//! Classes 4,5,8,10 — MIR → device.zig. Emits contract-shaped Zig.
//! LRM: §5 behavior (eval/q), §4.5 analog operators (state machine), ch9 system
//! functions, §8.3 device-side simulation contract.
//!
//! Transformation: Mir + Lower + proof.Verdict → device.zig source string.
//!
//! THE INCREMENTAL RULE (docs/architecture/03-codegen.html): emit ONE Zig
//! function per source unit, each with a STABLE name (naming.zig) and the SAME
//! signature, plus a thin dispatcher eval/q. Do NOT emit a monolithic eval and
//! do NOT name values `v{d}` by MIR index — both defeat `zig -fincremental`.
//!
//! DOD: write into one growing output buffer (gpa-owned; every scratch table is
//! on the compilation arena — see `generate`). Determinism is mandatory:
//! identical MIR ⇒ byte-identical output (a no-op edit must reproduce the file).
//!
//! SHAPE OF THE OUTPUT (top-down, so it reads like it is generated):
//!   1. imports + S-generic value-form math helpers                      (§4.3)
//!   2. `U` enum from Lower.node_order (ports first) + `num_ports`  (§1.3.1/§6.5)
//!   3. `Model`  — one field per parameter, spec default                  (§3.4)
//!   4. `Instance` — temperature/abstime/analysis kind + per-operator state (§4.5)
//!   5. one fn per source unit, uniform signature, per-unit @setFloatMode
//!   6. dispatchers `eval` (resistive) and `q` (reactive)                 (§5.6)
//!   7. `initState`/`updateState` advancing stateful operators          (§4.5.2)
//!   8. `comptime { contract.validate(Self); }`
//!
//! CONTROL FLOW. MIR is a CFG; Zig is structured. The reconstruction is the
//! dominator-tree + labelled-block scheme (Ramsey, "Beyond Relooper"): a merge
//! block Y (>1 predecessor) that is an immediate dominator child of X becomes a
//! labelled block opened inside X's emission and closed just before Y's own
//! code, so every edge into Y is `break :B<Y>`; a back edge is `continue :L<X>`
//! on the loop header's `while (true)`. That is exact for every reducible CFG,
//! which is what lowering (structured source) can produce — including `break` /
//! `continue` / inlined-function `return`, which a diamond-matcher would miss.
//! Phis are materialised as function-scope `var`s assigned on each incoming
//! edge (the standard SSA-out-of-form move); an ALIASED phi (ssa.zig's
//! trivial-phi removal) never gets one — every Value is `resolveAlias`d first.

const std = @import("std");
const Mir = @import("mir.zig");
const Lower = @import("lower.zig");
const proof = @import("proof.zig");
const diag = @import("diag.zig");
const naming = @import("naming.zig");
const assert = std.debug.assert;

pub const Error = std.mem.Allocator.Error || error{
    /// proof.zig rejected the model; codegen is gated on it (03-codegen.html).
    DomainErrors,
    /// A source identifier whose structural key exceeds `naming.max_name_len`.
    /// Never truncated: truncation would break the injectivity two distinct
    /// units rely on.
    NameTooLong,
};

const none_u32 = std.math.maxInt(u32);

/// The generated device, plus the map that lets the orchestrator write it out
/// as ONE FILE PER UNIT DECLARATION (docs/architecture/02-incremental.html).
///
/// Why a map rather than N buffers: `zig` keys its per-file ZIR cache on
/// `stat_inode`/`stat_size`/`stat_mtime` (`std/zig/Zir.zig`'s `Zir.Header`), so
/// leaving a file untouched is exactly what makes `zig` skip AstGen for it.
/// `orchestrator.writeIfChanged` already had the right rationale in its doc
/// comment, but it was applied at whole-device granularity — 182 MB rewritten
/// for a one-line edit, and every declaration re-hashed. Splitting the WRITE
/// fixes that without splitting the codegen buffer: `text` stays the single
/// contiguous emission (`--emit-zig` still writes it verbatim, which is what
/// keeps `tests/baseline.sh` a byte oracle), and the split is a view over it —
/// two `u32` appends per unit, no second buffer, the same reserve-and-record
/// trick as the signature back-patch.
///
/// INVARIANT: the ranges TILE. `unit_lo[i] == unit_hi[i-1]`, so
/// `text[0..unit_lo[0]]` is the prologue and `text[unit_hi[n-1]..]` is the
/// dispatcher tail, with nothing in between that is not a unit.
pub const Output = struct {
    /// Whole device as one text — gpa-owned (see `generate`).
    text: []const u8,
    /// One entry per emitted top-level unit declaration, in emission order.
    /// `names[i]` is BOTH the declaration name and the file stem, which is what
    /// makes the file set churn exactly as `naming.zig`'s keys do. Arena-owned.
    names: []const []const u8 = &.{},
    unit_lo: []const u32 = &.{},
    /// Offset of the declaration keyword inside `text`. The writer splices
    /// `pub ` here; see `Gen.emitUnit` for why `text` cannot carry it itself.
    unit_fn: []const u32 = &.{},
    unit_hi: []const u32 = &.{},
    /// File-scope prologue every `u/<key>.zig` needs: a unit file is a separate
    /// Zig FILE, and Zig has no textual include, so nothing `device.zig`
    /// declares is in its scope. Arena-owned; empty when `names` is.
    prelude: []const u8 = "",
    /// `h.zig`: the §4.3/§4.5 helper kernels, PUBLIC, for the unit files to
    /// alias. device.zig keeps its own private copy inline — `text` has to
    /// stay a valid stand-alone device, and `contract.rejectStrayPubDecls`
    /// forbids publishing them there — so this duplicates ~30 tiny generic
    /// functions that `zig` analyses lazily and only where used. Arena-owned;
    /// empty when `names` is.
    helpers: []const u8 = "",

    /// The un-split form: one `device.zig`, no `u/` directory. Used by
    /// `--emit-zig`, by the conformance runner, and by the orchestrator tests.
    pub fn single(text: []const u8) Output {
        return .{ .text = text };
    }
};

/// What to do with the §9.4 display tasks a model contains.
///
/// The default is `.drop`, and it is not a shrug: a device is compiled once and
/// evaluated in the solver's inner loop, on a batch, sometimes on a GPU. A
/// `std.debug.print` in there is a per-Newton-iteration syscall on the CPU and
/// does not compile at all for SPIR-V/PTX. So a device NEVER prints, and a
/// source that asked to is told so (W0850) rather than silently obeyed.
///
/// `.emit` is the other product FastVAF makes out of the same .va: a runnable
/// testbench, where the whole point is the text. See `--emit-exe` and src/tb.zig.
pub const Display = enum { drop, emit };

/// Knobs that change WHAT is generated (not how fast). One field today; it is a
/// struct so the next one does not churn `generate`'s signature again.
pub const Options = struct {
    display: Display = .drop,
    /// Where a codegen-stage diagnostic goes (E0515). Optional: the unit tests
    /// and any caller that only wants text pass none, and codegen then reports
    /// a refusal through `fatal_out` alone.
    ///
    /// NOT `lower.bag`: that pointer names the COMPILATION's bag, which
    /// `root.finish` has already detached into the caller's by the time codegen
    /// runs. This is the caller's bag, and it is alive for as long as the
    /// `CompileResult` is.
    diags: ?*diag.Bag = null,
};

/// Emit the whole device.zig. LRM §5/§8.3.
///
/// `arena` MUST be an arena (the per-compilation one): every scratch table is
/// allocated from it and freed with it — this pass has no deinit.
///
/// `gpa` owns the RETURNED SLICE and nothing else. The output buffer is the one
/// allocation here that grows unboundedly (182 MB on `hisimhv_va`), and
/// `ArenaAllocator.resize` refuses in-place growth for anything but the most
/// recent allocation — which `out` never is, since `fmtF64` allocates in
/// between. In an arena every regrow is therefore a full copy whose old buffer
/// is never reclaimed. Zig makes the same split: `Ast.renderAlloc` takes a gpa,
/// and `zig fmt`'s `out_buffer` is a gpa-backed `Allocating` reused across
/// files. Caller frees (see `CompileResult.deinit`).
///
/// Determinism: nothing on this path iterates a hash map.
pub fn generate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    verdict: proof.Verdict,
    /// Set if any unit collapsed to `@compileError` (see `Gen.any_fatal`).
    fatal_out: *bool,
    opts: Options,
) Error!Output {
    if (!verdict.ok()) return error.DomainErrors;
    // §6.2: the port list is OPTIONAL, so a module with no ports (and even a
    // module with no nets at all — §3.4 parameter-only modules are legal
    // Verilog-A) is a valid compilation unit. It yields a degenerate device
    // with `num_ports == 0` and an empty `U`, which the host simply never
    // stamps; that is a host-side triviality, not a source-language error.

    var g: Gen = .{
        .gpa = gpa,
        .arena = arena,
        .mir = mir,
        .lower = lower,
        .verdict = verdict,
        .display = opts.display,
        .diags = opts.diags,
    };
    errdefer g.out.deinit(gpa);
    try g.prepare();
    try g.emitFile();
    fatal_out.* = g.any_fatal;
    return .{
        .text = try g.out.toOwnedSlice(gpa),
        .names = g.file_names.items,
        .unit_lo = g.file_lo.items,
        .unit_fn = g.file_fn.items,
        .unit_hi = g.file_hi.items,
        .prelude = g.prelude,
        .helpers = g.helpers,
    };
}

// ===========================================================================
// Value typing — every MIR Value is emitted either as an `S` (real) or as a
// plain `i64` (LRM §3.2 integer). §4.2.1.1/§4.2.1.2 conversions are inserted at
// the use site, so a typing miss degrades to a redundant cast, never to code
// that does not compile.
// ===========================================================================

const VTy = enum(u8) { real, int, str };

/// Zero-sized context for `Gen.f64_cache`. The key is an f64's bit pattern,
/// which is already in a register; `AutoContext` would run
/// `Wyhash.hash(0, asBytes(&key))` over it. Being zero-sized means no call site
/// changes shape.
const F64Context = struct {
    pub fn hash(_: F64Context, k: u64) u64 {
        return std.hash.int(k);
    }
    pub fn eql(_: F64Context, a: u64, b: u64) bool {
        return a == b;
    }
};

// ===========================================================================
// The generator
// ===========================================================================

