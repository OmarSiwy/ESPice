//! In-place radix-2 Cooley-Tukey FFT on split real/imaginary f64 arrays.
//!
//! In: N samples, real and imaginary planes. Out: their N-point DFT in the
//! same planes, O(N log N), no allocation. Convention: X[k] = sum x[n] e^(-j 2 pi n k / N), unnormalized forward,
//! as in ngspice and numpy (cos(2 pi t / T) over N points gives X[1] = N/2).
//! Twiddle reseeding: #41.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const W = std.simd.suggestVectorLength(f64) orelse 1;
const V = @Vector(W, f64);

/// Twiddles come from cos/sin exactly every `reseed` butterflies and by a
/// rotation recurrence in between, whose rounding grows with its length:
/// one recurrence per stage half drifted to 9e3 eps of N on a 2^20-point
/// bin, against 3 eps reseeding every 32 (#41).
const reseed = 32;
comptime {
    assert(reseed % W == 0);
}

/// Forward DFT in place, O(N log N). Asserts that `re` and `im` have the
/// same length N and that N is a power of two (N = 1 is the identity).
pub fn fft(re: []f64, im: []f64) void {
    const n = re.len;
    assert(n == im.len);
    assert(math.isPowerOfTwo(n));
    bitReverse(re, im);
    butterflyPass(re, im);
}

/// Smallest power of two >= n, the length to zero-pad an `fft` input to.
/// Asserts that n > 0 and that the result fits in a usize.
pub fn nextPow2(n: usize) usize {
    return math.ceilPowerOfTwoAssert(usize, n);
}

fn bitReverse(re: []f64, im: []f64) void {
    const n = re.len;
    assert(im.len == n);
    // N = 1 would shift by the full word width.
    if (n < 2) return;
    const log_n: math.Log2Int(usize) = @intCast(@ctz(n));
    const shift: math.Log2Int(usize) = @intCast(@as(u7, @bitSizeOf(usize)) - @as(u7, log_n));
    for (0..n) |i| {
        const j = @bitReverse(@as(usize, i)) >> shift;
        if (i < j) {
            std.mem.swap(f64, &re[i], &re[j]);
            std.mem.swap(f64, &im[i], &im[j]);
        }
    }
}

/// Twiddles per table chunk; a stage with half > chunk walks its k range
/// in chunks, each applied to every group. 8 KiB of stack per stage.
const chunk = 512;
comptime {
    assert(chunk % reseed == 0);
    assert(math.isPowerOfTwo(chunk));
}

/// All butterfly stages. Each stage's twiddles for one chunk of k are made
/// once, by `twiddles`, and every group of the stage reuses them: before,
/// every group re-ran the cos/sin reseeds, n / 2 trig pairs on the half = 1
/// stage alone. The table holds the values the per-group recurrence made, so
/// the output is bitwise what it was (checked against the old stages when
/// the table went in).
fn butterflyPass(re: []f64, im: []f64) void {
    const n = re.len;
    assert(im.len == n);
    var twr: [chunk]f64 = undefined;
    var twi: [chunk]f64 = undefined;
    var half: usize = 1;
    while (half < n) : (half *= 2) {
        const angle_step = -math.pi / @as(f64, @floatFromInt(half));
        var k0: usize = 0;
        while (k0 < half) : (k0 += chunk) {
            const len = @min(chunk, half - k0);
            twiddles(twr[0..len], twi[0..len], k0, half, angle_step);
            var group: usize = 0;
            while (group < n) : (group += 2 * half) {
                const i = group + k0;
                butterflies(re[i..][0..len], im[i..][0..len], re[i + half ..][0..len], im[i + half ..][0..len], twr[0..len], twi[0..len]);
            }
        }
    }
}

/// w_k = cis(k * step) for k in k0..k0 + wr.len, exact cos/sin at every
/// multiple of `reseed` and a rotation recurrence in between: W lanes
/// advancing by cis(W * step) when half >= W, one lane by cis(step) below.
/// Asserts that k0 is a multiple of `reseed` (the chunk starts reseed).
fn twiddles(wr: []f64, wi: []f64, k0: usize, half: usize, step: f64) void {
    assert(wr.len == wi.len);
    assert(k0 % reseed == 0);
    assert(k0 + wr.len <= half);
    if (W > 1 and half >= W) {
        assert(wr.len % W == 0);
        const rot_r: V = @splat(@cos(step * @as(f64, @floatFromInt(W))));
        const rot_i: V = @splat(@sin(step * @as(f64, @floatFromInt(W))));
        var cr: V = undefined;
        var ci: V = undefined;
        var k: usize = 0;
        while (k < wr.len) : (k += W) {
            if (k % reseed == 0) {
                var tr: [W]f64 = undefined;
                var ti: [W]f64 = undefined;
                for (0..W) |l| {
                    const a = step * @as(f64, @floatFromInt(k0 + k + l));
                    tr[l] = @cos(a);
                    ti[l] = @sin(a);
                }
                cr = tr;
                ci = ti;
            }
            wr[k..][0..W].* = cr;
            wi[k..][0..W].* = ci;
            const nr = cr * rot_r - ci * rot_i;
            ci = cr * rot_i + ci * rot_r;
            cr = nr;
        }
    } else {
        const dwr = @cos(step);
        const dwi = @sin(step);
        var cr: f64 = undefined;
        var ci: f64 = undefined;
        for (wr, wi, 0..) |*r, *i, k| {
            if (k % reseed == 0) {
                const a = step * @as(f64, @floatFromInt(k0 + k));
                cr = @cos(a);
                ci = @sin(a);
            }
            r.* = cr;
            i.* = ci;
            const nr = cr * dwr - ci * dwi;
            ci = cr * dwi + ci * dwr;
            cr = nr;
        }
    }
}

