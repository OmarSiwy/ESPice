//! Class 4 — MIR (mid-level SSA IR). LRM §4.2 operators, §5 control flow.
//! This is the engine's stable IR — the Zig-ZIR analogue in spirit.
//!
//! Transformation: lowering writes MIR; proof.zig reads it; codegen.zig walks it.
//!
//! DOD (this is the performance core):
//!   - Instructions are a MultiArrayList of fixed rows {op,a,b,c,result,next}
//!     (21 B/inst as SoA columns), NOT tagged unions in a linked list.
//!   - Values, blocks, and the extra payload pool are separate SoA arrays.
//!   - Every reference is a typed enum(u32) handle.
//!   - Constants are deduped (fconst_map/iconst_map) at construction.
//!
//! CANONICALIZATION WARNING (for naming.zig / proof.zig): a Value's identity is
//! its enum(u32) index, which RENUMBERS when the source changes. Never let that
//! index leak into an emitted name or a content hash — canonicalize to stable
//! leaf identities first (see naming.zig). Concretely: `v{@intFromEnum(v)}` in a
//! declaration name or in a src_hash input reintroduces total-rebuild churn.
//!
//! DETERMINISM: every table here grows by append, so identical input yields
//! identical indices. The two const maps and the alias map are LOOKUP-ONLY —
//! never iterate them; HashMap iteration order is not part of the contract.
//!
//! This file IS the `Mir` struct (file-as-struct): `@import("mir.zig")` is both
//! the namespace (`Mir.Value`, `Mir.Opcode`) and the value type (`mir: *Mir`).

const std = @import("std");
const Ast = @import("ast.zig");
const assert = std.debug.assert;

pub const Mir = @This(); // so `Mir.Mir` also resolves for callers that spell it out

pub const Inst = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Value = enum(u32) {
    // Reserved sentinels 0..11 (common constants); dynamic values from 12+.
    undef = 0,
    f_zero,
    f_one,
    f_neg_one,
    f_two,
    f_ten,
    f_inf,
    zero,
    one,
    neg_one,
    false_,
    true_,
    _,

    /// First dynamic Value index. Values below this are the sentinels above and
    /// have no row in the `defs` side table.
    pub const first_dynamic: u32 = 12;

    pub fn idx(v: Value) u32 {
        return @intFromEnum(v);
    }
};
pub const Block = enum(u32) { entry = 0, _ };
/// Interned string handle (call callees, §4.4 access names, ch9 sysfunc names).
/// The SAME type the AST uses — one interning mechanism in the engine — but it
/// indexes THIS Mir's `strings` table, not the AST's. `.none` is the absent
/// sentinel. See `internString` / `stringOf`.
pub const StrId = Ast.StrId;

/// Opcode set. LRM §4.2 (arith/rel/logic/bit/shift), §4.3 (math), casts.
/// Closed enum → switch in hot loops (no vtable). Smallest tag.
///
/// Naming convention (load-bearing, `opIsInteger` relies on it): a leading `f`
/// is the real-valued form, a leading `i` the integer form. Math functions
/// (§4.3) are always real-valued and carry the bare LRM name.
pub const Opcode = enum(u8) {
    // --- arithmetic §4.2.4 (+ unary §4.2.3, modulus §4.2.4) ---
    fadd,
    fsub,
    fmul,
    fdiv,
    fmod,
    fneg,
    iadd,
    isub,
    imul,
    idiv,
    imod,
    ineg,
    // --- relational §4.2.5 / equality §4.2.7 (yield integer 0/1) ---
    flt,
    fgt,
    fle,
    fge,
    feq,
    fne,
    ilt,
    igt,
    ile,
    ige,
    ieq,
    ine,
    // --- logical §4.2.8 (integer 0/1 result) ---
    logand,
    logor,
    lognot,
    // --- bitwise §4.2.9 (integer only; reduction §4.2.10 is digital-only) ---
    bitand,
    bitor,
    bitxor,
    bitxnor,
    bitnot,
    // --- shifts §4.2.11 (logical << >> only; <<< >>> are illegal in analog) ---
    shl,
    shr,
    // --- standard math, LRM Table 4-14 §4.3.1 ---
    sqrt,
    exp,
    expm1,
    ln,
    ln1p,
    log10,
    pow,
    hypot,
    floor,
    ceil,
    fabs,
    fmin,
    fmax, // real forms
    iabs,
    imin,
    imax, // integer forms (§4.3.1: int operands ⇒ int result)
    // --- trigonometric + hyperbolic, LRM Table 4-15 §4.3.2 ---
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2,
    sinh,
    cosh,
    tanh,
    asinh,
    acosh,
    atanh,
    // --- casts §4.2.1.1 (real→integer, rounds) / §4.2.1.2 (integer→real) ---
    fi_cast,
    if_cast,
    /// Optimization fence (no LRM basis, see SPEC-MAP "engine-internal"): stops
    /// codegen from folding/reassociating across it. Unary, value-preserving.
    opt_barrier,
    // --- value-form conditional §4.2.12 (`?:` that needs no CFG split) ---
    select,
    // --- control §5.8/§5.9 ---
    phi,
    branch,
    jump,
    call,
};

