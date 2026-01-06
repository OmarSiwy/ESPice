//! Mir — Verilog-A mid-level IR, compact SoA storage.
//!
//! Every instruction is one fixed row {op, a, b, c} + result + next-in-block
//! link, stored column-wise in a MultiArrayList (25 B/inst vs the 44 B/inst
//! of the old tagged-union + linked-node layout). Variable-length payloads
//! (call args, phi operands) live in a single shared u32 pool. Consumers
//! still see a typed `InstructionData` union — it is decoded on read, so the
//! ergonomics cost nothing in storage.
//!
//! Field encoding by format:
//!   unary   a=arg
//!   binary  a=lhs b=rhs
//!   ternary a=cond b=then c=else            (select)
//!   branch  a=cond b=then_dst c=else_dst    (.br / .br_loop)
//!   jump    a=destination
//!   call    a=func_ref b=args_start c=args_len   (pool: [arg...])
//!   phi     a=pairs_start c=pair_count           (pool: [value, block]...)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buf = @import("emit").Buf;

const Mir = @This();

// ── Entity indices — u32-typed, no pointer arithmetic ─────────────────

pub const Block = enum(u32) {
    entry = 0,
    _,

    pub fn id(self: Block) u32 {
        return @intFromEnum(self);
    }
};

pub const Value = enum(u32) {
    undef = 0,
    false_ = 1,
    true_ = 2,
    f_zero = 3,
    zero = 4,
    one = 5,
    f_one = 6,
    f_neg_one = 7,
    f_two = 8,
    f_ten = 9,
    neg_one = 10,
    f_inf = 11,
    _,

    pub const first_dynamic = 12;

    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .undef => try w.print("undef", .{}),
            .false_ => try w.print("false", .{}),
            .true_ => try w.print("true", .{}),
            .f_zero => try w.print("0.0", .{}),
            .zero => try w.print("0", .{}),
            .one => try w.print("1", .{}),
            .f_one => try w.print("1.0", .{}),
            .f_neg_one => try w.print("-1.0", .{}),
            .f_two => try w.print("2.0", .{}),
            .f_ten => try w.print("10.0", .{}),
            .neg_one => try w.print("-1", .{}),
            .f_inf => try w.print("inf", .{}),
            _ => try w.print("v{d}", .{@intFromEnum(self)}),
        }
    }
};

pub const Inst = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn format(self: Inst, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("inst{d}", .{@intFromEnum(self)});
    }
};

/// Index into `call_names` — a call target is just a name; arity/effects
/// carried no information the backend ever read.
pub const FuncRef = enum(u32) { _ };

pub const StringIndex = enum(u32) { _ };

// ── Opcodes ───────────────────────────────────────────────────────────

pub const Opcode = enum(u8) {
    inot,
    bnot,
    ineg,
    fneg,
    fi_cast,
    if_cast,
    bi_cast,
    ib_cast,
    fb_cast,
    bf_cast,
    opt_barrier,
    sqrt,
    exp,
    ln,
    log,
    clog2,
    floor,
    ceil,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    iadd,
    isub,
    imul,
    idiv,
    irem,
    ishl,
    ishr,
    ixor,
    iand,
    ior,
    fadd,
    fsub,
    fmul,
    fdiv,
    frem,
    ilt,
    igt,
    ige,
    ile,
    flt,
    fgt,
    fge,
    fle,
    ieq,
    feq,
    seq,
    beq,
    ine,
    fne,
    sne,
    bne,
    hypot,
    atan2,
    pow,
    select,
    br,
    /// Branch that enters a loop body (backend lowers the header to `while`).
    br_loop,
    jmp,
    call,
    phi,

    pub fn instructionFormat(self: Opcode) InstructionFormat {
        return switch (self) {
            .inot, .bnot, .ineg, .fneg => .unary,
            .fi_cast, .if_cast, .bi_cast, .ib_cast, .fb_cast, .bf_cast => .unary,
            .opt_barrier => .unary,
            .sqrt, .exp, .ln, .log, .clog2, .floor, .ceil => .unary,
            .sin, .cos, .tan, .asin, .acos, .atan => .unary,
            .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => .unary,
            .iadd, .isub, .imul, .idiv, .irem => .binary,
            .ishl, .ishr, .ixor, .iand, .ior => .binary,
            .fadd, .fsub, .fmul, .fdiv, .frem => .binary,
            .ilt, .igt, .ige, .ile => .binary,
            .flt, .fgt, .fge, .fle => .binary,
            .ieq, .feq, .seq, .beq => .binary,
            .ine, .fne, .sne, .bne => .binary,
            .hypot, .atan2, .pow => .binary,
            .select => .ternary,
            .br, .br_loop => .branch,
            .jmp => .jump,
            .call => .call,
            .phi => .phi,
        };
    }

    pub fn hasResult(self: Opcode) bool {
        return switch (self) {
            .br, .br_loop, .jmp => false,
            else => true,
        };
    }

    pub fn name(self: Opcode) []const u8 {
        return @tagName(self);
    }
};

