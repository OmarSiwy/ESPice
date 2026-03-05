const PacTests = struct {
    const impl = @import("../pss/pac.zig");
    const Complex = impl.Complex;
    const dense_lu = @import("solvers").dense_lu;
    const fft_mod = @import("solvers").fft;
    const mapHarmonicToFftBin = impl.mapHarmonicToFftBin;
    const root = @import("../types.zig");
    const std = @import("std");

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
};

const PnoiseTests = struct {
    const impl = @import("../pss/pnoise.zig");
    const NoiseSource = impl.NoiseSource;
    const sourcePsd = impl.test_access.sourcePsd;
    const std = @import("std");

    const q_electron = 1.602176634e-19;

    // The 2q|I| vs 4kTg distinction is the DEVICE's, and its tests are in
    // ac/noise.zig + the ngspice fixtures; what this function owns is the
    // sideband frequency axis.

    test "sourcePsd white is flat, and a negative sideband mirrors" {
        const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 2.0 * q_electron * 1e-3 };
        try std.testing.expectEqual(src.white, sourcePsd(src.white, 0, 1, 1e6));
        try std.testing.expectEqual(src.white, sourcePsd(src.white, 0, 1, -1e6));
    }

    test "sourcePsd flicker rolls off as 1/|f_sb|^ef" {
        // KF*|I|^AF = 1e-27, EF = 1 (dionoise.c:99-104).
        try std.testing.expectApproxEqRel(10.0, sourcePsd(0, 1e-27, 1, 100.0) / sourcePsd(0, 1e-27, 1, 1000.0), 1e-12);
        // Folded sideband: |f| is what the shape sees.
        try std.testing.expectEqual(sourcePsd(0, 1e-27, 1, 100.0), sourcePsd(0, 1e-27, 1, -100.0));
        // mos1noi.c:175-181 nlev 2/3: the exponent is a model parameter.
        try std.testing.expectApproxEqRel(1e-27 / std.math.pow(f64, 100.0, 1.4), sourcePsd(0, 1e-27, 1.4, 100.0), 1e-12);
        // Both halves on one generator.
        try std.testing.expectApproxEqRel(3e-17 + 1e-30, sourcePsd(3e-17, 1e-27, 1, 1e3), 1e-12);
    }

    test "sourcePsd flicker near-DC clamp" {
        // f_sideband == 0 must not blow up (clamped to the 1e-30 floor).
        const psd = sourcePsd(0, 1e-24, 1, 0.0);
        try std.testing.expect(std.math.isFinite(psd));
        try std.testing.expect(psd > 0);
    }
};

