# docs/solvers — Solver Theory References

Documentation of the algorithms behind `src/analysis/solvers/` and the nonlinear
layer in `src/analysis/solvers/converger.zig`. Each file follows the
same structure: **1.** mathematical specification, **2.** flow explanation,
**3.** CPU-sequential pseudo-code, **4.** GPU-parallel pseudo-code — and
ends with fetched sources, per-section verification status, and pointers to
our implementation + fixtures.

## Index (priority order)

| File | Topic | Primary source |
|---|---|---|
| [gilbert-peierls-lu.md](gilbert-peierls-lu.md) | Left-looking sparse LU, symbolic DFS reachability, $O(\mathrm{flops}(LU))$ bound, threshold pivoting | KLU thesis §§2.3–2.4, 2.9, 2.13 (fetched) |
| [btf-permutation.md](btf-permutation.md) | Max transversal (Duff) + Tarjan SCC → block triangular form, block back-substitution | KLU thesis §§2.5–2.6, ch. 3 (fetched) |
| [amd-ordering.md](amd-ordering.md) | Approximate minimum degree: quotient graph, approximate external degree, absorption, supervariables | KLU thesis §2.8 + AMD paper content (partially derived) |
| [klu-pipeline.md](klu-pipeline.md) | Full KLU pipeline: diagonal-preference pivoting, numeric refactorization, pivot-growth monitor, condition estimation, iterative refinement | KLU thesis §§2.9–2.12, 3.2, 4.2 (fetched) |
| [circuit-matrix-specifics.md](circuit-matrix-specifics.md) | Why BTF+AMD beats general orderings on MNA, tridiagonal/Thomas fast path, value-memcmp + matrix-signature bypass | KLU thesis ch. 3 (fetched) + our design |
| [newton-raphson-convergence.md](newton-raphson-convergence.md) | ngspice convergence criteria (reltol/vntol/abstol), pnjlim/fetlim/limvds as globalization, JFNK + GMRES(m) + preconditioning | ngspice devsup.c (fetched), Kelley (derived) |
| [gpu-sparse-lu.md](gpu-sparse-lu.md) | GLU 3.0 level sets, double-U relaxed dependency detection, three kernel modes; NICSLU cluster/pipeline modes; our refactor-replay port spec | GLU3.0 arXiv:1908.00204 (fetched), NICSLU README (fetched) |
| [homotopy-continuation.md](homotopy-continuation.md) | gmin / source / pseudo-transient stepping as solver-level homotopy, Gillespie adaptive controllers, exact ngspice ladder | ngspice cktop.c (fetched), Kelley & Keyes (derived) |

## Index — structured solvers and extensions

These pages combine implemented components and proposed extensions. Dense
PAC/PXF conversion matrices, the QPSS GMRES operator, structured
preconditioner primitives, and finite-difference DCMATCH stamps exist.
Matrix-free PAC/PXF, MFT shooting, full multidimensional preconditioning,
analytic parameter stamps, and true-LPTV pnoise remain targets.

| File | Topic | Primary source |
|---|---|---|
| [lptv-block-solves.md](lptv-block-solves.md) | Harmonic conversion-matrix systems: block-Toeplitz structure, stacked-real expansion, transpose/adjoint solves, FFT matrix-free apply | rf-sim.pdf (fetched); conversion-matrix algebra derived; grounded in `pac.zig`'s dense impl |
| [monodromy-krylov.md](monodromy-krylov.md) | Matrix-free shooting: Φ·v via sensitivity recurrence over saved step factors, GMRES on (Φ−I), adjoint replay, GCRO-DR recycling | rf-sim.pdf §4.1.4 (fetched); Telichevesky DAC'95 + Parks GCRO-DR (paywalled, derived) |
| [structured-preconditioners.md](structured-preconditioners.md) | Block-circulant averaged-Jacobian preconditioner, FFT diagonalization, degradation + fallback hierarchy, d-dim multi-tone generalization | rf-sim.pdf HB sections (fetched); Krylov-HB preconditioning practice derived |
| [parameter-derivative-stamps.md](parameter-derivative-stamps.md) | Analytic ∂F/∂p via one extra AD dual lane (`evalp` contract hook), adjoint accumulation, SoA layout, GPU pass | contract.zig/ad.zig/batch.zig (source-verified); Director & Rohrer adjoint (derived) |

## Consumers — which analyses use which solver doc

Cross-reference to [docs/analysis/](../analysis/README.md); each analysis
doc carries the reverse mapping in its "Solvers used" section. *(future)*
= a proposed algorithm or extension, even when the analysis already exists.

