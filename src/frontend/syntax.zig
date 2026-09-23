//! Netlist syntax and builder preprocessing, independent of circuit/device code.
//! Parser(Tok).parse returns an AST. elaborate resolves it into builder scratch.
//! Leaves import each other and types.zig directly.

pub const types = @import("types.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const source = @import("source.zig");
pub const parser = @import("parser.zig");
pub const elaborate = @import("elaborate.zig").elaborate;
pub const Ast = types.Ast;

/// Netlist parser over a tokenizer dialect. Instantiate with `ngspice`,
/// `hspice` or `spectre`.
pub const Parser = parser.Parser;

/// Read a deck into `arena`. Separable: the parser takes bytes, not a path.
pub const load = source.load;

pub const ngspice = tokenizer.ngspice;
pub const hspice = tokenizer.hspice;
pub const spectre = tokenizer.spectre;

