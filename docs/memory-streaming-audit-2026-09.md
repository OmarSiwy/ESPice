# Memory and streaming audit, 2026-09-07

Accepted transient samples can go straight to the binary raw file. The CLI now
does this for one `.tran` job, retaining one output row instead of the complete
waveform and its transposed `Result`. The integrator, tolerances, accepted steps,
device evaluation and library `Result` API remain shared with the retained path.

## Measurement scope

Machine: i9-14900HX, RTX 4060 Laptop (8 GiB), Zig 0.16.0, ngspice 44.2.
ReleaseFast with LLVM. Measurements include process startup and output writing;
peak RSS comes from GNU time. This is a shared development machine.

The baseline includes the user's uncommitted topology, allocator and accuracy
work, over ARPice `3f5905cb` and VerA `71beced7`. In particular, fourbitadder
already has **451 equations**, matching ngspice. The historical 991-equation
measurement does not describe this baseline. That reduction belongs to the
user's existing work.

The user continued editing BSIM1, BSIM2, diode and solver sources during final
validation. Those changes were preserved. The benchmark tables describe the
frozen audit snapshot and must not be read as a verdict on those later changes.

Initial VerA sources contained six `std.posix.getenv("VERA_DBG")` diagnostic guards
in `src/backend/codegen.zig`; Zig 0.16 cannot compile that removed API. Early
validation used copied sources with only those guards disabled. The user then
removed the diagnostics; comparison confirmed that this was the only compiler
difference from the snapshot. No active compiler behavior was patched for testing.

Artifacts and preserved initial diffs: `/tmp/espice-concise-o8miw2/`.
The snapshot has adjacent ARPice/VerA directories and uses the pinned gompute
package. `ZIG_GLOBAL_CACHE_DIR` points to that artifact directory's `global-cache`.

Three-run medians, with no audit compilation running during timing:

| Fixture | Before CPU | Final CPU | ngspice | Before RSS | Final RSS | ngspice RSS | Accuracy |
|---|---:|---:|---:|---:|---:|---:|---|
| RC transient | 5.98 ms | 3.78 ms | 8.28 ms | 4.6 MiB | 4.5 MiB | 12.3 MiB | PASS |
| RC ladder 10k | 243.06 ms | 172.91 ms | 442.63 ms | 71.8 MiB | 17.6 MiB | 32.9 MiB | PASS |
| RC ladder 100k | 2.613 s | 1.793 s | 5.166 s | 670.7 MiB | 143.5 MiB | 220.0 MiB | PASS |
| Fourbitadder | 107.70 ms | 105.24 ms | 21.26 ms | 7.7 MiB | 6.9 MiB | 13.3 MiB | N/A |

The 100k ladder uses 78.6% less peak memory than the initial snapshot, and 34.8%
less than ngspice. It runs 2.88 times faster than ngspice in this measurement.
All four CPU outputs have identical metadata and **bitwise-identical complete
binary sample payloads** before and after the storage changes. Header point-count
padding is normalized when comparing metadata. Final report: `bench-final.md`;
payload checks: `stream-bitwise.json` and `memory-bitwise.json`.

GPU results also expose remaining gaps:

| Fixture | CPU | CUDA | ngspice | CPU/CUDA accuracy |
|---|---:|---:|---:|---|
| 2,000 parallel inverters | 3.082 s | 1.357 s | 1.020 s | FAIL, max normalized error 1.17e-2 |
| Fourbitadder | 105.24 ms | 341.62 ms | 21.26 ms | N/A, missing reference signals |

CUDA is 2.27 times faster than CPU on the inverter workload, but still slower
than ngspice. Fourbitadder is about five times slower on CPU than ngspice, and
CUDA adds overhead. RC ladder device work is cached/too small for offload; its
GPU column correctly reports a declined run. These results do not meet the
overall faster-and-equally-accurate target across workloads.

The complete 264-fixture screen (`bench-corpus.md`, one timing iteration,
10-second per-run timeout) produced **146 CPU PASS, 12 FAIL, 70 N/A, 18 CPU
SKIP, and 18 CPU runs without an ngspice comparison**. Only eight GPU runs
actually offloaded: two PASS, one FAIL and five N/A. One-sample corpus timings
are screening data; the table above uses three-run medians.

All 12 CPU failures were rerun with both the initial and retained pre-streaming
binaries. Every
normalized header and binary payload was identical to the final run: these
accuracy failures predate every audit change. Evidence:
`/tmp/espice-initial-corpus-4qxoejqt/comparison.json` and
`/tmp/espice-corpus-check-K4W1dr/comparison.json`.
Failures: `devices/{bsim1,bsim2,bsim4,diode_temp,hfet_inverter,mos6_inverter}`,
`ensemble/pvt_corners`, `ngspice/{mosamp,mosmem}`, `power/rectifier`,
`scaling/parallel_inverters_2000`, and `vacask/mul`.

After the helper import fix, both `verilogA/res_divider` and
`verilogA/diode_clamp` compile and simulate successfully. Their ngspice commands
do not support these HDL decks, so these move from CPU SKIP to successful runs
without comparison, not PASS. The divider and diode outputs also satisfy their
analytic checks (`hdl-analytic.json`). `verilog/inverter` still reports
`UnsupportedHdlExtension`; it is separate from the Verilog-A helper bug.
The targeted rerun is `bench-hdl-fixed.md`; its timings overlap compilation and
are not used for performance claims.

## Changes

- Binary CLI transient output uses one contiguous row and a 4 KiB writer buffer.
  A temporary file receives accepted samples; successful completion patches the
  point count and publishes the file atomically. Failed runs preserve previous
  output. Symlinks, hard links and special destinations use the retained writer.
  Multiple jobs and other formats also retain their existing behavior.
