//! Newton / JFNK convergence — generic, solver-level.
//!
//! Parameterized over System and Hook via comptime duck-typing.
//!
//! System (sys: anytype, must be pointer) provides:
//!   Fields: .n, .diag_slots[]u32, .rhs[]f64, .current_row[]bool
//!   Optional methods: beginSolve, advanceIteration, checkConvergence,
//!     applyLimits, updateStates, clearLimits, nodeName, checkpoint
//!   Optional fields: .gpu_active, .gpu_hook
//!
//! Hook (hook: anytype) provides:
//!   assemble(sys, x, t) void  — fill planes + rhs
//!   vals(sys) []f64           — matrix to factor (newton path only)
//!   Optional: residual(sys, x, t) void — JFNK residual-only eval
//!   Optional: pub const gpu_eligible = true — gates GPU whole-Newton

const std = @import("std");
const direct = @import("direct.zig");
const newton_core = @import("newton_core.zig");
const BbdInfo = @import("numerics").BbdInfo;

pub const Strategy = enum { newton, jfnk };

/// `ESPICE_SOLVER` — pin the strategy `run` would otherwise pick by itself.
///
/// Exists because the three regimes differ by MORE than speed and which one
/// wins is a property of the circuit, not of the hardware:
///
///   auto       the ladder below: device Newton, then JFNK, then direct.
///   direct     stamp + sparse LU + one solve per Newton step.
///   jfnk       stamp + sparse LU (as the PRECONDITIONER) + k GMRES matvecs.
///              Strictly more work per step than `direct`; it wins only by
///              taking fewer steps, because the LU is still there.
///   jfnk-nolu  stamp + k GMRES matvecs, Jacobi-preconditioned, NO
///              factorization at all. The only regime that actually removes
///              the CPU-serial LU, and so the only one whose cost falls as
///              device eval gets faster — but Jacobi on a stiff circuit
///              Jacobian stagnates readily, so it is opt-in and measured, not
///              a default.
pub const SolverPin = enum { auto, direct, jfnk, jfnk_nolu };

/// Cache the process setting on first use; concurrent first readers may repeat
/// the lookup. Later environment changes do not reconfigure active analyses.
var solver_pin_cache: std.atomic.Value(u8) = .init(std.math.maxInt(u8));

pub fn solverPin() SolverPin {
    const cached = solver_pin_cache.load(.monotonic);
    if (cached != std.math.maxInt(u8)) return @enumFromInt(cached);
    const p: SolverPin = blk: {
        const s = std.c.getenv("ESPICE_SOLVER") orelse break :blk .auto;
        const v = std.mem.span(s);
        break :blk std.StaticStringMap(SolverPin).initComptime(.{
            .{ "direct", .direct }, .{ "jfnk", .jfnk }, .{ "jfnk-nolu", .jfnk_nolu },
        }).get(v) orelse .auto;
    };
    solver_pin_cache.store(@intFromEnum(p), .monotonic);
    return p;
}

/// Same one-shot rule as `solverPin`: both of these are read from inside the
/// Newton loop (`newton` tests `ZP_NEWTON_DEBUG` per iterate and `opdbg` per
/// iterate under `opdbgEnabled`), and glibc's `getenv` is a linear scan of
/// `environ` — measured 1.58 M instructions, 0.35% of a devices/mos6_inverter
/// run, spent deciding not to print.
// 0 = unread, 1 = false, 2 = true. Only the cached byte is published.
var opdbg_cache: std.atomic.Value(u8) = .init(0);
var newton_dbg_cache: std.atomic.Value(u8) = .init(0);

pub fn opdbg() bool {
    return envFlag(&opdbg_cache, "ZP_OPDBG");
}

pub fn newtonDbg() bool {
    return envFlag(&newton_dbg_cache, "ZP_NEWTON_DEBUG");
}

fn envFlag(cache: *std.atomic.Value(u8), name: [*:0]const u8) bool {
    const cached = cache.load(.monotonic);
    if (cached != 0) return cached == 2;
    const v = std.c.getenv(name) != null;
    cache.store(@as(u8, @intFromBool(v)) + 1, .monotonic);
    return v;
}

