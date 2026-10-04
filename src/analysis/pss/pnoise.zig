//! Periodic noise: shoot to the periodic steady state, linearize about it
//! (pac.zig), and per output frequency solve the transposed LPTV conversion
//! matrix once. That gives every node's transfer from each input sideband
//! f_out + m*f_fundamental to the output at f_out. Source PSDs come from the
//! devices' `noisePsd`, re-sampled along the orbit (cyclostationary
//! modulation). `orbitSweep` is everything after the orbit, so `.hbnoise`
//! runs it on the harmonic-balance solution instead (hb_lptv.zig).
const std = @import("std");
const root = @import("../types.zig");
const pac = @import("pac.zig");

const Complex = pac.Complex;

/// One device noise generator between two nodes, as `collectNoiseSources` lists it.
pub const NoiseSource = root.NoiseSource;

/// The `.pnoise` query; `.hbnoise` and `.phasenoise` fill one in for `orbitSweep`.
pub const Options = @import("core").query.Pnoise;

/// Outcome of a pnoise sweep.
pub const SweepStatus = struct {
    /// sqrt of the trapezoid integral of the density over the sweep, in V.
    total_noise: f64,
    /// False when the shooting stopped short; the density is about its last period.
    pss_converged: bool,
};

/// S(f) = white + flicker/|f|^ef at one sideband, from one time sample's
/// coefficients.
pub inline fn sourcePsd(white: f64, flicker: f64, ef: f64, f_sideband: f64) f64 {
    if (flicker == 0) return white;
    // ponytail: 1/f diverges at the DC sideband, so |f| is floored at 1e-30.
    // Upgrade to the analytic band integral if it ever matters.
    const f_abs = @max(@abs(f_sideband), 1e-30);
    return white + flicker / std.math.pow(f64, f_abs, ef);
}

