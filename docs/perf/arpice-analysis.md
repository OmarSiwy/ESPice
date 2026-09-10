# Analysis cleanup and performance proposals

Reviewed all 19 assigned files in full. No build, test, benchmark, profiler, or
assembly-generation command was run. Rankings below are workload-dependent
expectations from source inspection, not measurements. Line numbers refer to the
reviewed working tree; other agents are editing concurrently.

The installed `GpuContext.hook()` in `src/gpu_context.zig` supplies
`eval_planes` and `solve_newton`, but leaves `solve_batch`,
`freq_solve_batch`, and `freq_solve_adjoint_batch` null. Consequently, the current
application runs frequency linear algebra and structural sweep scheduling on the
CPU. Its GPU work is device evaluation and associated state handling. GPU findings
below follow `Circuit.eval`/`evalNewton` into the real shared device kernel.

Only safe cleanup was applied. No public declaration, numeric formula, tolerance,
domain guard, or reduction order was changed by this audit. A concurrently added
`Circuit.evalQ` method was preserved; it is not part of this audit's edits.

| File | Review outcome |
| --- | --- |
| `src/analysis/ac/ac.zig` | Unchanged; frequency workspace proposal below. |
| `src/analysis/ac/noise.zig` | Removed unused private SIMD width; workspace and PSD proposals below. |
| `src/analysis/ac/sp.zig` | Shared identical wave conversion between solve routes; removed unused private SIMD declarations. |
| `src/analysis/ac/stb.zig` | Replaced disjoint row-copy loops with `@memcpy`; removed their unused SIMD declarations. |
| `src/analysis/Circuit.zig` | Reused `PatternView.findSlot`; removed unused private `Hooks` alias. |
| `src/analysis/contract.zig` | Unchanged; clean. |
| `src/analysis/dc/dcmatch.zig` | Removed unread derivative scratch and its private argument; used `@memcpy` for the nominal RHS snapshot; removed unused imports. |
| `src/analysis/dc/dc.zig` | Unchanged; constant-stamp proposal below. |
| `src/analysis/dc/op.zig` | Unchanged; constant-stamp proposal below. |
| `src/analysis/dc/tf.zig` | Removed unused private SIMD width; sparse solve proposal below. |
| `src/analysis/eigen/pz.zig` | Unchanged; multiple-RHS proposal below. |
| `src/analysis/post/disto.zig` | Removed unused private SIMD width; tensor proposal below. |
| `src/analysis/post/four.zig` | Replaced operating-point copy loop with `@memcpy`; removed unused private declarations. |
| `src/analysis/root.zig` | Unchanged; clean. |
| `src/analysis/sweep/lanes.zig` | Unchanged; bounded sweep storage proposal below. |
| `src/analysis/sweep/mc.zig` | Replaced integer counter initialization with `@memset`; bounded sweep storage proposal below. |
| `src/analysis/sweep/sens.zig` | Removed unused imports; residual and dot-product proposals below. |
| `src/analysis/sweep/temp_sweep.zig` | Unchanged; bounded sweep storage proposal below. |
| `src/analysis/types.zig` | Unchanged; clean. |

Reuse was checked against the repository and installed Zig standard library.
`PatternView.findSlot` has the same search and checks as the removed copy.
The removed mismatch scratch was written only by its private helper and never
read; the scratch allocation now holds three n-element vectors instead of four.
This changes storage size, not any finite-difference arithmetic.

Some similar code deliberately remains separate. Sensitivity's dot product folds
vector lanes in sequence, whereas mismatch reduces each vector block before
adding it to a scalar; merging them would change rounding. DC and temperature
sweeps use different endpoint rules, and temperature's public `sweep` uses repeated
addition while its `run` computes `start + k*step`. Unifying these paths is not a
safe cleanup. Public result layouts and stable `ParamRef` pointers remain intact.

## Store only retained distortion coefficients

