//! The grammar oracle's test root: every `*.peg` here against the frontend.
const std = @import("std");
const netlist = @import("netlist");
pub const peg = @import("peg.zig");
pub const canon = @import("canon.zig");
pub const lines = @import("lines.zig");
pub const corpus = @import("corpus.zig");

test {
    _ = peg;
    _ = lines;
    _ = corpus;
    _ = @import("vec_check.zig");
    _ = @import("include_check.zig");
    _ = @import("data_check.zig");
}

fn grammar(arena: std.mem.Allocator, comptime file: []const u8) !peg.Grammar {
    return grammarOf(arena, &.{file});
}

/// The grammar made of `files` in order: a shared file and a dialect file
/// read as one rule set.
fn grammarOf(arena: std.mem.Allocator, comptime files: []const []const u8) !peg.Grammar {
    comptime var text: []const u8 = "";
    inline for (files) |f| text = text ++ @embedFile(f) ++ "\n";
    var d: peg.Diag = .{};
    return peg.compile(arena, text, &d) catch |err| {
        std.debug.print("{s}: {t} at byte {d} {s}\n", .{ files[files.len - 1], err, d.offset, d.name });
        return err;
    };
}

/// The lines grammar's logical lines of `src`, joined into the card
/// grammar's input: one line per statement, each ended by `\n`.
fn cardText(arena: std.mem.Allocator, lg: peg.Grammar, src: []const u8) ![]const u8 {
    var d: peg.Diag = .{};
    const l = try lines.oracle(arena, lg, src, true, &d);
    var out: std.ArrayList(u8) = .empty;
    for (l.lines) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }
    return out.items;
}

test "ngspice cards: corpus accepts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try grammar(a, "ngspice_lines.peg");
    const g = try grammarOf(a, &.{ "spice_cards.peg", "ngspice.peg" });
    var bad: usize = 0;
    var n: usize = 0;
    for (try corpus.load(a, std.testing.io)) |deck| {
        if (deck.dialect != .ngspice) continue;
        n += 1;
        const text = try cardText(a, lg, deck.src);
        var d: peg.Diag = .{};
        _ = peg.parse(a, g, g.rule("Deck"), text, &d) catch |err| {
            bad += 1;
            const at = d.offset;
            const ls = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |k| k + 1 else 0;
            const le = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
            if (bad <= 40) std.debug.print("{s}: {t} at col {d}: {s}\n", .{ deck.path, err, at - ls, text[ls..le] });
            continue;
        };
    }
    if (bad > 0) {
        std.debug.print("ngspice cards: {d} decks, {d} rejected\n", .{ n, bad });
        return error.Rejected;
    }
}

/// Edge cases of the line rules, each from the dialect's research note.
const line_cases = struct {
    const hspice = [_][]const u8{
        "title\nR1 a b 1k $ comment\n.end\n",
        "title\n$ whole-line comment\nR1 a b 1k\n",
        "title\nR1 a b 1k$c\n",
        "title\nR1 a b 1w$c\n",
        "title\nR1 a$b c 1k\n",
        "title\nR1 a,b 1k,$c\n",
        "t\n.model n1 nmos $ inline\n* comment line\n+ level=3\n",
        "t\nR1 a b \\\n2k\n",
        "t\nR1 a b 1\\\\\nk\n",
        "t\nE1 o 0 vol='a+\\\\\nb'\n",
        "t\nR1 a b 1k\n.END trailing words\nsecond run\nR2 a b 2k\n.end\n",
        "t\nP1 p n port=1\n+ $ ****\n+ dc 1\n",
        "t\nR1 a b\n\n+ 1k\n",
        "t\nr1 a b 'x$y' $ c\n",
        "t\nr1 a b 'x $y' $ c\n",
        "t\nr1 a b 1k $ c \\\\\nr2 a b 1k\n",
        "t\n.param a='1\\\\\n  + 2' $c\n",
        "t\n  * indented comment\n\tR1 a b 1\n",
        "t\nR1 a b 1\n.end\n* between runs\nrun two\nR2 a b 2\n",
        "t\nR1 a b 1\n   \nR2 a b 2\n  ",
        "t\nR1 a b 1\\\\  \n  k\n",
        "t\nR1 a b \\  \n2k\n",
        "t\nR1 a b\n   + 1k\n",
        "t\nR1 a b .5$c\n",
        "t\nR1 a b r=\\\nr2 a b 1\n",
        "t\nR1 a b r=\"x $y\"\n",
        "t\n.param a='1 \\\n+2' b='3\\\\  \n  4'\n",
        "t\r\nR1 a b 1k\r\n",
        "t\nR1 a b 1k",
        "t\n.param s=\"a \\  \nb\"\n",
    };
    const spectre = [_][]const u8{
        "title\nr1 (a b) resistor r=1k // c\n",
        "t\n* star comment\n  * not a comment line\n",
        "t\nr1 (a b) \\\n  resistor r=1k\n",
        "t\nr1 (a b)\n// between\n\n* also\n+ resistor r=1k\n",
        "t\nq1 (c b e) \\2N2222 area=2\n",
        "t\nv1 (a 0) vsource file=\"x//y.txt\" // c\n",
        "t\nr1 (a b) resistor r=1k\nsimulator lang=spice\n* spice comment\nR2 a b 1k $ c\n+ tc1=1\nC1 a 0 1p \\\\\nsimulator lang=spectre\nr3 (a b) resistor r=1\n",
        "t\nsimulator lang=spice\nR1 a b 1k\nSIMULATOR LANG=SPECTRE\nr2 (a b) resistor r=1\n",
        "t\nx1 (a b) sub /* not a comment */\n",
        "t\nr1 (a b) resistor r=1k \\",
        "t\r\nr1 (a b) resistor r=1k\r\n",
        "t\nsimulator lang=spice\n  \n$ c\nR1 a b 1k\n",
        "t\nsimulator  lang = spice\nR1 a b 1k$c\nR2 a b \\\n2k\nR3 a b 1\\\\\nk\nE1 o 0 vol='a $b' $ c\n+ $ only\n\n+ m=1\n  ",
        "t\nsimulator lang=spice\nR1 a b 1k\n  simulator  lang = spectre\nr2 (a b) resistor r=1 // c\n+ m=1 // d\nr3 (a b) \\  \n resistor r=\"q\\\"x\"\n  ",
        "t\nsimulator lang=spicey\nr1 (a b) resistor r=1\n",
        "t\nsimulator lang=spice\nR1 a b 1k \\\\\n2\nR2 a b \"x $y\"\n",
        "t\nsimulator lang=spice\nR1 a b 1.5e3$c\nR2 a b .5$c\nR3 a b 2.$c\n",
        "t\nsimulator lang=spice\nR1 a b -1e+3$c\nR2 a b 1 \\\\\n  k\nR3 a b\n  + 1k\nR4 a b $ c\n  + 1k\n",
        "t\nr3 (a b) \\\n resistor r=1 // c\nx1 (\\\\ b) sub\n",
        "t\nsimulator lang=spice\nR1 a b 1 \\\\  \n  k\nR2 a b \\  \n2k\n",
        "t\nv1 (a 0) vsource file=\"x // y\nr1 (a b) resistor r=1\n",
    };
    const ngspice = [_][]const u8{
        "title\nR1 a b 1k $ comment\n.end\n",
        "title\n# hash comment\n; semicolon comment\n$ dollar comment\nR1 a b 1k\n",
        "title\nR1 a$b c 1k\n",
        "title\nRe 1 0 2k;comment\nR2 1 0 2k // slashes\n",
        "title\nR1 1 0 1k,$c\n",
        "t\n.param s='a $ b' $ c\n",
        "t\n.param s={x $ y}\n",
        "t\nRf 1 0\n* comment between\n   + 3k\n",
        "t\nR1 a b \\\\\n2k\n",
        "t\nR1 a b $ c \\\\\n2k\n",
        "t\nR1 a b 1k\n.end\nR2 a b 2k\n",
        "t\nR1 a b 1k\n@stop\nR2 a b 2k\n",
        "t\n+ stray\nR1 a b 1k\n",
        "t\n= odd\n(paren\nR1 a b 1k\n",
        "t\n.param q=\"it's\" ; c\n",
        "t\n  * indented\nR1 a b 1\n\nR2 a b 2\n  ",
        "t\n   + stray\nR1 a b 1\n  .end of deck\n",
        "t\nR1 a b \\\\  \n   2k $ c\n+ m=1 ; c\n",
        "t\n.param s='x'$y\n",
        "t\nR1 it's 1\n",
        "t\n.param s='a\\'b' t=\"c\\\"d\" $ c\n",
        "t\r\nR1 a b 1k\r\n",
        "t\n.param s='open $ quote\nR1 a b 1\n",
        "t\n.param s=\"open ; quote\nR1 a b 1\n",
    };
};

