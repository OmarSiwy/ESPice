//! SPICE3 `.print`-style text table: a plot line, a header row, a dashed
//! rule, then one tab-separated row per point.
const std = @import("std");
const Io = std.Io;
const Plot = @import("types.zig").Plot;

/// Writes `plot`, which must have passed `types.validatePlot(.print, ...)`.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    try w.print("{s}: {s}\n", .{ plot.result.plotname, plot.title });
    try w.writeAll("Index");
    for (plot.result.varnames) |name| {
        try w.writeByte('\t');
        try w.writeAll(name);
        if (plot.result.is_complex) try w.writeAll("\t(imag)");
    }
    try w.writeAll("\n-----");
    const columns = plot.result.varnames.len * @as(usize, if (plot.result.is_complex) 2 else 1);
    for (0..columns) |_| try w.writeAll("\t---------------");
    try w.writeByte('\n');
    for (0..plot.result.npoints) |pt| {
        try w.print("{d}", .{pt});
        for (plot.point(pt)) |x| try w.print("\t{e}", .{x});
        try w.writeByte('\n');
    }
}

test "SPICE3 print table" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "ac", .result = .{ .plotname = "AC Analysis", .varnames = &.{ "frequency", "v(out)" }, .is_complex = true, .npoints = 1, .data = &.{ 1.0, 0.0, 0.5, -0.5 } } });
    try std.testing.expectEqualStrings("AC Analysis: ac\nIndex\tfrequency\t(imag)\tv(out)\t(imag)\n" ++
        "-----\t---------------\t---------------\t---------------\t---------------\n0\t1e0\t0e0\t5e-1\t-5e-1\n", w.buffered());
}
