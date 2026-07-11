//! Operating point: plain Newton, then gmin stepping. One Workspace for the
//! whole continuation — the pattern is frozen, so ordering/symbolic work
//! happens exactly once.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");

pub const Method = enum { plain, gmin, source, jfnk };

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

    const r = try solveLadder(ckt, ws, x, options);
    // Operating point accepted: sync FSM devices (switches) so a following
    // transient starts from a committed state.
    if (r.converged) _ = ckt.stateCtl(.commit);
    return r;
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

    // Last-converged solution for continuation restarts (both rungs).
    const gpa = ws.slv.gpa;
    const x_good = try gpa.alloc(f64, ckt.n);
    defer gpa.free(x_good);
    var total_iter: u16 = 0;

    // Strategy 2: dynamic gmin stepping (ngspice op.c dynamic_gmin).
    // Descend gmin by `factor`; on a failed rung back gmin up toward the
    // last good value with a gentler factor (4th root) and retry from the
    // last converged x; give up when factor ≈ 1. A failed rung is a plain
    // failure, not an abort — SingularMatrix (NaN stamps) included.
    {
        coldStart(ckt, x);
        const gtarget = options.tol.gmin;
        var factor: f64 = 10.0;
        var good_gmin = options.tol.gmin_start; // upper bound to back up toward
        var gmin_val = good_gmin / factor;
        var have_good = false;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            const r = newtonRun(ckt, ws, x, options.tol, gmin_val) catch |e| switch (e) {
                error.SingularMatrix => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
                else => return e,
            };
            total_iter +|= r.iterations;
            if (r.converged) {
                if (gmin_val <= gtarget)
                    return .{ .converged = true, .iterations = total_iter, .max_dx = r.max_dx, .method_used = .gmin };
                @memcpy(x_good, x);
                have_good = true;
                good_gmin = gmin_val;
                // Easy rung → accelerate the descent (capped at the start factor).
                if (r.iterations <= options.tol.itl1 / 4)
                    factor = @min(factor * @sqrt(factor), 10.0);
                gmin_val = if (gmin_val < factor * gtarget) gtarget else gmin_val / factor;
            } else {
                if (factor < 1.00005) break; // wedged against the last good rung
                factor = @sqrt(@sqrt(factor));
                gmin_val = good_gmin / factor;
                if (have_good) @memcpy(x, x_good) else coldStart(ckt, x);
            }
        }
    }

    // Strategy 3: source stepping via device attempt(lambda), adaptive
    // delta: grow 1.5× on success, halve on failure and retry from the
    // last good lambda/x (ngspice src stepping flavor).
    coldStart(ckt, x);
    total_iter = 0;
    {
        var lambda: f64 = 0.0;
        var lambda_good: f64 = -1.0; // none converged yet
        var delta: f64 = 0.25;
        var solves: u32 = 0;
        while (solves < 100) : (solves += 1) {
            ckt.applyAttempt(lambda);
            ckt.has_baseline = false;
            try ckt.computeBaseline();
            const sr = newtonRun(ckt, ws, x, options.tol, options.tol.gmin) catch |e| switch (e) {
                error.SingularMatrix => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
                else => {
                    ckt.restoreModels();
                    ckt.has_baseline = false;
                    try ckt.computeBaseline();
                    return e;
                },
            };
            total_iter +|= sr.iterations;
            if (sr.converged) {
                if (lambda >= 1.0) break; // full sources reached
                lambda_good = lambda;
                @memcpy(x_good, x);
                delta *= 1.5;
                lambda = @min(lambda + delta, 1.0);
            } else {
                delta *= 0.5;
                if (delta < 1e-4) break;
                if (lambda_good >= 0.0) {
                    @memcpy(x, x_good);
                    lambda = @min(lambda_good + delta, 1.0);
                } else {
                    coldStart(ckt, x);
                    lambda = 0.0;
                }
            }
        }
    }
    ckt.restoreModels();
    ckt.has_baseline = false;
    try ckt.computeBaseline();

    // Final solve at true parameters
    const final = newtonRun(ckt, ws, x, options.tol, options.tol.gmin) catch |e| switch (e) {
        error.SingularMatrix => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        else => return e,
    };
    total_iter +|= final.iterations;
    if (final.converged)
        return .{
            .converged = true,
            .iterations = total_iter,
            .max_dx = final.max_dx,
            .method_used = .source,
        };

    // Strategy 4: JFNK guarantee rung — the same algorithm the GPU kernel
    // runs, so CPU convergence is a superset of GPU convergence by
    // construction. Damping + residual backtracking globalize differently
    // than direct Newton and catch circuits where the factored step wedges.
    coldStart(ckt, x);
    var copts = options.tol.newtonOpts(null);
    copts.gmin = options.tol.gmin;
    // converger.run clears device limiting state on exit; a direct jfnk
    // call must do the same so post-solve evals see clean state.
    defer ckt.clearLimits();
    const jr = try converger.jfnk(ckt, ws, x, 0, copts, converger.EvalHook{});
    total_iter +|= jr.iterations;
    return .{
        .converged = jr.converged,
        .iterations = total_iter,
        .max_dx = jr.max_dx,
        .method_used = if (jr.converged) .jfnk else .source,
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
