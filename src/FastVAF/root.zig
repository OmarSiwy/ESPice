//! FastVAF engine — module index & pipeline driver.
//!
//! Each file owns one engine "class" (a group of Verilog-AMS LRM sections).
//! This file is the facade: it re-exports every stage and owns the drivers that
//! sequence them, plus the ownership root (`CompileResult`) that every arena in
//! the engine hangs off.
//!
//! Architecture (see docs/architecture/): a Verilog-A source becomes a
//! loadable device through a fixed, index-based, cache-friendly pipeline.
//! Frontend is shared by all targets; only the backend differs.
//!
//!   .va text
//!     → preprocessor.zig   (class 1)  text → text
//!     → lexer.zig/token.zig (class 1) text → tokens (SoA {tag,start})
//!     → parser.zig/ast.zig  (class 2) tokens → AST (SoA, u32 handles)
//!     → lower.zig + ssa.zig → mir.zig (classes 3,4,5,7,9) AST → MIR (SoA SSA)
//!     → proof.zig           (class 6) MIR → per-unit finiteness verdict
//!     → codegen.zig+naming  (classes 4,5,8,10) MIR → device.zig (per-unit decls)
//!     → orchestrator.zig    (ch.2/5) device.zig → .so (+ GPU kernels)
//!     runtime: eval_batch.zig (ch.4) SIMD device evaluation
//!
//! DOD ground rules that hold in EVERY file here:
//!   - SoA (MultiArrayList / flat Buf), never array-of-structs across a hot loop.
//!   - Cross-node references are typed `enum(u32)` handles, never pointers.
//!   - Arena ownership per compilation; caller owns allocation.
//!   - Smallest integer that fits; hot/cold field split.
//!
//! OWNERSHIP (the whole engine's rule, enforced here):
//!   Every byte produced by stages 1–5 — preprocessed text, token list, AST,
//!   MIR, Lower side tables — is allocated from ONE per-compilation arena that
//!   `CompileResult` owns. There are two deliberate exceptions, so
//!   `CompileResult.deinit` frees exactly three things:
//!     - `proof.Verdict`, gpa-owned because proof.zig frees its own error
//!       strings;
//!     - `device_zig`, gpa-owned because it is the one unboundedly growing
//!       buffer (182 MB on `hisimhv_va`) and an arena cannot regrow in place —
//!       see `codegen.generate`.
//!   Everything else is the arena.
//!   Diagnostics collect into ONE `diag.Bag` on that same arena and are
//!   gpa-duped at the boundary by `Bag.detach` — a failed compilation frees
//!   its arena on the way out, so a borrowed stage message would dangle.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const token = @import("token.zig");
pub const Preprocessor = @import("preprocessor.zig");
pub const Lexer = @import("lexer.zig");
pub const Ast = @import("ast.zig");
pub const Parser = @import("parser.zig");
pub const Mir = @import("mir.zig");
pub const Ssa = @import("ssa.zig");
pub const Lower = @import("lower.zig");
pub const proof = @import("proof.zig");
pub const diag = @import("diag.zig");
pub const diag_code = @import("diag_code.zig");
pub const naming = @import("naming.zig");
pub const codegen = @import("codegen.zig");
pub const eval_batch = @import("eval_batch.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const tb = @import("tb.zig");

/// The three build targets. Frontend is identical for all three; the backend
/// and float behavior differ. See docs/architecture/index.html.
pub const Target = enum {
    /// Frontend only: parse + lower + finiteness proof, emit diagnostics.
    /// No codegen, no `zig` spawn. Microseconds.
    lint,
    /// Self-hosted backend, incremental (resident `zig --listen` + -fincremental),
    /// strict float mode, CPU .so only. Fast edit→run loop.
    debug,
    /// LLVM backend, no incremental, per-unit float mode, CPU .so + GPU kernels.
    release_fast,

    /// `null` for `.lint` — it produces no artifact. Incremental (in-place
    /// patching) is a self-hosted feature and GPU codegen is LLVM-only, so the
    /// backend choice falls out of the target with no further switch.
    pub fn backend(self: Target) ?orchestrator.Backend {
        return switch (self) {
            .lint => null,
            .debug => .self_hosted,
            .release_fast => .llvm,
        };
    }
};

pub const Error = codegen.Error || error{
    /// One or more stages reported diagnostics. They are in the caller's
    /// `Options.diags` when one was supplied.
    CompileFailed,
    /// The source declared no `module` (LRM §6.2) — nothing to compile.
    NoModule,
    /// `.lint` produces no artifact by definition.
    NoArtifact,
    /// `.debug` builds through a session-scoped resident `zig build --listen=-`
    /// child; cross-process -fincremental does not exist on ELF 0.16
    /// (docs/architecture/02-incremental.html).
    NoResidentChild,
};

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------
//
// There is no diagnostic type here any more. Every stage reports into one
// `diag.Bag` (src/diag.zig) keyed by a stable code from src/diag_code.zig, and
// the driver's only job is to create it, hand it to each stage, and detach it
// from the compilation arena on the way out.
//
// What that replaced: five private diagnostic structs, five caps, five
// allocators, and five conversion sites in this file that each turned a
// different currency (a line, a byte, a token index, a MIR instruction) into a
// line/col — one of which could not, and reported proof errors at 0:0.

pub const Bag = diag.Bag;
pub const Code = diag.Code;
pub const Severity = diag.Severity;
pub const Level = diag.Level;

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Diagnostics only.
    file_name: []const u8 = "<source>",
    /// Searched in order for `include, ahead of the built-in annex D files.
    include_dirs: []const []const u8 = &.{},
    /// Prepend annex D.2 constants.vams + annex D.1 disciplines.vams (§3.6.2).
    std_defs: bool = true,
    /// Receives every diagnostic of the run — errors AND warnings, so a
    /// SUCCESSFUL compilation may still fill it (see W0650, the finiteness
    /// warning). Detached from the compilation arena before this call returns,
    /// so it stays valid after the `CompileResult` is freed; the caller must
    /// `deinit(gpa)` it.
    diags: ?*diag.Bag = null,
    /// Per-code lint levels — `--allow=W0650`, `--deny=W0651`, ... An error
    /// code cannot be allowed away; see `diag.Levels.set`.
    lint: diag.Levels = .empty,
    /// Class-6 knobs (solver compliance bound, overflow model). See proof.zig.
    proof: proof.Options = .{},
    /// §9.4 what to do with the model's display tasks. `.drop` (the default)
    /// makes the DEVICE: no text, no syscall in the Newton loop, GPU-clean, and
    /// a W0850 for every task that was dropped. `.emit` makes the EXECUTABLE:
    /// the prints are the artifact. See `codegen.Display`.
    display: codegen.Display = .drop,
};

