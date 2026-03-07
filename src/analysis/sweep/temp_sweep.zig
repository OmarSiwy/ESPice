//! Temperature sweep: device-native temperature physics, one structural lane
//! per point. The circuit pattern and Newton workspace are shared across lanes.
const root = @import("../types.zig");
const lanes = @import("lanes.zig");
const converger = @import("solvers").converger;

pub const Options = @import("requests").Temp;

pub fn numPoints(options: Options) u32 {
    if (options.t_step <= 0) return 1;
    const span = options.t_stop - options.t_start;
    if (span < 0) return 0;
    return @as(u32, @intFromFloat(@floor(span / options.t_step))) + 1;
}

/// solveLanes apply/restore state: lane k installs temperature
/// t_start + k*t_step; the lane driver recomputes after restoring t_nom.
const LaneCtx = struct {
    ckt: *root.Circuit,
    t_start: f64,
    t_step: f64,
    t_nom: f64,

    fn apply(ptr: *anyopaque, k: usize) void {
        const self: *LaneCtx = @ptrCast(@alignCast(ptr));
        self.ckt.setCircuitTemp(@floatCast(self.t_start + @as(f64, @floatFromInt(k)) * self.t_step));
    }

    fn restore(ptr: *anyopaque) void {
        const self: *LaneCtx = @ptrCast(@alignCast(ptr));
        self.ckt.setCircuitTemp(@floatCast(self.t_nom));
    }
};

/// Contract entry: device-internal temperature physics via setCircuitTemp —
/// no external coefficients. Data layout: point-major (temp, probes...), one
/// row per converged temperature. Temperature restored to t_nom afterwards so
/// later jobs see the netlist-declared circuit.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    const max_points: usize = numPoints(opts);
    const ncols = ctx.probes.len + 1;

    // Structural sweep lanes: lane k is temperature t_start + k*t_step, batched
    // on GPU or serial. No external coeffs on this path — device-internal temp
    // physics only, installed via setCircuitTemp.
    const n: usize = ckt.n;
    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const x_lanes = try scratch.alloc(f64, max_points * n);
    defer scratch.free(x_lanes);
    const results = try scratch.alloc(converger.Result, max_points);
    defer scratch.free(results);

    var lane_ctx: LaneCtx = .{ .ckt = ckt, .t_start = opts.t_start, .t_step = opts.t_step, .t_nom = opts.t_nom };
    const setup: lanes.LaneSetup = .{ .ctx = &lane_ctx, .apply = LaneCtx.apply, .restore = LaneCtx.restore };
    const nopts = converger.optionsFromTolerances(opts.dc_options.tol, opts.dc_options.tol.itl2);
    try lanes.solveLanes(ckt, setup, x_lanes, results, nopts);

    // Collect converged points, point-major (temp, probes...).
    var npoints: usize = 0;
    for (results) |r| {
        if (r.converged) npoints += 1;
    }
    const data = try a.alloc(f64, npoints * ncols);
    var pt: usize = 0;
    for (0..max_points) |k| {
        if (!results[k].converged) continue;
        const row = data[pt * ncols ..][0..ncols];
        row[0] = opts.t_start + @as(f64, @floatFromInt(k)) * opts.t_step;
        const lane = x_lanes[k * n ..][0..n];
        for (ctx.probes, 0..) |node, p| row[1 + p] = lane[node];
        pt += 1;
    }

    return .{
        .plotname = "Temperature Sweep",
        .varnames = try root.probeNames(ctx, "temp"),
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}
