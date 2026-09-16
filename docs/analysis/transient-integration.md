# Transient Integration

BE / trapezoidal / Gear-2, TR-BDF2, LTE-based step control, breakpoints,
charge conservation.

## 1. Mathematical specification

### The circuit DAE and charge formulation

Transient analysis integrates the MNA differential-algebraic system

$$
F(x, t) \;=\; i(x) \;+\; \frac{d}{dt}q(x) \;+\; u(t) \;=\; 0,
$$

with $i(x)$ the resistive currents, $q(x)$ the node charges (and branch
fluxes), $u(t)$ the sources. **Charge conservation** requires discretizing
$q$ itself, never a capacitance-times-voltage product: the discrete update
must satisfy $\sum \Delta q = \int i\,dt$ exactly, which holds iff the
integrator's divided differences act on $q(x)$. (A $C(v)\,\dot v$
discretization leaks charge whenever $C$ varies over the step — the classic
SPICE2 MOS charge-pumping bug, Ward–Dutton charge models exist precisely for
this.) This engine stamps an exact $q(x)$ plane for the residual and the
analytic $C = \partial q/\partial x$ plane for the Jacobian — nothing is
lagged.

### One-step methods

With step $h = t_{m} - t_{m-1}$, define $\alpha$ and the dynamic residual
$F_{\text{dyn}}$ stamped per node:

**Backward Euler** (order 1, L-stable):

$$
\frac{q(x_m) - q(x_{m-1})}{h} \;\Rightarrow\;
F_{\text{dyn}} = \alpha\,(q(x_m) - q_{m-1}), \quad \alpha = \tfrac{1}{h}.
$$

**Trapezoidal** (order 2, A-stable, not L-stable):

$$
\frac{q(x_m)-q(x_{m-1})}{h} = \frac{\dot q_m + \dot q_{m-1}}{2}
\;\Rightarrow\;
F_{\text{dyn}} = \alpha\,(q(x_m) - q_{m-1}) - i_{m-1}, \quad \alpha = \tfrac{2}{h},
$$

where $i_{m-1} = \dot q_{m-1}$ is the previous accepted dynamic current,
updated by the same recurrence $i_m = \alpha(q_m - q_{m-1}) - i_{m-1}$.
Trap's residue at $z \to \infty$ is $-1$: an unresolved discontinuity
produces the well-known step-to-step ringing, which is why the flow drops
to BE at breakpoints.

**Gear-2 / BDF2** (order 2, L-stable), equal steps:

$$
F_{\text{dyn}} = \frac{3}{2h}\,(q_m - q_{m-1}) - \frac{1}{2h}\,(q_{m-1} - q_{m-2}),
\quad \alpha = \tfrac{3}{2h}.
$$

In all cases each Newton iteration solves

$$
\Big(G(x) + \alpha\,C(x)\Big)\,\Delta x = -\Big(F_{\text{res}}(x) + F_{\text{dyn}}(x)\Big),
$$

one axpy over the nnz combines the analytic $G$ and $C$ planes.

### TR-BDF2

*(derived, not source-verified — Bank, Coughran, Fichtner, Grosse, Rose,
Smith, IEEE Trans. CAD 4(4) 1985, is paywalled)*

One composite step $h$: a trapezoidal substep to $t + \gamma h$, then BDF2
over the pair. The TR stage has companion coefficient
$\alpha_{TR} = 2/(\gamma h)$, the BDF2 stage
$\alpha_{BDF2} = (2-\gamma)/((1-\gamma)h)$; the conventional
$\gamma = 2 - \sqrt2$ makes them equal ($\alpha = (2+\sqrt2)/h$), so one LU
serves both stages:

$$
\text{TR: } q(x_{m+\gamma}) - q(x_m) = \frac{\gamma h}{2}\big(\dot q_{m+\gamma} + \dot q_m\big),
$$

$$
\text{BDF2: } q(x_{m+1}) = \frac{1}{\gamma(2-\gamma)} q(x_{m+\gamma})
 - \frac{(1-\gamma)^2}{\gamma(2-\gamma)} q(x_m)
 + \frac{1-\gamma}{2-\gamma}\, h\,\dot q_{m+1}.
$$

Properties: second order, L-stable (no trap ringing), one embedded error
estimate free from the two stages,

$$
\text{LTE} \approx \frac{2 c_\gamma}{h}\Big(\tfrac{1}{\gamma} q_m - \tfrac{1}{\gamma(1-\gamma)} q_{m+\gamma} + \tfrac{1}{1-\gamma} q_{m+1}\Big),
\quad c_\gamma = \frac{-3\gamma^2 + 4\gamma - 2}{12(2-\gamma)},
$$

