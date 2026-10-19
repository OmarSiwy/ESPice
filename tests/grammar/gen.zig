//! A grammar's rows + a seed -> sentences of one rule, and byte mutations of
//! a sentence: the generator half of the grammar oracle (dev/frontend.md,
//! "Grammar oracle"). A derivation walks the rule's nodes choosing at random
//! (Purdom-style sentence generation) until a depth or length budget, past
//! which it takes the shortest derivation. PEG lookaheads (`&e`, `!e`) and
//! ordered choice are not generative, so a derived string is only a
//! candidate: `sentence` keeps the first one the grammar itself parses.
//! Seeded and serial, so a seed names the same inputs on every machine.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const peg = @import("peg.zig");

/// Bytes a class or `.` draws from first: the ones the card and line
/// grammars branch on. A class holding none of them draws from its own set.
const palette = "abcdefgiklmnoprstuvwxyz0123456789 _.,=+-*/()'\"{}[]$;!<>?:&|%^\\\t@#";

/// A derivation with no budget left takes its node's shortest path; `inf`
/// marks a node no finite derivation reaches.
const inf = std.math.maxInt(u16);

/// A grammar, its per-node shortest-derivation heights and a seeded source.
pub const Gen = struct {
    g: peg.Grammar,
    /// Per grammar node, the fewest rule expansions that derive it.
    height: []const u16,
    rng: std.Random,
    /// Rule expansions past which every choice takes its shortest alternative.
    depth_max: u16,
    /// Output bytes past which the same holds: it caps a derivation's size.
    len_max: u32,

    /// Asserts every rule has a finite derivation: an `inf` rule is a
    /// grammar that cannot end, a programmer error in a checked-in `.peg`.
    pub fn init(arena: Allocator, g: peg.Grammar, rng: std.Random, depth_max: u16, len_max: u32) Allocator.Error!Gen {
        assert(depth_max > 0);
        assert(len_max > 0);
        const h = try arena.alloc(u16, g.nodes.len);
        @memset(h, inf);
        // Fixpoint: each pass can only lower a height, and a height is at
        // most the rule count, so `nodes.len` passes bound it.
        var passes: usize = 0;
        while (true) : (passes += 1) {
            assert(passes <= g.nodes.len);
            var changed = false;
            for (g.nodes, h) |node, *hn| {
                const new: u16 = switch (node.tag) {
                    .seq => blk: {
                        var m: u16 = 0;
                        for (g.kids[node.a..][0..node.b]) |k| m = @max(m, h[k]);
                        break :blk m;
                    },
                    .choice => blk: {
                        var m: u16 = inf;
                        for (g.kids[node.a..][0..node.b]) |k| m = @min(m, h[k]);
                        break :blk m;
                    },
                    .plus => h[node.a],
                    .star, .opt, .@"and", .not, .lit, .lit_i, .class, .any => 0,
                    .ref => blk: {
                        const body = h[g.rule_bodies[node.a]];
                        break :blk if (body == inf) inf else body + 1;
                    },
                };
                if (new < hn.*) {
                    hn.* = new;
                    changed = true;
                }
            }
            if (!changed) break;
        }
        for (g.rule_bodies) |b| assert(h[b] != inf);
        return .{ .g = g, .height = h, .rng = rng, .depth_max = depth_max, .len_max = len_max };
    }

    /// A string rule `r` parses as a whole, from up to `tries` derivations;
    /// null when none parsed. The string and the trial parses use `arena`.
    pub fn sentence(gen: *Gen, arena: Allocator, r: peg.RuleId, tries: u32) Allocator.Error!?[]const u8 {
        assert(tries > 0);
        for (0..tries) |_| {
            var out: std.ArrayList(u8) = .empty;
            try gen.derive(arena, &out, gen.g.rule_bodies[r], 0);
            var d: peg.Diag = .{};
            _ = peg.parse(arena, gen.g, r, out.items, &d) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NoMatch, error.DepthExceeded => continue,
            };
            return out.items;
        }
        return null;
    }

    fn derive(gen: *Gen, arena: Allocator, out: *std.ArrayList(u8), n: u32, depth: u16) Allocator.Error!void {
        const g = gen.g;
        const node = g.nodes[n];
        const spent = depth >= gen.depth_max or out.items.len >= gen.len_max;
        switch (node.tag) {
            .seq => for (g.kids[node.a..][0..node.b]) |k| try gen.derive(arena, out, k, depth),
            .choice => {
                const kids = g.kids[node.a..][0..node.b];
                // Spent: a random one of the shortest alternatives, whose
                // height is the choice's own, so each `ref` taken lowers it
                // and the walk ends. Else any alternative that can end.
                var pick: u32 = undefined;
                var seen: u32 = 0;
                for (kids) |k| {
                    const ok = if (spent) gen.height[k] == gen.height[n] else gen.height[k] != inf;
                    if (!ok) continue;
                    seen += 1;
                    if (gen.rng.uintLessThan(u32, seen) == 0) pick = k;
                }
                assert(seen > 0);
                try gen.derive(arena, out, pick, depth);
            },
            .star, .plus, .opt => {
                const lo: u32 = @intFromBool(node.tag == .plus);
                const hi: u32 = if (spent) lo else if (node.tag == .opt) 1 else lo + 2;
                const reps = gen.rng.intRangeAtMost(u32, lo, hi);
                for (0..reps) |_| try gen.derive(arena, out, node.a, depth);
            },
            // Not generative; the parse in `sentence` judges the result.
            .@"and", .not => {},
            .lit => try out.appendSlice(arena, g.bytes[node.a..][0..node.b]),
            .lit_i => for (g.bytes[node.a..][0..node.b]) |c| {
                try out.append(arena, if (gen.rng.boolean()) std.ascii.toUpper(c) else c);
            },
            .class => try out.append(arena, gen.byteOf(g.classes[node.a])),
            .any => try out.append(arena, palette[gen.below(palette.len)]),
            .ref => {
                assert(gen.height[n] != inf);
                try gen.derive(arena, out, g.rule_bodies[node.a], depth + 1);
            },
        }
    }

    /// A byte of `set`: a palette byte when the set holds any, else any member.
    fn byteOf(gen: *Gen, set: std.StaticBitSet(256)) u8 {
        assert(set.count() > 0);
        var in_palette: u32 = 0;
        for (palette) |c| in_palette += @intFromBool(set.isSet(c));
        if (in_palette > 0) {
            var k = gen.rng.uintLessThan(u32, in_palette);
            for (palette) |c| if (set.isSet(c)) {
                if (k == 0) return c;
                k -= 1;
            };
            unreachable;
        }
        var k = gen.below(set.count());
        var it = set.iterator(.{});
        while (it.next()) |c| {
            if (k == 0) return @intCast(c);
            k -= 1;
        }
        unreachable;
    }

    /// `src` with one random edit: a byte deleted, inserted, doubled or
    /// swapped with its neighbour, or a span cut. The edit may leave the
    /// string inside the grammar; the caller's oracle says.
    /// A draw in `0..n` as a u64, so a 32-bit build generates the same decks.
    fn below(gen: *Gen, n: usize) usize {
        return @intCast(gen.rng.uintLessThan(u64, n));
    }

    pub fn mutate(gen: *Gen, arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, src);
        const at = gen.below(src.len + 1);
        const byte = palette[gen.below(palette.len)];
        switch (gen.rng.uintLessThan(u8, if (src.len == 0) 1 else 5)) {
            0 => try out.insert(arena, at, byte),
            1 => _ = out.orderedRemove(@min(at, src.len - 1)),
            2 => try out.insert(arena, @min(at, src.len - 1), src[@min(at, src.len - 1)]),
            3 => if (at + 1 < src.len) std.mem.swap(u8, &out.items[at], &out.items[at + 1]),
            4 => {
                const end = @min(src.len, at + 1 + gen.below(8));
                try out.replaceRange(arena, at, end - at, "");
            },
            else => unreachable,
        }
        assert(out.items.len + 8 >= src.len);
        return out.items;
    }
};

