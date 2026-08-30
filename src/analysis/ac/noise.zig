//! Small-signal noise, adjoint method: one transpose solve per frequency
//! (A^H y = e_out), then every source is a dot product -- O(solves) went from
//! points*sources to points. Source conductances come off the analytic
//! Jacobian (root.Circuit.collectNoiseSources), no perturbation -- devices
//! carry builtin noise generators, analyses never re-derive them.
//!
//! Supports thermal (4kTg), shot (2q|I|), and flicker (KF*|I|^AF/f) PSD.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("solvers").types;
const FreqSolver = root.solvers.freq_solve.FreqSolver;

const k_boltzmann = 1.380649e-23;
const q_electron = 1.602176634e-19;

const W = std.simd.suggestVectorLength(f64) orelse 8;

pub const NoiseSource = root.NoiseSource;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    out_node: u32,
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
    temp_k: f64 = 27.0 + 273.15,
};

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

/// Fine-grained primitive: sweep into caller-owned freqs/density buffers
/// (both logSweepCount long). Returns the integrated total output noise
/// (trapezoidal over the sweep band, sqrt at the end).
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !f64 {
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points = freqs.len;
    std.debug.assert(freqs.len == density.len);

    // ponytail: GPU batch adjoint path — all freq solves in one dispatch,
    // PSD accumulation stays CPU (cheap). Falls through on error or absence.
    if (ckt.gpu_hook != null) gpu: {
        // Fill G/C planes at operating point (same eval fromCircuit does).
        ckt.linearize(x_op);

        // Build omega + freq arrays.
        const omegas = allocator.alloc(f64, n_points) catch break :gpu;
        defer allocator.free(omegas);
        types.fillLogSweep(options.f_start, options.f_stop, options.points_per_decade, freqs, omegas);

        // RHS: unit excitation at out_node (stacked-real, length 2n).
        const e_out = allocator.alloc(f64, nn) catch break :gpu;
        defer allocator.free(e_out);
        root.zeroSimd(e_out);
        e_out[options.out_node] = 1.0;

        // Batch adjoint dispatch — single GPU launch for all frequency points.
        const y_lanes = ckt.gpuFreqBatch(allocator, ckt.g_vals, ckt.c_vals, omegas, e_out, @intCast(n), true) orelse break :gpu;
        defer root.freeFreqLanes(allocator, y_lanes);

        // CPU-side PSD accumulation + trapezoidal integration.
        var integrated_noise: f64 = 0;
        var prev_freq: f64 = 0;
        var prev_density: f64 = 0;
        for (0..n_points) |k| {
            const f = freqs[k];
            const y = y_lanes[k];

            var total_density: f64 = 0;
            for (noise_sources) |src| {
                const psd = sourcePsd(src, f, options.temp_k);
                const yp_re: f64 = if (src.node_p != root.GROUND) y[src.node_p] else 0;
                const yn_re: f64 = if (src.node_n != root.GROUND) y[src.node_n] else 0;
                const yp_im: f64 = if (src.node_p != root.GROUND) y[n + src.node_p] else 0;
                const yn_im: f64 = if (src.node_n != root.GROUND) y[n + src.node_n] else 0;
                const h_re = yp_re - yn_re;
                const h_im = yp_im - yn_im;
                total_density += (h_re * h_re + h_im * h_im) * psd;
            }

            density[k] = total_density;
            if (k > 0) integrated_noise += 0.5 * (prev_density + total_density) * (f - prev_freq);
            prev_freq = f;
            prev_density = total_density;
        }

        return @sqrt(integrated_noise);
    }

    // ── Serial CPU fallback ──────────────────────────────────────────────
    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const e_out = try allocator.alloc(f64, nn);
    defer allocator.free(e_out);
    const y = try allocator.alloc(f64, nn);
    defer allocator.free(y);
    root.zeroSimd(e_out);
    e_out[options.out_node] = 1.0;

    var integrated_noise: f64 = 0;
    var prev_freq: f64 = 0;
    var prev_density: f64 = 0;

    var sw = types.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var k: usize = 0;
    while (sw.next()) |f| : (k += 1) {
        const omega = 2.0 * std.math.pi * f;
        try fs.setOmega(omega);
        // Adjoint: A^H y = e_out (the conjugate drops out of |H|^2,
        // so stacked-real transpose solve suffices).
        try fs.solveRhsT(e_out, y);

        var total_density: f64 = 0;
        for (noise_sources) |src| {
            const psd = sourcePsd(src, f, options.temp_k);
            const yp_re: f64 = if (src.node_p != root.GROUND) y[src.node_p] else 0;
            const yn_re: f64 = if (src.node_n != root.GROUND) y[src.node_n] else 0;
            const yp_im: f64 = if (src.node_p != root.GROUND) y[n + src.node_p] else 0;
            const yn_im: f64 = if (src.node_n != root.GROUND) y[n + src.node_n] else 0;
            const h_re = yp_re - yn_re;
            const h_im = yp_im - yn_im;
            total_density += (h_re * h_re + h_im * h_im) * psd;
        }

        freqs[k] = f;
        density[k] = total_density;

        if (k > 0) integrated_noise += 0.5 * (prev_density + total_density) * (f - prev_freq);
        prev_freq = f;
        prev_density = total_density;
    }

    return @sqrt(integrated_noise);
}

/// Contract entry: sources off the analytic Jacobian (builtin device noise via
/// collectNoiseSources -- never re-derived per resistor), adjoint sweep, output
/// noise density per point. Data layout: point-major (frequency, onoise_density).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const srcs = try ctx.circuit.collectNoiseSources(x_op, a);
    defer a.free(srcs);

    const n_points = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const freqs = try a.alloc(f64, n_points);
    defer a.free(freqs);
    const density = try a.alloc(f64, n_points);
    defer a.free(density);

    _ = try sweep(ctx.circuit, x_op, srcs, freqs, density, opts, a);

    const names = try a.dupe([]const u8, &.{ "frequency", "onoise_density" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, @as(usize, n_points) * 2);
    for (0..n_points) |i| {
        data[i * 2] = freqs[i];
        data[i * 2 + 1] = density[i];
    }

    return .{
        .plotname = "Noise Analysis",
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
    // 4 * 1.380649e-23 * 300.15 * 0.01 = 1.6576e-25 (approx)
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