const Gen = struct {
    /// Owns `out` and nothing else — see `generate`.
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    mir: *const Mir,
    lower: *const Lower,
    verdict: proof.Verdict,
    out: std.ArrayList(u8) = .empty,
    /// Rendered text of every float constant seen, keyed on its bit pattern.
    /// See `fmtF64`.
    f64_cache: std.HashMapUnmanaged(u64, []const u8, F64Context, std.hash_map.default_max_load_percentage) = .empty,

    /// Whether the unit body being rendered read each parameter. Zig treats an
    /// unused parameter as a hard error, so the signature has to say `_` — see
    /// `emitUnit` for how that is resolved without a second buffer.
    uses_x: bool = false,
    uses_model: bool = false,
    uses_inst: bool = false,
    /// Set when the unit needs something FastVAF deliberately does not
    /// implement (§4.5.11 filters, §9.13 $random, …). The whole body collapses
    /// to one `@compileError` — a substitute value would corrupt the physics,
    /// and a per-statement error would bury the reason in a cascade.
    fatal: ?[]const u8 = null,
    /// Sticky: any unit collapsed to `@compileError`. Reported out so callers do
    /// not have to substring-search the generated file for it.
    any_fatal: bool = false,
    /// Seeds `fatal` for the NEXT unit, for a gap visible from the unit's
    /// DECLARATION rather than from an instruction in its body (§3.6.2.2
    /// signal-flow contributions). `emitUnit` consumes it.
    pre_fatal: ?[]const u8 = null,
    /// Token of the §4.5 operator call whose arguments are being rendered — the
    /// fallback span for E0515 when the offending argument is a leaf with no
    /// instruction of its own (a node probe has no token).
    // ponytail: one field set at the two places that render operator arguments,
    // rather than threading a token through `argF64`'s fifteen call sites.
    // Ceiling: it is only ever read on the E0515 path, which refuses the unit.
    ctrl_tok: u32 = Mir.no_tok,

    units: []naming.Unit = &.{},
    unit_names: [][]const u8 = &.{},
    /// One entry per emitted top-level unit declaration — see `Output`. Arena
    /// lists, appended by `recordUnitFile`; two `u32`s per unit is the whole
    /// cost of the per-file split on this side.
    file_names: std.ArrayList([]const u8) = .empty,
    file_lo: std.ArrayList(u32) = .empty,
    file_fn: std.ArrayList(u32) = .empty,
    file_hi: std.ArrayList(u32) = .empty,
    /// See `Output.prelude` / `Output.helpers`. Built by `emitFile`, which is
    /// where the conditionally-emitted helper blocks are already decided.
    prelude: []const u8 = "",
    helpers: []const u8 = "",

    // ---- the shared core (03-codegen.html#hoisting) ----
    /// Every unit function to emit, resolved before any of them is written.
    jobs: []Job = &.{},
    /// Position of this Value in the core's returned struct, or `none_u32`.
    /// Only the unit TARGETS cross the declaration boundary; every one of the
    /// ~22 000 subexpressions behind them stays a local of the core.
    lo_idx: []u32 = &.{},
    /// The returned values, in job order — `lo_idx` is the index into this.
    lo_vals: []Mir.Value = &.{},
    /// Set while the core is being emitted. It slices from every target at once
    /// and returns all of them, computing each value rather than reading it out
    /// of a struct that does not exist yet; the §9.4 display unit — the only
    /// other body — slices from one target and reads the rest.
    emitting_common: bool = false,
    /// Did `analyzeUnit` leave this body reading the core? Drives the one
    /// `const c = <module>__common__core(...)` line at the top of it. Only the
    /// §9.4 display unit can still set it.
    uses_cache: bool = false,
    /// `<module>__common__core`, or empty for a model with no targets at all.
    common_name: []const u8 = "",
    common_mode: proof.FloatMode = .optimized,
    /// §9.4. `.drop` ⇒ nothing below ever looks at `lower.display_root`.
    display: Display = .drop,
    /// `Options.diags` — where E0515 goes, when the caller kept a bag.
    diags: ?*diag.Bag = null,
    /// `<module>__display__tasks`, or empty when the model prints nothing (or
    /// when `display == .drop`). Set by `buildJobs`, which is also where the job
    /// that renders it is queued.
    display_name: []const u8 = "",
    /// Unit index of the analog-operator `call` at `Inst`, or `none_u32`.
    op_unit: []u32 = &.{},
    /// Extra solver unknowns codegen appends after `Lower.node_order`: one
    /// branch current per §5.6 potential contribution that lowering did not
    /// already give a `flow(a,b)` slot. Values are node_order-space indices.
    branch_u: []u32 = &.{},
    n_u: u32 = 0,
    /// Sanitized U-enum member name per unknown.
    u_names: [][]const u8 = &.{},
    /// Sanitized Model field name per `Lower.params` entry.
    p_names: [][]const u8 = &.{},
    /// §5.10 `Instance` field name per `Lower.held_vars` entry.
    held_names: [][]const u8 = &.{},
    /// Core field index holding each held variable's end-of-block value, or
    /// `none_u32` when it folded to `.f_zero`. Filled by `planCommon`.
    held_idx: []u32 = &.{},
    /// Parameters queried by §9.19 `$param_given` (they gain a `__given` flag).
    p_given: []bool = &.{},

    // ---- CFG, computed once and shared by every unit ----
    nb: u32 = 0,
    rpo_num: []u32 = &.{},
    rpo: []u32 = &.{},
    idom: []u32 = &.{},
    preds: [][]u32 = &.{},
    succs: [][]u32 = &.{},
    dom_kids: [][]u32 = &.{},
    /// Euler-tour numbering of the dominator tree, so `dominates` is O(1)
    /// instead of an idom walk (`none_u32` = block not in the tree).
    dom_in: []u32 = &.{},
    dom_out: []u32 = &.{},
    is_merge: []bool = &.{},
    is_loop: []bool = &.{},
    /// The OUTERMOST loop header whose natural loop contains this block, or
    /// `none_u32`. Outermost, not innermost, so a whole nest is one unit of
    /// decision in `planCommon` — see `loop_blocked`.
    loop_of: []u32 = &.{},
    /// PER UNIT, indexed by loop header: does the unit being analyzed run this
    /// loop itself, so its values must be recomputed rather than read from the
    /// core? Reset and refilled by `analyzeUnit`.
    loop_recompute: []bool = &.{},
    /// EVERY instruction of block `b`, in emission order:
    /// `inst_pool[inst_off[b]..inst_off[b + 1]]`. `prepare` used to walk the
    /// MIR's intrusive `next` chain six separate times (terminators, phi/stmt
    /// count, phi/stmt fill, `def_block`, `op_unit`, `$param_given`), and each
    /// `it.next()` is a dependent load — six latency-bound traversals of the
    /// whole model. AIR never has a chain at all: a block body is a `[]u32`
    /// window reinterpreted in place. Built by two walks, read by five.
    inst_pool: []Mir.Inst = &.{},
    inst_off: []u32 = &.{},
    /// Non-aliased phis of block `b`, in emission order:
    /// `phi_pool[phi_off[b]..phi_off[b + 1]]`. `emitPhiCopies` runs once per CFG
    /// edge, so re-walking the block's instruction chain there is quadratic in
    /// the block's in-degree. Flat pool + offsets, not `[][]Inst`: one
    /// allocation, 4 bytes per phi, nothing derivable stored.
    phi_pool: []Mir.Inst = &.{},
    phi_off: []u32 = &.{},
    /// Same shape, for the instructions a unit body can emit: everything except
    /// phis, terminators, and values aliased away. `emitBlockInsts` runs once
    /// per block PER UNIT, and the MIR's intrusive `next` chain makes that a
    /// pointer chase over the whole model each time.
    stmt_pool: []Mir.Inst = &.{},
    stmt_off: []u32 = &.{},
    /// Merge-block dominator children of `b`: `mk_pool[mk_off[b]..mk_off[b+1]]`.
    /// `emitCode` runs per block per unit and used to rebuild this list into a
    /// fresh arena allocation every time; the CFG does not change between units.
    mk_pool: []u32 = &.{},
    mk_off: []u32 = &.{},
    /// MIR instruction columns, hoisted once. `mir.instOp`/`instResult` each
    /// re-derive the MultiArrayList base pointers per call.
    i_op: []const Mir.Opcode = &.{},
    i_res: []const Mir.Value = &.{},
    term: []Mir.Inst = &.{},
    /// Block a Value is defined in (`none_u32` for constants/params/probes).
    def_block: []u32 = &.{},

    // ---- per-value tables ----
    nv: u32 = 0,
    vty: []VTy = &.{},
    /// `mir.resolveAlias` evaluated once for every Value. `rv` is on the render
    /// path of every unit (`renderVal`, `renderOp`, `livePhi`, `liveStmt`,
    /// `mark`, `emitUnits`), and `resolveAlias` is declared `*const` but WRITES:
    /// it path-compresses through the slice. Reading a snapshot instead makes
    /// `rv` one array load and makes the whole render path genuinely read-only,
    /// which is what per-unit parallelism will need. Costs `nv * 4` bytes.
    ///
    /// INVARIANT: nothing calls `Mir.setAlias` after `prepare`. Its only caller
    /// is `ssa.tryRemoveTrivialPhi`, which runs inside lowering — codegen and
    /// proof are read-only passes over a finished Mir.
    alias: []Mir.Value = &.{},

    // ---- per-unit scratch ----
    needed: []bool = &.{},
    /// The values `mark` reached for this unit, sorted ascending. Everything
    /// per-unit iterates this instead of `0..nv` — a unit touches a small slice
    /// of a 600 K-line model's values, and there are hundreds of units.
    live: std.ArrayList(Mir.Value) = .empty,
    eager_use: []u32 = &.{},
    arm_use: []u32 = &.{},
    inlined: []bool = &.{},
    /// The slice fits in the entry block with no phi (the common case).
    straight: bool = false,
    /// Blocks this unit defines something in, and blocks it needs a phi of.
    /// Per-block, per-unit; `planDeadBranches` is the only reader.
    blk_work: []bool = &.{},
    blk_phi: []bool = &.{},
    /// A `branch` whose two arms are indistinguishable to THIS unit: it neither
    /// defines anything nor copies a phi on either side before they reconverge.
    /// The condition is then never marked live, never slotted and never
    /// emitted — see `planDeadBranches`.
    dead_branch: []bool = &.{},
    /// Local slot of a needed value, or `none_u32`. UNIT-LOCAL — never a MIR
    /// index (03-codegen.html#canonicalization).
    slot: []u32 = &.{},
    n_slots: u32 = 0,
    /// Where each slot's declaration goes — `probeBody` fills this, and it is
    /// only meaningful for the out-of-SSA path (`straight` declares everything
    /// at its definition by construction).
    place: std.ArrayList(Place) = .empty,
    /// Index of a slot inside its type's hoist ARRAY, or `none_u32` for a slot
    /// that keeps a name of its own. See `emitUnitBody`: the surviving hoists
    /// are one `var h: [n]S` (plus `hi`/`hs` when those types occur) rather than
    /// one `var tN` apiece, which is ~4 k declarations on `hisimhv_va`.
    ///
    /// All-`none_u32` while `probing`, so the dry run names every slot `tN`.
    /// That is fine and deliberate: `probeBody` only compares offsets against
    /// each other, so it needs its own text to be self-consistent, not to match
    /// the final text byte for byte.
    hoist_idx: std.ArrayList(u32) = .empty,
    /// Emitted lexical scopes, as half-open output offsets. `sc_open` is the
    /// stack of scopes still being written; `sc_end` their closing offset once
    /// written. Only live during `probing`.
    sc_end: std.ArrayList(u32) = .empty,
    sc_open: std.ArrayList(u32) = .empty,
    probing: bool = false,

    // ------------------------------------------------------------------ setup

    fn prepare(self: *Gen) Error!void {
        // Empirically the emitted Zig runs ~24 bytes per MIR instruction. One
        // guess up front beats a dozen doublings even on a gpa, where a regrow
        // can at least remap in place.
        try self.out.ensureTotalCapacity(self.gpa, self.mir.insts.len * 24 + 4096);
        // Before `buildCfg`: its `livePhi`/`liveStmt` already call `rv`. `nv`
        // derives only from `mir.defs.len`, so it is knowable this early.
        self.nv = @intCast(self.mir.defs.len + Mir.Value.first_dynamic);
        try self.buildAlias();
        try self.buildCfg();
        try self.buildValueTypes();
        try self.buildUnits();
        try self.buildNames();
        try self.buildJobs();
        try self.planCommon();
    }

    // ---------------------------------------------------- the shared core ----
    //
    // WHY THIS EXISTS. `emitUnit` renders the full backward slice of one
    // `Mir.Value` through a CFG all the units share, so ~105 units each emit the
    // same core: `hisimhv_va` measured 1 220 929 emitted values across 58 units
    // of which 22 214 distinct values appear in two or more — 190 MB of output
    // from 614 K of source.
    //
    // 03-codegen.html chose that deliberately ("anonymous shared subexpressions
    // are recomputed, not promoted to hidden shared decls … this keeps every
    // unit independently skippable"). The justification does not hold, and the
    // same document concedes it two paragraphs earlier for NAMED units: "zig's
    // dependency graph dirties consumers correctly when such a unit changes".
    // A shared declaration is therefore BETTER for incrementality, not worse —
    // one declaration to re-analyse instead of 58 copies of it — and the units'
    // own tails stay independently skippable either way.
    //
    // WHY ONE DECLARATION AND NOT ONE PER VALUE. The obvious shape — a function
    // per shared value, calling the functions of its operands — is wrong, and
    // measurably so: the shared values form a DAG, so a value reachable by two
    // paths would be recomputed once per path, and the cost is exponential in
    // the DAG depth. The values have to be computed ONCE and PASSED.
    //
    // WHY *EVERY* TARGET IS IN IT, and not just the ≥K-shared subexpressions.
    // Hoisting a shared region and leaving a per-unit tail behind was measured
    // (docs/architecture/OUTPUT-VOLUME.md) and it is the wrong shape twice over:
    //
    //   SIZE. The tails are not tails. `emitCode` walks the whole reachable CFG
    //   for every unit, so each one re-materialises every merge block and every
    //   §5.9 loop whether or not it computes anything in them. On `hisimhv_va`
    //   the 58 tails were 378 634 lines of which 10 830 — 2.86% — were
    //   arithmetic; the median tail was 6 007 lines containing 6 operations.
    //   Folding the targets into the core deletes all of it: 440 124 → 59 986
    //   lines, 23.73 → 3.25 MB. The merged body is the same size as the core
    //   already was (60 061 lines), because the tails carried no information.
    //
    //   RUNTIME. Every tail opened with `const c = core(...)`, so one `eval`
    //   evaluated the core once per contribution — 40 times on `hisimhv_va`,
    //   30 on `vbic13_4t`. LLVM does NOT recover this: built -OReleaseFast it
    //   inlines all 30 `vbic13_4t` tails into the caller and still emits 30
    //   calls to the core (`objdump | grep -c core` = 30), because it cannot
    //   prove a 60 000-line two-pointer function `readonly willreturn`. Merging
    //   is therefore a runtime fix, not a size optimisation: one core per
    //   `eval`, one per `q`.
    //
    // WHAT IS LOST. The per-unit `@setFloatMode` — see `common_mode`. Nothing
    // else: `contract.zig` exposes only `eval`/`q`, and engine.zig (:511, :534,
    // :1216) always evaluates the whole residual, so a unit was never
    // independently callable in the first place.

    /// Decide what the one emitted body returns: every unit target, deduplicated
    /// and in job order.
    ///
    /// Job order — contributions in source order, then §4.5 operator inputs,
    /// then §9.4 display — is what makes `f<k>` insert-tolerant in the same
    /// sense `naming.zig` makes declaration names insert-tolerant: adding a
    /// contribution at the end of a module appends fields, it does not renumber
    /// them.
    fn planCommon(self: *Gen) Error!void {
        const a = self.arena;
        self.lo_idx = try a.alloc(u32, self.nv);
        @memset(self.lo_idx, none_u32);

        var vals: std.ArrayList(Mir.Value) = .empty;
        var mode: proof.FloatMode = .optimized;
        for (self.jobs) |job| {
            // §9.4 the display root stays OUT: the core runs once per `eval`,
            // and printing once per Newton iteration is exactly what
            // `emitDisplay` exists to prevent. It keeps its own declaration and
            // reads the core like the units used to.
            if (job.is_display) continue;
            mode = .strictest(mode, job.mode);
            const v = self.rv(job.target);
            if (v == .f_zero) continue; // an operator with no input; rendered inline
            if (self.lo_idx[@intFromEnum(v)] != none_u32) continue;
            self.lo_idx[@intFromEnum(v)] = @intCast(vals.items.len);
            try vals.append(a, v);
        }
        self.common_mode = mode;
        self.lo_vals = vals.items;
        // §5.10 which core field each held variable's write-back reads. Done
        // here rather than by scanning `jobs` in `emitStateMachine`, because
        // `lo_idx` is only meaningful once every job has been folded in.
        self.held_idx = try a.alloc(u32, self.lower.held_vars.items.len);
        for (self.lower.held_vars.items, 0..) |h, i| {
            const v = self.rv(h.final);
            self.held_idx[i] = if (v == .f_zero) none_u32 else self.lo_idx[@intFromEnum(v)];
        }
        if (self.lo_vals.len == 0) return;

        var buf: [naming.max_name_len]u8 = undefined;
        const n = naming.unitName(&buf, self.mir.name, .{
            .role = .common,
            // A single declaration, so the target is a fixed word rather than a
            // key: naming.zig's insert-tolerance is about the NAME not moving,
            // and this one cannot.
            .target = "core",
        }) catch return error.NameTooLong;
        self.common_name = try a.dupe(u8, n);
    }

    /// Is this block inside some loop's natural body?
    fn inLoop(self: *const Gen, block: u32) bool {
        return self.loop_of[block] != none_u32;
    }

    /// Is this Value read out of the common declaration's cache HERE?
    /// False inside the common declaration itself, where it is computed.
    inline fn cached(self: *const Gen, v: Mir.Value) bool {
        if (self.emitting_common or self.lo_idx[@intFromEnum(v)] == none_u32) return false;
        // §5.9 A unit that re-materializes a loop must not read that loop's
        // values out of the cache — see `analyzeUnit`'s fixpoint.
        const blk = self.def_block[@intFromEnum(v)];
        if (blk != none_u32) {
            const l = self.loop_of[blk];
            if (l != none_u32 and self.loop_recompute[l]) return false;
        }
        return true;
    }

    fn w(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// Body text. Same destination as `w` since the signature is back-patched
    /// (see `emitUnit`); kept as a separate name because the call sites read as
    /// "body" vs "file scaffolding".
    fn b(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        try self.out.print(self.gpa, fmt, args);
    }

    /// One `appendNTimes` rather than a loop of `appendSlice`: the value is
    /// comptime-known, so this lowers to a memset (see `ArrayList.appendNTimes`,
    /// which is `inline` for exactly that reason).
    fn ind(self: *Gen, n: u32) Error!void {
        try self.out.appendNTimes(self.gpa, ' ', n * 4);
    }

    /// Snapshot the whole alias forest, root-first, so `rv` never touches the
    /// Mir again. Values below `first_dynamic` are their own root by definition.
    fn buildAlias(self: *Gen) Error!void {
        self.alias = try self.arena.alloc(Mir.Value, self.nv);
        for (self.alias, 0..) |*p, v| p.* = self.mir.resolveAlias(@enumFromInt(@as(u32, @intCast(v))));
    }

    fn rv(self: *const Gen, v: Mir.Value) Mir.Value {
        return self.alias[@intFromEnum(v)];
    }

    /// Block `bi`'s instructions as a contiguous window — see `inst_pool`.
    inline fn blockInstsFlat(self: *const Gen, bi: u32) []const Mir.Inst {
        return self.inst_pool[self.inst_off[bi]..self.inst_off[bi + 1]];
    }

    // ---------------------------------------------------------------- CFG ----

    fn buildCfg(self: *Gen) Error!void {
        const a = self.arena;
        const nb = self.mir.blockCount();
        self.nb = nb;
        self.i_op = self.mir.insts.items(.op);
        self.i_res = self.mir.insts.items(.result);
        self.term = try a.alloc(Mir.Inst, nb);
        self.succs = try a.alloc([]u32, nb);
        self.preds = try a.alloc([]u32, nb);
        self.rpo_num = try a.alloc(u32, nb);
        self.idom = try a.alloc(u32, nb);
        self.is_merge = try a.alloc(bool, nb);
        self.is_loop = try a.alloc(bool, nb);
        self.loop_of = try a.alloc(u32, nb);
        self.loop_recompute = try a.alloc(bool, nb);
        @memset(self.rpo_num, none_u32);
        @memset(self.idom, none_u32);
        @memset(self.is_merge, false);
        @memset(self.is_loop, false);
        @memset(self.loop_of, none_u32);
        @memset(self.loop_recompute, false);

        // Flatten the intrusive `next` chain ONCE (count, then fill — the same
        // two-pass shape as `dom_kids`, so the pool never grows). Every later
        // walk in `prepare` reads `blockInstsFlat` instead. Order is the chain
        // order, which is emission order and therefore load-bearing.
        self.inst_off = try a.alloc(u32, nb + 1);
        var n_insts: u32 = 0;
        for (0..nb) |bi| {
            self.inst_off[bi] = n_insts;
            var it = self.mir.blockInsts(@enumFromInt(@as(u32, @intCast(bi))));
            while (it.next()) |_| n_insts += 1;
        }
        self.inst_off[nb] = n_insts;
        self.inst_pool = try a.alloc(Mir.Inst, n_insts);
        var ki: u32 = 0;
        for (0..nb) |bi| {
            var it = self.mir.blockInsts(@enumFromInt(@as(u32, @intCast(bi))));
            while (it.next()) |inst| {
                self.inst_pool[ki] = inst;
                ki += 1;
            }
        }

        // Terminator + successors. ssa.zig warns that a phi may sit ANYWHERE in
        // the chain (created on demand), so the terminator is found by opcode,
        // not by position.
        var pred_count = try a.alloc(u32, nb);
        @memset(pred_count, 0);
        for (0..nb) |bi| {
            self.term[bi] = .none;
            var s: [2]u32 = undefined;
            var ns: usize = 0;
            for (self.blockInstsFlat(@intCast(bi))) |inst| switch (self.mir.instOp(inst)) {
                .branch => {
                    const d = self.mir.instData(inst).branch;
                    self.term[bi] = inst;
                    s[0] = @intFromEnum(d.then_block);
                    s[1] = @intFromEnum(d.else_block);
                    ns = 2;
                },
                .jump => {
                    self.term[bi] = inst;
                    s[0] = @intFromEnum(self.mir.instData(inst).jump.target);
                    ns = 1;
                },
                else => {},
            };
            self.succs[bi] = try a.dupe(u32, s[0..ns]);
        }

        // Reachability + postorder (iterative DFS, successor order = branch
        // order ⇒ deterministic).
        var post = try a.alloc(u32, nb);
        var n_post: u32 = 0;
        {
            var seen = try a.alloc(bool, nb);
            @memset(seen, false);
            const Frame = struct { b: u32, i: u32 };
            var stack: std.ArrayList(Frame) = .empty;
            defer stack.deinit(a);
            try stack.append(a, .{ .b = 0, .i = 0 });
            seen[0] = true;
            while (stack.items.len != 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.i < self.succs[top.b].len) {
                    const s = self.succs[top.b][top.i];
                    top.i += 1;
                    if (!seen[s]) {
                        seen[s] = true;
                        try stack.append(a, .{ .b = s, .i = 0 });
                    }
                } else {
                    post[n_post] = top.b;
                    n_post += 1;
                    _ = stack.pop();
                }
            }
        }
        for (post[0..n_post], 0..) |bi, i| self.rpo_num[bi] = n_post - 1 - @as(u32, @intCast(i));
        self.rpo = try a.alloc(u32, n_post);
        for (post[0..n_post], 0..) |bi, i| self.rpo[n_post - 1 - i] = bi;

        // Predecessors (reachable only).
        for (0..nb) |bi| {
            if (self.rpo_num[bi] == none_u32) continue;
            for (self.succs[bi]) |s| pred_count[s] += 1;
        }
        for (0..nb) |bi| self.preds[bi] = try a.alloc(u32, pred_count[bi]);
        @memset(pred_count, 0);
        for (self.rpo) |bi| {
            for (self.succs[bi]) |s| {
                self.preds[s][pred_count[s]] = bi;
                pred_count[s] += 1;
            }
        }
        for (0..nb) |bi| self.is_merge[bi] = self.preds[bi].len > 1;
        self.is_merge[0] = false; // entry is never re-entered

        // Cooper/Harvey/Kennedy iterative dominators over reverse postorder.
        self.idom[0] = 0;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.rpo[1..]) |bi| {
                var new: u32 = none_u32;
                for (self.preds[bi]) |p| {
                    if (self.idom[p] == none_u32 and p != 0) continue;
                    new = if (new == none_u32) p else self.intersect(new, p);
                }
                if (new != none_u32 and self.idom[bi] != new) {
                    self.idom[bi] = new;
                    changed = true;
                }
            }
        }

        // Dominator children, in RPO order (deterministic emission order).
        var kid_count = try a.alloc(u32, nb);
        @memset(kid_count, 0);
        for (self.rpo[1..]) |bi| kid_count[self.idom[bi]] += 1;
        self.dom_kids = try a.alloc([]u32, nb);
        for (0..nb) |bi| self.dom_kids[bi] = try a.alloc(u32, kid_count[bi]);
        @memset(kid_count, 0);
        for (self.rpo[1..]) |bi| {
            const p = self.idom[bi];
            self.dom_kids[p][kid_count[p]] = bi;
            kid_count[p] += 1;
        }

        // Merge-block dominator children, flattened in the same order the
        // per-unit rebuild produced.
        self.mk_off = try a.alloc(u32, nb + 1);
        var n_mk: u32 = 0;
        for (0..nb) |bi| {
            self.mk_off[bi] = n_mk;
            for (self.dom_kids[bi]) |k| {
                if (self.is_merge[k]) n_mk += 1;
            }
        }
        self.mk_off[nb] = n_mk;
        self.mk_pool = try a.alloc(u32, n_mk);
        var mk: u32 = 0;
        for (0..nb) |bi| {
            for (self.dom_kids[bi]) |k| {
                if (self.is_merge[k]) {
                    self.mk_pool[mk] = k;
                    mk += 1;
                }
            }
        }

        // Euler tour of the dominator tree (explicit stack: 600 K-line models
        // nest deeply enough to blow a recursive walk).
        self.dom_in = try a.alloc(u32, nb);
        self.dom_out = try a.alloc(u32, nb);
        @memset(self.dom_in, none_u32);
        @memset(self.dom_out, none_u32);
        const Frame = struct { node: u32, kid: u32 };
        const stack = try a.alloc(Frame, nb);
        var sp: usize = 1;
        var clock: u32 = 0;
        stack[0] = .{ .node = 0, .kid = 0 };
        self.dom_in[0] = clock;
        clock += 1;
        while (sp > 0) {
            const f = &stack[sp - 1];
            const kids = self.dom_kids[f.node];
            if (f.kid < kids.len) {
                const k = kids[f.kid];
                f.kid += 1;
                self.dom_in[k] = clock;
                clock += 1;
                stack[sp] = .{ .node = k, .kid = 0 };
                sp += 1;
            } else {
                self.dom_out[f.node] = clock;
                clock += 1;
                sp -= 1;
            }
        }

        // Per-block phi and statement pools, counted then filled (same two-pass
        // shape as `dom_kids`, so neither pool needs to grow).
        self.phi_off = try a.alloc(u32, nb + 1);
        self.stmt_off = try a.alloc(u32, nb + 1);
        var n_phis: u32 = 0;
        var n_stmts: u32 = 0;
        for (0..nb) |bi| {
            self.phi_off[bi] = n_phis;
            self.stmt_off[bi] = n_stmts;
            for (self.blockInstsFlat(@intCast(bi))) |inst| {
                if (self.livePhi(inst)) n_phis += 1;
                if (self.liveStmt(inst)) n_stmts += 1;
            }
        }
        self.phi_off[nb] = n_phis;
        self.stmt_off[nb] = n_stmts;
        self.phi_pool = try a.alloc(Mir.Inst, n_phis);
        self.stmt_pool = try a.alloc(Mir.Inst, n_stmts);
        var kp: u32 = 0;
        var ks: u32 = 0;
        for (0..nb) |bi| {
            for (self.blockInstsFlat(@intCast(bi))) |inst| {
                if (self.livePhi(inst)) {
                    self.phi_pool[kp] = inst;
                    kp += 1;
                }
                if (self.liveStmt(inst)) {
                    self.stmt_pool[ks] = inst;
                    ks += 1;
                }
            }
        }

        // A loop header dominates at least one of its predecessors (back edge).
        for (self.rpo) |bi| {
            for (self.preds[bi]) |p| {
                if (self.dominates(bi, p)) self.is_loop[bi] = true;
            }
        }

        // The NATURAL LOOP BODY of every header, for the §5.9 `loop_recompute`
        // fixpoint and for `edgeAct`'s `inLoop` guard. Standard construction:
        // walk predecessors backwards from each back edge, stopping at the
        // header; every block reached is inside that loop.
        //
        // NOT "everything the header dominates": that also covers the region
        // past the loop's exit, so a model whose analog block opens with a `for`
        // would lose hoisting for its entire body — which is the 182 MB output
        // the shared core exists to prevent.
        //
        // `rpo` visits an outer header before an inner one, and the first write
        // wins, so `loop_of` ends up naming the OUTERMOST nest. That is what
        // makes a nest one decision: re-materializing an inner loop needs the
        // outer loop's structure too, so they stand or fall together.
        var body: std.ArrayList(u32) = .empty;
        defer body.deinit(self.arena);
        for (self.rpo) |h| {
            if (!self.is_loop[h]) continue;
            if (self.loop_of[h] == none_u32) self.loop_of[h] = h;
            for (self.preds[h]) |p| {
                if (!self.dominates(h, p)) continue; // not a back edge
                if (self.loop_of[p] != none_u32 and p != h) continue;
                if (p != h) {
                    self.loop_of[p] = self.loop_of[h];
                    try body.append(self.arena, p);
                }
                while (body.pop()) |cur| {
                    for (self.preds[cur]) |q| {
                        if (self.loop_of[q] != none_u32) continue;
                        self.loop_of[q] = self.loop_of[h];
                        try body.append(self.arena, q);
                    }
                }
            }
        }
    }

    fn intersect(self: *const Gen, x0: u32, y0: u32) u32 {
        var x = x0;
        var y = y0;
        while (x != y) {
            while (self.rpo_num[x] > self.rpo_num[y]) x = self.idom[x];
            while (self.rpo_num[y] > self.rpo_num[x]) y = self.idom[y];
        }
        return x;
    }

    /// `a` dominates `x` iff `x` sits inside `a`'s Euler-tour interval. Blocks
    /// outside the dominator tree (unreachable) dominate only themselves.
    fn dominates(self: *const Gen, a: u32, x: u32) bool {
        const ia = self.dom_in[a];
        const ix = self.dom_in[x];
        if (ia == none_u32 or ix == none_u32) return a == x;
        return ia <= ix and self.dom_out[x] <= self.dom_out[a];
    }

    // -------------------------------------------------------------- values ----

    fn buildValueTypes(self: *Gen) Error!void {
        const a = self.arena;
        self.vty = try a.alloc(VTy, self.nv); // `nv` was set in `prepare`
        self.def_block = try a.alloc(u32, self.nv);
        @memset(self.def_block, none_u32);
        for (self.vty) |*t| t.* = .real;

        for (0..self.nb) |bi| {
            for (self.blockInstsFlat(@intCast(bi))) |inst| {
                const r = self.mir.instResult(inst);
                if (r == .undef) continue;
                self.def_block[@intFromEnum(r)] = @intCast(bi);
            }
        }

        // Base pass: constants and opcodes decide themselves.
        var v: u32 = 0;
        while (v < self.nv) : (v += 1) {
            const val: Mir.Value = @enumFromInt(v);
            self.vty[v] = switch (self.mir.valueDef(val)) {
                .undef => .real,
                .float_const => .real,
                .int_const => .int,
                .str_const => .str,
                .param_ref => |p| tyOfParam(self.lower.params.items[p].ty),
                .block_param => .real,
                .inst_result => |inst| blk: {
                    const op = self.mir.instOp(inst);
                    if (op == .call) break :blk callTy(self.mir.instData(inst).call.name);
                    if (op == .phi or op == .select) break :blk .real; // refined below
                    break :blk if (Mir.opIsInteger(op)) .int else .real;
                },
            };
        }
        // Refine `select` and `phi` from their operands. Two sweeps in value
        // order settle every acyclic chain; a loop-carried phi keeps `.real`,
        // and a wrong guess only costs a redundant §4.2.1 conversion.
        var round: u32 = 0;
        while (round < 2) : (round += 1) {
            v = Mir.Value.first_dynamic;
            while (v < self.nv) : (v += 1) {
                const val: Mir.Value = @enumFromInt(v);
                const def = self.mir.valueDef(val);
                if (def != .inst_result) continue;
                const inst = def.inst_result;
                switch (self.mir.instOp(inst)) {
                    .select => {
                        const d = self.mir.instData(inst).ternary;
                        self.vty[v] = self.vty[@intFromEnum(self.rv(d.then_val))];
                    },
                    .phi => {
                        const d = self.mir.instData(inst).phi;
                        if (d.count == 0) continue;
                        const first = self.rv(self.mir.phiPair(inst, 0).value);
                        if (first == .undef) continue;
                        self.vty[v] = self.vty[@intFromEnum(first)];
                    },
                    else => {},
                }
            }
        }

        // Cleared here once; every later unit clears only its own live set.
        self.needed = try a.alloc(bool, self.nv);
        self.eager_use = try a.alloc(u32, self.nv);
        self.arm_use = try a.alloc(u32, self.nv);
        self.inlined = try a.alloc(bool, self.nv);
        self.slot = try a.alloc(u32, self.nv);
        @memset(self.needed, false);
        @memset(self.eager_use, 0);
        @memset(self.arm_use, 0);
        @memset(self.inlined, false);
        @memset(self.slot, none_u32);
        // Per-BLOCK, not per-value: a whole `@memset` of these per unit is a few
        // KB, nothing like the `0..nv` per-unit sweeps fix 5 in PERF.md deleted.
        self.blk_work = try a.alloc(bool, self.nb);
        self.blk_phi = try a.alloc(bool, self.nb);
        self.dead_branch = try a.alloc(bool, self.nb);
    }

    fn tyOf(self: *const Gen, v: Mir.Value) VTy {
        return self.vty[@intFromEnum(v)];
    }

    // --------------------------------------------------------------- units ----

    fn buildUnits(self: *Gen) Error!void {
        const a = self.arena;
        self.units = naming.enumerateUnits(a, self.mir, self.lower) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoSpaceLeft => return error.NameTooLong,
        };
        self.unit_names = try a.alloc([]const u8, self.units.len);
        var buf: [naming.max_name_len]u8 = undefined;
        for (self.units, 0..) |u, i| {
            const n = naming.unitName(&buf, self.mir.name, u) catch return error.NameTooLong;
            self.unit_names[i] = try a.dupe(u8, n);
        }
        // The analog-operator units are enumerated by naming.zig with exactly
        // this walk; repeating it maps each stateful `call` back to its unit.
        self.op_unit = try a.alloc(u32, self.mir.insts.len);
        @memset(self.op_unit, none_u32);
        var next = self.lower.contributions.items.len;
        for (0..self.nb) |bi| {
            for (self.blockInstsFlat(@intCast(bi))) |inst| {
                if (self.mir.instOp(inst) != .call) continue;
                if (opKind(self.mir.instData(inst).call.name) == .none) continue;
                assert(next < self.units.len);
                self.op_unit[@intFromEnum(inst)] = @intCast(next);
                next += 1;
            }
        }
        assert(next == self.units.len);
    }

    /// Is unknown `u` already the current of a source from a contribution
    /// before `i`? Two sources in one branch need two currents.
    fn uIsDriven(self: *const Gen, u: u32, i: usize) bool {
        for (self.branch_u[0..i]) |prev| {
            if (prev == u) return true;
        }
        return false;
    }

    /// `nm`, or `nm#k` for the first `k` that no unknown claims yet. `sanitize`
    /// escapes `#`, so the emitted U member stays a legal, injective name.
    fn freshUName(self: *const Gen, nm: []const u8, extra: []const []const u8) Error![]const u8 {
        var name = nm;
        var k: u32 = 1;
        while (self.uNameTaken(name, extra)) : (k += 1) {
            name = try std.fmt.allocPrint(self.arena, "{s}#{d}", .{ nm, k });
        }
        return name;
    }

    fn uNameTaken(self: *const Gen, nm: []const u8, extra: []const []const u8) bool {
        for (self.lower.node_order.items) |n| {
            if (std.mem.eql(u8, n, nm)) return true;
        }
        for (extra) |n| {
            if (std.mem.eql(u8, n, nm)) return true;
        }
        return false;
    }

    fn buildNames(self: *Gen) Error!void {
        const a = self.arena;
        var buf: [naming.max_name_len]u8 = undefined;

        // §5.6 potential contributions need a branch-current unknown. Lowering
        // allocates a `flow(a,b)` slot only where the model PROBES I(a,b), so
        // codegen appends the missing ones after node_order — every existing
        // block_param index keeps its meaning.
        const base: u32 = @intCast(self.lower.node_order.items.len);
        self.branch_u = try a.alloc(u32, self.lower.contributions.items.len);
        @memset(self.branch_u, none_u32);
        // Raw names of the unknowns appended after node_order, in append order.
        var extra: std.ArrayList([]const u8) = .empty;
        for (self.lower.contributions.items, 0..) |c, i| {
            // A §5.6 potential source and a §5.6.7 indirect (nullor) source are
            // the same topology: a source in the branch whose current is its
            // own unknown.
            if (c.access != .potential and c.kind != .indirect) continue;
            const nm = try std.fmt.allocPrint(a, "flow({s},{s})", .{
                self.lower.nodeName(c.hi), self.lower.nodeName(c.lo),
            });
            // Reuse the §5.4.2 slot lowering already allocated because the model
            // PROBES I(a,b) — unless an earlier contribution is already driving
            // it. §5.6.7.1 permits several indirect contributions to one branch,
            // and each is a separate source with a separate current.
            var found: u32 = none_u32;
            for (self.lower.node_order.items, 0..) |n, k| {
                if (std.mem.eql(u8, n, nm)) found = @intCast(k);
            }
            if (found != none_u32 and self.uIsDriven(found, i)) found = none_u32;
            if (found == none_u32) {
                found = base + @as(u32, @intCast(extra.items.len));
                try extra.append(a, try self.freshUName(nm, extra.items));
            }
            self.branch_u[i] = found;
        }
        self.n_u = base + @as(u32, @intCast(extra.items.len));

        self.u_names = try a.alloc([]const u8, self.n_u);
        for (self.lower.node_order.items, 0..) |n, i| {
            self.u_names[i] = try a.dupe(u8, naming.sanitize(&buf, n) catch return error.OutOfMemory);
        }
        for (extra.items, 0..) |n, k| {
            self.u_names[base + k] = try a.dupe(u8, naming.sanitize(&buf, n) catch return error.OutOfMemory);
        }

        self.p_names = try a.alloc([]const u8, self.lower.params.items.len);
        for (self.lower.params.items, 0..) |p, i| {
            self.p_names[i] = try a.dupe(u8, naming.sanitize(&buf, p.name) catch return error.OutOfMemory);
        }

        // §5.10 held variables. Same `<module>__<role>__<target>` grammar
        // `naming.unitName` builds, with `held` where a role word would go:
        // `naming.Role` is a closed set that this is deliberately not a member
        // of (a held variable is not an emitted source unit), and no enumerated
        // unit can spell that segment, so the two name spaces cannot meet. The
        // target is one `sanitize`d leaf, which is injective — and a module
        // variable's name is unique in its scope, so the whole key is.
        self.held_names = try a.alloc([]const u8, self.lower.held_vars.items.len);
        if (self.held_names.len != 0) {
            var mod_buf: [naming.max_name_len]u8 = undefined;
            const mod = naming.sanitize(&mod_buf, self.mir.name) catch return error.NameTooLong;
            for (self.lower.held_vars.items, 0..) |h, i| {
                const leaf = naming.sanitize(&buf, h.name) catch return error.NameTooLong;
                self.held_names[i] = try std.fmt.allocPrint(a, "{s}__held__{s}", .{ mod, leaf });
            }
        }
        self.p_given = try a.alloc(bool, self.lower.params.items.len);
        @memset(self.p_given, false);
        // §9.19 $param_given(p): the flag lives in Model, but only for the
        // parameters actually asked about.
        for (0..self.nb) |bi| {
            for (self.blockInstsFlat(@intCast(bi))) |inst| {
                if (self.mir.instOp(inst) != .call) continue;
                const d = self.mir.instData(inst).call;
                if (!std.mem.eql(u8, d.name, "$param_given")) continue;
                if (d.args.len == 0) continue;
                const def = self.mir.valueDef(self.rv(d.args[0]));
                if (def == .param_ref) self.p_given[def.param_ref] = true;
            }
        }
    }

    // =======================================================================
    // File assembly
    // =======================================================================

    fn emitFile(self: *Gen) Error!void {
        const stateful = self.hasStatefulOps();
        const hist = self.usesOp(.absdelay);
        const filt = self.usesOp(.laplace) or self.usesOp(.zi);
        const timer = self.usesOp(.timer);
        try self.buildPrelude(stateful, hist, filt, timer);
        try self.out.appendSlice(self.gpa, header_txt);
        try self.out.appendSlice(self.gpa, math_txt);
        try self.out.appendSlice(self.gpa, ops_txt);
        if (timer) try self.out.appendSlice(self.gpa, timer_txt);
        if (hist) try self.out.appendSlice(self.gpa, hist_txt);
        // §4.5.11/§4.5.12 the filter kernels are embedded from a real Zig file,
        // so they arrive already `pub` — which is right for `h.zig` and wrong
        // here: `contract.rejectStrayPubDecls` allows only contract-recognized
        // names to be public, so a model using `laplace_nd` or `zi_nd` failed
        // `--check`/`--emit-so` on `stray pub decl \`zBilin\``. Every other
        // helper block is written private and made public by `publish`; this one
        // has to go the other way.
        if (filt) try depublish(self.gpa, &self.out, filt_txt);
        if (self.display == .emit) try self.out.appendSlice(self.gpa, display_txt);
        try self.out.appendSlice(self.gpa, "\n");
        if (stateful) try self.out.appendSlice(self.gpa, rscalar_txt);

        try self.emitTopology();
        try self.emitModel();
        try self.emitInstance();
        try self.emitUnits();
        try self.emitDispatchers();
        try self.emitNoiseTable();
        if (stateful) try self.emitStateMachine();
        try self.emitNextBreakpoint();
        try self.w("comptime {{\n    contract.validate(Self);\n}}\n", .{});
    }

    /// `Output.prelude` (the file-scope prologue of a `u/<key>.zig`) and
    /// `Output.helpers` (`h.zig`).
    ///
    /// The unit file ALIASES the helpers rather than re-emitting them per unit.
    /// Re-emitting is what a naive split does, and it multiplies by the unit
    /// count exactly the AstGen + Sema work this split exists to remove; an
    /// alias is one declaration `zig` analyses once. The aliases mirror what a
    /// unit body can name (§4.3 math, §4.5 operators, §4.5.7 history,
    /// §4.5.11/12 filters, the topology types) and are gated on the same
    /// conditions `emitFile` uses, so no alias ever names a missing decl.
    ///
    /// `n_u` is RECOMPUTED (`contract.nU(dev)`) rather than aliased: it is
    /// private in device.zig and `contract.rejectStrayPubDecls` will not let it
    /// become public. It is the same comptime value either way.
    fn buildPrelude(self: *Gen, stateful: bool, hist: bool, filt: bool, timer: bool) Error!void {
        var p: std.ArrayList(u8) = .empty;
        try p.appendSlice(self.arena, prelude_head_txt);
        try p.appendSlice(self.arena, prelude_math_txt);
        if (timer) try p.appendSlice(self.arena, prelude_timer_txt);
        if (hist) try p.appendSlice(self.arena, prelude_hist_txt);
        if (filt) try p.appendSlice(self.arena, prelude_filt_txt);
        if (stateful) try p.appendSlice(self.arena, "const R = h.R;\n");
        // The shared core is a unit file like any other, and it sits beside the
        // unit that calls it — device.zig's own alias for it is private to
        // device.zig, so it is not in scope here.
        // The shared core is a unit file like any other and sits beside the
        // units that call it; device.zig's own alias for it is private to
        // device.zig, so it is not in scope here. The alias is spelled `core`
        // rather than the structural key so that the core's OWN file — which
        // gets this same prologue — does not redeclare its own name. A file
        // importing itself is legal and, unreferenced, never analysed.
        if (self.common_name.len != 0)
            try p.print(self.arena, "const core = @import(\"{0s}.zig\").{0s};\n", .{self.common_name});
        try p.appendSlice(self.arena, "\n");
        self.prelude = p.items;

        var hz: std.ArrayList(u8) = .empty;
        try hz.appendSlice(self.arena, helpers_head_txt);
        try publish(self.arena, &hz, math_txt);
        try publish(self.arena, &hz, ops_txt);
        if (timer) try publish(self.arena, &hz, timer_txt);
        if (hist) try publish(self.arena, &hz, hist_txt);
        if (filt) try publish(self.arena, &hz, filt_txt);
        if (stateful) try publish(self.arena, &hz, rscalar_txt);
        self.helpers = hz.items;
    }

    /// Copy `src` into `out`, making each top-level declaration public. The
    /// same text is emitted PRIVATE into device.zig, where the contract forbids
    /// stray public names, and PUBLIC into `h.zig`, where the unit files can
    /// reach it — one source of truth, one three-line transform, instead of two
    /// near-identical copies of 10 KB of helper text to keep in sync.
    /// The inverse of `publish`: drop a leading `pub ` so an embedded Zig file
    /// can be spliced into device.zig, where the contract forbids stray public
    /// names. See `emitFile`.
    fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, src, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try out.append(gpa, '\n');
            first = false;
            try out.appendSlice(gpa, if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line);
        }
    }

    fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
        var it = std.mem.splitScalar(u8, src, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try out.append(arena, '\n');
            first = false;
            if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "const "))
                try out.appendSlice(arena, "pub ");
            try out.appendSlice(arena, line);
        }
    }

    /// Close the byte range of the unit declaration that started at `lo`. The
    /// ranges must TILE (`Output`'s invariant), which is what lets the writer
    /// reconstruct `device.zig` as prologue ++ imports ++ tail.
    fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void {
        if (self.file_hi.items.len != 0)
            assert(self.file_hi.items[self.file_hi.items.len - 1] == lo);
        try self.file_names.append(self.arena, name);
        try self.file_lo.append(self.arena, @intCast(lo));
        try self.file_fn.append(self.arena, @intCast(fn_at));
        try self.file_hi.append(self.arena, @intCast(self.out.items.len));
    }

    /// Does this model need the §4.5.2 accepted-step machinery at all? A §5.10
    /// held variable does, for the same reason an operator does: its value is
    /// carried in `Instance` and only `updateState` may advance it.
    /// `contract.validate` (modules/devices/src/contract.zig) then requires
    /// `State` + `initState` + `updateState` as a set, which `emitStateMachine`
    /// emits together.
    fn hasStatefulOps(self: *const Gen) bool {
        if (self.lower.held_vars.items.len != 0) return true;
        for (self.units) |u| {
            if (u.role == .analog_op and opHasState(opKind(u.target))) return true;
        }
        return false;
    }

    fn usesOp(self: *const Gen, k: OpKind) bool {
        for (self.units) |u| {
            if (u.role == .analog_op and opKind(u.target) == k) return true;
        }
        return false;
    }

    /// §1.3.1 nodes / §6.5 ports. `x[i]` in every emitted body indexes exactly
    /// this enum, and ports come first so the host's terminal order is the
    /// module header order.
    fn emitTopology(self: *Gen) Error!void {
        try self.w("/// Solver unknowns: §6.5 ports first, then §3.6.3 internal nets,\n", .{});
        try self.w("/// then §5.4.2 branch-flow unknowns.\n", .{});
        try self.w("pub const U = enum(u8) {{\n", .{});
        for (self.u_names, 0..) |n, i| {
            const kindc: []const u8 = if (i < self.lower.num_ports) "port" else if (self.isFlowUnknown(@intCast(i))) "branch flow" else "internal";
            try self.w("    {s}, // {s}\n", .{ n, kindc });
        }
        try self.w("}};\n\npub const num_ports: usize = {d};\nconst n_u = contract.nU(Self);\n\n", .{self.lower.num_ports});

        var any_current = false;
        for (0..self.n_u) |i| {
            if (self.isFlowUnknown(@intCast(i))) any_current = true;
        }
        if (any_current) {
            try self.w("pub const u_kinds = [n_u]contract.UnknownKind{{\n", .{});
            for (0..self.n_u) |i| {
                try self.w("    .{s},\n", .{if (self.isFlowUnknown(@intCast(i))) "current" else "voltage"});
            }
            try self.w("}};\n\n", .{});
        }
        try self.w(
            \\/// §4.6.1 analysis() / §5.10.2 global events. The host sets this per pass.
            \\pub const AnalysisKind = enum(u8) {{ static, ic, nodeset, dc, tran, ac, noise }};
            \\
            \\
        , .{});
    }

    /// §1.3.4/§3.6.2.2. Returns the name of the contribution's net when that
    /// net is a SIGNAL-FLOW PORT: a directional (`input`/`output`, §6.5.2.2)
    /// port whose discipline binds only one nature. That combination is the
    /// LRM's unambiguous signal-flow port, and it has no conserved pair for a
    /// nodal device to stamp.
    ///
    /// A single-nature discipline on an `inout` port or on an internal net is
    /// NOT caught here: those are conservative-shaped declarations whose net
    /// simply has one tolerance, which the device stamps as usual (§3.9).
    fn signalFlowNet(self: *const Gen, c: Lower.Contribution) ?[]const u8 {
        const nodes = self.lower.node_order.items;
        for ([_]u16{ c.hi, c.lo }) |n| {
            if (n >= nodes.len) continue; // ground
            if (!self.lower.node_directional.items[n]) continue;
            const dname = self.lower.node_disciplines.items[n];
            if (dname.len == 0) continue;
            const d = self.lower.disciplines.get(dname) orelse continue;
            if (!d.has_potential or !d.has_flow) return nodes[n];
        }
        return null;
    }

    fn isFlowUnknown(self: *const Gen, i: u32) bool {
        if (i >= self.lower.node_order.items.len) return true; // codegen-added branch current
        return std.mem.startsWith(u8, self.lower.node_order.items[i], "flow(");
    }

    /// §3.4 parameters. One field, typed, with the constant-folded spec default.
    fn emitModel(self: *Gen) Error!void {
        try self.w("/// §3.4 module parameters (spec defaults folded at compile time).\npub const Model = struct {{\n", .{});
        for (self.lower.params.items, 0..) |p, i| {
            const ty: []const u8 = switch (tyOfParam(p.ty)) {
                .real => "f64",
                .int => "i64",
                .str => "[]const u8",
            };
            try self.w("    {s}: {s} = {s},\n", .{ self.p_names[i], ty, try self.paramDefault(p, tyOfParam(p.ty)) });
            if (self.p_given[i]) {
                try self.w("    {s}__given: bool = false, // §9.19 $param_given\n", .{self.p_names[i]});
            }
        }
        if (self.lower.params.items.len == 0) {
            try self.w("    // (the module declares no parameters)\n    _unused: u8 = 0,\n", .{});
        }
        try self.w("}};\n\n", .{});
    }

    fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8 {
        const c = self.foldConst(p.default, 0, true);
        return switch (want) {
            .real => try self.fmtF64(if (c) |k| k.f else 0.0),
            .int => try std.fmt.allocPrint(self.arena, "{d}", .{if (c) |k| @as(i64, @intFromFloat(@round(k.f))) else 0}),
            .str => blk: {
                const def = self.mir.valueDef(self.rv(p.default));
                break :blk if (def == .str_const)
                    try std.fmt.allocPrint(self.arena, "\"{f}\"", .{std.zig.fmtString(def.str_const)})
                else
                    "\"\"";
            },
        };
    }

    const Folded = struct { f: f64 };

    /// §4.2 constant expression folding over MIR, used for parameter defaults
    /// (`parameter real b = a*2;` — §6.3.4) and for §4.5 operator control
    /// arguments. Anything touching an unknown or a call is not constant.
    fn foldConst(self: *const Gen, v0: Mir.Value, depth: u32, resolve_params: bool) ?Folded {
        if (depth > 32) return null;
        const v = self.rv(v0);
        switch (self.mir.valueDef(v)) {
            .float_const => |x| return .{ .f = x },
            .int_const => |x| return .{ .f = @floatFromInt(x) },
            // Only a Model DEFAULT may look through a parameter: everywhere
            // else the value is whatever the host overrode it with.
            .param_ref => |p| return if (resolve_params)
                self.foldConst(self.lower.params.items[p].default, depth + 1, true)
            else
                null,
            .inst_result => |inst| {
                const row = self.mir.instRow(inst);
                switch (Mir.opClass(row.op)) {
                    .unary => {
                        const a = self.foldConst(@enumFromInt(row.a), depth + 1, resolve_params) orelse return null;
                        return switch (row.op) {
                            .fneg, .ineg => .{ .f = -a.f },
                            .fabs, .iabs => .{ .f = @abs(a.f) },
                            .sqrt => .{ .f = @sqrt(a.f) },
                            .exp => .{ .f = @exp(a.f) },
                            .ln => .{ .f = @log(a.f) },
                            .log10 => .{ .f = @log10(a.f) },
                            .floor => .{ .f = @floor(a.f) },
                            .ceil => .{ .f = @ceil(a.f) },
                            .fi_cast => .{ .f = @round(a.f) },
                            .if_cast, .opt_barrier => .{ .f = a.f },
                            else => null,
                        };
                    },
                    .binary => {
                        const a = self.foldConst(@enumFromInt(row.a), depth + 1, resolve_params) orelse return null;
                        const b2 = self.foldConst(@enumFromInt(row.b), depth + 1, resolve_params) orelse return null;
                        return switch (row.op) {
                            .fadd, .iadd => .{ .f = a.f + b2.f },
                            .fsub, .isub => .{ .f = a.f - b2.f },
                            .fmul, .imul => .{ .f = a.f * b2.f },
                            .fdiv => .{ .f = a.f / b2.f },
                            .idiv => .{ .f = @trunc(a.f / b2.f) },
                            .pow => .{ .f = std.math.pow(f64, a.f, b2.f) },
                            .fmin, .imin => .{ .f = @min(a.f, b2.f) },
                            .fmax, .imax => .{ .f = @max(a.f, b2.f) },
                            else => null,
                        };
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }

    /// Rendered form of a float constant, memoized on its BIT PATTERN.
    ///
    /// `hisimhv_va` emits 385 395 float constants and they are **140 distinct
    /// texts** — 68 600 of them are literally `0.0` and 63 149 are `1.0`. The
    /// unmemoized form did two `allocPrint`s into an arena that is never freed,
    /// so it was ~770 K allocations to produce 140 strings.
    ///
    /// Keyed on `@bitCast`, not on the `f64`: `-0.0` and `0.0` compare equal but
    /// render differently, and NaN is not equal to itself. `std.hash.int` on the
    /// u64 is three multiplies and bijective, so it adds no collisions over the
    /// identity — the same trick as `ssa.zig`'s defs context, and as
    /// `InternPool.Index.Adapter.hash`.
    fn fmtF64(self: *Gen, x: f64) Error![]const u8 {
        if (std.math.isNan(x)) return "std.math.nan(f64)";
        if (std.math.isInf(x)) return if (x > 0) "std.math.inf(f64)" else "-std.math.inf(f64)";
        const gop = try self.f64_cache.getOrPut(self.arena, @bitCast(x));
        if (gop.found_existing) return gop.value_ptr.*;
        // Stack, then copy the survivor — `printFloat` renders into a stack
        // buffer too. `{d}` on an f64 is at most ~24 bytes.
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
        const has_point = for (s) |ch| {
            if (ch == '.' or ch == 'e' or ch == 'E') break true;
        } else false;
        gop.value_ptr.* = if (has_point)
            try self.arena.dupe(u8, s)
        else
            try std.fmt.allocPrint(self.arena, "{s}.0", .{s});
        return gop.value_ptr.*;
    }

    /// Per-instance state: environment (§9.10) plus one field group per
    /// stateful §4.5 operator, KEYED BY THE STABLE UNIT NAME so adding an
    /// unrelated operator never renumbers existing state.
    fn emitInstance(self: *Gen) Error!void {
        try self.w(
            \\/// Per-instance state. The host owns every field above the operator
            \\/// block: `abstime`/`dt` per timestep (§9.10), `analysis_kind` per pass
            \\/// (§4.6.1), `temperature` in kelvin (§9.10), `mfactor` (§6.3.6).
            \\pub const Instance = struct {{
            \\    temperature: f64 = 300.15,
            \\    abstime: f64 = 0.0,
            \\    dt: f64 = 0.0,
            \\    mfactor: f64 = 1.0,
            \\    analysis_kind: AnalysisKind = .dc,
            \\    is_initial_step: bool = false,
            \\    is_final_step: bool = false,
            \\    /// §9.17.2 `$bound_step`: upper bound the model asks for on the
            \\    /// NEXT timestep, in seconds. `inf` = unconstrained. Written by
            \\    /// `updateState`; the host reads it after every accepted step and
            \\    /// shall ignore it outside a time-domain analysis (§9.17.2).
            \\    bound_step: f64 = std.math.inf(f64),
            \\    /// §9.17.1 `$discontinuity`: degree of the announced
            \\    /// discontinuity (0 = the equation itself, 1 = its slope, …), or
            \\    /// -1 for "none announced this step". Written by `updateState`.
            \\    discontinuity_order: i32 = -1,
            \\
        , .{});
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const n = self.unit_names[i];
            switch (opKind(u.target)) {
                .ddt, .transition, .slew => try self.w("    {s}__prev: f64 = 0.0, // §4.5\n", .{n}),
                .idt, .idtmod => try self.w("    {s}__acc: f64 = 0.0, // §4.5.4\n", .{n}),
                .absdelay => try self.w(
                    "    {s}__t: [{d}]f64 = @splat(0.0), // §4.5.7 delay ring\n" ++
                        "    {s}__v: [{d}]f64 = @splat(0.0),\n" ++
                        "    {s}__head: u32 = 0,\n",
                    .{ n, hist_len, n, hist_len, n },
                ),
                .last_crossing => try self.w("    {s}__prev: f64 = 0.0, // §4.5.10\n    {s}__t_last: f64 = -1.0,\n", .{ n, n }),
                .cross => try self.w("    {s}__prev: f64 = 0.0, // §5.10.3\n    {s}__hit: bool = false,\n", .{ n, n }),
                .timer => try self.w("    {s}__next: f64 = 0.0, // §5.10.3\n    {s}__hit: bool = false,\n", .{ n, n }),
                // §4.5.11/§4.5.12 direct-form-I history of the cascade: `deg`
                // past inputs and past outputs per section, newest first. The
                // SHAPE is structural (it comes from the flattened call), which
                // is what keeps it a codegen-time constant even though every
                // coefficient VALUE is a runtime read of Model.
                .laplace, .zi => {
                    const p = try self.filterPlan(self.opInstOf(@intCast(i)) orelse continue, self.opArgs(i));
                    if (p.err != null) continue;
                    try self.w("    {s}__u: [{d}]f64 = @splat(0.0), // §4.5.{s}\n", .{
                        n, p.ns * p.deg, if (opKind(u.target) == .zi) "12" else "11",
                    });
                    try self.w("    {s}__y: [{d}]f64 = @splat(0.0),\n", .{ n, p.ns * p.deg });
                    if (opKind(u.target) == .zi) try self.w(
                        "    {s}__next: f64 = 0.0, // §4.5.12 next sample time\n    {s}__out: f64 = 0.0,\n",
                        .{ n, n },
                    );
                },
                // §9.17 writes the two unconditional fields above, not a
                // per-unit one.
                .none, .above, .bound_step, .discontinuity => {},
            }
        }
        // §5.10 event-assigned variables. LAST, so a model that gains one does
        // not move a single operator field, and the default is the DECLARED
        // initializer — the only evaluation that can observe it is the first,
        // before `updateState` has ever run.
        for (self.lower.held_vars.items, 0..) |h, i| {
            // ponytail: a parameter-dependent initializer takes the parameter's
            // SPEC default, exactly like every §4.5 operator control argument
            // (`f64Expr`/`argF64`), because a struct field default is a comptime
            // value and a model card is not. Upgrade path: write it in
            // `initState`, which already takes a mutable `*Instance`.
            const init = self.foldConst(self.rv(h.init), 0, true);
            const v: f64 = if (init) |c| c.f else 0.0;
            if (h.ty == .integer) {
                try self.w("    {s}: i64 = {d}, // §5.10 held across evaluations\n", .{
                    self.held_names[i], @as(i64, @intFromFloat(@round(v))),
                });
            } else {
                try self.w("    {s}: f64 = {s}, // §5.10 held across evaluations\n", .{
                    self.held_names[i], try self.fmtF64(v),
                });
            }
        }
        try self.w("}};\n\n", .{});
    }

    // =======================================================================
    // Units
    // =======================================================================

    /// One emitted unit function, resolved BEFORE anything is written.
    ///
    /// `planCommon` has to know the exact set of units and their targets in
    /// order to count how many of them share a value, and `emitUnits` has to
    /// emit exactly that set — a disagreement between the two would leave a
    /// value rendered as a cache read in a unit whose slice was never counted.
    /// One list, built once, walked twice.
    const Job = struct {
        name: []const u8,
        target: Mir.Value,
        mode: proof.FloatMode,
        comment: []const u8,
        /// §3.6.2.2 refusal seeded from the unit's DECLARATION (`Gen.pre_fatal`).
        pre_fatal: ?[]const u8 = null,
        /// Index into `units` for an analog-operator job whose §4.5.11/§4.5.12
        /// coefficient reader is emitted right after it; `none_u32` otherwise.
        sec_of: u32 = none_u32,
        /// §9.4: the one job that is NOT folded into the core, because its body
        /// has side effects the residual must not trigger. See `planCommon`.
        is_display: bool = false,
    };

    fn unitMode(self: *const Gen, i: usize) proof.FloatMode {
        // proof.zig rates the CONTRIBUTION units only (proof.unitCount ==
        // lower.contributions.len); an analog-operator unit is not covered, so
        // it takes the safe side.
        if (i >= self.verdict.unit_modes.len) return .strict;
        return self.verdict.unit_modes[i];
    }

    fn buildJobs(self: *Gen) Error!void {
        var jobs: std.ArrayList(Job) = .empty;
        for (self.lower.contributions.items, 0..) |c, i| {
            const mode = self.unitMode(i);
            // §3.6.2.2: a signal-flow discipline binds ONE nature, so its nets
            // carry a value, not a conserved pair. FastVAF's artifact is a
            // nodal/KCL device (§8.3): stamping `<+` on such a net would
            // silently invent the missing half of the branch, so the unit
            // collapses to `@compileError` like any other deliberate gap.
            const pf: ?[]const u8 = if (self.signalFlowNet(c)) |net| try std.fmt.allocPrint(
                self.arena,
                "FastVAF does not implement contributions to the signal-flow port " ++
                    "`{s}` (LRM 1.3.4/3.6.2.2); only a conservative discipline has " ++
                    "the potential/flow pair a nodal device stamps",
                .{net},
            ) else null;
            const resist = self.rv(c.resist_val);
            const react = self.rv(c.react_val);
            if (resist != .f_zero) try jobs.append(self.arena, .{
                .name = self.unit_names[i],
                .target = resist,
                .mode = mode,
                .comment = unitComment(c, false),
                .pre_fatal = pf,
            });
            if (react != .f_zero) try jobs.append(self.arena, .{
                .name = try std.fmt.allocPrint(self.arena, "{s}__q", .{self.unit_names[i]}),
                .target = react,
                .mode = mode,
                .comment = unitComment(c, true),
                .pre_fatal = pf,
            });
        }
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            const args = self.mir.instData(inst).call.args;
            const k = opKind(u.target);
            try jobs.append(self.arena, .{
                .name = self.unit_names[i],
                .target = if (args.len == 0) Mir.Value.f_zero else self.rv(args[0]),
                .mode = self.unitMode(i),
                .comment = switch (k) {
                    .bound_step, .discontinuity => "§9.17 analog kernel control request",
                    else => "§4.5 analog operator input",
                },
                .sec_of = if (k == .laplace or k == .zi) @intCast(i) else none_u32,
            });
        }
        // §5.10 the end-of-block value of every held variable, so `updateState`
        // can store it back. Queued AFTER the operator inputs and before the
        // §9.4 display job for the same insert-tolerance reason: a model that
        // gains a held variable appends a core field, it renumbers none.
        //
        // `.strict` unconditionally: proof.zig rates contributions only.
        for (self.lower.held_vars.items, 0..) |h, i| {
            try jobs.append(self.arena, .{
                .name = self.held_names[i],
                .target = self.rv(h.final),
                .mode = .strict,
                .comment = "§5.10 event-assigned variable, held across evaluations",
            });
        }
        // §9.4 the display tasks, as ONE unit. Queued last, so no existing job —
        // and therefore no existing declaration name — moves when a model gains
        // or loses a `$strobe`.
        //
        // `.strict` unconditionally: proof.zig rates contributions only, a print
        // is not on the residual path, so there is nothing here for `.optimized`
        // to speed up and no verdict that would justify claiming it.
        const root = self.rv(self.lower.display_root);
        if (self.display == .emit and root != .f_zero) {
            var buf: [naming.max_name_len]u8 = undefined;
            const n = naming.unitName(&buf, self.mir.name, .{
                .role = .display,
                .target = "tasks",
            }) catch return error.NameTooLong;
            self.display_name = try self.arena.dupe(u8, n);
            try jobs.append(self.arena, .{
                .name = self.display_name,
                .target = root,
                .mode = .strict,
                .comment = "§9.4 display tasks, in source order",
                .is_display = true,
            });
        }
        self.jobs = jobs.items;
    }

    fn emitUnits(self: *Gen) Error!void {
        try self.w("// ---- the model, in one declaration ----\n\n", .{});
        // The §9.4 display unit calls the core through `core`, not through its
        // structural key, so the ONE call spelling works in both the single-file
        // form (this alias) and the split form (the alias in `Output.prelude`,
        // which is an `@import`). It sits in the prologue, ahead of the first
        // recorded unit range, so the ranges still tile.
        if (self.common_name.len != 0) try self.w("const core = {s};\n\n", .{self.common_name});
        try self.emitCommon();
        // §4.5.11/§4.5.12 the coefficient reader is DERIVED from the operator's
        // unit name (like the old `<unit>__q`), not a Unit of its own, so the
        // normative ordering in naming.zig/proof.zig is untouched. It reads
        // `Model` alone, so it was never part of the residual slice and is
        // unaffected by the merge.
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const k = opKind(u.target);
            if (k != .laplace and k != .zi) continue;
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            const p = try self.filterPlan(inst, self.mir.instData(inst).call.args);
            if (p.err != null) continue;
            const lo = self.out.items.len;
            const nm = try std.fmt.allocPrint(self.arena, "{s}__sec", .{self.unit_names[i]});
            const at = try self.emitFilterSections(self.unit_names[i], p, k == .zi);
            try self.recordUnitFile(nm, lo, at);
        }
        for (self.jobs) |job| {
            if (!job.is_display) continue;
            self.pre_fatal = job.pre_fatal;
            const lo = self.out.items.len;
            const at = try self.emitUnit(job.name, job.target, @tagName(job.mode), job.comment);
            try self.recordUnitFile(job.name, lo, at);
        }
        self.pre_fatal = null;
    }

    /// The one declaration the shared core is emitted into. See the block
    /// comment at "the shared core" for why the whole model is one declaration
    /// returning a struct rather than one declaration per unit.
    ///
    /// The return type is written INLINE (an anonymous struct in the signature)
    /// rather than as a named `Common(S)`: a named type would be a second
    /// top-level declaration, and in the single-file form it would have to be
    /// public for the unit files to reach it — which `contract.validate`
    /// rejects. Zig infers the anonymous type at both ends, so the units never
    /// have to name it.
    fn emitCommon(self: *Gen) Error!void {
        if (self.lo_vals.len == 0) return;
        self.emitting_common = true;
        defer self.emitting_common = false;

        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        // §3.6.2.2 a refusal visible from ANY unit's declaration poisons the one
        // body they now share. That is not a widening: `eval` stamps every
        // contribution, so a `@compileError` in any single unit already failed
        // the whole device.
        self.fatal = null;
        for (self.jobs) |job| {
            if (job.is_display) continue;
            if (job.pre_fatal) |m| {
                self.fatal = m;
                break;
            }
        }
        const pre = self.fatal;
        try self.analyzeUnit(.undef); // `emitting_common` ⇒ the live-outs are the targets

        const lo = self.out.items.len;
        try self.w(
            \\/// The whole model, evaluated ONCE per residual: the {d} source units
            \\/// share one CFG, so they share one declaration and `eval`/`q` read
            \\/// their targets out of the returned struct
            \\/// (docs/architecture/03-codegen.html#hoisting).
            \\
        , .{self.jobs.len});
        const at_fn = self.out.items.len;
        try self.w("fn {s}(comptime S: type, ", .{self.common_name});
        const at_x = self.out.items.len;
        try self.w("x: [n_u]S, ", .{});
        const at_model = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        const at_inst = self.out.items.len;
        try self.w("inst: *const Instance) struct {{\n", .{});
        for (self.lo_vals, 0..) |v, k| {
            try self.w("    f{d}: {s},\n", .{ k, zigTy(self.vty[@intFromEnum(v)]) });
        }
        try self.w("}} {{\n", .{});
        // §4.3: the STRICTEST mode of every consumer — `proof.FloatMode.strictest`
        // explains why the join has to absorb `.strict`.
        try self.w("    @setFloatMode(.{t});\n", .{self.common_mode});

        const body_start = self.out.items.len;
        self.fatal = pre;
        try self.emitUnitBody(.undef);
        if (self.fatal) |msg| {
            self.any_fatal = true;
            self.out.shrinkRetainingCapacity(body_start);
            self.uses_x = false;
            self.uses_model = false;
            self.uses_inst = false;
            try self.b("    @compileError(\"{s}\");\n", .{msg});
        }
        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
        try self.w("}}\n\n", .{});
        try self.recordUnitFile(self.common_name, lo, at_fn);
    }

    fn opInstOf(self: *const Gen, unit: u32) ?Mir.Inst {
        for (self.op_unit, 0..) |u, k| {
            if (u == unit) return @enumFromInt(@as(u32, @intCast(k)));
        }
        return null;
    }

    /// Call arguments of the operator that owns unit `i` (empty if it has none).
    fn opArgs(self: *const Gen, i: usize) []const Mir.Value {
        const inst = self.opInstOf(@intCast(i)) orelse return &.{};
        return self.mir.instData(inst).call.args;
    }

    /// Which field of the core holds analog-operator unit `i`'s §4.5 input, or
    /// `none_u32` for an operator called with no argument (its input is the
    /// literal zero and never reaches the core).
    fn opInputIdx(self: *const Gen, i: u32) u32 {
        const args = self.opArgs(i);
        if (args.len == 0) return none_u32;
        return self.lo_idx[@intFromEnum(self.rv(args[0]))];
    }

    /// Emit one source-unit function. LRM §5.6/§4.7/§5.3.
    /// The signature is UNIFORM and never churns; only the body depends on the
    /// unit's own logic, so `zig` re-Semas exactly the units that changed.
    /// Which parameters the body ended up reading is only known after the body
    /// is rendered, but the signature comes first. Rather than render into a
    /// scratch buffer and copy (a second pass over every byte of a 191 MB
    /// output), emit the signature with three fixed-width slots and overwrite
    /// them in place. Zig does the same thing — `Parse.reserveNode` /`setNode`,
    /// AstGen's `instructions.append(undefined)` … `instructions.set(...)`.
    ///
    /// Zig allows whitespace before a parameter's `:`, so `_` can be padded out
    /// to the width of the name it replaces. Padding the DISCARD rather than the
    /// name keeps the used case byte-identical to a direct emit.
    ///
    /// Returns the offset of the `fn` keyword, which is where
    /// `orchestrator.writeTree` splices `pub ` when the declaration is written
    /// to its own `u/<key>.zig`. It is NOT emitted `pub` here: `text` is also
    /// the single-file `--emit-zig` form, and `contract.rejectStrayPubDecls`
    /// (modules/devices/src/contract.zig) allows only contract-recognized names
    /// to be public on a device type. A per-unit name can never be one of
    /// those, so the visibility belongs to the split, not to the emission.
    fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: []const u8, comment: []const u8) Error!usize {
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        self.fatal = self.pre_fatal;
        try self.analyzeUnit(target);

        try self.w("/// {s}\n", .{comment});
        const at_fn = self.out.items.len;
        try self.w("fn {s}(comptime S: type, ", .{name});
        const at_x = self.out.items.len;
        try self.w("x: [n_u]S, ", .{});
        const at_model = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        const at_inst = self.out.items.len;
        try self.w("inst: *const Instance) S {{\n", .{});
        try self.w("    @setFloatMode(.{s});\n", .{mode});

        const body_start = self.out.items.len;
        try self.emitUnitBody(target);
        if (self.fatal) |msg| {
            self.any_fatal = true;
            self.out.shrinkRetainingCapacity(body_start);
            self.uses_x = false;
            self.uses_model = false;
            self.uses_inst = false;
            try self.b("    @compileError(\"{s}\");\n", .{msg});
        }
        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
        try self.w("}}\n\n", .{});
        return at_fn;
    }

    /// Overwrite a reserved parameter-name slot with `_`, space-padded to the
    /// name's width so the bytes after it do not move.
    fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
        self.out.items[at..][0..width].* = ("_" ++ " " ** (width - 1)).*;
    }

    // ---- slicing: what this unit actually has to compute -------------------

    /// §5.9 Which loops must this unit run for itself?
    ///
    /// The common declaration runs a loop to completion and publishes ONE
    /// snapshot of it. A unit with a private value inside the same loop
    /// re-materializes the loop around that snapshot — and then reads its
    /// counter and its exit condition from a cache already holding their FINAL
    /// values, so the copy runs zero times. (`102_loops` printed
    /// `for sums 1..5 got=0 want=15`.)
    ///
    /// The fix is per UNIT, not per model: a unit that runs a loop locally uses
    /// only local values of it, and every other unit keeps reading the core.
    /// Refusing to hoist loop values at all is sound too and costs 2-5x the
    /// generated output on the models that have loops (hisimhv_va: 17 MB → 78 MB).
    ///
    /// Monotone — marking a loop only ADDS private values, which can only mark
    /// more loops — so the fixpoint converges; in practice after one extra round.
    fn markRecomputedLoops(self: *Gen) bool {
        if (self.emitting_common) return false;
        var grew = false;
        for (self.live.items) |lv| {
            const v = @intFromEnum(lv);
            if (self.cached(lv)) continue; // computed by the core, not here
            const blk = self.def_block[v];
            if (blk == none_u32) continue;
            const l = self.loop_of[blk];
            if (l == none_u32 or self.loop_recompute[l]) continue;
            self.loop_recompute[l] = true;
            grew = true;
        }
        return grew;
    }

    fn analyzeUnit(self: *Gen, target: Mir.Value) Error!void {
        @memset(self.loop_recompute, false);
        while (true) {
            try self.analyzeUnitOnce(target);
            if (!self.markRecomputedLoops()) return;
        }
    }

    fn analyzeUnitOnce(self: *Gen, target: Mir.Value) Error!void {
        // Only the previous unit's live values can be dirty: every write below
        // is guarded by `needed`, which only `mark` sets. Clearing the whole
        // per-value tables per unit was O(units × values).
        for (self.live.items) |lv| {
            const i = @intFromEnum(lv);
            self.needed[i] = false;
            self.eager_use[i] = 0;
            self.arm_use[i] = 0;
            self.inlined[i] = false;
            self.slot[i] = none_u32;
        }
        self.live.clearRetainingCapacity();
        self.n_slots = 0;

        var work: std.ArrayList(Mir.Value) = .empty;
        defer work.deinit(self.arena);
        // The common declaration has many targets — its whole live-out set —
        // and `target` is ignored. One entry point, so the slicing, the use
        // counting and the CFG reconstruction below are shared verbatim.
        if (self.emitting_common) {
            for (self.lo_vals) |v| try self.mark(&work, v);
        } else {
            try self.mark(&work, target);
        }
        try self.closeSlice(&work);
        // Whether the unit needs the CFG at all is decided from the target's
        // own slice; only then do the branch conditions become live (emitting a
        // condition the unit never branches on would declare a local nothing
        // reads — a hard error in Zig).
        self.straight = self.isStraightLine();
        if (!self.straight) {
            // Only the branches this unit can OBSERVE. Hoisting the shared core
            // leaves most units with a handful of private values scattered
            // through a CFG of hundreds of blocks, and reconstructing all of it
            // was, measured on `bsimsoi_va`, 754 of the 5 431 lines of every
            // unit being `if (c) { break :B } else { break :B }`.
            //
            // Marking is monotone — a newly live condition can only ADD work to
            // a block, which can only revive a branch — so this converges, and
            // in practice after two rounds.
            while (true) {
                self.planDeadBranches();
                var grew = false;
                for (self.rpo) |bi| {
                    const t = self.term[bi];
                    if (t == .none) continue;
                    if (self.mir.instOp(t) != .branch) continue;
                    if (self.dead_branch[bi]) continue;
                    const cond = self.rv(self.mir.instData(t).branch.cond);
                    if (self.needed[@intFromEnum(cond)]) continue;
                    try self.mark(&work, cond);
                    grew = true;
                }
                try self.closeSlice(&work);
                if (!grew) break;
            }
        }

        // Ascending value order, so the two sweeps below see exactly the order a
        // full 0..nv scan would. Values are unique ⇒ unstable sort is fine.
        std.mem.sortUnstable(Mir.Value, self.live.items, {}, ltValue);

        // Use counting: a `select` arm (§4.2.12) is a LAZY position.
        self.countUses(target);

        // Descending value order is a topological order for pure ops (a result
        // is always created after its operands), so one sweep suffices.
        var k = self.live.items.len;
        while (k > 0) {
            k -= 1;
            const v = @intFromEnum(self.live.items[k]);
            if (v < Mir.Value.first_dynamic) break; // sentinels sort first
            if (self.eager_use[v] != 0 or self.arm_use[v] == 0) continue;
            // A live-out is a FIELD of the returned cache, so it has to exist as
            // a value; inlining it into its uses would render its expression at
            // every one of them, including the `return`.
            if (self.emitting_common and self.lo_idx[v] != none_u32) continue;
            const def = self.mir.valueDef(@as(Mir.Value, @enumFromInt(v)));
            if (def != .inst_result) continue;
            const op = self.mir.instOp(def.inst_result);
            // A `call` is never inlined: §4.5 operators and ch9 functions are
            // evaluated once per step regardless of which arm is taken.
            if (op == .call or op == .phi) continue;
            self.inlined[v] = true;
            self.reattribute(def.inst_result);
        }

        self.fuseSingleUse();

        // Slots for everything that survives as a statement, in ascending value
        // order — a UNIT-LOCAL dense index, never a MIR value index.
        self.uses_cache = false;
        for (self.live.items) |lv| {
            const v = @intFromEnum(lv);
            if (v < Mir.Value.first_dynamic or self.inlined[v]) continue;
            // A cache read is a field access, as cheap as a parameter read, and
            // it is valid anywhere in the body — it needs no statement and no
            // slot. This is also what lets most units come out straight-line.
            if (self.cached(lv)) {
                self.uses_cache = true;
                continue;
            }
            const def = self.mir.valueDef(lv);
            if (def != .inst_result) continue;
            // §4.5 an operator's INPUT is not a `mark`ed operand — `callArgIsValue`
            // deliberately says no, so the §4.5.2 one-evaluation-per-step rule
            // holds — but `emitOperator` still renders it, and outside the core
            // that rendering is a cache read. Without this the §9.4 display unit
            // (the one unit not folded into the core) emits `c.f1` with no `c`.
            const d = self.mir.instData(def.inst_result);
            if (d == .call and opNeedsInput(opKind(d.call.name)) and d.call.args.len != 0 and
                self.cached(self.rv(d.call.args[0]))) self.uses_cache = true;
            self.slot[v] = self.n_slots;
            self.n_slots += 1;
        }
    }

    /// Which `branch`es this unit cannot tell apart.
    ///
    /// A branch is dead here when both of its edges reduce to the SAME control
    /// action once the empty blocks between are skipped, and neither copies a
    /// phi on the way: the unit then computes the same values and reaches the
    /// same place whichever arm runs, so the condition is unobservable and the
    /// whole `if` can go. This is the per-unit half of the hoist — the shared
    /// core takes the values, this takes the scaffolding that held them.
    fn planDeadBranches(self: *Gen) void {
        @memset(self.blk_work, false);
        @memset(self.blk_phi, false);
        for (self.live.items) |lv| {
            const v = @intFromEnum(lv);
            if (v < Mir.Value.first_dynamic) continue;
            const db = self.def_block[v];
            if (db == none_u32) continue;
            // A phi marks its block EVEN WHEN CACHED. `blk_phi` means "the two
            // arms disagree at this SSA join", which is a property of the CFG
            // and the value — not of whether this unit happens to read the
            // result out of the cache. Measured: with a `cached` skip here,
            // `hisimhv_va` moved 4 000 of 128 000 residual entries.
            const def = self.mir.valueDef(lv);
            if (def == .inst_result and self.i_op[@intFromEnum(def.inst_result)] == .phi)
                self.blk_phi[db] = true;
            if (self.cached(lv)) continue; // a cache read has no block of its own
            self.blk_work[db] = true;
        }
        @memset(self.dead_branch, false);
        for (self.rpo) |bi| {
            const t = self.term[bi];
            if (t == .none or self.mir.instOp(t) != .branch) continue;
            const d = self.mir.instData(t).branch;
            const a = self.edgeAct(bi, @intFromEnum(d.then_block)) orelse continue;
            const b2 = self.edgeAct(bi, @intFromEnum(d.else_block)) orelse continue;
            if (std.meta.eql(a, b2)) self.dead_branch[bi] = true;
        }
    }

    /// What taking `from → to` reduces to for this unit, or null when the edge
    /// does something the unit can observe. Iterative, not recursive: the chain
    /// of empty blocks is bounded by nothing syntactic (PERF.md fix 10).
    const Act = union(enum) { cont: u32, brk: u32 };

    fn edgeAct(self: *const Gen, from0: u32, to0: u32) ?Act {
        var from = from0;
        var to = to0;
        var hops: u32 = 0;
        while (hops <= self.nb) : (hops += 1) {
            // A phi in `to` means `emitEdge` copies a value on this edge, which
            // is the one thing the two arms cannot share.
            if (self.blk_phi[to]) return null;
            if (self.is_loop[to] and self.dominates(to, from)) return .{ .cont = to };
            if (self.is_merge[to]) return .{ .brk = to };
            // Otherwise `to` is emitted INLINE here, so it has to be empty and
            // end in a plain jump for the two arms to stay indistinguishable.
            //
            // §5.9 and NOT inside a loop, even when empty. "Empty of values
            // this unit computes" is not "no effect" on a back edge: the arms
            // decide which loop-carried phi values get copied on the way round,
            // and `blk_phi` only guards a phi's OWN block — a loop-carried phi
            // the unit reads from the cache leaves it clear, so the two arms are
            // NOT interchangeable. It is the same hazard `markRecomputedLoops`
            // re-materializes a loop for. Measured: without this clause,
            // `hisimhv_va` moved 4 000 of 128 000 residual entries.
            if (self.is_loop[to] or self.inLoop(to) or self.blk_work[to]) return null;
            if (self.mk_off[to + 1] != self.mk_off[to]) return null; // opens labels
            const t = self.term[to];
            if (t == .none or self.mir.instOp(t) != .jump) return null;
            from = to;
            to = @intFromEnum(self.mir.instData(t).jump.target);
        }
        return null;
    }

    fn ltValue(_: void, lhs: Mir.Value, rhs: Mir.Value) bool {
        return @intFromEnum(lhs) < @intFromEnum(rhs);
    }

    fn closeSlice(self: *Gen, work: *std.ArrayList(Mir.Value)) Error!void {
        while (work.pop()) |v| {
            const def = self.mir.valueDef(v);
            if (def != .inst_result) continue;
            try self.markOperands(work, def.inst_result);
        }
    }

    fn mark(self: *Gen, work: *std.ArrayList(Mir.Value), v0: Mir.Value) Error!void {
        const v = self.rv(v0);
        if (self.needed[@intFromEnum(v)]) return;
        self.needed[@intFromEnum(v)] = true;
        try self.live.append(self.arena, v);
        // A value read out of the common declaration's cache is a LEAF here:
        // its operands were computed there, and pulling them in is exactly the
        // duplication the hoist removes.
        if (self.cached(v)) return;
        try work.append(self.arena, v);
    }

    fn markOperands(self: *Gen, work: *std.ArrayList(Mir.Value), inst: Mir.Inst) Error!void {
        switch (self.mir.instData(inst)) {
            .unary => |d| try self.mark(work, d.operand),
            .binary => |d| {
                try self.mark(work, d.lhs);
                if (!self.foldedExponent(d)) try self.mark(work, d.rhs);
            },
            .ternary => |d| {
                try self.mark(work, d.cond);
                try self.mark(work, d.then_val);
                try self.mark(work, d.else_val);
            },
            .call => |d| for (d.args, 0..) |a, i| {
                if (callArgIsValue(d.name, i, self.display)) try self.mark(work, a);
            },
            .phi => |d| {
                var i: u32 = 0;
                while (i < d.count) : (i += 1) try self.mark(work, self.mir.phiPair(inst, i).value);
            },
            .branch => |d| try self.mark(work, d.cond),
            .jump => {},
        }
    }

    fn countUses(self: *Gen, target: Mir.Value) void {
        if (self.emitting_common) {
            for (self.lo_vals) |v| self.eager_use[@intFromEnum(v)] += 1;
        } else {
            self.eager_use[@intFromEnum(self.rv(target))] += 1;
        }
        for (self.live.items) |lv| {
            if (self.cached(lv)) continue; // a leaf: its operands are not here
            const def = self.mir.valueDef(lv);
            if (def != .inst_result) continue;
            self.addUses(def.inst_result, false);
        }
        if (self.straight) return;
        for (self.rpo) |bi| {
            const t = self.term[bi];
            if (t == .none) continue;
            if (self.mir.instOp(t) != .branch) continue;
            // A dead branch emits no `if`, so its condition has no use here. It
            // must not be counted, or the value would be slotted and assigned
            // with nothing reading it — which Zig rejects.
            if (self.dead_branch[bi]) continue;
            self.eager_use[@intFromEnum(self.rv(self.mir.instData(t).branch.cond))] += 1;
        }
    }

    /// `undo = false` counts, `undo = true` moves this instruction's eager uses
    /// into arm uses (called when the instruction itself became lazy).
    fn addUses(self: *Gen, inst: Mir.Inst, undo: bool) void {
        const bump = struct {
            fn f(g: *Gen, v: Mir.Value, arm: bool, un: bool) void {
                const i = @intFromEnum(g.rv(v));
                if (!g.needed[i]) return;
                if (un) {
                    if (arm) return; // already an arm use
                    if (g.eager_use[i] > 0) g.eager_use[i] -= 1;
                    g.arm_use[i] += 1;
                } else if (arm) {
                    g.arm_use[i] += 1;
                } else {
                    g.eager_use[i] += 1;
                }
            }
        }.f;
        switch (self.mir.instData(inst)) {
            .unary => |d| bump(self, d.operand, false, undo),
            .binary => |d| {
                bump(self, d.lhs, false, undo);
                if (!self.foldedExponent(d)) bump(self, d.rhs, false, undo);
            },
            .ternary => |d| {
                bump(self, d.cond, false, undo);
                bump(self, d.then_val, true, undo);
                bump(self, d.else_val, true, undo);
            },
            .call => |d| for (d.args, 0..) |a, i| {
                if (callArgIsValue(d.name, i, self.display)) bump(self, a, false, undo);
            },
            .phi => |d| {
                var i: u32 = 0;
                while (i < d.count) : (i += 1) bump(self, self.mir.phiPair(inst, i).value, false, undo);
            },
            .branch, .jump => {},
        }
    }

    fn reattribute(self: *Gen, inst: Mir.Inst) void {
        self.addUses(inst, true);
    }

    /// A value read EXACTLY ONCE, by the very next statement of its own block,
    /// is rendered inside that statement instead of getting a `const` of its
    /// own. `renderValueRef` already falls through to `renderInst` for anything
    /// without a slot, so clearing the slot IS the fusion — no new rendering
    /// path, and chains collapse transitively because the fallthrough recurses.
    ///
    /// Measured on the emitted text before writing this: 14,930 of 16,242 `const
    /// tN` temps (92%) have exactly one use, and 11,366 of those are consumed on
    /// the very next line. That adjacency is the whole safety argument and the
    /// reason this is not the same pass as the lazy-arm inlining above:
    ///
    ///   - ONE use, so the expression is rendered once — no duplicated work.
    ///     `eager_use == 1 and arm_use == 0` is exactly that, since an arm use
    ///     is re-rendered per arm by design.
    ///   - the use is the NEXT statement in `stmt_pool`, so the computation
    ///     moves later by one statement, inside the same block. Nothing can be
    ///     hoisted into a loop body or sunk past a side effect, which is what a
    ///     general "def dominates use" rule would have to reason about.
    ///
    /// So this must NOT call `reattribute`: the operands stay eager because the
    /// expression is still evaluated exactly once, eagerly, one statement later.
    fn fuseSingleUse(self: *Gen) void {
        for (0..self.nb) |bi| {
            const stmts = self.stmt_pool[self.stmt_off[bi]..self.stmt_off[bi + 1]];
            if (stmts.len < 2) continue;
            for (stmts[0 .. stmts.len - 1], stmts[1..]) |inst, next| {
                const v = @intFromEnum(self.rv(self.i_res[@intFromEnum(inst)]));
                if (v < Mir.Value.first_dynamic) continue;
                if (!self.needed[v] or self.inlined[v]) continue;
                if (self.eager_use[v] != 1 or self.arm_use[v] != 0) continue;
                // A live-out is a FIELD of the returned cache (same reason as
                // the sweep above), and a cached value renders as `c.fN`
                // wherever it appears, so neither is ours to fuse.
                if (self.emitting_common and self.lo_idx[v] != none_u32) continue;
                if (self.cached(@enumFromInt(v))) continue;
                const op = self.mir.instOp(inst);
                // `call` is an operator/function evaluated once per step (§4.5),
                // `phi` is materialised as a `var` — neither is an expression.
                if (op == .call or op == .phi) continue;
                if (!self.eagerlyUses(next, @enumFromInt(v))) continue;
                self.inlined[v] = true;
            }
        }
    }

    /// Does `inst` read `v` in an EAGER position? Mirrors `addUses`, including
    /// its two exclusions — a folded constant exponent is never materialised,
    /// and a non-value call argument is not an operand — so that the counts this
    /// is checked against and the answer here cannot drift apart. A `ternary`'s
    /// arms are lazy positions, which is `arm_use`, not this.
    fn eagerlyUses(self: *const Gen, inst: Mir.Inst, v: Mir.Value) bool {
        return switch (self.mir.instData(inst)) {
            .unary => |d| self.rv(d.operand) == v,
            .binary => |d| self.rv(d.lhs) == v or
                (!self.foldedExponent(d) and self.rv(d.rhs) == v),
            .ternary => |d| self.rv(d.cond) == v,
            .call => |d| for (d.args, 0..) |a, i| {
                if (callArgIsValue(d.name, i, self.display) and self.rv(a) == v) break true;
            } else false,
            else => false,
        };
    }

    /// §4.3.1 `pow(x, k)` with a constant exponent goes through the scalar's
    /// `pow(S, f64)`, so the exponent is never materialised as a value.
    fn foldedExponent(self: *const Gen, d: anytype) bool {
        return d.op == .pow and self.foldConst(d.rhs, 0, true) != null;
    }

    // ---- body emission ------------------------------------------------------

    fn zigTy(t: VTy) []const u8 {
        return switch (t) {
            .real => "S",
            .int => "i64",
            .str => "[]const u8",
        };
    }

    /// The identity a slot starts at when it must be defined on every path.
    /// Matches `renderVal`'s rendering of an `.undef` operand, so the two agree
    /// on what "no value here" looks like.
    /// Name of the hoist array a slot of this type lives in — see `hoist_idx`.
    fn hoistArray(t: VTy) []const u8 {
        return switch (t) {
            .real => "h",
            .int => "hi",
            .str => "hs",
        };
    }

    /// Write the name a value's slot is read and written under: its own `tN`,
    /// or an element of its type's hoist array. The ONE place that knows the
    /// difference, so declaration and use can never drift apart.
    fn writeSlotRef(self: *Gen, i: usize) Error!void {
        const s = self.slot[i];
        const h = if (s < self.hoist_idx.items.len) self.hoist_idx.items[s] else none_u32;
        if (h == none_u32) return self.b("t{d}", .{s});
        return self.b("{s}[{d}]", .{ hoistArray(self.vty[i]), h });
    }

    fn zeroOf(t: VTy) []const u8 {
        return switch (t) {
            .real => "S.con(0.0)",
            .int => "0",
            .str => "\"\"",
        };
    }

    /// True when the slice lives entirely in the entry block and uses no phi —
    /// the common case (no `if` on the path to this contribution), and worth a
    /// special case because it emits flat, readable `const` code.
    ///
    /// Iterates `live`, not `0..nv`: it is called once per unit, and `live` is
    /// the small set `mark` actually reached — the same reason fix 5 in PERF.md
    /// gives for every other per-unit sweep.
    fn isStraightLine(self: *const Gen) bool {
        for (self.live.items) |lv| {
            const v = @intFromEnum(lv);
            if (v < Mir.Value.first_dynamic) continue;
            // A cache read is a field of a value the body already holds, so it
            // has no block of its own — which is what collapses most units to a
            // flat body once the shared core is hoisted out of them.
            if (self.cached(lv)) continue;
            const db = self.def_block[v];
            if (db != none_u32 and db != 0) return false;
            const def = self.mir.valueDef(lv);
            if (def == .inst_result and self.mir.instOp(def.inst_result) == .phi) return false;
        }
        return true;
    }

    /// Where one slot's declaration ends up, and the evidence for it.
    ///
    /// `def_off`/`max_use` are output offsets and `scope` an index into
    /// `sc_end`: since the emitted scopes nest, "every use is lexically inside
    /// the block that defines this slot" is exactly
    /// `def_off < max_use < sc_end[scope]`, and no dominator query is needed —
    /// the emitter's own brace placement IS the answer.
    const Place = struct {
        defs: u32 = 0,
        uses: u32 = 0,
        def_off: u32 = 0,
        max_use: u32 = 0,
        scope: u32 = 0,
        /// Something disqualifies this slot from `const`-at-definition: a
        /// second assignment (a real phi), a phi copy on a CFG edge, or a use
        /// emitted before the assignment (a loop-carried read).
        pinned: bool = false,
        /// Set once, after the probe: declare at the definition instead of at
        /// function scope.
        at_def: bool = false,
    };

    fn scopeOpen(self: *Gen) Error!void {
        if (!self.probing) return;
        try self.sc_end.append(self.arena, 0);
        try self.sc_open.append(self.arena, @intCast(self.sc_end.items.len - 1));
    }

    /// `at` is where the scope's text ends, which is NOT always `out.len`: the
    /// `emitCode` peephole rewinds over a label it decided not to keep.
    fn scopeClose(self: *Gen, at: usize) void {
        if (!self.probing) return;
        self.sc_end.items[self.sc_open.pop().?] = @intCast(at);
    }

    /// `movable` is false for a phi copy: `emitPhiCopies` writes the slot from
    /// several edges, and even a single-edge copy lands in an arm its merge
    /// block's readers are lexically outside of.
    fn probeDef(self: *Gen, slot: u32, movable: bool) void {
        if (!self.probing) return;
        const p = &self.place.items[slot];
        if (p.defs == 0) {
            p.def_off = @intCast(self.out.items.len);
            p.scope = self.sc_open.getLast();
        }
        p.defs += 1;
        if (p.defs > 1 or !movable) p.pinned = true;
    }

    fn probeUse(self: *Gen, slot: u32) void {
        if (!self.probing) return;
        const p = &self.place.items[slot];
        p.uses += 1;
        // Read before written in the text: a loop-carried value, or a slot the
        // emitter never assigns at all (which is the `undefined`/zero seed the
        // hoist exists to provide).
        if (p.defs == 0) p.pinned = true;
        p.max_use = @max(p.max_use, @as(u32, @intCast(self.out.items.len)));
    }

    /// Emit the body once into scratch to learn, per slot, where its assignment
    /// lands relative to its reads; rewind; then emit for real.
    ///
    /// A dry run rather than a dominator/liveness query because the emitted
    /// nesting is not the CFG: `planDeadBranches` deletes `if`s, the `emitCode`
    /// peephole deletes labels, and `emitEdge` inlines a whole subtree into an
    /// arm. Re-deriving the resulting brace structure would be a second, subtly
    /// different copy of the emitter. Emission only appends to `out` and only
    /// sets monotone `uses_*` flags, so running it twice is free of side
    /// effects (`fatal` is set-once and reproduces the same message).
    fn probeBody(self: *Gen, target: Mir.Value) Error!void {
        self.place.clearRetainingCapacity();
        try self.place.appendNTimes(self.arena, .{}, self.n_slots);
        self.sc_end.clearRetainingCapacity();
        self.sc_open.clearRetainingCapacity();

        const at = self.out.items.len;
        self.probing = true;
        try self.scopeOpen(); // the function body itself
        try self.emitTree(0, 1, target);
        self.scopeClose(self.out.items.len);
        self.probing = false;
        self.out.shrinkRetainingCapacity(at);

        for (self.place.items) |*p| {
            // `uses == 0` keeps its `var`: a slot that is written and never read
            // is legal Zig, but the same code as an unused `const` is not.
            p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
                p.max_use < self.sc_end.items[p.scope];
        }
    }

    fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
        // FIRST, before anything can emit a slot name: slot numbering is
        // unit-local, so last unit's hoist indices would otherwise still be
        // live here and rename this unit's slots into another unit's array.
        // Both paths below can emit before the real assignment happens — the
        // straight-line path returns early, and `probeBody` dry-runs the whole
        // body — so clearing anywhere later is too late.
        self.hoist_idx.clearRetainingCapacity();
        try self.hoist_idx.appendNTimes(self.arena, none_u32, self.n_slots);

        // One call, at the top of the body, so the shared core is evaluated
        // exactly once per unit — the same number of times it is evaluated
        // today, when every unit inlines a copy of it.
        if (self.uses_cache) {
            self.uses_x = true;
            self.uses_model = true;
            self.uses_inst = true;
            try self.ind(1);
            try self.b("const c = core(S, x, model, inst);\n", .{});
        }
        if (self.straight) {
            try self.emitBlockInsts(0, 1, true);
            try self.emitReturn(1, target);
            return;
        }
        // Out-of-SSA: a function-scope `var` per surviving value that NEEDS
        // one. Function scope (not the defining lexical block) because a
        // labelled-block reconstruction can put a definition inside a scope its
        // dominated uses are lexically outside of — but that is the exception,
        // not the rule, so `probeBody` measures it instead of assuming it and
        // `emitBlockInsts` declares the rest as `const` at the definition. On
        // `hisimhv_va` that is 16 k of 20 k hoists removed, ~26% of the file.
        //
        // What is left hoisted, and why each one has to be:
        //   - assigned more than once — a genuine phi, so it must be a `var`;
        //   - assigned by `emitPhiCopies` — the copy sits in the arm, the
        //     readers sit after the merge;
        //   - read outside the block that assigns it — the labelled-block case
        //     the comment above describes;
        //   - never assigned at all, which is the `undefined`/zero seed below.
        //
        // `undefined` is safe for every slot EXCEPT one the function RETURNS.
        // SSA guarantees a use is dominated by its definition, so an ordinary
        // slot is always written before it is read — but the return is reached
        // from every exit block, including ones the definition does not
        // dominate. That happens whenever the unit's target is defined inside a
        // conditional, which is exactly what `if (c) I <+ transition(x)` builds:
        // the operator's INPUT unit then returned `undefined` on the not-taken
        // path, and `updateState` pushed that into the operator's history —
        // undefined behavior in a shipped device, and silent state corruption in
        // the far more common case where it merely looked like a number.
        //
        // Zero is the value, not just a safe one: the arm did not execute, so it
        // contributed nothing this step — the same reason lowering seeds a §5.6
        // contribution accumulator with `.f_zero`.
        // Pinned by tests/fixtures/exhaustive/069_conditional_operator_state.va.
        try self.probeBody(target);
        const ret = self.rv(target);

        // One array per type instead of one `var` per slot. Two passes: assign
        // every survivor its index first, so the array lengths are known before
        // anything is written, then emit the declarations. `hoist_idx` was
        // cleared at entry and `probeBody` has just run against those cleared
        // names, so this is the first assignment either pass has seen.
        var n_hoist = [_]u32{0} ** 3;
        // A returned slot cannot be seeded `undefined` (see above), and an array
        // is declared once for all of its elements — so those are seeded by an
        // explicit store after the declaration instead.
        var seeded: std.ArrayList(Mir.Value) = .empty;
        defer seeded.deinit(self.arena);
        for (self.live.items) |lv| {
            const v = @intFromEnum(lv);
            if (self.slot[v] == none_u32) continue;
            const p = self.place.items[self.slot[v]];
            if (p.at_def) continue;
            // Never assigned and never read: `mark` kept the value alive but
            // the emitted tree reaches neither end of it. Declaring it would be
            // an unused local.
            if (p.defs == 0 and p.uses == 0) continue;
            const ty = @intFromEnum(self.vty[v]);
            self.hoist_idx.items[self.slot[v]] = n_hoist[ty];
            n_hoist[ty] += 1;
            const returned = if (self.emitting_common) self.lo_idx[v] != none_u32 else lv == ret;
            if (returned) try seeded.append(self.arena, lv);
        }
        for ([_]VTy{ .real, .int, .str }) |ty| {
            const n = n_hoist[@intFromEnum(ty)];
            if (n == 0) continue;
            try self.ind(1);
            try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
        }
        for (seeded.items) |lv| {
            const v = @intFromEnum(lv);
            try self.ind(1);
            try self.writeSlotRef(v);
            try self.b(" = {s};\n", .{zeroOf(self.vty[v])});
        }
        try self.emitTree(0, 1, target);
    }

    /// A unit returns its one contribution value; the common declaration
    /// returns the whole cache. Same exit points either way, so this is the one
    /// place that knows the difference.
    fn emitReturn(self: *Gen, depth: u32, target: Mir.Value) Error!void {
        try self.ind(depth);
        if (!self.emitting_common) {
            try self.b("return ", .{});
            try self.renderVal(target, .real);
            try self.b(";\n", .{});
            return;
        }
        try self.b("return .{{\n", .{});
        for (self.lo_vals, 0..) |v, k| {
            try self.ind(depth + 1);
            try self.b(".f{d} = ", .{k});
            try self.renderVal(v, self.vty[@intFromEnum(v)]);
            try self.b(",\n", .{});
        }
        try self.ind(depth);
        try self.b("}};\n", .{});
    }

    fn emitBlockInsts(self: *Gen, bi: u32, depth: u32, comptime decl: bool) Error!void {
        for (self.stmt_pool[self.stmt_off[bi]..self.stmt_off[bi + 1]]) |inst| {
            const i = @intFromEnum(self.i_res[@intFromEnum(inst)]);
            if (!self.needed[i] or self.slot[i] == none_u32) continue;
            self.probeDef(self.slot[i], true);
            // `or` short-circuits, so the straight-line path (`decl`, which runs
            // without a probe) never touches `place`.
            const at_def = decl or self.place.items[self.slot[i]].at_def;
            try self.ind(depth);
            if (at_def) {
                try self.b("const t{d}: {s} = ", .{ self.slot[i], zigTy(self.vty[i]) });
            } else {
                try self.writeSlotRef(i);
                try self.b(" = ", .{});
            }
            try self.renderInst(inst);
            try self.b(";\n", .{});
        }
    }

    fn emitTree(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
        if (self.is_loop[bi]) {
            try self.ind(depth);
            try self.b("L{d}: while (true) {{\n", .{bi});
            try self.scopeOpen();
            try self.emitCode(bi, depth + 1, target);
            self.scopeClose(self.out.items.len);
            try self.ind(depth);
            try self.b("}}\n", .{});
        } else {
            try self.emitCode(bi, depth, target);
        }
    }

    fn emitCode(self: *Gen, bi: u32, depth0: u32, target: Mir.Value) Error!void {
        const mc = self.mk_pool[self.mk_off[bi]..self.mk_off[bi + 1]];
        var depth = depth0;
        // Where the INNERMOST label (`mc[0]`, opened last) begins — the peephole
        // below rewinds to it.
        var at_inner: usize = 0;
        var i = mc.len;
        while (i > 0) {
            i -= 1;
            if (i == 0) at_inner = self.out.items.len;
            try self.ind(depth);
            try self.b("B{d}: {{\n", .{mc[i]});
            try self.scopeOpen();
            depth += 1;
        }
        const body_start = self.out.items.len;
        try self.emitBlockInsts(bi, depth, false);
        try self.emitTerm(bi, depth, target);

        // PEEPHOLE. `B{k}: { break :B{k}; }` is a labelled block whose only
        // statement is to leave it, and an empty one says the same thing — both
        // mean "fall through to `k`'s own code", which is emitted right after
        // the closing brace either way. This is what `planDeadBranches` leaves
        // behind once the `if` that used to sit here is gone: measured on
        // `bsimsoi_va`, 2 262 of a unit's remaining 3 207 lines. Rewinding `out`
        // is the same reserve-and-back-patch `emitUnit` uses for the signature.
        const dropped = mc.len != 0 and self.isFallThrough(body_start, depth, mc[0]);
        if (dropped) {
            self.out.shrinkRetainingCapacity(at_inner);
            self.scopeClose(at_inner);
            depth -= 1;
        }
        for (mc, 0..) |k, j| {
            if (j != 0 or !dropped) {
                depth -= 1;
                self.scopeClose(self.out.items.len);
                try self.ind(depth);
                try self.b("}}\n", .{});
            }
            try self.emitTree(k, depth, target);
        }
    }

    /// Is everything emitted since `at` exactly "leave the block labelled `k`"?
    /// A break to any OTHER label is not the same thing: dropping this label
    /// would then let control fall into `k`'s code instead of past it.
    fn isFallThrough(self: *const Gen, at: usize, depth: u32, k: u32) bool {
        const body = self.out.items[at..];
        if (body.len == 0) return true;
        var buf: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "break :B{d};\n", .{k}) catch return false;
        if (body.len != depth * 4 + want.len) return false;
        for (body[0 .. depth * 4]) |ch| {
            if (ch != ' ') return false;
        }
        return std.mem.eql(u8, body[depth * 4 ..], want);
    }

    fn emitTerm(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
        const t = self.term[bi];
        if (t == .none) {
            // The block lowering ended in: the contribution accumulators are
            // read here (§5.6.1.3).
            try self.emitReturn(depth, target);
            return;
        }
        switch (self.mir.instData(t)) {
            .jump => |d| try self.emitEdge(bi, @intFromEnum(d.target), depth, target),
            .branch => |d| {
                // `planDeadBranches`: both arms reconverge with nothing this
                // unit can observe in between, so emit the common action once.
                if (self.dead_branch[bi])
                    return self.emitEdge(bi, @intFromEnum(d.then_block), depth, target);
                try self.ind(depth);
                try self.b("if (", .{});
                try self.renderCond(d.cond);
                try self.b(") {{\n", .{});
                try self.scopeOpen();
                try self.emitEdge(bi, @intFromEnum(d.then_block), depth + 1, target);
                self.scopeClose(self.out.items.len);
                try self.ind(depth);
                try self.b("}} else {{\n", .{});
                try self.scopeOpen();
                try self.emitEdge(bi, @intFromEnum(d.else_block), depth + 1, target);
                self.scopeClose(self.out.items.len);
                try self.ind(depth);
                try self.b("}}\n", .{});
            },
            else => unreachable,
        }
    }

    fn renderCond(self: *Gen, cond: Mir.Value) Error!void {
        const v = self.rv(cond);
        if (self.tyOf(v) == .int) {
            try self.renderVal(v, .int);
            try self.b(" != 0", .{});
        } else {
            try self.b("(", .{});
            try self.renderVal(v, .real);
            try self.b(").val() != 0.0", .{});
        }
    }

    fn emitEdge(self: *Gen, from: u32, to: u32, depth: u32, target: Mir.Value) Error!void {
        try self.emitPhiCopies(from, to, depth);
        if (self.is_loop[to] and self.dominates(to, from)) {
            try self.ind(depth);
            try self.b("continue :L{d};\n", .{to});
        } else if (self.is_merge[to]) {
            try self.ind(depth);
            try self.b("break :B{d};\n", .{to});
        } else {
            try self.emitTree(to, depth, target);
        }
    }

    /// SSA-out-of-form on the edge `from → to`. Emitted through temporaries when
    /// `to` has more than one live phi, so a phi reading another phi of the same
    /// block (the swap idiom) cannot lose a copy.
    fn emitPhiCopies(self: *Gen, from: u32, to: u32, depth: u32) Error!void {
        const phis = self.phi_pool[self.phi_off[to]..self.phi_off[to + 1]];
        var n: u32 = 0;
        for (phis) |inst| {
            if (self.slotted(inst)) n += 1;
        }
        if (n == 0) return;
        const par = n > 1;
        if (par) {
            try self.ind(depth);
            try self.b("{{\n", .{});
        }
        const d2 = if (par) depth + 1 else depth;
        var k: u32 = 0;
        for (phis) |inst| {
            if (!self.slotted(inst)) continue;
            const i = @intFromEnum(self.i_res[@intFromEnum(inst)]);
            try self.ind(d2);
            if (par) {
                try self.b("const c{d}: {s} = ", .{ k, zigTy(self.vty[i]) });
            } else {
                self.probeDef(self.slot[i], false);
                try self.writeSlotRef(i);
                try self.b(" = ", .{});
            }
            try self.renderVal(self.phiIn(inst, from), self.vty[i]);
            try self.b(";\n", .{});
            k += 1;
        }
        if (!par) return;
        k = 0;
        for (phis) |inst| {
            if (!self.slotted(inst)) continue;
            try self.ind(d2);
            self.probeDef(self.slot[@intFromEnum(self.i_res[@intFromEnum(inst)])], false);
            try self.writeSlotRef(@intFromEnum(self.i_res[@intFromEnum(inst)]));
            try self.b(" = c{d};\n", .{k});
            k += 1;
        }
        try self.ind(depth);
        try self.b("}}\n", .{});
    }

    /// A phi whose result survives aliasing — the `phi_pool` filter, CFG-wide.
    fn livePhi(self: *const Gen, inst: Mir.Inst) bool {
        if (self.i_op[@intFromEnum(inst)] != .phi) return false;
        const r = self.i_res[@intFromEnum(inst)];
        return self.rv(r) == r;
    }

    /// The `stmt_pool` filter: everything a unit body may emit as a statement.
    /// Phis are block headers, terminators are `emitTerm`'s, and an aliased
    /// result was rewritten away by ssa.zig.
    fn liveStmt(self: *const Gen, inst: Mir.Inst) bool {
        switch (self.i_op[@intFromEnum(inst)]) {
            .phi, .branch, .jump => return false,
            else => {},
        }
        const r = self.i_res[@intFromEnum(inst)];
        return r != .undef and self.rv(r) == r;
    }

    /// A pooled phi this unit actually materializes into a local slot.
    fn slotted(self: *const Gen, inst: Mir.Inst) bool {
        const i = @intFromEnum(self.i_res[@intFromEnum(inst)]);
        return self.needed[i] and self.slot[i] != none_u32;
    }

    fn phiIn(self: *const Gen, inst: Mir.Inst, from: u32) Mir.Value {
        const d = self.mir.instData(inst).phi;
        var i: u32 = 0;
        while (i < d.count) : (i += 1) {
            const p = self.mir.phiPair(inst, i);
            if (@intFromEnum(p.block) == from) return p.value;
        }
        return .undef;
    }

    // ---- value / instruction rendering --------------------------------------

    /// Emit a value reference, converting per §4.2.1.1/§4.2.1.2 when the use
    /// wants the other LRM type.
    /// `renderVal` into a string instead of into `out`.
    ///
    /// Rendering only ever APPENDS, so the scratch buffer is `out` itself: emit,
    /// copy the tail, rewind. That keeps one growable buffer for the whole
    /// emission and keeps `uses_x`/`uses_model` accounting identical to a direct
    /// render — the same reserve-and-rewind trick `emitCode`'s peephole and
    /// `emitUnit`'s parameter slots use.
    ///
    /// Only for the handful of §4.5 operator inputs that have to appear inside a
    /// `{s}` of a kernel call; everything else renders straight into `out`.
    fn renderToArena(self: *Gen, v: Mir.Value, want: VTy) Error![]const u8 {
        const at = self.out.items.len;
        try self.renderVal(v, want);
        const s = try self.arena.dupe(u8, self.out.items[at..]);
        self.out.shrinkRetainingCapacity(at);
        return s;
    }

    fn renderVal(self: *Gen, v0: Mir.Value, want: VTy) Error!void {
        const v = self.rv(v0);
        const def = self.mir.valueDef(v);
        if (def == .undef) {
            try self.b("{s}", .{switch (want) {
                .real => "S.con(0.0)",
                .int => "0",
                .str => "\"\"",
            }});
            return;
        }
        if (self.tyOf(v) == want) return self.renderValueRef(v);
        switch (want) {
            .real => {
                if (def == .int_const) {
                    try self.b("S.con({s})", .{try self.fmtF64(@floatFromInt(def.int_const))});
                    return;
                }
                try self.b("S.con(@as(f64, @floatFromInt(", .{});
                try self.renderValueRef(v);
                try self.b(")))", .{});
            },
            .int => {
                if (def == .float_const) {
                    const x = def.float_const;
                    const n: i64 = if (std.math.isFinite(x)) @intFromFloat(@round(x)) else 0;
                    try self.b("{d}", .{n});
                    return;
                }
                // A string has no numeric value (§3.3); only its relations are
                // defined, and `renderOp` handles those before getting here.
                if (self.tyOf(v) == .str) return self.b("@as(i64, 0)", .{});
                try self.b("@as(i64, @intFromFloat(@round((", .{});
                try self.renderValueRef(v);
                try self.b(").val())))", .{});
            },
            .str => try self.b("\"\"", .{}),
        }
    }

    /// LRM §4. Constants → `S.con(literal)`, parameters → `model.<name>`, node
    /// probes → `x[@intFromEnum(U.<node>)]`, instruction results → the
    /// UNIT-LOCAL slot name (never `v{MIR index}` — 03-codegen.html).
    fn renderValueRef(self: *Gen, v: Mir.Value) Error!void {
        const i = @intFromEnum(v);
        // Hoisted: computed once by the common declaration, read here out of the
        // cache the body opened with (03-codegen.html#hoisting).
        if (i < self.nv and self.cached(v)) return self.b("c.f{d}", .{self.lo_idx[i]});
        if (i < self.nv and self.slot[i] != none_u32) {
            self.probeUse(self.slot[i]);
            try self.writeSlotRef(i);
            return;
        }
        switch (self.mir.valueDef(v)) {
            .undef => try self.b("S.con(0.0)", .{}),
            .float_const => |x| try self.b("S.con({s})", .{try self.fmtF64(x)}),
            .int_const => |x| try self.b("@as(i64, {d})", .{x}),
            .str_const => |s| try self.b("\"{f}\"", .{std.zig.fmtString(s)}),
            .param_ref => |p| {
                self.uses_model = true;
                switch (tyOfParam(self.lower.params.items[p].ty)) {
                    .real => try self.b("S.con(model.{s})", .{self.p_names[p]}),
                    .int, .str => try self.b("model.{s}", .{self.p_names[p]}),
                }
            },
            .block_param => |u| {
                self.uses_x = true;
                try self.b("x[@intFromEnum(U.{s})]", .{self.u_names[u]});
            },
            .inst_result => |inst| try self.renderInst(inst),
        }
    }

    fn renderInst(self: *Gen, inst: Mir.Inst) Error!void {
        const row = self.mir.instRow(inst);
        const op = row.op;
        if (op == .call) return self.emitCall(inst);
        if (op == .phi) return self.b("S.con(0.0)", .{}); // materialised as a var

        const a: Mir.Value = @enumFromInt(row.a);
        const b2: Mir.Value = @enumFromInt(row.b);
        const c: Mir.Value = @enumFromInt(row.c);

        // §4.2.12 the value-form conditional MUST stay lazy: proof.zig treats
        // the condition as a guard on the arms, so `x > 0 ? ln(x) : 0` is
        // accepted — evaluating both arms would run ln(x) with x <= 0, which is
        // UB under @setFloatMode(.optimized). Do not "simplify" this to a
        // select of two pre-computed values.
        if (op == .select) {
            const want = self.vty[@intFromEnum(self.mir.instResult(inst))];
            try self.b("(if (", .{});
            try self.renderCond(a);
            try self.b(") ", .{});
            try self.renderVal(b2, want);
            try self.b(" else ", .{});
            try self.renderVal(c, want);
            try self.b(")", .{});
            return;
        }
        return self.renderOp(op, a, b2, self.vty[@intFromEnum(self.mir.instResult(inst))]);
    }

    /// One opcode, rendered. Shared with the `$`-prefixed spellings of the same
    /// math functions (IEEE 1364 §17.11, carried into Verilog-AMS ch9).
    fn renderOp(self: *Gen, op: Mir.Opcode, a: Mir.Value, b2: Mir.Value, res_ty: VTy) Error!void {
        // §3.3.1 string relations: lowering types both operands `.string` and
        // picks the integer comparison opcodes for them.
        if (self.tyOf(self.rv(a)) == .str or self.tyOf(self.rv(b2)) == .str) {
            const rel: ?[]const u8 = switch (op) {
                .ieq, .feq => "== 0",
                .ine, .fne => "!= 0",
                .ilt, .flt => "< 0",
                .ile, .fle => "<= 0",
                .igt, .fgt => "> 0",
                .ige, .fge => ">= 0",
                else => null,
            };
            if (rel) |r| {
                try self.b("@as(i64, @intFromBool(zStrCmp(", .{});
                try self.renderVal(a, .str);
                try self.b(", ", .{});
                try self.renderVal(b2, .str);
                try self.b(") {s}))", .{r});
                return;
            }
        }
        switch (op) {
            // §4.2.4 real arithmetic
            .fadd => try self.method2(a, "add", b2),
            .fsub => try self.method2(a, "sub", b2),
            .fmul => try self.method2(a, "mul", b2),
            .fdiv => try self.method2(a, "div", b2),
            .fneg => try self.method1(a, "neg"),
            .fmod => try self.helper2("zFmod", a, b2),
            // §4.3.1/§4.3.2 math
            .sqrt => try self.method1(a, "sqrt"),
            .exp => try self.method1(a, "exp"),
            .ln => try self.method1(a, "log"),
            .sin => try self.method1(a, "sin"),
            .cos => try self.method1(a, "cos"),
            .tanh => try self.method1(a, "tanh"),
            .sinh => try self.method1(a, "sinh"),
            .cosh => try self.method1(a, "cosh"),
            .atan => try self.method1(a, "atan"),
            .fabs => try self.method1(a, "abs"),
            .expm1 => try self.helper1("zExpm1", a),
            .ln1p => try self.helper1("zLn1p", a),
            .log10 => try self.helper1("zLog10", a),
            .tan => try self.helper1("zTan", a),
            .asin => try self.helper1("zAsin", a),
            .acos => try self.helper1("zAcos", a),
            .asinh => try self.helper1("zAsinh", a),
            .acosh => try self.helper1("zAcosh", a),
            .atanh => try self.helper1("zAtanh", a),
            .floor => try self.helper1("zFloor", a),
            .ceil => try self.helper1("zCeil", a),
            .hypot => try self.helper2("zHypot", a, b2),
            .atan2 => try self.helper2("zAtan2", a, b2),
            .fmin => try self.method2(a, "min", b2),
            .fmax => try self.method2(a, "max", b2),
            .pow => {
                // The scalar interface only has pow(S, f64); a constant exponent
                // (the overwhelming case) uses it, anything else goes through
                // exp(y·ln x).
                if (self.foldConst(b2, 0, true)) |k| {
                    try self.b("(", .{});
                    try self.renderVal(a, .real);
                    try self.b(").pow({s})", .{try self.fmtF64(k.f)});
                } else try self.helper2("zPow", a, b2);
            },
            // §4.2.1 conversions
            .if_cast => {
                try self.b("S.con(@as(f64, @floatFromInt(", .{});
                try self.renderVal(a, .int);
                try self.b(")))", .{});
            },
            .fi_cast => {
                try self.b("@as(i64, @intFromFloat(@round((", .{});
                try self.renderVal(a, .real);
                try self.b(").val())))", .{});
            },
            .opt_barrier => try self.renderVal(a, res_ty),
            // §3.2 integer arithmetic (wrapping: an LRM integer is finite width)
            .iadd => try self.intBin(a, "+%", b2),
            .isub => try self.intBin(a, "-%", b2),
            .imul => try self.intBin(a, "*%", b2),
            .idiv => try self.intCall2("@divTrunc", a, b2),
            .imod => try self.intCall2("@rem", a, b2),
            .ineg => {
                try self.b("-%(", .{});
                try self.renderVal(a, .int);
                try self.b(")", .{});
            },
            .iabs => try self.intCall1("zIabs", a),
            .imin => try self.intCall2("@min", a, b2),
            .imax => try self.intCall2("@max", a, b2),
            // §4.2.5/§4.2.7 relational + equality — integer 0/1
            .flt => try self.cmpReal(a, "<", b2),
            .fgt => try self.cmpReal(a, ">", b2),
            .fle => try self.cmpReal(a, "<=", b2),
            .fge => try self.cmpReal(a, ">=", b2),
            .feq => try self.cmpReal(a, "==", b2),
            .fne => try self.cmpReal(a, "!=", b2),
            .ilt => try self.cmpInt(a, "<", b2),
            .igt => try self.cmpInt(a, ">", b2),
            .ile => try self.cmpInt(a, "<=", b2),
            .ige => try self.cmpInt(a, ">=", b2),
            .ieq => try self.cmpInt(a, "==", b2),
            .ine => try self.cmpInt(a, "!=", b2),
            // §4.2.8 logical
            .logand, .logor => {
                try self.b("@as(i64, @intFromBool((", .{});
                try self.renderVal(a, .int);
                try self.b(") != 0 {s} (", .{if (op == .logand) "and" else "or"});
                try self.renderVal(b2, .int);
                try self.b(") != 0))", .{});
            },
            .lognot => {
                try self.b("@as(i64, @intFromBool((", .{});
                try self.renderVal(a, .int);
                try self.b(") == 0))", .{});
            },
            // §4.2.9 bitwise
            .bitand => try self.intBin(a, "&", b2),
            .bitor => try self.intBin(a, "|", b2),
            .bitxor => try self.intBin(a, "^", b2),
            .bitxnor => {
                try self.b("~(", .{});
                try self.intBin(a, "^", b2);
                try self.b(")", .{});
            },
            .bitnot => {
                try self.b("~(", .{});
                try self.renderVal(a, .int);
                try self.b(")", .{});
            },
            // §4.2.11 shifts
            .shl => try self.intCall2Ty("std.math.shl", a, b2),
            // §4.2.11: "Both the << and >> shift operators fill the vacated bit
            // positions with zeroes (0)." A zero fill only means something
            // against a WIDTH, and §3.2.1 fixes the Verilog-A `integer` at 32
            // bits — so `>>` is not `std.math.shr(i64, ...)`, which sign-fills.
            .shr => try self.shrLogical(a, b2),
            .phi, .select, .call, .branch, .jump => unreachable,
        }
    }

    fn method1(self: *Gen, a: Mir.Value, name: []const u8) Error!void {
        try self.b("(", .{});
        try self.renderVal(a, .real);
        try self.b(").{s}()", .{name});
    }

    fn method2(self: *Gen, a: Mir.Value, name: []const u8, b2: Mir.Value) Error!void {
        try self.b("(", .{});
        try self.renderVal(a, .real);
        try self.b(").{s}(", .{name});
        try self.renderVal(b2, .real);
        try self.b(")", .{});
    }

    fn helper1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
        try self.b("{s}(S, ", .{name});
        try self.renderVal(a, .real);
        try self.b(")", .{});
    }

    fn helper2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("{s}(S, ", .{name});
        try self.renderVal(a, .real);
        try self.b(", ", .{});
        try self.renderVal(b2, .real);
        try self.b(")", .{});
    }

    fn intBin(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        try self.b("((", .{});
        try self.renderVal(a, .int);
        try self.b(") {s} (", .{opx});
        try self.renderVal(b2, .int);
        try self.b("))", .{});
    }

    fn intCall1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
        try self.b("{s}(", .{name});
        try self.renderVal(a, .int);
        try self.b(")", .{});
    }

    fn intCall2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("{s}(", .{name});
        try self.renderVal(a, .int);
        try self.b(", ", .{});
        try self.renderVal(b2, .int);
        try self.b(")", .{});
    }

    /// §4.2.11 `>>` — a LOGICAL shift over §3.2.1's 32-bit `integer`.
    ///
    /// Narrow to 32 bits, shift as UNSIGNED so the vacated positions fill with
    /// zeroes, widen back. §4.2.11's own worked example is `3 >> 1` giving
    /// "0011 shifted to the right one position and zero-filled"; the arithmetic
    /// shift this replaced made `-16 >> 2` come out as -4 instead of
    /// 0xFFFFFFF0 >> 2 == 1073741820, i.e. it kept the sign the LRM says to drop.
    ///
    /// `std.math.shr` still does the shifting because it is what defines an
    /// over-wide shift as 0 rather than as UB.
    ///
    /// `<<` is deliberately NOT changed here: it already zero-fills, and making
    /// it wrap at 32 bits is the separate `integer`-width item (the device
    /// codegens `integer` as `i64`, so `1 << 31` does not wrap negative the way
    /// §3.2.1's range requires). Doing half of that here would only make the
    /// constant fold and the runtime disagree.
    fn shrLogical(self: *Gen, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("@as(i64, std.math.shr(u32, @as(u32, @bitCast(@as(i32, @truncate(", .{});
        try self.renderVal(a, .int);
        try self.b(")))), ", .{});
        try self.renderVal(b2, .int);
        try self.b("))", .{});
    }

    fn intCall2Ty(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
        try self.b("{s}(i64, ", .{name});
        try self.renderVal(a, .int);
        try self.b(", ", .{});
        try self.renderVal(b2, .int);
        try self.b(")", .{});
    }

    fn cmpReal(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        try self.b("@as(i64, @intFromBool((", .{});
        try self.renderVal(a, .real);
        try self.b(").val() {s} (", .{opx});
        try self.renderVal(b2, .real);
        try self.b(").val()))", .{});
    }

    fn cmpInt(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
        try self.b("@as(i64, @intFromBool((", .{});
        try self.renderVal(a, .int);
        try self.b(") {s} (", .{opx});
        try self.renderVal(b2, .int);
        try self.b(")))", .{});
    }

    // =======================================================================
    // Calls: §4.5 analog operators, §4.6 noise, ch9 system functions
    // =======================================================================

    /// A plain-f64 expression for an operator CONTROL argument (delay,
    /// transition time, initial condition, …), or null when the argument is not
    /// one the host can evaluate outside the S domain.
    ///
    /// The `Model` struct IS the parameter set, so a control argument that is an
    /// arithmetic expression over parameters is just that expression with
    /// `model.<p>` leaves — `td = len * sqrt(l * c)` renders as
    /// `model.len * @sqrt(model.l * model.c)`. Real models write the delay of a
    /// transmission line that way (lossy_tline.va:135, coupled_tlines.va:110),
    /// and §4.5.7 permits it: `absdelay(input, td [, maxdelay])` gives td as an
    /// `analog_expression`, and with no `maxdelay` "the value of td when the
    /// absdelay() is first evaluated shall be used and any future changes to td
    /// shall be ignored" — which for a parameter expression is every evaluation.
    ///
    /// `foldConst` first at EVERY node, so a subtree of literals still comes out
    /// as one folded number rather than as rendered arithmetic.
    //
    // ponytail: the op set is what a delay/rate/initial-condition expression
    // actually uses — arithmetic, abs, sqrt, min/max, pow. A control argument
    // that wants `exp`/`ln`/`atan2` gets a diagnostic, not silence; add the case
    // when a model asks. Ceiling: unlike `foldConst` this never looks through a
    // parameter's DEFAULT, because the host overrides parameters at run time.
    fn f64Const(self: *Gen, v0: Mir.Value, depth: u32) Error!?[]const u8 {
        if (depth > 32) return null;
        if (self.foldConst(v0, 0, false)) |k| return try self.fmtF64(k.f);
        const v = self.rv(v0);
        switch (self.mir.valueDef(v)) {
            .param_ref => |p| {
                self.uses_model = true;
                return switch (tyOfParam(self.lower.params.items[p].ty)) {
                    .real => try std.fmt.allocPrint(self.arena, "model.{s}", .{self.p_names[p]}),
                    .int => try std.fmt.allocPrint(self.arena, "@as(f64, @floatFromInt(model.{s}))", .{self.p_names[p]}),
                    .str => "0.0",
                };
            },
            .inst_result => |inst| {
                const row = self.mir.instRow(inst);
                switch (Mir.opClass(row.op)) {
                    // Rendered as open/close (and separator) fragments rather
                    // than as a format string per opcode: `allocPrint` wants a
                    // comptime format, and a `{s}`-per-case switch would be the
                    // same table written twice as long.
                    .unary => {
                        const a = try self.f64Const(@enumFromInt(row.a), depth + 1) orelse return null;
                        const fix: [2][]const u8 = switch (row.op) {
                            .fneg, .ineg => .{ "-(", ")" },
                            .fabs, .iabs => .{ "@abs(", ")" },
                            .sqrt => .{ "@sqrt(", ")" },
                            // An int→real widening and a reassociation barrier
                            // are both identities in the f64 domain.
                            .if_cast, .opt_barrier => .{ "", "" },
                            else => return null,
                        };
                        return try std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ fix[0], a, fix[1] });
                    },
                    .binary => {
                        // Integer ops render in the f64 domain like `foldConst`
                        // folds them there; `idiv` is left out because its
                        // truncation is NOT what `/` does on an f64.
                        const fix: [3][]const u8 = switch (row.op) {
                            .fadd, .iadd => .{ "(", ") + (", ")" },
                            .fsub, .isub => .{ "(", ") - (", ")" },
                            .fmul, .imul => .{ "(", ") * (", ")" },
                            .fdiv => .{ "(", ") / (", ")" },
                            .fmin, .imin => .{ "@min(", ", ", ")" },
                            .fmax, .imax => .{ "@max(", ", ", ")" },
                            .pow => .{ "std.math.pow(f64, ", ", ", ")" },
                            else => return null,
                        };
                        const a = try self.f64Const(@enumFromInt(row.a), depth + 1) orelse return null;
                        const b2 = try self.f64Const(@enumFromInt(row.b), depth + 1) orelse return null;
                        return try std.fmt.allocPrint(self.arena, "{s}{s}{s}{s}{s}", .{
                            fix[0], a, fix[1], b2, fix[2],
                        });
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }

    /// `f64Const` for a position where the LRM requires one. A control argument
    /// that does not resolve is a SOURCE-LEVEL diagnostic (E0515) plus a refused
    /// unit — never an `@compileError` string pasted into the generated Zig,
    /// which surfaces as "unreachable code" at a line of generated code with
    /// nothing pointing back at the `.va`.
    fn f64Expr(self: *Gen, v0: Mir.Value) Error![]const u8 {
        if (try self.f64Const(v0, 0)) |s| return s;
        // The argument's own defining expression is the thing to point at; the
        // operator call is the fallback for a leaf with no instruction of its
        // own (a node probe, a phi), which is the common case here.
        const v = self.rv(v0);
        const def = self.mir.valueDef(v);
        const tok = if (def == .inst_result) self.mir.instTok(def.inst_result) else Mir.no_tok;
        if (self.diags) |bag| try bag.add(
            .codegen,
            .E0515,
            self.lower.tokenSpan(if (tok == Mir.no_tok) self.ctrl_tok else tok),
            "this argument is computed during the solve; only literals, parameters " ++
                "and arithmetic over them are available where the host evaluates it",
            .{},
        );
        if (self.fatal == null) self.fatal = "LRM 4.5: an analog operator control argument " ++
            "must be a constant or parameter expression";
        return "0.0";
    }

    fn argF64(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
        if (i >= args.len) return dflt;
        return self.f64Expr(args[i]);
    }

    /// "the signal crossed zero since the last accepted step, in the direction
    /// argument 1 asks for": `+1` rising, `-1` falling, `0` (or absent) either.
    /// §4.5.10 `last_crossing` and §5.10.3 `cross` take the SAME argument with
    /// the same meaning, so they share the test — `last_crossing` used to fire
    /// on any sign change and report a falling edge to a `(V(p), +1)` call.
    ///
    /// The argument is a `constant_expression` in both grammars, so an
    /// unfoldable one is a source error, not a direction; it degrades to
    /// "either", which is the LRM's own default.
    fn crossTest(self: *Gen, n: []const u8, args: []const Mir.Value) Error![]const u8 {
        const dir: i64 = if (self.foldConst(if (args.len > 1) args[1] else .zero, 0, true)) |c|
            @intFromFloat(c.f)
        else
            0;
        return switch (dir) {
            1 => std.fmt.allocPrint(self.arena, "inst.{0s}__prev <= 0.0 and in > 0.0", .{n}),
            -1 => std.fmt.allocPrint(self.arena, "inst.{0s}__prev >= 0.0 and in < 0.0", .{n}),
            else => std.fmt.allocPrint(
                self.arena,
                "(inst.{0s}__prev <= 0.0 and in > 0.0) or (inst.{0s}__prev >= 0.0 and in < 0.0)",
                .{n},
            ),
        };
    }

    /// §5.10 the `held_vars` index a `$held_*` call carries as its only
    /// argument. Always a literal `Lower` emitted, so the fold cannot fail.
    fn heldIdx(self: *const Gen, args: []const Mir.Value) usize {
        const c = self.foldConst(if (args.len != 0) args[0] else .zero, 0, false) orelse return 0;
        const i: usize = @intFromFloat(c.f);
        return @min(i, self.held_names.len -| 1);
    }

    /// System/environment and operator calls. LRM ch9, §4.5, §4.6.
    fn emitCall(self: *Gen, inst: Mir.Inst) Error!void {
        const d = self.mir.instData(inst).call;
        const name = d.name;
        const k = opKind(name);
        if (k != .none) return self.emitOperator(inst, d.args, k);

        // §4.5.13 limexp — user-invoked only; the engine never inserts it.
        if (std.mem.eql(u8, name, "limexp") or std.mem.eql(u8, name, "$limexp"))
            return self.helper1("zLimexp", if (d.args.len > 0) d.args[0] else .f_zero);

        // §4.5.14 ddx(f, V(node)) — the unknown index came through as an int.
        if (std.mem.eql(u8, name, "ddx")) {
            const u = if (d.args.len > 1) self.foldConst(d.args[1], 0, true) else null;
            try self.b("S.con((", .{});
            try self.renderVal(if (d.args.len > 0) d.args[0] else .f_zero, .real);
            try self.b(").ddxAt({d}))", .{if (u) |x| @as(i64, @intFromFloat(x.f)) else 0});
            return;
        }

        // §5.10.2 global events.
        if (std.mem.eql(u8, name, "initial_step") or std.mem.eql(u8, name, "final_step")) {
            self.uses_inst = true;
            const flag = if (name[0] == 'i') "is_initial_step" else "is_final_step";
            try self.b("S.con(if (inst.{s}", .{flag});
            if (d.args.len != 0) {
                try self.b(" and (", .{});
                try self.analysisMatch(d.args);
                try self.b(")", .{});
            }
            try self.b(") 1.0 else 0.0)", .{});
            return;
        }

        // §4.6.1 analysis("dc"|"tran"|…).
        if (std.mem.eql(u8, name, "analysis")) {
            self.uses_inst = true;
            try self.b("S.con(if (", .{});
            try self.analysisMatch(d.args);
            try self.b(") 1.0 else 0.0)", .{});
            return;
        }

        // §4.6.4 noise sources contribute in a small-signal noise analysis only;
        // their residual contribution is identically zero. The generator
        // topology is exported through `noise_gens`.
        const noise = [_][]const u8{ "white_noise", "flicker_noise", "noise_table", "noise_table_log" };
        for (noise) |n| {
            if (std.mem.eql(u8, name, n)) return self.b("S.con(0.0)", .{});
        }
        // §4.6.3 ac_stim is NOT a noise source: it is a small-signal stimulus
        // of a given magnitude and phase in AC analysis. Its residual is zero
        // like a noise source's, but zero alone loses the whole source — and
        // there is no `ac_gens` export to carry it, so a silent zero would
        // hand the host a device that is simply missing its AC drive.
        if (std.mem.eql(u8, name, "ac_stim")) return self.abort(
            "FastVAF does not implement ac_stim() (LRM 4.6.3); the generated " ++
                "device exports no AC stimulus table",
            .{},
        );

        if (name.len != 0 and name[0] == '$') return self.emitSysCall(name, d.args);

        return self.abort("FastVAF: unhandled call `{s}`", .{name});
    }

    fn abort(self: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.fatal == null) self.fatal = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.b("S.con(0.0)", .{});
    }

    /// §4.6.1 the analysis-name arguments are string constants; the comparison
    /// against the runtime pass is what the host answers.
    fn analysisMatch(self: *Gen, args: []const Mir.Value) Error!void {
        var first = true;
        for (args) |a| {
            const def = self.mir.valueDef(self.rv(a));
            if (def != .str_const) continue;
            if (!first) try self.b(" or ", .{});
            first = false;
            const s = def.str_const;
            if (std.mem.eql(u8, s, "static")) {
                // §4.6.1 "static" is true in any analysis that computes a DC
                // operating point.
                try self.b("(inst.analysis_kind == .static or inst.analysis_kind == .ic or " ++
                    "inst.analysis_kind == .nodeset or inst.analysis_kind == .dc)", .{});
            } else if (isAnalysisName(s)) {
                try self.b("inst.analysis_kind == .{s}", .{s});
            } else {
                try self.b("false", .{});
            }
        }
        if (first) try self.b("false", .{});
    }

    fn emitSysCall(self: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
        const eq = std.mem.eql;
        // §9.4/§9.7.3 — only when the caller asked for a printing artifact. In a
        // device they fall through to `void_tasks` below.
        if (self.display == .emit and Lower.isDisplayTask(name))
            return self.emitDisplayTask(name, args);
        // §9.10 environment.
        if (eq(u8, name, "$temperature")) {
            self.uses_inst = true;
            return self.b("S.con(inst.temperature)", .{});
        }
        if (eq(u8, name, "$vt")) {
            // k/q = 8.617333262e-5 V/K (§9.10 $vt = kT/q).
            if (args.len == 0) {
                self.uses_inst = true;
                return self.b("S.con(inst.temperature * 8.617333262145179e-5)", .{});
            }
            try self.b("(", .{});
            try self.renderVal(args[0], .real);
            return self.b(").scale(8.617333262145179e-5)", .{});
        }
        if (eq(u8, name, "$abstime") or eq(u8, name, "$realtime")) {
            self.uses_inst = true;
            return self.b("S.con(inst.abstime)", .{});
        }
        // §5.10 the retained value of an event-assigned variable. `Lower` put
        // this in the entry block in place of the declared initializer, so
        // reading the variable before the event has ever fired reads the
        // `Instance` default and after it the last accepted value.
        if (eq(u8, name, "$held_real") or eq(u8, name, "$held_int")) {
            self.uses_inst = true;
            const f = self.held_names[self.heldIdx(args)];
            return if (eq(u8, name, "$held_int"))
                self.b("inst.{s}", .{f})
            else
                self.b("S.con(inst.{s})", .{f});
        }
        if (eq(u8, name, "$mfactor")) { // §6.3.6
            self.uses_inst = true;
            return self.b("S.con(inst.mfactor)", .{});
        }
        // §9.18 Table 9-29 hierarchical system parameters. Their value is the
        // top-level value combined down the instantiation hierarchy; FastVAF
        // elaborates exactly ONE flat module, so the device IS the top level
        // and the table's "Top-Level Value" column is exact — not a substitute.
        // ($mfactor is the exception above: the host scales the whole stamp by
        // it, so it stays a settable Instance field.)
        if (eq(u8, name, "$xposition") or eq(u8, name, "$yposition"))
            return self.b("S.con(0.0)", .{}); // 0.0 m
        if (eq(u8, name, "$angle"))
            return self.b("S.con(0.0)", .{}); // 0 degrees
        if (eq(u8, name, "$hflip") or eq(u8, name, "$vflip"))
            return self.b("S.con(1.0)", .{}); // +1
        // §9.15 $simparam(name, fallback) — FastVAF answers with the fallback
        // (or a spec-neutral default), which is exactly what the LRM licenses
        // for a simulator that does not expose that parameter.
        if (eq(u8, name, "$simparam")) {
            if (args.len > 1) return self.b("S.con({s})", .{try self.f64Expr(args[1])});
            const nm = self.strArg(args, 0) orelse "";
            const dflt: f64 = if (eq(u8, nm, "gmin")) 1e-12 else if (eq(u8, nm, "tnom")) 300.15 else if (eq(u8, nm, "scale") or eq(u8, nm, "shrink") or eq(u8, nm, "sourceScaleFactor")) 1.0 else 0.0;
            return self.b("S.con({s})", .{try self.fmtF64(dflt)});
        }
        if (eq(u8, name, "$simparam$str")) return self.b("\"\"", .{});
        // §9.19 $param_given / $port_connected.
        if (eq(u8, name, "$param_given")) {
            const def = if (args.len > 0) self.mir.valueDef(self.rv(args[0])) else Mir.Def.undef;
            if (def == .param_ref) {
                self.uses_model = true;
                return self.b("@as(i64, @intFromBool(model.{s}__given))", .{self.p_names[def.param_ref]});
            }
            return self.b("@as(i64, 0)", .{});
        }
        if (eq(u8, name, "$port_connected")) {
            // Every port of an elaborated device instance is connected; an
            // unconnected one is the host's business (§6.5.6).
            return self.b("@as(i64, 1)", .{});
        }
        // §9.20 node aliases: this engine elaborates one flat module, so no net
        // is an alias of another. (Real-typed: that is how lowering types it.)
        if (eq(u8, name, "$analog_node_alias") or eq(u8, name, "$analog_port_alias"))
            return self.b("S.con(0.0)", .{});
        // §9.12 command-line plusargs: absent.
        if (eq(u8, name, "$test$plusargs") or eq(u8, name, "$value$plusargs"))
            return self.b("@as(i64, 0)", .{});
        // §9.22 Tables 9-19/9-20 connectmodule driver & receiver access. These
        // are `connectmodule`-only in the LRM; FastVAF compiles a flat analog
        // device, which HAS no digital drivers or receivers, so the count is
        // exactly 0 and no driver index is in range. Zero is the true answer
        // here, not a substitute — but the call site is nonconforming, hence
        // the acceptance is a snapshot (tests/fixtures/ch09_system_tasks §9.22).
        const driver_queries = [_][]const u8{
            "$driver_count",         "$receiver_count", "$driver_state",
            "$driver_strength",      "$driver_delay",   "$driver_next_state",
            "$driver_next_strength", "$driver_type",
        };
        for (driver_queries) |q| {
            if (eq(u8, name, q)) return self.b("@as(i64, 0)", .{});
        }
        // §4.5.15 $limit: the limiting ALGORITHM is a convergence aid the host
        // owns (contract `limit`); the LRM lets a simulator that does not apply
        // it return the access function unchanged, which is what happens here.
        if (eq(u8, name, "$limit"))
            return self.renderVal(if (args.len > 0) args[0] else .f_zero, .real);
        if (eq(u8, name, "$clog2"))
            return self.intCall1("zClog2", if (args.len > 0) args[0] else .zero);
        // §9.11 conversions.
        if (eq(u8, name, "$rtoi")) {
            try self.b("@as(i64, @intFromFloat(@trunc((", .{});
            try self.renderVal(if (args.len > 0) args[0] else .f_zero, .real);
            return self.b(").val())))", .{});
        }
        if (eq(u8, name, "$itor")) {
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try self.renderVal(if (args.len > 0) args[0] else .zero, .int);
            return self.b(")))", .{});
        }
        // §9.11 Table 9-8 $realtobits/$bitstoreal: the IEEE-754 bit pattern of
        // the real, verbatim. Exactly representable in the i64 that lowering
        // gives integers, so this is the spec function, not an approximation.
        if (eq(u8, name, "$realtobits")) {
            try self.b("@as(i64, @bitCast((", .{});
            try self.renderVal(if (args.len > 0) args[0] else .f_zero, .real);
            return self.b(").val()))", .{});
        }
        if (eq(u8, name, "$bitstoreal")) {
            try self.b("S.con(@as(f64, @bitCast(", .{});
            try self.renderVal(if (args.len > 0) args[0] else .zero, .int);
            return self.b(")))", .{});
        }
        // §9.4/§9.5/§9.7 display, file and control tasks: void. Lowering keeps
        // them as calls; their result is never read, so this only fires if a
        // model assigns one.
        const void_tasks = [_][]const u8{
            "$display",  "$displayb",  "$displayo",      "$displayh",
            "$write",    "$writeb",    "$writeo",        "$writeh",
            "$strobe",   "$strobeb",   "$strobeo",       "$strobeh",
            "$monitor",  "$monitoron", "$monitoroff",    "$debug",
            "$fdisplay", "$fwrite",    "$fstrobe",       "$fmonitor",
            "$fopen",    "$fclose",    "$fflush",        "$fgets",
            "$fscanf",   "$sscanf",    "$swrite",        "$rewind",
            "$fseek",    "$ftell",     "$feof",          "$ferror",
            "$finish",   "$stop",      "$fatal",         "$error",
            "$warning",  "$info",      "$discontinuity", "$bound_step",
        };
        for (void_tasks) |t| {
            if (eq(u8, name, t)) return self.b("S.con(0.0)", .{});
        }
        // IEEE 1364 §17.11 math functions, carried into Verilog-AMS: `$ln`,
        // `$exp`, `$pow`, … are the same functions as their bare spellings.
        const bare = name[1..];
        if (mathOpByName(bare)) |op| {
            if (Mir.opClass(op) == .unary and args.len >= 1) return self.renderOp(op, args[0], .f_zero, .real);
            if (Mir.opClass(op) == .binary and args.len >= 2) return self.renderOp(op, args[0], args[1], .real);
        }
        if (eq(u8, bare, "abs") and args.len >= 1) return self.method1(args[0], "abs");
        if ((eq(u8, bare, "min") or eq(u8, bare, "max")) and args.len >= 2)
            return self.method2(args[0], if (bare[1] == 'i') "min" else "max", args[1]);

        // §9.13 $random and the distributions, §9.21 $table_model, §9.16
        // $simprobe: a silent zero would corrupt the physics, so say so loudly.
        return self.abort("FastVAF does not implement `{s}` (ch9); " ++
            "a substitute value would corrupt the model", .{name});
    }

    fn strArg(self: *const Gen, args: []const Mir.Value, i: usize) ?[]const u8 {
        if (i >= args.len) return null;
        const def = self.mir.valueDef(self.rv(args[i]));
        return if (def == .str_const) def.str_const else null;
    }

    // -------------------------------------------------------- §9.4 display ----
    //
    // A display task is a STATEMENT in the source and a void `call` in the MIR,
    // and codegen renders values, not statements. Rather than grow a statement
    // path for the one construct that needs it, the call renders as a labeled
    // block EXPRESSION whose value is the same `S.con(0.0)` the dropped form
    // produces — the print is the side effect on the way there. It reaches the
    // output because `Lower.finishDisplays` chained it into a live root; see
    // `buildJobs`.

    /// One rendered `std.debug.print` operand: the value and the Zig type the
    /// chosen conversion needs it in. `%h` on a real is a real→integer
    /// conversion (§4.2.1.1), not a reinterpretation, so `want` is not always
    /// the value's own type.
    const PrintArg = struct {
        v: Mir.Value,
        want: VTy,
        /// Render through `zPadInt` into a per-call stack buffer instead of
        /// directly. See `emitDisplayTask` for the one reason this exists.
        pad: bool = false,
    };

    /// Emit one §9.4.1/§9.7.3 task as `std.debug.print`.
    ///
    /// Output goes to stderr, which is where `std.debug.print` writes and where a
    /// simulator's transcript belongs — stdout is for a host that pipes data.
    fn emitDisplayTask(self: *Gen, name: []const u8, args: []const Mir.Value) Error!void {
        // §9.7.3 `$fatal(finish_number, "fmt", …)` puts a non-string first, and
        // §9.4.1 allows `$display` with no format at all. Both fall out of
        // "the format is the first string constant, if there is one".
        var fmt_at: ?usize = null;
        for (args, 0..) |_, i| {
            if (self.strArg(args, i) != null) {
                fmt_at = i;
                break;
            }
        }

        var fmt: std.ArrayList(u8) = .empty;
        var ops: std.ArrayList(PrintArg) = .empty;
        // §9.7.3: the severity is the message's whole reason for existing, and a
        // reader cannot recover it from the text.
        if (severityWord(name)) |word| {
            try fmt.appendSlice(self.arena, word);
            try fmt.appendSlice(self.arena, ": ");
        }
        if (fmt_at) |at| {
            try self.translateFormat(self.strArg(args, at).?, args[at + 1 ..], &fmt, &ops);
        } else {
            // §9.4.3 no format string: each operand in its natural default,
            // separated by a space — with §9.4.1's radix suffix applied.
            const conv: u8 = switch (name[name.len - 1]) {
                'b' => 'b',
                'o' => 'o',
                'h' => 'x',
                else => 0,
            };
            for (args, 0..) |a, i| {
                if (i != 0) try fmt.append(self.arena, ' ');
                try self.appendConv(&fmt, &ops, a, conv, "");
            }
        }
        // §9.4.1: `$write` is the family member that does NOT end the line.
        if (!std.mem.startsWith(u8, name, "$write")) try fmt.append(self.arena, '\n');

        // A width-padded integer is printed through `zPadInt` because Zig's
        // `{d:>5}` writes `+42` where §9.4.3 (and C, and every other Verilog
        // tool) writes ` 42` — std.fmt spells the sign explicitly once a width
        // makes the field fixed. Padding the DECIMAL TEXT instead reproduces the
        // documented behavior, and the scratch it needs is a stack array in the
        // same block as the print.
        try self.b("zd: {{ ", .{});
        for (ops.items, 0..) |p, i| {
            if (p.pad) try self.b("var zb{d}: [24]u8 = undefined; ", .{i});
        }
        try self.b("std.debug.print(\"{f}\", .{{", .{std.zig.fmtString(fmt.items)});
        for (ops.items, 0..) |p, i| {
            if (i != 0) try self.b(", ", .{});
            try self.renderPrintArg(p, i);
        }
        try self.b("}}); break :zd S.con(0.0); }}", .{});
    }

    /// §9.7.3 severity tasks. Null for the §9.4.1 display family.
    fn severityWord(name: []const u8) ?[]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, name, "$fatal")) return "FATAL";
        if (eq(u8, name, "$error")) return "ERROR";
        if (eq(u8, name, "$warning")) return "WARNING";
        if (eq(u8, name, "$info")) return "INFO";
        return null;
    }

    /// §9.4.2/§9.4.3 format string → a Zig one, consuming an operand per
    /// conversion. Literal text is copied through with `{`/`}` doubled, because
    /// it is about to become a `std.fmt` template.
    ///
    /// Unmatched operands (more arguments than conversions) are appended
    /// space-separated in their default form, which is what §9.4.3 says the
    /// display tasks do.
    fn translateFormat(
        self: *Gen,
        src: []const u8,
        operands: []const Mir.Value,
        fmt: *std.ArrayList(u8),
        ops: *std.ArrayList(PrintArg),
    ) Error!void {
        const a = self.arena;
        var next: usize = 0;
        var i: usize = 0;
        while (i < src.len) {
            const c = src[i];
            if (c == '{' or c == '}') { // std.fmt's own escape
                try fmt.append(a, c);
                try fmt.append(a, c);
                i += 1;
                continue;
            }
            if (c != '%') {
                try fmt.append(a, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i >= src.len) break;
            if (src[i] == '%') { // §9.4.3 `%%` is a literal percent
                try fmt.append(a, '%');
                i += 1;
                continue;
            }
            // §9.4.3 `%[-0][width][.precision]conv` — the flags Verilog shares
            // with C. Zig's spec is `[fill][align][width][.precision]`, and its
            // fill/alignment are only meaningful WITH a width, so they are
            // emitted only when one was given.
            var spec: std.ArrayList(u8) = .empty;
            var left = false;
            var zero = false;
            while (i < src.len and (src[i] == '-' or src[i] == '+' or src[i] == ' ' or src[i] == '0')) : (i += 1) {
                if (src[i] == '-') left = true;
                if (src[i] == '0') zero = true;
            }
            const width_at = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            if (i > width_at) {
                if (zero) try spec.append(a, '0');
                try spec.append(a, if (left) '<' else '>');
                try spec.appendSlice(a, src[width_at..i]);
            }
            if (i < src.len and src[i] == '.') {
                try spec.append(a, '.');
                i += 1;
                while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) try spec.append(a, src[i]);
            }
            if (i >= src.len) break;
            const conv = std.ascii.toLower(src[i]);
            i += 1;
            // §9.4.4 `%m` names the enclosing module and consumes no operand.
            if (conv == 'm') {
                try fmt.appendSlice(a, self.mir.name);
                continue;
            }
            const operand = if (next < operands.len) operands[next] else Mir.Value.f_zero;
            next += 1;
            try self.appendConv(fmt, ops, operand, conv, spec.items);
        }
        while (next < operands.len) : (next += 1) {
            try fmt.append(a, ' ');
            try self.appendConv(fmt, ops, operands[next], 0, "");
        }
    }

    /// One conversion: append its `{…}` to `fmt` and its operand to `ops`.
    /// `conv == 0` means "the operand's natural form" (§9.4.3 default).
    fn appendConv(
        self: *Gen,
        fmt: *std.ArrayList(u8),
        ops: *std.ArrayList(PrintArg),
        v: Mir.Value,
        conv: u8,
        spec: []const u8,
    ) Error!void {
        const a = self.arena;
        const ty = self.tyOf(self.rv(v));
        // The Zig verb. `%f` is C's fixed-point default of six decimals; `%g`
        // and `%r` are shortest-round-trip, which is what `{d}` on a float is.
        // §9.4.3's engineering-notation `%r` scale suffix is NOT reproduced.
        const verb: []const u8 = switch (conv) {
            'b' => "b",
            'o' => "o",
            'h', 'x' => "x",
            'c' => "c",
            's' => "s",
            'e' => "e",
            'd', 'f', 'g', 'r', 't', 'u', 'z', 'l', 'v' => "d",
            else => if (ty == .str) "s" else "d",
        };
        // A float has no bit pattern to show in a radix conversion, and Zig's
        // `{x}` on an f64 is a hex FLOAT — not what `%h` asks for. Round it,
        // exactly like §4.2.1.1 does at any other real→integer boundary.
        const as_int = ty != .str and (std.mem.eql(u8, verb, "b") or
            std.mem.eql(u8, verb, "o") or std.mem.eql(u8, verb, "x") or
            std.mem.eql(u8, verb, "c") or conv == 'd');
        // A width (not a bare precision) is what makes std.fmt spell an
        // integer's sign; only then is the detour through `zPadInt` needed, and
        // only for the plain decimal conversion — a radix conversion has no
        // sign to spell.
        const pad = conv == 'd' and spec.len != 0 and spec[spec.len - 1] != '.' and
            std.mem.indexOfAny(u8, spec, "<>") != null;
        try fmt.append(a, '{');
        try fmt.appendSlice(a, if (pad) "s" else verb);
        // `%f`'s six decimals only apply when the source did not say otherwise.
        const default_prec = conv == 'f' and std.mem.indexOfScalar(u8, spec, '.') == null;
        if (spec.len > 0 or default_prec) {
            try fmt.append(a, ':');
            try fmt.appendSlice(a, spec);
            if (default_prec) try fmt.appendSlice(a, ".6");
        }
        try fmt.append(a, '}');
        try ops.append(a, .{ .v = v, .want = if (as_int) .int else ty, .pad = pad });
    }

    /// Render one operand of a `std.debug.print`. The `S` scalar is opaque, so a
    /// real crosses into the format layer through `.val()`; an integer and a
    /// string are already plain Zig values.
    fn renderPrintArg(self: *Gen, p: PrintArg, i: usize) Error!void {
        if (p.pad) {
            try self.b("zPadInt(&zb{d}, ", .{i});
            try self.renderVal(p.v, .int);
            return self.b(")", .{});
        }
        switch (p.want) {
            .real => {
                try self.b("(", .{});
                try self.renderVal(p.v, .real);
                try self.b(").val()", .{});
            },
            .int => try self.renderVal(p.v, .int),
            .str => try self.renderVal(p.v, .str),
        }
    }

    /// §4.5 stateful analog operators. The operator's INPUT is a named unit of
    /// its own, so the state field and `updateState`'s read of the input share
    /// one stable key and adding an unrelated operator renumbers nothing.
    fn emitOperator(self: *Gen, inst: Mir.Inst, args: []const Mir.Value, k: OpKind) Error!void {
        self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
        const unit = self.op_unit[@intFromEnum(inst)];
        if (unit == none_u32) return self.b("S.con(0.0)", .{});
        const n = self.unit_names[unit];
        // Only the operators whose kernel needs the CURRENT input read it; the
        // pure-history ones answer from `Instance` alone. Rendering the input
        // for one of those would set `uses_x`/`uses_model` for text that is
        // never emitted, and `patchParam` would then leave a named parameter
        // nothing references — which Zig rejects.
        const needs_in = opNeedsInput(k);
        // The input is a `Mir.Value` of the body being rendered, not a call to a
        // declaration of its own: `planCommon` makes every operator input a
        // field of the core, so inside the core it is the local that already
        // holds it and inside the §9.4 `display` unit it is a cache read.
        // `callArgIsValue` still returns false for an operator argument — the
        // value is live because it is a core target, not because this call
        // marked it, which is what keeps the §4.5.2 one-evaluation-per-step rule.
        const in = if (needs_in)
            try self.renderToArena(if (args.len == 0) .f_zero else args[0], .real)
        else
            "";
        // `above` is the one operator that now reads NOTHING out of `Instance`:
        // it was `<unit>(S, x, model, inst).val() > 0` and is a bare comparison
        // on the input value.
        if (k != .above) self.uses_inst = true;
        switch (k) {
            // §4.5.11 the cascade reads its sections from Model on every
            // evaluation and is LINEAR in the current input, so the Jacobian
            // `b0/a0` it hands the solver is exact.
            .laplace => {
                const p = try self.filterPlan(inst, args);
                if (p.err) |m| return self.abort("{s}", .{m});
                // `__sec` takes a `*const Model` whatever its coefficients read,
                // so the call site is a use of `model` even when `filterPlan`
                // saw no Model read — without this the enclosing unit's
                // parameter gets patched to `_` and the device does not compile.
                self.uses_model = true;
                try self.b("zLaplace(S, {d}, {d}, {s}, {s}__sec(model), inst.dt, &inst.{s}__u, &inst.{s}__y)", .{
                    p.ns, p.deg, in, n, n, n,
                });
            },
            // §4.5.12 "acts like a simple sample-and-hold which samples every T
            // seconds": between samples the output does not depend on the
            // current unknowns, so it enters the residual as a constant — the
            // same companion model `absdelay` uses.
            .zi => {
                const p = try self.filterPlan(inst, args);
                if (p.err) |m| return self.abort("{s}", .{m});
                try self.b("S.con(inst.{s}__out)", .{n});
            },
            .ddt => try self.b("zDdt(S, {s}, inst.{s}__prev, inst.dt)", .{ in, n }),
            // §4.5.4 `idt(expr, ic, assert)`: "idt() returns the initial
            // conditions during DC and IC analyses, and whenever assert is
            // nonzero. Once assert becomes zero, idt() returns the integral of
            // the argument starting from the last instant where assert was
            // nonzero." The reset is a plain select on the accumulator, which
            // `updateState` holds at `ic` for as long as assert is nonzero.
            .idt => if (args.len >= 3) try self.b(
                "zIdtReset(S, {s}, inst.{s}__acc, inst.dt, {s}, {s})",
                .{ in, n, try self.argF64(args, 1, "0.0"), try self.argF64(args, 2, "0.0") },
            ) else try self.b("zIdt(S, {s}, inst.{s}__acc, inst.dt, {s})", .{
                in, n, try self.argF64(args, 1, "0.0"),
            }),
            .idtmod => try self.b("zIdtmod(S, {s}, inst.{s}__acc, inst.dt, {s}, {s}, {s})", .{
                in,                              n,
                try self.argF64(args, 1, "0.0"), try self.argF64(args, 2, "0.0"),
                try self.argF64(args, 3, "0.0"),
            }),
            .absdelay => try self.b(
                "S.con(zHistAt(&inst.{s}__t, &inst.{s}__v, inst.{s}__head, inst.abstime - ({s})))",
                .{ n, n, n, try self.argF64(args, 1, "0.0") },
            ),
            .transition => try self.b("zTransition(S, {s}, inst.{s}__prev, inst.dt, {s})", .{
                in, n, try self.transitionTau(args),
            }),
            .slew => {
                const r = try self.slewRates(args);
                try self.b("zSlew(S, {s}, inst.{s}__prev, inst.dt, {s}, @abs({s}))", .{
                    in, n, r[0], r[1],
                });
            },
            .last_crossing => try self.b("S.con(inst.{s}__t_last)", .{n}),
            .cross => try self.b("S.con(if (inst.{s}__hit) 1.0 else 0.0)", .{n}),
            .timer => try self.b("S.con(if (inst.{s}__hit) 1.0 else 0.0)", .{n}),
            .above => try self.b("S.con(if (({s}).val() > 0.0) 1.0 else 0.0)", .{in}),
            // §9.17 tasks return no value ("It does not return a value").
            // Unreachable in practice — lowering never leaves one in an eval
            // expression — but a void task read as a value is a zero, not a
            // crash.
            .bound_step, .discontinuity => try self.b("S.con(0.0)", .{}),
            .none => unreachable,
        }
    }

    /// §4.5.8 transition(expr, td, rise, fall): the lag constant that makes the
    /// 10–90 % transit take `rise`/`fall`.
    fn transitionTau(self: *Gen, args: []const Mir.Value) Error![]const u8 {
        const rise = try self.argF64(args, 2, "0.0");
        // §4.5.8: "If only a positive rise_time value is specified, the
        // simulator uses it for both rise and fall times." Defaulting `fall` to
        // 0.0 instead halved the mean, so the 3-argument form transitioned
        // exactly TWICE as fast as the 4-argument form written with the same
        // number — silently, and only for the shorter spelling.
        const fall = try self.argF64(args, 3, rise);
        return std.fmt.allocPrint(self.arena, "(({s}) + ({s})) * 0.5 / 2.2", .{ rise, fall });
    }

    /// §4.5.9's two rate limits, for the two places that emit a `zSlew` call.
    ///
    /// "If the max_neg_slew_rate is not specified, it defaults to the opposite
    /// of the max_pos_slew_rate." The kernel takes `@abs` of the negative limit,
    /// so "the opposite" is spelled by reusing the positive expression verbatim.
    /// The old default of `1e300` left every falling edge UNLIMITED while the
    /// rising edge was held — an asymmetry the source never asked for, and one
    /// that only showed up in a transient.
    fn slewRates(self: *Gen, args: []const Mir.Value) Error![2][]const u8 {
        const pos = try self.argF64(args, 1, "1e300");
        return .{ pos, try self.argF64(args, 2, pos) };
    }

    // =======================================================================
    // §4.5.11 / §4.5.12 filters
    // =======================================================================

    /// One polynomial, ASCENDING powers of `s` (§4.5.11) or `z⁻¹` (§4.5.12),
    /// as emitted expression text — a literal or `model.<p>`, so a model-card
    /// override reaches the coefficient without a rebuild.
    const Poly = []const []const u8;

    /// A filter realised as a CASCADE of sections, `H = ∏ num[i]/den[i]`.
    ///
    /// The root forms (`*_zp`, `*_zd` zeros, `*_np`, `*_zp` poles) stay
    /// FACTORED: one section per real root, one per conjugate pair, each
    /// multiplied out as a REAL quadratic. Expanding ∏(1 − s/ρₖ) into a single
    /// coefficient vector is the Wilkinson operation — for a 6th-order filter
    /// the coefficients span decades and the roots move visibly on the way
    /// back out — so it is never done. Only the coefficient forms (`*_nd`,
    /// `*_zd` denominator, `*_np` numerator) arrive as a polynomial already,
    /// and those stay one direct-form section at their full degree.
    const FilterPlan = struct {
        num: []const Poly = &.{},
        den: []const Poly = &.{},
        /// Sections = max(num.len, den.len); a missing side is the polynomial 1.
        ns: usize = 0,
        /// Highest degree over every section — the shape of the state arrays.
        deg: usize = 0,
        /// Do the coefficients read Model? Decides `__sec`'s parameter name.
        uses_model: bool = false,
        /// §4.5.12 sampling period T. Null for a laplace filter.
        period: ?[]const u8 = null,
        err: ?[]const u8 = null,

        /// Section `i` of one side; a side that ran out of sections is the
        /// polynomial 1, which is how a 3-zero / 1-pole filter still cascades.
        fn poly(self: FilterPlan, numerator: bool, i: usize) Poly {
            const list = if (numerator) self.num else self.den;
            return if (i < list.len) list[i] else &.{"1.0"};
        }
    };

    fn planErr(msg: []const u8) FilterPlan {
        return .{ .err = msg };
    }

    /// Decode one `laplace_*`/`zi_*` call into its cascade. Lowering flattened
    /// each vector argument as `<count>, e0, e1, …` (see `lower.appendVectorArg`),
    /// so the argument list is self-describing.
    fn filterPlan(self: *Gen, inst: Mir.Inst, args: []const Mir.Value) Error!FilterPlan {
        const name = self.mir.instData(inst).call.name;
        const z = std.mem.startsWith(u8, name, "zi_");
        // `*_zp`/`*_zd` give the ZEROS as roots; `*_zp`/`*_np` give the POLES
        // as roots. The two letters after the underscore say which.
        const tail = name[if (z) 3 else 8..];
        const num_roots = tail[0] == 'z';
        const den_roots = tail[1] == 'p';

        const saved = self.uses_model;
        self.uses_model = false;
        defer self.uses_model = saved;

        const nv = self.readVec(args, 1) orelse
            return planErr("LRM 4.5.11/4.5.12: the numerator argument of a filter must be a vector");
        const dv = self.readVec(args, nv.next) orelse
            return planErr("LRM 4.5.11/4.5.12: the denominator argument of a filter must be a vector");

        var num: std.ArrayList(Poly) = .empty;
        var den: std.ArrayList(Poly) = .empty;
        if (try self.filterSide(&num, nv.elems, num_roots, z, false)) |m| return planErr(m);
        if (try self.filterSide(&den, dv.elems, den_roots, z, true)) |m| return planErr(m);

        var p: FilterPlan = .{
            .num = num.items,
            .den = den.items,
            .ns = @max(num.items.len, den.items.len),
            .uses_model = self.uses_model,
        };
        for (0..p.ns) |i| {
            p.deg = @max(p.deg, @max(p.poly(true, i).len, p.poly(false, i).len) - 1);
        }

        if (z) {
            // §4.5.12 "T specifies the period of the filter, is mandatory, and
            // shall be positive."
            if (dv.next >= args.len) return planErr(
                "LRM 4.5.12: the sampling period T of a zi_* filter is mandatory",
            );
            if (self.foldConst(args[dv.next], 0, true)) |c| {
                if (!(c.f > 0.0)) return planErr(
                    "LRM 4.5.12: the sampling period T of a zi_* filter shall be positive",
                );
            }
            p.period = try self.f64Expr(args[dv.next]);
            p.uses_model = self.uses_model;
            // §4.5.12 τ (transition time) and t0 (time of the first
            // transition). Neither is implemented: the emitted output steps
            // abruptly at t0 = 0. A silent τ would be a different waveform, so
            // it is rejected instead of ignored.
            if (dv.next + 1 < args.len) return planErr(
                "FastVAF does not implement the optional τ / t0 arguments of a zi_* filter (LRM 4.5.12)",
            );
        }
        // §4.5.11 the optional ε argument only "deriv[es] an absolute
        // tolerance (if needed)"; FastVAF has no per-signal tolerance table, so
        // dropping it changes no value the device computes.
        return p;
    }

    const Vec = struct { elems: []const Mir.Value, next: usize };

    /// Read one flattened vector argument: a literal count followed by that
    /// many elements. The count is always an `int_const` (lowering emits it);
    /// anything else means this argument was never a vector.
    fn readVec(self: *const Gen, args: []const Mir.Value, i: usize) ?Vec {
        if (i >= args.len) return null;
        const def = self.mir.valueDef(self.rv(args[i]));
        if (def != .int_const or def.int_const < 0) return null;
        const n: usize = @intCast(def.int_const);
        if (i + 1 + n > args.len) return null;
        return .{ .elems = args[i + 1 ..][0..n], .next = i + 1 + n };
    }

    /// Turn one side of a filter into its sections. `roots` selects the
    /// root-vector reading (pairs of real/imaginary parts) over the
    /// coefficient reading. Returns a diagnostic, or null on success.
    fn filterSide(
        self: *Gen,
        out: *std.ArrayList(Poly),
        elems: []const Mir.Value,
        roots: bool,
        z: bool,
        is_den: bool,
    ) Error!?[]const u8 {
        if (elems.len == 0) {
            // "The zeros argument may be represented as a null argument" — no
            // zeros means the numerator polynomial 1. An empty DENOMINATOR has
            // no such reading; it would be a division by nothing.
            if (is_den) return "LRM 4.5.11/4.5.12: the denominator of a filter shall not be empty";
            return null;
        }
        if (!roots) {
            var poly = try self.arena.alloc([]const u8, elems.len);
            var all_zero = true;
            for (elems, 0..) |e, i| {
                poly[i] = try self.f64Expr(e);
                const c = self.foldConst(e, 0, true);
                if (c == null or c.?.f != 0.0) all_zero = false;
            }
            if (is_den and all_zero)
                return "LRM 4.5.11/4.5.12: the denominator coefficients of this filter are identically zero";
            try out.append(self.arena, poly);
            return null;
        }
        // §4.5.11.1 "ζ is a vector of M pairs of real numbers … the first
        // number in the pair is the real part of the zero and the second is
        // the imaginary part."
        if (elems.len % 2 != 0)
            return "LRM 4.5.11/4.5.12: a root vector is a list of (real, imaginary) PAIRS, so its length must be even";
        const m = elems.len / 2;
        const used = try self.arena.alloc(bool, m);
        @memset(used, false);
        for (0..m) |k| {
            if (used[k]) continue;
            used[k] = true;
            // The conjugate PAIRING is structural — it decides how many
            // sections exist and of what degree — so the imaginary part has to
            // be known here. The real part may stay a runtime parameter.
            const im = self.foldConst(elems[2 * k + 1], 0, true) orelse
                return "LRM 4.5.11/4.5.12: the imaginary part of a filter root must be a constant expression " ++
                    "(the conjugate pairing decides the section structure)";
            const re = try self.f64Expr(elems[2 * k]);
            const re_c = self.foldConst(elems[2 * k], 0, true);
            if (im.f == 0.0) {
                // "If a root is zero, then the term associated with it is
                // implemented as s, rather than (1 − s/r)". In z⁻¹ the LRM's
                // own wording says "z", which is a non-causal advance and
                // contradicts its H(z) formula (which is written in z⁻¹
                // throughout); the causal dual of `s` is the unit delay z⁻¹.
                if (re_c != null and re_c.?.f == 0.0) {
                    try out.append(self.arena, &.{ "0.0", "1.0" });
                } else if (z) {
                    // §4.5.12 (1 − z⁻¹ρ)
                    try out.append(self.arena, try self.polyOf(&.{ "1.0", try self.neg(re) }));
                } else {
                    // §4.5.11 (1 − s/ρ). A model card that sets ρ to 0 at run
                    // time divides by zero — the same class of defect as a
                    // zero-valued resistance, and LRM 4.2.4 makes only `%` by
                    // zero an error.
                    try out.append(self.arena, try self.polyOf(&.{
                        "1.0", try std.fmt.allocPrint(self.arena, "-1.0 / ({s})", .{re}),
                    }));
                }
                continue;
            }
            // "If a root is complex, its conjugate shall also be present."
            const j = self.conjugateOf(elems, used, re, im.f) orelse
                return "LRM 4.5.11/4.5.12: a complex filter root has no conjugate partner " ++
                    "(\"If a root is complex, its conjugate shall also be present\")";
            used[j] = true;
            // Multiplied out as a REAL quadratic — never through complex
            // arithmetic, and never by expanding the whole product.
            //   §4.5.11  (1 − s/ρ)(1 − s/ρ*) = 1 − 2a/(a²+b²)·s + 1/(a²+b²)·s²
            //   §4.5.12  (1 − z⁻¹ρ)(1 − z⁻¹ρ*) = 1 − 2a·z⁻¹ + (a²+b²)·z⁻²
            // ponytail: b ≠ 0 here, so a²+b² > 0 and the §4.5.11 divisions are
            // safe for any real part, including a == 0 — which is a pole pair
            // ON the imaginary axis, an UNDAMPED section that rings forever
            // under the trapezoidal rule. That is the transfer function the
            // model asked for, not a defect of this realisation.
            const bb = try self.fmtF64(im.f * im.f);
            const mag = try std.fmt.allocPrint(self.arena, "(({0s}) * ({0s}) + {1s})", .{ re, bb });
            try out.append(self.arena, if (z) try self.polyOf(&.{
                "1.0",
                try std.fmt.allocPrint(self.arena, "-2.0 * ({s})", .{re}),
                mag,
            }) else try self.polyOf(&.{
                "1.0",
                try std.fmt.allocPrint(self.arena, "-2.0 * ({s}) / {s}", .{ re, mag }),
                try std.fmt.allocPrint(self.arena, "1.0 / {s}", .{mag}),
            }));
        }
        return null;
    }

    /// Index of the unused root that is the conjugate of (`re`, `im`): same
    /// real part, negated imaginary part. Real parts are compared as EMITTED
    /// TEXT, so `model.a` pairs with `model.a` without needing its value.
    fn conjugateOf(self: *Gen, elems: []const Mir.Value, used: []const bool, re: []const u8, im: f64) ?usize {
        for (used, 0..) |u, j| {
            if (u) continue;
            const jm = self.foldConst(elems[2 * j + 1], 0, true) orelse continue;
            if (jm.f != -im) continue;
            // `f64Const`, not `f64Expr`: this is a SPECULATIVE render used only
            // to pair roots, so a root that does not resolve is "not the
            // conjugate", not a diagnostic. The real render reports it.
            const jre = (self.f64Const(elems[2 * j], 0) catch continue) orelse continue;
            if (std.mem.eql(u8, jre, re)) return j;
        }
        return null;
    }

    fn polyOf(self: *Gen, items: []const []const u8) Error!Poly {
        return self.arena.dupe([]const u8, items);
    }

    fn neg(self: *Gen, e: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "-({s})", .{e});
    }

    /// `<unit>__sec(model)` — the cascade's CONTINUOUS coefficients, rebuilt
    /// from Model on every call so a model-card override lands without a
    /// recompile. Public because it is also the exact transfer function: a host
    /// doing `.ac`/`.noise` builds `H(jω) = ∏ num_i(jω)/den_i(jω)` from exactly
    /// these numbers, which the real-valued residual cannot carry.
    fn emitFilterSections(self: *Gen, n: []const u8, p: FilterPlan, z: bool) Error!usize {
        const var_name = if (z) "z⁻¹" else "s";
        try self.w(
            "/// §4.5.{s} cascade sections of `{s}`: H = ∏ [i][0]({s}) / [i][1]({s}),\n" ++
                "/// coefficients ascending. Read from Model on every evaluation.\n",
            .{ if (z) "12" else "11", n, var_name, var_name },
        );
        const at_fn = self.out.items.len;
        try self.w("pub fn {s}__sec({s}: *const Model) [{d}][2][{d}]f64 {{\n    return .{{\n", .{
            n, if (p.uses_model) "model" else "_", p.ns, p.deg + 1,
        });
        for (0..p.ns) |i| {
            try self.w("        .{{ ", .{});
            for ([_]bool{ true, false }, 0..) |numerator, s| {
                if (s == 1) try self.w(", ", .{});
                try self.w(".{{ ", .{});
                const poly = p.poly(numerator, i);
                for (0..p.deg + 1) |c| {
                    if (c != 0) try self.w(", ", .{});
                    try self.w("{s}", .{if (c < poly.len) poly[c] else "0.0"});
                }
                try self.w(" }}", .{});
            }
            try self.w(" }},\n", .{});
        }
        try self.w("    }};\n}}\n\n", .{});
        return at_fn;
    }

    // =======================================================================
    // Dispatchers — §5.6 residual assembly, §1.3.1.2 reference directions
    // =======================================================================

    fn emitDispatchers(self: *Gen) Error!void {
        try self.emitResidual(false);
        var any_q = false;
        for (self.lower.contributions.items) |c| {
            if (self.rv(c.react_val) != .f_zero) any_q = true;
        }
        if (any_q) try self.emitResidual(true);
        try self.emitDisplay();
    }

    /// §9.4 the one entry point a host calls to run the module's display tasks.
    ///
    /// Separate from `eval` on purpose. The prints live in a unit of their own,
    /// so a caller decides WHEN text happens instead of getting it once per
    /// Newton iteration as a side effect of the residual — and a device built
    /// with `display == .drop` simply has no such declaration.
    ///
    /// The unit returns an `S` (every unit does); it is the sum of the display
    /// calls' zero results and is discarded here.
    fn emitDisplay(self: *Gen) Error!void {
        if (self.display_name.len == 0) return;
        try self.w(
            \\/// §9.4 run this module's display tasks once, in source order.
            \\pub fn display(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64) void {{
            \\    _ = {s}(S, x, model, inst);
            \\}}
            \\
            \\
        , .{self.display_name});
    }

    fn emitResidual(self: *Gen, react: bool) Error!void {
        self.uses_x = false;
        self.uses_model = false;
        self.uses_inst = false;
        var stamps: u32 = 0;

        // Same reserve-and-backpatch as `emitUnit`. `res` needs a fourth slot:
        // with no stamps nothing assigns to it, and Zig rejects a `var` that is
        // never mutated. Here the shorter spelling is the one that gets padded.
        try self.w("/// {s}\n", .{
            if (react) "§5.6.1.2 reactive residual (charge/flux); the host differentiates it" else "§5.6 resistive residual: KCL at every unknown (§1.3.2)",
        });
        try self.w("pub fn {s}(comptime S: type, ", .{if (react) "q" else "eval"});
        const at_x = self.out.items.len;
        try self.w("x: [n_u]S, ", .{});
        const at_model = self.out.items.len;
        try self.w("model: *const Model, ", .{});
        const at_inst = self.out.items.len;
        try self.w("inst: *const Instance, _: f64) [n_u]S {{\n    ", .{});
        const at_mut = self.out.items.len;
        try self.w("var   res = [_]S{{S.con(0.0)}} ** n_u;\n", .{});
        // ONE core evaluation per residual, not one per contribution. LLVM does
        // not recover this by itself — measured, see `planCommon`'s header — so
        // the number of times the model runs is decided here, in the emitter.
        var opened = false;

        for (self.lower.contributions.items, 0..) |c, i| {
            const val = if (react) self.rv(c.react_val) else self.rv(c.resist_val);
            if (val == .f_zero) continue;
            self.uses_x = true;
            self.uses_model = true;
            self.uses_inst = true;
            if (!opened) {
                opened = true;
                try self.ind(1);
                try self.b("const m = core(S, x, model, inst);\n", .{});
            }
            stamps += 1;
            try self.ind(1);
            try self.b("{{\n", .{});
            try self.ind(2);
            try self.b("const c = m.f{d};\n", .{self.lo_idx[@intFromEnum(val)]});
            if (c.kind == .indirect) {
                // §5.6.7 nullor: `out` is driven by a source whose current is
                // the unknown `ib`, and the row is the CONSTRAINT alone —
                // `<probe> − <equation>`. There is deliberately no V(hi,lo)
                // term: "the source voltage needs to be adjusted so that the
                // given equation is satisfied", so the branch voltage is free.
                // The ib column is filled only by the two KCL stamps, which
                // makes the local 2x2 block off-diagonal — see the note in
                // docs/architecture/05-build-artifact.html.
                const u = self.branch_u[i];
                assert(!react); // splitContribution never runs on an indirect
                try self.ind(2);
                try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.u_names[u]});
                try self.stamp(2, c.hi, "add", "ib");
                try self.stamp(2, c.lo, "sub", "ib");
                try self.ind(2);
                try self.b("res[@intFromEnum(U.{s})] = c;\n", .{self.u_names[u]});
                try self.ind(1);
                try self.b("}}\n", .{});
                continue;
            }
            switch (c.access) {
                .flow => {
                    // §1.3.1.2: the value flows INTO hi and OUT OF lo.
                    try self.stamp(2, c.hi, "add", "c");
                    try self.stamp(2, c.lo, "sub", "c");
                },
                .potential => {
                    // §5.6 branch relation: the branch current is its own
                    // unknown; its row carries V(hi,lo) − <value>.
                    const u = self.branch_u[i];
                    if (!react) {
                        try self.ind(2);
                        try self.b("const ib = x[@intFromEnum(U.{s})];\n", .{self.u_names[u]});
                        try self.stamp(2, c.hi, "add", "ib");
                        try self.stamp(2, c.lo, "sub", "ib");
                        try self.ind(2);
                        try self.b("res[@intFromEnum(U.{s})] = ", .{self.u_names[u]});
                        try self.nodeVoltage(c.hi);
                        try self.b(".sub(", .{});
                        try self.nodeVoltage(c.lo);
                        try self.b(").sub(c);\n", .{});
                    } else {
                        // §5.6.1.2 the reactive part of a branch relation is a
                        // flux: v − dφ/dt = 0 ⇒ q on this row is −φ.
                        try self.ind(2);
                        try self.b("res[@intFromEnum(U.{s})] = c.neg();\n", .{self.u_names[u]});
                    }
                },
            }
            try self.ind(1);
            try self.b("}}\n", .{});
        }

        // §5.4.3 `I(<p>)` = "the flow into a port of a module". By KCL that is
        // exactly what this module has just stamped at p, so the row reuses the
        // accumulation above instead of restating it:
        //
        //     eval:  res[flow(<p>)] = x[flow(<p>)] − res[p]
        //     q:     res[flow(<p>)] =              − res[p]
        //
        // Total residual x − (I_dc + d/dt q_p) = 0, so the REACTIVE half of the
        // port current rides along for free — §5.4.3's own diode example probes
        // a node that carries a `ddt` junction-capacitance contribution, and a
        // DC-only I(<a>) there would be silently wrong in transient.
        //
        // Emitted AFTER the contribution loop because it reads the finished
        // res[p]; that is also why there is no separate summation helper.
        for (self.lower.port_probes.items) |pp| {
            self.uses_x = true;
            stamps += 1;
            try self.ind(1);
            if (react) {
                try self.b("res[@intFromEnum(U.{s})] = res[@intFromEnum(U.{s})].neg();\n", .{
                    self.u_names[pp.u], self.u_names[pp.port],
                });
            } else {
                try self.b("res[@intFromEnum(U.{0s})] = x[@intFromEnum(U.{0s})].sub(res[@intFromEnum(U.{1s})]);\n", .{
                    self.u_names[pp.u], self.u_names[pp.port],
                });
            }
        }

        if (!self.uses_x) self.patchParam(at_x, "x".len);
        if (!self.uses_model) self.patchParam(at_model, "model".len);
        if (!self.uses_inst) self.patchParam(at_inst, "inst".len);
        if (stamps == 0) self.out.items[at_mut..][0.."const".len].* = "const".*;
        try self.w("    return res;\n}}\n\n", .{});
    }

    fn stamp(self: *Gen, depth: u32, node: u16, opx: []const u8, val: []const u8) Error!void {
        if (node == Lower.ground) return; // §1.3.1.1 ground has no equation
        try self.ind(depth);
        try self.b("res[@intFromEnum(U.{0s})] = res[@intFromEnum(U.{0s})].{1s}({2s});\n", .{
            self.u_names[node], opx, val,
        });
    }

    fn nodeVoltage(self: *Gen, node: u16) Error!void {
        if (node == Lower.ground) return self.b("S.con(0.0)", .{});
        try self.b("x[@intFromEnum(U.{s})]", .{self.u_names[node]});
    }

    /// §4.6.4 noise generator topology. The PSD itself is left to the host's
    /// Jacobian-derived fallback.
    // ponytail: no `noisePsd` hook. Emitting one means running a third variant
    // of each unit (white_noise(p) → p) against the plain-f64 scalar `R`; the
    // machinery for that is already here (see `rscalar_txt`), it just needs a
    // per-contribution noise unit.
    fn emitNoiseTable(self: *Gen) Error!void {
        var n: u32 = 0;
        for (self.lower.contributions.items) |c| {
            if (c.noise_kind != null and !(c.hi == Lower.ground and c.lo == Lower.ground)) n += 1;
        }
        if (n == 0) return;
        try self.w("/// §4.6.4 noise sources declared by the model.\npub const noise_gens = [_]contract.NoiseGen(Self){{\n", .{});
        for (self.lower.contributions.items) |c| {
            const kind = c.noise_kind orelse continue;
            if (c.hi == Lower.ground and c.lo == Lower.ground) continue;
            // §1.3.1.1 ground is not an unknown: a to-ground generator is
            // spelled row == col.
            const row = if (c.hi != Lower.ground) c.hi else c.lo;
            const col = if (c.lo != Lower.ground) c.lo else row;
            try self.w("    .{{ .row = @intFromEnum(U.{s}), .col = @intFromEnum(U.{s}), .kind = .{s} }},\n", .{
                self.u_names[row], self.u_names[col], @tagName(kind),
            });
        }
        try self.w("}};\n\n", .{});
    }

    // =======================================================================
    // §4.5.2 the analog-operator state machine
    // =======================================================================

    /// Advance every stateful operator once the step is accepted. State lives in
    /// `Instance` (eval reads it); `State` only carries the bookkeeping the
    /// contract wants in its own struct.
    fn emitStateMachine(self: *Gen) Error!void {
        var uses_dt = false;
        var uses_core = false;
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op) continue;
            const k = opKind(u.target);
            uses_dt = uses_dt or switch (k) {
                .idt, .idtmod, .transition, .slew, .last_crossing, .laplace => true,
                else => false,
            };
            if (!opHasState(k)) continue;
            uses_core = uses_core or self.opInputIdx(@intCast(i)) != none_u32;
        }
        for (self.held_idx) |k| uses_core = uses_core or k != none_u32;
        try self.w(
            \\/// §4.5.2 accepted-step bookkeeping for the analog operators.
            \\pub const State = struct {{
            \\    t_prev: f64 = 0.0,
            \\}};
            \\
            \\pub fn initState(_: *const Model, _: *Instance) State {{
            \\    return .{{}};
            \\}}
            \\
            \\pub fn updateState(model: *const Model, inst: *Instance, x: [n_u]f64, state: *State) contract.UpdateResult {{
            \\    var xr: [n_u]R = undefined;
            \\    for (x, 0..) |xv, i| xr[i] = R.con(xv);
            \\
        , .{});
        // ONE core evaluation for every operator's input, not one per operator:
        // the inputs are fields of the same struct, so the accepted-step sweep
        // costs exactly one model evaluation however many operators there are.
        // `model` is always live because that call reads it. `dt` is not.
        if (uses_core) try self.w("    const m = core(R, xr, model, inst);\n", .{});
        if (uses_dt) try self.w("    const dt = inst.abstime - state.t_prev;\n", .{});
        // §9.17 reset FIRST, unconditionally: a `$bound_step` that only fired on
        // one arm of an `if` last step must not keep bounding this one, and the
        // reset value is also the right answer for a model that never calls the
        // task at all.
        try self.w(
            \\    inst.bound_step = std.math.inf(f64); // §9.17.2
            \\    inst.discontinuity_order = -1; // §9.17.1
            \\
        , .{});
        for (self.units, 0..) |u, i| {
            const k = opKind(u.target);
            if (u.role != .analog_op or !opHasState(k)) continue;
            const n = self.unit_names[i];
            const inst = self.opInstOf(@intCast(i)) orelse continue;
            self.ctrl_tok = self.mir.instTok(inst); // E0515's fallback span
            const args = self.mir.instData(inst).call.args;
            const lo = self.opInputIdx(@intCast(i));
            if (lo == none_u32) {
                try self.w("    {{\n        const in: f64 = 0.0;\n", .{});
            } else {
                try self.w("    {{\n        const in = m.f{d}.v;\n", .{lo});
            }
            switch (k) {
                .ddt => try self.w("        inst.{s}__prev = in;\n", .{n}),
                // §4.5.4 with `assert`: "Once assert becomes zero, idt()
                // returns the integral of the argument starting from the last
                // instant where assert was nonzero" — so while assert is
                // nonzero the accumulator is PINNED at ic, and integration
                // resumes from there.
                .idt => if (args.len >= 3) try self.w(
                    "        inst.{s}__acc = if (({s}) != 0.0) ({s}) else zIdtAcc(in, inst.{s}__acc, dt, {s});\n",
                    .{
                        n,                               try self.argF64(args, 2, "0.0"),
                        try self.argF64(args, 1, "0.0"), n,
                        try self.argF64(args, 1, "0.0"),
                    },
                ) else try self.w("        inst.{s}__acc = zIdtAcc(in, inst.{s}__acc, dt, {s});\n", .{
                    n, n, try self.argF64(args, 1, "0.0"),
                }),
                .idtmod => try self.w("        inst.{s}__acc = zWrap(zIdtAcc(in, inst.{s}__acc, dt, {s}), {s}, {s});\n", .{
                    n,                               n,
                    try self.argF64(args, 1, "0.0"), try self.argF64(args, 2, "0.0"),
                    try self.argF64(args, 3, "0.0"),
                }),
                .absdelay => try self.w("        zHistPush(&inst.{s}__t, &inst.{s}__v, &inst.{s}__head, inst.abstime, in);\n", .{ n, n, n }),
                .transition => try self.w("        inst.{s}__prev = zTransition(R, R.con(in), inst.{s}__prev, dt, {s}).v;\n", .{
                    n, n, try self.transitionTau(args),
                }),
                .slew => {
                    const r = try self.slewRates(args);
                    try self.w("        inst.{s}__prev = zSlew(R, R.con(in), inst.{s}__prev, dt, {s}, @abs({s})).v;\n", .{
                        n, n, r[0], r[1],
                    });
                },
                // §4.5.10 `last_crossing(expr, direction)`. The direction is the
                // SAME closed argument as §5.10.3 `cross`'s — +1 rising, -1
                // falling, 0 either — so it is decoded and honoured the same
                // way; a bare sign change would report a falling edge to a
                // `last_crossing(V(p), +1)`.
                .last_crossing => try self.w(
                    \\        if ({1s}) {{
                    \\            const f = inst.{0s}__prev / (inst.{0s}__prev - in);
                    \\            inst.{0s}__t_last = state.t_prev + f * dt;
                    \\        }}
                    \\        inst.{0s}__prev = in;
                    \\
                , .{ n, try self.crossTest(n, args) }),
                .cross => {
                    // §5.10.3 the direction argument selects rising/falling/both.
                    try self.w("        inst.{0s}__hit = {1s};\n", .{ n, try self.crossTest(n, args) });
                    try self.w("        inst.{s}__prev = in;\n", .{n});
                },
                .timer => try self.w(
                    \\        if (inst.{0s}__next < in) inst.{0s}__next = in;
                    \\        inst.{0s}__hit = inst.abstime >= inst.{0s}__next;
                    \\        if (inst.{0s}__hit) {{
                    \\            const period = {1s};
                    \\            inst.{0s}__next = if (period > 0.0) inst.{0s}__next + period else std.math.inf(f64);
                    \\        }}
                    \\
                , .{ n, try self.argF64(args, 1, "0.0") }),
                // §9.17.2 "the next time step taken is no larger than the
                // smallest $bound_step() argument currently ACTIVE". `in` is
                // already the running minimum over every `$bound_step` that
                // executed (lower.zig accumulates it through the CFG); the
                // `@min` folds it against the §4.5.12 sampling periods, which
                // are equally active and may be written by an earlier block.
                .bound_step => try self.w("        inst.bound_step = @min(inst.bound_step, in);\n", .{}),
                // §9.17.1 same, and `inf` means "no announcement": the degree is
                // a non-negative constant_expression, so a finite `in` is exact.
                .discontinuity => try self.w(
                    "        inst.discontinuity_order = if (std.math.isFinite(in)) @intFromFloat(in) else -1;\n",
                    .{},
                ),
                // §4.5.11 advance the cascade on the accepted solution.
                .laplace => {
                    const p = try self.filterPlan(inst, args);
                    if (p.err == null) try self.w(
                        "        zLaplaceStep({d}, {d}, in, {s}__sec(model), dt, &inst.{s}__u, &inst.{s}__y);\n",
                        .{ p.ns, p.deg, n, n, n },
                    );
                },
                // §4.5.12 the filter runs on ITS OWN timebase: sample when the
                // accepted time reaches the next multiple of T, hold in
                // between. Same shape as the §5.10.3 `timer` block above, and
                // the step bound is what keeps the solver from stepping over a
                // sample and aliasing the filter.
                .zi => {
                    const p = try self.filterPlan(inst, args);
                    if (p.err == null) try self.w(
                        \\        const period = {1s};
                        \\        if (inst.abstime >= inst.{0s}__next) {{
                        \\            inst.{0s}__out = zZiStep({2d}, {3d}, in, {0s}__sec(model), &inst.{0s}__u, &inst.{0s}__y);
                        \\            // ponytail: re-armed from the ACCEPTED time, not `+= T`, so a
                        \\            // step that overshoots cannot leave the clock permanently behind.
                        \\            inst.{0s}__next = inst.abstime + period;
                        \\            inst.discontinuity_order = 0; // §9.17.1 the held output steps
                        \\        }}
                        \\        inst.bound_step = @min(inst.bound_step, period);
                        \\
                    , .{ n, p.period orelse "0.0", p.ns, p.deg });
                },
                .none, .above => {},
            }
            try self.w("    }}\n", .{});
        }
        // §5.10 store every held variable back. HERE and nowhere else: this
        // function runs on the ACCEPTED solution, once per step, exactly like
        // the operator history above — writing it from `eval` would latch a
        // Newton iterate that the solver goes on to throw away.
        for (self.lower.held_vars.items, 0..) |h, i| {
            const k = self.held_idx[i];
            const n = self.held_names[i];
            if (k == none_u32) {
                // The value folded away entirely (never assigned outside the
                // §5.10 body on any reachable path, and the body's value is a
                // literal zero); nothing to carry.
                try self.w("    inst.{s} = 0;\n", .{n});
            } else if (h.ty == .integer) {
                try self.w("    inst.{s} = m.f{d};\n", .{ n, k });
            } else {
                try self.w("    inst.{s} = m.f{d}.v;\n", .{ n, k });
            }
        }
        try self.w(
            \\    state.t_prev = inst.abstime;
            \\    return .ok;
            \\}}
            \\
            \\
        , .{});
    }

    /// §5.10.5 `timer(start_time, period)` — the host's `nextBreakpoint` hook.
    ///
    /// WHY THIS OPERATOR AND NO OTHER. `nextBreakpoint` asks "at what time must
    /// the transient loop PLACE a timepoint", so a discontinuity lands on a step
    /// instead of being smeared across one. Nothing else in Verilog-A says that:
    /// §9.17.2 `$bound_step` bounds step SIZE (a bound, not a location) and
    /// §9.17.1 `$discontinuity` only announces one after the fact. §5.10.5 is the
    /// exact wording — "the timer function schedules an event at `start_time`,
    /// and every `period` after that" — so the fire times ARE the breakpoints.
    ///
    /// The signature `contract.zig` fixes is `fn (*const Model, f64) ?f64`: no
    /// `Instance`, so the live `__next` counter the state machine advances is out
    /// of reach and the schedule has to be RECOMPUTED from `(model, t)`. That is
    /// possible because §4.5.14 makes an analog-operator control argument a
    /// constant or parameter expression, which is exactly what `f64Const`
    /// renders — `model.<p>` leaves and arithmetic over them.
    ///
    /// ALL OR NOTHING. If any one timer's arguments do not render, the whole
    /// function is dropped rather than emitted covering the others. A missing
    /// hook only costs accuracy (the host falls back to LTE step control, as it
    /// does for every device today); a hook that silently reports a SUBSET reads
    /// to the host as "this device wants no other timepoints", which is a claim
    /// this code would not be entitled to make.
    ///
    // ponytail: the §5.10.5 `enable` argument is ignored here — because the
    // `.timer` arm of `updateState` ignores it too, so agreeing with the code
    // that actually raises `__hit` is the property that matters. When `enable`
    // is honoured there, gate it here the same way; an extra breakpoint costs a
    // timepoint, never an answer, so a Model-renderable enable can just AND in.
    fn emitNextBreakpoint(self: *Gen) Error!void {
        if (!self.usesOp(.timer)) return;

        // Render FIRST, emit second: `f64Const` is what sets `uses_model`, and
        // an unused `model` parameter does not compile.
        const saved = self.uses_model;
        defer self.uses_model = saved;
        self.uses_model = false;

        var timers: std.ArrayList([2][]const u8) = .empty;
        for (self.units, 0..) |u, i| {
            if (u.role != .analog_op or opKind(u.target) != .timer) continue;
            const inst = self.opInstOf(@intCast(i)) orelse return;
            const args = self.mir.instData(inst).call.args;
            // No diagnostic: `f64Expr` already fired one for the period if it is
            // unrenderable, and a start_time that is a solved quantity is legal
            // Verilog-A that this hook simply cannot describe.
            const start = try self.f64Const(if (args.len > 0) args[0] else .zero, 0) orelse return;
            const period = try self.f64Const(if (args.len > 1) args[1] else .zero, 0) orelse return;
            try timers.append(self.arena, .{ start, period });
        }
        if (timers.items.len == 0) return;

        try self.w(
            \\/// §5.10.5 the earliest `timer` fire strictly after `t`, so the host
            \\/// puts a timepoint ON the discontinuity instead of across it.
            \\pub fn nextBreakpoint({s}: *const Model, t: f64) ?f64 {{
            \\    var best = std.math.inf(f64);
            \\
        , .{if (self.uses_model) "model" else "_"});
        for (timers.items) |tm|
            try self.w("    if (zNextTimer({s}, {s}, t)) |b| best = @min(best, b);\n", .{ tm[0], tm[1] });
        try self.w(
            \\    return if (best == std.math.inf(f64)) null else best;
            \\}}
            \\
            \\
        , .{});
    }
};

