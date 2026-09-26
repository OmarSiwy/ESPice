//! ngspice binary raw file: a text header, then the samples as native-endian
//! f64. ascii_raw.zig shares the header.
const std = @import("std");
const Io = std.Io;
const Plot = @import("types.zig").Plot;

/// ngspice's variable type for a name: time, frequency, current for `i(...)`
/// and `#branch` names, voltage otherwise.
fn varType(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "time")) return "time";
    if (std.mem.eql(u8, name, "frequency")) return "frequency";
    if (std.mem.startsWith(u8, name, "i(")) return "current";
    if (std.mem.indexOf(u8, name, "#branch") != null) return "current";
    return "voltage";
}

pub fn encode(w: *Io.Writer, plot: Plot) !void {
    try writeHeader(w, plot, true);
    try w.writeAll(std.mem.sliceAsBytes(plot.result.data));
}

/// Writes the raw header up to and including `Binary:` or `Values:`.
/// The date is fixed so output is reproducible.
pub fn writeHeader(w: *Io.Writer, plot: Plot, comptime binary: bool) !void {
    try w.print("Title: {s}\n", .{plot.title});
    try w.writeAll("Date: Thu Jan  1 00:00:00 1970\n");
    try w.print("Plotname: {s}\n", .{plot.result.plotname});
    try w.writeAll(if (plot.result.is_complex) "Flags: complex\n" else "Flags: real\n");
    try w.print("No. Variables: {d}\nNo. Points: {d}\n", .{ plot.result.varnames.len, plot.result.npoints });
    try w.writeAll("Variables:\n");
    for (plot.result.varnames, 0..) |name, i| {
        try w.print("\t{d}\t{s}\t{s}\n", .{ i, name, varType(name) });
    }
    try w.writeAll(if (binary) "Binary:\n" else "Values:\n");
}

fn expectRaw(plot: Plot, header: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try encode(&w, plot);
    try std.testing.expectEqualStrings(header, w.buffered()[0..header.len]);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(plot.result.data), w.buffered()[header.len..]);
}

test "binary raw: real plot" {
    try expectRaw(.{ .title = "test tran", .result = .{
        .plotname = "Transient Analysis",
        .varnames = &.{ "time", "v(out)", "i(v1)" },
        .is_complex = false,
        .npoints = 2,
        .data = &.{ 0.0, 1.5, -0.001, 0.5, 3.3, 0.002 },
    } }, "Title: test tran\nDate: Thu Jan  1 00:00:00 1970\nPlotname: Transient Analysis\nFlags: real\n" ++
        "No. Variables: 3\nNo. Points: 2\nVariables:\n\t0\ttime\ttime\n\t1\tv(out)\tvoltage\n\t2\ti(v1)\tcurrent\nBinary:\n");
}

test "binary raw: complex plot" {
    try expectRaw(.{ .title = "test ac", .result = .{
        .plotname = "AC Analysis",
        .varnames = &.{ "frequency", "vdd#branch" },
        .is_complex = true,
        .npoints = 2,
        .data = &.{ 1.0, 0.0, 0.5, -0.5, 10.0, 0.0, 0.1, -0.9 },
    } }, "Title: test ac\nDate: Thu Jan  1 00:00:00 1970\nPlotname: AC Analysis\nFlags: complex\n" ++
        "No. Variables: 2\nNo. Points: 2\nVariables:\n\t0\tfrequency\tfrequency\n\t1\tvdd#branch\tcurrent\nBinary:\n");
}
