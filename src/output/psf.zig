const std = @import("std");
const Io = std.Io;
const types = @import("output_types");
const Plot = types.Plot;

/// Write Cadence PSF ASCII format.
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    const nvars = plot.varnames.len;
    const per: usize = if (plot.is_complex) 2 else 1;
    try types.validatePlot(.psf, plot);

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll("HEADER\n");
    try w.writeAll("\"PSFversion\" \"1.00\"\n");
    try w.writeAll("\"simulator\" \"espice\"\n");
    try w.print("\"title\" \"{s}\"\n", .{plot.title});
    try w.print("\"plotname\" \"{s}\"\n", .{plot.plotname});

    try w.writeAll("TYPE\n");
    try w.writeAll("\"real\" FLOAT DOUBLE\n");
    if (plot.is_complex) try w.writeAll("\"complex\" COMPLEX DOUBLE\n");

    const has_sweep = plot.npoints > 1 and nvars > 0;
    const trace_start: usize = if (has_sweep) 1 else 0;

    if (has_sweep) {
        try w.writeAll("SWEEP\n");
        try w.print("\"{s}\" \"real\"\n", .{plot.varnames[0]});
    }

    try w.writeAll("TRACE\n");
    const type_str: []const u8 = if (plot.is_complex) "complex" else "real";
    for (trace_start..nvars) |v| {
        try w.print("\"{s}\" \"{s}\"\n", .{ plot.varnames[v], type_str });
    }

    for (0..plot.npoints) |pt| {
        try w.writeAll("VALUE\n");
        if (has_sweep) {
            // Sweep variable always written as real
            // ponytail: the existing stride selects the real part in either layout.
            try w.print("\"{s}\" {e}\n", .{ plot.varnames[0], plot.data[pt * nvars * per] });
        }
        for (trace_start..nvars) |v| {
            if (plot.is_complex) {
                const idx = pt * nvars * 2 + v * 2;
                try w.print("\"{s}\" ({e} {e})\n", .{ plot.varnames[v], plot.data[idx], plot.data[idx + 1] });
            } else {
                try w.print("\"{s}\" {e}\n", .{ plot.varnames[v], plot.data[pt * nvars + v] });
            }
        }
    }

    try w.writeAll("END\n");
    try w.flush();
}

test "PSF real single-point (OP)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "v(out)", "v(in)" };
    const data = [_]f64{ 1.5, 3.3 };
    const plot: Plot = .{ .title = "op test", .plotname = "Operating Point", .varnames = &varnames, .is_complex = false, .npoints = 1, .data = &data };
    const path = "zig-out/test.psf";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "HEADER\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "\"PSFversion\" \"1.00\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "TRACE\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "\"v(out)\" \"real\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "END\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "SWEEP\n") == null);
}

test "PSF complex swept (AC)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{ 1.0, 0.0, 0.5, -0.5, 10.0, 0.0, 0.1, -0.9 };
    const plot: Plot = .{ .title = "ac psf", .plotname = "AC Analysis", .varnames = &varnames, .is_complex = true, .npoints = 2, .data = &data };
    const path = "zig-out/test_ac.psf";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "SWEEP\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "\"frequency\" \"real\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "\"complex\" COMPLEX DOUBLE\n") != null);
}

test "PSF data length mismatch" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "v(a)", "v(b)" };
    const data = [_]f64{ 1.0, 2.0, 3.0 };
    const plot: Plot = .{ .title = "bad", .plotname = "bad", .varnames = &varnames, .is_complex = false, .npoints = 2, .data = &data };
    try std.testing.expectError(error.DataLengthMismatch, write(io, "zig-out/bad.psf", plot));
}