pub const OpClass = enum(u8) { unary, binary, ternary, phi, branch, jump, call };

/// Operand shape of an opcode. Drives `instData` decoding.
pub fn opClass(op: Opcode) OpClass {
    return switch (op) {
        .fneg,
        .ineg,
        .lognot,
        .bitnot,
        .sqrt,
        .exp,
        .expm1,
        .ln,
        .ln1p,
        .log10,
        .floor,
        .ceil,
        .fabs,
        .iabs,
        .sin,
        .cos,
        .tan,
        .asin,
        .acos,
        .atan,
        .sinh,
        .cosh,
        .tanh,
        .asinh,
        .acosh,
        .atanh,
        .fi_cast,
        .if_cast,
        .opt_barrier,
        => .unary,
        .select => .ternary,
        .phi => .phi,
        .branch => .branch,
        .jump => .jump,
        .call => .call,
        // everything else is a two-operand op
        else => .binary,
    };
}

/// Does `op` produce an integer (LRM §3.2 integer) rather than a real?
/// Relational/equality/logical operators yield integer 0/1 (§4.2.5, §4.2.8).
/// Shared here so proof.zig and codegen.zig do not each carry the switch.
pub fn opIsInteger(op: Opcode) bool {
    return switch (op) {
        .iadd,
        .isub,
        .imul,
        .idiv,
        .imod,
        .ineg,
        .flt,
        .fgt,
        .fle,
        .fge,
        .feq,
        .fne,
        .ilt,
        .igt,
        .ile,
        .ige,
        .ieq,
        .ine,
        .logand,
        .logor,
        .lognot,
        .bitand,
        .bitor,
        .bitxor,
        .bitxnor,
        .bitnot,
        .shl,
        .shr,
        .iabs,
        .imin,
        .imax,
        .fi_cast,
        => true,
        else => false,
    };
}

/// One instruction row. Fixed width; operands are Value/Block/StrId handles
/// packed into a/b/c; `result` is the produced Value; `next` links within a block.
///
/// Operand encoding per class (see `instData` for the decoded view):
///   unary   a = operand
///   binary  a = lhs, b = rhs
///   ternary a = cond, b = then value, c = else value        (§4.2.12)
///   phi     b = extra start, c = pair count (2 u32 per pair: block, value)
///   branch  a = cond, b = then Block, c = else Block        (§5.8)
///   jump    a = target Block                                (§5.9)
///   call    a = callee StrId, b = extra start, c = arg count
pub const InstRow = struct {
    op: Opcode,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    result: Value = .undef,
    next: Inst = .none,
    /// PROVENANCE: index of the token this instruction came from, for
    /// diagnostics, or `no_tok`. Never set by a caller — `addInst` stamps it
    /// from `Mir.cur_tok` (see there).
    ///
    /// DOD: this is a COLD column. `insts` is a MultiArrayList, so the bytes
    /// live in their own run and no hot walk that asks for `.op`/`.a`/`.b`
    /// touches them. It costs 4 bytes per instruction of memory and nothing
    /// per instruction of bandwidth — which is what buys class-6 diagnostics
    /// a source location at all (they used to report at line 0, column 0).
    tok: u32 = no_tok,
};

