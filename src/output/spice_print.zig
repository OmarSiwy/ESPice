const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

/// Write SPICE3-style tabular text output (.print/.plot format).
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const nvars = plot.result.varnames.len;

    try w.print("{s}: {s}\n", .{ plot.result.plotname, plot.title });
    try w.writeAll("Index");
    for (plot.result.varnames) |name| {
        try w.writeByte('\t');
        try w.writeAll(name);
        if (plot.result.is_complex) {
            try w.writeAll("\t(imag)");
        }
    }
    try w.writeByte('\n');

    try w.writeAll("-----");
    for (0..nvars) |_| {
        try w.writeAll("\t---------------");
        if (plot.result.is_complex) try w.writeAll("\t---------------");
    }
    try w.writeByte('\n');

    for (0..plot.result.npoints) |pt| {
        try w.print("{d}", .{pt});
        for (0..nvars) |v| {
            if (plot.result.is_complex) {
                const idx = pt * nvars * 2 + v * 2;
                try w.print("\t{e}\t{e}", .{ plot.result.data[idx], plot.result.data[idx + 1] });
            } else {
                try w.print("\t{e}", .{plot.result.data[pt * nvars + v]});
            }
        }
        try w.writeByte('\n');
    }
}

test "SPICE3 print real data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0, 0.5, 2.0 };
    const plot: Plot = .{ .title = "test", .result = .{ .plotname = "Transient Analysis", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data } };
    const path = "zig-out/test_print.txt";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .print, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "time") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "-----") != null);
}

test "SPICE3 print complex data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5 };
    const plot: Plot = .{ .title = "ac", .result = .{ .plotname = "AC Analysis", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data } };
    const path = "zig-out/test_print_ac.txt";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .print, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "(imag)") != null);
}
