//! Newton convergence loops, generic over the system and its assembly hook:
//! direct Newton (stamp, sparse LU, one solve per step) and JFNK (restarted
//! GMRES with finite-difference Jacobian products), plus the shared
//! acceptance gates and per-circuit workspace.
//!
//! In: a system, its assembly hook and a start x. Out: x at a converged
//! point (or the last iterate) and a `Result`.
//!
//! `sys` is a pointer with fields `n`, `nnz`, `diag_slots`, `rhs` and
//! `current_row`, an optional `solver_execution`, and optional methods
//! beginSolve, advanceIteration, checkpoint, loadCheck, deviceSolve,
//! evalFollows, checkConvergence, applyLimits, updateStates, clearLimits and
//! nodeName, plus `certify: bool` with certifyPoint(hook, x, t, opts), which
//! `newton` calls on every converged x outside the INITFIX pass, before
//! staging, when `certify` is true. `hook` provides assemble(sys, x, t),
//! vals(sys) (the Jacobian in pattern order), diagAt(sys, slot), and
//! optionally residual(sys, x, t) for a residual-only evaluation.
//!
//! Cites ngspice NIiter (maths/ni/niiter.c), NIconvTest (maths/ni/niconv.c)
//! and CKTload's nodeset hold (cktload.c); dev/solvers/gpu-lu.md (the device
//! factor); #3, #53, #152 (the runaway bound and the branch-row gate).

const std = @import("std");
const assert = std.debug.assert;
const direct = @import("direct.zig");
const BbdInfo = @import("core").numerics.BbdInfo;
const Execution = @import("core").numerics.Execution;
const num = @import("core").numerics;
const z = @import("stdpp");

const mul = z.lanewise(mulFn);
fn mulFn(p: anytype) @TypeOf(p.left) {
    return p.left * p.right;
}
/// (left - right) * inv: the finite-difference Jacobian product.
const FdQuot = struct {
    pub const lanewise = true;
    inv: f64,
    pub fn call(self: *@This(), p: anytype) @TypeOf(p.left) {
        return (p.left - p.right) * z.splat(@TypeOf(p.left), self.inv);
    }
};

/// `ESPICE_SOLVER` overrides `run`'s choice: direct, jfnk (LU-preconditioned
/// GMRES) or jfnk-nolu (Jacobi-preconditioned, no factorization at all).
pub const SolverPin = enum {
    auto,
    direct,
    jfnk,
    jfnk_nolu,

    /// The `ESPICE_SOLVER` spellings; anything else is `.auto`.
    pub const names = std.StaticStringMap(SolverPin).initComptime(.{
        .{ "direct", .direct }, .{ "jfnk", .jfnk }, .{ "jfnk-nolu", .jfnk_nolu },
    });
};

/// Developer switches (`Workspace.knobs`). The facade reads them from the
/// environment once (`espice.zig`); the solver reads no environment.
pub const Knobs = struct {
    /// `ESPICE_SOLVER`.
    pin: SolverPin = .auto,
    /// `ZP_OPDBG`: trace operating-point iterates and continuation rungs.
    opdbg: bool = false,
    /// `ZP_NEWTON_DEBUG`: trace every Newton iterate.
    newton_debug: bool = false,
};

/// Which gate refused an iterate, for the `ZP_OPDBG` trace. ngspice's
/// NIconvTest (maths/ni/niconv.c) has only the delta test, the first-iterate
/// floor and the device limiting flag; `.residual` and `.runaway` are ours.
/// Disabling `.residual` on vacask/mul changed the Newton count by 0.01%.
/// ngspice's CKTconvTest device tests are dead in 44.2: they bump
/// CKTnoncon, then NIiter assigns NIconvTest's return over it, and
/// CKTconvTest returns OK (niiter.c:288).
const Reject = enum { converged, first_iter, delta, limited, flipped, residual, device, runaway };

fn Deref(comptime P: type) type {
    return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
}

/// The BBD factor scheduler `sys` carries as `solver_execution`; serial
/// for a system without one.
fn executionOf(sys: anytype) Execution {
    return if (comptime @hasField(Deref(@TypeOf(sys)), "solver_execution")) sys.solver_execution else .{};
}

/// The user-facing accuracy profile (SPICE .options).
pub const Tolerances = @import("core").numerics.Tolerances;

/// Newton options for `tol`, with `max_iter_override` replacing ITL1. The
/// cap is never below 100: ngspice's NIiter raises any smaller maxIter to
/// 100 (niiter.c:38), so ITL2 and ITL4 only steer the callers' own
/// iteration-count heuristics, never the Newton loop itself.
pub fn optionsFromTolerances(tol: Tolerances, max_iter_override: ?u16) Options {
    comptime assert(100 <= std.math.maxInt(u16));
    return .{
        .max_iter = @max(max_iter_override orelse tol.itl1, 100),
        .abstol = tol.abstol,
        .reltol = tol.reltol,
        .vntol = tol.vntol,
        .residual_tol = tol.residual_tol,
        // Diagonal gmin is opt-in (the op gmin-stepping rung). ngspice's
        // NIiter loads none; junction gmin lives in the device models.
        .gmin = 0,
    };
}

