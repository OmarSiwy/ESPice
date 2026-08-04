//! PEG grammar text -> a rule table; a rule table + input bytes -> parse tree
//! rows. The interpreter behind the grammar oracle: each `tests/grammar/*.peg`
//! is the executable spec of one input syntax, as Zig's
//! `doc/langref/grammar.peg` is of Zig, and the oracle's tree is checked
//! against what the real frontend reads (dev/frontend.md, "Grammar oracle").
//!
//! Notation (Ford, POPL 2004, with peg/leg's spelling):
//!
//!     # comment to end of line
//!     Rule <- a b / c        sequence, ordered choice
//!     e* e+ e?               repetition, option (greedy, no backtracking into)
//!     &e !e                  lookahead, negative lookahead (consume nothing)
//!     'lit' "lit" 'lit'i     literal; a trailing `i` matches ASCII case-blind
//!     [a-z_\]] [^\n]         byte class, `^` negates; escapes \n \r \t \\ \] \' \" \xHH
//!     .                      any byte
//!     ( e )                  grouping
//!
//! A rule whose name starts with an uppercase letter is captured: its match is
//! a tree row. A lowercase rule is lexical and leaves no row, so a token rule
//! like `ws` never clutters the tree.
//!
//! Every grammar node counts its successful matches (`Grammar.hits`), so the
//! harness can fail on a rule, an alternative or an optional part no input
//! exercised: the coverage gate that makes "every rule is tested" checkable.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Grammar node kinds. `a`/`b` per tag: `seq`/`choice`: `kids[a..][0..b]`;
/// `star`/`plus`/`opt`/`and`/`not`: child node `a`; `lit`/`lit_i`: `bytes[a..][0..b]`;
/// `class`: `classes[a]`; `any`: unused; `ref`: rule `a`.
pub const Tag = enum(u8) { seq, choice, star, plus, opt, @"and", not, lit, lit_i, class, any, ref };

/// One grammar node row.
pub const Node = struct { tag: Tag, a: u32, b: u32 };

/// Rule names the oracle refers to are u16 ids; a grammar this size has
/// a few hundred rules.
pub const RuleId = u16;
pub const rules_max = std.math.maxInt(RuleId);
/// Recursion depth past which a parse fails with `error.DepthExceeded`:
/// input-controlled nesting (expressions, parentheses) is capped, not trusted.
pub const depth_max = 512;

