//! Frontend: source preparation and model-to-circuit construction.
const preparation = @import("prepare.zig");
pub const Source = preparation.Source;
pub const Dialect = preparation.Dialect;
pub const PreparedInput = preparation.PreparedInput;
pub const prepare = preparation.prepare;
pub const parseDialect = preparation.parseDialect;
pub const Prepared = @import("problem_types").Prepared;
pub const build = preparation.build;
pub const resolveQueries = preparation.resolveQueries;

test {
    _ = @import("tests/syntax.zig");
    _ = @import("tests/builder.zig");
    _ = @import("tests/prepared.zig");
    _ = @import("tests/models.zig");
}
