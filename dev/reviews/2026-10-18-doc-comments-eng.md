# Design review: doc-comments audit, engine side

- **Change**: comment-only audit of every `//!` header and `pub` doc comment in `src/solver/`, `src/analysis/`, `src/device/` against the `doc-comments` skill.
- **Domain skill(s)**: `doc-comments`, `humanizer`.
- **Hot/cold**: n.a., no code changed.
- **Stages run**: R10 (doc audit) only, per §1.1 "any other diff".

Verification: every added or removed line is a comment, and the files with
their comment lines stripped are byte-identical to `int-3` (7c515efd).
`zig ast-check` passes on every touched file, so no doc comment sits where 0.17
rejects one. `zig fmt --check` fails on four files, but it fails on them at
`int-3` too (see P6). Nothing was built: zigq refuses agent builds, and a
comment-only diff has no build risk past `ast-check`.

Commits on `audit-doc-eng`:

| Commit | Module | Files |
| --- | --- | --- |
| 41aa1585 | solver | 14 |
| 3d4cc2d6 | device | 7 |
| a01909ab | analysis | 59 |

Every file in all three modules already opened with a `//!` header. Most were
missing their citation line, and many lacked an in → out statement. Every `dev/`
path cited by a new header was checked with `ls`.

## Findings, worst first

### Wrong contracts (APPLIED)

