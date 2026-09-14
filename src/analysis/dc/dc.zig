//! DC: Newton on A = G. solve() is the point primitive;
//! run() sweeps the primary source through its ParamRef and records probes.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const op = @import("op.zig");
const lanes = @import("../sweep/lanes.zig");

pub const Options = struct {
    tol: converger.Tolerances = .{},
    start: f64 = 0,
    stop: f64 = 0,
    step: f64 = 1,
    /// Batch-local index of the source to sweep (0 = first V or I source).
    source_index: u32 = 0,
    /// ngspice's optional second sweep variable — the OUTER loop
    /// (`.dc src1 ... src2 start2 stop2 incr2`). null second index with
    /// `source2_is_temp` set sweeps the circuit temperature (`.dc ... temp ...`).
    source2_index: ?u32 = null,
    source2_is_temp: bool = false,
    start2: f64 = 0,
    stop2: f64 = 0,
    step2: f64 = 1,

    fn hasOuter(self: Options) bool {
        return self.source2_index != null or self.source2_is_temp;
    }
};

pub const SolveResult = converger.Result;

pub fn solve(
    ckt: *root.Circuit,
    x: []f64,
    options: Options,
) !SolveResult {
    op.coldStart(ckt, x);
    // §4.6.1 `analysis("dc")`, §9.10 `$abstime` = 0. Every DC point is a static
    // solve; `initial_step` stays with op.solve, which is what actually runs
    // first in a job. ponytail: a standalone `.dc` sweep with no preceding OP
    // therefore never raises initial_step — plumb it in dc.run's point loop the
    // day a model needs a power-on latch without an operating point.
    ckt.setSimState(.{ .kind = .dc });
    try ckt.computeBaseline();
    const ws = try ckt.workspace();
    const copts = options.tol.newtonOpts(options.tol.itl2);
    return converger.run(ckt, ws, x, 0, copts, root.EvalHook{});
}

