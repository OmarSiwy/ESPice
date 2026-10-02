# Spectre-Style Tolerance System

`reltol` / `abstol` / `vntol` / `chgtol` semantics and errpreset-style
bundles.

## 1. Mathematical specification

### The unified error model

Every acceptance decision in the engine is an inequality of the form

$$
|\varepsilon_i| \;<\; \texttt{reltol}\cdot S_i \;+\; a_i,
$$

where $\varepsilon_i$ is an error estimate for row/state $i$, $S_i$ a scale
of the quantity being bounded, and $a_i$ an absolute floor that takes over
when the signal is near zero. The four tolerances select the floor by
physical unit:

| Knob | Unit | Floors errors in | Default |
|---|---|---|---|
| `reltol` | none | everything (relative part) | $10^{-3}$ |
| `vntol` | V | node voltages | $10^{-6}$ |
| `abstol` | A | branch/device currents | $10^{-12}$ |
| `chgtol` | C | charges (LTE control) | $10^{-14}$ |

Semantics: a computed voltage is *converged* when it is known to
$\max(\texttt{reltol}\cdot|v|,\ \texttt{vntol})$; a current to
$\max(\texttt{reltol}\cdot|i|,\ \texttt{abstol})$. The absolute floors
encode "smallest value anyone designs to": 1 µV, 1 pA, 0.01 fC. Setting
`reltol` tighter without touching the floors tightens *large*-signal
accuracy only.

### Where each inequality bites

**Newton update test** (per variable $i$, both DC and each transient step):

$$
\frac{|\Delta x_i|}{\texttt{reltol}\cdot\max(|x^{k+1}_i|,|x^k_i|) + a_i} < 1,
\qquad a_i \in \{\texttt{vntol}, \texttt{abstol}\}.
$$

**Residual (KCL) test.** Update tests alone accept false solutions when the
Jacobian is ill-conditioned ($\Delta x$ small because $J$ is huge, not
because $F$ is small); the row-scaled residual gate

$$
|F_i| \le \max\big(\texttt{residual\_tol},\ 10\,|A_{ii}|(\texttt{reltol}|x_i| + \texttt{vntol})\big)
$$

bounds the KCL error a legitimate final step may leave:
$|J\Delta x| \approx |A_{ii}||\Delta x_i|$ at the just-passed update
tolerance, with a 10x safety factor. Rows with a zero diagonal
(voltage-defined branches of V/E/H sources) skip it: their scale is the
source gain, and an exact solution still leaves O(gain * eps) residual there
(a 1e9-gain E source reads 2.7e-8). The delta test alone governs those rows,
as in ngspice.

**Divergence from ngspice (open, issues.md F7).** ngspice's `NIconvTest` has
no residual gate: besides the delta test it checks each device current as
`reltol*max(|I_new|, |I_old|) + abstol`. The row-scaled gate here is a
voltage tolerance times the row's diagonal conductance, about 1.5e-4 A on the
supply rows of `bench_tline_ltra1_1_line` and `bench_tline_txl1_1_line`,
which publish v(2) = 5.005 V over a 5 V supply. Disabling the gate on
`vacask_mul` changed the Newton count by 0.01%. Any change to it is global and
needs its own full-corpus A/B; see
[conformance-phase2.md](../conformance-phase2.md) group 8.

The transient steps run without it (`residual_tol = inf` in `tran.zig`), as
ngspice does. There it cost `bench_tline_txl2_3_line` a third iterate on the
step landing on a PULSE corner (the Meyer caps leave 1.3e-7 A on a
source-driven node after the delta test passed), and that iterate split the
grid from ngspice's (20.5x -> 2.3e-6x without it). Full-corpus A/B: with the
gate off everywhere, 13 decks moved and several passing static ones moved
away from their oracles (`pss/polynomial_2` 3.9e-13x -> 0.15x,
`op/bench_analog_diff_pair` 2e-4x -> 4e-3x); off in the transient only, two
decks moved (`txl2_3_line` and the failing `device_mesa_oscillator`, 52.5x ->
54.6x). The static solves keep the gate.

**LTE test** (transient, per charge state; see
[transient-integration.md](transient-integration.md)):

$$
\text{LTE}_j \;\lesssim\; \texttt{trtol}\cdot\max\Big(
\underbrace{\texttt{abstol} + \texttt{reltol}\max(|i_j|,|i_{j,\text{prev}}|)}_{\text{current scale}},\;
\underbrace{\texttt{reltol}\,\tfrac{\max(|q_j|, \texttt{chgtol})}{h}}_{\text{charge scale}}\Big).
$$

`trtol` deflates the theoretical LTE bound by its empirical pessimism
(SPICE default 7; `trtol` = 1 is the conservative setting, the bound taken
at face value).

