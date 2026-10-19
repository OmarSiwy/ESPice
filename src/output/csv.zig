//! CSV (RFC 4180): a header row of variable names, then one row per point.
//! A complex variable becomes a `_re` and an `_im` column. A name holding a
//! comma, quote or line break is quoted, its quotes doubled.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Plot = @import("types.zig").Plot;

/// Writes `plot`, which must have passed `types.validatePlot(.csv, ...)`.
/// Asserts that it has variables and one sample row per point.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    assert(plot.result.varnames.len > 0);
    assert(plot.result.data.len == plot.result.npoints * plot.stride());
    for (plot.result.varnames, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        if (plot.result.is_complex) {
            try field(w, name, "_re");
            try w.writeByte(',');
            try field(w, name, "_im");
        } else try field(w, name, "");
    }
    try w.writeByte('\n');
    for (0..plot.result.npoints) |pt| {
        for (plot.point(pt), 0..) |x, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{e}", .{x});
        }
        try w.writeByte('\n');
    }
}

/// `name ++ suffix` as one RFC 4180 field (#61).
fn field(w: *Io.Writer, name: []const u8, suffix: []const u8) !void {
    if (std.mem.indexOfAny(u8, name, ",\"\r\n") == null) return w.print("{s}{s}", .{ name, suffix });
    try w.writeByte('"');
    for (name) |c| {
        if (c == '"') try w.writeByte('"');
        try w.writeByte(c);
    }
    try w.print("{s}\"", .{suffix});
}

test "CSV quotes a name holding a comma or a quote" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "lin", .result = .{ .plotname = "SP", .varnames = &.{ "frequency", "S(1,1)", "a\"b" }, .is_complex = true, .npoints = 0, .data = &.{} } });
    try std.testing.expectEqualStrings("frequency_re,frequency_im,\"S(1,1)_re\",\"S(1,1)_im\",\"a\"\"b_re\",\"a\"\"b_im\"\n", w.buffered());
}

test "CSV real and complex layouts" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "csv", .result = .{ .plotname = "Transient", .varnames = &.{ "time", "v(out)" }, .is_complex = false, .npoints = 2, .data = &.{ 0.0, 1.0, 0.5, 2.0 } } });
    try std.testing.expectEqualStrings("time,v(out)\n0e0,1e0\n5e-1,2e0\n", w.buffered());

    w = .fixed(&buf);
    try encode(&w, .{ .title = "ac", .result = .{ .plotname = "AC", .varnames = &.{ "frequency", "v(out)" }, .is_complex = true, .npoints = 1, .data = &.{ 1.0, 0.0, 0.5, -0.5 } } });
    try std.testing.expectEqualStrings("frequency_re,frequency_im,v(out)_re,v(out)_im\n1e0,0e0,5e-1,-5e-1\n", w.buffered());
}

test "CSV with no points is the header row alone" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "csv", .result = .{ .plotname = "Transient", .varnames = &.{ "time", "v(out)" }, .is_complex = false, .npoints = 0, .data = &.{} } });
    try std.testing.expectEqualStrings("time,v(out)\n", w.buffered());
}

test "CSV round-trips every value through parseFloat, bit for bit" {
    const a = std.testing.allocator;
    var data: [3 * 40]f64 = undefined;
    const specials = [_]f64{ 0, -0.0, 5e-324, -2.2250738585072014e-308, std.math.floatMax(f64), std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), 0.1, 1.0 / 3.0 };
    var prng: std.Random.DefaultPrng = .init(0xc5f);
    for (&data, 0..) |*x, i| x.* = if (i < specials.len) specials[i] else @bitCast(prng.random().int(u64) & ~@as(u64, 0x7ff0_0000_0000_0000) | 0x3000_0000_0000_0000);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try encode(&out.writer, .{ .title = "t", .result = .{ .plotname = "p", .varnames = &.{ "time", "v(a)", "i(b)" }, .is_complex = false, .npoints = 40, .data = &data } });
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    try std.testing.expectEqualStrings("time,v(a),i(b)", lines.next().?);
    var i: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        var fields = std.mem.splitScalar(u8, line, ',');
        while (fields.next()) |f| : (i += 1) {
            const back = try std.fmt.parseFloat(f64, f);
            if (std.math.isNan(data[i])) try std.testing.expect(std.math.isNan(back)) else try std.testing.expectEqual(@as(u64, @bitCast(data[i])), @as(u64, @bitCast(back)));
        }
    }
    try std.testing.expectEqual(data.len, i);
    try std.testing.expectEqual(null, lines.next());
}
