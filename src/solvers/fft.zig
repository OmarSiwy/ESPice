//! In-tree FFT — radix-2 Cooley–Tukey + Bluestein chirp-z transform.
//!
//! Cooley–Tukey decimation-in-time for power-of-2 lengths; Bluestein chirp-z
//! transform for arbitrary lengths (circular convolution via zero-padded
//! radix-2 FFT). All paths are in-place on caller-owned SoA buffers.
//!
//! Generic over element type via `Fft(T)` (f32 or f64); the module-level
//! `fft`/`ifft`/`fftReal`/`bluestein` are the f64 instantiation. Twiddle
//! angles are always computed in f64 and narrowed to T at the store — an f32
//! recurrence drifts visibly within one large stage.
//!
//! Convention: X[k] = Σ x[n]·e^{−j2πnk/N} (forward, unnormalized).
//! Matches ngspice/numpy: cos(2πf₀t) sampled N points → X[1] = N/2.

const std = @import("std");
const math = std.math;

// ============================================================================
// Public generic FFT kernel
// ============================================================================

/// Complex FFT kernels monomorphized over element type T (f32 or f64).
/// Vector width and butterflies specialize per T at comptime via std.simd.
pub fn Fft(comptime T: type) type {
    return struct {
        const W = std.simd.suggestVectorLength(T) orelse 1;
        const V = @Vector(W, T);

        /// SIMD zero-fill a contiguous T buffer.
        inline fn simdZero(buf: []T) void {
            const zero: V = @splat(0);
            var i: usize = 0;
            while (i + W <= buf.len) : (i += W) {
                buf[i..][0..W].* = zero;
            }
            for (buf[i..]) |*v| v.* = 0;
        }

        // ----------------------------------------------------------------
        // Public API
        // ----------------------------------------------------------------

        /// Forward DFT, in-place. N must be a power of two.
        /// X[k] = Σ_{n=0}^{N−1} x[n]·e^{−j2πnk/N} (unnormalized).
        pub fn fft(re: []T, im: []T) void {
            const n = re.len;
            std.debug.assert(n == im.len);
            std.debug.assert(n > 0 and n & (n - 1) == 0);
            bitReverse(re, im);
            butterflyPass(re, im, false);
        }

        /// Inverse DFT, in-place. N must be a power of two.
        /// x[n] = (1/N) Σ_{k=0}^{N−1} X[k]·e^{+j2πnk/N}.
        pub fn ifft(re: []T, im: []T) void {
            const n = re.len;
            std.debug.assert(n == im.len);
            std.debug.assert(n > 0 and n & (n - 1) == 0);
            bitReverse(re, im);
            butterflyPass(re, im, true);
            const inv: T = @floatCast(1.0 / @as(f64, @floatFromInt(n)));
            for (re) |*v| v.* *= inv;
            for (im) |*v| v.* *= inv;
        }

        /// Real-input forward FFT. Packs even/odd into half-length complex FFT,
        /// then unpacks conjugate pairs. `signal` has length N (power of two, N >= 2).
        /// Writes N/2+1 complex bins into `out_re`, `out_im`.
        pub fn fftReal(signal: []const T, out_re: []T, out_im: []T) void {
            const n = signal.len;
            std.debug.assert(n >= 2 and n & (n - 1) == 0);
            const half = n / 2;
            std.debug.assert(out_re.len == half + 1 and out_im.len == half + 1);

            // Pack: z[k] = x[2k] + j·x[2k+1]
            for (0..half) |k| {
                out_re[k] = signal[2 * k];
                out_im[k] = signal[2 * k + 1];
            }
            @This().fft(out_re[0..half], out_im[0..half]);

            // Unpack DC and Nyquist
            const z0r = out_re[0];
            const z0i = out_im[0];
            out_re[0] = z0r + z0i;
            out_im[0] = 0;
            out_re[half] = z0r - z0i;
            out_im[half] = 0;

            // Unpack conjugate pairs (k, half−k) simultaneously — in-place safe.
            var k: usize = 1;
            while (k < half - k) : (k += 1) {
                const kn = half - k;
                const zkr = out_re[k];
                const zki = out_im[k];
                const znr = out_re[kn];
                const zni = out_im[kn];

                inline for (.{ .{ k, zkr, zki, znr, zni }, .{ kn, znr, zni, zkr, zki } }) |pair| {
                    const idx = pair[0];
                    const zr = pair[1];
                    const zi = pair[2];
                    const zcr = pair[3];
                    const zci = -pair[4];

                    const ar = (zr + zcr) * 0.5;
                    const ai = (zi + zci) * 0.5;
                    const br = (zr - zcr) * 0.5;
                    const bi = (zi - zci) * 0.5;

                    const angle = -2.0 * math.pi * @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n));
                    const wr: T = @floatCast(@cos(angle));
                    const wi: T = @floatCast(@sin(angle));

                    const wbr = br * wr - bi * wi;
                    const wbi = br * wi + bi * wr;

                    out_re[idx] = ar + wbi;
                    out_im[idx] = ai - wbr;
                }
            }
            // Midpoint when half is even: k == half−k maps to itself
            if (k == half - k) {
                const zr = out_re[k];
                const zi = out_im[k];

                const angle = -2.0 * math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
                const wr: T = @floatCast(@cos(angle));
                const wi: T = @floatCast(@sin(angle));

                // At midpoint: zcr = zr, zci = −zi, so ar = zr, ai = 0, br = 0, bi = zi
                // wbr = −zi·wi, wbi = zi·wr
                out_re[k] = zr + zi * wr;
                out_im[k] = -(-zi * wi);
            }
        }

        /// Bluestein chirp-z FFT for arbitrary length N. Performs a circular
        /// convolution via power-of-2 FFT internally.
        ///
        /// Scratch buffers must each have length >= bluesteinSize(N).
        /// Result is in `re[0..N]`, `im[0..N]` (in-place).
        pub fn bluestein(
            re: []T,
            im: []T,
            scratch_re: []T,
            scratch_im: []T,
            chirp_re: []T,
            chirp_im: []T,
        ) void {
            const n = re.len;
            std.debug.assert(im.len == n and n > 0);
            const m = bluesteinSize(n);
            std.debug.assert(scratch_re.len >= m and scratch_im.len >= m);
            std.debug.assert(chirp_re.len >= m and chirp_im.len >= m);

            // Bluestein identity: X[k] = b*[k] · Σ_n (x[n]·b*[n]) · b[k−n]
            // where b[m] = e^{jπm²/N}.
            //
            // Step 1: build chirp b[k], compute a[k] = x[k]·b*[k] into scratch,
            // stash b*[k] into (re, im) for final multiply (x is consumed here).
            // Angles use k² mod 2N to keep argument small.
            simdZero(chirp_re[0..m]);
            simdZero(chirp_im[0..m]);
            simdZero(scratch_re[0..m]);
            simdZero(scratch_im[0..m]);

            for (0..n) |k| {
                const kk = (k * k) % (2 * n);
                const angle = math.pi * @as(f64, @floatFromInt(kk)) / @as(f64, @floatFromInt(n));
                const cr: T = @floatCast(@cos(angle));
                const ci: T = @floatCast(@sin(angle));
                chirp_re[k] = cr;
                chirp_im[k] = ci;
                // a[k] = x[k]·conj(b[k])
                scratch_re[k] = re[k] * cr + im[k] * ci;
                scratch_im[k] = im[k] * cr - re[k] * ci;
                // stash b*[k]
                re[k] = cr;
                im[k] = -ci;
            }
            // Negative-index wrap: b[−k] = b[k] since (−k)² = k²
            for (1..n) |k| {
                chirp_re[m - k] = chirp_re[k];
                chirp_im[m - k] = chirp_im[k];
            }

            // Step 2: circular convolution via FFT
            @This().fft(chirp_re[0..m], chirp_im[0..m]);
            @This().fft(scratch_re[0..m], scratch_im[0..m]);
            for (0..m) |k| {
                const ar = scratch_re[k];
                const ai = scratch_im[k];
                const br = chirp_re[k];
                const bi = chirp_im[k];
                scratch_re[k] = ar * br - ai * bi;
                scratch_im[k] = ar * bi + ai * br;
            }
            @This().ifft(scratch_re[0..m], scratch_im[0..m]);

            // Step 3: X[k] = conv[k]·b*[k], b* recalled from (re, im)
            for (0..n) |k| {
                const cr = re[k];
                const ci = im[k];
                re[k] = scratch_re[k] * cr - scratch_im[k] * ci;
                im[k] = scratch_re[k] * ci + scratch_im[k] * cr;
            }
        }

        // ----------------------------------------------------------------
        // Internals
        // ----------------------------------------------------------------

        /// Bit-reversal permutation (in-place, SoA swap on re/im).
        fn bitReverse(re: []T, im: []T) void {
            const n = re.len;
            const log_n: std.math.Log2Int(usize) = @intCast(@ctz(n));
            const shift: std.math.Log2Int(usize) = @intCast(@as(u7, @bitSizeOf(usize)) - @as(u7, log_n));
            for (0..n) |i| {
                const j = @bitReverse(@as(usize, i)) >> shift;
                if (i < j) {
                    std.mem.swap(T, &re[i], &re[j]);
                    std.mem.swap(T, &im[i], &im[j]);
                }
            }
        }

        /// Iterative Cooley–Tukey butterfly passes over all stages.
        /// `inverse` is comptime so each direction is a fully specialized kernel.
        ///
        /// Stages with half >= W run a vectorized kernel: the k-loop within a
        /// group is contiguous, so W butterflies issue as SIMD ops with a
        /// per-lane twiddle vector advanced by one complex multiply per chunk
        /// (rotator cis(W·step)). half is a power of two → no scalar remainder.
        fn butterflyPass(re: []T, im: []T, comptime inverse: bool) void {
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

        /// Scalar butterfly stage — used for small half (< vector width).
        fn butterflyStageScalar(re: []T, im: []T, half: usize, angle_step: f64) void {
            const n = re.len;
            const dwr: T = @floatCast(@cos(angle_step));
            const dwi: T = @floatCast(@sin(angle_step));
            var group: usize = 0;
            while (group < n) : (group += 2 * half) {
                var wr: T = 1.0;
                var wi: T = 0.0;
                for (0..half) |k| {
                    const i = group + k;
                    const j = i + half;
                    const tr = wr * re[j] - wi * im[j];
                    const ti = wr * im[j] + wi * re[j];
                    re[j] = re[i] - tr;
                    im[j] = im[i] - ti;
                    re[i] += tr;
                    im[i] += ti;
                    // twiddle recurrence
                    const new_wr = wr * dwr - wi * dwi;
                    wi = wr * dwi + wi * dwr;
                    wr = new_wr;
                }
            }
        }

        /// SIMD butterfly stage — W-wide vector ops per iteration.
        /// First W twiddles are exact trig (once per stage), then the
        /// recurrence advances W lanes at a time → drift is W× smaller
        /// than a scalar per-element recurrence.
        fn butterflyStageVec(re: []T, im: []T, half: usize, angle_step: f64) void {
            const n = re.len;
            // Exact first-W twiddles per stage
            var twr0: [W]T = undefined;
            var twi0: [W]T = undefined;
            for (0..W) |l| {
                const a = angle_step * @as(f64, @floatFromInt(l));
                twr0[l] = @floatCast(@cos(a));
                twi0[l] = @floatCast(@sin(a));
            }
            // Rotator: cis(W·step) applied per chunk to advance all W lanes
            const step = angle_step * @as(f64, @floatFromInt(W));
            const rot_r: V = @splat(@floatCast(@cos(step)));
            const rot_i: V = @splat(@floatCast(@sin(step)));

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
                    // advance twiddle vector by cis(W·step)
                    const nwr = wr * rot_r - wi * rot_i;
                    wi = wr * rot_i + wi * rot_r;
                    wr = nwr;
                }
            }
        }
    };
}