/// Runs a lines grammar over its edge cases and every corpus deck in its
/// dialect, comparing each reading with the frontend's, then fails on any
/// grammar node no input matched (`peg.gaps`).
fn checkLines(comptime d: netlist.Dialect, comptime file: []const u8, cases: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grammar(a, file);
    var inputs: std.ArrayList(struct { name: []const u8, src: []const u8 }) = .empty;
    for (cases, 0..) |src, i| try inputs.append(a, .{ .name = try std.fmt.allocPrint(a, "case {d}", .{i}), .src = src });
    for (try corpus.load(a, std.testing.io)) |deck| if (deck.dialect == d) try inputs.append(a, .{ .name = deck.path, .src = deck.src });
    var bad: usize = 0;
    for (inputs.items) |in| {
        var diag: peg.Diag = .{};
        const want = lines.oracle(a, g, in.src, netlist.lines.Syntax(d).fold_case, &diag) catch |err| {
            bad += 1;
            std.debug.print("{s}: grammar {t} at byte {d}\n{s}\n", .{ in.name, err, diag.offset, in.src[0..@min(in.src.len, 400)] });
            continue;
        };
        const got = try lines.frontend(a, d, in.src);
        if (!want.eql(got)) {
            bad += 1;
            std.debug.print("{s}: lines differ\n--- input\n{s}--- grammar\n{f}--- frontend\n{f}\n", .{ in.name, in.src[0..@min(in.src.len, 400)], want, got });
        }
    }
    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var buf: std.Io.Writer.Allocating = .init(a);
        try peg.render(&buf.writer, g, h.node);
        std.debug.print("{s}: rule {s}: never matched: {s}\n", .{ file, h.rule, buf.written() });
    }
    if (bad > 0 or holes.len > 0) {
        std.debug.print("{s}: {d} inputs, {d} disagree, {d} coverage gaps\n", .{ file, inputs.items.len, bad, holes.len });
        return error.GrammarCheck;
    }
}

/// The vendored Spectre corpus (tests/grammar/spectre_corpus), each deck
/// after a title line: NetlistParse.rs reads line 1 as a statement.
const NamedDeck = struct { name: []const u8, src: []const u8 };

fn spectreDecks(a: std.mem.Allocator) ![]const NamedDeck {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "tests/grammar/spectre_corpus", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var out: std.ArrayList(NamedDeck) = .empty;
    while (try walker.next(std.testing.io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".scs")) continue;
        const bytes = try dir.readFileAlloc(std.testing.io, e.path, a, .limited(1 << 20));
        try out.append(a, .{ .name = try a.dupe(u8, e.path), .src = try std.mem.concat(a, u8, &.{ "// title\n", bytes }) });
    }
    return out.items;
}

test "spectre lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cases: std.ArrayList([]const u8) = .empty;
    try cases.appendSlice(a, &line_cases.spectre);
    for (try spectreDecks(a)) |d| try cases.append(a, d.src);
    try checkLines(.spectre, "spectre_lines.peg", cases.items);
}

test "spectre lines: exhaustive" {
    try exhaustLines(.spectre, "spectre_lines.peg", "a \\\"+/*\n", 5);
}

test "hspice lines" {
    try checkLines(.hspice, "hspice_lines.peg", &line_cases.hspice);
}

test "ngspice lines" {
    try checkLines(.ngspice, "ngspice_lines.peg", &line_cases.ngspice);
}

/// Every string up to `len_max` bytes over `alphabet`, after a title line:
/// the bounded-exhaustive check of a lines grammar (matklad, "Generate All
/// the Things"). An input the grammar rejects is skipped here; whether the
/// frontend refuses it too is the netlist stage's question.
fn exhaustLines(comptime d: netlist.Dialect, comptime file: []const u8, alphabet: []const u8, len_max: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const g = try grammar(arena.allocator(), file);
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    var digits: [16]u8 = undefined;
    std.debug.assert(len_max <= digits.len);
    var buf: [2 + 16]u8 = undefined;
    buf[0] = 't';
    buf[1] = '\n';
    var checked: usize = 0;
    var bad: usize = 0;
    for (0..len_max + 1) |len| {
        @memset(digits[0..len], 0);
        while (true) {
            for (digits[0..len], buf[2..][0..len]) |k, *c| c.* = alphabet[k];
            const src = buf[0 .. 2 + len];
            _ = scratch.reset(.retain_capacity);
            const a = scratch.allocator();
            var diag: peg.Diag = .{};
            if (lines.oracle(a, g, src, netlist.lines.Syntax(d).fold_case, &diag)) |want| {
                checked += 1;
                const got = try lines.frontend(a, d, src);
                if (!want.eql(got)) {
                    bad += 1;
                    if (bad <= 10) std.debug.print("--- input {f}\n--- grammar\n{f}--- frontend\n{f}\n", .{ std.zig.fmtString(src), want, got });
                }
            } else |_| {}
            // Next string of this length, odometer order.
            var i = len;
            while (i > 0) {
                i -= 1;
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            } else break;
        }
    }
    if (bad > 0) {
        std.debug.print("{s}: {d} of {d} accepted inputs disagree\n", .{ file, bad, checked });
        return error.Mismatch;
    }
}

