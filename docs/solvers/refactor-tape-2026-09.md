# SparseLu.refactor SIMD restructuring — negative result (2026-09)

Branch `simd-refactor`. Verdict: **refactor stays scalar in global
coordinates**. Every vector/restructured variant was bit-identical to the
oracle and faster in the hot microbenchmark — and the best one still lost
19% wall end-to-end. This log is the evidence and the rerunnable rig.

Machine: i9-14900HX (AVX2, no AVX-512; W=4 for f64), zig 0.16.0, ReleaseFast.
Workload: `tran/fourbitadder` (n=991, nnz=8329, L=9994, U=11404 after
AMD+BTF; ~110k axpy elements/refactor, ~255 refactors/run).

## Re-measured on spice-audit (2026-09-07) — the premise moved, verdict holds

Rebased onto `spice-audit` (past the merge train: path-integration, VerA
temp-hoist, fetlimds, Meyer $prev, BSIMSOI, GPU-resident, LTRA/TXL/CPL, and
the **BBD-permutation index-remap fix**). `sparse_lu.zig` is byte-identical
to that base — the verdict "refactor stays scalar" needs no change; the
kernel was never touched.

But the re-profile (same `-Ddebug-info=true` callgrind on
`tran/fourbitadder`) shows the **premise below is now void on this fixture**:
`SparseLu.refactor` executes **0 times**. The BBD-permutation fix routes
fourbitadder through the bordered-block-diagonal solver (`bbd.zig`:
per-block dense LU + Schur, explicitly "no refactor/pivot replay"), so the
flat `SparseLu.refactor` axpy replay — the entire subject of this log — is
off the hot path for this class. Raw-callgrind confirmation: no
`SparseLu(f64).refactor` symbol in the profile at all; `SparseLu.factor`
runs 1×; the refactor source lines (the `w[li[pl]] -= lx[pl]*uki` axpy)
carry ~36K Ir.

New program total 1,543.8M Ir (was 1,619.6M). Top real buckets are now the
device eval, not the solver:

| bucket | Ir (self) | share | note |
|---|---|---|---|
| `DeviceBatch(bjt).eval` (incl. pow/exp/log) | — | ~40% incl. | pow 132.9M, exp 104.3M, log 159.8M self still present — temp-hoist did **not** remove the per-bias exponentials |
| BBD dense-block factor (inlined; tagged `sparse_lu.zig:SolverT.factor`) | 337.0M | 21.83% | dense LU + Schur, D1-read-miss 20.2% — the arena scatter/block strides, NOT the sparse axpy |
| `SolverT.rawSolve` | 49.5M | 3.21% | |
| `SparseLu.refactor` | 0 | 0% | not dispatched on this fixture |

