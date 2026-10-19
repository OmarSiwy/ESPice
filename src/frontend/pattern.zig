//! HSPICE pattern sources [SA Ch.9 "Pattern Source"; CR .PAT]: a V or I
//! card's `PAT (vhi vlo td tr tf tsample data)` is rewritten, before
//! parsing, into the PWL that draws it. `data` is b-strings (`b10m1`),
//! `[ ... ]` nested structures and `.pat` names, each followed by optional
//! `R=` and `RB=`. Each bit holds for `tsample`; a change of level ramps
//! over `tr` (rising) or `tf` (falling), centred on the bit boundary, so the
//! first change is at td + N*tsample - tr/2 as the manual gives.
const std = @import("std");

/// PWL points the source models hold (`pwl_times[0:63]` in vsource.va and
/// isource.va).
const max_points = 64;
/// Expanded states a pattern may reach before it is refused, so `R=` with a
/// huge count fails fast instead of exhausting memory. A pattern past
/// `max_points` changes is refused anyway; this only caps long runs.
const max_states = 1 << 20;
/// `[ ... ]` nesting a pattern may use, so the recursive reader cannot
/// overflow the stack.
const max_depth = 32;

const Error = error{ OutOfMemory, InvalidPattern, UnsupportedPattern };

/// One component: a b-string's bits, or a nested list, repeated `r` more
/// times from its `rb`-th element (1-based). `depth` counts the `[ ... ]`
/// levels inside it, through the `.pat` names it reads, so `expand`
/// recurses at most `max_depth` deep (#67).
const Comp = struct {
    bits: []const u8 = "",
    list: []const Comp = &.{},
    r: u32 = 0,
    rb: u32 = 1,
    depth: u8 = 0,

    fn units(c: Comp) usize {
        return if (c.list.len > 0) c.list.len else c.bits.len;
    }

    /// The component's states, `0`, `1` or `m`, appended to `out`.
    fn expand(c: Comp, arena: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        for (0..c.r + 1) |pass| {
            const from = if (pass == 0) 0 else c.rb - 1;
            if (c.list.len > 0) {
                for (c.list[from..]) |child| try child.expand(arena, out);
            } else try out.appendSlice(arena, c.bits[from..]);
            if (out.items.len > max_states) return error.InvalidPattern;
        }
    }
};

/// Rewrites, in place, every V/I card in `lines` (lowercased logical lines)
/// that uses `PAT`; a rewritten line lives in `arena`. UnsupportedPattern
/// for a `Z` (high-impedance) state, which a V or I source cannot drive;
/// InvalidPattern for a malformed PAT form or `.pat` line, an undefined
/// name, an 8b/10b K-string, `R=-1` (forever), a pattern past the PWL's 64
/// points, over a million states long or nested over 32 deep. Lines before
/// the failing card are already rewritten when it fails.
pub fn rewrite(arena: std.mem.Allocator, lines: [][]const u8) Error!void {
    var defs: std.StringHashMapUnmanaged(Comp) = .empty;
    for (lines) |line| {
        if (!std.mem.startsWith(u8, line, ".pat ")) continue;
        const toks = try tokens(arena, line[5..]);
        if (toks.len < 3 or !std.mem.eql(u8, toks[1], "=")) return error.InvalidPattern;
        const def = group(arena, toks[2..], defs) catch |err| {
            if (!@import("builtin").is_test) switch (err) {
                error.InvalidPattern => std.log.warn("pattern: cannot read '{s}'", .{line}),
                error.UnsupportedPattern => std.log.err("pattern: '{s}': a Z (high-impedance) state is not supported", .{line}),
                error.OutOfMemory => {},
            };
            return err;
        };
        try defs.put(arena, toks[0], def);
    }
    for (lines) |*line| {
        if (line.len == 0 or (line.*[0] != 'v' and line.*[0] != 'i')) continue;
        const at = keyword(line.*) orelse continue;
        line.* = source(arena, line.*, at, defs) catch |err| {
            if (!@import("builtin").is_test) switch (err) {
                error.InvalidPattern => std.log.warn("pattern: cannot read '{s}'", .{line.*}),
                error.UnsupportedPattern => std.log.err("pattern: '{s}': a Z (high-impedance) state is not supported", .{line.*}),
                error.OutOfMemory => {},
            };
            return err;
        };
    }
}

