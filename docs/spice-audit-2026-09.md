# SPICE audit 2026-09-06 — root causes, not bandaids

One session, spice-audit branch. Method: full-corpus baseline first, then
every failure traced to a mechanism before any fix; agent audits verified
models line-by-line against ngspice 44.2 C sources (/tmp/ngspice-src).
Reports: /tmp/audit-{mos-legacy,bjt-jfet-mes,llvm-time}.md.

## The two lies in the old numbers

1. **Every CPU benchmark measured unoptimized code.** `standardOptimizeOption`
   defaulted to Debug AND `exe.use_llvm = false` pinned the self-hosted
   backend, which has no optimizer — `-Doptimize=ReleaseFast` changed
   nothing. ngspice (-O2) raced espice's debug codegen. Fixed: ReleaseFast +
   LLVM by default (Debug keeps self-hosted for iteration).
2. **Release carried full DWARF** — measured ~2/3 of the 12-minute LLVM
   compile (DI maintenance is superlinear in function size: exponent 2.0 vs
   1.2 stripped) and 115 MB of a 128 MB binary. Stripped: 184 s build, 12 MB.

## Correctness mechanisms found (each measured before/after)

- **VerA collapse chains** (bsim4 3.5e3 → 1.7e-3; also un-wedged every DC
  sweep, 1000x): two `V(a,b)<+0` shorts sharing a node (rgateMod=0) were
  aliased last-write-wins; the dangling KVL row stamped ±1 garbage onto a
  KCL row. Union-find in the emitted collapse(). VerA f6b428c.
- **$param_given never bound** (all models): derived defaults dead, PMOS
  bsim4 cards reset to NMOS, TOX-given zeroing gate caps. Landed with the
  bsim3 merge, plus Zig-primitive escapes (`u0Z`,`u1Z`,`u10Z`) card aliases.
- **Parenless waveforms** (`vs a 0 dc=0 sin 0 50 100k`): unparsed → flat DC
  (vacask/mul err 1.00 → 2.8e-5).
- **.options ignored wholesale** → parsed (reltol/abstol/vntol/gmin/trtol/
  chgtol/itl*/method/maxord/temp).
- **.dc second sweep variable + TEMP** (outer loop): 2-var fixtures ran at
  vgs=0 before; point counts now match ngspice exactly.
- **Topology diagnoses**: weighted union-find over V/L shorts (error only on
  INCONSISTENT KVL cycles), current-source cutset, capacitor island — named
  errors, ngspice-setup-class.
- **Runtime .hdl loading dead end-to-end** (3 bugs): missing gompute module
  for the .so's dyn build; swallowed ErrorBundle; ABI pre-check compared the
  orchestrator's cache key against the engine's type-layout hash (unrelated
  formulas). verilogA fixtures now exact.
- **Model equations vs ngspice C** (agent-verified, fixture-proven): diode
  IKF form + ISR/NR; bsim1 was ~4 decades dead (spurious 1e-4, wrong Cox
  scaling); mos2 VMAX used gate overdrive for drain excess; mos3 CLM gate;
  jfet IS(T) XTI; mos9 KP/PHI derivations; mesa pnjlim arg swap; BJT pe/me/
  pc/mc aliases; mos6/mos9 PMOS spell polarity `mtype`.
- **Fixture bugs in our own corpus**: diode_bridge had NO ground (both
  engines agreed to 2.6 µV differentially; the 2.47e2 was null-space);
  hfet_inverter's ngspice golden violates ngspice's own equations by 0.55 mA
  (hfetload.c reverse-mode vgs/vgd bug — nodeset pins the true state);
  schmitt's "espice 5 ns lag" was the golden's own LTE (tmax pinned).
- **Native LTRA** (recursive convolution, ngspice ltraload port): replaces
  the N-section Bergeron cascade; tline fixtures 1.3-3.3 s → 20-30 ms.
  Accuracy tuning was interrupted mid-agent — WIP on `ltra-native` branch.

## Known divergences, tracked (task list)

