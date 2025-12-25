//! Fourier (.four): transient steady-state harmonic decomposition. Extract
//! one fundamental period from the end of a transient waveform, resample to
//! a power of 2, FFT, and read off harmonic magnitudes, phases, and THD.
const std = @import("std");
const root = @import("root.zig");
const fft_mod = root.solvers.fft;
const tran = @import("tran.zig");

const math = std.math;

pub const Harmonic = struct {
    mag: f64,
    phase_deg: f64,
};

pub const Options = struct {
    f_fundamental: f64,
    n_harmonics: u16 = 9,
    output_node: u32 = 0,
    /// Transient window to analyze; defaults to 5 fundamental periods at
    /// 200 points/period (the old engine reused a queued .tran here).
    tran_opts: ?tran.Options = null,
};

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

    // Find the first sample index at or after t_start
    var start_idx: usize = 0;
    for (times, 0..) |t, idx| {
        if (t >= t_start) {
            start_idx = idx;
            break;
        }
    }

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
    for (0..n_fft) |k| {
        const t_target = t_start + period * @as(f64, @floatFromInt(k)) / n_fft_f;
        re[k] = interpolate(times[start_idx..], values[start_idx..], t_target);
        im[k] = 0;
    }

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
        im[k] = 0;
    }

    fft_mod.fft(re, im);

    return extractSpectrum(re, im, n_fft);
}

/// Fine-grained primitive: run transient simulation then perform Fourier
/// analysis on the result.
pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
    tran_opts: tran.Options,
    allocator: std.mem.Allocator,
) !Spectrum {
    const probes = [_]u32{options.output_node};
    var waveform = try tran.Waveform.init(allocator, 1, tran.initialCapacity(tran_opts));
    defer waveform.deinit();

    const tran_result = try tran.simulate(ckt, x, &probes, &waveform, tran_opts, allocator);
    if (!tran_result.completed) return error.TransientFailed;

    return analyze(&waveform, 0, options.f_fundamental, allocator);
}

/// Contract entry: transient from the operating point, then the harmonic
/// table — one row per harmonic (row 0 is DC), columns
/// (harmonic, frequency, magnitude, phase_deg). THD lands in the plotname.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const x = try a.dupe(f64, x_op);
    defer a.free(x);

    const tran_opts = opts.tran_opts orelse tran.Options{
        .t_stop = 5.0 / opts.f_fundamental,
        .dt_init = 1.0 / (200.0 * opts.f_fundamental),
    };

    const spec = try solve(ctx.circuit, x, opts, tran_opts, a);

    const n_harm: usize = @min(opts.n_harmonics, spec.harmonics.len);
    const npoints = 1 + n_harm;
    const names = try a.dupe([]const u8, &.{ "harmonic", "frequency", "magnitude", "phase_deg" });
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

fn extractSpectrum(re: []const f64, im: []const f64, n_fft: usize) Spectrum {
    const n_f: f64 = @floatFromInt(n_fft);
    const scale = 2.0 / n_f;

    // DC component (bin 0): no factor-of-2
    const dc = re[0] / n_f;

    // Fundamental (bin 1)
    const fund_mag = @sqrt(re[1] * re[1] + im[1] * im[1]) * scale;

    var harmonics: [9]Harmonic = undefined;
    // Harmonic 1 = fundamental
    // fft convention: X[1] = (N·A/2)·e^{+jφ} for A·cos(2πf₀t + φ), so the
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

fn interpolate(times: []const f64, values: []const f64, t: f64) f64 {
    // Binary search for the interval containing t
    if (times.len == 0) return 0;
    if (t <= times[0]) return values[0];
    if (t >= times[times.len - 1]) return values[values.len - 1];

    var lo: usize = 0;
    var hi: usize = times.len - 1;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (times[mid] <= t) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    const dt = times[hi] - times[lo];
    if (dt < 1e-30) return values[lo];
    const alpha = (t - times[lo]) / dt;
    return values[lo] * (1.0 - alpha) + values[hi] * alpha;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "four: pure cosine has zero THD" {
    const allocator = testing.allocator;
    const n = 256;
    var samples: [n]f64 = undefined;

    // One period of cos(2*pi*t/T), sampled at n points
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = @cos(2.0 * math.pi * t);
    }

    const result = try analyzeBuffer(&samples, allocator);

    try testing.expectApproxEqAbs(@as(f64, 0.0), result.dc, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.fundamental, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.thd_percent, 1e-6);
}

test "four: DC offset is reported correctly" {
    const allocator = testing.allocator;
    const n = 128;
    var samples: [n]f64 = undefined;

    const dc_offset = 3.5;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = dc_offset + @cos(2.0 * math.pi * t);
    }

    const result = try analyzeBuffer(&samples, allocator);

    try testing.expectApproxEqAbs(dc_offset, result.dc, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.fundamental, 1e-10);
}

