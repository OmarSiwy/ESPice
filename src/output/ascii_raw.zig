//! ngspice ASCII raw file: the binary raw header, then one text line per
//! variable, each point's first line led by the point index.
const std = @import("std");
const Io = std.Io;
const rawfile = @import("rawfile.zig");
const Plot = @import("types.zig").Plot;

/// Writes `plot`, which must have passed `types.validatePlot(.ascii, ...)`.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    try rawfile.writeHeader(w, plot, false);
    for (0..plot.result.npoints) |pt| {
        const row = plot.point(pt);
        try w.print("{d}", .{pt});
        for (0..plot.result.varnames.len) |v| {
            if (plot.result.is_complex) {
                try w.print("\t{e},{e}\n", .{ row[2 * v], row[2 * v + 1] });
            } else {
                try w.print("\t{e}\n", .{row[v]});
            }
        }
    }
}

test "ASCII raw values follow the Values: header" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "ac", .result = .{
        .plotname = "AC Analysis",
        .varnames = &.{ "frequency", "v(out)" },
        .is_complex = true,
        .npoints = 1,
        .data = &.{ 1.0, 0.0, 0.5, -0.5 },
    } });
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "Flags: complex\nNo. Variables: 2\nNo. Points: 1\n" ++
        "Variables:\n\t0\tfrequency\tfrequency\n\t1\tv(out)\tvoltage\nValues:\n0\t1e0,0e0\n\t5e-1,-5e-1\n"));
}

test "ASCII raw writes one line per real variable" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "t", .result = .{ .plotname = "Transient", .varnames = &.{ "time", "v(a)" }, .is_complex = false, .npoints = 2, .data = &.{ 0, 1, 0.5, -2 } } });
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "Values:\n0\t0e0\n\t1e0\n1\t5e-1\n\t-2e0\n"));
}
