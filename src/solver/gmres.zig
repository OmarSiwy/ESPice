//! GMRES(m) — restarted Krylov iterative solver, right-preconditioned.
//!
//! Matrix-free: the caller supplies a matvec callback (w = A*v) and an
//! optional right-preconditioner callback (r = M^{-1} * r in-place).
//!
//! Data layout (SoA, contiguous, pre-allocated at init):
//!   V:  (m+1) * n   Arnoldi basis, column-major (contiguous per vector)
//!   H:  (m+1) * m   upper Hessenberg, row-major
//!   cs, sn: m       Givens rotation cosines / sines
//!   g:  m+1          transformed RHS
//!   y:  m            triangular-solve workspace
//!   w:  n            matvec / precond scratch
//!   r:  n            residual scratch
//!
//! Zero allocation in solve(); all memory from init().
//! SIMD-accelerated dot products and axpy in the Gram-Schmidt inner loop.
//!
//! Serves: JFNK inner solve (converger.zig), monodromy-Krylov PSS (future),
//! any matrix-free system. See docs/solvers/newton-raphson-convergence.md §JFNK
//! and docs/solvers/monodromy-krylov.md §GMRES.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Right-preconditioned GMRES(m) solver, monomorphized per element type T.
pub fn Gmres(comptime T: type) type {
    comptime {
        std.debug.assert(T == f32 or T == f64);
    }

    return struct {
        const Self = @This();
        const W = std.simd.suggestVectorLength(T) orelse 1;
        const Vec = @Vector(W, T);

        /// Result of a solve() call.
        pub const SolveResult = struct {
            iterations: u32,
            residual: T,
            converged: bool,
        };

        // System dimension and restart depth.
        n: u32,
        m: u32,

        // --- Hot workspace (touched every Arnoldi step) ---
        // Arnoldi basis: (m+1) vectors of length n, contiguous.
        // v_basis[k * n .. (k+1) * n] is v_k.
        v_basis: []T,
        // Upper Hessenberg: (m+1) rows x m cols, row-major.
        // H[i * m + j] = h_{i,j}.
        h: []T,
        // Givens rotation parameters.
        cs: []T,
        sn: []T,
        // Transformed RHS (length m+1).
        g: []T,
        // Triangular solve workspace (length m).
        y: []T,
        // Scratch vectors (length n each).
        w: []T,
        r: []T,

        /// Allocate workspace for GMRES(m) on n-dimensional systems.
        pub fn init(gpa: Allocator, n: u32, m: u32) !Self {
            std.debug.assert(n > 0);
            std.debug.assert(m > 0);
            const nu: usize = n;
            const mu: usize = m;

            const v_basis = try gpa.alloc(T, (mu + 1) * nu);
            errdefer gpa.free(v_basis);
            const h = try gpa.alloc(T, (mu + 1) * mu);
            errdefer gpa.free(h);
            const cs = try gpa.alloc(T, mu);
            errdefer gpa.free(cs);
            const sn = try gpa.alloc(T, mu);
            errdefer gpa.free(sn);
            const g_ws = try gpa.alloc(T, mu + 1);
            errdefer gpa.free(g_ws);
            const y_ws = try gpa.alloc(T, mu);
            errdefer gpa.free(y_ws);
            const w_ws = try gpa.alloc(T, nu);
            errdefer gpa.free(w_ws);
            const r_ws = try gpa.alloc(T, nu);

            return .{
                .n = n,
                .m = m,
                .v_basis = v_basis,
                .h = h,
                .cs = cs,
                .sn = sn,
                .g = g_ws,
                .y = y_ws,
                .w = w_ws,
                .r = r_ws,
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            inline for (.{ self.v_basis, self.h, self.cs, self.sn, self.g, self.y, self.w, self.r }) |s| gpa.free(s);
            self.* = undefined;
        }

        /// Solve A*x = b matrix-free via right-preconditioned GMRES(m).
        ///
        /// matvec(v, w, ctx): compute w = A*v.
        /// precond(r, ctx): apply right preconditioner in-place (r <- M^{-1} r).
        ///   Pass null for unpreconditioned solve.
        /// x: initial guess on entry, solution on exit.
        /// tol: relative residual tolerance (||r|| / ||b|| < tol).
        /// max_restarts: maximum number of outer restarts (0 = single cycle).
        pub fn solve(
            self: *Self,
            matvec: *const fn (v: []const T, w: []T, ctx: *anyopaque) void,
            ctx: *anyopaque,
            precond: ?*const fn (r: []T, ctx: *anyopaque) void,
            precond_ctx: ?*anyopaque,
            b: []const T,
            x: []T,
            tol: T,
            max_restarts: u32,
        ) SolveResult {
            const n: usize = self.n;
            const m: usize = self.m;
            std.debug.assert(b.len >= n);
            std.debug.assert(x.len >= n);

            const b_norm = vecNorm(b[0..n]);
            // ponytail: zero RHS => x=0 is exact; skip iteration
            if (b_norm == 0) {
                @memset(x[0..n], 0);
                return .{ .iterations = 0, .residual = 0, .converged = true };
            }
            const abs_tol = tol * b_norm;

            var total_iters: u32 = 0;

            for (0..max_restarts + 1) |_| {
                // r = b - A*x
                matvec(x[0..n], self.r[0..n], ctx);
                for (0..n) |i| self.r[i] = b[i] - self.r[i];

                const beta = vecNorm(self.r[0..n]);
                if (beta <= abs_tol) {
                    return .{ .iterations = total_iters, .residual = beta / b_norm, .converged = true };
                }

                // v_0 = r / beta
                const v0 = self.getV(0);
                vecScale(self.r[0..n], 1.0 / beta, v0);

                // g = beta * e_1
                @memset(self.g[0 .. m + 1], 0);
                self.g[0] = beta;

                var j: u32 = 0;
                while (j < m) : (j += 1) {
                    const ju: usize = j;
                    total_iters += 1;

                    const vj = self.getV(j);

                    // Right preconditioning: w = M^{-1} v_j, then z = A*w.
                    // Without precond: z = A*v_j.
                    if (precond) |pc| {
                        @memcpy(self.w[0..n], vj);
                        pc(self.w[0..n], precond_ctx.?);
                        matvec(self.w[0..n], self.r[0..n], ctx);
                    } else {
                        matvec(vj, self.r[0..n], ctx);
                    }

                    // Modified Gram-Schmidt orthogonalization.
                    // z is stored in self.r (reused as scratch).
                    for (0..ju + 1) |i| {
                        const vi = self.getV(@intCast(i));
                        const hij = vecDot(self.r[0..n], vi);
                        self.h[i * m + ju] = hij;
                        vecAxpy(self.r[0..n], -hij, vi);
                    }

                    const h_jp1_j = vecNorm(self.r[0..n]);
                    self.h[(ju + 1) * m + ju] = h_jp1_j;

                    // If not breakdown, normalize the next basis vector.
                    if (h_jp1_j != 0) {
                        const vjp1 = self.getV(j + 1);
                        vecScale(self.r[0..n], 1.0 / h_jp1_j, vjp1);
                    }

                    // Apply previous Givens rotations to column j of H.
                    self.applyPreviousGivens(j);

                    // Compute new Givens rotation for (h_{j,j}, h_{j+1,j}).
                    const hjj = self.h[ju * m + ju];
                    const hjp1j = self.h[(ju + 1) * m + ju];
                    const rot = givensRotation(hjj, hjp1j);
                    self.cs[ju] = rot.c;
                    self.sn[ju] = rot.s;

                    // Apply to H column and g.
                    self.h[ju * m + ju] = rot.c * hjj + rot.s * hjp1j;
                    self.h[(ju + 1) * m + ju] = 0;

                    const g_j = self.g[ju];
                    const g_jp1 = self.g[ju + 1];
                    self.g[ju] = rot.c * g_j + rot.s * g_jp1;
                    self.g[ju + 1] = -rot.s * g_j + rot.c * g_jp1;

                    // Breakdown or convergence: exit the Arnoldi loop.
                    if (h_jp1_j == 0 or @abs(self.g[ju + 1]) <= abs_tol) {
                        j += 1;
                        break;
                    }
                }

                // Solve the upper triangular system H*y = g (j columns).
                const k = j; // number of Arnoldi steps completed
                if (k > 0) {
                    self.solveUpperTriangular(k);
                    // Update x: x += V_k * y (with right preconditioning:
                    // x += M^{-1} * V_k * y).
                    self.updateSolution(x[0..n], k, precond, precond_ctx);
                }

                // ponytail: one residual gate covers both early exit and a full restart window.
                const res_norm = @abs(self.g[k]);
                if (res_norm <= abs_tol) {
                    return .{ .iterations = total_iters, .residual = res_norm / b_norm, .converged = true };
                }
            }

            // Did not converge within max_restarts.
            // Compute actual residual for the report.
            matvec(x[0..n], self.r[0..n], ctx);
            for (0..n) |i| self.r[i] = b[i] - self.r[i];
            const final_res = vecNorm(self.r[0..n]);
            return .{ .iterations = total_iters, .residual = final_res / b_norm, .converged = false };
        }

        // --- Internal helpers ---

        /// Get the i-th Arnoldi basis vector (slice of v_basis).
        inline fn getV(self: *Self, i: u32) []T {
            const off: usize = @as(usize, i) * @as(usize, self.n);
            return self.v_basis[off..][0..self.n];
        }

        /// Apply Givens rotations 0..j-1 to column j of H (in-place).
        fn applyPreviousGivens(self: *Self, j: u32) void {
            const m: usize = self.m;
            const ju: usize = j;
            for (0..ju) |i| {
                const c = self.cs[i];
                const s = self.sn[i];
                const h_ij = self.h[i * m + ju];
                const h_ip1j = self.h[(i + 1) * m + ju];
                self.h[i * m + ju] = c * h_ij + s * h_ip1j;
                self.h[(i + 1) * m + ju] = -s * h_ij + c * h_ip1j;
            }
        }

        /// Back-solve the upper triangular k x k system from H into y.
        /// If a diagonal is zero (breakdown on a singular operator), truncate
        /// by setting that y-component to zero — gives the best solution in
        /// the available Krylov subspace.
        fn solveUpperTriangular(self: *Self, k: u32) void {
            const m: usize = self.m;
            const ku: usize = k;
            @memcpy(self.y[0..ku], self.g[0..ku]);
            var i: usize = ku;
            while (i > 0) {
                i -= 1;
                for (i + 1..ku) |jj| {
                    self.y[i] -= self.h[i * m + jj] * self.y[jj];
                }
                const diag = self.h[i * m + i];
                if (diag == 0) {
                    // ponytail: singular Hessenberg diagonal — Krylov subspace
                    // doesn't span this direction. Set y[i]=0 (least-norm).
                    self.y[i] = 0;
                } else {
                    self.y[i] /= diag;
                }
            }
        }

        /// Update x += V_k * y, applying right-preconditioner if present.
        fn updateSolution(
            self: *Self,
            x: []T,
            k: u32,
            precond: ?*const fn (r: []T, ctx: *anyopaque) void,
            precond_ctx: ?*anyopaque,
        ) void {
            const n: usize = self.n;
            if (precond) |pc| {
                // Accumulate V_k * y into w, then apply M^{-1}, then add to x.
                @memset(self.w[0..n], 0);
                for (0..k) |j| {
                    const vj = self.getV(@intCast(j));
                    vecAxpy(self.w[0..n], self.y[j], vj);
                }
                pc(self.w[0..n], precond_ctx.?);
                for (0..n) |i| x[i] += self.w[i];
            } else {
                // x += V_k * y directly.
                for (0..k) |j| {
                    const vj = self.getV(@intCast(j));
                    vecAxpy(x, self.y[j], vj);
                }
            }
        }

        // --- SIMD-accelerated vector operations ---

        /// ||v||_2
        fn vecNorm(v: []const T) T {
            return @sqrt(vecDot(v, v));
        }

        /// <a, b> dot product, SIMD-accelerated.
        fn vecDot(a: []const T, b: []const T) T {
            std.debug.assert(a.len == b.len);
            const n = a.len;
            var acc: Vec = @splat(0);
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const va: Vec = a[i..][0..W].*;
                const vb: Vec = b[i..][0..W].*;
                acc += va * vb;
            }
            var s: T = @reduce(.Add, acc);
            // Scalar tail.
            while (i < n) : (i += 1) s += a[i] * b[i];
            return s;
        }

        /// a[i] += alpha * b[i], SIMD-accelerated.
        fn vecAxpy(a: []T, alpha: T, b: []const T) void {
            std.debug.assert(a.len == b.len);
            const n = a.len;
            const va: Vec = @splat(alpha);
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const p: *[W]T = a[i..][0..W];
                const vb: Vec = b[i..][0..W].*;
                p.* = @as(Vec, p.*) + va * vb;
            }
            while (i < n) : (i += 1) a[i] += alpha * b[i];
        }

        /// dst[i] = alpha * src[i]
        fn vecScale(src: []const T, alpha: T, dst: []T) void {
            std.debug.assert(src.len == dst.len);
            const n = src.len;
            const va: Vec = @splat(alpha);
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const vs: Vec = src[i..][0..W].*;
                const p: *[W]T = dst[i..][0..W];
                p.* = va * vs;
            }
            while (i < n) : (i += 1) dst[i] = alpha * src[i];
        }
    };
}

/// Compute Givens rotation parameters: c, s such that
///   [ c  s ] [ a ]   [ r ]
///   [-s  c ] [ b ] = [ 0 ]
fn givensRotation(a: anytype, b: @TypeOf(a)) struct { c: @TypeOf(a), s: @TypeOf(a) } {
    if (b == 0) return .{ .c = 1, .s = 0 };
    if (a == 0) return .{ .c = 0, .s = std.math.sign(b) };
    const r = @sqrt(a * a + b * b);
    return .{ .c = a / r, .s = b / r };
}
