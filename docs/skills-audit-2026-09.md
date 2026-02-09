# Data layout, SIMD and code reduction audit

2026-09-07. Structural screening of 100 Zig source files across ESPice and VerA; detailed
changes below. This does not establish that every algorithm is optimal or
that every analysis matches ngspice. Existing user changes were preserved.
Initial source snapshots and diffs: `/tmp/espice-skills-2ly1cosk/`.
This pass removes 103 net implementation/test lines across both projects;
this report is additional documentation, excluded from that count.

## Applied changes

- Replace duplicated copy/cold-fill kernels with `@memcpy`, `@memset`,
  or the existing shared prefix-copy function. Keep measured hot vector fills,
  explicit arithmetic SIMD,
  scalar fallbacks, element types, SoA layout and allocation lifetimes.
  Shared copying preserves common-prefix length and exact aliasing.
- Assemble dense frequency admittance directly into its LU buffer. The
  unfactored matrix had no consumer after copying. Saves `4*n*n*sizeof(T)`
  bytes (8 KiB at the default maximum dense size, n=16 with f64) and one
  full matrix copy per frequency; G/C remain available for the
  next frequency, and multiple RHS/adjoint solves reuse the factors.
- Release initialized direct-solver storage if subsequent scratch/value-copy
  allocation fails. Allocation-failure injection checks every allocation.
- Add bounded `std.Io.async` execution for independent BBD block LU and
  column solves. Tasks share immutable block metadata and write disjoint
  existing numeric/pivot slabs. Schur reduction retains block order.
  Every task joins before any singular failure returns to the scalar fallback.
- VerA compacts shrinking phi operand lists in their existing payload regions
  and revisits the join instead of allocating a temporary phi list. It keeps
  unrelated edges, neighboring payloads and dead-phi aliases intact.
- Repair the reference verifier's carry-end mask and run it under LLVM
  ReleaseSafe. The old XOR included changed run bits as well as the end bit;
  ReleaseFast disabled the assertions intended to verify those claims.

## Data and scheduling decisions

Buffer operations transform contiguous `f32/f64` or `u32` planes without
arithmetic. Counts follow equation/nonzero/sample counts, with `usize` only
for addresses and slice extents. Storage remains caller-owned. These independent
copy/cold-fill operations use compiler/runtime bulk primitives instead of
duplicate kernels. Hot numeric planes retain temporal vector stores.

BBD keeps its existing SoA block offsets and contiguous A/W/F slabs. Scheduler
configuration is cold: optional caller-owned `std.Io` plus an eight-bit task
limit, read together at dispatch. At most 16 tasks run; small estimated work
stays serial. No per-task matrix copies or parallel floating-point reductions.
Unavailable asynchronous capacity executes the same function synchronously.

Phi pairs retain `u32` block/value handles. Each validated replacement removes
two predecessor edges and inserts one, so forward compaction fits the original
region. MIR mutation stays serial within the compilation arena.

### Rejected default: automatic BBD threading

`ESPICE_SOLVER_THREADS=N` opts into solver tasks, capped at 16. Default is one.
Dense flop estimates overpredict useful work in sparse block interiors.
Do not enable threading automatically based on those estimates alone.

An earlier version using builtin arena fills measured 431 microseconds
serial and 193 microseconds with 16 requested tasks on a 64-block, 32-row
dense-factor microbenchmark. Interleaved full-deck checks of that retired
version measured:

| Workload | One task | Multiple tasks | Complete binary payload |
|---|---:|---:|---|
| 64 repeated 32-node RC meshes | 143.8 ms | 156.7 ms, 16 tasks | Bitwise identical |
| 8 dense 64-node RC blocks | 185.3 ms | 195.2 ms, 8 tasks | Bitwise identical |

These exploratory timings ran on a shared development machine with compilation
activity. They did not justify automatic threading; they are not final-version
speed claims. Fallback: one task or absent `Io`. Upgrade: profile complete workloads
and measure block density, task cost and size imbalance before setting a gate.

### Rejected simplification: builtin fill of hot numeric arenas

An isolated BBD experiment changed only arena zeroing: original factor code
with builtin `memset` took about 427 microseconds, versus 342 microseconds
with its original vector fill. The final threaded implementation with vector
fill measured 348 microseconds serial and 140 microseconds with 16 tasks.
These are the synthetic 64-by-32 factor workload, not full-deck claims.
The vector fill is retained. Shared hot analysis-plane zeroing is retained
too; bulk simplification must not trade away locality or measured throughput.
Serial BBD still factors and consumes each block before moving to the next.

### Final isolated benchmarks

The final snapshot passed all eight CPU payload comparisons bit-for-bit,
including AC, BSIM1/2, RC100k, BBD mesh, parallel inverters and four-bit adder.
Three-iteration `zig build bench` medians:

| Workload | Before | Final | Final CPU RSS | ngspice RSS | ngspice comparison |
|---|---:|---:|---:|---:|---|
| RC transient | 3.85 ms | 3.98 ms | 4.8 MB | 12.2 MB | PASS |
| BSIM1 | 12.81 ms | 12.81 ms | 5.6 MB | 11.9 MB | PASS |
| BSIM2 | 12.90 ms | 13.14 ms | 5.8 MB | 12.1 MB | PASS |
| Ladder AC | 4.68 ms | 4.70 ms | 4.9 MB | 12.3 MB | N/A |
| BBD RC mesh | 130.14 ms | 129.26 ms | 8.8 MB | 17.9 MB | PASS |
| 2,000 inverters | 3.067 s | 3.108 s | 20.1 MB | 24.3 MB | FAIL |
| RC100k | 1.845 s | 1.862 s | 143.2 MB | 220.4 MB | PASS |
| Four-bit adder | 105.48 ms | 105.65 ms | 6.9 MB | 13.4 MB | N/A |

