//! The one file write every format goes through: validate, encode, and
//! replace the destination atomically, so it holds the old bytes or the whole
//! new plot, never a torn one.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

/// Replace `path` with `plot` encoded as `format`.
pub fn write(io: Io, path: []const u8, format: types.Format, plot: types.Plot) !void {
    return put(io, path, format, plot, false);
}

/// Binary raw only: ngspice appends every plot of a deck to ONE raw file and
/// readers take the concatenation. The existing plots are copied into the
/// replacement first, so the append is atomic too.
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
