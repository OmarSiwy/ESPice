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
    var s: Sweep = undefined;
    try s.init(ctx, opts);
    defer s.deinit();
    for (0..s.n_outer) |po| {
        try s.beginBlock(po);
        for (0..s.n_inner) |pt| {
            var converged = false;
            if (try s.beginPoint(pt)) {
                s.prepareWarm();
                // A SingularMatrix here (NaN stamps from a bad warm guess)
                // must not abort the sweep; the point falls to the ladder
                // like any other failure.
                if (converger.run(s.ckt, s.ws, s.sol(), 0, s.warmOptions(), root.EvalHook{})) |r| {
                    converged = r.converged;
                } else |e| switch (e) {
                    error.SingularMatrix => {},
                    else => return e, // else: only a singular warm guess falls to the ladder
                }
            }
            try s.endPoint(pt, converged);
        }
    }
    return try s.take();
}

/// `run` for the lanes of one batch: `.dc` queries on one pattern that
/// sweep the same values, each from its own operating point and variant
/// row (dev/research/lane-batched-simulation.md §6, the `.dc` row). The
/// sweep axis stays sequential and every lane keeps its own predictor and
/// warm start; each point's warm Newton runs as lanes, and a lane it leaves
/// unconverged takes its own cold ladder, as `run` does. Lane l's result
/// lands in `out[l]`, bitwise `run` on `ctxs[l]`. Under a JFNK pin or
/// `-Dcertify` every lane runs `run`. Asserts 1 <= `ctxs.len` <= W.
pub fn runLanes(comptime W: usize, ctxs: []const root.RunCtx, opts: Options, out: []LaneOutcome) void {
    const g = ctxs.len;
    std.debug.assert(g >= 1 and g <= W and out.len == g);
    const pin = ctxs[0].circuit.knobs.newton.pin;
    if (W == 1 or g == 1 or !(pin == .auto or pin == .direct) or root.Circuit.certify) {
        for (ctxs, out) |*c, *o| o.* = run(c, opts);
        return;
    }
    const L = @import("solver").lanes.Lanes(W);
    const System = @import("solver").lane_system.LaneSystem(W, root.Circuit, root.EvalHook);
    var sweeps: [W]Sweep = undefined;
    var live: L.Mask = 0;
    for (ctxs, 0..) |*c, l| {
        sweeps[l].init(c, opts) catch |e| {
            out[l] = e;
            continue;
        };
        live |= @as(L.Mask, 1) << @intCast(l);
    }
    defer {
        var it = L.each(live);
        while (it.next()) |l| sweeps[l].deinit();
    }
    // Every lane fails with the batch's own error (out of memory).
    const fail = struct {
        fn f(sw: []Sweep, m: *L.Mask, o: []LaneOutcome, err: LaneError) void {
            var it = L.each(m.*);
            while (it.next()) |l| {
                o[l] = err;
                sw[l].deinit();
            }
            m.* = 0;
        }
    }.f;
    const kill = struct {
        fn f(sw: []Sweep, m: *L.Mask, o: []LaneOutcome, l: usize, err: LaneError) void {
            o[l] = err;
            sw[l].deinit();
            m.* &= ~(@as(L.Mask, 1) << @intCast(l));
        }
    }.f;
    if (live == 0) return;
    const first = @ctz(live);
    var lanes: [W]*root.Circuit = undefined;
    var wss: [W]*converger.Workspace = undefined;
    for (&lanes, &wss, 0..) |*c, *w, l| {
        const k = if (l < g and (live >> @intCast(l)) & 1 != 0) l else first;
        c.* = ctxs[k].circuit;
        w.* = c.*.workspace() catch |e| return fail(&sweeps, &live, out, e);
    }
    const gpa = ctxs[first].scratch_allocator;
    var sys = System.init(gpa, lanes, .{}) catch |e| return fail(&sweeps, &live, out, e);
    defer sys.deinit(gpa);
    var lws = converger.LaneWorkspace(W).init(gpa, wss) catch |e| return fail(&sweeps, &live, out, e);
    defer lws.deinit(gpa);
    const xv = gpa.alloc(L.V, lanes[0].n) catch |e| return fail(&sweeps, &live, out, e);
    defer gpa.free(xv);

    const n_outer = sweeps[first].n_outer;
    const n_inner = sweeps[first].n_inner;
    for (0..n_outer) |po| {
        var it = L.each(live);
        while (it.next()) |l| sweeps[l].beginBlock(po) catch |e| kill(&sweeps, &live, out, l, e);
        for (0..n_inner) |pt| {
            var warm: L.Mask = 0;
            it = L.each(live);
            while (it.next()) |l| {
                const w = sweeps[l].beginPoint(pt) catch |e| {
                    kill(&sweeps, &live, out, l, e);
                    continue;
                };
                if (!w) continue;
                sweeps[l].prepareWarm();
                System.putLane(xv, sweeps[l].sol(), l);
                warm |= @as(L.Mask, 1) << @intCast(l);
            }
            var converged: L.Mask = 0;
            if (warm != 0) {
                sys.active = warm;
                const res = converger.newtonLanes(W, &sys, &lws, xv, @splat(0), sweeps[@ctz(warm)].warmOptions(), System.LaneHook{});
                it = L.each(warm);
                // As `converger.run` ends each lane's solve.
                while (it.next()) |l| lanes[l].clearLimits();
                const r = res catch |e| return fail(&sweeps, &live, out, e);
                converged = r.converged;
                it = L.each(warm);
                while (it.next()) |l| System.getLane(sweeps[l].sol(), xv, l);
            }
            it = L.each(live);
            while (it.next()) |l| sweeps[l].endPoint(pt, (converged >> @intCast(l)) & 1 != 0) catch |e| kill(&sweeps, &live, out, l, e);
        }
    }
    var it = L.each(live);
    while (it.next()) |l| out[l] = sweeps[l].take();
}

