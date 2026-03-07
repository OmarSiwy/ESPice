# Native transmission-line restoration and exact AMS migration audit

Audited 2026-09-16. Native restoration preserves the existing supported algorithms; exact AMS migration and full conformance remain open.

## Immediate finding

The audited checkpoint routes O/Y cards to `models/lossy_tline.va` and P cards to `models/coupled_tlines.va`. Their headers disclose dropped convolution kernels and a two-conductor modal approximation. The native Zig sources still exist, but registration was removed. This violates the requested no-approximate-substitution policy. Restore the supported native routes until a replacement passes equivalent numerical comparisons; do not count the current VA routing as migration success.

## Restoration design: six data-oriented questions

1. What data? Existing immutable native device types, Model/Instance blobs, and five CPU vtable bindings (LTRA, TXL, CPL with two, three, four conductors); no new runtime state layout.
2. What transformations? Bind card parameters once, allocate existing neutral prototypes, evaluate existing native residuals, and commit native histories only after accepted transient points.
3. What access? Cold construction reads a whole model; hot evaluation retains the existing per-device batches and SoA accepted-history arrays. No new hot lookup table.
4. What ownership/lifetime? Build-time model metadata is static; prototypes and instance histories retain their current prepared-circuit/session lifetimes. No cross-layer owning pointers are introduced.
5. What scale/ranges? Exactly five native bindings; existing u32 node handles and fixed native history capacities. CPL is limited to the native supported dimensions 2/3/4; unsupported dimensions fail explicitly.
6. What lane/kernel strategy? Devices are independent instance work; accepted timesteps remain sequential. Reuse the native scalar kernels unchanged and the existing CPU-only eligibility rule. No SIMD rewrite, GPU-specific algorithm, or frozen ABI change is needed.

## Standard boundary

Primary authority: [Accellera VAMS-2023 LRM](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf). Clause references below use that edition.

The standard supplies declared arrays, loops and analog functions (§§3.2, 4.7, 5.9), ordinary mathematical functions (§4.3), linear-interpolated delay (§4.5.7), rational Laplace filters (§4.5.11), dynamic timer scheduling (§5.10.3.3), and a maximum-next-step request (§9.17.2). It does not specify ngspice's particular convolution formulas, Padé coefficients, history compaction, integer-picosecond rounding, or accepted timestep sequence. Bessel-I and erfc are not listed standard mathematical builtins. VPI includes accepted-point/convergence callbacks (§12.31.3) and registered analog functions/tasks (§12.32). There is no standard source event named `accepted_step`. A maximum step request does not prescribe an integrator or guarantee identical sample times. Standard compliance and ngspice numerical compatibility are separate gates.

Consequently, do not add a supposed standard `$ltra`, `$convolve`, `$erfc`, or `@(accepted_step)` merely to translate native code. A user-registered function is a different, explicit interface. Do not change `absdelay` to quadratic interpolation for LTRA compatibility. Fixed-size numerical matrix algorithms are expressible in source; lack of a working lowering or simulator callback is not proof that matrix arithmetic itself is outside AMS.

## Existing native behavior and exact-migration dependencies

Paths below are relative to ARPice. Clause references name relevant standard facilities; the implementation tasks are conclusions from this repository audit.

