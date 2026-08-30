# Nonlinear Solving: Newton–Raphson Criteria, Device Limiting, JFNK + GMRES

## 1. Mathematical specification

**Newton–Raphson on MNA.** Find $x^*$ with $F(x^*) = 0$ where $F$ stacks
KCL/KVL residuals. Iterate

$$J(x^{(m)})\,\Delta x = -F(x^{(m)}), \qquad x^{(m+1)} = x^{(m)} + \Delta x,$$

$J = \partial F / \partial x$ the MNA Jacobian (conductance stamps).
Locally quadratic convergence for $F \in C^2$ with nonsingular $J(x^*)$;
globally, unmodified Newton diverges from poor starts — hence limiting and
homotopy (see `homotopy-continuation.md`).

**ngspice convergence criteria (SPICE3 NIconvTest).** Per unknown $i$:

$$|\Delta x_i| < \mathrm{reltol} \cdot \max\!\bigl(|x^{(m+1)}_i|, |x^{(m)}_i|\bigr) + \mathrm{atol}_i,
\qquad \mathrm{atol}_i = \begin{cases}\mathrm{vntol} & \text{voltage rows}\\ \mathrm{abstol} & \text{current rows}\end{cases}$$

(defaults reltol $=10^{-3}$, vntol $=10^{-6}$ V, abstol $=10^{-12}$ A).
Equivalently the scaled norm $\max_i |\Delta x_i| / (\mathrm{reltol}\max(
|x_i^{new}|,|x_i^{old}|) + \mathrm{atol}_i) < 1$. Supplements in ngspice
order: device state flips force another iteration; any device limiting
event forces another iteration; iteration 1 is never accepted. Delta-x
tests alone can accept a stagnated iterate, so we add a row-scaled residual
gate: accept only if additionally

$$|F_i| \le \max\!\bigl(\mathrm{residual\_tol},\ 10\,|J_{ii}|\,(\mathrm{reltol}\,|x_i| + \mathrm{vntol})\bigr)\ \forall i$$

— the bound a legitimate final step could leave ($|J\,\Delta x| \approx
|J_{ii}||\Delta x_i|$ at the just-passed tolerance), with the floor
`residual_tol` catching silently-singular solves on near-zero-diagonal
branch rows.

**Device limiting as globalization.** Instead of a line search on
$\|F\|$, SPICE clamps *device-controlling voltages* between iterations —
model-aware trust regions. With the limited voltage $v^{lim} \ne v$, the
device stamps the companion linearization $i(v^{lim}) + g(v^{lim})(v -
v^{lim})$, so $F$ remains consistent and piecewise-affine in $x$ through
limited devices. The ngspice functions (devsup.c, fetched, exact):

*pnjlim* — junction voltages. With thermal voltage $v_t$ and critical
voltage $v_{crit} = v_t \ln\bigl(v_t / (\sqrt{2}\, I_S)\bigr)$ (the knee
where $di/dv$ growth explodes):

$$v^{new} > v_{crit} \wedge |v^{new} - v^{old}| > 2v_t:\quad
v^{lim} = \begin{cases}
v^{old} + v_t\left(2 + \ln\!\frac{v^{new}-v^{old}}{v_t} - 2\right) & v^{old} > 0,\ \frac{v^{new}-v^{old}}{v_t} > 0\\[2pt]
v^{old} - v_t\left(2 + \ln\!\left(2 - \frac{v^{new}-v^{old}}{v_t}\right)\right) & v^{old} > 0,\ \text{else}\\[2pt]
v_t \ln(v^{new}/v_t) & v^{old} \le 0
\end{cases}$$

plus Gillespie's reverse-bias clamp: for $v^{new} < 0$, floor at
$-v^{old} - 1$ (if $v^{old} > 0$) or $2v^{old} - 1$ (else). The step in
forward bias is limited **logarithmically** — precisely inverting the
exponential $I(v)$, so the *current* step stays bounded.

*fetlim* — MOS gate drive, piecewise linear around $v_{to}$, with test
bands $v_{tsthi} = 2|v^{old} - v_{to}| + 2$, $v_{tstlo} = |v^{old} -
v_{to}| + 1$, $v_{tox} = v_{to} + 3.5$: on-region steps clamped to
$\pm v_{tsthi}/v_{tstlo}$, off→on transitions clamped to enter at
$v_{to} + 0.5$, on→off floored at $v_{to} - 0.5$ — the step may cross the
threshold but never far, keeping the square-law linearization honest.

*limvds* — drain-source: rising $v_{ds}$ clamped to $\min(v^{new},
3v^{old} + 2)$ (for $v^{old} \ge 3.5$; to 4 below), falling floored at 2
resp. $-0.5$ — geometric growth allowed, collapse damped.

Every limiting event sets a flag that vetoes convergence this iteration
(the "limited ⇒ iterate again" rule above).

