//! Quasi-Periodic Steady State (QPSS) — QP-HB path with GMRES.
//!
//! Multi-fundamental harmonic balance for incommensurate tones (e.g. RF + LO
//! in a mixer). The unknown is the 2-D (d-dim generalizable) harmonic
//! coefficient vector X_{k,l} for each circuit node, where:
//!
//!   x(t) = Σ_k Σ_l X_{kl} * e^{j2π(k*f1 + l*f2)*t}
//!
//! truncated to K1 harmonics of f1 and K2 harmonics of f2, giving
//! K = (2*K1+1)*(2*K2+1) mix products per node, total unknowns = n * K.
//!
//! Dense Jacobian is infeasible at n*K; we use matrix-free GMRES with a
//! block-circulant preconditioner (one sparse (G0+jω_{kl}C0) factor per
//! mix product).
//!
//! The operator apply is a "DFT sandwich": IDFT to 2-D time grid, per-sample
//! device eval (sparse), DFT back + frequency-domain charge terms.
//!
//! ## GPU acceleration strategy
//!
//! The QPSS inner loop is the GMRES matvec, which executes a DFT sandwich:
//!   1. IDFT: spectrum → nf time-domain samples per node
//!   2. Device eval: ckt.eval() at each sample (nf independent evals)
//!   3. DFT: time-domain results → spectrum + jω_{kl}C charge terms
//!
//! Current GPU integration:
//! - Circuit evaluations route through par_eval when available.
//!
//! ponytail: full GPU DFT-sandwich kernel — the ideal upgrade is a single
//! kernel launch that does all three steps on-device:
//!   (a) IDFT: nf spectral coefficients per node → nf time samples
//!       (dense matrix-vector with precomputed basis, or cuFFT for power-of-2)
//!   (b) Batched device eval: nf independent circuit evaluations in one launch
//!       (same megakernel dispatch as tran/MC, one warp-group per time sample)
//!   (c) DFT + charge: time samples → spectrum, accumulate jω_{kl}C·X_{kl}
//!       (same basis as (a), fused reduce)
//! This eliminates nf host→device round-trips per GMRES iteration.
//! Prerequisite: gpu_hook needs a batch_matvec or dft_sandwich entry point
//! that accepts the full spectral slab and returns the Jacobian-vector product.
//! Add when QPSS runtime is dominated by host↔device latency (profile first).
//!
//! ## DFT normalization convention
//!
//! IDFT (spectrum → time): x_td[s] = Σ_f (X_re[f]*cos[f,s] - X_im[f]*sin[f,s])
//!   — unscaled sum over all mix products.
//!
//! DFT  (time → spectrum): X_re[f] = (1/nf) Σ_s x_td[s]*cos[f,s]
//!                          X_im[f] = -(1/nf) Σ_s x_td[s]*sin[f,s]
//!
//! This is correct for the solver: the IDFT→eval→DFT roundtrip that forms
//! the HB residual F(X) works because the 1/nf in the forward DFT cancels
//! the nf-point summation in the IDFT, giving a consistent fixed-point.
//!
//! Note: for one-sided (non-conjugate-paired) spectral coefficients, a
//! single-frequency roundtrip has a 2x attenuation because the IDFT sums
//! both positive and negative frequency contributions while the DFT projects
//! onto a single-sided basis. This is NOT a bug — the solver operates on
//! the full two-sided coefficient vector and the residual is self-consistent.
//! Physical amplitude extraction should account for conjugate pairs (2x for
//! non-DC, non-Nyquist terms) when interpreting one-sided magnitudes.

const std = @import("std");
const root = @import("../types.zig");
const simdZero = root.zeroSimd;
const simdCopy = root.copySimd;
const converger = @import("solvers").converger;
const solvers = @import("solvers");
const gmres_mod = solvers.gmres;
const precond_mod = solvers.preconditioner;
const infNorm = @import("pss.zig").normInf;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

// ============================================================================
// Options + public types
// ============================================================================

pub const Options = struct {
    tol: converger.Tolerances = .{},
    f1: f64,
    f2: f64,
    k1: u16 = 5,
    k2: u16 = 5,
    max_newton: u16 = 50,
    hb_tol: f64 = 1e-9,
    /// GMRES restart depth (per Newton step)
    gmres_restart: u16 = 30,
    /// Max GMRES restarts per Newton step
    gmres_max_restarts: u16 = 10,
    /// GMRES relative tolerance
    gmres_tol: f64 = 1e-3,
    /// Source excitation magnitude (cosine current at f1 into source_node)
    source_mag: f64 = 1.0,
};

pub const SolveResult = @import("pss.zig").SolveResult;

