//! Analysis megakernel: ONE cooperative launch runs a whole Newton/JFNK
//! solve on-device — outer Newton loop, inner GMRES(m), device residual
//! evals, convergence gates — mirroring converger.jfnk() gate-for-gate so
//! CPU and GPU accept the same iterates. Host uploads the problem blob once
//! and reads back one contiguous window (x + ResultHeader). See gpu_abi.zig
//! for the blob layout.
//!
//! Execution model: grid-stride vector ops on all threads; scalar GMRES
//! bookkeeping (Givens, back-substitution, control flow) on global thread 0
//! with decisions published through workspace scalar slots; software grid
//! barrier between phases (sound under cuLaunchCooperativeKernel — proven
//! by barrier.zig / test-gpu).
//!
//! ponytail knowns, upgrade when measured: per-block reductions are one
//! f64 atomicAdd per thread into partials[block] (shared-memory tree later);
//! MGS dots are sequential (classical GS batching later); thread-0 scalar
//! sections idle the grid for O(m²) flops (irrelevant next to evals).

const devices = @import("dev_models");
const va_devices = @import("va_devices");
const contract = devices.contract;
const abi = @import("gpu_abi");

const Value = contract.Value;

const inf_f64: f64 = @bitCast(@as(u64, 0x7ff0000000000000));

// ---------------------------------------------------------------------------
// Barrier + reductions
// ---------------------------------------------------------------------------

inline fn blockSync() void {
    asm volatile ("bar.sync 0;" ::: .{ .memory = true });
}

inline fn memFence() void {
    // LLVM 21 drops atomicrmw orderings on NVPTX; membar.gl keeps the
    // barrier sound under the legacy PTX memory model.
    asm volatile ("membar.gl;" ::: .{ .memory = true });
}

