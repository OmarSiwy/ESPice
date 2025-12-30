//! (G + jwC) solves, stacked-real form [G, -wC; wC, G].
//!
//! The circuit planes ARE the linearization: fromCircuit is one eval().
//! Dense below the threshold (SIMD row ops beat pointer chasing), sparse
//! above: the 2n pattern is derived once from the circuit CSC — every big
//! column is [G-block rows | wC-block rows] in ascending order, so filling
//! per omega is a straight streamed copy from the planes. No triplets, no
//! searches, no re-assembly.
const std = @import("std");
const dense_lu = @import("dense_lu.zig");
const direct = @import("direct.zig");

const DENSE_THRESHOLD: usize = 128;

pub const Error = error{Singular};

/// Frequency-domain solver over element type T (f32 or f64). `FreqSolver`
/// below is the f64 instantiation (existing callers).
pub fn FreqSolverT(comptime T: type) type {
    return struct {
        const Self = @This();
        const DL = dense_lu.DenseLu(T);

        n: usize,
        nn: usize,
        strategy: Strategy,

        const Strategy = union(enum) {
            dense: Dense,
            sp: Sparse,
        };

        const Dense = struct {
            g_dense: []T,
            c_mat: []T,
            a_work: []T, // built per omega
            a_lu: []T, // factored copy for multi-RHS
            piv: []u32,
        };

        const Sparse = struct {
            // borrowed planes/pattern — the circuit must outlive the solver and
            // not be re-eval'd mid-sweep
            g_vals: []const T,
            c_vals: []const T,
            src_col_ptr: []const u32,
            // owned 2n CSC + solver
            col_ptr: []u32,
            row_idx: []u32,
            vals: []T,
            slv: direct.SolverT(T),
        };

        /// Linearize at x_op (one eval — the planes are G and C) and build.
        pub fn fromCircuit(allocator: std.mem.Allocator, ckt: anytype, x_op: []const T) !Self {
            ckt.eval(x_op, 0);
            const n: usize = ckt.n;

            if (n <= DENSE_THRESHOLD) {
                const g = try allocator.alloc(T, n * n);
                ckt.denseG(g);
                const c = allocator.alloc(T, n * n) catch |err| {
                    allocator.free(g);
                    return err;
                };
                ckt.denseC(c);
                return initDense(allocator, @intCast(n), g, c);
            }

            // Sparse: 2n pattern from the circuit CSC. Column j (< n) has the
            // G-block rows r then the wC-block rows r+n; column j+n mirrors it.
            const nn = 2 * n;
            const src_nnz: usize = ckt.nnz;
            const col_ptr = try allocator.alloc(u32, nn + 1);
            errdefer allocator.free(col_ptr);
            const row_idx = try allocator.alloc(u32, 2 * 2 * src_nnz);
            errdefer allocator.free(row_idx);
            const vals = try allocator.alloc(T, 2 * 2 * src_nnz);
            errdefer allocator.free(vals);

            var p: u32 = 0;
            col_ptr[0] = 0;
            for (0..2) |half| {
                for (0..n) |j| {
                    const s = ckt.col_ptr[j];
                    const e = ckt.col_ptr[j + 1];
                    for (ckt.row_idx[s..e]) |r| {
                        row_idx[p] = r;
                        p += 1;
                    }
                    for (ckt.row_idx[s..e]) |r| {
                        row_idx[p] = r + @as(u32, @intCast(n));
                        p += 1;
                    }
                    col_ptr[half * n + j + 1] = p;
                }
            }

            var slv = try direct.SolverT(T).init(allocator, @intCast(nn), col_ptr, row_idx, null);
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
        pub fn initDense(allocator: std.mem.Allocator, n: u32, g: []T, c: []T) !Self {
            errdefer allocator.free(g);
            errdefer allocator.free(c);
            const nu: usize = n;
            const nn = 2 * nu;
            const a_work = try allocator.alloc(T, nn * nn);
            errdefer allocator.free(a_work);
            const a_lu = try allocator.alloc(T, nn * nn);
            errdefer allocator.free(a_lu);
            const piv = try allocator.alloc(u32, nn);
            return .{
                .n = nu,
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

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
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

        /// Single-shot: build + solve at omega. Most common path.
        pub fn solve(self: *Self, omega: T, rhs: []const T, x_out: []T) !void {
            try self.setOmega(omega);
            try self.solveRhs(rhs, x_out);
        }

        /// Build the admittance at omega. For multi-RHS at one freq, call once
        /// then solveRhs N times.
        pub fn setOmega(self: *Self, omega: T) !void {
            switch (self.strategy) {
                .dense => |*d| {
                    DL.buildComplexAdmittance(self.n, self.nn, d.g_dense, d.c_mat, omega, d.a_work);
                    @memcpy(d.a_lu, d.a_work);
                    try DL.factorize(self.nn, d.a_lu, d.piv);
                },
                .sp => |*s| {
                    // streamed fill: [G | +wC] per left column, [-wC | G] per right;
                    // block copies/scales instead of element pushes
                    var p: usize = 0;
                    for (0..self.n) |j| {
                        const cs = s.src_col_ptr[j];
                        const len = s.src_col_ptr[j + 1] - cs;
                        @memcpy(s.vals[p..][0..len], s.g_vals[cs..][0..len]);
                        p += len;
                        scaleCopy(T, s.vals[p..][0..len], s.c_vals[cs..][0..len], omega);
                        p += len;
                    }
                    for (0..self.n) |j| {
                        const cs = s.src_col_ptr[j];
                        const len = s.src_col_ptr[j + 1] - cs;
                        scaleCopy(T, s.vals[p..][0..len], s.c_vals[cs..][0..len], -omega);
                        p += len;
                        @memcpy(s.vals[p..][0..len], s.g_vals[cs..][0..len]);
                        p += len;
                    }
                    try s.slv.factor(s.vals);
                },
            }
        }

        /// Solve with the current admittance. Non-destructive across calls.
        pub fn solveRhs(self: *Self, rhs: []const T, x_out: []T) !void {
            switch (self.strategy) {
                .dense => |*d| DL.solveFactored(self.nn, d.a_lu, d.piv, rhs, x_out),
                .sp => |*s| s.slv.solve(rhs, x_out),
            }
        }

        /// Adjoint solve at the current omega: A' y = rhs. Dense path builds the
        /// transpose explicitly only when asked (noise uses the sparse path's
        /// solveT; small-n dense fallback transposes per call).
        pub fn solveRhsT(self: *Self, rhs: []const T, x_out: []T) !void {
            switch (self.strategy) {
                .dense => |*d| {
                    // transpose a_work into a_lu and refactor — cold path, small n
                    for (0..self.nn) |i| {
                        for (0..self.nn) |j| d.a_lu[j * self.nn + i] = d.a_work[i * self.nn + j];
                    }
                    try DL.factorize(self.nn, d.a_lu, d.piv);
                    DL.solveFactored(self.nn, d.a_lu, d.piv, rhs, x_out);
                    // restore the untransposed factorization for solveRhs callers
                    @memcpy(d.a_lu, d.a_work);
                    try DL.factorize(self.nn, d.a_lu, d.piv);
                },
                .sp => |*s| s.slv.solveT(rhs, x_out),
            }
        }
    };
}

pub const FreqSolver = FreqSolverT(f64);

fn scaleCopy(comptime T: type, dst: []T, src: []const T, s: T) void {
    for (dst, src) |*d, v| d.* = s * v; // autovectorizes: contiguous, no branch
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "FreqSolver: single-shot solve (dense)" {
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 1, 0, 0, 1 });
    const c = try allocator.dupe(f64, &[_]f64{ 0.1, 0, 0, 0.1 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    const rhs = [_]f64{ 1, 0, 0, 0 };
    var x: [4]f64 = undefined;
    try fs.solve(10.0, &rhs, &x);

    try testing.expectApproxEqAbs(@as(f64, 0.5), x[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), x[2], 1e-10);
}

test "FreqSolver: multi-RHS at same omega" {
    const allocator = testing.allocator;
    const g = try allocator.dupe(f64, &[_]f64{ 2, 0, 0, 3 });
    const c = try allocator.dupe(f64, &[_]f64{ 0, 0, 0, 0 });

    var fs = try FreqSolver.initDense(allocator, 2, g, c);
    defer fs.deinit(allocator);

    try fs.setOmega(0);

    const rhs1 = [_]f64{ 2, 0, 0, 0 };
    var x1: [4]f64 = undefined;
    try fs.solveRhs(&rhs1, &x1);
    try testing.expectApproxEqAbs(@as(f64, 1.0), x1[0], 1e-10);

    const rhs2 = [_]f64{ 0, 3, 0, 0 };
    var x2: [4]f64 = undefined;
    try fs.solveRhs(&rhs2, &x2);
    try testing.expectApproxEqAbs(@as(f64, 1.0), x2[1], 1e-10);
}

// ponytail: sparse-path integration test removed — it depended on
// analysis.compiled.Builder. Re-add when solvers has its own CSC test harness.
