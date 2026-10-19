//! Numeric types and kernels shared by every layer: vector helpers, complex
//! arithmetic, the frequency grid, solver tolerances and the BBD partition.
//! Cites ngspice acan.c (the `.ac` grid and its stop tolerance), LAPACK
//! dnrm2 (`norm2`'s rescaling).

const std = @import("std");
const assert = std.debug.assert;

/// Thread budget a solver may use; its fields are read together at dispatch.
pub const Execution = struct {
    /// Null runs everything on the calling thread.
    io: ?std.Io = null,
    /// Workers a solver may fan out to through `io`; 1 is serial.
    threads: u8 = 1,
    /// Workers the sparse refactor may use when its cost model admits the
    /// multicore kernel (`direct.Solver`); 1 keeps it serial.
    lu_threads: u8 = 1,
};

// Elementwise helpers are plain loops, exact at any width; LLVM's loop
// vectorizer (on since Zig 0.18) emits their vector code. `dot` and `sum`
// reassociate into `fold_lanes` strict accumulators (a strict ordered float
// sum never vectorizes), so every caller rounds the same way, but not like
// an ordered scalar fold. Strict IEEE throughout: a NaN or inf entry
// propagates exactly as in the ordered loop, with no fast-math gate.

const abs_mask: u64 = 0x7fff_ffff_ffff_ffff;

/// Independent accumulators of `dot` and `sum`, which the vectorizer maps
/// to four AVX2 registers. Strict on purpose: fast-math would need a NaN
/// input scan that costs more than it saves (0.5 vs 0.18 cycles/entry).
const fold_lanes = 16;

/// Reduces `fold_lanes` accumulators by pairwise halving, a fixed order.
fn combine(acc: *[fold_lanes]f64) f64 {
    var w: usize = fold_lanes / 2;
    while (w > 0) : (w /= 2) for (acc[0..w], acc[w..][0..w]) |*p, q| {
        p.* += q;
    };
    return acc[0];
}

/// Up to this length `zeroSimd` and `copySimd` store vectors inline. A
/// `memset` or `memcpy` call costs 70 to 140 Ir at any length, most of a
/// small deck's plane reset (vacask_graetz: 4% of its instructions).
const inline_len = 64;
const vec_len = std.simd.suggestVectorLength(f64) orelse 1;
comptime {
    // The inline loops step by whole vectors and finish with a scalar tail.
    assert(std.math.isPowerOfTwo(vec_len));
    assert(inline_len >= vec_len);
}
/// Read through a volatile so LLVM cannot turn the zeroing loop back into
/// a `memset` call. Never written. It is a `var` on purpose: Zig folds a
/// volatile read of a comptime-known `const` at compile time (the load
/// disappears from the asm, checked 2026-10-17), and a local `var` would
/// add a stack store per call. ponytail: an immutable global as an
/// optimizer barrier; drop it once LLVM stops turning the loop into a
/// `memset` (re-check on 0.18, which turns the loop vectorizer back on).
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
/// Asserts that the prefixes do not otherwise overlap.
pub fn copySimd(dst: []f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    if (dst.ptr == src.ptr) return;
    const d = @intFromPtr(dst.ptr);
    const s = @intFromPtr(src.ptr);
    assert(d + n * @sizeOf(f64) <= s or s + n * @sizeOf(f64) <= d);
    if (n > inline_len) return @memcpy(dst[0..n], src[0..n]);
    var i: usize = 0;
    while (i + vec_len <= n) : (i += vec_len) dst[i..][0..vec_len].* = src[i..][0..vec_len].*;
    while (i < n) : (i += 1) dst[i] = src[i];
}

/// dst[i] += a * src[i] over dst.len. `src` may be `dst` itself; a shifted
/// overlap is unspecified. Asserts that `src` has at least dst.len entries.
pub fn axpy(dst: []f64, a: f64, src: []const f64) void {
    assert(src.len >= dst.len);
    for (dst, src[0..dst.len]) |*d, x| d.* += a * x;
}

