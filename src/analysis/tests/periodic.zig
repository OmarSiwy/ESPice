//! Periodic-family unit tests: pac/pxf, pnoise, pss and qpss.

const PacTests = struct {
    const impl = @import("../pss/pac.zig");
    const Complex = impl.Complex;
    const dense_lu = @import("solver").dense_lu;
    const fft_mod = @import("solver").fft;
    const mapHarmonicToFftBin = impl.mapHarmonicToFftBin;
    const std = @import("std");
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

    /// A 1-node resistive mixer, G(t) = G0·(1 + m·cos(2π f_LO t)), through
    /// the real conversion-matrix builder: forward (PAC) or transposed (PXF),
    /// unit drive on sideband 0. Returns the 2·n_sb real-expanded solution.
    const mixer = struct {
        const f_lo: f64 = 1e6;
        const n_harm: usize = 2;
        const n_sb: usize = 2 * n_harm + 1;
        const n_samples: usize = 64;
        const g0: f64 = 1e-3;
        const mod_depth: f64 = 0.5;

        fn gHat() [n_samples]Complex {
            const dt = 1.0 / f_lo / @as(f64, @floatFromInt(n_samples));
            var fft_re: [n_samples]f64 = undefined;
            var fft_im: [n_samples]f64 = @splat(0);
            for (&fft_re, 0..) |*g, k| g.* = g0 * (1.0 + mod_depth * @cos(2.0 * std.math.pi * f_lo * @as(f64, @floatFromInt(k)) * dt));
            fft_mod.fft(&fft_re, &fft_im);
            const inv_n = 1.0 / @as(f64, @floatFromInt(n_samples));
            var g_hat: [n_samples]Complex = undefined;
            for (&g_hat, fft_re, fft_im) |*g, re, im| g.* = .{ .re = re * inv_n, .im = im * inv_n };
            return g_hat;
        }

        fn solve(comptime adjoint: bool) ![2 * n_sb]f64 {
            const g_hat = gHat();
            const c_hat: [n_samples]Complex = @splat(Complex.zero);
            var a_work: [4 * n_sb * n_sb]f64 = @splat(0);
            var rhs: [2 * n_sb]f64 = @splat(0);
            var x: [2 * n_sb]f64 = undefined;
            const opts: impl.Options = .{ .f_lo = f_lo, .n_harmonics = n_harm, .n_time_samples = n_samples, .sweep = .{ .f_start = 1, .f_stop = 1 } };
            const lin: impl.Linearization = .{ .g_hat = &g_hat, .c_hat = &c_hat, .col_ptr = &.{ 0, 1 }, .row_idx = &.{0} };
            impl.buildConversionMatrix(adjoint, &a_work, lin, 1, n_sb, n_sb, 2 * n_sb, 0, opts);
            rhs[n_harm] = 1.0;
            try dense_lu.factorizeSolve(2 * n_sb, &a_work, &rhs, &x);
            return x;
        }

        fn mag(x: [2 * n_sb]f64, sb: usize) f64 {
            return @sqrt(x[sb] * x[sb] + x[n_sb + sb] * x[n_sb + sb]);
        }
    };

    test "PAC: resistive mixer translates f_in to f_in +/- f_LO" {
        const m = mixer;
        // G_0 = g0, G_{+-1} = g0*m/2.
        const g_hat = m.gHat();
        try testing.expectApproxEqAbs(m.g0, g_hat[0].re, 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 0), g_hat[0].im, 1e-10);
        try testing.expectApproxEqAbs(m.g0 * m.mod_depth / 2.0, g_hat[1].re, 1e-10);
        try testing.expectApproxEqAbs(m.g0 * m.mod_depth / 2.0, g_hat[m.n_samples - 1].re, 1e-10);

        const x = try m.solve(false);
        // Direct response near 1/G0, perturbed by the sideband coupling.
        const x0 = m.mag(x, m.n_harm);
        try testing.expect(x0 > 0.5 / m.g0 and x0 < 2.0 / m.g0);
        // m = +-1 carry the translated tone, about mod_depth/2 of the direct
        // one, and symmetric.
        const xp1 = m.mag(x, m.n_harm + 1);
        const xm1 = m.mag(x, m.n_harm - 1);
        try testing.expect(xp1 / x0 > 0.1 and xp1 / x0 < 0.5);
        try testing.expectApproxEqRel(xp1, xm1, 0.1);
    }

    test "PXF: the transposed mixer has PAC's sideband magnitudes" {
        // One node is both source and output, so |X_fwd[sb]| == |conj(Y_adj[sb])|.
        const m = mixer;
        const fwd = try m.solve(false);
        const adj = try m.solve(true);
        for (0..m.n_sb) |sb| try testing.expectApproxEqRel(m.mag(fwd, sb), m.mag(adj, sb), 1e-10);
    }
};

