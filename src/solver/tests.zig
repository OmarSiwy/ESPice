//! Solver unit tests: kernels against dense references, and every SIMD or
//! tape kernel against its scalar oracle, bitwise.

const std = @import("std");
const testing = std.testing;

/// Dense-to-CSC converter for tests.
fn DenseCsc(comptime n: usize) type {
    return struct {
        col_ptr: [n + 1]u32,
        row_idx: [n * n]u32,
        vals: [n * n]f64,

        fn from(a: [n][n]f64) @This() {
            var s: @This() = undefined;
            var m: u32 = 0;
            s.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    if (a[i][j] != 0) {
                        s.row_idx[m] = @intCast(i);
                        s.vals[m] = a[i][j];
                        m += 1;
                    }
                }
                s.col_ptr[j + 1] = m;
            }
            return s;
        }

        fn nnz(s: *const @This()) u32 {
            return s.col_ptr[n];
        }
    };
}

/// Dense Gaussian elimination reference solver for verification.
fn denseSolve(comptime n: usize, a_in: [n][n]f64, b_in: [n]f64) [n]f64 {
    var a = a_in;
    var b = b_in;
    for (0..n) |k| {
        var piv = k;
        for (k + 1..n) |i| {
            if (@abs(a[i][k]) > @abs(a[piv][k])) piv = i;
        }
        std.mem.swap([n]f64, &a[k], &a[piv]);
        std.mem.swap(f64, &b[k], &b[piv]);
        for (k + 1..n) |i| {
            const f = a[i][k] / a[k][k];
            for (k..n) |j| a[i][j] -= f * a[k][j];
            b[i] -= f * b[k];
        }
    }
    var x: [n]f64 = undefined;
    var k = n;
    while (k > 0) {
        k -= 1;
        var s = b[k];
        for (k + 1..n) |j| s -= a[k][j] * x[j];
        x[k] = s / a[k][k];
    }
    return x;
}

fn identity(comptime n: usize) [n]u32 {
    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);
    return q;
}

fn checkSolve(comptime n: usize, a: [n][n]f64, b: [n]f64, lu: *@import("root.zig").sparse_lu.SparseLu) !void {
    var x: [n]f64 = undefined;
    lu.solve(&b, &x);
    const xref = denseSolve(n, a, b);
    for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
}

const BbdTests = struct {
    const impl = @import("root.zig").bbd;
    const Allocator = std.mem.Allocator;
    const Bbd = impl.Bbd;
    const Limits = impl.Limits;
    const root = @import("core").numerics;

    const direct = @import("root.zig").direct;

    /// Synthetic BBD system: ground node 0, `nb` blocks of size `s`, `ncpl`
    /// coupling nodes at the end. Deterministic values from a seeded PRNG;
    /// diagonally dominant so both paths factor without drama.
    const Synth = struct {
        n: u32,
        dense: []f64,
        col_ptr: []u32,
        row_idx: []u32,
        vals: []f64,
        info: root.BbdInfo,

        fn build(
            gpa: Allocator,
            nb: u32,
            s: u32,
            ncpl: u32,
            seed: u64,
            opts: struct {
                decoupled_block: ?u32 = null, // this block gets no E/F entries (m=0)
                singular_block: ?u32 = null, // this block's A_i is rank-deficient
                cross_entry: bool = false, // add a block-1 <-> block-0 entry
            },
        ) !Synth {
            const n = 1 + nb * s + ncpl;
            const dense = try gpa.alloc(f64, @as(usize, n) * n);
            @memset(dense, 0);
            var prng = std.Random.DefaultPrng.init(seed);
            const rnd = prng.random();

            dense[0] = 1.0; // ground diagonal (gmin'd)
            const cs = 1 + nb * s; // coupling_start
            const blocks = try gpa.alloc(root.BbdBlock, nb);
            for (0..nb) |bi| {
                const st = 1 + @as(u32, @intCast(bi)) * s;
                blocks[bi] = .{ .start = st, .size = s };
                // block interior: dense-ish, diagonally dominant
                for (0..s) |i| {
                    for (0..s) |j| {
                        const v = rnd.float(f64) - 0.5;
                        dense[(st + i) * n + (st + j)] = if (i == j) v + @as(f64, @floatFromInt(s)) + 2 else v;
                    }
                }
                if (opts.singular_block) |sb| {
                    if (sb == bi and s >= 2) {
                        // rows 0 and 1 identical -> A_i singular (full matrix
                        // stays regular through the border coupling)
                        for (0..s) |j| dense[(st + 1) * n + (st + j)] = dense[(st + 0) * n + (st + j)];
                    }
                }
                if (opts.decoupled_block != null and opts.decoupled_block.? == bi) continue;
                if (ncpl > 0) {
                    // asymmetric E/F so solveT is a real test
                    for (0..s) |k| {
                        const cp = cs + @as(u32, @intCast(k % ncpl));
                        dense[(st + k) * n + cp] = 0.25 * (rnd.float(f64) - 0.5); // E
                        dense[cp * n + (st + k)] = 0.25 * (rnd.float(f64) - 0.5); // F
                    }
                }
            }
            // border-border: dominant diagonal + a few off-diagonals
            for (0..ncpl) |i| {
                dense[(cs + i) * n + (cs + i)] = 4 + rnd.float(f64);
                if (i + 1 < ncpl) dense[(cs + i) * n + (cs + i + 1)] = 0.3 * (rnd.float(f64) - 0.5);
            }
            if (opts.cross_entry and nb >= 2) {
                dense[blocks[1].start * n + blocks[0].start] = 0.1;
            }

            var self = Synth{
                .n = n,
                .dense = dense,
                .col_ptr = undefined,
                .row_idx = undefined,
                .vals = undefined,
                .info = .{ .blocks = blocks, .coupling_start = cs, .coupling_size = ncpl },
            };
            // dense -> CSC
            var nnz: usize = 0;
            for (dense) |v| nnz += @intFromBool(v != 0);
            self.col_ptr = try gpa.alloc(u32, n + 1);
            self.row_idx = try gpa.alloc(u32, nnz);
            self.vals = try gpa.alloc(f64, nnz);
            var p: u32 = 0;
            self.col_ptr[0] = 0;
            for (0..n) |j| {
                for (0..n) |i| {
                    const v = dense[i * n + j];
                    if (v != 0) {
                        self.row_idx[p] = @intCast(i);
                        self.vals[p] = v;
                        p += 1;
                    }
                }
                self.col_ptr[j + 1] = p;
            }
            return self;
        }

        fn free(self: *Synth, gpa: Allocator) void {
            gpa.free(self.dense);
            gpa.free(self.col_ptr);
            gpa.free(self.row_idx);
            gpa.free(self.vals);
            gpa.free(self.info.blocks);
        }

        fn rhs(self: *const Synth, gpa: Allocator) ![]f64 {
            const r = try gpa.alloc(f64, self.n);
            for (r, 0..) |*ri, i| ri.* = @as(f64, @floatFromInt(i % 7)) - 3.0;
            return r;
        }
    };

    const relaxed = Limits{ .min_blocks = 2 };

    fn expectMatchesFlat(gpa: Allocator, sy: *const Synth, eng: *Bbd) !void {
        var flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
        defer flat.deinit();
        try flat.factor(sy.vals, .{});
        try eng.factorWithExecution(sy.vals, .{});

        const b_rhs = try sy.rhs(gpa);
        defer gpa.free(b_rhs);
        const x_ref = try gpa.alloc(f64, sy.n);
        defer gpa.free(x_ref);
        const x = try gpa.alloc(f64, sy.n);
        defer gpa.free(x);

        flat.solve(b_rhs, x_ref);
        @memcpy(x, b_rhs);
        eng.solveInPlace(x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

        flat.solveT(b_rhs, x_ref);
        @memcpy(x, b_rhs);
        eng.solveTInPlace(x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
    }

    test "bbd: 3-block + border matches flat LU (solve + solveT)" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 42, .{});
        defer sy.free(gpa);
        var eng = try Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try expectMatchesFlat(gpa, &sy, &eng);
    }

    test "bbd: block with empty border footprint (m_i = 0)" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 7, .{ .decoupled_block = 1 });
        defer sy.free(gpa);
        var eng = try Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try testing.expectEqual(@as(u32, 0), eng.blk_m[1]);
        try expectMatchesFlat(gpa, &sy, &eng);
    }

    test "bbd: b = 1 (ground-only border, fully decoupled blocks)" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 4, 3, 0, 11, .{});
        defer sy.free(gpa);
        var eng = try Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try testing.expectEqual(@as(u32, 1), eng.b);
        try expectMatchesFlat(gpa, &sy, &eng);
    }

    test "bbd: singular block reports SingularMatrix from factor" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 13, .{ .singular_block = 1 });
        defer sy.free(gpa);
        var eng = try Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try testing.expectError(error.SingularMatrix, eng.factorWithExecution(sy.vals, .{}));
    }

    test "bbd: cross-block entry -> NotApplicable" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 17, .{ .cross_entry = true });
        defer sy.free(gpa);
        try testing.expectError(
            error.NotApplicable,
            Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed),
        );
    }

    test "bbd: production limits reject small block counts" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 19, .{});
        defer sy.free(gpa);
        try testing.expectError(
            error.NotApplicable,
            Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, .{}),
        );
    }

    test "bbd: std.Io block factors, failures and recovery match serial bitwise" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 17, 32, 3, 23, .{});
        defer sy.free(gpa);
        var eng = try Bbd.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();

        try eng.factorWithExecution(sy.vals, .{});
        const snap_arena = try gpa.dupe(f64, eng.arena);
        defer gpa.free(snap_arena);
        const snap_piv = try gpa.dupe(u32, eng.piv);
        defer gpa.free(snap_piv);
        const snap_spiv = try gpa.dupe(u32, eng.s_piv);
        defer gpa.free(snap_spiv);

        const rhs = try sy.rhs(gpa);
        defer gpa.free(rhs);
        const expected = try gpa.dupe(f64, rhs);
        defer gpa.free(expected);
        const actual = try gpa.dupe(f64, rhs);
        defer gpa.free(actual);
        const bad = try gpa.dupe(f64, sy.vals);
        defer gpa.free(bad);
        for ([_]std.Io.Limit{ .nothing, .limited(4) }) |limit| {
            var threaded = std.Io.Threaded.init(gpa, .{ .async_limit = limit });
            defer threaded.deinit();
            const execution: root.Execution = .{ .io = threaded.io(), .threads = 16 };
            try eng.factorWithExecution(sy.vals, execution);
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(snap_arena), std.mem.sliceAsBytes(eng.arena));
            try testing.expectEqualSlices(u32, snap_piv, eng.piv);
            try testing.expectEqualSlices(u32, snap_spiv, eng.s_piv);
            inline for (.{ false, true }) |transpose| {
                @memcpy(expected, rhs);
                @memcpy(actual, rhs);
                if (transpose) eng.solveTInPlace(actual) else eng.solveInPlace(actual);
                try eng.factorWithExecution(sy.vals, .{});
                if (transpose) eng.solveTInPlace(expected) else eng.solveInPlace(expected);
                try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(actual));
                try eng.factorWithExecution(sy.vals, execution);
            }
            for ([_]usize{ 0, 16 }) |bi| {
                @memcpy(bad, sy.vals);
                const off = eng.blk_a_off[bi];
                for (bad, eng.dst) |*v, d| if (d >= off and d < off + 32 * 32) {
                    v.* = 0;
                };
                try testing.expectError(error.SingularMatrix, eng.factorWithExecution(bad, execution));
                try eng.factorWithExecution(sy.vals, execution);
                try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(snap_arena), std.mem.sliceAsBytes(eng.arena));
            }
        }
    }

    test "bbd: facade activates BBD at >= 8 blocks and matches flat" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 8, 5, 4, 29, .{});
        defer sy.free(gpa);

        var s_bbd = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info);
        defer s_bbd.deinit();
        try testing.expect(s_bbd.bbd_eng != null);
        var s_flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
        defer s_flat.deinit();

        try s_bbd.factor(sy.vals, .{});
        try s_flat.factor(sy.vals, .{});

        const b_rhs = try sy.rhs(gpa);
        defer gpa.free(b_rhs);
        const x = try gpa.alloc(f64, sy.n);
        defer gpa.free(x);
        const x_ref = try gpa.alloc(f64, sy.n);
        defer gpa.free(x_ref);

        s_flat.solve(b_rhs, x_ref);
        s_bbd.solve(b_rhs, x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

        s_flat.solveNeg(b_rhs, x_ref);
        s_bbd.solveNeg(b_rhs, x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

        s_flat.solveT(b_rhs, x_ref);
        s_bbd.solveT(b_rhs, x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
    }

    test "bbd: facade falls back to flat permanently on a singular block" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 8, 5, 4, 31, .{ .singular_block = 2 });
        defer sy.free(gpa);

        var s = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info);
        defer s.deinit();
        try testing.expect(s.bbd_eng != null);

        // block 2 singular but the full matrix is regular through the border:
        // factor must succeed via the flat fallback
        try s.factor(sy.vals, .{});
        try testing.expect(s.bbd_eng == null);
        try testing.expect(s.lu != null);

        var flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
        defer flat.deinit();
        try flat.factor(sy.vals, .{});

        const b_rhs = try sy.rhs(gpa);
        defer gpa.free(b_rhs);
        const x = try gpa.alloc(f64, sy.n);
        defer gpa.free(x);
        const x_ref = try gpa.alloc(f64, sy.n);
        defer gpa.free(x_ref);
        flat.solve(b_rhs, x_ref);
        s.solve(b_rhs, x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);

        // second factor stays flat (refactor path) and still works
        try s.factor(sy.vals, .{});
        try testing.expect(s.bbd_eng == null);
        s.solve(b_rhs, x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
    }
};