/// Mix-product index (k, l) → flat index in the harmonic grid.
/// Layout: (2*K1+1) * (2*K2+1) products, k varies fastest (row-major in l).
/// Indices are signed: k in -K1..K1, l in -K2..K2.
/// Flat index = (l + K2) * (2*K1+1) + (k + K1).
const MixGrid = struct {
    k1: u16,
    k2: u16,
    nf1: usize, // 2*K1+1
    nf2: usize, // 2*K2+1
    nf: usize, // nf1 * nf2

    fn init(k1: u16, k2: u16) MixGrid {
        const nf1 = 2 * @as(usize, k1) + 1;
        const nf2 = 2 * @as(usize, k2) + 1;
        return .{ .k1 = k1, .k2 = k2, .nf1 = nf1, .nf2 = nf2, .nf = nf1 * nf2 };
    }

    /// Flat index for signed (k, l) pair.
    fn flatIdx(self: MixGrid, k_signed: i32, l_signed: i32) usize {
        const k_off: usize = @intCast(k_signed + @as(i32, self.k1));
        const l_off: usize = @intCast(l_signed + @as(i32, self.k2));
        return l_off * self.nf1 + k_off;
    }

    /// Signed (k, l) from flat index.
    fn signedKL(self: MixGrid, flat: usize) struct { k: i32, l: i32 } {
        const l_off = flat / self.nf1;
        const k_off = flat % self.nf1;
        return .{
            .k = @as(i32, @intCast(k_off)) - @as(i32, self.k1),
            .l = @as(i32, @intCast(l_off)) - @as(i32, self.k2),
        };
    }

    /// Mix-product angular frequency: ω_{kl} = 2π(k*f1 + l*f2).
    fn omega(self: MixGrid, flat: usize, f1: f64, f2: f64) f64 {
        const kl = self.signedKL(flat);
        return 2.0 * std.math.pi * (@as(f64, @floatFromInt(kl.k)) * f1 +
            @as(f64, @floatFromInt(kl.l)) * f2);
    }
};

// ============================================================================
// Operator context for GMRES matvec
// ============================================================================

/// All state needed by the matrix-free operator J*v and preconditioner.
/// All scratch buffers are heap-allocated — no node-count limitation.
const OperatorCtx = struct {
    ckt: *root.Circuit,
    grid: MixGrid,
    n: usize,
    f1: f64,
    f2: f64,

    // Current linearization point (time-domain samples)
    x_td: []f64, // n * nf (node-major)

    // Jacobian samples: g_td[elem * nf + sample], c_mat (averaged)
    g_td: []f64, // n * n * nf (element-major, samples contiguous)
    c_mat: []f64, // n * n (dense, from DC sample)

    // Scratch for operator apply
    v_td: []f64, // n * nf (IDFT of perturbation)
    w_td: []f64, // n * nf (time-domain product)

    // 2-D DFT basis (precomputed)
    // basis_cos[flat_freq * nf + time_sample], basis_sin[...]
    basis_cos: []f64, // nf * nf
    basis_sin: []f64, // nf * nf
    // Same values transposed to sample-major so the IDFT reads whole rows.
    basis_cos_t: []f64, // nf * nf
    basis_sin_t: []f64, // nf * nf

    // Scratch for per-sample eval (heap-allocated, size n)
    x_sample: []f64, // n
    // Scratch for dense G extraction (heap-allocated, size n*n)
    g_buf: []f64, // n * n

    // Preconditioner (optional)
    precond: ?*precond_mod.Preconditioner(f64),
};

// ============================================================================
// SIMD helpers
// ============================================================================

inline fn simdAxpy(out: []f64, a: f64, x: []const f64) void {
    const av: V = @splat(a);
    var i: usize = 0;
    while (i + W <= out.len) : (i += W) {
        const ov: V = out[i..][0..W].*;
        const xv: V = x[i..][0..W].*;
        out[i..][0..W].* = ov + av * xv;
    }
    while (i < out.len) : (i += 1) out[i] += a * x[i];
}

inline fn simdScale(dst: []f64, src: []const f64, s: f64) void {
    const sv: V = @splat(s);
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) {
        const xv: V = src[i..][0..W].*;
        dst[i..][0..W].* = sv * xv;
    }
    while (i < dst.len) : (i += 1) dst[i] = s * src[i];
}

// ============================================================================
// 2-D DFT / IDFT over the mix-product grid
// ============================================================================

