//! Lane-centric numeric sparse LU: W independent factorizations replaying ONE
//! frozen SparseLu(f64) symbolic factorization + pivot tape, values carried as
//! `[]@Vector(W, f64)` (AoSoA — lanes interleaved per structural entry).
//!
//! This is a mechanical f64 -> @Vector(W,f64) port of sparse_lu.zig's
//! numeric-only replay (`refactor`/`solve`/`solveT`): same index walks, same
//! op order, elementwise vector arithmetic. Because op order is preserved,
//! lane l of LaneLu(W) is bit-identical to a scalar SparseLu replay of lane l's
//! values — that is the test oracle. There is no separate scalar code path:
//! LaneLu(1) IS the scalar oracle.
//!
//! Scalar guards (singular/non-finite/pivot-growth) become per-lane masks
//! accumulated into `bad_lanes: u64`; a dead lane gets divisor 1.0 substituted
//! so its arithmetic stays finite and the surviving lanes stay exact. refactor
//! returns the mask; the caller peels bad lanes to the scalar full-factor
//! ladder (see solvers/direct.zig factorInner).
//!
//! Six questions (DOD):
//!  1. In: W value-planes for one frozen pattern + a borrowed factored
//!     SparseLu(f64). Out: W simultaneous LU factors + W simultaneous solves.
//!  2. How many: W lanes (native SIMD width) x nnz(L/U) entries, each a W-vector.
//!  3. How wide: values @Vector(W,f64); bad_lanes u64 (W <= 64 always);
//!     all indices borrowed from base as u32 — LaneLu stores none of its own.
//!  4. Access: replay walks base index arrays in exact scalar order; per entry
//!     one aligned vector load of interleaved lane values. Sequential.
//!  5. Lifetime: LaneLu owns lx/ux/udiag/w/y, allocated once, reused across
//!     every refactor/solve; dies with the solver. base borrowed, must outlive.
//!  6. Parallel: the lane axis IS the parallelism — W disjoint factorizations,
//!     zero cross-lane dependency (elementwise only). Perfect data parallelism.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sparse_lu = @import("sparse_lu.zig");

