# Device evaluation: code generation and scatter

2026-09-07. Device evaluation is the measured priority. Source snapshots,
raw outputs, profiles, patches and logs: `/tmp/espice-inverter-scdb9598/`.
The matched `full-base` and `profile-src` copies initially differ only in VerA;
concurrent transient edits were preserved in the live tree. Later experiments
in `profile-src` are separately named below and use preserved binaries.

## Applied changes

- Inline the generated shared core so each entry point can discard unused
  outputs. Limiting and state bookkeeping need only subsets of the model.
  The existing explicit `never_inline` chunk calls remain intact.
- Mark whether a power exponent depends on circuit unknowns. A model parameter
  still uses its runtime value; only its structurally zero exponent derivative
  and associated logarithm disappear. The existing value and base derivative,
  including the zero-base fallback, remain unchanged.
- Inline the fused `evalQ` call into the shared evaluator, exposing returned
  residual/derivative arrays to optimization before scattering.
- Update the split-declaration contract test for `inline fn` and add an
  executable conformance fixture covering the zero-base slope and both
  derivatives of a voltage-dependent exponent.

The existing generated-size gate was already stale: the preserved baseline
emitted 17,915 bytes for its smallest shape, against 16,642 expected. This pass
adds another 66 bytes there. All 15 sizes were checked by the full generated
benchmark; MIR row counts are unchanged. The updated expectations account for
both the pre-existing 1,273-byte drift and this pass's 66-byte emission change.

## Evidence

A matched full-model build running 100 inverters for 0.5 ns executes
186,457,098 instructions before, 141,067,065 after the compiler changes,
and 126,623,322 after fused-call inlining: 32.1% fewer overall. Callgrind's
counts measure work, not wall time. A smaller symbolized profiling build
isolated the two compiler changes before testing the complete catalog.

Three-iteration `zig build bench` medians from the matched full-model copies:

| Workload | CPU before | CPU after | CUDA before | CUDA after |
|---|---:|---:|---:|---:|
| BSIM1 | 12.57 ms | 9.34 ms | skipped | skipped |
| BSIM2 | 11.50 ms | 11.09 ms | skipped | skipped |
| BSIM4 | 4.06 ms | 4.02 ms | skipped | skipped |
| Diode temperature | 5.26 ms | 4.90 ms | skipped | skipped |
| MOS amplifier | 24.75 ms | 22.79 ms | skipped | skipped |
| 2,000 inverters | 2.788 s | 1.906 s | 1.306 s | 1.241 s |
| RC100k | 1.819 s | 1.805 s | skipped | skipped |
| Four-bit adder | 108.83 ms | 73.47 ms | 331.89 ms | 342.09 ms |

Compilation activity overlapped these exploratory runs on a shared development
machine; small differences need alternating-run confirmation. No universal
speedup is claimed. Peak CPU RSS did not materially fall: inverters measured
19.8 → 20.1 MB; RC100k 143.5 → 143.3 MB. Executable text grows by 3.33 MB
(28%); this is a runtime/code-size tradeoff. MOS1's emitted CUDA evaluation
frame shrinks from 1,536 to 1,152 bytes. That is the PTX frame declaration,
not a measurement of total GPU memory or physical register occupancy.

Five-round alternating runs using explicit CPU/CUDA selection and output to
`/dev/null` measured inverter CPU medians 2.804 → 1.925 s and CUDA medians
1.913 → 1.426 s. Adder CPU measured 97.90 → 71.05 ms; CUDA 360.33 → 335.76 ms.
RC100k remained essentially unchanged, 2.360 → 2.373 s (three rounds).
CUDA gains in the standard benchmark above were smaller; a single GPU
speedup percentage does not describe both measurement modes.

All eight complete CPU binary payloads are bitwise identical. CUDA inverter
samples differ by at most 2.67e-15; adder samples by 8.14e-5. CUDA remains
non-deterministic across repeat runs, so its result is not claimed bitwise.
The benchmark's ngspice errors are unchanged: inverters, BSIM4 and MOS
amplifier still fail; adder signal coverage remains incomplete.

