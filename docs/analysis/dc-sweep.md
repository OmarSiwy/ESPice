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

so the previous point's solution is an $O(\Delta p)$-accurate initial guess
— warm-started Newton converges in a few iterations per point. Where the
branch folds (bistable circuits: Schmitt triggers, latches), warm-start
Newton fails at the fold; the sweep must re-enter from a globalized solve.
A plain swept-source analysis (no arclength continuation) jumps to the
other stable branch there — the hysteresis loop is traced by sweeping both
directions.

Nested sweeps (e.g. `.dc VDS 0 5 0.1 VGS 0 3 0.5`) iterate the outer
parameter and re-run the inner sweep per outer point; the inner sweep
warm-starts from its own previous point, cold-restarting at each new outer
value's first point.

Convergence per point is the standard Newton criterion set
([tolerance-system.md](tolerance-system.md)) with the ITL2 budget (50) —
SPICE's continuation allowance, between ITL1 (cold DC) and ITL4 (transient
point).

## 2. Flow explanation

`modules/analysis/src/dc/dc.zig run()`:

1. **Locate the swept parameter**: `collectParams()` yields raw `ParamRef`
   f32 pointers; the sweep binds the `dc` parameter of the source at
   `source_index`. The value is saved and restored afterwards (with a
   `recompute()`) so the cached operating point stays valid for later jobs.
2. **Per point**: write the swept value, `recompute()` device baselines,
   then solve. The first point — and any point whose warm-started Newton
   fails — goes through the **full OP ladder** (seeded Newton → gmin
   stepping → source stepping → JFNK; see
   [operating-point-homotopy.md](operating-point-homotopy.md)). Interior
   points warm-start from the previous solution with a plain Newton at
   ITL2.
3. **Failure handling**: `SingularMatrix` on a warm-started point (NaN
   stamps from a bad extrapolated guess) does not abort the sweep — it
   demotes to the ladder like any non-convergence. A point where even the
   ladder fails records NaN for its probes and flags the *next* point to
   cold-start; the sweep always completes with the full grid.
4. One `Workspace` serves every point — the sparsity pattern is frozen, so
   symbolic ordering/factorization happens exactly once for the entire
   sweep.

Knobs: `start/stop/step`, `source_index`, and the tolerance bundle (ITL2
budget per warm point).

## 3. Pseudo-code, CPU sequential

```
dc_sweep(ckt, param, start, stop, step, tol):
    ws = workspace(ckt)               # symbolic factorization once
    cold = true
    for v in start..stop by step:
        param.set(v); ckt.recompute()
        converged = false
        if !cold:
            converged = newton(ckt, ws, x, itl2)   # warm start from prev x
                        # SingularMatrix -> converged = false, no abort
        if !converged:
            cold_start(x)
            converged = op_ladder(ckt, ws, x)      # gmin/source/jfnk rungs
        record(v, converged ? x[probes] : NaN)
        cold = !converged
    param.restore(); ckt.recompute()
```

## 4. Pseudo-code, GPU parallel

Sweep points are *almost* independent — only the warm-start guess couples
them. Two strategies:

- **Lane batching (preferred)**: partition the sweep into $L$ contiguous
  chunks; each lane cold-starts its first point (ladder) and warm-marches
  its chunk. Lanes are independent Newton problems on the same pattern →
  one megakernel launch with per-lane blob instances, or per-lane blocks in
  one cooperative launch. Fold-crossing points self-heal per lane exactly
  as on CPU. Speedup ≈ $L$ minus the extra $L{-}1$ cold ladders.
- **Within a point**: the standard batched SoA device eval + JFNK
  (see [operating-point-homotopy.md](operating-point-homotopy.md) §4);
  this is what the repo runs today when `--gpu` is active — the sweep loop
  stays host-side and each point's solve is one kernel launch.

```
host gpu_dc_sweep:
    chunks = split(points, L)
    launch megakernel with L lanes:
kernel lane l:
    cold ladder at chunks[l][0]           # thread-block-local ladder walk
    for v in chunks[l][1..]:              # sequential within lane
        set param lane-locally; assemble; jfnk solve (warm)
        gather probes -> results[l][k]
```

Nested sweeps multiply the lane supply (outer × chunks) — the outer axis is
fully independent (each outer point cold-starts anyway).

## Solvers used

| Phase | Solver doc | Impl |
|---|---|---|
| Warm-point Newton (factor/refactor on frozen pattern) | [klu-pipeline.md](../solvers/klu-pipeline.md), [gilbert-peierls-lu.md](../solvers/gilbert-peierls-lu.md) | `modules/solvers/src/direct.zig` via `converger.newton` |
| Refactor bypass on linear sweeps (same matrix per point at fixed sources) | [circuit-matrix-specifics.md](../solvers/circuit-matrix-specifics.md) (`matrix_sig` / memcmp bypass) | `converger.Options.matrix_sig` |
| Ladder fallback rungs | [homotopy-continuation.md](../solvers/homotopy-continuation.md) | `modules/analysis/src/dc/op.zig solveLadder` |
| Convergence gates, JFNK rung | [newton-raphson-convergence.md](../solvers/newton-raphson-convergence.md) | `modules/analysis/src/helper/converger.zig` |
| GPU lane batching | [gpu-sparse-lu.md](../solvers/gpu-sparse-lu.md) §4 (batched-solve discussion) | `modules/devices/src/kernel.zig` |

---

**Sources fetched**

| Source | Status |
|---|---|
| ngspice manual (fetched this pass, pdftotext) | verified — DC sweep semantics, ITLn split |
| Continuation/IFT argument | derived (textbook implicit function theorem) |

**Per-section verification**

- §1 continuation math: derived, standard. §2/§3: direct transcription of
  `dc.zig` (warm start, NaN rows, cold-restart flag, save/restore).
  Nested-sweep flow: front-end feature; engine primitive is the single
  sweep documented here.
- §4: extrapolation of repo GPU patterns (lane batching not yet
  implemented; per-point GPU solve is).

**Our implementation**

- `modules/analysis/src/dc/dc.zig` — sweep + warm start + ladder fallback.
- `modules/analysis/src/dc/op.zig` — ladder.
- Bench fixtures: `benchmark/fixtures/dc_sweep/*`,
  `benchmark/fixtures/convergence/schmitt` (fold/hysteresis behavior).