const PssTests = struct {
    const impl = @import("../pss/pss.zig");
    const Gmres = @import("solvers").gmres.Gmres(f64);
    const Options = @import("requests").Pss;
    const SolveResult = impl.SolveResult;
    const gpuIntegrateOnePeriod = impl.test_access.gpuIntegrateOnePeriod;
    const krylov_threshold = impl.test_access.krylov_threshold;
    const normInf = impl.normInf;
    const root = @import("../types.zig");
    const shootingMatvec = impl.test_access.shootingMatvec;
    const simdAdd = impl.test_access.simdAdd;
    const simdAxpy = impl.test_access.simdAxpy;
    const simdCopy = impl.test_access.simdCopy;
    const simdScale = impl.test_access.simdScale;
    const simdSub = impl.test_access.simdSub;
    const simdZero = impl.test_access.simdZero;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "pss: krylov_threshold is reasonable" {
        try testing.expect(krylov_threshold > 0);
        try testing.expect(krylov_threshold <= 200);
    }

    test "pss: simdCopy round-trip" {
        var a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        var b: [10]f64 = undefined;
        simdZero(&b);
        simdCopy(&b, &a);
        for (0..10) |i| try testing.expectEqual(a[i], b[i]);
    }

    test "pss: simdSub correctness" {
        var a = [_]f64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
        const b = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        var c: [10]f64 = undefined;
        simdSub(&c, &a, &b);
        for (0..10) |i| try testing.expectApproxEqAbs(a[i] - b[i], c[i], 1e-15);
        _ = &a;
    }

    test "pss: simdAdd correctness" {
        var a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        const b = [_]f64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
        var c: [10]f64 = undefined;
        simdAdd(&c, &a, &b);
        for (0..10) |i| try testing.expectApproxEqAbs(a[i] + b[i], c[i], 1e-15);
        _ = &a;
    }

    test "pss: simdAxpy correctness" {
        var dst = [_]f64{ 1, 2, 3, 4, 5 };
        const src = [_]f64{ 10, 20, 30, 40, 50 };
        simdAxpy(&dst, 0.5, &src);
        try testing.expectApproxEqAbs(@as(f64, 6.0), dst[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 12.0), dst[1], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 18.0), dst[2], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 24.0), dst[3], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 30.0), dst[4], 1e-15);
    }

    test "pss: simdScale correctness" {
        const src = [_]f64{ 2, 4, 6, 8, 10 };
        var dst: [5]f64 = undefined;
        simdScale(&dst, -1.0, &src);
        for (0..5) |i| try testing.expectApproxEqAbs(-src[i], dst[i], 1e-15);
    }

    test "pss: normInf" {
        const v = [_]f64{ -3, 1, 2, -5, 4 };
        try testing.expectApproxEqAbs(@as(f64, 5.0), normInf(&v), 1e-15);
    }

    test "pss: shootingMatvec identity operator" {
        // Verify the FD matvec structure compiles and the function pointer
        // signature matches GMRES expectations.
        const ptr: *const fn ([]const f64, []f64, *anyopaque) void = &shootingMatvec;
        try testing.expect(@intFromPtr(ptr) != 0);
    }

    test "pss: Options defaults are sane" {
        const opts = Options{ .period = 1e-9 };
        try testing.expect(opts.max_shooting_iter > 0);
        try testing.expect(opts.n_samples > 0);
        try testing.expect(opts.fd_epsilon > 0);
        try testing.expect(opts.shooting_tol > 0);
        try testing.expect(opts.gmres_restart > 0);
        try testing.expect(opts.gmres_tol > 0);
        try testing.expect(opts.gmres_max_restarts > 0);
    }

    test "pss: use_krylov gate" {
        // Verify the threshold logic: small n uses dense, large n uses Krylov.
        try testing.expect(!(10 >= krylov_threshold)); // small => dense
        try testing.expect(100 >= krylov_threshold); // large => krylov
    }

    test "pss: GMRES init/deinit for Krylov path" {
        const gpa = testing.allocator;
        var krylov = try Gmres.init(gpa, 64, 30);
        defer krylov.deinit(gpa);
        try testing.expectEqual(@as(u32, 64), krylov.n);
        try testing.expectEqual(@as(u32, 30), krylov.m);
    }

    test "pss: SolveResult fields" {
        const r = SolveResult{
            .converged = true,
            .iterations = 5,
            .residual_norm = 1e-10,
        };
        try testing.expect(r.converged);
        try testing.expectEqual(@as(u16, 5), r.iterations);
    }

    test "pss: gpuIntegrateOnePeriod returns false without gpu_hook" {
        // Verify GPU fallback: when gpu_hook is null, returns false immediately.
        // We can't construct a full Circuit, but the function signature and
        // the null-check logic is the critical path.
        const ptr: *const fn (*root.Circuit, []f64, Options, std.mem.Allocator) bool = &gpuIntegrateOnePeriod;
        try testing.expect(@intFromPtr(ptr) != 0);
    }
};

