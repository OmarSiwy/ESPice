//! Envelope-following transient. Each outer step skips `periods_per_step`
//! carrier periods with coarse trapezoid steps, then resolves the last period
//! finely to extract per-probe peak and RMS. The outer step halves when the
//! envelope moves more than envelope_reltol and doubles below a quarter of it.
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const converger = @import("solver").converger;
const integrator = @import("integrator.zig");

pub const Options = @import("core").query.Envelope;

/// Outcome of one envelope run.
pub const SimResult = struct {
    /// True when t reached t_stop.
    completed: bool,
    outer_steps: u32,
    /// Time of the last envelope point, in seconds.
    t_final: f64,
    /// Rows written into the caller's buffer, the t = 0 row included.
    n_points: u32,
};

/// Upper bound on envelope rows: every accepted outer step advances at least
/// min_periods_per_step carrier periods, plus the t = 0 row and one row of
/// rounding slack.
pub fn maxPoints(options: Options) u32 {
    const min_step = @as(f64, @floatFromInt(@max(options.min_periods_per_step, 1))) * options.t_carrier;
    const by_time = @ceil(options.t_stop / min_step);
    const cap = @as(f64, @floatFromInt(options.max_outer_steps));
    return @as(u32, @intFromFloat(@min(by_time, cap))) + 2;
}

/// Trapezoidal charge history carried across every envelope step, coarse and
/// fine alike (trapezoid is one-step, so dt may change between them).
const Trap = struct {
    q_prev: []f64,
    i_prev: []f64,
    /// q(x) from the last Newton assemble.
    q_cur: []f64,
    a_vals: []f64,
    alpha: f64 = 0,

    /// Companion residual alpha*(q - q_prev) - i_prev, matrix G + alpha*C.
    pub fn assemble(self: Trap, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        const n: usize = ckt.n;
        simdCopy(self.q_cur[0..n], ckt.q_vec[0..n]);
        integrator.companionAt(.trapezoidal, true, ckt.rhs[0..n], ckt.q_vec[0..n], self.q_prev[0..n], &.{}, self.i_prev[0..n], .{ .ag0 = self.alpha, .ag2 = 0 });
    }
    pub fn vals(self: Trap, ckt: *root.Circuit) []f64 {
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }
    pub fn diagAt(self: Trap, ckt: *root.Circuit, slot: u32) f64 {
        return ckt.gcAt(self.alpha, slot);
    }
    /// Accepted step: i = alpha*(q - q_prev) - i_prev, then q_prev = q.
    fn accept(self: Trap, n: usize) void {
        integrator.companionAt(.trapezoidal, false, self.i_prev[0..n], self.q_cur[0..n], self.q_prev[0..n], &.{}, self.i_prev[0..n], .{ .ag0 = self.alpha, .ag2 = 0 });
        simdCopy(self.q_prev[0..n], self.q_cur[0..n]);
    }
};

/// One step to absolute time t: a trapezoid step of length dt when the
/// circuit has charge (`trap`), else a static solve. Returns convergence.
fn newtonAt(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    x: []f64,
    t: f64,
    dt: f64,
    options: Options,
    trap: ?*Trap,
) !bool {
    // Devices read Instance.abstime (§9.10 `$abstime`), not the `t`
    // argument, so every step publishes its time.
    const opts = converger.optionsFromTolerances(options.tol, options.tol.itl4);
    const nr = if (trap) |tr| blk: {
        ckt.setSimState(.{ .t = t, .dt = dt, .kind = .tran });
        tr.alpha = 2.0 / dt;
        break :blk converger.run(ckt, ws, x, t, opts, tr.*);
    } else blk: {
        // No charge: dt stays 0 and the step is static.
        ckt.setSimState(.{ .t = t, .kind = .tran });
        break :blk converger.run(ckt, ws, x, t, opts, root.EvalHook{});
    };
    const r = nr catch |err| switch (err) {
        error.QueryCancelled => return err,
        else => return false,
    };
    if (r.converged) if (trap) |tr| tr.accept(ckt.n);
    return r.converged;
}

