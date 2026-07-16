//! A minimal FSDB-style analog container, little-endian: "FSDB", version,
//! variable and point counts, complex flag, u16-length-prefixed title,
//! plotname and variable names, then the samples as raw f64.
//! ponytail: FSDB proper is a closed Synopsys format; vendor tools need
//! libfsdb. Link it when real FSDB interchange is required.
const std = @import("std");
const Io = std.Io;
const Plot = @import("types.zig").Plot;

const magic = "FSDB";
const version: u32 = 0x0300;

/// Writes `plot`. Expects the u32/u16 limits `types.validatePlot`
/// enforces for fsdb; a longer string panics in safe builds.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    try w.writeAll(magic);
    try w.writeInt(u32, version, .little);
    try w.writeInt(u32, @intCast(plot.result.varnames.len), .little);
    try w.writeInt(u32, @intCast(plot.result.npoints), .little);
    try w.writeInt(u32, @intFromBool(plot.result.is_complex), .little);
    try writeString(w, plot.title);
    try writeString(w, plot.result.plotname);
    for (plot.result.varnames) |name| try writeString(w, name);
    try w.writeAll(std.mem.sliceAsBytes(plot.result.data));
}

fn writeString(w: *Io.Writer, s: []const u8) !void {
    try w.writeInt(u16, @intCast(s.len), .little);
    try w.writeAll(s);
}

test "FSDB header, strings and samples" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5 };
    try encode(&w, .{ .title = "ac", .result = .{ .plotname = "AC", .varnames = &.{ "frequency", "v(out)" }, .is_complex = true, .npoints = 1, .data = &data } });
    const blob = w.buffered();
    try std.testing.expectEqualStrings(magic, blob[0..4]);
    const counts = [_]u32{ version, 2, 1, 1 };
    for (counts, 0..) |c, i| try std.testing.expectEqual(c, std.mem.readInt(u32, blob[4 + 4 * i ..][0..4], .little));
    try std.testing.expectEqualStrings("\x02\x00ac\x02\x00AC\x09\x00frequency\x06\x00v(out)", blob[20..][0..27]);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&data), blob[47..]);
}