| Solver doc | Consuming analyses |
|---|---|
| [gilbert-peierls-lu.md](gilbert-peierls-lu.md), [btf-permutation.md](btf-permutation.md), [amd-ordering.md](amd-ordering.md) | every direct-Newton consumer via `direct.zig`: [operating-point-homotopy](../analysis/operating-point-homotopy.md), [dc-sweep](../analysis/dc-sweep.md), [transient-integration](../analysis/transient-integration.md), [transient-noise](../analysis/transient-noise.md), [sensitivity](../analysis/sensitivity.md), [ensemble-sweeps](../analysis/ensemble-sweeps.md), PSS/pnoise/PAC inner steps; [matex](../analysis/matex-exponential-integrators.md) (R-MATEX retained factors) |
| [klu-pipeline.md](klu-pipeline.md) (refactor-replay, pivoting, refinement) | same set as above, plus the sparse path of [ac-small-signal-noise](../analysis/ac-small-signal-noise.md) (`freq_solve` per-ω refill/refactor + `solveRhsT` adjoint); [pole-zero](../analysis/pole-zero.md) *(sparse/Arnoldi upgrade)*, [dcmatch](../analysis/dcmatch.md) (`solveT` on factors), [qpss](../analysis/qpss.md) (simplified preconditioner factors); [pnoise](../analysis/periodic-noise.md)/[pxf](../analysis/pxf.md) *(future: sparse adjoint factors)* |
| [circuit-matrix-specifics.md](circuit-matrix-specifics.md) (`matrix_sig`/memcmp bypass, MNA pattern) | [dc-sweep](../analysis/dc-sweep.md), [transient-integration](../analysis/transient-integration.md) (E2 factor-once), [ensemble-sweeps](../analysis/ensemble-sweeps.md), [stability](../analysis/stability.md) (probe-branch pattern note), [matex](../analysis/matex-exponential-integrators.md) *(future: eligibility detection)* |
| [newton-raphson-convergence.md](newton-raphson-convergence.md) (gates, limiting, JFNK/GMRES) | every analysis with a Newton loop: [operating-point-homotopy](../analysis/operating-point-homotopy.md), [tolerance-system](../analysis/tolerance-system.md) (the gates themselves), [dc-sweep](../analysis/dc-sweep.md), [transient-integration](../analysis/transient-integration.md), [transient-noise](../analysis/transient-noise.md), [sensitivity](../analysis/sensitivity.md), [ensemble-sweeps](../analysis/ensemble-sweeps.md), [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md), [periodic-noise](../analysis/periodic-noise.md), [pac](../analysis/pac.md), [mpde-envelope](../analysis/mpde-envelope.md); [qpss](../analysis/qpss.md) uses the separate `gmres.zig` core; Krylov-shooting/Krylov-HB remain extensions |
| [homotopy-continuation.md](homotopy-continuation.md) | [operating-point-homotopy](../analysis/operating-point-homotopy.md) (the ladder), [dc-sweep](../analysis/dc-sweep.md) (per-point fallback), [ensemble-sweeps](../analysis/ensemble-sweeps.md) (hard-corner fallback, upgrade knob), gmin regularization in [tolerance-system](../analysis/tolerance-system.md) |
| [gpu-sparse-lu.md](gpu-sparse-lu.md) | GPU §4 of [operating-point-homotopy](../analysis/operating-point-homotopy.md), [transient-integration](../analysis/transient-integration.md), [transient-noise](../analysis/transient-noise.md), [dc-sweep](../analysis/dc-sweep.md), [ensemble-sweeps](../analysis/ensemble-sweeps.md) (batched solves); [matex](../analysis/matex-exponential-integrators.md) *(future: level-scheduled Arnoldi solves)* |

| [lptv-block-solves.md](lptv-block-solves.md) | [pac](../analysis/pac.md) (dense impl exists; block/matrix-free path future), [pxf](../analysis/pxf.md) (dense adjoint exists; block/matrix-free path future), [periodic-noise](../analysis/periodic-noise.md) *(future: true-LPTV upgrade)*, [qpss](../analysis/qpss.md) *(future: QPAC)* |
| [monodromy-krylov.md](monodromy-krylov.md) *(future)* | [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md) *(future: Krylov shooting)*, [qpss](../analysis/qpss.md) *(future: MFT cycles)*, [pxf](../analysis/pxf.md) *(future: time-domain adjoint)*, [periodic-noise](../analysis/periodic-noise.md) *(future: adjoint pnoise)* |
| [structured-preconditioners.md](structured-preconditioners.md) | Krylov-HB in [pss-shooting-harmonic-balance](../analysis/pss-shooting-harmonic-balance.md), [pac](../analysis/pac.md)/[pxf](../analysis/pxf.md) matrix-free path, [qpss](../analysis/qpss.md) (simplified dominant-tone implementation; full multidimensional extension pending), [mpde-envelope](../analysis/mpde-envelope.md) Fourier-envelope steps |
| [parameter-derivative-stamps.md](parameter-derivative-stamps.md) *(future)* | [dcmatch](../analysis/dcmatch.md) (analytic upgrade; finite-difference stamps exist), [sensitivity](../analysis/sensitivity.md) adjoint/AC upgrade |

