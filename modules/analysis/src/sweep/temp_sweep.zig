//! Temperature sweep: setCircuitTemp + explicit TempCoeff overrides, then
//! re-solve DC at each point. One Workspace serves every temperature — the
//! pattern is frozen.
const std = @import("std");
const root = @import("../root.zig");
const dc = @import("../dc/dc.zig");
const converger = @import("../helper/converger.zig");

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
    param: *f32,
    base_value: f64,
    tc1: f64,
    tc2: f64,
    tnom: f64,

    /// Scale the parameter to temperature T using the standard SPICE model:
    ///   R(T) = R(Tnom) * (1 + tc1*(T - Tnom) + tc2*(T - Tnom)^2)
    pub fn apply(self: *const TempCoeff, temp: f64) void {
        const dt = temp - self.tnom;
        self.param.* = @floatCast(self.base_value * (1.0 + self.tc1 * dt + self.tc2 * dt * dt));
    }

    /// Restore the parameter to its nominal (base) value.
    pub fn restore(self: *const TempCoeff) void {
        self.param.* = @floatCast(self.base_value);
    }
};

/// Temperature sweep analysis.
///
/// Sweeps temperature from t_start to t_stop in steps of t_step.
/// At each temperature point, applies temperature coefficients to all
/// registered parameters via the TempCoeff descriptors, then re-solves
/// the DC operating point.
///
/// Caller owns the outputs: temps[numPoints(options)] and the flat
/// values[probes.len * temps.len], probe-major with stride temps.len —
/// values[p * temps.len + i] is probe p at recorded point i. Only the
/// first Status.points entries are written.
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
        ckt.recompute();

        // Re-solve DC operating point at this temperature
        @memset(x, 0);
        const dc_result = try converger.run(ckt, ws, x, 0, nopts, converger.EvalHook{});

        if (dc_result.converged) {
            temps[points] = temp;
            for (probes, 0..) |node, k| {
                values[k * temps.len + points] = x[node];
            }
            points += 1;
        } else {
            failed += 1;
        }
    }

    // Restore all parameters to nominal values
    ckt.setCircuitTemp(@floatCast(options.t_nom));
    for (temp_coeffs) |*tc| {
        tc.restore();
    }
    ckt.recompute();

    return .{
        .completed = failed == 0,
        .points = points,
        .failed_temps = failed,
    };
}

/// Convenience: compute the number of temperature points in a sweep.
pub fn numPoints(options: Options) u32 {
    if (options.t_step <= 0) return 1;
    const span = options.t_stop - options.t_start;
    if (span < 0) return 0;
    return @as(u32, @intFromFloat(@floor(span / options.t_step))) + 1;
}

/// Contract entry: device-internal temperature physics via setCircuitTemp —
/// no external coefficients. Data layout: point-major (temp, probes...), one
/// row per converged temperature. Temperature restored to t_nom afterwards so
/// later jobs see the netlist-declared circuit.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    const max_points: usize = numPoints(opts);

    const temps = try a.alloc(f64, max_points);
    defer a.free(temps);
    const values = try a.alloc(f64, ctx.probes.len * max_points);
    defer a.free(values);
    const x = try a.alloc(f64, ckt.n);
    defer a.free(x);

    // sweep() restores on success; this covers early-error paths too.
    defer {
        ckt.setCircuitTemp(@floatCast(opts.t_nom));
        ckt.recompute();
    }
    const st = try sweep(ckt, x, ctx.probes, &.{}, temps, values, opts);

    const npoints: usize = st.points;
    const names = try root.probeNames(ctx, "temp");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "temp" literal
        a.free(names);
    }
    const ncols = names.len;
    const data = try a.alloc(f64, npoints * ncols);
    for (0..npoints) |i| {
        const row = data[i * ncols ..][0..ncols];
        row[0] = temps[i];
        for (0..ctx.probes.len) |p| row[1 + p] = values[p * max_points + i];
    }

    return .{
        .plotname = "Temperature Sweep",
        .varnames = names,
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
