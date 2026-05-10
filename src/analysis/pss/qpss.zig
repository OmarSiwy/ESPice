//! Quasi-periodic steady state: two-tone harmonic balance over the
//! (2K1+1) x (2K2+1) mix-product grid k*f1 + l*f2, solved by Newton with
//! matrix-free GMRES. Residual and Jacobian-vector products are DFT
//! sandwiches: IDFT to the sample grid, evaluate, DFT back plus jw*Q.
const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const solvers = @import("solver");
const gmres_mod = solvers.gmres;
const dense_lu = solvers.dense_lu;
const num = @import("core").numerics;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = @import("core").query.Qpss;

pub const SolveResult = @import("pss.zig").SolveResult;

/// The mix-product grid: k in -K1..K1 varies fastest, l in -K2..K2 slowest,
/// flat index (l + K2) * (2K1+1) + (k + K1).
const MixGrid = struct {
    k1: u16,
    k2: u16,
    nf1: usize, // 2*K1+1
    nf2: usize, // 2*K2+1
    nf: usize, // nf1 * nf2
    pub fn init(k1: u16, k2: u16) MixGrid {
        const nf1 = 2 * @as(usize, k1) + 1;
        const nf2 = 2 * @as(usize, k2) + 1;
        return .{ .k1 = k1, .k2 = k2, .nf1 = nf1, .nf2 = nf2, .nf = nf1 * nf2 };
    }

    pub fn flatIdx(self: MixGrid, k_signed: i32, l_signed: i32) usize {
        const k_off: usize = @intCast(k_signed + @as(i32, self.k1));
        const l_off: usize = @intCast(l_signed + @as(i32, self.k2));
        return l_off * self.nf1 + k_off;
    }

    pub fn signedKL(self: MixGrid, flat: usize) struct { k: i32, l: i32 } {
        const l_off = flat / self.nf1;
        const k_off = flat % self.nf1;
        return .{
            .k = @as(i32, @intCast(k_off)) - @as(i32, self.k1),
            .l = @as(i32, @intCast(l_off)) - @as(i32, self.k2),
        };
    }

    /// Angular frequency of a mix product: 2*pi*(k*f1 + l*f2).
    pub fn omega(self: MixGrid, flat: usize, f1: f64, f2: f64) f64 {
        const kl = self.signedKL(flat);
        return 2.0 * std.math.pi * (@as(f64, @floatFromInt(kl.k)) * f1 +
            @as(f64, @floatFromInt(kl.l)) * f2);
    }
};

/// Everything the residual and the GMRES matvec read. Spectra are stacked
/// real: [re of every node; im of every node], nf entries per node. Time
/// arrays are node-major, sample-contiguous.
const OperatorCtx = struct {
    ckt: *root.Circuit,
    grid: MixGrid,
    n: usize,
    f1: f64,
    f2: f64,

    /// Time samples of the current iterate, n * nf.
    x_td: []f64,
    /// Dense G at every sample, (row*n + col) * nf + s.
    g_td: []f64,
    /// Dense C at sample 0, n * n.
    c_mat: []f64,
    /// Matvec scratch, n * nf each.
    v_td: []f64,
    w_td: []f64,
    /// The instant of each grid point, nf; see buildSampleTimes.
    times: []f64,
    /// Forward (DFT) basis, frequency-major: [f*nf + s].
    basis_cos: []f64,
    basis_sin: []f64,
    /// Inverse (IDFT) basis, sample-major: [s*nf + f].
    basis_cos_t: []f64,
    basis_sin_t: []f64,
    /// Per-sample eval input, n.
    x_sample: []f64,
    /// Dense G extraction scratch, n * n.
    g_buf: []f64,

    pub const matvec = jacobianMatvec;
};

/// Scratch `buildTransform` needs, in f64 and in u32.
fn transformWork(nf: usize) struct { f64s: usize, u32s: usize } {
    const m = 2 * nf;
    return .{ .f64s = m * m + 2 * m, .u32s = m };
}

