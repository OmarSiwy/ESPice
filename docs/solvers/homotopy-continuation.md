# gmin / Source / Pseudo-Transient Stepping: Solver-Level Homotopy

## 1. Mathematical specification

**Homotopy framing.** When Newton fails on $F(x) = 0$ from the available
start, embed the problem in a family

$$H(x, \lambda) = 0, \qquad H(x, 0) \text{ easy}, \quad H(x, 1) = F(x),$$

and track the solution curve $x(\lambda)$ from $\lambda = 0$ to 1, using
each converged $x(\lambda_k)$ to warm-start Newton at $\lambda_{k+1}$.
Convergence of the ladder rests on the implicit function theorem: while
$\partial H/\partial x$ stays nonsingular along the path, $x(\lambda)$ is
continuous and a small enough step keeps the start inside Newton's basin.
(Folds/bifurcations on the path are exactly where fixed-step ladders fail
and adaptive/arc-length ones survive — derived, not source-verified.)

**gmin stepping.** Homotopy through diagonal regularization:

$$H(x, g) = F(x) + g\,\Pi\,x, \qquad \Pi = \text{diag mask of device nodes},$$

$g$ from $g_0$ (large, e.g. $10^{-2}$) down to $g_{\text{target}} =
\max(\mathrm{gmin}, \mathrm{gshunt})$. Large $g$ makes every node see a
conductance to ground: $J + gI$ is diagonally dominant hence well
conditioned, and the DC solution is pulled toward 0 — an easy problem.
ngspice (cktop.c, fetched) implements the diagonal loading as
`CKTdiagGmin`, distinct from the model parameter gmin. Two variants:

- *spice3_gmin:* fixed geometric ladder — start at $g_{\text{target}} \cdot
  f^{N}$ ($N$ = `CKTnumGminSteps`, $f$ = `CKTgminFactor`, default 10),
  divide by $f$ per converged step, abort on the first failure, finish with
  one Newton at the true gmin.
- *dynamic_gmin (Gillespie):* adaptive multiplicative ladder. From $g =
  10^{-2}/f$: on success, save $(x, \text{state})$; if convergence took
  $\le \mathrm{maxiter}/4$ iterations, accelerate $f \gets f\sqrt{f}$
  (capped at the initial factor); if it took $> 3\,\mathrm{maxiter}/4$,
  decelerate $f \gets \sqrt{f}$; step $g \gets g / f$ (landing exactly on
  $g_{\text{target}}$ when the next step would cross it). On failure,
  retreat: $f \gets f^{1/4}$, restore the last good $(x, \text{state})$,
  retry from $g_{\text{old}}/f$; declare failure when $f < 1.00005$
  (step collapsed to nothing). Always exit with `CKTdiagGmin = gshunt` and
  a final full-precision Newton.

**Source stepping.** Homotopy through excitation scaling:

$$H(x, \alpha) = F_\alpha(x), \quad \text{all independent sources scaled by } \alpha \in [0,1].$$

At $\alpha = 0$ the circuit is source-free — $x = 0$ solves it (ngspice
literally zeros `rhsOld` and the state vector as the start). Variants:

- *spice3_src:* fixed ramp $\alpha = i/N$, $i = 0..N$; any failure aborts
  (no retreat).
- *gillespie_src:* adaptive ramp with the same controller shape as
  dynamic gmin: raise $\Delta\alpha$ from $10^{-3}$; success → save state,
  $\Delta\alpha \gets 1.5\,\Delta\alpha$ if fast ($\le$ maxiter/4),
  $\gets 0.5\,\Delta\alpha$ if slow ($> 3$maxiter/4); failure → restore,
  $\Delta\alpha \gets \Delta\alpha/10$ (capped at $10^{-2}$); give up when
  $\Delta\alpha < 10^{-7}$ or progress stalls ($\alpha - \alpha_{\text{conv}}
  < 10^{-8}$). Bootstrap: if even $\alpha = 0$ fails, run a 10-decade gmin
  ladder *inside* the source stepper to get the first point.

**Pseudo-transient continuation (PTC).** Homotopy through time — solve the
ODE-augmented system

$$\left(\frac{1}{\Delta t_k} D + J(x_k)\right)\Delta x = -F(x_k), \qquad
D \approx \text{capacitance/unit matrix},$$

