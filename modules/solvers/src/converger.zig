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
const BbdInfo = @import("root.zig").BbdInfo;

pub const Strategy = enum { newton, jfnk };

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

pub fn jfnk(
    sys: anytype,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const slv: ?*direct.Solver = &ws.slv;
    const dx = ws.dx;
    const x_old = ws.x_old;
    const n: usize = sys.n;
    const m: usize = @min(gmres_restart, n);

    const sz_vbasis = (m + 1) * n;
    const sz_hmat = (m + 1) * m;
    const buf = try ws.ensureGmres(n);

    var off: usize = 0;
    const v_basis = buf[off..][0..sz_vbasis]; off += sz_vbasis;
    const h_mat = buf[off..][0..sz_hmat]; off += sz_hmat;
    const cs = buf[off..][0..m]; off += m;
    const sn = buf[off..][0..m]; off += m;
    const g_vec = buf[off..][0..m + 1]; off += m + 1;
    const y_vec = buf[off..][0..m]; off += m;
    const r_vec = buf[off..][0..n]; off += n;
    const w_vec = buf[off..][0..n]; off += n;
    const x_pert = buf[off..][0..n]; off += n;
    const f0 = buf[off..][0..n]; off += n;
    const f_pert = buf[off..][0..n]; off += n;
    const diag_prec = buf[off..][0..n];

    var iter: u16 = 0;

    while (iter < opts.max_iter) : (iter += 1) {
        assembleResidual(sys, x, t, hook);
        if (opts.gmin > 0) {
            for (0..n) |i| {
                sys.rhs[i] += opts.gmin * x[i];
            }
        }
        var norm_f: f64 = 0;
        for (0..n) |i| norm_f = @max(norm_f, @abs(sys.rhs[i]));
        @memcpy(f0, sys.rhs[0..n]);

        buildDiagPreconditioner(sys, hook, opts, diag_prec);

        if (slv) |s| {
            const v = hook.vals(sys);
            if (opts.gmin > 0) {
                for (0..n) |i| {
                    v[sys.diag_slots[i]] += opts.gmin;
                }
            }
            s.factor(v) catch {};
        }

        for (0..n) |i| r_vec[i] = -f0[i];
        applyPreconditioner(r_vec, diag_prec, slv, n);

        const beta = vecNorm(r_vec[0..n]);
        if (beta < opts.abstol) {
            @memset(dx[0..n], 0);
            if (iter > 0)
                return .{ .converged = true, .iterations = iter + 1, .max_dx = 0 };
            continue;
        }

        const v0 = v_basis[0..n];
        for (0..n) |i| v0[i] = r_vec[i] / beta;
        g_vec[0] = beta;
        @memset(g_vec[1..], 0);
        @memset(h_mat, 0);

        var j: usize = 0;
        while (j < m) : (j += 1) {
            const vj = v_basis[j * n ..][0..n];
            jvProduct(sys, x, t, f0, vj, w_vec[0..n], x_pert[0..n], f_pert[0..n], n, hook, opts);

            applyPreconditioner(w_vec[0..n], diag_prec, slv, n);

            for (0..j + 1) |i| {
                const vi = v_basis[i * n ..][0..n];
                const hij = dot(vi, w_vec[0..n]);
                h_mat[i * m + j] = hij;
                for (0..n) |k| w_vec[k] -= hij * vi[k];
            }

            const h_jp1_j = vecNorm(w_vec[0..n]);
            h_mat[(j + 1) * m + j] = h_jp1_j;

            if (h_jp1_j > 1e-30) {
                const vjp1 = v_basis[(j + 1) * n ..][0..n];
                for (0..n) |k| vjp1[k] = w_vec[k] / h_jp1_j;
            }

            for (0..j) |i| {
                const h_i = h_mat[i * m + j];
                const h_i1 = h_mat[(i + 1) * m + j];
                h_mat[i * m + j] = cs[i] * h_i + sn[i] * h_i1;
                h_mat[(i + 1) * m + j] = -sn[i] * h_i + cs[i] * h_i1;
            }

            const a_val = h_mat[j * m + j];
            const b_val = h_mat[(j + 1) * m + j];
            const r_val = @sqrt(a_val * a_val + b_val * b_val);
            if (r_val > 1e-30) {
                cs[j] = a_val / r_val;
                sn[j] = b_val / r_val;
            } else {
                cs[j] = 1.0;
                sn[j] = 0.0;
            }
            h_mat[j * m + j] = r_val;
            h_mat[(j + 1) * m + j] = 0;

            const g_j = g_vec[j];
            const g_j1 = g_vec[j + 1];
            g_vec[j] = cs[j] * g_j + sn[j] * g_j1;
            g_vec[j + 1] = -sn[j] * g_j + cs[j] * g_j1;

            if (@abs(g_vec[j + 1]) < opts.abstol * 0.1) {
                j += 1;
                break;
            }
        }

        const jj = j;
        if (jj > 0) {
            backSolveUpperTriangular(h_mat, g_vec, y_vec, jj, m);

            @memset(dx[0..n], 0);
            for (0..jj) |k| {
                const vk = v_basis[k * n ..][0..n];
                for (0..n) |i| dx[i] += y_vec[k] * vk[i];
            }
        } else {
            @memset(dx[0..n], 0);
        }

        dampStep(dx[0..n], opts.dx_clamp);

        const st = finalizeStep(sys, x, dx, x_old, f0, hook.vals(sys), iter, opts);
        if (st.converged)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = st.scaled };
    }
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

    // GPU whole-Newton: only for hooks that declare gpu_eligible
    const hook_gpu = comptime @hasDecl(H, "gpu_eligible") and H.gpu_eligible;
    if (comptime @hasField(S, "gpu_hook") and hook_gpu) {
        if (sys.gpu_hook) |gh| {
            if (gh.solve_newton(gh.ctx, x, t, opts)) |r| {
                if (r.converged) return r;
            } else |_| {}
        }
    }

    // JFNK is the default strategy when GPU is active — matrix-free,
    // no factorization, same algorithm the megakernel runs so CPU/GPU
    // convergence is a superset. Direct Newton is the last resort.
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

