//! Transient: Newton per timestep on A = G + alpha*C (one axpy over nnz).
//! The companion residual uses the exact q(x) plane; the companion Jacobian
//! is the analytic C plane — nothing is lagged, nothing is dense.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;

// ponytail: platform SIMD width — not hardcoded
const W = std.simd.suggestVectorLength(f64) orelse 8;

// Data types live in types.zig (Circuit.zig names them in hook signatures);
// re-exported here so consumers keep writing tran.Options / tran.Waveform.
const tran_types = @import("types.zig");
pub const Method = tran_types.Method;
pub const Options = tran_types.Options;
pub const Waveform = tran_types.Waveform;
pub const SimResult = tran_types.SimResult;
pub const initialCapacity = tran_types.initialCapacity;
const simdCopy = tran_types.simdCopy;

// ---------------------------------------------------------------------------
// Integration methods: dynamic-residual coefficient, LTE estimate, timestep
// control. Internal to transient — only simulate() below drives these.
// ---------------------------------------------------------------------------
const integrator = struct {
    /// Dynamic-residual coefficient. The residual stamped per node is
    ///   BE:   F_dyn = (1/dt)*(q(x) - q_prev)
    ///   trap: F_dyn = (2/dt)*(q(x) - q_prev) - i_prev
    /// with i_prev the dynamic current of the previous accepted step.
    fn alpha(method: Method, dt: f64) f64 {
        return switch (method) {
            .backward_euler => 1.0 / dt,
            .trapezoidal => 2.0 / dt,
            .gear_2 => 3.0 / (2.0 * dt),
        };
    }

    /// ngspice CKTterr: per-state timestep bound, in seconds. For each
    /// charge state j (tolerance in CURRENT units, cktterr.c):
    ///   i_new_j     = α·(q0_j − q1_j) [− i_prev_j when the step ran trap]
    ///   volttol_j   = abstol + reltol·max(|i_new_j|, |i_prev_j|)
    ///   chargetol_j = reltol·max(|q0_j|, |q1_j|, chgtol) / dt
    ///   tol_j       = max(volttol_j, chargetol_j)
    ///   dd_j        = divided difference over order+2 charge points
    ///   del_j       = trtol·tol_j / max(abstol, coeff·|dd_j|)
    ///   order 2:      del_j = sqrt(del_j)
    /// coeff: 1/2 at order 1, 1/12 at order 2 (trap; gear_2 shares the
    /// order-2 path — ngspice's gear coefficient differs slightly, deferred).
    /// Returns min del over all states; the caller accepts the step iff
    /// del > 0.9·dt and uses del as the next dt (dctran.c:872-913).
    fn stepBound(
        order2: bool,
        q_cur: []const f64,
        q_prev: []const f64,
        q_prev2: []const f64,
        q_prev3: []const f64,
        i_prev: []const f64,
        alpha_used: f64,
        exec_trap: bool,
        dt: f64,
        dt1: f64,
        dt2: f64,
        reltol: f64,
        abstol: f64,
        chgtol: f64,
        trtol: f64,
    ) f64 {
        const V = @Vector(W, f64);
        const inv_dt: V = @splat(1.0 / dt);
        const inv_dt1: V = @splat(1.0 / dt1);
        const inv_sum01: V = @splat(1.0 / (dt + dt1));
        const av: V = @splat(alpha_used);
        const v_abstol: V = @splat(abstol);
        const v_reltol: V = @splat(reltol);
        const v_chgtol: V = @splat(chgtol);
        const v_trtol: V = @splat(trtol);
        const coeff: V = @splat(if (order2) 1.0 / 12.0 else 0.5);
        var vmin: V = @splat(std.math.inf(f64));
        var i: usize = 0;

        while (i + W <= q_cur.len) : (i += W) {
            const qc: V = q_cur[i..][0..W].*;
            const qp: V = q_prev[i..][0..W].*;
            const ip: V = i_prev[i..][0..W].*;
            const i_new = if (exec_trap) av * (qc - qp) - ip else av * (qc - qp);
            const volttol = v_abstol + v_reltol * @max(@abs(i_new), @abs(ip));
            const chargetol = v_reltol * @max(@max(@abs(qc), @abs(qp)), v_chgtol) * inv_dt;
            const tol = @max(volttol, chargetol);

            const qp2: V = q_prev2[i..][0..W].*;
            const f01 = (qc - qp) * inv_dt;
            const f12 = (qp - qp2) * inv_dt1;
            const f012 = (f01 - f12) * inv_sum01;
            var dd = f012;
            if (order2) {
                const qp3: V = q_prev3[i..][0..W].*;
                const f23 = (qp2 - qp3) * @as(V, @splat(1.0 / dt2));
                const f123 = (f12 - f23) * @as(V, @splat(1.0 / (dt1 + dt2)));
                dd = (f012 - f123) * @as(V, @splat(1.0 / (dt + dt1 + dt2)));
            }
            const del = v_trtol * tol / @max(v_abstol, coeff * @abs(dd));
            vmin = @min(vmin, del);
        }
        var min_del = @reduce(.Min, vmin);
        // Scalar tail
        while (i < q_cur.len) : (i += 1) {
            const i_new = if (exec_trap)
                alpha_used * (q_cur[i] - q_prev[i]) - i_prev[i]
            else
                alpha_used * (q_cur[i] - q_prev[i]);
            const volttol = abstol + reltol * @max(@abs(i_new), @abs(i_prev[i]));
            const chargetol = reltol * @max(@max(@abs(q_cur[i]), @abs(q_prev[i])), chgtol) / dt;
            const tol = @max(volttol, chargetol);
            const f01 = (q_cur[i] - q_prev[i]) / dt;
            const f12 = (q_prev[i] - q_prev2[i]) / dt1;
            const f012 = (f01 - f12) / (dt + dt1);
            var dd = f012;
            if (order2) {
                const f23 = (q_prev2[i] - q_prev3[i]) / dt2;
                const f123 = (f12 - f23) / (dt1 + dt2);
                dd = (f012 - f123) / (dt + dt1 + dt2);
            }
            const c: f64 = if (order2) 1.0 / 12.0 else 0.5;
            const del = trtol * tol / @max(abstol, c * @abs(dd));
            min_del = @min(min_del, del);
        }
        // sqrt is monotone — applying it to the reduced min is equivalent
        // to per-lane sqrt, and cheaper.
        return if (order2) @sqrt(min_del) else min_del;
    }
};