// ============================================================================
// f64 re-exports — module-level API for existing callers
// ============================================================================

const F64 = Fft(f64);
pub const fft = F64.fft;
pub const ifft = F64.ifft;
pub const fftReal = F64.fftReal;
pub const bluestein = F64.bluestein;

// ============================================================================
// Utility functions
// ============================================================================

/// Required power-of-2 convolution length for Bluestein on input of length N.
pub fn bluesteinSize(n: usize) usize {
    return nextPow2(2 * n - 1);
}

/// Next power of two >= n (n must be > 0).
pub fn nextPow2(n: usize) usize {
    std.debug.assert(n > 0);
    if (n == 1) return 1;
    var v = n - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    if (@sizeOf(usize) > 4) v |= v >> 32;
    return v + 1;
}

// ============================================================================
// Tests — impulse, DC, sinusoid, Parseval, round-trip, Bluestein, fftReal
// ============================================================================

const testing = std.testing;

test "fft: impulse response is flat spectrum" {
    var re = [_]f64{ 1, 0, 0, 0, 0, 0, 0, 0 };
    var im = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
    fft(&re, &im);
    for (re) |v| try testing.expectApproxEqAbs(@as(f64, 1.0), v, 1e-14);
    for (im) |v| try testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-14);
}

test "fft: DC signal has energy only in bin 0" {
    var re = [_]f64{ 3, 3, 3, 3 };
    var im = [_]f64{ 0, 0, 0, 0 };
    fft(&re, &im);
    try testing.expectApproxEqAbs(@as(f64, 12.0), re[0], 1e-13);
    try testing.expectApproxEqAbs(@as(f64, 0.0), im[0], 1e-13);
    for (1..4) |k| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), re[k], 1e-13);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-13);
    }
}

