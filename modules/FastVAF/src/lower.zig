//! Classes 3,4,5,7,9 — AST → MIR lowering + the type/discipline/param/branch
//! tables. This is the largest frontend file; it realizes most of the LRM.
//!
//! Transformation: ast.SourceFile → Mir + Lower side tables (params, branches,
//! contributions, node_order) consumed by proof.zig and codegen.zig.
//!
//! DOD: side tables are SoA (parallel slices), keyed by small integer ids.
//! node_order defines the U-enum index; keep it stable (codegen depends on it).
//!
//! FILE-AS-STRUCT: `@import("lower.zig")` is both the namespace
//! (`Lower.ParamInfo`) and the type (`lower: *const Lower`), exactly like
//! mir.zig. proof.zig / naming.zig / codegen.zig already spell it that way.

const std = @import("std");
const Ast = @import("ast.zig");
const Mir = @import("mir.zig");
const Ssa = @import("ssa.zig");
const Lexer = @import("lexer.zig");
const diag = @import("diag.zig");
const assert = std.debug.assert;

pub const Lower = @This(); // so `Lower.Lower` also resolves

/// Only OOM unwinds during lowering; everything else goes in the shared
/// `diag.Bag` and lowering continues with a poison value, so one run reports
/// many errors.
const Oom = std.mem.Allocator.Error;
pub const Error = Oom || error{ DiagnosticsReported, NoModule };

/// Class 3 — a resolved parameter. LRM §3.4.
pub const ParamInfo = struct {
    name: []const u8,
    /// Token of the declaration, so a class-6 diagnostic can point a label at
    /// "`k` declared here" and hang a `from (0:inf)` suggestion off it.
    tok: u32 = Mir.no_tok,
    ty: Ast.Type,
    default: Mir.Value,
    /// LRM §3.4.2. CRITICAL: carry ranges here from Ast.ParamDecl.ranges.
    /// proof.zig (class 6) uses these as the bound evidence. Historically this
    /// field did not exist and ranges were dropped — that is the class-6 gap.
    ranges: []const Ast.ValueRange = &.{},
    /// §3.4.5 localparam: not part of the model card ABI.
    is_local: bool = false,
};

/// Class 4 — a branch (pair of nodes carrying a flow/potential). LRM §3.12.
pub const BranchInfo = struct {
    hi: u16, // node_order index
    lo: u16, // node_order index (`ground` if implicit, §1.3.1.1)
};

/// §1.3.1.1 the global reference node. Not a solver unknown, so it is a
/// sentinel rather than a node_order slot: probing it yields a literal 0.
pub const ground: u16 = std.math.maxInt(u16);

/// §4.4 access-function flavour. `V(a,b)` is a potential, `I(a,b)` a flow;
/// user natures rename them (§3.6.1.4) but the two roles are closed.
pub const Access = enum(u8) { potential, flow };

/// Class 4 — a contribution target + its accumulated value. LRM §5.6.
///
/// ONE entry per (access, node pair), never one per `<+` statement: §5.6.1.3
/// makes `<+` an accumulation, and conditional contributions (§5.8) only make
/// sense as "the accumulator's value at the end of the analog block". Both fall
/// out of accumulating into an SSA place, so `resist_val`/`react_val` are the
/// final reads of that place. This is also the naming.zig unit target
/// (`I_drain_source`), so it is stable under source inserts.
///
/// Split into resistive (DC) and reactive (ddt/q) parts, §5.6.1.2.
pub const Contribution = struct {
    access: Access,
    /// Token of the `<+` this unit came from. proof.zig's W0650 reports
    /// per-unit, so it needs the STATEMENT, not the instruction that happened
    /// to break the finiteness proof.
    tok: u32 = Mir.no_tok,
    hi: u16, // node_order index (or `ground`)
    lo: u16, // node_order index (or `ground`)
    resist_val: Mir.Value = .f_zero, // → eval()
    react_val: Mir.Value = .f_zero, // → q()   (§4.5.3 ddt)
    noise_kind: ?NoiseKind = null, // §4.6.4
    /// §5.6.7 `V(out) : V(in) == e` is the SAME topology as a direct potential
    /// contribution — a source in the branch, its current an unknown — with a
    /// different constitutive row. `.direct` carries `V(hi,lo) − resist_val`;
    /// `.indirect` carries `resist_val` alone (= probe − equation), because the
    /// branch voltage is precisely what is being solved for (a nullor).
    ///
    /// A `.indirect` entry is NEVER deduped by `contribIndex`: §5.6.1.3
    /// accumulation is a property of `<+`, and each indirect statement is its
    /// own equation with its own source.
    kind: Kind = .direct,
};

pub const Kind = enum(u8) { direct, indirect };

/// §5.4.3 one probed module port: the port's node_order slot and the
/// node_order slot of the flow unknown that carries `I(<port>)`.
pub const PortProbe = struct { port: u16, u: u16 };

pub const NoiseKind = enum(u8) { thermal, flicker }; // §4.6.4.1/.2

/// §3.6.1.2 tolerances of a discipline's two natures. Recorded for proof.zig
/// and for codegen's per-node abstol; nothing here consumes it.
pub const DisciplineInfo = struct {
    potential_abstol: f64 = 1e-6,
    flow_abstol: f64 = 1e-12,
    is_discrete: bool = false, // §3.6.2.2
    /// §3.6.2.1 a CONSERVATIVE discipline binds both a potential and a flow
    /// nature; §3.6.2.2 a SIGNAL-FLOW discipline binds only one. Codegen needs
    /// the distinction: a contribution to a signal-flow net has no KCL meaning.
    has_potential: bool = false,
    has_flow: bool = false,
};

/// Value type of a lowered expression. LRM §3.1 — the analog kernel only has
/// these three; `Ast.Type.unspecified` is resolved before it reaches here.
pub const Ty = enum(u8) { real, integer, string };

/// A lowered expression: its Value plus the LRM type that governs which opcode
/// family the *consumer* must use (§4.2.1.1–§4.2.1.3 implicit conversions).
pub const TypedValue = struct { v: Mir.Value, ty: Ty };

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

arena: std.mem.Allocator,
mir: *Mir,
file: *const Ast.SourceFile,
builder: Ssa.SsaBuilder,
/// The block statements are currently being appended to.
cur: Mir.Block = .entry,

// ---- class 3 side tables (the codegen/proof contract) ----
params: std.ArrayList(ParamInfo) = .empty, // §3.4
/// Deduped `param_ref` Value per params[i] — parallel to `params`.
param_values: std.ArrayList(Mir.Value) = .empty,
branches: std.StringHashMapUnmanaged(BranchInfo) = .empty, // §3.12 named branches
contributions: std.ArrayList(Contribution) = .empty, // §5.6
/// The U-enum index space: ports (§6.5) first, then internal nodes (§3.6.3),
/// then branch-flow unknowns (§5.4.2). Append-only ⇒ stable.
node_order: std.ArrayList([]const u8) = .empty,
/// Discipline name per node_order slot (`""` when undeclared, §3.9).
node_disciplines: std.ArrayList([]const u8) = .empty,
/// §6.5.2.2 port direction per node_order slot. Only `input`/`output` are
/// recorded (`false` for `inout`, an internal net, or an undeclared direction):
/// a DIRECTIONAL port is the one place the LRM's signal-flow port model
/// (§1.3.4) is unambiguous, and codegen has to refuse those.
node_directional: std.ArrayList(bool) = .empty,
/// §5.4.3 ports read with `I(<p>)`, in first-probe order, deduped. Each needs
/// its own solver unknown (`u`) and a row pinning it to the module's KCL sum
/// at `port`; codegen emits that row. Append-only ⇒ deterministic.
port_probes: std.ArrayList(PortProbe) = .empty,
num_ports: usize = 0, // §6.5
node_voltages: std.StringHashMapUnmanaged(u16) = .empty, // §1.3.1 name → index
disciplines: std.StringHashMapUnmanaged(DisciplineInfo) = .empty, // §3.6.2

