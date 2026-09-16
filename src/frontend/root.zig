//! Frontend: source preparation and model-to-circuit construction.
const syntax = @import("syntax");
pub const types = syntax.types;
pub const Parser = syntax.Parser;
pub const load = syntax.load;
pub const ngspice = syntax.ngspice;
pub const hspice = syntax.hspice;
pub const spectre = syntax.spectre;
pub const Ast = syntax.Ast;
pub const Builder = @import("builder").Builder;
pub const models = @import("device_models");
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
