//! `.include` and `.lib` expansion, before parsing. Paths resolve against
//! the directory of the file that names them.
const std = @import("std");
const Io = std.Io;
const Fields = @import("lines.zig").Fields("\"'", false);
const Directive = enum { include, lib, endl };
const directives = std.StaticStringMap(Directive).initComptime(.{
    .{ ".include", .include }, .{ ".inc", .include }, .{ ".lib", .lib }, .{ ".endl", .endl },
});

/// Reads `path` and expands it (see `expand`). The result is allocated in `arena`.
pub fn load(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const src = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    errdefer arena.free(src);
    const out = try expand(io, arena, path, src);
    if (out.ptr != src.ptr) arena.free(src);
    return out;
}

/// Inlines includes and selected .lib sections, resolving paths against
/// `origin`'s directory; an HDL include stays an `.include` of its resolved
/// path. Returns `src` itself when it names none, else a copy in `arena`.
pub fn expand(io: Io, arena: std.mem.Allocator, origin: []const u8, src: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next(); // The title is opaque even when it starts with .include.
    while (lines.next()) |line| {
        if (directiveOf(std.mem.trim(u8, line, " \t\r")) != null) break;
    } else return src;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    try appendContents(io, origin, src, null, 0, &out);
    return try arena.dupe(u8, out.items);
}

/// HSPICE `.alter` [SA Ch.4]: the deck up to the first `.alter`, then one
/// full source per `.alter` block. Blocks are cumulative, as HSPICE reads
/// the input again from the previous run's netlist: block k applies to the
/// deck as blocks 1..k-1 left it. In a block, an element card replaces the
/// top-level card of the same name, `.model` the model of that name,
/// `.subckt ... .ends` the subcircuit of that name, and `.lib file sec`
/// the `.lib` line naming the same file; `.del lib file sec` removes one.
/// Any other card is appended (`.param`: the last definition wins). A deck
/// without `.alter` is returned as its single run, unchanged.
pub fn splitAlters(arena: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    var cards: std.ArrayList(Card) = .empty;
    var runs: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    const title = lines.first();
    var block: ?std.ArrayList(Card) = null;
    var base_end: usize = src.len;
    var pending: ?Card = null;
    while (true) {
        const at = lines.index orelse src.len;
        const next = lines.next();
        const line = next orelse "";
        const t = std.mem.trim(u8, line, " \t\r");
        if (next != null and t.len > 0 and t[0] == '+' and pending != null) {
            pending.?.text = src[@intFromPtr(pending.?.text.ptr) - @intFromPtr(src.ptr) .. at + line.len];
            continue;
        }
        if (pending) |c| {
            if (block) |*b| try b.append(arena, c) else try cards.append(arena, c);
            pending = null;
        }
        if (next == null) break;
        const head = firstWord(t);
        if (eqlLower(head, ".alter") or eqlLower(head, ".end")) {
            if (block) |b| {
                try apply(arena, &cards, b.items);
                try runs.append(arena, try render(arena, title, cards.items));
            } else base_end = at;
            block = null;
            if (eqlLower(head, ".end")) break;
            block = .empty;
            continue;
        }
        pending = .{ .text = src[at .. at + line.len], .key = try keyOf(arena, t) };
    }
    if (block) |b| {
        try apply(arena, &cards, b.items);
        try runs.append(arena, try render(arena, title, cards.items));
    }
    if (runs.items.len == 0) return try arena.dupe([]const u8, &.{src});
    try runs.insert(arena, 0, src[0..base_end]);
    return runs.items;
}

/// One logical card of an `.alter` split: its text (continuations
/// included) and what a block's card of the same key replaces.
const Card = struct { text: []const u8, key: []const u8 };

fn firstWord(t: []const u8) []const u8 {
    return t[0 .. std.mem.indexOfAny(u8, t, " \t") orelse t.len];
}

fn eqlLower(text: []const u8, lower: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text, lower);
}

/// `e:<name>`, `model:<name>`, `subckt:<name>`, `lib:<file>`, `del:<file>`
/// or "" for a card that only appends.
fn keyOf(arena: std.mem.Allocator, t: []const u8) ![]const u8 {
    if (t.len == 0 or t[0] == '*') return "";
    var fields = Fields.init(t);
    const head = fields.next() orelse return "";
    const kind: []const u8 = if (std.ascii.isAlphabetic(head[0])) "e" else if (eqlLower(head, ".model")) "model" else if (eqlLower(head, ".subckt")) "subckt" else if (eqlLower(head, ".lib")) "lib" else if (eqlLower(head, ".del")) "del" else if (eqlLower(head, ".ends")) "ends" else return "";
    if (std.mem.eql(u8, kind, "e") or std.mem.eql(u8, kind, "ends")) return std.ascii.allocLowerString(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ kind, head }));
    if (std.mem.eql(u8, kind, "del")) {
        const what = fields.next() orelse return error.InvalidAlter;
        if (!eqlLower(what, "lib")) return error.InvalidAlter;
    }
    const name = (word(&fields) catch return error.InvalidAlter) orelse return error.InvalidAlter;
    return std.ascii.allocLowerString(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{ kind, name }));
}