const PnoiseTests = struct {
    const impl = @import("../pss/pnoise.zig");
    const NoiseSource = impl.NoiseSource;
    const sourcePsd = impl.test_access.sourcePsd;
    const std = @import("std");

    const q_electron = 1.602176634e-19;

    // The white-noise magnitude is the device's (tested with ac/noise and the
    // ngspice fixtures); sourcePsd owns only the sideband frequency axis.

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
    const Options = @import("core").query.Pss;
    const krylov_threshold = impl.test_access.krylov_threshold;
    const simdCopy = impl.test_access.simdCopy;
    const simdZero = impl.test_access.simdZero;
    const std = @import("std");
    const testing = std.testing;

    test "pss: small systems solve dense, large ones with Krylov" {
        try testing.expect(krylov_threshold > 10);
        try testing.expect(krylov_threshold <= 100);
    }

    test "pss: simdCopy round-trip" {
        var a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
        var b: [10]f64 = undefined;
        simdZero(&b);
        simdCopy(&b, &a);
        for (0..10) |i| try testing.expectEqual(a[i], b[i]);
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
};

const QpssTests = struct {
    const impl = @import("../pss/qpss.zig");
    const MixGrid = impl.test_access.MixGrid;
    const buildTransform = impl.test_access.buildTransform;
    const buildSampleTimes = impl.test_access.buildSampleTimes;
    const transformWork = impl.test_access.transformWork;
    const dft2D = impl.test_access.dft2D;
    const gvProduct = impl.test_access.gvProduct;
    const idft2D = impl.test_access.idft2D;
    const simdZero = impl.test_access.simdZero;
    const std = @import("std");
    const testing = std.testing;

    // One incommensurate pair for every basis test, with the transform built
    // the way the solver builds it: APFT instants, then Γ and its inverse.
    const tone1: f64 = 1000.0;
    const tone2: f64 = 1414.213562373095;

    fn makeTransform(
        alloc: std.mem.Allocator,
        grid: MixGrid,
        times: []f64,
        basis_cos: []f64,
        basis_sin: []f64,
        basis_cos_t: []f64,
        basis_sin_t: []f64,
    ) !void {
        buildSampleTimes(times, grid, tone1, tone2);
        const need = transformWork(grid.nf);
        const work = try alloc.alloc(f64, need.f64s);
        defer alloc.free(work);
        const piv = try alloc.alloc(u32, need.u32s);
        defer alloc.free(piv);
        try buildTransform(grid, tone1, tone2, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t, work, piv);
    }

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
        const times = try alloc.alloc(f64, nf);
        defer alloc.free(times);
        try makeTransform(alloc, grid, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

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
        const times = try alloc.alloc(f64, nf);
        defer alloc.free(times);
        try makeTransform(alloc, grid, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

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

        // A lone one-sided coefficient round-trips at 0.5x because its conjugate
        // partner at (-k,-l) is zero. The solver always carries the full
        // two-sided vector, so its residual is self-consistent.
        try testing.expectApproxEqAbs(@as(f64, 0.25), out_re[f1_idx], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, -0.15), out_im[f2_idx], 1e-12);

        // DC should be ~0
        const dc_idx = grid.flatIdx(0, 0);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[dc_idx], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out_im[dc_idx], 1e-12);
    }

    test "QPSS: sampled two-tone drive is a clean pair of spectral lines" {
        // Sampling A1*sin(w1 t) + A2*sin(w2 t) at the APFT instants and taking
        // the 2-D DFT must land the whole signal on (±1,0) and (0,±1); a wrong
        // time grid smears it across every mix product.
        const a1: f64 = 1.0;
        const a2: f64 = 0.5;
        const grid = MixGrid.init(2, 2);
        const nf = grid.nf; // 5*5 = 25

        const alloc = testing.allocator;
        const buf = try alloc.alloc(f64, 6 * nf * nf + 3 * nf);
        defer alloc.free(buf);
        const basis_cos = buf[0 .. nf * nf];
        const basis_sin = buf[nf * nf ..][0 .. nf * nf];
        const basis_cos_t = buf[2 * nf * nf ..][0 .. nf * nf];
        const basis_sin_t = buf[3 * nf * nf ..][0 .. nf * nf];
        const times = buf[4 * nf * nf ..][0..nf];
        const td = buf[4 * nf * nf + nf ..][0..nf];
        const out_re = buf[4 * nf * nf + 2 * nf ..][0..nf];
        const out_im = buf[4 * nf * nf + 3 * nf ..][0..nf];

        try makeTransform(alloc, grid, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        const tau = 2.0 * std.math.pi;
        for (0..nf) |s| {
            td[s] = a1 * @sin(tau * tone1 * times[s]) + a2 * @sin(tau * tone2 * times[s]);
        }
        dft2D(out_re, out_im, td, basis_cos, basis_sin, 1, nf);

        // Two-sided coefficients: |X| = A/2 on each tone's own pair.
        for (0..nf) |f_idx| {
            const kl = grid.signedKL(f_idx);
            const want: f64 = if (kl.l == 0 and (kl.k == 1 or kl.k == -1))
                a1 / 2.0
            else if (kl.k == 0 and (kl.l == 1 or kl.l == -1))
                a2 / 2.0
            else
                0.0;
            const got = @sqrt(out_re[f_idx] * out_re[f_idx] + out_im[f_idx] * out_im[f_idx]);
            try testing.expectApproxEqAbs(want, got, 1e-9);
        }
    }

    test "QPSS: the transform inverts its own forward basis" {
        // Γ⁻¹Γ = I. Σ_s Γ⁻¹[f][s]·Γ[s][g] = δ_{fg}, and the stored arrays carry
        // a factor nf and a negated imaginary part (dft2D applies both), so the
        // real part of that sum reads as nf·δ_{fg} here. At APFT instants the
        // basis is not orthogonal, so the inverse is computed, not assumed.
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
        const times = try alloc.alloc(f64, nf);
        defer alloc.free(times);
        try makeTransform(alloc, grid, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        for (0..nf) |f_idx| {
            for (0..nf) |g_idx| {
                var dot: f64 = 0;
                for (0..nf) |s| {
                    dot += basis_cos[f_idx * nf + s] * basis_cos_t[s * nf + g_idx] +
                        basis_sin[f_idx * nf + s] * basis_sin_t[s * nf + g_idx];
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

    test "QPSS: DFT/IDFT roundtrip at n = 512 nodes" {
        const grid = MixGrid.init(1, 1); // nf=9
        const nf = grid.nf;
        const n: usize = 512;
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
        const times = try alloc.alloc(f64, nf);
        defer alloc.free(times);
        try makeTransform(alloc, grid, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

        const x_re = try alloc.alloc(f64, sz);
        defer alloc.free(x_re);
        const x_im = try alloc.alloc(f64, sz);
        defer alloc.free(x_im);
        simdZero(x_re);
        simdZero(x_im);

        const dc_idx = grid.flatIdx(0, 0);
        x_re[300 * nf + dc_idx] = 42.0;

        const x_td = try alloc.alloc(f64, sz);
        defer alloc.free(x_td);
        idft2D(x_td, x_re, x_im, basis_cos_t, basis_sin_t, n, nf);

        for (0..nf) |s| {
            try testing.expectApproxEqAbs(@as(f64, 42.0), x_td[300 * nf + s], 1e-10);
        }
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
    _ = QpssTests;
}
