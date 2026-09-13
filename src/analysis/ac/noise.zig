//! Small-signal noise, adjoint method: one transpose solve per frequency
//! (A^H y = e_out), then every source is a dot product -- O(solves) went from
//! points*sources to points. Source conductances come off the analytic
//! Jacobian (root.Circuit.collectNoiseSources), no perturbation -- devices
//! carry builtin noise generators, analyses never re-derive them.
//!
//! Supports thermal (4kTg), shot (2q|I|), and flicker (KF*|I|^AF/f) PSD.
//!
//! ngspice equivalence, src/spicelib/analysis/ (44.2):
//!   * nevalsrc.c:100-119 -- one generator contributes
//!     |Vadj(p) - Vadj(n)|^2 * PSD, PSD = 4kT*g (THERMNOISE) or 2q|I| (SHOT).
//!   * noisean.c:423-430 -- the ORDINARY ac solve, driven by the `.noise`
//!     input source, gives |H|^2; the input-referred spectrum is onoise/|H|^2,
//!     floored at N_MINGAIN.
//!   * ninteg.c -- the band integral is a per-interval power-law fit of the
//!     log-log spectrum, taken PER SOURCE (resnoise.c:139-161), not a trapezoid
//!     of the total. The first point only seeds the history (delFreq == 0).
//!   * cktnoise.c:56-64, :76-82 and noisean.c:318-325, :516-522 -- two plots:
//!     "Noise Spectral Density Curves" (frequency, onoise_spectrum,
//!     inoise_spectrum) and "Integrated Noise" (onoise_total, inoise_total,
//!     one point, no scale). The second only when the band is non-degenerate.
//!   * cktnoise.c:110-113, :123-126 -- the raw carries the SQUARE ROOT of
//!     every onoise*/inoise* column unless `set sqrnoise`, so the default units
//!     are V/sqrt(Hz) and V rms. Everything below `run` here is squared, like
//!     ngspice's `Ndata`; `run` takes the sqrt at the same boundary ngspice
//!     does.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("solvers").types;
const FreqSolver = @import("solvers").freq_solve.FreqSolver;

const k_boltzmann = 1.380649e-23;
const q_electron = 1.602176634e-19;

// ngspice include/ngspice/noisedef.h:105-113.
const n_minlog = 1e-38;
const n_mingain = 1e-20;
const n_intfthresh = 1e-10;
const n_intuselog = 1e-10;

pub const NoiseSource = root.NoiseSource;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    out_node: u32,
    /// MNA branch row of the `.noise` card's input source (its second
    /// argument). ngspice noisean.c:89/416 keys the input-referred spectrum on
    /// THAT card, never on the deck's first source. GROUND = unknown, and then
    /// inoise mirrors onoise (unit gain) rather than inventing one.
    in_branch: u32 = root.GROUND,
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
    temp_k: f64 = 27.0 + 273.15,
    /// Emit ngspice's SECOND plot -- "Integrated Noise", the band integrals
    /// (noisean.c:495-528) -- instead of the per-frequency spectrum. One `.noise`
    /// card queues one job of each; see engine.zig.
    integrated: bool = false,
};

/// Band integrals over the whole sweep: ngspice `data->outNoiz` /
/// `data->inNoise`, squared units (V^2 and input-unit^2).
pub const Totals = struct { onoise: f64 = 0, inoise: f64 = 0 };

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

/// Compute PSD for a single noise source at frequency f.
///   thermal: S(f) = 4 * k_B * T * g          (white)
///   shot:    S(f) = 2 * q * |I|              (white)
///   flicker: S(f) = KF * |I|^AF / f          (1/f)
inline fn sourcePsd(src: NoiseSource, f: f64, temp_k: f64) f64 {
    return switch (src.kind) {
        .thermal => 4.0 * k_boltzmann * temp_k * src.conductance,
        .shot => 2.0 * q_electron * @abs(src.current),
        .flicker => if (f > 0)
            src.kf * std.math.pow(f64, @abs(src.current), src.af) / f
        else
            0,
    };
}

