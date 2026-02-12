Static inspection only; no builds, tests, assembly generation, benchmarks, or profiling were run. Findings are proposals, ranked by plausible payoff on the workloads described. Timing and total-runtime shares remain unknown. Line ranges refer to the files after this cleanup.

All four files were read in full:

- `src/builder.zig`: removed unused/private lookup machinery, reused `findNameIndex` and positional parsing, and used stdlib enum reflection. Source binding still resolves the first exact name match; node allocation and numerical expressions are unchanged.
- `src/engine.zig`: replaced the duplicate test-column lookup with the existing `findNameIndex`. Production orchestration is unchanged.
- `src/gpu_context.zig`: reviewed and left unchanged; the opportunities below require performance and correctness validation.
- `src/main.zig`: replaced fixed alias scans with `StaticStringMap`, dispatched writers directly on the existing enum, and shared identical plot metadata. Aliases, case sensitivity, writer selection, and output ordering are unchanged.

Public APIs, public fields, frozen GPU layouts, and numerical guards were retained. Weighted union-find path compression was not applied: changing the potential-summation path can change floating-point results. Model objects were not shared across instances: parameter sweeps and instance overrides require their independence.

## Group BBD nodes with stable buckets

- **Where**: `src/builder.zig:93-162`, `Builder.computeBbd`.
- **Now**: Each internal node scans `instance_list` to find its instance, then each collected instance scans all tagged nodes again to populate `perm`. With N tagged nodes and I instances, this repeats O(N*I) integer comparisons and memory reads during compilation.
- **Change**: Build an instance-ID-to-u32-bucket map while visiting nodes in their current order. Keep counts and write cursors in parallel u32 arrays, prefix-sum counts starting at position 1, and scatter nodes in one more ascending-node pass. Preserve the existing first-seen instance/type order and final coupling-node pass. Size scratch storage for this construction phase and release it after permutation generation.
- **Why it is faster**: Expected O(N+I) grouping replaces repeated full-table scans; the count/cursor arrays contain only fields needed by the scatter.
- **Est. payoff**: Potentially orders of magnitude fewer comparisons with thousands of instances; wall-clock gain and compilation's share of total runtime are unknown, needs profiling. Flat decks take the existing early return and gain nothing.
- **Risk**: A different block or within-block node order changes the solver permutation and can change pivoting/numerics. Require identical `perm`, block metadata, ground placement, and coupling order. Keep the current implementation as the comparison oracle until centralized verification passes.
- **CPU / GPU / both**: CPU, during circuit construction.

## Index numeric card entries once

- **Where**: `src/builder.zig:2001-2043`, `numericParameter` and `applyKv`.
- **Now**: `applyKv` visits each assignable generated field and `numericParameter` linearly searches the entire card for each canonical name and alias. Binding F fields against K entries costs O(F*K), repeated for model and instance targets and across devices. Large generated models amplify redundant string comparisons; the compile-time name lowering itself is not the runtime cost.
- **Change**: For large cards, create a parse-lifetime `std.StringHashMapUnmanaged(u32)` from key to its first entry index. Reuse it across both target structs and across uses of the same model card. Keep the current field/alias traversal order and perform numeric validation only when that traversal selects an entry. Retain the short linear scan for small cards if measurement favors it.
- **Why it is faster**: An O(K) index build replaces K-entry scans with expected constant-time lookups, reducing the binding work toward O(K+F+A), where A counts alias probes.
- **Est. payoff**: Unknown, needs profiling; promising for models with hundreds or thousands of fields and substantial cards. This affects construction, not Newton evaluation, so total benefit shrinks on long simulations.
- **Risk**: Preserve first-duplicate behavior, canonical-over-alias precedence, the order of multiple alias writes, `__given` flags, and the existing unresolved/nonfinite error order. Do not eagerly validate unknown keys or unused models. Do not change Model/Instance PODs or their per-device ownership.
- **CPU / GPU / both**: CPU, before either backend runs.

## Parallelize the CPU subset of GPU evaluations

