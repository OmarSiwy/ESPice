//! Periodic steady state by shooting Newton: find x0 with
//! phi(x0) = x(T; x0) - x0 = 0, integrating one period with fixed-step
//! trapezoid. The Newton system (Phi - I) dx0 = -phi is a dense
//! finite-difference Jacobian below krylov_threshold unknowns, else JFNK GMRES.
const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const num = @import("core").numerics;
const converger = @import("solver").converger;
const integrator = @import("../tran/integrator.zig");
const dense_lu = @import("solver").dense_lu;
const Gmres = @import("solver").gmres.Gmres;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

/// ponytail: node count at which the Newton solve switches from the dense FD
/// Jacobian (n+1 period integrations, O(n^2) storage) to matrix-free GMRES
/// (one integration per matvec).
const krylov_threshold: usize = 50;

pub const Options = @import("core").query.Pss;

/// Outcome of a periodic solve (shared by pss, hb and qpss).
pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    /// Infinity norm of the final residual; inf when an integration failed.
    residual_norm: f64,
};

/// Trapezoidal companion state, reused across every period integration.
const Companion = struct {
    /// q at the previous accepted step.
    q_prev: []f64,
    /// q(x) from the last Newton assemble.
    q_cur: []f64,
    /// Dynamic current of the previous accepted step.
    i_prev: []f64,
    /// G + alpha*C, nnz long.
    a_vals: []f64,
};

/// Newton hook for one fixed step: residual adds
/// alpha*(q(x) - q_prev) - i_prev with alpha = 2/dt, matrix G + alpha*C.
const PeriodHook = struct {
    alpha: f64,
    q_prev: []const f64,
    i_prev: []const f64,
    /// Receives q(x) of each assemble for the accept update.
    q_snap: []f64,
    a_vals: []f64,
    has_charge: bool,

    pub fn assemble(self: PeriodHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.has_charge) {
            const n: usize = ckt.n;
            simdCopy(self.q_snap[0..n], ckt.q_vec[0..n]);
            integrator.companionAt(.trapezoidal, true, ckt.rhs[0..n], ckt.q_vec[0..n], self.q_prev[0..n], &.{}, self.i_prev[0..n], .{ .ag0 = self.alpha, .ag2 = 0 });
        }
    }

    pub fn vals(self: PeriodHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }

    /// One diagonal of the combined matrix without materializing it
    /// (`Circuit.gcAt`); the residual gate calls this per unknown.
    pub fn diagAt(self: PeriodHook, ckt: *root.Circuit, slot: u32) f64 {
        return if (self.has_charge) ckt.gcAt(self.alpha, slot) else ckt.g_vals[slot];
    }
};

/// Integrates x in place over [0, T] in n_samples trapezoid steps. A
/// non-empty `wave` receives n_samples+1 point-major rows
/// [t, v(probes)...] of stride 1 + probes.len. Returns false on the first
/// step whose Newton fails.
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
    const alpha = 2.0 / dt;
    const has_charge = ckt.has_charge;
    const ncols = 1 + probes.len;

    // Sources follow their waveform only under `analysis("tran")` (§4.6.1),
    // so every evaluated point declares the transient phase.
    ckt.setSimState(.{ .t = 0, .dt = dt, .kind = .tran });
    if (has_charge) {
        ckt.eval(x, 0);
        simdCopy(sc.q_prev[0..n], ckt.q_vec[0..n]);
        // Carry the trapezoid state across the period seam: a converged step
        // leaves i_prev = -f(x), so at x0 it is -rhs. A zero seed loses
        // dt*i0/2 of charge per period. Being a function of x0, it sits
        // inside the shooting Jacobian.
        // ponytail: masked to rows with a diagonal C entry, since an unmasked
        // seed rings undamped on algebraic rows; charge without a diagonal C
        // entry keeps a zero seed.
        sc.i_prev[0] = 0;
        for (1..n) |i| sc.i_prev[i] = if (ckt.c_vals[ckt.diag_slots[i]] != 0) -ckt.rhs[i] else 0;
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
            // Accept: i = alpha*(q - q_prev) - i_prev, then q_prev = q.
            integrator.companionAt(.trapezoidal, false, sc.i_prev[0..n], sc.q_cur[0..n], sc.q_prev[0..n], &.{}, sc.i_prev[0..n], .{ .ag0 = alpha, .ag2 = 0 });
            simdCopy(sc.q_prev[0..n], sc.q_cur[0..n]);
        }
        if (wave.len != 0) {
            const row = wave[(k + 1) * ncols ..][0..ncols];
            row[0] = t;
            for (probes, 0..) |node, p| row[1 + p] = x[node];
        }
    }
    return true;
}

/// Integrates one period from x0 into x_end, leaving x0 untouched.
inline fn integrateFrom(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x0: []const f64,
    x_end: []f64,
    options: Options,
) bool {
    simdCopy(x_end, x0);
    return integrateOnePeriod(ckt, ws, sc, x_end, &.{}, &.{}, options);
}

