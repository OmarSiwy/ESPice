//! Envelope-following transient: quasi-static Newton (A = G) sampled along
//! the carrier. Outer steps skip whole carrier periods; one fine-resolution
//! period per outer step feeds the peak/RMS envelope extraction.
const std = @import("std");
const root = @import("root.zig");
const newton = @import("newton.zig");

pub const Options = struct {
    /// Carrier period (1 / f_carrier).
    t_carrier: f64,
    /// Total simulation time (covers the full modulation envelope).
    t_stop: f64,
    /// Fraction of T_carrier per inner tran timestep (smaller = more accurate carrier resolution).
    carrier_steps_per_period: u32 = 64,
    /// Number of carrier periods per outer envelope step. 1 = sample every period.
    periods_per_outer_step: u32 = 1,
    /// Newton convergence tolerance for the inner transient solve.
    newton_tol: f64 = 1e-9,
    /// Maximum Newton iterations per inner timestep.
    max_newton_iter: u16 = 50,
    /// Maximum total outer (envelope) steps before giving up.
    max_outer_steps: u32 = 1_000_000,
    /// Envelope rate-of-change tolerance for adaptive outer stepping.
    /// If the relative change in envelope between two outer steps exceeds this,
    /// the outer step is halved.
    envelope_reltol: f64 = 0.05,
    /// Minimum outer step expressed as a multiple of T_carrier.
    min_periods_per_step: u32 = 1,
    /// Maximum outer step expressed as a multiple of T_carrier.
    max_periods_per_step: u32 = 16,
};

pub const SimResult = struct {
    completed: bool,
    outer_steps: u32,
    t_final: f64,
    /// Rows actually written into the caller's buffer.
    n_points: u32,
};

/// Upper bound on recorded envelope points: every accepted outer step
/// advances at least min_periods_per_step * t_carrier, plus the initial
/// point (and one row of float-rounding slack).
pub fn maxPoints(options: Options) u32 {
    const min_step = @as(f64, @floatFromInt(@max(options.min_periods_per_step, 1))) * options.t_carrier;
    const by_time = @ceil(options.t_stop / min_step);
    const cap = @as(f64, @floatFromInt(options.max_outer_steps));
    return @as(u32, @intFromFloat(@min(by_time, cap))) + 2;
}

/// One quasi-static Newton solve at absolute time t: assemble = ckt.eval,
/// matrix = G. Shared workspace; returns convergence only.
fn newtonAt(
    ckt: *root.Circuit,
    ws: *newton.Workspace,
    x: []f64,
    t: f64,
    options: Options,
) bool {
    const nr = newton.solve(ckt, &ws.slv, x, ws.dx, ws.x_old, t, .{
        .max_iter = options.max_newton_iter,
        .abstol = options.newton_tol,
        .gmin = 1e-12,
    }, newton.EvalHook{}) catch return false;
    return nr.converged;
}

