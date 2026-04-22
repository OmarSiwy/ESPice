//! Fourier analysis (`.four`): the harmonic content of a transient's steady
//! state. Takes the last fundamental period of the waveform, resamples it to
//! a power of two, and reads magnitudes, phases and THD off the FFT.
const std = @import("std");
const root = @import("../types.zig");
const fft_mod = @import("solver").fft;
const tran = @import("../tran/tran.zig");

const math = std.math;

/// One harmonic: sinusoid amplitude and phase in degrees (cosine reference).
pub const Harmonic = struct {
    mag: f64,
    phase_deg: f64,
};

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Four;

/// ngspice prints nine harmonics by default and a deck may ask for more
/// (`.four 1k v(out) 16`). The table is fixed-size because a Spectrum is
/// returned by value; a slice into scratch would dangle.
const max_harmonics = Options.max_harmonics;

/// The harmonic content of one period, amplitudes in the probe's units.
pub const Spectrum = struct {
    /// Mean over the period.
    dc: f64,
    /// Amplitude of harmonic 1, the THD denominator.
    fundamental: f64,
    /// harmonics[h] is harmonic h + 1; only the first `n_harmonics` are set.
    harmonics: [max_harmonics]Harmonic,
    n_harmonics: usize,
    /// Harmonics 2..n_harmonics against the fundamental, as ngspice counts it.
    thd_percent: f64,
};

/// Spectrum of probe `probe_idx` over the last period of `waveform`.
/// `n_harmonics` is clamped to 1..max_harmonics. Returns
/// error.InsufficientData when the waveform is shorter than one period or the
/// period holds fewer than two samples.
pub fn analyze(waveform: *const tran.Waveform, probe_idx: u32, f_fund: f64, n_harmonics: usize, allocator: std.mem.Allocator) !Spectrum {
    const times = waveform.timeSlice();
    const values = waveform.probeValues(probe_idx);

    if (times.len < 2) return error.InsufficientData;

    const period = 1.0 / f_fund;
    const t_end = times[times.len - 1];
    const t_start = t_end - period;

    if (t_start < times[0]) return error.InsufficientData;

    const start_idx = std.sort.partitionPoint(f64, times, t_start, struct {
        fn before(t: f64, time: f64) bool {
            return time < t;
        }
    }.before);

    const raw_count = times.len - start_idx;
    if (raw_count < 2) return error.InsufficientData;

    const n_fft = fft_mod.nextPow2(raw_count);
    const n_fft_f: f64 = @floatFromInt(n_fft);

    const re = try allocator.alloc(f64, n_fft);
    defer allocator.free(re);
    const im = try allocator.alloc(f64, n_fft);
    defer allocator.free(im);

    // n_fft uniform points on [t_start, t_end). The targets increase, so one
    // cursor walks the window forward: O(window + n_fft), no search per sample.
    const win_times = times[start_idx..];
    const win_vals = values[start_idx..];
    var cursor: usize = 0;
    for (0..n_fft) |k| {
        const t_target = t_start + period * @as(f64, @floatFromInt(k)) / n_fft_f;
        re[k] = interpolateAt(win_times, win_vals, t_target, &cursor);
    }

    root.zeroSimd(im);

    fft_mod.fft(re, im);

    return extractSpectrum(re, im, n_fft, n_harmonics);
}

