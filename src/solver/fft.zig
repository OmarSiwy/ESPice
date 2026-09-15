//! In-place radix-2 Cooley-Tukey FFT on split real/imaginary f64 arrays.
//! Convention: X[k] = sum x[n] e^(-j 2 pi n k / N), unnormalized forward,
//! as in ngspice and numpy (cos(2 pi t / T) over N points gives X[1] = N/2).

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

/// All butterfly stages. Stages whose half-width reaches W run W butterflies
/// per vector op; half is a power of two, so there is no remainder.
fn butterflyPass(re: []f64, im: []f64) void {
    const n = re.len;
    assert(im.len == n);
    var half: usize = 1;
    while (half < n) : (half *= 2) {
        const angle_step = -math.pi / @as(f64, @floatFromInt(half));
        if (W > 1 and half >= W) {
            butterflyStageVec(re, im, half, angle_step);
        } else {
            butterflyStageScalar(re, im, half, angle_step);
        }
    }
}

fn butterflyStageScalar(re: []f64, im: []f64, half: usize, angle_step: f64) void {
    const n = re.len;
    assert(half < n);
    const dwr = @cos(angle_step);
    const dwi = @sin(angle_step);
    var group: usize = 0;
    while (group < n) : (group += 2 * half) {
        var wr: f64 = undefined;
        var wi: f64 = undefined;
        for (0..half) |k| {
            if (k % reseed == 0) {
                const a = angle_step * @as(f64, @floatFromInt(k));
                wr = @cos(a);
                wi = @sin(a);
            }
            const i = group + k;
            const j = i + half;
            const tr = wr * re[j] - wi * im[j];
            const ti = wr * im[j] + wi * re[j];
            re[j] = re[i] - tr;
            im[j] = im[i] - ti;
            re[i] += tr;
            im[i] += ti;
            const new_wr = wr * dwr - wi * dwi;
            wi = wr * dwi + wi * dwr;
            wr = new_wr;
        }
    }
}

/// `butterflyStageScalar` W butterflies at a time: the lanes advance
/// together by cis(W * step) between the exact reseeds.
fn butterflyStageVec(re: []f64, im: []f64, half: usize, angle_step: f64) void {
    const n = re.len;
    // Whole vectors per group half: half and W are powers of two, half >= W.
    assert(half % W == 0);
    assert(half < n);
    const step = angle_step * @as(f64, @floatFromInt(W));
    const rot_r: V = @splat(@cos(step));
    const rot_i: V = @splat(@sin(step));

    var group: usize = 0;
    while (group < n) : (group += 2 * half) {
        var wr: V = undefined;
        var wi: V = undefined;
        var k: usize = 0;
        while (k < half) : (k += W) {
            if (k % reseed == 0) {
                var twr: [W]f64 = undefined;
                var twi: [W]f64 = undefined;
                for (0..W) |l| {
                    const a = angle_step * @as(f64, @floatFromInt(k + l));
                    twr[l] = @cos(a);
                    twi[l] = @sin(a);
                }
                wr = twr;
                wi = twi;
            }
            const i = group + k;
            const j = i + half;
            const xr: V = re[i..][0..W].*;
            const xi: V = im[i..][0..W].*;
            const yr: V = re[j..][0..W].*;
            const yi: V = im[j..][0..W].*;
            const tr = wr * yr - wi * yi;
            const ti = wr * yi + wi * yr;
            re[i..][0..W].* = xr + tr;
            im[i..][0..W].* = xi + ti;
            re[j..][0..W].* = xr - tr;
            im[j..][0..W].* = xi - ti;
            const nwr = wr * rot_r - wi * rot_i;
            wi = wr * rot_i + wi * rot_r;
            wr = nwr;
        }
    }
}