// ---- internal lowering state (not part of the codegen contract) ----
/// Deduped probe Value per node_order slot; `.undef` = not probed yet.
probe_cache: std.ArrayList(Mir.Value) = .empty,
/// Accumulator places, parallel to `contributions`.
accum: std.ArrayList(Accum) = .empty,
/// Preprocessed source and the lexer's `.start` column, kept ONLY so a token
/// index can become a `diag.Span`. proof.zig reaches them through
/// `tokenSpan` too — it holds a `*const Lower` already, so this is the whole
/// reason class-6 diagnostics have a source location.
src: []const u8 = "",
tok_starts: []const u32 = &.{},
/// Where every diagnostic of this compilation goes. Shared with the other
/// stages, so the cap, the dedupe and the source order are global.
bag: *diag.Bag = undefined,
/// Set by `err`; `lowerFile` reads it. NOT `bag.entries.len`, which the cap
/// and the dedupe both make an unreliable answer to "did lowering fail".
had_error: bool = false,
/// §3.6.1.4 access identifier → which half of the discipline it reads.
access_kind: std.StringHashMapUnmanaged(Access) = .empty,
/// Visible variables (§3.2) — locals, function args, scalarized array elements.
vars: std.StringHashMapUnmanaged(VarSlot) = .empty,
/// Undo log so named blocks (§5.3.2) and inlined functions (§4.7) can shadow.
scope_log: std.ArrayList(ScopeEntry) = .empty,
/// §3.4 parameters and §3.5 genvars visible to constant evaluation.
consts: std.StringHashMapUnmanaged(Const) = .empty,
/// name → index into `params` (aliasparam §3.4.7 maps two names to one index).
param_index: std.StringHashMapUnmanaged(u32) = .empty,
/// Scalarized array bounds (§3.2.2 variables, §3.4.4 parameters).
arrays: std.StringHashMapUnmanaged(ArrayInfo) = .empty,
/// §5.9 break/continue targets.
loops: std.ArrayList(LoopCtx) = .empty,
/// §4.7.1 the function currently being inlined (return slot + exit block).
ret: ?RetCtx = null,
/// §4.7.1 recursion guard — names on the inline stack.
inlining: std.ArrayList([]const u8) = .empty,
/// Non-null inside an `analog initial` block (§5.2.1) or an analog function
/// (§4.7.2); names the context in the "not allowed here" diagnostic.
restrict: ?[]const u8 = null,
/// True while lowering the body of an `@(...)` — i.e. while the statement
/// position is A.6.4 `analog_event_statement` rather than `analog_statement`.
/// The two productions differ in BOTH directions, so this flag gates two
/// distinct rules: `disable_statement`/`event_trigger` are legal only when it
/// is set, and `contribution_statement`/`indirect_contribution_statement` and a
/// nested `analog_event_control_statement` are legal only when it is clear
/// (§5.10 states the last three as prose restrictions as well).
in_event_stmt: bool = false,
/// §5.6.7 "Indirect branch contributions shall not be used in conditional or
/// looping statements, unless the conditional expression is a constant
/// expression". Incremented only on the paths that actually emit a branch —
/// the constant-folded `if` and the unrolled genvar `for` lower their body
/// straight into `self.cur` and never come through `lowerCondBody`.
cond_depth: u32 = 0,
/// §5.8.1's carve-out, counted in parallel with `cond_depth`: how many of the
/// enclosing runtime conditionals had an A.8.3 `analysis_or_constant_expression`
/// for their condition. `cond_depth == static_cond_depth` therefore means
/// "every enclosing conditional is decided before the solve starts", which is
/// exactly when an analog operator's history stays whole (E0514).
///
/// A LOOP body never raises it: §5.9 bans analog filter functions in `repeat`,
/// `while` and non-genvar `for` with no carve-out at all, so a loop must always
/// leave `cond_depth > static_cond_depth`.
///
/// Kept SEPARATE from `cond_depth` rather than replacing it, because the two
/// answer different questions: §5.6.7 (indirect contributions) and §5.8/§5.10.3.1
/// (event control) ask for a CONSTANT condition, which `analysis("dc")` is not.
static_cond_depth: u32 = 0,
/// The module being lowered (§6.2). Set by `lowerModule`.
module: ?*const Ast.ModuleDecl = null,
/// §9.17.2 `$bound_step` / §9.17.1 `$discontinuity`. Each is an SSA place
/// seeded to +inf ("nothing asked for") in the ENTRY block and `fmin`-ed at
/// every call site, exactly like a contribution accumulator: a call under an
/// `if` therefore reaches the exit through a phi and does NOT bound the step on
/// the arm that never executed. `lowerModule` reads the final value and emits
/// ONE synthetic `call`, which is what naming.zig turns into a unit and
/// codegen's `updateState` writes into `Instance`. Null = the model never
/// called the task, so no unit and no state write.
bound_step_place: ?Ssa.Place = null,
disc_place: ?Ssa.Place = null,
/// §9.4 display tasks, in source order. A display call's RESULT is never read,
/// so it is dead code the moment codegen slices a unit out of the MIR — and the
/// print vanishes with it. `display_root` is the one live root that keeps them
/// all: see `finishDisplays`.
displays: std.ArrayList(Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing. codegen turns it into ONE unit function whose
/// body is the prints, in source order.
display_root: Mir.Value = .f_zero,
/// §5.10 module variables assigned inside an `@(<event>)` body, in declaration
/// order. Such a variable RETAINS its value between analog evaluations — that
/// is the entire point of `@(cross(...)) x = V(p);`, and an ordinary SSA place
/// cannot express it, because every module variable is re-initialised from its
/// declaration at the top of every evaluation. Each entry gets a persistent
/// `Instance` slot instead; codegen reads it directly.
held_vars: std.ArrayList(HeldVar) = .empty,
/// Source names `markHeldVars` found under an `@(...)`, collected BEFORE the
/// module's variables are declared. Empty for a module with no event control.
held_names: std.StringHashMapUnmanaged(void) = .empty,

/// One §5.10 event-assigned module variable and its persistent slot.
pub const HeldVar = struct {
    /// Source spelling, INCLUDING the `[i]` of a scalarized array element
    /// (§3.2.2). Unique within the module scope, so codegen's `Instance` field
    /// name is injective after `naming.sanitize`.
    name: []const u8,
    ty: Ty,
    /// The declared initializer. Only reachable on the FIRST evaluation, so
    /// codegen renders it as the `Instance` field's default and nowhere else.
    init: Mir.Value,
    /// The `$held_*` call seeded into the ENTRY block. Reading the variable
    /// anywhere — including lexically before the `@(...)` — reads this, i.e.
    /// the value the last accepted evaluation left behind.
    seed: Mir.Value,
    /// The variable's value at the END of the analog block; `updateState`
    /// stores it back on the accepted solution. Filled by `finishHeldVars`.
    final: Mir.Value = .undef,
    place: Ssa.Place,
};

/// One §9.4/§9.7.3 print site.
pub const Display = struct {
    /// The synthetic `call`. Its first argument is the §2.7 format string.
    val: Mir.Value,
    /// The task's exact spelling — `$strobe`, `$write`, `$error`, … Codegen
    /// needs it for the newline rule (§9.4.1: `$write` does not append one) and
    /// for the §9.7.3 severity prefix.
    name: []const u8,
    /// The call token, for W0850/W0851.
    tok: u32,
    /// The call sits under an `if` or a loop. §9.4.6 makes emission a runtime
    /// property of the solve, which a hoisted unit root cannot express, and the
    /// value would not dominate the chain root either — so it is NOT emitted.
    conditional: bool,
};

const VarSlot = struct { place: Ssa.Place, ty: Ty };
const ScopeEntry = struct { name: []const u8, prev: ?VarSlot };
const ArrayInfo = struct { lo: i64, hi: i64, ty: Ty };
const LoopCtx = struct { brk: Mir.Block, cont: Mir.Block };
const RetCtx = struct { slot: VarSlot, exit: Mir.Block };
const Accum = struct { resist: Ssa.Place, react: Ssa.Place };

/// A folded constant (§4.2 constant_expression). Genvars (§3.5) and parameter
/// defaults live here so `for (i=0;i<N;i=i+1)` can unroll (§6.6.1).
pub const Const = union(enum) {
    int: i64,
    real: f64,
    str: []const u8,

    pub fn asReal(c: Const) f64 {
        return switch (c) {
            .int => |i| @floatFromInt(i),
            .real => |r| r,
            .str => 0,
        };
    }
    pub fn asInt(c: Const) i64 {
        return switch (c) {
            .int => |i| i,
            // §4.2.1.1 real→integer rounds, ties away from zero.
            .real => |r| @intFromFloat(@round(r)),
            .str => 0,
        };
    }
    pub fn isTrue(c: Const) bool {
        return switch (c) {
            .int => |i| i != 0,
            .real => |r| r != 0,
            .str => |s| s.len != 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// `mir` must be empty (this pass owns block 0). `file` and every string in it
/// are BORROWED and must outlive the Lower (both live in the arena).
pub fn init(
    arena: std.mem.Allocator,
    mir: *Mir,
    file: *const Ast.SourceFile,
    src: []const u8,
    tok_starts: []const u32,
    bag: *diag.Bag,
) Lower {
    assert(mir.blockCount() == 0);
    return .{
        .arena = arena,
        .mir = mir,
        .file = file,
        .src = src,
        .tok_starts = tok_starts,
        .bag = bag,
        .builder = Ssa.SsaBuilder.init(arena, mir),
    };
}

/// Frees the side tables and the SSA scratch. A no-op under an arena; present
/// so the whole pass runs leak-free on `std.testing.allocator`.
pub fn deinit(self: *Lower) void {
    const gpa = self.arena;
    self.builder.deinit();
    self.params.deinit(gpa);
    self.param_values.deinit(gpa);
    self.branches.deinit(gpa);
    self.contributions.deinit(gpa);
    self.node_order.deinit(gpa);
    self.node_disciplines.deinit(gpa);
    self.node_directional.deinit(gpa);
    self.port_probes.deinit(gpa);
    self.node_voltages.deinit(gpa);
    self.disciplines.deinit(gpa);
    self.probe_cache.deinit(gpa);
    self.accum.deinit(gpa);
    self.access_kind.deinit(gpa);
    self.vars.deinit(gpa);
    self.scope_log.deinit(gpa);
    self.consts.deinit(gpa);
    self.param_index.deinit(gpa);
    self.arrays.deinit(gpa);
    self.loops.deinit(gpa);
    self.inlining.deinit(gpa);
    self.displays.deinit(gpa);
    self.held_vars.deinit(gpa);
    self.held_names.deinit(gpa);
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Byte range of a token — the currency every diagnostic reports in.
/// `pub` because proof.zig maps a `Mir.Inst` back to source through it.
pub fn tokenSpan(self: *const Lower, tok: u32) diag.Span {
    return Lexer.tokenSpan(self.src, self.tok_starts, tok);
}

pub fn exprSpan(self: *const Lower, e: Ast.ExprId) diag.Span {
    return self.tokenSpan(self.file.exprs.mainTok(e));
}

/// Record an error and keep going. Callers substitute a poison value; nothing
/// downstream runs because `lowerFile` fails at the end.
fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    self.had_error = true;
    return self.bag.add(.lower, code, self.tokenSpan(tok), fmt, args);
}

fn errAt(self: *Lower, e: Ast.ExprId, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    return self.err(self.file.exprs.mainTok(e), code, fmt, args);
}

/// Same, for a diagnostic that wants a label, a note or a suggestion. The
/// caller must `emit()`.
fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder {
    self.had_error = true;
    return self.bag.build(.lower, code, self.tokenSpan(tok));
}

fn errAtWith(self: *Lower, e: Ast.ExprId, code: diag.Code) diag.Builder {
    return self.errWith(self.file.exprs.mainTok(e), code);
}

/// A poison real. Lowering continues so the run reports every error at once.
const poison: TypedValue = .{ .v = .undef, .ty = .real };

// ---------------------------------------------------------------------------
// Small MIR helpers
// ---------------------------------------------------------------------------

fn newBlock(self: *Lower) Oom!Mir.Block {
    return self.mir.addBlock(self.arena);
}

fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value {
    return self.mir.emit(self.arena, self.cur, op, ops);
}

fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value {
    const callee = try self.mir.internString(self.arena, name);
    return self.mir.emitCall(self.arena, self.cur, callee, args);
}

fn fconst(self: *Lower, x: f64) Oom!Mir.Value {
    return self.mir.addFloatConst(self.arena, x);
}

fn iconst(self: *Lower, x: i64) Oom!Mir.Value {
    return self.mir.addIntConst(self.arena, x);
}

/// Close `self.cur` with a jump and register the CFG edge (ssa.zig requires the
/// edge before the target is sealed).
fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void {
    _ = try self.mir.emitJump(self.arena, self.cur, target);
    try self.builder.addPredecessor(target, self.cur);
}

/// Start a fresh predecessor-less block. Everything appended to it is dead
/// (post-`break`/`return` code, §5.9/§4.7.1); sealing it immediately keeps the
/// SSA builder from ever waiting on an edge that will not arrive.
fn startUnreachable(self: *Lower) Oom!void {
    const b = try self.newBlock();
    try self.builder.sealBlock(b);
    self.cur = b;
}

// ---------------------------------------------------------------------------
// Type coercion — LRM §4.2.1.1 (real→integer), §4.2.1.2 (integer→real)
// ---------------------------------------------------------------------------

fn toReal(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    return switch (tv.ty) {
        .real => tv.v,
        .integer => self.emit(.if_cast, &.{tv.v}),
        .string => tv.v, // already diagnosed at the use site
    };
}

fn toInt(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    return switch (tv.ty) {
        .integer => tv.v,
        .real => self.emit(.fi_cast, &.{tv.v}),
        .string => tv.v,
    };
}

/// §4.2.8 — a condition is "true" when non-zero. Normalized to integer 0/1 so
/// `logand`/`logor`/`branch` all see the same shape.
fn toBool(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    return switch (tv.ty) {
        .integer => self.emit(.ine, &.{ tv.v, .zero }),
        .real => self.emit(.fne, &.{ tv.v, .f_zero }),
        .string => .zero,
    };
}

/// §4.2.1 — an operation with one real operand is performed in real.
fn unify(a: Ty, b: Ty) Ty {
    if (a == .string or b == .string) return .string;
    return if (a == .real or b == .real) .real else .integer;
}

fn astTy(t: Ast.Type) Ty {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .integer,
        .string => .string,
    };
}

// ---------------------------------------------------------------------------
// Class 9 — elaboration (LRM ch6)
// ---------------------------------------------------------------------------

/// Entry point: lower the file's module. LRM §6.2.
///
/// One flat module is the whole scope today (§6.2.2 instantiation is rejected
/// by the parser), so the FIRST module declaration is the device; later ones
/// would only be reachable through instantiation.
pub fn lowerFile(self: *Lower) Error!void {
    if (self.file.modules.len == 0) return error.NoModule;
    try self.lowerModule(&self.file.modules[0]);
    if (self.had_error) return error.DiagnosticsReported;
}

/// LRM §6.2/§6.9. Register ports (§6.5) into node_order, elaborate the
/// declarations, then lower each analog block (§5.2) in source order —
/// multiple analog blocks are executed as if concatenated (§6.9.1).
pub fn lowerModule(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    self.module = module;
    self.mir.name = self.file.str(module.name);

    const entry = try self.newBlock();
    assert(entry == .entry);
    try self.builder.sealBlock(entry);
    self.cur = entry;

    try self.collectDisciplines(); // §3.6.1/§3.6.2 (annex D.1 is inlined here)

    // §6.5 ports first: this order IS the host device's terminal order.
    for (module.ports) |p| {
        if (p.range != null) {
            try self.err(p.main_tok, .E0301, "", .{});
            continue;
        }
        const idx = try self.internNode(self.file.str(p.name), self.strOrEmpty(p.discipline));
        // §6.5.2.2. Recorded here and nowhere else: only a port can be
        // directional, and this loop is the only place the direction is known.
        self.node_directional.items[idx] = p.direction == .input or p.direction == .output;
    }
    self.num_ports = self.node_order.items.len;

    // §3.6.3 internal nets, then §3.6.4 ground.
    for (module.nets) |n| {
        const name = self.file.str(n.name);
        if (n.range != null) {
            try self.err(n.main_tok, .E0302, "", .{});
            continue;
        }
        if (n.is_ground) {
            try self.node_voltages.put(self.arena, name, ground);
            continue;
        }
        _ = try self.internNode(name, self.strOrEmpty(n.discipline));
    }

    // §3.4 parameters in source order — a later default may reference an
    // earlier parameter (§6.3.4), which is why `consts` is filled as we go.
    for (module.params) |*p| try self.lowerParamDecl(p);
    // §3.4.7 aliasparam: a second name for an existing parameter.
    for (module.aliasparams) |a| {
        const target = self.file.str(a.target);
        const alias = self.file.str(a.alias);
        // §3.4.7 "The alias_identifier shall not occur anywhere else in the
        // module; in particular, it shall not conflict with a different
        // parameter_identifier". Unchecked, the `put` below REBINDS the
        // colliding name for the rest of the module: every equation that says
        // `alias` quietly reads `target` instead, and the model card's `alias`
        // field goes dead. Nothing else in the file looks wrong.
        if (self.param_index.contains(alias)) {
            var b = self.errWith(module.main_tok, .E0331);
            b.msg("`{s}`", .{alias});
            b.help("an `aliasparam` gives `{s}` a second NAME, it does not declare a second parameter", .{target});
            try b.emit();
            continue;
        }
        if (self.param_index.get(target)) |idx| {
            try self.param_index.put(self.arena, alias, idx);
        } else {
            var b = self.errWith(module.main_tok, .E0303);
            b.msg("`{s}`", .{target});
            if (diag.didYouMeanMap(self.arena, target, self.param_index)) |s|
                b.help("did you mean `{s}`?", .{s});
            try b.emit();
        }
    }

    // §3.12 named branches.
    for (module.branches) |b| {
        if (b.is_port_branch) {
            try self.err(b.main_tok, .E0304, "", .{});
            continue;
        }
        if (b.range != null) {
            try self.err(b.main_tok, .E0305, "", .{});
            continue;
        }
        const hi = try self.nodeOf(b.hi);
        const lo = if (b.lo == .none) ground else try self.nodeOf(b.lo);
        try self.branches.put(self.arena, self.file.str(b.name), .{ .hi = hi, .lo = lo });
    }

    // §3.5 genvars exist only for unrolling; they carry no runtime storage.
    // §3.2/§3.3 module-level variables. The §5.10 scan runs FIRST: whether a
    // variable needs a persistent slot is decided at its declaration, not at
    // the assignment that reveals it — see `holdSlot`.
    try self.markHeldVars(module);
    for (module.vars) |*v| try self.declareVarDecl(v, .module);

    // §5.2 analog blocks, concatenated (§6.9.1).
    for (module.analog) |blk| {
        if (blk.is_initial) {
            // §5.2.1 executed once per analysis, before a matrix solution
            // exists. Guarded rather than split into a second CFG so codegen
            // keeps ONE walk; the guard is a call codegen answers from
            // `inst.analysis_kind`.
            const flag = try self.call("initial_step", &.{});
            const prev = self.restrict;
            self.restrict = "an analog initial block";
            try self.lowerGuarded(flag, blk.body);
            self.restrict = prev;
        } else {
            try self.lowerStmt(blk.body);
        }
    }

    // §5.6.1.3 the contribution accumulators' final values.
    for (self.contributions.items, self.accum.items) |*c, acc| {
        c.resist_val = try self.builder.readVariable(acc.resist, self.cur);
        c.react_val = try self.builder.readVariable(acc.react, self.cur);
    }
    // §5.10 the same, for every held variable. Reads only — no `call` — so the
    // unit enumeration below is untouched.
    for (self.held_vars.items) |*h| h.final = try self.builder.readVariable(h.place, self.cur);

    // §9.17 analog kernel control. Emitted LAST and in this fixed order so the
    // unit enumeration stays a pure function of the source.
    try self.finishKernelCtl();
    // §9.4 display tasks. AFTER the kernel-control calls on purpose: those two
    // become naming units, and inserting anything ahead of them would renumber
    // every Instance state field. The display chain adds no unit of its own.
    try self.finishDisplays();
}

/// §9.17.1/§9.17.2. Turn each accumulated kernel-control place into exactly one
/// synthetic `call`, whose single argument is the value the host must read.
/// `naming.enumerateUnits` gives that call a unit; `codegen.emitStateMachine`
/// evaluates the unit once per accepted step and stores it into `Instance`.
fn finishKernelCtl(self: *Lower) Oom!void {
    if (self.bound_step_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$bound_step", &.{v});
    }
    if (self.disc_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        _ = try self.call("$discontinuity", &.{v});
    }
}

/// §9.4 Chain every unconditional display call into ONE value, so codegen has a
/// single live root to slice a unit from. `fadd` is the cheapest carrier: the
/// operands are what matters, the sum is discarded, and rendering the sum walks
/// the operands in MIR order — which is source order.
///
/// Only `cond_depth == 0` calls join. They lie on the straight-line spine of the
/// analog block, so each one dominates `self.cur` here; a call inside an `if`
/// arm does not, and chaining it would be invalid SSA as well as the wrong
/// semantics (§9.4.6). Those are reported by the driver as W0851.
fn finishDisplays(self: *Lower) Oom!void {
    var root: Mir.Value = .f_zero;
    var first = true;
    for (self.displays.items) |d| {
        if (d.conditional) continue;
        root = if (first) d.val else try self.emit(.fadd, &.{ root, d.val });
        first = false;
    }
    self.display_root = root;
}

/// Fetch (creating on first use) a kernel-control place, seeded to +inf in the
/// entry block. `+inf` is the identity of `fmin` AND the correct "the model
/// asked for nothing" default for both tasks, so no separate "was it called"
/// flag has to survive the CFG.
fn kernelCtlPlace(self: *Lower, slot: *?Ssa.Place) Oom!Ssa.Place {
    if (slot.*) |p| return p;
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_inf);
    slot.* = p;
    return p;
}

fn strOrEmpty(self: *const Lower, id: Ast.StrId) []const u8 {
    return if (id == .none) "" else self.file.str(id);
}

// ---- §3.6 disciplines & natures --------------------------------------------

/// Build the discipline table and the §3.6.1.4 access-name map. The
/// preprocessor inlines annex D.1, so `electrical`/`thermal`/… arrive as
/// ordinary declarations in `file.disciplines`.
fn collectDisciplines(self: *Lower) Oom!void {
    // §4.4 the two standard access identifiers always resolve.
    try self.access_kind.put(self.arena, "V", .potential);
    try self.access_kind.put(self.arena, "I", .flow);

    for (self.file.disciplines) |*d| {
        var info: DisciplineInfo = .{
            .is_discrete = d.domain == .discrete,
            .has_potential = d.potential != .none,
            .has_flow = d.flow != .none,
        };
        if (d.potential != .none) {
            const n = self.natureOf(d.potential);
            if (n.abstol) |a| info.potential_abstol = a;
            if (n.access) |acc| try self.access_kind.put(self.arena, acc, .potential);
        }
        if (d.flow != .none) {
            const n = self.natureOf(d.flow);
            if (n.abstol) |a| info.flow_abstol = a;
            if (n.access) |acc| try self.access_kind.put(self.arena, acc, .flow);
        }
        // §3.6.2.3 discipline-level attribute overrides win over the nature's.
        for (d.overrides) |o| {
            if (!std.mem.eql(u8, self.file.str(o.attr.name), "abstol")) continue;
            const v = self.constEval(o.attr.value) orelse continue;
            switch (o.which) {
                .potential => info.potential_abstol = v.asReal(),
                .flow => info.flow_abstol = v.asReal(),
            }
        }
        try self.disciplines.put(self.arena, self.file.str(d.name), info);
    }
}

const NatureAttrs = struct { abstol: ?f64 = null, access: ?[]const u8 = null };

/// §3.6.1.1 walk a (possibly derived) nature for `abstol` (§3.6.1.2) and
/// `access` (§3.6.1.4). Derived natures inherit what they do not override.
fn natureOf(self: *Lower, name: Ast.StrId) NatureAttrs {
    var out: NatureAttrs = .{};
    var want = name;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const nat = for (self.file.natures) |*n| {
            if (n.name == want) break n;
        } else return out;
        for (nat.attrs) |a| {
            const an = self.file.str(a.name);
            if (out.abstol == null and std.mem.eql(u8, an, "abstol")) {
                if (self.constEval(a.value)) |c| out.abstol = c.asReal();
            } else if (out.access == null and std.mem.eql(u8, an, "access")) {
                if (self.file.exprs.tag(a.value) == .ident)
                    out.access = self.file.str(self.file.exprs.strOf(a.value));
            }
        }
        if (nat.parent == .none) return out;
        want = nat.parent;
    }
    return out;
}

// ---- §1.3.1 nodes ----------------------------------------------------------

/// Register (or find) a node. Undeclared names are implicit nets (§3.6.5), so
/// this never fails; registration order is source order ⇒ deterministic.
fn internNode(self: *Lower, name: []const u8, discipline: []const u8) Oom!u16 {
    const gop = try self.node_voltages.getOrPut(self.arena, name);
    if (gop.found_existing) {
        if (discipline.len != 0 and gop.value_ptr.* != ground)
            self.node_disciplines.items[gop.value_ptr.*] = discipline;
        return gop.value_ptr.*;
    }
    const idx: u16 = @intCast(self.node_order.items.len);
    assert(idx != ground);
    try self.node_order.append(self.arena, name);
    try self.node_disciplines.append(self.arena, discipline);
    try self.node_directional.append(self.arena, false);
    try self.probe_cache.append(self.arena, .undef);
    gop.value_ptr.* = idx;
    return idx;
}

/// Resolve a net reference expression (`.ident`) to a node_order index.
fn nodeOf(self: *Lower, e: Ast.ExprId) Oom!u16 {
    if (e == .none) return ground;
    if (self.file.exprs.tag(e) != .ident) {
        try self.errAt(e, .E0306, "", .{});
        return ground;
    }
    return self.internNode(self.file.str(self.file.exprs.strOf(e)), "");
}

/// The name codegen prints for a node_order index (naming.zig unit targets).
pub fn nodeName(self: *const Lower, idx: u16) []const u8 {
    return if (idx == ground) "gnd" else self.node_order.items[idx];
}

/// §4.4 potential probe of one node. Deduped so a node is one `block_param`
/// (codegen's `x[idx]`); ground is the literal 0 (§1.3.1.1).
fn probe(self: *Lower, idx: u16) Oom!Mir.Value {
    if (idx == ground) return .f_zero;
    if (self.probe_cache.items[idx] != .undef) return self.probe_cache.items[idx];
    const v = try self.mir.addBlockParam(self.arena, idx);
    self.probe_cache.items[idx] = v;
    return v;
}

/// §5.4.2 reading a flow (`I(a,b)`) makes the branch current a solver unknown
/// of its own. It gets a node_order slot so codegen indexes it like any other
/// `x[i]`; the parenthesised name cannot collide with an identifier.
fn flowUnknown(self: *Lower, hi: u16, lo: u16) Oom!u16 {
    const name = try std.fmt.allocPrint(self.arena, "flow({s},{s})", .{ self.nodeName(hi), self.nodeName(lo) });
    return self.internNode(name, "");
}

/// §5.4.3 the unknown carrying `I(<p>)`. Spelled `flow(<p>)` on purpose: it is
/// parenthesised (so no §2.7/§2.8.1 identifier can collide with it), it keeps
/// codegen's `flow(` prefix predicate — which classifies an unknown as a
/// CURRENT — correct with no change, and it can never be mistaken for a
/// `flow(a,b)` branch unknown (that form always has a comma).
fn portFlowUnknown(self: *Lower, p: u16) Oom!u16 {
    const name = try std.fmt.allocPrint(self.arena, "flow(<{s}>)", .{self.nodeName(p)});
    const u = try self.internNode(name, ""); // dedupes by name
    for (self.port_probes.items) |pp| {
        if (pp.port == p) return u;
    }
    try self.port_probes.append(self.arena, .{ .port = p, .u = u });
    return u;
}

// ---------------------------------------------------------------------------
// Class 3 — parameters (LRM §3.4) and variables (§3.2)
// ---------------------------------------------------------------------------

/// LRM §3.4. Register a parameter: infer its type (§3.4.1), fold its default,
/// and COPY decl.ranges into ParamInfo.ranges (§3.4.2 — the class-6 evidence).
pub fn lowerParamDecl(self: *Lower, decl: *const Ast.ParamDecl) Oom!void {
    const name = self.file.str(decl.name);

    // §3.4.4 array parameters are scalarized into `name[i]` entries.
    if (decl.dims.len != 0) return self.lowerParamArray(decl, name);

    const folded = self.constEval(decl.default);
    const ty: Ast.Type = if (decl.ty != .unspecified) decl.ty else switch (folded orelse Const{ .real = 0 }) {
        .int => .integer,
        .real => .real,
        .str => .string,
    };
    // §6.3.4 later defaults may reference this one.
    if (folded) |c| try self.consts.put(self.arena, name, c);

    const default: Mir.Value = if (folded) |c| switch (c) {
        .int => try self.iconst(c.asInt()),
        .real => try self.fconst(c.asReal()),
        .str => |s| try self.mir.addStrConst(self.arena, s),
    } else blk: {
        // Not constant-foldable (e.g. `parameter real b = a*2;` where `a` is
        // itself overridable): keep it as an expression over other params.
        const tv = try self.lowerExpr(decl.default);
        break :blk if (astTy(ty) == .real) try self.toReal(tv) else tv.v;
    };

    try self.addParam(name, ty, default, decl.ranges, decl.is_local, decl.main_tok);
}

fn addParam(
    self: *Lower,
    name: []const u8,
    ty: Ast.Type,
    default: Mir.Value,
    ranges: []const Ast.ValueRange,
    is_local: bool,
    tok: u32,
) Oom!void {
    const idx: u32 = @intCast(self.params.items.len);
    try self.params.append(self.arena, .{
        .name = name,
        .tok = tok, // §3.4.2 diagnostics point back at the declaration
        .ty = ty,
        .default = default,
        .ranges = ranges, // §3.4.2 — MUST reach proof.zig
        .is_local = is_local,
    });
    try self.param_values.append(self.arena, try self.mir.addParamRef(self.arena, idx));
    try self.param_index.put(self.arena, name, idx);
}

/// §3.4.4 `parameter real c[0:2] = '{1,2,3};` → three scalar parameters named
/// `c[0]`, `c[1]`, `c[2]`. Codegen emits one Model field each.
fn lowerParamArray(self: *Lower, decl: *const Ast.ParamDecl, name: []const u8) Oom!void {
    const dim = try self.dimBounds(decl.dims, decl.main_tok, name) orelse return;
    const ty: Ast.Type = if (decl.ty == .unspecified) .real else decl.ty;
    const elems: []const Ast.ExprId = if (decl.default != .none and
        self.file.exprs.tag(decl.default) == .assign_pattern)
        self.file.exprs.args(decl.default)
    else
        &.{};

    try self.arrays.put(self.arena, name, .{ .lo = dim.lo, .hi = dim.hi, .ty = astTy(ty) });
    var i = dim.lo;
    while (i <= dim.hi) : (i += 1) {
        const k: usize = @intCast(i - dim.lo);
        const elem = if (k < elems.len) elems[k] else Ast.ExprId.none;
        const default: Mir.Value = if (elem == .none)
            (if (astTy(ty) == .real) Mir.Value.f_zero else Mir.Value.zero)
        else if (self.constEval(elem)) |c|
            (if (astTy(ty) == .real) try self.fconst(c.asReal()) else try self.iconst(c.asInt()))
        else
            try self.toReal(try self.lowerExpr(elem));
        try self.addParam(try self.elemName(name, i), ty, default, decl.ranges, decl.is_local, decl.main_tok);
    }
}

const Bounds = struct { lo: i64, hi: i64 };

/// §3.2.2/§3.4.4 `[msb:lsb]`. Only one dimension is supported.
fn dimBounds(self: *Lower, dims: []const Ast.Dim, tok: u32, name: []const u8) Oom!?Bounds {
    if (dims.len != 1) {
        try self.err(tok, .E0307, "`{s}` has {d} dimensions", .{ name, dims.len });
        return null;
    }
    const a = self.constEval(dims[0].msb) orelse {
        try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
        return null;
    };
    const b = self.constEval(dims[0].lsb) orelse {
        try self.err(tok, .E0308, "in the bounds of `{s}`", .{name});
        return null;
    };
    const x = a.asInt();
    const y = b.asInt();
    return .{ .lo = @min(x, y), .hi = @max(x, y) };
}

/// The scalarized key for one array element, `name[i]` (§3.2.2, §3.4.4).
///
/// Only the two DECLARATION sites need this: `vars` and `param_index` retain
/// the key, so it has to outlive the call. Every *lookup* goes through
/// `elemKey` instead — see there.
fn elemName(self: *Lower, name: []const u8, i: i64) Oom![]const u8 {
    return std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ name, i });
}

