//! Temperature sweep: setCircuitTemp + explicit TempCoeff overrides, then
//! re-solve DC at each point. One Workspace serves every temperature — the
//! pattern is frozen.
const std = @import("std");
const root = @import("../types.zig");
const dc = @import("../dc/dc.zig");
const lanes = @import("lanes.zig");
const converger = @import("solvers").converger;


pub const Options = struct {
    tol: converger.Tolerances = .{},
    t_start: f64 = -40.0,
    t_stop: f64 = 125.0,
    t_step: f64 = 1.0,
    t_nom: f64 = 27.0,
    dc_options: dc.Options = .{},
};

pub const Status = struct {
    completed: bool,
    points: u32,
    failed_temps: u32,
};

/// Temperature coefficient descriptor for a model parameter.
/// Holds pointers to the resistance field and its base (nominal) value,
/// plus the tc1/tc2 coefficients. Take `param` from a root.ParamRef —
/// batch arrays are stable after compile().
pub const TempCoeff = struct {
    param: root.ParamRef,
    base_value: f64,
    tc1: f64,
    tc2: f64,
    tnom: f64,

    /// Scale the parameter to temperature T using the standard SPICE model:
    ///   R(T) = R(Tnom) * (1 + tc1*(T - Tnom) + tc2*(T - Tnom)^2)
    pub fn apply(self: *const TempCoeff, temp: f64) void {
        const dt = temp - self.tnom;
        self.param.set(self.base_value * (1.0 + self.tc1 * dt + self.tc2 * dt * dt));
    }

    pub fn restore(self: *const TempCoeff) void {
        self.param.set(self.base_value);
    }
};

/// Caller owns the outputs: temps[numPoints(options)] and the flat
/// values[probes.len * temps.len], probe-major with stride temps.len —
/// values[p * temps.len + i] is probe p at recorded point i. Only the
/// first Status.points entries are written.
///
/// Non-converged points are dropped (counted in failed_temps), not zeroed.
///
/// The caller is responsible for building the TempCoeff array that maps
/// model parameters to their temperature coefficients. This keeps the
/// analysis decoupled from any specific device type.
pub fn sweep(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    temp_coeffs: []const TempCoeff,
    temps: []f64,
    values: []f64,
    options: Options,
) !Status {
    std.debug.assert(values.len == probes.len * temps.len);
    errdefer {
        ckt.setCircuitTemp(@floatCast(options.t_nom));
        for (temp_coeffs) |*tc| tc.restore();
        ckt.recompute() catch {}; // preserve the original failure; no further solve follows
    }
    var points: u32 = 0;
    var failed: u32 = 0;

    const ws = try ckt.workspace();
    const nopts = options.dc_options.tol.newtonOpts(options.dc_options.tol.itl2);

    var temp = options.t_start;
    while (temp <= options.t_stop + options.t_step * 0.5) : (temp += options.t_step) {
        // Device-internal temperature physics: every batch with a temp field
        // (tc1/tc2, junction physics, ...) re-evaluates at this temperature.
        ckt.setCircuitTemp(@floatCast(temp));

        // Explicit external coefficients on top (overrides / extra params)
        for (temp_coeffs) |*tc| {
            tc.apply(temp);
        }
        try ckt.recompute();

        root.zeroSimd(x);
        ckt.seedJunctions(x);

        // Non-convergence or solver error => count as failed, skip point
        const converged = if (converger.run(ckt, ws, x, 0, nopts, root.EvalHook{})) |r|
            r.converged
        else |_|
            false;

        if (converged) {
            temps[points] = temp;
            for (probes, 0..) |node, k| {
                values[k * temps.len + points] = x[node];
            }
            points += 1;
        } else {
            failed += 1;
        }
    }

    ckt.setCircuitTemp(@floatCast(options.t_nom));
    for (temp_coeffs) |*tc| {
        tc.restore();
    }
    try ckt.recompute();

    return .{
        .completed = failed == 0,
        .points = points,
        .failed_temps = failed,
    };
}

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
    const x_lanes = try a.alloc(f64, max_points * n);
    defer a.free(x_lanes);
    const results = try a.alloc(converger.Result, max_points);
    defer a.free(results);

    var lane_ctx: LaneCtx = .{ .ckt = ckt, .t_start = opts.t_start, .t_step = opts.t_step, .t_nom = opts.t_nom };
    const setup: lanes.LaneSetup = .{ .ctx = &lane_ctx, .apply = LaneCtx.apply, .restore = LaneCtx.restore };
    const nopts = opts.dc_options.tol.newtonOpts(opts.dc_options.tol.itl2);
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
test "temp_sweep: numPoints calculation" {
    try testing.expectEqual(@as(u32, 166), numPoints(.{
        .t_start = -40.0,
        .t_stop = 125.0,
        .t_step = 1.0,
    }));
    try testing.expectEqual(@as(u32, 34), numPoints(.{
        .t_start = -40.0,
        .t_stop = 125.0,
        .t_step = 5.0,
    }));
    try testing.expectEqual(@as(u32, 1), numPoints(.{
        .t_start = 27.0,
        .t_stop = 27.0,
        .t_step = 1.0,
    }));
}