test "hspice lines: exhaustive" {
    try exhaustLines(.hspice, "hspice_lines.peg", "a1 $*+\\'\",\n", 5);
}

test "ngspice lines: exhaustive" {
    try exhaustLines(.ngspice, "ngspice_lines.peg", "a1 $*+\\';/,@\n", 5);
}

pub const lower = @import("lower.zig");

/// The first differing line of two canonical readings, with context.
fn printDiff(want: []const u8, got: []const u8) void {
    var a = std.mem.splitScalar(u8, want, '\n');
    var b = std.mem.splitScalar(u8, got, '\n');
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return;
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?)) continue;
        std.debug.print("    line {d}\n    grammar:  {s}\n    frontend: {s}\n", .{ i, x orelse "(end)", y orelse "(end)" });
        return;
    }
}

/// One deck through both readers: the grammar's (lines, cards, lowering)
/// and the frontend's (`netlist.parse`, canon.zig), after the same include
/// expansion `prepare` does.
fn compareDeck(a: std.mem.Allocator, comptime d: netlist.Dialect, lg: peg.Grammar, cg: peg.Grammar, path: []const u8, src: []const u8) !enum { same, differ, oracle_refused, frontend_refused, both_refused } {
    const origin = try std.fmt.allocPrint(a, "tests/fixtures/{s}", .{path});
    const runs = try netlist.source.splitAlters(a, src);
    const text = netlist.source.expand(std.testing.io, a, origin, runs[0]) catch return .both_refused;
    var diag: peg.Diag = .{};
    // The oracle's refusal, printed only when the frontend reads the deck.
    var why: std.Io.Writer.Allocating = .init(a);
    const card_text = cardText(a, lg, text) catch |err| blk: {
        try why.writer.print("{s}: lines grammar: {t}\n", .{ path, err });
        break :blk null;
    };
    const low: ?lower.Lowered = if (card_text) |ct| blk: {
        const tree = peg.parse(a, cg, cg.rule("Deck"), ct, &diag) catch |err| {
            const ls = if (std.mem.lastIndexOfScalar(u8, ct[0..diag.offset], '\n')) |k| k + 1 else 0;
            const le = std.mem.indexOfScalarPos(u8, ct, diag.offset, '\n') orelse ct.len;
            try why.writer.print("{s}: card grammar: {t} at col {d}: {s}\n", .{ path, err, diag.offset - ls, ct[ls..le] });
            break :blk null;
        };
        break :blk lower.lower(a, cg, tree, d, &.empty) catch |err| {
            try why.writer.print("{s}: lowering: {t}\n", .{ path, err });
            break :blk null;
        };
    } else null;
    const nl: ?netlist.Netlist = netlist.parse(a, text, d) catch null;
    if (low == null and nl == null) return .both_refused;
    if (low == null) {
        std.debug.print("{s}", .{why.written()});
        return .oracle_refused;
    }
    if (nl == null) return .frontend_refused;
    var out: std.Io.Writer.Allocating = .init(a);
    try canon.write(&out.writer, &nl.?, &low.?.loose);
    if (std.mem.eql(u8, low.?.text, out.written())) return .same;
    printDiff(low.?.text, out.written());
    return .differ;
}

/// `.ic0` files (ic0.peg): HSPICE's own (SA p.910), ESPice's writer's
/// (src/espice.zig `saveOperatingPoint`), and the corpus's.
const ic0_cases = [_][]const u8{
    \\* "simulator" "HSPICE"
    \\* "format" "HSP"
    \\* time= 0.
    \\*** BEGIN: Saved Operating Point ***
    \\.option
    \\+ gmindc= 1.0000p
    \\.nodeset
    \\+ clamp= 2.6200
    \\+ in= 0.
    \\+ vdd= 5.0000
    \\***   END: Saved Operating Point ***
    \\
    ,
    "* rc\n* operating point written by .save\n.nodeset v(clamp)=2.5e-1\n.nodeset v(vdd)=-1.25e0\n",
    "\n.IC V(clamp) = .5\r\n  .ic vdd=2 in=1m  \n.option gmindc=1p \n+ reltol=1e-3\n.nodeset \n+ b= 0.\n",
};

