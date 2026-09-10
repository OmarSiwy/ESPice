# Test-suite performance review

All nine assigned files were read in full. This is a source review; no build, test,
benchmark, profiler, or assembly-generation command was run. Rankings below are
estimates of opportunity, not measurements. Line ranges refer to the edited files.

Safe cleanup applied:

- `tests/analyses.zig`: 26 default DC setup sequences now reuse its existing
  `solveOp`, retaining the allocation, convergence check, cleanup, and `dc.solve`
  options. Custom tolerances and numerical expectations are unchanged.
- `tests/leak.zig`: the same 19 borrowed result names use `std.StaticStringMap`
  instead of a separate linear membership function. Result ownership is unchanged.
- `tests/test_all.zig`: sensitivity assertions reuse `builder.findNameIndex`;
  first-match behavior and failure on missing columns are unchanged.
- `tests/test_circuit.zig`: six identical prototype dispatch initializers share a
  private `protoFor`; allocation order, device types, branch numbering, and
  dispatch targets are unchanged.

`tests/parallel.zig` was reviewed and left unchanged; its opportunities are proposals
below. No public declarations, struct fields, numerical expressions, tolerances,
seeds, or guards were changed. No runtime speedup is claimed for the cleanup.

GPU reachability: these fixtures create circuits without installing `gpu_hook` or
constructing `GpuContext`. `tests/devices.zig` instantiates `Sink` with `device = true`
to check atomic scatter semantics on the host; it does not launch a device kernel.
There is consequently no GPU performance finding for these files.

## Inject allocation failures one analysis at a time

- **Where**: `tests/leak.zig:258-295`, `runInjected` and the allocation-failure test.
- **Now**: `checkAllAllocationFailures` first counts allocations in the entire
  ten-job sequence, then invokes that sequence again for every failure index.
  A failure inside envelope or transient noise reruns earlier DC, AC, noise,
  sensitivity, TF, STB, distortion, and PSS jobs. The cost is redundant recompute
  and allocation inside the outer failure-index loop, including repeated solves
  that cannot exercise the targeted failure site.
- **Change**: give the injection callback one `analysis.Job` and move the jobs
  loop outside `checkAllAllocationFailures`. Establish each job's starting
  circuit state before its injection campaign. Keep one successful ordered
  ten-job run to cover cross-analysis state handoff. Retain failure injection at
  every allocation site in each job and keep `testing.allocator` as the backing
  allocator.
- **Why it is faster**: removes successful prefixes from failure trials for later
  jobs. For job j with A_j allocation sites, it avoids roughly A_j executions
  of the preceding jobs; it does not shorten the target job's own failure search.
- **Est. payoff**: unknown, needs profiling. A several-fold improvement in this
  test is plausible if later jobs have many allocations and expensive prefixes.
  This test's fraction of suite runtime is unknown, needs measurement.
- **Risk**: analyses mutate circuit state, caches, and sometimes solution storage.
  Splitting the sequence without reproducing its starting state can alter which
  allocations are exercised. Preserve seeds, solver options, result freeing, and
  the ordered successful run. This changes test scheduling and is not applied
  as a semantics-preserving cleanup.
- **CPU / GPU / both**: CPU.

## Reserve node-label capacity for the large parallel fixtures

- **Where**: `tests/parallel.zig:55-66`, `buildLadder`;
  `tests/parallel.zig:133-176`, baseline and dedup fixture construction.
- **Now**: the 3,000-cell ladder, 2,000-cell baseline case, and 5,000-leaf dedup
  case repeatedly call `Builder.addNode` while its `node_labels` ArrayList grows.
  Growth introduces allocations inside these construction loops and may copy
  the accumulated slice descriptors. Each fixture then performs only three
  evaluations, so construction cost is poorly amortized.
- **Change**: call `b.node_labels.ensureTotalCapacity(gpa, ...)` before adding
  nodes. Required total capacities are `cells + 3` for `buildLadder`, 2,003 for
  the baseline case, and 5,003 for the fanout case: ground, rail, voltage-source
  branch, and one node per cell. Preserve the checked arithmetic for the
  parameterized count. Reserve this column directly; `Builder.reserveNodes`
  also allocates a name hash table these unnamed fixtures do not use.
- **Why it is faster**: replaces incremental growth of this column with one
  reservation. Node numbering, device insertion order, and the final SoA
  evaluation tables remain identical.
- **Est. payoff**: unknown, needs profiling; likely a modest fixture-construction
  saving. The proportion spent growing this column versus freezing the sparse
  pattern and running evaluations is unknown, needs measurement.
- **Risk**: moving an allocation changes OOM timing, and an incorrect capacity
  calculation loses the benefit. Keep existing guards and the debug allocator;
  replacing it with an arena would hide some fixture leaks. No frozen GPU
  layout changes are needed.
- **CPU / GPU / both**: CPU.

## Use byte comparison for equal determinism snapshots

