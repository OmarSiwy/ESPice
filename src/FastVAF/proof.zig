//! Class 6 — Numerical safety / finiteness proof pass.
//!
//! LRM basis: §4.3.1/§4.3.2 math-function domains (Tables 4-14/4-15), §4.3.2
//! "input outside the valid range shall report an error", §3.4.2 parameter
//! value ranges, §3.6.1.2 nature tolerances, §4.5.15 operator restrictions,
//! §5.8.4 conditional restrictions.
//!
//! Transformation: MIR + Lower side tables → per-unit float-mode verdict, OR a
//! compile error for a provably-unsafe domain violation.
//!
//! CONTRACT (see docs/architecture/03-codegen.html#finiteness):
//!   - Runs on EVERY target (lint/debug/release). Debug and Release accept the
//!     exact same set of models — no mode-specific semantics. Nothing in this
//!     file reads a target.
//!   - NO runtime domain checks are emitted anywhere. Proof-or-error only. This
//!     is what keeps the Release eval branch-free and vectorizable (eval_batch).
//!   - FastVAF is SPEC-FAITHFUL: `exp` (domain "All x", §4.3.2) is NEVER
//!     rejected — the LRM permits inf and makes `limexp` (§4.5.13) optional.
//!     Unprovable-finite units simply get `.strict` (below), not a rejection.
//!   - The engine NEVER inserts a clamp, a floor or a `limexp`.
//!   - DOMAIN CHECKS ARE THREE-WAY, not two (LRM §4.3.2 obliges reporting a
//!     value that IS out of range, not rejecting a program whose values MIGHT
//!     be):
//!         provably OUTSIDE  -> compile error
//!         provably INSIDE   -> ok, `.optimized` still reachable
//!         unprovable        -> ACCEPTED, forfeits `finite` -> unit `.strict`
//!     This is the same treatment `exp` gets above, and it is what keeps the
//!     accepted set EQUAL to the LRM's. Interval arithmetic cannot decide the
//!     common `x = V/(1+abs(V))` idiom (it must correlate two occurrences of
//!     V), so a stronger abstract domain would not rescue those legal models —
//!     only this policy does.
//!   - `/` BY ZERO IS NOT AN ERROR. §4.2.4's only zero rule is "It shall be an
//!     error to pass zero (0) as the second argument to the MODULUS operator".
//!     `x/0.0` is an exact IEEE ±inf, so it is accepted and forfeits `finite`.
//!     Rejecting it would refuse `I <+ V/r` — the plain resistor, and every
//!     foundry compact model, which divide by unranged parameters.
//!     Integer `/` and `%` DO stay errors: `@divTrunc(i64, 0)` is illegal
//!     behavior in Zig, and integers have no inf to fall back on.
//!
//! DOD: three SoA arrays indexed by `Mir.Value` (interval, finite bit, guard
//! ref). Instructions are walked once, in dominator-tree preorder. No per-op
//! allocation; all scratch lives in one arena that dies with `prove`.
//!
//! ─────────────────────────────────────────────────────────────────────────
//! UNIT ORDERING (normative — naming.zig and codegen.zig MUST match)
//!
//!   unit_modes[i]  ↔  lower.contributions.items[i]
//!
//! One unit per `Lower.Contribution` (which is already one per (access, node
//! pair), §5.6.1.3 — not one per `<+` statement; the exception is a §5.6.7
//! INDIRECT contribution, where each statement is its own equation and so its
//! own entry), in `Lower.contributions` append order, `naming.Role.analog`,
//! target = access + node pair. The mode is
//! the JOIN over both `resist_val` (→ eval) and `react_val` (→ q): a unit gets
//! `.optimized` only if BOTH its slices are proven finite, because codegen emits
//! one `@setFloatMode` per unit function. A §5.6.7 indirect contribution needs
//! no special case: its constraint row lives in `resist_val` like any other
//! unit value (`react_val` stays `.f_zero`), so the same slice walk rates it.
//!
//! A §5.4.3 PORT PROBE (`I(<p>)`, `lower.port_probes`) adds NO unit and does
//! not perturb this indexing. Like the branch-relation row of a §5.6 potential
//! contribution, its row (`x[flow(<p>)] − res[p]`) is assembled inline in
//! codegen's residual dispatcher out of values the contribution units already
//! produced; there is no separate body to rate, so naming.zig and this file
//! stay unchanged. If a future port form ever needs its own body, it becomes a
//! new unit kind and the rule below applies.
//!
//! `unitCount(lower)` is the authoritative length. If naming.zig ever emits
//! additional unit kinds (user functions §4.7, named blocks §5.3.2, analog-
//! operator sub-units §4.5), they MUST be appended AFTER the contribution units
//! and this file extended in the same commit — never interleaved.
//! ─────────────────────────────────────────────────────────────────────────
//!
//! SOUNDNESS MODEL (read before touching `finite`)
//!
//! `.optimized` compiles to `@setFloatMode(.optimized)`, which asserts nnan AND
//! ninf. A wrong `.optimized` is silent, Release-only, convergence-corrupting
//! UB, so every rule below errs toward `.strict`.
//!
//!   1. INPUTS ARE FINITE. Solver unknowns (§4.4 probes) and model-card
//!      parameters (§3.4) are finite IEEE doubles — that is the host artifact
//!      contract (docs/architecture/05-build-artifact.html). Being *finite* is
//!      separate from being *bounded*: a probe is finite with an unknown
//!      magnitude, so its interval is (-inf, inf) but its `finite` bit is set.
//!      A parameter whose declared range explicitly ADMITS `inf` (`from [0:inf]`)
//!      is not finite.
//!   2. OVERFLOW IS TRACKED WHERE IT IS REAL. `exp`/`expm1`/`sinh`/`cosh`/`pow`
//!      overflow at ordinary device magnitudes (exp(710)), so they are proven
//!      exactly: unbounded argument ⇒ `.strict`.
//!   3. `+ - * /` on finite operands are assumed not to overflow
//!      (`Options.arith_overflow = .assume_absent`, the default): reaching 1e308
//!      in a residual means the Newton iterate already diverged, which is the
//!      host's convergence check, not a language property. Set
//!      `.tracked` to demand bounded intervals there too — that is the
//!      calibration knob, not a code change.
//!   4. Anything unmodelled (a `call`: analog operators §4.5, ch9 system
//!      functions) is non-finite. It costs `.strict`, never a wrong `.optimized`.

const std = @import("std");
const Ast = @import("ast.zig");
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const diag = @import("diag.zig");
const assert = std.debug.assert;
const math = std.math;

/// Per-unit float-mode decision. LRM §4.3 domains + finiteness.
pub const FloatMode = enum {
    /// Proven finite (no NaN/Inf possible) → codegen emits @setFloatMode(.optimized).
    optimized,
    /// Not provably finite (e.g. unbounded voltage exp) → @setFloatMode(.strict),
    /// where inf is IEEE-defined and spec-legal. NOT an error.
    strict,

    /// The mode a declaration SHARED by several units must compile in.
    ///
    /// SOUNDNESS: `.optimized` is full fast-math — it asserts `nnan` and `ninf`
    /// (see the note at the head of this file). A subexpression hoisted out of a
    /// `.strict` unit into a shared declaration is still reachable from that
    /// unit, so compiling it fast-math would assert a finiteness fact that unit
    /// never had. The join is therefore `.strict`-absorbing, and codegen folds
    /// every consumer of a common declaration through it (`Gen.planCommon`).
    ///
    /// The other direction is free: a `.optimized` unit that loses fast-math
    /// inside a shared callee is slower, never wrong — the same conservative
    /// direction the file-scope math helpers already take (codegen.math_txt).
    pub fn strictest(a: FloatMode, b: FloatMode) FloatMode {
        return if (a == .strict or b == .strict) .strict else .optimized;
    }
};

pub const Verdict = struct {
    /// One entry per source unit — see UNIT ORDERING in the file header.
    unit_modes: []const FloatMode,
    /// Number of §4.3.2 domain violations reported into the `diag.Bag`. Zero ⇒
    /// the model is accepted and codegen may run. Non-zero ⇒ compile error;
    /// `unit_modes` is still filled (all `.strict`) so a lint front-end reports
    /// everything in one pass.
    ///
    /// The messages themselves are NOT here any more: they go straight into the
    /// shared bag, which is what gives them a source location, a code, a fix
    /// and a place in the global source ordering.
    error_count: u32,

    pub fn ok(self: Verdict) bool {
        return self.error_count == 0;
    }

    pub fn deinit(self: Verdict, gpa: std.mem.Allocator) void {
        gpa.free(self.unit_modes);
    }
};

pub const Options = struct {
    /// If the host guarantees |unknown| ≤ B for every solver unknown, set it and
    /// probe-dependent transcendentals become provable. `null` = unbounded
    /// (still finite — see SOUNDNESS MODEL 1). This is the hardware knob: a real
    /// solver has a real compliance limit that no language rule can see.
    unknown_bound: ?f64 = null,
    /// SOUNDNESS MODEL 3. `.tracked` refuses to assume `+ - * /` stay in range.
    arith_overflow: enum { assume_absent, tracked } = .assume_absent,
};

/// Stop after this many; one bad expression otherwise reports a cascade.
const max_errors = 64;

/// Number of source units — the length of `Verdict.unit_modes`. naming.zig must
/// agree with this (assert it there).
pub fn unitCount(lower: *const Lower) usize {
    return lower.contributions.items.len;
}

// ---------------------------------------------------------------------------
// The lattice
// ---------------------------------------------------------------------------

