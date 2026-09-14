//! Small-signal noise, adjoint method: one transpose solve per frequency
//! (A^H y = e_out), then every source is a dot product -- O(solves) went from
//! points*sources to points. Source PSDs come from the DEVICE
//! (root.Circuit.collectNoiseSources -> the model's own `noisePsd`), never
//! re-derived here: a PSD is a model expression over the bias and the model
//! card, and 4kT*|dI/dV| off the Jacobian is a different number.
//!
//! Each source is `S(f) = white + flicker/f^ef`, which covers thermal
//! (white = 4kTg), shot (white = 2q|I|) and flicker (KF*|I|^AF, ef = EF).
//!
//! ngspice equivalence, src/spicelib/analysis/ (44.2):
//!   * nevalsrc.c:99-117 -- one generator contributes
//!     |Vadj(p) - Vadj(n)|^2 * PSD, PSD = 4kT*g (THERMNOISE, :111) or 2q|I|
//!     (SHOTNOISE, :106), or bare |H|^2 (N_GAIN, :116) for the 1/f sources the
//!     device scales itself.
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

/// One source's PSD at frequency `f`: `S(f) = white + flicker / f^ef`.
///
/// The DEVICE computed both halves (`noisePsd`); adding the 1/f shape is the
/// only thing the analysis is entitled to do to them, and it is the same split
/// ngspice makes. The white half is `NevalSrc`'s single multiply
/// (nevalsrc.c:105-113 — SHOTNOISE `2q|I|` and THERMNOISE `4kTg` land in the
/// same `*noise` and are indistinguishable downstream); the 1/f half is the
/// `N_GAIN` call every device follows with its OWN coefficient —
/// `KF·|I|^AF/f` (dionoise.c:99-104, bjtnoise.c:112-118, both EF = 1) or
/// `…/f^EF` (mos1noi.c:175-181, nlev 2/3 — the ONLY ngspice branch where the
/// frequency exponent is a parameter, and the reason `ef` is a field).
inline fn sourcePsd(src: NoiseSource, f: f64) f64 {
    if (src.flicker == 0 or f <= 0) return src.white;
    return src.white + src.flicker / std.math.pow(f64, f, src.ef);
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
    // `defer`-freed below == scratch, and `a` is a results arena that cannot
    // reclaim it. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const srcs = try ctx.circuit.collectNoiseSources(x_op, scratch);
    defer scratch.free(srcs);

    const n_points = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const work = try scratch.alloc(f64, @as(usize, n_points) * 3);
    defer scratch.free(work);
    const freqs = work[0..n_points];
    const onoise = work[n_points .. 2 * n_points];
    const inoise = work[2 * n_points ..];

    const totals = try sweep(ctx.circuit, x_op, srcs, freqs, onoise, inoise, opts, scratch);

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

test "sourcePsd white is flat" {
    // Thermal, 100 ohm: the device would have handed us 4kT*g.
    const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 4.0 * k_boltzmann * 300.15 * 0.01 };
    try std.testing.expectApproxEqRel(src.white, sourcePsd(src, 1e6), 1e-12);
    try std.testing.expectApproxEqRel(sourcePsd(src, 1e6), sourcePsd(src, 1e9), 1e-12);
}

test "sourcePsd shot is 2q|I|, not 4kT*g" {
    // THE 2x THIS BRANCH EXISTS TO FIX. A junction at I has g = dI/dV = I/Vt,
    // so the old Jacobian read gave 4kT*I/Vt = 4q*I -- exactly twice 2q*I.
    const i_bias = 1e-3;
    const vt = k_boltzmann * 300.15 / q_electron;
    const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 2.0 * q_electron * i_bias };
    try std.testing.expectApproxEqRel(2.0 * q_electron * i_bias, sourcePsd(src, 1e6), 1e-12);
    try std.testing.expectApproxEqRel(2.0, (4.0 * k_boltzmann * 300.15 * (i_bias / vt)) / src.white, 1e-12);
}

test "sourcePsd flicker rolls off as 1/f^ef" {
    // ngspice dionoise.c:99-104: KF*|I|^AF / f, EF = 1.
    const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .flicker = 1e-24 * 1e-3 };
    try std.testing.expectApproxEqRel(1e-27 / 1e3, sourcePsd(src, 1e3), 1e-12);
    try std.testing.expectApproxEqRel(sourcePsd(src, 1e3) / 10.0, sourcePsd(src, 1e4), 1e-12);
    // f = 0 cannot divide; the white half is still the answer.
    try std.testing.expectEqual(@as(f64, 0), sourcePsd(src, 0));

    // mos1noi.c:175-181 / BSIM4's `ef`: the exponent is not always 1.
    const ef2: NoiseSource = .{ .node_p = 0, .node_n = 1, .flicker = 4e-30, .ef = 1.4 };
    try std.testing.expectApproxEqRel(4e-30 / std.math.pow(f64, 1e3, 1.4), sourcePsd(ef2, 1e3), 1e-12);
}

test "sourcePsd sums both halves on one generator" {
    // §4.6.4: two `<+` lines on one branch are two generators, but one device
    // may also hand back a term with both halves set.
    const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 3e-17, .flicker = 1e-14 };
    try std.testing.expectApproxEqRel(3e-17 + 1e-14 / 1e3, sourcePsd(src, 1e3), 1e-12);
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
