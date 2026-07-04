//! Small-signal noise, adjoint method: one transpose solve per frequency
//! (A' y = e_out), then every source is a dot product — O(solves) went from
//! points*sources to points. Source conductances come off the analytic
//! Jacobian (root.Circuit.collectNoiseSources), no perturbation — devices
//! carry builtin noise generators, analyses never re-derive them.
const std = @import("std");
const root = @import("root.zig");
const FreqSolver = root.solvers.freq_solve.FreqSolver;
const freq = @import("freq.zig");

const k_boltzmann = 1.380649e-23;

pub const NoiseSource = root.NoiseSource;

pub const Options = struct {
    out_node: u32,
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
    temp_k: f64 = 27.0 + 273.15,
};

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
    std.debug.assert(freqs.len == density.len);

    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const e_out = try allocator.alloc(f64, nn);
    defer allocator.free(e_out);
    const y = try allocator.alloc(f64, nn);
    defer allocator.free(y);
    @memset(e_out, 0);
    e_out[options.out_node] = 1.0;

    var integrated_noise: f64 = 0;
    var prev_freq: f64 = 0;
    var prev_density: f64 = 0;

    var sw = freq.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var k: usize = 0;
    while (sw.next()) |f| : (k += 1) {
        const omega = 2.0 * std.math.pi * f;
        try fs.setOmega(omega);
        // Adjoint: M' y = e_out (M' represents the conjugate transpose in
        // stacked-real form; the conjugate drops out of |H|^2).
        try fs.solveRhsT(e_out, y);

        var total_density: f64 = 0;
        for (noise_sources) |src| {
            const psd = 4.0 * k_boltzmann * options.temp_k * src.conductance;
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
/// collectNoiseSources — never re-derived per resistor), adjoint sweep, output
/// noise density per point. Data layout: point-major (frequency, onoise_density).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    const srcs = try ctx.circuit.collectNoiseSources(x_op, a);
    defer a.free(srcs);

    const n_points = freq.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const freqs = try a.alloc(f64, n_points);
    defer a.free(freqs);
    const density = try a.alloc(f64, n_points);
    defer a.free(density);

    _ = try sweep(ctx.circuit, x_op, srcs, freqs, density, opts, a);

    const names = try a.dupe([]const u8, &.{ "frequency", "onoise_density" });
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