**JFNK — Jacobian-free Newton–Krylov.** Solve $J\Delta x = -F$ by GMRES
using only directional derivatives:

$$Jv \approx \frac{F(x + \varepsilon v) - F(x)}{\varepsilon}, \qquad
\varepsilon = \frac{\sqrt{u}\,\max(\|x\|_2, 1)}{\|v\|_2},$$

$u$ = machine epsilon ($\varepsilon$ balances truncation vs roundoff;
standard JFNK choice — derived, not source-verified; Kelley's texts are the
paywalled reference). GMRES($m$): build the Arnoldi relation $J V_j =
V_{j+1} \bar H_j$ by modified Gram–Schmidt, minimize $\|\beta e_1 - \bar
H_j y\|_2$ via Givens rotations, $\Delta x = V_j y$; restart at $m$ (ours:
$m = 30$). Convergence is governed by the spectrum of the *preconditioned*
operator; MNA matrices are non-normal and badly scaled (volts vs amps), so
unpreconditioned GMRES stalls — preconditioning options, strongest first:

1. frozen full LU of a nearby Jacobian (exact one-iteration preconditioner
   while it stays near; our choice when the direct solver is factorable),
2. block-Jacobi from the BBD partition,
3. diagonal (Jacobi) $M^{-1} = \mathrm{diag}(J)^{-1}$ — the always-available
   fallback.

Right preconditioning ($J M^{-1} (M \Delta x) = -F$) keeps the true
residual observable. Note limiting composes correctly with JFNK: while the
limit state is frozen, $F$ is piecewise-affine through limited devices, so
the finite-difference $Jv$ is *exact*, not approximate.

## 2. Flow explanation

Both strategies flow through one shared skeleton (ours,
`converger.zig`): assemble → optional gmin regularization ($J \mathrel{+}=
g_{\min} I$, $F \mathrel{+}= g_{\min}x$ — keeps the fixed point, bounds the
condition number) → compute $\Delta x$ → direction-preserving damping →
**one shared acceptance path** (`finalizeStep`): apply, run limits, state
flips, iteration-1 veto, per-row delta-x, residual gate. One acceptance
implementation means the direct and Krylov paths cannot drift.

- **Direct Newton** computes $\Delta x$ by factor+solveNeg (KLU-style, see
  `klu-pipeline.md`), with the `matrix_sig` factor-once shortcut for
  constant Jacobians. This is the default: numeric refactor at
  $O(\mathrm{nnz}(L{+}U))$ is far cheaper than JFNK's per-Krylov-vector
  full circuit evals at every size we bench.
- **JFNK** is chosen when GPU is active (matrix-free = no factorization on
  device; every $Jv$ is one more residual eval, which is exactly what the
  megakernel does fast) — and falls back to direct Newton on
  non-convergence.
- **Damping**: if $\max|\Delta x_i| >$ clamp, scale the *whole* vector —
  componentwise clamping breaks the Newton direction and turns junction
  overshoot into a fixed-step walk; scaling keeps linear-row residuals
  decaying geometrically.
- **No monotone-$\|F\|$ backtracking**, deliberately, matching ngspice:
  limiting *is* the globalization; junction settling legitimately flares
  $\|F\|$ 10–100× for an iteration, and a monotonicity safeguard
  double-limits (measured: 3-iteration settles become 50 on
  fourbitadder/mos6_inverter-class fixtures).

## 3. Pseudo-code, CPU sequential

```
newton(ckt, x, opts, hook):
  for iter in 0..max_iter:
    hook.assemble(ckt, x, t)                    # J into vals, F into rhs
    if gmin > 0: vals[diag] += gmin; rhs += gmin * x
    if matrix_sig miss: slv.factor(vals)        # refactor / full fallback
    slv.solveNeg(rhs, dx)                       # dx = -J \ F
    if max|dx| > clamp: dx *= clamp / max|dx|   # direction-preserving
    # ---- shared acceptance (ngspice order) ----
    x_old = x;  x += dx
    scaled = max_i |dx_i| / (reltol*max(|x_i|,|x_old_i|) + atol_i)
    limited = apply pnjlim/fetlim/limvds per device (companion-corrected)
    if state flip:      continue                # discontinuity, iterate
    if limited:         continue
    if iter == 0:       continue                # never accept iteration 1
    if scaled >= 1:     continue
    if any |F_i| > max(residual_tol, 10*|J_ii|*(reltol*|x_i|+vntol)): continue
    return converged(iter+1, scaled)
  return not converged

pnjlim(vnew, vold, vt, vcrit):                  # ngspice devsup.c, exact
  if vnew > vcrit and |vnew - vold| > 2*vt:
    if vold > 0:
      arg = (vnew - vold) / vt
      vnew = vold + vt*(2 + ln(arg - 2))   if arg > 0
           = vold - vt*(2 + ln(2 - arg))   otherwise
    else: vnew = vt * ln(vnew / vt)
    limited = true
  elif vnew < 0:                                # Gillespie reverse clamp
    floor = (vold > 0) ? -vold - 1 : 2*vold - 1
    if vnew < floor: vnew = floor; limited = true

jfnk(ckt, x, opts, hook):                       # GMRES(m), right-precond
  for iter in 0..max_iter:
    F0 = residual(x) (+ gmin*x);  build diag precond;  try slv.factor (precond)
    r = M^-1 * (-F0); beta = ||r||; v0 = r/beta; g = beta*e1
    for j in 0..m:
      w = M^-1 * (F(x + eps*v_j) - F0)/eps      # one residual eval per vector
      modified Gram-Schmidt against v_0..v_j -> h_*j, v_{j+1}
      Givens-rotate column j; update g; break if |g_{j+1}| small
    back-solve H y = g;  dx = V y;  damp
    finalizeStep(...)  # SAME gates as newton
```

