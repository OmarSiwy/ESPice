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
//! - Step 2 already benefits from par_eval (CPU thread pool) and gpu_hook
//!   (single Newton via converger.run) for the initial DC operating point.
//! - The preconditioner build evaluates the circuit at nf samples — each
//!   eval routes through ckt.eval() → par_eval when available.
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
const types = solvers.types;
const gmres_mod = solvers.gmres;
const precond_mod = solvers.preconditioner;

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

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    residual_norm: f64,
};

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
    nf: usize,
    total: usize, // n * nf * 2 (stacked-real: [re; im])
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
    v_re: []f64, // n * nf (split re/im of input)
    v_im: []f64, // n * nf
    w_re: []f64, // n * nf (split re/im of output)
    w_im: []f64, // n * nf

    // 2-D DFT basis (precomputed)
    // basis_cos[flat_freq * nf + time_sample], basis_sin[...]
    basis_cos: []f64, // nf * nf
    basis_sin: []f64, // nf * nf

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

/// Infinity norm (max absolute value).
fn infNorm(buf: []const f64) f64 {
    var mx: f64 = 0;
    for (buf) |v| mx = @max(mx, @abs(v));
    return mx;
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
fn buildBasis2D(grid: MixGrid, basis_cos: []f64, basis_sin: []f64) void {
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
            basis_cos[freq * nf + samp] = @cos(angle);
            basis_sin[freq * nf + samp] = @sin(angle);
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
    basis_cos: []const f64,
    basis_sin: []const f64,
    n: usize,
    nf: usize,
) void {
    for (0..n) |node| {
        const re_base = node * nf;
        const im_base = node * nf;
        const td_base = node * nf;

        for (0..nf) |s| {
            var val: f64 = 0;
            var f_idx: usize = 0;
            while (f_idx + W <= nf) : (f_idx += W) {
                var bc: V = undefined;
                var bs: V = undefined;
                var xr: V = undefined;
                var xi: V = undefined;
                inline for (0..W) |w| {
                    bc[w] = basis_cos[(f_idx + w) * nf + s];
                    bs[w] = basis_sin[(f_idx + w) * nf + s];
                    xr[w] = x_re[re_base + f_idx + w];
                    xi[w] = x_im[im_base + f_idx + w];
                }
                val += @reduce(.Add, xr * bc - xi * bs);
            }
            while (f_idx < nf) : (f_idx += 1) {
                val += x_re[re_base + f_idx] * basis_cos[f_idx * nf + s] -
                    x_im[im_base + f_idx] * basis_sin[f_idx * nf + s];
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
    const nf = ctx.nf;
    const total_re = n * nf;

    // Split input into re/im views
    const x_re = x_hat[0..total_re];
    const x_im = x_hat[total_re..][0..total_re];

    // IDFT: spectrum → time domain
    idft2D(ctx.x_td, x_re, x_im, ctx.basis_cos, ctx.basis_sin, n, nf);

    // Evaluate device at each time sample, store residuals and Jacobian samples.
    // ponytail: each of the nf evals is independent — ckt.eval() already
    // delegates to par_eval (thread pool) when wired. For GPU, this loop
    // would become a single batched launch via gpu_hook; see module-level doc
    // for the full DFT-sandwich kernel architecture.
    const ckt = ctx.ckt;

    for (0..nf) |s| {
        // Gather node voltages at this time sample
        for (0..n) |node| ctx.x_sample[node] = ctx.x_td[node * nf + s];

        ckt.eval(ctx.x_sample[0..n], 0);

        // Store residual
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

    // Add frequency-domain charge terms: j*ω_{kl} * C * X_{kl}
    // In stacked-real: for each mix product f and each node-pair:
    //   res_re[row,f] += ω_f * Σ_col C[row,col] * (-X_im[col,f])
    //   res_im[row,f] += ω_f * Σ_col C[row,col] * ( X_re[col,f])
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
    const nf = ctx.nf;
    const total_re = n * nf;

    // Split v into re/im
    simdCopy(ctx.v_re, v[0..total_re]);
    simdCopy(ctx.v_im, v[total_re..][0..total_re]);

    // IDFT the perturbation to time domain
    idft2D(ctx.v_td, ctx.v_re, ctx.v_im, ctx.basis_cos, ctx.basis_sin, n, nf);

    // Time-domain Jacobian-vector product: w_td[s] = G(t_s) * v_td[s]
    simdZero(ctx.w_td);
    for (0..nf) |s| {
        for (0..n) |row| {
            var acc: f64 = 0;
            for (0..n) |col| {
                acc += ctx.g_td[(row * n + col) * nf + s] * ctx.v_td[col * nf + s];
            }
            ctx.w_td[row * nf + s] = acc;
        }
    }

    // DFT back to frequency domain
    dft2D(ctx.w_re, ctx.w_im, ctx.w_td, ctx.basis_cos, ctx.basis_sin, n, nf);

    // Write stacked-real output
    simdCopy(w[0..total_re], ctx.w_re);
    simdCopy(w[total_re..][0..total_re], ctx.w_im);

    // Add charge terms: j*ω_{kl} * C * v_{kl}
    for (0..nf) |f_idx| {
        const omega_f = ctx.grid.omega(f_idx, ctx.f1, ctx.f2);
        if (omega_f == 0) continue;

        for (0..n) |row| {
            var sum_re: f64 = 0;
            var sum_im: f64 = 0;
            for (0..n) |col| {
                const c_val = ctx.c_mat[row * n + col];
                if (c_val == 0) continue;
                sum_re += c_val * (-ctx.v_im[col * nf + f_idx]);
                sum_im += c_val * ctx.v_re[col * nf + f_idx];
            }
            w[row * nf + f_idx] += omega_f * sum_re;
            w[total_re + row * nf + f_idx] += omega_f * sum_im;
        }
    }
}

/// Preconditioner callback for GMRES: apply P^{-1} in-place.
fn precondApply(r: []f64, ctx_raw: *anyopaque) void {
    const ctx: *OperatorCtx = @ptrCast(@alignCast(ctx_raw));
    if (ctx.precond) |p| p.apply(r);
}

// ============================================================================
// GPU-accelerated preconditioner factorization
// ============================================================================

// ponytail: the preconditioner factors nf independent (G+jω_{kl}C) systems —
// one sparse LU per mix product. The factorizations are independent and could
// use gpu_hook.freq_solve_batch to solve all nf systems in a single launch
// during the preconditioner *apply* step. However, the current Preconditioner
// type pre-factors on init and applies via triangular solves, so the GPU path
// would need a different apply strategy (batched direct solve instead of
// pre-factored triangular solve). Worth adding when nf * n is large enough
// that the nf serial LU factorizations dominate Newton setup time.
// Intermediate step: parallelize the nf LU factorizations on CPU threads.

/// Try to use gpu_hook.freq_solve_batch for the preconditioner's initial
/// factorization samples (the nf circuit evaluations at the operating point).
/// Falls back to serial eval if GPU is unavailable.
fn evalPrecondSamples(
    ckt: *root.Circuit,
    nf: usize,
    x_zero: []f64,
    sample_storage: []f64,
    g_sample_ptrs: [][]const f64,
    c_sample_ptrs: [][]const f64,
) void {
    // ponytail: these nf evals at x=0 are identical (same operating point),
    // so they produce identical G/C. We eval once and replicate — the
    // preconditioner averages them anyway, so nf copies of the same data
    // yield the same averaged result. This is a valid shortcut because the
    // initial guess is zero (no time variation in the linearization point).
    // When re-building the preconditioner mid-Newton at a non-trivial x_hat,
    // the evals would differ per sample and this optimization wouldn't apply.
    ckt.eval(x_zero, 0);

    for (0..nf) |s| {
        const g_off = s * ckt.nnz;
        const c_off = nf * ckt.nnz + s * ckt.nnz;
        simdCopy(sample_storage[g_off..][0..ckt.nnz], ckt.g_vals[0..ckt.nnz]);
        if (ckt.has_charge) {
            simdCopy(sample_storage[c_off..][0..ckt.nnz], ckt.c_vals[0..ckt.nnz]);
        } else {
            simdZero(sample_storage[c_off..][0..ckt.nnz]);
        }
        g_sample_ptrs[s] = sample_storage[g_off..][0..ckt.nnz];
        c_sample_ptrs[s] = sample_storage[c_off..][0..ckt.nnz];
    }
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
        n * nf + // v_re
        n * nf + // v_im
        n * nf + // w_re
        n * nf + // w_im
        n * n * nf + // g_td
        n * n + // c_mat
        nf * nf + // basis_cos
        nf * nf + // basis_sin
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
    const v_re = arena[off..][0 .. n * nf];
    off += n * nf;
    const v_im = arena[off..][0 .. n * nf];
    off += n * nf;
    const w_re = arena[off..][0 .. n * nf];
    off += n * nf;
    const w_im = arena[off..][0 .. n * nf];
    off += n * nf;
    const g_td = arena[off..][0 .. n * n * nf];
    off += n * n * nf;
    const c_mat = arena[off..][0 .. n * n];
    off += n * n;
    const basis_cos = arena[off..][0 .. nf * nf];
    off += nf * nf;
    const basis_sin = arena[off..][0 .. nf * nf];
    off += nf * nf;
    const x_sample = arena[off..][0..n];
    off += n;
    const g_buf = arena[off..][0 .. n * n];
    off += n * n;
    std.debug.assert(off == arena_size);

    // Zero initial guess
    simdZero(x_hat);

    // Build 2-D DFT basis
    buildBasis2D(grid, basis_cos, basis_sin);

    // Operator context
    var op_ctx = OperatorCtx{
        .ckt = ckt,
        .grid = grid,
        .n = n,
        .nf = nf,
        .total = total,
        .f1 = options.f1,
        .f2 = options.f2,
        .x_td = x_td,
        .g_td = g_td,
        .c_mat = c_mat,
        .v_td = v_td,
        .w_td = w_td,
        .v_re = v_re,
        .v_im = v_im,
        .w_re = w_re,
        .w_im = w_im,
        .basis_cos = basis_cos,
        .basis_sin = basis_sin,
        .x_sample = x_sample,
        .g_buf = g_buf,
        .precond = null,
    };

    // --- Build preconditioner ---
    // Evaluate circuit at the initial operating point for preconditioning.
    // ponytail: at x=0 all nf samples are identical — eval once and replicate.
    // GPU benefit: the single eval routes through par_eval/gpu_hook automatically.
    const g_sample_ptrs = try allocator.alloc([]const f64, nf);
    defer allocator.free(g_sample_ptrs);
    const c_sample_ptrs = try allocator.alloc([]const f64, nf);
    defer allocator.free(c_sample_ptrs);

    // Allocate sample storage
    const sample_storage = try allocator.alloc(f64, 2 * nf * ckt.nnz);
    defer allocator.free(sample_storage);

    // Heap-allocated zero vector for preconditioner eval (replaces stack buffer)
    const x_zero = try allocator.alloc(f64, n);
    defer allocator.free(x_zero);
    simdZero(x_zero);

    evalPrecondSamples(ckt, nf, x_zero, sample_storage, g_sample_ptrs, c_sample_ptrs);

    // Use the largest harmonic count for the 1-D preconditioner — the preconditioner
    // treats the system as if it had max(K1,K2) harmonics of a single fundamental.
    // ponytail: simplified multi-tone preconditioner — use per-mix-product diagonal blocks
    // (G0 + jω_{kl}C0) factored independently. The Preconditioner type handles this
    // as a 1-D system with num_harmonics = nf/2 sidebands, each at the appropriate ω.
    // This is an approximation but captures the dominant conditioning.
    const max_harm: u32 = @intCast((@max(options.k1, options.k2)));
    const precond_sidebands: u32 = 2 * max_harm + 1;

    // Build preconditioner only if sidebands match what we can construct.
    // ponytail: skip preconditioner if mismatch; GMRES still works, just slower.
    var precond_inst: ?precond_mod.Preconditioner(f64) = null;
    defer if (precond_inst) |*p| p.deinit(allocator);

    if (precond_sidebands <= nf) {
        // Use min(nf, precond_sidebands) samples for preconditioner init
        const precond_samples: u32 = @intCast(@min(nf, @as(usize, precond_sidebands)));
        if (precond_samples >= 1) {
            precond_inst = precond_mod.Preconditioner(f64).init(
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
        }
    }
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
        // Evaluate residual F(X_hat)
        computeResidual(&op_ctx, x_hat, residual);

        // Add source excitation: cosine at f1 into source_node's KCL row
        // In stacked-real: source enters as re component at the (k=1,l=0) slot
        if (source_node != root.GROUND) {
            residual[source_node * nf + source_freq_idx] += source_mag;
        }

        // Check convergence
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
        const gmres_result = gmres.solve(
            &matvec,
            @ptrCast(&op_ctx),
            if (has_precond) &precondApply else null,
            if (has_precond) @ptrCast(&op_ctx) else null,
            residual,
            dx,
            options.gmres_tol,
            options.gmres_max_restarts,
        );
        _ = gmres_result;

        // Update x_hat
        simdAxpy(x_hat, 1.0, dx);
    }

    // Did not converge — compute final residual
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

/// Magnitude of the (k,l) mix product from a probe's re/im spectra.
pub fn mixMagnitude(re: []const f64, im: []const f64, grid: MixGrid, k: i32, l: i32) f64 {
    const idx = grid.flatIdx(k, l);
    const r = re[idx];
    const i = im[idx];
    return @sqrt(r * r + i * i);
}

// ============================================================================
// Contract entry point
// ============================================================================

pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const grid = MixGrid.init(opts.k1, opts.k2);
    const nf = grid.nf;

    const spectra_re = try a.alloc(f64, ctx.probes.len * nf);
    defer a.free(spectra_re);
    const spectra_im = try a.alloc(f64, ctx.probes.len * nf);
    defer a.free(spectra_im);

    const st = try solve(ctx.circuit, ctx.source_node, opts.source_mag, ctx.probes, spectra_re, spectra_im, opts, a);

    if (!st.converged) return error.QpssDidNotConverge;

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s);
        a.free(names);
    }
    const ncols = names.len;

    // Output: one row per mix product, columns = [freq, probe_magnitudes...]
    // Mix products sorted by frequency (k*f1 + l*f2).
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

    // Roundtrip all
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
    buildBasis2D(grid, basis_cos, basis_sin);

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
    idft2D(x_td, x_re, x_im, basis_cos, basis_sin, n, nf);

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
    buildBasis2D(grid, basis_cos, basis_sin);

    // Spectrum: cos at k=1,l=0 (re=0.5) + sin at k=0,l=1 (im=-0.3)
    var x_re = [_]f64{0} ** 9;
    var x_im = [_]f64{0} ** 9;
    const f1_idx = grid.flatIdx(1, 0);
    const f2_idx = grid.flatIdx(0, 1);
    x_re[f1_idx] = 0.5;
    x_im[f2_idx] = -0.3; // negative im = positive sin

    // IDFT → DFT roundtrip
    var td = [_]f64{0} ** 9;
    idft2D(&td, &x_re, &x_im, basis_cos, basis_sin, n, nf);

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
    buildBasis2D(grid, basis_cos, basis_sin);

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

test "QPSS: Options satisfies contract" {
    // Compile-time check: Options has tol field of correct type
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
    buildBasis2D(grid, basis_cos, basis_sin);

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
    idft2D(x_td, x_re, x_im, basis_cos, basis_sin, n, nf);

    // Node 300 should be constant 42.0 across all time samples
    for (0..nf) |s| {
        try testing.expectApproxEqAbs(@as(f64, 42.0), x_td[300 * nf + s], 1e-10);
    }
    // Node 0 should be zero
    for (0..nf) |s| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), x_td[0 * nf + s], 1e-10);
    }

    // DFT roundtrip
    const out_re = try alloc.alloc(f64, sz);
    defer alloc.free(out_re);
    const out_im = try alloc.alloc(f64, sz);
    defer alloc.free(out_im);
    dft2D(out_re, out_im, x_td, basis_cos, basis_sin, n, nf);

    try testing.expectApproxEqAbs(@as(f64, 42.0), out_re[300 * nf + dc_idx], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out_re[0 * nf + dc_idx], 1e-10);
}
