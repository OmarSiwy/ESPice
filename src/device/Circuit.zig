//! The frozen circuit: CSC matrix pattern, one device batch per type, and node
//! names. `freeze` builds it from the construction protos; analysis
//! instantiates its mutable state from it.
const std = @import("std");
const abi = @import("device_abi");
const numerics = @import("core").numerics;
const Circuit = @This();

/// Owns every slice below.
allocator: std.mem.Allocator,
/// Matrix dimension; every node id is below it.
n: u32,
/// Structural nonzeros; also the trash slot ground stamps land in.
nnz: u32,
/// CSC column starts, n + 1 entries; rows ascend within a column.
col_ptr: []u32,
row_idx: []u32,
/// CSC slot of each diagonal entry.
diag_slots: []u32,
batches: []abi.Batch,
/// The Library type of each batch, parallel to `batches`.
batch_types: []abi.DeviceType,
/// Rows whose unknown is a branch current rather than a node voltage.
current_row: []bool,
/// Node names, concatenated; name i is `intern_bytes[intern_offs[i]..
/// intern_offs[i + 1]]`.
intern_bytes: []u8,
intern_offs: []u32,
bbd: ?numerics.BbdInfo,
/// CSC slot of every frequency-dependent small-signal entry, batch-major in
/// `batches` order, then as each batch's `Hooks.collect_ac_dyn` lists them;
/// `nnz` marks a ground entry. Entry e pairs with term e of `Hooks.ac_dyn`.
ac_dyn_slots: []u32,
/// Some batch stamps charge (`Batch.has_charge`).
has_charge: bool,
/// Some charge-bearing batch also keeps accepted-step state, so a transient
/// must restamp q after `update_state`/`commit_state`.
has_state_q: bool,
/// The builder found a node with only capacitors to it, so the operating
/// point falls back to ngspice's OPtran. Set after the freeze.
needs_tran_op: bool = false,

/// Builds the pattern from every proto and finalizes each into a batch
/// allocated with `allocator`. On success it destroys the protos and takes
/// ownership of `intern_bytes`, `intern_offs` and `bbd`; on failure the caller
/// keeps all of them. Fails with `InvalidCircuit` when `n` is 0 or the tables
/// do not match: `intern_offs` must hold n + 1 ascending offsets ending at
/// `intern_bytes.len`, and `types` one id per proto.
pub fn freeze(
    allocator: std.mem.Allocator,
    n: u32,
    intern_bytes: []u8,
    intern_offs: []u32,
    protos: []const abi.Proto,
    types: []const abi.DeviceType,
    bbd: ?numerics.BbdInfo,
) !Circuit {
    if (n == 0 or intern_offs.len != @as(usize, n) + 1 or types.len != protos.len or
        intern_offs[n] != intern_bytes.len or !std.sort.isSorted(u32, intern_offs, {}, std.sort.asc(u32)))
        return error.InvalidCircuit;
    const scratch = @import("core").gpa;
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
    // Every diagonal was added above.
    for (diagonal, 0..) |*slot, i| slot.* = view.findSlot(@intCast(i), @intCast(i)).?;

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
    errdefer allocator.free(current_row);
    for (batches) |batch| if (batch.hooks.mark_current_rows) |mark|
        mark(batch.ctx, current_row);
    var ac_dyn: std.ArrayList(u32) = .empty;
    errdefer ac_dyn.deinit(allocator);
    for (batches) |batch| if (batch.hooks.collect_ac_dyn) |collect|
        try collect(batch.ctx, allocator, &ac_dyn).unwrap();
    const ac_dyn_slots = try ac_dyn.toOwnedSlice(allocator);

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
        .ac_dyn_slots = ac_dyn_slots,
        .has_charge = has_charge,
        .has_state_q = has_state_q,
    };
}

/// Frees every batch and table, the adopted node names and `bbd` included.
pub fn deinit(self: *Circuit) void {
    const allocator = self.allocator;
    for (self.batches) |batch| batch.hooks.deinit(batch.ctx, allocator);
    allocator.free(self.batches);
    allocator.free(self.batch_types);
    allocator.free(self.col_ptr);
    allocator.free(self.row_idx);
    allocator.free(self.diag_slots);
    allocator.free(self.current_row);
    allocator.free(self.ac_dyn_slots);
    allocator.free(self.intern_bytes);
    allocator.free(self.intern_offs);
    if (self.bbd) |bbd| allocator.free(bbd.blocks);
    self.* = undefined;
}

/// The name of `node`, or "" when out of range.
pub fn nodeName(self: Circuit, node: u32) []const u8 {
    if (node >= self.n) return "";
    return self.intern_bytes[self.intern_offs[node]..self.intern_offs[node + 1]];
}

/// The CSC slot of (row, col), or null when it is out of range or not in the
/// pattern.
pub fn findSlot(self: Circuit, row: u32, col: u32) ?u32 {
    if (row >= self.n or col >= self.n) return null;
    return (abi.PatternView{
        .col_ptr = self.col_ptr,
        .row_idx = self.row_idx,
        .n = self.n,
        .trash_slot = self.nnz,
    }).findSlot(row, col);
}

