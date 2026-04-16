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
            @memset(chirp_re[0..m], 0);
            @memset(chirp_im[0..m], 0);
            @memset(scratch_re[0..m], 0);
            @memset(scratch_im[0..m], 0);

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
