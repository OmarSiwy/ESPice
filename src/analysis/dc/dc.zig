//! DC: Newton on A = G. solve()/solveWarm() are the point primitives;
//! run() sweeps the primary source through its ParamRef and records probes.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const op = @import("op.zig");


pub const Options = struct {
    tol: converger.Tolerances = .{},
    start: f64 = 0,
    stop: f64 = 0,
    step: f64 = 1,
    /// Batch-local index of the source to sweep (0 = first V or I source).
    source_index: u32 = 0,
};

pub const SolveResult = converger.Result;

pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
) !SolveResult {
    op.coldStart(ckt, x);
    return solveWarm(ckt, x, options, 0);
}

/// Warm variant: keeps x as the initial guess; gmin_extra raises the
/// regularization floor (op's gmin stepping).
pub fn solveWarm(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
    gmin_extra: f64,
) !SolveResult {
    // §4.6.1 `analysis("dc")`, §9.10 `$abstime` = 0. Every DC point is a static
    // solve; `initial_step` stays with op.solve, which is what actually runs
    // first in a job. ponytail: a standalone `.dc` sweep with no preceding OP
    // therefore never raises initial_step — plumb it in dc.run's point loop the
    // day a model needs a power-on latch without an operating point.
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    const ws = try ckt.workspace();
    var copts = options.tol.newtonOpts(options.tol.itl2);
    copts.gmin = @max(gmin_extra, options.tol.gmin);
    return converger.run(ckt, ws, x, 0, copts, root.EvalHook{});
}

