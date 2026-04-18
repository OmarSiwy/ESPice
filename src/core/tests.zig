const std = @import("std");
const numerics = @import("numerics.zig");
const zeroSimd = numerics.zeroSimd;
const copySimd = numerics.copySimd;

test "bulk buffers preserve bits, common prefixes and exact aliases" {
    const src = [_]f64{ -0.0, @bitCast(@as(u64, 0x7ff8000000000042)), 3 };
    var dst = [_]f64{ 7, 7, 7, 7 };
    copySimd(&dst, &src);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&src), std.mem.sliceAsBytes(dst[0..3]));
    try std.testing.expectEqual(@as(f64, 7), dst[3]);
    copySimd(dst[0..2], &src);
    copySimd(&dst, &dst);
    copySimd(dst[0..0], &src);
    zeroSimd(&dst);
    try std.testing.expectEqualSlices(u64, &.{ 0, 0, 0, 0 }, @as([]const u64, @ptrCast(&dst)));
}

const testing = std.testing;

test "bulk zeroing covers full vectors and the tail without overwriting adjacent storage" {
    var values: [67]f64 = @splat(-1);
    zeroSimd(values[1..66]);
    try testing.expectEqual(@as(f64, -1), values[0]);
    try testing.expectEqual(@as(f64, -1), values[66]);
    for (values[1..66]) |value| try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(value)));
}

test "frequency grids retain both endpoints and support a single frequency" {
    const grid: numerics.FreqSweep = .{ .f_start = 10, .f_stop = 1000, .points = 2 };
    var sweep = grid.iter();
    const expected = [_]f64{ 10, @sqrt(1000.0), 100, @sqrt(100000.0), 1000 };
    try testing.expectEqual(expected.len, sweep.n);
    for (expected) |frequency| try testing.expectApproxEqRel(frequency, sweep.next().?, 1e-12);
    try testing.expect(sweep.next() == null);
    const point: numerics.FreqSweep = .{ .f_start = 7, .f_stop = 7, .points = 10 };
    var single = point.iter();
    try testing.expectApproxEqRel(@as(f64, 7), single.next().?, 1e-12);
    try testing.expect(single.next() == null);
}