- **Where**: `src/analysis/post/disto.zig:74-103`, `sweep` derivative construction; `src/analysis/post/disto.zig:141-164`, tensor contraction.
- **Now**: `d2` allocates `n*n*n` doubles, fills them with strided stores, and scans every coefficient at every frequency. Most entries can be zero for locally connected devices, but the contraction still loads them before `if (coeff == 0) continue`. This costs memory bandwidth, cache capacity, and cubic storage: the allocation expression alone requests 8 GB at n=1000, independently of circuit sparsity.
- **Change**: Keep the existing finite-difference perturbations, but read changed Jacobian entries from the frozen CSC plane instead of materializing `g_pert` as dense. Build a private coefficient table with row offsets and parallel `a`, `b`, and coefficient arrays, ordered exactly as the current row/a/b contraction. Retain entries that the current `coeff == 0` test would process. Contract that table at each frequency. Coordinate any later analytic derivative route with the existing proposal in `docs/solvers/parameter-derivative-stamps.md`.
- **Why it is faster**: Storage and contraction visits scale with retained coefficients instead of n cubed. Contiguous coefficient streams replace zero scans and strided tensor construction.
- **Est. payoff**: Potentially orders of magnitude on sparse tensor storage and contraction when retained entries are a small fraction of n cubed; needs measurement. Contraction and derivative construction may dominate large distortion runs, but their total runtime share is unknown, needs profiling.
- **Risk**: Preserve coefficient order, signed zero handling, non-finite coefficients, finite-difference steps, and the existing Volterra convention. Omitting structurally absent entries is not equivalent when an invalid `fd_eps` produces `0*inf`; retain a full-path fallback for such inputs. Analytic derivatives would be a separate numerical change. No frozen GPU layout needs modification for this CPU table.
- **CPU / GPU / both**: CPU; device evaluations can already run on GPU, but this finding concerns the host tensor.

## Keep port and stability systems sparse

- **Where**: `src/analysis/ac/sp.zig:114-155`, `sweep` CPU fallback; `src/analysis/ac/stb.zig:78-145`, `solve` augmentation and solver construction.
- **Now**: SP always calls `FreqSolver.initDense` on two n-squared planes, and STB copies both dense planes into two larger dense planes before the same constructor. Each frequency therefore pays dense factorization. STB's call to `solveBatch` does not provide SIMD frequency lanes because the dense strategy immediately uses `solveBatchSerial` in `src/solvers/freq_solve.zig`.
- **Change**: With the solver owner, provide a shared sparse-pattern construction path using the existing `FreqSolver` stacked-real CSC machinery. SP needs a private G-plane copy with the same ordered port-diagonal modifications; STB needs a private augmented CSC pattern containing its probe branch and couplings. Keep dense construction for small systems. Preserve SP's one factorization per frequency followed by all port RHS solves; adding frequency lanes must retain that factor sharing.
- **Why it is faster**: Sparse factorization avoids work on structural zeros, and STB no longer expands and copies entire n-squared planes. A sparse frequency strategy can use the existing pivot tape and `LaneLu` machinery.
- **Est. payoff**: Potentially multiple-fold or more on large, sparsely connected circuits; needs measurement. Factorization can dominate these sweeps, but the actual total runtime fraction is unknown, needs profiling.
- **Risk**: Different pivot selection and fallback ladders can change numerical answers or error behavior. Keep ground handling, duplicate-port stamp order, source signs, and the exact augmented system. The circuit's frozen CSC and GPU layout must remain unchanged; augmentation belongs to analysis-owned storage. This requires coordinated solver work and was not implemented as cleanup.
- **CPU / GPU / both**: CPU. The installed GPU context does not perform these frequency factorizations.

## Evaluate only residuals during parameter differencing