- Retained `Waveform` starts at 64 points instead of a minimum 1024. Growth still
  follows the existing estimate and geometric policy. This helps library users
  and formats outside the streaming path.
- BBD subtracts each Schur contribution directly, removing the temporary dense
  block and second traversal. Arithmetic order is preserved. Scratch savings for
  f64 are `8 * sum(m_i²) + 8 * blocks` bytes, plus a 16-byte slice field on x64.
- VerA SSA matrix growth copies only minted Place rows. Untouched capacity stays
  zero without faulting those pages into physical memory.
- Runtime HDL compilation exposed a second VerA bug: split-output `h.zig` math
  helpers referenced `contract` without importing it. One generated import line
  fixes the lexical scope; the module dependency was already wired correctly.
- HFET2 follows ambient temperature plus DTEMP when TEMP is unspecified;
  explicit model TEMP overrides both. A six-case regression checks ngspice drain
  currents. Frontend conversion of explicit device TEMP units is a separate
  remaining issue; this test validates the generated model's Kelvin API.
- Benchmark timings discard ngspice/Xyce console output. Large output previously
  exceeded the capture limit despite successful simulation. ESPice skip and GPU
  fallback diagnostics remain checked.
- Benchmark comparison indexes names once and reuses signal buffers. The former
  nested name search required billions of comparisons on the 100k ladder.
  Error normalization, interpolation and coverage policy are unchanged.
- Release app tests use the production LLVM backend. GDB confirmed native Zig
  codegen reused flags clobbered while materializing a floating comparison: a
  correct BJT alias `3` was compared against a wrongly selected expected `null`.
  The generated BJT was byte-identical before and after this audit's SSA change.

## Verification and limits

Streaming differential tests compare every sample with retained integration,
including UIC, initial/final points and deck temperature. Writer tests cover
probe order, point count, failures, cleanup and destination kinds.
Final snapshot build succeeded; **365/365 full-suite tests passed**. Subsequent
live build and tests also succeeded, with **366/366 tests** after concurrent user
additions. The benchmark runner's five standalone tests also passed. CLI checks preserved single binary,
multi-plot and ASCII output plus `/dev/null` and symlink behavior.
The final live binary also reproduced all four original baseline sample payloads
exactly (`live-final-bitwise.json`).

BBD: all 113 solver tests passed. Independent before/after replay covered 78
matrices, 390 successful factorizations and 156 singular outcomes per version;
factors, pivots, normal/transposed solves and recovery were bitwise identical.
AVX2 multiply/add instructions remain in the dot kernel. Eleven interleaved,
pinned fourbitadder runs measured 99.889 versus 99.466 ms: no material speed claim.
Evidence: `/tmp/espice-bbd-review.RTjV0t/`.

VerA: all seven isolated SSA tests passed; snapshot build and full tests passed.
The final current-source VerA build passed, with **279/279 tests**, including the
new helper compile regression. That regression fails with only the import
removed and passes after restoring it (`/tmp/vera-helper-regression.iUgcYd/`).
Synthetic SSA growth stress used 98,472 versus 49,224 KiB median RSS. This is a
stress result, not a claim that whole-compiler memory halved.
Evidence: `/tmp/vera-ssa-audit.auJ5lk/`.

Waveform replay of 236 samples and 100,002 probes reduced median peak RSS from
587,096 to 498,776 KiB with identical checksums. Full CLI streaming measurements
are separate. Evidence: `/tmp/espice-waveform-replay.PhlcAQ/`.

The benchmark's PASS label does not establish complete ngspice equivalence.
Complex/multiple plots, missing signals and incomplete grids are unvalidated.
Errors use `max(peak, span, 1)` normalization and a reference-step window on steep
transient edges. Small currents and timing shifts need stricter device-specific
checks. The runner does not fail its process solely because accuracy fails.

GPU currently evaluates devices; the sparse solve remains on CPU. Small workloads
decline offload. A declined or failed GPU run must not count as GPU performance.
Streaming excludes the optional whole-transient GPU hook because its fallback
requires rewinding retained samples; the current device-evaluation hook still runs.

The remaining BJT cost needs a fresh profile. Global collapse leaves the generated
local model at 14 coordinates (nine voltages, five flows) and `DualFor(14, f64,
true)`. The five flow rows are compile-time inactive, but the shared evaluator
still expresses 196 G and 196 C scatter calls. CUDA PTX confirms 420 f64 atomic
adds including residuals, **180 with provably zero operands**. This is emitted
PTX evidence, not a timing or final SASS count. The frozen dense tapes use
896 bytes/BJT. Artifact:
`.zig-cache/o/fcf8adf6a2b25715592ca9749755bd18/gompute_bjt.ptx`,
SHA256 `859782fd64435fa158b72c8d8066a82afa02e6611bfe7a81e9241851f89a5e9b`.
A compiler-proven inactive-row mask could remove zero scatter work while keeping
that ABI; compact AD could then shrink 14 to nine derivative coordinates. Further
alias compaction must preserve the chain rule and limiting corrections. This
audit leaves the user's ongoing compiler/topology edits intact.

## Reproduction

Run from the isolated ARPice source snapshot, with the environment above:

```sh
zig build && zig build test
zig build bench -- --iters 3 --timeout 30 --no-xyce \
  --filter basic/rc_transient --filter scaling/rc_ladder_10k \
  --filter scaling/rc_ladder_100k --filter tran/fourbitadder \
  --out /tmp/espice-concise-o8miw2/bench-final.md
```

Use a build that detected CUDA, and run outside the restricted device sandbox,
for actual NVIDIA measurements. Baseline/after memory reports are
`bench-snapshot-before.md` and `bench-snapshot-after.md` in the artifact directory.
