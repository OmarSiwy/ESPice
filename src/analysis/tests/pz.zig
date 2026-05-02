//! QR eigenvalue unit tests behind the pole-zero analysis.

const qr = @import("../eigen/qr.zig");
const Complex = @import("core").numerics.Complex;
const eigenvalues = qr.eigenvalues;
const hessenbergReduce = qr.hessenbergReduce;
const std = @import("std");
const testing = std.testing;

test "eigenvaluesQR: 2x2 real eigenvalues" {
    var a = [_]f64{ 3, 1, 0, 2 };
    var eigs: [2]Complex = undefined;

    const r = eigenvalues(2, &a, &eigs, 1e-12, 1000);
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

    const r = eigenvalues(2, &a, &eigs, 1e-12, 1000);
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

    const r = eigenvalues(3, &a, &eigs, 1e-12, 1000);
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

    const r = eigenvalues(4, &a, &eigs, 1e-12, 1000);
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

test "eigenvaluesQR: triangular gm chain is exact (bench_pz_pz2)" {
    // A = −G⁻¹C of four R‖L stages chained by unit transconductances: lower
    // bidiagonal, 1e9 off the diagonal. The Francis QR alone returns a
    // complex pair here; isolating the triangular rows is exact.
    var a = [_]f64{
        -0.98, 0,    0,     0,
        1e9,   -1.2, 0,     0,
        0,     -1e9, -11.6, 0,
        0,     0,    1e9,   -94.3,
    };
    var eigs: [4]Complex = undefined;
    const r = eigenvalues(4, &a, &eigs, 1e-12, 1000);
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 4), r.count);
    std.mem.sort(Complex, &eigs, {}, struct {
        fn cmp(_: void, lhs: Complex, rhs: Complex) bool {
            return lhs.re > rhs.re;
        }
    }.cmp);
    for (eigs, [_]f64{ -0.98, -1.2, -11.6, -94.3 }) |e, want| {
        try testing.expectEqual(want, e.re);
        try testing.expectEqual(@as(f64, 0), e.im);
    }
}

test "eigenvaluesQR: defective zero eigenvalue converges" {
    // S·J·S⁻¹ with J = diag(−1, 3×3 nilpotent Jordan block), rounded: the
    // shape of a pencil's roots at infinity. A bulge whose first column drops
    // the h21·h10 term never deflates this.
    var a = [_]f64{
        -1.887447539107211,  -0.8840137352155666, -2.756199923693247,  4.062190003815338,
        -1.0244181610072491, -1.2590614269362839, -0.6596718809614651, 2.4170164059519266,
        -1.2396032048836323, -1.1045402518122853, -2.410530331934376,  3.7794734834032813,
        -1.5667956614160352, -1.3414727203357497, -2.859214040442579,  4.557039297977871,
    };
    var eigs: [4]Complex = undefined;
    const r = eigenvalues(4, &a, &eigs, 1e-12, 1000);
    try testing.expect(r.converged);
    try testing.expectEqual(@as(usize, 4), r.count);
    var near_zero: usize = 0;
    for (eigs) |e| {
        if (e.mag() < 1e-4) near_zero += 1 else try testing.expectApproxEqAbs(@as(f64, -1), e.re, 1e-12);
    }
    try testing.expectEqual(@as(usize, 3), near_zero);
}