- **Where**: `src/gpu_context.zig:562-581`, `GpuContext.evalOnGpu`; `src/engine.zig:298-312`, `Simulation.fromNetlist`.
- **Now**: `evalOnGpu` evaluates every `cpu_batches` entry serially while device work runs. `Simulation.fromNetlist` can already create a `devices.par.ParEval` for the full circuit, but this mixed CPU/GPU path does not use it. Large ineligible or demoted compact-model batches therefore retain a serial dependency chain even when CPU threading was requested.
- **Change**: Build a separate `ParEval` schedule for the final CPU subset after kernel demotion is known, and use its existing `eval` entry point against host planes. Keep the full-circuit schedule for CPU fallback. Reconcile both schedules' per-batch `set_lanes` allocation and use an explicit work gate for the subset.
- **Why it is faster**: Independent device instances in the CPU subset can use multiple cores while pinned downloads and GPU kernels remain in flight. This helps when host evaluation extends beyond the device chain.
- **Est. payoff**: Unknown, needs profiling of mixed circuits with large CPU batches. The ceiling is the CPU subset's exposed time; no speedup is expected when that work already fits entirely under GPU execution/transfers.
- **Risk**: `ParEval` task indices belong to the batch slice used at initialization; passing the subset to the existing full-circuit schedule is invalid. Respect `thread_safe`, per-lane scratch, and state ownership. Parallel accumulation can change floating-point summation order, so this remains a proposal with the existing serial path as fallback. Frozen GPU tapes and PODs stay unchanged.
- **CPU / GPU / both**: Both; CPU evaluation overlaps actual device kernels.

## Stream transient plots in multi-job decks

- **Where**: `src/main.zig:248-277`, streaming selection and `Runner.stream`; `src/engine.zig:384-448`, `Simulation.run` and `runTransient`.
- **Now**: Streaming is limited to a single binary transient. Adding another analysis sends the whole deck through retained results. The transient driver builds a probe-major `Waveform`, copies it into point-major `Result.data`, and the engine retains results until all jobs finish. Large traces incur allocation, transposition traffic, and potentially paging.
- **Change**: Extend the CLI orchestration to consume each plot in job order, sending eligible transient jobs through the existing `analysis.tran.simulateInto` recorder path and writing completed non-transient results between them. Add append-capable streaming support with the output owner. Preserve `Simulation.run`/`getResults` for callers that request retained results; add the streaming contract separately in a future coordinated change.
- **Why it is faster**: It removes the full-trace transpose/copy and bounds output buffering instead of retaining all samples. The existing single-transient implementation supplies the reusable mechanism.
- **Est. payoff**: Unknown, needs profiling; mainly valuable when points times probes makes result storage large enough to compete with RAM. No integration-kernel speedup is implied. Total gain depends on the output/memory fraction and can be large if paging is avoided.
- **Risk**: Preserve raw plot concatenation, job ordering, DCOP/TRANOP caches, UIC handling, completion checks, and output-error propagation. Partial files and timing of writes on a later-job failure need an explicit contract. Keep current retained output as fallback; do not change sample values or timestep decisions.
- **CPU / GPU / both**: CPU output and memory management; no device-kernel change.

## Transfer charge planes only when resident batches produce charge

- **Where**: `src/gpu_context.zig:422-445`, `GpuContext.init`; `src/gpu_context.zig:519-581`, `evalOnGpu`.
- **Now**: The single `has_charge` flag comes from the entire circuit. If charge-producing devices all remain on the CPU, GPU evaluation still clears, downloads, and adds full zero C/Q planes. This wastes device-memory bandwidth, PCIe bandwidth, and host merge traffic every evaluation.
- **Change**: During the successful-upload loop, derive a separate resident-charge flag from the original `Batch.has_charge` values. Use that flag for device C/Q fills, pinned buffers, downloads, and merges. Keep circuit-wide charge handling for clearing and evaluating host planes. Preserve valid C/Q kernel argument buffers until all no-charge kernel accesses are proven absent.
- **Why it is faster**: Charge-free resident batches need only G/RHS transfers even when CPU batches produce charge. CPU C/Q contributions can remain in the host planes without an added zero plane.
- **Est. payoff**: In that specific mixed case, two of four plane downloads disappear, halving plane-download bytes because C matches G size and Q matches RHS size. Elapsed-time improvement and the exposed transfer share are unknown, needs profiling; existing overlap may hide much of the saving.
- **Risk**: Determine membership after missing-kernel demotion, include dynamic-device metadata, and preserve CPU charge clears. Avoid changing the frozen kernel signature or POD layouts. Omitting `+0` can affect signed-zero representations, so establish the required bitwise behavior before adopting a no-merge path.
- **CPU / GPU / both**: Both.

## Index model names before repeated device binding

- **Where**: `src/builder.zig:1868-1871`, `findModel`; callers in device normalization and model binding.
- **Now**: `findModel` scans the AoS model list on every lookup. Device normalization, level resolution, polarity selection, and binding can repeat this search for the same card. D devices and M model cards can therefore incur O(D*M) string comparisons and strided metadata reads.
- **Change**: Construct a parse-lifetime exact-name-to-u32-model-index map once, inserting only the first occurrence of each name. Pass that lookup through private wiring helpers; retrieve the original `types.Model` by index when its kind or parameters are needed. Keep the public `NetBuilder` interface unchanged or coordinate any necessary interface change separately.
- **Why it is faster**: Repeated name resolution becomes expected constant-time lookup without copying model payloads or sharing mutable simulation models.
- **Est. payoff**: Unknown, needs profiling; likely relevant to decks with many distinct models or repeated normalization lookups. Only construction time benefits; a deck using one or two model cards may be faster with the existing scan.
- **Risk**: Preserve exact case-sensitive matching, first duplicate wins, unresolved-model fallbacks, and the normalization rule that chooses the last matching positional token. The index must die with the parse arena and must not replace per-instance model storage.
- **CPU / GPU / both**: CPU.