/// Controls for one nonlinear solve.
pub const Options = struct {
    max_iter: u16 = 100,
    /// Current-row absolute tolerance, amperes.
    abstol: f64 = 1e-12,
    reltol: f64 = 1e-3,
    /// Voltage-row absolute tolerance, volts.
    vntol: f64 = 1e-6,
    /// Floor of the row-scaled residual gate.
    residual_tol: f64 = 1e-9,
    /// Conductance added to every diagonal (and gmin * x to the residual).
    gmin: f64 = 1e-12,
    /// Where `gmin` lands instead of every diagonal, when non-empty.
    gmin_stamps: []const GminStamp = &.{},
    /// Nonzero when the caller knows the matrix is unchanged since the last
    /// factor with this signature, so `newton` skips the factor.
    matrix_sig: u64 = 0,
    /// The solve is a cold operating point, ngspice's MODEINITJCT/INITFIX:
    /// the first iterate that passes every gate only switches to INITFLOAT,
    /// without staging device states, and the next must pass too, so
    /// `newton` publishes the second passing iterate (niiter.c, the
    /// MODEINITFIX branch; #53). Direct Newton only.
    init_fix: bool = false,
    /// Rows held near a value by a `force_g` conductance, as ngspice holds
    /// `.nodeset` nodes during MODEINITJCT/INITFIX (cktload.c). Direct Newton
    /// only.
    force: []const Force = &.{},
};

/// Conductance, in siemens, of a `Force` hold.
pub const force_g = 1e10;

/// `vals[slot] += force_g` and `rhs[row] += force_g * (x[row] - value)`: a
/// `force_g` conductance from row `row` to a source at `value`.
pub const Force = struct { slot: u32, row: u32, value: f64 };

/// One `gmin` load: `vals[slot] += gmin` and `rhs[row] += gmin * x[col]`,
/// the residual form of a conductance at (row, col).
pub const GminStamp = struct { slot: u32, row: u32, col: u32 };

/// Outcome of a nonlinear solve.
pub const Result = struct {
    converged: bool,
    iterations: u16,
    /// Largest scaled step of the accepted iterate; 0 when not converged.
    max_dx: f64,
};

/// Direct Newton: assemble, factor (skipped when `opts.matrix_sig` matches),
/// solve, accept. Errors are the factorization's and the checkpoint's.
///
/// A converged `x` is the last linearization point x_k, not the x_k+1 of the
/// final solve, which only feeds the acceptance gates. ngspice's NIiter
/// returns before swapping CKTrhs into CKTrhsOld (niiter.c), and CKTdump and
/// every device state read CKTrhsOld. A NaN or infinite iterate never
/// converges. `ws` must come from `Workspace.init` on `sys`'s n and pattern.
/// Asserts that `ws` and `x` are sized for `sys`.
pub fn newton(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const S = Deref(@TypeOf(sys));
    assert(ws.slv.n == sys.n);
    assert(ws.dx.len >= sys.n);
    assert(ws.x_old.len >= sys.n);
    assert(x.len >= sys.n);
    const slv = &ws.slv;
    const dx = ws.dx;
    const x_old = ws.x_old;
    var iter: u16 = 0;
    var init_fix = opts.init_fix;
    var limit: f64 = x_plausible;
    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();
    const prof = &ws.prof;

    while (iter < opts.max_iter) : (iter += 1) {
        if (comptime @hasDecl(S, "checkpoint")) if (iter != 0)
            try sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = opts.max_iter });
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);
        prof.start();
        hook.assemble(sys, x, t);
        prof.lap(.eval);
        const v = hook.vals(sys);
        loadExtras(sys, v, x, opts);
        if (iter == 0) limit = plausibleLimit(sys, x[0..sys.n], sys.rhs[0..sys.n], v);
        var norm_f: f64 = 0; // read only by the traces
        if (ws.knobs.newton_debug or ws.knobs.opdbg) {
            norm_f = num.normInf(sys.rhs[0..sys.n]);
        }
        if (ws.knobs.newton_debug)
            std.debug.print("  it={d} |F|={e} x={any}\n", .{ iter, norm_f, x[0..@min(sys.n, 8)] });
        // Before the factor and solve, which may overwrite `v` and `rhs`.
        const load_ok = if (comptime @hasDecl(S, "loadCheck")) sys.loadCheck(x, v, sys.rhs[0..sys.n], opts.reltol, opts.abstol) else true;
        prof.lap(.load);
        const need = opts.matrix_sig == 0 or ws.factored_sig != opts.matrix_sig;
        // The device LU (dev/solvers/gpu-lu.md) is bitwise this factor and
        // solve; false leaves both to the host.
        const on_device = if (comptime @hasDecl(S, "deviceSolve")) sys.deviceSolve(slv, v, dx, need) orelse false else false;
        if (on_device and need) ws.factored_sig = opts.matrix_sig;
        if (!on_device and need) {
            slv.factor(v, executionOf(sys)) catch |e| {
                if (ws.knobs.opdbg) {
                    var nan_cnt: usize = 0;
                    for (v[0..sys.nnz]) |vi| {
                        if (!std.math.isFinite(vi)) nan_cnt += 1;
                    }
                    const max_x = num.normInf(x[0..sys.n]);
                    std.debug.print("  newton it={d} FACTOR FAIL {} nan_vals={d} max|x|={e:.3} |F|={e:.3}\n", .{ iter, e, nan_cnt, max_x, norm_f });
                }
                return e;
            };
            ws.factored_sig = opts.matrix_sig;
            prof.lap(.factor);
        }
        if (!on_device) slv.solveNeg(sys.rhs, dx);
        prof.lap(.solve);
        // The INITFIX pass does not stage: its converged iterate is not the
        // answer, and staging there restarted a Newton-history limiter from a
        // stale value, so the extra pass solved F(lim(x)) = 0 (#53).
        const st = finalizeStep(sys, hook, x, dx, x_old, sys.rhs, v, iter, t, opts, limit, load_ok, !init_fix);
        prof.lap(.update);
        if (ws.knobs.opdbg) {
            var fi: usize = 0;
            var di: usize = 0;
            for (0..sys.n) |i| {
                if (@abs(sys.rhs[i]) > @abs(sys.rhs[fi])) fi = i;
                if (@abs(dx[i]) > @abs(dx[di])) di = i;
            }
            const name_fi = sysNodeName(sys, @intCast(fi));
            const name_di = sysNodeName(sys, @intCast(di));
            std.debug.print("  newton it={d} |F|={e:.3}@{d}({s}) dx={e:.3}@{d}({s}) x={e:.3} scaled={e:.3} conv={} why={s}\n", .{ iter, norm_f, fi, name_fi, dx[di], di, name_di, x[di], st.scaled, st.converged, @tagName(st.why) });
        }
        if (st.converged and init_fix) {
            init_fix = false;
        } else if (st.converged) {
            @memcpy(x[0..sys.n], x_old[0..sys.n]);
            return .{ .converged = true, .iterations = iter + 1, .max_dx = st.scaled };
        }
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