pub const InstructionFormat = enum { unary, binary, ternary, branch, jump, call, phi };

// ── Instruction data — decoded view over the packed row ───────────────

pub const InstructionData = union(InstructionFormat) {
    unary: struct { opcode: Opcode, arg: Value },
    binary: struct { opcode: Opcode, args: [2]Value },
    ternary: struct { opcode: Opcode, args: [3]Value },
    branch: struct { cond: Value, then_dst: Block, else_dst: Block, loop_entry: bool },
    jump: struct { destination: Block },
    call: struct { func_ref: FuncRef, args_start: u32, args_len: u16 },
    phi: struct { pairs_start: u32, len: u16 },

    pub fn opcode(self: InstructionData) Opcode {
        return switch (self) {
            .unary => |u| u.opcode,
            .binary => |b| b.opcode,
            .ternary => |t| t.opcode,
            .branch => |br| if (br.loop_entry) .br_loop else .br,
            .jump => .jmp,
            .call => .call,
            .phi => .phi,
        };
    }
};

// ── Value definition — {tag u8, payload u64} columns; decoded on read ─

pub const ValueDef = union(enum) {
    inst_result: Inst,
    block_param: struct { block: Block, index: u16 },
    /// Runtime read of a device parameter (index into Lower.params). Codegen
    /// renders it as `model.<name>` so generated devices honor .model cards
    /// instead of inlining the parameter's default.
    param_ref: u32,
    f_const: f64,
    i_const: i32,
    s_const: StringIndex,
    alias: Value,
    sentinel,
};

const ValueTag = std.meta.Tag(ValueDef);

/// One phi operand: `value` flows in from `block`.
pub const PhiPair = struct { value: Value, block: Block };

// ── SoA storage ────────────────────────────────────────────────────────

const InstRow = struct {
    op: Opcode,
    a: u32,
    b: u32,
    c: u32,
    result: Value,
    next: Inst,
};

const BlockRow = struct {
    first_inst: Inst,
    last_inst: Inst,
};

name: []const u8,
allocator: Allocator,

insts: std.MultiArrayList(InstRow) = .empty,
/// Blocks are created in program order and never reordered, so iteration
/// order is index order — no linked list.
blocks: std.MultiArrayList(BlockRow) = .empty,
values: std.MultiArrayList(struct { tag: ValueTag, payload: u64 }) = .empty,

/// Dedup maps for float/int constants — avoids duplicate Value entries.
fconst_map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
iconst_map: std.AutoHashMapUnmanaged(i32, Value) = .empty,

/// Shared u32 pool for call args ([arg...]) and phi operands ([value, block]...).
extra: Buf(u32) = .{},
/// Call target names (source-owned or static slices).
call_names: Buf([]const u8) = .{},
/// NUL-separated interned string literals.
strings: Buf(u8) = .{},

pub fn init(allocator: Allocator, func_name: []const u8) Mir {
    var self = Mir{ .name = func_name, .allocator = allocator };
    self.values.ensureTotalCapacity(allocator, Value.first_dynamic) catch unreachable;
    for (0..Value.first_dynamic) |_| {
        self.values.appendAssumeCapacity(.{ .tag = .sentinel, .payload = 0 });
    }
    return self;
}

pub fn deinit(self: *Mir) void {
    self.insts.deinit(self.allocator);
    self.blocks.deinit(self.allocator);
    self.values.deinit(self.allocator);
    self.fconst_map.deinit(self.allocator);
    self.iconst_map.deinit(self.allocator);
    self.extra.deinit(self.allocator);
    self.call_names.deinit(self.allocator);
    self.strings.deinit(self.allocator);
}

// ── Block operations ──────────────────────────────────────────────────

pub fn addBlock(self: *Mir) !Block {
    const idx: u32 = @intCast(self.blocks.len);
    try self.blocks.append(self.allocator, .{ .first_inst = .none, .last_inst = .none });
    return @enumFromInt(idx);
}

