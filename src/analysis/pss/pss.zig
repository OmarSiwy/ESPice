//! Periodic steady state by shooting Newton: find x0 with
//! phi(x0) = x(T; x0) - x0 = 0, integrating one period with fixed-step
//! trapezoid. The Newton system (Phi - I) dx0 = -phi is a dense
//! finite-difference Jacobian below krylov_threshold unknowns, else JFNK GMRES.
//!
//! An autonomous circuit (an oscillator, `Options.osc_node` set) has no
//! period to impose. There T joins the unknowns and the oscillator node's
//! x0 leaves them: its value stays pinned at t = 0, which fixes the phase
//! the time shift would otherwise leave free. The Jacobian keeps its n x n
//! shape, the osc column holding d(phi)/d(ln T) instead of d(phi)/d(x0[osc]).
//!
//! Cites: dev/analysis/pss-shooting-harmonic-balance.md, Verilog-A LRM
//! §4.6.1 (sources follow their waveform only in the transient phase).
const std = @import("std");
const root = @import("../types.zig");
const take = root.take;
const num = @import("core").numerics;
const converger = @import("solver").converger;
const integrator = @import("../tran/integrator.zig");
const dense_lu = @import("solver").dense_lu;
const Gmres = @import("solver").gmres.Gmres;
const solver = @import("solver");
const Lanes = solver.lanes.Lanes;

/// The lane system one period's step Newtons run on: each lane's own
/// circuit and its own `PeriodHook` (phase 3's per-lane hooks).
fn LaneSys(comptime W: usize) type {
    return solver.lane_system.LaneSystem(W, root.Circuit, PeriodHook);
}

/// ponytail: node count at which the Newton solve switches from the dense FD
/// Jacobian (n+1 period integrations, O(n^2) storage) to matrix-free GMRES
/// (one integration per matvec).
const krylov_threshold: usize = 50;

/// Guess periods an autonomous solve records to measure the period from.
const measure_periods: usize = 8;

/// The largest relative period change one autonomous Newton step takes;
/// a longer step is shortened, all unknowns together.
const max_period_step: f64 = 0.2;

/// Volts the oscillator node is pushed off its DC equilibrium to start it.
const osc_kick: f64 = 1e-3;

/// Cap on the periods an autonomous start settles past
/// `osc_settle_periods` while the swing still grows by over 1 % a period.
const max_settle_periods: usize = 2000;

/// The `.pss` query. With `osc_node` set, `period` is only the first guess.
pub const Options = @import("core").query.Pss;

/// Outcome of a periodic solve (shooting, HB, multi-tone HB and qpss).
pub const SolveResult = struct {
    converged: bool,
    /// Newton (shooting or spectral) iterations taken.
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
const PeriodHook = integrator.Hook(.trapezoidal);

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
) error{ QueryCancelled, OutOfMemory }!bool {
    const steps: usize = options.n_samples;
    const dt = options.period / @as(f64, @floatFromInt(steps));
    periodStart(ckt, sc, x, probes, wave, options);
    for (0..steps) |k| {
        const t = stepTime(options, k);
        const hook = periodHook(sc, 2.0 / dt, ckt.has_charge);
        ckt.setSimState(.{ .t = t, .dt = dt, .kind = .tran });
        const nr = converger.run(ckt, ws, x, t, .{
            .max_iter = options.max_newton_iter,
            .abstol = options.newton_tol,
        }, hook) catch |err| switch (err) {
            error.QueryCancelled, error.OutOfMemory => |e| return e,
            else => null, // else: a numerical failure fails the period
        };
        if (!periodAccept(ckt, &hook, x, probes, wave, k, t, nr != null and nr.?.converged)) return false;
    }
    return true;
}

