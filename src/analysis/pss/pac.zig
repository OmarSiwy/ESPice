//! Periodic AC (PAC) Analysis
//!
//! Linearises the circuit around a periodic steady-state (PSS) trajectory and
//! computes the linear periodically-time-varying (LPTV) transfer function.
//!
//! Algorithm:
//!   1. Obtain the PSS solution x_pss(t) by brute-force settling — run
//!      (pss_periods − 1) full periods of frozen-time quasi-static Newton
//!      solves at n_time_samples per period.
//!   2. Sample G(t_k) and C(t_k) (conductance and capacitance Jacobians) at
//!      N uniformly-spaced points within one LO period — one ckt.eval per
//!      sample fills both planes, denseG/denseC capture them.
//!   3. Fourier-decompose G and C into harmonic coefficients G_m, C_m via FFT.
//!   4. For each input frequency f_in, build and solve the LPTV conversion
//!      matrix that couples sidebands f_in + m*f_LO for m in [-M..+M].
//!   5. Result: complex transfer (gain + phase) at each sideband frequency.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("solvers").types;
const solvers = @import("solvers");
const fft_mod = solvers.fft;
const dense_lu = solvers.dense_lu;

pub const Complex = types.Complex;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// LO (pump) frequency — the fundamental periodicity.
    f_lo: f64,
    /// Number of LO harmonics to include: sidebands span [-n_harmonics..+n_harmonics].
    n_harmonics: u16 = 3,
    /// Input frequency sweep range.
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
    /// Number of time samples per LO period (must be power of 2, >= 2*(2*n_harmonics+1)).
    n_time_samples: u16 = 64,
    /// PSS shooting parameters.
    pss_periods: u16 = 20,
    pss_newton_tol: f64 = 1e-9,
    pss_max_newton_iter: u16 = 50,
};

/// Run PAC analysis: find periodic steady state, linearise, sweep input frequency.
///
/// `x_init` is the initial DC operating point (length ckt.n).
/// `ac_source_node` is the node where the small-signal AC excitation is applied.
/// `probe_node` is the output node to observe.
///
/// Caller owns the output: freqs[n_freqs] (n_freqs = types.logSweepCount of the
/// sweep), transfer[n_freqs * n_sb] flat, point-major — transfer[fi*n_sb + p]
/// is the sideband at harmonic m = p - n_harmonics (output f = f_in + m*f_LO).
pub fn analyze(
    ckt: *root.Circuit,
    x_init: []const f64,
    ac_source_node: u32,
    ac_magnitude: f64,
    probe_node: u32,
    freqs: []f64,
    transfer: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const n_harm: usize = options.n_harmonics;
    const n_sb: usize = 2 * n_harm + 1;

    const n_freqs = types.logSweepCount(options.f_start, options.f_stop, options.points_per_decade);
    std.debug.assert(freqs.len == n_freqs);
    std.debug.assert(transfer.len == @as(usize, n_freqs) * n_sb);

    const linearization = try linearize(ckt, x_init, options, allocator);
    defer allocator.free(linearization.g_hat);
    defer allocator.free(linearization.c_hat);

    // -- Step 4: Frequency sweep — build and solve conversion matrix ---------
    // The LPTV system couples n_sb sidebands, each of dimension n.
    // For sideband p (harmonic m_p = p - n_harm), the governing equation at
    // frequency omega_p = 2*pi*(f_in + m_p*f_LO) is:
    //
    //   sum_{q} [G_{p-q} + j*omega_p * C_{p-q}] * X_q = B_p
    //
    // where G_{m}, C_{m} are the m-th Fourier coefficients and X_q is the
    // unknown complex amplitude at sideband q.
    //
    // ponytail: GPU batch dispatch — Phase 4. The per-frequency solve here is a
    // dense (2M+1)n × (2M+1)n real system (conversion matrix), not the sparse
    // G+jωC that freq_solve_batch handles. A batched dense LU kernel
    // (gh.dense_solve_batch) would cover this — pack all n_freqs matrices and
    // RHS vectors, dispatch one call. Until that kernel exists, CPU-serial.

    const nn = n_sb * n;
    const nn2 = 2 * nn; // real expansion of the complex system

    const a_work = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_work);
    const rhs_work = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn2);
    defer allocator.free(x_work);

    var sw = types.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var fi: usize = 0;
    while (sw.next()) |f_in| : (fi += 1) {
        root.zeroSimd(a_work);
        root.zeroSimd(rhs_work);

        buildConversionMatrix(false, a_work, linearization.g_hat, linearization.c_hat, n, n_sb, nn, nn2, f_in, options);

        // Excitation: unit AC source at ac_source_node, sideband 0 (m=0, index n_harm).
        const exc_row = n_harm * n + ac_source_node;
        rhs_work[exc_row] = ac_magnitude; // real part

        try dense_lu.factorizeSolve(nn2, a_work, rhs_work, x_work);

        freqs[fi] = f_in;
        for (0..n_sb) |p| {
            const idx = p * n + probe_node;
            transfer[fi * n_sb + p] = .{
                .re = x_work[idx],
                .im = x_work[nn + idx],
            };
        }
    }
}