Not covered by a solver doc (used directly): `src/analysis/solvers/dense_lu.zig`
(tf, pz, sp, stb dense path, disto, pnoise, PAC/PXF, MATEX projected systems, shooting/HB Jacobians) and
`src/analysis/solvers/fft.zig` (fourier-thd, pac, HB/envelope upgrades) —
support kernels, not sparse-solver theory.

## Source status summary

Fetched this research pass: Palamadai Natarajan KLU thesis (UFDC PDF —
note the working URL is `.../palamadai_e.pdf`, not the `palamadainatara_e.pdf`
in RESEARCH.md, which 404s; also mirrored in SuiteSparse `KLU/Doc/`),
GLU3.0 paper (arXiv:1908.00204), GLU_public README (the `GLU3.0` GitHub
repo in RESEARCH.md no longer exists — it is `sheldonucr/GLU_public` now),
NICSLU README, ngspice `cktop.c` and `devsup.c` (raw). Paywalled and
therefore derived-not-source-verified where used: ACM Algorithm 907 paper,
Davis *Direct Methods* (SIAM), Kelley & Keyes, NICSLU TCAD 2013 paper,
AMD TOMS paper.

## Open questions — what's worth researching past KLU for us

Profiling context (RESEARCH.md §3): device eval ≈ 50% of runtime on big
linear circuits, solver ≈ 13%. Solver-side wins are second-order until
eval-side work lands; ranked accordingly.

1. **Non-AD eval paths feeding assembly** — not a solver topic, but the
   biggest lever the solver docs point at: refactor-replay makes the solver
   nearly free, so eval dominates. The solver-relevant piece: assembly
   could write straight into permuted coordinates (`prow` composition at
   stamp time), deleting the scatter pass from refactor.
2. **Parallel CPU refactor (NICSLU/CKTSO-style).** Our refactor is a
   pure replay over a frozen DAG — levelize once (CPU, trivial given
   `up/ui`) and run cluster-mode columns on a thread pool; pipeline mode
   for the deep tail. CKTSO (NICSLU's successor,
   github.com/chenxm1986/cktso, and the HYLU/CKTSO arXiv papers) is the
   modern reference and is un-fetched — next research pass.
3. **GPU factor vs GPU-JFNK crossover.** We have whole-Newton JFNK on
   device; `gpu-sparse-lu.md` §4 specs the level-set refactor alternative.
   Needed: a measurement of GMRES-eval cost vs refactor-replay cost per
   fixture class to decide if the port pays. GLU's data says wins start
   ~80k rows — most of our fixtures sit below that; batched *solves*
   (sweeps/MC) likely pay before batched factorization does.
4. **Ordering for DAG shape.** AMD minimizes fill; level-set parallelism
   wants shallow-wide DAGs (nested dissection per BTF block). Only worth
   testing if item 3 lands. (Thesis §2.16 already sketches ND-in-KLU +
   separator-tree parallelism.)
5. **PTC as the fourth OP rung.** `homotopy-continuation.md` documents the
   theory and the ngspice ladder; wiring pseudo-transient into
   `dc/op.zig` after source stepping (we have transient; the rung is glue
   plus a step controller) closes the ngspice robustness gap. Kelley–Keyes
   SER controller worth a proper source if we tune it.
6. **Condition estimation + row scaling.** Both KLU features we skip
   (documented in `klu-pipeline.md`). Cheap to add (Hager/Higham = a few
   solves on existing factors); add when a fixture shows tolerance failures
   traceable to conditioning rather than model error.
7. **Refactor heuristics.** Currently: memcmp bypass → sig bypass →
   refactor → full factor on collapse. Un-researched: partial refactor
   (only columns reachable from changed entries — the "supernodal update"
   idea restricted to our DAG), and pivot-sequence *reuse scoring* (retry
   full factor preemptively when growth trends worsen across iterations
   rather than on hard collapse).
