const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

/// Write simulation data as CSV. Complex variables split into _re/_im columns.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const nvars = plot.result.varnames.len;

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
        for (0..nvars) |v| {
            if (v > 0) try w.writeByte(',');
            if (plot.result.is_complex) {
                const idx = pt * nvars * 2 + v * 2;
                try w.print("{e},{e}", .{ plot.result.data[idx], plot.result.data[idx + 1] });
            } else {
                try w.print("{e}", .{plot.result.data[pt * nvars + v]});
            }
        }
        try w.writeByte('\n');
    }
}

test "CSV real data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0, 0.5, 2.0 };
    const plot: Plot = .{ .title = "csv", .result = .{ .plotname = "Transient", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data } };
    const path = "zig-out/test.csv";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .csv, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.startsWith(u8, blob, "time,v(out)\n"));
    // Verify 2 data rows + header = 3 lines
    const lines = std.mem.countScalar(u8, blob, '\n');
    try std.testing.expectEqual(@as(usize, 3), lines);
}

test "CSV complex data" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5 };
    const plot: Plot = .{ .title = "ac", .result = .{ .plotname = "AC", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data } };
    const path = "zig-out/test_ac.csv";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .csv, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.startsWith(u8, blob, "frequency_re,frequency_im,v(out)_re,v(out)_im\n"));
}

test "CSV data length mismatch" {
    const io = std.testing.io;
    const varnames = [_][]const u8{"v(a)"};
    const data = [_]f64{ 1.0, 2.0 };
    const plot: Plot = .{ .title = "bad", .result = .{ .plotname = "bad", .varnames = &varnames, .is_complex = false, .npoints = 1, .data = &data } };
    try std.testing.expectError(error.DataLengthMismatch, @import("write.zig").write(io, "zig-out/bad.csv", .csv, plot));
}
