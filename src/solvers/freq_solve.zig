//! (G + jωC) solves, stacked-real form [G, -ωC; ωC, G].
//!
//! The circuit planes ARE the linearization: fromCircuit is one eval().
//! Dense below the threshold (SIMD row ops beat pointer chasing), sparse
//! above: the 2n pattern is derived once from the circuit CSC — every big
//! column is [G-block rows | ωC-block rows] in ascending order, so filling
//! per omega is a straight streamed copy from the planes. No triplets, no
//! searches, no re-assembly.

const std = @import("std");
const dense_lu = @import("dense_lu.zig");
const direct = @import("direct.zig");
const lane_lu = @import("lane_lu.zig");

const Allocator = std.mem.Allocator;

// ponytail: crossover measured on medium/ladder_filter (n=41: dense 82^3/3
// per omega was 90% of the run; the sparse path refactors in O(nnz) per
// omega). Dense only wins for tiny systems where SIMD row ops beat scatter.
const DENSE_THRESHOLD: u32 = 16;

pub const Error = error{Singular};

/// Frequency-domain solver over element type T (f32 or f64). `FreqSolver`
/// below is the f64 instantiation (existing callers).
pub fn FreqSolverT(comptime T: type) type {
    return struct {
        const Self = @This();
        const DL = dense_lu.DenseLu(T);
        const W = std.simd.suggestVectorLength(T) orelse 1;
        const VT = @Vector(W, T);

        n: u32,
        nn: u32,
        strategy: Strategy,

        const Strategy = union(enum) {
            dense: Dense,
            sp: Sparse,
        };

        // -----------------------------------------------------------------
        // Dense path data (n <= DENSE_THRESHOLD)
        // -----------------------------------------------------------------
        // SoA: G and C kept as flat row-major n×n; the 2n×2n work matrix and
        // its LU copy are separate contiguous slabs (hot during factor/solve,
        // cold between omegas).
        const Dense = struct {
            g_dense: []T, // n×n row-major, owned
            c_mat: []T, // n×n row-major, owned
            a_work: []T, // 2n×2n assembled admittance (unfactored copy)
            a_lu: []T, // 2n×2n factored LU
            piv: []u32, // 2n pivot indices
        };

        // -----------------------------------------------------------------
        // Sparse path data (n > DENSE_THRESHOLD)
        // -----------------------------------------------------------------
        // Borrows the circuit's G/C plane values and column pointers; owns
        // the 2n stacked-real CSC and the direct solver built on it.
        const Sparse = struct {
            // borrowed — circuit must outlive solver and not be re-eval'd mid-sweep
            g_vals: []const T,
            c_vals: []const T,
            src_col_ptr: []const u32,
            // owned 2n CSC + solver
            col_ptr: []u32,
            row_idx: []u32,
            vals: []T,
            slv: direct.SolverT(T),
        };

        inline fn simdCopy(dst: []T, src: []const T) void {
            var i: usize = 0;
            while (i + W <= dst.len) : (i += W) {
                dst[i..][0..W].* = src[i..][0..W].*;
            }
            for (dst[i..], src[i..]) |*d, s| d.* = s;
        }

        // =================================================================
        // Construction
        // =================================================================

        /// Linearize at x_op (one eval — the planes are G and C) and build.
        pub fn fromCircuit(allocator: Allocator, ckt: anytype, x_op: []const T) !Self {
            ckt.linearize(x_op);
            const n: u32 = @intCast(ckt.n);

            if (n <= DENSE_THRESHOLD) {
                const nu: usize = n;
                const g = try allocator.alloc(T, nu * nu);
                ckt.denseG(g);
                const c = allocator.alloc(T, nu * nu) catch |err| {
                    allocator.free(g);
                    return err;
                };
                ckt.denseC(c);
                return initDense(allocator, n, g, c);
            }

            return initSparse(allocator, n, ckt);
        }

        /// Build the sparse 2n stacked-real CSC from the circuit's CSC pattern.
        /// Column j (< n) has [G-block rows r | ωC-block rows r+n];
        /// column j+n mirrors with signs flipped.
        fn initSparse(allocator: Allocator, n: u32, ckt: anytype) !Self {
            const nu: usize = n;
            const nn: u32 = 2 * n;
            const src_nnz: usize = ckt.nnz;
            const total_nnz: usize = 4 * src_nnz; // 2 halves × 2 sub-blocks each

            const col_ptr = try allocator.alloc(u32, @as(usize, nn) + 1);
            errdefer allocator.free(col_ptr);
            const row_idx = try allocator.alloc(u32, total_nnz);
            errdefer allocator.free(row_idx);
            const vals = try allocator.alloc(T, total_nnz);
            errdefer allocator.free(vals);

            // Build the row index pattern: each source column j contributes
            // rows [r] then [r+n] in both halves.
            var p: u32 = 0;
            col_ptr[0] = 0;
            for (0..2) |half| {
                for (0..nu) |j| {
                    const s = ckt.col_ptr[j];
                    const e = ckt.col_ptr[j + 1];
                    for (ckt.row_idx[s..e]) |r| {
                        row_idx[p] = r;
                        p += 1;
                    }
                    for (ckt.row_idx[s..e]) |r| {
                        row_idx[p] = r + n;
                        p += 1;
                    }
                    col_ptr[half * nu + j + 1] = p;
                }
            }

            var slv = try direct.SolverT(T).init(allocator, nn, col_ptr, row_idx, null);
            errdefer slv.deinit();

            return .{
                .n = n,
                .nn = nn,
                .strategy = .{ .sp = .{
                    .g_vals = ckt.g_vals,
                    .c_vals = ckt.c_vals,
                    .src_col_ptr = ckt.col_ptr,
                    .col_ptr = col_ptr,
                    .row_idx = row_idx,
                    .vals = vals,
                    .slv = slv,
                } },
            };
        }

        /// Dense from raw row-major G/C arrays; takes ownership of both.
        pub fn initDense(allocator: Allocator, n: u32, g: []T, c: []T) !Self {
            errdefer allocator.free(g);
            errdefer allocator.free(c);
            const nu: usize = n;
            const nn: u32 = 2 * n;
            const nnu: usize = nn;
            const a_work = try allocator.alloc(T, nnu * nnu);
            errdefer allocator.free(a_work);
            const a_lu = try allocator.alloc(T, nnu * nnu);
            errdefer allocator.free(a_lu);
            const piv = try allocator.alloc(u32, nnu);

            _ = nu;
            return .{
                .n = n,
                .nn = nn,
                .strategy = .{ .dense = .{
                    .g_dense = g,
                    .c_mat = c,
                    .a_work = a_work,
                    .a_lu = a_lu,
                    .piv = piv,
                } },
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            switch (self.strategy) {
                .dense => |*d| {
                    allocator.free(d.g_dense);
                    allocator.free(d.c_mat);
                    allocator.free(d.a_work);
                    allocator.free(d.a_lu);
                    allocator.free(d.piv);
                },
                .sp => |*s| {
                    s.slv.deinit();
                    allocator.free(s.col_ptr);
                    allocator.free(s.row_idx);
                    allocator.free(s.vals);
                },
            }
        }

        // =================================================================
        // Solve interface
        // =================================================================

        /// Single-shot: build + factor + solve at omega. Most common path.
        pub fn solve(self: *Self, omega: T, rhs: []const T, x_out: []T) !void {
            try self.setOmega(omega);
            try self.solveRhs(rhs, x_out);
        }

        /// Build the admittance at omega and factor. For multi-RHS at one
        /// freq, call once then solveRhs N times.
        pub fn setOmega(self: *Self, omega: T) !void {
            switch (self.strategy) {
                .dense => |*d| try setOmegaDense(self.n, self.nn, d, omega),
                .sp => |*s| try setOmegaSparse(self.n, s, omega),
            }
        }

        /// Solve with the current factored admittance. Non-destructive.
        pub fn solveRhs(self: *Self, rhs: []const T, x_out: []T) !void {
            switch (self.strategy) {
                .dense => |*d| DL.solveFactored(self.nn, d.a_lu, d.piv, rhs, x_out),
                .sp => |*s| s.slv.solve(rhs, x_out),
            }
        }

        /// Adjoint solve at the current omega: A^T y = rhs.
        /// Dense path uses solveFactoredT (no re-factorization needed).
        /// Sparse path uses direct.solveT on the existing LU factors.
        pub fn solveRhsT(self: *Self, rhs: []const T, x_out: []T) !void {
            switch (self.strategy) {
                .dense => |*d| DL.solveFactoredT(self.nn, d.a_lu, d.piv, rhs, x_out),
                .sp => |*s| s.slv.solveT(rhs, x_out),
            }
        }

        // =================================================================
        // Batch solve: W-chunked (G + jωC)x = rhs over many omegas.
        // Lane axis = frequency point. Layout mirrors the GpuHook freq blob:
        // omega k's rhs/solution lives at [k*2n..][0..2n] (real‖imag).
        // =================================================================

        /// Solve `omegas.len` frequency points. `rhs`/`x_out` are flat, lane k
        /// at [k*2n..][0..2n]. `adjoint` selects A^T. Falls back to the
        /// per-omega scalar path for the dense strategy, f32, tiny systems, or
        /// any lane whose refactor failed (peeled to full re-factor).
        pub fn solveBatch(self: *Self, gpa: Allocator, omegas: []const T, rhs: []const T, x_out: []T, adjoint: bool) !void {
            const nn: usize = self.nn;
            // Lane path is f64 + sparse only (LaneLu is f64; dense has no tape).
            const use_lanes = comptime (T == f64);
            const sp: *Sparse = switch (self.strategy) {
                .sp => |*s| s,
                .dense => return self.solveBatchSerial(omegas, rhs, x_out, adjoint),
            };
            if (!use_lanes) return self.solveBatchSerial(omegas, rhs, x_out, adjoint);

            const LL = lane_lu.LaneLu(W);
            const nnz2 = sp.vals.len; // structural entries in the 2n CSC
            const vplane = try gpa.alloc(@Vector(W, T), nnz2);
            defer gpa.free(vplane);
            const b_plane = try gpa.alloc(@Vector(W, T), nn);
            defer gpa.free(b_plane);
            const x_plane = try gpa.alloc(@Vector(W, T), nn);
            defer gpa.free(x_plane);

            var base: usize = 0;
            while (base < omegas.len) : (base += W) {
                const cnt = @min(W, omegas.len - base);
                // Ragged tail: pad by repeating the last real omega.
                var ow: [W]T = undefined;
                for (0..W) |l| ow[l] = omegas[base + @min(l, cnt - 1)];
                const omega_vec: @Vector(W, T) = ow;

                // Pivot refresh: scalar factor at the chunk-middle omega.
                setOmegaSparse(self.n, sp, ow[cnt / 2]) catch {
                    // Refresh factor failed at the middle omega: peel the whole
                    // chunk to the serial path (each omega re-factors itself).
                    try self.solveBatchSerial(omegas[base .. base + cnt], rhs[base * nn ..][0 .. cnt * nn], x_out[base * nn ..][0 .. cnt * nn], adjoint);
                    continue;
                };
                // LaneLu needs a SparseLu-backed factorization. If direct
                // dispatched to tridiag/BBD (no .lu), peel to serial.
                const lu = if (sp.slv.lu) |*l| l else {
                    try self.solveBatchSerial(omegas[base .. base + cnt], rhs[base * nn ..][0 .. cnt * nn], x_out[base * nn ..][0 .. cnt * nn], adjoint);
                    continue;
                };

                var ll = try LL.init(gpa, lu);
                defer ll.deinit(gpa);

                fillLanePlane(self.n, sp, omega_vec, vplane);
                const growth: T = @floatCast(sp.slv.params.refactor_growth_limit);
                const bad = ll.refactor(sp.col_ptr, vplane, growth);

                // Broadcast this chunk's rhs into the lane plane.
                for (0..nn) |i| {
                    var v: [W]T = undefined;
                    for (0..W) |l| v[l] = rhs[(base + @min(l, cnt - 1)) * nn + i];
                    b_plane[i] = v;
                }

                if (adjoint) ll.solveT(b_plane, x_plane) else ll.solve(b_plane, x_plane);

                // Deinterleave good lanes into x_out; peel bad lanes to serial.
                for (0..cnt) |l| {
                    if ((bad & (@as(u64, 1) << @intCast(l))) != 0) {
                        try self.solveBatchSerial(omegas[base + l ..][0..1], rhs[(base + l) * nn ..][0..nn], x_out[(base + l) * nn ..][0..nn], adjoint);
                        continue;
                    }
                    const dst = x_out[(base + l) * nn ..][0..nn];
                    for (0..nn) |i| {
                        const row: [W]T = x_plane[i];
                        dst[i] = row[l];
                    }
                }
            }
        }

        /// Reference path: loop setOmega + solveRhs per omega. The lane path
        /// must match this bit-for-bit when op orders agree (they do: LaneLu
        /// lane l replays the same SparseLu numeric sequence as this scalar
        /// factor of the same values).
        fn solveBatchSerial(self: *Self, omegas: []const T, rhs: []const T, x_out: []T, adjoint: bool) !void {
            const nn: usize = self.nn;
            for (omegas, 0..) |omega, k| {
                try self.setOmega(omega);
                if (adjoint)
                    try self.solveRhsT(rhs[k * nn ..][0..nn], x_out[k * nn ..][0..nn])
                else
                    try self.solveRhs(rhs[k * nn ..][0..nn], x_out[k * nn ..][0..nn]);
            }
        }

        /// Lane twin of setOmegaSparse's value fill: writes the W-wide value
        /// plane for W omegas at once, in the SAME structural order the scalar
        /// path fills `s.vals` (so LaneLu, replaying the SparseLu built over
        /// that CSC, is bit-identical to the scalar factor of each lane).
        fn fillLanePlane(n: u32, s: *Sparse, omega: @Vector(W, T), out: []@Vector(W, T)) void {
            const nu: usize = n;
            const neg_omega = -omega;
            var p: usize = 0;
            // Left half: [G_rows | +ωC_rows]
            for (0..nu) |j| {
                const cs = s.src_col_ptr[j];
                const len: usize = s.src_col_ptr[j + 1] - cs;
                for (0..len) |q| out[p + q] = @splat(s.g_vals[cs + q]);
                p += len;
                for (0..len) |q| out[p + q] = omega * @as(@Vector(W, T), @splat(s.c_vals[cs + q]));
                p += len;
            }
            // Right half: [-ωC_rows | G_rows]
            for (0..nu) |j| {
                const cs = s.src_col_ptr[j];
                const len: usize = s.src_col_ptr[j + 1] - cs;
                for (0..len) |q| out[p + q] = neg_omega * @as(@Vector(W, T), @splat(s.c_vals[cs + q]));
                p += len;
                for (0..len) |q| out[p + q] = @splat(s.g_vals[cs + q]);
                p += len;
            }
        }

        // =================================================================
        // Dense internals
        // =================================================================

        fn setOmegaDense(n: u32, nn: u32, d: *Dense, omega: T) !void {
            DL.buildComplexAdmittance(n, nn, d.g_dense, d.c_mat, omega, d.a_work);
            simdCopy(d.a_lu, d.a_work);
            try DL.factorize(nn, d.a_lu, d.piv);
        }

        // =================================================================
        // Sparse internals
        // =================================================================

        /// Streamed fill of the 2n stacked-real values from G/C planes,
        /// then factor. Layout per column:
        ///   left  half (j < n):  [G_rows |  +ωC_rows]
        ///   right half (j >= n): [-ωC_rows | G_rows ]
        fn setOmegaSparse(n: u32, s: *Sparse, omega: T) !void {
            const nu: usize = n;
            const neg_omega = -omega;
            var p: usize = 0;

            // Left half: columns 0..n-1
            for (0..nu) |j| {
                const cs = s.src_col_ptr[j];
                const len = s.src_col_ptr[j + 1] - cs;
                const lenu: usize = len;
                simdCopy(s.vals[p..][0..lenu], s.g_vals[cs..][0..lenu]);
                p += lenu;
                scaleCopy(T, s.vals[p..][0..lenu], s.c_vals[cs..][0..lenu], omega);
                p += lenu;
            }
            // Right half: columns n..2n-1
            for (0..nu) |j| {
                const cs = s.src_col_ptr[j];
                const len = s.src_col_ptr[j + 1] - cs;
                const lenu: usize = len;
                scaleCopy(T, s.vals[p..][0..lenu], s.c_vals[cs..][0..lenu], neg_omega);
                p += lenu;
                simdCopy(s.vals[p..][0..lenu], s.g_vals[cs..][0..lenu]);
                p += lenu;
            }

            try s.slv.factor(s.vals);
        }
    };
}

pub const FreqSolver = FreqSolverT(f64);

/// SIMD-friendly scale-copy: dst[i] = s * src[i].
fn scaleCopy(comptime T: type, dst: []T, src: []const T, s: T) void {
    const W = std.simd.suggestVectorLength(T) orelse 1;
    const VT = @Vector(W, T);
    const sv: VT = @splat(s);

    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: VT = src[i..][0..W].*;
        const p: *[W]T = dst[i..][0..W];
        p.* = sv * v;
    }
    // Scalar tail
    while (i < src.len) : (i += 1) {
        dst[i] = s * src[i];
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "FreqSolver: single-shot solve (dense, 2x2)" {
    // System: (G + jωC) x = b in stacked-real form.
    // G = I, C = 0.1·I, ω = 10 → (I + j·I) → admittance Y = I + j·I.
    // Stacked-real 4×4: [[1, 0, -1, 0], [0, 1, 0, -1], [1, 0, 1, 0], [0, 1, 0, 1]]
    // rhs = [1, 0, 0, 0] → x_re = 0.5, x_im = -0.5 for node 0.
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 1, 0, 0, 1 });
    const c = try allocator.dupe(f64, &[_]f64{ 0.1, 0, 0, 0.1 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    const rhs = [_]f64{ 1, 0, 0, 0 };
    var x: [4]f64 = undefined;
    try fs.solve(10.0, &rhs, &x);

    // x = (G + jωC)^-1 [1; 0] = (1+j)^-1 [1; 0] = [0.5 - 0.5j; 0]
    try testing.expectApproxEqAbs(@as(f64, 0.5), x[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), x[1], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), x[2], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), x[3], 1e-10);
}