/// A one-instance device that stamps (row, col) and owns one heap word, so
/// a leaked or double-freed batch shows up under the testing allocator.
const FakeProto = struct {
    row: u32,
    col: u32,

    const hooks: abi.Hooks = .{
        .instantiate = undefined,
        .snapshot = undefined,
        .copy_state = undefined,
        .scatter_bounds = undefined,
        .set_sim_state = undefined,
        .collect_params = undefined,
        .mark_current_rows = markCurrentRows,
        .collect_ac_dyn = collectAcDyn,
        .deinit = deinitBatch,
    };

    fn proto(self: *FakeProto) abi.Proto {
        return .{ .ctx = self, .type_name = "fake", .pattern = pattern, .finalize = finalize, .destroy = destroy, .apply_perm = applyPerm };
    }
    fn pattern(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *abi.PatternBuilder) abi.DeviceResult(void) {
        const self: *FakeProto = @ptrCast(@alignCast(ctx));
        return abi.DeviceResult(void).fromLocal(pb.add(gpa, self.row, self.col));
    }
    fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, view: abi.PatternView) abi.DeviceResult(abi.Batch) {
        const self: *FakeProto = @ptrCast(@alignCast(ctx));
        const slot = gpa.create(u32) catch return .out_of_memory;
        slot.* = view.findSlot(self.row, self.col).?;
        return .{ .ok = .{
            .ctx = slot,
            .eval = undefined,
            .eval_newton = undefined,
            .count = 1,
            .n_u = 2,
            .has_charge = false,
            .has_const_jacobian = true,
            .type_name = "fake",
            .hooks = &hooks,
        } };
    }
    fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    fn applyPerm(_: *anyopaque, _: []const u32) void {}
    fn markCurrentRows(_: *anyopaque, rows: []bool) void {
        rows[rows.len - 1] = true;
    }
    fn collectAcDyn(ctx: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayList(u32)) abi.DeviceResult(void) {
        const slot: *u32 = @ptrCast(@alignCast(ctx));
        return abi.DeviceResult(void).fromLocal(out.append(gpa, slot.*));
    }
    fn deinitBatch(ctx: *anyopaque, gpa: std.mem.Allocator) void {
        gpa.destroy(@as(*u32, @ptrCast(@alignCast(ctx))));
    }
};

fn freezeCase(gpa: std.mem.Allocator) !void {
    var fake: FakeProto = .{ .row = 0, .col = 1 };
    const protos = [_]abi.Proto{fake.proto()};
    const bytes = try gpa.dupe(u8, "ab");
    const offs = gpa.dupe(u32, &.{ 0, 1, 2 }) catch |err| {
        gpa.free(bytes);
        return err;
    };
    // On failure the caller keeps the names.
    var ckt = freeze(gpa, 2, bytes, offs, &protos, &.{@fromBackingInt(0)}, null) catch |err| {
        gpa.free(bytes);
        gpa.free(offs);
        return err;
    };
    defer ckt.deinit();

    const t = std.testing;
    // The diagonals plus (0, 1): column 0 {0}, column 1 {0, 1}.
    try t.expectEqual(@as(u32, 3), ckt.nnz);
    try t.expectEqualSlices(u32, &.{ 0, 1, 3 }, ckt.col_ptr);
    try t.expectEqualSlices(u32, &.{ 0, 0, 1 }, ckt.row_idx);
    try t.expectEqualSlices(u32, &.{ 0, 2 }, ckt.diag_slots);
    try t.expectEqualSlices(bool, &.{ false, true }, ckt.current_row);
    try t.expectEqualSlices(u32, &.{1}, ckt.ac_dyn_slots);
    try t.expectEqual(@as(?u32, 1), ckt.findSlot(0, 1));
    try t.expectEqual(@as(?u32, null), ckt.findSlot(1, 0));
    try t.expectEqual(@as(?u32, null), ckt.findSlot(2, 0));
    try t.expectEqual(@as(?u32, null), ckt.findSlot(0, 2));
    try t.expectEqualStrings("b", ckt.nodeName(1));
    try t.expectEqualStrings("", ckt.nodeName(2));
    try t.expect(!ckt.has_charge and !ckt.has_state_q);
}

test freeze {
    try freezeCase(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, freezeCase, .{});
}

test "freeze rejects inconsistent tables before touching a proto" {
    const t = std.testing;
    var fake: FakeProto = .{ .row = 0, .col = 0 };
    const protos = [_]abi.Proto{fake.proto()};
    const one: []const abi.DeviceType = &.{@fromBackingInt(0)};
    var bytes = "ab".*;
    var short = [_]u32{0};
    var offs = [_]u32{ 0, 1, 2 };
    var past_end = [_]u32{ 0, 1, 3 };
    var descending = [_]u32{ 0, 3, 2 };
    try t.expectError(error.InvalidCircuit, freeze(t.allocator, 0, &bytes, &short, &.{}, &.{}, null));
    try t.expectError(error.InvalidCircuit, freeze(t.allocator, 2, &bytes, &short, &protos, one, null));
    try t.expectError(error.InvalidCircuit, freeze(t.allocator, 2, &bytes, &offs, &protos, &.{}, null));
    try t.expectError(error.InvalidCircuit, freeze(t.allocator, 2, &bytes, &past_end, &protos, one, null));
    try t.expectError(error.InvalidCircuit, freeze(t.allocator, 2, &bytes, &descending, &protos, one, null));
}
