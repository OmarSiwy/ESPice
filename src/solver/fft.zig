//! In-place radix-2 Cooley-Tukey FFT on split real/imaginary f64 arrays.
//! Convention: X[k] = sum x[n] e^(-j 2 pi n k / N), unnormalized forward,
//! as in ngspice and numpy (cos(2 pi t / T) over N points gives X[1] = N/2).

const std = @import("std");
const math = std.math;
const scale = @import("core").numerics.scale;

const W = std.simd.suggestVectorLength(f64) orelse 1;
const V = @Vector(W, f64);

/// Forward DFT in place. N must be a power of two.
pub fn fft(re: []f64, im: []f64) void {
    const n = re.len;
    std.debug.assert(n == im.len);
    std.debug.assert(n > 0 and n & (n - 1) == 0);
    bitReverse(re, im);
    butterflyPass(re, im, false);
}

/// Inverse DFT in place, scaled by 1/N. N must be a power of two.
pub fn ifft(re: []f64, im: []f64) void {
    const n = re.len;
    std.debug.assert(n == im.len);
    std.debug.assert(n > 0 and n & (n - 1) == 0);
    bitReverse(re, im);
    butterflyPass(re, im, true);
    const inv = 1.0 / @as(f64, @floatFromInt(n));
    scale(re, inv, re);
    scale(im, inv, im);
}

/// Smallest power of two >= n; n must be > 0.
pub fn nextPow2(n: usize) usize {
    return math.ceilPowerOfTwoAssert(usize, n);
}

fn bitReverse(re: []f64, im: []f64) void {
    const n = re.len;
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
fn butterflyPass(re: []f64, im: []f64, comptime inverse: bool) void {
    const n = re.len;
    const sign: f64 = if (inverse) 1.0 else -1.0;
    var half: usize = 1;
    while (half < n) : (half *= 2) {
        const angle_step = sign * math.pi / @as(f64, @floatFromInt(half));
        if (W > 1 and half >= W) {
            butterflyStageVec(re, im, half, angle_step);
        } else {
            butterflyStageScalar(re, im, half, angle_step);
        }
    }
}

fn butterflyStageScalar(re: []f64, im: []f64, half: usize, angle_step: f64) void {
    const n = re.len;
    const dwr = @cos(angle_step);
    const dwi = @sin(angle_step);
    var group: usize = 0;
    while (group < n) : (group += 2 * half) {
        var wr: f64 = 1.0;
        var wi: f64 = 0.0;
        for (0..half) |k| {
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

/// The first W twiddles are exact per stage; after that the lanes advance
/// together by cis(W * step), so the recurrence drifts W times less than a
/// per-element one.
fn butterflyStageVec(re: []f64, im: []f64, half: usize, angle_step: f64) void {
    const n = re.len;
    var twr0: [W]f64 = undefined;
    var twi0: [W]f64 = undefined;
    for (0..W) |l| {
        const a = angle_step * @as(f64, @floatFromInt(l));
        twr0[l] = @cos(a);
        twi0[l] = @sin(a);
    }
    const step = angle_step * @as(f64, @floatFromInt(W));
    const rot_r: V = @splat(@cos(step));
    const rot_i: V = @splat(@sin(step));

    var group: usize = 0;
    while (group < n) : (group += 2 * half) {
        var wr: V = twr0;
        var wi: V = twi0;
        var k: usize = 0;
        while (k < half) : (k += W) {
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
