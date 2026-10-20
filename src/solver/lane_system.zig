//! W scalar Newton systems as one lane system for `converger.newtonLanes`:
//! lane-major right-hand side and Jacobian values over one shared pattern,
//! evaluated by deinterleaving each active lane's x, running that lane's
//! own scalar system and hook, and interleaving what they stamped. Every
//! device call is the scalar one on the lane's own state, so device code
//! changes for no lane and a lane's planes are bitwise its scalar run's.
//!
//! In: W systems with the `newton` interface on one pattern, and their
//! hook. Out: the lane system (`sys.active` selects the lanes evaluated)
//! and `LaneHook`, its `newtonLanes` hook. Each lane's own planes end every
//! iterate as its scalar solve leaves them (`loadCheck`).
//! dev/research/lane-batched-simulation.md §3.2 and §4 (the CPU decision).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Lanes = @import("lanes.zig").Lanes;
const Execution = @import("core").numerics.Execution;

/// W systems of type `Sys` (a pointer's child, with fields `n`, `nnz`,
/// `diag_slots`, `rhs`, `current_row`) and their scalar hook `Hook`.
pub fn LaneSystem(comptime W: usize, comptime Sys: type, comptime Hook: type) type {
    comptime assert(W >= 2);
    return struct {
        const Self = @This();
        const L = Lanes(W);
        pub const V = L.V;
        pub const Mask = L.Mask;

        /// Lane l's own system, borrowed; all on one pattern.
        lanes: [W]*Sys,
        /// Lane l's hook. A transient lane assembles under its own
        /// coefficients and charge history; a static solve's hook is the
        /// same for every lane.
        hooks: [W]Hook,
        n: u32,
        nnz: u32,
        diag_slots: []const u32,
        current_row: []const bool,
        /// Lane-major residual and Jacobian values (pattern order), as long
        /// as each lane's own (trailing trash slots included).
        rhs: []V,
        vals: []V,
        /// The lanes `newtonLanes` is still solving; the others are not
        /// evaluated.
        active: Mask = L.every,
        solver_execution: Execution = .{},
        /// One lane's x and x_old, deinterleaved.
        xs: []f64,
        xo: []f64,

        /// Borrows `lanes`. Asserts that they share n, nnz and diagonal
        /// slots. Fails only on allocation.
        pub fn init(gpa: Allocator, lanes: [W]*Sys, hook: Hook) !Self {
            const s0 = lanes[0];
            for (lanes) |s| {
                assert(s.n == s0.n and s.nnz == s0.nnz);
                assert(std.mem.eql(u32, s.diag_slots[0..s.n], s0.diag_slots[0..s0.n]));
            }
            const n: usize = s0.n;
            const rhs = try gpa.alloc(V, s0.rhs.len);
            errdefer gpa.free(rhs);
            const vals = try gpa.alloc(V, hook.vals(s0).len);
            errdefer gpa.free(vals);
            const xs = try gpa.alloc(f64, 2 * n);
            return .{
                .lanes = lanes,
                .hooks = @splat(hook),
                .n = s0.n,
                .nnz = s0.nnz,
                .diag_slots = s0.diag_slots,
                .current_row = s0.current_row,
                .rhs = rhs,
                .vals = vals,
                .solver_execution = if (@hasField(Sys, "solver_execution")) s0.solver_execution else .{},
                .xs = xs[0..n],
                .xo = xs[n..],
            };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.rhs);
            gpa.free(self.vals);
            gpa.free(self.xs.ptr[0 .. 2 * self.xs.len]);
            self.* = undefined;
        }

        /// The `newtonLanes` hook: each active lane's scalar `assemble` at
        /// its own x and t, interleaved.
        pub const LaneHook = struct {
            pub fn assemble(_: LaneHook, sys: *Self, x: []const V, t: V) void {
                var it = L.each(sys.active);
                while (it.next()) |l| {
                    const s = sys.lanes[l];
                    getLane(sys.xs, x, l);
                    sys.hooks[l].assemble(s, sys.xs, L.lane(t, l));
                    putLane(sys.vals, sys.hooks[l].vals(s), l);
                    putLane(sys.rhs, s.rhs, l);
                }
            }
            pub fn vals(_: LaneHook, sys: *Self) []V {
                return sys.vals;
            }
            pub fn diagAt(_: LaneHook, sys: *Self, slot: u32) V {
                return sys.vals[slot];
            }
        };

        /// Starts each active lane's solve; a lane outside `active` (a
        /// finished transient lane, a padding copy) is not touched.
        pub fn beginSolve(self: *Self) void {
            if (comptime !@hasDecl(Sys, "beginSolve")) return;
            var it = L.each(self.active);
            while (it.next()) |l| self.lanes[l].beginSolve();
        }

        /// The first active lane's refusal fails the batch.
        pub fn checkpoint(self: *Self, event: Event) !void {
            if (comptime @hasDecl(Sys, "checkpoint")) {
                var it = L.each(self.active);
                while (it.next()) |l| try self.lanes[l].checkpoint(event);
            }
        }

        /// The scalar checkpoint's event, or the shape `newtonLanes` passes.
        const Event = if (@hasDecl(Sys, "checkpoint"))
            @typeInfo(@TypeOf(Sys.checkpoint)).@"fn".param_types[1].?
        else
            struct { phase: enum { nonlinear }, completed: u16, total: u16 };

        pub fn advanceIteration(self: *Self, x_old: []const V) void {
            if (comptime !@hasDecl(Sys, "advanceIteration")) return;
            var it = L.each(self.active);
            while (it.next()) |l| {
                getLane(self.xo, x_old, l);
                self.lanes[l].advanceIteration(self.xo);
            }
        }

        /// Each active lane's load test on its own x, values and residual.
        /// Called once per iterate after `loadExtras`, it first writes the
        /// loaded values and residual back into each active lane, so every
        /// later device call (and the lane after the solve) sees the planes
        /// a scalar `newton` leaves in its own system.
        pub fn loadCheck(self: *Self, x: []const V, v: []const V, rhs: []const V, reltol: f64, abstol: f64) Mask {
            var ok: Mask = L.every;
            var it = L.each(self.active);
            while (it.next()) |l| {
                const s = self.lanes[l];
                const lv = self.hooks[l].vals(s)[0..self.nnz];
                getLane(lv, v, l);
                getLane(s.rhs[0..self.n], rhs, l);
                if (comptime !@hasDecl(Sys, "loadCheck")) continue;
                getLane(self.xs, x, l);
                if (!s.loadCheck(self.xs, lv, s.rhs[0..self.n], reltol, abstol)) ok &= ~bit(l);
            }
            return ok;
        }

        /// Each active lane's limiter on its own x and x_old; the limited
        /// x goes back into its lane.
        pub fn applyLimits(self: *Self, x: []V, x_old: []const V) Mask {
            if (comptime !@hasDecl(Sys, "applyLimits")) return L.none;
            var limited: Mask = L.none;
            var it = L.each(self.active);
            while (it.next()) |l| {
                getLane(self.xs, x, l);
                getLane(self.xo, x_old, l);
                if (self.lanes[l].applyLimits(self.xs, self.xo)) limited |= bit(l);
                putLane(x, self.xs, l);
            }
            return limited;
        }

        /// The lanes of `m` whose devices report convergence at x.
        pub fn checkConvergence(self: *Self, x: []const V, m: Mask) Mask {
            if (comptime !@hasDecl(Sys, "checkConvergence")) return m;
            var ok = m;
            var it = L.each(m);
            while (it.next()) |l| {
                getLane(self.xs, x, l);
                if (!self.lanes[l].checkConvergence(self.xs)) ok &= ~bit(l);
            }
            return ok;
        }

        /// Stages each lane of `m` at x; returns the lanes a device flipped.
        pub fn updateStates(self: *Self, x: []const V, m: Mask) Mask {
            if (comptime !@hasDecl(Sys, "updateStates")) return L.none;
            var flipped: Mask = L.none;
            var it = L.each(m);
            while (it.next()) |l| {
                getLane(self.xs, x, l);
                if (self.lanes[l].updateStates(self.xs) != null) flipped |= bit(l);
            }
            return flipped;
        }

        pub fn clearLimits(self: *Self) void {
            if (comptime @hasDecl(Sys, "clearLimits")) for (self.lanes) |s| s.clearLimits();
        }

        inline fn bit(l: usize) Mask {
            return @as(Mask, 1) << @intCast(l);
        }

        /// dst = lane l of src.
        pub fn getLane(dst: []f64, src: []const V, l: usize) void {
            for (dst, src[0..dst.len]) |*d, v| d.* = L.lane(v, l);
        }

        /// Lane l of dst = src.
        pub fn putLane(dst: []V, src: []const f64, l: usize) void {
            for (dst[0..src.len], src) |*d, v| {
                var a: [W]f64 = d.*;
                a[l] = v;
                d.* = a;
            }
        }
    };
}

