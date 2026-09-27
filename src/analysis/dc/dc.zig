//! DC sweep (`.dc`): steps one parameter (a source value, a device parameter
//! or the temperature) through its ParamRef, one warm-started Newton per
//! point, and records the probes. An optional second parameter is the outer
//! loop.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;
const op = @import("op.zig");

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Dc;

/// Contract entry: real, point-major (sweep value, probes...), outer blocks
/// concatenated. A point that does not converge records NaN probes. The swept
/// values are restored afterwards so the cached operating point stays valid
/// for later jobs. Returns error.DcSweepSourceNotFound when a target names no
/// parameter.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;

    // DC simulation state for the whole sweep, whatever the shared op left
    // behind. A deck with a .tran solves its op in the ic phase, where
    // analysis("tran") is true and sources bias at waveform(0), which would
    // make the swept dc value a no-op (rtlinv).
    ckt.setSimState(.{ .kind = .dc });

    // Matching the device type as well as the index lets a deck hold both a
    // V and an I card (their per-type indices overlap) and lets the sweep
    // name a resistor.
    const refs = try ckt.collectParams();
    // A null target is the temperature (`.dc TEMP ...`).
    const t: ?root.ParamRef = switch (opts.target) {
        .temp => null,
        .device => |d| findTarget(refs, d) orelse return error.DcSweepSourceNotFound,
    };
    const saved: f64 = if (t) |r| r.get() else 0;
    defer {
        if (t) |r| r.set(saved);
        ckt.recompute() catch unreachable; // restores the checked original source value
    }
    // A temperature sweep at either level writes every instance's
    // temperature; put the netlist's back before the recompute above.
    const sweeps_temp = opts.target == .temp or (opts.hasOuter() and opts.target2.? == .temp);
    var temperatures: std.ArrayList(f64) = .empty;
    defer temperatures.deinit(scratch);
    if (sweeps_temp) for (refs) |ref| {
        if (ref.is_instance and std.mem.eql(u8, ref.param_name, "temperature"))
            try temperatures.append(scratch, ref.get());
    };
    defer if (sweeps_temp) {
        var i: usize = 0;
        for (refs) |ref| {
            if (ref.is_instance and std.mem.eql(u8, ref.param_name, "temperature")) {
                ref.set(temperatures.items[i]);
                i += 1;
            }
        }
    };

    const n_inner = sweepCount(opts.start, opts.stop, opts.step);
    const n_outer: usize = if (opts.hasOuter()) sweepCount(opts.start2, opts.stop2, opts.step2) else 1;
    const npoints = n_inner * n_outer;
    const ncols = ctx.probes.len + 1;
    const data = try a.alloc(f64, npoints * ncols);
    errdefer a.free(data);
    // The last two points, for the predictor, carried across outer blocks as
    // ngspice's state rotation is (dctrcurv.c:290). The analysis' first
    // point fills both, so the second point starts from the first.
    const hist = try scratch.alloc(f64, 2 * ckt.n);
    defer scratch.free(hist);
    @memset(hist, 0);

    // ngspice's second variable is the outer loop: the whole inner sweep
    // replays for each src2 value and the raw file concatenates the blocks.
    // The outer install is one ParamRef write or a circuit temperature set.
    if (opts.hasOuter()) {
        const outer = opts.target2.?;
        const t2: ?root.ParamRef = switch (outer) {
            .temp => null,
            .device => |d| findTarget(refs, d) orelse return error.DcSweepSourceNotFound,
        };
        const saved2: f64 = if (t2) |r| r.get() else 0;
        defer if (t2) |r| {
            r.set(saved2);
        };
        // Accumulated, not start + k*step: ngspice steps both levels with
        // `+= TRCVvStep` (dctrcurv.c:469) and its axis carries that roundoff
        // (1.4975e-13 where start + k*step gives 0), which is above the
        // oracle's axis tolerance.
        var v2 = opts.start2;
        for (0..n_outer) |po| {
            if (po != 0) v2 += opts.step2;
            if (t2) |r| r.set(v2) else ckt.setCircuitTemp(@floatCast(v2));
            const block = data[po * n_inner * ncols ..][0 .. n_inner * ncols];
            try runSerial(ctx, ckt, hist, t, opts, n_inner, ncols, block, po == 0);
        }
    } else {
        try runSerial(ctx, ckt, hist, t, opts, npoints, ncols, data, true);
    }

    return .{
        .plotname = "DC transfer characteristic",
        .varnames = try root.probeNames(ctx, sweepColumn(opts.target)),
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

/// The sweep column's name. ngspice names it after the swept quantity: a
/// current source sweeps `i(i-sweep)`, a resistance `res-sweep`, the
/// temperature `temp-sweep`.
fn sweepColumn(target: Options.SweepTarget) []const u8 {
    const d = switch (target) {
        .temp => return "temp-sweep",
        .device => |d| d,
    };
    const Library = @import("device").Library;
    inline for (.{
        .{ "isource", "i(i-sweep)" },
        .{ "resistor", "res-sweep" },
        .{ "capacitor", "cap-sweep" },
        .{ "inductor", "ind-sweep" },
    }) |pair| if (d.type == Library.builtin(pair[0])) return pair[1];
    return "v(v-sweep)";
}

fn findTarget(refs: []const root.ParamRef, want: Options.SweepTarget.Param) ?root.ParamRef {
    for (refs) |ref| {
        if (ref.index == want.index and
            std.mem.eql(u8, ref.param_name, want.param_name) and
            ref.type == want.type) return ref;
    }
    return null;
}

/// Sweeps `t` over `npoints` values into `data` (row-major, `ncols` wide);
/// a null `t` sweeps the circuit temperature.
/// Each point warm-starts from the previous solution; the first point, and
/// any point whose warm Newton fails, cold-starts through the full OP ladder.
/// `hist` (2 * n) holds the last two points and is left holding this block's
/// last two, for the next block's predictor. `first_block` marks the
/// analysis' first block, whose first point also fills the older slot.
fn runSerial(
    ctx: *const root.RunCtx,
    ckt: *root.Circuit,
    hist: []f64,
    t: ?root.ParamRef,
    opts: Options,
    npoints: usize,
    ncols: usize,
    data: []f64,
    first_block: bool,
) !void {
    const x = hist[0..ckt.n];
    const x_prev = hist[ckt.n..];

    // The pattern is frozen, so one workspace (one symbolic factorization)
    // serves every point.
    const ws = try ckt.workspace();

    var cold = true;
    var v = opts.start;
    for (0..npoints) |pt| {
        if (pt != 0) try ckt.checkpoint(.{ .phase = .dc, .completed = pt, .total = npoints });
        // Accumulated like ngspice (see the outer loop in `run`).
        if (pt != 0) v += opts.step;
        if (t) |r| r.set(v) else ckt.setCircuitTemp(@floatCast(v));
        // Recompute device params so const-Jacobian stamps see the new value.
        // Only `t`'s device type moved, so later points re-derive just that
        // type (a full walk cost 1,811 BJT preamble runs on a one-instance
        // deck). Point 0 takes the full walk: an outer `.dc ... temp` loop
        // may just have changed the temperature and re-wired a device (see
        // `Circuit.recomputeType`). A temperature point moves every type.
        if (t) |r| {
            if (pt == 0) try ckt.recompute() else try ckt.recomputeType(r.type);
        } else try ckt.recompute();
        try ckt.computeBaseline();

        // MODEINITPRED (dctrcurv.c:375, DEVpred in the device loads): start
        // from the last two points extrapolated (xfact = 1 on the uniform
        // step), limited against the last one. A cold point overwrites the
        // guess; the rotation still runs, as ngspice's state rotation does.
        for (x, x_prev) |*xi, *xp| {
            const last = xi.*;
            xi.* = 2.0 * last - xp.*;
            xp.* = last;
        }
        var converged = false;
        if (!cold) {
            _ = ckt.applyLimits(x, x_prev);
            // A SingularMatrix here (NaN stamps from a bad warm guess) must
            // not abort the sweep; the point falls to the ladder like any
            // other failure.
            if (converger.run(ckt, ws, x, 0, converger.optionsFromTolerances(opts.tol, opts.tol.itl2), root.EvalHook{})) |r| {
                converged = r.converged;
            } else |e| switch (e) {
                error.SingularMatrix => {},
                else => return e,
            }
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
            // ngspice copies state0 into state1 after the first point
            // (dctrcurv.c:457-462), so the second point's MODEINITPRED
            // extrapolation holds the first point instead of doubling it.
            if (first_block and pt == 0) @memcpy(x_prev, x);
        } else {
            for (row[1..]) |*out| out.* = std.math.nan(f64);
            cold = true;
        }
    }
}

/// Points from `start` to `stop` by `step`, endpoint inclusive (ngspice
/// DCTsetup loops `v <= stop`); 1 for a zero step or one pointing away from
/// `stop`.
fn sweepCount(start: f64, stop: f64, step: f64) usize {
    if (step == 0 or (stop - start) * std.math.sign(step) < 0) return 1;
    // An exact-integer ratio arrives just under itself in f64
    // ((0.95−0.3)/0.005 is 129.9999999), and a bare floor would drop the last
    // point (hicum2_gummel: 130 vs ngspice's 131). The 1e-6-step nudge
    // absorbs the ~1e-13 division error and is far below any fractional step
    // a deck means.
    return @as(usize, @intFromFloat(@floor((stop - start) / step + 1e-6))) + 1;
}