| Native behavior and source | Existing source-level building blocks | Required simulator/compiler work | Separate compatibility requirement |
|---|---|---|---|
| LTRA `precompute`, `bessI0e`, `bessI1e`, `bessI1xOverXe`, `rlcH2Func`, `rlcH1dashTwiceIntFunc`, `rcH1*`, `rcH2*`, `rcH3*` in `models/native/ltra_native.zig` | Scalar arithmetic, conditionals, user analog functions; §4.3 math | Audit array/function lowering and generated f64 operation order; RC calls libc `erfc`, which requires a deliberate user-function or equivalent numerical implementation path | Reproduce the actual scaled polynomial coefficients and branching; erfc/library/platform parity needs an oracle. A different approximation is not interchangeable. |
| LTRA `intlinfunc`, `twiceintlinfunc`, `rebuildWave`, `rebuildRc` | Loops and indexed real arrays (§§3.2, 5.9); branch contributions | Runtime-sized history ownership and accepted-step snapshots; safe dynamic array indexing; preserve affine residual/Jacobian dependence while treating accepted history as constants | Fused O(history) sums, initial-value corrections, kernel chopping, auxiliary-index h2 interval mismatch and summation order all affect native results. No generic filter automatically reproduces them. |
| LTRA `interpDelayed`, `quadInterp` | Custom array search/interpolation functions | Access to committed history at arbitrary delayed times | First interval is linear, subsequent intervals quadratic; overshoot is not suppressed. `absdelay` is a distinct operator, not a numerical substitute (§4.5.7). |
| LTRA `pushHistory`, `updateState`, `compact` | Source variables can store values; this alone does not identify accepted solver points | Standard VPI accepted-point callback delivery and instance lifetime (§12.31.3), or an explicitly host-managed model interface until VPI exists; commit once, never on rejected trials | Five SoA histories, initial voltage/current seeding, same-time replacement, straight-line compaction and CAP=8192 policy. Current forced discard on overflow is a remaining native limitation. |
| LTRA `nextBreakpoint`, `updateState`, `precompute` max-safe-step bisection | `$bound_step` (§9.17.2), timer (§5.10.3.3) | Dynamic timer requests must reach the transient scheduler; standard callback request/cancellation and convergence semantics remain incomplete | Arrival breaks use a derivative test and an eight-entry ring. Hardcoded circuit tolerances and duplicated h2 straight-line test are compatibility details. Do not inject generic delay-echo breaks: that changes the accepted grid. |
| TXL `fitLine`, `getC`, `findRoots`, `root3`, `gauss3` in `models/native/txl_native.zig` | Scalar functions, fixed arrays and small matrix elimination | Correct array/function lowering, setup-time evaluation, deterministic coefficient transport | Hough/SWEC [3/3] Padé is already the TXL reference algorithm, not an AMS mandated transfer function. Its lossless shortcut, fit failure behavior, and high-R/L three-pi routing need dedicated cases. |
| TXL `rebuildLine`, `seedLine`, `commitLine`, `getPvs` | Complex arithmetic can be written as pairs of reals; loops/functions | Accepted/trial separation, delayed samples, callback and rollback delivery | Three h1/h2 and six h3 terms; complex h3 DC seed uses the native real-division quirk. Preserve operation and attenuation order. Generic `laplace_*` integration does not promise this recurrence. |
| TXL `updateState`, `eval` | `$abstime`, local values and conditional math | Publish current trial t/dt, commit only accepted points, invalidate trial caches on retry | History timestamps truncate to integer ps; recursive updates also use actual dt seconds. Sub-ps acceptances do not append. CAP=2048 front pruning can discard a still-live point. Bound is 0.9 delay; no generic wavefront breakpoints. |
| CPL `Setup.diagz`, `loopZY`, `evalSi`, `gauss2`, `approxMode`, `multP`; `matchFit`, `padeApx`; `CoupledLtra(N).precompute` in `models/native/coupled_ltra.zig` | Fixed multidimensional arrays, functions and loops | Multiple runtime array indices and full function-array argument semantics need conformance coverage; constant dimension elaboration must preserve N | Eight reciprocal-frequency samples; Jacobi ordering with truncated comparisons, degree-seven fit, per-entry three-pole Padé, R-entry floor 1e-4, scaled poles. Two-conductor even/odd algebra cannot replace arbitrary supported matrices. |
| CPL `rebuild`, `getPvs`, `seedTms`, `updateState`, `eval` | Same ordinary source facilities as TXL | Per-instance accepted-history lifetime, trial-cache isolation, callback scheduling and branch/Jacobian integration | Mode/conductor delayed interpolation, complex convolution initialization, cumulative coefficient scaling across real poles, integer ps, CAP=2048, bound 0.9 minimum delay. Native N is limited to 2/3/4; ngspice's larger dimension range is a separate task. |
| Native `eval` branch residuals and `u_kinds` | Conservative branches, contributions, implicit equations (Chapters 3, 5, 8) | Verify compiler branch unknowns, AD/Jacobians, analog operator state and analysis lifecycle against emitted model | Native TXL/CPL ignore card reference nodes like their ngspice construction path; the approximate coupled VA model honors them and differs in mutual-R DC behavior. Native non-transient paths currently stamp DC, so native AC cannot be the sole oracle. |

