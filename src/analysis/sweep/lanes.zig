//! Structural sweep lanes: N independent cold DC solves, each after one
//! parameter install, sharing the circuit pattern and one Newton workspace.
//! Lane k's solution lands at x_lanes[k*n..][0..n].
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;

/// Solves `results.len` lanes into `x_lanes` (`results.len * ckt.n` long);
/// `results[k]` is lane k's Newton result, non-converged on a solver error.
/// `setup` points at the caller's installer: `apply(k)` writes lane k's
/// params and is called in lane order, `restore()` puts the nominals back.
/// The driver recomputes after each, and restores on success and on error.
pub fn solveLanes(
    ckt: *root.Circuit,
    setup: anytype,
    x_lanes: []f64,
    results: []converger.Result,
    opts: converger.Options,
) !void {
    errdefer {
        setup.restore();
        ckt.recompute() catch {}; // keep the original error; no solve follows
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
