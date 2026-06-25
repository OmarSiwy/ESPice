//! Dense row-major LU with partial pivoting and SIMD row operations, for the
//! small dense f64 systems: HB/PSS Jacobians, BBD blocks and the dense AC
//! path. Matrices are n x n, row-major, stride n. From n = 40 elimination
//! runs in rank-8 panels; the unblocked loops are its bitwise oracle.

const std = @import("std");
const scale = @import("core").numerics.scale;

// ponytail: rank-8 panels are the only blocking; 2-D register tiling of the
// trailing update is next if dense solves dominate again.

/// A pivot fell below eps^2.
pub const Error = error{Singular};

const W = std.simd.suggestVectorLength(f64) orelse 1;
const V = @Vector(W, f64);
/// Pivot magnitudes below eps^2 (4.9e-32) count as zero.
const singular_tol: f64 = std.math.floatEps(f64) * std.math.floatEps(f64);

/// x = A^-1 b in one elimination pass. Destroys `a`; `b` and `x`
/// must not alias.
pub fn factorizeSolve(n: usize, a: []f64, b: []const f64, x: []f64) Error!void {
    return factorizeSolveImpl(n, a, b, x, false);
}

/// x = -A^-1 b, the Newton step. Destroys `a`; `b` and `x` must not
/// alias.
pub fn factorizeSolveNeg(n: usize, a: []f64, b: []const f64, x: []f64) Error!void {
    return factorizeSolveImpl(n, a, b, x, true);
}

/// PA = LU in place: unit-lower L below the diagonal, U on and above
/// it. `piv[k]` is the row swapped with row k at step k (LAPACK
/// convention). On error `a` and `piv` are partial.
pub fn factorize(n: usize, a: []f64, piv: []u32) Error!void {
    if (n >= blocked_min) return eliminateBlocked(n, a, piv, &.{}, .factor);
    for (0..n) |k| {
        const max_row = pivotRow(n, a, k);
        piv[k] = @intCast(max_row);
        if (max_row != k) swapRowsSimd(a, n, k, max_row);

        const pivot = a[k * n + k];
        if (@abs(pivot) < singular_tol) return error.Singular;
        const inv_pivot = @as(f64, 1.0) / pivot;
        const row_k = a[k * n ..][0..n];
        for (k + 1..n) |ii| {
            const factor = a[ii * n + k] * inv_pivot;
            a[ii * n + k] = factor;
            const row_i = a[ii * n ..][0..n];
            elimRowSimd(row_i, row_k, factor, k + 1, n);
        }
    }
}

/// x = A^-1 b from `factorize` output. `b` and `x` may alias.
pub fn solveFactored(n: usize, lu: []const f64, piv: []const u32, b: []const f64, x: []f64) void {
    if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

    // All swaps first: interleaving them with the elimination is
    // wrong when a later pivot touches a row an earlier column used.
    for (0..n) |k| {
        if (piv[k] != k) std.mem.swap(f64, &x[k], &x[piv[k]]);
    }

    for (0..n) |k| {
        const xk = x[k];
        if (xk == 0) continue; // sparse right-hand sides are common
        fmsSolveSimd(lu, x, n, k, xk);
    }

    backSubstitute(n, lu, x);
}

/// x = A^-f64 b from `factorize` output: A^f64 = U^f64 L^f64 P, so forward
/// through U^f64, back through L^f64, then undo the swaps. `b` and `x`
/// may alias.
pub fn solveFactoredT(n: usize, lu: []const f64, piv: []const u32, b: []const f64, x: []f64) void {
    if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

    for (0..n) |i| {
        x[i] = subtractColumnDot(n, lu, x, i, 0, i) / lu[i * n + i];
    }

    var i = n;
    while (i > 0) {
        i -= 1;
        x[i] = subtractColumnDot(n, lu, x, i, i + 1, n);
    }

    var k = n;
    while (k > 0) {
        k -= 1;
        if (piv[k] != k) std.mem.swap(f64, &x[k], &x[piv[k]]);
    }
}

