//! Structured preconditioners for HB / LPTV / QPSS Krylov solves.
//!
//! Block-circulant (averaged-Jacobian) preconditioning: the HB operator is
//! block-Toeplitz in the harmonic index; dropping the off-diagonal harmonic
//! coupling (m ≠ 0 Fourier coefficients of G(t), C(t)) yields a block-diagonal
//! operator in the frequency basis — one n×n complex (stacked-real 2n×2n)
//! sparse solve per sideband. All sidebands share the circuit sparsity pattern
//! (differ only by the scalar ω_p), so symbolic factorization is done once.
//!
//! Fallback hierarchy (ordered by cost / strength):
//!   1. dc_sample     — G(t_0) instead of Ḡ, cheapest
//!   2. averaged_circulant — Ḡ = mean(G_k), default
//!   3. block_banded  — keep |p-q| ≤ 1 harmonic coupling, block-Thomas
//!
//! The unknown vector is in stacked-real format: for M sidebands (2M+1 total,
//! p = -M..M), length = 2*(2M+1)*n, laid out as
//!   [re(x_{-M}), re(x_{-M+1}), ..., re(x_M), im(x_{-M}), ..., im(x_M)]
//! where each re/im block has length n.
//!
//! Imports from this module: direct.zig (sparse LU), fft.zig (unused here but
//! referenced by the doc — the preconditioner operates in the DFT basis
//! natively, no transform needed in apply).

const std = @import("std");
const direct = @import("direct.zig");

const Allocator = std.mem.Allocator;
const NONE: u32 = std.math.maxInt(u32);

