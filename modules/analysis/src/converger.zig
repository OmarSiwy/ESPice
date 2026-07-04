//! Newton / JFNK convergence strategies.
//!
//! dc / tran / envelope / tran_noise / pnoise / pss all converge through
//! this; they differ only in the Hook, which decides what gets assembled
//! and which vals plane is factored.
//!
//! Two strategies:
//!   newton — direct: assemble → gmin → factor → solveNeg → clamp → update
//!   jfnk   — Jacobian-Free Newton-Krylov: assemble + GMRES(m) where the
//!            J·v product is approximated by finite difference over the
//!            residual. No factorization needed — GPU-native.
//!
//! Hook contract (comptime duck-typed):
//!   assemble(ckt, x, t) void  — fill planes + rhs
//!   vals(ckt) []f64           — matrix to factor (newton path only)
//!
//! Optional hook methods (duck-typed, presence checked at comptime):
//!   residual(ckt, x, t) void  — assemble for residual-only evaluation
//!                               (JFNK path; falls back to assemble)

const std = @import("std");
const root = @import("root.zig");
const direct = root.solvers.direct;

pub const Strategy = enum { newton, jfnk };

pub fn pickStrategy(n: u32, gpu: bool) Strategy {
    if (gpu) return .jfnk;
    if (n > 5000) return .jfnk;
    return .newton;
}

pub const Options = struct {
    max_iter: u16 = 100,
    abstol: f64 = 1e-12,
    /// Diagonal regularization. The MNA matrix includes the ground row and
    /// is structurally singular without it.
    gmin: f64 = 1e-12,
    dx_clamp: f64 = 10.0,
};

pub const Result = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
};

/// Plain hook: assemble = one eval, matrix = G. This IS dc.
pub const EvalHook = struct {
    pub fn assemble(_: EvalHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
    }
    pub fn vals(_: EvalHook, ckt: *root.Circuit) []f64 {
        return ckt.g_vals;
    }
};

// ============================================================================
// Newton (direct) — exact existing semantics
// ============================================================================