const G = struct {
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

    inline fn sync(self: *const G) void {
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
    fn reduceAdd(self: *const G, partial: f64) f64 {
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
    fn reduceMax(self: *const G, partial: f64) f64 {
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
    fn reduceMin(self: *const G, partial: f64) f64 {
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
const TranEnv = struct {
    active: bool, // stamp alpha*q(x) into rhs (+ alpha*dQ diag)
    alpha: f64,
    cvec: ?[*]addrspace(.global) const f64, // step-constant companion part
    snap: ?[*]addrspace(.global) f64, // raw q(x) accumulation target (n+1)
};

const no_tran: TranEnv = .{ .active = false, .alpha = 0, .cvec = null, .snap = null };

// ---------------------------------------------------------------------------
// Residual evaluation — comptime dispatch over all device types.
// ---------------------------------------------------------------------------

fn isDevice(comptime D: type) bool {
    return @typeInfo(D) == .@"struct" and @hasDecl(D, "U") and @hasDecl(D, "eval") and @hasDecl(D, "Model");
}

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
fn evalBatch(
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

/// F(x) into g.rhs (+ Jacobian diag into g.diag): zero, dispatch every
/// batch, companion constant, ground stamp. Leaves gmin regularization to
/// the caller. With env.active the residual is the transient companion
/// F(x) = I(x) + alpha*q(x) + cvec (cvec carries the -alpha*q_prev / -i_prev
/// / gear history terms — constant within a timestep).
fn assemble(comptime with_diag: bool, g: *const G, hdr: *addrspace(.global) const abi.Header, blob: [*]addrspace(.global) u8, x: [*]addrspace(.global) const f64, t: f64, env: TranEnv, limiting: bool, x_base: [*]addrspace(.global) const f64) void {
    var i: u32 = g.tid;
    while (i < g.n + 1) : (i += g.stride) {
        g.rhs[i] = 0;
        if (comptime with_diag) {
            if (i < g.n) g.diag[i] = 0;
        }
        if (env.snap) |sp| sp[i] = 0;
    }
    g.sync();
    const table: [*]addrspace(.global) const abi.BatchDesc = @ptrCast(@alignCast(blob + hdr.off_batch_table));
    for (0..hdr.n_batches) |bi| {
        const desc = &table[bi];
        // Builtin models + build-time-baked Verilog-A/Verilog models
        // (-Dva-models) dispatch identically: same contract, same kindId.
        inline for (.{ devices, va_devices }) |M| {
            inline for (@typeInfo(M).@"struct".decls) |decl| {
                if (comptime @TypeOf(@field(M, decl.name)) == type) {
                    const D = @field(M, decl.name);
                    if (comptime isDevice(D)) {
                        if (desc.kind_id == comptime abi.kindId(D))
                            @call(.never_inline, evalBatch, .{ D, with_diag, g, desc, blob, x, t, env, limiting, x_base });
                    }
                }
            }
        }
    }
    g.sync();
    if (env.cvec) |cv| {
        i = g.tid;
        while (i < g.n) : (i += g.stride) g.rhs[i] += cv[i];
        g.sync();
    }
    if (g.tid == 0) {
        // Ground equation: g[0,0] = 1, rhs[0] = x[0].
        g.rhs[0] += x[0];
        if (comptime with_diag) g.diag[0] += 1.0;
    }
    g.sync();
}

/// Device limiting pass for one batch — the GPU port of batch.zig
/// applyLimits: cur = local(x); old = lim_x (once engaged) else local(x_old);
/// lim_x = D.limit(cur, old). Returns 1.0 if any component was limited
/// (thread-local partial; caller reduces grid-wide).
fn limitBatch(
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
            // Mirror batch.zig: only junction-limited unknowns
            // (limit_flag_unknowns) force another Newton iteration.
            const flags: bool = comptime blk: {
                if (!@hasDecl(D, "limit_flag_unknowns")) break :blk true;
                for (D.limit_flag_unknowns) |fu| {
                    if (@intFromEnum(fu) == u) break :blk true;
                }
                break :blk false;
            };
            if (flags and lm[u] != cur[u]) flag = 1;
            lim[id * n_u + u] = lm[u];
        }
    }
    return flag;
}

/// Run the limiting pass over every limited batch. Same comptime dispatch
/// as assemble(). Caller syncs + reduces the returned partial.
fn limitPass(
    g: *const G,
    hdr: *addrspace(.global) const abi.Header,
    blob: [*]addrspace(.global) u8,
    x: [*]addrspace(.global) const f64,
    x_old: [*]addrspace(.global) const f64,
    lim_active: bool,
) f64 {
    var flag: f64 = 0;
    const table: [*]addrspace(.global) const abi.BatchDesc = @ptrCast(@alignCast(blob + hdr.off_batch_table));
    for (0..hdr.n_batches) |bi| {
        const desc = &table[bi];
        if (desc.off_lim == 0) continue;
        inline for (.{ devices, va_devices }) |M| {
            inline for (@typeInfo(M).@"struct".decls) |decl| {
                if (comptime @TypeOf(@field(M, decl.name)) == type) {
                    const D = @field(M, decl.name);
                    if (comptime isDevice(D) and @hasDecl(D, "limit")) {
                        if (desc.kind_id == comptime abi.kindId(D))
                            flag = @max(flag, @call(.never_inline, limitBatch, .{ D, g, desc, blob, x, x_old, lim_active }));
                    }
                }
            }
        }
    }
    return flag;
}

// ---------------------------------------------------------------------------
// Shared workspace setup + Newton solve (arp_solve = one call; arp_tran =
// one call per timestep attempt with the companion env).
// ---------------------------------------------------------------------------

/// Carve the device workspace into the G views. Layout mirrors
/// abi.wsF64Count — the two cannot drift without both sides breaking.
fn setupG(hdr: *addrspace(.global) const abi.Header, blob: [*]addrspace(.global) u8) G {
    const n: u32 = hdr.n;
    const m: u32 = @min(hdr.tol.gmres_m, n);
    var g: G = undefined;
    g.n = n;
    g.m = m;
    g.n_blocks = hdr.n_blocks;
    g.ltid = @workItemId(0);
    g.bid = @workGroupId(0);
    g.tid = g.bid * @workGroupSize(0) + g.ltid;
    g.stride = @workGroupSize(0) * hdr.n_blocks;

    const ws: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + hdr.off_ws));
    var o: usize = 0;
    g.v_basis = ws + o;
    o += @as(usize, m + 1) * n;
    g.h = ws + o;
    o += @as(usize, m + 1) * m;
    g.cs = ws + o;
    o += m;
    g.sn = ws + o;
    o += m;
    g.g_vec = ws + o;
    o += m + 1;
    g.y_vec = ws + o;
    o += m;
    g.r = ws + o;
    o += n;
    g.w = ws + o;
    o += n;
    g.x_pert = ws + o;
    o += n;
    g.f0 = ws + o;
    o += n;
    g.f0_shift = ws + o;
    o += n;
    g.diag = ws + o;
    o += n;
    g.x_old = ws + o;
    o += n;
    g.rhs = ws + o;
    o += n + 1;
    g.x_try = ws + o;
    o += n;
    g.i_prev = ws + o;
    o += n;
    g.cvec = ws + o;
    o += n;
    g.q_hist = ws + o;
    o += 4 * (@as(usize, n) + 1);
    g.tstate = ws + o;
    o += 16;
    g.scal = ws + o;
    o += 16;
    g.partials = ws + o;
    o += abi.max_blocks;
    g.barrier_cg = @ptrCast(@alignCast(ws + o));
    return g;
}

// scal slot map (thread-0 owned): 0 reduce result | 1 eps | 2 control flag
// (0 none, 1 backtrack, 2 gmres-break, 3 done) | 3 beta/scale | 4 prev_norm
// | 5 jj | 6 gate violations | 7 backtrack count | 8 lim_active | 9..15 spare

/// One whole JFNK Newton solve on x (in place). Mirrors converger.jfnk()
/// gate-for-gate; with env.active the residual is the transient companion.
/// Writes iterations/max_dx (+ status on convergence) into res. Returns
/// converged — identical on every thread (all decisions flow through scal).
fn newtonSolve(
    g: *const G,
    hdr: *addrspace(.global) const abi.Header,
    blob: [*]addrspace(.global) u8,
    x: [*]addrspace(.global) f64,
    current_row: [*]addrspace(.global) const u8,
    res: *addrspace(.global) abi.ResultHeader,
    t: f64,
    env: TranEnv,
) bool {
    const n: u32 = g.n;
    const m: u32 = g.m;
    const tol = hdr.tol;
    // Perturbed (J·v) evals share the companion residual but must not
    // clobber the outer charge snapshot.
    const env_pert: TranEnv = .{ .active = env.active, .alpha = env.alpha, .cvec = env.cvec, .snap = null };

    // Init control state + x_old = x. Barrier counters are HOST-zeroed once
    // (blocks reach the first barrier before any thread could init them;
    // the sense-reversing barrier self-restores count=0 / monotonic gen, so
    // relaunches need no re-zeroing).
    if (g.tid == 0) {
        g.scal[2] = 0;
        g.scal[4] = 1e308; // prev_norm = "inf"
        g.scal[7] = 0; // backtrack count
        g.scal[8] = 0; // lim_active
    }
    // Any batch with device limiting? Uniform scan — same table every thread.
    const table_lim: [*]addrspace(.global) const abi.BatchDesc = @ptrCast(@alignCast(blob + hdr.off_batch_table));
    var has_lim = false;
    for (0..hdr.n_batches) |bi| {
        if (table_lim[bi].off_lim != 0) has_lim = true;
    }
    var i: u32 = g.tid;
    while (i < n) : (i += g.stride) g.x_old[i] = x[i];
    g.sync();

    var iter: u32 = 0;
    outer: while (iter < tol.max_iter) : (iter += 1) {
        // Device limiting engaged? (set by the limit pass of the previous
        // iteration; stable within one iteration.)
        const limiting = has_lim and g.scal[8] != 0;
        // F(x) + Jacobian diag, then gmin regularization (matches CPU: rhs
        // gets gmin·x; the preconditioner/gate diag gets +gmin).
        assemble(true, g, hdr, blob, x, t, env, limiting, x);
        var norm_partial: f64 = 0;
        i = g.tid;
        while (i < n) : (i += g.stride) {
            g.rhs[i] += tol.gmin * x[i];
            g.diag[i] += tol.gmin;
            norm_partial = @max(norm_partial, @abs(g.rhs[i]));
        }
        const norm_f = g.reduceMax(norm_partial);

        // Monotone residual safeguard (backtracking) — thread 0 decides.
        if (g.tid == 0) {
            const prev_norm = g.scal[4];
            var backtracks = g.scal[7];
            if (norm_f > 10.0 * prev_norm and backtracks < 16.0) {
                g.scal[2] = 1; // backtrack
                g.scal[7] = backtracks + 1;
            } else {
                g.scal[2] = 0;
                g.scal[7] = 0;
                g.scal[4] = norm_f;
            }
            backtracks = g.scal[7];
        }
        g.sync();
        if (g.scal[2] == 1) {
            i = g.tid;
            while (i < n) : (i += g.stride) x[i] = 0.5 * (x[i] + g.x_old[i]);
            g.sync();
            // Keep lim_x tracking the retreated x — mirrors the CPU
            // backtrack's applyLimits call.
            if (has_lim) {
                _ = limitPass(g, hdr, blob, x, g.x_old, limiting);
                if (g.tid == 0) g.scal[8] = 1;
                g.sync();
            }
            continue :outer;
        }

        // f0 = F(x)+gmin·x; Jacobi preconditioner = 1/diag.
        i = g.tid;
        while (i < n) : (i += g.stride) {
            g.f0[i] = g.rhs[i];
            const d = g.diag[i];
            g.diag[i] = if (@abs(d) > 1e-30) 1.0 / d else 1.0;
        }
        g.sync();

        // FD baseline: with limiting engaged, f0 carries the companion
        // correction J(lx)·(x−lx); differencing shifted perturbed evals
        // against it would leave an O(corr/ε) ghost. Difference against the
        // UNCORRECTED shifted residual at x itself (= i(lx) for limited
        // devices, i(x) for the rest). One extra residual-only eval per
        // outer iteration; a plain copy when limiting is off.
        if (limiting) {
            assemble(false, g, hdr, blob, x, t, env_pert, true, x);
            i = g.tid;
            while (i < n) : (i += g.stride) g.f0_shift[i] = g.rhs[i] + tol.gmin * x[i];
        } else {
            i = g.tid;
            while (i < n) : (i += g.stride) g.f0_shift[i] = g.f0[i];
        }
        g.sync();

        // r = -M⁻¹ f0; beta = ||r||.
        var acc: f64 = 0;
        i = g.tid;
        while (i < n) : (i += g.stride) {
            const ri = -g.f0[i] * g.diag[i];
            g.r[i] = ri;
            acc += ri * ri;
        }
        const beta = @sqrt(g.reduceAdd(acc));

        if (beta < tol.abstol) {
            if (iter > 0) {
                if (g.tid == 0) {
                    res.status = 1;
                    res.iterations = iter + 1;
                    res.max_dx = 0;
                }
                g.sync();
                return true;
            }
            continue :outer;
        }

        // v0 = r/beta; scalar GMRES state.
        i = g.tid;
        while (i < n) : (i += g.stride) g.v_basis[i] = g.r[i] / beta;
        if (g.tid == 0) {
            g.g_vec[0] = beta;
            for (1..m + 1) |k| g.g_vec[k] = 0;
            for (0..@as(usize, m + 1) * m) |k| g.h[k] = 0;
            g.scal[5] = 0; // jj
        }
        g.sync();

        var j: u32 = 0;
        gmres: while (j < m) : (j += 1) {
            const vj = g.v_basis + @as(usize, j) * n;

            // eps = sqrt(eps_mach)·max(||x||,1)/||v|| — two norms.
            acc = 0;
            i = g.tid;
            while (i < n) : (i += g.stride) acc += x[i] * x[i];
            const x_norm = @max(@sqrt(g.reduceAdd(acc)), 1.0);
            acc = 0;
            i = g.tid;
            while (i < n) : (i += g.stride) acc += vj[i] * vj[i];
            const v_norm = @sqrt(g.reduceAdd(acc));
            if (g.tid == 0) {
                const sqrt_eps = 1.4901161193847656e-8; // sqrt(f64 eps)
                g.scal[1] = if (v_norm > 1e-30) sqrt_eps * x_norm / v_norm else sqrt_eps;
            }
            g.sync();
            const eps = g.scal[1];

            i = g.tid;
            while (i < n) : (i += g.stride) g.x_pert[i] = x[i] + eps * vj[i];
            g.sync();

            // w = M⁻¹ (F(x+εv)+gmin·x_pert − f0_shift)/ε (residual-only,
            // shifted through lx when limiting so FD = J(lx)·v).
            assemble(false, g, hdr, blob, g.x_pert, t, env_pert, limiting, x);
            const inv_eps = 1.0 / eps;
            i = g.tid;
            while (i < n) : (i += g.stride)
                g.w[i] = ((g.rhs[i] + tol.gmin * g.x_pert[i]) - g.f0_shift[i]) * inv_eps * g.diag[i];
            g.sync();

            // Modified Gram-Schmidt (sequential dots — exactness over speed).
            var mi: u32 = 0;
            while (mi <= j) : (mi += 1) {
                const vi = g.v_basis + @as(usize, mi) * n;
                acc = 0;
                i = g.tid;
                while (i < n) : (i += g.stride) acc += vi[i] * g.w[i];
                const hij = g.reduceAdd(acc);
                if (g.tid == 0) g.h[@as(usize, mi) * m + j] = hij;
                i = g.tid;
                while (i < n) : (i += g.stride) g.w[i] -= hij * vi[i];
                g.sync();
            }
            acc = 0;
            i = g.tid;
            while (i < n) : (i += g.stride) acc += g.w[i] * g.w[i];
            const h_jp1 = @sqrt(g.reduceAdd(acc));
            if (g.tid == 0) g.h[@as(usize, j + 1) * m + j] = h_jp1;
            if (h_jp1 > 1e-30) {
                const vjp1 = g.v_basis + @as(usize, j + 1) * n;
                i = g.tid;
                while (i < n) : (i += g.stride) vjp1[i] = g.w[i] / h_jp1;
            }

            // Givens rotations + early-exit test — thread 0.
            if (g.tid == 0) {
                for (0..j) |k| {
                    const h_k = g.h[k * m + j];
                    const h_k1 = g.h[(k + 1) * m + j];
                    g.h[k * m + j] = g.cs[k] * h_k + g.sn[k] * h_k1;
                    g.h[(k + 1) * m + j] = -g.sn[k] * h_k + g.cs[k] * h_k1;
                }
                const a_val = g.h[@as(usize, j) * m + j];
                const b_val = g.h[@as(usize, j + 1) * m + j];
                const r_val = @sqrt(a_val * a_val + b_val * b_val);
                if (r_val > 1e-30) {
                    g.cs[j] = a_val / r_val;
                    g.sn[j] = b_val / r_val;
                } else {
                    g.cs[j] = 1.0;
                    g.sn[j] = 0.0;
                }
                g.h[@as(usize, j) * m + j] = r_val;
                g.h[@as(usize, j + 1) * m + j] = 0;
                const g_j = g.g_vec[j];
                const g_j1 = g.g_vec[j + 1];
                g.g_vec[j] = g.cs[j] * g_j + g.sn[j] * g_j1;
                g.g_vec[j + 1] = -g.sn[j] * g_j + g.cs[j] * g_j1;
                g.scal[5] = @floatFromInt(j + 1); // jj so far
                g.scal[2] = if (@abs(g.g_vec[j + 1]) < tol.abstol * 0.1) 2 else 0;
            }
            g.sync();
            if (g.scal[2] == 2) break :gmres;
        }

        // Back-substitution (thread 0), then dx = V·y into g.r.
        const jj: u32 = @intFromFloat(g.scal[5]);
        if (g.tid == 0 and jj > 0) {
            var k: u32 = jj;
            while (k > 0) {
                k -= 1;
                var s = g.g_vec[k];
                for (k + 1..jj) |kk| s -= g.h[@as(usize, k) * m + kk] * g.y_vec[kk];
                const d = g.h[@as(usize, k) * m + k];
                g.y_vec[k] = if (@abs(d) > 1e-30) s / d else 0;
            }
        }
        g.sync();
        i = g.tid;
        while (i < n) : (i += g.stride) {
            var dxi: f64 = 0;
            var k: u32 = 0;
            while (k < jj) : (k += 1) dxi += g.y_vec[k] * g.v_basis[@as(usize, k) * n + i];
            g.r[i] = dxi;
        }
        g.sync();

        // Direction-preserving damping.
        var mdx_p: f64 = 0;
        i = g.tid;
        while (i < n) : (i += g.stride) mdx_p = @max(mdx_p, @abs(g.r[i]));
        const mdx = g.reduceMax(mdx_p);
        if (mdx > tol.dx_clamp) {
            const s = tol.dx_clamp / mdx;
            i = g.tid;
            while (i < n) : (i += g.stride) g.r[i] *= s;
            g.sync();
        }

        // finalizeStep (mirrors converger.finalizeStep, no state flips):
        //   x_old = x; x += dx; device limiting pass; per-row delta-x
        //   criterion; iter-0 reject; limited-step reject; row-scaled
        //   residual gate on f0 with the (pre-inversion) diag.
        var scaled_p: f64 = 0;
        var viol_p: f64 = 0;
        i = g.tid;
        while (i < n) : (i += g.stride) {
            const dxi = g.r[i];
            const xo = x[i];
            const xn = xo + dxi;
            g.x_old[i] = xo;
            x[i] = xn;
            const atol = if (current_row[i] != 0) tol.abstol else tol.vntol;
            const tcrit = tol.reltol * @max(@abs(xn), @abs(xo)) + atol;
            scaled_p = @max(scaled_p, @abs(dxi) / tcrit);
            // residual gate — g.diag holds 1/diag; |diag| = 1/|inv|.
            const inv = g.diag[i];
            const scale = if (@abs(inv) > 1e-30) 1.0 / @abs(inv) else 0.0;
            const rtol = @max(tol.residual_tol, 10.0 * scale * (tol.reltol * @abs(xn) + tol.vntol));
            if (@abs(g.f0[i]) > rtol) viol_p = 1;
        }
        const scaled = g.reduceMax(scaled_p);
        const viol = g.reduceMax(viol_p);

        // Device limiting (pnjlim/fetlim): recompute lim_x at the updated x;
        // a limited step forces another iteration (same gate as the CPU).
        var limited: f64 = 0;
        if (has_lim) {
            // reduceMax above synced, so the x writes are grid-visible.
            const lf = limitPass(g, hdr, blob, x, g.x_old, limiting);
            limited = g.reduceMax(lf);
            if (g.tid == 0) g.scal[8] = 1;
            g.sync();
        }

        if (g.tid == 0) {
            const converged = iter > 0 and scaled < 1.0 and viol == 0 and limited == 0;
            g.scal[2] = if (converged) 3 else 0;
            if (converged) {
                res.status = 1;
                res.iterations = iter + 1;
                res.max_dx = scaled;
            } else {
                res.iterations = iter + 1;
                res.max_dx = scaled;
            }
        }
        g.sync();
        if (g.scal[2] == 3) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// arp_solve — one whole DC/OP Newton solve. Thin wrapper over newtonSolve.
// ---------------------------------------------------------------------------

fn arpSolve(blob: [*]addrspace(.global) u8) callconv(.kernel) void {
    @setFloatMode(.optimized);
    const hdr: *addrspace(.global) const abi.Header = @ptrCast(@alignCast(blob));
    if (hdr.magic != abi.magic) return;

    const g = setupG(hdr, blob);
    const x: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + hdr.off_x));
    const current_row: [*]addrspace(.global) const u8 = @ptrCast(blob + hdr.off_current_row);
    const res: *addrspace(.global) abi.ResultHeader = @ptrCast(@alignCast(blob + hdr.off_result));

    if (g.tid == 0) {
        res.status = 2;
        res.iterations = 0;
        res.max_dx = 0;
    }
    _ = newtonSolve(&g, hdr, blob, x, current_row, res, hdr.t, no_tran);
}

// ---------------------------------------------------------------------------
// arp_tran — whole transient analysis, one chunk of accepted timesteps per
// cooperative launch. Mirrors tran.simulate() decision-for-decision: same
// alpha, same LTE stepBound, same accept/reject/promote/breakpoint logic.
// Integration state persists in the device workspace between launches; the
// host only re-uploads the header (t_stop/dt bounds/chunk budget) and drains
// ResultHeader + the waveform buffer per chunk.
// ---------------------------------------------------------------------------

// tstate slot map (thread-0 persisted, mirrored into locals on every
// thread): 0 t | 1 dt | 2 dt_prev | 3 dt_prev2 | 4 use_be | 5 q_levels |
// 6 bp_landing | 7 rot (charge-ring rotation)

/// ngspice CKTterr / tran.integrator.stepBound: per-state timestep bound
/// (min over states), computed grid-stride + reduceMin. Same formulas as
/// the CPU scalar path, so accepted-dt decisions track the CPU integrator.
fn stepBound(
    g: *const G,
    order2: bool,
    q0: [*]addrspace(.global) const f64,
    q1: [*]addrspace(.global) const f64,
    q2: [*]addrspace(.global) const f64,
    q3: [*]addrspace(.global) const f64,
    alpha_used: f64,
    exec_trap: bool,
    dt: f64,
    dt1: f64,
    dt2: f64,
    hdr: *addrspace(.global) const abi.Header,
) f64 {
    const reltol = hdr.tol.reltol;
    const abstol = hdr.tol.abstol;
    const chgtol = hdr.chgtol;
    const trtol = hdr.trtol;
    var local: f64 = inf_f64;
    var i: u32 = g.tid;
    while (i < g.n) : (i += g.stride) {
        const ip = g.i_prev[i];
        const i_new = if (exec_trap)
            alpha_used * (q0[i] - q1[i]) - ip
        else
            alpha_used * (q0[i] - q1[i]);
        const volttol = abstol + reltol * @max(@abs(i_new), @abs(ip));
        const chargetol = reltol * @max(@max(@abs(q0[i]), @abs(q1[i])), chgtol) / dt;
        const tol_i = @max(volttol, chargetol);
        const f01 = (q0[i] - q1[i]) / dt;
        const f12 = (q1[i] - q2[i]) / dt1;
        const f012 = (f01 - f12) / (dt + dt1);
        var dd = f012;
        if (order2) {
            const f23 = (q2[i] - q3[i]) / dt2;
            const f123 = (f12 - f23) / (dt1 + dt2);
            dd = (f012 - f123) / (dt + dt1 + dt2);
        }
        const c: f64 = if (order2) 1.0 / 12.0 else 0.5;
        const del = trtol * tol_i / @max(abstol, c * @abs(dd));
        local = @min(local, del);
    }
    const mn = g.reduceMin(local);
    return if (order2) @sqrt(mn) else mn;
}

fn arpTran(blob: [*]addrspace(.global) u8) callconv(.kernel) void {
    @setFloatMode(.optimized);
    const hdr: *addrspace(.global) const abi.Header = @ptrCast(@alignCast(blob));
    if (hdr.magic != abi.magic) return;

    const g = setupG(hdr, blob);
    const n: u32 = g.n;
    const np1: usize = @as(usize, n) + 1;
    const x: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + hdr.off_x));
    const current_row: [*]addrspace(.global) const u8 = @ptrCast(blob + hdr.off_current_row);
    const res: *addrspace(.global) abi.ResultHeader = @ptrCast(@alignCast(blob + hdr.off_result));
    const probes: [*]addrspace(.global) const u32 = @ptrCast(@alignCast(blob + hdr.off_probes));
    const bps: [*]addrspace(.global) const f64 = @ptrCast(@alignCast(blob + hdr.off_breakpoints));
    const wave: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + hdr.off_wave));
    const wrow: usize = 1 + @as(usize, hdr.n_probes);

    // Any charge batch ⇒ companion residual + LTE control (uniform: every
    // thread scans the same table).
    const table: [*]addrspace(.global) const abi.BatchDesc = @ptrCast(@alignCast(blob + hdr.off_batch_table));
    var has_charge = false;
    for (0..hdr.n_batches) |bi| {
        if (table[bi].has_q != 0) has_charge = true;
    }
    const trap = hdr.method == 1;
    const gear = hdr.method == 2;

    if (hdr.tran_reset != 0) {
        if (g.tid == 0) {
            g.tstate[0] = 0; // t
            g.tstate[1] = hdr.dt_init; // dt
            g.tstate[2] = 0; // dt_prev
            g.tstate[3] = 0; // dt_prev2
            g.tstate[4] = 1; // use_be (order control starts at BE)
            g.tstate[5] = 0; // q_levels
            g.tstate[6] = 0; // bp_landing
            g.tstate[7] = 0; // rot
        }
        var ii: u32 = g.tid;
        while (ii < n) : (ii += g.stride) g.i_prev[ii] = 0;
        g.sync();
        if (has_charge) {
            // q(x, 0) into q_hist[1] (rot 0 ⇒ physical slot 1) — mirrors the
            // CPU's ckt.eval(x, 0) + q_prev seed. alpha = 0 keeps rhs inert.
            const env0: TranEnv = .{ .active = true, .alpha = 0, .cvec = null, .snap = g.q_hist + np1 };
            assemble(false, &g, hdr, blob, x, 0, env0, false, x);
        }
    }
    g.sync();

    // Local mirrors of tstate — identical on every thread (shared-memory
    // reads after syncs + deterministic f64 ops), so all control branches
    // below stay grid-uniform without extra scal round-trips.
    var t = g.tstate[0];
    var dt = g.tstate[1];
    var dt_prev = g.tstate[2];
    var dt_prev2 = g.tstate[3];
    var use_be = g.tstate[4] != 0;
    var q_levels: u32 = @intFromFloat(g.tstate[5]);
    var bp_landing = g.tstate[6] != 0;
    var rot: u32 = @intFromFloat(g.tstate[7]);

    var wave_len: u32 = 0;
    if (hdr.tran_reset != 0) {
        // Waveform point 0: (t = 0, seeded x).
        if (g.tid == 0) {
            wave[0] = 0;
            for (0..hdr.n_probes) |k| wave[1 + k] = x[probes[k]];
        }
        wave_len = 1;
    }

    var steps: u32 = 0;
    var status: u32 = abi.status_running;

    while (t < hdr.t_stop and steps < hdr.max_steps_chunk and wave_len < hdr.wave_capacity) {
        // Order control mirrors tran.simulate(): BE until LTE says the
        // configured method is safe; gear needs one history level.
        const use_gear = gear and !use_be and q_levels >= 1;
        const use_trap = trap and !use_be;
        const eff_be = use_be or (gear and !use_gear) or (!trap and !gear);
        const alpha: f64 = if (eff_be) 1.0 / dt else if (trap) 2.0 / dt else 3.0 / (2.0 * dt);
        const half_inv_dt: f64 = if (use_gear) 1.0 / (2.0 * dt) else 0;

        const qh0 = g.q_hist + @as(usize, (rot + 0) & 3) * np1;
        const qh1 = g.q_hist + @as(usize, (rot + 1) & 3) * np1;
        const qh2 = g.q_hist + @as(usize, (rot + 2) & 3) * np1;
        const qh3 = g.q_hist + @as(usize, (rot + 3) & 3) * np1;

        // Step-constant companion part:
        //   BE:   -alpha*q_prev
        //   trap: -alpha*q_prev - i_prev
        //   gear: -alpha*q_prev - (1/(2dt))*(q_prev - q_prev2)
        var i: u32 = g.tid;
        if (has_charge) {
            while (i < n) : (i += g.stride) {
                var c = -alpha * qh1[i];
                if (use_trap) c -= g.i_prev[i];
                if (use_gear) c -= half_inv_dt * (qh1[i] - qh2[i]);
                g.cvec[i] = c;
            }
        }
        i = g.tid;
        while (i < n) : (i += g.stride) g.x_try[i] = x[i];
        g.sync();

        const env: TranEnv = .{
            .active = has_charge,
            .alpha = alpha,
            .cvec = if (has_charge) g.cvec else null,
            .snap = if (has_charge) qh0 else null,
        };
        const conv = newtonSolve(&g, hdr, blob, g.x_try, current_row, res, t + dt, env);

        if (!conv) {
            dt *= 0.5;
            if (dt < hdr.dt_min) {
                status = abi.status_dt_underflow;
                break;
            }
            continue;
        }

        var dt_next = @min(dt * 1.5, hdr.dt_max);

        if (has_charge) {
            // qh0 = q(x) snapped by the last outer Newton assemble.
            const need: u32 = if (trap or gear) 2 else 1;
            if (q_levels >= need) {
                const order2 = !eff_be;
                const del = stepBound(&g, order2, qh0, qh1, qh2, qh3, alpha, use_trap, dt, dt_prev, dt_prev2, hdr);
                if (del < 0.9 * dt) {
                    dt *= 0.5;
                    if (dt < hdr.dt_min) {
                        status = abi.status_dt_underflow;
                        break;
                    }
                    continue;
                }
                dt_next = @min(@max(del, hdr.dt_min), hdr.dt_max);
            }

            // Promote BE → configured method when the higher-order LTE dt
            // is stable (ngspice: trap dt_next > 1.05 * dt).
            if (use_be and q_levels >= need) {
                const trial_order2 = hdr.method != 0;
                const trial_del = stepBound(&g, trial_order2, qh0, qh1, qh2, qh3, alpha, use_trap, dt, dt_prev, dt_prev2, hdr);
                if (trial_del > 1.05 * dt) use_be = false;
            }

            // Dynamic current update — must match the method actually used.
            i = g.tid;
            while (i < n) : (i += g.stride) {
                const dq = alpha * (qh0[i] - qh1[i]);
                g.i_prev[i] = if (use_trap) dq - g.i_prev[i] else dq;
            }
            rot = (rot + 3) & 3; // ring: new q_prev = old q_cur
            dt_prev2 = dt_prev;
            dt_prev = dt;
            if (q_levels < 2) q_levels += 1;
        }

        // Accept: x = x_try.
        i = g.tid;
        while (i < n) : (i += g.stride) x[i] = g.x_try[i];
        g.sync();
        t += dt;
        steps += 1;

        // Landed on a breakpoint last step: drop to BE + shrink dt.
        if (bp_landing) {
            use_be = true;
            dt_next = @min(dt_next, dt * 0.1);
            bp_landing = false;
        }

        // Record the accepted point (x visible after the sync above).
        if (g.tid == 0) {
            const row = wave + @as(usize, wave_len) * wrow;
            row[0] = t;
            for (0..hdr.n_probes) |k| row[1 + k] = x[probes[k]];
        }
        wave_len += 1;

        // Breakpoint clamp: first bp beyond t (same 1e-18 guard as the CPU
        // vsource nextBreakpoint + simulate()).
        var bi: u32 = 0;
        while (bi < hdr.n_breakpoints and bps[bi] <= t + 1e-18) bi += 1;
        if (bi < hdr.n_breakpoints) {
            const dt_to_bp = bps[bi] - t;
            if (dt_to_bp > 1e-18 and dt_to_bp < dt_next) {
                dt_next = dt_to_bp;
                bp_landing = true;
            }
        }

        dt = dt_next;
        if (t + dt > hdr.t_stop) dt = hdr.t_stop - t;
    }

    // Persist integration state + chunk results.
    g.sync();
    if (g.tid == 0) {
        g.tstate[0] = t;
        g.tstate[1] = dt;
        g.tstate[2] = dt_prev;
        g.tstate[3] = dt_prev2;
        g.tstate[4] = if (use_be) 1 else 0;
        g.tstate[5] = @floatFromInt(q_levels);
        g.tstate[6] = if (bp_landing) 1 else 0;
        g.tstate[7] = @floatFromInt(rot);
        res.steps = steps;
        res.wave_len = wave_len;
        res.t_final = t;
        res.dt_next = dt;
        res.status = if (status == abi.status_dt_underflow)
            status
        else if (t >= hdr.t_stop)
            abi.status_done
        else
            abi.status_running;
    }
}

comptime {
    @export(&arpSolve, .{ .name = "arp_solve" });
    @export(&arpTran, .{ .name = "arp_tran" });
}