test "hspice .ic0: the grammar reads it, then both readers agree on its cards" {
    std.testing.log_level = .err;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grammar(a, "ic0.peg");
    const lg = try grammar(a, "hspice_lines.peg");
    const cg = try grammarOf(a, &.{ "spice_cards.peg", "hspice.peg" });
    var bad: usize = 0;
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/hspice/load_ic.ic0", a, .unlimited);
    for (ic0_cases ++ [_][]const u8{fixture}) |c| {
        var diag: peg.Diag = .{};
        _ = peg.parse(a, g, g.rule("Ic0File"), c, &diag) catch |err| {
            std.debug.print("ic0.peg: {t} at byte {d}: {f}\n", .{ err, diag.offset, std.zig.fmtString(c) });
            bad += 1;
            continue;
        };
        // Inlined into a deck holding the nodes it names.
        const deck = try std.mem.concat(a, u8, &.{ "t\nv1 vdd 0 5\nr1 vdd clamp 1k\nr2 clamp 0 1k\nr3 in b 1k\nr4 b 0 1k\n", c, "\n.op\n" });
        const v = try compareDeck(a, .hspice, lg, cg, "case", deck);
        if (v != .same) {
            std.debug.print("ic0 case ({t}): {f}\n", .{ v, std.zig.fmtString(c) });
            bad += 1;
        }
    }
    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("ic0.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (bad > 0 or holes.len > 0) return error.Mismatch;
}

/// Card-level decks for rules the corpus does not reach, each compared
/// through both readers like a corpus deck.
const card_cases = struct {
    /// Decks both SPICE dialects read alike.
    const common = [_][]const u8{
        "t\n.parameter p=1\n.parameters q=2\nr1 1 0 p\nr2 1 0 q\n",
        "t\n.temperature 50\n",
        "t\n.temp=27\nr1 1 0 1k\n",
        "t\n.opts reltol=1e-4\nr1 1 0 1k\n",
        "t\n.subckt s a b r=1k\nr1 a b r\n.ends\nx1 1 0 s r=2k\n",
        "t\n.subckt s a b params: r=1k\nr1 a b r\n.ends s\nx1 1 0 s\n",
        "t\n.subckt s params: r=1k\nr1 1 0 r\n.ends\nx1 s\n",
        "t\n.macro m a b\nr1 a b 1k\n.eom\nx1 1 0 m\n",
        "t\n.subckt outer a\n.subckt inner b\nr1 b 0 1k\n.ends inner\nxi a inner\n.ends outer\nx1 1 outer\n",
        "t\n.subckt s a\n.model m1 d is=1e-14\nd1 a 0 m1\n.ends\nx1 1 s\nx2 2 s\n",
        "t\nr1 1 0 1k\n.title other\n.probe v(1)\n.graph v(1)\n.protect\n.unprotect\n.prot\n.unprot\n.store\n.op\n",
        "t\nr1 1 0 1mil\nr2 1 0 2.5meg\nr3 1 0 1d3\nr4 1 0 3a\n",
        "t\nr1 1 0 r = 1k tc1 = 1m\nv1 1 0 sin ( 0 1 1k )\n",
        "t\n.model d1 d ( is = 1e-14 n = 1.5 )\nd1 1 0 d1\n",
        "t\n.model c1 cpl r=1 l=1e-9 c=1e-12 g=0 length=1\n",
        "t\nv1 1 0 1\nr1 1 2 1k\nr2 2 0 1k\n.tf v(2,0) v1\n",
        "t\nv1 1 0 1\nb1 2 0 v=v(1,0)*2\nr1 2 0 1k\n",
        "t\nr1 1 0 1k\n.end\n",
        "t\nr1 1 0 1k\n.stateye\n",
        "t\n.foo bar\nr1 1 0 1k\n",
        "t\nr1 1 0 1k\n.dc temp 0 50 10\n.ac dec 10 1 1meg\n.tran 1n 1u 0 1n uic\n.op\n",
        "t\nm1 d g s b nm l=1u w=2u\n.model nm nmos level=1\nr1 d 0 1k\n",
        "t\nq1 c b e qm\nq2 c b e s qm area=2\n.model qm npn bf=100\n",
        "t\nd1 a k dm\nd2 a k t dm\n.model dm d\n",
        "t\nk1 l1 l2 0.9\nl1 1 0 1u\nl2 2 0 1u\n",
        "t\ne1 o 0 a 0 2\ng1 o 0 a 0 1m\nf1 o 0 vs 2\nh1 o 0 vs 1k\nvs a 0 0\n",
        "t\nt1 a 0 b 0 z0=50 td=1n\nr1 b 0 50\nv1 a 0 1\n",
        "t\ns1 a 0 c 0 sw\n.model sw sw vt=1\nw1 a 0 vs csw\n.model csw csw it=1m\nvs c 0 0\n",
        "t\nr1 1 0 1k\n.param w=1\n.data d w\n1\n2\n.enddata\n",
        "t\nr1 1 0 1k\nc1 1 0 1p\n.variation\n.element_variation\nr r=10%\nc c=5%\n.end_element_variation\n.end_variation\n",
        "t\n.param a=1\n.if a==1\nr1 1 0 1k\n.endif\n",
        "t\n.param a=2\n.if (a==1)\nr1 1 0 1k\n.elseif (a==2)\n.param b=5\nr1 1 0 b\n.else\nr1 1 0 3k\n.endif\n",
        "t\nr1 1 0 1k\n.dcvolt v(1)=1\n.nodeset v(1)=0.5\n.global vdd\n",
        "t\nr1 1 0 1k\n.hdl x.va\n.include y.va\n.inc z.va\n.verilog d.v\n",
        "t\nv1 1 0 1 ac 1\nr1 1 0 1k\n.acphasenoise\n.acmatch\n.acxf\n.dcsens\n.dcinc\n.dcxf\n.fft v(1)\n.hblin\n.lin\n.net\n",
        "t\nv1 1 0 1 ac 1\nr1 1 0 1k\n.ptdnoise\n.snac\n.snnoise\n.snxf\n.sn\n.snosc\n.sp\n.stb\n.tran_noise\n.trannoise\n",
        "t\nv1 1 0 1 ac 1\nr1 1 0 1k\n.disto\n.envelope\n.envlp\n.four 1k v(1)\n.hbac\n.hbnoise\n.hbxf\n.hbosc\n.matex\n.montecarlo\n.mc\n",
        "t\nv1 1 0 1 ac 1\nr1 1 0 1k\n.pac\n.phasenoise\n.pnoise\n.pss\n.pxf\n.qpss\n.sens\n",
        "t\nv1 1 0 1\nr1 1 0 1k\n.tran 1n 10n\n.jitter tran trig v(1) val=0 td=5n\n.dout d 0.5 (2n 0 3n 1)\n.biaschk 'v(1)' max=0.9\n.power v1 from=0 to=1n\n",
        "t\nv1 1 0 1\nr1 1 0 1k\n.check global_level (1 0 80% 20%)\n.sample fs=1meg maxfld=10 beta=0\n.mosra reltotaltime=1e8 simmode=2\n.appendmodel nra mosra n3 nmos\n",
        "t\nr1 b 0 1k\nr2 c 0 1k\n.connect b c\n.pat a2=[b10 b01] r=1\n.print tran v(b)\n.plot tran v(b)\n.width in=72\n",
        "t\nv1 1 0 1\nr1 1 0 1k\n.tran 1n 10n\n.stim tran pwl filename=rc v0=v(1) node1=b node2=0 npoints=5\n.stimuli tran pwl filename=rc v1=v(1) node1=c node2=0 npoints=5\n",

        "t\nr1 b[1] 0 1k\nr2 1 0 1k x=1 tstonefile = net.s2p\n",
        "t\n.model smod s tstonefile=net.s2p citifile=x.citi rlgcfile=y.rlgc\nr1 1 0 1k\n",
        "t\nv1 1 0 pulse(0 1 f(2) 1n)\n.param f(x)=x\nr1 1 0 1k\n",
        "t\nr1 1 0 .5k\nr2 1 0 -1k\n",
        "t\n.options reltol=1e-4\n.opt abstol=1e-12\n.option gmin=1e-12\nr1 1 0 1k\n",
    };
    /// Expression forms, written once per dialect's quoting.
    fn exprs(comptime open: []const u8, comptime close: []const u8) [6][]const u8 {
        return .{
            "t\nr1 1 0 " ++ open ++ "1+2*3**2" ++ close ++ "\nr2 1 0 " ++ open ++ "2^3^2" ++ close ++ "\nr3 1 0 " ++ open ++ "(1<2)&&(3>=3)||0" ++ close ++ "\n",
            "t\nr1 1 0 " ++ open ++ "1==1?5:6" ++ close ++ "\nr2 1 0 " ++ open ++ "!0+1" ++ close ++ "\nr3 1 0 " ++ open ++ "-2^2+10" ++ close ++ "\nr4 1 0 " ++ open ++ "2*-3+10" ++ close ++ "\n",
            "t\nr1 1 0 " ++ open ++ "sqrt(4)+abs(-1)+exp(0)+ln(1)+log10(10)+min(1,2)+max(1,2)+pow(2,3)" ++ close ++ "\n",
            "t\nr1 1 0 " ++ open ++ "sin(0)+cos(0)+tan(0)+atan(0)+tanh(0)+floor(1.5)+ceil(1.5)" ++ close ++ "\n",
            "t\n.param a=1 b=" ++ open ++ "a*2" ++ close ++ " c=-1\nr1 1 0 " ++ open ++ "a+b-c" ++ close ++ "\n.if (a==1)\nr2 1 0 1k\n.elseif (a==2)\nr2 1 0 2k\n.else\nr2 1 0 3k\n.endif\n",
            "t\n.param f(x)=" ++ open ++ "x*2" ++ close ++ "\nr1 1 0 " ++ open ++ "f(3)" ++ close ++ "\n",
        };
    }
    const ngspice = common ++ exprs("{", "}") ++ [_][]const u8{
        "t\nr1 1 0 {7%3}\nr2 1 0 {7\\2}\nr3 1 0 {1<>2}\n",
        "t\nr1 1 0 {sqr(3)+int(2.5)+nint(2.5)+sgn(-2)+sinh(0)+cosh(0)+arctan(0)}\n",
        "t\nr1 1 0 {asin(0)+acos(1)+asinh(0)+acosh(1)+atanh(0)+ternary_fcn(1,2,3)+pwr(2,2)}\n",
        "t\n.func g(x,y) {x+y}\nr1 1 0 {g(1,2)}\n",
        "t\n.param s=\"abc\"\nr1 1 0 1k\n",
        "t\nr1 1 0 'a+1'\n.param a=1\n",
        "t\n.model m1 d is=1e-14 file=\"x.txt\"\nd1 1 0 m1\n",
        "t\nv1 1 0 1\n.save v(1) i(v1) all\n.op\n",
        "t\n.model d1 d is=1e-14 lot/gauss=30% dev=5%\nr1 1 0 1k\n",
        "t\nr1 1 0 {1!=2}\nr2 1 0 {(1<=2)+(2>1)+5/2}\n",
        "t\n.func g ( x , y ) = {x+y}\n.param f ( x , y ) = {x*y} a = 2\nr1 1 0 {g(1,2)+f(2,3)+a}\n",
        "t\n.model smod s tstonefile=\"a/net.s2p\"\nr1 1 0 1k\n",
        "t\nr1 1 0 1k\n.osdi_include x.osdi\n.pre_osdi y.osdi\n.inc z.va\n",
        "t\n.model c1 cpl r={1} l=1e-9 c=1e-12 g=0 length=1\n",
        "t\nr1 1 0 1k \"x\"\nv1 1 0 pulse(0 {1} \"x\" 1n)\n",
        "t\n.control\nrun\n.endc\nr1 1 0 1k\n",
        "t\n.model d1 d is=1e-14 lot/gauss = 30% dev = 5%\nr1 1 0 1k\n",
    };
    const hspice = common ++ exprs("'", "'") ++ [_][]const u8{
        "t\nr1 1 0 \"1+2\"\n",
        "t\np1 a 0 port=1 z0=50 hblin=[1, -1]\nr1 a 0 50\n",
        "t\nw1 a 0 b 0 n=1 l=0.1 rlgcfile=\"x.rlgc\"\n",
        "t\ns1 a 0 b 0 mname=smod\n.model smod s tstonefile=net.s2p\n",
        "t\nr1 1 0 1x\nr2 1 0 2mil\n",
        "t\nr1 1 0 '1!=2'\nr2 1 0 '(1<=2)+(2>1)+5/2'\n",
        "t\n.model c1 cpl r = '1' l = 1e-9 c=1e-12 g=0 length=1\n",
        "t\n.control\nrun\n.endc\nr1 1 0 1k\n.save\n",
        "t\np1 a 0 port=1 hblin = [ 1 , -1 ]\nr1 a 0 50\nv1 b 0 pulse(0 '1' sin(1) 1n)\n",
        "t\n.param s=\"a b\"\nr1 1 0 1k\n",
        "t\n.func g ( x , y ) 'x+y'\n.param f ( x , y ) = 'x*y' a = 2\nr1 1 0 'g(1,2)+f(2,3)+a'\n",
        "t\nr1 1 0 1k\n.save level=none\n.osdi_include x.osdi\n.pre_osdi y.osdi\n",
        "t\n.model m nmos level=1 version=4.5.0\nr1 1 0 1k\n",
        "t\n.model d1 d is=1e-14 lot/gauss = 30% dev = 5%\nr1 1 0 1k\n",
        "t\n.func g(x) = 'x*2'\nr1 1 0 10kohm\nr2 1 0 'g(1)'\n",
    };
};

/// Every corpus deck in dialect `d` through both readers; fails on any
/// deck where they disagree or only one refuses.
fn checkNetlistCorpus(comptime d: netlist.Dialect, comptime lines_file: []const u8, comptime card_files: []const []const u8, cases: []const []const u8) !void {
    // The frontend warns on cards it reads and sets aside; the comparison
    // reports what matters. The runner resets this per test.
    std.testing.log_level = .err;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try grammar(a, lines_file);
    const cg = try grammarOf(a, card_files);
    const Verdict = @typeInfo(@typeInfo(@TypeOf(compareDeck)).@"fn".return_type.?).error_union.payload;
    var counts = std.EnumArray(Verdict, usize).initFill(0);
    for (try corpus.load(a, std.testing.io)) |deck| {
        if (deck.dialect != d) continue;
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        const verdict = try compareDeck(scratch.allocator(), d, lg, cg, deck.path, deck.src);
        counts.getPtr(verdict).* += 1;
        if (verdict != .same and verdict != .both_refused) std.debug.print("{s}: {t}\n", .{ deck.path, verdict });
    }
    for (cases) |src| {
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        const verdict = try compareDeck(scratch.allocator(), d, lg, cg, "case", src);
        counts.getPtr(verdict).* += 1;
        if (verdict != .same and verdict != .both_refused) std.debug.print("--- case ({t})\n{s}\n", .{ verdict, src });
    }
    const holes = try peg.gaps(a, cg);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, cg, h.node);
        std.debug.print("{t} cards: rule {s}: never matched: {s}\n", .{ d, h.rule, w.written() });
    }
    if (counts.get(.differ) + counts.get(.oracle_refused) + counts.get(.frontend_refused) + holes.len > 0) {
        var it = counts.iterator();
        while (it.next()) |e| std.debug.print("{t} {t}: {d}\n", .{ d, e.key, e.value.* });
        return error.Mismatch;
    }
}

