//! DC: Newton on A = G. solve()/solveWarm() are the point primitives;
//! run() sweeps the primary source through its ParamRef and records probes.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
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
    try ckt.computeBaseline();
    const ws = try ckt.workspace();
    var copts = options.tol.newtonOpts(options.tol.itl2);
    copts.gmin = @max(gmin_extra, options.tol.gmin);
    return converger.run(ckt, ws, x, 0, copts, converger.EvalHook{});
}

/// Contract entry: sweep the primary source dc value, one warm-started
/// solve per point. Swept value restored afterwards so the cached operating
/// point stays valid for later jobs.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;

    // Find the DC param pointer for the source at opts.source_index.
    const refs = try ckt.collectParams();
    var target: ?*f32 = null;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.param_name, "dc") and ref.index == opts.source_index) {
            target = ref.ptr;
            break;
        }
    }
    const t = target orelse return error.DcSweepSourceNotFound;
    const saved = t.*;
    defer {
        t.* = saved;
        ckt.recompute();
    }

    const npoints = sweepCount(opts.start, opts.stop, opts.step);
    const ncols = ctx.probes.len + 1;
    const data = try a.alloc(f64, npoints * ncols);
    const x = try a.alloc(f64, ckt.n);
    defer a.free(x);
    @memset(x, 0);

    try ckt.computeBaseline();
    const ws = try ckt.workspace();

    // First point (and any point whose warm-started Newton fails) goes
    // through the full op ladder: seeded Newton → gmin stepping → source
    // stepping. Interior points warm-start from the previous solution.
    var cold = true;
    for (0..npoints) |pt| {
        const v = opts.start + @as(f64, @floatFromInt(pt)) * opts.step;
        t.* = @floatCast(v);
        ckt.recompute();
        var converged = false;
        if (!cold) {
            const r = try converger.run(ckt, ws, x, 0, opts.tol.newtonOpts(opts.tol.itl2), converger.EvalHook{});
            converged = r.converged;
        }
        if (!converged) {
            op.coldStart(ckt, x);
            const lr = try op.solveLadder(ckt, ws, x, .{ .tol = opts.tol });
            converged = lr.converged;
        }
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

    return .{
        .plotname = "DC transfer characteristic",
        .varnames = try root.probeNames(ctx, "v-sweep"),
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

fn sweepCount(start: f64, stop: f64, step: f64) usize {
    if (step == 0 or (stop - start) * std.math.sign(step) < 0) return 1;
    return @as(usize, @intFromFloat(@floor((stop - start) / step))) + 1;
}
