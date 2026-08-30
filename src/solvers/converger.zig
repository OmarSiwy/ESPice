//! Newton / JFNK convergence — generic, solver-level.
//!
//! Parameterized over System and Hook via comptime duck-typing.
//!
//! System (sys: anytype, must be pointer) provides:
//!   Fields: .n, .diag_slots[]u32, .rhs[]f64, .current_row[]bool
//!   Optional methods: applyLimits, updateStates, clearLimits, nodeName
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
const BbdInfo = @import("types.zig").BbdInfo;

pub const Strategy = enum { newton, jfnk };

/// `ZPICEY_SOLVER` — pin the strategy `run` would otherwise pick by itself.
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

/// Read once. `getenv` on every Newton step of every timestep is not free, and
/// the value cannot change under a running process.
var solver_pin_cache: ?SolverPin = null;

pub fn solverPin() SolverPin {
    if (solver_pin_cache) |p| return p;
    const p: SolverPin = blk: {
        const s = std.c.getenv("ZPICEY_SOLVER") orelse break :blk .auto;
        const v = std.mem.span(s);
        if (std.mem.eql(u8, v, "direct")) break :blk .direct;
        if (std.mem.eql(u8, v, "jfnk")) break :blk .jfnk;
        if (std.mem.eql(u8, v, "jfnk-nolu")) break :blk .jfnk_nolu;
        break :blk .auto;
    };
    solver_pin_cache = p;
    return p;
}

pub fn opdbg() bool {
    return std.c.getenv("ZP_OPDBG") != null;
}

fn Deref(comptime P: type) type {
    return if (@typeInfo(P) == .pointer) @typeInfo(P).pointer.child else P;
}

// ---------------------------------------------------------------------------
// Tolerances — user-facing accuracy profile
// ---------------------------------------------------------------------------

