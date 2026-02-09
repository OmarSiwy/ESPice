//! Shared types for frequency-domain and waveform analysis.
//! Pure data — no solver or circuit dependencies.

const std = @import("std");

/// Caller-owned scheduler; both fields are read together at a solver dispatch.
pub const Execution = struct {
    io: ?std.Io = null,
    threads: u8 = 1,
};

/// Temporal vector stores keep immediately consumed numeric planes hot.
pub fn zeroSimd(buf: []f64) void {
    const W = std.simd.suggestVectorLength(f64) orelse 8;
    const V = @Vector(W, f64);
    const zero: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= buf.len) : (i += W) buf[i..][0..W].* = zero;
    for (buf[i..]) |*v| v.* = 0;
}

/// Copy the common prefix; exact aliasing is a no-op.
pub fn copySimd(dst: []f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    if (dst.ptr != src.ptr) @memcpy(dst[0..n], src[0..n]);
}

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
// BBD partitioning (moved from root.zig so solver leaves import a leaf,
// not the module root — keeps the intra-module import graph acyclic)
// ============================================================================

pub const BbdBlock = struct {
    start: u32,
    size: u32,
    type_id: u16,
    instance_id: u32,
};

pub const BbdInfo = struct {
    blocks: []BbdBlock,
    coupling_start: u32,
    coupling_size: u32,
};

// ============================================================================
// Complex number
// ============================================================================

pub const Complex = struct {
    re: f64,
    im: f64,

    pub const zero = Complex{ .re = 0, .im = 0 };

    pub inline fn mag(self: Complex) f64 {
        return @sqrt(self.re * self.re + self.im * self.im);
    }

    pub inline fn magSq(self: Complex) f64 {
        return self.re * self.re + self.im * self.im;
    }

    pub inline fn phase(self: Complex) f64 {
        return std.math.atan2(self.im, self.re);
    }

    pub inline fn phaseDeg(self: Complex) f64 {
        return self.phase() * (180.0 / std.math.pi);
    }

    pub inline fn magDb(self: Complex) f64 {
        const m = self.mag();
        return if (m < 1e-30) -300.0 else 20.0 * @log10(m);
    }

    pub inline fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub inline fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub inline fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub inline fn div(a: Complex, b: Complex) Complex {
        const d = b.re * b.re + b.im * b.im;
        return .{
            .re = (a.re * b.re + a.im * b.im) / d,
            .im = (a.im * b.re - a.re * b.im) / d,
        };
    }

    pub inline fn scale(self: Complex, s: f64) Complex {
        return .{ .re = self.re * s, .im = self.im * s };
    }

    pub inline fn neg(self: Complex) Complex {
        return .{ .re = -self.re, .im = -self.im };
    }

    pub inline fn conj(self: Complex) Complex {
        return .{ .re = self.re, .im = -self.im };
    }
};

// ============================================================================
// Log-frequency sweep
// ============================================================================

pub fn logSweepCount(f_start: f64, f_stop: f64, points_per_decade: u16) u32 {
    const decades = @log10(f_stop) - @log10(f_start);
    return @as(u32, @intFromFloat(@ceil(decades * @as(f64, @floatFromInt(points_per_decade))))) + 1;
}

pub fn logSweepFreq(f_start: f64, f_stop: f64, n_points: u32, k: u32) f64 {
    const log_start = @log10(f_start);
    const frac = if (n_points > 1) @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points - 1)) else 0;
    return std.math.pow(f64, 10.0, log_start + frac * (@log10(f_stop) - log_start));
}

pub const LogSweep = struct {
    f_start: f64,
    f_stop: f64,
    n: u32,
    k: u32 = 0,

    pub fn next(self: *LogSweep) ?f64 {
        if (self.k >= self.n) return null;
        const f = logSweepFreq(self.f_start, self.f_stop, self.n, self.k);
        self.k += 1;
        return f;
    }
};

pub fn logSweep(f_start: f64, f_stop: f64, points_per_decade: u16) LogSweep {
    return .{ .f_start = f_start, .f_stop = f_stop, .n = logSweepCount(f_start, f_stop, points_per_decade) };
}

/// Fill omegas (and optionally freqs) for a log sweep — both logSweepCount long.
pub fn fillLogSweep(f_start: f64, f_stop: f64, points_per_decade: u16, freqs: ?[]f64, omegas: []f64) void {
    var sw = logSweep(f_start, f_stop, points_per_decade);
    var i: usize = 0;
    while (sw.next()) |f| : (i += 1) {
        if (freqs) |fr| fr[i] = f;
        omegas[i] = 2.0 * std.math.pi * f;
    }
}

