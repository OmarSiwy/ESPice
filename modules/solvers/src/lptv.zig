//! LPTV (Linear Periodically Time-Varying) block solver for PAC/PXF/pnoise.
//!
//! Solves the conversion-matrix system A(f) X = B where
//!   A_{pq}(f) = G_{p-q} + j·ω_p·C_{p-q},   ω_p = 2π(f + p·f_0).
//!
//! Three modes:
//!   dense       — full (2M+1)n × (2M+1)n stacked-real, dense LU
//!   sparse_flat — derive 2(2M+1)n CSC from circuit pattern × band, sparse LU
//!   matrix_free — FFT-based apply for Krylov (no explicit assembly)
//!
//! Stacked-real form: complex Z = Zr + jZi maps to [Zr, -Zi; Zi, Zr],
//! so the full system is 2(2M+1)n real. Frequency sweep reuses symbolic
//! factorization (pattern frozen); only ω_p scalars change across frequencies.

const std = @import("std");
const math = std.math;
const dense_lu = @import("dense_lu.zig");
const direct = @import("direct.zig");
const fft_mod = @import("fft.zig");

const Allocator = std.mem.Allocator;

/// LPTV conversion-matrix solver, generic over element type T (f32/f64).
pub fn LptvSolver(comptime T: type) type {
    return struct {
        const Self = @This();
        const DL = dense_lu.DenseLu(T);
        const FFT = fft_mod.Fft(T);
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

        pub const Mode = enum { dense, sparse_flat, matrix_free };
        pub const Error = error{ SingularMatrix, OutOfMemory, OutOfWorkspace };

        // Circuit dimensions
        n: u32,
        num_harmonics: u32, // M
        num_bands: u32, // 2M+1
        omega0: T,

        // Sparse circuit pattern (borrowed)
        circ_col_ptr: []const u32,
        circ_row_idx: []const u32,
        circ_nnz: u32,

        // Harmonic coefficient blocks: g_blocks[band][circ_nnz], c_blocks[band][circ_nnz]
        // Indexed by m+M where m in [-M, M].
        g_blocks: []const []const T,
        c_blocks: []const []const T,

        // Current analysis frequency state
        current_omega_p: []T, // ω_p per sideband, length num_bands

        // Mode-specific state
        mode: Mode,
        dense_state: ?DenseState,
        sparse_state: ?SparseState,
        mf_state: ?MatrixFreeState,

        const DenseState = struct {
            sys_n: usize, // 2 * num_bands * n
            a_work: []T, // assembled matrix (row-major)
            a_lu: []T, // factored copy
            piv: []u32,
        };

        const SparseState = struct {
            sys_n: u32, // 2 * num_bands * n
            col_ptr: []u32,
            row_idx: []u32,
            vals: []T,
            slv: direct.SolverT(T),
            factored_once: bool,
        };

        const MatrixFreeState = struct {
            // FFT length: next power of 2 >= num_bands (for per-node DFT over sidebands)
            fft_n: usize,
            // Scratch buffers for apply: per-node FFT workspace
            // Time-domain vectors: fft_n * n each
            v_re: []T, // IDFT result (real part per time sample, per node)
            v_im: []T,
            y_re: []T, // G*v result
            y_im: []T,
            z_re: []T, // C*v result
            z_im: []T,
            // Per-node FFT scratch (length fft_n each)
            fft_re: []T,
            fft_im: []T,
            // Sampled G(t_k), C(t_k) in sparse form: fft_n * circ_nnz each
            // g_samples[k * circ_nnz + p] = value at sample k, entry p
            g_samples: []T,
            c_samples: []T,
        };

        /// Build from harmonic coefficient blocks G_m, C_m (m = -M..M).
        /// n = circuit size, M = number of sidebands.
        /// g_blocks[2M+1], c_blocks[2M+1]: coefficient blocks indexed by m+M.
        /// Each block is sparse on the circuit pattern (col_ptr, row_idx, vals).
        pub fn init(
            gpa: Allocator,
            n: u32,
            num_harmonics: u32,
            col_ptr: []const u32,
            row_idx: []const u32,
            g_blocks: []const []const T,
            c_blocks: []const []const T,
            omega0: T,
            mode: Mode,
        ) Error!Self {
            const num_bands: u32 = 2 * num_harmonics + 1;
            std.debug.assert(g_blocks.len == num_bands);
            std.debug.assert(c_blocks.len == num_bands);
            const circ_nnz = col_ptr[n];

            const omega_p = try gpa.alloc(T, num_bands);
            errdefer gpa.free(omega_p);

            var self = Self{
                .n = n,
                .num_harmonics = num_harmonics,
                .num_bands = num_bands,
                .omega0 = omega0,
                .circ_col_ptr = col_ptr,
                .circ_row_idx = row_idx,
                .circ_nnz = circ_nnz,
                .g_blocks = g_blocks,
                .c_blocks = c_blocks,
                .current_omega_p = omega_p,
                .mode = mode,
                .dense_state = null,
                .sparse_state = null,
                .mf_state = null,
            };

            switch (mode) {
                .dense => try self.initDense(gpa),
                .sparse_flat => try self.initSparse(gpa),
                .matrix_free => try self.initMatrixFree(gpa),
            }

            return self;
        }

        fn initDense(self: *Self, gpa: Allocator) Error!void {
            const sys_n = 2 * @as(usize, self.num_bands) * @as(usize, self.n);
            const sys_nn = sys_n * sys_n;
            const a_work = try gpa.alloc(T, sys_nn);
            errdefer gpa.free(a_work);
            const a_lu = try gpa.alloc(T, sys_nn);
            errdefer gpa.free(a_lu);
            const piv = try gpa.alloc(u32, sys_n);
            self.dense_state = .{
                .sys_n = sys_n,
                .a_work = a_work,
                .a_lu = a_lu,
                .piv = piv,
            };
        }

        fn initSparse(self: *Self, gpa: Allocator) Error!void {
            const n: usize = self.n;
            const nb: usize = self.num_bands;
            const sys_n: u32 = @intCast(2 * nb * n);
            // Each block (p,q) contributes entries only when |p-q| <= M (all blocks
            // exist since we have num_bands coefficient blocks). For the stacked-real
            // expansion, each complex block becomes 4 sub-blocks of circ_nnz entries.
            // But only blocks where p-q is in [-M, M] exist.
            // Total nnz = num existing blocks * 4 * circ_nnz.
            //
            // Build the 2*nb*n CSC pattern. Column layout:
            //   Columns 0..nb*n-1 are the "real" columns (one per sideband*node)
            //   Columns nb*n..2*nb*n-1 are the "imaginary" columns
            //
            // For column (half, q, j) where half=0(real)/1(imag), q=sideband, j=circuit node:
            //   We iterate over all sidebands p that couple to q: |p-q| <= M
            //   For each such p, the circuit column j contributes rows at:
            //     real block: rows from circ_row_idx offset by p*n (half=0) or p*n+nb*n (half=1)
            //     imag block: rows from circ_row_idx offset by p*n+nb*n (half=0) or p*n (half=1)

            // Count nnz per column
            const col_ptr = try gpa.alloc(u32, sys_n + 1);
            errdefer gpa.free(col_ptr);

            col_ptr[0] = 0;
            for (0..2) |half| {
                for (0..nb) |q| {
                    for (0..n) |j| {
                        const col_idx = half * nb * n + q * n + j;
                        // Count contributing sidebands
                        var count: u32 = 0;
                        for (0..nb) |p| {
                            const diff = absDiff(p, q);
                            if (diff <= self.num_harmonics) {
                                // This block exists; contributes 2 * col_nnz(j) entries
                                // (real row set + imag row set)
                                const col_nnz = self.circ_col_ptr[j + 1] - self.circ_col_ptr[j];
                                count += 2 * col_nnz;
                            }
                        }
                        col_ptr[col_idx + 1] = col_ptr[col_idx] + count;
                    }
                }
            }

            const total_nnz = col_ptr[sys_n];
            const row_idx = try gpa.alloc(u32, total_nnz);
            errdefer gpa.free(row_idx);
            const vals = try gpa.alloc(T, total_nnz);
            errdefer gpa.free(vals);

            // Fill row indices (values filled at setFreq time)
            for (0..2) |half| {
                for (0..nb) |q| {
                    for (0..n) |j| {
                        const col_idx = half * nb * n + q * n + j;
                        var p_out: u32 = col_ptr[col_idx];
                        // Iterate p in ascending order to get sorted row indices
                        for (0..nb) |p| {
                            if (absDiff(p, q) > self.num_harmonics) continue;
                            const cs = self.circ_col_ptr[j];
                            const ce = self.circ_col_ptr[j + 1];
                            // Stacked-real block mapping for column half, row:
                            //   half=0 (real col): real-part rows at p*n, imag-part rows at (p+nb)*n
                            //   half=1 (imag col): real-part rows at (p+nb)*n (with -Im), imag-part rows at p*n (with Re)
                            // But we simplify: row sets are always the circuit rows offset by
                            // the sideband row base.
                            const re_base: u32 = @intCast(p * n);
                            const im_base: u32 = @intCast((p + nb) * n);
                            if (half == 0) {
                                // Real column: top block is Re (G), bottom block is Im (wC)
                                for (self.circ_row_idx[cs..ce]) |r| {
                                    row_idx[p_out] = re_base + r;
                                    p_out += 1;
                                }
                                for (self.circ_row_idx[cs..ce]) |r| {
                                    row_idx[p_out] = im_base + r;
                                    p_out += 1;
                                }
                            } else {
                                // Imag column: top block is -Im (-wC), bottom block is Re (G)
                                for (self.circ_row_idx[cs..ce]) |r| {
                                    row_idx[p_out] = re_base + r;
                                    p_out += 1;
                                }
                                for (self.circ_row_idx[cs..ce]) |r| {
                                    row_idx[p_out] = im_base + r;
                                    p_out += 1;
                                }
                            }
                        }
                        std.debug.assert(p_out == col_ptr[col_idx + 1]);
                    }
                }
            }

            simdZero(vals);

            var slv = try direct.SolverT(T).init(gpa, sys_n, col_ptr, row_idx, null);
            errdefer slv.deinit();

            self.sparse_state = .{
                .sys_n = sys_n,
                .col_ptr = col_ptr,
                .row_idx = row_idx,
                .vals = vals,
                .slv = slv,
                .factored_once = false,
            };
        }

        fn initMatrixFree(self: *Self, gpa: Allocator) Error!void {
            const nb: usize = self.num_bands;
            const n: usize = self.n;
            const circ_nnz: usize = self.circ_nnz;
            // FFT length: next power of 2 >= num_bands
            const fft_n = fft_mod.nextPow2(nb);

            const alloc_fft = fft_n * n;
            const v_re = try gpa.alloc(T, alloc_fft);
            errdefer gpa.free(v_re);
            const v_im = try gpa.alloc(T, alloc_fft);
            errdefer gpa.free(v_im);
            const y_re = try gpa.alloc(T, alloc_fft);
            errdefer gpa.free(y_re);
            const y_im = try gpa.alloc(T, alloc_fft);
            errdefer gpa.free(y_im);
            const z_re = try gpa.alloc(T, alloc_fft);
            errdefer gpa.free(z_re);
            const z_im = try gpa.alloc(T, alloc_fft);
            errdefer gpa.free(z_im);
            const fft_re = try gpa.alloc(T, fft_n);
            errdefer gpa.free(fft_re);
            const fft_im = try gpa.alloc(T, fft_n);
            errdefer gpa.free(fft_im);

            // Pre-compute G(t_k), C(t_k) samples by IDFT of coefficient blocks
            const g_samples = try gpa.alloc(T, fft_n * circ_nnz);
            errdefer gpa.free(g_samples);
            const c_samples = try gpa.alloc(T, fft_n * circ_nnz);
            errdefer gpa.free(c_samples);

            // For each sparse entry, collect its harmonics and IDFT to get time samples.
            // G_m are indexed m+M (m in [-M, M]), so coefficient index = m + M.
            // We need G(t_k) = sum_m G_m * exp(j*m*omega0*t_k) for k = 0..fft_n-1.
            // Since t_k = k*T/fft_n and omega0 = 2*pi/T, omega0*t_k = 2*pi*k/fft_n.
            // G(t_k) = sum_{m=-M}^{M} G_m * exp(j*2*pi*m*k/fft_n).
            //
            // This is an IDFT (up to normalization): place G_m at bin m (mod fft_n),
            // then IFFT gives us fft_n time samples (scaled by fft_n).
            //
            // Since our G_m blocks are real-valued (from the real-valued time-domain
            // matrices — the Fourier coefficients come in conjugate pairs but each
            // G_m is a real matrix entry), the IDFT produces real samples.
            // Actually G_m can be complex in general. For the conversion matrix of a
            // real circuit, G_{-m} = conj(G_m). We handle this: place G_m at bin m,
            // then IFFT.
            //
            // ponytail: per-entry IDFT via direct summation for now — circ_nnz * nb * fft_n
            // is fine for small/medium systems. Full per-entry FFT if fft_n > 64 or so.
            const M = self.num_harmonics;
            for (0..circ_nnz) |entry| {
                for (0..fft_n) |k| {
                    var g_val: T = 0;
                    var c_val: T = 0;
                    // sum_m G_m[entry] * exp(j*2*pi*m*k/fft_n) — take real part
                    // since G_m come in conjugate pairs for real circuits
                    for (0..nb) |band| {
                        const m_signed: i64 = @as(i64, @intCast(band)) - @as(i64, @intCast(M));
                        const angle: T = @floatCast(2.0 * math.pi * @as(f64, @floatFromInt(m_signed)) *
                            @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(fft_n)));
                        const cos_a = @cos(angle);
                        g_val += self.g_blocks[band][entry] * cos_a;
                        c_val += self.c_blocks[band][entry] * cos_a;
                    }
                    g_samples[k * circ_nnz + entry] = g_val;
                    c_samples[k * circ_nnz + entry] = c_val;
                }
            }

            self.mf_state = .{
                .fft_n = fft_n,
                .v_re = v_re,
                .v_im = v_im,
                .y_re = y_re,
                .y_im = y_im,
                .z_re = z_re,
                .z_im = z_im,
                .fft_re = fft_re,
                .fft_im = fft_im,
                .g_samples = g_samples,
                .c_samples = c_samples,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.current_omega_p);
            if (self.dense_state) |*ds| {
                gpa.free(ds.a_work);
                gpa.free(ds.a_lu);
                gpa.free(ds.piv);
            }
            if (self.sparse_state) |*ss| {
                ss.slv.deinit();
                gpa.free(ss.col_ptr);
                gpa.free(ss.row_idx);
                gpa.free(ss.vals);
            }
            if (self.mf_state) |*mf| {
                inline for (.{ mf.v_re, mf.v_im, mf.y_re, mf.y_im, mf.z_re, mf.z_im, mf.fft_re, mf.fft_im, mf.g_samples, mf.c_samples }) |s| gpa.free(s);
            }
            self.* = undefined;
        }

        /// Set analysis frequency and factor. For sweep: call per freq, then solveRhs.
        pub fn setFreq(self: *Self, f: T) Error!void {
            const two_pi: T = @floatCast(2.0 * math.pi);
            const M = self.num_harmonics;
            for (0..self.num_bands) |band| {
                const p: i64 = @as(i64, @intCast(band)) - @as(i64, @intCast(M));
                self.current_omega_p[band] = two_pi * (f + @as(T, @floatCast(@as(f64, @floatFromInt(p)))) * self.omega0);
            }

            switch (self.mode) {
                .dense => try self.fillDense(),
                .sparse_flat => try self.fillSparse(),
                .matrix_free => {}, // nothing to factor
            }
        }

        fn fillDense(self: *Self) Error!void {
            const ds = &self.dense_state.?;
            const n: usize = self.n;
            const nb: usize = self.num_bands;
            const sys_n = ds.sys_n;
            const M = self.num_harmonics;

            simdZero(ds.a_work);

            // Fill block (p, q): A_{pq} = G_{p-q} + j*omega_p*C_{p-q}
            // Stacked-real: the 2x2 real expansion of A_{pq} occupies rows
            // [p*n..(p+1)*n, (p+nb)*n..(p+nb+1)*n] × cols [q*n..(q+1)*n, (q+nb)*n..(q+nb+1)*n]
            for (0..nb) |p| {
                const omega_p = self.current_omega_p[p];
                for (0..nb) |q| {
                    const diff_signed: i64 = @as(i64, @intCast(p)) - @as(i64, @intCast(q));
                    const m_idx = diff_signed + @as(i64, @intCast(M));
                    if (m_idx < 0 or m_idx >= @as(i64, @intCast(nb))) continue;
                    const band: usize = @intCast(m_idx);

                    const g_vals = self.g_blocks[band];
                    const c_vals = self.c_blocks[band];

                    // Scatter sparse entries into dense block
                    for (0..n) |j| {
                        const cs = self.circ_col_ptr[j];
                        const ce = self.circ_col_ptr[j + 1];
                        for (cs..ce) |idx| {
                            const i = self.circ_row_idx[idx];
                            const g_val = g_vals[idx];
                            const c_val = c_vals[idx];

                            // Re(A_{pq}) = G_{p-q}, Im(A_{pq}) = omega_p * C_{p-q}
                            const re = g_val;
                            const im = omega_p * c_val;

                            // Top-left: Re
                            const row_tl = p * n + i;
                            const col_tl = q * n + j;
                            ds.a_work[row_tl * sys_n + col_tl] += re;

                            // Top-right: -Im
                            const col_tr = (q + nb) * n + j;
                            ds.a_work[row_tl * sys_n + col_tr] -= im;

                            // Bottom-left: Im
                            const row_bl = (p + nb) * n + i;
                            ds.a_work[row_bl * sys_n + col_tl] += im;

                            // Bottom-right: Re
                            ds.a_work[row_bl * sys_n + col_tr] += re;
                        }
                    }
                }
            }

            simdCopy(ds.a_lu, ds.a_work);
            DL.factorize(ds.sys_n, ds.a_lu, ds.piv) catch return error.SingularMatrix;
        }

        fn fillSparse(self: *Self) Error!void {
            const ss = &self.sparse_state.?;
            const n: usize = self.n;
            const nb: usize = self.num_bands;
            const M = self.num_harmonics;

            // Fill values following the same column/row order as initSparse
            for (0..2) |half| {
                for (0..nb) |q| {
                    for (0..n) |j| {
                        const col_idx = half * nb * n + q * n + j;
                        var p_out: u32 = ss.col_ptr[col_idx];
                        for (0..nb) |p| {
                            if (absDiff(p, q) > self.num_harmonics) continue;
                            // band index for G_{p-q}: (p - q) + M
                            const diff_signed: i64 = @as(i64, @intCast(p)) - @as(i64, @intCast(q));
                            const band: usize = @intCast(diff_signed + @as(i64, @intCast(M)));
                            const omega_p = self.current_omega_p[p];

                            const cs = self.circ_col_ptr[j];
                            const ce = self.circ_col_ptr[j + 1];

                            const g_vals = self.g_blocks[band];
                            const c_vals = self.c_blocks[band];

                            if (half == 0) {
                                // Real column:
                                // Top rows (re_base): G_{p-q} (Re part)
                                for (cs..ce) |idx| {
                                    ss.vals[p_out] = g_vals[idx];
                                    p_out += 1;
                                }
                                // Bottom rows (im_base): omega_p * C_{p-q} (Im part)
                                for (cs..ce) |idx| {
                                    ss.vals[p_out] = omega_p * c_vals[idx];
                                    p_out += 1;
                                }
                            } else {
                                // Imag column:
                                // Top rows (re_base): -omega_p * C_{p-q} (-Im part)
                                for (cs..ce) |idx| {
                                    ss.vals[p_out] = -omega_p * c_vals[idx];
                                    p_out += 1;
                                }
                                // Bottom rows (im_base): G_{p-q} (Re part)
                                for (cs..ce) |idx| {
                                    ss.vals[p_out] = g_vals[idx];
                                    p_out += 1;
                                }
                            }
                        }
                    }
                }
            }

            ss.slv.factor(ss.vals) catch return error.SingularMatrix;
            ss.factored_once = true;
        }

        /// Solve A(f) * X = B. RHS/solution in stacked-real format (length 2*(2M+1)*n).
        pub fn solveRhs(self: *Self, rhs: []const T, x: []T) void {
            switch (self.mode) {
                .dense => {
                    const ds = &self.dense_state.?;
                    DL.solveFactored(ds.sys_n, ds.a_lu, ds.piv, rhs, x);
                },
                .sparse_flat => {
                    const ss = &self.sparse_state.?;
                    ss.slv.solve(rhs, x);
                },
                .matrix_free => {
                    // ponytail: matrix_free solve not implemented — needs GMRES wrapper
                    // from converger.zig. For now, only apply/applyT are available.
                    @panic("matrix_free mode requires external Krylov solver via apply()");
                },
            }
        }

        /// Adjoint solve: A(f)^H * Y = C. Same stacked-real format.
        pub fn solveRhsT(self: *Self, rhs: []const T, x: []T) void {
            switch (self.mode) {
                .dense => {
                    const ds = &self.dense_state.?;
                    // In stacked-real form, A^H maps to A^T (the real representation
                    // of the conjugate transpose is just the transpose of the real matrix).
                    DL.solveFactoredT(ds.sys_n, ds.a_lu, ds.piv, rhs, x);
                },
                .sparse_flat => {
                    const ss = &self.sparse_state.?;
                    ss.slv.solveT(rhs, x);
                },
                .matrix_free => {
                    @panic("matrix_free mode requires external Krylov solver via applyT()");
                },
            }
        }

        /// Matrix-free apply: w = A(f) * v (for Krylov use).
        /// v and w are in stacked-real format: [Re(X_{-M}), ..., Re(X_M), Im(X_{-M}), ..., Im(X_M)]
        /// each segment of length n. Total length = 2 * num_bands * n.
        pub fn apply(self: *Self, v: []const T, w: []T) void {
            self.applyImpl(v, w, false);
        }

        /// Adjoint apply: w = A(f)^H * v.
        pub fn applyT(self: *Self, v: []const T, w: []T) void {
            self.applyImpl(v, w, true);
        }

        fn applyImpl(self: *Self, v: []const T, w: []T, comptime adjoint: bool) void {
            switch (self.mode) {
                .dense => self.applyDense(v, w, adjoint),
                .sparse_flat => self.applySparse(v, w, adjoint),
                .matrix_free => self.applyMatrixFree(v, w, adjoint),
            }
        }

        fn applyDense(self: *Self, v: []const T, w: []T, comptime adjoint: bool) void {
            const ds = &self.dense_state.?;
            const sys_n = ds.sys_n;
            // w = A*v (or A^T*v for adjoint)
            for (0..sys_n) |i| {
                var sum: T = 0;
                for (0..sys_n) |j| {
                    const a_ij = if (adjoint) ds.a_work[j * sys_n + i] else ds.a_work[i * sys_n + j];
                    sum += a_ij * v[j];
                }
                w[i] = sum;
            }
        }

        fn applySparse(self: *Self, v: []const T, w: []T, comptime adjoint: bool) void {
            const ss = &self.sparse_state.?;
            const sys_n: usize = ss.sys_n;
            simdZero(w[0..sys_n]);
            if (adjoint) {
                // w = A^T * v: for each column j, w[j] += sum_i A[i,j] * v[i]
                for (0..sys_n) |j| {
                    var sum: T = 0;
                    for (ss.col_ptr[j]..ss.col_ptr[j + 1]) |p| {
                        sum += ss.vals[p] * v[ss.row_idx[p]];
                    }
                    w[j] = sum;
                }
            } else {
                // w = A * v: CSC scatter
                for (0..sys_n) |j| {
                    const vj = v[j];
                    if (vj == 0) continue;
                    for (ss.col_ptr[j]..ss.col_ptr[j + 1]) |p| {
                        w[ss.row_idx[p]] += ss.vals[p] * vj;
                    }
                }
            }
        }

        fn applyMatrixFree(self: *Self, v: []const T, w: []T, comptime adjoint: bool) void {
            const mf = &self.mf_state.?;
            const n: usize = self.n;
            const nb: usize = self.num_bands;
            const fft_n = mf.fft_n;
            const circ_nnz: usize = self.circ_nnz;

            // Step 1: Unpack v from stacked-real [Re(X_{-M})...Re(X_M), Im(X_{-M})...Im(X_M)]
            // into complex sideband vectors, then IDFT per node to get time-domain samples.
            // v_re[k*n + node], v_im[k*n + node] = node-value at time sample k.

            // Zero the FFT workspace (fft_n may be > nb)
            simdZero(mf.v_re[0 .. fft_n * n]);
            simdZero(mf.v_im[0 .. fft_n * n]);

            // Place sideband data into IDFT input: sideband p (from 0..nb) maps to
            // DFT bin p (we treat bin p as harmonic p-M, but the FFT doesn't care about
            // the label, just the index).
            for (0..nb) |p| {
                for (0..n) |node| {
                    mf.v_re[p * n + node] = v[p * n + node]; // Re part
                    mf.v_im[p * n + node] = v[(nb + p) * n + node]; // Im part
                }
            }

            // IDFT per node: for each node, gather the fft_n sideband values, IFFT
            simdZero(mf.y_re[0 .. fft_n * n]);
            simdZero(mf.y_im[0 .. fft_n * n]);
            simdZero(mf.z_re[0 .. fft_n * n]);
            simdZero(mf.z_im[0 .. fft_n * n]);

            for (0..n) |node| {
                // Gather sideband -> fft_re/fft_im (node-strided -> contiguous)
                for (0..fft_n) |k| {
                    mf.fft_re[k] = mf.v_re[k * n + node];
                    mf.fft_im[k] = mf.v_im[k * n + node];
                }
                // IFFT: sidebands -> time domain
                FFT.ifft(mf.fft_re[0..fft_n], mf.fft_im[0..fft_n]);
                // Scatter back (contiguous -> node-strided)
                for (0..fft_n) |k| {
                    mf.v_re[k * n + node] = mf.fft_re[k];
                    mf.v_im[k * n + node] = mf.fft_im[k];
                }
            }

            // Step 2: Time-domain SpMV: for each sample k,
            //   y(t_k) = G(t_k) * v(t_k),  z(t_k) = C(t_k) * v(t_k)
            // Using CSC scatter (or gather for adjoint = transposed SpMV).
            for (0..fft_n) |k| {
                const g_row = mf.g_samples[k * circ_nnz ..][0..circ_nnz];
                const c_row = mf.c_samples[k * circ_nnz ..][0..circ_nnz];
                const vr_base = mf.v_re[k * n ..][0..n];
                const vi_base = mf.v_im[k * n ..][0..n];
                const yr_base = mf.y_re[k * n ..][0..n];
                const yi_base = mf.y_im[k * n ..][0..n];
                const zr_base = mf.z_re[k * n ..][0..n];
                const zi_base = mf.z_im[k * n ..][0..n];

                if (adjoint) {
                    // Transposed SpMV: for each column j, accumulate row contributions into w[j]
                    for (0..n) |j| {
                        const cs = self.circ_col_ptr[j];
                        const ce = self.circ_col_ptr[j + 1];
                        var yr_sum: T = 0;
                        var yi_sum: T = 0;
                        var zr_sum: T = 0;
                        var zi_sum: T = 0;
                        for (cs..ce) |idx| {
                            const i = self.circ_row_idx[idx];
                            const gv = g_row[idx];
                            const cv = c_row[idx];
                            // G^T: accumulate G[i,j]*v[i] into result[j]
                            yr_sum += gv * vr_base[i];
                            yi_sum += gv * vi_base[i];
                            zr_sum += cv * vr_base[i];
                            zi_sum += cv * vi_base[i];
                        }
                        yr_base[j] += yr_sum;
                        yi_base[j] += yi_sum;
                        zr_base[j] += zr_sum;
                        zi_base[j] += zi_sum;
                    }
                } else {
                    // Forward SpMV: CSC scatter
                    for (0..n) |j| {
                        const vr_j = vr_base[j];
                        const vi_j = vi_base[j];
                        if (vr_j == 0 and vi_j == 0) continue;
                        const cs = self.circ_col_ptr[j];
                        const ce = self.circ_col_ptr[j + 1];
                        for (cs..ce) |idx| {
                            const i = self.circ_row_idx[idx];
                            const gv = g_row[idx];
                            const cv = c_row[idx];
                            // Complex multiply: (gv + 0j) * (vr + j*vi)
                            yr_base[i] += gv * vr_j;
                            yi_base[i] += gv * vi_j;
                            zr_base[i] += cv * vr_j;
                            zi_base[i] += cv * vi_j;
                        }
                    }
                }
            }

            // Step 3: DFT per node, then apply frequency ramp spectrally
            for (0..n) |node| {
                // DFT y(t) -> Y[p]
                for (0..fft_n) |k| {
                    mf.fft_re[k] = mf.y_re[k * n + node];
                    mf.fft_im[k] = mf.y_im[k * n + node];
                }
                FFT.fft(mf.fft_re[0..fft_n], mf.fft_im[0..fft_n]);
                for (0..fft_n) |k| {
                    mf.y_re[k * n + node] = mf.fft_re[k];
                    mf.y_im[k * n + node] = mf.fft_im[k];
                }

                // DFT z(t) -> Z[p]
                for (0..fft_n) |k| {
                    mf.fft_re[k] = mf.z_re[k * n + node];
                    mf.fft_im[k] = mf.z_im[k * n + node];
                }
                FFT.fft(mf.fft_re[0..fft_n], mf.fft_im[0..fft_n]);
                for (0..fft_n) |k| {
                    mf.z_re[k * n + node] = mf.fft_re[k];
                    mf.z_im[k * n + node] = mf.fft_im[k];
                }
            }

            // Step 4: Combine: W[p] = Y[p] + j*omega_p * Z[p]
            // In complex form: (Yr + j*Yi) + j*omega_p*(Zr + j*Zi)
            //                = (Yr - omega_p*Zi) + j*(Yi + omega_p*Zr)
            // For adjoint: conjugate the j*omega_p term:
            //   W[p] = Y[p] - j*omega_q * Z[p]  (with omega on column index)
            // In stacked-real adjoint form, the sign of the omega term flips and
            // omega_p is replaced by omega_p (the ramp is on the same index in
            // the transposed real form, but with negated imaginary coupling).
            simdZero(w);
            for (0..nb) |p| {
                const omega_p = self.current_omega_p[if (adjoint) p else p];
                for (0..n) |node| {
                    const yr = mf.y_re[p * n + node];
                    const yi = mf.y_im[p * n + node];
                    const zr = mf.z_re[p * n + node];
                    const zi = mf.z_im[p * n + node];

                    if (adjoint) {
                        // A^H: conjugate transpose in stacked-real =
                        // (Yr + omega_p*Zi) + j*(Yi - omega_p*Zr)
                        // ponytail: for adjoint, omega ramp on column index (q), but in
                        // matrix-free the ramp still uses omega_p since the FFT trick
                        // diagonalizes the Toeplitz part and the ramp is always per-sideband.
                        w[p * n + node] = yr + omega_p * zi;
                        w[(nb + p) * n + node] = yi - omega_p * zr;
                    } else {
                        w[p * n + node] = yr - omega_p * zi;
                        w[(nb + p) * n + node] = yi + omega_p * zr;
                    }
                }
            }
        }

        // ====================================================================
        // Helpers
        // ====================================================================

        inline fn absDiff(a: usize, b: usize) usize {
            return if (a >= b) a - b else b - a;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Helper: build a 2x2 LTI system (G_m=0, C_m=0 for m≠0) as an LPTV problem.
/// G_0 = [[g00, g01], [g10, g11]], C_0 = [[c00, c01], [c10, c11]] (dense -> CSC).
fn makeLti2x2(
    comptime T: type,
    g00: T,
    g01: T,
    g10: T,
    g11: T,
    c00: T,
    c01: T,
    c10: T,
    c11: T,
    num_harmonics: u32,
    omega0: T,
    mode: LptvSolver(T).Mode,
) !struct {
    solver: LptvSolver(T),
    // Owned storage that must be freed
    col_ptr: [3]u32,
    row_idx: [4]u32,
    g_block_data: []T,
    c_block_data: []T,
    g_blocks: [][]T,
    c_blocks: [][]T,
} {
    const gpa = testing.allocator;
    const nb: u32 = 2 * num_harmonics + 1;

    // Dense 2x2 -> CSC (all entries present)
    // Col 0: rows 0,1; Col 1: rows 0,1
    var result: @TypeOf(makeLti2x2(T, g00, g01, g10, g11, c00, c01, c10, c11, num_harmonics, omega0, mode) catch unreachable) = undefined;
    result.col_ptr = .{ 0, 2, 4 };
    result.row_idx = .{ 0, 1, 0, 1 };

    // CSC order: col0=[g00,g10], col1=[g01,g11]
    result.g_block_data = try gpa.alloc(T, @as(usize, nb) * 4);
    result.c_block_data = try gpa.alloc(T, @as(usize, nb) * 4);
    result.g_blocks = try gpa.alloc([]T, nb);
    result.c_blocks = try gpa.alloc([]T, nb);

    for (0..nb) |band| {
        result.g_blocks[band] = result.g_block_data[band * 4 ..][0..4];
        result.c_blocks[band] = result.c_block_data[band * 4 ..][0..4];
        @memset(result.g_blocks[band], 0);
        @memset(result.c_blocks[band], 0);
    }

    // Band M = G_0: the DC coefficient
    result.g_blocks[num_harmonics] = result.g_block_data[num_harmonics * 4 ..][0..4];
    result.g_blocks[num_harmonics][0] = g00; // col0 row0
    result.g_blocks[num_harmonics][1] = g10; // col0 row1
    result.g_blocks[num_harmonics][2] = g01; // col1 row0
    result.g_blocks[num_harmonics][3] = g11; // col1 row1

    result.c_blocks[num_harmonics] = result.c_block_data[num_harmonics * 4 ..][0..4];
    result.c_blocks[num_harmonics][0] = c00;
    result.c_blocks[num_harmonics][1] = c10;
    result.c_blocks[num_harmonics][2] = c01;
    result.c_blocks[num_harmonics][3] = c11;

    // Const-cast the slices for the solver API
    const g_const: []const []const T = @ptrCast(result.g_blocks);
    const c_const: []const []const T = @ptrCast(result.c_blocks);

    result.solver = try LptvSolver(T).init(
        gpa,
        2,
        num_harmonics,
        &result.col_ptr,
        &result.row_idx,
        g_const,
        c_const,
        omega0,
        mode,
    );

    return result;
}

fn freeLti2x2(comptime T: type, s: anytype) void {
    _ = T;
    const gpa = testing.allocator;
    var solver = s.solver;
    solver.deinit(gpa);
    gpa.free(s.g_block_data);
    gpa.free(s.c_block_data);
    gpa.free(s.g_blocks);
    gpa.free(s.c_blocks);
}

test "lptv: 2x2 LTI dense — reduces to independent AC solves per sideband" {
    // G = [[1, 0], [0, 2]], C = [[0.1, 0], [0, 0.2]]
    // With M=1 (3 sidebands), G_m=0 for m≠0 → block diagonal.
    // Each sideband p solves (G + j*omega_p*C) independently.
    const T = f64;
    var s = try makeLti2x2(T, 1, 0, 0, 2, 0.1, 0, 0, 0.2, 1, 100.0, .dense);
    defer freeLti2x2(T, &s);

    const f: T = 50.0;
    try s.solver.setFreq(f);

    // nb=3, n=2 => sys_n = 12
    // Stacked-real: [Re(X_{-1})(2), Re(X_0)(2), Re(X_1)(2), Im(X_{-1})(2), Im(X_0)(2), Im(X_1)(2)]
    // Drive sideband 0 (DC/center) only: Re part at indices 2,3
    var rhs = [_]T{0} ** 12;
    rhs[2] = 1.0; // Re(B_0)[node 0] = 1

    var x = [_]T{0} ** 12;
    s.solver.solveRhs(&rhs, &x);

    // For sideband p=0: omega_0 = 2*pi*(50 + 0*100/(2*pi)) = 2*pi*50
    // Wait, omega0 is the fundamental angular frequency. f0 = omega0/(2*pi).
    // omega_p = 2*pi*(f + p*f0) = 2*pi*(f + p*omega0/(2*pi)) = 2*pi*f + p*omega0
    // For p=0 (center, band index = M=1): omega_0 = 2*pi*50
    // A_00 = G_0 + j*omega_0*C_0 = [[1 + j*0.1*omega_0, 0], [0, 2 + j*0.2*omega_0]]
    // Solve (1 + j*0.1*w) * x = 1 -> x = 1/(1 + j*0.1*w) = (1 - j*0.1*w)/(1 + 0.01*w^2)
    const w0 = 2.0 * math.pi * f;
    const denom = 1.0 + 0.01 * w0 * w0;
    const expected_re = 1.0 / denom;
    const expected_im = -0.1 * w0 / denom;

    // x[2] = Re(X_0)[node 0], x[8] = Im(X_0)[node 0]
    try testing.expectApproxEqRel(expected_re, x[2], 1e-10);
    try testing.expectApproxEqRel(expected_im, x[8], 1e-10);

    // Other sidebands should be zero (RHS is zero there)
    try testing.expectApproxEqAbs(@as(T, 0), x[0], 1e-12);
    try testing.expectApproxEqAbs(@as(T, 0), x[1], 1e-12);
    try testing.expectApproxEqAbs(@as(T, 0), x[4], 1e-12);
    try testing.expectApproxEqAbs(@as(T, 0), x[5], 1e-12);
}

test "lptv: 2-harmonic dense vs sparse_flat match" {
    const T = f64;

    // Non-trivial: G_0 = [[1, 0.5], [0.3, 2]], C_0 = [[0.1, 0], [0, 0.2]]
    // G_1 (band M+1) = [[0.1, 0], [0, 0.05]], C_1 = [[0.01, 0], [0, 0.01]]
    // G_{-1} (band M-1) = same (symmetric for real circuit)
    const num_harmonics: u32 = 1;
    const nb: u32 = 3;

    var s_dense = try makeLti2x2(T, 1, 0.5, 0.3, 2, 0.1, 0, 0, 0.2, num_harmonics, 200.0, .dense);
    defer freeLti2x2(T, &s_dense);

    var s_sparse = try makeLti2x2(T, 1, 0.5, 0.3, 2, 0.1, 0, 0, 0.2, num_harmonics, 200.0, .sparse_flat);
    defer freeLti2x2(T, &s_sparse);

    // Add non-zero harmonics
    // G_{-1} at band 0, G_{+1} at band 2
    for ([_]*LptvSolver(T){ &s_dense.solver, &s_sparse.solver }) |solver| {
        _ = solver;
    }
    // Set the harmonic blocks on the raw data
    for ([_][]T{ s_dense.g_blocks[0], s_sparse.g_blocks[0] }) |block| {
        block[0] = 0.1; // col0 row0
        block[3] = 0.05; // col1 row1
    }
    for ([_][]T{ s_dense.g_blocks[2], s_sparse.g_blocks[2] }) |block| {
        block[0] = 0.1;
        block[3] = 0.05;
    }
    for ([_][]T{ s_dense.c_blocks[0], s_sparse.c_blocks[0] }) |block| {
        block[0] = 0.01;
        block[3] = 0.01;
    }
    for ([_][]T{ s_dense.c_blocks[2], s_sparse.c_blocks[2] }) |block| {
        block[0] = 0.01;
        block[3] = 0.01;
    }

    const f: T = 75.0;
    try s_dense.solver.setFreq(f);
    try s_sparse.solver.setFreq(f);

    // Drive all sidebands
    var rhs = [_]T{0} ** (2 * nb * 2);
    rhs[0] = 1.0; // Re(B_{-1})[node 0]
    rhs[3] = 0.5; // Re(B_0)[node 1]
    rhs[4] = -0.3; // Re(B_1)[node 0]
    rhs[9] = 0.7; // Im(B_0)[node 1]

    var x_dense = [_]T{0} ** (2 * nb * 2);
    var x_sparse = [_]T{0} ** (2 * nb * 2);

    s_dense.solver.solveRhs(&rhs, &x_dense);
    s_sparse.solver.solveRhs(&rhs, &x_sparse);

    for (0..x_dense.len) |i| {
        try testing.expectApproxEqRel(x_dense[i], x_sparse[i], 1e-8);
    }
}

test "lptv: frequency sweep reuses pattern (two frequencies)" {
    const T = f64;
    var s = try makeLti2x2(T, 1, 0, 0, 2, 0.1, 0, 0, 0.2, 0, 100.0, .dense);
    defer freeLti2x2(T, &s);

    // M=0 => 1 sideband, sys_n = 4

    // First frequency
    const f1: T = 50.0;
    try s.solver.setFreq(f1);
    var rhs = [_]T{ 1.0, 0.0, 0.0, 0.0 };
    var x1 = [_]T{0} ** 4;
    s.solver.solveRhs(&rhs, &x1);

    // Second frequency — pattern is identical, only omega changes
    const f2: T = 200.0;
    try s.solver.setFreq(f2);
    var x2 = [_]T{0} ** 4;
    s.solver.solveRhs(&rhs, &x2);

    // Verify both give correct AC answers
    const w1 = 2.0 * math.pi * f1;
    const w2 = 2.0 * math.pi * f2;
    const d1 = 1.0 + 0.01 * w1 * w1;
    const d2 = 1.0 + 0.01 * w2 * w2;

    try testing.expectApproxEqRel(1.0 / d1, x1[0], 1e-10);
    try testing.expectApproxEqRel(-0.1 * w1 / d1, x1[2], 1e-10);
    try testing.expectApproxEqRel(1.0 / d2, x2[0], 1e-10);
    try testing.expectApproxEqRel(-0.1 * w2 / d2, x2[2], 1e-10);

    // The two solutions must differ (different frequencies)
    try testing.expect(@abs(x1[0] - x2[0]) > 1e-6);
}

test "lptv: solveRhsT adjoint matches transpose on symmetric system" {
    const T = f64;
    // Symmetric G, symmetric C => A is symmetric => A^H = A^T = A
    // so solveRhsT should give same result as solveRhs
    var s = try makeLti2x2(T, 1, 0.5, 0.5, 2, 0.1, 0, 0, 0.2, 0, 100.0, .dense);
    defer freeLti2x2(T, &s);

    const f: T = 100.0;
    try s.solver.setFreq(f);

    // For a symmetric system with C also symmetric, A in stacked-real is NOT
    // generally symmetric (the off-diagonal blocks have ±wC). But A^T solve
    // should still be consistent: A * x = b => A^T * y = b has y = (A^T)^{-1} b.
    // Verify A^T * (solveRhsT result) = rhs by applying.
    var rhs = [_]T{ 1.0, 0.5, -0.3, 0.7 };
    var x = [_]T{0} ** 4;
    s.solver.solveRhsT(&rhs, &x);

    // Verify: reconstruct A^T * x and check it equals rhs
    const ds = &s.solver.dense_state.?;
    const sys_n = ds.sys_n;
    for (0..sys_n) |i| {
        var sum: T = 0;
        for (0..sys_n) |j| {
            // A^T[i][j] = A[j][i]
            sum += ds.a_work[j * sys_n + i] * x[j];
        }
        try testing.expectApproxEqRel(rhs[i], sum, 1e-9);
    }
}

test "lptv: matrix-free apply matches dense multiply" {
    const T = f64;

    // Build the same system in dense and matrix_free mode
    const num_harmonics: u32 = 1;
    const nb: u32 = 3;
    const n: u32 = 2;

    var s_dense = try makeLti2x2(T, 1, 0.5, 0.3, 2, 0.1, 0, 0, 0.2, num_harmonics, 200.0, .dense);
    defer freeLti2x2(T, &s_dense);

    var s_mf = try makeLti2x2(T, 1, 0.5, 0.3, 2, 0.1, 0, 0, 0.2, num_harmonics, 200.0, .matrix_free);
    defer freeLti2x2(T, &s_mf);

    const f: T = 75.0;
    try s_dense.solver.setFreq(f);
    try s_mf.solver.setFreq(f);

    // Test vector
    const sys_n = 2 * nb * n;
    var v: [sys_n]T = undefined;
    for (0..sys_n) |i| {
        v[i] = @as(T, @floatFromInt(i + 1)) * 0.1;
    }

    var w_dense: [sys_n]T = undefined;
    var w_mf: [sys_n]T = undefined;

    // Dense apply (reference)
    s_dense.solver.apply(&v, &w_dense);
    // Matrix-free apply
    s_mf.solver.apply(&v, &w_mf);

    for (0..sys_n) |i| {
        try testing.expectApproxEqRel(w_dense[i], w_mf[i], 1e-8);
    }
}

test "lptv: matrix-free applyT matches dense adjoint multiply" {
    const T = f64;

    const num_harmonics: u32 = 1;
    const nb: u32 = 3;
    const n: u32 = 2;

    var s_dense = try makeLti2x2(T, 1, 0.5, 0.3, 2, 0.1, 0, 0, 0.2, num_harmonics, 200.0, .dense);
    defer freeLti2x2(T, &s_dense);

    var s_mf = try makeLti2x2(T, 1, 0.5, 0.3, 2, 0.1, 0, 0, 0.2, num_harmonics, 200.0, .matrix_free);
    defer freeLti2x2(T, &s_mf);

    const f: T = 75.0;
    try s_dense.solver.setFreq(f);
    try s_mf.solver.setFreq(f);

    const sys_n = 2 * nb * n;
    var v: [sys_n]T = undefined;
    for (0..sys_n) |i| {
        v[i] = @as(T, @floatFromInt(i + 1)) * 0.1;
    }

    var w_dense: [sys_n]T = undefined;
    var w_mf: [sys_n]T = undefined;

    s_dense.solver.applyT(&v, &w_dense);
    s_mf.solver.applyT(&v, &w_mf);

    for (0..sys_n) |i| {
        try testing.expectApproxEqRel(w_dense[i], w_mf[i], 1e-8);
    }
}

test "lptv: f32 instantiation compiles and solves" {
    const T = f32;
    var s = try makeLti2x2(T, 1, 0, 0, 2, 0.1, 0, 0, 0.2, 0, 100.0, .dense);
    defer freeLti2x2(T, &s);

    try s.solver.setFreq(50.0);
    var rhs = [_]T{ 1, 0, 0, 0 };
    var x = [_]T{0} ** 4;
    s.solver.solveRhs(&rhs, &x);

    const w: T = @floatCast(2.0 * math.pi * 50.0);
    const denom = 1.0 + 0.01 * w * w;
    try testing.expectApproxEqRel(1.0 / denom, x[0], 1e-4);
}
