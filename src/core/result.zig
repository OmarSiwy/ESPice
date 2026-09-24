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