/// LRM Table 4-14/4-15 by name, including the `log10` spelling that the `$`
/// (IEEE 1364 §17.11) form uses. Reuses lowering's tables — one source of truth.
fn mathOpByName(name: []const u8) ?Mir.Opcode {
    if (Lower.unaryMathOp(name)) |op| return op;
    if (Lower.binaryMathOp(name)) |op| return op;
    if (std.mem.eql(u8, name, "log10")) return .log10;
    return null;
}

/// Is argument `i` of this call RENDERED as a value in the calling unit? The
/// others are consumed at codegen time — analysis names (§4.6.1), operator
/// control constants (§4.5), and the operator INPUT, which its own unit
/// recomputes. Keeping this in step with `emitCall` is what stops the slice
/// from declaring a local nothing reads (a hard error in Zig).
/// Is argument `i` of this call an expression the unit has to COMPUTE?
///
/// Most ch9 tasks answer from `Instance` or lower to a constant, so their
/// arguments are dead and slicing them in would emit code nothing reads. The
/// exception is the display family under `display == .emit`: there the operands
/// are the entire point, and forgetting them here renders every one of them as
/// an undefined leaf — which is what `S.con(0.0)` in a print means.
fn callArgIsValue(name: []const u8, i: usize, display: Display) bool {
    if (opKind(name) != .none) return false;
    const eq = std.mem.eql;
    if (display == .emit and Lower.isDisplayTask(name)) return true;
    if (eq(u8, name, "ddx")) return i == 0;
    if (eq(u8, name, "limexp")) return i == 0;
    if (name.len == 0 or name[0] != '$') return false; // events, noise, analysis
    if (eq(u8, name, "$limexp") or eq(u8, name, "$vt") or eq(u8, name, "$limit") or
        eq(u8, name, "$clog2") or eq(u8, name, "$rtoi") or eq(u8, name, "$itor")) return i == 0;
    const bare = name[1..];
    if (mathOpByName(bare) != null) return true;
    if (eq(u8, bare, "abs") or eq(u8, bare, "min") or eq(u8, bare, "max")) return true;
    return false;
}

