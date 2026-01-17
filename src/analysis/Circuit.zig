//! Circuit: frozen, analysis-facing representation.
//!
//! Consolidates the Circuit struct (root.zig), freeze logic (problem.zig),
//! and GPU packing (gpu.zig) into one self-contained file.
//!
//!   pattern:  col_ptr / row_idx  (CSC, frozen at compile)
//!   planes:   g_vals (dI/dx), c_vals (dQ/dx), rhs (I residual), q_vec (Q)
//!   eval():   one pass fills all four
//!
//! Every analysis is an affine consumer of the planes:
//!   DC   A = G;   TRAN  A = G + a*C;   AC  A = G + jwC.

const std = @import("std");
const devices = @import("devices");
const solvers = @import("solvers");
// Leaf types only (Waveform/Options/SimResult) — importing the transient
// driver here would close a cycle: tran.zig -> ../types.zig -> Circuit.zig.
const tran = @import("tran/types.zig");

const Batch = devices.batch.Batch;
const Hooks = devices.batch.Hooks;
const Planes = devices.batch.Planes;
const ParamRef = devices.batch.ParamRef;
const NoiseSource = devices.batch.NoiseSource;
const StateCtlOp = devices.batch.StateCtlOp;
const PatternBuilder = devices.batch.PatternBuilder;
const PatternView = devices.batch.PatternView;
const Proto = devices.batch.Proto;
const ParEval = devices.par.ParEval;
const converger = solvers.converger;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const GROUND: u32 = 0;

// ponytail: platform SIMD width — not hardcoded
const vec_width = std.simd.suggestVectorLength(f32) orelse 8;

// ---------------------------------------------------------------------------
// Re-exports from solvers
// ---------------------------------------------------------------------------

