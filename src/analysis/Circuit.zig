//! The analysis-side circuit: a frozen CSC pattern plus four value planes
//! (g = dI/dx, c = dQ/dx, rhs = I, q = Q) that one device pass fills. Every
//! analysis is an affine consumer of the planes: DC solves G, transient
//! G + a*C, AC G + jwC.

const std = @import("std");
const device_ir = @import("device").abi;
const Prepared = @import("device").Circuit;
const progress_api = @import("progress.zig");
const par_eval = @import("par_eval.zig");
const converger = @import("solver").converger;
const freq_solve = @import("solver").freq_solve;
const numerics = @import("core").numerics;

const Batch = device_ir.Batch;
const Planes = device_ir.Planes;
const ParamRef = device_ir.ParamRef;
const NoiseSource = device_ir.NoiseSource;
const StateCtlOp = device_ir.StateCtlOp;
const ParEval = par_eval.ParEval;
const BbdInfo = numerics.BbdInfo;

pub const zeroSimd = numerics.zeroSimd;
pub const copySimd = numerics.copySimd;

/// Row and column index of the ground node in every pattern.
pub const GROUND: u32 = 0;

/// A card parameter with a separate frequency-domain value, such as a
/// resistor's `ac=`. Matches ngspice's RESacResist/RESacConduct
/// (resdefs.h:48-49, stamped by resload.c:60-62): it moves .ac/.sp/.noise/.pz
/// and leaves .op/.dc/.tran alone.
pub const AcParam = struct {
    ptr: ParamRef,
    ac_value: f64,
    /// The DC value, saved across one AC linearization.
    saved: f64 = 0,
};