`../VerA/docs/CONFORMANCE-GAPS.md` currently tracks incomplete VPI, accepted-point callbacks, multidimensional dynamic indexing, delay history capacity, and simulator scheduling gaps. The existing narrow `SystfHost` bridge is not full chapter-12 VPI. First-call `$table_model` snapshots are not a mutable accepted-history queue. Digital simulation, connect modules and mixed-signal scheduling remain necessary for full AMS conformance, but pure analog transmission lines should not be made artificially dependent on every unrelated digital feature.

## What the approximate files actually omit

- `models/lossy_tline.va`: RLC uses an ideal delayed line with half the total series resistance at each end; h1'/h2/h3' kernels are absent. RC reduces to its DC resistance and omits erfc dispersion. Its step cap is 0.25 delay. LC and static RG are distinct branches and must be judged separately.
- `models/coupled_tlines.va`: only two symmetric conductors using even/odd closed forms; no general native modal fit or recursive convolution. It clamps mutual coupling, changes reference-node behavior, and has different mutual-resistance DC handling.
- Y cards have no dedicated exact VA TXL implementation. Routing Y to `lossy_tline.va` changes the algorithm even if a circuit has the same nominal R/L/G/C.

## Smallest restoration patch

Use pre-removal `fc7b115` (`HEAD^` at audit time) only as the behavioral reference. Historical definitions are `src/devices/root.zig:34–51`, and historical routing is `src/builder.zig:addTxl`, `addLossyLine`, `addCpl`, `cplVector`. Do not revert the current frontend/analysis refactor.

1. Export concrete LTRA, TXL and CPL(2/3/4) types from a native model aggregate. Add one CPU object built with the existing `src/analysis/eval.zig` root so it exports `arp_device_<name>` neutral vtables. Include that object everywhere existing model objects link: app, C adapter and tests. Keep the GPU root list restricted to its existing generated-device objects.
2. Add native exports to the frontend catalog without importing the evaluator into frontend. `src/frontend/builder.zig:Builder.addDevice` already resolves `devices.modelName(D)` to `devices.vtable(name)`. `src/analysis/eval.zig:deviceVtable` already owns prototype creation, precompute, batch construction and evaluation. `src/problem/device_ir.zig` stays unchanged.
3. Restore O-card RLC/RC native routing, Y-card supported TXL routing and P-card CPL dimensions 2/3/4. Preserve historical LC ideal and static RG routes. At construction, reject unsupported dynamic parameter sets, failed/nonfinite native fits, underflow that changes line classification, malformed scalar bindings and unsupported dimensions explicitly; do not restore historical approximate fallthroughs.
4. Reuse `eval.zig:hasAbsdelayState` and the `unrevertible_state` declaration. Its hook table already supplies native `commit_state`, `bound_step`, `set_sim_state`, and `next_breakpoint`. `Circuit.commitStates` and `tran/tran.zig` seed at t=0 and commit after acceptance. Rejected trial evaluations only update native pending/cache fields. Native State without limit is already CPU-only in `gpuEligible`.
5. Do not resurrect `record_history`/`inject_history`. Searches of the old evaluator show those hook fields had no native assignments. Native `eval` stamps history internally, and native `updateState` owns recording. The dormant slots can remain frozen-ABI placeholders.
6. Add routing/rejection tests and attach the existing native numerical unit tests to the full test target. Run the unchanged ngspice fixture comparisons. Update `docs/analysis/refactoring.md` to state that these natives remain active until an equivalent AMS replacement passes. Do not edit or bless oracle values to accommodate changed behavior.

## Existing runnable evidence

