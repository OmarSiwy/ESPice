//! Structural sweep lanes: one driver for the "N independent cold DC solves,
//! one param install per lane" shape. Lane k lands at x_lanes[k*n..][0..n].
//!
//! `apply(k)` installs lane k's params (ParamRef writes) and is invoked in
//! lane order (k = 0, 1, ... n_lanes-1). `recompute()` after apply is the
//! driver's job, not the caller's.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;

/// Solve `n_lanes` cold DC points into the flat blob `x_lanes` (lane k at
/// x_lanes[k*n..][0..n]); `results[k]` gets lane k's converger.Result. The
/// caller owns both slices (x_lanes.len == n_lanes*ckt.n, results.len ==
/// n_lanes). `setup` is a pointer to the caller's installer: `apply(k)`
/// writes lane k's params, `restore()` puts the nominals back, and runs
/// before returning on success and on error.
pub fn solveLanes(
    ckt: *root.Circuit,
    setup: anytype,
    x_lanes: []f64,
    results: []converger.Result,
    opts: converger.Options,
) !void {
    errdefer {
        setup.restore();
        ckt.recompute() catch {}; // preserve the original failure; no further solve follows
    }
    const n: usize = ckt.n;
    const n_lanes = results.len;
    const ws = try ckt.workspace();
    for (0..n_lanes) |k| {
        if (k != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = k, .total = n_lanes });
        setup.apply(k);
        try ckt.recompute();
        const xl = x_lanes[k * n ..][0..n];
        root.zeroSimd(xl);
        ckt.seedJunctions(xl);
        results[k] = converger.run(ckt, ws, xl, 0, opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        };
    }
    setup.restore();
    try ckt.recompute();
}