const testing = std.testing;
const converger = @import("converger.zig");

/// A diode-loaded sparse network: F(x) = A x + c (e^(x / 0.5) - 1) - b, a
/// step limiter, and a device that flips once when first staged.
const Toy = struct {
    n: u32,
    nnz: u32,
    col_ptr: []const u32,
    row_idx: []const u32,
    diag_slots: []const u32,
    current_row: []const bool,
    a: []f64,
    c: []f64,
    b: []f64,
    rhs: []f64,
    g: []f64,
    flips: u8 = 1,
    staged: u32 = 0,

    pub fn applyLimits(self: *Toy, x: []f64, x_old: []const f64) bool {
        var hit = false;
        for (x[0..self.n], x_old[0..self.n]) |*xi, xo| {
            if (@abs(xi.* - xo) > 1) {
                xi.* = xo + std.math.copysign(@as(f64, 1), xi.* - xo);
                hit = true;
            }
        }
        return hit;
    }

    pub fn updateStates(self: *Toy, _: []const f64) ?f64 {
        self.staged += 1;
        if (self.flips == 0) return null;
        self.flips -= 1;
        return 0;
    }

    const Hook = struct {
        pub fn assemble(_: Hook, s: *Toy, x: []const f64, t: f64) void {
            _ = t;
            @memcpy(s.g, s.a);
            @memset(s.rhs, 0);
            for (0..s.n) |j| for (s.col_ptr[j]..s.col_ptr[j + 1]) |p| {
                s.rhs[s.row_idx[p]] += s.a[p] * x[j];
            };
            for (0..s.n) |i| {
                const e = @exp(x[i] / 0.5);
                s.rhs[i] += s.c[i] * (e - 1) - s.b[i];
                s.g[s.diag_slots[i]] += s.c[i] / 0.5 * e;
            }
        }
        pub fn vals(_: Hook, s: *Toy) []f64 {
            return s.g;
        }
        pub fn diagAt(_: Hook, s: *Toy, slot: u32) f64 {
            return s.g[slot];
        }
    };
};