pub const Tolerances = struct {
    reltol: f64 = 1e-3,
    abstol: f64 = 1e-12,
    vntol: f64 = 1e-6,
    gmin: f64 = 1e-12,
    residual_tol: f64 = 1e-9,
    dx_clamp: f64 = std.math.inf(f64),

    gmin_start: f64 = 1e-2,
    source_steps: u8 = 7,

    itl1: u16 = 100,
    itl2: u16 = 50,
    itl4: u16 = 10,

    chgtol: f64 = 1e-14,
    trtol: f64 = 7.0,

    pub const ngspice: Tolerances = .{};
    pub const hspice: Tolerances = .{ .itl1 = 150 };
    pub const ltspice: Tolerances = .{ .trtol = 1.0, .source_steps = 25 };
    pub const tight: Tolerances = .{
        .reltol = 1e-6,
        .vntol = 1e-9,
        .abstol = 1e-15,
        .gmin = 1e-15,
        .trtol = 1.0,
    };

    pub fn newtonOpts(self: Tolerances, max_iter_override: ?u16) Options {
        return .{
            .max_iter = max_iter_override orelse self.itl1,
            .abstol = self.abstol,
            .reltol = self.reltol,
            .vntol = self.vntol,
            .residual_tol = self.residual_tol,
            .gmin = self.gmin,
            .dx_clamp = self.dx_clamp,
        };
    }
};

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

    while (iter < opts.max_iter) : (iter += 1) {
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
        if (std.c.getenv("ZP_NEWTON_DEBUG") != null)
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
                std.debug.print("  newton it={d} |F|={e:.3}@{d}({s}) dx={e:.3}@{d}({s}) x={e:.3} scaled={e:.3} conv={}\n", .{ iter, norm_f, fi, name_fi, dx[di], di, name_di, x[di], st.scaled, st.converged });
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

const Step = struct { converged: bool, scaled: f64, flipped: bool = false };

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

    if (comptime @hasDecl(S, "updateStates")) {
        if (sys.updateStates(x)) |_| return .{ .converged = false, .scaled = scaled, .flipped = true };
    }
    if (limited) return .{ .converged = false, .scaled = scaled };
    if (iter == 0) return .{ .converged = false, .scaled = scaled };
    if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled };
    for (0..n) |i| {
        const scale = @abs(vals[sys.diag_slots[i]]);
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        if (@abs(residual[i]) > tol) return .{ .converged = false, .scaled = scaled };
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

        pub fn postStep(self: *Self, x: [*]f64, x_old: [*]f64, lim: bool) newton_core.PostStep {
            _ = lim;
            const S = Deref(SysT);
            const xs = x[0..self.n];
            const limited = if (comptime @hasDecl(S, "applyLimits"))
                self.sys.applyLimits(xs, x_old[0..self.n])
            else
                false;
            var flipped = false;
            if (comptime @hasDecl(S, "updateStates")) {
                if (self.sys.updateStates(xs)) |_| flipped = true;
            }
            return .{ .limited = limited, .flipped = flipped };
        }

        pub fn gateScale(self: *Self, i: u32) f64 {
            return @abs(self.hook.vals(self.sys)[self.sys.diag_slots[i]]);
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
    const v_basis = buf[off..].ptr; off += (m + 1) * n;
    const h_mat = buf[off..].ptr; off += (m + 1) * m;
    const cs = buf[off..].ptr; off += m;
    const sn = buf[off..].ptr; off += m;
    const g_vec = buf[off..].ptr; off += m + 1;
    const y_vec = buf[off..].ptr; off += m;
    const w_vec = buf[off..].ptr; off += n;
    const x_pert = buf[off..].ptr; off += n;
    const f0 = buf[off..].ptr; off += n;
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

    if (comptime @hasDecl(S, "clearLimits")) {
        defer sys.clearLimits();
    }

    const pin = solverPin();
    if (pin == .direct) return newton(sys, ws, x, t, opts, hook);
    if (pin == .jfnk or pin == .jfnk_nolu) {
        if (jfnk(sys, ws, x, t, opts, hook)) |r| {
            if (r.converged) return r;
        } else |_| {}
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
            } else |_| {}
        }
    }

    // JFNK when the GPU is live. NOT because it is matrix-free — as configured
    // here it is not; `CpuEnv.precondBuild` factors the Jacobian and uses that
    // LU as the preconditioner, so a step costs a stamp, a factorization AND
    // the GMRES matvecs. It earns its place by taking fewer steps, and its
    // matvecs are residual evals, which is the part the device made cheap.
    // `ZPICEY_SOLVER=jfnk-nolu` is the genuinely factorization-free variant.
    if (comptime @hasField(S, "gpu_active")) {
        if (sys.gpu_active) {
            const r = try jfnk(sys, ws, x, t, opts, hook);
            if (r.converged) return r;
        }
    }

    // JFNK first even without GPU — faster for large sparse systems
    // where LU fill-in dominates. Falls through to direct Newton only
    // if JFNK fails to converge.
    if (jfnk(sys, ws, x, t, opts, hook)) |r| {
        if (r.converged) return r;
    } else |_| {}
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

fn vecNorm(v: []const f64) f64 {
    var s: f64 = 0;
    for (v) |vi| s += vi * vi;
    return @sqrt(s);
}

fn dot(a: []const f64, b: []const f64) f64 {
    var s: f64 = 0;
    for (a, b) |ai, bi| s += ai * bi;
    return s;
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "vecNorm: unit vector" {
    const v = [_]f64{ 3.0, 4.0 };
    try testing.expectApproxEqAbs(@as(f64, 5.0), vecNorm(&v), 1e-15);
}

test "dot: inner product" {
    const a = [_]f64{ 1.0, 2.0, 3.0 };
    const b = [_]f64{ 4.0, 5.0, 6.0 };
    try testing.expectApproxEqAbs(@as(f64, 32.0), dot(&a, &b), 1e-15);
}

