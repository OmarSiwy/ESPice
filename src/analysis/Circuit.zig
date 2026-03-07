//! Circuit: frozen, analysis-facing representation.
//!
//!   pattern:  col_ptr / row_idx  (CSC, frozen at compile)
//!   planes:   g_vals (dI/dx), c_vals (dQ/dx), rhs (I residual), q_vec (Q)
//!   eval():   one pass fills all four
//!
//! Every analysis is an affine consumer of the planes:
//!   DC   A = G;   TRAN  A = G + a*C;   AC  A = G + jwC.

const std = @import("std");
const device_ir = @import("device_ir");
const device_eval = @import("device_eval");
const Prepared = @import("problem_types").Circuit;
const progress_api = @import("progress.zig");
const solvers = @import("solvers");
// Leaf types only (Waveform/Options/SimResult) — importing the transient
// driver here would close a cycle: tran.zig -> ../types.zig -> Circuit.zig.
const tran = @import("tran/types.zig");

const Batch = device_ir.Batch;
const Planes = device_ir.Planes;
const ParamRef = device_ir.ParamRef;

/// A parameter that takes a DIFFERENT value in the frequency domain.
/// ngspice keeps a parallel value per device for exactly this (`RESacResist` /
/// `RESacConduct`, resdefs.h:48-49) and stamps it from `RESacload`
/// (resload.c:60-62) while `RESload` keeps using the DC one — so `ac=` moves
/// .ac/.sp/.noise/.pz and leaves .op/.dc/.tran alone.
pub const AcParam = struct {
    ptr: ParamRef,
    ac_value: f64,
    /// Scratch: the DC value, saved across one AC linearization.
    saved: f64 = 0,
};

const NoiseSource = device_ir.NoiseSource;
const StateCtlOp = device_ir.StateCtlOp;
const Proto = device_ir.Proto;
const PatternView = device_ir.PatternView;
const ParEval = device_eval.ParEval;
const converger = solvers.converger;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const GROUND: u32 = 0;

// ---------------------------------------------------------------------------
// Re-exports from solvers
// ---------------------------------------------------------------------------

pub const BbdBlock = @import("numerics").BbdBlock;
pub const BbdInfo = @import("numerics").BbdInfo;

// ---------------------------------------------------------------------------
// Utility types
// ---------------------------------------------------------------------------

/// Plain hook: assemble = one eval, matrix = G. This IS dc.
pub const EvalHook = struct {
    pub const gpu_eligible = true;

    pub fn assemble(_: EvalHook, ckt: *Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
    }
    pub fn vals(_: EvalHook, ckt: *Circuit) []f64 {
        return ckt.g_vals;
    }
    pub fn diagAt(_: EvalHook, ckt: *Circuit, slot: u32) f64 {
        return ckt.g_vals[slot];
    }
};

/// Engine-owned GPU solve surface — persistent context, batch-capable.
/// Single-solve (backward compat) + batch Newton + batch frequency.
/// Errors fall back to the CPU path.
pub const GpuHook = struct {
    ctx: *anyopaque,
    solve_newton: *const fn (*anyopaque, x: []f64, t: f64, opts: converger.Options) anyerror!converger.Result,
    simulate_tran: ?*const fn (*anyopaque, x: []f64, probes: []const u32, waveform: *tran.Waveform, options: tran.Options) anyerror!tran.SimResult = null,
    /// N independent Newton solves in one launch (MC/corners/temp/sens).
    /// x_lanes is a flat blob: lane k is x_lanes[k*n..][0..n], overwritten with
    /// the converged solution for that lane.
    solve_batch: ?*const fn (*anyopaque, x_lanes: []f64, n: u32, t: f64, opts: converger.Options, results: []converger.Result) anyerror!void = null,
    /// N independent frequency-domain solves: (G + jωC)x = rhs.
    /// omegas[k] is the angular frequency; x_out is a flat blob, lane k written
    /// to x_out[k*2n..][0..2n] (real‖imag).
    freq_solve_batch: ?*const fn (*anyopaque, g_vals: []const f64, c_vals: []const f64, omegas: []const f64, rhs: []const f64, x_out: []f64, n: u32) anyerror!void = null,
    /// Adjoint variant: (G + jωC)^H y = rhs per frequency.
    freq_solve_adjoint_batch: ?*const fn (*anyopaque, g_vals: []const f64, c_vals: []const f64, omegas: []const f64, rhs: []const f64, y_out: []f64, n: u32) anyerror!void = null,
    /// Stamp the planes on the device — the GPU half of `Circuit.eval` /
    /// `Circuit.evalNewton`, ground pin included.
    ///
    /// Void, not `anyerror!void`, because a stamp sits under every analysis in
    /// the tree and none of them are shaped to handle a driver fault mid-solve.
    /// The implementation falls back to the CPU stamp for the failing call and
    /// warns once, so a fault costs speed and not an answer.
    eval_planes: ?*const fn (*anyopaque, x: []const f64, t: f64) void = null,
    /// The GPU halves of `applyLimits` / `updateStates` / `clearLimits` /
    /// `seedJunctions` / `stateCtl` for resident limit/State batches (one
    /// fused `StateKernel` launch plus a `CtlKernel` at accepted steps;
    /// ineligible batches keep their host walk inside). All present or all
    /// null — one device-resident lim/state blob backs them. `apply_limits`
    /// also runs the state-latch half; the converger calls the two
    /// back-to-back at the same x (`finalizeStep`), so `update_states` only
    /// covers the CPU-side batches.
    apply_limits: ?*const fn (*anyopaque, x: []f64, x_old: []const f64) bool = null,
    update_states: ?*const fn (*anyopaque, x: []const f64) ?f64 = null,
    clear_limits: ?*const fn (*anyopaque) void = null,
    seed_junctions: ?*const fn (*anyopaque, x: []f64) void = null,
    /// The GPU half of `stateCtl`: accepted-step latches (path-integration
    /// commit) mutate the device-resident Instance blobs, so the host walk
    /// cannot stand in for a resident batch.
    state_ctl: ?*const fn (*anyopaque, op: StateCtlOp) bool = null,
    /// Repack device-resident payloads after parameter mutation (sweeps).
    repack: ?*const fn (*anyopaque) anyerror!void = null,
    /// Cheap dirty mark: host models/instances mutated (temp, recompute,
    /// homotopy attempt) — the context re-uploads lazily before its next
    /// launch. Every Circuit-level param mutator calls it, so a resident
    /// batch can never eval against stale physics.
    mark_dirty: ?*const fn (*anyopaque) void = null,
};