/// Abstract value: a closed/open real interval. `⊤` is `(-inf, inf)` closed,
/// which is also the "no evidence" element, so a zero-initialised pass is sound.
///
/// NaN never appears as a bound: a NaN constant widens to ⊤ (unknown), and every
/// bound-producing arithmetic below folds a NaN endpoint to the matching
/// infinity. Empty (`lo > hi`) means unreachable and vacuously satisfies every
/// domain, which is exactly right for a contradictory guard.
pub const Interval = struct {
    lo: f64 = -math.inf(f64),
    hi: f64 = math.inf(f64),
    /// `true` ⇒ the bound itself is EXCLUDED (LRM §3.4.2 `(`/`)`).
    lo_open: bool = false,
    hi_open: bool = false,
    /// LRM §3.4.2 `exclude 0` on an otherwise unbounded parameter: a hole an
    /// interval cannot represent, but the one hole a divisor proof needs.
    nonzero: bool = false,

    pub const top: Interval = .{};

    pub fn point(x: f64) Interval {
        if (math.isNan(x)) return top;
        return .{ .lo = x, .hi = x };
    }

    /// Bounded on both sides ⇒ every member is a finite double.
    pub fn bounded(i: Interval) bool {
        return math.isFinite(i.lo) and math.isFinite(i.hi);
    }

    pub fn isEmpty(i: Interval) bool {
        return i.lo > i.hi or (i.lo == i.hi and (i.lo_open or i.hi_open));
    }

    /// Does the interval EXCLUDE ±inf? (An open infinite bound excludes it.)
    pub fn excludesInf(i: Interval) bool {
        const lo_ok = math.isFinite(i.lo) or (i.lo == -math.inf(f64) and i.lo_open);
        const hi_ok = math.isFinite(i.hi) or (i.hi == math.inf(f64) and i.hi_open);
        return lo_ok and hi_ok;
    }

    pub fn gt(i: Interval, k: f64) bool { // x > k
        return i.lo > k or (i.lo == k and i.lo_open);
    }
    pub fn ge(i: Interval, k: f64) bool { // x >= k
        return i.lo >= k;
    }
    pub fn lt(i: Interval, k: f64) bool { // x < k
        return i.hi < k or (i.hi == k and i.hi_open);
    }
    pub fn le(i: Interval, k: f64) bool { // x <= k
        return i.hi <= k;
    }
    pub fn excludesZero(i: Interval) bool {
        return i.nonzero or i.gt(0) or i.lt(0);
    }

    /// Intersection — how guard evidence is applied.
    pub fn meet(a: Interval, b: Interval) Interval {
        var r = a;
        if (b.lo > r.lo) {
            r.lo = b.lo;
            r.lo_open = b.lo_open;
        } else if (b.lo == r.lo) {
            r.lo_open = r.lo_open or b.lo_open;
        }
        if (b.hi < r.hi) {
            r.hi = b.hi;
            r.hi_open = b.hi_open;
        } else if (b.hi == r.hi) {
            r.hi_open = r.hi_open or b.hi_open;
        }
        r.nonzero = r.nonzero or b.nonzero;
        return r;
    }

    /// Convex hull — how phi/select operands and `from` range lists combine.
    pub fn join(a: Interval, b: Interval) Interval {
        var r = a;
        if (b.lo < r.lo) {
            r.lo = b.lo;
            r.lo_open = b.lo_open;
        } else if (b.lo == r.lo) {
            r.lo_open = r.lo_open and b.lo_open;
        }
        if (b.hi > r.hi) {
            r.hi = b.hi;
            r.hi_open = b.hi_open;
        } else if (b.hi == r.hi) {
            r.hi_open = r.hi_open and b.hi_open;
        }
        r.nonzero = r.nonzero and b.nonzero;
        return r;
    }
};

/// LRM Tables 4-14 / 4-15 domains. The operand of each must be proven in-domain
/// (else compile error), EXCEPT the "All x" group which governs float mode only.
pub const Domain = enum {
    all, // exp, expm1, sinh, cosh, tanh, sin, cos, floor, ceil, min, max, abs — §4.3.1/§4.3.2
    positive, // ln, log10                                   §4.3.1  (x > 0)
    gt_neg_one, // ln1p                                       §4.3.1  (x > -1)
    non_negative, // sqrt                                     §4.3.1  (x >= 0)
    unit_closed, // asin, acos                                §4.3.2  (-1 <= x <= 1)
    unit_open, // atanh                                       §4.3.2  (-1 < x < 1)
    ge_one, // acosh                                          §4.3.2  (x >= 1)
    nonzero_divisor, // '/', '%'                              §4.2 / §4.3.1
    tan_poles, // tan: x != n(π/2), n odd                     §4.3.2
    pow_sign, // pow(x,y) sign rules                          §4.3.1 Table 4-14
};

