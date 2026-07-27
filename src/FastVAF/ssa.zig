//! Class 4 — SSA construction (Braun et al., "Simple and Efficient Construction
//! of Static Single Assignment Form"). Serves LRM §5 control flow: §5.8
//! conditionals, §5.9 loops, variable reads/writes across blocks.
//!
//! Transformation: per-block writes/reads → SSA Values with phi nodes.
//!
//! DOD:
//!   - defs: DENSE matrix (place, block) → Value. It was a sparse hash map on the
//!     theory that most pairs are undefined; measured, they are not (19% of cells
//!     live on hisimhv_va, ~100% on small modules) and the hash table was the
//!     single hottest thing in the frontend. See `SsaBuilder.defs`.
//!   - per-block state (sealed?, preds, incomplete phis) in a MultiArrayList row
//!     indexed by Block; the pred and incomplete-phi lists are intrusive u32
//!     indices into two flat pools, not one allocation per block.
//!   - trivial-phi removal aliases a phi to its single value (Mir.alias, so
//!     codegen never emits a `var` for it).
//!
//! CONTRACT FOR CONSUMERS (proof.zig, codegen.zig):
//!   1. Every Value read out of the MIR MUST be passed through `mir.resolveAlias`
//!      before use. A collapsed phi is never rewritten in its users' operand
//!      lists — the alias table IS the rewrite. `resolveAlias(v) != v` means the
//!      phi is dead: emit no declaration for it.
//!   2. Phi instructions are created ON DEMAND, so a `.phi` row can sit anywhere
//!      in its block's instruction chain — including after the terminator.
//!      Codegen must treat `.phi` as a block header: skip it in the linear walk
//!      and materialize it as a mutable local assigned at the end of each
//!      predecessor (the standard SSA-out-of-form move). Never emit a phi row
//!      in place.

const std = @import("std");
const Mir = @import("mir.zig");
const assert = std.debug.assert;

/// Every failure in this file is an allocation failure. Spelled out (not
/// inferred) because readVariable ⇄ readVariableRecursive ⇄ addPhiOperands are
/// mutually recursive.
const Error = std.mem.Allocator.Error;

/// A "place" is an assignable location (a variable or a lowered temp).
pub const Place = enum(u32) { _ };

/// End-of-list sentinel for the intrusive pools. Not 0: index 0 is a real slot.
const list_end: u32 = std.math.maxInt(u32);

/// "No definition recorded for this (place, block)" in the `defs` matrix.
///
/// It CANNOT be `Mir.Value.undef`: that is a legitimate stored result (a phi
/// over only self-references collapses to `undef`, see `tryRemoveTrivialPhi`),
/// and conflating "never written" with "written as undefined" would re-run the
/// recursive read on every access and re-create the collapsed phi. `Value` is a
/// non-exhaustive `enum(u32)` allocated sequentially from 12, so the top of the
/// range is unreachable without 4 G values — asserted in `writeVariable`.
const absent: Mir.Value = @enumFromInt(std.math.maxInt(u32));

