//! W sparse LU factorizations at once, replaying one frozen SparseLu
//! pattern and pivot sequence with values as `@Vector(W, f64)` per structural
//! entry. The walks and operation order are SparseLu's, so lane l's factors
//! are bitwise a scalar SparseLu replay of lane l's values; LaneLu(1) is
//! that oracle.
//! Lanes that fail a pivot guard are reported in a mask and substituted with
//! a unit divisor so the surviving lanes stay exact; the caller re-solves
//! them on the scalar path (freq_solve.zig `solveBatch`) or holds them
//! (`factorEach`). In: a factored SparseLu and W lanes of values. Out: W
//! lanes of L and U, and W-lane solves. Cites no outside source; the lane
//! axis is AGENTS.md §2.10.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const sparse_lu = @import("sparse_lu.zig");

/// W numeric factorizations sharing one SparseLu pattern. W is at most 64,
/// the width of the failure mask.
pub fn LaneLu(comptime W: usize) type {
    comptime {
        assert(W >= 1);
        assert(W <= 64);
    }
    return struct {
        const Self = @This();
        const Base = sparse_lu.SparseLu;
        /// One structural entry or unknown across the lanes: element l
        /// belongs to lane l's matrix.
        pub const V = @Vector(W, f64);

        /// Borrowed factored pattern and pivot sequence; must outlive self.
        base: *const Base,
        n: u32,

        // One vector per L entry, U entry and pivot step.
        lx: []V,
        ux: []V,
        udiag: []V,

        /// All-zero between calls, as in SparseLu.
        w: []V,
        y: []V,

        /// Sizes the value planes from `base`. A later full factor of `base`
        /// can change its L/U lengths; the caller then rebuilds the LaneLu.
        /// Asserts that `base` is factored.
        pub fn init(gpa: Allocator, base: *const Base) !Self {
            assert(base.factored);
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
            @memset(self.w, @as(V, @splat(0)));
            assert(self.planesMatch());
            return self;
        }

        /// True while `base` has the L/U lengths the planes were sized for.
        fn planesMatch(self: *const Self) bool {
            return self.lx.len == self.base.lx.items.len and self.ux.len == self.base.ux.items.len;
        }

        /// Frees the value planes; `base` stays the caller's.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.lx);
            gpa.free(self.ux);
            gpa.free(self.udiag);
            gpa.free(self.w);
            gpa.free(self.y);
            self.* = undefined;
        }

        /// A W-lane matrix stored whole: `vals[p][l]` is CSC entry p of lane
        /// l. The `refactor` source for callers that already hold the values.
        pub const Plane = struct {
            col_ptr: []const u32,
            vals: []const V,

            /// Writes column `c`'s entries to `w`, entry p at row `prow[p]`.
            pub inline fn load(self: Plane, c: usize, w: []V, prow: []const u32) void {
                for (self.col_ptr[c]..self.col_ptr[c + 1]) |p| w[prow[p]] = self.vals[p];
            }
        };

        /// SparseLu.refactor for W lanes. `src` hands over one column at a
        /// time through `load(c, w, prow)`, which must write column c's
        /// entries into `w` exactly as `Plane.load` would; a source that
        /// computes them on the fly (freq_solve.zig `Stacked`) holds no
        /// value plane. Returns the mask of lanes whose pivot was zero,
        /// non-finite or below `growth_limit` times its column max, or that
        /// stored a non-finite L or U entry (bit l = lane l); their factors
        /// are garbage. A void pivot in the base fails every lane. Asserts
        /// that `base` is factored and still has the L/U lengths `init`
        /// sized the planes for.
        pub fn refactor(self: *Self, src: anytype, growth_limit: f64) u64 {
            const b = self.base;
            assert(b.factored);
            assert(self.planesMatch());
            const li = b.li.items;
            const ui = b.ui.items;
            const up = b.up;
            const lp = b.lp;
            const prow = b.prow;
            const q = b.q;
            const void_col = b.void_col;
            const scaled_pivot = b.scaled_pivot;
            // Locals, not fields: a `[]V` store may alias `self` or `base`.
            const w = self.w;
            const lx = self.lx;
            const ux = self.ux;
            const udiag = self.udiag;
            const one: V = @splat(1);
            const zero: V = @splat(0);
            const inf: V = @splat(std.math.inf(f64));
            const all_lanes: u64 = std.math.maxInt(@Int(.unsigned, W));
            var bad: u64 = 0;
            // Nonzero in a lane that stored a NaN or inf L or U entry: the
            // bits of x - x, as SparseLu's replay ORs them. Folded into
            // `bad` once, at the end.
            var nonfinite: @Vector(W, u64) = @splat(0);

            for (0..self.n) |k| {
                src.load(q[k], w, prow);

                // Triangular solve in stored topological order; each slot is
                // zeroed as it is consumed.
                for (up[k]..up[k + 1]) |p| {
                    const i = ui[p];
                    const uki = w[i];
                    w[i] = zero;
                    ux[p] = uki;
                    nonfinite |= @as(@Vector(W, u64), @bitCast(uki - uki));
                    for (lp[i]..lp[i + 1]) |pl| w[li[pl]] -= lx[pl] * uki;
                }

                // The void-pivot logic stays on the scalar path.
                if (void_col[k]) {
                    @memset(w, zero);
                    return all_lanes;
                }
                var d = w[k];
                w[k] = zero;
                const dead_diag = (d == zero) | !(@abs(d) < inf);
                bad |= maskBits(dead_diag);
                d = @select(f64, dead_diag, one, d);
                udiag[k] = d;

                // `scaled_pivot` belongs to the shared tape, so this branch
                // never diverges across lanes.
                if (growth_limit > 0 and !scaled_pivot[k]) {
                    // SparseLu's bit-pattern max: NaN survives it and fails
                    // the test, so these L entries need no flag.
                    const I = @Vector(W, i64);
                    var cbits: I = @bitCast(@abs(d));
                    for (lp[k]..lp[k + 1]) |p| {
                        const r = li[p];
                        const v = w[r];
                        w[r] = zero;
                        cbits = @max(cbits, @as(I, @bitCast(@abs(v))));
                        lx[p] = v / d;
                    }
                    const cmax: V = @bitCast(cbits);
                    const grow: V = @splat(growth_limit);
                    bad |= maskBits(!(@abs(d) >= grow * cmax));
                } else {
                    for (lp[k]..lp[k + 1]) |p| {
                        const r = li[p];
                        const l = w[r] / d;
                        nonfinite |= @as(@Vector(W, u64), @bitCast(l - l));
                        lx[p] = l;
                        w[r] = zero;
                    }
                }
            }
            bad |= maskBits(nonfinite != @as(@Vector(W, u64), @splat(0)));
            assert(bad & ~all_lanes == 0);
            return bad;
        }

        /// SparseLu.solve for W lanes, bitwise its result per lane: a lane
        /// whose y[k] is zero subtracts +0, which leaves every value as
        /// SparseLu's zero skip does, signed zeros included. `b_in` and `x`
        /// may alias. A lane `refactor` masked holds garbage. Asserts that
        /// `b_in` has n entries, `x` at least n, and that the planes still
        /// fit `base`.
        pub fn solve(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            assert(b_in.len == self.n);
            assert(x.len >= self.n);
            assert(self.planesMatch());
            const li = b.li.items;
            const ui = b.ui.items;
            const lp = b.lp;
            const up = b.up;
            const lx = self.lx;
            const ux = self.ux;
            const udiag = self.udiag;
            const y = self.y;
            const pinv = b.pinv;

            const zero: V = @splat(0);
            for (b_in, 0..) |bi, r| y[pinv[r]] = bi;

            for (0..self.n) |k| {
                const yk = y[k];
                const live = yk != zero;
                for (lp[k]..lp[k + 1]) |p| y[li[p]] -= @select(f64, live, lx[p] * yk, zero);
            }

            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k] / udiag[k];
                y[k] = zk;
                const live = zk != zero;
                for (up[k]..up[k + 1]) |p| y[ui[p]] -= @select(f64, live, ux[p] * zk, zero);
            }

            for (b.q, 0..) |c, j| x[c] = y[j];
        }

        /// SparseLu.solveT for W lanes, bitwise its result per lane. `b_in`
        /// and `x` may alias. A lane `refactor` masked holds garbage. Asserts
        /// as `solve` does.
        pub fn solveT(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            assert(b_in.len == self.n);
            assert(x.len >= self.n);
            assert(self.planesMatch());
            const li = b.li.items;
            const ui = b.ui.items;
            const lp = b.lp;
            const up = b.up;
            const lx = self.lx;
            const ux = self.ux;
            const udiag = self.udiag;
            const y = self.y;
            const pinv = b.pinv;

            for (b.q, 0..) |c, k| y[k] = b_in[c];

            for (0..self.n) |k| {
                var yk = y[k];
                for (up[k]..up[k + 1]) |p| yk -= ux[p] * y[ui[p]];
                y[k] = yk / udiag[k];
            }

            var k = self.n;
            while (k > 0) {
                k -= 1;
                var yk = y[k];
                for (lp[k]..lp[k + 1]) |p| yk -= lx[p] * y[li[p]];
                y[k] = yk;
            }

            for (0..self.n) |r| x[r] = y[pinv[r]];
        }

        /// Lane l of `m` -> bit l.
        inline fn maskBits(m: @Vector(W, bool)) u64 {
            const bits: @Int(.unsigned, W) = @bitCast(m);
            // A no-op under LLVM; Zig 0.16's self-hosted x86 backend (Debug)
            // widens this bitcast with a stray bit W set.
            return @as(u64, bits) & std.math.maxInt(@Int(.unsigned, W));
        }
    };
}