/// Build the 2-D DFT basis.
/// Time grid: nf = nf1 * nf2 samples, t_{s} at (s1/nf1 * T1, s2/nf2 * T2).
/// Basis for mix product (k,l) at time sample s:
///   angle = 2π * (k*s1/nf1 + l*s2/nf2)
///   basis_cos[freq * nf + sample] = cos(angle)
///   basis_sin[freq * nf + sample] = sin(angle)
///
/// The `_t` outputs hold the same values indexed [sample * nf + freq]. The DFT
/// sums over samples and the IDFT over frequencies, so one layout can only be
/// contiguous for one of them; both are written here from the same @cos/@sin.
/// ponytail: 2*nf*nf extra doubles buys the IDFT contiguous loads. Generate the
/// transpose in tiles if nf ever grows past what the cache tolerates.
fn buildBasis2D(
    grid: MixGrid,
    basis_cos: []f64,
    basis_sin: []f64,
    basis_cos_t: []f64,
    basis_sin_t: []f64,
) void {
    const nf = grid.nf;
    const nf1 = grid.nf1;
    const nf2 = grid.nf2;

    for (0..nf) |freq| {
        const kl = grid.signedKL(freq);
        const k_f: f64 = @floatFromInt(kl.k);
        const l_f: f64 = @floatFromInt(kl.l);

        for (0..nf) |samp| {
            const s1 = samp % nf1;
            const s2 = samp / nf1;
            const angle = 2.0 * std.math.pi *
                (k_f * @as(f64, @floatFromInt(s1)) / @as(f64, @floatFromInt(nf1)) +
                    l_f * @as(f64, @floatFromInt(s2)) / @as(f64, @floatFromInt(nf2)));
            const c = @cos(angle);
            const s = @sin(angle);
            basis_cos[freq * nf + samp] = c;
            basis_sin[freq * nf + samp] = s;
            basis_cos_t[samp * nf + freq] = c;
            basis_sin_t[samp * nf + freq] = s;
        }
    }
}

/// IDFT: stacked-real spectrum [re_node*nf; im_node*nf] → time-domain x_td[node*nf+s].
/// Unscaled: x_td[s] = Σ_f (X_re[f]*cos[f,s] - X_im[f]*sin[f,s]).
/// See module-level doc for normalization convention.
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
        const re_base = node * nf;
        const im_base = node * nf;
        const td_base = node * nf;

        for (0..nf) |s| {
            // Sample-major basis: this sample's whole frequency row is contiguous,
            // so the four operands are plain vector loads and the summation order
            // over f is unchanged.
            const bc_row = basis_cos_t[s * nf ..][0..nf];
            const bs_row = basis_sin_t[s * nf ..][0..nf];

            var val: f64 = 0;
            var f_idx: usize = 0;
            while (f_idx + W <= nf) : (f_idx += W) {
                const bc: V = bc_row[f_idx..][0..W].*;
                const bs: V = bs_row[f_idx..][0..W].*;
                const xr: V = x_re[re_base + f_idx ..][0..W].*;
                const xi: V = x_im[im_base + f_idx ..][0..W].*;
                val += @reduce(.Add, xr * bc - xi * bs);
            }
            while (f_idx < nf) : (f_idx += 1) {
                val += x_re[re_base + f_idx] * bc_row[f_idx] -
                    x_im[im_base + f_idx] * bs_row[f_idx];
            }
            x_td[td_base + s] = val;
        }
    }
}

/// DFT: time-domain f_td[node*nf+s] → stacked-real spectrum [re; im].
/// Scaled by 1/nf:
///   X_re[f] = (1/nf) Σ_s f_td[s] * cos[f,s]
///   X_im[f] = -(1/nf) Σ_s f_td[s] * sin[f,s]
/// See module-level doc for normalization convention.
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
        const td_base = node * nf;
        const re_base = node * nf;
        const im_base = node * nf;

        for (0..nf) |f_idx| {
            const bc_base = f_idx * nf;

            var cos_acc: V = @splat(0.0);
            var sin_acc: V = @splat(0.0);
            var s: usize = 0;
            while (s + W <= nf) : (s += W) {
                const fv: V = f_td[td_base + s ..][0..W].*;
                const bcv: V = basis_cos[bc_base + s ..][0..W].*;
                const bsv: V = basis_sin[bc_base + s ..][0..W].*;
                cos_acc += fv * bcv;
                sin_acc += fv * bsv;
            }
            var cos_sum: f64 = @reduce(.Add, cos_acc);
            var sin_sum: f64 = @reduce(.Add, sin_acc);
            while (s < nf) : (s += 1) {
                cos_sum += f_td[td_base + s] * basis_cos[bc_base + s];
                sin_sum += f_td[td_base + s] * basis_sin[bc_base + s];
            }
            out_re[re_base + f_idx] = cos_sum * inv_nf;
            out_im[im_base + f_idx] = -sin_sum * inv_nf;
        }
    }
}