`gmin` ($10^{-12}$ S) is not an error tolerance but a regularization floor:
it bounds the resistance the simulator will represent
($10^{12}\,\Omega$), which in turn bounds attainable accuracy on
high-impedance nodes. A tolerance bundle that tightens `abstol` below
`gmin`·`vntol` without lowering `gmin` is inconsistent.

### errpreset bundles

*(derived, not source-verified: Spectre documentation is proprietary; the
mapping below follows Kundert, "The Designer's Guide to SPICE and Spectre",
and public Spectre UI docs from knowledge)*

Spectre's `errpreset` sets a coherent bundle rather than single knobs:

| errpreset | reltol | Integration | LTE stance |
|---|---|---|---|
| `liberal` | $10^{-3}$ | trap fallback, loose maxstep | speed |
| `moderate` | $10^{-3}$ | trap, moderate LTE | default |
| `conservative` | $10^{-4}$ | gear2only/trap, strict LTE (`lteratio` small), tight maxstep | accuracy |

The load-bearing ideas: (1) *bundles*, because tolerances interact: tight
`reltol` with `trtol` 7 wastes Newton effort on steps LTE then rejects;
(2) errpreset scales `reltol` and the LTE strictness *together*.

### Our knobs

There are no named bundles. One struct, `Tolerances`
(`src/core/numerics.zig`), holds ngspice's defaults and is set per deck from
`.options` (`reltol`, `abstol`, `vntol`, `gmin`, `trtol`, `chgtol`, `itl1`,
`itl2`, `itl4`; parsed in `src/frontend/analyses.zig`):

| Field | Default | Used by |
|---|---|---|
| `reltol` | 1e-3 | Newton delta test, residual gate, LTE |
| `abstol` | 1e-12 A | Newton delta test on current rows, LTE |
| `vntol` | 1e-6 V | Newton delta test on voltage rows, residual gate |
| `gmin` | 1e-12 S | target of the gmin-stepping rung |
| `residual_tol` | 1e-9 | floor of the residual gate |
| `gmin_start` | 1e-2 S | first rung of gmin stepping |
| `itl1` / `itl2` / `itl4` | 100 / 50 / 10 | Newton budgets: DC OP and final clean solves / stepping rungs and DC sweep points / transient point |
| `chgtol` | 1e-14 C | LTE charge floor |
| `trtol` | 7 | LTE overshoot factor |

An errpreset-style profile would be a set of these values chosen together
(for example `trtol` 1 with reltol, vntol and abstol scaled down). Not
implemented: no deck has needed one, and `.options` covers each knob.

### HSPICE RUNLVL

HSPICE's `.option runlvl=0..6`, `accurate` and `fast` [CR .OPTION RUNLVL,
.OPTION ACCURATE, .OPTION FAST] scale "all simulator tolerances"
together, for the transient only, without publishing the factors. ESPice
maps the level onto `trtol` alone, and leaves `reltol` and the Newton
tests where they are:

| RUNLVL | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| `trtol` | 28 | 14 | 7 | 3.5 | 1.75 | 0.875 |

Level 3 is HSPICE's default, "similar to HSPICE's original default mode",
so it keeps SPICE's 7; each level up halves the LTE bound. As the manual
says: a bare `runlvl` is 3, `runlvl=0` turns the mapping off, the level
overrides `.option trtol` wherever that sits, `accurate` raises any level
below 5 to 5 (alone it means 5), and `fast` alone is level 1. Divergence:
HSPICE's level also changes its bypass and timestep algorithm, which
ESPice does not have. The mapping is ESPice's; unconfirmed against HSPICE.

Measured (2026-10-01, `espice --tokenizer hspice`): 1 V, 1 MHz sine into
1 kΩ and 1 nF, `.tran 1u 5u` (so `dt_max` = 100 ns), maximum error of
`v(b)` against the analytic response:

| RUNLVL | 0 or 3 | 1 | 2 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| time points | 62 | 60 | 61 | 65 | 78 | 99 |
| max error (V) | 7.09e-3 | 7.10e-3 | 7.10e-3 | 6.75e-3 | 4.74e-3 | 3.06e-3 |

Levels 1 and 2 barely move this deck because the 100 ns `dt_max` already
holds the step; they loosen only decks whose steps LTE limits. Fallback:
`.option runlvl=0` with explicit `trtol`, `reltol` and friends.

## 2. Flow explanation

Convergence is decided in one module, `src/solver/converger.zig`:
`finalizeStep` for direct Newton and `residualConverged` plus the same delta
test for JFNK. Analyses build Newton options with
`converger.optionsFromTolerances(tol, max_iter_override)`, overriding only
the iteration budget (ITL1 for DC, ITL4 per transient point, matching
SPICE's ITLn split: DC gets a long leash, and a transient point that needs
more than 10 iterations is cheaper to redo at a smaller $h$). The diagonal
gmin is opt-in: `optionsFromTolerances` sets it to 0, and only the
gmin-stepping rung passes a nonzero value.

