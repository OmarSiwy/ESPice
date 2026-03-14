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
        /// All-zero between calls; `refactor` zeroes each slot as it consumes it.
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
            // Locals, not `self.` fields: a `[]V` store may alias `self`, so
            // field access reloaded both slice pointers on every axpy element.
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
                // `w` is all-zero here: every slot this column writes is zeroed
                // below as it is consumed (SparseLu.refactor's invariant).
                for (col_ptr[c]..col_ptr[c + 1]) |p| w[prow[p]] = vals[p];

                // Replay the triangular solve in stored topological order. No
                // later entry of this column writes w[i] once it is read.
                for (up[k]..up[k + 1]) |p| {
                    const i = ui[p];
                    const uki = w[i];
                    w[i] = zero;
                    ux[p] = uki;
                    for (lp[i]..lp[i + 1]) |pl| w[li[pl]] -= lx[pl] * uki;
                }

                // A fabricated (void) pivot is not replayed: every lane fails
                // and peels to the scalar ladder, which owns the void logic.
                if (b.void_col[k]) {
                    @memset(w, zero);
                    return all_lanes;
                }
                var d = w[k];
                w[k] = zero;
                // Per-lane singular / non-finite: mask, then substitute 1.0 so
                // the surviving lanes' divisions stay finite and exact.
                const dead_diag = (d == zero) | !(@abs(d) < inf);
                bad |= maskBits(dead_diag);
                d = @select(f64, dead_diag, one, d);
                udiag[k] = d;

                // `scaled_pivot` is a property of the SHARED base tape, so this
                // is an outer-loop branch with no lane divergence — lane l stays
                // bit-identical to a scalar SparseLu replay. Twin of
                // sparse_lu.zig refactor: a pivot accepted by the row-scaled
                // threshold test is legitimately far below its column max.
                if (growth_limit > 0 and !b.scaled_pivot[k]) {
                    var cmax = @abs(d);
                    for (lp[k]..lp[k + 1]) |p| {
                        const r = li[p];
                        const v = w[r];
                        w[r] = zero;
                        cmax = @max(cmax, @abs(v));
                        lx[p] = v / d;
                    }
                    // |d| < growth_limit * cmax => pivot decayed too far.
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

        // ====================================================================
        // solve: P -> L -> U -> Q substitution, W lanes. Twin of SparseLu.solve.
        // `b` and `x` interleaved [entry][lane]; may alias.
        // ====================================================================
        pub fn solve(self: *Self, b_in: []const V, x: []V) void {
            const b = self.base;
            const li = b.li.items;
            const ui = b.ui.items;
            const lp = b.lp;
            const up = b.up;
            const lx = self.lx;
            const ux = self.ux;
            const y = self.y;

            // 1. y = P b
            for (b_in, 0..) |bi, r| y[b.pinv[r]] = bi;

            // 2. L y' = y (forward, unit lower). The `if (yk==0) continue` skip
            //    is dropped — cross-lane, and the arithmetic is a no-op anyway.
            for (0..self.n) |k| {
                const yk = y[k];
                for (lp[k]..lp[k + 1]) |p| y[li[p]] -= lx[p] * yk;
            }

            // 3. U z = y' (back)
            var k = self.n;
            while (k > 0) {
                k -= 1;
                const zk = y[k] / self.udiag[k];
                y[k] = zk;
                for (up[k]..up[k + 1]) |p| y[ui[p]] -= ux[p] * zk;
            }

            // 4. x = Q^{-1} z
            for (b.q, 0..) |c, j| x[c] = y[j];
        }

        // ====================================================================
        // solveT: Q^T -> U^{-T} -> L^{-T} -> P^{-1}. Twin of SparseLu.solveT.
        // ====================================================================
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

        /// Bool vector -> per-lane bitmask (lane l -> bit l). Lane 0 = low bit.
        inline fn maskBits(m: @Vector(W, bool)) u64 {
            const bits: std.meta.Int(.unsigned, W) = @bitCast(m);
            // A no-op under LLVM. Zig 0.16's self-hosted x86 backend (Debug
            // builds) widens this bitcast with a stray bit W set: an all-false
            // 4-lane mask read back as 16.
            return @as(u64, bits) & std.math.maxInt(std.meta.Int(.unsigned, W));
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
