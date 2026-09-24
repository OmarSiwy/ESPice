//! DC sweep: run() sweeps the primary source through its ParamRef, one
//! warm-started Newton per point on A = G, and records the probes.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const op = @import("op.zig");

pub const Options = @import("requests").Dc;

/// Contract entry: sweep the primary source dc value, one warm-started
/// solve per point. Swept value restored afterwards so the cached operating
/// point stays valid for later jobs.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    // `defer`-freed below == scratch; `a` is a results arena that cannot
    // reclaim it. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator;

    // DCOP flavor for the whole sweep, whatever the deck's shared op left
    // behind: a deck with a .tran runs its op in the ic phase, where
    // analysis("tran") is true and sources bias at waveform(0) — which made
    // this sweep's dc override a no-op again (rtlinv). runSerial inherits this.
    ckt.setSimState(.{ .kind = .dc });

    // Locate the swept parameter. Matching the DEVICE TYPE as well as the
    // index is what lets a deck hold both a V and an I card (their
    // batch-local indices overlap) and what lets the sweep name a resistor.
    const refs = try ckt.collectParams();
    const t = findTarget(refs, opts.target) orelse return error.DcSweepSourceNotFound;
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
        const outer = opts.target2.?;
        const t2: ?root.ParamRef = if (outer.is_temp)
            null
        else
            findTarget(refs, outer) orelse return error.DcSweepSourceNotFound;
        const saved2: f64 = if (t2) |r| r.get() else 0;
        defer if (t2) |r| {
            r.set(saved2);
        };
        var temperatures: std.ArrayList(f64) = .empty;
        defer temperatures.deinit(a);
        if (outer.is_temp) for (refs) |ref| {
            if (ref.is_instance and std.mem.eql(u8, ref.param_name, "temperature"))
                try temperatures.append(a, ref.get());
        };
        defer if (outer.is_temp) {
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
    } else {
        try runSerial(ctx, ckt, scratch, t, opts, npoints, ncols, data);
    }

    return .{
        .plotname = "DC transfer characteristic",
        // ngspice names the sweep column after the swept QUANTITY, not after
        // the analysis: a current source sweeps `i(i-sweep)`, a resistance
        // `res-sweep`, the temperature `temp-sweep`.
        .varnames = try root.probeNames(ctx, sweepColumn(opts.target)),
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

fn sweepColumn(target: Options.SweepTarget) []const u8 {
    if (target.is_temp) return "temp-sweep";
    const named = std.StaticStringMap([]const u8).initComptime(.{
        .{ "isource", "i(i-sweep)" },
        .{ "resistor", "res-sweep" },
        .{ "capacitor", "cap-sweep" },
        .{ "inductor", "ind-sweep" },
    });
    return named.get(target.type_name) orelse "v(v-sweep)";
}

fn findTarget(refs: []const root.ParamRef, want: Options.SweepTarget) ?root.ParamRef {
    for (refs) |ref| {
        if (ref.index == want.index and
            std.mem.eql(u8, ref.param_name, want.param_name) and
            std.mem.eql(u8, ref.device_type, want.type_name)) return ref;
    }
    return null;
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

    // One workspace serves every point — sparsity pattern is frozen, so
    // symbolic ordering/factorization happens exactly once for the sweep.
    const ws = try ckt.workspace();

    // First point (and any point whose warm-started Newton fails) goes
    // through the full OP ladder: seeded Newton -> gmin stepping -> source
    // stepping -> JFNK. Interior points warm-start from the previous solution
    // with a plain Newton at ITL2.
    var cold = true;
    for (0..npoints) |pt| {
        if (pt != 0) try ckt.checkpoint(.{ .phase = .dc, .completed = pt, .total = npoints });
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
            if (converger.run(ckt, ws, x, 0, converger.optionsFromTolerances(opts.tol, opts.tol.itl2), root.EvalHook{})) |r| {
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
