# DC Sweep

Swept operating points with warm-start continuation; nested sweeps; ladder
fallback.

## 1. Mathematical specification

A DC sweep solves the parametrized family

$$
F(x; p) = 0, \qquad p \in \{p_0, p_0 + \Delta p, \dots, p_N\},
$$

where $p$ is a source value (V/I `dc` parameter; temperature and generic
parameters ride the same mechanism, see
[ensemble-sweeps.md](ensemble-sweeps.md)). This is a **discrete natural
continuation**: by the implicit function theorem, while $J = \partial F/\partial x$
is nonsingular along the branch, the solution curve $x^\ast(p)$ is smooth
with

$$
\frac{dx^\ast}{dp} = -J^{-1}\,\frac{\partial F}{\partial p},
$$

so the previous point's solution is an $O(\Delta p)$-accurate initial guess,
and warm-started Newton converges in a few iterations per point. Where the
branch folds (bistable circuits: Schmitt triggers, latches), warm-start
Newton fails at the fold; the sweep must re-enter from a globalized solve.
A plain swept-source analysis (no arclength continuation) jumps to the
other stable branch there; the hysteresis loop is traced by sweeping both
directions.

Nested sweeps (e.g. `.dc VDS 0 5 0.1 VGS 0 3 0.5`) iterate the outer
parameter and re-run the inner sweep per outer point; the inner sweep
warm-starts from its own previous point, cold-restarting at each new outer
value's first point.

Convergence per point is the standard Newton criterion set
([tolerance-system.md](tolerance-system.md)) with the ITL2 budget (50),
SPICE's continuation allowance, between ITL1 (cold DC) and ITL4 (transient
point).

## 2. Flow explanation

`src/analysis/dc/dc.zig run()`:

1. **Locate the swept parameter**: `Circuit.collectParams()` yields
   `ParamRef`s; the sweep binds the one matching the target's device type,
   index and parameter name. The value is saved and restored afterwards (with
   a `recompute()`) so the cached operating point stays valid for later
   queries. A `temp` target sets the circuit temperature instead.
2. **Axis**: the point count is
   $\lfloor (\text{stop} - \text{start})/\text{step} + 10^{-6}\rfloor + 1$,
   endpoint inclusive as ngspice's `DCTsetup` loops `v <= stop`. The
   $10^{-6}$-step nudge absorbs the ~1e-13 division error that otherwise drops
   the last point (`device_hicum2_gummel`: 130 points against ngspice's 131).
   `.temp` sweeps (`temp_sweep.numPoints`) use the same nudge. The swept value
   is accumulated, `v += step`, at both nesting levels, as
   `dctrcurv.c:469` does, not computed as start + k*step. ngspice's axis
   carries that roundoff (1.4975e-13 where start + k*step gives 0), and the
   oracles pin it.
3. **Per point**: write the swept value, recompute device parameters (the
   full walk at point 0, then only the swept device's type through
   `recomputeType`), recompute the baseline, then solve. The first point, and
   any point whose warm-started Newton fails, goes through the full OP ladder
   (see [operating-point-homotopy.md](operating-point-homotopy.md)). Interior
   points warm-start from the previous solution with a Newton at ITL2.
4. **Failure handling**: `SingularMatrix` on a warm-started point (NaN
   stamps from a bad guess) does not abort the sweep; it falls to the ladder
   like any non-convergence. A point where even the ladder fails records NaN
   for its probes and flags the next point to cold-start; the sweep always
   completes with the full grid.
5. **Nested sweeps**: ngspice's second variable is the outer loop. The whole
   inner sweep replays for each outer value, cold-starting its first point,
   and the result concatenates the blocks.
6. One `Workspace` serves every point: the sparsity pattern is frozen, so
   symbolic ordering and factorization happen once for the whole sweep.

Knobs: `start/stop/step`, the optional second source, and the tolerance
bundle (ITL2 budget per warm point).

The accumulated axis moves the analytic-oracle decks `dc/diode_reverse`
(3e-7 to 0.28 of tolerance) and `dc/diode_reverse_continuation` (8e-7 to
0.14), both still passing, and fixed `dc/device_mesfet_transfer`,
`dc/device_mesfet_subthreshold` and `dc/device_diode_breakdown` (issues.md
F2, commit `92df755`).

## 3. Pseudo-code, CPU sequential

```
dc_sweep(ckt, param, start, stop, step, tol):
    ws = workspace(ckt)               # symbolic factorization once
    n = floor((stop - start)/step + 1e-6) + 1
    cold = true; v = start
    for k in 0..n:
        if k > 0: v += step           # accumulated, as dctrcurv.c
        param.set(v); ckt.recompute()
        converged = false
        if !cold:
            converged = newton(ckt, ws, x, itl2)   # warm start from prev x
                        # SingularMatrix -> converged = false, no abort
        if !converged:
            cold_start(x)
            converged = op_ladder(ckt, ws, x)
        record(v, converged ? x[probes] : NaN)
        cold = !converged
    param.restore(); ckt.recompute()
```

## 4. Parallel execution

Today the sweep loop runs serially on the host; inside each Newton iterate
the device evaluation can run on `ParEval` threads or on the GPU
(`Circuit.gpu_hook.eval_planes`).

Not implemented (design note): sweep points are almost independent, since
only the warm-start guess couples them. Splitting the sweep into $L$
contiguous chunks, each cold-starting its first point and warm-marching the
rest, gives $L$ independent Newton problems on one pattern, for a speedup of
about $L$ minus the extra $L-1$ cold ladders. Fold-crossing points recover
per chunk exactly as on the CPU. Nested sweeps multiply the supply of chunks,
since each outer point cold-starts anyway. The structural-lane machinery for
this exists for Monte Carlo and temperature sweeps
(`src/analysis/sweep/lanes.zig solveLanes`, serial over lanes).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Warm-point Newton (factor/refactor on frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md) | `src/solver/direct.zig` via `converger.newton` |
| Refactor bypass on linear sweeps (same matrix per point at fixed sources) | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig` / memcmp bypass) | `converger.Options.matrix_sig` |
| Ladder fallback rungs | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `src/analysis/dc/op.zig solveLadder` |
| Convergence gates, JFNK rung | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `src/solver/converger.zig` |
| Chunked lane batching (not implemented) | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) §4 (batched-solve discussion) | none |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual (pdftotext) | verified: DC sweep semantics, ITLn split |
| Continuation/IFT argument | derived (textbook implicit function theorem) |

**Per-section verification**

- §1 continuation math: derived, standard. §2/§3: transcribed from
  `dc.zig` (warm start, NaN rows, cold-restart flag, save/restore,
  accumulated axis, nested blocks).
- §4: chunked lanes are a design note, not code.

**Our implementation**

- `src/analysis/dc/dc.zig`: sweep, warm start, ladder fallback.
- `src/analysis/dc/op.zig`: ladder.
- `src/analysis/sweep/temp_sweep.zig`: `.temp` point count.
- Fixtures: `tests/fixtures/dc/` (including `bench_dc_sweep_*`),
  `tests/fixtures/convergence/`.