/// Adds the loads `newton` stamps on top of `hook.assemble`: the diagonal
/// (or `opts.gmin_stamps`) gmin and the `opts.force` holds, into `v` and
/// `sys.rhs`. `v` is `hook.vals(sys)`. Asserts that `x` holds n entries
/// and `v` nnz.
pub fn loadExtras(sys: anytype, v: []f64, x: []const f64, opts: Options) void {
    std.debug.assert(x.len >= sys.n);
    std.debug.assert(v.len >= sys.nnz);
    loadGmin(sys, v, sys.rhs[0..sys.n], x, opts);
    for (opts.force) |f| {
        v[f.slot] += force_g;
        sys.rhs[f.row] += force_g * (x[f.row] - f.value);
    }
}

/// The row-scaled residual gate's tolerance on a row whose diagonal is
/// `diag` and unknown `xi`: `newton` and `jfnk` accept only when every row
/// has |F_i| at or below it. A zero `diag` (a voltage-defined branch row)
/// is gated at scale 1, a tolerance in volts (#152).
pub fn residualGate(opts: Options, diag: f64, xi: f64) f64 {
    const scale = @abs(diag);
    // A zero diagonal is a voltage-defined branch row (V/E/H source): it is
    // gated at scale 1, a loose 10*(reltol*|x| + vntol) that an exact
    // solution's O(gain * eps) residual (a 1e9-gain E source reads 2.7e-8)
    // still passes, but that refuses x = 0 when the only residual sits on
    // such a row (#152).
    const s = if (scale == 0) 1.0 else scale;
    return @max(opts.residual_tol, 10.0 * s * (opts.reltol * @abs(xi) + opts.vntol));
}

fn sysNodeName(sys: anytype, idx: u32) []const u8 {
    const S = Deref(@TypeOf(sys));
    if (comptime @hasDecl(S, "nodeName")) return sys.nodeName(idx);
    return "?";
}

const Step = struct { converged: bool, scaled: f64, flipped: bool = false, why: Reject = .converged };

/// The floor of the largest |x| an accepted iterate may hold. Every
/// acceptance test is relative: the delta test to |x|, the residual gate to
/// the diagonal conductance. A Newton that ran away carries both with it (a
/// FET fed from a current source at 0 V reached 5e24 V with 1e45 S
/// diagonals, and its 3e39 A residual passed), so a runaway iterate is
/// refused outright (#3).
const x_plausible = 1e9;

/// The runaway bound of one solve, read off its first assembly: 1e3 times
/// the scale the circuit sets there, the start |x| or the drive |F| times
/// the largest diagonal conductance, between `x_plausible` and 1e21. A 1e12 V
/// source or a 1e-12 ohm resistor (1e12 A from 1 V) solves; with the fixed
/// 1e9 every iterate was refused and an operating point published zeros
/// (#152).
/// ponytail: the 1e18 scale cap keeps a solve that starts already run away
/// (#3's 5e24 V) refused; a bound from the circuit's sources and constant
/// stamps alone would need no cap.
fn plausibleLimit(sys: anytype, x: []const f64, f: []const f64, vals: []const f64) f64 {
    var g: f64 = 1;
    for (sys.diag_slots[0..sys.n]) |slot| g = @max(g, @abs(vals[slot]));
    const scale = @min(@max(num.normInf(x), num.normInf(f) * g), 1e18);
    // Negated, so a NaN start keeps the floor.
    return if (!(1e3 * scale > x_plausible)) x_plausible else 1e3 * scale;
}

