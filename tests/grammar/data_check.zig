//! tests/grammar/extdata.peg -> the table an external `.data` card stands
//! for, checked against `netlist.source.expand` (which writes it out as an
//! inline `.data` block) on the corpus decks, targeted cases and
//! bounded-exhaustive cards and data files. The oracle merges by CR .DATA
//! p.69-70 on its own: MER stacks the files' rows, a later file inheriting
//! the earlier file's columns; LAM sets the files side by side, each name
//! from the last file that gives it; a missing value is 0. Cells are
//! compared as text, since both sides copy them.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const netlist = @import("netlist");
const peg = @import("peg.zig");

fn grammar(a: Allocator) !peg.Grammar {
    var d: peg.Diag = .{};
    return peg.compile(a, @embedFile("extdata.peg"), &d) catch |err| {
        std.debug.print("extdata.peg: {t} at byte {d} {s}\n", .{ err, d.offset, d.name });
        return err;
    };
}

/// A merged table: its names, then its rows of cells (text), or null when
/// the reader refuses the card.
const Table = ?struct { names: []const []const u8, rows: []const []const []const u8 };

/// One data file, as the oracle reads it: its rows, or null when a cell is
/// not a number.
fn readFile(a: Allocator, g: peg.Grammar, text: []const u8) !?[]const []const []const u8 {
    var d: peg.Diag = .{};
    const t = peg.parse(a, g, g.rule("ExtFile"), text, &d) catch |err| switch (err) {
        error.NoMatch => return null,
        else => return err,
    };
    var rows: std.ArrayList([]const []const u8) = .empty;
    var top = t.children(null);
    var it = t.children(top.next().?);
    while (it.next()) |r| {
        if (t.rows[r].rule != g.rule("Row")) continue;
        var cells: std.ArrayList([]const u8) = .empty;
        var c = t.children(r);
        while (c.next()) |k| try cells.append(a, t.text(k));
        try rows.append(a, cells.items);
    }
    return rows.items;
}

fn unquote(s: []const u8) []const u8 {
    return if (s.len >= 2 and (s[0] == '\'' or s[0] == '"')) s[1 .. s.len - 1] else s;
}

/// The oracle: the card's tree, its files read from `dir`, merged.
fn oracle(a: Allocator, io: Io, g: peg.Grammar, dir: []const u8, card: []const u8) !Table {
    var d: peg.Diag = .{};
    const t = peg.parse(a, g, g.rule("Block"), card, &d) catch |err| switch (err) {
        error.NoMatch => return null,
        else => return err,
    };
    const File = struct { rows: []const []const []const u8, cols: std.ArrayList(u32) };
    var names: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(File) = .empty;
    var lam = false;
    var it = t.children(null);
    const block = it.next().?;
    var kids = t.children(block);
    while (kids.next()) |k| {
        const r = t.rows[k].rule;
        if (r == g.rule("Mode")) lam = std.ascii.eqlIgnoreCase(t.text(k), "lam");
        if (r == g.rule("Out")) return null;
        if (r != g.rule("FileGroup")) continue;
        var parts = t.children(k);
        const path = try std.fs.path.join(a, &.{ dir, unquote(t.text(parts.next().?)) });
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return null;
        const rows = (try readFile(a, g, text)) orelse return null;
        var cols: std.ArrayList(u32) = .empty;
        if (!lam and files.items.len > 0) try cols.appendSlice(a, files.items[files.items.len - 1].cols.items);
        while (parts.next()) |p| {
            const key = t.text(t.child(p, g.rule("Key")).?);
            const col = std.fmt.parseInt(u32, t.text(t.child(p, g.rule("Col")).?), 10) catch return null;
            if (col == 0) return null;
            const n = for (names.items, 0..) |name, i| {
                if (std.ascii.eqlIgnoreCase(name, key)) break i;
            } else blk: {
                try names.append(a, key);
                break :blk names.items.len - 1;
            };
            if (cols.items.len <= n) try cols.appendNTimes(a, 0, n + 1 - cols.items.len);
            cols.items[n] = col;
        }
        try files.append(a, .{ .rows = rows, .cols = cols });
    }
    if (names.items.len == 0) return null;
    const at = struct {
        fn cell(f: File, r: usize, n: usize) []const u8 {
            if (r >= f.rows.len or n >= f.cols.items.len or f.cols.items[n] == 0) return "0";
            const col = f.cols.items[n];
            return if (col <= f.rows[r].len) f.rows[r][col - 1] else "0";
        }
    };
    var out: std.ArrayList([]const []const u8) = .empty;
    if (lam) {
        var rows: usize = 0;
        for (files.items) |f| rows = @max(rows, f.rows.len);
        for (0..rows) |r| {
            const row = try a.alloc([]const u8, names.items.len);
            for (row, 0..) |*v, n| {
                v.* = "0";
                for (files.items) |f| if (n < f.cols.items.len and f.cols.items[n] != 0) {
                    v.* = at.cell(f, r, n);
                };
            }
            try out.append(a, row);
        }
    } else for (files.items) |f| for (0..f.rows.len) |r| {
        const row = try a.alloc([]const u8, names.items.len);
        for (row, 0..) |*v, n| v.* = at.cell(f, r, n);
        try out.append(a, row);
    };
    return .{ .names = names.items, .rows = out.items };
}