// ---------------------------------------------------------------------------
// CompileResult — the ownership root
// ---------------------------------------------------------------------------

/// Result of one frontend run (source → MIR → optionally device.zig).
///
/// The arena is HEAP-allocated on purpose: `Lower`, `Ssa.SsaBuilder` and the
/// AST stores all hold an `Allocator` whose `ptr` is the ArenaAllocator's
/// address, so moving the ArenaAllocator by value into this struct would
/// dangle every one of them. Keeping a pointer makes the result freely movable
/// (into a `Compilation` unit row, out of a function, …).
pub const CompileResult = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    /// Preprocessed source (arena). Every AST/MIR string borrows from it.
    source: []const u8,
    file: *Ast.SourceFile,
    mir: *Mir,
    lower: *Lower,
    /// gpa-owned (its `unit_modes` slice is).
    verdict: proof.Verdict,
    target: Target,
    /// Stage 6 output; empty until `generateDevice` runs (never for `.lint`).
    /// GPA-OWNED, not arena — it is the one buffer that grows to hundreds of
    /// megabytes, and `ArenaAllocator.resize` cannot grow it in place. Freed by
    /// `deinit`; every consumer borrows it read-only and finishes first.
    ///
    /// `device.names`/`unit_lo`/`unit_hi` are the per-unit file map the
    /// orchestrator writes through `writeIfChanged` — see `codegen.Output`.
    device: codegen.Output = .{ .text = "" },
    /// Whether `device.text` contains an `@compileError` unit. Reported by
    /// codegen, so no caller has to substring-search a multi-megabyte output.
    device_has_compile_error: bool = false,
    /// Knobs that change WHAT stage 6 generates (§9.4 display handling today).
    codegen_opts: codegen.Options = .{},

    pub fn deinit(self: *CompileResult) void {
        self.gpa.free(self.device.text);
        self.verdict.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self.arena);
        self.* = undefined;
    }

    /// Stage 6. Idempotent — the generated text is cached on the result, which
    /// is what makes a `Compilation` cache hit free.
    pub fn generateDevice(self: *CompileResult) codegen.Error![]const u8 {
        return (try self.generateOutput()).text;
    }

    /// Stage 6, with the per-unit file map the orchestrator needs.
    pub fn generateOutput(self: *CompileResult) codegen.Error!codegen.Output {
        if (self.device.text.len == 0) {
            self.device = try codegen.generate(
                self.gpa,
                self.arena.allocator(),
                self.mir,
                self.lower,
                self.verdict,
                &self.device_has_compile_error,
                self.codegen_opts,
            );
        }
        return self.device;
    }

    /// Source units in the codegen/proof sense (LRM §5.6 contributions).
    /// `verdict.unit_modes` is parallel to this.
    pub fn unitCount(self: *const CompileResult) usize {
        return proof.unitCount(self.lower);
    }
};