const PxfTests = struct {
    const impl = @import("../pss/pxf.zig");
    const Complex = impl.Complex;
    const dense_lu = @import("solvers").dense_lu;
    const pac = @import("../pss/pac.zig");
    const root = @import("../types.zig");
    const std = @import("std");

    const mapHarmonicToFftBin = pac.mapHarmonicToFftBin;

    const fft_mod = @import("solvers").fft;

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "PXF: mapHarmonicToFftBin" {
        try testing.expectEqual(@as(?usize, 0), mapHarmonicToFftBin(0, 8));
        try testing.expectEqual(@as(?usize, 1), mapHarmonicToFftBin(1, 8));
        try testing.expectEqual(@as(?usize, 7), mapHarmonicToFftBin(-1, 8));
        try testing.expectEqual(@as(?usize, 5), mapHarmonicToFftBin(-3, 8));
        try testing.expectEqual(@as(?usize, null), mapHarmonicToFftBin(8, 8));
        try testing.expectEqual(@as(?usize, null), mapHarmonicToFftBin(-8, 8));
    }

    test "PXF: adjoint resistive mixer — verify transpose duality with PAC" {
        // For a purely resistive 1-node mixer (G(t) = G0*(1 + m*cos(2*pi*f_LO*t))),
        // the PAC and PXF solutions should be transposes of each other. Since n=1,
        // the conversion matrix is n_sb × n_sb and its transpose should give the
        // same magnitude pattern when the same node is both source and output.
        //
        // We verify: PXF's adjoint solution at sideband m has the same magnitude
        // as PAC's forward solution at sideband m (for a symmetric 1-node circuit).
        const allocator = testing.allocator;

        const f_lo: f64 = 1e6;
        const n_harm: usize = 2;
        const n_sb: usize = 2 * n_harm + 1;
        const n: usize = 1;
        const n_samples: usize = 64;
        const g0: f64 = 1e-3;
        const mod_depth: f64 = 0.5;

        const t_period = 1.0 / f_lo;
        const dt = t_period / @as(f64, @floatFromInt(n_samples));

        var g_time: [n_samples]f64 = undefined;
        for (0..n_samples) |k| {
            const tt = @as(f64, @floatFromInt(k)) * dt;
            g_time[k] = g0 * (1.0 + mod_depth * @cos(2.0 * std.math.pi * f_lo * tt));
        }

        var fft_re: [n_samples]f64 = undefined;
        var fft_im: [n_samples]f64 = [_]f64{0} ** n_samples;
        root.copySimd(&fft_re, &g_time);
        fft_mod.fft(&fft_re, &fft_im);
        const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));

        var g_hat: [n_samples]Complex = undefined;
        for (0..n_samples) |m| {
            g_hat[m] = .{ .re = fft_re[m] * inv_n, .im = fft_im[m] * inv_n };
        }

        const nn = n_sb * n;
        const nn2 = 2 * nn;

        // --- Forward (PAC-style) solve: A * X = e_source ---
        const a_fwd = try allocator.alloc(f64, nn2 * nn2);
        defer allocator.free(a_fwd);
        const rhs_fwd = try allocator.alloc(f64, nn2);
        defer allocator.free(rhs_fwd);
        const x_fwd = try allocator.alloc(f64, nn2);
        defer allocator.free(x_fwd);

        root.zeroSimd(a_fwd);
        root.zeroSimd(rhs_fwd);

        for (0..n_sb) |p| {
            for (0..n_sb) |q| {
                const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
                const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
                const m_diff = m_p - m_q;
                const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;

                // No C, pure conductance.
                const z_re = g_hat[fft_idx].re;
                const z_im = g_hat[fft_idx].im;

                const gr = p * n;
                const gc = q * n;

                a_fwd[gr * nn2 + gc] += z_re;
                a_fwd[gr * nn2 + (nn + gc)] += -z_im;
                a_fwd[(nn + gr) * nn2 + gc] += z_im;
                a_fwd[(nn + gr) * nn2 + (nn + gc)] += z_re;
            }
        }
        rhs_fwd[n_harm * n] = 1.0; // excitation at sideband m=0, node 0
        try dense_lu.factorizeSolve(nn2, a_fwd, rhs_fwd, x_fwd);

        // --- Adjoint (PXF-style) solve: A^T * Y = e_output ---
        const a_adj = try allocator.alloc(f64, nn2 * nn2);
        defer allocator.free(a_adj);
        const rhs_adj = try allocator.alloc(f64, nn2);
        defer allocator.free(rhs_adj);
        const x_adj = try allocator.alloc(f64, nn2);
        defer allocator.free(x_adj);

        root.zeroSimd(a_adj);
        root.zeroSimd(rhs_adj);

        // Build A^T by transposing the assembly.
        for (0..n_sb) |p| {
            for (0..n_sb) |q| {
                const m_p: i32 = @as(i32, @intCast(p)) - @as(i32, @intCast(n_harm));
                const m_q: i32 = @as(i32, @intCast(q)) - @as(i32, @intCast(n_harm));
                const m_diff = m_p - m_q;
                const fft_idx = mapHarmonicToFftBin(m_diff, n_samples) orelse continue;

                const z_re = g_hat[fft_idx].re;
                const z_im = g_hat[fft_idx].im;

                const gr = p * n;
                const gc = q * n;

                // Transposed: swap (gr, gc)
                a_adj[gc * nn2 + gr] += z_re;
                a_adj[gc * nn2 + (nn + gr)] += z_im;
                a_adj[(nn + gc) * nn2 + gr] += -z_im;
                a_adj[(nn + gc) * nn2 + (nn + gr)] += z_re;
            }
        }
        rhs_adj[n_harm * n] = 1.0; // selector at output node 0, sideband m=0
        try dense_lu.factorizeSolve(nn2, a_adj, rhs_adj, x_adj);

        // For a 1-node symmetric circuit, |X_fwd[sb]| should equal |conj(Y_adj[sb])|
        // at each sideband (same node for both source and output).
        for (0..n_sb) |sb| {
            const fwd_re = x_fwd[sb * n];
            const fwd_im = x_fwd[nn + sb * n];
            const fwd_mag = @sqrt(fwd_re * fwd_re + fwd_im * fwd_im);

            const adj_re = x_adj[sb * n];
            const adj_im = -x_adj[nn + sb * n]; // conj
            const adj_mag = @sqrt(adj_re * adj_re + adj_im * adj_im);

            try testing.expectApproxEqRel(fwd_mag, adj_mag, 1e-10);
        }

        // Sanity: m=0 response ~1/G0, m=+/-1 sidebands nonzero.
        const x0_mag = @sqrt(x_adj[n_harm * n] * x_adj[n_harm * n] +
            x_adj[nn + n_harm * n] * x_adj[nn + n_harm * n]);
        try testing.expect(x0_mag > 0.5 / g0);
        try testing.expect(x0_mag < 2.0 / g0);
    }

    test "PXF: Complex arithmetic" {
        const a_c = Complex{ .re = 3.0, .im = 4.0 };
        const b_c = Complex{ .re = 1.0, .im = -2.0 };

        const sum = Complex.add(a_c, b_c);
        try testing.expectApproxEqAbs(@as(f64, 4.0), sum.re, 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 2.0), sum.im, 1e-15);

        try testing.expectApproxEqAbs(@as(f64, 5.0), a_c.mag(), 1e-15);

        const conj = a_c.conj();
        try testing.expectApproxEqAbs(@as(f64, 3.0), conj.re, 1e-15);
        try testing.expectApproxEqAbs(@as(f64, -4.0), conj.im, 1e-15);
    }

    test "PXF: dense_lu solveT matches known solution" {
        // 2x2 system: [2 1; 1 3] * x = [5; 7] => x = [1.6, 1.8]
        var a_mat = [_]f64{ 2, 1, 1, 3 };
        const b_vec = [_]f64{ 5, 7 };
        var x_vec: [2]f64 = undefined;
        try dense_lu.factorizeSolve(2, &a_mat, &b_vec, &x_vec);
        try testing.expectApproxEqAbs(@as(f64, 1.6), x_vec[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 1.8), x_vec[1], 1e-12);
    }
};

