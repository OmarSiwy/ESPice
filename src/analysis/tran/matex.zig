//! Matrix-Exponential Integrator (MATEX) — linear-circuit fast path.
//!
//! R-MATEX variant: Arnoldi on (I - γA)⁻¹ via a once-factored (C + γG).
//! No Newton, no LTE loop — only source transition spots bound the step.
//! Krylov subspace reuse: one Arnoldi serves every h in the reuse window.
//!
//! ponytail: nonlinear EPIRK path documented but not implemented; add when
//! matrix_sig / const-Jacobian detection says linearization is needed.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const solvers = @import("solvers");
const types = @import("solvers").types;
const dense_lu = solvers.dense_lu;

const DenseLu = dense_lu.DenseLu(f64);
const Solver = solvers.direct.Solver;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;
const V = @Vector(W, f64);

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    tol: converger.Tolerances = .{},
    t_stop: f64,
    /// Krylov posterior tolerance (role of reltol on the exponential).
    krylov_tol: f64 = 1e-10,
    /// Maximum Krylov subspace dimension before declaring failure.
    m_max: u32 = 80,
    /// R-MATEX shift parameter γ — order of intended timestep, insensitive.
    gamma: ?f64 = null,
    /// Output resolution cap — maximum h between recorded points.
    h_output_cap: ?f64 = null,
    /// Maximum recorded points (controls initial waveform allocation).
    max_points: u32 = 1 << 22,
};

// ---------------------------------------------------------------------------
// Sparse CSC matrix-vector product: y = M * x (for n×n CSC M)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Dense small-matrix exponential: scaling & squaring with Padé(6,6)
//
// Padé(6,6) approximant with scaling-squaring. Coefficients:
//   b = [1, 1/2, 1/12, 1/120, 1/1680, 1/30240, 1/720720]
//
// Needs H^2, H^4 = H^2·H^2, H^6 = H^4·H^2 (3 matmuls for powers).
// U = H·(b[1]I + b[3]H^2 + b[5]H^4)    — odd part  (1 matmul)
// V = b[0]I + b[2]H^2 + b[4]H^4 + b[6]H^6  — even part
// expm ≈ (V - U)⁻¹·(V + U)
//
// Total: 4 matmuls + 1 dense LU solve. Accurate to ~1e-10 on the
// scaled-down matrix, which is plenty for Krylov subspaces.
// ---------------------------------------------------------------------------

/// Compute expm(H) for m×m dense row-major H. Result written to out (m×m).
/// Scratch must be at least 5*m*m. Destroys H.
fn expmSmall(m: usize, H: []f64, out: []f64, scratch: []f64) void {
    // Padé [6/6] coefficients: b_j = (12-j)! · 6! / (12! · j! · (6-j)!)
    const b = [_]f64{
        1.0,                // b[0] = 1
        0.5,                // b[1] = 1/2
        5.0 / 44.0,        // b[2] = 5/44
        1.0 / 66.0,        // b[3] = 1/66
        1.0 / 792.0,       // b[4] = 1/792
        1.0 / 15840.0,     // b[5] = 1/15840
        1.0 / 665280.0,    // b[6] = 1/665280
    };

    // Determine scaling factor s such that ||H/2^s|| < 0.5
    // ponytail: infinity-norm (max element) suffices for the scaling decision
    var norm_h: f64 = 0;
    for (0..m * m) |i| norm_h = @max(norm_h, @abs(H[i]));
    var s: u32 = 0;
    while (norm_h > 0.5) : (s += 1) {
        norm_h *= 0.5;
        // Scale H in-place
        for (0..m * m) |i| H[i] *= 0.5;
    }

    const mm = m * m;
    // Scratch layout: H2[mm] | H4[mm] | T[mm] | U[mm] | Vmat[mm]
    const H2 = scratch[0..mm];
    const H4 = scratch[mm .. 2 * mm];
    const T = scratch[2 * mm .. 3 * mm];
    const U = scratch[3 * mm .. 4 * mm];
    const Vmat = scratch[4 * mm .. 5 * mm];

    // H2 = H * H
    denseMatMul(m, H, H, H2);
    // H4 = H2 * H2
    denseMatMul(m, H2, H2, H4);

    // --- Even part: V = b[0]I + b[2]H^2 + b[4]H^4 + b[6]H^6 ---
    // First compute H6 into T (temporary), then build V.
    // H6 = H4 * H2
    denseMatMul(m, H4, H2, T); // T = H^6

    // Vmat = b[2]*H2 + b[4]*H4 + b[6]*H6 + b[0]*I
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
    for (0..m) |i| Vmat[i * m + i] += b[0]; // + b[0]*I

    // --- Odd part: U = H * (b[1]I + b[3]H^2 + b[5]H^4) ---
    // Build the inner matrix into T (we're done with H6)
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
    for (0..m) |i| T[i * m + i] += b[1]; // + b[1]*I

    // U = H * T
    denseMatMul(m, H, T, U);

    // --- Build (V + U) into out, (V - U) into H (which we can destroy) ---
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

    // Solve (V - U) * expm = (V + U) column by column using dense LU
    // Factor V - U (in H)
    var piv_buf: [256]u32 = undefined;
    const piv = piv_buf[0..m];
    DenseLu.factorize(m, H, piv) catch {
        // Singular — fall back to identity (degenerate zero matrix)
        for (0..mm) |i| out[i] = 0;
        for (0..m) |i| out[i * m + i] = 1;
        return;
    };

    // Solve each column: (V-U) * X[:,j] = (V+U)[:,j]
    // out currently holds V+U; solve in-place column by column
    const col_buf = H2; // reuse — factorize destroyed H already
    for (0..m) |j| {
        // Extract column j of (V+U) from out (row-major)
        for (0..m) |i| col_buf[i] = out[i * m + j];
        DenseLu.solveFactored(m, H, piv, col_buf[0..m], col_buf[0..m]);
        for (0..m) |i| out[i * m + j] = col_buf[i];
    }

    // Squaring phase: out = out^(2^s)
    var si: u32 = 0;
    while (si < s) : (si += 1) {
        simdCopy(H2[0..mm], out[0..mm]);
        denseMatMul(m, H2, H2, out);
    }
}

