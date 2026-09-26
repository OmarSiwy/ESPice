# Native transmission lines and their Verilog-A replacements

ESPice runs the lossy (LTRA), TXL and coupled (CPL) transmission lines on
native Zig devices in `models/native/` (`ltra_native.zig`, `txl_native.zig`,
`coupled_ltra.zig`). They are built through the same neutral evaluator
(`src/device/eval.zig`) as the generated models, into one CPU object
(`dev_native_lines` in build.zig), and they stay the production devices until
a Verilog-A replacement passes the gates below. The Verilog-A ports
(`models/native/{ltra,txl,coupled_ltra}.va`) are not built; what blocks them
in VerA is in [vera-gaps.md](vera-gaps.md).

Policy: no approximate substitution. An earlier checkpoint routed O/Y cards to
`models/lossy_tline.va` and P cards to `models/coupled_tlines.va`, whose
headers disclose dropped convolution kernels and a two-conductor modal
approximation. That routing was a regression, not a migration, and the native
routes were restored. A card the native devices cannot run exactly is
refused, never sent to an approximation.

## Routing

In `src/frontend/builder.zig`:

| Card | Case | Device |
|---|---|---|
| O (`addLossyLine`) | RLC (r, l, c > 0, g = 0) and RC (r, c > 0, l = g = 0) | `ltra_native` (recursive convolution with history, coefficients, chop and step limit), as ngspice LTRAsetup routes them |
| O | LC (r = g = 0) | one exact Bergeron line, `tline.va` |
| O | static RG (r, g > 0, l = c = 0) | the exact two-port branch of `lossy_tline.va` |
| O | anything else | refused (`UnsupportedTransmissionLineParameters`) |
| Y (`addTxl`) | r, l, c > 0 and r/l <= 1.6e10 | `txl_native` (Padé fit and history) |
| Y | r/l > 1.6e10 (ngspice expands this into three-pi sections) | refused |
| P (`addCpl`) | 2, 3 or 4 conductors | `cpl_native_2/3/4` (`CoupledLtra(N)`) |
| P | other conductor counts | refused (`UnsupportedCoupledLineDimension`) |

Construction also refuses a line whose classification would change through
underflow in the scaled totals, a failed or non-finite TXL or CPL fit,
non-finite or non-positive R*length, a non-positive fitted characteristic
admittance, and RG product or hyperbolic overflow and underflow (for example
`r=g=1e200,len=1`, `r=g=1,len=1000`, `r=g=1e-200,len=1e200`). These are
domain rejections, not alternative approximations.

The native devices declare `unrevertible_state`, so `eval.zig` exposes their
`updateState` as the `commit_state` hook: the transient seeds them at t = 0
and commits once per accepted point, and a rejected trial touches only their
pending fields. A device with `State` and no `limit` is CPU-only under
`gpuEligible`.

## Standard boundary

Primary authority: [Accellera VAMS-2023 LRM](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf). Clause references below use that edition.

The standard supplies declared arrays, loops and analog functions (§§3.2, 4.7, 5.9), ordinary mathematical functions (§4.3), linear-interpolated delay (§4.5.7), rational Laplace filters (§4.5.11), dynamic timer scheduling (§5.10.3.3), and a maximum-next-step request (§9.17.2). It does not specify ngspice's particular convolution formulas, Padé coefficients, history compaction, integer-picosecond rounding, or accepted timestep sequence. Bessel-I and erfc are not listed standard mathematical builtins. VPI includes accepted-point/convergence callbacks (§12.31.3) and registered analog functions/tasks (§12.32). There is no standard source event named `accepted_step`. A maximum step request does not prescribe an integrator or guarantee identical sample times. Standard compliance and ngspice numerical compatibility are separate gates.