// ============================================================================
// QP-HB residual evaluation
// ============================================================================

/// Compute F(X_hat) = DFT(f(IDFT(X_hat))) + jΩC·X_hat in stacked-real form.
/// x_hat layout: [re_0..re_{n-1}; im_0..im_{n-1}], each block has nf entries.
/// Same layout for residual output.
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

    // Evaluate device at each time sample, store residuals and Jacobian samples.
    // ponytail: each of the nf evals is independent — ckt.eval() already
    // delegates to par_eval (thread pool) when wired. For GPU, this loop
    // would become a single batched launch via gpu_hook; see module-level doc
    // for the full DFT-sandwich kernel architecture.
    const ckt = ctx.ckt;

    for (0..nf) |s| {
        for (0..n) |node| ctx.x_sample[node] = ctx.x_td[node * nf + s];

        ckt.eval(ctx.x_sample[0..n], 0);

        for (0..n) |node| ctx.w_td[node * nf + s] = ckt.rhs[node];

        // Store dense G for Jacobian-vector products
        ckt.denseG(ctx.g_buf[0 .. n * n]);
        for (0..n) |row| {
            for (0..n) |col| {
                ctx.g_td[(row * n + col) * nf + s] = ctx.g_buf[row * n + col];
            }
        }

        // Capture C at first sample (quasi-static approximation)
        if (s == 0) {
            if (ckt.has_charge) {
                ckt.denseC(ctx.c_mat);
            } else {
                simdZero(ctx.c_mat);
            }
        }
    }

    // DFT: time-domain residuals → frequency domain
    const res_re = residual[0..total_re];
    const res_im = residual[total_re..][0..total_re];
    dft2D(res_re, res_im, ctx.w_td, ctx.basis_cos, ctx.basis_sin, n, nf);

    addChargeTerms(ctx, x_re, x_im, res_re, res_im);
}

// ============================================================================
// GMRES callbacks: matrix-free Jacobian-vector product
// ============================================================================

/// J*v = DFT(G(t_s) * IDFT(v)) + jΩC * v
/// v and w are in stacked-real format: [re_0..re_{n-1}; im_0..im_{n-1}]
///
// ponytail: this DFT-sandwich matvec (IDFT→G*v→DFT + jωC) is the hot inner loop of
// QPSS — called once per GMRES iteration, each call does n*nf FLOPs for the
// time-domain G*v product plus two O(n*nf²) DFT passes. The nf time-sample evals
// are independent and the DFT is a dense matrix-vector; both map trivially to GPU.
//
// GPU upgrade path — single-kernel DFT sandwich:
//   1. Upload spectral slab v (n*nf*2 doubles) to device (or keep resident)
//   2. IDFT: nf parallel dot products per node (basis × v), one thread-block per node
//   3. Batched G*v: nf independent n×n matvecs, one warp-group per time sample
//      (same dispatch topology as the megakernel's per-instance eval)
//   4. DFT + charge: nf parallel dot products per node + jω_{kl}C accumulation
//   5. Read back w (n*nf*2 doubles) — or chain into GMRES Arnoldi on-device
//
// Prerequisites: gpu_hook.dft_sandwich_matvec entry point, or factor into
// gpu_hook.batch_eval (step 3) + host DFT (steps 2,4) as an intermediate step.
// The intermediate version still saves nf kernel launches → 1 launch.
// Add when profiling shows host↔device latency dominates over compute.
fn matvec(v: []const f64, w: []f64, ctx_raw: *anyopaque) void {
    const ctx: *OperatorCtx = @ptrCast(@alignCast(ctx_raw));
    const n = ctx.n;
    const nf = ctx.grid.nf;
    const total_re = n * nf;

    // GMRES supplies disjoint input/output slabs; borrow the spectral views.
    const v_re = v[0..total_re];
    const v_im = v[total_re..][0..total_re];
    const w_re = w[0..total_re];
    const w_im = w[total_re..][0..total_re];

    idft2D(ctx.v_td, v_re, v_im, ctx.basis_cos_t, ctx.basis_sin_t, n, nf);

    gvProduct(ctx.w_td, ctx.g_td, ctx.v_td, n, nf);

    dft2D(w_re, w_im, ctx.w_td, ctx.basis_cos, ctx.basis_sin, n, nf);

    addChargeTerms(ctx, v_re, v_im, w_re, w_im);
}

/// Time-domain Jacobian-vector product: w_td[·,s] = G(t_s) * v_td[·,s].
/// Samples are the contiguous axis of both g_td and v_td, so a tile of them
/// rides in one vector while each lane walks the columns in the original order.
/// ponytail: every slot is assigned; zero first only if this becomes accumulation.
/// The scalar tail is the width-one oracle — the test drives both.
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

