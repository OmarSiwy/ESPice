# DC and AC Mismatch (dcmatch, acmatch, dcsens)

Random-mismatch-induced offset at the operating point (Spectre `dcmatch`,
HSPICE `.dcmatch`), its AC counterpart (HSPICE `.acmatch`) and the DC
sensitivity to the variation block (HSPICE `.dcsens`).

`src/analysis/dc/dcmatch.zig` implements the adjoint solve with
finite-difference parameter stamps, `.dcsens` beside it
(`dcmatch.Sens`), and `src/analysis/ac/acmatch.zig` the per-frequency
version. Sigmas come from the deck's variation block when it has one, else
from Pelgrom metadata, else unit variance. Analytic parameter-derivative
stamps remain an extension.

## 1. Mathematical specification

Device-to-device *mismatch* (local variation, uncorrelated between
instances: unlike the correlated process variation Monte-Carlo corners
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
(the design-actionable part: "which pair to upsize"). Equivalent
Monte-Carlo (per-instance draws + $N$ re-solves) costs $O(N)$ solves and
converges as $1/\sqrt N$; dcmatch is exact-to-first-order at the cost of
**one** adjoint solve: the entire point of the analysis.

Validity limit: first-order in $\delta p$: breaks for comparators biased
at metastability or any $y$ with vanishing gradient; Spectre documents the
same caveat.

## 2. Flow

1. Linearize at the executor's operating point `ctx.x_op`; factor $J$.
2. Adjoint solve $J^{\mathsf T}\lambda = e_{\text{out}}$ on the existing
   factors.
3. Per matched device: mismatch $\sigma(\delta p)$ from model cards
   (Pelgrom coefficients + geometry), stamp-derivative dot against
   $\lambda$, accumulate variance; sort contributions.
4. Report $3\sigma$ offset + contribution table.

`src/analysis/dc/dcmatch.zig` computes $\partial F/\partial p_d$ as a forward
difference of $F(x_{op})$, re-deriving only the perturbed device's type
(`recomputeType`, as in [sensitivity.md](sensitivity.md) §2, with the same
measured cost on resistor-only decks). Its dot uses a per-block `@reduce`
summation order that differs from `sens.zig`'s, so the two must not share
the kernel without accepting a rounding change.

An analytic-stamp upgrade needs per-model $\partial F/\partial p$ stamp
derivatives for the mismatch parameters (VT0, beta/KP, R): the
[parameter-derivative-stamps](../solvers/parameter-derivative-stamps.md)
hook, shared with the adjoint-sensitivity upgrade.

**Mismatch sources are per-device**, consistent with the engine's
in-device noise convention (model sources are in
[models/](../../models/)): Pelgrom coefficients
($A_{VT}, A_\beta$, area terms) live on the device model card next to its
noise PSDs, the device geometry ($W, L$) that sets $\sigma(\delta p)$ is
instance data, and the analysis only consumes the per-device
$(\sigma^2(\delta p_d),\ \partial F/\partial p_d)$ pairs: it never owns a
mismatch table of its own.

## 3. Variation groups

A deck with a `.variation` block (or `DEV`/`LOT` on a model value) hands
`.dcmatch`, `.acmatch` and `.dcsens` its rows as `core.query.Variations`
(`variants.Planner.variations`): a per-device row (`.local_variation`,
`.element_variation`, `DEV`) is one group per device it reaches, labelled
`<card>@<param>`; a per-model row (`.global_variation`, `LOT`) is one group
moving every device of the model together, labelled `<model>@<param>`. A
member's step is one sigma: the row's value, times the nominal when
relative, over $\sqrt 3$ for a uniform spread. A group's column is then
$dy/d\sigma_g = \sum_k (\partial y/\partial p_k)\,\sigma_k$ and the total
variance $\sum_g (dy/d\sigma_g)^2$. Without a variation block every
collected parameter is its own group and its column stays $dy/dp$, as
before, so existing decks are unchanged.

HSPICE splits `.dcmatch` into global, local and spatial tables, with a
matched-pair guess; ESPice publishes one list over every group, local and
global together, 3-sigma total first. `.dcsens` publishes each group's
$dy/d\sigma$ in group order (HSPICE's `PERTURBATION=` finite difference
is replaced by the adjoint derivative, so it is accepted and unused).
The listing keywords (`THRESHOLD`, `FILE`, `INTERVAL`, `GROUPBYDEVICE`,
the virtual-sensitivity options) are checked and unused: every group is
published.

## 4. AC mismatch

`.acmatch v(out)` runs over the `.ac` sweep. With $A = G + j\omega C$,
$A x = b$ the AC solution and $A^{\mathsf T}\lambda = e_{\text{out}}$, a
parameter moves the output by

$$
\frac{dy}{dp} = -\lambda^{\mathsf T}\Big(\frac{dG}{dp} + j\omega\frac{dC}{dp}\Big)x,
$$

where the total derivatives include the operating point's own shift,
$dx_{op}/dp = -J^{-1}\partial F/\partial p$ (one solve on the DC factor).
Per parameter: one eval at $(p+\delta, x_{op})$ for $\partial F/\partial p$,
one at $(p+\delta, x_{op}+\delta\,dx_{op}/dp)$ for the planes, then one
pass over the pattern per frequency. The forward and adjoint AC solutions
come from two `freq.Stream` sweeps (frequency lanes); the stacked-real
transpose solve returns $\bar\lambda$. Columns: `acm_mag`, `acm_phase`
(degrees), `acm_re`, `acm_im`, the 1-sigma spreads of $|y|$, $\angle y$,
Re and Im, each summing the groups' linear changes in quadrature; then
each group's complex $dy/d\sigma$. The oracle deck
`tests/fixtures/hspice/match_diode` biases a diode through a varied
resistor, so the AC spread is almost entirely the operating-point shift;
it matches the analytic derivative to the forward difference's 2e-6.
`ponytail:` $dG/dp$ and $dC/dp$ come from the plain eval, so an `ac=`
resistor value and the frequency-dependent `acDyn` stamps (lines) carry no
parameter derivative, and only `v(...)` outputs are accepted (not HSPICE's
`vm`/`vp`/`i(...)` forms).

## Solvers used and extensions

| Phase | Solver doc | Impl |
|---|---|---|
| Adjoint solve $J^{\mathsf T}\lambda = e_{\text{out}}$ on the OP factors | [klu-pipeline.md](../solvers/klu-pipeline.md) | `direct.Solver.solveT`; one back-substitution total |
| Per-device $\partial F/\partial p$ stamps + adjoint dot accumulation | [parameter-derivative-stamps.md](../solvers/parameter-derivative-stamps.md) | finite differences implemented; analytic `evalp` hook remains a target |
| AC-swept variant (`.acmatch`) | frequency lanes as in [ac-small-signal-noise.md](ac-small-signal-noise.md) §4, complex adjoint via `freq_solve` | `ac/acmatch.zig` |

---

**Sources fetched**: none free found for Spectre dcmatch specifics -
**derived, not source-verified** (Pelgrom's paper is paywalled; the
$A/\sqrt{WL}$ law and adjoint formulation are standard). **Implementation
status:** adjoint DC mismatch with finite-difference stamps; analytic
stamps remain an upgrade shared with [sensitivity.md](sensitivity.md).
