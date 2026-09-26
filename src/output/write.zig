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

/// Appends `plot` to the binary raw file at `path`, creating it if missing.
/// ngspice writes every plot of a deck into one raw file and readers take
/// the concatenation. The old plots are copied into the replacement, so the
/// append is atomic too.
pub fn append(io: Io, path: []const u8, plot: types.Plot) !void {
    return put(io, path, .binary, plot, true);
}

fn put(io: Io, path: []const u8, format: types.Format, plot: types.Plot, keep: bool) !void {
    try types.validatePlot(format, plot);
    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    var buf: [8192]u8 = undefined;
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
    try switch (format) {
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
    try w.flush();
    try atomic.replace(io);
}

test "every format refuses a plot whose data length disagrees with its shape" {
    const plot: types.Plot = .{ .title = "bad", .result = .{
        .plotname = "bad",
        .varnames = &.{ "v(a)", "v(b)" },
        .is_complex = false,
        .npoints = 2,
        .data = &.{ 1.0, 2.0, 3.0 },
    } };
    inline for (@typeInfo(types.Format).@"enum".fields) |f| {
        const format: types.Format = @enumFromInt(f.value);
        const expected = if (format == .touchstone or format == .citi) error.NotSParameterData else error.DataLengthMismatch;
        try std.testing.expectError(expected, write(std.testing.io, "zig-out/should_not_exist", format, plot));
    }
}