/// Add j*ω_{kl} C X in stacked-real form, preserving the DC/zero-C skips.
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

/// Preconditioner callback for GMRES: apply P^{-1} in-place.
fn precondApply(r: []f64, ctx_raw: *anyopaque) void {
    const ctx: *OperatorCtx = @ptrCast(@alignCast(ctx_raw));
    if (ctx.precond) |p| p.apply(r);
}

// ============================================================================
// Solve (Newton + GMRES)
// ============================================================================

pub fn solve(
    ckt: *root.Circuit,
    source_node: u32,
    source_mag: f64,
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
    const total = total_re * 2; // stacked-real

    // --- Arena allocation (single slab) — no node-count limitation ---
    const arena_size =
        total + // x_hat (stacked-real)
        total + // residual
        total + // dx (Newton step)
        n * nf + // x_td
        n * nf + // v_td (scratch)
        n * nf + // w_td (scratch)
        n * n * nf + // g_td
        n * n + // c_mat
        nf * nf + // basis_cos
        nf * nf + // basis_sin
        nf * nf + // basis_cos_t (sample-major, for the IDFT)
        nf * nf + // basis_sin_t
        n + // x_sample (per-sample eval scratch)
        n * n; // g_buf (dense G extraction scratch)

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
    const x_sample = arena[off..][0..n];
    off += n;
    const g_buf = arena[off..][0 .. n * n];
    off += n * n;
    std.debug.assert(off == arena_size);

    simdZero(x_hat);

    buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

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
        .basis_cos = basis_cos,
        .basis_sin = basis_sin,
        .basis_cos_t = basis_cos_t,
        .basis_sin_t = basis_sin_t,
        .x_sample = x_sample,
        .g_buf = g_buf,
        .precond = null,
    };

    // ponytail: at x=0 all nf samples are identical. Borrow the G/C planes
    // through init, which reads them without evaluating the circuit; it still
    // averages nf terms in the same order. A varying orbit needs sample storage.
    const g_sample_ptrs = try allocator.alloc([]const f64, nf);
    defer allocator.free(g_sample_ptrs);
    const c_sample_ptrs = try allocator.alloc([]const f64, nf);
    defer allocator.free(c_sample_ptrs);
    const c_zero = try allocator.alloc(f64, if (ckt.has_charge) 0 else ckt.nnz);
    defer allocator.free(c_zero);

    simdZero(x_sample);
    ckt.eval(x_sample, 0);
    simdZero(c_zero);
    const g_sample = ckt.g_vals[0..ckt.nnz];
    const c_sample = if (ckt.has_charge) ckt.c_vals[0..ckt.nnz] else c_zero;
    for (0..nf) |s| {
        g_sample_ptrs[s] = g_sample;
        c_sample_ptrs[s] = c_sample;
    }

    // ponytail: the preconditioner factors independent (G+jωC) systems and
    // retains their factors for triangular solves. GPU batching needs a new
    // apply strategy; parallel CPU factorization is an intermediate option
    // when those serial factorizations dominate Newton setup.
    // Use the largest harmonic count for the 1-D preconditioner — the preconditioner
    // treats the system as if it had max(K1,K2) harmonics of a single fundamental.
    // ponytail: simplified multi-tone preconditioner — use per-mix-product diagonal blocks
    // This is an approximation but captures the dominant conditioning.
    const max_harm: u32 = @intCast((@max(options.k1, options.k2)));
    // nf = (2*k1+1)*(2*k2+1) always covers 2*max(k1,k2)+1 sidebands.
    var precond_inst: ?precond_mod.Preconditioner(f64) = precond_mod.Preconditioner(f64).init(
        allocator,
        @intCast(n),
        ckt.col_ptr,
        ckt.row_idx,
        max_harm,
        @intCast(nf),
        g_sample_ptrs,
        c_sample_ptrs,
        2.0 * std.math.pi * options.f1, // dominant tone
        .averaged_circulant,
    ) catch null;
    defer if (precond_inst) |*p| p.deinit(allocator);

    op_ctx.precond = if (precond_inst != null) &precond_inst.? else null;

    // --- GMRES workspace ---
    const gmres_m: u32 = @intCast(@min(options.gmres_restart, total));
    var gmres = try gmres_mod.Gmres(f64).init(allocator, @intCast(total), gmres_m);
    defer gmres.deinit(allocator);

    // --- Add source excitation at f1 (cosine = pure real part at k=1, l=0) ---
    // The source appears as a known RHS contribution. We add it after each
    // residual evaluation into the appropriate spectral slot.
    const source_freq_idx = grid.flatIdx(1, 0); // k=1, l=0 → positive f1

    // --- Newton iteration ---
    var iter: u16 = 0;
    while (iter < options.max_newton) : (iter += 1) {
        computeResidual(&op_ctx, x_hat, residual);

        // Add source excitation: cosine at f1 into source_node's KCL row
        // In stacked-real: source enters as re component at the (k=1,l=0) slot
        if (source_node != root.GROUND) {
            residual[source_node * nf + source_freq_idx] += source_mag;
        }

        const res_norm = infNorm(residual);
        if (res_norm < options.hb_tol) {
            extractSpectra2D(x_hat, probes, spectra_re, spectra_im, n, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = res_norm };
        }

        // Solve J * dx = -F via GMRES
        // Negate residual for the RHS (GMRES solves J*dx = b, we want dx = -J^{-1}F)
        simdScale(residual, residual, -1.0);

        simdZero(dx);

        const has_precond = op_ctx.precond != null;
        _ = gmres.solve(
            &matvec,
            @ptrCast(&op_ctx),
            if (has_precond) &precondApply else null,
            if (has_precond) @ptrCast(&op_ctx) else null,
            residual,
            dx,
            options.gmres_tol,
            options.gmres_max_restarts,
        );

        simdAxpy(x_hat, 1.0, dx);
    }

    computeResidual(&op_ctx, x_hat, residual);
    if (source_node != root.GROUND) {
        residual[source_node * nf + source_freq_idx] += source_mag;
    }
    const final_norm = infNorm(residual);

    extractSpectra2D(x_hat, probes, spectra_re, spectra_im, n, nf);
    return .{ .converged = false, .iterations = options.max_newton, .residual_norm = final_norm };
}

