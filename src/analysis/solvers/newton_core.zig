//! Single-source Newton/JFNK/GMRES(m) solver core — shared verbatim by the
//! CPU converger (converger.jfnk) and the GPU megakernel (devices/kernel.zig).
//!
//! MUST stay dependency-free and std-free: the GPU driver TU compiles this
//! file for nvptx64/amdgcn where std is unavailable. Only nvptx-legal
//! builtins (@sqrt/@abs/@min/@max), no slices in hot loops (many-pointers).
//!
//! The Env (comptime duck-typed, see validateEnv) abstracts the execution
//! model: the GPU passes grid-stride tid/stride, a software grid barrier,
//! atomic reductions and thread-0 "publish" slots (G.scal); the CPU passes
//! tid=0/stride=1, no-op sync, identity reductions and a local scalar array.
//! With stride()==1 every loop below is the plain serial 0..n loop, and
//! reduceAdd(partial)==partial, so CPU iterate trajectories are bit-identical
//! to the historical serial implementation.
//!
//! Comptime divergences preserved exactly:
//!   GPU: backtrack=true (monotone-residual retreat), exact_jv=false
//!        (f0_shift FD baseline for device-limited residual-only J·v evals).
//!   CPU: backtrack=false, exact_jv=true (FD against f0 directly).
//! Preconditioner differs via precondBuild/precondApply (GPU: Jacobi;
//! CPU: LU-when-factored-else-Jacobi).

pub const inf_f64: f64 = @bitCast(@as(u64, 0x7ff0000000000000));
const sqrt_eps: f64 = 1.4901161193847656e-8; // sqrt(f64 machine epsilon)

/// Solver controls. Field-for-field identical to gpu_abi.Tol (extern) so the
/// GPU wrapper can copy hdr.tol across without importing anything here.
pub const Tol = extern struct {
    reltol: f64,
    abstol: f64,
    vntol: f64,
    residual_tol: f64,
    gmin: f64,
    dx_clamp: f64,
    max_iter: u32,
    gmres_m: u32,
};

pub const Result = struct {
    converged: bool,
    iterations: u32,
    max_dx: f64,
};

pub const PostStep = struct {
    limited: bool,
    flipped: bool,
};

/// Workspace vector views, generic over the pointer type: the GPU passes
/// [*]addrspace(.global) f64, the host [*]f64. Field set mirrors the solver
/// subset of the GPU G struct (tran-only state stays in the GPU env).
pub fn Vecs(comptime P: type) type {
    return struct {
        v_basis: P, // (m+1)*n Krylov basis
        h: P, // (m+1)*m Hessenberg
        cs: P, // m Givens cosines
        sn: P, // m Givens sines
        g_vec: P, // m+1
        y_vec: P, // m
        r: P, // n — doubles as dx after the Krylov solve
        w: P, // n
        x_pert: P, // n
        f0: P, // n — outer residual F(x)+gmin·x
        f0_shift: P, // n — FD baseline (GPU only; alias f0 on CPU)
        diag: P, // n — preconditioner storage (env-owned semantics)
        x_old: P, // n
        rhs: P, // assembly target (env fills)
    };
}

// scal slot map (lead-thread owned, via publish/read): 0 env reductions |
// 1 eps | 2 control flag (0 none, 1 backtrack, 2 gmres-break, 3 done) |
// 4 prev_norm | 5 jj | 7 backtrack count | 8 lim_active | rest spare

fn PtrChild(comptime P: type) type {
    if (@typeInfo(P) != .pointer) @compileError("newton_core: env must be a pointer");
    return @typeInfo(P).pointer.child;
}

fn validateEnv(comptime E: type) void {
    const decls = .{
        "F64",      "backtrack", "exact_jv",   "tid",          "stride",
        "isLead",   "sync",      "reduceAdd",  "reduceMax",    "publish",
        "read",     "limiting",  "assemble",   "precondBuild", "precondApply",
        "postStep", "gateScale", "currentRow",
    };
    inline for (decls) |d| {
        if (!@hasDecl(E, d))
            @compileError("newton_core Env missing decl: " ++ d ++ " (in " ++ @typeName(E) ++ ")");
    }
}

