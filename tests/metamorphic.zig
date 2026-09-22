//! A linear ngspice deck's text -> rewritten decks whose results must not
//! change: nodes renamed, elements reordered, a resistor split in two, every
//! impedance scaled by k, a 0 A current source added. The relation each
//! rewrite keeps (a column renamed, currents scaled by 1/k) travels with it,
//! and `tests/test_correctness.zig --metamorphic` simulates both decks and
//! compares. Only decks of plain R, C, L cards with numeric values, V, I and
//! D cards, linear E, F, G, H cards and `.op`/`.dc`/`.ac`/`.tran` qualify: a rewrite must be exact by
//! construction, so anything it cannot rewrite exactly is out of scope.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The rewrites, each a relation the results must keep.
pub const Kind = enum { rename, reorder, split, scale, zero_source };

/// Impedance factor of `scale`: R and L times k, C over k, so every node
/// voltage stays and every current divides by k.
pub const k: f64 = 10.0;

/// A rewritten deck and how its columns relate to the original's.
pub const Variant = struct {
    kind: Kind,
    text: []const u8,
    /// `rename`: the original node name -> its new name, both lowercase.
    names: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// What multiplies a variant current to give the original's.
    current_factor: f64 = 1,

    /// The variant's column for original column `name`: `v(a)` and
    /// `v(a,b)` follow the rename, every other column keeps its name.
    pub fn column(v: Variant, a: Allocator, name: []const u8) Allocator.Error![]const u8 {
        if (v.names.count() == 0) return name;
        if (name.len < 4 or !std.ascii.startsWithIgnoreCase(name, "v(") or name[name.len - 1] != ')') return name;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "v(");
        var parts = std.mem.splitScalar(u8, name[2 .. name.len - 1], ',');
        var first = true;
        while (parts.next()) |p| {
            if (!first) try out.append(a, ',');
            first = false;
            const low = try std.ascii.allocLowerString(a, std.mem.trim(u8, p, " "));
            try out.appendSlice(a, v.names.get(low) orelse low);
        }
        try out.append(a, ')');
        return out.items;
    }
};

/// One card of a qualifying deck: an element's tokens, or any other line kept verbatim.
const Card = struct { line: []const u8, tokens: []const []const u8, element: bool };

/// The dot cards a qualifying deck may hold: none names a node or a device
/// value a rewrite would have to follow (a `.dc` sweep of a source, which no
/// rewrite renames or scales; `scale` skips decks with I cards).
const dot_ok = std.StaticStringMap(void).initComptime(.{
    .{".op"}, .{".dc"}, .{".ac"}, .{".tran"}, .{".end"}, .{".options"}, .{".option"}, .{".model"},
});

/// Element letters a rewrite reads, with their node count (ngspice manual
/// §3, §4.2). A MOSFET is out: VDMOS has three nodes where the rest have four.
fn nodeCount(letter: u8) ?u8 {
    return switch (std.ascii.toLower(letter)) {
        'r', 'c', 'l', 'v', 'i', 'd', 'f', 'h' => 2,
        'e', 'g' => 4,
        else => null,
    };
}

/// `src`'s cards when the deck qualifies, else null.
fn cards(a: Allocator, src: []const u8) Allocator.Error!?[]const Card {
    var out: std.ArrayList(Card) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, src, "\n"), '\n');
    _ = it.next(); // the title
    var elements: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const t = std.mem.trimStart(u8, line, " \t");
        if (t.len == 0 or t[0] == '*') {
            try out.append(a, .{ .line = line, .tokens = &.{}, .element = false });
            continue;
        }
        // Continuations, inline comments and expressions: out. Groups and
        // pairs stay on cards no rewrite edits past the nodes.
        if (std.mem.indexOfAny(u8, t, "+;${}'\"") != null) return null;
        const rcl = std.mem.indexOfScalar(u8, "rclRCL", t[0]) != null;
        if (rcl and std.mem.indexOfAny(u8, t, "()=") != null) return null;
        var toks: std.ArrayList([]const u8) = .empty;
        var ti = std.mem.tokenizeAny(u8, t, " \t,");
        while (ti.next()) |tok| try toks.append(a, tok);
        if (toks.items.len == 0) return null;
        const head = toks.items[0];
        if (head[0] == '.') {
            const low = try std.ascii.allocLowerString(a, head);
            if (!dot_ok.has(low)) return null;
            // A `.dc` sweep of an R, C or L value would have to follow a split or scale.
            if (std.mem.eql(u8, low, ".dc") and toks.items.len > 1 and std.mem.indexOfScalar(u8, "rclRCL", toks.items[1][0]) != null) return null;
            try out.append(a, .{ .line = line, .tokens = toks.items, .element = false });
            continue;
        }
        const nodes = nodeCount(head[0]) orelse return null;
        if (toks.items.len < 1 + nodes) return null;
        switch (std.ascii.toLower(head[0])) {
            'r', 'c', 'l' => if (toks.items.len != 4 or number(toks.items[3]) == null) return null,
            // Linear controlled sources only: a POLY, LAPLACE or POLE form
            // puts controlling nodes past where the rename looks.
            'e', 'g' => if (toks.items.len != 6 or number(toks.items[5]) == null) return null,
            'f', 'h' => if (toks.items.len != 5 or number(toks.items[4]) == null) return null,
            else => {},
        }
        elements += 1;
        try out.append(a, .{ .line = line, .tokens = toks.items, .element = true });
    }
    if (elements == 0) return null;
    return out.items;
}

