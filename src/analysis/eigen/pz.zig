//! Pole-zero analysis: eigenvalues λ of A = −G⁻¹C are negated time
//! constants; poles are s = 1/λ. Dense Hessenberg + Francis double-shift QR.
//! The planes are the linearization — one eval() at the op.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("solvers").types;
const solvers = @import("solvers");
const dense_lu = solvers.dense_lu;

const Complex = types.Complex;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = struct {
    tol: converger.Tolerances = .{},
    qr_max_iter: u32 = 1000,
    qr_tol: f64 = 1e-12,
};

pub const Poles = struct {
    poles: []Complex,
    n_stable: u32,
    /// False if the QR iteration hit qr_max_iter before deflating every
    /// eigenvalue — the pole list is then incomplete.
    qr_converged: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Poles) void {
        self.allocator.free(self.poles);
    }
};

/// Poles at a precomputed operating point x_op. Eigenvalues λ of A = −G⁻¹C
/// are negated time constants (seconds); poles are s = 1/λ rad/s. |λ| ≈ 0
/// eigenvalues (resistive nodes, branch rows) carry no dynamics and are
/// discarded. Returns error.Singular when G is singular (pure-C node).
pub fn solve(
    ckt: *root.Circuit,
    x_op: []const f64,
    options: Options,
    allocator: std.mem.Allocator,
) !Poles {
    const n: usize = ckt.n;

    // Linearize: one eval fills the G and C planes (ground row included).
    ckt.eval(x_op, 0);

    // ponytail: one bulk alloc for all f64 work buffers
    const f64_total = 3 * n * n + 2 * n;
    const arena = try allocator.alloc(f64, f64_total);
    defer allocator.free(arena);
    const piv = try allocator.alloc(u32, n);
    defer allocator.free(piv);
    // At most n eigenvalues — exact upper bound, no growth.
    const eigs = try allocator.alloc(Complex, n);
    defer allocator.free(eigs);

    const a_mat = arena[0 .. n * n];
    const g_lu = arena[n * n .. 2 * n * n];
    const c_mat = arena[2 * n * n .. 3 * n * n];
    const col_rhs = arena[3 * n * n ..][0..n];
    const col_sol = arena[3 * n * n + n ..][0..n];
    ckt.denseG(g_lu);
    ckt.denseC(c_mat);

    try dense_lu.factorize(n, g_lu, piv);

    // A = −G⁻¹C: one back-substitution per column of C.
    for (0..n) |j| {
        // Extract column j of C into col_rhs.
        for (0..n) |row| {
            col_rhs[row] = c_mat[row * n + j];
        }

        dense_lu.solveFactored(n, g_lu, piv, col_rhs, col_sol);

        // Negate into column j of A.
        for (0..n) |row| {
            a_mat[row * n + j] = -col_sol[row];
        }
    }

    const eig = eigenvaluesQR(n, a_mat, eigs, options);

    // λ → s = 1/λ = conj(λ)/|λ|²; drop |λ| ≈ 0 (no dynamics, not poles at origin).
    var max_abs: f64 = 0;
    for (eigs[0..eig.count]) |l| max_abs = @max(max_abs, l.mag());
    const cutoff = 1e-9 * max_abs;

    var n_poles: usize = 0;
    for (eigs[0..eig.count]) |l| {
        if (l.mag() <= cutoff or l.magSq() == 0) continue;
        n_poles += 1;
    }

    const poles = try allocator.alloc(Complex, n_poles);
    var n_stable: u32 = 0;
    var w: usize = 0;
    for (eigs[0..eig.count]) |l| {
        const m2 = l.magSq();
        if (l.mag() <= cutoff or m2 == 0) continue;
        const pole = Complex{ .re = l.re / m2, .im = -l.im / m2 };
        poles[w] = pole;
        w += 1;
        if (pole.re < 0) n_stable += 1;
    }

    return .{
        .poles = poles,
        .n_stable = n_stable,
        .qr_converged = eig.converged,
        .allocator = allocator,
    };
}

/// Contract entry: poles at ctx.x_op, one complex row per pole.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    var res = try solve(ctx.circuit, x_op, opts, a);
    defer res.deinit();

    const n = res.poles.len;
    const names = try a.dupe([]const u8, &.{ "index", "pole" });
    errdefer a.free(names); // entries are literals
    const data = try a.alloc(f64, n * 4);
    for (res.poles, 0..) |pole, i| {
        data[i * 4] = @floatFromInt(i);
        data[i * 4 + 1] = 0;
        data[i * 4 + 2] = pole.re;
        data[i * 4 + 3] = pole.im;
    }
    return .{
        .plotname = "Pole-Zero Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n,
        .data = data,
    };
}