/// Extract spectra for probed nodes from stacked-real x_hat.
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

// ============================================================================
// Contract entry point
// ============================================================================

pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const grid = MixGrid.init(opts.k1, opts.k2);
    const nf = grid.nf;

    // `defer`-freed == scratch; `a` is a results arena. See
    // RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    const spectra_re = try scratch.alloc(f64, ctx.probes.len * nf);
    defer scratch.free(spectra_re);
    const spectra_im = try scratch.alloc(f64, ctx.probes.len * nf);
    defer scratch.free(spectra_im);

    const st = try solve(ctx.circuit, ctx.source_node, opts.source_mag, ctx.probes, spectra_re, spectra_im, opts, scratch);

    if (!st.converged) return error.QpssDidNotConverge;

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s);
        a.free(names);
    }
    const ncols = names.len;

    // Output: one row per mix product, columns = [freq, probe_magnitudes...]
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "QPSS: MixGrid flat ↔ signed roundtrip" {
    const grid = MixGrid.init(3, 2);

    // nf1=7, nf2=5, nf=35
    try testing.expectEqual(@as(usize, 7), grid.nf1);
    try testing.expectEqual(@as(usize, 5), grid.nf2);
    try testing.expectEqual(@as(usize, 35), grid.nf);

    // DC: k=0, l=0 → flat = 2*7 + 3 = 17
    const dc_flat = grid.flatIdx(0, 0);
    try testing.expectEqual(@as(usize, 17), dc_flat);
    const dc_kl = grid.signedKL(dc_flat);
    try testing.expectEqual(@as(i32, 0), dc_kl.k);
    try testing.expectEqual(@as(i32, 0), dc_kl.l);

    // k=-3, l=-2 → flat = 0
    const corner = grid.flatIdx(-3, -2);
    try testing.expectEqual(@as(usize, 0), corner);
    const corner_kl = grid.signedKL(corner);
    try testing.expectEqual(@as(i32, -3), corner_kl.k);
    try testing.expectEqual(@as(i32, -2), corner_kl.l);

    for (0..grid.nf) |flat| {
        const kl = grid.signedKL(flat);
        try testing.expectEqual(flat, grid.flatIdx(kl.k, kl.l));
    }
}

test "QPSS: MixGrid omega calculation" {
    const grid = MixGrid.init(2, 1);
    const f1: f64 = 1e9;
    const f2: f64 = 1e6;

    // DC: ω = 0
    const dc = grid.flatIdx(0, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), grid.omega(dc, f1, f2), 1e-10);

    // k=1, l=0: ω = 2π*f1
    const f1_idx = grid.flatIdx(1, 0);
    try testing.expectApproxEqAbs(2.0 * std.math.pi * f1, grid.omega(f1_idx, f1, f2), 1e-3);

    // k=1, l=1: ω = 2π*(f1+f2)
    const sum_idx = grid.flatIdx(1, 1);
    try testing.expectApproxEqAbs(2.0 * std.math.pi * (f1 + f2), grid.omega(sum_idx, f1, f2), 1e-3);
}

