//! Transient analysis: Newton per timestep on A = G + ag0*C, with ngspice's
//! LTE step control, order promotion and breakpoint landing. The companion
//! residual uses the exact q(x) plane and the Jacobian the analytic C plane.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solver").converger;
const integrator = @import("integrator.zig");
const simdCopy = root.copySimd;

// ponytail: platform SIMD width, not hardcoded.
const W = std.simd.suggestVectorLength(f64) orelse 8;

const tran_types = @import("types.zig");
pub const Method = tran_types.Method;
pub const Options = tran_types.Options;
pub const Waveform = tran_types.Waveform;
pub const SimResult = tran_types.SimResult;
pub const initialCapacity = tran_types.initialCapacity;

/// ZP_TRAN_STATS step-economics counters: wall time in a slow transient is
/// attempts x Newton iterations x eval cost, and these say which factor.
const Stats = struct {
    attempts: u64 = 0,
    nr_iters: u64 = 0,
    rej_newton: u64 = 0,
    rej_state: u64 = 0,
    rej_lte: u64 = 0,
    order_drops: u64 = 0,
    bp_landings: u64 = 0,
};

/// Newton hook: companion RHS from the q plane, matrix G + ag0*C.
const TranHook = struct {
    /// The method this attempt integrates with (BE while order-dropped).
    method: Method,
    c: integrator.Coeffs,
    q_prev: []const f64,
    i_prev: []const f64, // read by trap only
    q_prev2: []const f64, // read by gear_2 only
    a_vals: []f64,
    has_charge: bool,

    pub fn assemble(self: TranHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.has_charge) {
            const n: usize = ckt.n;
            switch (self.method) {
                inline else => |m| integrator.companionAt(m, true, ckt.rhs[0..n], ckt.q_vec[0..n], self.q_prev, self.q_prev2, self.i_prev, self.c),
            }
        }
    }

    pub fn vals(self: TranHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.c.ag0, self.a_vals);
        return self.a_vals;
    }

    /// One diagonal of the combined matrix without materializing it
    /// (`Circuit.gcAt`); the residual gate calls this per unknown.
    pub fn diagAt(self: TranHook, ckt: *root.Circuit, slot: u32) f64 {
        return if (self.has_charge) ckt.gcAt(self.c.ag0, slot) else ckt.g_vals[slot];
    }
};

