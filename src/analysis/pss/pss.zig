//! Periodic Steady State via the shooting Newton method.
//!
//! Given a circuit driven at frequency f = 1/T, finds the initial condition
//! x0 such that integrating one full period returns to x0:
//!
//!   phi(x0) = x(T; x0) - x0 = 0
//!
//! Newton iteration on phi:
//!   J_phi * dx0 = -phi(x0)
//!   x0 <- x0 + dx0
//!
//! Two paths for the linear solve:
//!
//!   n < 50:  Dense FD Jacobian — J[:,j] built column-by-column via n+1
//!            period integrations, solved with dense LU.
//!
//!   n >= 50: JFNK / matrix-free Krylov — each GMRES matvec is one FD
//!            directional derivative (one period integration), so total
//!            cost is ~m period integrations per Newton step (m << n).
//!
//! The inner integration is fixed-step trapezoidal (n_samples steps per
//! period), so every buffer size is known up front: one scratch arena for
//! the whole shooting continuation, zero growth.
//!
//! GPU acceleration: when ckt.gpu_hook.simulate_tran is available, each
//! period integration dispatches to the GPU transient megakernel, bypassing
//! per-step host round-trips. Falls back to CPU on any error.
const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const tran = @import("../tran/tran.zig");
const converger = @import("solvers").converger;
const dense_lu = @import("solvers").dense_lu;
const Gmres = @import("solvers").gmres.Gmres(f64);

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

/// ponytail: threshold for switching from dense FD Jacobian to GMRES Krylov.
/// Below this, the O(n^2) dense path is cheaper than Krylov overhead.
const krylov_threshold: usize = 50;

pub const Options = @import("requests").Pss;

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    residual_norm: f64,
};

// ---------------------------------------------------------------------------
// SIMD arithmetic helpers
// ---------------------------------------------------------------------------

/// dst[i] = a[i] + b[i], SIMD.
inline fn simdAdd(dst: []f64, a: []const f64, b: []const f64) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const va: V = a[i..][0..W].*;
        const vb: V = b[i..][0..W].*;
        dst[i..][0..W].* = va + vb;
    }
    while (i < n) : (i += 1) dst[i] = a[i] + b[i];
}

/// dst[i] = a[i] - b[i], SIMD.
inline fn simdSub(dst: []f64, a: []const f64, b: []const f64) void {
    const n = @min(dst.len, @min(a.len, b.len));
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const va: V = a[i..][0..W].*;
        const vb: V = b[i..][0..W].*;
        dst[i..][0..W].* = va - vb;
    }
    while (i < n) : (i += 1) dst[i] = a[i] - b[i];
}

/// dst[i] += scale * src[i], SIMD.
inline fn simdAxpy(dst: []f64, scale: f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    const sv: V = @splat(scale);
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const d: V = dst[i..][0..W].*;
        const s: V = src[i..][0..W].*;
        dst[i..][0..W].* = d + sv * s;
    }
    while (i < n) : (i += 1) dst[i] += scale * src[i];
}

/// dst[i] = scale * src[i], SIMD.
inline fn simdScale(dst: []f64, scale: f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    const sv: V = @splat(scale);
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const s: V = src[i..][0..W].*;
        dst[i..][0..W].* = sv * s;
    }
    while (i < n) : (i += 1) dst[i] = scale * src[i];
}

/// ||v||_inf
pub inline fn normInf(buf: []const f64) f64 {
    var mx: f64 = 0;
    for (buf) |v| mx = @max(mx, @abs(v));
    return mx;
}

// ---------------------------------------------------------------------------
// Trapezoidal companion state, reused across every Newton/shooting pass
// ---------------------------------------------------------------------------

const Companion = struct {
    q_prev: []f64, // q at the previous accepted step
    q_cur: []f64, // q(x) captured from the last Newton assemble
    i_prev: []f64, // trap dynamic current of the previous accepted step
    a_vals: []f64, // G + alpha*C scratch (nnz)
};