const ConvergerTests = struct {
    const impl = @import("root.zig").converger;
    const Workspace = impl.Workspace;
    const jfnk = impl.jfnk;
    const newton = impl.newton;

    /// Scalar oracle for converger.updateAndNorm (the pre-vector loop).
    fn updateAndNormOracle(x: []f64, dx: []const f64, x_old: []f64, cur: []const bool, reltol: f64, abstol: f64, vntol: f64) f64 {
        var worst: f64 = 0;
        for (x, dx, x_old, cur) |*xi, dxi, *xoi, is_cur| {
            xoi.* = xi.*;
            xi.* += dxi;
            const atol = if (is_cur) abstol else vntol;
            const tol = reltol * @max(@abs(xi.*), @abs(xoi.*)) + atol;
            worst = @max(worst, @abs(dxi) / tol);
        }
        return worst;
    }

    test "updateAndNorm: vector body and tail match the scalar oracle bitwise" {
        const kernel = impl.test_access.updateAndNorm;
        var prng = std.Random.DefaultPrng.init(0xC0FFEE);
        const rand = prng.random();
        const specials = [_]f64{ 0, -0.0, std.math.nan(f64), std.math.inf(f64), 1e-300, -1e300 };
        var xa: [64]f64 = undefined;
        var xb: [64]f64 = undefined;
        var dx: [64]f64 = undefined;
        var oa: [64]f64 = undefined;
        var ob: [64]f64 = undefined;
        var cur: [64]bool = undefined;
        // Every length through several vector widths plus a tail, so each
        // boundary and the empty case run.
        for (0..40) |len| for (0..50) |trial| {
            for (0..len) |i| {
                xa[i] = (rand.float(f64) - 0.5) * std.math.pow(f64, 10, @floatFromInt(rand.intRangeAtMost(i32, -9, 3)));
                dx[i] = (rand.float(f64) - 0.5) * 1e-3;
                cur[i] = rand.boolean();
                if (trial % 7 == 0 and rand.boolean()) dx[i] = specials[rand.uintLessThan(usize, specials.len)];
                if (trial % 11 == 0 and rand.boolean()) xa[i] = specials[rand.uintLessThan(usize, specials.len)];
            }
            @memcpy(xb[0..len], xa[0..len]);
            const want = updateAndNormOracle(xa[0..len], dx[0..len], oa[0..len], cur[0..len], 1e-3, 1e-12, 1e-6);
            const got = kernel(xb[0..len], dx[0..len], ob[0..len], cur[0..len], 1e-3, 1e-12, 1e-6);
            try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
            for (0..len) |i| {
                try testing.expectEqual(@as(u64, @bitCast(xa[i])), @as(u64, @bitCast(xb[i])));
                try testing.expectEqual(@as(u64, @bitCast(oa[i])), @as(u64, @bitCast(ob[i])));
            }
        };
    }

    // One equation with a device veto through iteration two. This exercises both
    // nonzero Newton corrections and JFNK's zero-residual exit without model physics.
    const IterationSystem = struct {
        n: u32 = 1,
        nnz: u32 = 1,
        diag_slots: [1]u32 = .{0},
        current_row: []const bool = &.{false},
        rhs: []f64,
        g_vals: [1]f64 = .{1},
        target: f64,
        slope: f64 = 1,
        iteration: u16 = 0,
        advances: u16 = 0,
        staged: u16 = 0,
        previous: [32]f64 = @splat(0),

        pub fn beginSolve(self: *@This()) void {
            self.iteration = 1;
            self.advances = 0;
            self.staged = 0;
        }
        pub fn advanceIteration(self: *@This(), previous_x: []const f64) void {
            self.previous[self.advances] = previous_x[0];
            self.advances += 1;
            self.iteration += 1;
        }
        pub fn checkConvergence(self: *@This(), x: []const f64) bool {
            return self.iteration >= 3 and @abs(x[0] - self.target) < 1e-8;
        }
        pub fn updateStates(self: *@This(), _: []const f64) ?f64 {
            self.staged += 1;
            return null;
        }

        const Hook = struct {
            pub fn assemble(_: @This(), sys: *IterationSystem, x: []const f64, _: f64) void {
                sys.rhs[0] = sys.slope * (x[0] - sys.target);
                sys.g_vals[0] = sys.slope;
            }
            pub fn vals(_: @This(), sys: *IterationSystem) []f64 {
                return &sys.g_vals;
            }
            pub fn diagAt(_: @This(), sys: *IterationSystem, slot: u32) f64 {
                return sys.g_vals[slot];
            }
        };
    };

    test "Newton lifecycle: veto, zero residual, repeated solve and no finite-difference history" {
        const a = std.testing.allocator;
        inline for (.{ newton, jfnk }) |solve| {
            for ([_]f64{ 0, 2 }) |target| {
                var rhs = [_]f64{0};
                var sys: IterationSystem = .{ .target = target, .rhs = &rhs };
                var ws = try Workspace.init(a, 1, &.{ 0, 1 }, &.{0}, null);
                defer ws.deinit(a);
                for (0..2) |_| {
                    var x = [_]f64{0};
                    const result = try solve(&sys, &ws, &x, 0, .{ .gmin = 0, .max_iter = 32 }, IterationSystem.Hook{});
                    try std.testing.expect(result.converged);
                    try std.testing.expectEqual(@as(u16, 3), result.iterations);
                    try std.testing.expectEqual(@as(u16, 2), sys.advances);
                    try std.testing.expectEqual(@as(u16, 1), sys.staged);
                    try std.testing.expectEqual(@as(f64, 0), sys.previous[0]);
                    try std.testing.expectApproxEqAbs(target, sys.previous[1], 1e-8);
                    try std.testing.expectApproxEqAbs(target, x[0], 1e-8);
                }
                var x = [_]f64{0};
                const refused = try solve(&sys, &ws, &x, 0, .{ .gmin = 0, .max_iter = 2 }, IterationSystem.Hook{});
                try std.testing.expect(!refused.converged);
                try std.testing.expectEqual(@as(u16, 1), sys.advances);
                try std.testing.expectEqual(@as(u16, 0), sys.staged);
            }
        }
    }

    test "JFNK: a small preconditioned residual must pass the equation residual gate" {
        const a = std.testing.allocator;
        var rhs = [_]f64{0};
        var sys: IterationSystem = .{ .target = 1e-14, .slope = 1e16, .rhs = &rhs };
        var ws = try Workspace.init(a, 1, &.{ 0, 1 }, &.{0}, null);
        defer ws.deinit(a);
        var x = [_]f64{0};
        const result = try jfnk(&sys, &ws, &x, 0, .{
            .gmin = 0,
            .max_iter = 32,
            .reltol = 0,
            .vntol = 1e-20,
            .residual_tol = 1e-20,
        }, IterationSystem.Hook{});
        try std.testing.expect(result.converged);
        try std.testing.expectApproxEqAbs(sys.target, x[0], 1e-20);
        try std.testing.expect(@abs(sys.slope * (x[0] - sys.target)) < 1e-3);
    }

    /// `Eamp out 0 in out 1e9` in two unknowns: a KCL node row and a
    /// voltage-DEFINED branch row whose own diagonal is a structural zero.
    /// Row 1 is `(1+A)·v_out = A·vin`; at A = 1e9 the EXACT solution still
    /// leaves ~A·eps ≈ 3e-8 of cancellation in that residual, so a gate that
    /// falls back to the absolute `residual_tol` floor when it finds no
    /// diagonal refuses a 14-digit answer forever
    /// (convergence/negative_feedback_1000000000 → OpDidNotConverge).
    const GainRowSystem = struct {
        const gain = 1e9;
        const g_load = 1e-3;
        const vin = 1.0;

        n: u32 = 2,
        nnz: u32 = 4,
        // CSC {(0,0),(1,0),(0,1),(1,1)}; slot 3 is row 1's diagonal, always 0.
        diag_slots: [2]u32 = .{ 0, 3 },
        current_row: []const bool = &.{ false, true },
        rhs: []f64,
        g_vals: [4]f64 = @splat(0),

        const Hook = struct {
            pub fn assemble(_: @This(), sys: *GainRowSystem, x: []const f64, _: f64) void {
                sys.rhs[0] = g_load * x[0] + x[1];
                sys.rhs[1] = (1.0 + gain) * x[0] - gain * vin;
                sys.g_vals = .{ g_load, 1.0 + gain, 1.0, 0.0 };
            }
            pub fn vals(_: @This(), sys: *GainRowSystem) []f64 {
                return &sys.g_vals;
            }
            pub fn diagAt(_: @This(), sys: *GainRowSystem, slot: u32) f64 {
                return sys.g_vals[slot];
            }
        };
    };

    /// F0 = x0 + x1 - 3, F1 = x0^2 + x1^2 - 5: roots (2, 1) and (1, 2).
    const CircleSystem = struct {
        n: u32 = 2,
        nnz: u32 = 4,
        diag_slots: [2]u32 = .{ 0, 3 },
        current_row: []const bool = &.{ true, true },
        rhs: []f64,
        g_vals: [4]f64 = @splat(0),

        const Hook = struct {
            pub fn assemble(_: @This(), sys: *CircleSystem, x: []const f64, _: f64) void {
                sys.rhs[0] = x[0] + x[1] - 3.0;
                sys.rhs[1] = x[0] * x[0] + x[1] * x[1] - 5.0;
                sys.g_vals = .{ 1, 2 * x[0], 1, 2 * x[1] };
            }
            pub fn vals(_: @This(), sys: *CircleSystem) []f64 {
                return &sys.g_vals;
            }
            pub fn diagAt(_: @This(), sys: *CircleSystem, slot: u32) f64 {
                return sys.g_vals[slot];
            }
        };
    };

    test "JFNK: converges on a nonlinear 2x2 system, refuses under a 1-iteration cap" {
        const a = std.testing.allocator;
        var rhs = [_]f64{ 0, 0 };
        var sys: CircleSystem = .{ .rhs = &rhs };
        var ws = try Workspace.init(a, 2, &.{ 0, 2, 4 }, &.{ 0, 1, 0, 1 }, null);
        defer ws.deinit(a);
        var x = [_]f64{ 3, 3 };
        const r = try jfnk(&sys, &ws, &x, 0, .{ .gmin = 0 }, CircleSystem.Hook{});
        try testing.expect(r.converged);
        try testing.expectApproxEqAbs(@as(f64, 2), x[0], 1e-8);
        try testing.expectApproxEqAbs(@as(f64, 1), x[1], 1e-8);

        x = .{ 3, 3 };
        const capped = try jfnk(&sys, &ws, &x, 0, .{ .gmin = 0, .max_iter = 1 }, CircleSystem.Hook{});
        try testing.expect(!capped.converged);
    }

    test "residual gate: a branch row with no diagonal is not gated on an absolute floor" {
        const a = std.testing.allocator;
        const exact = GainRowSystem.gain * GainRowSystem.vin / (1.0 + GainRowSystem.gain);
        inline for (.{ newton, jfnk }) |solve| {
            var rhs = [_]f64{ 0, 0 };
            var sys: GainRowSystem = .{ .rhs = &rhs };
            var ws = try Workspace.init(a, 2, &.{ 0, 2, 4 }, &.{ 0, 1, 0, 1 }, null);
            defer ws.deinit(a);
            var x = [_]f64{ 0, 0 };
            const r = try solve(&sys, &ws, &x, 0, .{ .gmin = 0, .max_iter = 32 }, GainRowSystem.Hook{});
            try std.testing.expect(r.converged);
            try std.testing.expectApproxEqRel(exact, x[0], 1e-12);
            try std.testing.expectApproxEqRel(-GainRowSystem.g_load * exact, x[1], 1e-12);
        }
    }
};

