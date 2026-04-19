//! Waveform writers — the top of the `output` file DAG.
//!
//! Aggregation and re-export only, per AGENTS.md: the leaves below import
//! types.zig for shared data and never import this file.
//!
//! Every format is an encoder, `encode(w, plot)` onto any `std.Io.Writer`;
//! `write(io, path, format, plot)` is the one file write (validate, encode,
//! atomic replace). `Session` adds ordered, idempotent whole-plot publication
//! with a fixed output selection.

const std = @import("std");

pub const types = @import("types.zig");
pub const Session = @import("session.zig").Session;
pub const Schema = types.Schema;
pub const Selection = types.Selection;
pub const validateSchema = types.validateSchema;
pub const validatePlot = types.validatePlot;
pub const validateQuery = types.validateQuery;
pub const ValidationError = types.ValidationError;

pub const rawfile = @import("rawfile.zig");
pub const ascii_raw = @import("ascii_raw.zig");
pub const csv = @import("csv.zig");
pub const spice_print = @import("spice_print.zig");
pub const touchstone = @import("touchstone.zig");
pub const citifile = @import("citifile.zig");
pub const psf = @import("psf.zig");
pub const sst2 = @import("sst2.zig");
pub const fsdb = @import("fsdb.zig");

/// The one waveform payload every writer accepts.
pub const Result = types.Result;
pub const Plot = types.Plot;

/// Output encodings `write` can dispatch to.
pub const Format = types.Format;

/// Resolve a user-facing format name, including its aliases, to a `Format`.
/// Returns null for an unknown name so the caller owns the diagnostic.
// ponytail: fixed CLI aliases use stdlib maps; writers dispatch on the resolved enum.
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

/// Validate, encode and atomically replace `path` with `plot` in `format`.
pub const write = @import("write.zig").write;

test "every Format arm maps to the writer that names it" {
    // The dispatch and the alias table are the two places a new format gets
    // forgotten; this fails if `Format` grows an arm no alias reaches.
    inline for (@typeInfo(Format).@"enum".fields) |f| {
        const named = parseFormat(f.name);
        // `binary` is reached by "binary", every other arm by its own spelling.
        try std.testing.expect(named != null);
        try std.testing.expectEqual(@as(Format, @enumFromInt(f.value)), named.?);
    }
}

test {
    _ = types;
    _ = @import("session.zig");
    _ = rawfile;
    _ = ascii_raw;
    _ = csv;
    _ = spice_print;
    _ = touchstone;
    _ = citifile;
    _ = psf;
    _ = sst2;
    _ = fsdb;
}
