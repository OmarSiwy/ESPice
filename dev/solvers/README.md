# dev/solvers: solver references

The algorithms behind `src/solver/` (linear solvers plus the Newton layer in
`converger.zig`). [overview.md](overview.md) is the module map and API
reference. The theory pages follow one structure: **1.** mathematical
specification, **2.** flow explanation, **3.** CPU pseudo-code, **4.** GPU
design notes, then sources, per-section verification status, and pointers to
our implementation and fixtures. Every solve runs on the host; §4 of each
page is design, not code.

## Implemented

| File | Topic | Primary source |
|---|---|---|
| [overview.md](overview.md) | Module map, API, environment variables | the code |
| [gilbert-peierls-lu.md](gilbert-peierls-lu.md) | Left-looking sparse LU, symbolic DFS reachability, $O(\mathrm{flops}(LU))$ bound, threshold pivoting | KLU thesis §§2.3-2.4, 2.9, 2.13 (fetched) |
| [btf-permutation.md](btf-permutation.md) | Max transversal (Duff) + Tarjan SCC → block triangular form, block back-substitution | KLU thesis §§2.5-2.6, ch. 3 (fetched) |
| [amd-ordering.md](amd-ordering.md) | Approximate minimum degree: quotient graph, approximate external degree, absorption, supervariables | KLU thesis §2.8 + AMD paper content (partially derived) |
| [klu-pipeline.md](klu-pipeline.md) | KLU pipeline: diagonal-preference pivoting, numeric refactorization, pivot-growth monitor; condition estimation and iterative refinement as the unimplemented KLU reference | KLU thesis §§2.9-2.12, 3.2, 4.2 (fetched) |
| [circuit-matrix-specifics.md](circuit-matrix-specifics.md) | Why BTF+AMD beats general orderings on MNA, tridiagonal/Thomas fast path, value-memcmp + matrix-signature bypass, BBD | KLU thesis ch. 3 (fetched) + our design |
| [newton-raphson-convergence.md](newton-raphson-convergence.md) | ngspice convergence criteria (reltol/vntol/abstol), pnjlim/fetlim/limvds as globalization, JFNK + GMRES(m), the residual-gate divergence | ngspice devsup.c (fetched), Kelley (derived) |
| [homotopy-continuation.md](homotopy-continuation.md) | gmin / source / pseudo-transient stepping, the ngspice ladder and our five-rung OP ladder | ngspice cktop.c (fetched), Kelley & Keyes (derived) |
| [solver-perf-2026-09.md](solver-perf-2026-09.md) | Measured solver profile per deck, kernel changes with before/after numbers, retired experiments, open follow-ups | callgrind + hyperfine on this repo |
| [refactor-tape-2026-09.md](refactor-tape-2026-09.md) | Negative result: SIMD restructuring of the large-matrix refactor | callgrind + hyperfine on this repo |

## Design targets (partly or not implemented)

Each page states its status at the top. In short: PAC/PXF solve a dense
conversion matrix; PSS shooting uses finite-difference products (dense
below 50 unknowns, unpreconditioned GMRES above); QPSS runs unpreconditioned
GMRES; DCMATCH and sensitivity use finite differences. Matrix-free PAC/PXF,
sensitivity-recurrence shooting, structured preconditioners, analytic
parameter stamps and any GPU factorization remain targets.

