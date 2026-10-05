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
and adaptive/arc-length ones survive: derived, not source-verified.)

**gmin stepping.** Homotopy through diagonal regularization:

$$H(x, g) = F(x) + g\,\Pi\,x, \qquad \Pi = \text{diag mask of device nodes},$$

$g$ from $g_0$ (large, e.g. $10^{-2}$) down to $g_{\text{target}} =
\max(\mathrm{gmin}, \mathrm{gshunt})$. Large $g$ makes every node see a
conductance to ground: $J + gI$ is diagonally dominant hence well
conditioned, and the DC solution is pulled toward 0: an easy problem.
ngspice (cktop.c, fetched) implements the diagonal loading as
`CKTdiagGmin`, distinct from the model parameter gmin. Two variants:

- *spice3_gmin:* fixed geometric ladder: start at $g_{\text{target}} \cdot
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

At $\alpha = 0$ the circuit is source-free: $x = 0$ solves it (ngspice
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

**Pseudo-transient continuation (PTC).** Homotopy through time: solve the
ODE-augmented system

$$\left(\frac{1}{\Delta t_k} D + J(x_k)\right)\Delta x = -F(x_k), \qquad
D \approx \text{capacitance/unit matrix},$$

i.e. take *implicit-Euler pseudo-timesteps* toward the DC steady state
instead of Newton steps. For small $\Delta t$ the iteration matrix is
dominated by $D/\Delta t$ (well conditioned, damped, globally contractive
toward the transient flow); as $\Delta t \to \infty$ it *becomes* Newton
and inherits quadratic convergence. Kelley-Keyes prove convergence for the
standard controller "switched evolution/relaxation" $\Delta t_{k+1} =
\Delta t_k \cdot \|F(x_{k-1})\| / \|F(x_k)\|$ (grow the step as the
residual falls) under smoothness + stable-steady-state assumptions:
paywalled: derived, not source-verified. In SPICE practice PTC is a real
transient run with sources held at DC values and capacitors/inductors kept
(ngspice's OP fallback to `DOING_TRAN`, ramping supplies), used when both
ladders fail; its win is physical damping: oscillator-prone feedback
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
and owns checkpoint/restore of $(x, \text{device state})$: the essential
piece that fixed ladders (spice3 variants) skip and adaptive ones
(Gillespie variants) rely on for retreat.

Interaction with the linear solver: every rung change mutates matrix values
only (diagonal loading or RHS scaling) on the frozen pattern: the whole
ladder runs on numeric refactors (`klu-pipeline.md`); large-$g$ rungs are
strongly diagonally dominant so the frozen pivot sequence is at its
safest exactly when the homotopy needs cheap steps. gmin loading also
guards MNA's zero-diagonal rows during early rungs.

Ours: `solveLadder` in `src/analysis/dc/op.zig`, traced with `ZP_OPDBG=1`.
It runs five rungs in order:

1. Plain Newton with no diagonal gmin, capped at itl1.
2. Dynamic gmin stepping (cktop.c `dynamic_gmin`) from
   `Tolerances.gmin_start = 1e-2` down to `Tolerances.gmin`, factor 10.
   Each solve is capped at itl2, and the accelerate/slow-down thresholds,
   the 1.00005 floor and the final clamp follow cktop.c:207-222 on that
   itl2 budget. A converged step at the target gmin is re-solved with no
   shunt, since the answer must not carry it.
3. Adaptive source stepping through the devices' `attempt(lambda)`:
   lambda starts at 0 with delta = 0.25; delta grows 1.5x on success and
   halves on failure (retrying from the last good lambda and x); the rung
   gives up when delta falls below 1e-4, after 100 solves, or at once when
   the lambda = 0 start fails (a retry would repeat the same cold solve).
   Each solve is capped at itl2. There is no fixed step count: the old
   `source_steps` tolerance is gone.
4. JFNK (`converger.jfnk`) from a cold start.
5. OPtran: a real transient with full sources (dt 10 ns, t_stop 1 us, UIC),
   whose settled state only seeds a clean Newton; the answer is that
   Newton's verdict. ngspice 44.2 runs this rung only when `optran` is
   given (cktop.c:94-97).

The gmin knob feeds `Options.gmin`, applied at assembly time as
$J_{ii} \mathrel{+}= g$, $F_i \mathrel{+}= g x_i$. This is the
*residual-consistent* form (the regularized system's true residual), which
keeps the acceptance gates honest across rungs.

Divergences from cktop.c: our source stepping is not gillespie_src (it
starts from delta = 0.25 rather than raise = 1e-3 and has no gmin bootstrap
at lambda = 0), and the JFNK and OPtran rungs have no ngspice counterpart
in a default run.

When each rung wins: gmin: floating/high-impedance nodes, exponential
stiffness; source: circuits whose difficulty *is* the bias (latches,
high-gain feedback: the solution branch at full excitation is far from any
zero-state guess, but continuously connected to $x(0) = 0$); PTC:
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

## 4. GPU

None. The ladder and every Newton solve run on the host; the GPU only
evaluates device planes. A speculative ladder (several candidate gmin steps
solved in one batch from the same checkpoint) remains an idea, not code.

---

**Sources fetched:** ngspice `src/spicelib/analysis/cktop.c` (fetched raw:
CKTop, dynamic_gmin, spice3_gmin, gillespie_src, spice3_src read in full);
Kelley & Keyes, *Convergence Analysis of Pseudo-Transient Continuation*
(paywalled, not fetched).

**Verification status:** §1/§3 gmin + source stepping, all constants
(1e-2 origin, factor^(1/4) retreat, 1.00005 floor, raise 1e-3/1.5×/0.5×/÷10,
1e-7/1e-8 stops, 10-decade bootstrap), order of attack: source-verified
against fetched cktop.c. §1 homotopy/IFT framing: derived, not
source-verified (standard continuation theory). §1/§3 PTC and the SER
controller: derived, not source-verified (Kelley & Keyes paywalled; the
form given is their published controller as commonly cited). §2: verified
against `src/analysis/dc/op.zig` (`solveLadder`, `transientOp`) and
`converger.zig` (gmin loading in `newton()`).

**Our implementation:** ladder in `src/analysis/dc/op.zig` (`solveLadder`,
`transientOp`, `newtonRun`), reused per point by `src/analysis/dc/dc.zig`;
`Tolerances.{gmin, gmin_start, itl1, itl2}` in `src/core/numerics.zig`;
`Options.gmin` and gmin loading in `src/solver/converger.zig`. PTC in the
Kelley-Keyes form is not implemented; OPtran (rung 5) is the pseudo-time
fallback. Fixtures: `tests/fixtures/convergence/` (`bench_diode_bridge`,
`bench_schmitt`, `bench_high_gain_fb`), `tests/fixtures/op/`, and
`tests/fixtures/stress/scaling_inverter_chain_4k` (finishes on the gmin
rung, following ngspice's gmin sequence).
