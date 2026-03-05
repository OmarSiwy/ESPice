const std = @import("std");
const Io = std.Io;
const types = @import("output_types");
const Plot = types.Plot;

/// Write CITIfile format. Only valid for S-parameter data.
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    try types.validatePlot(.citi, plot);
    const nvars = plot.varnames.len;

    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll("CITIFILE A.01.01\n");
    try w.print("NAME {s}\n", .{plot.plotname});
    try w.print("VAR frequency MAG {d}\n", .{plot.npoints});

    try w.writeAll("VAR_LIST_BEGIN\n");
    for (0..plot.npoints) |pt| {
        const freq = plot.data[pt * nvars * 2]; // real part of frequency
        try w.print("{e}\n", .{freq});
    }
    try w.writeAll("VAR_LIST_END\n");

    for (plot.varnames, 0..) |name, vi| {
        const ports = types.sParameter(name) orelse continue;
        try w.print("DATA S[{d},{d}] RI\n", .{ ports[0], ports[1] });

        for (0..plot.npoints) |pt| {
            const idx = pt * nvars * 2 + vi * 2;
            try w.print("{e},{e}\n", .{ plot.data[idx], plot.data[idx + 1] });
        }
    }

    try w.writeAll("BEGIN\nEND\n");
    try w.flush();
}

test "CITIfile 2-port write" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const varnames = [_][]const u8{ "frequency", "S(1,1)", "S(2,1)" };
    const data = [_]f64{
        1.0e9, 0.0, 0.5, -0.3, 0.1, -0.05, // point 0
        2.0e9, 0.0, 0.4, -0.2, 0.2, -0.04, // point 1
    };
    const plot: Plot = .{ .title = "citi", .plotname = "S-Parameter Analysis", .varnames = &varnames, .is_complex = true, .npoints = 2, .data = &data };
    const path = "zig-out/test.citi";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try write(io, path, plot);
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const blob = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(blob);
    try std.testing.expect(std.mem.indexOf(u8, blob, "CITIFILE A.01.01\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "VAR_LIST_BEGIN\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "DATA S[1,1] RI\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob, "DATA S[2,1] RI\n") != null);
}

test "CITIfile rejects non-S-parameter" {
    const io = std.testing.io;
    const varnames = [_][]const u8{ "time", "v(out)" };
    const data = [_]f64{ 0.0, 1.0 };
    const plot: Plot = .{ .title = "bad", .plotname = "Transient", .varnames = &varnames, .is_complex = false, .npoints = 1, .data = &data };
    try std.testing.expectError(error.NotSParameterData, write(io, "zig-out/bad.citi", plot));
}

test "S-parameter labels accept both producers and reject malformed port identities" {
    try std.testing.expectEqual([2]u32{ 12, 3 }, types.sParameter("S(12,3)").?);
    try std.testing.expectEqual([2]u32{ 12, 3 }, types.sParameter("v(S_12_3)").?);
    for ([_][]const u8{ "S()", "S(0,1)", "S(1,)", "S(1,2,3)", "v(S_)", "v(S_1_0)", "v(S_1_2_3)", "v(S_+1_2)", "v(S_4294967296_1)" }) |name| {
        try std.testing.expect(types.sParameter(name) == null);
        try std.testing.expectError(error.NotSParameterData, types.validateSchema(.citi, .{
            .varnames = &.{ "frequency", "S(1,1)", name },
            .is_complex = true,
        }));
    }
}