pub const BbdBlock = solvers.BbdBlock;
pub const BbdInfo = solvers.BbdInfo;

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
    /// Repack device-resident payloads after parameter mutation (sweeps).
    repack: ?*const fn (*anyopaque) anyerror!void = null,
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
    has_history: bool,
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

    // -- cold: node metadata --
    // Flat intern table: nodeName(i) = intern_bytes[intern_offs[i]..intern_offs[i+1]].
    // intern_offs has n+1 entries; an empty slice (offs[i]==offs[i+1]) is a
    // branch-unknown (no netlist label). Read-only after freeze, by output
    // writers + error paths only. Replaces the per-node dupe + name→id hashmap.
    intern_bytes: []u8,
    intern_offs: []u32,

    // -- cold: structure --
    bbd: ?BbdInfo = null,
    /// Reference to the engine-owned parallel eval context (mechanism lives
    /// in par.zig, ownership in src/engine.zig). Null ⇒ serial eval.
    par_eval: ?*ParEval = null,
    /// Engine-owned persistent GPU context (mechanism in src/gpu_context.zig,
    /// same ownership pattern as par_eval). Provides single-solve, batch
    /// Newton, batch frequency, and transient dispatch. Null ⇒ CPU only.
    gpu_hook: ?GpuHook = null,
    gpa: std.mem.Allocator,

    // -- cold: linearization memo --
    /// "The four planes currently hold the linearization at this x_op." Set by
    /// `linearize` after it fills the planes; every writer of a plane or device
    /// parameter clears `valid`. Pointer identity is sound: x_op is the single
    /// arena slice engine.ensureOp builds, handed read-only to each analysis.
    /// Read once per analysis start (cache-hit check) — cold, no hot-loop use.
    lin: struct { x_ptr: [*]const f64 = undefined, len: u32 = 0, valid: bool = false } = .{},

    // -- cold: lazily-built shared solve state --
    /// One symbolic LU + Newton scratch per circuit; every analysis shares it.
    ws: ?converger.Workspace = null,
    /// Memoized collectParams — ParamRef.ptr point into frozen batch
    /// instance storage, stable until deinit. No invalidation needed.
    param_refs: ?[]ParamRef = null,

    /// Total bytes consumed by this circuit's frozen representation.
    /// Used for GPU memory budgeting — the shared prefix of the device
    /// blob is approximately this size minus the metadata overhead.
    pub const MemoryFootprint = struct {
        pattern_bytes: usize, // col_ptr + row_idx
        planes_bytes: usize, // g_vals + c_vals + rhs + q_vec
        baseline_bytes: usize, // g_base + c_base (0 if no baseline)
        batch_bytes: usize, // Batch[] array
        metadata_bytes: usize, // diag_slots + current_row + intern table
        total_bytes: usize,
    };

    pub fn memoryFootprint(self: *const Circuit) MemoryFootprint {
        const n: usize = self.n;
        const nnz: usize = self.nnz;
        const pattern = (n + 1) * @sizeOf(u32) + nnz * @sizeOf(u32);
        const planes = 4 * (nnz + 1) * @sizeOf(f64); // g, c, rhs(n+1), q(n+1) — rhs/q are n+1
        const baseline: usize = if (self.has_baseline) 2 * (nnz + 1) * @sizeOf(f64) else 0;
        const batch = self.batches.len * @sizeOf(Batch);
        const meta = n * @sizeOf(u32) + n * @sizeOf(bool) +
            self.intern_bytes.len + self.intern_offs.len * @sizeOf(u32);
        const total = pattern + planes + baseline + batch + meta;
        return .{
            .pattern_bytes = pattern,
            .planes_bytes = planes,
            .baseline_bytes = baseline,
            .batch_bytes = batch,
            .metadata_bytes = meta,
            .total_bytes = total,
        };
    }

    /// Shared Newton/JFNK workspace, built on first use. Pattern is frozen,
    /// so the symbolic LU stays valid for the circuit's lifetime.
    pub fn workspace(self: *Circuit) !*converger.Workspace {
        if (self.ws == null) self.ws = try converger.Workspace.init(self.gpa, self.n, self.col_ptr, self.row_idx, self.bbd);
        return &self.ws.?;
    }

    pub fn deinit(self: *Circuit) void {
        const gpa = self.gpa;
        if (self.ws) |*w| w.deinit(gpa);
        if (self.param_refs) |refs| gpa.free(refs);
        for (self.batches) |b| b.hooks.deinit(b.ctx, gpa);
        gpa.free(self.batches);
        gpa.free(self.col_ptr);
        gpa.free(self.row_idx);
        gpa.free(self.g_vals);
        gpa.free(self.c_vals);
        // Unconditional: computeBaseline can fail mid-way leaving buffers
        // allocated with has_baseline=false; free is a no-op on &.{}.
        gpa.free(self.g_base);
        gpa.free(self.c_base);
        gpa.free(self.rhs);
        gpa.free(self.q_vec);
        gpa.free(self.diag_slots);
        gpa.free(self.current_row);
        if (self.bbd) |bbd| gpa.free(bbd.blocks);
        gpa.free(self.intern_bytes);
        gpa.free(self.intern_offs);
        self.* = undefined;
    }

    /// View of this circuit's own value planes (the lane-0 / serial target).
    pub fn ownPlanes(self: *Circuit) Planes {
        return .{ .g_vals = self.g_vals, .c_vals = self.c_vals, .rhs = self.rhs, .q_vec = self.q_vec };
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
        if (self.gpu_hook) |gh| if (gh.eval_planes) |ev| {
            ev(gh.ctx, x, t);
            return;
        };
        self.evalCpu(x, t);
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

    pub fn evalCpu(self: *Circuit, x: []const f64, t: f64) void {
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
        for (self.batches) |b| b.eval(b.ctx, &pl, 0, 0, b.count, x, t);
        self.groundStamp(x);
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
            for (self.batches) |b| b.eval_newton(b.ctx, &pl, 0, 0, b.count, x, t);
        } else {
            zeroSimd(self.g_vals);
            if (self.has_charge) {
                zeroSimd(self.c_vals);
                @memset(self.q_vec, 0);
            }
            @memset(self.rhs, 0);
            for (self.batches) |b| b.eval(b.ctx, &pl, 0, 0, b.count, x, t);
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

        @memset(self.rhs, 0);
        if (self.has_charge) @memset(self.q_vec, 0);
        const pl: Planes = .{ .g_vals = self.g_base, .c_vals = self.c_base, .rhs = self.rhs, .q_vec = self.q_vec };
        for (self.batches) |b| {
            if (b.has_const_jacobian) b.eval(b.ctx, &pl, 0, 0, b.count, x_zero, 0);
        }
        self.g_base[self.diag_slots[0]] += 1.0;
        self.has_baseline = true;
    }

    pub fn combineGC(self: *const Circuit, alpha: f64, out: []f64) void {
        self.combineGCInner(alpha, out, false);
    }

    pub fn combineGCAndClear(self: *Circuit, alpha: f64, out: []f64) void {
        self.combineGCInner(alpha, out, true);
    }

    // *const is honest for both paths: the clear branch writes plane
    // CONTENTS through the g/c slices (separately-owned storage), never the
    // struct itself.
    fn combineGCInner(self: *const Circuit, alpha: f64, out: []f64, comptime clear: bool) void {
        std.debug.assert(out.len >= self.nnz);
        const W = vec_width;
        const V = @Vector(W, f64);
        const av: V = @splat(alpha);
        const zero: V = @splat(0.0);
        const g = self.g_vals;
        const c = self.c_vals;
        var i: usize = 0;
        while (i + W <= self.nnz) : (i += W) {
            const gv: V = g[i..][0..W].*;
            const cv: V = c[i..][0..W].*;
            out[i..][0..W].* = gv + av * cv;
            if (clear) {
                g[i..][0..W].* = zero;
                c[i..][0..W].* = zero;
            }
        }
        while (i < self.nnz) : (i += 1) {
            out[i] = g[i] + alpha * c[i];
            if (clear) {
                g[i] = 0;
                c[i] = 0;
            }
        }
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
        var lo = self.col_ptr[col];
        var hi = self.col_ptr[col + 1];
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.row_idx[mid] < row) lo = mid + 1 else hi = mid;
        }
        if (lo < self.col_ptr[col + 1] and self.row_idx[lo] == row) return lo;
        return null;
    }

    pub fn applyLimits(self: *const Circuit, x: []f64, x_old: []const f64) bool {
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
        for (self.batches) |b| if (b.hooks.seed) |f| f(b.ctx, x);
    }

    /// Reset device-private limiting state; called when a Newton solve
    /// finishes so later evals (waveform, AC, noise) see the node vector.
    pub fn clearLimits(self: *const Circuit) void {
        for (self.batches) |b| if (b.hooks.clear_limits) |f| f(b.ctx);
    }

    pub fn updateStates(self: *const Circuit, x: []const f64) ?f64 {
        var min_reject: ?f64 = null;
        for (self.batches) |b| {
            if (b.hooks.update_state) |f| if (f(b.ctx, x)) |tr| {
                min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
            };
        }
        return min_reject;
    }

    /// FSM accepted-state sync (switches). Returns true (for .query) when
    /// any device's working state differs from its last accepted state.
    pub fn stateCtl(self: *const Circuit, sop: StateCtlOp) bool {
        var dirty = false;
        for (self.batches) |b| if (b.hooks.state_ctl) |f| {
            if (f(b.ctx, sop)) dirty = true;
        };
        return dirty;
    }

    pub fn recordHistory(self: *Circuit, x: []const f64, t: f64) void {
        for (self.batches) |b| if (b.hooks.record_history) |f| f(b.ctx, x, t);
    }

    pub fn injectHistory(self: *Circuit, t: f64) void {
        for (self.batches) |b| if (b.hooks.inject_history) |f| f(b.ctx, t, self.rhs);
    }

    pub fn minDelay(self: *const Circuit) ?f64 {
        var min_td = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.min_delay) |f| {
            min_td = @min(min_td, f(b.ctx));
        };
        return if (min_td == std.math.inf(f64)) null else min_td;
    }

    pub fn nextBreakpoint(self: *const Circuit, t: f64) ?f64 {
        var best = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.next_breakpoint) |f| {
            if (f(b.ctx, t)) |bp| best = @min(best, bp);
        };
        return if (best == std.math.inf(f64)) null else best;
    }

    pub fn setCircuitTemp(self: *Circuit, temp_c: f32) void {
        self.lin.valid = false; // temp changes device physics
        for (self.batches) |b| if (b.hooks.set_temp) |f| f(b.ctx, temp_c);
    }

    /// Publish the host-owned simulation state (`$abstime`, timestep,
    /// `analysis()`, `initial_step`/`final_step`) to every device that reads
    /// it. Must run BEFORE the eval/Newton pass it describes — a generated
    /// device reads `Instance.abstime`, not the `t` argument of eval.
    /// O(instances), so call it per solve attempt, never per Newton iteration.
    pub fn setSimState(self: *const Circuit, st: devices.batch.SimState) void {
        for (self.batches) |b| if (b.hooks.set_sim_state) |f| f(b.ctx, st);
    }

    pub fn recompute(self: *Circuit) void {
        self.lin.valid = false; // param re-derivation (sweeps, dc, mc)
        for (self.batches) |b| if (b.hooks.recompute) |f| f(b.ctx);
    }

    pub fn applyAttempt(self: *Circuit, lambda: f64) void {
        self.lin.valid = false; // homotopy scales device params
        for (self.batches) |b| if (b.hooks.apply_attempt) |f| f(b.ctx, lambda);
    }

    pub fn restoreModels(self: *Circuit) void {
        self.lin.valid = false; // undoes applyAttempt param scaling
        for (self.batches) |b| if (b.hooks.restore_models) |f| f(b.ctx);
    }

    /// Memoized — built once on first call, freed by deinit. Refs point
    /// into frozen batch instance storage, stable for the circuit lifetime.
    pub fn collectParams(self: *Circuit) ![]const ParamRef {
        if (self.param_refs) |refs| return refs;
        const gpa = self.gpa;
        var list: std.ArrayList(ParamRef) = .empty;
        errdefer list.deinit(gpa);
        for (self.batches) |b| try b.hooks.collect_params(b.ctx, gpa, &list);
        self.param_refs = try list.toOwnedSlice(gpa);
        return self.param_refs.?;
    }

    pub fn collectNoiseSources(self: *const Circuit, x_op: []const f64, gpa: std.mem.Allocator) ![]NoiseSource {
        var list: std.ArrayList(NoiseSource) = .empty;
        errdefer list.deinit(gpa);
        for (self.batches) |b| if (b.hooks.collect_noise) |f| try f(b.ctx, x_op, gpa, &list);
        return try list.toOwnedSlice(gpa);
    }

    /// Freq-sweep GPU dispatch: one flat blob of `omegas.len * 2n` f64 (lane k at
    /// [k*2n..][0..2n], real‖imag), solved via the gpu_hook's freq_solve_batch
    /// (or adjoint) in a single launch. Returns null on ANY failure (missing
    /// hook, alloc, kernel error) so callers `orelse` into their serial path.
    /// Caller frees the returned blob.
    pub fn gpuFreqBatch(self: *Circuit, a: std.mem.Allocator, g: []const f64, c: []const f64, omegas: []const f64, rhs: []const f64, n: u32, adjoint: bool) ?[]f64 {
        const gh = self.gpu_hook orelse return null;
        const f = (if (adjoint) gh.freq_solve_adjoint_batch else gh.freq_solve_batch) orelse return null;
        const nn = 2 * @as(usize, n);
        const blob = a.alloc(f64, omegas.len * nn) catch return null;
        f(gh.ctx, g, c, omegas, rhs, blob, n) catch {
            a.free(blob);
            return null;
        };
        return blob;
    }

    pub fn nodeName(self: *const Circuit, node: u32) []const u8 {
        if (node + 1 < self.intern_offs.len)
            return self.intern_bytes[self.intern_offs[node]..self.intern_offs[node + 1]];
        return "";
    }

    /// Reverse map name→id. Cold: called at job-build time only (one lookup per
    /// name-carrying directive), so a linear scan over the intern table beats
    /// carrying a hashmap into the frozen struct. Empty slices (branch
    /// unknowns) never match a non-empty query.
    pub fn nodeIndex(self: *const Circuit, name: []const u8) ?u32 {
        var i: u32 = 0;
        while (i + 1 < self.intern_offs.len) : (i += 1) {
            if (std.mem.eql(u8, self.intern_bytes[self.intern_offs[i]..self.intern_offs[i + 1]], name))
                return i;
        }
        return null;
    }

    pub fn voltageNodeCount(self: *const Circuit) u32 {
        return self.n;
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
    var pb: PatternBuilder = .{};
    defer pb.deinit(gpa);
    try pb.reserve(gpa, n);
    for (0..n) |i| try pb.add(gpa, @intCast(i), @intCast(i));
    for (protos) |p| try p.pattern(p.ctx, gpa, &pb);

    var ckt: Circuit = undefined;
    ckt.gpa = gpa;
    ckt.n = n;
    ckt.intern_bytes = intern_bytes;
    ckt.intern_offs = intern_offs;
    ckt.has_charge = false;
    ckt.has_history = false;
    ckt.has_baseline = false;
    ckt.gpu_active = false;
    ckt.g_base = &.{};
    ckt.c_base = &.{};
    ckt.bbd = bbd;
    ckt.par_eval = null;
    ckt.ws = null;
    ckt.param_refs = null;
    ckt.gpu_hook = null;

    ckt.nnz = try pb.toCsc(gpa, n, &ckt.col_ptr, &ckt.row_idx);
    errdefer gpa.free(ckt.col_ptr);
    errdefer gpa.free(ckt.row_idx);
    ckt.trash_slot = ckt.nnz;
    ckt.g_vals = try gpa.alloc(f64, ckt.nnz + 1);
    errdefer gpa.free(ckt.g_vals);
    ckt.c_vals = try gpa.alloc(f64, ckt.nnz + 1);
    errdefer gpa.free(ckt.c_vals);
    ckt.rhs = try gpa.alloc(f64, @as(usize, n) + 1);
    errdefer gpa.free(ckt.rhs);
    ckt.q_vec = try gpa.alloc(f64, @as(usize, n) + 1);
    errdefer gpa.free(ckt.q_vec);
    // eval() only re-zeroes c_vals/q_vec when has_charge; chargeless
    // circuits must still expose an exact C = 0 plane (pz/stb/ac read it).
    @memset(ckt.c_vals, 0);
    @memset(ckt.q_vec, 0);

    ckt.diag_slots = try gpa.alloc(u32, n);
    errdefer gpa.free(ckt.diag_slots);
    for (0..n) |i| ckt.diag_slots[i] = ckt.findSlot(@intCast(i), @intCast(i)).?;

    const pv: PatternView = .{
        .col_ptr = ckt.col_ptr,
        .row_idx = ckt.row_idx,
        .n = ckt.n,
        .trash_slot = ckt.trash_slot,
    };

    const batches = try gpa.alloc(Batch, protos.len);
    errdefer gpa.free(batches);
    var n_final: usize = 0;
    errdefer for (batches[0..n_final]) |b| b.hooks.deinit(b.ctx, gpa);
    for (protos, 0..) |p, bi| {
        batches[bi] = try p.finalize(p.ctx, gpa, pv);
        n_final = bi + 1;
        if (batches[bi].has_charge) ckt.has_charge = true;
        if (batches[bi].hooks.inject_history != null) ckt.has_history = true;
    }
    ckt.batches = batches;

    // Row-kind mask: branch-current unknowns get abstol, node voltages get
    // vntol in the converger (ngspice NIconvTest split).
    ckt.current_row = try gpa.alloc(bool, n);
    @memset(ckt.current_row, false);
    for (batches) |b| if (b.hooks.mark_current_rows) |f| f(b.ctx, ckt.current_row);

    // Protos consumed: instance data moved into batches, shells freed.
    for (protos) |p| p.destroy(p.ctx, gpa);
    return ckt;
}


// ---------------------------------------------------------------------------
// probeNames: optional scale var + "v(<label>)" per probe node
// ---------------------------------------------------------------------------

pub fn probeNames(circuit: *const Circuit, probes: []const u32, allocator: std.mem.Allocator, first: ?[]const u8) ![]const []const u8 {
    const extra: usize = if (first == null) 0 else 1;
    const names = try allocator.alloc([]const u8, probes.len + extra);
    errdefer allocator.free(names);
    if (first) |name| names[0] = name;
    var done: usize = 0;
    errdefer for (names[extra..][0..done]) |s| allocator.free(s);
    for (probes, names[extra..]) |node, *out| {
        const label = circuit.nodeName(node);
        out.* = try std.fmt.allocPrint(allocator, "v({s})", .{if (label.len == 0) "?" else label});
        done += 1;
    }
    return names;
}

// ---------------------------------------------------------------------------
// zeroSimd / copySimd live in solvers/types.zig (the DAG leaf) so files
// above and below Circuit share one copy. Re-exported for the 50+ callers.
// ---------------------------------------------------------------------------

pub const zeroSimd = solvers.types.zeroSimd;
pub const copySimd = solvers.types.copySimd;
