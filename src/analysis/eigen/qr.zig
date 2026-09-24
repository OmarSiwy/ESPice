//! Dense real eigenvalues: balance, Hessenberg reduction, Francis
//! double-shift QR. Row-major n×n input, destroyed in place.
const std = @import("std");
const Complex = @import("numerics").Complex;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Eigs = struct { count: usize, converged: bool };

/// Writes eigenvalues into out (caller provides n slots — the exact upper
/// bound). A subdiagonal entry below `tol` relative to its diagonal pair
/// deflates. converged is false if `max_iter` Francis steps on one block were
/// exhausted (remaining eigenvalues dropped).
pub fn eigenvalues(n: usize, a: []f64, out: []Complex, tol: f64, max_iter: u32) Eigs {
    if (n == 0) return .{ .count = 0, .converged = true };

    if (n == 1) {
        out[0] = .{ .re = a[0], .im = 0 };
        return .{ .count = 1, .converged = true };
    }

    balance(n, a);
    hessenbergReduce(n, a);

    var count: usize = 0;
    var nn = n;
    var iter: u32 = 0;

    while (nn > 0) {
        // Top of the ACTIVE block: the largest l whose entry above it on the
        // subdiagonal is negligible. Chasing the bulge from row 0 instead —
        // which is what this did before there was a search — sweeps a
        // deflated block back into the iteration, and on a matrix that splits
        // in the middle (every MNA pencil with an isolated branch row does)
        // it stops converging at all.
        var l = nn - 1;
        while (l > 0) : (l -= 1) {
            const sub = @abs(a[l * n + (l - 1)]);
            const diag = @abs(a[(l - 1) * n + (l - 1)]) + @abs(a[l * n + l]);
            if (sub <= tol * @max(diag, 1e-30)) {
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
/// norm against its column's. D is powers of two, so the similarity is EXACT
/// in floating point and the eigenvalues are untouched — what changes is the
/// QR's conditioning, and A = −M⁻¹C spans the decades between a picofarad and
/// a kilohm, which is enough to hand back eigenvalues with the wrong ORDER of
/// magnitude (`pz/bench_pz_pz2` reported a pole at 4e15 rad/s for a circuit
/// whose fastest is 1e9). Numerical Recipes `balanc`, sweeping until a pass
/// changes nothing.
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

/// Extract eigenvalues of the 2x2 block at (offset, offset).
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

// ============================================================================
// Hessenberg reduction via Householder reflections (SIMD-accelerated)
// ============================================================================

pub fn hessenbergReduce(n: usize, a: []f64) void {
    if (n <= 2) return;

    for (0..n - 2) |k| {
        // Compute norm of sub-column a[k+1..n, k].
        var sigma: f64 = 0;
        for (k + 1..n) |row| {
            const v = a[row * n + k];
            sigma += v * v;
        }
        sigma = @sqrt(sigma);

        if (sigma < 1e-30) continue;

        if (a[(k + 1) * n + k] < 0) sigma = -sigma;

        a[(k + 1) * n + k] += sigma;
        const beta = 1.0 / (sigma * a[(k + 1) * n + k]);

        // Apply from the left: A := (I - beta * v * v^T) * A
        for (k..n) |j| {
            var dot_acc: V = @splat(0.0);
            var row: usize = k + 1;
            while (row + W <= n) : (row += W) {
                var vv: V = undefined;
                var av: V = undefined;
                inline for (0..W) |wi| {
                    vv[wi] = a[(row + wi) * n + k];
                    av[wi] = a[(row + wi) * n + j];
                }
                dot_acc += vv * av;
            }
            var dot: f64 = @reduce(.Add, dot_acc);
            while (row < n) : (row += 1) {
                dot += a[row * n + k] * a[row * n + j];
            }
            dot *= beta;
            row = k + 1;
            while (row < n) : (row += 1) {
                a[row * n + j] -= a[row * n + k] * dot;
            }
        }

        // Apply from the right: A := A * (I - beta * v * v^T)
        for (0..n) |row| {
            var dot_acc: V = @splat(0.0);
            var col: usize = k + 1;
            while (col + W <= n) : (col += W) {
                var vv: V = undefined;
                var av: V = undefined;
                inline for (0..W) |wi| {
                    vv[wi] = a[(col + wi) * n + k];
                    av[wi] = a[row * n + (col + wi)];
                }
                dot_acc += av * vv;
            }
            var dot: f64 = @reduce(.Add, dot_acc);
            while (col < n) : (col += 1) {
                dot += a[row * n + col] * a[col * n + k];
            }
            dot *= beta;
            col = k + 1;
            while (col + W <= n) : (col += W) {
                var vv: V = undefined;
                inline for (0..W) |wi| {
                    vv[wi] = a[(col + wi) * n + k];
                }
                inline for (0..W) |wi| {
                    a[row * n + (col + wi)] -= dot * vv[wi];
                }
            }
            while (col < n) : (col += 1) {
                a[row * n + col] -= dot * a[col * n + k];
            }
        }

        // Write sub-diagonal entry and zero below.
        a[(k + 1) * n + k] = -sigma;
        // The reflector maps its own storage v to -v (Hv = -v), leaving
        // nonzeros below the subdiagonal; francisStep reads those slots as
        // bulge entries, so they must be true zeros.
        for (k + 2..n) |row| a[row * n + k] = 0;
    }
}

// ============================================================================
// Francis double-shift QR step (SIMD-accelerated reflectors)
// ============================================================================

/// One bulge chase over the ACTIVE block, rows/columns [lo, nn).
fn francisStep(n: usize, a: []f64, lo: usize, nn: usize, iter: u32) void {
    // Shift polynomial from trailing 2x2 block.
    const am = a[(nn - 2) * n + (nn - 2)];
    const bm = a[(nn - 2) * n + (nn - 1)];
    const cm = a[(nn - 1) * n + (nn - 2)];
    const dm = a[(nn - 1) * n + (nn - 1)];

    var s = am + dm; // trace
    var t = am * dm - bm * cm; // determinant

    // EISPACK's exceptional shift. After ten sweeps the trailing 2x2 has
    // stopped telling the iteration anything, and a shift built from the
    // subdiagonal alone breaks the cycle. Without it a matrix with REPEATED
    // eigenvalues never deflates: `pz/bench_pz_pzt` is three identical R/L
    // sections, so all three of its poles sit on top of each other and the
    // iteration burned its whole budget without emitting one of them.
    if (iter > 0 and iter % 10 == 0) {
        const mag = @abs(cm) + @abs(a[(nn - 2) * n + (nn - 3)]);
        s = 1.5 * mag;
        t = mag * mag;
    }

    // First column of the implicit double-shift polynomial (H - sigma*I)(H - conj(sigma)*I).
    var x = a[lo * n + lo] * a[lo * n + lo] + a[lo * n + lo + 1] * a[(lo + 1) * n + lo] - s * a[lo * n + lo] + t;
    var y = a[(lo + 1) * n + lo] * (a[lo * n + lo] + a[(lo + 1) * n + (lo + 1)] - s);
    var z: f64 = a[(lo + 2) * n + lo] * a[(lo + 1) * n + lo];

    for (lo..nn - 1) |k| {
        const nr = @sqrt(x * x + y * y + z * z);
        if (nr < 1e-30) {
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

fn applyReflector3(n: usize, a: []f64, lo: usize, nn: usize, k: usize, x_in: f64, y_in: f64, z_in: f64, nr: f64) void {
    const sign_x: f64 = if (x_in >= 0) 1.0 else -1.0;
    const v0 = x_in + sign_x * nr;
    const v1 = y_in;
    const v2 = z_in;
    const denom = v0 * v0 + v1 * v1 + v2 * v2;
    if (denom < 1e-60) return;
    const beta = 2.0 / denom;

    const v0v: V = @splat(v0);
    const v1v: V = @splat(v1);
    const v2v: V = @splat(v2);
    const betav: V = @splat(beta);

    // Apply from left: rows k, k+1, k+2
    // Column lo-1 is the split this block was deflated at; reaching back into
    // it would refill the negligible subdiagonal entry and undo the split.
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
    // Scalar tail for non-W-aligned columns.
    while (j < nn) : (j += 1) {
        const dot = v0 * a[k * n + j] + v1 * a[(k + 1) * n + j] + v2 * a[(k + 2) * n + j];
        const tv = beta * dot;
        a[k * n + j] -= tv * v0;
        a[(k + 1) * n + j] -= tv * v1;
        a[(k + 2) * n + j] -= tv * v2;
    }

    // Apply from right: rows 0..min(nn-1, k+3), columns k, k+1, k+2
    const row_end = @min(nn, k + 4);
    for (0..row_end) |row| {
        const dot = a[row * n + k] * v0 + a[row * n + k + 1] * v1 + a[row * n + k + 2] * v2;
        const tv = beta * dot;
        a[row * n + k] -= tv * v0;
        a[row * n + k + 1] -= tv * v1;
        a[row * n + k + 2] -= tv * v2;
    }
}

fn applyReflector2(n: usize, a: []f64, lo: usize, nn: usize, k: usize, x_in: f64, y_in: f64) void {
    const nr = @sqrt(x_in * x_in + y_in * y_in);
    if (nr < 1e-30) return;

    const sign_x: f64 = if (x_in >= 0) 1.0 else -1.0;
    const v0 = x_in + sign_x * nr;
    const v1 = y_in;
    const denom = v0 * v0 + v1 * v1;
    if (denom < 1e-60) return;
    const beta = 2.0 / denom;

    const v0v: V = @splat(v0);
    const v1v: V = @splat(v1);
    const betav: V = @splat(beta);

    // Column lo-1 is the split this block was deflated at; reaching back into
    // it would refill the negligible subdiagonal entry and undo the split.
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
    // Scalar tail.
    while (j < nn) : (j += 1) {
        const dot = v0 * a[k * n + j] + v1 * a[(k + 1) * n + j];
        const tv = beta * dot;
        a[k * n + j] -= tv * v0;
        a[(k + 1) * n + j] -= tv * v1;
    }

    const row_end = @min(nn, k + 3);
    for (0..row_end) |row| {
        const dot = a[row * n + k] * v0 + a[row * n + k + 1] * v1;
        const tv = beta * dot;
        a[row * n + k] -= tv * v0;
        a[row * n + k + 1] -= tv * v1;
    }
}