- **Where**: `tests/parallel.zig:29-42`, `expectPlanesClose`, called by
  `Snapshot.expectClose` and `serialVsParallel`.
- **Now**: exact comparisons walk every f64, bitcast both values, and branch on
  the first mismatch. The successful path checks large contiguous planes one
  element at a time. The issue to investigate is scalar comparison throughput,
  not an assumed branch-misprediction problem: successful assertions are
  predictable.
- **Change**: after the existing length assertion, let `exact` comparisons
  return immediately when `std.mem.eql(u8, std.mem.sliceAsBytes(want),
  std.mem.sliceAsBytes(got))` succeeds. Retain the current loop for mismatches
  and all approximate comparisons, including its first-index diagnostic and
  error value.
- **Why it is faster**: delegates the common all-equal case to the stdlib's bulk
  byte comparison. It can compare wider chunks without introducing a new
  floating-point reduction or a custom SIMD kernel.
- **Est. payoff**: unknown, needs profiling and an assembly check. A faster exact
  comparator would affect only one comparison pass after the repeated parallel
  evaluation; its share of fixture and suite runtime is unknown and likely small.
- **Risk**: floating-point equality is not a substitute for bit equality: signed
  zeros and NaN payloads must remain distinguishable. Preserve the length check
  and trash-row exclusions. Mismatches may scan some bytes twice; confirm that
  existing diagnostics still identify the same first differing element.
- **CPU / GPU / both**: CPU.

## Keep the small fixed SP output buffers on the stack

- **Where**: `tests/analyses.zig:699-861`, the four SP test blocks, including
  both cases in the one-port resistor test.
- **Now**: each sweep allocates and frees separate frequency and complex-response
  buffers even though their lengths are compile-time constants. The five cases
  use 3, 5, or 20 frequencies and at most 20 complex values. These incur ten
  fixture allocation/free pairs before counting the circuit or solver's work.
- **Change**: replace only these caller-owned output allocations with fixed local
  arrays of the same lengths and pass slices to `analysis.sp.sweep`. Retain
  `testing.allocator` for all circuit and solver allocations. Do not change
  frequency counts, port order, expected values, or sweep options.
- **Why it is faster**: eliminates small allocations and their debug-allocator
  bookkeeping without changing the numerical kernel or output layout.
- **Est. payoff**: unknown, needs profiling; likely negligible for the whole suite
  and useful only if repeated fixture setup is measurable. Numerical solves
  remain unchanged.
- **Risk**: changes fixture allocation-failure behavior, so this is deferred.
  Keep the arrays bounded; the largest pair is 480 bytes of payload. Do not
  apply the same transformation to variable-size waveform or matrix storage.
- **CPU / GPU / both**: CPU.

## Format synthetic node names into their final storage

- **Where**: `tests/test_circuit.zig:119-139`, `build` label construction.
- **Now**: allocates a temporary slice table and one string per unknown, counts
  their bytes, allocates the final byte/offset planes, copies every string, and
  frees all temporaries. This is allocation inside the label loop plus redundant
  copying and pointer traversal. The file currently has no importing caller in
  the repository, so it contributes no runtime to the configured test suite.
- **Change**: if this helper is retained and reconnected, count the exact output
  size first with `std.fmt.count`, allocate the byte and u32 offset planes once,
  and write `"0"` and each `"n{d}"` label directly into its final span with
  `std.fmt.bufPrint`. Preserve labels for branch unknowns as well as nodes.
- **Why it is faster**: removes the temporary table, per-name allocations, and
  the flattening copy while retaining the frozen byte/offset representation.
- **Est. payoff**: zero in the current configured suite. For future large callers,
  label-construction payoff and its share of build time are unknown, need profiling.
- **Risk**: preserve exact label bytes, terminal offsets, checked u32 conversions,
  and ownership transfer on success and failure. The stale `analysis.problem`
  import at line 6 is also absent from HEAD's analysis exports. Resolve that
  integration issue before measuring this helper; its public `Desc` and `build`
  were not removed. Replacing the entire helper with `Builder` requires a separate
  equivalence review because labels and branch-allocation order can differ.
- **CPU / GPU / both**: CPU.

## Nothing to do

- `tests/builder.zig`: reviewed and unchanged; small topology and parameter-restoration fixtures have no material local performance opportunity.
- `tests/devices.zig`: reviewed and unchanged; the finite oracle cases and signed-zero/NaN checks should keep their independent expectations.
- `tests/hfet2_temperature.zig`: reviewed and unchanged; six allocation-free host evaluations do not justify another preparation cache or lane kernel.
- `tests/testdev.zig`: reviewed and unchanged; `R`/`Rc` and `D`/`Dp` deliberately expose distinct model types and engine capabilities, so merging them would compromise coverage or public type identity.
- `tests/test_all.zig`: reviewed and changed only for lookup reuse; no further local performance proposal. Its 20,000-step noise test exercises simulation behavior, and reassociating its sum-of-squares or shortening the run would change the numerical oracle.