pub fn blockInsts(self: *const Mir, block: Block) BlockInstIterator {
    return .{ .mir = self, .current = self.blocks.items(.first_inst)[block.id()] };
}

pub const BlockInstIterator = struct {
    mir: *const Mir,
    current: Inst,

    pub fn next(self: *BlockInstIterator) ?Inst {
        const cur = self.current;
        if (cur == .none) return null;
        self.current = self.mir.insts.items(.next)[@intFromEnum(cur)];
        return cur;
    }
};

pub fn blockIter(self: *const Mir) BlockIterator {
    return .{ .n = @intCast(self.blocks.len) };
}

pub const BlockIterator = struct {
    i: u32 = 0,
    n: u32,

    pub fn next(self: *BlockIterator) ?Block {
        if (self.i >= self.n) return null;
        defer self.i += 1;
        return @enumFromInt(self.i);
    }
};

// ── Instruction operations ────────────────────────────────────────────

pub fn addInst(self: *Mir, block: Block, data: InstructionData) !Inst {
    const idx: u32 = @intCast(self.insts.len);
    const inst: Inst = @enumFromInt(idx);
    const op = data.opcode();

    const result: Value = if (op.hasResult())
        try self.addValue(.{ .inst_result = inst })
    else
        .undef;

    var row: InstRow = .{ .op = op, .a = 0, .b = 0, .c = 0, .result = result, .next = .none };
    switch (data) {
        .unary => |u| row.a = @intFromEnum(u.arg),
        .binary => |b| {
            row.a = @intFromEnum(b.args[0]);
            row.b = @intFromEnum(b.args[1]);
        },
        .ternary => |t| {
            row.a = @intFromEnum(t.args[0]);
            row.b = @intFromEnum(t.args[1]);
            row.c = @intFromEnum(t.args[2]);
        },
        .branch => |br| {
            row.a = @intFromEnum(br.cond);
            row.b = @intFromEnum(br.then_dst);
            row.c = @intFromEnum(br.else_dst);
        },
        .jump => |j| row.a = @intFromEnum(j.destination),
        .call => |c| {
            row.a = @intFromEnum(c.func_ref);
            row.b = c.args_start;
            row.c = c.args_len;
        },
        .phi => |p| {
            row.a = p.pairs_start;
            row.c = p.len;
        },
    }
    try self.insts.append(self.allocator, row);

    // Append to the block's inst chain.
    const firsts = self.blocks.items(.first_inst);
    const lasts = self.blocks.items(.last_inst);
    if (lasts[block.id()] == .none) {
        firsts[block.id()] = inst;
    } else {
        self.insts.items(.next)[@intFromEnum(lasts[block.id()])] = inst;
    }
    lasts[block.id()] = inst;

    return inst;
}

pub fn instResult(self: *const Mir, inst: Inst) Value {
    return self.insts.items(.result)[@intFromEnum(inst)];
}

pub fn instData(self: *const Mir, inst: Inst) InstructionData {
    const i = @intFromEnum(inst);
    const op = self.insts.items(.op)[i];
    const a = self.insts.items(.a)[i];
    const b = self.insts.items(.b)[i];
    const c = self.insts.items(.c)[i];
    return switch (op.instructionFormat()) {
        .unary => .{ .unary = .{ .opcode = op, .arg = @enumFromInt(a) } },
        .binary => .{ .binary = .{ .opcode = op, .args = .{ @enumFromInt(a), @enumFromInt(b) } } },
        .ternary => .{ .ternary = .{ .opcode = op, .args = .{ @enumFromInt(a), @enumFromInt(b), @enumFromInt(c) } } },
        .branch => .{ .branch = .{
            .cond = @enumFromInt(a),
            .then_dst = @enumFromInt(b),
            .else_dst = @enumFromInt(c),
            .loop_entry = op == .br_loop,
        } },
        .jump => .{ .jump = .{ .destination = @enumFromInt(a) } },
        .call => .{ .call = .{ .func_ref = @enumFromInt(a), .args_start = b, .args_len = @intCast(c) } },
        .phi => .{ .phi = .{ .pairs_start = a, .len = @intCast(c) } },
    };
}

/// Rewrite a placeholder phi's operand list (SSA construction back-patches
/// phis once all predecessors are known).
pub fn setPhiOperands(self: *Mir, inst: Inst, pairs_start: u32, len: u16) void {
    const i = @intFromEnum(inst);
    self.insts.items(.a)[i] = pairs_start;
    self.insts.items(.c)[i] = len;
}

// ── Value operations ──────────────────────────────────────────────────