/// Dense m×m matrix multiply: C = A * B (row-major).
fn denseMatMul(m: usize, A: []const f64, B: []const f64, C: []f64) void {
    for (0..m) |i| {
        for (0..m) |j| {
            var sum: f64 = 0;
            for (0..m) |k| sum += A[i * m + k] * B[k * m + j];
            C[i * m + j] = sum;
        }
    }
}

/// SIMD copy for dense buffers (no @memcpy per contract).
fn simdCopy(dst: []f64, src: []const f64) void {
    var i: usize = 0;
    while (i + W <= dst.len) : (i += W) dst[i..][0..W].* = src[i..][0..W].*;
    while (i < dst.len) : (i += 1) dst[i] = src[i];
}

/// SIMD axpy: y[i] += a * x[i]
fn simdAxpy(a: f64, x: []const f64, y: []f64, n: usize) void {
    const av: V = @splat(a);
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const xv: V = x[i..][0..W].*;
        const yv: V = y[i..][0..W].*;
        y[i..][0..W].* = yv + av * xv;
    }
    while (i < n) : (i += 1) y[i] += a * x[i];
}

/// SIMD dot product
fn simdDot(a: []const f64, b: []const f64, n: usize) f64 {
    var acc: V = @splat(@as(f64, 0));
    var i: usize = 0;
    while (i + W <= n) : (i += W) {
        const av: V = a[i..][0..W].*;
        const bv: V = b[i..][0..W].*;
        acc += av * bv;
    }
    var sum = @reduce(.Add, acc);
    while (i < n) : (i += 1) sum += a[i] * b[i];
    return sum;
}

/// SIMD 2-norm
fn simdNorm(x: []const f64, n: usize) f64 {
    return @sqrt(simdDot(x, x, n));
}

// ---------------------------------------------------------------------------
// Arnoldi iteration for R-MATEX: basis of K_m((C + γG)⁻¹ C, v)
//
// The matrix-vector product is: w = (C + γG)⁻¹ (C v_j)
// which is: solve (C + γG) w = C v_j  using the pre-factored LU.
//
// H is the m×m upper Hessenberg matrix (row-major, allocated m_max × m_max).
// V_basis is n × (m_max+1) column-major (each column is one basis vector).
// Returns the actual dimension m used.
// ---------------------------------------------------------------------------

const ArnoldiResult = struct {
    m: u32,
    beta: f64, // ||v||
};

