//! SSA construction (Braun et al.): variables are numbered Places, reads in
//! blocks with unknown predecessors get placeholder phis that are back-patched
//! at seal time. Per-block state lives in three parallel columns; the
//! variable-length lists (predecessors, pending phis) are intrusive linked
//! lists through two shared pools — no per-block allocations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buf = @import("emit").Buf;
const Mir = @import("Mir.zig");

const SsaBuilder = @This();

pub const Place = enum(u32) { _ };

const Block = Mir.Block;
const Value = Mir.Value;
const Inst = Mir.Inst;

const none = std.math.maxInt(u32);

const PredEdge = struct { pred: Block, next: u32 };
const PendingPhi = struct { place: Place, inst: Inst, next: u32 };

mir: *Mir,
position: ?Block = null,

/// Sparse (place, block) → Value — only stores actual definitions.
defs: std.AutoHashMapUnmanaged(u64, Value) = .empty,

/// Per-block columns, indexed by block id.
block_state: std.MultiArrayList(struct {
    sealed: bool,
    pred_head: u32, // index into pred_pool or `none`
    phi_head: u32, // index into phi_pool or `none`
}) = .empty,

pred_pool: Buf(PredEdge) = .{},
phi_pool: Buf(PendingPhi) = .{},

next_place: u32 = 0,

fn defKey(place: Place, block: Block) u64 {
    return @as(u64, @intFromEnum(place)) << 32 | block.id();
}

pub fn init(mir: *Mir) SsaBuilder {
    return .{ .mir = mir };
}

pub fn deinit(self: *SsaBuilder) void {
    const a = self.mir.allocator;
    self.defs.deinit(a);
    self.block_state.deinit(a);
    self.pred_pool.deinit(a);
    self.phi_pool.deinit(a);
}

pub fn newPlace(self: *SsaBuilder) !Place {
    const p: Place = @enumFromInt(self.next_place);
    self.next_place += 1;
    return p;
}

pub fn createBlock(self: *SsaBuilder) !Block {
    const blk = try self.mir.addBlock();
    try self.block_state.append(self.mir.allocator, .{ .sealed = false, .pred_head = none, .phi_head = none });
    return blk;
}

pub fn switchToBlock(self: *SsaBuilder, block: Block) void {
    self.position = block;
}

pub fn currentBlock(self: *SsaBuilder) Block {
    return self.position.?;
}

pub fn addPredecessor(self: *SsaBuilder, block: Block, pred: Block) !void {
    const heads = self.block_state.items(.pred_head);
    try self.pred_pool.append(self.mir.allocator, .{ .pred = pred, .next = heads[block.id()] });
    heads[block.id()] = self.pred_pool.len - 1;
}

pub fn sealBlock(self: *SsaBuilder, block: Block) !void {
    const sealed = self.block_state.items(.sealed);
    if (sealed[block.id()]) return;
    sealed[block.id()] = true;

    var i = self.block_state.items(.phi_head)[block.id()];
    while (i != none) {
        const pending = self.phi_pool.slice()[i];
        try self.addPhiOperands(pending.place, pending.inst, block);
        i = pending.next;
    }
    self.block_state.items(.phi_head)[block.id()] = none;
}

pub fn defVar(self: *SsaBuilder, place: Place, value: Value, block: Block) !void {
    try self.defs.put(self.mir.allocator, defKey(place, block), value);
}

pub fn useVar(self: *SsaBuilder, place: Place) !Value {
    return self.readVariable(place, self.position.?);
}

const SsaError = std.mem.Allocator.Error;

fn readVariable(self: *SsaBuilder, place: Place, block: Block) SsaError!Value {
    if (self.defs.get(defKey(place, block))) |val| return val;
    return self.readVariableRecursive(place, block);
}

fn readVariableRecursive(self: *SsaBuilder, place: Place, block: Block) SsaError!Value {
    const a = self.mir.allocator;
    const blk_id = block.id();

    if (!self.block_state.items(.sealed)[blk_id]) {
        // Predecessors still unknown: placeholder phi, patched at seal time.
        const phi = try self.buildEmptyPhi(block);
        const heads = self.block_state.items(.phi_head);
        try self.phi_pool.append(a, .{ .place = place, .inst = phi.inst, .next = heads[blk_id] });
        heads[blk_id] = self.phi_pool.len - 1;
        try self.defVar(place, phi.val, block);
        return phi.val;
    }

    const pred_head = self.block_state.items(.pred_head)[blk_id];
    var val: Value = undefined;
    if (pred_head == none) {
        val = .undef;
    } else if (self.pred_pool.slice()[pred_head].next == none) {
        // Single predecessor: no phi needed.
        val = try self.readVariable(place, self.pred_pool.slice()[pred_head].pred);
    } else {
        const phi = try self.buildEmptyPhi(block);
        try self.defVar(place, phi.val, block);
        try self.addPhiOperands(place, phi.inst, block);
        val = try self.tryRemoveTrivialPhi(phi.val, phi.inst);
    }

    try self.defVar(place, val, block);
    return val;
}

