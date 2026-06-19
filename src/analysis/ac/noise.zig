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
pub inline fn sourcePsd(src: NoiseSource, f: f64) f64 {
    if (src.flicker == 0 or f <= 0) return src.white;
    return src.white + src.flicker / std.math.pow(f64, f, src.ef);
}

/// Band integrals in V^2: output-referred, and referred back through the gain
/// to the input source's terminals (zero when the deck named no input).
pub const Integrals = struct { onoise: f64, inoise: f64 };

/// Per-generator results for the contribution columns: `dens` is point-major
/// (`n_points * n_sources`, V^2/Hz at the output); `out` and `in` are each
/// generator's own band integral in V^2. The caller zeroes `out` and `in`.
pub const PerSource = struct { dens: []f64, out: []f64, in: []f64 };

/// Fills `freqs`, `density` and `in_density` (V^2/Hz, all `sweep.count()`
/// long) and returns the band integrals. `in_density` is all zeros unless
/// `options.in_branch` names a source. `per_source`, when given, also
/// receives every generator's density and integrals.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    in_density: []f64,
    per_source: ?PerSource,
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
        for (noise_sources, ln_last[0..noise_sources.len], dens_last, 0..) |src, *last, *last_dens, i| {
            const psd = sourcePsd(src, f);
            const yp_re: f64 = if (src.node_p != root.GROUND) y[src.node_p] else 0;
            const yn_re: f64 = if (src.node_n != root.GROUND) y[src.node_n] else 0;
            const yp_im: f64 = if (src.node_p != root.GROUND) y[n + src.node_p] else 0;
            const yn_im: f64 = if (src.node_n != root.GROUND) y[n + src.node_n] else 0;
            const h_re = yp_re - yn_re;
            const h_im = yp_im - yn_im;
            const dens = (h_re * h_re + h_im * h_im) * psd;
            total_density += dens;
            if (per_source) |ps| ps.dens[k * noise_sources.len + i] = dens;

            const ln_dens = @log(@max(dens, n_minlog));
            if (band.del_freq != 0) {
                const part = nintegrate(dens, ln_dens, last.*, band);
                integrated += part;
                if (per_source) |ps| ps.out[i] += part;
            }
            last.* = ln_dens;

            if (options.in_branch != null) {
                const dens_in = dens / gain_sq;
                total_in_density += dens_in;
                const ln_dens_in = @log(@max(dens_in, n_minlog));
                if (band.del_freq != 0) {
                    const part = nintegrate(dens_in, ln_dens_in, @log(@max(last_dens.* / gain_sq, n_minlog)), band);
                    integrated_in += part;
                    if (per_source) |ps| ps.in[i] += part;
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
/// inoise_spectrum) or, with `opts.integrated`, one row of rms totals. With
/// `opts.contributions` each device instance adds its columns ahead of the
/// totals, as ngspice's `.noise ... pts` does: per generator name and per
/// instance, `onoise_<inst>_<gen>` and `onoise_<inst>` in the spectrum,
/// `v(onoise_total_<inst>_<gen>)`, `v(inoise_total_<inst>_<gen>)` and the
/// instance sums in the integrated plot.
/// The output density at each of `freqs` as a sampler at `s.fs` sees it:
/// the density at every |f + k fs| up to `s.max_fold * fs`, each weighted
/// by the integrator's sinc^2(pi g beta / fs), summed. Caller frees with
/// `gpa`.
fn sampled(ckt: *root.Circuit, x_op: []const f64, srcs: []const NoiseSource, freqs: []const f64, s: @import("core").query.NoiseSample, opts: Options, gpa: std.mem.Allocator) ![]f64 {
    const f_top = s.max_fold * s.fs;
    const k_max: i64 = @intFromFloat(@ceil(s.max_fold) + 1);
    var grid: std.ArrayList(f64) = .empty;
    defer grid.deinit(gpa);
    for (freqs) |f| {
        var k = -k_max;
        while (k <= k_max) : (k += 1) {
            const g = @abs(f + @as(f64, @floatFromInt(k)) * s.fs);
            if (g > 0 and g <= f_top) try grid.append(gpa, g);
        }
    }
    std.mem.sort(f64, grid.items, {}, std.sort.asc(f64));
    var unique: usize = 0;
    for (grid.items) |g| {
        if (unique != 0 and grid.items[unique - 1] == g) continue;
        grid.items[unique] = g;
        unique += 1;
    }
    const at = grid.items[0..unique];
    const work = try gpa.alloc(f64, 3 * unique);
    defer gpa.free(work);
    var o = opts;
    o.sweep = .{ .f_start = if (unique != 0) at[0] else 0, .f_stop = if (unique != 0) at[unique - 1] else 0, .points = @intCast(unique), .kind = .poi, .list = at };
    o.contributions = false;
    if (unique != 0) _ = try sweep(ckt, x_op, srcs, work[0..unique], work[unique..][0..unique], work[2 * unique ..], null, o, gpa);
    const out = try gpa.alloc(f64, freqs.len);
    for (freqs, out) |f, *total| {
        total.* = 0;
        var k = -k_max;
        while (k <= k_max) : (k += 1) {
            const g = @abs(f + @as(f64, @floatFromInt(k)) * s.fs);
            if (!(g > 0 and g <= f_top)) continue;
            const i = std.sort.lowerBound(f64, at, g, orderF64);
            const x = std.math.pi * g * s.beta / s.fs;
            const sinc = if (x == 0) 1 else @sin(x) / x;
            total.* += work[unique + i] * sinc * sinc;
        }
    }
    return out;
}

fn orderF64(a: f64, b: f64) std.math.Order {
    return std.math.order(a, b);
}

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

    var columns: Columns = .{};
    var per_source: ?PerSource = null;
    if (opts.contributions) {
        columns = try Columns.build(a, ctx.circuit, opts.cards, srcs.len);
        const ps = try a.alloc(f64, srcs.len * (@as(usize, n_points) + 2));
        @memset(ps, 0);
        per_source = .{ .dens = ps[0 .. srcs.len * n_points], .out = ps[srcs.len * n_points ..][0..srcs.len], .in = ps[srcs.len * (n_points + 1) ..] };
    }

    const integrated = try sweep(ctx.circuit, x_op, srcs, freqs, density, in_density, per_source, opts, scratch);

    // ngspice's two noise plots, with ngspice's names and units: the curves
    // are amplitude spectra (V/sqrt(Hz)) and the totals are V rms. `inoise`
    // is the same noise referred to the input source's terminals.
    const n_cols = columns.labels.len;
    if (opts.integrated) {
        const names = try a.alloc([]const u8, 2 * n_cols + 2);
        const data = try a.alloc(f64, names.len);
        if (per_source) |ps| {
            const sums = try scratch.alloc(f64, 2 * n_cols);
            defer scratch.free(sums);
            @memset(sums, 0);
            columns.sum(ps.out, sums[0..n_cols]);
            columns.sum(ps.in, sums[n_cols..]);
            for (columns.labels, 0..) |label, c| {
                names[2 * c] = try std.fmt.allocPrint(a, "v(onoise_total_{s})", .{label});
                names[2 * c + 1] = try std.fmt.allocPrint(a, "v(inoise_total_{s})", .{label});
                data[2 * c] = @sqrt(sums[c]);
                data[2 * c + 1] = @sqrt(sums[n_cols + c]);
            }
        }
        names[2 * n_cols] = "v(onoise_total)";
        names[2 * n_cols + 1] = "v(inoise_total)";
        data[2 * n_cols] = @sqrt(integrated.onoise);
        data[2 * n_cols + 1] = @sqrt(integrated.inoise);
        return .{
            .plotname = "Integrated Noise",
            .varnames = names,
            .is_complex = false,
            .npoints = 1,
            .data = data,
        };
    }

    const folded = if (opts.sample) |s| try sampled(ctx.circuit, x_op, srcs, freqs, s, opts, scratch) else null;
    defer if (folded) |f| scratch.free(f);
    const extra: usize = @intFromBool(folded != null);
    const width = n_cols + 3 + extra;
    const names = try a.alloc([]const u8, width);
    names[0] = "frequency";
    for (columns.labels, names[1 .. 1 + n_cols]) |label, *name| name.* = try std.fmt.allocPrint(a, "onoise_{s}", .{label});
    names[n_cols + 1] = "onoise_spectrum";
    names[n_cols + 2] = "inoise_spectrum";
    if (folded != null) names[width - 1] = "onoise_sampled";
    const data = try a.alloc(f64, @as(usize, n_points) * width);
    for (0..n_points) |i| {
        const row = data[i * width ..][0..width];
        row[0] = freqs[i];
        const cols = row[1 .. 1 + n_cols];
        if (per_source) |ps| {
            @memset(cols, 0);
            columns.sum(ps.dens[i * srcs.len ..][0..srcs.len], cols);
            for (cols) |*v| v.* = @sqrt(v.*);
        }
        row[n_cols + 1] = @sqrt(density[i]);
        row[n_cols + 2] = @sqrt(in_density[i]);
        if (folded) |f| row[width - 1] = @sqrt(f[i]);
    }

    return .{
        .plotname = "Noise Spectral Density Curves",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}

/// The contribution columns and where each noise source lands in them.
/// Generators of one instance that share a name (LRM §4.6.4 `name`) share a
/// column; each instance's total column follows its generator columns.
const Columns = struct {
    /// `<inst>_<gen>` or `<inst>`, in column order.
    labels: []const []const u8 = &.{},
    /// Per source, in `collectNoiseSources` order: its generator column and
    /// its instance's total column.
    gen: []const u32 = &.{},
    total: []const u32 = &.{},

    /// Labels the `n_sources` generators `collectNoiseSources` yields, batch
    /// by batch and instance by instance, from each batch's `noise_names`
    /// and the card names in `cards`. `error.NoiseLabelMismatch` when the
    /// batches' generator counts do not add up to `n_sources`.
    fn build(a: std.mem.Allocator, ckt: *const root.Circuit, cards: []const root.CardRef, n_sources: usize) !Columns {
        var labels: std.ArrayList([]const u8) = .empty;
        const map = try a.alloc(u32, 2 * n_sources);
        const gen = map[0..n_sources];
        const total = map[n_sources..];
        var s: usize = 0;
        for (ckt.batches, ckt.batch_types) |b, t| {
            if (b.hooks.collect_noise == null) continue;
            const gens = b.hooks.noise_names;
            if (s + b.count * gens.len > n_sources) return error.NoiseLabelMismatch;
            for (0..b.count) |id| {
                if (gens.len == 0) break;
                const inst = root.CardRef.lookup(cards, t, @intCast(id)) orelse
                    try std.fmt.allocPrint(a, "{s}#{d}", .{ b.type_name, id });
                const first = labels.items.len;
                for (gens, 0..) |name, k| {
                    const label = if (name.len == 0)
                        try std.fmt.allocPrint(a, "{s}_{d}", .{ inst, k })
                    else
                        try std.fmt.allocPrint(a, "{s}_{s}", .{ inst, name });
                    gen[s + k] = for (labels.items[first..], first..) |seen, c| {
                        if (std.mem.eql(u8, seen, label)) break @intCast(c);
                    } else blk: {
                        try labels.append(a, label);
                        break :blk @intCast(labels.items.len - 1);
                    };
                }
                @memset(total[s..][0..gens.len], @intCast(labels.items.len));
                try labels.append(a, inst);
                s += gens.len;
            }
        }
        if (s != n_sources) return error.NoiseLabelMismatch;
        return .{ .labels = labels.items, .gen = gen, .total = total };
    }

    /// Adds each per-source value into its generator and instance columns.
    fn sum(self: Columns, per_source: []const f64, cols: []f64) void {
        for (per_source, self.gen, self.total) |v, g, t| {
            cols[g] += v;
            cols[t] += v;
        }
    }
};

/// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .Band = Band,
    .nintegrate = nintegrate,
    .sourcePsd = sourcePsd,
} else {};
