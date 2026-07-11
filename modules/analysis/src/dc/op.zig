//! Operating point: plain Newton, then gmin stepping. One Workspace for the
//! whole continuation — the pattern is frozen, so ordering/symbolic work
//! happens exactly once.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");

pub const Method = enum { plain, gmin, source };

pub const Options = struct {
    tol: converger.Tolerances = .{},
    warm_start: bool = false,
};

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
    method_used: Method,
};

/// Cold-start: zero x, then apply SPICE MODEINITJCT junction seeds so
/// iteration 1 linearizes at vcrit/vto instead of 0.
pub fn coldStart(ckt: *root.Circuit, x: []f64) void {
    @memset(x, 0);
    ckt.seedJunctions(x);
}

/// Fine-grained primitive: solve the operating point into caller-owned x.
/// engine.zig warm-starts every other analysis through this.
pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
) !SolveResult {
    if (!options.warm_start) coldStart(ckt, x);
    try ckt.computeBaseline();

    const ws = try ckt.workspace();

    return solveLadder(ckt, ws, x, options);
}

/// The three-strategy continuation ladder: plain Newton → gmin stepping →
/// source stepping. Takes a caller-owned Workspace so dc.run can reuse its
/// sweep workspace for fallback solves.
pub fn solveLadder(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    x: []f64,
    options: Options,
) !SolveResult {
    // Strategy 1: plain Newton
    const plain = newtonRun(ckt, ws, x, options.tol, options.tol.gmin) catch |e| switch (e) {
        error.SingularMatrix => null,
        else => return e,
    };
    if (plain) |p| {
        if (p.converged)
            return .{ .converged = true, .iterations = p.iterations, .max_dx = p.max_dx, .method_used = .plain };
    }

    // Strategy 2: gmin stepping, warm-started at each halving
    coldStart(ckt, x);
    var total_iter: u16 = 0;
    var gmin_val = options.tol.gmin_start;
    var result = newtonRun(ckt, ws, x, options.tol, gmin_val) catch |e| switch (e) {
        error.SingularMatrix => return .{ .converged = false, .iterations = 0, .max_dx = 0, .method_used = .gmin },
        else => return e,
    };
    total_iter +|= result.iterations;
    while (result.converged and gmin_val > options.tol.gmin) {
        gmin_val = @max(gmin_val * 0.5, options.tol.gmin);
        result = newtonRun(ckt, ws, x, options.tol, gmin_val) catch |e| switch (e) {
            error.SingularMatrix => break,
            else => return e,
        };
        total_iter +|= result.iterations;
    }
    if (result.converged)
        return .{ .converged = true, .iterations = total_iter, .max_dx = result.max_dx, .method_used = .gmin };

    // Strategy 3: source stepping via device attempt(lambda)
    coldStart(ckt, x);
    total_iter = 0;
    const steps = [_]f64{ 0.0, 0.25, 0.5, 0.75, 0.9, 0.95, 1.0 };
    for (steps) |lambda| {
        ckt.applyAttempt(lambda);
        ckt.has_baseline = false;
        try ckt.computeBaseline();
        const sr = newtonRun(ckt, ws, x, options.tol, options.tol.gmin) catch |e| switch (e) {
            error.SingularMatrix => break,
            else => {
                ckt.restoreModels();
                ckt.has_baseline = false;
                try ckt.computeBaseline();
                return e;
            },
        };
        total_iter +|= sr.iterations;
        if (!sr.converged) break;
    }
    ckt.restoreModels();
    ckt.has_baseline = false;
    try ckt.computeBaseline();

    // Final solve at true parameters
    const final = newtonRun(ckt, ws, x, options.tol, options.tol.gmin) catch |e| switch (e) {
        error.SingularMatrix => return .{ .converged = false, .iterations = total_iter, .max_dx = 0, .method_used = .source },
        else => return e,
    };
    total_iter +|= final.iterations;
    return .{
        .converged = final.converged,
        .iterations = total_iter,
        .max_dx = final.max_dx,
        .method_used = .source,
    };
}

/// Contract entry: solve (or reuse ctx.x_op) and format one point per probe.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const x = ctx.x_op orelse blk: {
        const x = try ctx.allocator.alloc(f64, ctx.circuit.n);
        errdefer ctx.allocator.free(x);
        const r = try solve(ctx.circuit, x, opts);
        if (!r.converged) return error.OpDidNotConverge;
        break :blk x;
    };
    defer if (ctx.x_op == null) ctx.allocator.free(x);
    const names = try root.probeNames(ctx, null);
    const data = try ctx.allocator.alloc(f64, names.len);
    for (ctx.probes, data) |node, *out| out.* = x[node];
    return .{
        .plotname = "Operating Point",
        .varnames = names,
        .is_complex = false,
        .npoints = 1,
        .data = data,
    };
}

fn newtonRun(ckt: *root.Circuit, ws: *converger.Workspace, x: []f64, tol: converger.Tolerances, gmin: f64) !converger.Result {
    var copts = tol.newtonOpts(null);
    copts.gmin = gmin;
    return converger.run(ckt, ws, x, 0, copts, converger.EvalHook{});
}
