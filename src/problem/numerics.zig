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
// Frequency sweep
//
// ONE grid for every frequency-domain analysis (ac/noise/sp/stb/disto/
// pac/pxf/pnoise). Each used to carry its own `f_start`/`f_stop`/
// `points_per_decade` triple and call a dec-only helper, so `.ac lin` and
// `.ac oct` had nowhere to land and were rejected at the dispatcher.
// ============================================================================

/// SPICE's three `.ac`/`.noise`/`.sp` spellings. `points` means per decade,
/// per octave, or in total, in that order.
pub const SweepKind = enum { dec, oct, lin };

pub const FreqSweep = struct {
    f_start: f64,
    f_stop: f64,
    /// `.dec`/`.oct`: points per decade/octave. `.lin`: total points.
    points: u32 = 10,
    kind: SweepKind = .dec,

    /// ngspice ACan: the geometric grid steps by a FIXED ratio and stops at
    /// the last point that still fits under `f_stop` — it does not stretch to
    /// land on it. `.ac dec 3 10 730` is 6 points ending at 464.16, not 7
    /// points ending at 730.
    pub fn count(self: FreqSweep) u32 {
        if (self.kind == .lin) return @max(self.points, 1);
        if (!(self.f_start > 0) or !(self.f_stop >= self.f_start)) return 1;
        const decades = @log(self.f_stop / self.f_start) / @log(self.base());
        const steps = decades * @as(f64, @floatFromInt(self.points));
        // +1e-9: an exact integral span (oct 2 10 1280 = exactly 14 steps)
        // must not lose its last point to a 1-ulp shortfall.
        if (!std.math.isFinite(steps) or steps < 0) return 1;
        return @as(u32, @intFromFloat(@floor(steps + 1e-9))) + 1;
    }

    pub fn at(self: FreqSweep, k: u32) f64 {
        const n = self.count();
        if (self.kind == .lin) {
            if (n <= 1) return self.f_start;
            const frac = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
            return self.f_start + frac * (self.f_stop - self.f_start);
        }
        // pow, not a running product: the accumulated multiply drifts off the
        // decade boundaries the oracles are written on.
        return self.f_start * std.math.pow(f64, self.base(), @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(@max(self.points, 1))));
    }

    /// Fill omegas (and optionally freqs) — both `count()` long.
    pub fn fill(self: FreqSweep, freqs: ?[]f64, omegas: []f64) void {
        for (0..self.count()) |i| {
            const f = self.at(@intCast(i));
            if (freqs) |fr| fr[i] = f;
            omegas[i] = 2.0 * std.math.pi * f;
        }
    }

    pub fn iter(self: FreqSweep) Iter {
        return .{ .sweep = self, .n = self.count() };
    }

    pub const Iter = struct {
        sweep: FreqSweep,
        n: u32,
        k: u32 = 0,

        pub fn next(self: *Iter) ?f64 {
            if (self.k >= self.n) return null;
            defer self.k += 1;
            return self.sweep.at(self.k);
        }
    };

    fn base(self: FreqSweep) f64 {
        return if (self.kind == .oct) 2.0 else 10.0;
    }
};

test "FreqSweep matches the ngspice grids the oracles were taken on" {
    const dec: FreqSweep = .{ .f_start = 10, .f_stop = 730, .points = 3, .kind = .dec };
    try std.testing.expectEqual(@as(u32, 6), dec.count());
    try std.testing.expectApproxEqRel(@as(f64, 464.15888336128), dec.at(5), 1e-12);
    const oct: FreqSweep = .{ .f_start = 10, .f_stop = 1280, .points = 2, .kind = .oct };
    try std.testing.expectEqual(@as(u32, 15), oct.count());
    try std.testing.expectApproxEqRel(@as(f64, 1280), oct.at(14), 1e-12);
    const lin: FreqSweep = .{ .f_start = 0, .f_stop = 1000, .points = 9, .kind = .lin };
    try std.testing.expectEqual(@as(u32, 9), lin.count());
    try std.testing.expectEqual(@as(f64, 125), lin.at(1));
    const one: FreqSweep = .{ .f_start = 100, .f_stop = 100, .points = 1, .kind = .lin };
    try std.testing.expectEqual(@as(u32, 1), one.count());
    try std.testing.expectEqual(@as(f64, 100), one.at(0));
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
