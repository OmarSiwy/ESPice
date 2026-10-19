//! Cadence PSF ASCII. A plot with more than one point writes its first
//! variable as the SWEEP and the rest as TRACEs; a single point writes every
//! variable as a TRACE.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Plot = @import("types.zig").Plot;

/// Writes `plot`, which must have passed `types.validatePlot(.psf, ...)`.
/// Asserts that it has variables and one sample row per point.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    assert(plot.result.varnames.len > 0);
    assert(plot.result.data.len == plot.result.npoints * plot.stride());
    const names = plot.result.varnames;
    const complex = plot.result.is_complex;
    try w.writeAll("HEADER\n");
    try w.writeAll("\"PSFversion\" \"1.00\"\n");
    try w.writeAll("\"simulator\" \"espice\"\n");
    try w.writeAll("\"title\" ");
    try string(w, plot.title);
    try w.writeAll("\n\"plotname\" ");
    try string(w, plot.result.plotname);
    try w.writeByte('\n');
    try w.writeAll("TYPE\n");
    try w.writeAll("\"real\" FLOAT DOUBLE\n");
    if (complex) try w.writeAll("\"complex\" COMPLEX DOUBLE\n");

    const has_sweep = plot.result.npoints > 1;
    const first_trace: usize = @intFromBool(has_sweep);
    if (has_sweep) {
        try w.writeAll("SWEEP\n");
        try string(w, names[0]);
        try w.writeAll(" \"real\"\n");
    }
    try w.writeAll("TRACE\n");
    for (names[first_trace..]) |name| {
        try string(w, name);
        try w.print(" \"{s}\"\n", .{if (complex) "complex" else "real"});
    }

    for (0..plot.result.npoints) |pt| {
        const row = plot.point(pt);
        try w.writeAll("VALUE\n");
        // The sweep is written as real: its real part in either layout.
        if (has_sweep) {
            try string(w, names[0]);
            try w.print(" {e}\n", .{row[0]});
        }
        for (first_trace..names.len) |v| {
            try string(w, names[v]);
            if (complex) {
                try w.print(" ({e} {e})\n", .{ row[2 * v], row[2 * v + 1] });
            } else {
                try w.print(" {e}\n", .{row[v]});
            }
        }
    }
    try w.writeAll("END\n");
}

/// `s` as a PSF string: quoted, its quotes and backslashes escaped (#61).
fn string(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

test "PSF: quotes and backslashes in strings are escaped" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "a \"q\" b\\s", .result = .{ .plotname = "Operating Point", .varnames = &.{"v(\"x\")"}, .is_complex = false, .npoints = 1, .data = &.{1} } });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"title\" \"a \\\"q\\\" b\\\\s\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "VALUE\n\"v(\\\"x\\\")\" 1e0\n") != null);
}

test "PSF: a single point has no SWEEP" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "op test", .result = .{ .plotname = "Operating Point", .varnames = &.{ "v(out)", "v(in)" }, .is_complex = false, .npoints = 1, .data = &.{ 1.5, 3.3 } } });
    try std.testing.expectEqualStrings("HEADER\n\"PSFversion\" \"1.00\"\n\"simulator\" \"espice\"\n\"title\" \"op test\"\n" ++
        "\"plotname\" \"Operating Point\"\nTYPE\n\"real\" FLOAT DOUBLE\nTRACE\n\"v(out)\" \"real\"\n\"v(in)\" \"real\"\n" ++
        "VALUE\n\"v(out)\" 1.5e0\n\"v(in)\" 3.3e0\nEND\n", w.buffered());
}

test "PSF: a complex sweep writes its first variable as a real SWEEP" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, .{ .title = "ac psf", .result = .{ .plotname = "AC Analysis", .varnames = &.{ "frequency", "v(out)" }, .is_complex = true, .npoints = 2, .data = &.{ 1.0, 0.0, 0.5, -0.5, 10.0, 0.0, 0.1, -0.9 } } });
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\"complex\" COMPLEX DOUBLE\nSWEEP\n\"frequency\" \"real\"\nTRACE\n\"v(out)\" \"complex\"\n" ++
        "VALUE\n\"frequency\" 1e0\n\"v(out)\" (5e-1 -5e-1)\nVALUE\n\"frequency\" 1e1\n\"v(out)\" (1e-1 -9e-1)\nEND\n"));
}