/// A compiled grammar. Every slice lives in the arena `compile` was given;
/// only `hits` mutates, once per successful node match.
pub const Grammar = struct {
    nodes: []const Node,
    kids: []const u32,
    bytes: []const u8,
    classes: []const std.StaticBitSet(256),
    rule_names: []const []const u8,
    rule_bodies: []const u32,
    /// Per node, how many times it matched. Grows across every parse.
    hits: []u32,

    /// The rule named `name`. Asserts it exists: the oracle names rules the
    /// grammar must define, so a typo is a programmer error.
    pub fn rule(g: Grammar, name: []const u8) RuleId {
        for (g.rule_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        std.debug.panic("grammar has no rule '{s}'", .{name});
    }

    /// The rule named `name`, or null when the grammar has none.
    pub fn find(g: Grammar, name: []const u8) ?RuleId {
        for (g.rule_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        return null;
    }

    /// True when rule `r` leaves a tree row.
    pub fn captured(g: Grammar, r: RuleId) bool {
        return std.ascii.isUpper(g.rule_names[r][0]);
    }
};

/// Grammar text errors, all a programmer error in a checked-in `.peg` file,
/// reported with the byte offset so the test names the line.
pub const CompileError = error{ OutOfMemory, GrammarSyntax, UndefinedRule, DuplicateRule, TooManyRules };

/// Compiles grammar text. `diag` receives the byte offset of a syntax error
/// or the first undefined/duplicate rule's name.
pub fn compile(arena: Allocator, text: []const u8, diag: *Diag) CompileError!Grammar {
    var c: Compiler = .{ .arena = arena, .src = text, .diag = diag };
    try c.grammar();
    const g: Grammar = .{
        .nodes = c.nodes.items,
        .kids = c.kids.items,
        .bytes = c.bytes.items,
        .classes = c.classes.items,
        .rule_names = c.names.items,
        .rule_bodies = c.bodies.items,
        .hits = try arena.alloc(u32, c.nodes.items.len),
    };
    @memset(g.hits, 0);
    // Resolve forward references: a `ref` holds a name index until here.
    for (c.nodes.items) |*n| if (n.tag == .ref) {
        const name = c.ref_names.items[n.a];
        n.a = for (g.rule_names, 0..) |r, i| {
            if (std.mem.eql(u8, r, name)) break @intCast(i);
        } else {
            diag.* = .{ .offset = 0, .name = name };
            return error.UndefinedRule;
        };
    };
    assert(g.rule_names.len == g.rule_bodies.len);
    assert(g.hits.len == g.nodes.len);
    return g;
}

/// Where a grammar or a parse failed.
pub const Diag = struct { offset: u32 = 0, name: []const u8 = "" };

const Compiler = struct {
    arena: Allocator,
    src: []const u8,
    pos: u32 = 0,
    diag: *Diag,
    nodes: std.ArrayList(Node) = .empty,
    kids: std.ArrayList(u32) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    classes: std.ArrayList(std.StaticBitSet(256)) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    bodies: std.ArrayList(u32) = .empty,
    ref_names: std.ArrayList([]const u8) = .empty,

    fn fail(c: *Compiler) CompileError {
        c.diag.* = .{ .offset = c.pos };
        return error.GrammarSyntax;
    }

    fn skip(c: *Compiler) void {
        while (c.pos < c.src.len) {
            const ch = c.src[c.pos];
            if (ch == '#') {
                while (c.pos < c.src.len and c.src[c.pos] != '\n') c.pos += 1;
            } else if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                c.pos += 1;
            } else break;
        }
    }

    fn peek(c: *Compiler) u8 {
        c.skip();
        return if (c.pos < c.src.len) c.src[c.pos] else 0;
    }

    fn ident(c: *Compiler) ?[]const u8 {
        c.skip();
        const start = c.pos;
        while (c.pos < c.src.len and (std.ascii.isAlphanumeric(c.src[c.pos]) or c.src[c.pos] == '_')) c.pos += 1;
        return if (c.pos == start) null else c.src[start..c.pos];
    }

    fn arrow(c: *Compiler) bool {
        c.skip();
        if (std.mem.startsWith(u8, c.src[c.pos..], "<-")) {
            c.pos += 2;
            return true;
        }
        return false;
    }

    fn grammar(c: *Compiler) CompileError!void {
        while (c.peek() != 0) {
            const name = c.ident() orelse return c.fail();
            if (!c.arrow()) return c.fail();
            for (c.names.items) |n| if (std.mem.eql(u8, n, name)) {
                c.diag.* = .{ .offset = c.pos, .name = name };
                return error.DuplicateRule;
            };
            if (c.names.items.len == rules_max) return error.TooManyRules;
            try c.names.append(c.arena, name);
            try c.bodies.append(c.arena, try c.choice());
        }
        if (c.names.items.len == 0) return c.fail();
    }

    fn add(c: *Compiler, n: Node) !u32 {
        try c.nodes.append(c.arena, n);
        return @intCast(c.nodes.items.len - 1);
    }

    /// Wraps `items` in a `seq`/`choice` node, or returns the lone item.
    fn group(c: *Compiler, tag: Tag, items: []const u32) !u32 {
        if (items.len == 1) return items[0];
        const start: u32 = @intCast(c.kids.items.len);
        try c.kids.appendSlice(c.arena, items);
        return c.add(.{ .tag = tag, .a = start, .b = @intCast(items.len) });
    }

    fn choice(c: *Compiler) CompileError!u32 {
        var alts: std.ArrayList(u32) = .empty;
        try alts.append(c.arena, try c.sequence());
        while (c.peek() == '/') {
            c.pos += 1;
            try alts.append(c.arena, try c.sequence());
        }
        return c.group(.choice, alts.items);
    }

    /// True when the next token starts a new rule (`Name <-`), ending a sequence.
    fn atRuleStart(c: *Compiler) bool {
        const save = c.pos;
        defer c.pos = save;
        _ = c.ident() orelse return false;
        return c.arrow();
    }

    fn sequence(c: *Compiler) CompileError!u32 {
        var items: std.ArrayList(u32) = .empty;
        while (true) {
            const ch = c.peek();
            if (ch == 0 or ch == '/' or ch == ')' or c.atRuleStart()) break;
            try items.append(c.arena, try c.prefix());
        }
        // An empty sequence matches the empty string.
        if (items.items.len == 0) return c.add(.{ .tag = .seq, .a = 0, .b = 0 });
        return c.group(.seq, items.items);
    }

    fn prefix(c: *Compiler) CompileError!u32 {
        const ch = c.peek();
        if (ch == '&' or ch == '!') {
            c.pos += 1;
            const inner = try c.suffix();
            return c.add(.{ .tag = if (ch == '&') .@"and" else .not, .a = inner, .b = 0 });
        }
        return c.suffix();
    }

    fn suffix(c: *Compiler) CompileError!u32 {
        var inner = try c.primary();
        while (true) {
            const tag: Tag = switch (c.peek()) {
                '*' => .star,
                '+' => .plus,
                '?' => .opt,
                else => return inner,
            };
            c.pos += 1;
            inner = try c.add(.{ .tag = tag, .a = inner, .b = 0 });
        }
    }

    fn primary(c: *Compiler) CompileError!u32 {
        const ch = c.peek();
        switch (ch) {
            '(' => {
                c.pos += 1;
                const inner = try c.choice();
                if (c.peek() != ')') return c.fail();
                c.pos += 1;
                return inner;
            },
            '.' => {
                c.pos += 1;
                return c.add(.{ .tag = .any, .a = 0, .b = 0 });
            },
            '\'', '"' => return c.literal(ch),
            '[' => return c.class(),
            else => {
                const name = c.ident() orelse return c.fail();
                try c.ref_names.append(c.arena, name);
                return c.add(.{ .tag = .ref, .a = @intCast(c.ref_names.items.len - 1), .b = 0 });
            },
        }
    }

    /// One possibly escaped byte inside a literal or class.
    fn escaped(c: *Compiler) CompileError!u8 {
        if (c.pos >= c.src.len) return c.fail();
        const ch = c.src[c.pos];
        c.pos += 1;
        if (ch != '\\') return ch;
        if (c.pos >= c.src.len) return c.fail();
        const e = c.src[c.pos];
        c.pos += 1;
        return switch (e) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\', '\'', '"', ']', '[', '-', '^' => e,
            'x' => blk: {
                if (c.pos + 2 > c.src.len) return c.fail();
                const v = std.fmt.parseInt(u8, c.src[c.pos..][0..2], 16) catch return c.fail();
                c.pos += 2;
                break :blk v;
            },
            else => c.fail(),
        };
    }

    fn literal(c: *Compiler, quote: u8) CompileError!u32 {
        c.pos += 1;
        const start: u32 = @intCast(c.bytes.items.len);
        while (true) {
            if (c.pos >= c.src.len) return c.fail();
            if (c.src[c.pos] == quote) break;
            try c.bytes.append(c.arena, try c.escaped());
        }
        c.pos += 1;
        const len: u32 = @intCast(c.bytes.items.len - start);
        if (len == 0) return c.fail();
        const blind = c.pos < c.src.len and c.src[c.pos] == 'i' and
            (c.pos + 1 == c.src.len or !std.ascii.isAlphanumeric(c.src[c.pos + 1]) and c.src[c.pos + 1] != '_');
        if (blind) c.pos += 1;
        return c.add(.{ .tag = if (blind) .lit_i else .lit, .a = start, .b = len });
    }

    fn class(c: *Compiler) CompileError!u32 {
        c.pos += 1;
        var set: std.StaticBitSet(256) = .empty;
        const negate = c.pos < c.src.len and c.src[c.pos] == '^';
        if (negate) c.pos += 1;
        while (true) {
            if (c.pos >= c.src.len) return c.fail();
            if (c.src[c.pos] == ']') break;
            const lo = try c.escaped();
            var hi = lo;
            if (c.pos + 1 < c.src.len and c.src[c.pos] == '-' and c.src[c.pos + 1] != ']') {
                c.pos += 1;
                hi = try c.escaped();
            }
            if (hi < lo) return c.fail();
            set.setRangeValue(.{ .start = lo, .end = @as(usize, hi) + 1 }, true);
        }
        c.pos += 1;
        if (negate) set.toggleAll();
        try c.classes.append(c.arena, set);
        return c.add(.{ .tag = .class, .a = @intCast(c.classes.items.len - 1), .b = 0 });
    }
};

