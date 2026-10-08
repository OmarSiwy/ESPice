//! Periodic-family unit tests: pac/pxf, pnoise, pss, qpss and multi-tone hb.
//! Oracles: the analytic steady state of an RC low-pass (pss and hb), a
//! resistive mixer's f_in ± f_LO lines, PAC's magnitudes for PXF, the dense
//! LU for the Krylov conversion solve, the dense Jacobian Newton for the
//! one-tone GMRES path, the dense product for `gvProduct` (bit for bit),
//! transform round trips for the DFT pairs, the recomputed
//! |k*f1 + l*f2| of each qpss box product, and the HSPICE [CR .HB]
//! truncation examples for the multi-tone spectrum.

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
            const opts: impl.Options = .{ .f_lo = f_lo, .out_node = 0, .n_harmonics = n_harm, .n_time_samples = n_samples, .sweep = .{ .f_start = 1, .f_stop = 1 } };
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

    const analysis = @import("../types.zig");
    const hb = @import("../pss/hb.zig");
    const converger = @import("solver").converger;
    const Builder = @import("builder").Builder;
    const Library = @import("device").Library;
    const models = @import("models");

    /// x_dc of `ckt` by DC Newton from zero; the caller frees it.
    fn dcPoint(ckt: *analysis.Circuit, a: std.mem.Allocator) ![]f64 {
        const x = try a.alloc(f64, ckt.n);
        errdefer a.free(x);
        @memset(x, 0);
        try ckt.computeBaseline();
        const ws = try ckt.workspace();
        ckt.setSimState(.{ .kind = .dc });
        _ = try converger.run(ckt, ws, x, 0, .{}, analysis.EvalHook{});
        return x;
    }

    /// The certificate of a periodic solution: one period from the final
    /// x0 ends where it started, on every probe.
    fn expectPeriodic(wave: []const f64, n_samples: usize, cols: usize, tol: f64) !void {
        for (wave[1..cols], wave[n_samples * cols + 1 ..][0 .. cols - 1]) |start, end|
            try testing.expectApproxEqAbs(start, end, tol);
    }

    test "pss and hb: an RC low-pass lands on its analytic steady state" {
        // v_in = sin(wt) through R into C: v_out = A sin(wt - phi) with
        // A = 1/sqrt(1 + (wRC)^2), phi = atan(wRC), so the cos coefficient is
        // -A sin(phi) and the sin coefficient A cos(phi).
        const a = testing.allocator;
        var lib = try Library.init(a);
        defer lib.deinit();
        var b = try Builder.init(a, &lib);
        const vin = try b.addNode();
        const out = try b.addNode();
        const f: f64 = 1e3;
        const r: f64 = 1e3;
        const c: f64 = 1e-7;
        try b.addDevice(models.vsource, "", .{ .dc = 0, .waveform = 2, .sin_vo = 0, .sin_va = 1, .sin_freq = f }, .{}, .{ vin, analysis.GROUND });
        try b.addDevice(models.resistor, "", .{ .r = r }, .{}, .{ vin, out });
        try b.addDevice(models.capacitor, "", .{ .c = c }, .{}, .{ out, analysis.GROUND });
        var prepared = try b.compile();
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, a);
        defer ckt.deinit();
        const x_dc = try dcPoint(&ckt, a);
        defer a.free(x_dc);

        const wrc = 2 * std.math.pi * f * r * c;
        const amp = 1 / @sqrt(1 + wrc * wrc);
        const phi = std.math.atan(wrc);
        const want_c = -amp * @sin(phi);
        const want_s = amp * @cos(phi);

        // Shooting: trapezoid at 128 steps is O((w dt)^2) ~ 2e-4 off.
        const ns: usize = 128;
        const wave = try a.alloc(f64, (ns + 1) * 2);
        defer a.free(wave);
        const res = try impl.solve(&ckt, x_dc, &.{out}, wave, .{ .period = 1 / f, .n_samples = ns }, a);
        try testing.expect(res.converged);
        try expectPeriodic(wave, ns, 2, 1e-6);
        var c1: f64 = 0;
        var s1: f64 = 0;
        for (0..ns) |k| {
            const ang = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(ns));
            c1 += 2 * wave[2 * k + 1] * @cos(ang) / @as(f64, @floatFromInt(ns));
            s1 += 2 * wave[2 * k + 1] * @sin(ang) / @as(f64, @floatFromInt(ns));
        }
        try testing.expectApproxEqAbs(want_c, c1, 1e-3);
        try testing.expectApproxEqAbs(want_s, s1, 1e-3);

        // HB is exact for a linear circuit: the fundamental to roundoff,
        // nothing at DC or above it.
        const nf: usize = 17;
        const x_hat = try a.alloc(f64, @as(usize, ckt.n) * nf);
        defer a.free(x_hat);
        const st = try hb.solveSpectrum(&ckt, x_hat, &.{}, .{ .f0 = f }, a);
        try testing.expect(st.status.converged);
        const spec = x_hat[@as(usize, out) * nf ..][0..nf];
        try testing.expectApproxEqAbs(want_c, spec[1], 1e-9);
        try testing.expectApproxEqAbs(want_s, spec[2], 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 0), spec[0], 1e-12);
        for (spec[3..]) |v| try testing.expectApproxEqAbs(@as(f64, 0), v, 1e-12);
    }

    test "pss: the Krylov path converges to a periodic orbit" {
        // An RC ladder past `krylov_threshold` unknowns takes matrix-free
        // GMRES; its certificate is that the returned period closes.
        const a = testing.allocator;
        var lib = try Library.init(a);
        defer lib.deinit();
        var b = try Builder.init(a, &lib);
        const vin = try b.addNode();
        try b.addDevice(models.vsource, "", .{ .dc = 0.5, .waveform = 2, .sin_vo = 0.5, .sin_va = 1, .sin_freq = 1e3 }, .{}, .{ vin, analysis.GROUND });
        var prev = vin;
        var first = vin;
        for (0..krylov_threshold + 10) |i| {
            const mid = try b.addNode();
            try b.addDevice(models.resistor, "", .{ .r = 100 }, .{}, .{ prev, mid });
            try b.addDevice(models.capacitor, "", .{ .c = 1e-8 }, .{}, .{ mid, analysis.GROUND });
            if (i == 0) first = mid;
            prev = mid;
        }
        var prepared = try b.compile();
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, a);
        defer ckt.deinit();
        try testing.expect(ckt.n >= krylov_threshold);
        const x_dc = try dcPoint(&ckt, a);
        defer a.free(x_dc);

        const ns: usize = 64;
        const probes = [_]u32{ first, prev };
        const wave = try a.alloc(f64, (ns + 1) * (1 + probes.len));
        defer a.free(wave);
        const res = try impl.solve(&ckt, x_dc, &probes, wave, .{ .period = 1e-3, .n_samples = ns }, a);
        try testing.expect(res.converged);
        try testing.expect(res.residual_norm < 1e-7);
        try expectPeriodic(wave, ns, 1 + probes.len, 1e-6);
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
    const mhb = @import("../pss/mhb.zig");
    const std = @import("std");
    const testing = std.testing;

    test "qpss: every box product reads the one-sided line at its |frequency|" {
        // Oracle: the product's frequency recomputed from (k, l), and the
        // two-sided count: DC alone, every other line once from each side.
        const f1: f64 = 1000;
        const f2: f64 = 1414.213562373095;
        const k1: u16 = 3;
        const k2: u16 = 2;
        const spec = try mhb.spectrum(testing.allocator, &.{ f1, f2 }, &.{ k1, k2 }, 0, 1);
        defer spec.deinit(testing.allocator);
        var lines: [7 * 5]u32 = undefined;
        impl.boxLines(spec, f1, f2, k1, k2, &lines);
        var hits: [7 * 5]u8 = @splat(0);
        for (lines, 0..) |j, flat| {
            const k: f64 = @floatFromInt(@as(i32, @intCast(flat % 7)) - 3);
            const l: f64 = @floatFromInt(@as(i32, @intCast(flat / 7)) - 2);
            try testing.expectEqual(@abs(k * f1 + l * f2), spec.freqs[j]);
            hits[j] += 1;
        }
        try testing.expectEqual(@as(u32, 0), lines[2 * 7 + 3]);
        try testing.expectEqual(@as(usize, 18), spec.freqs.len);
        for (hits[0..spec.freqs.len], 0..) |h, j| try testing.expectEqual(@as(u8, if (j == 0) 1 else 2), h);
    }

    test "qpss: a product merged into a commensurate line maps to that line" {
        // f2 = 2 f1: (-1, 1) and (1, 0) are both 1000 Hz, one kept line.
        const spec = try mhb.spectrum(testing.allocator, &.{ 1000, 2000 }, &.{ 1, 1 }, 0, 1);
        defer spec.deinit(testing.allocator);
        var lines: [9]u32 = undefined;
        impl.boxLines(spec, 1000, 2000, 1, 1, &lines);
        try testing.expectEqual(lines[1 * 3 + 2], lines[2 * 3 + 0]);
        try testing.expectEqual(@as(f64, 1000), spec.freqs[lines[2 * 3 + 0]]);
    }
};

