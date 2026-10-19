//! W Newton linear solves at once, each lane bitwise its own scalar
//! `direct.Solver`. Lane l keeps that solver (its engine, pivot history and
//! bypass copy); every lane whose pivot tape equals a lead lane's refactors
//! and solves on one `LaneLu(W)` over the lead's tape instead. A lane the
//! vector replay cannot stand in for is peeled: it factors and solves on its
//! own solver, deinterleaved. That is a lane whose pivot guard failed, whose
//! replay kept a multiplier a scalar `factor` would probe (`replayHolds`),
//! whose last factor was scalar on these same values (the scalar bypass), or
//! whose tape differs. A vector lane leaves its solver as a device factor
//! does: `vcopy` holds its values and `host_stale` makes the next host use
//! replay them (`direct.Solver.syncHost`).
//!
//! In: W solvers on one pattern, W lanes of values and right-hand sides.
//! Out: W lanes of -A^-1 rhs, and the lanes whose own factor failed.
//! dev/research/lane-batched-simulation.md §6 (direct solve row).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const direct = @import("direct.zig");
const SparseLu = @import("sparse_lu.zig").SparseLu;
const LaneLu = @import("lane_lu.zig").LaneLu;
const Lanes = @import("lanes.zig").Lanes;
const Execution = @import("core").numerics.Execution;

