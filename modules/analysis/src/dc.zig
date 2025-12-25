//! DC: Newton on A = G. solve()/solveWarm() are the point primitives;
//! run() sweeps the primary source through its ParamRef and records probes.
const std = @import("std");
const root = @import("root.zig");
const newton = @import("newton.zig");

pub const Options = struct {
    start: f64 = 0,
    stop: f64 = 0,
    step: f64 = 1,
    max_iter: u16 = 100,
    abstol: f64 = 1e-12,
    reltol: f64 = 1e-3,
    gmin: f64 = 1e-12,
};

pub const SolveResult = newton.Result;

pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    @memset(x, 0);
    return solveWarm(ckt, x, options, allocator, 0);
}

/// Warm variant: keeps x as the initial guess; gmin_extra raises the
/// regularization floor (op's gmin stepping).
pub fn solveWarm(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
    allocator: std.mem.Allocator,
    gmin_extra: f64,
) !SolveResult {
    try ckt.computeBaseline();
    var ws = try newton.Workspace.init(allocator, ckt);
    defer ws.deinit(allocator);
    return newton.solve(ckt, &ws.slv, x, ws.dx, ws.x_old, 0, .{
        .max_iter = options.max_iter,
        .abstol = options.abstol,
        .gmin = @max(gmin_extra, options.gmin),
    }, newton.EvalHook{});
}

/// Contract entry: sweep the primary source dc value, one warm-started
/// solve per point. Swept value restored afterwards so the cached operating
/// point stays valid for later jobs.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;

    // ponytail: sweeps the first source's "dc" param — directive source names
    // resolve here via ParamRef when engine passes them through Options.
    const refs = try ckt.collectParams(a);
    defer a.free(refs);
    var target: ?*f32 = null;
    for (refs) |ref| {
        if (std.mem.eql(u8, ref.param_name, "dc") and ref.index == 0) {
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
    var ws = try newton.Workspace.init(a, ckt);
    defer ws.deinit(a);

    for (0..npoints) |pt| {
        const v = opts.start + @as(f64, @floatFromInt(pt)) * opts.step;
        t.* = @floatCast(v);
        ckt.recompute();
        const r = try newton.solve(ckt, &ws.slv, x, ws.dx, ws.x_old, 0, .{
            .max_iter = opts.max_iter,
            .abstol = opts.abstol,
            .gmin = opts.gmin,
        }, newton.EvalHook{});
        const row = data[pt * ncols ..][0..ncols];
        row[0] = v;
        if (r.converged) {
            for (ctx.probes, row[1..]) |node, *out| out.* = x[node];
        } else {
            for (row[1..]) |*out| out.* = std.math.nan(f64);
            @memset(x, 0); // cold-start the next point
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