/// Whether every unknown is finite and within `limit`.
fn plausible(x: []const f64, limit: f64) bool {
    for (x) |xi| if (!(@abs(xi) <= limit)) return false;
    return true;
}

/// Applies `dx` and runs the acceptance gates in order: device limiting,
/// first iterate, per-row delta, row-scaled residual, the device load test
/// (`load_ok`, `sys.loadCheck` at the assembled x), device convergence,
/// then state staging, skipped when `stage` is false.
fn finalizeStep(
    sys: anytype,
    hook: anytype,
    x: []f64,
    dx: []const f64,
    x_old: []f64,
    residual: []const f64,
    vals: []const f64,
    iter: u16,
    t: f64,
    opts: Options,
    limit: f64,
    load_ok: bool,
    stage: bool,
) Step {
    const S = Deref(@TypeOf(sys));
    const n = sys.n;
    assert(residual.len >= n);
    assert(vals.len >= sys.nnz);
    const scaled = updateAndNorm(x[0..n], dx[0..n], x_old[0..n], sys.current_row[0..n], opts.reltol, opts.abstol, opts.vntol);

    // The first-iterate and delta gates are already decided and neither
    // reads the limiter, so the next assemble at the limited x is certain:
    // a system that batches its limit pass with that eval may start both.
    if (comptime @hasDecl(S, "evalFollows")) {
        if ((iter == 0 or scaled >= 1.0) and iter + 1 < opts.max_iter) sys.evalFollows(x, t, false);
    }

    const limited = if (comptime @hasDecl(S, "applyLimits")) sys.applyLimits(x, x_old) else false;

    if (limited) return .{ .converged = false, .scaled = scaled, .why = .limited };
    if (iter == 0) return .{ .converged = false, .scaled = scaled, .why = .first_iter };
    if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled, .why = .delta };
    if (!plausible(x[0..n], limit)) return .{ .converged = false, .scaled = scaled, .why = .runaway };
    for (0..n) |i| {
        // Negated, so a NaN residual fails too.
        if (!(@abs(residual[i]) <= residualGate(opts, vals[sys.diag_slots[i]], x[i])))
            return .{ .converged = false, .scaled = scaled, .why = .residual };
    }
    if (!load_ok) return .{ .converged = false, .scaled = scaled, .why = .device };
    if (comptime @hasDecl(S, "checkConvergence")) {
        if (!sys.checkConvergence(x)) return .{ .converged = false, .scaled = scaled, .why = .device };
    }
    // Last, at the x_k `newton` publishes: staging per iterate re-entered every
    // model core once per instance per iteration (18% of
    // scaling/parallel_inverters_100), and devices whose core reads the
    // staged latches (cswitch/vswitch hysteresis) saw F change mid-solve.
    // A device that flips here forces one more iterate.
    // Before staging: a device whose eval reads its staged history (LTRA
    // appends the point it stages) would see this x twice (#53).
    if (comptime @hasDecl(S, "certify") and S.certify) if (stage) sys.certifyPoint(hook, x_old[0..n], t, opts);
    if (comptime @hasDecl(S, "updateStates")) if (stage) {
        if (sys.updateStates(x_old[0..n])) |_| return .{ .converged = false, .scaled = scaled, .flipped = true, .why = .flipped };
    };
    // The first-iterate and delta gates passed.
    assert(iter > 0);
    assert(!(scaled >= 1.0));
    return .{ .converged = true, .scaled = scaled };
}

const gmres_restart = 30;
const sqrt_eps: f64 = 0x1p-26; // sqrt(f64 machine epsilon)
const inf = std.math.inf(f64);

