//! Shared analysis context: what every analysis leaf needs, and nothing the
//! leaves feed back into. Leaves import THIS file (usually as `root`), never
//! ../root.zig — root.zig imports the leaves for dispatch, and importing it
//! back would close the cycle this file exists to break.
//!
//! File-level DAG inside src/analysis/:
//!   tran/types.zig -> Circuit.zig -> types.zig -> contract.zig / leaves -> root.zig
const std = @import("std");

const circuit_mod = @import("Circuit.zig");

const devices = @import("devices");

// -- Re-exports from Circuit.zig --
pub const Circuit = circuit_mod.Circuit;
pub const EvalHook = circuit_mod.EvalHook;
pub const GpuHook = circuit_mod.GpuHook;
pub const BbdBlock = circuit_mod.BbdBlock;
pub const BbdInfo = circuit_mod.BbdInfo;
pub const GROUND = circuit_mod.GROUND;
pub const zeroSimd = circuit_mod.zeroSimd;
pub const copySimd = circuit_mod.copySimd;
/// Column names for one Result: optional scale literal at [0], then one
/// allocated name per probe. Engine-built ctxs carry a label per probe
/// ("v(out)", "i(v1)"); hand-built ones (tests) may leave `probe_labels`
/// empty and get the v(<node>) fallback off the circuit's intern table.
pub fn probeNames(ctx: *const RunCtx, first: ?[]const u8) ![]const []const u8 {
    const a = ctx.allocator;
    const extra: usize = if (first == null) 0 else 1;
    const names = try a.alloc([]const u8, ctx.probes.len + extra);
    errdefer a.free(names);
    if (first) |name| names[0] = name;
    const labeled = ctx.probe_labels.len == ctx.probes.len;
    var done: usize = 0;
    errdefer for (names[extra..][0..done]) |s| a.free(s);
    for (ctx.probes, names[extra..], 0..) |row, *out, i| {
        out.* = if (labeled)
            try a.dupe(u8, ctx.probe_labels[i])
        else blk: {
            const label = ctx.circuit.nodeName(row);
            break :blk try std.fmt.allocPrint(a, "v({s})", .{if (label.len == 0) "?" else label});
        };
        done += 1;
    }
    return names;
}

/// One netlist card, keyed the way `ParamRef` identifies a device: by device
/// TYPE plus ordinal within that type. The netlist layer fills it (src/
/// builder.zig, at the one place instance ordinals are handed out); `.sens` is
/// the consumer, because ngspice names a sensitivity column after the CARD and
/// `resistor#0` resolves to nothing a raw-file reader can use.
pub const CardRef = struct {
    type_name: []const u8,
    index: u32,
    name: []const u8,

    /// ponytail: linear scan. Decks run tens of cards against tens of params;
    /// sort by (type_name.ptr, index) and binary-search if a 10k-device .sens
    /// ever shows up in a profile.
    pub fn lookup(cards: []const CardRef, ref: ParamRef) ?[]const u8 {
        for (cards) |c| {
            if (c.index == ref.index and std.mem.eql(u8, c.type_name, ref.device_type)) return c.name;
        }
        return null;
    }
};

// -- Re-exports for analysis modules + src/ consumers --
pub const ParamRef = devices.batch.ParamRef;
pub const AcParam = circuit_mod.AcParam;
pub const NoiseSource = devices.batch.NoiseSource;
pub const NoiseGenKind = devices.batch.NoiseGenKind;
pub const NoiseGen = devices.batch.NoiseGen;
pub const PsdTerm = devices.batch.PsdTerm;
/// Builder freeze: protos -> analysis.Circuit (union pattern + planes + tapes).
pub const freeze = circuit_mod.init;

// ---------------------------------------------------------------------------
// Run context — everything an analysis needs, resolved before dispatch
// ---------------------------------------------------------------------------

pub const RunCtx = struct {
    circuit: *Circuit,
    x_op: ?[]f64,
    probes: []const u32,
    /// Raw column label per probe, parallel to `probes` (see probeNames).
    probe_labels: []const []const u8 = &.{},
    source_node: u32,
    source_branch: u32,
    /// Composite AC excitation over the circuit unknowns, stacked real:
    /// `[re(0..n), im(0..n)]`, length `2 * circuit.n`. Every source card
    /// carrying an `AC mag [phase]` contributes to it (builder.zig
    /// `acExcitation`), so an .ac sweep is one solve per frequency against the
    /// whole deck's drive — the SPICE semantics, not a unit poke at one branch.
    /// Empty (hand-built contexts) reads as "no source named AC", which is a
    /// zero response — the same answer ngspice gives such a deck.
    ac_drive: []const f64 = &.{},
    allocator: std.mem.Allocator,
    /// Reclaimable work storage when allocator retains the final results in an arena.
    scratch_allocator: ?std.mem.Allocator = null,
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