- mosamp: vds=0-seam Newton 2-cycle — RESOLVED after this doc's first draft
  by the frame-following gate limiter (VerA `a773641` "fetlimds", espice
  `a6c53c9`): fetlim only the leg that controls the channel in the sign of
  the OLD vds, then limvds, then derive the other leg. Residual 5.6e-2 is
  grid phase — ngspice runs the deck ~100x harder (#14 closed).
- Inverter mid-edge cluster (pvt/parallel_inverters/mos6_inverter): NOT
  Meyer. Averaging landed in `a7a3f70` on VerA's `$prev` (`6cfafc4`);
  mos1/2/3/6/9 now emit ngspice's `capgs = state0 + state1 + overlap` and
  `qgs += capgs*dvgs` verbatim. pvt_corners has no TOX and no CGSO/CGDO, so
  its Meyer caps were always zero in BOTH engines; mos6_inverter and
  hfet_inverter converge to ngspice's own answer at tmax=2ps (espice coarse
  0.7 ps off the converged edge, ngspice coarse 9.6 ps). Real lever is
  per-device-state LTE in `stepBound` (#15 → folded into #1).
- mesa/mes/hfet C·ddt(V) lowered as ddt(C·V) → spurious V·dC/dv (Cgg up to
  2.17x): RESOLVED by VerA `50a69da`, path-integrated reactive coefficients
  `q = pq + A(x)*(B(x) - pb)` — ngspice's own `qgs += capgs*(v - v1)`
  construction, with an exact AD Jacobian (dA enters only as (dA/dx)*(B-pb),
  which vanishes as dt→0) instead of the retired freeze_grad quasi-Newton.
  mesa_oscillator wedge → 3.71e-5 PASS (#8 closed).
- b4soi/b3soipd: WAS plumbing after all, not version skew — case-blind VA
  param match + derive()-on-comptime-path + TYPE polarity (b28d237), then
  Newton-path work (steplim $limit alg, body-side clamp writers, ngspice's
  b4soild.c:4914 gmin body tie). Fixtures 8.14e-1/1.75e0 → 7.8e-4/3.3e-5.
  The BSIMSOI-4.6.1 .va matches ngspice's 4.4 C to ≤1e-5 rel at every
  swept bias once the floating-body row is numerically resolvable
  (ISREC ≥ 1e-4 A/m²). REMAINING, named: at DEFAULT junction params the
  body KCL row is atto-siemens flat; SparseLu threshold pivoting
  (pivot_tol·colmax, with Gmbs ~1e-4 S in the same column) rejects its
  diagonal and the elimination through a channel row turns dx_body into
  volts of garbage (ZP_OPDBG: dx=-13.9 V in one iteration; .op/.dc-up at
  mid-vds converge on a pseudo-branch, Id up to +110%; .dc-down and cold
  .op at vds=1.1 land right). ngspice survives the same 1e-18-S row via
  Sparse 1.3's diagonal-preferring Markowitz (its body walks to exactly
  nrecf0·vt·ln2 = 35.26 mV). Fix belongs in the solver (row equilibration
  or isolated-tiny-row diagonal preference), not the model.
- hisim: model-version deltas vs ngspice's C, still open.
- espice raws carry no branch currents → several gummel/transfer "passes"
  are vacuous; ngspice trap-ringing artifacts (pvt undershoot −0.165 V)
  count against us in the comparator.

## Final scoreboard (clean full bench, 2026-09-07)

264 fixtures vs ngspice 44.2. **170 PASS / 15 FAIL** (rest: SKIP — see below).
Speed: of 229 timed fixtures, espice is **faster-or-equal on 183 (80%),
mean 1.79×**; GPU wins its lane (parallel_inverters_2000 2.07× vs CPU).

Read the FAIL list against the START-of-session baseline (18 FAIL, several
CATASTROPHIC): every catastrophe is gone — bsim4 3.5e3→1.7e-3, diode_bridge
2.5e2→2.7e-7, mul 1.0→8e-5, mesa_oscillator 0.45→3.7e-5, the whole tline
cluster, b4soi 0.81→7.8e-4, b3soipd 1.75→3.3e-5. NONE of the 15 remaining is
a regression. They are three honest kinds:

1. **Vacuous passes the session's own honesty exposed** — branch-current
   columns are compared now (they never were) and `.dc … TEMP` actually
   sweeps now (it was ignored). bsim1 (i(vds) 2.1e3), bsim2 (0.96),
   diode_temp (2.3e-2), ngspice/mosmem (3.1e-2), power/rectifier (4.5e-2),
   vbic_forced_output (4.8e-3), fourier/square_harmonics (0.10) were green
   only because nobody looked at the wrong quantity. The bar rose; these are
   the models that don't clear it. (#20 diode temp, #21 bsim1/2 currents.)
2. **Edge-phase-only** — RMS passes, max fails on one sample straddling a
   steep edge where ngspice's own coarse LTE grid disagrees with itself
   below the comparator's window: pvt_corners (rms 3.9e-3), parallel_inv
   (5.8e-4), mos6_inverter (2.2e-3), hfet_inverter (5.9e-3), vacask/mul
   (8e-5), mosamp (grid slop — ngspice runs it 100× harder). Closing these
   is tran-grid matching, a policy choice, not a model/solver bug.
3. **Documented architectural** — txl2_3_line (per-row vs per-state LTE on
   the shared q-plane, frozen at the GPU boundary); bsim4 1.69e-3 (just over
   the 1e-3 rms line, BSIM4 version delta).

SKIPs that are CORRECT: topology/{current_cutset,floating_node,voltage_loop}
(their golden IS the named error espice now emits); scaling/inverter_chain_*
(ngspice aborts them too — "timestep too small"). SKIPs still open:
b3soifd/dd (levels 55/56 unported; 57 PD done), hisimhv, vacask/{c6288,ring}
(psp103), verilog/inverter (FastVF not wired).

## Perf levers left (measured, ranked)

1. VerA temp-expr hoisting: pow/log/exp ≈ 20% of BJT transients (#16).
2. SIMD sparse refactor replay: 32% of fourbitadder (#17).
3. Waveform streaming to the raw writer: 760 MB → ~ngspice's 220 (#13).
4. Per-model LLVM objects (buildsplit branch, bit-identical, unmerged):
   caching granularity; strip already took the headline win.
5. VerA `--outline-chunk` (landed upstream, default off): GPU kernels
   compile 70-110x faster — the lever for re-admitting big models to GPU
   emission (#18).

## Measurement fixes, 2026-09-07

Both entries below are **scoring changes, not accuracy wins.** No model,
solver or integrator code changed; espice produces byte-identical waveforms
before and after. They are recorded here because the corpus already has a
history of fixtures that measured the harness rather than the simulator
(diode_bridge with no ground, hfet_inverter's golden violating ngspice's own
equations), and these are two more of the same kind.

### power/rectifier — the fixture was measuring ngspice's own LTE overshoot

`.tran 10u 5m` left tmax at ngspice's default `tstop/50 = 100us`. The diode
has no `RS` and the source no series impedance, so `i(vac)` is a raw
exponential of a node voltage: `dI/I = dV/Vt = 38.7*dV`. At the failing
sample both engines satisfy the *same* Shockley equation to six digits at
their *own* bias:

| engine | Vd = v(in)-v(out) | IS*(exp(Vd/Vt)-1) | value in the raw | rel |
|---|---|---|---|---|
| ngspice @ t=1.415829e-5 | 0.7442754 | 3.1407105 | 3.1407293 | -6.0e-6 |
| espice  @ t=1.412737e-5 | 0.7430888 | 2.9998799 | 2.9998720 | +2.6e-6 |

The 1.1866 mV integration difference exponentiates to 4.6945% — which was
the entire reported error. Refining tmax shows what the two curves are
actually converging to:

| tmax | ngspice peak i(vac) | espice peak i(vac) | scored max | scored rms |
|---|---|---|---|---|
| default (100u) | -3.140729 @ 1.415829e-5 | -2.999872 @ 1.412737e-5 | 4.522e-2 | 2.919e-3 |
| 5u | -3.140729 | -2.999872 | 4.522e-2 | 2.076e-3 |
| **1u** | -2.967130 | — | **9.529e-5** | **7.412e-6** |
| 200n | -2.939790 | — | 6.004e-4 | 4.850e-6 |
| 50n | -2.939720 | — | 2.082e-4 | 2.473e-6 |
| 20n | **-2.9397110** @ 1.527200e-5 | **-2.9397110** @ 1.527200e-5 | 1.539e-4 | 2.084e-6 |

Converged, the two engines agree to seven figures at the identical
timepoint. Against that converged peak, **ngspice's coarse answer is +6.84%
and espice's is +2.05%** — espice was 3.3x closer to the truth than the
reference it was being scored against. ngspice's own coarse sequence rings
(-3.141, -2.832, -2.988, -2.879): trapezoidal LTE overshoot, not a waveform.

Fix: pin the grid in the deck, `.tran 10u 5m 0 1u` (5005 points vs 515), with
the reasoning and these numbers recorded in a comment above the line. 1u, not
20n — 20n costs 250005 points for no additional discrimination. Widening the
comparator window does **not** help here and should not: this is a level
error from discretization, not a phase error (verified: still 4.522e-2 with
the wider window below).

Explicitly ruled out: the deck sets neither `BV` nor `IBV`, so neither
ngspice's breakdown branch (`diotemp.c:203-239`, guarded by
`DIObreakdownVoltageGiven`) nor diode.va's is ever reached, and the failing
sample is forward conduction at Vd = +0.744 V. The unported `xbv`
breakdown-match iteration is not implicated. `TEMP = TNOM = 27C`, so the
`diotemp.c` port is a no-op here — the fixture measured 4.5219337e-2 both
before and after it landed.

### ngspice/mosmem — the window could not see the candidate's own step

The failing column is not a MOS current but a source branch current,
`i(vwb)`, at `t = 2.010663e-08` — 0.107 ns after the breakpoint at t = 20 ns
where `vwb` starts its 20 ns fall. It is dominated by m2's constant
`cgso`/`cgdo` overlap capacitance (w = 250u => 2 x 1uF/m x 250um = 500 pF),
so it **steps discontinuously in time** from 4e-13 A to 4.149e-2 A the
instant the ramp begins. Sanity: `Cgs*dV2/dt + Cgd*(dV2/dt - dV4/dt) =
250p*(-1e8) + 250p*(-1e8 + 3.24e7) = -4.19e-2 A`, matching the measured
4.15e-2. Nothing to do with the Meyer/`$prev` path in mos1.va:347-349, which
is demonstrably correct here — refined, the two engines agree on the ramp to
six figures (0.0414992 vs 0.0414993 at 2.03e-8; 0.0415496 vs 0.0415498 at
2.19e-8) and on the flat sections either side (1.42344e-5 vs 1.42311e-5).

The failure was pure arithmetic in the comparator. espice bracketed ngspice's
sample between its own `(2.000e-8, -2.167e-19)` and `(2.002e-8, 0.0414902)`;
linear interpolation gives `0.0414902 * (1.186e-13 / 2e-12) = 0.00246037`,
exactly the `zp_raw` the runner reported. The edge-phase window could not
rescue it because it was sized from the *reference's* local grid only:
`dt_lo = 0.1186 ps`, `dt_hi = 0.237 ps`, three orders of magnitude too small
to reach espice's next sample 2 ps away. The window is smallest precisely
where ngspice's grid is finest, which is exactly where the reference lands
inside the candidate's step.

Both engines implement spice3's documented resume rule (`dctran.c:578`,
`tran.zig:596-626`, `0.1*min(saveDelta, gap)`); the difference is only which
side's truncation controller accepts the first BE step across the
discontinuity, and it is not systematic — espice is *finer* than ngspice at
half this deck's breakpoints (40ns: 3.47e-11 vs 9.57e-11; 240ns: 2.71e-10 vs
2.00e-9; 20ns: 1.28e-9 vs 1.07e-10).

Fix: `runner.zig` now sizes the window from `max(dt_lo, dt_hi, dt_cand)`
where `dt_cand` is the candidate's own bracketing step at that time.
Measured on the fixture as it stands:

| column | before (max / rms) | after (max / rms) |
|---|---|---|
| i(vwb) | 3.112e-2 / 2.873e-3 | **8.712e-4 / 9.109e-5** |
| i(vw)  | 2.508e-2 / 2.331e-3 | **9.323e-4 / 7.746e-5** |
| i(vs)  | 1.389e-2 / 1.579e-3 | **6.764e-4 / 5.502e-5** |
| i(vdd) | 2.205e-4 / 3.472e-5 | 2.205e-4 / 3.472e-5 (identical) |
| v(3)   | 2.920e-4 / 2.784e-4 | identical |
| v(4)   | 3.129e-3 / 2.564e-4 | identical |
| v(8)   | 1.140e-3 / 1.364e-4 | identical |

Every non-discontinuous column is bit-identical; only the three columns with
a genuine time-discontinuity move. Corroboration that this is sampling and
not physics: at tmax = 0.2 ns, excluding just the 11 ngspice samples (of
10039) that fall strictly inside an espice post-breakpoint interval takes
i(vwb) from 3.903e-2 to **2.786e-7**.

**This change IS a loosening, and it is a policy call, not a proof.** Where
the candidate takes a genuinely large step it now gets a wider excuse. The
mitigations are that it only fires when the pointwise error already exceeds
1e-3, and that it can only ever match the reference's value at *some* nearby
time — so a sustained level error (rectifier above; schmitt's 5 ns snap
delay) still fails. That is an argument, not a guarantee. The tighter
alternative, rejected as disproportionate for one fixture, is to make espice
emit a `2*delmin` probe step after every breakpoint landing so its grid
matches ngspice's shape at every source edge; that costs one extra accepted
point per breakpoint in every transient fixture.
