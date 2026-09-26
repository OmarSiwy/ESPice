//! CSV: a header row of variable names, then one row per point. A complex
//! variable becomes a `_re` and an `_im` column.
const std = @import("std");
const Io = std.Io;
const Plot = @import("types.zig").Plot;

pub fn encode(w: *Io.Writer, plot: Plot) !void {
    for (plot.result.varnames, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        if (plot.result.is_complex) {
            try w.print("{s}_re,{s}_im", .{ name, name });
        } else {
            try w.writeAll(name);
        }
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

test "CSV real and complex layouts" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "csv", .result = .{ .plotname = "Transient", .varnames = &.{ "time", "v(out)" }, .is_complex = false, .npoints = 2, .data = &.{ 0.0, 1.0, 0.5, 2.0 } } });
    try std.testing.expectEqualStrings("time,v(out)\n0e0,1e0\n5e-1,2e0\n", w.buffered());

    w = .fixed(&buf);
    try encode(&w, .{ .title = "ac", .result = .{ .plotname = "AC", .varnames = &.{ "frequency", "v(out)" }, .is_complex = true, .npoints = 1, .data = &.{ 1.0, 0.0, 0.5, -0.5 } } });
    try std.testing.expectEqualStrings("frequency_re,frequency_im,v(out)_re,v(out)_im\n1e0,0e0,5e-1,-5e-1\n", w.buffered());
}