// ---------------------------------------------------------------------------
// Stages 1–5
// ---------------------------------------------------------------------------

/// Front-to-MIR driver. Runs stages 1–5 (preprocess → lex → parse → lower →
/// PROVE). On `.lint` this is the whole job.
pub fn compileSource(gpa: Allocator, source: []const u8, target: Target) Error!CompileResult {
    return compileSourceOpts(gpa, source, target, .{});
}

pub fn compileSourceOpts(
    gpa: Allocator,
    source: []const u8,
    target: Target,
    opts: Options,
) Error!CompileResult {
    const arena_state = try newArena(gpa);

    // ONE bag for the whole run, on the compilation arena.
    var bag = diag.Bag.init(arena_state.allocator());
    bag.levels = opts.lint;

    const result = pipeline(gpa, arena_state, source, target, opts, &bag);

    // A `--deny=`d warning is an error by the user's own instruction, so a
    // compilation that only tripped one must still FAIL. Read before `finish`,
    // which moves the bag out.
    const denied = bag.failed();

    // ORDER MATTERS: the bag's messages, labels and file texts all live in the
    // compilation arena, so they must be copied out BEFORE the arena can be
    // freed. This is why no stage frees the arena on error any more — the
    // errdefers that used to do it ran first and left `detach` reading freed
    // memory.
    try finish(gpa, opts, &bag);

    var ok = result catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    if (denied) {
        ok.deinit();
        return error.CompileFailed;
    }
    return ok;
}

/// Stages 1–5. Never frees `arena_state`: on success it goes to the
/// `CompileResult`, on failure the caller frees it once the bag is detached.
fn pipeline(
    gpa: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    source: []const u8,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    var prelude_len: u32 = 0;
    const text = try preprocess(gpa, arena_state, source, opts, bag, &prelude_len);
    return compileInArena(gpa, arena_state, text, target, opts, bag);
}

/// Hand the bag to the caller, detached from the compilation arena. Called on
/// EVERY exit path, including the successful one — a clean compilation can
/// still carry warnings (W0650), and a caller that asked for diagnostics wants
/// them either way.
fn finish(gpa: Allocator, opts: Options, bag: *diag.Bag) Allocator.Error!void {
    const out = opts.diags orelse return;
    out.* = bag.*;
    try out.detach(gpa);
}

/// Same, for text that has already been through stage 1 (the `Compilation`
/// cache path re-enters here). `text` is copied into the fresh arena because
/// every interned AST string borrows it for the life of the result.
pub fn compilePreprocessed(
    gpa: Allocator,
    text: []const u8,
    target: Target,
    opts: Options,
) Error!CompileResult {
    const arena_state = try newArena(gpa);
    const owned = arena_state.allocator().dupe(u8, text) catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    var bag = diag.Bag.init(arena_state.allocator());
    bag.levels = opts.lint;
    // Stage 1 did not run here, so no source map exists: the text IS the file.
    bag.setSingleFile(opts.file_name, owned, 0) catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    const result = compileInArena(gpa, arena_state, owned, target, opts, &bag);
    const denied = bag.failed();
    try finish(gpa, opts, &bag);
    var ok = result catch |err| {
        freeArena(gpa, arena_state);
        return err;
    };
    if (denied) {
        ok.deinit();
        return error.CompileFailed;
    }
    return ok;
}

