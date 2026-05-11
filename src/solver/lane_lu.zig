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

/// W numeric factorizations sharing one SparseLu pattern.
pub fn LaneLu(comptime W: usize) type {
    return struct {
        const Self = @This();
        const Base = sparse_lu.SparseLu;
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

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.lx);
            gpa.free(self.ux);
            gpa.free(self.udiag);
            gpa.free(self.w);
            gpa.free(self.y);
            self.* = undefined;
        }

        /// SparseLu.refactor for W lanes; `vals[p][l]` is entry p of lane l.
        /// Returns the mask of lanes whose pivot was zero, non-finite or
        /// below `growth_limit` times its column max (bit l = lane l); their
        /// factors are garbage. A void pivot in the base fails every lane.
        pub fn refactor(self: *Self, col_ptr: []const u32, vals: []const V, growth_limit: f64) u64 {
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
            const all_lanes: u64 = std.math.maxInt(std.meta.Int(.unsigned, W));
            var bad: u64 = 0;

            for (0..self.n) |k| {
                const c = b.q[k];
                for (col_ptr[c]..col_ptr[c + 1]) |p| w[prow[p]] = vals[p];

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
        /// scalar path there is no zero skip in the L sweep, so a zero result
        /// can differ from SparseLu's in sign.
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

        /// SparseLu.solveT for W lanes. `b_in` and `x` may alias.
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
            const bits: std.meta.Int(.unsigned, W) = @bitCast(m);
            // A no-op under LLVM; Zig 0.16's self-hosted x86 backend (Debug)
            // widens this bitcast with a stray bit W set.
            return @as(u64, bits) & std.math.maxInt(std.meta.Int(.unsigned, W));
        }
    };
}