/// Newton hook for a plain DC solve: assemble is one eval, the matrix is G.
pub const EvalHook = struct {
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

/// Dispatch table the executor installs when a GPU context is live
/// (implementation in gpu.zig). Each entry replaces the host walk of the
/// `Circuit` method it is named after; on a driver fault the implementation
/// falls back to the host walk itself, so none of these can fail.
pub const GpuHook = struct {
    ctx: *anyopaque,
    /// Every resident batch that has a host `q_tape` gets it from the device
    /// through `sync_q_tape`; false keeps the transient on the row-plane LTE.
    q_tape: bool,
    /// Stamps all four planes, ground pin included. Serves both `eval` and
    /// `evalNewton`: the device path never uses the constant-Jacobian baseline.
    eval_planes: *const fn (*anyopaque, x: []const f64, t: f64) void,
    /// Brings the resident batches' host `q_tape` up to the last eval.
    sync_q_tape: *const fn (*anyopaque) void,
    /// Announces an eval at `x` and `t` right after the next `apply_limits`
    /// or `state_ctl(.query)` (`Circuit.evalFollows`).
    eval_follows: *const fn (*anyopaque, x: []const f64, t: f64, charge: bool) void,
    /// `eval_planes` for `Circuit.evalQ`: also brings the resident batches'
    /// host `q_tape` to x, on the same wait.
    eval_charge: *const fn (*anyopaque, x: []const f64, t: f64) void,
    /// Runs the device limit pass fused with the path-latch staging.
    apply_limits: *const fn (*anyopaque, x: []f64, x_old: []const f64) bool,
    /// Runs the resident held-variable batches' state pass and walks the
    /// host ones; the fused limit launch already staged the rest.
    update_states: *const fn (*anyopaque, x: []const f64) ?f64,
    clear_limits: *const fn (*anyopaque) void,
    seed_junctions: *const fn (*anyopaque, x: []f64) void,
    /// Accepted-step latches mutate device-resident instance blobs, so a host
    /// walk cannot stand in for a resident batch.
    state_ctl: *const fn (*anyopaque, op: StateCtlOp) bool,
    /// Marks the resident models and instances stale after a host parameter
    /// write; the context re-uploads before its next launch.
    mark_dirty: *const fn (*anyopaque) void,
};

/// Frozen topology plus the mutable device and solver state of one query.
///
/// Field order is the hot/cold split: the pattern, the planes, the batch table
/// and the eval flags come first and are what every solve streams; the rest is
/// read once per analysis or less.
pub const Circuit = struct {
    col_ptr: []u32,
    row_idx: []u32,
    nnz: u32,
    /// Plane index that absorbs ground rows and structurally dead entries.
    /// Equals `nnz`, so every plane has `nnz + 1` entries.
    trash_slot: u32,
    /// Unknown count; `rhs` and `q_vec` have `n + 1` entries, `[n]` is trash.
    n: u32,

    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,

    diag_slots: []u32,
    batches: []Batch,
    /// Library type of each batch, parallel to `batches`. Borrowed topology.
    batch_types: []const device_ir.DeviceType,
    /// True where unknown i is an MNA branch current (KVL row), false for a
    /// node voltage. Read by the converger's per-row tolerance.
    current_row: []bool,

    has_charge: bool,
    /// Some charge-carrying batch advances device state at the accepted step
    /// (freeze_grad latches, absdelay rings). The transient must then re-read q
    /// under the committed state before recording it, or the next step opens
    /// on a residual a*dq that doubles every time dt halves.
    has_state_q: bool,
    /// `g_base`/`c_base` hold the constant-Jacobian contribution and
    /// `evalNewton` seeds from them.
    has_baseline: bool,

    g_base: []f64,
    c_base: []f64,

    /// Capacitor-only nodes have a charge-defined startup, not a unique static OP.
    needs_tran_op: bool = false,

    /// Node names as one flat table: `nodeName(i)` is
    /// `intern_bytes[intern_offs[i]..intern_offs[i+1]]`, empty for a branch
    /// unknown. `intern_offs` has `n + 1` entries.
    intern_bytes: []u8,
    intern_offs: []u32,

    bbd: ?BbdInfo = null,
    /// CSC slot of each frequency-dependent small-signal entry, the trash
    /// slot for a ground one (`Prepared.ac_dyn_slots`); `acDyn` fills their
    /// terms. Borrowed topology.
    ac_dyn_slots: []const u32 = &.{},
    solver_execution: numerics.Execution = .{},
    /// Executor-owned threaded stamp; null means serial eval.
    par_eval: ?*ParEval = null,
    /// Executor-owned GPU context; null means CPU only.
    gpu_hook: ?GpuHook = null,
    /// The analysis state every device call receives (`setSimState`), with
    /// the Newton iteration `beginSolve`/`advanceIteration` count.
    sim: device_ir.SimState = .{},
    gpa: std.mem.Allocator,
    /// False when the pattern, tapes and names are borrowed from a template.
    owns_topology: bool = true,
    progress: ?progress_api.Callback = null,

    /// "The planes hold the linearization at this x_op." Set by `linearize`,
    /// cleared by every plane or device-parameter writer. `x_ptr` is an
    /// identity key and is never dereferenced: x_op is one arena slice that
    /// the executor hands read-only to each consumer.
    lin: struct { x_ptr: [*]const f64 = undefined, len: u32 = 0, valid: bool = false } = .{},
    /// `updateStates` ran since the last `stateCtl(.commit)` or `.revert`.
    state_staged: bool = false,

    /// Symbolic LU and Newton scratch, built on first use and shared by every
    /// analysis. The pattern is frozen, so it stays valid for the lifetime.
    ws: ?converger.Workspace = null,
    /// `collectParams` memo. The refs point into frozen batch storage.
    param_refs: ?[]ParamRef = null,
    /// Parameters with a frequency-domain value, filled by the executor.
    /// Empty on every deck without one. Owned by the query work arena.
    ac_params: []AcParam = &.{},

    /// Returns the shared Newton/JFNK workspace, building it on first use.
    pub fn workspace(self: *Circuit) !*converger.Workspace {
        if (self.ws == null) self.ws = try converger.Workspace.init(self.gpa, self.n, self.col_ptr, self.row_idx, self.bbd);
        return &self.ws.?;
    }

    /// Reports progress to the owning worker. Fails only when the query was
    /// cancelled.
    pub fn checkpoint(self: *Circuit, event: progress_api.Event) error{QueryCancelled}!void {
        if (self.progress) |callback| try callback.checkpoint(event);
    }

    /// Returns a circuit that shares `template`'s immutable topology and owns
    /// fresh device and solver state. `template` must outlive it and must never
    /// have been evaluated.
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

    /// Returns a copy of `source`'s device state over `template`'s topology,
    /// for a query that starts from a completed operating point.
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
        var ckt = try allocate(template.*, allocator, batches, false);
        ckt.sim = source.sim;
        return ckt;
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
            .batch_types = data.batch_types,
            .current_row = data.current_row,
            .has_charge = data.has_charge,
            .has_state_q = data.has_state_q,
            .has_baseline = false,
            .g_base = &.{},
            .c_base = &.{},
            .needs_tran_op = data.needs_tran_op,
            .intern_bytes = data.intern_bytes,
            .intern_offs = data.intern_offs,
            .bbd = data.bbd,
            .ac_dyn_slots = data.ac_dyn_slots,
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
        // Unconditional: a failed computeBaseline can leave these allocated
        // with has_baseline false.
        gpa.free(self.g_base);
        gpa.free(self.c_base);
        gpa.free(self.rhs);
        gpa.free(self.q_vec);
        if (self.owns_topology) {
            gpa.free(self.col_ptr);
            gpa.free(self.row_idx);
            gpa.free(self.diag_slots);
            gpa.free(self.current_row);
            gpa.free(self.batch_types);
            if (self.bbd) |bbd| gpa.free(bbd.blocks);
            gpa.free(self.ac_dyn_slots);
            gpa.free(self.intern_bytes);
            gpa.free(self.intern_offs);
        }
        self.* = undefined;
    }

    /// Returns a view of this circuit's own value planes.
    pub fn ownPlanes(self: *Circuit) Planes {
        return .{ .g_vals = self.g_vals, .c_vals = self.c_vals, .rhs = self.rhs, .q_vec = self.q_vec };
    }

    /// Returns the length of the per-device-state charge tape: one entry per
    /// (instance, LTE charge site) of every charge-carrying batch,
    /// batch-major.
    ///
    /// Zero when nothing carries charge, and zero under a GPU plane hook that
    /// cannot fill the resident batches' tapes (`GpuHook.q_tape`). The
    /// transient reads zero as "use per-row LTE on the summed q plane".
    pub fn qTapeLen(self: *const Circuit) u32 {
        if (self.gpu_hook) |gh| if (!gh.q_tape) return 0;
        var total: u32 = 0;
        for (self.batches) |b| {
            if (b.hooks.q_tape) |f| total += @intCast(f(b.ctx).len);
        }
        return total;
    }

    /// Concatenates every batch's live charge tape into `dst`, which must hold
    /// exactly `qTapeLen()` entries.
    pub fn snapshotQTape(self: *const Circuit, dst: []f64) void {
        if (self.gpu_hook) |gh| gh.sync_q_tape(gh.ctx);
        var off: usize = 0;
        for (self.batches) |b| {
            const f = b.hooks.q_tape orelse continue;
            const src = f(b.ctx);
            @memcpy(dst[off..][0..src.len], src);
            off += src.len;
        }
        std.debug.assert(off == dst.len);
    }

    /// Adds the ground pin. Runs once, after every batch stamp and reduction.
    pub fn groundStamp(self: *Circuit, x: []const f64) void {
        self.g_vals[self.diag_slots[0]] += 1.0;
        self.rhs[0] += x[0];
    }

    /// Stamps all four planes for state `x` at time `t`.
    ///
    /// This and `evalNewton` are the only places the GPU enters an analysis.
    /// Replacing the stamp rather than the solve lets every host step layered
    /// on a stamp (companion RHS, `combineGC`, limiting) compose with it.
    pub fn eval(self: *Circuit, x: []const f64, t: f64) void {
        // Callers also eval at points other than x_op (disto, pss, pac, ...),
        // so the linearization memo cannot survive this.
        self.lin.valid = false;
        if (self.gpu_hook) |gh| return gh.eval_planes(gh.ctx, x, t);
        self.stamp(x, t, .full);
    }

    /// Clears the planes `mode` writes, or seeds g/c from the baseline for
    /// `.newton`. The one plane reset shared by the serial path, ParEval and
    /// the GPU's host half.
    pub fn clearPlanes(self: *Circuit, comptime mode: par_eval.Mode) void {
        switch (mode) {
            .charge => zeroSimd(self.q_vec),
            .newton => {
                @memcpy(self.g_vals, self.g_base);
                if (self.has_charge) {
                    @memcpy(self.c_vals, self.c_base);
                    zeroSimd(self.q_vec);
                }
                zeroSimd(self.rhs);
            },
            .full => {
                zeroSimd(self.g_vals);
                if (self.has_charge) {
                    zeroSimd(self.c_vals);
                    zeroSimd(self.q_vec);
                }
                zeroSimd(self.rhs);
            },
        }
    }

    /// Host stamp: clear, run every batch serially or threaded, then add the
    /// ground pin (which `.charge` does not touch).
    fn stamp(self: *Circuit, x: []const f64, t: f64, comptime mode: par_eval.Mode) void {
        self.clearPlanes(mode);
        const pl = self.ownPlanes();
        if (self.par_eval) |p|
            p.run(self.batches, pl, x, t, mode)
        else for (self.batches) |b|
            par_eval.stampRange(b, &pl, 0, b.count, x, t, mode);
        if (mode != .charge) self.groundStamp(x);
    }

    /// Stamps only the charges at `x`: `q_vec` and every batch's `q_tape`,
    /// bit-for-bit what `eval` would leave there, with g/c/rhs untouched.
    /// ParEval reuses the lane cuts and reduce order of `.full`, so the
    /// promise holds threaded too. The GPU has no charge-only kernel and runs
    /// the full pass.
    pub fn evalQ(self: *Circuit, x: []const f64, t: f64) void {
        self.lin.valid = false;
        if (self.gpu_hook) |gh| return gh.eval_charge(gh.ctx, x, t);
        self.stamp(x, t, .charge);
    }

    /// Ensures the planes hold the linearization at `x_op`, reusing them when
    /// they already do. The AC-family analyses all linearize at the same
    /// operating point, so an op+ac+noise+pz deck pays for one device eval.
    pub fn linearize(self: *Circuit, x_op: []const f64) void {
        if (self.lin.valid and self.lin.x_ptr == x_op.ptr and self.lin.len == x_op.len) return;
        self.eval(x_op, 0);
        self.lin = .{ .x_ptr = x_op.ptr, .len = @intCast(x_op.len), .valid = true };
    }

    /// `linearize` for a frequency-domain analysis (ngspice CKTacLoad rather
    /// than CKTload): swaps in each `AcParam` value, stamps, and restores the
    /// DC values. Leaves the memo invalid, because the planes then hold the AC
    /// linearization that a later DC eval must not reuse.
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

    /// Writes the frequency-dependent term of every `ac_dyn_slots` entry e at
    /// `x` and each ω in `omegas` into `re[e * omegas.len + k]` and `im[...]`,
    /// under the stored sim state: A(ω) = G + jωC + (re + j·im) with G and C
    /// from a `.ac`/`.noise` eval at the same x. Host-side, GPU context or not.
    pub fn acDyn(self: *const Circuit, x: []const f64, omegas: []const f64, re: []f64, im: []f64) void {
        std.debug.assert(re.len == self.ac_dyn_slots.len * omegas.len and im.len == re.len);
        var off: usize = 0;
        for (self.batches) |b| if (b.hooks.ac_dyn) |f| {
            off += omegas.len * f(b.ctx, x, omegas, re[off..], im[off..]);
        };
        std.debug.assert(off == re.len);
    }

    /// Adds `acDyn` at `x` and one ω into the row-major 2n x 2n stacked-real
    /// `a` ([Re -Im; Im Re], `dense_lu.buildComplexAdmittance`'s layout).
    /// `scratch` holds `2 * ac_dyn_slots.len` values.
    pub fn addAcDynDense(self: *const Circuit, x: []const f64, omega: f64, a: []f64, scratch: []f64) void {
        const e = self.ac_dyn_slots.len;
        if (e == 0) return;
        const re = scratch[0..e];
        const im = scratch[e..][0..e];
        self.acDyn(x, &.{omega}, re, im);
        const n: usize = self.n;
        for (self.ac_dyn_slots, re, im) |slot, r, i| {
            if (slot >= self.nnz) continue;
            freq_solve.addDense(n, 2 * n, a, self.row_idx[slot], freq_solve.slotCol(self.col_ptr, slot), r, i);
        }
    }

    /// Stamps the planes for a Newton iterate, seeding from the constant
    /// baseline when one exists.
    pub fn evalNewton(self: *Circuit, x: []const f64, t: f64) void {
        self.lin.valid = false;
        // The device path ignores the baseline: `g_base` includes the resident
        // batches too, and the GPU sink cannot skip them, so it zeroes and
        // restamps instead.
        if (self.gpu_hook) |gh| return gh.eval_planes(gh.ctx, x, t);
        self.evalNewtonCpu(x, t);
    }

    /// Host half of `evalNewton`, also the GPU context's fault fallback.
    pub fn evalNewtonCpu(self: *Circuit, x: []const f64, t: f64) void {
        if (self.has_baseline) self.stamp(x, t, .newton) else self.stamp(x, t, .full);
    }

    /// Precomputes the constant-Jacobian contribution into `g_base`/`c_base`.
    /// A no-op when no batch has a constant Jacobian or the baseline is
    /// already current. Clobbers `rhs` and `q_vec`.
    pub fn computeBaseline(self: *Circuit) !void {
        if (self.has_baseline) return;
        for (self.batches) |b| {
            if (b.has_const_jacobian) break;
        } else return;

        if (self.g_base.len == 0) {
            self.g_base = try self.gpa.alloc(f64, self.nnz + 1);
            self.c_base = try self.gpa.alloc(f64, self.nnz + 1);
        }
        @memset(self.g_base, 0);
        @memset(self.c_base, 0);

        const x_zero = try self.gpa.alloc(f64, self.n + 1);
        defer self.gpa.free(x_zero);
        @memset(x_zero, 0);

        self.lin.valid = false;
        zeroSimd(self.rhs);
        if (self.has_charge) zeroSimd(self.q_vec);
        const pl: Planes = .{ .g_vals = self.g_base, .c_vals = self.c_base, .rhs = self.rhs, .q_vec = self.q_vec };
        for (self.batches) |b| {
            if (b.has_const_jacobian) b.eval(b.ctx, &pl, 0, b.count, x_zero, 0);
        }
        self.g_base[self.diag_slots[0]] += 1.0;
        self.has_baseline = true;
    }

    /// Returns one `G + alpha*C` entry, the same expression `combineGC` uses,
    /// so the Newton residual gate can read a diagonal in O(1) instead of
    /// rebuilding the whole plane.
    pub fn gcAt(self: *const Circuit, alpha: f64, slot: u32) f64 {
        return self.g_vals[slot] + alpha * self.c_vals[slot];
    }

    /// Writes `G + alpha*C` into `out[0..nnz]`.
    pub fn combineGC(self: *const Circuit, alpha: f64, out: []f64) void {
        std.debug.assert(out.len >= self.nnz);
        combinePlanes(std.simd.suggestVectorLength(f64) orelse 1, out[0..self.nnz], self.g_vals[0..self.nnz], self.c_vals[0..self.nnz], alpha);
    }

    /// Writes G as a dense row-major `n*n` matrix into `out`.
    pub fn denseG(self: *const Circuit, out: []f64) void {
        self.denseFrom(self.g_vals, out);
    }
    /// Writes C as a dense row-major `n*n` matrix into `out`.
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

    /// Returns the plane index of (row, col), or null when the pattern has no
    /// such entry.
    pub fn findSlot(self: *const Circuit, row: u32, col: u32) ?u32 {
        const pattern: device_ir.PatternView = .{
            .col_ptr = self.col_ptr,
            .row_idx = self.row_idx,
            .n = self.n,
            .trash_slot = self.trash_slot,
        };
        return pattern.findSlot(row, col);
    }

    /// Tells the circuit that the next `applyLimits` or `stateCtl(.query)`
    /// is followed by `eval` (or, with `charge`, `evalQ`) at `x` and `t`,
    /// with nothing in between that changes device state. `x` is read when
    /// that call runs, so for `applyLimits` it is the limited iterate. The
    /// GPU path then runs both on one host wait; the host path ignores it. A
    /// wrong promise costs one wasted device eval, never a wrong stamp: the
    /// eval checks its x and t.
    pub fn evalFollows(self: *const Circuit, x: []const f64, t: f64, charge: bool) void {
        if (self.gpu_hook) |gh| gh.eval_follows(gh.ctx, x, t, charge);
    }

    /// Limits the Newton update in place (pnjlim/fetlim). Returns true when any
    /// device clamped `x`.
    pub fn applyLimits(self: *const Circuit, x: []f64, x_old: []const f64) bool {
        if (self.gpu_hook) |gh| return gh.apply_limits(gh.ctx, x, x_old);
        return limitBatches(self.batches, x, x_old);
    }

    // Host walks over a batch slice. `Circuit` walks every batch; the GPU
    // context walks its host-resident ones, or every batch after a fault.

    pub fn limitBatches(batches: []const Batch, x: []f64, x_old: []const f64) bool {
        var any_limited = false;
        for (batches) |b| if (b.hooks.apply_limits) |f| {
            if (f(b.ctx, x, x_old)) any_limited = true;
        };
        return any_limited;
    }

    pub fn seedBatches(batches: []const Batch, x: []f64) void {
        for (batches) |b| if (b.hooks.seed) |f| f(b.ctx, x);
    }

    /// Sets every `idt` state unknown with an ic to that ic (`Hooks.seed_ic`):
    /// the uic start's stand-in for the operating point, which solves them.
    /// Needs a static sim state.
    pub fn seedIc(self: *const Circuit, x: []f64) void {
        for (self.batches) |b| if (b.hooks.seed_ic) |f| f(b.ctx, x);
    }

    pub fn clearLimitBatches(batches: []const Batch) void {
        for (batches) |b| if (b.hooks.clear_limits) |f| f(b.ctx);
    }

    pub fn updateBatches(batches: []const Batch, x: []const f64) ?f64 {
        return minReject(batches, "update_state", x);
    }

    pub fn stateCtlBatches(batches: []const Batch, sop: StateCtlOp) bool {
        var dirty = false;
        for (batches) |b| if (b.hooks.state_ctl) |f| {
            if (f(b.ctx, sop)) dirty = true;
        };
        return dirty;
    }

    /// Earliest step-reject time any batch's `hook` returns, or null.
    fn minReject(batches: []const Batch, comptime hook: []const u8, x: []const f64) ?f64 {
        var min_reject: ?f64 = null;
        for (batches) |b| {
            if (@field(b.hooks, hook)) |f| if (f(b.ctx, x)) |tr| {
                min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
            };
        }
        return min_reject;
    }

    /// SPICE MODEINITJCT: devices write junction seed voltages into a zeroed
    /// `x`, so iteration 1 linearizes at vcrit/vto instead of 0 and the
    /// limiters clamp against the seed. Cold starts only.
    pub fn seedJunctions(self: *const Circuit, x: []f64) void {
        if (self.gpu_hook) |gh| return gh.seed_junctions(gh.ctx, x);
        seedBatches(self.batches, x);
    }

    /// Resets device-private limiting state after a Newton solve, so later
    /// evals (waveform, AC, noise) see the node vector itself.
    pub fn clearLimits(self: *const Circuit) void {
        if (self.gpu_hook) |gh| return gh.clear_limits(gh.ctx);
        clearLimitBatches(self.batches);
    }

    /// Starts a nonlinear solve: `$simparam("iteration")` reads 1.
    pub fn beginSolve(self: *Circuit) void {
        self.lin.valid = false;
        self.sim.iteration = 1;
        self.publishSim();
    }

    /// Hands every device the previous Newton iterate, then counts the
    /// iteration.
    pub fn advanceIteration(self: *Circuit, previous_x: []const f64) void {
        self.lin.valid = false;
        for (self.batches) |b| if (b.hooks.advance_iteration) |f| f(b.ctx, previous_x);
        self.sim.iteration +|= 1;
        self.publishSim();
    }

    /// Returns false when any device vetoes convergence at `x`.
    pub fn checkConvergence(self: *const Circuit, x: []const f64) bool {
        for (self.batches) |b| if (b.hooks.check_convergence) |f| {
            if (!f(b.ctx, x)) return false;
        };
        return true;
    }

    /// Advances device state (operator history, held variables, latches)
    /// from the last accepted point to `x`. Returns the earliest time a
    /// device asks the step to be rejected at, or null. A second call
    /// before the next commit or revert (a flip that forced another
    /// iterate, a continuation rung) reverts first, since `stateCtl(.revert)`
    /// is exact only across one `updateState`.
    pub fn updateStates(self: *Circuit, x: []const f64) ?f64 {
        if (self.state_staged) _ = self.stateCtl(.revert);
        self.state_staged = true;
        if (self.gpu_hook) |gh| return gh.update_states(gh.ctx, x);
        return updateBatches(self.batches, x);
    }

    /// Accepted-point half of `updateStates`, for delay-line history no
    /// static solve may push (`Hooks.commit_state`). The transient calls it
    /// once per accepted point, before `stateCtl(.commit)`.
    pub fn commitStates(self: *const Circuit, x: []const f64) ?f64 {
        return minReject(self.batches, "commit_state", x);
    }

    /// Commits, reverts or queries the accepted device state. `.commit` at
    /// every accepted point, the operating point included; `.revert` after
    /// every rejected attempt. For `.query`, returns true when a cross/above
    /// flip moved the working state off the last accepted one.
    pub fn stateCtl(self: *Circuit, sop: StateCtlOp) bool {
        if (sop != .query) self.state_staged = false;
        if (self.gpu_hook) |gh| return gh.state_ctl(gh.ctx, sop);
        return stateCtlBatches(self.batches, sop);
    }

    /// Returns the smallest model delay (`D.delays`) in the circuit, or null.
    pub fn minDelay(self: *const Circuit) ?f64 {
        var min_td = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.min_delay) |f| {
            min_td = @min(min_td, f(b.ctx));
        };
        return if (min_td == std.math.inf(f64)) null else min_td;
    }

    /// Returns the tightest `$bound_step` (VAMS 9.17.2) any device asked for,
    /// or null. Only meaningful after an accepted step ran `updateStates`.
    pub fn boundStep(self: *const Circuit) ?f64 {
        var best = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.bound_step) |f| {
            best = @min(best, f(b.ctx));
        };
        return if (best == std.math.inf(f64)) null else best;
    }

    /// Returns the earliest device breakpoint after `t`, or null.
    pub fn nextBreakpoint(self: *const Circuit, t: f64) ?f64 {
        var best = std.math.inf(f64);
        for (self.batches) |b| if (b.hooks.next_breakpoint) |f| {
            if (f(b.ctx, t)) |bp| best = @min(best, bp);
        };
        return if (best == std.math.inf(f64)) null else best;
    }

    /// Installs a circuit temperature in degrees Celsius. Call `recompute`
    /// before solving, which also detects a temperature-driven topology change.
    pub fn setCircuitTemp(self: *Circuit, temp_c: f32) void {
        self.lin.valid = false;
        for (self.batches) |b| if (b.hooks.set_temp) |f| f(b.ctx, temp_c);
        self.markGpuDirty();
    }

    fn markGpuDirty(self: *Circuit) void {
        if (self.gpu_hook) |gh| gh.mark_dirty(gh.ctx);
    }

    /// Publishes the analysis state (`$abstime`, timestep, `analysis()`,
    /// `initial_step`/`final_step`) every later device call receives; `eval`
    /// takes `$abstime` from its own `t`. Keeps the Newton iteration count.
    /// Must run before the eval it describes.
    pub fn setSimState(self: *Circuit, st: device_ir.SimState) void {
        const iteration = self.sim.iteration;
        self.sim = st;
        self.sim.iteration = iteration;
        self.publishSim();
    }

    /// Copies `sim` into every batch: one store each.
    fn publishSim(self: *const Circuit) void {
        for (self.batches) |b| b.hooks.set_sim_state(b.ctx, self.sim);
    }

    /// Re-derives every batch's numeric parameters. `error.TopologyChanged`
    /// means internal wiring moved and the circuit must be rebuilt; restore
    /// the parameters and recompute before reusing it.
    pub fn recompute(self: *Circuit) error{TopologyChanged}!void {
        self.lin.valid = false;
        self.has_baseline = false;
        self.markGpuDirty();
        for (self.batches) |b| if (b.hooks.recompute) |f| {
            if (!f(b.ctx)) return error.TopologyChanged;
        };
    }

    /// `recompute` restricted to batches of type `t` (`ParamRef.type`).
    ///
    /// A `.dc` point writes one parameter, and a full recompute re-runs every
    /// compact model's temperature preamble (1,811 BJT preambles per sweep on
    /// a one-instance deck). Sound only while nothing global has moved: a
    /// temperature change can re-wire a device of another type (a BJT whose
    /// RB(T) reaches zero). The caller owns that distinction; `.dc` takes the
    /// full walk on the first point of every inner sweep and narrows after.
    pub fn recomputeType(self: *Circuit, t: device_ir.DeviceType) error{TopologyChanged}!void {
        self.lin.valid = false;
        self.has_baseline = false;
        self.markGpuDirty();
        for (self.batches, self.batch_types) |b, bt| {
            if (bt != t) continue;
            if (b.hooks.recompute) |f| {
                if (!f(b.ctx)) return error.TopologyChanged;
            }
        }
    }

    /// Scales device parameters for homotopy step `lambda`; undone by
    /// `restoreModels`.
    pub fn applyAttempt(self: *Circuit, lambda: f64) void {
        self.lin.valid = false;
        for (self.batches) |b| if (b.hooks.apply_attempt) |f| f(b.ctx, lambda);
        self.markGpuDirty();
    }

    /// Restores the parameters `applyAttempt` scaled.
    pub fn restoreModels(self: *Circuit) void {
        self.lin.valid = false;
        for (self.batches) |b| if (b.hooks.restore_models) |f| f(b.ctx);
        self.markGpuDirty();
    }

    /// Returns every device parameter, typed by batch. Built once and freed by
    /// `deinit`; the refs point into frozen batch storage.
    pub fn collectParams(self: *Circuit) ![]const ParamRef {
        if (self.param_refs) |refs| return refs;
        const gpa = self.gpa;
        var list: std.ArrayList(ParamRef) = .empty;
        errdefer list.deinit(gpa);
        try collectTyped(self.batches, self.batch_types, gpa, &list);
        self.param_refs = try list.toOwnedSlice(gpa);
        return self.param_refs.?;
    }

    /// Returns the short type name of device type `t`, or "" when absent.
    pub fn typeName(self: *const Circuit, t: device_ir.DeviceType) []const u8 {
        for (self.batches, self.batch_types) |b, bt| if (bt == t) return b.type_name;
        return "";
    }

    /// Appends every batch's parameters to `list`, each stamped with its
    /// batch's Library type.
    pub fn collectTyped(batches: []const Batch, types: []const device_ir.DeviceType, gpa: std.mem.Allocator, list: *std.ArrayList(ParamRef)) !void {
        for (batches, types) |b, t| {
            const first = list.items.len;
            try b.hooks.collect_params(b.ctx, gpa, list).unwrap();
            for (list.items[first..]) |*ref| ref.type = t;
        }
    }

    /// Returns every device's noise generators at `x`, with each device's own
    /// PSDs (which already carry its temperature). Pure in `x`, so `.pnoise`
    /// calls it per PSS sample. Caller owns the slice.
    pub fn collectNoiseSources(self: *const Circuit, x: []const f64, gpa: std.mem.Allocator) ![]NoiseSource {
        var list: std.ArrayList(NoiseSource) = .empty;
        errdefer list.deinit(gpa);
        for (self.batches) |b| if (b.hooks.collect_noise) |f| try f(b.ctx, x, gpa, &list).unwrap();
        return try list.toOwnedSlice(gpa);
    }

    /// Returns the netlist name of unknown `node`, or "" for a branch unknown.
    pub fn nodeName(self: *const Circuit, node: u32) []const u8 {
        if (node + 1 < self.intern_offs.len)
            return self.intern_bytes[self.intern_offs[node]..self.intern_offs[node + 1]];
        return "";
    }
};

/// Freezes `protos` into an owning Circuit (test construction). Takes
/// ownership of the intern table and consumes the protos.
pub fn init(
    gpa: std.mem.Allocator,
    n: u32,
    intern_bytes: []u8,
    intern_offs: []u32,
    protos: []const device_ir.Proto,
    types: []const device_ir.DeviceType,
    bbd: ?BbdInfo,
) !Circuit {
    var prepared = try Prepared.freeze(gpa, n, intern_bytes, intern_offs, protos, types, bbd);
    errdefer prepared.deinit();
    return Circuit.allocate(prepared, prepared.allocator, prepared.batches, true);
}

/// Writes `out = g + alpha*c` over independent CSC entries. `W == 1` is the
/// scalar oracle and the tail. `out` may alias `g`.
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
