const std = @import("std");
const Io = std.Io;
const types = @import("output_types");
const Plot = types.Plot;

// ponytail: FSDB is proprietary (Synopsys). This implements a minimal analog FSDB
// structure based on publicly documented format. Full vendor tool compatibility
// requires linking against libfsdb.so — this covers the open subset.

const FSDB_MAGIC = "FSDB";
const FSDB_VERSION: u32 = 0x0300; // v3.0

/// Write FSDB (Fast Signal Database) format for analog simulation data.
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    const nvars = plot.varnames.len;
    try types.validatePlot(.fsdb, plot);

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(FSDB_MAGIC);
    try w.writeInt(u32, FSDB_VERSION, .little);
    try w.writeInt(u32, @intCast(nvars), .little);
    try w.writeInt(u32, @intCast(plot.npoints), .little);
    try w.writeInt(u32, if (plot.is_complex) @as(u32, 1) else @as(u32, 0), .little);

    // Section 2: Title and plotname (length-prefixed strings)
    try w.writeInt(u16, @intCast(plot.title.len), .little);
    try w.writeAll(plot.title);
    try w.writeInt(u16, @intCast(plot.plotname.len), .little);
    try w.writeAll(plot.plotname);

    for (plot.varnames) |name| {
        try w.writeInt(u16, @intCast(name.len), .little);
        try w.writeAll(name);
    }

    // Section 4: Data block — point-major f64, same layout as Plot.data
    try w.writeAll(std.mem.sliceAsBytes(plot.data));

    try w.flush();
}

fn verifyHeader(blob: []const u8) !struct { nvars: u32, npoints: u32 } {
    if (blob.len < 20) return error.TooShort;
    if (!std.mem.startsWith(u8, blob, FSDB_MAGIC)) return error.BadMagic;
    const nvars = std.mem.readInt(u32, blob[8..12], .little);
    const npoints = std.mem.readInt(u32, blob[12..16], .little);
    return .{ .nvars = nvars, .npoints = npoints };
}

test "FSDB write and read back header" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0, 0.5, 2.0 };
    const plot: Plot = .{ .title = "fsdb test", .plotname = "Transient Analysis", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data };
    const path = "zig-out/test.fsdb";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    const hdr = try verifyHeader(blob);
    try std.testing.expectEqual(@as(u32, 2), hdr.nvars);
    try std.testing.expectEqual(@as(u32, 2), hdr.npoints);
}

test "FSDB complex data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5 };
    const plot: Plot = .{ .title = "ac", .plotname = "AC", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data };
    const path = "zig-out/test_ac.fsdb";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    const hdr = try verifyHeader(blob);
    try std.testing.expectEqual(@as(u32, 2), hdr.nvars);
    const complex_flag = std.mem.readInt(u32, blob[16..20], .little);
    try std.testing.expectEqual(@as(u32, 1), complex_flag);
}

test "FSDB data length mismatch" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "v(a)", "v(b)" };
    const data = [_]f64{ 1.0, 2.0, 3.0 };
    const plot: Plot = .{ .title = "bad", .plotname = "bad", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data };
    try std.testing.expectError(error.DataLengthMismatch, write(io, "zig-out/bad.fsdb", plot));
}
