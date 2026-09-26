//! Harmonic balance: Newton on the spectral residual with a backtracking
//! line search. Each iteration IDFTs the unknowns to 2(2K+1) time samples,
//! evaluates the circuit at each (sources included), DFTs the residual and
//! adds the dq/dt terms, then solves one dense harmonic-convolution Jacobian.
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const num = @import("core").numerics;
const converger = @import("solver").converger;
const dense_lu = @import("solver").dense_lu;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = @import("core").query.Hb;

pub const SolveResult = @import("pss.zig").SolveResult;

/// Time samples per spectral unknown. The 2K+1 collocation points alias
/// the harmonics a nonlinearity generates past K onto the top of the kept
/// band; 2(2K+1) > 4K samples project the residual of any cubic in x(t)
/// onto harmonics 0..K exactly, a Galerkin rather than collocation fit.
const oversample: usize = 2;

/// The shortest step the line search takes before it stops shortening.
const min_step: f64 = 1.0 / 1024.0;

/// Magnitude of harmonic k >= 1 from one probe's spectrum
/// [dc, cos_1, sin_1, ..., cos_K, sin_K].
fn magnitude(spectrum: []const f64, k: u16) f64 {
    const c = spectrum[2 * @as(usize, k) - 1];
    const s = spectrum[2 * @as(usize, k)];
    return @sqrt(c * c + s * s);
}