| File | Topic | Primary source |
|---|---|---|
| [lptv-block-solves.md](lptv-block-solves.md) | Harmonic conversion-matrix systems: block-Toeplitz structure, stacked-real expansion, transpose/adjoint solves, FFT matrix-free apply | rf-sim.pdf (fetched); conversion-matrix algebra derived; grounded in `pac.zig`'s dense impl |
| [monodromy-krylov.md](monodromy-krylov.md) | Matrix-free shooting: Φ·v via sensitivity recurrence over saved step factors, GMRES on (Φ−I), adjoint replay, GCRO-DR recycling | rf-sim.pdf §4.1.4 (fetched); Telichevesky DAC'95 + Parks GCRO-DR (paywalled, derived) |
| [structured-preconditioners.md](structured-preconditioners.md) | Block-circulant averaged-Jacobian preconditioner, FFT diagonalization, degradation + fallback hierarchy, d-dim multi-tone generalization | rf-sim.pdf HB sections (fetched); Krylov-HB preconditioning practice derived |
| [parameter-derivative-stamps.md](parameter-derivative-stamps.md) | Analytic ∂F/∂p via one extra AD dual lane (`evalp` hook), adjoint accumulation, SoA layout | VerA contract + `src/device/eval.zig`; Director & Rohrer adjoint (derived) |
| [gpu-convergence.md](gpu-convergence.md) | Which nonlinear algorithm fits a batch-evaluating GPU: sync census, lanes over independent problems, exact speculation, why not JFNK; ranked options and first experiments | Knoll & Keyes, Thornquist et al., GLU, parareal/MGRIT literature (links in page) |
| [gpu-convergence-fields.md](gpu-convergence-fields.md) | Batched stiff nonlinear solving in chemistry, power systems, reservoir, ODE ensembles, ML and FEM, mapped onto MNA: nonlinear elimination of internal nodes, localization, lagged Newton matrix, f32 planes, batched LU | SUNDIALS, Zhou et al., DiffEqGPU, MAPS (links in page) |
| [gpu-sparse-lu.md](gpu-sparse-lu.md) | GLU 3.0 level sets, double-U relaxed dependency detection, three kernel modes; NICSLU cluster/pipeline modes; refactor-replay port spec | GLU3.0 arXiv:1908.00204 (fetched), NICSLU README (fetched) |
| [gpu-lu.md](gpu-lu.md) | Design for post-layout decks: sync-free replay of the host pivot tape, sync-free solves, resident assembly, host re-pivot as the peel; options ranked, experiments | GLU, Chen TPDS 2015, KLU guide, cuDSS and rocSOLVER docs, sync-free SpTRSV (links in page) |

## Consumers: which analyses use which solver doc

Cross-reference to [dev/analysis/](../analysis/README.md); each analysis
doc carries the reverse mapping in its "Solvers used" section. *(future)*
marks a proposed algorithm or extension, even when the analysis exists.

| Solver doc | Consuming analyses |
|---|---|
| [gilbert-peierls-lu.md](gilbert-peierls-lu.md), [btf-permutation.md](btf-permutation.md), [amd-ordering.md](amd-ordering.md) | every direct-Newton consumer via `direct.zig`: [operating-point-homotopy](../analysis/operating-point-homotopy.md), [dc-sweep](../analysis/dc-sweep.md), [transient-integration](../analysis/transient-integration.md), [transient-noise](../analysis/transient-noise.md), [sensitivity](../analysis/sensitivity.md), [ensemble-sweeps](../analysis/ensemble-sweeps.md), PSS/pnoise/PAC inner steps; [matex](../analysis/matex-exponential-integrators.md) (R-MATEX retained factors) |
| [klu-pipeline.md](klu-pipeline.md) (refactor replay, pivoting) | same set as above, plus the sparse path of [ac-small-signal-noise](../analysis/ac-small-signal-noise.md) (`freq_solve` per-ω refill/refactor, `solveRhsT` adjoint, `solveBatch` lanes); [dcmatch](../analysis/dcmatch.md) (`solveT` on factors); [pole-zero](../analysis/pole-zero.md) *(future: sparse/Arnoldi)*; [pnoise](../analysis/periodic-noise.md)/[pxf](../analysis/pxf.md) *(future: sparse adjoint factors)* |
| [circuit-matrix-specifics.md](circuit-matrix-specifics.md) (`matrix_sig`/memcmp bypass, MNA pattern) | [dc-sweep](../analysis/dc-sweep.md), [transient-integration](../analysis/transient-integration.md) (factor-once), [ensemble-sweeps](../analysis/ensemble-sweeps.md), [stability](../analysis/stability.md) (probe-branch pattern note), [matex](../analysis/matex-exponential-integrators.md) *(future: eligibility detection)* |
| [newton-raphson-convergence.md](newton-raphson-convergence.md) (gates, limiting, JFNK/GMRES) | every analysis with a Newton loop: [operating-point-homotopy](../analysis/operating-point-homotopy.md), [tolerance-system](../analysis/tolerance-system.md) (the gates themselves), [dc-sweep](../analysis/dc-sweep.md), [transient-integration](../analysis/transient-integration.md), [transient-noise](../analysis/transient-noise.md), [sensitivity](../analysis/sensitivity.md), [ensemble-sweeps](../analysis/ensemble-sweeps.md), [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md), [periodic-noise](../analysis/periodic-noise.md), [pac](../analysis/pac.md), [mpde-envelope](../analysis/mpde-envelope.md); [qpss](../analysis/qpss.md) and large-n PSS shooting use `gmres.zig` directly |
| [homotopy-continuation.md](homotopy-continuation.md) | [operating-point-homotopy](../analysis/operating-point-homotopy.md) (the ladder), [dc-sweep](../analysis/dc-sweep.md) (per-point fallback to the same ladder), [ensemble-sweeps](../analysis/ensemble-sweeps.md), gmin in [tolerance-system](../analysis/tolerance-system.md) |
| [lptv-block-solves.md](lptv-block-solves.md) | [pac](../analysis/pac.md) (dense today), [pxf](../analysis/pxf.md) (dense adjoint today), [periodic-noise](../analysis/periodic-noise.md) *(future: true LPTV)*, [qpss](../analysis/qpss.md) *(future: QPAC)* |
| [monodromy-krylov.md](monodromy-krylov.md) | [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md) (FD GMRES today; recurrence *(future)*), [qpss](../analysis/qpss.md) *(future: MFT)*, [pxf](../analysis/pxf.md) *(future: time-domain adjoint)*, [periodic-noise](../analysis/periodic-noise.md) *(future: adjoint pnoise)* |
| [structured-preconditioners.md](structured-preconditioners.md) *(future)* | Krylov-HB in [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md), matrix-free [pac](../analysis/pac.md)/[pxf](../analysis/pxf.md), [qpss](../analysis/qpss.md), [mpde-envelope](../analysis/mpde-envelope.md) Fourier-envelope steps |
| [parameter-derivative-stamps.md](parameter-derivative-stamps.md) *(future)* | [dcmatch](../analysis/dcmatch.md) (finite-difference stamps today), [sensitivity](../analysis/sensitivity.md) adjoint/AC upgrade |
| [gpu-sparse-lu.md](gpu-sparse-lu.md) *(future)* | batched solves in [dc-sweep](../analysis/dc-sweep.md), [ensemble-sweeps](../analysis/ensemble-sweeps.md), [transient-integration](../analysis/transient-integration.md) |