pub fn addValue(self: *Mir, def: ValueDef) !Value {
    const idx: u32 = @intCast(self.values.len);
    const payload: u64 = switch (def) {
        .inst_result => |inst| @intFromEnum(inst),
        .block_param => |bp| @as(u64, bp.block.id()) | (@as(u64, bp.index) << 32),
        .param_ref => |p| p,
        .f_const => |f| @bitCast(f),
        .i_const => |i| @bitCast(@as(i64, i)),
        .s_const => |s| @intFromEnum(s),
        .alias => |v| @intFromEnum(v),
        .sentinel => 0,
    };
    try self.values.append(self.allocator, .{ .tag = def, .payload = payload });
    return @enumFromInt(idx);
}

pub fn addFConst(self: *Mir, val: f64) !Value {
    const bits: u64 = @bitCast(val);
    const gop = try self.fconst_map.getOrPut(self.allocator, bits);
    if (gop.found_existing) return gop.value_ptr.*;
    const v = try self.addValue(.{ .f_const = val });
    gop.value_ptr.* = v;
    return v;
}

pub fn addIConst(self: *Mir, val: i32) !Value {
    const gop = try self.iconst_map.getOrPut(self.allocator, val);
    if (gop.found_existing) return gop.value_ptr.*;
    const v = try self.addValue(.{ .i_const = val });
    gop.value_ptr.* = v;
    return v;
}

pub fn valueDef(self: *const Mir, val: Value) ValueDef {
    const i = @intFromEnum(val);
    const payload = self.values.items(.payload)[i];
    return switch (self.values.items(.tag)[i]) {
        .inst_result => .{ .inst_result = @enumFromInt(@as(u32, @truncate(payload))) },
        .block_param => .{ .block_param = .{
            .block = @enumFromInt(@as(u32, @truncate(payload))),
            .index = @truncate(payload >> 32),
        } },
        .param_ref => .{ .param_ref = @truncate(payload) },
        .f_const => .{ .f_const = @bitCast(payload) },
        .i_const => .{ .i_const = @intCast(@as(i64, @bitCast(payload))) },
        .s_const => .{ .s_const = @enumFromInt(@as(u32, @truncate(payload))) },
        .alias => .{ .alias = @enumFromInt(@as(u32, @truncate(payload))) },
        .sentinel => .sentinel,
    };
}

/// Redirect `val` to `target` (trivial-phi elimination).
pub fn setAlias(self: *Mir, val: Value, target: Value) void {
    const i = @intFromEnum(val);
    self.values.items(.tag)[i] = .alias;
    self.values.items(.payload)[i] = @intFromEnum(target);
}

pub fn resolveAlias(self: *const Mir, val: Value) Value {
    const tags = self.values.items(.tag);
    const payloads = self.values.items(.payload);
    var v = val;
    while (tags[@intFromEnum(v)] == .alias) {
        v = @enumFromInt(@as(u32, @truncate(payloads[@intFromEnum(v)])));
    }
    // ponytail: path compression — update root alias to point directly to resolved value.
    // const-cast is safe: transparent optimization, same logical result.
    if (v != val and tags[@intFromEnum(val)] == .alias) {
        @constCast(payloads)[@intFromEnum(val)] = @intFromEnum(v);
    }
    return v;
}

// ── Extra pool (call args / phi pairs) ────────────────────────────────

pub fn addExtra(self: *Mir, vals: []const u32) !u32 {
    const start: u32 = self.extra.len;
    try self.extra.appendSlice(self.allocator, vals);
    return start;
}

pub fn getExtraValues(self: *const Mir, start: u32, len: u16) []const Value {
    const raw = self.extra.slice()[start..][0..len];
    return @as([*]const Value, @ptrCast(raw.ptr))[0..len];
}

pub fn phiPair(self: *const Mir, pairs_start: u32, i: u32) PhiPair {
    const raw = self.extra.slice();
    return .{
        .value = @enumFromInt(raw[pairs_start + 2 * i]),
        .block = @enumFromInt(raw[pairs_start + 2 * i + 1]),
    };
}

// ── Call names ────────────────────────────────────────────────────────

pub fn addFuncName(self: *Mir, func_name: []const u8) !FuncRef {
    const idx: u32 = self.call_names.len;
    try self.call_names.append(self.allocator, func_name);
    return @enumFromInt(idx);
}

pub fn callName(self: *const Mir, ref: FuncRef) []const u8 {
    return self.call_names.slice()[@intFromEnum(ref)];
}

// ── String interning ──────────────────────────────────────────────────