- **Where**: `src/analysis/sweep/sens.zig:137-183`, `solve` parameter loop; `src/analysis/dc/dcmatch.zig:83-129`, `fdSensitivity`; `src/analysis/Circuit.zig:333-344`, `eval`, and `src/analysis/Circuit.zig:393-407`, `evalNewton`.
- **Now**: Each perturbed parameter triggers an evaluation that produces G, C, RHS, and Q, but the derivative calculation consumes only RHS. The shared device evaluator performs derivative work and scatters extra planes. On the real GPU route, `GpuContext.evalOnGpu` additionally zeros and downloads G and, for charge-bearing circuits, C and Q before the host uses only RHS.
- **Change**: Add a residual-only mode to the shared `devices/engine.zig` evaluation/sink implementation, with matching CPU and device entry points. Use it only for perturbed evaluations in `sens.solve` and `dcmatch.fdSensitivity`; keep full nominal evaluations and factorization. Keep models that need side effects from other outputs on the full evaluation path. A later affected-device derivative path can build on the existing parameter-derivative design document, without silently substituting analytic derivatives in this cleanup.
- **Why it is faster**: It eliminates unused AD work, Jacobian scatter, plane clearing, and device-to-host transfers on every parameter perturbation. The GPU implementation uses the same shared physics rather than duplicating kernel logic.
- **Est. payoff**: Potentially multiple-fold on the perturbation evaluator for models with many local derivatives; needs measurement. The P perturbation evaluations plausibly dominate large parameter sweeps; total share is unknown, needs profiling.
- **Risk**: Generated devices may update state while evaluating charge or derivatives. Preserve limiting behavior, topology checks, the actual stored parameter delta, zero-delta behavior, and nominal factor freshness. A reduced pass must invalidate the four-plane memo. Keep frozen Model/Instance PODs, scatter tapes, and plane layouts intact; any hook/export changes require coordinated review.
- **CPU / GPU / both**: Both; the current calls reach `eval_planes` and the actual device evaluation kernel.

## Upload only parameter batches that changed

- **Where**: `src/analysis/Circuit.zig:643-681`, `setCircuitTemp`, `markGpuDirty`, `recompute`, `applyAttempt`, and `restoreModels`; `src/analysis/dc/dcmatch.zig:91-104`, `fdSensitivity`; `src/analysis/sweep/sens.zig:138-155`, `solve`.
- **Now**: Any parameter mutation marks the entire GPU context dirty. The next real device evaluation calls `GpuContext.flushDirtyParams` and `repack`, which uploads every resident batch's complete model and instance arrays. Perturbing one parameter therefore transfers unrelated device payloads and serializes upload work before evaluation. The existing lazy dirty flag already combines repeated marks before a launch, so adding another global flag would not help.
- **Change**: During parameter collection, record a private mapping from parameter index to owning batch/model/instance range. Track dirty batch indices or byte ranges in host metadata and pass them through the dirty/repack path. Upload only those payload ranges before the next existing kernel launch. Temperature and homotopy operations should explicitly mark every affected range; unknown mutations retain the current full-repack fallback.
- **Why it is faster**: Parameter sweeps stop transferring untouched payloads. It reduces host-to-device traffic and the number of upload operations on the serialized path to each kernel.
- **Est. payoff**: Transfer volume could fall roughly in proportion to total resident payload bytes divided by changed payload bytes; latency benefit needs measurement. Overall impact is unknown, needs profiling, and may be small when physics dominates.
- **Risk**: A shared model parameter can affect many instances or derived fields. Missing any dependent range produces stale device physics. Do not change `ParamRef`'s public layout or frozen GPU POD layouts; use a separate host index table. Preserve full recompute/topology validation and restoration on every error path.
- **CPU / GPU / both**: GPU; this optimizes transfers feeding kernels already reached by the owned analysis code.

## Use the existing sparse solver for large transfer-function systems

- **Where**: `src/analysis/dc/tf.zig:35-69`, `solve`.
- **Now**: TF materializes an n-squared Jacobian and always runs dense LU, even though `Circuit` already owns CSC structure and a reusable workspace. It correctly shares one factorization between forward and transpose solves, but still pays dense allocation and cubic factorization cost.
- **Change**: Above a measured crossover, acquire `ckt.workspace()`, evaluate the same nominal G, call `ws.slv.factor(ckt.g_vals)`, and use the existing `solve` and `solveT` methods for the same two RHS vectors. Retain the current dense path for small systems and preserve both resistance formulas.
- **Why it is faster**: It reuses symbolic structure and avoids dense storage and operations on structural zeros while retaining one numerical factorization for both solves.
- **Est. payoff**: Potentially multiple-fold or more on large sparse TF problems; needs measurement. Factorization is likely the major TF-specific cost, but its fraction of a complete deck run is unknown, needs profiling.
- **Risk**: Sparse pivots, singular-matrix handling, and mutations of the shared workspace differ from the current private dense solve. Verify subsequent analyses and exact error mapping. Do not reuse old OP factors without checking the nominal Jacobian. No GPU ABI change is needed.
- **CPU / GPU / both**: CPU linear algebra; nominal device evaluation already has its own GPU route.