/// Contract entry: sweep the primary source dc value, one warm-started
/// solve per point. Swept value restored afterwards so the cached operating
/// point stays valid for later jobs.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;

    // Locate the DC param pointer for the source at opts.source_index.
    const refs = try ckt.collectParams();
    var target: ?root.ParamRef = null;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.param_name, "dc") and ref.index == opts.source_index) {
            target = ref;
            break;
        }
    }
    const t = target orelse return error.DcSweepSourceNotFound;
    const saved = t.get();
    defer {
        t.set(saved);
        ckt.recompute();
    }

    const npoints = sweepCount(opts.start, opts.stop, opts.step);
    const ncols = ctx.probes.len + 1;
    const data = try a.alloc(f64, npoints * ncols);
    errdefer a.free(data);

    // -----------------------------------------------------------------------
    // GPU batch path: cold-start every point, solve all N simultaneously.
    // ponytail: cold-start-only batch; chunked warm-start is future work —
    // add when profiling shows serial warm-march dominates a large sweep.
    // -----------------------------------------------------------------------
    fill: {
        if (ckt.gpu_hook) |gh| if (gh.solve_batch) |sb| {
            if (runBatchGpu(ctx, ckt, a, t, gh, sb, opts, npoints, ncols, data)) |_|
                break :fill
            else |e| if (e == error.OutOfMemory) return e;
            // Other GPU errors fall through to the serial path.
        };
        try runSerial(ctx, ckt, a, t, opts, npoints, ncols, data);
    }

    return .{
        .plotname = "DC transfer characteristic",
        .varnames = try root.probeNames(ctx, "v-sweep"),
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

/// GPU batch: cold-start every sweep point, launch one batched Newton.
fn runBatchGpu(
    ctx: *const root.RunCtx,
    ckt: *root.Circuit,
    a: std.mem.Allocator,
    t: root.ParamRef,
    gh: root.GpuHook,
    sb: *const fn (*anyopaque, [][]f64, f64, converger.Options, []converger.Result) anyerror!void,
    opts: Options,
    npoints: usize,
    ncols: usize,
    data: []f64,
) !void {
    // Allocate per-lane x-vectors and result slots.
    const x_lanes = try a.alloc([]f64, npoints);
    defer {
        for (x_lanes) |lane| a.free(lane);
        a.free(x_lanes);
    }
    const results = try a.alloc(converger.Result, npoints);
    defer a.free(results);

    // For each sweep point: set the source value, repack GPU device state,
    // and prepare a cold-started x-vector.
    for (0..npoints) |pt| {
        const v = opts.start + @as(f64, @floatFromInt(pt)) * opts.step;
        t.set(v);
        ckt.has_baseline = false;
        ckt.recompute();
        try ckt.computeBaseline();

        // Repack GPU payloads so the device sees the new swept param.
        if (gh.repack) |rp| try rp(gh.ctx);

        const lane = try a.alloc(f64, ckt.n);
        op.coldStart(ckt, lane);
        x_lanes[pt] = lane;
    }

    var copts = opts.tol.newtonOpts(opts.tol.itl1);
    copts.gmin = opts.tol.gmin;
    try sb(gh.ctx, x_lanes, 0, copts, results);

    // Collect results into the output data table.
    for (0..npoints) |pt| {
        const v = opts.start + @as(f64, @floatFromInt(pt)) * opts.step;
        const row = data[pt * ncols ..][0..ncols];
        row[0] = v;
        if (results[pt].converged) {
            for (ctx.probes, row[1..]) |node, *out| out.* = x_lanes[pt][node];
        } else {
            for (row[1..]) |*out| out.* = std.math.nan(f64);
        }
    }
}

/// Serial sweep: warm-start from previous point, cold-restart on failure.
fn runSerial(
    ctx: *const root.RunCtx,
    ckt: *root.Circuit,
    a: std.mem.Allocator,
    t: root.ParamRef,
    opts: Options,
    npoints: usize,
    ncols: usize,
    data: []f64,
) !void {
    const x = try a.alloc(f64, ckt.n);
    defer a.free(x);
    root.zeroSimd(x);

    // One workspace serves every point — sparsity pattern is frozen, so
    // symbolic ordering/factorization happens exactly once for the sweep.
    const ws = try ckt.workspace();

    // First point (and any point whose warm-started Newton fails) goes
    // through the full OP ladder: seeded Newton -> gmin stepping -> source
    // stepping -> JFNK. Interior points warm-start from the previous solution
    // with a plain Newton at ITL2.
    var cold = true;
    for (0..npoints) |pt| {
        const v = opts.start + @as(f64, @floatFromInt(pt)) * opts.step;
        t.set(v);
        // Per-point: invalidate baseline and recompute device params so
        // constant-Jacobian stamps reflect the new swept value.
        ckt.has_baseline = false;
        ckt.recompute();
        try ckt.computeBaseline();

        var converged = false;
        if (!cold) {
            // Warm start from previous x. SingularMatrix on a warm-started
            // point (NaN stamps from a bad extrapolated guess) must not abort
            // the sweep — demote to the ladder like any non-converged point.
            if (converger.run(ckt, ws, x, 0, opts.tol.newtonOpts(opts.tol.itl2), root.EvalHook{})) |r| {
                converged = r.converged;
            } else |e| switch (e) {
                error.SingularMatrix => {},
                else => return e,
            }
        }
        if (!converged) {
            // Cold restart: zero x, seed junctions, run full OP ladder.
            op.coldStart(ckt, x);
            const lr = try op.solveLadder(ckt, ws, x, .{ .tol = opts.tol });
            converged = lr.converged;
        }

        // Record sweep point: v-sweep value + probe values (or NaN on failure).
        const row = data[pt * ncols ..][0..ncols];
        row[0] = v;
        if (converged) {
            for (ctx.probes, row[1..]) |node, *out| out.* = x[node];
            cold = false;
        } else {
            for (row[1..]) |*out| out.* = std.math.nan(f64);
            cold = true;
        }
    }
}

fn sweepCount(start: f64, stop: f64, step: f64) usize {
    if (step == 0 or (stop - start) * std.math.sign(step) < 0) return 1;
    return @as(usize, @intFromFloat(@floor((stop - start) / step))) + 1;
}