/// Map an Opcode to its LRM domain obligation. `.all` ⇒ nothing to prove.
/// For the binary members the obligation is on the SECOND operand
/// (`nonzero_divisor`) or on BOTH (`pow_sign`); everything else constrains the
/// single unary operand.
pub fn domainOf(op: Mir.Opcode) Domain {
    return switch (op) {
        .ln, .log10 => .positive,
        .ln1p => .gt_neg_one,
        .sqrt => .non_negative,
        .asin, .acos => .unit_closed,
        .atanh => .unit_open,
        .acosh => .ge_one,
        .tan => .tan_poles,
        .pow => .pow_sign,
        // NOT `.fdiv`: §4.2.4 makes ONLY `%`-by-zero an error. `x/0.0` is an
        // exact IEEE ±inf and is spec-legal, so it must not reject — it forfeits
        // finiteness instead (see the `.fdiv` transfer), which drops the unit to
        // `.strict`. Integer `/` and `%` stay errors: Zig's `@divTrunc(i64, 0)`
        // is illegal behavior, and integers have no inf to fall back on.
        .fmod, .idiv, .imod => .nonzero_divisor,
        else => .all,
    };
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/// Main entry. Prove domains, decide per-unit float mode. See UNIT ORDERING.
pub fn prove(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    bag: *diag.Bag,
) !Verdict {
    return proveOpts(gpa, mir, lower, .{}, bag);
}

pub fn proveOpts(
    gpa: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    opts: Options,
    bag: *diag.Bag,
) !Verdict {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();

    var p: Prover = .{
        .gpa = gpa,
        .arena = scratch.allocator(),
        .mir = mir,
        .lower = lower,
        .opts = opts,
        .bag = bag,
    };

    try p.seedValues(); // §3.4.2 param ranges, §4.2 constants, §4.4 probes
    try p.buildClasses(); // structural congruence, so guards reach every copy
    try p.buildCfg(); // succ/pred CSR from the terminators
    try p.computeDominators(); // guard evidence needs dominance
    try p.markSelectArms(); // §4.2.12 `?:` guards its own arms
    try p.walk(); // the one linear pass: intervals + domain checks
    return p.verdict(); // per-unit join over the backward slices
}

// ---------------------------------------------------------------------------
// The prover
// ---------------------------------------------------------------------------

/// A guard fact: "this Value is confined to this interval here".
const Fact = struct { v: u32, iv: Interval };

/// Where a value's select-arm guard facts live in `facts`.
const GuardRef = struct { start: u32 = 0, count: u32 = 0 };

const none_u32 = std.math.maxInt(u32);

const Prover = struct {
    gpa: std.mem.Allocator,
    /// Scratch arena — every field below except `errors` lives here and dies
    /// with `prove`. Nothing in this file needs a per-op allocation.
    arena: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    opts: Options,

    // --- SoA, indexed by @intFromEnum(Mir.Value) ---
    iv: []Interval = &.{},
    /// SOUNDNESS MODEL: "is a finite IEEE double", recorded at definition time.
    finite: []bool = &.{},
    /// Use count, for the single-use test that scopes a §4.2.12 select guard.
    uses: []u32 = &.{},
    guard: []GuardRef = &.{},
    /// Congruence class per value (`none_u32` = alone). Two structurally
    /// identical pure instructions compute the SAME number, so a guard fact
    /// about one is a fact about all of them — that is what lets
    /// `if (V(p,n) > 0) … ln(V(p,n))` prove, given that lowering emits a fresh
    /// `fsub` per `V(p,n)` occurrence. Internal to this pass; it must never
    /// leak into codegen, which deliberately recomputes per unit.
    /// ponytail: structural key on already-resolved operands only (no
    /// transitive numbering). Upgrade to a real GVN if a fixture needs it.
    class_of: []u32 = &.{},
    class_member: []u32 = &.{},
    class_start: []u32 = &.{},

    facts: std.ArrayList(Fact) = .empty,
    /// Save stack for guard application (dominator-tree DFS + select arms).
    saved: std.ArrayList(Fact) = .empty,

    // --- CFG, CSR-encoded, indexed by @intFromEnum(Mir.Block) ---
    succ: []u32 = &.{},
    succ_start: []u32 = &.{},
    pred: []u32 = &.{},
    pred_start: []u32 = &.{},
    idom: []u32 = &.{},
    dom_child: []u32 = &.{},
    dom_child_start: []u32 = &.{},
    /// Reverse postorder position, `none_u32` for a block unreachable from entry.
    rpo_num: []u32 = &.{},
    visited_block: []bool = &.{},

    /// Where every class-6 diagnostic goes. Shared with the other stages.
    bag: *diag.Bag,
    /// §4.3.2 violations reported so far — the accept/reject decision.
    error_count: u32 = 0,

    /// Source span of an instruction — the whole reason `Mir.InstRow.tok`
    /// exists. Before it, every class-6 diagnostic reported at line 0, col 0,
    /// which made the hardest pass in the engine the least debuggable.
    fn span(self: *const Prover, inst: Mir.Inst) diag.Span {
        const tok = self.mir.instTok(inst);
        // An unattributed instruction has NO location. Reporting one anyway put
        // the caret on whatever token 0 happened to be — the first line of the
        // annex-D prelude.
        if (tok == Mir.no_tok) return .{};
        return self.lower.tokenSpan(tok);
    }

    /// Span of whatever DEFINED a value, so a label can point at the parameter
    /// or the sub-expression the prover is really complaining about.
    fn valueSpan(self: *const Prover, v: Mir.Value) diag.Span {
        switch (self.mir.valueDef(self.mir.resolveAlias(v))) {
            .inst_result => |inst| return self.span(inst),
            .param_ref => |pi| {
                if (pi >= self.lower.params.items.len) return .{};
                const tok = self.lower.params.items[pi].tok;
                if (tok == Mir.no_tok) return .{};
                return self.lower.tokenSpan(tok);
            },
            else => return .{},
        }
    }

    fn nVals(self: *const Prover) u32 {
        return @intCast(self.mir.defs.len + Mir.Value.first_dynamic);
    }

    fn nBlocks(self: *const Prover) u32 {
        return self.mir.blockCount();
    }

    /// Every read of a Value goes through the alias map (ssa.zig contract).
    fn idxOf(self: *const Prover, v: Mir.Value) u32 {
        return @intFromEnum(self.mir.resolveAlias(v));
    }

    fn ivOf(self: *const Prover, v: Mir.Value) Interval {
        return self.iv[self.idxOf(v)];
    }

    fn isFinite(self: *const Prover, v: Mir.Value) bool {
        return self.finite[self.idxOf(v)];
    }

    // ------------------------------------------------------------------ CFG --

    /// Successors from every `branch`/`jump` in a block (not just the last
    /// instruction — a malformed block only makes dominance more conservative).
    fn buildCfg(self: *Prover) !void {
        const nb = self.nBlocks();
        var succ: std.ArrayList(u32) = .empty;
        self.succ_start = try self.arena.alloc(u32, nb + 1);

        for (0..nb) |b| {
            self.succ_start[b] = @intCast(succ.items.len);
            var it = self.mir.blockInsts(@enumFromInt(@as(u32, @intCast(b))));
            while (it.next()) |inst| switch (self.mir.instData(inst)) {
                .branch => |br| {
                    try succ.append(self.arena, @intFromEnum(br.then_block));
                    try succ.append(self.arena, @intFromEnum(br.else_block));
                },
                .jump => |j| try succ.append(self.arena, @intFromEnum(j.target)),
                else => {},
            };
        }
        self.succ_start[nb] = @intCast(succ.items.len);
        self.succ = succ.items;

        // Transpose into predecessors (counting sort, no nested lists).
        self.pred_start = try self.arena.alloc(u32, nb + 1);
        @memset(self.pred_start, 0);
        for (self.succ) |s| self.pred_start[s + 1] += 1;
        for (1..nb + 1) |i| self.pred_start[i] += self.pred_start[i - 1];
        self.pred = try self.arena.alloc(u32, self.succ.len);
        const fill = try self.arena.alloc(u32, nb);
        @memcpy(fill, self.pred_start[0..nb]);
        for (0..nb) |b| {
            for (self.succ[self.succ_start[b]..self.succ_start[b + 1]]) |s| {
                self.pred[fill[s]] = @intCast(b);
                fill[s] += 1;
            }
        }
    }

    fn preds(self: *const Prover, b: u32) []const u32 {
        return self.pred[self.pred_start[b]..self.pred_start[b + 1]];
    }

    /// Cooper/Harvey/Kennedy iterative dominators over reverse postorder.
    /// Blocks unreachable from entry keep `rpo_num == none_u32` and are walked
    /// separately (with no guard evidence) so their domains are still checked.
    fn computeDominators(self: *Prover) !void {
        const nb = self.nBlocks();
        self.idom = try self.arena.alloc(u32, nb);
        self.rpo_num = try self.arena.alloc(u32, nb);
        @memset(self.idom, none_u32);
        @memset(self.rpo_num, none_u32);
        if (nb == 0) return;

        // Iterative DFS → postorder.
        const post = try self.arena.alloc(u32, nb);
        var n_post: u32 = 0;
        const seen = try self.arena.alloc(bool, nb);
        @memset(seen, false);
        const next_succ = try self.arena.alloc(u32, nb);
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(self.arena, 0);
        seen[0] = true;
        next_succ[0] = self.succ_start[0];
        while (stack.items.len > 0) {
            const b = stack.items[stack.items.len - 1];
            if (next_succ[b] < self.succ_start[b + 1]) {
                const s = self.succ[next_succ[b]];
                next_succ[b] += 1;
                if (!seen[s]) {
                    seen[s] = true;
                    next_succ[s] = self.succ_start[s];
                    try stack.append(self.arena, s);
                }
            } else {
                _ = stack.pop();
                post[n_post] = b;
                n_post += 1;
            }
        }
        for (post[0..n_post], 0..) |b, i| self.rpo_num[b] = n_post - 1 - @as(u32, @intCast(i));

        self.idom[0] = 0;
        var changed = true;
        while (changed) {
            changed = false;
            var i: u32 = n_post - 1; // reverse postorder = postorder backwards
            while (true) : (i -= 1) {
                const b = post[i];
                if (b != 0) {
                    var new: u32 = none_u32;
                    for (self.preds(b)) |p| {
                        if (self.idom[p] == none_u32) continue;
                        new = if (new == none_u32) p else self.intersect(p, new);
                    }
                    if (new != none_u32 and self.idom[b] != new) {
                        self.idom[b] = new;
                        changed = true;
                    }
                }
                if (i == 0) break;
            }
        }

        // Dominator-tree children, CSR, in block-index order (determinism).
        self.dom_child_start = try self.arena.alloc(u32, nb + 1);
        @memset(self.dom_child_start, 0);
        for (0..nb) |b| {
            if (b == 0 or self.idom[b] == none_u32) continue;
            self.dom_child_start[self.idom[b] + 1] += 1;
        }
        for (1..nb + 1) |i| self.dom_child_start[i] += self.dom_child_start[i - 1];
        self.dom_child = try self.arena.alloc(u32, self.dom_child_start[nb]);
        const fill = try self.arena.alloc(u32, nb);
        @memcpy(fill, self.dom_child_start[0..nb]);
        for (0..nb) |b| {
            if (b == 0 or self.idom[b] == none_u32) continue;
            const parent = self.idom[b];
            self.dom_child[fill[parent]] = @intCast(b);
            fill[parent] += 1;
        }
    }

    // -------------------------------------------------------------- seeding --

    /// Initial abstract state for every Value. Only `inst_result` is left at ⊤;
    /// the pass fills those in dominator order.
    fn seedValues(self: *Prover) !void {
        const n = self.nVals();
        self.iv = try self.arena.alloc(Interval, n);
        self.finite = try self.arena.alloc(bool, n);
        self.uses = try self.arena.alloc(u32, n);
        self.guard = try self.arena.alloc(GuardRef, n);
        @memset(self.iv, Interval.top);
        @memset(self.finite, false);
        @memset(self.uses, 0);
        @memset(self.guard, .{});

        for (0..n) |i| {
            const v: Mir.Value = @enumFromInt(@as(u32, @intCast(i)));
            switch (self.mir.valueDef(v)) {
                // §4.2 constant expressions — exact.
                .float_const => |c| {
                    self.iv[i] = Interval.point(c);
                    self.finite[i] = math.isFinite(c);
                },
                .int_const => |c| {
                    self.iv[i] = Interval.point(@floatFromInt(c));
                    self.finite[i] = true;
                },
                // §2.7 strings never reach a float operation.
                .str_const => self.finite[i] = true,
                // §3.4.2 — THE primary bound evidence.
                .param_ref => |pi| {
                    const iv = self.paramInterval(pi);
                    self.iv[i] = iv;
                    self.finite[i] = iv.excludesInf();
                    // A range the user WROTE that admits infinity is almost
                    // always a typo for the open bound — see W0651.
                    if (!self.finite[i]) try self.warnInfiniteRange(pi, iv);
                },
                // §4.4 solver unknown: finite by the host contract, magnitude
                // unknown unless the host declares one (Options.unknown_bound).
                .block_param => {
                    if (self.opts.unknown_bound) |b|
                        self.iv[i] = .{ .lo = -@abs(b), .hi = @abs(b) };
                    self.finite[i] = true;
                },
                .undef, .inst_result => {},
            }
        }
    }

    /// LRM §3.4.2 value ranges → an interval. `from` ranges are unioned (their
    /// convex hull — the representation has no holes), `exclude` ranges are
    /// subtracted only where they clip an end, which is exactly the `exclude 0`
    /// / `from (0:inf)` evidence a divisor or a `ln` needs.
    ///
    /// Bounds are folded LITERALLY (`foldBound`), never through
    /// `Lower.constEval`: a bound written in terms of another parameter folds to
    /// that parameter's DEFAULT, which the model card can override — using it
    /// would be an unsound proof.
    fn paramInterval(self: *const Prover, param: u32) Interval {
        if (param >= self.lower.params.items.len) return .top;
        const info = self.lower.params.items[param];
        if (info.ty == .string) return .top;

        var acc: ?Interval = null;
        for (info.ranges) |r| {
            if (r.kind != .from or r.strings != null) continue;
            const lo = self.foldBound(r.lo) orelse return .top;
            const hi = if (r.hi == .none) lo else (self.foldBound(r.hi) orelse return .top);
            const one: Interval = .{
                .lo = lo,
                .hi = hi,
                .lo_open = !r.lo_inclusive,
                .hi_open = !r.hi_inclusive,
            };
            acc = if (acc) |a| a.join(one) else one;
        }
        var iv = acc orelse Interval.top;

        for (info.ranges) |r| {
            if (r.kind != .exclude or r.strings != null) continue;
            const lo = self.foldBound(r.lo) orelse continue;
            const hi = if (r.hi == .none) lo else (self.foldBound(r.hi) orelse continue);
            // Only an end-clipping exclusion is representable without holes.
            //
            // §3.4.2: "Parentheses, ( and ), indicate exclusion of the end
            // points from the value range." An END POINT of an `exclude` is
            // therefore excluded only when its bracket is square — `exclude
            // (0:5)` still admits 0, and concluding `nonzero` from it is
            // unsound: it discharges the divide-by-zero obligation and hands
            // the unit `@setFloatMode(.optimized)`, under which a division by
            // the very value the range permits is undefined behaviour.
            // `exclude 0` keeps working: `hi == .none` copies `lo`, and both
            // inclusive flags default to true.
            const zero_excluded = (lo < 0 and hi > 0) or
                (lo == 0 and r.lo_inclusive) or
                (hi == 0 and r.hi_inclusive);
            if (zero_excluded) iv.nonzero = true;
            if (lo <= iv.lo and hi >= iv.lo and hi <= iv.hi) {
                iv.lo = hi;
                iv.lo_open = r.hi_inclusive;
            } else if (hi >= iv.hi and lo <= iv.hi and lo >= iv.lo) {
                iv.hi = lo;
                iv.hi_open = r.lo_inclusive;
            }
        }
        return iv;
    }

    /// Literal-only constant fold of a §3.4.2 range bound. Deliberately refuses
    /// identifiers (see `paramInterval`); `inf` (§3.4.2) folds to ±infinity.
    fn foldBound(self: *const Prover, e: Ast.ExprId) ?f64 {
        if (e == .none) return null;
        const ex = &self.lower.file.exprs;
        return switch (ex.tag(e)) {
            .int_literal => @floatFromInt(ex.intValue(e)),
            .real_literal => ex.realValue(e),
            .pos_inf => math.inf(f64),
            .neg_inf => -math.inf(f64),
            .unary => blk: {
                const a = self.foldBound(ex.lhs(e)) orelse break :blk null;
                break :blk switch (ex.unOp(e)) {
                    .plus => a,
                    .minus => -a,
                    else => null,
                };
            },
            .binary => blk: {
                const a = self.foldBound(ex.lhs(e)) orelse break :blk null;
                const b = self.foldBound(ex.rhs(e)) orelse break :blk null;
                break :blk switch (ex.binOp(e)) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => if (b == 0) null else a / b,
                    .pow => math.pow(f64, a, b),
                    else => null,
                };
            },
            else => null,
        };
    }

    fn intersect(self: *const Prover, a_in: u32, b_in: u32) u32 {
        var a = a_in;
        var b = b_in;
        while (a != b) {
            while (self.rpo_num[a] > self.rpo_num[b]) a = self.idom[a];
            while (self.rpo_num[b] > self.rpo_num[a]) b = self.idom[b];
        }
        return a;
    }

    // ------------------------------------------------------- guard evidence --

    /// Operands of an instruction, into a caller buffer (max 3 + the variadic
    /// classes, which are returned as borrowed slices instead).
    fn operands(self: *const Prover, inst: Mir.Inst, buf: *[3]Mir.Value) []const Mir.Value {
        return switch (self.mir.instData(inst)) {
            .unary => |u| blk: {
                buf[0] = u.operand;
                break :blk buf[0..1];
            },
            .binary => |b| blk: {
                buf[0] = b.lhs;
                buf[1] = b.rhs;
                break :blk buf[0..2];
            },
            .ternary => |t| blk: {
                buf[0] = t.cond;
                buf[1] = t.then_val;
                buf[2] = t.else_val;
                break :blk buf[0..3];
            },
            .branch => |b| blk: {
                buf[0] = b.cond;
                break :blk buf[0..1];
            },
            .jump => buf[0..0],
            .call => |c| c.args,
            // phi operands are (block, value) pairs — callers use `phiPair`.
            .phi => buf[0..0],
        };
    }

    /// Group structurally identical pure instructions. Impure classes (phi,
    /// call, terminators, and the `opt_barrier` fence) are never merged.
    fn buildClasses(self: *Prover) !void {
        const n = self.nVals();
        self.class_of = try self.arena.alloc(u32, n);
        @memset(self.class_of, none_u32);

        const Key = struct { op: Mir.Opcode, a: u32, b: u32, c: u32 };
        var map: std.AutoHashMapUnmanaged(Key, u32) = .empty;
        defer map.deinit(self.arena);
        var n_classes: u32 = 0;

        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(i)));
            const op = self.mir.instOp(inst);
            if (op == .phi or op == .call or op == .opt_barrier) continue;
            const result = self.mir.instResult(inst);
            if (result == .undef) continue;
            var buf: [3]Mir.Value = undefined;
            const ops = self.operands(inst, &buf);
            const key: Key = .{
                .op = op,
                .a = if (ops.len > 0) self.idxOf(ops[0]) else 0,
                .b = if (ops.len > 1) self.idxOf(ops[1]) else 0,
                .c = if (ops.len > 2) self.idxOf(ops[2]) else 0,
            };
            const gop = try map.getOrPut(self.arena, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = n_classes;
                n_classes += 1;
            }
            self.class_of[self.idxOf(result)] = gop.value_ptr.*;
        }

        // CSR of members, in value order (determinism).
        self.class_start = try self.arena.alloc(u32, n_classes + 1);
        @memset(self.class_start, 0);
        for (self.class_of) |c| if (c != none_u32) {
            self.class_start[c + 1] += 1;
        };
        for (1..n_classes + 1) |i| self.class_start[i] += self.class_start[i - 1];
        self.class_member = try self.arena.alloc(u32, self.class_start[n_classes]);
        const fill = try self.arena.alloc(u32, n_classes);
        @memcpy(fill, self.class_start[0..n_classes]);
        for (self.class_of, 0..) |c, v| if (c != none_u32) {
            self.class_member[fill[c]] = @intCast(v);
            fill[c] += 1;
        };
    }

    /// LRM §4.2.12 `?:` is a value-form `select`, so its arms carry NO CFG
    /// dominance — without this, the canonical guarded idiom
    /// `x > 0 ? ln(x) : 0` would be rejected. An arm's exclusively-owned
    /// backward slice (use count 1) is guarded by the select condition.
    ///
    /// CODEGEN OBLIGATION: `select` must be emitted as a lazy Zig `if`, not as
    /// "evaluate both arms then pick" — otherwise `ln(x)` really does run with
    /// x <= 0 and this guard is a lie.
    fn markSelectArms(self: *Prover) !void {
        // Use counts first: the single-use test is what scopes an arm.
        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(i)));
            if (self.mir.instOp(inst) == .phi) {
                const ph = self.mir.instData(inst).phi;
                for (0..ph.count) |k| self.uses[self.idxOf(self.mir.phiPair(inst, @intCast(k)).value)] += 1;
                continue;
            }
            var buf: [3]Mir.Value = undefined;
            for (self.operands(inst, &buf)) |v| self.uses[self.idxOf(v)] += 1;
        }
        // Contribution roots count as uses so a root is never mistaken for an
        // exclusively-owned select arm.
        for (self.lower.contributions.items) |c| {
            self.uses[self.idxOf(c.resist_val)] += 1;
            self.uses[self.idxOf(c.react_val)] += 1;
        }

        for (0..self.mir.insts.len) |i| {
            const inst: Mir.Inst = @enumFromInt(@as(u32, @intCast(i)));
            if (self.mir.instOp(inst) != .select) continue;
            const t = self.mir.instData(inst).ternary;
            try self.markArm(t.then_val, t.cond, true);
            try self.markArm(t.else_val, t.cond, false);
        }
    }

    fn markArm(self: *Prover, arm: Mir.Value, cond: Mir.Value, taken: bool) !void {
        var raw: [2]Fact = undefined;
        const facts = self.condFacts(cond, taken, &raw);
        if (facts.len == 0) return;
        const start: u32 = @intCast(self.facts.items.len);
        try self.facts.appendSlice(self.arena, facts);
        const ref: GuardRef = .{ .start = start, .count = @intCast(facts.len) };

        // DFS the arm's exclusively-owned slice. Budgeted: a shared value stops
        // the walk, so this is linear in the arm, not in the program.
        var stack: std.ArrayList(Mir.Value) = .empty;
        defer stack.deinit(self.arena);
        try stack.append(self.arena, arm);
        var budget: u32 = 4096;
        while (stack.pop()) |v| {
            if (budget == 0) break;
            budget -= 1;
            const i = self.idxOf(v);
            if (self.uses[i] != 1 or self.guard[i].count != 0) continue;
            const def = self.mir.valueDef(@enumFromInt(i));
            if (def != .inst_result) continue;
            self.guard[i] = ref;
            const inst = def.inst_result;
            if (self.mir.instOp(inst) == .phi) continue; // a phi is not arm-local
            var buf: [3]Mir.Value = undefined;
            for (self.operands(inst, &buf)) |o| try stack.append(self.arena, o);
        }
    }

    fn isZeroConst(self: *const Prover, v: Mir.Value) bool {
        return switch (self.mir.valueDef(self.mir.resolveAlias(v))) {
            .int_const => |c| c == 0,
            .float_const => |c| c == 0.0,
            else => false,
        };
    }

    /// Is this value already a 0/1 predicate (§4.2.5/§4.2.8)?
    fn isPredicate(self: *const Prover, v: Mir.Value) bool {
        const def = self.mir.valueDef(self.mir.resolveAlias(v));
        if (def != .inst_result) return false;
        return switch (self.mir.instOp(def.inst_result)) {
            .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine, .lognot => true,
            else => false,
        };
    }

    /// Facts implied by taking (or not taking) a branch on `cond`.
    /// LRM §4.2.5 relational / §4.2.7 equality operators; `&&`/`||` need no case
    /// because §4.2.8 short-circuit gives them real CFG (see lower.zig).
    fn condFacts(self: *const Prover, cond: Mir.Value, taken: bool, buf: *[2]Fact) []const Fact {
        const def = self.mir.valueDef(self.mir.resolveAlias(cond));
        if (def != .inst_result) return buf[0..0];
        const inst = def.inst_result;
        const d = self.mir.instData(inst);
        switch (d) {
            .unary => |u| if (u.op == .lognot) return self.condFacts(u.operand, !taken, buf),
            .binary => |b| {
                // §4.2.8: lowering materialises a condition as `c != 0`. Peel
                // that off when `c` is itself a comparison, otherwise keep it as
                // the (useful) "non-zero" fact for a §4.2.4 divisor.
                if (b.op == .ine or b.op == .fne or b.op == .ieq or b.op == .feq) {
                    const flip = b.op == .ieq or b.op == .feq;
                    const zl = self.isZeroConst(b.lhs);
                    const zr = self.isZeroConst(b.rhs);
                    const other: ?Mir.Value = if (zr) b.lhs else if (zl) b.rhs else null;
                    if (other) |o| {
                        if (self.isPredicate(o)) return self.condFacts(o, taken != flip, buf);
                        if (taken != flip) {
                            buf[0] = .{ .v = self.idxOf(o), .iv = .{ .nonzero = true } };
                            return buf[0..1];
                        }
                        return buf[0..0];
                    }
                }
                // Normalise every comparison to `lhs REL rhs`.
                const Rel = enum { lt, le, eq, none };
                var rel: Rel = .none;
                var swap = false;
                switch (b.op) {
                    .flt, .ilt => rel = if (taken) .lt else .none,
                    .fle, .ile => rel = if (taken) .le else .none,
                    .fgt, .igt => {
                        swap = true;
                        rel = if (taken) .lt else .none;
                    },
                    .fge, .ige => {
                        swap = true;
                        rel = if (taken) .le else .none;
                    },
                    .feq, .ieq => rel = if (taken) .eq else .none,
                    .fne, .ine => rel = if (taken) .none else .eq,
                    else => {},
                }
                // The negated strict/loose forms: !(a<b) ⇒ b<=a, !(a<=b) ⇒ b<a.
                if (!taken) switch (b.op) {
                    .flt, .ilt => {
                        rel = .le;
                        swap = true;
                    },
                    .fle, .ile => {
                        rel = .lt;
                        swap = true;
                    },
                    .fgt, .igt => {
                        rel = .le;
                        swap = false;
                    },
                    .fge, .ige => {
                        rel = .lt;
                        swap = false;
                    },
                    else => {},
                };
                if (rel == .none) return buf[0..0];
                const lo_v = if (swap) b.rhs else b.lhs;
                const hi_v = if (swap) b.lhs else b.rhs;
                const li = self.idxOf(lo_v);
                const hi = self.idxOf(hi_v);
                const a_iv = self.iv[li];
                const b_iv = self.iv[hi];
                var n: usize = 0;
                switch (rel) {
                    .eq => {
                        buf[n] = .{ .v = li, .iv = b_iv };
                        n += 1;
                        buf[n] = .{ .v = hi, .iv = a_iv };
                        n += 1;
                    },
                    .lt, .le => {
                        // a < b  ⇒  a < b.hi  and  b > a.lo
                        const strict = rel == .lt;
                        buf[n] = .{ .v = li, .iv = .{
                            .hi = b_iv.hi,
                            .hi_open = strict or b_iv.hi_open,
                        } };
                        n += 1;
                        buf[n] = .{ .v = hi, .iv = .{
                            .lo = a_iv.lo,
                            .lo_open = strict or a_iv.lo_open,
                        } };
                        n += 1;
                    },
                    .none => unreachable,
                }
                return buf[0..n];
            },
            else => {},
        }
        return buf[0..0];
    }

    /// Apply facts, remembering the previous intervals. Returns the undo mark.
    fn pushFacts(self: *Prover, facts: []const Fact) !usize {
        const mark = self.saved.items.len;
        for (facts) |f| {
            const c = self.class_of[f.v];
            const members: []const u32 = if (c == none_u32)
                (&[_]u32{f.v})[0..1]
            else
                self.class_member[self.class_start[c]..self.class_start[c + 1]];
            for (members) |m| {
                try self.saved.append(self.arena, .{ .v = m, .iv = self.iv[m] });
                self.iv[m] = self.iv[m].meet(f.iv);
            }
        }
        return mark;
    }

    fn popFacts(self: *Prover, mark: usize) void {
        while (self.saved.items.len > mark) {
            const f = self.saved.pop().?;
            self.iv[f.v] = f.iv;
        }
    }

    // ------------------------------------------------------------ the walk --

    /// One pass over every instruction, in dominator-tree preorder so that a
    /// guard applied on the edge into a block stays in effect for the whole
    /// subtree it dominates and is undone on the way out.
    ///
    /// SSA guarantees a definition dominates its uses, so every non-phi operand
    /// is already computed. A phi operand coming from an unprocessed
    /// predecessor (a loop back edge, §5.9) is still ⊤/non-finite — i.e. the
    /// loop is widened to ⊤ immediately. That is sound and terminating.
    /// ponytail: immediate widening loses loop-carried bounds. Upgrade path if a
    /// real model needs them: ascending-chain worklist from ⊥ with a widening
    /// after k rounds. Genvar loops (§6.6.1) unroll, so this bites `while` only.
    fn walk(self: *Prover) !void {
        const nb = self.nBlocks();
        if (nb == 0) return;
        self.visited_block = try self.arena.alloc(bool, nb);
        @memset(self.visited_block, false);

        try self.walkDom(0);

        // Blocks unreachable from entry still contain user-written operations;
        // check them with no guard evidence rather than silently skipping.
        for (0..nb) |b| if (!self.visited_block[b]) try self.walkBlock(@intCast(b));
    }

    fn walkDom(self: *Prover, b: u32) !void {
        const mark = self.saved.items.len;
        defer self.popFacts(mark);

        // Evidence from the edge idom(b) → b. Requiring b's ONLY predecessor to
        // be the branching block is what makes "dominated by b" imply "the
        // branch went this way".
        if (b != 0) {
            const parent = self.idom[b];
            if (parent != none_u32 and self.preds(b).len == 1) {
                var it = self.mir.blockInsts(@enumFromInt(parent));
                while (it.next()) |inst| {
                    const d = self.mir.instData(inst);
                    if (d != .branch) continue;
                    const taken = @intFromEnum(d.branch.then_block) == b;
                    if (!taken and @intFromEnum(d.branch.else_block) != b) continue;
                    var raw: [2]Fact = undefined;
                    _ = try self.pushFacts(self.condFacts(d.branch.cond, taken, &raw));
                }
            }
        }

        try self.walkBlock(b);
        for (self.dom_child[self.dom_child_start[b]..self.dom_child_start[b + 1]]) |c|
            try self.walkDom(c);
    }

    fn walkBlock(self: *Prover, b: u32) !void {
        self.visited_block[b] = true;
        var it = self.mir.blockInsts(@enumFromInt(b));
        while (it.next()) |inst| try self.evalInst(inst);
    }

    fn evalInst(self: *Prover, inst: Mir.Inst) !void {
        const result = self.mir.instResult(inst);
        const ri = self.idxOf(result);

        // §4.2.12 select-arm guard, scoped to exactly this instruction.
        const mark = self.saved.items.len;
        defer self.popFacts(mark);
        if (result != .undef) {
            const g = self.guard[ri];
            if (g.count != 0) _ = try self.pushFacts(self.facts.items[g.start..][0..g.count]);
        }

        // An unprovable domain is not an error (LRM §4.3.2, see checkDomain) —
        // it costs the result its finiteness fact, which drops the enclosing
        // unit to `@setFloatMode(.strict)` where NaN/inf are IEEE-defined.
        const domain_proven = try self.checkDomain(inst);
        if (result == .undef) return; // terminator

        const out = try self.transfer(inst);
        // MEET, not assign: a guard pushed on this value's congruence class
        // before its definition (the `if (V>0) … ln(V)` shape) must survive its
        // own transfer. `pushFacts` saved the pre-guard interval, so nothing
        // leaks out of the scope.
        self.iv[ri] = out.iv.meet(self.iv[ri]);
        self.finite[ri] = out.finite and domain_proven;
    }

    const Abstract = struct { iv: Interval, finite: bool };

    /// Transfer function. Intervals are computed for the DOMAIN proof; `finite`
    /// is the separate SOUNDNESS MODEL fact that drives the float mode.
    fn transfer(self: *Prover, inst: Mir.Inst) !Abstract {
        const op = self.mir.instOp(inst);

        // §4.2.5/§4.2.8: integer-valued results are finite by construction and
        // never pollute the float mode.
        if (Mir.opIsInteger(op)) return .{ .iv = self.integerIv(inst, op), .finite = true };

        switch (self.mir.instData(inst)) {
            .unary => |u| {
                const a = self.ivOf(u.operand);
                const af = self.isFinite(u.operand);
                return self.unaryTransfer(op, a, af);
            },
            .binary => |b| {
                const x = self.ivOf(b.lhs);
                const y = self.ivOf(b.rhs);
                const f = self.isFinite(b.lhs) and self.isFinite(b.rhs);
                return self.binaryTransfer(op, x, y, f);
            },
            .ternary => |t| { // §4.2.12 `?:` — the union of the two arms
                const a = self.ivOf(t.then_val);
                const b = self.ivOf(t.else_val);
                return .{
                    .iv = a.join(b),
                    .finite = self.isFinite(t.then_val) and self.isFinite(t.else_val),
                };
            },
            .phi => |ph| { // §5.8 join
                if (ph.count == 0) return .{ .iv = .top, .finite = false };
                var acc: ?Interval = null;
                var fin = true;
                for (0..ph.count) |k| {
                    const v = self.mir.phiPair(inst, @intCast(k)).value;
                    const one = self.ivOf(v);
                    acc = if (acc) |x| x.join(one) else one;
                    fin = fin and self.isFinite(v);
                }
                return .{ .iv = acc.?, .finite = fin };
            },
            // §4.5 analog operators / ch9 system functions: known ones carry a
            // spec-given range, everything else is ⊤.
            .call => |c| return callAbstract(c.name),
            .branch, .jump => return .{ .iv = .top, .finite = false },
        }
    }

    /// Integer results (§3.2): clamp to the i64 range so an integer expression
    /// can never make a unit `.strict`. Relational/logical results are 0/1.
    fn integerIv(self: *Prover, inst: Mir.Inst, op: Mir.Opcode) Interval {
        _ = self;
        _ = inst;
        return switch (op) {
            .flt, .fgt, .fle, .fge, .feq, .fne, .ilt, .igt, .ile, .ige, .ieq, .ine, .logand, .logor, .lognot => .{ .lo = 0, .hi = 1 },
            else => .{ .lo = -9.223372036854776e18, .hi = 9.223372036854776e18 },
        };
    }

    fn unaryTransfer(self: *Prover, op: Mir.Opcode, a: Interval, af: bool) Abstract {
        _ = self;
        const monotone: ?*const fn (f64) f64 = switch (op) {
            .exp => &mExp,
            .expm1 => &mExpm1,
            .ln => &mLn,
            .ln1p => &mLn1p,
            .log10 => &mLog10,
            .sqrt => &mSqrt,
            .sinh => &mSinh,
            .tanh => &mTanh,
            .asinh => &mAsinh,
            .atan => &mAtan,
            .asin => &mAsin,
            .atanh => &mAtanh,
            .acosh => &mAcosh,
            .floor => &mFloor,
            .ceil => &mCeil,
            .if_cast => &mId,
            .opt_barrier => &mId,
            else => null,
        };
        if (monotone) |f| {
            const lo = apply(f, a.lo);
            const hi = apply(f, a.hi);
            const iv: Interval = .{
                .lo = @min(lo, hi),
                .hi = @max(lo, hi),
                .lo_open = a.lo_open,
                .hi_open = a.hi_open,
            };
            const overflows = op == .exp or op == .expm1 or op == .sinh;
            return .{ .iv = iv, .finite = af and (!overflows or iv.bounded()) };
        }
        return switch (op) {
            .fneg => .{ .iv = .{
                .lo = -a.hi,
                .hi = -a.lo,
                .lo_open = a.hi_open,
                .hi_open = a.lo_open,
            }, .finite = af },
            .fabs => .{ .iv = absIv(a), .finite = af },
            // §4.3.2 acos is DECREASING on [-1,1].
            .acos => .{ .iv = .{ .lo = apply(&mAcos, a.hi), .hi = apply(&mAcos, a.lo) }, .finite = af },
            // §4.3.2 cosh: even, grows — bounded only if |x| is bounded.
            .cosh => blk: {
                const m = absIv(a);
                const iv: Interval = .{ .lo = 1, .hi = apply(&mCosh, m.hi) };
                break :blk .{ .iv = iv, .finite = af and iv.bounded() };
            },
            .sin, .cos => .{ .iv = .{ .lo = -1, .hi = 1 }, .finite = af },
            // §4.3.2 tan is unbounded between poles; the domain check has
            // already run, so only finiteness is left and it is not provable.
            .tan => .{ .iv = .top, .finite = false },
            else => .{ .iv = .top, .finite = false },
        };
    }

    fn binaryTransfer(self: *Prover, op: Mir.Opcode, x: Interval, y: Interval, f: bool) Abstract {
        const assume = self.opts.arith_overflow == .assume_absent;
        switch (op) {
            .fadd => {
                const iv: Interval = .{
                    .lo = addLo(x.lo, y.lo),
                    .hi = addHi(x.hi, y.hi),
                    .lo_open = x.lo_open or y.lo_open,
                    .hi_open = x.hi_open or y.hi_open,
                };
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .fsub => {
                const iv: Interval = .{
                    .lo = addLo(x.lo, -y.hi),
                    .hi = addHi(x.hi, -y.lo),
                    .lo_open = x.lo_open or y.hi_open,
                    .hi_open = x.hi_open or y.lo_open,
                };
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .fmul => {
                const iv = combine(x, y, mulOp);
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .fdiv => {
                // A divisor that can be zero yields ±inf (§4.2.4 permits it —
                // only `%` errors). That is NOT an overflow, so the
                // `assume_absent` escape must not apply: it covers SOUNDNESS
                // MODEL 3 (arithmetic overflow), and letting it through here
                // would mark an inf-producing value finite and hand the unit
                // `@setFloatMode(.optimized)`, whose `ninf` assertion it then
                // violates — silent, Release-only UB.
                if (!y.excludesZero()) return .{ .iv = .top, .finite = false };
                const iv = combine(x, y, divOp);
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            // §4.2.4 modulus: |result| < |divisor|, sign of the dividend.
            .fmod => {
                const m = absIv(y).hi;
                const iv: Interval = if (math.isFinite(m))
                    .{ .lo = if (x.ge(0)) 0 else -m, .hi = if (x.le(0)) 0 else m }
                else
                    .top;
                return .{ .iv = iv, .finite = f };
            },
            .pow => {
                const iv = combine(x, y, powOp);
                return .{ .iv = iv, .finite = f and iv.bounded() };
            },
            .hypot => {
                const iv: Interval = .{ .lo = 0, .hi = addHi(absIv(x).hi, absIv(y).hi) };
                return .{ .iv = iv, .finite = f and (assume or iv.bounded()) };
            },
            .atan2 => return .{ .iv = .{ .lo = -math.pi, .hi = math.pi }, .finite = f },
            .fmin => return .{ .iv = .{
                .lo = @min(x.lo, y.lo),
                .hi = @min(x.hi, y.hi),
            }, .finite = f },
            .fmax => return .{ .iv = .{
                .lo = @max(x.lo, y.lo),
                .hi = @max(x.hi, y.hi),
            }, .finite = f },
            else => return .{ .iv = .top, .finite = false },
        }
    }

    // ------------------------------------------------------- domain proofs --

    /// LRM §4.3.2: "Input values outside of the valid range for the operator
    /// shall report an error." That obliges reporting when a value IS out of
    /// range; it does not oblige rejecting a program whose values MIGHT be. So
    /// this is a THREE-WAY split, not two:
    ///
    ///   provably OUTSIDE the domain -> compile error (the §4.3.2 obligation,
    ///                                  discharged statically)
    ///   provably INSIDE              -> ok, may stay `.optimized`
    ///   straddles / unprovable       -> ACCEPTED, returns false so the caller
    ///                                  clears `finite` and the unit drops to
    ///                                  `.strict`, where NaN/inf are IEEE-defined
    ///
    /// This is the identical treatment `exp` already gets (SPEC-FAITHFUL, see
    /// the file header) and it is what keeps FastVAF's accepted set equal to the
    /// LRM's. Interval arithmetic provably cannot decide the common
    /// `x = V/(1+abs(V))` idiom (it needs to correlate two occurrences of V), so
    /// a stronger abstract domain would not rescue the rejected-but-legal cases.
    ///
    /// Returns TRUE when the domain is proven (or not applicable). Returning
    /// false is not an error — it is a loss of the finiteness fact.
    fn checkDomain(self: *Prover, inst: Mir.Inst) !bool {
        const op = self.mir.instOp(inst);
        const dom = domainOf(op);
        if (dom == .all) return true;

        switch (dom) {
            // Integer `/` and `%` only (§4.2.4). These stay HARD ERRORS: integer
            // division by zero is illegal behavior in Zig, not an IEEE infinity,
            // so there is no `.strict` fallback that makes it well-defined.
            .nonzero_divisor => {
                const d = self.mir.instData(inst).binary;
                const y = self.ivOf(d.rhs);
                if (y.excludesZero() or y.isEmpty()) return true;
                try self.reportDivisor(inst, op, d.rhs, y);
                return false;
            },
            .pow_sign => { // §4.3.1 Table 4-14
                const d = self.mir.instData(inst).binary;
                const x = self.ivOf(d.lhs);
                const y = self.ivOf(d.rhs);
                if (x.isEmpty() or y.isEmpty()) return true;
                if (x.gt(0)) return true; // x > 0, all y
                if (x.ge(0) and y.gt(0)) return true; // x = 0, y > 0
                if (self.provablyInteger(d.rhs)) return true; // x < 0, integer y
                // A negative base with a non-integer exponent is NaN, which is
                // IEEE-defined under `.strict`. Unprovable -> forfeit finiteness.
                return false;
            },
            .tan_poles => { // §4.3.2, x != n(pi/2), n odd
                const d = self.mir.instData(inst).unary;
                const a = self.ivOf(d.operand);
                if (a.isEmpty()) return true;
                if (a.bounded()) {
                    // The pole-free branch containing a.lo is
                    // (k*pi - pi/2, k*pi + pi/2). Note the f64 pole is exact to
                    // ~1 ulp; a model running that close to a tan pole is
                    // rejected, which is the conservative direction.
                    const k = @floor((a.lo + math.pi / 2.0) / math.pi);
                    const lo_pole = k * math.pi - math.pi / 2.0;
                    const hi_pole = k * math.pi + math.pi / 2.0;
                    if (a.gt(lo_pole) and a.lt(hi_pole)) return true;
                }
                // An interval spanning a pole still contains pole-free points, so
                // "provably always at a pole" is not decidable here. Unprovable
                // -> `.strict`, where the pole yields a defined IEEE infinity.
                return false;
            },
            else => {},
        }

        const d = self.mir.instData(inst).unary;
        const a = self.ivOf(d.operand);
        if (a.isEmpty()) return true;
        const name = opLabel(op);
        // Each arm: proven-inside -> true; proven-OUTSIDE -> report + false;
        // straddling -> false with no diagnostic (accepted, unit goes .strict).
        switch (dom) {
            .positive => {
                if (a.gt(0)) return true;
                if (a.le(0)) return self.violated(inst, .E0602, name, d.operand, a, "must be > 0", "add a range like `from (0:inf)` to the parameter, or guard the call with `if (x > 0)`");
                return false;
            },
            .gt_neg_one => {
                if (a.gt(-1)) return true;
                if (a.le(-1)) return self.violated(inst, .E0603, name, d.operand, a, "must be > -1", "add a range like `from (-1:inf)` to the parameter, or guard the call with `if (x > -1)`");
                return false;
            },
            .non_negative => {
                if (a.ge(0)) return true;
                if (a.lt(0)) return self.violated(inst, .E0604, name, d.operand, a, "must be >= 0", "add a range like `from [0:inf)` to the parameter, or write `sqrt(abs(x))` if magnitude is what the model means");
                return false;
            },
            .unit_closed => {
                if (a.ge(-1) and a.le(1)) return true;
                if (a.gt(1) or a.lt(-1)) return self.violated(inst, .E0605, name, d.operand, a, "must satisfy -1 <= x <= 1", "add a range like `from [-1:1]` to the parameter, or clamp with `min`/`max` before the call");
                return false;
            },
            .unit_open => {
                if (a.gt(-1) and a.lt(1)) return true;
                if (a.ge(1) or a.le(-1)) return self.violated(inst, .E0606, name, d.operand, a, "must satisfy -1 < x < 1", "add a range like `from (-1:1)` to the parameter — round brackets exclude the poles");
                return false;
            },
            .ge_one => {
                if (a.ge(1)) return true;
                if (a.lt(1)) return self.violated(inst, .E0607, name, d.operand, a, "must be >= 1", "add a range like `from [1:inf)` to the parameter, or guard the call");
                return false;
            },
            else => unreachable,
        }
    }

    /// §4.3.1 Table 4-14 pow with a negative base needs "all integer y".
    fn provablyInteger(self: *const Prover, v: Mir.Value) bool {
        const rv = self.mir.resolveAlias(v);
        switch (self.mir.valueDef(rv)) {
            .int_const => return true,
            .float_const => |c| return math.isFinite(c) and c == @trunc(c),
            .param_ref => |pi| return pi < self.lower.params.items.len and
                self.lower.params.items[pi].ty == .integer,
            .inst_result => |inst| {
                const op = self.mir.instOp(inst);
                // §4.2.1.2 integer→real conversion preserves integrality.
                return Mir.opIsInteger(op) or op == .if_cast;
            },
            else => return false,
        }
    }

    // ------------------------------------------------------------- messages --

    fn reportDivisor(self: *Prover, inst: Mir.Inst, op: Mir.Opcode, v: Mir.Value, iv: Interval) !void {
        const what = if (op == .fmod or op == .imod) "`%` divisor" else "`/` divisor";
        var b = try self.violation(inst, .E0601, v, iv, what);
        b.point("cannot be proven non-zero", .{});
        b.help("constrain the divisor with `exclude 0` or `from (0:inf)`, or guard the division", .{});
        try self.emit(&b);
    }

    /// Provably-outside-the-domain: report it (LRM §4.3.2) and forfeit
    /// finiteness. Always returns false so the caller clears `finite`.
    ///
    /// `requirement` is the short text drawn beside the caret ("must be > 0").
    /// The RULE and the CITATION are no longer strings here — they live in the
    /// code catalogue, so there is exactly one place they can be wrong.
    fn violated(
        self: *Prover,
        inst: Mir.Inst,
        code: diag.Code,
        what: []const u8,
        operand: Mir.Value,
        iv: Interval,
        requirement: []const u8,
        fix: []const u8,
    ) !bool {
        var b = try self.violation(inst, code, operand, iv, what);
        b.point("{s}", .{requirement});
        b.help("{s}", .{fix});
        try self.emit(&b);
        return false;
    }

    /// The shared skeleton of every class-6 error: caret on the offending
    /// instruction, a label on whatever DEFINED the bad operand, and the
    /// operand described in the terms the user wrote it in.
    fn violation(
        self: *Prover,
        inst: Mir.Inst,
        code: diag.Code,
        operand: Mir.Value,
        iv: Interval,
        what: []const u8,
    ) !diag.Builder {
        var buf: [96]u8 = undefined;
        var b = self.bag.build(.proof, code, self.span(inst));
        b.msg("{s} is {s}{s}", .{ what, self.describe(operand), self.ivText(&buf, iv) });
        const def = self.valueSpan(operand);
        if (!def.isNone() and def.start != self.span(inst).start)
            b.label(def, "{s} originates here", .{self.describe(operand)});
        return b;
    }

    fn emit(self: *Prover, b: *diag.Builder) !void {
        if (self.error_count >= max_errors) return;
        try b.emit();
        self.error_count += 1;
    }

    // ------------------------------------------------------ finiteness warns --

    /// W0650 — THE FINITENESS WARNING.
    ///
    /// A unit that is not provably finite is LEGAL and compiles; it just
    /// compiles with `@setFloatMode(.strict)` instead of `.optimized`, which
    /// costs reassociation, fusion and vectorisation in the batch evaluator.
    /// The engine never rejects such a model and never silently inserts a clamp
    /// or a `limexp` (see the SPEC-FAITHFUL note in the file header) — so the
    /// only honest thing left to do is TELL the user, name the value that broke
    /// the proof, and say what would fix it.
    ///
    /// `culprit` is the first value in the unit's backward slice with no
    /// finiteness evidence, which is exactly the thing to constrain.
    fn warnNotFinite(self: *Prover, unit: usize, c: Lower.Contribution, culprit: Mir.Value) !void {
        if (!self.bag.enabled(.W0650)) return;

        const access: []const u8 = if (c.access == .potential) "V" else "I";
        var b = self.bag.build(.proof, .W0650, self.lower.tokenSpan(c.tok));
        b.msg("unit {d} — {s}({s},{s}) — compiles with @setFloatMode(.strict)", .{
            unit,
            access,
            self.lower.nodeName(c.hi),
            self.lower.nodeName(c.lo),
        });

        const def = self.valueSpan(culprit);
        if (!def.isNone()) {
            b.label(def, "{s} is not provably finite", .{self.describe(culprit)});
        } else {
            b.point("{s} is not provably finite", .{self.describe(culprit)});
        }

        // Name the recovery that actually applies to THIS culprit rather than
        // listing all of them — the catalogue's `--explain` has the full set.
        switch (self.mir.valueDef(self.mir.resolveAlias(culprit))) {
            .param_ref => b.help(
                "give the parameter a range that excludes infinity, e.g. `from (0:inf)`",
                .{},
            ),
            .block_param => b.help(
                "a probe has unbounded magnitude; set `proof.Options.unknown_bound` to the solver's compliance limit",
                .{},
            ),
            .inst_result => |inst| {
                if (self.mir.instOp(inst) == .call) {
                    b.help("the prover does not model `{s}()`, so its range is unknown", .{
                        self.mir.instData(inst).call.name,
                    });
                } else {
                    b.help("constrain the operands with a range or a guard the prover can see", .{});
                }
            },
            else => {},
        }
        b.note("`.strict` is correct and spec-legal — this warning is about speed, not correctness", .{});
        try b.emit();
    }

    /// W0651 — a `from [0:inf]` range says infinity is an ACCEPTABLE VALUE for
    /// the parameter, which costs every unit downstream its proof. Writing the
    /// bound open admits the same finite values and keeps it.
    fn warnInfiniteRange(self: *Prover, pi: u32, iv: Interval) !void {
        if (!self.bag.enabled(.W0651)) return;
        if (pi >= self.lower.params.items.len) return;
        const pinfo = self.lower.params.items[pi];
        // Only worth saying when the user WROTE a range: a parameter with no
        // range at all is the ordinary case and W0650 already covers it.
        if (pinfo.ranges.len == 0) return;

        var b = self.bag.build(.proof, .W0651, self.lower.tokenSpan(pinfo.tok));
        b.msg("`{s}`", .{pinfo.name});
        b.point("{s} bound is closed on infinity", .{
            if (!math.isFinite(iv.lo) and !iv.lo_open) @as([]const u8, "lower") else "upper",
        });
        b.help("close the bound instead: `[0:inf)` admits the same finite values", .{});
        try b.emit();
    }

    /// Name the operand in terms the user wrote: a parameter, a node probe, or
    /// (for a computed value) the unbounded leaf it depends on.
    fn describe(self: *const Prover, v: Mir.Value) []const u8 {
        const rv = self.mir.resolveAlias(v);
        switch (self.mir.valueDef(rv)) {
            .param_ref => |pi| return if (pi < self.lower.params.items.len)
                std.fmt.allocPrint(self.arena, "parameter `{s}`", .{self.lower.params.items[pi].name}) catch "a parameter"
            else
                "a parameter",
            .block_param => |n| return std.fmt.allocPrint(
                self.arena,
                "a probe of node `{s}`",
                .{self.lower.nodeName(@intCast(n))},
            ) catch "a node probe",
            .float_const => |c| return std.fmt.allocPrint(self.arena, "the constant {d}", .{c}) catch "a constant",
            .int_const => |c| return std.fmt.allocPrint(self.arena, "the constant {d}", .{c}) catch "a constant",
            .inst_result => |inst| {
                if (self.mir.instOp(inst) == .call)
                    return std.fmt.allocPrint(self.arena, "the result of `{s}()`", .{self.mir.instData(inst).call.name}) catch "a call result";
                if (self.unboundedLeaf(rv)) |leaf|
                    return std.fmt.allocPrint(self.arena, "an expression of {s}", .{self.describe(leaf)}) catch "an expression";
                return "a computed expression";
            },
            else => return "an unknown value",
        }
    }

    /// First leaf in the backward slice with no bound evidence — the thing the
    /// user actually has to constrain. Budgeted; purely for the message.
    fn unboundedLeaf(self: *const Prover, root: Mir.Value) ?Mir.Value {
        var stack: [64]Mir.Value = undefined;
        var n: usize = 1;
        stack[0] = root;
        var budget: u32 = 256;
        while (n > 0 and budget > 0) {
            budget -= 1;
            n -= 1;
            const v = stack[n];
            const i = self.idxOf(v);
            switch (self.mir.valueDef(@enumFromInt(i))) {
                .param_ref, .block_param => if (!self.iv[i].bounded()) return v,
                .inst_result => |inst| {
                    if (self.mir.instOp(inst) == .phi) continue;
                    var buf: [3]Mir.Value = undefined;
                    for (self.operands(inst, &buf)) |o| {
                        if (n == stack.len) break;
                        stack[n] = o;
                        n += 1;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn ivText(self: *const Prover, buf: []u8, iv: Interval) []const u8 {
        _ = self;
        if (iv.lo == -math.inf(f64) and iv.hi == math.inf(f64)) return " with no known bounds";
        return std.fmt.bufPrint(buf, " with known range {c}{d}:{d}{c}", .{
            @as(u8, if (iv.lo_open) '(' else '['),
            iv.lo,
            iv.hi,
            @as(u8, if (iv.hi_open) ')' else ']'),
        }) catch "";
    }

    // -------------------------------------------------------------- verdict --

    /// Per-unit float mode: walk each contribution's backward slice and AND the
    /// `finite` bits. See UNIT ORDERING at the top of the file.
    fn verdict(self: *Prover) !Verdict {
        const n = unitCount(self.lower);
        const modes = try self.gpa.alloc(FloatMode, n);
        errdefer self.gpa.free(modes);

        const seen = try self.arena.alloc(bool, self.nVals());
        var stack: std.ArrayList(Mir.Value) = .empty;
        defer stack.deinit(self.arena);

        for (self.lower.contributions.items, 0..) |c, u| {
            @memset(seen, false);
            stack.clearRetainingCapacity();
            try stack.append(self.arena, c.resist_val);
            try stack.append(self.arena, c.react_val);
            var fin = true;
            // The first value with no finiteness evidence is the one the user
            // has to constrain, and so the one W0650 names.
            var culprit: Mir.Value = .undef;
            while (stack.pop()) |v| {
                const i = self.idxOf(v);
                if (seen[i]) continue;
                seen[i] = true;
                if (!self.finite[i]) {
                    fin = false;
                    culprit = v;
                    break;
                }
                const def = self.mir.valueDef(@enumFromInt(i));
                if (def != .inst_result) continue;
                const inst = def.inst_result;
                if (self.mir.instOp(inst) == .phi) {
                    const ph = self.mir.instData(inst).phi;
                    for (0..ph.count) |k|
                        try stack.append(self.arena, self.mir.phiPair(inst, @intCast(k)).value);
                    continue;
                }
                var buf: [3]Mir.Value = undefined;
                for (self.operands(inst, &buf)) |o| try stack.append(self.arena, o);
            }
            // A rejected model still gets a verdict, but never `.optimized`.
            modes[u] = if (fin and self.error_count == 0) .optimized else .strict;

            // Only warn when the model is otherwise ACCEPTED: after a domain
            // error every unit is `.strict` as a consequence, and reporting
            // that as news would bury the error that caused it.
            if (!fin and self.error_count == 0) try self.warnNotFinite(u, c, culprit);
        }

        return .{
            .unit_modes = modes,
            .error_count = self.error_count,
        };
    }
};

/// The handful of `call`s whose range the LRM fixes. Everything else is ⊤ —
/// unmodelled costs `.strict`, never a wrong `.optimized`. Without this table
/// the ubiquitous `V/$vt` idiom would be rejected as a possible division by
/// zero, which no conformant compiler should do.
fn callAbstract(name: []const u8) Prover.Abstract {
    const positive: Interval = .{ .lo = 0, .lo_open = true, .nonzero = true };
    const non_negative: Interval = .{ .lo = 0 };
    // §9.10 environment parameter functions; §4.5.13 limexp; §9.18 $mfactor.
    if (std.mem.eql(u8, name, "$vt") or // thermal voltage kT/q > 0
        std.mem.eql(u8, name, "$temperature") or // absolute temperature, kelvin
        std.mem.eql(u8, name, "$mfactor") or // multiplicity factor > 0
        std.mem.eql(u8, name, "limexp")) // §4.5.13: limited, hence finite
        return .{ .iv = positive, .finite = true };
    if (std.mem.eql(u8, name, "$abstime") or std.mem.eql(u8, name, "$realtime"))
        return .{ .iv = non_negative, .finite = true };
    return .{ .iv = .top, .finite = false };
}

/// LRM Table 4-14/4-15 spelling of an opcode, for diagnostics. `log10` is
/// Verilog-A's `log` (mir.zig naming note).
fn opLabel(op: Mir.Opcode) []const u8 {
    return switch (op) {
        .ln => "ln()",
        .log10 => "log()",
        .ln1p => "ln1p()",
        .sqrt => "sqrt()",
        .asin => "asin()",
        .acos => "acos()",
        .atanh => "atanh()",
        .acosh => "acosh()",
        .tan => "tan()",
        .pow => "pow()",
        else => @tagName(op),
    };
}

// --- endpoint arithmetic: NaN (inf-inf, 0*inf, 0/0) folds to the wide side ---

fn apply(f: *const fn (f64) f64, x: f64) f64 {
    const r = f(x);
    return if (math.isNan(r)) math.inf(f64) else r;
}

fn addLo(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) -math.inf(f64) else r;
}

fn addHi(a: f64, b: f64) f64 {
    const r = a + b;
    return if (math.isNan(r)) math.inf(f64) else r;
}

fn mulOp(a: f64, b: f64) f64 {
    return a * b;
}
fn divOp(a: f64, b: f64) f64 {
    return a / b;
}
fn powOp(a: f64, b: f64) f64 {
    return math.pow(f64, a, b);
}

/// Endpoint-combination for the non-monotone binary ops: all four corners,
/// closed result (openness is not derivable through a product). A NaN corner
/// (0*inf, 0/0, inf/inf) means the abstraction cannot say anything ⇒ ⊤.
fn combine(x: Interval, y: Interval, f: *const fn (f64, f64) f64) Interval {
    const c = [4]f64{ f(x.lo, y.lo), f(x.lo, y.hi), f(x.hi, y.lo), f(x.hi, y.hi) };
    var lo = math.inf(f64);
    var hi = -math.inf(f64);
    for (c) |v| {
        if (math.isNan(v)) return .top;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    return .{ .lo = lo, .hi = hi };
}

fn absIv(a: Interval) Interval {
    if (a.ge(0)) return a;
    if (a.le(0)) return .{ .lo = -a.hi, .hi = -a.lo, .lo_open = a.hi_open, .hi_open = a.lo_open };
    return .{ .lo = 0, .hi = @max(@abs(a.lo), @abs(a.hi)) };
}

// LRM Table 4-14 / 4-15 scalar forms, as function pointers for the monotone path.
fn mId(x: f64) f64 {
    return x;
}
fn mExp(x: f64) f64 {
    return @exp(x);
}
fn mExpm1(x: f64) f64 {
    return math.expm1(x);
}
fn mLn(x: f64) f64 {
    return @log(x);
}
fn mLn1p(x: f64) f64 {
    return math.log1p(x);
}
fn mLog10(x: f64) f64 {
    return @log10(x);
}
fn mSqrt(x: f64) f64 {
    return @sqrt(x);
}
fn mSinh(x: f64) f64 {
    return math.sinh(x);
}
fn mCosh(x: f64) f64 {
    return math.cosh(x);
}
fn mTanh(x: f64) f64 {
    return math.tanh(x);
}
fn mAsinh(x: f64) f64 {
    return math.asinh(x);
}
fn mAcosh(x: f64) f64 {
    return math.acosh(x);
}
fn mAtanh(x: f64) f64 {
    return math.atanh(x);
}
fn mAtan(x: f64) f64 {
    return math.atan(x);
}
fn mAsin(x: f64) f64 {
    return math.asin(x);
}
fn mAcos(x: f64) f64 {
    return math.acos(x);
}
fn mFloor(x: f64) f64 {
    return @floor(x);
}
fn mCeil(x: f64) f64 {
    return @ceil(x);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Preprocessor = @import("preprocessor.zig");
const Lexer = @import("lexer.zig");
const Parser = @import("parser.zig");

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    low: Lower,
    bag: diag.Bag,

    fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .low = undefined,
            .bag = undefined,
        };
        const arena = out.arena_state.allocator();
        out.bag = diag.Bag.init(arena);
        const text = try Preprocessor.process(arena, src, .{ .bag = &out.bag });
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
        try out.low.lowerFile();
    }

    /// Run the prover against this harness's own bag, so a test can assert on
    /// the CODES that came out rather than on prose.
    fn prove(self: *Harness, gpa: std.mem.Allocator, opts: Options) !Verdict {
        return proveOpts(gpa, &self.mir, &self.low, opts, &self.bag);
    }

    fn has(self: *const Harness, code: diag.Code) bool {
        return self.find(code) != null;
    }

    fn find(self: *const Harness, code: diag.Code) ?diag.Entry {
        for (self.bag.messages()) |mi| {
            const e = self.bag.get(mi);
            if (e.code == code) return e;
        }
        return null;
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

test "W0650: a .strict unit warns, names the culprit, and still compiles" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module diode(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real is = 1e-14 from (0:inf);
        \\  analog I(a, c) <+ is * (exp(V(a, c)) - 1.0);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    // LEGAL: an unbounded exp is spec-faithful (§4.3.2 "All x"), so the model
    // is ACCEPTED — the warning is about speed, not correctness.
    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
    try std.testing.expect(!h.bag.failed());

    const e = h.find(.W0650) orelse return error.NoFinitenessWarning;
    try std.testing.expectEqual(diag.Severity.warning, e.severity);
    // The caret is on the contribution — the unit — not on some interior
    // instruction the user did not write.
    try std.testing.expect(!e.span.isNone());
    // The culprit is named. A probe is finite-but-unbounded, so `exp` of it is
    // what forfeits the proof.
    var lbuf: [diag.max_children]diag.Label = undefined;
    const labels = h.bag.labels(e, &lbuf);
    var mentions_probe = false;
    for (labels) |l| {
        if (std.mem.indexOf(u8, l.text, "probe") != null) mentions_probe = true;
    }
    try std.testing.expect(mentions_probe or std.mem.indexOf(u8, e.point, "probe") != null);
}

test "W0650: a fully-ranged model is provably finite and warns about nothing" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1.0 from (0:inf);
        \\  analog I(p, n) <+ V(p, n) / rs;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
    try std.testing.expect(!h.has(.W0650));
}

test "W0650: unknown_bound recovers the proof, and the warning goes away with it" {
    const src =
        \\module amp(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
    ;
    var loose: Harness = undefined;
    try Harness.run(std.testing.allocator, src, &loose);
    defer loose.deinit();
    const a = try loose.prove(std.testing.allocator, .{});
    defer a.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.strict, a.unit_modes[0]);
    try std.testing.expect(loose.has(.W0650));

    // The compliance limit is a property of the host's solver, not of the
    // language — declaring it is what makes the transcendental provable.
    var tight: Harness = undefined;
    try Harness.run(std.testing.allocator, src, &tight);
    defer tight.deinit();
    const b = try tight.prove(std.testing.allocator, .{ .unknown_bound = 100 });
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.optimized, b.unit_modes[0]);
    try std.testing.expect(!tight.has(.W0650));
}

test "W0650: --allow silences it without changing the verdict" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module amp(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
    , &h);
    defer h.deinit();

    try h.bag.levels.set(h.arena_state.allocator(), .W0650, .allow);
    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(!h.has(.W0650));
    // Silencing the warning does NOT silence the consequence.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "W0651: a range closed on infinity is called out separately" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1.0 from [0:inf];
        \\  analog I(p, n) <+ V(p, n) / rs;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    const e = h.find(.W0651) orelse return error.NoRangeWarning;
    try std.testing.expect(std.mem.indexOf(u8, e.message, "rs") != null);
    // It points at the DECLARATION, which is where the fix goes.
    try std.testing.expect(!e.span.isNone());
    // ...and the closed bound really did cost the unit its proof.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
    try std.testing.expect(h.has(.W0650));
}

test "§3.4.2: an `exclude` proves nonzero only where its bracket is square" {
    // The three exclusions that differ ONLY in whether 0 is inside them. The
    // first still admits 0, so the divide is not provably safe and the unit has
    // to stay `.strict`; the other two really do remove 0 and earn `.optimized`.
    // Reading `(0:5)` as if it excluded its endpoints' *values* is unsound in
    // the dangerous direction: it hands fast-math a divisor the range permits
    // to be zero.
    const cases = [_]struct { range: []const u8, mode: FloatMode }{
        .{ .range = "exclude (0:5)", .mode = .strict },
        .{ .range = "exclude [0:5]", .mode = .optimized },
        .{ .range = "exclude 0", .mode = .optimized },
        // The open end that is NOT at zero must not change the verdict.
        .{ .range = "exclude (-5:0]", .mode = .optimized },
        .{ .range = "exclude [-5:0)", .mode = .strict },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  parameter real x = 1.0 from [-10:10] {s};
            \\  analog I(p, n) <+ V(p, n) / x;
            \\endmodule
        , .{c.range});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const v = try h.prove(std.testing.allocator, .{});
        defer v.deinit(std.testing.allocator);

        std.testing.expectEqual(c.mode, v.unit_modes[0]) catch |e| {
            std.debug.print("range: {s}\n", .{c.range});
            return e;
        };
    }
}

test "class-6 errors carry a real source span (Mir.InstRow.tok)" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer d = 0;
        \\  analog I(p, n) <+ V(p, n) * (10 / d);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);
    try std.testing.expect(!v.ok());

    const e = h.find(.E0601) orelse return error.NoDivisorError;
    // The whole point of the provenance column: this used to be 0:0.
    try std.testing.expect(!e.span.isNone());
    // And the span must land on the source the user wrote, not the prelude.
    const src_text = h.bag.fileText(h.bag.locate(e.span, e.file).file);
    try std.testing.expect(std.mem.indexOf(u8, src_text, "10 / d") != null);
}

test "proof: unbounded voltage exp is .strict, never an error (LRM 4.3.2 'All x')" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module diode(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real is = 1e-14 from (0:inf);
        \\  parameter real vt = 0.026 from (0:inf);
        \\  analog I(a,c) <+ is * (exp(V(a,c)/vt) - 1.0);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // exp is NEVER rejected
    try std.testing.expectEqual(@as(usize, 1), v.unit_modes.len);
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: a §3.4.2 range discharges the ln domain and proves the unit finite" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module r(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real rs = 1k from (0:inf);
        \\  analog I(p,n) <+ ln(rs) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
    try std.testing.expectEqual(FloatMode.optimized, v.unit_modes[0]);
}

test "proof: an UNPROVABLE ln domain is accepted and forced .strict (LRM 4.3.2)" {
    // §4.3.2 obliges reporting a value that IS out of range, not rejecting a
    // program whose values MIGHT be. `k` is unranged, so ln(k) straddles the
    // domain boundary: accept it, and forfeit `.optimized`.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real k = 1.0;
        \\  analog I(p,n) <+ ln(k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // accepted — the LRM permits it
    // THE SAFETY PROPERTY: a NaN-capable unit must never reach `.optimized`,
    // whose `nnan` assertion it would violate (silent, Release-only UB).
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: a PROVABLY-violated ln domain is still an error (LRM 4.3.2 'shall report')" {
    // Entirely negative range: statically decidable, so the §4.3.2 error
    // obligation is discharged at compile time.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad2(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real k = -2.0 from [-10:-1];
        \\  analog I(p,n) <+ ln(k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(!v.ok());
    try std.testing.expect(h.has(.E0602));
    const e = h.find(.E0602).?;
    try std.testing.expect(std.mem.indexOf(u8, e.message, "ln()") != null);
    try std.testing.expect(std.mem.indexOf(u8, e.message, "parameter `k`") != null);
    // The location is the whole point of Mir.InstRow.tok: class-6 diagnostics
    // used to report at 0:0.
    try std.testing.expect(!e.span.isNone());
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: a dominating §5.8 guard discharges the domain of a node probe" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module g(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    if (V(p,n) > 0.0)
        \\      I(p,n) <+ ln(V(p,n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
}

test "proof: `/` by a possibly-zero divisor is ACCEPTED and forced .strict (LRM 4.2.4)" {
    // §4.2.4's only zero rule is "It shall be an error to pass zero (0) as the
    // second argument to the MODULUS operator" — division by zero is not an
    // error, it is an exact IEEE +-inf. This is the plain resistor `V/r`, the
    // most common statement in all of Verilog-A; rejecting it would make
    // FastVAF stricter than the LRM.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real a = 1.0;
        \\  parameter real b = 1.0 exclude 0;
        \\  analog I(p,n) <+ V(p,n)/a + V(p,n)/b;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok()); // `a` unranged is legal
    // ...but it can produce inf, so the unit forfeits fast-math. Without this
    // the `ninf` assertion of `.optimized` is violated at run time only.
    try std.testing.expectEqual(FloatMode.strict, v.unit_modes[0]);
}

test "proof: integer `/` and `%` by a possibly-zero divisor remain errors (LRM 4.2.4)" {
    // No IEEE escape for integers: Zig's @divTrunc/@rem by zero is illegal
    // behavior, so a static proof is the only sound option.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer k = 1;
        \\  analog I(p,n) <+ (10 % k) * V(p,n);
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(!v.ok());
    try std.testing.expect(h.has(.E0601));
    try std.testing.expect(std.mem.indexOf(u8, h.find(.E0601).?.message, "divisor") != null);
}

test "proof: the §4.2.12 select guard covers `x > 0 ? ln(x) : 0`" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module s(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ (V(p,n) > 0.0) ? ln(V(p,n)) : 0.0;
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expect(v.ok());
}

test "proof: the unit count is the contribution count (the naming.zig contract)" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module two(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1p;
        \\  analog begin
        \\    I(p,n) <+ V(p,n);
        \\    I(p,n) <+ ddt(c * V(p,n));
        \\    V(p,n) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    const v = try h.prove(std.testing.allocator, .{});
    defer v.deinit(std.testing.allocator);

    try std.testing.expectEqual(unitCount(&h.low), v.unit_modes.len);
    try std.testing.expectEqual(@as(usize, 2), v.unit_modes.len);
}

test "proof: Options.unknown_bound is the calibration knob for a real solver" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module e(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  analog I(a,c) <+ exp(V(a,c));
        \\endmodule
    , &h);
    defer h.deinit();

    const loose = try h.prove(std.testing.allocator, .{});
    defer loose.deinit(std.testing.allocator);
    try std.testing.expectEqual(FloatMode.strict, loose.unit_modes[0]);

    // A host that clamps its unknowns to a compliance limit gets the fast path.
    const tight = try h.prove(std.testing.allocator, .{ .unknown_bound = 100 });
    defer tight.deinit(std.testing.allocator);
    try std.testing.expect(tight.ok());
    try std.testing.expectEqual(FloatMode.optimized, tight.unit_modes[0]);
}