/// Why an iterate was refused. `finalizeStep` has five independent gates and
/// they cost very different things, so "did not converge" alone is not a
/// diagnosis: a run that needs one extra iteration per timepoint everywhere is
/// a 1.5x tax, and which gate is charging it decides whether the fix is in the
/// solver, the device limiter or a device's state machine.
///
/// ngspice's own test is `NIconvTest` (maths/ni/niconv.c): the per-node
/// solution-delta test and nothing else, plus `NIiter`'s iterno==1 floor and
/// the device-set CKTnoncon (limiting) flag. `.residual` has no counterpart
/// there — it is ours. MEASURED, and it is NOT the tax: gating it off across
/// vacask/mul moved 1499519 Newton iterations to 1499341 (0.01%), against
/// ngspice's 1018450 for the same 500k timepoints. Left in.
pub const Reject = enum { converged, first_iter, delta, limited, flipped, residual, device };

fn Deref(comptime P: type) type {
    return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
}

// ---------------------------------------------------------------------------
// Tolerances — user-facing accuracy profile
// ---------------------------------------------------------------------------

pub const Tolerances = @import("numerics").Tolerances;

pub fn optionsFromTolerances(tol: Tolerances, max_iter_override: ?u16) Options {
    return .{
        .max_iter = max_iter_override orelse tol.itl1,
        .abstol = tol.abstol,
        .reltol = tol.reltol,
        .vntol = tol.vntol,
        .residual_tol = tol.residual_tol,
        // DIAGONAL gmin is opt-in (op's gmin-stepping rung), never a
        // default: ngspice's NIiter loads none — junction gmin lives in
        // the device models. The always-on 1e-12 shunt this used to
        // carry pinned every solution a little off ngspice's answer
        // (voltage_divider read a 2.5e-9 offset from it).
        .gmin = 0,
        .dx_clamp = tol.dx_clamp,
    };
}

// ---------------------------------------------------------------------------
// Options — internal Newton interface
// ---------------------------------------------------------------------------

pub const Options = struct {
    max_iter: u16 = 100,
    abstol: f64 = 1e-12,
    reltol: f64 = 1e-3,
    vntol: f64 = 1e-6,
    residual_tol: f64 = 1e-9,
    gmin: f64 = 1e-12,
    dx_clamp: f64 = std.math.inf(f64),
    matrix_sig: u64 = 0,
};

pub const Result = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
};

// ============================================================================
// Newton (direct)
// ============================================================================

pub fn newton(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const S = Deref(@TypeOf(sys));
    const slv = &ws.slv;
    const dx = ws.dx;
    const x_old = ws.x_old;
    var iter: u16 = 0;
    if (comptime @hasDecl(S, "beginSolve")) sys.beginSolve();

    while (iter < opts.max_iter) : (iter += 1) {
        if (comptime @hasDecl(S, "checkpoint")) if (iter != 0)
            try sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = opts.max_iter });
        if (comptime @hasDecl(S, "advanceIteration")) if (iter != 0) sys.advanceIteration(x_old);
        hook.assemble(sys, x, t);
        const v = hook.vals(sys);
        if (opts.gmin > 0) {
            for (0..sys.n) |i| {
                v[sys.diag_slots[i]] += opts.gmin;
                sys.rhs[i] += opts.gmin * x[i];
            }
        }
        var norm_f: f64 = 0;
        for (0..sys.n) |i| norm_f = @max(norm_f, @abs(sys.rhs[i]));
        if (newtonDbg())
            std.debug.print("  it={d} |F|={e} x={any}\n", .{ iter, norm_f, x[0..@min(sys.n, 8)] });
        if (opts.matrix_sig == 0 or ws.factored_sig != opts.matrix_sig) {
            slv.factor(v) catch |e| {
                if (opdbg()) {
                    var nan_cnt: usize = 0;
                    var max_x: f64 = 0;
                    for (v[0..sys.nnz]) |vi| {
                        if (!std.math.isFinite(vi)) nan_cnt += 1;
                    }
                    for (0..sys.n) |i| max_x = @max(max_x, @abs(x[i]));
                    std.debug.print("  newton it={d} FACTOR FAIL {} nan_vals={d} max|x|={e:.3} |F|={e:.3}\n", .{ iter, e, nan_cnt, max_x, norm_f });
                }
                return e;
            };
            ws.factored_sig = opts.matrix_sig;
        }
        slv.solveNeg(sys.rhs, dx);
        dampStep(dx[0..sys.n], opts.dx_clamp);
        const st = finalizeStep(sys, x, dx, x_old, sys.rhs, v, iter, opts);
        if (comptime opdbgEnabled(S)) {
            if (opdbg()) {
                var fi: usize = 0;
                var di: usize = 0;
                for (0..sys.n) |i| {
                    if (@abs(sys.rhs[i]) > @abs(sys.rhs[fi])) fi = i;
                    if (@abs(dx[i]) > @abs(dx[di])) di = i;
                }
                const name_fi = sysNodeName(sys, @intCast(fi));
                const name_di = sysNodeName(sys, @intCast(di));
                std.debug.print("  newton it={d} |F|={e:.3}@{d}({s}) dx={e:.3}@{d}({s}) x={e:.3} scaled={e:.3} conv={} why={s}\n", .{ iter, norm_f, fi, name_fi, dx[di], di, name_di, x[di], st.scaled, st.converged, @tagName(st.why) });
            }
        }
        if (st.converged)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = st.scaled };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