/// One captured match, in preorder. `next` is the row after this subtree, so
/// a node's children are the rows from `i + 1` to `next`, each skipping to
/// its own `next`.
pub const Row = struct { rule: RuleId, start: u32, end: u32, next: u32 };

/// A parse result: the rows and the input they index.
pub const Tree = struct {
    rows: []const Row,
    src: []const u8,

    /// The input bytes row `i` matched.
    pub fn text(t: Tree, i: u32) []const u8 {
        return t.src[t.rows[i].start..t.rows[i].end];
    }

    /// Iterates the direct children of row `i` (or the roots with `i = null`).
    pub fn children(t: Tree, i: ?u32) Children {
        return if (i) |p| .{ .rows = t.rows, .at = p + 1, .end = t.rows[p].next } else .{ .rows = t.rows, .at = 0, .end = @intCast(t.rows.len) };
    }

    /// The first direct child of `i` produced by rule `r`, or null.
    pub fn child(t: Tree, i: u32, r: RuleId) ?u32 {
        var it = t.children(i);
        while (it.next()) |k| if (t.rows[k].rule == r) return k;
        return null;
    }
};

/// Direct-children iterator over `Tree.rows`.
pub const Children = struct {
    rows: []const Row,
    at: u32,
    end: u32,

    /// The next child row, or null after the last.
    pub fn next(it: *Children) ?u32 {
        if (it.at >= it.end) return null;
        const k = it.at;
        it.at = it.rows[k].next;
        assert(it.at > k);
        return k;
    }
};

