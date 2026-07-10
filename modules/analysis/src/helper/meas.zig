const std = @import("std");

/// Measurement result: a scalar extracted from a waveform.
pub const Result = struct {
    name: []const u8,
    value: f64,
};

/// Waveform data: parallel arrays of time points and values.
/// Matches tran.Waveform layout — caller passes .timeSlice() and .probeValues(k).
pub const Waveform = struct {
    times: []const f64,
    values: []const f64,

    pub fn len(self: Waveform) usize {
        return @min(self.times.len, self.values.len);
    }
};

/// Measurement type selector.
pub const MeasType = enum {
    max,
    min,
    pp,
    avg,
    rms,
    rise_time,
    fall_time,
    frequency,
};

/// Options for threshold-based measurements (rise_time, fall_time, delay).
pub const ThresholdOpts = struct {
    lo: f64 = 0.1,
    hi: f64 = 0.9,
};

// ============================================================================
// Core measurement functions
// ============================================================================

/// Peak maximum value.
pub fn max(wf: Waveform) f64 {
    const n = wf.len();
    if (n == 0) return 0;
    var result: f64 = wf.values[0];
    for (wf.values[1..n]) |v| {
        result = @max(result, v);
    }
    return result;
}

/// Peak minimum value.
pub fn min(wf: Waveform) f64 {
    const n = wf.len();
    if (n == 0) return 0;
    var result: f64 = wf.values[0];
    for (wf.values[1..n]) |v| {
        result = @min(result, v);
    }
    return result;
}

/// Peak-to-peak: max - min.
pub fn pp(wf: Waveform) f64 {
    return max(wf) - min(wf);
}

/// Time-weighted average using trapezoidal integration.
pub fn avg(wf: Waveform) f64 {
    const n = wf.len();
    if (n < 2) return if (n == 1) wf.values[0] else 0;

    var integral: f64 = 0;
    for (1..n) |k| {
        const dt = wf.times[k] - wf.times[k - 1];
        integral += 0.5 * (wf.values[k - 1] + wf.values[k]) * dt;
    }
    const t_span = wf.times[n - 1] - wf.times[0];
    if (t_span == 0) return wf.values[0];
    return integral / t_span;
}

/// Root-mean-square via trapezoidal integration of v^2.
pub fn rms(wf: Waveform) f64 {
    const n = wf.len();
    if (n < 2) return if (n == 1) @abs(wf.values[0]) else 0;

    var integral: f64 = 0;
    for (1..n) |k| {
        const dt = wf.times[k] - wf.times[k - 1];
        const v0_sq = wf.values[k - 1] * wf.values[k - 1];
        const v1_sq = wf.values[k] * wf.values[k];
        integral += 0.5 * (v0_sq + v1_sq) * dt;
    }
    const t_span = wf.times[n - 1] - wf.times[0];
    if (t_span == 0) return @abs(wf.values[0]);
    return @sqrt(integral / t_span);
}

/// Rise time: time for signal to go from lo fraction to hi fraction of its
/// full swing. lo and hi are fractions of the peak-to-peak range measured
/// from the minimum value (e.g. 0.1 = 10%, 0.9 = 90%).
pub fn rise_time(wf: Waveform, opts: ThresholdOpts) f64 {
    const n = wf.len();
    if (n < 2) return 0;

    const v_min = min(wf);
    const v_max = max(wf);
    const swing = v_max - v_min;
    if (swing == 0) return 0;

    const lo_thresh = v_min + opts.lo * swing;
    const hi_thresh = v_min + opts.hi * swing;

    // Find first upward crossing of lo_thresh
    const t_lo = findCrossing(wf, lo_thresh, .rising) orelse return 0;
    // Find first upward crossing of hi_thresh after t_lo
    const t_hi = findCrossingAfter(wf, hi_thresh, .rising, t_lo) orelse return 0;

    return t_hi - t_lo;
}

