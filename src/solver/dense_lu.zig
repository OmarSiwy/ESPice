//! Dense row-major LU with partial pivoting and SIMD row operations, for the
//! small dense f64 systems: HB/PSS Jacobians, BBD blocks and the dense AC
//! path. Matrices are n x n, row-major, stride n. From n = 40 elimination
//! runs in rank-8 panels; the unblocked loops are its bitwise oracle.
//! Cites LAPACK's dgetrf pivot convention and #160 (`pinVoid`).

const std = @import("std");
const assert = std.debug.assert;
const num = @import("core").numerics;

// ponytail: rank-8 panels are the only blocking; 2-D register tiling of the
// trailing update is next if dense solves dominate again.

/// A pivot fell below eps^2 or was not finite.
pub const Error = error{Singular};

const W = std.simd.suggestVectorLength(f64) orelse 1;
const V = @Vector(W, f64);
/// Pivot magnitudes below eps^2 (4.9e-32) count as zero.
const singular_tol: f64 = std.math.floatEps(f64) * std.math.floatEps(f64);

/// Whether pivot `p` fails the factor: below `singular_tol`, inf or NaN.
/// The pivot search never picks a NaN over a finite candidate, but strict
/// elimination carries any NaN entry into some later pivot, so every NaN
/// input fails here.
inline fn badPivot(p: f64) bool {
    return !(@abs(p) >= singular_tol and @abs(p) <= std.math.floatMax(f64));
}

/// x = A^-1 b in one elimination pass, O(n^3). Destroys `a`; `b` and `x`
/// must not alias. `Singular` when a pivot falls below eps^2 in absolute
/// terms or is not finite; `x` is then partial. Asserts that `a` holds
/// n x n entries, `b` and `x` at least n each, and that `b` is not `x`.
pub fn factorizeSolve(n: usize, a: []f64, b: []const f64, x: []f64) Error!void {
    return factorizeSolveImpl(n, a, b, x, false);
}

/// x = -A^-1 b, the Newton step. Destroys `a`; `b` and `x` must not
/// alias. Asserts as `factorizeSolve` does.
pub fn factorizeSolveNeg(n: usize, a: []f64, b: []const f64, x: []f64) Error!void {
    return factorizeSolveImpl(n, a, b, x, true);
}

/// PA = LU in place: unit-lower L below the diagonal, U on and above
/// it. `piv[k]` is the row swapped with row k at step k (LAPACK
/// convention). O(n^3). `Singular` as in `factorizeSolve`; on error `a`
/// and `piv` are partial. Asserts that `a` holds n x n entries and `piv`
/// at least n.
pub fn factorize(n: usize, a: []f64, piv: []u32) Error!void {
    assert(a.len >= n * n);
    assert(piv.len >= n);
    if (n >= blocked_min) return eliminateBlocked(n, a, piv, &.{}, .factor);
    for (0..n) |k| {
        const max_row = pivotRow(n, a, k);
        piv[k] = @intCast(max_row);
        if (max_row != k) swapRows(a, n, k, max_row);

        const pivot = a[k * n + k];
        if (badPivot(pivot)) return error.Singular;
        const inv_pivot = @as(f64, 1.0) / pivot;
        const row_k = a[k * n ..][0..n];
        for (k + 1..n) |ii| {
            const factor = a[ii * n + k] * inv_pivot;
            a[ii * n + k] = factor;
            const row_i = a[ii * n ..][0..n];
            elimRow(row_i, row_k, factor, k + 1, n);
        }
    }
}

/// x = A^-1 b from `factorize` output. `b` and `x` may alias. Asserts that
/// `lu` holds n x n entries and `piv`, `b` and `x` at least n each.
pub fn solveFactored(n: usize, lu: []const f64, piv: []const u32, b: []const f64, x: []f64) void {
    assert(lu.len >= n * n);
    assert(piv.len >= n);
    assert(b.len >= n);
    assert(x.len >= n);
    if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

    // All swaps first: interleaving them with the elimination is
    // wrong when a later pivot touches a row an earlier column used.
    for (0..n) |k| {
        if (piv[k] != k) std.mem.swap(f64, &x[k], &x[piv[k]]);
    }

    // Forward through unit-lower L, a row at a time: contiguous dots over
    // x from its first nonzero, since leading zeros stay zero (sparse
    // right-hand sides are common). The column sweep this replaces
    // gathered one double per cache line: 2.2x slower at n = 8 to 64, 4.7x
    // at n = 512 (ReleaseFast, i9-14900HX).
    var f: usize = 0;
    while (f < n and x[f] == 0) f += 1;
    // `numerics.dot`'s 16 strict accumulators vectorize and keep NaN and
    // Inf exact; fast-math could drop a NaN the solve must return.
    if (f < n) for (f + 1..n) |i| {
        x[i] -= num.dot(lu[i * n ..][f..i], x[f..i]);
    };

    backSubstitute(n, lu, x);
}

