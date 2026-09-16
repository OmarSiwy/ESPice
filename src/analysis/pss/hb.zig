//! Harmonic Balance: Newton on the spectral residual. Time-domain device
//! evals (IDFT samples) meet frequency-domain charge terms (j*omega*h*C);
//! one dense frequency-domain Jacobian per iteration.
//!
//! Algorithm (from pss-shooting-harmonic-balance.md §3):
//!   X = 0  (Fourier coefficients: [dc, cos_1, sin_1, ..., cos_K, sin_K] per node)
//!   for iter:
//!     x_td = IDFT(X)                    — 2K+1 time samples per node
//!     for each sample k: eval(x_td[:,k])  — fills F and analytic G
//!                         (k==0: capture C)
//!     f_td += source excitation
//!     F = DFT(f_td) + spectral charge terms (w_h C X_h)
//!     if max|F| < hb_tol: return X
//!     J = spectral(G(t)) blocks + (+-w_h C) skew blocks
//!     solve dense J dX = -F;  X += dX
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const converger = @import("solvers").converger;
const solvers = @import("solvers");
const dense_lu = solvers.dense_lu;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = @import("requests").Hb;

pub const SolveResult = @import("pss.zig").SolveResult;

/// Magnitude of the k-th harmonic (k=0 is DC) from one probe's spectrum
/// slice [dc, cos_1, sin_1, ..., cos_N, sin_N] (length 2*n_harmonics+1).
pub fn magnitude(spectrum: []const f64, k: u16) f64 {
    if (k == 0) return @abs(spectrum[0]);
    const c = spectrum[2 * @as(usize, k) - 1];
    const s = spectrum[2 * @as(usize, k)];
    return @sqrt(c * c + s * s);
}

