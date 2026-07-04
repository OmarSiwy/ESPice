//! Shared analysis context: the circuit, the run context and the result type
//! every analysis leaf needs. Leaves import this file, never ../root.zig,
//! which imports the leaves for dispatch. File DAG inside src/analysis/:
//! Circuit.zig -> types.zig -> leaves / executor.zig -> root.zig.
const std = @import("std");

const circuit_mod = @import("Circuit.zig");
const device_ir = @import("device").abi;

pub const Circuit = circuit_mod.Circuit;
pub const EvalHook = circuit_mod.EvalHook;
pub const GpuHook = circuit_mod.GpuHook;
pub const AcParam = circuit_mod.AcParam;
pub const GROUND = circuit_mod.GROUND;
pub const zeroSimd = circuit_mod.zeroSimd;
pub const copySimd = circuit_mod.copySimd;
/// Builds an owning Circuit from protos, for tests. See `Circuit.zig` `init`.
pub const freeze = circuit_mod.init;

pub const CardRef = @import("core").query.CardRef;
pub const ParamRef = device_ir.ParamRef;
pub const NoiseSource = device_ir.NoiseSource;
/// §4.6.1 `analysis()`: the analysis a `Circuit.setSimState` publishes.
pub const AnalysisKind = @FieldType(device_ir.SimState, "kind");
pub const Result = @import("core").Result;

/// Everything an analysis needs, resolved before dispatch.
pub const RunCtx = struct {
    circuit: *Circuit,
    /// The operating point. The session solves one ahead of every query except
    /// `.op` (the executor solves it) and `.tran uic` (the executor seeds ICs).
    x_op: []f64,
    probes: []const u32,
    /// Raw column label per probe, parallel to `probes`. May be empty in
    /// hand-built contexts; see `probeNames`.
    probe_labels: []const []const u8 = &.{},
    source_node: u32,
    source_branch: u32,
    /// Composite AC excitation `[re(0..n), im(0..n)]`, length `2 * circuit.n`,
    /// summed over every source card with an `AC mag [phase]`. An .ac sweep is
    /// one solve per frequency against this drive. Empty means no AC source,
    /// which gives a zero response, as in ngspice.
    ac_drive: []const f64 = &.{},
    /// The deck's circuit variants, for queries that sweep them as lanes.
    variants: @import("core").Variants = .{},
    /// Results arena: everything in the returned Result lives here.
    allocator: std.mem.Allocator,
    /// Reclaimable work storage.
    scratch_allocator: std.mem.Allocator,
    /// Where a transient or AC sweep writes its rows instead of keeping them
    /// (`Session.stream`); its Result then has empty `data`.
    stream: ?*std.Io.Writer = null,
};

/// Returns one column name per probe, preceded by `first` when given.
/// Labeled names borrow `ctx.probe_labels` (deck storage that outlives every
/// result), and without `first` the slice is `probe_labels` itself.
/// Unlabeled contexts fall back to `v(<node name>)`, or `v(<row>)` for an
/// unnamed branch row so two such columns never share a name, allocated from
/// `ctx.allocator`. Callers free nothing: the results arena owns the rest.
pub fn probeNames(ctx: *const RunCtx, first: ?[]const u8) ![]const []const u8 {
    const a = ctx.allocator;
    const labeled = ctx.probe_labels.len == ctx.probes.len;
    if (labeled and first == null) return ctx.probe_labels;
    const extra: usize = if (first == null) 0 else 1;
    const names = try a.alloc([]const u8, ctx.probes.len + extra);
    if (first) |name| names[0] = name;
    if (labeled) {
        @memcpy(names[extra..], ctx.probe_labels);
        return names;
    }
    for (ctx.probes, names[extra..]) |row, *out| {
        const label = ctx.circuit.nodeName(row);
        out.* = if (label.len == 0)
            try std.fmt.allocPrint(a, "v({d})", .{row})
        else
            try std.fmt.allocPrint(a, "v({s})", .{label});
    }
    return names;
}