/// "This instruction has no AST origin" — a constant materialised by the SSA
/// builder, say. It must NOT be spelled 0: token 0 is a real token (the first
/// one in the file), so a zero default silently pointed every unattributed
/// instruction at the top of the annex-D prelude, and diagnostics labelled
/// themselves `discipline \logic ;`.
pub const no_tok: u32 = std.math.maxInt(u32);

pub const BlockRow = struct { first: Inst = .none, last: Inst = .none };

/// How a Value came to be. Hot: proof.zig switches on this per value.
pub const DefKind = enum(u8) {
    undef,
    float_const, // §4.2 constant expression, real
    int_const, // §4.2 constant expression, integer
    str_const, // §2.7 string literal (ch9 format args, §4.4 names)
    param_ref, // §3.4 parameter — index into Lower.params
    block_param, // §4.4 probe: index into the unknown vector (Lower.node_order)
    inst_result, // result of an instruction
};

/// Decoded definition of a Value (see `valueDef`). Not stored — built on read.
pub const Def = union(DefKind) {
    undef,
    float_const: f64,
    int_const: i64,
    str_const: []const u8,
    param_ref: u32,
    block_param: u32,
    inst_result: Inst,
};

/// SoA row of the value-definition side table. `payload` is kind-dependent:
/// float bits / int bits / StrId / param index / unknown index / Inst.
pub const ValueRow = struct { kind: DefKind, payload: u64 };

/// Decoded instruction view. Built on demand; never stored (see InstRow).
pub const InstData = union(OpClass) {
    unary: struct { op: Opcode, operand: Value },
    binary: struct { op: Opcode, lhs: Value, rhs: Value },
    ternary: struct { op: Opcode, cond: Value, then_val: Value, else_val: Value },
    phi: struct { start: u32, count: u32 },
    branch: struct { cond: Value, then_block: Block, else_block: Block },
    jump: struct { target: Block },
    call: struct { callee: StrId, name: []const u8, args: []const Value },
};

pub const PhiPair = struct { block: Block, value: Value };

name: []const u8 = "",
/// PROVENANCE CURSOR. Whoever builds the MIR sets this to the token index of
/// the AST node currently being lowered; `addInst` stamps it onto every row.
///
/// A cursor rather than a parameter on `emit`, because lowering emits from
/// hundreds of call sites but visits AST nodes from a handful — one assignment
/// per node beats threading a token through every operand helper, and there is
/// no way for the two to disagree.
cur_tok: u32 = no_tok,
insts: std.MultiArrayList(InstRow) = .empty,
blocks: std.MultiArrayList(BlockRow) = .empty,
/// Definition of every dynamic Value; index = @intFromEnum(v) - first_dynamic.
defs: std.MultiArrayList(ValueRow) = .empty,
/// Shared variable-length payload pool (call args, phi operands). SoA.
/// (0.16: `std.ArrayList` IS the unmanaged list; `ArrayListUnmanaged` is the
/// deprecated alias. Same spelling as ast.zig.)
extra: std.ArrayList(u32) = .empty,
/// String table — the AST's interner type, so "interned string" has one shape
/// engine-wide. Slices are NOT copied: they must outlive the Mir (arena).
strings: Ast.StringInterner = .empty,
/// Constant dedup (LRM §4 constant expressions). Cold maps, build-time only.
/// Keyed by exact bits so -0.0 / 0.0 stay distinct and NaN payloads survive.
fconst_map: std.AutoHashMapUnmanaged(u64, Value) = .empty,
iconst_map: std.AutoHashMapUnmanaged(i64, Value) = .empty,
/// Trivial-phi aliases (ssa.zig `tryRemoveTrivialPhi`). Union-find parent array
/// parallel to `defs` (index = value - first_dynamic); an entry equal to its own
/// Value means "no alias". Only collapsed phis point elsewhere, so codegen never
/// emits a decl for them.
alias: std.ArrayList(Value) = .empty,