const testing = std.testing;

test "LaneLu(W) lane l is the scalar replay of lane l on random systems, NaN and Inf lanes included" {
    // W = 1 is the scalar oracle itself.
    try expectLanesReplay(1);
    try expectLanesReplay(std.simd.suggestVectorLength(f64) orelse 4);
}

fn expectLanesReplay(comptime W: usize) !void {
    const gpa = testing.allocator;
    const L = LaneLu(W);
    const SparseLu = sparse_lu.SparseLu;
    const Sys = SparseLu.test_access.TestSystem;
    var prng = std.Random.DefaultPrng.init(0x1a7e5);
    const r = prng.random();
    for (0..96) |t| {
        const n: u32 = @intCast(1 + t % 24);
        const sys = try Sys.init(gpa, r, n, 0.25);
        defer sys.deinit(gpa);
        const nnz = sys.vals.len;
        const q = try gpa.alloc(u32, n);
        defer gpa.free(q);
        for (q, 0..) |*c, i| c.* = @intCast(i);
        r.shuffle(u32, q);
        var base = try SparseLu.init(gpa, n, sys.col_ptr, q);
        defer base.deinit(gpa);
        base.factor(gpa, sys.col_ptr, sys.row_idx, sys.vals, 1e-3) catch continue;
        var ll = try L.init(gpa, &base);
        defer ll.deinit(gpa);

        // Lane l scales every entry by 1 +- 10%; some lanes also get one
        // NaN or Inf entry, which must fail exactly when the scalar replay
        // fails.
        const lane_vals = try gpa.alloc([W]f64, nnz);
        defer gpa.free(lane_vals);
        var finite: [W]bool = @splat(true);
        for (0..W) |l| {
            for (lane_vals, sys.vals) |*v, a| v[l] = a * (0.9 + 0.2 * r.float(f64));
            const bad_val: f64 = switch (r.uintLessThan(u8, 6)) {
                0 => std.math.nan(f64),
                1 => -std.math.inf(f64),
                else => continue, // else: the other four draws keep the lane finite
            };
            lane_vals[r.uintLessThan(usize, nnz)][l] = bad_val;
            finite[l] = false;
        }
        const plane = try gpa.alloc(L.V, nnz);
        defer gpa.free(plane);
        for (plane, lane_vals) |*v, a| v.* = a;
        const mask = ll.refactor(L.Plane{ .col_ptr = sys.col_ptr, .vals = plane }, 1e-12);
        for (ll.w) |v| try testing.expect(@reduce(.And, v == @as(L.V, @splat(0))));

        const bufs = try gpa.alloc(f64, 3 * @as(usize, n));
        defer gpa.free(bufs);
        const rhs = bufs[0..n];
        const xs = bufs[n .. 2 * n];
        const xt = bufs[2 * n ..];
        const col = try gpa.alloc(f64, nnz);
        defer gpa.free(col);
        for (rhs) |*v| v.* = 2 * r.float(f64) - 1;
        const lv = try gpa.alloc(L.V, 3 * @as(usize, n));
        defer gpa.free(lv);
        const lb = lv[0..n];
        const lx = lv[n .. 2 * n];
        const lxt = lv[2 * n ..];
        for (lb, rhs) |*o, v| o.* = @splat(v);
        ll.solve(lb, lx);
        ll.solveT(lb, lxt);

        for (0..W) |l| {
            for (col, lane_vals) |*o, v| o.* = v[l];
            const scalar_bad = if (base.refactor(sys.col_ptr, col, 1e-12)) |_| false else |_| true;
            try testing.expectEqual(scalar_bad, (mask >> @intCast(l)) & 1 != 0);
            if (scalar_bad or !finite[l]) continue;
            base.solve(rhs, xs);
            base.solveT(rhs, xt);
            for (xs, xt, lx, lxt) |a, at, vx, vt| {
                const x_l: [W]f64 = vx;
                const t_l: [W]f64 = vt;
                try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(x_l[l])));
                try testing.expectEqual(@as(u64, @bitCast(at)), @as(u64, @bitCast(t_l[l])));
            }
        }
    }
}