## Build sensed-source membership once

- **Where**: `src/builder.zig:1150-1161`, `NetBuilder.isSensedSource`, called from the V-source branch of `addDevice`.
- **Now**: Every V source walks all F/H/W buckets and reconstructs each candidate `Device` to read its first positional name. V voltage sources and R references cost O(V*R) repeated reads and case-insensitive comparisons, including irrelevant Device fields.
- **Change**: Before processing the V bucket, scan the F/H/W positional-name columns once into a case-insensitive name set owned by the build phase. Query that set while binding V sources. Preserve the original bucket/card order for device creation and deferred binding.
- **Why it is faster**: Expected O(V+R) membership work replaces repeated scans; only reference-name data participates in the setup pass.
- **Est. payoff**: Unknown, needs profiling; potentially substantial on generated decks with thousands of sources and controlled-source cards. Negligible for ordinary decks with few sources, and zero effect on steady-state eval.
- **Risk**: The current predicate uses `eqlIgnoreCase`, including for manually constructed netlists; an exact string map would change behavior. Do not remove `v_sensed` or alter source replacement, branch numbering, source selection, or probe order. New set lifetime/plumbing requires a separate implementation pass.
- **CPU / GPU / both**: CPU.

## Replay the repeated GPU command chain

- **Where**: `src/gpu_context.zig:501-575`, `GpuContext.evalOnGpu`.
- **Now**: Every evaluation resubmits the same upload, plane clears, per-batch kernel launches, and plane downloads through individual driver calls. Shapes and device pointers are resident, but submission overhead remains on the host critical path, especially with several short device batches.
- **Change**: After initialization, represent the ordinary eval sequence as a reusable graph, update time/limiting arguments and upload lengths as needed, then submit it before the existing CPU work. Keep dirty-parameter and seeded-limit handling outside replay initially. This requires a backend-neutral graph facility in gompute; inspection found the current `Raw.launchOn` path but no graph/capture facility to reuse.
- **Why it is faster**: One replay submission can amortize repeated driver dispatch over the fixed sequence. It does not remove kernel computation, atomics, PCIe bytes, or the final dependency on completed planes.
- **Est. payoff**: Unknown, needs profiling of submission time versus device execution and transfers. Most promising when many short launches recur over many Newton iterations; little expected benefit for compute-dominated kernels.
- **Risk**: Captured scalar arguments must live beyond the current stack locals. Preserve stream ordering, dirty/seed updates, driver-error fallback, and changed limiting states. CUDA and HIP both need supported implementations; retain the current launch loop when replay is unavailable. No GPU-only numerical logic or frozen ABI change is required.
- **CPU / GPU / both**: Both.

## Queue state-control flags before the host walk

- **Where**: `src/gpu_context.zig:746-774`, `GpuContext.stateCtlOnGpu`.
- **Now**: Control kernels are queued, then CPU `state_ctl` hooks run, and only afterward is the four-byte flags download submitted. The result transfer is serialized after host work even though `pin_flags` is separate storage. `evalOnGpu` and `applyLimitsOnGpu` already queue downloads ahead of CPU work.
- **Change**: Once the kernel loop establishes `launched`, enqueue `d_flags.downloadAtAsync` before walking `cpu_batches`; retain synchronization, flag interpretation, and error handling after the host walk.
- **Why it is faster**: The flags transfer can complete while CPU hooks execute, removing some exposed submission/transfer latency without changing the control kernels.
- **Est. payoff**: Small and workload-dependent; unknown, needs profiling. At most the currently exposed flag-transfer/submission delay is hidden, and the total share of state control is unknown.
- **Risk**: Moving a fallible enqueue changes which CPU hooks have executed when that enqueue fails. Reconcile fallback/retry behavior before implementation; do not blindly reorder it as a semantics-preserving cleanup. Keep flags storage live and unread until synchronization.
- **CPU / GPU / both**: Both.

## Nothing to do

No entire file was classified as having no performance opportunities; all four are covered above. `src/gpu_context.zig` is clean of changes safe enough for this constrained cleanup and was left untouched. The existing resident GPU data, pinned asynchronous transfers, per-flavor operating-point cache, and single-transient streaming path already address their respective costs; no duplicate implementations are proposed.