/// Builds the transform Gamma[s][f] = e^{j w_f t_s} at the given instants
/// and its exact inverse, in the layouts `idft2D` and `dft2D` read:
///
///   basis_cos_t[s*nf+f], basis_sin_t[s*nf+f] = Re Gamma[s][f], Im Gamma[s][f]
///   basis_cos[f*nf+s],   basis_sin[f*nf+s]   = nf*Re Gamma^-1[f][s], -nf*Im Gamma^-1[f][s]
///
/// (nf and the sign absorb the 1/nf and the -Im that `dft2D` applies).
/// Incommensurate tones have no instants that are exact torus points for
/// both, so the orthogonal DFT basis would leak each tone into every mix
/// product at the level of the phase error. Gamma^-1 is exact at whatever
/// instants Gamma came from; good instants only keep it well conditioned.
/// ponytail: one (2nf)^2 dense LU and nf solves per analysis (nf <= 121 at
/// the default truncation); no structure exploited.
fn buildTransform(
    grid: MixGrid,
    f1: f64,
    f2: f64,
    times: []const f64,
    basis_cos: []f64,
    basis_sin: []f64,
    basis_cos_t: []f64,
    basis_sin_t: []f64,
    work: []f64,
    piv: []u32,
) !void {
    const nf = grid.nf;
    const m = 2 * nf; // real embedding of the complex nf x nf system
    const gamma = work[0 .. m * m];
    const rhs = work[m * m ..][0..m];
    const sol = work[m * m + m ..][0..m];

    simdZero(gamma);
    for (0..nf) |s| {
        for (0..nf) |f| {
            const angle = grid.omega(f, f1, f2) * times[s];
            const c = @cos(angle);
            const sn = @sin(angle);
            basis_cos_t[s * nf + f] = c;
            basis_sin_t[s * nf + f] = sn;
            // [ Re -Im ]
            // [ Im  Re ]
            gamma[s * m + f] = c;
            gamma[s * m + nf + f] = -sn;
            gamma[(nf + s) * m + f] = sn;
            gamma[(nf + s) * m + nf + f] = c;
        }
    }

    try dense_lu.factorize(m, gamma, piv);
    const nf_f: f64 = @floatFromInt(nf);
    for (0..nf) |s| {
        simdZero(rhs);
        rhs[s] = 1.0; // column s of the identity, zero imaginary part
        dense_lu.solveFactored(m, gamma, piv, rhs, sol);
        for (0..nf) |f| {
            basis_cos[f * nf + s] = nf_f * sol[f];
            basis_sin[f * nf + s] = -nf_f * sol[nf + f];
        }
    }
}

/// IDFT, unscaled: x_td[node*nf + s] = sum_f (X_re[f]*cos[f,s] - X_im[f]*sin[f,s]).
/// The sample-major basis makes each sample's frequency row one vector load.
fn idft2D(
    x_td: []f64,
    x_re: []const f64,
    x_im: []const f64,
    basis_cos_t: []const f64,
    basis_sin_t: []const f64,
    n: usize,
    nf: usize,
) void {
    for (0..n) |node| {
        const base = node * nf;
        for (0..nf) |s| {
            const bc_row = basis_cos_t[s * nf ..][0..nf];
            const bs_row = basis_sin_t[s * nf ..][0..nf];

            var val: f64 = 0;
            var f_idx: usize = 0;
            while (f_idx + W <= nf) : (f_idx += W) {
                const bc: V = bc_row[f_idx..][0..W].*;
                const bs: V = bs_row[f_idx..][0..W].*;
                const xr: V = x_re[base + f_idx ..][0..W].*;
                const xi: V = x_im[base + f_idx ..][0..W].*;
                val += @reduce(.Add, xr * bc - xi * bs);
            }
            while (f_idx < nf) : (f_idx += 1) {
                val += x_re[base + f_idx] * bc_row[f_idx] -
                    x_im[base + f_idx] * bs_row[f_idx];
            }
            x_td[base + s] = val;
        }
    }
}

