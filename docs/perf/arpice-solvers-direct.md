# Direct solver review and performance proposals

All seven assigned files were read in full. This is source analysis: no build,
test, benchmark, profiler, or assembly-generation command was run. Findings are
ranked by potential payoff on the workloads described, not by measured runtime
share. Line numbers refer to the reviewed source after this cleanup.

| File | Review outcome |
| --- | --- |
| `src/solvers/sparse_lu.zig` | Removed unused private vector declarations and replaced redundant OutOfMemory remapping with `try`. Arithmetic and allocation order are unchanged. |
| `src/solvers/dense_lu.zig` | Removed an unused private type alias and the private forward-solve start parameter, which was always `k + 1`; corrected its access-pattern description. |
| `src/solvers/lane_lu.zig` | Reviewed without edits; fabricated-pivot replay needs a separate behavior change, described below. |
| `src/solvers/direct.zig` | Removed an unused private sentinel, shared transpose RHS copying, and replaced the sole allocating test converter with the existing fixed-size `DenseCsc` fixture. |
| `src/solvers/order.zig` | Replaced a workspace copy loop with `@memcpy` and an integer square-root counting loop with `std.math.sqrt(u32)`, retaining the exact floor and dense threshold. |
| `src/solvers/bbd.zig` | Reused `std.mem.findScalar` for set membership and local-index lookup, retaining the missing-index failure. |
| `src/solvers/tridiag.zig` | Reviewed and unchanged; no safe simplification or justified performance change found. |

No public declaration, field, numerical threshold, or floating-point operation
sequence was changed. Guards and fallback paths remain. The remaining test-only
dense solvers deliberately stay independent: the production dense kernel uses
reciprocal multiplication and vector reductions where these references use
division and sequential subtraction. Replacing them would change numerics.
The private CSC helpers shared conceptually across files cannot be centralized
through a new exported helper under this task's public-API restriction.

These are CPU solvers even when device evaluation runs on a GPU.
`src/gpu_context.zig`, `hook`, leaves `solve_batch` and `freq_solve_batch` null;
the emitted device roots are in `src/devices/kernels.zig`. No device-kernel
reachability was found for the owned solver loops, so there are no GPU kernel
findings here. None of the proposals requires changing the frozen GPU scatter
tapes, CSC layout, or plane ABI.

Two prior investigations constrain the proposals. The
[skills audit](../skills-audit-2026-09.md) records a regression from replacing
BBD's hot vector zero-fill with builtin memset and does not justify automatic
BBD threading. The
[sparse replay investigation](../solvers/refactor-tape-2026-09.md) records a
regression from expanding replay into larger local-index tapes. Those are prior
results, not measurements from this review; both existing implementations stay.

## Tile large dense factorizations

- **Where**: `src/solvers/dense_lu.zig:38-55`, `DenseLu.factorize`; `src/solvers/dense_lu.zig:182-216`, `factorizeSolveImpl`; `src/solvers/dense_lu.zig:254-265`, `elimRowSimd`.
- **Now**: Each pivot updates every trailing row through a separate rank-one elimination loop. SIMD covers contiguous columns, but large trailing matrices are streamed repeatedly between pivot steps. This costs cache misses and memory traffic in large dense HB, shooting, and periodic small-signal systems.
- **Change**: Prototype a panel/tile implementation for large matrices, retaining the current kernel for small BBD blocks. Factor a narrow panel with the existing partial-pivot comparison and threshold, apply its row swaps consistently, and update trailing tiles while resident in cache. Keep the fused RHS updates in pivot order. Select the crossover using complete analyses, not just dense synthetic matrices.
- **Why it is faster**: Reusing a trailing tile across panel updates increases work per cache-line load and amortizes row-k reloads.
- **Est. payoff**: Potentially order-unity to several-fold on large, cache-limited dense factorization; needs measurement. The kernel can dominate large dense analyses, but its fraction of total runtime is unknown, needs profiling. Little expected benefit for the small BBD interiors.
- **Risk**: A conventional blocked update changes floating-point grouping, and pivot tie order or row-swap mistakes can change the solution. This is explicitly outside the numerical-preserving cleanup; preserve the existing variant as the reference and require numerical review before adoption. No GPU ABI change.
- **CPU / GPU / both**: CPU.

## Replay fabricated pivots in frequency lanes