test "fft: pure sinusoid at bin 1 (N=8)" {
    const n = 8;
    var re: [n]f64 = undefined;
    var im = [_]f64{0} ** n;
    for (0..n) |k| {
        re[k] = @cos(2.0 * math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
    }
    fft(&re, &im);
    // cos -> (N/2) at bin 1 and bin N-1, zero elsewhere
    try testing.expectApproxEqAbs(@as(f64, 4.0), re[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), im[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4.0), re[n - 1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), im[n - 1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), re[0], 1e-12);
    for (2..n - 1) |k| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), re[k], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-12);
    }
}

test "fft: pure sine at bin 2 (N=16)" {
    const n = 16;
    var re: [n]f64 = undefined;
    var im = [_]f64{0} ** n;
    for (0..n) |k| {
        re[k] = @sin(2.0 * math.pi * 2.0 * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
    }
    fft(&re, &im);
    // sin -> -j·(N/2) at bin 2, +j·(N/2) at bin N-2
    try testing.expectApproxEqAbs(@as(f64, 0.0), re[2], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, -8.0), im[2], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, 0.0), re[n - 2], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, 8.0), im[n - 2], 1e-11);
}

test "fft: Parseval's theorem (N=64)" {
    const n = 64;
    var re: [n]f64 = undefined;
    var im = [_]f64{0} ** n;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        re[k] = @sin(2.0 * math.pi * 3.0 * t) + 0.5 * @cos(2.0 * math.pi * 7.0 * t);
    }
    var e_time: f64 = 0;
    for (re) |v| e_time += v * v;

    fft(&re, &im);

    var e_freq: f64 = 0;
    for (re, im) |r, i| e_freq += r * r + i * i;
    e_freq /= @as(f64, @floatFromInt(n));

    try testing.expectApproxEqRel(e_time, e_freq, 1e-12);
}