/// x = A^-T b from `factorize` output: A^T = U^T L^T P, so forward
/// through U^T, back through L^T, then undo the swaps. `b` and `x`
/// may alias. Asserts as `solveFactored` does.
pub fn solveFactoredT(n: usize, lu: []const f64, piv: []const u32, b: []const f64, x: []f64) void {
    assert(lu.len >= n * n);
    assert(piv.len >= n);
    assert(b.len >= n);
    assert(x.len >= n);
    if (x.ptr != b.ptr) @memcpy(x[0..n], b[0..n]);

    // Both sweeps run over rows of the factor, contiguous, as axpys: x[j]
    // is final once its own row is reached, and row j then updates every
    // x it couples to. Strided column dots were 2.7x slower on the L^T
    // sweep at n = 64, 5x at n = 512.
    for (0..n) |j| {
        const row = lu[j * n ..][0..n];
        x[j] /= row[j];
        elimRow(x, row, x[j], j + 1, n);
    }

    var j = n;
    while (j > 1) {
        j -= 1;
        elimRow(x, lu[j * n ..][0..n], x[j], 0, j);
    }

    var k = n;
    while (k > 0) {
        k -= 1;
        if (piv[k] != k) std.mem.swap(f64, &x[k], &x[piv[k]]);
    }
}

/// Writes the stacked-real admittance [G, -ωC; ωC, G] into `a`
/// (row-major, stride nn = 2n) from n x n row-major G and C. Every entry
/// of the 2n x 2n block is written. Asserts that nn = 2n and that each
/// slice holds its matrix.
pub fn buildComplexAdmittance(
    n: usize,
    nn: usize,
    g_dense: []const f64,
    c_mat: []const f64,
    omega: f64,
    a: []f64,
) void {
    assert(nn == 2 * n);
    assert(g_dense.len >= n * n);
    assert(c_mat.len >= n * n);
    assert(a.len >= nn * nn);
    for (0..n) |row| {
        const top = a[row * nn ..][0..nn];
        const bot = a[(n + row) * nn ..][0..nn];
        for (g_dense[row * n ..][0..n], c_mat[row * n ..][0..n], top[0..n], top[n..], bot[0..n], bot[n..]) |g, c, *tl, *tr, *bl, *br| {
            tl.* = g;
            tr.* = -omega * c;
            bl.* = omega * c;
            br.* = g;
        }
    }
}

/// Gives every structurally void unknown (row i and column i all zero) a
/// unit pivot, as `SparseLu.voidUnknown` does: a compact model's disabled
/// branch flow (HICUM's `Temp(br_sht) <+ 0` with tnode grounded) is a free
/// variable, not a singular system, and solves to x_i = b_i (#160). Only
/// for a whole circuit matrix: a zero row inside a BBD block can still
/// couple through the border. O(n^2) against the O(n^3) factorization.
pub fn pinVoid(n: usize, a: []f64) void {
    outer: for (0..n) |i| {
        for (a[i * n ..][0..n]) |v| if (v != 0) continue :outer;
        for (0..n) |r| if (a[r * n + i] != 0) continue :outer;
        a[i * n + i] = 1;
    }
}