/// Writes the stacked-real admittance [G, -ωC; ωC, G] into `a`
/// (row-major, stride nn = 2n) from n x n row-major G and C.
pub fn buildComplexAdmittance(
    n: usize,
    nn: usize,
    g_dense: []const f64,
    c_mat: []const f64,
    omega: f64,
    a: []f64,
) void {
    const neg_omega = -omega;
    const omega_v: V = @splat(omega);
    const neg_omega_v: V = @splat(neg_omega);
    for (0..n) |row| {
        const g_row = g_dense[row * n ..][0..n];
        const c_row = c_mat[row * n ..][0..n];
        const a_tl = a[row * nn ..];
        const a_bl = a[(n + row) * nn ..];

        var col: usize = 0;
        while (col + W <= n) : (col += W) {
            const gv: V = g_row[col..][0..W].*;
            const cv: V = c_row[col..][0..W].*;

            const p_tl: *[W]f64 = a_tl[col..][0..W];
            p_tl.* = gv;
            const p_tr: *[W]f64 = a_tl[n + col ..][0..W];
            p_tr.* = neg_omega_v * cv;
            const p_bl: *[W]f64 = a_bl[col..][0..W];
            p_bl.* = omega_v * cv;
            const p_br: *[W]f64 = a_bl[n + col ..][0..W];
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

/// x[i] - sum over j in [start, end) of lu[j*n + i] * x[j]: W-lane
/// partial sums, one reduce, then the scalar tail.
inline fn subtractColumnDot(n: usize, lu: []const f64, x: []const f64, i: usize, start: usize, end: usize) f64 {
    var acc: V = @splat(0.0);
    var j = start;
    // ponytail: strided column gather; keep a transposed factor copy
    // if this ever shows up in a profile.
    while (j + W <= end) : (j += W) {
        var col_vals: [W]f64 = undefined;
        inline for (0..W) |w| col_vals[w] = lu[(j + w) * n + i];
        const cv: V = col_vals;
        const xv: V = x[j..][0..W].*;
        acc += cv * xv;
    }
    var sum = x[i] - @reduce(.Add, acc);
    while (j < end) : (j += 1) sum -= lu[j * n + i] * x[j];
    return sum;
}

/// Carries x through the elimination instead of recording pivots.
fn factorizeSolveImpl(n: usize, a: []f64, b: []const f64, x: []f64, comptime negate: bool) Error!void {
    if (negate) {
        scale(x[0..n], -1, b[0..n]);
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
            std.mem.swap(f64, &x[k], &x[max_row]);
        }
        const pivot = a[k * n + k];
        const inv_pivot = @as(f64, 1.0) / pivot;
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

/// Pivot columns per panel.
const block = 8;
/// Below this order the unblocked loops win: panel bookkeeping costs
/// more than the row traffic it saves (Ir crossover between 32 and 48).
const blocked_min = 5 * block;

const Mode = enum { factor, solve };

/// Blocked right-looking elimination. A panel of `block` columns is
/// factored as in the unblocked loops, then each trailing row takes
/// all the panel's updates in one pass while the panel's U rows stay
/// in L1. Every entry still gets `a -= l * u` in increasing k with the
/// same multipliers, so results are bitwise the unblocked loops'.
/// `.factor` records swaps in `piv`; `.solve` carries `x` instead.
fn eliminateBlocked(n: usize, a: []f64, piv: []u32, x: []f64, comptime mode: Mode) Error!void {
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

/// Pivot step k of `eliminateBlocked`: the unblocked body with the
/// row update stopped at the panel edge `kb`. Always stores the
/// multiplier, which `panelUpdate` reads. False on a singular pivot.
inline fn panelStep(n: usize, a: []f64, piv: []u32, x: []f64, k: usize, kb: usize, comptime mode: Mode) bool {
    const max_row = pivotRow(n, a, k);
    if (mode == .factor) piv[k] = @intCast(max_row);
    if (@abs(a[max_row * n + k]) < singular_tol) return false;
    if (max_row != k) {
        swapRowsSimd(a, n, k, max_row);
        if (mode == .solve) std.mem.swap(f64, &x[k], &x[max_row]);
    }
    const inv_pivot = @as(f64, 1.0) / a[k * n + k];
    const row_k = a[k * n ..][0..n];
    for (k + 1..n) |ii| {
        const factor = a[ii * n + k] * inv_pivot;
        a[ii * n + k] = factor;
        elimRowSimd(a[ii * n ..][0..n], row_k, factor, k + 1, kb);
        if (mode == .solve) x[ii] -= factor * x[k];
    }
    return true;
}

/// row[kb..n] -= row[kk] * a[kk, kb..n] for kk in [k0, kb), term by
/// term in increasing kk, which rounds like `kb - k0` separate
/// `elimRowSimd` calls. Four independent vector chains hide the
/// subtract latency.
inline fn panelUpdate(row: []f64, a: []const f64, n: usize, k0: usize, kb: usize) void {
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

/// First row i in [k, n) maximizing |a[i*n + k]|.
fn pivotRow(n: usize, a: []const f64, k: usize) usize {
    var max_val: f64 = @abs(a[k * n + k]);
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

/// U x = y in place: per row, W-lane partial sums, one reduce, the
/// scalar tail, then the divide.
fn backSubstitute(n: usize, a: []const f64, x: []f64) void {
    var ki: usize = n;
    while (ki > 0) {
        ki -= 1;
        const row = a[ki * n ..][0..n];
        var acc: V = @splat(@as(f64, 0));
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

/// row_i[start..n] -= factor * row_k[start..n].
inline fn elimRowSimd(row_i: []f64, row_k: []const f64, factor: f64, start: usize, n: usize) void {
    const fv: V = @splat(factor);
    var j = start;
    while (j + W <= n) : (j += W) {
        const kv: V = row_k[j..][0..W].*;
        const p: *[W]f64 = row_i[j..][0..W];
        const cur: V = p.*;
        p.* = cur - fv * kv;
    }
    while (j < n) : (j += 1) row_i[j] -= factor * row_k[j];
}

fn swapRowsSimd(a: []f64, n: usize, r1: usize, r2: usize) void {
    var j: usize = 0;
    while (j + W <= n) : (j += W) {
        const p1: *[W]f64 = a[r1 * n + j ..][0..W];
        const p2: *[W]f64 = a[r2 * n + j ..][0..W];
        const tmp = p1.*;
        p1.* = p2.*;
        p2.* = tmp;
    }
    while (j < n) : (j += 1) std.mem.swap(f64, &a[r1 * n + j], &a[r2 * n + j]);
}

/// x[i] -= xk * lu[i*n + k] for i in (k, n), gathering column k.
fn fmsSolveSimd(lu: []const f64, x: []f64, n: usize, k: usize, xk: f64) void {
    const xkv: V = @splat(xk);
    var ii = k + 1;
    while (ii + W <= n) : (ii += W) {
        var lv: [W]f64 = undefined;
        inline for (0..W) |w| lv[w] = lu[(ii + w) * n + k];
        const lvu: V = lv;
        const p: *[W]f64 = x[ii..][0..W];
        const cur: V = p.*;
        p.* = cur - xkv * lvu;
    }
    while (ii < n) : (ii += 1) x[ii] -= xk * lu[ii * n + k];
}
