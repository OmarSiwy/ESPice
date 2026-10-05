# Preparation performance (September 2026)

Two preparation changes: voltage-source names are indexed during binding
(see [frontend.md](../frontend.md), "Build"), and `PatternBuilder.radixSort`
(`src/device/abi.zig`) skips digits no key uses. Packed keys, scratch
lifetimes, CSC layout, device tapes and the frozen GPU ABI are unchanged.

## End-to-end benchmarks

`zig build bench` medians, after one warm-up, including process startup,
preparation, the solve and output. Reference conversion is outside the timed
interval. All ESPice, ngspice and VACASK comparisons agreed.

```sh
zig build bench -- --filter op/controlled_source_scaling.sp --iters 9 --timeout 30
zig build bench -- --filter stress/scaling_resistor_grid_100x100.sp --iters 7 --timeout 30
```

| Fixture | Runs | Before, ms | After, ms |
|---|---:|---:|---:|
| `op/controlled_source_scaling.sp` | 9 | 36.761 | 22.541 |
| `stress/scaling_resistor_grid_100x100.sp` | 7 | 90.336 | 102.385 |

`op/controlled_source_scaling.sp` has 2,048 independent
voltage-source/resistor/CCCS/load groups with permuted control references and
an analytic voltage/current oracle. It stresses preparation, not a long
nonlinear transient. Before the change, binding scanned every F/H/W reference
for every voltage source, then scanned every voltage-source name again for
each control binding. The 38.7% reduction applies to this fixture and both
changes together: the after binary also has the radix change, so the figure
does not isolate name lookup and says nothing about device evaluation.

The controlled-source baseline precedes source indexing; the grid baseline
immediately precedes the radix change. The grid benchmark came out slower;
it establishes no radix wall-time win.

## Interleaved grid check

Because the grid run looked like a regression, saved before and after
binaries were compared in 21 alternating pairs during concurrent VerA builds:
one warm-up, CPU with one device and solver thread, preparation via
`--plan --timing-in-depth`, and full runs with binary output.

| Measurement | Before median, ms | After median, ms |
|---|---:|---:|
| Preparation process wall time | 26.200 | 23.629 |
| Problem creation within preparation | 16.715 | 14.743 |
| Full process wall time | 89.566 | 90.166 |
| Problem creation within full run | 17.355 | 16.405 |
| Analysis, scheduling, and output within full run | 62.910 | 63.946 |

After was faster in 15 of 21 preparation pairs and 8 of 21 full-run pairs.
Full-run ranges were 83.441 to 117.923 ms before and 81.770 to 110.229 ms
after; the paired median after-minus-before difference was +2.312 ms. The
original 13.3% slowdown did not recur at that size, but a smaller regression
is still possible.

## Radix mechanism and instruction evidence

The OR of all keys identifies all-zero digits and bounds the histogram
buckets. Skipping zero digits removes the empty pass between packed 16-bit
row/column ids and its final copy; larger ids keep every necessary pass.

An isolated Callgrind driver used topology-equivalent stamps. Counts include
two `toCsc` calls, allocation and key restoration; they are instructions, not
elapsed time or whole-simulator figures.

| Driver | Input keys | Unique entries | Before instructions | After instructions |
|---|---:|---:|---:|---:|
| Grid 100×100 | 89,207 | 49,607 | 11,944,431 | 6,602,513 |
| RC ladder 100k | 600,005 | 300,005 | 73,456,908 | 68,480,580 |

That is 44.7% and 6.8% fewer instructions. The oracle is the test "pattern
CSC matches comparison sort across radix digits" in
`src/analysis/tests/circuit.zig`: a comparison sort and hash set checked in
ReleaseSafe on empty input, the 63/64/65-key thresholds, unsorted duplicates,
empty columns, zero digits, ids above 65535, and odd and even pass counts. No
SIMD kernel was added.
