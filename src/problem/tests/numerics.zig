const std = @import("std");
const numerics = @import("numerics");
const zeroSimd = numerics.zeroSimd;
const copySimd = numerics.copySimd;
const Waveform = numerics.Waveform;
const wfMax = numerics.wfMax;
const wfMin = numerics.wfMin;
const wfPp = numerics.wfPp;
const wfAvg = numerics.wfAvg;
const wfRms = numerics.wfRms;
const wfFrequency = numerics.wfFrequency;

test "bulk buffers preserve bits, common prefixes and exact aliases" {
    const src = [_]f64{ -0.0, @bitCast(@as(u64, 0x7ff8000000000042)), 3 };
    var dst = [_]f64{ 7, 7, 7, 7 };
    copySimd(&dst, &src);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&src), std.mem.sliceAsBytes(dst[0..3]));
    try std.testing.expectEqual(@as(f64, 7), dst[3]);
    copySimd(dst[0..2], &src);
    copySimd(&dst, &dst);
    copySimd(dst[0..0], &src);
    zeroSimd(&dst);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0, 0, 0 }, @as([]const u64, @ptrCast(&dst)));
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn generateSine(
    times: []f64,
    values: []f64,
    n_points: usize,
    t_stop: f64,
    freq_hz: f64,
    amplitude: f64,
    dc_offset: f64,
    phase_rad: f64,
) void {
    for (0..n_points) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) * t_stop;
        times[k] = t;
        values[k] = amplitude * @sin(2.0 * std.math.pi * freq_hz * t + phase_rad) + dc_offset;
    }
}

test "meas: max/min/pp on sine wave" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;
    const amplitude = 3.3;
    const freq_hz = 1e6;
    generateSine(&times, &values, n_points, 10.0 / freq_hz, freq_hz, amplitude, 0, 0);
    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqAbs(amplitude, wfMax(wf), 1e-3);
    try testing.expectApproxEqAbs(-amplitude, wfMin(wf), 1e-3);
    try testing.expectApproxEqAbs(2.0 * amplitude, wfPp(wf), 1e-3);
}

test "meas: avg of pure sine is zero" {
    const n_points = 10000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;
    generateSine(&times, &values, n_points, 10.0 / 1e6, 1e6, 1.0, 0, 0);
    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqAbs(@as(f64, 0), wfAvg(wf), 1e-3);
}

test "meas: rms of sine = peak / sqrt(2)" {
    const n_points = 100000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;
    const amplitude = 5.0;
    generateSine(&times, &values, n_points, 100.0 / 1e3, 1e3, amplitude, 0, 0);
    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqAbs(amplitude / @sqrt(2.0), wfRms(wf), 1e-3);
}

test "meas: frequency matches input" {
    const n_points = 100000;
    var times: [n_points]f64 = undefined;
    var values: [n_points]f64 = undefined;
    const freq_hz = 1e6;
    generateSine(&times, &values, n_points, 20.0 / freq_hz, freq_hz, 1.0, 0, 0);
    const wf = Waveform{ .times = &times, .values = &values };
    try testing.expectApproxEqRel(freq_hz, wfFrequency(wf), 1e-3);
}

test "meas: empty waveform returns zero" {
    const wf = Waveform{ .times = &.{}, .values = &.{} };
    try testing.expectApproxEqAbs(@as(f64, 0), wfMax(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), wfMin(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), wfAvg(wf), 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0), wfRms(wf), 1e-15);
}

test "bulk zeroing covers full vectors and the tail without overwriting adjacent storage" {
    var values: [67]f64 = @splat(-1);
    zeroSimd(values[1..66]);
    try testing.expectEqual(@as(f64, -1), values[0]);
    try testing.expectEqual(@as(f64, -1), values[66]);
    for (values[1..66]) |value| try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(value)));
}

test "waveform measurements respect the common prefix and degenerate time spans" {
    const wf: Waveform = .{ .times = &.{ 0, 2 }, .values = &.{ -3, 3, 999 } };
    try testing.expectEqual(@as(f64, 6), wfPp(wf));
    try testing.expectEqual(@as(f64, 0), wfAvg(wf));
    try testing.expectEqual(@as(f64, 3), wfRms(wf));
    const instant: Waveform = .{ .times = &.{ 1, 1 }, .values = &.{ -3, 5 } };
    try testing.expectEqual(@as(f64, -3), wfAvg(instant));
    try testing.expectEqual(@as(f64, 3), wfRms(instant));
    try testing.expectEqual(@as(f64, 0), wfFrequency(instant));
}

test "frequency grids retain both endpoints and support a single frequency" {
    var sweep = numerics.logSweep(10, 1000, 2);
    const expected = [_]f64{ 10, @sqrt(1000.0), 100, @sqrt(100000.0), 1000 };
    try testing.expectEqual(expected.len, sweep.n);
    for (expected) |frequency| try testing.expectApproxEqRel(frequency, sweep.next().?, 1e-12);
    try testing.expect(sweep.next() == null);
    var single = numerics.logSweep(7, 7, 10);
    try testing.expectApproxEqRel(@as(f64, 7), single.next().?, 1e-12);
    try testing.expect(single.next() == null);
}