/// Contract entry: sweep the primary source dc value, one warm-started
/// solve per point. Swept value restored afterwards so the cached operating
/// point stays valid for later jobs.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    // `defer`-freed below == scratch; `a` is a results arena that cannot
    // reclaim it. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;

    // DCOP flavor for the whole sweep, whatever the deck's shared op left
    // behind: a deck with a .tran runs its op in the ic phase, where
    // analysis("tran") is true and sources bias at waveform(0) — which made
    // this sweep's dc override a no-op again (rtlinv). runSerial/the GPU
    // lane path both inherit this.
    ckt.setSimState(.{ .kind = .dc });

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
        ckt.recompute() catch unreachable; // restores the checked original source value
    }

    const n_inner = sweepCount(opts.start, opts.stop, opts.step);
    const n_outer: usize = if (opts.hasOuter()) sweepCount(opts.start2, opts.stop2, opts.step2) else 1;
    const npoints = n_inner * n_outer;
    const ncols = ctx.probes.len + 1;
    const data = try a.alloc(f64, npoints * ncols);
    errdefer a.free(data);

    // ngspice's second variable is the OUTER loop: for each src2 value the
    // whole inner sweep replays, and the raw file concatenates the blocks
    // (v-sweep restarts per block). The outer install is one ParamRef write
    // (or a circuit temperature set) followed by the same serial march.
    if (opts.hasOuter()) {
        const t2: ?root.ParamRef = if (opts.source2_index) |idx2| blk: {
            for (refs) |ref| {
                if (std.mem.eql(u8, ref.param_name, "dc") and ref.index == idx2) break :blk ref;
            }
            return error.DcSweepSourceNotFound;
        } else null;
        const saved2: f64 = if (t2) |r| r.get() else 0;
        defer if (t2) |r| {
            r.set(saved2);
        };
        var temperatures: std.ArrayList(f64) = .empty;
        defer temperatures.deinit(a);
        if (opts.source2_is_temp) for (refs) |ref| {
            if (ref.is_instance and std.mem.eql(u8, ref.param_name, "temperature"))
                try temperatures.append(a, ref.get());
        };
        defer if (opts.source2_is_temp) {
            var i: usize = 0;
            for (refs) |ref| {
                if (ref.is_instance and std.mem.eql(u8, ref.param_name, "temperature")) {
                    ref.set(temperatures.items[i]);
                    i += 1;
                }
            }
        };
        for (0..n_outer) |po| {
            const v2 = opts.start2 + @as(f64, @floatFromInt(po)) * opts.step2;
            if (t2) |r| r.set(v2) else ckt.setCircuitTemp(@floatCast(v2));
            const block = data[po * n_inner * ncols ..][0 .. n_inner * ncols];
            try runSerial(ctx, ckt, a, t, opts, n_inner, ncols, block);
        }
    } else fill: {
        // -----------------------------------------------------------------------
        // GPU batch path: lane pt is sweep value start + pt*step, cold-started and
        // solved in one launch by sweep/lanes.zig. Only the GPU half is shared —
        // lanes' serial route is cold-start-only, and dc's is warm-started by
        // design (that is the point of a sweep), so runSerial below stays dc's own.
        // ponytail: cold-start-only batch; chunked warm-start is future work —
        // add when profiling shows serial warm-march dominates a large sweep.
        // -----------------------------------------------------------------------
        if (ckt.gpu_hook) |gh| if (gh.solve_batch != null) {
            const n: usize = ckt.n;
            const x_lanes = try scratch.alloc(f64, npoints * n);
            defer scratch.free(x_lanes);
            const results = try scratch.alloc(converger.Result, npoints);
            defer scratch.free(results);

            var lane_ctx: LaneCtx = .{ .source = t, .start = opts.start, .step = opts.step };
            const setup: lanes.LaneSetup = .{ .ctx = &lane_ctx, .apply = LaneCtx.apply, .restore = LaneCtx.restore };
            const copts = opts.tol.newtonOpts(opts.tol.itl1);
            if (try lanes.solveLanesGpu(ckt, setup, x_lanes, results, copts)) {
                for (0..npoints) |pt| {
                    const row = data[pt * ncols ..][0..ncols];
                    row[0] = opts.start + @as(f64, @floatFromInt(pt)) * opts.step;
                    const lane = x_lanes[pt * n ..][0..n];
                    for (ctx.probes, row[1..]) |node, *out|
                        out.* = if (results[pt].converged) lane[node] else std.math.nan(f64);
                }
                break :fill;
            }
        };
        try runSerial(ctx, ckt, scratch, t, opts, npoints, ncols, data);
    }

    return .{
        .plotname = "DC transfer characteristic",
        .varnames = try root.probeNames(ctx, "v(v-sweep)"),
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

/// solveLanesGpu apply/restore state: lane k installs sweep value
/// start + k*step on the swept source. `apply` is stateless, so re-running it
/// from k = 0 after a GPU fallthrough is a no-op difference; `restore` is
/// empty because run()'s defer owns putting the nominal value back — it has to
/// cover the serial route and the error paths anyway.
const LaneCtx = struct {
    source: root.ParamRef,
    start: f64,
    step: f64,

    fn apply(ptr: *anyopaque, k: usize) void {
        const self: *LaneCtx = @ptrCast(@alignCast(ptr));
        self.source.set(self.start + @as(f64, @floatFromInt(k)) * self.step);
    }

    fn restore(_: *anyopaque) void {}
};

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
        //
        // Only `t`'s device type moved, so every other batch would re-derive
        // to the value it already holds — measured at 1,811 BJT preamble runs
        // on a one-instance deck. But that is only true while temperature has
        // not moved, and the FIRST point of this sweep is exactly where an
        // outer `.dc ... temp` loop may just have changed it, possibly
        // re-wiring a device (see `Circuit.recomputeType`). So point 0 takes
        // the full walk and the rest narrow.
        if (pt == 0) try ckt.recompute() else try ckt.recomputeType(t.device_type);
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
    // The endpoint is inclusive (ngspice DCTsetup loops `v <= stop`). An
    // exact-integer ratio arrives just under it in f64 — (0.95−0.3)/0.005 is
    // 129.9999999 — and a bare floor drops the last point (hicum2_gummel 130
    // vs ngspice's 131). Nudge by 1e-6 of a step: absorbs the ~1e-13 division
    // error with room to spare, far below any fractional step a deck means.
    return @as(usize, @intFromFloat(@floor((stop - start) / step + 1e-6))) + 1;
}
