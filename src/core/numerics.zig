//! Numeric types and kernels shared by every layer: vector helpers, complex
//! arithmetic, the frequency grid, solver tolerances and the BBD partition.

const std = @import("std");

/// Thread budget a solver may use; both fields are read together at dispatch.
pub const Execution = struct {
    /// Null runs everything on the calling thread.
    io: ?std.Io = null,
    /// Workers a solver may fan out to through `io`; 1 is serial.
    threads: u8 = 1,
    /// Workers the sparse refactor may use when its cost model admits the
    /// multicore kernel (`direct.Solver`); 1 keeps it serial.
    lu_threads: u8 = 1,
};

// Elementwise helpers are exact at any width. `dot` and `sum` reassociate
// (stdpp `foldAssoc`: fixed lane accumulators, one fixed combine order), so
// every caller rounds the same way, but not like an ordered scalar fold.
// Zig 0.17 ships with LLVM's loop vectorizer off, so a plain `for` stays
// scalar; stdpp pipelines are what emit the vector code.
const z = @import("stdpp");

/// Lanewise float add; stdpp's `ops.add` wraps, which floats reject.
pub const add = z.lanewise(addFn);
fn addFn(a: anytype, b: anytype) @TypeOf(a) {
    return a + b;
}
const mul = z.lanewise(mulFn);
fn mulFn(p: anytype) @TypeOf(p.left) {
    return p.left * p.right;
}
const diff = z.lanewise(diffFn);
fn diffFn(p: anytype) @TypeOf(p.left) {
    return p.left - p.right;
}
const absMax = z.lanewise(absMaxFn);
fn absMaxFn(a: anytype, b: anytype) @TypeOf(a) {
    return @max(a, @abs(b));
}
const Axpy = struct {
    pub const lanewise = true;
    a: f64,
    pub fn call(self: *@This(), p: anytype) @TypeOf(p.left) {
        return p.left + z.splat(@TypeOf(p.left), self.a) * p.right;
    }
};
const Scale = struct {
    pub const lanewise = true;
    a: f64,
    pub fn call(self: *@This(), x: anytype) @TypeOf(x) {
        return z.splat(@TypeOf(x), self.a) * x;
    }
};

/// Up to this length `zeroSimd` and `copySimd` store vectors inline. A
/// `memset` or `memcpy` call costs 70 to 140 Ir at any length, most of a
/// small deck's plane reset (vacask_graetz: 4% of its instructions).
const inline_len = 64;
const vec_len = std.simd.suggestVectorLength(f64) orelse 1;
/// Read through a volatile so LLVM cannot turn the zeroing loop back into
/// a `memset` call.
var opaque_zero: f64 = 0;

/// Zeroes `buf` with ordinary (temporal) stores, so a plane that is read
/// right after stays in cache. Above 64 entries this is a `memset`.
pub fn zeroSimd(buf: []f64) void {
    if (buf.len > inline_len) return @memset(buf, 0);
    const z0: f64 = @as(*const volatile f64, &opaque_zero).*;
    var i: usize = 0;
    while (i + vec_len <= buf.len) : (i += vec_len) buf[i..][0..vec_len].* = @as(@Vector(vec_len, f64), @splat(z0));
    while (i < buf.len) : (i += 1) buf[i] = z0;
}

/// Copies the common prefix of `src` into `dst`; exact aliasing is a no-op.
/// Any other overlap is illegal: above 64 entries this is a `@memcpy`,
/// which asserts the buffers are disjoint.
pub fn copySimd(dst: []f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    if (dst.ptr == src.ptr) return;
    if (n > inline_len) return @memcpy(dst[0..n], src[0..n]);
    var i: usize = 0;
    while (i + vec_len <= n) : (i += vec_len) dst[i..][0..vec_len].* = src[i..][0..vec_len].*;
    while (i < n) : (i += 1) dst[i] = src[i];
}

/// dst[i] += a * src[i] over dst.len. `src` needs at least dst.len
/// entries and may be `dst` itself; a shifted overlap is unspecified,
/// since the vector path loads a block before it stores it.
pub fn axpy(dst: []f64, a: f64, src: []const f64) void {
    var it = z.fromSlice(f64, dst).zip(z.fromSlice(f64, src[0..dst.len])).map(Axpy{ .a = a });
    _ = it.writeInto(dst);
}

/// dst[i] = a * src[i] over dst.len. Aliasing and length as `axpy`.
pub fn scale(dst: []f64, a: f64, src: []const f64) void {
    var it = z.fromSlice(f64, src[0..dst.len]).map(Scale{ .a = a });
    _ = it.writeInto(dst);
}

