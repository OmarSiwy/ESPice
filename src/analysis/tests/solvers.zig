const BbdTests = struct {
    const impl = @import("solvers").bbd;
    const Allocator = std.mem.Allocator;
    const Bbd = impl.Bbd;
    const Limits = impl.Limits;
    const root = @import("solvers").types;
    const std = @import("std");

    // ============================================================================
    // Tests — synthetic BBD systems validated against the flat sparse LU through
    // the public direct.Solver facade (bbd=null → flat path).
    // ============================================================================

    const testing = std.testing;

    const direct = @import("solvers").direct;

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
                blocks[bi] = .{ .start = st, .size = s, .type_id = 0, .instance_id = @intCast(bi + 1) };
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

    fn expectMatchesFlat(gpa: Allocator, sy: *const Synth, eng: *Bbd(f64)) !void {
        var flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
        defer flat.deinit();
        try flat.factor(sy.vals);
        try eng.factor(sy.vals);

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
        var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try expectMatchesFlat(gpa, &sy, &eng);
    }

    test "bbd: block with empty border footprint (m_i = 0)" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 7, .{ .decoupled_block = 1 });
        defer sy.free(gpa);
        var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try testing.expectEqual(@as(u32, 0), eng.blk_m[1]);
        try expectMatchesFlat(gpa, &sy, &eng);
    }

    test "bbd: b = 1 (ground-only border, fully decoupled blocks)" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 4, 3, 0, 11, .{});
        defer sy.free(gpa);
        var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try testing.expectEqual(@as(u32, 1), eng.b);
        try expectMatchesFlat(gpa, &sy, &eng);
    }

    test "bbd: singular block reports SingularMatrix from factor" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 13, .{ .singular_block = 1 });
        defer sy.free(gpa);
        var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();
        try testing.expectError(error.SingularMatrix, eng.factor(sy.vals));
    }

    test "bbd: cross-block entry -> NotApplicable" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 17, .{ .cross_entry = true });
        defer sy.free(gpa);
        try testing.expectError(
            error.NotApplicable,
            Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed),
        );
    }

    test "bbd: production limits reject small block counts" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 3, 4, 3, 19, .{});
        defer sy.free(gpa);
        try testing.expectError(
            error.NotApplicable,
            Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, .{}),
        );
    }

    test "bbd: std.Io block factors, failures and recovery match serial bitwise" {
        const gpa = testing.allocator;
        var sy = try Synth.build(gpa, 17, 32, 3, 23, .{});
        defer sy.free(gpa);
        var eng = try Bbd(f64).init(gpa, sy.n, sy.col_ptr, sy.row_idx, sy.info, relaxed);
        defer eng.deinit();

        try eng.factor(sy.vals);
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
                try eng.factor(sy.vals);
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

        try s_bbd.factor(sy.vals);
        try s_flat.factor(sy.vals);

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
        try s.factor(sy.vals);
        try testing.expect(s.bbd_eng == null);
        try testing.expect(s.lu != null);

        var flat = try direct.Solver.init(gpa, sy.n, sy.col_ptr, sy.row_idx, null);
        defer flat.deinit();
        try flat.factor(sy.vals);

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
        try s.factor(sy.vals);
        try testing.expect(s.bbd_eng == null);
        s.solve(b_rhs, x);
        for (x, x_ref) |xi, ri| try testing.expectApproxEqAbs(ri, xi, 1e-11);
    }
};

const ConvergerTests = struct {
    const impl = @import("solvers").converger;
    const Workspace = impl.Workspace;
    const jfnk = impl.jfnk;
    const newton = impl.newton;
    const std = @import("std");

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
};

const DenseLuTests = struct {
    const impl = @import("solvers").dense_lu;
    const DenseLu = impl.DenseLu;
    const buildComplexAdmittance = impl.buildComplexAdmittance;
    const factorize = impl.factorize;
    const factorizeSolve = impl.factorizeSolve;
    const factorizeSolveNeg = impl.factorizeSolveNeg;
    const solveFactored = impl.solveFactored;
    const solveFactoredT = impl.solveFactoredT;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

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

    test "dense_lu: f32 instantiation solves the same system" {
        const LU32 = DenseLu(f32);
        var a = [_]f32{
            2, 1, 0,
            0, 3, 1,
            1, 0, 4,
        };
        const b = [_]f32{ 5, 7, 10 };
        var x: [3]f32 = undefined;
        try LU32.factorizeSolve(3, &a, &b, &x);

        const orig = [_]f32{ 2, 1, 0, 0, 3, 1, 1, 0, 4 };
        for (0..3) |row| {
            var sum: f32 = 0;
            for (0..3) |col| sum += orig[row * 3 + col] * x[col];
            try testing.expectApproxEqAbs(b[row], sum, 1e-4);
        }
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

    test "dense_lu: 1x1 system" {
        var a = [_]f64{3.0};
        const b = [_]f64{9.0};
        var x: [1]f64 = undefined;
        try factorizeSolve(1, &a, &b, &x);
        try testing.expectApproxEqAbs(@as(f64, 3.0), x[0], 1e-12);
    }

    test "dense_lu: identity matrix preserves RHS" {
        const n: usize = 5;
        var a = [_]f64{0} ** (n * n);
        for (0..n) |i| a[i * n + i] = 1.0;
        const b = [_]f64{ 1, 2, 3, 4, 5 };
        var x: [n]f64 = undefined;
        try factorizeSolve(n, &a, &b, &x);
        for (0..n) |i| try testing.expectApproxEqAbs(b[i], x[i], 1e-12);
    }
};

const DirectTests = struct {
    const impl = @import("solvers").direct;
    const Allocator = std.mem.Allocator;
    const Solver = impl.Solver;
    const sparse_lu = @import("solvers").sparse_lu;
    const std = @import("std");

    test "solver construction releases storage on every allocation failure" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(gpa: Allocator) !void {
                var solver = try Solver.initParams(gpa, 3, &.{ 0, 1, 2, 3 }, &.{ 0, 1, 2 }, null, .{ .iter_refine_steps = 1 });
                defer solver.deinit();
            }
        }.run, .{});
    }

    // ============================================================================
    // Tests — Solver facade: factor/solve/refactor, MNA structural zero diag,
    // singular detection, solveT correctness, determinism.
    // ============================================================================

    const testing = std.testing;

    const DenseCsc = SparseTests.DenseCsc;

    const denseSolve = SparseTests.denseSolve;

    const naturalOrder = SparseTests.identity;

    const checkSolve = SparseTests.checkSolve;

    test "Solver: factor + solveNeg + refactor on fixed pattern" {
        const gpa = testing.allocator;
        // ponytail: reuse the fixed-size CSC fixture; allocate only for runtime-sized cases.
        var csc = DenseCsc(2).from(.{ .{ 2, 1 }, .{ 1, 3 } });
        const col_ptr = &csc.col_ptr;
        const row_idx = csc.row_idx[0..csc.nnz()];
        const vals = csc.vals[0..csc.nnz()];

        var s = try Solver.init(gpa, 2, col_ptr, row_idx, null);
        defer s.deinit();
        try s.factor(vals);
        var x: [2]f64 = undefined;
        s.solveNeg(&.{ 5, 7 }, &x);
        try testing.expectApproxEqAbs(@as(f64, -1.6), x[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, -1.8), x[1], 1e-12);

        // new values, same pattern -> refactor path
        vals[0] = 4;
        vals[3] = 5; // [4 1; 1 5]
        try s.factor(vals);
        s.solveNeg(&.{ 9, 11 }, &x);
        try testing.expectApproxEqAbs(@as(f64, -34.0 / 19.0), x[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, -35.0 / 19.0), x[1], 1e-12);
    }

    test "factor + solve on an MNA-like system with a structural zero diagonal" {
        const a = [3][3]f64{
            .{ 1e-3, 0, 1 },
            .{ 0, 2e-3, -1 },
            .{ 1, -1, 0 },
        };
        const b = [3]f64{ 0, 0, 5 };
        const csc = DenseCsc(3).from(a);
        const gpa = testing.allocator;
        const SparseLu = sparse_lu.SparseLu(f64);
        const q3 = naturalOrder(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(3, a, b, &lu);
    }

    test "refactor: same pattern, new values, no allocation" {
        var a = [4][4]f64{
            .{ 4, 1, 0, 0 },
            .{ 1, 5, 2, 0 },
            .{ 0, 2, 6, 3 },
            .{ 0, 0, 3, 7 },
        };
        const gpa = testing.allocator;
        var csc = DenseCsc(4).from(a);
        const SparseLu = sparse_lu.SparseLu(f64);
        const q4 = naturalOrder(4);
        var lu = try SparseLu.init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q4);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(4, a, .{ 1, 2, 3, 4 }, &lu);

        // perturb values on the same pattern, refactor only
        a[1][1] = 9;
        a[2][3] = 1;
        csc = DenseCsc(4).from(a);
        try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-12);
        try checkSolve(4, a, .{ 4, 3, 2, 1 }, &lu);
    }

    test "singular matrix reported, refactor pivot collapse reported" {
        const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
        const csc = DenseCsc(2).from(a);
        const gpa = testing.allocator;
        const SparseLu = sparse_lu.SparseLu(f64);
        const q2 = naturalOrder(2);
        var lu = try SparseLu.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q2);
        defer lu.deinit(gpa);
        try testing.expectError(
            error.SingularMatrix,
            lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
        );
    }

    test "solveT: transpose solve matches A^T dense solve" {
        const a = [3][3]f64{
            .{ 1e-3, 0, 1 },
            .{ 0, 2e-3, -1 },
            .{ 1, -1, 0 },
        };
        const b = [3]f64{ 1, 2, 3 };
        const csc = DenseCsc(3).from(a);
        const gpa = testing.allocator;
        const SparseLu = sparse_lu.SparseLu(f64);
        const q3 = naturalOrder(3);
        var lu = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        var at: [3][3]f64 = undefined;
        for (0..3) |i| for (0..3) |j| {
            at[i][j] = a[j][i];
        };
        const xref = denseSolve(3, at, b);
        var x: [3]f64 = undefined;
        lu.solveT(&b, &x);
        for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
    }

    test "determinism: two factorizations of the same values are byte-identical" {
        const a = [3][3]f64{
            .{ 2, 1, 0 },
            .{ 1, 3, 1 },
            .{ 0, 1, 4 },
        };
        const csc = DenseCsc(3).from(a);
        const gpa = testing.allocator;
        const SparseLu = sparse_lu.SparseLu(f64);
        const q3 = naturalOrder(3);
        var lu1 = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
        defer lu1.deinit(gpa);
        var lu2 = try SparseLu.init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q3);
        defer lu2.deinit(gpa);
        try lu1.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try lu2.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try testing.expectEqualSlices(u32, lu1.q, lu2.q);
        try testing.expectEqualSlices(f64, lu1.lx.items, lu2.lx.items);
        try testing.expectEqualSlices(f64, lu1.ux.items, lu2.ux.items);
        try testing.expectEqualSlices(f64, lu1.udiag, lu2.udiag);
    }
};