test "FreqSolver: multi-RHS at same omega" {
    // G = diag(2, 3), C = 0 → pure real, each node decouples.
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 2, 0, 0, 3 });
    const c = try allocator.dupe(f64, &[_]f64{ 0, 0, 0, 0 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    try fs.setOmega(0);

    // RHS 1: excite node 0
    const rhs1 = [_]f64{ 2, 0, 0, 0 };
    var x1: [4]f64 = undefined;
    try fs.solveRhs(&rhs1, &x1);
    try testing.expectApproxEqAbs(@as(f64, 1.0), x1[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 0.0), x1[1], 1e-10);

    // RHS 2: excite node 1
    const rhs2 = [_]f64{ 0, 3, 0, 0 };
    var x2: [4]f64 = undefined;
    try fs.solveRhs(&rhs2, &x2);
    try testing.expectApproxEqAbs(@as(f64, 0.0), x2[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1.0), x2[1], 1e-10);
}

test "FreqSolver: adjoint solve (solveRhsT) matches transpose system" {
    // Asymmetric G, non-zero C → verify A^T y = rhs via forward check.
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 1, 2, 3, 4 });
    const c = try allocator.dupe(f64, &[_]f64{ 0.1, 0.2, 0.3, 0.4 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    const omega: f64 = 5.0;
    try fs.setOmega(omega);

    const rhs = [_]f64{ 1, 0, 0, 1 };
    var y: [4]f64 = undefined;
    try fs.solveRhsT(&rhs, &y);

    // Verify: build A explicitly, check A^T y ≈ rhs.
    const nn: usize = 4;
    var a: [16]f64 = undefined;
    dense_lu.DenseLu(f64).buildComplexAdmittance(2, 4, &[_]f64{ 1, 2, 3, 4 }, &[_]f64{ 0.1, 0.2, 0.3, 0.4 }, omega, &a);

    for (0..nn) |row| {
        var sum: f64 = 0;
        for (0..nn) |col| sum += a[col * nn + row] * y[col]; // A^T
        try testing.expectApproxEqAbs(rhs[row], sum, 1e-10);
    }
}

test "FreqSolver: forward and adjoint solves are distinct for asymmetric system" {
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 1, 3, 0, 2 });
    const c = try allocator.dupe(f64, &[_]f64{ 0.1, 0, 0.2, 0.1 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    try fs.setOmega(7.0);

    const rhs = [_]f64{ 1, 1, 0, 0 };
    var x_fwd: [4]f64 = undefined;
    var x_adj: [4]f64 = undefined;
    try fs.solveRhs(&rhs, &x_fwd);
    try fs.solveRhsT(&rhs, &x_adj);

    // For an asymmetric system, forward and adjoint solutions must differ.
    var differ = false;
    for (0..4) |i| {
        if (@abs(x_fwd[i] - x_adj[i]) > 1e-12) differ = true;
    }
    try testing.expect(differ);
}

test "FreqSolver: f32 instantiation" {
    const FS32 = FreqSolverT(f32);
    const allocator = testing.allocator;
    const g = try allocator.dupe(f32, &[_]f32{ 1, 0, 0, 1 });
    const c = try allocator.dupe(f32, &[_]f32{ 0.1, 0, 0, 0.1 });

    var fs = try FS32.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    const rhs = [_]f32{ 1, 0, 0, 0 };
    var x: [4]f32 = undefined;
    try fs.solve(10.0, &rhs, &x);

    try testing.expectApproxEqAbs(@as(f32, 0.5), x[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -0.5), x[2], 1e-5);
}

test "FreqSolver: setOmega then solveRhs preserves factorization across calls" {
    // Factor once, solve twice with different RHS — results must be consistent.
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 5, 1, 1, 5 });
    const c = try allocator.dupe(f64, &[_]f64{ 0.5, 0, 0, 0.5 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    try fs.setOmega(3.0);

    // Solve two different RHS and verify Ax = rhs for each.
    var a: [16]f64 = undefined;
    dense_lu.DenseLu(f64).buildComplexAdmittance(2, 4, &[_]f64{ 5, 1, 1, 5 }, &[_]f64{ 0.5, 0, 0, 0.5 }, 3.0, &a);

    const rhs_list = [_][4]f64{
        .{ 1, 0, 0, 0 },
        .{ 0, 0, 1, 0 },
    };
    for (rhs_list) |rhs| {
        var x: [4]f64 = undefined;
        try fs.solveRhs(&rhs, &x);

        // Check A x ≈ rhs
        for (0..4) |row| {
            var sum: f64 = 0;
            for (0..4) |col| sum += a[row * 4 + col] * x[col];
            try testing.expectApproxEqAbs(rhs[row], sum, 1e-10);
        }
    }
}

test "solveBatch equals looped solveRhs (dense fallback, fwd + adjoint)" {
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 5, 1, 2, 4 });
    const c = try allocator.dupe(f64, &[_]f64{ 0.3, 0.1, 0.0, 0.2 });
    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    const omegas = [_]f64{ 1.0, 3.0, 7.0, 13.0, 21.0 };
    const nn: usize = 4;
    // rhs blob: lane k at [k*2n..][0..2n]
    var rhs: [omegas.len * nn]f64 = undefined;
    for (0..omegas.len) |k| for (0..nn) |i| {
        rhs[k * nn + i] = @floatFromInt((k + 1) * (i + 1));
    };

    for ([_]bool{ false, true }) |adjoint| {
        var x_batch: [omegas.len * nn]f64 = undefined;
        try fs.solveBatch(allocator, &omegas, &rhs, &x_batch, adjoint);

        var x_ref: [omegas.len * nn]f64 = undefined;
        try fs.solveBatchSerial(&omegas, &rhs, &x_ref, adjoint);
        for (x_batch, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-12);
    }
}

