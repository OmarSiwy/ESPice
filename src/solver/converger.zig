//! Newton convergence loops, generic over the system and its assembly hook:
//! direct Newton (stamp, sparse LU, one solve per step) and JFNK (one
//! `gmres.Gmres` cycle on finite-difference Jacobian products), plus the shared
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
const Gmres = @import("gmres.zig").Gmres;
const BbdInfo = @import("core").numerics.BbdInfo;
const Execution = @import("core").numerics.Execution;
const num = @import("core").numerics;

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
comptime {
    // Per-entry tables the loads walk: no padding.
    assert(@sizeOf(Force) == 16);
    assert(@sizeOf(GminStamp) == 12);
}

/// Outcome of a nonlinear solve.
pub const Result = struct {
    converged: bool,
    iterations: u16,
};

/// Direct Newton: assemble, factor, solve, accept. Errors are the factorization's and the checkpoint's.
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
        // The device LU (dev/solvers/gpu-lu.md) is bitwise this factor and
        // solve; false leaves both to the host.
        const on_device = if (comptime @hasDecl(S, "deviceSolve")) sys.deviceSolve(slv, v, dx) orelse false else false;
        if (!on_device) {
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
            prof.lap(.factor);
            slv.solveNeg(sys.rhs, dx);
        }
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
            return .{ .converged = true, .iterations = iter + 1 };
        }
    }
    return .{ .converged = false, .iterations = opts.max_iter };
}