pub fn internString(self: *Mir, str: []const u8) !StringIndex {
    const start: u32 = self.strings.len;
    try self.strings.appendSlice(self.allocator, str);
    try self.strings.append(self.allocator, 0);
    return @enumFromInt(start);
}

pub fn getString(self: *const Mir, idx: StringIndex) []const u8 {
    const slice = self.strings.slice()[@intFromEnum(idx)..];
    const end = std.mem.indexOfScalar(u8, slice, 0) orelse slice.len;
    return slice[0..end];
}

// ── Convenience builders ──────────────────────────────────────────────

pub fn buildUnary(self: *Mir, block: Block, op: Opcode, arg: Value) !Value {
    const inst = try self.addInst(block, .{ .unary = .{ .opcode = op, .arg = arg } });
    return self.instResult(inst);
}

pub fn buildBinary(self: *Mir, block: Block, op: Opcode, lhs: Value, rhs: Value) !Value {
    const inst = try self.addInst(block, .{ .binary = .{ .opcode = op, .args = .{ lhs, rhs } } });
    return self.instResult(inst);
}

pub fn buildBranch(self: *Mir, block: Block, cond: Value, then_dst: Block, else_dst: Block) !Inst {
    return self.addInst(block, .{ .branch = .{ .cond = cond, .then_dst = then_dst, .else_dst = else_dst, .loop_entry = false } });
}

pub fn buildJump(self: *Mir, block: Block, dst: Block) !Inst {
    return self.addInst(block, .{ .jump = .{ .destination = dst } });
}

pub fn buildCall(self: *Mir, block: Block, func_ref: FuncRef, args: []const Value) !Value {
    const start = try self.addExtra(@as([*]const u32, @ptrCast(args.ptr))[0..args.len]);
    const inst = try self.addInst(block, .{ .call = .{ .func_ref = func_ref, .args_start = start, .args_len = @intCast(args.len) } });
    return self.instResult(inst);
}

pub fn buildSelect(self: *Mir, block: Block, cond: Value, then_val: Value, else_val: Value) !Value {
    const inst = try self.addInst(block, .{ .ternary = .{ .opcode = .select, .args = .{ cond, then_val, else_val } } });
    return self.instResult(inst);
}

// ── Counts ────────────────────────────────────────────────────────────

pub fn numBlocks(self: *const Mir) u32 {
    return @intCast(self.blocks.len);
}

pub fn numInsts(self: *const Mir) u32 {
    return @intCast(self.insts.len);
}

pub fn numValues(self: *const Mir) u32 {
    return @intCast(self.values.len);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "round-trip inst encodings" {
    var mir = init(std.testing.allocator, "t");
    defer mir.deinit();

    const b0 = try mir.addBlock();
    const v = try mir.buildBinary(b0, .fadd, .f_one, .f_two);
    switch (mir.valueDef(v)) {
        .inst_result => {},
        else => return error.TestUnexpectedResult,
    }

    const sel = try mir.buildSelect(b0, .true_, v, .f_zero);
    const data = mir.instData(mir.instDataOfValue(sel));
    try std.testing.expectEqual(Opcode.select, data.opcode());

    const b1 = try mir.addBlock();
    _ = try mir.buildJump(b0, b1);

    // Block iteration is index order; inst chain follows insertion.
    var it = mir.blockInsts(b0);
    try std.testing.expectEqual(Opcode.fadd, mir.instData(it.next().?).opcode());
    try std.testing.expectEqual(Opcode.select, mir.instData(it.next().?).opcode());
    try std.testing.expectEqual(Opcode.jmp, mir.instData(it.next().?).opcode());
    try std.testing.expectEqual(@as(?Inst, null), it.next());
}

test "value defs round-trip" {
    var mir = init(std.testing.allocator, "t");
    defer mir.deinit();

    const f = try mir.addFConst(3.5);
    try std.testing.expectEqual(@as(f64, 3.5), mir.valueDef(f).f_const);

    const i = try mir.addIConst(-7);
    try std.testing.expectEqual(@as(i32, -7), mir.valueDef(i).i_const);

    const bp = try mir.addValue(.{ .block_param = .{ .block = .entry, .index = 5 } });
    try std.testing.expectEqual(@as(u16, 5), mir.valueDef(bp).block_param.index);

    mir.setAlias(f, i);
    try std.testing.expectEqual(i, mir.resolveAlias(f));
}

/// Test helper: the inst that produced a value.
fn instDataOfValue(self: *const Mir, v: Value) Inst {
    return self.valueDef(v).inst_result;
}
