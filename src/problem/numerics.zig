//! Solver-independent numerical settings, structural metadata and result helpers.
//! Shared by problem construction and analysis; imports no solver implementation.

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
        // ponytail: reuse magSq without changing the squared-magnitude arithmetic.
        return @sqrt(self.magSq());
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

pub const Tolerances = struct {
    reltol: f64 = 1e-3,
    abstol: f64 = 1e-12,
    vntol: f64 = 1e-6,
    gmin: f64 = 1e-12,
    residual_tol: f64 = 1e-9,
    dx_clamp: f64 = std.math.inf(f64),

    gmin_start: f64 = 1e-2,
    source_steps: u8 = 7,

    itl1: u16 = 100,
    itl2: u16 = 50,
    itl4: u16 = 10,

    chgtol: f64 = 1e-14,
    trtol: f64 = 7.0,

    pub const ngspice: Tolerances = .{};
    pub const hspice: Tolerances = .{ .itl1 = 150 };
    pub const ltspice: Tolerances = .{ .trtol = 1.0, .source_steps = 25 };
    pub const tight: Tolerances = .{
        .reltol = 1e-6,
        .vntol = 1e-9,
        .abstol = 1e-15,
        .gmin = 1e-15,
        .trtol = 1.0,
    };
};
