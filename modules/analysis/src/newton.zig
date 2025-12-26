//! Backward-compatibility shim: re-exports from converger.zig.
//!
//! All callers (dc, tran, envelope, pss, pnoise, tran_noise, op) import
//! "newton.zig" and get the same API. The newton.solve() signature is
//! unchanged — it delegates to converger.newton(), the direct strategy.

const converger = @import("converger.zig");

pub const Options = converger.Options;
pub const Result = converger.Result;
pub const EvalHook = converger.EvalHook;
pub const Workspace = converger.Workspace;
pub const Strategy = converger.Strategy;
pub const pickStrategy = converger.pickStrategy;

/// The original newton.solve() — delegates to converger.newton() (direct).
/// Signature unchanged: all existing callers work without modification.
pub const solve = converger.newton;

/// JFNK entry point for callers that want the Krylov path.
pub const jfnk = converger.jfnk;

/// Unified entry point with strategy selection.
pub const solveWithStrategy = converger.solve;
