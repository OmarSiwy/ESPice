//! HSPICE `.fft` [CR .FFT; SA Ch.15]: the deck's transient, resampled onto
//! NP uniform points over [START, STOP), windowed and transformed. The plot
//! is the `.ft#` data: every bin from DC to NP/2, as one complex column
//! whose magnitude is the component's amplitude and whose angle is its sine
//! phase. Also cites Harris 1978 (Kaiser window side lobes, #82).
const std = @import("std");
const root = @import("../types.zig");
const fft_mod = @import("solver").fft;
const tran = @import("../tran/tran.zig");
const four = @import("four.zig");

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Fft;

/// HSPICE's window `n` of `np` [SA Ch.15 Table 56], `alfa` shaping GAUSS and
/// KAISER.
pub fn window(kind: Options.Window, n: usize, np: usize, alfa: f64) f64 {
    const x: f64 = @floatFromInt(n);
    const m: f64 = @floatFromInt(np);
    const c = 2 * std.math.pi * x / (m - 1);
    const half = m / 2;
    // Distance from the centre of the symmetric NP - 1 forms the cosine
    // windows use, so GAUSS and KAISER reach their edge value at n = 0 and
    // n = NP - 1 (#82): Kaiser's u = 2d/(NP - 1) spans [0, 1], as in Harris
    // 1978 and numpy's kaiser(NP, pi ALFA).
    const d = @abs(x - (m - 1) / 2);
    return switch (kind) {
        .rect => 1,
        .bart => if (x <= half - 1) 2 * x / (m - 1) else 2 - 2 * x / (m - 1),
        .hann => 0.5 - 0.5 * @cos(c),
        .hamm => 0.54 - 0.46 * @cos(c),
        .black => 0.42323 - 0.49755 * @cos(c) + 0.07922 * @cos(2 * c),
        .harris => 0.35875 - 0.48829 * @cos(c) + 0.14128 * @cos(2 * c) - 0.01168 * @cos(3 * c),
        .gauss => @exp(-0.5 * alfa * alfa * d * d / (m * m)),
        .kaiser => blk: {
            const x1 = std.math.pi * alfa;
            const r = 2 * d / (m - 1);
            break :blk besselI0(x1 * @sqrt(@max(1 - r * r, 0))) / besselI0(x1);
        },
    };
}

/// Zero-order modified Bessel function of the first kind, by its power
/// series, which converges for every finite argument.
fn besselI0(x: f64) f64 {
    var sum: f64 = 1;
    var term: f64 = 1;
    var k: f64 = 1;
    while (term > 1e-17 * sum) : (k += 1) {
        const h = x / (2 * k);
        term *= h * h;
        sum += term;
    }
    return sum;
}

