//! Structural sweep lanes: N DC solves, each after one parameter install,
//! sharing the circuit pattern and one Newton workspace. Each lane starts
//! cold, or with `warm` from the previous converged lane. Lane k's solution
//! lands at x_lanes[k*n..][0..n].
//! No outside source; dev/analysis/ensemble-sweeps.md and
//! dev/analysis/dc-sweep.md describe the lane axis.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;

/// Solves `results.len` lanes into `x_lanes` (`results.len * ckt.n` long);
/// `results[k]` is lane k's Newton result, non-converged on a solver error.
/// `setup` points at the caller's installer: `apply(k)` writes lane k's
/// params and is called in lane order, `restore()` puts the nominals back.
/// The driver recomputes after each, and restores on success and on error.
/// With `warm`, a lane starts from the previous lane's solution when that
/// one converged (neighbouring sweep points), else cold. A lane's solver
/// error is a non-converged result; what escapes is cancellation, a
/// recompute's error.TopologyChanged and the workspace's allocation failure.
/// Asserts that `x_lanes.len == results.len * ckt.n`.
pub fn solveLanes(
    ckt: *root.Circuit,
    setup: anytype,
    x_lanes: []f64,
    results: []converger.Result,
    opts: converger.Options,
    warm: bool,
) !void {
    errdefer {
        setup.restore();
        ckt.recompute() catch {}; // keep the original error; no solve follows
    }
    std.debug.assert(x_lanes.len == results.len * ckt.n);
    // ponytail: every lane keeps its whole solution, O(lanes * n) floats,
    // though callers read only the probes and the warm start only the
    // previous lane. Record probes per lane when a big .mc runs out of memory.
    const n: usize = ckt.n;
    const n_lanes = results.len;
    const ws = try ckt.workspace();
    for (0..n_lanes) |k| {
        if (k != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = k, .total = n_lanes });
        setup.apply(k);
        try ckt.recompute();
        const xl = x_lanes[k * n ..][0..n];
        if (warm and k != 0 and results[k - 1].converged) {
            @memcpy(xl, x_lanes[(k - 1) * n ..][0..n]);
        } else {
            @memset(xl, 0);
            ckt.seedJunctions(xl);
        }
        results[k] = converger.run(ckt, ws, xl, 0, opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled, error.OutOfMemory => return err,
            else => converger.Result{ .converged = false, .iterations = 0 }, // else: a numerical failure marks the lane unconverged
        };
    }
    setup.restore();
    try ckt.recompute();
}