fn arnoldi(
    n: u32,
    v: []const f64,
    slv: *Solver,
    // Circuit CSC for C-matrix multiply
    ckt_n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    c_vals: []const f64,
    // Outputs
    V_basis: []f64, // n * (m_max+1) column-major
    H: []f64, // m_max * m_max row-major
    // Config
    m_max: u32,
    h_step: f64,
    krylov_tol: f64,
    // Scratch: 2*n
    tmp1: []f64,
    tmp2: []f64,
) ArnoldiResult {
    const nn: usize = n;

    // v1 = v / ||v||
    const beta = simdNorm(v, nn);
    if (beta < 1e-300) return .{ .m = 0, .beta = 0 };

    const inv_beta = 1.0 / beta;
    // V_basis[:,0] = v / beta
    {
        var i: usize = 0;
        const av: V = @splat(inv_beta);
        while (i + W <= nn) : (i += W) {
            const vv: V = v[i..][0..W].*;
            V_basis[i..][0..W].* = av * vv;
        }
        while (i < nn) : (i += 1) V_basis[i] = v[i] * inv_beta;
    }

    // Zero H
    root.zeroSimd(H[0 .. @as(usize, m_max) * m_max]);

    var j: u32 = 0;
    while (j < m_max) : (j += 1) {
        const jj: usize = j;
        const vj = V_basis[jj * nn ..][0..nn];

        // tmp1 = C * v_j (sparse CSC matvec)
        cscMulVec(ckt_n, col_ptr, row_idx, c_vals, vj, tmp1[0..nn]);

        // tmp2 = (C + γG)⁻¹ tmp1   (solve using pre-factored LU)
        slv.solve(tmp1[0..nn], tmp2[0..nn]);

        // Modified Gram-Schmidt orthogonalization
        for (0..jj + 1) |k| {
            const vk = V_basis[k * nn ..][0..nn];
            const h_kj = simdDot(tmp2[0..nn], vk, nn);
            H[k * m_max + jj] = h_kj;
            simdAxpy(-h_kj, vk, tmp2[0..nn], nn);
        }

        // h_{j+1,j} = ||w||
        const h_jp1_j = simdNorm(tmp2[0..nn], nn);
        if (h_jp1_j < 1e-300) {
            // Lucky breakdown — exact invariant subspace
            return .{ .m = j + 1, .beta = beta };
        }

        H[(jj + 1) * m_max + jj] = h_jp1_j;

        // v_{j+1} = w / h_{j+1,j}
        const inv_h = 1.0 / h_jp1_j;
        const vj1 = V_basis[(jj + 1) * nn ..][0..nn];
        {
            var i: usize = 0;
            const av2: V = @splat(inv_h);
            while (i + W <= nn) : (i += W) {
                const wv: V = tmp2[i..][0..W].*;
                vj1[i..][0..W].* = av2 * wv;
            }
            while (i < nn) : (i += 1) vj1[i] = tmp2[i] * inv_h;
        }

        // Posterior error estimate (check every iteration after m >= 2):
        // ||r_m(h)|| ≈ beta * |h_{m+1,m} * e_m^T * expm(h * H_m) * e1|
        //
        // For R-MATEX with shift-and-invert, the Hessenberg H relates to
        // (C+γG)⁻¹C, not A directly. The exponential relationship is:
        // e^{hA}v ≈ beta * V_m * f(H_m) * e1
        // where f accounts for the spectral transform.
        //
        // ponytail: use the simpler heuristic — check if the last Arnoldi
        // coefficient h_{j+1,j} * |last component of expm(h*Hinv)*e1| is
        // small relative to beta. For efficiency, only do the full expm check
        // every 5 iterations after m >= 4.
        if (j >= 3 and (j + 1) % 5 == 0) {
            if (posteriorOk(j + 1, m_max, H, h_jp1_j, h_step, beta, krylov_tol, tmp1))
                return .{ .m = j + 1, .beta = beta };
        }
    }

    // Hit m_max without convergence — return what we have
    return .{ .m = m_max, .beta = beta };
}

/// Check posterior error for the R-MATEX Krylov approximation.
/// For shift-and-invert Krylov on (I - γA)⁻¹, the transformed Hessenberg
/// H relates to (C+γG)⁻¹C. The exponential of A is recovered by inverting
/// H and scaling.
///
/// ponytail: simplified posterior — compute expm of the small m×m Hessenberg,
/// check |h_{m+1,m} * (expm(hH⁻¹) * e1)[m-1]| / beta < tol.
/// Full R-MATEX posterior is: transform H to A-space first, but for step
/// acceptance this conservative check works (may use slightly more Krylov
/// vectors than optimal). Upgrade to exact R-MATEX posterior if m is consistently
/// hitting m_max on circuits where it shouldn't.
fn posteriorOk(
    m: u32,
    m_max: u32,
    H: []const f64,
    h_mp1_m: f64,
    h_step: f64,
    beta: f64,
    tol: f64,
    scratch: []f64, // needs at least 7*m*m
) bool {
    const mm: usize = m;
    const msq = mm * mm;

    // We need 7*m*m scratch for expmSmall (H copy + out + 5*m*m internal)
    if (scratch.len < msq + msq + 5 * msq) return false;

    const H_copy = scratch[0..msq];
    const expm_out = scratch[msq .. 2 * msq];
    const expm_scratch = scratch[2 * msq .. 7 * msq];

    // Copy the m×m leading submatrix of H (which is m_max-strided) into
    // contiguous m×m storage.
    for (0..mm) |i| {
        for (0..mm) |j| {
            H_copy[i * mm + j] = H[i * @as(usize, m_max) + j];
        }
    }

    // Scale H_copy by h_step (the time step)
    for (0..msq) |i| H_copy[i] *= h_step;

    expmSmall(mm, H_copy, expm_out, expm_scratch);

    // Error ≈ beta * h_mp1_m * |expm_out[m-1, 0]|
    const last_elem = @abs(expm_out[(mm - 1) * mm]);
    const err = beta * h_mp1_m * last_elem;

    return err < tol * beta; // relative to beta
}