/// Structured HB/LPTV preconditioner, monomorphized per element type.
pub fn Preconditioner(comptime T: type) type {
    return struct {
        const Self = @This();
        const W = std.simd.suggestVectorLength(T) orelse 1;
        const V = @Vector(W, T);

        /// SIMD zero-fill a contiguous T buffer.
        inline fn simdZero(buf: []T) void {
            const zero: V = @splat(0);
            var i: usize = 0;
            while (i + W <= buf.len) : (i += W) {
                buf[i..][0..W].* = zero;
            }
            for (buf[i..]) |*v| v.* = 0;
        }

        /// SIMD copy a contiguous T buffer.
        inline fn simdCopy(dst: []T, src: []const T) void {
            var i: usize = 0;
            while (i + W <= dst.len) : (i += W) {
                dst[i..][0..W].* = src[i..][0..W].*;
            }
            for (dst[i..], src[i..]) |*d, s| d.* = s;
        }

        pub const Kind = enum { dc_sample, averaged_circulant, block_banded };

        /// Number of circuit nodes.
        n: u32,
        /// Total sidebands = 2*num_harmonics + 1.
        num_sidebands: u32,
        /// Fundamental angular frequency.
        omega0: T,
        /// Which preconditioner variant.
        kind: Kind,

        // --- Averaged (or DC-sample) G/C values (length nnz each) ---
        g_bar: []T,
        c_bar: []T,

        // --- Stacked-real 2n×2n CSC pattern (owned, shared by all sidebands) ---
        sr_col_ptr: []u32,
        sr_row_idx: []u32,

        // --- Per-sideband sparse solvers (all share sr_col_ptr/sr_row_idx) ---
        // Length = num_sidebands. Each solver has its own LU factors.
        solvers: []direct.SolverT(T),
        /// Scratch for stacked-real values fill (length = sr nnz).
        sr_vals: []T,
        /// Whether each sideband's solver is factored at current G/C.
        factored: []bool,

        // --- Block-banded: extra off-diagonal coupling data ---
        // ponytail: block_banded stores G_±1 Fourier coefficients for
        // tridiagonal coupling. Upgrade to wider bands when needed.
        g_plus1: ?[]T, // G_{+1} Fourier coeff (length nnz), null if not banded
        g_minus1: ?[]T, // G_{-1} Fourier coeff
        c_plus1: ?[]T,
        c_minus1: ?[]T,
        // Extra solvers for the banded pivot blocks (Thomas elimination modifies
        // the diagonal blocks); length = num_sidebands, allocated only for banded.
        banded_scratch: ?[]T,

        // Source pattern (borrowed, for stacked-real fill).
        src_col_ptr: []const u32,
        src_row_idx: []const u32,
        src_nnz: u32,

        /// Build preconditioner from period-sampled Jacobians.
        ///
        /// g_samples[k] = G(t_k) sparse values on the circuit pattern (length nnz),
        /// c_samples[k] = C(t_k) likewise. num_samples = N time samples per period.
        /// num_harmonics = M: sidebands p = -M..M, total 2M+1.
        pub fn init(
            gpa: Allocator,
            n: u32,
            col_ptr: []const u32,
            row_idx: []const u32,
            num_harmonics: u32,
            num_samples: u32,
            g_samples: []const []const T,
            c_samples: []const []const T,
            omega0: T,
            kind: Kind,
        ) !Self {
            const nnz = col_ptr[n];
            const num_sidebands = 2 * num_harmonics + 1;
            const nu: usize = n;

            // --- Compute averaged or DC-sample G/C ---
            const g_bar = try gpa.alloc(T, nnz);
            errdefer gpa.free(g_bar);
            const c_bar = try gpa.alloc(T, nnz);
            errdefer gpa.free(c_bar);

            switch (kind) {
                .dc_sample => {
                    // Just use first sample
                    simdCopy(g_bar, g_samples[0][0..nnz]);
                    simdCopy(c_bar, c_samples[0][0..nnz]);
                },
                .averaged_circulant, .block_banded => {
                    // Period average: Ḡ = (1/N) Σ_k G(t_k)
                    averageSamples(T, g_bar, g_samples, num_samples, nnz);
                    averageSamples(T, c_bar, c_samples, num_samples, nnz);
                },
            }

            // --- Build stacked-real 2n×2n CSC pattern ---
            // Column j (j < n): rows from G-block then C-block shifted by n
            // Column j+n: same but [-wC | G] block
            const sr_nnz = 4 * @as(usize, nnz);
            const sr_col_ptr = try gpa.alloc(u32, 2 * nu + 1);
            errdefer gpa.free(sr_col_ptr);
            const sr_row_idx = try gpa.alloc(u32, sr_nnz);
            errdefer gpa.free(sr_row_idx);

            buildStackedRealPattern(n, col_ptr, row_idx, sr_col_ptr, sr_row_idx);

            // --- Allocate per-sideband solvers ---
            const solvers = try gpa.alloc(direct.SolverT(T), num_sidebands);
            errdefer {
                for (solvers) |*s| s.deinit();
                gpa.free(solvers);
            }
            for (solvers) |*s| {
                s.* = try direct.SolverT(T).init(gpa, 2 * n, sr_col_ptr, sr_row_idx, null);
            }

            const sr_vals = try gpa.alloc(T, sr_nnz);
            errdefer gpa.free(sr_vals);

            const factored_flags = try gpa.alloc(bool, num_sidebands);
            errdefer gpa.free(factored_flags);
            for (factored_flags) |*f| f.* = false;

            // --- Block-banded: compute G_±1 Fourier coefficients ---
            var g_plus1: ?[]T = null;
            var g_minus1: ?[]T = null;
            var c_plus1: ?[]T = null;
            var c_minus1: ?[]T = null;
            var banded_scratch: ?[]T = null;

            if (kind == .block_banded) {
                g_plus1 = try gpa.alloc(T, nnz);
                errdefer gpa.free(g_plus1.?);
                g_minus1 = try gpa.alloc(T, nnz);
                errdefer gpa.free(g_minus1.?);
                c_plus1 = try gpa.alloc(T, nnz);
                errdefer gpa.free(c_plus1.?);
                c_minus1 = try gpa.alloc(T, nnz);
                errdefer gpa.free(c_minus1.?);

                // DFT coefficient G_{+1} = (1/N) Σ_k G(t_k) e^{-j2πk/N}
                // We store real and imaginary parts interleaved:
                // g_plus1[i] = Re(G_{+1}[i]), but since the coupling in
                // the stacked-real form needs both parts, we store the
                // magnitude-scaled version. For block-tridiagonal Thomas,
                // we actually need the full complex coefficient. Store Re/Im
                // in g_plus1/g_minus1 respectively for m=+1.
                computeFourierCoeff(T, g_plus1.?, g_minus1.?, g_samples, num_samples, nnz, 1);
                computeFourierCoeff(T, c_plus1.?, c_minus1.?, c_samples, num_samples, nnz, 1);

                // Scratch for Thomas elimination: one 2n vector per sideband
                banded_scratch = try gpa.alloc(T, 2 * nu * num_sidebands);
            }

            var self = Self{
                .n = n,
                .num_sidebands = num_sidebands,
                .omega0 = omega0,
                .kind = kind,
                .g_bar = g_bar,
                .c_bar = c_bar,
                .sr_col_ptr = sr_col_ptr,
                .sr_row_idx = sr_row_idx,
                .solvers = solvers,
                .sr_vals = sr_vals,
                .factored = factored_flags,
                .g_plus1 = g_plus1,
                .g_minus1 = g_minus1,
                .c_plus1 = c_plus1,
                .c_minus1 = c_minus1,
                .banded_scratch = banded_scratch,
                .src_col_ptr = col_ptr,
                .src_row_idx = row_idx,
                .src_nnz = nnz,
            };

            // Pre-factor all sidebands eagerly. Typical M is small (3–15),
            // and the symbolic is shared — only numeric refactor per sideband.
            try self.factorAll();

            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.solvers) |*s| s.deinit();
            gpa.free(self.solvers);
            gpa.free(self.sr_col_ptr);
            gpa.free(self.sr_row_idx);
            gpa.free(self.sr_vals);
            gpa.free(self.factored);
            gpa.free(self.g_bar);
            gpa.free(self.c_bar);
            if (self.g_plus1) |p| gpa.free(p);
            if (self.g_minus1) |p| gpa.free(p);
            if (self.c_plus1) |p| gpa.free(p);
            if (self.c_minus1) |p| gpa.free(p);
            if (self.banded_scratch) |p| gpa.free(p);
            self.* = undefined;
        }

        /// Apply P^{-1} to rhs in-place (stacked-real format).
        ///
        /// Layout: rhs has length 2 * num_sidebands * n.
        /// First num_sidebands*n entries = real parts (one n-block per sideband),
        /// next num_sidebands*n entries = imaginary parts.
        ///
        /// For averaged_circulant / dc_sample: independent per-sideband solve.
        /// For block_banded: block-Thomas sweep.
        pub fn apply(self: *Self, rhs: []T) void {
            switch (self.kind) {
                .dc_sample, .averaged_circulant => self.applyBlockDiag(rhs, false),
                .block_banded => self.applyBanded(rhs, false),
            }
        }

        /// Apply P^{-T} (transpose preconditioner) in-place.
        pub fn applyT(self: *Self, rhs: []T) void {
            switch (self.kind) {
                .dc_sample, .averaged_circulant => self.applyBlockDiag(rhs, true),
                .block_banded => self.applyBanded(rhs, true),
            }
        }

        // ====================================================================
        // Internals
        // ====================================================================

        /// Factor all sidebands at their respective ω_p.
        fn factorAll(self: *Self) !void {
            const M = (self.num_sidebands - 1) / 2;
            for (0..self.num_sidebands) |pi| {
                const p_signed: i32 = @as(i32, @intCast(pi)) - @as(i32, @intCast(M));
                const omega_p: T = @as(T, @floatFromInt(p_signed)) * self.omega0;
                try self.factorSideband(@intCast(pi), omega_p);
            }
        }

        /// Fill stacked-real values and factor a single sideband.
        fn factorSideband(self: *Self, idx: u32, omega: T) !void {
            fillStackedReal(
                T,
                self.sr_vals,
                self.g_bar,
                self.c_bar,
                self.src_col_ptr,
                self.n,
                omega,
            );
            try self.solvers[idx].factor(self.sr_vals);
            self.factored[idx] = true;
        }

        /// Block-diagonal apply: per-sideband independent solves.
        fn applyBlockDiag(self: *Self, rhs: []T, transpose: bool) void {
            const n: usize = self.n;
            const ns = self.num_sidebands;

            // rhs layout: [re_0..re_{ns-1} | im_0..im_{ns-1}], each block of length n.
            // Per sideband p, the stacked-real RHS is [re_p; im_p] (length 2n).
            // We assemble it into sr_vals scratch (reusing sr_vals as a temp — it's
            // only needed during factor, not solve). Actually, we need a 2n scratch.
            // ponytail: reuse the first 2n of sr_vals as scratch; factor is done.
            const scratch = self.sr_vals[0 .. 2 * n];

            for (0..ns) |pi| {
                const re_off = pi * n;
                const im_off = ns * n + pi * n;

                // Assemble stacked-real RHS: [re_p; im_p]
                simdCopy(scratch[0..n], rhs[re_off..][0..n]);
                simdCopy(scratch[n..][0..n], rhs[im_off..][0..n]);

                // Solve in-place
                if (transpose) {
                    self.solvers[pi].solveT(scratch, scratch);
                } else {
                    self.solvers[pi].solve(scratch, scratch);
                }

                // Write back
                simdCopy(rhs[re_off..][0..n], scratch[0..n]);
                simdCopy(rhs[im_off..][0..n], scratch[n..][0..n]);
            }
        }

        /// Block-banded (tridiagonal) apply via block-Thomas sweep.
        ///
        /// The preconditioner has the structure:
        ///   P_{p,p} = G_bar + j*ω_p*C_bar   (diagonal blocks, already factored)
        ///   P_{p,p±1} = G_{±1} + j*ω_p*C_{±1}  (off-diagonal coupling)
        ///
        /// Thomas forward sweep: for p = 0..ns-1,
        ///   if p > 0: rhs_p -= P_{p,p-1} * P_{p-1,p-1}^{-1} * rhs_{p-1}
        ///   (modify the diagonal factor on the fly — but since we share
        ///    symbolic factorizations, we instead just do an SpMV + solve)
        ///
        /// ponytail: simplified Thomas — applies the diagonal preconditioner
        /// then does one correction sweep for the off-diagonal coupling.
        /// Full block-Thomas with modified pivots when iteration counts demand it.
        fn applyBanded(self: *Self, rhs: []T, transpose: bool) void {
            // First pass: apply block-diagonal (same as averaged_circulant)
            self.applyBlockDiag(rhs, transpose);

            // ponytail: off-diagonal correction is a single Jacobi-style sweep.
            // For mild modulation this converges fast. Full Thomas when needed.
            // The correction is: x_p -= D_p^{-1} * (L_{p,p-1}*x_{p-1} + U_{p,p+1}*x_{p+1})
            // where D_p is the diagonal block solver (already applied above).
            // Since we just solved D_p * x_p = b_p, the residual from off-diag
            // coupling is the dominant error. One sweep captures first-order coupling.
            if (self.banded_scratch == null) return;
            const scratch = self.banded_scratch.?;
            const n: usize = self.n;
            const ns = self.num_sidebands;
            const nn = 2 * n;

            // Compute off-diagonal contributions and correct
            for (0..ns) |pi| {
                const s_off = pi * nn;
                simdZero(scratch[s_off..][0..nn]);

                // Accumulate coupling from p-1 and p+1
                if (pi > 0) {
                    accumulateCoupling(
                        T,
                        scratch[s_off..][0..nn],
                        rhs,
                        pi - 1,
                        n,
                        ns,
                        self.g_minus1.?,
                        self.c_minus1.?,
                        self.src_col_ptr,
                        self.src_row_idx,
                        self.n,
                        self.omega0,
                        @as(i32, @intCast(pi)) - @as(i32, @intCast((ns - 1) / 2)),
                        transpose,
                    );
                }
                if (pi + 1 < ns) {
                    accumulateCoupling(
                        T,
                        scratch[s_off..][0..nn],
                        rhs,
                        pi + 1,
                        n,
                        ns,
                        self.g_plus1.?,
                        self.c_plus1.?,
                        self.src_col_ptr,
                        self.src_row_idx,
                        self.n,
                        self.omega0,
                        @as(i32, @intCast(pi)) - @as(i32, @intCast((ns - 1) / 2)),
                        transpose,
                    );
                }
            }

            // Apply diagonal solve to the correction and subtract
            for (0..ns) |pi| {
                const s_off = pi * nn;
                const correction = scratch[s_off..][0..nn];

                if (transpose) {
                    self.solvers[pi].solveT(correction, correction);
                } else {
                    self.solvers[pi].solve(correction, correction);
                }

                const re_off = pi * n;
                const im_off = ns * n + pi * n;
                for (0..n) |i| {
                    rhs[re_off + i] -= correction[i];
                    rhs[im_off + i] -= correction[n + i];
                }
            }
        }
    };
}

