const std = @import("std");

const contract = @import("contract.zig");
pub const problem = @import("problem/problem.zig");
pub const converger = @import("helper/converger.zig");
pub const gpu_abi = @import("gpu_abi.zig");

// -- DC / Operating Point --
pub const op = @import("dc/op.zig");
pub const dc = @import("dc/dc.zig");
pub const tf = @import("dc/tf.zig");

// -- Frequency-domain (small-signal AC) --
pub const ac = @import("ac/ac.zig");
pub const noise = @import("ac/noise.zig");
pub const sp = @import("ac/sp.zig");
pub const stb = @import("ac/stb.zig");

// -- Time-domain --
pub const tran = @import("tran/tran.zig");
pub const tran_noise = @import("tran/tran_noise.zig");
pub const envelope = @import("tran/envelope.zig");

// -- Periodic steady-state / LPTV --
pub const pss = @import("pss/pss.zig");
pub const pac = @import("pss/pac.zig");
pub const pnoise = @import("pss/pnoise.zig");
pub const hb = @import("pss/hb.zig");

// -- Time→Frequency post-processing --
pub const four = @import("post/four.zig");
pub const disto = @import("post/disto.zig");

// -- Parameter sweep / statistical --
pub const sens = @import("sweep/sens.zig");
pub const mc = @import("sweep/mc.zig");
pub const temp_sweep = @import("sweep/temp_sweep.zig");

// -- Eigenvalue --
pub const pz = @import("eigen/pz.zig");

// -- Shared utilities --
pub const freq = @import("helper/freq.zig");
const meas = @import("helper/meas.zig");
pub const solvers = @import("solvers");

// ---------------------------------------------------------------------------
// Analysis dispatch: SPICE keyword → AnalysisId → module.run()
// ---------------------------------------------------------------------------

pub const AnalysisId = enum {
    ac,
    dc,
    disto,
    envelope,
    four,
    hb,
    mc,
    noise,
    op,
    pac,
    pnoise,
    pss,
    pz,
    sens,
    sp,
    stb,
    temp,
    tf,
    tran,
    tran_noise,

    pub fn Module(comptime self: AnalysisId) type {
        return switch (self) {
            .ac => ac,
            .dc => dc,
            .disto => disto,
            .envelope => envelope,
            .four => four,
            .hb => hb,
            .mc => mc,
            .noise => noise,
            .op => op,
            .pac => pac,
            .pnoise => pnoise,
            .pss => pss,
            .pz => pz,
            .sens => sens,
            .sp => sp,
            .stb => stb,
            .temp => temp_sweep,
            .tf => tf,
            .tran => tran,
            .tran_noise => tran_noise,
        };
    }
};

pub const Analysis = std.StaticStringMap(AnalysisId).initComptime(.{
    .{ "ac", .ac },
    .{ "dc", .dc },
    .{ "disto", .disto },
    .{ "envelope", .envelope },
    .{ "envlp", .envelope },
    .{ "four", .four },
    .{ "hb", .hb },
    .{ "mc", .mc },
    .{ "montecarlo", .mc },
    .{ "noise", .noise },
    .{ "op", .op },
    .{ "pac", .pac },
    .{ "pnoise", .pnoise },
    .{ "pss", .pss },
    .{ "pz", .pz },
    .{ "sens", .sens },
    .{ "sp", .sp },
    .{ "stb", .stb },
    .{ "temp", .temp },
    .{ "tf", .tf },
    .{ "tran", .tran },
    .{ "trannoise", .tran_noise },
    .{ "tran_noise", .tran_noise },
});

// ---------------------------------------------------------------------------
// Run context — everything an analysis needs, resolved before dispatch
// ---------------------------------------------------------------------------

