# Phase 6 plan: periodic analyses per lane (#210)

Status: plan, not built. Written against main 06cff37f. Every line anchor
below was re-read in that tree. **Depends on phase 3** (#207): the
per-lane hook array in `solver/lane_system.zig`, `beginSolve` over the
active lanes only, and the `.tran` branch it adds to
`Executor.executeBatch` and `Session.gather`. Apply phase 3 first.

## 0. What the code actually does (corrections to the issue)

The issue and design doc §6 describe shooting as "a lane transient over
one period, reusing Phase 3's rounds". The tree does not do that:

- `pss.zig` never calls `tran.simulate`. `integrateOnePeriod`
  (pss.zig:74-145) is its own fixed-step trapezoid: `n_samples` steps of
  `dt = period / n_samples`, a `PeriodHook = integrator.Hook(.trapezoidal)`
  (pss.zig:68), one `converger.run` per step (pss.zig:124), commit or
  revert. There is no LTE, no breakpoint, no reject, no step control.
  Every lane takes the same steps (only an autonomous lane's own period
  changes its dt and t). So the shooting integration is **lockstep by
  construction** and needs none of phase 3's per-lane step machine. It
  needs only phase 3's per-lane hooks (each lane's `PeriodHook` points at
  its own `Companion`).
- Shooting (`pss.solve`, pss.zig:306-410) is: one base integration per
  iteration, then either n finite-difference column integrations and a
  dense LU (`denseFdSolve`, pss.zig:223, below `krylov_threshold = 50`
  unknowns) or GMRES whose every matvec is one integration
  (`krylovSolve`, pss.zig:260), then a damped update; then one final
  integration that records the waveform. `pss.solve` is also the seed of
  `pac.orbit` (pac.zig:342, so `.pac`, `.pxf`, `.pnoise`) and of
  `hb.solveOscillator` (hb.zig:400, so `.hbosc` and `.phasenoise`).
- HB one-tone dense (`hb.solveSpectrum`, hb.zig:77-396): per Newton
  iteration, `nt` device evals of the sampled waveform (hb.zig:180-196),
  a dense `(n·nf)²` Jacobian built on the host and one dense LU
  (hb.zig:384). Backtracking `step` halving at hb.zig:235-246.
- MHB (`mhb.solve`, mhb.zig:480-599): per Newton iteration, `sample`
  (mhb.zig:417, `nt` evals), DFT, `fs.factorEach(omegas)` (mhb.zig:588)
  and one `Gmres.solve` (mhb.zig:592). Same backtracking at mhb.zig:566-576.
- PAC/PXF/PNOISE: `pac.settle` (pac.zig:416) = `pac.orbit` (shooting) +
  `linearize`, then `pac.sweep` (pac.zig:42): a dense LU per frequency or
  GMRES with `factorEach` per frequency (`sweepKrylov`, pac.zig:161-211).
