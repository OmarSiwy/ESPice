//! `.include`, `.lib`, HSPICE `.load`, `.vec` and external `.data`
//! expansion, before parsing. Paths resolve against the directory of the file
//! that names them, then against each HSPICE `.option search=` directory.
const std = @import("std");
const Io = std.Io;
const Fields = @import("lines.zig").Fields("\"'", false);
const vec = @import("vec.zig");
const Directive = enum { include, lib, endl, load, data, vec };
const directives = std.StaticStringMap(Directive).initComptime(.{
    .{ ".include", .include }, .{ ".inc", .include }, .{ ".lib", .lib }, .{ ".endl", .endl },
    .{ ".load", .load },       .{ ".data", .data },   .{ ".vec", .vec },
});

/// Reads `path` and expands it (see `expand`). The result is allocated in
/// `arena`. Fails with the file system's error for `path` or any file it
/// names, or with `expand`'s.
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
/// InvalidInclude, InvalidLibrarySection, DuplicateLibrarySection,
/// LibrarySectionNotFound, InvalidData, InvalidVector or
/// IncludeDepthExceeded (past 32 levels) for a deck it cannot expand.
pub fn expand(io: Io, arena: std.mem.Allocator, origin: []const u8, src: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next(); // The title is opaque even when it starts with .include.
    while (lines.next()) |line| {
        if (directiveOf(std.mem.trim(u8, line, " \t\r")) != null) break;
    } else return src;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    try appendContents(io, try searchDirs(arena, origin, src), origin, src, null, 0, &out);
    return try arena.dupe(u8, out.items);
}

/// Whether any line after the title starts with `.alter`.
fn hasAlter(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.first();
    while (lines.next()) |line| {
        if (eqlLower(firstWord(std.mem.trim(u8, line, " \t\r")), ".alter")) return true;
    }
    return false;
}

/// HSPICE `.option search='dir'` [CR .OPTION SEARCH]: where `.lib`,
/// `.include` and `.load` look for a file not found beside the file naming
/// it. Read off the top-level deck only, so a search path set inside an
/// included file is not seen; a relative directory resolves against the
/// deck's.
fn searchDirs(arena: std.mem.Allocator, origin: []const u8, src: []const u8) ![]const []const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        var tokens = Fields.init(std.mem.trim(u8, line, " \t\r"));
        const head = tokens.next() orelse continue;
        if (!eqlLower(head, ".option") and !eqlLower(head, ".options") and !eqlLower(head, ".opt")) continue;
        while (tokens.next()) |key| {
            if (!Fields.isWord(key) or !tokens.takeEq()) continue;
            const value = word(&tokens) catch continue orelse continue;
            if (eqlLower(key, "search")) try dirs.append(arena, try std.fs.path.resolve(arena, &.{ std.fs.path.dirname(origin) orelse ".", value }));
        }
    }
    return dirs.items;
}

/// `name` beside `path`, else in the first search directory holding it;
/// beside `path` when none does, so the open reports the usual error.
fn locate(io: Io, search: []const []const u8, path: []const u8, name: []const u8) ![]u8 {
    const gpa = std.heap.page_allocator;
    const here = try std.fs.path.resolve(gpa, &.{ std.fs.path.dirname(path) orelse ".", name });
    if (search.len == 0 or std.fs.path.isAbsolute(name)) return here;
    if (Io.Dir.cwd().access(io, here, .{})) |_| return here else |_| {}
    for (search) |dir| {
        const there = try std.fs.path.resolve(gpa, &.{ dir, name });
        if (Io.Dir.cwd().access(io, there, .{})) |_| {
            gpa.free(here);
            return there;
        } else |_| gpa.free(there);
    }
    return here;
}