/// Settled G/C Fourier coefficients shared by PAC and PXF. Caller owns both
/// slices; sample/FFT scratch is released after the coefficients are captured.
pub inline fn linearize(
    ckt: *root.Circuit,
    x_init: []const f64,
    options: Options,
    allocator: std.mem.Allocator,
) !struct { g_hat: []Complex, c_hat: []Complex } {
    const n: usize = ckt.n;
    const n_samples: usize = options.n_time_samples;
    const period = 1.0 / options.f_lo;
    const dt = period / @as(f64, @floatFromInt(n_samples));

    const nr_opts = converger.Options{
        .max_iter = options.pss_max_newton_iter,
        .abstol = options.pss_newton_tol,
    };

    // -- Step 1: PSS via brute-force settling (frozen-time quasi-static) ----
    const x_cur = try allocator.alloc(f64, n);
    defer allocator.free(x_cur);
    // ponytail: reuse the shared copy; slice explicitly to retain the input bound.
    root.copySimd(x_cur, x_init[0..n]);

    try ckt.computeBaseline();
    const ws = try ckt.workspace();

    const g_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(g_mats);
    const c_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(c_mats);

    var t: f64 = 0;
    const settle_steps = (@as(usize, options.pss_periods) - 1) * n_samples;
    for (0..settle_steps) |_| {
        t += dt;
        _ = converger.run(ckt, ws, x_cur, t, nr_opts, root.EvalHook{}) catch {};
    }

    // -- Step 2: capture dense G(t_k), C(t_k) over the final period ---------
    for (0..n_samples) |k| {
        t += dt;
        _ = converger.run(ckt, ws, x_cur, t, nr_opts, root.EvalHook{}) catch {};
        ckt.eval(x_cur, t);
        ckt.denseG(g_mats[k * n * n ..][0 .. n * n]);
        ckt.denseC(c_mats[k * n * n ..][0 .. n * n]);
    }

    // -- Step 3: FFT each matrix element across time samples ----------------
    // G_hat[m][row][col] and C_hat[m][row][col] as complex Fourier coefficients.
    const g_hat = try allocator.alloc(Complex, n_samples * n * n);
    errdefer allocator.free(g_hat);
    const c_hat = try allocator.alloc(Complex, n_samples * n * n);
    errdefer allocator.free(c_hat);

    const fft_re = try allocator.alloc(f64, n_samples);
    defer allocator.free(fft_re);
    const fft_im = try allocator.alloc(f64, n_samples);
    defer allocator.free(fft_im);

    const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));

    for (0..n) |row| {
        for (0..n) |col| {
            const elem_off = row * n + col;

            inline for (.{ .{ g_mats, g_hat }, .{ c_mats, c_hat } }) |plane| {
                for (0..n_samples) |k| {
                    fft_re[k] = plane[0][k * n * n + elem_off];
                    fft_im[k] = 0;
                }
                fft_mod.fft(fft_re, fft_im);
                for (0..n_samples) |m| {
                    plane[1][m * n * n + elem_off] = .{
                        .re = fft_re[m] * inv_n,
                        .im = fft_im[m] * inv_n,
                    };
                }
            }
        }
    }

    return .{ .g_hat = g_hat, .c_hat = c_hat };
}

