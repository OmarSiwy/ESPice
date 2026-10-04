//! W sparse LU factorizations at once, replaying one frozen SparseLu
//! pattern and pivot sequence with values as `@Vector(W, f64)` per structural
//! entry. The walks and operation order are SparseLu's, so lane l's factors
//! are bitwise a scalar SparseLu replay of lane l's values; LaneLu(1) is
//! that oracle.
//! Lanes that fail a pivot guard are reported in a mask and substituted with
//! a unit divisor so the surviving lanes stay exact; the caller re-solves
//! them on the scalar path (freq_solve.zig `solveBatch`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const sparse_lu = @import("sparse_lu.zig");

/// W numeric factorizations sharing one SparseLu pattern. W is at most 64,
/// the width of the failure mask.
pub fn LaneLu(comptime W: usize) type {
    comptime std.debug.assert(W >= 1 and W <= 64);
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

        /// Sizes the value planes from `base`, which must be factored. A later
        /// full factor of `base` can change its L/U lengths; the caller then
        /// rebuilds the LaneLu.
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
            @memset(self.w, @as(V, @splat(0)));
            return self;
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
        /// non-finite or below `growth_limit` times its column max (bit l =
        /// lane l); their factors are garbage. A void pivot in the base fails
        /// every lane.
        pub fn refactor(self: *Self, src: anytype, growth_limit: f64) u64 {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;
            const up = b.up;
            const lp = b.lp;
            const prow = b.prow;
            // Locals, not fields: a `[]V` store may alias `self`.
            const w = self.w;
            const lx = self.lx;
            const ux = self.ux;
            const udiag = self.udiag;
            const one: V = @splat(1);
            const zero: V = @splat(0);
            const inf: V = @splat(std.math.inf(f64));
            const all_lanes: u64 = std.math.maxInt(@Int(.unsigned, W));
            var bad: u64 = 0;

            for (0..self.n) |k| {
                src.load(b.q[k], w, prow);

                // Triangular solve in stored topological order; each slot is
                // zeroed as it is consumed.
                for (up[k]..up[k + 1]) |p| {
                    const i = ui[p];
                    const uki = w[i];
                    w[i] = zero;
                    ux[p] = uki;
                    for (lp[i]..lp[i + 1]) |pl| w[li[pl]] -= lx[pl] * uki;
                }

                // The void-pivot logic stays on the scalar path.
                if (b.void_col[k]) {
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
                if (growth_limit > 0 and !b.scaled_pivot[k]) {
                    var cmax = @abs(d);
                    for (lp[k]..lp[k + 1]) |p| {
                        const r = li[p];
                        const v = w[r];
                        w[r] = zero;
                        cmax = @max(cmax, @abs(v));
                        lx[p] = v / d;
                    }
                    const grow: V = @splat(growth_limit);
                    bad |= maskBits(@abs(d) < grow * cmax);
                } else {
                    for (lp[k]..lp[k + 1]) |p| {
                        const r = li[p];
                        lx[p] = w[r] / d;
                        w[r] = zero;
                    }
                }
            }
            return bad;
        }

        /// SparseLu.solve for W lanes. `b_in` and `x` may alias. Unlike the
        /// scalar path there is no zero skip in either sweep, so a zero result
        /// can differ from SparseLu's in sign, and a lane whose factors hold
        /// an Inf or NaN can turn 0 * Inf into NaN where SparseLu skipped it.
        /// A lane `refactor` masked holds garbage.
        pub fn solve(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;
            const lp = b.lp;
            const up = b.up;
            const lx = self.lx;
            const ux = self.ux;
            const y = self.y;

            for (b_in, 0..) |bi, r| y[b.pinv[r]] = bi;

            for (0..self.n) |k| {
                const yk = y[k];
                for (lp[k]..lp[k + 1]) |p| y[li[p]] -= lx[p] * yk;
            }

            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k] / self.udiag[k];
                y[k] = zk;
                for (up[k]..up[k + 1]) |p| y[ui[p]] -= ux[p] * zk;
            }

            for (b.q, 0..) |c, j| x[c] = y[j];
        }

        /// SparseLu.solveT for W lanes, bitwise its result per lane. `b_in`
        /// and `x` may alias. A lane `refactor` masked holds garbage.
        pub fn solveT(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;
            const lp = b.lp;
            const up = b.up;
            const lx = self.lx;
            const ux = self.ux;
            const y = self.y;

            for (b.q, 0..) |c, k| y[k] = b_in[c];

            for (0..self.n) |k| {
                var yk = y[k];
                for (up[k]..up[k + 1]) |p| yk -= ux[p] * y[ui[p]];
                y[k] = yk / self.udiag[k];
            }

            var k = self.n;
            while (k > 0) {
                k -= 1;
                var yk = y[k];
                for (lp[k]..lp[k + 1]) |p| yk -= lx[p] * y[li[p]];
                y[k] = yk;
            }

            for (0..self.n) |r| x[r] = y[b.pinv[r]];
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
    const gpa = testing.allocator;
    const W = comptime std.simd.suggestVectorLength(f64) orelse 4;
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
        var base = try SparseLu.init(gpa, n, sys.col_ptr, sys.row_idx, q);
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
                else => continue,
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
                // solve: equal up to the sign of a zero; solveT: bitwise.
                try testing.expect(a == x_l[l]);
                try testing.expectEqual(@as(u64, @bitCast(at)), @as(u64, @bitCast(t_l[l])));
            }
        }
    }
}