// ---------------------------------------------------------------------------
// Circuit struct
// ---------------------------------------------------------------------------

/// Hot block first: the pattern, the four value planes, the eval dispatch and
/// the eval-driving flags are the only fields a solve streams. Cold metadata
/// (baseline, intern table, memos, GPU/par/workspace handles) is parked below
/// so it never shares a cache line with the hot path a per-eval pass walks.
pub const Circuit = struct {
    // =======================================================================
    // HOT — touched every eval / solve
    // =======================================================================

    // -- hot: pattern (read every solve) --
    col_ptr: []u32,
    row_idx: []u32,
    nnz: u32,
    trash_slot: u32,
    n: u32,

    // -- hot: value planes --
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,

    // -- hot: eval dispatch --
    diag_slots: []u32,
    batches: []Batch,

    /// true ⇒ unknown i is an MNA branch current (KVL row); false ⇒ node
    /// voltage (KCL row). Read by the converger's per-row tolerance.
    current_row: []bool,

    // -- hot: flags --
    has_charge: bool,
    /// Some charge-carrying batch advances device state at the ACCEPTED step
    /// (freeze_grad latches, absdelay rings): the transient must re-read q
    /// under the committed state before recording it as q_prev, or the next
    /// step opens on a residual α·Δq that doubles as dt halves.
    has_state_q: bool,
    has_baseline: bool,
    /// Set by engine when --gpu is active and circuit is GPU-eligible.
    /// converger.run reads this to pick JFNK.
    gpu_active: bool,

    // =======================================================================
    // COLD — metadata, memos and handles; off the hot cache lines
    // =======================================================================

    // -- cold: constant-Jacobian baseline --
    g_base: []f64,
    c_base: []f64,

    // Capacitor-only nodes have charge-defined startup, not a unique static OP.
    needs_tran_op: bool = false,

    // -- cold: node metadata --
    // Flat intern table: nodeName(i) = intern_bytes[intern_offs[i]..intern_offs[i+1]].
    // intern_offs has n+1 entries; an empty slice (offs[i]==offs[i+1]) is a
    // branch-unknown (no netlist label). Read-only after freeze, by output
    // writers + error paths only. Replaces the per-node dupe + name→id hashmap.
    intern_bytes: []u8,
    intern_offs: []u32,

    // -- cold: structure --
    bbd: ?BbdInfo = null,
    solver_execution: @import("numerics").Execution = .{},
    /// Executor-owned parallel evaluation context. Null ⇒ serial eval.
    par_eval: ?*ParEval = null,
    /// Executor-owned persistent GPU context (mechanism in gpu.zig).
    /// Provides single-solve, batch
    /// Newton, batch frequency, and transient dispatch. Null ⇒ CPU only.
    gpu_hook: ?GpuHook = null,
    gpa: std.mem.Allocator,
    owns_topology: bool = true,
    progress: ?progress_api.Callback = null,

    // -- cold: linearization memo --
    /// "The four planes currently hold the linearization at this x_op." Set by
    /// `linearize` after it fills the planes; every writer of a plane or device
    /// parameter clears `valid`. Pointer identity is sound: x_op is the single
    /// arena slice the OP executor builds, handed read-only to each consumer.
    /// Read once per analysis start (cache-hit check) — cold, no hot-loop use.
    lin: struct { x_ptr: [*]const f64 = undefined, len: u32 = 0, valid: bool = false } = .{},

    // -- cold: lazily-built shared solve state --
    /// One symbolic LU + Newton scratch per circuit; every analysis shares it.
    ws: ?converger.Workspace = null,
    /// Memoized collectParams — ParamRef.ptr point into frozen batch
    /// instance storage, stable until deinit. No invalidation needed.
    param_refs: ?[]ParamRef = null,
    /// Parameters that take a different value in the frequency domain (a
    /// resistor's `ac=`). Filled by the engine after freeze; empty on every
    /// deck that does not spell one, which is the no-op fast path in
    /// `linearizeAc`. Storage is the sim arena, not `gpa`.
    ac_params: []AcParam = &.{},

    /// Shared Newton/JFNK workspace, built on first use. Pattern is frozen,
    /// so the symbolic LU stays valid for the circuit's lifetime.
    pub fn workspace(self: *Circuit) !*converger.Workspace {
        if (self.ws == null) self.ws = try converger.Workspace.init(self.gpa, self.n, self.col_ptr, self.row_idx, self.bbd);
        self.ws.?.slv.params.execution = self.solver_execution;
        return &self.ws.?;
    }

    pub fn checkpoint(self: *Circuit, event: progress_api.Event) error{QueryCancelled}!void {
        if (self.progress) |callback| try callback.checkpoint(event);
    }

    /// Consumes prepared storage, including on allocation failure.
    pub fn fromPrepared(prepared: Prepared) !Circuit {
        var owned = prepared;
        errdefer owned.deinit();
        return allocate(prepared, prepared.allocator, prepared.batches, true);
    }

    /// Shares immutable topology and creates independent device and solver state.
    /// The never-evaluated template must outlive this circuit.
    pub fn instantiate(template: *const Prepared, allocator: std.mem.Allocator) !Circuit {
        const batches = try allocator.alloc(Batch, template.batches.len);
        errdefer allocator.free(batches);
        var count: usize = 0;
        errdefer for (batches[0..count]) |batch| batch.hooks.deinit(batch.ctx, allocator);
        for (template.batches, batches) |source, *target| {
            target.* = try source.hooks.instantiate(source.ctx, allocator).unwrap();
            count += 1;
        }
        return allocate(template.*, allocator, batches, false);
    }

    /// Copy a completed dependency's evaluator state, borrowing the same topology.
    pub fn fromSnapshot(template: *const Prepared, source: *const Circuit, allocator: std.mem.Allocator) !Circuit {
        if (source.n != template.n or source.col_ptr.ptr != template.col_ptr.ptr)
            return error.IncompatibleDependency;
        const batches = try allocator.alloc(Batch, source.batches.len);
        errdefer allocator.free(batches);
        var count: usize = 0;
        errdefer for (batches[0..count]) |batch| batch.hooks.deinit(batch.ctx, allocator);
        for (source.batches, batches) |original, *target| {
            target.* = try original.hooks.snapshot(original.ctx, allocator).unwrap();
            count += 1;
        }
        return allocate(template.*, allocator, batches, false);
    }

    fn allocate(data: Prepared, allocator: std.mem.Allocator, batches: []Batch, owns_topology: bool) !Circuit {
        const g_vals = try allocator.alloc(f64, @as(usize, data.nnz) + 1);
        errdefer allocator.free(g_vals);
        const c_vals = try allocator.alloc(f64, @as(usize, data.nnz) + 1);
        errdefer allocator.free(c_vals);
        const rhs = try allocator.alloc(f64, @as(usize, data.n) + 1);
        errdefer allocator.free(rhs);
        const q_vec = try allocator.alloc(f64, @as(usize, data.n) + 1);
        @memset(c_vals, 0);
        @memset(q_vec, 0);
        return .{
            .gpa = allocator,
            .col_ptr = data.col_ptr,
            .row_idx = data.row_idx,
            .nnz = data.nnz,
            .trash_slot = data.nnz,
            .n = data.n,
            .g_vals = g_vals,
            .c_vals = c_vals,
            .rhs = rhs,
            .q_vec = q_vec,
            .diag_slots = data.diag_slots,
            .batches = batches,
            .current_row = data.current_row,
            .has_charge = data.has_charge,
            .has_state_q = data.has_state_q,
            .has_baseline = false,
            .gpu_active = false,
            .g_base = &.{},
            .c_base = &.{},
            .needs_tran_op = data.needs_tran_op,
            .intern_bytes = data.intern_bytes,
            .intern_offs = data.intern_offs,
            .bbd = data.bbd,
            .owns_topology = owns_topology,
        };
    }

    pub fn deinit(self: *Circuit) void {
        const gpa = self.gpa;
        if (self.ws) |*w| w.deinit(gpa);
        if (self.param_refs) |refs| gpa.free(refs);
        for (self.batches) |b| b.hooks.deinit(b.ctx, gpa);
        gpa.free(self.batches);
        gpa.free(self.g_vals);
        gpa.free(self.c_vals);
        // Unconditional: computeBaseline can fail mid-way leaving buffers
        // allocated with has_baseline=false; free is a no-op on &.{}.
        gpa.free(self.g_base);
        gpa.free(self.c_base);
        gpa.free(self.rhs);
        gpa.free(self.q_vec);
        if (self.owns_topology) {
            gpa.free(self.col_ptr);
            gpa.free(self.row_idx);
            gpa.free(self.diag_slots);
            gpa.free(self.current_row);
            if (self.bbd) |bbd| gpa.free(bbd.blocks);
            gpa.free(self.intern_bytes);
            gpa.free(self.intern_offs);
        }
        self.* = undefined;
    }

    /// View of this circuit's own value planes (the lane-0 / serial target).
    pub fn ownPlanes(self: *Circuit) Planes {
        return .{ .g_vals = self.g_vals, .c_vals = self.c_vals, .rhs = self.rhs, .q_vec = self.q_vec };
    }

    /// Length of the per-device-STATE charge tape: one entry per
    /// (instance, unknown) of every charge-carrying batch, laid out
    /// batch-major and indexed exactly like each batch's `rhs_idx`.
    ///
    /// Zero when nothing carries charge, and zero when a GPU plane-stamp hook
    /// is installed: `eval`/`evalNewton` then return before any host batch
    /// runs, so the host tapes would be stale. The transient reads a 0 here as
    /// "fall back to per-row LTE on the summed q plane" — the pre-existing
    /// behaviour, unchanged.
    pub fn qTapeLen(self: *const Circuit) u32 {
        if (self.gpu_hook) |gh| {
            if (gh.eval_planes != null) return 0;
        }
        var total: u32 = 0;
        for (self.batches) |b| {
            if (b.hooks.q_tape != null) total += b.count * b.n_u;
        }
        return total;
    }

    /// Copy the live per-state charges out of the batches into one flat buffer
    /// of `qTapeLen()` entries. O(device types) memcpys — each batch's tape is
    /// already contiguous, this only concatenates them.
    pub fn snapshotQTape(self: *const Circuit, dst: []f64) void {
        var off: usize = 0;
        for (self.batches) |b| {
            const f = b.hooks.q_tape orelse continue;
            const src = f(b.ctx);
            @memcpy(dst[off..][0..src.len], src);
            off += src.len;
        }
        std.debug.assert(off == dst.len);
    }

    /// Ground pin: applied once, after all batch stamps (and any reduction).
    fn groundStamp(self: *Circuit, x: []const f64) void {
        self.g_vals[self.diag_slots[0]] += 1.0;
        self.rhs[0] += x[0];
    }

    /// Stamp the planes for state `x` at time `t`.
    ///
    /// Both this and `evalNewton` route to the device when a GPU context is
    /// attached, and that is the ONLY place the GPU enters an analysis. Putting
    /// it here rather than behind a whole parallel Newton loop is what lets
    /// transient use the GPU at all: `tran.TranHook.assemble` calls
    /// `evalNewton` and then does its own companion-RHS math on the planes, so
    /// a GPU path that replaced the SOLVE would have skipped that math, while
    /// one that replaces only the STAMP composes with it untouched. Same for
    /// `combineGC`, limiting, history injection and every other host-side step
    /// layered on top of a stamp.
    ///
    /// For the GPU the two functions are the same work — `gpuEligible` admits
    /// no device with a `limit` decl, so `eval` and `eval_newton` agree — hence
    /// one hook for both.
    pub fn eval(self: *Circuit, x: []const f64, t: f64) void {
        // The memo names an x, and x_op is one stable arena slice — so a
        // direct eval at a DIFFERENT x (disto, matex, qpss, pss, pnoise,
        // pac, pxf, tran_noise all do this) would otherwise leave `valid`
        // true with planes that no longer hold the op linearization, and the
        // next `linearize(x_op)` would false-hit. `linearize` re-sets it.
        self.lin.valid = false;
        if (self.gpu_hook) |gh| if (gh.eval_planes) |ev| {
            ev(gh.ctx, x, t);
            return;
        };
        if (self.par_eval) |p| {
            p.eval(self.batches, self.ownPlanes(), self.has_charge, x, t);
            self.groundStamp(x);
            return;
        }
        zeroSimd(self.g_vals);
        if (self.has_charge) {
            zeroSimd(self.c_vals);
            @memset(self.q_vec, 0);
        }
        @memset(self.rhs, 0);
        const pl = self.ownPlanes();
        for (self.batches) |b| b.eval(b.ctx, &pl, 0, b.count, x, t);
        self.groundStamp(x);
    }

    /// Charges only at `x`: `q_vec` and every batch's `q_tape`, bit-for-bit what
    /// `eval` would leave there, with g_vals/c_vals/rhs untouched.
    ///
    /// For the transient's post-accept re-read (tran.zig), which consumes the
    /// charges and nothing else — the next step's first `evalNewton` restamps
    /// the other three planes. Falls back to the full pass only on the GPU: one
    /// fused kernel, no charge-only entry, so there is nothing to call.
    ///
    /// ParEval gets the charge-only pass too, through a `.charge` Mode that
    /// reuses the SAME lane cuts and reduce order `.full` uses — so the q plane
    /// is bit-for-bit what a threaded `eval` at this width would have left,
    /// which is the promise this function makes. It used to fall back here, and
    /// that cost the threaded transient a complete four-plane device pass per
    /// accepted timestep: +40-45% device-eval passes on the very decks threading
    /// was being judged on (docs/perf/pareval-evalq-2026-09-10.md).
    pub fn evalQ(self: *Circuit, x: []const f64, t: f64) void {
        if (self.gpu_hook != null) return self.eval(x, t);
        self.lin.valid = false; // q_vec is one of the four memoized planes
        if (self.par_eval) |p| return p.evalQ(self.batches, self.ownPlanes(), x, t);
        @memset(self.q_vec, 0);
        const pl = self.ownPlanes();
        for (self.batches) |b| if (b.hooks.eval_q) |f| f(b.ctx, &pl, 0, b.count, x, t);
    }

    /// Ensure the four planes hold the linearization at `x_op`, reusing them if
    /// they already do. The AC-family analyses (freq_solve/noise/sp/pz/stb) each
    /// linearize at the same engine op point; without this memo an op+ac+noise+pz
    /// deck runs four identical full device evals. Cache-miss path is
    /// `eval(x_op, 0)` — byte-identical to the direct call it replaces.
    pub fn linearize(self: *Circuit, x_op: []const f64) void {
        if (self.lin.valid and self.lin.x_ptr == x_op.ptr and self.lin.len == x_op.len) return;
        self.eval(x_op, 0);
        self.lin = .{ .x_ptr = x_op.ptr, .len = @intCast(x_op.len), .valid = true };
    }

    /// `linearize` for a FREQUENCY-domain analysis: ngspice's CKTacLoad rather
    /// than CKTload. A handful of card parameters take a different value there
    /// — today only a resistor's `ac=` (resload.c:60-62 stamps RESacConduct
    /// where resload's DC twin stamps RESconduct) — so the planes are filled
    /// with those swapped in and the DC values put straight back.
    ///
    /// The memo is deliberately left INVALID on the way out: the planes now
    /// hold the AC linearization, which a later DC/transient eval must not
    /// mistake for its own.
    pub fn linearizeAc(self: *Circuit, x_op: []const f64) !void {
        if (self.ac_params.len == 0) return self.linearize(x_op);
        for (self.ac_params) |*p| {
            p.saved = p.ptr.get();
            p.ptr.set(p.ac_value);
        }
        defer {
            for (self.ac_params) |*p| p.ptr.set(p.saved);
            self.recompute() catch {};
            self.lin.valid = false;
        }
        try self.recompute();
        self.lin.valid = false;
        self.eval(x_op, 0);
    }

    pub fn evalNewton(self: *Circuit, x: []const f64, t: f64) void {
        // Newton stamps the planes for an in-flight iterate, not the op point —
        // the linearization memo is now stale.
        self.lin.valid = false;
        // The device path deliberately ignores `has_baseline`. `g_base` holds
        // the constant contribution of EVERY batch, GPU-eligible ones included,
        // so starting from it and then letting the kernels stamp on top would
        // double-count them — the GPU sink has no `skip_g`. It zeroes and
        // restamps instead, which costs the baseline optimization and is why
        // `computeBaseline` is not worth suppressing when the GPU is live.
        if (self.gpu_hook) |gh| if (gh.eval_planes) |ev| {
            ev(gh.ctx, x, t);
            return;
        };
        self.evalNewtonCpu(x, t);
    }

    pub fn evalNewtonCpu(self: *Circuit, x: []const f64, t: f64) void {
        if (self.par_eval) |p| {
            p.evalNewton(self.batches, self.ownPlanes(), self.has_charge, self.has_baseline, self.g_base, self.c_base, x, t);
            self.groundStamp(x);
            return;
        }
        const pl = self.ownPlanes();
        if (self.has_baseline) {
            @memcpy(self.g_vals, self.g_base);
            if (self.has_charge) {
                @memcpy(self.c_vals, self.c_base);
                @memset(self.q_vec, 0);
            }
            @memset(self.rhs, 0);
            for (self.batches) |b| b.eval_newton(b.ctx, &pl, 0, b.count, x, t);
        } else {
            zeroSimd(self.g_vals);
            if (self.has_charge) {
                zeroSimd(self.c_vals);
                @memset(self.q_vec, 0);
            }
            @memset(self.rhs, 0);
            for (self.batches) |b| b.eval(b.ctx, &pl, 0, b.count, x, t);
        }
        self.groundStamp(x);
    }

    pub fn computeBaseline(self: *Circuit) !void {
        if (self.has_baseline) return;
        var any_const = false;
        for (self.batches) |b| {
            if (b.has_const_jacobian) {
                any_const = true;
                break;
            }
        }
        if (!any_const) return;

        if (self.g_base.len == 0) {
            self.g_base = try self.gpa.alloc(f64, self.nnz + 1);
            self.c_base = try self.gpa.alloc(f64, self.nnz + 1);
        }
        @memset(self.g_base, 0);
        @memset(self.c_base, 0);

        const x_zero = try self.gpa.alloc(f64, self.n + 1);
        defer self.gpa.free(x_zero);
        @memset(x_zero, 0);

        self.lin.valid = false; // stamps rhs/q_vec at x = 0
        @memset(self.rhs, 0);
        if (self.has_charge) @memset(self.q_vec, 0);
        const pl: Planes = .{ .g_vals = self.g_base, .c_vals = self.c_base, .rhs = self.rhs, .q_vec = self.q_vec };
        for (self.batches) |b| {
            if (b.has_const_jacobian) b.eval(b.ctx, &pl, 0, b.count, x_zero, 0);
        }
        self.g_base[self.diag_slots[0]] += 1.0;
        self.has_baseline = true;
    }

    /// ONE combined `G + alpha*C` entry. Same expression as `combineGC`'s
    /// scalar tail, so it agrees with the full pass entry-for-entry.
    ///
    /// Exists because the Newton residual gate reads a single diagonal per
    /// unknown. Doing that through `combineGC` rebuilt the entire plane once
    /// per unknown per iteration — O(n·nnz) where O(1) does — and on a linear
    /// RC ladder that was 34% of total runtime (47,084 full passes for 736
    /// Newton iterations, 62 unknowns).
    pub fn gcAt(self: *const Circuit, alpha: f64, slot: u32) f64 {
        return self.g_vals[slot] + alpha * self.c_vals[slot];
    }

    pub fn combineGC(self: *const Circuit, alpha: f64, out: []f64) void {
        std.debug.assert(out.len >= self.nnz);
        combinePlanes(std.simd.suggestVectorLength(f64) orelse 1, out[0..self.nnz], self.g_vals[0..self.nnz], self.c_vals[0..self.nnz], alpha);
    }

    pub fn denseG(self: *const Circuit, out: []f64) void {
        self.denseFrom(self.g_vals, out);
    }
    pub fn denseC(self: *const Circuit, out: []f64) void {
        self.denseFrom(self.c_vals, out);
    }

    fn denseFrom(self: *const Circuit, vals: []const f64, out: []f64) void {
        const n: usize = self.n;
        std.debug.assert(out.len >= n * n);
        @memset(out[0 .. n * n], 0);
        for (0..n) |j| {
            for (self.col_ptr[j]..self.col_ptr[j + 1]) |p| {
                out[@as(usize, self.row_idx[p]) * n + j] = vals[p];
            }
        }
    }

    pub fn findSlot(self: *const Circuit, row: u32, col: u32) ?u32 {
        // ponytail: reuse the frozen-pattern lookup used by device scatter tapes.
        const pattern: PatternView = .{
            .col_ptr = self.col_ptr,
            .row_idx = self.row_idx,
            .n = self.n,
            .trash_slot = self.trash_slot,
        };
        return pattern.findSlot(row, col);
    }

    pub fn applyLimits(self: *const Circuit, x: []f64, x_old: []const f64) bool {
        if (self.gpu_hook) |gh| if (gh.apply_limits) |f| return f(gh.ctx, x, x_old);
        var any_limited = false;
        for (self.batches) |b| if (b.hooks.apply_limits) |f| {
            if (f(b.ctx, x, x_old)) any_limited = true;
        };
        return any_limited;
    }

    /// SPICE MODEINITJCT equivalent: devices write junction seed voltages
    /// into a freshly zeroed x so iteration 1 linearizes at vcrit/vto instead
    /// of 0, and pnjlim/fetlim limit against the seed. Cold starts only.
    pub fn seedJunctions(self: *const Circuit, x: []f64) void {
        if (self.gpu_hook) |gh| if (gh.seed_junctions) |f| return f(gh.ctx, x);
        for (self.batches) |b| if (b.hooks.seed) |f| f(b.ctx, x);
    }

    /// Reset device-private limiting state; called when a Newton solve
    /// finishes so later evals (waveform, AC, noise) see the node vector.
    pub fn clearLimits(self: *const Circuit) void {
        if (self.gpu_hook) |gh| if (gh.clear_limits) |f| return f(gh.ctx);
        for (self.batches) |b| if (b.hooks.clear_limits) |f| f(b.ctx);
    }

    pub fn beginSolve(self: *Circuit) void {
        self.lin.valid = false;
        for (self.batches) |b| if (b.hooks.begin_solve) |f| f(b.ctx);
    }

    pub fn advanceIteration(self: *Circuit, previous_x: []const f64) void {
        self.lin.valid = false;
        for (self.batches) |b| if (b.hooks.advance_iteration) |f| f(b.ctx, previous_x);
    }

    pub fn checkConvergence(self: *const Circuit, x: []const f64) bool {
        for (self.batches) |b| if (b.hooks.check_convergence) |f| {
            if (!f(b.ctx, x)) return false;
        };
        return true;
    }

    pub fn updateStates(self: *const Circuit, x: []const f64) ?f64 {
        if (self.gpu_hook) |gh| if (gh.update_states) |f| return f(gh.ctx, x);
        var min_reject: ?f64 = null;
        for (self.batches) |b| {
            if (b.hooks.update_state) |f| if (f(b.ctx, x)) |tr| {
                min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
            };
        }
        return min_reject;
    }

    /// Accepted-step half of `updateStates`: the devices whose state is not
    /// revertible (no `stateCtl`), so it must not be written speculatively.
    /// The transient calls this exactly once per accepted point.
    pub fn commitStates(self: *const Circuit, x: []const f64) ?f64 {
        var min_reject: ?f64 = null;
        for (self.batches) |b| {
            if (b.hooks.commit_state) |f| if (f(b.ctx, x)) |tr| {
                min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
            };
        }
        return min_reject;
    }

    /// FSM accepted-state sync (switches). Returns true (for .query) when
    /// any device's working state differs from its last accepted state.
    pub fn stateCtl(self: *const Circuit, sop: StateCtlOp) bool {
        if (self.gpu_hook) |gh| if (gh.state_ctl) |f| return f(gh.ctx, sop);
        var dirty = false;
        for (self.batches) |b| if (b.hooks.state_ctl) |f| {
            if (f(b.ctx, sop)) dirty = true;
        };
        return dirty;
    }

    pub fn minDelay(self: *const Circuit) ?f64 {
        var min_td = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.min_delay) |f| {
            min_td = @min(min_td, f(b.ctx));
        };
        return if (min_td == std.math.inf(f64)) null else min_td;
    }

    /// §9.17.2 tightest `$bound_step` any device asked for, or null when none
    /// did. Only meaningful after an accepted step has run `updateStates`.
    pub fn boundStep(self: *const Circuit) ?f64 {
        var best = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.bound_step) |f| {
            best = @min(best, f(b.ctx));
        };
        return if (best == std.math.inf(f64)) null else best;
    }

    pub fn nextBreakpoint(self: *const Circuit, t: f64) ?f64 {
        var best = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.next_breakpoint) |f| {
            if (f(b.ctx, t)) |bp| best = @min(best, bp);
        };
        return if (best == std.math.inf(f64)) null else best;
    }

    /// Install temperature; call recompute before solving to check frozen topology.
    pub fn setCircuitTemp(self: *Circuit, temp_c: f32) void {
        self.lin.valid = false; // temp changes device physics
        for (self.batches) |b| if (b.hooks.set_temp) |f| f(b.ctx, temp_c);
        self.markGpuDirty();
    }

    /// Host device params changed — a resident GPU copy is now stale.
    fn markGpuDirty(self: *Circuit) void {
        if (self.gpu_hook) |gh| if (gh.mark_dirty) |f| f(gh.ctx);
    }

    /// Publish the host-owned simulation state (`$abstime`, timestep,
    /// `analysis()`, `initial_step`/`final_step`) to every device that reads
    /// it. Must run BEFORE the eval/Newton pass it describes — a generated
    /// device reads `Instance.abstime`, not the `t` argument of eval.
    /// O(instances), so call it per solve attempt, never per Newton iteration.
    pub fn setSimState(self: *const Circuit, st: device_ir.SimState) void {
        for (self.batches) |b| if (b.hooks.set_sim_state) |f| f(b.ctx, st);
    }

    /// Refresh numeric parameters; changed internal wiring requires rebuilding the circuit.
    /// On error, restore the parameters and recompute before reusing this circuit.
    pub fn recompute(self: *Circuit) error{TopologyChanged}!void {
        self.lin.valid = false; // param re-derivation (sweeps, dc, mc)
        self.has_baseline = false;
        self.markGpuDirty();
        for (self.batches) |b| if (b.hooks.recompute) |f| {
            if (!f(b.ctx)) return error.TopologyChanged;
        };
    }

    /// `recompute` restricted to the one device type whose parameters moved.
    ///
    /// A `.dc` point writes exactly one `ParamRef`, but `recompute` re-runs
    /// `D.precompute` and `D.collapse` for EVERY batch, and those hold the
    /// compact models' temperature/parameter blocks. Measured per sweep point
    /// on a `.dc` output characteristic: the BJT preamble ran 1,811 times on a
    /// ONE-instance deck, against 180 for all 180 instances of `fourbitadder`
    /// at setup.
    ///
    /// **Only sound while nothing global has moved.** A batch's `recompute`
    /// output depends on its own parameters and on temperature; the first is
    /// untouched by a sweep of a different device, and the second is the trap.
    /// An earlier attempt narrowed unconditionally and turned a topology error
    /// into a silent answer: `.dc` with an outer temperature loop sets the
    /// circuit temperature, a BJT whose `RB(T)` reaches zero re-wires its base
    /// node, and the narrow walk never visited the BJT batch to find out
    /// (`tests/builder.zig` "DC outer temperature topology error"). So the
    /// CALLER owns the distinction — `runSerial` takes the full walk on the
    /// first point of every inner sweep, which is the point right after the
    /// outer loop may have moved temperature, and narrows only thereafter.
    ///
    /// `Batch.type_name` is `@typeName(D)` (`vsource.Vsource`) while
    /// `ParamRef.device_type` is its last component (`Vsource`), so the match
    /// is on the tail. No match at all falls back to the full walk: a silently
    /// skipped re-derivation is a wrong answer, not a slow one.
    pub fn recomputeType(self: *Circuit, type_name: []const u8) error{TopologyChanged}!void {
        self.lin.valid = false;
        self.has_baseline = false;
        self.markGpuDirty();
        var hit = false;
        for (self.batches) |b| {
            const tail = if (std.mem.lastIndexOfScalar(u8, b.type_name, '.')) |d|
                b.type_name[d + 1 ..]
            else
                b.type_name;
            if (!std.mem.eql(u8, tail, type_name)) continue;
            hit = true;
            if (b.hooks.recompute) |f| {
                if (!f(b.ctx)) return error.TopologyChanged;
            }
        }
        if (!hit) for (self.batches) |b| {
            if (b.hooks.recompute) |f| {
                if (!f(b.ctx)) return error.TopologyChanged;
            }
        };
    }

    pub fn applyAttempt(self: *Circuit, lambda: f64) void {
        self.lin.valid = false; // homotopy scales device params
        for (self.batches) |b| if (b.hooks.apply_attempt) |f| f(b.ctx, lambda);
        self.markGpuDirty();
    }

    pub fn restoreModels(self: *Circuit) void {
        self.lin.valid = false; // undoes applyAttempt param scaling
        for (self.batches) |b| if (b.hooks.restore_models) |f| f(b.ctx);
        self.markGpuDirty();
    }

    /// Memoized — built once on first call, freed by deinit. Refs point
    /// into frozen batch instance storage, stable for the circuit lifetime.
    pub fn collectParams(self: *Circuit) ![]const ParamRef {
        if (self.param_refs) |refs| return refs;
        const gpa = self.gpa;
        var list: std.ArrayList(ParamRef) = .empty;
        errdefer list.deinit(gpa);
        for (self.batches) |b| try b.hooks.collect_params(b.ctx, gpa, &list).unwrap();
        self.param_refs = try list.toOwnedSlice(gpa);
        return self.param_refs.?;
    }

    /// Every device's noise generators at state vector `x`, PSDs included —
    /// each device's own `noisePsd`, never re-derived here. No temperature
    /// argument: the density a device returns already carries its instance's
    /// `$temperature`. Pure in `x`, so `.pnoise` calls it per PSS sample.
    pub fn collectNoiseSources(self: *const Circuit, x: []const f64, gpa: std.mem.Allocator) ![]NoiseSource {
        var list: std.ArrayList(NoiseSource) = .empty;
        errdefer list.deinit(gpa);
        for (self.batches) |b| if (b.hooks.collect_noise) |f| try f(b.ctx, x, gpa, &list).unwrap();
        return try list.toOwnedSlice(gpa);
    }

    /// Write directly into caller-owned frequency lanes. Failure leaves the
    /// destination available for a complete CPU overwrite.
    pub fn gpuFreqBatch(self: *Circuit, g: []const f64, c: []const f64, omegas: []const f64, rhs: []const f64, n: u32, adjoint: bool, output: []f64) ?void {
        const gh = self.gpu_hook orelse return null;
        const f = (if (adjoint) gh.freq_solve_adjoint_batch else gh.freq_solve_batch) orelse return null;
        std.debug.assert(output.len == omegas.len * 2 * @as(usize, n));
        f(gh.ctx, g, c, omegas, rhs, output, n) catch return null;
        return {};
    }

    pub fn nodeName(self: *const Circuit, node: u32) []const u8 {
        if (node + 1 < self.intern_offs.len)
            return self.intern_bytes[self.intern_offs[node]..self.intern_offs[node + 1]];
        return "";
    }
};