/// Envelope-following transient from `x`. The caller owns `rows`, sized
/// maxPoints(options) * (1 + 2*probes.len): point-major rows
/// [t, peak_p0, rms_p0, peak_p1, rms_p1, ...]. Returns
/// error.EnvelopeDidNotConverge when a step fails at min_periods_per_step.
pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    rows: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SimResult {
    const n: usize = ckt.n;
    const t_carrier = options.t_carrier;
    const ncols = 1 + 2 * probes.len;
    std.debug.assert(rows.len >= @as(usize, maxPoints(options)) * ncols);

    try ckt.computeBaseline();
    const ws = try ckt.workspace();

    // One scratch block: [x_outer_save | prev_peak | peak | sum_sq | trap]
    // where trap = q_prev, i_prev, q_cur and rollback copies of the first
    // two, present only when the circuit has charge.
    const nt: usize = if (ckt.has_charge) n else 0;
    const scratch = try allocator.alloc(f64, n + 3 * probes.len + 5 * nt);
    defer allocator.free(scratch);
    const x_outer_save = scratch[0..n];
    const prev_peak = scratch[n..][0..probes.len];
    const peak = scratch[n + probes.len ..][0..probes.len];
    const sum_sq = scratch[n + 2 * probes.len ..][0..probes.len];
    const ts = scratch[n + 3 * probes.len ..][0 .. 5 * nt];
    const q_save = ts[3 * nt ..][0..nt];
    const i_save = ts[4 * nt ..][0..nt];
    var trap_state: Trap = undefined;
    const trap: ?*Trap = if (ckt.has_charge) blk: {
        trap_state = .{
            .q_prev = ts[0..n],
            .i_prev = ts[n..][0..n],
            .q_cur = ts[2 * n ..][0..n],
            .a_vals = try ws.ensureAVals(ckt.nnz),
        };
        // Exact at a DC operating point: q = q(x_op), no dynamic current.
        ckt.eval(x, 0);
        simdCopy(trap_state.q_prev, ckt.q_vec[0..n]);
        @memset(trap_state.i_prev, 0);
        break :blk &trap_state;
    } else null;
    const dt_inner: f64 = t_carrier / @as(f64, @floatFromInt(options.carrier_steps_per_period));

    // Row 0 is the operating point.
    {
        const row = rows[0..ncols];
        row[0] = 0;
        for (probes, 0..) |node, p| {
            row[1 + 2 * p] = @abs(x[node]); // peak
            row[2 + 2 * p] = @abs(x[node]); // rms
        }
    }

    var t: f64 = 0;
    var outer_steps: u32 = 0;
    var periods_per_step: u32 = options.periods_per_outer_step;

    for (probes, 0..) |node, p| {
        prev_peak[p] = @abs(x[node]);
    }

    var attempts: u64 = 0;
    while (t < options.t_stop and outer_steps < options.max_outer_steps) {
        if (attempts != 0) try ckt.checkpoint(.{ .phase = .transient, .completed = attempts });
        attempts += 1;
        simdCopy(x_outer_save, x);
        if (trap) |tr| {
            simdCopy(q_save, tr.q_prev);
            simdCopy(i_save, tr.i_prev);
        }

        const t_outer_step = @as(f64, @floatFromInt(periods_per_step)) * t_carrier;
        const t_target = @min(t + t_outer_step, options.t_stop);
        const actual_outer_dt = t_target - t;

        // Coarse steps (4x the inner dt) up to one carrier period short of
        // the target, then one fine period for the envelope.
        const t_fine_start = if (actual_outer_dt > t_carrier)
            t_target - t_carrier
        else
            t;
        const needs_coarse = t_fine_start > t;
        var ok = !needs_coarse or try coarseAdvance(ckt, ws, x, t, t_fine_start - t, dt_inner * 4.0, options, trap);

        // RMS by trapezoid weights over the window: half weight on each
        // endpoint, so a sine reads its true RMS.
        for (probes, 0..) |node, p| {
            peak[p] = @abs(x[node]);
            sum_sq[p] = 0.5 * x[node] * x[node];
        }
        var n_steps: u32 = 0;

        var t_inner: f64 = 0;
        const fine_duration = t_target - t_fine_start;
        while (ok and t_inner < fine_duration) {
            if (!try newtonAt(ckt, ws, x, t_fine_start + t_inner + dt_inner, dt_inner, options, trap)) {
                ok = false;
                break;
            }

            t_inner += dt_inner;
            n_steps += 1;

            for (probes, 0..) |node, p| {
                const v = x[node];
                peak[p] = @max(peak[p], @abs(v));
                sum_sq[p] += v * v;
            }
        }

        if (!ok) {
            // The outer step was too aggressive: restore and retry shorter.
            simdCopy(x, x_outer_save);
            if (trap) |tr| {
                simdCopy(tr.q_prev, q_save);
                simdCopy(tr.i_prev, i_save);
            }
            if (periods_per_step == options.min_periods_per_step) return error.EnvelopeDidNotConverge;
            periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
            continue;
        }

        t = t_target;
        outer_steps += 1;

        const row = rows[outer_steps * ncols ..][0..ncols];
        row[0] = t;

        var max_rel_change: f64 = 0;
        for (probes, 0..) |node, p| {
            const rms = @sqrt(@max(sum_sq[p] - 0.5 * x[node] * x[node], 0) / @as(f64, @floatFromInt(n_steps)));

            row[1 + 2 * p] = peak[p];
            row[2 + 2 * p] = rms;

            const denom = @max(prev_peak[p], 1e-15);
            const rel_change = @abs(peak[p] - prev_peak[p]) / denom;
            max_rel_change = @max(max_rel_change, rel_change);

            prev_peak[p] = peak[p];
        }

        if (max_rel_change > options.envelope_reltol) {
            periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
        } else if (max_rel_change < options.envelope_reltol * 0.25) {
            periods_per_step = @min(periods_per_step * 2, options.max_periods_per_step);
        }
    }

    return .{
        .completed = t >= options.t_stop,
        .outer_steps = outer_steps,
        .t_final = t,
        .n_points = outer_steps + 1,
    };
}

