const std = @import("std");
const Io = std.Io;

pub const Plot = struct {
    title: []const u8,
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    /// Point-major: all vars for point 0, then all vars for point 1, ...
    /// For real data: length = npoints * nvars
    /// For complex data: length = npoints * nvars * 2 (re,im pairs per variable)
    data: []const f64,
};

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

/// Write an ngspice-compatible binary raw file to `path`.
pub fn write(io: Io, path: []const u8, plot: Plot) !void {
    return writeInner(io, path, plot, false);
}

/// A multi-analysis deck produces one plot per directive; ngspice appends
/// them all to ONE raw file, and consumers (the benchmark runner included)
/// read the concatenation. Result 2+ goes through this.
pub fn writeAppend(io: Io, path: []const u8, plot: Plot) !void {
    return writeInner(io, path, plot, true);
}

/// Atomic replacement suits new files and regular files with no other links.
pub fn canStream(io: Io, path: []const u8) Io.Dir.StatFileError!bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    return stat.kind == .file and stat.nlink == 1;
}

/// One real transient plot; finish publishes it, deinit discards unfinished output.
/// varnames includes the time column. The destination path must outlive the stream.
pub const Stream = struct {
    atomic: Io.File.Atomic,
    writer: Io.File.Writer,
    row: []f64,
    npoints: usize = 0,
    count_offset: u64,
    allocator: std.mem.Allocator,

    pub fn init(io: Io, allocator: std.mem.Allocator, path: []const u8, title: []const u8, varnames: []const []const u8) !Stream {
        if (varnames.len == 0) return error.DataLengthMismatch;
        var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
        errdefer atomic.deinit(io);
        const row = try allocator.alloc(f64, varnames.len);
        errdefer allocator.free(row);
        const buffer = try allocator.alloc(u8, 4096);
        errdefer allocator.free(buffer);
        var writer = atomic.file.writer(io, buffer);
        const count_offset = try writeHeader(&writer, .{
            .title = title,
            .plotname = "Transient Analysis",
            .varnames = varnames,
            .is_complex = false,
            .npoints = 0,
            .data = &.{},
        }, true, true);
        return .{ .atomic = atomic, .writer = writer, .row = row, .count_offset = count_offset, .allocator = allocator };
    }

    pub fn record(self: *Stream, t: f64, x: []const f64, probes: []const u32) !void {
        if (!self.atomic.file_open) return error.StreamClosed;
        if (probes.len != self.row.len - 1) return error.DataLengthMismatch;
        self.row[0] = t;
        for (probes, self.row[1..]) |node, *value| value.* = x[node];
        try self.writer.interface.writeAll(std.mem.sliceAsBytes(self.row));
        self.npoints += 1;
    }

    pub fn finish(self: *Stream) !void {
        if (!self.atomic.file_open) return error.StreamClosed;
        try self.writer.interface.flush();
        var count: [20]u8 = undefined;
        const text = try std.fmt.bufPrint(&count, "{d:>20}", .{self.npoints});
        try self.atomic.file.writePositionalAll(self.writer.io, text, self.count_offset);
        try self.atomic.replace(self.writer.io);
    }

    pub fn deinit(self: *Stream) void {
        self.atomic.deinit(self.writer.io);
        self.allocator.free(self.writer.interface.buffer);
        self.allocator.free(self.row);
        self.* = undefined;
    }
};

fn writeInner(io: Io, path: []const u8, plot: Plot, append: bool) !void {
    const nvars = plot.varnames.len;
    const per: usize = if (plot.is_complex) 2 else 1;
    const expected_len = plot.npoints * nvars * per;
    if (plot.data.len != expected_len) return error.DataLengthMismatch;

    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = !append });
    defer file.close(io);
    const start_pos: u64 = if (append) try file.length(io) else 0;

    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    fw.pos = start_pos; // append lands after the previous plot
    const w = &fw.interface;
    _ = try writeHeader(&fw, plot, false, true);

    // Write f64 values as raw bytes in native endian (ngspice uses host endian).
    try w.flush();
    try w.writeAll(std.mem.sliceAsBytes(plot.data));
    try w.flush();
}

pub inline fn writeHeader(fw: *Io.File.Writer, plot: Plot, comptime padded_count: bool, comptime binary: bool) !u64 {
    const w = &fw.interface;
    try w.print("Title: {s}\n", .{plot.title});
    try w.writeAll("Date: Thu Jan  1 00:00:00 1970\n");
    try w.print("Plotname: {s}\n", .{plot.plotname});
    if (plot.is_complex) {
        try w.writeAll("Flags: complex\n");
    } else {
        try w.writeAll("Flags: real\n");
    }
    try w.print("No. Variables: {d}\nNo. Points: ", .{plot.varnames.len});
    const count_offset = if (padded_count) fw.logicalPos() else 0;
    if (padded_count) {
        try w.print("{d:>20}\n", .{plot.npoints});
    } else {
        try w.print("{d}\n", .{plot.npoints});
    }
    try w.writeAll("Variables:\n");
    for (plot.varnames, 0..) |name, i| {
        try w.print("\t{d}\t{s}\t{s}\n", .{ i, name, varType(name) });
    }
    try w.writeAll(if (binary) "Binary:\n" else "Values:\n");
    return count_offset;
}