/// Newton hook: companion RHS from the q plane, matrix = G + alpha*C.
const TranHook = struct {
    alpha: f64,
    q_prev: []const f64,
    i_prev: ?[]const f64, // trap only
    q_prev2: ?[]const f64, // gear_2 only
    half_inv_dt: f64, // gear_2: 1/(2*dt)
    a_vals: []f64,
    q_snap: ?[]f64,
    has_charge: bool,
    has_history: bool,

    pub fn assemble(self: TranHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.q_snap) |snap| simdCopy(snap, ckt.q_vec[0..ckt.n]);
        if (self.has_charge) {
            const n: usize = ckt.n;
            const V = @Vector(W, f64);
            const av: V = @splat(self.alpha);
            var i: usize = 0;
            if (self.q_prev2) |qp2| {
                // Gear-2: rhs += alpha*(q - q_prev) - (1/(2*dt))*(q_prev - q_prev2)
                const hv: V = @splat(self.half_inv_dt);
                while (i + W <= n) : (i += W) {
                    const r: V = ckt.rhs[i..][0..W].*;
                    const qv: V = ckt.q_vec[i..][0..W].*;
                    const qp: V = self.q_prev[i..][0..W].*;
                    const qp2v: V = qp2[i..][0..W].*;
                    ckt.rhs[i..][0..W].* = r + av * (qv - qp) - hv * (qp - qp2v);
                }
                while (i < n) : (i += 1)
                    ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]) - self.half_inv_dt * (self.q_prev[i] - qp2[i]);
            } else if (self.i_prev) |ipv| {
                // Trapezoidal
                while (i + W <= n) : (i += W) {
                    const r: V = ckt.rhs[i..][0..W].*;
                    const qv: V = ckt.q_vec[i..][0..W].*;
                    const qp: V = self.q_prev[i..][0..W].*;
                    const ip: V = ipv[i..][0..W].*;
                    ckt.rhs[i..][0..W].* = r + av * (qv - qp) - ip;
                }
                while (i < n) : (i += 1)
                    ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]) - ipv[i];
            } else {
                // Backward Euler (or Gear-2 first-step fallback)
                while (i + W <= n) : (i += W) {
                    const r: V = ckt.rhs[i..][0..W].*;
                    const qv: V = ckt.q_vec[i..][0..W].*;
                    const qp: V = self.q_prev[i..][0..W].*;
                    ckt.rhs[i..][0..W].* = r + av * (qv - qp);
                }
                while (i < n) : (i += 1)
                    ckt.rhs[i] += self.alpha * (ckt.q_vec[i] - self.q_prev[i]);
            }
        }
        if (self.has_history) ckt.injectHistory(t);
    }

    pub fn vals(self: TranHook, ckt: *root.Circuit) []f64 {
        if (!self.has_charge) return ckt.g_vals;
        ckt.combineGC(self.alpha, self.a_vals);
        return self.a_vals;
    }
    /// One diagonal, without materializing the whole combined plane —
    /// see `Circuit.gcAt`. The residual gate calls this per unknown.
    pub fn diagAt(self: TranHook, ckt: *root.Circuit, slot: u32) f64 {
        return if (self.has_charge) ckt.gcAt(self.alpha, slot) else ckt.g_vals[slot];
    }
};

