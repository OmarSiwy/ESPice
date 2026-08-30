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
| `reltol` | — | everything (relative part) | $10^{-3}$ |
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

**Residual (KCL) test** — update tests alone accept false solutions when the
Jacobian is ill-conditioned ($\Delta x$ small because $J$ is huge, not
because $F$ is small); the row-scaled residual gate

$$
|F_i| \le \max\big(\texttt{residual\_tol},\ 10\,|A_{ii}|(\texttt{reltol}|x_i| + \texttt{vntol})\big)
$$

bounds the KCL error a legitimate final step may leave:
$|J\Delta x| \approx |A_{ii}||\Delta x_i|$ at the just-passed update
tolerance, with a 10× safety factor.

**LTE test** (transient, per charge state — see
[transient-integration.md](transient-integration.md)):

$$
\text{LTE}_j \;\lesssim\; \texttt{trtol}\cdot\max\Big(
\underbrace{\texttt{abstol} + \texttt{reltol}\max(|i_j|,|i_{j,\text{prev}}|)}_{\text{current scale}},\;
\underbrace{\texttt{reltol}\,\tfrac{\max(|q_j|, \texttt{chgtol})}{h}}_{\text{charge scale}}\Big).
$$

`trtol` deflates the theoretical LTE bound by its empirical pessimism
(SPICE default 7; **`trtol` = 1 is the "conservative" setting** — the bound
taken at face value).

`gmin` ($10^{-12}$ S) is not an error tolerance but a regularization floor:
it bounds the resistance the simulator will represent
($10^{12}\,\Omega$), which in turn bounds attainable accuracy on
high-impedance nodes — a tolerance bundle that tightens `abstol` below
`gmin`·`vntol` without lowering `gmin` is inconsistent.

### errpreset bundles

*(derived, not source-verified — Spectre documentation is proprietary; the
mapping below follows Kundert, "The Designer's Guide to SPICE and Spectre",
and public Spectre UI docs from knowledge)*

Spectre's `errpreset` sets a coherent bundle rather than single knobs:

| errpreset | reltol | Integration | LTE stance |
|---|---|---|---|
| `liberal` | $10^{-3}$ | trap fallback, loose maxstep | speed |
| `moderate` | $10^{-3}$ | trap, moderate LTE | default |
| `conservative` | $10^{-4}$ | gear2only/trap, strict LTE (`lteratio` small), tight maxstep | accuracy |

The load-bearing ideas: (1) *bundles*, because tolerances interact — tight
`reltol` with `trtol` 7 wastes Newton effort on steps LTE then rejects;
(2) errpreset scales `reltol` and the LTE strictness *together*.

### Our bundles

`converger.Tolerances` named profiles are this engine's errpreset
equivalents — one struct, set once at the engine level, propagated into
every analysis:

| Profile | reltol | vntol | abstol | gmin | trtol | other |
|---|---|---|---|---|---|---|
| `.ngspice` (default) | 1e-3 | 1e-6 | 1e-12 | 1e-12 | 7 | itl1 100 |
| `.hspice` | 1e-3 | 1e-6 | 1e-12 | 1e-12 | 7 | itl1 150 |
| `.ltspice` | 1e-3 | 1e-6 | 1e-12 | 1e-12 | **1** | source_steps 25 |
| `.tight` | **1e-6** | **1e-9** | **1e-15** | **1e-15** | **1** | — |

`.tight` is the `conservative` analogue (reltol and floors scaled down
together, LTE at face value); `.ltspice` shows the trtol axis alone.
Benchmarking against a specific tool is one field change.

## 2. Flow explanation

There is exactly one tolerance struct
(`src/solvers/converger.zig Tolerances`) and one place
convergence is decided (`finalizeStep`), used by both the direct-Newton and
JFNK paths so they cannot drift; the GPU megakernel mirrors the same gates
so CPU and GPU accept identical iterates. Analyses never construct raw
Newton options — they call `Tolerances.newtonOpts()`, optionally overriding
only the iteration budget (ITL1 = 100 for DC, ITL4 = 10 per transient
point, matching SPICE's ITLn split: DC gets a long leash, a transient point
that needs > 10 iterations is cheaper to redo at smaller $h$).

Knob-by-knob meaning, in flow order:

- `gmin_start`, `source_steps` — DC continuation ladder geometry only.
- `reltol`, `vntol`, `abstol` — Newton acceptance in every analysis
  (DC, transient point, PSS inner step, HB via its own spectral residual).
- `residual_tol` — floor of the KCL residual gate; catches
  silently-singular solves.