Not covered by a solver doc (used directly): `src/solver/dense_lu.zig`
(tf, pz, disto, HB, PAC/PXF, pnoise, MATEX projected systems, the dense PSS
shooting Jacobian) and `src/solver/fft.zig` (`.four`, PAC): support
kernels, not sparse-solver theory.

## Source status

Fetched: Palamadai Natarajan KLU thesis (UFDC PDF; the working URL is
`.../palamadai_e.pdf`, the `palamadainatara_e.pdf` form 404s; also mirrored
in SuiteSparse `KLU/Doc/`), GLU3.0 paper (arXiv:1908.00204), GLU_public
README (the old `GLU3.0` GitHub repo is gone; it is `sheldonucr/GLU_public`
now), NICSLU README, ngspice `cktop.c` and `devsup.c` (raw). Paywalled, so
derived rather than source-verified where used: ACM Algorithm 907, Davis
*Direct Methods* (SIAM), Kelley & Keyes, the NICSLU TCAD 2013 paper, the
AMD TOMS paper.

## Open questions

Device evaluation dominates most profiles (about half the run on large
transient decks; see `dev/analysis/evaluation-profile.md`), so solver work
is second order. Ranked:

1. **Assembly in permuted coordinates.** Refactor replay makes the solver
   cheap, so the scatter pass is a visible cost. Writing stamps straight
   into permuted coordinates (`prow` composed at stamp time) would delete
   it from refactor.
2. **Ordering once per pattern.** Each `Circuit` computes BTF + AMD for its
   own `Workspace`; the ordering belongs with the prepared pattern
   (`solver-perf-2026-09.md`, open follow-ups).
3. **Parallel refactor.** Measured upper bound at 8 threads, ignoring
   barriers: 1.3x to 2.1x on the corpus's matrices (retired, see
   `solver-perf-2026-09.md`). CKTSO (NICSLU's successor,
   github.com/chenxm1986/cktso) is the unread reference if it reopens.
4. **GPU factorization.** None today. GLU's wins start around 80k rows,
   above most fixtures; batched solves (sweeps, Monte Carlo) would pay
   before batched factorization does. `gpu-sparse-lu.md` is the theory,
   `gpu-lu.md` the design and the experiments that decide it.
5. **Condition estimation and row scaling.** Both KLU features are skipped
   (`klu-pipeline.md`). Cheap to add (Hager/Higham is a few solves on the
   existing factors); add when a fixture fails on conditioning rather than
   model error.
6. **Refactor heuristics.** Today: memcmp bypass, signature bypass,
   refactor, full factor on collapse. Unexplored: partial refactor (only
   columns reachable from changed entries) and refactoring pre-emptively
   when growth trends worsen across iterations.
7. **The residual gate.** A global acceptance change against ngspice's
   NIconvTest (`newton-raphson-convergence.md` §5).
