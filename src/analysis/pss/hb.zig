//! Harmonic Balance: Newton on the spectral residual. Time-domain device
//! evals (IDFT samples) meet frequency-domain charge terms (j*omega*h*C);
//! one dense frequency-domain Jacobian per iteration.
//!
//! Algorithm (from pss-shooting-harmonic-balance.md §3):
//!   X = 0  (Fourier coefficients: [dc, cos_1, sin_1, ..., cos_K, sin_K] per node)
//!   for iter:
//!     x_td = IDFT(X)                    — 2K+1 time samples per node
//!     for each sample k: eval(x_td[:,k]) at t_k, analysis("tran")
//!                         — fills F (source waveform included) and analytic G
//!                         (k==0: capture C)
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

/// Harmonic Balance solve. The excitation is whatever the deck's source cards
/// put in the residual at each time sample — see the eval loop below.
///
/// Caller owns `spectra`: probes.len * (2*n_harmonics+1) flat, probe-major —
/// spectra[p*nf..][0..nf] = [dc, cos_1, sin_1, ..., cos_N, sin_N].
pub fn solve(
    ckt: *root.Circuit,
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
    const nf_f: f64 = @floatFromInt(nf);
    const dt_sample: f64 = period / nf_f;

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
        n * n + // g_sample (denseG scatter temp)
        total_unknowns + // x_prev (line-search rewind point)
        2 * (nh + 1); // gc / gs: one node pair's G(t) spectrum

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
    const x_prev = arena[off..][0..total_unknowns];
    off += total_unknowns;
    const gc = arena[off..][0 .. nh + 1];
    off += nh + 1;
    const gs = arena[off..][0 .. nh + 1];
    off += nh + 1;
    std.debug.assert(off == total_f64);

    root.zeroSimd(x_hat);

    // DC seed: solve the DC operating point via converger.run + EvalHook,
    // which routes through gpu_hook.solve_newton when GPU is active.
    // Seeding x_hat[dc] from the true DC op dramatically reduces HB iterations
    // for circuits with a nontrivial bias point.
    {
        const ws = try ckt.workspace();
        ckt.setSimState(.{ .kind = .dc });
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

    // Backtracking line search. Newton's full step overshoots badly once a
    // source is actually applied — a diode sees the whole swing in one step and
    // answers with exp(2/vt), so `hb/diode_rectifier_rc` ran the iteration
    // limit out. The search reuses the loop's OWN residual evaluation rather
    // than adding a second one: a step that made the residual worse (or
    // non-finite, hence the negated comparison) is undone from `x_prev` and
    // retried at half the length, and a step that helped earns the length back.
    var step: f64 = 1.0;
    var prev_residual: f64 = std.math.inf(f64);
    var retrying = false;

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
        //
        // Sample k IS the circuit at t_k = k*T/nf, and §4.6.1 only lets a
        // source waveform exist while `analysis("tran")` is true. Both were
        // missing: every sample was evaluated at t = 0 in whatever phase the
        // shared operating point left behind, so a SIN/PULSE/PWL card answered
        // with one DC value for the whole period and HB balanced an undriven
        // circuit. The deck's excitation enters here and nowhere else.
        // ponytail: nf evals are independent — GPU batch kernel dispatches all
        // samples in one launch, upgrade path from serial ckt.eval loop
        for (0..nf) |k| {
            const t_k = period * @as(f64, @floatFromInt(k)) / nf_f;
            for (0..n) |node| x_sample[node] = x_td[node * nf + k];
            ckt.setSimState(.{ .t = t_k, .dt = dt_sample, .kind = .tran });
            ckt.eval(x_sample, t_k);
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

        // DFT: time-domain residuals -> frequency domain
        // Node-major f_td[node * nf + k] means contiguous vector loads over k
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

        // Add frequency-domain charge terms: the (cos, sin) coefficients of
        // C dx/dt, in the SAME basis the IDFT above reconstructs x from.
        //   x(t)     = a cos(w_h t) + b sin(w_h t)
        //   dx/dt    = w_h*b cos(w_h t) - w_h*a sin(w_h t)
        // so cos takes +w_h*C*X_sin and sin takes -w_h*C*X_cos. The signs used
        // to be the other pair — the j*omega rule for the phasor X = a + jb,
        // which is the CONJUGATE of this basis's a - jb. Self-consistent with
        // the Jacobian below, so it converged; it just converged on the
        // time-reversed solution, invisible to a magnitude-only oracle but not
        // to a rectifier's signed DC term.
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
                    sum_cos += c_val * (omega_h * x_sin);
                    sum_sin += c_val * (-omega_h * x_cos);
                }
                f_hat[row * nf + 2 * h - 1] += sum_cos;
                f_hat[row * nf + 2 * h] += sum_sin;
            }
        }

        const max_residual = normInf(f_hat);
        if (std.posix.getenv("ESPICE_HB_TRACE") != null) std.debug.print("HB iter={d} res={e} step={e} normx={e}\n", .{ iter, max_residual, step, normInf(x_hat) });
        if (max_residual < options.hb_tol) {
            extractSpectra(x_hat, probes, spectra, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = max_residual };
        }

        if (iter != 0 and !(max_residual <= prev_residual) and step > min_step) {
            // The last step was too long: rewind and retake it shorter. `dx_hat`
            // still holds that direction, so no Jacobian is rebuilt.
            step *= 0.5;
            simdCopy(x_hat, x_prev);
            axpy(x_hat, step, dx_hat);
            retrying = true;
            continue;
        }
        prev_residual = max_residual;
        if (!retrying) step = @min(step * 2.0, 1.0);
        retrying = false;

        // The harmonic-convolution Jacobian. dF/dX is exactly the spectrum of
        // G(t) convolved with the basis, and the product-to-sum identities turn
        // that into DIFFERENCE and SUM terms:
        //
        //   d F_ch / d a_m = ½(Gc[|h-m|] + Gc[h+m])
        //   d F_ch / d b_m = ½(Gs[h+m]   + Gs[m-h])
        //   d F_sh / d a_m = ½(Gs[h+m]   + Gs[h-m])
        //   d F_sh / d b_m = ½(Gc[|h-m|] - Gc[h+m])
        //
        // with Gc[0] = 2·mean(G), Gs[0] = 0, Gs[-d] = -Gs[d], and every index
        // past nh truncated away (the box the analysis was asked for).
        //
        // Only the h = m diagonal and the h ↔ 0 column/row of this used to be
        // built, which is a quasi-Newton matrix that carries NO coupling
        // between two nonzero harmonics — the very term by which a nonlinearity
        // generates them. It converged on the undriven circuit because there
        // was nothing to generate; with the source applied, `hb/diode_clipper`
        // and `hb/diode_rectifier_rc` ran the iteration limit out instead.
        root.zeroSimd(jac);

        for (0..n) |row| {
            for (0..n) |col| {
                const g_slice = g_td[(row * n + col) * nf ..][0..nf];

                // Gc[0] = 2·mean(G); Gc[k>0], Gs[k>0] = the 2/nf projections.
                var g_dc_acc: V = @splat(0.0);
                var k2: usize = 0;
                while (k2 + W <= nf) : (k2 += W) {
                    const gv: V = g_slice[k2..][0..W].*;
                    g_dc_acc += gv;
                }
                var g_sum: f64 = @reduce(.Add, g_dc_acc);
                while (k2 < nf) : (k2 += 1) g_sum += g_slice[k2];
                gc[0] = 2.0 * g_sum / nf_f;
                gs[0] = 0;

                for (0..nh) |hi| {
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
                    gc[hi + 1] = 2.0 * g_cos_h / nf_f;
                    gs[hi + 1] = 2.0 * g_sin_h / nf_f;
                }

                const row_dc = row * nf;
                const col_dc = col * nf;
                jac[row_dc * total_unknowns + col_dc] = gc[0] * 0.5;

                for (1..nh + 1) |h| {
                    const row_cos = row * nf + 2 * h - 1;
                    const row_sin = row * nf + 2 * h;
                    // DC row takes the half-weight projection; DC column the full one.
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
                        const c_sum = if (sum <= nh) gc[sum] else 0;
                        const s_sum = if (sum <= nh) gs[sum] else 0;

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

                    // d(cos coeff of C dx/dt)/d(X_sin) = +omega_h*C
                    jac[row_cos * total_unknowns + col_sin] += omega_h * c_val;
                    // d(sin coeff of C dx/dt)/d(X_cos) = -omega_h*C
                    jac[row_sin * total_unknowns + col_cos] += -omega_h * c_val;
                }
            }
        }

        // ponytail: single dense system of size total_unknowns = n*(2K+1); cuSOLVER
        // dgetrf+dgetrs replaces this when total_unknowns > ~256, add when GPU HB kernel lands
        try dense_lu.factorizeSolveNeg(total_unknowns, jac, f_hat[0..total_unknowns], dx_hat);

        simdCopy(x_prev, x_hat);
        axpy(x_hat, step, dx_hat);
    }

    const final_norm = normInf(f_hat);
    extractSpectra(x_hat, probes, spectra, nf);
    return .{ .converged = false, .iterations = options.max_iter, .residual_norm = final_norm };
}

/// The shortest step the line search will take before giving up on shortening.
const min_step: f64 = 1.0 / 1024.0;

/// dst += a * src, over the whole slice.
inline fn axpy(dst: []f64, a: f64, src: []const f64) void {
    const av: V = @splat(a);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const dv: V = dst[i..][0..W].*;
        const sv: V = src[i..][0..W].*;
        dst[i..][0..W].* = dv + av * sv;
    }
    while (i < dst.len) : (i += 1) dst[i] += a * src[i];
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

/// Contract entry: the deck's own source cards drive the solve; harmonic
/// magnitudes per probe. Data layout: point-major rows
/// (frequency = k*f0, probes...), k = 0 (DC, signed) .. n_harmonics.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const nf: usize = 2 * @as(usize, opts.n_harmonics) + 1;

    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
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