/// A SPICE number (ngspice manual §2.1.2): mantissa, optional exponent,
/// optional scale factor, trailing letters ignored. Null when `s` is not one.
pub fn number(s: []const u8) ?f64 {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const digits = i;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
    if (i == digits) return null;
    if (i + 1 < s.len and (s[i] == 'e' or s[i] == 'E') and (std.ascii.isDigit(s[i + 1]) or s[i + 1] == '-' or s[i + 1] == '+')) {
        i += 2;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    const base = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    const rest = s[i..];
    const scales = [_]struct { []const u8, f64 }{
        .{ "meg", 1e6 }, .{ "mil", 25.4e-6 }, .{ "t", 1e12 }, .{ "g", 1e9 }, .{ "k", 1e3 },
        .{ "m", 1e-3 },  .{ "u", 1e-6 },      .{ "n", 1e-9 }, .{ "p", 1e-12 }, .{ "f", 1e-15 },
    };
    for (scales) |sc| if (std.ascii.startsWithIgnoreCase(rest, sc[0])) return base * sc[1];
    for (rest) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return base;
}

fn isGround(node: []const u8) bool {
    return std.mem.eql(u8, node, "0") or std.ascii.eqlIgnoreCase(node, "gnd");
}

/// The rewrite `kind` of `src`, or null when the deck does not qualify or
/// the rewrite has nothing to act on.
pub fn rewrite(a: Allocator, src: []const u8, kind: Kind) Allocator.Error!?Variant {
    const cs = try cards(a, src) orelse return null;
    const title_end = std.mem.indexOfScalar(u8, src, '\n') orelse return null;
    var v: Variant = .{ .kind = kind, .text = "" };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, src[0 .. title_end + 1]);
    switch (kind) {
        .rename => {
            // Renumbered in reverse order of first appearance.
            var order: std.ArrayList([]const u8) = .empty;
            for (cs) |c| if (c.element) for (c.tokens[1..][0..nodeCount(c.tokens[0][0]).?]) |n| {
                const low = try std.ascii.allocLowerString(a, n);
                if (isGround(low) or v.names.contains(low)) continue;
                try v.names.put(a, low, "");
                try order.append(a, low);
            };
            for (order.items, 0..) |n, i| v.names.putAssumeCapacity(n, try std.fmt.allocPrint(a, "m{d}", .{order.items.len - i}));
            for (cs) |c| {
                if (!c.element) {
                    try out.print(a, "{s}\n", .{c.line});
                    continue;
                }
                try out.appendSlice(a, c.tokens[0]);
                for (c.tokens[1..], 1..) |t, i| {
                    const low = try std.ascii.allocLowerString(a, t);
                    const node = i <= nodeCount(c.tokens[0][0]).?;
                    try out.print(a, " {s}", .{if (node) v.names.get(low) orelse t else t});
                }
                try out.append(a, '\n');
            }
        },
        .reorder => {
            var els: std.ArrayList([]const u8) = .empty;
            for (cs) |c| if (c.element) try els.append(a, c.line);
            std.mem.reverse([]const u8, els.items);
            var next: usize = 0;
            for (cs) |c| {
                const line = if (c.element) blk: {
                    next += 1;
                    break :blk els.items[next - 1];
                } else c.line;
                try out.print(a, "{s}\n", .{line});
            }
        },
        .split => {
            var done = false;
            for (cs) |c| {
                if (!done and c.element and std.ascii.toLower(c.tokens[0][0]) == 'r') {
                    const half = number(c.tokens[3]).? / 2;
                    try out.print(a, "{s} {s} mm_split {e}\n{s}_b mm_split {s} {e}\n", .{ c.tokens[0], c.tokens[1], half, c.tokens[0], c.tokens[2], half });
                    done = true;
                } else try out.print(a, "{s}\n", .{c.line});
            }
            if (!done) return null;
        },
        .scale => {
            // Only R, C, L and V: a current source, a diode or a gain would not scale.
            for (cs) |c| if (c.element and std.mem.indexOfScalar(u8, "rclvRCLV", c.tokens[0][0]) == null) return null;
            v.current_factor = k;
            for (cs) |c| {
                const factor: f64 = if (!c.element) 1 else switch (std.ascii.toLower(c.tokens[0][0])) {
                    'r', 'l' => k,
                    'c' => 1 / k,
                    else => 1,
                };
                if (factor == 1) {
                    try out.print(a, "{s}\n", .{c.line});
                    continue;
                }
                try out.print(a, "{s} {s} {s} {e}\n", .{ c.tokens[0], c.tokens[1], c.tokens[2], number(c.tokens[3]).? * factor });
            }
        },
        .zero_source => {
            const node = for (cs) |c| {
                if (!c.element) continue;
                if (!isGround(c.tokens[1])) break c.tokens[1];
                if (!isGround(c.tokens[2])) break c.tokens[2];
            } else return null;
            try out.print(a, "imm_zero {s} 0 0\n", .{node});
            for (cs) |c| try out.print(a, "{s}\n", .{c.line});
        },
    }
    v.text = out.items;
    assert(v.text.len > title_end);
    return v;
}