pub fn deinit(self: *Mir, gpa: std.mem.Allocator) void {
    self.insts.deinit(gpa);
    self.blocks.deinit(gpa);
    self.defs.deinit(gpa);
    self.extra.deinit(gpa);
    self.strings.deinit(gpa);
    self.fconst_map.deinit(gpa);
    self.iconst_map.deinit(gpa);
    self.alias.deinit(gpa);
    self.* = .{ .name = self.name };
}

// ---------------------------------------------------------------- values ----

/// Register a new dynamic Value. Prefer the typed helpers below.
pub fn addValue(self: *Mir, gpa: std.mem.Allocator, kind: DefKind, payload: u64) !Value {
    const i = self.defs.len + Value.first_dynamic;
    assert(i < std.math.maxInt(u32));
    const v: Value = @enumFromInt(@as(u32, @intCast(i)));
    try self.defs.append(gpa, .{ .kind = kind, .payload = payload });
    try self.alias.append(gpa, v); // self-parent = no alias
    return v;
}

/// LRM §4.2 real constant, deduped. Common literals map onto the sentinels so
/// two spellings of `1.0` are the same Value in every compilation.
pub fn addFloatConst(self: *Mir, gpa: std.mem.Allocator, x: f64) !Value {
    const bits: u64 = @bitCast(x);
    switch (bits) {
        @as(u64, @bitCast(@as(f64, 0.0))) => return .f_zero,
        @as(u64, @bitCast(@as(f64, 1.0))) => return .f_one,
        @as(u64, @bitCast(@as(f64, -1.0))) => return .f_neg_one,
        @as(u64, @bitCast(@as(f64, 2.0))) => return .f_two,
        @as(u64, @bitCast(@as(f64, 10.0))) => return .f_ten,
        @as(u64, @bitCast(std.math.inf(f64))) => return .f_inf,
        else => {},
    }
    const gop = try self.fconst_map.getOrPut(gpa, bits);
    if (!gop.found_existing) gop.value_ptr.* = try self.addValue(gpa, .float_const, bits);
    return gop.value_ptr.*;
}

/// LRM §4.2 integer constant, deduped.
pub fn addIntConst(self: *Mir, gpa: std.mem.Allocator, x: i64) !Value {
    switch (x) {
        0 => return .zero,
        1 => return .one,
        -1 => return .neg_one,
        else => {},
    }
    const gop = try self.iconst_map.getOrPut(gpa, x);
    if (!gop.found_existing)
        gop.value_ptr.* = try self.addValue(gpa, .int_const, @bitCast(x));
    return gop.value_ptr.*;
}

/// LRM §2.7 string literal. The string itself is deduped by the interner; the
/// Value wrapper is not (a handful per module, and identical strings are
/// behaviorally interchangeable).
pub fn addStrConst(self: *Mir, gpa: std.mem.Allocator, bytes: []const u8) !Value {
    const s = try self.internString(gpa, bytes);
    return self.addValue(gpa, .str_const, @intFromEnum(s));
}

/// LRM §3.4 parameter reference. `param` indexes Lower.params.
pub fn addParamRef(self: *Mir, gpa: std.mem.Allocator, param: u32) !Value {
    return self.addValue(gpa, .param_ref, param);
}

/// LRM §4.4 signal-access probe. `unknown` indexes the solver unknown vector
/// (Lower.node_order → the generated `U` enum, i.e. codegen's `x[unknown]`).
/// V(a,b) lowers to fsub of two probes; a branch-current unknown gets its own
/// node_order slot.
pub fn addBlockParam(self: *Mir, gpa: std.mem.Allocator, unknown: u32) !Value {
    return self.addValue(gpa, .block_param, unknown);
}

/// Intern a name into this Mir's table. `bytes` is BORROWED (arena / source
/// buffer) and must outlive the Mir. Idempotent, so the same callee name is one
/// StrId no matter how many call sites use it.
pub fn internString(self: *Mir, gpa: std.mem.Allocator, bytes: []const u8) !StrId {
    return self.strings.intern(gpa, bytes);
}

pub fn stringOf(self: *const Mir, s: StrId) []const u8 {
    return self.strings.get(s);
}