fn opdbgEnabled(comptime S: type) bool {
    _ = S;
    return true;
}

fn sysNodeName(sys: anytype, idx: u32) []const u8 {
    const S = Deref(@TypeOf(sys));
    if (comptime @hasDecl(S, "nodeName")) return sys.nodeName(idx);
    return "?";
}

// ----------------------------------------------------------------------------
// Shared step acceptance
// ----------------------------------------------------------------------------

const Step = struct { converged: bool, scaled: f64, flipped: bool = false, why: Reject = .converged };

fn dampStep(dx: []f64, clamp: f64) void {
    if (!std.math.isFinite(clamp)) return;
    var mdx: f64 = 0;
    for (dx) |d| mdx = @max(mdx, @abs(d));
    if (mdx > clamp) {
        const s = clamp / mdx;
        for (dx) |*d| d.* *= s;
    }
}

fn finalizeStep(
    sys: anytype,
    x: []f64,
    dx: []const f64,
    x_old: []f64,
    residual: []const f64,
    vals: []const f64,
    iter: u16,
    opts: Options,
) Step {
    const S = Deref(@TypeOf(sys));
    const n = sys.n;
    @memcpy(x_old[0..n], x[0..n]);
    const scaled = updateAndNorm(x[0..n], dx[0..n], x_old[0..n], sys.current_row, opts.reltol, opts.abstol, opts.vntol);

    const limited = if (comptime @hasDecl(S, "applyLimits")) sys.applyLimits(x, x_old) else false;

    if (limited) return .{ .converged = false, .scaled = scaled, .why = .limited };
    if (iter == 0) return .{ .converged = false, .scaled = scaled, .why = .first_iter };
    if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled, .why = .delta };
    for (0..n) |i| {
        const scale = @abs(vals[sys.diag_slots[i]]);
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        if (@abs(residual[i]) > tol) return .{ .converged = false, .scaled = scaled, .why = .residual };
    }
    if (comptime @hasDecl(S, "checkConvergence")) {
        if (!sys.checkConvergence(x)) return .{ .converged = false, .scaled = scaled, .why = .device };
    }
    // LAST, not first. `updateState` stages `wb`/`wq` (read only by
    // `stateCtl(.commit)`, once per ACCEPTED step) and `bound_step` (read only
    // by `ckt.boundStep()`, after an accepted step) — nothing in the Newton
    // loop reads either, and `state.t_prev` is written by every generated
    // device and read by none. Running it per iterate re-entered the FULL
    // model core once per instance per iteration: 348.9M instructions, 18.1%
    // of scaling/parallel_inverters_100 (callgrind, 2026-09-07). Here it runs
    // once per converged solve at exactly the x `commit` will use.
    //
    // Bit-identical for 36 of the 40 generated devices, by field-set argument:
    // `updateState` writes {wb__, wq__, bound_step, discontinuity_order,
    // t_prev} and `core` reads {pb__, pq__, pc__, temperature} — DISJOINT, so
    // the staging cannot reach a later eval/limit/q of the same device. And
    // `wq` is OVERWRITTEN, not accumulated (`inst.wq__0 = m.f23.v`); the
    // accumulation is `pq += wq` in `stateCtl(.commit)`. That double-buffer is
    // what made the per-iterate call safe, and it is also why moving it here
    // stages the same bytes: under either placement the converged iterate is
    // the last one before commit.
    //
    // For the other 4 it is a CORRECTNESS FIX, not just waste removal.
    // cswitch/vswitch `core` READS `__held__latched` and `__cross__*__prev`,
    // which `updateState` writes — per-iterate, the hysteresis latch advanced
    // between Newton iterates, so F was not a fixed function of x during the
    // solve. hisim2/hisimhv write a raw `$prev` ddt latch that their own
    // `stateCtl` neither stages nor reverts; this reduces the damage from
    // per-iterate to per-converged-attempt (the real fix is to route them to
    // the `commit_state` hook — `hasAbsdelayState` is the wrong predicate).
    //
    // A device that flips at the converged point still forces another iterate —
    // the only place a flip is worth acting on. All 27 generated devices return
    // `.ok` unconditionally today, so that branch is dead; it stays for the
    // first device that isn't.
    if (comptime @hasDecl(S, "updateStates")) {
        if (sys.updateStates(x)) |_| return .{ .converged = false, .scaled = scaled, .flipped = true, .why = .flipped };
    }
    return .{ .converged = true, .scaled = scaled };
}

