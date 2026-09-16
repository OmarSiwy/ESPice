const impl = @import("../Circuit.zig");
const combinePlanes = impl.combinePlanes;
const std = @import("std");

test "combined circuit planes match W=1 with tails and aliased output" {
    const W = std.simd.suggestVectorLength(f64) orelse 1;
    var random = std.Random.DefaultPrng.init(0x4321);
    var g: [3 * W + 1]f64 = undefined;
    var c: [g.len]f64 = undefined;
    var actual: [g.len]f64 = undefined;
    var expected: [g.len]f64 = undefined;
    for (0..g.len + 1) |n| {
        for (&g, &c) |*gv, *cv| {
            gv.* = random.random().float(f64) - 0.5;
            cv.* = random.random().float(f64) - 0.5;
        }
        for ([_]f64{ 0, -1, 0.125, 1e12 }) |alpha| {
            combinePlanes(1, expected[0..n], g[0..n], c[0..n], alpha);
            combinePlanes(W, actual[0..n], g[0..n], c[0..n], alpha);
            try std.testing.expectEqualSlices(f64, expected[0..n], actual[0..n]);
            @memcpy(actual[0..n], g[0..n]);
            combinePlanes(W, actual[0..n], actual[0..n], c[0..n], alpha);
            try std.testing.expectEqualSlices(f64, expected[0..n], actual[0..n]);
        }
    }
}