const MhbTests = struct {
    const impl = @import("../pss/mhb.zig");
    const hb = @import("../pss/hb.zig");
    const analysis = @import("../types.zig");
    const Builder = @import("builder").Builder;
    const Library = @import("device").Library;
    const models = @import("models");
    const std = @import("std");
    const testing = std.testing;
    const f1: f64 = 1000;
    const f2: f64 = 1300;

    test "residualNorm: a NaN residual never reads as converged (#83)" {
        try testing.expectEqual(@as(f64, 3), impl.residualNorm(&.{ 1, -3, 2 }));
        try testing.expect(std.math.isNan(impl.residualNorm(&.{ 1, std.math.nan(f64), 2 })));
    }

    /// Expects `spec` to hold exactly the products (k1, k2), DC first and
    /// by frequency.
    fn expectLines(spec: impl.Spectrum, want: []const [2]i16) !void {
        try testing.expectEqual(want.len, spec.freqs.len);
        var freqs: [32]f64 = undefined;
        for (want, 0..) |k, j| freqs[j] = @as(f64, @floatFromInt(k[0])) * f1 + @as(f64, @floatFromInt(k[1])) * f2;
        std.sort.pdq(f64, freqs[0..want.len], {}, std.sort.asc(f64));
        for (spec.freqs, freqs[0..want.len]) |got, f| try testing.expectApproxEqAbs(f, got, 1e-9);
        for (spec.freqs, 0..) |f, j| {
            const k = spec.mix[2 * j ..][0..2];
            try testing.expectApproxEqAbs(f, @as(f64, @floatFromInt(k[0])) * f1 + @as(f64, @floatFromInt(k[1])) * f2, 1e-9);
        }
    }

    // [CR .HB] examples 1 to 6, the frontend's defaults applied: NHARMS
    // defaults to INTMODMAX and INTMODMAX to the largest NHARMS.
    test "mhb spectrum: HSPICE .HB truncation examples" {
        const a = testing.allocator;
        const tones = [_]f64{ f1, f2 };
        const im1 = [_][2]i16{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
        const im2 = im1 ++ [_][2]i16{ .{ 1, 1 }, .{ -1, 1 }, .{ 2, 0 }, .{ 0, 2 } };
        const im3 = im2 ++ [_][2]i16{ .{ 2, 1 }, .{ 2, -1 }, .{ 1, 2 }, .{ -1, 2 }, .{ 3, 0 }, .{ 0, 3 } };
        const ex5 = im2 ++ [_][2]i16{ .{ 2, 1 }, .{ 2, -1 }, .{ 1, 2 }, .{ -1, 2 } };
        const ex6 = ex5 ++ [_][2]i16{ .{ 3, 0 }, .{ 0, 3 }, .{ 4, 0 }, .{ 0, 4 }, .{ 5, 0 }, .{ 0, 5 } };
        const cases = .{
            .{ [_]u16{ 1, 1 }, 1, &im1 },
            .{ [_]u16{ 2, 2 }, 2, &im2 },
            .{ [_]u16{ 3, 3 }, 3, &im3 },
            .{ [_]u16{ 2, 2 }, 3, &ex5 },
            .{ [_]u16{ 5, 5 }, 3, &ex6 },
        };
        inline for (cases) |c| {
            const nh = c[0];
            const spec = try impl.spectrum(a, &tones, &nh, c[1], 1);
            defer spec.deinit(a);
            try expectLines(spec, c[2]);
        }
        // Box: every |k_i| <= 2, 12 lines on the positive half plus DC.
        const box = try impl.spectrum(a, &tones, &.{ 2, 2 }, 0, 1);
        defer box.deinit(a);
        try testing.expectEqual(@as(usize, 13), box.freqs.len);
    }

    test "mhb spectrum: SUBHARMS steps of the first tone count one order" {
        const a = testing.allocator;
        // `.hb tones=1k 1.3k nharms=3 3 intmodmax=3 subharms=2`.
        const spec = try impl.spectrum(a, &.{ 500, 1300 }, &.{ 6, 3 }, 3, 2);
        defer spec.deinit(a);
        const has = struct {
            fn f(sp: impl.Spectrum, hz: f64) bool {
                return for (sp.freqs) |x| {
                    if (@abs(x - hz) < 1e-9) break true;
                } else false;
            }
        }.f;
        try testing.expect(has(spec, 500)); // a subharmonic
        try testing.expect(has(spec, 3000)); // the tone's own 6th step
        try testing.expect(has(spec, 3300)); // 4·500 + 1300, order 2 + 1
        try testing.expect(!has(spec, 3800)); // 5·500 + 1300, order 3 + 1
    }

    test "mhb spectrum: commensurate products merge onto the lowest order" {
        const a = testing.allocator;
        const spec = try impl.spectrum(a, &.{ 1000, 2000 }, &.{ 2, 2 }, 0, 1);
        defer spec.deinit(a);
        try testing.expectEqual(@as(usize, 7), spec.freqs.len);
        for (spec.freqs, 0..) |f, j| try testing.expectEqual(1000 * @as(f64, @floatFromInt(j)), f);
        // 2 kHz is tone 2 itself, not 2·f1 or the order-5 2·f2 - f1 - ...
        try testing.expectEqualSlices(i16, &.{ 0, 1 }, spec.mix[4..6]);
    }

    test "mhb transform: the APFT inverts its own instants, one tone projects" {
        const a = testing.allocator;
        inline for (.{ .{ &[_]f64{ f1, f2 }, &[_]u16{ 5, 5 }, 3 }, .{ &[_]f64{ f1, f2, 1710 }, &[_]u16{ 2, 2, 2 }, 3 }, .{ &[_]f64{f1}, &[_]u16{7}, 0 } }) |c| {
            const spec = try impl.spectrum(a, c[0], c[1], c[2], 1);
            defer spec.deinit(a);
            const nf = 2 * spec.freqs.len - 1;
            const nt = impl.test_access.transformSamples(spec);
            const buf = try a.alloc(f64, nt + 2 * nt * nf);
            defer a.free(buf);
            const tr = try impl.test_access.transform(spec, c[0], buf, a);
            for (0..nf) |i| for (0..nf) |j| {
                var acc: f64 = 0;
                for (0..nt) |s| acc += tr.fwd[i * nt + s] * tr.inv[s * nf + j];
                try testing.expectApproxEqAbs(@as(f64, if (i == j) 1 else 0), acc, 1e-12);
            };
        }
    }

    // The conversion-matrix Krylov path's oracle is the dense LU, forward
    // (PAC) and adjoint (PXF), on a pumped diode ladder with charge.
    test "pac: the Krylov conversion solve matches the dense LU both ways" {
        const a = testing.allocator;
        const pac = @import("../pss/pac.zig");
        const converger = @import("solver").converger;
        var lib = try Library.init(a);
        defer lib.deinit();
        var b = try Builder.init(a, &lib);
        const vin = try b.addNode();
        try b.addDevice(models.vsource, "", .{ .dc = 0.2, .waveform = 2, .sin_vo = 0.2, .sin_va = 0.6, .sin_freq = 1e3 }, .{}, .{ vin, analysis.GROUND });
        var prev = vin;
        for (0..4) |_| {
            const mid = try b.addNode();
            try b.addDevice(models.resistor, "", .{ .r = 300 }, .{}, .{ prev, mid });
            try b.addDevice(models.diode, "", .{ .is = 1e-14, .cjo = 5e-12 }, .{}, .{ mid, analysis.GROUND });
            try b.addDevice(models.capacitor, "", .{ .c = 2e-8 }, .{}, .{ mid, analysis.GROUND });
            prev = mid;
        }
        var prepared = try b.compile();
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, a);
        defer ckt.deinit();
        try ckt.computeBaseline();
        const n: usize = ckt.n;

        const x_op = try a.alloc(f64, n);
        defer a.free(x_op);
        @memset(x_op, 0);
        const ws = try ckt.workspace();
        ckt.setSimState(.{ .kind = .dc });
        _ = try converger.run(&ckt, ws, x_op, 0, .{}, analysis.EvalHook{});

        const opts: pac.Options = .{ .f_lo = 1e3, .out_node = prev, .n_harmonics = 3, .sweep = .{ .f_start = 10, .f_stop = 1e4, .points = 2 } };
        const lin = try pac.settle(&ckt, x_op, opts, a);
        defer lin.deinit(a);
        const n_f = opts.sweep.count();
        const n_sb: usize = 7;
        const drive = try a.alloc(f64, 2 * n);
        defer a.free(drive);
        @memset(drive, 0);
        drive[prev] = 1;
        drive[n + vin] = 0.5;
        const freqs = try a.alloc(f64, 2 * n_f);
        defer a.free(freqs);
        const out = try a.alloc(@import("core").numerics.Complex, 4 * n_f * n_sb * n);
        defer a.free(out);
        const ta = pac.test_access;
        inline for (.{ false, true }) |adjoint| {
            const len = n_f * (if (adjoint) n_sb * n else n_sb);
            const dense = out[0..len];
            const krylov = out[len..][0..len];
            try ta.sweepDense(adjoint, &ckt, lin, drive, @intCast(prev), freqs[0..n_f], dense, opts, a);
            try ta.sweepKrylov(adjoint, &ckt, lin, drive, @intCast(prev), freqs[n_f..], krylov, opts, a);
            var peak: f64 = 0;
            for (dense) |z| peak = @max(peak, @abs(z.re) + @abs(z.im));
            for (dense, krylov) |d, k| {
                try testing.expectApproxEqAbs(d.re, k.re, 1e-8 * peak);
                try testing.expectApproxEqAbs(d.im, k.im, 1e-8 * peak);
            }
        }
    }

    // The GMRES path's oracle is the dense Newton hb.zig takes below
    // `useGmres`: same residual, same fixed point.
    test "mhb: one tone through GMRES matches the dense Jacobian solve" {
        const a = testing.allocator;
        var lib = try Library.init(a);
        defer lib.deinit();
        var b = try Builder.init(a, &lib);
        const vin = try b.addNode();
        const mid = try b.addNode();
        const out = try b.addNode();
        try b.addDevice(models.vsource, "", .{ .dc = 0.3, .waveform = 2, .sin_vo = 0.3, .sin_va = 0.8, .sin_freq = 1e3 }, .{}, .{ vin, analysis.GROUND });
        try b.addDevice(models.resistor, "", .{ .r = 1000 }, .{}, .{ vin, mid });
        try b.addDevice(models.diode, "", .{ .is = 1e-14, .cjo = 1e-12 }, .{}, .{ mid, out });
        try b.addDevice(models.capacitor, "", .{ .c = 1e-7 }, .{}, .{ out, analysis.GROUND });
        try b.addDevice(models.resistor, "", .{ .r = 2000 }, .{}, .{ out, analysis.GROUND });
        var prepared = try b.compile();
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, a);
        defer ckt.deinit();
        try ckt.computeBaseline();

        const opts: impl.Options = .{ .f0 = 1e3, .n_harmonics = 8 };
        const len = @as(usize, ckt.n) * 17;
        const dense = try a.alloc(f64, len);
        defer a.free(dense);
        const krylov = try a.alloc(f64, len);
        defer a.free(krylov);
        try testing.expect((try hb.solveSpectrum(&ckt, dense, &.{}, opts, a)).status.converged);
        try testing.expect((try impl.solveOneTone(&ckt, krylov, opts, a)).converged);
        for (dense, krylov) |d, k| try testing.expectApproxEqAbs(d, k, 1e-9);
    }

    test "mhb: gvProduct over the pattern matches the dense product bit for bit" {
        // nf = 9 and 49 straddle the vector width so both the tiled body and the
        // scalar tail run; each lane must reproduce the ascending-column order.
        // The oracle is the dense row sum with zeros off the pattern, which
        // include negative-zero products.
        const alloc = testing.allocator;
        var prng = std.Random.DefaultPrng.init(0x5EED);
        const rnd = prng.random();

        for ([_][2]usize{ .{ 9, 3 }, .{ 49, 13 }, .{ 25, 1 } }) |c| {
            const nf = c[0];
            const n = c[1];
            // Random pattern with every diagonal, as Circuit.freeze builds.
            var col_ptr: std.ArrayList(u32) = .empty;
            defer col_ptr.deinit(alloc);
            var row_idx: std.ArrayList(u32) = .empty;
            defer row_idx.deinit(alloc);
            try col_ptr.append(alloc, 0);
            for (0..n) |col| {
                for (0..n) |row| if (row == col or rnd.boolean())
                    try row_idx.append(alloc, @intCast(row));
                try col_ptr.append(alloc, @intCast(row_idx.items.len));
            }
            const nnz = row_idx.items.len;
            const g_td = try alloc.alloc(f64, nnz * nf);
            defer alloc.free(g_td);
            const dense = try alloc.alloc(f64, n * n * nf);
            defer alloc.free(dense);
            const v_td = try alloc.alloc(f64, n * nf);
            defer alloc.free(v_td);
            const want = try alloc.alloc(f64, n * nf);
            defer alloc.free(want);
            const got = try alloc.alloc(f64, n * nf);
            defer alloc.free(got);

            for (g_td) |*v| v.* = rnd.float(f64) * 0.02 - 0.01;
            for (v_td) |*v| v.* = rnd.float(f64) * 2000.0 - 1000.0;
            @memset(dense, 0);
            for (0..n) |col| for (col_ptr.items[col]..col_ptr.items[col + 1]) |slot| {
                const row = row_idx.items[slot];
                @memcpy(dense[(row * n + col) * nf ..][0..nf], g_td[slot * nf ..][0..nf]);
            };

            for (0..nf) |s| {
                for (0..n) |row| {
                    var acc: f64 = 0;
                    for (0..n) |col| acc += dense[(row * n + col) * nf + s] * v_td[col * nf + s];
                    want[row * nf + s] = acc;
                }
            }
            impl.gvProduct(got, g_td, v_td, col_ptr.items, row_idx.items, nf);
            try testing.expectEqualSlices(u64, @ptrCast(want), @ptrCast(got));
        }
    }
};

test {
    _ = PacTests;
    _ = PnoiseTests;
    _ = PssTests;
    _ = QpssTests;
    _ = MhbTests;
}
