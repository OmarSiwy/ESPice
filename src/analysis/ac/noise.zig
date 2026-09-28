//! Small-signal noise of the device generators, measured at an output node.
//! Each frequency is one adjoint solve (a lane of `freq.Stream`); the source
//! PSDs come from the devices' noise models. Densities are V^2/Hz internally
//! and the published plots are V/sqrt(Hz) and V rms.
const std = @import("std");
const freq = @import("freq.zig");
const root = @import("../types.zig");
const FreqSolver = @import("solver").freq_solve.FreqSolver;

// ngspice include/ngspice/noisedef.h:105-113.
const n_minlog = 1e-38;
const n_intfthresh = 1e-10;
const n_intuselog = 1e-10;

/// One device noise generator between two nodes, as collected at the op.
pub const NoiseSource = root.NoiseSource;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Noise;

/// The per-interval geometry `nintegrate` needs (ngspice noisean.c:436-439).
const Band = struct { del_freq: f64, del_ln_freq: f64, ln_freq: f64, ln_last_freq: f64 };

/// `exp`, linear past 700 so a steep fit cannot overflow (ngspice ninteg.c:24).
inline fn limexp(x: f64) f64 {
    return if (x > 700.0) @exp(@as(f64, 700.0)) * (1.0 + x - 700.0) else @exp(x);
}

/// Integral of the power law `a * f^exponent` fitted between two points of one
/// source's log-log spectrum (ngspice ninteg.c:27-45 Nintegrate). A near-flat
/// slope degenerates to the rectangle rule and a slope near -1 to the
/// logarithmic one. The fit has to be per source because a sum of two
/// different power laws is not a power law.
fn nintegrate(dens: f64, ln_dens: f64, ln_last_dens: f64, b: Band) f64 {
    const exponent = (ln_dens - ln_last_dens) / b.del_ln_freq;
    if (@abs(exponent) < n_intfthresh) return dens * b.del_freq;
    const a = limexp(ln_dens - exponent * b.ln_freq);
    const e1 = exponent + 1.0;
    if (@abs(e1) < n_intuselog) return a * (b.ln_freq - b.ln_last_freq);
    return a * (limexp(e1 * b.ln_freq) - limexp(e1 * b.ln_last_freq)) / e1;
}

/// The source's PSD at `f`: white plus flicker / f^ef, in A^2/Hz.
inline fn sourcePsd(src: NoiseSource, f: f64) f64 {
    if (src.flicker == 0 or f <= 0) return src.white;
    return src.white + src.flicker / std.math.pow(f64, f, src.ef);
}

/// Band integrals in V^2: output-referred, and referred back through the gain
/// to the input source's terminals (zero when the deck named no input).
pub const Integrals = struct { onoise: f64, inoise: f64 };

