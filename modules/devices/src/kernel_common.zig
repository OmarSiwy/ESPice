//! Shared between the megakernel driver TU (kernel.zig) and the per-model
//! stub TUs (kernel_stub.zig): workspace views + grid barrier (G), the
//! transient companion env, and the generic batch eval/limit bodies.
//!
//! Every TU compiles this same source with the same compiler and flags, so
//! struct layouts (G, TranEnv) agree across the nvlink boundary.

const devices = @import("dev_models");
const contract = devices.contract;
const abi = @import("gpu_abi");
// Via dev_models (not a file import): eval_core.zig must belong to exactly
// one module per compilation, and batch.zig already owns it.
const eval_core = devices.batch.eval_core;

pub const inf_f64: f64 = @bitCast(@as(u64, 0x7ff0000000000000));

// ---------------------------------------------------------------------------
// Barrier + reductions
// ---------------------------------------------------------------------------

pub inline fn blockSync() void {
    asm volatile ("bar.sync 0;" ::: .{ .memory = true });
}

pub inline fn memFence() void {
    // LLVM 21 drops atomicrmw orderings on NVPTX; membar.gl keeps the
    // barrier sound under the legacy PTX memory model.
    asm volatile ("membar.gl;" ::: .{ .memory = true });
}

pub const G = struct {
    // Global workspace views, set up once in the entry point.
    n: u32,
    m: u32,
    n_blocks: u32,
    tid: u32, // global thread id
    ltid: u32, // in-block thread id
    bid: u32,
    stride: u32,
    v_basis: [*]addrspace(.global) f64,
    h: [*]addrspace(.global) f64,
    cs: [*]addrspace(.global) f64,
    sn: [*]addrspace(.global) f64,
    g_vec: [*]addrspace(.global) f64,
    y_vec: [*]addrspace(.global) f64,
    r: [*]addrspace(.global) f64, // doubles as dx after the Krylov solve
    w: [*]addrspace(.global) f64,
    x_pert: [*]addrspace(.global) f64,
    f0: [*]addrspace(.global) f64,
    f0_shift: [*]addrspace(.global) f64, // FD baseline (uncorrected when limiting)
    diag: [*]addrspace(.global) f64, // Jacobian diag -> inverted in place
    x_old: [*]addrspace(.global) f64,
    rhs: [*]addrspace(.global) f64, // n+1 (trash row)
    // -- transient state (persists across chunk launches) --
    x_try: [*]addrspace(.global) f64, // n: Newton trial vector
    i_prev: [*]addrspace(.global) f64, // n: previous dynamic current
    cvec: [*]addrspace(.global) f64, // n: per-step companion constant
    q_hist: [*]addrspace(.global) f64, // 4*(n+1) rotating charge ring
    tstate: [*]addrspace(.global) f64, // 16 thread-0-owned tran scalars
    scal: [*]addrspace(.global) f64, // 8 thread-0-owned slots
    partials: [*]addrspace(.global) f64,
    barrier_cg: [*]addrspace(.global) u32, // [count, generation]

    pub inline fn sync(self: *const G) void {
        blockSync();
        memFence();
        if (self.ltid == 0) {
            const count = &self.barrier_cg[0];
            const gen = &self.barrier_cg[1];
            const my_gen = @atomicLoad(u32, gen, .acquire);
            const prev = @atomicRmw(u32, count, .Add, 1, .acq_rel);
            if (prev == self.n_blocks - 1) {
                @atomicStore(u32, count, 0, .monotonic);
                _ = @atomicRmw(u32, gen, .Add, 1, .release);
            } else {
                while (@atomicLoad(u32, gen, .acquire) == my_gen) {}
            }
        }
        memFence();
        blockSync();
    }

    /// Sum thread-local partials grid-wide into scal[0]. 2 grid syncs.
    pub fn reduceAdd(self: *const G, partial: f64) f64 {
        if (self.ltid == 0) self.partials[self.bid] = 0;
        blockSync();
        _ = @atomicRmw(f64, &self.partials[self.bid], .Add, partial, .monotonic);
        self.sync();
        if (self.tid == 0) {
            var s: f64 = 0;
            for (0..self.n_blocks) |b| s += self.partials[b];
            self.scal[0] = s;
        }
        self.sync();
        return self.scal[0];
    }

    /// Grid-wide max of NON-NEGATIVE partials (bit-ordered u64 atomics).
    pub fn reduceMax(self: *const G, partial: f64) f64 {
        if (self.ltid == 0) self.partials[self.bid] = 0;
        blockSync();
        const pu: *addrspace(.global) u64 = @ptrCast(&self.partials[self.bid]);
        _ = @atomicRmw(u64, pu, .Max, @bitCast(partial), .monotonic);
        self.sync();
        if (self.tid == 0) {
            var mx: f64 = 0;
            for (0..self.n_blocks) |b| mx = @max(mx, self.partials[b]);
            self.scal[0] = mx;
        }
        self.sync();
        return self.scal[0];
    }

    /// Grid-wide min of POSITIVE partials (bit-ordered u64 atomics; +inf ok).
    pub fn reduceMin(self: *const G, partial: f64) f64 {
        if (self.ltid == 0) self.partials[self.bid] = inf_f64;
        blockSync();
        const pu: *addrspace(.global) u64 = @ptrCast(&self.partials[self.bid]);
        _ = @atomicRmw(u64, pu, .Min, @bitCast(partial), .monotonic);
        self.sync();
        if (self.tid == 0) {
            var mn: f64 = inf_f64;
            for (0..self.n_blocks) |b| mn = @min(mn, self.partials[b]);
            self.scal[0] = mn;
        }
        self.sync();
        return self.scal[0];
    }
};

