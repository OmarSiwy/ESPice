# Device evaluation profile — 2026-09-16

Callgrind 3.26.0 measured CPU execution of the existing ReleaseFast executable
with Zig 0.16.0. These are instruction counts, not elapsed-time percentages.
Other correctness checks were running, so no timing comparison was attempted.

The executable was `zig-out/bin/espice`, built from the cleanup working tree
based on checkpoint `41ff9a962c3c752cb1f3be7ff4d5fa354ce950fb`, before the
preparation performance changes. Its SHA-256 was
`b191563390a6608830fed1c8e71563377890d957407808e8beeb389883bc9365`.
The binary's modification time preceded both profiles and remained unchanged.

## Workloads and attribution

| Fixture | Devices | Transient points | Whole-process instructions |
|---|---:|---:|---:|
| `tran/device_mos6_inverter.sp` | 98 | 317 | 127,793,594 |
| `stress/scaling_parallel_inverters_100.sp` | 302 | 596 | 374,824,142 |

The MOS6 profile separates the device passes below. Inclusive counts contain
their called math routines; rows are separate entry points and do not overlap.

| MOS6 pass | Instructions | Whole-process share |
|---|---:|---:|
| Residual and Jacobian evaluation | 66,278,950 | 51.9% |
| Limiting | 9,109,359 | 7.1% |
| Accepted-solve state staging | 8,507,929 | 6.7% |
| Accepted-point charge evaluation | 6,689,101 | 5.2% |
| Total of these four passes | 90,585,339 | 70.9% |

Inside the first row, out-of-line math accounts for 8,273,793 instructions
(6.5% of the whole process); it must not be added to the row again. The
remaining process work includes other device types, solving, timestep control,
preparation, and output. This profile does not establish a 99% evaluation / 1%
preparation split, or a wall-time split between those stages.

The executable is stripped. Attribution used a direct assembly emission of
the MOS6 host object and matching function bytes/entry structure against the
profiled executable. Entry addresses were `0x2675a70` (evaluation),
`0x2681fe0` (limiting), `0x2680ec0` (state staging), and `0x26826b0`
(charge evaluation). A separate `-Ddebug-info=true -Dgpu=false` profiling
build failed with compiler SIGSEGVs in host device roots; it supplied no data.

## Reproduction

Run from the repository root with the identified executable:

```sh
valgrind --tool=callgrind --callgrind-out-file=/tmp/mos6.callgrind zig-out/bin/espice --backend cpu --rawfile /tmp/mos6.raw tests/fixtures/tran/device_mos6_inverter.sp
valgrind --tool=callgrind --callgrind-out-file=/tmp/mos1.callgrind zig-out/bin/espice --backend cpu --rawfile /tmp/mos1.raw tests/fixtures/stress/scaling_parallel_inverters_100.sp
callgrind_annotate --auto=no --tree=both /tmp/mos6.callgrind
```

The original profiles, raw results, logs, and MOS6 assembly are under
`/tmp/espice-src-cleanup/` as `mos6-eval-before.*`, `mos1-eval-before.*`, and
`mos6-host.s`. These are local investigation artifacts, not tracked fixtures.

## Candidate left unchanged

`evalRange` computes `corr_live` with a full derivative-vector comparison and
reduction, although MOS1/MOS6 limit only two unknowns. The emitted AVX2 path
includes `vpermps`, `vpslld`, `vpmovsxdq`, and `vmovmskpd` between the comparison
and scalar branch. Accumulating whether each computed correction is nonzero
while gathering those two unknowns may avoid that conversion chain.

No change was made: the expected benefit is small and has not been measured.
The existing vector reduction, correction arithmetic, host/GPU kernel, and
scalar fallbacks remain. Reconsider only with differential coverage for NaN
and signed zero, an assembly comparison, and before/after `zig build bench`
results on nonlinear transient fixtures. No performance gain is claimed here.
