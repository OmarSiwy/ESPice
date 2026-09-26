# Sensitivity Analysis (DC + AC)

Direct, adjoint and finite-difference methods; the implementation is adjoint
with finite-difference stamp derivatives.

## 1. Mathematical specification

Wanted: $\partial y / \partial p_j$ for one output $y = c^{\mathsf T} x$ and
parameters $p_1 \dots p_m$ (device/model values). Differentiate
$F(x; p) = 0$:

$$
J \frac{\partial x}{\partial p_j} = -\frac{\partial F}{\partial p_j}
\qquad\Rightarrow\qquad
\frac{\partial y}{\partial p_j} = -\,c^{\mathsf T} J^{-1} \frac{\partial F}{\partial p_j}.
$$

Three evaluation strategies, all computing the same quantity:

**Direct (forward) method**: one linear solve per parameter on the
already-factored $J$:
$J\,s_j = -\partial F/\partial p_j$, then $\partial y/\partial p_j = c^{\mathsf T} s_j$.
Cost: 1 factorization + $m$ back-substitutions. Right choice when many
outputs, few parameters.

**Adjoint method**: one *transposed* solve total:

$$
J^{\mathsf T} \lambda = c
\qquad\Rightarrow\qquad
\frac{\partial y}{\partial p_j} = -\,\lambda^{\mathsf T} \frac{\partial F}{\partial p_j},
$$

