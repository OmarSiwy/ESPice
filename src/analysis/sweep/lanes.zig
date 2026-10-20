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

/// Lane `k` of `setup` on `ckt`: its params, a recompute and its start.
pub fn install(ckt: *root.Circuit, setup: anytype, k: usize, x: []f64, warm: ?[]const f64) !void {
    setup.apply(k);
    try ckt.recompute();
    start(ckt, x, warm);
}

/// The Newton options every lane solves with: `.dc`'s, at its itl2.
pub fn newtonOptions(opts: anytype) converger.Options {
    return converger.optionsFromTolerances(opts.dc_options.tol, opts.dc_options.tol.itl2);
}

/// `M.run` (`.mc` or `.temp`) for every lane of `opts.lane`'s sweep, or the
/// one it names: the lanes solve in order (`solveLanes`) and `M.publish`
/// writes their rows.
pub fn run(comptime M: type, ctx: *const root.RunCtx, opts: M.Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    var setup = try M.setup(ctx, opts);
    defer setup.deinit(scratch);
    const range = M.range(opts);
    const np = ctx.probes.len;
    const rows = try scratch.alloc(f64, range.count * np);
    defer scratch.free(rows);
    const results = try scratch.alloc(converger.Result, range.count);
    defer scratch.free(results);
    try solveLanes(ctx.circuit, &setup, range.first, ctx.probes, rows, results, newtonOptions(opts), M.warm(ctx, opts), scratch);
    return M.publish(ctx, opts, range.first, rows, results);
}

/// What fails one lane row of a batch (`runBatch`).
pub const LaneError = std.mem.Allocator.Error || error{QueryCancelled} || root.ErrorOf(root.Circuit.workspace) ||
    root.ErrorOf(root.Circuit.recompute) || root.ErrorOf(root.Circuit.collectParams);
/// One lane row's outcome in a batch.
pub const LaneOutcome = LaneError!root.Result;

/// The lane rows of one batch, row l solving lane `opts[l].lane` on
/// `ctxs[l]`, each bitwise `run(M, &ctxs[l], opts[l])`: every lane installs
/// as it would alone, the Newtons run W wide (`solveBatch`), and each row
/// publishes its own result into `out[l]`. A lane's own install or publish
/// error is its outcome; the batch's (out of memory, a cancel) is every
/// lane's. The circuits keep their lanes' params: nothing reads a lane
/// row's circuit after it. Asserts 1 <= `ctxs.len` <= W and that every
/// `opts[l].lane` is set.
pub fn runBatch(comptime W: usize, comptime M: type, ctxs: []const root.RunCtx, opts: []const M.Options, out: []LaneOutcome) void {
    const g = ctxs.len;
    std.debug.assert(g >= 1 and g <= W and opts.len == g and out.len == g);
    var setups: [W]M.Setup = undefined;
    var xs: [W][]f64 = undefined;
    var ckts: [W]*root.Circuit = undefined;
    var live: [W]usize = undefined;
    var n_live: usize = 0;
    for (ctxs, opts, out, 0..) |*ctx, o, *res, l| {
        const scratch = ctx.scratch_allocator;
        setups[l] = M.setup(ctx, o) catch |err| {
            res.* = err;
            continue;
        };
        xs[l] = scratch.alloc(f64, ctx.circuit.n) catch |err| {
            setups[l].deinit(scratch);
            res.* = err;
            continue;
        };
        install(ctx.circuit, &setups[l], o.lane.?, xs[l], M.warm(ctx, o)) catch |err| {
            setups[l].deinit(scratch);
            scratch.free(xs[l]);
            res.* = err;
            continue;
        };
        ckts[n_live] = ctx.circuit;
        live[n_live] = l;
        n_live += 1;
    }
    var gathered: [W][]f64 = undefined;
    for (live[0..n_live], gathered[0..n_live]) |l, *x| x.* = xs[l];
    var results: [W]converger.Result = undefined;
    const solved: LaneError!void = if (n_live == 0) {} else solveBatch(W, ckts[0..n_live], gathered[0..n_live], newtonOptions(opts[0]), results[0..n_live], ctxs[live[0]].scratch_allocator);
    for (live[0..n_live], results[0..n_live]) |l, r| {
        const ctx = &ctxs[l];
        const scratch = ctx.scratch_allocator;
        defer {
            setups[l].deinit(scratch);
            scratch.free(xs[l]);
        }
        if (solved) |_| {} else |err| {
            out[l] = err;
            continue;
        }
        const np = ctx.probes.len;
        const row = scratch.alloc(f64, np) catch |err| {
            out[l] = err;
            continue;
        };
        defer scratch.free(row);
        if (r.converged) for (ctx.probes, row) |node, *v| {
            v.* = xs[l][node];
        };
        out[l] = M.publish(ctx, opts[l], opts[l].lane.?, row, &.{r});
    }
}