/// Periodic noise density at `options.out_node` (minus `out_neg`), in
/// V^2/Hz, about the shooting PSS from `x_dc`: `pac.orbit` then
/// `orbitSweep`. The caller owns freqs and density, both sweep-count long.
pub fn sweep(
    ckt: *root.Circuit,
    x_dc: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SweepStatus {
    const n_sb = 2 * @as(usize, options.n_sidebands) + 1;
    const orb = try pac.orbit(ckt, x_dc, .{
        .tol = options.tol,
        .period = 1.0 / options.f_fundamental,
        .n_samples = @intCast(samplesFor(options.pss_n_samples, n_sb)),
        .max_shooting_iter = options.pss_shoot_max_iter,
        .shooting_tol = options.pss_shoot_tol,
        .max_newton_iter = options.pss_newton_max_iter,
        .newton_tol = options.pss_newton_tol,
    }, allocator);
    defer allocator.free(orb.wave);
    return .{
        .total_noise = try orbitSweep(ckt, orb, noise_sources, freqs, density, options, allocator),
        .pss_converged = orb.converged,
    };
}

/// Orbit samples per period for `n_sb` sidebands: at least `requested`, a
/// power of two (the FFT's), and 2*n_sb so bins |m - j| <= 2M stay
/// alias-free. Asserts the result fits a usize.
pub fn samplesFor(requested: usize, n_sb: usize) usize {
    return std.math.ceilPowerOfTwoAssert(usize, @max(requested, 2 * n_sb));
}

/// Periodic noise density about any periodic orbit `orb` (shooting or HB),
/// whose sample count must be a power of two of at least 2*(2M+1). Reads
/// `out_node`, `out_neg`, `sweep`, `f_fundamental` and `n_sidebands` from
/// `options`; the `pss_*` fields are the orbit provider's. Returns the rms
/// noise over the sweep in V (sqrt of the trapezoid integral).
///
/// Each source is a stationary unit noise n(t) scaled by a periodic
/// amplitude a(t) = sqrt(PSD(t)) (white and flicker parts separately), so
/// its spectrum at sideband m is sum_k A_k N(f + (m-k)f0), A_k the Fourier
/// coefficients of a. With H_m the transfer from sideband m to the output at
/// f_out, the output density is
///   sum_j S_n(f_out + j*f0) * |sum_m H_m A_{m-j}|^2,
/// which for a time-invariant circuit and source is |H_0|^2 * S(f_out): an
/// LTI network converts no sideband.
/// A source whose density is negative somewhere on the orbit keeps the
/// sign on its amplitude, sign(D)*sqrt(|D|), as VACASK does, rather than
/// turning into NaN. The caller owns freqs and density, both sweep-count
/// long. Returns error.NoiseTopologyChanged if the sources differ along
/// the orbit.
pub fn orbitSweep(
    ckt: *root.Circuit,
    orb: pac.Orbit,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !f64 {
    const n: usize = ckt.n;
    const n_srcs = noise_sources.len;
    const m_max: usize = options.n_sidebands;
    const n_sb = 2 * m_max + 1;
    std.debug.assert(freqs.len == density.len);
    const n_samples = orb.samples(n);
    std.debug.assert(std.math.isPowerOfTwo(n_samples) and n_samples >= 2 * n_sb);

    const lin = try pac.linearize(ckt, orb, .noise, allocator);
    defer lin.deinit(allocator);

    // Source amplitudes along the orbit, source-major time series (white
    // then flicker): amp[s * n_samples + k], and their spectra, bin-major.
    const terms = n_samples * n_srcs;
    const amp = try allocator.alloc(f64, 2 * terms);
    defer allocator.free(amp);
    const amp_hat = try allocator.alloc(Complex, 2 * terms);
    defer allocator.free(amp_hat);
    const exponent = try allocator.alloc(f64, n_srcs);
    defer allocator.free(exponent);

    for (0..n_samples) |k| {
        const srcs_k = try ckt.collectNoiseSources(orb.state(k, n), allocator);
        defer allocator.free(srcs_k);
        if (srcs_k.len != n_srcs) return error.NoiseTopologyChanged;
        for (srcs_k, noise_sources, 0..) |src, original, s| {
            if (src.node_p != original.node_p or src.node_n != original.node_n)
                return error.NoiseTopologyChanged;
            amp[s * n_samples + k] = signedSqrt(src.white);
            amp[terms + s * n_samples + k] = signedSqrt(src.flicker);
            // ponytail: the flicker exponent is a model constant in every
            // device, so sample 0 stands for the period.
            if (k == 0) exponent[s] = src.ef;
        }
    }
    try pac.spectra(amp[0..terms], n_samples, amp_hat[0..terms], allocator);
    try pac.spectra(amp[terms..], n_samples, amp_hat[terms..], allocator);
    const white_hat = amp_hat[0..terms];
    const flicker_hat = amp_hat[terms..];
    if (options.strobe) |t| return strobed(ckt, lin, noise_sources, .{ white_hat, flicker_hat }, exponent, n_samples, freqs, density, options, t, allocator);

    // Adjoint transfers of every node and sideband to out_node at f_out.
    const nn = n_sb * n;
    const transfer = try allocator.alloc(Complex, freqs.len * nn);
    defer allocator.free(transfer);
    const drive = try allocator.alloc(f64, 2 * n);
    defer allocator.free(drive);
    @memset(drive, 0);
    if (options.out_node != root.GROUND) drive[options.out_node] = 1;
    if (options.out_neg != root.GROUND) drive[options.out_neg] = -1;
    const pac_opts: pac.Options = .{
        .f_lo = options.f_fundamental,
        .out_node = options.out_node,
        .n_harmonics = options.n_sidebands,
        .sweep = options.sweep,
    };
    try pac.sweep(true, ckt, lin, drive, 0, freqs, transfer, pac_opts, allocator);

    var integrated_noise: f64 = 0;
    for (freqs, density, 0..) |f_out, *total, fi| {
        const h = transfer[fi * nn ..][0..nn];
        total.* = 0;
        for (noise_sources, exponent, 0..) |src, ef, s| {
            for (0..n_sb) |j| {
                // Input sideband j: sum_m H_m A_{m-j}, white and flicker.
                var w: Complex = .zero;
                var fl: Complex = .zero;
                for (0..n_sb) |m| {
                    const bin = pac.mapHarmonicToFftBin(@as(i32, @intCast(m)) - @as(i32, @intCast(j)), n_samples) orelse continue;
                    const hp = if (src.node_p != root.GROUND) h[m * n + src.node_p] else Complex.zero;
                    const hn = if (src.node_n != root.GROUND) h[m * n + src.node_n] else Complex.zero;
                    const hm = Complex.sub(hp, hn);
                    w = Complex.add(w, Complex.mul(hm, white_hat[bin * n_srcs + s]));
                    fl = Complex.add(fl, Complex.mul(hm, flicker_hat[bin * n_srcs + s]));
                }
                const f_sb = f_out + (@as(f64, @floatFromInt(j)) - @as(f64, @floatFromInt(m_max))) * options.f_fundamental;
                // A 1/f shape is evaluated at the unfolded sideband f_sb.
                total.* += sourcePsd(w.magSq(), fl.magSq(), ef, f_sb);
            }
        }
        if (fi > 0) integrated_noise += 0.5 * (density[fi - 1] + total.*) * (f_out - freqs[fi - 1]);
    }

    return @sqrt(integrated_noise);
}

/// Periodic time-dependent noise (HSPICE `.ptdnoise`): the density, over
/// noise frequency f, whose integral is the output noise variance at time
/// `t` of the period. A unit source n at f enters at f + i*f0 with the
/// amplitude's coefficient A_i and reaches the output at f + p*f0, so
///   S_t(f) = sum_s S_s(f) |sum_p e^(j 2 pi p f0 t) sum_m H^(p)_m A_{m-M+p}|^2
/// with H^(p)_m the adjoint transfer from input sideband m to the output at
/// f + p*f0. Averaged over t it is the power the output receives from f,
/// summed over output sidebands. Cost: 2M+1 adjoint solves per point,
/// against one for `.pnoise`. Returns the rms noise at `t` over the sweep.
fn strobed(
    ckt: *root.Circuit,
    lin: pac.Linearization,
    noise_sources: []const NoiseSource,
    hats: [2][]const Complex,
    exponent: []const f64,
    n_samples: usize,
    freqs: []f64,
    density: []f64,
    options: Options,
    t: f64,
    allocator: std.mem.Allocator,
) !f64 {
    const n: usize = ckt.n;
    const n_srcs = noise_sources.len;
    const m_max: usize = options.n_sidebands;
    const n_sb = 2 * m_max + 1;
    const nn = n_sb * n;
    const f0 = options.f_fundamental;
    const shifted = try allocator.alloc(f64, n_sb);
    defer allocator.free(shifted);
    const out_freqs = try allocator.alloc(f64, n_sb);
    defer allocator.free(out_freqs);
    const transfer = try allocator.alloc(Complex, n_sb * nn);
    defer allocator.free(transfer);
    const drive = try allocator.alloc(f64, 2 * n);
    defer allocator.free(drive);
    @memset(drive, 0);
    if (options.out_node != root.GROUND) drive[options.out_node] = 1;
    if (options.out_neg != root.GROUND) drive[options.out_neg] = -1;
    const phase = try allocator.alloc(Complex, n_sb);
    defer allocator.free(phase);
    for (phase, 0..) |*e, p| {
        const w = 2 * std.math.pi * (@as(f64, @floatFromInt(p)) - @as(f64, @floatFromInt(m_max))) * f0 * t;
        e.* = .{ .re = @cos(w), .im = @sin(w) };
    }

    var integrated: f64 = 0;
    var sw = options.sweep.iter();
    var fi: usize = 0;
    while (sw.next()) |f| : (fi += 1) {
        freqs[fi] = f;
        for (shifted, 0..) |*s, p| s.* = f + (@as(f64, @floatFromInt(p)) - @as(f64, @floatFromInt(m_max))) * f0;
        const pac_opts: pac.Options = .{
            .f_lo = f0,
            .out_node = options.out_node,
            .n_harmonics = options.n_sidebands,
            .sweep = .{ .f_start = shifted[0], .f_stop = shifted[n_sb - 1], .points = @intCast(n_sb), .kind = .poi, .list = shifted },
        };
        try pac.sweep(true, ckt, lin, drive, 0, out_freqs, transfer, pac_opts, allocator);
        var total: f64 = 0;
        for (noise_sources, exponent, 0..) |src, ef, s| {
            for (hats, 0..) |hat, part| {
                var g: Complex = .zero;
                for (0..n_sb) |p| {
                    const h = transfer[p * nn ..][0..nn];
                    var inner: Complex = .zero;
                    for (0..n_sb) |m| {
                        const i = @as(i32, @intCast(m + p)) - 2 * @as(i32, @intCast(m_max));
                        const bin = pac.mapHarmonicToFftBin(i, n_samples) orelse continue;
                        const hp = if (src.node_p != root.GROUND) h[m * n + src.node_p] else Complex.zero;
                        const hn = if (src.node_n != root.GROUND) h[m * n + src.node_n] else Complex.zero;
                        inner = Complex.add(inner, Complex.mul(Complex.sub(hp, hn), hat[bin * n_srcs + s]));
                    }
                    g = Complex.add(g, Complex.mul(phase[p], inner));
                }
                total += if (part == 0) g.magSq() else sourcePsd(0, g.magSq(), ef, f);
            }
        }
        density[fi] = total;
        if (fi > 0) integrated += 0.5 * (density[fi - 1] + total) * (f - freqs[fi - 1]);
    }
    return @sqrt(integrated);
}

/// sign(d)*sqrt(|d|): a source amplitude whose square is the density d.
pub inline fn signedSqrt(d: f64) f64 {
    return std.math.copysign(@sqrt(@abs(d)), d);
}

/// Contract entry: device noise sources at ctx.x_op, LPTV sweep. Point-major
/// rows (frequency, pnoise_density); an unconverged PSS says so in the plot
/// name rather than failing.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const x_op = ctx.x_op;

    const scratch = ctx.scratch_allocator;
    const srcs = try ctx.circuit.collectNoiseSources(x_op, scratch);
    defer scratch.free(srcs);

    const n_points = opts.sweep.count();
    const freqs_buf = try scratch.alloc(f64, n_points);
    defer scratch.free(freqs_buf);
    const density_buf = try scratch.alloc(f64, n_points);
    defer scratch.free(density_buf);

    const st = try sweep(ctx.circuit, x_op, srcs, freqs_buf, density_buf, opts, scratch);
    if (opts.strobe) |t| {
        var res = try result(ctx.allocator, freqs_buf, density_buf, "ptdnoise_density", "");
        res.plotname = try std.fmt.allocPrint(ctx.allocator, "Periodic Time-Dependent Noise Analysis (time={e}){s}", .{ t, if (st.pss_converged) "" else " (PSS not converged)" });
        return res;
    }
    return result(ctx.allocator, freqs_buf, density_buf, "pnoise_density", if (st.pss_converged) "Periodic Noise Analysis" else "Periodic Noise Analysis (PSS not converged)");
}

/// The periodic-noise shape, shared with `.hbnoise`: point-major rows
/// (frequency, `column`) in `a`. `column` and `plotname` are literals.
pub fn result(a: std.mem.Allocator, freqs: []const f64, density: []const f64, column: []const u8, plotname: []const u8) !root.Result {
    const names = try a.dupe([]const u8, &.{ "frequency", column });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, freqs.len * 2);
    for (freqs, density, 0..) |f, d, i| {
        data[i * 2] = f;
        data[i * 2 + 1] = d;
    }
    return .{
        .plotname = plotname,
        .varnames = names,
        .is_complex = false,
        .npoints = freqs.len,
        .data = data,
    };
}

/// Private implementation access for the analysis test suite; void outside tests.
pub const test_access = if (@import("builtin").is_test) .{
    .sourcePsd = sourcePsd,
} else {};

test samplesFor {
    try std.testing.expectEqual(@as(usize, 64), samplesFor(64, 5));
    try std.testing.expectEqual(@as(usize, 16), samplesFor(3, 5));
    try std.testing.expectEqual(@as(usize, 128), samplesFor(100, 1));
    try std.testing.expectEqual(@as(usize, 2), samplesFor(0, 1));
}

test signedSqrt {
    try std.testing.expectEqual(@as(f64, 2), signedSqrt(4));
    try std.testing.expectEqual(@as(f64, -2), signedSqrt(-4));
    // The sign of zero survives, and NaN stays NaN rather than a number.
    try std.testing.expect(std.math.signbit(signedSqrt(-0.0)));
    try std.testing.expect(std.math.isNan(signedSqrt(std.math.nan(f64))));
    try std.testing.expectEqual(std.math.inf(f64), signedSqrt(std.math.inf(f64)));
}