/// Fine-grained primitive: integrate into caller-owned x and waveform.
/// four/pss/envelope/tran_noise all drive this.
pub fn simulate(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    waveform: *Waveform,
    options: Options,
    allocator: std.mem.Allocator,
) !SimResult {
    // Whole-transient GPU path (engine-owned megakernel driver): chunked
    // cooperative launches integrate the full [0, t_stop] on-device. Only
    // when nothing needs per-step host callbacks or host-side state; any
    // error falls through to the CPU integrator with the waveform rewound.
    if (ckt.gpu_hook) |gh| {
        if (gh.simulate_tran) |gt| {
            if (options.step_fn == null and !ckt.has_history) gpu: {
                const len0 = waveform.len;
                const r = gt(gh.ctx, x, probes, waveform, options) catch {
                    waveform.len = len0;
                    break :gpu;
                };
                return r;
            }
        }
    }
    const n: usize = ckt.n;
    const has_charge = ckt.has_charge;
    const has_history = ckt.has_history;
    const trap = options.method == .trapezoidal;
    const gear = options.method == .gear_2;

    const ws = try ckt.workspace();
    const x_try = try allocator.alloc(f64, n);
    defer allocator.free(x_try);

    // Charge state: dynamic current i_prev and a charge-history ring
    // [cur, prev, prev2, prev3] for the companion residual + trap LTE.
    var a_vals: []f64 = &.{};
    var i_prev: []f64 = &.{};
    var q_snap: []f64 = &.{};
    var q_hist: [4][]f64 = .{ &.{}, &.{}, &.{}, &.{} };
    defer if (has_charge) {
        allocator.free(i_prev);
        allocator.free(q_snap);
        for (q_hist) |q| allocator.free(q);
    };
    // uic: op.solve never ran, so nothing has put the devices in a defined
    // static state. It normally does three things this transient now owes:
    // latch power-on FSM state under `initial_step` (§5.10.2 — the OP is the
    // first step of the analysis; with uic the transient is), commit that
    // latch, and leave a static kind behind for the charge seeding below.
    // .ic, not .dc: the uic start IS the transient's ic phase, so waveform
    // sources evaluate at t = 0 (analysis("tran") also true there).
    if (options.uic) {
        ckt.setSimState(.{ .kind = .ic, .initial_step = true });
        _ = ckt.stateCtl(.commit);
        ckt.setSimState(.{ .kind = .ic });
    }
    try ckt.computeBaseline();

    if (has_charge) {
        a_vals = try ws.ensureAVals(ckt.nnz);
        i_prev = try allocator.alloc(f64, n);
        q_snap = try allocator.alloc(f64, n);
        root.zeroSimd(i_prev);
        for (&q_hist) |*q| q.* = try allocator.alloc(f64, n);
        // Deliberately NOT preceded by setSimState: q_prev must be the charge
        // the OPERATING POINT saw, so this seeding eval runs in the static
        // state op.solve left behind (t = 0, dt = 0, analysis "dc"). The first
        // loop iteration below is what switches the devices into "tran".
        ckt.eval(x, 0);
        // Seed the whole history with q(0): divided differences over the
        // flat history vanish, so LTE control runs from the first step.
        simdCopy(q_hist[1], ckt.q_vec[0..n]);
        simdCopy(q_hist[2], ckt.q_vec[0..n]);
        simdCopy(q_hist[3], ckt.q_vec[0..n]);
    }

    if (has_history) ckt.recordHistory(x, 0);
    // Seed absdelay rings with the operating point: commitStates drives the
    // §4.5.7 zHistPush, whose first push fills the WHOLE ring with (0, v_op).
    // Without it the first Newton solve queries an all-zero ring and every
    // delay line reads 0 V for t < td — a false transient off the DC state.
    // Must run under kind=.tran: the generated core only computes the delay
    // operators' input expressions on the non-static branch (dt stays 0, so
    // zAbsdelay itself is still the DC identity).
    ckt.setSimState(.{ .t = 0, .dt = 0, .kind = .tran, .initial_step = true });
    _ = ckt.commitStates(x);

    // ngspice tmax default is (tstop-tstart)/50; explicit tmax replaces it.
    // Clamp to minimum delay for history-aware timestep control.
    var effective_dt_max = options.dt_max orelse options.t_stop / 50.0;
    if (ckt.minDelay()) |td_min| effective_dt_max = @min(effective_dt_max, td_min);
    // ngspice CKTminBreak: breakpoints closer than this to the current time
    // (or to each other) are merged/skipped.
    const min_break = 5e-5 * effective_dt_max;

    // Delayed breakpoint echoes: ngspice traload registers a breakpoint at
    // t + td whenever a transmission-line input has a sharp edge, so the
    // integrator lands exactly on the arriving wavefront. Approximation:
    // every LANDED breakpoint re-emits one echo at t + td; echo landings
    // re-emit in turn, so reflections cascade (t + 2td, 3td, ...).
    // ponytail: one td (circuit min delay) for all history devices; enumerate
    // per-device delays if mixed-td circuits still show edge smear.
    var echo_bps: [256]f64 = undefined;
    var n_echo: usize = 0;
    // Keyed on minDelay availability itself — `has_history` is the dead
    // histInject channel and gated the whole echo machinery off for every
    // generated line (VerA now emits `delays`, which is what minDelay reads).
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

    try waveform.record(0, x, probes);

    var cur: []f64 = x;
    var trial: []f64 = x_try;
    var t: f64 = 0;
    // ngspice dctran first step: min(tstop/100, tstep)/10 at init, then /10
    // again at the t = 0 breakpoint landing (`if (firsttime) CKTdelta /= 10`)
    // — net /100. Matching it exactly makes the startup ladder (and every
    // LTE-driven step after it) replay ngspice's grid on edge circuits.
    // Never past the first breakpoint — a 1ns pulse edge at t~0 must not be
    // skipped.
    var dt: f64 = @min(@min(options.dt_init, effective_dt_max), options.t_stop / 100.0) / 100.0;
    if (nextBp(ckt, echo_bps[0..n_echo], min_break)) |bp0| {
        if (bp0 < dt) dt = bp0 / 10.0;
    }
    var dt_prev: f64 = dt;
    var dt_prev2: f64 = dt;
    var steps: u32 = 0;
    // ZP_TRAN_STATS: step-economics telemetry. Wall time in a slow transient
    // is (attempts × Newton iters × eval cost); this says WHICH factor.
    const stats_on = std.c.getenv("ZP_TRAN_STATS") != null;
    var st_attempts: u64 = 0;
    var st_nr_iters: u64 = 0;
    var st_rej_newton: u64 = 0;
    var st_rej_state: u64 = 0;
    var st_rej_lte: u64 = 0;
    var st_order_drops: u64 = 0;
    var st_bp_landings: u64 = 0;
    // Order control (ngspice-style): start at BE, promote to configured
    // method when LTE says it's safe. Drop back to BE at breakpoints to
    // suppress trap companion ringing after source-edge discontinuities.
    var use_be: bool = true;
    // Breakpoint we clamped dt_next toward; landing is |t - bp| <= min_break
    // checked after the step is ACCEPTED (a rejected clamped step must not
    // leave a stale landing flag behind). bp_save_dt is spice3's CKTsaveDelta:
    // the dt the LTE wanted before the breakpoint clamp shortened it.
    var bp_target: ?f64 = null;
    var bp_save_dt: f64 = 0;

    while (t < options.t_stop and steps < options.max_steps) {
        // Publish the point this attempt is aiming at BEFORE anything evaluates
        // it: converger.run below drives eval (§9.10 `$abstime`, `ddt`) and
        // updateStates, and a generated device reads Instance.abstime, not the
        // `t` argument. Per ATTEMPT, not per accepted point — a rejected step
        // `continue`s back to here with the shrunken dt, so the last write
        // before an accept is always the dt that was actually accepted. Still
        // O(instances) per timepoint: it is outside the Newton loop.
        // §5.10.2 initial_step = the first step of the analysis; final_step =
        // the step that lands on t_stop (dt is clamped to it at the bottom).
        ckt.setSimState(.{
            .t = t + dt,
            .dt = dt,
            .kind = .tran,
            .initial_step = steps == 0,
            .final_step = t + dt >= options.t_stop,
        });
        const use_gear = gear and !use_be;
        const use_trap = trap and !use_be;
        const eff_method: Method = if (use_be) .backward_euler else options.method;
        const alpha_val = integrator.alpha(eff_method, dt);
        const hook = TranHook{
            .alpha = alpha_val,
            .q_prev = q_hist[1],
            .i_prev = if (use_trap and has_charge) i_prev else null,
            .q_prev2 = if (use_gear and has_charge) q_hist[2] else null,
            .half_inv_dt = if (use_gear) 1.0 / (2.0 * dt) else 0,
            .a_vals = a_vals,
            .q_snap = if (has_charge) q_snap else null,
            .has_charge = has_charge,
            .has_history = has_history,
        };

        simdCopy(trial, cur);
        var nr_opts = options.tol.newtonOpts(options.tol.itl4);
        nr_opts.dx_clamp = std.math.inf(f64);
        const nr = converger.run(ckt, ws, trial, t + dt, nr_opts, hook) catch converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };
        st_attempts += 1;
        st_nr_iters += nr.iterations;

        if (!nr.converged) {
            st_rej_newton += 1;
            // Rejected point: restore FSM devices to the last accepted state.
            _ = ckt.stateCtl(.revert);
            // Order drop first: a discontinuity rejects trap long before dt
            // is the problem. Retry at order 1 at the SAME dt; only halve
            // when the retry already ran order 1 (ngspice-style).
            if (!use_be and (trap or gear)) {
                st_order_drops += 1;
                use_be = true;
                continue;
            }
            dt *= 0.5;
            if (dt < options.dt_min) {
                // The most interesting exit — say where it died. (The stats
                // block at the bottom is skipped by this return.)
                if (stats_on) std.debug.print(
                    "tran-stats: DT UNDERFLOW (newton) at t={e:.6} dt={e:.3} accepted={d} attempts={d} nr_iters={d}\n",
                    .{ t, dt, steps, st_attempts, st_nr_iters },
                );
                return .{ .completed = false, .steps = steps, .t_final = t };
            }
            continue;
        }

        // Device state flip (switch crossed its threshold inside this step):
        // reject and shrink so the conductance discontinuity lands sharp at
        // the crossing (within min_break) instead of smeared across dt.
        // ngspice's raw output samples always straddle the true crossing, so
        // a sharp edge interpolates correctly onto its grid.
        if (dt > min_break and ckt.stateCtl(.query)) {
            st_rej_state += 1;
            _ = ckt.stateCtl(.revert);
            use_be = true;
            dt = @max(0.25 * dt, min_break);
            continue;
        }

        // §9.17.2 `$bound_step`: read after the accepted step, applied to the
        // NEXT one. Not folded into `effective_dt_max` above, because that is
        // computed once before the loop and every device's bound is still at
        // its `inf` default until an `updateState` has run.
        //
        // Nothing consumed this before. `min_delay` looks like the same
        // channel but is not: it reads `D.delays`, a decl no VerA-generated
        // device has, so it was null for every model here. tline's
        // `$bound_step(0.25*td)` was computed and stored and read by nobody,
        // which is why a TD=2 ns line responded at t=1.5 ns — the absdelay
        // history is a fixed 32-entry ring, and a query older than the ring
        // silently returns the newest sample instead of the delayed one.
        var dt_next = @min(dt * 2.0, effective_dt_max);
        if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);

        if (has_charge) {
            simdCopy(q_hist[0], q_snap);

            {
                const order2 = eff_method != .backward_euler;
                const del = integrator.stepBound(
                    order2, q_hist[0], q_hist[1], q_hist[2], q_hist[3],
                    i_prev, alpha_val, use_trap, dt, dt_prev, dt_prev2,
                    options.tol.reltol, options.tol.abstol, options.tol.chgtol, options.tol.trtol,
                );
                if (del < 0.9 * dt) {
                    st_rej_lte += 1;
                    _ = ckt.stateCtl(.revert);
                    if (!use_be and (trap or gear)) {
                        st_order_drops += 1;
                        use_be = true;
                        continue;
                    }
                    // ngspice retries at the LTE-suggested dt (dctran.c:966
                    // `CKTdelta = newdelta`), not a halving ladder: one reject
                    // lands the right dt, so the step phase through an edge
                    // tracks ngspice's instead of drifting a half-octave
                    // (digital/clamp's 0.48 ns final edge chord). The branch
                    // guard makes del < 0.9*dt, so this shrinks every retry.
                    dt = del;
                    if (dt < options.dt_min) {
                        if (stats_on) std.debug.print(
                            "tran-stats: DT UNDERFLOW (lte) at t={e:.6} dt={e:.3} accepted={d} attempts={d} nr_iters={d}\n",
                            .{ t, dt, steps, st_attempts, st_nr_iters },
                        );
                        return .{ .completed = false, .steps = steps, .t_final = t };
                    }
                    continue;
                }
                // ngspice caps growth at 2x per accepted step — without it a
                // post-breakpoint shrink jumps straight back to a huge dt and
                // starves edge ramps of points.
                dt_next = @min(@max(del, options.dt_min), 2.0 * dt, effective_dt_max);
            }

            // Promote BE → configured method when LTE-based dt is stable.
            // ngspice promotes when trap dt_next > 1.05 * current dt.
            if (use_be) {
                const trial_order2 = options.method != .backward_euler;
                const trial_del = integrator.stepBound(
                    trial_order2, q_hist[0], q_hist[1], q_hist[2], q_hist[3],
                    i_prev, alpha_val, use_trap, dt, dt_prev, dt_prev2,
                    options.tol.reltol, options.tol.abstol, options.tol.chgtol, options.tol.trtol,
                );
                if (trial_del > 1.05 * dt) use_be = false;
            }

            // Dynamic current update — must match the method actually used.
            const V = @Vector(W, f64);
            const av: V = @splat(alpha_val);
            var j: usize = 0;
            if (use_trap) {
                while (j + W <= n) : (j += W) {
                    const q0: V = q_hist[0][j..][0..W].*;
                    const q1: V = q_hist[1][j..][0..W].*;
                    const ip: V = i_prev[j..][0..W].*;
                    i_prev[j..][0..W].* = av * (q0 - q1) - ip;
                }
                while (j < n) : (j += 1) i_prev[j] = alpha_val * (q_hist[0][j] - q_hist[1][j]) - i_prev[j];
            } else {
                while (j + W <= n) : (j += W) {
                    const q0: V = q_hist[0][j..][0..W].*;
                    const q1: V = q_hist[1][j..][0..W].*;
                    i_prev[j..][0..W].* = av * (q0 - q1);
                }
                while (j < n) : (j += 1) i_prev[j] = alpha_val * (q_hist[0][j] - q_hist[1][j]);
            }
            const tail = q_hist[3];
            q_hist[3] = q_hist[2];
            q_hist[2] = q_hist[1];
            q_hist[1] = q_hist[0];
            q_hist[0] = tail;
            dt_prev2 = dt_prev;
            dt_prev = dt;
        }

        // ponytail: pointer swap instead of memcpy on accept
        const tmp = cur;
        cur = trial;
        trial = tmp;
        t += dt;
        steps += 1;
        _ = ckt.stateCtl(.commit);

        // If we just landed on a breakpoint, drop to BE + resume with
        // 0.1*min(saveDelta, gap to next break) — spice3 dctran's resume
        // rule, which resolves a paired edge (rise start/end 1ns apart)
        // instead of stepping over it. The history is NOT flushed — the
        // promotion check above re-promotes to trap on the next accepted step.
        if (bp_target) |bp| {
            if (@abs(t - bp) <= min_break) {
                st_bp_landings += 1;
                use_be = true;
                // Re-emit the landed breakpoint one line-delay later (see
                // echo_bps above). Dedupe within min_break; drop when full.
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
            bp_target = null;
        }

        if (has_history) ckt.recordHistory(cur, t);
        // §4.5.2 accepted-step bookkeeping for devices whose state is not
        // revertible. Here — once per ACCEPTED point, beside the host's own
        // history record — and not inside the Newton loop, which ran it per
        // iteration including every rejected attempt. See `Hooks.commit_state`.
        _ = ckt.commitStates(cur);

        try waveform.record(t, cur, probes);
        if (options.step_fn) |f| f(options.step_ctx, t, cur);

        // Breakpoint handling: clamp dt to land on the next breakpoint,
        // skipping breaks within min_break of the current time (ngspice
        // CKTminBreak merge of near-coincident breakpoints).
        if (nextBp(ckt, echo_bps[0..n_echo], t + min_break)) |bp| {
            const dt_to_bp = bp - t;
            if (dt_to_bp < dt_next) {
                bp_save_dt = dt_next;
                dt_next = dt_to_bp;
                bp_target = bp;
            }
        }

        dt = dt_next;
        if (t + dt > options.t_stop) dt = options.t_stop - t;
    }

    if (stats_on) {
        std.debug.print(
            "tran-stats: accepted={d} attempts={d} nr_iters={d} rej[newton={d} lte={d} state={d}] order_drops={d} bp_landings={d} avg_dt={e:.3}\n",
            .{ steps, st_attempts, st_nr_iters, st_rej_newton, st_rej_lte, st_rej_state, st_order_drops, st_bp_landings, if (steps > 0) t / @as(f64, @floatFromInt(steps)) else 0 },
        );
    }

    // Ensure caller's buffer has the final result
    if (cur.ptr != x.ptr) simdCopy(x, cur);
    return .{ .completed = t >= options.t_stop, .steps = steps, .t_final = t };
}