/// Widest `name[i]` a legal model can produce: §2.7 caps an identifier at 1024
/// characters (the same source bound `naming.max_name_len` is sized from), plus
/// `[`, a 20-character `i64` and `]`.
const elem_key_len = 1024 + 22;

/// `name[i]` for a *lookup*, formatted into the caller's stack buffer.
///
/// `HashMap.get` only compares the key, it never retains it, so the arena copy
/// `elemName` makes is pure waste on this path — and it was paid once per
/// *reference*, so a `c[0]` read in a loop body leaked a fresh string every
/// time it was lowered. Now the arena sees `c[0]` once per compilation, at the
/// declaration. Same trick as `naming.zig`'s fixed key buffer, and safe for the
/// same reason: the slice never escapes the caller's frame.
///
/// ponytail: an over-long identifier falls back to the arena rather than
/// carrying a diagnostic of its own — it is already rejected upstream, and
/// silently truncating the key would alias two distinct elements.
fn elemKey(self: *Lower, buf: *[elem_key_len]u8, name: []const u8, i: i64) Oom![]const u8 {
    return std.fmt.bufPrint(buf, "{s}[{d}]", .{ name, i }) catch
        try self.elemName(name, i);
}

// ---- §3.2 variables and scopes ---------------------------------------------

fn openScope(self: *const Lower) usize {
    return self.scope_log.items.len;
}

fn closeScope(self: *Lower, mark: usize) void {
    while (self.scope_log.items.len > mark) {
        const e = self.scope_log.pop().?;
        if (e.prev) |p| {
            self.vars.putAssumeCapacity(e.name, p);
        } else {
            _ = self.vars.remove(e.name);
        }
    }
}

/// Bind `name` to a fresh SSA place, remembering what it shadowed (§5.3.2).
fn declareVar(self: *Lower, name: []const u8, ty: Ty) Oom!VarSlot {
    const slot: VarSlot = .{ .place = self.builder.newPlace(), .ty = ty };
    try self.scope_log.append(self.arena, .{ .name = name, .prev = self.vars.get(name) });
    try self.vars.put(self.arena, name, slot);
    return slot;
}

/// Where a `declareVarDecl` sits. Only a MODULE-level variable can take a
/// persistent §5.10 slot — see `holdSlot`.
const VarScope = enum { module, local };

/// §3.2 declare and initialize. Verilog-AMS variables start at zero, so a read
/// on a path that never assigned is 0 rather than the SSA builder's `.undef`
/// (which codegen could not emit).
fn declareVarDecl(self: *Lower, decl: *const Ast.VarDecl, scope: VarScope) Oom!void {
    const name = self.file.str(decl.name);
    const ty = astTy(decl.ty);
    // §5.10. `.string` is deliberately excluded: a string never reaches the
    // residual (§3.3 strings only feed §9.4 tasks, which re-run every
    // evaluation anyway), so a persistent slot for one would be storage
    // nothing can observe.
    const hold = scope == .module and ty != .string and self.held_names.contains(name);

    if (decl.dims.len != 0) {
        const dim = try self.dimBounds(decl.dims, decl.main_tok, name) orelse return;
        try self.arrays.put(self.arena, name, .{ .lo = dim.lo, .hi = dim.hi, .ty = ty });
        var i = dim.lo;
        while (i <= dim.hi) : (i += 1) {
            // §3.2.2 arrays are scalarized, so a held array is just one held
            // slot per element — `markHeldVars` records the base name and every
            // element takes a slot, since the index may be a runtime `case`.
            const en = try self.elemName(name, i);
            const slot = try self.declareVar(en, ty);
            const init_val = zeroOf(ty);
            try self.builder.writeVariable(slot.place, self.cur, if (hold)
                try self.holdSlot(en, ty, init_val, slot.place)
            else
                init_val);
        }
        return;
    }

    const slot = try self.declareVar(name, ty);
    const init_val: Mir.Value = if (decl.init == .none)
        zeroOf(ty)
    else if (ty == .real)
        try self.toReal(try self.lowerExpr(decl.init))
    else
        (try self.lowerExpr(decl.init)).v;
    try self.builder.writeVariable(slot.place, self.cur, if (hold)
        try self.holdSlot(name, ty, init_val, slot.place)
    else
        init_val);
}

/// §5.10. Give one event-assigned variable its persistent `Instance` slot and
/// return the Value that READS that slot.
///
/// The read replaces the declared initializer AT THE DECLARATION, which is the
/// whole reason the decision is made here and not at the assignment that
/// reveals it: a read of the variable that lexically precedes the `@(...)` must
/// also see the retained value, and by the time lowering reaches that
/// assignment the earlier read has already been resolved against the
/// initializer and memoized. Patching the entry def afterwards would leave it
/// stale.
///
/// `$held_real` / `$held_int` are synthetic callees — no LRM function has these
/// names, and `naming.isStatefulAnalogOp` rejects them, so they create no unit
/// and renumber no existing `Instance` state. The single argument is the index
/// into `held_vars`, which is how codegen recovers the field.
fn holdSlot(self: *Lower, name: []const u8, ty: Ty, init_val: Mir.Value, place: Ssa.Place) Oom!Mir.Value {
    // Emitted into the DECLARATION's block — `.entry`, unless the initializer
    // itself opened a diamond (§4.2.7 `&&`/`||` short-circuit), in which case it
    // is that diamond's join. Either way it dominates every statement of the
    // module, which is all the seed has to do.
    const idx: i64 = @intCast(self.held_vars.items.len);
    const seed = try self.call(if (ty == .integer) "$held_int" else "$held_real", &.{try self.iconst(idx)});
    try self.held_vars.append(self.arena, .{
        .name = name,
        .ty = ty,
        .init = init_val,
        .seed = seed,
        .place = place,
    });
    return seed;
}

/// §5.10. Collect the names assigned inside an `@(<event>)` body, before any of
/// them is declared.
///
// ponytail: MODULE-level variables only. A variable declared in a §5.3.2 named
// block inside the analog block still resets — its declaration is lowered once
// per execution of the block, so a slot keyed on the source name would collide
// with itself under a §6.6.1 unrolled `for`. Upgrade path: key the slot on the
// SSA place and give each re-declaration a group-local ordinal, the same way
// `naming.assignDisambig` does for same-target units.
fn markHeldVars(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    for (module.analog) |blk| try self.scanHeld(blk.body, false);
}

/// One walk, two modes: outside an event body we are only looking for the
/// `@(...)`; inside one, every assignment target names a variable that has to
/// survive to the next evaluation.
fn scanHeld(self: *Lower, id: Ast.StmtId, in_event: bool) Oom!void {
    if (id == .none) return;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try self.scanHeld(s, in_event),
        .assign => |a| {
            if (!in_event) return;
            const ex = &self.file.exprs;
            // §3.2.2 `x[i] = …` holds the ARRAY; `declareVarDecl` scalarizes it.
            const t = if (ex.tag(a.target) == .index) ex.lhs(a.target) else a.target;
            if (ex.tag(t) != .ident) return;
            try self.held_names.put(self.arena, self.file.str(ex.strOf(t)), {});
        },
        .if_stmt => |s| {
            try self.scanHeld(s.then_s, in_event);
            try self.scanHeld(s.else_s, in_event);
        },
        .case_stmt => |s| for (s.arms) |arm| try self.scanHeld(arm.body, in_event),
        .for_stmt => |s| {
            try self.scanHeld(s.init, in_event);
            try self.scanHeld(s.step, in_event);
            try self.scanHeld(s.body, in_event);
        },
        .while_stmt => |s| try self.scanHeld(s.body, in_event),
        .repeat_stmt => |s| try self.scanHeld(s.body, in_event),
        // §5.10 forbids nesting, so `true` is never re-entered; lowering
        // diagnoses that (E0703) and this walk does not need to.
        .event_control => |s| try self.scanHeld(s.body, true),
        else => {},
    }
}

fn zeroOf(ty: Ty) Mir.Value {
    return switch (ty) {
        .real => .f_zero,
        .integer => .zero,
        .string => .undef,
    };
}

// ---------------------------------------------------------------------------
// Class 4 — statements (LRM §5)
// ---------------------------------------------------------------------------

/// Dispatch one statement. LRM §5.
pub fn lowerStmt(self: *Lower, id: Ast.StmtId) Oom!void {
    if (id == .none) return;
    const tok = self.file.stmtTok(id);
    // Same provenance cursor as `lowerExpr`, for the instructions a statement
    // emits outside any expression (phis, jumps, accumulator writes).
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = tok;
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| try self.lowerSeqBlock(b), // §5.3
        .assign => |a| try self.lowerAssign(a.target, a.value), // §5.7
        .contribute => |c| try self.lowerContribute(c.lhs, c.rhs), // §5.6
        .indirect => |c| try self.lowerIndirect(tok, c.lhs, c.probe, c.eqn), // §5.6.7
        .if_stmt => |s| try self.lowerIf(s.cond, s.then_s, s.else_s), // §5.8
        .case_stmt => |s| try self.lowerCase(tok, s.kind, s.scrutinee, s.arms), // §5.8.3
        .for_stmt => |s| try self.lowerFor(s.init, s.cond, s.step, s.body), // §5.9.2
        .while_stmt => |s| try self.lowerWhile(s.cond, s.body), // §5.9.1
        .repeat_stmt => |s| try self.lowerRepeat(s.count, s.body), // §5.9
        .event_control => |s| try self.lowerEventControl(s.event, s.body), // §5.10
        .disable => try self.lowerDisable(tok),
        .sys_task => |s| try self.lowerSysTask(tok, self.file.str(s.name), s.args),
        .jump => |j| try self.lowerJump(tok, j.kind, j.value),
    }
}

/// A.6.5 `disable_statement`. It is an alternative of A.6.4
/// `analog_event_statement` and of the digital A.6.4 `statement`, and is ABSENT
/// from `analog_statement` — so `@(<event>) disable <block>;` is the only form
/// an analog block can legally contain. There is no clause-5 section for
/// `disable` (5.11 is `jump_statement`: return/break/continue), so annex A is
/// the citation.
fn lowerDisable(self: *Lower, tok: u32) Oom!void {
    if (!self.in_event_stmt) {
        var b = self.errWith(tok, .E0401);
        b.help("only `@(<event>) disable <block>;` is legal", .{});
        return b.emit();
    }
    return self.err(tok, .E0402, "", .{});
}

fn lowerStmts(self: *Lower, body: []const Ast.StmtId) Oom!void {
    for (body) |s| try self.lowerStmt(s);
}

/// §5.3.2 named sequential block: its declarations shadow for the block only.
fn lowerSeqBlock(self: *Lower, b: Ast.SeqBlock) Oom!void {
    const mark = self.openScope();
    defer self.closeScope(mark);
    for (b.params) |*p| try self.lowerParamDecl(p); // §5.3.2 local parameters
    for (b.vars) |*v| try self.declareVarDecl(v, .local);
    try self.lowerStmts(b.body);
}

/// §5.7 procedural assignment. The target is an lvalue expression so array
/// elements (§3.2.2) work; both sides are coerced to the target's type
/// (§4.2.1.1/§4.2.1.2).
fn lowerAssign(self: *Lower, target: Ast.ExprId, value: Ast.ExprId) Oom!void {
    const ex = &self.file.exprs;
    // §3.2.2 whole-array assignment from an assignment pattern (§4.2.13):
    // both sides are scalarized, so this is an element-wise copy.
    if (ex.tag(target) == .ident and (ex.tag(value) == .assign_pattern or ex.tag(value) == .concat)) {
        const name = self.file.str(ex.strOf(target));
        if (self.arrays.get(name)) |info| {
            const elems = ex.args(value);
            var key_buf: [elem_key_len]u8 = undefined;
            var i = info.lo;
            while (i <= info.hi) : (i += 1) {
                const k: usize = @intCast(i - info.lo);
                if (k >= elems.len) break;
                const slot = self.vars.get(try self.elemKey(&key_buf, name, i)) orelse continue;
                const tv = try self.lowerExpr(elems[k]);
                const v: Mir.Value = switch (slot.ty) {
                    .real => try self.toReal(tv),
                    .integer => try self.toInt(tv),
                    .string => tv.v,
                };
                try self.builder.writeVariable(slot.place, self.cur, v);
            }
            return;
        }
    }
    const slot = try self.resolveLvalue(target) orelse {
        _ = try self.lowerExpr(value); // keep collecting errors from the rhs
        return;
    };
    const tv = try self.lowerExpr(value);
    const v: Mir.Value = switch (slot.ty) {
        .real => try self.toReal(tv),
        .integer => try self.toInt(tv),
        .string => tv.v,
    };
    try self.builder.writeVariable(slot.place, self.cur, v);
}

/// An assignable location: `x` or `x[<constant>]` (§3.2.2). Anything else is a
/// diagnostic rather than a silent no-op.
fn resolveLvalue(self: *Lower, e: Ast.ExprId) Oom!?VarSlot {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.get(name)) |s| return s;
            if (self.param_index.contains(name)) {
                var b = self.errAtWith(e, .E0312);
                b.msg("`{s}`", .{name});
                b.help("declare a `real` variable if the value changes during the solve", .{});
                try b.emit();
                return null;
            }
            var b = self.errAtWith(e, .E0313);
            b.msg("`{s}`", .{name});
            const near = diag.didYouMeanMap(self.arena, name, self.vars) orelse
                diag.didYouMeanMap(self.arena, name, self.param_index);
            if (near) |s| b.suggestHere(s);
            try b.emit();
            return null;
        },
        .index => {
            const name_id = ex.strOf(ex.lhs(e));
            if (ex.tag(ex.lhs(e)) != .ident or name_id == .none) {
                try self.errAt(e, .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
                return null;
            }
            const name = self.file.str(name_id);
            const idx = self.constEval(ex.rhs(e)) orelse {
                // ponytail: a runtime array index would need a select chain or
                // real memory; every fixture indexes with a constant/genvar.
                try self.errAt(e, .E0311, "indexing `{s}`", .{name});
                return null;
            };
            return self.arrayElem(e, name, idx.asInt());
        },
        // A.6.3: `{a, b} = ...` is net_lvalue/variable_lvalue, a different
        // production from the §4.2.13 expression, and it is not in the analog
        // subset (annex C). Named so the message does not blame the rhs.
        .concat, .multi_concat => {
            try self.errAt(e, .E0317, "", .{});
            return null;
        },
        else => {
            try self.errAt(e, .E0316, "only `x` and `x[<constant>]` can be assigned to", .{});
            return null;
        },
    }
}

fn arrayElem(self: *Lower, e: Ast.ExprId, name: []const u8, i: i64) Oom!?VarSlot {
    const info = self.arrays.get(name) orelse {
        try self.errAt(e, .E0309, "`{s}`", .{name});
        return null;
    };
    if (i < info.lo or i > info.hi) {
        try self.errAt(e, .E0310, "index {d} is outside `{s}[{d}:{d}]`", .{ i, name, info.lo, info.hi });
        return null;
    }
    var key_buf: [elem_key_len]u8 = undefined;
    return self.vars.get(try self.elemKey(&key_buf, name, i));
}

/// §4.7.1 `return`, §5.9 `break` / `continue`. All three close the current
/// block and continue into dead code, so statements after them are lowered but
/// unreachable (and dropped by codegen).
fn lowerJump(self: *Lower, tok: u32, kind: Ast.Stmt.JumpKind, value: Ast.ExprId) Oom!void {
    switch (kind) {
        .ret => {
            const rc = self.ret orelse {
                try self.err(tok, .E0403, "", .{});
                return;
            };
            if (value != .none) {
                const tv = try self.lowerExpr(value);
                const v = if (rc.slot.ty == .real) try self.toReal(tv) else try self.toInt(tv);
                try self.builder.writeVariable(rc.slot.place, self.cur, v);
            }
            try self.gotoBlock(rc.exit);
        },
        .brk, .cont => {
            const l = self.loops.getLastOrNull() orelse {
                try self.err(tok, .E0404, "`{s}`", .{if (kind == .brk) "break" else "continue"});
                return;
            };
            try self.gotoBlock(if (kind == .brk) l.brk else l.cont);
        },
    }
    try self.startUnreachable();
}

// ---------------------------------------------------------------------------
// Class 4 — contributions (LRM §5.6)
// ---------------------------------------------------------------------------

