//! Structural sweep lanes: one driver for mc/temp/sens/dcmatch's "N
//! independent cold DC solves, one param install per lane" shape. Route is
//! GPU batch (`gpu_hook.solve_batch`, one launch) orelse a serial Newton loop
//! — the same flat lane blob both ways (lane k at x_lanes[k*n..][0..n]),
//! matching the GPU hook's contract.
//!
//! `apply(k)` installs lane k's params (ParamRef writes) and is invoked in
//! lane order (k = 0, 1, ... n_lanes-1) on BOTH routes. `recompute()` after
//! apply is the driver's job, not the caller's.
//!
//! CONTRACT for stateful callers (MC's PRNG): the GPU route may run all its
//! apply(k) calls and then fall through to the serial route, which re-runs
//! them from k=0. So `apply(0)` MUST reset any per-sweep state (reseed the
//! RNG) — that makes the two routes bit-identical and the fallthrough safe.
//!
//! `solveLanesGpu` is that GPU route on its own, for the caller whose serial
//! route is NOT cold-start: dc.zig's sweep warm-starts each point from the
//! previous solution and falls back to op's ladder, so it takes the batched
//! launch from here and keeps its own serial march.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;

/// Per-lane parameter installer. `ctx` is the caller's opaque state; `apply`
/// writes lane k's params; `restore` puts the nominal params back once the
/// sweep is done (both routes, success or GPU-fallthrough).
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
    if (try solveLanesGpu(ckt, setup, x_lanes, results, opts)) return;

    // -- Serial route: apply -> recompute -> seed -> Newton per lane.
    const n: usize = ckt.n;
    const n_lanes = results.len;
    const ws = try ckt.workspace();
    for (0..n_lanes) |k| {
        setup.apply(setup.ctx, k);
        try ckt.recompute();
        const xl = x_lanes[k * n ..][0..n];
        root.zeroSimd(xl);
        ckt.seedJunctions(xl);
        results[k] = converger.run(ckt, ws, xl, 0, opts, root.EvalHook{}) catch
            converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };
    }
    setup.restore(setup.ctx);
    try ckt.recompute();
}

/// GPU batch route on its own: install every lane's params, repack the device
/// payloads, cold-seed each lane, one batched launch. Returns false — with
/// `restore` NOT called and x_lanes/results left unspecified — when the hook is
/// absent or GPU execution fails. The caller must then run a serial route that
/// re-applies from k = 0 (the apply(0)-reset contract above). Topology changes
/// return an error; the caller must restore params before returning it.
pub fn solveLanesGpu(
    ckt: *root.Circuit,
    setup: LaneSetup,
    x_lanes: []f64,
    results: []converger.Result,
    opts: converger.Options,
) !bool {
    const n: usize = ckt.n;
    std.debug.assert(x_lanes.len == results.len * n);
    const gh = ckt.gpu_hook orelse return false;
    const sb = gh.solve_batch orelse return false;
    const repack = gh.repack orelse return false; // batch needs device repack
    for (0..results.len) |k| {
        setup.apply(setup.ctx, k);
        try ckt.recompute();
        repack(gh.ctx) catch return false;
        const xl = x_lanes[k * n ..][0..n];
        root.zeroSimd(xl);
        ckt.seedJunctions(xl);
    }
    sb(gh.ctx, x_lanes, @intCast(n), 0, opts, results) catch return false;
    setup.restore(setup.ctx);
    try ckt.recompute();
    return true;
}
