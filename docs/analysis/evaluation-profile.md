# Device evaluation profile

Where a transient run's instructions go, measured twice (2026-09-16 and
2026-09-23), and the kernel changes that came out of it. Function names in
the tables are the ones at the profiled commit; some have since been renamed
or inlined.

## Profile of 2026-09-16

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
(charge evaluation). A `-Ddebug-info=true -Dgpu=false` profiling build
failed with compiler SIGSEGVs in host device roots at the time; `e5634f7`
fixed that (see below).

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

## Candidate left unchanged (since done)

The `corr_live` reduction this section described (a float compare whose i1
mask lowered through `vpermps`/`vpslld`/`vpmovsxdq`/`vmovmskpd`) is now
`anyNonzero`, an integer shift-and-test with the same predicate. See the
2026-09-23 section below for its differential case and numbers.

## Host-pass profile of 2026-09-23

Callgrind 3.26.0, Zig 0.16.0, base `11661cc`. Attribution comes from a
`-Ddebug-info=true -Dgpu=false` build, now buildable (`e5634f7` pins the host
device objects stripped; before that every one SEGV'd the compiler). Its
whole-process Ir is within 0.001% of the shipped default build, whose totals
are the before/after numbers. Self Ir except where marked inclusive; symbol
names are as profiled at `11661cc`, and some have since been renamed.

| Pass | mos6_inverter | share | parallel_inverters_100 | share |
|---|---:|---:|---:|---:|
| Whole process | 126.41M | 100% | 373.54M | 100% |
| Device eval + scatter, inclusive (`Circuit.evalNewtonCpu`) | 68.91M | 54.5% | 208.52M | 55.8% |
| ... of which `DeviceBatch(mos*).eval` self | 58.01M | 45.9% | 187.76M | 50.3% |
| ... of which plane zeroing/baseline memset+memcpy | 0.98M | 0.8% | 3.21M | 0.9% |
| Sparse LU factor (`direct.factor`, inclusive) | 11.14M | 8.8% | 24.13M | 6.5% |
| Limiting (`applyLimits`, `D.limit` inlined) | 9.11M | 7.2% | 32.68M | 8.7% |
| Accepted-solve state staging (`updateState`) | 8.51M | 6.7% | 16.49M | 4.4% |
| Accepted-point charge re-eval (`evalQOnly`) | 6.69M | 5.3% | 21.77M | 5.8% |
| LTE step bound (`integrator.stepBound`) | 3.36M | 2.7% | 17.72M | 4.7% |
| Sparse LU solve (`rawSolve`) | 3.24M | 2.6% | 10.08M | 2.7% |
| `simulateInto` self (history rebase loops) | 1.89M | 1.5% | 9.04M | 2.4% |
| `integrator.advanceCurrent` | 1.15M | 0.9% | 5.65M | 1.5% |
| `converger.finalizeStep` self | 1.29M | 1.0% | 4.57M | 1.2% |
| `stateCtl` (Meyer latch commit) | 1.02M | 0.8% | 3.23M | 0.9% |
| DC operating point, inclusive | 5.39M | 4.3% | n/a | n/a |
| Parse + prepare (`Problem.init`, inclusive) | 5.03M | 4.0% | 6.36M | 1.7% |

Inside `DeviceBatch(mos1).eval`, instruction-level attribution (`--dump-instr`)
puts the scatter at ~4 instructions per stamp (slot load, `vaddsd` from the
plane, store, a lane extract), about 45 stamps per instance: the tape layout
is FROZEN and AVX2 has no scatter, so that floor stays. The rest is the
generated physics. `applyLimits`, `updateState`, `stateCtl` and `evalQOnly`
are likewise physics with a thin gather around it.

### Kept (default-build Ir; all fixture raws byte-identical)

| Commit | Change | mos6_inverter | parallel_inverters_100 | inverter_chain_256 |
|---|---|---:|---:|---:|
| `e5fb043` | vector `rebaseCurrent`, swap not copy the per-state history | -1.08% | -1.88% | -1.05% |
| `4cd2ef6` | comptime `Method` in `stepBound`/`advanceCurrent` | -0.76% | -1.31% | -0.78% |
| `0100c06` | host `Sink` holds `q_tape`'s pointer, not `*DeviceBatch` | -0.54% | -0.85% | -0.87% |
| `eebea9f` | `corr_live` as `anyNonzero` (bits, not a float compare) | -0.56% | -0.43% | -0.42% |
| | cumulative | 126.41M -> 122.73M (-2.91%) | 373.54M -> 357.11M (-4.40%) | 4912.95M -> 4761.73M (-3.08%) |

Wall time is not claimed: A/A hyperfine on the shared machine these ran on
varied 5-20% per deck, more than any of these effects. `zig build bench`
needs VACASK, which is not on PATH outside `nix develop .#benchmarking`.

### Tried and dropped

- `stateCtl` with a comptime op (`inline else`), so a `.query` arm that
  returns `false` drops its loop: 3.234M -> 3.232M on parallel_inverters_100.
  LLVM had already unswitched it; the cost is the commit arm's field copies.
- `limitRange` with a comptime `lim_active`: two instantiations pushed
  `D.limit` out of line (the failure mode `limitRange`'s own comment
  records). parallel_inverters_100 357.07M -> 368.32M (+3.2%),
  mos6_inverter 122.70M -> 125.81M (+2.5%). Reverted.

### Still open, not attempted

- `stepBound` spends 2 of its ~8 instructions per `@max`/`@min` on NaN
  handling (`vcmpunordpd` + `vblendvpd`). A plain `maxpd` select is exact
  only where one operand is a non-NaN constant (`chgtol`, `abstol`): about
  4 of ~54 instructions per 4 states, ~0.25% of parallel_inverters_100.
  The data-data maxes would change NaN propagation, so they stay.
- `builder.applyKv`'s `mem.eql` scan over parameter names: 1.4% of
  `mos6_inverter`, preparation only.
- The rest of the time is generated physics (eval, limit, `updateState`,
  `evalQ`) and the solver (see
  [solver-perf-2026-09.md](../solvers/solver-perf-2026-09.md)).
