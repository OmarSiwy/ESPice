//! Waveform writers. Every format is an `encode(w, plot)` onto a
//! `std.Io.Writer`; write.zig validates, encodes and atomically replaces the
//! file, and `Session` publishes whole plots in order. Aggregation only:
//! leaves import types.zig, never this file.
const std = @import("std");
const types = @import("types.zig");

pub const Session = @import("session.zig").Session;
pub const Selection = types.Selection;
pub const Format = types.Format;
pub const Result = types.Result;
pub const Plot = types.Plot;
pub const validateQuery = types.validateQuery;
/// Validates, encodes and atomically replaces one file with one plot.
pub const write = @import("write.zig").write;
/// `.meas` results in ngspice's print format.
pub const printMeasures = @import("measure.zig").print;
/// `.meas` statistics over Monte Carlo trials.
pub const printMeasureStatistics = @import("measure.zig").printStatistics;
/// Every `.meas` card's value over one result; see `measure.evaluateAll`.
pub const measureValues = @import("measure.zig").evaluateAll;
/// A measure clause's transient waveform at given times (HSPICE `.stim`).
pub const sampleMeasure = @import("measure.zig").sample;

/// Resolves a user-facing format name or alias to a `Format`. Returns null
/// for an unknown name so the caller owns the diagnostic.
pub fn parseFormat(s: []const u8) ?Format {
    return std.StaticStringMap(Format).initComptime(.{
        .{ "binary", .binary },         .{ "raw", .binary },
        .{ "ascii", .ascii },           .{ "csv", .csv },
        .{ "touchstone", .touchstone }, .{ "snp", .touchstone },
        .{ "s2p", .touchstone },        .{ "psf", .psf },
        .{ "fsdb", .fsdb },             .{ "sst2", .sst2 },
        .{ "hspice", .sst2 },           .{ "citi", .citi },
        .{ "citifile", .citi },         .{ "print", .print },
        .{ "text", .print },
    }).get(s);
}

test "every Format arm is reachable by its own name" {
    inline for (@typeInfo(Format).@"enum".fields) |f| {
        try std.testing.expectEqual(@as(?Format, @enumFromInt(f.value)), parseFormat(f.name));
    }
}

test {
    _ = types;
    _ = @import("write.zig");
    _ = @import("session.zig");
    _ = @import("rawfile.zig");
    _ = @import("ascii_raw.zig");
    _ = @import("csv.zig");
    _ = @import("spice_print.zig");
    _ = @import("touchstone.zig");
    _ = @import("citifile.zig");
    _ = @import("psf.zig");
    _ = @import("sst2.zig");
    _ = @import("fsdb.zig");
    _ = @import("measure.zig");
}
