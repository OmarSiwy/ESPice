//! Device-generated small-signal noise measured at a circuit node.
//! Each frequency uses one adjoint solve; source PSDs come from device noisePsd.
//! Spectra are V^2/Hz and integrated results are V rms.
const std = @import("std");
const batch = @import("batch.zig");
const root = @import("../types.zig");
const types = @import("numerics");
const FreqSolver = @import("solvers").freq_solve.FreqSolver;

// ngspice include/ngspice/noisedef.h:105-113.
const n_minlog = 1e-38;
const n_intfthresh = 1e-10;
const n_intuselog = 1e-10;

pub const NoiseSource = root.NoiseSource;

pub const Options = @import("requests").Noise;

/// The per-interval geometry `nintegrate` needs, ngspice noisean.c:436-439.
const Band = struct { del_freq: f64, del_ln_freq: f64, ln_freq: f64, ln_last_freq: f64 };

/// ngspice ninteg.c:24 -- linear past 700 so a steep fit cannot overflow.
inline fn limexp(x: f64) f64 {
    return if (x > 700.0) @exp(@as(f64, 700.0)) * (1.0 + x - 700.0) else @exp(x);
}

/// ngspice ninteg.c:27-45 Nintegrate: the integral of `a * f^exponent` between
/// two points of one source's log-log spectrum. A near-flat slope degenerates
/// to the rectangle rule and a near -1 slope to the logarithmic one, which is
/// why the fit has to be per source: the sum of two different power laws is
/// not a power law.
fn nintegrate(dens: f64, ln_dens: f64, ln_last_dens: f64, b: Band) f64 {
    const exponent = (ln_dens - ln_last_dens) / b.del_ln_freq;
    if (@abs(exponent) < n_intfthresh) return dens * b.del_freq;
    const a = limexp(ln_dens - exponent * b.ln_freq);
    const e1 = exponent + 1.0;
    if (@abs(e1) < n_intuselog) return a * (b.ln_freq - b.ln_last_freq);
    return a * (limexp(e1 * b.ln_freq) - limexp(e1 * b.ln_last_freq)) / e1;
}

/// Device PSD coefficients evaluated at frequency f.
inline fn sourcePsd(src: NoiseSource, f: f64) f64 {
    if (src.flicker == 0 or f <= 0) return src.white;
    return src.white + src.flicker / std.math.pow(f64, f, src.ef);
}

/// Band integrals in V^2 — output-referred and, when the deck named an input
/// source, referred back through the gain to that source's terminals.
pub const Integrals = struct { onoise: f64, inoise: f64 };

/// Fill the measured PSDs and return their band integrals in V^2.
/// `in_density` is filled only when `options.in_branch` names a source.
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

    // Adjoint: A^H y = e_out per omega (conjugate drops out of |H|^2, so the
    // stacked-real transpose solve suffices). One shared rhs, lane = frequency:
    // GPU batch adjoint dispatch orelse the CPU lane solveBatch(adjoint=true).
    // PSD accumulation stays CPU (cheap).
    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const omegas = try allocator.alloc(f64, n_points);
    defer allocator.free(omegas);
    options.sweep.fill(freqs, omegas);

    // RHS: unit excitation at the output (stacked-real, length 2n). A
    // differential `v(a,b)` output measures the node DIFFERENCE, so its
    // adjoint excitation is e_pos − e_neg; GROUND is never a matrix row.
    const e = try allocator.alloc(f64, nn);
    defer allocator.free(e);
    root.zeroSimd(e);
    e[options.out_node] = 1.0;
    if (options.out_neg != root.GROUND) e[options.out_neg] = -1.0;

    const y_lanes = try batch.solve(ckt, &fs, allocator, ckt.g_vals, ckt.c_vals, omegas, e, true);
    defer allocator.free(y_lanes);

    // ln of each source's density at the previous point -- ngspice's
    // `nVar[LNLSTDENS][i]`, the other half of the per-source fit. Two halves:
    // output-referred first, then the same fit on the input-referred density,
    // because dividing by a frequency-dependent gain is not a rescaling of
    // the integral.
    const ln_last = try allocator.alloc(f64, 2 * noise_sources.len);
    defer allocator.free(ln_last);
    const ln_last_in = ln_last[noise_sources.len..];

    var integrated: f64 = 0;
    var integrated_in: f64 = 0;
    // noisean.c:376 `data->lstFreq = data->freq` BEFORE the loop: the first
    // point has delFreq == 0 and contributes nothing but history.
    var prev_freq: f64 = if (n_points != 0) freqs[0] else 0;
    for (0..n_points) |k| {
        if (k != 0 and k % batch.quantum == 0) try ckt.checkpoint(.{ .phase = .postprocess, .completed = k, .total = n_points });
        const f = freqs[k];
        const y = y_lanes[k * nn ..][0..nn];

        const ln_freq = @log(@max(f, n_minlog));
        const ln_prev = @log(@max(prev_freq, n_minlog));
        const band: Band = .{
            .del_freq = f - prev_freq,
            .ln_freq = ln_freq,
            .ln_last_freq = ln_prev,
            .del_ln_freq = ln_freq - ln_prev,
        };

        // Gain from the named input source to the output, for free: the
        // adjoint y already IS the transfer row, so v_out for a unit drive on
        // the input branch is y[in_branch] (x_out = e_out^T A^-1 e_in =
        // (A^-T e_out)^T e_in). No second solve.
        const gain_sq: f64 = if (options.in_branch) |br| blk: {
            const g_re = y[br];
            const g_im = y[n + br];
            break :blk g_re * g_re + g_im * g_im;
        } else 0;

        var total_density: f64 = 0;
        var total_in_density: f64 = 0;
        for (noise_sources, ln_last[0..noise_sources.len], ln_last_in) |src, *last, *last_in| {
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
                const dens_in = if (gain_sq > 0) dens / gain_sq else 0;
                total_in_density += dens_in;
                const ln_dens_in = @log(@max(dens_in, n_minlog));
                if (band.del_freq != 0) {
                    integrated_in += nintegrate(dens_in, ln_dens_in, last_in.*, band);
                }
                last_in.* = ln_dens_in;
            }
        }

        density[k] = total_density;
        in_density[k] = total_in_density;
        prev_freq = f;
    }

    return .{ .onoise = integrated, .inoise = integrated_in };
}

/// Measure the device generators at opts.out_node, without a drive source.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    // `defer`-freed below == scratch, and `a` is a results arena that cannot
    // reclaim it. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

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
    // are AMPLITUDE spectra (V/sqrt(Hz)) while the accumulator works in
    // V^2/Hz, and the totals are V rms. `inoise` is the same noise referred
    // to the named input source's terminals — which is the only thing that
    // source is for, and why a name no card carries is a rejected deck.
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

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .Band = Band,
    .nintegrate = nintegrate,
    .sourcePsd = sourcePsd,
} else {};