/// Fills `freqs`, `density` and `in_density` (V^2/Hz, all `sweep.count()`
/// long) and returns the band integrals. `in_density` is all zeros unless
/// `options.in_branch` names a source.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    in_density: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Integrals {
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points = freqs.len;
    std.debug.assert(density.len == n_points);

    // Adjoint: A^H y = e_out per omega. The conjugate drops out of |H|^2, so
    // the stacked-real transpose solve is enough.
    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const omegas = try allocator.alloc(f64, n_points);
    defer allocator.free(omegas);
    options.sweep.fill(freqs, omegas);

    // Unit excitation at the output. A differential `v(a,b)` output measures
    // the node difference, so its adjoint excitation is e_pos − e_neg; the
    // ground row is the v(0) = 0 clamp and never takes one.
    const e = try allocator.alloc(f64, nn);
    defer allocator.free(e);
    root.zeroSimd(e);
    e[options.out_node] = 1.0;
    if (options.out_neg != root.GROUND) e[options.out_neg] = -1.0;

    var stream = try freq.Stream.init(allocator, &fs, ckt, x_op, omegas, e, true);
    defer stream.deinit(allocator);

    // ln of each source's output density at the previous point (ngspice's
    // `nVar[LNLSTDENS][i]`), the other end of the per-source fit; then the
    // same densities unlogged. The input side divides the previous point's
    // output density by the CURRENT gain, as every ngspice device does
    // (resnoise.c:145-150, `LNLSTDENS + lnGainInv`): the gain is held
    // constant across the interval.
    const ln_last = try allocator.alloc(f64, 2 * noise_sources.len);
    defer allocator.free(ln_last);
    const dens_last = ln_last[noise_sources.len..];

    var integrated: f64 = 0;
    var integrated_in: f64 = 0;
    // noisean.c:376 sets lstFreq = freq before the loop, so the first point
    // has delFreq == 0 and only seeds the history.
    var prev_freq: f64 = if (n_points != 0) freqs[0] else 0;
    while (try stream.next(ckt)) |pt| {
        const k = pt.k;
        const f = freqs[k];
        const y = pt.x;

        const ln_freq = @log(@max(f, n_minlog));
        const ln_prev = @log(@max(prev_freq, n_minlog));
        const band: Band = .{
            .del_freq = f - prev_freq,
            .ln_freq = ln_freq,
            .ln_last_freq = ln_prev,
            .del_ln_freq = ln_freq - ln_prev,
        };

        // Gain from the input source to the output without a second solve:
        // the adjoint y is the transfer row, so a unit drive on the input
        // branch gives v_out = y[in_branch] (e_out^T A^-1 e_in = (A^-T e_out)^T e_in).
        const gain_sq: f64 = if (options.in_branch) |br| blk: {
            const g_re = y[br];
            const g_im = y[n + br];
            // Floored at N_MINGAIN (noisean.c:487-488).
            break :blk @max(g_re * g_re + g_im * g_im, 1e-20);
        } else 0;

        var total_density: f64 = 0;
        var total_in_density: f64 = 0;
        for (noise_sources, ln_last[0..noise_sources.len], dens_last) |src, *last, *last_dens| {
            const psd = sourcePsd(src, f);
            const yp_re: f64 = if (src.node_p != root.GROUND) y[src.node_p] else 0;
            const yn_re: f64 = if (src.node_n != root.GROUND) y[src.node_n] else 0;
            const yp_im: f64 = if (src.node_p != root.GROUND) y[n + src.node_p] else 0;
            const yn_im: f64 = if (src.node_n != root.GROUND) y[n + src.node_n] else 0;
            const h_re = yp_re - yn_re;
            const h_im = yp_im - yn_im;
            const dens = (h_re * h_re + h_im * h_im) * psd;
            total_density += dens;

            const ln_dens = @log(@max(dens, n_minlog));
            if (band.del_freq != 0) {
                integrated += nintegrate(dens, ln_dens, last.*, band);
            }
            last.* = ln_dens;

            if (options.in_branch != null) {
                const dens_in = dens / gain_sq;
                total_in_density += dens_in;
                const ln_dens_in = @log(@max(dens_in, n_minlog));
                if (band.del_freq != 0) {
                    integrated_in += nintegrate(dens_in, ln_dens_in, @log(@max(last_dens.* / gain_sq, n_minlog)), band);
                }
                last_dens.* = dens;
            }
        }

        density[k] = total_density;
        in_density[k] = total_in_density;
        prev_freq = f;
    }

    return .{ .onoise = integrated, .inoise = integrated_in };
}

/// Contract entry: the device generators measured at opts.out_node, with no
/// drive source. Real; either the spectrum (frequency, onoise_spectrum,
/// inoise_spectrum) or, with `opts.integrated`, one row of rms totals.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const x_op = ctx.x_op;

    const srcs = try ctx.circuit.collectNoiseSources(x_op, scratch);
    defer scratch.free(srcs);

    const n_points = opts.sweep.count();
    const work = try scratch.alloc(f64, @as(usize, n_points) * 3);
    defer scratch.free(work);
    const freqs = work[0..n_points];
    const density = work[n_points..][0..n_points];
    const in_density = work[2 * n_points ..][0..n_points];

    const integrated = try sweep(ctx.circuit, x_op, srcs, freqs, density, in_density, opts, scratch);

    // ngspice's two noise plots, with ngspice's names and units: the curves
    // are amplitude spectra (V/sqrt(Hz)) and the totals are V rms. `inoise`
    // is the same noise referred to the input source's terminals.
    if (opts.integrated) {
        const names = try a.dupe([]const u8, &.{ "v(onoise_total)", "v(inoise_total)" });
        errdefer a.free(names); // entries are literals
        const data = try a.alloc(f64, 2);
        data[0] = @sqrt(integrated.onoise);
        data[1] = @sqrt(integrated.inoise);
        return .{
            .plotname = "Integrated Noise",
            .varnames = names,
            .is_complex = false,
            .npoints = 1,
            .data = data,
        };
    }

    const names = try a.dupe([]const u8, &.{ "frequency", "onoise_spectrum", "inoise_spectrum" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, @as(usize, n_points) * 3);
    for (0..n_points) |i| {
        data[i * 3] = freqs[i];
        data[i * 3 + 1] = @sqrt(density[i]);
        data[i * 3 + 2] = @sqrt(in_density[i]);
    }

    return .{
        .plotname = "Noise Spectral Density Curves",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}

/// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .Band = Band,
    .nintegrate = nintegrate,
    .sourcePsd = sourcePsd,
} else {};