/// W numeric sparse-LU factorizations sharing one SparseLu(f64) pattern.
pub fn LaneLu(comptime W: usize) type {
    return struct {
        const Self = @This();
        const Base = sparse_lu.SparseLu(f64);
        pub const V = @Vector(W, f64);

        base: *const Base, // borrowed, must be .factored
        n: u32,

        // lane value planes, sized to the base's L/U counts (one V per entry)
        lx: []V,
        ux: []V,
        udiag: []V,

        // workspaces (length n each)
        w: []V,
        y: []V,

        /// Allocate the lane value planes and workspaces. `base` must already
        /// be `.factored` — its pattern, pivot tape (pinv/q/prow) and index
        /// arrays are borrowed, never copied.
        pub fn init(gpa: Allocator, base: *const Base) !Self {
            std.debug.assert(base.factored);
            const n = base.n;
            var self: Self = .{
                .base = base,
                .n = n,
                .lx = &.{},
                .ux = &.{},
                .udiag = &.{},
                .w = &.{},
                .y = &.{},
            };
            errdefer self.deinit(gpa);
            self.lx = try gpa.alloc(V, base.lx.items.len);
            self.ux = try gpa.alloc(V, base.ux.items.len);
            self.udiag = try gpa.alloc(V, n);
            self.w = try gpa.alloc(V, n);
            self.y = try gpa.alloc(V, n);
            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.lx);
            gpa.free(self.ux);
            gpa.free(self.udiag);
            gpa.free(self.w);
            gpa.free(self.y);
            self.* = undefined;
        }

        // ====================================================================
        // refactor: numeric-only replay, W lanes at once.
        // Twin of SparseLu.refactor. `vals` is interleaved: entry p, lane l is
        // vals[p][l]. Returns the bad-lane bitmask (bit l set => lane l failed
        // singular / non-finite / pivot-growth; its factors are unusable).
        // ====================================================================
        pub fn refactor(self: *Self, col_ptr: []const u32, vals: []const V, growth_limit: f64) u64 {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;
            const up = b.up;
            const lp = b.lp;
            const prow = b.prow;
            const one: V = @splat(1);
            const zero: V = @splat(0);
            var bad: u64 = 0;

            for (0..self.n) |k| {
                const c = b.q[k];
                // Zero the stored pattern, then scatter A[:,c] in permuted rows.
                for (ui[up[k]..up[k + 1]]) |i| self.w[i] = zero;
                for (li[lp[k]..lp[k + 1]]) |i| self.w[i] = zero;
                self.w[k] = zero;
                for (col_ptr[c]..col_ptr[c + 1]) |p| self.w[prow[p]] = vals[p];

                // Replay the triangular solve in stored topological order.
                for (up[k]..up[k + 1]) |p| {
                    const i = ui[p];
                    const uki = self.w[i];
                    self.ux[p] = uki;
                    for (lp[i]..lp[i + 1]) |pl| self.w[li[pl]] -= self.lx[pl] * uki;
                }

                var d = self.w[k];
                // Per-lane singular / non-finite: mask, then substitute 1.0 so
                // the surviving lanes' divisions stay finite and exact.
                const dead_diag = (d == zero) | isNotFinite(d);
                bad |= maskBits(dead_diag);
                d = @select(f64, dead_diag, one, d);
                self.udiag[k] = d;

                // `scaled_pivot` is a property of the SHARED base tape, so this
                // is an outer-loop branch with no lane divergence — lane l stays
                // bit-identical to a scalar SparseLu replay. Twin of
                // sparse_lu.zig refactor: a pivot accepted by the row-scaled
                // threshold test is legitimately far below its column max.
                if (growth_limit > 0 and !b.scaled_pivot[k]) {
                    var cmax = @abs(d);
                    for (lp[k]..lp[k + 1]) |p| {
                        const v = self.w[li[p]];
                        cmax = @max(cmax, @abs(v));
                        self.lx[p] = v / d;
                    }
                    // |d| < growth_limit * cmax => pivot decayed too far.
                    const grow: V = @splat(growth_limit);
                    bad |= maskBits(@abs(d) < grow * cmax);
                } else {
                    for (lp[k]..lp[k + 1]) |p| self.lx[p] = self.w[li[p]] / d;
                }
            }
            return bad;
        }

        // ====================================================================
        // solve: P -> L -> U -> Q substitution, W lanes. Twin of SparseLu.solve.
        // `b` and `x` interleaved [entry][lane]; may alias.
        // ====================================================================
        pub fn solve(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;

            // 1. y = P b
            for (b_in, 0..) |bi, r| self.y[b.pinv[r]] = bi;

            // 2. L y' = y (forward, unit lower). The `if (yk==0) continue` skip
            //    is dropped — cross-lane, and the arithmetic is a no-op anyway.
            for (0..self.n) |k| {
                const yk = self.y[k];
                for (b.lp[k]..b.lp[k + 1]) |p| self.y[li[p]] -= self.lx[p] * yk;
            }

            // 3. U z = y' (back)
            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = self.y[k] / self.udiag[k];
                self.y[k] = zk;
                for (b.up[k]..b.up[k + 1]) |p| self.y[ui[p]] -= self.ux[p] * zk;
            }

            // 4. x = Q^{-1} z
            for (b.q, 0..) |c, j| x[c] = self.y[j];
        }

        // ====================================================================
        // solveT: Q^T -> U^{-T} -> L^{-T} -> P^{-1}. Twin of SparseLu.solveT.
        // ====================================================================
        pub fn solveT(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;

            for (b.q, 0..) |c, k| self.y[k] = b_in[c];

            for (0..self.n) |k| {
                for (b.up[k]..b.up[k + 1]) |p| self.y[k] -= self.ux[p] * self.y[ui[p]];
                self.y[k] /= self.udiag[k];
            }

            var k = self.n;
            while (k > 0) {
                k -= 1;
                for (b.lp[k]..b.lp[k + 1]) |p| self.y[k] -= self.lx[p] * self.y[li[p]];
            }

            for (0..self.n) |r| x[r] = self.y[b.pinv[r]];
        }

        /// Per-lane non-finite test (NaN or +/-inf) -> bool vector.
        /// x != x catches NaN; !(|x| < inf) catches infinities (and NaN again).
        inline fn isNotFinite(x: V) @Vector(W, bool) {
            const inf: V = @splat(std.math.inf(f64));
            return !(@abs(x) < inf);
        }

        /// Bool vector -> per-lane bitmask (lane l -> bit l). Lane 0 = low bit.
        inline fn maskBits(m: @Vector(W, bool)) u64 {
            const bits: std.meta.Int(.unsigned, W) = @bitCast(m);
            return bits;
        }
    };
}

// ---- free functions: interleave / deinterleave / broadcast ----

/// Interleave W scalar planes (lanes[l] is lane l's values, length nnz) into
/// one AoSoA vector plane: out[p][l] = lanes[l][p].
pub fn interleave(comptime W: usize, lanes: []const []const f64, out: []@Vector(W, f64)) void {
    for (out, 0..) |*o, p| {
        var v: [W]f64 = undefined;
        inline for (0..W) |l| v[l] = lanes[l][p];
        o.* = v;
    }
}

/// Deinterleave an AoSoA vector plane back to W scalar planes:
/// lanes[l][p] = in[p][l].
pub fn deinterleave(comptime W: usize, in: []const @Vector(W, f64), lanes: []const []f64) void {
    for (in, 0..) |v, p| {
        const a: [W]f64 = v;
        inline for (0..W) |l| lanes[l][p] = a[l];
    }
}

/// Broadcast one scalar plane to every lane: out[p] = @splat(src[p]).
pub fn broadcast(comptime W: usize, src: []const f64, out: []@Vector(W, f64)) void {
    for (out, src) |*o, s| o.* = @splat(s);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

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

fn identity(comptime n: usize) [n]u32 {
    var q: [n]u32 = undefined;
    for (0..n) |i| q[i] = @intCast(i);
    return q;
}

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