/// LRM §5.6. Resolve the branch, split the rhs into its resistive and reactive
/// halves (§5.6.1.2) and ACCUMULATE both into the target's places (§5.6.1.3).
///
/// Reference direction (§1.3.1.2) is carried by the (hi, lo) order alone —
/// codegen stamps `+val` at hi and `-val` at lo.
pub fn lowerContribute(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.errAt(lhs, .E0405, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Contribution statements cannot be used inside an event control
    // block because it can generate discontinuity in analog signals"; A.6.4
    // `analog_event_statement` states it structurally.
    if (self.in_event_stmt) {
        try self.errAt(lhs, .E0406, "", .{});
        return;
    }
    const ex = &self.file.exprs;
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+." (§4.4 says the same of branch assignment.)
    if (ex.tag(lhs) == .port_access) {
        var b = self.errAtWith(lhs, .E0407);
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        _ = try self.lowerExpr(rhs);
        return;
    }
    if (ex.tag(lhs) != .branch_access) {
        try self.errAt(lhs, .E0408, "", .{});
        _ = try self.lowerExpr(rhs);
        return;
    }
    const target = try self.branchOf(lhs) orelse return;
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot be
    // contributed to using the branch contribution operator <+."
    if (self.indirectOn(target.hi, target.lo)) {
        var b = self.errAtWith(lhs, .E0409);
        b.msg("`{s}({s},{s})`", .{
            if (target.access == .potential) "V" else "I",
            self.nodeName(target.hi),
            self.nodeName(target.lo),
        });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }
    const idx = try self.contribIndex(target.access, target.hi, target.lo, self.file.exprs.mainTok(lhs));

    const split = try self.splitContribution(rhs);
    const acc = self.accum.items[idx];
    if (split.resist) |v| {
        const old = try self.builder.readVariable(acc.resist, self.cur);
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, v }));
    }
    if (split.react) |v| {
        const old = try self.builder.readVariable(acc.react, self.cur);
        try self.builder.writeVariable(acc.react, self.cur, try self.emit(.fadd, &.{ old, v }));
    }
    // §4.6.4 the noise kind belongs to the target, not to one statement.
    if (self.noiseKindOf(rhs)) |k| self.contributions.items[idx].noise_kind = k;
}

/// LRM §5.6.7 indirect branch contribution — `V(out) : V(in) == e;`, read
/// "drive V(out) so that V(in) == e".
///
/// Topologically identical to a direct potential contribution: `out` is driven
/// by a source whose current is a solver unknown, and codegen stamps that
/// current at hi/lo. Only the constitutive row differs — it is
///
///     <probe> − <equation>
///
/// with NO `V(hi,lo)` term, because "the source voltage needs to be adjusted so
/// that the given equation is satisfied": the branch voltage is the free
/// variable, not a term of the constraint. Row ORIENTATION is probe − equation
/// (not the reverse); for a symmetric equation like the ideal opamp both signs
/// converge to the same point, but an asymmetric one does not.
///
/// "Any branches referenced in the equation are only probed and not driven" —
/// that falls out for free: `lowerExpr` on `V(in)` produces a probe, and only
/// the entry appended here ever reaches codegen's stamping loop.
fn lowerIndirect(self: *Lower, tok: u32, lhs: Ast.ExprId, probe_e: Ast.ExprId, eqn: Ast.ExprId) Oom!void {
    if (self.restrict) |ctx| {
        try self.errAt(lhs, .E0410, "not allowed in {s}", .{ctx});
        return;
    }
    if (self.in_event_stmt) {
        try self.errAt(lhs, .E0411, "", .{});
        return;
    }
    // §5.6.7 "Indirect branch contributions shall not be used in conditional or
    // looping statements, unless the conditional expression is a constant
    // expression." A constant condition never reaches here (see `cond_depth`).
    if (self.cond_depth != 0) {
        try self.err(tok, .E0412, "the condition is not a constant expression", .{});
        return;
    }
    const ex = &self.file.exprs;
    if (ex.tag(lhs) != .branch_access) {
        try self.errAt(lhs, .E0413, "", .{});
        return;
    }
    // §5.6.7 "The left-hand side of the equality operator must either be an
    // access function, or ddt, idt or idtmod applied to an access function."
    if (!self.isIndirectProbe(probe_e)) {
        var b = self.errAtWith(probe_e, .E0414);
        b.help("use an access function, or `ddt`/`idt`/`idtmod` applied to one", .{});
        try b.emit();
        return;
    }
    const target = try self.branchOf(lhs) orelse return;
    // §5.6.7.2 incompatible with a direct contribution across the same pair of
    // analog nets — checked on the accumulator ENTRY, since `<+` statements are
    // deduped across statements and across if-arms.
    for (self.contributions.items) |c| {
        if (c.kind != .direct) continue;
        if (!samePair(c.hi, c.lo, target.hi, target.lo)) continue;
        var b = self.errAtWith(lhs, .E0415);
        b.msg("`({s},{s})`", .{ self.nodeName(target.hi), self.nodeName(target.lo) });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }

    const p = try self.toReal(try self.lowerExpr(probe_e));
    const e = try self.toReal(try self.lowerExpr(eqn));
    const row = try self.emit(.fsub, &.{ p, e });

    // Its own entry, never `contribIndex`: §5.6.7.1 allows several indirect
    // contributions, each of which is a separate source and equation.
    const idx = try self.newContrib(.indirect, target.access, target.hi, target.lo, self.file.exprs.mainTok(lhs));
    try self.builder.writeVariable(self.accum.items[idx].resist, self.cur, row);
}

/// §5.6.7.2 "the same pair of analog nets (or any of its parallel branches)" —
/// unordered, since (a,b) and (b,a) are the same pair with opposite reference
/// directions (§1.3.1.2).
fn samePair(a_hi: u16, a_lo: u16, b_hi: u16, b_lo: u16) bool {
    return (a_hi == b_hi and a_lo == b_lo) or (a_hi == b_lo and a_lo == b_hi);
}

fn indirectOn(self: *const Lower, hi: u16, lo: u16) bool {
    for (self.contributions.items) |c| {
        if (c.kind == .indirect and samePair(c.hi, c.lo, hi, lo)) return true;
    }
    return false;
}

/// A.8.3 `indirect_expression`: a branch/port probe, or ddt/idt/idtmod of one.
/// The optional tolerance/initial-condition arguments are ordinary expressions
/// and are not restricted.
fn isIndirectProbe(self: *const Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (e == .none) return false;
    switch (ex.tag(e)) {
        .branch_access, .port_access => return true,
        .filter_call => {},
        else => return false,
    }
    const name = self.file.str(ex.strOf(e));
    const is_op = std.mem.eql(u8, name, "ddt") or
        std.mem.eql(u8, name, "idt") or
        std.mem.eql(u8, name, "idtmod");
    if (!is_op) return false;
    const args = ex.args(e);
    if (args.len == 0) return false;
    return switch (ex.tag(args[0])) {
        .branch_access, .port_access => true,
        else => false,
    };
}

const Target = struct { access: Access, hi: u16, lo: u16 };

/// §4.4.1 resolve `V(a)`, `V(a,b)`, `I(br)` to (access, node pair).
fn branchOf(self: *Lower, e: Ast.ExprId) Oom!?Target {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errAtWith(e, .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(self.arena, name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return null;
    };
    const first = ex.lhs(e);
    // §3.12 a single argument naming a declared branch.
    if (ex.rhs(e) == .none and ex.tag(first) == .ident) {
        if (self.branches.get(self.file.str(ex.strOf(first)))) |b|
            return .{ .access = access, .hi = b.hi, .lo = b.lo };
    }
    const hi = try self.nodeOf(first);
    const lo = if (ex.rhs(e) == .none) ground else try self.nodeOf(ex.rhs(e));
    return .{ .access = access, .hi = hi, .lo = lo };
}

/// Find or create the accumulator pair for one contribution target. A pair
/// that receives BOTH a potential and a flow contribution (in different arms)
/// is the §5.6.5 switch branch — two entries, one per access.
fn contribIndex(self: *Lower, access: Access, hi: u16, lo: u16, tok: u32) Oom!u32 {
    for (self.contributions.items, 0..) |c, i| {
        // §5.6.7.2 an indirectly-assigned branch is never an accumulation
        // target, so its entry can never absorb a `<+` (which `lowerIndirect`
        // rejects outright anyway).
        if (c.kind != .direct) continue;
        if (c.access == access and c.hi == hi and c.lo == lo) return @intCast(i);
    }
    return self.newContrib(.direct, access, hi, lo, tok);
}

/// Append a fresh contribution + its accumulator pair. The two tables stay
/// parallel; see the UNIT ORDERING note in proof.zig.
fn newContrib(self: *Lower, kind: Kind, access: Access, hi: u16, lo: u16, tok: u32) Oom!u32 {
    const idx: u32 = @intCast(self.contributions.items.len);
    try self.contributions.append(self.arena, .{
        .access = access,
        .tok = tok,
        .hi = hi,
        .lo = lo,
        .kind = kind,
    });
    const acc: Accum = .{ .resist = self.builder.newPlace(), .react = self.builder.newPlace() };
    // Seeded in the entry block, which dominates everything: a contribution
    // that only happens on one arm of an `if` reads 0 on the other (§5.8).
    try self.builder.writeVariable(acc.resist, .entry, .f_zero);
    try self.builder.writeVariable(acc.react, .entry, .f_zero);
    try self.accum.append(self.arena, acc);
    return idx;
}

const Split = struct { resist: ?Mir.Value, react: ?Mir.Value };

/// LRM §5.6.1.2 — separate the ddt terms (§4.5.3) into the reactive part.
///
/// The split is structural, on the ADDITIVE terms of the rhs: a term free of
/// `ddt` is resistive; a term containing one is reactive, and its reactive
/// value is the term with the `ddt` stripped (`C*ddt(V)` → `C*V`), i.e. the
/// charge/flux whose time derivative codegen's q() differentiates. That is
/// exact whenever `ddt` appears once along a multiplicative spine of the term,
/// which is what §5.6.1.2's charge formulation means. Anything else (`ddt`
/// inside a call, two `ddt`s multiplied) is a diagnostic — never silently the
/// wrong physics.
fn splitContribution(self: *Lower, rhs: Ast.ExprId) Oom!Split {
    var out: Split = .{ .resist = null, .react = null };
    try self.splitTerm(rhs, false, &out);
    return out;
}

fn splitTerm(self: *Lower, e: Ast.ExprId, negate: bool, out: *Split) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .add => {
                try self.splitTerm(ex.lhs(e), negate, out);
                try self.splitTerm(ex.rhs(e), negate, out);
                return;
            },
            .sub => {
                try self.splitTerm(ex.lhs(e), negate, out);
                try self.splitTerm(ex.rhs(e), !negate, out);
                return;
            },
            else => {},
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return self.splitTerm(ex.lhs(e), negate, out),
            .minus => return self.splitTerm(ex.lhs(e), !negate, out),
            else => {},
        },
        else => {},
    }

    if (self.containsDdt(e)) {
        const v = try self.lowerReactive(e) orelse return;
        try self.accumulate(&out.react, v, negate);
    } else {
        const v = try self.toReal(try self.lowerExpr(e));
        try self.accumulate(&out.resist, v, negate);
    }
}

fn accumulate(self: *Lower, slot: *?Mir.Value, v: Mir.Value, negate: bool) Oom!void {
    if (slot.*) |old| {
        slot.* = try self.emit(if (negate) .fsub else .fadd, &.{ old, v });
    } else {
        slot.* = if (negate) try self.emit(.fneg, &.{v}) else v;
    }
}

/// Does this subtree contain a `ddt` (§4.5.3)? Cheap recursive scan — the
/// expression store is SoA, so this is a few column reads per node.
fn containsDdt(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .filter_call, .call, .builtin_call, .sys_call, .noise_call => {
            if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) return true;
            for (ex.args(e)) |a| if (self.containsDdt(a)) return true;
            return false;
        },
        .ternary => return self.containsDdt(ex.lhs(e)) or self.containsDdt(ex.rhs(e)) or
            self.containsDdt(ex.ternaryElse(e)),
        else => return self.containsDdt(ex.lhs(e)) or self.containsDdt(ex.rhs(e)),
    }
}

/// The charge/flux of a reactive term: strip exactly one `ddt` from a
/// multiplicative spine (§5.6.1.2).
fn lowerReactive(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
    const ex = &self.file.exprs;
    spine: switch (ex.tag(e)) {
        .filter_call => {
            if (self.file.strings.eql(ex.strOf(e), "ddt")) {
                const args = ex.args(e);
                // A.8.2 gives a filter no `analog_expression_or_null` form, so
                // an OMITTED slot (`ddt(,1.0)`) is as wrong as no argument at
                // all. `lowerFilter` already rejects it on the non-reactive
                // path; this reactive spine bypasses that call and has to
                // agree (§4.5.14).
                if (args.len == 0 or args[0] == .none) {
                    try self.errAt(e, .E0502, "", .{});
                    return null;
                }
                // args[1] (abstol/nature, §4.5.3) only affects tolerance.
                return try self.toReal(try self.lowerExpr(args[0]));
            }
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return self.lowerReactive(ex.lhs(e)),
            .minus => {
                const v = try self.lowerReactive(ex.lhs(e)) orelse return null;
                return try self.emit(.fneg, &.{v});
            },
            else => {},
        },
        .binary => switch (ex.binOp(e)) {
            .mul => {
                const l_has = self.containsDdt(ex.lhs(e));
                const r_has = self.containsDdt(ex.rhs(e));
                if (l_has and r_has) break :spine;
                if (l_has) {
                    const a = try self.lowerReactive(ex.lhs(e)) orelse return null;
                    const b = try self.toReal(try self.lowerExpr(ex.rhs(e)));
                    return try self.emit(.fmul, &.{ a, b });
                }
                const a = try self.toReal(try self.lowerExpr(ex.lhs(e)));
                const b = try self.lowerReactive(ex.rhs(e)) orelse return null;
                return try self.emit(.fmul, &.{ a, b });
            },
            .div => {
                if (self.containsDdt(ex.rhs(e))) break :spine; // ddt in a divisor
                const a = try self.lowerReactive(ex.lhs(e)) orelse return null;
                const b = try self.toReal(try self.lowerExpr(ex.rhs(e)));
                return try self.emit(.fdiv, &.{ a, b });
            },
            else => {},
        },
        else => {},
    }
    var b = self.errAtWith(e, .E0503);
    b.help("assign the derivative to a variable, then use that variable in the contribution", .{});
    try b.emit();
    return null;
}

/// §4.6.4 the small-signal noise source a contribution carries, if any.
fn noiseKindOf(self: *const Lower, e: Ast.ExprId) ?NoiseKind {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .noise_call => {
            const n = self.file.strings.get(ex.strOf(e));
            // §4.6.3 ac_stim shares the small-signal grammar but is a STIMULUS,
            // not a noise source; listing it in `noise_gens` would invent a
            // noise generator the model never declared.
            if (std.mem.eql(u8, n, "ac_stim")) return null;
            // §4.6.4.2 flicker_noise; every other source is white (§4.6.4.1).
            return if (std.mem.eql(u8, n, "flicker_noise")) .flicker else .thermal;
        },
        .call, .builtin_call, .sys_call, .filter_call => {
            for (ex.args(e)) |a| if (self.noiseKindOf(a)) |k| return k;
            return null;
        },
        else => {
            if (self.noiseKindOf(ex.lhs(e))) |k| return k;
            return self.noiseKindOf(ex.rhs(e));
        },
    }
}

// ---------------------------------------------------------------------------
// Class 4 — control flow (LRM §5.8, §5.9)
// ---------------------------------------------------------------------------

/// §5.8 conditional. A constant-foldable condition lowers only the taken arm —
/// that is also what makes `generate if` (§6.6.2) collapse at elaboration.
fn lowerIf(self: *Lower, cond: Ast.ExprId, then_s: Ast.StmtId, else_s: Ast.StmtId) Oom!void {
    if (self.elabConst(cond)) |c| {
        return self.lowerStmt(if (c.isTrue()) then_s else else_s);
    }
    const c = try self.toBool(try self.lowerExpr(cond));
    try self.lowerBranchStmt(c, then_s, else_s, self.isAnalysisOrConst(cond));
}

/// §5.10 the same diamond, but the condition is already a Value (event guards)
/// — and an event's `hit` flag is the definition of a condition that changes
/// during the solve, so it is never static.
fn lowerGuarded(self: *Lower, cond: Mir.Value, body: Ast.StmtId) Oom!void {
    try self.lowerBranchStmt(cond, body, .none, false);
}

/// Lower a body that only runs under a RUNTIME condition. The wrapper carries
/// §5.6.7's ban on indirect contributions in a non-constant conditional or loop
/// and §5.8.1/§5.9's ban on analog operators in one; the constant-folded paths
/// (`lowerIf`'s fold, `tryUnrollFor`) call `lowerStmt` directly and are
/// therefore unrestricted, which is exactly the "unless the conditional
/// expression is a constant expression" carve-out.
///
/// `static` is the WEAKER §5.8.1 carve-out — an `analysis_or_constant_expression`
/// rather than a constant one. It relaxes E0514 alone; `cond_depth` still rises,
/// so the two constant-only rules keep rejecting the same code they did.
fn lowerCondBody(self: *Lower, body: Ast.StmtId, static: bool) Oom!void {
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    defer {
        self.cond_depth -= 1;
        self.static_cond_depth -= @intFromBool(static);
    }
    try self.lowerStmt(body);
}

/// A.8.3 `analysis_or_constant_expression` — the §5.8.1 carve-out. True when
/// nothing in the tree can change between one Newton iteration and the next:
/// literals, `parameter`s and `analysis()` calls, combined with operators.
///
/// Deliberately NOT `elabConst`: that folds to a VALUE and refuses a parameter
/// on purpose (a model card overrides it), while this asks the different
/// question of whether the value is fixed for the whole analysis. A parameter
/// is `constant_primary` in A.8.4 and cannot move mid-solve, so it qualifies.
fn isAnalysisOrConst(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => true,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk false;
            break :blk self.param_index.contains(name) or self.consts.contains(name);
        },
        // A.8.2 analysis_function_call. Its value is fixed for the analysis,
        // which is the whole reason §5.8.1 spells out "analysis_or_constant".
        .sys_call => std.mem.eql(u8, self.file.str(ex.strOf(e)), "analysis"),
        .unary => self.isAnalysisOrConst(ex.lhs(e)),
        .binary => self.isAnalysisOrConst(ex.lhs(e)) and self.isAnalysisOrConst(ex.rhs(e)),
        .ternary => self.isAnalysisOrConst(ex.lhs(e)) and
            self.isAnalysisOrConst(ex.rhs(e)) and
            self.isAnalysisOrConst(ex.ternaryElse(e)),
        else => false,
    };
}

