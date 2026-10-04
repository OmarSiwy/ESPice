//! Small-signal analyses about the harmonic-balance solution. Each one
//! solves `hb.solveSpectrum`, samples every unknown onto a power-of-two grid
//! with `hb.orbit`, and hands that orbit to the back half of its shooting
//! twin: `.hbac` is PAC's forward sweep, `.hbxf` PXF's adjoint sweep and
//! `.hbnoise` `pnoise.orbitSweep`. The linearization, conversion matrix and
//! sideband folding are shared code, so the two orbit providers differ only
//! in how they find the orbit. `.hblin` builds the same conversion matrix
//! with the port terminations and reads S-parameters between port bands.
const std = @import("std");
const root = @import("../types.zig");
const hb = @import("hb.zig");
const pac = @import("pac.zig");
const pxf = @import("pxf.zig");
const pnoise = @import("pnoise.zig");
const mhb_lptv = @import("mhb_lptv.zig");
const dense_lu = @import("solver").dense_lu;
const k_boltzmann = @import("../ac/sp.zig").k_boltzmann;
const t0_kelvin = @import("../ac/sp.zig").t0_kelvin;

const Complex = pac.Complex;
const HbLptv = @import("core").query.HbLptv;

/// Orbit samples per period before rounding up: the `.pnoise` default. The
/// grid only has to resolve G(t) and C(t), whose harmonics run past the
/// HB's K, so it does not shrink with K.
const min_samples: usize = 64;

/// Solves HB and samples its orbit on a power-of-two grid wide enough for
/// HB's own 2(2K+1) points and for sideband offsets up to 2M.
/// error.HbDidNotConverge when Newton stops short. The caller frees `wave`.
fn orbit(ckt: *root.Circuit, opts: HbLptv, allocator: std.mem.Allocator) !pac.Orbit {
    const n: usize = ckt.n;
    const nf = 2 * @as(usize, opts.n_harmonics) + 1;
    const x_hat = try allocator.alloc(f64, n * nf);
    defer allocator.free(x_hat);
    const st = try hb.solveSpectrum(ckt, x_hat, &.{}, opts.hb(), allocator);
    if (!st.status.converged) return error.HbDidNotConverge;
    const n_sb = 2 * @as(usize, opts.n_sidebands) + 1;
    return hb.orbit(x_hat, n, opts.f0, pnoise.samplesFor(@max(min_samples, 2 * nf), n_sb), true, allocator);
}

/// The HB orbit linearized under `kind`. The caller owns the result.
fn linearize(ckt: *root.Circuit, opts: HbLptv, kind: root.AnalysisKind, allocator: std.mem.Allocator) !pac.Linearization {
    const orb = try orbit(ckt, opts, allocator);
    defer allocator.free(orb.wave);
    return pac.linearize(ckt, orb, kind, allocator);
}

/// The `pac.sweep` options for these HB options: sidebands -M..M at f0.
fn pacOptions(opts: HbLptv) pac.Options {
    return .{ .tol = opts.tol, .f_lo = opts.f0, .out_node = opts.out_node, .n_harmonics = opts.n_sidebands, .sweep = opts.sweep };
}

/// `.hbac`: periodic AC about the HB orbit.
pub const Ac = struct {
    /// The shared HB small-signal query.
    pub const Options = HbLptv;

    /// Contract entry: the deck's AC excitation on sideband 0, read at
    /// `opts.out_node`, in `.pac`'s shape: point-major complex rows
    /// (frequency, tf_h{-M}..tf_h{+M}). Several tones go to `mhb_lptv.ac`.
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        if (opts.extra_tones.len != 0) return mhb_lptv.ac(ctx, opts);
        const scratch = ctx.scratch_allocator;
        const n_freqs: usize = opts.sweep.count();
        const freqs = try scratch.alloc(f64, n_freqs);
        defer scratch.free(freqs);
        const transfer = try scratch.alloc(Complex, n_freqs * (2 * @as(usize, opts.n_sidebands) + 1));
        defer scratch.free(transfer);
        const lin = try linearize(ctx.circuit, opts, .ac, scratch);
        defer lin.deinit(scratch);
        try pac.sweep(false, ctx.circuit, lin, ctx.ac_drive, opts.out_node, freqs, transfer, pacOptions(opts), scratch);
        return pac.result(ctx.allocator, freqs, transfer, opts.n_sidebands, "Harmonic Balance AC Analysis");
    }
};