/// Definition of `value`. Sentinels are decoded without a table lookup.
pub fn valueDef(self: *const Mir, value: Value) Def {
    switch (value) {
        .undef => return .undef,
        .f_zero => return .{ .float_const = 0.0 },
        .f_one => return .{ .float_const = 1.0 },
        .f_neg_one => return .{ .float_const = -1.0 },
        .f_two => return .{ .float_const = 2.0 },
        .f_ten => return .{ .float_const = 10.0 },
        .f_inf => return .{ .float_const = std.math.inf(f64) },
        // §4.2.8: booleans are just integers 0/1; false_/true_ exist for
        // readable lowering and decode identically to zero/one.
        .zero, .false_ => return .{ .int_const = 0 },
        .one, .true_ => return .{ .int_const = 1 },
        .neg_one => return .{ .int_const = -1 },
        _ => {},
    }
    const row = self.defs.get(@intFromEnum(value) - Value.first_dynamic);
    return switch (row.kind) {
        .undef => .undef,
        .float_const => .{ .float_const = @bitCast(row.payload) },
        .int_const => .{ .int_const = @bitCast(row.payload) },
        .str_const => .{ .str_const = self.stringOf(@enumFromInt(@as(u32, @truncate(row.payload)))) },
        .param_ref => .{ .param_ref = @truncate(row.payload) },
        .block_param => .{ .block_param = @truncate(row.payload) },
        .inst_result => .{ .inst_result = @enumFromInt(@as(u32, @truncate(row.payload))) },
    };
}

/// Cheap kind test without decoding the payload.
pub fn valueKind(self: *const Mir, value: Value) DefKind {
    return switch (self.valueDef(value)) {
        inline else => |_, tag| tag,
    };
}

// --------------------------------------------------------------- aliases ----

/// Record `from` ≡ `to` (ssa.zig trivial-phi removal). Idempotent overwrite.
/// `from` is always a dynamic Value (a phi result); `to` may be a sentinel.
pub fn setAlias(self: *Mir, from: Value, to: Value) void {
    assert(from != to); // a self-alias would make resolveAlias non-terminating
    assert(@intFromEnum(from) >= Value.first_dynamic);
    self.alias.items[@intFromEnum(from) - Value.first_dynamic] = to;
}

/// True if `value` was collapsed onto another (codegen skips its decl).
pub fn hasAlias(self: *const Mir, value: Value) bool {
    const i = @intFromEnum(value);
    if (i < Value.first_dynamic) return false;
    return self.alias.items[i - Value.first_dynamic] != value;
}

/// Follow the alias chain to the surviving Value. Union-find with path
/// compression, so a chain is walked at full length at most once.
///
/// `*const` but mutates `alias`: compression is pure memoization, the resolved
/// value is unchanged. Zig's const is shallow, so the slice pointee is writable.
pub fn resolveAlias(self: *const Mir, value: Value) Value {
    const fd = Value.first_dynamic;
    if (@intFromEnum(value) < fd) return value;
    const parent = self.alias.items;

    var root = value;
    var hops: usize = 0;
    while (@intFromEnum(root) >= fd) {
        const next = parent[@intFromEnum(root) - fd];
        if (next == root) break;
        root = next;
        hops += 1;
        assert(hops <= parent.len); // cycle ⇒ SSA bug
    }

    var v = value;
    while (v != root) {
        const next = parent[@intFromEnum(v) - fd];
        parent[@intFromEnum(v) - fd] = root;
        v = next;
    }
    return root;
}

// ---------------------------------------------------------------- blocks ----

pub fn addBlock(self: *Mir, gpa: std.mem.Allocator) !Block {
    const i = self.blocks.len;
    assert(i < std.math.maxInt(u32));
    try self.blocks.append(gpa, .{});
    return @enumFromInt(@as(u32, @intCast(i)));
}

pub fn blockCount(self: *const Mir) u32 {
    return @intCast(self.blocks.len);
}

pub const BlockIterator = struct {
    count: u32,
    i: u32 = 0,

    pub fn next(it: *BlockIterator) ?Block {
        if (it.i >= it.count) return null;
        defer it.i += 1;
        return @enumFromInt(it.i);
    }
};

