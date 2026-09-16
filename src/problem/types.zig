//! Shared prepared data; consumers never import the Problem facade.
const std = @import("std");
pub const requests = @import("requests");
pub const device_ir = @import("device_ir");
pub const numerics = @import("numerics");
pub const GROUND: u32 = 0;

/// Resolved initial condition, applied together when a query starts with UIC.
pub const Ic = struct { node: u32, value: f64 };

/// A stable parameter identity; each analysis clone resolves its own pointer.
pub const AcOverride = struct {
    type_name: []const u8,
    index: u32,
    param_name: []const u8,
    value: f64,
};

/// Construction bindings retained for resolving later analysis directives.
pub const QueryBindings = struct {
    v_names: []const []const u8,
    i_names: []const []const u8,
    v_branches: []const u32,
    /// Node rows of each V card, `+` then `−`, post-permutation.
    v_pos: []const u32,
    v_neg: []const u32,
    /// Same for each I card. An I source has no branch row of its own.
    i_pos: []const u32,
    i_neg: []const u32,
    v_distof1: []const [2]f64,
    ports: []const requests.Port,
};

/// Session-owned construction result. Parse scratch may be released immediately.
/// The circuit is immutable once published; analysis clones mutable state.
pub const Prepared = struct {
    circuit: Circuit,
    probes: []const u32,
    probe_labels: []const []const u8,
    source_node: u32,
    source_branch: u32,
    ac_drive: []const f64,
    title: []const u8,
    n_devices: u32,
    ic: []const Ic,
    deck_tol: numerics.Tolerances,
    deck_temp: ?f64,
    deck_method: ?requests.Method,
    queries: []const requests.Query,
    bindings: QueryBindings,
    cards: []const requests.CardRef,
    ac_overrides: []const AcOverride,

    /// The caller owns the arena containing all remaining metadata slices.
    pub fn deinit(self: *Prepared) void {
        self.circuit.deinit();
        self.* = undefined;
    }
};

/// Prepared circuit storage and construction bindings; contains no solvers.
pub const Circuit = struct {
    allocator: std.mem.Allocator,
    n: u32,
    nnz: u32,
    col_ptr: []u32,
    row_idx: []u32,
    diag_slots: []u32,
    batches: []device_ir.Batch,
    current_row: []bool,
    intern_bytes: []u8,
    intern_offs: []u32,
    bbd: ?numerics.BbdInfo,
    has_charge: bool,
    has_state_q: bool,
    needs_tran_op: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        n: u32,
        intern_bytes: []u8,
        intern_offs: []u32,
        protos: []const device_ir.Proto,
        bbd: ?numerics.BbdInfo,
    ) !Circuit {
        if (n == 0 or intern_offs.len != @as(usize, n) + 1)
            return error.InvalidCircuit;
        const scratch = std.heap.smp_allocator;
        var pattern: device_ir.PatternBuilder = .{};
        defer pattern.deinit(scratch);
        try pattern.reserve(scratch, n);
        for (0..n) |i| try pattern.add(scratch, @intCast(i), @intCast(i));
        for (protos) |proto| try proto.pattern(proto.ctx, scratch, &pattern).unwrap();

        var col_ptr: []u32 = undefined;
        var row_idx: []u32 = undefined;
        const nnz = try pattern.toCsc(allocator, scratch, n, &col_ptr, &row_idx);
        errdefer allocator.free(col_ptr);
        errdefer allocator.free(row_idx);
        const view: device_ir.PatternView = .{
            .col_ptr = col_ptr,
            .row_idx = row_idx,
            .n = n,
            .trash_slot = nnz,
        };
        const diagonal = try allocator.alloc(u32, n);
        errdefer allocator.free(diagonal);
        for (diagonal, 0..) |*slot, i|
            slot.* = view.findSlot(@intCast(i), @intCast(i)) orelse return error.InvalidCircuit;

        const batches = try allocator.alloc(device_ir.Batch, protos.len);
        errdefer allocator.free(batches);
        var count: usize = 0;
        errdefer for (batches[0..count]) |batch| batch.hooks.deinit(batch.ctx, allocator);
        var has_charge = false;
        var has_state_q = false;
        for (protos, batches) |proto, *batch| {
            batch.* = try proto.finalize(proto.ctx, allocator, view).unwrap();
            count += 1;
            has_charge = has_charge or batch.has_charge;
            has_state_q = has_state_q or (batch.has_charge and
                (batch.hooks.update_state != null or batch.hooks.commit_state != null));
        }
        const current_row = try allocator.alloc(bool, n);
        @memset(current_row, false);
        for (batches) |batch| if (batch.hooks.mark_current_rows) |mark|
            mark(batch.ctx, current_row);

        for (protos) |proto| proto.destroy(proto.ctx, allocator);
        return .{
            .allocator = allocator,
            .n = n,
            .nnz = nnz,
            .col_ptr = col_ptr,
            .row_idx = row_idx,
            .diag_slots = diagonal,
            .batches = batches,
            .current_row = current_row,
            .intern_bytes = intern_bytes,
            .intern_offs = intern_offs,
            .bbd = bbd,
            .has_charge = has_charge,
            .has_state_q = has_state_q,
        };
    }

    pub fn deinit(self: *Circuit) void {
        const allocator = self.allocator;
        for (self.batches) |batch| batch.hooks.deinit(batch.ctx, allocator);
        allocator.free(self.batches);
        allocator.free(self.col_ptr);
        allocator.free(self.row_idx);
        allocator.free(self.diag_slots);
        allocator.free(self.current_row);
        allocator.free(self.intern_bytes);
        allocator.free(self.intern_offs);
        if (self.bbd) |bbd| allocator.free(bbd.blocks);
        self.* = undefined;
    }

    pub fn nodeName(self: Circuit, node: u32) []const u8 {
        if (node >= self.n) return "";
        return self.intern_bytes[self.intern_offs[node]..self.intern_offs[node + 1]];
    }

    pub fn findSlot(self: Circuit, row: u32, col: u32) ?u32 {
        if (row >= self.n or col >= self.n) return null;
        return (device_ir.PatternView{
            .col_ptr = self.col_ptr,
            .row_idx = self.row_idx,
            .n = self.n,
            .trash_slot = self.nnz,
        }).findSlot(row, col);
    }
};
