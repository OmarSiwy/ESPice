//! MATEX: matrix-exponential transient for linear circuits (R-MATEX). Two
//! factorizations serve every step: Arnoldi on (C + gamma*G)^-1 C
//! approximates exp(hA), and G gives the source terms. Only source
//! transition spots bound the step. G must be regular.
//! ponytail: no nonlinear (EPIRK) path; add one when a const-Jacobian check
//! says a circuit needs linearization.
const std = @import("std");
const root = @import("../types.zig");
const simdCopy = root.copySimd;
const num = @import("core").numerics;
const combinePlanes = @import("../Circuit.zig").combinePlanes;
const solvers = @import("solver");
const Waveform = @import("types.zig").Waveform;

const DenseLu = solvers.dense_lu.DenseLu(f64);
const Solver = solvers.direct.Solver;

// ponytail: platform SIMD width, not hardcoded.
const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

pub const Options = @import("core").query.Matex;

/// y = M*x for the n x n CSC matrix M; zero columns of x are skipped.
fn cscMulVec(
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    vals: []const f64,
    x: []const f64,
    y: []f64,
) void {
    root.zeroSimd(y[0..n]);
    for (0..n) |j| {
        const xj = x[j];
        if (xj == 0) continue;
        for (col_ptr[j]..col_ptr[j + 1]) |p| {
            y[row_idx[p]] += vals[p] * xj;
        }
    }
}

/// expm(H) for m x m row-major H by scaling and squaring with Pade(6,6):
/// U = H*(b1*I + b3*H^2 + b5*H^4), V = b0*I + b2*H^2 + b4*H^4 + b6*H^6,
/// expm = (V - U)^-1 (V + U); four matmuls and one dense LU. Writes `out`,
/// destroys H. `scratch` holds at least 5*m*m, `piv_buf` at least m. A
/// singular V - U yields the identity.
fn expmSmall(m: usize, H: []f64, out: []f64, scratch: []f64, piv_buf: []u32) void {
    // b_j = (12-j)! 6! / (12! j! (6-j)!)
    const b = [_]f64{
        1.0,
        0.5,
        5.0 / 44.0,
        1.0 / 66.0,
        1.0 / 792.0,
        1.0 / 15840.0,
        1.0 / 665280.0,
    };

    // Scale until max |H_ij| <= 0.5.
    // ponytail: the max element suffices for the scaling decision.
    var norm_h: f64 = 0;
    for (0..m * m) |i| norm_h = @max(norm_h, @abs(H[i]));
    var s: u32 = 0;
    while (norm_h > 0.5) : (s += 1) {
        norm_h *= 0.5;
        for (0..m * m) |i| H[i] *= 0.5;
    }

    const mm = m * m;
    const H2 = scratch[0..mm];
    const H4 = scratch[mm .. 2 * mm];
    const T = scratch[2 * mm .. 3 * mm];
    const U = scratch[3 * mm .. 4 * mm];
    const Vmat = scratch[4 * mm .. 5 * mm];

    denseMatMul(m, H, H, H2);
    denseMatMul(m, H2, H2, H4);
    denseMatMul(m, H4, H2, T); // H^6

    // Even part.
    {
        var i: usize = 0;
        const b2v: V = @splat(b[2]);
        const b4v: V = @splat(b[4]);
        const b6v: V = @splat(b[6]);
        while (i + W <= mm) : (i += W) {
            const h2v: V = H2[i..][0..W].*;
            const h4v: V = H4[i..][0..W].*;
            const h6v: V = T[i..][0..W].*;
            Vmat[i..][0..W].* = b2v * h2v + b4v * h4v + b6v * h6v;
        }
        while (i < mm) : (i += 1) {
            Vmat[i] = b[2] * H2[i] + b[4] * H4[i] + b[6] * T[i];
        }
    }
    for (0..m) |i| Vmat[i * m + i] += b[0];

    // Odd part: T becomes the inner polynomial, then U = H*T.
    {
        var i: usize = 0;
        const b3v: V = @splat(b[3]);
        const b5v: V = @splat(b[5]);
        while (i + W <= mm) : (i += W) {
            const h2v: V = H2[i..][0..W].*;
            const h4v: V = H4[i..][0..W].*;
            T[i..][0..W].* = b3v * h2v + b5v * h4v;
        }
        while (i < mm) : (i += 1) {
            T[i] = b[3] * H2[i] + b[5] * H4[i];
        }
    }
    for (0..m) |i| T[i * m + i] += b[1];

    denseMatMul(m, H, T, U);

    // out = V + U, H = V - U.
    {
        var i: usize = 0;
        while (i + W <= mm) : (i += W) {
            const uv: V = U[i..][0..W].*;
            const vv: V = Vmat[i..][0..W].*;
            out[i..][0..W].* = vv + uv;
            H[i..][0..W].* = vv - uv;
        }
        while (i < mm) : (i += 1) {
            out[i] = Vmat[i] + U[i];
            H[i] = Vmat[i] - U[i];
        }
    }

    const piv = piv_buf[0..m];
    DenseLu.factorize(m, H, piv) catch {
        @memset(out[0..mm], 0);
        for (0..m) |i| out[i * m + i] = 1;
        return;
    };

    // Solve (V - U) X = (V + U) one column at a time, in place in `out`.
    const col_buf = H2;
    for (0..m) |j| {
        for (0..m) |i| col_buf[i] = out[i * m + j];
        DenseLu.solveFactored(m, H, piv, col_buf[0..m], col_buf[0..m]);
        for (0..m) |i| out[i * m + j] = col_buf[i];
    }

    // Undo the scaling: out = out^(2^s).
    var si: u32 = 0;
    while (si < s) : (si += 1) {
        simdCopy(H2[0..mm], out[0..mm]);
        denseMatMul(m, H2, H2, out);
    }
}