/// Jacobian-free Newton-Krylov: each step solves J dx = -F by one unrestarted cycle of
/// GMRES(min(30, n)) with finite-difference products J v, left-preconditioned
/// by the factored Jacobian (Jacobi only under ESPICE_SOLVER=jfnk-nolu).
/// Same gates as `newton`, with the residual gate on F, but a converged `x`
/// is x_k+1. A failed checkpoint returns `error.QueryCancelled`; the first
/// call on a workspace allocates its GMRES scratch (`error.OutOfMemory`).
/// Asserts that `ws` and `x_full` are sized for `sys`.
pub fn jfnk(
    sys: anytype,
    ws: *Workspace,
    x_full: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const S = Deref(@TypeOf(sys));
    const n: usize = sys.n;
    assert(ws.slv.n == n);
    assert(x_full.len >= n);
    const m: usize = @min(gmres_restart, n);
    const buf = try ws.ensureGmres(n);
    var off: usize = 0;
    const take = struct {
        fn f(b: []f64, o: *usize, len: usize) []f64 {
            defer o.* += len;
            return b[o.*..][0..len];
        }
    }.f;
    const v_basis = take(buf, &off, (m + 1) * n); // Krylov basis, vector-major
    const h = take(buf, &off, (m + 1) * m); // Hessenberg, row-major
    const cs = take(buf, &off, m); // Givens rotations
    const sn = take(buf, &off, m);
    const g = take(buf, &off, m + 1);
    const y = take(buf, &off, m);
    const w = take(buf, &off, n);
    const x_pert = take(buf, &off, n);
    const f0 = take(buf, &off, n); // F(x) + gmin * x at the outer iterate
    const diag = take(buf, &off, n); // Jacobi inverse diagonal
    assert(off == buf.len); // `ensureGmres` sized exactly these
    const r = ws.dx[0..n]; // becomes dx after the Krylov solve
    const x_old = ws.x_old[0..n];
    const x = x_full[0..n];
    // A null solver is what makes this matrix-free.
    const slv: ?*direct.Solver = if (ws.knobs.pin == .jfnk_nolu) null else &ws.slv;

    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();
    @memcpy(x_old, x);

    var limit: f64 = x_plausible;
    var iter: u16 = 0;
    while (iter < opts.max_iter) : (iter += 1) {
        if (comptime @hasDecl(S, "checkpoint")) if (iter != 0) {
            sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = opts.max_iter }) catch
                return error.QueryCancelled;
        };
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);

        assembleShifted(sys, x, t, opts, hook);
        @memcpy(f0, sys.rhs[0..n]);
        if (iter == 0) limit = plausibleLimit(sys, x, f0, hook.vals(sys));
        const v = hook.vals(sys);
        loadGmin(sys, v, null, x, opts);
        // Before the factor, which may overwrite `v`.
        const load_ok = if (comptime @hasDecl(S, "loadCheck")) sys.loadCheck(x, v, f0, opts.reltol, opts.abstol) else true;
        buildDiagPreconditioner(sys, v, diag);
        if (slv) |s| s.factor(v, executionOf(sys)) catch {};

        // r = -M^-1 f0, beta = ||r||.
        num.scale(r, -1, f0);
        applyPreconditioner(r, diag, slv);
        const beta = num.norm2(r);

        if (beta < opts.abstol and residualConverged(sys, hook, x, f0, opts, limit)) {
            @memset(r, 0);
            @memcpy(x_old, x);
            const limited = applyLimits(sys, x, x_old);
            if (iter > 0 and !limited and load_ok and acceptStep(sys, x))
                return .{ .converged = true, .iterations = iter + 1, .max_dx = 0 };
            continue;
        }

        num.scale(v_basis[0..n], 1 / beta, r);
        g[0] = beta;
        @memset(g[1 .. m + 1], 0);

        // eps_j = sqrt(eps_mach) * max(||x||, 1) / ||v_j||.
        const x_norm = @max(num.norm2(x), 1.0);

        var jj: usize = 0; // Arnoldi steps completed
        for (0..m) |j| {
            const vj = v_basis[j * n ..][0..n];
            const v_norm = num.norm2(vj);
            const eps = if (v_norm > 1e-30) sqrt_eps * x_norm / v_norm else sqrt_eps;

            // w = M^-1 (F(x + eps v_j) - f0) / eps.
            @memcpy(x_pert, x);
            num.axpy(x_pert, eps, vj);
            assembleShifted(sys, x_pert, t, opts, hook);
            const inv_eps = 1.0 / eps;
            var fd = z.fromSlice(f64, sys.rhs[0..n]).zip(z.fromSlice(f64, f0)).map(FdQuot{ .inv = inv_eps });
            _ = fd.writeInto(w);
            applyPreconditioner(w, diag, slv);

            // Modified Gram-Schmidt, sequential dot products.
            for (0..j + 1) |mi| {
                const vi = v_basis[mi * n ..][0..n];
                const hij = num.dot(vi, w);
                h[mi * m + j] = hij;
                num.axpy(w, -hij, vi);
            }
            const h_jp1 = num.norm2(w);
            h[(j + 1) * m + j] = h_jp1;
            if (h_jp1 > 1e-30) {
                num.scale(v_basis[(j + 1) * n ..][0..n], 1 / h_jp1, w);
            }

            for (0..j) |k| {
                const h_k = h[k * m + j];
                const h_k1 = h[(k + 1) * m + j];
                h[k * m + j] = cs[k] * h_k + sn[k] * h_k1;
                h[(k + 1) * m + j] = -sn[k] * h_k + cs[k] * h_k1;
            }
            const a_val = h[j * m + j];
            const b_val = h[(j + 1) * m + j];
            const r_val = @sqrt(a_val * a_val + b_val * b_val);
            if (r_val > 1e-30) {
                cs[j] = a_val / r_val;
                sn[j] = b_val / r_val;
            } else {
                cs[j] = 1.0;
                sn[j] = 0.0;
            }
            h[j * m + j] = r_val;
            h[(j + 1) * m + j] = 0;
            const g_j = g[j];
            const g_j1 = g[j + 1];
            g[j] = cs[j] * g_j + sn[j] * g_j1;
            g[j + 1] = -sn[j] * g_j + cs[j] * g_j1;
            jj = j + 1;
            if (@abs(g[j + 1]) < opts.abstol * 0.1) break;
        }

        // y = H^-1 g, then dx = V y.
        var k = jj;
        while (k > 0) {
            k -= 1;
            var s = g[k];
            for (k + 1..jj) |kk| s -= h[k * m + kk] * y[kk];
            const d = h[k * m + k];
            y[k] = if (@abs(d) > 1e-30) s / d else 0;
        }
        // Column by column: each entry still sums in increasing kk.
        @memset(r, 0);
        for (0..jj) |kk| num.axpy(r, y[kk], v_basis[kk * n ..][0..n]);

        // x_old = x; x += dx; per-row delta test. A non-finite iterate scores
        // inf: `@max` lowers to maxnum, which would drop a NaN and report a
        // diverged solve as converged.
        var scaled: f64 = 0;
        for (x, x_old, r, 0..) |*xi, *xoi, dxi, i| {
            const xo = xi.*;
            const xn = xo + dxi;
            xoi.* = xo;
            xi.* = xn;
            const atol = if (sys.current_row[i]) opts.abstol else opts.vntol;
            const tcrit = opts.reltol * @max(@abs(xn), @abs(xo)) + atol;
            const finite = @abs(xn) < inf and @abs(dxi) < inf;
            scaled = @max(scaled, if (finite) @abs(dxi) / tcrit else inf);
        }

        // Limiting may clamp x, so it runs before the residual gate.
        const limited = applyLimits(sys, x, x_old);
        const residual_ok = residualConverged(sys, hook, x, f0, opts, limit);
        // Publishes x_k+1: JFNK is not ngspice's iteration, and its inexact
        // steps leave x_k further out than a direct solve does.
        if (iter > 0 and scaled < 1.0 and residual_ok and !limited and load_ok and acceptStep(sys, x))
            return .{ .converged = true, .iterations = iter + 1, .max_dx = scaled };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

