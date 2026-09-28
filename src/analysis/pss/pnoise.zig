//! Periodic noise: shoot to the periodic steady state, linearize about it
//! (pac.zig), and per output frequency solve the transposed LPTV conversion
//! matrix once. That gives every node's transfer from each input sideband
//! f_out + m*f_fundamental to the output at f_out. Source PSDs come from the
//! devices' `noisePsd`, re-sampled along the orbit (cyclostationary
//! modulation).
const std = @import("std");
const root = @import("../types.zig");
const pac = @import("pac.zig");

const Complex = pac.Complex;

pub const NoiseSource = root.NoiseSource;

pub const Options = @import("core").query.Pnoise;

/// Outcome of a pnoise sweep.
pub const SweepStatus = struct {
    /// sqrt of the trapezoid integral of the density over the sweep, in V.
    total_noise: f64,
    pss_converged: bool,
};

/// S(f) = white + flicker/|f|^ef at one sideband, from one time sample's
/// coefficients.
inline fn sourcePsd(white: f64, flicker: f64, ef: f64, f_sideband: f64) f64 {
    if (flicker == 0) return white;
    // ponytail: 1/f diverges at the DC sideband, so |f| is floored at 1e-30.
    // Upgrade to the analytic band integral if it ever matters.
    const f_abs = @max(@abs(f_sideband), 1e-30);
    return white + flicker / std.math.pow(f64, f_abs, ef);
}

/// Periodic noise density at `options.out_node`, in V^2/Hz.
///
/// Each source is a stationary unit noise n(t) scaled by a periodic
/// amplitude a(t) = sqrt(PSD(t)) (white and flicker parts separately), so
/// its spectrum at sideband m is sum_k A_k N(f + (m-k)f0), A_k the Fourier
/// coefficients of a. With H_m the transfer from sideband m to the output at
/// f_out, the output density is
///   sum_j S_n(f_out + j*f0) * |sum_m H_m A_{m-j}|^2,
/// which for a time-invariant circuit and source is |H_0|^2 * S(f_out): an
/// LTI network converts no sideband.
/// The caller owns freqs and density, both sweep-count long. Returns
/// error.NoiseTopologyChanged if the sources differ along the orbit.
pub fn sweep(
    ckt: *root.Circuit,
    x_dc: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SweepStatus {
    const n: usize = ckt.n;
    const n_srcs = noise_sources.len;
    const m_max: usize = options.n_sidebands;
    const n_sb = 2 * m_max + 1;
    std.debug.assert(freqs.len == density.len);
    // The FFT needs a power of two; 2*n_sb bins keep |m - j| <= 2M alias-free.
    const n_samples: usize = std.math.ceilPowerOfTwoAssert(usize, @max(options.pss_n_samples, 2 * n_sb));

    const orb = try pac.orbit(ckt, x_dc, .{
        .tol = options.tol,
        .period = 1.0 / options.f_fundamental,
        .n_samples = @intCast(n_samples),
        .max_shooting_iter = options.pss_shoot_max_iter,
        .shooting_tol = options.pss_shoot_tol,
        .max_newton_iter = options.pss_newton_max_iter,
        .newton_tol = options.pss_newton_tol,
    }, allocator);
    defer allocator.free(orb.wave);
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
            amp[s * n_samples + k] = @sqrt(src.white);
            amp[terms + s * n_samples + k] = @sqrt(src.flicker);
            // ponytail: the flicker exponent is a model constant in every
            // device, so sample 0 stands for the period.
            if (k == 0) exponent[s] = src.ef;
        }
    }
    try pac.spectra(amp[0..terms], n_samples, amp_hat[0..terms], allocator);
    try pac.spectra(amp[terms..], n_samples, amp_hat[terms..], allocator);
    const white_hat = amp_hat[0..terms];
    const flicker_hat = amp_hat[terms..];

    // Adjoint transfers of every node and sideband to out_node at f_out.
    const nn = n_sb * n;
    const transfer = try allocator.alloc(Complex, freqs.len * nn);
    defer allocator.free(transfer);
    const drive = try allocator.alloc(f64, 2 * n);
    defer allocator.free(drive);
    @memset(drive, 0);
    if (options.out_node != root.GROUND) drive[options.out_node] = 1;
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

    return .{ .total_noise = @sqrt(integrated_noise), .pss_converged = orb.converged };
}

/// Contract entry: device noise sources at ctx.x_op, LPTV sweep. Point-major
/// rows (frequency, pnoise_density); an unconverged PSS says so in the plot
/// name rather than failing.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
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

    const names = try a.dupe([]const u8, &.{ "frequency", "pnoise_density" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, @as(usize, n_points) * 2);
    for (0..n_points) |i| {
        data[i * 2] = freqs_buf[i];
        data[i * 2 + 1] = density_buf[i];
    }

    return .{
        .plotname = if (st.pss_converged) "Periodic Noise Analysis" else "Periodic Noise Analysis (PSS not converged)",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .sourcePsd = sourcePsd,
} else {};
