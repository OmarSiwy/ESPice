//! Finite generalized eigenvalues of a dense real pencil: the roots λ of
//! det(A − λB) = 0, by exact-zero isolation, Hessenberg-triangular reduction
//! and the Moler-Stewart double-shift QZ (LAPACK dggbal 'P', dgghrd, dhgeqz).
//! Row-major n×n input, destroyed in place.
//!
//! Every transform is a Givens rotation. The 3-element Householders of the
//! textbook step cost fewer flops, but a pole-zero pencil is solved once per
//! query and one primitive keeps the step short.
const std = @import("std");
const Complex = @import("core").numerics.Complex;

const eps = std.math.floatEps(f64);

/// How many finite roots were written, and whether the iteration finished.
pub const Roots = struct { count: usize, converged: bool };

/// Writes the finite roots of det(A − λB) = 0 into `out[0..count]`; `out`
/// needs n slots. Roots at infinity (B singular) are dropped, and so is the
/// 0/0 of a singular pencil.
///
/// A root is infinite when its diagonal of B's triangular factor falls to
/// eps·‖B‖_F, within the QZ's own backward error. A defective block at
/// infinity lands there too, one zero diagonal per root, so the finite roots
/// need no magnitude cutoff. A subdiagonal of A's Hessenberg factor deflates
/// below `tol` relative to its diagonal pair, or below eps·‖A‖_F.
/// `converged` is false when one block exhausted `max_iter` QZ steps; its
/// roots are then missing.
pub fn roots(n: usize, a: []f64, b: []f64, out: []Complex, tol: f64, max_iter: u32) Roots {
    var count: usize = 0;
    const m = isolate(n, a, b, out, &count);
    if (m == 0) return .{ .count = count, .converged = true };
    hessenbergTriangular(m, a, b);

    var a_norm: f64 = 0;
    var b_norm: f64 = 0;
    for (a[0 .. m * m], b[0 .. m * m]) |av, bv| {
        a_norm += av * av;
        b_norm += bv * bv;
    }
    const a_tol = eps * @sqrt(a_norm);
    const b_tol = eps * @sqrt(b_norm);

    var hi = m;
    var iter: u32 = 0;
    while (hi > 0) {
        const l = hi - 1;
        // Top of the active block: the largest f whose subdiagonal entry is
        // negligible, as in qr.zig's Francis loop.
        var f = l;
        while (f > 0) : (f -= 1) {
            const sub = @abs(a[f * m + f - 1]);
            if (sub <= @max(tol * (@abs(a[f * m + f]) + @abs(a[(f - 1) * m + f - 1])), a_tol)) {
                a[f * m + f - 1] = 0;
                break;
            }
        }
        var j = f;
        while (j <= l and @abs(b[j * m + j]) > b_tol) j += 1;
        if (j <= l) {
            b[j * m + j] = 0;
            chaseInfinite(m, a, b, f, j, l);
            hi = l;
            iter = 0;
            continue;
        }
        if (f == l) {
            out[count] = .{ .re = a[l * m + l] / b[l * m + l], .im = 0 };
            count += 1;
            hi = l;
            iter = 0;
            continue;
        }
        const tr, const det = sumProduct(m, a, b, l - 1);
        if (f + 1 == l) {
            quadraticRoots(tr, det, out[count..][0..2]);
            count += 2;
            hi = f;
            iter = 0;
            continue;
        }
        if (iter >= max_iter) return .{ .count = count, .converged = false };
        qzStep(m, a, b, f, l, iter, tr, det);
        iter += 1;
    }
    return .{ .count = count, .converged = true };
}

