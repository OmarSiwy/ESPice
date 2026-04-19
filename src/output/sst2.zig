const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

// ponytail: Fortran-style unformatted record writer — HSPICE TR0/SST2 uses this framing.
fn writeRecord(w: anytype, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &len_buf, @intCast(data.len), .little);
    try w.writeAll(&len_buf);
    try w.writeAll(data);
    try w.writeAll(&len_buf);
}

fn writeRecordI32(w: anytype, value: i32) !void {
    var val_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &val_buf, value, .little);
    try writeRecord(w, &val_buf);
}

/// Write HSPICE SST2 binary format.
/// Structure: header record (ASCII metadata), variable count, variable names, data blocks.
/// ponytail: simplified SST2 — compatible structure, may not match all vendor reader quirks.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const nvars = plot.result.varnames.len;
    const per: usize = if (plot.result.is_complex) 2 else 1;

    var hdr_buf: [512]u8 = undefined;
    // ponytail: bufPrint supplies the record length; no separate counting pass.
    const hdr = std.fmt.bufPrint(&hdr_buf, "SST2 {s} {s} nvars={d} npoints={d}", .{
        plot.title, plot.result.plotname, nvars, plot.result.npoints,
    }) catch &hdr_buf;
    try writeRecord(w, hdr);

    try writeRecordI32(w, @intCast(nvars));

    // Record 3: Variable names — null-terminated, fixed 16-byte slots
    var name_block: [16 * 64]u8 = @splat(0);
    for (plot.result.varnames, 0..) |name, i| {
        const offset = i * 16;
        const copy_len = @min(name.len, 15);
        @memcpy(name_block[offset..][0..copy_len], name[0..copy_len]);
    }
    try writeRecord(w, name_block[0 .. nvars * 16]);

    try writeRecordI32(w, if (plot.result.is_complex) @as(i32, 1) else @as(i32, 0));

    // Data records: one per point, all variables as f64
    const values_per_point = nvars * per;
    for (0..plot.result.npoints) |pt| {
        const start = pt * values_per_point;
        const point_data = plot.result.data[start..][0..values_per_point];
        try writeRecord(w, std.mem.sliceAsBytes(point_data));
    }

}

test "SST2 write and structural verify" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0, 0.5, 2.0 };
    const plot: Plot = .{ .title = "sst2 test", .result = .{ .plotname = "Transient Analysis", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data } };
    const path = "zig-out/test.tr0";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .sst2, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);

    // Verify Fortran record framing: first 4 bytes = length of header record
    const rec1_len = std.mem.readInt(i32, blob[0..4], .little);
    try std.testing.expect(rec1_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, blob[4..], "SST2"));
    const rec1_end: usize = @intCast(4 + rec1_len);
    const rec1_close = std.mem.readInt(i32, blob[rec1_end..][0..4], .little);
    try std.testing.expectEqual(rec1_len, rec1_close);
}

test "SST2 complex data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5 };
    const plot: Plot = .{ .title = "ac", .result = .{ .plotname = "AC", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data } };
    const path = "zig-out/test.ac0";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .sst2, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.startsWith(u8, blob[4..], "SST2"));
}

test "SST2 data length mismatch" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "v(a)", "v(b)" };
    const data = [_]f64{ 1.0, 2.0, 3.0 };
    const plot: Plot = .{ .title = "bad", .result = .{ .plotname = "bad", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data } };
    try std.testing.expectError(error.DataLengthMismatch, @import("write.zig").write(io, "zig-out/bad.tr0", .sst2, plot));
}