The following `tests/fixtures/tran/` fixture stems have checked-in ngspice-44.2 expected JSON, origin metadata and source hashes:

| Family | Existing stems |
|---|---|
| LTRA | `device_lossy_tline`, `bench_tline_ltra1_1_line`, `bench_tline_ltra2_2_line` |
| TXL | `bench_tline_txl1_1_line`, `bench_tline_txl2_3_line` |
| CPL | `device_coupled_tlines`, `bench_tline_cpl_ibm2`, `bench_tline_cpl3_4_line` |
| Ideal/LC companions | `device_tline`, `bench_tline_terminated`, `bench_tline_ideal_tline`, `bench_tline_delay_line` |

These are sampled waveform comparisons with existing tolerances, commonly rtol 0.003 and voltage atol 2e-6; they are not bitwise tests or proof of complete AMS conformance. Commands are `zig build test -- --filter tran/bench_tline_`, `zig build test -- --filter tran/device_lossy_tline`, and `zig build test -- --filter tran/device_coupled_tlines`. The runner also accepts `--jobs` and `--timeout`. `ESPICE_SOLVER=jfnk` repeats a comparison through the other nonlinear solve path.

Existing direct native tests cover LTRA matched RLC/DC settling; TXL characteristic admittance, ngspice setup constants and matched transient/DC settling; CPL setup coefficients. The CPL constant extraction referenced a temporary ngspice-44.2 C program, which is not versioned here. Persist its source/build recipe before claiming a reproducible independent setup oracle. The restoration adds `zig build test-native-lines` for these tests.

## Missing gates before retiring the native models

1. Compare native and emitted-model residuals, Jacobians, derived coefficients, pending state and committed state on the same prescribed accepted-time grid. Isolate model arithmetic from solver-grid differences, then compare complete simulator waveforms against unchanged ngspice fixtures.
2. Exercise nonzero initial/DC bias, UIC, analysis restart, t=0 seeding, repeated same-time evaluations, finite-difference probes, failed Newton iterations, LTE rejection and retries at the same endpoint with changed dt. Confirm exactly one history commit per accepted point and no accepted-history mutation on rejection.
3. Cover LC/RLC/RC/RG separately; TXL lossless shortcut, complex poles, fit failures and high-R/L three-pi case; CPL asymmetric matrices, off-diagonal R/G, dimensions 2/3/4, rejection beyond supported dimensions and nonground reference-node policy.
4. Cover t before/at/after delay; nonuniform knots; quadratic overshoot; nosteplimit and steps longer than delay; times just either side of integer-ps boundaries; dynamic timer cancellation, breakpoint-ring overflow and tolerance overrides.
5. Cross capacity boundaries 8192 (LTRA) and 2048 (TXL/CPL). The retained native code currently discards samples when no safe retention path remains. Require lossless storage growth or an explicit diagnostic before calling the result exact across arbitrary run lengths. Do not silently port that limitation as a language requirement.
6. Compare multiple independent instances, parameter re-preparation, cold/repeated analyses and parallel evaluation. Preserve independent instance histories and CPU fallback for stateful devices.
7. Add frequency-domain line oracles from analytic telegrapher equations and ngspice AC. Current native non-transient/DC stamps are insufficient as an AC oracle. Add KCL/branch checks independently of waveform matches.
8. Keep compatibility tests and standard conformance tests distinct. A restored native kernel or a registered user analog function may preserve ngspice behavior without constituting a pure-source rewrite. Retire native registration only after the declared replacement scope and all relevant gates pass.

## Validation record

Implementation and verification are in an isolated source snapshot at `/tmp/vera-ams-wave1/native-restore`, compared with `/tmp/vera-ams-wave1/native-restore-baseline`. Build/test outcomes will be appended after execution; fixture inventory above is not a claim that every fixture currently passes.

Construction validation does not yet guard every later runtime parameter mutation. Sweep recomputation invokes native `precompute` again through `recomputePrecomputed`; a newly invalid fit can still reach the native DC fallback or nonfinite coefficients. Add a failure-propagating model-validation contract and sweep regressions before claiming arbitrary parameter-mutation safety. CPU ABI 10 separately repairs error transport and topology checks; it does not add this numerical validation.

