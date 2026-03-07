# Preparation performance, September 2026

This cleanup indexes voltage-source names during binding and reduces
`PatternBuilder.radixSort` work. Packed keys, scratch lifetimes, CSC layout,
device tapes, and the frozen GPU ABI remain unchanged.

## End-to-end benchmarks

Recorded `zig build bench` medians include startup and output, after one warm-up.
All ESPice/ngspice/VACASK comparisons agreed.

| Fixture | Runs | Before, ms | After, ms |
|---|---:|---:|---:|
| `op/controlled_source_scaling.sp` | 9 | 36.761 | 22.541 |
| `stress/scaling_resistor_grid_100x100.sp` | 7 | 90.336 | 102.385 |

The controlled-source baseline precedes source indexing; the grid baseline
immediately precedes radix changes. Both after results use the final executable.
The grid benchmark is slower; it does not establish a radix wall-time win.

Commands additionally supplied ngspice 45/VACASK 2026 executable paths and
`--out` report paths:

```sh
zig build bench -- --filter op/controlled_source_scaling.sp --iters 9 --timeout 30
zig build bench -- --filter stress/scaling_resistor_grid_100x100.sp --iters 7 --timeout 30
```

Reports: `/tmp/espice-src-cleanup/bench-{before,after}.md` and
`/tmp/espice-src-cleanup/grid-{before,after}.md`.

## Interleaved grid check

During concurrent VerA builds/tests, saved binaries were compared in 21
alternating pairs: one warm-up, CPU with one device/solver thread, preparation
using `--plan --timing-in-depth`, and full runs with binary output.

| Measurement | Before median, ms | After median, ms |
|---|---:|---:|
| Preparation process wall time | 26.200 | 23.629 |
| Problem creation within preparation | 16.715 | 14.743 |
| Full process wall time | 89.566 | 90.166 |
| Problem creation within full run | 17.355 | 16.405 |
| Analysis, scheduling, and output within full run | 62.910 | 63.946 |

After was faster in 15/21 preparation pairs and 8/21 full-run pairs. Full ranges
were 83.441–117.923 ms before and 81.770–110.229 ms after; the paired median
after-minus-before difference was +2.312 ms. The original 13.3% slowdown did not
recur at that magnitude, but a smaller regression remains possible. Samples and
binary hashes: `/tmp/espice-src-cleanup/grid-paired-binaries.json`.

## Radix mechanism and instruction evidence

The OR of all keys identifies all-zero digits and bounds histogram buckets.
Skipping zero digits removes the empty pass between packed 16-bit row/column
IDs and its final copy; larger IDs retain every necessary pass.

An isolated Callgrind driver used topology-equivalent stamps. Counts include two
`toCsc` calls, allocation, and key restoration; these are instructions, not
elapsed-time speedups or whole-simulator measurements.

| Driver | Input keys | Unique entries | Before instructions | After instructions |
|---|---:|---:|---:|---:|
| Grid 100×100 | 89,207 | 49,607 | 11,944,431 | 6,602,513 |
| RC ladder 100k | 600,005 | 300,005 | 73,456,908 | 68,480,580 |

That is 44.7% and 6.8% fewer instructions. Driver and profiles:
`/tmp/espice-src-cleanup/pattern-*`.

The comparison-sort/hash-set oracle in `src/analysis/tests/circuit.zig` passed
24 ReleaseSafe cases: empty input, 63/64/65-key thresholds, unsorted duplicates,
empty columns, zero digits, IDs above 65535, and odd/even passes. No SIMD kernel
was added.

## Validation

Build: 331/331. Unit tests: 366/368, including analysis 238/238, prepared 42/42,
builder 5/5, and output 36/36. Both Problem failures reproduce on checkpoint
`41ff9a9` with only the required device-contract compatibility patch.
Fixtures: 419/614 pass, 195 fail; no newly failing fixtures. Two HDL passes
changed amid external VerA edits and are not credited here.

The full gate remains red; changes after the checkpoint are intentionally
uncommitted. Logs: `/tmp/espice-src-cleanup/final-{build,test}.log` and
`/tmp/espice-src-cleanup/baseline-problem.log`.

These checks cover the cleanup snapshot. Concurrent changes to
`src/frontend/model_loader.zig` and the `hdl/veriloga_parallel` fixture arrived
after validation; they were preserved and are not covered by these results.
