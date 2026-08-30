//! Periodic noise (PNoise): PSS via shooting Newton, then a frozen-time LPTV
//! sweep with sideband folding. Source conductances come off the analytic
//! Jacobian (root.Circuit.collectNoiseSources) — devices carry builtin noise
//! generators, this analysis never re-derives them.
//!
//! Noise kinds:
//!   thermal: S = 4*k_B*T*g          (white)
//!   shot:    S = 2*q*|I|             (white)
//!   flicker: S = kf*|I|^af / |f_sb|  (1/f, frequency-dependent per sideband)
//!
//! Cyclostationary modulation: noise sources are collected at each PSS sample
//! so the PSD g_s(t_k)/I(t_k) tracks the periodic orbit (the dominant modulation
//! effect for switched networks). Inter-sideband correlation and true LPTV
//! conversion matrices are the adjoint upgrade path.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const dense_lu = @import("solvers").dense_lu;
const types = @import("solvers").types;

const k_boltzmann = 1.380649e-23; // J/K
const q_electron = 1.602176634e-19; // C

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const NoiseSource = root.NoiseSource;

pub const Options = struct {
    tol: converger.Tolerances = .{},
    out_node: u32,
    f_start: f64,
    f_stop: f64,
    f_fundamental: f64,
    points_per_decade: u16 = 10,
    temp_k: f64 = 27.0 + 273.15,
    pss_n_samples: u32 = 64,
    pss_stab_periods: u32 = 10,
    pss_shoot_tol: f64 = 1e-6,
    pss_shoot_max_iter: u16 = 50,
    pss_newton_max_iter: u16 = 50,
    pss_newton_tol: f64 = 1e-9,
    n_sidebands: u16 = 7,
};

pub const SweepStatus = struct {
    total_noise: f64,
    pss_converged: bool,
};

// ---------------------------------------------------------------------------
// SIMD helpers (mandatory: no @memset, @memcpy, std.mem.*)
// ---------------------------------------------------------------------------

inline fn simdZero(buf: []f64) void {
    root.zeroSimd(buf);
}

inline fn simdCopy(dst: []f64, src: []const f64) void {
    const n = @min(dst.len, src.len);
    var i: usize = 0;
    while (i + W <= n) : (i += W) dst[i..][0..W].* = src[i..][0..W].*;
    while (i < n) : (i += 1) dst[i] = src[i];
}

// ---------------------------------------------------------------------------
// Per-source PSD computation
// ---------------------------------------------------------------------------

/// Compute PSD for a single noise source at a given sideband frequency.
/// For cyclostationary modulation, conductance/current are the time-sample values.
inline fn sourcePsd(
    kind: root.NoiseGenKind,
    conductance: f64,
    current: f64,
    kf: f64,
    af: f64,
    f_sideband: f64,
    four_kt: f64,
) f64 {
    return switch (kind) {
        .thermal => four_kt * conductance,
        .shot => 2.0 * q_electron * @abs(current),
        .flicker => blk: {
            // ponytail: guard f_sideband == 0 (DC sideband); flicker PSD
            // diverges — clamp to a floor; upgrade: analytic integral if needed
            const f_abs = @max(@abs(f_sideband), 1e-30);
            break :blk kf * std.math.pow(f64, @abs(current), af) / f_abs;
        },
    };
}

// ---------------------------------------------------------------------------
// Public API: fine-grained sweep primitive
// ---------------------------------------------------------------------------