/// `.hbxf`: periodic transfer functions about the HB orbit.
pub const Xf = struct {
    /// The shared HB small-signal query.
    pub const Options = HbLptv;

    /// Contract entry: transfers from every node and sideband to
    /// `opts.out_node`, in `.pxf`'s shape: point-major complex rows
    /// (frequency, pxf_h{m}(node) for every sideband then node). Several
    /// tones go to `mhb_lptv.xf`.
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        if (opts.extra_tones.len != 0) return mhb_lptv.xf(ctx, opts);
        const scratch = ctx.scratch_allocator;
        const n: usize = ctx.circuit.n;
        const n_freqs: usize = opts.sweep.count();
        const freqs = try scratch.alloc(f64, n_freqs);
        defer scratch.free(freqs);
        const transfer = try scratch.alloc(Complex, n_freqs * (2 * @as(usize, opts.n_sidebands) + 1) * n);
        defer scratch.free(transfer);
        const drive = try scratch.alloc(f64, 2 * n);
        defer scratch.free(drive);
        @memset(drive, 0);
        drive[opts.out_node] = 1;
        const lin = try linearize(ctx.circuit, opts, .ac, scratch);
        defer lin.deinit(scratch);
        try pac.sweep(true, ctx.circuit, lin, drive, 0, freqs, transfer, pacOptions(opts), scratch);
        return pxf.result(ctx, freqs, transfer, opts.n_sidebands, "Harmonic Balance Transfer Function Analysis");
    }
};

/// `.hbnoise`: cyclostationary noise about the HB orbit.
pub const Noise = struct {
    /// The shared HB small-signal query.
    pub const Options = HbLptv;

    /// Contract entry: output noise density of v(out_node) - v(out_neg), in
    /// `.pnoise`'s shape: point-major rows (frequency, hbnoise_density).
    /// Several tones go to `mhb_lptv.noise`.
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        if (opts.extra_tones.len != 0) return mhb_lptv.noise(ctx, opts);
        const scratch = ctx.scratch_allocator;
        const srcs = try ctx.circuit.collectNoiseSources(ctx.x_op, scratch);
        defer scratch.free(srcs);
        const n_points: usize = opts.sweep.count();
        const freqs = try scratch.alloc(f64, n_points);
        defer scratch.free(freqs);
        const density = try scratch.alloc(f64, n_points);
        defer scratch.free(density);
        const orb = try orbit(ctx.circuit, opts, scratch);
        defer scratch.free(orb.wave);
        _ = try pnoise.orbitSweep(ctx.circuit, orb, srcs, freqs, density, .{
            .tol = opts.tol,
            .out_node = opts.out_node,
            .out_neg = opts.out_neg,
            .sweep = opts.sweep,
            .f_fundamental = opts.f0,
            .n_sidebands = opts.n_sidebands,
        }, scratch);
        return pnoise.result(ctx.allocator, freqs, density, "hbnoise_density", "Harmonic Balance Noise Analysis");
    }
};