/// Envelope-following transient analysis.
///
/// Runs a fast inner transient integration over one carrier period at each
/// outer envelope step. Extracts peak and RMS values from the inner waveform
/// to build the slowly-varying envelope. The outer step size adapts based on
/// the rate of change of the envelope.
///
/// This is efficient when T_modulation >> T_carrier: instead of simulating
/// every carrier cycle with tiny timesteps, we skip between carrier periods,
/// only running a full-resolution inner sim for one period at each sample.
///
/// Caller owns `rows`: point-major envelope samples with stride
/// 1 + 2*probes.len, row = [t, peak_p0, rms_p0, peak_p1, rms_p1, ...];
/// size it with maxPoints(options). SimResult.n_points rows are written.
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
    var ws = try newton.Workspace.init(allocator, ckt);
    defer ws.deinit(allocator);

    // One scratch alloc: [x_save | x_outer_save | prev_peak | peak | sum_sq]
    const scratch = try allocator.alloc(f64, 2 * n + 3 * probes.len);
    defer allocator.free(scratch);
    const x_save = scratch[0..n];
    const x_outer_save = scratch[n .. 2 * n];
    // Previous envelope values for adaptive stepping (one per probe),
    // plus envelope extraction scratch.
    const prev_peak = scratch[2 * n ..][0..probes.len];
    const peak = scratch[2 * n + probes.len ..][0..probes.len];
    const sum_sq = scratch[2 * n + 2 * probes.len ..][0..probes.len];

    // Inner tran timestep
    const dt_inner: f64 = t_carrier / @as(f64, @floatFromInt(options.carrier_steps_per_period));

    // Record initial envelope point (DC operating point)
    var n_pts: u32 = 1;
    {
        const row = rows[0..ncols];
        row[0] = 0;
        for (probes, 0..) |node, p| {
            row[1 + 2 * p] = x[node]; // peak
            row[2 + 2 * p] = @abs(x[node]); // rms
        }
    }

    var t: f64 = 0;
    var outer_steps: u32 = 0;
    var periods_per_step: u32 = options.periods_per_outer_step;

    for (probes, 0..) |node, p| {
        prev_peak[p] = x[node];
    }

    while (t < options.t_stop and outer_steps < options.max_outer_steps) {
        @memcpy(x_outer_save, x);

        // Outer step size: advance by periods_per_step carrier periods
        const t_outer_step = @as(f64, @floatFromInt(periods_per_step)) * t_carrier;
        const t_target = @min(t + t_outer_step, options.t_stop);
        const actual_outer_dt = t_target - t;

        // Advance the solution to t_target by running the inner transient.
        // We only need detailed carrier resolution for the last carrier period
        // to extract the envelope. For intermediate periods we can take larger steps.
        //
        // Strategy: skip to t_target - T_carrier with coarse steps, then run
        // one full carrier period with fine steps for envelope extraction.

        const t_fine_start = if (actual_outer_dt > t_carrier)
            t_target - t_carrier
        else
            t;

        // Coarse advance: skip intermediate carrier periods
        if (t_fine_start > t) {
            const coarse_ok = coarseAdvance(
                ckt,
                &ws,
                x,
                t,
                t_fine_start - t,
                dt_inner * 4.0, // coarse step = 4x inner step
                options,
            );
            if (!coarse_ok) {
                // Coarse advance failed to converge; halve outer step
                periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
                @memcpy(x, x_outer_save);
                continue;
            }
        }

        // Fine-resolution inner transient over one carrier period.
        // Track peak and RMS for envelope extraction.
        for (probes, 0..) |node, p| {
            peak[p] = @abs(x[node]);
            sum_sq[p] = x[node] * x[node];
        }
        var n_samples: u32 = 1;

        var t_inner: f64 = 0;
        const fine_duration = t_target - t_fine_start;
        while (t_inner < fine_duration) {
            @memcpy(x_save, x);

            const inner_converged = newtonAt(ckt, &ws, x, t_fine_start + t_inner + dt_inner, options);
            if (!inner_converged) {
                @memcpy(x, x_save);
                // If even the inner step fails, the outer step is too aggressive
                periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
                break;
            }

            t_inner += dt_inner;
            n_samples += 1;

            for (probes, 0..) |node, p| {
                const v = x[node];
                peak[p] = @max(peak[p], @abs(v));
                sum_sq[p] += v * v;
            }
        }

        if (t_inner < fine_duration) {
            // Inner sim did not complete; retry with smaller outer step
            @memcpy(x, x_outer_save);
            continue;
        }

        // Compute envelope metrics
        t = t_target;
        outer_steps += 1;

        const row = rows[n_pts * ncols ..][0..ncols];
        row[0] = t;
        n_pts += 1;

        var max_rel_change: f64 = 0;
        for (probes, 0..) |_, p| {
            const rms = @sqrt(sum_sq[p] / @as(f64, @floatFromInt(n_samples)));

            row[1 + 2 * p] = peak[p];
            row[2 + 2 * p] = rms;

            // Track envelope rate of change for adaptive stepping
            const denom = @max(@abs(prev_peak[p]), 1e-15);
            const rel_change = @abs(peak[p] - prev_peak[p]) / denom;
            max_rel_change = @max(max_rel_change, rel_change);

            prev_peak[p] = peak[p];
        }

        // Adapt outer step size based on envelope rate of change
        if (max_rel_change > options.envelope_reltol) {
            // Envelope changing fast: reduce outer step
            periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
        } else if (max_rel_change < options.envelope_reltol * 0.25) {
            // Envelope changing slowly: increase outer step
            periods_per_step = @min(periods_per_step * 2, options.max_periods_per_step);
        }
    }

    return .{
        .completed = t >= options.t_stop,
        .outer_steps = outer_steps,
        .t_final = t,
        .n_points = n_pts,
    };
}

