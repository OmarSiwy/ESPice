const std = @import("std");

// ponytail: single SIMD-accelerated dense LU, replaces 7 copy-pasted solveDense functions.
// Rank-8 panel updates from n = 40 up; the next step would be 2-D register
// tiling of the trailing update if dense solves dominate again.

pub const Error = error{Singular};

/// Dense LU over element type T (f32 or f64). Monomorphizes per T:
/// vector width, singular threshold, and all kernels specialize at comptime.
pub fn DenseLu(comptime T: type) type {
    return struct {
        const W = std.simd.suggestVectorLength(T) orelse 1;
        const V = @Vector(W, T);
        /// Pivot magnitudes below eps²(T) are numerical noise
        /// (4.9e-32 for f64 — within a decade of the historical 1e-30).
        const singular_tol: T = std.math.floatEps(T) * std.math.floatEps(T);

        // ====================================================================
        // Public API
        // ====================================================================

        /// Fused factorize + forward-solve + back-substitute. x = A \ b.
        /// Destroys `a`. `b` and `x` must not alias.
        pub fn factorizeSolve(n: usize, a: []T, b: []const T, x: []T) Error!void {
            return factorizeSolveImpl(n, a, b, x, false);
        }

        /// Fused factorize + forward-solve + back-substitute. x = A \ (-b).
        /// Destroys `a`. `b` and `x` must not alias.
        pub fn factorizeSolveNeg(n: usize, a: []T, b: []const T, x: []T) Error!void {
            return factorizeSolveImpl(n, a, b, x, true);
        }

        /// PA = LU factorization with partial pivoting.
        /// `a` is overwritten with L (unit lower, stored below diagonal) and U
        /// (upper, stored on and above diagonal). `piv[k]` records the row
        /// swapped with row k at step k.
        pub fn factorize(n: usize, a: []T, piv: []u32) Error!void {
            if (n >= blocked_min) return eliminateBlocked(n, a, piv, &.{}, .factor);
            for (0..n) |k| {
                const max_row = pivotRow(n, a, k);
                piv[k] = @intCast(max_row);
                if (max_row != k) swapRowsSimd(a, n, k, max_row);

                const pivot = a[k * n + k];
                if (@abs(pivot) < singular_tol) return error.Singular;
                const inv_pivot = @as(T, 1.0) / pivot;
                const row_k = a[k * n ..][0..n];
                for (k + 1..n) |ii| {
                    const factor = a[ii * n + k] * inv_pivot;
                    a[ii * n + k] = factor; // store L multiplier
                    const row_i = a[ii * n ..][0..n];
                    elimRowSimd(row_i, row_k, factor, k + 1, n);
                }
            }
        }

        /// Solve Ax = b given PA = LU from factorize().
        /// Forward substitution (apply P then L), then back substitution (U).
        /// `b` and `x` may alias.
        pub fn solveFactored(n: usize, lu: []const T, piv: []const u32, b: []const T, x: []T) void {
            if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

            // Apply row permutations (forward order, LAPACK convention).
            // All swaps first, then forward elimination — interleaving is wrong
            // when a later pivot touches a row used by an earlier column.
            for (0..n) |k| {
                if (piv[k] != k) std.mem.swap(T, &x[k], &x[piv[k]]);
            }

            // Forward substitution: L y = P b (L has unit diagonal, multipliers below)
            for (0..n) |k| {
                const xk = x[k];
                if (xk == 0) continue; // ponytail: skip zero RHS — common in sparse-ish systems
                fmsSolveSimd(lu, x, n, k, xk);
            }

            backSubstitute(n, lu, x);
        }

        /// Solve A^T x = b given PA = LU from factorize().
        /// A = P^T L U  =>  A^T = U^T L^T P.
        /// Forward-sub U^T (lower tri), back-sub L^T (unit upper), then P^{-1}.
        /// `b` and `x` may alias.
        pub fn solveFactoredT(n: usize, lu: []const T, piv: []const u32, b: []const T, x: []T) void {
            if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

            // Forward-sub U^T z = b: U^T[i][j] = lu[j*n+i] for j <= i
            for (0..n) |i| {
                x[i] = subtractColumnDot(n, lu, x, i, 0, i) / lu[i * n + i];
            }

            // Back-sub L^T w = z: unit diagonal, L^T[i][j] = lu[j*n+i] for j > i
            var i = n;
            while (i > 0) {
                i -= 1;
                x[i] = subtractColumnDot(n, lu, x, i, i + 1, n);
            }

            // Reverse permutation: undo swaps k = n-1 .. 0
            var k = n;
            while (k > 0) {
                k -= 1;
                if (piv[k] != k) std.mem.swap(T, &x[k], &x[piv[k]]);
            }
        }

        /// Assemble the 2n x 2n stacked-real complex admittance matrix:
        ///   [ G,  -ωC ]
        ///   [ ωC,   G  ]
        /// Layout: row-major in `a` with stride `nn` (= 2n).
        pub fn buildComplexAdmittance(
            n: usize,
            nn: usize,
            g_dense: []const T,
            c_mat: []const T,
            omega: T,
            a: []T,
        ) void {
            const neg_omega = -omega;
            const omega_v: V = @splat(omega);
            const neg_omega_v: V = @splat(neg_omega);
            for (0..n) |row| {
                const g_row = g_dense[row * n ..][0..n];
                const c_row = c_mat[row * n ..][0..n];
                const a_tl = a[row * nn ..]; // top-left quadrant row
                const a_bl = a[(n + row) * nn ..]; // bottom-left quadrant row

                var col: usize = 0;
                while (col + W <= n) : (col += W) {
                    const gv: V = g_row[col..][0..W].*;
                    const cv: V = c_row[col..][0..W].*;

                    const p_tl: *[W]T = a_tl[col..][0..W];
                    p_tl.* = gv;
                    const p_tr: *[W]T = a_tl[n + col ..][0..W];
                    p_tr.* = neg_omega_v * cv;
                    const p_bl: *[W]T = a_bl[col..][0..W];
                    p_bl.* = omega_v * cv;
                    const p_br: *[W]T = a_bl[n + col ..][0..W];
                    p_br.* = gv;
                }
                while (col < n) : (col += 1) {
                    const g_val = g_row[col];
                    const c_val = c_row[col];
                    a_tl[col] = g_val;
                    a_tl[n + col] = neg_omega * c_val;
                    a_bl[col] = omega * c_val;
                    a_bl[n + col] = g_val;
                }
            }
        }

        // ====================================================================
        // Internal kernels
        // ====================================================================

        /// Subtract a strided column dot product, preserving vector reduction
        /// followed by scalar subtraction for both transpose substitutions.
        inline fn subtractColumnDot(n: usize, lu: []const T, x: []const T, i: usize, start: usize, end: usize) T {
            var acc: V = @splat(0.0);
            var j = start;
            // ponytail: strided column access; gather for moderate n, scalar tail for small n.
            // Upgrade to a transposed factor layout if column gathers become the bottleneck.
            while (j + W <= end) : (j += W) {
                var col_vals: [W]T = undefined;
                inline for (0..W) |w| col_vals[w] = lu[(j + w) * n + i];
                const cv: V = col_vals;
                const xv: V = x[j..][0..W].*;
                acc += cv * xv;
            }
            var sum = x[i] - @reduce(.Add, acc);
            while (j < end) : (j += 1) sum -= lu[j * n + i] * x[j];
            return sum;
        }

        /// Fused factorize + solve: carries the RHS through elimination (no piv storage).
        fn factorizeSolveImpl(n: usize, a: []T, b: []const T, x: []T, comptime negate: bool) Error!void {
            if (negate) {
                // SIMD negate copy
                var i: usize = 0;
                while (i + W <= n) : (i += W) {
                    const bv: V = b[i..][0..W].*;
                    const p: *[W]T = x[i..][0..W];
                    const zero: V = @splat(@as(T, 0));
                    p.* = zero - bv;
                }
                while (i < n) : (i += 1) x[i] = -b[i];
            } else {
                @memcpy(x[0..n], b[0..n]);
            }
            if (n >= blocked_min) {
                try eliminateBlocked(n, a, &.{}, x, .solve);
                return backSubstitute(n, a, x);
            }

            for (0..n) |k| {
                const max_row = pivotRow(n, a, k);
                if (@abs(a[max_row * n + k]) < singular_tol) return error.Singular;
                if (max_row != k) {
                    swapRowsSimd(a, n, k, max_row);
                    std.mem.swap(T, &x[k], &x[max_row]);
                }
                const pivot = a[k * n + k];
                const inv_pivot = @as(T, 1.0) / pivot;
                const row_k = a[k * n ..][0..n];
                for (k + 1..n) |ii| {
                    const factor = a[ii * n + k] * inv_pivot;
                    const row_i = a[ii * n ..][0..n];
                    elimRowSimd(row_i, row_k, factor, k + 1, n);
                    x[ii] -= factor * x[k];
                }
            }

            backSubstitute(n, a, x);
        }

        /// Pivot columns per panel of `eliminateBlocked`.
        const block = 8;
        /// Below this order the unblocked loops above win: the panel
        /// bookkeeping costs more than the row traffic it saves (Ir crossover
        /// between n = 32 and 48).
        const blocked_min = 5 * block;

        const Mode = enum { factor, solve };

        /// PA = LU with partial pivoting, blocked right-looking: a panel of
        /// `block` columns is factored as in the unblocked loops, then each
        /// trailing row takes the panel's updates in ONE pass instead of
        /// `block`, so it streams through memory once per panel while the
        /// panel's U rows stay in L1. Every entry still receives
        /// `a -= l * u` in increasing k, as a separate multiply and subtract,
        /// with the same reciprocal-pivot multipliers, so the factors, pivots
        /// and fused solution are bitwise those of the unblocked loops (the
        /// test oracle). `.factor` records swaps in `piv`; `.solve` carries
        /// `x` through instead, as `factorizeSolveImpl` does.
        fn eliminateBlocked(n: usize, a: []T, piv: []u32, x: []T, comptime mode: Mode) Error!void {
            var k0: usize = 0;
            while (k0 < n) : (k0 += block) {
                const kb = @min(k0 + block, n);
                for (k0..kb) |k| if (!panelStep(n, a, piv, x, k, kb, mode)) return error.Singular;
                if (kb == n) break;
                // The panel's own U rows, trailing columns: row k takes the
                // updates of rows k0..k-1, which are final by then.
                for (k0 + 1..kb) |k| {
                    const row = a[k * n ..][0..n];
                    for (k0..k) |kk| elimRowSimd(row, a[kk * n ..][0..n], row[kk], kb, n);
                }
                for (kb..n) |i| panelUpdate(a[i * n ..][0..n], a, n, k0, kb);
            }
        }

        /// Pivot step k of `eliminateBlocked`: the unblocked loop body with
        /// the row update stopped at the panel edge `kb`, and the multiplier
        /// always stored because `panelUpdate` reads it. False on a singular
        /// pivot.
        inline fn panelStep(n: usize, a: []T, piv: []u32, x: []T, k: usize, kb: usize, comptime mode: Mode) bool {
            const max_row = pivotRow(n, a, k);
            if (mode == .factor) piv[k] = @intCast(max_row);
            if (@abs(a[max_row * n + k]) < singular_tol) return false;
            if (max_row != k) {
                swapRowsSimd(a, n, k, max_row);
                if (mode == .solve) std.mem.swap(T, &x[k], &x[max_row]);
            }
            const inv_pivot = @as(T, 1.0) / a[k * n + k];
            const row_k = a[k * n ..][0..n];
            for (k + 1..n) |ii| {
                const factor = a[ii * n + k] * inv_pivot;
                a[ii * n + k] = factor;
                elimRowSimd(a[ii * n ..][0..n], row_k, factor, k + 1, kb);
                if (mode == .solve) x[ii] -= factor * x[k];
            }
            return true;
        }

        /// row[kb..n] -= sum over kk in [k0, kb) of row[kk] * a[kk, kb..n],
        /// term by term in increasing kk (the rounding of `kb - k0` separate
        /// `elimRowSimd` calls). Four vectors are in flight per pass: each
        /// one's subtracts form a dependent chain, and a single chain stalls
        /// on the subtract latency.
        inline fn panelUpdate(row: []T, a: []const T, n: usize, k0: usize, kb: usize) void {
            var j = kb;
            while (j + 4 * W <= n) : (j += 4 * W) {
                var v0: V = row[j..][0..W].*;
                var v1: V = row[j + W ..][0..W].*;
                var v2: V = row[j + 2 * W ..][0..W].*;
                var v3: V = row[j + 3 * W ..][0..W].*;
                for (k0..kb) |kk| {
                    const l: V = @splat(row[kk]);
                    const u = a[kk * n + j ..];
                    v0 = v0 - l * @as(V, u[0..W].*);
                    v1 = v1 - l * @as(V, u[W..][0..W].*);
                    v2 = v2 - l * @as(V, u[2 * W ..][0..W].*);
                    v3 = v3 - l * @as(V, u[3 * W ..][0..W].*);
                }
                row[j..][0..W].* = v0;
                row[j + W ..][0..W].* = v1;
                row[j + 2 * W ..][0..W].* = v2;
                row[j + 3 * W ..][0..W].* = v3;
            }
            while (j + W <= n) : (j += W) {
                var v: V = row[j..][0..W].*;
                for (k0..kb) |kk| v = v - @as(V, @splat(row[kk])) * @as(V, a[kk * n + j ..][0..W].*);
                row[j..][0..W].* = v;
            }
            while (j < n) : (j += 1) {
                var v = row[j];
                for (k0..kb) |kk| v -= row[kk] * a[kk * n + j];
                row[j] = v;
            }
        }

        /// argmax |a[i*n+k]| over i in k..n (partial-pivot row for column k).
        fn pivotRow(n: usize, a: []const T, k: usize) usize {
            var max_val: T = @abs(a[k * n + k]);
            var max_row: usize = k;
            for (k + 1..n) |i| {
                const v = @abs(a[i * n + k]);
                if (v > max_val) {
                    max_val = v;
                    max_row = i;
                }
            }
            return max_row;
        }

        /// Back substitution: solve U x = y in place. x[n-1] down to x[0].
        /// SIMD vector accumulator with single horizontal reduce per row.
        fn backSubstitute(n: usize, a: []const T, x: []T) void {
            var ki: usize = n;
            while (ki > 0) {
                ki -= 1;
                const row = a[ki * n ..][0..n];
                var acc: V = @splat(@as(T, 0));
                var j = ki + 1;
                while (j + W <= n) : (j += W) {
                    const av: V = row[j..][0..W].*;
                    const xv: V = x[j..][0..W].*;
                    acc += av * xv;
                }
                var sum = x[ki] - @reduce(.Add, acc);
                while (j < n) : (j += 1) sum -= row[j] * x[j];
                x[ki] = sum / row[ki];
            }
        }

        /// SIMD row elimination: row_i[start..n] -= factor * row_k[start..n]
        inline fn elimRowSimd(row_i: []T, row_k: []const T, factor: T, start: usize, n: usize) void {
            const fv: V = @splat(factor);
            var j = start;
            while (j + W <= n) : (j += W) {
                const kv: V = row_k[j..][0..W].*;
                const p: *[W]T = row_i[j..][0..W];
                const cur: V = p.*;
                p.* = cur - fv * kv;
            }
            while (j < n) : (j += 1) row_i[j] -= factor * row_k[j];
        }

        /// SIMD row swap: exchange rows r1 and r2 in matrix a (stride n).
        fn swapRowsSimd(a: []T, n: usize, r1: usize, r2: usize) void {
            var j: usize = 0;
            while (j + W <= n) : (j += W) {
                const p1: *[W]T = a[r1 * n + j ..][0..W];
                const p2: *[W]T = a[r2 * n + j ..][0..W];
                const tmp = p1.*;
                p1.* = p2.*;
                p2.* = tmp;
            }
            while (j < n) : (j += 1) std.mem.swap(T, &a[r1 * n + j], &a[r2 * n + j]);
        }

        /// Forward-sub helper for solveFactored: x[k+1..n] -= xk * lu[i*n+k] (strided column access).
        fn fmsSolveSimd(lu: []const T, x: []T, n: usize, k: usize, xk: T) void {
            const xkv: V = @splat(xk);
            // ponytail: the start is always k + 1; parameterize if another range is needed.
            var ii = k + 1;
            while (ii + W <= n) : (ii += W) {
                // lu[ii*n+k] .. lu[(ii+W-1)*n+k] — strided access (column k).
                // x[ii..ii+W] — contiguous. Gather the column, fma into x.
                var lv: [W]T = undefined;
                inline for (0..W) |w| lv[w] = lu[(ii + w) * n + k];
                const lvu: V = lv;
                const p: *[W]T = x[ii..][0..W];
                const cur: V = p.*;
                p.* = cur - xkv * lvu;
            }
            while (ii < n) : (ii += 1) x[ii] -= xk * lu[ii * n + k];
        }
    };
}

// f64 instantiation re-exported as the module-level API (existing callers).
const F64 = DenseLu(f64);
pub const factorizeSolve = F64.factorizeSolve;
pub const factorizeSolveNeg = F64.factorizeSolveNeg;
pub const factorize = F64.factorize;
pub const solveFactored = F64.solveFactored;
pub const solveFactoredT = F64.solveFactoredT;
pub const buildComplexAdmittance = F64.buildComplexAdmittance;