test "ngspice netlist: corpus" {
    try checkNetlistCorpus(.ngspice, "ngspice_lines.peg", &.{ "spice_cards.peg", "ngspice.peg" }, &card_cases.ngspice);
}

test "hspice netlist: corpus" {
    try checkNetlistCorpus(.hspice, "hspice_lines.peg", &.{ "spice_cards.peg", "hspice.peg" }, &card_cases.hspice);
}

pub const data = @import("data.zig");
const wfit = @import("wfit");
const sparam = wfit.sparam;

/// Touchstone edge cases, each from dev/research/data-file-syntax.md §1.
const touchstone_cases = [_]struct { ports: usize, src: []const u8 }{
    .{ .ports = 1, .src = "! pad\n# MHz S RI R 50\n1 0 0\n2 0 0\n" },
    .{ .ports = 1, .src = "#MHz S RI R 50\n1 0 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n# GHz Y MA R 75\n1 0 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\r1 0 0 ! c\r2 0 0\r" },
    .{ .ports = 1, .src = "# Hz S RI R 50\r\n1 0 0\r\n" },
    .{ .ports = 1, .src = "1 0 0\n# Hz S RI R 50\n2 0 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n1 nan 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n1 1k 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n2 0 0\n1 0 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n1 0 0\n2 0\n" },
    .{ .ports = 1, .src = "# Hz H RI R 50\n1 0 0\n" },
    .{ .ports = 1, .src = "#\n1 0 0\n" },
    .{ .ports = 1, .src = "# GHz S MA R 50\n1 0.5 90\n" },
    .{ .ports = 1, .src = "# kHz Z DB R 75.5\n1e3 -6 90\n2.5E3 +.5 -45.\n" },
    .{ .ports = 1, .src = "[Version] 2.0\n1 0 0\n" },
    .{ .ports = 1, .src = "  \n! only a comment\n" },
    .{ .ports = 1, .src = "# Hz S RI R 0\n1 0 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R\n1 0 0\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n  1   0   0  ! trailing\n\n" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n1 0 0" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n1 0 0 ! c" },
    .{ .ports = 1, .src = "# Hz S RI R 50\n1 0 0\n  " },
    .{ .ports = 2, .src = "# Hz S RI R 50\n1 0 0 0.5 0 0.5 0 0 0\n2 0 0 0.5 0 0.5 0 0 0\n2 2.0 0.5 0 0.1\n" },
    .{ .ports = 2, .src = "# Hz S RI R 50\n1 0 0 0.5 0 0.5 0 0 0\n2 0 0 0.5 0 0.5 0 0 0\n1 2.0 0.5 0\n" },
    .{ .ports = 2, .src = "# Hz S RI R 50\n1 0 0 0.5 0\n0.5 0 0 0\n" },
};

