//! What an analysis publishes: the shape known up front and the finished payload.
//! Plain data; cites nothing beyond ESPice's own analysis/output contract.
const Kind = @import("query.zig").Kind;

/// What a query will publish, known before it runs: enough for an output
/// format to refuse it up front (`analysis.schemaOf`, `output.validateQuery`).
pub const QuerySchema = struct {
    kind: Kind,
    /// Variables (columns) of the published result.
    columns: usize,
    /// An `.sp` with no ports of its own and no deck source to drive it.
    portless: bool,
    /// Plot name and scale column of a sweep whose rows can stream before
    /// the run ends (a transient or AC sweep); empty for every other query.
    plotname: []const u8 = "",
    scale: []const u8 = "",
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
    /// variable takes two adjacent f64s (real, imaginary). Empty for a
    /// transient or AC sweep whose rows streamed straight to the output (a final plan
    /// that nothing reads after it, see `analysis.session.Session.stream`).
    data: []const f64,
    /// Per `.meas` card of the deck, what it found while the run went
    /// (measurement-only mode, `output/measure.zig` `Stream`), in place of
    /// the columns it reads, which are not in `data`; empty, or a card's
    /// `scans == 0`, where a card reads `data`.
    measured: []const Measured = &.{},
    /// A transient's tangent rows (`Tran.tangents`): one more block of
    /// `data`'s shape per row, on the same times, each the first-order
    /// prediction of the run at that row. Empty without them.
    tangents: []const f64 = &.{},
};

/// A `.meas` card measured as its run went: each of its passes over the
/// waveform (an event, a value at a time, a window), in the order the
/// evaluator reads them.
pub const Measured = struct {
    scans: u8 = 0,
    found: [2]Found = undefined,

    /// A pass's numbers: the value, then where (`at=`, `from=`, `to=`), or
    /// `missing` when it names a vector the run lacks.
    pub const Found = struct { missing: bool = false, v: [3]f64 };
};