/// Solves with `newton`, or with `jfnk` under an `ESPICE_SOLVER` pin (falling
/// back to `newton` when it fails). Clears device limiting on exit.
pub fn run(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const S = Deref(@TypeOf(sys));
    // Function scope: a defer inside an `if` block would run before the solve.
    defer if (comptime @hasDecl(S, "clearLimits")) sys.clearLimits();

    const pin = ws.knobs.pin;
    if (pin == .jfnk or pin == .jfnk_nolu) {
        if (jfnk(sys, ws, x, t, opts, hook)) |r| {
            if (r.converged) return r;
        } else |err| if (err == error.QueryCancelled) return err;
    }
    // Direct Newton is the default because it was faster on every fixture
    // size, both backends, op and tran alike (best-of-2 wall seconds):
    //
    //   fixture                unkn  backend  direct   jfnk  jfnk-nolu
    //   resistor_grid_32x32     ~1k  cpu        0.01   0.02       0.16
    //   resistor_grid_100x100  ~10k  cpu        0.19   0.21      10.76
    //   rc_ladder_1k            ~1k  cpu        0.22   5.65       8.74
    //   rc_ladder_10k          ~10k  cpu        2.19   4.76      39.40
    //   rc_ladder_10k          ~10k  cuda       2.03   4.77      39.88
    //
    // JFNK still factors the Jacobian as its preconditioner and adds up to
    // 30 full device sweeps per step. It is not a superset either:
    // scaling/parallel_inverters_100 converges only under JFNK, and only when
    // JFNK drives the whole op ladder, while convergence/diode_bridge goes the
    // other way. An automatic retry after a failed direct solve cost 10x on
    // ensemble/pvt_corners, because `run` is called per rung and per
    // timestep. ponytail: the pin is the interface until the op ladder itself
    // learns to restart under JFNK.
    return newton(sys, ws, x, t, opts, hook);
}

/// Loads `opts.gmin` as `Options` documents: at each of `gmin_stamps`, or
/// on every diagonal when there are none. Adds it to `vals` when non-null
/// and its residual form, gmin * x[col], to `rhs` when non-null.
fn loadGmin(sys: anytype, vals: ?[]f64, rhs: ?[]f64, x: []const f64, opts: Options) void {
    if (!(opts.gmin > 0)) return;
    if (opts.gmin_stamps.len > 0) {
        for (opts.gmin_stamps) |g| {
            if (vals) |v| v[g.slot] += opts.gmin;
            if (rhs) |r| r[g.row] += opts.gmin * x[g.col];
        }
    } else for (0..sys.n) |i| {
        if (vals) |v| v[sys.diag_slots[i]] += opts.gmin;
        if (rhs) |r| r[i] += opts.gmin * x[i];
    }
}

/// Residual at x plus the gmin load into `sys.rhs`.
fn assembleShifted(sys: anytype, x: []const f64, t: f64, opts: Options, hook: anytype) void {
    assert(x.len == sys.n);
    if (@hasDecl(@TypeOf(hook), "residual"))
        hook.residual(sys, x, t)
    else
        hook.assemble(sys, x, t);
    loadGmin(sys, null, sys.rhs[0..x.len], x, opts);
}

/// Inverse diagonal of `vals`, which already carries the gmin load.
fn buildDiagPreconditioner(sys: anytype, vals: []const f64, diag: []f64) void {
    assert(diag.len >= sys.n);
    for (0..sys.n) |i| {
        const d = vals[sys.diag_slots[i]];
        diag[i] = if (@abs(d) > 1e-30) 1.0 / d else 1.0;
    }
}