/// One whole JFNK Newton solve on x (in place): outer Newton loop, restarted
/// GMRES(m) inner loop, convergence gates. Gate order and every FP operation
/// mirror the historical CPU converger.jfnk / GPU kernel newtonSolve
/// gate-for-gate — do not reorder or reassociate anything in here.
pub fn newtonSolve(
    env: anytype,
    v: Vecs(PtrChild(@TypeOf(env)).F64),
    x: PtrChild(@TypeOf(env)).F64,
    t: f64,
    tol: Tol,
    n: u32,
    m: u32,
) Result {
    const E = PtrChild(@TypeOf(env));
    comptime validateEnv(E);
    const tid = env.tid();
    const stride = env.stride();
    if (comptime @hasDecl(E, "beginSolve")) env.beginSolve();

    // Init control state + x_old = x (lead writes pre-barrier; everyone
    // reads post-barrier).
    if (env.isLead()) {
        env.publish(2, 0);
        env.publish(4, 1e308); // prev_norm = "inf"
        env.publish(7, 0); // backtrack count
        env.publish(8, 0); // lim_active
    }
    var i: u32 = tid;
    while (i < n) : (i += stride) v.x_old[i] = x[i];
    env.sync();

    // Last completed iteration's stats — what a failed solve reports.
    var res_iters: u32 = 0;
    var res_maxdx: f64 = 0;

    var iter: u32 = 0;
    outer: while (iter < tol.max_iter) : (iter += 1) {
        if (comptime @hasDecl(E, "checkpoint")) if (iter != 0) {
            if (!env.checkpoint(iter))
                return .{ .converged = false, .iterations = res_iters, .max_dx = res_maxdx };
        };
        if (comptime @hasDecl(E, "advanceIteration")) if (iter != 0) env.advanceIteration(v.x_old);
        // Device limiting engaged? (env decides; stable within an iteration.)
        const limiting = env.limiting();

        // F(x) (+ Jacobian diag on GPU) + gmin regularization — env-owned.
        env.assemble(true, x, x, t, limiting);
        var norm_p: f64 = 0;
        i = tid;
        while (i < n) : (i += stride) norm_p = @max(norm_p, @abs(v.rhs[i]));
        const norm_f = env.reduceMax(norm_p);

        // Monotone residual safeguard (GPU only) — lead decides.
        if (comptime E.backtrack) {
            if (env.isLead()) {
                const prev_norm = env.read(4);
                const backtracks = env.read(7);
                if (norm_f > 10.0 * prev_norm and backtracks < 16.0) {
                    env.publish(2, 1); // backtrack
                    env.publish(7, backtracks + 1);
                } else {
                    env.publish(2, 0);
                    env.publish(7, 0);
                    env.publish(4, norm_f);
                }
            }
            env.sync();
            if (env.read(2) == 1) {
                i = tid;
                while (i < n) : (i += stride) x[i] = 0.5 * (x[i] + v.x_old[i]);
                env.sync();
                // Keep device lim state tracking the retreated x.
                _ = env.postStep(x, v.x_old, limiting);
                continue :outer;
            }
        }

        // f0 = F(x)+gmin·x; build the preconditioner (GPU: invert diag in
        // place; CPU: Jacobi diag + LU factor attempt).
        i = tid;
        while (i < n) : (i += stride) v.f0[i] = v.rhs[i];
        env.precondBuild();
        env.sync();

        // FD baseline (GPU only): with limiting engaged, f0 carries the
        // companion correction J(lx)·(x−lx); difference against the
        // UNCORRECTED shifted residual at x instead. Plain copy otherwise.
        if (comptime !E.exact_jv) {
            if (limiting) {
                env.assemble(false, x, x, t, true);
                i = tid;
                while (i < n) : (i += stride) v.f0_shift[i] = v.rhs[i];
            } else {
                i = tid;
                while (i < n) : (i += stride) v.f0_shift[i] = v.f0[i];
            }
            env.sync();
        }

        // r = -M⁻¹ f0; beta = ||r||₂.
        i = tid;
        while (i < n) : (i += stride) v.r[i] = -v.f0[i];
        env.precondApply(v.r);
        var acc: f64 = 0;
        i = tid;
        while (i < n) : (i += stride) acc += v.r[i] * v.r[i];
        const beta = @sqrt(env.reduceAdd(acc));

        if (beta < tol.abstol and residualConverged(env, x, v.f0, tol, n)) {
            i = tid;
            while (i < n) : (i += stride) {
                v.r[i] = 0; // dx = 0
                v.x_old[i] = x[i];
            }
            env.sync();
            const ps = env.postStep(x, v.x_old, limiting);
            var converged = iter > 0 and !ps.limited and !ps.flipped;
            if (comptime @hasDecl(E, "acceptStep")) {
                if (converged) converged = env.acceptStep(x);
            }
            res_iters = iter + 1;
            res_maxdx = 0;
            if (converged)
                return .{ .converged = true, .iterations = iter + 1, .max_dx = 0 };
            continue :outer;
        }

        // v0 = r/beta; scalar GMRES state on the lead thread.
        i = tid;
        while (i < n) : (i += stride) v.v_basis[i] = v.r[i] / beta;
        if (env.isLead()) {
            v.g_vec[0] = beta;
            var k: u32 = 1;
            while (k < m + 1) : (k += 1) v.g_vec[k] = 0;
            env.publish(5, 0); // jj
        }
        env.sync();

        var j: u32 = 0;
        gmres: while (j < m) : (j += 1) {
            const vj = v.v_basis + @as(usize, j) * n;

            // eps = sqrt(eps_mach)·max(||x||,1)/||v||.
            acc = 0;
            i = tid;
            while (i < n) : (i += stride) acc += x[i] * x[i];
            const x_norm = @max(@sqrt(env.reduceAdd(acc)), 1.0);
            acc = 0;
            i = tid;
            while (i < n) : (i += stride) acc += vj[i] * vj[i];
            const v_norm = @sqrt(env.reduceAdd(acc));
            if (env.isLead())
                env.publish(1, if (v_norm > 1e-30) sqrt_eps * x_norm / v_norm else sqrt_eps);
            env.sync();
            const eps = env.read(1);

            i = tid;
            while (i < n) : (i += stride) v.x_pert[i] = x[i] + eps * vj[i];
            env.sync();

            // w = M⁻¹ (F(x+εv)+gmin·x_pert − baseline)/ε.
            env.assemble(false, v.x_pert, x, t, limiting);
            const fd_base = if (comptime E.exact_jv) v.f0 else v.f0_shift;
            const inv_eps = 1.0 / eps;
            i = tid;
            while (i < n) : (i += stride) v.w[i] = (v.rhs[i] - fd_base[i]) * inv_eps;
            env.precondApply(v.w);
            env.sync();

            // Modified Gram-Schmidt (sequential dots — exactness over speed).
            var mi: u32 = 0;
            while (mi <= j) : (mi += 1) {
                const vi = v.v_basis + @as(usize, mi) * n;
                acc = 0;
                i = tid;
                while (i < n) : (i += stride) acc += vi[i] * v.w[i];
                const hij = env.reduceAdd(acc);
                if (env.isLead()) v.h[@as(usize, mi) * m + j] = hij;
                i = tid;
                while (i < n) : (i += stride) v.w[i] -= hij * vi[i];
                env.sync();
            }
            acc = 0;
            i = tid;
            while (i < n) : (i += stride) acc += v.w[i] * v.w[i];
            const h_jp1 = @sqrt(env.reduceAdd(acc));
            if (env.isLead()) v.h[@as(usize, j + 1) * m + j] = h_jp1;
            if (h_jp1 > 1e-30) {
                const vjp1 = v.v_basis + @as(usize, j + 1) * n;
                i = tid;
                while (i < n) : (i += stride) vjp1[i] = v.w[i] / h_jp1;
            }

            // Givens rotations + early-exit test — lead thread.
            if (env.isLead()) {
                var k: u32 = 0;
                while (k < j) : (k += 1) {
                    const h_k = v.h[@as(usize, k) * m + j];
                    const h_k1 = v.h[@as(usize, k + 1) * m + j];
                    v.h[@as(usize, k) * m + j] = v.cs[k] * h_k + v.sn[k] * h_k1;
                    v.h[@as(usize, k + 1) * m + j] = -v.sn[k] * h_k + v.cs[k] * h_k1;
                }
                const a_val = v.h[@as(usize, j) * m + j];
                const b_val = v.h[@as(usize, j + 1) * m + j];
                const r_val = @sqrt(a_val * a_val + b_val * b_val);
                if (r_val > 1e-30) {
                    v.cs[j] = a_val / r_val;
                    v.sn[j] = b_val / r_val;
                } else {
                    v.cs[j] = 1.0;
                    v.sn[j] = 0.0;
                }
                v.h[@as(usize, j) * m + j] = r_val;
                v.h[@as(usize, j + 1) * m + j] = 0;
                const g_j = v.g_vec[j];
                const g_j1 = v.g_vec[j + 1];
                v.g_vec[j] = v.cs[j] * g_j + v.sn[j] * g_j1;
                v.g_vec[j + 1] = -v.sn[j] * g_j + v.cs[j] * g_j1;
                env.publish(5, @floatFromInt(j + 1)); // jj so far
                env.publish(2, if (@abs(v.g_vec[j + 1]) < tol.abstol * 0.1) 2 else 0);
            }
            env.sync();
            if (env.read(2) == 2) break :gmres;
        }

        // Back-substitution (lead), then dx = V·y into v.r.
        const jj: u32 = @intFromFloat(env.read(5));
        if (env.isLead() and jj > 0) {
            var k: u32 = jj;
            while (k > 0) {
                k -= 1;
                var s = v.g_vec[k];
                var kk: u32 = k + 1;
                while (kk < jj) : (kk += 1) s -= v.h[@as(usize, k) * m + kk] * v.y_vec[kk];
                const d = v.h[@as(usize, k) * m + k];
                v.y_vec[k] = if (@abs(d) > 1e-30) s / d else 0;
            }
        }
        env.sync();
        i = tid;
        while (i < n) : (i += stride) {
            var dxi: f64 = 0;
            var k: u32 = 0;
            while (k < jj) : (k += 1) dxi += v.y_vec[k] * v.v_basis[@as(usize, k) * n + i];
            v.r[i] = dxi;
        }
        env.sync();

        // Direction-preserving damping (no-op while dx_clamp is inf).
        var mdx_p: f64 = 0;
        i = tid;
        while (i < n) : (i += stride) mdx_p = @max(mdx_p, @abs(v.r[i]));
        const mdx = env.reduceMax(mdx_p);
        if (mdx > tol.dx_clamp) {
            const s = tol.dx_clamp / mdx;
            i = tid;
            while (i < n) : (i += stride) v.r[i] *= s;
            env.sync();
        }

        // finalizeStep: x_old = x; x += dx; per-row delta-x criterion;
        // limiting/state-flip pass; row-scaled residual gate on f0;
        // iter-0 reject. Gate ORDER preserved on each side.
        var scaled_p: f64 = 0;
        i = tid;
        while (i < n) : (i += stride) {
            const dxi = v.r[i];
            const xo = x[i];
            const xn = xo + dxi;
            v.x_old[i] = xo;
            x[i] = xn;
            const atol = if (env.currentRow(i)) tol.abstol else tol.vntol;
            const tcrit = tol.reltol * @max(@abs(xn), @abs(xo)) + atol;
            // A non-finite iterate must read as NOT converged, and it did not:
            // `@max` lowers to `maxnum`, which returns the NON-NaN operand, so
            // a NaN dx simply vanished out of `scaled` and `scaled < 1.0` then
            // reported success on a diverged solve. (`xn == inf` slipped
            // through the other way: `tcrit` is then inf and `|dx|/inf == 0`.)
            // That is how a lone PMOS .op returned NaN with exit 0.
            //
            // `inf_f64` says "not converged" and, unlike NaN, survives
            // `reduceMax` the same way on every Env — the GPU's atomic max has
            // the same maxnum semantics as the CPU's identity reduce.
            const finite = @abs(xn) < inf_f64 and @abs(dxi) < inf_f64;
            scaled_p = @max(scaled_p, if (finite) @abs(dxi) / tcrit else inf_f64);
        }
        const scaled = env.reduceMax(scaled_p);

        // CPU: applyLimits (may clamp x); GPU: device limit
        // pass. Runs BEFORE the residual gate so the CPU gate sees the
        // limited x, exactly as the historical finalizeStep did.
        const ps = env.postStep(x, v.x_old, limiting);

        const residual_ok = residualConverged(env, x, v.f0, tol, n);

        var converged = iter > 0 and scaled < 1.0 and residual_ok and
            !ps.limited and !ps.flipped;
        if (comptime @hasDecl(E, "acceptStep")) {
            if (converged) converged = env.acceptStep(x);
        }
        if (env.isLead()) env.publish(2, if (converged) 3 else 0);
        env.sync();
        res_iters = iter + 1;
        res_maxdx = scaled;
        if (env.read(2) == 3)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = scaled };
    }
    return .{ .converged = false, .iterations = res_iters, .max_dx = res_maxdx };
}

fn residualConverged(env: anytype, x: PtrChild(@TypeOf(env)).F64, residual: PtrChild(@TypeOf(env)).F64, tol: Tol, n: u32) bool {
    var violation: f64 = 0;
    var i = env.tid();
    while (i < n) : (i += env.stride()) {
        const scale = env.gateScale(i);
        const rt = @max(tol.residual_tol, 10.0 * scale * (tol.reltol * @abs(x[i]) + tol.vntol));
        // Negated comparisons reject NaN as well as an out-of-tolerance residual.
        if (!(@abs(residual[i]) <= rt) or !(@abs(x[i]) < inf_f64)) violation = 1;
    }
    return env.reduceMax(violation) == 0;
}