VerA: 280/280 tests, 1,242/1,242 full conformance fixtures. All 39 built-in
models compile through the CPU/CUDA/HIP build. ESPice's frozen full test suite
passes 368/368. Final live builds/tests also pass: ESPice 368/368 and
VerA 280/280. Source hashes and patches are saved with the logs.

## Ground scatter

The shared evaluator now gathers a local ground mask alongside voltages and
reuses it when stamping G, C and the residual. All derivative lanes remain
seeded; limiting corrections still use the complete gradient. Cached replay
uses the current instance's mask and retains complete cached gradients.
Every charge row still reaches `scatterQ`, including ground, preserving both
`q_vec[n]` conservation and the user's concurrently added per-state `q_tape`.
Cached charge replay now calls that same writer instead of duplicating it.

The layout decisions are unchanged: local residuals/Jacobians feed global
planes; cardinality is instances times local rows/columns; frozen indices stay
u32, values f64, the local mask bool. Gathered metadata is reused before
scattering. The mask lives for one instance evaluation, with no heap storage.
Instances remain parallel; shared GPU destinations still use atomic addition.
Model/Instance PODs, kernel parameters, layout hashes and scatter tapes do not
change. The live implementation grows by six lines, plus the regression test.

In the isolated inverter topology, 2,000 NMOS and 2,000 PMOS instances have
eight local coordinates each. Four NMOS coordinates map to ground; PMOS has
none. Retaining all charge writes removes 200,000 of 576,000 atomic additions
per evaluation. This targets discarded writes contending on common addresses;
it is a traffic count derived from the actual benchmark maps, not a hardware
performance-counter reading. Remaining active shared-rail updates bound the
possible gain.

CUDA event medians from nine alternating groups of 40 kernel launches:

| MOS instances | Before | After |
|---:|---:|---:|
| 256 | 0.155 ms | 0.141 ms |
| 4,000 | 0.288 ms | 0.169 ms |
| 40,000 | 2.286 ms | 1.136 ms |

Active plane differences remain at atomic-reduction rounding scale, at most
1.32e-14 in these probes. The final kernel has the same 168 static global loads
and 1,152-byte PTX local frame as baseline. An early prototype reloaded the
map after each scatter (311 loads); it was retired. Dropping ground charge
writes was also retired to preserve charge conservation and the new tape.

Three-iteration `zig build bench` medians for this pass:

| Workload | CPU before | CPU after | CUDA before | CUDA after |
|---|---:|---:|---:|---:|
| BSIM1 | 9.70 ms | 8.59 ms | skipped | skipped |
| BSIM2 | 9.50 ms | 10.05 ms | skipped | skipped |
| BSIM4 | 4.11 ms | 4.27 ms | skipped | skipped |
| Diode temperature | 5.11 ms | 4.51 ms | skipped | skipped |
| MOS amplifier | 20.52 ms | 19.45 ms | skipped | skipped |
| 2,000 inverters | 1.934 s | 1.615 s | 1.245 s | 1.023 s |
| RC100k | 1.853 s | 1.644 s | skipped | skipped |
| Four-bit adder | 70.86 ms | 60.00 ms | 338.83 ms | 326.79 ms |

Five alternating full-circuit runs confirm inverter CPU medians 1.926 -> 1.598 s
and CUDA 1.252 -> 0.984 s. Adder CPU measures 72.83 -> 54.87 ms, but CUDA
311.81 -> 331.04 ms: no reliable small-circuit GPU gain. RC100k measures
1.767 -> 1.580 s over three rounds. Short model tests were noisy on the hybrid
CPU; no universal improvement is claimed. Peak CPU RSS is essentially flat:
inverters 19.9 -> 20.1 MB, RC100k 143.7 -> 143.5 MB. Native text grows by
150,448 bytes (1.0%).

Branchless triage used Callgrind branch simulation: the short inverter run's
misprediction rate is 2.4% before and 2.0% after. Instructions rise from
126,623,726 to 130,140,683 despite wall-time gains. These are simulated work
counts, not hardware stall measurements. The surviving topology predicates
skip costly updates; forcing unconditional zero atomics would retain the
contention. No floating-point selects or arithmetic were rewritten here.

