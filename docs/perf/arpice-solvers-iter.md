# Iterative solver performance review

Static source review, 2026-09-09. No build, test, benchmark, profiler, or assembly-generation command was run. Payoffs below are hypotheses or work-count bounds, not measurements. Ordering reflects likely opportunity on the named workloads; their shares of total runtime need profiling.

All nine owned files were read in full. Cleanup preserves public declarations and fields, floating-point expressions in live solver paths, tolerances, and validation. No allocation lifetime or solver layout changed.

| File | Cleanup outcome |
| --- | --- |
| `src/solvers/gmres.zig` | Removed a duplicate convergence decision; retained the identical residual gate. |
| `src/solvers/preconditioner.zig` | Shared the two identical CSC-pattern loops; used builtin flag fill and optional capture; removed an unused private constant. |
| `src/solvers/converger.zig` | Used `StaticStringMap` for solver-pin spellings; removed the always-true debug wrapper and private dot/norm helpers referenced only by their own tests. Those two obsolete helper tests were removed with them; shared-core solver tests remain. |
| `src/solvers/newton_core.zig` | Reviewed; no cleanup edit. Reduction order, guards, and Env sequencing retained. |
| `src/solvers/freq_solve.zig` | Removed an unused private vector-type alias. |
| `src/solvers/fft.zig` | Reviewed; no cleanup edit. Twiddle arithmetic and size checks retained. |
| `src/solvers/dev_harness.zig` | Reused one run-coverage loop for `u16` and `u32`; removed an unused private parameter and discarded local. Experimental floating-point kernels retained. |
| `src/solvers/types.zig` | `Complex.mag` reuses the identical expression in `magSq`. |
| `src/solvers/root.zig` | Reviewed; clean aggregation and re-exports, unchanged. |

The only added table is the compile-time solver-pin map: three immutable byte-string keys (lengths 6, 4, and 9) mapped to the existing `SolverPin` enum. It performs the same one-shot environment lookup, has program lifetime, allocates no runtime storage, and adds no parallel work. Existing collection dimensions, integer widths, flat numeric planes, and workspace lifetimes remain unchanged.

GPU reachability matters here: `gpu_context.zig:815-840` routes `solveNewton` through CPU `converger.newton`; its assembly hook launches `engine.DeviceKernel` through `evalOnGpu`. The current hook leaves frequency-batch solving unset (`gpu_context.zig:865-884`). Despite the historical comments in `newton_core.zig`, no current device kernel imports that solver core. Consequently, only the assembly finding below proposes GPU work; the remaining solver, FFT, and measurement loops are CPU work.

## Reuse constant Jacobians in GPU Newton assembly

- **Where**: `src/solvers/converger.zig:178-219`, `newton`, especially `hook.assemble` and `hook.vals`.
- **Now**: Every iteration invokes assembly before the factorization check. On the actual GPU route, `GpuContext.AssembleHook.assemble` calls `evalOnGpu`, which zeros, restamps, and downloads G/RHS and, when present, C/Q. This repeats AD, atomic matrix scatter, and PCIe transfers for constant-Jacobian devices. The CPU circuit path already has a constant-Jacobian baseline; the GPU path explicitly does not use it.
- **Change**: In a coordinated performance change, carry the existing `Batch.has_const_jacobian` classification into GPU assembly and maintain constant G/C baselines there. Let the Newton hook request residual/charge updates for those batches while nonlinear batches continue full evaluation. Implement any specialized evaluation in shared `engine.evalRange`/Sink code, and retain fresh residuals for every Newton iterate. Reuse the CPU circuit's baseline logic rather than adding another classification scheme. This requires changes outside the files owned by this audit.
- **Why it is faster**: It removes repeated constant-device derivative computation and matrix scatter. Retaining constant contributions on the host/device also avoids transferring those matrix contributions each iterate where the assembly layout permits it.
- **Est. payoff**: Unknown, needs profiling of constant-device share, kernel time, and transfer time. Potentially substantial for repeated Newton solves dominated by constant batches; little benefit when nonlinear evaluation dominates. Total runtime share is unknown.
- **Risk**: Constant Jacobian does not mean constant RHS or charge. Preserve limiting, history, source-time dependence, ground stamps, parameter invalidation, and failed-launch fallback. `matrix_sig` currently defaults to zero at in-tree call sites and is not sufficient evidence of constancy. Keep frozen scatter tapes, PODs, and plane layouts intact.
- **CPU / GPU / both**: Both, through the existing GPU assembly path and its host merge.

