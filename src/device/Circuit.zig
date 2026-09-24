//! The frozen circuit: CSC pattern, device batches and node labels. `freeze`
//! consumes the construction protos; analysis instantiates mutable state from it.
const std = @import("std");
const abi = @import("device_abi");
const numerics = @import("numerics");
const Circuit = @This();

allocator: std.mem.Allocator,
n: u32,
nnz: u32,
col_ptr: []u32,
row_idx: []u32,
diag_slots: []u32,
batches: []abi.Batch,
/// The Library type of each batch, parallel to `batches`.
batch_types: []abi.DeviceType,
current_row: []bool,
intern_bytes: []u8,
intern_offs: []u32,
bbd: ?numerics.BbdInfo,
has_charge: bool,
has_state_q: bool,
needs_tran_op: bool = false,

pub fn freeze(
    allocator: std.mem.Allocator,
    n: u32,
    intern_bytes: []u8,
    intern_offs: []u32,
    protos: []const abi.Proto,
    types: []const abi.DeviceType,
    bbd: ?numerics.BbdInfo,
) !Circuit {
    if (n == 0 or intern_offs.len != @as(usize, n) + 1 or types.len != protos.len)
        return error.InvalidCircuit;
    const scratch = std.heap.smp_allocator;
    var pattern: abi.PatternBuilder = .{};
    defer pattern.deinit(scratch);
    try pattern.reserve(scratch, n);
    for (0..n) |i| try pattern.add(scratch, @intCast(i), @intCast(i));
    for (protos) |proto| try proto.pattern(proto.ctx, scratch, &pattern).unwrap();

    var col_ptr: []u32 = undefined;
    var row_idx: []u32 = undefined;
    const nnz = try pattern.toCsc(allocator, scratch, n, &col_ptr, &row_idx);
    errdefer allocator.free(col_ptr);
    errdefer allocator.free(row_idx);
    const view: abi.PatternView = .{
        .col_ptr = col_ptr,
        .row_idx = row_idx,
        .n = n,
        .trash_slot = nnz,
    };
    const diagonal = try allocator.alloc(u32, n);
    errdefer allocator.free(diagonal);
    for (diagonal, 0..) |*slot, i|
        slot.* = view.findSlot(@intCast(i), @intCast(i)) orelse return error.InvalidCircuit;

    const batches = try allocator.alloc(abi.Batch, protos.len);
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
    const batch_types = try allocator.dupe(abi.DeviceType, types);
    errdefer allocator.free(batch_types);
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
        .batch_types = batch_types,
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
    allocator.free(self.batch_types);
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
    return (abi.PatternView{
        .col_ptr = self.col_ptr,
        .row_idx = self.row_idx,
        .n = self.n,
        .trash_slot = self.nnz,
    }).findSlot(row, col);
}