/// C = A*B for m x m row-major matrices; C must not alias A or B.
/// Vectorized over W adjacent output columns, each lane summing k in
/// 0..m order, so every element rounds exactly as the scalar loop would.
fn denseMatMul(m: usize, A: []const f64, B: []const f64, C: []f64) void {
    for (0..m) |i| {
        const a_row = A[i * m ..][0..m];
        const c_row = C[i * m ..][0..m];
        var j: usize = 0;
        while (j + W <= m) : (j += W) {
            var acc: V = @splat(@as(f64, 0));
            for (0..m) |k| {
                const av: V = @splat(a_row[k]);
                const bv: V = B[k * m + j ..][0..W].*;
                acc += av * bv;
            }
            c_row[j..][0..W].* = acc;
        }
        while (j < m) : (j += 1) {
            var sum: f64 = 0;
            for (0..m) |k| sum += a_row[k] * B[k * m + j];
            c_row[j] = sum;
        }
    }
}

const ArnoldiResult = struct {
    /// Krylov dimension reached; 0 when v is zero.
    m: u32,
    /// ||v||.
    beta: f64,
};

/// Arnoldi on (C + gamma*G)^-1 C from v, with modified Gram-Schmidt. Each
/// matvec is a CSC product with C and one solve against the prefactored
/// `slv`. Fills V_basis (n x (m_max+1), column-major) and H (row-major,
/// stride m_max, with one extra row for the last subdiagonal). Stops on
/// breakdown, when `posteriorOk` accepts, or at m_max.
fn arnoldi(
    n: u32,
    v: []const f64,
    slv: *Solver,
    col_ptr: []const u32,
    row_idx: []const u32,
    c_vals: []const f64,
    V_basis: []f64,
    H: []f64,
    m_max: u32,
    h_step: f64,
    krylov_tol: f64,
    // tmp1: max(n, 7*m_max^2), since the posterior reuses it; tmp2: n.
    tmp1: []f64,
    tmp2: []f64,
    piv: []u32,
) ArnoldiResult {
    const nn: usize = n;

    const beta = @sqrt(num.dot(v[0..nn], v[0..nn]));
    if (beta < 1e-300) return .{ .m = 0, .beta = 0 };

    num.scale(V_basis[0..nn], 1.0 / beta, v[0..nn]);

    root.zeroSimd(H[0 .. @as(usize, m_max) * m_max]);

    var j: u32 = 0;
    while (j < m_max) : (j += 1) {
        const jj: usize = j;
        const vj = V_basis[jj * nn ..][0..nn];

        cscMulVec(n, col_ptr, row_idx, c_vals, vj, tmp1[0..nn]);
        slv.solve(tmp1[0..nn], tmp2[0..nn]);
        const w_norm = @sqrt(num.dot(tmp2[0..nn], tmp2[0..nn]));

        for (0..jj + 1) |k| {
            const vk = V_basis[k * nn ..][0..nn];
            const h_kj = num.dot(tmp2[0..nn], vk[0..nn]);
            H[k * m_max + jj] = h_kj;
            num.axpy(tmp2[0..nn], -h_kj, vk[0..nn]);
        }

        const h_jp1_j = @sqrt(num.dot(tmp2[0..nn], tmp2[0..nn]));
        // Lucky breakdown: the subspace is invariant. The test is relative,
        // since orthogonalization leaves a residual of round-off size, and a
        // normalized round-off vector would put a spurious zero in H_m.
        if (h_jp1_j <= 1e-12 * w_norm) return .{ .m = j + 1, .beta = beta };

        H[(jj + 1) * m_max + jj] = h_jp1_j;
        num.scale(V_basis[(jj + 1) * nn ..][0..nn], 1.0 / h_jp1_j, tmp2[0..nn]);

        // ponytail: the full expm posterior every 5 iterations from m = 5;
        // see posteriorOk for what it approximates.
        if (j >= 3 and (j + 1) % 5 == 0) {
            if (posteriorOk(j + 1, m_max, H, h_jp1_j, h_step, beta, krylov_tol, tmp1, piv))
                return .{ .m = j + 1, .beta = beta };
        }
    }

    return .{ .m = m_max, .beta = beta };
}