fn lowerBranchStmt(
    self: *Lower,
    cond: Mir.Value,
    then_s: Ast.StmtId,
    else_s: Ast.StmtId,
    static: bool,
) Oom!void {
    const then_b = try self.newBlock();
    const else_b = try self.newBlock();
    const join = try self.newBlock();

    _ = try self.mir.emitBranch(self.arena, self.cur, cond, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    try self.builder.sealBlock(else_b);

    self.cur = then_b;
    try self.lowerCondBody(then_s, static);
    try self.gotoBlock(join);

    self.cur = else_b;
    try self.lowerCondBody(else_s, static);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §5.8.3 case — lowered as the equality chain the LRM defines it to be: the
/// first matching arm wins, `default` is the final else. `casex`/`casez` have
/// no meaning for a real scrutinee (annex C).
fn lowerCase(
    self: *Lower,
    tok: u32,
    kind: Ast.CaseKind,
    scrutinee: Ast.ExprId,
    arms: []const Ast.CaseArm,
) Oom!void {
    if (kind != .normal) {
        var b = self.errWith(tok, .E0416);
        b.help("use `case`", .{});
        try b.emit();
        return;
    }
    const sv = try self.lowerExpr(scrutinee);
    var default_arm: Ast.StmtId = .none;
    for (arms) |a| {
        if (a.labels.len == 0) default_arm = a.body;
    }
    // §5.8.1 applies to `case` word for word: the arm LABELS are constants by
    // A.6.7, so whether an arm is decided before the solve turns entirely on
    // the scrutinee.
    try self.lowerCaseChain(sv, arms, default_arm, self.isAnalysisOrConst(scrutinee));
}

fn lowerCaseChain(
    self: *Lower,
    sv: TypedValue,
    arms: []const Ast.CaseArm,
    default_arm: Ast.StmtId,
    static: bool,
) Oom!void {
    if (arms.len == 0) return self.lowerStmt(default_arm);
    const a = arms[0];
    if (a.labels.len == 0) return self.lowerCaseChain(sv, arms[1..], default_arm, static);

    // §5.8.3 an arm with several labels matches any of them.
    var cond: ?Mir.Value = null;
    for (a.labels) |l| {
        const eq = try self.cmp(.eq, sv, try self.lowerExpr(l));
        cond = if (cond) |c| try self.emit(.logor, &.{ c, eq }) else eq;
    }

    const then_b = try self.newBlock();
    const else_b = try self.newBlock();
    const join = try self.newBlock();
    _ = try self.mir.emitBranch(self.arena, self.cur, cond.?, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    try self.builder.sealBlock(else_b);

    self.cur = then_b;
    try self.lowerCondBody(a.body, static);
    try self.gotoBlock(join);

    self.cur = else_b;
    self.cond_depth += 1;
    self.static_cond_depth += @intFromBool(static);
    try self.lowerCaseChain(sv, arms[1..], default_arm, static);
    self.static_cond_depth -= @intFromBool(static);
    self.cond_depth -= 1;
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
}

/// §5.9.1 `while`. Braun order: the header is sealed only after the back edge.
fn lowerWhile(self: *Lower, cond: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const header = try self.newBlock();
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try self.lowerExpr(cond));
    const body_b = try self.newBlock();
    const exit = try self.newBlock();
    // `self.cur`, NOT `header`: a §4.2.7 short-circuit (`while (i<=4 && f(x))`)
    // splits the condition across blocks of its own and leaves `cur` at the
    // join. Branching from `header` regardless appended a SECOND terminator to
    // a block that already ended in the `&&`'s branch — the join and the rhs
    // block then had no predecessor, codegen never emitted them, and the loop
    // branched on a temporary nothing ever assigned. Same hazard as `?:` in a
    // condition. Pinned by codegen.zig's test "§5.9.1 a short-circuit loop
    // condition still reaches the loop's branch".
    _ = try self.mir.emitBranch(self.arena, self.cur, c, body_b, exit);
    try self.builder.addPredecessor(body_b, self.cur);
    try self.builder.addPredecessor(exit, self.cur);
    try self.builder.sealBlock(body_b);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = header });
    self.cur = body_b;
    try self.lowerCondBody(body, false); // §5.9: a loop body is never static
    try self.gotoBlock(header);
    _ = self.loops.pop();

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// §5.9 `repeat (n)` — the LRM's counted loop, lowered as an integer countdown.
fn lowerRepeat(self: *Lower, count: Ast.ExprId, body: Ast.StmtId) Oom!void {
    const n = try self.toInt(try self.lowerExpr(count));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, n);

    const header = try self.newBlock();
    try self.gotoBlock(header);
    self.cur = header;

    const i = try self.builder.readVariable(place, header);
    const c = try self.emit(.igt, &.{ i, .zero });
    const body_b = try self.newBlock();
    const step_b = try self.newBlock();
    const exit = try self.newBlock();
    _ = try self.mir.emitBranch(self.arena, header, c, body_b, exit);
    try self.builder.addPredecessor(body_b, header);
    try self.builder.addPredecessor(exit, header);
    try self.builder.sealBlock(body_b);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try self.lowerCondBody(body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    _ = self.loops.pop();

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    const cur_i = try self.builder.readVariable(place, step_b);
    try self.builder.writeVariable(place, step_b, try self.emit(.isub, &.{ cur_i, .one }));
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// §5.9.2 `for`. If the loop variable is a genvar (§3.5) the whole loop is
/// unrolled at elaboration (§6.6.1) — that is the only form allowed to appear
/// in a generate region, and it is what makes `genvar`-indexed nets work.
fn lowerFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!void {
    if (try self.tryUnrollFor(init_s, cond, step, body)) return;

    try self.lowerStmt(init_s);
    const header = try self.newBlock();
    try self.gotoBlock(header);
    self.cur = header;

    const c = try self.toBool(try self.lowerExpr(cond));
    const body_b = try self.newBlock();
    const step_b = try self.newBlock();
    const exit = try self.newBlock();
    // `self.cur`, not `header` — see `lowerWhile`: the condition may have been
    // split across blocks by a short-circuit, and the branch belongs at its end.
    _ = try self.mir.emitBranch(self.arena, self.cur, c, body_b, exit);
    try self.builder.addPredecessor(body_b, self.cur);
    try self.builder.addPredecessor(exit, self.cur);
    try self.builder.sealBlock(body_b);

    try self.loops.append(self.arena, .{ .brk = exit, .cont = step_b });
    self.cur = body_b;
    try self.lowerCondBody(body, false); // §5.9: a loop body is never static
    try self.gotoBlock(step_b);
    _ = self.loops.pop();

    try self.builder.sealBlock(step_b);
    self.cur = step_b;
    try self.lowerStmt(step);
    try self.gotoBlock(header);

    try self.builder.sealBlock(header);
    try self.builder.sealBlock(exit);
    self.cur = exit;
}

/// Bound on §6.6.1 unrolling: a runaway genvar loop is a source bug, not a
/// reason to emit a million instructions.
const max_unroll: u32 = 4096;

/// §3.5/§6.6.1 genvar loop-generate. Returns false when this is an ordinary
/// procedural `for` (which `lowerFor` then lowers as a CFG loop).
fn tryUnrollFor(self: *Lower, init_s: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId) Oom!bool {
    const gv = self.genvarOf(init_s) orelse return false;
    const start = self.constEval(self.assignValueOf(init_s).?) orelse {
        try self.errAt(cond, .E0417, "initial value of `{s}`", .{gv});
        return true;
    };
    try self.consts.put(self.arena, gv, start);

    var n: u32 = 0;
    while (n < max_unroll) : (n += 1) {
        const c = self.constEval(cond) orelse {
            try self.errAt(cond, .E0418, "", .{});
            break;
        };
        if (!c.isTrue()) break;
        try self.lowerStmt(body);
        const next = self.constEval(self.assignValueOf(step) orelse .none) orelse {
            try self.errAt(cond, .E0419, "", .{});
            break;
        };
        try self.consts.put(self.arena, gv, next);
    }
    if (n == max_unroll)
        try self.errAt(cond, .E0420, "gave up after {d} iterations", .{max_unroll});
    _ = self.consts.remove(gv);
    return true;
}

/// The genvar assigned by a `for` init statement, if any (§3.5).
fn genvarOf(self: *const Lower, init_s: Ast.StmtId) ?[]const u8 {
    const m = self.module orelse return null;
    if (init_s == .none) return null;
    const s = self.file.stmt(init_s);
    if (s != .assign) return null;
    const t = s.assign.target;
    if (self.file.exprs.tag(t) != .ident) return null;
    const name_id = self.file.exprs.strOf(t);
    for (m.genvars) |g| if (g == name_id) return self.file.str(name_id);
    return null;
}

fn assignValueOf(self: *const Lower, s: Ast.StmtId) ?Ast.ExprId {
    if (s == .none) return null;
    const st = self.file.stmt(s);
    return if (st == .assign) st.assign.value else null;
}

// ---------------------------------------------------------------------------
// Class 7 — events (LRM §5.10)
// ---------------------------------------------------------------------------

/// LRM §5.10. An analog event control runs its body only when the event is
/// active, so it lowers to a guard: the event itself becomes a `call` whose
/// integer result codegen answers from the simulator state (§5.10.2 global
/// events, §5.10.3 monitored events).
pub fn lowerEventControl(self: *Lower, event: Ast.ExprId, body: Ast.StmtId) Oom!void {
    if (self.restrict) |ctx| {
        try self.errAt(event, .E0702, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Nested event control statements are not allowed" — and A.6.4
    // agrees: `analog_event_statement` has no
    // `analog_event_control_statement` alternative.
    if (self.in_event_stmt) {
        try self.errAt(event, .E0703, "", .{});
        return;
    }
    // §5.8 "Event control statements (e.g.: timer, cross) cannot be used inside
    // conditional statements unless the conditional expression is a constant
    // expression"; §5.9 bans them in repeat/while/non-genvar for outright;
    // §5.10.3.1 repeats it for `cross`. STRICTER than E0514 on purpose — the
    // carve-out here is a constant expression, so `analysis("dc")` does not
    // license it and `static_cond_depth` is deliberately not consulted.
    if (self.cond_depth != 0) {
        var b = self.errAtWith(event, .E0707);
        b.help("put `@(...)` on the spine and make the statement it guards conditional", .{});
        try b.emit();
    }
    const cond = try self.lowerEventExpr(event) orelse return;
    const prev = self.in_event_stmt;
    self.in_event_stmt = true;
    defer self.in_event_stmt = prev;
    try self.lowerGuarded(cond, body);
}

/// §5.10.1 or-lists, §5.10.2 initial_step/final_step, §5.10.3 cross/above/timer.
fn lowerEventExpr(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        // §5.10.1 `@(a or b)` — active when either is.
        .event_or => {
            const a = try self.lowerEventExpr(ex.lhs(e)) orelse return null;
            const b = try self.lowerEventExpr(ex.rhs(e)) orelse return null;
            return try self.emit(.logor, &.{ a, b });
        },
        // §5.10.2 global events; the analysis-name arguments select which
        // analyses they fire in (`initial_step("dc","tran")`).
        .event_initial_step, .event_final_step => {
            const name = if (ex.tag(e) == .event_initial_step) "initial_step" else "final_step";
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            if (ex.extraOf(e) < ex.pool.items.len) {
                for (ex.nameParts(e)) |p|
                    try args.append(self.arena, try self.mir.addStrConst(self.arena, self.file.str(p)));
            }
            return try self.call(name, args.items);
        },
        // §5.10.3 monitored events.
        .event_function => {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "absdelta")) {
                // §5.10.3 absdelta monitors a digital-domain delta; it has no
                // analog kernel semantics. (Wording pinned by
                // tests/fixtures/ch05_analog_behavior/absdelta_digital_only.)
                try self.errAt(e, .E0513, "", .{});
                return null;
            }
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            for (ex.args(e)) |a| {
                // A.6.5 permits omitted arguments; keep the position.
                if (a == .none) {
                    try args.append(self.arena, .f_zero);
                    continue;
                }
                try args.append(self.arena, try self.toReal(try self.lowerExpr(a)));
            }
            return try self.call(name, args.items);
        },
        .event_posedge, .event_negedge => {
            try self.errAt(e, .E0704, "", .{});
            return null;
        },
        // §5.10.4. IN SCOPE for Verilog-A — §5.10 lists named events as one of
        // the three kinds of ANALOG event, and annex C.7 excludes only DIGITAL
        // behavior and events — but not implemented: an event that can be
        // detected and never triggered would make `@(ev)` a silently
        // never-taken guard, which is exactly the substitution invariant 5
        // forbids.
        .ident => {
            try self.errAt(e, .E0705, "`{s}`", .{self.file.str(ex.strOf(e))});
            return null;
        },
        else => {
            try self.errAt(e, .E0706, "", .{});
            return null;
        },
    }
}

// ---------------------------------------------------------------------------
// ch9 — system tasks (statement position)
// ---------------------------------------------------------------------------

/// §5.12/ch9 analog system task. Display/file tasks are void calls codegen may
/// drop; the deliberately-unsupported set is rejected by exact name.
fn lowerSysTask(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!void {
    if (isRejectedSysFunc(name)) {
        try self.err(tok, .E0801, "`{s}`", .{name});
        return;
    }
    if (try self.lowerKernelCtl(tok, name, args)) return; // §9.17
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (args) |a| {
        if (a == .none) continue; // A.6.9 empty argument slot
        try vals.append(self.arena, try self.lowerSysArg(a));
    }
    const v = try self.call(name, vals.items);
    if (isDisplayTask(name)) try self.displays.append(self.arena, .{
        .val = v,
        .name = name,
        .tok = tok,
        .conditional = self.cond_depth != 0,
    });
}

/// §9.4.1 display family + §9.7.3 severity family: the tasks whose whole content
/// is text on the simulator's output. The file family (§9.5) is NOT here — it
/// needs a descriptor the compiled device has no way to own — and neither is
/// `$monitoron`/`$monitoroff`, which toggle a mode rather than print.
pub fn isDisplayTask(name: []const u8) bool {
    const printing = [_][]const u8{
        "$display", "$displayb", "$displayo", "$displayh",
        "$write",   "$writeb",   "$writeo",   "$writeh",
        "$strobe",  "$strobeb",  "$strobeo",  "$strobeh",
        "$monitor", "$debug",    "$fatal",    "$error",
        "$warning", "$info",
    };
    for (printing) |p| if (std.mem.eql(u8, name, p)) return true;
    return false;
}

/// §9.17 analog kernel control. Handled here rather than as an ordinary void
/// call because both tasks WRITE TO THE HOST: a plain call would render as
/// `S.con(0.0)` in an eval unit and the request would be silently dropped.
/// Returns true when `name` was one of them.
fn lowerKernelCtl(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!bool {
    // §9.17.2 `$bound_step ( expression ) ;` — "the simulator shall ensure that
    // the next time step taken is no larger than the smallest $bound_step()
    // argument currently active", so the accumulation is a running minimum.
    if (std.mem.eql(u8, name, "$bound_step")) {
        if (args.len != 1 or args[0] == .none) {
            try self.err(tok, .E0802, "got {d}", .{args.len});
            return true;
        }
        // "The expression argument shall be non-negative" (§9.17.2); `abs`
        // would silently repair a model that violates it, so a provably
        // negative constant is a diagnostic and anything else is taken as
        // written.
        if (self.constEval(args[0])) |c| {
            if (c.asReal() < 0.0) {
                try self.errAt(args[0], .E0803, "got {d}", .{c.asReal()});
                return true;
            }
        }
        const p = try self.kernelCtlPlace(&self.bound_step_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.toReal(try self.lowerExpr(args[0]));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }

    // §9.17.1 `$discontinuity [ ( constant_expression ) ] ;` — the argument is
    // the DEGREE, "a discontinuity in the i'th derivative", so a smaller degree
    // is the more severe announcement and the running minimum is what the host
    // needs. `$discontinuity` with no argument is degree 0.
    if (std.mem.eql(u8, name, "$discontinuity")) {
        const real_args = for (args) |a| {
            if (a != .none) break args;
        } else args[0..0];
        if (real_args.len > 1) {
            try self.err(tok, .E0804, "got {d}", .{real_args.len});
            return true;
        }
        var degree: i64 = 0;
        if (real_args.len == 1) {
            const c = self.constEval(real_args[0]) orelse {
                try self.errAt(real_args[0], .E0805, "", .{});
                return true;
            };
            degree = c.asInt();
        }
        // §9.17.1 "A special form of the $discontinuity task, $discontinuity(-1),
        // is used with the $limit() function". FastVAF leaves the limiting
        // ALGORITHM to the host (codegen renders `$limit` as its own argument),
        // so there is no -1 announcement to make and dropping it here is exact —
        // it is not a substitute value, it is the whole content of the request.
        if (degree < 0) return true;
        const p = try self.kernelCtlPlace(&self.disc_place);
        const cur = try self.builder.readVariable(p, self.cur);
        const v = try self.fconst(@floatFromInt(degree));
        try self.builder.writeVariable(p, self.cur, try self.emit(.fmin, &.{ cur, v }));
        return true;
    }
    return false;
}

/// ch9 functions FastVAF deliberately does not implement. Rejecting by exact
/// name (rather than silently returning 0) is what the fixtures pin.
fn isRejectedSysFunc(name: []const u8) bool {
    const rejected = [_][]const u8{
        "$random", "$arandom", // §9.13.1
        "$dist_uniform",      "$dist_normal",     "$dist_exponential", // §9.13.2
        "$dist_poisson",      "$dist_chi_square", "$dist_t",
        "$dist_erlang",       "$rdist_uniform",   "$rdist_normal",
        // The rest of §9.13.2. A random variate cannot exist in a device
        // residual at all: the Newton loop re-evaluates one operating point
        // many times, and a draw that changes between iterations makes the
        // residual non-deterministic, so it never converges. Rejecting the
        // WHOLE family is the only self-consistent rule — a zero substitute
        // would silently change the device the user wrote.
        "$rdist_exponential", "$rdist_poisson",   "$rdist_chi_square",
        "$rdist_t",           "$rdist_erlang",
        "$table_model", // §9.21
        "$simprobe", // §9.16
    };
    for (rejected) |r| if (std.mem.eql(u8, name, r)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Class 4/5 — expressions (LRM §4.2), math (§4.3), signal access (§4.4)
// ---------------------------------------------------------------------------

/// Expression lowering. LRM §4. Returns the Value AND its LRM type, because
/// every operator's opcode family depends on it (§4.2.1.1–§4.2.1.3).
pub fn lowerExpr(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (e == .none) return poison;
    const ex = &self.file.exprs;
    // PROVENANCE. Every MIR instruction emitted while this node is being
    // lowered is stamped with its token (Mir.addInst reads the cursor), which
    // is how proof.zig turns a `Mir.Inst` back into a source span. Saved and
    // restored because lowering recurses: an operand must not leave the cursor
    // pointing at itself once the parent resumes emitting.
    const saved_tok = self.mir.cur_tok;
    defer self.mir.cur_tok = saved_tok;
    self.mir.cur_tok = ex.mainTok(e);
    switch (ex.tag(e)) {
        .int_literal => return .{ .v = try self.iconst(ex.intValue(e)), .ty = .integer }, // §2.6.1
        .real_literal => return .{ .v = try self.fconst(ex.realValue(e)), .ty = .real }, // §2.6.2
        .str_literal => return .{
            .v = try self.mir.addStrConst(self.arena, self.file.str(ex.strOf(e))),
            .ty = .string,
        }, // §2.7
        // A.2.5 — only legal inside a value range, which proof.zig reads from
        // the AST directly; lowering one is harmless.
        .pos_inf => return .{ .v = .f_inf, .ty = .real },
        .neg_inf => return .{ .v = try self.fconst(-std.math.inf(f64)), .ty = .real },

        .ident => return self.lookupIdent(e),
        .hier_ident => {
            try self.errAt(e, .E0901, "", .{});
            return poison;
        },

        .unary => return self.lowerUnary(e),
        .binary => return self.lowerBinary(e),
        // §4.2.12 value-form conditional: `select` needs no CFG split, so a
        // ternary inside an expression stays one basic block.
        .ternary => {
            const c = try self.toBool(try self.lowerExpr(ex.lhs(e)));
            const t = try self.lowerExpr(ex.rhs(e));
            const f = try self.lowerExpr(ex.ternaryElse(e));
            const ty = unify(t.ty, f.ty);
            const tv = if (ty == .real) try self.toReal(t) else t.v;
            const fv = if (ty == .real) try self.toReal(f) else f.v;
            return .{ .v = try self.emit(.select, &.{ c, tv, fv }), .ty = ty };
        },

        .call => return self.lowerUserCall(e), // §4.7
        .builtin_call => return self.lowerBuiltin(e), // §4.3
        .sys_call => return self.lowerSysCall(e), // ch9
        .filter_call => return self.lowerFilter(e), // §4.5
        .noise_call => return self.lowerNoise(e), // §4.6

        .branch_access => return self.lowerBranchAccess(e), // §4.4.1
        .port_access => return self.lowerPortAccess(e), // §4.4.2/§5.4.3

        .index => return self.lowerIndex(e),

        .concat => return self.lowerConcat(e), // §3.3 Table 3-3 / §4.2.13
        .multi_concat, .assign_pattern => {
            try self.errAt(e, .E0509, "", .{});
            return poison;
        },
        .range => {
            try self.errAt(e, .E0329, "", .{});
            return poison;
        },
        .event_or, .event_posedge, .event_negedge, .event_initial_step, .event_final_step, .event_function => {
            try self.errAt(e, .E0701, "", .{});
            return poison;
        },
    }
}

/// §3.2.2 array element read. A constant index selects one scalarized
/// element; a runtime index becomes a `select` chain over them (the array is
/// scalarized, so there is no memory to index).
fn lowerIndex(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const base = ex.lhs(e);
    if (ex.tag(base) != .ident) {
        try self.errAt(e, .E0330, "only `name[<index>]` is supported", .{});
        return poison;
    }
    const name = self.file.str(ex.strOf(base));
    const info = self.arrays.get(name) orelse {
        try self.errAt(e, .E0309, "`{s}`", .{name});
        return poison;
    };

    if (self.constEval(ex.rhs(e))) |k| {
        const i = k.asInt();
        if (i < info.lo or i > info.hi) {
            try self.errAt(e, .E0310, "index {d} is outside `{s}[{d}:{d}]`", .{ i, name, info.lo, info.hi });
            return poison;
        }
        return (try self.arrayElemValue(name, i)) orelse poison;
    }

    // Runtime index: fold from the top down so element `lo` is the fallback.
    // An out-of-range index yields element `lo` (§3.2.2 leaves it undefined).
    const iv = try self.toInt(try self.lowerExpr(ex.rhs(e)));
    var acc: ?TypedValue = null;
    var i = info.hi;
    while (true) : (i -= 1) {
        const el = (try self.arrayElemValue(name, i)) orelse return poison;
        if (acc) |a| {
            const ty = unify(el.ty, a.ty);
            const c = try self.emit(.ieq, &.{ iv, try self.iconst(i) });
            const ev = if (ty == .real) try self.toReal(el) else el.v;
            const av = if (ty == .real) try self.toReal(a) else a.v;
            acc = .{ .v = try self.emit(.select, &.{ c, ev, av }), .ty = ty };
        } else {
            acc = el;
        }
        if (i == info.lo) break;
    }
    return acc orelse poison;
}

/// `{a, b, ...}` in a value position. The INTEGER form (§4.2.13) needs each
/// operand's bit width, which only the token text carries, so `parser.zig`
/// folds it and lowering never sees one; what is left here is §3.3 Table 3-3
/// `{Str1,...,Strn}`, "concatenation of Str1,…,Strn" — the LRM's own example is
/// `{ "hello", " ", "world" }` == `"hello world"`.
///
/// ponytail: constant operands only. A string Value is a `str_const` (there is
/// no runtime string in the emitted device), so a non-constant operand has
/// nothing to concatenate and is rejected rather than substituted.
fn lowerConcat(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const elems = self.file.exprs.args(e);
    if (elems.len == 0) {
        try self.errAt(e, .E0326, "", .{});
        return poison;
    }
    var out: std.ArrayList(u8) = .empty;
    for (elems) |el| {
        const tv = try self.lowerExpr(el);
        if (tv.ty != .string) {
            try self.errAt(e, .E0327, "only sized constants and strings can be concatenated", .{});
            return poison;
        }
        switch (self.mir.valueDef(tv.v)) {
            .str_const => |s| try out.appendSlice(self.arena, s),
            else => {
                try self.errAt(e, .E0328, "", .{});
                return poison;
            },
        }
    }
    // The interner borrows: the bytes live in the arena, which outlives the Mir.
    return .{ .v = try self.mir.addStrConst(self.arena, try out.toOwnedSlice(self.arena)), .ty = .string };
}

/// The Value of one scalarized element — a variable array (§3.2.2) or a
/// parameter array (§3.4.4).
fn arrayElemValue(self: *Lower, name: []const u8, i: i64) Oom!?TypedValue {
    var key_buf: [elem_key_len]u8 = undefined;
    const key = try self.elemKey(&key_buf, name, i);
    if (self.vars.get(key)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    if (self.param_index.get(key)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.params.items[idx].ty) };
    return null;
}

/// §2.8 name resolution: variables (§3.2) shadow parameters (§3.4), which
/// shadow genvars (§3.5). Nets are NOT values — they are only reachable
/// through an access function (§4.4).
fn lookupIdent(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const name = self.file.str(self.file.exprs.strOf(e));
    if (self.vars.get(name)) |slot|
        return .{ .v = try self.builder.readVariable(slot.place, self.cur), .ty = slot.ty };
    if (self.param_index.get(name)) |idx|
        return .{ .v = self.param_values.items[idx], .ty = astTy(self.params.items[idx].ty) };
    if (self.consts.get(name)) |c| return switch (c) {
        .int => .{ .v = try self.iconst(c.asInt()), .ty = .integer },
        .real => .{ .v = try self.fconst(c.asReal()), .ty = .real },
        .str => |s| .{ .v = try self.mir.addStrConst(self.arena, s), .ty = .string },
    };
    if (self.node_voltages.contains(name)) {
        var b = self.errAtWith(e, .E0315);
        b.msg("`{s}`", .{name});
        b.help("probe it: `V({s})` or `I({s})`", .{ name, name });
        try b.emit();
        return poison;
    }
    var b = self.errAtWith(e, .E0314);
    b.msg("`{s}`", .{name});
    const near = diag.didYouMeanMap(self.arena, name, self.vars) orelse
        diag.didYouMeanMap(self.arena, name, self.param_index) orelse
        diag.didYouMeanMap(self.arena, name, self.node_voltages) orelse
        diag.didYouMeanMap(self.arena, name, self.branches);
    if (near) |s| b.suggestHere(s);
    try b.emit();
    return poison;
}

/// A.8.6 unary operators. §4.2.3 (+/-), §4.2.7 (!), §4.2.9 (~).
fn lowerUnary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const a = try self.lowerExpr(ex.lhs(e));
    switch (ex.unOp(e)) {
        .plus => return a,
        .minus => return .{
            .v = try self.emit(if (a.ty == .real) .fneg else .ineg, &.{a.v}),
            .ty = a.ty,
        },
        .logical_not => return .{ .v = try self.emit(.lognot, &.{try self.toBool(a)}), .ty = .integer },
        .bit_not => {
            if (a.ty != .integer) {
                try self.errAt(e, .E0318, "`~` on a {s}", .{@tagName(a.ty)});
                return poison;
            }
            return .{ .v = try self.emit(.bitnot, &.{a.v}), .ty = .integer };
        },
        // §4.2.10 reduction on a two's-complement integer: `|x` is `x != 0`
        // and `&x` is "every bit set", i.e. `x == -1`. Both are expressible
        // with existing opcodes, so no bit-vector op is needed.
        .reduce_and, .reduce_nand, .reduce_or, .reduce_nor => |uop| {
            if (a.ty != .integer) {
                try self.errAt(e, .E0319, "got a {s}", .{@tagName(a.ty)});
                return poison;
            }
            const is_and = uop == .reduce_and or uop == .reduce_nand;
            const base = try self.emit(
                if (is_and) .ieq else .ine,
                &.{ a.v, if (is_and) Mir.Value.neg_one else Mir.Value.zero },
            );
            const negated = uop == .reduce_nand or uop == .reduce_nor;
            return .{
                .v = if (negated) try self.emit(.lognot, &.{base}) else base,
                .ty = .integer,
            };
        },
        // §4.2.10 xor reduction is a parity, which has no analog equivalent
        // and no MIR opcode (annex C).
        .reduce_xor, .reduce_xnor => {
            try self.errAt(e, .E0320, "", .{});
            return poison;
        },
    }
}

/// A.8.6 binary operators. LRM Table 4-3 precedence is the parser's job; this
/// only picks the opcode family from the operand types (§4.2.1).
fn lowerBinary(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const op = ex.binOp(e);

    // §4.2.7 && and || SHORT-CIRCUIT: the rhs must not be evaluated when the
    // lhs already decides the result, so this needs real control flow.
    if (op == .logical_and or op == .logical_or) return self.lowerShortCircuit(e, op);

    const a = try self.lowerExpr(ex.lhs(e));
    const b = try self.lowerExpr(ex.rhs(e));

    switch (op) {
        .add, .sub, .mul, .div, .mod => {
            const ty = unify(a.ty, b.ty);
            if (ty == .string) {
                try self.errAt(e, .E0321, "", .{});
                return poison;
            }
            const real = ty == .real;
            const opc: Mir.Opcode = switch (op) {
                .add => if (real) .fadd else .iadd,
                .sub => if (real) .fsub else .isub,
                .mul => if (real) .fmul else .imul,
                .div => if (real) .fdiv else .idiv,
                else => if (real) .fmod else .imod,
            };
            const lv = if (real) try self.toReal(a) else a.v;
            const rv = if (real) try self.toReal(b) else b.v;
            return .{ .v = try self.emit(opc, &.{ lv, rv }), .ty = ty };
        },
        // §4.3.1 Table 4-14: pow is a real-valued math function.
        .pow => return .{
            .v = try self.emit(.pow, &.{ try self.toReal(a), try self.toReal(b) }),
            .ty = .real,
        },
        .eq, .neq, .lt, .le, .gt, .ge => return .{ .v = try self.cmp(op, a, b), .ty = .integer },
        .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr => {
            if (a.ty != .integer or b.ty != .integer) {
                try self.errAt(e, .E0322, "got {s} and {s}", .{ @tagName(a.ty), @tagName(b.ty) });
                return poison;
            }
            const opc: Mir.Opcode = switch (op) {
                .bit_and => .bitand,
                .bit_or => .bitor,
                .bit_xor => .bitxor,
                .bit_xnor => .bitxnor,
                .shl => .shl,
                else => .shr,
            };
            return .{ .v = try self.emit(opc, &.{ a.v, b.v }), .ty = .integer };
        },
        // §4.2.5 case equality is a 4-state comparison (annex C).
        .case_eq, .case_neq => {
            var d = self.errAtWith(e, .E0323);
            d.help("use `==`; for reals prefer `abs(a - b) < tol`", .{});
            try d.emit();
            return poison;
        },
        // §4.2.11 arithmetic shifts have no MIR opcode: a Verilog-A `integer`
        // is signed, so `<<<`/`>>>` would need a separate signed-shift op.
        .ashl, .ashr => {
            var d = self.errAtWith(e, .E0324);
            d.help("use `<<` and `>>`", .{});
            try d.emit();
            return poison;
        },
        else => {
            try self.errAt(e, .E0325, "`{s}`", .{@tagName(op)});
            return poison;
        },
    }
}

/// §4.2.4 relational / §4.2.5 equality — integer 0/1 result either way.
fn cmp(self: *Lower, op: Ast.BinaryOp, a: TypedValue, b: TypedValue) Oom!Mir.Value {
    const real = unify(a.ty, b.ty) == .real;
    const opc: Mir.Opcode = switch (op) {
        .eq => if (real) .feq else .ieq,
        .neq => if (real) .fne else .ine,
        .lt => if (real) .flt else .ilt,
        .le => if (real) .fle else .ile,
        .gt => if (real) .fgt else .igt,
        else => if (real) .fge else .ige,
    };
    const lv = if (real) try self.toReal(a) else a.v;
    const rv = if (real) try self.toReal(b) else b.v;
    return self.emit(opc, &.{ lv, rv });
}

/// §4.2.7 `&&` / `||` with LRM short-circuit evaluation. The rhs gets its own
/// block, so a guard like `(x != 0) && (1/x > k)` never divides by zero.
fn lowerShortCircuit(self: *Lower, e: Ast.ExprId, op: Ast.BinaryOp) Oom!TypedValue {
    const ex = &self.file.exprs;
    const a = try self.toBool(try self.lowerExpr(ex.lhs(e)));
    const place = self.builder.newPlace();
    try self.builder.writeVariable(place, self.cur, a);

    const rhs_b = try self.newBlock();
    const join = try self.newBlock();
    // `a && b` evaluates b only when a is true; `a || b` only when a is false.
    if (op == .logical_and) {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, rhs_b, join);
    } else {
        _ = try self.mir.emitBranch(self.arena, self.cur, a, join, rhs_b);
    }
    try self.builder.addPredecessor(rhs_b, self.cur);
    try self.builder.addPredecessor(join, self.cur);
    try self.builder.sealBlock(rhs_b);

    self.cur = rhs_b;
    const b = try self.toBool(try self.lowerExpr(ex.rhs(e)));
    try self.builder.writeVariable(place, self.cur, b);
    try self.gotoBlock(join);

    try self.builder.sealBlock(join);
    self.cur = join;
    return .{ .v = try self.builder.readVariable(place, join), .ty = .integer };
}

/// §4.4.1 access function: `V(a)`, `V(a,b)`, `I(br)`.
/// A potential is the difference of two node unknowns; a flow that is *read*
/// makes the branch current an unknown of its own (§5.4.2).
fn lowerBranchAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.errAt(e, .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    const t = try self.branchOf(e) orelse return poison;
    switch (t.access) {
        .potential => {
            const hi = try self.probe(t.hi);
            if (t.lo == ground) return .{ .v = hi, .ty = .real };
            const lo = try self.probe(t.lo);
            return .{ .v = try self.emit(.fsub, &.{ hi, lo }), .ty = .real };
        },
        .flow => {
            const u = try self.flowUnknown(t.hi, t.lo);
            return .{ .v = try self.probe(u), .ty = .real };
        },
    }
}

/// LRM §5.4.3 port access — `I(<p>)`.
///
/// "The port access function accesses the flow into a port of a module. ...
/// However (<>) is used to delimit the port name, e.g., I(<a>) accesses the
/// current through module port a."
///
/// By KCL that current is precisely the sum of everything this module stamps at
/// `p`, i.e. the residual codegen is in the middle of assembling — so it cannot
/// be an expression over the other units without a cycle. It becomes its own
/// solver unknown, exactly like the §5.4.2 branch-flow unknown, and codegen
/// pins it with the row `x[u] − Σ stamps at p`.
fn lowerPortAccess(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.errAt(e, .E0421, "not allowed in {s}", .{ctx});
        return poison;
    }
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const access = self.access_kind.get(name) orelse {
        var b = self.errAtWith(e, .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(self.arena, name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return poison;
    };
    // §5.4.3 "The expression V(<a>) is invalid for ports and nets, where V is a
    // potential access function." A port access reads a FLOW, always.
    if (access == .potential) {
        try self.errAt(e, .E0507, "`{s}` is a potential access function", .{name});
        return poison;
    }
    const p = try self.nodeOf(ex.lhs(e));
    // §4.4.2 "For port access functions, the expression list is a single port
    // of the module"; §5.4.1 "it must be a declared port of the module in which
    // the port access function is used." An internal net has no outside, so its
    // port flow would be an identically-zero substitute — reject instead.
    if (p == ground or p >= self.num_ports) {
        var b = self.errAtWith(e, .E0508);
        b.msg("`{s}(<{s}>)`", .{ name, self.nodeName(p) });
        if (diag.didYouMeanMap(self.arena, self.nodeName(p), self.node_voltages)) |s|
            b.help("did you mean `{s}`?", .{s});
        try b.emit();
        return poison;
    }
    return .{ .v = try self.probe(try self.portFlowUnknown(p)), .ty = .real };
}

// ---- §4.3 math functions (Tables 4-14 and 4-15) ----------------------------

/// LRM Table 4-14 §4.3.1 / Table 4-15 §4.3.2 — the real-valued one-argument
/// functions, by their LRM spelling. `log` is base 10 (`log10` in MIR).
pub fn unaryMathOp(name: []const u8) ?Mir.Opcode {
    return unary_math.get(name);
}

/// LRM Table 4-14 — the real-valued two-argument functions.
pub fn binaryMathOp(name: []const u8) ?Mir.Opcode {
    return binary_math.get(name);
}

// File-scope so `unknownCall` can offer `.keys()` as did-you-mean candidates:
// a misspelled built-in is the commonest way to reach E0512, and the LRM's own
// spelling is the answer.
const unary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "sqrt", .sqrt },   .{ "exp", .exp },     .{ "expm1", .expm1 },
    .{ "ln", .ln },       .{ "ln1p", .ln1p },   .{ "log", .log10 },
    .{ "floor", .floor }, .{ "ceil", .ceil },   .{ "sin", .sin },
    .{ "cos", .cos },     .{ "tan", .tan },     .{ "asin", .asin },
    .{ "acos", .acos },   .{ "atan", .atan },   .{ "sinh", .sinh },
    .{ "cosh", .cosh },   .{ "tanh", .tanh },   .{ "asinh", .asinh },
    .{ "acosh", .acosh }, .{ "atanh", .atanh },
});

const binary_math = std.StaticStringMap(Mir.Opcode).initComptime(.{
    .{ "pow", .pow }, .{ "hypot", .hypot }, .{ "atan2", .atan2 },
});

/// §4.3 built-in math. `abs`/`min`/`max` keep integer operands integer
/// (§4.3.1: "if both operands are integer the result is integer").
fn lowerBuiltin(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);

    if (unaryMathOp(name)) |op| {
        if (args.len != 1) return self.arityError(e, name, 1);
        const a = try self.lowerExpr(args[0]);
        return .{ .v = try self.emit(op, &.{try self.toReal(a)}), .ty = .real };
    }
    if (binaryMathOp(name)) |op| {
        if (args.len != 2) return self.arityError(e, name, 2);
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        return .{ .v = try self.emit(op, &.{ try self.toReal(a), try self.toReal(b) }), .ty = .real };
    }
    if (std.mem.eql(u8, name, "abs")) {
        if (args.len != 1) return self.arityError(e, name, 1);
        const a = try self.lowerExpr(args[0]);
        const int = a.ty == .integer;
        return .{ .v = try self.emit(if (int) .iabs else .fabs, &.{a.v}), .ty = a.ty };
    }
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        if (args.len != 2) return self.arityError(e, name, 2);
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        const ty = unify(a.ty, b.ty);
        const is_min = name[1] == 'i';
        const op: Mir.Opcode = if (ty == .real)
            (if (is_min) .fmin else .fmax)
        else
            (if (is_min) .imin else .imax);
        const lv = if (ty == .real) try self.toReal(a) else a.v;
        const rv = if (ty == .real) try self.toReal(b) else b.v;
        return .{ .v = try self.emit(op, &.{ lv, rv }), .ty = ty };
    }
    try self.unknownCall(e, name);
    return poison;
}