/// HSPICE `.alter` [SA Ch.4]: the deck up to the first `.alter`, then one
/// full source per `.alter` block. Blocks are cumulative, as HSPICE reads
/// the input again from the previous run's netlist: block k applies to the
/// deck as blocks 1..k-1 left it. In a block, an element card replaces the
/// top-level card of the same name, `.model` the model of that name,
/// `.subckt ... .ends` the subcircuit of that name, and `.lib file sec`
/// the `.lib` line naming the same file; `.del lib file sec` removes one.
/// Any other card is appended (`.param`: the last definition wins). A deck
/// without `.alter` is returned as its single run, unchanged. Runs borrow
/// `src` or live in `arena`. InvalidAlter for a nameless `.model`,
/// `.subckt` or `.lib`, a `.del` other than `.del lib`, or a `.del` that
/// matches no `.lib` card.
pub fn splitAlters(arena: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    // Most decks have no `.alter`: borrow `src` whole and index nothing.
    if (!hasAlter(src)) return try arena.dupe([]const u8, &.{src});
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

/// What a non-netlist file a deck names holds: an HDL module, or `data`
/// that a card reads (an HSPICE RLGC or Touchstone file).
pub const ForeignKind = enum { osdi_include, pre_osdi, verilog_a, verilog, data };

/// The HDL kind a path's extension names; null for a netlist include.
pub fn foreignKindForPath(path: []const u8) ?ForeignKind {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".va", ".vams", ".veriloga" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return .verilog_a;
    if (std.ascii.eqlIgnoreCase(ext, ".v") or std.ascii.eqlIgnoreCase(ext, ".sv")) return .verilog;
    return null;
}

fn appendFile(io: Io, search: []const []const u8, path: []const u8, section: ?[]const u8, depth: u8, out: *std.ArrayList(u8)) anyerror!void {
    // ponytail: bounded recursion; iterative include stack if real PDKs exceed 32.
    if (depth == 32) return error.IncludeDepthExceeded;
    const gpa = std.heap.page_allocator;
    const src = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(src);
    try appendContents(io, search, path, src, section, depth, out);
}

/// HSPICE `.load [FILE=f] [RUN=...]` [CR .LOAD]: inlines the `.nodeset`/`.ic`
/// cards an earlier `.save` wrote, `<stem of path>.ic0` by default. A file
/// not there yet (the run that first saves it) is skipped with a warning.
/// RUN= only picks between `.alter` runs' files, which ESPice does not
/// number; it is accepted and unused.
fn appendLoad(io: Io, search: []const []const u8, path: []const u8, tokens: *Fields, depth: u8, out: *std.ArrayList(u8)) anyerror!void {
    const gpa = std.heap.page_allocator;
    var file: ?[]const u8 = null;
    while (tokens.next()) |key| {
        if (!Fields.isWord(key) or !tokens.takeEq()) return error.InvalidInclude;
        const value = (try word(tokens)) orelse return error.InvalidInclude;
        if (std.ascii.eqlIgnoreCase(key, "file")) file = value else if (!std.ascii.eqlIgnoreCase(key, "run")) return error.InvalidInclude;
    }
    const stem = std.fs.path.stem(path);
    const default = try std.mem.concat(gpa, u8, &.{ stem, ".ic0" });
    defer gpa.free(default);
    const resolved = try locate(io, search, path, file orelse default);
    defer gpa.free(resolved);
    appendFile(io, search, resolved, null, depth + 1, out) catch |err| switch (err) {
        error.FileNotFound => std.log.warn(".load: {s} not found; no saved operating point", .{resolved}),
        else => return err,
    };
}

/// HSPICE external `.data name MER|LAM FILE=f p=col ... .enddata`
/// [CR .DATA], written out as the inline `.data` table it stands for. Each
/// `FILE=` is followed by `name=column` (1-based) pairs. MER stacks the
/// files' rows, and a file inherits the previous file's columns for names
/// it does not give; LAM puts the files side by side, row for row, each
/// name from the file that gives it. A missing value is 0. Data files hold
/// blank- or comma-separated numbers, one row per line. `header` holds the
/// rest of the `.data` line; `lines` is left after `.enddata`.
fn appendData(io: Io, path: []const u8, name: []const u8, lam: bool, header: Fields, lines: *std.mem.SplitIterator(u8, .scalar), out: *std.ArrayList(u8)) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const File = struct { rows: []const []const []const u8, cols: std.ArrayList(u32) };
    var names: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList(File) = .empty;
    var tokens = header;
    while (true) {
        while (tokens.next()) |t| {
            if (t[0] == '$' or t[0] == ';') break;
            const key = std.mem.trimStart(u8, t, "+");
            if (key.len == 0) continue;
            if (!Fields.isWord(key) or !tokens.takeEq()) return error.InvalidData;
            const value = (try word(&tokens)) orelse return error.InvalidData;
            if (std.ascii.eqlIgnoreCase(key, "file")) {
                const resolved = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(path) orelse ".", value });
                const text = try Io.Dir.cwd().readFileAlloc(io, resolved, a, .unlimited);
                var rows: std.ArrayList([]const []const u8) = .empty;
                var it = std.mem.splitScalar(u8, text, '\n');
                while (it.next()) |row| {
                    var cells: std.ArrayList([]const u8) = .empty;
                    var c = std.mem.tokenizeAny(u8, row, " \t,\r");
                    while (c.next()) |v| try cells.append(a, v);
                    if (cells.items.len != 0) try rows.append(a, cells.items);
                }
                var cols: std.ArrayList(u32) = .empty;
                if (!lam and files.items.len != 0) try cols.appendSlice(a, files.items[files.items.len - 1].cols.items);
                try files.append(a, .{ .rows = rows.items, .cols = cols });
            } else if (std.ascii.eqlIgnoreCase(key, "out")) {
                // ponytail: OUT= (write the merged table back) is refused; add when a flow needs the file.
                std.log.err(".data {s}: OUT= is not supported", .{name});
                return error.InvalidData;
            } else {
                if (files.items.len == 0) return error.InvalidData;
                const col = std.fmt.parseInt(u32, value, 10) catch return error.InvalidData;
                if (col == 0) return error.InvalidData;
                const k = for (names.items, 0..) |n, i| {
                    if (std.ascii.eqlIgnoreCase(n, key)) break i;
                } else blk: {
                    try names.append(a, key);
                    break :blk names.items.len - 1;
                };
                const cols = &files.items[files.items.len - 1].cols;
                if (cols.items.len <= k) try cols.appendNTimes(a, 0, k + 1 - cols.items.len);
                cols.items[k] = col;
            }
        }
        const raw = lines.next() orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0 and eqlLower(firstWord(line), ".enddata")) break;
        tokens = Fields.init(if (line.len != 0 and line[0] == '*') "" else line);
    }
    if (names.items.len == 0) return error.InvalidData;
    const gpa = std.heap.page_allocator;
    try out.print(gpa, ".data {s}", .{name});
    for (names.items) |n| try out.print(gpa, " {s}", .{n});
    try out.append(gpa, '\n');
    if (lam) {
        // Each name's file: the last that gives it a column.
        const owner = try a.alloc(?usize, names.items.len);
        @memset(owner, null);
        var rows: usize = 0;
        for (files.items, 0..) |f, fi| {
            rows = @max(rows, f.rows.len);
            for (f.cols.items, 0..) |col, k| if (col != 0) {
                owner[k] = fi;
            };
        }
        for (0..rows) |r| {
            try out.append(gpa, '+');
            for (owner, 0..) |fi, k| {
                const f = if (fi) |i| files.items[i] else null;
                try out.print(gpa, " {s}", .{if (f) |file| cell(file, r, k) else "0"});
            }
            try out.append(gpa, '\n');
        }
    } else for (files.items) |f| for (0..f.rows.len) |r| {
        try out.append(gpa, '+');
        for (0..names.items.len) |k| try out.print(gpa, " {s}", .{cell(f, r, k)});
        try out.append(gpa, '\n');
    };
    try out.appendSlice(gpa, ".enddata\n");
}