/// Newton hook for one fixed timestep: companion RHS from the q plane,
/// matrix = G + alpha*C.
///   trap residual: F_dyn = alpha*(q(x) - q_prev) - i_prev,  alpha = 2/dt.
const PeriodHook = struct {
    alpha: f64,
    q_prev: []const f64,
    i_prev: []const f64,
    q_snap: []f64, // captures q(x) from the last Newton iter for the accept update
    a_vals: []f64,
    has_charge: bool,

    pub fn assemble(self: PeriodHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.has_charge) {
            const n: usize = ckt.n;
            // q_vec now holds q(x) for this iteration — snapshot for accept.
            simdCopy(self.q_snap[0..n], ckt.q_vec[0..n]);
            const av: V = @splat(self.alpha);
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const r: V = ckt.rhs[i..][0..W].*;
                const qv: V = ckt.q_vec[i..][0..W].*;
                const qp: V = self.q_prev[i..][0..W].*;
                const ip: V = self.i_prev[i..][0..W].*;
                ckt.rhs[i..][0..W].* = r + av * (qv - qp) - ip;
            }
            while (i < n) : (i += 1)
                ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]) - self.i_prev[i];
        }
    }

    pub fn vals(self: PeriodHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }
    /// One diagonal, without materializing the whole combined plane —
    /// see `Circuit.gcAt`. The residual gate calls this per unknown.
    pub fn diagAt(self: PeriodHook, ckt: *root.Circuit, slot: u32) f64 {
        return if (self.has_charge) ckt.gcAt(self.alpha, slot) else ckt.g_vals[slot];
    }
};