// =============================================================================
// Tests
// =============================================================================

test "stream eligibility preserves special files, symlinks and hard links" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/wave.raw", .{tmp.sub_path});
    defer a.free(path);
    try std.testing.expect(try canStream(io, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "wave.raw", .data = "existing" });
    try std.testing.expect(try canStream(io, path));

    try tmp.dir.symLink(io, "wave.raw", "link.raw", .{});
    const linked = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/link.raw", .{tmp.sub_path});
    defer a.free(linked);
    try std.testing.expect(!try canStream(io, linked));
    try tmp.dir.hardLink("wave.raw", tmp.dir, "hard.raw", io, .{});
    try std.testing.expect(!try canStream(io, path));
    if (@import("builtin").os.tag == .linux)
        try std.testing.expect(!try canStream(io, "/dev/null"));

    const invalid = try std.fmt.allocPrint(a, "{s}/child", .{path});
    defer a.free(invalid);
    try std.testing.expectError(error.NotDir, canStream(io, invalid));
}

test "stream: noncontiguous probes preserve column order and final point count" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/wave.raw", .{tmp.sub_path});
    defer a.free(path);

    var stream = try Stream.init(io, a, path, "stream test", &.{ "time", "v(c)", "i(a)" });
    defer stream.deinit();
    try stream.record(0, &.{ 0, 11, 22, 33 }, &.{ 3, 1 });
    try stream.record(1, &.{ 0, 44, 55, 66 }, &.{ 3, 1 });
    try stream.finish();

    const blob = try tmp.dir.readFileAlloc(io, "wave.raw", a, .unlimited);
    defer a.free(blob);
    const marker = "Binary:\n";
    const payload = (std.mem.indexOf(u8, blob, marker) orelse return error.MarkerNotFound) + marker.len;
    try std.testing.expect(std.mem.indexOf(u8, blob[0..payload], "No. Points:                    2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, blob[0..payload], "\t2\ti(a)\tcurrent\n") != null);
    const expected = [_]f64{ 0, 33, 11, 1, 66, 44 };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), blob[payload..]);
}

test "stream: abort and write failure preserve target and remove temporary files" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/wave.raw", .{tmp.sub_path});
    defer a.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "wave.raw", .data = "previous result" });

    for ([_]bool{ false, true }) |fail_write| {
        {
            var stream = try Stream.init(io, a, path, "aborted", &.{ "time", "v(out)" });
            defer stream.deinit();
            try stream.record(0, &.{1}, &.{0});
            if (fail_write) {
                const padding = [_]u8{0} ** 4096;
                try stream.writer.interface.writeAll(padding[0 .. 4096 - stream.writer.interface.end]);
                stream.writer.interface.vtable = &.{ .drain = struct {
                    fn fail(_: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
                        return error.WriteFailed;
                    }
                }.fail };
                try std.testing.expectError(error.WriteFailed, stream.record(1, &.{2}, &.{0}));
                try std.testing.expectEqual(@as(usize, 1), stream.npoints);
                try std.testing.expectError(error.WriteFailed, stream.finish());
            }
        }
        const blob = try tmp.dir.readFileAlloc(io, "wave.raw", a, .unlimited);
        defer a.free(blob);
        try std.testing.expectEqualStrings("previous result", blob);
        var entries = tmp.dir.iterate();
        const entry = (try entries.next(io)) orelse return error.MissingTarget;
        try std.testing.expectEqualStrings("wave.raw", entry.name);
        try std.testing.expect((try entries.next(io)) == null);
    }
}

test "write and read back real .op raw file" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const varnames = [_][]const u8{ "v(out)", "v(in)", "i(v1)#branch" };
    const data = [_]f64{ 1.5, 3.3, -0.001 }; // 1 point, 3 vars

    const plot: Plot = .{
        .title = "test op",
        .plotname = "Operating Point",
        .varnames = &varnames,
        .is_complex = false,
        .npoints = 1,
        .data = &data,
    };

    const path = "zig-out/test_op.raw";

    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};

    try write(io, path, plot);
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
        .plotname = "Transient Analysis",
        .varnames = &varnames,
        .is_complex = false,
        .npoints = 3,
        .data = &data,
    };

    const path = "zig-out/test_tran.raw";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};

    try write(io, path, plot);
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
        .plotname = "AC Analysis",
        .varnames = &varnames,
        .is_complex = true,
        .npoints = 2,
        .data = &data,
    };

    const path = "zig-out/test_ac.raw";
    Io.Dir.cwd().createDirPath(io, "zig-out") catch {};

    try write(io, path, plot);
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
        .plotname = "bad",
        .varnames = &varnames,
        .is_complex = false,
        .npoints = 2,
        .data = &data,
    };

    const result = write(io, "zig-out/should_not_exist.raw", plot);
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
