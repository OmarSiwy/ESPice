//! Fourier (.four): transient steady-state harmonic decomposition. Extract
//! one fundamental period from the end of a transient waveform, resample to
//! a power of 2, FFT, and read off harmonic magnitudes, phases, and THD.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const fft_mod = @import("solvers").fft;
const tran = @import("../tran/tran.zig");

const math = std.math;

pub const Harmonic = struct {
    mag: f64,
    phase_deg: f64,
};

pub const Options = @import("requests").Four;

pub const Spectrum = struct {
    dc: f64,
    fundamental: f64,
    harmonics: [9]Harmonic,
    thd_percent: f64,
};

/// Run Fourier analysis on a transient waveform captured in a Waveform struct.
/// Extracts one period from the end (steady-state), resamples to power-of-2,
/// applies FFT, and computes harmonic magnitudes, phases, and THD.
pub fn analyze(waveform: *const tran.Waveform, probe_idx: u32, f_fund: f64, allocator: std.mem.Allocator) !Spectrum {
    const times = waveform.timeSlice();
    const values = waveform.probeValues(probe_idx);

    if (times.len < 2) return error.InsufficientData;

    const period = 1.0 / f_fund;
    const t_end = times[times.len - 1];
    const t_start = t_end - period;

    if (t_start < times[0]) return error.InsufficientData;

    // Binary search for the first sample index at or after t_start
    const start_idx = bsearchGe(times, t_start);

    const raw_count = times.len - start_idx;
    if (raw_count < 2) return error.InsufficientData;

    // Resample to next power of 2 via linear interpolation
    const n_fft = fft_mod.nextPow2(raw_count);
    const n_fft_f: f64 = @floatFromInt(n_fft);

    const re = try allocator.alloc(f64, n_fft);
    defer allocator.free(re);
    const im = try allocator.alloc(f64, n_fft);
    defer allocator.free(im);

    // Linearly interpolate raw_count samples onto n_fft uniform points in [t_start, t_end)
    const win_times = times[start_idx..];
    const win_vals = values[start_idx..];
    // Targets increase monotonically, so one cursor walks the window forward
    // instead of restarting a binary search per sample: O(window + n_fft).
    var cursor: usize = 0;
    for (0..n_fft) |k| {
        const t_target = t_start + period * @as(f64, @floatFromInt(k)) / n_fft_f;
        re[k] = interpolateAt(win_times, win_vals, t_target, &cursor);
    }

    root.zeroSimd(im);

    fft_mod.fft(re, im);

    return extractSpectrum(re, im, n_fft);
}

/// Fourier analysis from pre-computed uniform samples (no transient sim needed).
/// `samples` are uniformly spaced over exactly one period of the fundamental.
pub fn analyzeBuffer(samples: []const f64, allocator: std.mem.Allocator) !Spectrum {
    if (samples.len < 2) return error.InsufficientData;

    const n_fft = fft_mod.nextPow2(samples.len);
    const n_fft_f: f64 = @floatFromInt(n_fft);
    const n_in_f: f64 = @floatFromInt(samples.len);

    const re = try allocator.alloc(f64, n_fft);
    defer allocator.free(re);
    const im = try allocator.alloc(f64, n_fft);
    defer allocator.free(im);

    // Resample input to n_fft points via linear interpolation
    for (0..n_fft) |k| {
        const frac = @as(f64, @floatFromInt(k)) / n_fft_f * n_in_f;
        const idx_lo: usize = @intFromFloat(@floor(frac));
        const idx_hi = if (idx_lo + 1 < samples.len) idx_lo + 1 else idx_lo;
        const alpha = frac - @as(f64, @floatFromInt(idx_lo));
        re[k] = samples[idx_lo] * (1.0 - alpha) + samples[idx_hi] * alpha;
    }

    root.zeroSimd(im);

    fft_mod.fft(re, im);

    return extractSpectrum(re, im, n_fft);
}

/// Contract entry: transient from the operating point, then the harmonic
/// table — one row per harmonic (row 0 is DC), columns
/// (harmonic, frequency, magnitude, phase_deg). THD lands in the plotname.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    // `defer`-freed == scratch, and `a` is a results arena that cannot reclaim
    // it — the waveform below is a whole transient. `Spectrum` is a value
    // type and `analyze` frees its own FFT buffers, so it is scratch too.
    const scratch = ctx.scratch_allocator orelse a;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const x = try scratch.dupe(f64, x_op);
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

        break :blk try analyze(&waveform, 0, opts.f_fundamental, scratch);
    };

    const n_harm: usize = @min(opts.n_harmonics, spec.harmonics.len);
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

// ============================================================================
// Internals
// ============================================================================

/// Binary search: return index of first element >= target.
fn bsearchGe(times: []const f64, target: f64) usize {
    var lo: usize = 0;
    var hi: usize = times.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (times[mid] < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn extractSpectrum(re: []const f64, im: []const f64, n_fft: usize) Spectrum {
    const n_f: f64 = @floatFromInt(n_fft);
    const scale = 2.0 / n_f;

    // DC component (bin 0): no factor-of-2
    const dc = re[0] / n_f;

    // Fundamental (bin 1)
    const fund_mag = @sqrt(re[1] * re[1] + im[1] * im[1]) * scale;

    var harmonics: [9]Harmonic = undefined;
    // Harmonic 1 = fundamental
    // fft convention: X[1] = (N*A/2)*e^{+j*phi} for A*cos(2*pi*f0*t + phi), so the
    // phase is +atan2 — no negation.
    harmonics[0] = .{
        .mag = fund_mag,
        .phase_deg = math.radiansToDegrees(math.atan2(im[1], re[1])),
    };

    // Harmonics 2..9
    var thd_sum_sq: f64 = 0;
    for (1..9) |h| {
        const bin = h + 1; // harmonic number = h+1, bin index = h+1
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
        .thd_percent = thd_percent,
    };
}

/// Linear interpolation on sorted time/value arrays, advancing `cursor` to the
/// bracketing index instead of searching for it. Callers must pass targets in
/// non-decreasing order; `interpolate` below is the binary-search oracle this
/// agrees with element for element (see the differential test).
fn interpolateAt(times: []const f64, values: []const f64, t: f64, cursor: *usize) f64 {
    if (times.len == 0) return 0;
    if (t <= times[0]) return values[0];
    if (t >= times[times.len - 1]) return values[values.len - 1];

    // Both searches land on lo = max{i : times[i] <= t}, capped at len-2.
    var lo = cursor.*;
    while (lo + 2 < times.len and times[lo + 1] <= t) lo += 1;
    cursor.* = lo;
    const hi = lo + 1;

    const dt = times[hi] - times[lo];
    if (dt < 1e-30) return values[lo];
    const alpha = (t - times[lo]) / dt;
    return values[lo] * (1.0 - alpha) + values[hi] * alpha;
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .interpolateAt = interpolateAt,
} else {};
