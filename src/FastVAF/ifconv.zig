//! If-conversion: a CFG diamond whose arms are pure becomes a `select`.
//!
//! Transformation: MIR blocks → MIR blocks, with `branch`/`jump` diamonds
//! replaced by `select` instructions and the merge's phis aliased onto them.
//!
//! WHY THIS IS SAFE, which is the whole design. §4.2.12 requires the value-form
//! conditional to stay LAZY — `x > 0 ? ln(x) : 0` must not evaluate `ln(x)` with
//! x <= 0, which is UB under `@setFloatMode(.optimized)`. Predicating a branch
//! into "compute both arms, then pick" would break exactly that, and
//! `codegen.renderInst` carries a comment forbidding it.
//!
//! This pass does NOT predicate. It rewrites the diamond into a `select`, and
//! codegen renders a `select` as a Zig `if` EXPRESSION — `(if (c) a else b)` —
//! which is lazy. The arms stay unevaluated on the path not taken. The existing
//! use-counting is what enforces it: a value used only in a select arm scores
//! `arm_use`, never `eager_use`, and the inline sweep in `analyzeUnitOnce` then
//! renders it inside the arm rather than as a statement before the select. So
//! the precondition below — every value an arm defines is used only by the
//! merge's phis — is not a nicety, it is what keeps the guard intact.
//!
//! It also HELPS the prover: `proof.zig` treats a select's condition as a guard
//! scoped to its arms (`evalInst`, §4.2.12), so a domain that was only provable
//! under the branch stays provable after conversion.

const std = @import("std");
const Mir = @import("mir.zig");

/// What a scan found, so the transform can be sized before it is trusted.
pub const Stats = struct {
    branches: u32 = 0,
    /// Rejected, by cause — each is a reason a diamond is not convertible.
    not_diamond: u32 = 0,
    arm_impure: u32 = 0,
    arm_escapes: u32 = 0,
    merge_shared: u32 = 0,
    convertible: u32 = 0,
    phis_selected: u32 = 0,
};

/// `.call` is an analog operator or ch9 function: §4.5.2 says it is evaluated
/// once per step regardless of which arm runs, so it cannot move into an arm.
/// `.phi` in an arm would need its own merge. Everything else MIR can produce
/// in a straight-line block is a pure value computation.
fn pureOp(op: Mir.Opcode) bool {
    return switch (op) {
        .call, .phi, .opt_barrier => false,
        else => true,
    };
}

fn terminatorOf(mir: *const Mir, b: Mir.Block) ?Mir.Inst {
    var last: ?Mir.Inst = null;
    var it = mir.blockInsts(b);
    while (it.next()) |i| last = i;
    return last;
}

/// Count how many predecessors each block has, from the terminators alone.
fn predCounts(gpa: std.mem.Allocator, mir: *const Mir) ![]u32 {
    const n = mir.blockCount();
    const out = try gpa.alloc(u32, n);
    @memset(out, 0);
    for (0..n) |bi| {
        const t = terminatorOf(mir, @enumFromInt(@as(u32, @intCast(bi)))) orelse continue;
        switch (mir.instData(t)) {
            .branch => |d| {
                out[@intFromEnum(d.then_block)] += 1;
                out[@intFromEnum(d.else_block)] += 1;
            },
            .jump => |d| out[@intFromEnum(d.target)] += 1,
            else => {},
        }
    }
    return out;
}

/// An arm of a candidate diamond: single-predecessor, pure, and jumping to the
/// merge. `.empty` is the triangle case (`if` with no `else`), where the arm
/// edge goes straight to the merge and carries the value defined before the
/// branch.
const Arm = union(enum) {
    empty,
    block: Mir.Block,
};

fn classifyArm(mir: *const Mir, b: Mir.Block, merge: ?Mir.Block, preds: []const u32, st: *Stats) ?struct { arm: Arm, merge: Mir.Block } {
    if (merge) |m| if (b == m) return .{ .arm = .empty, .merge = m };
    if (preds[@intFromEnum(b)] != 1) {
        st.not_diamond += 1;
        return null;
    }
    const t = terminatorOf(mir, b) orelse return null;
    const jump = switch (mir.instData(t)) {
        .jump => |d| d.target,
        else => {
            st.not_diamond += 1;
            return null;
        },
    };
    var it = mir.blockInsts(b);
    while (it.next()) |i| {
        if (i == t) continue;
        if (!pureOp(mir.instOp(i))) {
            st.arm_impure += 1;
            return null;
        }
    }
    return .{ .arm = .{ .block = b }, .merge = jump };
}