/// Blocks in creation order — the deterministic codegen walk order.
pub fn blockIter(self: *const Mir) BlockIterator {
    return .{ .count = self.blockCount() };
}

pub const InstIterator = struct {
    /// Borrowed `next` column. Adding instructions invalidates it: iterate only
    /// after the block is built (codegen/proof are read-only passes).
    next_col: []const Inst,
    cur: Inst,

    pub fn next(it: *InstIterator) ?Inst {
        if (it.cur == .none) return null;
        const out = it.cur;
        it.cur = it.next_col[@intFromEnum(out)];
        return out;
    }
};

/// Instructions of `block`, in emission order (intrusive `next` chain).
pub fn blockInsts(self: *const Mir, block: Block) InstIterator {
    return .{
        .next_col = self.insts.items(.next),
        .cur = self.blocks.items(.first)[@intFromEnum(block)],
    };
}

// ---------------------------------------------------------- instructions ----

/// Append `row` to the end of `block` and link it in. Caller sets row.result
/// (use `emit` to get a fresh result Value automatically).
pub fn addInst(self: *Mir, gpa: std.mem.Allocator, block: Block, row: InstRow) !Inst {
    const i = self.insts.len;
    assert(i < std.math.maxInt(u32) - 1); // maxInt is Inst.none
    var stamped = row;
    stamped.tok = self.cur_tok; // provenance — see InstRow.tok and cur_tok
    try self.insts.append(gpa, stamped);
    const inst: Inst = @enumFromInt(@as(u32, @intCast(i)));

    const b = @intFromEnum(block);
    const last = self.blocks.items(.last)[b];
    if (last == .none) {
        self.blocks.items(.first)[b] = inst;
    } else {
        self.insts.items(.next)[@intFromEnum(last)] = inst;
    }
    self.blocks.items(.last)[b] = inst;
    return inst;
}

/// The workhorse: append a value-producing instruction and return its result.
/// `ops` is 1..3 operands (see InstRow's encoding table).
pub fn emit(self: *Mir, gpa: std.mem.Allocator, block: Block, op: Opcode, ops: []const Value) !Value {
    assert(ops.len >= 1 and ops.len <= 3);
    assert(switch (opClass(op)) {
        .unary => ops.len == 1,
        .binary => ops.len == 2,
        .ternary => ops.len == 3,
        else => false, // phi/branch/jump/call have dedicated builders
    });
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{
        .op = op,
        .a = @intFromEnum(ops[0]),
        .b = if (ops.len > 1) @intFromEnum(ops[1]) else 0,
        .c = if (ops.len > 2) @intFromEnum(ops[2]) else 0,
        .result = result,
    });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// LRM §5.8 two-way branch. Terminator; no result.
pub fn emitBranch(self: *Mir, gpa: std.mem.Allocator, block: Block, cond: Value, then_block: Block, else_block: Block) !Inst {
    return self.addInst(gpa, block, .{
        .op = .branch,
        .a = @intFromEnum(cond),
        .b = @intFromEnum(then_block),
        .c = @intFromEnum(else_block),
    });
}

/// LRM §5.9 unconditional jump. Terminator; no result.
pub fn emitJump(self: *Mir, gpa: std.mem.Allocator, block: Block, target: Block) !Inst {
    return self.addInst(gpa, block, .{ .op = .jump, .a = @intFromEnum(target) });
}

/// LRM §4.3/§4.5/§4.7/ch9 call by name (math builtin, analog operator, UDF,
/// system function). `callee` names it; codegen.emitCall dispatches on the name.
pub fn emitCall(self: *Mir, gpa: std.mem.Allocator, block: Block, callee: StrId, args: []const Value) !Value {
    const start = try self.addExtraValues(gpa, args);
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{
        .op = .call,
        .a = @intFromEnum(callee),
        .b = start,
        .c = @intCast(args.len),
        .result = result,
    });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// LRM §5.8/§5.9 phi. `pairs` may be empty for an incomplete phi (Braun);
