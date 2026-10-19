//! HSPICE SST2-style binary in Fortran unformatted records (little-endian i32
//! length, payload, length again): a text header, the variable count, the
//! names, a complex flag, then one record of f64 samples per point.
//! ponytail: follows the record structure only; vendor readers may expect
//! more. Match a real HSPICE file when a reader rejects this one.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Plot = @import("types.zig").Plot;

/// Width of one name slot; names are cut to 15 bytes plus a NUL.
const name_slot = 16;
/// Name slots in the names record (`types.validateSchema` enforces it).
const names_max = 64;

fn writeRecord(w: *Io.Writer, data: []const u8) !void {
    assert(data.len <= std.math.maxInt(i32));
    try w.writeInt(i32, @intCast(data.len), .little);
    try w.writeAll(data);
    try w.writeInt(i32, @intCast(data.len), .little);
}

/// Writes `plot`. Asserts at most 64 variables (`types.validateSchema`
/// enforces it) and one sample row per point.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const nvars = plot.result.varnames.len;
    assert(nvars <= names_max);
    assert(plot.result.data.len == plot.result.npoints * plot.stride());
    const header = "SST2 {s} {s} nvars={d} npoints={d}";
    const args = .{ plot.title, plot.result.plotname, nvars, plot.result.npoints };
    const header_len: i32 = @intCast(std.fmt.count(header, args));
    try w.writeInt(i32, header_len, .little);
    try w.print(header, args);
    try w.writeInt(i32, header_len, .little);

    try writeRecord(w, &std.mem.toBytes(std.mem.nativeToLittle(i32, @intCast(nvars))));
    var names: [name_slot * names_max]u8 = @splat(0);
    for (plot.result.varnames, 0..) |name, i| {
        const len = @min(name.len, name_slot - 1);
        @memcpy(names[i * name_slot ..][0..len], name[0..len]);
    }
    try writeRecord(w, names[0 .. nvars * name_slot]);
    try writeRecord(w, &std.mem.toBytes(std.mem.nativeToLittle(i32, @intFromBool(plot.result.is_complex))));
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

test "SST2 cuts names to 15 bytes plus a NUL" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "t", .result = .{ .plotname = "p", .varnames = &.{ "v(a_very_long_node_name)", "v(b)" }, .is_complex = false, .npoints = 0, .data = &.{} } });
    const blob = w.buffered();
    const header = "SST2 t p nvars=2 npoints=0";
    const names = blob[4 + header.len + 4 + 12 + 4 ..][0 .. 2 * name_slot];
    const pad: [12]u8 = @splat(0);
    try std.testing.expectEqualStrings("v(a_very_long_n\x00v(b)" ++ pad, names);
}

test "SST2 round-trips every record and its sample bits" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const nan_payload: f64 = @bitCast(@as(u64, 0xfff8_0000_0000_0042));
    const data = [_]f64{ 1, -0.0, 5e-324, nan_payload, 2, std.math.inf(f64), 3, -7 };
    try encode(&w, .{ .title = "t", .result = .{ .plotname = "AC", .varnames = &.{ "frequency", "v(o)" }, .is_complex = true, .npoints = 2, .data = &data } });
    var r: Io.Reader = .fixed(w.buffered());
    // Each record: i32 length, payload, the same length again.
    const S = struct {
        fn record(rd: *Io.Reader) ![]const u8 {
            const len: usize = @intCast(try rd.takeInt(i32, .little));
            const payload = try rd.take(len);
            try std.testing.expectEqual(@as(i32, @intCast(len)), try rd.takeInt(i32, .little));
            return payload;
        }
    };
    try std.testing.expectEqualStrings("SST2 t AC nvars=2 npoints=2", try S.record(&r));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, (try S.record(&r))[0..4], .little));
    try std.testing.expectEqualStrings("frequency" ++ "\x00\x00\x00\x00\x00\x00\x00" ++ "v(o)" ++ "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", try S.record(&r));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, (try S.record(&r))[0..4], .little));
    for (0..2) |pt| {
        const row = try S.record(&r);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(data[pt * 4 ..][0..4]), row);
    }
    try std.testing.expectError(error.EndOfStream, r.takeByte());
}
