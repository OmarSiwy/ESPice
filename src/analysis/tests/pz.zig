const impl = @import("../eigen/pz.zig");
const Complex = impl.test_access.Complex;
const eigenvaluesQR = impl.test_access.eigenvaluesQR;
const hessenbergReduce = impl.test_access.hessenbergReduce;
const std = @import("std");

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
