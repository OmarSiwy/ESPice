//! Netlist front end — the top of the `frontend` file DAG.
//!
//! Aggregation, re-export and dispatch only, per AGENTS.md: the leaves below
//! import `types.zig` and `tokenizer.zig` directly and never import this file.
//!
//! The parse pipeline is three separable stages, and they are exposed as three
//! calls rather than one `parseFile(path)`, so a caller owns the bytes and the
//! arena:
//!
//! 1. `source.load` — read a deck into an arena (skip it and supply your own
//!    bytes; nothing downstream knows where they came from).
//! 2. `Parser(Tok)` — a tokenizer dialect applied to those bytes.
//! 3. `types.Netlist` — the result, a plain data type callers may build by hand.
//!
//! `Tok` is a comptime dialect rather than a runtime flag so the tokenizer's
//! character tables inline into the scan loop.

pub const types = @import("types.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const source = @import("source.zig");
pub const parser = @import("parser.zig");

/// Netlist parser over a tokenizer dialect. Instantiate with `ngspice`,
/// `hspice` or `spectre`.
pub const Parser = parser.Parser;

/// Errors the parser raises; `ParseError` carries its diagnostic out of band.
pub const Error = parser.Error;

/// Read a deck into `arena`. Separable: the parser takes bytes, not a path.
pub const load = source.load;

pub const ngspice = tokenizer.ngspice;
pub const hspice = tokenizer.hspice;
pub const spectre = tokenizer.spectre;

/// Build a tokenizer dialect from a character-class configuration.
pub const GenTokens = tokenizer.GenTokens;

/// The parsed deck and the tables hung off it.
pub const Netlist = types.Netlist;

test {
    _ = types;
    _ = tokenizer;
    _ = source;
    _ = parser;
    _ = @import("parameter_tests.zig");
}