**Implementation status:** not implemented; `gear_2` is the L-stable
order-2 option in this engine. TR-BDF2 is checklist item 1 in RESEARCH.md §2.

### Local truncation error and step control (ngspice `CKTterr` exact)

The LTE of an order-$p$ method on state $q_j$ is
$\text{LTE}_j = C_{p+1} h^{p+1} q_j^{(p+1)}(\xi)$ with error constants
$C_2 = \tfrac12$ (BE), $C_3 = -\tfrac{1}{12}$ (trap). The unknown derivative
is estimated by divided differences over the charge history: with steps
$h_0 = t_m - t_{m-1}$, $h_1$, $h_2$ back through four charge points,

$$
q[m,m-1] = \frac{q_m - q_{m-1}}{h_0},\quad
q[m,m-1,m-2] = \frac{q[m,m-1]-q[m-1,m-2]}{h_0+h_1},\ \dots
$$

$\mathrm{dd}_j$ is the order-$(p+1)$-th divided difference ($p{+}2$ points).
Per-state tolerance, in **current** units (ngspice `cktterr.c`):

$$
\begin{aligned}
i_{\text{new},j} &= \alpha\,(q_{m,j} - q_{m-1,j}) \;[-\,i_{m-1,j}\ \text{if trap}],\\
\texttt{volttol}_j &= \texttt{abstol} + \texttt{reltol}\cdot\max(|i_{\text{new},j}|, |i_{m-1,j}|),\\
\texttt{chargetol}_j &= \texttt{reltol}\cdot\max(|q_{m,j}|,|q_{m-1,j}|,\texttt{chgtol}) / h_0,\\
\tau_j &= \max(\texttt{volttol}_j, \texttt{chargetol}_j),
\end{aligned}
$$

and the per-state admissible step

$$
\delta_j \;=\; \frac{\texttt{trtol}\cdot\tau_j}{\max(\texttt{abstol},\, c_p\,|\mathrm{dd}_j|)},
\qquad c_1 = \tfrac12,\; c_2 = \tfrac1{12},
$$