/// r = M^-1 r: the LU when it factored, else the Jacobi diagonal.
fn applyPreconditioner(r: []f64, diag: []const f64, slv: ?*direct.Solver) void {
    assert(diag.len >= r.len);
    if (slv) |s| {
        if (s.factored) {
            s.solve(r, r);
            return;
        }
    }
    var it = z.fromSlice(f64, r).zip(z.fromSlice(f64, diag[0..r.len])).map(mul);
    _ = it.writeInto(r);
}

fn applyLimits(sys: anytype, x: []f64, x_old: []f64) bool {
    return if (comptime @hasDecl(Deref(@TypeOf(sys)), "applyLimits")) sys.applyLimits(x, x_old) else false;
}

/// Device convergence, then state staging; false refuses the iterate.
fn acceptStep(sys: anytype, x: []f64) bool {
    const S = Deref(@TypeOf(sys));
    if (comptime @hasDecl(S, "checkConvergence")) {
        if (!sys.checkConvergence(x)) return false;
    }
    if (comptime @hasDecl(S, "updateStates")) {
        if (sys.updateStates(x) != null) return false;
    }
    return true;
}

/// Row-scaled residual gate, as in `finalizeStep`, that also rejects a
/// non-finite residual or an iterate past `limit`. A row with no diagonal
/// (a V source's branch row) holds its KVL residual in volts to
/// 10 (reltol |x| + vntol): JFNK has no delta test to govern it, and
/// skipping the row accepted a cold x = 0 whose only residual was the
/// source's own value (#152).
fn residualConverged(sys: anytype, hook: anytype, x: []const f64, residual: []const f64, opts: Options, limit: f64) bool {
    assert(x.len == sys.n);
    var ok = true;
    for (x, residual, 0..) |xi, ri, i| {
        const rt = residualGate(opts, hook.diagAt(sys, sys.diag_slots[i]), xi);
        // Negated comparisons reject NaN too.
        if (!(@abs(ri) <= rt) or !(@abs(xi) <= limit)) ok = false;
    }
    return ok;
}

/// Private kernels for tests.zig; void outside test builds.
pub const test_access = if (@import("builtin").is_test) .{ .updateAndNorm = updateAndNorm } else {};

/// x_old = x; x += dx; returns max |dx| / (reltol * max(|x|, |x_old|) + atol),
/// atol = abstol on current rows, vntol elsewhere. A row whose new x or dx
/// is NaN or infinite scores inf: `@max` lowers to maxnum, which would drop
/// a NaN and pass a diverged step. Max is exact and order-independent, so
/// the vector body and scalar tail agree bitwise with a plain scalar loop.
fn updateAndNorm(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    const V = @Vector(W, f64);
    const rel: V = @splat(reltol);
    const abs_i: V = @splat(abstol);
    const abs_v: V = @splat(vntol);
    const inf_v: V = @splat(inf);
    // Up front, so the vector body carries no per-slice bounds checks.
    assert(dx.len >= x.len);
    assert(x_old.len >= x.len);
    assert(current_row.len >= x.len);
    var worst_v: V = @splat(0);
    var i: usize = 0;
    while (i + W <= x.len) : (i += W) {
        const xo: V = x[i..][0..W].*;
        const d: V = dx[i..][0..W].*;
        const cur: @Vector(W, bool) = current_row[i..][0..W].*;
        const xn = xo + d;
        x_old[i..][0..W].* = xo;
        x[i..][0..W].* = xn;
        const tol = rel * @max(@abs(xn), @abs(xo)) + @select(f64, cur, abs_i, abs_v);
        const finite = (@abs(xn) < inf_v) & (@abs(d) < inf_v);
        worst_v = @max(worst_v, @select(f64, finite, @abs(d) / tol, inf_v));
    }
    var worst: f64 = @reduce(.Max, worst_v);
    for (x[i..], dx[i..], x_old[i..], current_row[i..x.len]) |*xi, dxi, *xoi, is_cur| {
        const xo = xi.*;
        xoi.* = xo;
        xi.* = xo + dxi;
        const atol = if (is_cur) abstol else vntol;
        const tol = reltol * @max(@abs(xi.*), @abs(xo)) + atol;
        const finite = @abs(xi.*) < inf and @abs(dxi) < inf;
        worst = @max(worst, if (finite) @abs(dxi) / tol else inf);
    }
    assert(!(worst < 0));
    return worst;
}

/// `--timing-in-depth` wall-time split of `newton`, summed over every solve
/// on one workspace. Off (no clock reads) until `io` is set.
pub const Prof = struct {
    io: ?std.Io = null,
    /// Nanoseconds per phase, indexed by `Phase`.
    ns: [5]u64 = @splat(0),
    /// Newton iterations and the factorizations among them.
    counts: [2]u64 = @splat(0),
    last: std.Io.Timestamp = .zero,

    /// eval: device evaluation plus companion stamps (`hook.assemble`).
    /// load: the combined G + ag0*C matrix and gmin. update: the step,
    /// limiting and the convergence gates.
    pub const Phase = enum(u3) { eval, load, factor, solve, update };

    fn start(p: *Prof) void {
        const io = p.io orelse return;
        p.last = .now(io, .awake);
        p.counts[0] += 1;
    }

    fn lap(p: *Prof, phase: Phase) void {
        comptime assert(@typeInfo(Phase).@"enum".field_names.len == @typeInfo(@FieldType(Prof, "ns")).array.len);
        const io = p.io orelse return;
        const now: std.Io.Timestamp = .now(io, .awake);
        p.ns[@backingInt(phase)] += @intCast(p.last.durationTo(now).nanoseconds);
        p.last = now;
        if (phase == .factor) p.counts[1] += 1;
    }
};

