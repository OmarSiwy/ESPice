//! Fourier post-processing unit tests.

const impl = @import("../post/four.zig");
const analyze = impl.analyze;
const interpolateAt = impl.test_access.interpolateAt;
const math = std.math;
const std = @import("std");
const tran = @import("../tran/tran.zig");

/// Oracle for `interpolateAt`: binary search plus linear interpolation on
/// sorted time/value arrays, clamped at both ends.
fn interpolate(times: []const f64, values: []const f64, t: f64) f64 {
    if (times.len == 0) return 0;
    if (t <= times[0]) return values[0];
    if (t >= times[times.len - 1]) return values[values.len - 1];

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

/// Spectrum of one period sampled at a power-of-two count: the FFT and the
/// extraction `analyze` runs after its resampling step.
fn spectrumOf(samples: []const f64, n_harmonics: usize, allocator: std.mem.Allocator) !impl.Spectrum {
    const re = try allocator.dupe(f64, samples);
    defer allocator.free(re);
    const im = try allocator.alloc(f64, samples.len);
    defer allocator.free(im);
    @memset(im, 0);
    @import("solver").fft.fft(re, im);
    return impl.test_access.extractSpectrum(re, im, samples.len, n_harmonics);
}

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

    const result = try spectrumOf(&samples, 9, allocator);

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

    const result = try spectrumOf(&samples, 9, allocator);

    try testing.expectApproxEqAbs(dc_offset, result.dc, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.fundamental, 1e-10);
}

test "four: square wave THD ~ 48.3%" {
    // An ideal square wave has THD = sqrt(1/9 + 1/25 + 1/49 + ...) ~= 48.3%.
    // This one is band-limited to the 9th harmonic, so only 3, 5, 7, 9 count.
    const allocator = testing.allocator;
    const n = 1024;
    var samples: [n]f64 = undefined;

    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        // sq(t) = (4/pi) * sum over odd h <= 9 of sin(2*pi*h*t)/h
        var val: f64 = 0;
        var harm: u32 = 1;
        while (harm <= 9) : (harm += 2) {
            val += @sin(2.0 * math.pi * @as(f64, @floatFromInt(harm)) * t) / @as(f64, @floatFromInt(harm));
        }
        samples[k] = val * 4.0 / math.pi;
    }

    const result = try spectrumOf(&samples, 9, allocator);

    // Fundamental magnitude: (4/pi) * 1 = 1.2732
    try testing.expectApproxEqAbs(@as(f64, 4.0 / math.pi), result.fundamental, 1e-3);

    // 3rd harmonic = (4/pi)/3 = 0.4244
    try testing.expectApproxEqAbs(@as(f64, 4.0 / (3.0 * math.pi)), result.harmonics[2].mag, 1e-3);

    // sqrt((1/3)^2 + (1/5)^2 + (1/7)^2 + (1/9)^2) * 100 ~= 43.5%
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

    const result = try spectrumOf(&samples, 9, allocator);

    try testing.expectApproxEqAbs(amp, result.fundamental, 1e-8);
    try testing.expectApproxEqAbs(45.0, result.harmonics[0].phase_deg, 0.1);
}

test "four: analyze waveform from tran data" {
    const allocator = testing.allocator;

    const n_points: usize = 512;
    var waveform = try tran.Waveform.init(allocator, 1, n_points);
    defer waveform.deinit();

    const f_fund = 1000.0;
    const period = 1.0 / f_fund;
    // Three periods, so the last full one can be extracted.
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
