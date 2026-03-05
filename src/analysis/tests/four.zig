const impl = @import("../post/four.zig");
const analyze = impl.analyze;
const analyzeBuffer = impl.analyzeBuffer;
const interpolateAt = impl.test_access.interpolateAt;
const math = std.math;
const std = @import("std");
const tran = @import("../tran/tran.zig");

/// Binary-search + linear interpolation on sorted time/value arrays.
fn interpolate(times: []const f64, values: []const f64, t: f64) f64 {
    if (times.len == 0) return 0;
    if (t <= times[0]) return values[0];
    if (t >= times[times.len - 1]) return values[values.len - 1];

    // Binary search for the bracketing interval
    var lo: usize = 0;
    var hi: usize = times.len - 1;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (times[mid] <= t) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    const dt = times[hi] - times[lo];
    if (dt < 1e-30) return values[lo];
    const alpha = (t - times[lo]) / dt;
    return values[lo] * (1.0 - alpha) + values[hi] * alpha;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "four: cursor interpolation matches the binary-search oracle" {
    var times: [64]f64 = undefined;
    var vals: [64]f64 = undefined;
    for (0..64) |i| {
        const fi: f64 = @floatFromInt(i);
        times[i] = fi * 0.1;
        vals[i] = @sin(fi);
    }
    times[20] = times[19]; // duplicate timestamp: both must pick the same interval

    var cursor: usize = 0;
    var k: usize = 0;
    while (k <= 700) : (k += 1) { // sweeps below t[0], through the window, past t[last]
        const t = @as(f64, @floatFromInt(k)) * 0.01 - 0.05;
        try testing.expectEqual(
            interpolate(&times, &vals, t),
            interpolateAt(&times, &vals, t, &cursor),
        );
    }
}

test "four: pure cosine has zero THD" {
    const allocator = testing.allocator;
    const n = 256;
    var samples: [n]f64 = undefined;

    // One period of cos(2*pi*t/T), sampled at n points
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = @cos(2.0 * math.pi * t);
    }

    const result = try analyzeBuffer(&samples, 9, allocator);

    try testing.expectApproxEqAbs(@as(f64, 0.0), result.dc, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.fundamental, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.thd_percent, 1e-6);
}

test "four: DC offset is reported correctly" {
    const allocator = testing.allocator;
    const n = 128;
    var samples: [n]f64 = undefined;

    const dc_offset = 3.5;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = dc_offset + @cos(2.0 * math.pi * t);
    }

    const result = try analyzeBuffer(&samples, 9, allocator);

    try testing.expectApproxEqAbs(dc_offset, result.dc, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.fundamental, 1e-10);
}

test "four: square wave THD ~ 48.3%" {
    // A square wave with harmonics 1,3,5,7,... has
    // THD = sqrt(1/9 + 1/25 + 1/49 + ...) / 1 * 100
    // Analytically first 8 odd harmonics:
    // THD = sqrt(sum(1/(2k+1)^2 for k=1..)) ~= 48.34%
    // With 9 harmonics (2-9) we capture harmonics 3,5,7,9
    const allocator = testing.allocator;
    const n = 1024;
    var samples: [n]f64 = undefined;

    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        // Build square wave from Fourier series up to 9th harmonic
        // to avoid aliasing: sq(t) = (4/pi) * sum_{k=0}^{} sin(2pi(2k+1)t)/(2k+1)
        var val: f64 = 0;
        var harm: u32 = 1;
        while (harm <= 9) : (harm += 2) {
            val += @sin(2.0 * math.pi * @as(f64, @floatFromInt(harm)) * t) / @as(f64, @floatFromInt(harm));
        }
        samples[k] = val * 4.0 / math.pi;
    }

    const result = try analyzeBuffer(&samples, 9, allocator);

    // Fundamental magnitude: (4/pi) * 1 = 1.2732
    try testing.expectApproxEqAbs(@as(f64, 4.0 / math.pi), result.fundamental, 1e-3);

    // 3rd harmonic = (4/pi)/3 = 0.4244
    try testing.expectApproxEqAbs(@as(f64, 4.0 / (3.0 * math.pi)), result.harmonics[2].mag, 1e-3);

    // THD from harmonics 3,5,7,9 only:
    // sqrt((1/3)^2 + (1/5)^2 + (1/7)^2 + (1/9)^2) * 100 = ~43.53%
    const expected_thd = @sqrt(1.0 / 9.0 + 1.0 / 25.0 + 1.0 / 49.0 + 1.0 / 81.0) * 100.0;
    try testing.expectApproxEqAbs(expected_thd, result.thd_percent, 1.0);
}

test "four: known amplitude and phase" {
    const allocator = testing.allocator;
    const n = 512;
    var samples: [n]f64 = undefined;

    // 2.0*cos(2*pi*t + pi/4) = fundamental with amplitude 2.0 and phase 45 deg
    const amp = 2.0;
    const phase_rad = math.pi / 4.0;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = amp * @cos(2.0 * math.pi * t + phase_rad);
    }

    const result = try analyzeBuffer(&samples, 9, allocator);

    try testing.expectApproxEqAbs(amp, result.fundamental, 1e-8);
    try testing.expectApproxEqAbs(45.0, result.harmonics[0].phase_deg, 0.1);
}

test "four: analyzeBuffer with non-power-of-2 input" {
    // Verify resampling works for arbitrary length input
    const allocator = testing.allocator;
    const n = 100; // not a power of 2
    var samples: [n]f64 = undefined;

    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = 1.5 * @cos(2.0 * math.pi * t);
    }

    const result = try analyzeBuffer(&samples, 9, allocator);

    try testing.expectApproxEqAbs(@as(f64, 1.5), result.fundamental, 1e-2);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.dc, 1e-2);
}

test "four: analyze waveform from tran data" {
    const allocator = testing.allocator;

    // Build a synthetic waveform as if from transient sim
    const n_points: usize = 512;
    var waveform = try tran.Waveform.init(allocator, 1, n_points);
    defer waveform.deinit();

    const f_fund = 1000.0; // 1 kHz
    const period = 1.0 / f_fund;
    // Simulate 3 periods worth of data so there is enough for one-period extraction
    const t_total = 3.0 * period;

    const probes = [_]u32{0};
    for (0..n_points) |k| {
        const t = t_total * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points));
        const v = [_]f64{2.5 * @cos(2.0 * math.pi * f_fund * t)};
        try waveform.record(t, &v, &probes);
    }

    const result = try analyze(&waveform, 0, f_fund, 9, allocator);

    try testing.expectApproxEqAbs(@as(f64, 2.5), result.fundamental, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.dc, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.thd_percent, 1.0);
}