// ============================================================================
// Standalone helpers (not methods — no hidden self / generic coupling)
// ============================================================================

/// Standalone SIMD zero for generic T (used by helpers outside the struct).
inline fn standaloneSimdZero(comptime T: type, buf: []T) void {
    const Ww = std.simd.suggestVectorLength(T) orelse 1;
    const Vv = @Vector(Ww, T);
    const zero: Vv = @splat(0);
    var i: usize = 0;
    while (i + Ww <= buf.len) : (i += Ww) {
        buf[i..][0..Ww].* = zero;
    }
    for (buf[i..]) |*v| v.* = 0;
}

/// Standalone SIMD copy for generic T.
inline fn standaloneSimdCopy(comptime T: type, dst: []T, src: []const T) void {
    const Ww = std.simd.suggestVectorLength(T) orelse 1;
    var i: usize = 0;
    while (i + Ww <= dst.len) : (i += Ww) {
        dst[i..][0..Ww].* = src[i..][0..Ww].*;
    }
    for (dst[i..], src[i..]) |*d, s| d.* = s;
}

/// Period-average: dst[i] = (1/N) Σ_k samples[k][i].
fn averageSamples(comptime T: type, dst: []T, samples: []const []const T, num_samples: u32, nnz: u32) void {
    standaloneSimdZero(T, dst[0..nnz]);
    const inv_n: T = @floatCast(1.0 / @as(f64, @floatFromInt(num_samples)));
    for (0..num_samples) |k| {
        const src = samples[k];
        for (0..nnz) |i| {
            dst[i] += src[i];
        }
    }
    for (dst[0..nnz]) |*v| v.* *= inv_n;
}