/// Stage 1. The returned bytes live in the compilation arena and everything
/// downstream borrows them. TAKES OWNERSHIP of `arena_state`: it is freed here
/// on failure, so no caller may add an errdefer of its own (each stage frees
/// the arena exactly once, at the point ownership stops).
fn preprocess(
    gpa: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    source: []const u8,
    opts: Options,
    bag: *diag.Bag,
    prelude_len: *u32,
) Error![]const u8 {
    _ = gpa;
    const arena = arena_state.allocator();
    return Preprocessor.process(arena, source, .{
        .include_dirs = opts.include_dirs,
        .file_name = opts.file_name,
        .std_defs = opts.std_defs,
        .prelude_len = prelude_len,
        .bag = bag,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The message is already in the bag, with its own file and span — the
        // preprocessor registers every file it opens, so a failure inside an
        // `include names that header rather than the top-level unit.
        error.PreprocessFailed => error.CompileFailed,
    };
}

/// Stages 2–5. Takes ownership of `arena_state`: it is freed on any error and
/// handed to the returned `CompileResult` on success.
///
/// Every stage now reports into `bag` in ONE currency — a byte range in the
/// preprocessed text — so this function no longer converts anything. It just
/// runs the stages and translates the aggregate outcome into an `Error`.
fn compileInArena(
    gpa: Allocator,
    arena_state: *std.heap.ArenaAllocator,
    text: []const u8,
    target: Target,
    opts: Options,
    bag: *diag.Bag,
) Error!CompileResult {
    const arena = arena_state.allocator();

    // --- stage 2: lex (class 1) ---------------------------------------------
    var tokens = try Lexer.Lexer.tokenize(arena, text);
    const tags = tokens.items(.tag);
    const starts = tokens.items(.start);

    // --- stage 3: parse (class 2) -------------------------------------------
    var p = Parser.Parser.init(arena, text, tags, starts, bag);
    const file = try arena.create(Ast.SourceFile);
    file.* = p.parseSourceFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            // The parser recovers at top level, so a diagnosed parse still
            // tells us whether a §6.2 `module` was found at all. When it was
            // not — the file held only constructs outside annex C
            // (`connectmodule`, `connectrules`, `macromodule`, `library`,
            // `primitive`, `paramset`) — NoModule is the outcome the caller
            // acts on; the precise reason is already in the bag.
            if (p.file.modules.len == 0) return error.NoModule;
            return error.CompileFailed;
        },
    };

    // --- stage 4: lower (classes 3,4,5,7,9) ---------------------------------
    const mir = try arena.create(Mir);
    mir.* = .{};
    const lower = try arena.create(Lower);
    lower.* = Lower.init(arena, mir, file, text, starts, bag);
    lower.lowerFile() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoModule => {
            try bag.add(.lower, .E1001, .{}, "", .{});
            return error.NoModule;
        },
        error.DiagnosticsReported => return error.CompileFailed,
    };

    // --- stage 5: PROVE (class 6) — gates every target ----------------------
    // Also the source of the W0650 finiteness WARNING, which is why this runs
    // even when nothing downstream needs the verdict: a `.lint` run exists to
    // tell the user what their model costs.
    const verdict = try proof.proveOpts(gpa, mir, lower, opts.proof, bag);
    errdefer verdict.deinit(gpa);
    // §4.3.2: a domain violation is a compile error on every target.
    if (!verdict.ok()) return error.CompileFailed;

    // §9.4. Reported HERE and not in lower.zig, because "was the print kept?"
    // is a property of what the caller asked to build, and lowering does not
    // know that. Both are warnings: the model is legal either way.
    for (lower.displays.items) |d| {
        const span = lower.tokenSpan(d.tok);
        if (opts.display == .drop) {
            try bag.add(.lower, .W0850, span, "`{s}`", .{d.name});
        } else if (d.conditional) {
            try bag.add(.lower, .W0851, span, "`{s}`", .{d.name});
        }
    }

    return .{
        .gpa = gpa,
        .arena = arena_state,
        .source = text,
        .file = file,
        .mir = mir,
        .lower = lower,
        .verdict = verdict,
        .target = target,
        // `opts.diags`, not the compilation's own bag: codegen runs AFTER
        // `finish` detached the messages into the caller's bag, so the caller's
        // is the only one still alive when E0515 is raised.
        .codegen_opts = .{ .display = opts.display, .diags = opts.diags },
    };
}

// ---------------------------------------------------------------------------
// Stages 6–8 — codegen + hand-off to the orchestrator
// ---------------------------------------------------------------------------