/// Contract entry: integrate from the operating point and format the
/// waveform point-major: (time, probes...) per row.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const x = try a.alloc(f64, x_op.len);
    defer a.free(x);
    simdCopy(x, x_op);

    var wf = try Waveform.init(a, @intCast(ctx.probes.len), initialCapacity(opts));
    defer wf.deinit();
    // ngspice treats a truncated transient as a hard failure ("timestep too
    // small") — never return a silently-truncated waveform.
    const sim = try simulate(ctx.circuit, x, ctx.probes, &wf, opts, a);
    if (!sim.completed) return error.TimestepTooSmall;

    const names = try root.probeNames(ctx, "time");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "time" literal
        a.free(names);
    }
    const ncols = names.len;
    const npoints: usize = wf.len;
    const data = try a.alloc(f64, npoints * ncols);
    const times = wf.timeSlice();
    for (0..npoints) |p| {
        const row = data[p * ncols ..][0..ncols];
        row[0] = times[p];
        for (0..ctx.probes.len) |idx| row[idx + 1] = wf.probeValues(@intCast(idx))[p];
    }

    return .{
        .plotname = "Transient Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}

// ============================================================================
// Tests
// ============================================================================
const testing = std.testing;
test "waveform: doubling fallback keeps probe-major data intact" {
    const allocator = testing.allocator;
    var waveform = try Waveform.init(allocator, 2, 2);
    defer waveform.deinit();

    const probes = [_]u32{ 0, 1 };
    for (0..10) |i| {
        const fi: f64 = @floatFromInt(i);
        const xv = [_]f64{ fi, 100.0 + fi };
        try waveform.record(fi * 1e-9, &xv, &probes);
    }

    try testing.expectEqual(@as(u32, 10), waveform.len);
    try testing.expect(waveform.capacity >= 10);
    for (0..10) |i| {
        const fi: f64 = @floatFromInt(i);
        try testing.expectApproxEqAbs(fi * 1e-9, waveform.timeSlice()[i], 1e-24);
        try testing.expectApproxEqAbs(fi, waveform.probeValues(0)[i], 1e-15);
        try testing.expectApproxEqAbs(100.0 + fi, waveform.probeValues(1)[i], 1e-15);
    }
}

test "alpha: BE 1/dt, trap 2/dt" {
    try std.testing.expectApproxEqRel(@as(f64, 1e9), integrator.alpha(.backward_euler, 1e-9), 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 2e9), integrator.alpha(.trapezoidal, 1e-9), 1e-12);
}

