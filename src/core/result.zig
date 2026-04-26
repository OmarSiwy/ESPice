//! What an analysis publishes: the shape known up front and the finished payload.
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

/// The column layout of a result, available before any samples exist.
pub const Schema = struct {
    varnames: []const []const u8,
    is_complex: bool,
    /// Null when the analysis is adaptive and the point count is unknown.
    npoints: ?usize = null,
};

/// A completed analysis payload, valid until the owning Problem is destroyed.
pub const Result = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    /// Point-major samples, `npoints * varnames.len` of them; a complex
    /// variable takes two adjacent f64s (real, imaginary).
    data: []const f64,
};