/// fill it later with `setPhiPairs`.
pub fn emitPhi(self: *Mir, gpa: std.mem.Allocator, block: Block, pairs: []const PhiPair) !Value {
    const start = try self.addExtraPairs(gpa, pairs);
    const result = try self.addValue(gpa, .inst_result, 0);
    const inst = try self.addInst(gpa, block, .{
        .op = .phi,
        .b = start,
        .c = @intCast(pairs.len),
        .result = result,
    });
    self.defs.items(.payload)[@intFromEnum(result) - Value.first_dynamic] = @intFromEnum(inst);
    return result;
}

/// Replace a phi's operand list (Braun: sealBlock fills incomplete phis).
/// ponytail: appends a fresh region and abandons the old one — a few dead u32s
/// per filled phi. Compact the pool only if `extra` ever shows up in a profile.
pub fn setPhiPairs(self: *Mir, gpa: std.mem.Allocator, inst: Inst, pairs: []const PhiPair) !void {
    assert(self.insts.items(.op)[@intFromEnum(inst)] == .phi);
    const start = try self.addExtraPairs(gpa, pairs);
    self.insts.items(.b)[@intFromEnum(inst)] = start;
    self.insts.items(.c)[@intFromEnum(inst)] = @intCast(pairs.len);
}

pub fn instRow(self: *const Mir, inst: Inst) InstRow {
    return self.insts.get(@intFromEnum(inst));
}

/// Token this instruction was lowered from — the class-6 diagnostic location,
/// or `no_tok` when it has no AST origin.
pub fn instTok(self: *const Mir, inst: Inst) u32 {
    return self.insts.items(.tok)[@intFromEnum(inst)];
}

pub fn instOp(self: *const Mir, inst: Inst) Opcode {
    return self.insts.items(.op)[@intFromEnum(inst)];
}

/// The Value this instruction defines, or `.undef` for terminators.
pub fn instResult(self: *const Mir, inst: Inst) Value {
    return self.insts.items(.result)[@intFromEnum(inst)];
}

/// Decoded view of one instruction. Switch on the class, not on raw a/b/c.
pub fn instData(self: *const Mir, inst: Inst) InstData {
    const row = self.instRow(inst);
    return switch (opClass(row.op)) {
        .unary => .{ .unary = .{ .op = row.op, .operand = @enumFromInt(row.a) } },
        .binary => .{ .binary = .{
            .op = row.op,
            .lhs = @enumFromInt(row.a),
            .rhs = @enumFromInt(row.b),
        } },
        .ternary => .{ .ternary = .{
            .op = row.op,
            .cond = @enumFromInt(row.a),
            .then_val = @enumFromInt(row.b),
            .else_val = @enumFromInt(row.c),
        } },
        .phi => .{ .phi = .{ .start = row.b, .count = row.c } },
        .branch => .{ .branch = .{
            .cond = @enumFromInt(row.a),
            .then_block = @enumFromInt(row.b),
            .else_block = @enumFromInt(row.c),
        } },
        .jump => .{ .jump = .{ .target = @enumFromInt(row.a) } },
        .call => .{ .call = .{
            .callee = @enumFromInt(row.a),
            .name = self.stringOf(@enumFromInt(row.a)),
            .args = self.getExtraValues(row.b, row.c),
        } },
    };
}

/// Operand `i` of a phi (0..count-1 from `instData(...).phi`).
pub fn phiPair(self: *const Mir, inst: Inst, i: u32) PhiPair {
    const row = self.instRow(inst);
    assert(row.op == .phi and i < row.c);
    const at = row.b + i * 2;
    return .{
        .block = @enumFromInt(self.extra.items[at]),
        .value = @enumFromInt(self.extra.items[at + 1]),
    };
}

// ----------------------------------------------------------- extra pool ----

/// Append raw u32s; returns the start index. Prefer the typed wrappers.
pub fn addExtra(self: *Mir, gpa: std.mem.Allocator, words: []const u32) !u32 {
    const start = self.extra.items.len;
    assert(start < std.math.maxInt(u32));
    try self.extra.appendSlice(gpa, words);
    return @intCast(start);
}