Knob by knob, in flow order:

- `gmin_start`, `gmin`: DC gmin-stepping geometry. Source stepping is
  adaptive with fixed constants (start step 0.25, grow 1.5x on success,
  halve on failure, stop below 1e-4 or after 100 solves) in
  `src/analysis/dc/op.zig`; it has no tolerance field.
- `reltol`, `vntol`, `abstol`: Newton acceptance in every analysis (DC,
  transient point, PSS inner step; HB uses its own spectral residual).
- `residual_tol`: floor of the row-scaled residual gate.
- `chgtol`, `trtol`: transient LTE only.
- `itl1`, `itl2`, `itl4`: iteration budgets.

Failure semantics: tolerances are never loosened adaptively. Failure at a
given setting escalates the strategy (homotopy rung, order drop, step cut),
not the accuracy.

## 3. Pseudo-code, CPU sequential

```
# the single acceptance kernel every analysis funnels through
finalize_step(x, dx, x_old, F, A_diag, iter, tol) -> accepted?:
    worst = max_i |dx_i| / (tol.reltol*max(|x_i|,|x_old_i|)
                            + (current_row(i) ? tol.abstol : tol.vntol))
    if device_limited:                   return no      # forces re-iterate
    if iter == 0:                        return no      # never accept iter 1
    if worst >= 1:                       return no
    for each row i with A_diag[i] != 0:  # static solves only
        gate = max(tol.residual_tol,
                   10*|A_diag[i]|*(tol.reltol*|x_i| + tol.vntol))
        if |F_i| > gate:                 return no
    if !device_check_convergence(x):     return no
    if device_state_flipped(x):          return no      # staged last
    return yes

# LTE gate (transient only)
lte_gate(q_hist, i_prev, alpha, h, tol) -> del:
    for each charge state j:
        i_new     = alpha*(q0_j - q1_j) [- i_prev_j]
        volttol   = tol.abstol + tol.reltol*max(|i_new|, |i_prev_j|)
        chargetol = tol.reltol*max(|q0_j|,|q1_j|,tol.chgtol)/h
        del_j     = tol.trtol*max(volttol, chargetol)
                    / max(tol.abstol, c_p*|dd_j|)
    return (order2 ? sqrt : id)(min_j del_j)

# one Tolerances per deck, from .options
tol = Tolerances{} with .options applied
every analysis: opts = optionsFromTolerances(tol, budget)
```

## 4. Parallel execution

Tolerances are scalars. All gates run on the host after each Newton
iterate, including when the GPU evaluates the device planes. Batched
analyses (Monte Carlo, corners) share one `Tolerances` across all lanes, and
each lane converges on its own.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| The acceptance gates themselves (reltol/vntol/abstol semantics, residual gate) | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `converger.finalizeStep`, `residualConverged`, `updateAndNorm` |
| Solver accuracy features (pivot-growth monitor; condition estimation and iterative refinement are not implemented) | [klu-pipeline.md](../solvers/klu-pipeline.md) | `src/solver/direct.zig` |
| `gmin` as solver regularization | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | diagonal stamp in `converger.newton`/`jfnk` when `Options.gmin > 0` |

---

**Sources fetched**

| Source | Status |
|---|---|
| designers-guide.org analysis + theory index pages | fetched; no standalone tolerance paper listed on the fetched pages; rf-sim.pdf fetched for context |
| Spectre errpreset semantics / Kundert *Designer's Guide to SPICE and Spectre* | book and proprietary docs; derived, not source-verified |
| ngspice defaults (reltol/abstol/vntol/chgtol/trtol/ITLn) | verified against the `Tolerances` defaults; ngspice manual not re-fetched |

**Per-section verification**

- §1 tolerance semantics and where each bites: verified against
  `converger.zig` (`updateAndNorm`, `finalizeStep`, `residualConverged`) and
  `integrator.zig` (`stepBound`).
- §1 errpreset table: derived, not source-verified.
- §1 knobs table: transcribed from `Tolerances` in `core/numerics.zig`.
- §2/§3: transcribed from source.

**Our implementation**

- `src/core/numerics.zig`: `Tolerances`.
- `src/solver/converger.zig`: `optionsFromTolerances`, `finalizeStep`,
  `residualConverged`, `updateAndNorm`.
- `src/analysis/tran/integrator.zig`: `chgtol`/`trtol` consumers.
- Fixtures: `tests/fixtures/convergence/` stresses the gates.