/// `integrateOnePeriod`'s start: the transient-phase sim state, the
/// trapezoid seam state at x, and the t = 0 wave row.
fn periodStart(ckt: *root.Circuit, sc: *Companion, x: []const f64, probes: []const u32, wave: []f64, options: Options) void {
    const n: usize = ckt.n;
    const dt = options.period / @as(f64, @floatFromInt(options.n_samples));
    // Sources follow their waveform only under `analysis("tran")` (§4.6.1),
    // so every evaluated point declares the transient phase.
    ckt.setSimState(.{ .t = 0, .dt = dt, .kind = .tran });
    if (ckt.has_charge) {
        ckt.eval(x, 0);
        num.copySimd(sc.q_prev[0..n], ckt.q_vec[0..n]);
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
        const row = wave[0 .. 1 + probes.len];
        row[0] = 0;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
    }
}

/// The end time of step k of a period.
fn stepTime(options: Options, k: usize) f64 {
    return options.period * @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(options.n_samples));
}

/// The companion hook of one step at `alpha` = 2/dt.
fn periodHook(sc: *Companion, alpha: f64, has_charge: bool) PeriodHook {
    return .{
        .method = {},
        .c = .{ .ag0 = alpha, .ag2 = 0 },
        .q_prev = sc.q_prev,
        .i_prev = sc.i_prev,
        .q_cur = sc.q_cur,
        .a_vals = sc.a_vals,
        .has_charge = has_charge,
    };
}