// ponytail: estimateLTE/adaptTimestep tests removed — LTE control now
// uses integrator.stepBound which has its own acceptance path in simulate().

// The one property the `set_sim_state` plumbing exists for. A generated
// device reads `Instance.abstime` (§9.10 `$abstime`), NOT the `t` argument of
// eval — with the host never writing that field every SPICE waveform is
// pinned at its t=0 value and a PULSE is a flat line at V1. Real generated
// vsource + resistor, real Circuit, real integrator: nothing is mocked, so a
// regression anywhere on the path (hook, vtable gate, call site, ordering)
// fails here.
test "transient: a PULSE vsource output actually moves with $abstime" {
    const gpa = testing.allocator;
    const dev = @import("devices");
    const Vsrc = dev.models.vsource;
    const Res = dev.models.resistor;
    const Proto = dev.batch.Proto;

    // node 0 = ground, node 1 = out, node 2 = vsource branch current.
    // PULSE(0 5 2ns 1ps 1ps 4ns 20ns): flat 0 up to 2 ns, 5 V over 2..6 ns.
    const VStore = dev.batch.ProtoStore(Vsrc);
    const vstore = try gpa.create(VStore);
    vstore.* = .{};
    try vstore.models.append(gpa, .{
        .waveform = 1,
        .pulse_v1 = 0.0,
        .pulse_v2 = 5.0,
        .pulse_td = 2e-9,
        .pulse_tr = 1e-12,
        .pulse_tf = 1e-12,
        .pulse_pw = 4e-9,
        .pulse_per = 20e-9,
    });
    try vstore.instances.append(gpa, .{});
    try vstore.nodes.append(gpa, .{ 1, 0, 2 });

    const RStore = dev.batch.ProtoStore(Res);
    const rstore = try gpa.create(RStore);
    rstore.* = .{};
    try rstore.models.append(gpa, .{ .r = 1000.0 });
    try rstore.instances.append(gpa, .{});
    try rstore.nodes.append(gpa, .{ 1, 0 });

    const protos = [_]Proto{
        .{
            .ctx = vstore,
            .type_name = @typeName(Vsrc),
            .pattern = VStore.addPattern,
            .finalize = VStore.finalize,
            .destroy = VStore.destroy,
            .apply_perm = VStore.applyPerm,
        },
        .{
            .ctx = rstore,
            .type_name = @typeName(Res),
            .pattern = RStore.addPattern,
            .finalize = RStore.finalize,
            .destroy = RStore.destroy,
            .apply_perm = RStore.applyPerm,
        },
    };

    // Flat intern table: 3 nodes all labelled "0" → bytes "000", offs step 1.
    const intern_bytes = try gpa.dupe(u8, "000");
    const intern_offs = try gpa.alloc(u32, 4);
    for (intern_offs, 0..) |*o, i| o.* = @intCast(i);
    var ckt = try root.freeze(gpa, 3, intern_bytes, intern_offs, &protos, null);
    defer ckt.deinit();

    const x = try gpa.alloc(f64, 3);
    defer gpa.free(x);
    root.zeroSimd(x);

    const probes = [_]u32{1};
    var wf = try Waveform.init(gpa, 1, 512);
    defer wf.deinit();

    const sim = try simulate(&ckt, x, &probes, &wf, .{
        .t_stop = 8e-9,
        .dt_init = 1e-10,
        .method = .backward_euler,
    }, gpa);
    try testing.expect(sim.completed);

    // The waveform must reach BOTH pulse levels. Before the fix every sample
    // read v1 (abstime stuck at 0), so `hi` was 0 and this failed.
    const times = wf.timeSlice();
    const vals = wf.probeValues(0);
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (vals) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try testing.expectApproxEqAbs(@as(f64, 0.0), lo, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0), hi, 1e-9);

    // ...and reach them at the RIGHT times: a plumbing bug that fed a stale or
    // off-by-one-step time would still swing 0..5.
    for (times, vals) |tt, v| {
        const want: f64 = if (tt < 2e-9 or tt > 6e-9) 0.0 else 5.0;
        // Skip the 1 ps edges themselves — a sample can legitimately land
        // mid-ramp there.
        const on_edge = @abs(tt - 2e-9) < 2e-12 or @abs(tt - 6e-9) < 2e-12;
        if (!on_edge) try testing.expectApproxEqAbs(want, v, 1e-6);
    }
}