/// Fall time: time for signal to go from hi fraction to lo fraction of its
/// full swing. hi and lo are fractions of the peak-to-peak range measured
/// from the minimum value (e.g. 0.9 = 90%, 0.1 = 10%).
pub fn fall_time(wf: Waveform, opts: ThresholdOpts) f64 {
    const n = wf.len();
    if (n < 2) return 0;

    const v_min = min(wf);
    const v_max = max(wf);
    const swing = v_max - v_min;
    if (swing == 0) return 0;

    const hi_thresh = v_min + opts.hi * swing;
    const lo_thresh = v_min + opts.lo * swing;

    // Find first downward crossing of hi_thresh
    const t_hi = findCrossing(wf, hi_thresh, .falling) orelse return 0;
    // Find first downward crossing of lo_thresh after t_hi
    const t_lo = findCrossingAfter(wf, lo_thresh, .falling, t_hi) orelse return 0;

    return t_lo - t_hi;
}

/// Propagation delay: time between threshold crossings on two different
/// waveforms. Both waveforms must share the same time base.
pub fn delay(wf1: Waveform, wf2: Waveform, threshold: f64) f64 {
    const t1 = findCrossing(wf1, threshold, .rising) orelse return 0;
    const t2 = findCrossing(wf2, threshold, .rising) orelse return 0;
    return @abs(t2 - t1);
}

/// Frequency measurement via zero-crossing period detection.
/// Measures the average period from consecutive rising zero-crossings.
pub fn frequency(wf: Waveform) f64 {
    const n = wf.len();
    if (n < 3) return 0;

    // Use average as the DC offset / crossing level
    const dc_offset = avg(wf);

    var first_crossing: ?f64 = null;
    var last_crossing: ?f64 = null;
    var crossing_count: u32 = 0;

    for (1..n) |k| {
        // Rising crossing of dc_offset
        if (wf.values[k - 1] < dc_offset and wf.values[k] >= dc_offset) {
            // Linear interpolation for exact crossing time
            const frac = (dc_offset - wf.values[k - 1]) / (wf.values[k] - wf.values[k - 1]);
            const t_cross = wf.times[k - 1] + frac * (wf.times[k] - wf.times[k - 1]);

            if (first_crossing == null) {
                first_crossing = t_cross;
            }
            last_crossing = t_cross;
            crossing_count += 1;
        }
    }

    if (crossing_count < 2) return 0;
    const total_time = last_crossing.? - first_crossing.?;
    if (total_time <= 0) return 0;
    const periods = @as(f64, @floatFromInt(crossing_count - 1));
    return periods / total_time;
}