/// Coarse advance: quasi-static Newton solves with larger timesteps to skip
/// intermediate carrier periods where we do not need fine resolution.
fn coarseAdvance(
    ckt: *root.Circuit,
    ws: *newton.Workspace,
    x: []f64,
    t_start: f64,
    duration: f64,
    dt_coarse: f64,
    options: Options,
) bool {
    var t_elapsed: f64 = 0;
    while (t_elapsed < duration) {
        const dt = @min(dt_coarse, duration - t_elapsed);
        if (!newtonAt(ckt, ws, x, t_start + t_elapsed + dt, options)) return false;
        t_elapsed += dt_coarse;
    }
    return true;
}

/// Extract peak value from a waveform slice.
pub fn extractPeak(values: []const f64) f64 {
    var peak: f64 = 0;
    for (values) |v| {
        peak = @max(peak, @abs(v));
    }
    return peak;
}

/// Extract RMS value from a waveform slice.
pub fn extractRMS(values: []const f64) f64 {
    if (values.len == 0) return 0;
    var sum_sq: f64 = 0;
    for (values) |v| {
        sum_sq += v * v;
    }
    return @sqrt(sum_sq / @as(f64, @floatFromInt(values.len)));
}

/// Contract entry: envelope-follow from ctx.x_op. Data layout: point-major
/// rows (time, peak/rms per probe) — the same rows simulate() writes.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const x = try a.dupe(f64, x_op);
    defer a.free(x);

    const ncols = 1 + 2 * ctx.probes.len;
    const data = try a.alloc(f64, @as(usize, maxPoints(opts)) * ncols);
    const st = try simulate(ctx.circuit, x, ctx.probes, data, opts, a);
    if (!st.completed)
        std.debug.print("Warning: envelope stopped early at t={e}\n", .{st.t_final});

    const names = try a.alloc([]const u8, ncols);
    names[0] = "time";
    for (ctx.probes, 0..) |node, p| {
        const label = ctx.circuit.nodeName(node);
        const l = if (label.len == 0) "?" else label;
        names[1 + p * 2] = try std.fmt.allocPrint(a, "peak(v({s}))", .{l});
        names[2 + p * 2] = try std.fmt.allocPrint(a, "rms(v({s}))", .{l});
    }

    const npoints: usize = st.n_points;
    return .{
        .plotname = "Envelope Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data[0 .. npoints * ncols],
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "envelope: extractPeak finds absolute maximum" {
    const vals = [_]f64{ 1.0, -3.0, 2.0, -1.5, 0.5 };
    const peak = extractPeak(&vals);
    try testing.expectApproxEqAbs(@as(f64, 3.0), peak, 1e-15);
}

test "envelope: extractRMS of constant signal equals absolute value" {
    const vals = [_]f64{ 2.0, 2.0, 2.0, 2.0 };
    const rms = extractRMS(&vals);
    try testing.expectApproxEqAbs(@as(f64, 2.0), rms, 1e-15);
}

test "envelope: extractRMS of sine wave is amplitude/sqrt(2)" {
    // Generate one full period of sin
    const n = 1024;
    var vals: [n]f64 = undefined;
    const amplitude = 3.0;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        vals[k] = amplitude * @sin(2.0 * std.math.pi * t);
    }
    const rms = extractRMS(&vals);
    const expected_rms = amplitude / @sqrt(2.0);
    try testing.expectApproxEqRel(expected_rms, rms, 1e-4);
}
test "envelope: extractRMS of empty slice returns zero" {
    const empty: []const f64 = &.{};
    try testing.expectEqual(@as(f64, 0), extractRMS(empty));
}

test "envelope: extractPeak of single element" {
    const vals = [_]f64{-7.5};
    try testing.expectApproxEqAbs(@as(f64, 7.5), extractPeak(&vals), 1e-15);
}
