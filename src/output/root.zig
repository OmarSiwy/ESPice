//! Waveform writers — the top of the `output` file DAG.
//!
//! Aggregation, re-export and dispatch only, per AGENTS.md: the leaves below
//! import `rawfile.zig` for `Plot` and never import this file.
//!
//! Two tiers, so a caller never has to take the dispatch to reach a writer:
//!
//! - Orthogonal: every writer is re-exported under its own name and takes the
//!   same `write(io, path, plot)`. Call `csv.write` directly and nothing else
//!   in this module is initialized or consulted.
//! - Diagonal: `Format` plus `write(io, path, format, plot)` for the common
//!   case of "the user named a format on the command line".
//!
//! `Plot` is `rawfile.Plot` rather than a type of this module's own, because
//! the binary raw file is the format every other writer was defined against.

const std = @import("std");

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
pub const Plot = rawfile.Plot;

/// SPICE variable-class string (`voltage`, `current`, ...) for a signal name.
pub const varType = rawfile.varType;

/// Append a plot to an existing binary raw file.
pub const writeAppend = rawfile.writeAppend;

/// Whether `path` names a binary raw file that `Stream` may append to.
pub const canStream = rawfile.canStream;

/// Incremental binary-raw writer, for runs whose point count is not known up
/// front. Only the binary format streams; the rest are whole-plot writers.
pub const Stream = rawfile.Stream;

/// Output encodings `write` can dispatch to.
pub const Format = enum { binary, ascii, csv, touchstone, psf, fsdb, sst2, citi, print };

/// Resolve a user-facing format name, including its aliases, to a `Format`.
/// Returns null for an unknown name so the caller owns the diagnostic.
// ponytail: fixed CLI aliases use stdlib maps; writers dispatch on the resolved enum.
pub fn parseFormat(s: []const u8) ?Format {
    return std.StaticStringMap(Format).initComptime(.{
        .{ "binary", .binary },      .{ "raw", .binary },
        .{ "ascii", .ascii },        .{ "csv", .csv },
        .{ "touchstone", .touchstone }, .{ "snp", .touchstone }, .{ "s2p", .touchstone },
        .{ "psf", .psf },            .{ "fsdb", .fsdb },
        .{ "sst2", .sst2 },          .{ "hspice", .sst2 },
        .{ "citi", .citi },          .{ "citifile", .citi },
        .{ "print", .print },        .{ "text", .print },
    }).get(s);
}

/// Write `plot` to `path` in `format`. The diagonal route; each arm is the
/// corresponding writer's own `write`, reachable directly if a caller wants to
/// skip the dispatch.
pub fn write(io: std.Io, path: []const u8, format: Format, plot: Plot) !void {
    return switch (format) {
        .binary => rawfile.write(io, path, plot),
        .ascii => ascii_raw.write(io, path, plot),
        .csv => csv.write(io, path, plot),
        .touchstone => touchstone.write(io, path, plot),
        .psf => psf.write(io, path, plot),
        .fsdb => fsdb.write(io, path, plot),
        .sst2 => sst2.write(io, path, plot),
        .citi => citifile.write(io, path, plot),
        .print => spice_print.write(io, path, plot),
    };
}

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