const DenseLuTests = struct {
    const impl = @import("root.zig").dense_lu;
    const buildComplexAdmittance = impl.buildComplexAdmittance;
    const factorize = impl.factorize;
    const factorizeSolve = impl.factorizeSolve;
    const factorizeSolveNeg = impl.factorizeSolveNeg;
    const solveFactored = impl.solveFactored;
    const solveFactoredT = impl.solveFactoredT;

    test "dense_lu: factorizeSolve 3x3" {
        var a = [_]f64{
            2, 1, 0,
            0, 3, 1,
            1, 0, 4,
        };
        const b = [_]f64{ 5, 7, 10 };
        var x: [3]f64 = undefined;
        try factorizeSolve(3, &a, &b, &x);

        // Verify A*x = b with original matrix
        const orig = [_]f64{ 2, 1, 0, 0, 3, 1, 1, 0, 4 };
        for (0..3) |row| {
            var sum: f64 = 0;
            for (0..3) |col| sum += orig[row * 3 + col] * x[col];
            try testing.expectApproxEqAbs(b[row], sum, 1e-10);
        }
    }

    test "dense_lu: factorizeSolveNeg 3x3" {
        var a = [_]f64{
            2, 1, 0,
            0, 3, 1,
            1, 0, 4,
        };
        const b = [_]f64{ 5, 7, 10 };
        var x_neg: [3]f64 = undefined;
        try factorizeSolveNeg(3, &a, &b, &x_neg);

        // Solve with positive b for reference
        var a2 = [_]f64{ 2, 1, 0, 0, 3, 1, 1, 0, 4 };
        var x_pos: [3]f64 = undefined;
        try factorizeSolve(3, &a2, &b, &x_pos);

        // x_neg should be -x_pos
        for (0..3) |i| try testing.expectApproxEqAbs(-x_pos[i], x_neg[i], 1e-10);
    }

    test "dense_lu: singular matrix returns error" {
        var a = [_]f64{
            1, 2,
            2, 4,
        };
        const b = [_]f64{ 1, 2 };
        var x: [2]f64 = undefined;
        try testing.expectError(error.Singular, factorizeSolve(2, &a, &b, &x));

        var a2 = [_]f64{ 1, 2, 2, 4 };
        var piv: [2]u32 = undefined;
        try testing.expectError(error.Singular, factorize(2, &a2, &piv));
    }

    test "dense_lu: solveFactoredT solves A^T x = b (with pivoting, aliased)" {
        // Asymmetric matrix with a zero leading diagonal to force row swaps.
        const orig = [_]f64{
            0, 2, 1,
            3, 1, 0,
            1, 0, 4,
        };
        var lu = orig;
        var piv: [3]u32 = undefined;
        try factorize(3, &lu, &piv);

        var x = [_]f64{ 5, 7, 10 }; // aliased b/x
        solveFactoredT(3, &lu, &piv, &x, &x);

        // check A^T x = b
        const b = [_]f64{ 5, 7, 10 };
        for (0..3) |row| {
            var sum: f64 = 0;
            for (0..3) |col| sum += orig[col * 3 + row] * x[col];
            try testing.expectApproxEqAbs(b[row], sum, 1e-10);
        }
    }

    test "dense_lu: solveFactored aliased b/x matches non-aliased" {
        const orig = [_]f64{
            0, 2, 1,
            3, 1, 0,
            1, 0, 4,
        };
        var lu = orig;
        var piv: [3]u32 = undefined;
        try factorize(3, &lu, &piv);

        const b = [_]f64{ 5, 7, 10 };
        var x1: [3]f64 = undefined;
        solveFactored(3, &lu, &piv, &b, &x1);
        var x2 = b;
        solveFactored(3, &lu, &piv, &x2, &x2);
        for (x1, x2) |v1, v2| try testing.expectEqual(v1, v2);
    }

    test "dense_lu: factorize + solveFactored matches factorizeSolve" {
        const orig = [_]f64{
            4, 7, 2, 3,
            1, 3, 8, 2,
            5, 2, 1, 9,
            6, 4, 3, 1,
        };
        const b = [_]f64{ 1, 2, 3, 4 };
        const n: usize = 4;

        // Path 1: fused
        var a1 = orig;
        var x1: [n]f64 = undefined;
        try factorizeSolve(n, &a1, &b, &x1);

        // Path 2: separate factorize + solveFactored
        var a2 = orig;
        var piv: [n]u32 = undefined;
        try factorize(n, &a2, &piv);
        var x2: [n]f64 = undefined;
        solveFactored(n, &a2, &piv, &b, &x2);

        // Both must produce A*x = b
        for (0..n) |row| {
            var sum: f64 = 0;
            for (0..n) |col| sum += orig[row * n + col] * x1[col];
            try testing.expectApproxEqAbs(b[row], sum, 1e-10);
        }
        for (0..n) |row| {
            var sum: f64 = 0;
            for (0..n) |col| sum += orig[row * n + col] * x2[col];
            try testing.expectApproxEqAbs(b[row], sum, 1e-10);
        }
    }

    test "dense_lu: buildComplexAdmittance" {
        const g = [_]f64{ 1, 2, 3, 4 };
        const c = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
        var a: [16]f64 = undefined;
        buildComplexAdmittance(2, 4, &g, &c, 10.0, &a);

        // Top-left: G
        try testing.expectApproxEqAbs(@as(f64, 1.0), a[0 * 4 + 0], 1e-12); // g[0,0]
        try testing.expectApproxEqAbs(@as(f64, 2.0), a[0 * 4 + 1], 1e-12); // g[0,1]
        try testing.expectApproxEqAbs(@as(f64, 3.0), a[1 * 4 + 0], 1e-12); // g[1,0]
        try testing.expectApproxEqAbs(@as(f64, 4.0), a[1 * 4 + 1], 1e-12); // g[1,1]

        // Top-right: -omega*C
        try testing.expectApproxEqAbs(@as(f64, -1.0), a[0 * 4 + 2], 1e-12); // -10*0.1
        try testing.expectApproxEqAbs(@as(f64, -2.0), a[0 * 4 + 3], 1e-12); // -10*0.2
        try testing.expectApproxEqAbs(@as(f64, -3.0), a[1 * 4 + 2], 1e-12); // -10*0.3
        try testing.expectApproxEqAbs(@as(f64, -4.0), a[1 * 4 + 3], 1e-12); // -10*0.4

        // Bottom-left: omega*C
        try testing.expectApproxEqAbs(@as(f64, 1.0), a[2 * 4 + 0], 1e-12); // 10*0.1
        try testing.expectApproxEqAbs(@as(f64, 2.0), a[2 * 4 + 1], 1e-12); // 10*0.2
        try testing.expectApproxEqAbs(@as(f64, 3.0), a[3 * 4 + 0], 1e-12); // 10*0.3
        try testing.expectApproxEqAbs(@as(f64, 4.0), a[3 * 4 + 1], 1e-12); // 10*0.4

        // Bottom-right: G
        try testing.expectApproxEqAbs(@as(f64, 1.0), a[2 * 4 + 2], 1e-12); // g[0,0]
        try testing.expectApproxEqAbs(@as(f64, 2.0), a[2 * 4 + 3], 1e-12); // g[0,1]
        try testing.expectApproxEqAbs(@as(f64, 3.0), a[3 * 4 + 2], 1e-12); // g[1,0]
        try testing.expectApproxEqAbs(@as(f64, 4.0), a[3 * 4 + 3], 1e-12); // g[1,1]
    }

    /// Scalar oracle: unblocked right-looking elimination in the order the
    /// kernel promises (reciprocal-pivot multipliers, then `a -= l * u` per
    /// entry in increasing k). `x`, when given, rides along as the fused
    /// solve does. Returns false on a pivot below eps^2.
    fn luOracle(n: usize, a: []f64, piv: []u32, x: ?[]f64) bool {
        const tol = std.math.floatEps(f64) * std.math.floatEps(f64);
        for (0..n) |k| {
            var p = k;
            for (k + 1..n) |i| {
                if (@abs(a[i * n + k]) > @abs(a[p * n + k])) p = i;
            }
            piv[k] = @intCast(p);
            if (@abs(a[p * n + k]) < tol) return false;
            if (p != k) {
                for (0..n) |j| std.mem.swap(f64, &a[k * n + j], &a[p * n + j]);
                if (x) |xs| std.mem.swap(f64, &xs[k], &xs[p]);
            }
            const inv = 1.0 / a[k * n + k];
            for (k + 1..n) |i| {
                const f = a[i * n + k] * inv;
                a[i * n + k] = f;
                for (k + 1..n) |j| a[i * n + j] -= f * a[k * n + j];
                if (x) |xs| xs[i] -= f * xs[k];
            }
        }
        return true;
    }

    test "dense_lu: blocked elimination is bitwise the scalar oracle" {
        const gpa = testing.allocator;
        var prng = std.Random.DefaultPrng.init(0xB10C);
        const rand = prng.random();
        // Both sides of the blocked cut-in (40), ragged last panels, and a
        // size past several panels.
        for ([_]usize{ 39, 40, 41, 47, 48, 57, 64, 73, 130 }) |n| for (0..3) |trial| {
            const a0 = try gpa.alloc(f64, n * n);
            defer gpa.free(a0);
            for (a0) |*v| v.* = rand.float(f64) - 0.5;
            // trial 1: zero diagonal, every step must pivot off it;
            // trial 2: duplicate rows, singular partway through.
            if (trial == 1) for (0..n) |i| {
                a0[i * n + i] = 0;
            };
            if (trial == 2) @memcpy(a0[(n - 3) * n ..][0..n], a0[5 * n ..][0..n]);
            const b = try gpa.alloc(f64, n);
            defer gpa.free(b);
            for (b) |*v| v.* = rand.float(f64) - 0.5;

            const ao = try gpa.dupe(f64, a0);
            defer gpa.free(ao);
            const po = try gpa.alloc(u32, n);
            defer gpa.free(po);
            const ok = luOracle(n, ao, po, null);
            const ak = try gpa.dupe(f64, a0);
            defer gpa.free(ak);
            const pk = try gpa.alloc(u32, n);
            defer gpa.free(pk);
            if (factorize(n, ak, pk)) |_| {
                try testing.expect(ok);
                try testing.expectEqualSlices(u32, po, pk);
                try testing.expectEqualSlices(u64, @ptrCast(ao), @ptrCast(ak));
            } else |_| try testing.expect(!ok);

            // Fused solve: the oracle carries -b through, then back-substitutes.
            const xo = try gpa.alloc(f64, n);
            defer gpa.free(xo);
            for (xo, b) |*o, v| o.* = -v;
            @memcpy(ao, a0);
            const ok2 = luOracle(n, ao, po, xo);
            const xk = try gpa.alloc(f64, n);
            defer gpa.free(xk);
            @memcpy(ak, a0);
            if (factorizeSolveNeg(n, ak, b, xk)) |_| {
                try testing.expect(ok2);
                var i = n;
                while (i > 0) {
                    i -= 1;
                    var s = xo[i];
                    // backSubstitute's order: vector partial sums, then the tail.
                    const W = std.simd.suggestVectorLength(f64) orelse 1;
                    var acc: @Vector(W, f64) = @splat(0);
                    var j = i + 1;
                    while (j + W <= n) : (j += W) {
                        const av: @Vector(W, f64) = ao[i * n + j ..][0..W].*;
                        const xv: @Vector(W, f64) = xo[j..][0..W].*;
                        acc += av * xv;
                    }
                    s -= @reduce(.Add, acc);
                    while (j < n) : (j += 1) s -= ao[i * n + j] * xo[j];
                    xo[i] = s / ao[i * n + i];
                }
                try testing.expectEqualSlices(u64, @ptrCast(xo), @ptrCast(xk));
            } else |_| try testing.expect(!ok2);
        };
    }
};

const DirectTests = struct {
    const impl = @import("root.zig").direct;
    const Allocator = std.mem.Allocator;
    const Solver = impl.Solver;
    const sparse_lu = @import("root.zig").sparse_lu;

    test "solver construction releases storage on every allocation failure" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(gpa: Allocator) !void {
                var solver = try Solver.init(gpa, 4, &.{ 0, 2, 3, 4, 6 }, &.{ 0, 3, 1, 2, 0, 3 }, null);
                defer solver.deinit();
            }
        }.run, .{});
    }

    test "Solver: factor + solveNeg + refactor on fixed pattern" {
        const gpa = testing.allocator;
        var csc = DenseCsc(2).from(.{ .{ 2, 1 }, .{ 1, 3 } });
        const col_ptr = &csc.col_ptr;
        const row_idx = csc.row_idx[0..csc.nnz()];
        const vals = csc.vals[0..csc.nnz()];

        var s = try Solver.init(gpa, 2, col_ptr, row_idx, null);
        defer s.deinit();
        try s.factor(vals, .{});
        var x: [2]f64 = undefined;
        s.solveNeg(&.{ 5, 7 }, &x);
        try testing.expectApproxEqAbs(@as(f64, -1.6), x[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, -1.8), x[1], 1e-12);

        // new values, same pattern -> refactor path
        vals[0] = 4;
        vals[3] = 5; // [4 1; 1 5]
        try s.factor(vals, .{});
        s.solveNeg(&.{ 9, 11 }, &x);
        try testing.expectApproxEqAbs(@as(f64, -34.0 / 19.0), x[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, -35.0 / 19.0), x[1], 1e-12);
    }
};

const FftTests = struct {
    const impl = @import("root.zig").fft;
    const fft = impl.fft;
    const ifft = impl.ifft;
    const math = std.math;

    test "fft: impulse response is flat spectrum" {
        var re = [_]f64{ 1, 0, 0, 0, 0, 0, 0, 0 };
        var im = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
        fft(&re, &im);
        for (re) |v| try testing.expectApproxEqAbs(@as(f64, 1.0), v, 1e-14);
        for (im) |v| try testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-14);
    }

    test "fft: pure sinusoid at bin 1 (N=8)" {
        const n = 8;
        var re: [n]f64 = undefined;
        var im = @as([n]f64, @splat(0));
        for (0..n) |k| {
            re[k] = @cos(2.0 * math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
        }
        fft(&re, &im);
        // cos -> (N/2) at bin 1 and bin N-1, zero elsewhere
        try testing.expectApproxEqAbs(@as(f64, 4.0), re[1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 4.0), re[n - 1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[n - 1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), re[0], 1e-12);
        for (2..n - 1) |k| {
            try testing.expectApproxEqAbs(@as(f64, 0.0), re[k], 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-12);
        }
    }

    test "fft: pure sine at bin 2 (N=16)" {
        const n = 16;
        var re: [n]f64 = undefined;
        var im = @as([n]f64, @splat(0));
        for (0..n) |k| {
            re[k] = @sin(2.0 * math.pi * 2.0 * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n)));
        }
        fft(&re, &im);
        // sin -> -j·(N/2) at bin 2, +j·(N/2) at bin N-2
        try testing.expectApproxEqAbs(@as(f64, 0.0), re[2], 1e-11);
        try testing.expectApproxEqAbs(@as(f64, -8.0), im[2], 1e-11);
        try testing.expectApproxEqAbs(@as(f64, 0.0), re[n - 2], 1e-11);
        try testing.expectApproxEqAbs(@as(f64, 8.0), im[n - 2], 1e-11);
    }

    test "fft/ifft: round-trip recovers original signal" {
        const n = 32;
        var re: [n]f64 = undefined;
        var im = @as([n]f64, @splat(0));
        var orig: [n]f64 = undefined;
        for (0..n) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            re[k] = @sin(2.0 * math.pi * 5.0 * t) + 0.3 * @cos(2.0 * math.pi * 11.0 * t);
            orig[k] = re[k];
        }
        fft(&re, &im);
        ifft(&re, &im);
        for (0..n) |k| {
            try testing.expectApproxEqAbs(orig[k], re[k], 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-12);
        }
    }

    test "fft: N=1024 Parseval and bin accuracy" {
        const n = 1024;
        var re: [n]f64 = undefined;
        var im = @as([n]f64, @splat(0));
        for (0..n) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            re[k] = 2.0 * @cos(2.0 * math.pi * 5.0 * t) + @sin(2.0 * math.pi * 100.0 * t) + 0.5 * @cos(2.0 * math.pi * 511.0 * t);
        }
        var e_time: f64 = 0;
        for (re) |v| e_time += v * v;

        fft(&re, &im);

        var e_freq: f64 = 0;
        for (re, im) |r, i| e_freq += r * r + i * i;
        e_freq /= @as(f64, @floatFromInt(n));
        try testing.expectApproxEqRel(e_time, e_freq, 1e-10);

        // bin 5: amplitude 2 cos → |X[5]| = N/2 * 2 = 1024
        const mag5 = @sqrt(re[5] * re[5] + im[5] * im[5]);
        try testing.expectApproxEqRel(@as(f64, 1024.0), mag5, 1e-10);
        // bin 100: amplitude 1 sin → |X[100]| = N/2 = 512
        const mag100 = @sqrt(re[100] * re[100] + im[100] * im[100]);
        try testing.expectApproxEqRel(@as(f64, 512.0), mag100, 1e-10);
    }
};

