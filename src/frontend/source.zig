//! SPICE includes and selected .lib sections; paths stay relative to their file.
const std = @import("std");
const Io = std.Io;
const ir = @import("types.zig");
const Tokens = @import("tokenizer.zig").GenTokens(.{ .quotes = "\"'" });
const Directive = enum { include, lib, endl };
const directives = std.StaticStringMap(Directive).initComptime(.{
    .{ ".include", .include }, .{ ".inc", .include }, .{ ".lib", .lib }, .{ ".endl", .endl },
});

pub fn load(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const src = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    errdefer arena.free(src);
    if (try expand(io, arena, path, src)) |expanded| {
        arena.free(src);
        return expanded;
    }
    return src;
}

/// Expand supplied bytes using origin's directory for includes. Always returns
/// owned storage, including when the input needs no expansion.
pub fn loadBytes(io: Io, arena: std.mem.Allocator, origin: []const u8, src: []const u8) ![]const u8 {
    return try expand(io, arena, origin, src) orelse try arena.dupe(u8, src);
}

fn expand(io: Io, arena: std.mem.Allocator, origin: []const u8, src: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next(); // The title is opaque even when it starts with .include.
    while (lines.next()) |line| {
        if (directiveOf(std.mem.trim(u8, line, " \t\r")) != null) break;
    } else return null;

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

fn word(tokens: *Tokens) !?[]const u8 {
    const rest = tokens.rest();
    if (rest.len == 0 or rest[0] == '$' or rest[0] == ';') return null;
    return switch (tokens.next() orelse return null) {
        .word, .quoted => |s| s,
        else => error.InvalidInclude,
    };
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
        var tokens = Tokens.init(trimmed);
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
            // HDL includes are consumed later by the existing runtime loader.
            if (ir.foreignKindForPath(file_or_section) != null) {
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