/// Fine-grained primitive: sweep into caller-owned freqs/onoise/inoise buffers
/// (all logSweepCount long), in SQUARED units (V^2/Hz). Returns the two band
/// integrals, also squared. `run` is the only place the sqrt happens.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    onoise: []f64,
    inoise: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Totals {
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points = freqs.len;
    std.debug.assert(onoise.len == n_points and inoise.len == n_points);

    // Adjoint: A^H y = e_out per omega (conjugate drops out of |H|^2, so the
    // stacked-real transpose solve suffices). One shared rhs, lane = frequency:
    // GPU batch adjoint dispatch orelse the CPU lane solveBatch(adjoint=true).
    // PSD accumulation stays CPU (cheap).
    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const omegas = try allocator.alloc(f64, n_points);
    defer allocator.free(omegas);
    types.fillLogSweep(options.f_start, options.f_stop, options.points_per_decade, freqs, omegas);

    // RHS: unit excitation at out_node (stacked-real, length 2n).
    const e = try allocator.alloc(f64, nn);
    defer allocator.free(e);
    root.zeroSimd(e);
    e[options.out_node] = 1.0;

    const y_lanes = ckt.gpuFreqBatch(allocator, ckt.g_vals, ckt.c_vals, omegas, e, @intCast(n), true) orelse blk: {
        const cpu = try allocator.alloc(f64, n_points * nn);
        try fs.solveBatch(allocator, omegas, e, cpu, true);
        break :blk cpu;
    };
    defer allocator.free(y_lanes);

    // Forward: the ORDINARY ac system driven by the `.noise` input source
    // (noisean.c:423-427). Unit magnitude, matching ac.zig's contract entry --
    // ngspice reads the card's own AC value and refuses a card without one
    // (noisean.c:144-149).
    var h_lanes: []f64 = &.{};
    defer if (h_lanes.len != 0) allocator.free(h_lanes);
    if (options.in_branch != root.GROUND) {
        root.zeroSimd(e);
        e[options.in_branch] = 1.0;
        h_lanes = ckt.gpuFreqBatch(allocator, ckt.g_vals, ckt.c_vals, omegas, e, @intCast(n), false) orelse blk: {
            const cpu = try allocator.alloc(f64, n_points * nn);
            try fs.solveBatch(allocator, omegas, e, cpu, false);
            break :blk cpu;
        };
    }

    // ln of each source's density at the previous point -- ngspice's
    // `nVar[LNLSTDENS][i]`, the other half of the per-source fit.
    const ln_last = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(ln_last);

    var totals: Totals = .{};
    // noisean.c:376 `data->lstFreq = data->freq` BEFORE the loop: the first
    // point has delFreq == 0 and contributes nothing but history.
    var prev_freq: f64 = if (n_points != 0) freqs[0] else 0;
    for (0..n_points) |k| {
        const f = freqs[k];
        const y = y_lanes[k * nn ..][0..nn];

        // GainSqInv = 1 / max(|H|^2, N_MINGAIN)  (noisean.c:428-430).
        var gain_sq_inv: f64 = 1.0;
        if (h_lanes.len != 0) {
            const h = h_lanes[k * nn ..][0..nn];
            const hr = h[options.out_node];
            const hi = h[n + options.out_node];
            gain_sq_inv = 1.0 / @max(hr * hr + hi * hi, n_mingain);
        }
        const ln_gain_inv = @log(gain_sq_inv);

        const band: Band = .{
            .del_freq = f - prev_freq,
            .ln_freq = @log(@max(f, n_minlog)),
            .ln_last_freq = @log(@max(prev_freq, n_minlog)),
            .del_ln_freq = @log(@max(f, n_minlog)) - @log(@max(prev_freq, n_minlog)),
        };

        var total_density: f64 = 0;
        for (noise_sources, ln_last) |src, *last| {
            const psd = sourcePsd(src, f, options.temp_k);
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
                // resnoise.c:143-150 -- note that BOTH the current and the
                // stored density are shifted by the CURRENT point's gain.
                totals.onoise += nintegrate(dens, ln_dens, last.*, band);
                totals.inoise += nintegrate(dens * gain_sq_inv, ln_dens + ln_gain_inv, last.* + ln_gain_inv, band);
            }
            last.* = ln_dens;
        }

        onoise[k] = total_density;
        inoise[k] = total_density * gain_sq_inv;
        prev_freq = f;
    }

    return totals;
}

