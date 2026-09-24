const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const Plot = types.Plot;

/// Write Touchstone (.snp) format. Only valid for S-parameter analysis data.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    const n_ports = try types.portCount(plot.schema());
    const nvars = plot.result.varnames.len;

    try w.print("! {s}\n", .{plot.title});
    try w.writeAll("# Hz S RI R 50\n");

    for (0..plot.result.npoints) |pt| {
        const base = pt * nvars * 2;
        // Frequency (real part only, imag is always 0)
        try w.print("{e}", .{plot.result.data[base]});

        if (n_ports <= 2) {
            // 2-port spec order: S11, S21, S12, S22 (column-major)
            if (n_ports == 1) {
                try w.print(" {e} {e}", .{ plot.result.data[base + 2], plot.result.data[base + 3] });
            } else {
                // Row-major in data: S(1,1)=1 S(1,2)=2 S(2,1)=3 S(2,2)=4
                // Touchstone 2-port order: S11=1 S21=3 S12=2 S22=4
                const order = [_]usize{ 1, 3, 2, 4 };
                for (order) |vi| {
                    try w.print(" {e} {e}", .{ plot.result.data[base + vi * 2], plot.result.data[base + vi * 2 + 1] });
                }
            }
            try w.writeByte('\n');
        } else {
            // n-port: row-major matrix, one row per line
            try w.writeByte('\n');
            for (0..n_ports) |m| {
                for (0..n_ports) |n| {
                    const vi = 1 + m * n_ports + n;
                    try w.print(" {e} {e}", .{ plot.result.data[base + vi * 2], plot.result.data[base + vi * 2 + 1] });
                }
                try w.writeByte('\n');
            }
        }
    }
}

test "Touchstone 2-port write" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "S(1,1)", "S(1,2)", "S(2,1)", "S(2,2)" };
    const data = [_]f64{
        1.0e9, 0.0, // frequency
        0.5, -0.3, // S(1,1)
        0.8, 0.1, // S(1,2)
        0.1, -0.05, // S(2,1)
        0.4, -0.2, // S(2,2)
    };
    const plot: Plot = .{ .title = "s2p test", .result = .{ .plotname = "S-Parameter Analysis", .varnames = &varnames, .is_complex = true, .npoints = 1, .data = &data } };
    const path = "zig-out/test.s2p";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try @import("write.zig").write(io, path, .touchstone, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "# Hz S RI R 50\n") != null);
    // Verify column-major reorder: S21 data (0.1, -0.05) appears before S12 data (0.8, 0.1)
    const s21_pos = std.mem.indexOf(u8, blob, "-5e-2") orelse std.mem.indexOf(u8, blob, "-0.05");
    const s12_pos = std.mem.indexOf(u8, blob, "8e-1") orelse std.mem.indexOf(u8, blob, "0.8");
    if (s21_pos != null and s12_pos != null) {
        try std.testing.expect(s21_pos.? < s12_pos.?);
    }
}

test "Touchstone rejects non-S-parameter data" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0 };
    const plot: Plot = .{ .title = "bad", .result = .{ .plotname = "Transient", .varnames = &varnames, .is_complex = false, .npoints = 1, .data = &data } };
    try std.testing.expectError(error.NotSParameterData, @import("write.zig").write(io, "zig-out/bad.s2p", .touchstone, plot));
}