const testing = std.testing;

test "numbers read as ngspice reads them" {
    try testing.expectEqual(@as(?f64, 1000), number("1k"));
    try testing.expectEqual(@as(?f64, 2.2e-6), number("2.2u"));
    try testing.expectEqual(@as(?f64, 1e6), number("1Meg"));
    try testing.expectEqual(@as(?f64, 10), number("10v"));
    try testing.expectEqual(@as(?f64, 1.5e-3), number("1.5e-3"));
    try testing.expectEqual(@as(?f64, null), number("abc"));
}

test "each rewrite keeps the relation it states" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deck = "t\nVin in 0 10\nR1 in out 1k\nC1 out 0 1p\n.op\n.end\n";
    const r = (try rewrite(a, deck, .rename)).?;
    try testing.expectEqualStrings("t\nVin m2 0 10\nR1 m2 m1 1k\nC1 m1 0 1p\n.op\n.end\n", r.text);
    try testing.expectEqualStrings("v(m1)", try r.column(a, "V(out)"));
    try testing.expectEqualStrings("i(vin)", try r.column(a, "i(vin)"));
    try testing.expectEqualStrings("t\nC1 out 0 1p\nR1 in out 1k\nVin in 0 10\n.op\n.end\n", (try rewrite(a, deck, .reorder)).?.text);
    try testing.expectEqualStrings("t\nVin in 0 10\nR1 in mm_split 5e2\nR1_b mm_split out 5e2\nC1 out 0 1p\n.op\n.end\n", (try rewrite(a, deck, .split)).?.text);
    const s = (try rewrite(a, deck, .scale)).?;
    try testing.expectEqualStrings("t\nVin in 0 10\nR1 in out 1e4\nC1 out 0 1e-13\n.op\n.end\n", s.text);
    try testing.expectEqual(k, s.current_factor);
    try testing.expectEqualStrings("t\nimm_zero in 0 0\nVin in 0 10\nR1 in out 1k\nC1 out 0 1p\n.op\n.end\n", (try rewrite(a, deck, .zero_source)).?.text);
    const dd = (try rewrite(a, "t\nv1 a 0 1\nd1 a k dm\ne1 o 0 k 0 2\n.model dm d\n", .rename)).?;
    try testing.expectEqualStrings("t\nv1 m3 0 1\nd1 m3 m2 dm\ne1 m1 0 m2 0 2\n.model dm d\n", dd.text);
    try testing.expectEqual(null, try rewrite(a, "t\nv1 a 0 1\nd1 a 0 dm\n.model dm d\n", .scale));
    // Out of scope: a MOSFET, a POLY source, a pair on an R, an I card under `scale`.
    try testing.expectEqual(null, try rewrite(a, "t\nm1 d g 0 0 nm\n.model nm nmos\n", .reorder));
    try testing.expectEqual(null, try rewrite(a, "t\ne1 o 0 poly(1) a 0 0 1\n", .reorder));
    try testing.expectEqual(null, try rewrite(a, "t\nr1 a 0 r=1k\n", .reorder));
    try testing.expectEqual(null, try rewrite(a, "t\ni1 a 0 1m\nr1 a 0 1k\n.op\n", .scale));
}
