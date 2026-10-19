//! `Circuit(W)`: W per-query Circuits on one pattern, with their stamp
//! planes lane-major (entry i of lane l at `i * W + l`, one `@Vector(W,
//! f64)` per entry). Each lane keeps its own Circuit, devices and state; the
//! lane-major planes are packed from them when a batch starts and unpacked
//! into them when it ends. Evaluation deinterleaves each lane's x and runs
//! that lane's own scalar eval (§4: no device object changes). W = 1 is
//! `Circuit` itself. dev/research/lane-batched-simulation.md §3.2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Circuit = @import("Circuit.zig").Circuit;
const EvalHook = @import("Circuit.zig").EvalHook;
const solver = @import("solver");
const Lanes = solver.lanes.Lanes;

pub fn LaneCircuit(comptime W: usize) type {
    if (W == 1) return Circuit;
    return struct {
        const Self = @This();
        const L = Lanes(W);
        pub const V = L.V;
        /// The Newton view, for `converger.newtonLanes` with
        /// `System.LaneHook`: `sys.vals` is the lane-major G plane and
        /// `sys.rhs` the residual.
        pub const System = solver.lane_system.LaneSystem(W, Circuit, EvalHook);

        sys: System,
        c_vals: []V,
        q_vec: []V,

        /// Borrows `lanes`, which must share one pattern, and packs them.
        /// Fails only on allocation.
        pub fn init(gpa: Allocator, lanes: [W]*Circuit) !Self {
            var sys = try System.init(gpa, lanes, .{});
            errdefer sys.deinit(gpa);
            const c = lanes[0];
            const c_vals = try gpa.alloc(V, c.c_vals.len);
            errdefer gpa.free(c_vals);
            var self: Self = .{ .sys = sys, .c_vals = c_vals, .q_vec = try gpa.alloc(V, c.q_vec.len) };
            self.pack();
            return self;
        }

        /// Frees the lane-major planes; the lanes stay the caller's.
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.sys.deinit(gpa);
            gpa.free(self.c_vals);
            gpa.free(self.q_vec);
            self.* = undefined;
        }

        /// Interleaves every lane's g, c, rhs and q planes.
        pub fn pack(self: *Self) void {
            for (self.sys.lanes, 0..) |c, l| self.put(c, l);
        }

        /// Writes the lane-major planes back into every lane.
        pub fn unpack(self: *Self) void {
            for (self.sys.lanes, 0..) |c, l| {
                System.getLane(c.g_vals, self.sys.vals, l);
                System.getLane(c.c_vals, self.c_vals, l);
                System.getLane(c.rhs, self.sys.rhs, l);
                System.getLane(c.q_vec, self.q_vec, l);
            }
        }

        /// Each lane's `Circuit.eval` at its own x and t, interleaved: all
        /// four planes, bitwise each lane's scalar eval.
        pub fn eval(self: *Self, x: []const V, t: V) void {
            for (self.sys.lanes, 0..) |c, l| {
                const xs = self.sys.xs;
                System.getLane(xs, x, l);
                c.eval(xs, L.lane(t, l));
                self.put(c, l);
            }
        }

        /// The Newton workspace over every lane's own (built on first use,
        /// as `Circuit.workspace`). Caller deinits it with `gpa`.
        pub fn workspace(self: *Self, gpa: Allocator) !solver.converger.LaneWorkspace(W) {
            var ws: [W]*solver.converger.Workspace = undefined;
            for (&ws, self.sys.lanes) |*w, c| w.* = try c.workspace();
            return .init(gpa, ws);
        }

        fn put(self: *Self, c: *const Circuit, l: usize) void {
            System.putLane(self.sys.vals, c.g_vals, l);
            System.putLane(self.c_vals, c.c_vals, l);
            System.putLane(self.sys.rhs, c.rhs, l);
            System.putLane(self.q_vec, c.q_vec, l);
        }
    };
}