Consequently, do not add a supposed standard `$ltra`, `$convolve`, `$erfc`, or `@(accepted_step)` merely to translate native code. A user-registered function is a different, explicit interface. Do not change `absdelay` to quadratic interpolation for LTRA compatibility. Fixed-size numerical matrix algorithms are expressible in source; lack of a working lowering or simulator callback is not proof that matrix arithmetic itself is outside AMS.

## Native behavior an exact port must reproduce

Clause references name relevant standard facilities; the implementation tasks
are conclusions from a source audit.

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

VerA's `docs/CONFORMANCE.md` tracks incomplete VPI, accepted-point callbacks, multidimensional dynamic indexing, delay history capacity and simulator scheduling. The narrow `SystfHost` bridge is not full chapter-12 VPI. First-call `$table_model` snapshots are not a mutable accepted-history queue. Digital simulation, connect modules and mixed-signal scheduling are needed for full AMS conformance, but pure analog transmission lines should not depend on unrelated digital features.

## What the approximate `.va` lines omit

- `models/lossy_tline.va`: RLC uses an ideal delayed line with half the total series resistance at each end; the h1'/h2/h3' kernels are absent. RC reduces to its DC resistance and omits erfc dispersion. Its step cap is 0.25 delay. LC and static RG are distinct branches and are judged separately; only static RG is routed to it.
- `models/coupled_tlines.va`: only two symmetric conductors using even/odd closed forms, with no general modal fit or recursive convolution. It clamps mutual coupling, changes reference-node behavior, and handles mutual-resistance DC differently. No card routes to it.
- No Verilog-A model in `models/` implements the TXL Padé method or the CPL modal fit.

## Evidence

ngspice 44.2 fixtures under `tests/fixtures/tran/` (current pass/fail status
is in `issues.md`):

| Family | Fixture stems |
|---|---|
| LTRA | `device_lossy_tline`, `bench_tline_ltra1_1_line`, `bench_tline_ltra2_2_line` |
| TXL | `bench_tline_txl1_1_line`, `bench_tline_txl2_3_line` |
| CPL | `device_coupled_tlines`, `bench_tline_cpl_ibm2`, `bench_tline_cpl3_4_line` |
| Ideal/LC companions | `device_tline`, `bench_tline_terminated`, `bench_tline_ideal_tline`, `bench_tline_delay_line` |

These are sampled waveform comparisons with their own tolerances, commonly
rtol 0.003 and voltage atol 2e-6; they are not bitwise tests or proof of AMS
conformance. Run them with `zig build test -- --filter tran/bench_tline_`
(or `tran/device_lossy_tline`, `tran/device_coupled_tlines`).
`ESPICE_SOLVER=jfnk` repeats a comparison through the other nonlinear solve
path.

`zig build test-native-lines` runs the direct native tests: the LTRA matched
RLC line and DC settling; TXL characteristic admittance, the ngspice txlsetup
constants and matched transient/DC settling; CPL setup against the ngspice
cplsetup pipeline; and "LTRA residual on the ngspice LTRA1 accepted grid". The
CPL constants came from a temporary ngspice 44.2 C program that is not
versioned here; persist it before calling that setup oracle reproducible.

**LTRA1 prescribed-grid replay.** `models/native/testdata/ltra1_ngspice_44_2.bin`
holds the 498 accepted timepoints (time, both voltages, both currents) of an
ngspice 44.2 run of the unchanged LTRA1 deck. The JSON sidecar records
hashes, the command and the model parameters, and the directory's README has
the extraction recipe. Replaying that history through `precompute`, `eval`
and `updateState` gives a largest branch residual of 4.3e-16 A, against the
device's 1e-12 A current tolerance: the native convolution arithmetic agrees
with ngspice on a prescribed history to floating-point precision. The full
LTRA1 waveform still differs. Both runs accept 498 points, but near the
failing sample the host's bracket starts about 0.55 ps before ngspice's
(3.2942522651910284e-8 s against 3.29430723438508e-8 s). So the accepted grid
or the solver trajectory differs; the offset alone is not proven to explain
the voltage error. The next step is to force identical accepted times in the
full solver while keeping native stamping.