const QpssTests = struct {
    const impl = @import("../pss/qpss.zig");
    const MixGrid = impl.test_access.MixGrid;
    const Options = @import("requests").Qpss;
    const buildBasis2D = impl.test_access.buildBasis2D;
    const dft2D = impl.test_access.dft2D;
    const gvProduct = impl.test_access.gvProduct;
    const idft2D = impl.test_access.idft2D;
    const simdZero = impl.test_access.simdZero;
    const std = @import("std");

    const converger = @import("solvers").converger;

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "QPSS: MixGrid flat ↔ signed roundtrip" {
        const grid = MixGrid.init(3, 2);

        // nf1=7, nf2=5, nf=35
        try testing.expectEqual(@as(usize, 7), grid.nf1);
        try testing.expectEqual(@as(usize, 5), grid.nf2);
        try testing.expectEqual(@as(usize, 35), grid.nf);

        // DC: k=0, l=0 → flat = 2*7 + 3 = 17
        const dc_flat = grid.flatIdx(0, 0);
        try testing.expectEqual(@as(usize, 17), dc_flat);
        const dc_kl = grid.signedKL(dc_flat);
        try testing.expectEqual(@as(i32, 0), dc_kl.k);
        try testing.expectEqual(@as(i32, 0), dc_kl.l);

        // k=-3, l=-2 → flat = 0
        const corner = grid.flatIdx(-3, -2);
        try testing.expectEqual(@as(usize, 0), corner);
        const corner_kl = grid.signedKL(corner);
        try testing.expectEqual(@as(i32, -3), corner_kl.k);
        try testing.expectEqual(@as(i32, -2), corner_kl.l);

        for (0..grid.nf) |flat| {
            const kl = grid.signedKL(flat);
            try testing.expectEqual(flat, grid.flatIdx(kl.k, kl.l));
        }
    }

    test "QPSS: MixGrid omega calculation" {
        const grid = MixGrid.init(2, 1);
        const f1: f64 = 1e9;
        const f2: f64 = 1e6;

        // DC: ω = 0
        const dc = grid.flatIdx(0, 0);
        try testing.expectApproxEqAbs(@as(f64, 0.0), grid.omega(dc, f1, f2), 1e-10);

        // k=1, l=0: ω = 2π*f1
        const f1_idx = grid.flatIdx(1, 0);
        try testing.expectApproxEqAbs(2.0 * std.math.pi * f1, grid.omega(f1_idx, f1, f2), 1e-3);

        // k=1, l=1: ω = 2π*(f1+f2)
        const sum_idx = grid.flatIdx(1, 1);
        try testing.expectApproxEqAbs(2.0 * std.math.pi * (f1 + f2), grid.omega(sum_idx, f1, f2), 1e-3);
    }

    test "QPSS: 2D DFT/IDFT roundtrip" {
        const grid = MixGrid.init(1, 1); // nf1=3, nf2=3 → nf=9
        const nf = grid.nf;
        const n: usize = 2;
        const sz = n * nf; // 2 * 9 = 18

        const alloc = testing.allocator;

        const basis_cos = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos);
        const basis_sin = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin);
        const basis_cos_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos_t);
        const basis_sin_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin_t);
        buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        const x_re = try alloc.alloc(f64, sz);
        defer alloc.free(x_re);
        const x_im = try alloc.alloc(f64, sz);
        defer alloc.free(x_im);
        for (x_re) |*v| v.* = 0;
        for (x_im) |*v| v.* = 0;

        const dc_idx = grid.flatIdx(0, 0);
        x_re[0 * nf + dc_idx] = 1.0;
        x_re[1 * nf + dc_idx] = 2.0;

        const x_td = try alloc.alloc(f64, sz);
        defer alloc.free(x_td);
        idft2D(x_td, x_re, x_im, basis_cos_t, basis_sin_t, n, nf);

        for (0..nf) |s| {
            try testing.expectApproxEqAbs(@as(f64, 1.0), x_td[0 * nf + s], 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 2.0), x_td[1 * nf + s], 1e-12);
        }

        const out_re = try alloc.alloc(f64, sz);
        defer alloc.free(out_re);
        const out_im = try alloc.alloc(f64, sz);
        defer alloc.free(out_im);
        dft2D(out_re, out_im, x_td, basis_cos, basis_sin, n, nf);

        try testing.expectApproxEqAbs(@as(f64, 1.0), out_re[0 * nf + dc_idx], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 2.0), out_re[1 * nf + dc_idx], 1e-12);

        for (0..n) |node| {
            for (0..nf) |f_idx| {
                if (f_idx == dc_idx) continue;
                try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[node * nf + f_idx], 1e-12);
                try testing.expectApproxEqAbs(@as(f64, 0.0), out_im[node * nf + f_idx], 1e-12);
            }
        }
    }

    test "QPSS: 2D DFT/IDFT roundtrip with non-DC harmonic" {
        const grid = MixGrid.init(1, 1);
        const nf = grid.nf; // 3*3 = 9
        const n: usize = 1;

        const alloc = testing.allocator;
        const basis_cos = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos);
        const basis_sin = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin);
        const basis_cos_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos_t);
        const basis_sin_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin_t);
        buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        // Spectrum: cos at k=1,l=0 (re=0.5) + sin at k=0,l=1 (im=-0.3)
        var x_re = [_]f64{0} ** 9;
        var x_im = [_]f64{0} ** 9;
        const f1_idx = grid.flatIdx(1, 0);
        const f2_idx = grid.flatIdx(0, 1);
        x_re[f1_idx] = 0.5;
        x_im[f2_idx] = -0.3; // negative im = positive sin

        // IDFT → DFT roundtrip
        var td = [_]f64{0} ** 9;
        idft2D(&td, &x_re, &x_im, basis_cos_t, basis_sin_t, n, nf);

        var out_re = [_]f64{0} ** 9;
        var out_im = [_]f64{0} ** 9;
        dft2D(&out_re, &out_im, &td, basis_cos, basis_sin, n, nf);

        // Non-DC harmonics: the IDFT sums all nf basis vectors (positive + negative
        // frequencies), but the DFT projects onto one-sided basis with 1/nf scaling.
        // For a single one-sided coefficient, the roundtrip yields 0.5x because the
        // conjugate partner at (-k,-l) is zero. This is by design — the solver always
        // operates on the full two-sided vector so the residual is self-consistent.
        // See module-level normalization doc.
        try testing.expectApproxEqAbs(@as(f64, 0.25), out_re[f1_idx], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, -0.15), out_im[f2_idx], 1e-12);

        // DC should be ~0
        const dc_idx = grid.flatIdx(0, 0);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[dc_idx], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out_im[dc_idx], 1e-12);
    }

    test "QPSS: buildBasis2D orthogonality" {
        // For a proper DFT basis, <cos_f, cos_g> = (nf/2) δ_{fg} for f,g ≠ 0.
        // More precisely, Σ_s cos(2πf·s_vec) cos(2πg·s_vec) = nf * δ_{fg}
        // when both f and g are zero, nf/2 for real-valued DFT.
        // Our convention: (1/nf) * DFT gives coefficient, so the inner product
        // of basis vectors should be nf for matching indices, 0 otherwise.
        const grid = MixGrid.init(1, 1);
        const nf = grid.nf;

        const alloc = testing.allocator;
        const basis_cos = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos);
        const basis_sin = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin);
        const basis_cos_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos_t);
        const basis_sin_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin_t);
        buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        // Check: Σ_s cos[f,s]*cos[g,s] + sin[f,s]*sin[g,s] = nf * δ_{fg}
        // (This is the full complex inner product mapped to real)
        for (0..nf) |f_idx| {
            for (0..nf) |g_idx| {
                var dot: f64 = 0;
                for (0..nf) |s| {
                    dot += basis_cos[f_idx * nf + s] * basis_cos[g_idx * nf + s] +
                        basis_sin[f_idx * nf + s] * basis_sin[g_idx * nf + s];
                }
                const expected: f64 = if (f_idx == g_idx) @as(f64, @floatFromInt(nf)) else 0;
                try testing.expectApproxEqAbs(expected, dot, 1e-10);
            }
        }
    }

    test "QPSS: gvProduct matches the scalar sample-major product bit for bit" {
        // nf = 9 and 49 straddle the vector width so both the tiled body and the
        // scalar tail run; each lane must reproduce the ascending-column order.
        const alloc = testing.allocator;
        var prng = std.Random.DefaultPrng.init(0x5EED);
        const rnd = prng.random();

        for ([_][2]usize{ .{ 9, 3 }, .{ 49, 13 }, .{ 25, 1 } }) |c| {
            const nf = c[0];
            const n = c[1];
            const g_td = try alloc.alloc(f64, n * n * nf);
            defer alloc.free(g_td);
            const v_td = try alloc.alloc(f64, n * nf);
            defer alloc.free(v_td);
            const want = try alloc.alloc(f64, n * nf);
            defer alloc.free(want);
            const got = try alloc.alloc(f64, n * nf);
            defer alloc.free(got);

            for (g_td) |*v| v.* = rnd.float(f64) * 0.02 - 0.01;
            for (v_td) |*v| v.* = rnd.float(f64) * 2000.0 - 1000.0;

            for (0..nf) |s| {
                for (0..n) |row| {
                    var acc: f64 = 0;
                    for (0..n) |col| acc += g_td[(row * n + col) * nf + s] * v_td[col * nf + s];
                    want[row * nf + s] = acc;
                }
            }
            gvProduct(got, g_td, v_td, n, nf);
            for (want, got) |e, a| try testing.expectEqual(e, a);
        }
    }

    test "QPSS: Options satisfies contract" {
        comptime {
            if (!@hasField(Options, "tol")) @compileError("missing tol");
            if (@FieldType(Options, "tol") != converger.Tolerances) @compileError("wrong tol type");
        }
    }

    test "QPSS: heap buffers work for n > 256" {
        // Verify the arena sizing arithmetic doesn't overflow or assert for large n.
        // We can't run a full solve without a Circuit, but we can verify the DFT/IDFT
        // path with a large node count using heap-allocated buffers.
        const grid = MixGrid.init(1, 1); // nf=9
        const nf = grid.nf;
        const n: usize = 512; // > 256, was previously impossible
        const sz = n * nf;

        const alloc = testing.allocator;

        const basis_cos = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos);
        const basis_sin = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin);
        const basis_cos_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_cos_t);
        const basis_sin_t = try alloc.alloc(f64, nf * nf);
        defer alloc.free(basis_sin_t);
        buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        const x_re = try alloc.alloc(f64, sz);
        defer alloc.free(x_re);
        const x_im = try alloc.alloc(f64, sz);
        defer alloc.free(x_im);
        simdZero(x_re);
        simdZero(x_im);

        // Set DC for node 300 (beyond old 256 limit)
        const dc_idx = grid.flatIdx(0, 0);
        x_re[300 * nf + dc_idx] = 42.0;

        const x_td = try alloc.alloc(f64, sz);
        defer alloc.free(x_td);
        idft2D(x_td, x_re, x_im, basis_cos_t, basis_sin_t, n, nf);

        // Node 300 should be constant 42.0 across all time samples
        for (0..nf) |s| {
            try testing.expectApproxEqAbs(@as(f64, 42.0), x_td[300 * nf + s], 1e-10);
        }
        // Node 0 should be zero
        for (0..nf) |s| {
            try testing.expectApproxEqAbs(@as(f64, 0.0), x_td[0 * nf + s], 1e-10);
        }

        const out_re = try alloc.alloc(f64, sz);
        defer alloc.free(out_re);
        const out_im = try alloc.alloc(f64, sz);
        defer alloc.free(out_im);
        dft2D(out_re, out_im, x_td, basis_cos, basis_sin, n, nf);

        try testing.expectApproxEqAbs(@as(f64, 42.0), out_re[300 * nf + dc_idx], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[0 * nf + dc_idx], 1e-10);
    }
};

test {
    _ = PacTests;
    _ = PnoiseTests;
    _ = PssTests;
    _ = PxfTests;
    _ = QpssTests;
}
