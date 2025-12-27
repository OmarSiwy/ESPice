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
//! J_phi is approximated column-by-column via finite differences over the
//! flow map (one transient run per column) — this stays FD by construction;
//! the analytic planes give the Jacobian of F, not of the period map.
//!
//! The inner integration is fixed-step trapezoidal (n_samples steps per
//! period), so every buffer size is known up front: one scratch arena for
//! the whole shooting continuation, zero growth.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
const dense_lu = root.solvers.dense_lu;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = struct {
    tol: converger.Tolerances = .{},
    period: f64,
    max_shooting_iter: u16 = 50,
    shooting_tol: f64 = 1e-7,
    fd_epsilon: f64 = 1e-7,
    max_newton_iter: u16 = 50,
    newton_tol: f64 = 1e-9,
    /// Fixed trapezoidal steps per period; the waveform has n_samples+1 rows.
    n_samples: u32 = 256,
};

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    residual_norm: f64,
};

/// Trapezoidal companion state, reused across every Newton/shooting pass.
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
    has_history: bool,

    pub fn assemble(self: PeriodHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.has_charge) {
            const n: usize = ckt.n;
            // q_vec now holds q(x) for this iteration — snapshot for accept.
            @memcpy(self.q_snap[0..n], ckt.q_vec[0..n]);
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
        if (self.has_history) ckt.injectHistory(t);
    }

    pub fn vals(self: PeriodHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
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
    const has_history = ckt.has_history;
    const ncols = 1 + probes.len;

    if (has_charge) {
        ckt.eval(x, 0);
        @memcpy(sc.q_prev[0..n], ckt.q_vec[0..n]);
        @memset(sc.i_prev, 0);
    }
    if (has_history) ckt.recordHistory(x, 0);
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
            .has_history = has_history,
        };
        const nr = converger.run(ckt, ws, x, t, .{
            .max_iter = options.max_newton_iter,
            .abstol = options.newton_tol,
            .dx_clamp = std.math.inf(f64),
        }, hook) catch return false;
        if (!nr.converged) return false;

        if (has_charge) {
            // Accept: trap dynamic current i = alpha*(q - q_prev) - i_prev,
            // then rotate the charge history by pointer swap.
            const av: V = @splat(alpha);
            var j: usize = 0;
            while (j + W <= n) : (j += W) {
                const q0: V = sc.q_cur[j..][0..W].*;
                const q1: V = sc.q_prev[j..][0..W].*;
                const ip: V = sc.i_prev[j..][0..W].*;
                sc.i_prev[j..][0..W].* = av * (q0 - q1) - ip;
            }
            while (j < n) : (j += 1)
                sc.i_prev[j] = alpha * (sc.q_cur[j] - sc.q_prev[j]) - sc.i_prev[j];
            std.mem.swap([]f64, &sc.q_prev, &sc.q_cur);
        }
        if (has_history) ckt.recordHistory(x, t);
        if (wave.len != 0) {
            const row = wave[(k + 1) * ncols ..][0..ncols];
            row[0] = t;
            for (probes, 0..) |node, p| row[1 + p] = x[node];
        }
    }
    return true;
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
    @memset(wave, 0);

    // One scratch arena for the whole shooting continuation. Layout (f64):
    //   x0, x_end, phi, x0_pert, x_end_pert, phi_pert, dx0  — 7*n
    //   q_prev, q_cur, i_prev                               — 3*n (companion)
    //   a_vals                                              — nnz (G + alpha*C)
    //   j_phi                                               — n*n (dense Jacobian of phi)
    const arena = try allocator.alloc(f64, 10 * n + nnz + n * n);
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
    const phi_pert = arena[off..][0..n];
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
    const j_phi = arena[off..][0 .. n * n];

    try ckt.computeBaseline();
    const ws = try ckt.workspace();

    // Initialize x0 from DC operating point
    @memcpy(x0, x_dc[0..n]);

    var iter: u16 = 0;
    var res_norm: f64 = std.math.inf(f64);

    while (iter < options.max_shooting_iter) : (iter += 1) {
        // Integrate from x0 over [0, T] to get x(T)
        @memcpy(x_end, x0);
        if (!integrateOnePeriod(ckt, ws, &sc, x_end, &.{}, &.{}, options)) {
            return .{
                .converged = false,
                .iterations = iter,
                .residual_norm = std.math.inf(f64),
            };
        }

        // Compute phi(x0) = x(T) - x0
        for (0..n) |j| phi[j] = x_end[j] - x0[j];

        // Check convergence: ||phi||_inf
        res_norm = 0;
        for (0..n) |j| res_norm = @max(res_norm, @abs(phi[j]));

        if (res_norm < options.shooting_tol) break;

        // Build Jacobian via finite differences: J[:,j] = (phi(x0+eps*e_j) - phi(x0)) / eps
        const eps = options.fd_epsilon;
        for (0..n) |j| {
            @memcpy(x0_pert, x0);
            x0_pert[j] += eps;

            @memcpy(x_end_pert, x0_pert);
            if (!integrateOnePeriod(ckt, ws, &sc, x_end_pert, &.{}, &.{}, options)) {
                // If perturbed integration fails, use identity column as fallback
                for (0..n) |row| j_phi[row * n + j] = if (row == j) @as(f64, 1.0) else @as(f64, 0.0);
                continue;
            }

            for (0..n) |row| {
                phi_pert[row] = x_end_pert[row] - x0_pert[row];
                j_phi[row * n + j] = (phi_pert[row] - phi[row]) / eps;
            }
        }

        // Solve J_phi * dx0 = -phi using dense LU
        try dense_lu.factorizeSolveNeg(n, j_phi, phi, dx0);

        // Update x0
        for (0..n) |j| x0[j] += dx0[j];
    }

    // Record the final periodic waveform from the converged x0.
    @memcpy(x_end, x0);
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
    const ncols = names.len;
    const npoints: usize = @as(usize, opts.n_samples) + 1;
    const data = try a.alloc(f64, npoints * ncols);

    const res = try solve(ctx.circuit, x_op, ctx.probes, data, opts, a);
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