fn isAnalysisName(s: []const u8) bool {
    const names = [_][]const u8{ "static", "ic", "nodeset", "dc", "tran", "ac", "noise" };
    for (names) |n| {
        if (std.mem.eql(u8, s, n)) return true;
    }
    return false;
}

/// Length of the §4.5.7 absdelay history ring.
// ponytail: fixed 32 samples with linear interpolation. A delay longer than 32
// timesteps degrades to the oldest sample; make it a parameter of the operator
// (or size it from `td / min_step`) if a real model needs more.
const hist_len: usize = 32;

fn unitComment(c: Lower.Contribution, react: bool) []const u8 {
    if (react) return "§5.6.1.2 reactive part (charge/flux; q() differentiates it)";
    if (c.kind == .indirect)
        return "§5.6.7 indirect contribution — the constraint `<probe> − <equation>`";
    return switch (c.access) {
        .flow => "§5.6 flow contribution — current into `hi`, out of `lo` (§1.3.1.2)",
        .potential => "§5.6 potential contribution — the branch constitutive relation",
    };
}

fn tyOfParam(t: @import("ast.zig").Type) VTy {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .int,
        .string => .str,
    };
}

/// ch9 return types — mirrors `Lower.sysFuncTy` (§9.11/§9.12/§9.19/§9.22).
/// Everything else, including every §4.5 operator and §4.6 event, is real:
/// lowering compares an event guard against `0.0`, so it must stay real.
/// MUST agree with `Lower.sysFuncTy`: the two type the same call from opposite
/// sides of the MIR, and a disagreement puts an `S` expression in an `i64` slot,
/// which does not compile.
///
/// §9.11 Table 9-8: `$realtobits` yields the bit PATTERN (an integer),
/// `$bitstoreal` yields the real that pattern stands for. Only the first belongs
/// here — see tests/fixtures/exhaustive/122_bit_conversions.va.
fn callTy(name: []const u8) VTy {
    const ints = [_][]const u8{
        "$param_given",       "$port_connected",
        "$test$plusargs",     "$value$plusargs",
        "$rtoi",              "$clog2",
        "$realtobits",        "$driver_count",
        "$receiver_count",    "$driver_state",
        "$driver_strength",   "$driver_delay",
        "$driver_next_state", "$driver_next_strength",
        "$driver_type",
    };
    for (ints) |i| if (std.mem.eql(u8, name, i)) return .int;
    if (std.mem.eql(u8, name, "$simparam$str")) return .str;
    // §5.10 `Lower.holdSlot`'s synthetic seed. Not a ch9 task and not in
    // `Lower.sysFuncTy`: the callee is chosen by the variable's declared type,
    // so the name IS the type and the two sides agree by construction.
    if (std.mem.eql(u8, name, "$held_int")) return .int;
    return .real;
}