/// Step k's end: a failed Newton reverts the devices and fails the
/// period (false); a converged one commits them, advances the trapezoid
/// history and records wave row k + 1 at t.
fn periodAccept(ckt: *root.Circuit, hook: *const PeriodHook, x: []const f64, probes: []const u32, wave: []f64, k: usize, t: f64, converged: bool) bool {
    if (!converged) {
        _ = ckt.stateCtl(.revert);
        return false;
    }
    _ = ckt.stateCtl(.commit);
    if (hook.has_charge) hook.accept(ckt.n);
    if (wave.len != 0) {
        const ncols = 1 + probes.len;
        const row = wave[(k + 1) * ncols ..][0..ncols];
        row[0] = t;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
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
) error{ QueryCancelled, OutOfMemory }!bool {
    num.copySimd(x_end, x0);
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
    /// Set when an integration fails on cancellation or memory, which the
    /// void matvec cannot return; `krylovSolve` returns it.
    failure: ?error{ QueryCancelled, OutOfMemory } = null,

    /// The GMRES operator, `shootingMatvec`.
    pub const matvec = shootingMatvec;
};

/// w = (Phi - I) v by one FD period integration:
/// w = (phi(x0 + eps*v) - phi(x0)) / eps. A failed integration returns
/// w = 0, which GMRES treats as a null direction. Autonomous: v[osc] moves
/// ln T instead of x0[osc].
fn shootingMatvec(ctx: *ShootingKrylovCtx, v: []const f64, w: []f64) void {
    const n = ctx.n;
    const inv_eps = 1.0 / ctx.options.fd_epsilon;

    num.copySimd(ctx.x_pert[0..n], ctx.x0[0..n]);
    num.axpy(ctx.x_pert[0..n], ctx.options.fd_epsilon, v[0..n]);
    var opts = ctx.options;
    const osc = opts.osc_node;
    if (osc != root.GROUND) {
        ctx.x_pert[osc] = ctx.x0[osc];
        opts.period *= 1 + ctx.options.fd_epsilon * v[osc];
    }

    const ok = integrateFrom(ctx.ckt, ctx.ws, ctx.sc, ctx.x_pert, ctx.x_end_pert, opts) catch |err| blk: {
        ctx.failure = ctx.failure orelse err;
        break :blk false;
    };
    if (!ok) {
        // ponytail: a zero column is safer than propagating NaN.
        @memset(w[0..n], 0);
        return;
    }
    fdColumn(w[0..n], ctx.x_end_pert, ctx.x_pert, ctx.phi, inv_eps);
}

/// out = ((x_end - x_start) - phi) * inv_eps, the FD derivative of phi;
/// `out` may alias `x_end`.
fn fdColumn(out: []f64, x_end: []const f64, x_start: []const f64, phi: []const f64, inv_eps: f64) void {
    num.sub(out, x_end, x_start);
    num.sub(out, out, phi);
    num.scale(out, inv_eps, out);
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
) error{ QueryCancelled, OutOfMemory }!void {
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

    @memset(dx0[0..n], 0);

    _ = krylov.solve(&ctx, neg_phi[0..n], dx0[0..n], options.gmres_tol, options.gmres_max_restarts);
    if (ctx.failure) |err| return err;
}

/// One shooting solve between its period integrations, so `solve` and
/// `runLanes` share every step but the integration: `next` names the
/// period the solve needs, the caller integrates it, `done` consumes the
/// outcome. The statements are `solve`'s own, in its order. Pinned once
/// `init` ran: `sc` and `krylov` are reached by pointer.
const Shoot = struct {
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    probes: []const u32,
    wave: []f64,
    /// The query's options; `opts` carries the period the solve is at.
    options: Options,
    opts: Options,
    allocator: std.mem.Allocator,
    n: usize,
    arena: []f64,
    x0: []f64,
    x_end: []f64,
    phi: []f64,
    x0_pert: []f64,
    x_end_pert: []f64,
    dx0: []f64,
    /// Dense path's FD Jacobian (n*n), else empty.
    j_phi: []f64,
    /// Krylov path's right-hand side (n), else empty.
    neg_phi: []f64,
    sc: Companion,
    krylov: ?Gmres,
    iter: u16 = 0,
    res_norm: f64 = std.math.inf(f64),
    stage: Stage = .base,
    /// The FD column the `.column` stage integrates next.
    col: usize = 0,
    /// Set when `stage` reaches `.done`.
    result: SolveResult = undefined,

    const Stage = enum { base, column, final, done };

    /// One period integration: `x` holds its start and receives its end;
    /// a non-empty `wave` records it as `integrateOnePeriod` documents.
    const Request = struct { x: []f64, probes: []const u32, wave: []f64, opts: Options };

    /// `solve`'s setup: buffers, the GMRES workspace past
    /// `krylov_threshold`, the baseline, and for an autonomous circuit the
    /// oscillator start. Errors as `solve`'s; on error nothing is held.
    fn init(s: *Shoot, ckt: *root.Circuit, x_dc: []const f64, probes: []const u32, wave: []f64, options: Options, allocator: std.mem.Allocator) !void {
        const n: usize = ckt.n;
        const nnz: usize = ckt.nnz;
        const ncols = 1 + probes.len;
        std.debug.assert(wave.len == 0 or wave.len == (@as(usize, options.n_samples) + 1) * ncols);
        @memset(wave, 0);

        const use_krylov = n >= krylov_threshold;
        // One block for the whole continuation, every size known up front:
        //   x0, x_end, phi, x0_pert, x_end_pert, dx0   6n
        //   q_prev, q_cur, i_prev                      3n
        //   a_vals                                     nnz
        //   j_phi (dense) or neg_phi (Krylov)          n*n or n
        const dense_extra = if (!use_krylov) n * n else 0;
        const krylov_extra = if (use_krylov) n else 0;
        const arena = try allocator.alloc(f64, 9 * n + nnz + dense_extra + krylov_extra);
        errdefer allocator.free(arena);
        var off: usize = 0;
        const x0 = take(arena, &off, n);
        const x_end = take(arena, &off, n);
        const phi = take(arena, &off, n);
        const x0_pert = take(arena, &off, n);
        const x_end_pert = take(arena, &off, n);
        const dx0 = take(arena, &off, n);
        const sc: Companion = .{
            .q_prev = take(arena, &off, n),
            .q_cur = take(arena, &off, n),
            .i_prev = take(arena, &off, n),
            .a_vals = take(arena, &off, nnz),
        };
        // The unused path's buffer slices the arena to zero length so both
        // stay mutable []f64.
        const j_phi = if (!use_krylov) arena[off..][0 .. n * n] else arena[0..0];
        const neg_phi = if (use_krylov) arena[off..][0..n] else arena[0..0];
        var krylov: ?Gmres = null;
        if (use_krylov) {
            const m = @min(options.gmres_restart, @as(u32, @intCast(n)));
            krylov = try Gmres.init(allocator, @intCast(n), m);
        }
        errdefer if (krylov) |*k| k.deinit(allocator);

        try ckt.computeBaseline();
        const ws = try ckt.workspace();
        s.* = .{
            .ckt = ckt,
            .ws = ws,
            .probes = probes,
            .wave = wave,
            .options = options,
            .opts = options,
            .allocator = allocator,
            .n = n,
            .arena = arena,
            .x0 = x0,
            .x_end = x_end,
            .phi = phi,
            .x0_pert = x0_pert,
            .x_end_pert = x_end_pert,
            .dx0 = dx0,
            .j_phi = j_phi,
            .neg_phi = neg_phi,
            .sc = sc,
            .krylov = krylov,
        };
        num.copySimd(x0, x_dc[0..n]);
        if (options.osc_node != root.GROUND) s.opts.period = try startOscillator(ckt, ws, &s.sc, x0, options, allocator);
    }

    fn deinit(s: *Shoot) void {
        if (s.krylov) |*k| k.deinit(s.allocator);
        s.allocator.free(s.arena);
        s.* = undefined;
    }

    /// The next period the solve needs, or null once `result` is set.
    /// Fails only when a checkpoint cancels.
    fn next(s: *Shoot) error{QueryCancelled}!?Request {
        const n = s.n;
        sw: switch (s.stage) {
            .base => {
                if (s.iter >= s.options.max_shooting_iter) {
                    s.stage = .final;
                    continue :sw .final;
                }
                if (s.iter != 0) try s.ckt.checkpoint(.{ .phase = .periodic, .completed = s.iter });
                // integrateFrom(x0 -> x_end).
                num.copySimd(s.x_end, s.x0);
                return .{ .x = s.x_end, .probes = &.{}, .wave = &.{}, .opts = s.opts };
            },
            .column => {
                // denseFdSolve's column `col`.
                const j = s.col;
                num.copySimd(s.x0_pert[0..n], s.x0[0..n]);
                var o = s.opts;
                if (o.osc_node != root.GROUND and j == o.osc_node) o.period *= 1 + o.fd_epsilon else s.x0_pert[j] += o.fd_epsilon;
                num.copySimd(s.x_end_pert, s.x0_pert);
                return .{ .x = s.x_end_pert, .probes = &.{}, .wave = &.{}, .opts = o };
            },
            .final => {
                num.copySimd(s.x_end, s.x0);
                return .{ .x = s.x_end, .probes = s.probes, .wave = s.wave, .opts = s.opts };
            },
            .done => return null,
        }
    }

    /// Consumes the outcome of the request `next` returned: `ok` is that
    /// integration's return. Errors as `solve`'s: a Krylov solve's
    /// cancellation or memory, `dense_lu`'s singular Jacobian.
    fn done(s: *Shoot, ok: bool) !void {
        const n = s.n;
        switch (s.stage) {
            .base => {
                if (!ok) {
                    s.result = .{ .converged = false, .iterations = s.iter, .residual_norm = std.math.inf(f64) };
                    s.stage = .done;
                    return;
                }
                // x_end + (-1)*x0 is exactly x_end - x0.
                num.copySimd(s.phi, s.x_end);
                num.axpy(s.phi, -1.0, s.x0);
                s.res_norm = num.normInf(s.phi);
                if (s.res_norm < s.options.shooting_tol) {
                    s.stage = .final;
                    return;
                }
                if (s.krylov) |*k| {
                    // ponytail: unpreconditioned; add an ILU preconditioner if GMRES stalls.
                    try krylovSolve(s.ckt, s.ws, &s.sc, n, s.x0, s.phi, s.x0_pert, s.x_end_pert, s.dx0, s.neg_phi, k, s.opts);
                    s.update();
                } else {
                    s.stage = .column;
                    s.col = 0;
                }
            },
            .column => {
                const j = s.col;
                if (!ok) {
                    for (0..n) |row| s.j_phi[row * n + j] = if (row == j) @as(f64, 1.0) else @as(f64, 0.0);
                } else {
                    // Column j is stride n in row-major J, so the store stays scalar.
                    const col = s.x_end_pert[0..n];
                    fdColumn(col, col, s.x0_pert[0..n], s.phi[0..n], 1.0 / s.opts.fd_epsilon);
                    for (col, 0..) |d, row| s.j_phi[row * n + j] = d;
                }
                s.col += 1;
                if (s.col < n) return;
                try dense_lu.factorizeSolveNeg(n, s.j_phi, s.phi[0..n], s.dx0);
                s.stage = .base;
                s.update();
            },
            .final => {
                if (!ok) @memset(s.wave, 0);
                s.result = .{ .converged = s.res_norm < s.options.shooting_tol, .iterations = s.iter, .residual_norm = s.res_norm };
                s.stage = .done;
            },
            .done => unreachable,
        }
    }

    /// The damped Newton update that ends a shooting iteration.
    fn update(s: *Shoot) void {
        var damping: f64 = 1.0;
        const osc = s.options.osc_node;
        if (osc != root.GROUND) {
            const d_ln_t = s.dx0[osc];
            s.dx0[osc] = 0;
            if (@abs(d_ln_t) > max_period_step) damping = max_period_step / @abs(d_ln_t);
            s.opts.period *= 1 + damping * d_ln_t;
        }
        num.axpy(s.x0, damping, s.dx0);
        s.iter += 1;
    }
};

/// Shooting Newton from x_dc. A non-empty `wave`, sized
/// (n_samples+1) * (1 + probes.len), receives point-major rows
/// [t, v(probes)...] of one period from the final x0, converged or not; it is
/// left zeroed if that integration fails. An autonomous solve starts with
/// `startOscillator` and returns its period as the last row's t;
/// error.OscillatorDidNotStart when the circuit does not oscillate.
/// Allocates O(n^2) below `krylov_threshold` unknowns, O(n * gmres_restart)
/// past it, and O(n * n_samples) more to start an oscillator, all freed
/// before return. Asserts `wave` is empty or that size. A period whose
/// integration fails ends the solve unconverged with an infinite residual,
/// not an error; the errors are OutOfMemory, QueryCancelled, error.Singular
/// from the dense Jacobian, and error.OscillatorDidNotStart.
pub fn solve(
    ckt: *root.Circuit,
    x_dc: []const f64,
    probes: []const u32,
    wave: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    var s: Shoot = undefined;
    try s.init(ckt, x_dc, probes, wave, options, allocator);
    defer s.deinit();
    while (try s.next()) |r| try s.done(try integrateOnePeriod(ckt, s.ws, &s.sc, r.x, r.probes, r.wave, r.opts));
    return s.result;
}

/// Starts an oscillator for the autonomous solve: kicks `x` (the DC point)
/// off its equilibrium at the osc node, integrates `osc_settle_periods`
/// guess periods and then until the swing settles (at most
/// `max_settle_periods`), then records `measure_periods` more. The period
/// is the mean spacing of the osc node's rising mid-swing crossings in
/// that record. Leaves `x` at the first sample after the last crossing, the
/// phase anchor the solve pins, and returns the period.
fn startOscillator(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !f64 {
    const n: usize = ckt.n;
    const osc = options.osc_node;
    const steps: usize = options.n_samples;
    x[osc] += osc_kick;
    for (0..options.osc_settle_periods) |_|
        if (!try integrateOnePeriod(ckt, ws, sc, x, &.{}, &.{}, options)) return error.OscillatorDidNotStart;
    // A weakly unstable tank grows from the kick over many periods: keep
    // settling until the osc node's swing moves under 1 % a period.
    const swing = try allocator.alloc(f64, 2 * (steps + 1));
    defer allocator.free(swing);
    var prev_swing: f64 = 0;
    for (0..max_settle_periods) |_| {
        if (!try integrateOnePeriod(ckt, ws, sc, x, &.{osc}, swing, options)) return error.OscillatorDidNotStart;
        var lo = std.math.inf(f64);
        var hi = -std.math.inf(f64);
        for (0..steps + 1) |k| {
            lo = @min(lo, swing[2 * k + 1]);
            hi = @max(hi, swing[2 * k + 1]);
        }
        if (@abs(hi - lo - prev_swing) <= 0.01 * (hi - lo)) break;
        prev_swing = hi - lo;
    }

    const rows = try allocator.alloc(u32, n);
    defer allocator.free(rows);
    for (rows, 0..) |*r, i| r.* = @intCast(i);
    const stride = (steps + 1) * (n + 1);
    const record = try allocator.alloc(f64, measure_periods * stride);
    defer allocator.free(record);
    for (0..measure_periods) |p|
        if (!try integrateOnePeriod(ckt, ws, sc, x, rows, record[p * stride ..][0..stride], options)) return error.OscillatorDidNotStart;

    // Sample g of the record is row g % steps of period g / steps; the last
    // row of each period repeats the next period's first.
    const total = measure_periods * steps + 1;
    const Sample = struct {
        fn row(rec: []const f64, g: usize, s: usize, cols: usize) []const f64 {
            const p = @min(g / s, measure_periods - 1);
            return rec[p * (s + 1) * cols + (g - p * s) * cols + 1 ..][0 .. cols - 1];
        }
    };
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (0..total) |g| {
        const v = Sample.row(record, g, steps, n + 1)[osc];
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const level = 0.5 * (lo + hi);
    var first: f64 = 0;
    var last: f64 = 0;
    var anchor: usize = 0;
    var crossings: u32 = 0;
    var prev = Sample.row(record, 0, steps, n + 1)[osc];
    for (1..total) |g| {
        const v = Sample.row(record, g, steps, n + 1)[osc];
        if (prev < level and v >= level) {
            const at = @as(f64, @floatFromInt(g - 1)) + (level - prev) / (v - prev);
            if (crossings == 0) first = at;
            last = at;
            anchor = g;
            crossings += 1;
        }
        prev = v;
    }
    if (crossings < 2 or !(hi - lo > osc_kick)) return error.OscillatorDidNotStart;
    num.copySimd(x[0..n], Sample.row(record, anchor, steps, n + 1));
    const dt = options.period / @as(f64, @floatFromInt(steps));
    return (last - first) / @as(f64, @floatFromInt(crossings - 1)) * dt;
}

/// Contract entry: shoot from ctx.x_op and return one period as point-major
/// rows (time, probes...), n_samples+1 of them. Non-convergence prints a
/// warning and still returns the last period.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    try ctx.circuit.refuseDigital("pss");
    const names = try root.probeNames(ctx, "time");
    const data = try ctx.allocator.alloc(f64, (@as(usize, opts.n_samples) + 1) * names.len);
    errdefer ctx.allocator.free(data);
    const res = try solve(ctx.circuit, ctx.x_op, ctx.probes, data, opts, ctx.scratch_allocator);
    return finish(res, names, data, opts);
}

/// `run`'s setup for a lane: the same refusals, names and row buffer,
/// then the shooting state in `shot`.
fn start(ctx: *const root.RunCtx, opts: Options, shot: *Shoot, names: *[]const []const u8, data: *[]f64) !void {
    try ctx.circuit.refuseDigital("pss");
    names.* = try root.probeNames(ctx, "time");
    data.* = try ctx.allocator.alloc(f64, (@as(usize, opts.n_samples) + 1) * names.len);
    errdefer ctx.allocator.free(data.*);
    try shot.init(ctx.circuit, ctx.x_op, ctx.probes, data.*, opts, ctx.scratch_allocator);
}

/// The published period. Non-convergence prints a warning and still
/// returns the last period.
fn finish(res: SolveResult, names: []const []const u8, data: []f64, opts: Options) root.Result {
    if (!res.converged)
        std.debug.print("Warning: pss: shooting did not converge (residual {e})\n", .{res.residual_norm});
    return .{
        .plotname = "Periodic Steady State",
        .varnames = names,
        .is_complex = false,
        .npoints = @as(usize, opts.n_samples) + 1,
        .data = data,
    };
}

/// `integrateOnePeriod` for every lane of `m`, lane l on `shots[l]` and
/// request `reqs[l]`: the start, commit/revert, history and wave rows run
/// per lane and each step's Newton runs as lanes, so lane l is bitwise its
/// scalar integration. Returns the lanes whose period completed. Every
/// request takes the same `n_samples` (one batch shares its options; an
/// autonomous lane's own period changes only its t and dt). Cancellation
/// and memory fail every lane.
fn integrateLanes(
    comptime W: usize,
    sys: *LaneSys(W),
    lws: *converger.LaneWorkspace(W),
    xv: []Lanes(W).V,
    shots: *[W]Shoot,
    reqs: *const [W]Shoot.Request,
    m: Lanes(W).Mask,
) !Lanes(W).Mask {
    const L = Lanes(W);
    const S = LaneSys(W);
    const steps: usize = reqs[@ctz(m)].opts.n_samples;
    var it = L.each(m);
    while (it.next()) |l| {
        std.debug.assert(reqs[l].opts.n_samples == steps);
        periodStart(shots[l].ckt, &shots[l].sc, reqs[l].x, reqs[l].probes, reqs[l].wave, reqs[l].opts);
    }
    var live = m;
    var hooks: [W]PeriodHook = undefined;
    var times: [W]f64 = @splat(0);
    for (0..steps) |k| {
        if (!L.any(live)) break;
        it = L.each(live);
        while (it.next()) |l| {
            const o = reqs[l].opts;
            const ckt = shots[l].ckt;
            const dt = o.period / @as(f64, @floatFromInt(steps));
            times[l] = stepTime(o, k);
            hooks[l] = periodHook(&shots[l].sc, 2.0 / dt, ckt.has_charge);
            sys.hooks[l] = hooks[l];
            ckt.setSimState(.{ .t = times[l], .dt = dt, .kind = .tran });
            S.putLane(xv, reqs[l].x, l);
        }
        sys.active = live;
        const o0 = reqs[@ctz(live)].opts;
        const res = converger.newtonLanes(W, sys, lws, xv, times, .{
            .max_iter = o0.max_newton_iter,
            .abstol = o0.newton_tol,
        }, S.LaneHook{});
        // As `converger.run` ends each lane's solve.
        it = L.each(live);
        while (it.next()) |l| shots[l].ckt.clearLimits();
        const r = try res;
        it = L.each(live);
        while (it.next()) |l| {
            S.getLane(reqs[l].x, xv, l);
            const bit = @as(L.Mask, 1) << @intCast(l);
            const ok = r.converged & bit != 0 and r.singular & bit == 0;
            if (!periodAccept(shots[l].ckt, &hooks[l], reqs[l].x, reqs[l].probes, reqs[l].wave, k, times[l], ok)) live &= ~bit;
        }
    }
    return live;
}

/// `run` for the lanes of one batch: `.pss` queries on one pattern, each
/// from its own operating point and variant row (#210). Each lane keeps
/// its own shooting loop, FD columns, monodromy LU, GMRES and period; the
/// period integrations of a round run together, one lane Newton per time
/// step (`integrateLanes`). A Krylov lane's matvecs run scalar inside its
/// own `done`. Lane l's result lands in `out[l]`, bitwise `run` on
/// `ctxs[l]`. Under a JFNK pin or `-Dcertify` every lane runs `run`.
/// Asserts 1 <= `ctxs.len` <= W.
pub fn runLanes(comptime W: usize, ctxs: []const root.RunCtx, opts: Options, out: []LaneOutcome) void {
    const g = ctxs.len;
    std.debug.assert(g >= 1 and g <= W and out.len == g);
    const pin = ctxs[0].circuit.knobs.newton.pin;
    if (W == 1 or g == 1 or !(pin == .auto or pin == .direct) or root.Circuit.certify) {
        for (ctxs, out) |*c, *o| o.* = run(c, opts);
        return;
    }
    const L = Lanes(W);
    const S = LaneSys(W);
    var shots: [W]Shoot = undefined;
    var names: [W][]const []const u8 = undefined;
    var data: [W][]f64 = undefined;
    var live: L.Mask = 0;
    for (ctxs, 0..) |*c, l| {
        start(c, opts, &shots[l], &names[l], &data[l]) catch |e| {
            out[l] = e;
            continue;
        };
        live |= @as(L.Mask, 1) << @intCast(l);
    }
    defer {
        var it = L.each(live);
        while (it.next()) |l| shots[l].deinit();
    }
    const kill = struct {
        fn f(sh: []Shoot, m: *L.Mask, o: []LaneOutcome, l: usize, err: LaneError) void {
            o[l] = err;
            sh[l].deinit();
            m.* &= ~(@as(L.Mask, 1) << @intCast(l));
        }
    }.f;
    // Every lane fails with the batch's own error (cancel, out of memory).
    const fail = struct {
        fn f(sh: []Shoot, m: *L.Mask, o: []LaneOutcome, err: LaneError) void {
            var it = L.each(m.*);
            while (it.next()) |l| {
                o[l] = err;
                sh[l].deinit();
            }
            m.* = 0;
        }
    }.f;
    if (live == 0) return;
    const first = @ctz(live);
    var lanes: [W]*root.Circuit = undefined;
    var wss: [W]*converger.Workspace = undefined;
    for (&lanes, &wss, 0..) |*c, *w, l| {
        // Unused lanes repeat the first live one and stay inactive.
        const k = if (l < g and (live >> @intCast(l)) & 1 != 0) l else first;
        c.* = shots[k].ckt;
        w.* = shots[k].ws;
    }
    const gpa = ctxs[first].scratch_allocator;
    // The hook only sizes the value plane here (alpha 0 rewrites `a_vals`
    // as G, which every assemble overwrites); each step sets its own.
    var sys = S.init(gpa, lanes, periodHook(&shots[first].sc, 0, lanes[first].has_charge)) catch |e| return fail(&shots, &live, out, e);
    defer sys.deinit(gpa);
    var lws = converger.LaneWorkspace(W).init(gpa, wss) catch |e| return fail(&shots, &live, out, e);
    defer lws.deinit(gpa);
    const xv = gpa.alloc(L.V, lanes[first].n) catch |e| return fail(&shots, &live, out, e);
    defer gpa.free(xv);

    var reqs: [W]Shoot.Request = undefined;
    while (true) {
        var round: L.Mask = 0;
        var it = L.each(live);
        while (it.next()) |l| {
            const bit = @as(L.Mask, 1) << @intCast(l);
            const r = shots[l].next() catch |e| {
                kill(&shots, &live, out, l, e);
                continue;
            };
            if (r) |req| {
                reqs[l] = req;
                round |= bit;
                continue;
            }
            out[l] = finish(shots[l].result, names[l], data[l], opts);
            shots[l].deinit();
            live &= ~bit;
        }
        if (round == 0) break;
        const ok = integrateLanes(W, &sys, &lws, xv, &shots, &reqs, round) catch |e| return fail(&shots, &live, out, e);
        it = L.each(round);
        while (it.next()) |l| shots[l].done(ok & (@as(L.Mask, 1) << @intCast(l)) != 0) catch |e| kill(&shots, &live, out, l, e);
    }
}

const LaneError = root.ErrorOf(run);
/// One lane's `run` outcome.
pub const LaneOutcome = LaneError!root.Result;

/// Private implementation access for the analysis test suite; void outside tests.
pub const test_access = if (@import("builtin").is_test) .{
    .krylov_threshold = krylov_threshold,
} else {};
