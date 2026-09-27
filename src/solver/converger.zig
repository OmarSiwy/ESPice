//! Newton convergence loops, generic over the system and its assembly hook:
//! direct Newton (stamp, sparse LU, one solve per step) and JFNK (restarted
//! GMRES with finite-difference Jacobian products), plus the shared
//! acceptance gates and per-circuit workspace.
//!
//! `sys` is a pointer with fields `n`, `nnz`, `diag_slots`, `rhs` and
//! `current_row`, and optional methods beginSolve, advanceIteration,
//! checkpoint, checkConvergence, applyLimits, updateStates, clearLimits and
//! nodeName. `hook` provides assemble(sys, x, t), vals(sys) (the Jacobian in
//! pattern order), diagAt(sys, slot), and optionally residual(sys, x, t) for
//! a residual-only evaluation.

const std = @import("std");
const direct = @import("direct.zig");
const BbdInfo = @import("core").numerics.BbdInfo;
const Execution = @import("core").numerics.Execution;

/// `ESPICE_SOLVER` overrides `run`'s choice: direct, jfnk (LU-preconditioned
/// GMRES) or jfnk-nolu (Jacobi-preconditioned, no factorization at all).
const SolverPin = enum { auto, direct, jfnk, jfnk_nolu };

/// Read once per process; concurrent first readers may repeat the lookup.
var solver_pin_cache: std.atomic.Value(u8) = .init(std.math.maxInt(u8));

fn solverPin() SolverPin {
    const cached = solver_pin_cache.load(.monotonic);
    if (cached != std.math.maxInt(u8)) return @enumFromInt(cached);
    const p: SolverPin = blk: {
        const s = std.c.getenv("ESPICE_SOLVER") orelse break :blk .auto;
        break :blk std.StaticStringMap(SolverPin).initComptime(.{
            .{ "direct", .direct }, .{ "jfnk", .jfnk }, .{ "jfnk-nolu", .jfnk_nolu },
        }).get(std.mem.span(s)) orelse .auto;
    };
    solver_pin_cache.store(@intFromEnum(p), .monotonic);
    return p;
}

// Debug flags, read once: they are tested per Newton iterate, and glibc's
// getenv is a linear scan of environ (0.35% of a devices/mos6_inverter run).
// 0 = unread, 1 = unset, 2 = set.
var opdbg_cache: std.atomic.Value(u8) = .init(0);
var newton_dbg_cache: std.atomic.Value(u8) = .init(0);
var hb_trace_cache: std.atomic.Value(u8) = .init(0);

/// `ZP_OPDBG`: trace operating-point iterates and continuation rungs.
pub fn opdbg() bool {
    return envFlag(&opdbg_cache, "ZP_OPDBG");
}

fn newtonDbg() bool {
    return envFlag(&newton_dbg_cache, "ZP_NEWTON_DEBUG");
}

/// `ESPICE_HB_TRACE`: trace harmonic-balance iterates.
pub fn hbTrace() bool {
    return envFlag(&hb_trace_cache, "ESPICE_HB_TRACE");
}

fn envFlag(cache: *std.atomic.Value(u8), name: [*:0]const u8) bool {
    const cached = cache.load(.monotonic);
    if (cached != 0) return cached == 2;
    const v = std.c.getenv(name) != null;
    cache.store(@as(u8, @intFromBool(v)) + 1, .monotonic);
    return v;
}