/// Harmonic Balance solve. Excitation is a cosine current source of
/// `source_mag` at f0 injected into `source_node`'s KCL row.
///
/// Caller owns `spectra`: probes.len * (2*n_harmonics+1) flat, probe-major —
/// spectra[p*nf..][0..nf] = [dc, cos_1, sin_1, ..., cos_N, sin_N].
pub fn solve(
    ckt: *root.Circuit,
    source_node: u32,
    source_mag: f64,
    probes: []const u32,
    spectra: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const nh: usize = options.n_harmonics;
    const nf: usize = 2 * nh + 1;
    const total_unknowns = n * nf;
    std.debug.assert(spectra.len == probes.len * nf);

    const period: f64 = 1.0 / options.f0;
    const omega0: f64 = 2.0 * std.math.pi * options.f0;

    const total_f64 = total_unknowns + // x_hat
        total_unknowns + // f_hat
        nf * n + // x_td (node-major)
        nf * n + // f_td (node-major)
        n * n + // c_mat
        total_unknowns * total_unknowns + // jac
        total_unknowns + // dx_hat
        nf * n * n + // g_td (element-major, samples contiguous)
        nf * nh + // basis_cos (harmonic-major)
        nf * nh + // basis_sin
        n + // x_sample (gather buffer for device eval)
        n * n; // g_sample (denseG scatter temp)

    const arena = try allocator.alloc(f64, total_f64);
    defer allocator.free(arena);

    var off: usize = 0;
    const x_hat = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const f_hat = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const x_td = arena[off..][0 .. nf * n];
    off += nf * n;
    const f_td = arena[off..][0 .. nf * n];
    off += nf * n;
    const c_mat = arena[off..][0 .. n * n];
    off += n * n;
    const jac = arena[off..][0 .. total_unknowns * total_unknowns];
    off += total_unknowns * total_unknowns;
    const dx_hat = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const g_td = arena[off..][0 .. nf * n * n];
    off += nf * n * n;
    const basis_cos = arena[off..][0 .. nf * nh];
    off += nf * nh;
    const basis_sin = arena[off..][0 .. nf * nh];
    off += nf * nh;
    const x_sample = arena[off..][0..n];
    off += n;
    const g_sample = arena[off..][0 .. n * n];
    off += n * n;
    std.debug.assert(off == total_f64);

    root.zeroSimd(x_hat);

    // DC seed: solve the DC operating point via converger.run + EvalHook,
    // which routes through gpu_hook.solve_newton when GPU is active.
    // Seeding x_hat[dc] from the true DC op dramatically reduces HB iterations
    // for circuits with a nontrivial bias point.
    {
        const ws = try ckt.workspace();
        root.zeroSimd(x_sample);
        _ = converger.run(ckt, ws, x_sample, 0, converger.optionsFromTolerances(options.tol, null), root.EvalHook{}) catch {};
        for (0..n) |node| x_hat[node * nf] = x_sample[node];
    }

    // Basis: harmonic-major layout — basis_cos[hi * nf + k], basis_sin[hi * nf + k]
    for (0..nh) |hi| {
        const h = hi + 1;
        for (0..nf) |k| {
            const t_k = @as(f64, @floatFromInt(k)) * period / @as(f64, @floatFromInt(nf));
            const angle = @as(f64, @floatFromInt(h)) * omega0 * t_k;
            basis_cos[hi * nf + k] = @cos(angle);
            basis_sin[hi * nf + k] = @sin(angle);
        }
    }

    // ponytail: GPU status for HB —
    //   DC seed above uses converger.run + EvalHook → gpu_hook.solve_newton when GPU active.
    //   HB inner loop (DFT sandwich: IDFT → device eval → DFT) stays CPU.
    //   GPU upgrade path: batched device eval kernel over nf time samples (each independent),
    //   plus cuSOLVER dense LU for the total_unknowns×total_unknowns spectral Jacobian.
    //   IDFT/DFT are also trivially parallel per (node, harmonic) element.

    var iter: u16 = 0;
    while (iter < options.max_iter) : (iter += 1) {
        if (iter != 0) try ckt.checkpoint(.{ .phase = .harmonic, .completed = iter });
        // IDFT: Fourier coefficients -> time-domain samples (node-major: x_td[node * nf + k])
        // ponytail: IDFT is trivially parallel per (node, k) — one GPU thread per element
        for (0..n) |node| {
            const dc = x_hat[node * nf];
            const cos_base = node * nf + 1;
            for (0..nf) |k| {
                var val: f64 = dc;
                var hi: usize = 0;
                while (hi + W <= nh) : (hi += W) {
                    var bcv: V = undefined;
                    var bsv: V = undefined;
                    var cv: V = undefined;
                    var sv: V = undefined;
                    inline for (0..W) |w| {
                        bcv[w] = basis_cos[(hi + w) * nf + k];
                        bsv[w] = basis_sin[(hi + w) * nf + k];
                        cv[w] = x_hat[cos_base + 2 * (hi + w)];
                        sv[w] = x_hat[cos_base + 2 * (hi + w) + 1];
                    }
                    val += @reduce(.Add, cv * bcv + sv * bsv);
                }
                while (hi < nh) : (hi += 1) {
                    val += x_hat[cos_base + 2 * hi] * basis_cos[hi * nf + k] +
                        x_hat[cos_base + 2 * hi + 1] * basis_sin[hi * nf + k];
                }
                x_td[node * nf + k] = val;
            }
        }

        // Evaluate F(x(t_k)) at each time sample: one eval fills residual +
        // analytic G plane; k=0 also serves as the DC sample for the C plane.
        // ponytail: nf evals are independent — GPU batch kernel dispatches all
        // samples in one launch, upgrade path from serial ckt.eval loop
        for (0..nf) |k| {
            for (0..n) |node| x_sample[node] = x_td[node * nf + k];
            ckt.eval(x_sample, 0);
            for (0..n) |node| f_td[node * nf + k] = ckt.rhs[node];
            ckt.denseG(g_sample);
            for (0..n) |row| {
                for (0..n) |col| {
                    g_td[(row * n + col) * nf + k] = g_sample[row * n + col];
                }
            }
            if (k == 0) {
                // dQ/dx at the DC sample, straight off the analytic C plane
                if (ckt.has_charge) ckt.denseC(c_mat) else root.zeroSimd(c_mat);
            }
        }

        if (source_node != root.GROUND) {
            for (0..nf) |k| {
                f_td[source_node * nf + k] += source_mag * basis_cos[k];
            }
        }

        // DFT: time-domain residuals -> frequency domain
        // Node-major f_td[node * nf + k] means contiguous vector loads over k
        const nf_f: f64 = @floatFromInt(nf);

        for (0..n) |node| {
            const f_slice = f_td[node * nf ..][0..nf];

            var dc_acc: V = @splat(0.0);
            var k: usize = 0;
            while (k + W <= nf) : (k += W) {
                const fv: V = f_slice[k..][0..W].*;
                dc_acc += fv;
            }
            var dc_sum: f64 = @reduce(.Add, dc_acc);
            while (k < nf) : (k += 1) dc_sum += f_slice[k];
            f_hat[node * nf] = dc_sum / nf_f;

            for (0..nh) |hi| {
                const bc_slice = basis_cos[hi * nf ..][0..nf];
                const bs_slice = basis_sin[hi * nf ..][0..nf];
                var cos_acc: V = @splat(0.0);
                var sin_acc: V = @splat(0.0);
                k = 0;
                while (k + W <= nf) : (k += W) {
                    const fv: V = f_slice[k..][0..W].*;
                    const bcv: V = bc_slice[k..][0..W].*;
                    const bsv: V = bs_slice[k..][0..W].*;
                    cos_acc += fv * bcv;
                    sin_acc += fv * bsv;
                }
                var cos_sum: f64 = @reduce(.Add, cos_acc);
                var sin_sum: f64 = @reduce(.Add, sin_acc);
                while (k < nf) : (k += 1) {
                    cos_sum += f_slice[k] * bc_slice[k];
                    sin_sum += f_slice[k] * bs_slice[k];
                }
                f_hat[node * nf + 2 * (hi + 1) - 1] = 2.0 * cos_sum / nf_f;
                f_hat[node * nf + 2 * (hi + 1)] = 2.0 * sin_sum / nf_f;
            }
        }

        // Add frequency-domain charge terms: j*omega*h * C * X_hat[h]
        // j*omega_h * (C_cos + j*C_sin) applied to (X_cos + j*X_sin):
        //   real part: -omega_h * C * X_sin
        //   imag part:  omega_h * C * X_cos
        for (0..nh) |hi| {
            const h = hi + 1;
            const omega_h = @as(f64, @floatFromInt(h)) * omega0;
            for (0..n) |row| {
                var sum_cos: f64 = 0;
                var sum_sin: f64 = 0;
                for (0..n) |col| {
                    const c_val = c_mat[row * n + col];
                    if (c_val == 0) continue;
                    const x_cos = x_hat[col * nf + 2 * h - 1];
                    const x_sin = x_hat[col * nf + 2 * h];
                    sum_cos += c_val * (-omega_h * x_sin);
                    sum_sin += c_val * (omega_h * x_cos);
                }
                f_hat[row * nf + 2 * h - 1] += sum_cos;
                f_hat[row * nf + 2 * h] += sum_sin;
            }
        }

        const max_residual = normInf(f_hat);
        if (max_residual < options.hb_tol) {
            extractSpectra(x_hat, probes, spectra, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = max_residual };
        }

        // ponytail: DC + first-order cos/sin cross-blocks kept;
        // higher-order intermodulation blocks truncated (doc §2 design choice)
        root.zeroSimd(jac);

        for (0..n) |row| {
            for (0..n) |col| {
                const g_slice = g_td[(row * n + col) * nf ..][0..nf];

                // G_0 (DC component of G(t)): mean over all samples
                var g_dc_acc: V = @splat(0.0);
                var k2: usize = 0;
                while (k2 + W <= nf) : (k2 += W) {
                    const gv: V = g_slice[k2..][0..W].*;
                    g_dc_acc += gv;
                }
                var g_dc: f64 = @reduce(.Add, g_dc_acc);
                while (k2 < nf) : (k2 += 1) g_dc += g_slice[k2];
                g_dc /= nf_f;

                const row_dc = row * nf;
                const col_dc = col * nf;
                jac[row_dc * total_unknowns + col_dc] = g_dc;

                for (0..nh) |hi| {
                    const h = hi + 1;
                    const bc_slice = basis_cos[hi * nf ..][0..nf];
                    const bs_slice = basis_sin[hi * nf ..][0..nf];

                    // G_h: h-th Fourier coefficient of G(t)
                    var g_cos_acc: V = @splat(0.0);
                    var g_sin_acc: V = @splat(0.0);
                    var k3: usize = 0;
                    while (k3 + W <= nf) : (k3 += W) {
                        const gv: V = g_slice[k3..][0..W].*;
                        const bcv: V = bc_slice[k3..][0..W].*;
                        const bsv: V = bs_slice[k3..][0..W].*;
                        g_cos_acc += gv * bcv;
                        g_sin_acc += gv * bsv;
                    }
                    var g_cos_h: f64 = @reduce(.Add, g_cos_acc);
                    var g_sin_h: f64 = @reduce(.Add, g_sin_acc);
                    while (k3 < nf) : (k3 += 1) {
                        g_cos_h += g_slice[k3] * bc_slice[k3];
                        g_sin_h += g_slice[k3] * bs_slice[k3];
                    }
                    g_cos_h *= 2.0 / nf_f;
                    g_sin_h *= 2.0 / nf_f;

                    const row_cos = row * nf + 2 * h - 1;
                    const row_sin = row * nf + 2 * h;
                    const col_cos = col * nf + 2 * h - 1;
                    const col_sin = col * nf + 2 * h;

                    // Diagonal blocks (G_0 on harmonic-h diagonal)
                    jac[row_cos * total_unknowns + col_cos] = g_dc;
                    jac[row_sin * total_unknowns + col_sin] = g_dc;

                    // Cross-blocks: DC ↔ harmonic h (first-order intermodulation)
                    if (@abs(g_cos_h) > 1e-30 or @abs(g_sin_h) > 1e-30) {
                        jac[row_dc * total_unknowns + col_cos] += g_cos_h * 0.5;
                        jac[row_dc * total_unknowns + col_sin] += g_sin_h * 0.5;
                        jac[row_cos * total_unknowns + col_dc] += g_cos_h;
                        jac[row_sin * total_unknowns + col_dc] += g_sin_h;
                    }
                }
            }
        }

        // Add charge Jacobian contribution: ±omega_h * C skew blocks
        for (0..nh) |hi| {
            const h = hi + 1;
            const omega_h = @as(f64, @floatFromInt(h)) * omega0;
            for (0..n) |row| {
                for (0..n) |col| {
                    const c_val = c_mat[row * n + col];
                    if (c_val == 0) continue;

                    const row_cos = row * nf + 2 * h - 1;
                    const row_sin = row * nf + 2 * h;
                    const col_cos = col * nf + 2 * h - 1;
                    const col_sin = col * nf + 2 * h;

                    // d/d(X_sin)[j*omega_h * C * (X_cos + j*X_sin)]_real = -omega_h*C
                    jac[row_cos * total_unknowns + col_sin] += -omega_h * c_val;
                    // d/d(X_cos)[j*omega_h * C * (X_cos + j*X_sin)]_imag = omega_h*C
                    jac[row_sin * total_unknowns + col_cos] += omega_h * c_val;
                }
            }
        }

        // ponytail: single dense system of size total_unknowns = n*(2K+1); cuSOLVER
        // dgetrf+dgetrs replaces this when total_unknowns > ~256, add when GPU HB kernel lands
        try dense_lu.factorizeSolveNeg(total_unknowns, jac, f_hat[0..total_unknowns], dx_hat);

        {
            var ui: usize = 0;
            while (ui + W <= total_unknowns) : (ui += W) {
                const xv: V = x_hat[ui..][0..W].*;
                const dv: V = dx_hat[ui..][0..W].*;
                x_hat[ui..][0..W].* = xv + dv;
            }
            while (ui < total_unknowns) : (ui += 1) {
                x_hat[ui] += dx_hat[ui];
            }
        }
    }

    const final_norm = normInf(f_hat);
    extractSpectra(x_hat, probes, spectra, nf);
    return .{ .converged = false, .iterations = options.max_iter, .residual_norm = final_norm };
}

