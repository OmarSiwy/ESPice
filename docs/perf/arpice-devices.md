# Device cleanup and performance proposals

All seven owned source files were read in full. No build, test, benchmark,
profiler, or assembly-generation command was run. The operation and storage
counts below come from the source; they are not timing measurements. Findings
are ordered by potential payoff on the stated workloads, pending profiling.

| File | Review outcome |
| --- | --- |
| `src/devices/coupled_ltra.zig` | Removed the redundant private interpolation count; replaced polynomial scratch zeroing with `@memset`. |
| `src/devices/engine.zig` | Reused `contract.nU`, preserving `usize` arithmetic; reused full `ParEval.eval` in the no-baseline fallback. |
| `src/devices/kernels.zig` | Reviewed; unchanged. |
| `src/devices/loader.zig` | Reviewed; unchanged. Duplicate-load work is proposed below. |
| `src/devices/ltra_native.zig` | Removed the unreferenced private `rlcH3dashIntFunc`; all called numerical routines remain unchanged. |
| `src/devices/root.zig` | Reviewed; unchanged. |
| `src/devices/txl_native.zig` | Replaced repeated compile-time side comparisons with the existing field-name convention. |

The cleanup changes no public declarations, layouts, live floating-point
expressions, tolerances, or runtime guards. Another writer added
`Hooks.eval_q`, `evalQRange`, and `evalQOnly` during the review, before these
cleanup edits. Those 45 added lines were preserved and are not part of this
cleanup's changes.

Deferred reuse: the Gauss loop in `coupled_ltra.padeApx` duplicates
`txl_native.gauss3` with epsilon `1e-28`; `eval2` and `getC` also have matching
arithmetic. Sharing them would require exposing a helper or adding a shared
file, beyond the permitted API/file scope. Extract those exact primitives in
a coordinated follow-up; retain both existing root solvers and complex
division variants, whose operation ordering and discriminant scaling differ.
Their current implementations remain the fallback. Likewise, public history
and prep-cache machinery in `engine.zig` remains: absence from today's
validated generated models does not make the publicly callable generic
engine API removable.

## Share LTRA coefficient generation across identical history grids

- **Where**: `src/devices/ltra_native.zig:432-726`, `rebuildWave`, `rebuildRc`; `src/devices/engine.zig:977-1140`, `ProtoStore.finalize`.
- **Now**: Each instance independently generates Bessel/erfc-based coefficients while walking its accepted history. Repeated lines with identical kernel parameters and time grids repeat the same expensive coefficient arithmetic, even though only their voltage/current samples differ. The affine cache already avoids this work within one timepoint; the remaining duplication is across instances.
- **Change**: Introduce a host-owned coefficient cache for a group of lines with equal kernel parameters and exactly equal history timestamps. Generate the three coefficient sequences and first coefficients once per attempted timepoint, then consume them in each instance's existing newest-to-oldest accumulation order. Keep the fused path for singleton groups and histories that diverge after compaction.
- **Why it is faster**: It replaces repeated special-function evaluation with sequential coefficient reads. Voltage/current convolution remains per instance.
- **Est. payoff**: For K matching lines, coefficient-generation work could approach 1/K of its current count; total rebuild speedup is unknown, needs profiling. This matters for many repeated lossy lines with long histories; its share of total simulation time is unknown.
- **Risk**: Compaction is signal-dependent, so sharing by model or history length alone is incorrect. Keys must include the time grid, attempted time, kernel parameters, and chopping settings. Preserve chopping comparisons, the auxiliary-index quirk, and every per-instance summation order. Synchronize cache publication before ParEval consumes it.
- **CPU / GPU / both**: CPU. The native LTRA device has State without limit and does not pass `gpuEligible`.

## Separate native line caches from fixed history storage

- **Where**: `src/devices/ltra_native.zig:107-137`, `Instance`; `src/devices/txl_native.zig:604-620`, `Instance`; `src/devices/coupled_ltra.zig:653-688`, `CoupledLtra.Instance`; `src/devices/engine.zig:977-1058`, `ProtoStore` storage and finalization.
- **Now**: Every Instance embeds full zero-initialized history arrays: 320 KiB for LTRA, 80 KiB for TXL, and 272 KiB for four-conductor CPL, excluding other fields. ArrayList insertion/growth moves these large records. Newton passes need small cached stamps but access them through this large stride, creating potential cache/TLB pressure; they do not read all history bytes on every iteration.
- **Change**: In a coordinated native-storage revision, keep host state, cache keys, and cached stamp scalars in a dense hot table. Put convolution state and history in separate simulation-lifetime tables indexed by u32 instance IDs. Give TXL/CPL history storage capacity based on the live delayed window, with growth up to the existing cap; preserve LTRA's full-history retention and current overflow behavior.
- **Why it is faster**: It reduces setup copying and zero-fill bandwidth and packs the fields traversed each Newton iteration together. Separating storage alone does not eliminate history convolution work.
- **Est. payoff**: Potentially a large memory/setup improvement at thousands of lines; Newton throughput and total runtime share are unknown, needs profiling. Little expected benefit for one short line.
- **Risk**: These Instance fields are public, so this requires an API/storage migration and was not applied. Preserve accepted-step ownership, retry invalidation, compaction choices, integer-ps timestamps, and the public adapter behavior. Do not alter generated Model/Instance PODs or frozen GPU tapes to achieve this.
- **CPU / GPU / both**: CPU. All three native line devices are currently excluded from GPU evaluation.