const testing = std.testing;

test "a derivation the grammar parses, every alternative reached, deterministic per seed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: peg.Diag = .{};
    const text =
        \\Sum   <- Prod (ws [+\-] ws Prod)*
        \\Prod  <- Atom (ws '*' ws Atom)*
        \\Atom  <- Num / 'pi'i / '(' ws Sum ws ')'
        \\Num   <- [0-9]+ !'x'
        \\ws    <- [ \t]*
    ;
    const g = try peg.compile(a, text, &d);
    var p1: std.Random.DefaultPrng = .init(7);
    var gen = try Gen.init(a, g, p1.random(), 6, 200);
    var first: std.ArrayList([]const u8) = .empty;
    for (0..200) |_| {
        const s = (try gen.sentence(a, g.rule("Sum"), 4)).?;
        try first.append(a, s);
        _ = try gen.mutate(a, s);
    }
    try testing.expectEqual(@as(usize, 0), (try peg.gaps(a, g)).len);
    // The same seed, a fresh grammar: the same strings.
    const g2 = try peg.compile(a, text, &d);
    var p2: std.Random.DefaultPrng = .init(7);
    var gen2 = try Gen.init(a, g2, p2.random(), 6, 200);
    for (first.items) |want| {
        const got = (try gen2.sentence(a, g2.rule("Sum"), 4)).?;
        try testing.expectEqualStrings(want, got);
        _ = try gen2.mutate(a, got);
    }
}
