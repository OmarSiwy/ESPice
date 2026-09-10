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
    var lines = std.mem.splitScalar(u8, src, '\n');
    _ = lines.next(); // The title is opaque even when it starts with .include.
    while (lines.next()) |line| {
        if (directiveOf(std.mem.trim(u8, line, " \t\r")) != null) break;
    } else return src;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.page_allocator);
    {
        defer arena.free(src);
        try appendContents(io, path, src, null, 0, &out);
    }
    return arena.dupe(u8, out.items);
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

test "source: nested relative includes select only requested case-insensitive corner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Models");
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = "Title\n.LIB 'Models/lib.sp' TT\n.end\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib ss ; ignored corner\n.include missing.sp\n.endl ss\n.lib tt $ selected corner\n.inc 'res.sp'\n.endl TT ; close\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/res.sp", .data = "R1 out 0 1k\n" });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/deck.sp", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const text = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "R1 out 0 1k") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "missing") == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.endl ff\n" });
    try std.testing.expectError(error.InvalidLibrarySection, load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib ff\n.endl ff\n" });
    try std.testing.expectError(error.LibrarySectionNotFound, load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.include 'lib.sp'\n.endl tt\n" });
    // An unselected library declaration is inert when included without a corner.
    const inert = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(inert);
    try tmp.dir.writeFile(io, .{ .sub_path = "Models/lib.sp", .data = ".lib tt\n.lib 'lib.sp' tt\n.endl tt\n" });
    try std.testing.expectError(error.IncludeDepthExceeded, load(io, std.testing.allocator, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = "\n* unmatched ' comment\n.include 'Models/res.sp'\n.end\n" });
    const blank_title = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(blank_title);
    try std.testing.expectEqualStrings("\n* unmatched ' comment\nR1 out 0 1k\n\n.end\n\n", blank_title);
    // Include-free input is returned byte-for-byte, including CRLF and no final LF.
    const plain = ".include is only the title\r\n* .lib 'comment\r\nR1 out 0 1k\r\n.end";
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sp", .data = plain });
    const unchanged = try load(io, std.testing.allocator, path);
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings(plain, unchanged);
}