/// Harmonic balance from the DC operating point; the excitation is whatever
/// the deck's sources stamp at each time sample. The caller owns `spectra`,
/// probes.len * (2*n_harmonics+1) probe-major:
/// spectra[p*nf..][0..nf] = [dc, cos_1, sin_1, ..., cos_K, sin_K].
/// Memory is O((n*nf)^2) for the dense Jacobian.
pub fn solve(
    ckt: *root.Circuit,
    probes: []const u32,
    spectra: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;
    const nh: usize = options.n_harmonics;
    const nf: usize = 2 * nh + 1;
    const nt: usize = nf * oversample;
    const total_unknowns = n * nf;
    std.debug.assert(spectra.len == probes.len * nf);

    const period: f64 = 1.0 / options.f0;
    const omega0: f64 = 2.0 * std.math.pi * options.f0;
    const nt_f: f64 = @floatFromInt(nt);
    const dt_sample: f64 = period / nt_f;

    const total_f64 = total_unknowns + // x_hat
        total_unknowns + // f_hat
        nt * n + // x_td (node-major)
        nt * n + // f_td (node-major)
        nt * n + // q_td (node-major)
        n * n + // c_mat
        total_unknowns * total_unknowns + // jac
        total_unknowns + // dx_hat
        nt * nnz + // g_td (slot-major, samples contiguous)
        nt * 2 * nh + // basis_cos (harmonic-major, harmonics 1..2K)
        nt * 2 * nh + // basis_sin
        n + // x_sample (gather buffer for device eval)
        total_unknowns + // x_prev (line-search rewind point)
        2 * (2 * nh + 1); // gc / gs: one slot's G(t) spectrum to 2K

    const arena = try allocator.alloc(f64, total_f64);
    defer allocator.free(arena);

    var off: usize = 0;
    const x_hat = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const f_hat = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const x_td = arena[off..][0 .. nt * n];
    off += nt * n;
    const f_td = arena[off..][0 .. nt * n];
    off += nt * n;
    const q_td = arena[off..][0 .. nt * n];
    off += nt * n;
    const c_mat = arena[off..][0 .. n * n];
    off += n * n;
    const jac = arena[off..][0 .. total_unknowns * total_unknowns];
    off += total_unknowns * total_unknowns;
    const dx_hat = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const g_td = arena[off..][0 .. nt * nnz];
    off += nt * nnz;
    const basis_cos = arena[off..][0 .. nt * 2 * nh];
    off += nt * 2 * nh;
    const basis_sin = arena[off..][0 .. nt * 2 * nh];
    off += nt * 2 * nh;
    const x_sample = arena[off..][0..n];
    off += n;
    const x_prev = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const gc = arena[off..][0 .. 2 * nh + 1];
    off += 2 * nh + 1;
    const gs = arena[off..][0 .. 2 * nh + 1];
    off += 2 * nh + 1;
    std.debug.assert(off == total_f64);

    root.zeroSimd(x_hat);

    // Seed the DC coefficients with the DC operating point, which cuts the
    // iteration count on biased circuits.
    {
        const ws = try ckt.workspace();
        ckt.setSimState(.{ .kind = .dc });
        root.zeroSimd(x_sample);
        _ = converger.run(ckt, ws, x_sample, 0, converger.optionsFromTolerances(options.tol, null), root.EvalHook{}) catch {};
        for (0..n) |node| x_hat[node * nf] = x_sample[node];
    }

    // Harmonic-major basis: basis_cos[hi * nt + k] = cos((hi+1)*w0*t_k).
    // The IDFT/DFT read harmonics 1..K; the Jacobian's G(t) spectrum needs
    // them to 2K.
    for (0..2 * nh) |hi| {
        const h = hi + 1;
        for (0..nt) |k| {
            const t_k = @as(f64, @floatFromInt(k)) * period / nt_f;
            const angle = @as(f64, @floatFromInt(h)) * omega0 * t_k;
            basis_cos[hi * nt + k] = @cos(angle);
            basis_sin[hi * nt + k] = @sin(angle);
        }
    }

    // ponytail: all on the CPU. The GPU path would batch the nt independent
    // sample evals in one launch and factor the spectral Jacobian with
    // cuSOLVER; the IDFT/DFT are parallel per (node, harmonic).

    // Backtracking line search on the loop's own residual evaluation: a step
    // that made the residual worse (or non-finite, hence the negated
    // comparison) is undone from `x_prev` and retaken at half length, and a
    // step that helped earns the length back. A full Newton step can hand a
    // diode the whole source swing at once.
    var step: f64 = 1.0;
    var prev_residual: f64 = std.math.inf(f64);
    var retrying = false;

    var iter: u16 = 0;
    while (iter < options.max_iter) : (iter += 1) {
        if (iter != 0) try ckt.checkpoint(.{ .phase = .harmonic, .completed = iter });
        // IDFT to node-major samples x_td[node * nt + k].
        for (0..n) |node| {
            const dc = x_hat[node * nf];
            const cos_base = node * nf + 1;
            for (0..nt) |k| {
                var val: f64 = dc;
                var hi: usize = 0;
                while (hi + W <= nh) : (hi += W) {
                    var bcv: V = undefined;
                    var bsv: V = undefined;
                    var cv: V = undefined;
                    var sv: V = undefined;
                    inline for (0..W) |w| {
                        bcv[w] = basis_cos[(hi + w) * nt + k];
                        bsv[w] = basis_sin[(hi + w) * nt + k];
                        cv[w] = x_hat[cos_base + 2 * (hi + w)];
                        sv[w] = x_hat[cos_base + 2 * (hi + w) + 1];
                    }
                    val += @reduce(.Add, cv * bcv + sv * bsv);
                }
                while (hi < nh) : (hi += 1) {
                    val += x_hat[cos_base + 2 * hi] * basis_cos[hi * nt + k] +
                        x_hat[cos_base + 2 * hi + 1] * basis_sin[hi * nt + k];
                }
                x_td[node * nt + k] = val;
            }
        }

        // Sample k is the circuit at t_k = k*T/nt in the transient phase,
        // the only phase in which a source follows its waveform (§4.6.1).
        // One eval fills the residual and the G plane; sample 0 also gives C.
        // ponytail: the nt evals are independent; batch them on the GPU when
        // HB needs it.
        for (0..nt) |k| {
            const t_k = period * @as(f64, @floatFromInt(k)) / nt_f;
            for (0..n) |node| x_sample[node] = x_td[node * nt + k];
            ckt.setSimState(.{ .t = t_k, .dt = dt_sample, .kind = .tran });
            ckt.eval(x_sample, t_k);
            for (0..n) |node| f_td[node * nt + k] = ckt.rhs[node];
            for (0..n) |node| q_td[node * nt + k] = ckt.q_vec[node];
            for (ckt.g_vals[0..nnz], 0..) |g, slot| g_td[slot * nt + k] = g;
            if (k == 0) {
                if (ckt.has_charge) ckt.denseC(c_mat) else root.zeroSimd(c_mat);
            }
        }

        // DFT of the residual; node-major f_td makes each node's samples one
        // contiguous run.
        for (0..n) |node| {
            const f_slice = f_td[node * nt ..][0..nt];

            var dc_acc: V = @splat(0.0);
            var k: usize = 0;
            while (k + W <= nt) : (k += W) {
                const fv: V = f_slice[k..][0..W].*;
                dc_acc += fv;
            }
            var dc_sum: f64 = @reduce(.Add, dc_acc);
            while (k < nt) : (k += 1) dc_sum += f_slice[k];
            f_hat[node * nf] = dc_sum / nt_f;

            for (0..nh) |hi| {
                const bc_slice = basis_cos[hi * nt ..][0..nt];
                const bs_slice = basis_sin[hi * nt ..][0..nt];
                var cos_acc: V = @splat(0.0);
                var sin_acc: V = @splat(0.0);
                k = 0;
                while (k + W <= nt) : (k += W) {
                    const fv: V = f_slice[k..][0..W].*;
                    const bcv: V = bc_slice[k..][0..W].*;
                    const bsv: V = bs_slice[k..][0..W].*;
                    cos_acc += fv * bcv;
                    sin_acc += fv * bsv;
                }
                var cos_sum: f64 = @reduce(.Add, cos_acc);
                var sin_sum: f64 = @reduce(.Add, sin_acc);
                while (k < nt) : (k += 1) {
                    cos_sum += f_slice[k] * bc_slice[k];
                    sin_sum += f_slice[k] * bs_slice[k];
                }
                f_hat[node * nf + 2 * (hi + 1) - 1] = 2.0 * cos_sum / nt_f;
                f_hat[node * nf + 2 * (hi + 1)] = 2.0 * sin_sum / nt_f;
            }
        }

        // dq/dt from the DFT of q(t_k), exact for nonlinear charge. With
        // q(t) = a cos(w_h t) + b sin(w_h t), dq/dt = w_h b cos - w_h a sin,
        // so the cos row takes +w_h*Q_sin and the sin row -w_h*Q_cos.
        // ponytail: scalar O(n*nh*nt) projection, the same order as the
        // residual DFT; vectorize both if HB ever profiles hot.
        if (ckt.has_charge) for (0..n) |node| {
            const q_slice = q_td[node * nt ..][0..nt];
            for (0..nh) |hi| {
                var q_cos: f64 = 0;
                var q_sin: f64 = 0;
                for (q_slice, basis_cos[hi * nt ..][0..nt], basis_sin[hi * nt ..][0..nt]) |q, bc, bs| {
                    q_cos += q * bc;
                    q_sin += q * bs;
                }
                const omega_h = @as(f64, @floatFromInt(hi + 1)) * omega0;
                f_hat[node * nf + 2 * (hi + 1) - 1] += omega_h * (2.0 * q_sin / nt_f);
                f_hat[node * nf + 2 * (hi + 1)] += -omega_h * (2.0 * q_cos / nt_f);
            }
        };

        const max_residual = num.normInf(f_hat);
        if (converger.hbTrace()) std.debug.print("HB iter={d} res={e} step={e} normx={e}\n", .{ iter, max_residual, step, num.normInf(x_hat) });
        if (max_residual < options.hb_tol) {
            extractSpectra(x_hat, probes, spectra, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = max_residual };
        }

        if (iter != 0 and !(max_residual <= prev_residual) and step > min_step) {
            // Rewind and retake the last step at half length along the same
            // `dx_hat`; no Jacobian rebuild.
            step *= 0.5;
            simdCopy(x_hat, x_prev);
            num.axpy(x_hat, step, dx_hat);
            retrying = true;
            continue;
        }
        prev_residual = max_residual;
        if (!retrying) step = @min(step * 2.0, 1.0);
        retrying = false;

        // The harmonic-convolution Jacobian: dF/dX is the spectrum of G(t)
        // convolved with the basis, and product-to-sum gives
        //
        //   d F_ch / d a_m = 1/2 (Gc[|h-m|] + Gc[h+m])
        //   d F_ch / d b_m = 1/2 (Gs[h+m]   + Gs[m-h])
        //   d F_sh / d a_m = 1/2 (Gs[h+m]   + Gs[h-m])
        //   d F_sh / d b_m = 1/2 (Gc[|h-m|] - Gc[h+m])
        //
        // with Gc[0] = 2*mean(G), Gs[0] = 0 and Gs[-d] = -Gs[d]. h + m runs
        // to 2K: product-to-sum is exact on the samples, so projecting G(t)
        // onto harmonics past K keeps the Jacobian exact for the sampled
        // residual. The h != m blocks are how a nonlinearity couples
        // harmonics.
        root.zeroSimd(jac);

        // Pattern slots only: a structurally zero entry has G(t) = 0, whose
        // projections are the +0 already in jac.
        for (0..n) |col| {
            for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |slot| {
                const row: usize = ckt.row_idx[slot];
                const g_slice = g_td[slot * nt ..][0..nt];

                // Gc[0] = 2*mean(G); Gc[k>0], Gs[k>0] are the 2/nt projections.
                var g_dc_acc: V = @splat(0.0);
                var k2: usize = 0;
                while (k2 + W <= nt) : (k2 += W) {
                    const gv: V = g_slice[k2..][0..W].*;
                    g_dc_acc += gv;
                }
                var g_sum: f64 = @reduce(.Add, g_dc_acc);
                while (k2 < nt) : (k2 += 1) g_sum += g_slice[k2];
                gc[0] = 2.0 * g_sum / nt_f;
                gs[0] = 0;

                for (0..2 * nh) |hi| {
                    const bc_slice = basis_cos[hi * nt ..][0..nt];
                    const bs_slice = basis_sin[hi * nt ..][0..nt];
                    var g_cos_acc: V = @splat(0.0);
                    var g_sin_acc: V = @splat(0.0);
                    var k3: usize = 0;
                    while (k3 + W <= nt) : (k3 += W) {
                        const gv: V = g_slice[k3..][0..W].*;
                        const bcv: V = bc_slice[k3..][0..W].*;
                        const bsv: V = bs_slice[k3..][0..W].*;
                        g_cos_acc += gv * bcv;
                        g_sin_acc += gv * bsv;
                    }
                    var g_cos_h: f64 = @reduce(.Add, g_cos_acc);
                    var g_sin_h: f64 = @reduce(.Add, g_sin_acc);
                    while (k3 < nt) : (k3 += 1) {
                        g_cos_h += g_slice[k3] * bc_slice[k3];
                        g_sin_h += g_slice[k3] * bs_slice[k3];
                    }
                    gc[hi + 1] = 2.0 * g_cos_h / nt_f;
                    gs[hi + 1] = 2.0 * g_sin_h / nt_f;
                }

                const row_dc = row * nf;
                const col_dc = col * nf;
                jac[row_dc * total_unknowns + col_dc] = gc[0] * 0.5;

                for (1..nh + 1) |h| {
                    const row_cos = row * nf + 2 * h - 1;
                    const row_sin = row * nf + 2 * h;
                    // The DC row takes the half-weight projection, the DC
                    // column the full one.
                    jac[row_dc * total_unknowns + col_dc + 2 * h - 1] = gc[h] * 0.5;
                    jac[row_dc * total_unknowns + col_dc + 2 * h] = gs[h] * 0.5;
                    jac[row_cos * total_unknowns + col_dc] = gc[h];
                    jac[row_sin * total_unknowns + col_dc] = gs[h];

                    for (1..nh + 1) |m| {
                        const diff = @as(isize, @intCast(h)) - @as(isize, @intCast(m));
                        const adiff: usize = @abs(diff);
                        const c_diff = gc[adiff];
                        const s_diff = if (diff < 0) -gs[adiff] else gs[adiff];
                        const sum = h + m;
                        const c_sum = gc[sum];
                        const s_sum = gs[sum];

                        const col_cos = col * nf + 2 * m - 1;
                        const col_sin = col * nf + 2 * m;
                        jac[row_cos * total_unknowns + col_cos] = 0.5 * (c_diff + c_sum);
                        jac[row_cos * total_unknowns + col_sin] = 0.5 * (s_sum - s_diff);
                        jac[row_sin * total_unknowns + col_cos] = 0.5 * (s_sum + s_diff);
                        jac[row_sin * total_unknowns + col_sin] = 0.5 * (c_diff - c_sum);
                    }
                }
            }
        }

        // Charge Jacobian: +-w_h*C skew blocks.
        // ponytail: C(t0), not the C(t) convolution G gets. Exact for linear
        // charge and quasi-Newton otherwise; the residual is exact either
        // way, so the fixed point is right. Convolve C like G if a
        // nonlinear-charge deck converges too slowly.
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

                    jac[row_cos * total_unknowns + col_sin] += omega_h * c_val;
                    jac[row_sin * total_unknowns + col_cos] += -omega_h * c_val;
                }
            }
        }

        // ponytail: one dense n*(2K+1) system on the CPU; a GPU dense LU
        // (cuSOLVER getrf/getrs) replaces it past ~256 unknowns.
        try dense_lu.factorizeSolveNeg(total_unknowns, jac, f_hat[0..total_unknowns], dx_hat);

        simdCopy(x_prev, x_hat);
        num.axpy(x_hat, step, dx_hat);
    }

    const final_norm = num.normInf(f_hat);
    extractSpectra(x_hat, probes, spectra, nf);
    return .{ .converged = false, .iterations = options.max_iter, .residual_norm = final_norm };
}

/// Copies each probed node's [dc, cos_1, sin_1, ...] block out of x_hat,
/// whose per-node layout `spectra` shares.
fn extractSpectra(x_hat: []const f64, probes: []const u32, spectra: []f64, nf: usize) void {
    for (probes, 0..) |node, p|
        simdCopy(spectra[p * nf ..][0..nf], x_hat[node * nf ..][0..nf]);
}

/// Contract entry: harmonic magnitudes per probe as point-major rows
/// (frequency = k*f0, probes...) for k = 0 .. n_harmonics; the DC row keeps
/// its sign. Non-convergence is error.HbDidNotConverge.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const nf: usize = 2 * @as(usize, opts.n_harmonics) + 1;

    const scratch = ctx.scratch_allocator;
    const spectra = try scratch.alloc(f64, ctx.probes.len * nf);
    defer scratch.free(spectra);
    const st = try solve(ctx.circuit, ctx.probes, spectra, opts, scratch);
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