## Share sideband ordering and symbolic setup

- **Where**: `src/solvers/preconditioner.zig:117-137`, `Preconditioner.init`; `src/solvers/preconditioner.zig:251-273`, `factorAll` and `factorSideband`.
- **Now**: One `direct.SolverT(T).init` runs per sideband on the same stacked-real pattern. `direct.initInner` computes an ordering and creates a separate sparse solver for each applicable sideband. Sharing `sr_col_ptr` and `sr_row_idx` does not share that work, despite the file's symbolic-sharing comments. Repeated ordering, allocation, and symbolic traversal increase initialization time and storage.
- **Change**: Compute the structural ordering once for the common 2n CSC and share immutable symbolic data while retaining independent numeric factors and solve scratch. For the f64 path, evaluate reusing `LaneLu(W)` over sidebands, as `FreqSolverT.solveBatch` already does, with failed lanes peeled to independent full factors. Preserve the current per-sideband implementation as the fallback. A first, lower-risk step is sharing only the column ordering, without forcing common numeric pivots.
- **Why it is faster**: Pattern-only work is amortized across `num_sidebands`, and shared immutable arrays reduce duplicated memory traffic. A later lane implementation can reuse one structural traversal across independent frequencies.
- **Est. payoff**: Ordering work can fall from `num_sidebands` copies to one; this is a work-count bound, not a measured speedup. Overall preconditioner setup and QPSS runtime shares are unknown, need profiling. The current QPSS call constructs this preconditioner before its Newton loop.
- **Risk**: Numeric pivot choices can differ with omega; common CSC does not guarantee common L/U structure. Keep singular/growth fallback, transpose behavior, ownership, and per-sideband factors correct. Public `solvers`/pattern fields prevent treating this as an API-neutral cleanup. No current GPU preconditioner kernel exists.
- **CPU / GPU / both**: CPU.

## Reuse FFT setup across equal-length transforms

- **Where**: `src/solvers/fft.zig:205-308`, `bitReverse`, `butterflyPass`, and `butterflyStageVec`.
- **Now**: Every transform recomputes the permutation indices and stage trigonometric seeds. Within each stage, every group regenerates the same twiddle recurrence. PAC/PXF perform two equal-length transforms for every matrix element, so this setup repeats across many short transforms.
- **Change**: Add a separately reviewed caller-owned FFT plan or batch path for the matrix-element transforms. Cache permutation pairs and per-stage scalar/vector seeds for each `(T, N, direction, W)`. If recurrence work profiles hot, cache each stage's twiddles generated by the existing recurrence, including the existing casts, and reuse them across groups. Keep the current one-shot entry points available.
- **Why it is faster**: It amortizes repeated trigonometric evaluation and bit-reversal computation across the `2*n*n` G/C transforms in PAC/PXF. Cached twiddles can also remove the recurrence dependency chain, at the cost of additional loads.
- **Est. payoff**: Unknown, needs measurement across the actual sample lengths. Most promising for many small equal-length transforms; the transform phase's share of PAC/PXF runtime is unknown. Larger tables may lose once cache pressure dominates.
- **Risk**: Preserve f64 angle calculation, narrowing to T, vector width, stage order, and recurrence rounding. Directly replacing recurrences with fresh trig values changes results. Keep existing power-of-two and scratch-size guards. New plan storage/API and differential/assembly verification belong in later work.
- **CPU / GPU / both**: CPU.

## Hoist the unchanged Newton-vector norm out of Arnoldi

- **Where**: `src/solvers/newton_core.zig:218-236`, `newtonSolve`, the `x_norm` computation inside `gmres`.
- **Now**: Each Arnoldi step computes the ordered sum of `x[i]*x[i]`, then its square root and clamp, even though the outer Newton iterate is unchanged throughout that inner solve. This repeats a scalar reduction and a full vector read up to m times.
- **Change**: After entering a nontrivial GMRES solve, compute `x_norm` once before the j loop. Reuse it when computing each finite-difference epsilon; retain the per-basis-vector `v_norm` and its domain guard. Establish that every supported Env leaves x unchanged during inner assembly/preconditioning before moving the call.
- **Why it is faster**: It removes m-1 passes over x and m-1 serial reduction chains per full Arnoldi cycle. It does not require changing the summation order of the retained norm.
- **Est. payoff**: The x-norm subwork falls from m evaluations to one, with the CPU caller using `m = min(30, n)`. End-to-end gain is unknown, needs profiling; device evaluation and modified Gram-Schmidt may dominate JFNK.
- **Risk**: Env methods are generic and could have side effects; moving `reduceAdd` changes their call cadence. Confirm all integrations, pointer aliasing, and finite-difference trajectories. The historical GPU reduction discussion is not evidence of an active device caller today.
- **CPU / GPU / both**: CPU.

