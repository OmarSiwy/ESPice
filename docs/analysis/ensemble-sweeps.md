# Ensemble Sweeps: Monte Carlo / Corners / Temperature

Structural sweep lanes, seed policy, statistics, what parallelizes.

## 1. Mathematical specification

### The common shape

All three analyses evaluate the same map over a parameter ensemble:

$$
y_\ell = h\big(x^\ast(p_\ell)\big), \qquad F(x^\ast(p_\ell);\, p_\ell) = 0,
\qquad \ell = 1 \dots L,
$$

differing only in how $\{p_\ell\}$ is generated:

**Monte Carlo**: random draws per varied parameter. The implementation
draws Gaussian $p = p_0(1 + \tau\, z)$, $z \sim \mathcal N(0,1)$, with $\tau$
the relative variation (`variation`), for every device's nonzero primary
parameter. It publishes one row per converged trial (`run`, then the
probes); the statistics below are for the consumer to compute and are not
built in. Over the $N_c \le L$ converged trials:

$$
\bar y = \frac{1}{N_c}\sum y_\ell, \qquad
s^2 = \frac{1}{N_c - 1}\sum (y_\ell - \bar y)^2
\quad(\text{Bessel-corrected}),
$$

plus min/max and **yield**
$\Pr[y \in [y_{lo}, y_{hi}]] \approx N_{\text{pass}}/N_c$. Monte Carlo
error decays as $s/\sqrt{N_c}$, independent of dimension, which, which is why MC
beats grid corners past a handful of varied parameters.

**Corners**: deterministic $\{p_\ell\}$ at specification extremes
(process/voltage/temperature combinations); worst case, not statistical.
There is no dedicated corner analysis; corner decks such as
`tran/bench_ensemble_pvt_corners` spell the corners out in the netlist.

**Temperature sweep**: a 1-D deterministic ensemble with the SPICE
temperature model applied per point:

$$
R(T) = R(T_{\text{nom}})\big(1 + tc_1 (T - T_{\text{nom}}) + tc_2 (T - T_{\text{nom}})^2\big)
$$

(and device-internal temperature scaling through
`Circuit.setCircuitTemp`).

### Seed policy

The RNG is deterministic and seed-parameterized
(`std.Random.DefaultPrng.init(seed)`, default seed 42): the same netlist +
seed + trial count reproduces the ensemble bit-exactly: a *requirement*
for regression benchmarking and for debugging individual failed trials.
The implementation consumes one stream in trial order and reseeds it on
trial 0, so every run draws the same sequence. A parallel lane executor would
need a counter-based per-trial substream (`hash(seed, trial)`) so trial $k$'s
draws do not depend on scheduling.

### Convergence bookkeeping

A non-converged trial is **dropped, not zeroed**: samples pack converged
trials contiguously, statistics divide by $N_c$, and yield is conditional
on convergence. A high non-convergence rate is itself a result: it shows as
fewer rows than `n_trials`.

## 2. Flow explanation

Both sweeps run on the structural-lane driver `solveLanes`
(`src/analysis/sweep/lanes.zig`): $N$ independent cold DC solves, each after
one parameter install, sharing the circuit pattern and one Newton workspace.
The caller supplies `apply(k)` (install lane $k$'s parameters, called in lane
order) and `restore()`; the driver recomputes after each and restores the
nominals on success and on error. Lanes run serially: this is the
"structural lanes" axis of the lane-axis doctrine in AGENTS.md, not SIMD.

**Monte Carlo** (`src/analysis/sweep/mc.zig`): collect every device's
nonzero primary parameter (`collectParams`); lane $k$ sets each to
`nominal * (1 + variation * N(0,1))`, then a cold DC solve at ITL2. Any
solver error counts as non-convergence and never aborts the ensemble.

**Temperature** (`sweep/temp_sweep.zig`): each lane applies
`setCircuitTemp` and recomputes device-native temperature coefficients
before a cold DC solve at ITL2. Converged points are recorded; failed points
are skipped. `numPoints` uses the same $10^{-6}$-step endpoint nudge as the DC
sweep. The driver restores `t_nom` and recomputes after the sweep.

**Within-solve parallelism** (`src/analysis/par_eval.zig`): device
evaluation can split instances across `ParEval` worker threads with private
plane slabs, a fixed partition and a fixed reduction order, so results are
bit-identical run to run at a given thread count (they differ from serial by
reassociation only). It is off by default (`ESPICE_THREADS`, default 1).

Knobs: `n_trials`, `seed`, `variation`; temperature start/stop/step and
`t_nom`; the tolerance bundle per solve.

## 3. Pseudo-code, CPU sequential

```
mc(ckt, probes, N, seed, variation):
    vars = nonzero primary params of every device
    solve_lanes(ckt, N, apply = |k|:
        if k == 0: rng = prng(seed)
        for v in vars: v.set(v.nominal * (1 + variation * rng.normal())))
    for each lane k that converged: emit row (k_conv, x_k[probes])

solve_lanes(ckt, N, apply):
    ws = workspace(ckt)                      # pattern frozen once
    for k in 0..N:
        apply(k); ckt.recompute()
        x_k = cold_newton(ckt, ws, itl2)     # error => not converged
    restore nominals; ckt.recompute()

temp_sweep(ckt, T0..T1 step dT, t_nom):
    solve_lanes over the temperatures (apply = set_circuit_temp)
    emit converged points only
```

## 4. Parallel execution

The ensemble axis is the cleanest parallel axis in the simulator: trials are
independent problems with the same pattern and the same code. Today the lanes
run one after another on the host, and each solve can use `ParEval` threads
for device evaluation.

Not implemented (design note): run $L$ trials as $L$ lanes with the same batch
descriptors and per-lane parameter values and state vectors, so the lane axis
multiplies the instance count and keeps occupancy high on small circuits (the
"small circuit, many corners" GPU case). Draws would come from a
counter-based RNG (`hash(seed, trial, param)`), non-converged lanes would
raise a flag, and statistics would be reductions over the converged mask.
Within-trial and across-trial parallelism compose: big circuits use the
former, small circuits the latter.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-trial cold Newton (refactor per trial on frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solver/direct.zig` via `converger.run` |
| Workspace/pattern reuse; memcmp/sig refactor bypass for lanes where values repeat | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `ckt.workspace()`, `converger.Options.matrix_sig` |
| Ladder fallback for hard corners | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | not used: a lane that fails plain Newton is recorded as non-converged; `dc/op.zig solveLadder` is the upgrade |
| Batched GPU solves (not implemented) | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) (batched-solve discussion) | none |
| Within-solve parallel eval | none (eval-side, not solver) | `src/analysis/par_eval.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| SPICE temperature model ($tc_1/tc_2$) | implemented by generated device models; the sweep sets circuit temperature |
| MC convergence ($1/\sqrt N$), Bessel correction | derived (standard statistics) |

**Per-section verification**

- §1 distributions, seed policy, drop-not-zero: verified against `mc.zig`.
  The statistics formulas are standard and not implemented in the analysis.
- §2/§3: transcribed from `mc.zig`, `temp_sweep.zig`, `lanes.zig` and
  `par_eval.zig`. §4: design note.

**Our implementation**

- `src/analysis/sweep/lanes.zig` (`solveLanes`), `sweep/mc.zig`,
  `sweep/temp_sweep.zig`, `analysis/par_eval.zig`.
- Fixtures: `tests/fixtures/mc/`, `tests/fixtures/temp/`,
  `tests/fixtures/tran/bench_ensemble_*`, `tests/fixtures/dc/bench_ensemble_sweep_lanes`.