/// dggbal's permutation step for a pencil: a row of the active block with at
/// most one nonzero column across A and B (or a column with at most one
/// nonzero row) is permuted to the block's bottom (top), leaving the pencil
/// block triangular with that 1×1 exact. Emits the finite ones into `out`
/// and compacts the remaining m×m block to the front of `a` and `b` with
/// stride m, returning m.
///
/// An MNA pencil needs this: a gm chain puts 1e9 off the diagonal next to
/// O(1) roots that the QZ would perturb into a complex pair
/// (`pz/bench_pz_pz2`), and every branch row and GROUND clamp is a root at
/// infinity whose B row is exactly empty.
fn isolate(n: usize, a: []f64, b: []f64, out: []Complex, count: *usize) usize {
    var lo: usize = 0;
    var hi: usize = n;
    search: while (lo < hi) {
        for (lo..hi) |i| {
            if (single(a, b, lo, hi, i, n, 1)) |j| {
                swap(n, a, b, i, hi - 1, n, 1);
                swap(n, a, b, j orelse hi - 1, hi - 1, 1, n);
                hi -= 1;
                emit(a[hi * n + hi], b[hi * n + hi], out, count);
                continue :search;
            }
        }
        for (lo..hi) |j| {
            if (single(a, b, lo, hi, j, 1, n)) |i| {
                swap(n, a, b, j, lo, 1, n);
                swap(n, a, b, i orelse lo, lo, n, 1);
                emit(a[lo * n + lo], b[lo * n + lo], out, count);
                lo += 1;
                continue :search;
            }
        }
        break;
    }
    // Read offsets only grow and never fall behind the write offset, so the
    // in-place copy never overwrites an entry it has yet to read.
    const m = hi - lo;
    for (0..m) |r| {
        for (0..m) |c| {
            a[r * m + c] = a[(lo + r) * n + lo + c];
            b[r * m + c] = b[(lo + r) * n + lo + c];
        }
    }
    return m;
}

/// For line `k` (a row when `major` = n, `minor` = 1; a column when swapped),
/// null when it has two or more nonzeros in [lo, hi) across A and B, else the
/// position of its one nonzero, or an inner null when it has none.
fn single(a: []const f64, b: []const f64, lo: usize, hi: usize, k: usize, major: usize, minor: usize) ??usize {
    var found: ?usize = null;
    for (lo..hi) |t| {
        const at = k * major + t * minor;
        if (a[at] == 0 and b[at] == 0) continue;
        if (found != null) return null;
        found = t;
    }
    return found;
}

/// Swaps lines `i` and `k` of both matrices: rows when `major` = n and
/// `minor` = 1, columns when swapped.
fn swap(n: usize, a: []f64, b: []f64, i: usize, k: usize, major: usize, minor: usize) void {
    if (i == k) return;
    for (0..n) |t| {
        std.mem.swap(f64, &a[i * major + t * minor], &a[k * major + t * minor]);
        std.mem.swap(f64, &b[i * major + t * minor], &b[k * major + t * minor]);
    }
}

/// An isolated 1×1 is exact, so any nonzero B entry is a finite root.
fn emit(av: f64, bv: f64, out: []Complex, count: *usize) void {
    if (bv == 0) return;
    out[count.*] = .{ .re = av / bv, .im = 0 };
    count.* += 1;
}

/// c, s with c·f + s·g = r and c·g − s·f = 0.
fn givens(f: f64, g: f64) struct { f64, f64 } {
    if (g == 0) return .{ 1, 0 };
    const r = std.math.hypot(f, g);
    return .{ f / r, g / r };
}

/// x ← c·x + s·y, y ← c·y − s·x over `len` entries `stride` apart, x at
/// `xi` and y at `yi`. Stride 1 rotates two rows; stride m two columns.
fn rot(mat: []f64, xi: usize, yi: usize, stride: usize, len: usize, c: f64, s: f64) void {
    for (0..len) |t| {
        const x = mat[xi + t * stride];
        const y = mat[yi + t * stride];
        mat[xi + t * stride] = c * x + s * y;
        mat[yi + t * stride] = c * y - s * x;
    }
}