### Integration corrections found during restoration

CPL matrix parsing passed the named first coefficient through scalar-expression parsing. A following negative coefficient became subtraction, reducing the packed matrix length (the four-line oracle's C list had nine entries instead of ten). The patch restricts CPL r/l/g/c first values to individual tokens; braces still support expressions, and scalar model values retain expression parsing. A focused syntax test covers both behaviors.

ngspice's raw format emits duplicate current column names for TXL ends and CPL conductors. The checked-in named JSON retains the final duplicate. The restored routes publish that final far-end branch under the existing card name; builder tests verify the row. An independent ngspice-44.2 run of `device_coupled_tlines.sp` matched the JSON `i(p1)` to the fourth raw current column within 5.2e-17, whereas the other duplicate columns differed by about 0.003–0.01 A. No expected values or tolerances changed.

The RG direct route retains the fully bound Model (including instance `length=`) and calls the same `deriveModel` binding step as the generic route. Parameter-dependent boolean localparam recomputation is independently being corrected in VerA; RG initialization remains part of that final integration gate.

### AC probe

No checked-in fixture explicitly combines an LTRA/TXL/CPL model card with AC analysis. A separate LTRA deck at 1, 10 and 100 MHz produced byte-identical raw output from the captured generated-route executable and the restored native executable: `v(b)=0.49504950495049505+j0` at all three points. ngspice-44.2 produced approximately `0.49407254-j0.03108544`, `0.40049541-j0.29098868`, and `0.49502493-j0.000003939`. Both host routes are incomplete for this AC case; equality between them is not AC correctness. Deck and raw files are under `/tmp/vera-ams-wave1/native-ac/`.

### Verification checkpoints

Native unit target: 6/6 passed. One completed builder/device/native checkpoint: 17/17 passed, including native selection, rejected cases, commit-state/CPU-only hooks and RG length binding. The initial scoped full test ran 289/291 unit cases; its two allocation-failure tests hit the separately identified CPU callback error-ordinal bug, being fixed independently.

Before CPL parsing and current probes were repaired, the unchanged nine `tran/bench_tline_` oracles passed 3/9 under native restoration versus 2/9 under the captured generated-route executable. Native `ltra2_2_line` passed; `ltra1_1_line` still differed in a small output tail (sample144: expected 0.0027506850, got0.0035507718). Ideal `delay_line` failed identically on both executables (sample95: expected 0.14997750, got0.19997000). These are open numerical comparisons, not grounds to relax an oracle. Final parser/probe reruns follow below.

### Final restoration verification

`zig build -Dgpu=false -j4` succeeded. This is the existing CPU iteration build option; the integrated shipping/default GPU build is a separate parent check. `zig build test-builder test-frontend test-devices test-native-lines -Dgpu=false -j4` passed 39/39 tests (builder8, frontend22, catalog3, native6).

With the final parser and named-current fixes, unchanged numerical comparisons pass 6/11:

| Fixture | Final result |
|---|---|
| `bench_tline_ltra2_2_line` | Pass |
| `bench_tline_cpl3_4_line` | Pass |
| `bench_tline_ideal_tline` | Pass |
| `bench_tline_terminated` | Pass |
| `device_lossy_tline` | Pass |
| `device_coupled_tlines` | Pass |
| `bench_tline_ltra1_1_line` | Open: v(3), sample144, expected 0.002750685033439; actual 0.003550771763122 |
| `bench_tline_txl1_1_line` | Open: v(2), sample119, expected 0.07676896733476; actual 0.07647156406391 |
| `bench_tline_txl2_3_line` | Open: v(3), sample155, expected 1.718660974832; actual 1.727429689675 |
| `bench_tline_cpl_ibm2` | Open: v(v1), sample85, expected 0.012748357727967; actual 0.012699332535487 |
| `bench_tline_delay_line` | Existing independent ideal-line failure, identical captured-baseline/restored output: v(a), sample95, expected 0.14997750168741; actual 0.19997000224986 |

Logs: `/tmp/vera-ams-wave1/native-final-tline.log`, `native-final-ltra-device.log`, `native-final-cpl-device.log`, `native-final-unit-summary.log`, and `native-final-build.log`. The retained native algorithms improve supported routing and restore absent numerical behavior; these results do not certify every restored end-to-end waveform as ngspice-equivalent.

### LTRA1 prescribed-grid isolation

An independent ngspice-44.2 run of the unchanged LTRA1 deck emitted 498 accepted samples including both internal line currents. Replaying exactly those timepoints, voltages and currents through `ltra_native.precompute`, `eval` and accepted `updateState` gives a maximum branch residual of 4.3021142204224816e-16 A (equivalent 6.163275120867155e-14 V). At the failing oracle tail time 3.29430723438508e-8 s, the far-end residual is−8.327011497867576e-17 A (equivalent−1.19294049777558e-14 V). The unchanged native convolution arithmetic therefore agrees with ngspice on this prescribed history to floating-point precision.

The complete host trajectory still differs. Both runs accepted 498 points, but near the failing sample the host bracket starts at 3.2942522651910284e-8 s, while ngspice starts at 3.29430723438508e-8 s: a roughly 0.55 ps shift. This establishes that differing accepted-history inputs, solver/integration trajectory or scheduling must be investigated; it does not prove that this single time offset alone causes the entire voltage error. Next isolate driver/charge integration and force identical accepted times in the full solver while retaining native residual/Jacobian stamping.

Replay artifacts: `/tmp/vera-ams-wave1/ltra1-grid.zig`, `ltra1-grid.bin`, `ltra1-ng.raw`, `ltra1-native.raw`. Reproduce with `zig test -OReleaseFast -lc --dep ltra -Mroot=/tmp/vera-ams-wave1/ltra1-grid.zig --dep contract -Mltra=models/native/ltra_native.zig -Mcontract=../VerA/tools/contract.zig` from ARPice. This replay is now preserved by the permanent native regression described below; the scratch files retain the original diagnostic output.

### Permanent regression and final domain checks

The permanent test `LTRA residual on the ngspice LTRA1 accepted grid` is appended to `models/native/ltra_native.zig` and is included automatically by `test-native-lines`. It reuses the existing test scalar and native functions. `models/native/testdata/ltra1_ngspice_44_2.bin` contains the 498 five-value rows; its JSON sidecar records source/data SHA256, ngspice command, column mapping, model parameters and data format. `models/native/testdata/README.md` includes the extraction/check recipe. The test applies the native branch-current absolute tolerance of 1e-12 A, independent of existing waveform tolerances. The native target now passes 7/7. A fresh second ngspice-44.2 run reproduced all selected bytes and the data SHA256 exactly.

The restored matched LTRA device fixture also passes through `ESPICE_SOLVER=jfnk`. Both single-device fixtures fail under the captured generated-route baseline (LTRA waveform mismatch, CPL missing current), giving an aggregate improvement from 2/11 to 6/11 across the listed waveforms. Full numerical closure remains open.

Additional construction review found that finite R*length/G*length does not protect the RG VA intermediates. The integrated builder now rejects product/hyperbolic overflow (`r=g=1e200,len=1`; `r=g=1,len=1000`) and positive product underflow (`r=g=1e-200,len=1e200`, where the implemented raw R*G becomes zero despite unit scaled totals). These are domain rejections, not alternate numerical approximations. The parent also added a separate analytic RG operating-point fixture with instance length=2; its final result depends on the independent parameter-derive fix and integrated validation.

Independent TXL audit additionally reproduced a finite successful fit with infinite DC total resistance (`r=l=1e200,c=1e-100,g=0,len=1e150`), and a successful fit whose characteristic admittance underflows to zero (`r=1,l=1e200,c=1e-200,g=0,len=1`). The integrated builder now rejects nonfinite/nonpositive R*length and nonpositive fitted characteristic admittance, with both counterexamples covered by rejection tests. Runtime parameter-sweep validation remains separately open.