const FftTests = struct {
    const impl = @import("solvers").fft;
    const Fft = impl.Fft;
    const bluestein = impl.bluestein;
    const bluesteinSize = impl.bluesteinSize;
    const fft = impl.fft;
    const fftReal = impl.fftReal;
    const ifft = impl.ifft;
    const math = std.math;
    const nextPow2 = impl.nextPow2;
    const std = @import("std");

    // ============================================================================
    // Tests — impulse, DC, sinusoid, Parseval, round-trip, Bluestein, fftReal
    // ============================================================================

    const testing = std.testing;

    test "fft: impulse response is flat spectrum" {
        var re = [_]f64{ 1, 0, 0, 0, 0, 0, 0, 0 };
        var im = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
        fft(&re, &im);
        for (re) |v| try testing.expectApproxEqAbs(@as(f64, 1.0), v, 1e-14);
        for (im) |v| try testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-14);
    }

    test "fft: DC signal has energy only in bin 0" {
        var re = [_]f64{ 3, 3, 3, 3 };
        var im = [_]f64{ 0, 0, 0, 0 };
        fft(&re, &im);
        try testing.expectApproxEqAbs(@as(f64, 12.0), re[0], 1e-13);
        try testing.expectApproxEqAbs(@as(f64, 0.0), im[0], 1e-13);
        for (1..4) |k| {
            try testing.expectApproxEqAbs(@as(f64, 0.0), re[k], 1e-13);
            try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-13);
        }
    }

    test "fft: pure sinusoid at bin 1 (N=8)" {
        const n = 8;
        var re: [n]f64 = undefined;
        var im = [_]f64{0} ** n;
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
        var im = [_]f64{0} ** n;
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

    test "fft: Parseval's theorem (N=64)" {
        const n = 64;
        var re: [n]f64 = undefined;
        var im = [_]f64{0} ** n;
        for (0..n) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            re[k] = @sin(2.0 * math.pi * 3.0 * t) + 0.5 * @cos(2.0 * math.pi * 7.0 * t);
        }
        var e_time: f64 = 0;
        for (re) |v| e_time += v * v;

        fft(&re, &im);

        var e_freq: f64 = 0;
        for (re, im) |r, i| e_freq += r * r + i * i;
        e_freq /= @as(f64, @floatFromInt(n));

        try testing.expectApproxEqRel(e_time, e_freq, 1e-12);
    }

    test "fft/ifft: round-trip recovers original signal" {
        const n = 32;
        var re: [n]f64 = undefined;
        var im = [_]f64{0} ** n;
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

    test "fft: f32 instantiation — round-trip and Parseval" {
        const F32 = Fft(f32);
        const n = 256;
        var re: [n]f32 = undefined;
        var im = [_]f32{0} ** n;
        var orig: [n]f32 = undefined;
        for (0..n) |k| {
            const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            re[k] = @sin(2.0 * math.pi * 5.0 * t) + 0.3 * @cos(2.0 * math.pi * 11.0 * t);
            orig[k] = re[k];
        }
        var e_time: f64 = 0;
        for (re) |v| e_time += @as(f64, v) * @as(f64, v);

        F32.fft(&re, &im);

        var e_freq: f64 = 0;
        for (re, im) |r, i| e_freq += @as(f64, r) * r + @as(f64, i) * i;
        e_freq /= @as(f64, @floatFromInt(n));
        try testing.expectApproxEqRel(e_time, e_freq, 1e-4);

        F32.ifft(&re, &im);
        for (0..n) |k| {
            try testing.expectApproxEqAbs(orig[k], re[k], 1e-4);
            try testing.expectApproxEqAbs(@as(f32, 0.0), im[k], 1e-4);
        }
    }

    test "fft: large N=1024 — Parseval and bin accuracy" {
        const n = 1024;
        var re: [n]f64 = undefined;
        var im = [_]f64{0} ** n;
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

    test "bluestein: matches radix-2 FFT on power-of-2 input" {
        const n = 8;
        var re1 = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
        var im1 = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
        var re2 = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8 };
        var im2 = [_]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };

        fft(&re1, &im1);

        const m = comptime bluesteinSize(n);
        var scratch_re: [m]f64 = undefined;
        var scratch_im: [m]f64 = undefined;
        var chirp_re: [m]f64 = undefined;
        var chirp_im: [m]f64 = undefined;
        bluestein(&re2, &im2, &scratch_re, &scratch_im, &chirp_re, &chirp_im);

        for (0..n) |k| {
            try testing.expectApproxEqAbs(re1[k], re2[k], 1e-10);
            try testing.expectApproxEqAbs(im1[k], im2[k], 1e-10);
        }
    }

    test "bluestein: non-power-of-2 — impulse is flat" {
        const n = 7;
        var re = [_]f64{ 1, 0, 0, 0, 0, 0, 0 };
        var im = [_]f64{ 0, 0, 0, 0, 0, 0, 0 };

        const m = comptime bluesteinSize(n);
        var scratch_re: [m]f64 = undefined;
        var scratch_im: [m]f64 = undefined;
        var chirp_re: [m]f64 = undefined;
        var chirp_im: [m]f64 = undefined;
        bluestein(&re, &im, &scratch_re, &scratch_im, &chirp_re, &chirp_im);

        for (0..n) |k| {
            try testing.expectApproxEqAbs(@as(f64, 1.0), re[k], 1e-10);
            try testing.expectApproxEqAbs(@as(f64, 0.0), im[k], 1e-10);
        }
    }

    test "bluestein: non-power-of-2 — Parseval (N=13)" {
        const n = 13;
        var re: [n]f64 = undefined;
        var im = [_]f64{0} ** n;
        for (0..n) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            re[k] = @sin(2.0 * math.pi * 3.0 * t) + 0.7 * @cos(2.0 * math.pi * 5.0 * t);
        }
        var e_time: f64 = 0;
        for (re) |v| e_time += v * v;

        const m = comptime bluesteinSize(n);
        var scratch_re: [m]f64 = undefined;
        var scratch_im: [m]f64 = undefined;
        var chirp_re: [m]f64 = undefined;
        var chirp_im: [m]f64 = undefined;
        bluestein(&re, &im, &scratch_re, &scratch_im, &chirp_re, &chirp_im);

        var e_freq: f64 = 0;
        for (0..n) |k| e_freq += re[k] * re[k] + im[k] * im[k];
        e_freq /= @as(f64, @floatFromInt(n));

        try testing.expectApproxEqRel(e_time, e_freq, 1e-10);
    }

    test "fftReal: matches full complex FFT on real input" {
        const n = 16;
        var signal: [n]f64 = undefined;
        for (0..n) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            signal[k] = @cos(2.0 * math.pi * 3.0 * t) + 0.5 * @sin(2.0 * math.pi * 7.0 * t);
        }
        // full complex FFT as reference
        var ref_re: [n]f64 = undefined;
        var ref_im = [_]f64{0} ** n;
        @memcpy(&ref_re, &signal);
        fft(&ref_re, &ref_im);

        // real FFT
        var out_re: [n / 2 + 1]f64 = undefined;
        var out_im: [n / 2 + 1]f64 = undefined;
        fftReal(&signal, &out_re, &out_im);

        for (0..n / 2 + 1) |k| {
            try testing.expectApproxEqAbs(ref_re[k], out_re[k], 1e-12);
            try testing.expectApproxEqAbs(ref_im[k], out_im[k], 1e-12);
        }
    }

    test "nextPow2: correctness" {
        try testing.expectEqual(@as(usize, 1), nextPow2(1));
        try testing.expectEqual(@as(usize, 2), nextPow2(2));
        try testing.expectEqual(@as(usize, 4), nextPow2(3));
        try testing.expectEqual(@as(usize, 4), nextPow2(4));
        try testing.expectEqual(@as(usize, 8), nextPow2(5));
        try testing.expectEqual(@as(usize, 1024), nextPow2(1000));
        try testing.expectEqual(@as(usize, 1024), nextPow2(1024));
    }
};

