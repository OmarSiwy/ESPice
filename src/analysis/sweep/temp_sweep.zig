//! Temperature sweep (`.temp`): one structural lane per temperature, using
//! the devices' own temperature physics (setCircuitTemp), no external
//! coefficients.
const root = @import("../types.zig");
const lanes = @import("lanes.zig");
const converger = @import("solver").converger;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Temp;

/// Points from t_start to t_stop by t_step, endpoint inclusive; 1 for a
/// non-positive step, 0 for a descending span.
pub fn numPoints(options: Options) u32 {
    if (options.t_step <= 0) return 1;
    const span = options.t_stop - options.t_start;
    if (span < 0) return 0;
    // Same 1e-6-step nudge as dc.zig sweepCount: an exact-integer ratio
    // arrives just under itself in f64 and a bare floor drops the endpoint.
    return @as(u32, @intFromFloat(@floor(span / options.t_step + 1e-6))) + 1;
}

/// Lane k runs at t_start + k*t_step; restore returns the circuit to t_nom.
const LaneCtx = struct {
    ckt: *root.Circuit,
    t_start: f64,
    t_step: f64,
    t_nom: f64,

    pub fn apply(self: *LaneCtx, k: usize) void {
        self.ckt.setCircuitTemp(@floatCast(self.t_start + @as(f64, @floatFromInt(k)) * self.t_step));
    }

    pub fn restore(self: *LaneCtx) void {
        self.ckt.setCircuitTemp(@floatCast(self.t_nom));
    }
};

/// Contract entry: real, point-major (temp, probes...), one row per converged
/// temperature. The circuit is back at t_nom afterwards so later jobs see the
/// netlist's temperature.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const max_points: usize = numPoints(opts);
    const ncols = ctx.probes.len + 1;
    const n: usize = ckt.n;

    const x_lanes = try scratch.alloc(f64, max_points * n);
    defer scratch.free(x_lanes);
    const results = try scratch.alloc(converger.Result, max_points);
    defer scratch.free(results);

    var lane_ctx: LaneCtx = .{ .ckt = ckt, .t_start = opts.t_start, .t_step = opts.t_step, .t_nom = opts.t_nom };
    const nopts = converger.optionsFromTolerances(opts.dc_options.tol, opts.dc_options.tol.itl2);
    try lanes.solveLanes(ckt, &lane_ctx, x_lanes, results, nopts, false);

    var npoints: usize = 0;
    for (results) |r| npoints += @intFromBool(r.converged);
    const data = try a.alloc(f64, npoints * ncols);
    var pt: usize = 0;
    for (results, 0..) |r, k| {
        if (!r.converged) continue;
        const row = data[pt * ncols ..][0..ncols];
        row[0] = opts.t_start + @as(f64, @floatFromInt(k)) * opts.t_step;
        const lane = x_lanes[k * n ..][0..n];
        for (ctx.probes, row[1..]) |node, *out| out.* = lane[node];
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