/// The span of cards a `.subckt` card at `i` opens, through its `.ends`.
fn unitLen(cards: []const Card, i: usize) usize {
    if (!std.mem.startsWith(u8, cards[i].key, "subckt:")) return 1;
    var k = i + 1;
    while (k < cards.len and !std.mem.startsWith(u8, cards[k].key, "ends:")) : (k += 1) {}
    return @min(k + 1, cards.len) - i;
}

/// Applies one `.alter` block to `cards` in place.
fn apply(arena: std.mem.Allocator, cards: *std.ArrayList(Card), block: []const Card) !void {
    var i: usize = 0;
    while (i < block.len) {
        const c = block[i];
        const n = unitLen(block, i);
        defer i += n;
        const target = if (std.mem.startsWith(u8, c.key, "del:")) try std.fmt.allocPrint(arena, "lib:{s}", .{c.key[4..]}) else c.key;
        const replaceable = target.len != 0 and !std.mem.startsWith(u8, target, "ends:");
        // Top-level cards only: skip subcircuit bodies.
        var k: usize = 0;
        const found: ?usize = while (replaceable and k < cards.items.len) {
            if (std.mem.eql(u8, cards.items[k].key, target)) break k;
            k += unitLen(cards.items, k);
        } else null;
        if (found) |at| {
            const old = unitLen(cards.items, at);
            const new: []const Card = if (target.ptr != c.key.ptr) &.{} else block[i..][0..n];
            try cards.replaceRange(arena, at, old, new);
        } else if (target.ptr == c.key.ptr) {
            try cards.appendSlice(arena, block[i..][0..n]);
        } else return error.InvalidAlter;
    }
}

fn render(arena: std.mem.Allocator, title: []const u8, cards: []const Card) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, title);
    try out.append(arena, '\n');
    for (cards) |c| {
        try out.appendSlice(arena, c.text);
        try out.append(arena, '\n');
    }
    try out.appendSlice(arena, ".end\n");
    return out.items;
}

fn directiveOf(line: []const u8) ?Directive {
    if (line.len == 0 or line[0] != '.') return null;
    var key_buf: [8]u8 = undefined;
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return if (end <= key_buf.len) directives.get(std.ascii.lowerString(key_buf[0..end], line[0..end])) else null;
}

fn word(fields: *Fields) !?[]const u8 {
    const rest = fields.rest();
    if (rest.len == 0 or rest[0] == '$' or rest[0] == ';') return null;
    const f = fields.next() orelse return null;
    if (Fields.isQuote(f[0])) return Fields.body(f);
    return if (Fields.isWord(f)) f else error.InvalidInclude;
}

/// A model file the netlist includes but does not parse.
pub const ForeignKind = enum { osdi_include, pre_osdi, verilog_a, verilog };

/// The HDL kind a path's extension names; null for a netlist include.
pub fn foreignKindForPath(path: []const u8) ?ForeignKind {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".va", ".vams", ".veriloga" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .verilog_a;
    if (std.ascii.eqlIgnoreCase(ext, ".v") or std.ascii.eqlIgnoreCase(ext, ".sv")) return .verilog;
    return null;
}

fn appendFile(io: Io, path: []const u8, section: ?[]const u8, depth: u8, out: *std.ArrayList(u8)) anyerror!void {
    // ponytail: bounded recursion; iterative include stack if real PDKs exceed 32.
    if (depth == 32) return error.IncludeDepthExceeded;
    const gpa = std.heap.page_allocator;
    const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(src);
    try appendContents(io, path, src, section, depth, out);
}

fn appendContents(io: Io, path: []const u8, src: []const u8, section: ?[]const u8, depth: u8, out: *std.ArrayList(u8)) anyerror!void {
    const gpa = std.heap.page_allocator;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var selected = section == null;
    var found = selected;
    var current_section: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var tokens = Fields.init(trimmed);
        // Title and comments are opaque, including unmatched quotes.
        if (depth == 0 and out.items.len == 0) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            continue;
        }
        if (directiveOf(trimmed)) |kind| {
            _ = try word(&tokens);
            if (kind == .endl) {
                // The name after `.endl` is not checked: ngspice ignores it
                // (inpcom.c), and GF180 closes `.lib dio` with `.endl diode`.
                if (current_section == null) return error.InvalidLibrarySection;
                current_section = null;
                selected = section == null;
                continue;
            }
            const file_or_section = (try word(&tokens)) orelse return error.InvalidInclude;
            const corner = if (kind == .lib) try word(&tokens) else null;
            if (kind == .lib and corner == null) {
                if (current_section != null) return error.InvalidLibrarySection;
                current_section = file_or_section;
                selected = if (section) |wanted| std.ascii.eqlIgnoreCase(wanted, file_or_section) else false;
                if (selected and found) return error.DuplicateLibrarySection;
                found = found or selected;
                continue;
            }
            if (!selected) continue;
            const resolved = try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(path) orelse ".", file_or_section });
            defer gpa.free(resolved);
            // HDL includes are left for the runtime loader.
            if (foreignKindForPath(file_or_section) != null) {
                try out.appendSlice(gpa, ".include \"");
                try out.appendSlice(gpa, resolved);
                try out.appendSlice(gpa, "\"\n");
                continue;
            }
            try appendFile(io, resolved, corner, depth + 1, out);
        } else if (selected) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    if (current_section != null) return error.InvalidLibrarySection;
    if (!found) return error.LibrarySectionNotFound;
}