**Integration fixes found during the restoration.**

- CPL matrix values: a named first coefficient went through scalar-expression
  parsing, so a following negative coefficient became a subtraction and the
  packed matrix lost an entry. The first r/l/g/c values are now individual
  tokens (`cplVector`); braces still allow expressions.
- ngspice's raw format emits duplicate current column names for TXL ends and
  CPL conductors, and the fixture JSON keeps the last duplicate. The native
  routes publish that far-end branch under the card name. An independent
  ngspice 44.2 run of `device_coupled_tlines.sp` matched the JSON `i(p1)` to
  the fourth raw current column within 5.2e-17; the other duplicates differed
  by about 0.003 to 0.01 A.
- Native TXL and CPL ignore the card's reference nodes, as ngspice's
  construction does; the approximate coupled `.va` honors them.

## Known limitations of the native devices

- Construction validates a line once. Sweep recomputation calls native
  `precompute` again through `recomputePrecomputed`, and a newly invalid fit
  there can still reach the DC fallback or non-finite coefficients. A
  failure-propagating model-validation contract and sweep regressions are
  needed before claiming safety under arbitrary parameter changes.
- The native non-transient paths stamp DC. No fixture combines a line with
  `.ac`. On an LTRA deck at 1, 10 and 100 MHz, both the native route and the
  old generated route gave `v(b) = 0.49504950495049505` at every point, while
  ngspice 44.2 gave about 0.49407254-j0.03108544, 0.40049541-j0.29098868 and
  0.49502493-j0.000003939. Native AC is not an oracle.
- History capacity is fixed: 8192 points for LTRA, 2048 for TXL and CPL.
  Past it, the code discards samples when no safe retention path remains.

## Gates before retiring a native model

1. Compare native and emitted-model residuals, Jacobians, derived coefficients, pending state and committed state on the same prescribed accepted-time grid. Isolate model arithmetic from solver-grid differences, then compare complete simulator waveforms against unchanged ngspice fixtures.
2. Exercise nonzero initial/DC bias, UIC, analysis restart, t=0 seeding, repeated same-time evaluations, finite-difference probes, failed Newton iterations, LTE rejection and retries at the same endpoint with changed dt. Confirm exactly one history commit per accepted point and no accepted-history mutation on rejection.
3. Cover LC/RLC/RC/RG separately; the TXL lossless shortcut, complex poles, fit failures and high-R/L three-pi case; CPL asymmetric matrices, off-diagonal R/G, dimensions 2/3/4, rejection beyond supported dimensions and the nonground reference-node policy.
4. Cover t before, at and after the delay; nonuniform knots; quadratic overshoot; nosteplimit and steps longer than the delay; times just either side of integer-ps boundaries; dynamic timer cancellation, breakpoint-ring overflow and tolerance overrides.
5. Cross the capacity boundaries 8192 (LTRA) and 2048 (TXL/CPL). Require lossless storage growth or an explicit diagnostic before calling the result exact across arbitrary run lengths. Do not port the native discard as a language requirement.
6. Compare multiple independent instances, parameter re-preparation, cold and repeated analyses and parallel evaluation. Preserve independent instance histories and the CPU fallback for stateful devices.
7. Add frequency-domain line oracles from the analytic telegrapher equations and ngspice AC, plus KCL/branch checks independent of waveform matches.
8. Keep compatibility tests and standard conformance tests distinct. A native kernel or a registered user analog function may preserve ngspice behavior without being a pure-source rewrite. Retire a native registration only after the declared replacement scope and all relevant gates pass.

When a `.va` port passes: copy it into `models/`, route its card to it in
`builder.zig`, and diff the matching `bench_tline_*` decks (and
`stress/vacask_ring`) against the native device before deleting the `.zig`.
