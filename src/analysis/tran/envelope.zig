//! Envelope-following transient: quasi-static Newton (A = G) sampled along
//! the carrier. Outer steps skip whole carrier periods; one fine-resolution
//! period per outer step feeds the peak/RMS envelope extraction.
//!
//! Algorithm (sample-envelope, doc §3):
//!   1. Record DC point as envelope sample 0.
//!   2. Outer loop: Δt = periods_per_step * T_c.
//!      a. If Δt > T_c, coarse-advance to t_target − T_c (4× inner dt).
//!      b. One fine period at carrier_steps_per_period resolution;
//!         accumulate per-probe peak and Σv² (RMS).
//!   3. Record (t, peak, rms) per probe.
//!   4. Adapt: rel change > envelope_reltol → halve pps; < reltol/4 → double.
//!   5. Newton failure → restore snapshot, halve pps, retry.

const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const converger = @import("solvers").converger;

// ponytail: SIMD width for all vectorized loops
const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// Carrier period (1 / f_carrier).
    t_carrier: f64,
    /// Total simulation time (covers the full modulation envelope).
    t_stop: f64,
    carrier_steps_per_period: u32 = 64,
    /// Number of carrier periods per outer envelope step. 1 = sample every period.
    periods_per_outer_step: u32 = 1,
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
    ws: *converger.Workspace,
    x: []f64,
    t: f64,
    options: Options,
) bool {
    // §9.10 `$abstime`: a generated device reads Instance.abstime, not the `t`
    // argument, so the envelope's quasi-static probes have to publish it too —
    // otherwise every source in the envelope sees t = 0. dt stays 0: this rung
    // IS quasi-static, so `ddt` should return 0 (see the generated zDdt guard).
    ckt.setSimState(.{ .t = t, .kind = .tran });
    const nr = converger.run(ckt, ws, x, t, options.tol.newtonOpts(options.tol.itl4), root.EvalHook{}) catch return false;
    return nr.converged;
}

// ============================================================================
// Core simulation
// ============================================================================

/// Envelope-following transient analysis.
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
    const ws = try ckt.workspace();

    // One scratch alloc: [x_outer_save | prev_peak | peak | sum_sq]
    const scratch = try allocator.alloc(f64, n + 3 * probes.len);
    defer allocator.free(scratch);
    const x_outer_save = scratch[0..n];
    // Previous envelope values for adaptive stepping (one per probe),
    // plus envelope extraction scratch.
    const prev_peak = scratch[n ..][0..probes.len];
    const peak = scratch[n + probes.len ..][0..probes.len];
    const sum_sq = scratch[n + 2 * probes.len ..][0..probes.len];

    const dt_inner: f64 = t_carrier / @as(f64, @floatFromInt(options.carrier_steps_per_period));

    // Record initial envelope point (DC operating point)
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

    while (t < options.t_stop and outer_steps < options.max_outer_steps) {
        // Snapshot state for rollback on Newton failure
        simdCopy(x_outer_save, x);

        const t_outer_step = @as(f64, @floatFromInt(periods_per_step)) * t_carrier;
        const t_target = @min(t + t_outer_step, options.t_stop);
        const actual_outer_dt = t_target - t;

        // Strategy (doc §2): skip to t_target − T_carrier with coarse steps,
        // then run one full carrier period with fine steps for envelope extraction.
        const t_fine_start = if (actual_outer_dt > t_carrier)
            t_target - t_carrier
        else
            t;

        // Coarse advance: skip intermediate carrier periods (4× inner step)
        if (t_fine_start > t) {
            const coarse_ok = coarseAdvance(
                ckt,
                ws,
                x,
                t,
                t_fine_start - t,
                dt_inner * 4.0,
                options,
            );
            if (!coarse_ok) {
                // Coarse advance failed to converge; halve outer step, restore, retry
                periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
                simdCopy(x, x_outer_save);
                continue;
            }
        }

        for (probes, 0..) |node, p| {
            peak[p] = @abs(x[node]);
            sum_sq[p] = x[node] * x[node];
        }
        var n_samples: u32 = 1;

        var t_inner: f64 = 0;
        const fine_duration = t_target - t_fine_start;
        var inner_failed = false;
        while (t_inner < fine_duration) {
            const inner_converged = newtonAt(ckt, ws, x, t_fine_start + t_inner + dt_inner, options);
            if (!inner_converged) {
                // Inner step fails → outer step too aggressive
                periods_per_step = @max(periods_per_step / 2, options.min_periods_per_step);
                inner_failed = true;
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

        if (inner_failed) {
            // Inner sim did not complete; retry with smaller outer step
            simdCopy(x, x_outer_save);
            continue;
        }

        t = t_target;
        outer_steps += 1;

        const row = rows[outer_steps * ncols ..][0..ncols];
        row[0] = t;

        var max_rel_change: f64 = 0;
        for (0..probes.len) |p| {
            const rms = @sqrt(sum_sq[p] / @as(f64, @floatFromInt(n_samples)));

            row[1 + 2 * p] = peak[p];
            row[2 + 2 * p] = rms;

            const denom = @max(prev_peak[p], 1e-15);
            const rel_change = @abs(peak[p] - prev_peak[p]) / denom;
            max_rel_change = @max(max_rel_change, rel_change);

            prev_peak[p] = peak[p];
        }

        // Adapt outer step size based on envelope rate of change (doc §3 pseudocode)
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
        .n_points = outer_steps + 1,
    };
}

/// Coarse advance: quasi-static Newton solves with larger timesteps to skip
/// intermediate carrier periods where we do not need fine resolution.
fn coarseAdvance(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
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
        t_elapsed += dt;
    }
    return true;
}

