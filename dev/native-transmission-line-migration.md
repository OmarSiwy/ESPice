# Native transmission lines and their Verilog-A replacements

The O, Y and P cards run on Verilog-A transcriptions of ngspice's LTRA, TXL
and CPL: `models/ltra.va`, `models/txl.va` and `models/coupled_ltra.va` (with
`coupled_ltra3.va` and `coupled_ltra4.va`, which include it at 3 and 4
conductors). They replaced native Zig devices (`ltra_native.zig`,
`txl_native.zig`, `coupled_ltra.zig`), which were deleted together with
`models/native/` and the `test-native-lines` step once each `.va` matched its
native device on the line decks (below). What VerA needed for that is in
[vera-gaps.md](vera-gaps.md).

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
| O (`addLossyLine`) | RLC (r, l, c > 0, g = 0) and RC (r, c > 0, l = g = 0) | `ltra.va` (recursive convolution with history, coefficients, chop and step limit), as ngspice LTRAsetup routes them |
| O | LC (r = g = 0) | one exact Bergeron line, `tline.va` |
| O | static RG (r, g > 0, l = c = 0) | the exact two-port branch of `lossy_tline.va` |
| O | anything else | refused (`UnsupportedTransmissionLineParameters`) |
| Y (`addTxl`) | r, l, c > 0 and r/l <= 1.6e10 | `txl.va` (Padé fit and history) |
| Y | r/l > 1.6e10 (ngspice expands this into three-pi sections) | refused |
| P (`addCpl`) | 2, 3 or 4 conductors | `coupled_ltra.va`, `coupled_ltra3.va`, `coupled_ltra4.va` |
| P | other conductor counts | refused (`UnsupportedCoupledLineDimension`) |

Construction also refuses a line whose classification would change through
underflow in the scaled totals, non-finite or non-positive R*length, and RG
product or hyperbolic overflow and underflow (for example `r=g=1e200,len=1`,
`r=g=1,len=1000`, `r=g=1e-200,len=1e200`). These are domain rejections, not
alternative approximations.

A TXL or CPL card whose Padé or modal fit fails, or yields a non-positive
delay or admittance or a non-finite coefficient, passes construction and
`$fatal`s in the model's `analog initial`. VerA's status channel latches it,
and the query fails with `error.DeviceRefused` after logging
`<card>: <file>:<line>: fatal: <message>`. Divergence: the native devices
refused these at construction, because the builder could call their fit; the
builder cannot run a Verilog-A model's setup, so the refusal comes at the
first evaluation, on every analysis (`.op`, `.tran` with and without `uic`,
`.ac`, `.noise`: "a failed line fit refuses every analysis" in
`src/tests/analyses.zig`).

The lines hold their history as §5.10 held state: `updateState` stages it per
converged solve and `stateCtl` commits or reverts it with the accepted point.
The static solve a transient starts from seeds it (`analysis("tran")` is true
there, §4.6.1); under `uic` the first accepted point does.

## LTRA on Verilog-A

`models/ltra.va` replaced `ltra_native.zig`. Diffed against the native device
(`espice -r out.csv --format=csv`, native binary at 4cee2ba5), largest
difference relative to the column's peak:

| Deck | Points (VA, native) | Largest relative difference |
|---|---|---|
| `tran/bench_tline_ltra1_1_line` | 498, 498 | 8.9e-13 (v(3)) |
| `tran/bench_tline_ltra2_2_line` | 510, 510 | 6.5e-7 (i(vs)), 2.3e-8 on voltages |
| `tran/device_lossy_tline` | 632, 632 | 3.5e-15 |

The ltra2 difference starts at the sixth point as a 1e-21 A change in i(vs)
and stays at round-off level. Every deck passes its ngspice fixture as the
native device did. `op/device_lossy_tline_rg` is the RG branch of
`lossy_tline.va` and did not change.

What the port changed:

- The history is seeded in the static solve the transient starts from.
  `analysis("tran")` is true there (§4.6.1, VerA maps it to the ic kind), and
  the host runs `updateState` on that solve. An `@(initial_step)` reset ran
  on the first time step instead (the host flags `initial_step` there), so
  the first step took the DC rows and every later point lagged one step.
  Under `uic` there is no static solve: the first accepted point seeds the
  history, where the native device seeded from the t = 0 commit.
- The convolution rebuild is a `(* vera_timepoint *)` statement, the native
  `cache_t`.
- erfc is an analog function in the file (VerA's `tests/fixtures/erfc.vh`,
  within 1.9e-13 relative of libm on [-6, 6]), so the RC kernels are not
  bit-equal to the native libm calls. No fixture runs an RC line.
- Breakpoints are per instance. The native ring of 8 was per model, shared by
  every instance of the card.
- The native prescribed-grid replay test (`testdata/ltra1_ngspice_44_2.bin`,
  498 ngspice 44.2 points, largest residual 4.3e-16 A) went with
  `ltra_native.zig`. The full-run match above against that device replaces it.

## TXL and CPL on Verilog-A

Diffed against the native devices the same way:

| Deck | Points (VA, native) | Largest relative difference |
|---|---|---|
| `tran/bench_tline_txl1_1_line` | 493, 493 | 1.4e-13 (i(vs)) |
| `tran/bench_tline_txl2_3_line` | 497, 497 | 1.1e-12 (i(y2)) |
| `tran/bench_tline_cpl3_4_line` | 1018, 1018 | 5.8e-8 (i(p1)), 4.6e-10 elsewhere |
| `tran/bench_tline_cpl_ibm2` | 217, 217 | 2.5e-11 |
| `tran/device_coupled_tlines` | 632, 632 | 1.1e-11 |

TXL needed the host's step. ngspice labels each accepted history point at the
next load as trunc((t_next - dt_next)*1e12), and the native devices copied
that. With `$abstime` alone the label is floor(t_acc*1e12), 1 ps lower
whenever t_acc*1e12 lands an ulp below an integer (t_acc =
9.279999999999999e-10 gives 927, (1.028e-9 - 1e-10)*1e12 gives 928), which
failed txl1 at 1.044 of tolerance and txl2_3 at 1.055. txl.va and
coupled_ltra.va now stage the accepted point and commit it in the next
timepoint's `vera_timepoint` block, labelled from `$simparam("dt")`, the
host's step (VerA 558c520c).

**Divergence: CPL's gmin port stamp.** cplload adds 0.1*gmin*(v1 + v2) to
both port rows of every conductor, as txlload does. txl.va models it;
coupled_ltra.va does not, because a per-conductor flow contribution next to
the conductor's potential branch needs one named branch per vector element,
which a width set by `CPL_N` cannot declare. The effect is that current: on
cpl3_4 the largest difference, 1.375e-14 A on i(p1) at 16.675 ns, equals
0.1 * 1e-12 * (v(5) + v(9)) = 1.376e-14 A at that point, 5.8e-8 of the
column's peak. Every CPL fixture passes with it.

## Cost

Median wall time of 7 runs, `zig build -Dgpu=false` ReleaseFast, on a loaded
machine; the native column is the last native build (4cee2ba5), measured in
the same session:

| Deck | Native | Verilog-A |
|---|---|---|
| `bench_tline_ltra1_1_line` | 18.7 ms | 16.0 ms |
| `bench_tline_ltra2_2_line` | 26.1 ms | 22.3 ms |
| `device_lossy_tline` | 16.9 ms | 13.0 ms |
| `bench_tline_txl1_1_line` | 8.2 ms | 16.4 ms |
| `bench_tline_txl2_3_line` | 9.9 ms | 29.4 ms |
| `bench_tline_cpl3_4_line` | 15.5 ms | 68.8 ms |
| `bench_tline_cpl_ibm2` | 6.8 ms | 13.7 ms |
| `device_coupled_tlines` | 7.9 ms | 28.4 ms |