/// dst[i] = a[i] - b[i] over dst.len. Each input needs dst.len entries
/// and may be `dst` itself; a shifted overlap is unspecified.
pub fn sub(dst: []f64, a: []const f64, b: []const f64) void {
    var it = z.fromSlice(f64, a[0..dst.len]).zip(z.fromSlice(f64, b[0..dst.len])).map(diff);
    _ = it.writeInto(dst);
}

/// Σ a[i]·b[i] over a.len; `b` needs at least a.len entries. Reassociated:
/// fixed per target, but not the rounding of an ordered loop.
pub fn dot(a: []const f64, b: []const f64) f64 {
    var it = z.fromSlice(f64, a).zip(z.fromSlice(f64, b[0..a.len])).map(mul);
    return it.foldAssoc(@as(f64, 0), add);
}

/// Σ buf[i], reassociated like `dot`.
pub fn sum(buf: []const f64) f64 {
    var it = z.fromSlice(f64, buf);
    return it.foldAssoc(@as(f64, 0), add);
}

/// max |buf[i]|, 0 for an empty slice; NaN entries are skipped like @max does.
pub fn normInf(buf: []const f64) f64 {
    // Max is exact, so any lane grouping equals the scalar fold bit for bit.
    var it = z.fromSlice(f64, buf);
    return it.foldAssoc(@as(f64, 0), absMax);
}

test "vector helpers run on stdpp's SIMD path" {
    // lane_count is null when a callback is not lanewise or the backend has
    // no vector form; other self-hosted backends run the scalar fallback.
    const builtin = @import("builtin");
    if (builtin.zig_backend != .stage2_llvm and builtin.zig_backend != .stage2_x86_64) return;
    const s: []const f64 = &.{};
    const pair = z.fromSlice(f64, s).zip(z.fromSlice(f64, s));
    inline for (.{ @TypeOf(pair.map(Axpy{ .a = 0 })), @TypeOf(z.fromSlice(f64, s).map(Scale{ .a = 0 })), @TypeOf(pair.map(diff)), @TypeOf(pair.map(mul)), @TypeOf(z.fromSlice(f64, s)) }) |T|
        comptime std.debug.assert(T.lane_count != null);
}

test "vector helpers match their per-element formulas" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    var x: [3 * 8 * vec_len + 1]f64 = undefined;
    var y: [3 * 8 * vec_len + 1]f64 = undefined;
    for (0..x.len + 1) |len| {
        for (x[0..len], y[0..len]) |*u, *v| {
            u.* = r.float(f64) - 0.5;
            v.* = r.float(f64) - 0.5;
        }
        var got = y;
        axpy(got[0..len], 0.3, x[0..len]);
        for (0..len) |i| try std.testing.expectEqual(y[i] + 0.3 * x[i], got[i]);
        sub(got[0..len], y[0..len], x[0..len]);
        for (0..len) |i| try std.testing.expectEqual(y[i] - x[i], got[i]);
        scale(got[0..len], -2.0, x[0..len]);
        for (0..len) |i| try std.testing.expectEqual(-2.0 * x[i], got[i]);
        var mx: f64 = 0;
        for (x[0..len]) |u| mx = @max(mx, @abs(u));
        try std.testing.expectEqual(mx, normInf(x[0..len]));
        var acc: f64 = 0;
        for (x[0..len], y[0..len]) |u, v| acc += u * v;
        try std.testing.expectApproxEqAbs(acc, dot(x[0..len], y[0..len]), 1e-12);
        acc = 0;
        for (x[0..len]) |u| acc += u;
        try std.testing.expectApproxEqAbs(acc, sum(x[0..len]), 1e-12);
    }
    // NaN lanes are skipped in the vector body and the tail alike.
    var with_nan: [2 * vec_len + 1]f64 = @splat(1);
    with_nan[1] = std.math.nan(f64);
    with_nan[2 * vec_len] = std.math.nan(f64);
    with_nan[vec_len] = -4;
    try std.testing.expectEqual(@as(f64, 4), normInf(&with_nan));
}