## Reuse TXL exponentials for duplicated poles

- **Where**: `src/devices/txl_native.zig:299-302`, `fitLine`; `src/devices/txl_native.zig:417-525`, `rebuildLine`.
- **Now**: `fitLine` builds `h3_x` by concatenating `h1_x` and `h2_x`. In the all-real rebuild, the h1, h3, and h2 loops contain 3 + 6 + 3 exponential evaluations, although there are at most six distinct pole arguments. Complex-pair paths also repeat the pair exponential and trigonometric arguments. Actual compiler elimination is unknown.
- **Change**: Inspect generated code first. If these calls survive, compute h1 exponentials in the existing `st.h1e` and a small per-call h2 exponential/pair cache, and reuse them in h3. Compute each complex pair's exponential once before its existing sine/cosine products. Keep the original recurrence and accumulation expressions.
- **Why it is faster**: It removes redundant transcendental work without changing the Padé approximation or summing poles in a different order.
- **Est. payoff**: The all-real source-level exponential count falls from twelve to six; wall-time speedup and total runtime share are unknown, needs profiling. Benefits apply on timepoint rebuilds, not cached Newton iterations.
- **Risk**: `LineFit` and `rebuildLine` are public: manually supplied fits need not satisfy the concatenation invariant. Require an established invariant or retain the old path when pole arrays differ. Check exact numerical behavior and register pressure before adopting the cache.
- **CPU / GPU / both**: CPU.

## Tile the ordered CPU lane reduction

- **Where**: `src/devices/engine.zig:2491-2531`, `ParEval.reduce`, `addSimd`.
- **Now**: The outer loop is over lanes. Each lane walks its entire scatter window, rereading and rewriting the destination planes. When overlapping windows exceed cache capacity, later lanes reload the same destination lines from memory. SIMD addition already exists; repeated destination traffic is the candidate cost.
- **Change**: Reduce cache-sized destination tiles. For each tile, visit intersecting lane windows in the current ascending lane order and call the existing `addSimd` on their intersections. Keep matrix and row planes independent and preserve exclusion of trash slots.
- **Why it is faster**: The destination tile can remain cached while all lanes contribute; source slabs remain sequential streams within each tile.
- **Est. payoff**: Potentially a substantial reduction-kernel improvement for large overlapping windows and several workers; unknown, needs profiling. The fraction of total runtime spent in reduction is unknown and may be small for expensive compact models.
- **Risk**: Preserve the exact sequence of additions for every destination, including zero contributions. A tree reduction would change rounding. Window clipping, charge presence, and empty windows must retain current behavior. Frozen tapes and GPU layouts need no change.
- **CPU / GPU / both**: CPU.

## Balance CPU partitions using device evaluation cost

- **Where**: `src/devices/engine.zig:2239-2273`, `ParEval.init`; `src/devices/engine.zig:2405-2426`, `forkJoin`.
- **Now**: Work is estimated as `count * n_u * n_u`. This counts dense Jacobian geometry, not the generated physics cost, structural sparsity, or native history rebuild cost. Mixed device batches can leave lanes waiting at the completion barrier while one lane finishes a more expensive partition.
- **Change**: Measure per-type evaluation costs and use a host-owned per-type weight consistently in `w_total`, `loads`, and `w` when constructing the existing static tasks. Retain whole-batch placement for non-thread-safe devices and an `n_u²` fallback for unmeasured types. Evaluate whether native first-eval rebuilds need a separate weighting policy before extending it.
- **Why it is faster**: Better initial partitions reduce idle time at the serialized fork/join boundary without adding per-instance scheduler calls.
- **Est. payoff**: Could recover substantial lost parallel efficiency on mixed-model circuits; expected to do little for homogeneous batches. Speedup and total runtime share are unknown, needs profiling.
- **Risk**: Changing partitions changes which lane accumulates each stamp and can change floating-point rounding even with a fixed final lane order. This is a numerical-validation project, not a safe cleanup. Keep the current partitioner as fallback.
- **CPU / GPU / both**: CPU.

## Combine device state flags before the global atomic

