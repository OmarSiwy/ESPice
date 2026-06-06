//! Numeric types and kernels shared by every layer: vector helpers, complex
//! arithmetic, the frequency grid, solver tolerances and the BBD partition.

const std = @import("std");

/// Thread budget a solver may use; both fields are read together at dispatch.
pub const Execution = struct {
    /// Null runs everything on the calling thread.
    io: ?std.Io = null,
    threads: u8 = 1,
    /// Workers the sparse refactor may use when its cost model admits the
    /// multicore kernel (`direct.Solver`); 1 keeps it serial.
    lu_threads: u8 = 1,
};

// Elementwise helpers are exact at any width. `dot` fixes one reduction
// order (W-lane accumulator, one @reduce, scalar tail), so every caller
// rounds the same way.
const vw = std.simd.suggestVectorLength(f64) orelse 8;
const Vf = @Vector(vw, f64);

/// Zeroes `buf` with ordinary (temporal) vector stores, so a plane that is
/// read right after stays in cache.
pub fn zeroSimd(buf: []f64) void {
    const zero: Vf = @splat(0.0);
    var i: usize = 0;
    while (i + vw <= buf.len) : (i += vw) buf[i..][0..vw].* = zero;
    for (buf[i..]) |*v| v.* = 0;
}

/// Copies the common prefix of `src` into `dst`; exact aliasing is a no-op.
pub fn copySimd(dst: []f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    if (dst.ptr != src.ptr) @memcpy(dst[0..n], src[0..n]);
}

/// dst[i] += a * src[i] over dst.len; src may alias dst.
pub fn axpy(dst: []f64, a: f64, src: []const f64) void {
    const av: Vf = @splat(a);
    var i: usize = 0;
    while (i + vw <= dst.len) : (i += vw) dst[i..][0..vw].* = @as(Vf, dst[i..][0..vw].*) + av * @as(Vf, src[i..][0..vw].*);
    while (i < dst.len) : (i += 1) dst[i] += a * src[i];
}

/// dst[i] = a * src[i] over dst.len; src may alias dst.
pub fn scale(dst: []f64, a: f64, src: []const f64) void {
    const av: Vf = @splat(a);
    var i: usize = 0;
    while (i + vw <= dst.len) : (i += vw) dst[i..][0..vw].* = av * @as(Vf, src[i..][0..vw].*);
    while (i < dst.len) : (i += 1) dst[i] = a * src[i];
}

/// Σ a[i]·b[i] over a.len.
pub fn dot(a: []const f64, b: []const f64) f64 {
    var acc: Vf = @splat(0);
    var i: usize = 0;
    while (i + vw <= a.len) : (i += vw) acc += @as(Vf, a[i..][0..vw].*) * @as(Vf, b[i..][0..vw].*);
    var sum = @reduce(.Add, acc);
    while (i < a.len) : (i += 1) sum += a[i] * b[i];
    return sum;
}

/// max |buf[i]|, 0 for an empty slice; NaN entries are skipped like @max does.
pub fn normInf(buf: []const f64) f64 {
    // Max is exact, so one lane accumulator reduced once equals the scalar
    // fold bit for bit.
    var acc: Vf = @splat(0);
    var i: usize = 0;
    while (i + vw <= buf.len) : (i += vw) acc = @max(acc, @abs(@as(Vf, buf[i..][0..vw].*)));
    var mx = @reduce(.Max, acc);
    while (i < buf.len) : (i += 1) mx = @max(mx, @abs(buf[i]));
    return mx;
}