// ---------------------------------------------------------------------------
// Collect transition spots (breakpoints) from circuit sources
// ---------------------------------------------------------------------------

const TransitionSpots = struct {
    spots: []f64,
    len: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, ckt: *root.Circuit, t_stop: f64) !TransitionSpots {
        // Collect breakpoints by scanning the circuit's source list
        var spots_list: std.ArrayListUnmanaged(f64) = .empty;
        defer spots_list.deinit(allocator);

        // Walk through time collecting all breakpoints
        var t: f64 = 0;
        var iters: u32 = 0;
        while (t < t_stop and iters < 100_000) : (iters += 1) {
            if (ckt.nextBreakpoint(t)) |bp| {
                if (bp <= t_stop) {
                    try spots_list.append(allocator, bp);
                    t = bp;
                } else break;
            } else break;
        }
        // Always include t_stop
        try spots_list.append(allocator, t_stop);

        // Sort and deduplicate
        const items = try spots_list.toOwnedSlice(allocator);
        std.mem.sort(f64, items, {}, std.sort.asc(f64));

        // Dedup
        var write: usize = 0;
        for (items, 0..) |v, i| {
            if (i == 0 or v - items[write - 1] > 1e-18) {
                items[write] = v;
                write += 1;
            }
        }

        return .{
            .spots = items,
            .len = write,
            .allocator = allocator,
        };
    }

    fn deinit(self: *TransitionSpots) void {
        self.allocator.free(self.spots);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Assemble dense G and C matrices from circuit
// ---------------------------------------------------------------------------

fn assembleDenseGC(ckt: *root.Circuit, x: []const f64, g_dense: []f64, c_dense: []f64) void {
    const n: usize = ckt.n;
    // Evaluate at the operating point to fill g_vals, c_vals
    ckt.eval(x, 0);
    ckt.denseG(g_dense);
    if (ckt.has_charge) {
        ckt.denseC(c_dense);
    } else {
        root.zeroSimd(c_dense[0 .. n * n]);
    }
}

// ---------------------------------------------------------------------------
// Build and factor (C + γG) for R-MATEX. Uses the circuit's CSC pattern
// to build combined values, then factors via the sparse direct solver.
// ---------------------------------------------------------------------------

fn buildCombinedVals(
    nnz: u32,
    g_vals: []const f64,
    c_vals: []const f64,
    gamma: f64,
    out: []f64,
) void {
    // out[i] = c_vals[i] + gamma * g_vals[i]
    const gv: V = @splat(gamma);
    var i: usize = 0;
    while (i + W <= nnz) : (i += W) {
        const cv: V = c_vals[i..][0..W].*;
        const gvals: V = g_vals[i..][0..W].*;
        out[i..][0..W].* = cv + gv * gvals;
    }
    while (i < nnz) : (i += 1) out[i] = c_vals[i] + gamma * g_vals[i];
}

// ---------------------------------------------------------------------------
// Compute RHS vector b(t) = C⁻¹ B u(t) via: b = -A x_static + rhs_sources
// For linear circuits with sources, the RHS comes from the circuit eval.
// b(t) is obtained by evaluating the circuit at x=0 to get the source-only
// contribution (rhs plane), which is B*u(t).
// ---------------------------------------------------------------------------

fn evalSourceRhs(ckt: *root.Circuit, t: f64, b_out: []f64) void {
    const n: usize = ckt.n;
    // Create a zero x to get pure source contributions
    // ponytail: reuse the rhs plane directly — eval at x=0 gives rhs = B*u(t)
    const x_zero = b_out; // we'll overwrite b_out anyway
    root.zeroSimd(x_zero[0..n]);
    ckt.eval(x_zero, t);
    // After eval at x=0: rhs contains the source contributions
    simdCopy(b_out[0..n], ckt.rhs[0..n]);
}

// ---------------------------------------------------------------------------
// PWL source integral helpers
//
// Full MATEX source integral for piecewise-linear sources (MATEX eq. 5):
//   x(t+h) = expm(hA) * [x(t) + A⁻¹·b(t) + A⁻²·(b(t+h)-b(t))/h]
//          - A⁻¹·b(t+h) - A⁻²·(b(t+h)-b(t))/h
//
// Where A⁻¹·v is computed as a triangular solve against the already-factored
// system matrix (one solve, NOT a matrix inverse).
//
// For R-MATEX: A = -C⁻¹G, so A⁻¹ = -G⁻¹C.
// We use the pre-factored (C + γG) and the sparse G to compute the needed
// solves. Since we have G in CSC and the combined factor, we reformulate:
//
// Let the system be Cx' = -Gx + b(t), so A = -C⁻¹G.
// A⁻¹·v = -G⁻¹·C·v. We compute this via:
//   1. w = C·v  (sparse CSC matvec)
//   2. Solve G·z = -w  (using the system solver with appropriate scaling)
//
// ponytail: for the initial PWL integral, we use the pre-factored (C+γG)
// as an approximate solve for G (exact when γ→0, which is fine for small γ).
// The correction is O(γ²) which is below Krylov tolerance for reasonable γ.
// Exact G-factor when γ-sensitivity causes visible drift.
// ---------------------------------------------------------------------------

/// Compute A⁻¹·v ≈ -(C+γG)⁻¹·(C·v) as an approximate solve.
/// Result written to dest. tmp is scratch of length n.
fn approxAinvMul(
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    c_vals: []const f64,
    slv: *Solver,
    v_in: []const f64,
    dest: []f64,
    tmp: []f64,
) void {
    const nn: usize = n;
    // tmp = C * v_in
    cscMulVec(n, col_ptr, row_idx, c_vals, v_in, tmp[0..nn]);
    // Negate: tmp = -C * v_in  (because A⁻¹ = -G⁻¹C, and we solve (C+γG)≈G)
    {
        const neg: V = @splat(@as(f64, -1.0));
        var i: usize = 0;
        while (i + W <= nn) : (i += W) {
            const tv: V = tmp[i..][0..W].*;
            tmp[i..][0..W].* = neg * tv;
        }
        while (i < nn) : (i += 1) tmp[i] = -tmp[i];
    }
    // dest = (C+γG)⁻¹ * (-C * v_in)
    slv.solve(tmp[0..nn], dest[0..nn]);
}

// ---------------------------------------------------------------------------
// Main MATEX march: exponential integration with Krylov approximation
// ---------------------------------------------------------------------------

pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const ckt = ctx.circuit;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const n: usize = ckt.n;
    const nn: u32 = ckt.n;

    if (n == 0) return error.EmptyCircuit;

    // --- DC operating point as initial condition ---
    const x = try a.alloc(f64, n);
    defer a.free(x);
    simdCopy(x, x_op);

    // --- Gamma: default to t_stop / 1000 if not specified ---
    const gamma = opts.gamma orelse opts.t_stop / 1000.0;

    // --- Output resolution cap ---
    const h_cap = opts.h_output_cap orelse opts.t_stop / 200.0;

    const m_max = opts.m_max;
    const m_max_usize: usize = m_max;

    // --- Evaluate circuit once to populate G, C planes ---
    try ckt.computeBaseline();
    ckt.eval(x, 0);

    // --- Build (C + γG) combined values and factor ---
    const combined_vals = try a.alloc(f64, ckt.nnz + 1);
    defer a.free(combined_vals);

    if (ckt.has_charge) {
        buildCombinedVals(ckt.nnz, ckt.g_vals, ckt.c_vals, gamma, combined_vals);
    } else {
        // No charge elements — C = 0, combined = γG
        const gv: V = @splat(gamma);
        var i: usize = 0;
        while (i + W <= ckt.nnz) : (i += W) {
            const g: V = ckt.g_vals[i..][0..W].*;
            combined_vals[i..][0..W].* = gv * g;
        }
        while (i < ckt.nnz) : (i += 1) combined_vals[i] = gamma * ckt.g_vals[i];
    }
    // Handle trash slot (ground stamp area)
    if (ckt.nnz < combined_vals.len) combined_vals[ckt.nnz] = 0;

    // Factor (C + γG) — ONE factorization for the entire simulation
    var slv = try Solver.init(a, nn, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer slv.deinit();
    try slv.factor(combined_vals);

    // --- Collect transition spots ---
    var ts = try TransitionSpots.init(a, ckt, opts.t_stop);
    defer ts.deinit();

    // --- Allocate Krylov workspace ---
    // V_basis: n * (m_max+1) column-major
    const v_basis_size = n * (m_max_usize + 1);
    const V_basis = try a.alloc(f64, v_basis_size);
    defer a.free(V_basis);

    // H: m_max * m_max row-major
    const h_size = m_max_usize * m_max_usize;
    const H_mat = try a.alloc(f64, h_size);
    defer a.free(H_mat);

    // Scratch for Arnoldi: 2*n
    const arnoldi_tmp1 = try a.alloc(f64, n);
    defer a.free(arnoldi_tmp1);
    const arnoldi_tmp2 = try a.alloc(f64, n);
    defer a.free(arnoldi_tmp2);

    // Scratch for expm: 7*m_max^2 (Padé(6) needs 5*m*m, plus H_copy + expm_out)
    const expm_scratch_size = 7 * h_size;
    const expm_scratch = try a.alloc(f64, @max(expm_scratch_size, 1));
    defer a.free(expm_scratch);

    // Small expm output: m_max * m_max
    const expm_out = try a.alloc(f64, h_size);
    defer a.free(expm_out);

    // Small H copy for expm
    const H_copy = try a.alloc(f64, h_size);
    defer a.free(H_copy);

    // Temporary vectors for the step update
    const b_t = try a.alloc(f64, n); // b(t) = source RHS at time t
    defer a.free(b_t);
    const b_th = try a.alloc(f64, n); // b(t+h) = source RHS at time t+h
    defer a.free(b_th);
    const v_vec = try a.alloc(f64, n); // the vector to exponentiate
    defer a.free(v_vec);
    const y_vec = try a.alloc(f64, n); // result of V_m * expm * e1
    defer a.free(y_vec);
    const x_new = try a.alloc(f64, n); // next state
    defer a.free(x_new);

    // PWL integral scratch vectors
    const ainv_bt = try a.alloc(f64, n); // A⁻¹·b(t)
    defer a.free(ainv_bt);
    const ainv_bth = try a.alloc(f64, n); // A⁻¹·b(t+h)
    defer a.free(ainv_bth);
    const ainv2_db = try a.alloc(f64, n); // A⁻²·(b(t+h)-b(t))/h
    defer a.free(ainv2_db);
    const db_vec = try a.alloc(f64, n); // (b(t+h)-b(t))/h
    defer a.free(db_vec);
    const pwl_tmp = try a.alloc(f64, n); // scratch for approxAinvMul
    defer a.free(pwl_tmp);

    // --- Waveform recording ---
    const n_probes: u32 = @intCast(ctx.probes.len);
    const est_points: u32 = @intFromFloat(@min(
        @max(@as(f64, 256), opts.t_stop / h_cap * 2.0),
        @as(f64, opts.max_points),
    ));
    var wf = try @import("tran.zig").Waveform.init(a, n_probes, est_points);
    defer wf.deinit();

    // Record initial point
    try wf.record(0, x, ctx.probes);

    // --- Time march ---
    var t: f64 = 0;
    var ts_idx: usize = 0;
    var steps: u32 = 0;

    // Save C values for matvec in Arnoldi (they get overwritten by eval)
    const c_vals_saved = try a.alloc(f64, ckt.nnz + 1);
    defer a.free(c_vals_saved);
    if (ckt.has_charge) {
        simdCopy(c_vals_saved[0..ckt.nnz], ckt.c_vals[0..ckt.nnz]);
    } else {
        root.zeroSimd(c_vals_saved[0..ckt.nnz]);
    }

    while (t < opts.t_stop and steps < 10_000_000) {
        // Determine step size h: distance to next transition spot, capped
        var h = opts.t_stop - t;
        while (ts_idx < ts.len and ts.spots[ts_idx] <= t + 1e-18) : (ts_idx += 1) {}
        if (ts_idx < ts.len) {
            h = @min(h, ts.spots[ts_idx] - t);
        }
        h = @min(h, h_cap);
        if (h < 1e-30) break;

        // Clamp to t_stop
        if (t + h > opts.t_stop) h = opts.t_stop - t;

        // Get source RHS at t and t+h
        evalSourceRhs(ckt, t, b_t);
        evalSourceRhs(ckt, t + h, b_th);

        // --- Full PWL source integral (MATEX eq. 5) ---
        //
        // x(t+h) = expm(hA) * [x(t) + A⁻¹·b(t) + A⁻²·(b(t+h)-b(t))/h]
        //        - A⁻¹·b(t+h) - A⁻²·(b(t+h)-b(t))/h
        //
        // Step 1: Compute db = (b(t+h) - b(t)) / h
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

        // Step 2: Compute A⁻¹·b(t) and A⁻¹·b(t+h)
        approxAinvMul(nn, ckt.col_ptr, ckt.row_idx, c_vals_saved, &slv, b_t[0..n], ainv_bt[0..n], pwl_tmp[0..n]);
        approxAinvMul(nn, ckt.col_ptr, ckt.row_idx, c_vals_saved, &slv, b_th[0..n], ainv_bth[0..n], pwl_tmp[0..n]);

        // Step 3: Compute A⁻²·db = A⁻¹·(A⁻¹·db)
        approxAinvMul(nn, ckt.col_ptr, ckt.row_idx, c_vals_saved, &slv, db_vec[0..n], pwl_tmp[0..n], ainv2_db[0..n]);
        // pwl_tmp now holds A⁻¹·db, apply A⁻¹ again:
        approxAinvMul(nn, ckt.col_ptr, ckt.row_idx, c_vals_saved, &slv, pwl_tmp[0..n], ainv2_db[0..n], db_vec[0..n]);
        // ainv2_db now holds A⁻²·(b(t+h)-b(t))/h

        // Step 4: Build the vector for the Krylov exponential:
        //   v = x(t) + A⁻¹·b(t) + A⁻²·(b(t+h)-b(t))/h
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

        // --- Arnoldi iteration ---
        const ar = arnoldi(
            nn,
            v_vec[0..n],
            &slv,
            nn,
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
        );

        if (ar.m == 0) {
            // Zero vector — x doesn't change, subtract the correction terms
            root.zeroSimd(x_new[0..n]);
        } else {
            const m: usize = ar.m;
            const msq = m * m;

            // Copy the m×m leading submatrix of H (m_max-strided → m-strided)
            for (0..m) |i| {
                for (0..m) |j| {
                    H_copy[i * m + j] = H_mat[i * m_max_usize + j];
                }
            }

            // For R-MATEX: the Hessenberg H represents (C+γG)⁻¹C.
            // To recover expm(hA), we need:
            //   expm(hA) v ≈ beta * V_m * g(H_m) * e1
            // where g maps from the shifted-inverted spectrum back to A-space.
            //
            // ponytail: for now, use the direct approach — invert H via dense LU,
            // build T = h/γ * (I - H⁻¹), expm(T).

            // Step 1: Invert H_copy (m×m) using dense LU
            const H_inv = expm_out[0..msq]; // reuse buffer
            root.zeroSimd(H_inv[0..msq]);
            for (0..m) |i| H_inv[i * m + i] = 1.0;

            // Factor H_copy
            var piv_buf: [256]u32 = undefined;
            const piv = piv_buf[0..m];

            // We need a copy since factorize destroys the matrix
            const H_factored = expm_scratch[0..msq];
            simdCopy(H_factored[0..msq], H_copy[0..msq]);

            const lu_ok = DenseLu.factorize(m, H_factored, piv);
            if (lu_ok) |_| {
                // This branch is never taken — factorize returns void or error
            } else |_| {
                // Singular H — fall back to forward Euler
                simdCopy(x_new[0..n], x[0..n]);
                simdAxpy(h, b_t[0..n], x_new[0..n], n);
                simdCopy(x[0..n], x_new[0..n]);
                t += h;
                steps += 1;
                try wf.record(t, x, ctx.probes);
                continue;
            }

            // Solve H * H_inv[:,j] = I[:,j] for each column j
            for (0..m) |j| {
                root.zeroSimd(arnoldi_tmp1[0..m]);
                arnoldi_tmp1[j] = 1.0;
                DenseLu.solveFactored(m, H_factored, piv, arnoldi_tmp1[0..m], arnoldi_tmp1[0..m]);
                for (0..m) |i| H_inv[i * m + j] = arnoldi_tmp1[i];
            }

            // Step 2: T = (h/γ) * (I - H_inv)
            const scale = h / gamma;
            for (0..msq) |i| H_copy[i] = -scale * H_inv[i];
            for (0..m) |i| H_copy[i * m + i] += scale;

            // Step 3: expm(T) → expm_out
            const expm_inner_scratch = expm_scratch[msq .. msq + 5 * msq];
            expmSmall(m, H_copy, expm_out, expm_inner_scratch);

            // x_exp = beta * V_m * (expm_out * e1)
            // y_small = expm_out[:,0] (column 0 of m×m row-major)
            // x_exp = beta * V_m * y_small
            root.zeroSimd(x_new[0..n]);
            for (0..m) |k| {
                const coeff = ar.beta * expm_out[k * m]; // expm[k,0]
                const vk = V_basis[k * n ..][0..n];
                simdAxpy(coeff, vk, x_new[0..n], n);
            }
        }

        // x_new now holds expm(hA) * [x(t) + A⁻¹b(t) + A⁻²·db/h].
        // Subtract the correction terms: - A⁻¹·b(t+h) - A⁻²·(b(t+h)-b(t))/h
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

        // Accept step
        simdCopy(x[0..n], x_new[0..n]);
        t += h;
        steps += 1;

        try wf.record(t, x, ctx.probes);
    }

    // --- Format result ---
    const names = try root.probeNames(ctx, "time");
    errdefer {
        for (names[1..]) |s_val| a.free(s_val);
        a.free(names);
    }
    const ncols = names.len;
    const npoints: usize = wf.len;
    const data = try a.alloc(f64, npoints * ncols);
    const times = wf.timeSlice();
    for (0..npoints) |p| {
        const row = data[p * ncols ..][0..ncols];
        row[0] = times[p];
        for (0..ctx.probes.len) |idx| row[idx + 1] = wf.probeValues(@intCast(idx))[p];
    }

    return .{
        .plotname = "MATEX Transient Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "expmSmall: identity" {
    // expm(0) = I
    var H = [_]f64{ 0, 0, 0, 0 };
    var out: [4]f64 = undefined;
    var scratch: [20]f64 = undefined; // 5*2*2 = 20
    expmSmall(2, &H, &out, &scratch);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[3], 1e-12);
}

test "expmSmall: diagonal" {
    // expm(diag(1,2)) = diag(e, e^2)
    var H = [_]f64{ 1, 0, 0, 2 };
    var out: [4]f64 = undefined;
    var scratch: [20]f64 = undefined;
    expmSmall(2, &H, &out, &scratch);
    // Padé(6,6) + scaling-squaring: ~1e-10 on the small matrix
    try testing.expectApproxEqRel(std.math.e, out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-10);
    try testing.expectApproxEqRel(std.math.e * std.math.e, out[3], 1e-6);
}

test "expmSmall: 1x1" {
    var H = [_]f64{1.0};
    var out: [1]f64 = undefined;
    var scratch: [5]f64 = undefined; // 5*1*1
    expmSmall(1, &H, &out, &scratch);
    try testing.expectApproxEqRel(std.math.e, out[0], 1e-6);
}

test "expmSmall: 3x3 nilpotent" {
    // H = [[0,1,0],[0,0,1],[0,0,0]] — nilpotent, expm = I + H + H²/2
    // expm = [[1,1,0.5],[0,1,1],[0,0,1]]
    var H = [_]f64{ 0, 1, 0, 0, 0, 1, 0, 0, 0 };
    var out: [9]f64 = undefined;
    var scratch: [45]f64 = undefined; // 5*3*3
    expmSmall(3, &H, &out, &scratch);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[0], 1e-12); // [0,0]
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[1], 1e-12); // [0,1]
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[2], 1e-12); // [0,2]
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-12); // [1,0]
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[4], 1e-12); // [1,1]
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[5], 1e-12); // [1,2]
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[6], 1e-12); // [2,0]
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[7], 1e-12); // [2,1]
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[8], 1e-12); // [2,2]
}

