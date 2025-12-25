//! The one Newton loop. dc / tran / envelope / tran_noise / pnoise all run
//! this; they differ only in the Hook, which decides what gets assembled
//! and which vals plane is factored.
//!
//! Hook contract (comptime duck-typed):
//!   assemble(ckt, x, t) void  — fill planes + rhs (companion terms, noise
//!                               currents, history injection go here)
//!   vals(ckt) []f64           — matrix to factor (dc: g_vals; tran: G+aC)

const std = @import("std");
const root = @import("root.zig");
const direct = root.solvers.direct;

pub const Options = struct {
    max_iter: u16 = 100,
    abstol: f64 = 1e-12,
    /// Diagonal regularization. The MNA matrix includes the ground row and
    /// is structurally singular without it.
    gmin: f64 = 1e-12,
    dx_clamp: f64 = 10.0,
};

pub const Result = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
};

/// Plain hook: assemble = one eval, matrix = G. This IS dc.
pub const EvalHook = struct {
    pub fn assemble(_: EvalHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
    }
    pub fn vals(_: EvalHook, ckt: *root.Circuit) []f64 {
        return ckt.g_vals;
    }
};

/// Caller owns solver and scratch (dx, x_old): sweeps reuse both across
/// hundreds of solves on the same frozen pattern.
pub fn solve(
    ckt: *root.Circuit,
    slv: *direct.Solver,
    x: []f64,
    dx: []f64,
    x_old: []f64,
    t: f64,
    opts: Options,
    hook: anytype,
) !Result {
    var iter: u16 = 0;
    while (iter < opts.max_iter) : (iter += 1) {
        hook.assemble(ckt, x, t);
        const vals = hook.vals(ckt);
        if (opts.gmin > 0) {
            for (0..ckt.n) |i| {
                vals[ckt.diag_slots[i]] += opts.gmin;
                ckt.rhs[i] += opts.gmin * x[i];
            }
        }
        try slv.factor(vals);
        slv.solveNeg(ckt.rhs, dx);
        for (dx[0..ckt.n]) |*d| d.* = std.math.clamp(d.*, -opts.dx_clamp, opts.dx_clamp);
        @memcpy(x_old[0..ckt.n], x[0..ckt.n]);
        const max_dx = updateAndNorm(x[0..ckt.n], dx[0..ckt.n]);
        ckt.applyLimits(x, x_old);
        if (ckt.updateStates(x)) |_| continue; // state flip: force another iteration
        if (max_dx < opts.abstol)
            return .{ .converged = true, .iterations = iter + 1, .max_dx = max_dx };
    }
    return .{ .converged = false, .iterations = opts.max_iter, .max_dx = 0 };
}

fn updateAndNorm(x: []f64, dx: []const f64) f64 {
    var max_dx: f64 = 0;
    for (x, dx) |*xi, dxi| {
        xi.* += dxi;
        max_dx = @max(max_dx, @abs(dxi));
    }
    return max_dx;
}

/// Convenience: workspace bundled for one-shot / sweep callers.
pub const Workspace = struct {
    slv: direct.Solver,
    dx: []f64,
    x_old: []f64,

    pub fn init(gpa: std.mem.Allocator, ckt: *const root.Circuit) !Workspace {
        const dx = try gpa.alloc(f64, ckt.n);
        errdefer gpa.free(dx);
        const x_old = try gpa.alloc(f64, ckt.n);
        errdefer gpa.free(x_old);
        return .{
            .slv = try direct.Solver.init(gpa, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd),
            .dx = dx,
            .x_old = x_old,
        };
    }

    pub fn deinit(self: *Workspace, gpa: std.mem.Allocator) void {
        self.slv.deinit();
        gpa.free(self.dx);
        gpa.free(self.x_old);
        self.* = undefined;
    }
};
