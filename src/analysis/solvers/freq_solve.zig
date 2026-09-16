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

/// Frequency-domain solver over element type T (f32 or f64). `FreqSolver`
/// below is the f64 instantiation (existing callers).
pub fn FreqSolverT(comptime T: type) type {
    return struct {
        const Self = @This();
        const DL = dense_lu.DenseLu(T);
        const W = std.simd.suggestVectorLength(T) orelse 1;

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
        // SoA: G/C are flat row-major n×n planes. Assemble each frequency
        // directly into the reusable 2n×2n LU slab.
        const Dense = struct {
            g_dense: []T, // n×n row-major, owned
            c_mat: []T, // n×n row-major, owned
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
            // Solver-lifetime AoSoA scratch: one vector per structural entry,
            // followed by RHS and solution planes. Reused across query yields.
            lane_work: []@Vector(W, T) = &.{},
            lanes: if (T == f64) ?lane_lu.LaneLu(W) else void = if (T == f64) null else {},
        };

        // =================================================================
        // Construction
        // =================================================================

        /// Linearize at x_op (one eval — the planes are G and C) and build.
        pub fn fromCircuit(allocator: Allocator, ckt: anytype, x_op: []const T) !Self {
            try ckt.linearizeAc(x_op);
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
            const nn: u32 = 2 * n;
            const src_nnz: usize = ckt.nnz;
            const total_nnz: usize = 4 * src_nnz; // 2 halves × 2 sub-blocks each

            const col_ptr = try allocator.alloc(u32, @as(usize, nn) + 1);
            errdefer allocator.free(col_ptr);
            const row_idx = try allocator.alloc(u32, total_nnz);
            errdefer allocator.free(row_idx);
            const vals = try allocator.alloc(T, total_nnz);
            errdefer allocator.free(vals);

            buildStackedRealPattern(n, ckt.col_ptr, ckt.row_idx, col_ptr, row_idx);

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
            const nn: u32 = 2 * n;
            const nnu: usize = nn;
            const a_lu = try allocator.alloc(T, nnu * nnu);
            errdefer allocator.free(a_lu);
            const piv = try allocator.alloc(u32, nnu);

            return .{
                .n = n,
                .nn = nn,
                .strategy = .{ .dense = .{
                    .g_dense = g,
                    .c_mat = c,
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
                    allocator.free(d.a_lu);
                    allocator.free(d.piv);
                },
                .sp => |*s| {
                    if (comptime T == f64) if (s.lanes) |*l| l.deinit(allocator);
                    allocator.free(s.lane_work);
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

        /// Solve `omegas.len` frequency points against ONE shared `rhs`
        /// (length 2n — every caller today broadcasts an identical excitation;
        /// a per-lane variant appears when a caller needs it). `x_out` is
        /// flat, lane k at [k*2n..][0..2n]. `adjoint` selects A^T. Falls back
        /// to the per-omega scalar path for the dense strategy, f32, tiny
        /// systems, or any lane whose refactor failed (peeled to full
        /// re-factor).
        pub fn solveBatch(self: *Self, omegas: []const T, rhs: []const T, x_out: []T, adjoint: bool) !void {
            const nn: usize = self.nn;
            std.debug.assert(rhs.len >= nn);
            std.debug.assert(x_out.len == omegas.len * nn);
            if (omegas.len == 0) return;
            // Lane path is f64 + sparse only (LaneLu is f64; dense has no tape).
            const use_lanes = comptime (T == f64);
            const sp: *Sparse = switch (self.strategy) {
                .sp => |*s| s,
                .dense => return self.solveBatchSerial(omegas, rhs, x_out, adjoint),
            };
            if (!use_lanes) return self.solveBatchSerial(omegas, rhs, x_out, adjoint);

            const gpa = sp.slv.gpa;
            const LL = lane_lu.LaneLu(W);
            const nnz2 = sp.vals.len; // structural entries in the 2n CSC
            if (sp.lane_work.len == 0)
                sp.lane_work = try gpa.alloc(@Vector(W, T), nnz2 + 2 * nn);
            const vplane = sp.lane_work[0..nnz2];
            const b_plane = sp.lane_work[nnz2..][0..nn];
            const x_plane = sp.lane_work[nnz2 + nn ..];
            for (rhs[0..nn], b_plane) |value, *lane| lane.* = @splat(value);

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
                    try self.solveBatchSerial(omegas[base .. base + cnt], rhs, x_out[base * nn ..][0 .. cnt * nn], adjoint);
                    continue;
                };
                // LaneLu needs a SparseLu-backed factorization. If direct
                // dispatched to tridiag/BBD (no .lu), peel to serial.
                const lu = if (sp.slv.lu) |*l| l else {
                    try self.solveBatchSerial(omegas[base .. base + cnt], rhs, x_out[base * nn ..][0 .. cnt * nn], adjoint);
                    continue;
                };

                // A chunk whose refactor tripped the growth monitor re-runs a
                // FULL factor (direct.zig ladder), which repivots and can
                // change the tape lengths — so the lane planes are re-sized
                // when they no longer match, not just allocated once.
                if (sp.lanes) |*l| {
                    if (l.lx.len != lu.lx.items.len or l.ux.len != lu.ux.items.len) {
                        l.deinit(gpa);
                        sp.lanes = null;
                    }
                }
                if (sp.lanes == null) sp.lanes = try LL.init(gpa, lu);
                sp.lanes.?.base = lu;

                fillLanePlane(self.n, sp, omega_vec, vplane);
                const growth: T = @floatCast(sp.slv.params.refactor_growth_limit);
                const bad = sp.lanes.?.refactor(sp.col_ptr, vplane, growth);

                if (adjoint) sp.lanes.?.solveT(b_plane, x_plane) else sp.lanes.?.solve(b_plane, x_plane);

                // Deinterleave good lanes into x_out; peel bad lanes to serial.
                for (0..cnt) |l| {
                    if ((bad & (@as(u64, 1) << @intCast(l))) != 0) {
                        try self.solveBatchSerial(omegas[base + l ..][0..1], rhs, x_out[(base + l) * nn ..][0..nn], adjoint);
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

        /// Reference path: loop setOmega + solveRhs per omega against the one
        /// shared rhs. The lane path must match this bit-for-bit when op
        /// orders agree (they do: LaneLu lane l replays the same SparseLu
        /// numeric sequence as this scalar factor of the same values).
        pub const test_access = if (@import("builtin").is_test) .{ .solveBatchSerial = solveBatchSerial } else {};

        fn solveBatchSerial(self: *Self, omegas: []const T, rhs: []const T, x_out: []T, adjoint: bool) !void {
            const nn: usize = self.nn;
            for (omegas, 0..) |omega, k| {
                try self.setOmega(omega);
                if (adjoint)
                    try self.solveRhsT(rhs[0..nn], x_out[k * nn ..][0..nn])
                else
                    try self.solveRhs(rhs[0..nn], x_out[k * nn ..][0..nn]);
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
            DL.buildComplexAdmittance(n, nn, d.g_dense, d.c_mat, omega, d.a_lu);
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
                @memcpy(s.vals[p..][0..lenu], s.g_vals[cs..][0..lenu]);
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
                @memcpy(s.vals[p..][0..lenu], s.g_vals[cs..][0..lenu]);
                p += lenu;
            }

            try s.slv.factor(s.vals);
        }
    };
}

pub const FreqSolver = FreqSolverT(f64);

/// Build the stacked-real 2n×2n CSC pattern from the n×n circuit pattern.
/// Column j (j < n): G-rows then C-rows+n.
/// Column j+n: -wC-rows then G-rows+n.
pub inline fn buildStackedRealPattern(
    n: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    sr_col_ptr: []u32,
    sr_row_idx: []u32,
) void {
    const nu: usize = n;
    var p: u32 = 0;
    sr_col_ptr[0] = 0;

    // ponytail: both halves share the row pattern; only the value fill differs.
    for (0..2) |half| {
        for (0..nu) |j| {
            const s = col_ptr[j];
            const e = col_ptr[j + 1];
            for (row_idx[s..e]) |r| {
                sr_row_idx[p] = r;
                p += 1;
            }
            for (row_idx[s..e]) |r| {
                sr_row_idx[p] = r + n;
                p += 1;
            }
            sr_col_ptr[half * nu + j + 1] = p;
        }
    }
}

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

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .scaleCopy = scaleCopy,
} else {};