- `dx_clamp` — direction-preserving damping bound; default $\infty$
  (device limiting is the globalization; see OP doc).
- `chgtol`, `trtol` — transient LTE only.
- `itl1/itl2/itl4` — iteration budgets (DC / DC-sweep continuation /
  transient point).

Failure semantics: tolerances are never loosened adaptively; failure at a
given bundle escalates *strategy* (homotopy rung, order drop, step halving),
not accuracy. This is the Spectre stance — accuracy is a contract, effort is
adaptive.

## 3. Pseudo-code, CPU sequential

```
# the single acceptance kernel every analysis funnels through
finalize_step(x, dx, x_old, F, A_diag, iter, tol) -> accepted?:
    worst = max_i |dx_i| / (tol.reltol*max(|x_i|,|x_old_i|)
                            + (current_row(i) ? tol.abstol : tol.vntol))
    if device_limited or state_flipped: return no      # forces re-iterate
    if iter == 0:                        return no      # never accept iter 1
    if worst >= 1:                       return no
    for each row i:
        gate = max(tol.residual_tol,
                   10*|A_diag[i]|*(tol.reltol*|x_i| + tol.vntol))
        if |F_i| > gate:                 return no
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

# profile selection = errpreset
tol = Tolerances.ngspice          # or .hspice / .ltspice / .tight
engine.run_all_analyses(tol)      # one bundle, everywhere
```

## 4. Pseudo-code, GPU parallel

Tolerances are scalars — the GPU story is that the *gates* evaluate in
parallel and reduce, and that the constants ride in the problem blob so the
whole convergence decision happens on-device (no readback per iteration).

```
kernel (inside newton/jfnk megakernel):
    # weighted update norm: grid-stride + max-reduction
    parallel over i: w_i = |dx_i| / (reltol*max(|x_i|,|x_old_i|) + atol_i)
    block-reduce max -> partials[block]; thread0 reduces partials
    # residual gate: same shape
    parallel over i: ok_i = |F_i| <= max(residual_tol, 10*|diag_i|*(reltol*|x_i|+vntol))
    grid AND-reduction
    # limiting flag: per-batch grid-stride pass returns 1.0 if any limited
    thread0: combine (limited, flipped, iter>0, worst<1, residuals ok)
             -> publish converged flag in workspace scalar slot
    grid_barrier                    # all threads read the decision
```

Batched analyses (Monte-Carlo/corners) share one tolerance bundle across
all lanes; per-lane convergence flags reduce independently, so one slow lane
never loosens (or blocks) another's acceptance.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| The acceptance gates themselves (reltol/vntol/abstol semantics, residual gate) | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `converger.finalizeStep` / `updateAndNorm` |
| Solver-accuracy features the bundles lean on (pivot-growth monitor; condition estimation + iterative refinement documented-but-skipped) | [klu-pipeline.md](../solvers/klu-pipeline.md) | `src/solvers/direct.zig` |
| `gmin` floor as solver regularization | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | diagonal stamp in `converger.newton`/`jfnk` |

---

**Sources fetched**

| Source | Status |
|---|---|
| designers-guide.org analysis + theory index pages | fetched — no standalone tolerance paper listed on the fetched pages; rf-sim.pdf fetched for context |
| Spectre errpreset semantics / Kundert *Designer's Guide to SPICE and Spectre* | **book/proprietary docs — derived, not source-verified** |
| ngspice defaults (reltol/abstol/vntol/chgtol/trtol/ITLn) | verified against our `Tolerances` struct which pins them; ngspice manual not re-fetched |

**Per-section verification**

- §1 tolerance semantics + where each bites: verified against
  `converger.zig` (`updateAndNorm`, `finalizeStep`) and `tran.zig`
  (`stepBound`) — line-for-line.
- §1 errpreset table: derived, not source-verified (marked).
- §1 our-bundles table: verified, direct transcription of
  `Tolerances.{ngspice,hspice,ltspice,tight}`.
- §3/§4: direct transcription of repo source.

**Our implementation**

- `src/solvers/converger.zig` — `Tolerances`, profiles,
  `newtonOpts`, `finalizeStep`, `updateAndNorm`.
- `src/analysis/tran/tran.zig` — `chgtol`/`trtol` consumers.
- `src/devices/engine.zig` — on-device gate mirror.
- Bench fixtures: accuracy columns across `benchmark/RESULTS.md` are
  produced under `.ngspice`; `benchmark/fixtures/convergence/*` and
  `benchmark/fixtures/adversarial/*` stress the gates.