LTRA is at parity since VerA stores held arrays in place. TXL and CPL cost 2
to 4.4 times the native time; their per-timepoint rebuild and the held-state
traffic of the 2048-point histories are what remain. Before the host stopped
rerunning `analog initial` on every evaluation (vera-gaps item 6) CPL was far
slower: cpl3_4 took 449 ms, the modal fit rerunning on every Newton iterate.

## Standard boundary

Primary authority: [Accellera VAMS-2023 LRM](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf). Clause references below use that edition.

The standard supplies declared arrays, loops and analog functions (§§3.2, 4.7, 5.9), ordinary mathematical functions (§4.3), linear-interpolated delay (§4.5.7), rational Laplace filters (§4.5.11), dynamic timer scheduling (§5.10.3.3), and a maximum-next-step request (§9.17.2). It does not specify ngspice's particular convolution formulas, Padé coefficients, history compaction, integer-picosecond rounding, or accepted timestep sequence. Bessel-I and erfc are not listed standard mathematical builtins. VPI includes accepted-point/convergence callbacks (§12.31.3) and registered analog functions/tasks (§12.32). There is no standard source event named `accepted_step`. A maximum step request does not prescribe an integrator or guarantee identical sample times. Standard compliance and ngspice numerical compatibility are separate gates.

Consequently, do not add a supposed standard `$ltra`, `$convolve`, `$erfc`, or `@(accepted_step)` merely to translate native code. A user-registered function is a different, explicit interface. Do not change `absdelay` to quadratic interpolation for LTRA compatibility. Fixed-size numerical matrix algorithms are expressible in source; lack of a working lowering or simulator callback is not proof that matrix arithmetic itself is outside AMS.

## Native behavior an exact port must reproduce

Clause references name relevant standard facilities; the implementation tasks
are conclusions from a source audit.