fn touchstoneVerdict(a: std.mem.Allocator, g: peg.Grammar, src: []const u8, ports: usize) !?[]const u8 {
    var d: peg.Diag = .{};
    const want: ?sparam.Raw = if (peg.parse(a, g, g.rule("File"), src, &d)) |t| data.touchstone(a, g, t, ports) catch null else |_| null;
    const got: ?sparam.Raw = sparam.readTouchstone(a, src, ports) catch null;
    if (want == null and got == null) return null;
    if (want == null) return "grammar refuses, frontend reads";
    if (got == null) return "frontend refuses, grammar reads";
    if (!data.sameRaw(want.?, got.?)) return "readings differ";
    return null;
}

test "touchstone: cases, corpus, exhaustive, coverage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grammar(a, "touchstone.peg");
    var bad: usize = 0;
    for (touchstone_cases) |c| if (try touchstoneVerdict(a, g, c.src, c.ports)) |why| {
        bad += 1;
        std.debug.print("touchstone {f}: {s}\n", .{ std.zig.fmtString(c.src), why });
    };
    const net = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/hspice/s_element.assets/net.s2p", a, .limited(1 << 20));
    if (try touchstoneVerdict(a, g, net, 2)) |why| {
        bad += 1;
        std.debug.print("net.s2p: {s}\n", .{why});
    }
    // Every string up to 6 bytes over the bytes the rules turn on.
    const alphabet = "#1. -!\nhr";
    var digits: [6]u8 = undefined;
    var buf: [6]u8 = undefined;
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    for (0..digits.len + 1) |len| {
        @memset(digits[0..len], 0);
        while (true) {
            for (digits[0..len], buf[0..len]) |k, *ch| ch.* = alphabet[k];
            _ = scratch.reset(.retain_capacity);
            if (try touchstoneVerdict(scratch.allocator(), g, buf[0..len], 1)) |why| {
                bad += 1;
                if (bad <= 20) std.debug.print("touchstone {f}: {s}\n", .{ std.zig.fmtString(buf[0..len]), why });
            }
            var i = len;
            while (i > 0) {
                i -= 1;
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            } else break;
        }
    }
    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("touchstone.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (bad > 0 or holes.len > 0) return error.GrammarCheck;
}

fn rlgcVerdict(a: std.mem.Allocator, g: peg.Grammar, src: []const u8) !?[]const u8 {
    _ = a;
    var d: peg.Diag = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const want = if (peg.parse(arena.allocator(), g, g.rule("File"), src, &d)) |t| data.rlgc(g, t) else |_| error.Refused;
    const got = wfit.readRlgcFile(src);
    if (want) |w| {
        const r = got catch return "frontend refuses, grammar reads";
        if (w.n != r.n or w.mats != r.mats or !std.meta.eql(w.tri, r.tri)) return "readings differ";
    } else |we| {
        const ge = if (got) |_| return "grammar refuses, frontend reads" else |e| e;
        // ESPice's conductor limit is its own error on both sides.
        if ((we == error.TooManyConductors) != (ge == error.TooManyConductors)) return "refusals differ";
    }
    return null;
}