/// DFT, scaled by 1/nf: X_re[f] = sum_s f_td[s]*cos[f,s] / nf and
/// X_im[f] = -sum_s f_td[s]*sin[f,s] / nf, per node. With `buildTransform`'s
/// basis this inverts `idft2D` exactly.
fn dft2D(
    out_re: []f64,
    out_im: []f64,
    f_td: []const f64,
    basis_cos: []const f64,
    basis_sin: []const f64,
    n: usize,
    nf: usize,
) void {
    const inv_nf: f64 = 1.0 / @as(f64, @floatFromInt(nf));

    for (0..n) |node| {
        const base = node * nf;
        for (0..nf) |f_idx| {
            const bc_base = f_idx * nf;

            var cos_acc: V = @splat(0.0);
            var sin_acc: V = @splat(0.0);
            var s: usize = 0;
            while (s + W <= nf) : (s += W) {
                const fv: V = f_td[base + s ..][0..W].*;
                const bcv: V = basis_cos[bc_base + s ..][0..W].*;
                const bsv: V = basis_sin[bc_base + s ..][0..W].*;
                cos_acc += fv * bcv;
                sin_acc += fv * bsv;
            }
            var cos_sum: f64 = @reduce(.Add, cos_acc);
            var sin_sum: f64 = @reduce(.Add, sin_acc);
            while (s < nf) : (s += 1) {
                cos_sum += f_td[base + s] * basis_cos[bc_base + s];
                sin_sum += f_td[base + s] * basis_sin[bc_base + s];
            }
            out_re[base + f_idx] = cos_sum * inv_nf;
            out_im[base + f_idx] = -sin_sum * inv_nf;
        }
    }
}

/// Distance between two phases in cycles, wrapped to [0, 0.5].
inline fn cycleErr(phase: f64, target: f64) f64 {
    const d = phase - target;
    return @abs(d - @round(d));
}

/// One scalar instant per mix-grid point, since a device reads one clock.
/// Tone 1 is exact at t = (s1/nf1 + m)/f1 for every integer m, so m is spent
/// on tone 2: the m in [0, 4096) whose frac(f2*t) lands closest to s2/nf2.
/// The leftover phase error only affects conditioning (`buildTransform`
/// inverts whatever these instants generate); f64 phase resolution at
/// t = O(horizon/f1) caps the horizon.
/// ponytail: linear scan, O(nf * horizon) once per analysis. A
/// continued-fraction search of f2/f1 would get there in O(log) steps if the
/// horizon ever has to grow.
fn buildSampleTimes(times: []f64, grid: MixGrid, f1: f64, f2: f64) void {
    const horizon: usize = 1 << 12;
    const rho = f2 / f1;
    const nf1_f: f64 = @floatFromInt(grid.nf1);
    const nf2_f: f64 = @floatFromInt(grid.nf2);
    for (0..grid.nf) |s| {
        const phase1 = @as(f64, @floatFromInt(s % grid.nf1)) / nf1_f;
        const target = @as(f64, @floatFromInt(s / grid.nf1)) / nf2_f;
        var best_u = phase1;
        var best_err = std.math.inf(f64);
        for (0..horizon) |m| {
            const u = phase1 + @as(f64, @floatFromInt(m));
            const err = cycleErr(rho * u, target);
            if (err < best_err) {
                best_err = err;
                best_u = u;
            }
        }
        times[s] = best_u / f1;
    }
}

/// F(X) = DFT(f(IDFT(X))) + jW*DFT(q(IDFT(X))), stacked real. Also refreshes
/// the linearization the matvec reads: g_td at every sample and c_mat at
/// sample 0.
fn computeResidual(
    ctx: *OperatorCtx,
    x_hat: []const f64,
    residual: []f64,
) void {
    const n = ctx.n;
    const nf = ctx.grid.nf;
    const total_re = n * nf;

    const x_re = x_hat[0..total_re];
    const x_im = x_hat[total_re..][0..total_re];

    idft2D(ctx.x_td, x_re, x_im, ctx.basis_cos_t, ctx.basis_sin_t, n, nf);

    // ponytail: the nf evals are independent; ckt.eval already uses the
    // thread pool, and a GPU batch launch would take the whole loop.
    const ckt = ctx.ckt;

    for (0..nf) |s| {
        for (0..n) |node| ctx.x_sample[node] = ctx.x_td[node * nf + s];

        // Each grid point is its own instant, in the transient phase so the
        // sources follow their waveforms (§4.6.1).
        ckt.setSimState(.{ .t = ctx.times[s], .kind = .tran });
        ckt.eval(ctx.x_sample[0..n], ctx.times[s]);

        for (0..n) |node| ctx.w_td[node * nf + s] = ckt.rhs[node];
        // q(t_s) for the charge term; v_td is free until the next matvec.
        for (0..n) |node| ctx.v_td[node * nf + s] = ckt.q_vec[node];

        ckt.denseG(ctx.g_buf[0 .. n * n]);
        for (0..n) |row| {
            for (0..n) |col| {
                ctx.g_td[(row * n + col) * nf + s] = ctx.g_buf[row * n + col];
            }
        }

        if (s == 0) {
            if (ckt.has_charge) {
                ckt.denseC(ctx.c_mat);
            } else {
                simdZero(ctx.c_mat);
            }
        }
    }

    const res_re = residual[0..total_re];
    const res_im = residual[total_re..][0..total_re];
    dft2D(res_re, res_im, ctx.w_td, ctx.basis_cos, ctx.basis_sin, n, nf);

    // jW*Q from the DFT of q(t_s), exact for nonlinear charge; same
    // projection and sign as dft2D.
    // ponytail: scalar O(n*nf^2), the order of dft2D. The matvec keeps the
    // C(t0) Jacobian (quasi-Newton for nonlinear charge).
    if (ckt.has_charge) {
        const inv_nf: f64 = 1.0 / @as(f64, @floatFromInt(nf));
        for (0..n) |node| {
            const q_slice = ctx.v_td[node * nf ..][0..nf];
            for (0..nf) |f_idx| {
                const omega_f = ctx.grid.omega(f_idx, ctx.f1, ctx.f2);
                if (omega_f == 0) continue;
                var q_re: f64 = 0;
                var q_im: f64 = 0;
                for (q_slice, ctx.basis_cos[f_idx * nf ..][0..nf], ctx.basis_sin[f_idx * nf ..][0..nf]) |q, bc, bs| {
                    q_re += q * bc;
                    q_im -= q * bs;
                }
                res_re[node * nf + f_idx] += omega_f * (-q_im * inv_nf);
                res_im[node * nf + f_idx] += omega_f * (q_re * inv_nf);
            }
        }
    }
}