// ============================================================================
// JFNK — Jacobian-Free Newton-Krylov (restarted GMRES(m))
// ============================================================================

const gmres_restart = 30;

/// Serial Env for newton_core: tid=0/stride=1 makes every core loop the
/// plain 0..n loop, reduce = identity, publish = local scalar array — the
/// iterate trajectory is bit-identical to the historical serial jfnk.
fn CpuEnv(comptime SysT: type, comptime HookT: type) type {
    return struct {
        const Self = @This();
        sys: SysT,
        hook: HookT,
        opts: Options,
        slv: ?*direct.Solver,
        n: usize,
        diag: []f64,
        scal: [16]f64 = @splat(0),
        cancelled: bool = false,

        pub const F64 = [*]f64;
        pub const backtrack = false; // GPU-only monotone-residual retreat
        pub const exact_jv = true; // FD against f0 directly (no f0_shift)

        pub inline fn tid(_: *Self) u32 {
            return 0;
        }
        pub inline fn stride(_: *Self) u32 {
            return 1;
        }
        pub inline fn isLead(_: *Self) bool {
            return true;
        }
        pub inline fn sync(_: *Self) void {}
        pub inline fn reduceAdd(_: *Self, partial: f64) f64 {
            return partial;
        }
        pub inline fn reduceMax(_: *Self, partial: f64) f64 {
            return partial;
        }
        pub inline fn publish(self: *Self, slot: usize, val: f64) void {
            self.scal[slot] = val;
        }
        pub inline fn read(self: *Self, slot: usize) f64 {
            return self.scal[slot];
        }
        pub inline fn limiting(_: *Self) bool {
            return false; // CPU limiting lives in applyLimits/postStep
        }

        pub fn checkpoint(self: *Self, iter: u32) bool {
            if (comptime @hasDecl(Deref(SysT), "checkpoint")) {
                self.sys.checkpoint(.{ .phase = .nonlinear, .completed = iter, .total = self.opts.max_iter }) catch {
                    self.cancelled = true;
                    return false;
                };
            }
            return true;
        }

        pub fn assemble(self: *Self, comptime with_diag: bool, x_eval: [*]f64, x_base: [*]f64, t: f64, lim: bool) void {
            _ = with_diag; // CPU eval always fills what the hook fills
            _ = x_base;
            _ = lim;
            assembleResidual(self.sys, x_eval[0..self.n], t, self.hook);
            if (self.opts.gmin > 0) {
                for (0..self.n) |i| self.sys.rhs[i] += self.opts.gmin * x_eval[i];
            }
        }

        pub fn precondBuild(self: *Self) void {
            buildDiagPreconditioner(self.sys, self.hook, self.opts, self.diag);
            if (self.slv) |s| {
                const v = self.hook.vals(self.sys);
                if (self.opts.gmin > 0) {
                    for (0..self.n) |i| {
                        v[self.sys.diag_slots[i]] += self.opts.gmin;
                    }
                }
                s.factor(v) catch {};
            }
        }

        pub fn precondApply(self: *Self, r: [*]f64) void {
            applyPreconditioner(r[0..self.n], self.diag, self.slv, self.n);
        }

        pub fn beginSolve(self: *Self) void {
            if (comptime @hasDecl(Deref(SysT), "beginSolve")) self.sys.beginSolve();
        }

        pub fn advanceIteration(self: *Self, previous_x: [*]f64) void {
            if (comptime @hasDecl(Deref(SysT), "advanceIteration")) self.sys.advanceIteration(previous_x[0..self.n]);
        }

        pub fn acceptStep(self: *Self, x: [*]f64) bool {
            const S = Deref(SysT);
            const xs = x[0..self.n];
            if (comptime @hasDecl(S, "checkConvergence")) {
                if (!self.sys.checkConvergence(xs)) return false;
            }
            if (comptime @hasDecl(S, "updateStates")) {
                if (self.sys.updateStates(xs) != null) return false;
            }
            return true;
        }

        pub fn postStep(self: *Self, x: [*]f64, x_old: [*]f64, lim: bool) newton_core.PostStep {
            _ = lim;
            const S = Deref(SysT);
            const xs = x[0..self.n];
            const limited = if (comptime @hasDecl(S, "applyLimits"))
                self.sys.applyLimits(xs, x_old[0..self.n])
            else
                false;
            return .{ .limited = limited, .flipped = false };
        }

        /// |J_ii| for the residual gate. `diagAt` and not `vals(...)[slot]`:
        /// the latter rebuilt the ENTIRE combined plane to read one entry, so
        /// the gate loop cost O(n·nnz) per Newton iteration instead of O(n).
        /// On a linear RC ladder that was 34% of total instructions.
        pub fn gateScale(self: *Self, i: u32) f64 {
            return @abs(self.hook.diagAt(self.sys, self.sys.diag_slots[i]));
        }

        pub fn currentRow(self: *Self, i: u32) bool {
            return self.sys.current_row[i];
        }
    };
}