## Retain frequency-lane workspace across batch calls

- **Where**: `src/solvers/freq_solve.zig:237-319`, `FreqSolverT.solveBatch`.
- **Now**: Each sparse f64 call allocates vplane, b_plane, and x_plane, then lazily allocates LaneLu storage. These are freed at return. The three planes are allocated even for an empty omega slice or a batch that later falls back entirely to a non-SparseLu solver. Repeated calls pay allocation and initialization costs for unchanged dimensions.
- **Change**: Give repeated batch callers a reusable workspace sized to the current 2n CSC and lane width; retain the existing entry point as a convenience adapter. Defer plane allocation until a chunk actually has a usable sparse factorization. Preserve the current LaneLu resize check when refactoring changes L/U tape lengths, and refresh values/RHS for each call.
- **Why it is faster**: It amortizes allocator traffic and avoids provisioning SIMD storage for work that only takes the scalar fallback. Long sweeps already reuse LaneLu within one call, so that case has less to gain.
- **Est. payoff**: Unknown, needs profiling. Most relevant to repeated short sweeps or many RHS calls, potentially a few percent there; likely small for a single large factorization-heavy sweep. Total runtime share is unknown.
- **Risk**: A persistent LaneLu must not retain a pointer into a moved/destroyed base solver. Preserve allocation-error cleanup, tape invalidation, ragged-lane handling, failed-lane peeling, and adjoint behavior. Allocation timing and added workspace interfaces are observable changes, so this was not implemented as cleanup.
- **CPU / GPU / both**: CPU.

## Accumulate each GMRES solution block in registers

- **Where**: `src/solvers/gmres.zig:295-317`, `Gmres.updateSolution`.
- **Now**: Each basis coefficient triggers a complete `vecAxpy` over x or w. A k-vector update reads and writes the destination k times, in addition to reading the basis. Large destination vectors cause repeated cache/bandwidth traffic.
- **Change**: Tile the destination by W rows. Load one destination vector (or initialize it to zero for the preconditioned path), walk coefficients in the existing j order, perform the same multiply followed by add, and store once. Apply the right preconditioner only after the entire w vector is assembled, exactly as today.
- **Why it is faster**: Destination traffic falls from k read/write passes to one while basis access remains contiguous within each vector tile. This is a different schedule for the final update, not a change from modified to classical Gram-Schmidt.
- **Est. payoff**: Destination traffic can fall roughly k-fold; full update speedup and its fraction of GMRES runtime are unknown, need measurement. Expect a modest overall gain unless large-vector solution updates are a visible hotspot.
- **Risk**: Prove x/w do not overlap basis or coefficient storage in supported calls; public workspace slices make this an explicit contract issue. Preserve j order, separate multiply/add rounding, signed zero, scalar tails, and the preconditioner call count. Leave the orthogonalization dot/AXPY sequence unchanged.
- **CPU / GPU / both**: CPU.

## Compute the diagnostic residual norm only when requested

- **Where**: `src/solvers/converger.zig:200-233`, `newton`.
- **Now**: `norm_f` scans every RHS element on every iteration. Its consumers are the Newton debug print and the op-debug prints, including the factor-failure diagnostic. Acceptance uses `finalizeStep` instead. With both environment flags disabled this is a redundant full-array read and max-reduction chain.
- **Change**: Gate this existing norm scan on `newtonDbg() or opdbg()` before factorization. Keep the scan at its current point when either diagnostic is enabled, so factor failure and post-step diagnostics still report the same pre-solve norm.
- **Why it is faster**: Normal runs avoid an O(n) read/reduction that contributes no solver decision. The guard is uniform per solve, not a data-dependent per-row branch.
- **Est. payoff**: Likely small for factorization-heavy circuits; potentially a few percent of the cheap host Newton bookkeeping on large linear systems. Both estimates need measurement; total runtime share is unknown.
- **Risk**: Preserve one-shot environment-cache semantics and diagnostic timing, including hooks that could mutate process state. Do not remove the independent residual acceptance gate. This is host work even when assembly is GPU-backed.
- **CPU / GPU / both**: CPU.