test "fft/ifft: round-trip recovers original signal" {
    const n = 32;
    var re: [n]f64 = undefined;
    var im = [_]f64{0} ** n;
    var orig: [n]f64 = undefined;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        re[k] = @sin(2.0 * math.pi * 5.0 * t) + 0.3 * @cos(2.0 * math.pi * 11.0 * t);
        orig[k] = re[k];
    }
    fft(&re, &im);
    ifft(&re, &im);
    for (0..n) |k| {
        try testing.expectApproxEqAbs(orig[k], re[k], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-12);
    }
}

test "fft: f32 instantiation — round-trip and Parseval" {
    const F32 = Fft(f32);
    const n = 256;
    var re: [n]f32 = undefined;
    var im = [_]f32{0} ** n;
    var orig: [n]f32 = undefined;
    for (0..n) |k| {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
        re[k] = @sin(2.0 * math.pi * 5.0 * t) + 0.3 * @cos(2.0 * math.pi * 11.0 * t);
        orig[k] = re[k];
    }
    var e_time: f64 = 0;
    for (re) |v| e_time += @as(f64, v) * @as(f64, v);

    F32.fft(&re, &im);

    var e_freq: f64 = 0;
    for (re, im) |r, i| e_freq += @as(f64, r) * r + @as(f64, i) * i;
    e_freq /= @as(f64, @floatFromInt(n));
    try testing.expectApproxEqRel(e_time, e_freq, 1e-4);

    F32.ifft(&re, &im);
    for (0..n) |k| {
        try testing.expectApproxEqAbs(orig[k], re[k], 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 0.0), im[k], 1e-4);
    }
}

test "fft: large N=1024 — Parseval and bin accuracy" {
    const n = 1024;
    var re: [n]f64 = undefined;
    var im = [_]f64{0} ** n;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        re[k] = 2.0 * @cos(2.0 * math.pi * 5.0 * t) + @sin(2.0 * math.pi * 100.0 * t) + 0.5 * @cos(2.0 * math.pi * 511.0 * t);
    }
    var e_time: f64 = 0;
    for (re) |v| e_time += v * v;

    fft(&re, &im);

    var e_freq: f64 = 0;
    for (re, im) |r, i| e_freq += r * r + i * i;
    e_freq /= @as(f64, @floatFromInt(n));
    try testing.expectApproxEqRel(e_time, e_freq, 1e-10);

    // bin 5: amplitude 2 cos → |X[5]| = N/2 * 2 = 1024
    const mag5 = @sqrt(re[5] * re[5] + im[5] * im[5]);
    try testing.expectApproxEqRel(@as(f64, 1024.0), mag5, 1e-10);
    // bin 100: amplitude 1 sin → |X[100]| = N/2 = 512
    const mag100 = @sqrt(re[100] * re[100] + im[100] * im[100]);
    try testing.expectApproxEqRel(@as(f64, 512.0), mag100, 1e-10);
}

