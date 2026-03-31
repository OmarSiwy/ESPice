//! Structural sweep lanes: one driver for the "N independent cold DC solves,
//! one param install per lane" shape. Lane k lands at x_lanes[k*n..][0..n].
//!
//! `apply(k)` installs lane k's params (ParamRef writes) and is invoked in
//! lane order (k = 0, 1, ... n_lanes-1). `recompute()` after apply is the
//! driver's job, not the caller's.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;

/// Per-lane parameter installer. `ctx` is the caller's opaque state; `apply`
/// writes lane k's params; `restore` puts the nominal params back once the
/// sweep is done, on success and on error.
pub const LaneSetup = struct {
    ctx: *anyopaque,
    apply: *const fn (ctx: *anyopaque, k: usize) void,
    restore: *const fn (ctx: *anyopaque) void,
};

/// Solve `n_lanes` cold DC points into the flat blob `x_lanes` (lane k at
/// x_lanes[k*n..][0..n]); `results[k]` gets lane k's converger.Result. The
/// caller owns both slices (x_lanes.len == n_lanes*ckt.n, results.len ==
/// n_lanes). Params are restored via `setup.restore` before returning.
pub fn solveLanes(
    ckt: *root.Circuit,
    setup: LaneSetup,
    x_lanes: []f64,
    results: []converger.Result,
    opts: converger.Options,
) !void {
    errdefer {
        setup.restore(setup.ctx);
        ckt.recompute() catch {}; // preserve the original failure; no further solve follows
    }
    const n: usize = ckt.n;
    const n_lanes = results.len;
    const ws = try ckt.workspace();
    for (0..n_lanes) |k| {
        if (k != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = k, .total = n_lanes });
        setup.apply(setup.ctx, k);
        try ckt.recompute();
        const xl = x_lanes[k * n ..][0..n];
        root.zeroSimd(xl);
        ckt.seedJunctions(xl);
        results[k] = converger.run(ckt, ws, xl, 0, opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        };
    }
    setup.restore(setup.ctx);
    try ckt.recompute();
}