/// Fill the zeroed real-expanded LPTV matrix, optionally storing its transpose.
/// The transpose is specialized at comptime so PXF needs no extra matrix pass.
pub inline fn buildConversionMatrix(
    comptime transpose: bool,
    a_work: []f64,
    g_hat: []const Complex,
    c_hat: []const Complex,
    n: usize,
    n_sb: usize,
    nn: usize,
    nn2: usize,
    f_in: f64,
    options: Options,
) void {
    const n_samples: usize = options.n_time_samples;
    const n_harm: usize = options.n_harmonics;
    for (0..n_sb) |p| {
        const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
        const omega_p = 2.0 * std.math.pi * (f_in + @as(f64, @floatFromInt(m_p)) * options.f_lo);

        for (0..n_sb) |q| {
            const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
            const m_diff = m_p - m_q;

            const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;

            for (0..n) |row| {
                for (0..n) |col| {
                    const g_coeff = g_hat[fft_idx * n * n + row * n + col];
                    const c_coeff = c_hat[fft_idx * n * n + row * n + col];

                    // (G + j*omega*C) complex coefficient:
                    // real part: G_re - omega*C_im
                    // imag part: G_im + omega*C_re
                    const z_re = g_coeff.re - omega_p * c_coeff.im;
                    const z_im = g_coeff.im + omega_p * c_coeff.re;

                    // Map into the 2*nn x 2*nn real system:
                    //   | Re  -Im |   | X_re |   | B_re |
                    //   | Im   Re | * | X_im | = | B_im |
                    const gr = if (transpose) q * n + col else p * n + row;
                    const gc = if (transpose) p * n + row else q * n + col;

                    a_work[gr * nn2 + gc] += z_re;
                    a_work[gr * nn2 + (nn + gc)] += if (transpose) z_im else -z_im;
                    a_work[(nn + gr) * nn2 + gc] += if (transpose) -z_im else z_im;
                    a_work[(nn + gr) * nn2 + (nn + gc)] += z_re;
                }
            }
        }
    }
}

