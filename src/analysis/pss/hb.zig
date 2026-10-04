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

/// The `.hb` query; `extra_tones` or `phasors` route it to `mhb.zig`.
pub const Options = @import("core").query.Hb;

/// The Newton outcome, shared with pss and qpss.
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
/// projection vector. Asserts n_harmonics > 0 when autonomous (the
/// phase condition lives on sin_1).
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
    std.debug.assert(options.osc_node == root.GROUND or nh > 0);
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
        idft(x_hat, nh, nt, basis_cos, basis_sin, x_td);

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
        // contiguous run. `project`'s DC is twice the mean.
        const kc = gc[0 .. nh + 1];
        const ks = gs[0 .. nh + 1];
        for (0..n) |node| {
            project(f_td[node * nt ..][0..nt], basis_cos, basis_sin, kc, ks);
            const spec = f_hat[node * nf ..][0..nf];
            spec[0] = 0.5 * kc[0];
            for (1..nh + 1) |h| {
                spec[2 * h - 1] = kc[h];
                spec[2 * h] = ks[h];
            }
        }

        // dq/dt from the DFT of q(t_k), exact for nonlinear charge. With
        // q(t) = a cos(w_h t) + b sin(w_h t), dq/dt = w_h b cos - w_h a sin,
        // so the cos row takes +w_h*Q_sin and the sin row -w_h*Q_cos.
        // They are linear in w0, so q_term is also dF/d(ln w0).
        root.zeroSimd(q_term);
        if (ckt.has_charge) for (0..n) |node| {
            project(q_td[node * nt ..][0..nt], basis_cos, basis_sin, kc, ks);
            for (1..nh + 1) |h| {
                const omega_h = @as(f64, @floatFromInt(h)) * omega0;
                q_term[node * nf + 2 * h - 1] = omega_h * ks[h];
                q_term[node * nf + 2 * h] = -omega_h * kc[h];
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

/// x_td[node*nt + k] = dc + Σ_h c_h·basis_cos[h-1, k] + s_h·basis_sin[h-1, k]
/// for every node of `x_hat` (`solveSpectrum`'s layout, harmonics 1..nh),
/// one contiguous row per node.
fn idft(x_hat: []const f64, nh: usize, nt: usize, basis_cos: []const f64, basis_sin: []const f64, x_td: []f64) void {
    const nf = 2 * nh + 1;
    const n = x_hat.len / nf;
    for (0..n) |node| {
        const spec = x_hat[node * nf ..][0..nf];
        const row = x_td[node * nt ..][0..nt];
        @memset(row, spec[0]);
        for (0..nh) |hi| {
            num.axpy(row, spec[2 * hi + 1], basis_cos[hi * nt ..][0..nt]);
            num.axpy(row, spec[2 * hi + 2], basis_sin[hi * nt ..][0..nt]);
        }
    }
}

/// The spectrum of the samples `g` to harmonic gc.len - 1, in the
/// Jacobian's convention: gc[0] = 2*mean(g), gs[0] = 0, and gc[k], gs[k]
/// the 2/nt cos and sin projections on the harmonic-major bases.
fn project(g: []const f64, basis_cos: []const f64, basis_sin: []const f64, gc: []f64, gs: []f64) void {
    const nt = g.len;
    const nt_f: f64 = @floatFromInt(nt);
    gc[0] = 2.0 * num.sum(g) / nt_f;
    gs[0] = 0;
    for (gc[1..], gs[1..], 0..) |*c, *s, hi| {
        c.* = 2.0 * num.dot(g, basis_cos[hi * nt ..][0..nt]) / nt_f;
        s.* = 2.0 * num.dot(g, basis_sin[hi * nt ..][0..nt]) / nt_f;
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
/// the phase condition `solveSpectrum` holds). Exact while the orbit
/// samples more than 2K points per period; asserts x_hat.len is n * (2K+1)
/// with K >= 1.
pub fn seed(x_hat: []f64, orb: pac.Orbit, n: usize, osc: u32) void {
    const nf = x_hat.len / n;
    const nh = (nf - 1) / 2;
    std.debug.assert(nf * n == x_hat.len and nh > 0);
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

test idft {
    // idft against the term-by-term sum, and back through `project`: on
    // 2(2K+1) points the harmonics 0..K are orthogonal, so a band-limited
    // spectrum round-trips. nt = 14 straddles every vector width.
    const nh = 3;
    const nf = 2 * nh + 1;
    const nt = 2 * nf;
    const n = 2;
    var basis_cos: [2 * nh * nt]f64 = undefined;
    var basis_sin: [2 * nh * nt]f64 = undefined;
    for (0..2 * nh) |hi| for (0..nt) |k| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt((hi + 1) * k)) / nt;
        basis_cos[hi * nt + k] = @cos(angle);
        basis_sin[hi * nt + k] = @sin(angle);
    };
    var prng = std.Random.DefaultPrng.init(0x4B);
    var x_hat: [n * nf]f64 = undefined;
    for (&x_hat) |*v| v.* = prng.random().float(f64) * 2 - 1;
    var x_td: [n * nt]f64 = undefined;
    idft(&x_hat, nh, nt, &basis_cos, &basis_sin, &x_td);

    var gc: [nh + 1]f64 = undefined;
    var gs: [nh + 1]f64 = undefined;
    for (0..n) |node| {
        const spec = x_hat[node * nf ..][0..nf];
        for (0..nt) |k| {
            var want = spec[0];
            for (0..nh) |hi| want += spec[2 * hi + 1] * basis_cos[hi * nt + k] + spec[2 * hi + 2] * basis_sin[hi * nt + k];
            try std.testing.expectApproxEqAbs(want, x_td[node * nt + k], 1e-12);
        }
        project(x_td[node * nt ..][0..nt], &basis_cos, &basis_sin, &gc, &gs);
        try std.testing.expectApproxEqAbs(spec[0], 0.5 * gc[0], 1e-12);
        try std.testing.expectEqual(@as(f64, 0), gs[0]);
        for (1..nh + 1) |h| {
            try std.testing.expectApproxEqAbs(spec[2 * h - 1], gc[h], 1e-12);
            try std.testing.expectApproxEqAbs(spec[2 * h], gs[h], 1e-12);
        }
    }
}

test orbit {
    // orbit samples a spectrum whose osc node (1) is a pure cosine, and
    // seed recovers it: the phase shift it applies is then the identity.
    const gpa = std.testing.allocator;
    const n = 2;
    const nf = 7;
    const ns = 32;
    const x_hat = [n * nf]f64{ 0.5, 0.1, -0.2, 0.03, 0.04, -0.01, 0.02, 1.0, 0.8, 0, 0.1, -0.05, 0.02, 0.01 };
    const orb = try orbit(&x_hat, n, 1e3, ns, true, gpa);
    defer gpa.free(orb.wave);
    try std.testing.expectEqual(@as(usize, ns), orb.samples(n));
    try std.testing.expectApproxEqRel(@as(f64, 1e-3), orb.wave[ns * (n + 1)], 1e-15);
    for (orb.state(0, n), orb.state(ns, n)) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
    // DC plus every amplitude at t = 0.
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 + 0.8 + 0.1 + 0.02), orb.state(0, n)[1], 1e-12);
    var back: [n * nf]f64 = undefined;
    seed(&back, orb, n, 1);
    for (x_hat, back) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-12);
}