| # | File | What was wrong | Commit |
| --- | --- | --- | --- |
| 1 | `src/solver/converger.zig` `residualGate` | Said "a zero `diag` returns inf". Since #152 a zero diagonal (a branch row) is gated at scale 1, a tolerance in volts. The comment also named only `newton` as a user, but `jfnk` uses the gate too | 41aa1585 |
| 2 | `src/solver/converger.zig` `Options.init_fix` | Said `newton` publishes "the first passing solve". It publishes the second passing iterate, and the INITFIX pass stages no device state. Applies to direct Newton only (#53) | 41aa1585 |
| 3 | `src/device/eval.zig` `StateKernel` and `gpuEligible` | Said both halves run fused per iterate, except for held batches. Since #15 the launcher never sets both bits: the limit half runs per iterate and the state half once per converged solve (`analysis/gpu.zig:1539`, `:1632`) | 3d4cc2d6 |
| 4 | `src/device/abi.zig` `GpuPayload.held` | Its doc told the launcher how to schedule. Nothing reads it now (see P2) | 3d4cc2d6 |
| 5 | `src/analysis/knobs.zig` `gpu_eval_check`, `gpu_nofuse` | EVAL_CHECK is a device-vs-device replay, not a host check. NOFUSE turns off the `evalFollows` shared wait; it does not "unfuse kernels" | a01909ab |
| 6 | `src/analysis/gpu.zig` `eval`, `host_planes`, `poisoned` | `eval` does not bring `q_tape` to x (it downloads into `pin_tape`, and `syncQTape` copies later). `deinit` does not restore the planes; `restorePlanes` does. A failed tape sync also poisons | a01909ab |
| 7 | `src/analysis/Circuit.zig` `eval` | Claimed `eval` and `evalNewton` are the only GPU entry points. The GPU also enters through `evalQ`, limits, the state passes, `seedJunctions`, `clearLimits`, the q-tape sync and `deviceSolve` | a01909ab |
| 8 | `src/analysis/dc/tf.zig` `solve` | Named `error.SingularMatrix`. `dense_lu` returns `error.Singular`, and only after `pinVoid` (#160) | a01909ab |
| 9 | `src/analysis/tran/tran.zig` `simulate` | Promised `x` holds the last accepted solution. Both dt-underflow returns skip that copy, and running out of `max_steps` returns `completed = false` | a01909ab |
| 10 | `src/analysis/ac/noise.zig` `PerSource` | Said the caller zeroes `out` and `in`. `dens` is written only on each correlated group's first row, so all three must be zeroed. The `Columns` doc was also attached to the wrong declaration (an `@import`) | a01909ab |
| 11 | `src/analysis/session.zig` header | Said a row is "a query plus its implicit OP". Implicit OPs are rows of their own | a01909ab |
| 12 | `src/analysis/pss/phasenoise.zig` `stitch` | "Reads pac[0..nlp.len]" implied `pac` may be longer. The zipped `for` asserts equal lengths | a01909ab |

### Stale contracts (APPLIED)

- `src/device/abi.zig` `Planes`, `Batch`: ParEval no longer gets private slabs. Since #137/#138 it stages through `Hooks.stage`. (3d4cc2d6)
- `src/device/abi.zig` `GpuPayload`: a host-stepped batch's `instances` change at every host step (`pushStepped`, #139), not only on a sweep. (3d4cc2d6)
- `src/device/eval.zig` `Sink.lim_`: the plane is `count * LimMap(D).k`, not `count * n_u` (ABI 21). `walksPending` excludes only `hasCtlKernel` types. (3d4cc2d6)
- `src/solver/order.zig`: each block takes AMD or natural order, whichever fills less (#46). (41aa1585)
- `src/solver/direct.zig` `factor`, `Params.bbd_refine_growth`, and `residual_tests.zig` `certify`: the replay probe (`replayHolds`) also forces a full factor, and the BBD probe refines one solve each way, A and A^T. (41aa1585)
- `src/solver/converger.zig` header: the hook list was missing `solver_execution`, `loadCheck`, `deviceSolve` and `evalFollows`. (41aa1585)
- `src/analysis/certify.zig` and `Circuit.certify`: the certificate runs only on staged points, so INITFIX is skipped. (a01909ab)
- `src/analysis/executor.zig` header: under `final_plan` the dependency is moved, not copied. (a01909ab)
- `src/analysis/gpu.zig`: `eval_follows` was renamed `evalFollows`. `Decline.policy` also covers `ImageNotCompiled` (#139). (a01909ab)
- `src/analysis/dc/op.zig` `transientOp`: a `//` copied from `solveLadder` made no sense where it sat. "dt 10 ns to 1 µs" misread `dt_max`/`t_stop`. (a01909ab)
- `src/analysis/pss/qpss.zig`: cited the deleted `solver/preconditioner.zig`. (a01909ab)
- `src/analysis/pss/phasenoise.zig` `Diffusion.dc`, `sweep/lanes.zig`, `sweep/mc.zig`, `dc/dc.zig` and `ac/noise.zig` headers: each now describes the features added since the comment was written (correlated-group rows, `warm`, variants, tangents, phase and sampled noise). (a01909ab)

### Missing contracts (APPLIED)

Errors, asserts and invalidation lines were added to public entries that
lacked them:

- **solver**: `freq_solve` `solve`/`solveBatch`, `sparse_lu.refactor`, `bbd` `InitError`/`factorWithExecution`, `lu_kernels` (15-task cap), `lane_lu.refactor`, `tridiag.factor`, `direct.dropBypass` (not for BBD).
- **device**: eight undocumented `Hooks` fields, `collect_params` (makes a held `GpuPayload.models` stale), `lim_pass_state` (it had no doc at all; a `///` attaches to one declaration only), `Circuit.freeze`, `Library.LoadError`, `loader.prepareAll`, `bind.markKnown`.
- **analysis**: `Executor.create`, `Session.advanceReady`/`advance`/`InvalidQuery`, `Circuit.linearizeAc`/`updateStates`/`recompute`/`restoreState`/`attachGpu`/`configure`, `ParEval.init`/`run`, `gpu.syncHostState`/`evalFollows`, `certify.check` (it panics on OOM), `matex.run`, `sens.solve`, `dcmatch.solve`, `disto`, `mosra`, `envelope`, `ac`, `sp.toModes`, `hb.solveSpectrum`/`solveOscillator`, `mhb.spectrum`/`solve`/`orbit`, `pss.solve`, `pac.sweep`/`orbit`, `qpss.solve`, `pnoise.orbitSweep`.

### Headers (APPLIED)

Every header that cites an outside source now has a citation line: ngspice and
VACASK sources, LRM sections, papers, issues and `dev/` notes, all taken from
its own body (the small leaves in P12 cite nothing). Each test file under
`src/analysis/tests/` now names its oracle.

### Proposed, not applied

| # | Where | Finding | Why not applied |
| --- | --- | --- | --- |
| P1 | `src/solver/direct.zig:283-292` `factorInner` | **Possible bug.** When `refactorLu` succeeds and then `replayHolds` fails with OOM (or `demote` hits OOM), `factor` returns the error with `factored` still true and `vcopy` holding the old values. A later `factor` with those old values takes the bypass and solves on a factor that does not match them. The doc now says OOM leaves no usable factor, but the code does not enforce it | Code change |
| P2 | `src/device/abi.zig` `GpuPayload.held` | Written (`gpu.zig:875`) and read nowhere since #15 | Code change plus an ABI bump |
| P3 | `src/device/abi.zig:4` header | Claims everything crossing the separately compiled boundary is in `layoutHash`. `GpuPayload` and `ScatterTapes` cross it as hook return values, but `hashType` does not follow them | Code change plus an ABI bump |
| P4 | `src/device/eval.zig` (lines ~440, 709, 797, 1668, 2209) | Cites four `dev/` notes that do not exist anywhere in git history: `dev/perf/jac-width-2026-09-10.md`, `dev/perf/remaining-2026-09-10.md`, `dev/device-evaluation-audit-2026-09.md`, `dev/devices/noise-contract.md`. Line 1668 sits inside a `@compileError` string, which is code | Needs an owner to pick the replacement notes |
| P5 | `src/solver/residual_tests.zig` `certify` | "Thomas has no growth check (measured 105)" may predate #45, which added a pivot refusal | Needs a re-measure |
| P6 | `src/analysis/executor.zig`, `sweep/sens.zig:156`, `tests/session.zig`, `src/device/bind.zig` | Fail `zig fmt --check` at `int-3`, before this audit | Code reformat, outside a comment-only audit |
| P7 | `src/analysis/Circuit.zig` `restoreState` | A no-op while a GPU context is attached, so a pss/qpss/hb/envelope rewind under `--backend cuda` keeps the resident state. The contract now says so, and the existing `ponytail:` note names the gap | Behaviour decision |
| P8 | `src/analysis/dc/dcmatch.zig` `Groups.label` | Would index out of bounds on a group with no members | Assert or validate: a code question |
| P9 | `dev/solvers/overview.md:110` | The usage example calls `solveBatch` without its `dyn` argument | Outside `src/`; trivial doc fix for whoever owns `dev/` |
| P10 | `src/analysis/post/disto.zig` `sweep` | Its `///` holds a numbered walk-through of the algorithm, which is implementation, not contract | Borderline; left as is |
| P11 | `src/analysis/pss/pss.zig:21` | `/// ponytail:` on a private const; the marker belongs in `//` | Cosmetic |
| P12 | `src/analysis/*.zig` small leaves (`worker`, `walk`, `progress`, `root`, `knobs`) | No citation line, but they cite nothing outside ESPice | Low value |

## Proposed issues

1. **`direct.Solver.factor` keeps `factored` true after `OutOfMemory`, so the bypass can serve a stale factor.**
   If `replayHolds` (after a successful refactor) or `demote` fails on allocation, `factor` returns with `factored` true and `vcopy` unchanged. The next `factor` call with the old values then takes the bypass. Fix: add `errdefer self.factored = false;` in `factorInner`, plus a test with a failing allocator.
2. **device ABI: `GpuPayload.held` is dead since #15.**
   `gpuPayload` writes the field and `BatchGpu.held` copies it, but no code reads it, since every state kernel now runs once per converged solve. Either drop it (with an `abi_version` bump) or give it a reader.
3. **device ABI: `layoutHash` omits `GpuPayload` and `ScatterTapes`.**
   Both are returned through `Hooks` across the per-model object and `.so` boundary. `hashType` follows only by-value fields, so a layout change in either goes undetected. Add both to the hashed list and bump `abi_version`.
4. **Dead design-note references in `src/device/eval.zig`.**
   The jac-width, remaining-perf, device-evaluation-audit and noise-contract notes are cited but were never committed. Restore them, or point the citations at `dev/devices/abi.md` and `dev/devices/gpu-evaluation.md`.
5. **`zig fmt --check` fails on four engine files at `int-3`.**
   `src/analysis/executor.zig`, `src/analysis/sweep/sens.zig` (a double space in `principal`), `src/analysis/tests/session.zig` and `src/device/bind.zig`. Run `zig fmt`, and decide whether the gate checks formatting.

## Checklist

| # | Check | Source | Verdict | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Every file opens with `//!`: in → out and citations | AGENTS.md §2.15; doc-comments "module header" | pass | All 93 files open with `//!`; 74 headers changed in this audit |
| 2 | Every `pub` item names a fact the signature cannot | doc-comments "The test" | pass, with an exception | Undocumented are duck-typed interface methods (Dual arithmetic, `apply`/`restore`, `call`) and `test_access` shims, whose names are their contract |
| 3 | Reachable asserts have `Asserts that` lines | doc-comments step 4 | pass | See "Missing contracts" |
| 4 | Errors documented with their condition | doc-comments rank 4 | pass | See "Missing contracts" |
| 5 | Comments verified against the code | doc-comments audit step 3 | pass | 12 wrong and about 15 stale claims fixed |
| 6 | Placement compiles | zig.md "Placement" | pass | `zig ast-check` passes on all touched files |
| 7 | No code changed | audit brief | pass | Files stripped of comments are identical to 7c515efd |
| 8 | Dead references | doc-comments audit step 2 | fail, proposed | P4, P9 |