fn jvProduct(
    sys: anytype,
    x: []const f64,
    t: f64,
    f0: []const f64,
    v: []const f64,
    out: []f64,
    x_pert: []f64,
    f_pert: []f64,
    n: usize,
    hook: anytype,
    opts: Options,
) void {
    const eps_mach = std.math.floatEps(f64);
    const sqrt_eps = @sqrt(eps_mach);
    const x_norm = @max(vecNorm(x[0..n]), 1.0);
    const v_norm = vecNorm(v[0..n]);
    const eps = if (v_norm > 1e-30) sqrt_eps * x_norm / v_norm else sqrt_eps;

    for (0..n) |i| x_pert[i] = x[i] + eps * v[i];

    assembleResidual(sys, x_pert, t, hook);
    if (opts.gmin > 0) {
        for (0..n) |i| {
            sys.rhs[i] += opts.gmin * x_pert[i];
        }
    }
    @memcpy(f_pert[0..n], sys.rhs[0..n]);

    const inv_eps = 1.0 / eps;
    for (0..n) |i| out[i] = (f_pert[i] - f0[i]) * inv_eps;
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

fn backSolveUpperTriangular(h: []const f64, g: []const f64, y: []f64, j: usize, m: usize) void {
    var k: usize = j;
    while (k > 0) {
        k -= 1;
        var s = g[k];
        for (k + 1..j) |i| s -= h[k * m + i] * y[i];
        const d = h[k * m + k];
        y[k] = if (@abs(d) > 1e-30) s / d else 0;
    }
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
        const total = (m + 1) * n + (m + 1) * m + m + m + (m + 1) + m + 6 * n;
        if (self.gmres.len < total) {
            self.slv.gpa.free(self.gmres);
            self.gmres = &.{};
            self.gmres = try self.slv.gpa.alloc(f64, total);
        }
        return self.gmres[0..total];
    }

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.slv.deinit();
        gpa.free(self.dx);
        gpa.free(self.x_old);
        gpa.free(self.gmres);
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

test "backSolveUpperTriangular: 2x2 system" {
    const m: usize = 2;
    const h = [_]f64{ 2, 1, 0, 3 };
    const g = [_]f64{ 5, 6 };
    var y: [2]f64 = undefined;
    backSolveUpperTriangular(&h, &g, &y, 2, m);
    try testing.expectApproxEqAbs(@as(f64, 1.5), y[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), y[1], 1e-15);
}