const FreqSolveTests = struct {
    const impl = @import("root.zig").freq_solve;
    const FreqSolver = impl.FreqSolver;
    const dense_lu = @import("root.zig").dense_lu;

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
        dense_lu.buildComplexAdmittance(2, 4, &[_]f64{ 1, 2, 3, 4 }, &[_]f64{ 0.1, 0.2, 0.3, 0.4 }, omega, &a);

        for (0..nn) |row| {
            var sum: f64 = 0;
            for (0..nn) |col| sum += a[col * nn + row] * y[col]; // A^T
            try testing.expectApproxEqAbs(rhs[row], sum, 1e-10);
        }

        // As a complex system that is A^H y = b, A = G + jωC: row i of
        // (G^T − jωC^T) y, not (G^T + jωC^T) y, reproduces b. Callers that
        // need A^T's solution (acxf, PXF) conjugate.
        const gm = [_]f64{ 1, 2, 3, 4 };
        const cm = [_]f64{ 0.1, 0.2, 0.3, 0.4 };
        for (0..2) |i| {
            var re: f64 = 0;
            var im: f64 = 0;
            for (0..2) |k| {
                const gr = gm[k * 2 + i];
                const ci = -omega * cm[k * 2 + i];
                re += gr * y[k] - ci * y[2 + k];
                im += gr * y[2 + k] + ci * y[k];
            }
            try testing.expectApproxEqAbs(rhs[i], re, 1e-10);
            try testing.expectApproxEqAbs(rhs[2 + i], im, 1e-10);
        }
    }

    test "FreqSolver: setOmega then solveRhs preserves factorization across calls" {
        // Factor once, then two right-hand sides against the same factors.
        const allocator = testing.allocator;
        const g = try allocator.dupe(f64, &[_]f64{ 5, 1, 1, 5 });
        const c = try allocator.dupe(f64, &[_]f64{ 0.5, 0, 0, 0.5 });

        var fs = try FreqSolver.initDense(allocator, 2, g, c);
        defer fs.deinit(allocator);

        try fs.setOmega(3.0);

        // Solve two different RHS and verify Ax = rhs for each.
        var a: [16]f64 = undefined;
        dense_lu.buildComplexAdmittance(2, 4, &[_]f64{ 5, 1, 1, 5 }, &[_]f64{ 0.5, 0, 0, 0.5 }, 3.0, &a);

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
        // One shared rhs across all lanes (solveBatch's contract).
        var rhs: [nn]f64 = undefined;
        for (0..nn) |i| rhs[i] = @floatFromInt(i + 1);

        for ([_]bool{ false, true }) |adjoint| {
            var x_batch: [omegas.len * nn]f64 = undefined;
            try fs.solveBatch(&omegas, .{}, &rhs, &x_batch, adjoint);

            var x_ref: [omegas.len * nn]f64 = undefined;
            try @TypeOf(fs).test_access.solveBatchSerial(&fs, &omegas, .{}, 0, omegas.len, &rhs, &x_ref, adjoint);
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
            pub fn linearizeAc(_: @This(), _: []const f64) !void {}
            // Never reached (n > DENSE_THRESHOLD) but must exist for fromCircuit's
            // dense branch to type-check against `anytype`.
            pub fn denseG(_: @This(), _: []f64) void {}
            pub fn denseC(_: @This(), _: []f64) void {}
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
        // The same matrices, dense, for the multi-rhs check below.
        const gd = try allocator.alloc(f64, n * n);
        const cd = try allocator.alloc(f64, n * n);
        @memset(gd, 0);
        @memset(cd, 0);
        for (0..n) |j| for (col_ptr.items[j]..col_ptr.items[j + 1]) |p| {
            gd[row_idx.items[p] * n + j] = g_vals.items[p];
            cd[row_idx.items[p] * n + j] = c_vals.items[p];
        };
        var fd = try FreqSolver.initDense(allocator, n, gd, cd);
        defer fd.deinit(allocator);
        // A re-evaluated circuit cannot reach the solver's snapshot.
        @memset(g_vals.items, std.math.nan(f64));
        @memset(c_vals.items, std.math.nan(f64));

        // Enough omegas to span more than one W-chunk plus a ragged tail.
        const omegas = [_]f64{ 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000 };
        const nn: usize = 2 * n;
        const total = omegas.len * nn;
        // One shared rhs across all lanes (solveBatch's contract).
        const rhs = try allocator.alloc(f64, nn);
        defer allocator.free(rhs);
        for (0..nn) |i| rhs[i] = @sin(@as(f64, @floatFromInt(i)));

        const x_batch = try allocator.alloc(f64, total);
        defer allocator.free(x_batch);
        const x_ref = try allocator.alloc(f64, total);
        defer allocator.free(x_ref);

        for ([_]bool{ false, true }) |adjoint| {
            try fs.solveBatch(&omegas, .{}, rhs, x_batch, adjoint);
            const work_ptr = fs.strategy.sp.lane_work.ptr;
            try @TypeOf(fs).test_access.solveBatchSerial(&fs, &omegas, .{}, 0, omegas.len, rhs, x_ref, adjoint);
            for (x_batch, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
            for (rhs) |*value| value.* *= -2;
            try fs.solveBatch(omegas[0..3], .{}, rhs, x_batch[0 .. 3 * nn], adjoint);
            try fs.solveBatch(omegas[3..], .{}, rhs, x_batch[3 * nn ..], adjoint);
            try testing.expectEqual(work_ptr, fs.strategy.sp.lane_work.ptr);
            try @TypeOf(fs).test_access.solveBatchSerial(&fs, &omegas, .{}, 0, omegas.len, rhs, x_ref, adjoint);
            for (x_batch, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
        }

        // Two right-hand sides share each lane factorization, and addDiagG
        // lands on the same entry in the sparse and the dense copy.
        fs.addDiagG(7, -3.5);
        fd.addDiagG(7, -3.5);
        const rhs2 = try allocator.alloc(f64, 2 * nn);
        defer allocator.free(rhs2);
        for (rhs2, 0..) |*value, i| value.* = @cos(@as(f64, @floatFromInt(i)));
        const x2 = try allocator.alloc(f64, 2 * total);
        defer allocator.free(x2);
        const x2_ref = try allocator.alloc(f64, 2 * total);
        defer allocator.free(x2_ref);
        for ([_]bool{ false, true }) |adjoint| {
            try fs.solveBatch(&omegas, .{}, rhs2, x2, adjoint);
            try fd.solveBatch(&omegas, .{}, rhs2, x2_ref, adjoint);
            for (x2, x2_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-10);
        }

        // Frequency-dependent terms: a repeated slot, a ground (trash) entry
        // and an off-diagonal one.
        const nnz: u32 = @intCast(row_idx.items.len);
        const dyn_slots = [_]u32{ 1, 4, 4, nnz, 10 };
        var dyn_re: [dyn_slots.len * omegas.len]f64 = undefined;
        var dyn_im: [dyn_slots.len * omegas.len]f64 = undefined;
        for (&dyn_re, &dyn_im, 0..) |*re, *im, i| {
            const t: f64 = @floatFromInt(i);
            re.* = 0.3 * @sin(t);
            im.* = 0.2 * @cos(1.7 * t);
        }
        const dyn: impl.Dyn = .{ .slots = &dyn_slots, .re = &dyn_re, .im = &dyn_im };

        // The W-lane fill is bitwise W scalar fills, ragged tail included:
        // `Stacked` loads every column through the identity row map (each
        // stacked column's rows are distinct) and lane l must equal
        // `setOmegaSparse` at ω index base + l, entry by entry.
        const ta = @TypeOf(fs).test_access;
        const W = ta.W;
        const sp = &fs.strategy.sp;
        try ta.indexDyn(allocator, sp, dyn);
        const nn2: usize = 2 * n;
        const w_rows = try allocator.alloc(@Vector(W, f64), nn2);
        defer allocator.free(w_rows);
        var base: usize = 0;
        while (base < omegas.len) : (base += W) {
            const cnt = @min(W, omegas.len - base);
            var ow: [W]f64 = undefined;
            for (0..W) |l| ow[l] = omegas[base + @min(l, cnt - 1)];
            const src = impl.Stacked(W).of(sp, ow, dyn, base, cnt);
            for (0..cnt) |l| {
                try ta.setOmegaSparse(n, sp, omegas[base + l], dyn, base + l);
                for (0..nn2) |col| {
                    src.load(col, w_rows, sp.row_idx);
                    for (sp.col_ptr[col]..sp.col_ptr[col + 1]) |p| {
                        const row: [W]f64 = w_rows[sp.row_idx[p]];
                        try testing.expectEqual(@as(u64, @bitCast(sp.vals[p])), @as(u64, @bitCast(row[l])));
                    }
                }
            }
        }

        // Fused into the refactor, the fill gives the factors of a scalar
        // SparseLu refactor of `setOmegaSparse`'s values, lane by lane, and
        // so does its W = 1 instantiation: the solves agree exactly (equal
        // as values; a zero may differ in sign, see `LaneLu.solve`).
        const lane_lu = @import("root.zig").lane_lu;
        const b_lane = try allocator.alloc(@Vector(W, f64), nn2);
        defer allocator.free(b_lane);
        const x_lane = try allocator.alloc(@Vector(W, f64), nn2);
        defer allocator.free(x_lane);
        const b_one = try allocator.alloc(@Vector(1, f64), nn2);
        defer allocator.free(b_one);
        const x_one = try allocator.alloc(@Vector(1, f64), nn2);
        defer allocator.free(x_one);
        const x_scalar = try allocator.alloc(f64, nn2);
        defer allocator.free(x_scalar);
        for (rhs, b_lane, b_one) |v, *bw, *b1| {
            bw.* = @splat(v);
            b1.* = @splat(v);
        }
        base = 0;
        while (base < omegas.len) : (base += W) {
            const cnt = @min(W, omegas.len - base);
            var scalar_vals: [W][]f64 = undefined;
            for (0..cnt) |l| {
                try ta.setOmegaSparse(n, sp, omegas[base + l], dyn, base + l);
                scalar_vals[l] = try allocator.dupe(f64, sp.vals);
            }
            defer for (scalar_vals[0..cnt]) |v| allocator.free(v);
            const lu = &sp.slv.lu.?;
            var ow: [W]f64 = undefined;
            for (0..W) |l| ow[l] = omegas[base + @min(l, cnt - 1)];
            var lw = try lane_lu.LaneLu(W).init(allocator, lu);
            defer lw.deinit(allocator);
            const mask_w = lw.refactor(impl.Stacked(W).of(sp, ow, dyn, base, cnt), 1e-12);
            lw.solve(b_lane, x_lane);
            for (0..cnt) |l| {
                var l1 = try lane_lu.LaneLu(1).init(allocator, lu);
                defer l1.deinit(allocator);
                const mask_1 = l1.refactor(impl.Stacked(1).of(sp, .{omegas[base + l]}, dyn, base + l, 1), 1e-12);
                const failed = if (lu.refactor(sp.col_ptr, scalar_vals[l], 1e-12)) |_| false else |_| true;
                try testing.expectEqual(failed, mask_1 != 0);
                try testing.expectEqual(failed, (mask_w >> @intCast(l)) & 1 != 0);
                if (failed) continue;
                lu.solve(rhs, x_scalar);
                l1.solve(b_one, x_one);
                for (x_scalar, x_one, x_lane) |xs, x1, xw| {
                    const lanes_w: [W]f64 = xw;
                    try testing.expectEqual(xs, x1[0]);
                    try testing.expectEqual(xs, lanes_w[l]);
                }
            }
        }

        // Solved, the lane path matches its serial oracle and the dense
        // strategy, which places the same entries by (row, col).
        fd.strategy.dense.src_col_ptr = col_ptr.items;
        fd.strategy.dense.src_row_idx = row_idx.items;
        for ([_]bool{ false, true }) |adjoint| {
            try fs.solveBatch(&omegas, dyn, rhs, x_batch, adjoint);
            try ta.solveBatchSerial(&fs, &omegas, dyn, 0, omegas.len, rhs, x_ref, adjoint);
            for (x_batch, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
            try fd.solveBatch(&omegas, dyn, rhs, x2_ref[0..total], adjoint);
            for (x_batch, x2_ref[0..total]) |a, b| try testing.expectApproxEqRel(b, a, 1e-10);
        }
    }

    test "factorEach/solveEach equal a per-omega setOmega+solveRhs (sparse lanes and dense)" {
        const allocator = testing.allocator;
        // Tridiagonal G with a C that dominates at the top of the band, and
        // omega = 0 in the batch as harmonic balance's DC block.
        const omegas = [_]f64{ 0, 1, 3, 10, 30, 100, 300, 1000, 3000, 1e4, 3e4 };
        inline for (.{ 20, 6 }) |n_| {
            const n: u32 = n_; // 20: sparse lanes; 6: dense
            var col_ptr: std.ArrayList(u32) = .empty;
            defer col_ptr.deinit(allocator);
            var row_idx: std.ArrayList(u32) = .empty;
            defer row_idx.deinit(allocator);
            var g_vals: std.ArrayList(f64) = .empty;
            defer g_vals.deinit(allocator);
            var c_vals: std.ArrayList(f64) = .empty;
            defer c_vals.deinit(allocator);
            try col_ptr.append(allocator, 0);
            for (0..n) |j| {
                for ([_]i64{ -1, 0, 1 }) |d| {
                    const r = @as(i64, @intCast(j)) + d;
                    if (r < 0 or r >= n) continue;
                    try row_idx.append(allocator, @intCast(r));
                    try g_vals.append(allocator, if (d == 0) 3 + @as(f64, @floatFromInt(j % 4)) else -1);
                    try c_vals.append(allocator, if (d == 0) 0.02 else -0.005);
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
                pub fn linearizeAc(_: @This(), _: []const f64) !void {}
                pub fn denseG(_: @This(), g: []f64) void {
                    @memset(g, 0);
                }
                pub fn denseC(_: @This(), c: []f64) void {
                    @memset(c, 0);
                }
            };
            const ckt = Ckt{ .n = n, .nnz = row_idx.items.len, .col_ptr = col_ptr.items, .row_idx = row_idx.items, .g_vals = g_vals.items, .c_vals = c_vals.items };
            var fs = try FreqSolver.fromCircuit(allocator, ckt, &.{});
            defer fs.deinit(allocator);
            // The planes arrive through setPlanes, not the circuit.
            fs.setPlanes(g_vals.items, c_vals.items);

            const nn: usize = 2 * n;
            const rhs = try allocator.alloc(f64, omegas.len * nn);
            defer allocator.free(rhs);
            for (rhs, 0..) |*v, i| v.* = @sin(0.37 * @as(f64, @floatFromInt(i)));
            const x = try allocator.alloc(f64, rhs.len);
            defer allocator.free(x);
            const x_ref = try allocator.alloc(f64, rhs.len);
            defer allocator.free(x_ref);

            try fs.factorEach(allocator, &omegas);
            try testing.expectEqual(@as(usize, 0), fs.held_id.items.len);
            // Twice: the held factors survive a solve. Then the adjoint.
            for (0..2) |_| fs.solveEach(rhs, x, false);
            for (omegas, 0..) |w, k| try fs.solve(w, rhs[k * nn ..][0..nn], x_ref[k * nn ..][0..nn]);
            for (x, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
            try fs.factorEach(allocator, &omegas);
            fs.solveEach(rhs, x, true);
            for (omegas, 0..) |w, k| {
                try fs.setOmega(w);
                try fs.solveRhsT(rhs[k * nn ..][0..nn], x_ref[k * nn ..][0..nn]);
            }
            for (x, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
            // The same planes through fromPlanes, no circuit.
            var fp = try FreqSolver.fromPlanes(allocator, n, col_ptr.items, row_idx.items, g_vals.items, c_vals.items);
            defer fp.deinit(allocator);
            try fp.factorEach(allocator, &omegas);
            fp.solveEach(rhs, x, true);
            for (x, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
        }
    }
};

const GmresTests = struct {
    const impl = @import("root.zig").gmres;
    const Gmres = impl.Gmres;

    fn denseMatvec(a: []const f64, n: usize, v: []const f64, w: []f64) void {
        for (0..n) |i| {
            var s: f64 = 0;
            for (0..n) |j| s += a[i * n + j] * v[j];
            w[i] = s;
        }
    }

    /// Dense operator for tests: A is n x n row-major.
    const DenseMatvec = struct {
        a: []const f64,
        n: u32,

        pub fn matvec(self: *const @This(), v: []const f64, w: []f64) void {
            denseMatvec(self.a, self.n, v, w);
        }
    };

    /// Dense operator with a diagonal preconditioner, r[i] /= diag[i].
    const DiagPreconditioned = struct {
        a: []const f64,
        n: u32,
        diag: []const f64,

        pub fn matvec(self: *const @This(), v: []const f64, w: []f64) void {
            denseMatvec(self.a, self.n, v, w);
        }

        pub fn precond(self: *const @This(), r: []f64) void {
            for (r, self.diag) |*ri, di| ri.* /= di;
        }
    };

    test "GMRES: 3x3 SPD system converges in at most 3 iterations" {
        const gpa = testing.allocator;
        // A = [4 1 0; 1 3 1; 0 1 2], b = [5; 5; 3] => x = [1; 1; 1]
        var mv = DenseMatvec{
            .a = &.{ 4, 1, 0, 1, 3, 1, 0, 1, 2 },
            .n = 3,
        };
        var gmres = try Gmres.init(gpa, 3, 3);
        defer gmres.deinit(gpa);

        var x = [3]f64{ 0, 0, 0 };
        const result = gmres.solve(
            &mv,
            &.{ 5, 5, 3 },
            &x,
            1e-12,
            0,
        );

        try testing.expect(result.converged);
        try testing.expect(result.iterations <= 3);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[0], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[1], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[2], 1e-10);
    }

    test "GMRES: ill-conditioned system with tight budget reports non-convergence" {
        const gpa = testing.allocator;
        // 4x4 ill-conditioned non-symmetric system. With restart depth m=1 and
        // only 2 restarts, GMRES(1) cannot converge.
        const n: u32 = 4;
        var mv = DenseMatvec{
            .a = &.{
                1e6, 1,    1,   1,
                1,   1e-6, 1,   1,
                1,   1,    1e6, 1,
                1,   1,    1,   1e-6,
            },
            .n = n,
        };
        var gmres_s = try Gmres.init(gpa, n, 1);
        defer gmres_s.deinit(gpa);

        var x = [n]f64{ 0, 0, 0, 0 };
        const result = gmres_s.solve(
            &mv,
            &.{ 1, 1, 1, 1 },
            &x,
            1e-14,
            2,
        );
        try testing.expect(!result.converged);
        try testing.expect(result.residual > 1e-14);
    }

    test "GMRES: restart behavior on larger system" {
        const gpa = testing.allocator;
        // 8x8 diagonally dominant system; restart depth m=3 forces multiple restarts.
        const n: u32 = 8;
        var a: [n * n]f64 = undefined;
        var b: [n]f64 = undefined;
        @memset(&a, 0);
        for (0..n) |i| {
            a[i * n + i] = 10;
            if (i + 1 < n) {
                a[i * n + i + 1] = 1;
                a[(i + 1) * n + i] = 1;
            }
            b[i] = @as(f64, @floatFromInt(i + 1));
        }

        var mv = DenseMatvec{ .a = &a, .n = n };

        // Small restart window: needs multiple restarts.
        var gmres = try Gmres.init(gpa, n, 3);
        defer gmres.deinit(gpa);

        var x = [n]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const result = gmres.solve(
            &mv,
            &b,
            &x,
            1e-10,
            50,
        );
        try testing.expect(result.converged);
        // More than m=3 iterations means restarts happened.
        try testing.expect(result.iterations > 3);

        // Verify solution: A*x should equal b.
        var check: [n]f64 = undefined;
        mv.matvec(&x, &check);
        for (0..n) |i| try testing.expectApproxEqAbs(b[i], check[i], 1e-8);
    }

    test "GMRES: right preconditioning returns correct unpreconditioned solution" {
        const gpa = testing.allocator;
        // A = [10 1; 2 8], b = [11; 10] => x = [1; 1]
        // Precond M = diag(10, 8): the solution must be in the original space,
        // not in the preconditioned space.
        var op = DiagPreconditioned{ .a = &.{ 10, 1, 2, 8 }, .n = 2, .diag = &.{ 10, 8 } };

        var gmres = try Gmres.init(gpa, 2, 10);
        defer gmres.deinit(gpa);

        var x = [2]f64{ 0, 0 };
        const result = gmres.solve(
            &op,
            &.{ 11, 10 },
            &x,
            1e-12,
            0,
        );

        try testing.expect(result.converged);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[0], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[1], 1e-10);
    }

    test "GMRES: zero RHS returns zero solution immediately" {
        const gpa = testing.allocator;
        var mv = DenseMatvec{
            .a = &.{ 1, 0, 0, 1 },
            .n = 2,
        };
        var gmres = try Gmres.init(gpa, 2, 5);
        defer gmres.deinit(gpa);

        var x = [2]f64{ 42, 99 };
        const result = gmres.solve(
            &mv,
            &.{ 0, 0 },
            &x,
            1e-12,
            0,
        );
        try testing.expect(result.converged);
        try testing.expect(result.iterations == 0);
        try testing.expectApproxEqAbs(@as(f64, 0.0), x[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 0.0), x[1], 1e-15);
    }
};

const LaneLuTests = struct {
    const impl = @import("root.zig").lane_lu;
    const Allocator = std.mem.Allocator;
    const LaneLu = impl.LaneLu;
    const sparse_lu = @import("root.zig").sparse_lu;

    test "LaneLu construction releases storage on every allocation failure" {
        const gpa = testing.allocator;
        const csc = DenseCsc(2).from(.{ .{ 4, 1 }, .{ 1, 3 } });
        var q = identity(2);
        var base = try sparse_lu.SparseLu.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer base.deinit(gpa);
        try base.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        try testing.checkAllAllocationFailures(gpa, struct {
            fn run(allocator: Allocator, factored: *const sparse_lu.SparseLu) !void {
                var lanes = try LaneLu(4).init(allocator, factored);
                defer lanes.deinit(allocator);
            }
        }.run, .{&base});
    }

    test "LaneLu(1) refactor+solve bit-identical to SparseLu on same values" {
        const gpa = testing.allocator;
        const a = [4][4]f64{
            .{ 4, 1, 0, 0 },
            .{ 1, 5, 2, 0 },
            .{ 0, 2, 6, 3 },
            .{ 0, 0, 3, 7 },
        };
        const csc = DenseCsc(4).from(a);
        var q = identity(4);
        var base = try sparse_lu.SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer base.deinit(gpa);
        try base.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        // Scalar reference: refactor + solve on the base itself.
        try base.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
        const b_ref = [4]f64{ 1, 2, 3, 4 };
        var x_ref: [4]f64 = undefined;
        base.solve(&b_ref, &x_ref);

        // LaneLu(1): same values, one lane.
        const L1 = LaneLu(1);
        var ll = try L1.init(gpa, &base);
        defer ll.deinit(gpa);
        var lvals: [16]L1.V = undefined;
        for (csc.vals[0..csc.nnz()], 0..) |v, i| lvals[i] = .{v};
        const mask = ll.refactor(L1.Plane{ .col_ptr = &csc.col_ptr, .vals = lvals[0..csc.nnz()] }, 1e-12);
        try testing.expectEqual(@as(u64, 0), mask);

        var lb: [4]L1.V = undefined;
        for (b_ref, 0..) |v, i| lb[i] = .{v};
        var lx: [4]L1.V = undefined;
        ll.solve(&lb, &lx);

        for (0..4) |i| try testing.expectEqual(x_ref[i], lx[i][0]);
    }

    test "LaneLu(W) lane l bit-identical to scalar replay of lane l, perturbed" {
        const gpa = testing.allocator;
        const W = std.simd.suggestVectorLength(f64) orelse 4;
        const LW = LaneLu(W);

        const patterns = [_][4][4]f64{
            .{ .{ 4, 1, 0, 0 }, .{ 1, 5, 2, 0 }, .{ 0, 2, 6, 3 }, .{ 0, 0, 3, 7 } },
            .{ .{ 10, 2, 1, 0 }, .{ 2, 9, 0, 1 }, .{ 1, 0, 8, 2 }, .{ 0, 1, 2, 7 } },
            // MNA-style zero diagonal on the last node (needs off-diagonal pivot).
            .{ .{ 1e-3, 0, 1, 0 }, .{ 0, 2e-3, -1, 0 }, .{ 1, -1, 0, 1 }, .{ 0, 0, 1, 3 } },
            // Atto-siemens row (BSIMSOI floating body): the base tape carries a
            // scale-accepted pivot, so this exercises the growth-monitor skip.
            .{ .{ 2.0e-20, -1.0e-20, -1.0e-20, 0.0 }, .{ -1.0e-6, 1.0e3, -9.0e-4, 1.0e-3 }, .{ 1.0e-6, -9.0e-4, 2.0e-3, -1.0e-3 }, .{ 0.0, 0.0, -1.0e-3, 1.0 } },
        };

        var prng = std.Random.DefaultPrng.init(0xABCDEF);
        const rand = prng.random();

        for (patterns) |a0| {
            const base_csc = DenseCsc(4).from(a0);
            var q = identity(4);
            var base = try sparse_lu.SparseLu.init(gpa, 4, &base_csc.col_ptr, base_csc.row_idx[0..base_csc.nnz()], &q);
            defer base.deinit(gpa);
            try base.factor(gpa, &base_csc.col_ptr, base_csc.row_idx[0..base_csc.nnz()], base_csc.vals[0..base_csc.nnz()], 1e-3);
            const nnz = base_csc.nnz();

            // Build W perturbed (+/-5%) value sets sharing the pattern.
            var lane_vals: [W][16]f64 = undefined;
            for (0..W) |l| {
                for (0..nnz) |p| {
                    const f = 1.0 + (rand.float(f64) - 0.5) * 0.1;
                    lane_vals[l][p] = base_csc.vals[p] * f;
                }
            }

            // Interleave into the vector plane.
            var lvals: [16]LW.V = undefined;
            for (0..nnz) |p| {
                var v: [W]f64 = undefined;
                for (0..W) |l| v[l] = lane_vals[l][p];
                lvals[p] = v;
            }

            var ll = try LW.init(gpa, &base);
            defer ll.deinit(gpa);
            const mask = ll.refactor(LW.Plane{ .col_ptr = &base_csc.col_ptr, .vals = lvals[0..nnz] }, 1e-12);

            const b_scalar = [4]f64{ 1, 2, 3, 4 };
            var lb: [4]LW.V = undefined;
            for (b_scalar, 0..) |v, i| lb[i] = @splat(v);
            var lx: [4]LW.V = undefined;
            ll.solve(&lb, &lx);

            // Scalar replay of each lane on the SAME base (its own refactor/solve).
            // The lane mask must agree with the scalar SingularMatrix verdict, and
            // every lane the scalar path accepted must be bit-identical.
            for (0..W) |l| {
                const scalar_bad = if (base.refactor(&base_csc.col_ptr, lane_vals[l][0..nnz], 1e-12)) |_| false else |_| true;
                const lane_bad = (mask & (@as(u64, 1) << @intCast(l))) != 0;
                try testing.expectEqual(scalar_bad, lane_bad);
                if (scalar_bad) continue;
                var xr: [4]f64 = undefined;
                base.solve(&b_scalar, &xr);
                for (0..4) |i| {
                    const row: [W]f64 = lx[i];
                    try testing.expectEqual(xr[i], row[l]);
                }
            }
        }
    }

    test "LaneLu(W): one singular lane sets its mask bit, others stay exact" {
        const gpa = testing.allocator;
        const W = std.simd.suggestVectorLength(f64) orelse 4;
        if (W < 2) return; // needs at least two lanes to be meaningful
        const LW = LaneLu(W);

        const a0 = [3][3]f64{ .{ 5, 1, 0 }, .{ 1, 5, 1 }, .{ 0, 1, 5 } };
        const csc = DenseCsc(3).from(a0);
        var q = identity(3);
        var base = try sparse_lu.SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer base.deinit(gpa);
        try base.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        const nnz = csc.nnz();

        // Lane 1 gets a matrix whose frozen pivot collapses (zero out the diagonal);
        // all other lanes keep the well-conditioned values.
        var lane_vals: [W][9]f64 = undefined;
        for (0..W) |l| for (0..nnz) |p| {
            lane_vals[l][p] = csc.vals[p];
        };
        // Make lane 1 rank-deficient (all entries equal -> singular) so the frozen
        // pivot at some step collapses; the diagonal there becomes 0.
        for (0..nnz) |p| lane_vals[1][p] = 1.0;

        var lvals: [9]LW.V = undefined;
        for (0..nnz) |p| {
            var v: [W]f64 = undefined;
            for (0..W) |l| v[l] = lane_vals[l][p];
            lvals[p] = v;
        }

        var ll = try LW.init(gpa, &base);
        defer ll.deinit(gpa);
        const mask = ll.refactor(LW.Plane{ .col_ptr = &csc.col_ptr, .vals = lvals[0..nnz] }, 0); // growth off; catch singular only

        try testing.expect((mask & (@as(u64, 1) << 1)) != 0); // lane 1 flagged

        // The good lanes still solve exactly vs scalar replay.
        const b_scalar = [3]f64{ 1, 2, 3 };
        var lb: [3]LW.V = undefined;
        for (b_scalar, 0..) |v, i| lb[i] = @splat(v);
        var lx: [3]LW.V = undefined;
        ll.solve(&lb, &lx);

        for (0..W) |l| {
            if (l == 1) continue;
            try base.refactor(&csc.col_ptr, lane_vals[l][0..nnz], 0);
            var xr: [3]f64 = undefined;
            base.solve(&b_scalar, &xr);
            for (0..3) |i| {
                const row: [W]f64 = lx[i];
                try testing.expectEqual(xr[i], row[l]);
            }
        }
    }

    fn expectZero(comptime W: usize, w: []const @Vector(W, f64)) !void {
        for (w) |v| try testing.expect(@reduce(.And, v == @as(@Vector(W, f64), @splat(0))));
    }

    test "LaneLu(W): refactor leaves w zero, so a second refactor still matches scalar" {
        // With fill-in, a stale `w` slot would leak into the next refactor,
        // since no column clears its pattern up front.
        const gpa = testing.allocator;
        const W = std.simd.suggestVectorLength(f64) orelse 4;
        const LW = LaneLu(W);
        const a0 = [5][5]f64{
            .{ 9, 1, 2, 0, 1 },
            .{ 1, 8, 0, 3, 0 },
            .{ 2, 0, 7, 1, 2 },
            .{ 0, 3, 1, 9, 1 },
            .{ 1, 0, 2, 1, 6 },
        };
        const csc = DenseCsc(5).from(a0);
        const nnz = csc.nnz();
        var q = identity(5);
        var base = try sparse_lu.SparseLu.init(gpa, 5, &csc.col_ptr, csc.row_idx[0..nnz], &q);
        defer base.deinit(gpa);
        try base.factor(gpa, &csc.col_ptr, csc.row_idx[0..nnz], csc.vals[0..nnz], 1e-3);

        var ll = try LW.init(gpa, &base);
        defer ll.deinit(gpa);
        var prng = std.Random.DefaultPrng.init(0x5EED);
        const rand = prng.random();
        var lane_vals: [W][25]f64 = undefined;
        var lvals: [25]LW.V = undefined;
        for (0..3) |_| {
            for (0..W) |l| for (0..nnz) |p| {
                lane_vals[l][p] = csc.vals[p] * (1.0 + (rand.float(f64) - 0.5) * 0.2);
            };
            for (0..nnz) |p| {
                var v: [W]f64 = undefined;
                for (0..W) |l| v[l] = lane_vals[l][p];
                lvals[p] = v;
            }
            try testing.expectEqual(@as(u64, 0), ll.refactor(LW.Plane{ .col_ptr = &csc.col_ptr, .vals = lvals[0..nnz] }, 1e-12));
            try expectZero(W, ll.w);

            const b_scalar = [5]f64{ 1, -2, 3, -4, 5 };
            var lb: [5]LW.V = undefined;
            for (b_scalar, 0..) |v, i| lb[i] = @splat(v);
            var lx: [5]LW.V = undefined;
            ll.solve(&lb, &lx);
            for (0..W) |l| {
                try base.refactor(&csc.col_ptr, lane_vals[l][0..nnz], 1e-12);
                var xr: [5]f64 = undefined;
                base.solve(&b_scalar, &xr);
                for (0..5) |i| {
                    const row: [W]f64 = lx[i];
                    try testing.expectEqual(xr[i], row[l]);
                }
            }
        }
    }

    test "LaneLu(W): a void pivot fails every lane and leaves w zero" {
        // Unknown 2 appears in no equation: its only structural entry is a
        // zero-valued diagonal, so SparseLu fabricates a unit pivot for it.
        const gpa = testing.allocator;
        const W = std.simd.suggestVectorLength(f64) orelse 4;
        const LW = LaneLu(W);
        const col_ptr = [_]u32{ 0, 2, 4, 5 };
        const row_idx = [_]u32{ 0, 1, 0, 1, 2 };
        const vals = [_]f64{ 4, 1, 1, 3, 0 };
        var q = identity(3);
        var base = try sparse_lu.SparseLu.init(gpa, 3, &col_ptr, &row_idx, &q);
        defer base.deinit(gpa);
        try base.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3);
        try testing.expect(base.void_col[2]);

        var ll = try LW.init(gpa, &base);
        defer ll.deinit(gpa);
        var lvals: [5]LW.V = undefined;
        for (&lvals, vals) |*o, v| o.* = @splat(v);
        const all: u64 = std.math.maxInt(@Int(.unsigned, W));
        try testing.expectEqual(all, ll.refactor(LW.Plane{ .col_ptr = &col_ptr, .vals = &lvals }, 1e-12));
        try expectZero(W, ll.w);
    }
};

const OrderTests = struct {
    const impl = @import("root.zig").order;
    const Ws = impl.Ws;
    const amd = impl.amd;
    const order = impl.order;
    const wsSize = impl.wsSize;

    fn expectPermutation(q: []const u32, n: u32) !void {
        var seen: [64]bool = @splat(false);
        for (q) |c| {
            try testing.expect(c < n);
            try testing.expect(!seen[c]);
            seen[c] = true;
        }
    }

    // 5x5 star: hub 0 coupled to every leaf. Min degree must defer the hub
    // until its degree collapses; eliminating it first fills the whole matrix.
    const star = [5][5]f64{
        .{ 1, 1, 1, 1, 1 },
        .{ 1, 1, 0, 0, 0 },
        .{ 1, 0, 1, 0, 0 },
        .{ 1, 0, 0, 1, 0 },
        .{ 1, 0, 0, 0, 1 },
    };

    test "amd: star defers the hub until its degree collapses" {
        const csc = DenseCsc(5).from(star);
        var buf: [2048]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [5]u32 = undefined;
        try order(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
        try expectPermutation(&q, 5);
        // hub 0 may not pivot before the second-to-last position
        try testing.expect(q[3] == 0 or q[4] == 0);
    }

    // A = [B1 C; 0 B2] over {0,1} and {2,3}: edges within each pair both ways,
    // C couples column 2 into row 0 only. Condensation: {2,3} → {0,1}, so the
    // sink block {0,1} must be factored first.
    const btf_case = [4][4]f64{
        .{ 1, 1, 1, 0 },
        .{ 1, 1, 0, 0 },
        .{ 0, 0, 1, 1 },
        .{ 0, 0, 1, 1 },
    };

    test "btf: sink block factored first" {
        const csc = DenseCsc(4).from(btf_case);
        var buf: [2048]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [4]u32 = undefined;
        try order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
        try expectPermutation(&q, 4);
        // Sink block {0,1} must appear first in the ordering
        try testing.expect(q[0] < 2 and q[1] < 2);
        try testing.expect(q[2] >= 2 and q[3] >= 2);
    }

    test "amd: supervariables, chain, diagonal-only" {
        // Star: indistinguishable leaves → supervariable merging
        {
            const csc = DenseCsc(5).from(star);
            var buf: [2048]u32 = undefined;
            var ws_val = Ws.init(&buf);
            var q: [5]u32 = undefined;
            try amd(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
            try expectPermutation(&q, 5);
            try testing.expect(q[3] == 0 or q[4] == 0);
        }
        // Tridiagonal chain of 6: exercises degree updates along a path
        {
            var a: [6][6]f64 = @splat(@splat(0));
            for (0..6) |i| {
                a[i][i] = 1;
                if (i + 1 < 6) {
                    a[i][i + 1] = 1;
                    a[i + 1][i] = 1;
                }
            }
            const csc = DenseCsc(6).from(a);
            var buf: [4096]u32 = undefined;
            var ws_val = Ws.init(&buf);
            var q: [6]u32 = undefined;
            try amd(6, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
            try expectPermutation(&q, 6);
        }
        // Diagonal-only (3×3 identity): 3 singleton blocks, passes through
        {
            var a: [3][3]f64 = @splat(@splat(0));
            for (0..3) |i| a[i][i] = 1;
            const csc = DenseCsc(3).from(a);
            var buf: [1024]u32 = undefined;
            var ws_val = Ws.init(&buf);
            var q: [3]u32 = undefined;
            try order(3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
            try expectPermutation(&q, 3);
        }
    }

    test "order: comptime and runtime results are identical" {
        @setEvalBranchQuota(200_000);
        const ct = comptime blk: {
            const csc = DenseCsc(4).from(btf_case);
            var buf: [2048]u32 = undefined;
            var ws_val = Ws.init(&buf);
            var q: [4]u32 = undefined;
            order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val) catch unreachable;
            break :blk q;
        };
        const csc = DenseCsc(4).from(btf_case);
        const buf = try testing.allocator.alloc(u32, wsSize(4, csc.nnz()));
        defer testing.allocator.free(buf);
        var ws_val = Ws.init(buf);
        var q: [4]u32 = undefined;
        try order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
        try testing.expectEqualSlices(u32, &ct, &q);
    }

    test "bump workspace: alloc, checkpoint, exhaustion" {
        var buf: [8]u32 = undefined;
        var ws_val = Ws.init(&buf);
        const a = try ws_val.alloc(4);
        a[0] = 7;
        const m = ws_val.mark();
        _ = try ws_val.allocSet(3, 0);
        try testing.expectError(error.OutOfWorkspace, ws_val.alloc(2));
        ws_val.release(m);
        _ = try ws_val.alloc(4);
        try testing.expectEqual(@as(u32, 7), buf[0]);
    }

    test "order and amd: empty and 1x1 patterns" {
        var buf: [256]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q0: [0]u32 = undefined;
        try amd(0, &[_]u32{0}, &[_]u32{}, &q0, &ws_val);
        try order(0, &[_]u32{0}, &[_]u32{}, &q0, &ws_val);
        var q: [1]u32 = undefined;
        try order(1, &[_]u32{ 0, 1 }, &[_]u32{0}, &q, &ws_val);
        try testing.expectEqual(@as(u32, 0), q[0]);
    }

    test "amd: complete graph K4, all vertices indistinguishable" {
        // K4: every vertex connected to every other → all are supervariables
        var a: [4][4]f64 = undefined;
        for (0..4) |i| for (0..4) |j| {
            a[i][j] = 1;
        };
        const csc = DenseCsc(4).from(a);
        var buf: [4096]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [4]u32 = undefined;
        try amd(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
        try expectPermutation(&q, 4);
    }

    test "btf: three blocks in correct topological order" {
        // Upper triangular 3×3: three singleton SCCs. Edge j→i iff A(i,j)≠0:
        // DAG is 2→1→0, 2→0. Reverse topo (sinks first): {0}, {1}, {2}.
        const a = [3][3]f64{
            .{ 1, 1, 1 },
            .{ 0, 1, 1 },
            .{ 0, 0, 1 },
        };
        const csc = DenseCsc(3).from(a);
        var buf: [2048]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [3]u32 = undefined;
        try order(3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
        try expectPermutation(&q, 3);
        // Sink {0} first, then {1}, then {2}
        try testing.expectEqual(@as(u32, 0), q[0]);
        try testing.expectEqual(@as(u32, 1), q[1]);
        try testing.expectEqual(@as(u32, 2), q[2]);
    }

    test "amd: arrowhead matrix defers the hub" {
        // 8×8 arrowhead: row 0 and col 0 are dense, rest is diagonal.
        // Hub vertex 0 should be deferred to the end.
        const n = 8;
        var a: [n][n]f64 = @splat(@splat(0));
        for (0..n) |i| {
            a[i][i] = 1;
            if (i > 0) {
                a[0][i] = 1;
                a[i][0] = 1;
            }
        }
        const csc = DenseCsc(n).from(a);
        var buf: [8192]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [n]u32 = undefined;
        try amd(n, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
        try expectPermutation(&q, n);
        // Hub 0 should be last or second-to-last
        try testing.expect(q[n - 1] == 0 or q[n - 2] == 0);
    }
};

const SparseTests = struct {
    const impl = @import("root.zig").sparse_lu;
    const Allocator = std.mem.Allocator;
    const SparseLu = impl.SparseLu;

    const order = @import("root.zig").order;

    test "3x3: factor + solve verified against dense reference" {
        const gpa = testing.allocator;
        const a = [3][3]f64{
            .{ 2, 1, 0 },
            .{ 1, 3, 1 },
            .{ 0, 1, 4 },
        };
        const b = [3]f64{ 1, 5, 9 };
        const csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(3, a, b, &lu);
    }

    test "order -> factor + solve: AMD permutation is valid and the solve is correct" {
        const gpa = testing.allocator;
        // Arrowhead: dense first row/col (hub at node 0), diagonal elsewhere.
        // AMD defers the hub, so q is a real permutation: order and LU composed.
        const a = [4][4]f64{
            .{ 5, 1, 1, 1 },
            .{ 1, 2, 0, 0 },
            .{ 1, 0, 3, 0 },
            .{ 1, 0, 0, 4 },
        };
        const b = [4]f64{ 8, 3, 4, 5 };
        const csc = DenseCsc(4).from(a);

        var q: [4]u32 = undefined;
        var buf: [order.wsSize(4, 10)]u32 = undefined; // arrowhead nnz = 10
        var ws = order.Ws.init(&buf);
        try order.order(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws);

        // q must be a valid permutation of 0..4.
        var seen = @as([4]bool, @splat(false));
        for (q) |c| {
            try testing.expect(!seen[c]);
            seen[c] = true;
        }
        // The hub (node 0) is deferred: not factored first.
        try testing.expect(q[0] != 0);

        var lu = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(4, a, b, &lu);
    }

    test "MNA structural zero diagonal: off-diagonal pivoting" {
        const gpa = testing.allocator;
        // Voltage-source branch row: zero diagonal forces off-diagonal pivoting.
        const a = [3][3]f64{
            .{ 1e-3, 0, 1 },
            .{ 0, 2e-3, -1 },
            .{ 1, -1, 0 },
        };
        const b = [3]f64{ 0, 0, 5 };
        const csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(3, a, b, &lu);
    }

    test "atto-siemens row keeps its own diagonal (BSIMSOI floating body)" {
        const gpa = testing.allocator;
        // A distilled BSIMSOI body block. Row/col 0 is the floating-body KCL
        // row, atto-siemens at default junction params; rows 1 and 2 are drain
        // and source, with Gmbs = 1 uS in the body column. The raw threshold
        // test rejects the body diagonal and pivots on the drain row, which
        // rebuilds the body equation from numbers 1e14 times its own size.
        const a = [4][4]f64{
            .{ 2.0e-20, -1.0e-20, -1.0e-20, 0.0 },
            .{ -1.0e-6, 1.0e3, -9.0e-4, 1.0e-3 },
            .{ 1.0e-6, -9.0e-4, 2.0e-3, -1.0e-3 },
            .{ 0.0, 0.0, -1.0e-3, 1.0 },
        };
        const x_true = [4]f64{ 0.03526, 0.9, 0.1, 1.1 };
        var b: [4]f64 = .{ 0, 0, 0, 0 };
        for (0..4) |i| for (0..4) |j| {
            b[i] += a[i][j] * x_true[j];
        };

        const csc = DenseCsc(4).from(a);
        var q = identity(4);
        var lu = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        // The body row must pivot its OWN column (step 0 factors column 0).
        // Without the row-scaled fallback it is pivoted LAST: pinv[0] == 3.
        try testing.expectEqual(@as(u32, 0), lu.pinv[0]);
        try testing.expect(lu.scaled_pivot[0]);

        var x: [4]f64 = undefined;
        lu.solve(&b, &x);
        // Measured: raw threshold gives x0 = 0.035260200093 (5.7e-6 relative) and
        // x2 off by 1.3e-9; the row-scaled choice is exact to 2e-15 on every
        // component. 1e-9 sits three orders clear of both.
        for (x, x_true) |xi, ref| try testing.expectApproxEqRel(ref, xi, 1e-9);

        // ...and the tape must be replayable: the raw growth monitor sees
        // |d| = 2e-20 against a column max of 1e-6 and would reject every refactor,
        // forcing a full factor per Newton iterate.
        try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
        lu.solve(&b, &x);
        for (x, x_true) |xi, ref| try testing.expectApproxEqRel(ref, xi, 1e-9);
    }

    test "refactor: same pattern, new values" {
        const gpa = testing.allocator;
        var a = [4][4]f64{
            .{ 4, 1, 0, 0 },
            .{ 1, 5, 2, 0 },
            .{ 0, 2, 6, 3 },
            .{ 0, 0, 3, 7 },
        };
        var csc = DenseCsc(4).from(a);
        var q = identity(4);
        var lu = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(4, a, .{ 1, 2, 3, 4 }, &lu);

        // Perturb values on the same pattern, refactor only
        a[1][1] = 9;
        a[2][3] = 1;
        csc = DenseCsc(4).from(a);
        try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
        try checkSolve(4, a, .{ 4, 3, 2, 1 }, &lu);
    }

    test "structurally void unknown gets a unit pivot, not SingularMatrix" {
        const gpa = testing.allocator;
        // Row/col 1 is entirely zero, a compact model's disabled branch-flow
        // unknown (HICUM `V(br_sht) <+ 0` at flsh = 0). The remaining 2x2 system
        // [[2,1],[1,3]] x = [5,7] has the solution (8/5, 9/5); x1 must come back 0.
        // DenseCsc drops exact zeros, so build the pattern by hand: the host always
        // forces the diagonal, and the per-device dense block leaves row/col 1
        // structurally present with zero values.
        const col_ptr = [4]u32{ 0, 3, 6, 9 };
        const row_idx = [9]u32{ 0, 1, 2, 0, 1, 2, 0, 1, 2 };
        const vals = [9]f64{ 2, 0, 1, 0, 0, 0, 1, 0, 3 };
        var q = identity(3);
        var lu = try SparseLu.init(gpa, 3, &col_ptr, &row_idx, &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3);
        try testing.expect(lu.void_col[1]);

        var x: [3]f64 = undefined;
        lu.solve(&[3]f64{ 5, 0, 7 }, &x);
        try testing.expectApproxEqAbs(@as(f64, 8.0 / 5.0), x[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), x[1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 9.0 / 5.0), x[2], 1e-12);

        // refactor must replay the fabricated pivot, not rediscover a zero and fail.
        const vals2 = [9]f64{ 4, 0, 1, 0, 0, 0, 1, 0, 5 };
        try lu.refactor(&col_ptr, &vals2, 0);
        lu.solve(&[3]f64{ 5, 0, 7 }, &x);
        try testing.expectApproxEqAbs(@as(f64, 18.0 / 19.0), x[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), x[1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 23.0 / 19.0), x[2], 1e-12);
    }

    test "refactor rejects activation of a fabricated pivot's row or column" {
        const gpa = testing.allocator;
        const col_ptr = [_]u32{ 0, 2, 4 };
        const row_idx = [_]u32{ 0, 1, 0, 1 };
        const updates = [_][4]f64{
            .{ 2, 0, 0, 4 }, // diagonal activates: solution must use 4, not unit pivot
            .{ 2, 1, 0, 0 }, // row alone activates: still singular
            .{ 2, 0, 1, 0 }, // column alone activates: still singular
            .{ 2, 1, 1, 0 }, // off-diagonal coupling activates: must re-pivot
        };
        for ([_][2]u32{ .{ 0, 1 }, .{ 1, 0 } }) |q| {
            var lu = try SparseLu.init(gpa, 2, &col_ptr, &row_idx, &q);
            defer lu.deinit(gpa);
            var fresh = try SparseLu.init(gpa, 2, &col_ptr, &row_idx, &q);
            defer fresh.deinit(gpa);
            for (updates) |vals| {
                try lu.factor(gpa, &col_ptr, &row_idx, &.{ 2, 0, 0, 0 }, 1e-3);
                try testing.expectError(error.SingularMatrix, lu.refactor(&col_ptr, &vals, 1e-12));
                fresh.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3) catch |err| {
                    try testing.expectError(err, lu.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3));
                    continue;
                };
                try lu.factor(gpa, &col_ptr, &row_idx, &vals, 1e-3);
                try testing.expectEqual(@as(usize, 0), lu.void_slots.items.len);
                var actual: [2]f64 = undefined;
                var expected: [2]f64 = undefined;
                lu.solve(&.{ 2, 4 }, &actual);
                fresh.solve(&.{ 2, 4 }, &expected);
                for (actual, expected) |v, ref| try testing.expectApproxEqAbs(ref, v, 1e-12);
            }
        }
    }

    test "a genuinely singular matrix is still rejected" {
        const gpa = testing.allocator;
        // Duplicate columns: the second column's reach holds no unpivoted row, but
        // its values are not zero, so voidUnknown must refuse to rescue it.
        const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
        const csc = DenseCsc(2).from(a);
        var q = identity(2);
        var lu = try SparseLu.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try testing.expectError(
            error.SingularMatrix,
            lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
        );
    }

    test "solveT: transpose solve matches A^T dense reference" {
        const gpa = testing.allocator;
        const a = [3][3]f64{
            .{ 1e-3, 0, 1 },
            .{ 0, 2e-3, -1 },
            .{ 1, -1, 0 },
        };
        const b = [3]f64{ 1, 2, 3 };
        const csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        // Reference: A^T dense solve
        var at: [3][3]f64 = undefined;
        for (0..3) |i| for (0..3) |j| {
            at[i][j] = a[j][i];
        };
        const xref = denseSolve(3, at, b);
        var x: [3]f64 = undefined;
        lu.solveT(&b, &x);
        for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
    }

    test "a singular full factor leaves w zero and the next factor exact" {
        // Column 1 is singular after eliminating column 0, while w[0] still
        // holds that column's U value. A stale w[0] would enter the next
        // factor as if it were part of the matrix.
        const gpa = testing.allocator;
        const col_ptr = [_]u32{ 0, 2, 4, 5 };
        const row_idx = [_]u32{ 0, 1, 0, 1, 2 };
        const singular = [_]f64{ 1, 1, 1, 1, 1 };
        const good = [_]f64{ 4, 1, 1, 3, 2 };
        const q3 = identity(3);
        var lu = try SparseLu.init(gpa, 3, &col_ptr, &row_idx, &q3);
        defer lu.deinit(gpa);
        try testing.expectError(error.SingularMatrix, lu.factor(gpa, &col_ptr, &row_idx, &singular, 1e-3));
        for (lu.w) |v| try testing.expectEqual(@as(f64, 0), v);

        try lu.factor(gpa, &col_ptr, &row_idx, &good, 1e-3);
        const b = [3]f64{ 5, 4, 2 };
        var x: [3]f64 = undefined;
        lu.solve(&b, &x);
        // [4 1 0; 1 3 0; 0 0 2] x = b  =>  x = [1, 1, 1]
        for (x) |xi| try testing.expectApproxEqAbs(@as(f64, 1), xi, 1e-14);
    }

    test "determinism: two factorizations byte-identical" {
        const gpa = testing.allocator;
        const a = [3][3]f64{
            .{ 2, 1, 0 },
            .{ 1, 3, 1 },
            .{ 0, 1, 4 },
        };
        const csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu1 = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu1.deinit(gpa);
        var lu2 = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu2.deinit(gpa);
        try lu1.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try lu2.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try testing.expectEqualSlices(f64, lu1.lx.items, lu2.lx.items);
        try testing.expectEqualSlices(f64, lu1.ux.items, lu2.ux.items);
        try testing.expectEqualSlices(f64, lu1.udiag, lu2.udiag);
        try testing.expectEqualSlices(u32, lu1.li.items, lu2.li.items);
        try testing.expectEqualSlices(u32, lu1.ui.items, lu2.ui.items);
    }

    test "scatterAxpy: bit-identical to the one-at-a-time oracle at every length" {
        // The pair-stepped kernel splits on length parity; cover both sides,
        // including lengths 0 and 1.
        var rng = std.Random.DefaultPrng.init(0x5EED);
        const r = rng.random();
        for (0..9) |len| {
            var idx: [9]u32 = undefined;
            var src: [9]f64 = undefined;
            for (0..len) |i| {
                idx[i] = @intCast(2 * i + 1); // distinct rows, as a CSC column is
                src[i] = r.float(f64) * 8 - 4;
            }
            var got = @as([20]f64, @splat(0));
            var want = @as([20]f64, @splat(0));
            for (&got, &want, 0..) |*g, *e, i| {
                g.* = @floatFromInt(i);
                e.* = g.*;
            }
            const f = r.float(f64) * 8 - 4;
            SparseLu.test_access.scatterAxpy(&got, &idx, &src, 0, @intCast(len), f);
            for (0..len) |p| want[idx[p]] -= src[p] * f;
            try testing.expectEqualSlices(f64, &want, &got);
        }
    }

    test "factor: supernode panels are bitwise the column-at-a-time refactor" {
        // A 24x24 grid Laplacian under AMD fills into supernodes with L
        // columns past panel_min_rows, so `factor` switches to its panel
        // loop. `refactor` replays the same U order one column at a time
        // (the scalar oracle); the panel kernels promise the same operations
        // per row in the same order, so the factors must match bit for bit.
        // Unknown `v` is void (structural zeros only) to cover a fabricated
        // pivot inside the supernodal loop.
        const gpa = testing.allocator;
        const k = 24;
        const n = k * k + 1;
        const v = k * k;
        var rng = std.Random.DefaultPrng.init(0x9A1E);
        const r = rng.random();
        var col_ptr: [n + 1]u32 = undefined;
        var row_idx: std.ArrayList(u32) = .empty;
        defer row_idx.deinit(gpa);
        var vals: std.ArrayList(f64) = .empty;
        defer vals.deinit(gpa);
        col_ptr[0] = 0;
        for (0..n) |j| {
            if (j == v) {
                for ([_]u32{ 3, 100, v }) |i| {
                    try row_idx.append(gpa, i);
                    try vals.append(gpa, 0);
                }
            } else {
                const x = j % k;
                const y = j / k;
                const nb = [_]?usize{
                    if (y > 0) j - k else null,
                    if (x > 0) j - 1 else null,
                    j,
                    if (x + 1 < k) j + 1 else null,
                    if (y + 1 < k) j + k else null,
                };
                for (nb) |o| if (o) |i| {
                    try row_idx.append(gpa, @intCast(i));
                    try vals.append(gpa, if (i == j) 4 + r.float(f64) else -0.5 - r.float(f64));
                };
                if (j == 3 or j == 100) {
                    try row_idx.append(gpa, v);
                    try vals.append(gpa, 0);
                }
            }
            col_ptr[j + 1] = @intCast(row_idx.items.len);
        }
        var q: [n]u32 = undefined;
        const ws_buf = try gpa.alloc(u32, order.wsSize(n, col_ptr[n]));
        defer gpa.free(ws_buf);
        var ws = order.Ws.init(ws_buf);
        try order.order(n, &col_ptr, row_idx.items, &q, &ws);

        var lu = try SparseLu.init(gpa, n, &col_ptr, row_idx.items, &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &col_ptr, row_idx.items, vals.items, 1e-3);
        try testing.expect(lu.panels.items.len > 0);
        const lx = try gpa.dupe(f64, lu.lx.items);
        defer gpa.free(lx);
        const ux = try gpa.dupe(f64, lu.ux.items);
        defer gpa.free(ux);
        const ud = try gpa.dupe(f64, lu.udiag);
        defer gpa.free(ud);
        try lu.refactor(&col_ptr, vals.items, 0);
        try testing.expectEqualSlices(f64, lx, lu.lx.items);
        try testing.expectEqualSlices(f64, ux, lu.ux.items);
        try testing.expectEqualSlices(f64, ud, lu.udiag);
        for (lu.w) |wi| try testing.expectEqual(@as(f64, 0), wi);

        // The reach is complete: A x = b holds for the factored system.
        var b: [n]f64 = undefined;
        for (&b) |*bi| bi.* = r.float(f64) - 0.5;
        var sol: [n]f64 = undefined;
        lu.solve(&b, &sol);
        var res = b;
        for (0..n) |j| for (col_ptr[j]..col_ptr[j + 1]) |p| {
            res[row_idx.items[p]] -= vals.items[p] * sol[j];
        };
        res[v] -= sol[v]; // the fabricated unit pivot
        const tol: f64 = 1e-12;
        for (res) |ri| try testing.expect(@abs(ri) < tol);
    }

    test "refactor and solve: the small-matrix tape is bitwise the column path" {
        // A random circuit-like matrix small enough for the tape: diagonal
        // entries, a few off-diagonals per column, a branch row with a
        // structural zero diagonal (off-diagonal pivot), and a void unknown.
        // Two factorizations of the same values; one refactors through the
        // tape, the other through `refactorColumns`, its scalar oracle.
        const gpa = testing.allocator;
        const n = 40;
        const v = n - 1; // void unknown
        const br = 7; // branch row: zero diagonal, +-1 couplings
        var rng = std.Random.DefaultPrng.init(0x7A9E);
        const r = rng.random();
        var dense: [n][n]bool = @splat(@splat(false));
        for (0..n - 1) |j| {
            dense[j][j] = j != br;
            for (0..3) |_| {
                const i = r.uintLessThan(usize, n - 1);
                dense[i][j] = true;
                dense[j][i] = true;
            }
        }
        dense[3][v] = true;
        dense[v][3] = true;
        dense[br][2] = true;
        dense[2][br] = true;
        var col_ptr: [n + 1]u32 = undefined;
        var row_idx: std.ArrayList(u32) = .empty;
        defer row_idx.deinit(gpa);
        col_ptr[0] = 0;
        for (0..n) |j| {
            for (0..n) |i| if (dense[i][j]) try row_idx.append(gpa, @intCast(i));
            col_ptr[j + 1] = @intCast(row_idx.items.len);
        }
        const nnz = row_idx.items.len;
        const vals = try gpa.alloc(f64, nnz);
        defer gpa.free(vals);
        var q: [n]u32 = undefined;
        const ws_buf = try gpa.alloc(u32, order.wsSize(n, col_ptr[n]));
        defer gpa.free(ws_buf);
        var ws = order.Ws.init(ws_buf);
        try order.order(n, &col_ptr, row_idx.items, &q, &ws);
        var a = try SparseLu.init(gpa, n, &col_ptr, row_idx.items, &q);
        defer a.deinit(gpa);
        var b = try SparseLu.init(gpa, n, &col_ptr, row_idx.items, &q);
        defer b.deinit(gpa);

        var failed: u32 = 0;
        for (0..8) |round| {
            for (0..n) |j| for (col_ptr[j]..col_ptr[j + 1]) |p| {
                const i = row_idx.items[p];
                vals[p] = if (i == v or j == v) 0 else if (i == br or j == br) (if (i < j) 1 else -1) else if (i == j) 5 + r.float(f64) else r.float(f64) - 0.5;
            };
            // Round 5 collapses one pivot, and only that round fails.
            if (round == 5) for (col_ptr[0]..col_ptr[1]) |p| {
                if (row_idx.items[p] == 0) vals[p] = 1e-30;
            };
            if (round == 0) {
                try a.factor(gpa, &col_ptr, row_idx.items, vals, 1e-3);
                try b.factor(gpa, &col_ptr, row_idx.items, vals, 1e-3);
                try testing.expect(a.tv.items.len != 0);
                try testing.expect(std.mem.indexOfScalar(bool, a.void_col, true) != null);
                b.tv.clearRetainingCapacity(); // b solves column by column
            }
            const ra = a.refactor(&col_ptr, vals, 1e-12);
            const rb = SparseLu.test_access.refactorColumns(&b, &col_ptr, vals, 1e-12);
            if (ra) |_| {
                try rb;
                try testing.expectEqualSlices(f64, b.lx.items, a.lx.items);
                try testing.expectEqualSlices(f64, b.ux.items, a.ux.items);
                try testing.expectEqualSlices(f64, b.udiag, a.udiag);
                // Solve: zeros and signed zeros exercise the skip.
                var rhs: [n]f64 = undefined;
                for (&rhs, 0..) |*x, i| x.* = switch (i % 5) {
                    0 => 0,
                    1 => -0.0,
                    else => r.float(f64) - 0.5,
                };
                var xa: [n]f64 = undefined;
                var xb: [n]f64 = undefined;
                a.solve(&rhs, &xa);
                b.solve(&rhs, &xb);
                try testing.expectEqualSlices(u8, std.mem.asBytes(&xb), std.mem.asBytes(&xa));
                // All -0: every entry skips; subtracting l * -0 would give +0.
                @memset(&rhs, -0.0);
                a.solve(&rhs, &xa);
                b.solve(&rhs, &xb);
                try testing.expectEqualSlices(u8, std.mem.asBytes(&xb), std.mem.asBytes(&xa));
            } else |e| {
                try testing.expectEqual(5, round);
                failed += 1;
                try testing.expectError(e, rb);
                try a.factor(gpa, &col_ptr, row_idx.items, vals, 1e-3);
                try b.factor(gpa, &col_ptr, row_idx.items, vals, 1e-3);
                b.tv.clearRetainingCapacity();
            }
            for (a.w) |wi| try testing.expectEqual(@as(f64, 0), wi);
        }
        try testing.expectEqual(1, failed);
    }

    test "w is all-zero after factor, after refactor, and after a failed refactor" {
        // `factor` reads 0 from every fill row it does not scatter, so every
        // call must hand `w` back clean. The failed refactor matters most: it
        // is what sends direct.zig to a full factor.
        const gpa = testing.allocator;
        var a = [3][3]f64{
            .{ 10, 1, 0 },
            .{ 1, 10, 1 },
            .{ 0, 1, 10 },
        };
        var csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        for (lu.w) |v| try testing.expectEqual(@as(f64, 0), v);

        try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
        for (lu.w) |v| try testing.expectEqual(@as(f64, 0), v);

        // Collapse every diagonal: the growth monitor rejects the replay mid-way.
        a[0][0] = 1e-20;
        a[1][1] = 1e-20;
        a[2][2] = 1e-20;
        csc = DenseCsc(3).from(a);
        try testing.expectError(
            error.SingularMatrix,
            lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-6),
        );
        for (lu.w) |v| try testing.expectEqual(@as(f64, 0), v);

        // The full factor that follows must match a fresh solver's.
        var fresh = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer fresh.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try fresh.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try testing.expectEqualSlices(f64, fresh.lx.items, lu.lx.items);
        try testing.expectEqualSlices(f64, fresh.ux.items, lu.ux.items);
        try testing.expectEqualSlices(f64, fresh.udiag, lu.udiag);
    }

    test "an off-diagonal pivot hands its diagonal to the column that lost one" {
        const gpa = testing.allocator;
        // Column 0 must pivot on row 1. Column 1 then gets row 0, which
        // passes the threshold, not its column max (row 2).
        const a = [3][3]f64{
            .{ 1e-9, 1, 0 },
            .{ 1, 1e-9, 0 },
            .{ 0, 5, 1 },
        };
        var csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try testing.expectEqualSlices(u32, &.{ 1, 0, 2 }, lu.pinv);
        try checkSolve(3, a, .{ 1, 2, 3 }, &lu);
    }

    test "a re-pivot past the fill cap keeps the previous pivots" {
        const gpa = testing.allocator;
        var a = [4][4]f64{
            .{ 2, -1, 0, 0 },
            .{ -1, 2, -1, 0 },
            .{ 0, -1, 2, -1 },
            .{ 0, 0, -1, 2 },
        };
        var csc = DenseCsc(4).from(a);
        const nnz = csc.nnz();
        var q = identity(4);
        var capped = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..nnz], &q);
        defer capped.deinit(gpa);
        var free = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..nnz], &q);
        defer free.deinit(gpa);
        capped.fill_cap = 1;
        try capped.factor(gpa, &csc.col_ptr, csc.row_idx[0..nnz], csc.vals[0..nnz], 1e-3);
        try free.factor(gpa, &csc.col_ptr, csc.row_idx[0..nnz], csc.vals[0..nnz], 1e-3);
        const base = capped.li.items.len + capped.ui.items.len;

        // A collapsed diagonal: threshold pivoting leaves it and fills.
        a[0][0] = 1e-5;
        csc = DenseCsc(4).from(a);
        try free.factor(gpa, &csc.col_ptr, csc.row_idx[0..nnz], csc.vals[0..nnz], 1e-3);
        try testing.expect(free.li.items.len + free.ui.items.len > base);
        try capped.factor(gpa, &csc.col_ptr, csc.row_idx[0..nnz], csc.vals[0..nnz], 1e-3);
        try testing.expectEqual(base, capped.li.items.len + capped.ui.items.len);
        try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, capped.pinv);
        var x: [4]f64 = undefined;
        capped.solve(&.{ 1, 2, 3, 4 }, &x);
        for (x, denseSolve(4, a, .{ 1, 2, 3, 4 })) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-8);
    }

    test "solve and solveT in-place (b aliases x)" {
        const gpa = testing.allocator;
        const a = [2][2]f64{ .{ 3, 1 }, .{ 1, 2 } };
        const csc = DenseCsc(2).from(a);
        var q = identity(2);
        var lu = try SparseLu.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        const b = [2]f64{ 7, 5 };
        const xref = denseSolve(2, a, b);

        // In-place solve: x and b point to the same memory
        var x = b;
        lu.solve(&x, &x);
        try testing.expectApproxEqAbs(xref[0], x[0], 1e-12);
        try testing.expectApproxEqAbs(xref[1], x[1], 1e-12);
    }

    test "SparseLu construction releases storage on every allocation failure" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(gpa: Allocator) !void {
                var lu = try SparseLu.init(gpa, 3, &.{ 0, 3, 6, 9 }, &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 }, &.{ 0, 1, 2 });
                defer lu.deinit(gpa);
            }
        }.run, .{});
    }
};