test "rlgc: cases, corpus, exhaustive, coverage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try grammar(a, "rlgc.peg");
    const cases = [_][]const u8{
        "* one line\n1\n2.5e-7 * L\n1e-10, 5\n", "2 (1 2 3) [4 5 6]", "5 1 2", "", "1.5 1 2", "1 1",
        "2 1 2 3 4",                                "1 1 2 3 4 5 6 7",    "1 1n 2", "1 nan 2", "1;2;3", "1\t{2}\r\n3 *c",
        "+1 -2e-3 .5",
    };
    var bad: usize = 0;
    for (cases) |c| if (try rlgcVerdict(a, g, c)) |why| {
        bad += 1;
        std.debug.print("rlgc {f}: {s}\n", .{ std.zig.fmtString(c), why });
    };
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "tests/fixtures", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |e| {
        if (e.kind != .file or !(std.mem.endsWith(u8, e.path, ".rlgc") or std.mem.endsWith(u8, e.path, ".rlc"))) continue;
        const bytes = try dir.readFileAlloc(std.testing.io, e.path, a, .limited(1 << 20));
        if (try rlgcVerdict(a, g, bytes)) |why| {
            bad += 1;
            std.debug.print("{s}: {s}\n", .{ e.path, why });
        }
    }
    const alphabet = "12 *n\n.,";
    var digits: [6]u8 = undefined;
    var buf: [6]u8 = undefined;
    for (0..digits.len + 1) |len| {
        @memset(digits[0..len], 0);
        while (true) {
            for (digits[0..len], buf[0..len]) |k, *ch| ch.* = alphabet[k];
            if (try rlgcVerdict(a, g, buf[0..len])) |why| {
                bad += 1;
                if (bad <= 20) std.debug.print("rlgc {f}: {s}\n", .{ std.zig.fmtString(buf[0..len]), why });
            }
            var i = len;
            while (i > 0) {
                i -= 1;
                digits[i] += 1;
                if (digits[i] < alphabet.len) break;
                digits[i] = 0;
            } else break;
        }
    }
    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("rlgc.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (bad > 0 or holes.len > 0) return error.GrammarCheck;
}

/// Spectre decks for rules the corpus does not reach, each through both
/// readers like a corpus deck (title line first).
const spectre_cases = [_][]const u8{
    "t\nsimulator lang = spice insensitive=yes\nR1 a 0 1k\nsimulator lang = spectre\nr2 (a 0) resistor r=1\n",
    "t\ninclude \"x.scs\" section=tt\n",
    "t\nlibrary lib\nsection tt\nr1 (a 0) resistor r=1\nendsection tt\nendlibrary lib\n",
    "t\nmodel nch bsim4 type=n {\n1: lmin=1u lmax=2u wmin=1u wmax=10u vth0=0.5\nb2 : lmin=2u lmax=4u wmin=1u wmax=10u vth0=0.4\n}\nm1 (d g 0 0) nch w=2u l=1.5u\n",
    "t\nreal f( real a , real b ) { return a+b*2 ; }\nr1 (a 0) resistor r=f(1,2)\n",
    "t\nreal g(real a) {\nreturn a*3\n}\nr1 (a 0) resistor r=g(2)\n",
    "t\nr1 (a 0) resistor r=1\nsave a depth=2 r1:1\nic a = 1\nnodeset a = 0.5\n",
    "t\nparameters x=1\nif (x == 1) {\nr1 (a 0) resistor r=1\n} else {\nr1 (a 0) resistor r=2\n}\n",
    "t\nparameters x=2\nif (x == 1) r1 (a 0) resistor r=1 else r1 (a 0) resistor r=2\n",
    "t\nparameters x=2\nif (x == 1) r1 (a 0) resistor r=1 else if (x == 2) r1 (a 0) resistor r=3 else r1 (a 0) resistor r=2\n",
    "err_ else opening a line, refused by both\nparameters x=1\nif (x == 1) {\nr1 (a 0) resistor r=1\n}\nelse {\nr1 (a 0) resistor r=2\n}\n",
    "t\nstatistics {\nprocess {\nvary rsh dist=gauss std=12 percent=yes\n}\nmismatch {\nvary xisn dist=gauss std=0.5\n}\ncorrelate param=[rsh xisn] cc=0.6\ntruncate tr=6.0\n}\nr1 (a 0) resistor r=1\n",
    "t\nv1 (a 0) vsource dc=1 mag=1\nr1 (a 0) resistor r=1\nswp sweep param=temp values=[0 50] {\nop1 dc\n}\n",
    "t\nv1 (a 0) vsource dc=1\nr1 (a 0) resistor r=1\na1 acmatch\na2 dcmatch\na3 envlp\na4 hbac\na5 hbnoise\na6 hbsp\na7 hbstb\na8 hbxf\na9 hb\n",
    "t\nv1 (a 0) vsource dc=1\nr1 (a 0) resistor r=1\nb1 pac\nb2 pnoise\nb3 psp\nb4 pss\nb5 pstb\nb6 pxf\nb7 pz\nb8 qpac\nb9 qpnoise\n",
    "t\nv1 (a 0) vsource dc=1\nr1 (a 0) resistor r=1\nc1 qpsp\nc2 qpss\nc3 qpxf\nc4 sp\nc5 stb\nc6 tdr\nc7 xf\nc8 fourier\nc9 pdisto\nc10 sens\nc11 montecarlo\n",
    "t\ninclude \"x.scs\" section = tt\n",
    "t\ninclude \"a\\\"b.scs\"\n",
    "t\nsubckt inv ( a b )\nr1 (a b) resistor r=1\nends inv\nx1 (p q) inv\n",
    "t\nreal h (real a) { return a }\nc1 (a 0) capacitor (c=10E-12)\nr1 (a 0) resistor ( r=h(2) )\n",
    "t\nparameters p=( 2 ** 3 ) + - 1 + max ( 1 , 2 )\nr1 (a 0) resistor r=p\n",
    "t\nmodel \\2n2222 bjt\nq1 (c b 0) \\2n2222\n",
    "t\nmodel q\\-1 bjt\nq1 (c b 0) q\\-1\n",
    "t\nsubckt cell (a)\nparameters k=2\nr1 (a 0) resistor r=k\nends\nx1 (n) cell\nr2 (n 0) resistor r=x1.k\n",
    "t\nv1 (a 0) vsource dc=1\nr1 (a 0) resistor r=1\nswp sweep param=temp values=[0, 50] {\nop1 dc\n}\n",
    "t\nr1 (a 0) resistor r=1\nalt1 altergroup {\nr1 (a 0) resistor r=2\n}\nk1 alter param=temp value=27\nk2 assert\nk3 checklimit\nk4 check what=all\nk5 info what=oppoint\nk6 paramset\nk7 paramtest\nk8 set\nk9 shell\n",
};

/// NetlistParse.rs decks the Spectre grammar reads otherwise, and why. The
/// test fails if one of them starts to agree, so the list stays true.
const spectre_divergences = std.StaticStringMap([]const u8).initComptime(.{
    .{ "params_expr/base_specifiers.scs", "Verilog-style bases (8'hFF): not Spectre, not read" },
    .{ "params_expr/op_chains.scs", "bitwise and shift operators: not read by ESPice" },
    .{ "params_expr/relational_logical.scs", "bitwise operators: not read by ESPice" },
    .{ "params_expr/reduction_nor_nand.scs", "reduction operators: not read by ESPice" },
    .{ "params_expr/shift_reduction.scs", "shift operators: not read by ESPice" },
    .{ "julia_parse_tests/var_reference.scs", "bitwise operators: not read by ESPice" },
    .{ "model/bare_param.scs", "a bare flag parameter: NetlistParse.rs's relaxation, not Cadence's" },
    .{ "instance/trailing_bare_param.scs", "a trailing bare word: NetlistParse.rs's relaxation" },
    .{ "include_global/lenient_section_empty.scs", "an empty section=: NetlistParse.rs's relaxation" },
    .{ "protect/protect_block.scs", "an encrypted protect block: refused" },
    .{ "conditional/err_braceless.scs", "a braceless if body: Cadence allows one statement (R19 p.491)" },
});