/// dst[i] = a * src[i] over dst.len. Aliasing as `axpy`. Asserts that
/// `src` has at least dst.len entries.
pub fn scale(dst: []f64, a: f64, src: []const f64) void {
    assert(src.len >= dst.len);
    for (dst, src[0..dst.len]) |*d, x| d.* = a * x;
}

/// dst[i] = a[i] - b[i] over dst.len. Either input may be `dst` itself; a
/// shifted overlap is unspecified. Asserts that `a` and `b` each have at
/// least dst.len entries.
pub fn sub(dst: []f64, a: []const f64, b: []const f64) void {
    assert(a.len >= dst.len);
    assert(b.len >= dst.len);
    for (dst, a[0..dst.len], b[0..dst.len]) |*d, x, y| d.* = x - y;
}

/// Σ a[i]·b[i] over a.len. Reassociated: fixed per target, but not the
/// rounding of an ordered loop. Strict IEEE, never fast-math: a NaN entry
/// always reaches the result, and `dense_lu`'s forward solve and `bbd`'s
/// Schur update rely on that to fail on a NaN factor. Asserts that `b`
/// has at least a.len entries.
pub fn dot(a: []const f64, b: []const f64) f64 {
    assert(b.len >= a.len);
    var acc: [fold_lanes]f64 = @splat(0);
    var i: usize = 0;
    while (i + fold_lanes <= a.len) : (i += fold_lanes) {
        for (&acc, a[i..][0..fold_lanes], b[i..][0..fold_lanes]) |*s, x, y| s.* += x * y;
    }
    var tail: f64 = 0;
    for (a[i..], b[i..a.len]) |x, y| tail += x * y;
    return combine(&acc) + tail;
}

/// Σ buf[i], reassociated like `dot`.
pub fn sum(buf: []const f64) f64 {
    var acc: [fold_lanes]f64 = @splat(0);
    var i: usize = 0;
    while (i + fold_lanes <= buf.len) : (i += fold_lanes) {
        for (&acc, buf[i..][0..fold_lanes]) |*s, x| s.* += x;
    }
    var tail: f64 = 0;
    for (buf[i..]) |x| tail += x;
    return combine(&acc) + tail;
}

/// max |buf[i]|, 0 for an empty slice, NaN when any entry is NaN: the
/// convergence and growth norm, so a NaN entry must not read as small.
/// Exact, and +inf with -inf gives inf.
pub fn normInf(buf: []const f64) f64 {
    // An i64 max over the |x| bit patterns: for non-negative floats the
    // integer order is the float order, and a NaN's pattern sorts above
    // inf. It vectorizes where a float @max does not, and float @max
    // would drop the NaN.
    var m: i64 = 0;
    for (buf) |v| m = @max(m, @as(i64, @bitCast(@as(u64, @bitCast(v)) & abs_mask)));
    return @bitCast(m);
}

/// Euclidean norm of `buf` that neither overflows nor underflows: the
/// reassociated `dot(buf, buf)` when its sum lands in the normal range,
/// else Σ (x / max|x|)² rescaled by max|x| (LAPACK dnrm2's idea). inf when
/// an entry is inf, NaN when one is NaN and none is inf, 0 when empty.
pub fn norm2(buf: []const f64) f64 {
    const ss = dot(buf, buf);
    // Below this an underflowed square could cost more than one ulp per entry.
    const tiny = std.math.floatMin(f64) / std.math.floatEps(f64);
    if (ss >= tiny and ss < std.math.inf(f64)) return @sqrt(ss);
    // An inf entry wins over a NaN one, as in hypot.
    for (buf) |x| if (@abs(x) == std.math.inf(f64)) return @abs(x);
    if (std.math.isNan(ss)) return ss;
    const amax = normInf(buf);
    if (amax == 0) return 0;
    // ponytail: ordered scalar loop, reached only past the f64 square range.
    var acc: f64 = 0;
    for (buf) |x| {
        const t = x / amax;
        acc += t * t;
    }
    std.debug.assert(acc >= 1);
    return amax * @sqrt(acc);
}