/// Run a measurement by type enum.
pub fn measure(wf: Waveform, mtype: MeasType, opts: ThresholdOpts) f64 {
    return switch (mtype) {
        .max => max(wf),
        .min => min(wf),
        .pp => pp(wf),
        .avg => avg(wf),
        .rms => rms(wf),
        .rise_time => rise_time(wf, opts),
        .fall_time => fall_time(wf, opts),
        .frequency => frequency(wf),
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

const CrossingDir = enum { rising, falling };

/// Find first crossing of threshold in the given direction. Returns
/// linearly-interpolated time, or null if no crossing found.
fn findCrossing(wf: Waveform, threshold: f64, dir: CrossingDir) ?f64 {
    const n = wf.len();
    if (n < 2) return null;

    for (1..n) |k| {
        const cross = switch (dir) {
            .rising => wf.values[k - 1] < threshold and wf.values[k] >= threshold,
            .falling => wf.values[k - 1] > threshold and wf.values[k] <= threshold,
        };
        if (cross) {
            const dv = wf.values[k] - wf.values[k - 1];
            if (@abs(dv) < 1e-30) return wf.times[k];
            const frac = (threshold - wf.values[k - 1]) / dv;
            return wf.times[k - 1] + frac * (wf.times[k] - wf.times[k - 1]);
        }
    }
    return null;
}

/// Find first crossing of threshold in the given direction that occurs
/// strictly after t_after. Returns linearly-interpolated time, or null.
fn findCrossingAfter(wf: Waveform, threshold: f64, dir: CrossingDir, t_after: f64) ?f64 {
    const n = wf.len();
    if (n < 2) return null;

    for (1..n) |k| {
        if (wf.times[k] <= t_after) continue;

        const cross = switch (dir) {
            .rising => wf.values[k - 1] < threshold and wf.values[k] >= threshold,
            .falling => wf.values[k - 1] > threshold and wf.values[k] <= threshold,
        };
        if (cross) {
            const dv = wf.values[k] - wf.values[k - 1];
            if (@abs(dv) < 1e-30) return wf.times[k];
            const frac = (threshold - wf.values[k - 1]) / dv;
            return wf.times[k - 1] + frac * (wf.times[k] - wf.times[k - 1]);
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Generate a sinusoidal waveform: v(t) = amplitude * sin(2*pi*freq*t + phase) + dc_offset
fn generateSine(
    times: []f64,
    values: []f64,
    n_points: usize,
    t_stop: f64,
    freq_hz: f64,
    amplitude: f64,
    dc_offset: f64,
    phase: f64,
) void {
    for (0..n_points) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) * t_stop;
        times[k] = t;
        values[k] = amplitude * @sin(2.0 * std.math.pi * freq_hz * t + phase) + dc_offset;
    }
}

test "meas: max/min/pp on sine wave" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const amplitude = 3.3;
    const freq_hz = 1e6;
    const t_stop = 10.0 / freq_hz; // 10 full cycles
    generateSine(&times, &values, n_points, t_stop, freq_hz, amplitude, 0, 0);

    const wf = Waveform{ .times = &times, .values = &values };

    try testing.expectApproxEqAbs(amplitude, max(wf), 1e-3);
    try testing.expectApproxEqAbs(-amplitude, min(wf), 1e-3);
    try testing.expectApproxEqAbs(2.0 * amplitude, pp(wf), 1e-3);
}

test "meas: avg of pure sine is zero (no DC offset)" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const freq_hz = 1e6;
    const t_stop = 10.0 / freq_hz;
    generateSine(&times, &values, n_points, t_stop, freq_hz, 1.0, 0, 0);

    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqAbs(@as(f64, 0), avg(wf), 1e-3);
}

test "meas: avg of sine with DC offset equals offset" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const dc = 2.5;
    const freq_hz = 1e6;
    const t_stop = 10.0 / freq_hz;
    generateSine(&times, &values, n_points, t_stop, freq_hz, 1.0, dc, 0);

    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqAbs(dc, avg(wf), 1e-3);
}

test "meas: rms of sine = peak / sqrt(2)" {
    const n_points = 100000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const amplitude = 5.0;
    const freq_hz = 1e3;
    const t_stop = 100.0 / freq_hz; // many full cycles for accuracy
    generateSine(&times, &values, n_points, t_stop, freq_hz, amplitude, 0, 0);

    const wf = Waveform{ .times = &times, .values = &values };
    const expected_rms = amplitude / @sqrt(2.0);
    try testing.expectApproxEqAbs(expected_rms, rms(wf), 1e-3);
}

test "meas: frequency matches input" {
    const n_points = 100000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const freq_hz = 1e6;
    const t_stop = 20.0 / freq_hz;
    generateSine(&times, &values, n_points, t_stop, freq_hz, 1.0, 0, 0);

    const wf = Waveform{ .times = &times, .values = &values };
    const measured_freq = frequency(wf);
    try testing.expectApproxEqRel(freq_hz, measured_freq, 1e-3);
}

test "meas: rise time on ramp-like signal" {
    // Create a signal that ramps from 0 to 1 between t=1us and t=3us
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const t_stop = 5e-6;
    const t_rise_start = 1e-6;
    const t_rise_end = 3e-6;

    for (0..n_points) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) * t_stop;
        times[k] = t;
        if (t < t_rise_start) {
            values[k] = 0;
        } else if (t > t_rise_end) {
            values[k] = 1.0;
        } else {
            values[k] = (t - t_rise_start) / (t_rise_end - t_rise_start);
        }
    }

    const wf = Waveform{ .times = &times, .values = &values };
    // 10%-90% of 2us ramp = 0.8 * 2us = 1.6us
    const rt = rise_time(wf, .{ .lo = 0.1, .hi = 0.9 });
    const expected = 0.8 * (t_rise_end - t_rise_start);
    try testing.expectApproxEqAbs(expected, rt, 1e-8);
}

