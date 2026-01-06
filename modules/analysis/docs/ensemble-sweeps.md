# Ensemble Sweeps: Monte Carlo / Corners / Temperature

Lane batching, seed policy, statistics, what parallelizes.

## 1. Mathematical specification

### The common shape

All three analyses evaluate the same map over a parameter ensemble:

$$
y_\ell = h\big(x^\ast(p_\ell)\big), \qquad F(x^\ast(p_\ell);\, p_\ell) = 0,
\qquad \ell = 1 \dots L,
$$

differing only in how $\{p_\ell\}$ is generated:

**Monte Carlo** — random draws per varied parameter:
uniform $p = p_0(1 + \tau(2u - 1))$ or Gaussian
$p = p_0(1 + \tau\, z)$, $z \sim \mathcal N(0,1)$, with $\tau$ the relative
tolerance. Outputs are sample statistics over the $N_c \le L$ converged
trials:

$$
\bar y = \frac{1}{N_c}\sum y_\ell, \qquad
s^2 = \frac{1}{N_c - 1}\sum (y_\ell - \bar y)^2
\quad(\text{Bessel-corrected}),
$$

plus min/max and **yield**
$\Pr[y \in [y_{lo}, y_{hi}]] \approx N_{\text{pass}}/N_c$. Monte-Carlo
error decays as $s/\sqrt{N_c}$ — dimension-independent, which is why MC
beats grid corners past a handful of varied parameters.

**Corners** — deterministic $\{p_\ell\}$ at specification extremes
(process/voltage/temperature combinations); worst-case, not statistical.

**Temperature sweep** — a 1-D deterministic ensemble with the SPICE
temperature model applied per point:

$$
R(T) = R(T_{\text{nom}})\big(1 + tc_1 (T - T_{\text{nom}}) + tc_2 (T - T_{\text{nom}})^2\big)
$$

(and device-internal temperature scaling via the engine's `setCircuitTemp`
path).

### Seed policy

The RNG is deterministic and seed-parameterized
(`std.Random.DefaultPrng.init(seed)`, default seed 42): the same netlist +
seed + trial count reproduces the ensemble bit-exactly — a *requirement*
for regression benchmarking and for debugging individual failed trials
(re-run trial $k$ = re-derive its draws from the seed). Lane-parallel
execution must preserve this: either one stream consumed in trial order, or
a counter-based per-trial substream (`hash(seed, trial)`) so trial $k$'s
draws are independent of scheduling — the latter is the GPU-safe policy.

### Convergence bookkeeping

A non-converged trial is **dropped, not zeroed**: samples pack converged
trials contiguously, statistics divide by $N_c$, and yield is conditional
on convergence. (A high non-convergence rate is itself a result — it shows
up as `n_converged` in the stats.)

## 2. Flow explanation

**Monte Carlo** (`modules/analysis/src/sweep/mc.zig`): collect primary
instance parameters (`collectParams`, skipping unset zeros), wrap each in a
`ParamVar` (raw f32 pointer + nominal + distribution). Per trial: perturb
all parameters, `recompute()`, cold DC solve at ITL2 (any error counts as
non-convergence, never aborts the ensemble), record probes / update
running min-max / yield counters, restore nominals. One `Workspace` serves
every trial (frozen pattern). Statistics finalized after the loop; nominals
+ `recompute()` restored on every exit path.

**Temperature** (`sweep/temp_sweep.zig`): per point apply
`setCircuitTemp` + explicit `TempCoeff` overrides, re-solve DC
(cold, ITL2), record; failed points are counted (`failed_temps`) and
skipped, sweep continues.

**Corners** ride the same primitives — a corner is a deterministic
`ParamVar` assignment; multi-lane machinery below executes them.

**Multi-lane execution** (`problem/par.zig`, `problem/batch.zig`): within
one solve, device evaluation is lane-parallel over private plane slabs
with fixed partition and fixed reduction order — **bit-identical results
run-to-run at a given lane count** (differs from serial by reassociation
only). This is the same determinism contract the seed policy makes at the
ensemble level. Fixtures: `ensemble/{opamp_mc,pvt_corners,sweep_lanes,corner_pathological}`.