/// Compute Fourier coefficient m of time-sampled sparse values.
/// out_re[i] = (1/N) Σ_k samples[k][i] * cos(2π*m*k/N)
/// out_im[i] = -(1/N) Σ_k samples[k][i] * sin(2π*m*k/N)
fn computeFourierCoeff(
    comptime T: type,
    out_re: []T,
    out_im: []T,
    samples: []const []const T,
    num_samples: u32,
    nnz: u32,
    m: u32,
) void {
    standaloneSimdZero(T, out_re[0..nnz]);
    standaloneSimdZero(T, out_im[0..nnz]);
    const inv_n: T = @floatCast(1.0 / @as(f64, @floatFromInt(num_samples)));
    for (0..num_samples) |k| {
        const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(m * k)) / @as(f64, @floatFromInt(num_samples));
        const cos_a: T = @floatCast(@cos(angle));
        const sin_a: T = @floatCast(@sin(angle));
        const src = samples[k];
        for (0..nnz) |i| {
            out_re[i] += src[i] * cos_a;
            out_im[i] += src[i] * sin_a;
        }
    }
    for (out_re[0..nnz]) |*v| v.* *= inv_n;
    for (out_im[0..nnz]) |*v| v.* *= inv_n;
}

/// Build the stacked-real 2n×2n CSC pattern from the n×n circuit pattern.
/// Column j (j < n): G-rows then C-rows+n.
/// Column j+n: -wC-rows then G-rows+n.
/// Mirrors freq_solve.zig's pattern construction.
fn buildStackedRealPattern(
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    sr_col_ptr: []u32,
    sr_row_idx: []u32,
) void {
    const nu: usize = n;
    var p: u32 = 0;
    sr_col_ptr[0] = 0;

    // First n columns: [G-block rows; wC-block rows + n]
    for (0..nu) |j| {
        const s = col_ptr[j];
        const e = col_ptr[j + 1];
        for (row_idx[s..e]) |r| {
            sr_row_idx[p] = r;
            p += 1;
        }
        for (row_idx[s..e]) |r| {
            sr_row_idx[p] = r + n;
            p += 1;
        }
        sr_col_ptr[j + 1] = p;
    }

    // Next n columns: [-wC-block rows; G-block rows + n]
    for (0..nu) |j| {
        const s = col_ptr[j];
        const e = col_ptr[j + 1];
        for (row_idx[s..e]) |r| {
            sr_row_idx[p] = r;
            p += 1;
        }
        for (row_idx[s..e]) |r| {
            sr_row_idx[p] = r + n;
            p += 1;
        }
        sr_col_ptr[nu + j + 1] = p;
    }
}

