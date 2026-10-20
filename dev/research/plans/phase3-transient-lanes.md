# Phase 3 plan: transient lanes (#207)

Implementation-ready plan for the CPU transient lane path. It is also the host
side of the GPU backend (phase 4). Written against main 06cff37f. Nothing here
was built or run: every anchor was read in the tree, and the spots that only a
build can settle are marked **CHECK**.

Design sources: `dev/research/lane-batched-simulation.md` §6 (`.tran` row), §7
(rounds, early stop, measures), §11 (phase 3 gate); issue #207.

## 0. Summary

- **One transient, two drivers.** `tran.zig`'s `simulateWith` becomes a pinned
  step machine, `Sim`. Its fields are today's locals, moved verbatim, plus three
  methods:
  - `begin()` runs everything before Newton;
  - `end(attempt, nr)` runs every step-end decision;
  - `finish()` runs everything after the loop.

  The scalar driver (`Sim.drive`) is today's loop with Newton through
  `converger.run`. The lane driver (`tran.runLanes`) runs **rounds**: every live
  lane `begin`s its own attempt at its own (t, dt), one `converger.newtonLanes`
  solves all of them, and every lane `end`s with its own Newton result.
  `dc.zig`'s `Sweep`/`run`/`runLanes` split is the precedent, and this copies it.
- **No decision is shared.** Every step-control decision (Newton reject,
  `reject_at`, the state-flip query, LTE, promotion, breakpoint landing, clamps,
  early stop) runs in `end` on the lane's own `Sim` and its own `Circuit`. So
  each lane's `SimState`, breakpoints, measures and stream are its own for free:
  the CPU deinterleave path (§4) keeps one `Circuit` per lane.
- **Bitwise by construction.** Lane l executes exactly the scalar statements in
  the scalar order. The only substitution is `newtonLanes(W)` lane l for
  `newton(1)`, which phase 1 made bitwise. That holds through `LaneSystem`,
  which now carries **per-lane hooks**, because a transient lane's hook (its
  coefficients and charge-history slices) differs per lane.
