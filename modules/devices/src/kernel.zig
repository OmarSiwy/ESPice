//! Analysis megakernel: ONE cooperative launch runs a whole Newton/JFNK
//! solve on-device — outer Newton loop, inner GMRES(m), device residual
//! evals, convergence gates — the solver body is single-sourced with
//! converger.jfnk() (modules/solvers/src/newton_core.zig, imported as the
//! `newton_core` module) so CPU and GPU accept the same iterates by
//! construction. Host uploads the problem blob once
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
const abi = @import("gpu_abi");
const newton_core = @import("newton_core");

// Driver TU imports the models ONLY for decl names + kindId hashes; the
// physics lives in per-model stub TUs (kernel_stub.zig) resolved by symbol
// name at nvlink time. Nothing here instantiates a device eval.
const common = @import("kernel_common.zig");
const G = common.G;
const TranEnv = common.TranEnv;
const no_tran = common.no_tran;
const isDevice = common.isDevice;
const inf_f64 = common.inf_f64;

// ---------------------------------------------------------------------------
// Residual evaluation — comptime dispatch over all device types.
// ---------------------------------------------------------------------------

/// F(x) into g.rhs (+ Jacobian diag into g.diag): zero, dispatch every
/// batch, companion constant, ground stamp. Leaves gmin regularization to
/// the caller. With env.active the residual is the transient companion
/// F(x) = I(x) + alpha*q(x) + cvec (cvec carries the -alpha*q_prev / -i_prev
/// / gear history terms — constant within a timestep).
fn assembleEval(comptime with_diag: bool, g: *const G, hdr: *addrspace(.global) const abi.Header, blob: [*]addrspace(.global) u8, x: [*]addrspace(.global) const f64, t: f64, env: TranEnv, limiting: bool, x_base: [*]addrspace(.global) const f64) void {
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
        inline for (@typeInfo(devices).@"struct".decls) |decl| {
            if (comptime @TypeOf(@field(devices, decl.name)) == type) {
                const D = @field(devices, decl.name);
                if (comptime isDevice(D)) {
                    if (desc.kind_id == comptime abi.kindId(D)) {
                        // Physics lives in the model's stub TU; resolved by nvlink.
                        const suffix = if (with_diag) "_d" else "_r";
                        const f = @extern(common.EbFn, .{ .name = "arp_eb_" ++ decl.name ++ suffix });
                        f(g, desc, blob, x, t, &env, limiting, x_base);
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
        inline for (@typeInfo(devices).@"struct".decls) |decl| {
            if (comptime @TypeOf(@field(devices, decl.name)) == type) {
                const D = @field(devices, decl.name);
                if (comptime isDevice(D) and @hasDecl(D, "limit")) {
                    if (desc.kind_id == comptime abi.kindId(D)) {
                        const f = @extern(common.LbFn, .{ .name = "arp_lb_" ++ decl.name });
                        flag = @max(flag, f(g, desc, blob, x, x_old, lim_active));
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
// (0 none, 1 backtrack, 2 gmres-break, 3 done) | 3 spare | 4 prev_norm
// | 5 jj | 6 spare | 7 backtrack count | 8 lim_active | 9..15 spare
// (slots 1/2/4/5/7/8 are owned by newton_core via publish/read)

/// Cooperative-grid Env for newton_core.newtonSolve: grid-stride tid/stride,
/// software grid barrier + atomic reductions from common.G, thread-0 publish
/// slots through g.scal. backtrack=true (monotone-residual retreat),
/// exact_jv=false (f0_shift FD baseline; J·v via residual-only shifted
/// evals), Jacobi preconditioner from the assembled diag.
const GpuEnv = struct {
    g: *const G,
    hdr: *addrspace(.global) const abi.Header,
    blob: [*]addrspace(.global) u8,
    tran: TranEnv,
    // Perturbed (J·v) evals share the companion residual but must not
    // clobber the outer charge snapshot.
    tran_pert: TranEnv,
    has_lim: bool,
    current_row: [*]addrspace(.global) const u8,

    pub const F64 = [*]addrspace(.global) f64;
    pub const backtrack = true;
    pub const exact_jv = false;

    pub inline fn tid(e: *const GpuEnv) u32 {
        return e.g.tid;
    }
    pub inline fn stride(e: *const GpuEnv) u32 {
        return e.g.stride;
    }
    pub inline fn isLead(e: *const GpuEnv) bool {
        return e.g.tid == 0;
    }
    pub inline fn sync(e: *const GpuEnv) void {
        e.g.sync();
    }
    pub inline fn reduceAdd(e: *const GpuEnv, partial: f64) f64 {
        return e.g.reduceAdd(partial);
    }
    pub inline fn reduceMax(e: *const GpuEnv, partial: f64) f64 {
        return e.g.reduceMax(partial);
    }
    pub inline fn publish(e: *const GpuEnv, slot: usize, val: f64) void {
        e.g.scal[slot] = val;
    }
    pub inline fn read(e: *const GpuEnv, slot: usize) f64 {
        return e.g.scal[slot];
    }
    /// Device limiting engaged? (set by the limit pass of the previous
    /// iteration; stable within one iteration.)
    pub inline fn limiting(e: *const GpuEnv) bool {
        return e.has_lim and e.g.scal[8] != 0;
    }

    /// F(x) (+ Jacobian diag when with_diag) + gmin regularization into
    /// g.rhs. Residual-only evals use the snap-less companion env.
    pub fn assemble(e: *const GpuEnv, comptime with_diag: bool, x_eval: F64, x_base: F64, t: f64, lim: bool) void {
        assembleEval(with_diag, e.g, e.hdr, e.blob, x_eval, t, if (with_diag) e.tran else e.tran_pert, lim, x_base);
        const gmin = e.hdr.tol.gmin;
        var i: u32 = e.g.tid;
        while (i < e.g.n) : (i += e.g.stride) e.g.rhs[i] += gmin * x_eval[i];
        // No sync: rhs is consumed own-index only (assembleEval synced the
        // atomic scatter already).
    }

    /// Jacobi preconditioner: diag = 1/(J_diag + gmin), in place.
    pub fn precondBuild(e: *const GpuEnv) void {
        const gmin = e.hdr.tol.gmin;
        var i: u32 = e.g.tid;
        while (i < e.g.n) : (i += e.g.stride) {
            const d = e.g.diag[i] + gmin;
            e.g.diag[i] = if (@abs(d) > 1e-30) 1.0 / d else 1.0;
        }
    }

    pub fn precondApply(e: *const GpuEnv, r: F64) void {
        var i: u32 = e.g.tid;
        while (i < e.g.n) : (i += e.g.stride) r[i] *= e.g.diag[i];
    }

    /// Device limiting (pnjlim/fetlim): recompute lim_x at the updated x;
    /// a limited step forces another iteration (same gate as the CPU).
    pub fn postStep(e: *const GpuEnv, x: F64, x_old: F64, lim: bool) newton_core.PostStep {
        var limited: f64 = 0;
        if (e.has_lim) {
            // Core reduced/synced before calling, so x writes are visible.
            const lf = limitPass(e.g, e.hdr, e.blob, x, x_old, lim);
            limited = e.g.reduceMax(lf);
            if (e.g.tid == 0) e.g.scal[8] = 1;
            e.g.sync();
        }
        return .{ .limited = limited != 0, .flipped = false };
    }

    /// Residual gate scale — g.diag holds 1/diag; |diag| = 1/|inv|.
    pub fn gateScale(e: *const GpuEnv, i: u32) f64 {
        const inv = e.g.diag[i];
        return if (@abs(inv) > 1e-30) 1.0 / @abs(inv) else 0.0;
    }

    pub fn currentRow(e: *const GpuEnv, i: u32) bool {
        return e.current_row[i] != 0;
    }
};

/// One whole JFNK Newton solve on x (in place) — newton_core.newtonSolve
/// with the cooperative-grid env; with env.active the residual is the
/// transient companion. Writes iterations/max_dx (+ status on convergence)
/// into res. Returns converged — identical on every thread (all decisions
/// flow through scal). Barrier counters are HOST-zeroed once (blocks reach
/// the first barrier before any thread could init them; the sense-reversing
/// barrier self-restores count=0 / monotonic gen, so relaunches need no
/// re-zeroing).
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
    // Any batch with device limiting? Uniform scan — same table every thread.
    const table_lim: [*]addrspace(.global) const abi.BatchDesc = @ptrCast(@alignCast(blob + hdr.off_batch_table));
    var has_lim = false;
    for (0..hdr.n_batches) |bi| {
        if (table_lim[bi].off_lim != 0) has_lim = true;
    }
    var genv: GpuEnv = .{
        .g = g,
        .hdr = hdr,
        .blob = blob,
        .tran = env,
        .tran_pert = .{ .active = env.active, .alpha = env.alpha, .cvec = env.cvec, .snap = null },
        .has_lim = has_lim,
        .current_row = current_row,
    };
    const vecs: newton_core.Vecs([*]addrspace(.global) f64) = .{
        .v_basis = g.v_basis,
        .h = g.h,
        .cs = g.cs,
        .sn = g.sn,
        .g_vec = g.g_vec,
        .y_vec = g.y_vec,
        .r = g.r,
        .w = g.w,
        .x_pert = g.x_pert,
        .f0 = g.f0,
        .f0_shift = g.f0_shift,
        .diag = g.diag,
        .x_old = g.x_old,
        .rhs = g.rhs,
    };
    const tol: newton_core.Tol = .{
        .reltol = hdr.tol.reltol,
        .abstol = hdr.tol.abstol,
        .vntol = hdr.tol.vntol,
        .residual_tol = hdr.tol.residual_tol,
        .gmin = hdr.tol.gmin,
        .dx_clamp = hdr.tol.dx_clamp,
        .max_iter = hdr.tol.max_iter,
        .gmres_m = hdr.tol.gmres_m,
    };
    const r = newton_core.newtonSolve(&genv, vecs, x, t, tol, g.n, g.m);
    if (g.tid == 0) {
        res.iterations = r.iterations;
        res.max_dx = r.max_dx;
        if (r.converged) res.status = 1;
    }
    g.sync();
    return r.converged;
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
            assembleEval(false, &g, hdr, blob, x, 0, env0, false, x);
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

// ---------------------------------------------------------------------------
// arp_solve_batch — N independent Newton lanes in one cooperative launch.
// Each lane gets blocks_per_lane blocks with lane-local barriers. Lanes
// share the blob's immutable prefix (batch table, payloads, current_row)
// but have private x, result, and workspace regions.
// ---------------------------------------------------------------------------

/// Carve workspace for a specific lane. Same layout as setupG but:
///   - ws_base points into the lane's private region
///   - n_blocks = blocks_per_lane (lane-local barrier)
///   - bid/tid/stride computed from lane-local block ID
fn setupGLane(
    hdr: *addrspace(.global) const abi.Header,
    ws: [*]addrspace(.global) f64,
    blocks_per_lane: u32,
    lane_bid: u32,
) G {
    const n: u32 = hdr.n;
    const m: u32 = @min(hdr.tol.gmres_m, n);
    var g: G = undefined;
    g.n = n;
    g.m = m;
    g.n_blocks = blocks_per_lane;
    g.ltid = @workItemId(0);
    g.bid = lane_bid;
    g.tid = lane_bid * @workGroupSize(0) + g.ltid;
    g.stride = @workGroupSize(0) * blocks_per_lane;

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
    o += blocks_per_lane;
    g.barrier_cg = @ptrCast(@alignCast(ws + o));
    return g;
}

fn arpSolveBatch(
    blob: [*]addrspace(.global) u8,
    batch_hdr: *addrspace(.global) const abi.BatchLaunchHeader,
) callconv(.kernel) void {
    @setFloatMode(.optimized);
    const hdr: *addrspace(.global) const abi.Header = @ptrCast(@alignCast(blob));
    if (hdr.magic != abi.magic) return;

    const bpl = batch_hdr.blocks_per_lane;
    if (bpl == 0) return;
    const lane_id = @workGroupId(0) / bpl;
    if (lane_id >= batch_hdr.n_lanes) return;
    const lane_bid = @workGroupId(0) % bpl;

    // Lane's private region: x | result | workspace
    const lane_base = @as(usize, batch_hdr.shared_size) + @as(usize, lane_id) * batch_hdr.lane_stride;
    const n: usize = hdr.n;
    const x: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + lane_base));
    const res_off = lane_base + n * 8;
    const res: *addrspace(.global) abi.ResultHeader = @ptrCast(@alignCast(blob + abi.alignUp(res_off, 8)));
    const ws_off = abi.alignUp(res_off + @sizeOf(abi.ResultHeader), 8);
    const ws: [*]addrspace(.global) f64 = @ptrCast(@alignCast(blob + ws_off));

    const g = setupGLane(hdr, ws, bpl, lane_bid);
    const current_row: [*]addrspace(.global) const u8 = @ptrCast(blob + hdr.off_current_row);

    if (g.tid == 0) {
        res.status = 2;
        res.iterations = 0;
        res.max_dx = 0;
    }
    _ = newtonSolve(&g, hdr, blob, x, current_row, res, hdr.t, no_tran);
}

comptime {
    @export(&arpSolve, .{ .name = "arp_solve" });
    @export(&arpTran, .{ .name = "arp_tran" });
    @export(&arpSolveBatch, .{ .name = "arp_solve_batch" });
}