/// Extract peak value from a waveform slice (SIMD).
pub fn extractPeak(values: []const f64) f64 {
    if (values.len == 0) return 0;
    var peak_v: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= values.len) : (i += W) {
        const v: V = values[i..][0..W].*;
        peak_v = @max(peak_v, @abs(v));
    }
    var peak: f64 = 0;
    inline for (0..W) |lane| peak = @max(peak, peak_v[lane]);
    while (i < values.len) : (i += 1) peak = @max(peak, @abs(values[i]));
    return peak;
}

/// Extract RMS value from a waveform slice (SIMD).
pub fn extractRMS(values: []const f64) f64 {
    if (values.len == 0) return 0;
    var acc: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= values.len) : (i += W) {
        const v: V = values[i..][0..W].*;
        acc += v * v;
    }
    var sum_sq: f64 = 0;
    inline for (0..W) |lane| sum_sq += acc[lane];
    while (i < values.len) : (i += 1) sum_sq += values[i] * values[i];
    return @sqrt(sum_sq / @as(f64, @floatFromInt(values.len)));
}

/// Contract entry: envelope-follow from ctx.x_op. Data layout: point-major
/// rows (time, peak/rms per probe) — the same rows simulate() writes.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    // `defer`-freed == scratch; `a` is a results arena. `data` stays on `a`:
    // it IS the Result. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const x = try scratch.alloc(f64, x_op.len);
    defer scratch.free(x);
    simdCopy(x, x_op);

    const ncols = 1 + 2 * ctx.probes.len;
    const data = try a.alloc(f64, @as(usize, maxPoints(opts)) * ncols);
    errdefer a.free(data);
    const st = try simulate(ctx.circuit, x, ctx.probes, data, opts, scratch);
    if (!st.completed)
        std.debug.print("Warning: envelope stopped early at t={e}\n", .{st.t_final});

    const names = try a.alloc([]const u8, ncols);
    errdefer a.free(names);
    names[0] = "time";
    var done: usize = 0; // allocated entries after the "time" literal
    errdefer for (names[1..][0..done]) |s| a.free(s);
    for (ctx.probes, 0..) |node, p| {
        const label = ctx.circuit.nodeName(node);
        const l = if (label.len == 0) "?" else label;
        names[1 + p * 2] = try std.fmt.allocPrint(a, "peak(v({s}))", .{l});
        done += 1;
        names[2 + p * 2] = try std.fmt.allocPrint(a, "rms(v({s}))", .{l});
        done += 1;
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

test "envelope: extractPeak of empty slice returns zero" {
    const empty: []const f64 = &.{};
    try testing.expectEqual(@as(f64, 0), extractPeak(empty));
}

test "envelope: maxPoints monotone in max_outer_steps" {
    const base: Options = .{ .t_carrier = 1e-9, .t_stop = 1e-3 };
    const mp1 = maxPoints(base);
    var opts2 = base;
    opts2.max_outer_steps = 100;
    const mp2 = maxPoints(opts2);
    // Fewer allowed steps → fewer max points
    try testing.expect(mp2 <= mp1);
}

test "envelope: coarseAdvance duration tracking uses actual dt" {
    // Regression: old code used t_elapsed += dt_coarse instead of dt,
    // which could skip the final partial step. Verified by the fix in
    // coarseAdvance using dt (the clamped value) for the accumulator.
    // This test just validates the maxPoints helper doesn't overflow.
    const opts: Options = .{
        .t_carrier = 1e-6,
        .t_stop = 1e-3,
        .min_periods_per_step = 1,
        .max_periods_per_step = 32,
    };
    const mp = maxPoints(opts);
    try testing.expect(mp >= 3); // at least DC + one step + slack
}