const LaneError = root.ErrorOf(run);
/// One lane's `run` outcome.
pub const LaneOutcome = LaneError!root.Result;

/// One `.dc` analysis' state between its steps, so `run` and `runLanes`
/// share every step but the warm Newton. Blocks are the outer sweep's
/// levels, each sweeping the inner parameter (`runSerial` in ngspice
/// terms): every point warm-starts from the previous solution; a block's
/// first point, and any point whose warm Newton fails, cold-starts
/// through the `.nodeset` step and the full OP ladder, as dctrcurv.c's
/// CKTop calls do.
const Sweep = struct {
    ctx: *const root.RunCtx,
    ckt: *root.Circuit,
    opts: Options,
    /// The inner target; null sweeps the temperature.
    t: ?root.ParamRef,
    saved: f64,
    t2: ?root.ParamRef = null,
    saved2: f64 = 0,
    sweeps_temp: bool,
    temp_c: f32,
    n_inner: usize,
    n_outer: usize,
    ncols: usize,
    /// The result data, owned until `take`.
    data: []f64,
    /// The last two points for the predictor, carried across outer blocks
    /// as ngspice's state rotation is (dctrcurv.c:290), then
    /// `tangentRows`' scratch: F(x) and dx, and the saved values of the
    /// widest row's writes.
    hist: []f64,
    force: []converger.Force,
    ws: *converger.Workspace = undefined,
    /// The outer level `beginBlock` installed.
    block_index: usize = 0,
    first_block: bool = true,
    cold: bool = true,
    v: f64 = 0,
    v2: f64 = 0,
    taken: bool = false,

    /// `run`'s setup through the outer target. On an error everything set
    /// up so far is undone and freed.
    fn init(s: *Sweep, ctx: *const root.RunCtx, opts: Options) !void {
        const ckt = ctx.circuit;
        // DC simulation state for the whole sweep, whatever the shared op
        // left behind. A deck with a .tran solves its op in the ic phase,
        // where analysis("tran") is true and sources bias at waveform(0),
        // which would make the swept dc value a no-op (rtlinv).
        ckt.setSimState(.{ .kind = .dc });
        // Matching the device type as well as the index lets a deck hold
        // both a V and an I card (their per-type indices overlap) and lets
        // the sweep name a resistor.
        const refs = try ckt.collectParams();
        // A null target is the temperature (`.dc TEMP ...`).
        const t: ?root.ParamRef = switch (opts.target) {
            .temp => null,
            .device => |d| findTarget(refs, d) orelse return error.DcSweepSourceNotFound,
        };
        // A temperature sweep at either level writes every Model row's
        // temperature; `deinit` puts the netlist's back.
        s.* = .{
            .ctx = ctx,
            .ckt = ckt,
            .opts = opts,
            .t = t,
            .saved = if (t) |r| r.get() else 0,
            .sweeps_temp = opts.target == .temp or (opts.hasOuter() and opts.target2.? == .temp),
            .temp_c = ckt.temp_c,
            .n_inner = if (opts.points.len > 0) opts.points.len else sweepCount(opts.start, opts.stop, opts.step),
            .n_outer = if (!opts.hasOuter()) 1 else if (opts.points2.len > 0) opts.points2.len else sweepCount(opts.start2, opts.stop2, opts.step2),
            .ncols = ctx.probes.len + 1,
            .data = &.{},
            .hist = &.{},
            .force = &.{},
        };
        errdefer s.deinit();
        const npoints = s.n_inner * s.n_outer;
        s.data = try ctx.allocator.alloc(f64, npoints * s.ncols * (1 + opts.tangents.len));
        var widest: usize = 0;
        for (opts.tangents) |row| widest = @max(widest, ctx.variants.writes(row)[0].len);
        s.hist = try ctx.scratch_allocator.alloc(f64, 2 * ckt.n + if (opts.tangents.len == 0) 0 else 2 * ckt.n + widest);
        @memset(s.hist[0 .. 2 * ckt.n], 0);
        s.force = try ctx.scratch_allocator.alloc(converger.Force, ctx.nodeset.len);
        for (s.force, ctx.nodeset) |*f, ns| f.* = .{ .slot = ckt.diag_slots[ns.node], .row = ns.node, .value = ns.value };
        // ngspice's second variable is the outer loop: the whole inner
        // sweep replays for each src2 value and the raw file concatenates
        // the blocks. The outer install is one ParamRef write or a circuit
        // temperature set.
        if (opts.hasOuter()) {
            s.t2 = switch (opts.target2.?) {
                .temp => null,
                .device => |d| findTarget(refs, d) orelse return error.DcSweepSourceNotFound,
            };
            s.saved2 = if (s.t2) |r| r.get() else 0;
            // Accumulated, not start + k*step: ngspice steps both levels
            // with `+= TRCVvStep` (dctrcurv.c:469) and its axis carries that
            // roundoff (1.4975e-13 where start + k*step gives 0), which is
            // above the oracle's axis tolerance.
            s.v2 = opts.start2;
        }
    }

    /// Restores what the sweep moved (the outer target, the temperature,
    /// then the inner target with a full recompute) and frees its buffers,
    /// the data too unless `take` handed it out.
    fn deinit(s: *Sweep) void {
        if (s.t2) |r| r.set(s.saved2);
        if (s.sweeps_temp) s.ckt.setCircuitTemp(s.temp_c);
        if (s.t) |r| r.set(s.saved);
        s.ckt.recompute() catch unreachable; // restores the checked original source value
        if (!s.taken) s.ctx.allocator.free(s.data);
        s.ctx.scratch_allocator.free(s.hist);
        s.ctx.scratch_allocator.free(s.force);
    }

    fn take(s: *Sweep) !root.Result {
        s.taken = true;
        return .{
            .plotname = "DC transfer characteristic",
            .varnames = root.probeNames(s.ctx, sweepColumn(s.opts.target)) catch |e| {
                s.taken = false;
                return e;
            },
            .is_complex = false,
            .npoints = s.n_inner * s.n_outer * (1 + s.opts.tangents.len),
            .data = s.data,
        };
    }

    fn sol(s: *const Sweep) []f64 {
        return s.hist[0..s.ckt.n];
    }

    fn warmOptions(s: *const Sweep) converger.Options {
        return converger.optionsFromTolerances(s.opts.tol, s.opts.tol.itl2);
    }

    /// Installs outer level `po` and starts its block cold at `start`.
    fn beginBlock(s: *Sweep, po: usize) !void {
        if (s.opts.hasOuter()) {
            if (po != 0) s.v2 += s.opts.step2;
            if (s.opts.points2.len > 0) s.v2 = s.opts.points2[po];
            if (s.t2) |r| r.set(s.v2) else s.ckt.setCircuitTemp(@floatCast(s.v2));
        }
        s.block_index = po;
        s.first_block = po == 0;
        // The pattern is frozen, so one workspace (one symbolic
        // factorization) serves every point.
        s.ws = try s.ckt.workspace();
        s.cold = true;
        s.v = s.opts.start;
    }

    /// Installs point `pt` of the block and writes its predictor into `x`;
    /// true when the point runs a warm Newton first.
    fn beginPoint(s: *Sweep, pt: usize) !bool {
        const ckt = s.ckt;
        const opts = s.opts;
        if (pt != 0) try ckt.checkpoint(.{ .phase = .dc, .completed = pt, .total = s.n_inner });
        // Accumulated like ngspice (see `init`).
        if (pt != 0) s.v += opts.step;
        if (opts.points.len > 0) s.v = opts.points[pt];
        if (s.t) |r| r.set(s.v) else ckt.setCircuitTemp(@floatCast(s.v));
        // Recompute device params so const-Jacobian stamps see the new
        // value. Only `t`'s device type moved, so later points re-derive
        // just that type (a full walk cost 1,811 BJT preamble runs on a
        // one-instance deck). Point 0 takes the full walk: an outer `.dc
        // ... temp` loop may just have changed the temperature and re-wired
        // a device (see `Circuit.recomputeType`). A temperature point moves
        // every type.
        if (s.t) |r| {
            if (pt == 0) try ckt.recompute() else try ckt.recomputeType(r.type);
        } else try ckt.recompute();
        try ckt.computeBaseline();

        // MODEINITPRED (dctrcurv.c:375, DEVpred in the device loads): start
        // from the last two points extrapolated (xfact = 1 on the uniform
        // step), limited against the last one. A cold point overwrites the
        // guess; the rotation still runs, as ngspice's state rotation does.
        const x_prev = s.hist[ckt.n..][0..ckt.n];
        for (s.sol(), x_prev) |*xi, *xp| {
            const last = xi.*;
            xi.* = 2.0 * last - xp.*;
            xp.* = last;
        }
        return !s.cold;
    }

    /// The warm point's start: the predictor limited against the last point.
    fn prepareWarm(s: *Sweep) void {
        const x_prev = s.hist[s.ckt.n..][0..s.ckt.n];
        s.ckt.evalFollowsFirst(s.sol(), 0);
        _ = s.ckt.applyLimits(s.sol(), x_prev);
    }

    /// Ends point `pt`: the cold ladder when the warm Newton did not
    /// converge (or did not run), then the point's row and tangent rows.
    fn endPoint(s: *Sweep, pt: usize, warm_converged: bool) !void {
        const ckt = s.ckt;
        const ctx = s.ctx;
        const opts = s.opts;
        const ncols = s.ncols;
        const x = s.sol();
        const x_prev = s.hist[ckt.n..][0..ckt.n];
        // Rows in one tangent block: every point of every outer level.
        const block = s.n_inner * s.n_outer;
        var converged = warm_converged;
        if (!converged) {
            op.coldStart(ckt, x);
            const lr = try op.nodesetLadder(ckt, s.ws, x, .{ .tol = opts.tol }, s.force, 0);
            converged = lr.converged;
        }
        const at = s.block_index * s.n_inner + pt;
        const data = s.data;
        const row = data[at * ncols ..][0..ncols];
        row[0] = s.v;
        for (0..opts.tangents.len) |k| data[((k + 1) * block + at) * ncols] = s.v;
        if (converged) {
            // Each sweep point is an accepted point for device state.
            _ = ckt.stateCtl(.commit);
            for (ctx.probes, row[1..]) |node, *o| o.* = x[node];
            if (opts.tangents.len != 0) try tangentRows(ctx, ckt, s.ws, x, opts.tangents, s.hist[2 * ckt.n ..], data[(block + at) * ncols ..], block * ncols, ncols);
            s.cold = false;
            // ngspice copies state0 into state1 after the first point
            // (dctrcurv.c:457-462), so the second point's MODEINITPRED
            // extrapolation holds the first point instead of doubling it.
            if (s.first_block and pt == 0) @memcpy(x_prev, x);
        } else {
            for (0..1 + opts.tangents.len) |k| @memset(data[(k * block + at) * ncols ..][1..ncols], std.math.nan(f64));
            s.cold = true;
        }
    }
};

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