- **Where**: `src/solvers/lane_lu.zig:93-148`, `LaneLu.refactor`; scalar behavior at `src/solvers/sparse_lu.zig:419-481`, `SparseLu.refactor`.
- **Now**: Scalar replay checks `void_slots` and installs a unit diagonal at `void_col` steps. Lane replay does neither: its ordinary zero-diagonal test marks a still-disabled unknown as failed. For a tape containing such a pivot, otherwise valid lanes can all be peeled to serial solves by `FreqSolver.solveBatch`, after already paying for vector replay and substitution. The mechanism is redundant recomputation plus lost lane parallelism.
- **Change**: In a separately verified change, mirror both scalar safeguards: accumulate per-lane failures for nonzero values in `base.void_slots`, then replay `base.void_col[k]` with the same fabricated diagonal and zero L entries as the scalar code. Preserve the remaining pivot-growth policy and failure mask. Add differential cases for disabled pivots and activation of their row, column, and diagonal, including permuted tapes.
- **Why it is faster**: Valid disabled-unknown lanes can finish in the existing SIMD solve instead of repeating their work through the scalar fallback. Checking activation is essential to making that reuse valid.
- **Est. payoff**: Potentially restores an order-unity lane speedup on affected batches; the SIMD width is only an upper-bound intuition, not a timing estimate. Frequency-solve share and frequency of fabricated pivots are unknown, needs profiling. No expected gain on tapes without void pivots.
- **Risk**: This changes currently observable lane masks and is a correctness change as well as a performance opportunity. Adding only the unit pivot would miss activated couplings. Validate `LaneLu(1)` and wider lanes against scalar replay; retain scalar fallback for rejected lanes. Not applied here.
- **CPU / GPU / both**: CPU.

## Batch the border right-hand sides of each block

- **Where**: `src/solvers/bbd.zig:320-331`, `Bbd.factorBlock`; `src/solvers/dense_lu.zig:60-78`, `solveFactored`; `src/solvers/dense_lu.zig:280-297`, `fmsSolveSimd`.
- **Now**: After factoring one block, `factorBlock` calls `Dense.solveFactored` separately for every column of W. Each call repeats permutation traversal and reads the same LU entries, including strided column gathers during forward substitution. Blocks with a large local border footprint pay this repeated traversal `m` times.
- **Change**: Prototype a private multiple-RHS kernel for W columns within `factorBlock`. Process a small RHS tile together, broadcasting each LU coefficient across independent RHS lanes. Retain the existing column-major W layout for the Schur dots; pack only a bounded tile if needed. Retain the existing single-RHS path when the footprint is small.
- **Why it is faster**: One coefficient/pivot traversal serves several RHS vectors and exposes independent substitutions without parallelizing a dependent elimination step.
- **Est. payoff**: An order-unity improvement is plausible for the block's W-solve phase when `m` is large enough to amortize packing; needs measurement. W solves account for O(m*s^2) block work, alongside O(s^3) factorization and O(m^2*s) Schur work; total runtime share is unknown, needs profiling.
- **Risk**: The current back-substitution uses a vector reduction tree. A new RHS-axis kernel must preserve that tree per RHS if bitwise equivalence is required. Zero-RHS skips, NaNs, signed zero, aliasing, and pivot order also need differential coverage. No public signature or GPU layout needs to change for a private experiment.
- **CPU / GPU / both**: CPU.

## Tile the serial Schur dot products

- **Where**: `src/solvers/bbd.zig:298-317`, `Bbd.factorWithExecution`; `src/solvers/bbd.zig:464-476`, `dotSimd`.
- **Now**: The nested local-border loops compute one dot product at a time. Each F row is reread for every W column, and the same W columns are reread for every F row. All Schur reductions run serially after scheduled block factors finish, creating a serial stage that limits the existing threading path.
- **Change**: Compute a small tile of independent border dot products together. Reuse each loaded F vector across several W columns and maintain a separate vector accumulator for each output. Keep each accumulator's existing element order and horizontal reduction, then commit results in the same block/row/column order. Leave direct accumulation into `s_dense` intact; do not add a full Schur matrix per worker.
- **Why it is faster**: Repeated F loads are shared and multiple independent accumulators can hide multiply/add latency. The fixed-order serial stage does less repeated load work.
- **Est. payoff**: Potentially a modest to order-unity improvement in Schur formation for larger local footprints; needs measurement. This stage costs O(sum(m_i^2*s_i)); its total runtime share is unknown, needs profiling, and tiny footprints may not benefit.
- **Risk**: Too many accumulators cause register spills. Accumulator grouping, FMA contraction, or committing blocks in another order changes numerics. Preserve the existing dot kernel as the reference and retain the serial accumulation policy.
- **CPU / GPU / both**: CPU.

## Cache exact row occupancy during full factorization