const FreqSolveTests = struct {
    const impl = @import("solvers").freq_solve;
    const FreqSolver = impl.FreqSolver;
    const FreqSolverT = impl.FreqSolverT;
    const dense_lu = @import("solvers").dense_lu;
    const scaleCopy = impl.test_access.scaleCopy;
    const std = @import("std");

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
        // One shared rhs across all lanes (solveBatch's contract).
        var rhs: [nn]f64 = undefined;
        for (0..nn) |i| rhs[i] = @floatFromInt(i + 1);

        for ([_]bool{ false, true }) |adjoint| {
            var x_batch: [omegas.len * nn]f64 = undefined;
            try fs.solveBatch(&omegas, &rhs, &x_batch, adjoint);

            var x_ref: [omegas.len * nn]f64 = undefined;
            try @TypeOf(fs).test_access.solveBatchSerial(&fs, &omegas, &rhs, &x_ref, adjoint);
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
            try fs.solveBatch(&omegas, rhs, x_batch, adjoint);
            const work_ptr = fs.strategy.sp.lane_work.ptr;
            try @TypeOf(fs).test_access.solveBatchSerial(&fs, &omegas, rhs, x_ref, adjoint);
            for (x_batch, x_ref) |a, b| try testing.expectApproxEqRel(b, a, 1e-11);
            for (rhs) |*value| value.* *= -2;
            try fs.solveBatch(omegas[0..3], rhs, x_batch[0 .. 3 * nn], adjoint);
            try fs.solveBatch(omegas[3..], rhs, x_batch[3 * nn ..], adjoint);
            try testing.expectEqual(work_ptr, fs.strategy.sp.lane_work.ptr);
            try @TypeOf(fs).test_access.solveBatchSerial(&fs, &omegas, rhs, x_ref, adjoint);
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
};

const GmresTests = struct {
    const impl = @import("solvers").gmres;
    const Gmres = impl.Gmres;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    /// Dense matvec context for tests: A is n x n row-major.
    fn DenseMatvec(comptime T: type) type {
        return struct {
            a: []const T,
            n: u32,

            fn matvec(v: []const T, w: []T, ctx_ptr: *anyopaque) void {
                const self: *const @This() = @ptrCast(@alignCast(ctx_ptr));
                const n: usize = self.n;
                for (0..n) |i| {
                    var s: T = 0;
                    for (0..n) |j| s += self.a[i * n + j] * v[j];
                    w[i] = s;
                }
            }
        };
    }

    /// Diagonal preconditioner: r[i] /= diag[i].
    fn DiagPrecond(comptime T: type) type {
        return struct {
            diag: []const T,

            fn apply(r: []T, ctx_ptr: *anyopaque) void {
                const self: *const @This() = @ptrCast(@alignCast(ctx_ptr));
                for (r, self.diag) |*ri, di| ri.* /= di;
            }
        };
    }

    test "GMRES: 3x3 SPD system converges in at most 3 iterations" {
        const gpa = testing.allocator;
        // A = [4 1 0; 1 3 1; 0 1 2], b = [5; 5; 3] => x = [1; 1; 1]
        var mv = DenseMatvec(f64){
            .a = &.{ 4, 1, 0, 1, 3, 1, 0, 1, 2 },
            .n = 3,
        };
        var gmres = try Gmres(f64).init(gpa, 3, 3);
        defer gmres.deinit(gpa);

        var x = [3]f64{ 0, 0, 0 };
        const result = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            null,
            null,
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

    test "GMRES: identity preconditioner gives same result" {
        const gpa = testing.allocator;
        var mv = DenseMatvec(f64){
            .a = &.{ 4, 1, 0, 1, 3, 1, 0, 1, 2 },
            .n = 3,
        };

        // Identity preconditioner: no-op.
        const IdentityPrecond = struct {
            fn apply(_: []f64, _: *anyopaque) void {}
        };
        var dummy: u8 = 0;

        var gmres = try Gmres(f64).init(gpa, 3, 3);
        defer gmres.deinit(gpa);

        var x = [3]f64{ 0, 0, 0 };
        const result = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            &IdentityPrecond.apply,
            @ptrCast(&dummy),
            &.{ 5, 5, 3 },
            &x,
            1e-12,
            0,
        );

        try testing.expect(result.converged);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[0], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[1], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[2], 1e-10);
    }

    test "GMRES: diagonal preconditioner reduces iterations" {
        const gpa = testing.allocator;
        // Poorly scaled: A = [1000 1; 1 1], b = [1001; 2] => x = [1; 1]
        var mv = DenseMatvec(f64){
            .a = &.{ 1000, 1, 1, 1 },
            .n = 2,
        };

        // Without preconditioner.
        var gmres = try Gmres(f64).init(gpa, 2, 10);
        defer gmres.deinit(gpa);

        var x1 = [2]f64{ 0, 0 };
        const r1 = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            null,
            null,
            &.{ 1001, 2 },
            &x1,
            1e-12,
            0,
        );
        try testing.expect(r1.converged);

        // With diagonal preconditioner (scale by diagonal of A).
        var pc = DiagPrecond(f64){ .diag = &.{ 1000, 1 } };
        var x2 = [2]f64{ 0, 0 };
        const r2 = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            &DiagPrecond(f64).apply,
            @ptrCast(&pc),
            &.{ 1001, 2 },
            &x2,
            1e-12,
            0,
        );
        try testing.expect(r2.converged);
        try testing.expect(r2.iterations <= r1.iterations);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x2[0], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x2[1], 1e-10);
    }

    test "GMRES: ill-conditioned system with tight budget reports non-convergence" {
        const gpa = testing.allocator;
        // 4x4 ill-conditioned non-symmetric system. With restart depth m=1 and
        // only 2 restarts, GMRES(1) cannot converge.
        const n: u32 = 4;
        var mv = DenseMatvec(f64){
            .a = &.{
                1e6, 1,    1,   1,
                1,   1e-6, 1,   1,
                1,   1,    1e6, 1,
                1,   1,    1,   1e-6,
            },
            .n = n,
        };
        var gmres_s = try Gmres(f64).init(gpa, n, 1);
        defer gmres_s.deinit(gpa);

        var x = [n]f64{ 0, 0, 0, 0 };
        const result = gmres_s.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            null,
            null,
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

        var mv = DenseMatvec(f64){ .a = &a, .n = n };

        // Small restart window: needs multiple restarts.
        var gmres = try Gmres(f64).init(gpa, n, 3);
        defer gmres.deinit(gpa);

        var x = [n]f64{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const result = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            null,
            null,
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
        DenseMatvec(f64).matvec(&x, &check, @ptrCast(&mv));
        for (0..n) |i| try testing.expectApproxEqAbs(b[i], check[i], 1e-8);
    }

    test "GMRES: right preconditioning returns correct unpreconditioned solution" {
        const gpa = testing.allocator;
        // A = [10 1; 2 8], b = [11; 10] => x = [1; 1]
        // Precond M = diag(10, 8): the solution must be in the original space,
        // not in the preconditioned space.
        var mv = DenseMatvec(f64){
            .a = &.{ 10, 1, 2, 8 },
            .n = 2,
        };
        var pc = DiagPrecond(f64){ .diag = &.{ 10, 8 } };

        var gmres = try Gmres(f64).init(gpa, 2, 10);
        defer gmres.deinit(gpa);

        var x = [2]f64{ 0, 0 };
        const result = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            &DiagPrecond(f64).apply,
            @ptrCast(&pc),
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
        var mv = DenseMatvec(f64){
            .a = &.{ 1, 0, 0, 1 },
            .n = 2,
        };
        var gmres = try Gmres(f64).init(gpa, 2, 5);
        defer gmres.deinit(gpa);

        var x = [2]f64{ 42, 99 };
        const result = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            null,
            null,
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

    test "GMRES: non-zero initial guess converges" {
        const gpa = testing.allocator;
        // A = [2 0; 0 3], b = [2; 3] => x = [1; 1], start from x = [0.5; 0.5]
        var mv = DenseMatvec(f64){
            .a = &.{ 2, 0, 0, 3 },
            .n = 2,
        };
        var gmres = try Gmres(f64).init(gpa, 2, 5);
        defer gmres.deinit(gpa);

        var x = [2]f64{ 0.5, 0.5 };
        const result = gmres.solve(
            &DenseMatvec(f64).matvec,
            @ptrCast(&mv),
            null,
            null,
            &.{ 2, 3 },
            &x,
            1e-12,
            0,
        );
        try testing.expect(result.converged);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[0], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 1.0), x[1], 1e-10);
    }

    test "GMRES: f32 instantiation compiles and solves" {
        const gpa = testing.allocator;
        var mv = DenseMatvec(f32){
            .a = &.{ 4, 1, 1, 3 },
            .n = 2,
        };
        var gmres = try Gmres(f32).init(gpa, 2, 5);
        defer gmres.deinit(gpa);

        var x = [2]f32{ 0, 0 };
        const result = gmres.solve(
            &DenseMatvec(f32).matvec,
            @ptrCast(&mv),
            null,
            null,
            &[2]f32{ 5, 4 },
            &x,
            1e-5,
            0,
        );
        try testing.expect(result.converged);
        // [4 1; 1 3] x = [5; 4] => x = [1, 1]
        try testing.expectApproxEqAbs(@as(f32, 1.0), x[0], 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 1.0), x[1], 1e-4);
    }
};