// ===========================================================================
// §4.5 analog operators — which ones own per-instance state
// ===========================================================================

/// Stateful analog operators (§4.5) and monitored events (§5.10.3). MUST agree
/// with `naming.isStatefulAnalogOp`: that predicate decides which calls get a
/// unit, and this one decides which get Instance state — they are the same set.
const OpKind = enum {
    none,
    ddt, // §4.5.3
    idt, // §4.5.4
    idtmod, // §4.5.5
    absdelay, // §4.5.7
    transition, // §4.5.8
    slew, // §4.5.9
    last_crossing, // §4.5.10
    laplace, // §4.5.11
    zi, // §4.5.12
    cross, // §5.10.3
    above, // §5.10.3
    timer, // §5.10.3
    bound_step, // §9.17.2
    discontinuity, // §9.17.1
};

fn opKind(name: []const u8) OpKind {
    const map = std.StaticStringMap(OpKind).initComptime(.{
        .{ "ddt", .ddt },
        .{ "idt", .idt },
        .{ "idtmod", .idtmod },
        .{ "absdelay", .absdelay },
        .{ "transition", .transition },
        .{ "slew", .slew },
        .{ "last_crossing", .last_crossing },
        .{ "laplace_zd", .laplace },
        .{ "laplace_zp", .laplace },
        .{ "laplace_nd", .laplace },
        .{ "laplace_np", .laplace },
        .{ "zi_zd", .zi },
        .{ "zi_zp", .zi },
        .{ "zi_nd", .zi },
        .{ "zi_np", .zi },
        .{ "cross", .cross },
        .{ "above", .above },
        .{ "timer", .timer },
        // §9.17 — both spellings: the MIR callee keeps the `$`, the unit target
        // naming.zig builds does not (see `enumerateUnits`).
        .{ "$bound_step", .bound_step },
        .{ "bound_step", .bound_step },
        .{ "$discontinuity", .discontinuity },
        .{ "discontinuity", .discontinuity },
    });
    return map.get(name) orelse .none;
}

