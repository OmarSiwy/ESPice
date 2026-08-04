//! Deck bytes -> the title and the logical lines, two ways: the dialect's
//! `*_lines.peg` grammar and the frontend's `lines.Syntax(d).Lines`. The
//! first stage the oracle compares; the statement grammars read its output.
//!
//! A lines grammar's start rule is `File`. It captures `Title` (the title
//! text) and `Line` (one logical statement). Inside a `Line`, `Piece` is a
//! stretch of a physical line joined to the previous one with a blank and
//! `Glue` one joined with nothing (HSPICE `\\`). Comments are simply not
//! captured. Whitespace runs collapse to one blank on both sides, since the
//! field splitter treats any run as one separator.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const netlist = @import("netlist");
const lines = netlist.lines;
const peg = @import("peg.zig");

/// A deck's title and logical lines, whitespace-collapsed.
pub const Logical = struct {
    title: []const u8,
    lines: []const []const u8,

    /// True when both readings hold the same title and lines.
    pub fn eql(a: Logical, b: Logical) bool {
        if (!std.mem.eql(u8, a.title, b.title)) return false;
        if (a.lines.len != b.lines.len) return false;
        for (a.lines, b.lines) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }

    /// Writes the reading one line per row, the title first, for a diff.
    pub fn format(l: Logical, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("title: {s}\n", .{l.title});
        for (l.lines) |s| try w.print("| {s}\n", .{s});
    }
};

/// The grammar's rule ids a lines grammar must define.
pub const Rules = struct {
    file: peg.RuleId,
    title: peg.RuleId,
    line: peg.RuleId,
    piece: peg.RuleId,
    /// Absent in a dialect that joins every continuation with a blank.
    glue: ?peg.RuleId,
    /// Spectre's `simulator lang=spice` regions: their lines and parts.
    spice_line: ?peg.RuleId,
    hpiece: ?peg.RuleId,
    hglue: ?peg.RuleId,

    /// Looks the rules up; asserts `File`, `Title`, `Line` and `Piece` exist.
    pub fn of(g: peg.Grammar) Rules {
        return .{
            .file = g.rule("File"),
            .title = g.rule("Title"),
            .line = g.rule("Line"),
            .piece = g.rule("Piece"),
            .glue = g.find("Glue"),
            .spice_line = g.find("SpiceLine"),
            .hpiece = g.find("HPiece"),
            .hglue = g.find("HGlue"),
        };
    }

    fn isLine(r: Rules, rule: peg.RuleId) bool {
        return rule == r.line or rule == r.spice_line;
    }

    fn isPiece(r: Rules, rule: peg.RuleId) bool {
        return rule == r.piece or rule == r.hpiece;
    }
};

/// The grammar's reading of `src`, lowercased when `fold` (the SPICE
/// dialects fold case before reading lines).
pub fn oracle(arena: Allocator, g: peg.Grammar, src: []const u8, fold: bool, diag: *peg.Diag) peg.ParseError!Logical {
    const r: Rules = .of(g);
    const tree = try peg.parse(arena, g, r.file, src, diag);
    var title: []const u8 = "";
    var out: std.ArrayList([]const u8) = .empty;
    var file = tree.children(null);
    const root = file.next().?;
    assert(tree.rows[root].rule == r.file);
    var it = tree.children(root);
    while (it.next()) |k| {
        const rule = tree.rows[k].rule;
        if (rule == r.title) {
            title = try collapse(arena, tree.text(k), false);
        } else if (r.isLine(rule)) {
            var buf: std.ArrayList(u8) = .empty;
            var parts = tree.children(k);
            while (parts.next()) |p| {
                const part = tree.rows[p].rule;
                assert(r.isPiece(part) or part == r.glue or part == r.hglue);
                if (buf.items.len > 0 and r.isPiece(part)) try buf.append(arena, ' ');
                try unbreak(arena, &buf, tree.text(p));
            }
            const text = try collapse(arena, buf.items, fold);
            if (text.len > 0) try out.append(arena, text);
        }
    }
    return .{ .title = title, .lines = out.items };
}

/// The frontend's reading of `src` in dialect `d`, as `netlist.parse`
/// splits it before any card is read.
pub fn frontend(arena: Allocator, comptime d: lines.Dialect, src: []const u8) !Logical {
    const S = lines.Syntax(d);
    const text = if (S.fold_case) try std.ascii.allocLowerString(arena, src) else src;
    var split: S.Lines = .{ .rest = text, .arena = arena };
    var title: []const u8 = "";
    if (S.title_line) {
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
        title = try collapse(arena, src[0..nl], false);
        split.rest = if (nl < text.len) text[nl + 1 ..] else "";
    }
    var out: std.ArrayList([]const u8) = .empty;
    while (try split.next()) |line| {
        const c = try collapse(arena, line, false);
        if (c.len == 0) continue;
        // The declarations walk stops at an HSPICE `.end` (the run ends) and
        // skips an ngspice one (ngspice reads on past it).
        if (std.mem.eql(u8, c, ".end") or std.mem.startsWith(u8, c, ".end ")) {
            if (d == .hspice) break;
            continue;
        }
        try out.append(arena, c);
    }
    return .{ .title = title, .lines = out.items };
}

/// Appends `text` with each line break left inside a quoted string removed:
/// `\\` and the blanks around it join with nothing, ` \` with one blank
/// (the grammar's `qbreak`). Outside quotes a break ends the part, so any
/// break still in a part's text sits inside quotes.
fn unbreak(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\') if (breakEnd(text, i)) |end| {
            const glue = i + 1 < text.len and text[i + 1] == '\\';
            while (out.items.len > 0 and (out.last() == ' ' or out.last() == '\t')) _ = out.pop();
            var j = end;
            if (glue) {
                while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            } else try out.append(arena, ' ');
            i = j;
            continue;
        };
        try out.append(arena, text[i]);
        i += 1;
    }
}

/// The offset past the newline when `text[i..]` is `\` or `\\`, blanks, then
/// a newline; null otherwise.
fn breakEnd(text: []const u8, i: usize) ?usize {
    var j = i + 1;
    if (j < text.len and text[j] == '\\') j += 1;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\r')) j += 1;
    return if (j < text.len and text[j] == '\n') j + 1 else null;
}

/// `s` with each run of blanks, tabs and CRs as one blank, trimmed, and
/// lowercased when `fold`.
fn collapse(arena: Allocator, s: []const u8, fold: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var blank = false;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\r') {
            blank = out.items.len > 0;
            continue;
        }
        if (blank) try out.append(arena, ' ');
        blank = false;
        try out.append(arena, if (fold) std.ascii.toLower(c) else c);
    }
    return out.items;
}

test collapse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b c", try collapse(arena.allocator(), " \tA  b\rc ", true));
    try std.testing.expectEqualStrings("", try collapse(arena.allocator(), " \t", false));
}