test "newtonLanes(W) lane l is bitwise the scalar newton on lane l, through limiting, flips, INITFIX, gmin and a singular lane" {
    try expectNewtonLanes(2);
    try expectNewtonLanes(std.simd.suggestVectorLength(f64) orelse 4);
}

fn expectNewtonLanes(comptime W: usize) !void {
    const gpa = testing.allocator;
    const SparseLu = @import("sparse_lu.zig").SparseLu;
    const LS = LaneSystem(W, Toy, Toy.Hook);
    var prng = std.Random.DefaultPrng.init(0x7e57);
    const r = prng.random();
    var converged_lanes: usize = 0;
    for (0..24) |trial| {
        const n: u32 = @intCast(3 + trial % 9);
        const sys = try SparseLu.test_access.TestSystem.init(gpa, r, n, 0.3);
        defer sys.deinit(gpa);
        const nnz: u32 = @intCast(sys.vals.len);
        const diag = try gpa.alloc(u32, n);
        defer gpa.free(diag);
        for (diag, 0..) |*d, j| {
            for (sys.col_ptr[j]..sys.col_ptr[j + 1]) |p| if (sys.row_idx[p] == j) {
                d.* = @intCast(p);
            };
        }
        const cur = try gpa.alloc(bool, n);
        defer gpa.free(cur);
        for (cur) |*c| c.* = r.boolean();

        // Lanes 0..W and their scalar twins W..2W.
        const per = 2 * @as(usize, nnz) + 3 * @as(usize, n) + 1;
        const store = try gpa.alloc(f64, 2 * W * per);
        defer gpa.free(store);
        var toys: [2 * W]Toy = undefined;
        for (&toys, 0..) |*t, k| {
            const m = store[k * per ..][0..per];
            t.* = .{
                .n = n,
                .nnz = nnz,
                .col_ptr = sys.col_ptr,
                .row_idx = sys.row_idx,
                .diag_slots = diag,
                .current_row = cur,
                .a = m[0..nnz],
                .c = m[nnz..][0..n],
                .b = m[nnz + n ..][0..n],
                .rhs = m[nnz + 2 * n ..][0 .. n + 1],
                .g = m[nnz + 3 * n + 1 ..][0..nnz],
            };
        }
        for (toys[0..W]) |*t| {
            for (t.a, sys.vals) |*o, v| o.* = v * (0.8 + 0.4 * r.float(f64));
            for (t.c) |*c| c.* = if (r.uintLessThan(u8, 3) == 0) 1e-3 * r.float(f64) else 0;
            for (t.b) |*b| b.* = 4 * r.float(f64) - 2;
            t.flips = r.uintLessThan(u8, 2);
            // One lane in four is singular: a column with no entries and
            // no diode.
            if (r.uintLessThan(u8, 4) == 0) {
                const col = r.uintLessThan(usize, n);
                for (sys.col_ptr[col]..sys.col_ptr[col + 1]) |p| t.a[p] = 0;
                t.c[col] = 0;
            }
        }
        for (toys[0..W], toys[W..]) |l, *twin| {
            @memcpy(twin.a, l.a);
            @memcpy(twin.c, l.c);
            @memcpy(twin.b, l.b);
            twin.flips = l.flips;
        }

        var wss: [2 * W]converger.Workspace = undefined;
        for (&wss) |*w| w.* = try converger.Workspace.init(gpa, n, sys.col_ptr, sys.row_idx, null, .{}, .{});
        defer for (&wss) |*w| w.deinit(gpa);
        var lane_ptrs: [W]*Toy = undefined;
        var ws_ptrs: [W]*converger.Workspace = undefined;
        for (0..W) |l| {
            lane_ptrs[l] = &toys[l];
            ws_ptrs[l] = &wss[l];
        }
        var ls = try LS.init(gpa, lane_ptrs, .{});
        defer ls.deinit(gpa);
        var lws = try converger.LaneWorkspace(W).init(gpa, ws_ptrs);
        defer lws.deinit(gpa);

        const opts: converger.Options = .{ .init_fix = trial % 2 == 0, .gmin = if (trial % 3 == 0) 1e-6 else 0, .max_iter = 100 };
        const x = try gpa.alloc(LS.V, n);
        defer gpa.free(x);
        const x_ref = try gpa.alloc(f64, W * @as(usize, n));
        defer gpa.free(x_ref);
        for (x, 0..) |*v, i| {
            var a: [W]f64 = undefined;
            for (&a, 0..) |*e, l| {
                e.* = r.float(f64) - 0.5;
                x_ref[l * n + i] = e.*;
            }
            v.* = a;
        }
        const res = try converger.newtonLanes(W, &ls, &lws, x, @splat(0), opts, LS.LaneHook{});
        try testing.expectEqual(@as(LS.Mask, 0), res.converged & res.singular);
        for (0..W) |l| {
            const bitl = @as(LS.Mask, 1) << @intCast(l);
            const xr = x_ref[l * n ..][0..n];
            const want = converger.newton(&toys[W + l], &wss[W + l], xr, 0, opts, Toy.Hook{}) catch |e| {
                try testing.expectEqual(error.SingularMatrix, e);
                try testing.expect(res.singular & bitl != 0);
                continue;
            };
            try testing.expect(res.singular & bitl == 0);
            try testing.expectEqual(want.converged, res.converged & bitl != 0);
            try testing.expectEqual(want.iterations, res.iterations[l]);
            try testing.expectEqual(toys[W + l].staged, toys[l].staged);
            converged_lanes += @intFromBool(want.converged);
            for (xr, x) |a, v| try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(LS.L.lane(v, l))));
        }
    }
    try testing.expect(converged_lanes > 0);
}