/// The frontend: the deck expanded, its `.data` block read back.
fn frontend(a: Allocator, io: Io, origin: []const u8, card: []const u8) !Table {
    const deck = try std.mem.concat(a, u8, &.{ "t\n", card });
    const text = netlist.source.expand(io, std.heap.page_allocator, a, origin, deck) catch return null;
    var names: []const []const u8 = &.{};
    var rows: std.ArrayList([]const []const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const head = f.next() orelse continue;
        var rest: std.ArrayList([]const u8) = .empty;
        while (f.next()) |v| try rest.append(a, v);
        if (std.mem.eql(u8, head, ".data")) names = rest.items[1..];
        if (std.mem.eql(u8, head, "+")) try rows.append(a, rest.items);
    }
    return .{ .names = names, .rows = rows.items };
}

fn same(x: Table, y: Table) bool {
    if (x == null or y == null) return x == null and y == null;
    const p = x.?;
    const q = y.?;
    if (p.names.len != q.names.len or p.rows.len != q.rows.len) return false;
    for (p.names, q.names) |m, n| if (!std.mem.eql(u8, m, n)) return false;
    for (p.rows, q.rows) |r, s| {
        if (r.len != s.len) return false;
        for (r, s) |u, v| if (!std.mem.eql(u8, u, v)) return false;
    }
    return true;
}

fn check(a: Allocator, io: Io, g: peg.Grammar, dir: []const u8, card: []const u8) !bool {
    const origin = try std.fs.path.join(a, &.{ dir, "deck.sp" });
    const want = try oracle(a, io, g, dir, card);
    const got = try frontend(a, io, origin, card);
    if (same(want, got)) return true;
    std.debug.print("--- .data card {f}\n", .{std.zig.fmtString(card)});
    for ([_]Table{ want, got }, [_][]const u8{ "oracle", "frontend" }) |x, who| {
        std.debug.print("  {s}:", .{who});
        const v = x orelse {
            std.debug.print(" refused\n", .{});
            continue;
        };
        for (v.names) |n| std.debug.print(" {s}", .{n});
        for (v.rows) |r| {
            std.debug.print(" |", .{});
            for (r) |c| std.debug.print(" {s}", .{c});
        }
        std.debug.print("\n", .{});
    }
    return false;
}

const data_files = [_][2][]const u8{
    .{ "a.txt", "1 2\n3,4\n" },
    .{ "b.txt", "5 6 7\n" },
    .{ "c.txt", "* header\n$ x y\n-1.5k 2e-3\n\n8\n" },
    .{ "h.txt", "x y\n1 2\n" },
    .{ "n.txt", "1e+ 2\n" },
};