Knobs: `n_trials`, `seed`, `variation` ($\tau$), distributions per
parameter; temperature triple + `t_nom`; tolerance bundle per solve.

## 3. Pseudo-code, CPU sequential

```
mc(ckt, param_vars, probes, N, seed):
    rng = prng(seed); ws = workspace(ckt)      # pattern frozen once
    for trial in 0..N:
        for pv in param_vars:
            pv.set(draw(rng, pv.dist, pv.nominal, pv.rel_tol))
        ckt.recompute()
        x = cold_newton(ckt, ws, itl2)          # error => not converged
        if converged:
            pack samples[probe][n_conv] = x[probe]; update min/max/yield
            n_conv += 1
        restore nominals
    stats: mean, bessel std, min, max, yield% over n_conv

temp_sweep(ckt, coeffs, T0..T1 step dT):
    for T in range:
        set_circuit_temp(T); for c in coeffs: c.apply(T)
        x = cold_dc(ckt)                        # fail -> count, skip point
        record(T, x[probes])
    restore coeffs
```

## 4. Pseudo-code, GPU parallel

The ensemble axis is the **cleanest GPU axis in the whole engine** —
trials are independent, identical-pattern, identical-code problems:

- **lane batching**: $L$ trials = $L$ blob instances (same batch
  descriptors, per-lane parameter values and state vectors); one
  cooperative launch runs $L$ Newton solves as independent block clusters
  — the megakernel's batched SoA eval already iterates instance-major, so
  the lane axis multiplies instance count, keeping occupancy high on small
  circuits (the classic "small circuit × many corners" GPU win);
- **per-trial draws** on-device via counter-based RNG
  (`philox/hash(seed, trial, param)`) — reproducible independent of
  scheduling, no stream serialization;
- non-converged lanes raise a flag and idle (or get reassigned);
  statistics are grid reductions over the converged mask;
- temperature/corners: identical, with deterministic per-lane parameter
  fill instead of RNG.

```
host: upload blob + per-lane param table (or seed for on-device draws)
kernel ensemble(lanes = trials):
    lane-local: draw/apply params -> lane's model values
    newton/jfnk per lane (block cluster; gates as in converger)
    write y[lane], converged[lane]
host or kernel epilogue: masked reductions -> mean/std/min/max/yield
```

Within-trial lane parallelism (`par.zig`) and across-trial lane batching
compose: big circuits use the former, small circuits the latter.

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Per-trial cold Newton (refactor per trial on frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `modules/solvers/src/direct.zig` via `converger.run` |
| Workspace/pattern reuse; memcmp/sig refactor bypass for lanes where values repeat | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) | `ckt.workspace()`, `converger.Options.matrix_sig` |
| Ladder fallback for hard corners | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `dc/op.zig solveLadder` (dc-sweep style demotion; MC currently records non-convergence instead — upgrade knob) |
| Batched GPU solves | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) (batched-solve discussion) + megakernel JFNK | `modules/devices/src/kernel.zig` |
| Within-solve lane-parallel eval | none (eval-side, not solver) | `modules/analysis/src/problem/par.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| SPICE temperature model ($tc_1/tc_2$) | verified against ngspice manual conventions + our `TempCoeff` |
| MC convergence ($1/\sqrt N$), Bessel correction | derived (standard statistics) |

**Per-section verification**

- §1 distributions, stats, seed policy, drop-not-zero: verified against
  `mc.zig` source. Counter-based substream policy: design note (current
  impl is one sequential stream — correct for the sequential loop, flagged
  as the thing to change for lane parallelism).
- §2/§3: direct transcription of `mc.zig`/`temp_sweep.zig`/`par.zig`
  header contract. §4: prospective (per-point GPU solve exists; lane
  batching not yet).

**Our implementation**

- `modules/analysis/src/sweep/mc.zig`, `sweep/temp_sweep.zig`,
  `problem/par.zig` (+ `problem/batch.zig` SoA batches).
- Bench fixtures: `benchmark/fixtures/ensemble/{opamp_mc,pvt_corners,sweep_lanes,corner_pathological}`,
  `benchmark/fixtures/sweep/*`.
