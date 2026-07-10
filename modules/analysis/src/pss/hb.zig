//! Harmonic Balance: Newton on the spectral residual. Time-domain device
//! evals (IDFT samples) meet frequency-domain charge terms (j*omega*h*C);
//! one dense frequency-domain Jacobian per iteration.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
const dense_lu = root.solvers.dense_lu;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = struct {
    tol: converger.Tolerances = .{},
    f0: f64,
    n_harmonics: u16 = 8,
    max_iter: u16 = 200,
    hb_tol: f64 = 1e-9,
};

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    residual_norm: f64,
};

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

    @memset(x_hat, 0);

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

    var iter: u16 = 0;
    while (iter < options.max_iter) : (iter += 1) {
        // IDFT: Fourier coefficients -> time-domain samples (node-major: x_td[node * nf + k])
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
                if (ckt.has_charge) ckt.denseC(c_mat) else @memset(c_mat, 0);
            }
        }

        // Add source excitation in time domain
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

        // Check convergence
        var max_residual: f64 = 0;
        for (f_hat[0..total_unknowns]) |v| {
            max_residual = @max(max_residual, @abs(v));
        }
        if (max_residual < options.hb_tol) {
            extractSpectra(x_hat, probes, spectra, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = max_residual };
        }

        // Build frequency-domain Jacobian
        @memset(jac, 0);

        for (0..n) |row| {
            for (0..n) |col| {
                const g_slice = g_td[(row * n + col) * nf ..][0..nf];

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

                    jac[row_cos * total_unknowns + col_cos] = g_dc;
                    jac[row_sin * total_unknowns + col_sin] = g_dc;

                    if (@abs(g_cos_h) > 1e-30 or @abs(g_sin_h) > 1e-30) {
                        jac[row_dc * total_unknowns + col_cos] += g_cos_h * 0.5;
                        jac[row_dc * total_unknowns + col_sin] += g_sin_h * 0.5;
                        jac[row_cos * total_unknowns + col_dc] += g_cos_h;
                        jac[row_sin * total_unknowns + col_dc] += g_sin_h;
                    }
                }
            }
        }

        // Add charge Jacobian contribution
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

                    jac[row_cos * total_unknowns + col_sin] += -omega_h * c_val;
                    jac[row_sin * total_unknowns + col_cos] += omega_h * c_val;
                }
            }
        }

        // Solve J_hb * dX = -F_hat
        try dense_lu.factorizeSolveNeg(total_unknowns, jac, f_hat[0..total_unknowns], dx_hat);

        // Update X_hat
        for (0..total_unknowns) |j| {
            x_hat[j] += dx_hat[j];
        }
    }

    var final_norm: f64 = 0;
    for (f_hat[0..total_unknowns]) |v| {
        final_norm = @max(final_norm, @abs(v));
    }
    extractSpectra(x_hat, probes, spectra, nf);
    return .{ .converged = false, .iterations = options.max_iter, .residual_norm = final_norm };
}

/// Copy each probed node's [dc, cos_1, sin_1, ...] block out of x_hat —
/// spectra shares x_hat's per-node layout exactly.
fn extractSpectra(x_hat: []const f64, probes: []const u32, spectra: []f64, nf: usize) void {
    for (probes, 0..) |node, p|
        @memcpy(spectra[p * nf ..][0..nf], x_hat[node * nf ..][0..nf]);
}

/// Contract entry: unit cosine current excitation on ctx.source_node,
/// harmonic magnitudes per probe. Data layout: point-major rows
/// (frequency = k*f0, probes...), k = 0 (DC, signed) .. n_harmonics.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const nf: usize = 2 * @as(usize, opts.n_harmonics) + 1;

    const spectra = try a.alloc(f64, ctx.probes.len * nf);
    defer a.free(spectra);
    const st = try solve(ctx.circuit, ctx.source_node, 1.0, ctx.probes, spectra, opts, a);
    if (!st.converged)
        std.debug.print("Warning: hb: did not converge (residual {e})\n", .{st.residual_norm});

    const names = try root.probeNames(ctx, "frequency");
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
