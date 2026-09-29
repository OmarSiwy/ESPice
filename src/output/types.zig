//! Shared output data and the checks that decide whether a format can hold a
//! result. Writers and producers import this leaf, never root.zig.
const std = @import("std");
const core = @import("core");

pub const Format = enum(u8) { binary, ascii, csv, touchstone, psf, fsdb, sst2, citi, print };

/// Where and how a session writes its plots. Fixed for the session's life.
pub const Selection = struct {
    format: Format = .binary,
    /// Null keeps results in memory and writes no file.
    path: ?[]const u8 = null,
};

pub const Schema = core.Schema;
pub const Result = core.Result;

/// A result as one file shows it: the deck title over the analysis payload.
pub const Plot = struct {
    title: []const u8,
    result: Result,

    pub fn schema(self: Plot) Schema {
        return .{ .varnames = self.result.varnames, .is_complex = self.result.is_complex, .npoints = self.result.npoints };
    }

    /// Returns the samples of point `pt`: one f64 per variable, or a
    /// (real, imaginary) pair per variable when complex.
    pub fn point(self: Plot, pt: usize) []const f64 {
        const stride = self.result.varnames.len * @as(usize, if (self.result.is_complex) 2 else 1);
        return self.result.data[pt * stride ..][0..stride];
    }
};

pub const ValidationError = error{ DataLengthMismatch, NotSParameterData, FormatLimitExceeded };

fn sampleCount(schema: Schema, npoints: usize) ValidationError!usize {
    const count = std.math.mul(usize, npoints, schema.varnames.len) catch return error.DataLengthMismatch;
    return std.math.mul(usize, count, if (schema.is_complex) 2 else 1) catch error.DataLengthMismatch;
}

/// Returns the one-based port pair of an `S(m,n)` or ngspice `v(S_m_n)`
/// label, or null if `name` is neither.
pub fn sParameter(name: []const u8) ?[2]u32 {
    if (!std.mem.endsWith(u8, name, ")")) return null;
    const ngspice = std.mem.startsWith(u8, name, "v(S_");
    if (!ngspice and !std.mem.startsWith(u8, name, "S(")) return null;
    const inner = name[(if (ngspice) @as(usize, 4) else 2) .. name.len - 1];
    const separator = std.mem.indexOfScalar(u8, inner, if (ngspice) '_' else ',') orelse return null;
    for (inner, 0..) |char, i| if (i != separator and !std.ascii.isDigit(char)) return null;
    const m = std.fmt.parseInt(u32, inner[0..separator], 10) catch return null;
    const n = std.fmt.parseInt(u32, inner[separator + 1 ..], 10) catch return null;
    if (m == 0 or n == 0) return null;
    return .{ m, n };
}

/// Returns the port count of a complete S matrix: complex data, `frequency`
/// first, then every `S(m,n)` in row-major order. Touchstone needs this
/// layout; columns after the S block (`.lin`'s) are allowed.
pub fn portCount(schema: Schema) ValidationError!u32 {
    if (!schema.is_complex or schema.varnames.len < 2 or
        !std.mem.eql(u8, schema.varnames[0], "frequency")) return error.NotSParameterData;
    var end: usize = 1;
    while (end < schema.varnames.len and sParameter(schema.varnames[end]) != null) end += 1;
    const last = sParameter(schema.varnames[end - 1]) orelse return error.NotSParameterData;
    const n: usize = last[0];
    if (last[1] != n) return error.NotSParameterData;
    const count = std.math.mul(usize, n, n) catch return error.NotSParameterData;
    if (count != end - 1) return error.NotSParameterData;
    for (schema.varnames[1..end], 0..) |name, i| {
        const pair = sParameter(name) orelse return error.NotSParameterData;
        if (pair[0] != i / n + 1 or pair[1] != i % n + 1) return error.NotSParameterData;
    }
    return last[0];
}

/// Checks that `format` can hold a result of this shape. Pure, so
/// construction can reject a bad selection before any I/O.
pub fn validateSchema(format: Format, schema: Schema) ValidationError!void {
    if (schema.varnames.len == 0) return error.DataLengthMismatch;
    if (schema.npoints) |n| _ = try sampleCount(schema, n);
    switch (format) {
        .touchstone => _ = try portCount(schema),
        .citi => {
            if (!schema.is_complex or !std.mem.eql(u8, schema.varnames[0], "frequency"))
                return error.NotSParameterData;
            var found = false;
            for (schema.varnames[1..]) |name| {
                if (!std.mem.startsWith(u8, name, "S(") and !std.mem.startsWith(u8, name, "v(S_")) continue;
                _ = sParameter(name) orelse return error.NotSParameterData;
                found = true;
            }
            if (!found) return error.NotSParameterData;
        },
        .fsdb => {
            if (schema.varnames.len > std.math.maxInt(u32)) return error.FormatLimitExceeded;
            if (schema.npoints) |n| if (n > std.math.maxInt(u32)) return error.FormatLimitExceeded;
            for (schema.varnames) |name| if (name.len > std.math.maxInt(u16)) return error.FormatLimitExceeded;
        },
        // sst2.zig has 64 fixed name slots.
        .sst2 => if (schema.varnames.len > 64) return error.FormatLimitExceeded,
        else => {},
    }
}