/// Why a parse failed. `NoMatch`: the start rule did not match the whole
/// input (the furthest byte reached is in `Diag.offset`); `DepthExceeded`:
/// nesting passed `depth_max`.
pub const ParseError = error{ OutOfMemory, NoMatch, DepthExceeded };

/// Parses all of `src` from rule `start`. The rows live in `arena`; a
/// failure leaves the furthest offset any terminal reached in `diag`.
pub fn parse(arena: Allocator, g: Grammar, start: RuleId, src: []const u8, diag: *Diag) ParseError!Tree {
    assert(src.len < std.math.maxInt(u32));
    var p: Parser = .{ .g = g, .src = src, .arena = arena };
    const end = try p.rule(start, 0);
    diag.* = .{ .offset = p.furthest };
    if (end == null or end.? != src.len) return error.NoMatch;
    return .{ .rows = p.rows.items, .src = src };
}

const Parser = struct {
    g: Grammar,
    src: []const u8,
    arena: Allocator,
    rows: std.ArrayList(Row) = .empty,
    depth: u32 = 0,
    furthest: u32 = 0,

    fn rule(p: *Parser, r: RuleId, pos: u32) ParseError!?u32 {
        if (p.depth == depth_max) return error.DepthExceeded;
        p.depth += 1;
        defer p.depth -= 1;
        if (!p.g.captured(r)) return p.match(p.g.rule_bodies[r], pos);
        const at: u32 = @intCast(p.rows.items.len);
        try p.rows.append(p.arena, .{ .rule = r, .start = pos, .end = pos, .next = 0 });
        const end = try p.match(p.g.rule_bodies[r], pos) orelse {
            p.rows.shrinkRetainingCapacity(at);
            return null;
        };
        p.rows.items[at].end = end;
        p.rows.items[at].next = @intCast(p.rows.items.len);
        return end;
    }

    fn reach(p: *Parser, pos: u32) void {
        p.furthest = @max(p.furthest, pos);
    }

    /// Matches node `n` at `pos`: the end offset, or null. A failed match
    /// leaves the rows as it found them.
    fn match(p: *Parser, n: u32, pos: u32) ParseError!?u32 {
        const node = p.g.nodes[n];
        const end: ?u32 = switch (node.tag) {
            .seq => blk: {
                const save = p.rows.items.len;
                var at = pos;
                for (p.g.kids[node.a..][0..node.b]) |k| at = try p.match(k, at) orelse {
                    p.rows.shrinkRetainingCapacity(save);
                    break :blk null;
                };
                break :blk at;
            },
            .choice => blk: {
                for (p.g.kids[node.a..][0..node.b]) |k| if (try p.match(k, pos)) |e| break :blk e;
                break :blk null;
            },
            .star, .plus => blk: {
                var at = pos;
                var count: u32 = 0;
                while (try p.match(node.a, at)) |e| {
                    count += 1;
                    if (e == at) break; // an empty match repeats forever
                    at = e;
                }
                break :blk if (node.tag == .plus and count == 0) null else at;
            },
            .opt => try p.match(node.a, pos) orelse pos,
            .@"and", .not => blk: {
                const save = p.rows.items.len;
                const hit = try p.match(node.a, pos) != null;
                p.rows.shrinkRetainingCapacity(save);
                break :blk if (hit == (node.tag == .@"and")) pos else null;
            },
            .lit, .lit_i => blk: {
                const want = p.g.bytes[node.a..][0..node.b];
                if (p.src.len - pos < want.len) {
                    p.reach(pos);
                    break :blk null;
                }
                const got = p.src[pos..][0..want.len];
                const ok = if (node.tag == .lit) std.mem.eql(u8, got, want) else std.ascii.eqlIgnoreCase(got, want);
                if (!ok) {
                    p.reach(pos);
                    break :blk null;
                }
                break :blk pos + node.b;
            },
            .class => blk: {
                if (pos < p.src.len and p.g.classes[node.a].isSet(p.src[pos])) break :blk pos + 1;
                p.reach(pos);
                break :blk null;
            },
            .any => if (pos < p.src.len) pos + 1 else blk: {
                p.reach(pos);
                break :blk null;
            },
            .ref => try p.rule(@intCast(node.a), pos),
        };
        if (end != null) p.g.hits[n] += 1;
        return end;
    }
};