/// Fill stacked-real values for a given omega:
///   Column j (< n): [G_vals; +omega * C_vals]
///   Column j+n:     [-omega * C_vals; G_vals]
/// Mirrors freq_solve.zig setOmega.
fn fillStackedReal(
    comptime T: type,
    sr_vals: []T,
    g_vals: []const T,
    c_vals: []const T,
    col_ptr: []const u32,
    n: u32,
    omega: T,
) void {
    const nu: usize = n;
    var p: usize = 0;

    // First n columns: [G; +ωC]
    for (0..nu) |j| {
        const cs = col_ptr[j];
        const len = col_ptr[j + 1] - cs;
        standaloneSimdCopy(T, sr_vals[p..][0..len], g_vals[cs..][0..len]);
        p += len;
        scaleCopy(T, sr_vals[p..][0..len], c_vals[cs..][0..len], omega);
        p += len;
    }

    // Next n columns: [-ωC; G]
    for (0..nu) |j| {
        const cs = col_ptr[j];
        const len = col_ptr[j + 1] - cs;
        scaleCopy(T, sr_vals[p..][0..len], c_vals[cs..][0..len], -omega);
        p += len;
        standaloneSimdCopy(T, sr_vals[p..][0..len], g_vals[cs..][0..len]);
        p += len;
    }
}

fn scaleCopy(comptime T: type, dst: []T, src: []const T, s: T) void {
    for (dst, src) |*d, v| d.* = s * v;
}