/// Cards for each rule of extdata.peg (CR .DATA p.64-70).
const cases = [_][]const u8{
    // The corpus decks' shapes (tests/fixtures/variants/data_{mer,lam}.sp).
    ".data d MER\n+ FILE='a.txt' y=2 x=1\n+ FILE='b.txt' y=1 x=3\n+ FILE='c.txt'\n.enddata\n",
    ".data d LAM\n+ FILE='a.txt' x=1\n+ FILE='b.txt' y=3\n.enddata\n",
    // Bare lines, `FILE=` on the `.data` line, bare and double-quoted names.
    ".data d mer FILE=a.txt x=1\nFILE=\"b.txt\" y = 2\n.ENDDATA\n",
    ".data d MER\n* comment\n\n+FILE='a.txt' x=1 $ note\n+ ; none\n.enddata trailing\n",
    // Indented and blank lines, a long key, CRLF line ends.
    ".data d MER\n  \n  * c\n  + FILE='a.txt' rl_2=1\n.enddata\n",
    ".data d MER\r\n+ FILE='a.txt' x=1\r\n.enddata\r\n",
    // MER inheritance, short rows (0), duplicate names (the last wins),
    // names case-insensitive (the first spelling kept).
    ".data d MER\n+ FILE='b.txt' x=3 x=1 Y=2\n+ FILE='a.txt' y=1\n.enddata\n",
    // LAM: more rows in one file, a name given by two files.
    ".data d LAM\n+ FILE='c.txt' x=1 y=2\n+ FILE='b.txt' y=3\n.enddata\n",
    // Refusals: OUT=, column 0, a pair before FILE, no names, a header row,
    // a cell that is not a number, a missing file.
    ".data d MER FILE='a.txt' x=1 OUT='o.txt'\n.enddata\n",
    ".data d MER FILE='a.txt' x=0\n.enddata\n",
    ".data d MER x=1 FILE='a.txt'\n.enddata\n",
    ".data d MER FILE='a.txt'\n.enddata\n",
    ".data d MER FILE='h.txt' x=1\n.enddata\n",
    ".data d MER FILE='n.txt' x=1\n.enddata\n",
    ".data d MER FILE='none.txt' x=1\n.enddata\n",
};

test "external .data: oracle and frontend merge alike" {
    std.testing.log_level = .err;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (data_files) |f| try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const g = try grammar(a);
    var bad: usize = 0;
    for (cases) |c| {
        if (!try check(a, io, g, dir, c)) bad += 1;
    }

    // Every card of up to four items over this vocabulary, each joined to
    // the last by a blank, a `+` line or a bare line.
    const items = [_][]const u8{ "FILE='a.txt'", "FILE=b.txt", "x=1", "y=2", "x=3", "FILE='c.txt'", "y = 1" };
    const seps = [_][]const u8{ " ", "\n+ ", "\n" };
    var n: usize = 0;
    for (1..5) |len| {
        var idx: [4]usize = @splat(0);
        while (true) {
            for ([_][]const u8{ "MER", "LAM" }) |mode| {
                var card: std.ArrayList(u8) = .empty;
                try card.print(a, ".data d {s}", .{mode});
                for (idx[0..len], 0..) |k, i| try card.print(a, "{s}{s}", .{ seps[(k + i + len) % seps.len], items[k] });
                try card.appendSlice(a, "\n.enddata\n");
                if (!try check(a, io, g, dir, card.items)) bad += 1;
                n += 1;
            }
            var i: usize = 0;
            while (i < len) : (i += 1) {
                idx[i] += 1;
                if (idx[i] < items.len) break;
                idx[i] = 0;
            }
            if (i == len) break;
        }
    }

    // Every data file of up to two lines of up to three tokens.
    const toks = [_][]const u8{ "1", "-2.5k", ".5e+1x", "x", "1e+", "*c", "$c", ",", "\t", "1.2.3", "+-1" };
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(a, "");
    for (toks) |p| {
        try lines.append(a, p);
        for (toks) |q| {
            try lines.append(a, try std.mem.concat(a, u8, &.{ p, " ", q }));
            for (toks) |r| try lines.append(a, try std.mem.concat(a, u8, &.{ p, " ", q, ",", r }));
        }
    }
    for (lines.items, 0..) |l1, i| for ([_][]const u8{ "", "7 8", lines.items[(i * 7) % lines.items.len] }) |l2| {
        try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = try std.mem.concat(a, u8, &.{ l1, "\n", l2, "\n" }) });
        if (!try check(a, io, g, dir, ".data d MER FILE='f.txt' x=1 y=2 z=3\n.enddata\n")) bad += 1;
        n += 1;
    };

    const holes = try peg.gaps(a, g);
    for (holes) |h| {
        var w: std.Io.Writer.Allocating = .init(a);
        try peg.render(&w.writer, g, h.node);
        std.debug.print("extdata.peg: rule {s}: never matched: {s}\n", .{ h.rule, w.written() });
    }
    if (bad > 0 or holes.len > 0) {
        std.debug.print("external .data: {d} of {d} disagree, {d} coverage gaps\n", .{ bad, n + cases.len, holes.len });
        return error.Mismatch;
    }
}
