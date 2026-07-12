//! Batch frequency-domain solver kernel — N independent (G + jωC)x = b
//! systems in one standard (non-cooperative) launch. One thread block per
//! frequency point. Dense stacked-real formulation for small circuits
//! (n ≤ 256). The adjoint variant solves Aᵀx = b.
//!
//! Standard launch (NOT cooperative — each block is independent).
//! Grid: n_points blocks. Block: min(2n, 256) threads.

const abi = @import("gpu_abi");

/// Arguments passed as a flat struct via device global memory.
pub const FreqArgs = extern struct {
    n: u32,
    nnz: u32,
    n_points: u32,
    _pad: u32 = 0,
    off_g: u64,
    off_c: u64,
    off_col_ptr: u64,
    off_row_idx: u64,
    off_omegas: u64,
    off_rhs: u64,
    off_solutions: u64,
    off_scratch: u64,
};

// ---------------------------------------------------------------------------
// Dense LU with partial pivoting — in-block, row-major, nn = 2*n
// ---------------------------------------------------------------------------

fn denseLuFactor(
    comptime addrspace_tag: anytype,
    nn: u32,
    a: [*]addrspace(addrspace_tag) f64,
    piv: [*]addrspace(addrspace_tag) u32,
    tid: u32,
    block_size: u32,
) bool {
    _ = block_size;
    // Single-thread factorization (thread 0 per block)
    if (tid != 0) return true;

    const m: usize = nn;
    for (0..m) |k| {
        // Partial pivot: find max |a[i,k]| for i >= k
        var best: usize = k;
        var best_val = @abs(a[k * m + k]);
        for (k + 1..m) |i| {
            const v = @abs(a[i * m + k]);
            if (v > best_val) {
                best = i;
                best_val = v;
            }
        }
        piv[k] = @intCast(best);
        if (best_val < 1e-30) return false; // singular

        // Swap rows k and best
        if (best != k) {
            for (0..m) |j| {
                const tmp = a[k * m + j];
                a[k * m + j] = a[best * m + j];
                a[best * m + j] = tmp;
            }
        }

        // Eliminate below
        const inv = 1.0 / a[k * m + k];
        for (k + 1..m) |i| {
            const factor = a[i * m + k] * inv;
            a[i * m + k] = factor; // store L in-place
            for (k + 1..m) |j| {
                a[i * m + j] -= factor * a[k * m + j];
            }
        }
    }
    return true;
}

fn denseLuSolve(
    comptime addrspace_tag: anytype,
    nn: u32,
    a: [*]addrspace(addrspace_tag) const f64,
    piv: [*]addrspace(addrspace_tag) const u32,
    b: [*]addrspace(addrspace_tag) f64,
    x: [*]addrspace(addrspace_tag) f64,
    tid: u32,
) void {
    if (tid != 0) return;
    const m: usize = nn;

    // Apply pivot permutation to b → x
    for (0..m) |i| x[i] = b[i];
    for (0..m) |i| {
        const p: usize = piv[i];
        if (p != i) {
            const tmp = x[i];
            x[i] = x[p];
            x[p] = tmp;
        }
    }
    // Forward substitution (L)
    for (1..m) |i| {
        var s = x[i];
        for (0..i) |j| s -= a[i * m + j] * x[j];
        x[i] = s;
    }
    // Back substitution (U)
    var k: usize = m;
    while (k > 0) {
        k -= 1;
        var s = x[k];
        for (k + 1..m) |j| s -= a[k * m + j] * x[j];
        x[k] = s / a[k * m + k];
    }
}

fn denseLuSolveTranspose(
    comptime addrspace_tag: anytype,
    nn: u32,
    a: [*]addrspace(addrspace_tag) const f64,
    piv: [*]addrspace(addrspace_tag) const u32,
    b: [*]addrspace(addrspace_tag) f64,
    x: [*]addrspace(addrspace_tag) f64,
    tid: u32,
) void {
    if (tid != 0) return;
    const m: usize = nn;

    // Uᵀ solve: forward substitution on upper triangle transposed
    for (0..m) |i| x[i] = b[i];
    for (0..m) |i| {
        x[i] /= a[i * m + i];
        for (i + 1..m) |j| x[j] -= a[i * m + j] * x[i];
    }
    // Lᵀ solve: back substitution on lower triangle transposed
    var k: usize = m;
    while (k > 0) {
        k -= 1;
        for (0..k) |j| x[j] -= a[k * m + j] * x[k];
    }
    // Reverse pivot permutation
    var p: usize = m;
    while (p > 0) {
        p -= 1;
        const pi: usize = piv[p];
        if (pi != p) {
            const tmp = x[p];
            x[p] = x[pi];
            x[pi] = tmp;
        }
    }
}

// ---------------------------------------------------------------------------
// Build stacked-real admittance matrix from sparse CSC G, C
// ---------------------------------------------------------------------------

fn buildStackedReal(
    comptime AS: anytype,
    n: u32,
    nn: u32,
    g_vals: [*]addrspace(AS) const f64,
    c_vals: [*]addrspace(AS) const f64,
    col_ptr: [*]addrspace(AS) const u32,
    row_idx: [*]addrspace(AS) const u32,
    omega: f64,
    a: [*]addrspace(AS) f64,
    tid: u32,
) void {
    if (tid != 0) return;
    const m: usize = nn;
    // Zero
    for (0..m * m) |i| a[i] = 0;
    // Fill from CSC
    for (0..n) |j| {
        for (col_ptr[j]..col_ptr[j + 1]) |p| {
            const i: usize = row_idx[p];
            const g = g_vals[p];
            const c = c_vals[p];
            // [G, -ωC; ωC, G]
            a[i * m + j] = g;
            a[i * m + (n + j)] = -omega * c;
            a[(n + i) * m + j] = omega * c;
            a[(n + i) * m + (n + j)] = g;
        }
    }
}