// ---------------------------------------------------------------------------
// init (freeze): build union sparsity pattern, allocate planes, precompute
// slot tapes. Protos consumed (finalized into batches, shells freed).
// Takes ownership of the flat intern table (intern_bytes + intern_offs).
// ---------------------------------------------------------------------------

pub fn init(
    gpa: std.mem.Allocator,
    n: u32,
    intern_bytes: []u8,
    intern_offs: []u32,
    protos: []const Proto,
    bbd: ?BbdInfo,
) !Circuit {
    return Circuit.fromPrepared(try Prepared.init(gpa, n, intern_bytes, intern_offs, protos, bbd));
}

// ---------------------------------------------------------------------------
// zeroSimd / copySimd live in problem/numerics.zig so files
// above and below Circuit share one copy. Re-exported for the 50+ callers.
// ---------------------------------------------------------------------------

pub const zeroSimd = @import("numerics").zeroSimd;
pub const copySimd = @import("numerics").copySimd;

/// Independent CSC entries: out = G + alpha*C. W=1 is also the tail and oracle.
pub fn combinePlanes(comptime W: usize, out: []f64, g: []const f64, c: []const f64, alpha: f64) void {
    std.debug.assert(out.len == g.len and out.len == c.len);
    const V = @Vector(W, f64);
    const scale: V = @splat(alpha);
    var i: usize = 0;
    while (i + W <= out.len) : (i += W) {
        const gv: V = g[i..][0..W].*;
        const cv: V = c[i..][0..W].*;
        out[i..][0..W].* = gv + scale * cv;
    }
    if (comptime W > 1) combinePlanes(1, out[i..], g[i..], c[i..], alpha);
}
