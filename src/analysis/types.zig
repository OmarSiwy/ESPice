//! Shared analysis context: what every analysis leaf needs, and nothing the
//! leaves feed back into. Leaves import THIS file (usually as `root`), never
//! ../root.zig — root.zig imports the leaves for dispatch, and importing it
//! back would close the cycle this file exists to break.
//!
//! File-level DAG inside src/analysis/:
//!   tran/types.zig -> Circuit.zig -> types.zig -> contract.zig / leaves -> root.zig
const std = @import("std");

const circuit_mod = @import("Circuit.zig");

// -- Crate imports --
pub const solvers = @import("solvers");
pub const devices = @import("devices");
pub const converger = solvers.converger;
pub const types = solvers.types;
pub const freq = types;

// -- Re-exports from Circuit.zig --
pub const Circuit = circuit_mod.Circuit;
pub const EvalHook = circuit_mod.EvalHook;
pub const GpuHook = circuit_mod.GpuHook;
pub const BbdBlock = circuit_mod.BbdBlock;
pub const BbdInfo = circuit_mod.BbdInfo;
pub const GROUND = circuit_mod.GROUND;
pub const zeroSimd = circuit_mod.zeroSimd;
pub const copySimd = circuit_mod.copySimd;
pub const freeFreqLanes = circuit_mod.freeFreqLanes;
pub fn probeNames(ctx: *const RunCtx, first: ?[]const u8) ![]const []const u8 {
    return circuit_mod.probeNames(ctx.circuit, ctx.probes, ctx.allocator, first);
}

// -- Re-exports for analysis modules + src/ consumers --
pub const ParamRef = devices.batch.ParamRef;
pub const NoiseSource = devices.batch.NoiseSource;
pub const NoiseGenKind = devices.batch.NoiseGenKind;
pub const NoiseGen = devices.batch.NoiseGen;
/// Builder freeze: protos -> analysis.Circuit (union pattern + planes + tapes).
pub const freeze = circuit_mod.init;

// ---------------------------------------------------------------------------
// Run context — everything an analysis needs, resolved before dispatch
// ---------------------------------------------------------------------------

pub const RunCtx = struct {
    circuit: *Circuit,
    x_op: ?[]f64,
    probes: []const u32,
    source_node: u32,
    source_branch: u32,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Uniform result — every analysis produces this
// ---------------------------------------------------------------------------

pub const Result = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    data: []const f64,
};