/// Rotates rows p, q of `mat` over columns [c0, c1) so that entry (q, `col`)
/// becomes zero, and applies the same rotation to rows p, q of `other` over
/// [o0, c1).
fn rowZero(m: usize, mat: []f64, other: []f64, p: usize, q: usize, col: usize, c0: usize, o0: usize, c1: usize) void {
    const c, const s = givens(mat[p * m + col], mat[q * m + col]);
    rot(mat, p * m + c0, q * m + c0, 1, c1 - c0, c, s);
    rot(other, p * m + o0, q * m + o0, 1, c1 - o0, c, s);
    mat[q * m + col] = 0;
}

/// Rotates columns p, q of `mat` over rows [r0, r1) so that entry (`row`, p)
/// becomes zero, and applies the same rotation to columns p, q of `other`
/// over rows [r0, o1).
fn colZero(m: usize, mat: []f64, other: []f64, p: usize, q: usize, row: usize, r0: usize, r1: usize, o1: usize) void {
    const c, const s = givens(mat[row * m + q], mat[row * m + p]);
    rot(mat, r0 * m + q, r0 * m + p, m, r1 - r0, c, s);
    rot(other, r0 * m + q, r0 * m + p, m, o1 - r0, c, s);
    mat[row * m + p] = 0;
}

/// dgghrd: orthogonal Q, Z with QᵀAZ upper Hessenberg and QᵀBZ upper
/// triangular, B first by a Givens QR. Zeros already in place are skipped,
/// which on a sparse MNA pencil is most of them.
fn hessenbergTriangular(m: usize, a: []f64, b: []f64) void {
    for (0..m) |k| {
        var i = m - 1;
        while (i > k) : (i -= 1) {
            if (b[i * m + k] != 0) rowZero(m, b, a, i - 1, i, k, k, 0, m);
        }
    }
    if (m < 3) return;
    for (0..m - 2) |k| {
        var i = m - 1;
        while (i > k + 1) : (i -= 1) {
            if (a[i * m + k] == 0) continue;
            rowZero(m, a, b, i - 1, i, k, k, i - 1, m);
            colZero(m, b, a, i - 1, i, i, 0, i + 1, m);
        }
    }
}

/// Moves the zero at B(j, j) of the unreduced block [f, l] down to B(l, l)
/// and splits it off there with A(l, l−1) = 0: a root at infinity,
/// deflated. dhgeqz's chase when the zero is not at the top of its block;
/// used for every position, since at the top it only skips a fill.
fn chaseInfinite(m: usize, a: []f64, b: []f64, f: usize, j: usize, l: usize) void {
    for (j..l) |k| {
        // Rows k, k+1: B(k+1, k+1) → 0, which leaves B(k, k) at zero and
        // fills A(k+1, k−1).
        const c, const s = givens(b[k * m + k + 1], b[(k + 1) * m + k + 1]);
        rot(b, k * m + k + 1, (k + 1) * m + k + 1, 1, l + 1 - (k + 1), c, s);
        b[(k + 1) * m + k + 1] = 0;
        const c0 = if (k > f) k - 1 else k;
        rot(a, k * m + c0, (k + 1) * m + c0, 1, l + 1 - c0, c, s);
        // Columns k−1, k clear that fill; B(k−1, k−1) picks up B(k−1, k),
        // so the zero has moved one step down.
        if (k > f) colZero(m, a, b, k - 1, k, k + 1, f, k + 2, k);
    }
    if (l > f) colZero(m, a, b, l - 1, l, l, f, l + 1, l);
}

/// Sum and product of the two roots of the 2×2 subpencil at (p, p): the
/// trace and determinant of A₂₂B₂₂⁻¹. B's diagonal there is above b_tol.
fn sumProduct(m: usize, a: []const f64, b: []const f64, p: usize) struct { f64, f64 } {
    const q = p + 1;
    const h11 = a[p * m + p] / b[p * m + p];
    const h21 = a[q * m + p] / b[p * m + p];
    // Second column of A₂₂B₂₂⁻¹: B₂₂⁻¹e₂ = (−b12/(b11·b22), 1/b22).
    const h12 = (a[p * m + q] - h11 * b[p * m + q]) / b[q * m + q];
    const h22 = (a[q * m + q] - h21 * b[p * m + q]) / b[q * m + q];
    return .{ h11 + h22, h11 * h22 - h12 * h21 };
}

