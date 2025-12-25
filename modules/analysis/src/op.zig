//! Operating point: plain Newton, then gmin stepping. One Workspace for the
//! whole continuation — the pattern is frozen, so ordering/symbolic work
//! happens exactly once.
const std = @import("std");
const root = @import("root.zig");
const newton = @import("newton.zig");

pub const Method = enum { plain, gmin, source };

pub const Options = struct {
    max_iter: u16 = 100,
    abstol: f64 = 1e-12,
    reltol: f64 = 1e-3,
    gmin: f64 = 1e-12,
    gmin_start: f64 = 1e-2,
    warm_start: bool = false,
};

pub const SolveResult = struct {
    converged: bool,
    iterations: u16,
    max_dx: f64,
    method_used: Method,
};

/// Fine-grained primitive: solve the operating point into caller-owned x.
/// engine.zig warm-starts every other analysis through this.
pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    if (!options.warm_start) @memset(x, 0);
    try ckt.computeBaseline();

    var ws = try newton.Workspace.init(allocator, ckt);
    defer ws.deinit(allocator);

    // Strategy 1: plain Newton
    const plain = newtonRun(ckt, &ws, x, options, options.gmin) catch |e| switch (e) {
        error.SingularMatrix => null,
        else => return e,
    };
    if (plain) |p| {
        if (p.converged)
            return .{ .converged = true, .iterations = p.iterations, .max_dx = p.max_dx, .method_used = .plain };
    }

    // Strategy 2: gmin stepping, warm-started at each halving
    @memset(x, 0);
    var total_iter: u16 = 0;
    var gmin_val = options.gmin_start;
    var result = newtonRun(ckt, &ws, x, options, gmin_val) catch |e| switch (e) {
        error.SingularMatrix => return .{ .converged = false, .iterations = 0, .max_dx = 0, .method_used = .gmin },
        else => return e,
    };
    total_iter +|= result.iterations;
    while (result.converged and gmin_val > options.gmin) {
        gmin_val = @max(gmin_val * 0.5, options.gmin);
        result = newtonRun(ckt, &ws, x, options, gmin_val) catch |e| switch (e) {
            error.SingularMatrix => break,
            else => return e,
        };
        total_iter +|= result.iterations;
    }
    if (result.converged)
        return .{ .converged = true, .iterations = total_iter, .max_dx = result.max_dx, .method_used = .gmin };

    // Strategy 3: source stepping via device attempt(lambda)
    @memset(x, 0);
    total_iter = 0;
    const steps = [_]f64{ 0.0, 0.25, 0.5, 0.75, 0.9, 0.95, 1.0 };
    for (steps) |lambda| {
        ckt.applyAttempt(lambda);
        ckt.has_baseline = false;
        try ckt.computeBaseline();
        const sr = newtonRun(ckt, &ws, x, options, options.gmin) catch |e| switch (e) {
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
    const final = newtonRun(ckt, &ws, x, options, options.gmin) catch |e| switch (e) {
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
        const r = try solve(ctx.circuit, x, opts, ctx.allocator);
        if (!r.converged) return error.OpDidNotConverge;
        break :blk x;
    };
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

fn newtonRun(ckt: *root.Circuit, ws: *newton.Workspace, x: []f64, options: Options, gmin: f64) !newton.Result {
    return newton.solve(ckt, &ws.slv, x, ws.dx, ws.x_old, 0, .{
        .max_iter = options.max_iter,
        .abstol = options.abstol,
        .gmin = gmin,
    }, newton.EvalHook{});
}