/// Row `r`, name `k` of an external `.data` file; "0" where it has none.
fn cell(f: anytype, r: usize, k: usize) []const u8 {
    if (r >= f.rows.len or k >= f.cols.items.len or f.cols.items[k] == 0) return "0";
    const row = f.rows[r];
    const col = f.cols.items[k];
    return if (col <= row.len) row[col - 1] else "0";
}

/// HSPICE `.vec 'file'`: the sources and `.dout` cards the vector file
/// stands for (frontend/vec.zig).
fn appendVec(io: Io, path: []const u8, out: *std.ArrayList(u8)) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const src = try Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .unlimited);
    const text = vec.expand(arena.allocator(), src) catch |err| {
        if (err == error.InvalidVector) std.log.warn(".vec: cannot read {s}", .{path});
        return err;
    };
    try out.appendSlice(std.heap.page_allocator, text);
}

fn appendContents(io: Io, search: []const []const u8, path: []const u8, src: []const u8, section: ?[]const u8, depth: u8, out: *std.ArrayList(u8)) anyerror!void {
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
            if (kind == .data) {
                // An inline table passes through; MER and LAM read files.
                const name = tokens.next() orelse "";
                const mode = tokens.next() orelse "";
                const lam = std.ascii.eqlIgnoreCase(mode, "lam");
                if (selected and (lam or std.ascii.eqlIgnoreCase(mode, "mer"))) {
                    try appendData(io, path, name, lam, tokens, &lines, out);
                } else if (selected) {
                    try out.appendSlice(gpa, line);
                    try out.append(gpa, '\n');
                }
                continue;
            }
            if (kind == .load) {
                if (selected) try appendLoad(io, search, path, &tokens, depth, out);
                continue;
            }
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
            const resolved = try locate(io, search, path, file_or_section);
            defer gpa.free(resolved);
            // HDL includes are left for the runtime loader.
            if (foreignKindForPath(file_or_section) != null) {
                try out.appendSlice(gpa, ".include \"");
                try out.appendSlice(gpa, resolved);
                try out.appendSlice(gpa, "\"\n");
                continue;
            }
            if (kind == .vec) {
                try appendVec(io, resolved, out);
                continue;
            }
            try appendFile(io, search, resolved, corner, depth + 1, out);
        } else if (selected) {
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
    }
    if (current_section != null) return error.InvalidLibrarySection;
    if (!found) return error.LibrarySectionNotFound;
}

