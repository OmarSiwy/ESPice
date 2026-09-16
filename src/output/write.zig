//! Whole-plot dispatch shared by the public root and output sessions.
const std = @import("std");
const types = @import("output_types");

pub fn write(io: std.Io, path: []const u8, format: types.Format, plot: types.Plot) !void {
    return switch (format) {
        .binary => @import("rawfile.zig").write(io, path, plot),
        .ascii => @import("ascii_raw.zig").write(io, path, plot),
        .csv => @import("csv.zig").write(io, path, plot),
        .touchstone => @import("touchstone.zig").write(io, path, plot),
        .psf => @import("psf.zig").write(io, path, plot),
        .fsdb => @import("fsdb.zig").write(io, path, plot),
        .sst2 => @import("sst2.zig").write(io, path, plot),
        .citi => @import("citifile.zig").write(io, path, plot),
        .print => @import("spice_print.zig").write(io, path, plot),
    };
}
