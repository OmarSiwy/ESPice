//! Harmonic balance: Newton on the spectral residual with a backtracking
//! line search. Each iteration IDFTs the unknowns to 2(2K+1) time samples,
//! evaluates the circuit at each (sources included), DFTs the residual and
//! adds the dq/dt terms, then solves one dense harmonic-convolution Jacobian.
//!
//! An oscillator (`Options.osc_node`) trades one unknown for f0: the osc
//! node's sin_1 coefficient stays 0, which fixes the phase, and its Jacobian
//! column becomes dF/d(ln f0). The charge terms are the only place f0
//! enters the residual, and they are linear in it, so that column is the
//! charge terms themselves.
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const num = @import("core").numerics;
const converger = @import("solver").converger;
const dense_lu = @import("solver").dense_lu;
const pac = @import("pac.zig");
const mhb = @import("mhb.zig");

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = @import("core").query.Hb;

pub const SolveResult = @import("pss.zig").SolveResult;

/// `solveSpectrum`'s outcome: the Newton status and the fundamental the
/// spectrum is at, `Options.f0` unless the solve was autonomous.
pub const Spectrum = struct { status: SolveResult, f0: f64 };

/// Time samples per spectral unknown. The 2K+1 collocation points alias
/// the harmonics a nonlinearity generates past K onto the top of the kept
/// band; 2(2K+1) > 4K samples project the residual of any cubic in x(t)
/// onto harmonics 0..K exactly, a Galerkin rather than collocation fit.
const oversample: usize = 2;

/// The shortest step the line search takes before it stops shortening.
const min_step: f64 = 1.0 / 1024.0;

/// True when a driven solve of n unknowns and nf = 2K+1 coefficients each
/// takes `mhb.zig`'s preconditioned GMRES instead of the dense Jacobian.
/// The dense LU is O((n·nf)^3) a step and GMRES O(iterations·n·nf^2), so
/// n decides. Callgrind (docs/analysis/multitone-hb.md): a 4-node diode
/// clipper at K = 32 is 1.23x cheaper dense, a 6-node rectifier at K = 32
/// 1.31x; the diode-RC ladders are cheaper on GMRES by 2.2x at 14 nodes and
/// K = 8, 3.6x at 9 nodes and K = 32, and 16x at 44 nodes and K = 8.
fn useGmres(n: usize, nf: usize) bool {
    return n >= 10 or n * nf >= 512;
}

/// Magnitude of harmonic k >= 1 from one probe's spectrum
/// [dc, cos_1, sin_1, ..., cos_K, sin_K].
fn magnitude(spectrum: []const f64, k: u16) f64 {
    const c = spectrum[2 * @as(usize, k) - 1];
    const s = spectrum[2 * @as(usize, k)];
    return @sqrt(c * c + s * s);
}

