//! The one file write every format goes through: validate, encode, and
//! replace the destination atomically, so it holds the old bytes or the
//! whole new plot, never a torn one.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

/// Replaces `path` with `plot` encoded as `format`. Validation errors leave
/// the destination untouched.
pub fn write(io: Io, path: []const u8, format: types.Format, plot: types.Plot) !void {
    return put(io, path, format, plot, false);
}

/// Appends `plot` to the file at `path`, creating it if missing. Only for
/// formats that `concatenates`. The old plots are copied into the
/// replacement, so the append is atomic too, at O(file size) per call.
/// Asserts that `format` concatenates.
pub fn append(io: Io, path: []const u8, format: types.Format, plot: types.Plot) !void {
    std.debug.assert(concatenates(format));
    return put(io, path, format, plot, true);
}

/// Whether one file holds several plots back to back. ngspice writes every
/// plot of a deck into one raw file, binary or ASCII, and readers take the
/// concatenation; a `.print` listing is a sequence of tables. The other
/// formats hold one dataset per file.
pub fn concatenates(format: types.Format) bool {
    return switch (format) {
        .binary, .ascii, .print => true,
        else => false,
    };
}

fn put(io: Io, path: []const u8, format: types.Format, plot: types.Plot, keep: bool) !void {
    try types.validatePlot(format, plot);
    var buf: [8192]u8 = undefined;
    // A device or FIFO (`-r /dev/null`) cannot be renamed over: write to it
    // directly. Appending to one is writing the new plot.
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch null;
    if (stat != null and stat.?.kind != .file) {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .write_only });
        defer file.close(io);
        var fw = file.writer(io, &buf);
        try encode(&fw.interface, format, plot);
        return fw.interface.flush();
    }
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    var fw = atomic.file.writer(io, &buf);
    const w = &fw.interface;
    if (keep) copy: {
        const old = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :copy,
            else => return err,
        };
        defer old.close(io);
        var rbuf: [8192]u8 = undefined;
        var reader = old.reader(io, &rbuf);
        _ = try reader.interface.streamRemaining(w);
    }
    try encode(w, format, plot);
    try w.flush();
    try atomic.replace(io);
}

fn encode(w: *Io.Writer, format: types.Format, plot: types.Plot) !void {
    return switch (format) {
        .binary => @import("rawfile.zig").encode(w, plot),
        .ascii => @import("ascii_raw.zig").encode(w, plot),
        .csv => @import("csv.zig").encode(w, plot),
        .touchstone => @import("touchstone.zig").encode(w, plot),
        .psf => @import("psf.zig").encode(w, plot),
        .fsdb => @import("fsdb.zig").encode(w, plot),
        .sst2 => @import("sst2.zig").encode(w, plot),
        .citi => @import("citifile.zig").encode(w, plot),
        .print => @import("spice_print.zig").encode(w, plot),
    };
}

test "a character device is written in place, not renamed over" {
    const plot: types.Plot = .{ .title = "t", .result = .{
        .plotname = "p",
        .varnames = &.{"v(a)"},
        .is_complex = false,
        .npoints = 1,
        .data = &.{1.0},
    } };
    try write(std.testing.io, "/dev/null", .binary, plot);
    try append(std.testing.io, "/dev/null", .binary, plot);
}

test "every format refuses a plot whose data length disagrees with its shape" {
    const plot: types.Plot = .{ .title = "bad", .result = .{
        .plotname = "bad",
        .varnames = &.{ "v(a)", "v(b)" },
        .is_complex = false,
        .npoints = 2,
        .data = &.{ 1.0, 2.0, 3.0 },
    } };
    inline for (@typeInfo(types.Format).@"enum".field_values) |value| {
        const format: types.Format = @fromBackingInt(@intCast(value));
        const expected = if (format == .touchstone or format == .citi) error.NotSParameterData else error.DataLengthMismatch;
        try std.testing.expectError(expected, write(std.testing.io, "zig-out/should_not_exist", format, plot));
    }
}

test "write replaces and append extends, both atomically" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out.txt", .{tmp.sub_path});
    defer a.free(path);
    const plot: types.Plot = .{ .title = "t", .result = .{ .plotname = "p", .varnames = &.{"v(a)"}, .is_complex = false, .npoints = 1, .data = &.{1.0} } };
    var one: Io.Writer.Allocating = .init(a);
    defer one.deinit();
    try encode(&one.writer, .print, plot);
    try tmp.dir.writeFile(io, .{ .sub_path = "out.txt", .data = "old" });
    try write(io, path, .print, plot);
    try append(io, path, .print, plot);
    const got = try tmp.dir.readFileAlloc(io, "out.txt", a, .unlimited);
    defer a.free(got);
    const twice = try std.mem.concat(a, u8, &.{ one.written(), one.written() });
    defer a.free(twice);
    try std.testing.expectEqualStrings(twice, got);
}
