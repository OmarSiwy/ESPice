//! Periodic noise: fixed-point shooting to the periodic steady state, then a
//! frozen-time LPTV sweep that averages |H|^2 * PSD over the period at each
//! sideband and folds the sidebands. Source PSDs come from the devices'
//! `noisePsd`, re-sampled along the orbit (cyclostationary modulation).
const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const converger = @import("solver").converger;
const dense_lu = @import("solver").dense_lu;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const NoiseSource = root.NoiseSource;

pub const Options = @import("core").query.Pnoise;

/// Outcome of a pnoise sweep.
pub const SweepStatus = struct {
    /// sqrt of the trapezoid integral of the density over the sweep, in V.
    total_noise: f64,
    pss_converged: bool,
};

/// S(f) = white + flicker/|f|^ef at one sideband, from one time sample's
/// coefficients.
inline fn sourcePsd(white: f64, flicker: f64, ef: f64, f_sideband: f64) f64 {
    if (flicker == 0) return white;
    // ponytail: 1/f diverges at the DC sideband, so |f| is floored at 1e-30.
    // Upgrade to the analytic band integral if it ever matters.
    const f_abs = @max(@abs(f_sideband), 1e-30);
    return white + flicker / std.math.pow(f64, f_abs, ef);
}

/// Periodic noise density at `options.out_node`, frozen-time approximation:
///   1. Shoot to the periodic orbit x(t_k), k = 0..N-1, T = 1/f_fundamental.
///   2. At each t_k take dense G_k, C_k and each source's PSD coefficients.
///   3. For each f_out and sideband f_m = f_out + m*f_fundamental, factor
///      Y_k = G_k + j*2*pi*|f_m|*C_k per sample, solve the adjoint once for
///      every source, and average |H_k|^2 * S(f_m, t_k) over k.
///   4. Sum the sidebands into S_v(f_out), in V^2/Hz.
/// The caller owns freqs and density, both sweep-count long. Returns
/// error.NoiseTopologyChanged if the sources differ along the orbit.
pub fn sweep(
    ckt: *root.Circuit,
    x_dc: []const f64,
    noise_sources: []const NoiseSource,
    freqs: []f64,
    density: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SweepStatus {
    const n: usize = ckt.n;
    const period = 1.0 / options.f_fundamental;
    const n_samples = options.pss_n_samples;
    const n_samples_f: f64 = @floatFromInt(n_samples);
    const dt = period / n_samples_f;
    const n_srcs = noise_sources.len;
    std.debug.assert(freqs.len == density.len);

    const pss_traj = try allocator.alloc(f64, n_samples * n);
    defer allocator.free(pss_traj);

    const pss_converged = try runPSS(ckt, x_dc, pss_traj, n, n_samples, period, options, allocator);

    const g_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(g_mats);
    const c_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(c_mats);

    // Per-sample source coefficients, SoA and sample-major:
    // src_white[k * n_srcs + s].
    const terms = @as(usize, n_samples) * n_srcs;
    const source_planes = try allocator.alloc(f64, 3 * terms);
    defer allocator.free(source_planes);
    const src_white = source_planes[0..terms];
    const src_flicker = source_planes[terms..][0..terms];
    const src_exponent = source_planes[2 * terms ..];

    for (0..n_samples) |k| {
        const x_k = pss_traj[k * n .. (k + 1) * n];
        const t_k = @as(f64, @floatFromInt(k)) * dt;
        // The time the sample was solved at (integrateOnePeriod).
        ckt.setSimState(.{ .t = t_k, .kind = .tran });
        ckt.eval(x_k, t_k);
        ckt.denseG(g_mats[k * n * n ..][0 .. n * n]);
        ckt.denseC(c_mats[k * n * n ..][0 .. n * n]);

        const srcs_k = try ckt.collectNoiseSources(x_k, allocator);
        defer allocator.free(srcs_k);

        const w_row = src_white[k * n_srcs ..][0..n_srcs];
        const f_row = src_flicker[k * n_srcs ..][0..n_srcs];
        const e_row = src_exponent[k * n_srcs ..][0..n_srcs];
        if (srcs_k.len != n_srcs) return error.NoiseTopologyChanged;
        for (srcs_k, noise_sources, w_row, f_row, e_row) |src, original, *white, *flicker, *exponent| {
            if (src.node_p != original.node_p or src.node_n != original.node_n)
                return error.NoiseTopologyChanged;
            white.* = src.white;
            flicker.* = src.flicker;
            exponent.* = src.ef;
        }
    }

    const nn = 2 * n;
    const a_work = try allocator.alloc(f64, nn * nn);
    defer allocator.free(a_work);
    const piv = try allocator.alloc(u32, nn);
    defer allocator.free(piv);
    const rhs_work = try allocator.alloc(f64, nn);
    defer allocator.free(rhs_work);
    simdZero(rhs_work);
    if (options.out_node != root.GROUND) rhs_work[options.out_node] = 1;
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);
    // Per-source sum over samples of |H|^2 * PSD at one sideband.
    const h_sq_acc = try allocator.alloc(f64, n_srcs);
    defer allocator.free(h_sq_acc);

    var integrated_noise: f64 = 0;
    var prev_freq: f64 = 0;
    var prev_density: f64 = 0;

    const m_max: i32 = @intCast(options.n_sidebands);
    const inv_n_samples = 1.0 / n_samples_f;

    var sw = options.sweep.iter();
    var pt: usize = 0;
    while (sw.next()) |f_out| : (pt += 1) {
        if (pt != 0) try ckt.checkpoint(.{ .phase = .frequency, .completed = pt, .total = freqs.len });
        var total_density: f64 = 0;

        var m: i32 = -m_max;
        while (m <= m_max) : (m += 1) {
            const f_sb = f_out + @as(f64, @floatFromInt(m)) * options.f_fundamental;
            // |H(f)| = |H(-f)| for a real network, so fold to |f|.
            const f_phys = @abs(f_sb);
            if (f_phys < 1e-30) continue;
            const omega = 2.0 * std.math.pi * f_phys;

            simdZero(h_sq_acc);

            for (0..n_samples) |k| {
                const g_offset = k * n * n;
                const g_mat = g_mats[g_offset .. g_offset + n * n];
                const c_mat = c_mats[g_offset .. g_offset + n * n];
                const w_row = src_white[k * n_srcs ..][0..n_srcs];
                const f_row = src_flicker[k * n_srcs ..][0..n_srcs];
                const e_row = src_exponent[k * n_srcs ..][0..n_srcs];

                //   | G  -wC | | v_re |   | i_re |
                //   | wC   G | | v_im | = | i_im |
                dense_lu.buildComplexAdmittance(n, nn, g_mat, c_mat, omega, a_work);
                try dense_lu.factorize(nn, a_work, piv);

                // One adjoint solve gives every source's transfer.
                dense_lu.solveFactoredT(nn, a_work, piv, rhs_work, x_work);
                for (noise_sources, 0..) |src, s| {
                    const h_re = (if (src.node_p != root.GROUND) x_work[src.node_p] else 0) -
                        (if (src.node_n != root.GROUND) x_work[src.node_n] else 0);
                    const h_im = (if (src.node_p != root.GROUND) x_work[n + src.node_p] else 0) -
                        (if (src.node_n != root.GROUND) x_work[n + src.node_n] else 0);
                    const h_sq = h_re * h_re + h_im * h_im;

                    // A 1/f shape is evaluated at the unfolded sideband f_sb.
                    const psd = sourcePsd(w_row[s], f_row[s], e_row[s], f_sb);
                    h_sq_acc[s] += h_sq * psd;
                }
            }

            // Sideband density = (1/N) * sum over sources of h_sq_acc.
            var sb_density: f64 = 0;
            var si: usize = 0;
            const splat_inv: V = @splat(inv_n_samples);
            while (si + W <= n_srcs) : (si += W) {
                const hv: V = h_sq_acc[si..][0..W].*;
                const psd_v = splat_inv * hv;
                sb_density += @reduce(.Add, psd_v);
            }
            while (si < n_srcs) : (si += 1) {
                sb_density += inv_n_samples * h_sq_acc[si];
            }

            total_density += sb_density;
        }

        freqs[pt] = f_out;
        density[pt] = total_density;

        if (pt > 0) {
            integrated_noise += 0.5 * (prev_density + total_density) * (f_out - prev_freq);
        }
        prev_freq = f_out;
        prev_density = total_density;
    }

    return .{ .total_noise = @sqrt(integrated_noise), .pss_converged = pss_converged };
}