// ============================================================================
// QR eigenvalue computation: Hessenberg reduction + Francis double-shift
// ============================================================================

const Eigs = struct { count: usize, converged: bool };

/// Writes eigenvalues into out (caller provides n slots — the exact upper
/// bound). converged is false if qr_max_iter was exhausted (remaining
/// eigenvalues dropped).
fn eigenvaluesQR(n: usize, a: []f64, out: []Complex, options: Options) Eigs {
    if (n == 0) return .{ .count = 0, .converged = true };

    if (n == 1) {
        out[0] = .{ .re = a[0], .im = 0 };
        return .{ .count = 1, .converged = true };
    }

    hessenbergReduce(n, a);

    var count: usize = 0;
    var nn = n;
    var iter: u32 = 0;

    while (nn > 2) {
        if (iter >= options.qr_max_iter) return .{ .count = count, .converged = false };

        // Check for 1x1 deflation at bottom.
        const sub = @abs(a[(nn - 1) * n + (nn - 2)]);
        const diag_sum = @abs(a[(nn - 1) * n + (nn - 1)]) + @abs(a[(nn - 2) * n + (nn - 2)]);
        if (sub <= options.qr_tol * @max(diag_sum, 1e-30)) {
            out[count] = .{ .re = a[(nn - 1) * n + (nn - 1)], .im = 0 };
            count += 1;
            nn -= 1;
            iter = 0;
            continue;
        }

        // Check for 2x2 deflation at bottom.
        if (nn > 2) {
            const sub2 = @abs(a[(nn - 2) * n + (nn - 3)]);
            const diag_sum2 = @abs(a[(nn - 2) * n + (nn - 2)]) + @abs(a[(nn - 3) * n + (nn - 3)]);
            if (sub2 <= options.qr_tol * @max(diag_sum2, 1e-30)) {
                extract2x2(a, n, nn - 2, out[count..][0..2]);
                count += 2;
                nn -= 2;
                iter = 0;
                continue;
            }
        }

        francisStep(n, a, nn);
        iter += 1;
    }

    // Handle remaining 2x2 or 1x1 block.
    if (nn == 2) {
        extract2x2(a, n, 0, out[count..][0..2]);
        count += 2;
    } else if (nn == 1) {
        out[count] = .{ .re = a[0], .im = 0 };
        count += 1;
    }
    return .{ .count = count, .converged = true };
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

fn hessenbergReduce(n: usize, a: []f64) void {
    if (n <= 2) return;

    for (0..n - 2) |k| {
        const len = n - k - 1;
        if (len == 0) continue;

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

fn francisStep(n: usize, a: []f64, nn: usize) void {
    // Shift polynomial from trailing 2x2 block.
    const am = a[(nn - 2) * n + (nn - 2)];
    const bm = a[(nn - 2) * n + (nn - 1)];
    const cm = a[(nn - 1) * n + (nn - 2)];
    const dm = a[(nn - 1) * n + (nn - 1)];

    const s = am + dm; // trace
    const t = am * dm - bm * cm; // determinant

    // First column of the implicit double-shift polynomial (H - sigma*I)(H - conj(sigma)*I).
    var x = a[0] * a[0] + a[0 * n + 1] * a[1 * n + 0] - s * a[0] + t;
    var y = a[1 * n + 0] * (a[0] + a[1 * n + 1] - s);
    var z: f64 = if (nn > 2) a[2 * n + 0] * a[1 * n + 0] else 0;

    for (0..nn - 1) |k| {
        const nr = @sqrt(x * x + y * y + z * z);
        if (nr < 1e-30) {
            if (k + 1 < nn - 1) {
                x = a[(k + 1) * n + k];
                y = a[(k + 2) * n + k];
                z = if (k + 3 < nn) a[(k + 3) * n + k] else 0;
            }
            continue;
        }

        const p = if (k + 2 < nn) @as(usize, 3) else @as(usize, 2);

        if (p == 3) {
            applyReflector3(n, a, nn, k, x, y, z, nr);
        } else {
            applyReflector2(n, a, nn, k, x, y);
        }

        if (k + 1 < nn - 1) {
            x = a[(k + 1) * n + k];
            y = if (k + 2 < nn) a[(k + 2) * n + k] else 0;
            z = if (k + 3 < nn) a[(k + 3) * n + k] else 0;
        }
    }
}

fn applyReflector3(n: usize, a: []f64, nn: usize, k: usize, x_in: f64, y_in: f64, z_in: f64, nr: f64) void {
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
    const col_start = if (k > 0) k - 1 else 0;
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

fn applyReflector2(n: usize, a: []f64, nn: usize, k: usize, x_in: f64, y_in: f64) void {
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

    const col_start = if (k > 0) k - 1 else 0;
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "eigenvaluesQR: 2x2 real eigenvalues" {
    var a = [_]f64{ 3, 1, 0, 2 };
    var eigs: [2]Complex = undefined;

    const r = eigenvaluesQR(2, &a, &eigs, .{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 2), r.count);

    std.mem.sort(Complex, eigs[0..r.count], {}, struct {
        fn cmp(_: void, lhs: Complex, rhs: Complex) bool {
            return lhs.re > rhs.re;
        }
    }.cmp);

    try testing.expectApproxEqAbs(@as(f64, 3.0), eigs[0].re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), eigs[0].im, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 2.0), eigs[1].re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), eigs[1].im, 1e-10);
}

test "eigenvaluesQR: 2x2 complex conjugate pair" {
    var a = [_]f64{ 0, -1, 1, 0 };
    var eigs: [2]Complex = undefined;

    const r = eigenvaluesQR(2, &a, &eigs, .{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 2), r.count);

    std.mem.sort(Complex, eigs[0..r.count], {}, struct {
        fn cmp(_: void, lhs: Complex, rhs: Complex) bool {
            return lhs.im > rhs.im;
        }
    }.cmp);

    try testing.expectApproxEqAbs(@as(f64, 0.0), eigs[0].re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), eigs[0].im, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), eigs[1].re, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -1.0), eigs[1].im, 1e-10);
}