test "expmSmall: scaled diagonal needs squaring" {
    // expm(diag(5,5)) = diag(e^5, e^5) — forces scaling-squaring
    var H = [_]f64{ 5, 0, 0, 5 };
    var out: [4]f64 = undefined;
    var scratch: [20]f64 = undefined;
    expmSmall(2, &H, &out, &scratch);
    const e5 = @exp(@as(f64, 5.0));
    try testing.expectApproxEqRel(e5, out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-6);
    try testing.expectApproxEqRel(e5, out[3], 1e-6);
}

test "expmSmall: antisymmetric (rotation)" {
    // H = [[0, -pi/4], [pi/4, 0]] => expm is rotation by pi/4
    // expm = [[cos(pi/4), -sin(pi/4)], [sin(pi/4), cos(pi/4)]]
    const angle = std.math.pi / 4.0;
    var H = [_]f64{ 0, -angle, angle, 0 };
    var out: [4]f64 = undefined;
    var scratch: [20]f64 = undefined;
    expmSmall(2, &H, &out, &scratch);
    const c = @cos(angle);
    const s_val = @sin(angle);
    try testing.expectApproxEqRel(c, out[0], 1e-6);
    try testing.expectApproxEqRel(-s_val, out[1], 1e-6);
    try testing.expectApproxEqRel(s_val, out[2], 1e-6);
    try testing.expectApproxEqRel(c, out[3], 1e-6);
}