/// Integrates from the operating point in `x` to options.t_stop, recording
/// accepted points at t >= t_start into `waveform`. On return `x` holds the
/// last accepted solution. `allocator` backs per-run scratch only.
pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    waveform: *Waveform,
    options: Options,
    allocator: std.mem.Allocator,
) !SimResult {
    const n: usize = ckt.n;
    const has_charge = ckt.has_charge;

    const ws = try ckt.workspace();
    // A device's `request_reject_at` retries the step ending at that time.
    ckt.land_rejects = true;
    defer ckt.land_rejects = false;
    const x_try = try allocator.alloc(f64, n);
    defer allocator.free(x_try);
    // The accepted point before `cur`, for the predictor. Equal to `cur`
    // until the first step is accepted, so that step starts from the OP.
    const x_prev = try allocator.alloc(f64, n);
    defer allocator.free(x_prev);
    simdCopy(x_prev, x);

    // Row-plane charge state: the dynamic current and the charge ring
    // [cur, prev, prev2, prev3]. Slot 0 takes the charge of each converged
    // attempt; the companion residual reads slots 1 and 2.
    var a_vals: []f64 = &.{};
    var i_prev: []f64 = &.{};
    var q_hist: [4][]f64 = .{ &.{}, &.{}, &.{}, &.{} };
    defer if (has_charge) {
        allocator.free(i_prev);
        for (q_hist) |q| allocator.free(q);
    };

    // The LTE runs per device charge state, as ngspice's CKTterr does
    // (ckttrunc.c and the per-device trunc routines), not per matrix row:
    // charges that share a node add their divided differences, so a row's
    // slope belongs to no real state. The device `q_tape` holds one charge
    // per `ddt()` site the model leaves in the LTE (`vera_lte`), and the host
    // keeps a second history over it. The companion residual still
    // integrates the row plane.
    //
    // n_qt == 0 (no charge, or a GPU plane-stamp hook that bypasses the host
    // batches) runs the same kernel over the row plane. ZP_NO_QTAPE forces
    // that fallback for A/B runs; `n_qt` in the stats line says which is live.
    const n_qt: usize = if (has_charge and std.c.getenv("ZP_NO_QTAPE") == null) ckt.qTapeLen() else 0;
    // Coupled inductors: ngspice truncates one state per inductor, INDflux =
    // L*i + sum M*i_other (indload.c:72-76; MUT has no trunc routine). The
    // tape holds L*i and each M*i as separate states, which bind where
    // INDflux does not. With a K card, `lteSnap` zeroes the inductor and
    // kinduc tape spans (a flat zero history never binds) and appends the row
    // plane at every current row, since an inductor's branch row sums exactly
    // its INDflux. Both are resolved here, once: `lte_zero` holds the
    // [offset, end) tape spans to clear.
    // ponytail: every current row is appended (V-source rows carry no charge
    // and stay inert); take only the inductors' rows once Circuit exposes the
    // tape's rhs_idx.
    var lte_rows: []u32 = &.{};
    var lte_zero: [][2]u32 = &.{};
    defer allocator.free(lte_rows);
    defer allocator.free(lte_zero);
    if (n_qt > 0) for (ckt.batches) |kb| {
        if (!std.mem.eql(u8, kb.type_name, "kinduc")) continue;
        var rows: std.ArrayList(u32) = .empty;
        for (ckt.current_row[0..n], 0..) |is_cur, r| if (is_cur) try rows.append(allocator, @intCast(r));
        lte_rows = try rows.toOwnedSlice(allocator);
        var spans: std.ArrayList([2]u32) = .empty;
        var off: u32 = 0;
        for (ckt.batches) |b| {
            const f = b.hooks.q_tape orelse continue;
            const end = off + @as(u32, @intCast(f(b.ctx).len));
            if (std.mem.eql(u8, b.type_name, "inductor") or std.mem.eql(u8, b.type_name, "kinduc"))
                try spans.append(allocator, .{ off, end });
            off = end;
        }
        lte_zero = try spans.toOwnedSlice(allocator);
        break;
    };
    const n_lt = n_qt + lte_rows.len;
    const lteSnap = struct {
        fn call(c: *root.Circuit, dst: []f64, zero: []const [2]u32, rows: []const u32) void {
            const n_tape = dst.len - rows.len;
            c.snapshotQTape(dst[0..n_tape]);
            for (zero) |z| @memset(dst[z[0]..z[1]], 0);
            for (rows, dst[n_tape..]) |r, *d| d.* = c.q_vec[r];
        }
    }.call;
    var qt_i_prev: []f64 = &.{};
    var qt_hist: [4][]f64 = .{ &.{}, &.{}, &.{}, &.{} };
    defer if (n_qt > 0) {
        allocator.free(qt_i_prev);
        for (qt_hist) |q| allocator.free(q);
    };

    // uic skipped op.solve, so do its device bookkeeping here: latch power-on
    // FSM state under `initial_step` (§5.10.2), commit it, and leave a static
    // kind for the charge seeding below. `.ic`, not `.dc`: the uic start is
    // the transient's ic phase, so waveform sources evaluate at t = 0.
    // An idt's ic is its value at t = 0 (LRM §4.5.4) and the charge the
    // integration starts from, as a capacitor's IC is under ngspice's
    // MODEUIC (capload.c), so it is seeded here rather than left at 0.
    if (options.uic) {
        ckt.setSimState(.{ .kind = .ic, .initial_step = true });
        _ = ckt.stateCtl(.commit);
        ckt.setSimState(.{ .kind = .ic });
        ckt.seedIc(x);
    }
    try ckt.computeBaseline();

    if (has_charge) {
        a_vals = try ws.ensureAVals(ckt.nnz);
        i_prev = try allocator.alloc(f64, n);
        root.zeroSimd(i_prev);
        for (&q_hist) |*q| q.* = try allocator.alloc(f64, n);
        if (n_qt > 0) {
            qt_i_prev = try allocator.alloc(f64, n_lt);
            root.zeroSimd(qt_i_prev);
            for (&qt_hist) |*q| q.* = try allocator.alloc(f64, n_lt);
        }
        // No setSimState first: q_prev must be the charge the operating point
        // saw, so this eval runs in the static state op.solve left behind.
        ckt.eval(x, 0);
        // A flat q(0) history makes every divided difference vanish, so LTE
        // control runs from the first step.
        simdCopy(q_hist[1], ckt.q_vec[0..n]);
        simdCopy(q_hist[2], ckt.q_vec[0..n]);
        simdCopy(q_hist[3], ckt.q_vec[0..n]);
        if (n_qt > 0) {
            lteSnap(ckt, qt_hist[1], lte_zero, lte_rows);
            simdCopy(qt_hist[2], qt_hist[1]);
            simdCopy(qt_hist[3], qt_hist[1]);
        }
    }
    // The LTE history: per state when the tape is live, per row otherwise.
    // Same kernel either way, so the row path is the scalar oracle for the
    // tape path. The pointer follows the ring rotation.
    const lte_hist: *[4][]f64 = if (n_qt > 0) &qt_hist else &q_hist;
    const lte_ip: []const f64 = if (n_qt > 0) qt_i_prev else i_prev;

    // Seed absdelay rings with the operating point: the first §4.5.7
    // zHistPush fills the whole ring with (0, v_op), so no delay line reads
    // 0 V for t < td. Needs kind = .tran, the only branch on which the
    // generated core computes the delay inputs (dt = 0 keeps zAbsdelay the
    // DC identity).
    ckt.setSimState(.{ .t = 0, .dt = 0, .kind = .tran, .initial_step = true });
    _ = ckt.commitStates(x);
    _ = ckt.stateCtl(.commit);

    // ngspice tmax defaults to (tstop - tstart)/50; the circuit's minimum
    // delay caps it further.
    var effective_dt_max = options.dt_max orelse options.t_stop / 50.0;
    if (ckt.minDelay()) |td_min| effective_dt_max = @min(effective_dt_max, td_min);
    // The analysis' own CKTminBreak: delmin = 1e-11*maxStep and minBreak =
    // 10*delmin (traninit.c:36, dctran.c:170). Breakpoints closer than this
    // to the current time or to each other merge (dctran.c:636,
    // cktsetbk.c:45). optran.c:419's 5e-5*tmax is the OP transient's rule and
    // would merge away ns-scale source corners.
    const delmin = 1e-11 * effective_dt_max;
    const min_break = 10.0 * delmin;
    // How sharply a device state flip must land before the step is accepted.
    // An espice Newton/FSM tolerance with no ngspice counterpart; the switch
    // fixtures are tuned against it, so it is not min_break.
    const state_eps = 5e-5 * effective_dt_max;

    // Delayed breakpoint echoes, standing in for ngspice traload's t + td
    // breakpoint on a sharp line input: every landed breakpoint re-emits one
    // echo at t + td, and echo landings re-emit in turn (t + 2td, 3td, ...).
    // ponytail: one td (the circuit's minimum delay) for every history
    // device; enumerate per-device delays if mixed-td circuits show edge smear.
    var echo_bps: [256]f64 = undefined;
    var n_echo: usize = 0;
    const echo_td: ?f64 = ckt.minDelay();
    if (echo_td) |td_| {
        // t = 0 is itself a breakpoint (source edges often start there).
        echo_bps[0] = td_;
        n_echo = 1;
    }
    const nextBp = struct {
        fn call(c: *root.Circuit, echo: []const f64, after: f64) ?f64 {
            var best = std.math.inf(f64);
            if (c.nextBreakpoint(after)) |bp| best = bp;
            for (echo) |e| {
                if (e >= after and e < best) best = e;
            }
            return if (best == std.math.inf(f64)) null else best;
        }
    }.call;

    // tstart suppresses output, never the solve: [0, t_start) is integrated
    // with full history and not recorded.
    if (options.t_start <= 0) try waveform.record(0, x, probes);

    var cur: []f64 = x;
    var trial: []f64 = x_try;
    var prev: []f64 = x_prev;
    var t: f64 = 0;
    // ngspice's first step: min(tstep, tstop/100)/10 clamped to tmax outside
    // the min (dctran.c:134), then the t = 0 breakpoint clamp 0.1*breaks[1]
    // (dctran.c:578-586), then the firsttime /10. The operand order sets the
    // phase of the whole accepted grid.
    var dt: f64 = @min(@min(options.dt_init, options.t_stop / 100.0) / 10.0, effective_dt_max);
    if (nextBp(ckt, echo_bps[0..n_echo], min_break)) |bp0| dt = @min(dt, 0.1 * bp0);
    dt /= 10.0;
    if (options.t_start > 0 and dt > options.t_start) dt = options.t_start;
    // CKTdeltaOld[] starts at CKTmaxStep (dctran.c:312), which the first
    // divided differences read.
    var dt_prev: f64 = effective_dt_max;
    var dt_prev2: f64 = effective_dt_max;
    var steps: u32 = 0;
    const stats_on = std.c.getenv("ZP_TRAN_STATS") != null;
    var st: Stats = .{};
    // Order control: start at BE, promote to the configured method when the
    // LTE allows, and drop back to BE at breakpoints so trap does not ring
    // after a source edge.
    var use_be: bool = true;
    // ngspice's CKTbreaks[0] as the next step starts: the first breakpoint
    // past t + min_break, and whether dt_next was clamped onto it. Landing is
    // tested after the step is accepted, so a rejected step leaves no stale
    // flag. bp_save_dt is spice3's CKTsaveDelta, the dt the LTE wanted before
    // the last clamp; ngspice starts it at tstop/50 (dctran.c:318).
    var bp_next: ?f64 = null;
    var bp_clamped = false;
    var bp_save_dt: f64 = options.t_stop / 50.0;
    var attempted_dt = dt;

    while (t < options.t_stop and steps < options.max_steps) {
        if (st.attempts != 0) try ckt.checkpoint(.{
            .phase = .transient,
            .completed = st.attempts,
            .simulation_time = t,
            .step_size = attempted_dt,
            .next_step = dt,
            .accepted = steps,
        });
        attempted_dt = dt;
        // Publish the point this attempt aims at before anything evaluates
        // it: generated devices read Instance.abstime (§9.10 `$abstime`,
        // `ddt`), not the `t` argument. A rejected step comes back here with
        // the shrunken dt, so the last write before an accept is the accepted
        // dt. §5.10.2: initial_step is the analysis' first step, final_step
        // the one that lands on t_stop.
        ckt.setSimState(.{
            .t = t + dt,
            .dt = dt,
            .kind = .tran,
            .initial_step = steps == 0,
            .final_step = t + dt >= options.t_stop,
        });
        const eff_method: Method = if (use_be) .backward_euler else options.method;
        const cf = integrator.coeffs(eff_method, dt, dt_prev);
        const hook = TranHook{
            .method = eff_method,
            .c = cf,
            .q_prev = q_hist[1],
            .i_prev = i_prev,
            .q_prev2 = q_hist[2],
            .a_vals = a_vals,
            .has_charge = has_charge,
        };

        // MODEINITPRED (dctran.c:794, DEVpred in dioload.c/mos1load.c): the
        // first iterate extrapolates the last two accepted points by
        // dt/dt_prev and is limited against the last accepted one. HFET and
        // MESA divide by the step two back instead (CKTdeltaOld[2]).
        const xfact = dt / dt_prev;
        for (trial, cur, prev) |*xt, xc, xp| xt.* = xc + xfact * (xc - xp);
        ckt.predictFirstIterate(trial, cur, prev, dt / dt_prev2);
        ckt.evalFollows(trial, t + dt, false);
        _ = ckt.applyLimits(trial, cur);
        const nr_opts = converger.optionsFromTolerances(options.tol, options.tol.itl4);
        ckt.reject_at = null;
        const nr = converger.run(ckt, ws, trial, t + dt, nr_opts, hook) catch |err| switch (err) {
            error.QueryCancelled => return err,
            else => converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 },
        };
        st.attempts += 1;
        st.nr_iters += nr.iterations;

        if (!nr.converged) {
            st.rej_newton += 1;
            // Restore FSM devices to the last accepted state.
            _ = ckt.stateCtl(.revert);
            // Cut dt by 8 and drop to order 1 in one retry (dctran.c:815, :823).
            if (!use_be) st.order_drops += 1;
            use_be = true;
            dt /= 8.0;
            if (dt < options.dt_min) {
                // The stats block at the bottom is skipped by this return.
                if (stats_on) std.debug.print(
                    "tran-stats: DT UNDERFLOW (newton) at t={e:.6} dt={e:.3} accepted={d} attempts={d} nr_iters={d}\n",
                    .{ t, dt, steps, st.attempts, st.nr_iters },
                );
                return .{ .completed = false, .steps = steps, .t_final = t };
            }
            continue;
        }

        // A device located an event inside this step and asked for the step
        // to end on it (`request_reject_at`): retry landing there. A time
        // within state_eps of the step's end counts as the end, the
        // resolution the flip query below keeps too.
        if (ckt.reject_at) |tr| if (tr > t and t + dt - tr > state_eps and tr - t >= options.dt_min) {
            st.rej_state += 1;
            _ = ckt.stateCtl(.revert);
            dt = tr - t;
            continue;
        };

        // A device state flipped inside this step (a switch crossed its
        // threshold): reject and shrink so the conductance step lands within
        // state_eps of the crossing instead of smeared across dt.
        if (has_charge) ckt.evalFollows(trial, t + dt, true);
        if (dt > state_eps and ckt.stateCtl(.query)) {
            st.rej_state += 1;
            _ = ckt.stateCtl(.revert);
            use_be = true;
            dt = @max(0.25 * dt, state_eps);
            continue;
        }

        // The first accepted point skips CKTtrunc (dctran.c firsttime), so dt
        // repeats. §9.17.2 `$bound_step` is read after the step and applies
        // to the next one; devices only set it in `updateState`, so it cannot
        // be folded into effective_dt_max.
        var dt_next = if (steps == 0) dt else @min(dt * 2.0, effective_dt_max);
        if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);

        if (has_charge) {
            // CKTterr reads the charge of the published point. The converger
            // returns x_k+1 while the planes hold q(x_k) (or a JFNK matvec's
            // x), so re-read q at the solution: the LTE, advanceCurrent and
            // the next residual all see q(trial).
            ckt.evalQ(trial, t + dt);
            simdCopy(q_hist[0], ckt.q_vec[0..n]);
            if (n_qt > 0) lteSnap(ckt, qt_hist[0], lte_zero, lte_rows);
            // Taken before the ring rotation below.
            const lh = lte_hist.*;
            const lq: [4][]const f64 = .{ lh[0], lh[1], lh[2], lh[3] };
            const lte: integrator.LteIn = .{
                .dt = dt,
                .dt1 = dt_prev,
                .dt2 = dt_prev2,
                .reltol = options.tol.reltol,
                .abstol = options.tol.abstol,
                .chgtol = options.tol.chgtol,
                .trtol = options.tol.trtol,
            };

            if (steps > 0) {
                const del = integrator.stepBound(W, eff_method, eff_method, lq, lte_ip, cf, lte);
                if (del < 0.9 * dt) {
                    st.rej_lte += 1;
                    _ = ckt.stateCtl(.revert);
                    // Retry at the LTE's dt and the same order
                    // (dctran.c:966 `CKTdelta = newdelta`); only a Newton
                    // failure drops the order. del < 0.9*dt here, so every
                    // retry shrinks.
                    dt = del;
                    if (dt < options.dt_min) {
                        if (stats_on) std.debug.print(
                            "tran-stats: DT UNDERFLOW (lte) at t={e:.6} dt={e:.3} accepted={d} attempts={d} nr_iters={d}\n",
                            .{ t, dt, steps, st.attempts, st.nr_iters },
                        );
                        return .{ .completed = false, .steps = steps, .t_final = t };
                    }
                    continue;
                }
                // Growth capped at 2x per accepted step, as in ngspice.
                dt_next = @min(@max(del, options.dt_min), 2.0 * dt, effective_dt_max);
            }

            // Order promotion (dctran.c:901-913): recompute the trunc at
            // order 2 and adopt min(2*dt, del2) as the next dt whether or not
            // the order changes, as ngspice's `CKTdelta = newdelta` does.
            if (steps > 0 and use_be) {
                const trial_del = integrator.stepBound(W, options.method, eff_method, lq, lte_ip, cf, lte);
                const nd2 = @min(2.0 * dt, trial_del);
                if (nd2 > 1.05 * dt) use_be = false;
                dt_next = @min(@max(nd2, options.dt_min), effective_dt_max);
                if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);
            }

            // The dynamic current under the method actually used. Both index
            // spaces run it: ngspice keeps it per state in
            // CKTstates[0][qcap+1], where CKTterr's volttol reads it.
            integrator.advanceCurrent(eff_method, i_prev, q_hist[0], q_hist[1], q_hist[2], cf);
            if (n_qt > 0)
                integrator.advanceCurrent(eff_method, qt_i_prev, qt_hist[0], qt_hist[1], qt_hist[2], cf);

            // [cur, prev, prev2, prev3] -> [stale, cur, prev, prev2].
            std.mem.rotate([]f64, &q_hist, 3);
            if (n_qt > 0) std.mem.rotate([]f64, &qt_hist, 3);
        }
        dt_prev2 = dt_prev;
        dt_prev = dt;

        // Rotate the slices; accepted states need no copy.
        const stale = prev;
        prev = cur;
        cur = trial;
        trial = stale;
        t += dt;
        steps += 1;
        // §4.5.2 delay-line bookkeeping, once per accepted point
        // (`Hooks.commit_state`), then the commit that latches every stage.
        _ = ckt.commitStates(cur);
        _ = ckt.stateCtl(.commit);

        // Landed on a breakpoint: drop to BE and resume at
        // 0.1*min(saveDelta, gap to the next break), spice3 dctran's rule,
        // which resolves paired edges instead of stepping over them. The
        // history is kept; the promotion check re-promotes next step. A step
        // that was not clamped lands too when it ends within 100 ulps of the
        // breakpoint or delmin short of it (dctran.c:559); only min_break
        // separates a clamped landing from its target. The line echoes are
        // left out of that: they stand in for traload breakpoints ngspice
        // sets only on a sharp input, and tran/bench_tline_delay_line steps
        // through its t = td echo without a cut there.
        if (bp_next) |bp| {
            const landed = if (bp_clamped)
                @abs(t - bp) <= min_break
            else
                (bp - t <= delmin or almostEqualUlps(t, bp, 100)) and
                    std.mem.indexOfScalar(f64, echo_bps[0..n_echo], bp) == null;
            if (landed) {
                st.bp_landings += 1;
                use_be = true;
                // Re-emit one line delay later; dedupe within min_break and
                // drop when the table is full.
                if (echo_td) |td_| {
                    const e = t + td_;
                    if (e < options.t_stop and n_echo < echo_bps.len) {
                        var dup = false;
                        for (echo_bps[0..n_echo]) |old| {
                            if (@abs(old - e) <= min_break) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) {
                            echo_bps[n_echo] = e;
                            n_echo += 1;
                        }
                    }
                }
                var shrink = bp_save_dt;
                if (nextBp(ckt, echo_bps[0..n_echo], t + min_break)) |nb| shrink = @min(shrink, nb - t);
                dt_next = @min(dt_next, 0.1 * shrink);
            }
            bp_next = null;
        }

        // Stateful-charge devices: the commits above can move a device's q
        // away from what q_hist recorded. Re-read it so the next residual
        // starts from q(cur); otherwise it opens on alpha*(q_committed -
        // q_recorded), which doubles with every dt halving. The i_prev
        // correction is the same alpha*dq for every method. dq is not zero
        // after the pre-LTE re-read: dropping this changes the output of
        // txl2_3_line, hfet_inverter, mesa_oscillator and mos6_inverter.
        // `evalQ` computes the same q bits as `eval`, charges only.
        if (has_charge and ckt.has_state_q) {
            ckt.evalQ(cur, t);
            integrator.rebaseCurrent(W, i_prev, ckt.q_vec[0..n], q_hist[1], cf.ag0);
            simdCopy(q_hist[1], ckt.q_vec[0..n]);
            if (n_qt > 0) {
                lteSnap(ckt, qt_hist[0], lte_zero, lte_rows);
                integrator.rebaseCurrent(W, qt_i_prev, qt_hist[0], qt_hist[1], cf.ag0);
                // Swap, not copy: slot 0 is the ring's scratch slot, and the
                // next accepted attempt overwrites it before any read.
                std.mem.swap([]f64, &qt_hist[0], &qt_hist[1]);
            }
        }

        if (t >= options.t_start) {
            // ngspice does not step onto TSTART (dctran.c records the first
            // accepted t >= TSTART), and landing there would shift the whole
            // accepted grid. The first printed point is still TSTART itself,
            // interpolated from the step that crosses it (`prev` holds the
            // previous accepted state after the rotation).
            const t_prev = t - dt;
            if (t_prev < options.t_start and t > options.t_start)
                try waveform.recordLerp(options.t_start, prev, cur, (options.t_start - t_prev) / dt, probes);
            try waveform.record(t, cur, probes);
        }

        // Clamp dt to land on the next breakpoint, skipping those within
        // min_break of now (ngspice CKTminBreak merge).
        bp_next = nextBp(ckt, echo_bps[0..n_echo], t + min_break);
        bp_clamped = false;
        if (bp_next) |bp| {
            const dt_to_bp = bp - t;
            if (dt_to_bp < dt_next) {
                bp_save_dt = dt_next;
                dt_next = dt_to_bp;
                bp_clamped = true;
            }
        }

        dt = dt_next;
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    try ckt.checkpoint(.{
        .phase = .transient,
        .completed = st.attempts,
        .simulation_time = t,
        .step_size = attempted_dt,
        .next_step = if (t < options.t_stop) dt else 0,
        .accepted = steps,
    });
    if (stats_on) {
        std.debug.print(
            "tran-stats: n_qt={d} accepted={d} attempts={d} nr_iters={d} rej[newton={d} lte={d} state={d}] order_drops={d} bp_landings={d} avg_dt={e:.3}\n",
            .{ n_qt, steps, st.attempts, st.nr_iters, st.rej_newton, st.rej_lte, st.rej_state, st.order_drops, st.bp_landings, if (steps > 0) t / @as(f64, @floatFromInt(steps)) else 0 },
        );
    }

    if (cur.ptr != x.ptr) simdCopy(x, cur);
    return .{ .completed = t >= options.t_stop, .steps = steps, .t_final = t };
}