// ---------------------------------------------------------------------------
// Kernel entries
// ---------------------------------------------------------------------------

fn arpFreqSolve(args_ptr: [*]addrspace(.global) const u8) callconv(.kernel) void {
    @setFloatMode(.optimized);
    const args: *const FreqArgs = @ptrCast(@alignCast(args_ptr));
    const point_id = @workGroupId(0);
    if (point_id >= args.n_points) return;

    const n: u32 = args.n;
    const nn: u32 = 2 * n;
    const tid = @workItemId(0);

    const g_vals: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_g);
    const c_vals: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_c);
    const col_ptr: [*]addrspace(.global) const u32 = @ptrFromInt(args.off_col_ptr);
    const row_idx: [*]addrspace(.global) const u32 = @ptrFromInt(args.off_row_idx);
    const omegas: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_omegas);
    const rhs: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_rhs);
    const solutions: [*]addrspace(.global) f64 = @ptrFromInt(args.off_solutions);

    const omega = omegas[point_id];

    // Per-block scratch: A(nn*nn) + piv(nn) + rhs_local(nn) + x_local(nn)
    const scratch_base: [*]addrspace(.global) f64 = @ptrFromInt(args.off_scratch);
    const per_point = @as(usize, nn) * nn + nn + nn + nn;
    const scratch = scratch_base + @as(usize, point_id) * per_point;

    const a = scratch;
    const piv_f: [*]addrspace(.global) f64 = scratch + @as(usize, nn) * nn;
    const piv: [*]addrspace(.global) u32 = @ptrCast(@alignCast(piv_f));
    const rhs_local = piv_f + nn;
    const x_local = rhs_local + nn;

    // Build stacked-real A
    buildStackedReal(.global, n, nn, g_vals, c_vals, col_ptr, row_idx, omega, a, tid);
    @fence(.seq_cst);

    // Copy RHS
    if (tid == 0) {
        for (0..nn) |i| rhs_local[i] = rhs[i];
    }
    @fence(.seq_cst);

    // Factor + solve
    const ok = denseLuFactor(.global, nn, a, piv, tid, @workGroupSize(0));
    @fence(.seq_cst);

    if (ok) {
        denseLuSolve(.global, nn, a, piv, rhs_local, x_local, tid);
    } else {
        if (tid == 0) for (0..nn) |i| x_local[i] = 0;
    }
    @fence(.seq_cst);

    // Write solution
    if (tid == 0) {
        const out = solutions + @as(usize, point_id) * nn;
        for (0..nn) |i| out[i] = x_local[i];
    }
}

fn arpFreqSolveAdjoint(args_ptr: [*]addrspace(.global) const u8) callconv(.kernel) void {
    @setFloatMode(.optimized);
    const args: *const FreqArgs = @ptrCast(@alignCast(args_ptr));
    const point_id = @workGroupId(0);
    if (point_id >= args.n_points) return;

    const n: u32 = args.n;
    const nn: u32 = 2 * n;
    const tid = @workItemId(0);

    const g_vals: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_g);
    const c_vals: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_c);
    const col_ptr: [*]addrspace(.global) const u32 = @ptrFromInt(args.off_col_ptr);
    const row_idx: [*]addrspace(.global) const u32 = @ptrFromInt(args.off_row_idx);
    const omegas: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_omegas);
    const rhs: [*]addrspace(.global) const f64 = @ptrFromInt(args.off_rhs);
    const solutions: [*]addrspace(.global) f64 = @ptrFromInt(args.off_solutions);

    const omega = omegas[point_id];

    const scratch_base: [*]addrspace(.global) f64 = @ptrFromInt(args.off_scratch);
    const per_point = @as(usize, nn) * nn + nn + nn + nn;
    const scratch = scratch_base + @as(usize, point_id) * per_point;

    const a = scratch;
    const piv_f: [*]addrspace(.global) f64 = scratch + @as(usize, nn) * nn;
    const piv: [*]addrspace(.global) u32 = @ptrCast(@alignCast(piv_f));
    const rhs_local = piv_f + nn;
    const x_local = rhs_local + nn;

    buildStackedReal(.global, n, nn, g_vals, c_vals, col_ptr, row_idx, omega, a, tid);
    @fence(.seq_cst);

    if (tid == 0) {
        for (0..nn) |i| rhs_local[i] = rhs[i];
    }
    @fence(.seq_cst);

    const ok = denseLuFactor(.global, nn, a, piv, tid, @workGroupSize(0));
    @fence(.seq_cst);

    if (ok) {
        denseLuSolveTranspose(.global, nn, a, piv, rhs_local, x_local, tid);
    } else {
        if (tid == 0) for (0..nn) |i| x_local[i] = 0;
    }
    @fence(.seq_cst);

    if (tid == 0) {
        const out = solutions + @as(usize, point_id) * nn;
        for (0..nn) |i| out[i] = x_local[i];
    }
}

comptime {
    @export(&arpFreqSolve, .{ .name = "arp_freq_solve" });
    @export(&arpFreqSolveAdjoint, .{ .name = "arp_freq_solve_adjoint" });
}
