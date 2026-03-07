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
//! Dense Jacobian is infeasible at n*K; we use matrix-free GMRES. A
//! block-circulant preconditioner (one sparse (G0+jω_{kl}C0) factor per mix
//! product) is the upgrade path — see the note in `solve`.
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
const solvers = @import("solvers");
const gmres_mod = solvers.gmres;
const dense_lu = solvers.dense_lu;
const infNorm = @import("pss.zig").normInf;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

// ============================================================================
// Options + public types
// ============================================================================

pub const Options = @import("requests").Qpss;

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

    pub fn init(k1: u16, k2: u16) MixGrid {
        const nf1 = 2 * @as(usize, k1) + 1;
        const nf2 = 2 * @as(usize, k2) + 1;
        return .{ .k1 = k1, .k2 = k2, .nf1 = nf1, .nf2 = nf2, .nf = nf1 * nf2 };
    }

    /// Flat index for signed (k, l) pair.
    pub fn flatIdx(self: MixGrid, k_signed: i32, l_signed: i32) usize {
        const k_off: usize = @intCast(k_signed + @as(i32, self.k1));
        const l_off: usize = @intCast(l_signed + @as(i32, self.k2));
        return l_off * self.nf1 + k_off;
    }

    /// Signed (k, l) from flat index.
    pub fn signedKL(self: MixGrid, flat: usize) struct { k: i32, l: i32 } {
        const l_off = flat / self.nf1;
        const k_off = flat % self.nf1;
        return .{
            .k = @as(i32, @intCast(k_off)) - @as(i32, self.k1),
            .l = @as(i32, @intCast(l_off)) - @as(i32, self.k2),
        };
    }

    /// Mix-product angular frequency: ω_{kl} = 2π(k*f1 + l*f2).
    pub fn omega(self: MixGrid, flat: usize, f1: f64, f2: f64) f64 {
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

    // One scalar instant per grid point — see buildSampleTimes.
    times: []f64, // nf

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

/// Scratch `buildTransform` needs, in f64 and in u32.
fn transformWork(nf: usize) struct { f64s: usize, u32s: usize } {
    const m = 2 * nf;
    return .{ .f64s = m * m + 2 * m, .u32s = m };
}

/// Build the forward transform Γ[s][f] = e^{j ω_f t_s} and its exact inverse,
/// in the two layouts `idft2D` and `dft2D` already read:
///
///   basis_cos_t[s*nf+f], basis_sin_t[s*nf+f] = Re Γ[s][f],  Im Γ[s][f]
///   basis_cos[f*nf+s],   basis_sin[f*nf+s]   = nf·Re Γ⁻¹[f][s], −nf·Im Γ⁻¹[f][s]
///
/// (the nf and the sign absorb the 1/nf and the −Im that `dft2D` applies).
///
/// Why an inverse rather than the textbook orthogonal 2-D DFT basis: that basis
/// is orthogonal only on the exact torus points, and incommensurate tones admit
/// no instant that is an exact torus point for BOTH tones (see
/// `buildSampleTimes`). Sampling a tone at the nearly-right instants and
/// projecting on the ideal basis leaks it into every other mix product at the
/// level of the instants' phase error — parts in 10⁵, where the corpus wants a
/// mix product that carries nothing to read as 1e-7. Γ⁻¹ is exact at whatever
/// instants Γ was built from, so a signal that is a sum of exactly these
/// exponentials lands on exactly its own lines, to roundoff. The APFT instants
/// still matter: they keep Γ within their phase error of the ideal DFT matrix,
/// which is what keeps the inverse well conditioned.
///
/// ponytail: one (2nf)² dense factorization and nf solves, once per analysis,
/// against nf circuit evaluations per GMRES iteration. nf ≤ 121 at the default
/// truncation, so this is a 242×242 LU — no reason to exploit the structure.
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
            // [ Re Γ  −Im Γ ]
            // [ Im Γ   Re Γ ]
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

/// Signed distance between two phases measured in cycles, wrapped to ±0.5.
inline fn cycleErr(phase: f64, target: f64) f64 {
    const d = phase - target;
    return @abs(d - @round(d));
}

/// One scalar instant per 2-D mix-grid point.
///
/// A device reads a single clock, so the torus point (s1/nf1 through tone 1,
/// s2/nf2 through tone 2) has to be spelled as ONE time — and it used to be
/// spelled as t = 0 for every sample, which is why no source waveform could
/// vary across the grid at all.
///
/// Tone 1 is exact at every t = (s1/nf1 + m)/f1 for integer m, so m is free to
/// spend on tone 2: pick the one whose frac(f2*t) lands closest to s2/nf2.
/// Incommensurate tones admit no instant exact for both — that is the APFT
/// sample-selection problem — but frac(m*f2/f1) equidistributes, so the leftover
/// phase error is O(1/horizon).
///
/// That leftover does NOT have to be small for the answer to be right:
/// `buildTransform` inverts the transform these instants actually generate, so
/// the spectra are exact wherever the instants land. What the horizon buys is
/// CONDITIONING — instants near the torus points keep Γ near the ideal DFT
/// matrix — and it is bounded above by f64 phase resolution, since the device
/// evaluates sin(2π·f·t) at t = O(horizon/f1).
///
/// ponytail: linear scan, O(nf · horizon) ≈ 5e5 flops once per analysis. A
/// continued-fraction search of f2/f1 would reach the same error in O(log)
/// steps — worth writing only if the horizon ever has to grow.
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

        // §4.6.1: a source waveform only exists while `analysis("tran")` is
        // true, and each grid point is a DIFFERENT instant. Both were missing
        // (every sample was `eval(x, 0)` in the inherited operating-point
        // phase), so the deck's two tones answered with one DC value and QPSS
        // balanced an undriven circuit. The excitation enters here.
        ckt.setSimState(.{ .t = ctx.times[s], .kind = .tran });
        ckt.eval(ctx.x_sample[0..n], ctx.times[s]);

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

// ============================================================================
// Solve (Newton + GMRES)
// ============================================================================

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
        nf + // times (one instant per mix-grid point)
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

    // No preconditioner. `solvers/preconditioner.zig` cannot be pointed at this
    // system as it stands: `applyBlockDiag` walks `2*max(K1,K2)+1` SIDEBAND-major
    // blocks of n and factors block p at ω = p·2πf1, while the QPSS vector is
    // n NODE-major blocks of nf and its blocks sit at the mix frequencies
    // k·f1 + l·f2. Both the indexing and the frequencies disagree, so the
    // "preconditioner" was solving the wrong subvectors against the wrong ω.
    // Harmless where C is absent (every block is then the same G⁻¹, however it
    // is permuted — `qpss/square_mixer` converged through it) and actively
    // misleading where it is not: all three `qpss/linear_two_tone_*` decks,
    // which differ from square_mixer by one capacitor, stalled GMRES until this
    // came out.
    //
    // ponytail: unpreconditioned GMRES, because these systems are 2·n·nf ≤ a few
    // hundred unknowns at a conditioning the restart depth already handles. The
    // upgrade is a real block-diagonal preconditioner — one sparse
    // (G₀ + jω_{kl}C₀) factor per MIX PRODUCT, node-major — which is what the
    // module doc above describes and what `Preconditioner` would need a
    // per-block ω and this layout to provide.

    // --- GMRES workspace ---
    // ponytail: no restarts at all below 512 unknowns. Unrestarted GMRES
    // terminates in at most `total` iterations, and `total` here is 2·n·nf —
    // 90 for `qpss/linear_two_tone_1_1`. Restarting at 30 threw away the
    // Arnoldi basis three times over on a 90-unknown system and stalled: the
    // matrix spans a voltage source's ±1 branch stamp and a 1 kΩ conductance's
    // 1e-3, and one capacitor's ω·C on top of that pushes the spread past 1e4,
    // which is exactly where a short restart cycle gives up. The basis costs
    // m·total doubles, so 512 is ~2 MB; past it the requested depth stands and
    // the real answer is the block preconditioner noted above.
    const want_m: usize = if (total <= 512) total else options.gmres_restart;
    const gmres_m: u32 = @intCast(@min(want_m, total));
    var gmres = try gmres_mod.Gmres(f64).init(allocator, @intCast(total), gmres_m);
    defer gmres.deinit(allocator);

    // --- Newton iteration ---
    // The excitation is not injected here any more: `computeResidual` evaluates
    // the circuit in the transient phase at each grid point's own instant, so
    // every source card's real spectrum is already in `residual`.
    var iter: u16 = 0;
    while (iter < options.max_newton) : (iter += 1) {
        if (iter != 0) try ckt.checkpoint(.{ .phase = .harmonic, .completed = iter });
        computeResidual(&op_ctx, x_hat, residual);

        const res_norm = infNorm(residual);
        if (res_norm < options.hb_tol) {
            extractSpectra2D(x_hat, probes, spectra_re, spectra_im, n, nf);
            return .{ .converged = true, .iterations = iter + 1, .residual_norm = res_norm };
        }

        // Solve J * dx = -F via GMRES
        // Negate residual for the RHS (GMRES solves J*dx = b, we want dx = -J^{-1}F)
        simdScale(residual, residual, -1.0);

        simdZero(dx);

        _ = gmres.solve(
            &matvec,
            @ptrCast(&op_ctx),
            null,
            null,
            residual,
            dx,
            options.gmres_tol,
            options.gmres_max_restarts,
        );

        simdAxpy(x_hat, 1.0, dx);
    }

    computeResidual(&op_ctx, x_hat, residual);
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

    const st = try solve(ctx.circuit, ctx.probes, spectra_re, spectra_im, opts, scratch);

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