// ============================================================================
// Waveform measurement
// ============================================================================

pub const Waveform = struct {
    times: []const f64,
    values: []const f64,

    pub fn len(self: Waveform) usize {
        return @min(self.times.len, self.values.len);
    }
};

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

pub const ThresholdOpts = struct {
    lo: f64 = 0.1,
    hi: f64 = 0.9,
};

pub fn wfMax(wf: Waveform) f64 {
    const n = wf.len();
    if (n == 0) return 0;
    var result: f64 = wf.values[0];
    for (wf.values[1..n]) |v| result = @max(result, v);
    return result;
}

pub fn wfMin(wf: Waveform) f64 {
    const n = wf.len();
    if (n == 0) return 0;
    var result: f64 = wf.values[0];
    for (wf.values[1..n]) |v| result = @min(result, v);
    return result;
}

pub fn wfPp(wf: Waveform) f64 {
    return wfMax(wf) - wfMin(wf);
}

pub fn wfAvg(wf: Waveform) f64 {
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

pub fn wfRms(wf: Waveform) f64 {
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

pub fn riseTime(wf: Waveform, opts: ThresholdOpts) f64 {
    const n = wf.len();
    if (n < 2) return 0;
    const v_min = wfMin(wf);
    const v_max = wfMax(wf);
    const swing = v_max - v_min;
    if (swing == 0) return 0;
    const lo_thresh = v_min + opts.lo * swing;
    const hi_thresh = v_min + opts.hi * swing;
    const t_lo = findCrossing(wf, lo_thresh, .rising) orelse return 0;
    const t_hi = findCrossingAfter(wf, hi_thresh, .rising, t_lo) orelse return 0;
    return t_hi - t_lo;
}

pub fn fallTime(wf: Waveform, opts: ThresholdOpts) f64 {
    const n = wf.len();
    if (n < 2) return 0;
    const v_min = wfMin(wf);
    const v_max = wfMax(wf);
    const swing = v_max - v_min;
    if (swing == 0) return 0;
    const hi_thresh = v_min + opts.hi * swing;
    const lo_thresh = v_min + opts.lo * swing;
    const t_hi = findCrossing(wf, hi_thresh, .falling) orelse return 0;
    const t_lo = findCrossingAfter(wf, lo_thresh, .falling, t_hi) orelse return 0;
    return t_lo - t_hi;
}

pub fn wfDelay(wf1: Waveform, wf2: Waveform, threshold: f64) f64 {
    const t1 = findCrossing(wf1, threshold, .rising) orelse return 0;
    const t2 = findCrossing(wf2, threshold, .rising) orelse return 0;
    return @abs(t2 - t1);
}

pub fn wfFrequency(wf: Waveform) f64 {
    const n = wf.len();
    if (n < 3) return 0;
    const dc_offset = wfAvg(wf);
    var first_crossing: ?f64 = null;
    var last_crossing: ?f64 = null;
    var crossing_count: u32 = 0;
    for (1..n) |k| {
        if (wf.values[k - 1] < dc_offset and wf.values[k] >= dc_offset) {
            const frac = (dc_offset - wf.values[k - 1]) / (wf.values[k] - wf.values[k - 1]);
            const t_cross = wf.times[k - 1] + frac * (wf.times[k] - wf.times[k - 1]);
            if (first_crossing == null) first_crossing = t_cross;
            last_crossing = t_cross;
            crossing_count += 1;
        }
    }
    if (crossing_count < 2) return 0;
    const total_time = last_crossing.? - first_crossing.?;
    if (total_time <= 0) return 0;
    return @as(f64, @floatFromInt(crossing_count - 1)) / total_time;
}

pub fn measure(wf: Waveform, mtype: MeasType, opts: ThresholdOpts) f64 {
    return switch (mtype) {
        .max => wfMax(wf),
        .min => wfMin(wf),
        .pp => wfPp(wf),
        .avg => wfAvg(wf),
        .rms => wfRms(wf),
        .rise_time => riseTime(wf, opts),
        .fall_time => fallTime(wf, opts),
        .frequency => wfFrequency(wf),
    };
}

// ============================================================================
// Internal
// ============================================================================

const CrossingDir = enum { rising, falling };

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