/// `.hblin`: frequency-translation S-parameters about the HB orbit (HSPICE
/// RF, [RF Ch.10]). Port i is read in its band s_i·f + h_i·f0, which is
/// sideband s_i·h_i of the conversion matrix, conjugated for a lower band
/// (s = −1): that band's physical phasor is the conjugate of the sideband's.
/// Every port is terminated in its z0 on every sideband; per input frequency
/// one dense factorization serves one solve per port. `noisecalc=1` adds
/// the single-sideband noise figure from port 1 to port 2 (`NF`, a power
/// ratio): the output noise in port 2's band with port 1's z0 at 290 K, from
/// every sideband, over that z0's noise from port 1's band alone. The
/// circuit's own noise comes from `pnoise.orbitSweep` at port 2's band and
/// the z0 terms from one adjoint solve on the same factor.
pub const Lin = struct {
    /// The `.hblin` query: ports with their bands and z0, plus the HB tone.
    pub const Options = @import("core").query.Hblin;
    const Band = @import("core").query.Port.Band;

    /// Contract entry: complex point-major rows (frequency, S(1,1), S(1,2),
    /// ..., S(N,N)[, NF]), S(i,j) = b_i / a_j with each wave in its port's
    /// band.
    /// error.PortBandOutsideSidebands when a band's harmonic exceeds
    /// `opts.n_sidebands`.
    pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
        const a = ctx.allocator;
        const scratch = ctx.scratch_allocator;
        const ckt = ctx.circuit;
        const n: usize = ckt.n;
        const ports = opts.ports;
        const np = ports.len;
        const n_harm: usize = opts.n_sidebands;
        for (ports) |p| if (@abs(p.band.harmonic) > n_harm) return error.PortBandOutsideSidebands;
        const lptv = opts.lptv();
        const orb = try orbit(ckt, lptv, scratch);
        defer scratch.free(orb.wave);
        const lin = try pac.linearize(ckt, orb, .ac, scratch);
        defer lin.deinit(scratch);
        const pac_opts = pacOptions(lptv);

        const n_sb = 2 * n_harm + 1;
        const nn = n_sb * n;
        const nn2 = 2 * nn;
        const work = try scratch.alloc(f64, nn2 * nn2 + 2 * nn2);
        defer scratch.free(work);
        const a_work = work[0 .. nn2 * nn2];
        const rhs = work[nn2 * nn2 ..][0..nn2];
        const x = work[nn2 * nn2 + nn2 ..][0..nn2];
        const piv = try scratch.alloc(u32, nn2);
        defer scratch.free(piv);
        // Frequency-dependent stamps, added as `pac.sweep` adds them.
        const n_samples = lin.g_hat.len / lin.col_ptr[n];
        const series = if (lin.wave.len != 0) ckt.ac_dyn_slots.len * n_sb else 0;
        const dyn_f = try scratch.alloc(f64, n_sb + 2 * series * (n_samples + 1) + 2 * n_samples);
        defer scratch.free(dyn_f);
        const dyn_hat = try scratch.alloc(Complex, series * n_samples);
        defer scratch.free(dyn_hat);

        const noisy = opts.noise and np >= 2;
        const names = try a.alloc([]const u8, 1 + np * np + @intFromBool(noisy));
        names[0] = "frequency";
        for (0..np) |i| for (0..np) |j| {
            names[1 + i * np + j] = try std.fmt.allocPrint(a, "S({d},{d})", .{ i + 1, j + 1 });
        };
        if (noisy) names[names.len - 1] = "NF";
        const n_points: usize = opts.sweep.count();
        // Noise: port 2's band frequency, and the output noise of port 1's
        // z0 at T0 from every sideband and from port 1's band alone.
        const noise_work = try scratch.alloc(f64, if (noisy) 3 * n_points else 0);
        defer scratch.free(noise_work);
        const row_len = 2 * names.len;
        const data = try a.alloc(f64, n_points * row_len);

        var sw = opts.sweep.iter();
        var k: usize = 0;
        while (sw.next()) |f| : (k += 1) {
            if (k != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = k, .total = n_points });
            root.zeroSimd(a_work);
            pac.buildConversionMatrix(false, a_work, lin, n, n_sb, nn, nn2, f, pac_opts);
            if (series != 0) {
                const omegas = dyn_f[0..n_sb];
                for (omegas, 0..) |*w, q| w.* = 2.0 * std.math.pi * (f + @as(f64, @floatFromInt(@as(i32, @intCast(q)) - @as(i32, @intCast(n_harm)))) * opts.f0);
                pac.dynSpectra(ckt, lin, omegas, dyn_f[n_sb..], dyn_hat);
                pac.addDynConversion(false, a_work, lin, ckt.ac_dyn_slots, dyn_hat, n, n_sb, nn, nn2);
            }
            // z0 in series with every ideal port source, on every sideband.
            for (ports) |p| if (!p.series_z0) for (0..n_sb) |q| {
                const r = q * n + p.branch;
                a_work[r * nn2 + r] -= p.z0;
                a_work[(nn + r) * nn2 + nn + r] -= p.z0;
            };
            try dense_lu.factorize(nn2, a_work, piv);
            const row = data[k * row_len ..][0..row_len];
            row[0] = f;
            row[1] = 0;
            for (ports, 0..) |pj, j| {
                // A unit source voltage on port j's branch in its band.
                @memset(rhs, 0);
                rhs[sideband(pj.band, n_harm) * n + pj.branch] = 1;
                dense_lu.solveFactored(nn2, a_work, piv, rhs, x);
                const a_j = 1 / (2 * @sqrt(pj.z0));
                for (ports, 0..) |pi, i| {
                    const base = sideband(pi.band, n_harm) * n;
                    const v = rowV(x, nn, base, pi.node).sub(rowV(x, nn, base, pi.neg));
                    const cur = rowV(x, nn, base, pi.branch).scale(-1);
                    var b = v.sub(cur.scale(pi.z0)).scale(1 / (2 * @sqrt(pi.z0)));
                    if (pi.band.sign < 0) b.im = -b.im;
                    const s = b.scale(1 / a_j);
                    row[2 * (1 + i * np + j)] = s.re;
                    row[2 * (1 + i * np + j) + 1] = s.im;
                }
            }
            if (noisy) {
                // Adjoint of port 2's voltage in its band: Aᵀ y = e on the
                // stacked-real factor gives |transfer|² = y_re² + y_im² from
                // a voltage on port 1's branch in each sideband.
                const p1 = ports[0];
                const p2 = ports[1];
                @memset(rhs, 0);
                const out = sideband(p2.band, n_harm) * n;
                if (p2.node != root.GROUND) rhs[out + p2.node] = 1;
                if (p2.neg != root.GROUND) rhs[out + p2.neg] = -1;
                dense_lu.solveFactoredT(nn2, a_work, piv, rhs, x);
                const e2 = 4 * k_boltzmann * t0_kelvin * p1.z0;
                var all: f64 = 0;
                for (0..n_sb) |q| all += rowV(x, nn, q * n, p1.branch).magSq();
                noise_work[k] = @abs(@as(f64, @floatFromInt(p2.band.sign)) * f + @as(f64, @floatFromInt(p2.band.harmonic)) * opts.f0);
                noise_work[n_points + k] = e2 * all;
                noise_work[2 * n_points + k] = e2 * rowV(x, nn, sideband(p1.band, n_harm) * n, p1.branch).magSq();
            }
        }
        if (noisy) {
            // The circuit's own noise at port 2's band (`.hbnoise` on the same
            // orbit); the P cards' z0 are noiseless resistors, so it holds
            // no port termination.
            const f_out = noise_work[0..n_points];
            const dev = try scratch.alloc(f64, n_points);
            defer scratch.free(dev);
            const freqs = try scratch.alloc(f64, n_points);
            defer scratch.free(freqs);
            const srcs = try ckt.collectNoiseSources(ctx.x_op, scratch);
            defer scratch.free(srcs);
            _ = try pnoise.orbitSweep(ckt, orb, srcs, freqs, dev, .{
                .tol = opts.tol,
                .out_node = ports[1].node,
                .out_neg = ports[1].neg,
                .sweep = .{ .kind = .poi, .list = f_out, .points = @intCast(n_points), .f_start = f_out[0], .f_stop = f_out[n_points - 1] },
                .f_fundamental = opts.f0,
                .n_sidebands = opts.n_sidebands,
            }, scratch);
            for (0..n_points) |i| {
                const f_ssb = (dev[i] + noise_work[n_points + i]) / noise_work[2 * n_points + i];
                data[i * row_len + row_len - 2] = f_ssb;
                data[i * row_len + row_len - 1] = 0;
            }
        }
        return .{
            .plotname = "Harmonic Balance LIN Analysis",
            .varnames = names,
            .is_complex = true,
            .npoints = n_points,
            .data = data,
        };
    }

    /// Conversion-matrix sideband index of a port band: s·h, offset by M.
    /// The caller has checked |h| <= M.
    fn sideband(band: Band, n_harm: usize) usize {
        return @intCast(@as(i32, @intCast(n_harm)) + @as(i32, band.sign) * @as(i32, band.harmonic));
    }

    /// Unknown `row` of the sideband block at `base` in the stacked-real
    /// solution; ground is zero.
    fn rowV(x: []const f64, nn: usize, base: usize, row: u32) Complex {
        if (row == root.GROUND) return Complex.zero;
        return .{ .re = x[base + row], .im = x[nn + base + row] };
    }
};

test "Lin.sideband offsets the signed band by M" {
    try std.testing.expectEqual(@as(usize, 2), Lin.sideband(.{}, 2));
    try std.testing.expectEqual(@as(usize, 1), Lin.sideband(.{ .harmonic = 1, .sign = -1 }, 2));
    try std.testing.expectEqual(@as(usize, 3), Lin.sideband(.{ .harmonic = -1, .sign = -1 }, 2));
    try std.testing.expectEqual(@as(usize, 4), Lin.sideband(.{ .harmonic = 2 }, 2));
}

test {
    // mhb_lptv.zig is reached only through here.
    _ = mhb_lptv;
}
