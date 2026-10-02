# Design review: ponytail audit (ultra), engine half

- **Change**: a whole-module audit for over-engineering (dead code, needless `pub`, speculative abstractions, duplicated knowledge, hand-rolled std, stale `ponytail:` debt) of `src/solver/`, `src/analysis/`, `src/device/` and the in-repo `models/*.va`.
- **Domain skill(s)**: `ponytail` (ultra), `ponytail-audit`, `ponytail-debt`; `spice-engine` for what is physics and not duplication.
- **Hot/cold**: not assessed per finding. No applied change touches code that runs (comments, `pub` and unused declarations only). Every proposal that touches a loop is marked as needing a build, the corpus or a probe.
- **Stages run**: R10 only (§1.1, "any other diff"). There is no build: zigq refuses agent builds, so only changes that grep proves safe are applied.
- **Base**: `int-3` at 7c515efd, on branch `audit-pony-eng`.

Method: a declaration scan (every container-level `fn`/`const`/`var` against every identifier in the tracked files and in `zig-pkg/`, which catches VerA's reflection reads), then four read-through passes, one each over solver, analysis core with dc/sweep/tests, analysis ac/pss/tran/post/eigen, and device with models. I re-checked every applied item by grep before editing it. Two proposals from the passes turned out wrong and are dropped: `tran.Method` (`tests/transient.zig:458` reads it) and the `VpiHost` decls (VerA's `contract.validateHost` reads them by reflection).

## Applied

| # | Tag | Where | What | Commit |
|---|---|---|---|---|
| A1 | delete | `src/device/root.zig:16-19` | `device.models` and `device.Entry` re-exports have no consumer; every importer takes `@import("models")`, and `Entry` types `catalog` only inside catalog.zig | 89a91125 |
| A2 | delete | `src/analysis/ac/stb.zig:3`, `ac/xf.zig:3` | unused `const std` (no `std.` in either file) | 89a91125 |
| A3 | shrink | `pss/mhb.zig:59 max_box`, `tran/matex.zig:361 estPoints` | `pub` on aliases that only their own file reads | 89a91125 |
| A4 | shrink | `analysis/Circuit.zig` `groundStamp`, `clearPlanes`, `evalNewtonCpu` | `pub` with no caller outside Circuit.zig. The `clearPlanes` doc said ParEval and the GPU half share it, but neither calls it; the doc is fixed | eef61cbe |
| A5 | delete | `dc/op.zig:332-333` | duplicated "holds can pin the floating nodes" comment where it described nothing | eef61cbe |
| A6 | stale | `dc/op.zig:268` | "JFNK, the algorithm the GPU kernel runs": no GPU JFNK exists (every solve runs on the host, §2.9) | eef61cbe |
| A7 | stale | `pss/qpss.zig:536` | cited `solver/preconditioner.zig`, which is gone; the upgrade it names now exists as `mhb.Operator.precond` | eef61cbe |
| A8 | delete | `tran/{integrator,tran,matex}.zig`, `post/disto.zig:628`, `pss/hb.zig:208` | `ponytail:` tags that defer nothing ("platform SIMD width"; an allocation note), and a GPU-batch debt item repeated 20 lines below its first copy | eef61cbe, 89a91125 (matex) |

Net applied: −19 lines, 0 behaviour change. Neither commit is compile-checked; the gate must run before integration. (A3 and A4 can only fail to compile if an unseen caller exists, and grep finds none in src, tests, tools, build.zig or zig-pkg.)

## Findings, ranked by cut (PROPOSED)

