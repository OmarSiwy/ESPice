//! DC sweep (`.dc`): steps one parameter (a source value, a device parameter
//! or the temperature) through its ParamRef, one warm-started Newton per
//! point, and records the probes. An optional second parameter is the outer
//! loop, and each `tangents` variant row adds a first-order block.
//! Cites ngspice dctrcurv.c (predictor, state rotation, accumulated steps)
//! and DCTsetup; dev/analysis/dc-sweep.md and dev/analysis/optimize.md
//! (tangent rows).
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;
const op = @import("op.zig");

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Dc;

/// Contract entry: real, point-major (sweep value, probes...), outer blocks
/// concatenated, then one more such block per `opts.tangents` row. A point
/// that does not converge records NaN probes, in every block. The swept
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
    // A temperature sweep at either level writes every Model row's
    // temperature; put the netlist's back before the recompute above.
    const sweeps_temp = opts.target == .temp or (opts.hasOuter() and opts.target2.? == .temp);
    const temp_c = ckt.temp_c;
    defer if (sweeps_temp) ckt.setCircuitTemp(temp_c);

    const n_inner = if (opts.points.len > 0) opts.points.len else sweepCount(opts.start, opts.stop, opts.step);
    const n_outer: usize = if (!opts.hasOuter()) 1 else if (opts.points2.len > 0) opts.points2.len else sweepCount(opts.start2, opts.stop2, opts.step2);
    const npoints = n_inner * n_outer;
    const ncols = ctx.probes.len + 1;
    const data = try a.alloc(f64, npoints * ncols * (1 + opts.tangents.len));
    errdefer a.free(data);
    // The last two points, for the predictor, carried across outer blocks as
    // ngspice's state rotation is (dctrcurv.c:290). The analysis' first
    // point fills both, so the second point starts from the first.
    // Then `tangentRows`' scratch, sized once for the sweep: F(x) and dx,
    // and the saved values of the widest row's writes.
    var widest: usize = 0;
    for (opts.tangents) |row| widest = @max(widest, ctx.variants.writes(row)[0].len);
    const hist = try scratch.alloc(f64, 2 * ckt.n + if (opts.tangents.len == 0) 0 else 2 * ckt.n + widest);
    defer scratch.free(hist);
    @memset(hist[0 .. 2 * ckt.n], 0);
    const force = try scratch.alloc(converger.Force, ctx.nodeset.len);
    defer scratch.free(force);
    for (force, ctx.nodeset) |*f, ns| f.* = .{ .slot = ckt.diag_slots[ns.node], .row = ns.node, .value = ns.value };

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
            if (opts.points2.len > 0) v2 = opts.points2[po];
            if (t2) |r| r.set(v2) else ckt.setCircuitTemp(@floatCast(v2));
            try runSerial(ctx, ckt, hist, force, t, opts, po * n_inner, n_inner, ncols, data, po == 0);
        }
    } else {
        try runSerial(ctx, ckt, hist, force, t, opts, 0, npoints, ncols, data, true);
    }

    return .{
        .plotname = "DC transfer characteristic",
        .varnames = try root.probeNames(ctx, sweepColumn(opts.target)),
        .is_complex = false,
        .npoints = npoints * (1 + opts.tangents.len),
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

/// Sweeps `t` over `npoints` values into rows `first..` of `data` (`run`'s
/// layout, `ncols` wide), tangent blocks included; a null `t` sweeps the
/// circuit temperature.
/// Each point warm-starts from the previous solution; the first point, and
/// any point whose warm Newton fails, cold-starts through the `.nodeset`
/// step (`nodeset`) and the full OP ladder, as dctrcurv.c's CKTop calls do.
/// `hist[0 .. 2 * n]` holds the last two points and is left holding this
/// block's last two, for the next block's predictor; the rest is
/// `tangentRows`' scratch. `first_block` marks the
/// analysis' first block, whose first point also fills the older slot.
fn runSerial(
    ctx: *const root.RunCtx,
    ckt: *root.Circuit,
    hist: []f64,
    nodeset: []const converger.Force,
    t: ?root.ParamRef,
    opts: Options,
    first: usize,
    npoints: usize,
    ncols: usize,
    data: []f64,
    first_block: bool,
) !void {
    const x = hist[0..ckt.n];
    const x_prev = hist[ckt.n..][0..ckt.n];
    // Rows in one block: every point of every outer level.
    const block = data.len / ncols / (1 + opts.tangents.len);

    // The pattern is frozen, so one workspace (one symbolic factorization)
    // serves every point.
    const ws = try ckt.workspace();

    var cold = true;
    var v = opts.start;
    for (0..npoints) |pt| {
        if (pt != 0) try ckt.checkpoint(.{ .phase = .dc, .completed = pt, .total = npoints });
        // Accumulated like ngspice (see the outer loop in `run`).
        if (pt != 0) v += opts.step;
        if (opts.points.len > 0) v = opts.points[pt];
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
            ckt.evalFollowsFirst(x, 0);
            _ = ckt.applyLimits(x, x_prev);
            // A SingularMatrix here (NaN stamps from a bad warm guess) must
            // not abort the sweep; the point falls to the ladder like any
            // other failure.
            if (converger.run(ckt, ws, x, 0, converger.optionsFromTolerances(opts.tol, opts.tol.itl2), root.EvalHook{})) |r| {
                converged = r.converged;
            } else |e| switch (e) {
                error.SingularMatrix => {},
                else => return e, // else: only a singular warm guess falls to the ladder
            }
        }
        if (!converged) {
            op.coldStart(ckt, x);
            const lr = try op.nodesetLadder(ckt, ws, x, .{ .tol = opts.tol }, nodeset, 0);
            converged = lr.converged;
        }

        const row = data[(first + pt) * ncols ..][0..ncols];
        row[0] = v;
        for (0..opts.tangents.len) |k| data[((k + 1) * block + first + pt) * ncols] = v;
        if (converged) {
            // Each sweep point is an accepted point for device state.
            _ = ckt.stateCtl(.commit);
            for (ctx.probes, row[1..]) |node, *out| out.* = x[node];
            if (opts.tangents.len != 0) try tangentRows(ctx, ckt, ws, x, opts.tangents, hist[2 * ckt.n ..], data[(block + first + pt) * ncols ..], block * ncols, ncols);
            cold = false;
            // ngspice copies state0 into state1 after the first point
            // (dctrcurv.c:457-462), so the second point's MODEINITPRED
            // extrapolation holds the first point instead of doubling it.
            if (first_block and pt == 0) @memcpy(x_prev, x);
        } else {
            for (0..1 + opts.tangents.len) |k| @memset(data[(k * block + first + pt) * ncols ..][1..ncols], std.math.nan(f64));
            cold = true;
        }
    }
}