/// Periodic Noise (PNoise) analysis.
///
/// Algorithm (frozen-time LPTV approximation):
///   1. Run simplified PSS via shooting Newton to find the periodic steady-state
///      solution x(t) over one period T = 1/f_fundamental.
///   2. Sample the circuit Jacobian G(t_k) and charge Jacobian C(t_k) at each
///      PSS time sample t_k (k = 0..N-1) — one ckt.eval per sample fills both
///      planes, denseG/denseC capture them.
///   3. Collect noise sources at each PSS sample for cyclostationary modulation:
///      g_s(t_k) and I(t_k) vary over the period as the bias varies along the orbit.
///   4. For each output frequency f_out in the sweep range:
///      a. For each sideband m = -M..+M, compute the sideband frequency
///         f_m = f_out + m * f_fundamental.
///      b. At each time sample, build the complex admittance Y_k = G_k + j*2*pi*f_m*C_k,
///         factor once, then one back-substitution per noise source.
///      c. Average |H_k(f_m)|^2 * S_s(f_m, t_k) over the PSS period (frozen-time
///         approximation with cyclostationary source modulation and per-kind PSD).
///      d. Fold: sum contributions from all sidebands.
///   5. Output: noise spectral density S_v(f_out) [V^2/Hz] at each frequency.
///
/// Fine-grained primitive: caller owns freqs/density (both logSweepCount long).
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

    // --- Phase 1: PSS via shooting Newton ---
    const pss_traj = try allocator.alloc(f64, n_samples * n);
    defer allocator.free(pss_traj);

    const pss_converged = try runPSS(ckt, x_dc, pss_traj, n, n_samples, period, options, allocator);

    // --- Phase 2: Extract G(t_k) and C(t_k) at each sample ---
    const g_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(g_mats);
    const c_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(c_mats);

    // Per-sample noise source data for cyclostationary modulation:
    // conductance g_s(t_k) and current I(t_k) vary over the period.
    // ponytail: SoA layout — n_samples * n_srcs flat array, sample-major
    const src_g = try allocator.alloc(f64, n_samples * n_srcs);
    defer allocator.free(src_g);
    const src_i = try allocator.alloc(f64, n_samples * n_srcs);
    defer allocator.free(src_i);

    for (0..n_samples) |k| {
        const x_k = pss_traj[k * n .. (k + 1) * n];
        const t_k = @as(f64, @floatFromInt(k)) * dt;
        ckt.eval(x_k, t_k);
        ckt.denseG(g_mats[k * n * n ..][0 .. n * n]);
        ckt.denseC(c_mats[k * n * n ..][0 .. n * n]);

        // Collect noise sources at this PSS sample for cyclostationary modulation.
        const srcs_k = try ckt.collectNoiseSources(x_k, allocator);
        defer allocator.free(srcs_k);

        const g_row = src_g[k * n_srcs ..][0..n_srcs];
        const i_row = src_i[k * n_srcs ..][0..n_srcs];
        // Match sources by ordering — same ordering guaranteed by
        // the collector, which iterates devices deterministically.
        for (0..n_srcs) |s| {
            // ponytail: trust ordering from collectNoiseSources is deterministic
            // across calls; if not, a hash-match is the upgrade path
            if (s < srcs_k.len) {
                g_row[s] = srcs_k[s].conductance;
                i_row[s] = srcs_k[s].current;
            } else {
                g_row[s] = noise_sources[s].conductance; // fallback to DC
                i_row[s] = noise_sources[s].current;
            }
        }
    }

    // --- Phase 3: Frequency sweep with sideband folding ---
    const nn = 2 * n;
    const a_work = try allocator.alloc(f64, nn * nn);
    defer allocator.free(a_work);
    const piv = try allocator.alloc(u32, nn);
    defer allocator.free(piv);
    const rhs_work = try allocator.alloc(f64, nn);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);
    // Per-source period-averaged |H|^2 * PSD accumulator (one admittance
    // factorization per sample serves every source).
    const h_sq_acc = try allocator.alloc(f64, n_srcs);
    defer allocator.free(h_sq_acc);

    var integrated_noise: f64 = 0;
    var prev_freq: f64 = 0;
    var prev_density: f64 = 0;

    const m_max: i32 = @intCast(options.n_sidebands);
    const four_kt = 4.0 * k_boltzmann * options.temp_k;
    const inv_n_samples = 1.0 / n_samples_f;

    var sw = types.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var pt: usize = 0;
    while (sw.next()) |f_out| : (pt += 1) {
        var total_density: f64 = 0;

        // For each sideband m
        var m: i32 = -m_max;
        while (m <= m_max) : (m += 1) {
            const f_sb = f_out + @as(f64, @floatFromInt(m)) * options.f_fundamental;
            // Fold negative frequencies via conjugate symmetry (|H(f)| = |H(-f)|
            // for real networks)
            const f_phys = @abs(f_sb);
            if (f_phys < 1e-30) continue;
            const omega = 2.0 * std.math.pi * f_phys;

            simdZero(h_sq_acc);

            // Average over PSS time samples: factor the admittance once per
            // sample, then one back-substitution per noise source.
            for (0..n_samples) |k| {
                const g_offset = k * n * n;
                const g_mat = g_mats[g_offset .. g_offset + n * n];
                const c_mat = c_mats[g_offset .. g_offset + n * n];
                const g_row = src_g[k * n_srcs ..][0..n_srcs];
                const i_row = src_i[k * n_srcs ..][0..n_srcs];

                // Build 2n x 2n complex admittance system:
                //   | G  -wC | | v_re |   | i_re |
                //   | wC   G | | v_im | = | i_im |
                dense_lu.buildComplexAdmittance(n, nn, g_mat, c_mat, omega, a_work);
                try dense_lu.factorize(nn, a_work, piv);

                for (noise_sources, 0..) |src, s| {
                    // Excitation: unit current at noise source nodes
                    simdZero(rhs_work);
                    if (src.node_p != root.GROUND) rhs_work[src.node_p] = 1.0;
                    if (src.node_n != root.GROUND) rhs_work[src.node_n] = -1.0;

                    dense_lu.solveFactored(nn, a_work, piv, rhs_work, x_work);

                    // Transfer to output node (complex: re in [0..n), im in [n..2n))
                    const h_re = x_work[options.out_node];
                    const h_im = x_work[n + options.out_node];
                    const h_sq = h_re * h_re + h_im * h_im;

                    // Per-source PSD with cyclostationary modulation
                    const psd = sourcePsd(
                        src.kind,
                        g_row[s],
                        i_row[s],
                        src.kf,
                        src.af,
                        f_sb, // actual sideband freq (not folded) for flicker
                        four_kt,
                    );
                    h_sq_acc[s] += h_sq * psd;
                }
            }

            // Sum over sources: density = (1/N) * sum_k |H_k|^2 * PSD_s(t_k, f_sb)
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

        // Trapezoidal integration
        if (pt > 0) {
            integrated_noise += 0.5 * (prev_density + total_density) * (f_out - prev_freq);
        }
        prev_freq = f_out;
        prev_density = total_density;
    }

    return .{ .total_noise = @sqrt(integrated_noise), .pss_converged = pss_converged };
}