pub fn LaneSolver(comptime W: usize) type {
    comptime assert(W >= 2); // W = 1 is `direct.Solver` itself
    return struct {
        const Self = @This();
        const L = Lanes(W);
        pub const V = L.V;
        pub const Mask = L.Mask;

        /// Lane l's own solver, borrowed; all on one pattern.
        lanes: [W]*direct.Solver,
        /// The replay over `lanes[lead]`'s tape; null while no lane has a
        /// factored sparse LU.
        lu: ?LaneLu(W) = null,
        lead: usize = 0,
        /// Lanes whose tape is the lead's, the lead included.
        joined: Mask = L.none,
        /// Each lane's `tapeKey` when `joined` was last computed.
        keys: [W]u64 = @splat(no_lu),
        /// Deinterleave scratch: nnz values, then n of right-hand side.
        scratch: []f64,
        gpa: Allocator,

        const no_lu = std.math.maxInt(u64);

        /// Borrows `lanes`, which must share one pattern and keep their
        /// bypass copies. Fails only on allocation.
        pub fn init(gpa: Allocator, lanes: [W]*direct.Solver) !Self {
            const s0 = lanes[0];
            for (lanes) |s| {
                assert(s.n == s0.n);
                assert(s.col_ptr.ptr == s0.col_ptr.ptr or std.mem.eql(u32, s.col_ptr, s0.col_ptr));
                assert(s.vcopy.len == s0.col_ptr[s0.n]);
                assert(s.params.refactor_growth_limit == s0.params.refactor_growth_limit);
            }
            return .{ .lanes = lanes, .scratch = try gpa.alloc(f64, s0.col_ptr[s0.n] + @as(usize, s0.n)), .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            if (self.lu) |*lu| lu.deinit(self.gpa);
            self.gpa.free(self.scratch);
            self.* = undefined;
        }

        /// dx = -A_l^-1 rhs_l for every lane l in `m`, A_l being lane l of
        /// `vals` (pattern order), bitwise `lanes[l].factor` then `solveNeg`.
        /// Returns the lanes whose factor failed with `error.SingularMatrix`;
        /// their dx is garbage, as is every lane outside `m`. Other factor
        /// errors (out of memory) fail the call. `rhs` and `dx` hold n
        /// entries, `vals` nnz.
        pub fn factorSolveNeg(self: *Self, vals: []const V, rhs: []const V, dx: []V, m: Mask, execution: Execution) !Mask {
            const s0 = self.lanes[0];
            const n = s0.n;
            const nnz = s0.col_ptr[n];
            assert(vals.len >= nnz);
            assert(rhs.len >= n and dx.len >= n);
            try self.rejoin();

            var peel = m & ~self.joined;
            var vector = m & self.joined;
            // The scalar bypass: a lane whose own solver last factored these
            // values solves on those factors, which may be a full factor's.
            var it = L.each(vector);
            while (it.next()) |l| {
                const s = self.lanes[l];
                if (s.factored and !s.host_stale and laneEql(s.vcopy, vals, l)) peel |= bit(l);
            }
            vector &= ~peel;
            if (L.any(vector)) {
                const lu = &self.lu.?;
                const growth = s0.params.refactor_growth_limit;
                var bad: Mask = @truncate(lu.refactor(LaneLu(W).Plane{ .col_ptr = s0.col_ptr, .vals = vals }, growth));
                bad |= self.wideMultipliers();
                peel |= vector & bad;
                vector &= ~bad;
                for (dx[0..n], rhs[0..n]) |*d, r| d.* = -r;
                lu.solve(dx[0..n], dx[0..n]);
                it = L.each(vector);
                while (it.next()) |l| {
                    const s = self.lanes[l];
                    for (s.vcopy, vals[0..nnz]) |*c, v| c.* = L.lane(v, l);
                    s.host_stale = true;
                    s.gen +%= 1;
                }
            }

            var singular: Mask = L.none;
            const v_l = self.scratch[0..nnz];
            const x_l = self.scratch[nnz..][0..n];
            it = L.each(peel);
            while (it.next()) |l| {
                const s = self.lanes[l];
                for (v_l, vals[0..nnz]) |*o, v| o.* = L.lane(v, l);
                s.factor(v_l, execution) catch |e| switch (e) {
                    error.SingularMatrix => {
                        singular |= bit(l);
                        continue;
                    },
                    else => |other| return other,
                };
                for (x_l, rhs[0..n]) |*o, r| o.* = L.lane(r, l);
                s.solveNeg(x_l, x_l);
                for (dx[0..n], x_l) |*d, x| d.* = putLane(d.*, l, x);
            }
            return singular;
        }

        inline fn bit(l: usize) Mask {
            return @as(Mask, 1) << @intCast(l);
        }

        fn putLane(v: V, l: usize, x: f64) V {
            var a: [W]f64 = v;
            a[l] = x;
            return a;
        }

        fn laneEql(copy: []const f64, vals: []const V, l: usize) bool {
            for (copy, vals[0..copy.len]) |c, v| if (!(c == L.lane(v, l))) return false;
            return true;
        }

        /// Lanes whose replay kept an L multiplier above 1 / `pivot_tol`
        /// off the scaled pivots: the bound `direct`'s `replayHolds`
        /// passes at once, so the scalar path would probe them. NaN fails.
        fn wideMultipliers(self: *const Self) Mask {
            const lu = &self.lu.?;
            const b = lu.base;
            const I = @Vector(W, u64);
            var worst: I = @splat(0);
            for (0..b.n) |k| {
                if (b.scaled_pivot[k]) continue;
                for (lu.lx[b.lp[k]..b.lp[k + 1]]) |x| worst = @max(worst, @as(I, @bitCast(@abs(x))));
            }
            const m: V = @bitCast(worst);
            return ~L.cmp(.lte, m, L.splat(1 / direct.pivot_tol));
        }

        /// Identifies lane l's tape: its sparse LU's pattern epoch, or
        /// `no_lu` while it has no factored sparse LU (a structured engine,
        /// or a failed factor).
        fn tapeKey(s: *direct.Solver) u64 {
            const lu = s.sparse() orelse return no_lu;
            return if (lu.factored) lu.pattern_epoch else no_lu;
        }

        /// After any lane's tape changed: lead = the first lane with a
        /// factored sparse LU, `lu` rebuilt over it, and `joined` = the
        /// lanes whose tape equals the lead's.
        fn rejoin(self: *Self) !void {
            var keys: [W]u64 = undefined;
            for (&keys, self.lanes) |*k, s| k.* = tapeKey(s);
            if (std.mem.eql(u64, &keys, &self.keys)) return;
            self.keys = keys;
            if (self.lu) |*lu| lu.deinit(self.gpa);
            self.lu = null;
            self.joined = L.none;
            const lead = std.mem.indexOfNone(u64, &keys, &.{no_lu}) orelse return;
            self.lead = lead;
            const base = self.lanes[lead].sparse().?;
            self.lu = try LaneLu(W).init(self.gpa, base);
            for (self.lanes, keys, 0..) |s, k, l| {
                if (k != no_lu and sameTape(s.sparse().?, base)) self.joined |= bit(l);
            }
            assert(self.joined & bit(lead) != 0);
        }

        /// Whether a replay on `a` runs `b`'s operations: same ordering,
        /// pivots, L and U structure, and fabricated or scaled pivots.
        fn sameTape(a: *const SparseLu, b: *const SparseLu) bool {
            if (a == b) return true;
            return std.mem.eql(u32, a.q, b.q) and std.mem.eql(u32, a.pinv, b.pinv) and
                std.mem.eql(u32, a.lp, b.lp) and std.mem.eql(u32, a.li.items, b.li.items) and
                std.mem.eql(u32, a.up, b.up) and std.mem.eql(u32, a.ui.items, b.ui.items) and
                std.mem.eql(bool, a.void_col, b.void_col) and std.mem.eql(bool, a.scaled_pivot, b.scaled_pivot);
        }
    };
}

const testing = std.testing;

test "LaneSolver(W) lane l is bitwise its own scalar factor and solveNeg, through re-pivots, singular lanes and bypasses" {
    try expectLanesMatch(2);
    try expectLanesMatch(std.simd.suggestVectorLength(f64) orelse 4);
}

fn expectLanesMatch(comptime W: usize) !void {
    const gpa = testing.allocator;
    const S = LaneSolver(W);
    const Sys = SparseLu.test_access.TestSystem;
    var prng = std.Random.DefaultPrng.init(0x1a7e50);
    const r = prng.random();
    var vector_lanes: usize = 0;
    var peeled_lanes: usize = 0;
    for (0..64) |t| {
        const n: u32 = @intCast(2 + t % 20);
        const sys = try Sys.init(gpa, r, n, 0.3);
        defer sys.deinit(gpa);
        const nnz = sys.vals.len;
        var mine: [W]direct.Solver = undefined;
        var refs: [W]direct.Solver = undefined;
        var ptrs: [W]*direct.Solver = undefined;
        for (&mine, &refs, &ptrs) |*a, *b, *p| {
            a.* = try direct.Solver.init(gpa, n, sys.col_ptr, sys.row_idx, null, .{});
            b.* = try direct.Solver.init(gpa, n, sys.col_ptr, sys.row_idx, null, .{});
            p.* = a;
        }
        defer for (&mine, &refs) |*a, *b| {
            a.deinit();
            b.deinit();
        };
        var ls = try S.init(gpa, ptrs);
        defer ls.deinit();

        const vals = try gpa.alloc(S.V, nnz);
        defer gpa.free(vals);
        const rhs = try gpa.alloc(S.V, 2 * @as(usize, n));
        defer gpa.free(rhs);
        const dx = rhs[n..];
        const col = try gpa.alloc(f64, nnz + 2 * @as(usize, n));
        defer gpa.free(col);
        for (vals, sys.vals) |*v, a| v.* = @splat(a);
        for (0..8) |_| {
            // Per lane: keep the last values (a bypass), scale them 1 +- 5%
            // (a replay), redraw an entry (often a re-pivot) or zero a
            // column (singular).
            var arr: []([W]f64) = @ptrCast(vals);
            for (0..W) |l| switch (r.uintLessThan(u8, 8)) {
                0, 1 => {},
                2 => arr[r.uintLessThan(usize, nnz)][l] = 4 * r.float(f64) - 2,
                3 => {
                    const c = r.uintLessThan(usize, n);
                    for (sys.col_ptr[c]..sys.col_ptr[c + 1]) |p| arr[p][l] = 0;
                },
                else => for (arr, sys.vals) |*v, a| {
                    v[l] = a * (0.95 + 0.1 * r.float(f64));
                },
            };
            for (rhs[0..n]) |*v| {
                var a: [W]f64 = undefined;
                for (&a) |*x| x.* = 2 * r.float(f64) - 1;
                v.* = a;
            }
            const m: S.Mask = @truncate(r.int(u64) | 1);
            const singular = try ls.factorSolveNeg(vals, rhs[0..n], dx, m, .{});
            try testing.expectEqual(@as(S.Mask, 0), singular & ~m);
            for (0..W) |l| {
                if ((m >> @intCast(l)) & 1 == 0) continue;
                if ((ls.joined >> @intCast(l)) & 1 != 0) vector_lanes += 1 else peeled_lanes += 1;
                const v_l = col[0..nnz];
                const b_l = col[nnz..][0..n];
                for (v_l, vals) |*o, v| o.* = S.L.lane(v, l);
                for (b_l, rhs[0..n]) |*o, v| o.* = S.L.lane(v, l);
                const ref_bad = if (refs[l].factor(v_l, .{})) |_| false else |e| switch (e) {
                    error.SingularMatrix => true,
                    else => return e,
                };
                try testing.expectEqual(ref_bad, (singular >> @intCast(l)) & 1 != 0);
                if (ref_bad) continue;
                const x_l = col[nnz + n ..][0..n];
                refs[l].solveNeg(b_l, x_l);
                for (x_l, dx) |a, v| try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(S.L.lane(v, l))));
            }
        }
    }
    // Both paths ran.
    try testing.expect(vector_lanes > 0 and peeled_lanes > 0);
}