/// Offset of the `pat` word in a card, past its name and two nodes. Reads
/// the words in place: most V and I cards have none, and pay no allocation.
fn keyword(line: []const u8) ?usize {
    var it: Words = .{ .text = line };
    for (0..3) |_| _ = it.next() orelse return null;
    if (it.peek() == null) return null;
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, "pat") or std.mem.startsWith(u8, t, "pat(")) return t.ptr - line.ptr;
    }
    return null;
}

/// `line` with its PAT form, from `at` on, replaced by the PWL.
fn source(arena: std.mem.Allocator, line: []const u8, at: usize, defs: std.StringHashMapUnmanaged(Comp)) Error![]const u8 {
    var body = std.mem.trim(u8, line[at + 3 ..], " \t");
    if (body.len > 0 and body[0] == '(') {
        const close = std.mem.lastIndexOfScalar(u8, body, ')') orelse return error.InvalidPattern;
        body = body[1..close];
    }
    const toks = try tokens(arena, body);
    if (toks.len < 7) return error.InvalidPattern;
    const p = toks[0..6];
    var states: std.ArrayList(u8) = .empty;
    try (try group(arena, toks[6..], defs)).expand(arena, &states);
    if (states.items.len == 0) return error.InvalidPattern;

    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}pwl(0 {s}", .{ line[0..at], try level(arena, p, states.items[0]) });
    var points: usize = 1;
    for (states.items[1..], 1..) |s, k| {
        const prev = states.items[k - 1];
        if (s == prev) continue;
        points += 2;
        if (points > max_points) return error.InvalidPattern;
        const ramp = if (rank(s) > rank(prev)) p[3] else p[4];
        const edge = try arena.print("({s})+{d}*({s})", .{ p[2], k, p[5] });
        try out.print(arena, " '{s}-({s})/2' {s} '{s}+({s})/2' {s}", .{ edge, ramp, try level(arena, p, prev), edge, ramp, try level(arena, p, s) });
    }
    try out.append(arena, ')');
    return out.items;
}

fn rank(state: u8) u8 {
    return switch (state) {
        '0' => 0,
        'm' => 1,
        else => 2,
    };
}

/// A state's level as a PWL value: vhi, vlo, or their mean for `m`.
fn level(arena: std.mem.Allocator, p: []const []const u8, state: u8) Error![]const u8 {
    return switch (state) {
        '1' => try arena.print("'{s}'", .{p[0]}),
        '0' => try arena.print("'{s}'", .{p[1]}),
        else => try arena.print("'0.5*(({s})+({s}))'", .{ p[0], p[1] }),
    };
}

/// A component sequence; one component stands for itself, several form a
/// list. `R=`/`RB=` apply to the component before them.
fn group(arena: std.mem.Allocator, toks: []const []const u8, defs: std.StringHashMapUnmanaged(Comp)) Error!Comp {
    var i: usize = 0;
    const list = try sequence(arena, toks, &i, defs, 0);
    if (i != toks.len or list.len == 0) return error.InvalidPattern;
    return if (list.len == 1) list[0] else .{ .list = list, .depth = maxDepth(list) };
}

fn maxDepth(list: []const Comp) u8 {
    var d: u8 = 0;
    for (list) |c| d = @max(d, c.depth);
    return d;
}

fn sequence(arena: std.mem.Allocator, toks: []const []const u8, i: *usize, defs: std.StringHashMapUnmanaged(Comp), depth: u8) Error![]Comp {
    var out: std.ArrayList(Comp) = .empty;
    while (i.* < toks.len) {
        const t = toks[i.*];
        if (std.mem.eql(u8, t, "]")) break;
        i.* += 1;
        if (std.mem.eql(u8, t, "[")) {
            if (depth == max_depth) return error.InvalidPattern;
            const list = try sequence(arena, toks, i, defs, depth + 1);
            if (i.* == toks.len or list.len == 0) return error.InvalidPattern;
            i.* += 1;
            try out.append(arena, .{ .list = list, .depth = 1 + maxDepth(list) });
        } else if ((std.mem.eql(u8, t, "r") or std.mem.eql(u8, t, "rb")) and i.* + 1 < toks.len and std.mem.eql(u8, toks[i.*], "=")) {
            const n = std.fmt.parseInt(i32, toks[i.* + 1], 10) catch return error.InvalidPattern;
            i.* += 2;
            if (out.items.len == 0) return error.InvalidPattern;
            const last = &out.items[out.items.len - 1];
            if (t.len == 1) {
                // ponytail: R=-1 repeats forever; needs the PWL's own repeat.
                if (n == -1) return error.InvalidPattern;
                last.r = @intCast(@max(n, 0));
            } else {
                last.rb = @intCast(@max(n, 1));
                if (last.rb > last.units()) return error.InvalidPattern;
            }
        } else if (t[0] == 'b' and t.len > 1 and std.mem.indexOfNone(u8, t[1..], "01m") == null) {
            try out.append(arena, .{ .bits = t[1..] });
        } else if (t[0] == 'b' and t.len > 1 and std.mem.indexOfNone(u8, t[1..], "01mz") == null) {
            return error.UnsupportedPattern;
        } else {
            const def = defs.get(t) orelse return error.InvalidPattern;
            if (depth + def.depth > max_depth) return error.InvalidPattern;
            try out.append(arena, def);
        }
    }
    return out.items;
}