test "meas: fall time on ramp-down signal" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const t_stop = 5e-6;
    const t_fall_start = 1e-6;
    const t_fall_end = 3e-6;

    for (0..n_points) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) * t_stop;
        times[k] = t;
        if (t < t_fall_start) {
            values[k] = 1.0;
        } else if (t > t_fall_end) {
            values[k] = 0;
        } else {
            values[k] = 1.0 - (t - t_fall_start) / (t_fall_end - t_fall_start);
        }
    }

    const wf = Waveform{ .times = &times, .values = &values };
    // 90%-10% of 2us ramp = 0.8 * 2us = 1.6us
    const ft = fall_time(wf, .{ .lo = 0.1, .hi = 0.9 });
    const expected = 0.8 * (t_fall_end - t_fall_start);
    try testing.expectApproxEqAbs(expected, ft, 1e-8);
}

test "meas: delay between two signals" {
    // Signal 1 starts at t=0 with phase=0: first rising zero-crossing at t=0.
    // Signal 2 starts at t=0 with a positive phase offset, so its first
    // rising zero-crossing is earlier (negative time), making the first
    // observable rising crossing at t = period - (phase / (2*pi*freq)).
    // Instead, directly construct two ramp signals with known crossing times.
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values1: [n_points]f64 = undefined;
    var values2: [n_points]f64 = undefined;

    const t_stop = 5e-6;
    const cross1 = 1e-6; // signal 1 crosses 0.5 at t=1us
    const cross2 = 1.3e-6; // signal 2 crosses 0.5 at t=1.3us
    const expected_delay = cross2 - cross1; // 0.3us

    for (0..n_points) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) * t_stop;
        times[k] = t;
        // Ramp from 0 to 1 around the crossing time (width 0.2us)
        values1[k] = std.math.clamp((t - cross1 + 0.1e-6) / 0.2e-6, 0, 1.0);
        values2[k] = std.math.clamp((t - cross2 + 0.1e-6) / 0.2e-6, 0, 1.0);
    }

    const wf1 = Waveform{ .times = &times, .values = &values1 };
    const wf2 = Waveform{ .times = &times, .values = &values2 };

    const measured_delay = delay(wf1, wf2, 0.5);
    try testing.expectApproxEqAbs(expected_delay, measured_delay, 1e-9);
}

test "meas: measure dispatch function" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const amplitude = 2.0;
    const freq_hz = 1e6;
    const t_stop = 10.0 / freq_hz;
    generateSine(&times, &values, n_points, t_stop, freq_hz, amplitude, 0, 0);

    const wf = Waveform{ .times = &times, .values = &values };

    const v_max = measure(wf, .max, .{});
    try testing.expectApproxEqAbs(amplitude, v_max, 1e-3);

    const v_pp = measure(wf, .pp, .{});
    try testing.expectApproxEqAbs(2.0 * amplitude, v_pp, 1e-3);
}

test "meas: single-point waveform edge cases" {
    const times = [_]f64{0};
    const values = [_]f64{3.14};
    const wf = Waveform{ .times = &times, .values = &values };

    try testing.expectApproxEqAbs(@as(f64, 3.14), max(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.14), min(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), pp(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.14), avg(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.14), rms(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), frequency(wf), 1e-15);
}

test "meas: empty waveform returns zero" {
    const wf = Waveform{ .times = &.{}, .values = &.{} };

    try testing.expectApproxEqAbs(@as(f64, 0), max(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), min(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), pp(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), avg(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), rms(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), frequency(wf), 1e-15);
}

test "meas: DC signal has zero pp and rms equals magnitude" {
    const n_points = 1000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;

    const dc_val = 3.3;
    for (0..n_points) |k| {
        times[k] = @as(f64, @floatFromInt(k)) * 1e-9;
        values[k] = dc_val;
    }

    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqAbs(@as(f64, 0), pp(wf), 1e-15);
    try testing.expectApproxEqAbs(dc_val, rms(wf), 1e-12);
    try testing.expectApproxEqAbs(dc_val, avg(wf), 1e-12);
}
