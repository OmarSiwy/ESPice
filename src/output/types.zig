//! Shared output data. Writers and producers import this leaf, not root.zig.
const std = @import("std");

pub const Format = enum(u8) { binary, ascii, csv, touchstone, psf, fsdb, sst2, citi, print };

/// Fixed for one output session. Null path retains results without file output.
pub const Selection = struct {
    format: Format = .binary,
    path: ?[]const u8 = null,
};

/// Available before samples exist; adaptive analyses leave npoints unknown.
pub const Schema = struct {
    varnames: []const []const u8,
    is_complex: bool,
    npoints: ?usize = null,
};

/// A completed analysis payload, retained until the owning Problem is destroyed.
pub const Result = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    data: []const f64,
};

pub const Plot = struct {
    title: []const u8,
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    /// Point-major; complex variables occupy adjacent real/imaginary f64 values.
    /// Length is npoints * varnames.len * (if is_complex then 2 else 1).
    data: []const f64,

    pub fn schema(self: Plot) Schema {
        return .{ .varnames = self.varnames, .is_complex = self.is_complex, .npoints = self.npoints };
    }
};

pub const ValidationError = error{ DataLengthMismatch, NotSParameterData, FormatLimitExceeded };

fn sampleCount(schema: Schema, npoints: usize) ValidationError!usize {
    const count = std.math.mul(usize, npoints, schema.varnames.len) catch return error.DataLengthMismatch;
    return std.math.mul(usize, count, if (schema.is_complex) 2 else 1) catch error.DataLengthMismatch;
}

/// One-based port indices in an S(m,n) label or ngspice's v(S_m_n) label.
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

/// Touchstone writes a complete row-major matrix after the frequency column.
pub fn portCount(schema: Schema) ValidationError!u32 {
    if (!schema.is_complex or schema.varnames.len < 2 or
        !std.mem.eql(u8, schema.varnames[0], "frequency")) return error.NotSParameterData;
    const last = sParameter(schema.varnames[schema.varnames.len - 1]) orelse return error.NotSParameterData;
    const n: usize = last[0];
    if (last[1] != n) return error.NotSParameterData;
    const count = std.math.mul(usize, n, n) catch return error.NotSParameterData;
    if (count != schema.varnames.len - 1) return error.NotSParameterData;
    for (schema.varnames[1..], 0..) |name, i| {
        const pair = sParameter(name) orelse return error.NotSParameterData;
        if (pair[0] != i / n + 1 or pair[1] != i % n + 1) return error.NotSParameterData;
    }
    return last[0];
}

/// Pure validation: construction can reject incompatible output before any I/O.
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
        // The existing writer has 64 fixed-width name slots.
        .sst2 => if (schema.varnames.len > 64) return error.FormatLimitExceeded,
        else => {},
    }
}

pub fn validatePlot(format: Format, plot: Plot) ValidationError!void {
    try validateSchema(format, plot.schema());
    if (plot.data.len != try sampleCount(plot.schema(), plot.npoints)) return error.DataLengthMismatch;
    if (format == .fsdb and (plot.title.len > std.math.maxInt(u16) or plot.plotname.len > std.math.maxInt(u16)))
        return error.FormatLimitExceeded;
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
