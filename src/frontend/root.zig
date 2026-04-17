//! Frontend: source preparation and model-to-circuit construction.
const preparation = @import("prepare.zig");
pub const Source = preparation.Source;
pub const Dialect = preparation.Dialect;
pub const prepare = preparation.prepare;
pub const parseDialect = preparation.parseDialect;
pub const build = preparation.build;
pub const resolveQueries = preparation.resolveQueries;
pub const Library = @import("device").Library;

test {
    _ = @import("tests/builder.zig");
    _ = @import("tests/prepared.zig");
    _ = @import("tests/models.zig");
}