/// Contract entry: the transient, then the spectrum. Complex, NP/2 + 1 rows
/// (frequency, output). Bin k >= 1 holds 2·X[k]/Σw rotated to a sine
/// reference, so a bin-centred A·sin(2πft + φ) reads A∠φ under any window;
/// DC and Nyquist hold X[k]/Σw. FORMAT=NORM divides every bin by the
/// largest non-DC magnitude. `error.TransientFailed` when the run stops
/// early.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const np: usize = opts.np;

    const x = try scratch.dupe(f64, ctx.x_op);
    defer scratch.free(x);
    const differential = opts.out_neg != root.GROUND;
    const probes = [_]u32{ opts.out_pos, opts.out_neg };
    const n_probes: u32 = if (differential) 2 else 1;
    var wf = try tran.Waveform.init(scratch, n_probes, tran.initialCapacity(opts.tran));
    defer wf.deinit();
    const sim = try tran.simulate(ctx.circuit, x, probes[0..n_probes], &wf, opts.tran, scratch);
    if (!sim) return error.TransientFailed;

    const re = try scratch.alloc(f64, 2 * np);
    defer scratch.free(re);
    const im = re[np..];
    @memset(im, 0);
    const times = wf.column(0);
    const dt = (opts.stop - opts.start) / @as(f64, @floatFromInt(np));
    var cursor_p: usize = 0;
    var cursor_n: usize = 0;
    var w_sum: f64 = 0;
    for (re[0..np], 0..) |*r, k| {
        const t = opts.start + dt * @as(f64, @floatFromInt(k));
        var v = four.interpolateAt(times, wf.column(1), t, &cursor_p);
        if (differential) v -= four.interpolateAt(times, wf.column(2), t, &cursor_n);
        const w = window(opts.window, k, np, opts.alfa);
        w_sum += w;
        r.* = v * w;
    }
    fft_mod.fft(re[0..np], im);

    const rows = np / 2 + 1;
    // Complex rows: (frequency, 0, re, im).
    const data = try a.alloc(f64, rows * 4);
    var peak: f64 = 0;
    for (0..rows) |k| {
        const scale = (if (k == 0 or k == np / 2) @as(f64, 1) else 2) / w_sum;
        const row = data[k * 4 ..][0..4];
        row[0] = @as(f64, @floatFromInt(k)) / (opts.stop - opts.start);
        row[1] = 0;
        // X[k] = (N·A/2)·e^{jφc} for A·cos(ωt + φc); A·sin(ωt + φ) has
        // φc = φ − 90°, so j·X[k] carries the sine phase φ.
        row[2] = if (k == 0) re[0] * scale else -im[k] * scale;
        row[3] = if (k == 0) 0 else re[k] * scale;
        if (k != 0) peak = @max(peak, std.math.hypot(row[2], row[3]));
    }
    if (opts.normalized and peak > 0) for (0..rows) |k| {
        data[k * 4 + 2] /= peak;
        data[k * 4 + 3] /= peak;
    };

    const names = try a.dupe([]const u8, &.{ "frequency", opts.label });
    return .{
        .plotname = try std.fmt.allocPrint(a, "FFT Analysis {s}", .{opts.label}),
        .varnames = names,
        .is_complex = true,
        .npoints = rows,
        .data = data,
    };
}

test "window: every kind is symmetric and peaks at 1 or less" {
    const np = 64;
    inline for (@typeInfo(Options.Window).@"enum".field_names) |name| {
        const kind = @field(Options.Window, name);
        for (0..np) |k| {
            const w = window(kind, k, np, 3);
            try std.testing.expectApproxEqAbs(window(kind, np - 1 - k, np, 3), w, 1e-12);
            try std.testing.expect(w <= 1 + 1e-12 and w > -1e-12);
        }
    }
    // Hann reaches 0 at both ends; rect and alfa = 0 Kaiser are flat.
    try std.testing.expectApproxEqAbs(@as(f64, 0), window(.hann, 0, np, 0), 1e-15);
    try std.testing.expectEqual(@as(f64, 1), window(.rect, 7, np, 0));
    try std.testing.expectEqual(@as(f64, 1), window(.kaiser, 7, np, 0));
}

test "window: Kaiser side lobes match Harris 1978 Table I" {
    // Highest side lobe of the 64-point window's spectrum, 16x zero-padded:
    // Harris gives -57, -69 and -82 dB at ALFA 2.5, 3 and 3.5. The old
    // centre-sample indexing kept the edge high and gave -55.9, -64.5 and
    // -69.4 (#82).
    const np = 64;
    const pad = 16 * np;
    for ([_]f64{ 2.5, 3, 3.5 }, [_]f64{ -57, -69, -82 }) |alfa, want| {
        var mag: [pad / 2]f64 = undefined;
        for (&mag, 0..) |*out, k| {
            var re: f64 = 0;
            var im: f64 = 0;
            for (0..np) |n| {
                const ph = 2 * std.math.pi * @as(f64, @floatFromInt(k * n)) / pad;
                const w = window(.kaiser, n, np, alfa);
                re += w * @cos(ph);
                im -= w * @sin(ph);
            }
            out.* = @sqrt(re * re + im * im);
        }
        var k: usize = 1;
        while (mag[k] < mag[k - 1]) k += 1; // past the main lobe's first null
        var peak: f64 = 0;
        for (mag[k..]) |v| peak = @max(peak, v);
        const db = 20 * @log10(peak / mag[0]);
        try std.testing.expectApproxEqAbs(want, db, 1.5);
    }
}

test "besselI0: series against reference values" {
    try std.testing.expectEqual(@as(f64, 1), besselI0(0));
    try std.testing.expectApproxEqRel(@as(f64, 1.2660658777520082), besselI0(1), 1e-15);
    try std.testing.expectApproxEqRel(@as(f64, 2815.716628466254), besselI0(10), 1e-13);
}