/// GMRES matvec: w = DFT(G(t_s) * IDFT(v)) + jW*C*v, stacked real, against
/// the linearization of the last `computeResidual`.
/// ponytail: the QPSS hot loop, O(n^2*nf) for the G products plus two
/// O(n*nf^2) transforms per call, all on the CPU. A GPU version would keep
/// the spectral slab resident and fuse IDFT, the nf batched G*v products and
/// the DFT into one launch; it needs a gpu_hook entry point for it. Add when
/// a profile shows host-device latency dominating.
fn jacobianMatvec(ctx: *OperatorCtx, v: []const f64, w: []f64) void {
    const n = ctx.n;
    const nf = ctx.grid.nf;
    const total_re = n * nf;

    // GMRES passes disjoint input and output slabs.
    const v_re = v[0..total_re];
    const v_im = v[total_re..][0..total_re];
    const w_re = w[0..total_re];
    const w_im = w[total_re..][0..total_re];

    idft2D(ctx.v_td, v_re, v_im, ctx.basis_cos_t, ctx.basis_sin_t, n, nf);

    gvProduct(ctx.w_td, ctx.g_td, ctx.v_td, n, nf);

    dft2D(w_re, w_im, ctx.w_td, ctx.basis_cos, ctx.basis_sin, n, nf);

    addChargeTerms(ctx, v_re, v_im, w_re, w_im);
}

/// Time-domain Jacobian-vector product w_td[., s] = G(t_s) * v_td[., s].
/// Samples are contiguous in both g_td and v_td, so W samples ride in one
/// vector while each lane walks the columns in order. The scalar tail is the
/// width-one oracle; the test drives both. Overwrites every w_td slot.
fn gvProduct(w_td: []f64, g_td: []const f64, v_td: []const f64, n: usize, nf: usize) void {
    for (0..n) |row| {
        const g_row = g_td[row * n * nf ..][0 .. n * nf];
        var s: usize = 0;
        while (s + W <= nf) : (s += W) {
            var acc: V = @splat(0.0);
            for (0..n) |col| {
                const gv: V = g_row[col * nf + s ..][0..W].*;
                const vv: V = v_td[col * nf + s ..][0..W].*;
                acc += gv * vv;
            }
            w_td[row * nf + s ..][0..W].* = acc;
        }
        while (s < nf) : (s += 1) {
            var acc: f64 = 0;
            for (0..n) |col| {
                acc += g_row[col * nf + s] * v_td[col * nf + s];
            }
            w_td[row * nf + s] = acc;
        }
    }
}