/// Accepts the m-dimensional Krylov approximation when
/// beta*h_{m+1,m}*|expm(h_step*H_m)[m-1, 0]| < tol*beta. `scratch` needs
/// 7*m*m (false otherwise), `piv` m.
/// ponytail: takes expm of the shift-inverted H directly instead of mapping
/// it back to A-space first. Conservative (may use a few extra vectors);
/// switch to the exact R-MATEX posterior if m keeps hitting m_max.
fn posteriorOk(
    m: u32,
    m_max: u32,
    H: []const f64,
    h_mp1_m: f64,
    h_step: f64,
    beta: f64,
    tol: f64,
    scratch: []f64,
    piv: []u32,
) bool {
    const mm: usize = m;
    const msq = mm * mm;

    if (scratch.len < 7 * msq) return false;

    const H_copy = scratch[0..msq];
    const expm_out = scratch[msq .. 2 * msq];
    const expm_scratch = scratch[2 * msq .. 7 * msq];

    // Leading m x m block of the m_max-strided H.
    for (0..mm) |i| {
        simdCopy(H_copy[i * mm ..][0..mm], H[i * @as(usize, m_max) ..][0..mm]);
    }

    for (0..msq) |i| H_copy[i] *= h_step;

    expmSmall(mm, H_copy, expm_out, expm_scratch, piv);

    const last_elem = @abs(expm_out[(mm - 1) * mm]);
    const err = beta * h_mp1_m * last_elem;

    return err < tol * beta;
}

/// Source breakpoints in (0, t_stop], sorted, with t_stop appended and
/// points closer than 1e-18 s merged. Allocated on `allocator`.
fn collectTransitionSpots(allocator: std.mem.Allocator, ckt: *root.Circuit, t_stop: f64) ![]f64 {
    var spots: std.ArrayList(f64) = .empty;
    defer spots.deinit(allocator);

    var t: f64 = 0;
    var iters: u32 = 0;
    while (t < t_stop and iters < 100_000) : (iters += 1) {
        const bp = ckt.nextBreakpoint(t) orelse break;
        if (bp > t_stop) break;
        try spots.append(allocator, bp);
        t = bp;
    }
    try spots.append(allocator, t_stop);

    const items = try spots.toOwnedSlice(allocator);
    std.mem.sort(f64, items, {}, std.sort.asc(f64));

    var write: usize = 0;
    for (items, 0..) |v, i| {
        if (i == 0 or v - items[write - 1] > 1e-18) {
            items[write] = v;
            write += 1;
        }
    }
    return items[0..write];
}

