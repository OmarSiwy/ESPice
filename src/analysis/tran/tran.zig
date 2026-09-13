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

    /// LTE divided-difference coefficient — ngspice `CKTterr`
    /// (spicelib/analysis/cktterr.c:24-34, selected at :58-67 by
    /// `CKTintegrateMethod`, indexed `[CKTorder-1]`):
    ///   gearCoeff = {.5, .2222222222, .1363636364, .096, .0729927, .0583090}
    ///   trapCoeff = {.5, .08333333333}
    /// espice's order is fixed by the method (BE = 1, trap/gear_2 = 2), so the
    /// coefficient is a function of the method alone. Order 1 is `.5` in both
    /// tables, which is why BE reads the same either way — and why the order-2
    /// GEAR entry (2/9) was the only one that could be, and was, wrong: it had
    /// been sharing `trapCoeff[1]`, a 1.63x looser bound than GEAR asks for.
    fn lteCoeff(method: Method) f64 {
        return switch (method) {
            .backward_euler => 0.5, // gearCoeff[0] == trapCoeff[0]
            .trapezoidal => 1.0 / 12.0, // trapCoeff[1]
            .gear_2 => 2.0 / 9.0, // gearCoeff[1]
        };
    }

    /// Dynamic-current recurrence, in place — ngspice `NIintegrate`
    /// (maths/ni/niinteg.c) writing `CKTstate0[qcap+1]`:
    ///   BE / gear : i_j <- alpha*(q0_j - q1_j)
    ///   trap      : i_j <- alpha*(q0_j - q1_j) - i_j
    /// One body for the summed row plane (companion residual, length n) and for
    /// the per-device-state tape (LTE only, length n_qt). Expressions are
    /// unchanged from the two loops this replaces, so the row plane — which
    /// feeds the residual — stays bit-identical.
    fn advanceCurrent(i_cur: []f64, q0: []const f64, q1: []const f64, alpha_used: f64, exec_trap: bool) void {
        const V = @Vector(W, f64);
        const av: V = @splat(alpha_used);
        var j: usize = 0;
        while (j + W <= i_cur.len) : (j += W) {
            const a: V = q0[j..][0..W].*;
            const b: V = q1[j..][0..W].*;
            const ip: V = i_cur[j..][0..W].*;
            const d = av * (a - b);
            i_cur[j..][0..W].* = if (exec_trap) d - ip else d;
        }
        while (j < i_cur.len) : (j += 1) {
            const d = alpha_used * (q0[j] - q1[j]);
            i_cur[j] = if (exec_trap) d - i_cur[j] else d;
        }
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
    /// coeff = `lteCoeff(method)`; order = 2 for everything but BE.
    /// Returns min del over all states; the caller accepts the step iff
    /// del > 0.9·dt and uses del as the next dt (dctran.c:872-913).
    fn stepBound(
        method: Method,
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
        const order2 = method != .backward_euler;
        const c = lteCoeff(method);
        const V = @Vector(W, f64);
        const inv_dt: V = @splat(1.0 / dt);
        const inv_dt1: V = @splat(1.0 / dt1);
        const inv_sum01: V = @splat(1.0 / (dt + dt1));
        const av: V = @splat(alpha_used);
        const v_abstol: V = @splat(abstol);
        const v_reltol: V = @splat(reltol);
        const v_chgtol: V = @splat(chgtol);
        const v_trtol: V = @splat(trtol);
        const coeff: V = @splat(c);
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
    /// Per-device-state charge snapshot, same cadence as `q_snap` and for the
    /// same reason: JFNK's matvec re-evals after the converged assemble, so the
    /// last plane state is not necessarily the solution's. Null ⇒ per-row LTE
    /// (nothing carries charge, or the GPU owns the stamp).
    qt_snap: ?[]f64 = null,
    has_charge: bool,
    has_history: bool,

    pub fn assemble(self: TranHook, ckt: *root.Circuit, x: []const f64, t: f64) void {
        ckt.evalNewton(x, t);
        if (self.q_snap) |snap| simdCopy(snap, ckt.q_vec[0..ckt.n]);
        if (self.qt_snap) |snap| ckt.snapshotQTape(snap);
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
pub const simulate = simulateInto;

/// Same integrator, recording accepted samples through record(t, x, probes).
pub fn simulateInto(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    waveform: anytype,
    options: Options,
    allocator: std.mem.Allocator,
) !SimResult {
    // Whole-transient GPU path (engine-owned megakernel driver): chunked
    // cooperative launches integrate the full [0, t_stop] on-device. Only
    // when nothing needs per-step host callbacks or host-side state; any
    // error falls through to the CPU integrator with the waveform rewound.
    // A streamed recorder cannot rewind already-written samples on fallback.
    if (comptime @TypeOf(waveform) == *Waveform) if (ckt.gpu_hook) |gh| {
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
    };
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
    // Slot 0 receives the Newton snapshot; the solve only reads slots 1..3.
    var a_vals: []f64 = &.{};
    var i_prev: []f64 = &.{};
    var q_hist: [4][]f64 = .{ &.{}, &.{}, &.{}, &.{} };
    defer if (has_charge) {
        allocator.free(i_prev);
        for (q_hist) |q| allocator.free(q);
    };
    // Per-device-STATE LTE. ngspice calls CKTterr once per device charge state
    // and mins over states, then over devices (ckttrunc.c, captrunc.c,
    // bjttrunc.c, mos1trun.c); this ran it once per matrix ROW off the summed q
    // plane. Co-moving charges on one node add their divided differences, so
    // the row slope is not any real state's: on tline/txl2_3_line node 168
    // carries a 7.398 fF load cap plus two MOS gate charges, the row reads
    // 7.498 fF, and the post-breakpoint step seed comes out 1.3% short.
    //
    // The device tape already carried the per-contribution identity —
    // `buildTapes` writes rhs_idx[id*n_u + ru], a dense (instance, unknown)
    // array whose VALUE is the row — so the host keeps a second history over
    // that index space and reduces over it instead. Purely additive: the
    // companion residual still integrates the summed plane, bit for bit.
    //
    // n_qt == 0 (nothing carries charge, or a GPU plane-stamp hook means the
    // host batches never ran) falls back to the row plane — same kernel, same
    // formula, and the scalar oracle the tape path is differenced against.
    // ZP_NO_QTAPE forces the per-row fallback on a live binary. Not decoration:
    // it is the A/B that says whether a fixture's grid moved because of THIS
    // controller or because of something else, and `n_qt` in the stats line
    // says whether the tape is live at all. Setup-path getenv, never hot.
    const n_qt: usize = if (has_charge and std.c.getenv("ZP_NO_QTAPE") == null) ckt.qTapeLen() else 0;
    var qt_i_prev: []f64 = &.{};
    var qt_hist: [4][]f64 = .{ &.{}, &.{}, &.{}, &.{} };
    defer if (n_qt > 0) {
        allocator.free(qt_i_prev);
        for (qt_hist) |q| allocator.free(q);
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
        root.zeroSimd(i_prev);
        for (&q_hist) |*q| q.* = try allocator.alloc(f64, n);
        if (n_qt > 0) {
            qt_i_prev = try allocator.alloc(f64, n_qt);
            root.zeroSimd(qt_i_prev);
            for (&qt_hist) |*q| q.* = try allocator.alloc(f64, n_qt);
        }
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
        // Same seeding on the per-state tape, off the same eval.
        if (n_qt > 0) {
            ckt.snapshotQTape(qt_hist[1]);
            simdCopy(qt_hist[2], qt_hist[1]);
            simdCopy(qt_hist[3], qt_hist[1]);
        }
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
    // (or to each other) are merged/skipped (dctran.c:636, cktsetbk.c:45).
    //
    // This read `5e-5 * effective_dt_max`, which is optran.c:419's constant —
    // the OPERATING-POINT transient's rule, not the analysis's. The transient's
    // own is traninit.c:36 + dctran.c:170: delmin = 1e-11·maxStep and
    // CKTminBreak = 10·delmin, i.e. 500000x finer. Anything shorter than the
    // wrong value was merged away, so a deck with 1 ns PULSE corners and
    // tmax = 5 us (min_break 250 ps) dropped the corner at t = 1 ns entirely:
    // the grid stepped 0.8 ns -> 1.6 ns straight OVER the edge where ngspice
    // clamps and lands on it exactly. That is the whole "edge-phase" failure
    // class — the comparator was reading espice's missing sample, not a model.
    const delmin = 1e-11 * effective_dt_max;
    const min_break = 10.0 * delmin;
    // espice's own state-flip resolution floor — how sharply a switch crossing
    // must land before the step is accepted. Deliberately NOT min_break: it is
    // a Newton/FSM tolerance, has no ngspice counterpart, and the switch
    // fixtures are tuned against this value.
    const state_eps = 5e-5 * effective_dt_max;

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
    // ngspice dctran first step: min(tstop/100, tstep)/10 at init, clamped to
    // tmax (OUTSIDE the min — dctran.c:134 + the resume-loop maxStep clamp),
    // then /10 again at the t = 0 breakpoint landing (`firsttime` cut) — net
    // /100. Operand order matters: folding tmax into the min shifts the whole
    // accepted grid by a constant phase on every tmax < tstep deck (measured
    // 1 ps vs ngspice on tline/txl1, ringing down the TXL slow pole for 18 ns
    // after every wavefront). Never past the first breakpoint — a 1ns pulse
    // edge at t~0 must not be skipped.
    var dt: f64 = @min(@min(options.dt_init, options.t_stop / 100.0) / 10.0, effective_dt_max) / 10.0;
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
            .q_snap = if (has_charge) q_hist[0] else null,
            .qt_snap = if (n_qt > 0) qt_hist[0] else null,
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
        // the crossing (within state_eps) instead of smeared across dt.
        // ngspice's raw output samples always straddle the true crossing, so
        // a sharp edge interpolates correctly onto its grid.
        if (dt > state_eps and ckt.stateCtl(.query)) {
            st_rej_state += 1;
            _ = ckt.stateCtl(.revert);
            use_be = true;
            dt = @max(0.25 * dt, state_eps);
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
            // Per-device-STATE index space when the tape is live, per-row when
            // it is not. Same kernel, same formula, same acceptance test — only
            // the length changes, which is why the n_qt == 0 path is a genuine
            // scalar oracle and not a second implementation. Captured before
            // the ring rotation at the bottom of this block.
            const lq0 = if (n_qt > 0) qt_hist[0] else q_hist[0];
            const lq1 = if (n_qt > 0) qt_hist[1] else q_hist[1];
            const lq2 = if (n_qt > 0) qt_hist[2] else q_hist[2];
            const lq3 = if (n_qt > 0) qt_hist[3] else q_hist[3];
            const lip = if (n_qt > 0) qt_i_prev else i_prev;

            // dctran.c firsttime: the first accepted point skips CKTtrunc
            // entirely ("no check on first time point") — dt REPEATS, it
            // neither grows nor rejects. Without this the accepted grid runs
            // one first-dt ahead of ngspice's for the whole transient.
            if (steps == 0) {
                dt_next = dt;
            } else {
                const del = integrator.stepBound(
                    eff_method, lq0, lq1, lq2, lq3,
                    lip, alpha_val, use_trap, dt, dt_prev, dt_prev2,
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

            // Promote BE → configured method when LTE-based dt is stable
            // (dctran.c:901-913): recompute the trunc at order 2 and ADOPT
            // min(2·dt, del₂) as the next dt EITHER WAY — ngspice's
            // `CKTdelta = newdelta` keeps the order-2 result even when the
            // order drops back to 1. Keeping the order-1 del here instead
            // left the post-breakpoint ramp a half-octave behind ngspice's
            // (ltra1_1_line: 37 ps grid-phase offset by 32.3 ns, 1.02e-2 on
            // the delayed wavefront at 33.04 ns).
            if (steps > 0 and use_be) {
                const trial_del = integrator.stepBound(
                    options.method, lq0, lq1, lq2, lq3,
                    lip, alpha_val, use_trap, dt, dt_prev, dt_prev2,
                    options.tol.reltol, options.tol.abstol, options.tol.chgtol, options.tol.trtol,
                );
                const nd2 = @min(2.0 * dt, trial_del);
                if (nd2 > 1.05 * dt) use_be = false;
                dt_next = @min(@max(nd2, options.dt_min), effective_dt_max);
                if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);
            }

            // Dynamic current update — must match the method actually used.
            // Both index spaces run the SAME recurrence: ngspice keeps the
            // dynamic current in CKTstates[0][qcap+1], i.e. per state, and
            // CKTterr's volttol reads it there.
            integrator.advanceCurrent(i_prev, q_hist[0], q_hist[1], alpha_val, use_trap);
            if (n_qt > 0)
                integrator.advanceCurrent(qt_i_prev, qt_hist[0], qt_hist[1], alpha_val, use_trap);

            const tail = q_hist[3];
            q_hist[3] = q_hist[2];
            q_hist[2] = q_hist[1];
            q_hist[1] = q_hist[0];
            q_hist[0] = tail;
            if (n_qt > 0) {
                const qt_tail = qt_hist[3];
                qt_hist[3] = qt_hist[2];
                qt_hist[2] = qt_hist[1];
                qt_hist[1] = qt_hist[0];
                qt_hist[0] = qt_tail;
            }
            dt_prev2 = dt_prev;
            dt_prev = dt;
        }

        // ponytail: stdlib swaps the slices; accepted states need no copy.
        std.mem.swap([]f64, &cur, &trial);
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

        // Safety net for stateful-charge devices: if a state advance above
        // (stateCtl commit, commitStates) moved any device's reported q away
        // from the last Newton assemble, re-read it so q_prev is what the
        // NEXT step's residual reproduces at x = cur. Left open, that gap
        // opens the next attempt on F = α·(q_committed − q_recorded), which
        // DOUBLES every dt halving (mesa_oscillator wedged at t≈350 ps this
        // way under the retired freeze_grad latch). VerA's path-integrated
        // latches commit value-continuously — pq+wq in stateCtl equals the
        // assemble's fadd(pq, D) bit for bit. The i_prev correction is the same
        // α·Δq for both methods.
        //
        // NOT diagnostic, and Δq is NOT a rounding floor — this was gated off
        // once and had to come back (2026-09-07). `newton()` returns on the
        // iterate it converged, WITHOUT reassembling: `ckt.q_vec` holds q(x_k)
        // while `cur` is x_k+1. So Δq is the last Newton correction's charge,
        // ~C·dx, and α·Δq is 1e-7…7.7e-5 A against abstol 1e-12 — five to eight
        // decades above the floor. i_prev and q_hist[1] are not diagnostics
        // either: both are read by the NEXT step's companion residual
        // (`TranHook.assemble`, rhs += α(q − q_prev) − i_prev) and by
        // `stepBound`. Skipping this integrates the next step from a point one
        // Newton correction away from the one that was recorded.
        // Measured cost of keeping it: +10% devices/mos6_inverter, +14%
        // tran/fourbitadder, +17% scaling/parallel_inverters_100. Measured cost
        // of dropping it: 151 -> 149 fixtures passing, parallel_inverters_100
        // 8.98e-3 -> 1.49e-2 (PASS -> FAIL) while taking 3.4% MORE steps.
        // The two writes are one correction — applying either alone is worse
        // than applying neither (3.6e-2 on parallel_inverters_100).
        // Only the CHARGES are read here — g/c/rhs stay dead until the next
        // step's first `TranHook.assemble` zeroes and restamps all three — so
        // this is `evalQ`, the reactive half of the pass, not `eval`, run on a
        // value-only `S` (`engine.RealFor`) whose arithmetic is `Dual`'s value
        // half verbatim. Same `D.q`, same scatter, same bits, so `q_vec`/
        // `q_tape` are what the full pass wrote; it just stops computing the two
        // Jacobians and the resistive residual it was throwing away.
        //
        // It cannot be skipped, and not because of limiting: `newton()` returns
        // the iterate AFTER the one it assembled, so the accepted `cur` is one
        // Newton correction past the x the planes hold — always, limited or not.
        if (has_charge and ckt.has_state_q) {
            ckt.evalQ(cur, t);
            for (0..n) |j2| {
                const q_new = ckt.q_vec[j2];
                i_prev[j2] += alpha_val * (q_new - q_hist[1][j2]);
                q_hist[1][j2] = q_new;
            }
            // The per-state tape is the SAME two writes on the same Δq, off the
            // same re-read — `stepBound` now reduces over it, so leaving it
            // uncorrected would reintroduce exactly the "one Newton correction
            // away from the recorded point" error the row loop above exists to
            // close, only on the LTE side instead of the residual side.
            if (n_qt > 0) {
                ckt.snapshotQTape(qt_hist[0]);
                for (0..n_qt) |j2| {
                    qt_i_prev[j2] += alpha_val * (qt_hist[0][j2] - qt_hist[1][j2]);
                    qt_hist[1][j2] = qt_hist[0][j2];
                }
            }
        }

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
            "tran-stats: n_qt={d} accepted={d} attempts={d} nr_iters={d} rej[newton={d} lte={d} state={d}] order_drops={d} bp_landings={d} avg_dt={e:.3}\n",
            .{ n_qt, steps, st_attempts, st_nr_iters, st_rej_newton, st_rej_lte, st_rej_state, st_order_drops, st_bp_landings, if (steps > 0) t / @as(f64, @floatFromInt(steps)) else 0 },
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
    const scratch = ctx.scratch_allocator orelse a;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const x = try scratch.alloc(f64, x_op.len);
    defer scratch.free(x);
    simdCopy(x, x_op);

    var wf = try Waveform.init(scratch, @intCast(ctx.probes.len), initialCapacity(opts));
    defer wf.deinit();
    // ngspice treats a truncated transient as a hard failure ("timestep too
    // small") — never return a silently-truncated waveform.
    const sim = try simulate(ctx.circuit, x, ctx.probes, &wf, opts, scratch);
    if (!sim.completed) return error.TimestepTooSmall;

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

test "waveform: toRows tiling crosses tile boundaries exactly" {
    // 70 points over a 32-point tile: two full tiles plus a 6-point remainder,
    // with more probes than one tile of rows. Exact equality — the tiling only
    // reorders the copy, never the values.
    const allocator = testing.allocator;
    const n_probes = 5;
    var waveform = try Waveform.init(allocator, n_probes, 70);
    defer waveform.deinit();

    var xv: [n_probes]f64 = undefined;
    const probes = [_]u32{ 0, 1, 2, 3, 4 };
    for (0..70) |i| {
        for (&xv, 0..) |*v, k| v.* = @as(f64, @floatFromInt(i)) * 10.0 + @as(f64, @floatFromInt(k));
        try waveform.record(@as(f64, @floatFromInt(i)) * 1e-9, &xv, &probes);
    }

    const ncols = n_probes + 1;
    const rows = try waveform.toRows(allocator, ncols);
    defer allocator.free(rows);
    try testing.expectEqual(@as(usize, 70 * ncols), rows.len);
    for (0..70) |p| {
        try testing.expectEqual(@as(f64, @floatFromInt(p)) * 1e-9, rows[p * ncols]);
        for (0..n_probes) |k| {
            const want = @as(f64, @floatFromInt(p)) * 10.0 + @as(f64, @floatFromInt(k));
            try testing.expectEqual(want, rows[p * ncols + k + 1]);
        }
    }
}

test "alpha: BE 1/dt, trap 2/dt" {
    try std.testing.expectApproxEqRel(@as(f64, 1e9), integrator.alpha(.backward_euler, 1e-9), 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 2e9), integrator.alpha(.trapezoidal, 1e-9), 1e-12);
}

// cktterr.c:24-34 verbatim. gear_2 used to read trapCoeff[1] (1/12), which is
// 8/3 smaller and — through the sqrt at order 2 — a 1.63x LOOSER dt bound than
// GEAR's own error control asks for. Pin all three against the C tables.
test "lteCoeff: ngspice gearCoeff/trapCoeff tables" {
    try testing.expectEqual(@as(f64, 0.5), integrator.lteCoeff(.backward_euler));
    try testing.expectApproxEqRel(@as(f64, 0.08333333333), integrator.lteCoeff(.trapezoidal), 1e-10);
    try testing.expectApproxEqRel(@as(f64, 0.2222222222), integrator.lteCoeff(.gear_2), 1e-10);
    // The bound is trtol*tol/(coeff*|dd|) under a sqrt, so the ratio a gear
    // deck's dt moves by is sqrt(trapCoeff[1]/gearCoeff[1]) = 0.6124.
    try testing.expectApproxEqRel(
        @as(f64, 0.61237243569),
        @sqrt(integrator.lteCoeff(.trapezoidal) / integrator.lteCoeff(.gear_2)),
        1e-9,
    );
}

// The whole point of per-device-state LTE, as a pure function. Two charge
// contributions that cancel EXACTLY on their shared row: each swings 2 pC over
// the step, the row sums to a flat zero. ngspice's CKTterr sees each state and
// binds; the summed q plane sees nothing and steps 14 decades too far. Fails
// the moment stepBound is fed row-summed charge again.
test "stepBound: per-state min survives what the summed row cancels" {
    const dt: f64 = 1e-9;
    const reltol: f64 = 1e-3;
    const abstol: f64 = 1e-12;
    const chgtol: f64 = 1e-14;
    const trtol: f64 = 7.0;

    // 2*W+1: W cancelling pairs through the vector body, one dead slot so the
    // scalar tail runs too.
    const len = 2 * W + 1;
    var s_cur: [len]f64 = @splat(0);
    var s_prev: [len]f64 = @splat(0);
    const s_zero: [len]f64 = @splat(0);
    var k: usize = 0;
    while (k + 1 < len) : (k += 2) {
        s_cur[k] = 3e-12;
        s_cur[k + 1] = -3e-12;
        s_prev[k] = 1e-12;
        s_prev[k + 1] = -1e-12;
    }
    // Row view: every pair sums to zero, and so does its whole history.
    const row: [W + 1]f64 = @splat(0);

    const del_state = integrator.stepBound(
        .backward_euler, &s_cur, &s_prev, &s_zero, &s_zero, &s_zero,
        1.0 / dt, false, dt, dt, dt, reltol, abstol, chgtol, trtol,
    );
    const del_row = integrator.stepBound(
        .backward_euler, &row, &row, &row, &row, &row,
        1.0 / dt, false, dt, dt, dt, reltol, abstol, chgtol, trtol,
    );

    // Closed form, so the CKTterr formula is pinned and not just the inequality:
    //   i_new     = (1/dt)*(3e-12 - 1e-12)            = 2e-3
    //   volttol   = abstol + reltol*i_new             = 2.000001e-6
    //   chargetol = reltol*3e-12/dt                   = 3e-6      <- binds
    //   dd  = ((3e-12-1e-12)/dt - (1e-12-0)/dt)/(2*dt) = 5e5
    //   del = trtol*3e-6 / (0.5*5e5)                  = 8.4e-11
    try testing.expectApproxEqRel(@as(f64, trtol * 3e-6 / 2.5e5), del_state, 1e-12);
    try testing.expect(del_state < dt);
    // The summed row: dd == 0, so the bound collapses to trtol*tol/abstol.
    try testing.expect(del_row > 1e6 * dt);

    // The ground-mirror entries are INERT, which is why the tape needs no
    // trash-row mask. ngspice terrs one state per instance (captrunc.c:
    // `CKTterr(here->CAPqcap)`, capdefs.h: CAPnumStates = 2 for q AND its
    // current, i.e. ONE charge); the tape carries q on one terminal and -q on
    // the other, and the old per-row path never saw the ground side at all
    // because stepBound walks q_hist[0..n], excluding the trash cell q_vec[n].
    // Every CKTterr term is even in q — |q|, |dd|, |i| — so the mirror scores
    // identically and cannot move the min. Masking it would be work for zero
    // numerical effect; this assert is what says so.
    const one_sided = [_]f64{ 3e-12, 0 };
    const one_sided_p = [_]f64{ 1e-12, 0 };
    const mirrored = [_]f64{ 3e-12, -3e-12 };
    const mirrored_p = [_]f64{ 1e-12, -1e-12 };
    const pair_zero = [_]f64{ 0, 0 };
    const del_one = integrator.stepBound(
        .backward_euler, &one_sided, &one_sided_p, &pair_zero, &pair_zero, &pair_zero,
        1.0 / dt, false, dt, dt, dt, reltol, abstol, chgtol, trtol,
    );
    const del_mirror = integrator.stepBound(
        .backward_euler, &mirrored, &mirrored_p, &pair_zero, &pair_zero, &pair_zero,
        1.0 / dt, false, dt, dt, dt, reltol, abstol, chgtol, trtol,
    );
    try testing.expectEqual(del_one, del_mirror);

    // CKTterr is HOMOGENEOUS OF DEGREE ZERO in the charge: tol scales with |q|
    // (both volttol and chargetol) and so does |dd|, so `del` does not depend on
    // how big the contribution is — only on its RELATIVE curvature. Away from
    // the abstol/chgtol floors, scaling a state by 1000 leaves its bound put.
    //
    // This is the whole reason per-state LTE is not simply "more conservative":
    // a contribution 1000x smaller than its row-mates is still a full-strength
    // truncation candidate once it is its own state. It is what ngspice does
    // too — and it is exactly why devices/kinduc regressed, since espice gives
    // a K card its own charge states where ngspice folds the mutual flux into
    // the inductor's single INDflux (indload.c:70-77, and MUT has no MUTtrunc).
    const big: [2]f64 = .{ s_cur[0] * 1e3, 0 };
    const big_p: [2]f64 = .{ s_prev[0] * 1e3, 0 };
    const del_big = integrator.stepBound(
        .backward_euler, &big, &big_p, &pair_zero, &pair_zero, &pair_zero,
        1.0 / dt, false, dt, dt, dt, reltol, abstol, chgtol, trtol,
    );
    try testing.expectApproxEqRel(del_one, del_big, 1e-9);
}

// The plumbing invariant: every charge the devices stamped is in the tape
// exactly once, and it is stamped PER INSTANCE, not merged onto the node.
// Catches a missing scatterQ write, a double write, a stale dedup replay and a
// ParEval lane overlap — the failure modes that are otherwise silent.
test "q tape: per-device-state charges, one entry each, summing to the q plane" {
    const gpa = testing.allocator;
    const dev = @import("devices");
    const Cap = dev.models.capacitor;
    const Proto = dev.batch.Proto;

    // The txl2_3_line shape: a big load cap and a small parasitic sharing
    // node 1. Per-row LTE differences their SUM; per-state keeps them apart.
    const CStore = dev.batch.ProtoStore(Cap);
    const cstore = try gpa.create(CStore);
    cstore.* = .{};
    try cstore.append(.{ .c = 7.398e-15 }, .{}, .{ 1, 0 }); // load cap, node 1 -> ground
    try cstore.append(.{ .c = 5.0e-17 }, .{}, .{ 1, 2 }); // parasitic, node 1 -> node 2

    const protos = [_]Proto{.{
        .ctx = cstore,
        .type_name = @typeName(Cap),
        .pattern = CStore.addPattern,
        .finalize = CStore.finalize,
        .destroy = CStore.destroy,
        .apply_perm = CStore.applyPerm,
    }};

    const intern_bytes = try gpa.dupe(u8, "000");
    const intern_offs = try gpa.alloc(u32, 4);
    for (intern_offs, 0..) |*o, i| o.* = @intCast(i);
    var ckt = try root.freeze(gpa, 3, intern_bytes, intern_offs, &protos, null);
    defer ckt.deinit();

    // 2 instances * 2 unknowns. Per NODE there would be 3 rows; per STATE there
    // are 4 contributions, and node 1 carries two of them.
    try testing.expectEqual(@as(u32, 4), ckt.qTapeLen());

    const x = [_]f64{ 0.0, 1.0, 0.25 };
    ckt.eval(&x, 0);

    const tape = try gpa.alloc(f64, ckt.qTapeLen());
    defer gpa.free(tape);
    ckt.snapshotQTape(tape);

    // Indexed id*n_u + ru, exactly like rhs_idx.
    try testing.expectApproxEqRel(@as(f64, 7.398e-15 * 1.00), tape[0], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -7.398e-15 * 1.00), tape[1], 1e-9);
    try testing.expectApproxEqRel(@as(f64, 5.0e-17 * 0.75), tape[2], 1e-9);
    try testing.expectApproxEqRel(@as(f64, -5.0e-17 * 0.75), tape[3], 1e-9);

    // Every contribution lands in exactly one q_vec cell (the ground terminal
    // in the trash row q_vec[n]), so the two totals are the same number.
    var sum_tape: f64 = 0;
    for (tape) |v| sum_tape += v;
    var sum_plane: f64 = 0;
    for (ckt.q_vec) |v| sum_plane += v;
    try testing.expectApproxEqAbs(sum_plane, sum_tape, 1e-30);

    // And the merge the old controller had to live with: node 1's row is the
    // sum, whose slope is neither cap's.
    try testing.expectApproxEqRel(
        @as(f64, 7.398e-15 * 1.00 + 5.0e-17 * 0.75),
        ckt.q_vec[1],
        1e-9,
    );
}

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
    try vstore.append(.{
        .waveform = 1,
        .pulse_v1 = 0.0,
        .pulse_v2 = 5.0,
        .pulse_td = 2e-9,
        .pulse_tr = 1e-12,
        .pulse_tf = 1e-12,
        .pulse_pw = 4e-9,
        .pulse_per = 20e-9,
    }, .{}, .{ 1, 0, 2 });

    const RStore = dev.batch.ProtoStore(Res);
    const rstore = try gpa.create(RStore);
    rstore.* = .{};
    try rstore.append(.{ .r = 1000.0 }, .{}, .{ 1, 0 });

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