/// Stage 6 then 7–8. FastVAF's responsibility ends at the artifact: the host
/// owns dlopen/dlclose and simulation state (docs/architecture/05-build-artifact).
///
/// `resident` is the session-scoped `zig build --listen=-` child required by
/// `.debug`; pass `null` for `.release_fast`, which always builds cold.
pub fn buildArtifact(
    gpa: Allocator,
    io: std.Io,
    result: *CompileResult,
    o: orchestrator.Options,
    generation: u32,
    resident: ?*orchestrator.ResidentChild,
    // Inferred error set: the orchestrator spawns a process and talks a pipe
    // protocol, so its failures are OS-shaped and open-ended. Naming them in
    // `Error` would mean re-listing every IO error the child can produce.
) !orchestrator.Result {
    if (result.target == .lint) return error.NoArtifact;
    const device = try result.generateOutput();
    return switch (result.target) {
        .lint => unreachable,
        .debug => (resident orelse return error.NoResidentChild).rebuild(gpa, device, generation),
        .release_fast => orchestrator.compileRelease(gpa, io, o, device, generation),
    } catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // The orchestrator's failure modes are build-system shaped (spawn,
        // pipe, zig diagnostics); they are not compile errors of ours, so they
        // pass through with their own names rather than becoming CompileFailed.
        else => err,
    };
}

test "buildArtifact is analyzed" {
    // This function was dead AND broken for a while: nothing referenced it, so
    // Zig never analyzed its body, and it kept calling a two-argument
    // `compileRelease` long after the orchestrator grew `io` and an `Options`.
    // A pub fn with no caller is not type-checked — this reference is what
    // keeps that from happening again.
    _ = &buildArtifact;
}

// ---------------------------------------------------------------------------
// Compilation — incremental frontend cache
// ---------------------------------------------------------------------------

/// Stable, dense handle for a source unit. Never reused; a unit's handle
/// survives every edit, which is what lets a caller key its own state off it.
pub const Unit = enum(u32) { _ };

pub const UpdateStatus = enum {
    /// The preprocessed bytes were byte-identical: stages 2–6 did not run.
    cached,
    /// Stages 1–6 re-ran; `generation` was bumped.
    compiled,
};

pub const Update = struct {
    unit: Unit,
    /// Bumped on every recompile. The artifact path is versioned by it so the
    /// host dlopens a fresh inode (ch.5).
    generation: u32,
    status: UpdateStatus,
    /// device.zig. Empty for `.lint`. Borrowed from the unit's arena — valid
    /// until the next `update` of THIS unit.
    generated: []const u8,
};