| Native behavior and source | Existing source-level building blocks | Required simulator/compiler work | Separate compatibility requirement |
|---|---|---|---|
| LTRA `precompute`, `bessI0e`, `bessI1e`, `bessI1xOverXe`, `rlcH2Func`, `rlcH1dashTwiceIntFunc`, `rcH1*`, `rcH2*`, `rcH3*` in the retired `ltra_native.zig` (now `models/ltra.va`) | Scalar arithmetic, conditionals, user analog functions; §4.3 math | Audit array/function lowering and generated f64 operation order; RC calls libc `erfc`, which requires a deliberate user-function or equivalent numerical implementation path | Reproduce the actual scaled polynomial coefficients and branching; erfc/library/platform parity needs an oracle. A different approximation is not interchangeable. |
| LTRA `intlinfunc`, `twiceintlinfunc`, `rebuildWave`, `rebuildRc` | Loops and indexed real arrays (§§3.2, 5.9); branch contributions | Runtime-sized history ownership and accepted-step snapshots; safe dynamic array indexing; preserve affine residual/Jacobian dependence while treating accepted history as constants | Fused O(history) sums, initial-value corrections, kernel chopping, auxiliary-index h2 interval mismatch and summation order all affect native results. No generic filter automatically reproduces them. |
| LTRA `interpDelayed`, `quadInterp` | Custom array search/interpolation functions | Access to committed history at arbitrary delayed times | First interval is linear, subsequent intervals quadratic; overshoot is not suppressed. `absdelay` is a distinct operator, not a numerical substitute (§4.5.7). |
| LTRA `pushHistory`, `updateState`, `compact` | Source variables can store values; this alone does not identify accepted solver points | Standard VPI accepted-point callback delivery and instance lifetime (§12.31.3), or an explicitly host-managed model interface until VPI exists; commit once, never on rejected trials | Five SoA histories, initial voltage/current seeding, same-time replacement, straight-line compaction and CAP=8192 policy. Current forced discard on overflow is a remaining native limitation. |
| LTRA `nextBreakpoint`, `updateState`, `precompute` max-safe-step bisection | `$bound_step` (§9.17.2), timer (§5.10.3.3) | Dynamic timer requests must reach the transient scheduler; standard callback request/cancellation and convergence semantics remain incomplete | Arrival breaks use a derivative test and an eight-entry ring. Hardcoded circuit tolerances and duplicated h2 straight-line test are compatibility details. Do not inject generic delay-echo breaks: that changes the accepted grid. |
| TXL `fitLine`, `getC`, `findRoots`, `root3`, `gauss3` in the retired `txl_native.zig` (now `models/txl.va`) | Scalar functions, fixed arrays and small matrix elimination | Correct array/function lowering, setup-time evaluation, deterministic coefficient transport | Hough/SWEC [3/3] Padé is already the TXL reference algorithm, not an AMS mandated transfer function. Its lossless shortcut, fit failure behavior, and high-R/L three-pi routing need dedicated cases. |
| TXL `rebuildLine`, `seedLine`, `commitLine`, `getPvs` | Complex arithmetic can be written as pairs of reals; loops/functions | Accepted/trial separation, delayed samples, callback and rollback delivery | Three h1/h2 and six h3 terms; complex h3 DC seed uses the native real-division quirk. Preserve operation and attenuation order. Generic `laplace_*` integration does not promise this recurrence. |
| TXL `updateState`, `eval` | `$abstime`, local values and conditional math | Publish current trial t/dt, commit only accepted points, invalidate trial caches on retry | History timestamps truncate to integer ps; recursive updates also use actual dt seconds. Sub-ps acceptances do not append. CAP=2048 front pruning can discard a still-live point. Bound is 0.9 delay; no generic wavefront breakpoints. |
| CPL `Setup.diagz`, `loopZY`, `evalSi`, `gauss2`, `approxMode`, `multP`; `matchFit`, `padeApx`; `CoupledLtra(N).precompute` in the retired `coupled_ltra.zig` (now `models/coupled_ltra.va`) | Fixed multidimensional arrays, functions and loops | Multiple runtime array indices and full function-array argument semantics need conformance coverage; constant dimension elaboration must preserve N | Eight reciprocal-frequency samples; Jacobi ordering with truncated comparisons, degree-seven fit, per-entry three-pole Padé, R-entry floor 1e-4, scaled poles. Two-conductor even/odd algebra cannot replace arbitrary supported matrices. |
| CPL `rebuild`, `getPvs`, `seedTms`, `updateState`, `eval` | Same ordinary source facilities as TXL | Per-instance accepted-history lifetime, trial-cache isolation, callback scheduling and branch/Jacobian integration | Mode/conductor delayed interpolation, complex convolution initialization, cumulative coefficient scaling across real poles, integer ps, CAP=2048, bound 0.9 minimum delay. Native N is limited to 2/3/4; ngspice's larger dimension range is a separate task. |

VerA's `docs/CONFORMANCE.md` tracks incomplete VPI, accepted-point callbacks, multidimensional dynamic indexing, delay history capacity and simulator scheduling. The narrow `SystfHost` bridge is not full chapter-12 VPI. First-call `$table_model` snapshots are not a mutable accepted-history queue. Digital simulation, connect modules and mixed-signal scheduling are needed for full AMS conformance, but pure analog transmission lines should not depend on unrelated digital features.

## What the approximate `.va` lines omit

- `models/lossy_tline.va`: RLC uses an ideal delayed line with half the total series resistance at each end; the h1'/h2/h3' kernels are absent. RC reduces to its DC resistance and omits erfc dispersion. Its step cap is 0.25 delay. LC and static RG are distinct branches and are judged separately; only static RG is routed to it.
- `models/coupled_tlines.va`: only two symmetric conductors using even/odd closed forms, with no general modal fit or recursive convolution. It clamps mutual coupling, changes reference-node behavior, and handles mutual-resistance DC differently. No card routes to it.
- No Verilog-A model in `models/` implements the TXL Padé method or the CPL modal fit.

## Evidence

ngspice 44.2 fixtures under `tests/fixtures/tran/` (current pass/fail status
is what `zig build test` reports):

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