/// Harmonic balance from the DC operating point, keeping every unknown's
/// spectrum: `x_hat` (n * (2*n_harmonics+1), caller-owned) receives
/// node-major blocks x_hat[node*nf..][0..nf] = [dc, cos_1, sin_1, ...,
/// cos_K, sin_K], the last iterate when Newton does not converge. `orbit`
/// samples it for the small-signal analyses about the HB solution. The
/// excitation is whatever the deck's sources stamp at each time sample.
/// Memory is O((n*nf)^2) for the dense Jacobian; a driven circuit past
/// `useGmres` solves through `mhb.solveOneTone` instead, O(nnz*nt).
/// Autonomous (`osc_node`
/// set): `x_hat` must arrive holding a seed near the oscillation (`seed`),
/// with f0 its frequency, and the result carries the solved f0. A
/// non-empty `ppv` (autonomous only, x_hat.len long) receives y with
/// J_w^T y = e_w at the solution, J_w the Newton Jacobian with its f0
/// column: the left null vector of the HB Jacobian, normalized so that
/// y . dF/d(ln w0) = 1. phasenoise.zig turns it into the perturbation
/// projection vector.
pub fn solveSpectrum(
    ckt: *root.Circuit,
    x_hat: []f64,
    ppv: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Spectrum {
    const n: usize = ckt.n;
    const nnz: usize = ckt.nnz;
    const nh: usize = options.n_harmonics;
    const nf: usize = 2 * nh + 1;
    const nt: usize = nf * oversample;
    const total_unknowns = n * nf;
    std.debug.assert(x_hat.len == total_unknowns);
    std.debug.assert(ppv.len == 0 or (ppv.len == total_unknowns and options.osc_node != root.GROUND));
    if (options.osc_node == root.GROUND and useGmres(n, nf))
        return .{ .status = try mhb.solveOneTone(ckt, x_hat, options, allocator), .f0 = options.f0 };

    var period: f64 = 1.0 / options.f0;
    var omega0: f64 = 2.0 * std.math.pi * options.f0;
    const nt_f: f64 = @floatFromInt(nt);
    // Autonomous: the unknown the osc node's sin_1 gives up to ln(f0).
    const osc = options.osc_node;
    const omega_col = osc * nf + 2;
    var omega_prev = omega0;
    var d_ln_omega: f64 = 0;
    // Set once converged when the caller wants `ppv`: one more Jacobian.
    var solved: ?Spectrum = null;

    const total_f64 = total_unknowns + // f_hat
        nt * n + // x_td (node-major)
        nt * n + // f_td (node-major)
        nt * n + // q_td (node-major)
        n * n + // c_mat
        total_unknowns * total_unknowns + // jac
        total_unknowns + // dx_hat
        nt * nnz + // g_td (slot-major, samples contiguous)
        (if (ppv.len != 0) nt * nnz else 0) + // c_td: C(t) for the PPV's exact Jacobian
        nt * 2 * nh + // basis_cos (harmonic-major, harmonics 1..2K)
        nt * 2 * nh + // basis_sin
        n + // x_sample (gather buffer for device eval)
        total_unknowns + // x_prev (line-search rewind point)
        total_unknowns + // q_term (charge terms: the autonomous f0 column)
        2 * (2 * nh + 1); // gc / gs: one slot's G(t) spectrum to 2K

    const arena = try allocator.alloc(f64, total_f64);
    defer allocator.free(arena);

    var off: usize = 0;
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
    const c_td = arena[off..][0..if (ppv.len != 0) nt * nnz else 0];
    off += c_td.len;
    const basis_cos = arena[off..][0 .. nt * 2 * nh];
    off += nt * 2 * nh;
    const basis_sin = arena[off..][0 .. nt * 2 * nh];
    off += nt * 2 * nh;
    const x_sample = arena[off..][0..n];
    off += n;
    const x_prev = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const q_term = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const gc = arena[off..][0 .. 2 * nh + 1];
    off += 2 * nh + 1;
    const gs = arena[off..][0 .. 2 * nh + 1];
    off += 2 * nh + 1;
    std.debug.assert(off == total_f64);

    // Seed the DC coefficients with the DC operating point, which cuts the
    // iteration count on biased circuits.
    if (osc == root.GROUND) {
        root.zeroSimd(x_hat);
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

        const dt_sample = period / nt_f;
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
            if (c_td.len != 0) for (ckt.c_vals[0..nnz], 0..) |c, slot| {
                c_td[slot * nt + k] = c;
            };
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
        // They are linear in w0, so q_term is also dF/d(ln w0).
        root.zeroSimd(q_term);
        if (ckt.has_charge) for (0..n) |node| {
            const q_slice = q_td[node * nt ..][0..nt];
            for (0..nh) |hi| {
                const q_cos = num.dot(q_slice, basis_cos[hi * nt ..][0..nt]);
                const q_sin = num.dot(q_slice, basis_sin[hi * nt ..][0..nt]);
                const omega_h = @as(f64, @floatFromInt(hi + 1)) * omega0;
                q_term[node * nf + 2 * (hi + 1) - 1] = omega_h * (2.0 * q_sin / nt_f);
                q_term[node * nf + 2 * (hi + 1)] = -omega_h * (2.0 * q_cos / nt_f);
            }
        };
        num.axpy(f_hat, 1.0, q_term);

        const max_residual = num.normInf(f_hat);
        if (converger.hbTrace()) std.debug.print("HB iter={d} res={e} step={e} normx={e}\n", .{ iter, max_residual, step, num.normInf(x_hat) });
        if (max_residual < options.hb_tol) {
            solved = .{ .status = .{ .converged = true, .iterations = iter + 1, .residual_norm = max_residual }, .f0 = if (osc == root.GROUND) options.f0 else omega0 / (2.0 * std.math.pi) };
            if (ppv.len == 0) return solved.?;
        }

        if (solved == null and iter != 0 and !(max_residual <= prev_residual) and step > min_step) {
            // Rewind and retake the last step at half length along the same
            // `dx_hat`; no Jacobian rebuild.
            step *= 0.5;
            simdCopy(x_hat, x_prev);
            num.axpy(x_hat, step, dx_hat);
            if (osc != root.GROUND) setOmega(&omega0, &period, omega_prev * (1 + step * d_ln_omega));
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

                project(g_slice, basis_cos, basis_sin, gc, gs);

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
        // ponytail: C(t0), not the C(t) convolution G gets, while Newton
        // runs. Exact for linear charge and quasi-Newton otherwise; the
        // residual is exact either way, so the fixed point is right. The
        // PPV's Jacobian convolves C(t) (a varactor converts a slow control
        // voltage into the carrier through it); convolve C on every
        // iteration too if a nonlinear-charge deck converges too slowly.
        if (solved != null and c_td.len != 0) {
            for (0..n) |col| for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |slot| {
                const row: usize = ckt.row_idx[slot];
                project(c_td[slot * nt ..][0..nt], basis_cos, basis_sin, gc, gs);
                // dQ/dt: F_cos_h += w_h Q_sin_h, F_sin_h -= w_h Q_cos_h,
                // with Q = conv(C) x as the G blocks above.
                for (1..nh + 1) |h| {
                    const omega_h = @as(f64, @floatFromInt(h)) * omega0;
                    const row_cos = (row * nf + 2 * h - 1) * total_unknowns;
                    const row_sin = (row * nf + 2 * h) * total_unknowns;
                    const col_dc = col * nf;
                    jac[row_cos + col_dc] += omega_h * gs[h];
                    jac[row_sin + col_dc] -= omega_h * gc[h];
                    for (1..nh + 1) |m| {
                        const diff = @as(isize, @intCast(h)) - @as(isize, @intCast(m));
                        const adiff: usize = @abs(diff);
                        const c_diff = gc[adiff];
                        const s_diff = if (diff < 0) -gs[adiff] else gs[adiff];
                        const c_sum = gc[h + m];
                        const s_sum = gs[h + m];
                        const col_cos = col_dc + 2 * m - 1;
                        jac[row_cos + col_cos] += omega_h * 0.5 * (s_sum + s_diff);
                        jac[row_cos + col_cos + 1] += omega_h * 0.5 * (c_diff - c_sum);
                        jac[row_sin + col_cos] -= omega_h * 0.5 * (c_diff + c_sum);
                        jac[row_sin + col_cos + 1] -= omega_h * 0.5 * (s_sum - s_diff);
                    }
                }
            };
        } else for (0..nh) |hi| {
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

        if (osc != root.GROUND) for (0..total_unknowns) |r| {
            jac[r * total_unknowns + omega_col] = q_term[r];
        };
        if (solved) |done| {
            const piv = try allocator.alloc(u32, total_unknowns);
            defer allocator.free(piv);
            try dense_lu.factorize(total_unknowns, jac, piv);
            root.zeroSimd(f_hat);
            f_hat[omega_col] = 1;
            dense_lu.solveFactoredT(total_unknowns, jac, piv, f_hat, ppv);
            return done;
        }

        // One dense n*(2K+1) system; large driven circuits never get here
        // (`useGmres`). Oscillators still do: their f0 column and `ppv`
        // adjoint are dense-only.
        try dense_lu.factorizeSolveNeg(total_unknowns, jac, f_hat[0..total_unknowns], dx_hat);

        simdCopy(x_prev, x_hat);
        if (osc != root.GROUND) {
            d_ln_omega = dx_hat[omega_col];
            dx_hat[omega_col] = 0;
            omega_prev = omega0;
            setOmega(&omega0, &period, omega0 * (1 + step * d_ln_omega));
        }
        num.axpy(x_hat, step, dx_hat);
    }

    return .{
        .status = .{ .converged = false, .iterations = options.max_iter, .residual_norm = num.normInf(f_hat) },
        .f0 = if (osc == root.GROUND) options.f0 else omega0 / (2.0 * std.math.pi),
    };
}

/// Autonomous HB from the DC point `x_dc`: the oscillator's shooting orbit
/// (`pss.solve` with the same osc node, from the guess `options.f0`) seeds
/// `x_hat` and f0, then `solveSpectrum` refines both. `ppv` as there.
/// error.HbDidNotConverge when the shooting seed does not converge.
pub fn solveOscillator(ckt: *root.Circuit, x_dc: []const f64, x_hat: []f64, ppv: []f64, options: Options, allocator: std.mem.Allocator) !Spectrum {
    // ponytail: HSPICE's HBOSC searches amplitude and frequency from a
    // probe voltage; the shooting orbit is a seed already on the limit
    // cycle, at the cost of one autonomous PSS.
    const n: usize = ckt.n;
    const orb = try pac.orbit(ckt, x_dc, .{ .tol = options.tol, .period = 1 / options.f0, .osc_node = options.osc_node }, allocator);
    defer allocator.free(orb.wave);
    if (!orb.converged) return error.HbDidNotConverge;
    seed(x_hat, orb, n, options.osc_node);
    var opts = options;
    opts.f0 = 1 / orb.wave[orb.samples(n) * (n + 1)];
    return solveSpectrum(ckt, x_hat, ppv, opts, allocator);
}

/// The spectrum of one pattern slot's samples `g` to harmonic 2K, in the
/// Jacobian's convention: gc[0] = 2*mean(g), gs[0] = 0, and gc[k], gs[k]
/// the 2/nt cos and sin projections on the harmonic-major bases.
fn project(g: []const f64, basis_cos: []const f64, basis_sin: []const f64, gc: []f64, gs: []f64) void {
    const nt = g.len;
    const nt_f: f64 = @floatFromInt(nt);
    var g_dc_acc: V = @splat(0.0);
    var k2: usize = 0;
    while (k2 + W <= nt) : (k2 += W) {
        const gv: V = g[k2..][0..W].*;
        g_dc_acc += gv;
    }
    var g_sum: f64 = @reduce(.Add, g_dc_acc);
    while (k2 < nt) : (k2 += 1) g_sum += g[k2];
    gc[0] = 2.0 * g_sum / nt_f;
    gs[0] = 0;

    for (0..gc.len - 1) |hi| {
        const bc_slice = basis_cos[hi * nt ..][0..nt];
        const bs_slice = basis_sin[hi * nt ..][0..nt];
        var g_cos_acc: V = @splat(0.0);
        var g_sin_acc: V = @splat(0.0);
        var k3: usize = 0;
        while (k3 + W <= nt) : (k3 += W) {
            const gv: V = g[k3..][0..W].*;
            const bcv: V = bc_slice[k3..][0..W].*;
            const bsv: V = bs_slice[k3..][0..W].*;
            g_cos_acc += gv * bcv;
            g_sin_acc += gv * bsv;
        }
        var g_cos_h: f64 = @reduce(.Add, g_cos_acc);
        var g_sin_h: f64 = @reduce(.Add, g_sin_acc);
        while (k3 < nt) : (k3 += 1) {
            g_cos_h += g[k3] * bc_slice[k3];
            g_sin_h += g[k3] * bs_slice[k3];
        }
        gc[hi + 1] = 2.0 * g_cos_h / nt_f;
        gs[hi + 1] = 2.0 * g_sin_h / nt_f;
    }
}

/// Moves the autonomous fundamental and the period with it.
fn setOmega(omega0: *f64, period: *f64, omega: f64) void {
    omega0.* = omega;
    period.* = 2.0 * std.math.pi / omega;
}

/// Seeds `x_hat` for an autonomous solve from one period of the
/// oscillator's shooting orbit: the first K harmonics of every unknown,
/// time-shifted so the osc node's fundamental is a pure cosine (sin_1 = 0,
/// the phase condition `solveSpectrum` holds).
pub fn seed(x_hat: []f64, orb: pac.Orbit, n: usize, osc: u32) void {
    const nf = x_hat.len / n;
    const nh = (nf - 1) / 2;
    const ns = orb.samples(n);
    const ns_f: f64 = @floatFromInt(ns);
    root.zeroSimd(x_hat);
    for (0..ns) |k| {
        const x = orb.state(k, n);
        for (0..n) |node| {
            const spec = x_hat[node * nf ..][0..nf];
            spec[0] += x[node] / ns_f;
            for (1..nh + 1) |h| {
                const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt((h * k) % ns)) / ns_f;
                spec[2 * h - 1] += 2.0 * x[node] * @cos(angle) / ns_f;
                spec[2 * h] += 2.0 * x[node] * @sin(angle) / ns_f;
            }
        }
    }
    // Shift t by phi/w0: harmonic h rotates by h*phi.
    const phi = std.math.atan2(x_hat[osc * nf + 2], x_hat[osc * nf + 1]);
    for (0..n) |node| for (1..nh + 1) |h| {
        const c = x_hat[node * nf + 2 * h - 1];
        const s = x_hat[node * nf + 2 * h];
        const a = @as(f64, @floatFromInt(h)) * phi;
        x_hat[node * nf + 2 * h - 1] = c * @cos(a) + s * @sin(a);
        x_hat[node * nf + 2 * h] = s * @cos(a) - c * @sin(a);
    };
    x_hat[osc * nf + 2] = 0;
}

/// One period of the HB solution `x_hat` (`solveSpectrum`'s layout, n
/// unknowns, fundamental `f0`) on `n_samples` uniform points, as the
/// `pac.Orbit` rows [t, x(0..n)] the periodic small-signal analyses
/// linearize about. HB's own grid, 2(2K+1) points, is not a power of two;
/// this one is whatever the caller asks, a power of two for
/// `pac.linearize`. Row k is the band-limited x(k*T/n_samples) exactly, so
/// the last row repeats the first. O(n*K*n_samples). The caller frees
/// `wave` with `allocator`.
pub fn orbit(
    x_hat: []const f64,
    n: usize,
    f0: f64,
    n_samples: usize,
    converged: bool,
    allocator: std.mem.Allocator,
) !pac.Orbit {
    const nf = x_hat.len / n;
    const nh = (nf - 1) / 2;
    const cols = n + 1;
    const wave = try allocator.alloc(f64, (n_samples + 1) * cols);
    errdefer allocator.free(wave);
    // cos/sin of 2*pi*j/n_samples; harmonic h at sample k reads entry
    // (h*k) mod n_samples, so every sample sees the same rounded values.
    const table = try allocator.alloc(f64, 2 * n_samples);
    defer allocator.free(table);
    const ns_f: f64 = @floatFromInt(n_samples);
    for (0..n_samples) |j| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / ns_f;
        table[j] = @cos(angle);
        table[n_samples + j] = @sin(angle);
    }
    for (0..n_samples + 1) |k| {
        const row = wave[k * cols ..][0..cols];
        row[0] = @as(f64, @floatFromInt(k)) / ns_f / f0;
        for (row[1..], 0..) |*x, node| {
            const spec = x_hat[node * nf ..][0..nf];
            var v = spec[0];
            for (1..nh + 1) |h| {
                const j = (h * k) % n_samples;
                v += spec[2 * h - 1] * table[j] + spec[2 * h] * table[n_samples + j];
            }
            x.* = v;
        }
    }
    return .{ .wave = wave, .converged = converged };
}

/// Contract entry: harmonic magnitudes per probe as point-major rows
/// (frequency = k*f0, probes...) for k = 0 .. n_harmonics; the DC row keeps
/// its sign. Non-convergence is error.HbDidNotConverge.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    try ctx.circuit.refuseDigital("hb");
    if (opts.extra_tones.len != 0 or opts.phasors) return mhb.run(ctx, opts);
    const a = ctx.allocator;
    const nf: usize = 2 * @as(usize, opts.n_harmonics) + 1;

    const scratch = ctx.scratch_allocator;
    const x_hat = try scratch.alloc(f64, @as(usize, ctx.circuit.n) * nf);
    defer scratch.free(x_hat);
    const st = if (opts.osc_node != root.GROUND)
        try solveOscillator(ctx.circuit, ctx.x_op, x_hat, &.{}, opts, scratch)
    else
        try solveSpectrum(ctx.circuit, x_hat, &.{}, opts, scratch);
    if (!st.status.converged) return error.HbDidNotConverge;

    const names = try root.probeNames(ctx, "frequency");
    const ncols = names.len;
    const n_rows: usize = @as(usize, opts.n_harmonics) + 1;
    const data = try a.alloc(f64, n_rows * ncols);
    for (0..n_rows) |k| {
        const row = data[k * ncols ..][0..ncols];
        row[0] = @as(f64, @floatFromInt(k)) * st.f0;
        for (ctx.probes, 0..) |node, p| {
            const spec = x_hat[node * nf ..][0..nf];
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