/// Contract entry: device noise sources at ctx.x_op, LPTV sweep. Point-major
/// rows (frequency, pnoise_density); an unconverged PSS says so in the plot
/// name rather than failing.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op;

    // ponytail: no lane batching. Every PSS sample has its own (G_k, C_k),
    // so FreqSolver.solveBatch (one G, C, many omegas) does not fit the
    // (freq x sideband x sample) loop. The upgrade is a batched variant
    // taking N (G, C, omega) triples.

    const scratch = ctx.scratch_allocator;
    const srcs = try ctx.circuit.collectNoiseSources(x_op, scratch);
    defer scratch.free(srcs);

    const n_points = opts.sweep.count();
    const freqs_buf = try scratch.alloc(f64, n_points);
    defer scratch.free(freqs_buf);
    const density_buf = try scratch.alloc(f64, n_points);
    defer scratch.free(density_buf);

    const st = try sweep(ctx.circuit, x_op, srcs, freqs_buf, density_buf, opts, scratch);

    const names = try a.dupe([]const u8, &.{ "frequency", "pnoise_density" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, @as(usize, n_points) * 2);
    for (0..n_points) |i| {
        data[i * 2] = freqs_buf[i];
        data[i * 2 + 1] = density_buf[i];
    }

    return .{
        .plotname = if (st.pss_converged) "Periodic Noise Analysis" else "Periodic Noise Analysis (PSS not converged)",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}

/// Fixed-point shooting: integrate one period from x0 and repeat from x(T)
/// until max|x(T) - x0| < pss_shoot_tol. Fills pss_traj with n_samples
/// states over [0, T), from the last attempt when it does not converge.
/// Returns whether it converged.
fn runPSS(
    ckt: *root.Circuit,
    x_dc: []const f64,
    pss_traj: []f64,
    n: usize,
    n_samples: u32,
    period: f64,
    options: Options,
    allocator: std.mem.Allocator,
) !bool {
    const ws = try ckt.workspace();
    const x0 = try allocator.alloc(f64, n);
    defer allocator.free(x0);
    const x_end = try allocator.alloc(f64, n);
    defer allocator.free(x_end);

    simdCopy(x0, x_dc);

    var shoot_iter: u16 = 0;
    while (shoot_iter < options.pss_shoot_max_iter) : (shoot_iter += 1) {
        if (shoot_iter != 0) try ckt.checkpoint(.{ .phase = .periodic, .completed = shoot_iter });
        try integrateOnePeriod(ckt, x0, x_end, pss_traj, n, n_samples, period, options, ws);

        var max_residual: f64 = 0;
        var j: usize = 0;
        while (j + W <= n) : (j += W) {
            const ev: V = x_end[j..][0..W].*;
            const xv: V = x0[j..][0..W].*;
            max_residual = @max(max_residual, @reduce(.Max, @abs(ev - xv)));
        }
        while (j < n) : (j += 1) {
            max_residual = @max(max_residual, @abs(x_end[j] - x0[j]));
        }

        if (max_residual < options.pss_shoot_tol) return true;

        simdCopy(x0, x_end);
    }

    try integrateOnePeriod(ckt, x0, x_end, pss_traj, n, n_samples, period, options, ws);

    return false;
}

/// Walks one period from x0 with frozen-time quasi-static Newton solves at
/// n_samples uniform points, storing each state in pss_traj (sample 0 is
/// x0) and leaving the last in x_end. Newton failures are ignored.
fn integrateOnePeriod(
    ckt: *root.Circuit,
    x0: []const f64,
    x_end: []f64,
    pss_traj: []f64,
    n: usize,
    n_samples: u32,
    period: f64,
    options: Options,
    ws: *converger.Workspace,
) !void {
    const dt = period / @as(f64, @floatFromInt(n_samples));
    const nr_opts = converger.Options{
        .max_iter = options.pss_newton_max_iter,
        .abstol = options.pss_newton_tol,
    };

    simdCopy(x_end, x0);
    simdCopy(pss_traj[0..n], x0);

    for (1..n_samples) |k| {
        const t_k = @as(f64, @floatFromInt(k)) * dt;
        // Sources follow their waveform only under analysis("tran")
        // (§4.6.1). dt stays 0: these solves are quasi-static.
        ckt.setSimState(.{ .t = t_k, .kind = .tran });
        _ = converger.run(ckt, ws, x_end, t_k, nr_opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => {},
        };

        const offset = k * n;
        simdCopy(pss_traj[offset .. offset + n], x_end);
    }
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .sourcePsd = sourcePsd,
} else {};