/// Roots of λ² − tr·λ + det, the larger real one first by the stable form.
fn quadraticRoots(tr: f64, det: f64, out: *[2]Complex) void {
    const disc = tr * tr - 4 * det;
    if (disc < 0) {
        const im = @sqrt(-disc) / 2;
        out[0] = .{ .re = tr / 2, .im = im };
        out[1] = .{ .re = tr / 2, .im = -im };
        return;
    }
    const q = (tr + std.math.copysign(@sqrt(disc), tr)) / 2;
    out[0] = .{ .re = q, .im = 0 };
    out[1] = .{ .re = if (q == 0) 0 else det / q, .im = 0 };
}

/// One implicit double-shift QZ sweep over the unreduced block [f, l]
/// (at least 3×3) with shifts the roots of λ² − tr·λ + det: a bulge
/// introduced from the first column of (AB⁻¹)² − tr·AB⁻¹ + det, chased down
/// by row rotations on A and column rotations that keep B triangular.
fn qzStep(m: usize, a: []f64, b: []f64, f: usize, l: usize, iter: u32, tr_in: f64, det_in: f64) void {
    var tr = tr_in;
    var det = det_in;
    // EISPACK's exceptional shift, as in qr.zig: after ten sweeps the
    // trailing block has stopped steering the iteration.
    if (iter > 0 and iter % 10 == 0) {
        const mag = @abs(a[l * m + l - 1] / b[(l - 1) * m + l - 1]) +
            @abs(a[(l - 1) * m + l - 2] / b[(l - 2) * m + l - 2]);
        tr = 1.5 * mag;
        det = mag * mag;
    }
    // Leading 3×2 of M = AB⁻¹ on the block, Hessenberg like A.
    const g = f + 1;
    const m11 = a[f * m + f] / b[f * m + f];
    const m21 = a[g * m + f] / b[f * m + f];
    const m12 = (a[f * m + g] - m11 * b[f * m + g]) / b[g * m + g];
    const m22 = (a[g * m + g] - m21 * b[f * m + g]) / b[g * m + g];
    const m32 = a[(g + 1) * m + g] / b[g * m + g];
    // First column of (M − λ₁)(M − λ₂): the bulge, three nonzeros.
    var x = m11 * m11 + m12 * m21 - tr * m11 + det;
    var y = m21 * (m11 + m22 - tr);
    var z = m21 * m32;

    for (f..l) |k| {
        if (k > f) {
            x = a[k * m + k - 1];
            y = a[(k + 1) * m + k - 1];
            z = if (k + 2 <= l) a[(k + 2) * m + k - 1] else 0;
        }
        const c0 = if (k > f) k - 1 else f;
        // Rows k+1, k+2 then k, k+1: (x, y, z) → (*, 0, 0).
        if (k + 2 <= l) {
            const c, const s = givens(y, z);
            rot(a, (k + 1) * m + c0, (k + 2) * m + c0, 1, l + 1 - c0, c, s);
            rot(b, (k + 1) * m + k, (k + 2) * m + k, 1, l + 1 - k, c, s);
            y = c * y + s * z;
            if (k > f) a[(k + 2) * m + k - 1] = 0;
        }
        const c, const s = givens(x, y);
        rot(a, k * m + c0, (k + 1) * m + c0, 1, l + 1 - c0, c, s);
        rot(b, k * m + k, (k + 1) * m + k, 1, l + 1 - k, c, s);
        if (k > f) a[(k + 1) * m + k - 1] = 0;
        // Rows k+1, k+2 went first, so B(k+2, k) is still zero and only
        // B(k+2, k+1) and B(k+1, k) need restoring, by columns.
        const r1 = @min(k + 4, l + 1);
        if (k + 2 <= l) colZero(m, b, a, k + 1, k + 2, k + 2, f, k + 3, r1);
        colZero(m, b, a, k, k + 1, k + 1, f, k + 2, r1);
    }
}