pub fn addExtraValues(self: *Mir, gpa: std.mem.Allocator, values: []const Value) !u32 {
    return self.addExtra(gpa, @ptrCast(values));
}

pub fn addExtraPairs(self: *Mir, gpa: std.mem.Allocator, pairs: []const PhiPair) !u32 {
    const start = self.extra.items.len;
    assert(start < std.math.maxInt(u32));
    try self.extra.ensureUnusedCapacity(gpa, pairs.len * 2);
    for (pairs) |p| {
        self.extra.appendAssumeCapacity(@intFromEnum(p.block));
        self.extra.appendAssumeCapacity(@intFromEnum(p.value));
    }
    return @intCast(start);
}

/// Borrowed slice into the payload pool; invalidated by further appends.
pub fn getExtraValues(self: *const Mir, start: u32, len: u32) []const Value {
    return @ptrCast(self.extra.items[start..][0..len]);
}

// -------------------------------------------------------------------------

test "mir: const dedup, block chain, phi pairs, alias" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "diode" };
    defer mir.deinit(gpa);

    // sentinels + dedup (§4.2 constant expressions)
    try std.testing.expectEqual(Value.f_one, try mir.addFloatConst(gpa, 1.0));
    try std.testing.expectEqual(Value.zero, try mir.addIntConst(gpa, 0));
    const k = try mir.addFloatConst(gpa, 1.5);
    try std.testing.expectEqual(k, try mir.addFloatConst(gpa, 1.5));
    try std.testing.expectEqual(@as(f64, 1.5), mir.valueDef(k).float_const);
    // 0.0 and -0.0 are distinct bit patterns and must not collapse
    try std.testing.expect(try mir.addFloatConst(gpa, -0.0) != Value.f_zero);

    const entry = try mir.addBlock(gpa);
    const vd = try mir.addBlockParam(gpa, 0);
    const vs = try mir.addBlockParam(gpa, 1);
    const dv = try mir.emit(gpa, entry, .fsub, &.{ vd, vs });
    const id = try mir.emit(gpa, entry, .fmul, &.{ dv, k });
    try std.testing.expectEqual(@as(u32, 0), mir.valueDef(vd).block_param);

    // instruction chain + decoded view
    var it = mir.blockInsts(entry);
    const in0 = it.next().?;
    const in1 = it.next().?;
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(dv, mir.instResult(in0));
    try std.testing.expectEqual(id, mir.instResult(in1));
    try std.testing.expectEqual(vs, mir.instData(in0).binary.rhs);
    try std.testing.expectEqual(in1, mir.valueDef(id).inst_result);

    // call (§4.3): name + args round-trip through the extra pool
    const nm = try mir.internString(gpa, "exp");
    try std.testing.expectEqual(nm, try mir.internString(gpa, "exp")); // deduped
    const e = try mir.emitCall(gpa, entry, nm, &.{id});
    const cd = mir.instData(mir.valueDef(e).inst_result).call;
    try std.testing.expectEqualStrings("exp", cd.name);
    try std.testing.expectEqualSlices(Value, &.{id}, cd.args);

    // phi (§5.8): empty then filled, and trivial-phi aliasing
    const join = try mir.addBlock(gpa);
    const p = try mir.emitPhi(gpa, join, &.{});
    const pi = mir.valueDef(p).inst_result;
    try std.testing.expectEqual(@as(u32, 0), mir.instData(pi).phi.count);
    try mir.setPhiPairs(gpa, pi, &.{ .{ .block = entry, .value = id }, .{ .block = join, .value = e } });
    try std.testing.expectEqual(@as(u32, 2), mir.instData(pi).phi.count);
    try std.testing.expectEqual(e, mir.phiPair(pi, 1).value);

    mir.setAlias(p, e);
    try std.testing.expectEqual(e, mir.resolveAlias(p));
    try std.testing.expectEqual(id, mir.resolveAlias(id));

    var bi = mir.blockIter();
    try std.testing.expectEqual(Block.entry, bi.next().?);
    try std.testing.expectEqual(join, bi.next().?);
    try std.testing.expect(bi.next() == null);
}
