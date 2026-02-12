const std = @import("std");
const Io = std.Io;
const rawfile = @import("rawfile.zig");
const Plot = rawfile.Plot;

/// Write an ngspice-compatible ASCII raw file (same header as binary, text data).
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    const nvars = plot.varnames.len;
    const per: usize = if (plot.is_complex) 2 else 1;
    if (plot.data.len != plot.npoints * nvars * per) return error.DataLengthMismatch;

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    _ = try rawfile.writeHeader(&fw, plot, false, false);

    for (0..plot.npoints) |pt| {
        for (0..nvars) |v| {
            if (v == 0) {
                try w.print("{d}\t", .{pt});
            } else {
                try w.writeByte('\t');
            }
            if (plot.is_complex) {
                const idx = pt * nvars * 2 + v * 2;
                try w.print("{e},{e}\n", .{ plot.data[idx], plot.data[idx + 1] });
            } else {
                try w.print("{e}\n", .{plot.data[pt * nvars + v]});
            }
        }
    }
    try w.flush();
}

test "ASCII real raw file round-trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "v(out)", "i(v1)#branch" };
    const data = [_]f64{ 1.5, -0.001 };
    const plot: Plot = .{ .title = "test ascii", .plotname = "Operating Point", .varnames = &varnames, .is_complex = false, .npoints = 1, .data = &data };
    const path = "zig-out/test_ascii.raw";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "Values:\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "Flags: real\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "Binary:") == null);
}

test "ASCII complex raw file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5 };
    const plot: Plot = .{ .title = "ac", .plotname = "AC Analysis", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data };
    const path = "zig-out/test_ascii_ac.raw";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "Flags: complex\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "Values:\n") != null);
}

test "ASCII data length mismatch" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "v(a)", "v(b)" };
    const data = [_]f64{ 1.0, 2.0, 3.0 };
    const plot: Plot = .{ .title = "bad", .plotname = "bad", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data };
    try std.testing.expectError(error.DataLengthMismatch, write(io, "zig-out/bad.raw", plot));
}