/// Steps from t_start through `duration` seconds at `dt_coarse`, the last
/// step shortened to land exactly. Returns false on the first Newton failure.
fn coarseAdvance(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    x: []f64,
    t_start: f64,
    duration: f64,
    dt_coarse: f64,
    options: Options,
    trap: ?*Trap,
) !bool {
    var t_elapsed: f64 = 0;
    while (t_elapsed < duration) {
        const dt = @min(dt_coarse, duration - t_elapsed);
        if (!try newtonAt(ckt, ws, x, t_start + t_elapsed + dt, dt, options, trap)) return false;
        t_elapsed += dt;
    }
    return true;
}

/// Contract entry: envelope-follow from ctx.x_op. Point-major rows
/// (time, peak and rms per probe), exactly what `simulate` writes.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;
    const scratch = ctx.scratch_allocator;
    const x = try scratch.alloc(f64, x_op.len);
    defer scratch.free(x);
    simdCopy(x, x_op);

    // `data` is the Result, so it lives on the results arena.
    const ncols = 1 + 2 * ctx.probes.len;
    const data = try a.alloc(f64, @as(usize, maxPoints(opts)) * ncols);
    errdefer a.free(data);
    const st = try simulate(ctx.circuit, x, ctx.probes, data, opts, scratch);
    if (!st.completed) return error.EnvelopeDidNotConverge;

    // probeNames uses the deck's labels, which also name branch-current rows.
    const labels = try root.probeNames(ctx, null);
    const names = try a.alloc([]const u8, ncols);
    names[0] = "time";
    for (labels, 0..) |l, p| {
        names[1 + p * 2] = try std.fmt.allocPrint(a, "peak({s})", .{l});
        names[2 + p * 2] = try std.fmt.allocPrint(a, "rms({s})", .{l});
    }

    const npoints: usize = st.n_points;
    return .{
        .plotname = "Envelope Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = try a.realloc(data, npoints * ncols),
    };
}