Decision (per the doc's own reopen rule and the re-measure brief): the "best
variant" optimized the flat `SparseLu.refactor` path, which this fixture no
longer takes — re-racing it end-to-end would measure a cold path, i.e. the
dead-variant re-exploration the brief forbids. No re-race run. The negative
verdict for the flat-refactor kernel stands as written; the microbench and
end-to-end evidence below are retained as the record for any workload that
still drives the flat path (large single blocks the BBD partitioner leaves
whole — see "What would reopen this"). Everything below this section is the
original 14ed081 measurement, kept verbatim.

## Baseline share (original tree, commit 14ed081)

callgrind, `-Ddebug-info=true` build (Release strips DWARF by default; the
`zig-out-di` prefix keeps the stripped build intact):

| bucket (sparse_lu.zig lines) | Ir | share |
|---|---|---|
| refactor | 404.8M | 25.0% |
| solve | 48.4M | 3.0% |
| factor | 4.4M | 0.3% |
| program total | 1,619.6M | |

Inside refactor: axpy inner loop 298.6M (74% of the kernel, ~10.6 Ir/flop),
zero-pattern walk ~31.5M, A-scatter 18.8M, normalize ~27M. The axpy line
also carries 17.3% of all D1 read misses — partly memory-bound already.

## Step 1: run-length distribution (measure before vectorizing)

`dev_harness.zig` on a `ZP_LU_DUMP` capture of the fixture:

- Global coordinates, L columns sorted ascending: **7.9%** of flop-weighted
  elements are covered by 4-runs. Direct SIMD on `w[li[p]] -= lx[p]*uki` is
  dead on arrival for this pattern class.
- Active-set-local coordinates (rank within sorted(U steps) ++ k ++
  sorted(L rows)): 4-runs cover **52.0%**, 2-runs 71.2%, 8-runs 35.3%
  (m_max=343, avg front ~20). Greedy 8/4/2/1 decomposition: 51,657 ops for
  109,977 elements — but 31,663 (61%) of the ops are scalar singles.

The local formulation also collapses all replay indices to u16 ranks into a
dense L1 front (`wloc`), makes zero a contiguous fill and normalize a
contiguous vector divide (the L part of the front IS the lx column order
once factor sorts L columns).

## Step 2: variants, all bit-identical to `lu.refactor` before racing

| variant | ns/refactor (hot µbench, 2000 reps) |
|---|---|
| plain (shipped): global coords, scalar | 120,306 |
| tape scalar (`refactorLocal(W=1)`) | **86,717** |
| tape + branchy 4-wide runs (`refactorLocal(W=4)`) | 125,933 |
| tape + build-time 8/4/2/1 run classes (`RTape`) | 112,422 |
| tape + masked uniform 4-wide ops (`MTape`, load-blend-store) | 159,942 |
| tape + 4/2/1 classes, packed counts (`RTape2`) | 121,677 |

Two findings:

1. **Run-vectorizing the axpy scatter loses even in the hot loop.** 52%
   4-run coverage is not enough: the per-op decode + short-vector traffic
   costs more than the scalar stores it replaces, and the masked variant is
   worst (blend-store defeats store-forwarding). Scalar store-forwarding
   through the dense front wins.
2. The scalar tape looks like a 28% kernel win — in a microbenchmark where
   its tapes stay cache-resident. That is the trap; see step 3.

## Step 3: end-to-end, where the tape loses

Shipped-candidate = scalar tape (vector zero + vector normalize, scalar
axpy). callgrind on the full fixture:

| | before (plain) | after (tape) |
|---|---|---|
| refactor kernel Ir | 404.8M | 314.8M + 0.5M dispatch (−22%) |
| memset (see hazard below) | 8.2M | 74.7M (+66.6M) |
| factor + tape build | 4.4M | 5.5M |
| program total | 1,619.6M | 1,609.1M |

After fixing the memset hazard the Ir win is real — and wall time still
regresses:

- hyperfine, pinned to one P-core, 10 runs, after measured FIRST (thermal
  worst-case for before): before **120.4 ± 0.8 ms**, after **143.2 ± 1.3 ms**
  → tape is **1.19x slower**. Unpinned 5-run means agree (128.4 → 149.6 ms).
- `scaling/rc_ladder_10k`: 237.1 → 239.2 ms, `devices/hisim2`: 66.1 →
  67.7 ms — noise-level (their refactor shares are small).
- cachegrind: D1 miss rate improves 3.9% → 1.5%, but **LL read refs go
  21.2M → 59.3M (2.8x)**. The per-flop `loc` tape is 110k u16 = 220KB per
  refactor with **zero reuse** — streamed fresh every refactor. The plain
  path re-reads the same ~40KB of `li` columns across U steps, D1-resident.
  Between refactors the device eval evicts everything, so the real run pays
  the stream, and the hot microbenchmark (tapes L2-resident) never sees it.

Ir is not time: −22% instructions, +19% wall. The reused-index working set
beats the sequential-but-larger tape. That is the whole verdict.

## Hazard found on the way: LLVM memset loop-idiom on short zero loops

`while (z < m) : (z += W) wloc[z..][0..W].* = @splat(0)` with runtime `m`
is loop-idiom-recognized into a `memset` CALL. At m ~ 20 slots (~160 B)
that was 252,705 calls / 66.6M Ir — ~21% of the tape kernel, pure call
overhead. Fix that keeps inline vector stores: splat from a value loaded
through a `*const volatile T` (a non-comptime store value blocks the
idiom). Verified in asm: `vmovups ymm` stores, no memset call, `vdivpd`
normalize intact. Applies to any short variable-length fill in a hot loop;
`@memset` on large buffers is unaffected (the call amortizes).

## What would reopen this

- Pattern classes with long L columns / large fronts (post-layout power
  grids): run coverage → contiguous and the per-op overhead amortizes.
- AVX-512 (scatter/gather + mask registers): MTape's blend tax disappears.
- Workloads where the tape fits and stays in L1 (tiny n, refactor-dominant
  loops with no device eval between solves).
- **A workload that actually drives the flat `SparseLu.refactor` path.** As of
  spice-audit, `tran/fourbitadder` goes BBD (dense blocks, no replay), so it
  is no longer the fixture to profile for this kernel. Pick one the BBD
  partitioner leaves as a single large block, or force the flat path, before
  re-racing.

Reopen = rerun the rig, not re-argue: the harness differential-checks every
variant (bit-identical) before racing, so only the timing question reopens.
Confirm the fixture still dispatches `SparseLu.refactor` (grep the callgrind
out for the symbol; on fourbitadder post-BBD-fix it is 0) — else the race
times a cold path.

## Reproduce

```sh
# capture a pattern from any run (libc builds only; last full factor wins)
ZP_LU_DUMP=/tmp/zplu.bin zig-out/bin/espice -b -r /tmp/o.raw \
    benchmark/fixtures/tran/fourbitadder/circuit.sp
# stats + differential checks + race (fixture copy lives in testdata/)
zig run -OReleaseFast -fllvm -mcpu=native src/solvers/dev_harness.zig -- \
    src/solvers/testdata/fourbitadder_lu.bin 2000
# symbolized profile (Release strips DWARF; ~3x LLVM time)
zig build -Ddebug-info=true -p zig-out-di
valgrind --tool=callgrind --cache-sim=yes zig-out-di/bin/espice -b ...
```