/// One diagonal block of a bordered-block-diagonal (BBD) row partition.
pub const BbdBlock = struct {
    /// First row; the block owns rows `[start, start + size)`.
    start: u32,
    /// Rows.
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

    /// |z| through |z|², so it overflows once |re| or |im| passes ~1e154
    /// (`std.math.hypot` does not, at a price).
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

/// SPICE's `.ac`/`.noise`/`.sp` grid spellings, plus HSPICE's POI point list.
pub const SweepKind = enum { dec, oct, lin, poi };

/// The frequency grid every frequency-domain analysis runs on.
pub const FreqSweep = struct {
    /// Hz.
    f_start: f64,
    /// Hz. A geometric grid may stop short of it (see `count`).
    f_stop: f64,
    /// Points per decade (`dec`), per octave (`oct`), or in total (`lin`,
    /// `poi`).
    points: u32 = 10,
    kind: SweepKind = .dec,
    /// The `poi` frequencies in Hz, ascending, `points` of them; `f_start`
    /// and `f_stop` are its ends. Unused by the other kinds.
    list: []const f64 = &.{},

    /// Number of grid points, at least 1 and at most maxInt(u32). A grid it
    /// cannot step (a non-positive, NaN or infinite span) is one point.
    /// A geometric grid steps by a fixed ratio and stops at the last point
    /// under `f_stop`, as ngspice ACan does: `.ac dec 3 10 730` is 6 points
    /// ending at 464.16, not 7 ending at 730.
    pub fn count(self: FreqSweep) u32 {
        if (self.kind == .lin or self.kind == .poi) return @max(self.points, 1);
        if (!(self.f_start > 0) or !(self.f_stop >= self.f_start)) return 1;
        // The ratio keeps ngspice's rounding; a span whose ratio overflows
        // (1e-300 to 1e300) falls back to the log difference.
        const ratio = self.f_stop / self.f_start;
        const ln_span = if (std.math.isFinite(ratio)) @log(ratio) else @log(self.f_stop) - @log(self.f_start);
        const decades = ln_span / @log(self.base());
        const steps = decades * @as(f64, @floatFromInt(self.points));
        if (!std.math.isFinite(steps) or steps < 0) return 1;
        // +1e-9: an exact integral span (oct 2 10 1280 = 14 steps) must not
        // lose its last point to a 1-ulp shortfall. The cap keeps an absurd
        // span (`dec 4294967295 1e-300 1e300`) inside u32 instead of trapping.
        const capped = @min(@floor(steps + 1e-9), @as(f64, std.math.maxInt(u32) - 1));
        return @as(u32, @intFromFloat(capped)) + 1;
    }

    /// Frequency of point `k`, in Hz. `k` is not range-checked.
    pub fn at(self: FreqSweep, k: u32) f64 {
        if (self.kind == .poi) return self.list[k];
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

    /// The grid as an iterator, `count()` points in the order of `at`.
    pub fn iter(self: FreqSweep) Iter {
        return .{ .sweep = self, .n = self.count() };
    }

    /// Yields the grid frequencies in order, in Hz.
    pub const Iter = struct {
        sweep: FreqSweep,
        n: u32,
        k: u32 = 0,

        /// Null once all `n` points are out.
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
    /// Relative part of every convergence test, dimensionless.
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
    /// Row of `Deck.variants` this query runs; null runs the nominal circuit.
    variant: ?u32 = null,
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

test "vector helpers match their stdpp pull-path oracle at every length and offset" {
    // `.byRef()` hides random access, so the same pipeline runs the scalar
    // pull path. Small integers make every reassociated sum exact, so the
    // folds must agree with it bit for bit too. 256 entries is past 3x the
    // widest f64 vector and past stdpp's 64-entry fold cutoff.
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x0c0e);
    const r = prng.random();
    var xs: [260]f64 = undefined;
    var ys: [260]f64 = undefined;
    for (&xs, &ys) |*u, *v| {
        u.* = @floatFromInt(r.intRangeAtMost(i8, -8, 8));
        v.* = @floatFromInt(r.intRangeAtMost(i8, -8, 8));
    }
    var want: [256]f64 = undefined;
    var got: [256]f64 = undefined;
    for (0..257) |len| for (0..4) |off| {
        const x = xs[off..][0..len];
        const y = ys[off..][0..len];

        var pair = z.fromSlice(f64, x).zip(z.fromSlice(f64, y));
        try t.expectEqual(pair.byRef().map(mul).foldAssoc(@as(f64, 0), add), dot(x, y));
        var single = z.fromSlice(f64, x);
        try t.expectEqual(single.byRef().foldAssoc(@as(f64, 0), add), sum(x));
        single = z.fromSlice(f64, x);
        try t.expectEqual(single.byRef().foldAssoc(@as(f64, 0), absMax), normInf(x));

        @memcpy(want[0..len], y);
        @memcpy(got[0..len], y);
        var acc = z.fromSlice(f64, want[0..len]).zip(z.fromSlice(f64, x));
        _ = acc.byRef().map(Axpy{ .a = 3 }).writeInto(want[0..len]);
        axpy(got[0..len], 3, x);
        try t.expectEqualSlices(f64, want[0..len], got[0..len]);

        single = z.fromSlice(f64, x);
        _ = single.byRef().map(Scale{ .a = -2 }).writeInto(want[0..len]);
        scale(got[0..len], -2, x);
        try t.expectEqualSlices(f64, want[0..len], got[0..len]);

        pair = z.fromSlice(f64, x).zip(z.fromSlice(f64, y));
        _ = pair.byRef().map(diff).writeInto(want[0..len]);
        sub(got[0..len], x, y);
        try t.expectEqualSlices(f64, want[0..len], got[0..len]);
    };
}

test "vector helpers accept dst itself as their source" {
    const t = std.testing;
    var buf: [3 * vec_len + 1]f64 = undefined;
    for (&buf, 0..) |*v, i| v.* = @floatFromInt(i);
    axpy(&buf, 2, &buf);
    for (buf, 0..) |v, i| try t.expectEqual(@as(f64, @floatFromInt(3 * i)), v);
    scale(&buf, 0.5, &buf);
    sub(&buf, &buf, &buf);
    for (buf) |v| try t.expectEqual(@as(f64, 0), v);
}

test "normInf of signed zeros and infinities, and of nothing" {
    const t = std.testing;
    const inf = std.math.inf(f64);
    try t.expectEqual(@as(f64, 0), normInf(&.{}));
    try t.expectEqual(@as(u64, 0), @as(u64, @bitCast(normInf(&.{ -0.0, -0.0 }))));
    var buf: [2 * vec_len + 3]f64 = @splat(1);
    buf[buf.len - 1] = -inf;
    try t.expectEqual(inf, normInf(&buf));
    try t.expectEqual(@as(f64, 0), dot(&.{}, &.{}));
    try t.expectEqual(@as(f64, 0), sum(&.{}));
}

test "bulk zeroing and copying at every length up to past the inline cutoff" {
    const t = std.testing;
    var src: [inline_len + 4]f64 = undefined;
    for (&src, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    for (0..inline_len + 3) |len| {
        var buf: [inline_len + 4]f64 = @splat(-1);
        copySimd(buf[1..][0..len], src[0..len]);
        try t.expectEqualSlices(f64, src[0..len], buf[1..][0..len]);
        try t.expectEqual(@as(f64, -1), buf[0]);
        try t.expectEqual(@as(f64, -1), buf[len + 1]);
        zeroSimd(buf[1..][0..len]);
        for (buf[1..][0..len]) |v| try t.expectEqual(@as(u64, 0), @as(u64, @bitCast(v)));
        try t.expectEqual(@as(f64, -1), buf[0]);
        try t.expectEqual(@as(f64, -1), buf[len + 1]);
    }
}

test "FreqSweep is one point on a span it cannot step, and caps an absurd one" {
    const t = std.testing;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    for ([_][2]f64{ .{ 0, 10 }, .{ -1, 10 }, .{ 10, 1 }, .{ nan, 10 }, .{ 10, nan }, .{ 10, inf } }) |span| {
        try t.expectEqual(@as(u32, 1), (FreqSweep{ .f_start = span[0], .f_stop = span[1] }).count());
        try t.expectEqual(@as(u32, 1), (FreqSweep{ .f_start = span[0], .f_stop = span[1], .kind = .oct }).count());
    }
    // No points per decade is one point, not a division by zero.
    try t.expectEqual(@as(u32, 1), (FreqSweep{ .f_start = 1, .f_stop = 1e3, .points = 0 }).count());
    try t.expectEqual(@as(f64, 1), (FreqSweep{ .f_start = 1, .f_stop = 1e3, .points = 0 }).at(0));
    try t.expectEqual(@as(u32, 1), (FreqSweep{ .f_start = 1, .f_stop = 1e3, .points = 0, .kind = .lin }).count());
    const huge: FreqSweep = .{ .f_start = 1e-300, .f_stop = 1e300, .points = std.math.maxInt(u32) };
    try t.expectEqual(@as(u32, std.math.maxInt(u32)), huge.count());
    // A descending linear grid walks down to its stop.
    const down: FreqSweep = .{ .f_start = 100, .f_stop = 0, .points = 5, .kind = .lin };
    try t.expectEqual(@as(f64, 75), down.at(1));
    try t.expectEqual(@as(f64, 0), down.at(4));
}

test "FreqSweep.fill writes the poi list and its angular frequencies" {
    const t = std.testing;
    const list = [_]f64{ 1, 20, 300 };
    const poi: FreqSweep = .{ .f_start = 1, .f_stop = 300, .points = 3, .kind = .poi, .list = &list };
    var hz: [3]f64 = undefined;
    var rad: [3]f64 = undefined;
    poi.fill(&hz, &rad);
    try t.expectEqualSlices(f64, &list, &hz);
    for (list, rad) |f, w| try t.expectEqual(2 * std.math.pi * f, w);
    // Without a frequency buffer only the omegas are written.
    var rad_only: [3]f64 = undefined;
    poi.fill(null, &rad_only);
    try t.expectEqualSlices(f64, &rad, &rad_only);
}