const TridiagTests = struct {
    const impl = @import("root.zig").tridiag;
    const TriDiag = impl.TriDiag;
    const isTridiag = impl.isTridiag;

    const a4 = [4][4]f64{
        .{ 4, 1, 0, 0 },
        .{ 1, 5, 2, 0 },
        .{ 0, 1, 6, 3 },
        .{ 0, 0, 2, 7 },
    };

    test "TriDiag: solve and solveT match dense references" {
        const gpa = testing.allocator;
        const csc = DenseCsc(4).from(a4);
        var td = try TriDiag.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
        defer td.deinit(gpa);
        try td.factor(csc.vals[0..csc.nnz()]);

        const rhs = [4]f64{ 7, 13, 20, 23 };
        var x = rhs;
        td.solve(&x);
        for (denseSolve(4, a4, rhs), x) |ref, xi| try testing.expectApproxEqAbs(ref, xi, 1e-12);

        var at: [4][4]f64 = undefined;
        for (0..4) |i| for (0..4) |j| {
            at[i][j] = a4[j][i];
        };
        x = rhs;
        td.solveT(&x);
        for (denseSolve(4, at, rhs), x) |ref, xi| try testing.expectApproxEqAbs(ref, xi, 1e-12);
    }

    test "TriDiag: a zero pivot fails the factor" {
        const gpa = testing.allocator;
        const a = [3][3]f64{ .{ 1, 1, 0 }, .{ 1, 1, 0 }, .{ 0, 0, 1 } };
        const csc = DenseCsc(3).from(a);
        var td = try TriDiag.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()]);
        defer td.deinit(gpa);
        try testing.expectError(error.SingularMatrix, td.factor(csc.vals[0..csc.nnz()]));
    }

    test "isTridiag: accepts band 1 from n = 3, rejects wider or smaller" {
        const csc = DenseCsc(4).from(a4);
        try testing.expect(isTridiag(4, &csc.col_ptr, csc.row_idx[0..csc.nnz()]));
        var wide = a4;
        wide[0][2] = 1;
        const wcsc = DenseCsc(4).from(wide);
        try testing.expect(!isTridiag(4, &wcsc.col_ptr, wcsc.row_idx[0..wcsc.nnz()]));
        try testing.expect(!isTridiag(2, &.{ 0, 1, 2 }, &.{ 0, 1 }));
    }
};