test "norm2: overflow, underflow and non-finite entries" {
    try std.testing.expectEqual(@as(f64, 0), norm2(&.{}));
    try std.testing.expectEqual(@as(f64, 0), norm2(&.{ 0, -0.0 }));
    try std.testing.expectEqual(@as(f64, 5), norm2(&.{ 3, -4 }));
    try std.testing.expectApproxEqRel(@as(f64, 5e300), norm2(&.{ 3e300, -4e300 }), 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 5e-200), norm2(&.{ 3e-200, -4e-200 }), 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 5e-320), norm2(&.{ 3e-320, -4e-320 }), 0.01);
    try std.testing.expectEqual(std.math.inf(f64), norm2(&.{ 1, -std.math.inf(f64), std.math.nan(f64) }));
    try std.testing.expect(std.math.isNan(norm2(&.{ 1, std.math.nan(f64) })));
    try std.testing.expect(std.math.isNan(norm2(&.{ 1e300, std.math.nan(f64) })));
}

/// One diagonal block of a bordered-block-diagonal (BBD) row partition.
pub const BbdBlock = struct {
    /// First row; the block owns rows `[start, start + size)`.
    start: u32,
    /// Rows.
    size: u32,
};
comptime {
    assert(@sizeOf(BbdBlock) == 8);
}

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
comptime {
    // Complex planes are stored as interleaved (re, im) f64 pairs.
    assert(@sizeOf(Complex) == 2 * @sizeOf(f64));
}

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
    /// ngspice `.ac` (acan.c:89-99): a `dec` grid spanning at least a
    /// decade stretches its ratio so the last point lands on `f_stop`
    /// (`.ac dec 3 10 730` is 6 points ending at 730). ngspice's noise and
    /// sp grids keep the plain ratio, so only the `.ac` card sets it.
    land_on_stop: bool = false,

    /// Number of grid points, at least 1 and at most maxInt(u32). A grid it
    /// cannot step (a non-positive, NaN or infinite span) is one point.
    /// A geometric grid steps by a fixed ratio and keeps every point up to
    /// `f_stop` plus ngspice's stop tolerance (acan.c:239): `dec 10 1 9.999`
    /// is 11 points ending at 10.
    pub fn count(self: FreqSweep) u32 {
        if (self.kind == .poi) return @max(self.points, 1);
        // A `.dc` lin axis may descend; only an empty span is one point.
        if (self.kind == .lin) return if (self.f_stop != self.f_start) @max(self.points, 1) else 1;
        if (!(self.f_start > 0) or !(self.f_stop >= self.f_start) or self.points == 0) return 1;
        const ln_step = @log(self.base()) / @as(f64, @floatFromInt(self.points));
        // The ratio keeps ngspice's rounding; a span whose ratio overflows
        // (1e-300 to 1e300) falls back to the log difference.
        const ratio = self.f_stop / self.f_start;
        const ln_span = if (std.math.isFinite(ratio)) @log(ratio) else @log(self.f_stop) - @log(self.f_start);
        // ngspice runs while freq <= f_stop + step * f_stop * reltol, at the
        // default reltol. ponytail: the deck's reltol is not threaded here;
        // it moves only a point within 0.1% of f_stop.
        const steps = self.stretchedSteps() orelse (ln_span + std.math.log1p(@exp(ln_step) * 1e-3)) / ln_step;
        if (!std.math.isFinite(steps) or steps < 0) return 1;
        // The cap keeps an absurd span (`dec 4294967295 1e-300 1e300`)
        // inside u32 instead of trapping.
        const capped = @min(@floor(steps), @as(f64, std.math.maxInt(u32) - 1));
        assert(capped >= 0);
        return @as(u32, @intFromFloat(capped)) + 1;
    }

    /// Frequency of point `k`, in Hz. Asserts that `k < count()`; for `poi`,
    /// that `list` holds point `k` instead.
    pub fn at(self: FreqSweep, k: u32) f64 {
        if (self.kind == .poi) {
            assert(k < self.list.len);
            return self.list[k];
        }
        assert(k < self.count());
        const kf: f64 = @floatFromInt(k);
        if (self.kind == .lin) {
            const n = self.count();
            if (n <= 1) return self.f_start;
            const frac = kf / @as(f64, @floatFromInt(n - 1));
            return self.f_start + frac * (self.f_stop - self.f_start);
        }
        // pow, not a running product: the product drifts off the decade
        // boundaries the oracles are written on.
        if (self.stretchedSteps()) |steps| return self.f_start * std.math.pow(f64, self.f_stop / self.f_start, kf / steps);
        return self.f_start * std.math.pow(f64, self.base(), kf / @as(f64, @floatFromInt(@max(self.points, 1))));
    }

    /// Writes each grid frequency (Hz) into `freqs`, when given, and its
    /// angular frequency (rad/s) into `omegas`. Asserts that each holds at
    /// least `count()` entries.
    pub fn fill(self: FreqSweep, freqs: ?[]f64, omegas: []f64) void {
        const n = self.count();
        assert(omegas.len >= n);
        if (freqs) |fr| assert(fr.len >= n);
        for (0..n) |i| {
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
            assert(self.k <= self.n);
            if (self.k >= self.n) return null;
            defer self.k += 1;
            return self.sweep.at(self.k);
        }
    };

    /// ngspice's stretched step count, floor(log10(stop/start) * points),
    /// when `land_on_stop` applies; null for a plain grid.
    fn stretchedSteps(self: FreqSweep) ?f64 {
        if (!self.land_on_stop or self.kind != .dec or !(self.f_stop / 10.0 >= self.f_start)) return null;
        const steps = @floor(std.math.log10(self.f_stop / self.f_start) * @as(f64, @floatFromInt(self.points)));
        return if (steps >= 1 and std.math.isFinite(steps)) steps else null;
    }

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
    // ngspice 45 `.ac`: the dec ratio stretches to land on f_stop.
    const dec: FreqSweep = .{ .f_start = 10, .f_stop = 730, .points = 3, .kind = .dec, .land_on_stop = true };
    try t.expectEqual(@as(u32, 6), dec.count());
    try t.expectApproxEqRel(@as(f64, 23.58656), dec.at(1), 1e-6);
    try t.expectApproxEqRel(@as(f64, 730), dec.at(5), 1e-12);
    const short: FreqSweep = .{ .f_start = 1, .f_stop = 99.9, .points = 2, .kind = .dec, .land_on_stop = true };
    try t.expectEqual(@as(u32, 4), short.count());
    try t.expectApproxEqRel(@as(f64, 4.640041), short.at(1), 1e-6);
    // Under a decade, and on the noise/sp grids, the ratio stays 10^(1/N);
    // the stop tolerance keeps 10 past 9.999.
    inline for (.{ true, false }) |land| {
        const under: FreqSweep = .{ .f_start = 1, .f_stop = 9.999, .points = 10, .kind = .dec, .land_on_stop = land };
        try t.expectEqual(@as(u32, 11), under.count());
        try t.expectApproxEqRel(@as(f64, 10), under.at(10), 1e-12);
    }
    const plain: FreqSweep = .{ .f_start = 10, .f_stop = 730, .points = 3, .kind = .dec };
    try t.expectEqual(@as(u32, 6), plain.count());
    try t.expectApproxEqRel(@as(f64, 464.15888336128), plain.at(5), 1e-12);
    const oct3: FreqSweep = .{ .f_start = 10, .f_stop = 100, .points = 3, .kind = .oct };
    try t.expectEqual(@as(u32, 10), oct3.count());
    try t.expectApproxEqRel(@as(f64, 80), oct3.at(9), 1e-12);
    const flat: FreqSweep = .{ .f_start = 100, .f_stop = 100, .points = 5, .kind = .lin };
    try t.expectEqual(@as(u32, 1), flat.count());
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