/// Adds j*w_f*C*X in stacked-real form, skipping DC and zero C entries.
inline fn addChargeTerms(
    ctx: *const OperatorCtx,
    x_re: []const f64,
    x_im: []const f64,
    res_re: []f64,
    res_im: []f64,
) void {
    const n = ctx.n;
    const nf = ctx.grid.nf;
    for (0..nf) |f_idx| {
        const omega_f = ctx.grid.omega(f_idx, ctx.f1, ctx.f2);
        if (omega_f == 0) continue;

        for (0..n) |row| {
            var sum_re: f64 = 0;
            var sum_im: f64 = 0;
            for (0..n) |col| {
                const c_val = ctx.c_mat[row * n + col];
                if (c_val == 0) continue;
                sum_re += c_val * (-x_im[col * nf + f_idx]);
                sum_im += c_val * x_re[col * nf + f_idx];
            }
            res_re[row * nf + f_idx] += omega_f * sum_re;
            res_im[row * nf + f_idx] += omega_f * sum_im;
        }
    }
}

/// Newton with unpreconditioned GMRES from X = 0; the deck's sources drive
/// the residual. The caller owns spectra_re/spectra_im, probes.len * nf each,
/// probe-major in MixGrid order. Memory is O(n^2 * nf) for the dense G samples.
pub fn solve(
    ckt: *root.Circuit,
    probes: []const u32,
    spectra_re: []f64,
    spectra_im: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const grid = MixGrid.init(options.k1, options.k2);
    const nf = grid.nf;
    const total_re = n * nf;
    const total = total_re * 2; // stacked real

    const arena_size =
        total + // x_hat
        total + // residual
        total + // dx (Newton step)
        n * nf + // x_td
        n * nf + // v_td
        n * nf + // w_td
        n * n * nf + // g_td
        n * n + // c_mat
        nf * nf + // basis_cos
        nf * nf + // basis_sin
        nf * nf + // basis_cos_t
        nf * nf + // basis_sin_t
        nf + // times
        n + // x_sample
        n * n; // g_buf

    const arena = try allocator.alloc(f64, arena_size);
    defer allocator.free(arena);

    var off: usize = 0;
    const x_hat = arena[off..][0..total];
    off += total;
    const residual = arena[off..][0..total];
    off += total;
    const dx = arena[off..][0..total];
    off += total;
    const x_td = arena[off..][0 .. n * nf];
    off += n * nf;
    const v_td = arena[off..][0 .. n * nf];
    off += n * nf;
    const w_td = arena[off..][0 .. n * nf];
    off += n * nf;
    const g_td = arena[off..][0 .. n * n * nf];
    off += n * n * nf;
    const c_mat = arena[off..][0 .. n * n];
    off += n * n;
    const basis_cos = arena[off..][0 .. nf * nf];
    off += nf * nf;
    const basis_sin = arena[off..][0 .. nf * nf];
    off += nf * nf;
    const basis_cos_t = arena[off..][0 .. nf * nf];
    off += nf * nf;
    const basis_sin_t = arena[off..][0 .. nf * nf];
    off += nf * nf;
    const times = arena[off..][0..nf];
    off += nf;
    const x_sample = arena[off..][0..n];
    off += n;
    const g_buf = arena[off..][0 .. n * n];
    off += n * n;
    std.debug.assert(off == arena_size);

    simdZero(x_hat);

    buildSampleTimes(times, grid, options.f1, options.f2);
    {
        const need = transformWork(nf);
        const work = try allocator.alloc(f64, need.f64s);
        defer allocator.free(work);
        const piv = try allocator.alloc(u32, need.u32s);
        defer allocator.free(piv);
        try buildTransform(grid, options.f1, options.f2, times, basis_cos, basis_sin, basis_cos_t, basis_sin_t, work, piv);
    }

    var op_ctx = OperatorCtx{
        .ckt = ckt,
        .grid = grid,
        .n = n,
        .f1 = options.f1,
        .f2 = options.f2,
        .x_td = x_td,
        .g_td = g_td,
        .c_mat = c_mat,
        .v_td = v_td,
        .w_td = w_td,
        .times = times,
        .basis_cos = basis_cos,
        .basis_sin = basis_sin,
        .basis_cos_t = basis_cos_t,
        .basis_sin_t = basis_sin_t,
        .x_sample = x_sample,
        .g_buf = g_buf,
    };

    // No preconditioner: solver/preconditioner.zig's block-diagonal form is
    // sideband-major at w = p*2*pi*f1, while this system is node-major at the
    // mix frequencies k*f1 + l*f2, so neither its indexing nor its w fits.
    // ponytail: the systems here are 2*n*nf <= a few hundred unknowns, and
    // unrestarted GMRES handles their conditioning (restart 30 stalled on a
    // 90-unknown two-tone deck with a 1e4 spread). Below 512 unknowns the
    // restart depth is the whole system (~2 MB of basis at 512); past it the
    // requested depth stands. The upgrade is a node-major block preconditioner
    // with one sparse (G0 + j*w_kl*C0) factor per mix product.
    const want_m: usize = if (total <= 512) total else options.gmres_restart;
    const gmres_m: u32 = @intCast(@min(want_m, total));
    var gmres = try gmres_mod.Gmres(f64).init(allocator, @intCast(total), gmres_m);
    defer gmres.deinit(allocator);

    var iter: u16 = 0;
    while (iter < options.max_newton) : (iter += 1) {
        if (iter != 0) try ckt.checkpoint(.{ .phase = .harmonic, .completed = iter });
        computeResidual(&op_ctx, x_hat, residual);

        const res_norm = num.normInf(residual);
        if (res_norm < options.hb_tol) {
            extractSpectra2D(x_hat, probes, spectra_re, spectra_im, n, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = res_norm };
        }

        // J dx = -F.
        num.scale(residual, -1.0, residual);
        simdZero(dx);

        _ = gmres.solve(&op_ctx, residual, dx, options.gmres_tol, options.gmres_max_restarts);

        num.axpy(x_hat, 1.0, dx);
    }

    computeResidual(&op_ctx, x_hat, residual);
    const final_norm = num.normInf(residual);

    extractSpectra2D(x_hat, probes, spectra_re, spectra_im, n, nf);
    return .{ .converged = false, .iterations = options.max_newton, .residual_norm = final_norm };
}

