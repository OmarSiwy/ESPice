const std = @import("std");
const Io = std.Io;

const types = @import("types.zig");
pub const Plot = types.Plot;

/// Infer the ngspice type string for a variable name.
/// "time" -> "time", "frequency" -> "frequency",
/// names containing "#branch" or starting with "i(" -> "current",
/// everything else -> "voltage".
pub fn varType(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "time")) return "time";
    if (std.mem.eql(u8, name, "frequency")) return "frequency";
    if (std.mem.startsWith(u8, name, "i(")) return "current";
    if (std.mem.indexOf(u8, name, "#branch") != null) return "current";
    return "voltage";
}

/// An ngspice-compatible binary raw plot: text header, then native-endian f64.
pub fn encode(w: *Io.Writer, plot: Plot) !void {
    try writeHeader(w, plot, true);
    try w.writeAll(std.mem.sliceAsBytes(plot.result.data));
}

pub inline fn writeHeader(w: *Io.Writer, plot: Plot, comptime binary: bool) !void {
    try w.print("Title: {s}\n", .{plot.title});
    try w.writeAll("Date: Thu Jan  1 00:00:00 1970\n");
    try w.print("Plotname: {s}\n", .{plot.result.plotname});
    if (plot.result.is_complex) {
        try w.writeAll("Flags: complex\n");
    } else {
        try w.writeAll("Flags: real\n");
    }
    try w.print("No. Variables: {d}\nNo. Points: {d}\n", .{ plot.result.varnames.len, plot.result.npoints });
    try w.writeAll("Variables:\n");
    for (plot.result.varnames, 0..) |name, i| {
        try w.print("\t{d}\t{s}\t{s}\n", .{ i, name, varType(name) });
    }
    try w.writeAll(if (binary) "Binary:\n" else "Values:\n");
}

// =============================================================================
// Tests
// =============================================================================

test "write and read back real .op raw file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const varnames = [_][]const u8{ "v(out)", "v(in)", "i(v1)#branch" };
    const data = [_]f64{ 1.5, 3.3, -0.001 }; // 1 point, 3 vars

    const plot: Plot = .{
        .title = "test op",
        .result = .{
            .plotname = "Operating Point",
            .varnames = &varnames,
            .is_complex = false,
            .npoints = 1,
            .data = &data,
        },
    };

    const path = "zig-out/test_op.raw";

    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};

    try @import("write.zig").write(io, path, .binary, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);

    const marker = "Binary:\n";
    const marker_pos = std.mem.indexOf(u8, blob, marker) orelse return error.MarkerNotFound;
    const header = blob[0..marker_pos];
    const bin_start = marker_pos + marker.len;

    try std.testing.expect(std.mem.indexOf(u8, header, "Title: test op\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Plotname: Operating Point\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Flags: real\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "No. Variables: 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "No. Points: 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t0\tv(out)\tvoltage\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t1\tv(in)\tvoltage\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t2\ti(v1)#branch\tcurrent\n") != null);

    const nvars = 3;
    const npoints = 1;
    const expected_bytes = nvars * npoints * @sizeOf(f64);
    try std.testing.expectEqual(expected_bytes, blob.len - bin_start);

    const read_data: [*]align(1) const f64 = @ptrCast(blob[bin_start..].ptr);
    try std.testing.expectApproxEqAbs(1.5, read_data[0], 1e-15);
    try std.testing.expectApproxEqAbs(3.3, read_data[1], 1e-15);
    try std.testing.expectApproxEqAbs(-0.001, read_data[2], 1e-15);
}