test "spectre cards: corpus accepts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try grammar(a, "spectre_lines.peg");
    const g = try grammar(a, "spectre.peg");
    var bad: usize = 0;
    var decks: std.ArrayList(NamedDeck) = .empty;
    try decks.appendSlice(a, try spectreDecks(a));
    for (spectre_cases) |c| try decks.append(a, .{ .name = c, .src = c });
    for (decks.items) |deck| {
        const err_deck = std.mem.indexOf(u8, deck.name, "err_") != null;
        var d: peg.Diag = .{};
        const l = try lines.oracle(a, lg, deck.src, false, &d);
        var text: std.ArrayList(u8) = .empty;
        for (l.lines) |line| {
            try text.appendSlice(a, line);
            try text.append(a, '\n');
        }
        const ok = if (peg.parse(a, g, g.rule("SDeck"), text.items, &d)) |_| true else |_| false;
        if (spectre_divergences.get(deck.name)) |why| {
            if (ok != err_deck) {
                bad += 1;
                std.debug.print("{s}: listed as a divergence ({s}) but agrees\n", .{ deck.name, why });
            }
            continue;
        }
        if (ok == err_deck) {
            bad += 1;
            const at = @min(d.offset, text.items.len);
            const ls = if (std.mem.lastIndexOfScalar(u8, text.items[0..at], '\n')) |k| k + 1 else 0;
            const le = std.mem.indexOfScalarPos(u8, text.items, at, '\n') orelse text.items.len;
            std.debug.print("{s}: {s} at col {d}: {s}\n", .{ deck.name, if (ok) "accepted" else "rejected", at - ls, text.items[ls..le] });
        }
    }
    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("spectre.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (bad > 0 or holes.len > 0) {
        std.debug.print("spectre cards: {d} decks disagree with NetlistParse.rs, {d} coverage gaps\n", .{ bad, holes.len });
        return error.Mismatch;
    }
}

pub const lower_spectre = @import("lower_spectre.zig");

/// One Spectre deck through both readers: the grammar's (lines, statements,
/// the oracle's translation, then the SPICE oracle) and the frontend's.
fn compareSpectre(a: std.mem.Allocator, lg: peg.Grammar, sg: peg.Grammar, cg: peg.Grammar, name: []const u8, src: []const u8) !enum { same, differ, oracle_refused, frontend_refused, both_refused } {
    var diag: peg.Diag = .{};
    // The oracle's refusal, printed only when the frontend reads the deck.
    var why: std.Io.Writer.Allocating = .init(a);
    const low: ?lower.Lowered = blk: {
        const l = lines.oracle(a, lg, src, false, &diag) catch break :blk null;
        var text: std.ArrayList(u8) = .empty;
        for (l.lines) |line| {
            try text.appendSlice(a, line);
            try text.append(a, '\n');
        }
        const tree = peg.parse(a, sg, sg.rule("SDeck"), text.items, &diag) catch break :blk null;
        const tr = lower_spectre.translate(a, sg, tree) catch |err| {
            try why.writer.print("{s}: oracle translation: {t}\n", .{ name, err });
            break :blk null;
        };
        const ct = peg.parse(a, cg, cg.rule("Deck"), tr.text, &diag) catch |err| {
            try why.writer.print("{s}: oracle cards: {t} at {d}\n{s}\n", .{ name, err, diag.offset, tr.text });
            break :blk null;
        };
        break :blk lower.lower(a, cg, ct, .spectre, &tr.kinds) catch |err| {
            try why.writer.print("{s}: oracle lowering: {t}\n{s}\n", .{ name, err, tr.text });
            break :blk null;
        };
    };
    const nl: ?netlist.Netlist = netlist.parse(a, src, .spectre) catch |err| blk: {
        // Name where the frontend's rewrite stops, for the report.
        var dl: peg.Diag = .{};
        if (lines.oracle(a, lg, src, false, &dl)) |l| {
            var kinds: netlist.spectre_rewrite.Kinds = .empty;
            for (l.lines, 0..) |_, i| {
                _ = netlist.spectre_rewrite.translate(a, l.lines[0 .. i + 1], &kinds) catch |e| {
                    if (e != error.ParseError or i + 1 == l.lines.len) {
                        if (low != null) std.debug.print("{s}: frontend: {t} ({t}) at: {s}\n", .{ name, err, e, l.lines[i] });
                        break;
                    }
                    continue;
                };
            }
        } else |_| {}
        break :blk null;
    };
    if (low == null and nl == null) return .both_refused;
    if (low == null) {
        std.debug.print("{s}", .{why.written()});
        return .oracle_refused;
    }
    if (nl == null) return .frontend_refused;
    var out: std.Io.Writer.Allocating = .init(a);
    try canon.write(&out.writer, &nl.?, &low.?.loose);
    if (std.mem.eql(u8, low.?.text, out.written())) return .same;
    printDiff(low.?.text, out.written());
    return .differ;
}

test "spectre netlist: corpus" {
    // The frontend warns on cards it reads and sets aside; the comparison
    // reports what matters. The runner resets this per test.
    std.testing.log_level = .err;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lg = try grammar(a, "spectre_lines.peg");
    const sg = try grammar(a, "spectre.peg");
    const cg = try grammarOf(a, &.{ "spice_cards.peg", "hspice.peg" });
    const Verdict = @typeInfo(@typeInfo(@TypeOf(compareSpectre)).@"fn".return_type.?).error_union.payload;
    var counts = std.EnumArray(Verdict, usize).initFill(0);
    var decks: std.ArrayList(NamedDeck) = .empty;
    try decks.appendSlice(a, try spectreDecks(a));
    for (spectre_cases) |c| try decks.append(a, .{ .name = c, .src = c });
    for (decks.items) |deck| {
        var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer scratch.deinit();
        const v = try compareSpectre(scratch.allocator(), lg, sg, cg, deck.name, deck.src);
        counts.getPtr(v).* += 1;
        if (v != .same and v != .both_refused) std.debug.print("{s}: {t}\n", .{ deck.name, v });
    }
    if (counts.get(.differ) + counts.get(.oracle_refused) + counts.get(.frontend_refused) > 0) {
        var it = counts.iterator();
        while (it.next()) |e| std.debug.print("spectre {t}: {d}\n", .{ e.key, e.value.* });
        return error.Mismatch;
    }
}
