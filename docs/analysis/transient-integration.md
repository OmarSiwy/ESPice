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
discretization leaks charge whenever $C$ varies over the step: the classic
SPICE2 MOS charge-pumping bug, and Ward-Dutton charge models exist precisely for
this.) This engine stamps an exact $q(x)$ plane for the residual and the
analytic $C = \partial q/\partial x$ plane for the Jacobian; nothing is
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

**Gear-2 / BDF2** (order 2, L-stable). With $r = h/h_{\text{prev}}$ the
variable-step coefficients are ngspice's (`nicomcof.c:60-136`, solved there
as a Vandermonde system):

$$
F_{\text{dyn}} = \alpha\,(q_m - q_{m-1}) - a_2\,(q_{m-1} - q_{m-2}),
\quad \alpha = \frac{1+2r}{(1+r)h},\quad a_2 = \frac{r^2}{(1+r)h}.
$$

Equal steps ($r = 1$) give the familiar $\alpha = 3/(2h)$, $a_2 = 1/(2h)$.
`integrator.coeffs` returns $(\alpha, a_2)$ for all three methods.

In all cases each Newton iteration solves

$$
\Big(G(x) + \alpha\,C(x)\Big)\,\Delta x = -\Big(F_{\text{res}}(x) + F_{\text{dyn}}(x)\Big),
$$

one axpy over the nnz combines the analytic $G$ and $C$ planes.

### TR-BDF2