test "write and read back real .tran raw file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{
        0.0, 0.0, // point 0
        0.5, 1.0, // point 1
        1.0, 2.0, // point 2
    };

    const plot: Plot = .{
        .title = "test tran",
        .result = .{
            .plotname = "Transient Analysis",
            .varnames = &varnames,
            .is_complex = false,
            .npoints = 3,
            .data = &data,
        },
    };

    const path = "zig-out/test_tran.raw";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};

    try @import("write.zig").write(io, path, .binary, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);

    const marker = "Binary:\n";
    const marker_pos = std.mem.indexOf(u8, blob, marker) orelse return error.MarkerNotFound;
    const header = blob[0..marker_pos];
    const bin_start = marker_pos + marker.len;

    try std.testing.expect(std.mem.indexOf(u8, header, "Plotname: Transient Analysis\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "No. Variables: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "No. Points: 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t0\ttime\ttime\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t1\tv(out)\tvoltage\n") != null);

    const nvars = 2;
    const npoints = 3;
    const expected_bytes = nvars * npoints * @sizeOf(f64);
    try std.testing.expectEqual(expected_bytes, blob.len - bin_start);

    const read_data: [*]align(1) const f64 = @ptrCast(blob[bin_start..].ptr);
    try std.testing.expectApproxEqAbs(0.0, read_data[0], 1e-15); // time
    try std.testing.expectApproxEqAbs(0.0, read_data[1], 1e-15); // v(out)
    try std.testing.expectApproxEqAbs(0.5, read_data[2], 1e-15); // time
    try std.testing.expectApproxEqAbs(1.0, read_data[3], 1e-15); // v(out)
    try std.testing.expectApproxEqAbs(1.0, read_data[4], 1e-15); // time
    try std.testing.expectApproxEqAbs(2.0, read_data[5], 1e-15); // v(out)
}

test "write and read back complex .ac raw file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const varnames = [_][]const u8{ "frequency", "v(out)" };
    const data = [_]f64{
        1.0, 0.0, // frequency re, im
        0.5, -0.5, // v(out) re, im
        10.0, 0.0, // frequency re, im
        0.1, -0.9, // v(out) re, im
    };

    const plot: Plot = .{
        .title = "test ac",
        .result = .{
            .plotname = "AC Analysis",
            .varnames = &varnames,
            .is_complex = true,
            .npoints = 2,
            .data = &data,
        },
    };

    const path = "zig-out/test_ac.raw";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};

    try @import("write.zig").write(io, path, .binary, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);

    const marker = "Binary:\n";
    const marker_pos = std.mem.indexOf(u8, blob, marker) orelse return error.MarkerNotFound;
    const header = blob[0..marker_pos];
    const bin_start = marker_pos + marker.len;

    try std.testing.expect(std.mem.indexOf(u8, header, "Flags: complex\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "No. Variables: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "No. Points: 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t0\tfrequency\tfrequency\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "\t1\tv(out)\tvoltage\n") != null);

    const nvars = 2;
    const npoints = 2;
    const expected_bytes = nvars * npoints * 2 * @sizeOf(f64);
    try std.testing.expectEqual(expected_bytes, blob.len - bin_start);

    const read_data: [*]align(1) const f64 = @ptrCast(blob[bin_start..].ptr);
    // point 0, frequency (re, im)
    try std.testing.expectApproxEqAbs(1.0, read_data[0], 1e-15);
    try std.testing.expectApproxEqAbs(0.0, read_data[1], 1e-15);
    // point 0, v(out) (re, im)
    try std.testing.expectApproxEqAbs(0.5, read_data[2], 1e-15);
    try std.testing.expectApproxEqAbs(-0.5, read_data[3], 1e-15);
    // point 1, frequency (re, im)
    try std.testing.expectApproxEqAbs(10.0, read_data[4], 1e-15);
    try std.testing.expectApproxEqAbs(0.0, read_data[5], 1e-15);
    // point 1, v(out) (re, im)
    try std.testing.expectApproxEqAbs(0.1, read_data[6], 1e-15);
    try std.testing.expectApproxEqAbs(-0.9, read_data[7], 1e-15);
}

test "data length mismatch returns error" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "v(a)", "v(b)" };
    const data = [_]f64{ 1.0, 2.0, 3.0 }; // 3 values but 2 vars * 2 points = 4 expected

    const plot: Plot = .{
        .title = "bad",
        .result = .{
            .plotname = "bad",
            .varnames = &varnames,
            .is_complex = false,
            .npoints = 2,
            .data = &data,
        },
    };

    const result = @import("write.zig").write(io, "zig-out/should_not_exist.raw", .binary, plot);
    try std.testing.expectError(error.DataLengthMismatch, result);
}

test "varType inference" {
    try std.testing.expectEqualStrings("time", varType("time"));
    try std.testing.expectEqualStrings("frequency", varType("frequency"));
    try std.testing.expectEqualStrings("current", varType("i(v1)"));
    try std.testing.expectEqualStrings("current", varType("vdd#branch"));
    try std.testing.expectEqualStrings("voltage", varType("v(out)"));
    try std.testing.expectEqualStrings("voltage", varType("v(1)"));
}