test "solveBatch equals looped solveRhs (sparse lane path, fwd + adjoint)" {
    const allocator = testing.allocator;
    const n: u32 = 20; // > DENSE_THRESHOLD => sparse strategy => lane path
    // Tridiagonal CSC pattern; diagonally dominant so factors stay well-cond.
    var col_ptr = std.ArrayList(u32).empty;
    defer col_ptr.deinit(allocator);
    var row_idx = std.ArrayList(u32).empty;
    defer row_idx.deinit(allocator);
    var g_vals = std.ArrayList(f64).empty;
    defer g_vals.deinit(allocator);
    var c_vals = std.ArrayList(f64).empty;
    defer c_vals.deinit(allocator);
    try col_ptr.append(allocator, 0);
    for (0..n) |j| {
        // column j: rows j-1, j, j+1 (ascending)
        if (j > 0) {
            try row_idx.append(allocator, @intCast(j - 1));
            try g_vals.append(allocator, -1);
            try c_vals.append(allocator, 0.05);
        }
        try row_idx.append(allocator, @intCast(j));
        try g_vals.append(allocator, 4 + @as(f64, @floatFromInt(j % 3)));
        try c_vals.append(allocator, 0.2);
        if (j + 1 < n) {
            try row_idx.append(allocator, @intCast(j + 1));
            try g_vals.append(allocator, -1);
            try c_vals.append(allocator, 0.05);
        }
        try col_ptr.append(allocator, @intCast(row_idx.items.len));
    }

    const Ckt = struct {
        n: usize,
        nnz: usize,
        col_ptr: []const u32,
        row_idx: []const u32,
        g_vals: []const f64,
        c_vals: []const f64,
        fn linearize(_: @This(), _: []const f64) void {}
        // Never reached (n > DENSE_THRESHOLD) but must exist for fromCircuit's
        // dense branch to type-check against `anytype`.
        fn denseG(_: @This(), _: []f64) void {}
        fn denseC(_: @This(), _: []f64) void {}
    };
    const ckt = Ckt{
        .n = n,
        .nnz = row_idx.items.len,
        .col_ptr = col_ptr.items,
        .row_idx = row_idx.items,
        .g_vals = g_vals.items,
        .c_vals = c_vals.items,
    };
    var fs = try FreqSolver.fromCircuit(allocator, ckt, &.{});
    defer fs.deinit(allocator);

    // Enough omegas to span more than one W-chunk plus a ragged tail.
    const omegas = [_]f64{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000 };
    const nn: usize = 2 * n;
    const total = omegas.len * nn;
    const rhs = try allocator.alloc(f64, total);
    defer allocator.free(rhs);
    for (0..omegas.len) |k| for (0..nn) |i| {
        rhs[k * nn + i] = @sin(@as(f64, @floatFromInt(k * 7 + i)));
    };

    const x_batch = try allocator.alloc(f64, total);
    defer allocator.free(x_batch);
    const x_ref = try allocator.alloc(f64, total);
    defer allocator.free(x_ref);

    for ([_]bool{ false, true }) |adjoint| {
        try fs.solveBatch(allocator, &omegas, rhs, x_batch, adjoint);
        try fs.solveBatchSerial(&omegas, rhs, x_ref, adjoint);
        for (x_batch, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
    }
}

test "scaleCopy: basic operation" {
    var dst: [5]f64 = undefined;
    const src = [_]f64{ 1, 2, 3, 4, 5 };
    scaleCopy(f64, &dst, &src, 3.0);
    const expected = [_]f64{ 3, 6, 9, 12, 15 };
    for (dst, expected) |got, exp| {
        try testing.expectApproxEqAbs(exp, got, 1e-15);
    }
}

test "scaleCopy: empty slice" {
    var dst: [0]f64 = .{};
    const src: [0]f64 = .{};
    scaleCopy(f64, &dst, &src, 42.0);
}

// ponytail: sparse-path integration test deferred — needs circuit CSC
// fixture (CompiledCircuit.Builder). Re-add when solvers has its own
// standalone CSC test harness.