/// The plain Newton of `solveLanes` for one lane per circuit, each
/// installed and started at `xs[l]`, run W wide; `results[l]` is bitwise
/// lane l's `converger.run`. Under a JFNK pin or `-Dcertify` every lane
/// runs `converger.run`. Fails, for every lane, on allocation or a cancel.
pub fn solveBatch(comptime W: usize, ckts: []const *root.Circuit, xs: []const []f64, opts: converger.Options, results: []converger.Result, gpa: std.mem.Allocator) LaneError!void {
    const g = ckts.len;
    std.debug.assert(g >= 1 and g <= W and xs.len == g and results.len == g);
    const pin = ckts[0].knobs.newton.pin;
    if (W == 1 or g == 1 or !(pin == .auto or pin == .direct) or root.Circuit.certify) {
        for (ckts, xs, results) |c, x, *r| r.* = converger.run(c, try c.workspace(), x, 0, opts, root.EvalHook{}) catch |err| switch (err) {
            error.QueryCancelled => return error.QueryCancelled,
            error.OutOfMemory => return error.OutOfMemory,
            else => .{ .converged = false, .iterations = 0 },
        };
        return;
    }
    const L = @import("solver").lanes.Lanes(W);
    const System = @import("solver").lane_system.LaneSystem(W, root.Circuit, root.EvalHook);
    // Unused lanes repeat lane 0 and stay inactive.
    var lanes: [W]*root.Circuit = undefined;
    var wss: [W]*converger.Workspace = undefined;
    for (&lanes, &wss, 0..) |*c, *w, l| {
        c.* = ckts[if (l < g) l else 0];
        w.* = try c.*.workspace();
    }
    var sys = try System.init(gpa, lanes, .{});
    defer sys.deinit(gpa);
    sys.active = @truncate(@as(u64, std.math.maxInt(L.Mask)) >> @intCast(W - g));
    var lws = try converger.LaneWorkspace(W).init(gpa, wss);
    defer lws.deinit(gpa);
    const xv = try gpa.alloc(L.V, ckts[0].n);
    defer gpa.free(xv);
    for (xs, 0..) |x, l| System.putLane(xv, x, l);
    const res = converger.newtonLanes(W, &sys, &lws, xv, @splat(0), opts, System.LaneHook{});
    // As `converger.run` ends each lane's solve.
    for (ckts) |c| c.clearLimits();
    // A numerical failure of the whole batch marks every lane unconverged,
    // as `solveLanes` marks a lane's.
    const r = res catch |err| switch (err) {
        error.QueryCancelled => return error.QueryCancelled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            @memset(results, .{ .converged = false, .iterations = 0 });
            return;
        },
    };
    for (xs, results, 0..) |x, *out, l| {
        System.getLane(x, xv, l);
        const bit = @as(L.Mask, 1) << @intCast(l);
        out.* = .{ .converged = r.converged & bit != 0 and r.singular & bit == 0, .iterations = r.iterations[l] };
    }
}