/// Adds the loads `newton` stamps on top of `hook.assemble`: the diagonal
/// (or `opts.gmin_stamps`) gmin and the `opts.force` holds, into `v` and
/// `sys.rhs`. `v` is `hook.vals(sys)`. Asserts that `x` holds n entries
/// and `v` nnz.
pub fn loadExtras(sys: anytype, v: []f64, x: []const f64, opts: Options) void {
    assert(x.len >= sys.n);
    assert(v.len >= sys.nnz);
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

const Step = struct { converged: bool, scaled: f64, why: Reject = .converged };

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

/// Whether every unknown is finite and within `limit`. Chunked: each
/// 64-unknown block is a branchless OR the loop vectorizer takes, with one
/// branch per block; `!(a <= b)` fails NaN too. 0.07-0.09 ns per unknown
/// against the early-return loop's 0.54 (ReleaseFast, n = 64 to 16384).
fn plausible(x: []const f64, limit: f64) bool {
    const block = 64;
    var i: usize = 0;
    while (i + block <= x.len) : (i += block) {
        var bad: u64 = 0;
        for (x[i..][0..block]) |xi| bad |= @intFromBool(!(@abs(xi) <= limit));
        if (bad != 0) return false;
    }
    var bad: u64 = 0;
    for (x[i..]) |xi| bad |= @intFromBool(!(@abs(xi) <= limit));
    return bad == 0;
}

/// Rows whose |F_i| exceeds `residualGate`, NaN included. A branchless
/// count, not an early return: it runs only on an iterate that passed the
/// delta gate, where it nearly always passes and reads every row anyway.
/// 0.52 ns per row against the early-return loop's 1.22 (ReleaseFast, n =
/// 64 to 16384).
fn residualMisses(opts: Options, residual: []const f64, x: []const f64, vals: []const f64, diag_slots: []const u32) usize {
    assert(residual.len >= x.len);
    assert(diag_slots.len >= x.len);
    var misses: usize = 0;
    for (residual[0..x.len], x, diag_slots[0..x.len]) |ri, xi, slot|
        misses += @intFromBool(!(@abs(ri) <= residualGate(opts, vals[slot], xi)));
    return misses;
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
    if (residualMisses(opts, residual[0..n], x[0..n], vals, sys.diag_slots[0..n]) != 0)
        return .{ .converged = false, .scaled = scaled, .why = .residual };
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
        if (sys.updateStates(x_old[0..n])) |_| return .{ .converged = false, .scaled = scaled, .why = .flipped };
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
/// GMRES(min(30, n)) (`gmres.Gmres`) with finite-difference products J v,
/// left-preconditioned by the factored Jacobian (Jacobi only under
/// ESPICE_SOLVER=jfnk-nolu). A cycle that stops short is taken as it stands.
/// Same gates as `newton`, with the residual gate on F, but a converged `x`
/// is x_k+1. A failed checkpoint returns `error.QueryCancelled`; the first
/// call on a workspace allocates its GMRES scratch (`error.OutOfMemory`).
/// Asserts that `ws` and `x_full` are sized for `sys` and that `sys` has an
/// unknown.
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
    assert(n > 0);
    assert(ws.slv.n == n);
    assert(x_full.len >= n);
    const krylov = try ws.ensureKrylov();
    const x_pert = ws.jf[0..n];
    const f0 = ws.jf[n..][0..n]; // F(x) + gmin * x at the outer iterate
    const b = ws.jf[2 * n ..][0..n]; // -M^-1 f0, the Krylov right-hand side
    const diag = ws.jf[3 * n ..][0..n]; // Jacobi inverse diagonal
    const r = ws.dx[0..n]; // becomes dx after the Krylov solve
    const x_old = ws.x_old[0..n];
    const x = x_full[0..n];
    // A null solver is what makes this matrix-free.
    const slv: ?*direct.Solver = if (ws.knobs.pin == .jfnk_nolu) null else &ws.slv;

    // w = M^-1 (F(x + eps v) - f0) / eps, eps = sqrt(eps_mach) * max(||x||, 1) / ||v||:
    // left preconditioning inside the operator, so GMRES's residual and
    // stop are on M^-1 (F + J dx), as the hand-rolled solver's were.
    // Right preconditioning (a `precond` decl) left the 2x2 circle test
    // (solver tests) 1e-6 from its root; the hand-rolled left form landed
    // within 1e-8.
    const Sys = @TypeOf(sys);
    const Hook = @TypeOf(hook);
    const FdOp = struct {
        sys: Sys,
        hook: Hook,
        x: []const f64,
        x_norm: f64 = 0,
        x_pert: []f64,
        f0: []const f64,
        diag: []const f64,
        slv: ?*direct.Solver,
        t: f64,
        opts: Options,

        pub fn matvec(op: *@This(), v: []const f64, w: []f64) void {
            const v_norm = num.norm2(v);
            // J 0 = 0 exactly: GMRES's initial residual costs no device eval.
            if (v_norm == 0) {
                @memset(w, 0);
                return;
            }
            const eps = if (v_norm > 1e-30) sqrt_eps * op.x_norm / v_norm else sqrt_eps;
            @memcpy(op.x_pert, op.x);
            num.axpy(op.x_pert, eps, v);
            assembleShifted(op.sys, op.x_pert, op.t, op.opts, op.hook);
            // The finite-difference product; a plain loop LLVM vectorizes.
            const inv = 1.0 / eps;
            for (w, op.sys.rhs[0..w.len], op.f0[0..w.len]) |*wi, fi, f0i| wi.* = (fi - f0i) * inv;
            applyPreconditioner(w, op.diag, op.slv);
        }
    };
    var op: FdOp = .{ .sys = sys, .hook = hook, .x = x, .x_pert = x_pert, .f0 = f0, .diag = diag, .slv = slv, .t = t, .opts = opts };

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

        // ||M^-1 f0||: the preconditioned step already within abstol.
        // b = -M^-1 f0, beta = ||b||.
        num.scale(b, -1, f0);
        applyPreconditioner(b, diag, slv);
        const beta = num.norm2(b);
        if (beta < opts.abstol and residualConverged(sys, hook, x, f0, opts, limit)) {
            @memset(r, 0);
            @memcpy(x_old, x);
            const limited = applyLimits(sys, x, x_old);
            if (iter > 0 and !limited and load_ok and acceptStep(sys, x))
                return .{ .converged = true, .iterations = iter + 1 };
            continue;
        }

        // GMRES stops at ||M^-1 (F + J dx)|| <= abstol / 10, but takes at
        // least one Arnoldi step: a beta already under that would otherwise
        // return dx = 0 and stall on the residual gate.
        @memset(r, 0);
        op.x_norm = @max(num.norm2(x), 1.0);
        _ = krylov.solve(&op, b, r, @min(0.1 * opts.abstol / beta, 0.5), 0);

        // Limiting may clamp x, so it runs before the residual gate.
        const scaled = updateAndNorm(x, r, x_old, sys.current_row[0..n], opts.reltol, opts.abstol, opts.vntol);
        const limited = applyLimits(sys, x, x_old);
        const residual_ok = residualConverged(sys, hook, x, f0, opts, limit);
        // Publishes x_k+1: JFNK is not ngspice's iteration, and its inexact
        // steps leave x_k further out than a direct solve does.
        if (iter > 0 and scaled < 1.0 and residual_ok and !limited and load_ok and acceptStep(sys, x))
            return .{ .converged = true, .iterations = iter + 1 };
    }
    return .{ .converged = false, .iterations = opts.max_iter };
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
    if ((pin == .jfnk or pin == .jfnk_nolu) and sys.n > 0) {
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
    const gmin = opts.gmin;
    const stamps = opts.gmin_stamps;
    if (vals) |v| {
        if (stamps.len > 0) {
            for (stamps) |g| v[g.slot] += gmin;
        } else for (sys.diag_slots[0..sys.n]) |slot| v[slot] += gmin;
    }
    if (rhs) |r| {
        if (stamps.len > 0) {
            for (stamps) |g| r[g.row] += gmin * x[g.col];
        } else for (r[0..sys.n], x[0..sys.n]) |*ri, xi| ri.* += gmin * xi;
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
    for (r, diag[0..r.len]) |*ri, di| ri.* *= di;
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
/// is NaN or infinite scores inf; a zero step on a zero tolerance (0/0)
/// scores 0. The max runs on the i64 bit patterns of the nonnegative
/// scores: exact and order-independent, and the loop vectorizes (float
/// `@max` keeps it scalar: 1.2 against 0.8 ns per row).
fn updateAndNorm(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    // Up front, so the loop carries no per-slice bounds checks.
    assert(dx.len >= x.len);
    assert(x_old.len >= x.len);
    assert(current_row.len >= x.len);
    var worst: i64 = 0;
    for (x, dx[0..x.len], x_old[0..x.len], current_row[0..x.len]) |*xi, d, *xoi, cur| {
        const xo = xi.*;
        const xn = xo + d;
        xoi.* = xo;
        xi.* = xn;
        const tol = reltol * @max(@abs(xn), @abs(xo)) + (if (cur) abstol else vntol);
        const finite = @abs(xn) < inf and @abs(d) < inf;
        const q = @abs(d) / tol;
        const score: f64 = if (!finite) inf else if (q == q) q else 0;
        worst = @max(worst, @as(i64, @bitCast(score)));
    }
    const result: f64 = @bitCast(worst);
    assert(!(result < 0));
    return result;
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

    pub fn start(p: *Prof) void {
        const io = p.io orelse return;
        p.last = .now(io, .awake);
        p.counts[0] += 1;
    }

    pub fn lap(p: *Prof, phase: Phase) void {
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
    /// `jfnk`'s GMRES and its four n-vectors (x_pert, f0, b, diag), made
    /// on its first call.
    krylov: ?Gmres = null,
    jf: []f64 = &.{},
    /// tran's G + alpha*C values, grown by `ensureAVals`.
    a_vals: []f64 = &.{},
    prof: Prof = .{},
    knobs: Knobs,

    /// Borrows `col_ptr` and `row_idx` for the workspace's lifetime. Caller
    /// frees with `deinit` and the same allocator. Fails as
    /// `direct.Solver.init` does (out of memory, or the ordering's
    /// `OutOfWorkspace`), leaving nothing allocated. Asserts that `col_ptr`
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

    fn ensureKrylov(self: *Workspace) !*Gmres {
        if (self.krylov == null) {
            const gpa = self.slv.gpa;
            const n = self.slv.n;
            const jf = try gpa.alloc(f64, 4 * @as(usize, n));
            errdefer gpa.free(jf);
            self.krylov = try Gmres.init(gpa, n, @min(gmres_restart, n));
            self.jf = jf;
        }
        return &self.krylov.?;
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
        if (self.krylov) |*k| k.deinit(gpa);
        gpa.free(self.jf);
        gpa.free(self.a_vals);
        self.* = undefined;
    }
};

test "the Jacobi preconditioner scales each row by its inverse diagonal" {
    var r = [_]f64{ 2, -3, 4, std.math.nan(f64) };
    const diag = [_]f64{ 0.5, 2, -0.25, 1, 9 };
    applyPreconditioner(&r, &diag, null);
    try std.testing.expectEqualSlices(f64, &.{ 1, -6, -1 }, r[0..3]);
    try std.testing.expect(std.math.isNan(r[3]));
}

test "plausible and residualMisses match a scalar oracle at every length, NaN and inf included" {
    var prng = std.Random.DefaultPrng.init(0xC0);
    const r = prng.random();
    const len_max = 200;
    var x: [len_max]f64 = undefined;
    var res: [len_max]f64 = undefined;
    var vals: [len_max + 1]f64 = undefined;
    var slots: [len_max]u32 = undefined;
    const opts: Options = .{};
    for (0..len_max + 1) |n| for (0..4) |plant| {
        for (x[0..n], res[0..n], slots[0..n], 0..) |*xi, *ri, *si, i| {
            xi.* = (r.float(f64) - 0.5) * 10;
            ri.* = (r.float(f64) - 0.5) * 1e-8;
            si.* = @intCast((i * 7) % (len_max + 1));
        }
        for (&vals, 0..) |*v, i| v.* = if (i % 5 == 0) 0 else r.float(f64) * 1e-2;
        if (n > 0) {
            const at = r.uintLessThan(usize, n);
            switch (plant) {
                0 => {},
                1 => {
                    x[at] = std.math.nan(f64);
                    res[at] = std.math.nan(f64);
                },
                2 => {
                    x[at] = -std.math.inf(f64);
                    res[at] = std.math.inf(f64);
                },
                else => x[at] = 5, // else: plant 3, exactly at the limit (plausible)
            }
        }
        var want_plausible = true;
        var want_misses: usize = 0;
        for (0..n) |i| {
            if (!(@abs(x[i]) <= 5)) want_plausible = false;
            const diag = @abs(vals[slots[i]]);
            const scale = if (diag == 0) 1.0 else diag;
            const gate = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
            if (!(@abs(res[i]) <= gate)) want_misses += 1;
        }
        try std.testing.expectEqual(want_plausible, plausible(x[0..n], 5));
        try std.testing.expectEqual(want_misses, residualMisses(opts, res[0..n], x[0..n], &vals, slots[0..n]));
    };
}

test "loadGmin stamps the diagonal or the listed stamps, into vals and rhs independently" {
    const Sys = struct { n: u32 = 3, diag_slots: []const u32 = &.{ 0, 4, 8 } };
    const sys: Sys = .{};
    const x = [_]f64{ 1, -2, 3 };
    var vals: [9]f64 = @splat(0);
    var rhs: [3]f64 = @splat(1);
    loadGmin(&sys, &vals, &rhs, &x, .{ .gmin = 0.5 });
    try std.testing.expectEqualSlices(f64, &.{ 0.5, 0, 0, 0, 0.5, 0, 0, 0, 0.5 }, &vals);
    try std.testing.expectEqualSlices(f64, &.{ 1.5, 0, 2.5 }, &rhs);
    // Stamps: (row 0, col 2) at slot 6, twice; rhs only.
    const stamps = [_]GminStamp{ .{ .slot = 6, .row = 0, .col = 2 }, .{ .slot = 6, .row = 0, .col = 2 } };
    loadGmin(&sys, null, &rhs, &x, .{ .gmin = 0.25, .gmin_stamps = &stamps });
    try std.testing.expectEqualSlices(f64, &.{ 3, 0, 2.5 }, &rhs);
    loadGmin(&sys, &vals, null, &x, .{ .gmin = 0.25, .gmin_stamps = &stamps });
    try std.testing.expectEqual(@as(f64, 0.5), vals[6]);
    // Zero, negative and NaN gmin load nothing.
    const before = vals;
    for ([_]f64{ 0, -1, std.math.nan(f64) }) |g| loadGmin(&sys, &vals, &rhs, &x, .{ .gmin = g });
    try std.testing.expectEqualSlices(f64, &before, &vals);
    try std.testing.expectEqualSlices(f64, &.{ 3, 0, 2.5 }, &rhs);
}