/// Integrate the circuit from x (in place) over one period [0, T] with
/// n_samples fixed trapezoidal steps. When `wave` is non-empty it receives
/// point-major rows [t, v(probes[0]), v(probes[1]), ...] with stride
/// 1 + probes.len — n_samples+1 rows total (t=0 included).
/// Returns false if any timestep's Newton fails to converge.
fn integrateOnePeriod(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x: []f64,
    probes: []const u32,
    wave: []f64,
    options: Options,
) bool {
    const n: usize = ckt.n;
    const steps: usize = options.n_samples;
    const dt = options.period / @as(f64, @floatFromInt(steps));
    const alpha = 2.0 / dt; // trapezoidal companion coefficient
    const has_charge = ckt.has_charge;
    const ncols = 1 + probes.len;

    // §4.6.1: a source waveform only exists while `analysis("tran")` is
    // true. PSS inherited whatever phase the shared operating point left
    // behind, so every SIN/PULSE/PWL card answered with its DC value and the
    // shooting loop converged on an UNDRIVEN circuit — `pss/rc_*` printed
    // zeros for a deck with a 1 kHz drive. The phase has to be re-declared at
    // every point the loop evaluates, exactly as tran.zig does.
    ckt.setSimState(.{ .t = 0, .dt = dt, .kind = .tran });
    if (has_charge) {
        ckt.eval(x, 0);
        simdCopy(sc.q_prev[0..n], ckt.q_vec[0..n]);
        simdZero(sc.i_prev[0..n]);
    }
    if (wave.len != 0) {
        const row = wave[0..ncols];
        row[0] = 0;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
    }

    for (0..steps) |k| {
        const t = options.period * @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(steps));
        const hook = PeriodHook{
            .alpha = alpha,
            .q_prev = sc.q_prev,
            .i_prev = sc.i_prev,
            .q_snap = sc.q_cur,
            .a_vals = sc.a_vals,
            .has_charge = has_charge,
        };
        ckt.setSimState(.{ .t = t, .dt = dt, .kind = .tran });
        const nr = converger.run(ckt, ws, x, t, .{
            .max_iter = options.max_newton_iter,
            .abstol = options.newton_tol,
            .dx_clamp = std.math.inf(f64),
        }, hook) catch return false;
        if (!nr.converged) return false;

        if (has_charge) {
            // Accept: trap dynamic current i = alpha*(q - q_prev) - i_prev,
            // then rotate the charge history via copy (no std.mem.swap).
            const av: V = @splat(alpha);
            var j: usize = 0;
            while (j + W <= n) : (j += W) {
                const q0: V = sc.q_cur[j..][0..W].*;
                const q1: V = sc.q_prev[j..][0..W].*;
                const ip: V = sc.i_prev[j..][0..W].*;
                sc.i_prev[j..][0..W].* = av * (q0 - q1) - ip;
                sc.q_prev[j..][0..W].* = q0;
            }
            while (j < n) : (j += 1) {
                sc.i_prev[j] = alpha * (sc.q_cur[j] - sc.q_prev[j]) - sc.i_prev[j];
                sc.q_prev[j] = sc.q_cur[j];
            }
        }
        if (wave.len != 0) {
            const row = wave[(k + 1) * ncols ..][0..ncols];
            row[0] = t;
            for (probes, 0..) |node, p| row[1 + p] = x[node];
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// GPU period integration — uses simulate_tran for the whole period as one
// chunked transient, bypassing per-step host round-trips.
// ---------------------------------------------------------------------------

/// Try to integrate one period on GPU via simulate_tran. Returns true if GPU
/// succeeded and x now holds x(T). Returns false if GPU is unavailable or
/// errored — caller should fall back to CPU integrateOnePeriod.
/// ponytail: minimal waveform (capacity 1, 0 probes) — we only need x(T).
fn gpuIntegrateOnePeriod(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) bool {
    const gh = ckt.gpu_hook orelse return false;
    const gt = gh.simulate_tran orelse return false;

    var wf = tran.Waveform.init(allocator, 0, 1) catch return false;
    defer wf.deinit();

    const tran_opts = tran.Options{
        .tol = options.tol,
        .t_stop = options.period,
        .dt_init = options.period / @as(f64, @floatFromInt(options.n_samples)),
        .method = .trapezoidal,
        .max_steps = @as(u32, options.n_samples) * 4, // ponytail: headroom for adaptive dt
    };

    const result = gt(gh.ctx, x, &.{}, &wf, tran_opts) catch return false;
    return result.completed;
}

/// Integrate a shooting trial, restoring the IC before CPU fallback because a
/// failed GPU attempt may already have changed x_end.
inline fn integrateFrom(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x0: []const f64,
    x_end: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) bool {
    simdCopy(x_end, x0);
    if (gpuIntegrateOnePeriod(ckt, x_end, options, allocator)) return true;
    simdCopy(x_end, x0);
    return integrateOnePeriod(ckt, ws, sc, x_end, &.{}, &.{}, options);
}

// ---------------------------------------------------------------------------
// JFNK / Krylov shooting context — matrix-free (Phi - I) * v via FD
// ---------------------------------------------------------------------------

/// Context passed to GMRES matvec: carries everything needed to compute
/// one FD directional derivative of the shooting map (Phi - I).
const ShootingKrylovCtx = struct {
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x0: []const f64, // current shooting iterate
    phi: []const f64, // phi(x0) = x(T;x0) - x0, already computed
    x_pert: []f64, // scratch: perturbed initial condition (n)
    x_end_pert: []f64, // scratch: perturbed endpoint (n)
    options: Options,
    n: usize,
    allocator: std.mem.Allocator,
};

/// GMRES matvec: w = (Phi - I) * v via one FD period integration.
///
///   x_pert = x0 + eps * v
///   integrate x_pert over [0,T] → x_end_pert
///   phi_pert = x_end_pert - x_pert   (= Phi(x0+eps*v) - (x0+eps*v))
///   w = (phi_pert - phi) / eps        ≈ (Phi-I)' * v
fn shootingMatvec(v: []const f64, w: []f64, ctx_ptr: *anyopaque) void {
    const ctx: *ShootingKrylovCtx = @ptrCast(@alignCast(ctx_ptr));
    const n = ctx.n;
    const inv_eps = 1.0 / ctx.options.fd_epsilon;

    simdCopy(ctx.x_pert[0..n], ctx.x0[0..n]);
    simdAxpy(ctx.x_pert[0..n], ctx.options.fd_epsilon, v[0..n]);

    const ok = integrateFrom(ctx.ckt, ctx.ws, ctx.sc, ctx.x_pert, ctx.x_end_pert, ctx.options, ctx.allocator);

    if (!ok) {
        // ponytail: perturbed integration failed — return zero vector so
        // GMRES treats this direction as null. Safer than NaN propagation.
        simdZero(w[0..n]);
        return;
    }

    const inv_v: V = @splat(inv_eps);
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const xe: V = ctx.x_end_pert[i..][0..W].*;
        const xp: V = ctx.x_pert[i..][0..W].*;
        const ph: V = ctx.phi[i..][0..W].*;
        w[i..][0..W].* = ((xe - xp) - ph) * inv_v;
    }
    while (i < n) : (i += 1) {
        const phi_pert = ctx.x_end_pert[i] - ctx.x_pert[i];
        w[i] = (phi_pert - ctx.phi[i]) * inv_eps;
    }
}

// ---------------------------------------------------------------------------
// Dense FD Jacobian path (n < krylov_threshold)
// ---------------------------------------------------------------------------

/// Build the dense FD Jacobian and solve with LU.
fn denseFdSolve(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    n: usize,
    x0: []const f64,
    phi: []const f64,
    x0_pert: []f64,
    x_end_pert: []f64,
    dx0: []f64,
    j_phi: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const eps = options.fd_epsilon;
    const inv_eps = 1.0 / eps;

    for (0..n) |j| {
        simdCopy(x0_pert[0..n], x0[0..n]);
        x0_pert[j] += eps;

        const ok = integrateFrom(ckt, ws, sc, x0_pert, x_end_pert, options, allocator);

        if (!ok) {
            // If perturbed integration fails, use identity column as fallback
            for (0..n) |row| j_phi[row * n + j] = if (row == j) @as(f64, 1.0) else @as(f64, 0.0);
            continue;
        }

        // Column-j writes are stride-n (row-major J), so the store is scalar
        // even though the subtract is SIMD.
        {
            const inv_v: V = @splat(inv_eps);
            var row: usize = 0;
            while (row + W <= n) : (row += W) {
                const xep: V = x_end_pert[row..][0..W].*;
                const x0p: V = x0_pert[row..][0..W].*;
                const pv: V = phi[row..][0..W].*;
                const diff: V = (xep - x0p - pv) * inv_v;
                const arr: [W]f64 = diff;
                for (0..W) |w| j_phi[(row + w) * n + j] = arr[w];
            }
            while (row < n) : (row += 1) {
                const pp = x_end_pert[row] - x0_pert[row];
                j_phi[row * n + j] = (pp - phi[row]) * inv_eps;
            }
        }
    }

    // ponytail: LU reads phi and writes the separate dx0 slab; no RHS copy needed.
    try dense_lu.factorizeSolveNeg(n, j_phi, phi[0..n], dx0);
}

// ---------------------------------------------------------------------------
// Krylov (GMRES) path (n >= krylov_threshold)
// ---------------------------------------------------------------------------

/// Solve (Phi - I) * dx0 = -phi using matrix-free GMRES.
fn krylovSolve(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    n: usize,
    x0: []const f64,
    phi: []const f64,
    x_pert: []f64,
    x_end_pert: []f64,
    dx0: []f64,
    neg_phi: []f64,
    krylov: *Gmres,
    options: Options,
    allocator: std.mem.Allocator,
) void {
    simdScale(neg_phi[0..n], -1.0, phi[0..n]);

    var ctx = ShootingKrylovCtx{
        .ckt = ckt,
        .ws = ws,
        .sc = sc,
        .x0 = x0,
        .phi = phi,
        .x_pert = x_pert,
        .x_end_pert = x_end_pert,
        .options = options,
        .n = n,
        .allocator = allocator,
    };

    simdZero(dx0[0..n]);

    _ = krylov.solve(
        &shootingMatvec,
        @ptrCast(&ctx),
        null,
        null,
        neg_phi[0..n],
        dx0[0..n],
        options.gmres_tol,
        options.gmres_max_restarts,
    );
}

/// Fine-grained primitive: shooting Newton into caller-owned `wave`.
/// wave layout: (n_samples+1) point-major rows [t, v(probe)...], stride
/// 1 + probes.len (pass an empty slice to skip waveform recording).
/// The final converged waveform over [0, T] is written regardless of
/// convergence status; on inner integration failure it is left zeroed.
pub fn solve(
    ckt: *root.Circuit,
    x_dc: []const f64,
    probes: []const u32,
    wave: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;
    const ncols = 1 + probes.len;
    std.debug.assert(wave.len == 0 or wave.len == (@as(usize, options.n_samples) + 1) * ncols);
    simdZero(wave);

    const use_krylov = n >= krylov_threshold;

    // One scratch arena for the whole shooting continuation. Layout (f64):
    //   x0, x_end, phi, x0_pert, x_end_pert, dx0  — 6*n
    //   q_prev, q_cur, i_prev                      — 3*n (companion)
    //   a_vals                                     — nnz (G + alpha*C)
    //   Dense path: j_phi — n*n (dense Jacobian of phi)
    //   Krylov path: neg_phi — n (GMRES RHS)
    const dense_extra = if (!use_krylov) n * n else 0;
    const krylov_extra = if (use_krylov) n else 0; // neg_phi
    const arena = try allocator.alloc(f64, 9 * n + nnz + dense_extra + krylov_extra);
    defer allocator.free(arena);
    var off: usize = 0;
    const x0 = arena[off..][0..n];
    off += n;
    const x_end = arena[off..][0..n];
    off += n;
    const phi = arena[off..][0..n];
    off += n;
    const x0_pert = arena[off..][0..n];
    off += n;
    const x_end_pert = arena[off..][0..n];
    off += n;
    const dx0 = arena[off..][0..n];
    off += n;
    var sc = Companion{
        .q_prev = arena[off..][0..n],
        .q_cur = arena[off + n ..][0..n],
        .i_prev = arena[off + 2 * n ..][0..n],
        .a_vals = arena[off + 3 * n ..][0..nnz],
    };
    off += 3 * n + nnz;

    // Path-specific workspace. Empty branch slices the arena (not a const
    // literal) so both arms stay []f64 — the callees write through these.
    const j_phi = if (!use_krylov) arena[off..][0 .. n * n] else arena[0..0];
    const neg_phi = if (use_krylov) arena[off..][0..n] else arena[0..0];

    // GMRES instance for the Krylov path — allocated once, reused every
    // shooting iteration.
    var krylov: ?Gmres = null;
    if (use_krylov) {
        const m = @min(options.gmres_restart, @as(u32, @intCast(n)));
        krylov = try Gmres.init(allocator, @intCast(n), m);
    }
    defer if (krylov) |*k| k.deinit(allocator);

    try ckt.computeBaseline();
    const ws = try ckt.workspace();

    simdCopy(x0, x_dc[0..n]);

    var iter: u16 = 0;
    var res_norm: f64 = std.math.inf(f64);

    while (iter < options.max_shooting_iter) : (iter += 1) {
        if (iter != 0) try ckt.checkpoint(.{ .phase = .periodic, .completed = iter });
        const period_ok = integrateFrom(ckt, ws, &sc, x0, x_end, options, allocator);

        if (!period_ok) {
            return .{
                .converged = false,
                .iterations = iter,
                .residual_norm = std.math.inf(f64),
            };
        }

        simdSub(phi, x_end, x0);

        res_norm = normInf(phi);
        if (res_norm < options.shooting_tol) break;

        // Solve (Phi - I) * dx0 = -phi
        if (use_krylov) {
            // ponytail: Krylov path — ~m period integrations per Newton step
            // instead of n+1. Upgrade: ILU preconditioner if GMRES stalls.
            krylovSolve(
                ckt,
                ws,
                &sc,
                n,
                x0,
                phi,
                x0_pert,
                x_end_pert,
                dx0,
                neg_phi,
                &krylov.?,
                options,
                allocator,
            );
        } else {
            try denseFdSolve(
                ckt,
                ws,
                &sc,
                n,
                x0,
                phi,
                x0_pert,
                x_end_pert,
                dx0,
                j_phi,
                options,
                allocator,
            );
        }

        simdAdd(x0, x0, dx0);
    }

    // Record the final periodic waveform from the converged x0.
    simdCopy(x_end, x0);
    _ = integrateOnePeriod(ckt, ws, &sc, x_end, probes, wave, options);

    return .{
        .converged = res_norm < options.shooting_tol,
        .iterations = iter,
        .residual_norm = res_norm,
    };
}

/// Contract entry: shoot from ctx.x_op, one time-domain period per probe.
/// Data layout: point-major rows (time, probes...), n_samples+1 rows.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const names = try root.probeNames(ctx, "time");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "time" literal
        a.free(names);
    }
    const ncols = names.len;
    const npoints: usize = @as(usize, opts.n_samples) + 1;
    const data = try a.alloc(f64, npoints * ncols);
    errdefer a.free(data);

    // `solve` writes the caller's `data` and frees everything else it takes;
    // `a` is a results arena that cannot reclaim it. See
    // RunCtx.scratch_allocator.
    const res = try solve(ctx.circuit, x_op, ctx.probes, data, opts, ctx.scratch_allocator orelse a);
    if (!res.converged)
        std.debug.print("Warning: pss: shooting did not converge (residual {e})\n", .{res.residual_norm});

    return .{
        .plotname = "Periodic Steady State",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .gpuIntegrateOnePeriod = gpuIntegrateOnePeriod,
    .krylov_threshold = krylov_threshold,
    .shootingMatvec = shootingMatvec,
    .simdAdd = simdAdd,
    .simdAxpy = simdAxpy,
    .simdCopy = simdCopy,
    .simdScale = simdScale,
    .simdSub = simdSub,
    .simdZero = simdZero,
} else {};