/// E0512 with a suggestion drawn from everything that COULD have been called
/// here: the module's §4.7 analog functions and the §4.3 built-ins of Tables
/// 4-14/4-15. `m.functions` is a slice, not a map, so the candidates are
/// collected before `didYouMean` sees them — and the built-in names ride in the
/// same list so one call picks the single nearest of the whole set.
fn unknownCall(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!void {
    var b = self.errAtWith(e, .E0512);
    b.msg("`{s}`", .{name});

    var names: std.ArrayList([]const u8) = .empty;
    if (self.module) |m| {
        for (m.functions) |*fd| try names.append(self.arena, self.file.str(fd.name));
    }
    try names.appendSlice(self.arena, unary_math.keys());
    try names.appendSlice(self.arena, binary_math.keys());
    // §3.13.2 access functions land here too: the parser routes `Vv(p,n)` to a
    // function call precisely BECAUSE `Vv` is not an access name, so `V` is the
    // answer far more often than any analog function is.
    var it = self.access_kind.keyIterator();
    while (it.next()) |k| try names.append(self.arena, k.*);
    if (diag.didYouMean(name, names.items)) |s| b.suggestHere(s);

    return b.emit();
}

fn arityError(self: *Lower, e: Ast.ExprId, name: []const u8, want: usize) Oom!TypedValue {
    try self.errAt(e, .E0506, "`{s}()` takes {d}", .{ name, want });
    return poison;
}

// ---- §4.5 analog operators / filters ---------------------------------------

/// §4.5 analog operators. Each occurrence owns simulator state, so every one
/// stays a distinct `call` instruction carrying its arguments — codegen
/// allocates one Instance state slot per call site (§4.5.2).
///
/// Vector coefficient arguments (§4.5.11 laplace_*, §4.5.12 zi_*) are
/// FLATTENED into the argument list as `<count>, e0, e1, …`, so the call is
/// self-describing without a second pool.
/// The two A.8.2 `analog_filter_function_call` names that keep NO history.
///
/// §5.8.1 bans "an analog operator" under a runtime condition, and both of these
/// are listed in §4.5, so the letter of the rule covers them. Its stated reason
/// does not: §4.5.6 makes `ddx` a derivative of the expression as it stands on
/// THIS evaluation, and §4.5.13 makes `limexp` a piecewise-linear substitution
/// for `exp` past a critical voltage. Neither reads a previous timestep, so
/// neither can carry a wrong history out of a branch that was off — and E0514's
/// whole claim is about corrupted history. Warning on them would be noise that
/// teaches a modeller to silence the code; `vdmos.va` uses conditional `limexp`
/// three times and is right to.
fn isHistoryless(name: []const u8) bool {
    return std.mem.eql(u8, name, "ddx") or std.mem.eql(u8, name, "limexp");
}

fn lowerFilter(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    if (self.restrict) |ctx| {
        try self.errAt(e, .E0422, "not allowed in {s}", .{ctx});
        return poison;
    }
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);

    // §5.8.1 / §5.9: an analog operator is a state machine the kernel advances
    // once per accepted step, on the straight-line spine of the analog block.
    // Under a branch the solve can flip, the step its arm was off feeds it the
    // type's zero instead of the real input, and its history is wrong from then
    // on.
    if (self.cond_depth != self.static_cond_depth and !isHistoryless(name)) {
        var b = self.errAtWith(e, .E0514);
        b.msg("`{s}`", .{name});
        b.help("hoist `{s}(...)` onto the spine and make only its USE conditional", .{name});
        try b.emit();
    }

    // §4.5.6 ddx(f, V(node)) — the second argument is a probe, not a value:
    // it names the unknown to differentiate with respect to.
    if (std.mem.eql(u8, name, "ddx")) {
        if (args.len != 2) return self.arityError(e, name, 2);
        const f = try self.toReal(try self.lowerExpr(args[0]));
        if (ex.tag(args[1]) != .branch_access) {
            try self.errAt(e, .E0504, "", .{});
            return poison;
        }
        const t = try self.branchOf(args[1]) orelse return poison;
        const u: u16 = switch (t.access) {
            .potential => t.hi,
            .flow => try self.flowUnknown(t.hi, t.lo),
        };
        return .{ .v = try self.call("ddx", &.{ f, try self.iconst(u) }), .ty = .real };
    }

    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (args) |a| {
        // A.8.2 analog_filter_function_call has no `analog_expression_or_null`
        // form: every declared argument must be present (§4.5.14).
        if (a == .none) {
            try self.errAt(e, .E0505, "`{s}()`", .{name});
            return poison;
        }
        if (try self.appendVectorArg(&vals, a)) continue;
        const tv = try self.lowerExpr(a);
        try vals.append(self.arena, if (tv.ty == .string) tv.v else try self.toReal(tv));
    }
    return .{ .v = try self.call(name, vals.items), .ty = .real };
}