test "bluestein: matches radix-2 FFT on power-of-2 input" {
    const n = 8;
    var re1 = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var im1 = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var re2 = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var im2 = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };

    fft(&re1, &im1);

    const m = comptime bluesteinSize(n);
    var scratch_re: [m]f64 = undefined;
    var scratch_im: [m]f64 = undefined;
    var chirp_re: [m]f64 = undefined;
    var chirp_im: [m]f64 = undefined;
    bluestein(&re2, &im2, &scratch_re, &scratch_im, &chirp_re, &chirp_im);

    for (0..n) |k| {
        try testing.expectApproxEqAbs(re1[k], re2[k], 1e-10);
        try testing.expectApproxEqAbs(im1[k], im2[k], 1e-10);
    }
}

test "bluestein: non-power-of-2 — impulse is flat" {
    const n = 7;
    var re = [_]f64{ 1, 0, 0, 0, 0, 0, 0 };
    var im = [_]f64{ 0, 0, 0, 0, 0, 0, 0 };

    const m = comptime bluesteinSize(n);
    var scratch_re: [m]f64 = undefined;
    var scratch_im: [m]f64 = undefined;
    var chirp_re: [m]f64 = undefined;
    var chirp_im: [m]f64 = undefined;
    bluestein(&re, &im, &scratch_re, &scratch_im, &chirp_re, &chirp_im);

    for (0..n) |k| {
        try testing.expectApproxEqAbs(@as(f64, 1.0), re[k], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-10);
    }
}

test "bluestein: non-power-of-2 — Parseval (N=13)" {
    const n = 13;
    var re: [n]f64 = undefined;
    var im = [_]f64{0} ** n;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        re[k] = @sin(2.0 * math.pi * 3.0 * t) + 0.7 * @cos(2.0 * math.pi * 5.0 * t);
    }
    var e_time: f64 = 0;
    for (re) |v| e_time += v * v;

    const m = comptime bluesteinSize(n);
    var scratch_re: [m]f64 = undefined;
    var scratch_im: [m]f64 = undefined;
    var chirp_re: [m]f64 = undefined;
    var chirp_im: [m]f64 = undefined;
    bluestein(&re, &im, &scratch_re, &scratch_im, &chirp_re, &chirp_im);

    var e_freq: f64 = 0;
    for (0..n) |k| e_freq += re[k] * re[k] + im[k] * im[k];
    e_freq /= @as(f64, @floatFromInt(n));

    try testing.expectApproxEqRel(e_time, e_freq, 1e-10);
}

test "fftReal: matches full complex FFT on real input" {
    const n = 16;
    var signal: [n]f64 = undefined;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        signal[k] = @cos(2.0 * math.pi * 3.0 * t) + 0.5 * @sin(2.0 * math.pi * 7.0 * t);
    }
    // full complex FFT as reference
    var ref_re: [n]f64 = undefined;
    var ref_im = [_]f64{0} ** n;
    @memcpy(&ref_re, &signal);
    fft(&ref_re, &ref_im);

    // real FFT
    var out_re: [n / 2 + 1]f64 = undefined;
    var out_im: [n / 2 + 1]f64 = undefined;
    fftReal(&signal, &out_re, &out_im);

    for (0..n / 2 + 1) |k| {
        try testing.expectApproxEqAbs(ref_re[k], out_re[k], 1e-12);
        try testing.expectApproxEqAbs(ref_im[k], out_im[k], 1e-12);
    }
}

test "nextPow2: correctness" {
    try testing.expectEqual(@as(usize, 1), nextPow2(1));
    try testing.expectEqual(@as(usize, 2), nextPow2(2));
    try testing.expectEqual(@as(usize, 4), nextPow2(3));
    try testing.expectEqual(@as(usize, 4), nextPow2(4));
    try testing.expectEqual(@as(usize, 8), nextPow2(5));
    try testing.expectEqual(@as(usize, 1024), nextPow2(1000));
    try testing.expectEqual(@as(usize, 1024), nextPow2(1024));
}