/// A grammar node that never matched across every parse so far: a rule
/// body, a choice alternative or the inside of a `?`/`*`/`+`.
pub const Gap = struct { rule: []const u8, node: u32 };

/// Every coverage gap in `g`, in rule order. Lexical helpers count too: a
/// rule that cannot be reached is dead spec.
pub fn gaps(arena: Allocator, g: Grammar) Allocator.Error![]Gap {
    var out: std.ArrayList(Gap) = .empty;
    for (g.rule_bodies, g.rule_names) |body, name| try walkGaps(arena, g, body, name, &out, true);
    return out.items;
}

fn walkGaps(arena: Allocator, g: Grammar, n: u32, rule_name: []const u8, out: *std.ArrayList(Gap), counted: bool) Allocator.Error!void {
    if (counted and g.hits[n] == 0) return out.append(arena, .{ .rule = rule_name, .node = n });
    const node = g.nodes[n];
    switch (node.tag) {
        // A sequence matched means each part matched; recurse to find their
        // own optional parts and alternatives.
        .seq => for (g.kids[node.a..][0..node.b]) |k| try walkGaps(arena, g, k, rule_name, out, false),
        .choice => for (g.kids[node.a..][0..node.b]) |k| try walkGaps(arena, g, k, rule_name, out, true),
        .star, .plus, .opt => try walkGaps(arena, g, node.a, rule_name, out, true),
        // A lookahead's operand is judged by its own result: `!x` succeeding
        // never matches x, and that is not a gap.
        .@"and", .not, .lit, .lit_i, .class, .any, .ref => {},
    }
}