All eight full CPU payloads, including repeated alternating runs, are bitwise
identical. Full CUDA transient comparisons retain identical shapes and time
points: inverter maximum absolute difference is 1.23e-15 (RMS 2.47e-18);
adder maximum is 7.91e-6 (RMS 2.66e-7), reflecting unordered atomic sums.
The frozen expanded regression suite passes 369/369. The live build
passes all 251 steps and its tests pass 371/371, including the user's new
charge-tape tests. An independent read-only review found no correctness issue.
The new test checks nonlinear current and charge with a grounded terminal moved
by limiting, both uncached and cached, and every per-state tape entry.

Measurements use frozen sources predating the user's concurrent transient
changes; those changes were retained when applying the two evaluator/cache
bodies to the live tree. Results, exact patches, source hashes and commands
are `/tmp/espice-inverter-scdb9598/scatter-*`. Existing ngspice accuracy
mismatches are unchanged; repairing them is outside this requested pass.

## Additional VerA experiments: retained current implementation

Three bounded experiments added no production change. Rewrapping a
structurally constant division denominator produced identical complete CPU
assembly: core inlining already exposes those zero derivatives. Forcing inline
value-only power/log calls gave no CUDA gain and grew the local frame from
1,152 to 1,536 bytes. Also inlining `zPow` slowed the 40,000-instance probe by
3.85%. Existing generation is the fallback. Before/after generated-size gates
passed; rejected candidates did not warrant full conformance runs. Reproduction
artifacts and findings are `/tmp/vera-divc/FINDINGS.md`.

## Zero atomic additions

The GPU atomic writer now skips a zero add only when strict addition to the
observed destination preserves its bits. Signed-zero changes and NaN quieting
fall through to the original atomic operation. The skipped update can linearize
at its relaxed atomic load; this writer accumulates values and does not serve
as a release-sequence synchronization primitive. Nonzero writes are unchanged.
CPU addition stays unchanged. Every charge-tape write still occurs.

No table, stored field, allocation or ABI changes. The existing compile-time
backend branch contains this memory policy; device equations remain shared.
The implementation adds six lines. A 200-case regression compares CPU and
atomic writers with their original operations, covering signed zeros,
subnormals, finite values, infinities and quiet/signaling NaNs. CUDA probes
also check planes prefilled with negative zero and both NaN kinds.
Independent review found no correctness issue.

A first shared CPU/GPU guard was rejected: pinned inverter CPU runs regressed
11.1%, and a cache-sized scatter microbenchmark regressed 41.6%. The final
policy restricts the guard to the existing atomic writer. It emits the same
GPU specialization as the measured candidate. Nine alternating CUDA event
pairs, forty launches per sample:

| MOS instances | Ground mask only | With zero guard | Paired time change |
|---:|---:|---:|---:|
| 256 | 0.141 ms | 0.153 ms | +8.2% |
| 4,000 | 0.214 ms | 0.150 ms | -30.0% |
| 40,000 | 1.136 ms | 0.836 ms | -26.5% |

The small grid regresses. Driver-reported resources remain 252 registers and
1,200 local bytes per thread, with a 256-thread block limit. PTX source grows
11,832 to 13,325 lines; all 144 static atomic sites remain, dynamically guarded.
Reduced atomic contention is consistent with the large-grid gain, but no
hardware-counter attribution is available. The fallback is the original
atomic add; a future alternative must beat this on complete layout workloads
without changing floating-point behavior. Artifacts:
`/tmp/espice-zero-stamps/findings.md` and adjacent logs/scripts.

Final `zig build bench` (three iterations) measures inverter CPU 1.615 ->
1.649 s and CUDA 1.023 -> 0.866 s; adder CPU 60.00 -> 63.41 ms and CUDA
326.79 -> 311.76 ms. These separate-run CPU timings establish no gain.
Two independent sets of three alternating CUDA pairs measure inverter time
ratios 0.9204 and 0.8536, about 8–15% less end-to-end time. Adder ratios are
1.1198 and 0.9790: no reliable improvement on the small workload.
All eight CPU payloads match bit-for-bit; paired inverter CPU is neutral.
CUDA inverter differences are at most 8.83e-15. Adder differences reach
1.21e-4, within its own repeated-run variation; this is not a bitwise GPU
conformance claim. Existing ngspice mismatches remain unchanged.