- **Where**: `src/solvers/sparse_lu.zig:184-196`, row-scaling pass in `SparseLu.factor`; `src/solvers/sparse_lu.zig:392-408`, `voidUnknown`.
- **Now**: Each candidate void unknown scans its own column and then essentially the entire CSC to prove its row is empty. Many disabled model unknowns cause repeated O(nnz) scans during a full factorization. The mechanism is redundant scanning and scattered row-index reads; numeric refactorization already has its cheaper `void_slots` check.
- **Change**: If profiles show multiple void candidates per full factor, record exact row occupancy during the existing value scan, in a compact bitset indexed by original row. `voidUnknown` can consult that bitset for row emptiness while retaining its `pinv` and column checks. Recompute occupancy on every full factorization; allocate its storage with solver workspace, subject to a separate field/API review.
- **Why it is faster**: V full row scans become one occupancy-building pass plus constant-time row membership checks. It adds no per-replay work to the common numeric refactor path.
- **Est. payoff**: The row-emptiness subphase can improve by roughly the number of void candidates when all would scan the whole matrix; this is an algorithmic bound, not a measurement. Overall payoff is unknown, needs profiling, and is probably negligible without repeated disabled unknowns and full factorizations.
- **Risk**: Occupancy must use exactly `vals[p] != 0`, including treating NaN as present. `rscale` is not an equivalent emptiness test because its magnitude reduction and finite fallback have different semantics. Reusing stale occupancy could fabricate an invalid pivot. Keep activation checks and singularity handling.
- **CPU / GPU / both**: CPU.

## Reuse Tarjan scratch for per-block AMD

- **Where**: `src/solvers/order.zig:83-173`, `order`, Tarjan workspace and the transition to per-block AMD.
- **Now**: `num`, `low`, `on`, `scc_stack`, `frame_v`, and `frame_p` remain reserved in `Ws` while subpatterns and AMD workspaces are allocated. Their lifetime has ended after SCC emission, but later scratch uses fresh slab regions, increasing the peak touched footprint and cache/page pressure.
- **Change**: Allocate `emit` and `block_ptr` before a Tarjan scratch checkpoint. Allocate the six temporary arrays after it, release that checkpoint when DFS completes, then allocate `blk_of`, `loc`, and AMD scratch from the recovered slab region. Keep emitted vertex order, per-block extraction order, and all workspace bounds checks intact.
- **Why it is faster**: Later work reuses up to `6*n` u32 slots already touched by DFS instead of extending the workspace high-water mark. This reduces the live scratch requirement by up to `24*n` bytes.
- **Est. payoff**: Timing is unknown, needs profiling; likely a small setup-only benefit unless ordering large patterns causes cache or page pressure. Ordering occurs during solver construction and fallback initialization, so its share of long simulations is likely limited but unmeasured.
- **Risk**: Releasing `emit` or `block_ptr` would corrupt the permutation. Smaller workspace requirements also change when callers receive `OutOfWorkspace`, so this is deferred rather than treated as strictly identical observable behavior. Preserve comptime compatibility.
- **CPU / GPU / both**: CPU.

## Narrow validated BBD slab offsets after an API review

- **Where**: `src/solvers/bbd.zig:65-79`, Bbd offset fields; `src/solvers/bbd.zig:163-190`, layout construction and arena bound.
- **Now**: Five per-block offset arrays use `usize`, even though initialization rejects an arena longer than `maxInt(u32)`. Pivot and local-index slab lengths are also bounded by the block arena construction. On a 64-bit CPU these metadata arrays consume twice the storage needed for their validated range.
- **Change**: In a separately authorized layout change, store `blk_a_off`, `blk_w_off`, `blk_f_off`, `blk_piv_off`, and `blk_loc_off` as u32 after validating their ranges. Keep layout arithmetic and allocation sizes in usize until bounds validation; widen offsets at address calculations. Review all consumers of these nameable fields first.
- **Why it is faster**: Per-block metadata traversals read fewer bytes, reducing cache footprint for large block counts.
- **Est. payoff**: Saves `20*nb` bytes on a 64-bit host; this is a layout calculation, not a measured speedup. Timing benefit and total runtime share are unknown, needs profiling; expect at most a small benefit unless metadata pressure is demonstrated.
- **Risk**: These fields are externally nameable, so changing their types violates this cleanup's public-API constraint. Narrowing before validating offsets risks overflow; retain the existing arena bound and explicitly bound the other slabs. This host metadata is distinct from the frozen GPU scatter tapes.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `src/solvers/tridiag.zig`: Reviewed and unchanged; precomputed u32 slot maps, separate numeric arrays, zero-allocation O(n) sweeps, and guarded sequential divisions fit the actual chain dependency.
- `src/solvers/direct.zig`: After the stated cleanup, no further performance change is justified by inspection; retain early-exit value comparison, cached-value copying, optional engine dispatch, and pivot/refinement guards. Bytewise equality would change signed-zero and NaN behavior.