## Scan waveform extrema together

- **Where**: `src/solvers/types.zig:199-217`, `wfMax`, `wfMin`, and `wfPp`; `src/solvers/types.zig:247-273`, `riseTime` and `fallTime`.
- **Now**: Peak-to-peak and edge-time measurements call separate minimum and maximum scans over the same values. For long waveforms this doubles extrema-read traffic before crossing searches even begin.
- **Change**: Add a private combined-extrema helper for these compound measurements. Initialize both accumulators from the first sample and retain ascending element order and the current `@min`/`@max` operands. Keep single-extremum APIs on their existing one-result paths.
- **Why it is faster**: Both independent accumulators consume each loaded value, reducing two extrema passes to one without requiring a reassociated sum.
- **Est. payoff**: Up to about half the extrema-scan memory traffic, not a measured 2x speedup. Most relevant above cache-sized waveforms. Measurement postprocessing's share of total simulation runtime is unknown and often smaller than solving.
- **Risk**: Preserve empty/mismatched-length behavior, NaN handling, signed-zero choices, and the existing crossing/domain guards. A vector reduction needs separate equivalence checks and is not implied by this proposal.
- **CPU / GPU / both**: CPU.

## Build harness coordinate maps once

- **Where**: `src/solvers/dev_harness.zig:347-398`, `buildTape`; `src/solvers/dev_harness.zig:493-562`, `buildRTape`; `src/solvers/dev_harness.zig:703-872`, `buildMTape` and `buildRTape2`.
- **Now**: Four tape builders reconstruct each column's active set, sort U rows, generate rank maps, and rebuild the same aloc/uloc relationships. Temporary arrays and repeated sorts cost harness startup time. The different replay encodings are intentional experimental variants, so their numeric bodies are not dead duplication.
- **Change**: Use the first `Tape`'s immutable local ranks and aloc/uloc mappings as inputs to the three encoding builders. For the RTape high-bit marking algorithm, copy the current walk's ranks into scratch before marking; never mutate shared ranks. Keep each replay kernel and its bit-equality comparison independent.
- **Why it is faster**: It removes repeated active-set sorting, rank-map construction, and common mapping allocations while retaining the encoding-specific work being compared.
- **Est. payoff**: Several repeated setup passes can be removed; elapsed improvement is unknown, needs measurement. This affects only developer-harness startup, not production runtime or the timed replay loops.
- **Risk**: Preserve every encoding limit: u16 ranks, MTape's 14-bit offsets, RTape2 stash limits, high-bit marking assumptions, and padded loads. Shared tables require explicit ownership. Do not change the experimental loops while claiming comparable historical benchmark results.
- **CPU / GPU / both**: CPU.

Further cleanup proposals deliberately left unapplied:

- `preconditioner.buildStackedRealPattern` and `freq_solve.initSparse` still duplicate pattern construction across files. Their private visibility prevents reuse without exposing a helper or changing module boundaries; the task forbids adding public declarations. The same restriction applies to the private scale-copy helpers. Keep the frozen CSC ordering unchanged in any later consolidation.
- `fft.nextPow2` duplicates `std.math.ceilPowerOfTwoAssert`. The installed stdlib was inspected: its overflow failure uses `catch unreachable`, whereas the current code reaches checked integer addition. The normal positive, representable result agrees, but failure behavior was not assumed interchangeable under this audit's strict observable-behavior rule.
- `types.findCrossing` and `findCrossingAfter` have overlapping scan bodies. A shared helper must retain the optional time filter exactly; using a sentinel time can change behavior for non-finite samples. Their early exits and tiny-dv guard also prevent blanket branchless conversion.
- Preconditioner's `factored` and `src_nnz`, Newton's signature controls, and shared-core fields were retained despite unused or limited in-tree reads because callers can name those fields. In particular, unused arguments in `accumulateCoupling` were not removed along with their call-site checked casts. Such removal could silently discard failure behavior; completing its intended frequency/transpose physics would be a numerical behavior change, not cleanup.
- The standalone GMRES solver is right-preconditioned; `newton_core` uses a left-preconditioned JFNK sequence with different breakdown tests. They cannot be merged merely because both contain Arnoldi and Givens loops. Existing private dot helpers elsewhere also do not justify changing reduction order or adding a new public dependency here.

## Nothing to do

- `src/solvers/root.zig`: clean import/re-export aggregation with declaration coverage; no runtime loop or allocation to optimize.