/// Renders node `n` back to grammar notation, for gap reports.
pub fn render(w: *std.Io.Writer, g: Grammar, n: u32) std.Io.Writer.Error!void {
    const node = g.nodes[n];
    switch (node.tag) {
        .seq, .choice => {
            try w.writeByte('(');
            for (g.kids[node.a..][0..node.b], 0..) |k, i| {
                if (i > 0) try w.writeAll(if (node.tag == .seq) " " else " / ");
                try render(w, g, k);
            }
            try w.writeByte(')');
        },
        .star, .plus, .opt => {
            try render(w, g, node.a);
            try w.writeByte(switch (node.tag) {
                .star => '*',
                .plus => '+',
                else => '?',
            });
        },
        .@"and", .not => {
            try w.writeByte(if (node.tag == .@"and") '&' else '!');
            try render(w, g, node.a);
        },
        .lit, .lit_i => {
            try w.print("'{f}'", .{std.zig.fmtString(g.bytes[node.a..][0..node.b])});
            if (node.tag == .lit_i) try w.writeByte('i');
        },
        .class => try w.writeAll("[...]"),
        .any => try w.writeByte('.'),
        .ref => try w.writeAll(g.rule_names[node.a]),
    }
}

const testing = std.testing;

test "arithmetic: precedence lands in the tree, case-blind literals, classes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const g = try compile(a,
        \\Sum   <- Prod (ws [+\-] ws Prod)*
        \\Prod  <- Atom (ws '*' ws Atom)*
        \\Atom  <- Num / 'pi'i / '(' ws Sum ws ')'
        \\Num   <- [0-9]+
        \\ws    <- [ \t]*
    , &d);
    const t = try parse(a, g, g.rule("Sum"), "1 + 2*(3-PI)", &d);
    // Sum > Prod(1) Prod(2*(..)) ; the second Prod holds Atom(2) and Atom((..)).
    var roots = t.children(null);
    const sum = roots.next().?;
    try testing.expectEqual(null, roots.next());
    var prods = t.children(sum);
    try testing.expectEqualStrings("1", t.text(prods.next().?));
    const p2 = prods.next().?;
    try testing.expectEqualStrings("2*(3-PI)", t.text(p2));
    try testing.expectEqual(null, prods.next());
    try testing.expectError(error.NoMatch, parse(a, g, g.rule("Sum"), "1 + ", &d));
    try testing.expectEqual(@as(u32, 4), d.offset);
}

test "coverage: an unexercised alternative and optional part are gaps" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const g = try compile(a,
        \\Top <- ('a' / 'b') 'c'?
    , &d);
    _ = try parse(a, g, g.rule("Top"), "a", &d);
    try testing.expectEqual(@as(usize, 2), (try gaps(a, g)).len); // 'b' and 'c'
    _ = try parse(a, g, g.rule("Top"), "bc", &d);
    try testing.expectEqual(@as(usize, 0), (try gaps(a, g)).len);
}

test "grammar errors name the problem" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    try testing.expectError(error.UndefinedRule, compile(a, "A <- B", &d));
    try testing.expectEqualStrings("B", d.name);
    try testing.expectError(error.DuplicateRule, compile(a, "A <- 'x'\nA <- 'y'", &d));
    try testing.expectError(error.GrammarSyntax, compile(a, "A <- 'x", &d));
}

test "nesting past depth_max fails by name, not by stack overflow" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .{};
    const g = try compile(a, "P <- '(' P? ')'", &d);
    const deep = try a.alloc(u8, 2 * depth_max + 2);
    @memset(deep[0 .. depth_max + 1], '(');
    @memset(deep[depth_max + 1 ..], ')');
    try testing.expectError(error.DepthExceeded, parse(a, g, g.rule("P"), deep, &d));
}