pub const RunCtx = struct {
    circuit: *Circuit,
    x_op: ?[]f64,
    probes: []const u32,
    source_node: u32,
    source_branch: u32,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Uniform result — every analysis produces this
// ---------------------------------------------------------------------------

pub const Result = struct {
    plotname: []const u8,
    varnames: []const []const u8,
    is_complex: bool,
    npoints: usize,
    data: []const f64,
};

// ---------------------------------------------------------------------------
// Job — tagged union, each variant is that module's Options
// ---------------------------------------------------------------------------

pub const Job = union(AnalysisId) {
    ac: ac.Options,
    dc: dc.Options,
    disto: disto.Options,
    envelope: envelope.Options,
    four: four.Options,
    hb: hb.Options,
    mc: mc.Options,
    noise: noise.Options,
    op: op.Options,
    pac: pac.Options,
    pnoise: pnoise.Options,
    pss: pss.Options,
    pz: pz.Options,
    sens: sens.Options,
    sp: sp.Options,
    stb: stb.Options,
    temp: temp_sweep.Options,
    tf: tf.Options,
    tran: tran.Options,
    tran_noise: tran_noise.Options,
};

// ---------------------------------------------------------------------------
// Dispatch — n lines, one switch, pure function per analysis
// ---------------------------------------------------------------------------

pub fn run(ctx: *const RunCtx, job: Job) !Result {
    switch (job) {
        inline else => |opts, tag| return tag.Module().run(ctx, opts),
    }
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

pub const GROUND: u32 = 0;

/// Result varnames: optional scale var ("time"/"frequency"/sweep) followed by
/// "v(<label>)" per probe. One alloc for the slice, one per formatted name.
pub fn probeNames(ctx: *const RunCtx, first: ?[]const u8) ![]const []const u8 {
    const extra: usize = if (first == null) 0 else 1;
    const names = try ctx.allocator.alloc([]const u8, ctx.probes.len + extra);
    errdefer ctx.allocator.free(names);
    if (first) |name| names[0] = name;
    var done: usize = 0;
    errdefer for (names[extra..][0..done]) |s| ctx.allocator.free(s);
    for (ctx.probes, names[extra..]) |node, *out| {
        const label = ctx.circuit.nodeName(node);
        out.* = try std.fmt.allocPrint(ctx.allocator, "v({s})", .{if (label.len == 0) "?" else label});
        done += 1;
    }
    return names;
}

// ponytail: platform SIMD width — not hardcoded
const vec_width = std.simd.suggestVectorLength(f32) orelse 8;

// ---------------------------------------------------------------------------
// Circuit-facing types
// ---------------------------------------------------------------------------

pub const ParamRef = struct {
    ptr: *f32,
    device_type: []const u8,
    param_name: []const u8,
    index: u32,
    is_instance: bool,
    primary: bool,
};

pub const NoiseSource = struct {
    node_p: u32,
    node_n: u32,
    conductance: f64,
};

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

pub const NoiseGenKind = enum { thermal, shot, flicker };
pub const NoiseGen = struct { row: usize, col: usize, kind: NoiseGenKind };

pub const BbdBlock = solvers.BbdBlock;
pub const BbdInfo = solvers.BbdInfo;

/// Target value planes for one eval pass. Circuit.eval points this at its own
/// slices; parallel eval (par.zig) points lanes 1.. at private slabs and
/// reduces afterwards. computeBaseline points it at g_base/c_base directly.
pub const Planes = struct {
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,
};

/// Per-type device batch vtable. One entry per device TYPE, dispatched once
/// per eval. Created by batch.zig's freeze().
///
/// eval/eval_newton stamp instances [first..last) into `pl`; `lane` selects
/// the per-lane dedup cache (0 on the serial path).
pub const Batch = struct {
    // -- hot: the only fields the eval dispatch loop reads --
    ctx: *anyopaque,
    eval: *const fn (*anyopaque, *const Planes, lane: u32, first: u32, last: u32, []const f64, f64) void,
    eval_newton: *const fn (*anyopaque, *const Planes, lane: u32, first: u32, last: u32, []const f64, f64) void,
    count: u32,
    /// Terminals per instance; per-instance eval cost scales ~n_u².
    n_u: u32,
    has_charge: bool,
    has_const_jacobian: bool,
    /// False when eval uses shared per-batch scratch — such a batch must run
    /// whole on one lane.
    thread_safe: bool,

    // -- cold --
    type_name: []const u8,
    /// GPU kind (0 ⇒ not GPU-eligible); must match the megakernel's
    /// comptime dispatch.
    gpu_kind_id: u32 = 0,
    /// Everything dispatched outside the eval loop: one static table per
    /// device TYPE (comptime const in DeviceBatch(D)), zero per-batch bytes.
    hooks: *const Hooks,
};

/// Cold per-device-type vtable. Null entry ⇒ device type lacks the hook.
pub const Hooks = struct {
    /// Grow per-lane dedup caches to n_lanes. Null when the batch has none.
    set_lanes: ?*const fn (*anyopaque, std.mem.Allocator, u32) anyerror!void = null,
    /// Scatter footprint of instances [first..last): {slot_lo, slot_hi_excl,
    /// row_lo, row_hi_excl}, entries equal to the passed trash slot/row
    /// (ground writes) excluded. Lets parallel eval zero and reduce only the
    /// touched window of a lane's private planes.
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    /// Reset private limiting state after a Newton solve finishes.
    clear_limits: ?*const fn (*anyopaque) void = null,
    /// SPICE MODEINITJCT: write junction seed voltages into a cold-started x.
    seed: ?*const fn (*anyopaque, []f64) void = null,
    /// Mark unknowns that are MNA branch currents (not node voltages) so the
    /// converger can apply abstol vs vntol per row (ngspice NIconvTest).
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    record_history: ?*const fn (*anyopaque, []const f64, f64) void = null,
    inject_history: ?*const fn (*anyopaque, f64, []f64) void = null,
    min_delay: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) anyerror!void,
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) anyerror!void = null,
    recompute: ?*const fn (*anyopaque) void = null,
    apply_attempt: ?*const fn (*anyopaque, f64) void = null,
    restore_models: ?*const fn (*anyopaque) void = null,
    gpu_pack_size: ?*const fn (*anyopaque) usize = null,
    /// Serialize tapes+params into `dest` (blob-relative base at `base_off`),
    /// returning the filled BatchDesc.
    gpu_pack: ?*const fn (*anyopaque, dest: []u8, base_off: u32, n: u32) gpu_abi.BatchDesc = null,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Engine-owned GPU solve surface: one whole Newton solve per call —
/// 1 kernel launch + 1 readback. Errors fall back to the CPU path.
pub const GpuHook = struct {
    ctx: *anyopaque,
    solve_newton: *const fn (*anyopaque, x: []f64, t: f64, opts: converger.Options) anyerror!converger.Result,
    /// Whole transient analysis on-device (chunked cooperative launches).
    /// Appends accepted points into `waveform`; on error the caller truncates
    /// the waveform back and falls through to the CPU integrator.
    simulate_tran: ?*const fn (*anyopaque, x: []f64, probes: []const u32, waveform: *tran.Waveform, options: tran.Options) anyerror!tran.SimResult = null,
};

// ---------------------------------------------------------------------------
// Circuit: frozen, analysis-facing representation.
//
//   pattern:  col_ptr / row_idx  (CSC, frozen at compile)
//   planes:   g_vals (dI/dx), c_vals (dQ/dx), rhs (I residual), q_vec (Q)
//   eval():   one pass fills all four
//
// Every analysis is an affine consumer of the planes:
//   DC   A = G;   TRAN  A = G + a*C;   AC  A = G + jwC.
// ---------------------------------------------------------------------------
pub const Circuit = struct {
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

    // -- flags --
    has_charge: bool,
    has_history: bool,
    has_baseline: bool,
    /// Set by engine when --gpu is active and circuit is GPU-eligible.
    /// converger.run reads this to pick JFNK.
    gpu_active: bool,
    /// Engine-owned whole-solve GPU hook (mechanism in src/gpu_solver.zig,
    /// same ownership pattern as par_eval). Null ⇒ CPU paths only.
    gpu_hook: ?GpuHook = null,

    // -- cold: constant-Jacobian baseline --
    g_base: []f64,
    c_base: []f64,

    // -- cold: node metadata --
    node_names: std.StringHashMapUnmanaged(u32),
    node_labels: [][]const u8,

    // -- cold: structure --
    bbd: ?BbdInfo = null,
    /// Reference to the engine-owned parallel eval context (mechanism lives
    /// in par.zig, ownership in src/engine.zig). Null ⇒ serial eval.
    par_eval: ?*problem.ParEval = null,
    gpa: std.mem.Allocator,

    // -- cold: lazily-built shared solve state --
    /// One symbolic LU + Newton scratch per circuit; every analysis shares it.
    ws: ?converger.Workspace = null,
    /// Memoized collectParams — ParamRef.ptr point into frozen batch
    /// instance storage, stable until deinit. No invalidation needed.
    param_refs: ?[]ParamRef = null,

    /// Shared Newton/JFNK workspace, built on first use. Pattern is frozen,
    /// so the symbolic LU stays valid for the circuit's lifetime.
    pub fn workspace(self: *Circuit) !*converger.Workspace {
        if (self.ws == null) self.ws = try converger.Workspace.init(self.gpa, self);
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
        for (self.node_labels) |label| {
            if (!std.mem.eql(u8, label, "0")) gpa.free(label);
        }
        gpa.free(self.node_labels);
        self.node_names.deinit(gpa);
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

    pub fn eval(self: *Circuit, x: []const f64, t: f64) void {
        if (self.par_eval) |p| return p.eval(self, x, t);
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
        if (self.par_eval) |p| return p.evalNewton(self, x, t);
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
        @constCast(self).combineGCInner(alpha, out, false);
    }

    pub fn combineGCAndClear(self: *Circuit, alpha: f64, out: []f64) void {
        self.combineGCInner(alpha, out, true);
    }

    fn combineGCInner(self: *Circuit, alpha: f64, out: []f64, comptime clear: bool) void {
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

    pub fn setCircuitTemp(self: *const Circuit, temp_c: f32) void {
        for (self.batches) |b| if (b.hooks.set_temp) |f| f(b.ctx, temp_c);
    }

    pub fn recompute(self: *const Circuit) void {
        for (self.batches) |b| if (b.hooks.recompute) |f| f(b.ctx);
    }

    pub fn applyAttempt(self: *const Circuit, lambda: f64) void {
        for (self.batches) |b| if (b.hooks.apply_attempt) |f| f(b.ctx, lambda);
    }

    pub fn restoreModels(self: *const Circuit) void {
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

    pub fn nodeName(self: *const Circuit, node: u32) []const u8 {
        if (node < self.node_labels.len and self.node_labels[node].len != 0)
            return self.node_labels[node];
        return "";
    }

    pub fn voltageNodeCount(self: *const Circuit) u32 {
        return @intCast(self.node_labels.len);
    }
};

pub fn zeroSimd(buf: []f64) void {
    const W = vec_width;
    const V = @Vector(W, f64);
    const zero: V = @splat(0.0);
    var i: usize = 0;
    while (i + W <= buf.len) : (i += W) buf[i..][0..W].* = zero;
    for (buf[i..]) |*v| v.* = 0;
}

// ---------------------------------------------------------------------------
// Contract: every analysis is a pure fn run(*const RunCtx, Options) !Result
// ---------------------------------------------------------------------------

comptime {
    for (@typeInfo(AnalysisId).@"enum".fields) |f|
        contract.validate(@field(AnalysisId, f.name).Module());
}

// std.testing.refAllDeclsRecursive was removed in Zig 0.16; local equivalent
// so every referenced file's tests are still collected.
fn refAllDeclsRecursive(comptime T: type) void {
    if (!@import("builtin").is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

test {
    refAllDeclsRecursive(@This());
    _ = problem;
    _ = @import("helper/converger.zig");
    _ = @import("helper/meas.zig");
}