test "vector helpers match their per-element formulas" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var x: [3 * vw + 1]f64 = undefined;
    var y: [3 * vw + 1]f64 = undefined;
    for (0..x.len + 1) |len| {
        for (x[0..len], y[0..len]) |*u, *v| {
            u.* = r.float(f64) - 0.5;
            v.* = r.float(f64) - 0.5;
        }
        var got = y;
        axpy(got[0..len], 0.3, x[0..len]);
        for (0..len) |i| try std.testing.expectEqual(y[i] + 0.3 * x[i], got[i]);
        scale(got[0..len], -2.0, x[0..len]);
        for (0..len) |i| try std.testing.expectEqual(-2.0 * x[i], got[i]);
        var mx: f64 = 0;
        for (x[0..len]) |u| mx = @max(mx, @abs(u));
        try std.testing.expectEqual(mx, normInf(x[0..len]));
        var sum: f64 = 0;
        for (x[0..len], y[0..len]) |u, v| sum += u * v;
        try std.testing.expectApproxEqAbs(sum, dot(x[0..len], y[0..len]), 1e-12);
    }
    // NaN lanes are skipped in the vector body and the tail alike.
    var with_nan: [2 * vw + 1]f64 = @splat(1);
    with_nan[1] = std.math.nan(f64);
    with_nan[2 * vw] = std.math.nan(f64);
    with_nan[vw] = -4;
    try std.testing.expectEqual(@as(f64, 4), normInf(&with_nan));
}

/// One diagonal block of a bordered-block-diagonal (BBD) row partition.
pub const BbdBlock = struct {
    /// First row; the block owns rows `[start, start + size)`.
    start: u32,
    size: u32,
};

/// Bordered-block-diagonal partition of the MNA rows: independent diagonal
/// blocks plus the coupling border `[coupling_start, coupling_start + coupling_size)`.
pub const BbdInfo = struct {
    blocks: []BbdBlock,
    coupling_start: u32,
    coupling_size: u32,
};

/// A complex f64 with the operations the AC-family drivers use.
pub const Complex = struct {
    re: f64,
    im: f64,

    pub const zero = Complex{ .re = 0, .im = 0 };

    pub inline fn mag(self: Complex) f64 {
        return @sqrt(self.magSq());
    }

    /// |z|², without the square root.
    pub inline fn magSq(self: Complex) f64 {
        return self.re * self.re + self.im * self.im;
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

    /// a / b by the textbook formula. Unscaled, so |b|² can overflow or
    /// underflow at extreme magnitudes.
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
};

/// SPICE's three `.ac`/`.noise`/`.sp` grid spellings.
pub const SweepKind = enum { dec, oct, lin };

/// The frequency grid every frequency-domain analysis runs on.
pub const FreqSweep = struct {
    /// Hz.
    f_start: f64,
    /// Hz. A geometric grid may stop short of it (see `count`).
    f_stop: f64,
    /// Points per decade (`dec`), per octave (`oct`), or in total (`lin`).
    points: u32 = 10,
    kind: SweepKind = .dec,

    /// Number of grid points, at least 1.
    /// A geometric grid steps by a fixed ratio and stops at the last point
    /// under `f_stop`, as ngspice ACan does: `.ac dec 3 10 730` is 6 points
    /// ending at 464.16, not 7 ending at 730.
    pub fn count(self: FreqSweep) u32 {
        if (self.kind == .lin) return @max(self.points, 1);
        if (!(self.f_start > 0) or !(self.f_stop >= self.f_start)) return 1;
        const decades = @log(self.f_stop / self.f_start) / @log(self.base());
        const steps = decades * @as(f64, @floatFromInt(self.points));
        if (!std.math.isFinite(steps) or steps < 0) return 1;
        // +1e-9: an exact integral span (oct 2 10 1280 = 14 steps) must not
        // lose its last point to a 1-ulp shortfall.
        return @as(u32, @intFromFloat(@floor(steps + 1e-9))) + 1;
    }

    /// Frequency of point `k`, in Hz. `k` is not range-checked.
    pub fn at(self: FreqSweep, k: u32) f64 {
        const n = self.count();
        if (self.kind == .lin) {
            if (n <= 1) return self.f_start;
            const frac = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
            return self.f_start + frac * (self.f_stop - self.f_start);
        }
        // pow, not a running product: the product drifts off the decade
        // boundaries the oracles are written on.
        return self.f_start * std.math.pow(f64, self.base(), @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(@max(self.points, 1))));
    }

    /// Writes each grid frequency (Hz) into `freqs`, when given, and its
    /// angular frequency (rad/s) into `omegas`. Both need `count()` entries.
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

    /// Yields the grid frequencies in order, in Hz.
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

/// Convergence and timestep tolerances, one copy per query. Defaults follow
/// the SPICE `.options` defaults.
pub const Tolerances = struct {
    reltol: f64 = 1e-3,
    /// Amperes.
    abstol: f64 = 1e-12,
    /// Volts.
    vntol: f64 = 1e-6,
    /// Minimum conductance, in siemens.
    gmin: f64 = 1e-12,
    /// Absolute floor of the per-row Newton residual test.
    residual_tol: f64 = 1e-9,
    /// First rung of the DC gmin-stepping ladder, in siemens.
    gmin_start: f64 = 1e-2,
    /// Newton iteration limits named after the SPICE options: DC operating
    /// point, DC sweep point, transient timepoint.
    itl1: u16 = 100,
    itl2: u16 = 50,
    itl4: u16 = 10,
    /// Coulombs; charge floor of the transient truncation-error estimate.
    chgtol: f64 = 1e-14,
    /// Factor by which the truncation-error estimate is assumed to overshoot.
    trtol: f64 = 7.0,
    /// `.options temp` for this query alone, in degC (one entry of an HSPICE
    /// `.temp` list); null runs at the deck temperature.
    temp_c: ?f64 = null,
};

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

test "bulk zeroing covers full vectors and the tail without overwriting adjacent storage" {
    var values: [67]f64 = @splat(-1);
    zeroSimd(values[1..66]);
    try std.testing.expectEqual(@as(f64, -1), values[0]);
    try std.testing.expectEqual(@as(f64, -1), values[66]);
    for (values[1..66]) |value| try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(value)));
}