each parameter then costs one sparse dot against its stamp derivative
(a handful of entries: a resistor's $\partial F/\partial G$ touches 4).
Cost: 1 factorization + 1 back-substitution + $m$ dots. Right choice for
the SPICE .SENS shape (one output, *all* parameters): this is Director &
Rohrer's adjoint-network method.

**Finite-difference (perturbation)**: re-solve the nonlinear system at
$p_j + \delta_j$ and difference the outputs:

$$
\frac{\partial y}{\partial p_j} \approx \frac{y(p_j + \delta_j) - y(p_j)}{\delta_j},
\qquad \delta_j = 10^{-6}|p_j| + 10^{-12}.
$$

Cost: $m{+}1$ full Newton solves. Exact for the *actual* engine (includes
every recompute side effect: temperature scaling, derived model
parameters), needs no $\partial F/\partial p$ stamps, but is $O(m)$ solves
and truncation/cancellation-limited ($\delta$ balances truncation
$O(\delta)$ against roundoff $O(\epsilon/\delta)$). This is also what
ngspice does (manual §1.2.6: "by perturbing each parameter of each device
independently... a numerical approximation"; zero-valued parameters are
skipped).

**AC sensitivity** *(not implemented here)*: same identities on the complex
system $A(\omega) = G + j\omega C$ per frequency point:
$\partial X/\partial p_j = -A^{-1}(\partial A/\partial p_j) X$, adjoint form
$A^{\mathsf H}\lambda = c$ then
$\partial X_{\text{out}}/\partial p_j = -\lambda^{\mathsf H}(\partial A/\partial p_j)X$
- one extra transposed solve per frequency on the AC sweep's existing
factorization (the same `solveRhsT` the noise analysis already uses).

**Our implementation choice:** the adjoint method with a finite-difference
stamp derivative. One factorization of $J$ at the operating point and one
transposed solve give $\lambda$; each parameter then costs one re-evaluation
of $F(x_{op})$ with that parameter nudged, and
$\partial y/\partial p_j \approx -\lambda^{\mathsf T}(F(x_{op}; p_j + \delta_j) - F(x_{op}; p_j))/\delta_j$.
That replaces the $m$ Newton solves of full finite differencing with $m$
residual evaluations and dots, and needs no analytic
$\partial F/\partial p$ stamps. Two refinements: the difference is taken
against the step the parameter actually stored (an f32 parameter rounds
$\delta$, and the requested $\delta$ would give a wrong derivative, not a
small one), and a zero stored step is an error (`error.ZeroDelta`).
ngspice's `.sens` uses per-device analytic sensitivities (`cktsens.c`);
analytic stamps are the upgrade
([parameter-derivative-stamps.md](../solvers/parameter-derivative-stamps.md)).

## 2. Flow explanation

`src/analysis/sweep/sens.zig`:

1. Linearize at the executor's operating point `ctx.x_op`, the result of the
   full OP ladder. An earlier version ran its own cold Newton here, which
   fails on circuits that need stepping (commit `ff3e91f`; no deck bytes
   changed). `computeBaseline()` is deliberately not called: the baseline
   would freeze the const-Jacobian stamps (resistors) and mask the very
   perturbations being measured.
2. `evalNewton(x_op)`, keep the nominal residual, factor $J$, and solve
   $J^{\mathsf T}\lambda = e_{\text{out}}$ (for `v(a,b)` the seed is
   $e_a - e_b$).
3. Per parameter from `collectParams`: write $p_j + \delta_j$ with
   $\delta_j = 10^{-6}|p_j| + 10^{-12}$, re-derive only that device type
   (`recomputeType`), read back the stored step, re-evaluate $F(x_{op})$, and
   take the fused dot. The parameter is restored on every exit path. A
   parameter whose nominal value collapses an internal node (for example
   Gummel-Poon RC/RE = 0, MOS1 RD/RS = 0) is re-wired by the $10^{-12}$
   floor, the batch reports `TopologyChanged`, and the derivative is reported
   as 0: the perturbed circuit has a node the frozen pattern lacks. ngspice
   never perturbs a topology parameter.
4. Columns carry ngspice's names (`cktsens.c:224-238`): `<card>:<param>` for
   a model parameter, `<card>` for the principal instance parameter,
   `<card>_<param>` for any other instance parameter.

Per-parameter re-derivation through `recomputeType` instead of a full
`recompute` (commit `148361f`) took `multi_analysis/bench_sens_diffpair`
(4 BJTs) from 80.61M to 42.51M Ir (-47.3%) and `sens/bench_sens_bridge` from
1.930M to 1.896M. Resistor-only decks (`sens/divider`,
`sens/high_impedance`, `dcmatch/divider_0_1000`,
`dcmatch/high_resistance`) got 0.8% to 2.4% slower (15k to 36k Ir), because
the type-name match costs more than recomputing a resistor.

Knobs: `output_node` (default: the last probe), `output_neg`. $\delta$ is
fixed at $10^{-6}|p| + 10^{-12}$ (relative with an absolute floor).

## 3. Pseudo-code, CPU sequential

```
sens(ckt, x_op, params, out):
    ws = workspace(ckt)
    F0 = evalNewton(x_op); factor(J)
    lambda = solveT(J, e_out)               # ONE transposed solve
    for p in params:
        p.set(p.nominal + 1e-6*|p| + 1e-12); recomputeType(p.type)
        if TopologyChanged: S[p] = 0; restore; continue
        delta = p.value - p.nominal         # what the parameter actually stored
        F = evalNewton(x_op)
        S[p] = -dot(lambda, (F - F0)/delta)
        p.restore(); recomputeType(p.type)
```

## 4. Parallel execution

Everything runs on the host. The per-parameter loop is embarrassingly
parallel (each iteration is one residual evaluation and a dot), but it
mutates the shared circuit's parameters, so parallelizing it would need
per-lane parameter copies. Not implemented. AC sensitivity would batch over
frequency points on top, as in
[ac-small-signal-noise.md](ac-small-signal-noise.md) §4.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| One factorization of $J$ at the OP | [klu-pipeline.md](../solvers/klu-pipeline.md) | `ws.slv.factor` (`src/solver/direct.zig`) |
| Adjoint (transposed solve on the same factors) | [klu-pipeline.md](../solvers/klu-pipeline.md) (solve with $L^{\mathsf T}U^{\mathsf T}$ order swapped) | `direct.Solver.solveT`; `freq_solve` adjoint `solveBatch` for the AC case (not implemented) |
| Analytic $\partial F/\partial p$ stamps (upgrade) | [parameter-derivative-stamps.md](../solvers/parameter-derivative-stamps.md) | not implemented |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §1.2.6/§11.3.7 (.SENS) | fetched, verified: perturbation method, zero-param skipping, second-order caveat |
| Director & Rohrer adjoint sensitivity | paywalled; derived, not source-verified (standard result) |

**Per-section verification**

- §1 three methods and cost model: direct/adjoint derived (textbook); FD
  verified against the ngspice manual.
- §2/§3: transcribed from `sens.zig`. AC sensitivity: not implemented, math
  given for the upgrade.
- §4: design note.

**Our implementation**

- `src/analysis/sweep/sens.zig`: adjoint DC sensitivity with FD stamps.
- Fixtures: `tests/fixtures/sens/`, `tests/fixtures/multi_analysis/bench_sens_diffpair`.
