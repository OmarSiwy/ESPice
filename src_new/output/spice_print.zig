const std = @import("std");
const Io = std.Io;
const Plot = @import("rawfile.zig").Plot;

/// Write SPICE3-style tabular text output (.print/.plot format).
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    const nvars = plot.varnames.len;
    const per: usize = if (plot.is_complex) 2 else 1;
    if (plot.data.len != plot.npoints * nvars * per) return error.DataLengthMismatch;

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    // Header
    try w.print("{s}: {s}\n", .{ plot.plotname, plot.title });
    try w.writeAll("Index");
    for (plot.varnames) |name| {
        try w.writeByte('\t');
        try w.writeAll(name);
        if (plot.is_complex) {
            try w.writeAll("\t(imag)");
        }
    }
    try w.writeByte('\n');

    // Separator
    try w.writeAll("-----");
    for (0..nvars) |_| {
        try w.writeAll("\t---------------");
        if (plot.is_complex) try w.writeAll("\t---------------");
    }
    try w.writeByte('\n');

    // Data
    for (0..plot.npoints) |pt| {
        try w.print("{d}", .{pt});
        for (0..nvars) |v| {
            if (plot.is_complex) {
                const idx = pt * nvars * 2 + v * 2;
                try w.print("\t{e}\t{e}", .{ plot.data[idx], plot.data[idx + 1] });
            } else {
                try w.print("\t{e}", .{plot.data[pt * nvars + v]});
            }
        }
        try w.writeByte('\n');
    }
    try w.flush();
}

test "SPICE3 print real data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0, 0.5, 2.0 };
    const plot: Plot = .{ .title = "test", .plotname = "Transient Analysis", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data };
    const path = "zig-out/test_print.txt";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
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
    const plot: Plot = .{ .title = "ac", .plotname = "AC Analysis", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data };
    const path = "zig-out/test_print_ac.txt";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "(imag)") != null);
}
