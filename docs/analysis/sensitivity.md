# Sensitivity Analysis (DC + AC)

Direct vs adjoint methods; our brute-force implementation and its upgrade
path.

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

**Direct (forward) method** — one linear solve per parameter on the
already-factored $J$:
$J\,s_j = -\partial F/\partial p_j$, then $\partial y/\partial p_j = c^{\mathsf T} s_j$.
Cost: 1 factorization + $m$ back-substitutions. Right choice when many
outputs, few parameters.

**Adjoint method** — one *transposed* solve total:

$$
J^{\mathsf T} \lambda = c
\qquad\Rightarrow\qquad
\frac{\partial y}{\partial p_j} = -\,\lambda^{\mathsf T} \frac{\partial F}{\partial p_j},
$$

each parameter then costs one sparse dot against its stamp derivative
(a handful of entries — a resistor's $\partial F/\partial G$ touches 4).
Cost: 1 factorization + 1 back-substitution + $m$ dots. Right choice for
the SPICE .SENS shape (one output, *all* parameters) — this is Director &
Rohrer's adjoint-network method.

**Finite-difference (perturbation)** — re-solve the nonlinear system at
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
— one extra transposed solve per frequency on the AC sweep's existing
factorization (the same `solveRhsT` the noise analysis already uses).

**Our implementation choice:** finite-difference (matches ngspice), one
f32-aware refinement — the FD is taken against the step the f32 parameter
*actually* took after rounding, not the requested $\delta$, eliminating a
systematic quantization error. Adjoint is the documented upgrade when $m$
grows (it drops $m$ Newton solves to $m$ dots).

## 2. Flow explanation

`src/analysis/sweep/sens.zig`:

1. Collect all device parameters (`collectParams` → raw f32 pointers with
   device/param names). Nominal solve at ITL2 → $y_0$.
   `computeBaseline()` is deliberately **not** called: the baseline would
   freeze const-Jacobian stamps (resistors) and mask the very perturbations
   being measured.
2. Per parameter: write $p_j + \delta_j$, `recompute()`, read back the
   *actual* delta after f32 rounding, cold-start Newton re-solve, FD the
   output node, restore the parameter (defer-guaranteed even on error).
3. One `Workspace` serves nominal + every perturbed solve (frozen
   pattern). A perturbed solve that fails to converge errors the analysis
   (a silent zero would be a wrong answer, not a missing one).

Knobs: `output_node` (default: last probe), the tolerance bundle (ITL2 per
solve). $\delta$ is fixed at $10^{-6}|p| + 10^{-12}$ (relative with an
absolute floor).

## 3. Pseudo-code, CPU sequential

```
sens(ckt, params, out, tol):
    ws = workspace(ckt)                     # one symbolic factorization
    x0 = newton_cold(ckt, ws, itl2); y0 = x0[out]
    for p in params:
        delta_req = 1e-6*|p| + 1e-12
        p.set(p.nominal + delta_req); ckt.recompute()
        delta = f64(p.value) - p.nominal    # what the f32 actually took
        x = newton_cold(ckt, ws, itl2)      # fail -> analysis error
        S[p] = (x[out] - y0)/delta
        p.restore()
    ckt.recompute()

# adjoint upgrade (documented, not implemented):
sens_adjoint(ckt, params, out):
    solve nominal; keep factored J
    lambda = solveT(J, e_out)               # ONE transposed solve
    for p in params: S[p] = -dot(lambda, dF_dp_stamp(p))   # ~4 flops each
```

## 4. Pseudo-code, GPU parallel

The FD method is embarrassingly parallel over parameters — each perturbed
solve is an independent Newton problem on the same pattern:

```
host: build L = m perturbed blob instances (one param each nudged)
kernel lanes 0..m: cold newton/jfnk per lane (megakernel batching)
host:  S[j] = (y_j - y_0)/delta_j
```

The adjoint method is the *cheaper* GPU story: one transposed solve
(or transposed-GMRES with the batched-eval $J^{\mathsf T} v$ apply), then a
grid-stride pass computing all $m$ dots at once — parameters map to
instances, so the dot pass is exactly one batched SoA sweep over the device
batches accumulating $\lambda_p - \lambda_n$ terms. AC sensitivity batches
over frequency points on top (independent lanes, as in
[ac-small-signal-noise.md](ac-small-signal-noise.md) §4).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Nominal + perturbed Newton solves (refactor on frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/analysis/solvers/direct.zig` via `converger.run` |
| Workspace/pattern reuse across all solves | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `ckt.workspace()` |
| Adjoint upgrade (transposed solve on existing factors) | [klu-pipeline.md](../solvers/klu-pipeline.md) (solve with $L^{\mathsf T}U^{\mathsf T}$ order swapped) | `direct.zig` solveT / `freq_solve.zig` `solveRhsT` (AC case) |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual §1.2.6/§11.3.7 (.SENS) | **fetched, verified** — perturbation method, zero-param skipping, second-order caveat |
| Director & Rohrer adjoint sensitivity | **paywalled — derived, not source-verified** (standard result) |

**Per-section verification**

- §1 three methods + cost model: direct/adjoint derived (textbook);
  FD verified against ngspice manual + our source (incl. the
  actual-f32-delta refinement, which is ours).
- §2/§3: direct transcription of `sens.zig`. AC sensitivity: not
  implemented, math given for the upgrade.
- §4: prospective.

**Our implementation**

- `src/analysis/sweep/sens.zig` — brute-force DC sensitivity.
- Bench fixtures: `benchmark/fixtures/sens/*`.