/// Does this operator need `updateState` to advance anything?
fn opHasState(k: OpKind) bool {
    return switch (k) {
        .none, .above => false,
        else => true,
    };
}

/// Does this operator's kernel read the CURRENT input? The pure-history ones
/// answer from `Instance` alone, and rendering an input they never emit would
/// leave the unit claiming a parameter (or a cache) nothing references.
/// `emitOperator` renders `in` exactly for these; `planSlots` has to agree,
/// which is why the set lives here and not in either of them.
fn opNeedsInput(k: OpKind) bool {
    return switch (k) {
        .ddt, .idt, .idtmod, .transition, .slew, .above, .laplace => true,
        else => false,
    };
}

// ===========================================================================
// Fixed emitted text
// ===========================================================================

const header_txt =
    \\// GENERATED BY FastVAF — DO NOT EDIT.
    \\// The model is ONE declaration; its name is the structural key from
    \\// naming.zig, so an unchanged model is byte-identical across rebuilds and
    \\// `zig -fincremental` skips it (docs/architecture/02-incremental.html).
    \\
    \\const std = @import("std");
    \\const contract = @import("contract");
    \\const Self = @This();
    \\
    \\
;

/// LRM Tables 4-14 / 4-15 in VALUE FORM: every function the scalar interface S
/// does not provide natively is composed out of the ones it does, so forward-mode
/// autodiff propagates the ANALYTIC derivative instead of a finite difference.
/// S provides: con addC scale add sub neg mul div exp log sqrt pow(a,f64)
/// sin cos tanh sinh cosh atan abs minC maxC min max val.
///
/// These are FILE-scope helpers, so they run in the default (strict) float
/// mode; `@setFloatMode` is per-unit and does not cross a call. That is the
/// conservative direction — a `.optimized` unit loses fast-math inside a helper,
/// it never gains unsound fast-math.
const math_txt =
    \\// ---- §4.3 math, value form (derivative propagates by composition) ----
    \\
    \\fn zTan(comptime S: type, a: S) S { // §4.3.2 tan = sin/cos
    \\    return a.sin().div(a.cos());
    \\}
    \\fn zLog10(comptime S: type, a: S) S { // §4.3.1 log() is base 10
    \\    return a.log().scale(0.4342944819032518);
    \\}
    \\fn zExpm1(comptime S: type, a: S) S { // §4.3.1
    \\    return a.exp().addC(-1.0);
    \\}
    \\fn zLn1p(comptime S: type, a: S) S { // §4.3.1
    \\    return a.addC(1.0).log();
    \\}
    \\fn zHypot(comptime S: type, a: S, b: S) S { // §4.3.1
    \\    return a.mul(a).add(b.mul(b)).sqrt();
    \\}
    \\fn zAsin(comptime S: type, a: S) S { // §4.3.2 asin = atan(x/sqrt(1-x^2))
    \\    return a.div(a.mul(a).neg().addC(1.0).sqrt()).atan();
    \\}
    \\fn zAcos(comptime S: type, a: S) S { // §4.3.2
    \\    return S.con(1.5707963267948966).sub(zAsin(S, a));
    \\}
    \\fn zAsinh(comptime S: type, a: S) S { // §4.3.2 ln(x + sqrt(x^2+1))
    \\    return a.add(a.mul(a).addC(1.0).sqrt()).log();
    \\}
    \\fn zAcosh(comptime S: type, a: S) S { // §4.3.2 ln(x + sqrt(x^2-1))
    \\    return a.add(a.mul(a).addC(-1.0).sqrt()).log();
    \\}
    \\fn zAtanh(comptime S: type, a: S) S { // §4.3.2 0.5*ln((1+x)/(1-x))
    \\    return a.addC(1.0).div(a.neg().addC(1.0)).log().scale(0.5);
    \\}
    \\fn zAtan2(comptime S: type, y: S, x: S) S { // §4.3.2
    \\    // Value-level branch only: every arm is atan(y/x) plus a CONSTANT, so
    \\    // each arm carries the exact derivative of atan2 on its quadrant.
    \\    const xv = x.val();
    \\    if (xv > 0.0) return y.div(x).atan();
    \\    if (xv < 0.0) {
    \\        const c: f64 = if (y.val() >= 0.0) 3.141592653589793 else -3.141592653589793;
    \\        return y.div(x).atan().addC(c);
    \\    }
    \\    const yv = y.val();
    \\    return S.con(if (yv > 0.0) 1.5707963267948966 else if (yv < 0.0) -1.5707963267948966 else 0.0);
    \\}
    \\fn zFloor(comptime S: type, a: S) S { // §4.3.1 — derivative 0 a.e.
    \\    return S.con(@floor(a.val()));
    \\}
    \\fn zCeil(comptime S: type, a: S) S { // §4.3.1 — derivative 0 a.e.
    \\    return S.con(@ceil(a.val()));
    \\}
    \\fn zFmod(comptime S: type, a: S, b: S) S { // §4.2.4 % keeps the sign of a
    \\    return a.sub(b.scale(@trunc(a.val() / b.val())));
    \\}
    \\fn zPow(comptime S: type, a: S, b: S) S { // §4.3.1 with a non-constant exponent
    \\    return b.mul(a.log()).exp();
    \\}
    \\fn zIabs(a: i64) i64 { // §4.3.1 integer abs
    \\    return if (a < 0) -a else a;
    \\}
    \\fn zClog2(a: i64) i64 { // §9.11 $clog2
    \\    if (a <= 1) return 0;
    \\    const m: u64 = @intCast(a - 1);
    \\    return 64 - @as(i64, @clz(m));
    \\}
    \\fn zStrCmp(a: []const u8, b: []const u8) i64 { // §3.3.1 string relations
    \\    return switch (std.mem.order(u8, a, b)) { .lt => -1, .eq => 0, .gt => 1 };
    \\}
    \\fn zLimexp(comptime S: type, a: S) S { // §4.5.13 — user-invoked ONLY
    \\    const lim = 80.0;
    \\    if (a.val() > lim) return a.addC(1.0 - lim).scale(@exp(lim));
    \\    return a.exp();
    \\}
    \\
    \\