/// x' = x + w y, y' = x - w y over one group's chunk: the top half `xr`/`xi`
/// and the bottom half `yr`/`yi`, which do not overlap. A plain loop the
/// vectorizer takes (ymm, same speed as the hand-written `@Vector` form).
fn butterflies(xr: []f64, xi: []f64, yr: []f64, yi: []f64, wr: []const f64, wi: []const f64) void {
    assert(xi.len == xr.len);
    assert(yr.len == xr.len);
    assert(yi.len == xr.len);
    assert(wr.len == xr.len);
    assert(wi.len == xr.len);
    for (xr, xi, yr, yi, wr, wi) |*ar, *ai, *br, *bi, cr, ci| {
        const tr = cr * br.* - ci * bi.*;
        const ti = cr * bi.* + ci * br.*;
        br.* = ar.* - tr;
        bi.* = ai.* - ti;
        ar.* += tr;
        ai.* += ti;
    }
}

const testing = std.testing;

test "fft: N = 1 and N = 2 are the identity and the sum/difference, NaN propagates" {
    var re1 = [_]f64{3.5};
    var im1 = [_]f64{-2};
    fft(&re1, &im1);
    try testing.expectEqual(@as(f64, 3.5), re1[0]);
    try testing.expectEqual(@as(f64, -2), im1[0]);
    var re2 = [_]f64{ 1, 4 };
    var im2 = [_]f64{ 2, -1 };
    fft(&re2, &im2);
    try testing.expectEqualSlices(f64, &.{ 5, -3 }, &re2);
    try testing.expectEqualSlices(f64, &.{ 1, 3 }, &im2);
    // One NaN sample reaches every bin: each output sums every input.
    var re = @as([16]f64, @splat(0));
    var im = @as([16]f64, @splat(0));
    re[5] = std.math.nan(f64);
    fft(&re, &im);
    for (re) |v| try testing.expect(std.math.isNan(v));
}

test "fft: linearity and the shift theorem hold to rounding (metamorphic)" {
    // DFT(a x + y) = a X + Y; a circular shift by s multiplies bin k by
    // cis(-2 pi k s / N).
    const n = 256;
    var prng = std.Random.DefaultPrng.init(0x5417);
    const r = prng.random();
    var xr: [n]f64 = undefined;
    var xi: [n]f64 = undefined;
    var yr: [n]f64 = undefined;
    var yi: [n]f64 = undefined;
    for (&xr, &xi, &yr, &yi) |*a, *b, *c, *d| {
        a.* = r.float(f64) - 0.5;
        b.* = r.float(f64) - 0.5;
        c.* = r.float(f64) - 0.5;
        d.* = r.float(f64) - 0.5;
    }
    const alpha = 2.5;
    var sr: [n]f64 = undefined;
    var si: [n]f64 = undefined;
    for (&sr, &si, xr, xi, yr, yi) |*a, *b, x0, x1, y0, y1| {
        a.* = alpha * x0 + y0;
        b.* = alpha * x1 + y1;
    }
    const shift = 37;
    var hr: [n]f64 = undefined;
    var hi: [n]f64 = undefined;
    for (0..n) |t| {
        hr[(t + shift) % n] = xr[t];
        hi[(t + shift) % n] = xi[t];
    }
    fft(&xr, &xi);
    fft(&yr, &yi);
    fft(&sr, &si);
    fft(&hr, &hi);
    const tol = 1e-12;
    for (0..n) |k| {
        try testing.expectApproxEqAbs(alpha * xr[k] + yr[k], sr[k], tol);
        try testing.expectApproxEqAbs(alpha * xi[k] + yi[k], si[k], tol);
        const a = -2.0 * math.pi * @as(f64, @floatFromInt((k * shift) % n)) / n;
        const c = @cos(a);
        const s = @sin(a);
        try testing.expectApproxEqAbs(c * xr[k] - s * xi[k], hr[k], tol);
        try testing.expectApproxEqAbs(c * xi[k] + s * xr[k], hi[k], tol);
    }
}