test "four: square wave THD ~ 48.3%" {
    // A square wave with harmonics 1,3,5,7,... has
    // THD = sqrt(1/9 + 1/25 + 1/49 + ...) / 1 * 100
    // Analytically first 8 odd harmonics:
    // THD = sqrt(sum(1/(2k+1)^2 for k=1..)) ~= 48.34%
    // With 9 harmonics (2-9) we capture harmonics 3,5,7,9
    const allocator = testing.allocator;
    const n = 1024;
    var samples: [n]f64 = undefined;

    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        // Build square wave from Fourier series up to 9th harmonic
        // to avoid aliasing: sq(t) = (4/pi) * sum_{k=0}^{} sin(2pi(2k+1)t)/(2k+1)
        var val: f64 = 0;
        var harm: u32 = 1;
        while (harm <= 9) : (harm += 2) {
            val += @sin(2.0 * math.pi * @as(f64, @floatFromInt(harm)) * t) / @as(f64, @floatFromInt(harm));
        }
        samples[k] = val * 4.0 / math.pi;
    }

    const result = try analyzeBuffer(&samples, allocator);

    // Fundamental magnitude: (4/pi) * 1 = 1.2732
    try testing.expectApproxEqAbs(@as(f64, 4.0 / math.pi), result.fundamental, 1e-3);

    // 3rd harmonic = (4/pi)/3 = 0.4244
    try testing.expectApproxEqAbs(@as(f64, 4.0 / (3.0 * math.pi)), result.harmonics[2].mag, 1e-3);

    // THD from harmonics 3,5,7,9 only:
    // sqrt((1/3)^2 + (1/5)^2 + (1/7)^2 + (1/9)^2) * 100 = ~43.53%
    const expected_thd = @sqrt(1.0 / 9.0 + 1.0 / 25.0 + 1.0 / 49.0 + 1.0 / 81.0) * 100.0;
    try testing.expectApproxEqAbs(expected_thd, result.thd_percent, 1.0);
}

test "four: known amplitude and phase" {
    const allocator = testing.allocator;
    const n = 512;
    var samples: [n]f64 = undefined;

    // 2.0*cos(2*pi*t + pi/4) = fundamental with amplitude 2.0 and phase 45 deg
    const amp = 2.0;
    const phase_rad = math.pi / 4.0;
    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = amp * @cos(2.0 * math.pi * t + phase_rad);
    }

    const result = try analyzeBuffer(&samples, allocator);

    try testing.expectApproxEqAbs(amp, result.fundamental, 1e-8);
    try testing.expectApproxEqAbs(45.0, result.harmonics[0].phase_deg, 0.1);
}

test "four: analyzeBuffer with non-power-of-2 input" {
    // Verify resampling works for arbitrary length input
    const allocator = testing.allocator;
    const n = 100; // not a power of 2
    var samples: [n]f64 = undefined;

    for (0..n) |k| {
        const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        samples[k] = 1.5 * @cos(2.0 * math.pi * t);
    }

    const result = try analyzeBuffer(&samples, allocator);

    try testing.expectApproxEqAbs(@as(f64, 1.5), result.fundamental, 1e-2);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.dc, 1e-2);
}

test "four: analyze waveform from tran data" {
    const allocator = testing.allocator;

    // Build a synthetic waveform as if from transient sim
    const n_points: usize = 512;
    var waveform = try tran.Waveform.init(allocator, 1, n_points);
    defer waveform.deinit();

    const f_fund = 1000.0; // 1 kHz
    const period = 1.0 / f_fund;
    // Simulate 3 periods worth of data so there is enough for one-period extraction
    const t_total = 3.0 * period;

    const probes = [_]u32{0};
    for (0..n_points) |k| {
        const t = t_total * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_points));
        const v = [_]f64{2.5 * @cos(2.0 * math.pi * f_fund * t)};
        try waveform.record(t, &v, &probes);
    }

    const result = try analyze(&waveform, 0, f_fund, allocator);

    try testing.expectApproxEqAbs(@as(f64, 2.5), result.fundamental, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.dc, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.thd_percent, 1.0);
}
