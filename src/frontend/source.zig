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
                const active = current_section orelse return error.InvalidLibrarySection;
                if (try word(&tokens)) |closing| {
                    if (!std.ascii.eqlIgnoreCase(active, closing)) return error.InvalidLibrarySection;
                }
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
