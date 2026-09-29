//! Variant planning: `.alter` splitting, the live-value fast path against
//! its rebuild oracle, and Monte Carlo draws.
const std = @import("std");
const t = std.testing;
const input = @import("../prepare.zig");
const variants = @import("../variants.zig");
const netlist = @import("netlist");
const device = @import("device");

test ".alter blocks are cumulative and replace cards by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const runs = try netlist.source.splitAlters(arena.allocator(),
        \\title
        \\.lib 'm.lib' tt
        \\r1 a b 1k
        \\+ tc1=0
        \\.subckt s x
        \\r1 x 0 5
        \\.ends
        \\.op
        \\.alter
        \\r1 a b 2k
        \\.lib 'm.lib' ff
        \\.alter
        \\.subckt s x
        \\r9 x 0 7
        \\.ends
        \\.del lib 'm.lib' ff
        \\.end
    );
    try t.expectEqual(@as(usize, 3), runs.len);
    try t.expect(std.mem.indexOf(u8, runs[0], ".alter") == null);
    try t.expectEqualStrings("title\n.lib 'm.lib' ff\nr1 a b 2k\n.subckt s x\nr1 x 0 5\n.ends\n.op\n.end\n", runs[1]);
    // Run 2 keeps run 1's r1 and swaps the subcircuit body.
    try t.expectEqualStrings("title\nr1 a b 2k\n.subckt s x\nr9 x 0 7\n.ends\n.op\n.end\n", runs[2]);
    const plain = try netlist.source.splitAlters(arena.allocator(), "t\nr1 a 0 1\n.end\n");
    try t.expectEqual(@as(usize, 1), plain.len);
}

/// Plans `src` twice: as `build` does (fast path when the probe allows)
/// and with every point rebuilt. The rows must agree bit for bit.
fn expectFastMatchesRebuild(src: []const u8, fast_expected: bool) !void {
    var sa = std.heap.ArenaAllocator.init(t.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(t.allocator);
    defer pa.deinit();
    var lib = try device.Library.init(t.allocator);
    defer lib.deinit();
    const nl = try netlist.parse(pa.allocator(), src, .ngspice);
    var prepared = try input.build(&lib, sa.allocator(), pa.allocator(), nl);
    defer prepared.deinit();
    var planner = try variants.Planner.init(&lib, sa.allocator(), pa.allocator(), &nl, &prepared.circuit, prepared.deck.cards, "");
    planner.force_rebuild = true;
    const oracle = try variants.plan(&planner);
    const got = prepared.deck.variants;
    try t.expectEqual(oracle.variants.count(), got.count());
    for (0..got.count()) |v| {
        const refs, const values = got.writes(@intCast(v));
        const want_refs, const want_values = oracle.variants.writes(@intCast(v));
        try t.expectEqualSlices(u32, want_refs, refs);
        try t.expectEqualSlices(u64, @ptrCast(want_values), @ptrCast(values));
    }
    // The fresh planner in `build` probed; re-probe to see what it chose.
    var probe = try variants.Planner.init(&lib, sa.allocator(), pa.allocator(), &nl, &prepared.circuit, prepared.deck.cards, "");
    _ = try variants.plan(&probe);
    try t.expectEqual(fast_expected, probe.fast == .identity);
}

test "the live-value fast path writes what a rebuild would" {
    try expectFastMatchesRebuild(
        \\fast path
        \\.param rv=1k cv=1n vs=2 isat=1e-14
        \\.subckt load a k=1
        \\r1 a 0 '2k*k'
        \\.ends
        \\v1 in 0 vs
        \\r1 in a {rv}
        \\c1 a 0 {cv}
        \\d1 a 0 dm
        \\x1 a load k='rv/1k'
        \\.model dm d is=isat
        \\.step param rv list 1k 3k
        \\.step param isat list 1e-14 2e-14
        \\.step param vs list 1 2
        \\.op
        \\.end
    , true);
    // A slot at zero cannot be probed: every point rebuilds.
    try expectFastMatchesRebuild(
        \\rebuild path
        \\.param g=0
        \\v1 in 0 1
        \\r1 in 0 1k
        \\d1 in 0 dm
        \\.model dm d rs=g
        \\.step param g list 0 5
        \\.op
        \\.end
    , false);
}

test "Monte Carlo draws depend only on seed, trial and site; LHS strata cover each trial once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var srs = try variants.Sampler.init(arena.allocator(), &.{}, 8);
    const a = srs.uniform(42, 3, 2);
    try t.expectEqual(a, srs.uniform(42, 3, 2));
    try t.expect(a != srs.uniform(43, 3, 2) and a != srs.uniform(42, 4, 3));
    var lhs = srs;
    lhs.lhs = true;
    var seen: [8]bool = @splat(false);
    for (0..8) |k| {
        const u = lhs.uniform(99, @intCast(k + 1), @intCast(k));
        try t.expect(u > 0 and u < 1);
        const stratum: usize = @intFromFloat(@floor(u * 8));
        try t.expect(!seen[stratum]);
        seen[stratum] = true;
    }
}
