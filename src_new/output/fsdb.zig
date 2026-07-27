const std = @import("std");
const Io = std.Io;
const Plot = @import("rawfile.zig").Plot;

// ponytail: FSDB is proprietary (Synopsys). This implements a minimal analog FSDB
// structure based on publicly documented format. Full vendor tool compatibility
// requires linking against libfsdb.so — this covers the open subset.

const FSDB_MAGIC = "FSDB";
const FSDB_VERSION: u32 = 0x0300; // v3.0

fn writeU32(w: anytype, val: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, val, .little);
    try w.writeAll(&b);
}

fn writeU16(w: anytype, val: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, val, .little);
    try w.writeAll(&b);
}

fn writeF64(w: anytype, val: f64) !void {
    try w.writeAll(std.mem.asBytes(&val));
}

/// Write FSDB (Fast Signal Database) format for analog simulation data.
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    const nvars = plot.varnames.len;
    const per: usize = if (plot.is_complex) 2 else 1;
    if (plot.data.len != plot.npoints * nvars * per) return error.DataLengthMismatch;

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    // Section 1: File header
    try w.writeAll(FSDB_MAGIC);
    try writeU32(w, FSDB_VERSION);
    try writeU32(w, @intCast(nvars));
    try writeU32(w, @intCast(plot.npoints));
    try writeU32(w, if (plot.is_complex) @as(u32, 1) else @as(u32, 0));

    // Section 2: Title and plotname (length-prefixed strings)
    try writeU16(w, @intCast(plot.title.len));
    try w.writeAll(plot.title);
    try writeU16(w, @intCast(plot.plotname.len));
    try w.writeAll(plot.plotname);

    // Section 3: Signal definitions — name table
    for (plot.varnames) |name| {
        try writeU16(w, @intCast(name.len));
        try w.writeAll(name);
    }

    // Section 4: Data block — column-major f64, same layout as Plot.data
    try w.writeAll(std.mem.sliceAsBytes(plot.data));

    try w.flush();
}

/// Read back and verify an FSDB file header. Used by tests.
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
    // Complex flag should be 1
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