/// Per-circuit Newton scratch: the direct solver on the circuit pattern plus
/// step vectors. GMRES and combined-matrix buffers grow on first use.
pub const Workspace = struct {
    slv: direct.Solver,
    dx: []f64,
    x_old: []f64,
    gmres: []f64 = &.{},
    a_vals: []f64 = &.{},
    /// `Options.matrix_sig` of the current factorization; 0 = none.
    factored_sig: u64 = 0,
    prof: Prof = .{},
    knobs: Knobs,

    /// Borrows `col_ptr` and `row_idx` for the workspace's lifetime. Caller
    /// frees with `deinit` and the same allocator. Asserts that `col_ptr`
    /// has n + 1 entries.
    pub fn init(gpa: std.mem.Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?BbdInfo, knobs: Knobs, lu_knobs: direct.Knobs) !Workspace {
        assert(col_ptr.len == @as(usize, n) + 1);
        const dx = try gpa.alloc(f64, n);
        errdefer gpa.free(dx);
        const x_old = try gpa.alloc(f64, n);
        errdefer gpa.free(x_old);
        return .{
            .slv = try direct.Solver.init(gpa, n, col_ptr, row_idx, bbd, lu_knobs),
            .dx = dx,
            .x_old = x_old,
            .knobs = knobs,
        };
    }

    fn ensureGmres(self: *Workspace, n: usize) ![]f64 {
        const m: usize = @min(gmres_restart, n);
        const total = (m + 1) * n + (m + 1) * m + m + m + (m + 1) + m + 4 * n;
        if (self.gmres.len < total) {
            self.slv.gpa.free(self.gmres);
            self.gmres = &.{};
            self.gmres = try self.slv.gpa.alloc(f64, total);
        }
        return self.gmres[0..total];
    }

    /// Scratch of length `nnz` for tran's combined G + alpha*C values, reused
    /// across runs; the slice is invalidated by the next call that grows it.
    pub fn ensureAVals(self: *Workspace, nnz: u32) ![]f64 {
        if (self.a_vals.len < nnz) {
            self.slv.gpa.free(self.a_vals);
            // Empty before the alloc so a failure cannot double-free in deinit.
            self.a_vals = &.{};
            self.a_vals = try self.slv.gpa.alloc(f64, nnz);
        }
        return self.a_vals[0..nnz];
    }

    /// Frees every buffer, the lazily grown ones included; `gpa` must be the
    /// allocator `init` got.
    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.slv.deinit();
        gpa.free(self.dx);
        gpa.free(self.x_old);
        gpa.free(self.gmres);
        gpa.free(self.a_vals);
        self.* = undefined;
    }
};

test "FdQuot and mul run on stdpp's SIMD path and match its pull path bitwise" {
    const builtin = @import("builtin");
    if (builtin.zig_backend == .stage2_llvm or builtin.zig_backend == .stage2_x86_64) {
        const e: []const f64 = &.{};
        const pair = z.fromSlice(f64, e).zip(z.fromSlice(f64, e));
        comptime std.debug.assert(@TypeOf(pair.map(FdQuot{ .inv = 0 })).lane_count != null);
        comptime std.debug.assert(@TypeOf(pair.map(mul)).lane_count != null);
    }
    var prng = std.Random.DefaultPrng.init(0xFD);
    const r = prng.random();
    var left: [84]f64 = undefined;
    var right: [84]f64 = undefined;
    for (&left, &right) |*u, *v| {
        u.* = r.float(f64) - 0.5;
        v.* = r.float(f64) - 0.5;
    }
    left[5] = std.math.nan(f64);
    right[40] = std.math.inf(f64);
    var fast: [84]f64 = undefined;
    var slow: [84]f64 = undefined;
    // Past 4 unrolled blocks of the widest f64 vector, at every misalignment.
    for (0..81) |len| for (0..4) |off| {
        const lv = left[off..][0..len];
        const rv = right[off..][0..len];
        inline for (.{ FdQuot{ .inv = 1e7 }, mul }) |f| {
            var it = z.fromSlice(f64, lv).zip(z.fromSlice(f64, rv)).map(f);
            try std.testing.expectEqual(len, it.writeInto(fast[0..len]));
            var src = z.fromSlice(f64, lv);
            var pull = src.byRef().zip(z.fromSlice(f64, rv)).map(f);
            try std.testing.expectEqual(len, pull.writeInto(slow[0..len]));
            for (fast[0..len], slow[0..len]) |a, b| try std.testing.expectEqual(@as(u64, @bitCast(b)), @as(u64, @bitCast(a)));
        }
    };
}
