//! A minimal FSDB-style analog container, little-endian: "FSDB", version,
//! variable and point counts, complex flag, u16-length-prefixed title,
//! plotname and variable names, then the samples as raw f64.
//! ponytail: FSDB proper is a closed Synopsys format; vendor tools need
//! libfsdb. Link it when real FSDB interchange is required.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Plot = @import("types.zig").Plot;

const magic = "FSDB";
const version: u32 = 0x0300;

/// Writes `plot`. Asserts the u32 counts and u16 string lengths
/// `types.validatePlot(.fsdb, ...)` checks, and one sample row per point.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    assert(plot.result.varnames.len <= std.math.maxInt(u32));
    assert(plot.result.npoints <= std.math.maxInt(u32));
    assert(plot.result.data.len == plot.result.npoints * plot.stride());
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
    assert(s.len <= std.math.maxInt(u16));
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

test "FSDB round-trips header, strings and sample bits" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const nan_payload: f64 = @bitCast(@as(u64, 0x7ff8_0000_0000_beef));
    const data = [_]f64{ 0, -0.0, 5e-324, nan_payload, std.math.inf(f64), -1e308 };
    const names = [_][]const u8{ "time", "v(a)", "" };
    try encode(&w, .{ .title = "", .result = .{ .plotname = "Transient", .varnames = &names, .is_complex = false, .npoints = 2, .data = &data } });
    var r: Io.Reader = .fixed(w.buffered());
    try std.testing.expectEqualStrings(magic, try r.take(4));
    try std.testing.expectEqual(version, try r.takeInt(u32, .little));
    try std.testing.expectEqual(@as(u32, 3), try r.takeInt(u32, .little));
    try std.testing.expectEqual(@as(u32, 2), try r.takeInt(u32, .little));
    try std.testing.expectEqual(@as(u32, 0), try r.takeInt(u32, .little));
    for ([_][]const u8{ "", "Transient" } ++ names) |want| {
        const len = try r.takeInt(u16, .little);
        try std.testing.expectEqualStrings(want, try r.take(len));
    }
    for (data) |x| try std.testing.expectEqual(@as(u64, @bitCast(x)), try r.takeInt(u64, .native));
    try std.testing.expectError(error.EndOfStream, r.takeByte());
}
