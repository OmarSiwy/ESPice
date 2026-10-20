//! Structural sweep lanes: DC solves, each after one parameter install,
//! sharing the circuit pattern and one Newton workspace. Every lane starts
//! cold, or from one fixed `warm` reference (the nominal OP), never from
//! another lane, so a lane is the same whichever lanes run beside it and
//! the session can run each as its own row (#213). A lane keeps only its
//! probe values.
//! No outside source; dev/analysis/ensemble-sweeps.md and
//! dev/analysis/dc-sweep.md describe the lane axis.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;

/// Lanes `first..first + count` of a sweep of `total`: all of them, or the
/// one lane a split row (`lane`) solves.
pub const Range = struct {
    first: usize,
    count: usize,

    pub fn of(lane: ?u32, total: usize) Range {
        return if (lane) |k| .{ .first = k, .count = 1 } else .{ .first = 0, .count = total };
    }
};

/// Solves lanes `first..first + results.len`; `results[i]` is lane
/// `first + i`'s Newton result, non-converged on a solver error, and a
/// converged lane's probe values land at `rows[i * probes.len ..]`.
/// `setup` points at the caller's installer: `apply(k)` writes lane k's
/// params and is called in lane order, `restore()` puts the nominals back.
/// The driver recomputes after each, and restores on success and on error.
/// A lane starts from `warm` when given (asserted `ckt.n` long), else cold.
/// A lane's solver error is a non-converged result; what escapes is
/// cancellation, a recompute's error.TopologyChanged and allocation failure.
/// Asserts that `rows.len == results.len * probes.len`.
pub fn solveLanes(
    ckt: *root.Circuit,
    setup: anytype,
    first: usize,
    probes: []const u32,
    rows: []f64,
    results: []converger.Result,
    opts: converger.Options,
    warm: ?[]const f64,
    scratch: std.mem.Allocator,
) !void {
    errdefer {
        setup.restore();
        ckt.recompute() catch {}; // keep the original error; no solve follows
    }
    std.debug.assert(rows.len == results.len * probes.len);
    const n: usize = ckt.n;
    if (warm) |w| std.debug.assert(w.len == n);
    const x = try scratch.alloc(f64, n);
    defer scratch.free(x);
    const ws = try ckt.workspace();
    for (results, 0..) |*result, i| {
        if (i != 0) try ckt.checkpoint(.{ .phase = .sweep, .completed = i, .total = results.len });
        setup.apply(first + i);
        try ckt.recompute();
        start(ckt, x, warm);
        result.* = converger.run(ckt, ws, x, 0, opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled, error.OutOfMemory => return err,
            else => converger.Result{ .converged = false, .iterations = 0 }, // else: a numerical failure marks the lane unconverged
        };
        if (result.converged) for (probes, rows[i * probes.len ..][0..probes.len]) |node, *out| {
            out.* = x[node];
        };
    }
    setup.restore();
    try ckt.recompute();
}

/// A lane's Newton start: a copy of `warm`, or zero with the junctions seeded.
pub fn start(ckt: *root.Circuit, x: []f64, warm: ?[]const f64) void {
    if (warm) |w| {
        @memcpy(x, w);
    } else {
        @memset(x, 0);
        ckt.seedJunctions(x);
    }
}