pub const SsaBuilder = struct {
    gpa: std.mem.Allocator,
    mir: *Mir,
    /// (place, block) → Value, as a DENSE PLACE-MAJOR matrix:
    /// `defs[place * block_stride + block]`, `absent` where unwritten.
    ///
    /// DOD: this was a `HashMap<u64=(place<<32|block), Value>` justified as
    /// "sparse by construction". Measured, it is not sparse — on `hisimhv_va` it
    /// holds 2,114,902 live entries over 1978 places × 5646 blocks = 11.2 M cells
    /// (19% dense, ~100% on small modules), and the hash table's own 4.19 M-slot
    /// allocation was already LARGER than the live matrix. Hashing, probing and
    /// rehashing were ~35% of frontend runtime, `grow` alone 9.2%; a matrix index
    /// is a multiply-add. Measured end to end: frontend 1.33–1.58× faster.
    ///
    /// The cost is real and was measured too: both axes round up to a power of
    /// two, so 1978 × 5646 live cells occupy 2048 × 8192 = 67 MB against the hash
    /// map's 54 MB, and peak RSS is ~8% higher on three of four foundry models.
    /// That trade was taken deliberately. Two alternatives were measured and are
    /// WORSE, so do not "fix" this by reaching for either:
    ///   - growing the block axis to `mir.blockCount()` instead of doubling
    ///     re-strides more often, and a re-stride holds the old and new buffer at
    ///     once — peak RSS went UP (hisim2_va 155 → 194 MB).
    ///   - block-major with rows appended exactly re-allocates once per block,
    ///     which is quadratic: 4.6 GB and 4× SLOWER.
    ///
    /// PLACE-MAJOR is load-bearing: the hot recursion (`readVariableRecursive` →
    /// `addPhiOperands`) walks predecessor BLOCKS for ONE fixed place, so
    /// consecutive probes land in adjacent cells.
    defs: []Mir.Value = &.{},
    /// Row length of `defs` — capacity along the block axis, not the live count.
    block_stride: u32 = 0,
    /// Rows allocated in `defs` — capacity along the place axis.
    place_cap: u32 = 0,
    /// Row per Mir.Block, grown lazily (lower.zig owns block creation).
    block_state: std.MultiArrayList(BlockState) = .empty,
    /// Flat pools; BlockState holds head/tail indices into them.
    pred_pool: std.ArrayList(PredNode) = .empty,
    incomplete_pool: std.ArrayList(IncompletePhi) = .empty,
    /// Phi def-use edges: for a Value, the phis that name it as an operand.
    /// Intrusive list like pred_pool; `user_head` is a dense array parallel to
    /// `Mir.defs` (index = value - first_dynamic), `list_end` = no users.
    /// Only the trivial-phi re-check reads it.
    user_pool: std.ArrayList(UserNode) = .empty,
    user_head: std.ArrayList(u32) = .empty,
    /// Shared phi-operand scratch, used with stack discipline (save length,
    /// restore on exit) so re-entrant lowering needs no per-phi allocation.
    scratch: std.ArrayList(Mir.PhiPair) = .empty,
    /// Trivial-phi worklist, driven with the same save/restore discipline as
    /// `scratch`. A second list rather than a reuse of `scratch` only because the
    /// element type differs.
    phi_work: std.ArrayList(Mir.Value) = .empty,
    next_place: u32 = 0,

    pub const BlockState = struct {
        /// Braun: sealed ⇒ this block's predecessor set is final.
        sealed: bool = false,
        preds_head: u32 = list_end,
        preds_tail: u32 = list_end,
        /// Kept beside the list so `readVariableRecursive`'s `predCount(b) == 1`
        /// test is a load, not a walk. Same reason AIR stores `body_len` next to
        /// its trailing instruction list instead of terminating it.
        preds_len: u32 = 0,
        /// Phis created before the block was sealed; filled by `sealBlock`.
        phis_head: u32 = list_end,
    };

    const PredNode = struct { block: Mir.Block, next: u32 };
    const IncompletePhi = struct { place: Place, value: Mir.Value, next: u32 };
    const UserNode = struct { phi: Mir.Value, next: u32 };

    pub fn init(gpa: std.mem.Allocator, mir: *Mir) SsaBuilder {
        return .{ .gpa = gpa, .mir = mir };
    }

    /// Frees builder scratch only; the MIR it wrote into is untouched.
    pub fn deinit(self: *SsaBuilder) void {
        self.gpa.free(self.defs);
        self.block_state.deinit(self.gpa);
        self.pred_pool.deinit(self.gpa);
        self.incomplete_pool.deinit(self.gpa);
        self.user_pool.deinit(self.gpa);
        self.user_head.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.phi_work.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa, .mir = self.mir };
    }

    /// Fresh assignable location (LRM §3.4.4 variable, or a lowered temporary).
    pub fn newPlace(self: *SsaBuilder) Place {
        defer self.next_place += 1;
        return @enumFromInt(self.next_place);
    }

    // ------------------------------------------------------------- CFG edges --

    /// Declare `pred → block` in the CFG. MUST be called before `sealBlock(block)`;
    /// lower.zig calls it wherever it emits a jump/branch (§5.8, §5.9).
    pub fn addPredecessor(self: *SsaBuilder, block: Mir.Block, pred: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        assert(!self.block_state.items(.sealed)[b]); // preds are final once sealed
        _ = try self.ensureState(pred);

        const node: u32 = @intCast(self.pred_pool.items.len);
        try self.pred_pool.append(self.gpa, .{ .block = pred, .next = list_end });
        const tail = self.block_state.items(.preds_tail)[b];
        if (tail == list_end) {
            self.block_state.items(.preds_head)[b] = node;
        } else {
            self.pred_pool.items[tail].next = node;
        }
        self.block_state.items(.preds_tail)[b] = node;
        self.block_state.items(.preds_len)[b] += 1;
    }

    /// Mark a block's predecessors final and fill every incomplete phi.
    /// Braun §sealBlock. Idempotent.
    pub fn sealBlock(self: *SsaBuilder, block: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        if (self.block_state.items(.sealed)[b]) return;
        // Seal FIRST: a recursive read that comes back here while we fill must
        // take the (now final) predecessor path instead of queueing another
        // incomplete phi onto the list we are walking.
        self.block_state.items(.sealed)[b] = true;

        var node = self.block_state.items(.phis_head)[b];
        self.block_state.items(.phis_head)[b] = list_end;
        while (node != list_end) {
            const rec = self.incomplete_pool.items[node]; // copy: recursion may realloc
            node = rec.next;
            _ = try self.addPhiOperands(rec.place, rec.value, block);
        }
    }

    // ------------------------------------------------------- read / write --

    /// Record `place := value` in `block`. LRM §5.7 assignment.
    pub fn writeVariable(self: *SsaBuilder, place: Place, block: Mir.Block, value: Mir.Value) Error!void {
        assert(value != absent); // see `absent`: the Value space never reaches maxInt
        const i = try self.defsIndex(place, block);
        self.defs[i] = value;
    }

    /// Read `place` in `block`, inserting phis as needed. Braun §readVariable.
    /// Reading a place that is undefined on some path yields `.undef` there —
    /// initializing declared variables (§3.4.4) is lower.zig's job, not ours.
    pub fn readVariable(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        if (self.defsPeek(place, block)) |v| return v;
        return self.readVariableRecursive(place, block);
    }

    /// Load without growing: an unallocated cell reads as absent, exactly like an
    /// allocated-but-unwritten one. Keeps the read path free of the resize branch.
    fn defsPeek(self: *const SsaBuilder, place: Place, block: Mir.Block) ?Mir.Value {
        const p = @intFromEnum(place);
        const b = @intFromEnum(block);
        if (p >= self.place_cap or b >= self.block_stride) return null;
        const v = self.defs[p * self.block_stride + b];
        return if (v == absent) null else v;
    }

    /// Index of (place, block), growing the matrix to cover it.
    ///
    /// BOTH axes grow geometrically. Widening the block axis re-strides every row;
    /// adding a place appends rows and moves nothing, but growing it exactly would
    /// still re-allocate per place. Exact growth on either axis is quadratic — it
    /// was measured on the block axis at 4.6 GB and 4× slower.
    fn defsIndex(self: *SsaBuilder, place: Place, block: Mir.Block) Error!u32 {
        const p = @intFromEnum(place);
        const b = @intFromEnum(block);

        if (b >= self.block_stride) {
            const new_stride = @max(b + 1, @max(self.block_stride * 2, 16));
            const new_cap = @max(self.place_cap, 1);
            const grown = try self.gpa.alloc(Mir.Value, @as(usize, new_cap) * new_stride);
            @memset(grown, absent);
            // Re-stride: copy each old row to the front of its wider slot.
            var row: u32 = 0;
            while (row < self.place_cap) : (row += 1) {
                const src = self.defs[row * self.block_stride ..][0..self.block_stride];
                @memcpy(grown[row * new_stride ..][0..self.block_stride], src);
            }
            self.gpa.free(self.defs);
            self.defs = grown;
            self.block_stride = new_stride;
            self.place_cap = new_cap;
        }
        if (p >= self.place_cap) {
            const new_cap = @max(p + 1, @max(self.place_cap * 2, 16));
            const grown = try self.gpa.realloc(self.defs, @as(usize, new_cap) * self.block_stride);
            @memset(grown[@as(usize, self.place_cap) * self.block_stride ..], absent);
            self.defs = grown;
            self.place_cap = new_cap;
        }
        return p * self.block_stride + b;
    }

    /// Braun §readVariableRecursive. Every path memoizes its result with
    /// `writeVariable`, which is also what breaks cycles on the loop path.
    ///
    /// ponytail: still recursive, and its depth is a CFG chain length (the
    /// single-predecessor arm below), not a nesting depth — the same unbounded
    /// shape `tryRemoveTrivialPhi` was just converted out of. Ceiling: one stack
    /// frame per block on the first read of a place, so ~10⁵ sequential `if`s in
    /// one module would blow the stack. All 36 foundry models are far under it.
    /// The fix is an explicit stack with a resume state, since the ≥2-preds arm
    /// has real post-recursion work; see PERF.md "Known-good next moves".
    fn readVariableRecursive(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        const b = try self.ensureState(block);

        var val: Mir.Value = undefined;
        if (!self.block_state.items(.sealed)[b]) {
            // Preds not final yet (loop header, §5.9): incomplete phi, filled by sealBlock.
            val = try self.newPhi(block);
            try self.pushIncomplete(block, place, val);
        } else if (self.predCount(block) == 1) {
            val = try self.readVariable(place, self.firstPred(block));
        } else {
            // ≥2 preds (or 0 — an undefined read in a source-less block).
            val = try self.newPhi(block);
            try self.writeVariable(place, block, val); // break cycles before recursing
            val = try self.addPhiOperands(place, val, block);
        }
        try self.writeVariable(place, block, val);
        return val;
    }

    /// Braun §addPhiOperands: one operand per predecessor edge, then collapse.
    fn addPhiOperands(self: *SsaBuilder, place: Place, phi: Mir.Value, block: Mir.Block) Error!Mir.Value {
        // One shared scratch used as a stack: this is re-entrant (readVariable
        // recurses back in), and a fresh list per phi was an allocation per phi.
        const top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(top);

        var node = self.predsHead(block);
        while (node != list_end) {
            const pred = self.pred_pool.items[node]; // copy: recursion may realloc
            node = pred.next;
            const v = try self.readVariable(place, pred.block);
            try self.scratch.append(self.gpa, .{ .block = pred.block, .value = v });
        }
        const pairs = self.scratch.items[top..];
        try self.mir.setPhiPairs(self.gpa, self.mir.valueDef(phi).inst_result, pairs);
        for (pairs) |p| try self.addUser(p.value, phi);
        return self.tryRemoveTrivialPhi(phi);
    }

    /// Collapse a phi whose operands all resolve to one value (self-references
    /// ignored) to that value. Braun §tryRemoveTrivialPhi.
    ///
    /// "Rerouting users" is done by ALIASING rather than rewriting: the operand
    /// lists keep pointing at the dead phi and every consumer resolves through
    /// `Mir.resolveAlias`. Dependent phis are then re-checked.
    ///
    /// EXPLICIT WORKLIST, not recursion. Braun states this recursively and every
    /// textbook port copies that, but the recursion is over the phi DEF-USE
    /// graph, so its depth is bounded by nothing syntactic — a 600 K-line foundry
    /// model chains phis far deeper than it nests anything. Every recursion in
    /// the Zig compiler's equivalents is nesting-bounded (AstGen walks the tree,
    /// Liveness walks bodies), so the analogue here is codegen.zig's dominator
    /// Euler tour, which is an explicit stack for exactly this reason. This is a
    /// stack-overflow fix, NOT a speed fix: no measurable time change.
    ///
    /// EQUIVALENCE with the recursive form — the return value is load-bearing
    /// (`addPhiOperands` hands it back as the value of the phi), and a worklist
    /// drains in a different order than a call stack, so both halves matter:
    ///   - RETURN. The recursion fixes `repl` for the root BEFORE it descends
    ///     into the root's users, and returns that same `repl` afterwards; every
    ///     recursive call's result is discarded (`_ =`). So capturing the first
    ///     iteration's result and then draining the worklist returns the same
    ///     Value, whatever the drain order is.
    ///   - ORDER. It is preserved anyway, which is what keeps the alias table —
    ///     and therefore the generated bytes — identical. Users are appended in
    ///     list order and then reversed, so the LIFO pops them head→tail, and a
    ///     popped phi's own users land on top and drain before its remaining
    ///     siblings: exactly the recursion's pre-order DFS. The `hasAlias` skip is
    ///     applied at POP time, not push time, because the recursion re-tests it
    ///     only after the previous sibling's whole subtree has run. (The
    ///     recursion's extra `u.phi == phi` skip is subsumed: `phi` was just
    ///     aliased, so `hasAlias` already rejects it.) Snapshotting a user list is
    ///     safe because nothing on this path calls `addUser`, so `user_pool`
    ///     cannot grow or move mid-walk.
    ///
    /// TERMINATION: entries are pushed only by the branch that just called
    /// `Mir.setAlias`, `setAlias` is monotonic (an alias is never cleared), and a
    /// popped phi that `hasAlias` is dropped. So each phi pushes its users at most
    /// once and total pushes are bounded by `user_pool.len`.
    pub fn tryRemoveTrivialPhi(self: *SsaBuilder, phi: Mir.Value) Error!Mir.Value {
        // Stack discipline like `scratch`: this runs under re-entrant lowering.
        const top = self.phi_work.items.len;
        defer self.phi_work.shrinkRetainingCapacity(top);

        var root_repl: ?Mir.Value = null;
        var cur = phi; // the root is processed unconditionally, as in the recursion
        while (true) {
            const inst = self.mir.valueDef(cur).inst_result;
            assert(self.mir.instOp(inst) == .phi);

            var same: ?Mir.Value = null;
            const count = self.mir.instData(inst).phi.count;
            var i: u32 = 0;
            const repl = while (i < count) : (i += 1) {
                const op = self.mir.resolveAlias(self.mir.phiPair(inst, i).value);
                if (op == cur) continue; // self-reference (loop back edge)
                if (same) |s| {
                    if (op == s) continue;
                    break cur; // merges ≥2 distinct values ⇒ a real phi
                }
                same = op;
            } else same orelse Mir.Value.undef; // no operands / only self-refs ⇒ undefined

            if (repl != cur) {
                self.mir.setAlias(cur, repl);
                // Queue only the phis that named `cur` as an operand: they may now
                // be trivial. Walking every phi here was 97% of runtime on
                // bsimsoi_va.
                const mark = self.phi_work.items.len;
                var node = self.userHead(cur);
                while (node != list_end) {
                    const u = self.user_pool.items[node];
                    node = u.next;
                    try self.phi_work.append(self.gpa, u.phi);
                }
                // ponytail: append-then-reverse, because `user_pool` is singly
                // linked and cannot be walked backwards. Ceiling is one extra
                // pass over one phi's users; if that ever shows up in a profile
                // the fix is a tail pointer per value, not a smarter reversal.
                std.mem.reverse(Mir.Value, self.phi_work.items[mark..]);
            }
            if (root_repl == null) root_repl = repl;

            cur = while (self.phi_work.items.len > top) {
                const u = self.phi_work.pop().?;
                if (!self.mir.hasAlias(u)) break u;
            } else return root_repl.?;
        }
    }

    // ---------------------------------------------------------- internals --

    fn ensureState(self: *SsaBuilder, block: Mir.Block) Error!u32 {
        const i = @intFromEnum(block);
        assert(i < self.mir.blockCount());
        while (self.block_state.len <= i) try self.block_state.append(self.gpa, .{});
        return i;
    }

    fn newPhi(self: *SsaBuilder, block: Mir.Block) Error!Mir.Value {
        return self.mir.emitPhi(self.gpa, block, &.{});
    }

    /// Record "`user` (a phi) reads `value`". Sentinels never collapse, so they
    /// get no list.
    fn addUser(self: *SsaBuilder, value: Mir.Value, user: Mir.Value) Error!void {
        const i = @intFromEnum(value);
        if (i < Mir.Value.first_dynamic) return;
        const slot = i - Mir.Value.first_dynamic;
        while (self.user_head.items.len <= slot) try self.user_head.append(self.gpa, list_end);
        const node: u32 = @intCast(self.user_pool.items.len);
        try self.user_pool.append(self.gpa, .{ .phi = user, .next = self.user_head.items[slot] });
        self.user_head.items[slot] = node;
    }

    fn userHead(self: *const SsaBuilder, value: Mir.Value) u32 {
        const i = @intFromEnum(value);
        if (i < Mir.Value.first_dynamic) return list_end;
        const slot = i - Mir.Value.first_dynamic;
        if (slot >= self.user_head.items.len) return list_end;
        return self.user_head.items[slot];
    }

    fn pushIncomplete(self: *SsaBuilder, block: Mir.Block, place: Place, value: Mir.Value) Error!void {
        const b = @intFromEnum(block);
        const node: u32 = @intCast(self.incomplete_pool.items.len);
        try self.incomplete_pool.append(self.gpa, .{
            .place = place,
            .value = value,
            .next = self.block_state.items(.phis_head)[b],
        });
        self.block_state.items(.phis_head)[b] = node;
    }

    fn predsHead(self: *const SsaBuilder, block: Mir.Block) u32 {
        const b = @intFromEnum(block);
        if (b >= self.block_state.len) return list_end;
        return self.block_state.items(.preds_head)[b];
    }

    fn predCount(self: *const SsaBuilder, block: Mir.Block) u32 {
        const b = @intFromEnum(block);
        if (b >= self.block_state.len) return 0;
        return self.block_state.items(.preds_len)[b];
    }

    fn firstPred(self: *const SsaBuilder, block: Mir.Block) Mir.Block {
        const head = self.predsHead(block);
        assert(head != list_end);
        return self.pred_pool.items[head].block;
    }
};

