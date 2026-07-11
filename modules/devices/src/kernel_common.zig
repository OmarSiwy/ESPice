//! Shared between the megakernel driver TU (kernel.zig) and the per-model
//! stub TUs (kernel_stub.zig): workspace views + grid barrier (G), the
//! transient companion env, and the generic batch eval/limit bodies.
//!
//! Every TU compiles this same source with the same compiler and flags, so
//! struct layouts (G, TranEnv) agree across the nvlink boundary.

const devices = @import("dev_models");
const contract = devices.contract;
const abi = @import("gpu_abi");

const Value = contract.Value;

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

/// Evaluate one batch: gather x, run physics, atomicAdd residual (and the
/// Jacobian diagonal when `with_diag`). One grid-stride loop per batch keeps
/// warps convergent inside a device type. When env.active, the companion
/// charge terms are stamped too: rhs += alpha*q(x), diag += alpha*dQ/dx,
/// raw q(x) accumulated into env.snap (charge history snapshot).
///
/// Device limiting (`limiting` + desc.off_lim): mirrors batch.zig evalInner.
///   with_diag (outer): eval at the private limited point lx, stamp the
///     linearization extended to the node point — i(lx) + J(lx)·(x − lx)
///     (SPICE companion correction, dioload.c `cdeq = cd − gd·vd`).
///   residual-only (J·v FD): eval at lx + (local(x) − local(x_base)) so the
///     finite difference against the same-shifted baseline yields J(lx)·v,
///     consistent with the outer linearization.
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
    @setEvalBranchQuota(1_000_000);
    const n_u = comptime contract.nU(D);
    const has_limit = comptime @hasDecl(D, "limit");
    const S = if (with_diag) contract.Dual(n_u) else Value;
    const gath: [*]addrspace(.global) const u32 = @ptrCast(@alignCast(blob + desc.off_gath));
    const rhs_idx: [*]addrspace(.global) const u32 = @ptrCast(@alignCast(blob + desc.off_rhs_idx));
    const models: [*]addrspace(.global) const D.Model = @ptrCast(@alignCast(blob + desc.off_models));
    const instances: [*]addrspace(.global) const D.Instance = @ptrCast(@alignCast(blob + desc.off_instances));
    const lim: [*]addrspace(.global) const f64 = if (comptime has_limit)
        @ptrCast(@alignCast(blob + desc.off_lim))
    else
        undefined;
    const use_lim = if (comptime has_limit) limiting and desc.off_lim != 0 else false;

    var id: u32 = g.tid;
    while (id < desc.count) : (id += g.stride) {
        var xv: [n_u]S = undefined;
        // Companion-correction term local(x) − lx (zero when not limiting).
        var corr: @Vector(n_u, f64) = @splat(0);
        inline for (0..n_u) |u| {
            const xg = x[gath[id * n_u + u]];
            if (comptime with_diag) {
                var d: @Vector(n_u, f64) = @splat(0);
                d[u] = 1;
                var v = xg;
                if (use_lim) {
                    const lx = lim[id * n_u + u];
                    v = lx;
                    corr[u] = xg - lx;
                }
                xv[u] = .{ .v = v, .d = d };
            } else {
                var v = xg;
                if (use_lim)
                    v = lim[id * n_u + u] + (xg - x_base[gath[id * n_u + u]]);
                xv[u] = Value.con(v);
            }
        }
        const has_prep = comptime @hasDecl(D, "evalFromPrep");
        const out = if (comptime has_prep) blk: {
            const prep: [*]addrspace(.global) const D.PrepCache = @ptrCast(@alignCast(blob + desc.off_prep_cache));
            const group: [*]addrspace(.global) const u32 = @ptrCast(@alignCast(blob + desc.off_prep_group));
            break :blk D.evalFromPrep(S, xv, @addrSpaceCast(&prep[group[id]]), @addrSpaceCast(&models[id]), @addrSpaceCast(&instances[id]), t);
        } else D.eval(S, xv, @addrSpaceCast(&models[id]), @addrSpaceCast(&instances[id]), t);

        inline for (0..n_u) |ru| {
            const row = rhs_idx[id * n_u + ru];
            var val = out[ru].v;
            if (comptime with_diag and has_limit) {
                if (use_lim) val += @reduce(.Add, out[ru].d * corr);
            }
            _ = @atomicRmw(f64, &g.rhs[row], .Add, val, .monotonic);
            if (comptime with_diag) {
                // Diagonal Jacobian contribution: residual row == unknown col.
                inline for (0..n_u) |cu| {
                    if (row == gath[id * n_u + cu] and row < g.n)
                        _ = @atomicRmw(f64, &g.diag[row], .Add, out[ru].d[cu], .monotonic);
                }
            }
        }

        if (comptime @hasDecl(D, "q")) {
            if (env.active and desc.has_q != 0) {
                const qo = if (comptime @hasDecl(D, "qFromPrep")) blk: {
                    const prep: [*]addrspace(.global) const D.PrepCache = @ptrCast(@alignCast(blob + desc.off_prep_cache));
                    const group: [*]addrspace(.global) const u32 = @ptrCast(@alignCast(blob + desc.off_prep_group));
                    break :blk D.qFromPrep(S, xv, @addrSpaceCast(&prep[group[id]]), @addrSpaceCast(&models[id]), @addrSpaceCast(&instances[id]), t);
                } else D.q(S, xv, @addrSpaceCast(&models[id]), @addrSpaceCast(&instances[id]), t);

                inline for (0..n_u) |ru| {
                    const row = rhs_idx[id * n_u + ru];
                    var qv = qo[ru].v;
                    if (comptime with_diag and has_limit) {
                        if (use_lim) qv += @reduce(.Add, qo[ru].d * corr);
                    }
                    _ = @atomicRmw(f64, &g.rhs[row], .Add, env.alpha * qv, .monotonic);
                    if (env.snap) |sp|
                        _ = @atomicRmw(f64, &sp[row], .Add, qv, .monotonic);
                    if (comptime with_diag) {
                        inline for (0..n_u) |cu| {
                            if (row == gath[id * n_u + cu] and row < g.n)
                                _ = @atomicRmw(f64, &g.diag[row], .Add, env.alpha * qo[ru].d[cu], .monotonic);
                        }
                    }
                }
            }
        }
    }
}

/// Device limiting pass for one batch — the GPU port of batch.zig
/// applyLimits: cur = local(x); old = lim_x (once engaged) else local(x_old);
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
    const n_u = comptime contract.nU(D);
    const gath: [*]addrspace(.global) const u32 = @ptrCast(@alignCast(blob + desc.off_gath));
    const models: [*]addrspace(.global) const D.Model = @ptrCast(@alignCast(blob + desc.off_models));
    const instances: [*]addrspace(.global) const D.Instance = @ptrCast(@alignCast(blob + desc.off_instances));
    const lim: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + desc.off_lim));

    var flag: f64 = 0;
    var id: u32 = g.tid;
    while (id < desc.count) : (id += g.stride) {
        var cur: [n_u]f64 = undefined;
        var old: [n_u]f64 = undefined;
        inline for (0..n_u) |u| {
            cur[u] = x[gath[id * n_u + u]];
            old[u] = if (lim_active) lim[id * n_u + u] else x_old[gath[id * n_u + u]];
        }
        const lm = D.limit(@addrSpaceCast(&models[id]), @addrSpaceCast(&instances[id]), cur, old);
        inline for (0..n_u) |u| {
            if (lm[u] != cur[u]) flag = 1;
            lim[id * n_u + u] = lm[u];
        }
    }
    return flag;
}
