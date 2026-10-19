//! Tests for source.zig's `.alter` split: hand-derived runs, a fuzz and a
//! seeded generator (no panic, no leak, `InvalidAlter` or `OutOfMemory`
//! only; the first run is a prefix of the deck and every later one a full
//! deck), and allocation failure.
const std = @import("std");
const source = @import("../source.zig");
const Smith = std.testing.Smith;
const Seeded = @import("seeded.zig").Seeded;

fn check(gpa: std.mem.Allocator, src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const runs = source.splitAlters(arena.allocator(), src) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidAlter => return,
    };
    try std.testing.expect(runs.len >= 1);
    try std.testing.expect(std.mem.startsWith(u8, src, runs[0]));
    for (runs[1..]) |r| try std.testing.expect(std.mem.endsWith(u8, r, ".end\n"));
}

test "splitAlters: each block applies to the deck the blocks before it left" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Block 1 replaces r1 and adds c1; block 2 replaces the model and
    // deletes the .lib card; both carry the title and `.end`.
    const runs = try source.splitAlters(a,
        \\t
        \\r1 a 0 1
        \\.model m d is=1
        \\.lib 'f.lib' tt
        \\.alter
        \\R1 a 0 2
        \\c1 a 0 1p
        \\.alter
        \\.model M d is=2
        \\.del lib 'f.lib' tt
        \\.end
        \\
    );
    try std.testing.expectEqual(3, runs.len);
    try std.testing.expectEqualStrings("t\nr1 a 0 1\n.model m d is=1\n.lib 'f.lib' tt\n", runs[0]);
    try std.testing.expectEqualStrings("t\nR1 a 0 2\n.model m d is=1\n.lib 'f.lib' tt\nc1 a 0 1p\n.end\n", runs[1]);
    try std.testing.expectEqualStrings("t\nR1 a 0 2\n.model M d is=2\nc1 a 0 1p\n.end\n", runs[2]);
    // A subcircuit is replaced whole, continuation lines ride with their card.
    const sub = try source.splitAlters(a, "t\n.subckt s a\nr1 a 0 1\n.ends\nv1 a 0 1\n+ ac 1\n.alter\n.subckt s a\nr2 a 0 5\n.ends\n");
    try std.testing.expectEqualStrings("t\n.subckt s a\nr2 a 0 5\n.ends\nv1 a 0 1\n+ ac 1\n.end\n", sub[1]);
    // A deck without `.alter` is borrowed whole.
    const plain = "t\nr1 a 0 1\n.end\n";
    try std.testing.expectEqual(plain.ptr, (try source.splitAlters(a, plain))[0].ptr);
    for ([_][]const u8{ "t\n.alter\n.del lib 'g.lib' tt\n", "t\n.alter\n.model\n", "t\n.alter\n.del x\n", "t\n.alter\n.subckt\n" }) |bad|
        try std.testing.expectError(error.InvalidAlter, source.splitAlters(a, bad));
}

const cards = [_][]const u8{
    "r1 a 0 1",   "R1 a 0 2",    "c1 a 0 1p",         ".model m d is=1", ".model M d is=2", ".lib 'f.lib' tt", ".del lib 'f.lib' tt",
    ".del lib x", ".subckt s a", ".ends",             ".ends s",         ".param p=1",      "+ ac 1",          "* comment",
    "",           ".alter",      ".alter second run", ".end",            ".model",          ".del",            "x1 a s",
    "  ",         "\t.ALTER",    ".subckt",           "+",               ".lib",            "v1 a 0 1",        "\r",
};

fn deck(src: anytype, w: *std.Io.Writer) void {
    w.writeAll("title\n") catch return;
    while (!src.eosWeightedSimple(11, 1)) w.print("{s}\n", .{cards[src.index(cards.len)]}) catch return;
}

fn fuzzDeck(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 12]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    deck(s, &w);
    try check(std.testing.allocator, w.buffered());
}

test "fuzz splitAlters: decks built from cards" {
    try std.testing.fuzz({}, fuzzDeck, .{});
}

fn fuzzRaw(_: void, s: *Smith) anyerror!void {
    var buf: [1 << 12]u8 = undefined;
    try check(std.testing.allocator, buf[0..s.slice(&buf)]);
}

test "fuzz splitAlters: raw bytes" {
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = &.{"t\nr1 a 0 1\n.alter\nr1 a 0 2\n.end\n"} });
}

test "splitAlters: 20000 seeded decks split or fail with InvalidAlter" {
    var prng: std.Random.DefaultPrng = .init(0x50ce_0001);
    var src: Seeded = .{ .r = prng.random() };
    var buf: [1 << 12]u8 = undefined;
    for (0..20000) |_| {
        var w: std.Io.Writer = .fixed(&buf);
        deck(&src, &w);
        try check(std.testing.allocator, w.buffered());
    }
}

fn splitAll(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try source.splitAlters(arena.allocator(), "t\nr1 a 0 1\n.lib 'f' tt\n.alter\nr1 a 0 2\n.del lib 'f' tt\n.alter\n.subckt s a\n.ends\n.end\n");
}

test "splitAlters fails cleanly at every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, splitAll, .{});
}