const LaneLuTests = struct {
    const impl = @import("solvers").lane_lu;
    const Allocator = std.mem.Allocator;
    const LaneLu = impl.LaneLu;
    const broadcast = impl.broadcast;
    const deinterleave = impl.deinterleave;
    const interleave = impl.interleave;
    const sparse_lu = @import("solvers").sparse_lu;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    const DenseCsc = SparseTests.DenseCsc;

    const identity = SparseTests.identity;

    test "LaneLu construction releases storage on every allocation failure" {
        const gpa = testing.allocator;
        const csc = DenseCsc(2).from(.{ .{ 4, 1 }, .{ 1, 3 } });
        var q = identity(2);
        var base = try sparse_lu.SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer base.deinit(gpa);
        try base.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        try testing.checkAllAllocationFailures(gpa, struct {
            fn run(allocator: Allocator, factored: *const sparse_lu.SparseLu(f64)) !void {
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
        var base = try sparse_lu.SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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
        const mask = ll.refactor(&csc.col_ptr, lvals[0..csc.nnz()], 1e-12);
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
            var base = try sparse_lu.SparseLu(f64).init(gpa, 4, &base_csc.col_ptr, base_csc.row_idx[0..base_csc.nnz()], &q);
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
            const mask = ll.refactor(&base_csc.col_ptr, lvals[0..nnz], 1e-12);

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
        var base = try sparse_lu.SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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
        const mask = ll.refactor(&csc.col_ptr, lvals[0..nnz], 0); // growth off; catch singular only

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

    test "interleave/deinterleave/broadcast round-trip" {
        const W = 4;
        var l0 = [_]f64{ 1, 2, 3 };
        var l1 = [_]f64{ 4, 5, 6 };
        var l2 = [_]f64{ 7, 8, 9 };
        var l3 = [_]f64{ 10, 11, 12 };
        const lanes = [_][]const f64{ &l0, &l1, &l2, &l3 };
        var plane: [3]@Vector(W, f64) = undefined;
        interleave(W, &lanes, &plane);
        try testing.expectEqual(@as(f64, 1), plane[0][0]);
        try testing.expectEqual(@as(f64, 4), plane[0][1]);
        try testing.expectEqual(@as(f64, 12), plane[2][3]);

        var o0: [3]f64 = undefined;
        var o1: [3]f64 = undefined;
        var o2: [3]f64 = undefined;
        var o3: [3]f64 = undefined;
        const outs = [_][]f64{ &o0, &o1, &o2, &o3 };
        deinterleave(W, &plane, &outs);
        try testing.expectEqualSlices(f64, &l0, &o0);
        try testing.expectEqualSlices(f64, &l3, &o3);

        const src = [_]f64{ 5, 6 };
        var b: [2]@Vector(W, f64) = undefined;
        broadcast(W, &src, &b);
        try testing.expectEqual(@as(@Vector(W, f64), @splat(5)), b[0]);
    }
};

const NewtonCoreTests = struct {
    const impl = @import("solvers").newton_core;
    const PostStep = impl.PostStep;
    const Result = impl.Result;
    const Tol = impl.Tol;
    const Vecs = impl.Vecs;
    const inf_f64 = impl.inf_f64;
    const newtonSolve = impl.newtonSolve;

    // ===========================================================================
    // Tests — a self-contained serial Env (no std, no libc, no LU) exercising the
    // full outer-Newton + GMRES(m) core on a known analytic system. This mirrors
    // the CPU CpuEnv contract in converger.zig but stays libc-free so it runs in
    // the solvers module suite. Jacobi preconditioner from the analytic diagonal.
    // ===========================================================================

    const std = @import("std");

    // Analytic 2x2 nonlinear system, root at (2, 1):
    //   F0 = x0 + x1 - 3
    //   F1 = x0^2 + x1^2 - 5
    // Diagonal of J for the Jacobi preconditioner: {1, 2*x1}.
    const TestEnv = struct {
        const Self = @This();
        n: u32,
        x_cur: [*]f64, // outer x, for the preconditioner diagonal
        rhs_buf: [8]f64 = @splat(0),
        diag_buf: [8]f64 = @splat(0),
        scal: [16]f64 = @splat(0),

        pub const F64 = [*]f64;
        pub const backtrack = false;
        pub const exact_jv = true;

        pub inline fn tid(_: *Self) u32 {
            return 0;
        }
        pub inline fn stride(_: *Self) u32 {
            return 1;
        }
        pub inline fn isLead(_: *Self) bool {
            return true;
        }
        pub inline fn sync(_: *Self) void {}
        pub inline fn reduceAdd(_: *Self, p: f64) f64 {
            return p;
        }
        pub inline fn reduceMax(_: *Self, p: f64) f64 {
            return p;
        }
        pub inline fn publish(self: *Self, slot: usize, val: f64) void {
            self.scal[slot] = val;
        }
        pub inline fn read(self: *Self, slot: usize) f64 {
            return self.scal[slot];
        }
        pub inline fn limiting(_: *Self) bool {
            return false;
        }

        // Fill rhs with F(x_eval); the core adds nothing else on the CPU path.
        pub fn assemble(self: *Self, comptime _: bool, x_eval: [*]f64, _: [*]f64, _: f64, _: bool) void {
            self.rhs_buf[0] = x_eval[0] + x_eval[1] - 3.0;
            self.rhs_buf[1] = x_eval[0] * x_eval[0] + x_eval[1] * x_eval[1] - 5.0;
        }

        // Jacobi diagonal from the current outer x: J = [[1,1],[2x0,2x1]] -> {1, 2x1}.
        pub fn precondBuild(self: *Self) void {
            const d0 = 1.0;
            const d1 = 2.0 * self.x_cur[1];
            self.diag_buf[0] = if (@abs(d0) > 1e-30) 1.0 / d0 else 1.0;
            self.diag_buf[1] = if (@abs(d1) > 1e-30) 1.0 / d1 else 1.0;
        }
        pub fn precondApply(self: *Self, r: [*]f64) void {
            r[0] *= self.diag_buf[0];
            r[1] *= self.diag_buf[1];
        }
        pub fn postStep(_: *Self, _: [*]f64, _: [*]f64, _: bool) PostStep {
            return .{ .limited = false, .flipped = false };
        }
        pub fn gateScale(self: *Self, i: u32) f64 {
            // |J_ii| — the residual-gate row scale.
            return if (i == 0) 1.0 else 2.0 * self.x_cur[1];
        }
        pub fn currentRow(_: *Self, _: u32) bool {
            return true;
        }
    };

    fn runTestSolve(x: *[2]f64, max_iter: u32) Result {
        const n: u32 = 2;
        const m: u32 = 2; // gmres restart = min(30, n)
        var env = TestEnv{ .n = n, .x_cur = x };
        // Vecs backing storage, sized for (n=2, m=2).
        var v_basis: [(m + 1) * n]f64 = @splat(0);
        var h: [(m + 1) * m]f64 = @splat(0);
        var cs: [m]f64 = @splat(0);
        var sn: [m]f64 = @splat(0);
        var g_vec: [m + 1]f64 = @splat(0);
        var y_vec: [m]f64 = @splat(0);
        var r: [n]f64 = @splat(0);
        var w: [n]f64 = @splat(0);
        var x_pert: [n]f64 = @splat(0);
        var f0: [n]f64 = @splat(0);
        var x_old: [n]f64 = @splat(0);
        const vecs: Vecs([*]f64) = .{
            .v_basis = &v_basis,
            .h = &h,
            .cs = &cs,
            .sn = &sn,
            .g_vec = &g_vec,
            .y_vec = &y_vec,
            .r = &r,
            .w = &w,
            .x_pert = &x_pert,
            .f0 = &f0,
            .f0_shift = &f0, // aliased, unused with exact_jv
            .diag = &env.diag_buf,
            .x_old = &x_old,
            .rhs = &env.rhs_buf,
        };
        const tol: Tol = .{
            .reltol = 1e-3,
            .abstol = 1e-12,
            .vntol = 1e-6,
            .residual_tol = 1e-9,
            .gmin = 0,
            .dx_clamp = inf_f64,
            .max_iter = max_iter,
            .gmres_m = m,
        };
        return newtonSolve(&env, vecs, x, 0, tol, n, m);
    }

    test "newton_core: JFNK converges to known root of analytic 2x2 system" {
        var x = [2]f64{ 3.0, 3.0 };
        const res = runTestSolve(&x, 100);
        try std.testing.expect(res.converged);
        try std.testing.expectApproxEqAbs(@as(f64, 2.0), x[0], 1e-8);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), x[1], 1e-8);
    }

    test "newton_core: reports not-converged (not a wrong root) under a 1-iter cap" {
        var x = [2]f64{ 3.0, 3.0 };
        const res = runTestSolve(&x, 1);
        try std.testing.expect(!res.converged);
    }
};

const OrderTests = struct {
    const impl = @import("solvers").order;
    const Ws = impl.Ws;
    const amd = impl.amd;
    const order = impl.order;
    const std = @import("std");
    const wsSize = impl.wsSize;

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    /// Dense adjacency matrix → CSC converter for tests.
    fn DenseCsc(comptime n: usize) type {
        return struct {
            col_ptr: [n + 1]u32,
            row_idx: [n * n]u32,

            fn from(a: [n][n]u1) @This() {
                var s: @This() = undefined;
                var m: u32 = 0;
                s.col_ptr[0] = 0;
                for (0..n) |j| {
                    for (0..n) |i| {
                        if (a[i][j] != 0) {
                            s.row_idx[m] = @intCast(i);
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

    fn expectPermutation(q: []const u32, n: u32) !void {
        var seen: [64]bool = @splat(false);
        for (q) |c| {
            try testing.expect(c < n);
            try testing.expect(!seen[c]);
            seen[c] = true;
        }
    }

    // 5x5 star: hub 0 coupled to every leaf. Min degree must defer the hub
    // until its degree collapses — eliminating it first fills the whole matrix.
    const star = [5][5]u1{
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
    const btf_case = [4][4]u1{
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
            var a: [6][6]u1 = @splat(@splat(0));
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
            var a: [3][3]u1 = @splat(@splat(0));
            for (0..3) |i| a[i][i] = 1;
            const csc = DenseCsc(3).from(a);
            var buf: [1024]u32 = undefined;
            var ws_val = Ws.init(&buf);
            var q: [3]u32 = undefined;
            try order(3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q, &ws_val);
            try expectPermutation(&q, 3);
        }
    }

    test "order: deterministic — two runs byte-identical" {
        const csc = DenseCsc(5).from(star);
        var buf: [2048]u32 = undefined;
        var q1: [5]u32 = undefined;
        var q2: [5]u32 = undefined;
        var ws1 = Ws.init(&buf);
        try order(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q1, &ws1);
        var ws2 = Ws.init(&buf);
        try order(5, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q2, &ws2);
        try testing.expectEqualSlices(u32, &q1, &q2);
    }

    test "order: comptime consumer ≡ runtime consumer, byte-compared" {
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

    test "amd: empty matrix" {
        var buf: [64]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [0]u32 = undefined;
        try amd(0, &[_]u32{0}, &[_]u32{}, &q, &ws_val);
    }

    test "order: empty matrix" {
        var buf: [64]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [0]u32 = undefined;
        try order(0, &[_]u32{0}, &[_]u32{}, &q, &ws_val);
    }

    test "order: single element" {
        // 1×1 matrix with a diagonal entry
        var buf: [256]u32 = undefined;
        var ws_val = Ws.init(&buf);
        var q: [1]u32 = undefined;
        try order(1, &[_]u32{ 0, 1 }, &[_]u32{0}, &q, &ws_val);
        try testing.expectEqual(@as(u32, 0), q[0]);
    }

    test "amd: complete graph (K4) — all vertices indistinguishable" {
        // K4: every vertex connected to every other → all are supervariables
        var a: [4][4]u1 = undefined;
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
        const a = [3][3]u1{
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

    test "amd: arrowhead matrix — hub deferred" {
        // 8×8 arrowhead: row 0 and col 0 are dense, rest is diagonal.
        // Hub vertex 0 should be deferred to the end.
        const n = 8;
        var a: [n][n]u1 = @splat(@splat(0));
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

const PreconditionerTests = struct {
    const impl = @import("solvers").preconditioner;
    const Allocator = std.mem.Allocator;
    const Preconditioner = impl.Preconditioner;
    const averageSamples = impl.test_access.averageSamples;
    const buildStackedRealPattern = @import("solvers").freq_solve.buildStackedRealPattern;
    const fillStackedReal = impl.test_access.fillStackedReal;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    /// Helper: build a 2×2 CSC pattern for [diag + off-diag] circuit.
    fn testPattern2x2() struct { col_ptr: [3]u32, row_idx: [4]u32 } {
        // Full 2×2: col 0 has rows {0,1}, col 1 has rows {0,1}
        return .{
            .col_ptr = .{ 0, 2, 4 },
            .row_idx = .{ 0, 1, 0, 1 },
        };
    }

    test "Preconditioner: LTI system, averaged_circulant is exact inverse" {
        // 2×2 diagonal G = [[2,0],[0,3]], C = [[0.1,0],[0,0.2]]
        // With constant G/C (LTI), the averaged preconditioner is the exact operator,
        // so P^{-1} * (operator * x) = x for any x.
        const gpa = testing.allocator;
        var pat = testPattern2x2();

        const num_harmonics: u32 = 1; // M=1, sidebands = 3 (p=-1,0,+1)
        const num_samples: u32 = 4;
        const omega0: f64 = 2.0 * std.math.pi * 1e3; // 1kHz fundamental

        // G = [2, 0; 0, 3] stored in CSC: vals = [2, 0, 0, 3]
        const g_vals = [_]f64{ 2.0, 0.0, 0.0, 3.0 };
        // C = [0.1, 0; 0, 0.2]
        const c_vals = [_]f64{ 0.1, 0.0, 0.0, 0.2 };

        // All samples identical (LTI)
        const g_slices = [_][]const f64{&g_vals} ** num_samples;
        const c_slices = [_][]const f64{&c_vals} ** num_samples;

        var prec = try Preconditioner(f64).init(
            gpa,
            2,
            &pat.col_ptr,
            &pat.row_idx,
            num_harmonics,
            num_samples,
            &g_slices,
            &c_slices,
            omega0,
            .averaged_circulant,
        );
        defer prec.deinit(gpa);

        // Build a test RHS: for sideband p, set up (G + jωpC) * x_known and verify
        // that apply recovers x_known.
        const ns: usize = 3; // 2*1+1
        const n: usize = 2;
        const vec_len = 2 * ns * n; // 12

        // Known solution: x_p = [1, 1] for all sidebands (re and im)
        var rhs: [vec_len]f64 = undefined;

        // For each sideband p, compute b_p = (G + jωpC) * [1;1]
        // In stacked-real: [G, -ωC; ωC, G] * [1;1;1;1]
        //   re = G*[1;1] - ωC*[1;1] = [2-0.1ω; 3-0.2ω]  (per sideband p)
        //   im = ωC*[1;1] + G*[1;1] = [0.1ω+2; 0.2ω+3]
        const M: i32 = 1;
        for (0..ns) |pi| {
            const p_signed: f64 = @floatFromInt(@as(i32, @intCast(pi)) - M);
            const wp = p_signed * omega0;

            // re part
            rhs[pi * n + 0] = 2.0 - 0.1 * wp; // G[0,0]*1 + G[0,1]*1 - wp*(C[0,0]*1 + C[0,1]*1) = 2 - 0.1*wp
            rhs[pi * n + 1] = 3.0 - 0.2 * wp;

            // im part
            rhs[ns * n + pi * n + 0] = 0.1 * wp + 2.0;
            rhs[ns * n + pi * n + 1] = 0.2 * wp + 3.0;
        }

        prec.apply(&rhs);

        // Should recover x = [1, 1, 1, 1, 1, 1 | 1, 1, 1, 1, 1, 1]
        for (0..vec_len) |i| {
            try testing.expectApproxEqAbs(@as(f64, 1.0), rhs[i], 1e-8);
        }
    }

    test "Preconditioner: dc_sample produces valid solve" {
        const gpa = testing.allocator;
        var pat = testPattern2x2();

        const g_vals = [_]f64{ 1.0, 0.0, 0.0, 1.0 }; // identity G
        const c_vals = [_]f64{ 0.0, 0.0, 0.0, 0.0 }; // zero C

        const g_slices = [_][]const f64{&g_vals} ** 2;
        const c_slices = [_][]const f64{&c_vals} ** 2;

        var prec = try Preconditioner(f64).init(
            gpa,
            2,
            &pat.col_ptr,
            &pat.row_idx,
            1, // M=1
            2,
            &g_slices,
            &c_slices,
            1.0,
            .dc_sample,
        );
        defer prec.deinit(gpa);

        // With G=I, C=0: P = I for all sidebands. apply should be identity.
        const ns: usize = 3;
        const n: usize = 2;
        var rhs: [2 * ns * n]f64 = undefined;
        for (&rhs, 0..) |*v, i| v.* = @floatFromInt(i + 1);

        var expected: [2 * ns * n]f64 = undefined;
        @memcpy(&expected, &rhs);

        prec.apply(&rhs);

        for (0..rhs.len) |i| {
            try testing.expectApproxEqAbs(expected[i], rhs[i], 1e-10);
        }
    }

    test "Preconditioner: applyT matches apply on symmetric system" {
        // Symmetric G, symmetric C → the stacked-real matrix is symmetric
        // (since [G, -ωC; ωC, G] with symmetric G,C is NOT symmetric — but
        // the LU factors give the same result when G is symmetric and C=0).
        const gpa = testing.allocator;
        var pat = testPattern2x2();

        // Symmetric G, zero C (so the stacked-real block is [G,0;0,G] = symmetric)
        const g_vals = [_]f64{ 2.0, 0.5, 0.5, 3.0 }; // symmetric 2×2
        const c_vals = [_]f64{ 0.0, 0.0, 0.0, 0.0 };

        const g_slices = [_][]const f64{&g_vals} ** 2;
        const c_slices = [_][]const f64{&c_vals} ** 2;

        var prec = try Preconditioner(f64).init(
            gpa,
            2,
            &pat.col_ptr,
            &pat.row_idx,
            1,
            2,
            &g_slices,
            &c_slices,
            0.0, // ω=0 so C doesn't matter → purely symmetric
            .averaged_circulant,
        );
        defer prec.deinit(gpa);

        const ns: usize = 3;
        const n: usize = 2;

        // Apply and applyT to same input should give same result (symmetric system)
        var rhs1: [2 * ns * n]f64 = undefined;
        var rhs2: [2 * ns * n]f64 = undefined;
        for (&rhs1, &rhs2, 0..) |*v1, *v2, i| {
            const val: f64 = @floatFromInt(i + 1);
            v1.* = val;
            v2.* = val;
        }

        prec.apply(&rhs1);
        prec.applyT(&rhs2);

        for (0..rhs1.len) |i| {
            try testing.expectApproxEqAbs(rhs1[i], rhs2[i], 1e-10);
        }
    }

    test "Preconditioner: non-trivial modulation, averaged vs dc_sample" {
        // Time-varying G: two samples with different conductances.
        // Both dc_sample and averaged_circulant should produce valid (finite) results
        // but they differ because they use different Jacobian approximations.
        const gpa = testing.allocator;
        var pat = testPattern2x2();

        // Sample 0: G = [1,0;0,2], Sample 1: G = [3,0;0,4]
        const g0 = [_]f64{ 1.0, 0.0, 0.0, 2.0 };
        const g1 = [_]f64{ 3.0, 0.0, 0.0, 4.0 };
        const c0 = [_]f64{ 0.1, 0.0, 0.0, 0.1 };
        const c1 = [_]f64{ 0.1, 0.0, 0.0, 0.1 };

        const g_slices = [_][]const f64{ &g0, &g1 };
        const c_slices = [_][]const f64{ &c0, &c1 };

        // Averaged: G_bar = [2,0;0,3]
        var prec_avg = try Preconditioner(f64).init(
            gpa,
            2,
            &pat.col_ptr,
            &pat.row_idx,
            1,
            2,
            &g_slices,
            &c_slices,
            1.0,
            .averaged_circulant,
        );
        defer prec_avg.deinit(gpa);

        // DC-sample: uses G(t_0) = [1,0;0,2]
        var prec_dc = try Preconditioner(f64).init(
            gpa,
            2,
            &pat.col_ptr,
            &pat.row_idx,
            1,
            2,
            &g_slices,
            &c_slices,
            1.0,
            .dc_sample,
        );
        defer prec_dc.deinit(gpa);

        const ns: usize = 3;
        const n: usize = 2;
        var rhs_avg: [2 * ns * n]f64 = undefined;
        var rhs_dc: [2 * ns * n]f64 = undefined;
        for (&rhs_avg, &rhs_dc, 0..) |*va, *vd, i| {
            const val: f64 = @floatFromInt(i + 1);
            va.* = val;
            vd.* = val;
        }

        prec_avg.apply(&rhs_avg);
        prec_dc.apply(&rhs_dc);

        // Both should produce finite results
        for (rhs_avg) |v| try testing.expect(std.math.isFinite(v));
        for (rhs_dc) |v| try testing.expect(std.math.isFinite(v));

        // They should differ (different Jacobian approximations with ω≠0)
        var any_diff = false;
        for (rhs_avg, rhs_dc) |a, d| {
            if (@abs(a - d) > 1e-12) {
                any_diff = true;
                break;
            }
        }
        try testing.expect(any_diff);
    }

    test "Preconditioner: block_banded initializes and applies" {
        // Smoke test: block_banded should at least produce finite results.
        const gpa = testing.allocator;
        var pat = testPattern2x2();

        const g0 = [_]f64{ 2.0, 0.1, 0.1, 3.0 };
        const g1 = [_]f64{ 2.5, 0.2, 0.2, 3.5 };
        const g2 = [_]f64{ 1.5, 0.05, 0.05, 2.5 };
        const g3 = [_]f64{ 2.0, 0.15, 0.15, 3.0 };
        const c_vals = [_]f64{ 0.1, 0.0, 0.0, 0.1 };

        const g_slices = [_][]const f64{ &g0, &g1, &g2, &g3 };
        const c_slices = [_][]const f64{ &c_vals, &c_vals, &c_vals, &c_vals };

        var prec = try Preconditioner(f64).init(
            gpa,
            2,
            &pat.col_ptr,
            &pat.row_idx,
            1,
            4,
            &g_slices,
            &c_slices,
            1.0,
            .block_banded,
        );
        defer prec.deinit(gpa);

        const ns: usize = 3;
        const n: usize = 2;
        var rhs: [2 * ns * n]f64 = undefined;
        for (&rhs, 0..) |*v, i| v.* = @floatFromInt(i + 1);

        prec.apply(&rhs);

        for (rhs) |v| try testing.expect(std.math.isFinite(v));
    }

    test "Preconditioner: stacked-real pattern matches freq_solve layout" {
        // Verify the 2n×2n CSC pattern has the expected structure.
        var pat = testPattern2x2();
        const n: u32 = 2;
        const nnz = pat.col_ptr[n]; // 4
        var sr_col_ptr: [5]u32 = undefined; // 2n+1
        var sr_row_idx: [16]u32 = undefined; // 4*nnz

        buildStackedRealPattern(n, &pat.col_ptr, &pat.row_idx, &sr_col_ptr, &sr_row_idx);

        // Column 0 should have 4 entries: rows 0,1 (G block) then 2,3 (C block)
        try testing.expectEqual(@as(u32, 0), sr_col_ptr[0]);
        try testing.expectEqual(@as(u32, 4), sr_col_ptr[1]);
        try testing.expectEqual(@as(u32, 0), sr_row_idx[0]);
        try testing.expectEqual(@as(u32, 1), sr_row_idx[1]);
        try testing.expectEqual(@as(u32, 2), sr_row_idx[2]);
        try testing.expectEqual(@as(u32, 3), sr_row_idx[3]);

        // Total nnz should be 4 * original nnz
        try testing.expectEqual(@as(u32, 4 * nnz), sr_col_ptr[4]);
    }

    test "Preconditioner: averageSamples correctness" {
        const s0 = [_]f64{ 1.0, 2.0, 3.0 };
        const s1 = [_]f64{ 3.0, 4.0, 5.0 };
        const samples = [_][]const f64{ &s0, &s1 };
        var dst: [3]f64 = undefined;

        averageSamples(f64, &dst, &samples, 2, 3);

        try testing.expectApproxEqAbs(@as(f64, 2.0), dst[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 3.0), dst[1], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 4.0), dst[2], 1e-15);
    }

    test "Preconditioner: fillStackedReal correctness" {
        // 2×2 diagonal: G=[2,3], C=[0.1,0.2] (diagonal only, nnz=2)
        const col_ptr = [_]u32{ 0, 1, 2 };
        const g = [_]f64{ 2.0, 3.0 };
        const c = [_]f64{ 0.1, 0.2 };
        const omega: f64 = 10.0;
        var vals: [8]f64 = undefined; // 4*nnz = 8

        fillStackedReal(f64, &vals, &g, &c, &col_ptr, 2, omega);

        // Col 0 (< n): [G[0], ω*C[0]] = [2, 1.0]
        try testing.expectApproxEqAbs(@as(f64, 2.0), vals[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 1.0), vals[1], 1e-15);
        // Col 1 (< n): [G[1], ω*C[1]] = [3, 2.0]
        try testing.expectApproxEqAbs(@as(f64, 3.0), vals[2], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 2.0), vals[3], 1e-15);
        // Col 2 (≥ n): [-ω*C[0], G[0]] = [-1.0, 2.0]
        try testing.expectApproxEqAbs(@as(f64, -1.0), vals[4], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 2.0), vals[5], 1e-15);
        // Col 3 (≥ n): [-ω*C[1], G[1]] = [-2.0, 3.0]
        try testing.expectApproxEqAbs(@as(f64, -2.0), vals[6], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 3.0), vals[7], 1e-15);
    }

    test "Preconditioner construction releases storage on every allocation failure" {
        for (std.enums.values(Preconditioner(f64).Kind)) |kind| {
            try testing.checkAllAllocationFailures(testing.allocator, struct {
                fn run(gpa: Allocator, k: Preconditioner(f64).Kind) !void {
                    var prec = try Preconditioner(f64).init(gpa, 2, &.{ 0, 2, 4 }, &.{ 0, 1, 0, 1 }, 1, 1, &.{&.{ 2, -1, -1, 2 }}, &.{&.{ 0.1, 0, 0, 0.1 }}, 1, k);
                    defer prec.deinit(gpa);
                }
            }.run, .{kind});
        }
    }

    test "Preconditioner releases banded storage when factorization fails" {
        try testing.expectError(error.SingularMatrix, Preconditioner(f64).init(testing.allocator, 2, &.{ 0, 2, 4 }, &.{ 0, 1, 0, 1 }, 1, 1, &.{&.{ 1, 1, 1, 1 }}, &.{&.{ 0, 0, 0, 0 }}, 1, .block_banded));
    }
};

const SparseTests = struct {
    const impl = @import("solvers").sparse_lu;
    const Allocator = std.mem.Allocator;
    const SparseLu = impl.SparseLu;
    const std = @import("std");

    const order = @import("solvers").order;

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    /// Dense-to-CSC converter for tests.
    pub fn DenseCsc(comptime n: usize) type {
        return struct {
            col_ptr: [n + 1]u32,
            row_idx: [n * n]u32,
            vals: [n * n]f64,

            pub fn from(a: [n][n]f64) @This() {
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

            pub fn nnz(s: *const @This()) u32 {
                return s.col_ptr[n];
            }
        };
    }

    /// Dense Gaussian elimination reference solver for verification.
    pub fn denseSolve(comptime n: usize, a_in: [n][n]f64, b_in: [n]f64) [n]f64 {
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

    pub fn identity(comptime n: usize) [n]u32 {
        var q: [n]u32 = undefined;
        for (0..n) |i| q[i] = @intCast(i);
        return q;
    }

    pub fn checkSolve(comptime n: usize, a: [n][n]f64, b: [n]f64, lu: *SparseLu(f64)) !void {
        var x: [n]f64 = undefined;
        lu.solve(&b, &x);
        const xref = denseSolve(n, a, b);
        for (x, xref) |xi, ri| try testing.expectApproxEqRel(ri, xi, 1e-11);
    }

    test "2x2: factor + solve" {
        const gpa = testing.allocator;
        const a = [2][2]f64{ .{ 2, 1 }, .{ 1, 3 } };
        const csc = DenseCsc(2).from(a);
        var q = identity(2);
        var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        var x: [2]f64 = undefined;
        lu.solve(&.{ 5, 7 }, &x);
        const xref = denseSolve(2, a, .{ 5, 7 });
        try testing.expectApproxEqAbs(xref[0], x[0], 1e-12);
        try testing.expectApproxEqAbs(xref[1], x[1], 1e-12);
    }

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
        var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(3, a, b, &lu);
    }

    test "order -> factor + solve: AMD permutation is valid and the solve is correct" {
        const gpa = testing.allocator;
        // Arrowhead: dense first row/col (hub at node 0), diagonal elsewhere.
        // AMD defers the hub, so q is a genuine non-identity permutation — this is
        // the composition order.zig and the LU each test only in isolation.
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
        var seen = [_]bool{false} ** 4;
        for (q) |c| {
            try testing.expect(!seen[c]);
            seen[c] = true;
        }
        // The hub (node 0) is deferred: not factored first.
        try testing.expect(q[0] != 0);

        var lu = try SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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
        var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try checkSolve(3, a, b, &lu);
    }

    test "atto-siemens row keeps its own diagonal (BSIMSOI floating body)" {
        const gpa = testing.allocator;
        // Distilled BSIMSOI body block. Row/col 0 is the floating-body KCL row: at
        // DEFAULT junction params every coefficient in it is atto-siemens. Rows 1/2
        // are the drain/source nodes — 1 kS of contact conductance and Gmbs = 1 uS
        // of body transconductance, and that Gmbs sits in the BODY COLUMN. So the
        // body equation is 14 decades below the rest of the matrix while its column
        // carries a 1e-6 entry: the raw threshold test (|a00| >= tol*colmax) rejects
        // the body diagonal, the body column pivots on the drain row, and the body
        // equation is then reconstructed out of numbers 1e14 times its own size.
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
        var lu = try SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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
        var lu = try SparseLu(f64).init(gpa, 4, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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

    test "singular matrix detection" {
        const gpa = testing.allocator;
        const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
        const csc = DenseCsc(2).from(a);
        var q = identity(2);
        var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try testing.expectError(
            error.SingularMatrix,
            lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3),
        );
    }

    test "structurally void unknown gets a unit pivot, not SingularMatrix" {
        const gpa = testing.allocator;
        // Row/col 1 is entirely zero — a compact model's disabled branch-flow
        // unknown (HICUM `V(br_sht) <+ 0` at flsh = 0). The remaining 2x2 system
        // [[2,1],[1,3]] x = [5,7] has the solution (8/5, 9/5); x1 must come back 0.
        // DenseCsc drops exact zeros, so build the pattern by hand: the host always
        // forces the diagonal, and the per-device dense block leaves row/col 1
        // structurally present with zero values.
        const col_ptr = [4]u32{ 0, 3, 6, 9 };
        const row_idx = [9]u32{ 0, 1, 2, 0, 1, 2, 0, 1, 2 };
        const vals = [9]f64{ 2, 0, 1, 0, 0, 0, 1, 0, 3 };
        var q = identity(3);
        var lu = try SparseLu(f64).init(gpa, 3, &col_ptr, &row_idx, &q);
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
            var lu = try SparseLu(f64).init(gpa, 2, &col_ptr, &row_idx, &q);
            defer lu.deinit(gpa);
            var fresh = try SparseLu(f64).init(gpa, 2, &col_ptr, &row_idx, &q);
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
        // its values are NOT zero — voidUnknown must refuse to rescue it.
        const a = [2][2]f64{ .{ 1, 1 }, .{ 1, 1 } };
        const csc = DenseCsc(2).from(a);
        var q = identity(2);
        var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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
        var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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

    test "determinism: two factorizations byte-identical" {
        const gpa = testing.allocator;
        const a = [3][3]f64{
            .{ 2, 1, 0 },
            .{ 1, 3, 1 },
            .{ 0, 1, 4 },
        };
        const csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu1 = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu1.deinit(gpa);
        var lu2 = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu2.deinit(gpa);
        try lu1.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try lu2.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try testing.expectEqualSlices(f64, lu1.lx.items, lu2.lx.items);
        try testing.expectEqualSlices(f64, lu1.ux.items, lu2.ux.items);
        try testing.expectEqualSlices(f64, lu1.udiag, lu2.udiag);
        try testing.expectEqualSlices(u32, lu1.li.items, lu2.li.items);
        try testing.expectEqualSlices(u32, lu1.ui.items, lu2.ui.items);
    }

    test "pivot growth monitor detection" {
        const gpa = testing.allocator;
        // Factor a well-conditioned matrix, then refactor with values that
        // cause extreme pivot decay — the growth monitor should catch it.
        var a = [3][3]f64{
            .{ 10, 1, 0 },
            .{ 1, 10, 1 },
            .{ 0, 1, 10 },
        };
        var csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        // Make the diagonal nearly zero while off-diagonals stay large:
        // the frozen pivot at position (0,0) will collapse.
        a[0][0] = 1e-20;
        a[1][1] = 1e-20;
        a[2][2] = 1e-20;
        csc = DenseCsc(3).from(a);
        // With a tight growth limit the decay should be detected
        try testing.expectError(
            error.SingularMatrix,
            lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 1e-6),
        );
    }

    test "scatterAxpy: bit-identical to the one-at-a-time oracle at every length" {
        // The pair-stepped kernel splits on length parity, so the oracle has to be
        // walked over both sides of the split — 0 and 1 are the lengths that
        // actually occur least in the wild and break first.
        var rng = std.Random.DefaultPrng.init(0x5EED);
        const r = rng.random();
        for (0..9) |len| {
            var idx: [9]u32 = undefined;
            var src: [9]f64 = undefined;
            for (0..len) |i| {
                idx[i] = @intCast(2 * i + 1); // distinct rows, as a CSC column is
                src[i] = r.float(f64) * 8 - 4;
            }
            var got = [_]f64{0} ** 20;
            var want = [_]f64{0} ** 20;
            for (&got, &want, 0..) |*g, *e, i| {
                g.* = @floatFromInt(i);
                e.* = g.*;
            }
            const f = r.float(f64) * 8 - 4;
            SparseLu(f64).test_access.scatterAxpy(&got, &idx, &src, 0, @intCast(len), f);
            for (0..len) |p| want[idx[p]] -= src[p] * f;
            try testing.expectEqualSlices(f64, &want, &got);
        }
    }

    test "w is all-zero after factor, after refactor, and after a failed refactor" {
        // `factor` reads 0 out of every fill row it does not scatter, so whatever
        // ran before it must hand `w` back clean — refactor's per-column zeroing
        // moved to the consumption sites and this is what pins it there. The
        // failure path matters most: it is the ONLY caller of `factor` after a
        // `refactor`, via direct.zig's fall back to a full re-pivoting factor.
        const gpa = testing.allocator;
        var a = [3][3]f64{
            .{ 10, 1, 0 },
            .{ 1, 10, 1 },
            .{ 0, 1, 10 },
        };
        var csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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

        // ...and the full factor that direct.zig now runs must agree with a
        // solver that never saw the failed replay.
        var fresh = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer fresh.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try fresh.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);
        try testing.expectEqualSlices(f64, fresh.lx.items, lu.lx.items);
        try testing.expectEqualSlices(f64, fresh.ux.items, lu.ux.items);
        try testing.expectEqualSlices(f64, fresh.udiag, lu.udiag);
    }

    test "solve and solveT in-place (b aliases x)" {
        const gpa = testing.allocator;
        const a = [2][2]f64{ .{ 3, 1 }, .{ 1, 2 } };
        const csc = DenseCsc(2).from(a);
        var q = identity(2);
        var lu = try SparseLu(f64).init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
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

    test "refactor then solve gives correct answer" {
        // Ensure the full round-trip: factor → refactor → solve works, not just
        // that refactor doesn't error.
        const gpa = testing.allocator;
        var a = [3][3]f64{
            .{ 5, 1, 0 },
            .{ 1, 5, 1 },
            .{ 0, 1, 5 },
        };
        var csc = DenseCsc(3).from(a);
        var q = identity(3);
        var lu = try SparseLu(f64).init(gpa, 3, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], csc.vals[0..csc.nnz()], 1e-3);

        // New values, same pattern
        a[0][0] = 8;
        a[1][0] = 2;
        a[2][2] = 9;
        csc = DenseCsc(3).from(a);
        try lu.refactor(&csc.col_ptr, csc.vals[0..csc.nnz()], 0);

        const b = [3]f64{ 10, 20, 30 };
        try checkSolve(3, a, b, &lu);
    }

    test "f32 instantiation compiles and solves" {
        const gpa = testing.allocator;
        const Lu32 = SparseLu(f32);
        const a = [2][2]f64{ .{ 4, 1 }, .{ 1, 3 } };
        const csc = DenseCsc(2).from(a);
        // Convert vals to f32
        var vals32: [4]f32 = undefined;
        for (csc.vals[0..csc.nnz()], 0..) |v, i| vals32[i] = @floatCast(v);
        var q = identity(2);
        var lu = try Lu32.init(gpa, 2, &csc.col_ptr, csc.row_idx[0..csc.nnz()], &q);
        defer lu.deinit(gpa);
        try lu.factor(gpa, &csc.col_ptr, csc.row_idx[0..csc.nnz()], vals32[0..csc.nnz()], 1e-3);

        var x: [2]f32 = undefined;
        lu.solve(&[2]f32{ 9, 7 }, &x);
        // [4 1; 1 3]x = [9;7] → x = [20/11, 19/11]
        try testing.expectApproxEqAbs(@as(f32, 20.0 / 11.0), x[0], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, 19.0 / 11.0), x[1], 1e-5);
    }

    test "SparseLu construction releases storage on every allocation failure" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn run(gpa: Allocator) !void {
                var lu = try SparseLu(f64).init(gpa, 3, &.{ 0, 3, 6, 9 }, &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 }, &.{ 0, 1, 2 });
                defer lu.deinit(gpa);
            }
        }.run, .{});
    }
};

const TridiagTests = struct {
    const impl = @import("solvers").tridiag;
    const TriDiag = impl.TriDiag;
    const isTridiag = impl.isTridiag;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    /// Build CSC from dense row-major matrix (test helper, comptime).
    fn CscResult(comptime n: usize, comptime nnz: usize) type {
        return struct {
            col_ptr: [n + 1]u32,
            row_idx: [nnz]u32,
            vals: [nnz]f64,
        };
    }

    fn countNnz(comptime n: usize, comptime dense: *const [n * n]f64) usize {
        var count: usize = 0;
        for (dense) |v| count += @intFromBool(v != 0);
        return count;
    }

    fn cscFromDense(comptime n: usize, comptime dense: *const [n * n]f64) CscResult(n, countNnz(n, dense)) {
        const nnz = comptime countNnz(n, dense);
        var col_ptr: [n + 1]u32 = undefined;
        var row_idx: [nnz]u32 = undefined;
        var vals: [nnz]f64 = undefined;

        var p: u32 = 0;
        col_ptr[0] = 0;
        for (0..n) |j| {
            for (0..n) |i| {
                const v = dense[i * n + j];
                if (v != 0) {
                    row_idx[p] = @intCast(i);
                    vals[p] = v;
                    p += 1;
                }
            }
            col_ptr[j + 1] = p;
        }

        return .{ .col_ptr = col_ptr, .row_idx = row_idx, .vals = vals };
    }

    /// Dense solve Ax = b for reference (Gaussian elimination with partial pivoting).
    fn denseSolve(comptime n: usize, mat: [n * n]f64, rhs: [n]f64) [n]f64 {
        var a = mat;
        var b = rhs;
        // Forward elimination with partial pivoting
        for (0..n) |k| {
            // Find pivot
            var max_val: f64 = @abs(a[k * n + k]);
            var max_row: usize = k;
            for (k + 1..n) |i| {
                const v = @abs(a[i * n + k]);
                if (v > max_val) {
                    max_val = v;
                    max_row = i;
                }
            }
            // Swap rows
            if (max_row != k) {
                for (0..n) |j| std.mem.swap(f64, &a[k * n + j], &a[max_row * n + j]);
                std.mem.swap(f64, &b[k], &b[max_row]);
            }
            // Eliminate
            for (k + 1..n) |i| {
                const m = a[i * n + k] / a[k * n + k];
                for (k + 1..n) |j| a[i * n + j] -= m * a[k * n + j];
                b[i] -= m * b[k];
            }
        }
        // Back substitution
        var x: [n]f64 = undefined;
        var ki: usize = n;
        while (ki > 0) {
            ki -= 1;
            var s = b[ki];
            for (ki + 1..n) |j| s -= a[ki * n + j] * x[j];
            x[ki] = s / a[ki * n + ki];
        }
        return x;
    }

    /// Transpose a dense row-major matrix.
    fn denseTranspose(comptime n: usize, mat: [n * n]f64) [n * n]f64 {
        var t: [n * n]f64 = undefined;
        for (0..n) |i| for (0..n) |j| {
            t[i * n + j] = mat[j * n + i];
        };
        return t;
    }

    test "TriDiag: 4x4 factor + solve vs dense reference" {
        const gpa = testing.allocator;
        // 4x4 tridiagonal:
        // [4  1  0  0]
        // [1  5  2  0]
        // [0  1  6  3]
        // [0  0  2  7]
        const dense = [16]f64{
            4, 1, 0, 0,
            1, 5, 2, 0,
            0, 1, 6, 3,
            0, 0, 2, 7,
        };
        const csc = cscFromDense(4, &dense);

        var td = try TriDiag(f64).init(gpa, 4, &csc.col_ptr, &csc.row_idx);
        defer td.deinit(gpa);

        try td.factor(&csc.vals);

        const rhs = [4]f64{ 7, 13, 20, 23 };
        var x = rhs;
        td.solve(&x);

        const ref = denseSolve(4, dense, rhs);
        for (0..4) |i| {
            try testing.expectApproxEqAbs(ref[i], x[i], 1e-12);
        }
    }

    test "TriDiag: solveT matches dense A^T solve" {
        const gpa = testing.allocator;
        const dense = [16]f64{
            4, 1, 0, 0,
            1, 5, 2, 0,
            0, 1, 6, 3,
            0, 0, 2, 7,
        };
        const csc = cscFromDense(4, &dense);

        var td = try TriDiag(f64).init(gpa, 4, &csc.col_ptr, &csc.row_idx);
        defer td.deinit(gpa);

        try td.factor(&csc.vals);

        const rhs = [4]f64{ 3, 9, 15, 21 };
        var x = rhs;
        td.solveT(&x);

        const at = denseTranspose(4, dense);
        const ref = denseSolve(4, at, rhs);
        for (0..4) |i| {
            try testing.expectApproxEqAbs(ref[i], x[i], 1e-12);
        }
    }

    test "TriDiag: singular detection (zero pivot)" {
        const gpa = testing.allocator;
        // Singular: second row becomes zero after elimination.
        // [1  1  0]
        // [1  1  0]   <- row 2 = row 1 => zero pivot
        // [0  0  1]
        const dense = [9]f64{
            1, 1, 0,
            1, 1, 0,
            0, 0, 1,
        };
        const csc = cscFromDense(3, &dense);

        var td = try TriDiag(f64).init(gpa, 3, &csc.col_ptr, &csc.row_idx);
        defer td.deinit(gpa);

        try testing.expectError(error.SingularMatrix, td.factor(&csc.vals));
    }

    test "isTridiag: tridiag detected" {
        // 4x4 tridiag
        const dense = [16]f64{
            4, 1, 0, 0,
            1, 5, 2, 0,
            0, 1, 6, 3,
            0, 0, 2, 7,
        };
        const csc = cscFromDense(4, &dense);
        try testing.expect(isTridiag(4, &csc.col_ptr, &csc.row_idx));
    }

    test "isTridiag: non-tridiag rejected" {
        // 4x4 with an off-tridiag entry at A[0,2]
        const dense = [16]f64{
            4, 1, 1, 0,
            1, 5, 2, 0,
            0, 1, 6, 3,
            0, 0, 2, 7,
        };
        const csc = cscFromDense(4, &dense);
        try testing.expect(!isTridiag(4, &csc.col_ptr, &csc.row_idx));
    }

    test "isTridiag: n < 3 rejected" {
        const col_ptr = [3]u32{ 0, 1, 2 };
        const row_idx = [2]u32{ 0, 1 };
        try testing.expect(!isTridiag(2, &col_ptr, &row_idx));
    }

    test "TriDiag: f32 factor + solve" {
        const gpa = testing.allocator;
        // 3x3 tridiag with f32
        const dense = [9]f64{
            3, 1, 0,
            1, 4, 2,
            0, 1, 5,
        };
        const csc = cscFromDense(3, &dense);

        var td = try TriDiag(f32).init(gpa, 3, &csc.col_ptr, &csc.row_idx);
        defer td.deinit(gpa);

        // Convert vals to f32
        var vals32: [csc.vals.len]f32 = undefined;
        for (csc.vals, 0..) |v, i| vals32[i] = @floatCast(v);

        try td.factor(&vals32);

        var x = [3]f32{ 5, 11, 12 };
        td.solve(&x);

        // Dense reference in f64, then compare with f32 tolerance
        const rhs64 = [3]f64{ 5, 11, 12 };
        const ref = denseSolve(3, dense, rhs64);
        for (0..3) |i| {
            try testing.expectApproxEqAbs(@as(f32, @floatCast(ref[i])), x[i], 1e-5);
        }
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
    _ = NewtonCoreTests;
    _ = OrderTests;
    _ = PreconditionerTests;
    _ = SparseTests;
    _ = TridiagTests;
}
