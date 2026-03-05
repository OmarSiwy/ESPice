const impl = @import("../Circuit.zig");
const combinePlanes = impl.combinePlanes;
const std = @import("std");

test "pattern CSC matches comparison sort across radix digits" {
    const PatternBuilder = @import("device_ir").PatternBuilder;
    const gpa = std.testing.allocator;
    var random = std.Random.DefaultPrng.init(0x5041545445524e);
    for ([_]u32{ 1, 31, 65537, 131073 }) |n| {
        for ([_]usize{ 0, 1, 63, 64, 65, 257 }) |count| {
            var pattern: PatternBuilder = .{};
            defer pattern.deinit(gpa);
            var unique = std.AutoHashMap(u64, void).init(gpa);
            defer unique.deinit();
            var previous: u64 = 0;
            for (0..count) |i| {
                const row = if (i % 7 == 0) n - 1 else random.random().intRangeLessThan(u32, 0, n);
                const occupied_columns = [_]u32{ n - 1, 0, n / 2 };
                const col = occupied_columns[i % occupied_columns.len];
                const key = if (i % 4 == 1) previous else (@as(u64, col) << 32) | row;
                try pattern.add(gpa, @truncate(key), @intCast(key >> 32));
                try unique.put(key, {});
                previous = key;
            }
            const expected = try gpa.alloc(u64, unique.count());
            defer gpa.free(expected);
            var keys = unique.keyIterator();
            for (expected) |*key| key.* = keys.next().?.*;
            std.mem.sortUnstable(u64, expected, {}, std.sort.asc(u64));

            var col_ptr: []u32 = undefined;
            var row_idx: []u32 = undefined;
            const nnz = try pattern.toCsc(gpa, gpa, n, &col_ptr, &row_idx);
            defer gpa.free(col_ptr);
            defer gpa.free(row_idx);
            try std.testing.expectEqual(@as(u32, @intCast(expected.len)), nnz);
            try std.testing.expectEqual(expected.len, row_idx.len);
            try std.testing.expectEqual(@as(usize, n) + 1, col_ptr.len);
            try std.testing.expectEqual(@as(u32, 0), col_ptr[0]);
            var p: usize = 0;
            for (0..n) |col| {
                while (p < expected.len and expected[p] >> 32 == col) : (p += 1) {
                    try std.testing.expectEqual(@as(u32, @truncate(expected[p])), row_idx[p]);
                }
                try std.testing.expectEqual(@as(u32, @intCast(p)), col_ptr[col + 1]);
            }
            try std.testing.expectEqual(expected.len, p);
        }
    }
}

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