/// Session-scoped frontend cache. Dirtiness is decided on the PREPROCESSED
/// bytes (docs/architecture/01-pipeline.html §stage 1), so a macro or `include
/// change invalidates even when the .va file itself is untouched.
///
/// This is deliberately whole-unit, not fine-grained: per-declaration change
/// detection is delegated to `zig` through stable naming (ch.2). All this layer
/// buys is skipping a frontend that already runs in microseconds — its real job
/// is proving the no-op-edit determinism invariant.
pub const Compilation = struct {
    gpa: Allocator,
    units: std.MultiArrayList(UnitRow) = .empty,
    /// name → Unit. Lookup-only: never iterated (determinism).
    by_name: std.StringHashMapUnmanaged(Unit) = .empty,
    /// Cache misses since init. Benchmarks read it.
    rebuilds: u64 = 0,

    /// SoA even though the table is cold — one row per source file — because
    /// the whole engine holds that shape and the row is mostly pointers.
    const UnitRow = struct {
        /// gpa-owned; also the diagnostic file name.
        name: []const u8,
        /// BLAKE3 of the preprocessed bytes + the target byte.
        fingerprint: [32]u8,
        generation: u32,
        /// `null` after a failed update — a stale result must never be served.
        result: ?CompileResult,
        /// Borrowed from `result.device_zig` (gpa-owned by the result).
        generated: []const u8,
        /// The unit's diagnostics, gpa-owned and detached.
        ///
        /// WHY THE CACHE HAS TO CARRY THESE: stages 2–6 do not run on a hit, so
        /// without a replay a cached unit would report NOTHING — an edit
        /// elsewhere in the project would make a model's W0650 finiteness
        /// warning silently vanish and come back. Warnings are the reason this
        /// matters: a cached ERROR cannot happen (a failed update drops the
        /// result), but a cached SUCCESS carrying warnings is the normal case.
        diags: diag.Bag,
    };

    pub fn init(gpa: Allocator) Compilation {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Compilation) void {
        const names = self.units.items(.name);
        const results = self.units.items(.result);
        const diags = self.units.items(.diags);
        for (names, results, diags) |name, *res, *d| {
            if (res.*) |*r| r.deinit();
            d.deinit(self.gpa);
            self.gpa.free(name);
        }
        self.units.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn unitOf(self: *const Compilation, name: []const u8) ?Unit {
        return self.by_name.get(name);
    }

    /// Registers `name` if new. The handle is the row index.
    pub fn addUnit(self: *Compilation, name: []const u8) Allocator.Error!Unit {
        if (self.by_name.get(name)) |u| return u;
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        const unit: Unit = @enumFromInt(self.units.len);
        try self.units.append(self.gpa, .{
            .name = owned,
            .fingerprint = @splat(0),
            .generation = 0,
            .result = null,
            .generated = "",
            .diags = .init(self.gpa),
        });
        errdefer _ = self.units.pop();
        try self.by_name.put(self.gpa, owned, unit);
        return unit;
    }

    pub fn result(self: *Compilation, unit: Unit) ?*CompileResult {
        const slot = &self.units.items(.result)[@intFromEnum(unit)];
        return if (slot.*) |*r| r else null;
    }

    pub fn generationOf(self: *const Compilation, unit: Unit) u32 {
        return self.units.items(.generation)[@intFromEnum(unit)];
    }

    /// Stages 1–6 for one source unit, skipped wholesale when the preprocessed
    /// bytes are unchanged. On failure the unit's cached result is dropped and
    /// the error is returned; diagnostics land in `opts.diags`.
    pub fn update(
        self: *Compilation,
        name: []const u8,
        source: []const u8,
        target: Target,
        opts: Options,
    ) Error!Update {
        const unit = try self.addUnit(name);
        const idx = @intFromEnum(unit);

        var o = opts;
        o.file_name = self.units.items(.name)[idx];

        // Stage 1 runs unconditionally: it IS the fingerprint.
        const arena_state = try newArena(self.gpa);
        var bag = diag.Bag.init(arena_state.allocator());
        bag.levels = o.lint;
        var prelude_len: u32 = 0;
        const text = preprocess(self.gpa, arena_state, source, o, &bag, &prelude_len) catch |err| {
            try finish(self.gpa, o, &bag);
            freeArena(self.gpa, arena_state);
            return err;
        };

        var fp: [32]u8 = undefined;
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(&.{@intFromEnum(target)});
        hasher.update(text);
        hasher.final(&fp);

        if (self.units.items(.result)[idx] != null and
            std.mem.eql(u8, &self.units.items(.fingerprint)[idx], &fp))
        {
            // Stages 2–6 did not run, so `bag` is empty. Replay what the unit
            // reported when it WAS compiled, or a cached success would look
            // like a warning-free one.
            freeArena(self.gpa, arena_state);
            if (o.diags) |out| {
                out.* = self.units.items(.diags)[idx];
                try out.detach(self.gpa); // deep-copies; the stored bag is untouched
            }
            return .{
                .unit = unit,
                .generation = self.units.items(.generation)[idx],
                .status = .cached,
                .generated = self.units.items(.generated)[idx],
            };
        }

        // Miss. Drop the stale result first: nothing may observe a result that
        // does not match the source we are about to compile.
        if (self.units.items(.result)[idx]) |*old| old.deinit();
        self.units.items(.result)[idx] = null;
        self.units.items(.generated)[idx] = "";

        var res = compileInArena(self.gpa, arena_state, text, target, o, &bag) catch |err| {
            try finish(self.gpa, o, &bag);
            freeArena(self.gpa, arena_state);
            return err;
        };
        const denied = bag.failed();

        // Keep the unit's own copy BEFORE `finish` moves the bag out to the
        // caller. Both are deep copies of the same arena-backed original.
        var stored = bag;
        try stored.detach(self.gpa);
        self.units.items(.diags)[idx].deinit(self.gpa);
        self.units.items(.diags)[idx] = stored;

        try finish(self.gpa, o, &bag);
        if (denied) {
            res.deinit();
            return error.CompileFailed;
        }
        errdefer res.deinit();
        const generated = if (target == .lint) "" else try res.generateDevice();

        self.units.items(.result)[idx] = res;
        self.units.items(.generated)[idx] = generated;
        self.units.items(.fingerprint)[idx] = fp;
        self.units.items(.generation)[idx] +%= 1;
        self.rebuilds += 1;
        return .{
            .unit = unit,
            .generation = self.units.items(.generation)[idx],
            .status = .compiled,
            .generated = generated,
        };
    }
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn newArena(gpa: Allocator) Allocator.Error!*std.heap.ArenaAllocator {
    const a = try gpa.create(std.heap.ArenaAllocator);
    a.* = .init(gpa);
    return a;
}

fn freeArena(gpa: Allocator, a: *std.heap.ArenaAllocator) void {
    a.deinit();
    gpa.destroy(a);
}

// `preludeLines` and `userLine` used to live here: the prelude's newline count
// was subtracted from every reported line, and the file comment admitted that
// `include shifted lines the same way and was NOT corrected, so an error inside
// an included header pointed at the wrong line of the wrong file. That upgrade
// path is now taken — the preprocessor emits a real `diag.SourceMap` (offset →
// file, offset) and `diag.render` resolves through it.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    // One test root: pull in every stage so `zig build test` runs their tests.
    _ = token;
    _ = Preprocessor;
    _ = Lexer;
    _ = Ast;
    _ = Parser;
    _ = Mir;
    _ = Ssa;
    _ = Lower;
    _ = proof;
    _ = naming;
    _ = codegen;
    _ = eval_batch;
    _ = orchestrator;
    _ = diag;
    _ = diag_code;
    _ = tb;
}

const test_resistor =
    \\module res(p, n);
    \\  inout p, n;
    \\  electrical p, n;
    \\  parameter real r = 1000.0 from (0.0:inf);
    \\  analog I(p, n) <+ V(p, n) / r;
    \\endmodule
;

test "lint: source → MIR, arena freed clean" {
    var res = try compileSource(std.testing.allocator, test_resistor, .lint);
    defer res.deinit();

    try std.testing.expectEqualStrings("res", res.mir.name);
    try std.testing.expectEqual(@as(usize, 2), res.lower.num_ports);
    try std.testing.expect(res.verdict.ok());
    try std.testing.expectEqual(res.unitCount(), res.verdict.unit_modes.len);
}

test "diagnostics outlive the compilation arena" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    try std.testing.expectError(error.CompileFailed, compileSourceOpts(
        gpa,
        "module bad(p); inout p; electrical p; analog I(p) <+ ;\nendmodule\n",
        .lint,
        .{ .diags = &bag },
    ));
    // The arena is gone by now; reading the messages must still be valid.
    try std.testing.expect(!bag.isEmpty());
    try std.testing.expect(bag.failed());
    for (bag.messages()) |mi| try std.testing.expect(diag.info(bag.get(mi).code).title.len != 0);

    // And so must rendering, which reads the FILE TEXT the bag detached.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &buf);
    defer buf = aw.toArrayList();
    try diag.render(&bag, &aw.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "-->") != null);
}

