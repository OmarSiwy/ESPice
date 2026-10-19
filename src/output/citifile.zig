//! CITIfile: a header declaring the FREQ variable and every S-parameter
//! DATA, the frequency list, then one BEGIN/END block of real,imaginary
//! pairs per DATA in header order. Variables that are not S parameters are
//! skipped.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const types = @import("types.zig");
const Plot = types.Plot;

/// Writes `plot`, which must have passed `types.validatePlot(.citi, ...)`.
/// Asserts that it is complex with one sample row per point.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    assert(plot.result.is_complex);
    assert(plot.result.data.len == plot.result.npoints * plot.stride());
    try w.writeAll("CITIFILE A.01.01\n");
    // NAME is one word.
    try w.writeAll("NAME ");
    for (plot.result.plotname) |c| try w.writeByte(if (c == ' ' or c == '\t') '_' else c);
    try w.print("\nVAR FREQ MAG {d}\n", .{plot.result.npoints});
    for (plot.result.varnames) |name| {
        const ports = types.sParameter(name) orelse continue;
        try w.print("DATA S[{d},{d}] RI\n", .{ ports[0], ports[1] });
    }
    try w.writeAll("VAR_LIST_BEGIN\n");
    for (0..plot.result.npoints) |pt| try w.print("{e}\n", .{plot.point(pt)[0]});
    try w.writeAll("VAR_LIST_END\n");
    for (plot.result.varnames, 0..) |name, vi| {
        if (types.sParameter(name) == null) continue;
        try w.writeAll("BEGIN\n");
        for (0..plot.result.npoints) |pt| {
            const row = plot.point(pt);
            try w.print("{e},{e}\n", .{ row[2 * vi], row[2 * vi + 1] });
        }
        try w.writeAll("END\n");
    }
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
    // The layout scikit-rf 1.9's CITIfile reader takes (#61).
    try std.testing.expectEqualStrings("CITIFILE A.01.01\nNAME S-Parameter_Analysis\nVAR FREQ MAG 2\n" ++
        "DATA S[1,1] RI\nDATA S[2,1] RI\nVAR_LIST_BEGIN\n1e9\n2e9\nVAR_LIST_END\n" ++
        "BEGIN\n5e-1,-3e-1\n4e-1,-2e-1\nEND\nBEGIN\n1e-1,-5e-2\n2e-1,-4e-2\nEND\n", w.buffered());
}

test "CITIfile skips columns that are not S parameters" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "c", .result = .{ .plotname = "sp", .varnames = &.{ "frequency", "NFMIN", "v(S_1_1)" }, .is_complex = true, .npoints = 1, .data = &.{ 1, 0, 9, 9, 0.5, -0.5 } } });
    try std.testing.expectEqualStrings("CITIFILE A.01.01\nNAME sp\nVAR FREQ MAG 1\nDATA S[1,1] RI\nVAR_LIST_BEGIN\n1e0\nVAR_LIST_END\nBEGIN\n5e-1,-5e-1\nEND\n", w.buffered());
}
