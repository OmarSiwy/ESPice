//! Fuzz, boundary and allocation-failure tests for vec.zig's `expand`.
//! The oracle: no panic, no leak, `InvalidVector` or `OutOfMemory` only,
//! and on success one `vvec_` source or `.dout` card per line.
const std = @import("std");
const vec = @import("../vec.zig");
const Smith = std.testing.Smith;
const Seeded = @import("seeded.zig").Seeded;

fn check(gpa: std.mem.Allocator, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const text = vec.expand(arena.allocator(), src) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidVector => return,
    };
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "vvec_") or std.mem.startsWith(u8, line, ".dout "));
    }
}

const statements = [_][]const u8{
    "radix 1 1 2", "radix 4",    "radix 1",  "radix 21",  "vname a b q[[1:0]]",    "vname d[3:0]", "vname vb<[1:0]> c{[[3:3]]}",
    "vname a",     "io i i o",   "io i",     "io iuo",    "io b",                  "tunit ns",     "tunit 2 ps",
    "tunit hours", "period 10",  "tskip",    "slope 0.5", "trise 1 1",             "tfall 0.2",    "vih 5 1 0 0",
    "vil 0",       "voh 3",      "vol 0.5",  "vth 2.5",   "vref gnd",              "out 0",        "triz 1",
    "tdelay 1",    "idelay 2 f", "odelay 1", "enable 1",  "+ 1",                   "; comment",    "",
    "10 1 0 x",    "20 0 1 2",   "a",        "5",         "30 1 1 f",              "10 z",         "1 2 0",
    "0 0 0 0",     "5 000",      "7 11z",    "40 u u 3",  "vname a[2147483647:0]",
};

fn file(src: anytype, w: *std.Io.Writer) void {
    while (!src.eosWeightedSimple(9, 1)) w.print("{s}\n", .{statements[src.index(statements.len)]}) catch return;
}

fn fuzzFile(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 12]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    file(s, &w);
    try check(std.testing.allocator, w.buffered());
}

test "fuzz vec.expand: files built from statements" {
    std.testing.log_level = .err;
    try std.testing.fuzz({}, fuzzFile, .{});
}

fn fuzzRaw(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 12]u8 = undefined;
    try check(std.testing.allocator, buf[0..s.slice(&buf)]);
}

test "fuzz vec.expand: raw bytes" {
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = &.{"radix 1 1\nvname a b\nio i o\n10 1 0\n20 0 1\n"} });
}

test "vec: 20000 seeded files expand or fail with InvalidVector" {
    var prng: std.Random.DefaultPrng = .init(0x7ec0_0001);
    var src: Seeded = .{ .r = prng.random() };
    var buf: [1 << 12]u8 = undefined;
    for (0..20000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        // RADIX first most of the time, so rows get read.
        w.writeAll(if (src.eosWeightedSimple(1, 3)) "radix 1 1 2\n" else "") catch {};
        file(&src, &w);
        try check(std.testing.allocator, w.buffered());
    }
}

test "vec: a PWL source holds at most 64 points" {
    // One bit flipping every row: the first row is the start level, each
    // flip after it adds two points to the one at t = 0. 31 flips are 63
    // points, 32 are 65.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { usize, bool }{ .{ 32, true }, .{ 33, false } }) |case| {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "radix 1\nvname a\nperiod 10\n");
        for (0..case[0]) |r| try src.appendSlice(a, if (r % 2 == 0) "0\n" else "1\n");
        const got = vec.expand(a, src.items);
        if (case[1]) {
            const text = try got;
            // 1 + 2·31 = 63 numbers after `pwl(0` pairs: count the blanks.
            try std.testing.expectEqual(2 * 63 - 1, std.mem.count(u8, text[std.mem.indexOf(u8, text, "pwl(").?..], " "));
        } else try std.testing.expectError(error.InvalidVector, got);
    }
}

fn expandAll(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try vec.expand(arena.allocator(), "radix 1 1 2\nvname a b q[[1:0]]\nio i i o\ntunit ns\nslope 0.5\nvih 5 1 0 0\nvth 2.5\n10 1 0 x\n20 0 1 2\n");
}

test "vec: expand fails cleanly at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, expandAll, .{});
}