test "vector helpers match a naive scalar oracle at every length and offset" {
    // Small integers make every reassociated sum exact, so the folds must
    // agree with the ordered loop bit for bit. 260 entries is past 3x the
    // widest f64 vector and past many `fold_lanes` blocks.
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x0c0e);
    const r = prng.random();
    var xs: [264]f64 = undefined;
    var ys: [264]f64 = undefined;
    for (&xs, &ys) |*u, *v| {
        u.* = @floatFromInt(r.intRangeAtMost(i8, -8, 8));
        v.* = @floatFromInt(r.intRangeAtMost(i8, -8, 8));
    }
    var want: [260]f64 = undefined;
    var got: [260]f64 = undefined;
    for (0..261) |len| for (0..4) |off| {
        const x = xs[off..][0..len];
        const y = ys[off..][0..len];

        var d: f64 = 0;
        var s: f64 = 0;
        var m: f64 = 0;
        for (x, y) |u, v| {
            d += u * v;
            s += u;
            m = @max(m, @abs(u));
        }
        try t.expectEqual(d, dot(x, y));
        try t.expectEqual(s, sum(x));
        try t.expectEqual(m, normInf(x));

        for (want[0..len], y, x) |*w, v, u| w.* = v + 3 * u;
        @memcpy(got[0..len], y);
        axpy(got[0..len], 3, x);
        try t.expectEqualSlices(f64, want[0..len], got[0..len]);

        for (want[0..len], x) |*w, u| w.* = -2 * u;
        scale(got[0..len], -2, x);
        try t.expectEqualSlices(f64, want[0..len], got[0..len]);

        for (want[0..len], x, y) |*w, u, v| w.* = u - v;
        sub(got[0..len], x, y);
        try t.expectEqualSlices(f64, want[0..len], got[0..len]);
    };
}