pub fn jfnk(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const n: usize = sys.n;
    const m: usize = @min(gmres_restart, n);
    const buf = try ws.ensureGmres(n);

    var off: usize = 0;
    const v_basis = buf[off..].ptr;
    off += (m + 1) * n;
    const h_mat = buf[off..].ptr;
    off += (m + 1) * m;
    const cs = buf[off..].ptr;
    off += m;
    const sn = buf[off..].ptr;
    off += m;
    const g_vec = buf[off..].ptr;
    off += m + 1;
    const y_vec = buf[off..].ptr;
    off += m;
    const w_vec = buf[off..].ptr;
    off += n;
    const x_pert = buf[off..].ptr;
    off += n;
    const f0 = buf[off..].ptr;
    off += n;
    const diag_prec = buf[off..][0..n];

    var env: CpuEnv(@TypeOf(sys), @TypeOf(hook)) = .{
        .sys = sys,
        .hook = hook,
        .opts = opts,
        // A null solver is what makes this matrix-free: `precondBuild` skips
        // `s.factor` and `applyPreconditioner` falls back to the Jacobi diagonal
        // it always builds. That is the ONLY configuration in which JFNK
        // removes the factorization rather than merely wrapping it.
        .slv = if (solverPin() == .jfnk_nolu) null else &ws.slv,
        .n = n,
        .diag = diag_prec,
    };
    const vecs: newton_core.Vecs([*]f64) = .{
        .v_basis = v_basis,
        .h = h_mat,
        .cs = cs,
        .sn = sn,
        .g_vec = g_vec,
        .y_vec = y_vec,
        .r = ws.dx.ptr, // dx lives in ws.dx, exactly as before
        .w = w_vec,
        .x_pert = x_pert,
        .f0 = f0,
        .f0_shift = f0, // unused with exact_jv
        .diag = diag_prec.ptr,
        .x_old = ws.x_old.ptr,
        .rhs = sys.rhs.ptr,
    };
    const tol: newton_core.Tol = .{
        .reltol = opts.reltol,
        .abstol = opts.abstol,
        .vntol = opts.vntol,
        .residual_tol = opts.residual_tol,
        .gmin = opts.gmin,
        .dx_clamp = opts.dx_clamp,
        .max_iter = opts.max_iter,
        .gmres_m = @intCast(m),
    };
    const r = newton_core.newtonSolve(&env, vecs, x.ptr, t, tol, @intCast(n), @intCast(m));
    if (env.cancelled) return error.QueryCancelled;
    if (r.converged)
        return .{ .converged = true, .iterations = @intCast(r.iterations), .max_dx = r.max_dx };
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

/// Auto-picks strategy. Optional GPU path via sys.gpu_hook + hook.gpu_eligible.
pub fn run(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const S = Deref(@TypeOf(sys));
    const H = @TypeOf(hook);

    // `defer` is scoped to its ENCLOSING BLOCK, so wrapping this in an
    // `if { defer ... }` ran the cleanup at the closing brace — before the
    // solve below, not after it. Device limiting therefore stayed armed for
    // every caller, and any analysis that re-evaluates at a perturbed x got a
    // Jacobian frozen at the last Newton iterate (disto's finite difference
    // read G against itself and produced exactly zero HD2). The condition
    // belongs INSIDE one function-scoped defer.
    defer if (comptime @hasDecl(S, "clearLimits")) sys.clearLimits();

    const pin = solverPin();
    if (pin == .direct) return newton(sys, ws, x, t, opts, hook);
    if (pin == .jfnk or pin == .jfnk_nolu) {
        if (jfnk(sys, ws, x, t, opts, hook)) |r| {
            if (r.converged) return r;
        } else |err| if (err == error.QueryCancelled) return err;
        // Still falls back: a pin is a preference, not a promise to return a
        // wrong answer.
        return newton(sys, ws, x, t, opts, hook);
    }

    // GPU whole-Newton: only for hooks that declare gpu_eligible
    const hook_gpu = comptime @hasDecl(H, "gpu_eligible") and H.gpu_eligible;
    if (comptime @hasField(S, "gpu_hook") and hook_gpu) {
        if (sys.gpu_hook) |gh| {
            if (gh.solve_newton(gh.ctx, x, t, opts)) |r| {
                if (r.converged) return r;
            } else |err| if (err == error.QueryCancelled) return err;
        }
    }

    // Direct Newton. JFNK used to run FIRST here, on the reasoning that it
    // wins "for large sparse systems where LU fill-in dominates" — measured,
    // it does not, at any size this simulator has a fixture for.
    //
    // The cost model says why. As configured, JFNK is not matrix-free:
    // `CpuEnv.precondBuild` factors the Jacobian and uses that LU as the
    // preconditioner, so a step costs a stamp, a factorization AND the GMRES
    // matvecs — and each matvec is a FULL device sweep, `assemble(false, ...)`
    // at newton_core.zig:242. On a 31-unknown MOS transient that was 30
    // matvecs per Newton iteration (`gmres_m = min(30, n)`, and the early-exit
    // never fired), so 96.8% of all device evaluation was finite-difference
    // Jacobian probing. Device evaluation is ~92% of a transient. Direct
    // Newton pays one sweep and one solve.
    //
    // Best-of-2 wall clock, ReleaseFast, this machine (RTX 4060, GPU forced on
    // for the cuda rows; it otherwise declines this much work):
    //
    //   fixture                unkn    backend  direct   jfnk    jfnk-nolu
    //   resistor_grid_32x32    ~1k     cpu       0.01    0.02      0.16
    //   resistor_grid_100x100  ~10k    cpu       0.19    0.21     10.76
    //   rc_ladder_1k           ~1k     cpu       0.22    5.65      8.74
    //   rc_ladder_10k          ~10k    cpu       2.19    4.76     39.40
    //   rc_ladder_10k          ~10k    cuda      2.03    4.77     39.88
    //
    // Direct wins every row, on both backends, on .op and .tran alike, and
    // the gap widens with n rather than closing. There is no crossover to
    // find, so there is no size threshold to encode here.
    //
    // JFNK stays reachable via ESPICE_SOLVER=jfnk / jfnk-nolu, and that is not
    // decoration. CORRECTION to the commit that made this change: it claimed
    // JFNK rescues nothing direct Newton cannot do. That is wrong.
    // scaling/parallel_inverters_100 is a counterexample — direct Newton
    // returns OpDidNotConverge in 10.0s, JFNK solves it in 14.3s. Neither
    // solver is a superset of the other (convergence/diode_bridge goes the
    // other way), so `auto` is a cost choice, not a capability one.
    //
    // It is deliberately NOT wired as an automatic fallback after a failed
    // direct solve. Two measurements killed that:
    //
    //   - JFNK only rescues parallel_inverters_100 when it drives the WHOLE
    //     op continuation ladder. Patching individual failed rungs follows a
    //     different trajectory and still fails (184s, still ERR).
    //   - `run` is called per continuation rung and per timestep, and a failed
    //     rung is normal, so an unconditional retry charges a full JFNK solve
    //     for something the ladder already handles: ensemble/pvt_corners
    //     0.29s -> 2.90s, bjt/diff_amp 0.02s -> 0.71s.
    //
    // Doing it properly means restarting the whole op ladder under JFNK, at
    // the dc/op level rather than here. Until someone needs that, the pin is
    // the honest interface.
    //
    // `gpu_active` no longer selects it either. The GPU makes device eval
    // cheaper, which is JFNK's cost centre AND direct Newton's; it does not
    // change which of the two does less work.
    return newton(sys, ws, x, t, opts, hook);
}

// ============================================================================
// JFNK helpers
// ============================================================================

fn assembleResidual(sys: anytype, x: []const f64, t: f64, hook: anytype) void {
    if (@hasDecl(@TypeOf(hook), "residual"))
        hook.residual(sys, x, t)
    else
        hook.assemble(sys, x, t);
}

fn buildDiagPreconditioner(sys: anytype, hook: anytype, opts: Options, diag: []f64) void {
    const v = hook.vals(sys);
    for (0..sys.n) |i| {
        var d = v[sys.diag_slots[i]];
        if (opts.gmin > 0) d += opts.gmin;
        diag[i] = if (@abs(d) > 1e-30) 1.0 / d else 1.0;
    }
}

fn applyPreconditioner(r: []f64, diag: []const f64, slv: ?*direct.Solver, n: usize) void {
    if (slv) |s| {
        if (s.factored) {
            s.solve(r, r);
            return;
        }
    }
    for (0..n) |i| r[i] *= diag[i];
}

fn updateAndNorm(x: []f64, dx: []const f64, x_old: []const f64, current_row: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
    var worst: f64 = 0;
    for (x, dx, x_old, current_row) |*xi, dxi, xoi, is_cur| {
        xi.* += dxi;
        const atol = if (is_cur) abstol else vntol;
        const tol = reltol * @max(@abs(xi.*), @abs(xoi)) + atol;
        worst = @max(worst, @abs(dxi) / tol);
    }
    return worst;
}

// ============================================================================
// Workspace — generic, init from raw pattern params
// ============================================================================

pub const Workspace = struct {
    slv: direct.Solver,
    dx: []f64,
    x_old: []f64,
    gmres: []f64 = &.{},
    a_vals: []f64 = &.{},
    factored_sig: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, n: u32, col_ptr: []const u32, row_idx: []const u32, bbd: ?BbdInfo) !Workspace {
        const dx = try gpa.alloc(f64, n);
        errdefer gpa.free(dx);
        const x_old = try gpa.alloc(f64, n);
        errdefer gpa.free(x_old);
        return .{
            .slv = try direct.Solver.init(gpa, n, col_ptr, row_idx, bbd),
            .dx = dx,
            .x_old = x_old,
        };
    }

    fn ensureGmres(self: *Workspace, n: usize) ![]f64 {
        const m: usize = @min(gmres_restart, n);
        const total = (m + 1) * n + (m + 1) * m + m + m + (m + 1) + m + 4 * n;
        if (self.gmres.len < total) {
            self.slv.gpa.free(self.gmres);
            self.gmres = &.{};
            self.gmres = try self.slv.gpa.alloc(f64, total);
        }
        return self.gmres[0..total];
    }

    /// Scratch for tran's combined G+alpha*C matrix values (length nnz).
    /// Lifetime: per-circuit, reused across every tran run (pss/envelope/
    /// tran_noise drive simulate repeatedly). Grows if too small, mirrors gmres.
    pub fn ensureAVals(self: *Workspace, nnz: u32) ![]f64 {
        if (self.a_vals.len < nnz) {
            self.slv.gpa.free(self.a_vals);
            // Empty between free and alloc: if alloc errors, deinit must not
            // double-free the stale slice.
            self.a_vals = &.{};
            self.a_vals = try self.slv.gpa.alloc(f64, nnz);
        }
        return self.a_vals[0..nnz];
    }

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.slv.deinit();
        gpa.free(self.dx);
        gpa.free(self.x_old);
        gpa.free(self.gmres);
        gpa.free(self.a_vals);
        self.* = undefined;
    }
};
