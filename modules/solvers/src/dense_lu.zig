const std = @import("std");

// ponytail: single SIMD-accelerated dense LU, replaces 7 copy-pasted solveDense functions
// upgrade path: blocked LU (BLAS-3 style) if n > ~256

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

        pub fn factorizeSolve(n: usize, a: []T, b: []const T, x: []T) Error!void {
            return factorizeSolveImpl(n, a, b, x, false);
        }

        pub fn factorizeSolveNeg(n: usize, a: []T, b: []const T, x: []T) Error!void {
            return factorizeSolveImpl(n, a, b, x, true);
        }

        // Fused factorize + solve carrying the RHS through elimination (no piv storage).
        fn factorizeSolveImpl(n: usize, a: []T, b: []const T, x: []T, comptime negate: bool) Error!void {
            if (negate) {
                for (0..n) |i| x[i] = -b[i];
            } else {
                @memcpy(x[0..n], b[0..n]);
            }

            for (0..n) |k| {
                const max_row = pivotRow(n, a, k);
                if (@abs(a[max_row * n + k]) < singular_tol) return error.Singular;
                if (max_row != k) {
                    swapRowsSimd(a, n, k, max_row);
                    std.mem.swap(T, &x[k], &x[max_row]);
                }
                const pivot = a[k * n + k];
                const row_k = a[k * n ..][0..n];
                for (k + 1..n) |ii| {
                    const factor = a[ii * n + k] / pivot;
                    const row_i = a[ii * n ..][0..n];
                    elimRowSimd(row_i, row_k, factor, k + 1, n);
                    x[ii] -= factor * x[k];
                }
            }

            backSubstitute(n, a, x);
        }

        pub fn factorize(n: usize, a: []T, piv: []u32) Error!void {
            for (0..n) |k| {
                const max_row = pivotRow(n, a, k);
                piv[k] = @intCast(max_row);
                if (max_row != k) swapRowsSimd(a, n, k, max_row);

                const pivot = a[k * n + k];
                if (@abs(pivot) < singular_tol) return error.Singular;
                const row_k = a[k * n ..][0..n];
                for (k + 1..n) |ii| {
                    const factor = a[ii * n + k] / pivot;
                    a[ii * n + k] = factor;
                    const row_i = a[ii * n ..][0..n];
                    elimRowSimd(row_i, row_k, factor, k + 1, n);
                }
            }
        }

        pub fn solveFactored(n: usize, lu: []const T, piv: []const u32, b: []const T, x: []T) void {
            @memcpy(x[0..n], b[0..n]);

            // factorize() swaps FULL rows (LAPACK convention): earlier-column
            // multipliers are permuted by later swaps, so ALL swaps must be applied
            // to the RHS before forward elimination — interleaving them is wrong
            // whenever a later pivot touches a row used by an earlier column.
            for (0..n) |k| {
                if (piv[k] != k) std.mem.swap(T, &x[k], &x[piv[k]]);
            }
            for (0..n) |k| {
                for (k + 1..n) |ii| x[ii] -= lu[ii * n + k] * x[k];
            }

            backSubstitute(n, lu, x);
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

        fn backSubstitute(n: usize, a: []const T, x: []T) void {
            var ki: usize = n;
            while (ki > 0) {
                ki -= 1;
                const row = a[ki * n ..][0..n];
                // vector accumulator: one horizontal reduce per row, not per chunk
                var acc: V = @splat(0.0);
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

        // ====================================================================
        // Complex admittance system builder (2n×2n real expansion)
        // ====================================================================

        pub fn buildComplexAdmittance(
            n: usize,
            nn: usize,
            g_dense: []const T,
            c_mat: []const T,
            omega: T,
            a: []T,
        ) void {
            // no memset: every element of the 2n×2n matrix is written below
            const neg_omega = -omega;
            const omega_v: V = @splat(omega);
            const neg_omega_v: V = @splat(neg_omega);
            for (0..n) |row| {
                const g_row = g_dense[row * n ..][0..n];
                const c_row = c_mat[row * n ..][0..n];
                const a_tl = a[row * nn ..]; // top-left row
                const a_bl = a[(n + row) * nn ..]; // bottom-left row

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
    };
}

// f64 instantiation re-exported as the module-level API (existing callers).
const F64 = DenseLu(f64);
pub const factorizeSolve = F64.factorizeSolve;
pub const factorizeSolveNeg = F64.factorizeSolveNeg;
pub const factorize = F64.factorize;
pub const solveFactored = F64.solveFactored;
pub const buildComplexAdmittance = F64.buildComplexAdmittance;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "dense_lu: factorizeSolve 3x3" {
    var a = [_]f64{
        2, 1, 0,
        0, 3, 1,
        1, 0, 4,
    };
    const b = [_]f64{ 5, 7, 10 };
    var x: [3]f64 = undefined;
    try factorizeSolve(3, &a, &b, &x);

    const orig = [_]f64{ 2, 1, 0, 0, 3, 1, 1, 0, 4 };
    for (0..3) |row| {
        var sum: f64 = 0;
        for (0..3) |col| sum += orig[row * 3 + col] * x[col];
        try testing.expectApproxEqAbs(b[row], sum, 1e-10);
    }
}

test "dense_lu: f32 instantiation solves the same system" {
    const LU32 = DenseLu(f32);
    var a = [_]f32{
        2, 1, 0,
        0, 3, 1,
        1, 0, 4,
    };
    const b = [_]f32{ 5, 7, 10 };
    var x: [3]f32 = undefined;
    try LU32.factorizeSolve(3, &a, &b, &x);

    const orig = [_]f32{ 2, 1, 0, 0, 3, 1, 1, 0, 4 };
    for (0..3) |row| {
        var sum: f32 = 0;
        for (0..3) |col| sum += orig[row * 3 + col] * x[col];
        try testing.expectApproxEqAbs(b[row], sum, 1e-4);
    }
}

test "dense_lu: singular matrix returns error" {
    var a = [_]f64{
        1, 2,
        2, 4,
    };
    const b = [_]f64{ 1, 2 };
    var x: [2]f64 = undefined;
    try testing.expectError(error.Singular, factorizeSolve(2, &a, &b, &x));

    var a2 = [_]f64{ 1, 2, 2, 4 };
    var piv: [2]u32 = undefined;
    try testing.expectError(error.Singular, factorize(2, &a2, &piv));
}

test "dense_lu: buildComplexAdmittance" {
    const g = [_]f64{ 1, 2, 3, 4 };
    const c = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
    var a: [16]f64 = undefined;
    buildComplexAdmittance(2, 4, &g, &c, 10.0, &a);

    try testing.expectApproxEqAbs(@as(f64, 1.0), a[0 * 4 + 0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1.0), a[0 * 4 + 2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), a[2 * 4 + 2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), a[2 * 4 + 0], 1e-12);
}