/// Companion-residual environment for the transient path. Inactive for
/// arp_solve — one runtime struct, ONE evalBatch instantiation per device
/// (ptxas cost stays flat; the q call is guarded by `active`).
pub const TranEnv = struct {
    active: bool, // stamp alpha*q(x) into rhs (+ alpha*dQ diag)
    alpha: f64,
    cvec: ?[*]addrspace(.global) const f64, // step-constant companion part
    snap: ?[*]addrspace(.global) f64, // raw q(x) accumulation target (n+1)
};

pub const no_tran: TranEnv = .{ .active = false, .alpha = 0, .cvec = null, .snap = null };

pub fn isDevice(comptime D: type) bool {
    return @typeInfo(D) == .@"struct" and @hasDecl(D, "U") and @hasDecl(D, "eval") and @hasDecl(D, "Model");
}

// ---------------------------------------------------------------------------
// Cross-TU dispatch ABI: each model stub exports these three shapes; the
// driver resolves them by comptime-generated symbol name ("arp_eb_<name>_d",
// "arp_eb_<name>_r", "arp_lb_<name>"). Pointers only — no aggregates by
// value across the link boundary.
// ---------------------------------------------------------------------------

pub const EbFn = *const fn (
    g: *const G,
    desc: *addrspace(.global) const abi.BatchDesc,
    blob: [*]addrspace(.global) u8,
    x: [*]addrspace(.global) const f64,
    t: f64,
    env: *const TranEnv,
    limiting: bool,
    x_base: [*]addrspace(.global) const f64,
) callconv(.c) void;

pub const LbFn = *const fn (
    g: *const G,
    desc: *addrspace(.global) const abi.BatchDesc,
    blob: [*]addrspace(.global) u8,
    x: [*]addrspace(.global) const f64,
    x_old: [*]addrspace(.global) const f64,
    lim_active: bool,
) callconv(.c) f64;

/// GPU sink for eval_core: owns the addrspace(.global) workspace/tape
/// pointers; scatter is atomicAdd into g.rhs and (diag-only) g.diag; the
/// companion charge terms fold through env (rhs += alpha*q, diag += alpha*dQ,
/// raw q into env.snap). No dedup — it compiles out (zero ptxas cost).
fn GpuSink(comptime D: type) type {
    const n_u = contract.nU(D);
    const has_limit = @hasDecl(D, "limit");
    const has_prep = @hasDecl(D, "PrepCache");
    return struct {
        g: *const G,
        env: TranEnv,
        has_q: bool, // desc.has_q != 0
        xs: [*]addrspace(.global) const f64,
        xb: [*]addrspace(.global) const f64, // x_base (residual-only limiting)
        xo: [*]addrspace(.global) const f64, // x_old (limit pass)
        gt: [*]addrspace(.global) const u32,
        ri: [*]addrspace(.global) const u32,
        mods: [*]addrspace(.global) const D.Model,
        insts: [*]addrspace(.global) const D.Instance,
        lims: if (has_limit) [*]addrspace(.global) f64 else void,
        preps: if (has_prep) [*]addrspace(.global) const D.PrepCache else void,
        pgroup: if (has_prep) [*]addrspace(.global) const u32 else void,

        pub const dedup = false;
        pub const skip_g = false;
        pub const skip_c = false;
        pub const optimized_float = false;

        const Self = @This();

        inline fn ix(id: u32, u: usize) usize {
            return @as(usize, id) * n_u + u;
        }
        pub inline fn x(s: *const Self, gi: u32) f64 {
            return s.xs[gi];
        }
        pub inline fn xBase(s: *const Self, gi: u32) f64 {
            return s.xb[gi];
        }
        pub inline fn xOld(s: *const Self, gi: u32) f64 {
            return s.xo[gi];
        }
        pub inline fn gath(s: *const Self, id: u32, u: usize) u32 {
            return s.gt[ix(id, u)];
        }
        pub inline fn rhsRow(s: *const Self, id: u32, ru: usize) u32 {
            return s.ri[ix(id, ru)];
        }
        pub inline fn lim(s: *const Self, id: u32, u: usize) f64 {
            return s.lims[ix(id, u)];
        }
        pub inline fn setLim(s: *const Self, id: u32, u: usize, v: f64) void {
            s.lims[ix(id, u)] = v;
        }
        pub inline fn model(s: *const Self, id: u32) *const D.Model {
            return @addrSpaceCast(&s.mods[id]);
        }
        pub inline fn inst(s: *const Self, id: u32) *const D.Instance {
            return @addrSpaceCast(&s.insts[id]);
        }
        pub inline fn prep(s: *const Self, id: u32) *const D.PrepCache {
            return @addrSpaceCast(&s.preps[s.pgroup[id]]);
        }
        pub inline fn scatterRes(s: *const Self, row: u32, val: f64) void {
            _ = @atomicRmw(f64, &s.g.rhs[row], .Add, val, .monotonic);
        }
        /// Diagonal Jacobian contribution only: residual row == unknown col.
        pub inline fn scatterJac(s: *const Self, id: u32, ru: usize, cu: usize, row: u32, val: f64) void {
            _ = ru;
            if (row == s.gt[ix(id, cu)] and row < s.g.n)
                _ = @atomicRmw(f64, &s.g.diag[row], .Add, val, .monotonic);
        }
        pub inline fn qActive(s: *const Self) bool {
            return s.env.active and s.has_q;
        }
        pub inline fn scatterQ(s: *const Self, row: u32, qv: f64) void {
            _ = @atomicRmw(f64, &s.g.rhs[row], .Add, s.env.alpha * qv, .monotonic);
            if (s.env.snap) |sp|
                _ = @atomicRmw(f64, &sp[row], .Add, qv, .monotonic);
        }
        pub inline fn scatterQJac(s: *const Self, id: u32, ru: usize, cu: usize, row: u32, val: f64) void {
            s.scatterJac(id, ru, cu, row, s.env.alpha * val);
        }
    };
}