/// The device LU's kernel bodies (lu_kernels.zig) on host threads against
/// their oracle, `refactorColumns` plus `solve`: bitwise, with the refactor
/// on one thread (every ticket in order) and on four (real waits).
/// docs/solvers/gpu-lu.md §4.6.
const LuKernelTests = struct {
    const SparseLu = @import("root.zig").sparse_lu.SparseLu;
    const K = @import("root.zig").lu_kernels;
    const order = @import("root.zig").order;

    const Case = struct {
        n: u32,
        col_ptr: []u32,
        row_idx: []u32,
        q: []u32,
        fn deinit(c: *Case, gpa: std.mem.Allocator) void {
            gpa.free(c.col_ptr);
            gpa.free(c.row_idx);
            gpa.free(c.q);
        }
    };

    /// Circuit-like pattern: random local couplings, a rail node coupled
    /// to most unknowns (a wide U column once AMD defers it), a branch row
    /// with a zero diagonal, and a void unknown.
    fn circuit(gpa: std.mem.Allocator, n: u32, seed: u64) !Case {
        var rng = std.Random.DefaultPrng.init(seed);
        const r = rng.random();
        const v = n - 1;
        const rail = n - 2;
        const br = 5;
        const dense = try gpa.alloc(bool, n * n);
        defer gpa.free(dense);
        @memset(dense, false);
        for (0..n - 1) |j| {
            dense[j * n + j] = j != br;
            // Couplings stay inside clusters of 6, so the rail's U column
            // is wide and shallow, the shape the gather form is for.
            for (0..2) |_| {
                const i = @min(@as(u32, @intCast(j / 6 * 6)) + r.uintLessThan(u32, 6), n - 3);
                dense[i * n + j] = true;
                dense[j * n + i] = true;
            }
            if (j % 3 != 0) {
                dense[rail * n + j] = true;
                dense[j * n + rail] = true;
            }
        }
        dense[3 * n + v] = true;
        dense[v * n + 3] = true;
        dense[br * n + 2] = true;
        dense[2 * n + br] = true;
        var rows: std.ArrayList(u32) = .empty;
        errdefer rows.deinit(gpa);
        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        col_ptr[0] = 0;
        for (0..n) |j| {
            for (0..n) |i| if (dense[i * n + j]) try rows.append(gpa, @intCast(i));
            col_ptr[j + 1] = @intCast(rows.items.len);
        }
        const q = try gpa.alloc(u32, n);
        errdefer gpa.free(q);
        const ws_buf = try gpa.alloc(u32, order.wsSize(n, col_ptr[n]));
        defer gpa.free(ws_buf);
        var ws = order.Ws.init(ws_buf);
        const row_idx = try rows.toOwnedSlice(gpa);
        errdefer gpa.free(row_idx);
        try order.order(n, col_ptr, row_idx, q, &ws);
        return .{ .n = n, .col_ptr = col_ptr, .row_idx = row_idx, .q = q };
    }

    fn values(c: Case, r: std.Random, vals: []f64) void {
        const v = c.n - 1;
        const br = 5;
        for (0..c.n) |j| for (c.col_ptr[j]..c.col_ptr[j + 1]) |p| {
            const i = c.row_idx[p];
            vals[p] = if (i == v or j == v) 0 else if (i == br or j == br) (if (i < j) 1 else -1) else if (i == j) 4 + r.float(f64) else r.float(f64) - 0.5;
        };
    }

    /// Refactors `vals` with the oracle and with the kernels (1 and 4
    /// threads, scratch and in-place columns); both must fail at the same
    /// step or agree bitwise. Returns whether the oracle succeeded.
    fn expectMatch(gpa: std.mem.Allocator, lu: *SparseLu, c: Case, tb: K.Tables, vals: []const f64, rhs: []const f64, stamp: *u32) !bool {
        const n = c.n;
        const t = tb.tab;
        const val = try gpa.alloc(f64, t.n_val);
        defer gpa.free(val);
        const y = try gpa.alloc(f64, n);
        defer gpa.free(y);
        const dx = try gpa.alloc(f64, n);
        defer gpa.free(dx);
        const sync = try gpa.alloc(u32, t.syncLen());
        defer gpa.free(sync);
        @memset(sync, 0);
        const ok = if (SparseLu.test_access.refactorColumns(lu, c.col_ptr, vals, t.growth)) |_| true else |_| false;
        const neg = try gpa.alloc(f64, n);
        defer gpa.free(neg);
        for (neg, rhs) |*o, b| o.* = -b;
        const ref = try gpa.alloc(f64, n);
        defer gpa.free(ref);
        if (ok) lu.solve(neg, ref);
        // Shared-scratch columns on 1 and 4 threads; every column in `val`.
        inline for (.{ .{ K.col_max, 1 }, .{ K.col_max, 4 }, .{ 0, 4 } }) |run| {
            stamp.* += 1;
            const fail = try K.runHostCap(run[0], t, .{ .idx = tb.idx, .val = val, .a = vals, .rhs = rhs, .y = y, .dx = dx, .sync = sync }, stamp.*, run[1]);
            try testing.expectEqual(ok, fail == null);
            // Every step below the failing one holds the oracle's values.
            for (0..fail orelse n) |k| {
                const base = tb.idx[t.coff + k];
                const nuk = lu.up[k + 1] - lu.up[k];
                const nlk = lu.lp[k + 1] - lu.lp[k];
                try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(lu.ux.items[lu.up[k]..lu.up[k + 1]]), std.mem.sliceAsBytes(val[base..][0..nuk]));
                try testing.expectEqual(@as(u64, @bitCast(lu.udiag[k])), @as(u64, @bitCast(val[base + nuk])));
                try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(lu.lx.items[lu.lp[k]..lu.lp[k + 1]]), std.mem.sliceAsBytes(val[base + nuk + 1 ..][0..nlk]));
            }
            if (ok) try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ref), std.mem.sliceAsBytes(dx));
        }
        return ok;
    }

    test "lu kernels: host threads are bitwise refactorColumns + solve, failures included" {
        const gpa = testing.allocator;
        var c = try circuit(gpa, 300, 0x11C0);
        defer c.deinit(gpa);
        const nnz = c.col_ptr[c.n];
        const vals = try gpa.alloc(f64, nnz);
        defer gpa.free(vals);
        const rhs = try gpa.alloc(f64, c.n);
        defer gpa.free(rhs);
        var rng = std.Random.DefaultPrng.init(0x5EED);
        const r = rng.random();
        var lu = try SparseLu.init(gpa, c.n, c.col_ptr, c.row_idx, c.q);
        defer lu.deinit(gpa);
        values(c, r, vals);
        try lu.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
        try testing.expect(std.mem.indexOfScalar(bool, lu.void_col, true) != null);
        // Solves all head (the cost model's pick here), half tail, all tail.
        var failed: u32 = 0;
        for ([_]?u32{ null, c.n / 2, 0 }) |tail| {
            var tb = try K.build(gpa, &lu, c.col_ptr, 1e-12, .{ .tail = tail });
            defer tb.deinit(gpa);
            // Some column (the rail's) took the gather form, not all of them.
            const wlev = tb.idx[tb.tab.wlev..][0 .. c.n + 1];
            var gathered: u32 = 0;
            for (0..c.n) |k| gathered += @intFromBool(wlev[k] != wlev[k + 1]);
            try testing.expect(gathered > 0 and gathered < c.n);

            var stamp: u32 = 0;
            for (0..6) |round| {
                values(c, r, vals);
                for (rhs, 0..) |*x, i| x.* = switch (i % 5) {
                    0 => 0,
                    1 => -0.0,
                    else => r.float(f64) - 0.5,
                };
                // Round 3 puts the first step from 40 on with an A entry
                // below its pivot under the growth limit: those grow 1e20.
                if (round == 3) {
                    var k: u32 = 40;
                    while (true) : (k += 1) {
                        var hit = false;
                        for (c.col_ptr[c.q[k]]..c.col_ptr[c.q[k] + 1]) |p| if (lu.prow[p] > k) {
                            vals[p] *= 1e20;
                            hit = true;
                        };
                        if (hit) break;
                    }
                }
                if (!try expectMatch(gpa, &lu, c, tb, vals, rhs, &stamp)) failed += 1;
            }
        }
        try testing.expectEqual(3, failed);
    }

    test "lu kernels: HostRefactor on io tasks is bitwise refactor, failures included" {
        const gpa = testing.allocator;
        var c = try circuit(gpa, 300, 0x7A5C);
        defer c.deinit(gpa);
        const vals = try gpa.alloc(f64, c.col_ptr[c.n]);
        defer gpa.free(vals);
        var rng = std.Random.DefaultPrng.init(0xB17);
        const r = rng.random();
        var a = try SparseLu.init(gpa, c.n, c.col_ptr, c.row_idx, c.q);
        defer a.deinit(gpa);
        var b = try SparseLu.init(gpa, c.n, c.col_ptr, c.row_idx, c.q);
        defer b.deinit(gpa);
        values(c, r, vals);
        try a.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
        try b.factor(gpa, c.col_ptr, c.row_idx, vals, 1e-3);
        var hr = try K.HostRefactor.init(gpa, &a, c.col_ptr, 1e-12);
        defer hr.deinit(gpa);
        // Inline tasks (no async threads) and four real ones.
        for ([_]std.Io.Limit{ .nothing, .limited(4) }) |limit| {
            var threaded = std.Io.Threaded.init(gpa, .{ .async_limit = limit });
            defer threaded.deinit();
            for (0..4) |round| {
                values(c, r, vals);
                if (round == 2) {
                    // A column with an entry below its pivot grows 1e20.
                    var k: u32 = 40;
                    while (true) : (k += 1) {
                        var hit = false;
                        for (c.col_ptr[c.q[k]]..c.col_ptr[c.q[k] + 1]) |p| if (a.prow[p] > k) {
                            vals[p] *= 1e20;
                            hit = true;
                        };
                        if (hit) break;
                    }
                }
                const ref = b.refactor(c.col_ptr, vals, 1e-12);
                const got = hr.run(&a, vals, threaded.io(), 4);
                if (ref) |_| {
                    try got;
                    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(b.ux.items), std.mem.sliceAsBytes(a.ux.items));
                    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(b.udiag), std.mem.sliceAsBytes(a.udiag));
                    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(b.lx.items), std.mem.sliceAsBytes(a.lx.items));
                } else |e| {
                    try testing.expectEqual(2, round);
                    try testing.expectError(e, got);
                }
            }
        }
    }

    test "lu kernels: a scale-accepted pivot skips the growth monitor on the device too" {
        const gpa = testing.allocator;
        // The BSIMSOI body block of "atto-siemens row keeps its own diagonal".
        const a = [4][4]f64{
            .{ 2.0e-20, -1.0e-20, -1.0e-20, 0.0 },
            .{ -1.0e-6, 1.0e3, -9.0e-4, 1.0e-3 },
            .{ 1.0e-6, -9.0e-4, 2.0e-3, -1.0e-3 },
            .{ 0.0, 0.0, -1.0e-3, 1.0 },
        };
        var csc = DenseCsc(4).from(a);
        var q = identity(4);
        const c: Case = .{ .n = 4, .col_ptr = &csc.col_ptr, .row_idx = csc.row_idx[0..csc.nnz()], .q = &q };
        var lu = try SparseLu.init(gpa, 4, c.col_ptr, c.row_idx, &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, c.col_ptr, c.row_idx, csc.vals[0..csc.nnz()], 1e-3);
        try testing.expect(lu.scaled_pivot[0]);
        var tb = try K.build(gpa, &lu, c.col_ptr, 1e-12, .{});
        defer tb.deinit(gpa);
        var stamp: u32 = 0;
        try testing.expect(try expectMatch(gpa, &lu, c, tb, csc.vals[0..csc.nnz()], &.{ 1, -2, 0.5, 3 }, &stamp));
    }
};

test {
    _ = BbdTests;
    _ = ConvergerTests;
    _ = DenseLuTests;
    _ = DirectTests;
    _ = FftTests;
    _ = FreqSolveTests;
    _ = GmresTests;
    _ = LaneLuTests;
    _ = LuKernelTests;
    _ = OrderTests;
    _ = SparseTests;
    _ = TridiagTests;
}
