//! CITIfile: the frequency list, then one real/imaginary DATA block per
//! S-parameter variable. Variables that are not S parameters are skipped.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

/// Writes `plot`, which must have passed `types.validatePlot(.citi, ...)`:
/// complex, `frequency` first.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    try w.writeAll("CITIFILE A.01.01\n");
    try w.print("NAME {s}\n", .{plot.result.plotname});
    try w.print("VAR frequency MAG {d}\n", .{plot.result.npoints});
    try w.writeAll("VAR_LIST_BEGIN\n");
    for (0..plot.result.npoints) |pt| try w.print("{e}\n", .{plot.point(pt)[0]});
    try w.writeAll("VAR_LIST_END\n");
    for (plot.result.varnames, 0..) |name, vi| {
        const ports = types.sParameter(name) orelse continue;
        try w.print("DATA S[{d},{d}] RI\n", .{ ports[0], ports[1] });
        for (0..plot.result.npoints) |pt| {
            const row = plot.point(pt);
            try w.print("{e},{e}\n", .{ row[2 * vi], row[2 * vi + 1] });
        }
    }
    try w.writeAll("BEGIN\nEND\n");
}

test "CITIfile 2-port write" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "citi", .result = .{
        .plotname = "S-Parameter Analysis",
        .varnames = &.{ "frequency", "S(1,1)", "S(2,1)" },
        .is_complex = true,
        .npoints = 2,
        .data = &.{ 1.0e9, 0.0, 0.5, -0.3, 0.1, -0.05, 2.0e9, 0.0, 0.4, -0.2, 0.2, -0.04 },
    } });
    try std.testing.expectEqualStrings("CITIFILE A.01.01\nNAME S-Parameter Analysis\nVAR frequency MAG 2\n" ++
        "VAR_LIST_BEGIN\n1e9\n2e9\nVAR_LIST_END\nDATA S[1,1] RI\n5e-1,-3e-1\n4e-1,-2e-1\n" ++
        "DATA S[2,1] RI\n1e-1,-5e-2\n2e-1,-4e-2\nBEGIN\nEND\n", w.buffered());
}
