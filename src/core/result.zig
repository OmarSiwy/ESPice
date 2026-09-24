const Kind = @import("query.zig").Kind;

/// What a query will publish, known before it runs: enough for an output
/// format to refuse it up front (`analysis.schemaOf`, `output.validateQuery`).
pub const QuerySchema = struct {
    kind: Kind,
    /// Variables (columns) of the published result.
    columns: usize,
    /// An `.sp` with no ports of its own and no deck source to drive it.
    portless: bool,
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