test "a clean compilation reports no diagnostics but still hands back the bag" {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);

    var res = try compileSourceOpts(
        gpa,
        "module r(p, n); inout p, n; electrical p, n;\n" ++
            "  parameter real rs = 1.0 from (0:inf);\n" ++
            "  analog I(p, n) <+ V(p, n) / rs;\n" ++
            "endmodule\n",
        .lint,
        .{ .diags = &bag },
    );
    defer res.deinit();
    try std.testing.expect(!bag.failed());
    // A fully-ranged resistor is provably finite, so not even W0650 fires.
    try std.testing.expect(bag.isEmpty());
    try std.testing.expectEqual(proof.FloatMode.optimized, res.verdict.unit_modes[0]);
}

test "lint levels: --deny promotes a warning into a hard failure" {
    const gpa = std.testing.allocator;
    const src =
        \\module amp(a, c); inout a, c; electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
        \\
    ;

    // Default: W0650 fires, but a warning does not fail a compilation.
    {
        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag });
        defer res.deinit();
        try std.testing.expect(!bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.warn_count);
    }

    // --deny=W0650: same diagnostic, now an error, and the compile fails.
    {
        var levels: diag.Levels = .empty;
        defer levels.deinit(gpa);
        try levels.set(gpa, .W0650, .deny);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        try std.testing.expectError(error.CompileFailed, compileSourceOpts(
            gpa,
            src,
            .lint,
            .{ .diags = &bag, .lint = levels },
        ));
        try std.testing.expect(bag.failed());
        try std.testing.expectEqual(@as(u32, 1), bag.err_count);
    }

    // --allow=W0650: not collected at all, and still a clean compile.
    {
        var levels: diag.Levels = .empty;
        defer levels.deinit(gpa);
        try levels.set(gpa, .W0650, .allow);

        var bag: diag.Bag = .init(gpa);
        defer bag.deinit(gpa);
        var res = try compileSourceOpts(gpa, src, .lint, .{ .diags = &bag, .lint = levels });
        defer res.deinit();
        try std.testing.expect(bag.isEmpty());
        // Silencing the lint does not change the generated code.
        try std.testing.expectEqual(proof.FloatMode.strict, res.verdict.unit_modes[0]);
    }
}