/// Contract entry: a transient from the operating point (opts.tran_opts, or
/// five periods at 200 steps per period), then the harmonic table. Real, one
/// row per harmonic with row 0 the DC term, columns
/// (harmonic, frequency, magnitude, phase_deg). The THD goes in the plotname.
/// Returns error.TransientFailed when the transient stops early.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;

    const x = try scratch.dupe(f64, ctx.x_op);
    defer scratch.free(x);

    const tran_opts = opts.tran_opts orelse tran.Options{
        .t_stop = 5.0 / opts.f_fundamental,
        .dt_init = 1.0 / (200.0 * opts.f_fundamental),
        .dt_max = 1.0 / (200.0 * opts.f_fundamental),
    };

    const spec = blk: {
        const probes = [_]u32{opts.output_node};
        var waveform = try tran.Waveform.init(scratch, 1, tran.initialCapacity(tran_opts));
        defer waveform.deinit();

        const tran_result = try tran.simulate(ctx.circuit, x, &probes, &waveform, tran_opts, scratch);
        if (!tran_result.completed) return error.TransientFailed;

        break :blk try analyze(&waveform, 0, opts.f_fundamental, opts.n_harmonics, scratch);
    };

    const n_harm: usize = spec.n_harmonics;
    const npoints = 1 + n_harm;
    const names = try a.dupe([]const u8, &.{ "harmonic", "frequency", "magnitude", "phase_deg" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, npoints * 4);
    data[0..4].* = .{ 0, 0, spec.dc, 0 };
    for (0..n_harm) |h| {
        const k: f64 = @floatFromInt(h + 1);
        data[(h + 1) * 4 ..][0..4].* = .{
            k,
            k * opts.f_fundamental,
            spec.harmonics[h].mag,
            spec.harmonics[h].phase_deg,
        };
    }

    return .{
        .plotname = try std.fmt.allocPrint(a, "Fourier Analysis (THD = {d:.4} %)", .{spec.thd_percent}),
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

/// Reads the spectrum off an `n_fft`-point FFT of exactly one period. A
/// harmonic at or past Nyquist reads as zero.
fn extractSpectrum(re: []const f64, im: []const f64, n_fft: usize, n_harmonics: usize) Spectrum {
    const n_f: f64 = @floatFromInt(n_fft);
    const scale = 2.0 / n_f;

    // Bin 0 is the mean; it has no factor of two.
    const dc = re[0] / n_f;
    const fund_mag = @sqrt(re[1] * re[1] + im[1] * im[1]) * scale;

    const n_harm = std.math.clamp(n_harmonics, 1, max_harmonics);
    var harmonics: [max_harmonics]Harmonic = undefined;
    // The FFT gives X[1] = (N*A/2)·e^{+j·phi} for A·cos(2π·f0·t + phi), so
    // the phase is +atan2 with no negation.
    harmonics[0] = .{
        .mag = fund_mag,
        .phase_deg = math.radiansToDegrees(math.atan2(im[1], re[1])),
    };

    // Harmonic h + 1 sits in bin h + 1. The THD numerator is every harmonic
    // the deck asked to see, as ngspice's is.
    var thd_sum_sq: f64 = 0;
    for (1..n_harm) |h| {
        const bin = h + 1;
        if (bin >= n_fft / 2) {
            harmonics[h] = .{ .mag = 0, .phase_deg = 0 };
            continue;
        }
        const mag = @sqrt(re[bin] * re[bin] + im[bin] * im[bin]) * scale;
        const phase = math.radiansToDegrees(math.atan2(im[bin], re[bin]));
        harmonics[h] = .{ .mag = mag, .phase_deg = phase };
        thd_sum_sq += mag * mag;
    }

    const thd_percent = if (fund_mag > 1e-30) @sqrt(thd_sum_sq) / fund_mag * 100.0 else 0;

    return .{
        .dc = dc,
        .fundamental = fund_mag,
        .harmonics = harmonics,
        .n_harmonics = n_harm,
        .thd_percent = thd_percent,
    };
}

/// Linear interpolation of `values` at `t` on sorted `times`, advancing
/// `cursor` to the bracketing index instead of searching for it. Targets must
/// come in non-decreasing order. tests/four.zig checks it element for element
/// against a binary-search oracle.
fn interpolateAt(times: []const f64, values: []const f64, t: f64, cursor: *usize) f64 {
    if (times.len == 0) return 0;
    if (t <= times[0]) return values[0];
    if (t >= times[times.len - 1]) return values[values.len - 1];

    // Lands on lo = max{i : times[i] <= t}, capped at len - 2, as the binary
    // search does.
    var lo = cursor.*;
    while (lo + 2 < times.len and times[lo + 1] <= t) lo += 1;
    cursor.* = lo;
    const hi = lo + 1;

    const dt = times[hi] - times[lo];
    if (dt < 1e-30) return values[lo];
    const alpha = (t - times[lo]) / dt;
    return values[lo] * (1.0 - alpha) + values[hi] * alpha;
}

/// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .extractSpectrum = extractSpectrum,
    .interpolateAt = interpolateAt,
} else {};
