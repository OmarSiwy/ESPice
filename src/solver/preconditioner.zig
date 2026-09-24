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
//! The preconditioner operates in the DFT basis; apply needs no transform.

const std = @import("std");
const direct = @import("direct.zig");
const buildStackedRealPattern = @import("freq_solve.zig").buildStackedRealPattern;

const Allocator = std.mem.Allocator;

/// Structured HB/LPTV preconditioner, monomorphized per element type.
pub fn Preconditioner(comptime T: type) type {
    return struct {
        const Self = @This();

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
                    @memcpy(g_bar, g_samples[0][0..nnz]);
                    @memcpy(c_bar, c_samples[0][0..nnz]);
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
            var initialized: usize = 0;
            errdefer {
                for (solvers[0..initialized]) |*s| s.deinit();
                gpa.free(solvers);
            }
            for (solvers) |*s| {
                s.* = try direct.SolverT(T).init(gpa, 2 * n, sr_col_ptr, sr_row_idx, null);
                initialized += 1;
            }

            const sr_vals = try gpa.alloc(T, sr_nnz);
            errdefer gpa.free(sr_vals);

            // --- Block-banded: compute G_±1 Fourier coefficients ---
            var g_plus1: ?[]T = null;
            var g_minus1: ?[]T = null;
            var c_plus1: ?[]T = null;
            var c_minus1: ?[]T = null;
            var banded_scratch: ?[]T = null;
            errdefer inline for (.{ g_plus1, g_minus1, c_plus1, c_minus1, banded_scratch }) |buf| {
                if (buf) |v| gpa.free(v);
            };

            if (kind == .block_banded) {
                g_plus1 = try gpa.alloc(T, nnz);
                g_minus1 = try gpa.alloc(T, nnz);
                c_plus1 = try gpa.alloc(T, nnz);
                c_minus1 = try gpa.alloc(T, nnz);

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
                .g_plus1 = g_plus1,
                .g_minus1 = g_minus1,
                .c_plus1 = c_plus1,
                .c_minus1 = c_minus1,
                .banded_scratch = banded_scratch,
                .src_col_ptr = col_ptr,
                .src_row_idx = row_idx,
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
                @memcpy(scratch[0..n], rhs[re_off..][0..n]);
                @memcpy(scratch[n..][0..n], rhs[im_off..][0..n]);

                // Solve in-place
                if (transpose) {
                    self.solvers[pi].solveT(scratch, scratch);
                } else {
                    self.solvers[pi].solve(scratch, scratch);
                }

                // Write back
                @memcpy(rhs[re_off..][0..n], scratch[0..n]);
                @memcpy(rhs[im_off..][0..n], scratch[n..][0..n]);
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
            const scratch = self.banded_scratch orelse return;
            const n: usize = self.n;
            const ns = self.num_sidebands;
            const nn = 2 * n;

            // Compute off-diagonal contributions and correct
            for (0..ns) |pi| {
                const s_off = pi * nn;
                @memset(scratch[s_off..][0..nn], 0);

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
                        @as(i32, @intCast(pi)) - @as(i32, @intCast((ns - 1) / 2)),
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
                        @as(i32, @intCast(pi)) - @as(i32, @intCast((ns - 1) / 2)),
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

/// Period-average: dst[i] = (1/N) Σ_k samples[k][i].
fn averageSamples(comptime T: type, dst: []T, samples: []const []const T, num_samples: u32, nnz: u32) void {
    @memset(dst[0..nnz], 0);
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
    @memset(out_re[0..nnz], 0);
    @memset(out_im[0..nnz], 0);
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
        @memcpy(sr_vals[p..][0..len], g_vals[cs..][0..len]);
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
        @memcpy(sr_vals[p..][0..len], g_vals[cs..][0..len]);
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
    p_signed: i32,
) void {
    _ = p_signed;

    // Extract neighbor's re/im blocks
    const nb_re_off = neighbor_idx * n;
    const nb_im_off = ns * n + neighbor_idx * n;

    // SpMV: G_fourier (complex) * x_neighbor (complex) in stacked-real.
    // Re(result) += G_re * x_re - G_im * x_im
    // Im(result) += G_re * x_im + G_im * x_re
    // Done via CSC column-wise scatter (same pattern as circuit SpMV).
    for (0..n) |j| {
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

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .averageSamples = averageSamples,
    .fillStackedReal = fillStackedReal,
} else {};