test "LaneLu masks a lane whose finite values overflow in U off the pivot; the others stay bitwise" {
    const gpa = testing.allocator;
    const W = 4;
    const L = LaneLu(W);
    const SparseLu = sparse_lu.SparseLu;
    const c = SparseLu.test_access.overflow_case;
    var base = try SparseLu.init(gpa, 3, &c.col_ptr, &c.q);
    defer base.deinit(gpa);
    try base.factor(gpa, &c.col_ptr, &c.row_idx, &c.benign_vals, 1e-3);
    var ll = try L.init(gpa, &base);
    defer ll.deinit(gpa);
    // Lane 2 overflows; lane l of the rest scales A by l + 1.
    var plane: [c.benign_vals.len]L.V = undefined;
    for (&plane, c.benign_vals, c.overflow_vals) |*v, a, o| {
        v.* = .{ a, 2 * a, o, 4 * a };
    }
    for ([_]f64{ 1e-12, 0 }) |growth| {
        try testing.expectEqual(@as(u64, 1 << 2), ll.refactor(L.Plane{ .col_ptr = &c.col_ptr, .vals = &plane }, growth));
        for (0..W) |l| {
            if (l == 2) continue;
            var col: [plane.len]f64 = undefined;
            for (&col, plane) |*o, v| o.* = @as([W]f64, v)[l];
            try base.refactor(&c.col_ptr, &col, growth);
            for (base.ux.items, ll.ux) |s, v| try testing.expectEqual(@as(u64, @bitCast(s)), @as(u64, @bitCast(@as([W]f64, v)[l])));
            for (base.lx.items, ll.lx) |s, v| try testing.expectEqual(@as(u64, @bitCast(s)), @as(u64, @bitCast(@as([W]f64, v)[l])));
            for (base.udiag, ll.udiag) |s, v| try testing.expectEqual(@as(u64, @bitCast(s)), @as(u64, @bitCast(@as([W]f64, v)[l])));
        }
    }
}