/// Direct Newton solve: hook.assemble → gmin → slv.factor → slv.solveNeg →
/// clamp → limits → updateStates → convergence check.
pub fn newton(
    ckt: *root.Circuit,
    slv: *direct.Solver,
    x: []f64,
    dx: []f64,
    x_old: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    var iter: u16 = 0;
    while (iter < opts.max_iter) : (iter += 1) {
        hook.assemble(ckt, x, t);
        const v = hook.vals(ckt);
        if (opts.gmin > 0) {
            for (0..ckt.n) |i| {
                v[ckt.diag_slots[i]] += opts.gmin;
                ckt.rhs[i] += opts.gmin * x[i];
            }
        }
        try slv.factor(v);
        slv.solveNeg(ckt.rhs, dx);
        for (dx[0..ckt.n]) |*d| d.* = std.math.clamp(d.*, -opts.dx_clamp, opts.dx_clamp);
        @memcpy(x_old[0..ckt.n], x[0..ckt.n]);
        const max_dx = updateAndNorm(x[0..ckt.n], dx[0..ckt.n]);
        ckt.applyLimits(x, x_old);
        if (ckt.updateStates(x)) |_| continue; // state flip: force another iteration
        if (max_dx < opts.abstol)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = max_dx };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

// ============================================================================
// JFNK — Jacobian-Free Newton-Krylov (restarted GMRES(m))
// ============================================================================

/// GMRES workspace parameters.
const gmres_restart = 30;

/// JFNK solve: outer Newton loop with inner GMRES(m) linear solve.
/// J·v approximated by finite difference: (F(x+εv) - F(x))/ε.
/// Optional block-Jacobi preconditioner from BBD or diagonal Jacobi.
pub fn jfnk(
    ckt: *root.Circuit,
    slv: ?*direct.Solver,
    x: []f64,
    dx: []f64,
    x_old: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
    gpa: std.mem.Allocator,
) !Result {
    const n: usize = ckt.n;
    const m: usize = @min(gmres_restart, n);

    // GMRES workspace: Krylov basis V (m+1 vectors of length n),
    // Hessenberg H ((m+1) x m), cosines/sines (m), g (m+1), y (m),
    // scratch vectors for matvec.
    const v_basis = try gpa.alloc(f64, (m + 1) * n);
    defer gpa.free(v_basis);
    const h_mat = try gpa.alloc(f64, (m + 1) * m);
    defer gpa.free(h_mat);
    const cs = try gpa.alloc(f64, m);
    defer gpa.free(cs);
    const sn = try gpa.alloc(f64, m);
    defer gpa.free(sn);
    const g_vec = try gpa.alloc(f64, m + 1);
    defer gpa.free(g_vec);
    const y_vec = try gpa.alloc(f64, m);
    defer gpa.free(y_vec);
    const r_vec = try gpa.alloc(f64, n);
    defer gpa.free(r_vec);
    const w_vec = try gpa.alloc(f64, n);
    defer gpa.free(w_vec);
    const x_pert = try gpa.alloc(f64, n);
    defer gpa.free(x_pert);
    const f0 = try gpa.alloc(f64, n);
    defer gpa.free(f0);
    const f_pert = try gpa.alloc(f64, n);
    defer gpa.free(f_pert);
    // Diagonal preconditioner (frozen per outer Newton iteration)
    const diag_prec = try gpa.alloc(f64, n);
    defer gpa.free(diag_prec);

    var iter: u16 = 0;
    while (iter < opts.max_iter) : (iter += 1) {
        // Evaluate F(x) = residual at current x
        assembleResidual(ckt, x, t, hook);
        if (opts.gmin > 0) {
            for (0..n) |i| {
                ckt.rhs[i] += opts.gmin * x[i];
            }
        }
        // f0 = F(x) = rhs (note: Newton solves J*dx = -F)
        @memcpy(f0, ckt.rhs[0..n]);

        // Build frozen diagonal preconditioner from the matrix diagonal
        buildDiagPreconditioner(ckt, hook, opts, diag_prec);

        // Use BBD preconditioner if available (factor once per outer Newton)
        if (slv) |s| {
            const v = hook.vals(ckt);
            if (opts.gmin > 0) {
                for (0..n) |i| {
                    v[ckt.diag_slots[i]] += opts.gmin;
                }
            }
            s.factor(v) catch {
                // If factorization fails, fall back to diagonal preconditioning
                // (slv stays unfactored, we just use diag_prec)
            };
        }

        // GMRES to solve J*dx = -F(x)
        // r = -F(x) (preconditioned)
        for (0..n) |i| r_vec[i] = -f0[i];
        applyPreconditioner(r_vec, diag_prec, slv, n);

        const beta = vecNorm(r_vec[0..n]);
        if (beta < opts.abstol) {
            @memset(dx[0..n], 0);
            return .{ .converged = true, .iterations = iter + 1, .max_dx = 0 };
        }

        // v_0 = r / beta
        const v0 = v_basis[0..n];
        for (0..n) |i| v0[i] = r_vec[i] / beta;
        g_vec[0] = beta;
        @memset(g_vec[1..], 0);
        @memset(h_mat, 0);

        var j: usize = 0;
        while (j < m) : (j += 1) {
            // w = J * v_j (finite difference approximation)
            const vj = v_basis[j * n ..][0..n];
            jvProduct(ckt, x, t, f0, vj, w_vec[0..n], x_pert[0..n], f_pert[0..n], n, hook, opts);

            // Right-precondition: w = M^{-1} * (J * v_j)
            applyPreconditioner(w_vec[0..n], diag_prec, slv, n);

            // Modified Gram-Schmidt orthogonalization
            for (0..j + 1) |i| {
                const vi = v_basis[i * n ..][0..n];
                const hij = dot(vi, w_vec[0..n]);
                h_mat[i * m + j] = hij;
                for (0..n) |k| w_vec[k] -= hij * vi[k];
            }

            const h_jp1_j = vecNorm(w_vec[0..n]);
            h_mat[(j + 1) * m + j] = h_jp1_j;

            // Store v_{j+1}
            if (h_jp1_j > 1e-30) {
                const vjp1 = v_basis[(j + 1) * n ..][0..n];
                for (0..n) |k| vjp1[k] = w_vec[k] / h_jp1_j;
            }

            // Apply previous Givens rotations to column j of H
            for (0..j) |i| {
                const h_i = h_mat[i * m + j];
                const h_i1 = h_mat[(i + 1) * m + j];
                h_mat[i * m + j] = cs[i] * h_i + sn[i] * h_i1;
                h_mat[(i + 1) * m + j] = -sn[i] * h_i + cs[i] * h_i1;
            }

            // Compute new Givens rotation for row j
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

            // Apply rotation to g
            const g_j = g_vec[j];
            const g_j1 = g_vec[j + 1];
            g_vec[j] = cs[j] * g_j + sn[j] * g_j1;
            g_vec[j + 1] = -sn[j] * g_j + cs[j] * g_j1;

            if (@abs(g_vec[j + 1]) < opts.abstol * 0.1) {
                j += 1;
                break;
            }
        }

        // Solve upper triangular H * y = g
        const jj = j;
        if (jj > 0) {
            backSolveUpperTriangular(h_mat, g_vec, y_vec, jj, m);

            // dx = V * y (sum of Krylov basis vectors)
            @memset(dx[0..n], 0);
            for (0..jj) |k| {
                const vk = v_basis[k * n ..][0..n];
                for (0..n) |i| dx[i] += y_vec[k] * vk[i];
            }
        } else {
            @memset(dx[0..n], 0);
        }

        // Clamp
        for (dx[0..n]) |*d| d.* = std.math.clamp(d.*, -opts.dx_clamp, opts.dx_clamp);

        // Update x
        @memcpy(x_old[0..n], x[0..n]);
        const max_dx = updateAndNorm(x[0..n], dx[0..n]);
        ckt.applyLimits(x, x_old);

        if (ckt.updateStates(x)) |_| continue;
        if (max_dx < opts.abstol)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = max_dx };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

/// Unified solve entry point. strategy=null means auto-pick.
pub fn solve(
    ckt: *root.Circuit,
    slv: *direct.Solver,
    x: []f64,
    dx: []f64,
    x_old: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
    strategy_override: ?Strategy,
    gpa: ?std.mem.Allocator,
) !Result {
    const strat = strategy_override orelse pickStrategy(ckt.n, false);
    switch (strat) {
        .newton => return newton(ckt, slv, x, dx, x_old, t, opts, hook),
        .jfnk => {
            const alloc = gpa orelse return newton(ckt, slv, x, dx, x_old, t, opts, hook);
            return jfnk(ckt, slv, x, dx, x_old, t, opts, hook, alloc);
        },
    }
}

// ============================================================================
// JFNK helpers
// ============================================================================

fn assembleResidual(ckt: *root.Circuit, x: []const f64, t: f64, hook: anytype) void {
    hook.assemble(ckt, x, t);
}

fn jvProduct(
    ckt: *root.Circuit,
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
    // epsilon = sqrt(eps_mach) * max(||x||, 1) / ||v||
    const eps_mach = std.math.floatEps(f64);
    const sqrt_eps = @sqrt(eps_mach);
    const x_norm = @max(vecNorm(x[0..n]), 1.0);
    const v_norm = vecNorm(v[0..n]);
    const eps = if (v_norm > 1e-30) sqrt_eps * x_norm / v_norm else sqrt_eps;

    // x_pert = x + eps * v
    for (0..n) |i| x_pert[i] = x[i] + eps * v[i];

    // Evaluate F(x + eps*v)
    assembleResidual(ckt, x_pert, t, hook);
    if (opts.gmin > 0) {
        for (0..n) |i| {
            ckt.rhs[i] += opts.gmin * x_pert[i];
        }
    }
    @memcpy(f_pert[0..n], ckt.rhs[0..n]);

    // out = (F(x + eps*v) - F(x)) / eps
    const inv_eps = 1.0 / eps;
    for (0..n) |i| out[i] = (f_pert[i] - f0[i]) * inv_eps;
}

fn buildDiagPreconditioner(ckt: *root.Circuit, hook: anytype, opts: Options, diag: []f64) void {
    const v = hook.vals(ckt);
    for (0..ckt.n) |i| {
        var d = v[ckt.diag_slots[i]];
        if (opts.gmin > 0) d += opts.gmin;
        diag[i] = if (@abs(d) > 1e-30) 1.0 / d else 1.0;
    }
}

fn applyPreconditioner(r: []f64, diag: []const f64, slv: ?*direct.Solver, n: usize) void {
    if (slv) |s| {
        if (s.factored) {
            // Use the factored matrix as preconditioner
            s.solve(r, r);
            return;
        }
    }
    // Diagonal (Jacobi) preconditioning
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

fn updateAndNorm(x: []f64, dx: []const f64) f64 {
    var max_dx: f64 = 0;
    for (x, dx) |*xi, dxi| {
        xi.* += dxi;
        max_dx = @max(max_dx, @abs(dxi));
    }
    return max_dx;
}

// ============================================================================
// Workspace — same as the old newton.Workspace, extended for JFNK
// ============================================================================

pub const Workspace = struct {
    slv: direct.Solver,
    dx: []f64,
    x_old: []f64,

    pub fn init(gpa: std.mem.Allocator, ckt: *const root.Circuit) !Workspace {
        const dx = try gpa.alloc(f64, ckt.n);
        errdefer gpa.free(dx);
        const x_old = try gpa.alloc(f64, ckt.n);
        errdefer gpa.free(x_old);
        return .{
            .slv = try direct.Solver.init(gpa, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd),
            .dx = dx,
            .x_old = x_old,
        };
    }

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.slv.deinit();
        gpa.free(self.dx);
        gpa.free(self.x_old);
        self.* = undefined;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "pickStrategy: small circuit -> newton" {
    try testing.expectEqual(Strategy.newton, pickStrategy(100, false));
    try testing.expectEqual(Strategy.newton, pickStrategy(5000, false));
}

test "pickStrategy: large circuit -> jfnk" {
    try testing.expectEqual(Strategy.jfnk, pickStrategy(5001, false));
    try testing.expectEqual(Strategy.jfnk, pickStrategy(10000, false));
}

test "pickStrategy: gpu -> jfnk" {
    try testing.expectEqual(Strategy.jfnk, pickStrategy(1, true));
    try testing.expectEqual(Strategy.jfnk, pickStrategy(100, true));
}

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
    // [2 1] [y0]   [5]
    // [0 3] [y1] = [6]  -> y1=2, y0=1.5
    const m: usize = 2;
    const h = [_]f64{ 2, 1, 0, 3 };
    const g = [_]f64{ 5, 6 };
    var y: [2]f64 = undefined;
    backSolveUpperTriangular(&h, &g, &y, 2, m);
    try testing.expectApproxEqAbs(@as(f64, 1.5), y[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), y[1], 1e-15);
}