;

/// §4.5.2 the operator kernels. All take the CURRENT (S-valued) operator input
/// plus the accepted state, so the Jacobian of the companion model is analytic.
const ops_txt =
    \\// ---- §4.5 analog operator kernels ----
    \\
    \\fn zDdt(comptime S: type, v: S, prev: f64, dt: f64) S { // §4.5.3
    \\    if (dt <= 0.0) return S.con(0.0); // no time derivative in a static analysis
    \\    return v.addC(-prev).scale(1.0 / dt);
    \\}
    \\fn zIdt(comptime S: type, v: S, acc: f64, dt: f64, ic: f64) S { // §4.5.4
    \\    if (dt <= 0.0) return S.con(ic); // §4.5.4 DC value is the initial condition
    \\    return v.scale(dt).addC(acc);
    \\}
    \\fn zIdtReset(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, assert_: f64) S { // §4.5.4
    \\    // "idt() returns the initial conditions during DC and IC analyses,
    \\    // and whenever assert is nonzero."
    \\    if (assert_ != 0.0) return S.con(ic);
    \\    return zIdt(S, v, acc, dt, ic);
    \\}
    \\fn zIdtAcc(v: f64, acc: f64, dt: f64, ic: f64) f64 {
    \\    if (dt <= 0.0) return ic;
    \\    return acc + v * dt;
    \\}
    \\fn zIdtmod(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, m: f64, o: f64) S { // §4.5.5
    \\    const raw = zIdt(S, v, acc, dt, ic);
    \\    if (!(m > 0.0)) return raw;
    \\    // The wrap subtracts a piecewise-CONSTANT multiple of the modulus, so
    \\    // the derivative of the wrapped integral is the derivative of the raw one.
    \\    return raw.addC(-m * @floor((raw.val() - o) / m));
    \\}
    \\fn zWrap(x: f64, modulus: f64, offset: f64) f64 { // §4.5.5 idtmod
    \\    if (!(modulus > 0.0)) return x;
    \\    return x - modulus * @floor((x - offset) / modulus);
    \\}
    \\fn zSlew(comptime S: type, v: S, prev: f64, dt: f64, rise: f64, fall: f64) S { // §4.5.9
    \\    if (dt <= 0.0) return v;
    \\    return v.minC(prev + rise * dt).maxC(prev - fall * dt);
    \\}
    \\fn zTransition(comptime S: type, v: S, prev: f64, dt: f64, tau: f64) S { // §4.5.8
    \\    // ponytail: first-order lag instead of the exact piecewise-linear ramp
    \\    // (the exact form needs the ramp's start value AND target in state).
    \\    // Same endpoints, same monotonicity, smooth Jacobian.
    \\    if (dt <= 0.0 or tau <= 0.0) return v;
    \\    const k = dt / (tau + dt);
    \\    return v.addC(-prev).scale(k).addC(prev);
    \\}
    \\
;

/// §5.10.5 the `nextBreakpoint` kernel. Its own block, gated on `usesOp(.timer)`
/// like the history and filter kernels, so the 36 foundry models — none of which
/// uses `timer` — keep a byte-identical device.zig (tests/baseline.sh).
const timer_txt =
    \\// ---- §5.10.5 timer breakpoints ----
    \\
    \\/// The next time a `timer(start, period)` fires, STRICTLY after `t`.
    \\/// The only source in Verilog-A that means "put a timepoint here" — see
    \\/// `emitNextBreakpoint`. Must agree exactly with the `.timer` arm of
    \\/// `updateState`, which is the code that actually raises `__hit`.
    \\fn zNextTimer(start: f64, period: f64, t: f64) ?f64 {
    \\    // `updateState` clamps `__next` UP from its 0.0 initialiser, so a start
    \\    // before the origin fires at the origin — already a timepoint.
    \\    const s = @max(start, 0.0);
    \\    if (s > t) return s;
    \\    if (!(period > 0.0)) return null; // one-shot, and its single fire is behind us
    \\    // Fire k is s + k*period. Take the first k past `t`, then repair the
    \\    // two one-ulp outcomes of the division: landing high SKIPS a fire,
    \\    // landing low returns `t` itself and the transient walk stops advancing.
    \\    var n = @floor((t - s) / period) + 1.0;
    \\    if (n > 1.0 and s + (n - 1.0) * period > t) n -= 1.0;
    \\    if (s + n * period <= t) n += 1.0;
    \\    const next = s + n * period;
    \\    // Strictly `> t`, never `>=`: a host that re-asks from the breakpoint it
    \\    // was just handed (analysis/src/tran/matex.zig walks exactly that way)
    \\    // spins forever on an equal answer. When `period` is so small beside `t`
    \\    // that no later time is representable, "no breakpoint" is the honest —
    \\    // and terminating — answer.
    \\    return if (next > t and std.math.isFinite(next)) next else null;
    \\}
    \\
;

/// §4.5.11/§4.5.12 the filter kernels, emitted VERBATIM from `filter_kernels.zig`
/// so the numerics codegen's tests exercise are byte-for-byte the numerics the
/// device runs. Only devices that actually use a filter carry them.
const filt_txt = "// ---- §4.5.11/§4.5.12 filter kernels (src/filter_kernels.zig) ----\n\n" ++
    @embedFile("filter_kernels.zig") ++ "\n";

const hist_txt =
    \\/// §4.5.7 absdelay history: a fixed ring of (t, v) samples, linearly
    \\/// interpolated. A pure delay has no dependence on the CURRENT unknowns, so
    \\/// the delayed value is injected as a constant (derivative 0) — which is the
    \\/// correct companion model for it.
    \\fn zHistAt(ts: []const f64, vs: []const f64, head: u32, t: f64) f64 {
    \\    const n = ts.len;
    \\    var i: usize = 0;
    \\    var newer: usize = (head + n - 1) % n;
    \\    while (i < n) : (i += 1) {
    \\        const older = (newer + n - 1) % n;
    \\        if (ts[older] <= t and t <= ts[newer]) {
    \\            const span = ts[newer] - ts[older];
    \\            if (span <= 0.0) return vs[newer];
    \\            const f = (t - ts[older]) / span;
    \\            return vs[older] + (vs[newer] - vs[older]) * f;
    \\        }
    \\        newer = older;
    \\    }
    \\    return vs[(head + n - 1) % n];
    \\}
    \\fn zHistPush(ts: []f64, vs: []f64, head: *u32, t: f64, v: f64) void {
    \\    ts[head.*] = t;
    \\    vs[head.*] = v;
    \\    head.* = (head.* + 1) % @as(u32, @intCast(ts.len));
    \\}
    \\
;

// ---- the `u/<key>.zig` file-scope prologue (see `Output.prelude`) ----------
//
// A unit file is a separate Zig FILE, so device.zig's file-scope helpers are
// not in its scope and Zig has no textual include. These blocks ALIAS them —
// one declaration for `zig` to analyse, versus one copy per unit if the helper
// text were re-emitted, which would multiply exactly the AstGen + Sema work the
// split exists to remove. `..` is the work_dir: `u/<key>.zig` sits one level
// under `device.zig`, which is the module root.
//
// KEEP IN SYNC with math_txt / ops_txt / hist_txt / filt_txt — the test "every
// emitted helper is aliased into the unit prologue" fails otherwise.

const helpers_head_txt =
    \\// GENERATED BY FastVAF — DO NOT EDIT.
    \\// The §4.3/§4.5 kernels, public so `u/<key>.zig` can alias them. device.zig
    \\// carries the same text privately: it must stay a valid stand-alone device.
    \\const std = @import("std");
    \\
    \\
;

const prelude_head_txt =
    \\// GENERATED BY FastVAF — DO NOT EDIT.
    \\const std = @import("std");
    \\const contract = @import("contract");
    \\const dev = @import("../device.zig");
    \\const h = @import("../h.zig");
    \\const U = dev.U;
    \\const Model = dev.Model;
    \\const Instance = dev.Instance;
    \\const AnalysisKind = dev.AnalysisKind;
    \\const n_u = contract.nU(dev);
    \\
;

const prelude_math_txt =
    \\const zTan = h.zTan;
    \\const zLog10 = h.zLog10;
    \\const zExpm1 = h.zExpm1;
    \\const zLn1p = h.zLn1p;
    \\const zHypot = h.zHypot;
    \\const zAsin = h.zAsin;
    \\const zAcos = h.zAcos;
    \\const zAsinh = h.zAsinh;
    \\const zAcosh = h.zAcosh;
    \\const zAtanh = h.zAtanh;
    \\const zAtan2 = h.zAtan2;
    \\const zFloor = h.zFloor;
    \\const zCeil = h.zCeil;
    \\const zFmod = h.zFmod;
    \\const zPow = h.zPow;
    \\const zIabs = h.zIabs;
    \\const zClog2 = h.zClog2;
    \\const zStrCmp = h.zStrCmp;
    \\const zLimexp = h.zLimexp;
    \\const zDdt = h.zDdt;
    \\const zIdt = h.zIdt;
    \\const zIdtReset = h.zIdtReset;
    \\const zIdtAcc = h.zIdtAcc;
    \\const zIdtmod = h.zIdtmod;
    \\const zWrap = h.zWrap;
    \\const zSlew = h.zSlew;
    \\const zTransition = h.zTransition;
    \\
;

const prelude_timer_txt =
    \\const zNextTimer = h.zNextTimer;
    \\
;

const prelude_hist_txt =
    \\const zHistAt = h.zHistAt;
    \\const zHistPush = h.zHistPush;
    \\
;

const prelude_filt_txt =
    \\const zBilin = h.zBilin;
    \\const zSec = h.zSec;
    \\const zSecR = h.zSecR;
    \\const zPush = h.zPush;
    \\const zLaplace = h.zLaplace;
    \\const zLaplaceStep = h.zLaplaceStep;
    \\const zZiStep = h.zZiStep;
    \\
;

/// Plain-f64 instantiation of the scalar interface. `updateState` has to run a
/// unit body on the accepted solution, where derivatives are meaningless.
/// §9.4.3 support, emitted ONLY into the printing artifact (`display == .emit`).
///
/// `std.fmt` writes `+42` for `{d:>5}`: once a width fixes the field, it spells
/// the sign. §9.4.3 — and C's `%5d`, and every other Verilog tool — writes
/// ` 42`. Padding the rendered DECIMAL rather than the integer gets that back,
/// and `{s:>5}` has no opinion about signs.
///
// ponytail: 24 bytes is i64's widest decimal (20 chars) plus slack, so the
// `catch unreachable` cannot fire. Zero-padding a NEGATIVE number still yields
// `00-42` where C yields `-0042`; nothing in the corpus writes `%05d` on a
// negative, and fixing it means reimplementing the sign placement here.
const display_txt =
    \\fn zPadInt(buf: []u8, v: i64) []const u8 { // §9.4.3 %<width>d
    \\    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
    \\}
    \\
;