## Reuse constant stamps across source-only continuation steps

- **Where**: `src/analysis/dc/dc.zig:229-235`, `runSerial`; `src/analysis/dc/op.zig:159-196`, `solveLadder` source stepping; `src/analysis/Circuit.zig:437-467`, `computeBaseline`, and `src/analysis/Circuit.zig:665-681`, parameter mutators.
- **Now**: Each DC point calls `recompute`, invalidates the entire baseline, and rebuilds constant-Jacobian stamps. Source stepping likewise invalidates and rebuilds the baseline for each lambda. Even a source-only change can cause all constant batches to be re-evaluated, and `computeBaseline` allocates and zeroes `x_zero` on each rebuild. The ordinary Newton loop already shares its workspace, so another solve-workspace cache is unnecessary.
- **Change**: Track which constant batches' G/C contributions actually depend on the changed source or continuation parameter. Reuse unchanged baseline contributions and rebuild only affected ones, retaining a full rebuild for temperature, topology-sensitive recomputation, or unclassified changes. Reuse an existing lifetime-appropriate zero-state buffer during necessary rebuilds rather than allocating it each time.
- **Why it is faster**: It removes repeated constant-device evaluation and temporary allocation between otherwise cheap warm-started Newton solves.
- **Est. payoff**: Could materially reduce point setup on large linear networks and short warm-start solves; needs measurement. Total runtime share is unknown, needs profiling; this will matter little when nonlinear iterations dominate.
- **Risk**: Source/homotopy hooks can change more than RHS. `computeBaseline` also writes RHS/Q and includes the ground stamp, so skipping it is not merely a cache change. Prove dependencies and preserve all observable plane/state effects before using a fast path. Keep the numerical continuation ladder and every limit unchanged. GPU evaluation currently ignores the baseline, so this is not a claim of GPU speedup.
- **CPU / GPU / both**: CPU.

## Batch the pole solver's right-hand sides

- **Where**: `src/analysis/eigen/pz.zig:61-84`, `solve` construction of minus G-inverse times C.
- **Now**: C is stored row-major, but each RHS extracts a column using `c_mat[row*n+j]`; solution writes to A have the same stride. `dense_lu.solveFactored` then streams the same LU factors again for every column. The resulting cache misses and repeated factor loads precede the separate dense QR computation.
- **Change**: Fill RHS columns directly from `ckt.col_ptr`, `ckt.row_idx`, and `ckt.c_vals` into a bounded block of RHS vectors. Add a multiple-RHS variant beside the existing dense factored solve that applies the same pivot tape and triangular arithmetic to independent columns. Pack columns across SIMD lanes, then store completed A columns in tiles. Keep the present single-column path as the oracle/fallback.
- **Why it is faster**: A block of RHS vectors amortizes factor loads, exposes independent lane work, and avoids the dense C allocation and its strided column extraction.
- **Est. payoff**: A few-fold improvement in A construction is plausible when LU factor traffic dominates; needs measurement. QR may dominate the whole PZ run, so the total runtime fraction affected is unknown, needs profiling.
- **Risk**: Preserve pivot order, each RHS's accumulation order, and signed zeros when zero-filling absent CSC entries. Do not batch Hessenberg or Francis iterations as independent lanes; those transformations are dependent. No frozen GPU layout change is needed.
- **CPU / GPU / both**: CPU; the PZ eigensolver does not run on a device kernel.

## Bound frequency-response workspace