/// Which gate refused an iterate, for the `ZP_OPDBG` trace. ngspice's
/// NIconvTest (maths/ni/niconv.c) has only the delta test, the first-iterate
/// floor and the device limiting flag; `.residual` is ours. Disabling it on
/// vacask/mul changed the Newton count by 0.01%. ngspice's CKTconvTest
/// device tests are dead in 44.2: they bump CKTnoncon, then NIiter assigns
/// NIconvTest's return over it, and CKTconvTest returns OK (niiter.c:288).
const Reject = enum { converged, first_iter, delta, limited, flipped, residual, device };

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
    /// Nonzero when the caller knows the matrix is unchanged since the last
    /// factor with this signature, so `newton` skips the factor.
    matrix_sig: u64 = 0,
    /// The solve is a cold operating point, ngspice's MODEINITJCT/INITFIX:
    /// the first iterate that passes every gate only switches to INITFLOAT
    /// and the next must pass too, so `newton` publishes the first passing
    /// solve (niiter.c, the MODEINITFIX branch).
    init_fix: bool = false,
};

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
/// every device state read CKTrhsOld.
pub fn newton(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const S = Deref(@TypeOf(sys));
    const slv = &ws.slv;
    const dx = ws.dx;
    const x_old = ws.x_old;
    var iter: u16 = 0;
    var init_fix = opts.init_fix;
    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();

    while (iter < opts.max_iter) : (iter += 1) {
        if (comptime @hasDecl(S, "checkpoint")) if (iter != 0)
            try sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = opts.max_iter });
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);
        hook.assemble(sys, x, t);
        const v = hook.vals(sys);
        if (opts.gmin > 0) {
            if (opts.gmin_stamps.len > 0) {
                for (opts.gmin_stamps) |g| {
                    v[g.slot] += opts.gmin;
                    sys.rhs[g.row] += opts.gmin * x[g.col];
                }
            } else for (0..sys.n) |i| {
                v[sys.diag_slots[i]] += opts.gmin;
                sys.rhs[i] += opts.gmin * x[i];
            }
        }
        var norm_f: f64 = 0; // read only by the traces
        if (newtonDbg() or opdbg()) {
            for (0..sys.n) |i| norm_f = @max(norm_f, @abs(sys.rhs[i]));
        }
        if (newtonDbg())
            std.debug.print("  it={d} |F|={e} x={any}\n", .{ iter, norm_f, x[0..@min(sys.n, 8)] });
        if (opts.matrix_sig == 0 or ws.factored_sig != opts.matrix_sig) {
            slv.factor(v, executionOf(sys)) catch |e| {
                if (opdbg()) {
                    var nan_cnt: usize = 0;
                    var max_x: f64 = 0;
                    for (v[0..sys.nnz]) |vi| {
                        if (!std.math.isFinite(vi)) nan_cnt += 1;
                    }
                    for (0..sys.n) |i| max_x = @max(max_x, @abs(x[i]));
                    std.debug.print("  newton it={d} FACTOR FAIL {} nan_vals={d} max|x|={e:.3} |F|={e:.3}\n", .{ iter, e, nan_cnt, max_x, norm_f });
                }
                return e;
            };
            ws.factored_sig = opts.matrix_sig;
        }
        slv.solveNeg(sys.rhs, dx);
        const st = finalizeStep(sys, x, dx, x_old, sys.rhs, v, iter, t, opts);
        if (opdbg()) {
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

fn sysNodeName(sys: anytype, idx: u32) []const u8 {
    const S = Deref(@TypeOf(sys));
    if (comptime @hasDecl(S, "nodeName")) return sys.nodeName(idx);
    return "?";
}

const Step = struct { converged: bool, scaled: f64, flipped: bool = false, why: Reject = .converged };

/// Applies `dx` and runs the acceptance gates in order: device limiting,
/// first iterate, per-row delta, row-scaled residual, device convergence,
/// then state staging.
fn finalizeStep(
    sys: anytype,
    x: []f64,
    dx: []const f64,
    x_old: []f64,
    residual: []const f64,
    vals: []const f64,
    iter: u16,
    t: f64,
    opts: Options,
) Step {
    const S = Deref(@TypeOf(sys));
    const n = sys.n;
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
    for (0..n) |i| {
        const scale = @abs(vals[sys.diag_slots[i]]);
        // A zero diagonal is a voltage-defined branch row (V/E/H source):
        // its scale is the source gain, and an exact solution still leaves
        // O(gain * eps) residual there (a 1e9-gain E source reads 2.7e-8).
        // The delta test alone governs such rows, as in ngspice NIconvTest.
        if (scale == 0) continue;
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        if (@abs(residual[i]) > tol) return .{ .converged = false, .scaled = scaled, .why = .residual };
    }
    if (comptime @hasDecl(S, "checkConvergence")) {
        if (!sys.checkConvergence(x)) return .{ .converged = false, .scaled = scaled, .why = .device };
    }
    // Last, at the x_k `newton` publishes: staging per iterate re-entered every
    // model core once per instance per iteration (18% of
    // scaling/parallel_inverters_100), and devices whose core reads the
    // staged latches (cswitch/vswitch hysteresis) saw F change mid-solve.
    // A device that flips here forces one more iterate.
    if (comptime @hasDecl(S, "updateStates")) {
        if (sys.updateStates(x_old[0..n])) |_| return .{ .converged = false, .scaled = scaled, .flipped = true, .why = .flipped };
    }
    return .{ .converged = true, .scaled = scaled };
}

const gmres_restart = 30;
const sqrt_eps: f64 = 0x1p-26; // sqrt(f64 machine epsilon)
const inf = std.math.inf(f64);

/// Jacobian-free Newton-Krylov: each step solves J dx = -F by restarted-free
/// GMRES(min(30, n)) with finite-difference products J v, right-preconditioned
/// by the factored Jacobian (Jacobi only under ESPICE_SOLVER=jfnk-nolu).
/// Same gates as `newton`, with the residual gate on F. A failed
/// checkpoint returns `error.QueryCancelled`.
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
    const r = ws.dx[0..n]; // becomes dx after the Krylov solve
    const x_old = ws.x_old[0..n];
    const x = x_full[0..n];
    // A null solver is what makes this matrix-free.
    const slv: ?*direct.Solver = if (solverPin() == .jfnk_nolu) null else &ws.slv;

    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();
    @memcpy(x_old, x);

    var iter: u16 = 0;
    while (iter < opts.max_iter) : (iter += 1) {
        if (comptime @hasDecl(S, "checkpoint")) if (iter != 0) {
            sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = opts.max_iter }) catch
                return error.QueryCancelled;
        };
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);

        assembleShifted(sys, x, t, opts, hook);
        @memcpy(f0, sys.rhs[0..n]);
        buildDiagPreconditioner(sys, hook, opts, diag);
        if (slv) |s| {
            const v = hook.vals(sys);
            if (opts.gmin > 0) {
                for (0..n) |i| v[sys.diag_slots[i]] += opts.gmin;
            }
            s.factor(v, executionOf(sys)) catch {};
        }

        // r = -M^-1 f0, beta = ||r||.
        for (r, f0) |*ri, fi| ri.* = -fi;
        applyPreconditioner(r, diag, slv);
        var acc: f64 = 0;
        for (r) |ri| acc += ri * ri;
        const beta = @sqrt(acc);

        if (beta < opts.abstol and residualConverged(sys, hook, x, f0, opts)) {
            @memset(r, 0);
            @memcpy(x_old, x);
            const limited = applyLimits(sys, x, x_old);
            if (iter > 0 and !limited and acceptStep(sys, x))
                return .{ .converged = true, .iterations = iter + 1, .max_dx = 0 };
            continue;
        }

        for (v_basis[0..n], r) |*vi, ri| vi.* = ri / beta;
        g[0] = beta;
        @memset(g[1 .. m + 1], 0);

        // eps_j = sqrt(eps_mach) * max(||x||, 1) / ||v_j||.
        acc = 0;
        for (x) |xi| acc += xi * xi;
        const x_norm = @max(@sqrt(acc), 1.0);

        var jj: usize = 0; // Arnoldi steps completed
        for (0..m) |j| {
            const vj = v_basis[j * n ..][0..n];
            acc = 0;
            for (vj) |vi| acc += vi * vi;
            const v_norm = @sqrt(acc);
            const eps = if (v_norm > 1e-30) sqrt_eps * x_norm / v_norm else sqrt_eps;

            // w = M^-1 (F(x + eps v_j) - f0) / eps.
            for (x_pert, x, vj) |*xp, xi, vi| xp.* = xi + eps * vi;
            assembleShifted(sys, x_pert, t, opts, hook);
            const inv_eps = 1.0 / eps;
            for (w, sys.rhs[0..n], f0) |*wi, ri, fi| wi.* = (ri - fi) * inv_eps;
            applyPreconditioner(w, diag, slv);

            // Modified Gram-Schmidt, sequential dot products.
            for (0..j + 1) |mi| {
                const vi = v_basis[mi * n ..][0..n];
                acc = 0;
                for (vi, w) |a, b| acc += a * b;
                const hij = acc;
                h[mi * m + j] = hij;
                for (w, vi) |*wi, a| wi.* -= hij * a;
            }
            acc = 0;
            for (w) |wi| acc += wi * wi;
            const h_jp1 = @sqrt(acc);
            h[(j + 1) * m + j] = h_jp1;
            if (h_jp1 > 1e-30) {
                for (v_basis[(j + 1) * n ..][0..n], w) |*vi, wi| vi.* = wi / h_jp1;
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
        for (r, 0..) |*ri, i| {
            var dxi: f64 = 0;
            for (0..jj) |kk| dxi += y[kk] * v_basis[kk * n + i];
            ri.* = dxi;
        }

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
        const residual_ok = residualConverged(sys, hook, x, f0, opts);
        // Publishes x_k+1: JFNK is not ngspice's iteration, and its inexact
        // steps leave x_k further out than a direct solve does.
        if (iter > 0 and scaled < 1.0 and residual_ok and !limited and acceptStep(sys, x))
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

    const pin = solverPin();
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

/// Residual at x plus gmin * x into `sys.rhs`.
fn assembleShifted(sys: anytype, x: []const f64, t: f64, opts: Options, hook: anytype) void {
    if (@hasDecl(@TypeOf(hook), "residual"))
        hook.residual(sys, x, t)
    else
        hook.assemble(sys, x, t);
    if (opts.gmin > 0) {
        for (0..x.len) |i| sys.rhs[i] += opts.gmin * x[i];
    }
}

fn buildDiagPreconditioner(sys: anytype, hook: anytype, opts: Options, diag: []f64) void {
    const v = hook.vals(sys);
    for (0..sys.n) |i| {
        var d = v[sys.diag_slots[i]];
        if (opts.gmin > 0) d += opts.gmin;
        diag[i] = if (@abs(d) > 1e-30) 1.0 / d else 1.0;
    }
}

/// r = M^-1 r: the LU when it factored, else the Jacobi diagonal.
fn applyPreconditioner(r: []f64, diag: []const f64, slv: ?*direct.Solver) void {
    if (slv) |s| {
        if (s.factored) {
            s.solve(r, r);
            return;
        }
    }
    for (r, diag) |*ri, d| ri.* *= d;
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
/// non-finite residual or iterate.
fn residualConverged(sys: anytype, hook: anytype, x: []const f64, residual: []const f64, opts: Options) bool {
    var ok = true;
    for (x, residual, 0..) |xi, ri, i| {
        const scale = @abs(hook.diagAt(sys, sys.diag_slots[i]));
        const rt = if (scale == 0) inf else @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(xi) + opts.vntol));
        // Negated comparisons reject NaN too.
        if (!(@abs(ri) <= rt) or !(@abs(xi) < inf)) ok = false;
    }
    return ok;
}

pub const test_access = if (@import("builtin").is_test) .{ .updateAndNorm = updateAndNorm } else {};

/// x_old = x; x += dx; returns max |dx| / (reltol * max(|x|, |x_old|) + atol),
/// atol = abstol on current rows, vntol elsewhere. Max is exact and
/// order-independent, so the vector body and scalar tail agree bitwise with
/// a plain scalar loop.
fn updateAndNorm(x: []f64, dx: []const f64, x_old: []f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    const V = @Vector(W, f64);
    const rel: V = @splat(reltol);
    const abs_i: V = @splat(abstol);
    const abs_v: V = @splat(vntol);
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
        worst_v = @max(worst_v, @abs(d) / tol);
    }
    var worst: f64 = @reduce(.Max, worst_v);
    for (x[i..], dx[i..], x_old[i..], current_row[i..x.len]) |*xi, dxi, *xoi, is_cur| {
        const xo = xi.*;
        xoi.* = xo;
        xi.* = xo + dxi;
        const atol = if (is_cur) abstol else vntol;
        const tol = reltol * @max(@abs(xi.*), @abs(xo)) + atol;
        worst = @max(worst, @abs(dxi) / tol);
    }
    return worst;
}

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

    /// Borrows `col_ptr` and `row_idx` for the workspace's lifetime.
    pub fn init(gpa: std.mem.Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?BbdInfo) !Workspace {
        const dx = try gpa.alloc(f64, n);
        errdefer gpa.free(dx);
        const x_old = try gpa.alloc(f64, n);
        errdefer gpa.free(x_old);
        return .{
            .slv = try direct.Solver.init(gpa, n, col_ptr, row_idx, bbd),
            .dx = dx,
            .x_old = x_old,
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

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.slv.deinit();
        gpa.free(self.dx);
        gpa.free(self.x_old);
        gpa.free(self.gmres);
        gpa.free(self.a_vals);
        self.* = undefined;
    }
};