/// `validateSchema`, plus the data length and the fsdb string limits.
/// Every encoder assumes a plot that passed this.
pub fn validatePlot(format: Format, plot: Plot) ValidationError!void {
    try validateSchema(format, plot.schema());
    if (plot.result.data.len != try sampleCount(plot.schema(), plot.result.npoints)) return error.DataLengthMismatch;
    if (format == .fsdb and (plot.title.len > std.math.maxInt(u16) or plot.result.plotname.len > std.math.maxInt(u16)))
        return error.FormatLimitExceeded;
}

/// Refuses, before it runs, a query whose result `format` cannot encode
/// under the deck's `title` and `probe_labels`.
/// `NoPorts`: a Touchstone or CITI request for an `.sp` with no ports.
pub fn validateQuery(format: Format, query: core.QuerySchema, title: []const u8, probe_labels: []const []const u8) error{ NotSParameterData, NoPorts, DataLengthMismatch, FormatLimitExceeded }!void {
    if (format == .touchstone or format == .citi) {
        if (query.kind != .sp) return error.NotSParameterData;
        if (query.portless) return error.NoPorts;
    }
    if (format != .sst2 and format != .fsdb) return;
    if (query.columns == 0) return error.DataLengthMismatch;
    if (format == .sst2 and query.columns > 64) return error.FormatLimitExceeded;
    if (format == .fsdb) {
        if (query.columns > std.math.maxInt(u32) or title.len > std.math.maxInt(u16)) return error.FormatLimitExceeded;
        for (probe_labels) |label| if (label.len > std.math.maxInt(u16)) return error.FormatLimitExceeded;
    }
}

test "output schemas validate unknown sizes, checked dimensions and S-parameter layout" {
    const t = std.testing;
    const real: Schema = .{ .varnames = &.{ "time", "v(out)" }, .is_complex = false };
    try validateSchema(.csv, real);
    try t.expectError(error.NotSParameterData, validateSchema(.touchstone, real));
    try t.expectError(error.NotSParameterData, validateSchema(.citi, real));
    var huge = real;
    huge.npoints = std.math.maxInt(usize);
    try t.expectError(error.DataLengthMismatch, validateSchema(.binary, huge));

    const partial: Schema = .{ .varnames = &.{ "frequency", "S(2,2)" }, .is_complex = true };
    try validateSchema(.citi, partial);
    try t.expectError(error.NotSParameterData, validateSchema(.touchstone, partial));
    const complete: Schema = .{
        .varnames = &.{ "frequency", "S(1,1)", "S(1,2)", "S(2,1)", "S(2,2)" },
        .is_complex = true,
    };
    try t.expectEqual(@as(u32, 2), try portCount(complete));
    try validateSchema(.touchstone, complete);

    const too_many_names: [65][]const u8 = @splat("v(out)");
    try t.expectError(error.FormatLimitExceeded, validateSchema(.sst2, .{
        .varnames = &too_many_names,
        .is_complex = false,
    }));
    const mislabeled: Schema = .{ .varnames = &.{ "time", "S(1,1)" }, .is_complex = true };
    try t.expectError(error.NotSParameterData, validateSchema(.citi, mislabeled));
}

test "S-parameter labels accept both producers and reject malformed port identities" {
    try std.testing.expectEqual([2]u32{ 12, 3 }, sParameter("S(12,3)").?);
    try std.testing.expectEqual([2]u32{ 12, 3 }, sParameter("v(S_12_3)").?);
    for ([_][]const u8{ "S()", "S(0,1)", "S(1,)", "S(1,2,3)", "v(S_)", "v(S_1_0)", "v(S_1_2_3)", "v(S_+1_2)", "v(S_4294967296_1)" }) |name| {
        try std.testing.expect(sParameter(name) == null);
        try std.testing.expectError(error.NotSParameterData, validateSchema(.citi, .{
            .varnames = &.{ "frequency", "S(1,1)", name },
            .is_complex = true,
        }));
    }
}