- **Where**: `src/analysis/ac/ac.zig:60-75`, `sweep`; `src/analysis/ac/noise.zig:77-107`, `sweep`; `src/analysis/ac/stb.zig:139-158`, `solve`.
- **Now**: Each analysis retains every frequency's full 2n-element solution until it extracts a few probes, noise densities, or one probe-branch current. This requests `16*n*n_points` bytes for the solution blob alone, despite compact final outputs. The large temporary working set increases allocation pressure and memory traffic. Current GPU frequency hooks are absent, so this storage is normally allocated for CPU `solveBatch`.
- **Change**: Keep one `FreqSolver` and persistent lane scratch, solve bounded frequency blocks, and immediately extract the required outputs. For noise, carry `prev_freq`, `prev_density`, and the integrated sum across block boundaries. Keep the public output layouts. The solver's block API should retain its `LaneLu` scratch instead of allocating it anew on each block call.
- **Why it is faster**: Temporary solutions remain cache-sized, and peak storage stops scaling with the entire sweep. Probe extraction can consume results while they are still hot.
- **Est. payoff**: Memory use falls from O(n*points) to O(n*block_size); time benefit matters mainly once the current blob exceeds cache or memory capacity. Speedup and total runtime share are unknown, needs profiling.
- **Risk**: Block boundaries must preserve existing W-wide pivot-refresh groups, frequency order, per-lane scalar fallback, and the last ragged group. Reinitializing the solver per block can change both cost and numerical choices. Keep noise integration order and result indexing exactly.
- **CPU / GPU / both**: CPU under the installed context; no GPU frequency execution is assumed.

## Stream CPU sweep results into compact outputs

- **Where**: `src/analysis/sweep/lanes.zig:51-65`, `solveLanes` serial route; `src/analysis/sweep/mc.zig:137-181`, `analyze`; `src/analysis/sweep/temp_sweep.zig:173-199`, `run`.
- **Now**: MC and temperature allocate one full n-element solution for every trial/temperature even when the installed context immediately selects serial Newton. Each solve is independent in parameter choice but runs serially through one mutable circuit. Only probe values survive, so most of the O(n*lanes) allocation is retained unnecessarily until the collection pass.
- **Change**: Keep the public `solveLanes` full-output contract. Add an internal bounded serial path for MC and temperature that installs global lane k, uses the existing workspace with a reusable x buffer, and copies selected probes into caller-owned compact storage immediately. Factor its per-lane solve operation out of the existing driver to preserve restoration and error handling. Keep full blobs for callers that actually require them.
- **Why it is faster**: It reduces resident solution storage to O(n + probes*lanes), avoids rereading a large solution blob, and keeps the current solution and probe loads hot.
- **Est. payoff**: Primarily a memory-capacity improvement when unknowns greatly outnumber probes; needs measurement. Newton likely dominates smaller sweeps, and total runtime share is unknown, needs profiling.
- **Risk**: MC's `apply(0)` reseeds the PRNG. A chunk-local zero must never accidentally restart draws; fallback must replay global lane order. Keep convergence filtering, packed sample order, statistics reduction order, and restoration timing. Temperature's public `sweep` has different stepping semantics and must not be silently replaced with `run`'s lane formula. GPU evaluation inside each serial solve remains as it is.
- **CPU / GPU / both**: CPU storage and scheduling; current GPU device evaluations are retained.

## Precompute frequency-invariant noise terms

- **Where**: `src/analysis/ac/noise.zig:32-40`, `sourcePsd`; `src/analysis/ac/noise.zig:86-108`, `sweep` accumulation.
- **Now**: Every frequency walks full `NoiseSource` records, branches on noise kind, and recomputes white-noise products or flicker's `pow(abs(current), af)`. Bias, temperature, coefficients, and node indices are fixed for the sweep. Repeated scalar power operations can dominate the PSD pass, while reading fields for other noise kinds wastes cache bandwidth.
- **Change**: At setup, build private parallel node-index and PSD arrays in original source order. Compute white PSDs and flicker numerators with the exact current expressions once; keep a compact list of flicker source indices to update PSDs at each positive frequency. Accumulate sources in their original order. If profiling justifies SIMD, vectorize independent frequency lanes while keeping each lane's source sum and final trapezoid order unchanged.
- **Why it is faster**: It removes repeated expensive power evaluations and moves kind dispatch out of the frequency/source inner loop. The hot pass loads only endpoints and the PSD it uses.
- **Est. payoff**: Potentially several-fold on a flicker-heavy PSD pass; needs measurement. Total noise runtime may still be dominated by adjoint solves; the fraction is unknown, needs profiling.
- **Risk**: Do not sort the summation by kind, replace division by reciprocal multiplication, remove the positive-frequency guard, or change the public `NoiseSource` layout. Preserve non-finite behavior, ground guards, source order, and exact products. New vector arithmetic needs an oracle and assembly review later.
- **CPU / GPU / both**: CPU; noise accumulation remains on the host.