/// §4.5.11/§4.5.12 filter coefficient vectors and §9.21/§4.6.4 noise data
/// vectors: an assignment pattern `'{a,b}` or the name of an array parameter
/// (§3.4.4). Flattened into the call as `<count>, e0, e1, …`, so the argument
/// list stays self-describing. Returns false when `a` is an ordinary scalar.
fn appendVectorArg(self: *Lower, out: *std.ArrayList(Mir.Value), a: Ast.ExprId) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(a)) {
        .assign_pattern, .concat => {
            const elems = ex.args(a);
            try out.append(self.arena, try self.iconst(@intCast(elems.len)));
            for (elems) |el|
                try out.append(self.arena, try self.toReal(try self.lowerExpr(el)));
            return true;
        },
        .ident => {
            const name = self.file.str(ex.strOf(a));
            const info = self.arrays.get(name) orelse return false;
            try out.append(self.arena, try self.iconst(info.hi - info.lo + 1));
            var i = info.lo;
            while (i <= info.hi) : (i += 1) {
                const el = (try self.arrayElemValue(name, i)) orelse return true;
                try out.append(self.arena, try self.toReal(el));
            }
            return true;
        },
        else => return false,
    }
}

/// §4.6.4 noise sources. They contribute only in a small-signal noise
/// analysis; codegen decides that from the call name (the value is 0 in DC).
fn lowerNoise(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (ex.args(e)) |a| {
        if (a == .none) continue;
        if (try self.appendVectorArg(&vals, a)) continue;
        const tv = try self.lowerExpr(a);
        try vals.append(self.arena, if (tv.ty == .string) tv.v else try self.toReal(tv));
    }
    return .{ .v = try self.call(name, vals.items), .ty = .real };
}

// ---- ch9 system functions ---------------------------------------------------

/// ch9 system function in expression position. Everything not on the
/// deliberately-unsupported list becomes a `call`; codegen.emitCall dispatches
/// on the name and owns the simulator semantics.
fn lowerSysCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    if (isRejectedSysFunc(name)) {
        try self.errAt(e, .E0801, "`{s}`", .{name});
        return poison;
    }
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    if (ex.extraOf(e) < ex.pool.items.len) {
        for (ex.args(e)) |a| {
            if (a == .none) continue;
            try vals.append(self.arena, try self.lowerSysArg(a));
        }
    }
    return .{ .v = try self.call(name, vals.items), .ty = sysFuncTy(name) };
}

/// Several ch9 functions take a NET or PORT reference rather than a value —
/// §9.19 `$port_connected`, §9.20 `$analog_node_alias`, §9.22/§9.23 driver
/// access. A bare net name in argument position lowers to its node_order
/// index, which is what codegen needs; anything else is an ordinary value.
fn lowerSysArg(self: *Lower, e: Ast.ExprId) Oom!Mir.Value {
    const ex = &self.file.exprs;
    if (ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        const is_value = self.vars.contains(name) or self.param_index.contains(name) or
            self.consts.contains(name);
        if (!is_value) {
            if (self.node_voltages.get(name)) |idx| return self.iconst(idx);
        }
    }
    return (try self.lowerExpr(e)).v;
}

/// ch9 return types. Everything not listed is real (§9.14/§9.15 dominate).
fn sysFuncTy(name: []const u8) Ty {
    const ints = [_][]const u8{
        "$param_given", "$port_connected", // §9.19
        "$test$plusargs", "$value$plusargs", // §9.12
        // §9.11 Table 9-8. `$bitstoreal` is deliberately NOT here: it maps a
        // bit pattern TO a real, so its result is a real. Typing it as an
        // integer made codegen assign an `S` expression to an `i64` slot, which
        // does not even compile — see tests/fixtures/exhaustive/122.
        "$rtoi",          "$clog2",
        "$realtobits",
        "$driver_count", "$receiver_count", "$driver_state", "$driver_strength", // §9.22
        "$driver_delay", "$driver_next_state", "$driver_next_strength", "$driver_type", // §9.23
    };
    for (ints) |i| if (std.mem.eql(u8, name, i)) return .integer;
    if (std.mem.eql(u8, name, "$simparam$str")) return .string; // §9.15
    return .real;
}

// ---------------------------------------------------------------------------
// Class 9 — user-defined analog functions (LRM §4.7)
// ---------------------------------------------------------------------------

fn lowerUserCall(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const m = self.module orelse return poison;
    for (m.functions) |*fd| {
        if (!std.mem.eql(u8, self.file.str(fd.name), name)) continue;
        return self.inlineUserFunc(fd, ex.args(e), e);
    }
    // vpi_* and every other unresolved name lands here.
    try self.unknownCall(e, name);
    return poison;
}

/// LRM §4.7.3/§4.7.2 — analog functions are INLINED (§4.7.1 forbids
/// recursion, and there is no call ABI in the generated device).
///
/// §4.7.1 isolation: the body sees only its own arguments and locals, never
/// module variables — implemented by swapping in a fresh scope.
/// §4.7.2.3/§4.7.2.4: `output`/`inout` arguments are written back to the
/// caller's lvalue after the body runs.
pub fn inlineUserFunc(
    self: *Lower,
    fd: *const Ast.FuncDecl,
    arg_exprs: []const Ast.ExprId,
    site: Ast.ExprId,
) Oom!TypedValue {
    const name = self.file.str(fd.name);
    for (self.inlining.items) |n| {
        if (std.mem.eql(u8, n, name)) {
            try self.errAt(site, .E0510, "`{s}`", .{name});
            return poison;
        }
    }
    if (arg_exprs.len != fd.args.len) {
        try self.errAt(site, .E0511, "`{s}()` takes {d}, got {d}", .{ name, fd.args.len, arg_exprs.len });
        return poison;
    }

    // Actuals are evaluated in the CALLER's scope, before it is swapped out.
    var actuals: std.ArrayList(Mir.Value) = .empty;
    defer actuals.deinit(self.arena);
    for (fd.args, arg_exprs) |formal, actual| {
        if (formal.direction == .output) {
            try actuals.append(self.arena, zeroOf(astTy(formal.ty)));
            continue;
        }
        const tv = try self.lowerExpr(actual);
        try actuals.append(self.arena, switch (astTy(formal.ty)) {
            .real => try self.toReal(tv),
            .integer => try self.toInt(tv),
            .string => tv.v,
        });
    }

    // ---- enter the function scope (§4.7.1) ----
    const saved_vars = self.vars;
    const saved_arrays = self.arrays;
    const saved_ret = self.ret;
    const saved_restrict = self.restrict;
    const saved_loops = self.loops.items.len;
    const log_mark = self.scope_log.items.len;
    self.vars = .empty;
    self.arrays = .empty;
    self.restrict = "an analog function";
    try self.inlining.append(self.arena, name);

    // §4.7.2 local parameters fold to constants; they never reach the Model.
    for (fd.params) |*p| {
        if (self.constEval(p.default)) |c|
            try self.consts.put(self.arena, self.file.str(p.name), c);
    }

    const ret_ty = astTy(fd.ret_ty);
    const ret_slot = try self.declareVar(name, ret_ty); // §4.7.1 return variable
    try self.builder.writeVariable(ret_slot.place, self.cur, zeroOf(ret_ty));

    var arg_slots: std.ArrayList(VarSlot) = .empty;
    defer arg_slots.deinit(self.arena);
    for (fd.args, actuals.items) |formal, v| {
        const slot = try self.declareVar(self.file.str(formal.name), astTy(formal.ty));
        try self.builder.writeVariable(slot.place, self.cur, v);
        try arg_slots.append(self.arena, slot);
    }
    for (fd.vars) |*v| try self.declareVarDecl(v, .local);

    const exit = try self.newBlock();
    self.ret = .{ .slot = ret_slot, .exit = exit };
    try self.lowerStmt(fd.body);
    try self.gotoBlock(exit);
    try self.builder.sealBlock(exit);
    self.cur = exit;

    const result: TypedValue = .{
        .v = try self.builder.readVariable(ret_slot.place, self.cur),
        .ty = ret_ty,
    };
    // §4.7.2.3/§4.7.2.4 read the writeback values while the scope is still up.
    var writeback: std.ArrayList(Mir.Value) = .empty;
    defer writeback.deinit(self.arena);
    for (fd.args, arg_slots.items) |formal, slot| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        try writeback.append(self.arena, try self.builder.readVariable(slot.place, self.cur));
    }

    // ---- leave the function scope ----
    _ = self.inlining.pop();
    self.scope_log.shrinkRetainingCapacity(log_mark);
    self.vars.deinit(self.arena);
    self.arrays.deinit(self.arena);
    self.vars = saved_vars;
    self.arrays = saved_arrays;
    self.ret = saved_ret;
    self.restrict = saved_restrict;
    self.loops.shrinkRetainingCapacity(saved_loops);

    var w: usize = 0;
    for (fd.args, arg_exprs) |formal, actual| {
        if (formal.direction != .output and formal.direction != .inout) continue;
        defer w += 1;
        const slot = try self.resolveLvalue(actual) orelse continue;
        try self.builder.writeVariable(slot.place, self.cur, writeback.items[w]);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Class 9 — constant evaluation (LRM §4.2 constant_expression, §6.6.1)
// ---------------------------------------------------------------------------

/// Fold an elaboration-time constant: literals, genvars (§3.5) and parameters
/// (§3.4 — a parameter IS a constant expression for array bounds and
/// generate bounds, §6.6.1). Returns null when the expression is not constant.
pub fn constEval(self: *const Lower, e: Ast.ExprId) ?Const {
    return self.foldExpr(e, true);
}

/// The same fold with parameters EXCLUDED. A procedural `if (p > 0)` must stay
/// a runtime branch — `p` is overridable by the model card, so folding it to
/// its default would silently compile the wrong arm (§3.4 vs §6.6.2).
fn elabConst(self: *const Lower, e: Ast.ExprId) ?Const {
    return self.foldExpr(e, false);
}

fn foldExpr(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal => return .{ .int = ex.intValue(e) },
        .real_literal => return .{ .real = ex.realValue(e) },
        .str_literal => return .{ .str = self.file.str(ex.strOf(e)) },
        .pos_inf => return .{ .real = std.math.inf(f64) },
        .neg_inf => return .{ .real = -std.math.inf(f64) },
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) return null; // a runtime variable
            if (!params and self.param_index.contains(name)) return null;
            return self.consts.get(name);
        },
        .unary => {
            const a = self.foldExpr(ex.lhs(e), params) orelse return null;
            return switch (ex.unOp(e)) {
                .plus => a,
                .minus => switch (a) {
                    .int => |i| .{ .int = -i },
                    .real => |r| .{ .real = -r },
                    .str => null,
                },
                .logical_not => Const{ .int = @intFromBool(!a.isTrue()) },
                .bit_not => Const{ .int = ~a.asInt() },
                else => null,
            };
        },
        .binary => return self.foldBinary(e, params),
        .ternary => {
            const c = self.foldExpr(ex.lhs(e), params) orelse return null;
            return self.foldExpr(if (c.isTrue()) ex.rhs(e) else ex.ternaryElse(e), params);
        },
        // §4.3 math in a constant expression — the common subset only.
        .builtin_call => {
            const name = self.file.str(ex.strOf(e));
            const args = ex.args(e);
            if (args.len == 1) {
                const a = self.foldExpr(args[0], params) orelse return null;
                if (std.mem.eql(u8, name, "abs")) return switch (a) {
                    .int => |i| .{ .int = @intCast(@abs(i)) },
                    .real => |r| .{ .real = @abs(r) },
                    .str => null,
                };
                const x = a.asReal();
                const r: f64 = if (std.mem.eql(u8, name, "sqrt"))
                    @sqrt(x)
                else if (std.mem.eql(u8, name, "exp"))
                    @exp(x)
                else if (std.mem.eql(u8, name, "ln"))
                    @log(x)
                else if (std.mem.eql(u8, name, "log"))
                    @log10(x)
                else if (std.mem.eql(u8, name, "floor"))
                    @floor(x)
                else if (std.mem.eql(u8, name, "ceil"))
                    @ceil(x)
                else
                    return null;
                return .{ .real = r };
            }
            if (args.len == 2) {
                const a = self.foldExpr(args[0], params) orelse return null;
                const b = self.foldExpr(args[1], params) orelse return null;
                const int = a == .int and b == .int;
                if (std.mem.eql(u8, name, "min"))
                    return if (int) Const{ .int = @min(a.asInt(), b.asInt()) } else Const{ .real = @min(a.asReal(), b.asReal()) };
                if (std.mem.eql(u8, name, "max"))
                    return if (int) Const{ .int = @max(a.asInt(), b.asInt()) } else Const{ .real = @max(a.asReal(), b.asReal()) };
                if (std.mem.eql(u8, name, "pow"))
                    return .{ .real = std.math.pow(f64, a.asReal(), b.asReal()) };
                return null;
            }
            return null;
        },
        else => return null,
    }
}