// ---------------------------------------------------------------------------
// Contract entry: run()
// ---------------------------------------------------------------------------

/// Contract entry: sources off the analytic Jacobian (builtin device noise via
/// collectNoiseSources — never re-derived per resistor), LPTV sweep, periodic
/// noise density per point. Data layout: point-major (frequency, pnoise_density).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    // ponytail: Phase 4 — GPU batch dispatch not applicable here.
    // Each PSS time sample k has its own Jacobian (G_k, C_k) from the periodic
    // orbit, so freq_solve_batch (which takes one shared G,C with many omegas)
    // cannot batch the (freq × sideband × sample) inner loop directly.
    // Upgrade path: a per-sample-batched variant that accepts N×(G,C,omega)
    // triples, or lifting the sample loop into the kernel.

    const srcs = try ctx.circuit.collectNoiseSources(x_op, a);
    defer a.free(srcs);

    const n_points = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const freqs_buf = try a.alloc(f64, n_points);
    defer a.free(freqs_buf);
    const density_buf = try a.alloc(f64, n_points);
    defer a.free(density_buf);

    const st = try sweep(ctx.circuit, x_op, srcs, freqs_buf, density_buf, opts, a);

    const names = try a.dupe([]const u8, &.{ "frequency", "pnoise_density" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, @as(usize, n_points) * 2);
    for (0..n_points) |i| {
        data[i * 2] = freqs_buf[i];
        data[i * 2 + 1] = density_buf[i];
    }

    return .{
        // Non-convergence surfaced in the plotname — run() stays pure.
        .plotname = if (st.pss_converged) "Periodic Noise Analysis" else "Periodic Noise Analysis (PSS not converged)",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}

// ============================================================================
// PSS: Simplified shooting Newton
// ============================================================================

/// Run PSS via shooting Newton method.
/// Integrates the circuit over one period using per-sample frozen-time Newton
/// solves, then checks if x(T) == x(0). Fixed-point iteration on the shooting
/// function phi(x0) = x(T) - x0.
///
/// For LTI circuits (resistors only), the PSS solution is the DC operating point
/// replicated at every time sample, and convergence is immediate.
///
/// Returns true if converged. Fills pss_traj with n_samples state snapshots
/// uniformly distributed over one period [0, T).
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
    const x_scratch = try allocator.alloc(f64, n);
    defer allocator.free(x_scratch);

    // Initialize x0 from DC operating point
    simdCopy(x0, x_dc);

    // Shooting fixed-point iterations
    var converged = false;
    var shoot_iter: u16 = 0;
    while (shoot_iter < options.pss_shoot_max_iter) : (shoot_iter += 1) {
        // Integrate one period from x0, storing trajectory
        integrateOnePeriod(ckt, x0, x_end, pss_traj, n, n_samples, period, options, ws, x_scratch);

        // Shooting residual: phi = x_end - x0
        var max_residual: f64 = 0;
        var j: usize = 0;
        while (j + W <= n) : (j += W) {
            const ev: V = x_end[j..][0..W].*;
            const xv: V = x0[j..][0..W].*;
            const dv = ev - xv;
            const av = @abs(dv);
            max_residual = @max(max_residual, @reduce(.Max, av));
        }
        while (j < n) : (j += 1) {
            max_residual = @max(max_residual, @abs(x_end[j] - x0[j]));
        }

        if (max_residual < options.pss_shoot_tol) {
            converged = true;
            break;
        }

        // Simple fixed-point update: x0 = x_end
        simdCopy(x0, x_end);
    }

    // If not converged, fill the trajectory with the last attempt anyway.
    if (!converged) {
        integrateOnePeriod(ckt, x0, x_end, pss_traj, n, n_samples, period, options, ws, x_scratch);
    }

    return converged;
}