// -------------------------------------------------------------------------

test "ssa: diamond phi, trivial collapse, loop phi, undefined read" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_selfcheck" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    //        entry
    //        /   \
    //     then   else       (LRM §5.8 conditional)
    //        \   /
    //         join
    const entry = try mir.addBlock(gpa);
    const then_b = try mir.addBlock(gpa);
    const else_b = try mir.addBlock(gpa);
    const join = try mir.addBlock(gpa);

    try b.sealBlock(entry); // no predecessors
    try b.addPredecessor(then_b, entry);
    try b.addPredecessor(else_b, entry);
    try b.sealBlock(then_b);
    try b.sealBlock(else_b);
    try b.addPredecessor(join, then_b);
    try b.addPredecessor(join, else_b);
    try b.sealBlock(join);

    const x = b.newPlace();
    const y = b.newPlace();
    const c1 = try mir.addFloatConst(gpa, 1.0);
    const c2 = try mir.addFloatConst(gpa, 2.0);
    const y0 = try mir.addFloatConst(gpa, 7.0);

    try b.writeVariable(y, entry, y0);
    try b.writeVariable(x, then_b, c1);
    try b.writeVariable(x, else_b, c2);

    // x differs per arm ⇒ a real phi, operands in predecessor-declaration order.
    const xj = try b.readVariable(x, join);
    try std.testing.expectEqual(xj, mir.resolveAlias(xj));
    const x_inst = mir.valueDef(xj).inst_result;
    try std.testing.expectEqual(Mir.Opcode.phi, mir.instOp(x_inst));
    try std.testing.expectEqual(@as(u32, 2), mir.instData(x_inst).phi.count);
    try std.testing.expectEqual(c1, mir.phiPair(x_inst, 0).value);
    try std.testing.expectEqual(then_b, mir.phiPair(x_inst, 0).block);
    try std.testing.expectEqual(c2, mir.phiPair(x_inst, 1).value);

    // y is the same on both arms ⇒ its join phi is trivial and collapses to y0.
    const yj = try b.readVariable(y, join);
    try std.testing.expectEqual(y0, mir.resolveAlias(yj));

    // Reading x again is memoized, not a second phi.
    try std.testing.expectEqual(xj, try b.readVariable(x, join));

    //   join → header ⇄ body        (LRM §5.9 loop: header sealed only after the
    //             ↘ exit             back edge exists)
    const header = try mir.addBlock(gpa);
    const body = try mir.addBlock(gpa);

    const i_pl = b.newPlace();
    const i_init = try mir.addIntConst(gpa, 0);
    try b.writeVariable(i_pl, join, i_init);

    try b.addPredecessor(header, join);
    try b.addPredecessor(body, header);
    try b.sealBlock(body);

    // Read before the header is sealed ⇒ INCOMPLETE phi in the header.
    const iv = try b.readVariable(i_pl, body);
    const i_inst = mir.valueDef(iv).inst_result;
    try std.testing.expectEqual(Mir.Opcode.phi, mir.instOp(i_inst));
    try std.testing.expectEqual(@as(u32, 0), mir.instData(i_inst).phi.count);

    const i_next = try mir.emit(gpa, body, .iadd, &.{ iv, .one });
    try b.writeVariable(i_pl, body, i_next);
    const yb = try b.readVariable(y, body); // loop-invariant ⇒ trivial header phi

    try b.addPredecessor(header, body); // back edge
    try b.sealBlock(header);

    // The induction variable's phi is real: {join: 0, body: i+1}.
    try std.testing.expectEqual(iv, mir.resolveAlias(iv));
    try std.testing.expectEqual(@as(u32, 2), mir.instData(i_inst).phi.count);
    try std.testing.expectEqual(i_init, mir.phiPair(i_inst, 0).value);
    try std.testing.expectEqual(join, mir.phiPair(i_inst, 0).block);
    try std.testing.expectEqual(i_next, mir.phiPair(i_inst, 1).value);
    try std.testing.expectEqual(body, mir.phiPair(i_inst, 1).block);

    // y's header phi is {join: <collapsed join phi>, body: itself} ⇒ collapses,
    // transitively through the already-aliased join phi, all the way to y0.
    try std.testing.expect(yb != y0);
    try std.testing.expectEqual(y0, mir.resolveAlias(yb));

    // Never written anywhere ⇒ undef, not a live phi.
    const z = b.newPlace();
    try std.testing.expectEqual(Mir.Value.undef, mir.resolveAlias(try b.readVariable(z, join)));
}