test "QPSS: 2D DFT/IDFT roundtrip" {
    const grid = MixGrid.init(1, 1); // nf1=3, nf2=3 → nf=9
    const nf = grid.nf;
    const n: usize = 2;
    const sz = n * nf; // 2 * 9 = 18

    const alloc = testing.allocator;

    const basis_cos = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos);
    const basis_sin = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin);
    const basis_cos_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos_t);
    const basis_sin_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin_t);
    buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

    const x_re = try alloc.alloc(f64, sz);
    defer alloc.free(x_re);
    const x_im = try alloc.alloc(f64, sz);
    defer alloc.free(x_im);
    for (x_re) |*v| v.* = 0;
    for (x_im) |*v| v.* = 0;

    const dc_idx = grid.flatIdx(0, 0);
    x_re[0 * nf + dc_idx] = 1.0;
    x_re[1 * nf + dc_idx] = 2.0;

    const x_td = try alloc.alloc(f64, sz);
    defer alloc.free(x_td);
    idft2D(x_td, x_re, x_im, basis_cos_t, basis_sin_t, n, nf);

    for (0..nf) |s| {
        try testing.expectApproxEqAbs(@as(f64, 1.0), x_td[0 * nf + s], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 2.0), x_td[1 * nf + s], 1e-12);
    }

    const out_re = try alloc.alloc(f64, sz);
    defer alloc.free(out_re);
    const out_im = try alloc.alloc(f64, sz);
    defer alloc.free(out_im);
    dft2D(out_re, out_im, x_td, basis_cos, basis_sin, n, nf);

    try testing.expectApproxEqAbs(@as(f64, 1.0), out_re[0 * nf + dc_idx], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.0), out_re[1 * nf + dc_idx], 1e-12);

    for (0..n) |node| {
        for (0..nf) |f_idx| {
            if (f_idx == dc_idx) continue;
            try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[node * nf + f_idx], 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 0.0), out_im[node * nf + f_idx], 1e-12);
        }
    }
}

test "QPSS: 2D DFT/IDFT roundtrip with non-DC harmonic" {
    const grid = MixGrid.init(1, 1);
    const nf = grid.nf; // 3*3 = 9
    const n: usize = 1;

    const alloc = testing.allocator;
    const basis_cos = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos);
    const basis_sin = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin);
    const basis_cos_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos_t);
    const basis_sin_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin_t);
    buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

    // Spectrum: cos at k=1,l=0 (re=0.5) + sin at k=0,l=1 (im=-0.3)
    var x_re = [_]f64{0} ** 9;
    var x_im = [_]f64{0} ** 9;
    const f1_idx = grid.flatIdx(1, 0);
    const f2_idx = grid.flatIdx(0, 1);
    x_re[f1_idx] = 0.5;
    x_im[f2_idx] = -0.3; // negative im = positive sin

    // IDFT → DFT roundtrip
    var td = [_]f64{0} ** 9;
    idft2D(&td, &x_re, &x_im, basis_cos_t, basis_sin_t, n, nf);

    var out_re = [_]f64{0} ** 9;
    var out_im = [_]f64{0} ** 9;
    dft2D(&out_re, &out_im, &td, basis_cos, basis_sin, n, nf);

    // Non-DC harmonics: the IDFT sums all nf basis vectors (positive + negative
    // frequencies), but the DFT projects onto one-sided basis with 1/nf scaling.
    // For a single one-sided coefficient, the roundtrip yields 0.5x because the
    // conjugate partner at (-k,-l) is zero. This is by design — the solver always
    // operates on the full two-sided vector so the residual is self-consistent.
    // See module-level normalization doc.
    try testing.expectApproxEqAbs(@as(f64, 0.25), out_re[f1_idx], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.15), out_im[f2_idx], 1e-12);

    // DC should be ~0
    const dc_idx = grid.flatIdx(0, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[dc_idx], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out_im[dc_idx], 1e-12);
}