**Native unit tests (retired).** `zig build test-native-lines` ran direct
tests of the native devices: TXL characteristic admittance, the ngspice
txlsetup constants and matched transient/DC settling, and CPL setup against
the ngspice cplsetup pipeline (constants from a temporary ngspice 44.2 C
program that was never versioned). They tested Zig functions that no longer
exist and went with them; the full-run parity above against those devices,
and the ngspice fixtures, replace them.

**LTRA1 prescribed-grid replay (retired).** A native test replayed 498
accepted ngspice 44.2 timepoints of the LTRA1 deck through the native
device and found a largest branch residual of 4.3e-16 A. Both runs accepted
498 points, but the full waveform differed near 3.29e-8 s, where the host's
bracket started about 0.55 ps before ngspice's. The test and its data went
with `ltra_native.zig`; `ltra.va` matches that device on the full run.

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
- TXL and CPL ignore the card's reference nodes, as ngspice's construction
  does: the builder ties those ports of `txl.va` and `coupled_ltra.va` to
  ground, and the models leave them unused. The approximate coupled `.va`
  honors them.

## Known limitations

- A sweep that makes a TXL or CPL fit invalid reruns `analog initial`, which
  `$fatal`s, so the run is refused rather than reaching non-finite
  coefficients; no sweep regression covers it yet.
- The non-transient paths stamp DC, as the native devices did. No fixture combines a line with
  `.ac`. On an LTRA deck at 1, 10 and 100 MHz, both the native route and the
  old generated route gave `v(b) = 0.49504950495049505` at every point, while
  ngspice 44.2 gave about 0.49407254-j0.03108544, 0.40049541-j0.29098868 and
  0.49502493-j0.000003939. Native AC is not an oracle.
- History capacity is fixed: 8192 points for LTRA (`ltra.va` keeps it), 2048
  for TXL and CPL. Past it, the code discards samples when no safe retention
  path remains.

## Gates still open for the Verilog-A lines

LTRA, TXL and CPL were retired on the owner's line-deck parity gate (each
`.va` matches its native device on every line deck, as measured above). Gates
2 to 8 below were not run and stay open as coverage work for the `.va` lines.

1. Compare native and emitted-model residuals, Jacobians, derived coefficients, pending state and committed state on the same prescribed accepted-time grid. Isolate model arithmetic from solver-grid differences, then compare complete simulator waveforms against unchanged ngspice fixtures.
2. Exercise nonzero initial/DC bias, UIC, analysis restart, t=0 seeding, repeated same-time evaluations, finite-difference probes, failed Newton iterations, LTE rejection and retries at the same endpoint with changed dt. Confirm exactly one history commit per accepted point and no accepted-history mutation on rejection.
3. Cover LC/RLC/RC/RG separately; the TXL lossless shortcut, complex poles, fit failures and high-R/L three-pi case; CPL asymmetric matrices, off-diagonal R/G, dimensions 2/3/4, rejection beyond supported dimensions and the nonground reference-node policy.
4. Cover t before, at and after the delay; nonuniform knots; quadratic overshoot; nosteplimit and steps longer than the delay; times just either side of integer-ps boundaries; dynamic timer cancellation, breakpoint-ring overflow and tolerance overrides.
5. Cross the capacity boundaries 8192 (LTRA) and 2048 (TXL/CPL). Require lossless storage growth or an explicit diagnostic before calling the result exact across arbitrary run lengths. Do not port the native discard as a language requirement.
6. Compare multiple independent instances, parameter re-preparation, cold and repeated analyses and parallel evaluation. Preserve independent instance histories and the CPU fallback for stateful devices.
7. Add frequency-domain line oracles from the analytic telegrapher equations and ngspice AC, plus KCL/branch checks independent of waveform matches.
8. Keep compatibility tests and standard conformance tests distinct. A native kernel or a registered user analog function may preserve ngspice behavior without being a pure-source rewrite. Retire a native registration only after the declared replacement scope and all relevant gates pass.