- **Where**: `src/devices/engine.zig:2092-2171`, `StateKernel.run`, `CtlKernel.run`.
- **Now**: Every thread with a limiting/fault flag, or a true state-control result, atomically ORs into the same `flags[0]`. Widespread limiting at difficult Newton iterates creates a contended global atomic. Threads with zero flags already skip the atomic and should retain that advantage.
- **Change**: Add or expose a portable block/subgroup integer-OR primitive through gompute, combine each thread's existing flag locally, and let one leader issue the global OR when the combined value is nonzero. Apply it only to these control flags; leave f64 matrix/residual atomics alone. `kernels.zig` remains a registration shim.
- **Why it is faster**: It bounds global flag updates by participating groups instead of flagged instances. Integer OR preserves the exact result under regrouping.
- **Est. payoff**: Potentially an order-of-magnitude reduction in global atomic count during widespread limiting; kernel speedup and total runtime share are unknown, needs profiling. Sparse flags may make group coordination slower.
- **Risk**: Tail threads currently return before the body; they must participate safely in any new collective without touching out-of-range instance data. Honor CUDA/HIP group widths and preserve both flag bits and host fallback behavior. Keep the kernel ABI unchanged and retain the existing atomic path when aggregation does not pay.
- **CPU / GPU / both**: GPU. These are actual entry points registered for eligible generated devices.

## Iterate only present CPL convolution entries

- **Where**: `src/devices/coupled_ltra.zig:906-1039`, `rebuild`; `src/devices/coupled_ltra.zig:1129-1182`, `updateState`.
- **Now**: Every timepoint scans dense `h1t`, `h2t`, and `h3t` tables, checking `aten == 0` to skip absent entries. For N = 4 that is 16 + 64 + 64 candidate entries in rebuild. This is repeated sparse traversal and metadata traffic; branch misprediction has not been established, and the branch correctly avoids expensive exponentials.
- **Change**: During precompute, build ordered lists of live flat entry IDs for each table. Iterate them in the current j/k/l order, indexing the existing coefficient and convolution storage. Keep real/complex handling inside that ordered traversal. In complex branches, also check whether the compiler already shares the two identical exponential calls before introducing a local result.
- **Why it is faster**: Sparse fits avoid visiting absent entries while retaining the branch that selects each entry's numerical formula. It removes work rather than executing masked special functions.
- **Est. payoff**: Likely modest at N <= 4; only useful when many fits are absent or many CPL instances rebuild. Dense-fit benefit, speedup, and total runtime share are unknown, needs profiling.
- **Risk**: A failed Padé fit can leave coefficient storage populated while `aten` marks it absent. Build lists from exactly that predicate and rebuild them after parameter changes. Preserve accumulation order; sorting by real/complex kind would change it. Public Model/Instance layouts make storage placement a coordinated follow-up.
- **CPU / GPU / both**: CPU.

## Add processor hints to ParEval's short spin waits

- **Where**: `src/devices/engine.zig:2405-2452`, `forkJoin`, `workerMain`; `src/devices/loader.zig:31-32`, existing spin-hint usage.
- **Now**: The main thread polls `done` and workers poll `epoch` in tight loops; they yield only after 4096 spins. Neither polling loop calls `std.atomic.spinLoopHint`. Busy waiters can consume execution resources needed by another worker on a sibling hardware thread.
- **Change**: Use the existing stdlib hint in both polling loops while preserving acquire/release operations, quit checks, and the current yield threshold. Measure short jobs and SMT contention before keeping it.
- **Why it is faster**: A processor pause hint can reduce the cost of active waiting and interference with useful work. It does not fix unequal task costs or eliminate the barrier.
- **Est. payoff**: Usually small or workload-dependent; potentially relevant for frequent short evaluations with SMT. Speedup and total runtime share are unknown, needs profiling.
- **Risk**: Hints can increase wakeup latency on some targets. Keep synchronization semantics unchanged and retain the current wait policy if end-to-end timing regresses.
- **CPU / GPU / both**: CPU.

## Check duplicate HDL registration before generating device text

- **Where**: `src/devices/loader.zig:82-109`, `prepareOne`; `src/devices/loader.zig:177-200`, `ensureAllLoaded`.
- **Now**: `compileSource` and `generateDevice` run before the registry-name check. A repeated load of an already registered model therefore allocates and emits device text that is immediately discarded. Concurrent requests can also pass the registration check before either registers, duplicating later build work.
- **Change**: First move `generateDevice` below the existing name-length validation and already-registered early return, retaining `compileSource` to obtain the validated module name. If duplicate concurrent requests are common, separately consider tracking in-progress generation keys outside the registry's short critical section.
- **Why it is faster**: The first edit removes a full code-generation pass and its allocations for duplicate registered names. The existing artifact cache only avoids later compilation work.
- **Est. payoff**: Saves the code-generation portion of duplicate loads; first-load cost is unchanged. This is startup/interactive-load work, not simulation evaluation. Timing and total runtime share are unknown, needs profiling.
- **Risk**: Moving generation changes which diagnostics/errors are observed for duplicate names, so it is not semantics-preserving and was not applied. Define that behavior before changing the order. Keep extension, source-size, name-length, backend, and ABI checks. Do not hold the registry spinlock during codegen/build/dlopen.
- **CPU / GPU / both**: CPU host loading; generating a device artifact is not GPU kernel execution.

## Nothing to do

- `src/devices/kernels.zig`: Clean registration shim; all device logic already resides in the shared engine. No independent runtime optimization proposed.
- `src/devices/root.zig`: Clean catalog/dispatch aggregation with a static letter map and explicit level policy. No simulation hot loop to optimize here.