/// Integrate the circuit over one period [0, T) using frozen-time Newton
/// solves, storing state snapshots at n_samples uniformly spaced time points.
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
    x_scratch: []f64,
) void {
    const dt = period / @as(f64, @floatFromInt(n_samples));
    const nr_opts = converger.Options{
        .max_iter = options.pss_newton_max_iter,
        .abstol = options.pss_newton_tol,
    };

    // Start from x0; store initial state as sample 0.
    simdCopy(x_scratch, x0);
    simdCopy(pss_traj[0..n], x0);

    // Solve at each subsequent time sample (frozen-time quasi-static Newton).
    for (1..n_samples) |k| {
        const t_k = @as(f64, @floatFromInt(k)) * dt;
        _ = converger.run(ckt, ws, x_scratch, t_k, nr_opts, root.EvalHook{}) catch
            converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };

        // Store this time sample
        const offset = k * n;
        simdCopy(pss_traj[offset .. offset + n], x_scratch);
    }

    // x_end = state at end of period
    simdCopy(x_end, x_scratch);
}

// ============================================================================
// Tests
// ============================================================================

test "sourcePsd thermal" {
    const four_kt = 4.0 * k_boltzmann * 300.15;
    const g: f64 = 0.01; // 100 ohm
    const psd = sourcePsd(.thermal, g, 0, 0, 1, 1e6, four_kt);
    // S = 4kTg
    const expected = four_kt * g;
    try std.testing.expectApproxEqRel(psd, expected, 1e-12);
}

test "sourcePsd shot" {
    const i_bias: f64 = 1e-3; // 1 mA
    const psd = sourcePsd(.shot, 0, i_bias, 0, 1, 1e6, 0);
    // S = 2*q*|I|
    const expected = 2.0 * q_electron * i_bias;
    try std.testing.expectApproxEqRel(psd, expected, 1e-12);
}

test "sourcePsd shot negative current" {
    const i_bias: f64 = -2e-3;
    const psd = sourcePsd(.shot, 0, i_bias, 0, 1, 1e6, 0);
    const expected = 2.0 * q_electron * 2e-3;
    try std.testing.expectApproxEqRel(psd, expected, 1e-12);
}

test "sourcePsd flicker" {
    const i_bias: f64 = 1e-3;
    const kf: f64 = 1e-24;
    const af: f64 = 1.0;
    const f_sb: f64 = 1e3;
    const psd = sourcePsd(.flicker, 0, i_bias, kf, af, f_sb, 0);
    // S = kf * |I|^af / |f|
    const expected = kf * std.math.pow(f64, i_bias, af) / f_sb;
    try std.testing.expectApproxEqRel(psd, expected, 1e-12);
}

test "sourcePsd flicker 1/f shape" {
    // Flicker PSD at f1 vs f2 should scale as f2/f1
    const i_bias: f64 = 1e-3;
    const kf: f64 = 1e-24;
    const af: f64 = 1.0;
    const psd_lo = sourcePsd(.flicker, 0, i_bias, kf, af, 100.0, 0);
    const psd_hi = sourcePsd(.flicker, 0, i_bias, kf, af, 1000.0, 0);
    // ratio should be 10 (1/f shape)
    try std.testing.expectApproxEqRel(psd_lo / psd_hi, 10.0, 1e-12);
}

test "sourcePsd flicker near-DC clamp" {
    // f_sideband near zero should not blow up (clamped to 1e-30 floor)
    const psd = sourcePsd(.flicker, 0, 1e-3, 1e-24, 1.0, 0.0, 0);
    try std.testing.expect(std.math.isFinite(psd));
    try std.testing.expect(psd > 0);
}

test "sourcePsd flicker af=2" {
    const i_bias: f64 = 2e-3;
    const kf: f64 = 1e-24;
    const af: f64 = 2.0;
    const f_sb: f64 = 500.0;
    const psd = sourcePsd(.flicker, 0, i_bias, kf, af, f_sb, 0);
    const expected = kf * std.math.pow(f64, i_bias, af) / f_sb;
    try std.testing.expectApproxEqRel(psd, expected, 1e-12);
}