| # | Tag | Where | What, and the fix | Why not applied | ≈ lines |
|---|---|---|---|---|---|
| P1 | **bug** | `src/solver/tests.zig:1164` | `const PivotTests = struct {…}` is missing from the `test { _ = …; }` list at `tests.zig:3887-3900`, so its four #45 tests (Thomas threshold, replay probe, zero `pivot_tol`, capped re-pivot) have **never run** (introduced in 0282d149). Fix: add `_ = PivotTests;` | they may fail on first run; needs `test-solver` | +1 |
| P2 | yagni | `pss/qpss.zig` (696 lines) | a second two-tone HB solver. `mhb.solve` takes any tone count and has the preconditioner qpss lacks. Fix: run `.qpss` through `mhb.solve` and keep only the (k, l) output remap | the corpus may move; owner decision | −550 |
| P3 | yagni | `solver/converger.zig:386-560` `jfnk` | carries its own Arnoldi/MGS/Givens/back-substitution plus `ensureGmres` scratch; `gmres.zig` `Gmres` already does it. Fix: build JFNK on `Gmres` with an FD matvec op | rounding and stop criteria change on op rung 4; needs the corpus | −90 |
| P4 | delete | `solver/sparse_lu.zig:577-672` `census()` | the E1 structural census, behind `ZP_LU_STATS`. The experiment is recorded in `dev/solvers/gpu-lu.md` | owner: keep the dev knob? | −80 |
| P5 | delete | `analysis/gpu_lu.zig:390-519`, `Knobs.gpu_lu_bench/threads`, `GpuLu.idx` | the `ESPICE_GPU_LU_BENCH` harness ships in the library. Fix: a bench tool or a comptime build option | owner; GPU build | −130 |
| P6 | shrink | `dc/tf.zig:24-101` vs `dc/xf.zig:20-84` | `.tf` repeats `.dcxf`'s readout on a dense O(n²) LU. Fix: build `tf` on `xf.excite`/`Output.seed/read`/`immittance` and the sparse factor; also read `output_node/neg` from `options` instead of separate arguments | last-bit result moves; `+inf` vs `1e20` convention differs | −50 |
| P7 | shrink | `post/disto.zig:276-302, 339-350` | three inline copies of `solveAt` and one of `scatter` | compile | −16 |
| P8 | shrink | `pss/hb.zig:107-151`, `qpss.zig:438-478`, `pss.zig:351-371` | a hand-kept size sum plus an `off +=` carve list, twice per file. `mhb.zig:443` already has `take`; move it to `types.zig` | compile | −40 |
| P9 | yagni | `tran/{tran,envelope,tran_noise}.zig`, `pss/pss.zig` | four Newton hooks with identical `vals`/`diagAt`, two with identical trapezoid assemble/accept. Fix: one companion hook in `integrator.zig` | on the Newton path: §2.1 rung-5 probe | −35 |
| P10 | shrink | `sweep/sens.zig:106-143` vs `dc/dcmatch.zig:143-173` | the same FD-adjoint knowledge twice. The λ seed is hand-written four times (`sens:78`, `dcmatch:206`, `tf:73`, `xf.Output.seed`) | `eval` vs `evalNewton` changes bits | −35 |
| P11 | stdlib | `tran/tran_noise.zig:23-58` | `Xorshift64` + Box-Muller → `std.Random.DefaultPrng` + `floatNorm(f64)` | the noise stream changes, and seeded fixtures with it; owner | −30 |
| P12 | yagni | `ac/{ac,stb,xf,lstb,sp,acmatch}.zig` | the same 5-line frequency-axis block (alloc, slice, `sweep.fill`, `FreqSolver.fromCircuit`) six times. Fix: one helper in `freq.zig` | compile | −20 |
| P13 | delete | `tran/types.zig:169-177`, `tran/envelope.zig:15-24` | `SimResult.steps/.t_final` and `outer_steps/.t_final` are never read. Fix: return `bool`/`n_points` | compile | −20 |
| P14 | stdlib | `tran/matex.zig:430-462, 574-584` | hand `@Vector` loops that §2.11 routes to `num.sub/scale/axpy` | bit-exactness vs corpus | −25 |
| P15 | delete | `solver/converger.zig:116,197-214,768` `Options.matrix_sig` / `factored_sig` | no caller sets `matrix_sig`, so `need` is always true; `Solver.factor`'s value compare covers it | compile; 9 dev pages describe it | −10 |
| P16 | delete | `Result.max_dx` (converger + 8 analysis writers) | written everywhere, consumed nowhere | crosses files; compile | −9 |
| P17 | yagni | `solver/sparse_lu.zig:143` `SparseLu.init(row_idx)` | parameter discarded (`_ = row_idx;`), passed at ~35 call sites | wide signature change | −35 args |
| P18 | yagni | `solver/direct.zig:20-42` `Params` | `pivot_tol`, `repivot_fill_cap` and `bbd_refine_growth` are never set off their defaults; only `refactor_growth_limit` is written (`freq_solve.zig:192`). Fix: file-level consts | compile (`residual_tests`, `gpu_lu` read them) | −6 |
| P19 | shrink | `solver/dense_lu.zig:25-34,199-233` | `factorizeSolve[Neg]` duplicates `factorize` + `solveFactored` through a second elimination mode | 8 callers need `piv` scratch; bitwise check on HB/PSS/disto | −50 |
| P20 | shrink | `solver/converger.zig:537-548` | the jfnk update loop is `updateAndNorm` (`:690`) verbatim | compile | −11 |
| P21 | yagni | `solver/lu_kernels.zig:668-728` | private `HostFactor` exists only for `HostRefactor`, whose init/deinit delegate to it; merge them | GPU build | −12 |
| P22 | shrink | `tran/tran.zig:678-686` `atStop` | same answer as `almostEqualUlps(t, t_stop, 100)` (`:752`) for t ≥ 0 | compile | −13 |
| P23 | shrink | `pss/{pss,qpss,hb}.zig`, `tran_noise.zig:533` | local `simdZero`/`simdCopy` renames of `root.zeroSimd/copySimd`, plus a test that tests the alias (`tests/periodic.zig:149-165`) | multi-file compile | −15 |
| P24 | shrink | `pss/pnoise.zig`, `mhb_lptv.zig`, `ac/noise.zig:113`, `ac/acmatch.zig:56` | the ±1 output-drive vector built six times → `root.outputDrive` | compile | −12 |
| P25 | shrink | `pss/hb.zig:153-166` vs `mhb.zig:463-473` | the DC-seed block is copied verbatim → `dcSeed` | compile | −10 |
| P26 | shrink | `device/eval.zig:2503-2526` | five `"arp_<x>_" ++ baseName(D)` functions → one `kernelSym(prefix, D)`; the symbols stay identical | GPU export path; default build | −10 |
| P27 | shrink | `models/vccs_delay.va` vs `vcvs_delay.va` | the same body twice; fold into a `` `define DELAY_CURRENT `` wrapper, as `vcvs_laplace` does | VerA build + delay decks | −16 |
| P28 | yagni | `analysis/gpu_lu.zig:65` `GpuLu.check` | a copy of `knobs.gpu_lu_check`, stored next to `knobs` | GPU build | −2 |
| P29 | yagni | `analysis/worker.zig:21` `Options.stack_size` | never set; `par_eval.zig:320` hard-codes the same 512 MiB. One const | compile | −2 |
| P30 | shrink | `gpu.zig:181` / `gpu_lu.zig:24` `nowNs` | copy-pasted `clock_gettime`; keep one, or `std.Io.Timestamp` | GPU build | −5 |
| P31 | shrink | `sweep/temp_sweep.zig:13` vs `dc/dc.zig:297` | the `numPoints`/`sweepCount` nudge copied (the comment says so); descending-span edge differs | edge behaviour | −6 |
| P32 | shrink | `device/loader.zig:184` vs `:398` | `generation = 1` and a hard-coded `".1"` in the `.so` path: one fact in two places | compile | 0 |
| P33 | shrink | `device/loader.zig:104,385`; `device/bind.zig:58,93` | duplicated `Prepared` init and comptime lower-key block | compile | −8 |
| P34 | stdlib | `solver/fft.zig:31-35` `nextPow2` | wraps `std.math.ceilPowerOfTwoAssert`; one caller (`post/four.zig:65`) and a test | compile | −8 |
| P35 | small | `mhb.zig:146` realloc by hand → `gpa.realloc`; `four.zig:47` `probe_idx` always 0; `pac.zig:121,193` + `hb_lptv.zig:200` sideband ω ×3; `stb/lstb/noise/pnoise/four` `test_access` re-exports of already-`pub` fns; `Circuit.zig:863` `evalFollowsFirst` | compile | −25 |
| P36 | test | `analysis/tests/gpu.zig` | a single test that restates `backend`'s definition, so it is tautological (§2.6). It is also the root's import of gpu.zig; check the test count before deleting | count check | −17 |

Rejected after checking: `executor.zig:507-546` `validate`/`Tolerances` (a fork proposed deleting them). They are comptime contract assertions, which §2.5 keeps always on. `bbd.zig` `simdZero`/`dotSimd`: measured, and `num.dot` would reassociate. The `Circuit.zig:272-337` one-line setters are a documented style, so changing them is an owner call. `progress.Phase.postprocess` is never emitted but is pinned in `include/espice.h:69`. `qz.zig:251` vs `core/eigen.zig:203` orders the roots differently. `Library.zig`/`loader.zig` linear scans are within their ceiling.

Proposed net: about −1,450 lines (P2–P36), 0 dependencies. P1 adds one line and turns on four tests.

## Ponytail debt (`ponytail:` ledger)

Counts after this branch: solver 16, analysis 55, device 13, models 53.

| Status | Items |
|---|---|
| Resolved, rewritten here | `qpss.zig:536`: the named node-major preconditioner exists in `mhb`. It is fully resolved once P2 lands |
| Not debt, removed here | `tran/{integrator,tran,matex}.zig` "platform SIMD width", `disto.zig:628`, the duplicate `hb.zig:208` |
| Half resolved, owner check | `converger.zig:596`: "until the op ladder learns to restart under JFNK". op rung 4 does run JFNK now, but the text says `parallel_inverters_100` still converges only when JFNK drives the whole ladder, so the pin stays. Reword when someone re-measures |
| Unblocked, not needed yet | `device/eval.zig:2884` systf: the pinned VerA now ships `contract.SystfHost` |
| Open, ceiling not hit | everything else. Solver: `bbd`, `lu_kernels`, `direct`, `dense_lu`, `sparse_lu`, `converger:294`. Analysis: `worker:34`, `executor:228/404/444`, `Circuit:236/528/964/1005`, `gpu:257/1219/1905`, `gpu_lu:333/343`, `dcmatch:135`, `lanes:31`, `pss/*`, `tran/*`, `ac/*`, `post/*`. Device: `eval:37/715/1466/1500/2443/2699/3019`, `catalog:37`, `Library:110`, `loader:487/497/503`. Models: every tag names an ngspice behaviour or a VerA limit that still holds |

## Proposed issues

1. **solver: PivotTests (#45 regressions) never run.** `src/solver/tests.zig:1164` declares `PivotTests`, but the `test {}` reference list at `:3887-3900` omits it, so Zig never analyses its four tests. Add `_ = PivotTests;`, run `zig build test-solver`, and fix whatever fails. Add a fitness check that flags every `const XTests = struct` missing from its file's reference list.
2. **pss: run `.qpss` on `mhb.solve`.** qpss.zig is a second two-tone HB solver without a preconditioner. MHB covers any tone count with `Operator.precond`. Keep the (k, l) output remap only. Exit criterion: the qpss decks hold their verdicts. About −550 lines.
3. **converger: build JFNK on `gmres.Gmres`.** It is about 175 lines of private Arnoldi/Givens. Use an FD matvec op, with `updateAndNorm` for the update. Op rung 4 and the corpus must hold.
4. **solver/analysis: drop never-set options and never-read results.** `converger.Options.matrix_sig`/`factored_sig`; `Result.max_dx`; `direct.Params.{pivot_tol, repivot_fill_cap, bbd_refine_growth}` → consts; `SparseLu.init`'s discarded `row_idx`; `tran SimResult.steps/t_final`, `envelope outer_steps/t_final`; `worker.Options.stack_size`; `GpuLu.check`. Mechanical. Update the dev pages that describe `matrix_sig`.
5. **Move dev-only instrumentation out of the library.** `sparse_lu.census` (`ZP_LU_STATS`) and the `ESPICE_GPU_LU_BENCH` harness in `gpu_lu.zig`, about 210 lines between them, go to a bench tool or a comptime option.
6. **dc: build `.tf` on `.dcxf`'s sparse adjoint readout, and share one FD-sensitivity helper between `sens` and `dcmatch`.** Settle the `+inf` vs `1e20` convention first, and record any last-bit divergence per §2.7.5.
7. **analysis: fold duplicated plumbing.** P7, P8, P12, P23, P24, P25 and P35: the `take` carve, the frequency-axis helper, `outputDrive`, `dcSeed`, disto `solveAt`/`scatter`, sideband ω. Compile-only, results bitwise. About −140 lines.
8. **tran: one companion-matrix Newton hook (P9).** It needs a §2.1 probe, since it sits on the Newton path.
9. **tran_noise: `std.Random` for the noise stream (P11).** This is an owner decision because it changes seeded output.