test "eigenvaluesQR: 3x3 with known eigenvalues" {
    var a = [_]f64{
        -1, 0,  0,
        0,  -2, 0,
        0,  0,  -3,
    };
    var eigs: [3]Complex = undefined;

    const r = eigenvaluesQR(3, &a, &eigs, .{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 3), r.count);

    std.mem.sort(Complex, eigs[0..r.count], {}, struct {
        fn cmp(_: void, lhs: Complex, rhs: Complex) bool {
            return lhs.re > rhs.re;
        }
    }.cmp);

    try testing.expectApproxEqAbs(@as(f64, -1.0), eigs[0].re, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, -2.0), eigs[1].re, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, -3.0), eigs[2].re, 1e-8);
    for (eigs[0..r.count]) |p| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), p.im, 1e-8);
    }
}

test "eigenvaluesQR: 4x4 with mixed real and complex eigenvalues" {
    var a = [_]f64{
        -1, -2, 0,  0,
        2,  -1, 0,  0,
        0,  0,  -3, 0,
        0,  0,  0,  -4,
    };
    var eigs: [4]Complex = undefined;

    const r = eigenvaluesQR(4, &a, &eigs, .{});
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 4), r.count);

    std.mem.sort(Complex, eigs[0..r.count], {}, struct {
        fn cmp(_: void, lhs: Complex, rhs: Complex) bool {
            const l_abs_im = @abs(lhs.im);
            const r_abs_im = @abs(rhs.im);
            if (l_abs_im < 0.5 and r_abs_im < 0.5) return lhs.re > rhs.re;
            if (l_abs_im < 0.5) return true;
            if (r_abs_im < 0.5) return false;
            return lhs.im > rhs.im;
        }
    }.cmp);

    try testing.expectApproxEqAbs(@as(f64, -3.0), eigs[0].re, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, -4.0), eigs[1].re, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, -1.0), eigs[2].re, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 2.0), eigs[2].im, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, -1.0), eigs[3].re, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, -2.0), eigs[3].im, 1e-8);
}

test "hessenbergReduce: preserves eigenvalues" {
    var h = [_]f64{
        2, 1, 1,
        1, 3, 1,
        1, 1, 4,
    };

    hessenbergReduce(3, &h);

    try testing.expectApproxEqAbs(@as(f64, 0.0), h[2 * 3 + 0], 1e-12);

    const trace_orig: f64 = 2.0 + 3.0 + 4.0;
    const trace_h = h[0] + h[4] + h[8];
    try testing.expectApproxEqAbs(trace_orig, trace_h, 1e-10);
}