fn addPhiOperands(self: *SsaBuilder, place: Place, phi_inst: Inst, block: Block) SsaError!void {
    const a = self.mir.allocator;

    // Materialize [value, block] pairs fully before touching the shared extra
    // pool — reading a variable in a predecessor can recurse into more phis.
    var pairs: Buf(u32) = .{};
    defer pairs.deinit(a);

    var i = self.block_state.items(.pred_head)[block.id()];
    while (i != none) {
        const edge = self.pred_pool.slice()[i];
        const val = try self.readVariable(place, edge.pred);
        try pairs.append(a, @intFromEnum(val));
        try pairs.append(a, edge.pred.id());
        i = edge.next;
    }

    const start = try self.mir.addExtra(pairs.slice());
    self.mir.setPhiOperands(phi_inst, start, @intCast(pairs.len / 2));
}

fn tryRemoveTrivialPhi(self: *SsaBuilder, phi_val: Value, phi_inst: Inst) SsaError!Value {
    const data = self.mir.instData(phi_inst);
    const phi = switch (data) {
        .phi => |p| p,
        else => return phi_val,
    };

    var same: ?Value = null;
    for (0..phi.len) |i| {
        const resolved = self.mir.resolveAlias(self.mir.phiPair(phi.pairs_start, @intCast(i)).value);
        if (resolved == phi_val) continue;
        if (same) |s| {
            if (resolved == s) continue;
            return phi_val;
        }
        same = resolved;
    }

    const replacement = same orelse .undef;
    self.mir.setAlias(phi_val, replacement);
    return replacement;
}

const PhiResult = struct { val: Value, inst: Inst };

fn buildEmptyPhi(self: *SsaBuilder, block: Block) !PhiResult {
    const inst = try self.mir.addInst(block, .{ .phi = .{ .pairs_start = 0, .len = 0 } });
    return .{ .val = self.mir.instResult(inst), .inst = inst };
}

// ── Convenience: emit at current position ─────────────────────────────

pub fn buildUnary(self: *SsaBuilder, op: Mir.Opcode, arg: Value) !Value {
    return self.mir.buildUnary(self.position.?, op, arg);
}

pub fn buildBinary(self: *SsaBuilder, op: Mir.Opcode, lhs: Value, rhs: Value) !Value {
    return self.mir.buildBinary(self.position.?, op, lhs, rhs);
}

pub fn buildSelect(self: *SsaBuilder, cond: Value, then_val: Value, else_val: Value) !Value {
    return self.mir.buildSelect(self.position.?, cond, then_val, else_val);
}

pub fn buildBranch(self: *SsaBuilder, cond: Value, then_dst: Block, else_dst: Block) !void {
    _ = try self.mir.buildBranch(self.position.?, cond, then_dst, else_dst);
}

pub fn buildLoopBranch(self: *SsaBuilder, cond: Value, body: Block, exit: Block) !void {
    _ = try self.mir.addInst(self.position.?, .{ .branch = .{
        .cond = cond, .then_dst = body, .else_dst = exit, .loop_entry = true,
    } });
}

pub fn buildJump(self: *SsaBuilder, dst: Block) !void {
    _ = try self.mir.buildJump(self.position.?, dst);
}

pub fn buildCall(self: *SsaBuilder, func_ref: Mir.FuncRef, args: []const Value) !Value {
    return self.mir.buildCall(self.position.?, func_ref, args);
}

pub fn iconst(self: *SsaBuilder, val: i32) !Value {
    return switch (val) {
        0 => .zero,
        1 => .one,
        -1 => .neg_one,
        else => self.mir.addIConst(val),
    };
}

pub fn fconst(self: *SsaBuilder, val: f64) !Value {
    if (val == 0.0) return .f_zero;
    if (val == 1.0) return .f_one;
    if (val == -1.0) return .f_neg_one;
    if (val == 2.0) return .f_two;
    if (val == 10.0) return .f_ten;
    if (std.math.isInf(val) and val > 0) return .f_inf;
    return self.mir.addFConst(val);
}