/// Blank-separated words of `text`, with `[`, `]` and `=` as words of
/// their own; a quoted run stays inside its word. Borrows `text`.
const Words = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(w: Words) ?[]const u8 {
        var copy = w;
        return copy.next();
    }

    fn next(w: *Words) ?[]const u8 {
        const text = w.text;
        var i = w.pos;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == ',')) i += 1;
        if (i == text.len) {
            w.pos = i;
            return null;
        }
        const start = i;
        if (text[i] == '[' or text[i] == ']' or text[i] == '=') {
            i += 1;
        } else {
            var quote: ?u8 = null;
            while (i < text.len) : (i += 1) {
                const b = text[i];
                if (quote) |q| {
                    if (b == q) quote = null;
                } else if (b == '\'' or b == '"') {
                    quote = b;
                } else if (std.mem.indexOfScalar(u8, " \t,[]=", b) != null) break;
            }
        }
        w.pos = i;
        return text[start..i];
    }
};

/// Every word of `text` (`Words`), in `arena`.
fn tokens(arena: std.mem.Allocator, text: []const u8) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it: Words = .{ .text = text };
    while (it.next()) |t| try out.append(arena, t);
    return out.items;
}

test "pattern sources expand as the manual's examples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { []const u8, []const u8 };
    const defs_src = [_][]const u8{ ".pat a1=b1010 r=1 rb=1", ".pat a2=b0101 r=1 rb=1", ".pat n1=[b1010 b0101] r=0 rb=1" };
    for ([_]Case{
        .{ "b1011 r=1 rb=2 b0m1", "1011011" ++ "0m1" },
        .{ "[b1011 r=1 rb=2 b0m1] r=2 rb=2", "1011011" ++ "0m1" ++ "0m1" ++ "0m1" },
        .{ "a1 a2 r=2 rb=2", "10101010" ++ "0101" ++ "101" ++ "101" },
        .{ "[n1 b0011] r=1 rb=1", "10100101" ++ "0011" ++ "10100101" ++ "0011" },
    }) |case| {
        var lines = [_][]const u8{ defs_src[0], defs_src[1], defs_src[2] };
        var defs: std.StringHashMapUnmanaged(Comp) = .empty;
        for (&lines) |l| {
            const t = try tokens(a, l[5..]);
            try defs.put(a, t[0], try group(a, t[2..], defs));
        }
        var states: std.ArrayList(u8) = .empty;
        try (try group(a, try tokens(a, case[0]), defs)).expand(a, &states);
        try std.testing.expectEqualStrings(case[1], states.items);
    }
    var lines = [_][]const u8{ "v1 1 0 pat (5 0 1n 1n 2n 5n b10)", "r1 1 0 1" };
    try rewrite(a, &lines);
    try std.testing.expectEqualStrings("v1 1 0 pwl(0 '5' '(1n)+1*(5n)-(2n)/2' '5' '(1n)+1*(5n)+(2n)/2' '0')", lines[0]);
    var z = [_][]const u8{"v1 1 0 pat (5 0 0 1n 1n 5n b1z)"};
    try std.testing.expectError(error.UnsupportedPattern, rewrite(a, &z));
}