/// Contract entry: sources off the analytic Jacobian (builtin device noise via
/// collectNoiseSources -- never re-derived per resistor), adjoint sweep, and
/// whichever of ngspice's two noise plots `opts.integrated` selects. Values are
/// square-rooted here and only here (cktnoise.c:110-113): V/sqrt(Hz) for the
/// spectrum, V rms for the totals.
///
/// ponytail: the integrated job re-runs the sweep rather than memoizing the
/// spectral job's totals. `.noise` is not on any perf fixture; memoize through
/// RunCtx the day one lands.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const srcs = try ctx.circuit.collectNoiseSources(x_op, a);
    defer a.free(srcs);

    const n_points = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const work = try a.alloc(f64, @as(usize, n_points) * 3);
    defer a.free(work);
    const freqs = work[0..n_points];
    const onoise = work[n_points .. 2 * n_points];
    const inoise = work[2 * n_points ..];

    const totals = try sweep(ctx.circuit, x_op, srcs, freqs, onoise, inoise, opts, a);

    if (opts.integrated) {
        // ngspice declares these SV_VOLTAGE (noisean.c:507-508), and its raw
        // writer decorates a voltage with `v(...)`; the spectrum's
        // SV_VOLTAGE_DENSITY is left bare. Both spellings are literal.
        const names = try a.dupe([]const u8, &.{ "v(onoise_total)", "v(inoise_total)" });
        errdefer a.free(names); // entries are literals
        const data = try a.alloc(f64, 2);
        data[0] = @sqrt(totals.onoise);
        data[1] = @sqrt(totals.inoise);
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
        data[i * 3 + 1] = @sqrt(onoise[i]);
        data[i * 3 + 2] = @sqrt(inoise[i]);
    }

    return .{
        .plotname = "Noise Spectral Density Curves",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "sourcePsd thermal" {
    const src: NoiseSource = .{
        .node_p = 0,
        .node_n = 1,
        .kind = .thermal,
        .conductance = 0.01, // 100 ohm resistor
    };
    const psd = sourcePsd(src, 1e6, 300.15);
    const expected = 4.0 * k_boltzmann * 300.15 * 0.01;
    try std.testing.expectApproxEqRel(expected, psd, 1e-12);
    // White: same PSD at different frequency
    const psd2 = sourcePsd(src, 1e9, 300.15);
    try std.testing.expectApproxEqRel(psd, psd2, 1e-12);
}

test "sourcePsd shot" {
    const src: NoiseSource = .{
        .node_p = 0,
        .node_n = 1,
        .kind = .shot,
        .conductance = 0,
        .current = 1e-3,
    };
    const psd = sourcePsd(src, 1e6, 300.15);
    const expected = 2.0 * q_electron * 1e-3;
    try std.testing.expectApproxEqRel(expected, psd, 1e-12);
    // White: frequency-independent
    const psd2 = sourcePsd(src, 1e9, 300.15);
    try std.testing.expectApproxEqRel(psd, psd2, 1e-12);
    // Negative current → same magnitude
    const src_neg: NoiseSource = .{
        .node_p = 0,
        .node_n = 1,
        .kind = .shot,
        .conductance = 0,
        .current = -1e-3,
    };
    const psd_neg = sourcePsd(src_neg, 1e6, 300.15);
    try std.testing.expectApproxEqRel(psd, psd_neg, 1e-12);
}

test "sourcePsd flicker" {
    const kf = 1e-24;
    const af = 1.0;
    const i_bias = 1e-3;
    const src: NoiseSource = .{
        .node_p = 0,
        .node_n = 1,
        .kind = .flicker,
        .conductance = 0,
        .current = i_bias,
        .kf = kf,
        .af = af,
    };
    // At 1 kHz: KF * |I|^AF / f = 1e-24 * 1e-3 / 1e3 = 1e-30
    const psd_1k = sourcePsd(src, 1e3, 300.15);
    const expected_1k = kf * std.math.pow(f64, i_bias, af) / 1e3;
    try std.testing.expectApproxEqRel(expected_1k, psd_1k, 1e-12);
    // At 10 kHz: should be 10x smaller (1/f)
    const psd_10k = sourcePsd(src, 1e4, 300.15);
    try std.testing.expectApproxEqRel(psd_1k / 10.0, psd_10k, 1e-12);
    // At f=0: returns 0 (guard against division by zero)
    const psd_0 = sourcePsd(src, 0, 300.15);
    try std.testing.expectEqual(@as(f64, 0), psd_0);
}

test "sourcePsd flicker af exponent" {
    const src: NoiseSource = .{
        .node_p = 0,
        .node_n = 1,
        .kind = .flicker,
        .conductance = 0,
        .current = 2e-3,
        .kf = 1e-24,
        .af = 2.0,
    };
    const psd = sourcePsd(src, 1e3, 300.15);
    // KF * |I|^AF / f = 1e-24 * (2e-3)^2 / 1e3 = 1e-24 * 4e-6 / 1e3 = 4e-33
    const expected = 1e-24 * std.math.pow(f64, 2e-3, 2.0) / 1e3;
    try std.testing.expectApproxEqRel(expected, psd, 1e-12);
}

test "sourcePsd defaults backward compatible" {
    // Default-initialized NoiseSource should behave as thermal
    const src: NoiseSource = .{
        .node_p = 0,
        .node_n = 1,
        .conductance = 0.02,
    };
    const psd = sourcePsd(src, 1e6, 300.15);
    const expected = 4.0 * k_boltzmann * 300.15 * 0.02;
    try std.testing.expectApproxEqRel(expected, psd, 1e-12);
}

test "nintegrate reproduces ngspice's three branches analytically" {
    const f0: f64 = 1e3;
    const f1: f64 = 1e4;
    const b: Band = .{
        .del_freq = f1 - f0,
        .ln_freq = @log(f1),
        .ln_last_freq = @log(f0),
        .del_ln_freq = @log(f1) - @log(f0),
    };

    // Flat spectrum -> |exponent| < N_INTFTHRESH -> the rectangle rule.
    const s: f64 = 3e-17;
    try std.testing.expectApproxEqRel(s * (f1 - f0), nintegrate(s, @log(s), @log(s), b), 1e-12);

    // S = a/f (exponent -1) -> the logarithmic branch, integral a*ln(f1/f0).
    const a: f64 = 1e-14;
    try std.testing.expectApproxEqRel(
        a * @log(f1 / f0),
        nintegrate(a / f1, @log(a / f1), @log(a / f0), b),
        1e-9,
    );

    // S = c*f^2 -> the general branch, integral c*(f1^3 - f0^3)/3.
    const c: f64 = 2e-24;
    try std.testing.expectApproxEqRel(
        c * (f1 * f1 * f1 - f0 * f0 * f0) / 3.0,
        nintegrate(c * f1 * f1, @log(c * f1 * f1), @log(c * f0 * f0), b),
        1e-9,
    );
}