const rscalar_txt =
    \\/// Value-only scalar: `updateState` runs unit bodies on the accepted
    \\/// solution, where no derivative is wanted.
    \\const R = struct {
    \\    v: f64,
    \\    const T = @This();
    \\    pub fn con(c: f64) T { return .{ .v = c }; }
    \\    pub fn val(a: T) f64 { return a.v; }
    \\    pub fn ddxAt(_: T, _: usize) f64 { return 0.0; }
    \\    pub fn add(a: T, b: T) T { return .{ .v = a.v + b.v }; }
    \\    pub fn sub(a: T, b: T) T { return .{ .v = a.v - b.v }; }
    \\    pub fn neg(a: T) T { return .{ .v = -a.v }; }
    \\    pub fn mul(a: T, b: T) T { return .{ .v = a.v * b.v }; }
    \\    pub fn div(a: T, b: T) T { return .{ .v = a.v / b.v }; }
    \\    pub fn scale(a: T, c: f64) T { return .{ .v = a.v * c }; }
    \\    pub fn addC(a: T, c: f64) T { return .{ .v = a.v + c }; }
    \\    pub fn exp(a: T) T { return .{ .v = @exp(a.v) }; }
    \\    pub fn log(a: T) T { return .{ .v = @log(a.v) }; }
    \\    pub fn sqrt(a: T) T { return .{ .v = @sqrt(a.v) }; }
    \\    pub fn sin(a: T) T { return .{ .v = @sin(a.v) }; }
    \\    pub fn cos(a: T) T { return .{ .v = @cos(a.v) }; }
    \\    pub fn tanh(a: T) T { return .{ .v = std.math.tanh(a.v) }; }
    \\    pub fn sinh(a: T) T { return .{ .v = std.math.sinh(a.v) }; }
    \\    pub fn cosh(a: T) T { return .{ .v = std.math.cosh(a.v) }; }
    \\    pub fn atan(a: T) T { return .{ .v = std.math.atan(a.v) }; }
    \\    pub fn abs(a: T) T { return .{ .v = @abs(a.v) }; }
    \\    pub fn minC(a: T, c: f64) T { return .{ .v = @min(a.v, c) }; }
    \\    pub fn maxC(a: T, c: f64) T { return .{ .v = @max(a.v, c) }; }
    \\    pub fn min(a: T, b: T) T { return .{ .v = @min(a.v, b.v) }; }
    \\    pub fn max(a: T, b: T) T { return .{ .v = @max(a.v, b.v) }; }
    \\    pub fn pow(a: T, c: f64) T { return .{ .v = std.math.pow(f64, a.v, c) }; }
    \\};
    \\
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Ast = @import("ast.zig");
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
        // One diagnostic bag threaded through every stage (src/diag.zig).
        out.bag = diag.Bag.init(arena);
        const text = try Preprocessor.process(arena, src, .{ .bag = &out.bag });
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        out.file = try p.parseSourceFile();
        out.low = Lower.init(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag);
        try out.low.lowerFile();
    }

    fn gen(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        return (try self.genOut(gpa)).text;
    }

    /// Same, with §9.4 display tasks emitted — the printing artifact.
    fn genDisplay(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        const v = try proof.prove(gpa, &self.mir, &self.low, &self.bag);
        defer v.deinit(gpa);
        var fatal = false;
        const a = self.arena_state.allocator();
        return (try generate(a, a, &self.mir, &self.low, v, &fatal, .{ .display = .emit })).text;
    }

    fn genOut(self: *Harness, gpa: std.mem.Allocator) !Output {
        const v = try proof.prove(gpa, &self.mir, &self.low, &self.bag);
        defer v.deinit(gpa);
        var fatal = false;
        // ponytail: the harness hands `generate` its arena as the output gpa, so
        // `deinit` reclaims the result with everything else and no test needs a
        // matching free. Ceiling: these fixtures are kilobytes; the arena regrow
        // cost `generate`'s gpa parameter exists to avoid only bites at MB scale.
        const a = self.arena_state.allocator();
        // The harness bag is arena-lived and never detached, so unlike the
        // driver's it is still the right one to hand codegen.
        return generate(a, a, &self.mir, &self.low, v, &fatal, .{ .diags = &self.bag });
    }

    fn deinit(self: *Harness) void {
        self.low.deinit();
        self.arena_state.deinit();
    }
};

const resistor_va =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "codegen: one stably-named declaration for the model, thin dispatcher" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, src, "pub const U = enum(u8) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "r: f64 = 1000.0,") != null);
    // The declaration name is naming.zig's structural key, and it is NOT a MIR
    // index. Since the merge there is ONE of them per model: the per-contribution
    // keys still exist (naming.zig, proof.zig, the `Instance` state fields) but
    // no longer name a declaration.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn res__common__core(comptime S: type,") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const m = core(S, x, model, inst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "contract.validate(Self)") != null);
    // no reactive part ⇒ no q()
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
    // NEVER a global MIR value index in a name
    try std.testing.expect(std.mem.indexOf(u8, src, "v12") == null);
}

const shared_va =
    \\module sh(p, n);
    \\  inout p, n;
    \\  electrical p, n, m;
    \\  parameter real r = 1000.0 from (0:inf);
    \\  real g;
    \\  analog begin
    \\    g = exp(V(p, n) / r) * V(p, m);
    \\    I(p, m) <+ g * 2.0;
    \\    I(m, n) <+ g * 3.0;
    \\  end
    \\endmodule
;

test "codegen: two contributions sharing a subexpression evaluate it ONCE" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, shared_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // One declaration, named structurally — no MIR index anywhere in it.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn sh__common__core(comptime S: type,") != null);
    // ONE call for the whole residual, not one per contribution. This is the
    // runtime half of the merge: LLVM does not CSE repeated calls to a body of
    // this size (measured — see `planCommon`), so the count here IS the number
    // of times the model runs per Newton iteration.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, src, "const m = core(S, x, model, inst);"),
    );
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    // The costly part — `exp` — is emitted once. That is the whole scaling
    // defect. Counted past the file-scope helpers, several of which spell
    // `.exp()` themselves.
    const decls = src[std.mem.indexOf(u8, src, "// ---- the model, in one declaration ----").?..];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, decls, ".exp()"));

    // §4.3: `exp` of an unbounded probe is not provably finite, so both units
    // are `.strict` and the declaration they share must be too — compiling it
    // `.optimized` would assert `ninf` on behalf of a unit that never had it.
    const at = std.mem.indexOf(u8, src, "fn sh__common__core").?;
    try std.testing.expect(std.mem.indexOf(u8, src[at..], "@setFloatMode(.strict);") != null);
}

test "codegen: one declaration even for a single contribution" {
    // No threshold. A model with one contribution gets the same shape as a model
    // with fifty, because the shape is not an optimisation any more — `eval`
    // reads its targets out of one struct and there is nothing to opt out of.
    // The extra call is free: a one-contribution core is small enough for LLVM
    // to inline, which is exactly what it will not do for a 60 000-line one.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "fn res__common__core(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, src, "= core(S, x, model, inst);"));
}

test "codegen: the unit ranges tile the emission and each names its own decl" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  parameter real c = 1e-12;
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(p, n) <+ ddt(c * V(p, n));
        \\    V(p, n) <+ laplace_nd(V(p, n), {1.0}, {1.0, 1.0});
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const o = try h.genOut(std.testing.allocator);

    // The merged core and the §4.5.11 `__sec` coefficient reader derived from
    // the laplace operator — every shape `emitUnits` can still produce for a
    // model with no §9.4 display unit.
    try std.testing.expectEqual(@as(usize, 2), o.names.len);
    for (o.names, o.unit_lo, o.unit_hi, 0..) |name, lo, hi, i| {
        // Tiling — `Output`'s invariant, and what lets the writer rebuild
        // device.zig as prologue ++ imports ++ tail with nothing dropped.
        if (i != 0) try std.testing.expectEqual(o.unit_hi[i - 1], lo);
        const decl = try std.fmt.allocPrint(std.testing.allocator, "fn {s}(", .{name});
        defer std.testing.allocator.free(decl);
        // The range holds the declaration it is named for, and `unit_fn` points
        // at that declaration's keyword — where the writer splices `pub `,
        // without which `@import("u/<key>.zig").<key>` does not resolve.
        try std.testing.expect(std.mem.indexOf(u8, o.text[lo..hi], decl) != null);
        try std.testing.expect(lo <= o.unit_fn[i] and o.unit_fn[i] < hi);
        const at = o.text[o.unit_fn[i]..];
        try std.testing.expect(std.mem.startsWith(u8, at, decl) or std.mem.startsWith(u8, at, "pub fn "));
    }
    // The tail after the last unit is the dispatcher, not more units.
    try std.testing.expect(std.mem.indexOf(u8, o.text[o.unit_hi[o.unit_hi.len - 1]..], "pub fn eval(") != null);
    // The prologue before the first unit carries the types a unit file aliases.
    try std.testing.expect(std.mem.indexOf(u8, o.text[0..o.unit_lo[0]], "pub const Model = struct {") != null);
}

test "codegen: every emitted helper is aliased into the unit prologue" {
    // A `u/<key>.zig` can only name what `Output.prelude` aliases. If a helper
    // is added to math_txt/ops_txt/hist_txt/filt_txt and not to the prologue,
    // the split tree stops compiling — but only for the models that happen to
    // use it, which is the worst possible failure mode. Catch it here instead.
    const prelude = prelude_head_txt ++ prelude_math_txt ++ prelude_timer_txt ++
        prelude_hist_txt ++ prelude_filt_txt ++ "const R = h.R;\n";
    inline for (.{ math_txt, ops_txt, timer_txt, hist_txt, filt_txt }) |src| {
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, "fn z") and !std.mem.startsWith(u8, line, "pub fn z")) continue;
            const rest = line[if (std.mem.startsWith(u8, line, "pub ")) "pub fn ".len else "fn ".len..];
            const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '(') orelse continue];
            const alias = try std.fmt.allocPrint(std.testing.allocator, "const {s} = h.{s};\n", .{ name, name });
            defer std.testing.allocator.free(alias);
            if (std.mem.indexOf(u8, prelude, alias) == null) {
                std.debug.print("helper `{s}` is emitted but not aliased in the unit prologue\n", .{name});
                return error.MissingPreludeAlias;
            }
        }
    }
}

test "codegen: identical MIR yields a byte-identical file (determinism)" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h2);
    defer h2.deinit();
    try std.testing.expectEqualStrings(try h1.gen(std.testing.allocator), try h2.gen(std.testing.allocator));
}

test "codegen: adding a contribution appends to the core, it does not renumber" {
    var h1: Harness = undefined;
    try Harness.run(std.testing.allocator, resistor_va, &h1);
    defer h1.deinit();
    var h2: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n, m;
        \\  parameter real r = 1000.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ V(p, n) / r;
        \\    I(m, n) <+ V(m, n) / r;
        \\  end
        \\endmodule
    , &h2);
    defer h2.deinit();

    const a = try h1.gen(std.testing.allocator);
    const b2 = try h2.gen(std.testing.allocator);
    // The first contribution is still `f0` and `eval` still stamps it from
    // `m.f0`. That is what `planCommon`'s job-order numbering buys: the field
    // index of an existing target is insert-tolerant in the same sense
    // naming.zig makes a declaration name insert-tolerant, so `zig`'s
    // `TrackedInst` for the dispatcher does not churn on an unrelated edit.
    try std.testing.expect(std.mem.indexOf(u8, a, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, b2, "const c = m.f0;") != null);
    const ka = a[std.mem.indexOf(u8, a, "pub fn eval(").?..];
    const kb = b2[std.mem.indexOf(u8, b2, "pub fn eval(").?..];
    const na = std.mem.indexOf(u8, ka, "    }\n").? + 6;
    const nb = std.mem.indexOf(u8, kb, "    }\n").? + 6;
    try std.testing.expectEqualStrings(ka[0..na], kb[0..nb]);
}

test "codegen: §5.6.1.2 reactive split emits q(), §4.2.12 select stays lazy" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module cap(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real c = 1e-12 from (0:inf);
        \\  parameter real vmin = 1.0 from (0:inf);
        \\  analog begin
        \\    I(p, n) <+ c * ddt(V(p, n));
        \\    I(p, n) <+ V(p, n) > vmin ? ln(V(p, n)) : 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(comptime S: type") != null);
    // The reactive half is a SECOND field of the same core, reached by `q` —
    // the split survives the merge as two targets, not two declarations.
    try std.testing.expect(std.mem.indexOf(u8, src, "fn cap__common__core(") != null);
    // §4.2.12 laziness (proof.zig's CODEGEN OBLIGATION): the `ln` must sit
    // INSIDE the if-arm, never in a preceding `const`.
    const unit = src[std.mem.indexOf(u8, src, "fn cap__common__core(").?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    const sel = std.mem.indexOf(u8, body, "(if (").?;
    const lg = std.mem.indexOf(u8, body, ".log()").?;
    try std.testing.expect(lg > sel);
}

test "codegen: §5.8 control flow reconstructs into structured Zig" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module sw(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real ron = 1.0 from (0:inf);
        \\  parameter real roff = 1e9 from (0:inf);
        \\  analog begin
        \\    real g;
        \\    g = 0.0;
        \\    if (V(p, n) > 0.5) g = 1.0 / ron; else g = 1.0 / roff;
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "if (") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "} else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "break :B") != null);
}

test "codegen: a §5.6 potential contribution gets its own branch-current unknown" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module vs(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real dc = 1.0;
        \\  analog V(p, n) <+ dc;
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // lowering only allocates `flow(a,b)` where the model PROBES I(a,b), so
    // codegen appends the unknown AFTER node_order — existing indices hold.
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const u_kinds") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, ".sub(c);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
}

test "codegen: §5.6.7 indirect contribution is a nullor row, ASYMMETRIC-safe" {
    var h: Harness = undefined;
    // Deliberately asymmetric: probe − equation = V(pin,nin) − 2*V(out).
    // The mirrored row (equation − probe) is invisible on the textbook opamp
    // (`V(pin,nin) == 0`), so the fixture that pins the sign has to be one
    // whose two sides differ.
    try Harness.run(std.testing.allocator,
        \\module amp(out, pin, nin);
        \\  inout out, pin, nin;
        \\  electrical out, pin, nin;
        \\  analog V(out) : V(pin, nin) == 2.0 * V(out);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The source current is a solver unknown; the KCL stamps are its only
    // occurrence outside its own row (a nullor).
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28outZ2cgndZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "res[@intFromEnum(U.flowZ28outZ2cgndZ29)] = c;\n") != null);
    // ... and NOT the direct-contribution row `V(hi,lo) − c`.
    try std.testing.expect(std.mem.indexOf(u8, src, ".sub(c);") == null);

    // THE trap: the row must be a function of `x`, or the host's dual-number
    // Jacobian has a zero column and Newton can never move the source.
    const key = "fn amp__common__core(comptime S: type, x: [n_u]S";
    try std.testing.expect(std.mem.indexOf(u8, src, key) != null);
    const unit = src[std.mem.indexOf(u8, src, key).?..];
    const body = unit[0..std.mem.indexOf(u8, unit, "\n}\n").?];
    // probe − equation, in that order.
    const probe_at = std.mem.indexOf(u8, body, "U.pin").?;
    const eqn_at = std.mem.indexOf(u8, body, "S.con(2.0)").?;
    try std.testing.expect(std.mem.indexOf(u8, body, ".sub(") != null);
    try std.testing.expect(probe_at < eqn_at);
}

test "codegen: §5.6.7.1 two indirect contributions to one branch get one source each" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module two(p, n, c1, c2);
        \\  inout p, n, c1, c2;
        \\  electrical p, n, c1, c2;
        \\  analog begin
        \\    V(p, n) : V(c1) == V(p, n);
        \\    V(p, n) : V(c2) == 2.0 * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    // Two sources ⇒ two currents ⇒ two DISTINCT U members (a shared name would
    // be a duplicate enum field, which the Zig parser cannot catch).
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28pZ2cnZ29Z231, // branch flow") != null);
    // Two targets ⇒ two distinct core fields ⇒ two rows in `eval`. (The
    // group-local ordinal naming.zig gives the second unit is still what keys
    // its §4.5 state and proof.zig's verdict; it just no longer names a decl.)
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const c = m.f1;") != null);
}

test "codegen: §5.10.5 only a `timer` module gets a nextBreakpoint hook" {
    // The hook is OPTIONAL in modules/devices/src/contract.zig, and emitting it
    // for a module with no timer would claim a schedule that does not exist —
    // the host reads "no breakpoints ever" and stops asking. `transition` is the
    // trap case: it is stateful and discontinuity-adjacent, but nothing about it
    // says WHERE a timepoint goes, only how fast the value moves.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "nextBreakpoint") == null);
}

test "codegen: §5.10.5 a timer whose start is a solved quantity emits NO hook" {
    // `nextBreakpoint` gets `*const Model` and no `Instance`, so the schedule
    // has to be a function of the parameters. A start_time read off the solution
    // is not, and there is no honest answer to give — a guessed one either hangs
    // the transient walk (an answer at or before `t`) or moves an edge. Silence
    // degrades to LTE step control, which is where every device is today.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer fired;
        \\  analog begin
        \\    @(timer(V(p, n), 1e-9)) fired = fired + 1;
        \\    I(p, n) <+ fired;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "__hit") != null); // the timer IS compiled
    try std.testing.expect(std.mem.indexOf(u8, src, "nextBreakpoint") == null);
}

test "codegen: §4.5 operator state is keyed to the stable unit id" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tr(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real td = 1e-9 from (0:inf);
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, td, td);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "tr__analog_op__transition__prev: f64 = 0.0") != null);
    // The operator's INPUT is a core field now, not a declaration of its own —
    // but the state field, and therefore `naming.zig`'s key, is untouched.
    try std.testing.expect(std.mem.indexOf(u8, src, "zTransition(S, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "const m = core(R, xr, model, inst);") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const State = struct {") != null);
}

test "codegen: §4.5.11 laplace_nd emits a real filter, not a compile error" {
    // Was: asserted laplace was a LOUD @compileError. It is now implemented,
    // so the assertion is inverted — a stateful filter unit must be emitted.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module lp(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ laplace_nd(V(p, n), {1.0}, {1.0, 1.0});
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "laplace_nd") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn updateState(") != null);
    // The cascade's `__sec(model)` call is the ONLY Model read in this module,
    // so the unit's parameter must stay NAMED. Was patched to `_`, which made
    // every filter-in-a-contribution device fail to compile on `model`.
    try std.testing.expect(std.mem.indexOf(u8, src, "__sec(model)") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "core(comptime S: type, x: [n_u]S, model: *const Model") != null);
}

test "codegen: a non-const analog-operator control argument is a LOUD compile error" {
    // The invariant the previous test really guarded: unsupported constructs
    // must be loud, never a silent substitute value (a silent 0 corrupts the
    // device residual). §4.5.14 requires control arguments to be constant.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tv(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog I(p, n) <+ transition(V(p, n), 0.0, V(p, n), 1e-9);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") != null);
}

test "codegen: §5.4.3 I(<p>) is a solver unknown pinned to the KCL sum at p" {
    var h: Harness = undefined;
    // §5.4.3's own diode example shape: the probed port also carries a `ddt`
    // contribution, so a DC-only port current would be silently wrong in tran.
    try Harness.run(std.testing.allocator,
        \\module d(a, c);
        \\  inout a, c;
        \\  electrical a, c;
        \\  parameter real cj = 1e-12;
        \\  real m;
        \\  analog begin
        \\    I(a, c) <+ 1e-3 * V(a, c) + ddt(cj * V(a, c));
        \\    m = I(<a>);
        \\    I(a, c) <+ 1e-9 * m;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // Its own unknown, appended after the ports so `num_ports` is untouched,
    // and classified a CURRENT by the existing `flow(` predicate.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub const num_ports: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28Z3caZ3eZ29, // branch flow") != null);

    // SIGN: `I(p,n) <+ c` stamps `+c` at hi, so res[a] is the current leaving
    // node a INTO the module — which is exactly §5.4.3's "flow into a port".
    // Hence `x − res[a]`, not `x + res[a]`.
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(res[@intFromEnum(U.a)]);",
    ) != null);
    // THE REACTIVE HALF: q() carries `−q_a` on the same row, so the total
    // residual is x − (I_dc + d/dt q_a).
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3caZ3eZ29)] = res[@intFromEnum(U.a)].neg();",
    ) != null);
    // The row is emitted AFTER the contribution stamps it reads.
    const stamp_at = std.mem.indexOf(u8, src, "res[@intFromEnum(U.a)].add(c)").?;
    const row_at = std.mem.indexOf(u8, src, "= x[@intFromEnum(U.flowZ28Z3caZ3eZ29)].sub(").?;
    try std.testing.expect(stamp_at < row_at);
}

test "codegen: a port whose only branch goes to ground still gets its unknown" {
    var h: Harness = undefined;
    // The self-referential form: I(p) <+ I(<p>) + V(p). Nothing else drives p.
    try Harness.run(std.testing.allocator,
        \\module g(p);
        \\  inout p;
        \\  electrical p;
        \\  analog I(p) <+ I(<p>) + V(p);
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "flowZ28Z3cpZ3eZ29, // branch flow") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "res[@intFromEnum(U.flowZ28Z3cpZ3eZ29)] = x[@intFromEnum(U.flowZ28Z3cpZ3eZ29)].sub(res[@intFromEnum(U.p)]);",
    ) != null);
    // No reactive part anywhere ⇒ no q() at all, so no port row is missing.
    try std.testing.expect(std.mem.indexOf(u8, src, "pub fn q(") == null);
}

test "codegen: §5.9 a loop the unit re-runs is not read out of the shared core" {
    var h: Harness = undefined;
    // Two units both slice the loop, so `planCommon` wants to hoist it — but
    // each also has private values inside it, so each re-materializes the loop.
    // Reading the hoisted counter and exit condition there is reading their
    // FINAL values, and the re-materialized loop then runs zero times.
    try Harness.run(std.testing.allocator,
        \\module l(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i;
        \\  real a, b;
        \\  analog begin
        \\    a = 0.0;
        \\    b = 0.0;
        \\    for (i = 1; i <= 5; i = i + 1) begin
        \\      a = a + i;
        \\      b = b + i * 2;
        \\    end
        \\    I(p, n) <+ a * V(p, n);
        \\    I(p) <+ b * V(p);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    // `genDisplay`, not `gen`: since the merge the RESIDUAL cannot hit this bug
    // at all — there is one body, the loop is emitted where its values are
    // computed, and there is no cache holding a loop-carried value at its exit
    // state. §9.4 `display` is the one declaration that still opens with
    // `const c = core(...)`, so it is the only remaining consumer of the §5.9
    // `loop_recompute` fixpoint and therefore the only place this can regress.
    const src = try h.genDisplay(std.testing.allocator);
    // A body holding `while (true)` while reading `c.f<N>` inside it is the bug.
    var rest = src;
    while (std.mem.indexOf(u8, rest, "L")) |_| {
        const at = std.mem.indexOf(u8, rest, ": while (true)") orelse break;
        const end = std.mem.indexOfPos(u8, rest, at, "\n    }") orelse rest.len;
        try std.testing.expect(std.mem.indexOf(u8, rest[at..end], "c.f") == null);
        rest = rest[end..];
    }
    // The residual half of the guarantee, stated structurally: the merged core
    // reads no cache, so a `c.f` cannot appear in it anywhere, in or out of a
    // loop. This is what makes the hazard impossible rather than merely absent.
    const core_at = std.mem.indexOf(u8, src, "fn l__common__core(").?;
    const core_end = std.mem.indexOfPos(u8, src, core_at, "\n}\n").?;
    try std.testing.expect(std.mem.indexOf(u8, src[core_at..core_end], "c.f") == null);
}

test "codegen: §9.4 display tasks are void by default and print on request" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module d(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real g = 2.0;
        \\  analog begin
        \\    $strobe("g=%g n=%5d s=%s", g, 42, "x");
        \\    $write("no newline");
        \\    $error("bad");
        \\    I(p, n) <+ g * V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();

    // A DEVICE never prints: no sink, nothing that blocks a GPU backend.
    const dev = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, dev, "std.debug.print") == null);
    try std.testing.expect(std.mem.indexOf(u8, dev, "pub fn display(") == null);

    // The EXECUTABLE does, with §9.4.3 conversions translated and the operands
    // sliced in (a missing slice renders every one of them as `S.con(0.0)`).
    const exe = try h.genDisplay(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, exe, "pub fn display(") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe, "g={d} n={s:>5} s={s}\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe, "(S.con(model.g)).val()") != null);
    // §9.4.1 `$write` is the one that does not end the line.
    try std.testing.expect(std.mem.indexOf(u8, exe, "\"no newline\"") != null);
    // §9.7.3 the severity is a prefix, not something a reader must infer.
    try std.testing.expect(std.mem.indexOf(u8, exe, "ERROR: bad") != null);
}

test "codegen: §9.4 a display unit that reads an operator input opens the cache" {
    // The display unit is the ONE unit not folded into the core, and an
    // operator's input is not a `mark`ed operand — so a `c.f*` rendered for it
    // used to arrive with no `const c = core(...)` above it and the printing
    // artifact did not compile. Same shape for ddt/transition/slew/laplace.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module dop(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    $strobe("y=%g", transition(V(p, n), 0.0, 1n, 1n));
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const exe = try h.genDisplay(std.testing.allocator);
    const at = std.mem.indexOf(u8, exe, "zTransition(S, c.f").?;
    const open = std.mem.lastIndexOf(u8, exe[0..at], "const c = core(S, x, model, inst);");
    const head = std.mem.lastIndexOf(u8, exe[0..at], "\nfn ") orelse 0;
    try std.testing.expect(open != null and open.? > head);
}

test "codegen: §2.6.1 an integer literal keeps all 64 bits" {
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module big(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer k;
        \\  analog begin
        \\    k = 4607182418800017408;
        \\    I(p, n) <+ 0.0 * k;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, src, "4607182418800017408") != null);
}

test "codegen: a unit whose target is defined in one arm returns a VALUE, not undefined" {
    var h: Harness = undefined;
    // §4.5 the operator's input unit is sliced from the argument, which here is
    // only defined on the taken arm. Returning `undefined` from the other one is
    // undefined behavior in the device AND silently corrupts the operator's
    // history, because `updateState` pushes whatever comes back.
    // The condition is a §3.4 PARAMETER, which §5.8.1 licenses (a `constant_
    // primary` cannot move mid-analysis, so the operator never misses a step)
    // while `elabConst` still refuses to fold it away — a model card overrides
    // it. So the diamond is real and the operator is legal, which is exactly the
    // shape this test needs. A probe condition here would now be E0514.
    try Harness.run(std.testing.allocator,
        \\module g(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  parameter real en = 1.0;
        \\  analog begin
        \\    if (en > 0.5)
        \\      I(p, n) <+ transition(V(p, n), 0, 1n, 1n);
        \\    else
        \\      I(p, n) <+ 0.0;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);
    const at = std.mem.indexOf(u8, src, "fn g__common__core(").?;
    // `"\n}\n"`, not `"\n}"`: the core's return type is an anonymous struct
    // written into the signature, and it closes with `\n} {`.
    const end = std.mem.indexOfPos(u8, src, at, "\n}\n").?;
    const body = src[at..end];
    // Hoisted slots share one `var h: [n]S`, so the carve-out is no longer a
    // property of each declaration — the array itself is declared `undefined`.
    // It is now the pair of facts below: the array is EXACTLY as long as the
    // number of zero-seeds, so no element of it can reach the `return`
    // unwritten. Assert both or the guarantee is not being tested.
    //
    // Targeted, not a blanket memset: the only hoists are the two returned
    // fields (the operator input, defined on one arm only, and the contribution
    // phi). Every other slot is a `const` at its definition, which is what
    // `probeBody` is for — so counting the hoists is counting exactly the values
    // that could reach the `return` without being written.
    try std.testing.expect(std.mem.indexOf(u8, body, "    var h: [2]S = undefined;") != null);
    var hoists: usize = 0;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "    h[")) continue;
        hoists += 1;
        try std.testing.expect(std.mem.endsWith(u8, line, "= S.con(0.0);"));
    }
    try std.testing.expectEqual(@as(usize, 2), hoists);
}

test "codegen: §4.5.8/§4.5.9 an omitted rate argument copies the one that was given" {
    // §4.5.8: "If only a positive rise_time value is specified, the simulator
    // uses it for both rise and fall times." §4.5.9: max_neg_slew_rate "defaults
    // to the opposite of the max_pos_slew_rate."
    //
    // Both used to default to a NEUTRAL element instead of to the value that WAS
    // given — `fall = 0.0` and `max_neg = 1e300` — so the short spelling of each
    // operator behaved differently from the long spelling written with the same
    // number: the 3-argument `transition` transitioned twice as fast, and `slew`
    // held the rising edge while letting the falling edge through unlimited.
    //
    // Asserted on the emitted call rather than by diffing the two spellings,
    // because `slew(x, 2e8, -2e8)` renders `@abs(-2e8)` and the short form
    // renders `@abs(2e8)` — the same limit, different text.
    const cases = [_]struct { call: []const u8, want: []const u8 }{
        .{
            .call = "transition(V(p, n), 0, 2.2n)",
            .want = "((0.0000000022000000000000003) + (0.0000000022000000000000003))",
        },
        .{
            .call = "slew(V(p, n), 2e8)",
            .want = "inst.dt, 200000000.0, @abs(200000000.0))",
        },
    };
    for (cases) |c| {
        const src = try std.fmt.allocPrint(std.testing.allocator,
            \\module m(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  analog I(p, n) <+ {s};
            \\endmodule
        , .{c.call});
        defer std.testing.allocator.free(src);

        var h: Harness = undefined;
        try Harness.run(std.testing.allocator, src, &h);
        defer h.deinit();
        const out = try h.gen(std.testing.allocator);

        std.testing.expect(std.mem.indexOf(u8, out, c.want) != null) catch |e| {
            std.debug.print("{s}: expected to emit `{s}`\n", .{ c.call, c.want });
            return e;
        };
    }
}

test "codegen: §5.9.1 a short-circuit loop condition still reaches the loop's branch" {
    // §4.2.7 `&&` splits its expression across blocks, so after lowering the
    // condition of a `while` the CURRENT block is the short-circuit join, not
    // the loop header. `lowerWhile`/`lowerFor` used to emit the loop's own
    // branch into the header regardless: the header ended up with two
    // terminators, the `&&`'s rhs and join blocks lost their predecessor, and
    // codegen — which walks reachable blocks — declared slots for the values
    // defined in them and then never emitted a single assignment. The loop then
    // branched on an `undefined` local. Zig caught it as "unused local
    // variable" on `bsimsoi_va`; without that it is a read of undefined memory.
    //
    // Asserted structurally rather than on one temporary's name: EVERY declared
    // slot must be written somewhere in the body. That is the whole bug class,
    // and it does not move when slot numbering does.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module w(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    real x, y; integer i;
        \\    x = 1e6; y = V(p, n); i = 0;
        \\    while ((i <= 4) && (abs(y - x) > 1e-12)) begin
        \\      x = y;
        \\      y = 2.0 * y + 1.0;
        \\      i = i + 1;
        \\    end
        \\    I(p, n) <+ y;
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    // The rhs of the `&&` is emitted at all — it used to be dropped entirely.
    try std.testing.expect(std.mem.indexOf(u8, src, ".abs()") != null);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        const decl = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, decl, "var t")) continue;
        const name = decl[4 .. std.mem.indexOfScalar(u8, decl, ':') orelse continue];
        var buf: [32]u8 = undefined;
        const store = try std.fmt.bufPrint(&buf, "{s} = ", .{name});
        std.testing.expect(std.mem.indexOf(u8, src, store) != null) catch |e| {
            std.debug.print("slot `{s}` is declared but never assigned\n", .{name});
            return e;
        };
    }
}

test "codegen: §4.5.7 a delay computed from parameters renders as an expression over `model`" {
    // `td = len * sqrt(l * c)` is how every transmission line in the wild
    // spells its delay (devices/models/lossy_tline.va:135,
    // coupled_tlines.va:110). It is not a literal and not a bare parameter, so
    // it used to hit the `else` of `f64Expr` and paste an `@compileError` INTO
    // an expression in the generated Zig — which the Zig compiler then reported
    // as "unreachable code" at a line of generated code, with nothing naming
    // the model.
    //
    // §4.5.7 permits it: `absdelay(input, td [, maxdelay])` takes td as an
    // analog_expression, and with no maxdelay "the value of td when the
    // absdelay() is first evaluated shall be used" — which for an expression
    // over parameters is its value at every evaluation.
    //
    // Also pins the ASSIGNMENT: `td` is a `real` variable, not a parameter, so
    // this only works because the walk runs on SSA values rather than on names.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module tl(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real len = 1.0 from (0:inf);
        \\  parameter real l = 250e-9 from (0:inf);
        \\  parameter real c = 100e-12 from (0:inf);
        \\  real td;
        \\  analog begin
        \\    td = len * sqrt(l * c);
        \\    I(p, n) <+ absdelay(V(p, n), td);
        \\  end
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(
        u8,
        src,
        "inst.abstime - ((model.len) * (@sqrt((model.l) * (model.c))))",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "@compileError") == null);
}

test "codegen: §4.5 a control argument that is a solve result is E0515, not generated Zig" {
    // The other half: a delay that genuinely cannot be resolved must be a
    // diagnostic at the `.va` line. An `@compileError` pasted into an
    // expression is not one — it reads as an engine bug in generated code.
    var h: Harness = undefined;
    try Harness.run(std.testing.allocator,
        \\module bad(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  analog I(p, n) <+ absdelay(V(p, n), V(c));
        \\endmodule
    , &h);
    defer h.deinit();
    const src = try h.gen(std.testing.allocator);

    var found = false;
    for (h.bag.messages()) |mi| {
        const e = h.bag.get(mi);
        if (e.code != .E0515) continue;
        found = true;
        try std.testing.expectEqual(diag.Stage.codegen, e.stage);
        // The span is the `absdelay` call: a node probe has no instruction of
        // its own to point at, which is what `ctrl_tok` is the fallback for.
        try std.testing.expect(e.span.end > e.span.start);
    }
    try std.testing.expect(found);
    // Refused as a whole unit — an `@compileError` STATEMENT that replaces the
    // body, never one pasted into the middle of an expression (which is what
    // `inst.abstime - (@compileError(…))` was, and what Zig reported as
    // "unreachable code" at a line of generated code).
    try std.testing.expect(std.mem.indexOf(u8, src, "\n    @compileError(\"LRM 4.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "(@compileError") == null);
}