Native `.text` size remains 15,252,617 bytes. Embedded/read-only data grows
1,327,720 bytes and the executable 1,327,728 bytes (4.43%). Native code bytes
are not identical: section addresses move, and no normalized instruction
comparison was performed. The final live build and tests pass 372/372,
including the new zero-scatter regression and concurrent charge-tape tests.
Full proof: `/tmp/espice-zero-stamps/final-validation.md` and
`atomic-only-bench.md`.

## Final memory and solver review

The review retained the existing data layout and `std.Io` BBD scheduling.
It found three construction/failure ownership defects: `SparseLu.init` leaked
allocated buffers on later allocation failure; `LaneLu.init` did the same;
`Preconditioner.init` could destroy uninitialized sideband solvers, and its
block-banded scratch cleanup ended before eager factorization could fail.

The fixes initialize owned slices empty before installing existing `deinit`
cleanup, track the successfully initialized solver prefix, and keep optional
scratch cleanup in function scope through `factorAll`. There are no new
persistent fields or tables. Counts remain equation/nonzero/lane/sideband
counts; values and u32 indices are unchanged. Allocation order and successful
lifetimes remain the same. Failed construction now releases exactly its owned
prefix; borrowed CSC patterns and column permutations remain borrowed.
Independent review found no correctness issue in these ownership changes.

Failure injection reproduced the original SparseLu leak at allocation 2 of 18
(12 bytes), the LaneLu leak at allocation 2 of 5 (32 bytes), and a preconditioner
cleanup crash. A singular block-banded factorization also leaked five buffers.
Regression tests cover every allocation failure in both LU constructors and
all three preconditioner modes, plus the late numeric failure. These are
failure-path memory fixes; successful-run RSS and throughput are not claimed
to improve.

The remaining measured policy and memory constraints are:

| Area | Retained decision |
|---|---|
| BBD tasks | At most 16 opt-in `std.Io` tasks, disjoint numeric/pivot slabs; all join before errors escape, then fixed-order Schur reduction. Existing full-deck medians favor serial: RC mesh 126.9 vs 130.2 ms (16 tasks), dense RC blocks 125.3 vs 131.2 ms (8 tasks). |
| Frequency SIMD | LaneLu shares a borrowed pivot/index tape and owns five vector planes. Concurrent frequency chunks would need separate mutable base solvers or a different pivot/fallback schedule; sharing the current workspace would race. |
| Device threads | Each extra lane owns full scatter planes: `8*(nnz+1+n+1)` bytes without charge, twice that with charge, plus small scheduling/cache state. Compacting those slabs needs a different scatter-address contract and measured reduction costs. |
| Device cache | Non-repeated PrepCache groups currently allocate unused evaluation-cache storage. Current generated built-ins do not expose PrepCache; no workload evidence justifies another library-only change in this pass. |
| Output | Existing single-transient streaming remains the principal measured RSS reduction; retained/multiple analyses keep their existing result lifetime. See the memory-streaming audit. |

No scheduler rewrite or automatic threading threshold was introduced.
The focused BBD test still covers absent/limited async capacity, failure and
recovery, and bitwise normal/transpose solves. OOM reproductions and isolated
checks are `/tmp/espice-memory-last/` and `/tmp/solver-schedule/`.

The final live build passes all 251 steps and the full test build passes all
259 steps with **376/376 tests**. The complete solver suite separately passes
120/120 tests under ReleaseSafe/LLVM. All eight full CPU payloads match the
saved pre-memory-fix live binary bit-for-bit, including the user's latest
charge-tape work. An initial build caught an in-progress VerA rename
(`solveConst`); the user's caller update resolved it, and the unchanged audit
patch then built successfully. Source hashes confirm the three solver files,
evaluator and device tests were stable through this check. The preconditioner
file has pre-existing formatter differences in three tests; those lines were
preserved. Patch and validation logs: `/tmp/espice-memory-last/`.
