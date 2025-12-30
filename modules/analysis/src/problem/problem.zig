//! Comptime device → batch mechanism. Analysis-owned because it defines the
//! Jacobian convention every analysis consumes:
//!
//!   pattern:  dedup (row,col) set → sorted CSC, frozen at freeze()
//!   batches:  one per device TYPE (archetype), slot tapes precomputed
//!   AD:       device physics is written once, generic over a scalar S;
//!             eval runs it on a derivative-carrying scalar, so one pass
//!             yields residual + all partials. No finite differences.
//!
//! Ground is branch-free: x[0] is a real unknown pinned to 0 by the ground
//! equation (g[0,0] = 1, rhs[0] = x[0]); device stamps touching row or
//! column 0 land in a trash slot (index nnz) / trash rhs (index n).
//!
//! Construction policy (node interning, BBD permutation) lives with the app
//! in src/builder.zig; it accumulates ProtoStore(D)s behind the Proto fn-ptr
//! table and hands them to freeze().

const std = @import("std");
const root = @import("../root.zig");

const batch = @import("batch.zig");
const gpu = @import("gpu.zig");
const par = @import("par.zig");
const pattern = @import("pattern.zig");

const Batch = root.Batch;
const Circuit = root.Circuit;
const PatternBuilder = pattern.PatternBuilder;

// -- public surface (analysis.problem.*) --
pub const ProtoStore = batch.ProtoStore;
pub const dyn = @import("dyn.zig");
pub const HistLookup = @import("history.zig").HistLookup;
pub const AdScalar = @import("ad.zig").AdScalar;
pub const ParEval = par.ParEval;
pub const EvalTask = par.EvalTask;
pub const default_min_instances = par.default_min_instances;
pub const GpuProblem = gpu.GpuProblem;
pub const TranPack = gpu.TranPack;
pub const packGpuProblem = gpu.packGpuProblem;
pub const gpuEligible = gpu.gpuEligible;

// ---------------------------------------------------------------------------
// Proto: type-erased accumulation store, one per device TYPE (archetype).
// Builder code holds []Proto; freeze() consumes them into Batches.
// ---------------------------------------------------------------------------
pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) anyerror!void,
    finalize: *const fn (*anyopaque, std.mem.Allocator, *const Circuit) anyerror!Batch,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

/// Freeze: build the union sparsity pattern (full diagonal + every
/// non-ground device entry), allocate planes, precompute every slot
/// tape. The protos are consumed (finalized into batches, shells freed).
/// Takes ownership of node_names and node_labels.
pub fn freeze(
    gpa: std.mem.Allocator,
    n: u32,
    node_names: std.StringHashMapUnmanaged(u32),
    node_labels: [][]const u8,
    protos: []const Proto,
    bbd: ?root.BbdInfo,
) !Circuit {
    var pb: PatternBuilder = .{};
    defer pb.deinit(gpa);
    try pb.reserve(gpa, n);
    for (0..n) |i| try pb.add(gpa, @intCast(i), @intCast(i));
    for (protos) |p| try p.pattern(p.ctx, gpa, &pb);

    var ckt: Circuit = undefined;
    ckt.gpa = gpa;
    ckt.n = n;
    ckt.node_names = node_names;
    ckt.node_labels = node_labels;
    ckt.has_charge = false;
    ckt.has_history = false;
    ckt.has_baseline = false;
    ckt.gpu_active = false;
    ckt.g_base = &.{};
    ckt.c_base = &.{};
    ckt.bbd = bbd;
    ckt.par_eval = null;
    ckt.ws = null;
    ckt.param_refs = null;
    ckt.gpu_hook = null;

    ckt.nnz = try pb.toCsc(gpa, n, &ckt.col_ptr, &ckt.row_idx);
    errdefer gpa.free(ckt.col_ptr);
    errdefer gpa.free(ckt.row_idx);
    ckt.trash_slot = ckt.nnz;
    ckt.g_vals = try gpa.alloc(f64, ckt.nnz + 1);
    errdefer gpa.free(ckt.g_vals);
    ckt.c_vals = try gpa.alloc(f64, ckt.nnz + 1);
    errdefer gpa.free(ckt.c_vals);
    ckt.rhs = try gpa.alloc(f64, @as(usize, n) + 1);
    errdefer gpa.free(ckt.rhs);
    ckt.q_vec = try gpa.alloc(f64, @as(usize, n) + 1);
    errdefer gpa.free(ckt.q_vec);
    // eval() only re-zeroes c_vals/q_vec when has_charge; chargeless
    // circuits must still expose an exact C = 0 plane (pz/stb/ac read it).
    @memset(ckt.c_vals, 0);
    @memset(ckt.q_vec, 0);

    ckt.diag_slots = try gpa.alloc(u32, n);
    errdefer gpa.free(ckt.diag_slots);
    for (0..n) |i| ckt.diag_slots[i] = ckt.findSlot(@intCast(i), @intCast(i)).?;

    const batches = try gpa.alloc(Batch, protos.len);
    errdefer gpa.free(batches);
    var n_final: usize = 0;
    errdefer for (batches[0..n_final]) |b| b.hooks.deinit(b.ctx, gpa);
    for (protos, 0..) |p, bi| {
        batches[bi] = try p.finalize(p.ctx, gpa, &ckt);
        n_final = bi + 1;
        if (batches[bi].has_charge) ckt.has_charge = true;
        if (batches[bi].hooks.inject_history != null) ckt.has_history = true;
    }
    ckt.batches = batches;

    // Row-kind mask: branch-current unknowns get abstol, node voltages get
    // vntol in the converger (ngspice NIconvTest split).
    ckt.current_row = try gpa.alloc(bool, n);
    @memset(ckt.current_row, false);
    for (batches) |b| if (b.hooks.mark_current_rows) |f| f(b.ctx, ckt.current_row);

    // Protos consumed: instance data moved into batches, shells freed.
    for (protos) |p| p.destroy(p.ctx, gpa);
    return ckt;
}