i.e. take *implicit-Euler pseudo-timesteps* toward the DC steady state
instead of Newton steps. For small $\Delta t$ the iteration matrix is
dominated by $D/\Delta t$ (well conditioned, damped, globally contractive
toward the transient flow); as $\Delta t \to \infty$ it *becomes* Newton
and inherits quadratic convergence. Kelley–Keyes prove convergence for the
standard controller "switched evolution/relaxation" $\Delta t_{k+1} =
\Delta t_k \cdot \|F(x_{k-1})\| / \|F(x_k)\|$ (grow the step as the
residual falls) under smoothness + stable-steady-state assumptions —
paywalled: derived, not source-verified. In SPICE practice PTC is a real
transient run with sources held at DC values and capacitors/inductors kept
(ngspice's OP fallback to `DOING_TRAN`, ramping supplies), used when both
ladders fail; its win is physical damping — oscillator-prone feedback
circuits follow an actual settling trajectory instead of Newton chaos.

**Order of attack (ngspice CKTop):** plain Newton (`NIiter`) → gmin ladder
(dynamic if `numGminSteps == 1`, spice3 if $> 1$) → source ladder
(gillespie if `numSrcSteps == 1`, spice3 if $> 1$) → caller may fall back
to PTC. Rationale: each rung is more expensive and more robust than the
last; gmin before source because it needs no reassembly of source stamps
and converges in fewer total Newton iterations on mildly-stiff circuits.

## 2. Flow explanation

The homotopy ladder is *solver-level*: it wraps the Newton driver, mutating
one scalar knob ($g$, $\alpha$, or $\Delta t$) between full Newton solves,
and owns checkpoint/restore of $(x, \text{device state})$ — the essential
piece that fixed ladders (spice3 variants) skip and adaptive ones
(Gillespie variants) rely on for retreat.

Interaction with the linear solver: every rung change mutates matrix values
only (diagonal loading or RHS scaling) on the frozen pattern — the whole
ladder runs on numeric refactors (`klu-pipeline.md`); large-$g$ rungs are
strongly diagonally dominant so the frozen pivot sequence is at its
safest exactly when the homotopy needs cheap steps. gmin loading also
guards MNA's zero-diagonal rows during early rungs.

Ours (`converger.Tolerances`): `gmin_start = 1e-2` (matches ngspice's
dynamic ladder origin), `source_steps = 7` (spice3-style ramp; ltspice
profile bumps it to 25), the per-analysis ladder living in the dc/op
drivers with `ZP_OPDBG=1` tracing rungs. The gmin knob feeds
`Options.gmin`, applied at assembly time as $J_{ii} \mathrel{+}= g$,
$F_i \mathrel{+}= g x_i$ — note this is the *residual-consistent* form
(the regularized system's true residual), which keeps the acceptance gates
honest across rungs.

When each rung wins: gmin — floating/high-impedance nodes, exponential
stiffness; source — circuits whose difficulty *is* the bias (latches,
high-gain feedback: the solution branch at full excitation is far from any
zero-state guess, but continuously connected to $x(0) = 0$); PTC —
multistable/oscillatory DC landscapes where both parameter ladders jump
branches.

## 3. Pseudo-code, CPU sequential

Transcribed from fetched cktop.c (structure exact, bookkeeping elided):

```
CKTop:
  if newton(iterlim) converged: return
  if numGminSteps == 1: dynamic_gmin() else if > 1: spice3_gmin()
  if converged: return
  if numSrcSteps == 1: gillespie_src() else if > 1: spice3_src()

dynamic_gmin:
  x = 0; state = 0
  factor = gminFactor                     # default 10
  gmin = 1e-2 / factor;  gtarget = max(gmin_param, gshunt)
  until success or failed:
    (converged, iters) = newton(maxiter) with diag loading gmin
    if converged:
      if gmin <= gtarget: success
      else:
        checkpoint (x, state)
        if iters <= maxiter/4: factor = min(factor*sqrt(factor), gminFactor)
        if iters >  3*maxiter/4: factor = sqrt(factor)
        old = gmin
        gmin = (gmin < factor*gtarget) ? gtarget : gmin/factor
    else:
      if factor < 1.00005: failed         # step collapsed
      else: factor = factor^(1/4); gmin = old/factor; restore checkpoint
  diagGmin = gshunt; final newton(iterlim) at true gmin

spice3_gmin:
  gmin = (gshunt or gmin_param) * gminFactor^numGminSteps
  for i in 0..numGminSteps:
    if !newton(maxiter): break            # abort ladder on failure
    gmin /= gminFactor
  diagGmin = gshunt; final newton(iterlim)

gillespie_src:
  alpha = 0; raise = 1e-3; conv = 0; x = 0; state = 0
  if !newton(maxiter) at alpha=0:         # bootstrap with a gmin ladder
    gmin = base * 10^10
    for 11 steps: newton(maxiter) or break; gmin /= 10
  checkpoint; alpha = raise
  while raise >= 1e-7 and conv < 1:
    (converged, iters) = newton(maxiter) at alpha
    if converged:
      conv = alpha; checkpoint
      if iters <= maxiter/4:  raise *= 1.5
      if iters >  3*maxiter/4: raise *= 0.5
      alpha = min(conv + raise, 1)
    else:
      if alpha - conv < 1e-8: break       # stalled
      raise = min(raise/10, 0.01); alpha = conv; restore
  return conv == 1 ? ok : E_ITERLIM       # srcFact reset to 1 either way

pseudo_transient (the rung below the ladder):
  hold sources at DC; keep C/L stamps
  dt = dt0
  loop: solve (D/dt + J) dx = -F          # implicit Euler step
    on success: x += dx; dt *= ||F_prev|| / ||F||   # SER controller
    on failure: dt /= cut
    stop when ||F|| < tol (steady state = DC op)
```

## 4. Pseudo-code, GPU parallel

The ladder is outer-loop control — milliseconds of host logic around
device-heavy Newton solves. The correct GPU design keeps the ladder on the
host and the solves on the device; the interesting parallel angle is
*rung-level* concurrency:

```
gpu_ladder(ckt):
  # rung knobs are header fields: our staged prefix already carries
  # Tol.gmin per solve (gpu_solver.zig patches it) — a gmin rung is a
  # header-only HtoD + relaunch, no repack; alpha likewise scales source
  # params through the ParamRef repack path.
  x_dev persists across rungs             # warm start = free (stays on device)
  for rung in ladder:
    patch header {gmin | srcFact}; upload header (bytes, not MBs)
    launch arp_solve (whole Newton on device); read ResultHeader
    host controller: accelerate/decelerate/retreat exactly as in §3
    checkpoints: device-to-device copy of x into a shadow buffer
                 (restore = pointer swap; never round-trips the host)

speculative parallel ladder (when the device is underutilized by one solve):
  parfor candidate steps {g/f1, g/f2, g/f3} in one batched launch:
    independent Newton solves from the same checkpoint      # batch dim
  take the deepest converged rung; discard the rest
  # trades wasted flops for ladder latency — profitable exactly when a
  # single solve can't fill the GPU (small n, our common case)

what fundamentally serializes: the homotopy path itself — rung k+1's warm
start IS rung k's solution; speculation shortens the chain by a constant
factor, never removes it. PTC serializes identically (pseudo-time is a
chain by construction) but each step is a plain device Newton solve, so it
inherits whatever the megakernel already does.
```

---

**Sources fetched:** ngspice `src/spicelib/analysis/cktop.c` (fetched raw —
CKTop, dynamic_gmin, spice3_gmin, gillespie_src, spice3_src read in full);
Kelley & Keyes, *Convergence Analysis of Pseudo-Transient Continuation*
(paywalled — not fetched).

**Verification status:** §1/§3 gmin + source stepping, all constants
(1e-2 origin, factor^(1/4) retreat, 1.00005 floor, raise 1e-3/1.5×/0.5×/÷10,
1e-7/1e-8 stops, 10-decade bootstrap), order of attack — source-verified
against fetched cktop.c. §1 homotopy/IFT framing — derived, not
source-verified (standard continuation theory). §1/§3 PTC and the SER
controller — derived, not source-verified (Kelley & Keyes paywalled; the
form given is their published controller as commonly cited). §2 — verified
against `converger.zig` (`Tolerances.gmin_start/source_steps`, gmin
residual-consistent loading in `newton()`); the dc/op ladder drivers live in
`src/analysis/dc/`. §4 — our design, not from a source.

**Our implementation:** `src/analysis/solvers/converger.zig`
(`Tolerances.{gmin_start, source_steps}`, `Options.gmin`, gmin loading in
`newton()`/`jfnk()`); ladder drivers `src/analysis/dc/{op,dc}.zig`;
GPU header patching `src/analysis/gpu.zig` (`solveNewton` writes `Tol.gmin`
per solve — the rung-as-header-patch mechanism exists today). PTC: not
implemented as a DC fallback (transient exists; wiring it as an OP rung is
an open item — see README). Fixtures:
`benchmark/fixtures/convergence/{diode_bridge,schmitt,high_gain_fb}`
(ladder rungs actually exercised), `benchmark/fixtures/op/`,
`benchmark/fixtures/adversarial/`.