test "directives and alter keys" {
    try std.testing.expectEqual(.include, directiveOf(".INC x").?);
    try std.testing.expectEqual(.endl, directiveOf(".endl\tx").?);
    try std.testing.expectEqual(null, directiveOf(".includes x"));
    try std.testing.expectEqual(null, directiveOf("r1 a b 1"));
    try std.testing.expectEqual(null, directiveOf(""));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("e:r1", try keyOf(a, "R1 a b 1"));
    try std.testing.expectEqualStrings("model:nm", try keyOf(a, ".model NM nmos"));
    try std.testing.expectEqualStrings("del:f", try keyOf(a, ".del lib 'f' tt"));
    try std.testing.expectEqualStrings("", try keyOf(a, ".param a=1"));
    try std.testing.expectEqualStrings("", try keyOf(a, "* c"));
    try std.testing.expectError(error.InvalidAlter, keyOf(a, ".del x"));
    try std.testing.expectError(error.InvalidAlter, keyOf(a, ".model"));
    try std.testing.expectEqual(.verilog_a, foreignKindForPath("a/B.VA").?);
    try std.testing.expectEqual(.verilog, foreignKindForPath("x.sv").?);
    try std.testing.expectEqual(null, foreignKindForPath("x.sp"));
    // A deck naming nothing is returned as itself, even with a `.include` title.
    const plain = ".include x\nr1 a 0 1\n";
    try std.testing.expectEqual(plain.ptr, (try expand(std.testing.io, a, "deck.sp", plain)).ptr);
}

test "external .data: MER stacks files, LAM sets them side by side" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1 2\n3,4\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "5 6\n" });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/deck.sp", .{tmp.sub_path});
    const Case = struct { []const u8, anyerror![]const u8 };
    for ([_]Case{
        .{ "t\n.data d MER\n+ FILE='a.txt' x=1 y=2\n+ FILE='b.txt' y=1\n.enddata\n.end\n", "t\n.data d x y\n+ 1 2\n+ 3 4\n+ 5 5\n.enddata\n.end\n\n" },
        .{ "t\n.data d LAM\n+ FILE='a.txt' x=1\n+ FILE='b.txt' y=2\n.enddata\n", "t\n.data d x y\n+ 1 6\n+ 3 0\n.enddata\n\n" },
        .{ "t\n.data d MER FILE='a.txt' x=0\n.enddata\n", error.InvalidData },
        .{ "t\n.data d MER x=1\n.enddata\n", error.InvalidData },
        .{ "t\n.data d MER FILE='a.txt'\n.enddata\n", error.InvalidData },
    }) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = case[0] });
        const got = load(io, a, path);
        if (case[1]) |want| try std.testing.expectEqualStrings(want, try got) else |err| try std.testing.expectError(err, got);
    }
}