/// Every value an arm defines must be used ONLY inside that arm or by a phi of
/// the merge — see the laziness argument in the file comment. Anything else
/// would be read on a path where the guard does not hold.
fn armEscapes(gpa: std.mem.Allocator, mir: *const Mir, arm: Mir.Block, merge: Mir.Block) !bool {
    var defined: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty;
    defer defined.deinit(gpa);
    var it = mir.blockInsts(arm);
    while (it.next()) |i| {
        const r = mir.instResult(i);
        if (r != .undef) try defined.put(gpa, mir.resolveAlias(r), {});
    }
    if (defined.count() == 0) return false;

    for (0..mir.blockCount()) |bi| {
        const b: Mir.Block = @enumFromInt(@as(u32, @intCast(bi)));
        if (b == arm) continue;
        var jt = mir.blockInsts(b);
        while (jt.next()) |i| {
            const op = mir.instOp(i);
            // A phi of the merge reading the arm's value is the point of the
            // exercise; any other reader is an escape.
            if (b == merge and op == .phi) continue;
            var buf: [3]Mir.Value = undefined;
            for (operandsOf(mir, i, &buf)) |o| {
                if (defined.contains(mir.resolveAlias(o))) return true;
            }
            if (op == .phi) {
                const d = mir.instData(i).phi;
                var k: u32 = 0;
                while (k < d.count) : (k += 1) {
                    if (defined.contains(mir.resolveAlias(mir.phiPair(i, k).value))) return true;
                }
            }
        }
    }
    return false;
}

fn operandsOf(mir: *const Mir, inst: Mir.Inst, buf: *[3]Mir.Value) []const Mir.Value {
    return switch (mir.instData(inst)) {
        .unary => |d| blk: {
            buf[0] = d.operand;
            break :blk buf[0..1];
        },
        .binary => |d| blk: {
            buf[0] = d.lhs;
            buf[1] = d.rhs;
            break :blk buf[0..2];
        },
        .ternary => |d| blk: {
            buf[0] = d.cond;
            buf[1] = d.then_val;
            buf[2] = d.else_val;
            break :blk buf[0..3];
        },
        .branch => |d| blk: {
            buf[0] = d.cond;
            break :blk buf[0..1];
        },
        .call => |c| c.args,
        .jump, .phi => buf[0..0],
    };
}

/// Scan only — reports what WOULD convert. Kept as its own entry point because
/// the transform is worth writing only if this says so on real models.
pub fn scan(gpa: std.mem.Allocator, mir: *const Mir) !Stats {
    var st: Stats = .{};
    const preds = try predCounts(gpa, mir);
    defer gpa.free(preds);

    for (0..mir.blockCount()) |bi| {
        const x: Mir.Block = @enumFromInt(@as(u32, @intCast(bi)));
        const t = terminatorOf(mir, x) orelse continue;
        const br = switch (mir.instData(t)) {
            .branch => |d| d,
            else => continue,
        };
        st.branches += 1;
        if (br.then_block == br.else_block) {
            st.not_diamond += 1;
            continue;
        }

        const a = classifyArm(mir, br.then_block, null, preds, &st) orelse continue;
        const b = classifyArm(mir, br.else_block, a.merge, preds, &st) orelse continue;
        if (b.merge != a.merge) {
            st.not_diamond += 1;
            continue;
        }
        const merge = a.merge;
        // The merge must be reached from THIS diamond and nowhere else, or its
        // phis carry values from a third edge and do not reduce to one select.
        if (preds[@intFromEnum(merge)] != 2) {
            st.merge_shared += 1;
            continue;
        }

        var escapes = false;
        inline for (.{ a.arm, b.arm }) |arm| switch (arm) {
            .empty => {},
            .block => |blk| {
                if (!escapes and try armEscapes(gpa, mir, blk, merge)) escapes = true;
            },
        };
        if (escapes) {
            st.arm_escapes += 1;
            continue;
        }

        st.convertible += 1;
        var it = mir.blockInsts(merge);
        while (it.next()) |i| {
            if (mir.instOp(i) == .phi) st.phis_selected += 1;
        }
    }
    return st;
}