fn foldBinary(self: *const Lower, e: Ast.ExprId, params: bool) ?Const {
    const ex = &self.file.exprs;
    const a = self.foldExpr(ex.lhs(e), params) orelse return null;
    const b = self.foldExpr(ex.rhs(e), params) orelse return null;
    const op = ex.binOp(e);
    // §4.2.1 integer arithmetic only when BOTH operands are integer.
    const int = a == .int and b == .int;
    const x = a.asReal();
    const y = b.asReal();
    return switch (op) {
        .add => if (int) Const{ .int = a.asInt() +% b.asInt() } else Const{ .real = x + y },
        .sub => if (int) Const{ .int = a.asInt() -% b.asInt() } else Const{ .real = x - y },
        .mul => if (int) Const{ .int = a.asInt() *% b.asInt() } else Const{ .real = x * y },
        .div => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @divTrunc(a.asInt(), b.asInt()) })
        else
            Const{ .real = x / y },
        .mod => if (int)
            (if (b.asInt() == 0) null else Const{ .int = @rem(a.asInt(), b.asInt()) })
        else
            Const{ .real = @rem(x, y) },
        .pow => .{ .real = std.math.pow(f64, x, y) },
        .eq => .{ .int = @intFromBool(x == y) },
        .neq => .{ .int = @intFromBool(x != y) },
        .lt => .{ .int = @intFromBool(x < y) },
        .le => .{ .int = @intFromBool(x <= y) },
        .gt => .{ .int = @intFromBool(x > y) },
        .ge => .{ .int = @intFromBool(x >= y) },
        .logical_and => .{ .int = @intFromBool(a.isTrue() and b.isTrue()) },
        .logical_or => .{ .int = @intFromBool(a.isTrue() or b.isTrue()) },
        .bit_and => .{ .int = a.asInt() & b.asInt() },
        .bit_or => .{ .int = a.asInt() | b.asInt() },
        .bit_xor => .{ .int = a.asInt() ^ b.asInt() },
        .bit_xnor => .{ .int = ~(a.asInt() ^ b.asInt()) },
        .shl, .shr => blk: {
            const sh = b.asInt();
            if (sh < 0 or sh > 63) break :blk null;
            if (op == .shl) break :blk Const{ .int = a.asInt() << @as(u6, @intCast(sh)) };
            // §4.2.11 `>>` fills the vacated positions with zeroes, over
            // §3.2.1's 32-bit `integer` — same rule codegen's `shrLogical`
            // emits, and the fold has to agree with it or a constant and a
            // computed operand give different answers.
            if (sh > 31) break :blk Const{ .int = 0 };
            const lo: u32 = @bitCast(@as(i32, @truncate(a.asInt())));
            break :blk Const{ .int = lo >> @as(u5, @intCast(sh)) };
        },
        else => null,
    };
}

// ponytail: deliberately deferred, each with its LRM section and upgrade path.
//   · §4.4.2/§5.4.3 port probes `I(<p>)` — needs a per-port branch unknown.
//   · §3.12 branch arrays and §6.5.2 vector ports/nets — the parser already
//     rejects the declarations; the checks here are the backstop.
//   · §6.2.2 module instantiation — rejected by the parser; a flat module is
//     the whole scope, so nothing here resolves a hierarchical name (§6.8).
//   · §3.2.2 runtime array indices — every index must fold (§4.2 constant
//     expression). A select chain would be the upgrade.
//   · §4.7.2 function-local `parameter` declarations fold into `consts` and
//     are not restored on exit: a module parameter of the same name would be
//     shadowed for the rest of the module. Give `consts` the same save/restore
//     treatment as `vars` if a fixture ever does that.

// ---------------------------------------------------------------------------
// Self-check: the whole frontend on two small modules — the split that class 6
// and codegen depend on, plus one diagnostic. Runs on std.testing.allocator
// through an arena, so a leaked byte fails the test.
// ---------------------------------------------------------------------------

const Preprocessor = @import("preprocessor.zig");
const Parser = @import("parser.zig");

const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    bag: diag.Bag,
    low: Lower,

    fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .bag = undefined,
            .low = undefined,
        };
        const arena = out.arena_state.allocator();
        out.bag = diag.Bag.init(arena);
        const text = try Preprocessor.process(arena, src, .{ .bag = &out.bag });
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
    }

    /// The code of the i'th diagnostic. Assertions key on the CODE, never on
    /// prose: the message no longer carries the LRM citation (`Info.lrm` does)
    /// and the title is not part of the message at all.
    fn code(self: *const Harness, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    fn msg(self: *const Harness, i: usize) []const u8 {
        return self.bag.at(i).message;
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

test "lower: contribution splits into resistive and reactive parts" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module rc(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1k from (0:inf);
        \\  parameter real c = 1p;
        \\  real g;
        \\  analog begin
        \\    g = 1.0 / r;
        \\    if (V(p,n) > 0.0)
        \\      I(p,n) <+ g * V(p,n);
        \\    I(p,n) <+ ddt(c * V(p,n));
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    // §6.5 ports first, in header order — this is the host's terminal order.
    try std.testing.expectEqual(@as(usize, 2), h.low.num_ports);
    try std.testing.expectEqualStrings("p", h.low.node_order.items[0]);
    try std.testing.expectEqualStrings("n", h.low.node_order.items[1]);

    // §3.4.2 the value range MUST survive to proof.zig.
    try std.testing.expectEqual(@as(usize, 2), h.low.params.items.len);
    try std.testing.expectEqualStrings("r", h.low.params.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), h.low.params.items[0].ranges.len);
    try std.testing.expectEqual(Ast.ValueRange.Kind.from, h.low.params.items[0].ranges[0].kind);

    // §5.6.1.3 both `<+` statements accumulate into ONE target…
    try std.testing.expectEqual(@as(usize, 1), h.low.contributions.items.len);
    const c = h.low.contributions.items[0];
    try std.testing.expectEqual(Access.flow, c.access);
    try std.testing.expectEqual(@as(u16, 0), c.hi);
    try std.testing.expectEqual(@as(u16, 1), c.lo);
    // …and §5.6.1.2 splits them: the guarded g*V is resistive, ddt(c*V) is not.
    const resist = h.mir.resolveAlias(c.resist_val);
    const react = h.mir.resolveAlias(c.react_val);
    try std.testing.expect(resist != .f_zero); // a phi over the §5.8 guard
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(resist).inst_result));
    // The reactive part is `c * V(p,n)` — the charge, NOT its derivative.
    const react_inst = h.mir.valueDef(react).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fadd, h.mir.instOp(react_inst));
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(
        h.mir.valueDef(h.mir.instData(react_inst).binary.rhs).inst_result,
    ));
}

test "lower: §5.6.7 indirect contribution is a nullor entry, one per statement" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog begin
        \\    V(out) : V(pin, nin) == 2.0 * V(out);
        \\    V(out) : V(pin) == 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    // §5.6.7.1 several indirect contributions are legal, and each is its own
    // equation — NEVER accumulated the way §5.6.1.3 accumulates `<+`.
    try std.testing.expectEqual(@as(usize, 2), h.low.contributions.items.len);
    for (h.low.contributions.items) |c| {
        try std.testing.expectEqual(Kind.indirect, c.kind);
        try std.testing.expectEqual(Access.potential, c.access);
        try std.testing.expectEqual(@as(u16, 0), c.hi); // out
        try std.testing.expectEqual(ground, c.lo);
        try std.testing.expectEqual(Mir.Value.f_zero, c.react_val);
    }
    // Row ORIENTATION: probe − equation, so the top-level op is `fsub` whose
    // LHS is the probe slice. Reversed, the residual is negated and an
    // asymmetric equation converges to the wrong point.
    const row = h.mir.resolveAlias(h.low.contributions.items[0].resist_val);
    const inst = h.mir.valueDef(row).inst_result;
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(inst));
    const lhs = h.mir.resolveAlias(h.mir.instData(inst).binary.lhs);
    // lhs is V(pin,nin) = x[pin] − x[nin]; rhs is the 2.0*V(out) product.
    try std.testing.expectEqual(Mir.Opcode.fsub, h.mir.instOp(h.mir.valueDef(lhs).inst_result));
    const rhs = h.mir.resolveAlias(h.mir.instData(inst).binary.rhs);
    try std.testing.expectEqual(Mir.Opcode.fmul, h.mir.instOp(h.mir.valueDef(rhs).inst_result));
}

test "lower: §5.6.7.2 an indirectly assigned branch refuses <+, in either order" {
    // The two orders are mirror images, and each has its own code.
    const cases = [_]struct { want: diag.Code, src: []const u8 }{
        .{ .want = .E0409, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    V(p, n) : V(p) == 0.0;
        \\    I(p, n) <+ 1e-6;
        \\  end
        \\endmodule
        },
        // …and the reverse order, on the reversed net pair (a "parallel
        // branch" in §5.6.7.2's words).
        .{ .want = .E0415, .src =
        \\module a(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    I(n, p) <+ 1e-6;
        \\    V(p, n) : V(p) == 0.0;
        \\  end
        \\endmodule
        },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.code(0));
    }
}

test "lower: §5.6.7 indirect is banned under a runtime condition, allowed under a constant one" {
    var bad: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (V(i) > 0.0) V(o) : V(i) == 0.0;
        \\endmodule
    , &bad);
    defer bad.deinit();
    try std.testing.expectError(error.DiagnosticsReported, bad.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0412, bad.code(0));

    // "…unless the conditional expression is a constant expression": a folded
    // condition lowers its arm straight into the current block, so it never
    // raises `cond_depth`. (A §3.4 `parameter` is deliberately NOT foldable
    // here — one artifact serves every model card — and `elabConst` treats a
    // §3.4.5 `localparam` the same way, so this uses a literal.)
    var ok: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module a(o, i);
        \\  inout o, i;
        \\  electrical o, i;
        \\  analog if (1) V(o) : V(i) == 0.0;
        \\endmodule
    , &ok);
    defer ok.deinit();
    try ok.low.lowerFile();
    try std.testing.expectEqual(@as(usize, 1), ok.low.contributions.items.len);
    try std.testing.expectEqual(Kind.indirect, ok.low.contributions.items[0].kind);
}

test "lower: a ddt that is not a linear factor is a diagnostic, not wrong physics" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p,n) <+ sin(ddt(V(p,n)));
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0503, h.code(0));
}

test "lower: genvar loops unroll, procedural loops do not" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module chain(a, b);
        \\  inout a, b;
        \\  electrical a, b;
        \\  genvar i;
        \\  analog begin
        \\    for (i = 0; i < 3; i = i + 1)
        \\      I(a,b) <+ i * V(a,b);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    // §6.6.1: three unrolled bodies accumulate into one target, and the loop
    // left no CFG behind (entry only).
    try std.testing.expectEqual(@as(usize, 1), h.low.contributions.items.len);
    try std.testing.expectEqual(@as(u32, 1), h.mir.blockCount());
}

test "lower: §5.4.3 port access — what is rejected, and what the unknown is" {
    const cases = [_]struct { src: []const u8, want: diag.Code, msg: []const u8 = "" }{
        // "The expression V(<a>) is invalid for ports and nets, where V is a
        // potential access function."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(p) <+ V(<p>);
        \\endmodule
        , .want = .E0507, .msg = "potential access function" },
        // "The port access function shall not be used on the left side of a
        // contribution operator <+."
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  analog I(<p>) <+ 1.0;
        \\endmodule
        , .want = .E0407 },
        // §4.4.2 "the expression list is a single port of the module": an
        // internal net has no outside, so I(<n>) would be an identical zero.
        .{ .src =
        \\module m(p);
        \\  inout p; electrical p;
        \\  electrical n;
        \\  analog I(p, n) <+ I(<n>);
        \\endmodule
        , .want = .E0508, .msg = "I(<n>)" },
    };
    for (cases) |c| {
        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, c.src, &h);
        defer h.deinit();
        try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
        try std.testing.expectEqual(c.want, h.code(0));
        if (c.msg.len != 0)
            try std.testing.expect(std.mem.indexOf(u8, h.msg(0), c.msg) != null);
    }
}

test "lower: §5.4.3 repeated I(<p>) is one unknown, appended after the ports" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(a, c);
        \\  inout a, c; electrical a, c;
        \\  analog I(a, c) <+ I(<a>) + I(<c>) + I(<a>);
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();

    try std.testing.expectEqual(@as(usize, 2), h.low.num_ports);
    try std.testing.expectEqual(@as(usize, 2), h.low.port_probes.items.len);
    // Deduped by port, in first-probe order, and never inside `num_ports`.
    try std.testing.expectEqual(@as(u16, 0), h.low.port_probes.items[0].port);
    try std.testing.expectEqual(@as(u16, 1), h.low.port_probes.items[1].port);
    for (h.low.port_probes.items) |pp| {
        try std.testing.expect(pp.u >= h.low.num_ports);
        // The name codegen's `flow(` predicate keys on, and which no §2.7/§2.8.1
        // identifier and no `flow(a,b)` branch unknown can collide with.
        try std.testing.expect(std.mem.startsWith(u8, h.low.nodeName(pp.u), "flow(<"));
    }
    try std.testing.expectEqualStrings("flow(<a>)", h.low.nodeName(h.low.port_probes.items[0].u));
}

test "lower: §9.17.2 $bound_step accumulates through the CFG, not unconditionally" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bs(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $bound_step(1n);
        \\    if (V(p,n) > 0.0) $bound_step(1p);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // Exactly ONE synthetic call, and its argument is a phi: the guarded
    // `$bound_step(1p)` must NOT bound the step on the arm that never ran.
    var found: ?Mir.Value = null;
    var blocks = h.mir.blockIter();
    while (blocks.next()) |b| {
        var it = h.mir.blockInsts(b);
        while (it.next()) |inst| {
            if (h.mir.instOp(inst) != .call) continue;
            if (!std.mem.eql(u8, h.mir.instData(inst).call.name, "$bound_step")) continue;
            try std.testing.expect(found == null);
            found = h.mir.instData(inst).call.args[0];
        }
    }
    const arg = h.mir.resolveAlias(found orelse return error.NoBoundStepCall);
    try std.testing.expectEqual(Mir.Opcode.phi, h.mir.instOp(h.mir.valueDef(arg).inst_result));
    // …and nothing was emitted for §9.17.1, which this module never calls.
    try std.testing.expect(h.low.disc_place == null);
}

test "lower: §9.17.1 $discontinuity folds its degree; the $limit form (-1) emits nothing" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(-1);
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());
    // §9.17.1's `-1` exists only for `$limit`; there is no announcement to make,
    // so no place, no synthetic call, and therefore no unit.
    try std.testing.expect(h.low.disc_place == null);
    try std.testing.expect(h.low.bound_step_place == null);

    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d2(p, n);
        \\  inout p, n; electrical p, n;
        \\  analog begin
        \\    $discontinuity(2);
        \\    $discontinuity;
        \\    I(p,n) <+ V(p,n);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());
    try std.testing.expect(h2.low.disc_place != null);
}

test "lower: A.6.4 the analog_statement / analog_event_statement split" {
    // §5.10 "Contribution statements cannot be used inside an event control
    // block"; A.6.4 `analog_event_statement` has no contribution alternative.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module e(p, c);
        \\  inout p, c; electrical p, c;
        \\  analog @(cross(V(c), +1)) I(p) <+ V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h.bag.count());
    try std.testing.expectEqual(diag.Code.E0406, h.code(0));

    // `disable` is the mirror image: absent from `analog_statement`, present in
    // `analog_event_statement`. There is no §5.11 entry for it (5.11 is
    // jump_statement), so the diagnostic must not claim one.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p);
        \\  inout p; electrical p;
        \\  analog begin : work
        \\    if (V(p) > 1.0) disable work;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(@as(usize, 1), h2.bag.count());
    try std.testing.expectEqual(diag.Code.E0401, h2.code(0));
    // A.6.4, never §5.11 (which is jump_statement) — the citation is the code's.
    try std.testing.expectEqualStrings("A.6.4", diag.info(.E0401).lrm);
}

test "lower: an unknown name carries a `did you mean` help" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  real vds;
        \\  analog I(p) <+ vdss * V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0314, h.code(0));
    try std.testing.expectEqualStrings("`vdss`", h.msg(0));
    var nbuf: [diag.max_children]diag.Note = undefined;
    const notes = h.bag.notes(h.bag.at(0), &nbuf);
    try std.testing.expectEqual(@as(usize, 1), notes.len);
    try std.testing.expectEqualStrings("did you mean `vds`?", notes[0].text);
}

test "lower: §3.3 Table 3-3 string concatenation folds; the integer form never reaches here" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p);
        \\  inout p;
        \\  electrical p;
        \\  string a = "hello", b = "world", c;
        \\  analog begin
        \\    c = {a, " ", b};
        \\    I(p) <+ 0.0 * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try h.low.lowerFile();
    try std.testing.expect(h.bag.isEmpty());

    // The LRM's own example: `{ "hello", " ", "world" }` == `"hello world"`.
    var found = false;
    for (h.mir.strings.strings.items) |s| {
        if (std.mem.eql(u8, s, "hello world")) found = true;
    }
    try std.testing.expect(found);

    // A non-string operand has no width here (the parser folds the sized-
    // constant form), so it is rejected rather than silently coerced.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m; integer a, b; analog a = {b, b}; endmodule
    , &h2);
    defer h2.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h2.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0327, h2.code(0));
    try std.testing.expect(std.mem.indexOf(u8, h2.msg(0), "only sized constants") != null);
}

test "lower: §5.8.1 an analog operator under a runtime condition (E0514)" {
    // What makes this rule worth a diagnostic: an analog operator is a state
    // machine the kernel steps once per accepted timestep. Under a branch the
    // solve can flip, the step its arm was off feeds it the type's zero, and its
    // history is wrong from then on — with a residual that still looks ordinary.
    //
    // Each case is the SAME operator under a different condition; only the
    // condition decides the verdict, which is exactly what §5.8.1 says.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        // Not an analysis_or_constant_expression: a probe moves every iteration.
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "V(c) > 0.5 && gain > 0.0", .warns = true },
        // A.8.2 analysis_function_call — §5.8.1 names it explicitly.
        .{ .cond = "analysis(\"dc\")", .warns = false },
        .{ .cond = "!analysis(\"tran\")", .warns = false },
        // constant_primary: a §3.4 parameter cannot move mid-analysis.
        .{ .cond = "gain > 0.0", .warns = false },
        .{ .cond = "analysis(\"dc\") || gain > 0.0", .warns = false },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n, c);
            \\  inout p, n, c;
            \\  electrical p, n, c;
            \\  parameter real gain = 1.0;
            \\  real q;
            \\  analog begin
            \\    q = 0.0;
            \\    if ({s}) q = ddt(V(p, n));
            \\    I(p, n) <+ q;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        };

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0514) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}

test "lower: §5.9 a loop body has no carve-out, and §4.5.6/§4.5.13 have no history" {
    // §5.9's ban on analog filter functions in repeat/while/non-genvar `for` is
    // unconditional — there is no analysis_or_constant escape hatch — so a
    // constant loop bound does NOT license the operator.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0514, h.code(0));

    // ...but a genvar `for` (§5.9.3 analog_for) is unrolled onto the spine, so
    // every operator instance is stepped every time: no warning.
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  genvar i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();
    try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());

    // `ddx` (§4.5.6) and `limexp` (§4.5.13) read no previous timestep, so a
    // branch that was off cannot corrupt them. `vdmos.va` calls conditional
    // `limexp` three times; warning there would be noise, and noise is what
    // teaches a modeller to silence the code.
    var h3: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module m(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  real q;
        \\  analog begin
        \\    q = 0.0;
        \\    if (V(c) > 0.5) q = limexp(V(p, n)) + ddx(V(p, n), V(p));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    , &h3);
    defer h3.deinit();
    try h3.low.lowerFile();
    try std.testing.expect(h3.bag.isEmpty());
}

test "lower: §5.8/§5.10.3.1 an event control statement is stricter than E0514" {
    // §5.8: event control "cannot be used inside conditional statements unless
    // the conditional expression is a constant expression" — CONSTANT, not
    // analysis_or_constant. So the very condition that licenses `ddt` above
    // still rejects `@(cross(...))`, and the two rules must not share a counter.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "analysis(\"dc\")", .warns = true },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, c);
            \\  inout p, c;
            \\  electrical p, c;
            \\  real held;
            \\  analog begin
            \\    held = 0.0;
            \\    if ({s}) @(cross(V(c) - 1.0, 1)) held = V(p);
            \\    I(p) <+ held;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        };

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.code(i) == .E0707) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}
