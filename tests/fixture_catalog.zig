//! Build-time filesystem discovery becomes shared compile-time fixture arrays.
const std = @import("std");

pub fn create(b: *std.Build) *std.Build.Module {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "tests/fixtures", .{ .iterate = true }) catch
        @panic("cannot open tests/fixtures");
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("cannot walk tests/fixtures");
    defer walker.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(io) catch @panic("fixture traversal failed")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sp")) continue;
        paths.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.less);
    if (paths.items.len == 0) @panic("tests/fixtures contains no SPICE files");

    const files = b.addWriteFiles();
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    const w = &source.writer;
    w.writeAll("pub const spice_files = [_][]const u8{\n") catch @panic("OOM");
    for (paths.items) |path| {
        const relative = b.fmt("fixtures/{s}", .{path});
        w.print("    \"{f}\",\n", .{std.zig.fmtString(relative)}) catch @panic("OOM");
        const expected = b.fmt("{s}.expected.json", .{path[0 .. path.len - 3]});
        dir.access(io, expected, .{}) catch std.debug.panic("missing expected output for {s}", .{path});
        _ = files.addCopyFile(b.path(b.fmt("tests/fixtures/{s}", .{expected})), b.fmt("fixtures/{s}", .{expected}));
    }
    w.writeAll(
        \\};
        \\pub const expected_files = blk: {
        \\    @setEvalBranchQuota(100_000);
        \\    var paths: [spice_files.len][]const u8 = undefined;
        \\    for (spice_files, 0..) |path, i| paths[i] = path[0 .. path.len - 3] ++ ".expected.json";
        \\    break :blk paths;
        \\};
        \\pub const expected_outputs = blk: {
        \\    @setEvalBranchQuota(100_000);
        \\    var contents: [expected_files.len][]const u8 = undefined;
        \\    for (expected_files, 0..) |path, i| contents[i] = @embedFile(path);
        \\    break :blk contents;
        \\};
        \\
    ) catch @panic("OOM");
    return b.createModule(.{ .root_source_file = files.add("fixture_catalog.zig", source.written()) });
}