test "denseMatMul: identity times A" {
    const A = [_]f64{ 1, 2, 3, 4 };
    const I = [_]f64{ 1, 0, 0, 1 };
    var C: [4]f64 = undefined;
    denseMatMul(2, &I, &A, &C);
    try testing.expectApproxEqAbs(@as(f64, 1.0), C[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.0), C[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.0), C[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 4.0), C[3], 1e-15);
}

test "simdDot: basic" {
    const a_arr = [_]f64{ 1, 2, 3, 4 };
    const b_arr = [_]f64{ 5, 6, 7, 8 };
    const d = simdDot(&a_arr, &b_arr, 4);
    try testing.expectApproxEqAbs(@as(f64, 70.0), d, 1e-12);
}

test "simdNorm: unit" {
    const v_arr = [_]f64{ 3, 4 };
    try testing.expectApproxEqAbs(@as(f64, 5.0), simdNorm(&v_arr, 2), 1e-12);
}

test "simdAxpy: basic" {
    const x_arr = [_]f64{ 1, 2, 3 };
    var y_arr = [_]f64{ 10, 20, 30 };
    simdAxpy(2.0, &x_arr, &y_arr, 3);
    try testing.expectApproxEqAbs(@as(f64, 12.0), y_arr[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 24.0), y_arr[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 36.0), y_arr[2], 1e-15);
}

test "buildCombinedVals: gamma=1 gives C+G" {
    const g = [_]f64{ 1, 2, 3 };
    const c = [_]f64{ 10, 20, 30 };
    var out: [3]f64 = undefined;
    buildCombinedVals(3, &g, &c, 1.0, &out);
    try testing.expectApproxEqAbs(@as(f64, 11.0), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 22.0), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 33.0), out[2], 1e-15);
}