/// Contract entry: PSS-linearised sweep, excitation on ctx.source_node,
/// output at the last probe. Data layout: point-major complex rows
/// (frequency, tf_h{-M}..tf_h{+M}) with (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    if (ctx.probes.len == 0) return error.NoProbe;
    const probe = ctx.probes[ctx.probes.len - 1];

    const n_freqs: usize = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const n_sb: usize = 2 * @as(usize, opts.n_harmonics) + 1;
    const freqs = try a.alloc(f64, n_freqs);
    defer a.free(freqs);
    const transfer = try a.alloc(Complex, n_freqs * n_sb);
    defer a.free(transfer);

    try analyze(ctx.circuit, x_op, ctx.source_node, 1.0, probe, freqs, transfer, opts, a);

    const names = try a.alloc([]const u8, 1 + n_sb);
    names[0] = "frequency";
    for (0..n_sb) |k| {
        const harmonic = @as(i32, @intCast(k)) - @as(i32, opts.n_harmonics);
        names[1 + k] = try std.fmt.allocPrint(a, "tf_h{d}", .{harmonic});
    }
    const ncols = names.len;
    const data = try a.alloc(f64, n_freqs * ncols * 2);
    for (0..n_freqs) |fi| {
        const row = data[fi * ncols * 2 ..][0 .. ncols * 2];
        row[0] = freqs[fi];
        row[1] = 0;
        for (0..n_sb) |k| {
            const tfv = transfer[fi * n_sb + k];
            row[(1 + k) * 2] = tfv.re;
            row[(1 + k) * 2 + 1] = tfv.im;
        }
    }
    return .{
        .plotname = "Periodic AC Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_freqs,
        .data = data,
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Map a signed harmonic index to an FFT bin. Returns null if out of range.
pub fn mapHarmonicToFftBin(m: i32, n_samples: usize) ?usize {
    const ns: i32 = @intCast(n_samples);
    // FFT bin for harmonic m: m mod N (negative harmonics wrap to N+m).
    if (m >= 0 and m < ns) {
        return @intCast(m);
    } else if (m < 0 and m > -ns) {
        return @intCast(ns + m);
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "PAC: mapHarmonicToFftBin" {
    try testing.expectEqual(@as(?usize, 0), mapHarmonicToFftBin(0, 8));
    try testing.expectEqual(@as(?usize, 1), mapHarmonicToFftBin(1, 8));
    try testing.expectEqual(@as(?usize, 7), mapHarmonicToFftBin(-1, 8));
    try testing.expectEqual(@as(?usize, 5), mapHarmonicToFftBin(-3, 8));
    try testing.expectEqual(@as(?usize, null), mapHarmonicToFftBin(8, 8));
    try testing.expectEqual(@as(?usize, null), mapHarmonicToFftBin(-8, 8));
}

test "PAC: Complex arithmetic" {
    const ca = Complex{ .re = 3.0, .im = 4.0 };
    const b = Complex{ .re = 1.0, .im = -2.0 };

    const sum = Complex.add(ca, b);
    try testing.expectApproxEqAbs(@as(f64, 4.0), sum.re, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), sum.im, 1e-15);

    const prod = Complex.mul(ca, b);
    // (3+4j)(1-2j) = 3 - 6j + 4j - 8j^2 = 11 - 2j
    try testing.expectApproxEqAbs(@as(f64, 11.0), prod.re, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2.0), prod.im, 1e-15);

    try testing.expectApproxEqAbs(@as(f64, 5.0), ca.mag(), 1e-15);
}

test "PAC: solveDense matches known solution" {
    // 2x2 system: [2 1; 1 3] * x = [5; 7] => x = [1.6, 1.8]
    var ma = [_]f64{ 2, 1, 1, 3 };
    const b = [_]f64{ 5, 7 };
    var x: [2]f64 = undefined;
    try dense_lu.factorizeSolve(2, &ma, &b, &x);
    try testing.expectApproxEqAbs(@as(f64, 1.6), x[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.8), x[1], 1e-12);
}

test "PAC: RC mixer with single tone — verify frequency translation" {
    // Simplified test: a time-varying conductance (mixer) modulated at f_LO
    // driving an RC load. The "mixer" is modelled as a resistor whose
    // conductance is modulated: G(t) = G0 * (1 + m * cos(2*pi*f_LO*t)).
    //
    // For a purely resistive circuit (no caps), the LPTV transfer matrix
    // should show frequency translation: an input at f_in appears at
    // f_in +/- f_LO with amplitude proportional to m/2.
    //
    // We build this manually rather than using the full circuit API to test
    // the LPTV conversion-matrix solver in isolation.
    const allocator = testing.allocator;

    const f_lo: f64 = 1e6; // 1 MHz LO
    const n_harm: usize = 2;
    const n_sb: usize = 2 * n_harm + 1; // 5 sidebands
    const n: usize = 1; // single node
    const n_samples: usize = 64;
    const g0: f64 = 1e-3; // 1 kohm base conductance
    const mod_depth: f64 = 0.5; // modulation depth

    // Build G(t_k) = G0 * (1 + m*cos(2*pi*f_LO*t_k)) at n_samples points.
    const t_period = 1.0 / f_lo;
    const dt = t_period / @as(f64, @floatFromInt(n_samples));

    var g_time: [n_samples]f64 = undefined;
    for (0..n_samples) |k| {
        const tk = @as(f64, @floatFromInt(k)) * dt;
        g_time[k] = g0 * (1.0 + mod_depth * @cos(2.0 * std.math.pi * f_lo * tk));
    }

    // FFT of G(t) to get G_hat[m].
    var fft_re: [n_samples]f64 = undefined;
    var fft_im: [n_samples]f64 = undefined;
    root.copySimd(&fft_re, &g_time);
    root.zeroSimd(&fft_im);
    fft_mod.fft(&fft_re, &fft_im);
    const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));

    var g_hat: [n_samples]Complex = undefined;
    for (0..n_samples) |m| {
        g_hat[m] = .{ .re = fft_re[m] * inv_n, .im = fft_im[m] * inv_n };
    }

    // Verify Fourier decomposition: G_0 = g0, G_1 = g0*m/2, G_{-1} = g0*m/2.
    try testing.expectApproxEqAbs(g0, g_hat[0].re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0), g_hat[0].im, 1e-10);
    try testing.expectApproxEqAbs(g0 * mod_depth / 2.0, g_hat[1].re, 1e-10);
    try testing.expectApproxEqAbs(g0 * mod_depth / 2.0, g_hat[n_samples - 1].re, 1e-10);

    // No capacitance: C_hat = 0 for all harmonics.
    // Build and solve the conversion matrix for a single input frequency.
    const nn = n_sb * n;
    const nn2 = 2 * nn;
    const a_work = try allocator.alloc(f64, nn2 * nn2);
    defer allocator.free(a_work);
    const rhs_buf = try allocator.alloc(f64, nn2);
    defer allocator.free(rhs_buf);
    const x_work = try allocator.alloc(f64, nn2);
    defer allocator.free(x_work);

    root.zeroSimd(a_work);
    root.zeroSimd(rhs_buf);

    for (0..n_sb) |p| {
        for (0..n_sb) |q| {
            const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
            const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
            const m_diff = m_p - m_q;

            const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;

            // Pure conductance (no C): Z = G_hat[m_diff].
            const z_re = g_hat[fft_idx].re;
            const z_im = g_hat[fft_idx].im;

            const gr = p * n; // + row, but n=1 so row=0
            const gc = q * n;

            a_work[gr * nn2 + gc] += z_re;
            a_work[gr * nn2 + (nn + gc)] += -z_im;
            a_work[(nn + gr) * nn2 + gc] += z_im;
            a_work[(nn + gr) * nn2 + (nn + gc)] += z_re;
        }
    }

    // Excitation at sideband 0 (m=0), node 0.
    const exc_idx = n_harm * n;
    rhs_buf[exc_idx] = 1.0;

    try dense_lu.factorizeSolve(nn2, a_work, rhs_buf, x_work);

    // For a purely resistive time-varying conductance G(t) = G0*(1 + m*cos),
    // the response at sideband m=0 should be 1/G0 and the conversion to
    // m = +/-1 should be related to the modulation depth.
    const x0_re = x_work[n_harm * n]; // m=0 real part
    const x0_im = x_work[nn + n_harm * n]; // m=0 imaginary part
    const x0_mag = @sqrt(x0_re * x0_re + x0_im * x0_im);

    // The m=0 (direct) response should be close to 1/G0 = 1000 ohms.
    // Due to sideband coupling, it is perturbed slightly but should be
    // in the right ballpark.
    try testing.expect(x0_mag > 0.5 / g0);
    try testing.expect(x0_mag < 2.0 / g0);

    // m=+1 sideband (index n_harm+1): should have nonzero magnitude
    // proportional to modulation depth.
    const xp1_re = x_work[(n_harm + 1) * n];
    const xp1_im = x_work[nn + (n_harm + 1) * n];
    const xp1_mag = @sqrt(xp1_re * xp1_re + xp1_im * xp1_im);
    try testing.expect(xp1_mag > 0);

    // m=-1 sideband (index n_harm-1): should also be nonzero.
    const xm1_re = x_work[(n_harm - 1) * n];
    const xm1_im = x_work[nn + (n_harm - 1) * n];
    const xm1_mag = @sqrt(xm1_re * xm1_re + xm1_im * xm1_im);
    try testing.expect(xm1_mag > 0);

    // Conversion gain ratio: sideband 1 amplitude / sideband 0 amplitude
    // should be approximately m/2 = 0.25 for the dominant coupling.
    const conversion_ratio = xp1_mag / x0_mag;
    try testing.expect(conversion_ratio > 0.1);
    try testing.expect(conversion_ratio < 0.5);

    // Symmetry: m=+1 and m=-1 should have similar magnitudes.
    try testing.expectApproxEqRel(xp1_mag, xm1_mag, 0.1);
}