/// The probes of each `tangents` row at the solution `x`, to first order:
/// x - J⁻¹ (F(x, row) - F(x)), F with every parameter as the row writes it
/// and J factored at `x`, so one solve per row replaces the Newton solve of
/// a sweep at that row. Row k's probes go to `out[k * stride + 1 ..]`; NaN
/// when J at `x` is singular. `buf` holds 2n values plus the widest row's
/// writes. Leaves every parameter as it found it.
fn tangentRows(ctx: *const root.RunCtx, ckt: *root.Circuit, ws: *converger.Workspace, x: []const f64, tangents: []const u32, buf: []f64, out: []f64, stride: usize, ncols: usize) !void {
    const n = ckt.n;
    const params = try ckt.collectParams();
    const rhs = buf[0..n];
    const dx = buf[n..][0..n];
    // A full stamp: the baseline would hold the const-Jacobian devices
    // (resistors) at their nominal values, as in sens.zig.
    ckt.eval(x, 0);
    @memcpy(rhs, ckt.rhs[0..n]);
    const factored = if (ws.slv.factor(ckt.g_vals, ckt.solver_execution)) true else |e| switch (e) {
        error.SingularMatrix => false,
        else => return e, // else: only a singular J has an answer (NaN rows)
    };
    for (tangents, 0..) |row, k| {
        const probes = out[k * stride + 1 ..][0 .. ncols - 1];
        if (!factored) {
            @memset(probes, std.math.nan(f64));
            continue;
        }
        const refs, const values = ctx.variants.writes(row);
        const saved = buf[2 * n ..][0..refs.len];
        for (refs, values, saved) |r, value, *old| {
            old.* = params[r].get();
            params[r].set(value);
        }
        // The rows only move device parameters, so re-deriving their own
        // types is the whole recompute (Circuit.recomputeType). A row that
        // re-wires a device has no first-order answer on this pattern.
        const rewired = if (recomputeTypes(ckt, params, refs)) false else |e| switch (e) {
            error.TopologyChanged => true,
        };
        if (!rewired) {
            ckt.eval(x, 0);
            for (dx, ckt.rhs[0..n], rhs) |*d, f, f0| d.* = f - f0;
        }
        for (refs, saved) |r, old| params[r].set(old);
        recomputeTypes(ckt, params, refs) catch unreachable; // restores the values it was built at
        if (rewired) {
            @memset(probes, std.math.nan(f64));
            continue;
        }
        ws.slv.solveNeg(dx, dx);
        for (ctx.probes, probes) |node, *p| p.* = x[node] + dx[node];
    }
}

/// `Circuit.recomputeType` once for each device type `refs` writes.
fn recomputeTypes(ckt: *root.Circuit, params: []const root.ParamRef, refs: []const u32) error{TopologyChanged}!void {
    for (refs, 0..) |r, i| {
        const t = params[r].type;
        for (refs[0..i]) |earlier| {
            if (params[earlier].type == t) break;
        } else try ckt.recomputeType(t);
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

test sweepCount {
    const t = std.testing;
    // (0.95 - 0.3) / 0.005 lands just under 130 in f64; the endpoint stays.
    try t.expectEqual(@as(usize, 131), sweepCount(0.3, 0.95, 0.005));
    try t.expectEqual(@as(usize, 11), sweepCount(0, 1, 0.1));
    // A step that does not divide the span stops short of `stop`.
    try t.expectEqual(@as(usize, 4), sweepCount(0, 1, 0.3));
    try t.expectEqual(@as(usize, 1), sweepCount(2, 2, 1));
    // Descending with a negative step counts like ascending.
    try t.expectEqual(@as(usize, 6), sweepCount(5, 0, -1));
    // A zero step, or one pointing away from `stop`, is one point.
    try t.expectEqual(@as(usize, 1), sweepCount(0, 1, 0));
    try t.expectEqual(@as(usize, 1), sweepCount(0, 1, -0.1));
    try t.expectEqual(@as(usize, 1), sweepCount(1, 0, 0.1));
}