- **Executor and session.** `Executor.executeBatch` gains a `.tran` branch.
  `Session.gather` and `sameLaneJob` admit `.tran`. Lanes stay OFF by default on
  the CPU (`executor.lanesOn`, #211).
- **Not in phase 3** (deferred, as §7 and §11 allow):
  - refill (regrouping), until idle is measured above 10%;
  - `.four`, `.fft`, OPtran (`op.zig:334`) and `tran_noise` lanes. They keep
    calling scalar `simulate`.
  - The GPU-facing split of `end` into *probe → decide → apply* is phase 4's
    first step (phase4 plan, step G1). Doing it here would add a second
    restructuring to the bitwise gate before the oracle exists.

## 1. Design details

### 1.1 Round

```
live = lanes whose Run.init succeeded
loop:
  round = {}
  for l in live:  a_l = runs[l].sim.begin()      # checkpoint, SimState, coeffs, hook, predictor, limiting
                  null -> finish, take, publish, drop l
                  else round += l, hooks[l] = a_l.hook, xv[:,l] = trial_l, t[l] = t_dev_l
  if round == {}: break
  sys.active = round
  newtonLanes(W, sys, lws, xv, t, nr_opts, LaneHook)   # masks: lanes freeze as they converge
  for l in round: lane l's clearLimits()               # converger.run's defer
  for l in round: trial_l = xv[:,l]; nr_l = (converged_l, iterations_l) or (false, 0) when singular
                  end(a_l, nr_l): .go | .stop -> finish | .underflow -> TimestepTooSmall
```

- `nr_opts` is lane-uniform: `optionsFromTolerances(tol, tol.itl4)` with
  `residual_tol = inf`. Lanes are grouped only when their options differ at most
  in `tol.variant` and `tol.temp_c` (`stripTol`), and neither field enters
  `optionsFromTolerances`.
- A lane's Newton error maps exactly as the scalar `catch` does:
  - `QueryCancelled` and `OutOfMemory` fail the batch (`newtonLanes` errors);
  - a singular lane gets `{ .converged = false, .iterations = 0 }`;
  - an unconverged lane gets `iterations = max_iter`, from both `newton` and
    `LaneResult`.
- The fallback runs every lane's scalar `run`, as `dc.runLanes` does, when:
  - `W == 1`, or the batch has one lane;
  - a JFNK pin is set, or `-Dcertify` is on;
  - the lanes carry VPI (`ckt.vpi != null`), because a VPI application is called
    in step order and lanes would interleave its calls.

### 1.2 Why rounds are exact here

`newtonLanes` already lets each lane leave `active` on its own convergence or
singularity (class B). A lane that is not in `round` is never evaluated:
`LaneHook.assemble`, `loadCheck`, `applyLimits`, `checkConvergence` and
`updateStates` all walk `sys.active` or a submask of it. `beginSolve` is made
active-only (edit 2.1), and `clearLimits` is called per round lane by the
driver. So a lane that finished, or failed earlier, sees no device call.

`Circuit.updateStates` under `land_rejects` runs `acceptStates`, which leaves
`q_fresh` and `reject_at` on the lane's own circuit. `end` reads them straight
after its own Newton, as the scalar code does, because no other lane writes that
circuit.

### 1.3 Per-lane SimState, breakpoints, measures

These are free on the CPU: `Sim` holds `ckt: *Circuit` (the lane's own), and
`begin` calls `ckt.setSimState` before anything evaluates it. Breakpoints come
from the lane's own batches (`nextBreakpoint`), and `.meas` streaming
(`measure.Stream`) and early stop live in the lane's own `Run`. A lane that
resolves its cards returns `.stop`, finishes, and leaves `live`. The others go
on.

### 1.4 GPU-facing choices made here

- Lane l's per-attempt inputs are one value: `Attempt` (t_dev, method, `Coeffs`,
  hook, `dts`, `ag`). Phase 4 uploads exactly these per lane per round (§5.1:
  "N x 5 f64 up").
- Its outputs are one `converger.Result` per lane. Phase 4 downloads the same
  shape per lane.
- `Sim` keeps all control in scalars, so phase 4 can reuse `begin` and the
  decision half of `end` on the host unchanged (phase4 plan G1).

## 2. Code changes, in dependency order

### 2.1 `src/solver/lane_system.zig`: per-lane hooks, active-only `beginSolve`

Anchor `LaneSystem` fields, line ~32 `hook: Hook,`. Replace:

```zig
        /// Lane l's own system, borrowed; all on one pattern.
        lanes: [W]*Sys,
        /// Lane l's hook. A transient lane assembles under its own
        /// coefficients and charge history; a static solve's hook is the
        /// same for every lane.
        hooks: [W]Hook,
```

`init` (line ~51): the signature stays `init(gpa, lanes, hook: Hook)`, so
`op.solveLanes`, `dc.runLanes` and the tests keep passing `.{}`. Change the
struct literal's `.hook = hook,` to:

```zig
                .hooks = @splat(hook),
```

(`hook.vals(s0).len` above it stays: it sizes `vals` from the hook given.)

`LaneHook.assemble` (line ~88). Replace the loop body:

```zig
            pub fn assemble(_: LaneHook, sys: *Self, x: []const V, t: V) void {
                var it = L.each(sys.active);
                while (it.next()) |l| {
                    const s = sys.lanes[l];
                    getLane(sys.xs, x, l);
                    sys.hooks[l].assemble(s, sys.xs, L.lane(t, l));
                    putLane(sys.vals, sys.hooks[l].vals(s), l);
                    putLane(sys.rhs, s.rhs, l);
                }
            }
```

`beginSolve` (line ~105):

```zig
        /// Starts each active lane's solve; a lane outside `active` (a
        /// finished transient lane, a padding copy) is not touched.
        pub fn beginSolve(self: *Self) void {
            if (comptime !@hasDecl(Sys, "beginSolve")) return;
            var it = L.each(self.active);
            while (it.next()) |l| self.lanes[l].beginSolve();
        }
```

`loadCheck` (line ~143): `const lv = self.hook.vals(s)[0..self.nnz];` becomes

```zig
                const lv = self.hooks[l].vals(s)[0..self.nnz];
```

Why `beginSolve` is safe for the existing callers:
- `op.solveLanes`: the inactive lanes are padding copies of lane 0, which is
  active.
- `dc.runLanes`: a lane outside `warm` runs its own scalar ladder next, which
  calls `beginSolve` itself.

The phase 2 corpus diff (§4.4, `op`/`dc` kinds) re-checks this.

**CHECK.** `@splat` into `[W]Hook` needs the result type, and the field type
gives it. If the compiler refuses `@splat` for a zero-size `EvalHook`, use
`.hooks = [_]Hook{hook} ** W`.

### 2.2 `src/analysis/tran/tran.zig`: `Sim`, `Attempt`, `Verdict`, `drive`

Replace `simulateWith` (lines 291-956, from its doc comment `/// \`simulate\`,
also advancing ...` through the closing `}` before `fn ring`) with the code
below. `simulate` (lines 271-289) is unchanged and still calls `simulateWith`.

The statement order inside `init`, `begin`, `end` and `finish` is exactly
today's. Mutated locals became `s.` fields, and the ring slices are re-sliced
from the fields on each call (`qHist`, `qtHist`, ...), so `std.mem.rotate` and
`std.mem.swap` still permute the arrays the hook slices index.

```zig
/// `simulate`, also advancing and recording `tangents` at the operating
/// point and every accepted step, and feeding each recorded row to `stream`
/// for `options.point`'s early stop (returns true once every card has
/// resolved, the tangent rows' too) and abort bound
/// (`error.MeasureBoundExceeded` at the first row past it with a card
/// unresolved).
fn simulateWith(
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    waveform: *Waveform,
    options: Options,
    allocator: std.mem.Allocator,
    tangents: ?*Tangents,
    stream: ?*Stream,
) !bool {
    var s: Sim = undefined;
    try s.init(ckt, x, probes, waveform, options, allocator, tangents, stream);
    defer s.deinit();
    return s.drive();
}

/// What one attempt asks of Newton: `trial` from the predictor, solved at
/// `t_dev` under `hook` with `nr_opts`. `dts`, `ag` and `c` are the step's
/// own history and coefficients, which `end` reads again.
const Attempt = struct {
    t_dev: f64,
    method: Method,
    gear_hi: bool,
    dts: [7]f64,
    ag: [7]f64,
    c: integrator.Coeffs,
    hook: TranHook,
    nr_opts: converger.Options,
};

/// How `Sim.end` left the run: `.go` attempts again (a retry or the next
/// step), `.stop` ends it early with every card resolved, `.underflow` ends
/// it short of t_stop (dt below `dt_min`, or the VPI retry bound).
const Verdict = enum { go, stop, underflow };

/// One transient between its attempts: `simulateWith`'s state, so the
/// scalar driver (`drive`) and the lane driver (`runLanes`) share every
/// statement but the Newton solve. Pinned: `init` fills it in place.
/// `begin` prepares an attempt, the caller solves it, `end` takes the
/// verdict, and `finish` closes a run that left `begin`'s loop.
/// dev/research/lane-batched-simulation.md §7.
const Sim = struct {
    ckt: *root.Circuit,
    x: []f64,
    probes: []const u32,
    waveform: *Waveform,
    options: Options,
    allocator: std.mem.Allocator,
    tangents: ?*Tangents,
    stream: ?*Stream,
    ws: *converger.Workspace,
    n: usize,
    has_charge: bool,
    x_try: []f64,
    x_prev: []f64,
    top_order: u8,
    n_hist: usize,
    a_vals: []f64,
    row_state: []f64,
    i_prev: []f64,
    q_ring: [9][]f64,
    g_row: []f64,
    n_qt: usize,
    lte_rows: []u32,
    lte_zero: [][2]u32,
    lte_state: []f64,
    qt_i_prev: []f64,
    qt_ring: [9][]f64,
    qt_g: []f64,
    effective_dt_max: f64,
    delmin: f64,
    min_break: f64,
    state_eps: f64,
    echo_bps: [256]f64,
    n_echo: usize,
    echo_td: ?f64,
    uic_bp: ?f64,
    vpi: ?*const @import("device").Library.Vpi,
    vpi_point: @import("device").Library.AnalogPoint,
    cur: []f64,
    trial: []f64,
    prev: []f64,
    t: f64,
    dt: f64,
    dt_old: [6]f64,
    steps: u32,
    stats_on: bool,
    st: Stats,
    order: u8,
    run_order: u8,
    order_run: u32,
    bp_next: ?f64,
    bp_clamped: bool,
    bp_save_dt: f64,
    attempted_dt: f64,
    vpi_again: u32,
    resolved: bool,

    fn qHist(s: *Sim) [][]f64 {
        return s.q_ring[0..s.n_hist];
    }
    fn qtHist(s: *Sim) [][]f64 {
        return s.qt_ring[0..s.n_hist];
    }
    /// The LTE history: per state when the tape is live, per row otherwise.
    /// Same kernel either way, so the row path is the scalar oracle for the
    /// tape path. The slice is the ring, so it follows the rotation.
    fn lteHist(s: *Sim) [][]f64 {
        return if (s.n_qt > 0) s.qtHist() else s.qHist();
    }
    fn lteIp(s: *const Sim) []const f64 {
        return if (s.n_qt > 0) s.qt_i_prev else s.i_prev;
    }
    fn lteG(s: *const Sim) []const f64 {
        return if (s.n_qt > 0) s.qt_g else s.g_row;
    }

    /// Everything `simulateWith` did before its step loop, in its order:
    /// scratch, the charge rings, uic bookkeeping, the baseline, history
    /// seeding, the tangents' operating point, delay-line seeding, the
    /// breakpoint and VPI setup, and the t = 0 row. Leaves the device state
    /// committed at t = 0 and `land_rejects` set; `deinit` clears it.
    fn init(
        s: *Sim,
        ckt: *root.Circuit,
        x: []f64,
        probes: []const u32,
        waveform: *Waveform,
        options: Options,
        allocator: std.mem.Allocator,
        tangents: ?*Tangents,
        stream: ?*Stream,
    ) !void {
        const n: usize = ckt.n;
        const has_charge = ckt.has_charge;

        const ws = try ckt.workspace();
        // A device's `request_reject_at` retries the step ending at that time.
        ckt.land_rejects = true;
        errdefer ckt.land_rejects = false;
        const x_try = try allocator.alloc(f64, n);
        errdefer allocator.free(x_try);
        // The accepted point before `cur`, for the predictor. Equal to `cur`
        // until the first step is accepted, so that step starts from the OP.
        const x_prev = try allocator.alloc(f64, n);
        errdefer allocator.free(x_prev);
        num.copySimd(x_prev, x);

        // Row-plane charge state, one block: the dynamic current, then the
        // charge ring [cur, prev, prev2, ...]. Slot 0 takes the charge of each
        // converged attempt; the companion residual reads slots 1 and 2. The LTE
        // at order k reads k + 2 slots, so the ring holds max(4, top + 2), and
        // a gear-3..6 run keeps its step's `gearHistory` g in one more part.
        const top_order = integrator.order(options.method);
        const n_hist: usize = @max(4, top_order + 2);
        const n_parts: usize = 1 + n_hist + @intFromBool(top_order >= 3);
        const row_state = try allocator.alloc(f64, if (has_charge) n_parts * n else 0);
        errdefer allocator.free(row_state);
        const q_ring = ring(row_state, n_parts);

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
        const n_qt: usize = if (has_charge and !ckt.knobs.no_qtape) ckt.qTapeLen() else 0;
        // Coupled inductors: ngspice truncates one state per inductor, INDflux =
        // L*i + sum M*i_other (indload.c:72-76; MUT has no trunc routine). The
        // tape holds L*i and each M*i as separate states, which bind where
        // INDflux does not. With a K card, `lteSnap` zeroes the inductor and
        // kinduc tape spans (a flat zero history never binds) and appends the row
        // plane at every inductor current row, since an inductor's branch row
        // sums exactly its INDflux. Both are resolved here, once: `lte_zero`
        // holds the [offset, end) tape spans to clear.
        var lte_rows: []u32 = &.{};
        var lte_zero: [][2]u32 = &.{};
        errdefer allocator.free(lte_rows);
        errdefer allocator.free(lte_zero);
        if (n_qt > 0) for (ckt.batches) |kb| {
            if (!std.mem.eql(u8, kb.type_name, "kinduc")) continue;
            var rows: std.ArrayList(u32) = .empty;
            errdefer rows.deinit(allocator);
            const is_l = try allocator.alloc(bool, n);
            defer allocator.free(is_l);
            @memset(is_l, false);
            ckt.markCurrentRowsOf("inductor", is_l);
            for (is_l, 0..) |l, r| if (l) try rows.append(allocator, @intCast(r));
            lte_rows = try rows.toOwnedSlice(allocator);
            var spans: std.ArrayList([2]u32) = .empty;
            errdefer spans.deinit(allocator);
            var off: u32 = 0;
            for (ckt.batches) |b| {
                const f = b.hooks.q_tape orelse continue;
                const end_ = off + @as(u32, @intCast(f(b.ctx).len));
                if (std.mem.eql(u8, b.type_name, "inductor") or std.mem.eql(u8, b.type_name, "kinduc"))
                    try spans.append(allocator, .{ off, end_ });
                off = end_;
            }
            lte_zero = try spans.toOwnedSlice(allocator);
            break;
        };
        const n_lt = n_qt + lte_rows.len;
        // The same layout over the n_lt LTE states.
        const lte_state = try allocator.alloc(f64, if (n_qt > 0) n_parts * n_lt else 0);
        errdefer allocator.free(lte_state);
        const qt_ring = ring(lte_state, n_parts);

        s.* = .{
            .ckt = ckt,
            .x = x,
            .probes = probes,
            .waveform = waveform,
            .options = options,
            .allocator = allocator,
            .tangents = tangents,
            .stream = stream,
            .ws = ws,
            .n = n,
            .has_charge = has_charge,
            .x_try = x_try,
            .x_prev = x_prev,
            .top_order = top_order,
            .n_hist = n_hist,
            .a_vals = &.{},
            .row_state = row_state,
            .i_prev = row_state[0 .. row_state.len / n_parts],
            .q_ring = q_ring,
            .g_row = q_ring[n_hist],
            .n_qt = n_qt,
            .lte_rows = lte_rows,
            .lte_zero = lte_zero,
            .lte_state = lte_state,
            .qt_i_prev = lte_state[0 .. lte_state.len / n_parts],
            .qt_ring = qt_ring,
            .qt_g = qt_ring[n_hist],
            // Set below, in `simulateWith`'s order.
            .effective_dt_max = undefined,
            .delmin = undefined,
            .min_break = undefined,
            .state_eps = undefined,
            .echo_bps = undefined,
            .n_echo = 0,
            .echo_td = null,
            .uic_bp = null,
            .vpi = null,
            .vpi_point = undefined,
            .cur = x,
            .trial = x_try,
            .prev = x_prev,
            .t = 0,
            .dt = undefined,
            .dt_old = undefined,
            .steps = 0,
            .stats_on = ckt.knobs.tran_stats,
            .st = .{},
            .order = 1,
            .run_order = 1,
            .order_run = 0,
            .bp_next = null,
            .bp_clamped = false,
            .bp_save_dt = options.t_stop / 50.0,
            .attempted_dt = undefined,
            .vpi_again = 0,
            .resolved = false,
        };
        const q_hist = s.qHist();
        const qt_hist = s.qtHist();

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
            s.a_vals = try ws.ensureAVals(ckt.nnz);
            num.zeroSimd(s.i_prev);
            num.zeroSimd(s.qt_i_prev);
            // No setSimState first: q_prev must be the charge the operating point
            // saw, so this eval runs in the static state op.solve left behind.
            ckt.eval(x, 0);
            // A flat q(0) history makes every divided difference vanish, so LTE
            // control runs from the first step.
            for (q_hist[1..]) |h| num.copySimd(h, ckt.q_vec[0..n]);
            if (n_qt > 0) {
                lteSnap(ckt, qt_hist[1], lte_zero, lte_rows);
                for (qt_hist[2..]) |h| num.copySimd(h, qt_hist[1]);
            }
        }
        // Still in the operating point's static state, as the seeding above.
        if (tangents) |tg| {
            std.debug.assert(!options.uic);
            try tg.advance(ckt, ws, s.a_vals, x, 0, null);
            try ckt.computeBaseline();
        }

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
        s.effective_dt_max = options.dt_max orelse (options.t_stop - options.t_start) / 50.0;
        if (ckt.minDelay()) |td_min| s.effective_dt_max = @min(s.effective_dt_max, td_min);
        // The analysis' own CKTminBreak: delmin = 1e-11*maxStep and minBreak =
        // 10*delmin (traninit.c:36, dctran.c:170). Breakpoints closer than this
        // to the current time or to each other merge (dctran.c:636,
        // cktsetbk.c:45). optran.c:419's 5e-5*tmax is the OP transient's rule and
        // would merge away ns-scale source corners.
        s.delmin = 1e-11 * s.effective_dt_max;
        s.min_break = 10.0 * s.delmin;
        // How sharply a device state flip must land before the step is accepted.
        // An espice Newton/FSM tolerance with no ngspice counterpart; the switch
        // fixtures are tuned against it, so it is not min_break.
        s.state_eps = 5e-5 * s.effective_dt_max;

        // Delayed breakpoint echoes, standing in for ngspice traload's t + td
        // breakpoint on a sharp line input: every landed breakpoint re-emits one
        // echo at t + td, and echo landings re-emit in turn (t + 2td, 3td, ...).
        // ponytail: one td (the circuit's minimum delay) for every history
        // device; enumerate per-device delays if mixed-td circuits show edge smear.
        s.echo_td = ckt.minDelay();
        if (s.echo_td) |td_| {
            // t = 0 is itself a breakpoint (source edges often start there).
            s.echo_bps[0] = td_;
            s.n_echo = 1;
        }
        // Under uic ngspice sets a breakpoint at tstep "to reduce ringing of
        // current in devices" (dctran.c:582-584), after sizing the first step,
        // so landing there drops the order once (#166). Past t_stop it is never
        // reached, as CKTsetBreak inserts nothing past CKTfinalTime.
        s.uic_bp = if (options.uic) options.dt_init else null;

        // LRM 12.31.3 sees the transient proper, not the OPtran fallback.
        s.vpi = if (options.sources_at_zero) null else ckt.vpi;
        s.vpi_point = .{ .kind = .tran, .start = options.t_start, .stop = options.t_stop, .max_step = s.effective_dt_max };
        if (s.vpi) |v| v.point(v.ctx, s.vpi_point);

        // tstart suppresses output, never the solve: [0, t_start) is integrated
        // with full history and not recorded.
        if (options.t_start <= 0) {
            const x0 = try uicStart(ckt, ws, x, x_try, .{
                .method = .backward_euler,
                .c = integrator.coeffs(.backward_euler, s.delmin, s.delmin, options.xmu),
                .q_prev = q_hist[1],
                .i_prev = s.i_prev,
                .q_prev2 = q_hist[2],
                .a_vals = s.a_vals,
                .q_cur = {},
                .has_charge = has_charge,
            }, options);
            try waveform.record(0, x0, probes);
            if (stream) |sm| sm.feed(0, x0, waveform.data());
        }
        if (s.vpi) |v| v.accept(v.ctx, true, false);
        if (tangents) |tg| if (options.t_start <= 0) try tg.record(0, probes);

        // ngspice's first step: min(tstep, tstop/100)/10 clamped to tmax outside
        // the min (dctran.c:134), then the t = 0 breakpoint clamp 0.1*breaks[1]
        // (dctran.c:578-586), then the firsttime /10. The operand order sets the
        // phase of the whole accepted grid.
        var dt: f64 = @min(@min(options.dt_init, options.t_stop / 100.0) / 10.0, s.effective_dt_max);
        if (nextBp(ckt, s.echo_bps[0..s.n_echo], null, s.min_break)) |bp0| dt = @min(dt, 0.1 * bp0);
        dt /= 10.0;
        if (options.t_start > 0 and dt > options.t_start) dt = options.t_start;
        s.dt = dt;
        // The accepted steps [dt_prev, dt_prev2, ...], newest first. CKTdeltaOld[]
        // starts at CKTmaxStep (dctran.c:312), which the first divided
        // differences read.
        s.dt_old = @splat(s.effective_dt_max);
        s.attempted_dt = dt;
    }

    /// Frees the scratch `init` allocated and clears `land_rejects`.
    fn deinit(s: *Sim) void {
        const a = s.allocator;
        a.free(s.lte_state);
        a.free(s.lte_zero);
        a.free(s.lte_rows);
        a.free(s.row_state);
        a.free(s.x_prev);
        a.free(s.x_try);
        s.ckt.land_rejects = false;
        s.* = undefined;
    }

    /// The scalar loop: each attempt's Newton through `converger.run`, a
    /// numerical failure retrying the step. Returns `finish`'s value, or
    /// false when the run ended short of t_stop.
    fn drive(s: *Sim) !bool {
        while (try s.begin()) |a| {
            const nr = converger.run(s.ckt, s.ws, s.trial, a.t_dev, a.nr_opts, a.hook) catch |err| switch (err) {
                error.QueryCancelled, error.OutOfMemory => return err,
                else => converger.Result{ .converged = false, .iterations = 0 }, // else: a numerical failure retries the step
            };
            switch (try s.end(&a, nr)) {
                .go => {},
                .stop => break,
                .underflow => return false,
            }
        }
        return s.finish();
    }

    /// The step loop's head: null once the run has reached t_stop or
    /// `max_steps`, else the next attempt, with `trial` predicted and
    /// limited and the device state published for it.
    fn begin(s: *Sim) !?Attempt {
        const options = s.options;
        if (!(s.t < options.t_stop and !atStop(s.t, options.t_stop) and s.steps < options.max_steps)) return null;
        const ckt = s.ckt;
        if (s.st.attempts != 0) try ckt.checkpoint(.{
            .phase = .transient,
            .completed = s.st.attempts,
            .simulation_time = s.t,
            .step_size = s.attempted_dt,
            .next_step = s.dt,
            .accepted = s.steps,
        });
        s.attempted_dt = s.dt;
        const t = s.t;
        const dt = s.dt;
        // The time the devices evaluate at; OPtran holds it at 0.
        const t_dev = if (options.sources_at_zero) 0 else t + dt;
        // Publish the point this attempt aims at before anything evaluates
        // it: generated devices read Instance.abstime (§9.10 `$abstime`,
        // `ddt`), not the `t` argument. A rejected step comes back here with
        // the shrunken dt, so the last write before an accept is the accepted
        // dt. §5.10.2: initial_step is the analysis' first step, final_step
        // the one that lands on t_stop.
        ckt.setSimState(.{
            .t = t_dev,
            .dt = dt,
            .kind = .tran,
            .initial_step = s.steps == 0,
            .final_step = t + dt >= options.t_stop,
        });
        if (s.vpi) |v| {
            var p = s.vpi_point;
            p.t = t + dt;
            p.dt = dt;
            v.point(v.ctx, p);
        }
        const q_hist = s.qHist();
        const eff_method = methodAt(options.method, s.order);
        // Gear-3..6 solves its coefficients from the whole step history
        // and folds the older charges into g once per attempt.
        const gear_hi = s.order >= 3;
        var a: Attempt = .{
            .t_dev = t_dev,
            .method = eff_method,
            .gear_hi = gear_hi,
            .dts = [1]f64{dt} ++ s.dt_old,
            .ag = undefined,
            .c = undefined,
            .hook = undefined,
            .nr_opts = undefined,
        };
        a.c = if (gear_hi) blk: {
            a.ag = integrator.gearAg(s.order, &a.dts);
            integrator.gearHistory(s.g_row, q_hist[0 .. s.order + 1], a.ag);
            break :blk .{ .ag0 = a.ag[0], .ag2 = 0 };
        } else integrator.coeffs(eff_method, dt, s.dt_old[0], options.xmu);
        a.hook = .{
            .method = eff_method,
            .c = a.c,
            .q_prev = q_hist[1],
            .i_prev = s.i_prev,
            .q_prev2 = if (gear_hi) s.g_row else q_hist[2],
            .q_cur = {},
            .a_vals = s.a_vals,
            .has_charge = s.has_charge,
        };

        // MODEINITPRED (dctran.c:794, DEVpred in dioload.c/mos1load.c): the
        // first iterate extrapolates the last two accepted points by
        // dt/dt_prev and is limited against the last accepted one. HFET and
        // MESA divide by the step two back instead (CKTdeltaOld[2]).
        const xfact = dt / s.dt_old[0];
        predict(s.trial, s.cur, s.prev, xfact);
        ckt.predictFirstIterate(s.trial, s.cur, s.prev, dt / s.dt_old[1]);
        ckt.evalFollowsFirst(s.trial, t_dev);
        _ = ckt.applyLimits(s.trial, s.cur);
        // ngspice's transient Newton accepts on the per-row delta test alone
        // (niconv.c): a step that has converged in x but leaves a residual on
        // a row, e.g. a Meyer gate cap's curvature at a source-driven node,
        // is not iterated again.
        a.nr_opts = converger.optionsFromTolerances(options.tol, options.tol.itl4);
        a.nr_opts.residual_tol = std.math.inf(f64);
        ckt.reject_at = null;
        return a;
    }

    /// The step loop's body after Newton: rejects (Newton, a device's
    /// `reject_at`, a state flip, the LTE, VPI) shrink `dt` and return
    /// `.go`; an accepted step promotes or keeps the order, advances the
    /// histories, commits, lands breakpoints, records and streams, and sets
    /// the next dt.
    fn end(s: *Sim, a: *const Attempt, nr: converger.Result) !Verdict {
        const ckt = s.ckt;
        const options = s.options;
        const n = s.n;
        const has_charge = s.has_charge;
        const q_hist = s.qHist();
        const qt_hist = s.qtHist();
        const lte_hist = s.lteHist();
        const lte_ip = s.lteIp();
        const lte_g = s.lteG();
        const t = s.t;
        const dt = s.dt;
        const t_dev = a.t_dev;
        const eff_method = a.method;
        const cf = a.c;
        const gear_hi = a.gear_hi;
        s.st.attempts += 1;
        s.st.nr_iters += nr.iterations;

        if (!nr.converged) {
            s.st.rej_newton += 1;
            // Restore FSM devices to the last accepted state.
            _ = ckt.stateCtl(.revert);
            // Cut dt by 8 and drop to order 1 in one retry (dctran.c:815, :823).
            if (s.order > 1) s.st.order_drops += 1;
            s.order = 1;
            s.dt = dt / 8.0;
            if (s.dt < options.dt_min) {
                // The stats block in `finish` is skipped by this return.
                if (s.stats_on) std.debug.print(
                    "tran-stats: DT UNDERFLOW (newton) at t={e:.6} dt={e:.3} accepted={d} attempts={d} nr_iters={d}\n",
                    .{ t, s.dt, s.steps, s.st.attempts, s.st.nr_iters },
                );
                return .underflow;
            }
            return .go;
        }

        // A device located an event inside this step and asked for the step
        // to end on it (`request_reject_at`): retry landing there. A time
        // within state_eps of the step's end counts as the end, the
        // resolution the flip query below keeps too.
        if (ckt.reject_at) |tr| if (tr > t and t + dt - tr > s.state_eps and tr - t >= options.dt_min) {
            s.st.rej_state += 1;
            _ = ckt.stateCtl(.revert);
            s.dt = tr - t;
            return .go;
        };

        // A device state flipped inside this step (a switch crossed its
        // threshold): reject and shrink so the conductance step lands within
        // state_eps of the crossing instead of smeared across dt.
        if (has_charge and !ckt.q_fresh) ckt.evalFollows(s.trial, t_dev, true);
        if (dt > s.state_eps and ckt.stateCtl(.query)) {
            s.st.rej_state += 1;
            _ = ckt.stateCtl(.revert);
            s.order = 1;
            s.dt = @max(0.25 * dt, s.state_eps);
            return .go;
        }

        // The first accepted point skips CKTtrunc (dctran.c firsttime), so dt
        // repeats. §9.17.2 `$bound_step` is read after the step and applies
        // to the next one; devices only set it in `updateState`, so it cannot
        // be folded into effective_dt_max.
        var dt_next = if (s.steps == 0) dt else @min(dt * 2.0, s.effective_dt_max);
        if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);

        // CKTterr reads the charge of the published point. The converger
        // returns x_k+1 while the planes hold q(x_k) (or a JFNK matvec's x),
        // so re-read q at the solution: the LTE, advanceCurrent and the next
        // residual all see q(trial).
        // `q_fresh`: the converger's `updateStates` already stamped them.
        if (has_charge) {
            if (!ckt.q_fresh) ckt.evalQ(s.trial, t_dev);
            num.copySimd(q_hist[0], ckt.q_vec[0..n]);
            if (s.n_qt > 0) lteSnap(ckt, qt_hist[0], s.lte_zero, s.lte_rows);
            if (gear_hi and s.n_qt > 0) integrator.gearHistory(s.qt_g, qt_hist[0 .. s.order + 1], a.ag);
        }
        // Taken before the ring rotation below.
        const lq: [4][]const f64 = .{ lte_hist[0], lte_hist[1], lte_hist[2], lte_hist[3] };
        const lte: integrator.LteIn = .{
            .dt = dt,
            .dt1 = s.dt_old[0],
            .dt2 = s.dt_old[1],
            .reltol = options.tol.reltol,
            .abstol = options.tol.abstol,
            .chgtol = options.tol.chgtol,
            .trtol = options.tol.trtol,
        };
        // This step's own bound, read again by the gear order control.
        var del: f64 = undefined;
        if (has_charge and s.steps > 0) {
            del = if (gear_hi)
                integrator.stepBoundGear(eff_method, eff_method, lte_hist, lte_ip, lte_g, cf, lte, &a.dts)
            else
                integrator.stepBound(W, eff_method, eff_method, lq, lte_ip, cf, lte);
            if (!(del >= 0.9 * dt)) {
                s.st.rej_lte += 1;
                _ = ckt.stateCtl(.revert);
                // Retry at the LTE's dt and the same order (dctran.c:966
                // `CKTdelta = newdelta`); only a Newton failure drops the
                // order. del < 0.9*dt here, so every retry shrinks. A NaN
                // bound (a non-finite charge) retries as a Newton failure.
                if (std.math.isNan(del)) {
                    s.order = 1;
                    s.dt = dt / 8.0;
                } else s.dt = del;
                if (s.dt < options.dt_min) {
                    if (s.stats_on) std.debug.print(
                        "tran-stats: DT UNDERFLOW (lte) at t={e:.6} dt={e:.3} accepted={d} attempts={d} nr_iters={d}\n",
                        .{ t, s.dt, s.steps, s.st.attempts, s.st.nr_iters },
                    );
                    return .underflow;
                }
                return .go;
            }
            // Growth capped at 2x per accepted step, as in ngspice, and
            // lower at gear-3..6 (`maxGrowth`).
            dt_next = @min(@max(del, options.dt_min), integrator.maxGrowth(eff_method) * dt, s.effective_dt_max);
        }

        // LRM 12.31.3 acbConvergenceTest, last before acceptance: a rejection
        // (or 12.36 vpiRejectTransientStep) backs up to half the step from
        // the last accepted point, as VerA's own walk does; 12.36
        // vpiTransientFailConverge solves the same step again.
        if (s.vpi) |v| switch (v.verdict(v.ctx)) {
            .accept => s.vpi_again = 0,
            .reject => {
                s.st.rej_vpi += 1;
                _ = ckt.stateCtl(.revert);
                s.dt = dt / 2.0;
                if (s.dt < options.dt_min) return .underflow;
                return .go;
            },
            .again => {
                s.st.rej_vpi += 1;
                _ = ckt.stateCtl(.revert);
                s.vpi_again += 1;
                if (s.vpi_again == 60) return .underflow;
                return .go;
            },
        };

        // Accepted from here on; the history below is still this step's.
        if (s.tangents) |tg| {
            try tg.advance(ckt, s.ws, s.a_vals, s.trial, t_dev, .{ .method = eff_method, .c = cf, .q1 = q_hist[1], .q2 = q_hist[2], .i = s.i_prev });
            if (t + dt >= options.t_start) try tg.record(t + dt, s.probes);
        }

        if (has_charge) {
            // Order promotion (dctran.c:901-913): recompute the trunc at
            // order 2 and adopt min(2*dt, del2) as the next dt whether or not
            // the order changes, as ngspice's `CKTdelta = newdelta` does.
            s.st.by_order[s.order - 1] += 1;
            s.order_run = if (s.order == s.run_order) s.order_run + 1 else 1;
            s.run_order = s.order;
            if (s.steps > 0 and s.order == 1) {
                const trial_del = integrator.stepBound(W, methodAt(options.method, 2), eff_method, lq, lte_ip, cf, lte);
                // A NaN probe (prev3 non-finite) keeps BE and the step.
                if (!std.math.isNan(trial_del)) {
                    const nd2 = @min(2.0 * dt, trial_del);
                    if (nd2 > 1.05 * dt) s.order = 2;
                    dt_next = @min(@max(nd2, options.dt_min), s.effective_dt_max);
                    if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);
                }
            } else if (s.steps > 0 and s.top_order >= 3 and s.order_run > s.order) {
                // Gear-3..6 order control, an espice policy (dctran.c stops
                // at order 2): after order + 1 accepted steps at one order,
                // move one order up or down (not below 2) when that order's
                // CKTterr bound beats this one's by 5%, the margin of the
                // 1-to-2 promotion; the next step is then that bound under
                // the new order's `maxGrowth`.
                // ponytail: one order per change; DASSL-style selection on
                // error trends would move faster.
                var best = del;
                var best_order = s.order;
                for ([_]u8{ s.order + 1, s.order - 1 }) |k| {
                    if (k > s.top_order or k < 2) continue;
                    const d = integrator.stepBoundGear(methodAt(options.method, k), eff_method, lte_hist, lte_ip, lte_g, cf, lte, &a.dts);
                    if (d > 1.05 * best) {
                        best = d;
                        best_order = k;
                    }
                }
                if (best_order != s.order) {
                    s.order = best_order;
                    dt_next = @min(@max(best, options.dt_min), integrator.maxGrowth(methodAt(options.method, s.order)) * dt, s.effective_dt_max);
                    if (ckt.boundStep()) |bs| dt_next = @min(dt_next, bs);
                }
            }

            // The dynamic current under the method actually used. Both index
            // spaces run it: ngspice keeps it per state in
            // CKTstates[0][qcap+1], where CKTterr's volttol reads it.
            integrator.advanceCurrent(eff_method, s.i_prev, q_hist[0], q_hist[1], if (gear_hi) s.g_row else q_hist[2], cf);
            if (s.n_qt > 0)
                integrator.advanceCurrent(eff_method, s.qt_i_prev, qt_hist[0], qt_hist[1], if (gear_hi) s.qt_g else qt_hist[2], cf);

            // [cur, prev, prev2, ...] -> [stale, cur, prev, ...].
            std.mem.rotate([]f64, q_hist, s.n_hist - 1);
            if (s.n_qt > 0) std.mem.rotate([]f64, qt_hist, s.n_hist - 1);
        }
        std.mem.copyBackwards(f64, s.dt_old[1..], s.dt_old[0 .. s.dt_old.len - 1]);
        s.dt_old[0] = dt;

        // Rotate the slices; accepted states need no copy.
        const stale = s.prev;
        s.prev = s.cur;
        s.cur = s.trial;
        s.trial = stale;
        s.t = t + dt;
        s.steps += 1;
        const t_new = s.t;
        // §4.5.2 delay-line bookkeeping, once per accepted point
        // (`Hooks.commit_state`), then the commit that latches every stage.
        _ = ckt.commitStates(s.cur);
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
        if (s.bp_next) |bp| {
            const landed = if (s.bp_clamped)
                @abs(t_new - bp) <= s.min_break
            else
                (bp - t_new <= s.delmin or almostEqualUlps(t_new, bp, 100)) and
                    std.mem.indexOfScalar(f64, s.echo_bps[0..s.n_echo], bp) == null;
            if (landed) {
                s.st.bp_landings += 1;
                s.order = 1;
                // Re-emit one line delay later; dedupe within min_break and
                // drop when the table is full.
                if (s.echo_td) |td_| {
                    const e = t_new + td_;
                    if (e < options.t_stop and s.n_echo < s.echo_bps.len) {
                        var dup = false;
                        for (s.echo_bps[0..s.n_echo]) |old| {
                            if (@abs(old - e) <= s.min_break) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) {
                            s.echo_bps[s.n_echo] = e;
                            s.n_echo += 1;
                        }
                    }
                }
                var shrink = s.bp_save_dt;
                if (nextBp(ckt, s.echo_bps[0..s.n_echo], s.uic_bp, t_new + s.min_break)) |nb| shrink = @min(shrink, nb - t_new);
                dt_next = @min(dt_next, 0.1 * shrink);
            }
            s.bp_next = null;
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
            ckt.evalQ(s.cur, t_new);
            integrator.rebaseCurrent(s.i_prev, ckt.q_vec[0..n], q_hist[1], cf.ag0);
            num.copySimd(q_hist[1], ckt.q_vec[0..n]);
            if (s.n_qt > 0) {
                lteSnap(ckt, qt_hist[0], s.lte_zero, s.lte_rows);
                integrator.rebaseCurrent(s.qt_i_prev, qt_hist[0], qt_hist[1], cf.ag0);
                // Swap, not copy: slot 0 is the ring's scratch slot, and the
                // next accepted attempt overwrites it before any read.
                std.mem.swap([]f64, &qt_hist[0], &qt_hist[1]);
            }
        }

        // ngspice neither steps onto TSTART nor prints it: dctran.c dumps
        // the accepted points at t >= CKTinitTime and nothing else (#167).
        if (t_new >= options.t_start) try s.waveform.record(t_new, s.cur, s.probes);
        // Before the breakpoint search below, so a time a callback forces
        // from this point is landed on.
        if (s.vpi) |v| v.accept(v.ctx, false, t_new >= options.t_stop or atStop(t_new, options.t_stop));
        if (s.stream) |sm| if (t_new >= options.t_start) {
            sm.feed(t_new, s.cur, s.waveform.data());
            if (options.point.abort_after) |bound| if (t_new > bound and sm.unresolved()) return error.MeasureBoundExceeded;
            if (options.point.early_stop and sm.open == 0 and (s.tangents == null or s.tangents.?.open() == 0)) {
                s.resolved = true;
                return .stop;
            }
        };

        // Clamp dt to land on the next breakpoint, skipping those within
        // min_break of now (ngspice CKTminBreak merge).
        s.bp_next = nextBp(ckt, s.echo_bps[0..s.n_echo], s.uic_bp, t_new + s.min_break);
        s.bp_clamped = false;
        if (s.bp_next) |bp| {
            const dt_to_bp = bp - t_new;
            if (dt_to_bp < dt_next) {
                s.bp_save_dt = dt_next;
                dt_next = dt_to_bp;
                s.bp_clamped = true;
            }
        }

        s.dt = dt_next;
        if (t_new + s.dt > options.t_stop) s.dt = options.t_stop - t_new;
        return .go;
    }

    /// The step loop's tail: the last checkpoint, the stats line, `x`
    /// holding the last accepted solution. True on reaching t_stop or once
    /// every card resolved.
    fn finish(s: *Sim) !bool {
        const options = s.options;
        try s.ckt.checkpoint(.{
            .phase = .transient,
            .completed = s.st.attempts,
            .simulation_time = s.t,
            .step_size = s.attempted_dt,
            .next_step = if (s.t < options.t_stop) s.dt else 0,
            .accepted = s.steps,
        });
        if (s.stats_on) {
            const st = s.st;
            std.debug.print(
                "tran-stats: n_qt={d} accepted={d} attempts={d} nr_iters={d} rej[newton={d} lte={d} state={d} vpi={d}] order_drops={d} bp_landings={d} by_order={any} avg_dt={e:.3}\n",
                .{ s.n_qt, s.steps, st.attempts, st.nr_iters, st.rej_newton, st.rej_lte, st.rej_state, st.rej_vpi, st.order_drops, st.bp_landings, st.by_order, if (s.steps > 0) s.t / @as(f64, @floatFromInt(s.steps)) else 0 },
            );
        }
        if (s.cur.ptr != s.x.ptr) num.copySimd(s.x, s.cur);
        return s.resolved or s.t >= options.t_stop or atStop(s.t, options.t_stop);
    }
};

/// `lteSnap` and `nextBp`, hoisted out of `simulateWith` unchanged so
/// `Sim` can call them.
fn lteSnap(c: *root.Circuit, dst: []f64, zero: []const [2]u32, rows: []const u32) void {
    const n_tape = dst.len - rows.len;
    c.snapshotQTape(dst[0..n_tape]);
    for (zero) |span| @memset(dst[span[0]..span[1]], 0);
    for (rows, dst[n_tape..]) |r, *d| d.* = c.q_vec[r];
}

fn nextBp(c: *root.Circuit, echo: []const f64, extra: ?f64, after: f64) ?f64 {
    var best = std.math.inf(f64);
    if (c.nextBreakpoint(after)) |bp| best = bp;
    for (echo) |e| {
        if (e >= after and e < best) best = e;
    }
    if (extra) |e| {
        if (e >= after and e < best) best = e;
    }
    return if (best == std.math.inf(f64)) null else best;
}
```

Transcription notes, so a reviewer can check the diff against today's body:
- `end_` in the kinduc loop renames today's local `end`, which would shadow
  the method name inside `init`. **CHECK:** Zig refuses a local that shadows a
  container decl.
- Today's `t` and `dt` locals are mutated in place. In `end` they are read once
  into `t`/`dt` (the attempt's values), and every write goes to `s.t`/`s.dt`.
  Every read after a write uses `s.dt` or `t_new`, exactly where today's code
  read the updated local. Spot-check the three `s.dt = dt / 8.0` sites: today's
  code divides in place, so the printed value is the new dt in both versions.
- `std.mem.swap([]f64, &qt_hist[0], &qt_hist[1])` swaps `s.qt_ring`'s first two
  elements through the slice, as today's swap did through `qt_ring`'s slice.

### 2.3 `src/analysis/tran/tran.zig`: `Run`, `run`, `runLanes`

Replace `pub fn run` (lines 994-1109, from its doc comment) with the following.
The doc comment stays as it is, plus a sentence for `runLanes`.

```zig
/// Contract entry: ... (today's doc comment, unchanged)
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    var r: Run = undefined;
    try r.init(ctx, opts);
    defer r.deinit();
    return r.take(try r.sim.drive());
}

/// One `.tran` query's outputs around its `Sim`: the probes it records,
/// its `.meas` stream, waveform and tangents, so `run` and `runLanes`
/// build and publish each query the same way. Pinned: `init` fills it in
/// place, and `sim` points at `wf`, `stream` and `tangents`.
const Run = struct {
    ctx: *const root.RunCtx,
    opts: Options,
    x: []f64,
    kept: bool,
    streamed: bool,
    names: []const []const u8,
    own_probes: []u32,
    stream: ?Stream,
    wf: Waveform,
    tangents: ?Tangents,
    /// `take` handed `wf`'s rows to the result.
    published: bool = false,
    sim: Sim,

    /// `run`'s setup, then `Sim.init`.
    fn init(r: *Run, ctx: *const root.RunCtx, opts: Options) !void {
        const a = ctx.allocator;
        const scratch = ctx.scratch_allocator;
        const x_op = ctx.x_op;
        const x = try scratch.alloc(f64, x_op.len);
        errdefer scratch.free(x);
        num.copySimd(x, x_op);

        // The recording is the published result, so it lives in the results
        // arena and `data` is borrowed below. A `.op <time>` snapshot publishes
        // only x, and a streamed run writes its rows to `ctx.stream` as it goes,
        // so either keeps its recording in scratch and drops it here.
        const kept = !opts.snapshot and ctx.stream == null;
        const all_names = try root.probeNames(ctx, scale);
        var names = all_names;
        var probes = ctx.probes;
        var own_probes: []u32 = &.{};
        errdefer scratch.free(own_probes);
        const tran_cards = for (ctx.measures) |m| {
            if (m.analysis == .tran) break true;
        } else false;
        // Measured as the run goes, in place of their columns.
        const streamed = kept and opts.point.measures_only and opts.tangents.len == 0 and tran_cards;
        if (kept and opts.point.measures_only) {
            const keep = try scratch.alloc(bool, names.len);
            defer scratch.free(keep);
            measure.markColumns(ctx.measures, names, keep, streamed);
            const sub_names = try a.alloc([]const u8, std.mem.count(bool, keep, &.{true}));
            const sub_probes = try scratch.alloc(u32, sub_names.len - 1);
            var k: usize = 0;
            for (names, keep, 0..) |name, on, i| if (on) {
                sub_names[k] = name;
                if (k > 0) sub_probes[k - 1] = ctx.probes[i - 1];
                k += 1;
            };
            names = sub_names;
            probes = sub_probes;
            own_probes = sub_probes;
        }
        const watched = streamed or (kept and tran_cards and (opts.point.early_stop or opts.point.abort_after != null));
        var stream: ?Stream = if (watched) try .init(scratch, ctx.measures, all_names, ctx.probes, names) else null;
        errdefer if (stream) |*sm| sm.deinit();
        if (stream) |*sm| if (opts.point.abort_measure.len != 0) {
            sm.abort_card = for (ctx.measures, 0..) |m, k| {
                if (std.ascii.eqlIgnoreCase(m.name, opts.point.abort_measure)) break k;
            } else null;
        };
        const n_probes: u32 = @intCast(probes.len);
        var wf = if (kept)
            try Waveform.init(a, n_probes, initialCapacity(opts))
        else if (opts.snapshot)
            try Waveform.init(scratch, n_probes, initialCapacity(opts))
        else
            try Waveform.initStream(scratch, n_probes, ctx.stream.?);
        errdefer wf.deinit();
        var tangents = if (kept and opts.tangents.len != 0) try Tangents.init(ctx, opts, n_probes, scratch) else null;
        errdefer if (tangents) |*tg| tg.deinit(scratch);
        if (tangents) |*tg| if (watched and opts.point.early_stop) {
            const streams = try scratch.alloc(Stream, tg.wf.len);
            for (streams, 0..) |*sm, k| sm.* = Stream.init(scratch, ctx.measures, all_names, ctx.probes, names) catch |e| {
                for (streams[0..k]) |*done| done.deinit();
                scratch.free(streams);
                return e;
            };
            tg.streams = streams;
        };
        r.* = .{
            .ctx = ctx,
            .opts = opts,
            .x = x,
            .kept = kept,
            .streamed = streamed,
            .names = names,
            .own_probes = own_probes,
            .stream = stream,
            .wf = wf,
            .tangents = tangents,
            .sim = undefined,
        };
        try r.sim.init(ctx.circuit, x, probes, &r.wf, opts, scratch, if (r.tangents) |*tg| tg else null, if (r.stream) |*sm| sm else null);
    }

    /// Frees what `init` made, `wf` unless `take` published it.
    fn deinit(r: *Run) void {
        const scratch = r.ctx.scratch_allocator;
        r.sim.deinit();
        if (r.tangents) |*tg| tg.deinit(scratch);
        if (!r.published) r.wf.deinit();
        if (r.stream) |*sm| sm.deinit();
        scratch.free(r.own_probes);
        scratch.free(r.x);
        r.* = undefined;
    }

    /// The query's result from a run that ended with `sim_ok` (`Sim.drive`
    /// or `Sim.finish`): `run`'s tail.
    fn take(r: *Run, sim_ok: bool) !root.Result {
        const ctx = r.ctx;
        const a = ctx.allocator;
        const opts = r.opts;
        if (!sim_ok) return error.TimestepTooSmall;
        // HSPICE `.op <time>`: the state at t_stop, laid out as `.op` lays it out.
        if (opts.snapshot) {
            const op_names = try root.probeNames(ctx, null);
            const data = try a.alloc(f64, op_names.len);
            for (ctx.probes, data) |node, *out| out.* = r.x[node];
            return .{
                .plotname = try std.fmt.allocPrint(a, "Operating Point (time={e})", .{opts.t_stop}),
                .varnames = op_names,
                .is_complex = false,
                .npoints = 1,
                .data = data,
            };
        }
        const tg = if (r.tangents) |*tg| tg else {
            const res: root.Result = .{
                .plotname = plotname,
                .varnames = r.names,
                .is_complex = false,
                .npoints = r.wf.len,
                .data = r.wf.data(),
                .measured = if (r.streamed) try r.stream.?.measured(a) else &.{},
            };
            r.published = r.kept;
            return res;
        };
        // Each row's block on the base run's time points.
        const block = r.wf.data().len;
        const blocks = try a.alloc(f64, block * tg.wf.len);
        for (tg.wf, 0..) |w, k| @memcpy(blocks[k * block ..][0..block], w.data());
        r.published = r.kept;
        return .{
            .plotname = plotname,
            .varnames = r.names,
            .is_complex = false,
            .npoints = r.wf.len,
            .data = r.wf.data(),
            .tangents = blocks,
        };
    }
};

const LaneError = root.ErrorOf(run);
/// One lane's `run` outcome.
pub const LaneOutcome = LaneError!root.Result;

/// `run` for the lanes of one batch: `.tran` queries on one pattern, each
/// from its own operating point (or `uic` start) and variant row, in rounds
/// (dev/research/lane-batched-simulation.md §7). Each round every live lane
/// `begin`s an attempt at its own (t, dt), one `newtonLanes` solves them,
/// and each `end`s it with its own step control, so no decision couples
/// lanes and lane l's result lands in `out[l]` bitwise `run` on `ctxs[l]`.
/// A JFNK pin, `-Dcertify` or a VPI application runs every lane's `run`.
/// Asserts 1 <= `ctxs.len` <= `width`.
pub fn runLanes(comptime width: usize, ctxs: []const root.RunCtx, opts: Options, out: []LaneOutcome) void {
    const g = ctxs.len;
    std.debug.assert(g >= 1 and g <= width and out.len == g);
    const c0 = ctxs[0].circuit;
    const pin = c0.knobs.newton.pin;
    if (width == 1 or g == 1 or !(pin == .auto or pin == .direct) or root.Circuit.certify or c0.vpi != null) {
        for (ctxs, out) |*c, *o| o.* = run(c, opts);
        return;
    }
    const L = @import("solver").lanes.Lanes(width);
    const System = @import("solver").lane_system.LaneSystem(width, root.Circuit, TranHook);
    const bit = struct {
        fn f(l: usize) L.Mask {
            return @as(L.Mask, 1) << @intCast(l);
        }
    }.f;
    var runs: [width]Run = undefined;
    var live: L.Mask = 0;
    for (ctxs, 0..) |*c, l| {
        runs[l].init(c, opts) catch |e| {
            out[l] = e;
            continue;
        };
        live |= bit(l);
    }
    defer {
        var it = L.each(live);
        while (it.next()) |l| runs[l].deinit();
    }
    const Lane = struct {
        /// Lane l ends with `ok` (`Sim.finish`'s value, or false short of
        /// t_stop): its result, then its scratch.
        fn done(rs: []Run, m: *L.Mask, o: []LaneOutcome, l: usize, ok: bool) void {
            o[l] = rs[l].take(ok);
            rs[l].deinit();
            m.* &= ~bit(l);
        }
        fn kill(rs: []Run, m: *L.Mask, o: []LaneOutcome, l: usize, err: LaneError) void {
            o[l] = err;
            rs[l].deinit();
            m.* &= ~bit(l);
        }
        /// Every live lane fails with the batch's own error (out of memory,
        /// a cancel).
        fn fail(rs: []Run, m: *L.Mask, o: []LaneOutcome, err: LaneError) void {
            var it = L.each(m.*);
            while (it.next()) |l| kill(rs, m, o, l, err);
        }
    };
    if (live == 0) return;
    const gpa = ctxs[@ctz(live)].scratch_allocator;
    const n = c0.n;

    var sys: ?System = null;
    defer if (sys) |*s| s.deinit(gpa);
    var lws: ?@import("solver").converger.LaneWorkspace(width) = null;
    defer if (lws) |*w| w.deinit(gpa);
    const xv = gpa.alloc(L.V, n) catch |e| return Lane.fail(&runs, &live, out, e);
    defer gpa.free(xv);
    var atts: [width]Attempt = undefined;

    while (live != 0) {
        var round: L.Mask = 0;
        var tv: [width]f64 = @splat(0);
        var it = L.each(live);
        while (it.next()) |l| {
            const sim = &runs[l].sim;
            const a = sim.begin() catch |e| {
                Lane.kill(&runs, &live, out, l, e);
                continue;
            } orelse {
                const ok = sim.finish() catch |e| {
                    Lane.kill(&runs, &live, out, l, e);
                    continue;
                };
                Lane.done(&runs, &live, out, l, ok);
                continue;
            };
            atts[l] = a;
            tv[l] = a.t_dev;
            round |= bit(l);
        }
        if (round == 0) break;
        const lead = @ctz(round);
        if (sys == null) {
            // Unused and finished lanes repeat the lead and stay inactive.
            var lanes: [width]*root.Circuit = undefined;
            var wss: [width]*converger.Workspace = undefined;
            for (&lanes, &wss, 0..) |*c, *w, l| {
                const k = if (l < g and (live >> @intCast(l)) & 1 != 0) l else lead;
                c.* = runs[k].sim.ckt;
                w.* = runs[k].sim.ws;
            }
            sys = System.init(gpa, lanes, atts[lead].hook) catch |e| return Lane.fail(&runs, &live, out, e);
            lws = converger.LaneWorkspace(width).init(gpa, wss) catch |e| return Lane.fail(&runs, &live, out, e);
        }
        const s = &sys.?;
        it = L.each(round);
        while (it.next()) |l| {
            s.hooks[l] = atts[l].hook;
            System.putLane(xv, runs[l].sim.trial, l);
        }
        s.active = round;
        const res = converger.newtonLanes(width, s, &lws.?, xv, tv, atts[lead].nr_opts, System.LaneHook{});
        // As `converger.run` ends each lane's solve.
        it = L.each(round);
        while (it.next()) |l| runs[l].sim.ckt.clearLimits();
        const r = res catch |e| return Lane.fail(&runs, &live, out, e);
        it = L.each(round);
        while (it.next()) |l| {
            const sim = &runs[l].sim;
            System.getLane(sim.trial, xv, l);
            const b = bit(l);
            // A singular lane is `converger.run`'s caught numerical failure.
            const nr: converger.Result = if (r.singular & b != 0)
                .{ .converged = false, .iterations = 0 }
            else
                .{ .converged = r.converged & b != 0, .iterations = r.iterations[l] };
            const v = sim.end(&atts[l], nr) catch |e| {
                Lane.kill(&runs, &live, out, l, e);
                continue;
            };
            switch (v) {
                .go => {},
                .stop => {
                    const ok = sim.finish() catch |e| {
                        Lane.kill(&runs, &live, out, l, e);
                        continue;
                    };
                    Lane.done(&runs, &live, out, l, ok);
                },
                .underflow => Lane.done(&runs, &live, out, l, false),
            }
        }
    }
}
```

Notes and **CHECK**s:
- **Name collision.** tran.zig has a file-level `const W`, so the comptime
  parameter is called `width`. Zig refuses a parameter that shadows a container
  declaration.
- **The `lanes` array is built once, on the first round.** A lane that dies
  later stays in `sys.lanes`. That is harmless: it never re-enters `active`.
  `LaneSolver.rejoin` reads every lane's tape key, but those are reads only: a
  finished lane's solver is no longer written.
- **Error set.** `Lane.fail(..., e)` with `e` from `newtonLanes(width)` needs
  that error set ⊆ `ErrorOf(run)`. It should be `{QueryCancelled, OutOfMemory}`:
  `LaneSolver.factorSolveNeg` returns the other factor errors through
  `else => |other|`, which narrows. If the build disagrees, write `@errorCast(e)`.
  `dc.runLanes` compiles the same pattern.
- **`sim.begin() catch ... orelse ...`.** **CHECK** the precedence: `catch`
  binds tighter than `orelse`, so this reads `(sim.begin() catch {...}) orelse
  {...}`. The `catch` block ends in `continue`, which is `noreturn`. If that
  trips the compiler, split it in two:
  `const maybe = sim.begin() catch |e| {...}; const a = maybe orelse {...};`.
- **`ckt.knobs.newton.pin`** exists today (`op.solveLanes` reads it).

### 2.4 `src/analysis/executor.zig`: the `.tran` batch branch

1. Imports, after `const dc = @import("dc/dc.zig");` (line 14):

```zig
const tran = @import("tran/tran.zig");
```

2. `Config.lanes` doc (line ~60): "batch ready operating points, `.dc` sweeps
   and transients as lanes".

3. `executeBatch` (line ~312). Its doc gains ", transients
   (`tran.runLanes`)". The assert becomes:

```zig
        std.debug.assert(g <= lane_width and (self.job == .op or self.job == .dc or self.job == .tran));
```

   Insert after the `.dc` branch's closing `}` (line ~352), before
   `var ckts: [lane_width]*types.Circuit = undefined;`:

```zig
        if (self.job == .tran) {
            var ctxs: [lane_width]types.RunCtx = undefined;
            for (live[0..n_live], 0..) |k, l| {
                const e = members[k];
                // `runQuery`'s transient start: the `.ic` kind, and the
                // `uic` x when no operating point ran.
                e.circuit.setSimState(.{ .kind = .ic });
                if (e.job.uic()) e.seedUic() catch |err| {
                    for (live[0..n_live]) |j| outcomes[j] = err;
                    return outcomes[0];
                };
                ctxs[l] = e.runCtx();
            }
            var ran: [lane_width]tran.LaneOutcome = undefined;
            if (n_live != 0) tran.runLanes(lane_width, ctxs[0..n_live], self.job.tran, ran[0..n_live]);
            for (live[0..n_live], ran[0..n_live]) |k, o| {
                outcomes[k] = if (o) |r| members[k].label(r) else |err| err;
                members[k].refuseLatched() catch |err| {
                    outcomes[k] = err;
                };
            }
            return outcomes[0];
        }
```

4. `runQuery`. Factor the `uic` seed (lines ~466-471) into a method, used by
   both callers:

```zig
        } else if (self.job.uic()) try self.seedUic();
```

```zig
    /// A `uic` start's x: zero, then every `.ic` and `uic` value.
    fn seedUic(self: *Executor) !void {
        self.x = try self.work.allocator().alloc(f64, self.circuit.n);
        @memset(self.x.?, 0);
        for (self.deck.ic) |ic| self.x.?[ic.node] = ic.value;
        for (self.deck.uic_ic) |ic| self.x.?[ic.node] = ic.value;
    }
```

   **CHECK:** `QueryError` must still cover `tran.runLanes`' outcomes. It
   already includes `ErrorOf(run)`, which includes `tran.run`'s set.

### 2.5 `src/analysis/session.zig`: grouping admits `.tran`

`gather` (line ~478):

```zig
        if ((jobs[i] != .op and jobs[i] != .dc and jobs[i] != .tran) or self.rows.items(.executor)[i] != null) return;
```

Its doc: "makes ready `.op`, `.dc` or `.tran` row `i` the leader ...".

`sameLaneJob` (line ~1022):

```zig
        inline .op, .dc, .tran => |o, tag| b == tag and sameDeep(stripTol(o), stripTol(@field(b, @tagName(tag)))),
```

**CHECK:** `sameDeep` over `query.Tran` walks `PointOptions` (`abort_measure:
[]const u8`, `abort_after: ?f64`, `tangent_step: f64`) and `tangents: []const
u32`. Every one is a case `sameDeep` handles (slice, optional, float, int,
enum, bool).

## 3. W = 1 identity and codegen probes

- **No scalar arithmetic becomes W-generic in phase 3.** The step logic runs per
  lane as scalar code (`Sim`), and the only W-generic piece is `newtonLanes`,
  which phase 1's `gen_newton`/`hand_newton` pair already holds IDENTICAL.
  `LaneSystem` is W ≥ 2 only (`comptime assert(W >= 2)`), so its per-lane hooks
  touch no W = 1 code. **No new `gen_`/`hand_` pair is added.** A
  `gen_tran_step` probe would have to export `Sim`, which drags `Circuit` and
  every device into tests/codegen.zig's object, and it would test a refactor,
  not an abstraction.
- **The W = 1 identity gate is behavioural.** The whole corpus runs through
  `Sim.drive` (lanes off), and it must be byte-identical to the pre-refactor
  binary (§4.4 step a). Every transient deck is a test of the transplant.
- **Performance check** for the refactor (the moved locals are now fields
  behind `s.`): run the 24-stage chain (`gen_chain.py`) 5 times at ReleaseFast
  under `ZP_TRAN_STATS=1` on the old and new binaries. The attempts and
  `nr_iters` must be equal, and the wall times within noise (≤ 1%). Per-attempt
  control is ~0.1% of a step, so register pressure there is irrelevant.

## 4. Tests

### 4.1 `src/solver/lane_system.zig`: existing tests

`expectNewtonLanes` keeps passing `.{}` to `init`: no change. It now also
exercises `@splat(hook)` and the active-only `beginSolve`.

### 4.2 `src/analysis/tests/session.zig`: new test

```zig
test "lane batches: .tran rows (a moved source edge, a NaN and an extreme lane) group into batches and each equals its run alone, bitwise" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    // PULSE(0 1 1ns 50ps 50ps 2ns 6ns): the variant rows move its delay.
    // CHECK: vsource takes its pulse parameters where `.dc` goes in the
    // tests above (`&.{ .dc = 3 }`); swap the two slices if they are
    // model parameters instead.
    try b.addDevice(models.vsource, "", &.{ .waveform = 1, .pulse_v1 = 0, .pulse_v2 = 1, .pulse_td = 1e-9, .pulse_tr = 5e-11, .pulse_tf = 5e-11, .pulse_pw = 2e-9, .pulse_per = 6e-9 }, &.{}, .{ vin, GROUND });
    var prev = vin;
    for (0..4) |_| {
        const mid = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ prev, mid });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-12 }, &.{}, .{ mid, GROUND });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14, .cjo = 1e-13 }, &.{}, .{ mid, GROUND });
        prev = mid;
    }
    var prepared = try b.compile();
    defer prepared.deinit();
    var probe = try @import("../types.zig").Circuit.instantiate(&prepared, t.allocator);
    defer probe.deinit();
    const params = try probe.collectParams();
    const find = struct {
        fn f(ps: []const @import("../types.zig").ParamRef, ty: @import("device").abi.DeviceType, name: []const u8) !u32 {
            for (ps, 0..) |p, k| if (p.type == ty and p.index == 0 and std.mem.eql(u8, p.param_name, name)) return @intCast(k);
            return error.TestUnexpectedResult;
        }
    }.f;
    const r_ref = try find(params, builtin("resistor"), "r");
    const td_ref = try find(params, builtin("vsource"), "pulse_td");
    // Rows 0..7 write the first resistor; rows 8..11 the source delay (one
    // edge moved per row). Repeated values replicate a lane.
    const refs = [_]u32{ r_ref, r_ref, r_ref, r_ref, r_ref, r_ref, r_ref, r_ref, td_ref, td_ref, td_ref, td_ref };
    const values = [_]f64{ 1e3, 2e3, std.math.nan(f64), 1e-30, 1e3, 5e3, 1e12, 7e3, 1e-9, 1.25e-9, 0.5e-9, 1e-9 };
    var labels: [values.len][]const u8 = undefined;
    var starts: [values.len + 1]u32 = undefined;
    var temps: [values.len]?f64 = undefined;
    for (&labels, starts[0..values.len], &temps, 0..) |*l, *s0, *tc, k| {
        l.* = "row";
        s0.* = @intCast(k);
        tc.* = null;
    }
    starts[values.len] = values.len;
    var deck = bareDeck(&.{ vin, prev }, &.{ "v(in)", "v(out)" });
    deck.variants = .{ .labels = &labels, .temp_c = &temps, .starts = &starts, .refs = &refs, .values = &values };
    deck.cards = &.{.{ .type = builtin("vsource"), .index = 0, .name = "v1" }};
    var jobs: [values.len]requests.Query = undefined;
    for (&jobs, 0..) |*j, k| j.* = .{ .tran = .{ .t_stop = 8e-9, .dt_init = 2e-11, .tol = .{ .variant = @intCast(k) } } };
    const Row = struct { status: Status, failure: ?@import("../session.zig").Failure, data: []f64 };
    var rows: [2][jobs.len]Row = undefined;
    var tran_batched: usize = 0;
    for ([_]bool{ false, true }, &rows) |lanes, *out| {
        var config: @import("../executor.zig").Config = .{};
        config.knobs.lanes = lanes;
        var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        try s.runAll(.{ .max_parallel = 1, .quantum = .completion });
        for (s.rows.items(.executor), s.rows.items(.job)) |e, j| if (e) |x| {
            if (j == .tran) tran_batched += x.peers.len;
        };
        for (ids, out) |id, *r| {
            const q = try s.info(id);
            r.* = .{ .status = q.status, .failure = q.failure, .data = &.{} };
            if (q.status == .complete) r.data = try t.allocator.dupe(f64, (try s.result(id)).data);
        }
    }
    defer for (rows) |rs| for (rs) |r| t.allocator.free(r.data);
    try t.expect(tran_batched > 0);
    var completed: usize = 0;
    for (rows[0], rows[1]) |a, c| {
        try t.expectEqual(a.status, c.status);
        try t.expectEqual(a.failure, c.failure);
        try t.expectEqualSlices(u64, @ptrCast(a.data), @ptrCast(c.data));
        completed += @intFromBool(a.status == .complete);
    }
    // The NaN row fails; the moved edges and extremes still complete.
    try t.expect(completed > jobs.len / 2 and completed < jobs.len);
}
```

**CHECK:** the `ParamRef` and `DeviceType` import paths in the helper. Copy
whatever the existing `"lane batches: a NaN value ..."` test resolves
(`builtin("resistor")` returns the `DeviceType`).

Also extend the existing test `"lane batches: OP and .dc rows at several
temperatures ..."`: add ten `.tran` jobs (`.t_stop = 2e-6`, one per
temperature) to `jobs`, and a `tran_batched` count beside `dc_batched`. Its
bitwise comparison already covers every row.

### 4.3 `src/tests/espice.zig`: the lockstep and mixed-lane gate, end to end

Two tests next to the #212 test. Both use the public `api.Problem` with
`.backend = .{ .lanes = true }`.

```zig
test "per-lane stimulus (#212) under lanes: each .data point equals its row run alone, to the bit" {
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, lane_deck, t.allocator, .unlimited);
    defer t.allocator.free(source);
    var swept: LaneRun = .{};
    defer swept.deinit();
    try swept.addWith(source, true);
    var alone: LaneRun = .{};
    defer alone.deinit();
    for ([_][2]f64{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 1 }, .{ 1, 0 } }) |row| {
        const solo = try laneSolo(source, row[0], row[1]);
        defer t.allocator.free(solo);
        try alone.add(solo);
    }
    try t.expectEqualStrings(alone.measures.items, swept.measures.items);
    try t.expectEqualSlices(u64, @ptrCast(alone.data.items), @ptrCast(swept.data.items));
    for (swept.grids.items, alone.grids.items) |a, b| try t.expectEqualSlices(u64, @ptrCast(b), @ptrCast(a));
}
```

with `LaneRun.add` split so a backend can be passed:

```zig
    fn add(r: *LaneRun, source: []const u8) !void {
        return r.addWith(source, false);
    }

    fn addWith(r: *LaneRun, source: []const u8, lanes: bool) !void {
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "lane.sp" } }, .dialect = .hspice, .backend = .{ .lanes = lanes } });
        // ... the rest of today's `add` body, unchanged ...
    }
```

Change the call in the first test to `try swept.addWith(source, true);`.
`Problem.init`'s `backend` field is `analysis.ExecutionConfig`, which is
`executor.Config`, and `.{ .lanes = lanes }` sets its `lanes` field.

The lockstep test is §1's 16 points, but on level-1 MOS so it needs no PDK,
plus the §11 mixed lanes: a lane that fails, a moved source edge, a
re-pivoting extreme, and two permutations of the table.

```zig
const chain_deck =
    \\* Lane lockstep (#207): 16 sizing points of an 8-stage inverter chain
    \\* with RC wires (lane-batched-simulation.md §1 on level-1 MOS), plus a
    \\* moved input edge, an extreme wire and a failing row.
    \\.param wn=1u wp=2u rw=200 cw=5f td=20p
    \\vdd vdd 0 1
    \\vin in 0 pulse(0 1 'td' 10p 10p 100p 300p)
    \\.subckt stage a z vdd
    \\mn y a 0 0 nm l=0.1u w='wn'
    \\mp y a vdd vdd pm l=0.1u w='wp'
    \\rw y z 'rw'
    \\cw z 0 'cw'
    \\.ends
    \\x1 in n1 vdd stage
    \\x2 n1 n2 vdd stage
    \\x3 n2 n3 vdd stage
    \\x4 n3 n4 vdd stage
    \\x5 n4 n5 vdd stage
    \\x6 n5 n6 vdd stage
    \\x7 n6 n7 vdd stage
    \\x8 n7 n8 vdd stage
    \\.model nm nmos level=1 vto=0.3 kp=200u
    \\.model pm pmos level=1 vto=-0.3 kp=100u
    \\.data pts wn wp rw cw td
    \\ROWS
    \\.enddata
    \\.tran 1p 400p sweep data=pts
    \\.meas tran tpd trig v(in) val=0.5 rise=1 targ v(n8) val=0.5 cross=1
    \\.meas tran trise trig v(n8) val=0.2 rise=1 targ v(n8) val=0.8 rise=1
    \\.meas tran tfall trig v(n8) val=0.8 fall=1 targ v(n8) val=0.2 fall=1
    \\.end
    \\
;

/// (wn, wp, rw, cw, td): 16 sizing points drawn as lockstep.py draws them
/// (nfin 2-4 as width 0.5-1.5 um, rw and cw 0.5-2x), then a moved edge,
/// an extreme wire, and rw = 0, which fails (CHECK: if the frontend
/// clamps r = 0 instead of failing, the test still holds; it then only
/// checks that some row differs, see the last assert).
const chain_rows = [_][5]f64{
    .{ 1.0e-6, 2.0e-6, 200, 5e-15, 20e-12 },   .{ 0.5e-6, 1.0e-6, 137, 3.1e-15, 20e-12 },
    .{ 1.5e-6, 3.0e-6, 352, 9.2e-15, 20e-12 }, .{ 1.0e-6, 1.0e-6, 101, 2.6e-15, 20e-12 },
    .{ 0.5e-6, 3.0e-6, 288, 7.7e-15, 20e-12 }, .{ 1.5e-6, 1.0e-6, 214, 4.0e-15, 20e-12 },
    .{ 1.0e-6, 3.0e-6, 390, 6.6e-15, 20e-12 }, .{ 0.5e-6, 2.0e-6, 166, 9.9e-15, 20e-12 },
    .{ 1.5e-6, 2.0e-6, 121, 2.9e-15, 20e-12 }, .{ 1.0e-6, 2.0e-6, 305, 8.4e-15, 20e-12 },
    .{ 0.5e-6, 1.0e-6, 255, 5.5e-15, 20e-12 }, .{ 1.5e-6, 3.0e-6, 178, 3.7e-15, 20e-12 },
    .{ 1.0e-6, 1.0e-6, 333, 7.1e-15, 20e-12 }, .{ 0.5e-6, 3.0e-6, 110, 6.0e-15, 20e-12 },
    .{ 1.5e-6, 1.0e-6, 270, 4.8e-15, 20e-12 }, .{ 1.0e-6, 3.0e-6, 199, 8.8e-15, 20e-12 },
    .{ 1.0e-6, 2.0e-6, 200, 5e-15, 37e-12 },   .{ 1.0e-6, 2.0e-6, 1e9, 5e-15, 20e-12 },
    .{ 1.0e-6, 2.0e-6, 0, 5e-15, 20e-12 },
};

/// `chain_deck` with `order`'s rows in its .data table.
fn chainSwept(order: []const usize) ![]u8 {
    var rows: std.Io.Writer.Allocating = .init(t.allocator);
    defer rows.deinit();
    for (order) |k| {
        const r = chain_rows[k];
        try rows.writer.print("+ {e} {e} {e} {e} {e}\n", .{ r[0], r[1], r[2], r[3], r[4] });
    }
    return std.mem.replaceOwned(u8, t.allocator, chain_deck, "ROWS\n", rows.written());
}

/// `chain_deck` without its .data table, at row `k` alone.
fn chainSolo(k: usize) ![]u8 {
    const r = chain_rows[k];
    var line: [128]u8 = undefined;
    const p = try std.fmt.bufPrint(&line, ".param wn={e} wp={e} rw={e} cw={e} td={e}", .{ r[0], r[1], r[2], r[3], r[4] });
    const start = std.mem.indexOf(u8, chain_deck, ".data ").?;
    const end = std.mem.indexOf(u8, chain_deck, ".enddata\n").? + ".enddata\n".len;
    const cut = try std.mem.concat(t.allocator, u8, &.{ chain_deck[0..start], chain_deck[end..] });
    defer t.allocator.free(cut);
    const plain = try std.mem.replaceOwned(u8, t.allocator, cut, " sweep data=pts", "");
    defer t.allocator.free(plain);
    return std.mem.replaceOwned(u8, t.allocator, plain, ".param wn=1u wp=2u rw=200 cw=5f td=20p", p);
}

/// Each requested .tran point's samples (empty for a failed point) and
/// error name, in request order.
const Points = struct {
    data: std.ArrayList([]f64) = .empty,
    errs: std.ArrayList(?anyerror) = .empty,

    fn deinit(ps: *Points) void {
        for (ps.data.items) |d| t.allocator.free(d);
        ps.data.deinit(t.allocator);
        ps.errs.deinit(t.allocator);
    }

    fn collect(ps: *Points, source: []const u8, lanes: bool) !void {
        const p = try api.Problem.init(t.allocator, t.io, .{ .source = .{ .bytes = .{ .data = source, .origin = "chain.sp" } }, .dialect = .hspice, .backend = .{ .lanes = lanes } });
        defer p.deinit();
        // CHECK: whether `run_all` fails when one point fails; if it does,
        // catch and continue, the per-query results below still tell.
        p.run_all() catch {};
        for (0..p.query_count()) |i| {
            const id: api.QueryId = @fromBackingInt(@intCast(i));
            const info = try p.query_info(id);
            if (!info.requested or info.kind != .tran) continue;
            if (p.result(id)) |res| {
                try ps.data.append(t.allocator, try t.allocator.dupe(f64, res.data));
                try ps.errs.append(t.allocator, null);
            } else |e| {
                try ps.data.append(t.allocator, &.{});
                try ps.errs.append(t.allocator, e);
            }
        }
    }
};

test "lane lockstep (#207): 16 sizing points, a moved edge, an extreme and a failing row, in three orders, each bitwise its run alone" {
    var alone: Points = .{};
    defer alone.deinit();
    for (0..chain_rows.len) |k| {
        const solo = try chainSolo(k);
        defer t.allocator.free(solo);
        try alone.collect(solo, false);
    }
    try t.expectEqual(chain_rows.len, alone.data.items.len);
    var identity: [chain_rows.len]usize = undefined;
    for (&identity, 0..) |*o, k| o.* = k;
    var reversed = identity;
    std.mem.reverse(usize, &reversed);
    var shuffled = identity;
    var prng = std.Random.DefaultPrng.init(207);
    prng.random().shuffle(usize, &shuffled);
    for ([_][]const usize{ &identity, &reversed, &shuffled }) |order| {
        const src = try chainSwept(order);
        defer t.allocator.free(src);
        var got: Points = .{};
        defer got.deinit();
        try got.collect(src, true);
        try t.expectEqual(order.len, got.data.items.len);
        for (order, got.data.items, got.errs.items) |k, d, e| {
            try t.expectEqual(alone.errs.items[k], e);
            try t.expectEqualSlices(u64, @ptrCast(alone.data.items[k]), @ptrCast(d));
        }
    }
    // Some row must fail (rw = 0) or the failing-lane case tested nothing.
    try t.expect(std.mem.indexOfNone(?anyerror, alone.errs.items, &.{null}) != null);
}
```

The bitwise per-point comparison implies equal time grids. The time column is
part of `data`, so no separate grid assert is needed.

**CHECK:** `api.QueryId`, `query_info(...).requested` and `.kind`, and
`p.result` match the #212 test's use. They are copied from it.

### 4.4 Corpus gate: `tools/lane_diff.py`

New file (the plan's only tool). It compares raw output bytes and stdout
(`.meas` lines). Modes:
- `swept` (default): every corpus deck that holds one of the given analysis
  cards *and* a sweep construct, run with `ESPICE_LANES=0` and `ESPICE_LANES=1`,
  both at `--jobs=1`.
- `replicate`: every deck that holds the card gets 4 identical rows appended
  (`.param lane_rep=0` plus `.step param lane_rep list 1 2 3 4`). Each point's
  plot must equal the unswept run's plot, data bitwise. This is §11 test 2,
  "replication", which makes the whole fixture corpus a lane test without new
  expected files.

```python
#!/usr/bin/env python3
"""Lane gates (lane-batched-simulation.md §11 tests 2 and 3).
  tools/lane_diff.py ESPICE swept     [kinds...]  every swept deck: lanes off == lanes on, bytes
  tools/lane_diff.py ESPICE replicate [kinds...]  every deck x4 identical rows: each point == the deck alone, data bits
kinds default to tran; e.g. `op dc tran`. Exit 1 on any difference."""
import json, os, pathlib, re, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

exe = os.path.abspath(sys.argv[1]); mode = sys.argv[2] if len(sys.argv) > 2 else "swept"
kinds = sys.argv[3:] or ["tran"]
SWEEP = re.compile(r"^\s*\.(step|data|alter|mc)\b|\bsweep\b|^\s*\.temp\s+\S+\s+\S+", re.I | re.M)
CARD = re.compile(r"^\s*\.(" + "|".join(kinds) + r")\b", re.I | re.M)

def tokenizer(deck):
    oracle = deck.with_suffix(".expected.json")
    try: return json.loads(oracle.read_text()).get("tokenizer") or "ngspice"
    except Exception: return "ngspice"

def run(deck, src, lanes, tmp):
    p = pathlib.Path(tmp) / deck.name
    p.write_text(src)
    raw = pathlib.Path(tmp) / f"out{lanes}.raw"
    env = dict(os.environ, ESPICE_LANES=str(lanes))
    r = subprocess.run([exe, "--jobs=1", "--format=binary", "-b", "-r", str(raw), "--tokenizer", tokenizer(deck), p.name],
                       cwd=tmp, env=env, capture_output=True, timeout=1800)
    return r.returncode, r.stdout, raw.read_bytes() if raw.exists() else b""

def plots(raw):
    """ngspice binary raw: list of (plotname, nvars, npoints, complex, data bytes)."""
    out, i = [], 0
    while i < len(raw):
        hdr = {}
        while True:
            j = raw.index(b"\n", i); line = raw[i:j].decode(errors="replace"); i = j + 1
            if line.startswith("Binary:"): break
            if ":" in line: k, v = line.split(":", 1); hdr[k.strip()] = v.strip()
            if line.startswith("Variables:"):
                for _ in range(int(hdr["No. Variables"])): i = raw.index(b"\n", i) + 1
        nv, npt = int(hdr["No. Variables"]), int(hdr["No. Points"])
        cplx = "complex" in hdr.get("Flags", "")
        n = nv * npt * (16 if cplx else 8)
        out.append((hdr.get("Plotname", ""), nv, npt, cplx, raw[i:i + n])); i += n
    return out

def check(deck):
    src0 = deck.read_text(errors="replace")
    # Copy the deck's directory so includes resolve.
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["cp", "-r", str(deck.parent) + "/.", tmp], check=True)
        if mode == "swept":
            a, b = run(deck, src0, 0, tmp), run(deck, src0, 1, tmp)
            return None if a == b else f"{deck}: lanes on != off (rc {a[0]}/{b[0]}, raw {len(a[2])}/{len(b[2])} B)"
        base = run(deck, src0, 0, tmp)
        rep = re.sub(r"^\s*\.end\s*$", ".param lane_rep=0\n.step param lane_rep list 1 2 3 4\n.end", src0, flags=re.I | re.M)
        got = run(deck, rep, 1, tmp)
        if base[0] != 0: return None  # a failing deck stays failing; swept mode covers its bytes
        pb, pg = plots(base[2]), plots(got[2])
        if len(pg) != 4 * len(pb): return f"{deck}: {len(pg)} plots for 4 x {len(pb)}"
        for k, g in enumerate(pg):
            want = pb[k % len(pb)]  # step-major: point j's plots are pg[j*len(pb) : (j+1)*len(pb)]
            if g[1:] != want[1:]: return f"{deck}: replica plot {k} '{g[0]}' differs from '{want[0]}'"
        return None

decks = sorted(p for p in pathlib.Path("tests/fixtures").rglob("*.sp")
               if "invalid" not in p.parts and (t := p.read_text(errors="replace"))
               and CARD.search(t) and (mode == "replicate" or SWEEP.search(t)))
if mode == "replicate": decks = [d for d in decks if not SWEEP.search(d.read_text(errors="replace"))]
with ThreadPoolExecutor(os.cpu_count() // 2 or 1) as pool:
    bad = [m for m in pool.map(check, decks) if m]
print(f"{len(decks)} decks, {len(bad)} differ"); [print(m) for m in bad]
sys.exit(1 if bad else 0)
```

**CHECK:**
- The replica plot order. ESPice emits each sweep point's plot in point order
  (`session.outputs`), so with one analysis per deck point k is plot k. A deck
  with several analysis cards emits them per point (step-major, one plot per
  card per point), so `pb[k % len(pb)]` is right. Verify on one multi-card
  deck and fix the index if ESPice orders card-major.
- The raw header field names (`No. Variables`, `No. Points`, `Flags`,
  `Plotname`). They are ngspice's; confirm against `src/output/raw.zig`.
- Decks whose `.end` is missing, or that already define `lane_rep`. The first
  is skipped by the regex.

**Gate runs**, in this order (Debug build, `-Dgpu=false`, one at a time per
AGENTS.md):

a. **Refactor identity, before any lane code is reachable.**
   `ESPICE_LANES=0` corpus `test-correctness` unchanged. Also run
   `tools/lane_diff.py OLD_ESPICE swept tran`, adapted to diff the old binary
   against the new one with lanes off: copy `run` with `exe` switched. This is
   §3's behavioural W = 1 gate.

b. `tools/lane_diff.py zig-out/bin/espice swept op dc tran`: 0 differ.
   Expected decks today: `variants/data_lane_stimulus`,
   `variants/monte_tran_meas` (200 points), `variants/step_*`, `optimize/*`,
   plus phase 2's op/dc decks.

c. `tools/lane_diff.py zig-out/bin/espice replicate tran`: 0 differ.

d. `zig build test-analysis`, `test-espice` and `test-solver`: the new and
   existing lane tests.

e. **ReleaseFast compile time** (`zig build -Doptimize=ReleaseFast install`,
   cold for the exe module) within +20% of main. One more `newtonLanes`
   instantiation is expected to cost seconds.

## 5. Risks, open questions, what only a build settles

1. **The transplant is the risk.** About 450 lines move into methods. Every read
   of a mutated local (`t`, `dt`, `order`, `del`) must see the same value as
   before. Gate (a) catches any slip, because the corpus' transient decks cover
   the Newton, LTE, flip, `reject_at`, VPI, gear-3..6, uic, tangent and
   early-stop paths. Review the diff side by side against 06cff37f.
2. **Interleaved device calls across lanes.**
   - Lane l's devices see the same call sequence, but other lanes' calls happen
     in between. That is safe only if devices hold no process-global state.
   - `ckt.vpi` is excluded for that reason.
   - Display tasks are already excluded (`sayNames`).
   - VerA's §9.21 tables and `$random` seeds live per Instance. **CHECK** that
     no generated model keeps a process-global (file-scope `var`). One `grep -n
     "^var " zig-out/.../*.zig` over the generated models settles it.
3. **The executor computes `nr_opts` from the leader's `opts`.** That is valid
   because `stripTol` groups only on equal non-variant tolerances. A future
   `Tran` field that is per-row and enters `optionsFromTolerances` would have to
   join the key.
4. **Idle tail.**
   - Lanes that finish early (early stop, an earlier t_stop is impossible within
     a group) leave the batch, and the rest continue at a narrower effective
     width.
   - Idle at W = 4 is 5-8% (§7).
   - Refill stays deferred until a measurement above 10%.
5. **Memory.** W `Run`s each hold today's scratch (same as W queries on W
   threads). No new peak.
6. **What only a build settles:** the **CHECK**s above.
   - `@splat` for zero-size hooks;
   - `catch`/`orelse` precedence;
   - error-set coercions;
   - the `api` option type name;
   - vsource parameter slots in the Builder test.

## 6. Effort

| Step | Work | Effort |
|---|---|---|
| 2.1 | `LaneSystem` per-lane hooks, active-only `beginSolve` | 0.5 d |
| 2.2 | `Sim` transplant, `drive`, gate (a) | 2 d |
| 2.3 | `Run`, `run`, `runLanes` | 1 d |
| 2.4-2.5 | executor branch, `seedUic`, session grouping | 0.5 d |
| 4.2-4.3 | session and end-to-end lane tests | 1.5 d |
| 4.4 | `lane_diff.py`, gates (b)-(e), fixes | 1.5 d |
| | **Total** | **7 d (≈1.5 weeks)**, against §11's 3 weeks: the CPU path keeps scalar control per lane, and only Newton is shared |

Critical path to phase 4: 2.1 → 2.2 → 2.3. Phase 4's step G1 (the
probe/decide/apply split) starts from 2.2's `Sim`.