with $\delta_j \leftarrow \sqrt{\delta_j}$ at order 2 (the bound solves
$C_3 h^3 |q'''| = \texttt{trtol}\,\tau$ for $h$, and the divided difference
carries one factor of $h$ already). The step bound is
$\delta = \min_j \delta_j$; **accept iff $\delta > 0.9\,h$** and use
$\min(\delta,\,2h,\,h_{\max})$ as the next step (spice3 `dctran.c`).
`trtol` (default 7) deflates the worst-case LTE bound to its empirically
observed sharpness.

**Per-device-state LTE (landed 2026-09-07).** ngspice runs the formula above
once per device charge *state* (`ckttrunc.c` → `DEVtrunc` → `cktterr.c`; see
`captrunc.c`, `bjttrunc.c`, `mos1trun.c`) and mins over states, then over
devices. espice used to run it on the `q_vec` plane, i.e. the per-row
(per-node) SUM of charges, which adds co-moving contributions' divided
differences together and loses the binding state.

The fix needed no ABI change and nothing had to be unfrozen. The
per-contribution index space was **already there**: `engine.buildTapes` writes
`rhs_idx[id * n_u + ru]`, a dense `(instance, unknown)` array whose *value* is
the row — many-to-one onto rows, which is precisely "which device state landed
on which node". `Sink.scatterQ` now also stores its `qv` into a host-only
`DeviceBatch.q_tape` on that same index, and `simulate` keeps a second history
(`qt_hist[4]`, `qt_i_prev`) over it. `stepBound` is unchanged — it is handed
different slices. Cost: one nullable fn pointer on the cold `Hooks` vtable
(which moves `layoutHash()` and so re-keys the FastVAF `.so` cache once —
that is the mechanism working, not a break). The four `[]f64` planes, the u32
tapes, the CSC pattern, the Model/Instance PODs and `DeviceKernel.run`'s
parameter list are byte-identical.

Measured on the 264-fixture corpus: **151 PASS / 7 FAIL, unchanged**; 9
fixtures better, 3 worse. `tline/txl2_3_line` 1.23e-2 → 5.40e-3 max (the case
this was built for: node 168's 7.398 fF load cap is a state again instead of
being merged into a 7.498 fF row slope), `ltra2_2_line` 1.13e-4 → 9.65e-6,
`fourbitadder` 3.55e-4 → 3.37e-5, `mos1_large_signal` 8.58e-4 → 1.06e-4,
`mosmem` 3.13e-3 → 8.89e-4. Step counts are unchanged on most of the corpus
and move ±7 % where they move at all — the "more constraints ⇒ smaller steps"
intuition is wrong, see the scale-invariance note below. `ZP_NO_QTAPE=1`
forces the per-row path on a live binary and reproduces the pre-change numbers
exactly; `ZP_TRAN_STATS=1` prints `n_qt`.

**Divergence 1 — the partition is per-(instance, terminal), not per-`ddt`.**
VerA emits `D.q` as one charge per device *unknown*, so a two-terminal cap,
inductor or diode gets exactly ngspice's state set (`CAPqcap`, `INDflux`,
`DIOqd`), but a MOSFET's `qgs + qgd + qgb` arrive already summed on the gate
unknown where `MOS1trunc` terrs them separately. Neither partition is a
superset of the other — `MOS1trunc` also omits `qbd`/`qbs` entirely. Going
finer is a VerA change (emit per-`ddt` charges), which *is* a device-ABI event.

**Divergence 2 — espice can have MORE states than ngspice, and that is what
regressed `devices/kinduc`** (1.53e-8 → 2.75e-4 max; still PASS with 36×
margin). espice lowers a `K` card to its own `kinduc` instance writing
`q[br1] = −M·i2`, `q[br2] = −M·i1` onto the two inductors' branch rows, so
each branch row carries two contributions (self flux + mutual). ngspice
accumulates the mutual term **into the inductor's single `INDflux` state**
(`indload.c:70-77`) and `MUT` has no `MUTtrunc` at all — so ngspice's
truncation candidate for a coupled inductor is exactly espice's *row sum*.
Splitting it is strictly finer than ngspice, not coarser.

Why a *small* extra state still moves the grid: **`CKTterr` is homogeneous of
degree zero in the charge.** `volttol` and `chargetol` both scale with `|q_j|`
and so does `|dd_j|`, so `del_j` depends only on a contribution's *relative*
curvature, not its size — away from the `abstol`/`chgtol` floors, scaling a
state by 1000 leaves its bound put (pinned by an assert in
`tran.zig`'s `stepBound` test). Measured on `kinduc` by sweeping the coupling:
per-state / per-row max error is 2.75e-4 / 1.53e-8 at k = 0.99, 2.62e-4 /
1.86e-8 at k = 0.5, 2.81e-4 / 3.80e-9 at k = 0.1 and 6.17e-5 / 2.02e-12 at
k = 0.001. The gap does not scale with the coupling — a mutual flux 1000×
smaller than the self flux is still a full-strength candidate once it is its
own state. Fixing it means teaching the host that a `K` card's charge belongs
to the inductor's state; not done, because the fixture passes and the
machinery would be a device-type special case.

**Divergence 3 — the GPU keeps per-row LTE.** `Circuit.qTapeLen()` returns 0
when a `gpu_hook.eval_planes` stamp is installed, because `eval`/`evalNewton`
then return before any host batch runs and the tapes would be stale. Closing
that means adding the tape to `DeviceKernel.run`, which *is* a GPU ABI change.
The whole-transient megakernel (`gpu_hook.simulate_tran`) is unaffected — it
has its own LTE reduce.

**Not a divergence: ground-side charge.** The old per-row path walked
`q_hist[0..n]`, excluding the trash cell `q_vec[n]`, so every ground-terminal
contribution was exempt from LTE; the tape has no such exemption. This looks
like a behavioural change but is numerically inert: every `CKTterr` term is
even in `q` (`|q|`, `|dd|`, `|i|`), so a grounded device's `−q` mirror scores
identically to its `+q` partner and cannot move a min. Asserted in the same
test. No trash-row mask is needed, which is why none was built.

### Breakpoints

Sources with corners (PULSE/PWL edges) register breakpoint times. The step
is clamped to land exactly on the next breakpoint ($h \le t_{bp} - t$);
breakpoints closer than $\texttt{min\_break} = 5\times10^{-5}\, h_{\max}$
to the current time or to each other are merged (ngspice `CKTminBreak`).
After landing, integration resumes at order 1 with
$h = 0.1\cdot\min(\texttt{saveDelta},\, \text{gap to next break})$ — spice3's
`CKTsaveDelta` resume rule, which resolves a paired edge (rise start/end 1 ns
apart) instead of stepping over it. Transmission-line delays re-emit landed
breakpoints at $t + \tau_d$ (echo cascade for reflections).

## 2. Flow explanation

`src/analysis/tran/tran.zig simulate()` drives one adaptive-step
loop; four/pss/envelope/tran_noise all build on it.

**Phases.** (1) Setup: allocate the charge-history ring
$[q_{\text{cur}}, q_{-1}, q_{-2}, q_{-3}]$, seed all four with $q(x_{op})$ so
divided differences vanish and LTE control is live from step one; compute
$h_{\max} = $ `tmax` or $t_{\text{stop}}/50$, clamped to the minimum
transmission-line delay. First step: $\min(\texttt{dt\_init}, h_{\max})/10$,
and never past the first breakpoint. (2) Step loop: assemble the companion
system through `TranHook`, Newton with budget ITL4 (=10), then the LTE
acceptance test, then bookkeeping (dynamic-current update matching the
method actually used, history rotation by pointer swap).

**Order control.** Start at BE; promote to the configured method
(trap/gear-2) when the order-2 trunc recompute allows
$\min(2h, \delta_2) > 1.05\,h$ — and adopt that value as the next $h$
**whether or not the promotion sticks** (dctran.c:901-913 assigns
`CKTdelta = newdelta` from the order-2 recompute even when the order drops
back to 1; keeping the order-1 $\delta$ instead left every post-breakpoint
ramp a half-octave behind ngspice's — ltra1_1_line carried a 37 ps
grid-phase offset into the 33 ns wavefront, 1.02e-2). Drop back to BE at
every landed breakpoint (kills trap companion ringing at source-edge
discontinuities) and on any rejection: **order drop first, halve $h$ only
when the retry already ran order 1** — a discontinuity rejects trap long
before $h$ is the problem.

**Failure handling.** Newton non-convergence → revert device FSM state,
order-drop/halve; $h < \texttt{dt\_min}$ → hard failure ("timestep too
small" — a truncated waveform is never returned silently). A device state
flip inside an accepted step (switch threshold crossing) rejects the step
and shrinks so the conductance discontinuity lands sharp (within
`min_break`) instead of smeared across $h$. Growth is capped at $2\times$
per accepted step so a post-breakpoint shrink cannot jump straight back to a
huge $h$ and starve edge ramps.

**Tolerance knobs.** `reltol/abstol` enter both Newton acceptance and
`volttol`; `chgtol` (1e-14) floors the charge scale in `chargetol`; `trtol`
(7 = ngspice, 1 = LTspice/`tight`) directly scales allowed LTE — it is the
single most Spectre-`errpreset`-like knob here (see
[tolerance-system.md](tolerance-system.md)); `dt_min`, `dt_max`,
`max_steps` bound the march; ITL4 is the per-point Newton budget.

## 3. Pseudo-code, CPU sequential

```
simulate(ckt, x, t_stop, tol):
    seed q_hist[1..3] = q(x_op); i_prev = 0
    h_max = tmax or t_stop/50, clamped to min line delay
    h = min(dt_init, h_max)/10, clamped to first breakpoint/10
    use_be = true; t = 0
    while t < t_stop:
        alpha  = (use_be ? 1/h : method == trap ? 2/h : 3/(2h))
        trial  = x
        nr = newton(trial, t+h, hook = {                  # ITL4 budget
                 rhs += alpha*(q(x)-q_prev) [- i_prev | - gear hist],
                 A    = G + alpha*C })
        if !nr.converged:
            revert_device_states()
            if !use_be: use_be = true; continue           # order drop first
            h /= 2; if h < dt_min: fail "timestep too small"
            continue
        if device_state_flipped() and h > min_break:
            revert; use_be = true; h = max(h/4, min_break); continue

        # LTE acceptance (CKTterr over all charge states)
        del = min_j  trtol * max(volttol_j, chargetol_j)
                     / max(abstol, c_p * |divided_diff_j|)
        if order2: del = sqrt(del)
        if del < 0.9*h:
            revert
            if !use_be: use_be = true; continue
            h /= 2; if h < dt_min: fail
            continue
        h_next = min(max(del, dt_min), 2*h, h_max)

        # promotion probe: would the target order allow a bigger step?
        if use_be and trial_del(order of configured method) > 1.05*h:
            use_be = false

        i_prev = alpha*(q_cur - q_prev) [- i_prev if trap]  # method-matched
        rotate q_hist; commit device states
        t += h; record(t, x); x = trial                     # pointer swap

        if landed_on_breakpoint(t):                         # |t - bp| <= min_break
            use_be = true
            h_next = min(h_next, 0.1*min(save_delta, gap_to_next_break))
            re_emit_echo_breakpoint(t + line_delay)
        if next_bp - t < h_next:                            # clamp to land on bp
            save_delta = h_next; h_next = next_bp - t
        h = min(h_next, t_stop - t)
```

## 4. Pseudo-code, GPU parallel

**Time stepping is inherently sequential** — step $m{+}1$ needs the accepted
$q$-history of step $m$. Everything *inside* a step parallelizes, and the
repo goes one further: the whole march runs on-device so the sequential loop
never round-trips to the host.

What parallelizes (per step):
- batched SoA device eval: residual $i(x) + \alpha q(x) + c_{\text{vec}}$
  where `cvec` carries the $-\alpha q_{\text{prev}} - i_{\text{prev}}$ /
  gear-history terms — constant within a timestep, computed once by a
  grid-stride pass;
- the JFNK/GMRES linear solve (matrix-free $J\cdot v$ = one more batched
  eval; see [operating-point-homotopy.md](operating-point-homotopy.md) §4);
- LTE reduction: per-state $\delta_j$ is elementwise over the charge
  vector, then one grid min-reduction;
- history rotation, dynamic-current update: grid-stride axpys.

What stays sequential: step acceptance decision, order control, breakpoint
bookkeeping — thread-0 scalar logic between grid barriers, exactly like the
GMRES bookkeeping.

```
host:
    upload blob once (batches, breakpoint list, tolerances)
    loop: launch tran_chunk(cooperative)         # chunked cooperative launches
          drain waveform ring (device ships probe values, not full x)
          until t >= t_stop or device signals fail -> CPU fallback, waveform rewound

kernel tran_chunk:
    while t < chunk_end:                         # sequential march on-device
        thread0: pick alpha, method (order control state)
        parallel: cvec = -alpha*q_prev [- i_prev]          # once per step
        newton/jfnk on-device (see OP doc §4) with rhs += alpha*q(x) + cvec
        grid_barrier
        parallel: del_j per charge state; grid min-reduce -> del
        thread0: accept/reject, h_next, breakpoint clamp, promote/demote order
        if accepted: parallel i_prev update + q_hist pointer rotation
                     parallel gather probes -> waveform ring slot
        grid_barrier
```

Other parallel axes: independent transients (Monte-Carlo, corners,
`tran_noise` ensembles) batch as independent problems — that axis is
embarrassingly parallel and is how "parallel/GPU transient" beats
Spectre X on throughput rather than latency.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-step Newton on $G + \alpha C$ (numeric refactor when $\alpha$ changes) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md) | `src/analysis/solvers/direct.zig` via `converger.run` + `TranHook` |
| Refactor bypass across steps at constant $\alpha$ (linear circuits) | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig`, value-memcmp) | `converger.Options.matrix_sig` (E2 factor-once) |
| Newton gates / JFNK per step | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/analysis/solvers/converger.zig` |
| GPU on-device march (JFNK) vs level-set refactor alternative | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) | `src/analysis/eval/engine.zig` (`TranEnv`/`cvec`) |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual / `cktterr.c`, `dctran.c` semantics | verified indirectly — our `tran.zig` documents and implements the exact `CKTterr` formulas and `dctran.c:872-913` acceptance (line-referenced in source); manual PDF not re-fetched |
| Bank et al. 1985 (TR-BDF2) | **paywalled — derived, not source-verified** ($\gamma = 2-\sqrt2$, L-stability, embedded LTE from knowledge) |
| Nagel ERL-M520 | not fetched — LTE theory **derived**; constants cross-checked against the ngspice-exact code in this repo |
| designers-guide.org tolerance/accuracy papers | rf-sim.pdf fetched (background); no standalone transient-tolerance paper found on the fetched index pages |

**Per-section verification**

- §1 BE/trap/Gear-2 + LTE formulas: verified against `tran.zig`
  (ngspice-exact per source comments, incl. trtol=7, $c_p \in \{1/2, 1/12\}$,
  0.9·h acceptance, 2× growth cap).
- §1 TR-BDF2: derived, not source-verified; **not implemented**.
- §1 charge conservation: derived (standard Ward–Dutton argument); the
  repo's exact-$q$ residual satisfies it by construction.
- §2/§3: direct transcription of repo source.
- §4: kernel.zig TranEnv/cvec mechanism verified in source; chunked
  cooperative tran launch per `tran.zig` gpu_hook path.

**Our implementation**

- `src/analysis/tran/tran.zig` — integrator, LTE (`stepBound`),
  order control, breakpoints.
- `src/analysis/solvers/converger.zig` — per-step Newton.
- `src/analysis/eval/engine.zig` (`TranEnv`, `cvec`) — on-device companion.
- Bench fixtures: `benchmark/fixtures/tran/{fourbitadder,rc_pulse}`,
  `benchmark/fixtures/tline/*` (breakpoint echoes),
  `benchmark/fixtures/digital/*`, `benchmark/fixtures/ngspice/*` transient
  cases.