inline fn normInf(buf: []const f64) f64 {
    var mx: f64 = 0;
    var ri: usize = 0;
    while (ri + W <= buf.len) : (ri += W) {
        const fv: V = buf[ri..][0..W].*;
        mx = @max(mx, @reduce(.Max, @abs(fv)));
    }
    while (ri < buf.len) : (ri += 1) {
        mx = @max(mx, @abs(buf[ri]));
    }
    return mx;
}

/// Copy each probed node's [dc, cos_1, sin_1, ...] block out of x_hat —
/// spectra shares x_hat's per-node layout exactly.
fn extractSpectra(x_hat: []const f64, probes: []const u32, spectra: []f64, nf: usize) void {
    for (probes, 0..) |node, p|
        simdCopy(spectra[p * nf ..][0..nf], x_hat[node * nf ..][0..nf]);
}

/// Contract entry: unit cosine current excitation on ctx.source_node,
/// harmonic magnitudes per probe. Data layout: point-major rows
/// (frequency = k*f0, probes...), k = 0 (DC, signed) .. n_harmonics.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const nf: usize = 2 * @as(usize, opts.n_harmonics) + 1;

    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const spectra = try scratch.alloc(f64, ctx.probes.len * nf);
    defer scratch.free(spectra);
    const st = try solve(ctx.circuit, ctx.source_node, 1.0, ctx.probes, spectra, opts, scratch);
    if (!st.converged) return error.HbDidNotConverge;

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s);
        a.free(names);
    }
    const ncols = names.len;
    const n_rows: usize = @as(usize, opts.n_harmonics) + 1;
    const data = try a.alloc(f64, n_rows * ncols);
    for (0..n_rows) |k| {
        const row = data[k * ncols ..][0..ncols];
        row[0] = @as(f64, @floatFromInt(k)) * opts.f0;
        for (0..ctx.probes.len) |p| {
            const spec = spectra[p * nf ..][0..nf];
            row[p + 1] = if (k == 0) spec[0] else magnitude(spec, @intCast(k));
        }
    }
    return .{
        .plotname = "Harmonic Balance",
        .varnames = names,
        .is_complex = false,
        .npoints = n_rows,
        .data = data,
    };
}