/// GMRES matvec context: one FD directional derivative of the shooting map.
const ShootingKrylovCtx = struct {
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    /// Current shooting iterate.
    x0: []const f64,
    /// phi(x0), already computed.
    phi: []const f64,
    /// Scratch, n long: the perturbed start and its endpoint.
    x_pert: []f64,
    x_end_pert: []f64,
    options: Options,
    n: usize,

    pub const matvec = shootingMatvec;
};

/// w = (Phi - I) v by one FD period integration:
/// w = (phi(x0 + eps*v) - phi(x0)) / eps. A failed integration returns
/// w = 0, which GMRES treats as a null direction.
fn shootingMatvec(ctx: *ShootingKrylovCtx, v: []const f64, w: []f64) void {
    const n = ctx.n;
    const inv_eps = 1.0 / ctx.options.fd_epsilon;

    simdCopy(ctx.x_pert[0..n], ctx.x0[0..n]);
    num.axpy(ctx.x_pert[0..n], ctx.options.fd_epsilon, v[0..n]);

    if (!integrateFrom(ctx.ckt, ctx.ws, ctx.sc, ctx.x_pert, ctx.x_end_pert, ctx.options)) {
        // ponytail: a zero column is safer than propagating NaN.
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

/// Dense path: builds the FD Jacobian of phi column by column (n period
/// integrations) into `j_phi` (n*n, row-major) and solves for dx0. A column
/// whose integration fails becomes the identity column.
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
) !void {
    const eps = options.fd_epsilon;
    const inv_eps = 1.0 / eps;

    for (0..n) |j| {
        simdCopy(x0_pert[0..n], x0[0..n]);
        x0_pert[j] += eps;

        if (!integrateFrom(ckt, ws, sc, x0_pert, x_end_pert, options)) {
            for (0..n) |row| j_phi[row * n + j] = if (row == j) @as(f64, 1.0) else @as(f64, 0.0);
            continue;
        }

        // Column j is stride n in row-major J, so the store stays scalar.
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

    try dense_lu.factorizeSolveNeg(n, j_phi, phi[0..n], dx0);
}

/// Krylov path: solves (Phi - I) dx0 = -phi with matrix-free GMRES from a
/// zero start.
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
) void {
    num.scale(neg_phi[0..n], -1.0, phi[0..n]);

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
    };

    simdZero(dx0[0..n]);

    _ = krylov.solve(&ctx, neg_phi[0..n], dx0[0..n], options.gmres_tol, options.gmres_max_restarts);
}

/// Shooting Newton from x_dc. A non-empty `wave`, sized
/// (n_samples+1) * (1 + probes.len), receives point-major rows
/// [t, v(probes)...] of one period from the final x0, converged or not; it is
/// left zeroed if that integration fails.
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

    // One block for the whole continuation, every size known up front:
    //   x0, x_end, phi, x0_pert, x_end_pert, dx0   6n
    //   q_prev, q_cur, i_prev                      3n
    //   a_vals                                     nnz
    //   j_phi (dense) or neg_phi (Krylov)          n*n or n
    const dense_extra = if (!use_krylov) n * n else 0;
    const krylov_extra = if (use_krylov) n else 0;
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

    // The unused path's buffer slices the arena to zero length so both stay
    // mutable []f64.
    const j_phi = if (!use_krylov) arena[off..][0 .. n * n] else arena[0..0];
    const neg_phi = if (use_krylov) arena[off..][0..n] else arena[0..0];

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
        if (!integrateFrom(ckt, ws, &sc, x0, x_end, options)) {
            return .{
                .converged = false,
                .iterations = iter,
                .residual_norm = std.math.inf(f64),
            };
        }

        // x_end + (-1)*x0 is exactly x_end - x0.
        simdCopy(phi, x_end);
        num.axpy(phi, -1.0, x0);

        res_norm = num.normInf(phi);
        if (res_norm < options.shooting_tol) break;

        if (use_krylov) {
            // ponytail: unpreconditioned; add an ILU preconditioner if GMRES stalls.
            krylovSolve(ckt, ws, &sc, n, x0, phi, x0_pert, x_end_pert, dx0, neg_phi, &krylov.?, options);
        } else {
            try denseFdSolve(ckt, ws, &sc, n, x0, phi, x0_pert, x_end_pert, dx0, j_phi, options);
        }

        num.axpy(x0, 1.0, dx0);
    }

    simdCopy(x_end, x0);
    _ = integrateOnePeriod(ckt, ws, &sc, x_end, probes, wave, options);

    return .{
        .converged = res_norm < options.shooting_tol,
        .iterations = iter,
        .residual_norm = res_norm,
    };
}

/// Contract entry: shoot from ctx.x_op and return one period as point-major
/// rows (time, probes...), n_samples+1 of them. Non-convergence prints a
/// warning and still returns the last period.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;

    const names = try root.probeNames(ctx, "time");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "time" literal
        a.free(names);
    }
    const ncols = names.len;
    const npoints: usize = @as(usize, opts.n_samples) + 1;
    const data = try a.alloc(f64, npoints * ncols);
    errdefer a.free(data);

    const res = try solve(ctx.circuit, x_op, ctx.probes, data, opts, ctx.scratch_allocator);
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
    .krylov_threshold = krylov_threshold,
    .shootingMatvec = shootingMatvec,
    .simdCopy = simdCopy,
    .simdZero = simdZero,
} else {};
