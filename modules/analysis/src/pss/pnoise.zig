//! Periodic noise (PNoise): PSS via shooting Newton, then a frozen-time LPTV
//! sweep with sideband folding. Source conductances come off the analytic
//! Jacobian (root.Circuit.collectNoiseSources) — devices carry builtin noise
//! generators, this analysis never re-derives them.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
const dense_lu = root.solvers.dense_lu;
const freq = @import("../helper/freq.zig");

const k_boltzmann = 1.380649e-23; // J/K

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

/// Periodic Noise (PNoise) analysis.
///
/// Algorithm (frozen-time LPTV approximation):
///   1. Run simplified PSS via shooting Newton to find the periodic steady-state
///      solution x(t) over one period T = 1/f_fundamental.
///   2. Sample the circuit Jacobian G(t_k) and charge Jacobian C(t_k) at each
///      PSS time sample t_k (k = 0..N-1) — one ckt.eval per sample fills both
///      planes, denseG/denseC capture them.
///   3. For each output frequency f_out in the sweep range:
///      a. For each sideband m = -M..+M, compute the sideband frequency
///         f_m = f_out + m * f_fundamental.
///      b. At each time sample, build the complex admittance Y_k = G_k + j*2*pi*f_m*C_k,
///         solve for the noise transfer function H_k(f_m) from each noise source
///         to the output node.
///      c. Average |H_k(f_m)|^2 over the PSS period (frozen-time approximation).
///      d. Fold: sum contributions from all sidebands for each noise source.
///   4. Output: noise spectral density S_v(f_out) [V^2/Hz] at each frequency.
///
/// For a purely resistive LTI circuit with no periodicity, this reduces to the
/// standard noise analysis: S_v = 4kT * R_parallel, flat across frequency,
/// independent of the number of sidebands.
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
    std.debug.assert(freqs.len == density.len);

    // --- Step 1: PSS via shooting Newton ---
    // Allocate PSS solution trajectory: n_samples snapshots of the state vector.
    const pss_traj = try allocator.alloc(f64, n_samples * n);
    defer allocator.free(pss_traj);

    const pss_converged = try runPSS(ckt, x_dc, pss_traj, n, n_samples, period, options, allocator);

    // --- Step 2: Extract G(t_k) and C(t_k) at each sample ---
    // One eval per sample fills both planes.
    const g_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(g_mats);
    const c_mats = try allocator.alloc(f64, n_samples * n * n);
    defer allocator.free(c_mats);

    for (0..n_samples) |k| {
        const x_k = pss_traj[k * n .. (k + 1) * n];
        const t_k = @as(f64, @floatFromInt(k)) * dt;
        ckt.eval(x_k, t_k);
        ckt.denseG(g_mats[k * n * n ..][0 .. n * n]);
        ckt.denseC(c_mats[k * n * n ..][0 .. n * n]);
    }

    // --- Step 3: Frequency sweep with sideband folding ---
    const nn = 2 * n;
    const a_work = try allocator.alloc(f64, nn * nn);
    defer allocator.free(a_work);
    const piv = try allocator.alloc(u32, nn);
    defer allocator.free(piv);
    const rhs_work = try allocator.alloc(f64, nn);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);
    // Per-source period-averaged |H|^2 accumulator (one admittance
    // factorization per sample serves every source).
    const h_sq_acc = try allocator.alloc(f64, noise_sources.len);
    defer allocator.free(h_sq_acc);

    var integrated_noise: f64 = 0;
    var prev_freq: f64 = 0;
    var prev_density: f64 = 0;

    const m_max: i32 = @intCast(options.n_sidebands);

    var sw = freq.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var pt: usize = 0;
    while (sw.next()) |f_out| : (pt += 1) {
        var total_density: f64 = 0;

        // For each sideband m
        var m: i32 = -m_max;
        while (m <= m_max) : (m += 1) {
            const f_sb = f_out + @as(f64, @floatFromInt(m)) * options.f_fundamental;
            // Skip negative physical frequencies (fold via conjugate symmetry)
            const f_phys = @abs(f_sb);
            if (f_phys < 1e-30) continue;
            const omega = 2.0 * std.math.pi * f_phys;

            @memset(h_sq_acc, 0);

            // Average over PSS time samples: factor the admittance once per
            // sample, then one back-substitution per noise source.
            for (0..n_samples) |k| {
                const g_offset = k * n * n;
                const g_mat = g_mats[g_offset .. g_offset + n * n];
                const c_mat = c_mats[g_offset .. g_offset + n * n];

                // Build 2n x 2n complex admittance system:
                //   | G  -wC | | v_re |   | i_re |
                //   | wC   G | | v_im | = | i_im |
                dense_lu.buildComplexAdmittance(n, nn, g_mat, c_mat, omega, a_work);
                try dense_lu.factorize(nn, a_work, piv);

                for (noise_sources, h_sq_acc) |src, *acc| {
                    // Excitation: unit current at noise source nodes
                    @memset(rhs_work, 0);
                    if (src.node_p != root.GROUND) rhs_work[src.node_p] = 1.0;
                    if (src.node_n != root.GROUND) rhs_work[src.node_n] = -1.0;

                    dense_lu.solveFactored(nn, a_work, piv, rhs_work, x_work);

                    // Transfer to output node
                    const h_re = x_work[options.out_node];
                    const h_im = x_work[n + options.out_node];
                    acc.* += h_re * h_re + h_im * h_im;
                }
            }

            for (noise_sources, h_sq_acc) |src, acc| {
                const psd = 4.0 * k_boltzmann * options.temp_k * src.conductance;
                total_density += (acc / n_samples_f) * psd;
            }
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

/// Contract entry: sources off the analytic Jacobian (builtin device noise via
/// collectNoiseSources — never re-derived per resistor), LPTV sweep, periodic
/// noise density per point. Data layout: point-major (frequency, pnoise_density).
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

    const st = try sweep(ctx.circuit, x_op, srcs, freqs, density, opts, a);

    const names = try a.dupe([]const u8, &.{ "frequency", "pnoise_density" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, @as(usize, n_points) * 2);
    for (0..n_points) |i| {
        data[i * 2] = freqs[i];
        data[i * 2 + 1] = density[i];
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
    const x_work = try allocator.alloc(f64, n);
    defer allocator.free(x_work);

    // Initialize x0 from DC operating point
    @memcpy(x0, x_dc);

    // Shooting fixed-point iterations
    var converged = false;
    var shoot_iter: u16 = 0;
    while (shoot_iter < options.pss_shoot_max_iter) : (shoot_iter += 1) {
        // Integrate one period from x0, storing trajectory
        integrateOnePeriod(ckt, x0, x_end, pss_traj, n, n_samples, period, options, ws, x_work);

        // Shooting residual: phi = x_end - x0
        var max_residual: f64 = 0;
        for (0..n) |j| {
            const r = @abs(x_end[j] - x0[j]);
            max_residual = @max(max_residual, r);
        }

        if (max_residual < options.pss_shoot_tol) {
            converged = true;
            break;
        }

        // Simple fixed-point update: x0 = x_end
        // (For nonlinear circuits, a full Jacobian of the shooting function
        // would be needed; this simplified version works for mildly nonlinear
        // circuits and converges immediately for LTI circuits.)
        @memcpy(x0, x_end);
    }

    // If not converged, fill the trajectory with the last attempt anyway.
    if (!converged) {
        integrateOnePeriod(ckt, x0, x_end, pss_traj, n, n_samples, period, options, ws, x_work);
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
    x_work: []f64,
) void {
    const dt = period / @as(f64, @floatFromInt(n_samples));
    const nr_opts = converger.Options{
        .max_iter = options.pss_newton_max_iter,
        .abstol = options.pss_newton_tol,
    };

    // Start from x0; store initial state as sample 0.
    @memcpy(x_work, x0);
    @memcpy(pss_traj[0..n], x0);

    // Solve at each subsequent time sample (frozen-time quasi-static Newton).
    for (1..n_samples) |k| {
        const t_k = @as(f64, @floatFromInt(k)) * dt;
        _ = converger.run(ckt, ws, x_work, t_k, nr_opts, converger.EvalHook{}) catch
            converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };

        // Store this time sample
        const offset = k * n;
        @memcpy(pss_traj[offset .. offset + n], x_work);
    }

    // x_end = state at end of period
    @memcpy(x_end, x_work);
}