- No corpus deck sweeps a `.pss` (`tests/fixtures/pss/*.sp` has no
  `.step`/`.data`), and only `tests/fixtures/hb/sweep_two_tone_cubic.sp`
  sweeps an `.hb`. The §11 gate ("corpus PSS/HB decks byte-identical
  batched") is therefore vacuous on today's corpus; this plan adds swept
  tests (§4) instead of new fixtures, because no external oracle runs
  ESPice's shooting (ngspice has no `.pss` shooting).

## 1. Design

### 1.1 The rule that sets the scope

On the CPU a lane is a deinterleaved scalar eval (§4 of the design doc)
and lane batching measured as a loss (#211). So a CPU lane buys nothing by
itself; it is worth building only where it is the **bitwise oracle of a
future GPU kernel**. Three periodic pieces have a GPU shape:

| Piece | GPU shape | CPU lane in phase 6? |
|---|---|---|
| shooting period integration (n_samples Newton solves per integration, n+1 integrations per dense iteration) | phase 4's lane Newton per step | **yes**: lane every integration of a round |
| HB/MHB sampled evals (`nt` evals per iteration) | eval over (sample, point) lanes, no Newton | no: a CPU lane is the same scalar eval; nothing to verify that phase 4's eval oracle does not already |
| MHB `factorEach` over (point, line) | phase 5's stacked (point, ω) factor | no: phase 5's stacked solver is its oracle |
| masked per-lane GMRES (MHB, PAC Krylov, shooting Krylov) | per-lane Krylov kernels | no: keep `Gmres` scalar; lanes peel |
| dense monodromy LU, dense HB/PAC LU | host scalar per lane (n < 50, or cuSOLVER batched later) | no |
| pz / QZ | not laned (§6) | no |

So phase 6 on the CPU is:

1. **`.pss` lanes.** `pss.solve` becomes a resumable per-lane state
   machine `Shoot` (the same pattern as `dc.Sweep` and phase 3's `Sim`):
   `next()` returns the next period integration the scalar algorithm
   needs (base, FD column j, or the final recorded period), `done(ok)`
   consumes its outcome (residual test, column store, dense LU, Krylov
   solve, damped update). Scalar `solve` drives it with
   `integrateOnePeriod`; `pss.runLanes` drives W of them in **rounds**:
   every live lane posts its next request, `integrateLanes` runs all
   posted periods together with one `converger.newtonLanes` per time
   step, and each lane consumes its outcome. Lanes may sit in different
   stages in one round (one lane on its base integration, another on FD
   column 7): every request is `n_samples` steps, so the steps align.
2. **Everything else stays scalar and ungrouped.** HB, MHB, `.hbac`/
   `.hbxf`/`.hbnoise`/`.hblin`, `.pac`, `.pxf`, `.pnoise`, `.phasenoise`,
   `.qpss` and `.pz` are **not** added to the grouping key. Grouping them
   with every lane peeled would run W queries serially on one worker that
   `--jobs` would otherwise run in parallel: a pure loss. The §11 gate
   holds for them trivially (they never batch) and stays a test (§4.3).

The GMRES and Krylov paths inside a laned `.pss` peel: a lane on the
Krylov path (n >= 50) runs `krylovSolve` with its scalar matvecs inside
its own `done`, while the round waits. Correct and bitwise; it gains
nothing, which is the point of the rule above.

### 1.2 Bitwise argument

- `Shoot.next`/`done` execute the statements of today's `solve` in the
  same order on the same buffers (§2 step 2 maps every line). The scalar
  `solve` becomes `init; while (next) |r| done(integrateOnePeriod(r))`,
  so W = 1 runs the same floating-point operations; only the control
  flow is restructured. No arithmetic becomes W-generic, so there is no
  new codegen probe (§3).
- `integrateLanes` runs, per lane, exactly `integrateOnePeriod`'s calls
  in order (`periodStart`, then per step `setSimState`, Newton,
  `clearLimits`, `periodAccept`), with the step's Newton as
  `converger.newtonLanes` over `LaneSystem(W, Circuit, PeriodHook)`.
  `newtonLanes` lane l is bitwise `converger.newton` on lane l (phase 1's
  test, phase 2's corpus run); `converger.run` adds only the JFNK pin
  (excluded) and `clearLimits` (done per lane). A singular or
  unconverged lane fails its period exactly as `integrateOnePeriod`'s
  `null`/`!converged` branch does.
- Lanes share no decision: each lane's iteration count, stage, column,
  damping and period are its own fields.

### 1.3 What a GPU phase reuses later (not built here)

- `integrateLanes` is the host loop phase 4 replaces: per step, upload t
  and dt per lane, run the lane Newton graph, download the converged and
  singular masks; `periodAccept`'s commit/revert, the companion `accept`
  and the wave row become per-lane kernels plus a probe download.
- The dense path's n FD columns are independent integrations: on the GPU
  a lane can be a (point, column) pair, N = points × n. `Shoot.next`
  then returns all n column requests at once. Not worth it at the CPU's
  W; a one-function change later (`nextBatch`).
- HB/MHB sample evals as (sample, point) lanes; MHB `factorEach` through
  phase 5's stacked solver; per-lane masked GMRES kernels for MHB and PAC
  Krylov; per-lane HB `step` as a lane vector. All four only pay on the
  GPU and each needs its own kernels: track as a phase 6b issue after
  phase 4 measures the shooting path.

## 2. Code changes, in dependency order

All edits are in `src/analysis/pss/pss.zig` unless named. Zig 0.18 as the
tree writes it (`@ctz`, `L.each`, `std.debug.assert`, labelled `switch`
`continue :sw`). `CHECK:` marks spots a build must confirm.

### Step 1. Imports and helpers for the period integration (pss.zig:14-21, 70-145)

Add after `const Gmres = ...` (pss.zig:21):

```zig
const solver = @import("solver");
const Lanes = solver.lanes.Lanes;

/// The lane system one period's step Newtons run on: each lane's own
/// circuit and its own `PeriodHook` (phase 3's per-lane hooks).
fn LaneSys(comptime W: usize) type {
    return solver.lane_system.LaneSystem(W, root.Circuit, PeriodHook);
}
```

Replace `integrateOnePeriod` (pss.zig:70-145) with the same function
built from three helpers that `integrateLanes` (step 3) shares. Bodies
are today's lines, moved verbatim:

```zig
/// Integrates x in place over [0, T] in n_samples trapezoid steps. A
/// non-empty `wave` receives n_samples+1 point-major rows
/// [t, v(probes)...] of stride 1 + probes.len. Returns false on the first
/// step whose Newton fails.
fn integrateOnePeriod(
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    sc: *Companion,
    x: []f64,
    probes: []const u32,
    wave: []f64,
    options: Options,
) error{ QueryCancelled, OutOfMemory }!bool {
    const steps: usize = options.n_samples;
    const dt = options.period / @as(f64, @floatFromInt(steps));
    periodStart(ckt, sc, x, probes, wave, options);
    for (0..steps) |k| {
        const t = stepTime(options, k);
        const hook = periodHook(sc, 2.0 / dt, ckt.has_charge);
        ckt.setSimState(.{ .t = t, .dt = dt, .kind = .tran });
        const nr = converger.run(ckt, ws, x, t, .{
            .max_iter = options.max_newton_iter,
            .abstol = options.newton_tol,
        }, hook) catch |err| switch (err) {
            error.QueryCancelled, error.OutOfMemory => |e| return e,
            else => null, // else: a numerical failure fails the period
        };
        if (!periodAccept(ckt, &hook, x, probes, wave, k, t, nr != null and nr.?.converged)) return false;
    }
    return true;
}

/// `integrateOnePeriod`'s start: the transient-phase sim state, the
/// trapezoid seam state at x, and the t = 0 wave row.
fn periodStart(ckt: *root.Circuit, sc: *Companion, x: []const f64, probes: []const u32, wave: []f64, options: Options) void {
    const n: usize = ckt.n;
    const dt = options.period / @as(f64, @floatFromInt(options.n_samples));
    // Sources follow their waveform only under `analysis("tran")` (§4.6.1),
    // so every evaluated point declares the transient phase.
    ckt.setSimState(.{ .t = 0, .dt = dt, .kind = .tran });
    if (ckt.has_charge) {
        ckt.eval(x, 0);
        num.copySimd(sc.q_prev[0..n], ckt.q_vec[0..n]);
        // Carry the trapezoid state across the period seam: a converged step
        // leaves i_prev = -f(x), so at x0 it is -rhs. A zero seed loses
        // dt*i0/2 of charge per period. Being a function of x0, it sits
        // inside the shooting Jacobian.
        // ponytail: masked to rows with a diagonal C entry, since an unmasked
        // seed rings undamped on algebraic rows; charge without a diagonal C
        // entry keeps a zero seed.
        sc.i_prev[0] = 0;
        for (1..n) |i| sc.i_prev[i] = if (ckt.c_vals[ckt.diag_slots[i]] != 0) -ckt.rhs[i] else 0;
    }
    if (wave.len != 0) {
        const row = wave[0 .. 1 + probes.len];
        row[0] = 0;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
    }
}

/// The end time of step k of a period.
fn stepTime(options: Options, k: usize) f64 {
    return options.period * @as(f64, @floatFromInt(k + 1)) / @as(f64, @floatFromInt(options.n_samples));
}

/// The companion hook of one step at `alpha` = 2/dt.
fn periodHook(sc: *Companion, alpha: f64, has_charge: bool) PeriodHook {
    return .{
        .method = {},
        .c = .{ .ag0 = alpha, .ag2 = 0 },
        .q_prev = sc.q_prev,
        .i_prev = sc.i_prev,
        .q_cur = sc.q_cur,
        .a_vals = sc.a_vals,
        .has_charge = has_charge,
    };
}

/// Step k's end: a failed Newton reverts the devices and fails the
/// period (false); a converged one commits them, advances the trapezoid
/// history and records wave row k + 1 at t.
fn periodAccept(ckt: *root.Circuit, hook: *const PeriodHook, x: []const f64, probes: []const u32, wave: []f64, k: usize, t: f64, converged: bool) bool {
    if (!converged) {
        _ = ckt.stateCtl(.revert);
        return false;
    }
    _ = ckt.stateCtl(.commit);
    if (hook.has_charge) hook.accept(ckt.n);
    if (wave.len != 0) {
        const ncols = 1 + probes.len;
        const row = wave[(k + 1) * ncols ..][0..ncols];
        row[0] = t;
        for (probes, 0..) |node, p| row[1 + p] = x[node];
    }
    return true;
}
```

Bitwise notes: `t` and `dt` are the same expressions (`stepTime` is
pss.zig:113 verbatim); `alpha = 2.0 / dt` with the same `dt`; today's
`hook.accept(n)` with `n = ckt.n` and `has_charge = ckt.has_charge` is
`hook.accept(ckt.n)` gated on `hook.has_charge`, the same value.
`integrateFrom` (pss.zig:148-158) is unchanged.

### Step 2. `Shoot`: `solve` as a resumable machine (replaces pss.zig:294-410)

Insert before `solve`:

```zig
/// One shooting solve between its period integrations, so `solve` and
/// `runLanes` share every step but the integration: `next` names the
/// period the solve needs, the caller integrates it, `done` consumes the
/// outcome. The statements are `solve`'s own, in its order. Pinned once
/// `init` ran: `sc` and `krylov` are reached by pointer.
const Shoot = struct {
    ckt: *root.Circuit,
    ws: *converger.Workspace,
    probes: []const u32,
    wave: []f64,
    /// The query's options; `opts` carries the period the solve is at.
    options: Options,
    opts: Options,
    allocator: std.mem.Allocator,
    n: usize,
    arena: []f64,
    x0: []f64,
    x_end: []f64,
    phi: []f64,
    x0_pert: []f64,
    x_end_pert: []f64,
    dx0: []f64,
    /// Dense path's FD Jacobian (n*n), else empty.
    j_phi: []f64,
    /// Krylov path's right-hand side (n), else empty.
    neg_phi: []f64,
    sc: Companion,
    krylov: ?Gmres,
    iter: u16 = 0,
    res_norm: f64 = std.math.inf(f64),
    stage: Stage = .base,
    /// The FD column the `.column` stage integrates next.
    col: usize = 0,
    /// Set when `stage` reaches `.done`.
    result: SolveResult = undefined,

    const Stage = enum { base, column, final, done };

    /// One period integration: `x` holds its start and receives its end;
    /// a non-empty `wave` records it as `integrateOnePeriod` documents.
    const Request = struct { x: []f64, probes: []const u32, wave: []f64, opts: Options };

    /// `solve`'s setup: buffers, the GMRES workspace past
    /// `krylov_threshold`, the baseline, and for an autonomous circuit the
    /// oscillator start. Errors as `solve`'s; on error nothing is held.
    fn init(s: *Shoot, ckt: *root.Circuit, x_dc: []const f64, probes: []const u32, wave: []f64, options: Options, allocator: std.mem.Allocator) !void {
        const n: usize = ckt.n;
        const nnz: usize = ckt.nnz;
        const ncols = 1 + probes.len;
        std.debug.assert(wave.len == 0 or wave.len == (@as(usize, options.n_samples) + 1) * ncols);
        @memset(wave, 0);

        const use_krylov = n >= krylov_threshold;
        // One block for the whole continuation, every size known up front:
        //   x0, x_end, phi, x0_pert, x_end_pert, dx0   6n
        //   q_prev, q_cur, i_prev                      3n
        //   a_vals                                     nnz
        //   j_phi (dense) or neg_phi (Krylov)          n*n or n
        const dense_extra = if (!use_krylov) n * n else 0;
        const krylov_extra = if (use_krylov) n else 0;
        const arena = try allocator.alloc(f64, 9 * n + nnz + dense_extra + krylov_extra);
        errdefer allocator.free(arena);
        var off: usize = 0;
        const x0 = take(arena, &off, n);
        const x_end = take(arena, &off, n);
        const phi = take(arena, &off, n);
        const x0_pert = take(arena, &off, n);
        const x_end_pert = take(arena, &off, n);
        const dx0 = take(arena, &off, n);
        const sc: Companion = .{
            .q_prev = take(arena, &off, n),
            .q_cur = take(arena, &off, n),
            .i_prev = take(arena, &off, n),
            .a_vals = take(arena, &off, nnz),
        };
        // The unused path's buffer slices the arena to zero length so both
        // stay mutable []f64.
        const j_phi = if (!use_krylov) arena[off..][0 .. n * n] else arena[0..0];
        const neg_phi = if (use_krylov) arena[off..][0..n] else arena[0..0];
        var krylov: ?Gmres = null;
        if (use_krylov) {
            const m = @min(options.gmres_restart, @as(u32, @intCast(n)));
            krylov = try Gmres.init(allocator, @intCast(n), m);
        }
        errdefer if (krylov) |*k| k.deinit(allocator);

        try ckt.computeBaseline();
        const ws = try ckt.workspace();
        s.* = .{
            .ckt = ckt,
            .ws = ws,
            .probes = probes,
            .wave = wave,
            .options = options,
            .opts = options,
            .allocator = allocator,
            .n = n,
            .arena = arena,
            .x0 = x0,
            .x_end = x_end,
            .phi = phi,
            .x0_pert = x0_pert,
            .x_end_pert = x_end_pert,
            .dx0 = dx0,
            .j_phi = j_phi,
            .neg_phi = neg_phi,
            .sc = sc,
            .krylov = krylov,
        };
        num.copySimd(x0, x_dc[0..n]);
        if (options.osc_node != root.GROUND) s.opts.period = try startOscillator(ckt, ws, &s.sc, x0, options, allocator);
    }

    fn deinit(s: *Shoot) void {
        if (s.krylov) |*k| k.deinit(s.allocator);
        s.allocator.free(s.arena);
        s.* = undefined;
    }

    /// The next period the solve needs, or null once `result` is set.
    /// Fails only when a checkpoint cancels.
    fn next(s: *Shoot) error{QueryCancelled}!?Request {
        const n = s.n;
        sw: switch (s.stage) {
            .base => {
                if (s.iter >= s.options.max_shooting_iter) {
                    s.stage = .final;
                    continue :sw .final;
                }
                if (s.iter != 0) try s.ckt.checkpoint(.{ .phase = .periodic, .completed = s.iter });
                // integrateFrom(x0 -> x_end).
                num.copySimd(s.x_end, s.x0);
                return .{ .x = s.x_end, .probes = &.{}, .wave = &.{}, .opts = s.opts };
            },
            .column => {
                // denseFdSolve's column `col`.
                const j = s.col;
                num.copySimd(s.x0_pert[0..n], s.x0[0..n]);
                var o = s.opts;
                if (o.osc_node != root.GROUND and j == o.osc_node) o.period *= 1 + o.fd_epsilon else s.x0_pert[j] += o.fd_epsilon;
                num.copySimd(s.x_end_pert, s.x0_pert);
                return .{ .x = s.x_end_pert, .probes = &.{}, .wave = &.{}, .opts = o };
            },
            .final => {
                num.copySimd(s.x_end, s.x0);
                return .{ .x = s.x_end, .probes = s.probes, .wave = s.wave, .opts = s.opts };
            },
            .done => return null,
        }
    }

    /// Consumes the outcome of the request `next` returned: `ok` is that
    /// integration's return. Errors as `solve`'s: a Krylov solve's
    /// cancellation or memory, `dense_lu`'s singular Jacobian.
    fn done(s: *Shoot, ok: bool) !void {
        const n = s.n;
        switch (s.stage) {
            .base => {
                if (!ok) {
                    s.result = .{ .converged = false, .iterations = s.iter, .residual_norm = std.math.inf(f64) };
                    s.stage = .done;
                    return;
                }
                // x_end + (-1)*x0 is exactly x_end - x0.
                num.copySimd(s.phi, s.x_end);
                num.axpy(s.phi, -1.0, s.x0);
                s.res_norm = num.normInf(s.phi);
                if (s.res_norm < s.options.shooting_tol) {
                    s.stage = .final;
                    return;
                }
                if (s.krylov) |*k| {
                    // ponytail: unpreconditioned; add an ILU preconditioner if GMRES stalls.
                    try krylovSolve(s.ckt, s.ws, &s.sc, n, s.x0, s.phi, s.x0_pert, s.x_end_pert, s.dx0, s.neg_phi, k, s.opts);
                    s.update();
                } else {
                    s.stage = .column;
                    s.col = 0;
                }
            },
            .column => {
                const j = s.col;
                if (!ok) {
                    for (0..n) |row| s.j_phi[row * n + j] = if (row == j) @as(f64, 1.0) else @as(f64, 0.0);
                } else {
                    // Column j is stride n in row-major J, so the store stays scalar.
                    const col = s.x_end_pert[0..n];
                    fdColumn(col, col, s.x0_pert[0..n], s.phi[0..n], 1.0 / s.opts.fd_epsilon);
                    for (col, 0..) |d, row| s.j_phi[row * n + j] = d;
                }
                s.col += 1;
                if (s.col < n) return;
                try dense_lu.factorizeSolveNeg(n, s.j_phi, s.phi[0..n], s.dx0);
                s.stage = .base;
                s.update();
            },
            .final => {
                if (!ok) @memset(s.wave, 0);
                s.result = .{ .converged = s.res_norm < s.options.shooting_tol, .iterations = s.iter, .residual_norm = s.res_norm };
                s.stage = .done;
            },
            .done => unreachable,
        }
    }

    /// The damped Newton update that ends a shooting iteration.
    fn update(s: *Shoot) void {
        var damping: f64 = 1.0;
        const osc = s.options.osc_node;
        if (osc != root.GROUND) {
            const d_ln_t = s.dx0[osc];
            s.dx0[osc] = 0;
            if (@abs(d_ln_t) > max_period_step) damping = max_period_step / @abs(d_ln_t);
            s.opts.period *= 1 + damping * d_ln_t;
        }
        num.axpy(s.x0, damping, s.dx0);
        s.iter += 1;
    }
};
```

Then `solve` keeps its doc comment (pss.zig:294-305) and becomes:

```zig
pub fn solve(
    ckt: *root.Circuit,
    x_dc: []const f64,
    probes: []const u32,
    wave: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    var s: Shoot = undefined;
    try s.init(ckt, x_dc, probes, wave, options, allocator);
    defer s.deinit();
    while (try s.next()) |r| try s.done(try integrateOnePeriod(ckt, s.ws, &s.sc, r.x, r.probes, r.wave, r.opts));
    return s.result;
}
```

Delete `denseFdSolve` (pss.zig:219-256): its body now lives in
`next(.column)` and `done(.column)`.

Line-by-line map to today's `solve`, for the reviewer:

| today | now |
|---|---|
| :314-358 buffers, krylov, baseline, ws | `init` |
| :360-363 x0, `startOscillator` | `init` tail |
| :368 `while (iter < max)` | `next(.base)` first test |
| :369 checkpoint | `next(.base)` |
| :370 `integrateFrom(x0, x_end)` | `next(.base)` copy + caller's integration |
| :371-376 failed base | `done(.base)` `!ok` |
| :379-383 phi, norm, break | `done(.base)` |
| :385-390 Krylov or dense | `done(.base)` / `next(.column)` + `done(.column)` |
| :392-399 damping, axpy; loop `iter += 1` | `update` |
| :402-403 final period, wave zeroed on failure | `next(.final)` + `done(.final)` |
| :405-409 result | `done(.final)` |

`CHECK:` `continue :sw .final` inside a labelled `switch` on an enum
field: legal since Zig 0.14; the tree uses labelled switch continues
elsewhere? If not, replace with `while (true) switch (s.stage)` and set
`s.stage` before `continue`.

### Step 3. `integrateLanes` and `runLanes` (append after `run`, pss.zig:523)

```zig
/// `integrateOnePeriod` for every lane of `m`, lane l on `shots[l]` and
/// request `reqs[l]`: the start, commit/revert, history and wave rows run
/// per lane and each step's Newton runs as lanes, so lane l is bitwise its
/// scalar integration. Returns the lanes whose period completed. Every
/// request takes the same `n_samples` (one batch shares its options; an
/// autonomous lane's own period changes only its t and dt). Cancellation
/// and memory fail every lane.
fn integrateLanes(
    comptime W: usize,
    sys: *LaneSys(W),
    lws: *converger.LaneWorkspace(W),
    xv: []Lanes(W).V,
    shots: *[W]Shoot,
    reqs: *const [W]Shoot.Request,
    m: Lanes(W).Mask,
) !Lanes(W).Mask {
    const L = Lanes(W);
    const S = LaneSys(W);
    const steps: usize = reqs[@ctz(m)].opts.n_samples;
    var it = L.each(m);
    while (it.next()) |l| {
        std.debug.assert(reqs[l].opts.n_samples == steps);
        periodStart(shots[l].ckt, &shots[l].sc, reqs[l].x, reqs[l].probes, reqs[l].wave, reqs[l].opts);
    }
    var live = m;
    var hooks: [W]PeriodHook = undefined;
    var times: [W]f64 = @splat(0);
    for (0..steps) |k| {
        if (!L.any(live)) break;
        it = L.each(live);
        while (it.next()) |l| {
            const o = reqs[l].opts;
            const ckt = shots[l].ckt;
            const dt = o.period / @as(f64, @floatFromInt(steps));
            times[l] = stepTime(o, k);
            hooks[l] = periodHook(&shots[l].sc, 2.0 / dt, ckt.has_charge);
            sys.hooks[l] = hooks[l];
            ckt.setSimState(.{ .t = times[l], .dt = dt, .kind = .tran });
            S.putLane(xv, reqs[l].x, l);
        }
        sys.active = live;
        const o0 = reqs[@ctz(live)].opts;
        const res = converger.newtonLanes(W, sys, lws, xv, times, .{
            .max_iter = o0.max_newton_iter,
            .abstol = o0.newton_tol,
        }, S.LaneHook{});
        // As `converger.run` ends each lane's solve.
        it = L.each(live);
        while (it.next()) |l| shots[l].ckt.clearLimits();
        const r = try res;
        it = L.each(live);
        while (it.next()) |l| {
            S.getLane(reqs[l].x, xv, l);
            const bit = @as(L.Mask, 1) << @intCast(l);
            const ok = r.converged & bit != 0 and r.singular & bit == 0;
            if (!periodAccept(shots[l].ckt, &hooks[l], reqs[l].x, reqs[l].probes, reqs[l].wave, k, times[l], ok)) live &= ~bit;
        }
    }
    return live;
}

/// `run` for the lanes of one batch: `.pss` queries on one pattern, each
/// from its own operating point and variant row (#210). Each lane keeps
/// its own shooting loop, FD columns, monodromy LU, GMRES and period; the
/// period integrations of a round run together, one lane Newton per time
/// step (`integrateLanes`). A Krylov lane's matvecs run scalar inside its
/// own `done`. Lane l's result lands in `out[l]`, bitwise `run` on
/// `ctxs[l]`. Under a JFNK pin or `-Dcertify` every lane runs `run`.
/// Asserts 1 <= `ctxs.len` <= W.
pub fn runLanes(comptime W: usize, ctxs: []const root.RunCtx, opts: Options, out: []LaneOutcome) void {
    const g = ctxs.len;
    std.debug.assert(g >= 1 and g <= W and out.len == g);
    const pin = ctxs[0].circuit.knobs.newton.pin;
    if (W == 1 or g == 1 or !(pin == .auto or pin == .direct) or root.Circuit.certify) {
        for (ctxs, out) |*c, *o| o.* = run(c, opts);
        return;
    }
    const L = Lanes(W);
    const S = LaneSys(W);
    var shots: [W]Shoot = undefined;
    var names: [W][]const []const u8 = undefined;
    var data: [W][]f64 = undefined;
    var live: L.Mask = 0;
    for (ctxs, 0..) |*c, l| {
        start(c, opts, &shots[l], &names[l], &data[l]) catch |e| {
            out[l] = e;
            continue;
        };
        live |= @as(L.Mask, 1) << @intCast(l);
    }
    defer {
        var it = L.each(live);
        while (it.next()) |l| shots[l].deinit();
    }
    const kill = struct {
        fn f(sh: []Shoot, m: *L.Mask, o: []LaneOutcome, l: usize, err: LaneError) void {
            o[l] = err;
            sh[l].deinit();
            m.* &= ~(@as(L.Mask, 1) << @intCast(l));
        }
    }.f;
    // Every lane fails with the batch's own error (cancel, out of memory).
    const fail = struct {
        fn f(sh: []Shoot, m: *L.Mask, o: []LaneOutcome, err: LaneError) void {
            var it = L.each(m.*);
            while (it.next()) |l| {
                o[l] = err;
                sh[l].deinit();
            }
            m.* = 0;
        }
    }.f;
    if (live == 0) return;
    const first = @ctz(live);
    var lanes: [W]*root.Circuit = undefined;
    var wss: [W]*converger.Workspace = undefined;
    for (&lanes, &wss, 0..) |*c, *w, l| {
        // Unused lanes repeat the first live one and stay inactive.
        const k = if (l < g and (live >> @intCast(l)) & 1 != 0) l else first;
        c.* = shots[k].ckt;
        w.* = shots[k].ws;
    }
    const gpa = ctxs[first].scratch_allocator;
    // The hook only sizes the value plane here (alpha 0 rewrites `a_vals`
    // as G, which every assemble overwrites); each step sets its own.
    var sys = S.init(gpa, lanes, periodHook(&shots[first].sc, 0, lanes[first].has_charge)) catch |e| return fail(&shots, &live, out, e);
    defer sys.deinit(gpa);
    var lws = converger.LaneWorkspace(W).init(gpa, wss) catch |e| return fail(&shots, &live, out, e);
    defer lws.deinit(gpa);
    const xv = gpa.alloc(L.V, lanes[first].n) catch |e| return fail(&shots, &live, out, e);
    defer gpa.free(xv);

    var reqs: [W]Shoot.Request = undefined;
    while (true) {
        var round: L.Mask = 0;
        var it = L.each(live);
        while (it.next()) |l| {
            const bit = @as(L.Mask, 1) << @intCast(l);
            const r = shots[l].next() catch |e| {
                kill(&shots, &live, out, l, e);
                continue;
            };
            if (r) |req| {
                reqs[l] = req;
                round |= bit;
                continue;
            }
            out[l] = finish(shots[l].result, names[l], data[l], opts);
            shots[l].deinit();
            live &= ~bit;
        }
        if (round == 0) break;
        const ok = integrateLanes(W, &sys, &lws, xv, &shots, &reqs, round) catch |e| return fail(&shots, &live, out, e);
        it = L.each(round);
        while (it.next()) |l| shots[l].done(ok & (@as(L.Mask, 1) << @intCast(l)) != 0) catch |e| kill(&shots, &live, out, l, e);
    }
}

const LaneError = root.ErrorOf(run);
/// One lane's `run` outcome.
pub const LaneOutcome = LaneError!root.Result;
```

`run` (pss.zig:498-523) is rewritten over two helpers that `runLanes`
shares, so the lanes publish exactly what `run` publishes:

```zig
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    try ctx.circuit.refuseDigital("pss");
    const names = try root.probeNames(ctx, "time");
    const data = try ctx.allocator.alloc(f64, (@as(usize, opts.n_samples) + 1) * names.len);
    errdefer ctx.allocator.free(data);
    const res = try solve(ctx.circuit, ctx.x_op, ctx.probes, data, opts, ctx.scratch_allocator);
    return finish(res, names, data, opts);
}

/// `run`'s setup for a lane: the same refusals, names and row buffer,
/// then the shooting state in `shot`.
fn start(ctx: *const root.RunCtx, opts: Options, shot: *Shoot, names: *[]const []const u8, data: *[]f64) !void {
    try ctx.circuit.refuseDigital("pss");
    names.* = try root.probeNames(ctx, "time");
    data.* = try ctx.allocator.alloc(f64, (@as(usize, opts.n_samples) + 1) * names.len);
    errdefer ctx.allocator.free(data.*);
    try shot.init(ctx.circuit, ctx.x_op, ctx.probes, data.*, opts, ctx.scratch_allocator);
}

/// The published period. Non-convergence prints a warning and still
/// returns the last period.
fn finish(res: SolveResult, names: []const []const u8, data: []f64, opts: Options) root.Result {
    if (!res.converged)
        std.debug.print("Warning: pss: shooting did not converge (residual {e})\n", .{res.residual_norm});
    return .{
        .plotname = "Periodic Steady State",
        .varnames = names,
        .is_complex = false,
        .npoints = @as(usize, opts.n_samples) + 1,
        .data = data,
    };
}
```

`CHECK:` (a) phase 3's `LaneSystem` API: this plan assumes `init(gpa,
lanes, hook)` stores `hook` in every slot of a new `hooks: [W]Hook`
field and that `LaneHook.assemble`/`vals`/`loadCheck` read
`sys.hooks[l]`. Adjust the two `sys.hooks[l] = ...` / `S.init` lines to
the API phase 3 lands. (b) `try res` in `integrateLanes`: its inferred
set is `newtonLanes`'s, which `dc.runLanes` already coerces into its
`LaneError`; here it must coerce into `pss.LaneError` (cancellation and
memory, both in `run`'s set). (c) `times` is `[W]f64` passed as
`Lanes(W).V`: array-to-vector coercion; if refused, build `var tv: L.V`
via `S.putLane`-style writes. (d) `ctxs[l].allocator.free(data[l])` on
`kill`: not done, the results arena owns it (matches `run`'s errdefer
on an arena, which is a no-op there too).

### Step 4. Executor (src/analysis/executor.zig)

Import beside `dc` (executor.zig:14):

```zig
const pss = @import("pss/pss.zig");
```

In `executeBatch` (executor.zig:312), widen the assert (executor.zig:314;
phase 3 has already added `.tran`):

```zig
        std.debug.assert(g <= lane_width and (self.job == .op or self.job == .dc or self.job == .tran or self.job == .pss));
```

Fold the `.dc` branch (executor.zig:336-353) and phase 3's `.tran`
branch into one generic branch that `.pss` joins. Replace the `if
(self.job == .dc) { ... }` block with:

```zig
        switch (self.job) {
            // Every laned analysis past the OP: each lane runs from its own
            // circuit and context, and publishes as it would alone.
            inline .dc, .tran, .pss => |opts, tag| {
                const M = module(tag);
                const transient = @as(requests.Kind, self.job).transient();
                var ctxs: [lane_width]types.RunCtx = undefined;
                for (live[0..n_live], 0..) |k, l| {
                    members[k].circuit.setSimState(.{ .kind = if (transient) .ic else .dc });
                    ctxs[l] = members[k].runCtx();
                }
                var swept: [lane_width]M.LaneOutcome = undefined;
                if (n_live != 0) M.runLanes(lane_width, ctxs[0..n_live], opts, swept[0..n_live]);
                for (live[0..n_live], swept[0..n_live]) |k, o| {
                    outcomes[k] = if (o) |r| members[k].label(r) else |err| err;
                    members[k].refuseLatched() catch |err| {
                        outcomes[k] = err;
                    };
                }
                return outcomes[0];
            },
            else => {},
        }
```

`.dc`'s sim state stays `.dc` (`Kind.dc.transient()` is false), as the
removed lines set it; `.pss` gets `.ic`, as `runQuery` sets for every
transient kind (executor.zig:443-453). If phase 3's `tran.runLanes` takes
anything beyond `(W, ctxs, opts, out)`, keep its own branch and add only
`.pss` here. `CHECK:` `inline .dc, .tran, .pss => |opts, tag|` on a
`union(Kind)` gives each prong its payload type; `module(tag)` is
comptime (executor.zig:641).

### Step 5. Session grouping (src/analysis/session.zig)

`gather` (session.zig:477-478): the kind test.

```zig
        if (!lanedKind(jobs[i]) or self.rows.items(.executor)[i] != null) return;
```

`sameLaneJob` (session.zig:1022-1027):

```zig
fn sameLaneJob(a: requests.Query, b: requests.Query) bool {
    return switch (a) {
        inline .op, .dc, .tran, .pss => |o, tag| b == tag and sameDeep(stripTol(o), stripTol(@field(b, @tagName(tag)))),
        else => false,
    };
}

/// The kinds `Executor.executeBatch` runs as lanes. Not the HB, PAC and
/// noise families: their lanes would all peel to W = 1, which only
/// serializes queries `--jobs` runs in parallel (#210 plan §1.1).
fn lanedKind(job: requests.Query) bool {
    return switch (job) {
        .op, .dc, .tran, .pss => true,
        else => false,
    };
}
```

(Drop `.tran` from both if phase 3 spelled them differently; the point is
adding `.pss`.) Update `gather`'s doc comment (session.zig:464-468) from
"`.op` or `.dc` row" to "a row of a `lanedKind`".

### Step 6. Docs

- `dev/research/lane-batched-simulation.md` §6, shooting row: "fixed-step
  trapezoid periods run as lanes, one lane Newton per step; FD columns,
  monodromy LU, GMRES and damping per lane, scalar"; HB/MHB and PAC rows:
  "phase 6b, GPU only (plan §1.1)". §11 phase 6 row: effort and gate as
  §6 below.
- `executor.zig` `lanesOn` doc and `Config.lanes` doc (executor.zig:60):
  "operating points, `.dc`, `.tran` and `.pss`".

## 3. W = 1 identity and codegen probes

- **No new probe.** No scalar arithmetic becomes W-generic: `Shoot`
  reorders control flow only, `integrateLanes` exists only at W >= 2, and
  `Gmres` stays scalar (a masked per-lane GMRES would need a
  `gen_gmres`/`hand_gmres` IDENTICAL pair; it buys nothing on the CPU and
  is deferred to the GPU phase with its kernels). The existing
  `gen_newton`, `gen_update_and_norm` and `gen_hook_trap_assemble` probes
  already cover the Newton and the `PeriodHook` that lanes call.
- **W = 1 byte identity of the refactor** (step 1-2 changes every
  `.pss`, `.pac`, `.pxf`, `.pnoise`, `.hbosc`, `.phasenoise` run). Build
  `espice` at main and at the branch (Debug is enough), then, from the
  repo root:

```sh
for d in tests/fixtures/{pss,pac,pxf,pnoise,phasenoise,hb,hbac,hbxf,hbnoise,qpss}/*.sp; do
  (cd "$(dirname "$d")" && $OLD --format=binary -b -r /tmp/p6_old.raw "$(basename "$d")" >/dev/null 2>&1; \
   $NEW --format=binary -b -r /tmp/p6_new.raw "$(basename "$d")" >/dev/null 2>&1; \
   cmp -s /tmp/p6_old.raw /tmp/p6_new.raw || echo "DIFF $d")
done
```

  Zero `DIFF` lines is the gate. (`test-correctness` alone is not enough:
  it compares to tolerance.)
- **Batched vs unbatched**: the same loop with `ESPICE_LANES=0 $NEW
  --jobs=1` against `ESPICE_LANES=1 $NEW --jobs=1`, over
  `tests/fixtures/variants/*.sp` and the two decks §4.2 writes to
  `zig-out/` (the corpus has no swept `.pss`).

## 4. Tests

### 4.1 Session: swept `.pss` rows, mixed and replicated (src/analysis/tests/session.zig)

After "lane batches: a NaN value, failing, peeling and re-pivoting lanes
..." (session.zig:536-616), add:

```zig
test "lane batches: .pss rows on variant rows equal their runs alone bitwise, replicated, failing and NaN lanes included (#210)" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    // A half-wave rectifier (tests/fixtures/pss/diode_rectifier_rc.sp):
    // nonlinear, charge-carrying, and on the dense FD path (n < 50).
    const vin = try b.addNode();
    const a = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 0, .waveform = 2, .sin_vo = 0, .sin_va = 2, .sin_freq = 1e3 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 100 }, &.{}, .{ vin, a });
    try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ a, out });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ out, GROUND });
    try b.addDevice(models.capacitor, "", &.{ .c = 100e-9 }, &.{}, .{ out, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    // Variant k writes the load resistor's `r` (the second resistor).
    var probe = try @import("../types.zig").Circuit.instantiate(&prepared, t.allocator);
    defer probe.deinit();
    const params = try probe.collectParams();
    const r_ref: u32 = for (params, 0..) |p, k| {
        if (p.type == builtin("resistor") and p.index == 1 and std.mem.eql(u8, p.param_name, "r")) break @intCast(k);
    } else return error.TestUnexpectedResult;
    // Three copies of 1k (replication), a NaN, a near-short, and spread loads.
    const values = [_]f64{ 1e3, 2e3, 1e3, std.math.nan(f64), 500, 1e-30, 1e3, 5e3, 1e5 };
    var labels: [values.len][]const u8 = undefined;
    var starts: [values.len + 1]u32 = undefined;
    var refs: [values.len]u32 = undefined;
    var temps: [values.len]?f64 = undefined;
    for (&labels, starts[0..values.len], &refs, &temps, 0..) |*l, *s0, *r, *tc, k| {
        l.* = "rl";
        s0.* = @intCast(k);
        r.* = r_ref;
        tc.* = null;
    }
    starts[values.len] = values.len;
    var deck = bareDeck(&.{ vin, out }, &.{ "v(in)", "v(out)" });
    deck.variants = .{ .labels = &labels, .temp_c = &temps, .starts = &starts, .refs = &refs, .values = &values };
    var jobs: [values.len]requests.Query = undefined;
    for (&jobs, 0..) |*j, k| j.* = .{ .pss = .{ .period = 1e-3, .n_samples = 64, .tol = .{ .variant = @intCast(k) } } };
    const Row = struct { status: Status, failure: ?@import("../session.zig").Failure, data: []f64 };
    var rows: [2][jobs.len]Row = undefined;
    var batched: usize = 0;
    for ([_]bool{ false, true }, &rows) |lanes, *got| {
        var config: @import("../executor.zig").Config = .{};
        config.knobs.lanes = lanes;
        var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
        defer s.deinit();
        var ids: [jobs.len]requests.QueryId = undefined;
        _ = try s.append(&jobs, &ids);
        try s.runAll(.{ .max_parallel = 1, .quantum = .completion });
        for (s.rows.items(.executor), s.rows.items(.job)) |e, j| if (e) |x| {
            if (j == .pss) batched += x.peers.len;
        };
        for (ids, got) |id, *r| {
            const q = try s.info(id);
            r.* = .{ .status = q.status, .failure = q.failure, .data = &.{} };
            if (q.status == .complete) r.data = try t.allocator.dupe(f64, (try s.result(id)).data);
        }
    }
    defer for (rows) |rs| for (rs) |r| t.allocator.free(r.data);
    try t.expect(batched > 0);
    var completed: usize = 0;
    for (rows[0], rows[1]) |alone, laned| {
        try t.expectEqual(alone.status, laned.status);
        try t.expectEqual(alone.failure, laned.failure);
        try t.expectEqualSlices(u64, @ptrCast(alone.data), @ptrCast(laned.data));
        completed += @intFromBool(alone.status == .complete);
    }
    // The three 1k rows are one another bitwise, alone and as lanes.
    for ([_]usize{ 2, 6 }) |k| try t.expectEqualSlices(u64, @ptrCast(rows[1][0].data), @ptrCast(rows[1][k].data));
    // The NaN row must fail; most finish.
    try t.expect(completed > jobs.len / 2 and completed < jobs.len);
}
```

`CHECK:` the `models.vsource` sine fields are spelled as in
`tests/periodic.zig:181`; `diode` takes `.is`. If the NaN row instead
completes (a NaN load may OP-fail first, which is what the test wants:
its `.pss` then fails as a dependency), keep the `completed < jobs.len`
assertion only if some row fails; otherwise swap NaN for `-1e3`.

### 4.2 End to end: `.step`, Krylov lanes, autonomous lanes (src/tests/espice.zig)

After the per-lane stimulus test (espice.zig:1709-1729), add:

```zig
/// Every requested `.pss` result of `source`, in request order, with
/// `.lanes` on or off.
fn pssRows(source: []const u8, lanes: bool) ![]f64 {
    const p = try api.Problem.init(t.allocator, t.io, .{
        .source = .{ .bytes = .{ .data = source, .origin = "pss_lanes.sp" } },
        .backend = .{ .lanes = lanes },
    });
    defer p.deinit();
    try p.run_all();
    var rows: std.ArrayList(f64) = .empty;
    errdefer rows.deinit(t.allocator);
    for (0..p.query_count()) |i| {
        const id: api.QueryId = @fromBackingInt(@intCast(i));
        const info = try p.query_info(id);
        if (!info.requested or info.kind != .pss) continue;
        try rows.appendSlice(t.allocator, (try p.result(id)).data);
    }
    return rows.toOwnedSlice(t.allocator);
}

test "pss lanes (#210): a .step sweep of shooting solves is bitwise each point alone, dense and Krylov" {
    // Dense FD path: the rectifier of tests/fixtures/pss, load swept.
    const dense =
        \\* swept rectifier
        \\.param rl=1k
        \\Vin in 0 SIN(0 2 1k)
        \\Rsrc in a 100
        \\D1 a out dm
        \\Rload out 0 {rl}
        \\C1 out 0 100n
        \\.model dm D(is=1e-14 rs=1)
        \\.step param rl list 500 1k 1k 2k 4k 8k 16k 32k 64k
        \\.pss 1k 64
        \\.end
        \\
    ;
    // Krylov path (n >= 50): a diode into a 50-stage RC ladder.
    var krylov: std.Io.Writer.Allocating = .init(t.allocator);
    defer krylov.deinit();
    try krylov.writer.writeAll("* swept ladder\n.param rl=1k\nVin in 0 SIN(0 2 1k)\nD1 in n0 dm\n");
    for (1..51) |k| try krylov.writer.print("R{d} n{d} n{d} 100\nC{d} n{d} 0 1n\n", .{ k, k - 1, k, k, k });
    try krylov.writer.writeAll("Rload n50 0 {rl}\n.model dm D(is=1e-14)\n.step param rl list 1k 2k 4k 8k 16k\n.pss 1k 32\n.end\n");
    for ([_][]const u8{ dense, krylov.written() }) |source| {
        const alone = try pssRows(source, false);
        defer t.allocator.free(alone);
        const laned = try pssRows(source, true);
        defer t.allocator.free(laned);
        try t.expect(alone.len > 0);
        try t.expectEqualSlices(u64, @ptrCast(alone), @ptrCast(laned));
    }
}

test "pss lanes (#210): autonomous shooting solves keep their own periods as lanes" {
    // tests/fixtures/pss/ring_oscillator.sp's ring with its RC swept: each
    // lane starts its own oscillator and solves its own period.
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, "tests/fixtures/pss/ring_oscillator.sp", t.allocator, .unlimited);
    defer t.allocator.free(source);
    // CHECK: splice a `.param c=1n` + `.step param c list 0.8n 1n 1.2n 1.5n`
    // into the deck and make one capacitor read `{c}`; the ring deck's
    // exact card text decides the replace below.
    const swept = try std.mem.replaceOwned(u8, t.allocator, source, ".end", ".param cx=1n\nCx c1 0 {cx}\n.step param cx list 0.1n 0.2n 0.3n 0.4n\n.end");
    defer t.allocator.free(swept);
    const alone = try pssRows(swept, false);
    defer t.allocator.free(alone);
    const laned = try pssRows(swept, true);
    defer t.allocator.free(laned);
    try t.expect(alone.len > 0);
    try t.expectEqualSlices(u64, @ptrCast(alone), @ptrCast(laned));
}
```

`CHECK:` `.step param` fans out `.pss` per point (analyses.zig
`copyVariants` is applied to every job, analyses.zig:234); the ring deck
names its node `c1` (it does in `ring_oscillator_krylov.sp`; confirm in
`ring_oscillator.sp`). Cost: the Krylov deck is the slowest test here
(5 points × GMRES matvecs × 32 steps); in Debug expect tens of seconds.
Drop it to 3 points if it exceeds a minute.

### 4.3 The unbatched families stay unbatched (src/analysis/tests/session.zig)

```zig
test "lane batches: HB rows are never grouped (#210: their lanes would all peel)" {
    const t = std.testing;
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const vin = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(models.vsource, "", &.{ .dc = 0, .waveform = 2, .sin_vo = 0, .sin_va = 1, .sin_freq = 1e3 }, &.{}, .{ vin, GROUND });
    try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ vin, out });
    try b.addDevice(models.capacitor, "", &.{ .c = 1e-7 }, &.{}, .{ out, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    const deck = bareDeck(&.{out}, &.{"v(out)"});
    const jobs = [_]requests.Query{
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 3 } },
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 3 } },
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 3 } },
    };
    var config: @import("../executor.zig").Config = .{};
    config.knobs.lanes = true;
    var s = Session.init(t.allocator, t.io, &prepared, &deck, config);
    defer s.deinit();
    var ids: [jobs.len]requests.QueryId = undefined;
    _ = try s.append(&jobs, &ids);
    try s.runAll(.{ .max_parallel = 1, .quantum = .completion });
    try t.expectEqual(null, s.failure());
    for (s.rows.items(.executor)) |e| if (e) |x| try t.expectEqual(@as(usize, 0), x.peers.len);
}
```

### 4.4 Existing tests that must stay green unchanged

`src/analysis/tests/periodic.zig` (all, notably "pss and hb: an RC
low-pass lands on its analytic steady state", "pss: the Krylov path
converges to a periodic orbit", "periodic solves free everything on every
allocation failure": the last one drives `Shoot.init`'s errdefers through
every allocation), `test-correctness` over `pss/`, `pac/`, `pxf/`,
`pnoise/`, `phasenoise/`, `hb*/`, and §3's byte loop.

## 5. Risks, open questions, what only a build settles

1. **Phase 3's `LaneSystem` hook API** is assumed (`hooks: [W]Hook`,
   init-time fill, active-only `beginSolve`). A different shape changes
   three lines of step 3; a missing active-only `beginSolve` would call
   `beginSolve` on finished lanes, harmless for results (their outputs
   are already written) but worth fixing in phase 3.
2. **Zero gain on the CPU, by design.** `.pss` lanes are the oracle for a
   GPU shooting path, not a CPU speedup; with lanes off by default
   (`lanesOn`) nothing changes for users. Measure once
   (`ESPICE_LANES=1` vs `0` on the §4.2 dense deck) only to confirm no
   regression worse than #211's.
3. **Round imbalance.** A Krylov lane runs its whole GMRES inside `done`
   while the others wait, and a dense lane's n columns hold its partners
   to n+1 integrations per iteration even after they converge. Exact, but
   it means laning `.pss` on the GPU needs the (point, column) widening of
   §1.3 to be worth it.
4. **Inferred error sets** (`try res` in `integrateLanes`,
   `LaneError` coercions in `kill`/`fail`): a build settles them; the
   fallback is to widen `integrateLanes`'s return to an explicit
   `error{ QueryCancelled, OutOfMemory }!` and `catch` anything else into
   `fail`.
5. **Warnings order.** "Warning: pss: shooting did not converge" goes to
   stderr in lane-finish order, not query order. Output files are
   unaffected; a test that scrapes stderr would see it.
6. **Labelled `switch` continue** in `Shoot.next` (CHECK in step 2).
7. **The §11 gate is weak** without swept corpus decks; §4.1-4.2 are the
   real gate. If the owner wants corpus coverage, add
   `tests/fixtures/variants/step_pss_rectifier.sp` with an
   `expected.json` built from each point run alone (a self-oracle, so
   say so in its header).

Open for the owner: whether phase 6b (HB/MHB sample evals, MHB
`factorEach` over (point, line), masked GMRES, PAC/PNOISE shooting via
`Shoot` + phase 5's stacked sweep) is wanted before an A100 measurement
of phase 4. This plan assumes not.

## 6. Effort

| Step | Work | Effort |
|---|---|---|
| 1 | period helpers, `integrateOnePeriod` rebuilt on them | 0.25 d |
| 2 | `Shoot`, `solve` over it, `denseFdSolve` folded | 0.75 d |
| 3 | `integrateLanes`, `runLanes`, `start`/`finish` | 1 d |
| 4 | executor generic lane branch | 0.25 d |
| 5 | session `lanedKind`/`sameLaneJob` | 0.1 d |
| 6 | docs | 0.15 d |
| tests | §4.1-4.3, the §3 byte loops, fixes | 1 d |
| **total** | | **~3.5 days** (the doc's 3-4 weeks assumed masked HB, `factorEach` over (point, harmonic) and per-lane GMRES on the CPU; those move to a GPU-only phase 6b, est. 2-3 weeks after phase 4) |