test "FreqSweep matches the ngspice grids the oracles were taken on" {
    const t = std.testing;
    const dec: FreqSweep = .{ .f_start = 10, .f_stop = 730, .points = 3, .kind = .dec };
    try t.expectEqual(@as(u32, 6), dec.count());
    try t.expectApproxEqRel(@as(f64, 464.15888336128), dec.at(5), 1e-12);
    const oct: FreqSweep = .{ .f_start = 10, .f_stop = 1280, .points = 2, .kind = .oct };
    try t.expectEqual(@as(u32, 15), oct.count());
    try t.expectApproxEqRel(@as(f64, 1280), oct.at(14), 1e-12);
    const lin: FreqSweep = .{ .f_start = 0, .f_stop = 1000, .points = 9, .kind = .lin };
    try t.expectEqual(@as(u32, 9), lin.count());
    try t.expectEqual(@as(f64, 125), lin.at(1));
    const one: FreqSweep = .{ .f_start = 100, .f_stop = 100, .points = 1, .kind = .lin };
    try t.expectEqual(@as(u32, 1), one.count());
    try t.expectEqual(@as(f64, 100), one.at(0));

    // The iterator walks the same grid and keeps both endpoints.
    const grid: FreqSweep = .{ .f_start = 10, .f_stop = 1000, .points = 2 };
    var sweep = grid.iter();
    const expected = [_]f64{ 10, @sqrt(1000.0), 100, @sqrt(100000.0), 1000 };
    try t.expectEqual(expected.len, sweep.n);
    for (expected) |frequency| try t.expectApproxEqRel(frequency, sweep.next().?, 1e-12);
    try t.expect(sweep.next() == null);
    const point: FreqSweep = .{ .f_start = 7, .f_stop = 7, .points = 10 };
    var single = point.iter();
    try t.expectApproxEqRel(@as(f64, 7), single.next().?, 1e-12);
    try t.expect(single.next() == null);
}