*(derived, not source-verified: Bank, Coughran, Fichtner, Grosse, Rose,
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
order-2 option in this engine.

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
\qquad c_{\text{BE}} = \tfrac12,\; c_{\text{trap}} = \tfrac1{12},\; c_{\text{gear2}} = \tfrac29,
$$

with $\delta_j \leftarrow \sqrt{\delta_j}$ at order 2 (the bound solves
$C_3 h^3 |q'''| = \texttt{trtol}\,\tau$ for $h$, and the divided difference
carries one factor of $h$ already). The step bound is
$\delta = \min_j \delta_j$; **accept iff $\delta > 0.9\,h$** and use
$\min(\delta,\,2h,\,h_{\max})$ as the next step (spice3 `dctran.c`).
`trtol` (default 7) deflates the worst-case LTE bound to its empirically
observed sharpness.

### Per-device-state LTE

ngspice runs the formula above once per device charge *state*
(`ckttrunc.c` to `DEVtrunc` to `cktterr.c`; see `captrunc.c`, `bjttrunc.c`,
`mos1trun.c`) and takes the minimum over states, then over devices. Running
it on the `q_vec` plane instead, the per-row (per-node) sum of charges, adds
the divided differences of co-moving contributions and loses the binding
state.

The per-contribution index space already exists: `buildTapes`
(`src/device/eval.zig`) writes `rhs_idx[id * n_u + ru]`, a dense
`(instance, unknown)` array whose value is the row. `Sink.scatterQ` also
stores its `qv` into the host-only `DeviceBatch.q_tape` on that index, and
`simulate` keeps a second history (`qt_hist[4]`, `qt_i_prev`) over it.
`stepBound` takes either index space. The cost is one nullable function
pointer on the cold `Hooks` vtable (it moves `layoutHash()` and so re-keys
the runtime `.so` cache once). The four `[]f64` planes, the u32 tapes, the CSC
pattern, the Model/Instance PODs and `DeviceKernel.run`'s parameter list are
unchanged.

Measured when it landed (2026-09-07, 264-fixture corpus): 151 pass / 7 fail,
unchanged; 9 fixtures closer to the reference, 3 further. `txl2_3_line`
1.23e-2 to 5.40e-3 max error (node 168's 7.398 fF load cap becomes a state
again instead of merging into a 7.498 fF row slope), `ltra2_2_line` 1.13e-4
to 9.65e-6, `fourbitadder` 3.55e-4 to 3.37e-5, `mos1_large_signal` 8.58e-4
to 1.06e-4, `mosmem` 3.13e-3 to 8.89e-4. Step counts are unchanged on most
decks and move by up to 7% elsewhere. Fallback: `ZP_NO_QTAPE=1` forces the
per-row path and reproduces the pre-change numbers exactly;
`ZP_TRAN_STATS=1` prints `n_qt`, which says which path is live.

**Divergence 1: the partition is per (instance, terminal), not per `ddt`.**
VerA emits `D.q` as one charge per device unknown, so a two-terminal cap,
inductor or diode gets exactly ngspice's state set (`CAPqcap`, `INDflux`,
`DIOqd`), but a MOSFET's `qgs + qgd + qgb` arrive summed on the gate unknown
where `MOS1trunc` truncates them separately. Neither partition contains the
other: `MOS1trunc` also omits `qbd`/`qbs`. A finer partition needs VerA to emit
per-`ddt` charges (a device ABI change); it is the open cause of the drift on
`mos6_inverter`, `schmitt`, `rca3040`, `rtlinv`, `hfet_inverter` and
`inverter_chain_256` (see "Conformance with dctran.c" below).

**Coupled inductors truncate on INDflux.** A `K` card lowers to a `kinduc`
instance writing `q[br1] = -M*i2`, `q[br2] = -M*i1` onto the two inductors'
branch rows, so the tape holds `L*i` and each `M*i` as separate states.
ngspice folds the mutual term into the inductor's single state,
INDflux = L*i + sum M*i_other (`indload.c:72-76`), and MUT has no trunc
routine. Because `CKTterr` is homogeneous of degree zero in the charge
(`volttol`, `chargetol` and `|dd_j|` all scale with `|q_j|`), a mutual flux
1000x smaller than the self flux still binds once it is its own state: on
`device_kinduc` the per-state/per-row max error was 2.75e-4 / 1.53e-8 at
k = 0.99 and 6.17e-5 / 2.02e-12 at k = 0.001. With a `kinduc` batch present,
`lteSnap` in `tran.zig` zeroes the inductor and kinduc tape spans (a flat
zero history never binds) and appends the row plane at every current row,
where an inductor's branch row sums to INDflux. `device_kinduc` went from
51.7x to 0.0013x of tolerance, bit-identical to the `ZP_NO_QTAPE=1` run;
circuits without a K card are unchanged. Ceiling: every current row is
appended, not only the inductors'. V-source rows carry no charge and stay
inert, and a device charging its own branch row appears twice with the same
value. The upgrade is to take only the inductor rows once `Circuit` exposes
the tape's `rhs_idx`.

**Divergence 2: a GPU plane stamp keeps per-row LTE.** `Circuit.qTapeLen()`
returns 0 when a `gpu_hook.eval_planes` stamp is installed, because the host
batches never run and the tapes would be stale. Closing it means adding the
tape to `DeviceKernel.run`, a GPU ABI change.

**Not a divergence: ground-side charge.** The per-row path excluded the trash
cell `q_vec[n]`, so every ground-terminal contribution was exempt from LTE;
the tape has no such exemption. Every `CKTterr` term is even in `q` (`|q|`,
`|dd|`, `|i|`), so a grounded device's `-q` mirror scores the same as its
`+q` partner and cannot move the minimum. The `stepBound` tests assert both
this and the scale invariance.

### Breakpoints

Sources with corners (PULSE/PWL edges) register breakpoint times. The step
is clamped to land exactly on the next breakpoint ($h \le t_{bp} - t$).
Breakpoints closer than $\texttt{min\_break} = 10\,\texttt{delmin}$, with
$\texttt{delmin} = 10^{-11} h_{\max}$ (`traninit.c:36`, `dctran.c:170`), to
the current time or to each other merge (ngspice `CKTminBreak`). After
landing, integration resumes at order 1 with
$h = 0.1\cdot\min(\texttt{saveDelta},\, \text{gap to next break})$, spice3's
`CKTsaveDelta` resume rule, which resolves a paired edge (rise start and end
1 ns apart) instead of stepping over it. Transmission-line delays re-emit
landed breakpoints at $t + \tau_d$ (echo cascade for reflections).

## 2. Flow explanation

`src/analysis/tran/tran.zig simulate()` drives one adaptive-step loop; the
kernels (companion coefficients, dynamic-current recurrence, `CKTterr`
bound) live in `src/analysis/tran/integrator.zig`. `.four`, PSS, envelope and
`tran_noise` build on the same kernels.

**Setup.** Allocate the charge-history ring
$[q_{\text{cur}}, q_{-1}, q_{-2}, q_{-3}]$ and seed all four with
$q(x_{op})$, so the divided differences vanish and LTE control is live from
the first step. $h_{\max}$ is `tmax` or $t_{\text{stop}}/50$, clamped to the
minimum transmission-line delay. The step history $h_{-1}, h_{-2}$ starts at
$h_{\max}$ (`CKTdeltaOld[i] = CKTmaxStep`, `dctran.c:312`).

**First step** (`dctran.c:134`, `578-586`):
$h = \min(\min(\texttt{dt\_init}, t_{\text{stop}}/100)/10,\ h_{\max})$, then
$h = \min(h, 0.1\cdot t_{bp,1})$ when a breakpoint exists, then the
`firsttime` division by 10. The operand order sets the phase of the whole
accepted grid. The first accepted point skips `CKTtrunc`, so its step repeats
for every circuit, with or without charge; `CKTtrunc`'s $\min(2h, \delta)$
applies from the second accepted point on.

**Per step.** Assemble the companion system through `TranHook`, run Newton
with budget ITL4 (10), then re-read $q$ at the Newton solution
(`Circuit.evalQ`) before the LTE test. The converger returns $x_{k+1}$ while
the planes still hold $q(x_k)$, so without the re-read `CKTterr`,
`advanceCurrent` and the next residual would see the wrong charge. Then
bookkeeping: the dynamic-current update for the method actually used and a
pointer rotation of the history ring.

**Order control.** Start at BE. After each accepted BE step, recompute the
bound at order 2; promote to the configured method (trap or gear-2) when
$\min(2h, \delta_2) > 1.05\,h$, and adopt that value as the next $h$ whether
or not the promotion happens (`dctran.c:901-913` assigns
`CKTdelta = newdelta` from the order-2 recompute even when the order stays
at 1). Keeping the order-1 $\delta$ instead left every post-breakpoint ramp
half an octave behind ngspice's; `ltra1_1_line` carried a 37 ps grid-phase
offset into the 33 ns wavefront. Drop to BE at every landed breakpoint.

**Rejections.**
- LTE: retry at $h = \delta$ with the same order (`dctran.c:966`). Only a
  Newton failure changes the order.
- Newton non-convergence: revert device FSM state, $h \leftarrow h/8$ and
  order 1 in the same retry (`dctran.c:815`, `:823`).
- A device state flip inside an accepted step (switch threshold crossing):
  revert, drop to BE and shrink to $\max(h/4, \texttt{state\_eps})$ with
  $\texttt{state\_eps} = 5\times10^{-5} h_{\max}$, so the conductance step
  lands sharp instead of smeared across $h$.
- $h < \texttt{dt\_min}$: hard failure ("timestep too small"); a truncated
  waveform is never returned as complete.

Growth is capped at $2\times$ per accepted step.

**Tolerance knobs.** `reltol`/`abstol` enter both Newton acceptance and
`volttol`; `chgtol` (1e-14) floors the charge scale in `chargetol`; `trtol`
(7 = ngspice, 1 = LTspice/`tight`) scales the allowed LTE directly (see
[tolerance-system.md](tolerance-system.md)). `dt_min`, `dt_max` and
`max_steps` bound the march; ITL4 is the per-point Newton budget.

## 3. Pseudo-code, CPU sequential

```
simulate(ckt, x, t_stop, tol):
    seed q_hist[0..3] = q(x_op); i_prev = 0
    h_max = tmax or t_stop/50, clamped to min line delay
    h_prev = h_prev2 = h_max
    h = min(min(dt_init, t_stop/100)/10, h_max)
    if first breakpoint bp1: h = min(h, 0.1*bp1)
    h /= 10
    use_be = true; t = 0; steps = 0
    while t < t_stop:
        (alpha, a2) = coeffs(use_be ? BE : method, h, h_prev)
        trial = x
        nr = newton(trial, t+h, ITL4, hook = {
                 rhs += alpha*(q(x)-q_prev) [- i_prev | - a2*(q_prev-q_prev2)],
                 A    = G + alpha*C })
        if !nr.converged:
            revert_device_states()
            use_be = true; h /= 8
            if h < dt_min: fail "timestep too small"
            continue
        if device_state_flipped() and h > state_eps:
            revert; use_be = true; h = max(h/4, state_eps); continue

        h_next = (steps == 0) ? h : min(2h, h_max)     # firsttime: no CKTtrunc
        q_hist[0] = q(trial)                           # charge at the published point
        if steps > 0:
            del = CKTterr over every charge state      # sqrt at order 2
            if del < 0.9*h:
                revert; h = del                        # same order
                if h < dt_min: fail
                continue
            h_next = min(max(del, dt_min), 2h, h_max)
            if use_be:                                 # promotion probe
                nd2 = min(2h, CKTterr at the configured order)
                if nd2 > 1.05*h: use_be = false
                h_next = min(max(nd2, dt_min), h_max)

        i_prev = alpha*(q_cur - q_prev) [- history term]   # method actually used
        rotate q_hist; h_prev2 = h_prev; h_prev = h
        commit device states
        t += h; record(t, trial); swap(x, trial)

        if landed_on_breakpoint(t):                    # |t - bp| <= min_break
            use_be = true
            h_next = min(h_next, 0.1*min(save_delta, gap_to_next_break))
            re_emit_echo_breakpoint(t + line_delay)
        if next_bp - t < h_next:                       # clamp to land on bp
            save_delta = h_next; h_next = next_bp - t
        h = min(h_next, t_stop - t)
```

## 4. Parallel execution

Time stepping is sequential: step $m{+}1$ needs the accepted $q$ history of
step $m$. What runs in parallel is device evaluation inside each Newton
iterate: `ParEval` worker threads on the CPU, or the GPU through
`Circuit.gpu_hook.eval_planes`, which ships `x` up and the value planes down
per iterate. The Newton update, sparse LU, LTE, order control and breakpoint
logic all run on the host.

Not implemented (design note): an on-device march would keep the step loop
on the GPU, with a per-step constant vector carrying
$-\alpha q_{\text{prev}} - i_{\text{prev}}$, matrix-free JFNK for the Newton
solve, a grid min-reduction for the per-state $\delta_j$, and thread-0 scalar
logic for acceptance and order control between grid barriers. An earlier
cooperative-kernel prototype of this was deleted; the GPU evaluates device
planes only.

Independent transients (Monte Carlo, corners, `tran_noise` ensembles) are a
separate, embarrassingly parallel axis.

## Conformance with dctran.c

Step control follows ngspice 44.2 `dctran.c` rule by rule. Each rule landed
as its own commit and moved decks toward their references; the before/after
numbers are worst error as a multiple of tolerance.

First step (issues.md F1). The breakpoint clamp used to run after the
`firsttime` division and drop it, and only circuits with charge repeated the
first step. With both fixed, the first step equals ngspice's on all six
affected decks; `bench_medium_rc_ladder_50` (8.61 to 1.4e-5),
`bench_power_buck_open` (2.96e3 to 0.0047) and `bench_ngspice_res_array`
(8.64e3 to 4.5e-6) pass. `.four` decks move 0.33x to 0.34x on a grid that is
now ngspice's point for point; their residual is the `.four` interpolation.

The drift fixes (issues.md F9), in order, took the fixture pass count from 554
to 559 with no regression:

| Rule | ngspice | Effect |
|---|---|---|
| LTE rejection keeps the order | `dctran.c:966` | 4 passing reference decks closer by 1 to 7 digits; no flip |
| Newton failure: $h/8$ and order 1 in one retry | `:815`, `:823` | `hfet_inverter` 1.85e3 to 704 |
| Step history seeded with $h_{\max}$ | `:312` | `vacask_mul` 234 to 200 |
| LTE reads $q$ at the published solution | `CKTterr` on the accepted state | `vacask_graetz` 13.2 to 0.17, `vacask_mul` 242 to 0.71, `bench_bypass_gated_branch` 10.8 to 0.63, `bench_digital_clamp` 1.11 to 0.92 |
| Coupled inductors truncate on INDflux | `indload.c:72-76` | `device_kinduc` 51.7 to 0.0013 |

The charge re-read costs one extra `evalQ` per accepted step (callgrind Ir,
whole run):

| Deck | Before | After | |
|---|---|---|---|
| `tran/device_mos6_inverter` | 115.3M | 121.6M | +5.4% |
| `tran/bench_tran_fourbitadder` | 290.4M | 297.4M | +2.4% |
| `stress/scaling_parallel_inverters_100` | 330.0M | 350.2M | +6.1% |
| `tran/bench_bypass_gated_branch` | 36.4M | 39.3M | +8.0% |

No cheaper pass gives the same values: the Jacobian-extrapolated $C\,dx$ is
not $q(x)$ for a nonlinear charge. The post-accept re-read for stateful-charge
devices stays; without it `txl2_3_line`, `hfet_inverter`,
`mesa_oscillator` and `mos6_inverter` change bytes.

Decks that moved away from their reference, all failing before and after.
Each was checked against an instrumented ngspice 44.2 run, and the accepted
grid now follows ngspice's:

- `reference/diode_reverse_recovery` 7.87 to 20.5: the recovery tail tracks
  ngspice's grid to 4e-5.
- `tran/bench_ngspice_mosamp` 2.6e5 to 3.84e5: the old oracle carried
  ngspice's ~710 Newton $h/8$ cuts in the MOS2 slew. Its oracle is now
  ngspice at tight options (see issues.md F9).
- `tran/device_mos6_inverter` 453 to 668: the accepted row count is now
  ngspice's (315); the residual is Divergence 1.

Open:
- One tape slot per `ddt()` site with a per-site LTE mask (Divergence 1).
  Needs VerA.
- Newton robustness: `MODEINITPRED`, `fetlim`/`limvds`, `CKTconvTest`
  (`bench_ensemble_pvt_corners`, `bench_ngspice_mosamp`).
- `bench_ngspice_mosamp` publishes far fewer points than ngspice's 2316 later
  in the run.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-step Newton on $G + \alpha C$ (numeric refactor when $\alpha$ changes) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md) | `src/solver/direct.zig` via `converger.run` + `TranHook` |
| Refactor bypass across steps at constant $\alpha$ (linear circuits) | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig`, value compare) | `converger.Options.matrix_sig`, `direct.Solver.factor` |
| Newton gates / JFNK per step | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solver/converger.zig` |
| GPU level-set refactor (not implemented) | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) | none |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice `cktterr.c`, `dctran.c`, `nicomcof.c`, `indload.c` | verified against the line references in `tran.zig` and `integrator.zig`; the drift fixes were A/B tested against an instrumented ngspice 44.2 |
| Bank et al. 1985 (TR-BDF2) | paywalled; derived, not source-verified ($\gamma = 2-\sqrt2$, L-stability, embedded LTE) |
| Nagel ERL-M520 | not fetched; LTE theory derived, constants cross-checked against `integrator.zig` |

**Per-section verification**

- §1 BE/trap/Gear-2 and LTE formulas: verified against `integrator.zig`
  (trtol 7, $c_p \in \{.5, .08333333333, .2222222222\}$, 0.9h acceptance,
  2x growth cap). The coefficients are cktterr.c's truncated decimals, not
  1/12 and 2/9: the 4e-11 relative gap moved every LTE-chosen step by
  2e-11: only 50 of the 187 `stress/scaling_rc_ladder_1k` oracle times hit
  our grid within 1e-13, and now all 187 do.
- §1 TR-BDF2: derived, not source-verified; not implemented.
- §1 charge conservation: derived (standard Ward-Dutton argument); the exact
  $q$ residual satisfies it by construction.
- §2/§3: transcribed from `tran.zig`.
- §4: the on-device march is a design note, not code.

**Our implementation**

- `src/analysis/tran/tran.zig`: step loop, order control, breakpoints,
  per-state LTE history, INDflux handling.
- `src/analysis/tran/integrator.zig`: `coeffs`, `advanceCurrent`,
  `companionAt`, `stepBound`.
- `src/solver/converger.zig`: per-step Newton.
- Fixtures: `tests/fixtures/tran/` (`bench_tran_fourbitadder`,
  `bench_tran_rc_pulse`, the `bench_tline_*` breakpoint-echo decks,
  `bench_digital_*`, `bench_ngspice_*`), `tests/fixtures/reference/`.