/// b(t) = B*u(t) for C x' + G x = b: the negated rhs plane (the residual
/// current I(x) = G x - b) of an eval at x = 0, so only sources contribute.
/// Sets the transient phase, since a SIN/PULSE/PWL card only follows its
/// waveform under `analysis("tran")` (§4.6.1).
fn evalSourceRhs(ckt: *root.Circuit, t: f64, b_out: []f64) void {
    const n: usize = ckt.n;
    // b_out doubles as the zero state vector; the eval result overwrites it.
    root.zeroSimd(b_out[0..n]);
    ckt.setSimState(.{ .t = t, .kind = .tran });
    ckt.eval(b_out, t);
    num.scale(b_out[0..n], -1.0, ckt.rhs[0..n]);
}

/// dest = -G^-1 v, which is A^-1 (C^-1 v) for A = -C^-1 G. C^-1 never
/// appears, so a singular C (algebraic MNA rows) is fine; G must be regular.
/// `v` and `dest` must not alias.
fn negGinvMul(slv_g: *Solver, v: []const f64, dest: []f64) void {
    slv_g.solve(v, dest);
    num.scale(dest, -1.0, dest);
}

/// Contract entry: march from ctx.x_op with the piecewise-linear source
/// integral (MATEX eq. 5), stepping to each transition spot or h_output_cap.
/// Point-major rows (time, probes...).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    // `a` holds only the Result. The fixed-size work buffers share one
    // lifetime and one arena; the solver and the growing waveform use
    // scratch directly so their frees are real.
    var work = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer work.deinit();
    const scratch = work.allocator();
    const ckt = ctx.circuit;
    const x_op = ctx.x_op;
    const n: usize = ckt.n;
    const nn: u32 = ckt.n;

    if (n == 0) return error.EmptyCircuit;

    const x = try scratch.alloc(f64, n);
    simdCopy(x, x_op);

    const gamma = opts.gamma orelse opts.t_stop / 1000.0;
    const h_cap = opts.h_output_cap orelse opts.t_stop / 200.0;

    // A Krylov subspace of R^n has at most n dimensions, and the step update
    // reuses the n-long arnoldi_tmp1 as an m-long dense RHS, so m <= n is
    // also a memory-safety bound.
    const m_max = @min(opts.m_max, nn);
    const m_max_usize: usize = m_max;

    // One eval fills the G and C planes.
    try ckt.computeBaseline();
    ckt.eval(x, 0);

    // Factor (C + gamma*G) once for the whole run; the extra slot is the
    // ground-stamp trash slot.
    const combined_vals = try scratch.alloc(f64, ckt.nnz + 1);
    const nnz: usize = ckt.nnz;
    if (ckt.has_charge)
        combinePlanes(W, combined_vals[0..nnz], ckt.c_vals[0..nnz], ckt.g_vals[0..nnz], gamma)
    else
        num.scale(combined_vals[0..nnz], gamma, ckt.g_vals[0..nnz]);
    combined_vals[nnz] = 0;

    var slv = try Solver.init(ctx.scratch_allocator, nn, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer slv.deinit();
    try slv.factor(combined_vals);

    // G alone carries the particular solution: the source terms of eq. 5
    // are A^-1 C^-1 b = -G^-1 b and A^-2 C^-1 b = G^-1 C G^-1 b.
    var slv_g = try Solver.init(ctx.scratch_allocator, nn, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer slv_g.deinit();
    try slv_g.factor(ckt.g_vals);

    const spots = try collectTransitionSpots(scratch, ckt, opts.t_stop);

    const v_basis_size = n * (m_max_usize + 1);
    const V_basis = try scratch.alloc(f64, v_basis_size);

    // H is m_max x m_max plus one row: the last non-breakdown Arnoldi
    // iteration stores the subdiagonal at H[m_max*m_max + m_max-1], which
    // nothing reads.
    const h_size = m_max_usize * m_max_usize;
    const H_mat = try scratch.alloc(f64, h_size + m_max_usize);

    // tmp1 doubles as posteriorOk's 7*m*m expm scratch.
    const arnoldi_tmp1 = try scratch.alloc(f64, @max(n, 7 * h_size));
    const arnoldi_tmp2 = try scratch.alloc(f64, n);
    const piv_all = try scratch.alloc(u32, m_max_usize);
    const expm_scratch = try scratch.alloc(f64, @max(5 * h_size, 1));
    const expm_out = try scratch.alloc(f64, h_size);
    // Plus m_max for u = H_m^-1 e1 past the m x m block.
    const H_copy = try scratch.alloc(f64, h_size + m_max_usize);

    var b_t = try scratch.alloc(f64, n); // b(t)
    var b_th = try scratch.alloc(f64, n); // b(t+h)
    const v_vec = try scratch.alloc(f64, n); // the vector to exponentiate
    const x_new = try scratch.alloc(f64, n);

    var ainv_bt = try scratch.alloc(f64, n); // A^-1 b(t)
    var ainv_bth = try scratch.alloc(f64, n); // A^-1 b(t+h)
    const ainv2_db = try scratch.alloc(f64, n); // A^-2 (b(t+h) - b(t))/h
    const db_vec = try scratch.alloc(f64, n); // (b(t+h) - b(t))/h
    const pwl_tmp = try scratch.alloc(f64, n);

    const n_probes: u32 = @intCast(ctx.probes.len);
    const est_points: u32 = @intFromFloat(@min(
        @max(@as(f64, 256), opts.t_stop / h_cap * 2.0),
        @as(f64, opts.max_points),
    ));
    var wf = try Waveform.init(ctx.scratch_allocator, n_probes, est_points);
    defer wf.deinit();

    try wf.record(0, x, ctx.probes);

    var t: f64 = 0;
    var ts_idx: usize = 0;
    var steps: u32 = 0;

    // The C plane for the Arnoldi matvec, saved because later evals
    // overwrite the planes.
    const c_vals_saved = try scratch.alloc(f64, ckt.nnz + 1);
    if (ckt.has_charge) {
        simdCopy(c_vals_saved[0..ckt.nnz], ckt.c_vals[0..ckt.nnz]);
    } else {
        root.zeroSimd(c_vals_saved[0..ckt.nnz]);
    }

    while (t < opts.t_stop and steps < 10_000_000) {
        if (steps != 0) try ckt.checkpoint(.{ .phase = .transient, .completed = steps });
        // h: distance to the next transition spot, capped.
        var h = opts.t_stop - t;
        while (ts_idx < spots.len and spots[ts_idx] <= t + 1e-18) : (ts_idx += 1) {}
        if (ts_idx < spots.len) {
            h = @min(h, spots[ts_idx] - t);
        }
        h = @min(h, h_cap);
        if (h < 1e-30) break;
        if (t + h > opts.t_stop) h = opts.t_stop - t;

        // After the first step b(t) and A^-1 b(t) are last step's b(t+h)
        // terms, swapped in below: evalSourceRhs is a pure function of t.
        if (steps == 0) {
            evalSourceRhs(ckt, t, b_t);
            negGinvMul(&slv_g, b_t[0..n], ainv_bt[0..n]);
        }
        evalSourceRhs(ckt, t + h, b_th);

        // MATEX eq. 5, the exact update for piecewise-linear sources:
        //   x(t+h) = expm(hA) [x(t) + A^-1 b(t) + A^-2 db]
        //          - A^-1 b(t+h) - A^-2 db,     db = (b(t+h) - b(t))/h
        {
            const inv_h = 1.0 / h;
            const ihv: V = @splat(inv_h);
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const bt: V = b_t[i..][0..W].*;
                const bth: V = b_th[i..][0..W].*;
                db_vec[i..][0..W].* = ihv * (bth - bt);
            }
            while (i < n) : (i += 1) {
                db_vec[i] = (b_th[i] - b_t[i]) * inv_h;
            }
        }

        negGinvMul(&slv_g, b_th[0..n], ainv_bth[0..n]);
        // A^-2 db = -G^-1 C (-G^-1 db); db_vec is free scratch after this.
        negGinvMul(&slv_g, db_vec[0..n], pwl_tmp[0..n]);
        cscMulVec(nn, ckt.col_ptr, ckt.row_idx, c_vals_saved, pwl_tmp[0..n], db_vec[0..n]);
        negGinvMul(&slv_g, db_vec[0..n], ainv2_db[0..n]);

        {
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const xv: V = x[i..][0..W].*;
                const a1: V = ainv_bt[i..][0..W].*;
                const a2: V = ainv2_db[i..][0..W].*;
                v_vec[i..][0..W].* = xv + a1 + a2;
            }
            while (i < n) : (i += 1) {
                v_vec[i] = x[i] + ainv_bt[i] + ainv2_db[i];
            }
        }

        // expm(hA) z = g(S) S z for S = (C + gamma*G)^-1 C, the
        // shift-inverted operator, and g(mu) = exp((h/gamma)(1 - 1/mu)) / mu.
        // Starting the Krylov space at S z drops the algebraic (mu = 0)
        // components, which expm(hA) sends to zero, so H_m stays regular.
        cscMulVec(nn, ckt.col_ptr, ckt.row_idx, c_vals_saved, v_vec[0..n], pwl_tmp[0..n]);
        slv.solve(pwl_tmp[0..n], db_vec[0..n]);

        const ar = arnoldi(
            nn,
            db_vec[0..n],
            &slv,
            ckt.col_ptr,
            ckt.row_idx,
            c_vals_saved,
            V_basis,
            H_mat,
            m_max,
            h,
            opts.krylov_tol,
            arnoldi_tmp1,
            arnoldi_tmp2,
            piv_all,
        );

        if (ar.m == 0) {
            // Zero vector: only the correction terms remain.
            root.zeroSimd(x_new[0..n]);
        } else {
            const m: usize = ar.m;
            const msq = m * m;

            for (0..m) |i| {
                simdCopy(H_copy[i * m ..][0..m], H_mat[i * m_max_usize ..][0..m]);
            }

            // H_m approximates (C + gamma*G)^-1 C, so hA maps to
            // T = (h/gamma)(I - H_m^-1) and expm(hA) v ~ beta V_m expm(T) e1.
            // ponytail: inverts H_m by dense LU; fine at Krylov sizes.
            const H_inv = expm_out[0..msq];
            const piv = piv_all[0..m];

            // Singular only for a DAE of index > 1, which this path cannot
            // integrate.
            try DenseLu.factorize(m, H_copy[0..msq], piv);

            for (0..m) |j| {
                root.zeroSimd(arnoldi_tmp1[0..m]);
                arnoldi_tmp1[j] = 1.0;
                DenseLu.solveFactored(m, H_copy[0..msq], piv, arnoldi_tmp1[0..m], arnoldi_tmp1[0..m]);
                for (0..m) |i| H_inv[i * m + j] = arnoldi_tmp1[i];
            }

            // u = H_m^-1 e1, kept for g(H_m) e1 = expm(T) u: expmSmall
            // overwrites H_inv.
            const u = H_copy[msq..][0..m];
            for (0..m) |i| u[i] = H_inv[i * m];

            const scale = h / gamma;
            for (0..msq) |i| H_copy[i] = -scale * H_inv[i];
            for (0..m) |i| H_copy[i * m + i] += scale;

            expmSmall(m, H_copy, expm_out, expm_scratch, piv_all);

            // x_new = beta * V_m * expm(T) * u
            root.zeroSimd(x_new[0..n]);
            for (0..m) |k| {
                const coeff = ar.beta * num.dot(expm_out[k * m ..][0..m], u);
                const vk = V_basis[k * n ..][0..n];
                num.axpy(x_new[0..n], coeff, vk[0..n]);
            }
        }

        // Subtract the correction terms A^-1 b(t+h) + A^-2 db.
        {
            var i: usize = 0;
            while (i + W <= n) : (i += W) {
                const xv: V = x_new[i..][0..W].*;
                const a1: V = ainv_bth[i..][0..W].*;
                const a2: V = ainv2_db[i..][0..W].*;
                x_new[i..][0..W].* = xv - a1 - a2;
            }
            while (i < n) : (i += 1) {
                x_new[i] = x_new[i] - ainv_bth[i] - ainv2_db[i];
            }
        }

        simdCopy(x[0..n], x_new[0..n]);
        t += h;
        steps += 1;
        std.mem.swap([]f64, &b_t, &b_th);
        std.mem.swap([]f64, &ainv_bt, &ainv_bth);

        try wf.record(t, x, ctx.probes);
    }

    const names = try root.probeNames(ctx, "time");
    errdefer {
        for (names[1..]) |s_val| a.free(s_val);
        a.free(names);
    }
    const data = try wf.toRows(a, names.len);

    return .{
        .plotname = "MATEX Transient Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = wf.len,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .denseMatMul = denseMatMul,
    .expmSmall = expmSmall,
} else {};