/// Contract entry: integrate from the operating point and return the
/// waveform as point-major rows (time, probes...). A run that stops short of
/// t_stop is error.TimestepTooSmall, as in ngspice.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;
    const x_op = ctx.x_op;
    const x = try scratch.alloc(f64, x_op.len);
    defer scratch.free(x);
    simdCopy(x, x_op);

    var wf = try Waveform.init(scratch, @intCast(ctx.probes.len), initialCapacity(opts));
    defer wf.deinit();
    const sim = try simulate(ctx.circuit, x, ctx.probes, &wf, opts, scratch);
    if (!sim.completed) return error.TimestepTooSmall;
    // HSPICE `.op <time>`: the state at t_stop, laid out as `.op` lays it out.
    if (opts.snapshot) {
        const names = try root.probeNames(ctx, null);
        const data = try a.alloc(f64, names.len);
        for (ctx.probes, data) |node, *out| out.* = x[node];
        return .{
            .plotname = try std.fmt.allocPrint(a, "Operating Point (time={e})", .{opts.t_stop}),
            .varnames = names,
            .is_complex = false,
            .npoints = 1,
            .data = data,
        };
    }

    const names = try root.probeNames(ctx, "time");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "time" literal
        a.free(names);
    }
    const data = try wf.toRows(a, names.len);
    return .{
        .plotname = "Transient Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = wf.len,
        .data = data,
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .W = W,
    .integrator = integrator,
    .almostEqualUlps = almostEqualUlps,
} else {};

/// ngspice's AlmostEqualUlps (maths/misc/equality.c): `a` and `b` are at
/// most `max_ulps` representable doubles apart, across zero included.
fn almostEqualUlps(a: f64, b: f64, max_ulps: i64) bool {
    if (a == b) return true;
    const lex = struct {
        fn f(x: f64) i128 {
            const i: i64 = @bitCast(x);
            return if (i < 0) @as(i128, std.math.minInt(i64)) - i else i;
        }
    }.f;
    return @abs(lex(a) - lex(b)) <= max_ulps;
}