test "dot and sum give the ordered loop's IEEE answer on a non-finite entry or result" {
    const t = std.testing;
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    // In the accumulator blocks and in the tail.
    for ([_]usize{ 0, 63, 64, 130, 199 }) |at| {
        var x: [200]f64 = @splat(1);
        x[at] = nan;
        try t.expect(std.math.isNan(dot(&x, &x)));
        try t.expect(std.math.isNan(sum(&x)));
        x[at] = inf;
        try t.expectEqual(inf, dot(&x, &x));
        try t.expectEqual(inf, sum(&x));
        x[at] = -inf;
        try t.expectEqual(-inf, sum(&x));
        try t.expectEqual(inf, normInf(&x));
    }
    // inf - inf: the ordered loop's NaN.
    try t.expect(std.math.isNan(sum(&.{ inf, -inf })));
    // Finite entries whose sum overflows: inf, as the ordered loop gives.
    try t.expectEqual(inf, sum(&.{ 1e308, 1e308 }));
    try t.expectEqual(inf, dot(&.{ 1e200, 1e200 }, &.{ 1e200, 1e200 }));
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

test "normInf equals a naive NaN-propagating max at every length, NaN, inf, -0 and subnormals planted" {
    var prng = std.Random.DefaultPrng.init(0xA85);
    const r = prng.random();
    var buf: [204]f64 = undefined;
    const specials = [_]f64{ std.math.nan(f64), -std.math.nan(f64), -std.math.inf(f64), -0.0, 4.9e-324, -1e308 };
    for (0..201) |n| for (0..3) |off| for (0..specials.len + 1) |k| {
        const s = buf[off..][0..n];
        for (s) |*v| v.* = (r.float(f64) - 0.5) * 1e3;
        if (n > 0 and k < specials.len) s[r.uintLessThan(usize, n)] = specials[k];
        var want: f64 = 0;
        var nan = false;
        for (s) |v| {
            if (std.math.isNan(v)) nan = true else if (@abs(v) > want) want = @abs(v);
        }
        const got = normInf(s);
        if (nan) try std.testing.expect(std.math.isNan(got)) else try std.testing.expectEqual(want, got);
    };
}

test "normInf of signed zeros and infinities, and of nothing" {
    const t = std.testing;
    const inf = std.math.inf(f64);
    try t.expectEqual(@as(f64, 0), normInf(&.{}));
    try t.expectEqual(@as(u64, 0), @as(u64, @bitCast(normInf(&.{ -0.0, -0.0 }))));
    var buf: [2 * vec_len + 3]f64 = @splat(1);
    buf[buf.len - 1] = -inf;
    try t.expectEqual(inf, normInf(&buf));
    try t.expectEqual(@as(f64, 1e-310), normInf(&.{ 5e-324, -1e-310 }));
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

test "Complex arithmetic on exact values, and div inverts mul" {
    const t = std.testing;
    const a: Complex = .{ .re = 3, .im = -4 };
    const b: Complex = .{ .re = 0.5, .im = 2 };
    try t.expectEqual(@as(f64, 5), a.mag());
    try t.expectEqual(@as(f64, 25), a.magSq());
    try t.expectEqual(Complex{ .re = 3.5, .im = -2 }, a.add(b));
    try t.expectEqual(Complex{ .re = 2.5, .im = -6 }, a.sub(b));
    // (3 - 4i)(0.5 + 2i) = 1.5 + 8 + (6 - 2)i.
    try t.expectEqual(Complex{ .re = 9.5, .im = 4 }, a.mul(b));
    try t.expectEqual(Complex{ .re = -6, .im = 8 }, a.scale(-2));
    try t.expectEqual(a, a.mul(b).div(b));
    try t.expectEqual(Complex.zero, a.mul(.zero));
}

test "norm2 agrees with the plain square root of the ordered sum, and scales by |c|" {
    // A power-of-two scale that keeps every entry normal is exact, so the
    // scaled norm is |c| times the norm to rounding, on the fast path and
    // on the rescaled one (squares past the f64 range either way).
    const t = std.testing;
    var prng = std.Random.DefaultPrng.init(0x2022);
    const r = prng.random();
    var x: [37]f64 = undefined;
    var y: [37]f64 = undefined;
    for (0..x.len + 1) |len| {
        for (x[0..len]) |*v| v.* = r.float(f64) * 2 - 1;
        var acc: f64 = 0;
        for (x[0..len]) |v| acc += v * v;
        const base = norm2(x[0..len]);
        try t.expectApproxEqRel(@sqrt(acc), base, 1e-14);
        for ([_]f64{ 0x1p-990, 0x1p-600, 0x1p600, 0x1p1000, -0x1p-3 }) |c| {
            for (x[0..len], y[0..len]) |u, *v| v.* = c * u;
            try t.expectApproxEqRel(@abs(c) * base, norm2(y[0..len]), 1e-13);
        }
    }
}

test "FreqSweep.fill and the iterator write exactly at(k), and a geometric grid ascends" {
    const t = std.testing;
    const grids = [_]FreqSweep{
        .{ .f_start = 1, .f_stop = 1e6, .points = 7 },
        .{ .f_start = 10, .f_stop = 730, .points = 3, .land_on_stop = true },
        .{ .f_start = 3, .f_stop = 1e3, .points = 5, .kind = .oct },
        .{ .f_start = 0, .f_stop = 5, .points = 6, .kind = .lin },
    };
    var hz: [64]f64 = undefined;
    var rad: [64]f64 = undefined;
    for (grids) |g| {
        const n = g.count();
        g.fill(hz[0..n], rad[0..n]);
        var it = g.iter();
        for (0..n) |k| {
            try t.expectEqual(g.at(@intCast(k)), hz[k]);
            try t.expectEqual(2 * std.math.pi * hz[k], rad[k]);
            try t.expectEqual(hz[k], it.next().?);
            if (k > 0) try t.expect(hz[k] > hz[k - 1]);
        }
        try t.expectEqual(null, it.next());
        // Every point stays within the stop tolerance of f_stop.
        try t.expect(hz[n - 1] <= g.f_stop * (1 + 1e-2));
    }
}