test "Compilation: a cache hit replays the unit's warnings" {
    const gpa = std.testing.allocator;
    var comp: Compilation = .init(gpa);
    defer comp.deinit();

    const src =
        \\module amp(a, c); inout a, c; electrical a, c;
        \\  analog I(a, c) <+ exp(V(a, c));
        \\endmodule
        \\
    ;

    var first: diag.Bag = .init(gpa);
    defer first.deinit(gpa);
    const a = try comp.update("amp.va", src, .lint, .{ .diags = &first });
    try std.testing.expectEqual(UpdateStatus.compiled, a.status);
    try std.testing.expectEqual(@as(u32, 1), first.warn_count);

    // Byte-identical source: stages 2–6 are skipped entirely...
    var second: diag.Bag = .init(gpa);
    defer second.deinit(gpa);
    const b = try comp.update("amp.va", src, .lint, .{ .diags = &second });
    try std.testing.expectEqual(UpdateStatus.cached, b.status);

    // ...but the diagnostics must not vanish with them. A warning that blinks
    // out because an unrelated file was edited is worse than no warning.
    try std.testing.expectEqual(@as(u32, 1), second.warn_count);
    try std.testing.expectEqual(first.at(0).code, second.at(0).code);
    try std.testing.expectEqualStrings(first.at(0).message, second.at(0).message);
    // Deep copy, not a share: the two bags deinit independently.
    try std.testing.expect(first.at(0).message.ptr != second.at(0).message.ptr);
}

test "Compilation: unchanged source is a cache hit, generation stable" {
    const gpa = std.testing.allocator;
    var comp: Compilation = .init(gpa);
    defer comp.deinit();

    const first = try comp.update("res.va", test_resistor, .lint, .{});
    try std.testing.expectEqual(UpdateStatus.compiled, first.status);
    try std.testing.expectEqual(@as(u32, 1), first.generation);

    const second = try comp.update("res.va", test_resistor, .lint, .{});
    try std.testing.expectEqual(UpdateStatus.cached, second.status);
    try std.testing.expectEqual(first.unit, second.unit);
    try std.testing.expectEqual(first.generation, second.generation);
    try std.testing.expectEqual(@as(u64, 1), comp.rebuilds);

    // A macro-only edit changes the preprocessed bytes ⇒ must recompile.
    const via_macro = "`define R 1000.0\n" ++
        \\module res(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter real r = `R from (0.0:inf);
        \\  analog I(p, n) <+ V(p, n) / r;
        \\endmodule
    ;
    const third = try comp.update("res.va", via_macro, .lint, .{});
    try std.testing.expectEqual(UpdateStatus.compiled, third.status);
    try std.testing.expectEqual(@as(u32, 2), third.generation);
}

test "determinism: a no-op recompile reproduces identical device.zig" {
    const gpa = std.testing.allocator;
    var a = try compileSource(gpa, test_resistor, .debug);
    defer a.deinit();
    var b = try compileSource(gpa, test_resistor, .debug);
    defer b.deinit();
    try std.testing.expectEqualStrings(try a.generateDevice(), try b.generateDevice());
}

// The static lib exports no symbol and Zig analyses lazily, so nothing in the
// pipeline is type-checked unless something references it. This test is the
// integration guard: it forces semantic analysis of every top-level pub decl of
// every stage, so `zig build` (which depends on compiling the test roots) means
// "the whole engine type-checks", not just "the files parse".
test "every top-level pub decl of every stage type-checks" {
    inline for (.{ token, Preprocessor, Lexer, Ast, Parser, Mir, Ssa, Lower, proof, naming, codegen, eval_batch, orchestrator }) |stage| {
        std.testing.refAllDecls(stage);
    }
}