## Fuse sensitivity differencing with its existing dot order

- **Where**: `src/analysis/sweep/sens.zig:57-75`, `dotSimd`; `src/analysis/sweep/sens.zig:133-183`, `solve` derivative scratch and accumulation.
- **Now**: Each parameter writes an entire `dfdp` vector and immediately rereads it in `dotSimd`. This creates an avoidable memory pass and scratch allocation. Mismatch already computes the derivative and dot in one loop, but its block-by-block reduction order is different and cannot safely replace this helper.
- **Change**: In a separately verified kernel, calculate `(rhs_pert-rhs_nom)*inv_delta` and accumulate its product with lambda into the same W-lane accumulator currently used by `dotSimd`. Preserve the explicit left-to-right fold of lanes and the scalar tail. Remove the materialized `dfdp` only after differential checks establish identical results for the supported build modes.
- **Why it is faster**: The derivative stays in registers, eliminating n stores and n reloads per parameter and one n-element scratch vector.
- **Est. payoff**: At most a modest, potentially few-fold change to the memory-bound derivative/dot pass itself; needs measurement. It is likely small compared with full device re-evaluation, and total runtime share is unknown, needs profiling.
- **Risk**: Fusing can permit different code generation, contraction, or reassociation. Preserve multiplication grouping, current vector width, the explicit lane fold, scalar tails, and zero-delta error behavior. Do not replace it with mismatch's reduction or a generic `@reduce` implementation. No GPU ABI impact.
- **CPU / GPU / both**: CPU.

## Advance one interpolation cursor through Fourier samples

- **Where**: `src/analysis/post/four.zig:64-70`, `analyze` resampling loop; `src/analysis/post/four.zig:239-260`, `interpolate`.
- **Now**: Every uniformly increasing target time restarts a binary search over the same waveform window. The dependent comparisons and nonsequential loads cost O(FFT_points*log(window_points)) search work before the FFT.
- **Change**: In `analyze`, retain the bracketing index between target samples and advance it while the next timestamp is at or below the target. Reuse the exact endpoint clamps, duplicate-time guard, and interpolation expression. Keep the binary-search helper as a fallback for non-finite or nonmonotonic input/target cases rather than changing their behavior.
- **Why it is faster**: Ordered targets permit one forward walk, reducing search work to O(window_points + FFT_points) and making timestamp loads sequential.
- **Est. payoff**: Potentially a few-fold on large-window resampling; needs measurement. The transient simulation and FFT may dominate `four.run`, so overall runtime share is unknown, needs profiling.
- **Risk**: Preserve which interval wins at duplicate timestamps and exact endpoints, the truncated window's initial clamp, and the `dt < 1e-30` guard. Replacing the interpolation with a differently associated expression changes rounding. No GPU layout or kernel change is involved.
- **CPU / GPU / both**: CPU; this is host post-processing after transient simulation.

## Nothing to do

- `src/analysis/contract.zig`: compile-time shape validation has no runtime kernel; keep every contract check.
- `src/analysis/root.zig`: static keyword map, tagged dispatch, and re-exports already fit the conventions; the installed Zig 0.16 `std.testing` has no `refAllDeclsRecursive` replacement for the local test helper.
- `src/analysis/types.zig`: shared context, result ABI, and probe-name allocation are cold paths; no justified performance or layout change was found.