test "pattern corner cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Without parentheses, and one state: a constant PWL.
    var one = [_][]const u8{"v1 1 0 pat 5 0 1n 1n 2n 5n b1"};
    try rewrite(a, &one);
    try std.testing.expectEqualStrings("v1 1 0 pwl(0 '5')", one[0]);
    // `m` is the mid level, reached on the rising ramp.
    var mid = [_][]const u8{"i1 1 0 pat (5 0 0 1n 2n 1n b0m)"};
    try rewrite(a, &mid);
    try std.testing.expect(std.mem.indexOf(u8, mid[0], "-(1n)/2' '0' '(0)+1*(1n)+(1n)/2' '0.5*((5)+(0))')") != null);
    // Cards without PAT, and PAT in a node position, are left alone.
    var plain = [_][]const u8{ "v1 1 0 pwl(0 0)", "vpat pat 0 1", "r1 pat 0 1" };
    try rewrite(a, &plain);
    try std.testing.expectEqualStrings("v1 1 0 pwl(0 0)", plain[0]);
    try std.testing.expectEqualStrings("vpat pat 0 1", plain[1]);
    var deep: std.ArrayList(u8) = .empty;
    try deep.appendSlice(a, "v1 1 0 pat (5 0 0 1n 1n 1n ");
    for (0..40) |_| try deep.appendSlice(a, "[ ");
    try deep.appendSlice(a, "b1 ");
    for (0..40) |_| try deep.appendSlice(a, "] ");
    try deep.append(a, ')');
    var toggles: std.ArrayList(u8) = .empty;
    try toggles.appendSlice(a, "v1 1 0 pat (5 0 0 1n 1n 1n b");
    for (0..40) |_| try toggles.appendSlice(a, "10");
    try toggles.append(a, ')');
    for ([_][]const u8{
        "v1 1 0 pat (5 0 0 1n 1n 1n b1 r=2000000000)", // bounded, not 2 GB
        "v1 1 0 pat (5 0 0 1n 1n 1n b10 rb=3)", // RB past the component
        "v1 1 0 pat (5 0 0 1n 1n 1n b10 r=-1)", // forever
        "v1 1 0 pat (5 0 0 1n 1n 1n nope)", // undefined name
        "v1 1 0 pat (5 0 0 1n 1n 1n [b1)", // unclosed
        "v1 1 0 pat (5 0 0 1n 1n 1n [])", // empty list
        "v1 1 0 pat (5 0 0 1n 1n 1n r=1)", // R= with nothing before it
        "v1 1 0 pat (5 0 0 1n 1n)", // too few fields
        "v1 1 0 pat (5 0 0 1n 1n 1n b1",
        deep.items,
        toggles.items, // 80 changes, past the PWL's 64 points
    }) |card| {
        var lines = [_][]const u8{card};
        try std.testing.expectError(error.InvalidPattern, rewrite(a, &lines));
    }
    var bad_def = [_][]const u8{".pat a b1"};
    try std.testing.expectError(error.InvalidPattern, rewrite(a, &bad_def));
}

test "a .pat name nests as deep as its definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // p0 = [b1] and pK = [p(K-1)]: pK is K+1 levels deep.
    var lines: [34][]const u8 = undefined;
    lines[0] = ".pat p0=[b1]";
    for (1..33) |k| lines[k] = try a.print(".pat p{d}=[p{d}]", .{ k, k - 1 });
    // p31 is 32 deep, the limit.
    lines[32] = "v1 1 0 pat (5 0 0 1n 1n 1n p31)";
    try rewrite(a, lines[0..33]);
    try std.testing.expectEqualStrings("v1 1 0 pwl(0 '5')", lines[32]);
    // p32 is 33 deep.
    lines[32] = ".pat p32=[p31]";
    lines[33] = "v1 1 0 pat (5 0 0 1n 1n 1n p32)";
    try std.testing.expectError(error.InvalidPattern, rewrite(a, &lines));
}

test "words split on blanks, commas and the bracket and `=` bytes; quotes hold" {
    var it: Words = .{ .text = " b10,[a]=  'x y'z\t" };
    for ([_][]const u8{ "b10", "[", "a", "]", "=", "'x y'z" }) |want| try std.testing.expectEqualStrings(want, it.next().?);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(null, keyword("v1 a"));
    try std.testing.expectEqual(null, keyword("v1 a 0"));
    try std.testing.expectEqual(@as(?usize, 7), keyword("v1 a 0 pat(1 0 0 1n 1n 1n b1)"));
}

fn rewriteAll(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var cards = [_][]const u8{ ".pat a1=b10 r=1", "v1 1 0 pat (5 0 1n 1n 2n 5n [a1 b0m] r=1 rb=2)", "i1 1 0 pat 1 0 0 1n 1n 1n b01" };
    try rewrite(arena.allocator(), &cards);
}

test "rewrite: every allocation failure surfaces as OutOfMemory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, rewriteAll, .{});
}