fn makeSink(
    comptime D: type,
    g: *const G,
    desc: *addrspace(.global) const abi.BatchDesc,
    blob: [*]addrspace(.global) u8,
    env: TranEnv,
) GpuSink(D) {
    return .{
        .g = g,
        .env = env,
        .has_q = desc.has_q != 0,
        .xs = undefined,
        .xb = undefined,
        .xo = undefined,
        .gt = @ptrCast(@alignCast(blob + desc.off_gath)),
        .ri = @ptrCast(@alignCast(blob + desc.off_rhs_idx)),
        .mods = @ptrCast(@alignCast(blob + desc.off_models)),
        .insts = @ptrCast(@alignCast(blob + desc.off_instances)),
        .lims = if (comptime @hasDecl(D, "limit")) @ptrCast(@alignCast(blob + desc.off_lim)) else {},
        .preps = if (comptime @hasDecl(D, "PrepCache")) @ptrCast(@alignCast(blob + desc.off_prep_cache)) else {},
        .pgroup = if (comptime @hasDecl(D, "PrepCache")) @ptrCast(@alignCast(blob + desc.off_prep_group)) else {},
    };
}

/// Evaluate one batch: gather x, run physics, atomicAdd residual (and the
/// Jacobian diagonal when `with_diag`). One grid-stride loop per batch keeps
/// warps convergent inside a device type. When env.active, the companion
/// charge terms are stamped too: rhs += alpha*q(x), diag += alpha*dQ/dx,
/// raw q(x) accumulated into env.snap (charge history snapshot).
/// Body lives in eval_core.evalRange (single source with batch.zig).
pub fn evalBatch(
    comptime D: type,
    comptime with_diag: bool,
    g: *const G,
    desc: *addrspace(.global) const abi.BatchDesc,
    blob: [*]addrspace(.global) u8,
    x: [*]addrspace(.global) const f64,
    t: f64,
    env: TranEnv,
    limiting: bool,
    x_base: [*]addrspace(.global) const f64,
) void {
    var sink = makeSink(D, g, desc, blob, env);
    sink.xs = x;
    sink.xb = x_base;
    const use_lim = if (comptime @hasDecl(D, "limit")) limiting and desc.off_lim != 0 else false;
    eval_core.evalRange(D, with_diag, &sink, g.tid, desc.count, g.stride, t, use_lim);
}

/// Device limiting pass for one batch (single source: eval_core.limitRange):
/// cur = local(x); old = lim_x (once engaged) else local(x_old);
/// lim_x = D.limit(cur, old). Returns 1.0 if any component was limited
/// (thread-local partial; caller reduces grid-wide).
pub fn limitBatch(
    comptime D: type,
    g: *const G,
    desc: *addrspace(.global) const abi.BatchDesc,
    blob: [*]addrspace(.global) u8,
    x: [*]addrspace(.global) const f64,
    x_old: [*]addrspace(.global) const f64,
    lim_active: bool,
) f64 {
    var sink = makeSink(D, g, desc, blob, no_tran);
    sink.xs = x;
    sink.xo = x_old;
    return eval_core.limitRange(D, &sink, g.tid, desc.count, g.stride, lim_active);
}