/// Copies each probed node's re and im spectra out of the stacked-real x_hat.
fn extractSpectra2D(
    x_hat: []const f64,
    probes: []const u32,
    spectra_re: []f64,
    spectra_im: []f64,
    n: usize,
    nf: usize,
) void {
    const total_re = n * nf;
    for (probes, 0..) |node, p| {
        const re_src = x_hat[node * nf ..][0..nf];
        const im_src = x_hat[total_re + node * nf ..][0..nf];
        simdCopy(spectra_re[p * nf ..][0..nf], re_src);
        simdCopy(spectra_im[p * nf ..][0..nf], im_src);
    }
}

/// Contract entry: one row per mix product (frequency k*f1 + l*f2, then each
/// probe's |X_kl|). The grid is two-sided, so a real tone splits across its
/// +-(k, l) conjugate pair and its amplitude is twice one line's magnitude
/// (DC excepted). Non-convergence is error.QpssDidNotConverge.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const grid = MixGrid.init(opts.k1, opts.k2);
    const nf = grid.nf;

    const scratch = ctx.scratch_allocator;
    const spectra_re = try scratch.alloc(f64, ctx.probes.len * nf);
    defer scratch.free(spectra_re);
    const spectra_im = try scratch.alloc(f64, ctx.probes.len * nf);
    defer scratch.free(spectra_im);

    const st = try solve(ctx.circuit, ctx.probes, spectra_re, spectra_im, opts, scratch);

    if (!st.converged) return error.QpssDidNotConverge;

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s);
        a.free(names);
    }
    const ncols = names.len;

    const n_rows = nf;
    const data = try a.alloc(f64, n_rows * ncols);

    for (0..n_rows) |row_idx| {
        const row = data[row_idx * ncols ..][0..ncols];
        const kl = grid.signedKL(row_idx);
        const freq = @as(f64, @floatFromInt(kl.k)) * opts.f1 +
            @as(f64, @floatFromInt(kl.l)) * opts.f2;
        row[0] = freq;

        for (0..ctx.probes.len) |p| {
            const re_slice = spectra_re[p * nf ..][0..nf];
            const im_slice = spectra_im[p * nf ..][0..nf];
            const r = re_slice[row_idx];
            const i = im_slice[row_idx];
            row[p + 1] = @sqrt(r * r + i * i);
        }
    }

    return .{
        .plotname = "Quasi-Periodic Steady State",
        .varnames = names,
        .is_complex = false,
        .npoints = n_rows,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .MixGrid = MixGrid,
    .buildTransform = buildTransform,
    .transformWork = transformWork,
    .dft2D = dft2D,
    .gvProduct = gvProduct,
    .idft2D = idft2D,
    .buildSampleTimes = buildSampleTimes,
    .simdZero = simdZero,
} else {};
