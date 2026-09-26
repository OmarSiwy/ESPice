//! HSPICE SST2-style binary in Fortran unformatted records (little-endian i32
//! length, payload, length again): a text header, the variable count, the
//! names, a complex flag, then one record of f64 samples per point.
//! ponytail: follows the record structure only; vendor readers may expect
//! more. Match a real HSPICE file when a reader rejects this one.
const std = @import("std");
const Io = std.Io;
const Plot = @import("types.zig").Plot;

/// Width of one name slot; names are cut to 15 bytes plus a NUL.
const name_slot = 16;

fn writeRecord(w: *Io.Writer, data: []const u8) !void {
    try w.writeInt(i32, @intCast(data.len), .little);
    try w.writeAll(data);
    try w.writeInt(i32, @intCast(data.len), .little);
}

fn writeRecordI32(w: *Io.Writer, value: i32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .little);
    try writeRecord(w, &buf);
}

/// Expects at most 64 variables (`types.validateSchema` enforces it).
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const nvars = plot.result.varnames.len;
    const header = "SST2 {s} {s} nvars={d} npoints={d}";
    const args = .{ plot.title, plot.result.plotname, nvars, plot.result.npoints };
    const header_len: i32 = @intCast(std.fmt.count(header, args));
    try w.writeInt(i32, header_len, .little);
    try w.print(header, args);
    try w.writeInt(i32, header_len, .little);

    try writeRecordI32(w, @intCast(nvars));
    var names: [name_slot * 64]u8 = @splat(0);
    for (plot.result.varnames, 0..) |name, i| {
        const len = @min(name.len, name_slot - 1);
        @memcpy(names[i * name_slot ..][0..len], name[0..len]);
    }
    try writeRecord(w, names[0 .. nvars * name_slot]);
    try writeRecordI32(w, @intFromBool(plot.result.is_complex));
    for (0..plot.result.npoints) |pt| try writeRecord(w, std.mem.sliceAsBytes(plot.point(pt)));
}

test "SST2 record framing" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "sst2 test", .result = .{ .plotname = "Transient Analysis", .varnames = &.{ "time", "v(out)" }, .is_complex = false, .npoints = 2, .data = &.{ 0.0, 1.0, 0.5, 2.0 } } });
    const blob = w.buffered();
    const header = "SST2 sst2 test Transient Analysis nvars=2 npoints=2";
    try std.testing.expectEqual(@as(i32, header.len), std.mem.readInt(i32, blob[0..4], .little));
    try std.testing.expectEqualStrings(header, blob[4..][0..header.len]);
    try std.testing.expectEqual(@as(i32, header.len), std.mem.readInt(i32, blob[4 + header.len ..][0..4], .little));
    // Header, count, names, complex flag, two points of 2 f64 each.
    try std.testing.expectEqual(header.len + 8 + 3 * 4 + 2 * name_slot + 8 + 3 * 4 + 2 * (8 + 16), blob.len);
}