/// Carries x through the elimination instead of recording pivots.
fn factorizeSolveImpl(n: usize, a: []f64, b: []const f64, x: []f64, comptime negate: bool) Error!void {
    assert(a.len >= n * n);
    assert(b.len >= n);
    assert(x.len >= n);
    if (n > 0) assert(b.ptr != x.ptr);
    if (negate) {
        num.scale(x[0..n], -1, b[0..n]);
    } else {
        @memcpy(x[0..n], b[0..n]);
    }
    if (n >= blocked_min) {
        try eliminateBlocked(n, a, &.{}, x, .solve);
        return backSubstitute(n, a, x);
    }

    for (0..n) |k| {
        const max_row = pivotRow(n, a, k);
        if (badPivot(a[max_row * n + k])) return error.Singular;
        if (max_row != k) {
            swapRows(a, n, k, max_row);
            std.mem.swap(f64, &x[k], &x[max_row]);
        }
        const pivot = a[k * n + k];
        const inv_pivot = @as(f64, 1.0) / pivot;
        const row_k = a[k * n ..][0..n];
        for (k + 1..n) |ii| {
            const factor = a[ii * n + k] * inv_pivot;
            const row_i = a[ii * n ..][0..n];
            elimRow(row_i, row_k, factor, k + 1, n);
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
comptime {
    // The vector row loops step by whole vectors inside one panel.
    assert(std.math.isPowerOfTwo(W));
    assert(blocked_min >= block);
}

const Mode = enum { factor, solve };

/// Blocked right-looking elimination. A panel of `block` columns is
/// factored as in the unblocked loops, then each trailing row takes
/// all the panel's updates in one pass while the panel's U rows stay
/// in L1. Every entry still gets `a -= l * u` in increasing k with the
/// same multipliers, so results are bitwise the unblocked loops'.
/// `.factor` records swaps in `piv`; `.solve` carries `x` instead.
fn eliminateBlocked(n: usize, a: []f64, piv: []u32, x: []f64, comptime mode: Mode) Error!void {
    assert(n >= blocked_min);
    if (mode == .factor) assert(piv.len >= n) else assert(x.len >= n);
    var k0: usize = 0;
    while (k0 < n) : (k0 += block) {
        const kb = @min(k0 + block, n);
        for (k0..kb) |k| if (!panelStep(n, a, piv, x, k, kb, mode)) return error.Singular;
        if (kb == n) break;
        // The panel's own U rows, trailing columns: row k takes the
        // updates of rows k0..k-1, which are final by then.
        for (k0 + 1..kb) |k| {
            const row = a[k * n ..][0..n];
            for (k0..k) |kk| elimRow(row, a[kk * n ..][0..n], row[kk], kb, n);
        }
        for (kb..n) |i| panelUpdate(a[i * n ..][0..n], a, n, k0, kb);
    }
}

/// Pivot step k of `eliminateBlocked`: the unblocked body with the
/// row update stopped at the panel edge `kb`. Always stores the
/// multiplier, which `panelUpdate` reads. False on a singular pivot.
inline fn panelStep(n: usize, a: []f64, piv: []u32, x: []f64, k: usize, kb: usize, comptime mode: Mode) bool {
    assert(k < kb);
    assert(kb <= n);
    const max_row = pivotRow(n, a, k);
    if (mode == .factor) piv[k] = @intCast(max_row);
    if (badPivot(a[max_row * n + k])) return false;
    if (max_row != k) {
        swapRows(a, n, k, max_row);
        if (mode == .solve) std.mem.swap(f64, &x[k], &x[max_row]);
    }
    const inv_pivot = @as(f64, 1.0) / a[k * n + k];
    const row_k = a[k * n ..][0..n];
    for (k + 1..n) |ii| {
        const factor = a[ii * n + k] * inv_pivot;
        a[ii * n + k] = factor;
        elimRow(a[ii * n ..][0..n], row_k, factor, k + 1, kb);
        if (mode == .solve) x[ii] -= factor * x[k];
    }
    return true;
}

/// row[kb..n] -= row[kk] * a[kk, kb..n] for kk in [k0, kb), term by
/// term in increasing kk, which rounds like `kb - k0` separate
/// `elimRow` calls. Four independent vector chains hide the
/// subtract latency; the plain loop with kk outer (one `elimRow` per kk)
/// measured 1.4x slower at n = 128 and 1.7x at n = 64.
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
    assert(k < n);
    var max_val: f64 = @abs(a[k * n + k]);
    var max_row: usize = k;
    for (k + 1..n) |i| {
        const v = @abs(a[i * n + k]);
        if (v > max_val) {
            max_val = v;
            max_row = i;
        }
    }
    assert(max_row >= k);
    return max_row;
}

/// U x = y in place: per row, a dot over the row's tail, then the divide.
fn backSubstitute(n: usize, a: []const f64, x: []f64) void {
    assert(a.len >= n * n);
    assert(x.len >= n);
    var ki: usize = n;
    while (ki > 0) {
        ki -= 1;
        const row = a[ki * n ..][0..n];
        x[ki] = (x[ki] - num.dot(row[ki + 1 ..], x[ki + 1 .. n])) / row[ki];
    }
}

/// row_i[start..n] -= factor * row_k[start..n]. A plain loop: LLVM
/// vectorizes it behind a runtime alias check.
inline fn elimRow(row_i: []f64, row_k: []const f64, factor: f64, start: usize, n: usize) void {
    for (row_i[start..n], row_k[start..n]) |*a, b| a.* -= factor * b;
}

fn swapRows(a: []f64, n: usize, r1: usize, r2: usize) void {
    assert(r1 < n);
    assert(r2 < n);
    for (a[r1 * n ..][0..n], a[r2 * n ..][0..n]) |*p, *q| {
        const t = p.*;
        p.* = q.*;
        q.* = t;
    }
}

/// Private kernels for src/solver/tests.zig; empty outside test builds.
pub const test_access = if (@import("builtin").is_test) .{ .backSubstitute = backSubstitute } else {};

const testing = std.testing;

/// LAPACK's scaled residual ||A x - b|| / (||A|| ||x|| n eps) in max norms,
/// with n max|a_ij| bounding ||A||; `transpose` checks A^T x = b.
fn scaledResidual(n: usize, a: []const f64, x: []const f64, b: []const f64, transpose: bool) f64 {
    var rmax: f64 = 0;
    var amax: f64 = 0;
    var xmax: f64 = 0;
    for (0..n) |i| {
        var ri = b[i];
        for (0..n) |j| {
            const aij = if (transpose) a[j * n + i] else a[i * n + j];
            ri -= aij * x[j];
            amax = @max(amax, @abs(aij));
        }
        rmax = @max(rmax, @abs(ri));
        xmax = @max(xmax, @abs(x[i]));
    }
    const nf: f64 = @floatFromInt(n);
    return rmax / (nf * amax * xmax * nf * std.math.floatEps(f64));
}

test "every entry point solves random systems, blocked and unblocked, and agrees on singular ones" {
    // A wrong solve scores ~1/(n eps), 1e13 and up.
    const thresh = 1e4;
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xde45e);
    const r = prng.random();
    // Past blocked_min, with every panel tail length.
    for (0..2 * blocked_min + block + 1) |n| {
        const buf = try gpa.alloc(f64, 2 * n * n + 3 * n);
        defer gpa.free(buf);
        const a0 = buf[0 .. n * n];
        const a = buf[n * n .. 2 * n * n];
        const b = buf[2 * n * n ..][0..n];
        const x = buf[2 * n * n + n ..][0..n];
        const x2 = buf[2 * n * n + 2 * n ..][0..n];
        const piv = try gpa.alloc(u32, n);
        defer gpa.free(piv);
        for (a0) |*v| v.* = 2 * r.float(f64) - 1;
        for (b) |*v| v.* = 2 * r.float(f64) - 1;

        @memcpy(a, a0);
        try factorize(n, a, piv);
        solveFactored(n, a, piv, b, x);
        @memcpy(x2, b);
        solveFactored(n, a, piv, x2, x2);
        try testing.expectEqualSlices(u64, @ptrCast(x), @ptrCast(x2));
        if (n > 0) try testing.expect(scaledResidual(n, a0, x, b, false) <= thresh);
        solveFactoredT(n, a, piv, b, x);
        if (n > 0) try testing.expect(scaledResidual(n, a0, x, b, true) <= thresh);

        @memcpy(a, a0);
        try factorizeSolve(n, a, b, x);
        if (n > 0) try testing.expect(scaledResidual(n, a0, x, b, false) <= thresh);
        @memcpy(a, a0);
        try factorizeSolveNeg(n, a, b, x2);
        for (x, x2) |p, m| try testing.expect(m == -p);

        if (n == 0) continue;
        @memset(a, 0);
        try testing.expectError(error.Singular, factorize(n, a, piv));
        @memset(a, 0);
        try testing.expectError(error.Singular, factorizeSolve(n, a, b, x));
    }
}

test "a void unknown solves to x_i = b_i, blocked and unblocked (#160)" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x160);
    const r = prng.random();
    for ([_]usize{ 3, 2 * blocked_min + 1 }) |n| {
        const buf = try gpa.alloc(f64, 2 * n * n + 3 * n);
        defer gpa.free(buf);
        const a0 = buf[0 .. n * n];
        const a = buf[n * n .. 2 * n * n];
        const b = buf[2 * n * n ..][0..n];
        const x = buf[2 * n * n + n ..][0..n];
        const x2 = buf[2 * n * n + 2 * n ..][0..n];
        const piv = try gpa.alloc(u32, n);
        defer gpa.free(piv);
        for (a0, 0..) |*v, k| v.* = if (k / n == k % n) @as(f64, @floatFromInt(n)) else 2 * r.float(f64) - 1;
        for (b) |*v| v.* = 2 * r.float(f64) - 1;
        // Unknown 1 appears in no equation and equation 1 holds no unknown.
        for (0..n) |k| {
            a0[n + k] = 0;
            a0[k * n + 1] = 0;
        }
        @memcpy(a, a0);
        try testing.expectError(error.Singular, factorize(n, a, piv));
        @memcpy(a, a0);
        pinVoid(n, a);
        try factorize(n, a, piv);
        solveFactored(n, a, piv, b, x);
        @memcpy(a, a0);
        pinVoid(n, a);
        try factorizeSolve(n, a, b, x2);
        try testing.expectEqual(b[1], x[1]);
        try testing.expectEqual(b[1], x2[1]);
        // The other equations hold: A x = b with x_1 free.
        a0[n + 1] = 1;
        try testing.expect(scaledResidual(n, a0, x, b, false) <= 1e4);
        try testing.expect(scaledResidual(n, a0, x2, b, false) <= 1e4);
    }
}