/// Accumulate off-diagonal coupling SpMV into scratch vector.
/// For the banded preconditioner: computes G_{±1} * x_{neighbor} contribution
/// in stacked-real form.
fn accumulateCoupling(
    comptime T: type,
    scratch: []T,
    rhs: []const T,
    neighbor_idx: usize,
    n: usize,
    ns: usize,
    g_fourier_re: []const T,
    g_fourier_im: []const T,
    col_ptr: []const u32,
    row_idx: []const u32,
    n_u32: u32,
    omega0: T,
    p_signed: i32,
    transpose: bool,
) void {
    _ = omega0;
    _ = p_signed;
    _ = transpose;

    // Extract neighbor's re/im blocks
    const nb_re_off = neighbor_idx * n;
    const nb_im_off = ns * n + neighbor_idx * n;

    // SpMV: G_fourier (complex) * x_neighbor (complex) in stacked-real.
    // Re(result) += G_re * x_re - G_im * x_im
    // Im(result) += G_re * x_im + G_im * x_re
    // Done via CSC column-wise scatter (same pattern as circuit SpMV).
    const nu: usize = n_u32;
    for (0..nu) |j| {
        const cs = col_ptr[j];
        const ce = col_ptr[j + 1];
        const xr = rhs[nb_re_off + j];
        const xi = rhs[nb_im_off + j];
        for (cs..ce) |idx| {
            const row = row_idx[idx];
            scratch[row] += g_fourier_re[idx] * xr - g_fourier_im[idx] * xi;
            scratch[n + row] += g_fourier_re[idx] * xi + g_fourier_im[idx] * xr;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Helper: build a 2×2 CSC pattern for [diag + off-diag] circuit.
fn testPattern2x2() struct { col_ptr: [3]u32, row_idx: [4]u32 } {
    // Full 2×2: col 0 has rows {0,1}, col 1 has rows {0,1}
    return .{
        .col_ptr = .{ 0, 2, 4 },
        .row_idx = .{ 0, 1, 0, 1 },
    };
}

test "Preconditioner: LTI system, averaged_circulant is exact inverse" {
    // 2×2 diagonal G = [[2,0],[0,3]], C = [[0.1,0],[0,0.2]]
    // With constant G/C (LTI), the averaged preconditioner is the exact operator,
    // so P^{-1} * (operator * x) = x for any x.
    const gpa = testing.allocator;
    var pat = testPattern2x2();

    const num_harmonics: u32 = 1; // M=1, sidebands = 3 (p=-1,0,+1)
    const num_samples: u32 = 4;
    const omega0: f64 = 2.0 * std.math.pi * 1e3; // 1kHz fundamental

    // G = [2, 0; 0, 3] stored in CSC: vals = [2, 0, 0, 3]
    const g_vals = [_]f64{ 2.0, 0.0, 0.0, 3.0 };
    // C = [0.1, 0; 0, 0.2]
    const c_vals = [_]f64{ 0.1, 0.0, 0.0, 0.2 };

    // All samples identical (LTI)
    const g_slices = [_][]const f64{&g_vals} ** num_samples;
    const c_slices = [_][]const f64{&c_vals} ** num_samples;

    var prec = try Preconditioner(f64).init(
        gpa,
        2,
        &pat.col_ptr,
        &pat.row_idx,
        num_harmonics,
        num_samples,
        &g_slices,
        &c_slices,
        omega0,
        .averaged_circulant,
    );
    defer prec.deinit(gpa);

    // Build a test RHS: for sideband p, set up (G + jωpC) * x_known and verify
    // that apply recovers x_known.
    const ns: usize = 3; // 2*1+1
    const n: usize = 2;
    const vec_len = 2 * ns * n; // 12

    // Known solution: x_p = [1, 1] for all sidebands (re and im)
    var rhs: [vec_len]f64 = undefined;

    // For each sideband p, compute b_p = (G + jωpC) * [1;1]
    // In stacked-real: [G, -ωC; ωC, G] * [1;1;1;1]
    //   re = G*[1;1] - ωC*[1;1] = [2-0.1ω; 3-0.2ω]  (per sideband p)
    //   im = ωC*[1;1] + G*[1;1] = [0.1ω+2; 0.2ω+3]
    const M: i32 = 1;
    for (0..ns) |pi| {
        const p_signed: f64 = @floatFromInt(@as(i32, @intCast(pi)) - M);
        const wp = p_signed * omega0;

        // re part
        rhs[pi * n + 0] = 2.0 - 0.1 * wp; // G[0,0]*1 + G[0,1]*1 - wp*(C[0,0]*1 + C[0,1]*1) = 2 - 0.1*wp
        rhs[pi * n + 1] = 3.0 - 0.2 * wp;

        // im part
        rhs[ns * n + pi * n + 0] = 0.1 * wp + 2.0;
        rhs[ns * n + pi * n + 1] = 0.2 * wp + 3.0;
    }

    prec.apply(&rhs);

    // Should recover x = [1, 1, 1, 1, 1, 1 | 1, 1, 1, 1, 1, 1]
    for (0..vec_len) |i| {
        try testing.expectApproxEqAbs(@as(f64, 1.0), rhs[i], 1e-8);
    }
}

test "Preconditioner: dc_sample produces valid solve" {
    const gpa = testing.allocator;
    var pat = testPattern2x2();

    const g_vals = [_]f64{ 1.0, 0.0, 0.0, 1.0 }; // identity G
    const c_vals = [_]f64{ 0.0, 0.0, 0.0, 0.0 }; // zero C

    const g_slices = [_][]const f64{&g_vals} ** 2;
    const c_slices = [_][]const f64{&c_vals} ** 2;

    var prec = try Preconditioner(f64).init(
        gpa,
        2,
        &pat.col_ptr,
        &pat.row_idx,
        1, // M=1
        2,
        &g_slices,
        &c_slices,
        1.0,
        .dc_sample,
    );
    defer prec.deinit(gpa);

    // With G=I, C=0: P = I for all sidebands. apply should be identity.
    const ns: usize = 3;
    const n: usize = 2;
    var rhs: [2 * ns * n]f64 = undefined;
    for (&rhs, 0..) |*v, i| v.* = @floatFromInt(i + 1);

    var expected: [2 * ns * n]f64 = undefined;
    @memcpy(&expected, &rhs);

    prec.apply(&rhs);

    for (0..rhs.len) |i| {
        try testing.expectApproxEqAbs(expected[i], rhs[i], 1e-10);
    }
}

test "Preconditioner: applyT matches apply on symmetric system" {
    // Symmetric G, symmetric C → the stacked-real matrix is symmetric
    // (since [G, -ωC; ωC, G] with symmetric G,C is NOT symmetric — but
    // the LU factors give the same result when G is symmetric and C=0).
    const gpa = testing.allocator;
    var pat = testPattern2x2();

    // Symmetric G, zero C (so the stacked-real block is [G,0;0,G] = symmetric)
    const g_vals = [_]f64{ 2.0, 0.5, 0.5, 3.0 }; // symmetric 2×2
    const c_vals = [_]f64{ 0.0, 0.0, 0.0, 0.0 };

    const g_slices = [_][]const f64{&g_vals} ** 2;
    const c_slices = [_][]const f64{&c_vals} ** 2;

    var prec = try Preconditioner(f64).init(
        gpa,
        2,
        &pat.col_ptr,
        &pat.row_idx,
        1,
        2,
        &g_slices,
        &c_slices,
        0.0, // ω=0 so C doesn't matter → purely symmetric
        .averaged_circulant,
    );
    defer prec.deinit(gpa);

    const ns: usize = 3;
    const n: usize = 2;

    // Apply and applyT to same input should give same result (symmetric system)
    var rhs1: [2 * ns * n]f64 = undefined;
    var rhs2: [2 * ns * n]f64 = undefined;
    for (&rhs1, &rhs2, 0..) |*v1, *v2, i| {
        const val: f64 = @floatFromInt(i + 1);
        v1.* = val;
        v2.* = val;
    }

    prec.apply(&rhs1);
    prec.applyT(&rhs2);

    for (0..rhs1.len) |i| {
        try testing.expectApproxEqAbs(rhs1[i], rhs2[i], 1e-10);
    }
}

test "Preconditioner: non-trivial modulation, averaged vs dc_sample" {
    // Time-varying G: two samples with different conductances.
    // Both dc_sample and averaged_circulant should produce valid (finite) results
    // but they differ because they use different Jacobian approximations.
    const gpa = testing.allocator;
    var pat = testPattern2x2();

    // Sample 0: G = [1,0;0,2], Sample 1: G = [3,0;0,4]
    const g0 = [_]f64{ 1.0, 0.0, 0.0, 2.0 };
    const g1 = [_]f64{ 3.0, 0.0, 0.0, 4.0 };
    const c0 = [_]f64{ 0.1, 0.0, 0.0, 0.1 };
    const c1 = [_]f64{ 0.1, 0.0, 0.0, 0.1 };

    const g_slices = [_][]const f64{ &g0, &g1 };
    const c_slices = [_][]const f64{ &c0, &c1 };

    // Averaged: G_bar = [2,0;0,3]
    var prec_avg = try Preconditioner(f64).init(
        gpa, 2, &pat.col_ptr, &pat.row_idx,
        1, 2, &g_slices, &c_slices, 1.0, .averaged_circulant,
    );
    defer prec_avg.deinit(gpa);

    // DC-sample: uses G(t_0) = [1,0;0,2]
    var prec_dc = try Preconditioner(f64).init(
        gpa, 2, &pat.col_ptr, &pat.row_idx,
        1, 2, &g_slices, &c_slices, 1.0, .dc_sample,
    );
    defer prec_dc.deinit(gpa);

    const ns: usize = 3;
    const n: usize = 2;
    var rhs_avg: [2 * ns * n]f64 = undefined;
    var rhs_dc: [2 * ns * n]f64 = undefined;
    for (&rhs_avg, &rhs_dc, 0..) |*va, *vd, i| {
        const val: f64 = @floatFromInt(i + 1);
        va.* = val;
        vd.* = val;
    }

    prec_avg.apply(&rhs_avg);
    prec_dc.apply(&rhs_dc);

    // Both should produce finite results
    for (rhs_avg) |v| try testing.expect(std.math.isFinite(v));
    for (rhs_dc) |v| try testing.expect(std.math.isFinite(v));

    // They should differ (different Jacobian approximations with ω≠0)
    var any_diff = false;
    for (rhs_avg, rhs_dc) |a, d| {
        if (@abs(a - d) > 1e-12) {
            any_diff = true;
            break;
        }
    }
    try testing.expect(any_diff);
}

test "Preconditioner: block_banded initializes and applies" {
    // Smoke test: block_banded should at least produce finite results.
    const gpa = testing.allocator;
    var pat = testPattern2x2();

    const g0 = [_]f64{ 2.0, 0.1, 0.1, 3.0 };
    const g1 = [_]f64{ 2.5, 0.2, 0.2, 3.5 };
    const g2 = [_]f64{ 1.5, 0.05, 0.05, 2.5 };
    const g3 = [_]f64{ 2.0, 0.15, 0.15, 3.0 };
    const c_vals = [_]f64{ 0.1, 0.0, 0.0, 0.1 };

    const g_slices = [_][]const f64{ &g0, &g1, &g2, &g3 };
    const c_slices = [_][]const f64{ &c_vals, &c_vals, &c_vals, &c_vals };

    var prec = try Preconditioner(f64).init(
        gpa, 2, &pat.col_ptr, &pat.row_idx,
        1, 4, &g_slices, &c_slices, 1.0, .block_banded,
    );
    defer prec.deinit(gpa);

    const ns: usize = 3;
    const n: usize = 2;
    var rhs: [2 * ns * n]f64 = undefined;
    for (&rhs, 0..) |*v, i| v.* = @floatFromInt(i + 1);

    prec.apply(&rhs);

    for (rhs) |v| try testing.expect(std.math.isFinite(v));
}

test "Preconditioner: stacked-real pattern matches freq_solve layout" {
    // Verify the 2n×2n CSC pattern has the expected structure.
    var pat = testPattern2x2();
    const n: u32 = 2;
    const nnz = pat.col_ptr[n]; // 4
    var sr_col_ptr: [5]u32 = undefined; // 2n+1
    var sr_row_idx: [16]u32 = undefined; // 4*nnz

    buildStackedRealPattern(n, &pat.col_ptr, &pat.row_idx, &sr_col_ptr, &sr_row_idx);

    // Column 0 should have 4 entries: rows 0,1 (G block) then 2,3 (C block)
    try testing.expectEqual(@as(u32, 0), sr_col_ptr[0]);
    try testing.expectEqual(@as(u32, 4), sr_col_ptr[1]);
    try testing.expectEqual(@as(u32, 0), sr_row_idx[0]);
    try testing.expectEqual(@as(u32, 1), sr_row_idx[1]);
    try testing.expectEqual(@as(u32, 2), sr_row_idx[2]);
    try testing.expectEqual(@as(u32, 3), sr_row_idx[3]);

    // Total nnz should be 4 * original nnz
    try testing.expectEqual(@as(u32, 4 * nnz), sr_col_ptr[4]);
}

test "Preconditioner: averageSamples correctness" {
    const s0 = [_]f64{ 1.0, 2.0, 3.0 };
    const s1 = [_]f64{ 3.0, 4.0, 5.0 };
    const samples = [_][]const f64{ &s0, &s1 };
    var dst: [3]f64 = undefined;

    averageSamples(f64, &dst, &samples, 2, 3);

    try testing.expectApproxEqAbs(@as(f64, 2.0), dst[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.0), dst[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 4.0), dst[2], 1e-15);
}

test "Preconditioner: fillStackedReal correctness" {
    // 2×2 diagonal: G=[2,3], C=[0.1,0.2] (diagonal only, nnz=2)
    const col_ptr = [_]u32{ 0, 1, 2 };
    const g = [_]f64{ 2.0, 3.0 };
    const c = [_]f64{ 0.1, 0.2 };
    const omega: f64 = 10.0;
    var vals: [8]f64 = undefined; // 4*nnz = 8

    fillStackedReal(f64, &vals, &g, &c, &col_ptr, 2, omega);

    // Col 0 (< n): [G[0], ω*C[0]] = [2, 1.0]
    try testing.expectApproxEqAbs(@as(f64, 2.0), vals[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.0), vals[1], 1e-15);
    // Col 1 (< n): [G[1], ω*C[1]] = [3, 2.0]
    try testing.expectApproxEqAbs(@as(f64, 3.0), vals[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), vals[3], 1e-15);
    // Col 2 (≥ n): [-ω*C[0], G[0]] = [-1.0, 2.0]
    try testing.expectApproxEqAbs(@as(f64, -1.0), vals[4], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), vals[5], 1e-15);
    // Col 3 (≥ n): [-ω*C[1], G[1]] = [-2.0, 3.0]
    try testing.expectApproxEqAbs(@as(f64, -2.0), vals[6], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.0), vals[7], 1e-15);
}