## 4. Pseudo-code, GPU parallel

JFNK is the GPU-native strategy: its primitives are residual evals
(device-parallel across devices/nodes), axpy/dot (parallel reductions),
and small host-side $H$ updates. This is what our megakernel implements —
one cooperative launch runs the *whole* Newton solve.

```
arp_solve (device, cooperative launch, our layout):
  # staged prefix: header{t, Tol{reltol,abstol,vntol,residual_tol,gmin,
  #   dx_clamp,max_iter,gmres_m}}, x[n]; SoA problem data; ws after prefix
  for iter in 0..max_iter:                      # loop entirely on device
    parfor device batches: eval -> stamp F (and J·v support data)
    grid barrier
    GMRES(m): each Krylov vector =
      parfor: x_pert = x + eps*v
      parfor batches: residual eval at x_pert   # the dominant kernel work
      parfor: w = (F_pert - F0)/eps; precondition (diag: one parfor mul)
      dot/norm = grid reductions; H/Givens on thread 0 (n_gmres ~ 30: cheap)
      grid barrier per vector                   # SERIALIZES: Arnoldi chain
    parfor: dx = V y; damp by grid-max reduction
    parfor: x += dx; limiting per device (pnjlim/fetlim in the kernel)
    grid reductions: scaled norm, limited-flag, residual gate
    if accepted: write ResultHeader{status, iterations, max_dx}; break
  # host: ONE HtoD (prefix), ONE launch, ONE DtoH (x + ResultHeader);
  # non-finite x is not copied back (poisoned warm start guard);
  # non-convergence falls back host-side: JFNK (CPU) then direct Newton.

what fundamentally serializes:
  - Newton iterations (x^(m+1) needs x^(m)) — irreducible outer chain
  - Arnoldi: v_{j+1} needs v_j orthogonalized — m sequential J·v evals;
    s-step/communication-avoiding GMRES trades stability for fewer barriers
  - grid barriers between eval/reduce phases — the cooperative-launch cost
direct-Newton-on-GPU alternative: level-set refactor + batched solve
  (see klu-pipeline.md §4 / gpu-sparse-lu.md) — wins when m·(eval cost)
  exceeds refactor cost, i.e. big linear-ish circuits.
```

---

**Sources fetched:** ngspice `src/spicelib/devices/devsup.c` (fetched raw —
DEVpnjlim, DEVfetlim, DEVlimvds verbatim); ngspice `cktop.c` (fetched, for
the caller ladder — see `homotopy-continuation.md`); thesis (fetched, for
the linear-solver contract). ngspice `niconv.c`/`niiter.c` not fetched this
session — the criteria match ngspice's documented NIconvTest semantics and
our previously-verified implementation.

**Verification status:** §1 limiting math — source-verified against fetched
devsup.c. §1 convergence criteria — verified against our implementation,
which was previously validated ngspice-exact (`updateAndNorm` cites
NIconvTest; niiter.c "iterno != 1" rule); marked high-confidence but not
re-fetched. §1 residual gate — our addition, not ngspice (documented as
such in the code). §1 JFNK/GMRES math — derived, not source-verified
(standard Saad/Kelley material; Kelley & Keyes paywalled). §2/§3 — verified
against `converger.zig` directly. §4 — verified against
`src/gpu_context.zig` + `converger.run` dispatch; kernel internals
paraphrase our ABI (`analysis.gpu_abi`).

**Our implementation:** `src/solvers/converger.zig`
(`newton`, `jfnk`, `finalizeStep`, `dampStep`, `updateAndNorm`,
`Tolerances`); device limiting in `src/devices/*.zig`
(`ckt.applyLimits`); GPU driver `src/gpu_context.zig` (`solveNewton`).
Fixtures: `benchmark/fixtures/convergence/{diode_bridge,schmitt,
high_gain_fb}`, `benchmark/fixtures/op/`, scaling:
`inverter_chain_{256,1k,4k}` (Newton per step),
`parallel_inverters_2000` (JFNK/GPU eval dominance).