test "QPSS: buildBasis2D orthogonality" {
    // For a proper DFT basis, <cos_f, cos_g> = (nf/2) δ_{fg} for f,g ≠ 0.
    // More precisely, Σ_s cos(2πf·s_vec) cos(2πg·s_vec) = nf * δ_{fg}
    // when both f and g are zero, nf/2 for real-valued DFT.
    // Our convention: (1/nf) * DFT gives coefficient, so the inner product
    // of basis vectors should be nf for matching indices, 0 otherwise.
    const grid = MixGrid.init(1, 1);
    const nf = grid.nf;

    const alloc = testing.allocator;
    const basis_cos = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos);
    const basis_sin = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin);
    const basis_cos_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos_t);
    const basis_sin_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin_t);
    buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

    // Check: Σ_s cos[f,s]*cos[g,s] + sin[f,s]*sin[g,s] = nf * δ_{fg}
    // (This is the full complex inner product mapped to real)
    for (0..nf) |f_idx| {
        for (0..nf) |g_idx| {
            var dot: f64 = 0;
            for (0..nf) |s| {
                dot += basis_cos[f_idx * nf + s] * basis_cos[g_idx * nf + s] +
                    basis_sin[f_idx * nf + s] * basis_sin[g_idx * nf + s];
            }
            const expected: f64 = if (f_idx == g_idx) @as(f64, @floatFromInt(nf)) else 0;
            try testing.expectApproxEqAbs(expected, dot, 1e-10);
        }
    }
}

test "QPSS: gvProduct matches the scalar sample-major product bit for bit" {
    // nf = 9 and 49 straddle the vector width so both the tiled body and the
    // scalar tail run; each lane must reproduce the ascending-column order.
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();

    for ([_][2]usize{ .{ 9, 3 }, .{ 49, 13 }, .{ 25, 1 } }) |c| {
        const nf = c[0];
        const n = c[1];
        const g_td = try alloc.alloc(f64, n * n * nf);
        defer alloc.free(g_td);
        const v_td = try alloc.alloc(f64, n * nf);
        defer alloc.free(v_td);
        const want = try alloc.alloc(f64, n * nf);
        defer alloc.free(want);
        const got = try alloc.alloc(f64, n * nf);
        defer alloc.free(got);

        for (g_td) |*v| v.* = rnd.float(f64) * 0.02 - 0.01;
        for (v_td) |*v| v.* = rnd.float(f64) * 2000.0 - 1000.0;

        for (0..nf) |s| {
            for (0..n) |row| {
                var acc: f64 = 0;
                for (0..n) |col| acc += g_td[(row * n + col) * nf + s] * v_td[col * nf + s];
                want[row * nf + s] = acc;
            }
        }
        gvProduct(got, g_td, v_td, n, nf);
        for (want, got) |e, a| try testing.expectEqual(e, a);
    }
}

test "QPSS: Options satisfies contract" {
    comptime {
        if (!@hasField(Options, "tol")) @compileError("missing tol");
        if (@FieldType(Options, "tol") != converger.Tolerances) @compileError("wrong tol type");
    }
}

test "QPSS: heap buffers work for n > 256" {
    // Verify the arena sizing arithmetic doesn't overflow or assert for large n.
    // We can't run a full solve without a Circuit, but we can verify the DFT/IDFT
    // path with a large node count using heap-allocated buffers.
    const grid = MixGrid.init(1, 1); // nf=9
    const nf = grid.nf;
    const n: usize = 512; // > 256, was previously impossible
    const sz = n * nf;

    const alloc = testing.allocator;

    const basis_cos = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos);
    const basis_sin = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin);
    const basis_cos_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_cos_t);
    const basis_sin_t = try alloc.alloc(f64, nf * nf);
    defer alloc.free(basis_sin_t);
    buildBasis2D(grid, basis_cos, basis_sin, basis_cos_t, basis_sin_t);

    const x_re = try alloc.alloc(f64, sz);
    defer alloc.free(x_re);
    const x_im = try alloc.alloc(f64, sz);
    defer alloc.free(x_im);
    simdZero(x_re);
    simdZero(x_im);

    // Set DC for node 300 (beyond old 256 limit)
    const dc_idx = grid.flatIdx(0, 0);
    x_re[300 * nf + dc_idx] = 42.0;

    const x_td = try alloc.alloc(f64, sz);
    defer alloc.free(x_td);
    idft2D(x_td, x_re, x_im, basis_cos_t, basis_sin_t, n, nf);

    // Node 300 should be constant 42.0 across all time samples
    for (0..nf) |s| {
        try testing.expectApproxEqAbs(@as(f64, 42.0), x_td[300 * nf + s], 1e-10);
    }
    // Node 0 should be zero
    for (0..nf) |s| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), x_td[0 * nf + s], 1e-10);
    }

    const out_re = try alloc.alloc(f64, sz);
    defer alloc.free(out_re);
    const out_im = try alloc.alloc(f64, sz);
    defer alloc.free(out_im);
    dft2D(out_re, out_im, x_td, basis_cos, basis_sin, n, nf);

    try testing.expectApproxEqAbs(@as(f64, 42.0), out_re[300 * nf + dc_idx], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[0 * nf + dc_idx], 1e-10);
}
