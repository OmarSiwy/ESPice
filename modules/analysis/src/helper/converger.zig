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
const root = @import("../root.zig");
const direct = root.solvers.direct;

pub const Strategy = enum { newton, jfnk };

/// ZP_OPDBG=1 traces Newton iterations + ladder rungs to stderr.
pub fn opdbg() bool {
    return std.c.getenv("ZP_OPDBG") != null;
}

// ---------------------------------------------------------------------------
// Tolerances — user-facing accuracy profile. One struct, set once at the
// engine level, propagated into every analysis via Options.tol. Named
// profiles match the defaults of common SPICE simulators so benchmarking
// against a specific tool is one field change.
// ---------------------------------------------------------------------------

pub const Tolerances = struct {
    // Newton convergence
    reltol: f64 = 1e-3,
    abstol: f64 = 1e-12,
    vntol: f64 = 1e-6,
    gmin: f64 = 1e-12,
    residual_tol: f64 = 1e-9,
    dx_clamp: f64 = std.math.inf(f64),

    // DC continuation
    gmin_start: f64 = 1e-2,
    source_steps: u8 = 7,

    // Iteration limits (SPICE ITLn)
    itl1: u16 = 100,
    itl2: u16 = 50,
    itl4: u16 = 10,

    // Transient LTE control
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
// Options — internal Newton interface. Analyses don't construct this
// directly; they call Tolerances.newtonOpts().
// ---------------------------------------------------------------------------

pub const Options = struct {
    max_iter: u16 = 100,
    abstol: f64 = 1e-12,
    reltol: f64 = 1e-3,
    vntol: f64 = 1e-6,
    residual_tol: f64 = 1e-9,
    gmin: f64 = 1e-12,
    dx_clamp: f64 = std.math.inf(f64),
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
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const slv = &ws.slv;
    const dx = ws.dx;
    const x_old = ws.x_old;
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
        // Monotone residual safeguard (backtracking line search): a Newton
        // step that lands a junction volts past its exponential knee blows
        // ||F|| up by e10+; retreat halfway toward the previous iterate
        // until the residual is sane again. This is the device-agnostic
        // stand-in for SPICE's pnjlim on unknowns that have no private
        // node to limit (collapsed primes, shared nets).
        var norm_f: f64 = 0;
        for (0..ckt.n) |i| norm_f = @max(norm_f, @abs(ckt.rhs[i]));
        // No system-level residual backtracking: ngspice has none — device
        // limiting (pnjlim/fetlim/limvds, now ngspice-exact) IS the
        // globalization. A monotone-||F|| safeguard here double-limits and
        // starves recovery: junction settling legitimately flares ||F|| by
        // 10-100x for an iteration, and retreating turns a 3-iteration
        // settle into 50 (measured on fourbitadder/mos6_inverter).
        slv.factor(v) catch |e| {
            if (opdbg()) {
                var nan_cnt: usize = 0;
                var max_x: f64 = 0;
                for (v[0..ckt.nnz]) |vi| {
                    if (!std.math.isFinite(vi)) nan_cnt += 1;
                }
                for (0..ckt.n) |i| max_x = @max(max_x, @abs(x[i]));
                std.debug.print("  newton it={d} FACTOR FAIL {} nan_vals={d} max|x|={e:.3} |F|={e:.3}\n", .{ iter, e, nan_cnt, max_x, norm_f });
            }
            return e;
        };
        slv.solveNeg(ckt.rhs, dx);
        dampStep(dx[0..ckt.n], opts.dx_clamp);
        // ckt.rhs still holds F(x) + gmin·x — solveNeg takes rhs as const;
        // v still holds the assembled matrix (factor copies internally).
        const st = finalizeStep(ckt, x, dx, x_old, ckt.rhs, v, iter, opts);
        if (opdbg()) {
            var fi: usize = 0;
            var di: usize = 0;
            for (0..ckt.n) |i| {
                if (@abs(ckt.rhs[i]) > @abs(ckt.rhs[fi])) fi = i;
                if (@abs(dx[i]) > @abs(dx[di])) di = i;
            }
            std.debug.print("  newton it={d} |F|={e:.3}@{d}({s}) dx={e:.3}@{d}({s}) x={e:.3} scaled={e:.3} conv={}\n", .{ iter, norm_f, fi, ckt.nodeName(@intCast(fi)), dx[di], di, ckt.nodeName(@intCast(di)), x[di], st.scaled, st.converged });
        }
        if (st.converged)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = st.scaled };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

// ----------------------------------------------------------------------------
// Shared step acceptance — the ONE place convergence is decided, used by both
// newton() and jfnk() so the two paths cannot drift.
// ----------------------------------------------------------------------------

const Step = struct { converged: bool, scaled: f64 };

/// Direction-preserving Newton damping: if max|dx_i| exceeds `clamp`, scale
/// the WHOLE step by clamp/max|dx|. Component-wise clamping decouples the
/// step — linear source rows end up violated by whatever their clamped
/// neighbors kept, and a junction overshoot turns into a dx_clamp-per-
/// iteration walk that never converges. Scaling keeps the Newton direction:
/// linear-row residuals decay geometrically under any damping factor.
fn dampStep(dx: []f64, clamp: f64) void {
    if (!std.math.isFinite(clamp)) return;
    var mdx: f64 = 0;
    for (dx) |d| mdx = @max(mdx, @abs(d));
    if (mdx > clamp) {
        const s = clamp / mdx;
        for (dx) |*d| d.* *= s;
    }
}

/// Apply dx, then run the acceptance gates in ngspice order:
///   1. device state flips (updateStates) force another iteration
///   2. device limiting (pnjlim/fetlim) forces another iteration
///   3. iteration 1 is never accepted (ngspice niiter.c: iterno != 1)
///   4. per-row delta-x criterion (vntol on voltage rows, abstol on current)
///   5. row-scaled KCL residual gate on voltage rows
/// `residual` is F(x_prev) + gmin·x_prev of the system actually being solved
/// (regularized), which → 0 at its fixed point; at the accepting iteration
/// x barely moved, so it stands in for F(x_accepted) at zero extra assembles.
/// `vals` is the assembled matrix of the same iteration — its diagonal sets
/// the per-row current scale for the residual gate.
fn finalizeStep(
    ckt: *root.Circuit,
    x: []f64,
    dx: []const f64,
    x_old: []f64,
    residual: []const f64,
    vals: []const f64,
    iter: u16,
    opts: Options,
) Step {
    const n = ckt.n;
    @memcpy(x_old[0..n], x[0..n]);
    const scaled = updateAndNorm(x[0..n], dx[0..n], x_old[0..n], ckt.current_row, opts.reltol, opts.abstol, opts.vntol);
    // Limiting is safe on the JFNK path too: while lim_x is frozen, the
    // batch eval stamps i(lx) + J(lx)·(x_node − lx) (companion correction,
    // batch.zig corrDot), so F is piecewise LINEAR in x through limited
    // devices — finite-difference J·v is exact, not merely approximate.
    const limited = ckt.applyLimits(x, x_old);
    if (ckt.updateStates(x)) |_| return .{ .converged = false, .scaled = scaled };
    if (limited) return .{ .converged = false, .scaled = scaled };
    if (iter == 0) return .{ .converged = false, .scaled = scaled };
    if (scaled >= 1.0) return .{ .converged = false, .scaled = scaled };
    for (0..n) |i| {
        // Residual a legit final step may leave: |J·dx| ≈ |A_ii|·|dx_i|
        // with |dx_i| at the just-passed delta-x tolerance (10× safety).
        // ALL rows are checked: KVL (branch) rows have ~zero diagonal so
        // their tol floors at residual_tol — which is exactly what catches
        // a silently-singular solve returning dx = 0 at x = 0 (KCL rows are
        // trivially satisfied there; the -V on the source rows is the only
        // witness that x = 0 is not a solution).
        const scale = @abs(vals[ckt.diag_slots[i]]);
        const tol = @max(opts.residual_tol, 10.0 * scale * (opts.reltol * @abs(x[i]) + opts.vntol));
        if (@abs(residual[i]) > tol) return .{ .converged = false, .scaled = scaled };
    }
    return .{ .converged = true, .scaled = scaled };
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
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    const slv: ?*direct.Solver = &ws.slv;
    const dx = ws.dx;
    const x_old = ws.x_old;
    const n: usize = ckt.n;
    const m: usize = @min(gmres_restart, n);

    // ponytail: single GMRES workspace owned by Workspace, sliced into
    // views. Allocated once per circuit, reused across every solve —
    // every region is written before read, so reuse is bit-identical.
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
        // Evaluate F(x) = residual at current x
        assembleResidual(ckt, x, t, hook);
        if (opts.gmin > 0) {
            for (0..n) |i| {
                ckt.rhs[i] += opts.gmin * x[i];
            }
        }
        // Monotone residual safeguard — same as the newton path.
        var norm_f: f64 = 0;
        for (0..n) |i| norm_f = @max(norm_f, @abs(ckt.rhs[i]));
        // No residual backtracking — same rationale as the newton path.
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
            // Same min-iteration rule as finalizeStep: never accept iter 1.
            if (iter > 0)
                return .{ .converged = true, .iterations = iter + 1, .max_dx = 0 };
            continue;
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

        // Damp (direction-preserving, same as newton path)
        dampStep(dx[0..n], opts.dx_clamp);

        // Update x — same acceptance gates as newton(); f0 is F(x)+gmin·x.
        // hook.vals was clobbered by jvProduct's perturbed assembles, but
        // the diagonal magnitudes (residual-gate scale) are unaffected.
        const st = finalizeStep(ckt, x, dx, x_old, f0, hook.vals(ckt), iter, opts);
        if (st.converged)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = st.scaled };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

/// Main entry point. Auto-picks strategy:
///   GPU requested → JFNK (matrix-free, device-native)
///   n > 5000      → JFNK (sparse factor too expensive)
///   otherwise     → direct Newton (LU)
///
/// When GPU is active, the device eval kernels run on-device and JFNK's J·v
/// finite-difference uses those kernel launches (wired in Phase 5). CPU JFNK
/// uses the same algorithm with ckt.eval calls.
pub fn run(
    ckt: *root.Circuit,
    ws: *Workspace,
    x: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    // Device-private limiting state must not leak into post-solve evals
    // (waveform recording, AC, noise) — clear it however we exit.
    defer ckt.clearLimits();
    // Whole-solve GPU path (engine-owned megakernel): 1 launch + 1 readback
    // for the entire Newton solve. EvalHook only — TranHook et al. carry
    // host-side assembly the kernel can't see yet. Non-convergence or launch
    // failure falls through to the CPU strategies (warm-started from the
    // GPU's last iterate).
    if (ckt.gpu_hook) |gh| {
        if (comptime @TypeOf(hook) == EvalHook) {
            if (gh.solve_newton(gh.ctx, x, t, opts)) |r| {
                if (r.converged) return r;
            } else |_| {}
        }
    }
    if (ckt.gpu_active or ckt.n > 5000) {
        const r = try jfnk(ckt, ws, x, t, opts, hook);
        // GPU-mode fallback: after kernel + JFNK both fail, direct Newton is
        // still the strongest strategy for factorable systems — don't leave
        // it unreachable just because --gpu was requested.
        if (r.converged or ckt.n > 5000) return r;
    }
    return newton(ckt, ws, x, t, opts, hook);
}


// ============================================================================
// JFNK helpers
// ============================================================================

fn assembleResidual(ckt: *root.Circuit, x: []const f64, t: f64, hook: anytype) void {
    if (@hasDecl(@TypeOf(hook), "residual"))
        hook.residual(ckt, x, t)
    else
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

// SPICE3f5 per-variable criterion (ngspice NIconvTest):
//   |dx_i| / (reltol * max(|x_new_i|, |x_old_i|) + atol_i)
// where atol_i = vntol for node voltages, abstol for branch currents.
// Returns max over all i. Converged when < 1.0.
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
// Workspace — same as the old newton.Workspace, extended for JFNK
// ============================================================================

pub const Workspace = struct {
    slv: direct.Solver,
    dx: []f64,
    x_old: []f64,
    gmres: []f64 = &.{}, // lazily grown — only jfnk pays

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

    /// GMRES scratch, allocated on first jfnk call and reused after.
    fn ensureGmres(self: *Workspace, n: usize) ![]f64 {
        const m: usize = @min(gmres_restart, n);
        const total = (m + 1) * n + (m + 1) * m + m + m + (m + 1) + m + 6 * n;
        if (self.gmres.len < total) {
            self.slv.gpa.free(self.gmres);
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
