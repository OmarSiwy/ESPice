# DC Mismatch (dcmatch)

Random-mismatch-induced offset at the operating point (Spectre `dcmatch`).

`src/analysis/dc/dcmatch.zig` implements the adjoint solve with
finite-difference parameter stamps. It uses Pelgrom metadata when present
and unit variance otherwise. Analytic parameter-derivative stamps and
AC mismatch remain extensions.

## 1. Mathematical specification

Device-to-device *mismatch* (local variation, uncorrelated between
instances — unlike the correlated process variation Monte-Carlo corners
model) perturbs each device $d$'s parameters by zero-mean random
$\delta p_d$ with variance from the Pelgrom model:

$$
\sigma^2(\delta P_d) = \frac{A_P^2}{W_d L_d} \;(+\, S_P^2 D^2),
$$

($A_{VT}, A_\beta$ area coefficients; distance term usually dropped). To
first order the induced output offset is

$$
\delta y = \sum_d \frac{\partial y}{\partial p_d}\, \delta p_d
\quad\Rightarrow\quad
\sigma^2(y) = \sum_d \Big(\frac{\partial y}{\partial p_d}\Big)^2 \sigma^2(\delta p_d),
$$

since mismatch contributions are independent. The sensitivities are
exactly the adjoint-sensitivity quantities of
[sensitivity.md](sensitivity.md) §1: **one transposed solve**
$J^{\mathsf T}\lambda = e_{\text{out}}$ at the operating point, then each
device's contribution is a sparse dot
$\partial y/\partial p_d = -\lambda^{\mathsf T} (\partial F/\partial p_d)$.
Output: total $\sigma(y)$ plus the ranked per-device contribution table
(the design-actionable part — "which pair to upsize"). Equivalent
Monte-Carlo (per-instance draws + $N$ re-solves) costs $O(N)$ solves and
converges as $1/\sqrt N$; dcmatch is exact-to-first-order at the cost of
**one** adjoint solve — the entire point of the analysis.

Validity limit: first-order in $\delta p$ — breaks for comparators biased
at metastability or any $y$ with vanishing gradient; Spectre documents the
same caveat.

## 2. Flow

1. OP solve; keep the factored $J$.
2. Adjoint solve $J^{\mathsf T}\lambda = e_{\text{out}}$ on the existing
   factors.
3. Per matched device: mismatch $\sigma(\delta p)$ from model cards
   (Pelgrom coefficients + geometry), stamp-derivative dot against
   $\lambda$, accumulate variance; sort contributions.
4. Report $3\sigma$ offset + contribution table.

An analytic-stamp upgrade needs per-model $\partial F/\partial p$ stamp
derivatives for the mismatch parameters (VT0, beta/KP, R) — the
[parameter-derivative-stamps](../solvers/parameter-derivative-stamps.md)
hook, shared with the adjoint-sensitivity upgrade.

**Mismatch sources are per-device**, consistent with the engine's
in-device noise convention (model sources are in
[models/](../../models/)): Pelgrom coefficients
($A_{VT}, A_\beta$, area terms) live on the device model card next to its
noise PSDs, the device geometry ($W, L$) that sets $\sigma(\delta p)$ is
instance data, and the analysis only consumes the per-device
$(\sigma^2(\delta p_d),\ \partial F/\partial p_d)$ pairs — it never owns a
mismatch table of its own.

## Solvers used and extensions

| Phase | Solver doc | Impl |
|---|---|---|
| Adjoint solve $J^{\mathsf T}\lambda = e_{\text{out}}$ on the OP factors | [klu-pipeline.md](../solvers/klu-pipeline.md) | `direct.zig solveT` (**exists**); one back-substitution total |
| Per-device $\partial F/\partial p$ stamps + adjoint dot accumulation | [parameter-derivative-stamps.md](../solvers/parameter-derivative-stamps.md) | finite differences implemented; analytic `evalp` hook remains a target |
| AC-swept variant (offset vs frequency) | frequency lanes as in [ac-small-signal-noise.md](ac-small-signal-noise.md) §4, complex adjoint via `freq_solve.solveRhsT` (exists) | requirement |

---

**Sources fetched**: none free found for Spectre dcmatch specifics —
**derived, not source-verified** (Pelgrom's paper is paywalled; the
$A/\sqrt{WL}$ law and adjoint formulation are standard). **Implementation
status:** adjoint DC mismatch with finite-difference stamps; analytic
stamps remain an upgrade shared with [sensitivity.md](sensitivity.md).
