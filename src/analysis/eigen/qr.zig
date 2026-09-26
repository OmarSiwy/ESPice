//! Dense real eigenvalues: balance, Hessenberg reduction, Francis
//! double-shift QR. Row-major n×n input, destroyed in place.
const std = @import("std");
const Complex = @import("core").numerics.Complex;

const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

/// How many eigenvalues were written, and whether all of them were.
pub const Eigs = struct { count: usize, converged: bool };

/// Writes the eigenvalues of `a` (n×n, destroyed) into `out[0..count]`;
/// `out` needs n slots. A subdiagonal entry below `tol` relative to its
/// diagonal pair, or below eps·max|H|, deflates. `converged` is false when
/// one block exhausted `max_iter` Francis steps; its eigenvalues are then
/// missing.
pub fn eigenvalues(n: usize, a: []f64, out: []Complex, tol: f64, max_iter: u32) Eigs {
    const exact = isolate(n, a, out);
    const rest = francis(n - exact, a, out[exact..], tol, max_iter);
    return .{ .count = exact + rest.count, .converged = rest.converged };
}

/// dgebal's permutation step. A row or column whose off-diagonal part inside
/// the active block is zero carries its diagonal entry as an exact
/// eigenvalue; permuting it out of the block leaves the rest block-triangular.
/// Writes those eigenvalues to `out` and returns how many; the remaining
/// m×m block is compacted to the front of `a` with stride m.
///
/// An MNA pencil needs this: a gm chain makes A = −M⁻¹C triangular with 1e9
/// off the diagonal next to O(1) eigenvalues. Those eigenvalues are too
/// ill-conditioned for the QR, which turns four real poles into a complex
/// pair (`pz/bench_pz_pz2`), and balancing cannot help because it skips a row
/// with no off-diagonal mass.
fn isolate(n: usize, a: []f64, out: []Complex) usize {
    var lo: usize = 0;
    var hi: usize = n;
    var count: usize = 0;
    search: while (lo < hi) {
        for (lo..hi) |i| {
            for (lo..hi) |j| {
                if (j != i and a[i * n + j] != 0) break;
            } else {
                swap(n, a, i, hi - 1);
                hi -= 1;
                out[count] = .{ .re = a[hi * n + hi], .im = 0 };
                count += 1;
                continue :search;
            }
        }
        for (lo..hi) |j| {
            for (lo..hi) |i| {
                if (i != j and a[i * n + j] != 0) break;
            } else {
                swap(n, a, j, lo);
                out[count] = .{ .re = a[lo * n + lo], .im = 0 };
                count += 1;
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
        for (0..m) |c| a[r * m + c] = a[(lo + r) * n + lo + c];
    }
    return count;
}

/// Symmetric permutation: swaps rows i, k and columns i, k.
fn swap(n: usize, a: []f64, i: usize, k: usize) void {
    if (i == k) return;
    for (0..n) |j| std.mem.swap(f64, &a[i * n + j], &a[k * n + j]);
    for (0..n) |r| std.mem.swap(f64, &a[r * n + i], &a[r * n + k]);
}

/// Balance, Hessenberg reduction and Francis QR on a block with no isolated
/// eigenvalues left; `eigenvalues` states the contract.
fn francis(n: usize, a: []f64, out: []Complex, tol: f64, max_iter: u32) Eigs {
    if (n == 0) return .{ .count = 0, .converged = true };

    if (n == 1) {
        out[0] = .{ .re = a[0], .im = 0 };
        return .{ .count = 1, .converged = true };
    }

    balance(n, a);
    // `out` holds 2n f64s and nothing is written to it before the QR runs.
    hessenbergReduce(n, a, std.mem.bytesAsSlice(f64, std.mem.sliceAsBytes(out)));
    // The normwise floor deflates what the relative test cannot: a block of
    // roots at infinity is a cluster of noise eigenvalues around zero, and
    // its subdiagonal never falls below tol times its own noise-sized
    // diagonal (`multi_analysis/device_vbic_ce_amp`). Setting an entry below
    // eps·‖H‖ to zero is within the QR's own backward error.
    var norm: f64 = 0;
    for (a[0 .. n * n]) |v| norm = @max(norm, @abs(v));
    const floor = std.math.floatEps(f64) * norm;

    var count: usize = 0;
    var nn = n;
    var iter: u32 = 0;

    while (nn > 0) {
        // Top of the active block: the largest l whose subdiagonal entry is
        // negligible. Chasing the bulge from row 0 would sweep a deflated
        // block back into the iteration, and on a matrix that splits in the
        // middle (every MNA pencil with an isolated branch row does) the
        // iteration would stop converging.
        var l = nn - 1;
        while (l > 0) : (l -= 1) {
            const sub = @abs(a[l * n + (l - 1)]);
            const diag = @abs(a[(l - 1) * n + (l - 1)]) + @abs(a[l * n + l]);
            if (sub <= @max(tol * diag, floor)) {
                a[l * n + (l - 1)] = 0;
                break;
            }
        }

        if (l + 1 == nn) {
            out[count] = .{ .re = a[l * n + l], .im = 0 };
            count += 1;
            nn = l;
            iter = 0;
        } else if (l + 2 == nn) {
            extract2x2(a, n, l, out[count..][0..2]);
            count += 2;
            nn = l;
            iter = 0;
        } else {
            if (iter >= max_iter) return .{ .count = count, .converged = false };
            francisStep(n, a, l, nn, iter);
            iter += 1;
        }
    }
    return .{ .count = count, .converged = true };
}

/// dgebal-style scaling: the diagonal similarity D⁻¹AD that evens each row's
/// norm against its column's (Numerical Recipes `balanc`, swept until a pass
/// changes nothing). D is powers of two, so the similarity is exact in
/// floating point and only the QR's conditioning changes. That matters
/// because A = −M⁻¹C spans the decades between a picofarad and a kilohm:
/// unbalanced, `pz/bench_pz_pz2` gets a pole at 4e15 rad/s for a circuit
/// whose fastest is 1e9.
fn balance(n: usize, a: []f64) void {
    const radix: f64 = 2;
    const radix_sq = radix * radix;
    // The sweep is a fixed point and terminates on its own; the cap is here so
    // a denormal cannot turn that into a hang.
    for (0..64) |_| {
        var settled = true;
        for (0..n) |i| {
            var c: f64 = 0;
            var r: f64 = 0;
            for (0..n) |j| {
                if (j == i) continue;
                c += @abs(a[j * n + i]);
                r += @abs(a[i * n + j]);
            }
            if (c == 0 or r == 0) continue;
            const s = c + r;
            var f: f64 = 1;
            var g = r / radix;
            while (c < g) {
                f *= radix;
                c *= radix_sq;
            }
            g = r * radix;
            while (c > g) {
                f /= radix;
                c /= radix_sq;
            }
            if (!((c + r) / f < 0.95 * s)) continue;
            const inv = 1 / f;
            for (0..n) |j| a[i * n + j] *= inv;
            for (0..n) |j| a[j * n + i] *= f;
            settled = false;
        }
        if (settled) return;
    }
}

/// Eigenvalues of the 2x2 block at (offset, offset).
fn extract2x2(a: []const f64, n: usize, offset: usize, out: *[2]Complex) void {
    const a11 = a[offset * n + offset];
    const a12 = a[offset * n + offset + 1];
    const a21 = a[(offset + 1) * n + offset];
    const a22 = a[(offset + 1) * n + offset + 1];

    const tr = a11 + a22;
    const det = a11 * a22 - a12 * a21;
    const disc = tr * tr - 4.0 * det;

    if (disc >= 0) {
        const sq = @sqrt(disc);
        out[0] = .{ .re = (tr + sq) / 2.0, .im = 0 };
        out[1] = .{ .re = (tr - sq) / 2.0, .im = 0 };
    } else {
        const sq = @sqrt(-disc);
        out[0] = .{ .re = tr / 2.0, .im = sq / 2.0 };
        out[1] = .{ .re = tr / 2.0, .im = -sq / 2.0 };
    }
}

/// Reduces `a` (n×n, row-major) in place to upper Hessenberg form by
/// Householder similarities; the eigenvalues are unchanged and every entry
/// below the subdiagonal is an exact zero. `v_buf` is scratch of at least n
/// entries: a contiguous copy of each reflector, so its reads are vector
/// loads rather than stride-n gathers.
pub fn hessenbergReduce(n: usize, a: []f64, v_buf: []f64) void {
    if (n <= 2) return;

    for (0..n - 2) |k| {
        var sigma: f64 = 0;
        for (k + 1..n) |row| {
            const v = a[row * n + k];
            sigma += v * v;
        }
        sigma = @sqrt(sigma);

        if (sigma == 0) continue;

        if (a[(k + 1) * n + k] < 0) sigma = -sigma;

        a[(k + 1) * n + k] += sigma;
        const beta = 1.0 / (sigma * a[(k + 1) * n + k]);

        // The reflector v = a[k+1.., k]. Column j = k of the left update
        // rewrites it in place (to Hv, -v up to rounding), and every later
        // column and the right update read that rewritten copy, so the
        // buffer is refreshed after j = k.
        const m = n - (k + 1);
        const v = v_buf[0..m];
        for (v, k + 1..) |*x, row| x.* = a[row * n + k];

        // Apply from the left: A := (I - beta * v * v^T) * A
        for (k..n) |j| {
            if (j == k + 1) for (v, k + 1..) |*x, row| {
                x.* = a[row * n + k];
            };
            var dot_acc: V = @splat(0.0);
            var i: usize = 0;
            while (i + W <= m) : (i += W) {
                var av: V = undefined;
                inline for (0..W) |wi| av[wi] = a[(k + 1 + i + wi) * n + j];
                dot_acc += @as(V, v[i..][0..W].*) * av;
            }
            var dot: f64 = @reduce(.Add, dot_acc);
            while (i < m) : (i += 1) dot += v[i] * a[(k + 1 + i) * n + j];
            dot *= beta;
            for (v, k + 1..) |x, row| a[row * n + j] -= x * dot;
        }

        // Apply from the right: A := A * (I - beta * v * v^T)
        for (0..n) |row| {
            const ar = a[row * n + k + 1 ..][0..m];
            var dot_acc: V = @splat(0.0);
            var i: usize = 0;
            while (i + W <= m) : (i += W)
                dot_acc += @as(V, ar[i..][0..W].*) * @as(V, v[i..][0..W].*);
            var dot: f64 = @reduce(.Add, dot_acc);
            while (i < m) : (i += 1) dot += ar[i] * v[i];
            dot *= beta;
            const dv: V = @splat(dot);
            i = 0;
            while (i + W <= m) : (i += W)
                ar[i..][0..W].* = @as(V, ar[i..][0..W].*) - dv * @as(V, v[i..][0..W].*);
            while (i < m) : (i += 1) ar[i] -= dot * v[i];
        }

        // The reflector maps its own storage v to -v (Hv = -v), leaving
        // nonzeros below the subdiagonal; francisStep reads those slots as
        // bulge entries, so they must be true zeros.
        a[(k + 1) * n + k] = -sigma;
        for (k + 2..n) |row| a[row * n + k] = 0;
    }
}

/// One Francis double-shift bulge chase over the active block, rows and
/// columns [lo, nn).
fn francisStep(n: usize, a: []f64, lo: usize, nn: usize, iter: u32) void {
    // Shift polynomial from trailing 2x2 block.
    const am = a[(nn - 2) * n + (nn - 2)];
    const bm = a[(nn - 2) * n + (nn - 1)];
    const cm = a[(nn - 1) * n + (nn - 2)];
    const dm = a[(nn - 1) * n + (nn - 1)];

    var s = am + dm; // trace
    var t = am * dm - bm * cm; // determinant

    // EISPACK's exceptional shift: after ten sweeps the trailing 2x2 has
    // stopped steering the iteration, and a shift built from the subdiagonal
    // alone breaks the cycle. Without it a matrix with repeated eigenvalues
    // never deflates (`pz/bench_pz_pzt`, three identical R/L sections).
    if (iter > 0 and iter % 10 == 0) {
        const mag = @abs(cm) + @abs(a[(nn - 2) * n + (nn - 3)]);
        s = 1.5 * mag;
        t = mag * mag;
    }

    // First column of the implicit double-shift polynomial (H - sigma*I)(H - conj(sigma)*I):
    // (h00² + h01·h10 − s·h00 + t, h10·(h00 + h11 − s), h21·h10).
    var x = a[lo * n + lo] * a[lo * n + lo] + a[lo * n + lo + 1] * a[(lo + 1) * n + lo] - s * a[lo * n + lo] + t;
    var y = a[(lo + 1) * n + lo] * (a[lo * n + lo] + a[(lo + 1) * n + (lo + 1)] - s);
    var z: f64 = a[(lo + 2) * n + lo + 1] * a[(lo + 1) * n + lo];

    for (lo..nn - 1) |k| {
        const nr = @sqrt(x * x + y * y + z * z);
        if (nr == 0) {
            if (k + 1 < nn - 1) {
                x = a[(k + 1) * n + k];
                y = a[(k + 2) * n + k];
                z = if (k + 3 < nn) a[(k + 3) * n + k] else 0;
            }
            continue;
        }

        if (k + 2 < nn) {
            applyReflector3(n, a, lo, nn, k, x, y, z, nr);
        } else {
            applyReflector2(n, a, lo, nn, k, x, y);
        }

        if (k + 1 < nn - 1) {
            x = a[(k + 1) * n + k];
            y = a[(k + 2) * n + k];
            z = if (k + 3 < nn) a[(k + 3) * n + k] else 0;
        }
    }
}

/// Applies the 3-element Householder reflector that zeroes (y, z) against x
/// to rows and columns k..k+2 of the active block.
fn applyReflector3(n: usize, a: []f64, lo: usize, nn: usize, k: usize, x_in: f64, y_in: f64, z_in: f64, nr: f64) void {
    const sign_x: f64 = if (x_in >= 0) 1.0 else -1.0;
    const v0 = x_in + sign_x * nr;
    const v1 = y_in;
    const v2 = z_in;
    const denom = v0 * v0 + v1 * v1 + v2 * v2;
    if (denom == 0) return;
    const beta = 2.0 / denom;

    const v0v: V = @splat(v0);
    const v1v: V = @splat(v1);
    const v2v: V = @splat(v2);
    const betav: V = @splat(beta);

    // From the left, rows k..k+2. Column lo-1 is the split this block was
    // deflated at; reaching back into it would refill the negligible
    // subdiagonal entry and undo the split.
    const col_start = if (k > lo) k - 1 else lo;
    var j: usize = col_start;
    while (j + W <= nn) : (j += W) {
        const r0: V = a[k * n + j ..][0..W].*;
        const r1: V = a[(k + 1) * n + j ..][0..W].*;
        const r2: V = a[(k + 2) * n + j ..][0..W].*;
        const dot_v = v0v * r0 + v1v * r1 + v2v * r2;
        const tv = betav * dot_v;
        const p0: *[W]f64 = a[k * n + j ..][0..W];
        const p1: *[W]f64 = a[(k + 1) * n + j ..][0..W];
        const p2: *[W]f64 = a[(k + 2) * n + j ..][0..W];
        p0.* = r0 - tv * v0v;
        p1.* = r1 - tv * v1v;
        p2.* = r2 - tv * v2v;
    }
    while (j < nn) : (j += 1) {
        const dot = v0 * a[k * n + j] + v1 * a[(k + 1) * n + j] + v2 * a[(k + 2) * n + j];
        const tv = beta * dot;
        a[k * n + j] -= tv * v0;
        a[(k + 1) * n + j] -= tv * v1;
        a[(k + 2) * n + j] -= tv * v2;
    }

    // From the right, columns k..k+2, rows lo..min(nn, k+4). Rows above lo
    // couple to deflated blocks and are never read again, since only the
    // eigenvalues are wanted.
    const row_end = @min(nn, k + 4);
    for (lo..row_end) |row| {
        const dot = a[row * n + k] * v0 + a[row * n + k + 1] * v1 + a[row * n + k + 2] * v2;
        const tv = beta * dot;
        a[row * n + k] -= tv * v0;
        a[row * n + k + 1] -= tv * v1;
        a[row * n + k + 2] -= tv * v2;
    }
}

/// The 2-element reflector at the bottom of the chase, rows and columns
/// k..k+1.
fn applyReflector2(n: usize, a: []f64, lo: usize, nn: usize, k: usize, x_in: f64, y_in: f64) void {
    const nr = @sqrt(x_in * x_in + y_in * y_in);
    if (nr == 0) return;

    const sign_x: f64 = if (x_in >= 0) 1.0 else -1.0;
    const v0 = x_in + sign_x * nr;
    const v1 = y_in;
    const denom = v0 * v0 + v1 * v1;
    if (denom == 0) return;
    const beta = 2.0 / denom;

    const v0v: V = @splat(v0);
    const v1v: V = @splat(v1);
    const betav: V = @splat(beta);

    // Same column and row ranges as applyReflector3.
    const col_start = if (k > lo) k - 1 else lo;
    var j: usize = col_start;
    while (j + W <= nn) : (j += W) {
        const r0: V = a[k * n + j ..][0..W].*;
        const r1: V = a[(k + 1) * n + j ..][0..W].*;
        const dot_v = v0v * r0 + v1v * r1;
        const tv = betav * dot_v;
        const p0: *[W]f64 = a[k * n + j ..][0..W];
        const p1: *[W]f64 = a[(k + 1) * n + j ..][0..W];
        p0.* = r0 - tv * v0v;
        p1.* = r1 - tv * v1v;
    }
    while (j < nn) : (j += 1) {
        const dot = v0 * a[k * n + j] + v1 * a[(k + 1) * n + j];
        const tv = beta * dot;
        a[k * n + j] -= tv * v0;
        a[(k + 1) * n + j] -= tv * v1;
    }

    const row_end = @min(nn, k + 3);
    for (lo..row_end) |row| {
        const dot = a[row * n + k] * v0 + a[row * n + k + 1] * v1;
        const tv = beta * dot;
        a[row * n + k] -= tv * v0;
        a[row * n + k + 1] -= tv * v1;
    }
}
