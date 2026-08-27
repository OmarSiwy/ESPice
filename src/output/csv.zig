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