test "the singular threshold is |pivot| < eps^2 exactly, blocked and unblocked" {
    const gpa = testing.allocator;
    for ([_]usize{ 3, blocked_min + 1 }) |n| {
        const buf = try gpa.alloc(f64, n * n + 2 * n);
        defer gpa.free(buf);
        const a = buf[0 .. n * n];
        const b = buf[n * n ..][0..n];
        const x = buf[n * n + n ..][0..n];
        const piv = try gpa.alloc(u32, n);
        defer gpa.free(piv);
        @memset(b, 1);
        // c I with c = eps^2 factors and solves to 1/c exactly; one ulp
        // below is singular.
        for ([_]f64{ singular_tol, std.math.nextAfter(f64, singular_tol, 0) }, [_]bool{ true, false }) |c, ok| {
            for (a, 0..) |*v, k| v.* = if (k / n == k % n) c else 0;
            if (factorizeSolve(n, a, b, x)) |_| {
                try testing.expect(ok);
                for (x) |v| try testing.expectEqual(1 / c, v);
            } else |_| try testing.expect(!ok);
            for (a, 0..) |*v, k| v.* = if (k / n == k % n) c else 0;
            try testing.expectEqual(ok, if (factorize(n, a, piv)) |_| true else |_| false);
        }
    }
}

test "a NaN or inf entry anywhere fails the factor, blocked and unblocked" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x7a7);
    const r = prng.random();
    for ([_]usize{ 1, 2, 5, blocked_min + 3 }) |n| for (0..20) |i| {
        const buf = try gpa.alloc(f64, 2 * n * n + 2 * n);
        defer gpa.free(buf);
        const a = buf[0 .. n * n];
        const a2 = buf[n * n ..][0 .. n * n];
        const b = buf[2 * n * n ..][0..n];
        const x = buf[2 * n * n + n ..][0..n];
        const piv = try gpa.alloc(u32, n);
        defer gpa.free(piv);
        for (a) |*v| v.* = 2 * r.float(f64) - 1;
        for (b) |*v| v.* = 1 + r.float(f64);
        // The diagonal first: a NaN pivot used to pass the eps^2 test.
        const at = if (i == 0) 0 else r.uintLessThan(usize, n * n);
        a[at] = if (i % 2 == 0) std.math.nan(f64) else -std.math.inf(f64);
        @memcpy(a2, a);
        try testing.expectError(error.Singular, factorizeSolve(n, a, b, x));
        try testing.expectError(error.Singular, factorize(n, a2, piv));
    };
}