Separate five-round alternating RC100k runs writing to `/dev/null` measured
2.310 s before versus 2.306 s after. No overall simulator speedup or RSS
reduction is established by these measurements; the dense-buffer saving is
structural and below these fixtures' RSS resolution. Shared-machine timing
noise remains. No benchmark normalization or accuracy gate changed.

Final BBD full-deck medians: RC mesh 126.9 ms serial versus 130.2 ms with
16 requested tasks; dense RC blocks 125.3 ms serial versus 131.2 ms with
8 requested tasks. Both threaded payloads are bitwise identical to serial.
The synthetic factor-only gain does not justify automatic threading.

CUDA: inverter median 1.364 s before versus 1.370 s after; four-bit adder
367.85 ms before versus 406.28 ms after. These timings do not establish a
GPU improvement. Inverter samples differ by at most 2.11e-15 across versions;
four-bit-adder samples differ by at most 7.74e-5. CPU equivalence does not
imply bitwise CUDA determinism. Three repeat runs of the original adder
CUDA binary differed by up to 7.96e-5; the patched binary by up to 7.46e-6.
The cross-version difference is within the observed original repeat spread;
this supports existing GPU variability, not proof of universal GPU equivalence.

## Structural findings retained for later work

| Area screened | Finding and next evidence needed |
|---|---|
| Sparse/direct/frequency solvers | Sparse pivot/elimination dependencies prevent arbitrary row threading. Frequency chunks mutate their base pivot tape; concurrent chunks need separate mutable workspaces and a memory budget. Existing frequency SIMD stays intact. |
| Devices and GPU dispatch | Shared CPU/GPU evaluator and frozen scatter ABI stay intact. Dense local derivative/scatter work remains a candidate for compiler-proven inactive-coordinate elimination; preserve limiting corrections and chain rules. |
| Transient and other analyses | Timesteps/Newton iterations remain sequential. Existing single-transient streaming already removes retained waveform storage; multi-job output still retains results. |
| Frontend and builder | Existing parse/simulation lifetime split, intern tables and circuit SoA remain. No speculative parser rewrite or blanket narrowing without input bounds. |
| Output and benchmark tools | Formats have distinct contracts; generic writer infrastructure would add machinery. Benchmark PASS still has coverage/normalization limits; missing signals and complex plots are unvalidated. |
| VerA IR/backend | Existing MIR SoA and dense SSA indexing remain. Phi payload compaction removes actual duplicate storage. `$table_model` still sorts on each evaluation; cache only with a measured workload and correct instance lifetime. |
| Build/model sources | Generated device equations and runtime compiler behavior remain unchanged. Physics models and active topology edits were not rewritten for line count. |

## Verification

- Initial ESPice snapshot: 366/366 tests. Final implementation snapshot:
  368/368; final live build and tests also pass 368/368. Solver ReleaseSafe
  checks: 116/116, including threaded/synchronous
  BBD equality, normal/transpose solves, singular failure and recovery.
- VerA: 279/279 before, 280/280 after; 171/171 expression conformance fixtures.
  Live build/tests passed after the phi change. All 39 built-in Verilog-A models emit
  byte-identical Zig before/after.
- Solver assembly retains packed `vmulpd`/`vaddpd`; bulk operations lower to
  standard `memcpy`/`memset` where retained. No new arithmetic SIMD kernel was introduced.
- Standalone SIMD reference verification passes with
  `zig run ref/SIMD-Strategies/verify.zig -fllvm -OReleaseSafe -mcpu=native`.
- Benchmark reports, source patches, generated-model comparisons and execution
  logs live in the artifact directory above. Generated stress decks are there
  too; they are not presented as representative layout workloads.

Reproduction uses `zig build && zig build test`, `zig build bench -- --iters 3
--timeout 30 --no-xyce --filter ... --out /tmp/report.md`, and VerA's
`zig build test -Doptimize=ReleaseFast`, `zig build torture
-Doptimize=ReleaseFast -- ch04_expressions -j4`, and
`zig build bench -Doptimize=ReleaseFast -- gen`.

## Concurrent edits and measurement scope

The final live build passed 368/368 tests. During validation, additional user
edits appeared in `solvers/converger.zig`, `analysis/tran/tran.zig` and VerA's
`backend/codegen.zig`; those edits were preserved. The live benchmark therefore
measures their combined state with this patch. Numerical comparisons that
isolate this patch use the original source/dependency snapshots plus only
this pass's edits.

The latest live benchmark (`bench-complete.md` in the artifact directory)
measured RC100k at 1.792 s and 143.6 MB, versus ngspice at 5.046 s and
220.4 MB, passing the benchmark's error gate. This is a whole-tree result,
not a speed or memory improvement attributable to this patch.
The 2,000-inverter fixture still fails ngspice comparison on CPU and CUDA
(max normalized error 1.49e-2); both are slower than ngspice. The initial
snapshot also failed that fixture (1.17e-2). Four-bit-adder and complex AC
results remain unvalidated by the harness. Universal accuracy and performance
parity are not established.
