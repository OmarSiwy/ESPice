# Fixture audit — open issues

Audit date 2026-09-16, branch `spice-audit`. Method: full `tests/fixtures`
sweep (616 decks) with `zig-out/bin/espice --backend=cpu --format=binary -b`,
cross-referenced against every `KNOWN GAP:` marker carried in the fixture
sources, and finally against a full `zig build test`.

Three passes:
1. run-level sweep — 63 of 616 decks exited nonzero or wrongly accepted an
   invalid deck;
2. `KNOWN GAP:` markers — 162 decks declare a missing feature in their own
   source;
3. the real harness — **461/616 pass, 155 fail** at the start, and 66 of those
   155 carried no marker at all. Those are section E, and they are the ones
   nobody knew about.

**After this session: 494/616 pass, 122 fail.** 33 decks flipped to PASS and
none regressed:

    dc/current_ascending  dc/current_descending  dc/mixed_voltage_current
    dc/resistor_sweep
    noise/balanced_temp_{0,27,125,minus40}  noise/unequal_temp_{0,27,125,minus40}
    noise/bench_noise_amp_noise  noise/bench_noise_bjt_flicker
    noise/clamped_output  noise/rc_1e-06  noise/rc_1e-09  noise/single_frequency
    noise/differential_balanced  noise/differential_unbalanced
    pss/bench_pss_diode_rect_driven  pss/diode_rectifier_rc
    pss/rc_fast  pss/rc_offset
    disto/diode_{0p001,0p002,0p01}  disto/linear_divider_{0p001,0p01,0p1}
    pz/widely_separated_modes  tf/current_input  tf/current_output

Failure MODES collapsed too, which matters more than the count: `MissingPlot`
20 -> 3, `MissingColumn` 5 -> 3, `DuplicateColumn` 1 -> 0. What is left is
89 `ValueMismatch` + 25 `SimulatorFailed` — the remaining work is physics and
missing features, not output plumbing.

The run-level count is 37 (from 63), with zero wrongly-accepted invalid decks.
The 51 `tstart` decks and the 22 `lin`/`oct` decks stopped ERRORING and now
run; they are counted in the numeric total above, not double-counted here.

Legend: `[ ]` open, `[x]` fixed this session, `[~]` partially fixed.

**Re-indexed 2026-09-24: 519/616 pass, 97 fail. Section F is the current
index; sections A-E below are the audit history it points into.**

FILE-OWNERSHIP NOTE: one `.disto` card must publish THREE plots, and the tree's
only fan-out mechanism is `prepare.zig queriesFromDirectives` (the same route
`.noise` already uses to become two jobs). So C7 required two small additive
edits outside its assigned files — `Disto.plot: Plot = .summary` in
`requests.zig` and an 8-line fan-out beside the `.noise` one, plus the job
ceiling `directives.len * 2` -> `* 3`. Default `.summary` means nothing else in
the tree changes behaviour.

"Fixed" means the change is in and the deck it was written against passes in
the final `zig build test` run — every `[x]` below is in the 33-deck flip
list above or was verified against its own oracle by hand. Nothing is marked
fixed on the strength of "it compiles".

One thing the harness caught on the way out, worth keeping in view: the
`.noise` change broke `src/problem/tests/problem.zig` "device noise needs no
input source and retains its thermal PSD", which pinned the old
`noise_density`/`noise_rms` shape. It is updated to the ngspice contract
(3-column amplitude spectrum, 2-column totals) and `zig build test-problem`
is green. A contract test that pins a wrong contract is doing its job when it
fails — but it means the plot schema was never anyone's deliberate choice.

## F. Failure index (re-indexed 2026-09-24)

`zig build test -Dgpu=false` on 4614f9a + the diode commit: **519/616 pass,
97 fail**. Every failing deck is listed once, under the entry that owns its
FIRST cause. Fix recipes for F1, F4, F5, F8, F10, F11 and E6 are in
`docs/conformance-phase2.md`.

- [~] **F1 — first transient step differs from ngspice dctran.** FIXED the
  step (phase 2b), 3 of 6 decks pass. `tran.zig` keeps the `firsttime` /10
  after the t = 0 breakpoint clamp (dctran.c:578-586), and every circuit,
  charge or not, repeats the first accepted dt (no CKTtrunc on the first
  point). First steps now equal ngspice's on all six decks.
  Pass: `tran/bench_medium_rc_ladder_50`, `tran/bench_power_buck_open`,
  `multi_analysis/bench_ngspice_res_array`. Still failing on a later cause:
  `tran/bench_tline_cpl_ibm2` (8.2e3x -> 2.2e3x), `tran/bench_tline_delay_line`
  (111x, unchanged), `tran/bench_ngspice_mosamp` (198 points against
  ngspice's 2316; 2.9e4x -> 2.6e5x, the grid start is right and the gap is
  the later LTE behaviour, group 14). The `four/*` decks move 0.33x -> 0.34x
  of tolerance on a grid that is now ngspice's point for point; their
  residual is the `.four` interpolation, not the grid.
- [x] **F2 — DC sweep axis: ngspice accumulates the step.** FIXED (phase
  2b): `dc.zig` accumulates `v += step` at both sweep levels like
  dctrcurv.c:469, and `temp_sweep.numPoints` takes the same 1e-6-step
  endpoint nudge as `sweepCount`. `dc/device_mesfet_transfer`,
  `dc/device_mesfet_subthreshold`, `dc/device_diode_breakdown` pass. The
  analytic-oracle axes (`dc/diode_reverse`, `diode_reverse_continuation`)
  move by the accumulated roundoff (0.28x / 0.14x of the 1e-15 atol, still
  passing): the axis now carries ngspice's bits, not start+k*step.
- [x] **F3 — B-source.** FIXED (phase 2b), see C1. `four/polynomial_2`,
  `four/polynomial_3`, `convergence/monotonic_cubic_1`,
  `convergence/monotonic_cubic_1000` pass, and so do `hb/polynomial_2`,
  `hb/polynomial_3`, `pss/polynomial_2`, `pss/polynomial_3` (C1 was their
  only open cause).
- [~] **F4 — VBIC.** `dc/device_vbic_temp` FIXED (phase 2b): a card
  without the fifth (thermal) node defaults `sw_et = 0` (ngspice ties the
  missing node to ground, inp2q.c:85-87, so dT = 0; an explicit SW_ET on the
  card still wins), and `i(q1)` is aliased to `v(q1#xf2)` when TD > 0 (E9).
  `dc/device_vbic_forced_output`: MissingColumn -> 1 row at 3.26x (row 25,
  the Vc = 3.45 V zero crossing of `i(vb)`, ~1e-6 relative; constants,
  unverified). `noise/device_vbic_noise_scale` 28x unchanged (the VA's
  double mfactor on noise, recipe 5b, not applied here).
  `multi_analysis/device_vbic_ce_amp`: MissingColumn -> AC passes, needs B3.
  `op/device_vbic` moves 0.0033x -> 0.0037x (self-heating now off, as in
  ngspice).
- [ ] **F5 — OP reports success after the confirming Newton failed.**
  `stress/scaling_inverter_chain_4k` (also slow: 308 s against the runner's
  300 s timeout, so it flips between Timeout and ValueMismatch). `op.zig`
  rung 5 returns `converged = true`; the stepping rungs run Newton with itl1
  where ngspice uses itl2.
- [ ] **F6 — last transient row lands short of t_stop.**
  `tran_noise/rc_equilibrium` (last row 9.999999999999999e-06 < 1e-5 ->
  MissingTimeCoverage). Clamp the last step to t_stop.
- [ ] **F7 — OP Newton acceptance too loose.** See E7.
  `tran/bench_tline_ltra1_1_line`, `tran/bench_tline_txl1_1_line`.
- [~] **F8 — envelope.** `envelope/sine` FIXED (phase 2b): columns are
  named from the probe labels (`i(vin)` was published as `v(2)`), and the
  window RMS uses trapezoid endpoint weights (it counted 65 samples over 64
  steps, sqrt(64/65) low). `envelope/dc_offset`, `negative_offset` go from
  0.28x to exact. Open: `envelope/rc_startup_0p001` (quasi-static
  envelope, the capacitor is open).
- [ ] **F9 — transient drift once LTE engages.** 21 decks; re-measure after
  F1. Grid divergence: `stress/scaling_parallel_inverters_100`,
  `stress/scaling_parallel_inverters_2000`, `stress/scaling_inverter_chain_256`,
  `tran/bench_bypass_idle_ladder`, `tran/bench_ensemble_pvt_corners`,
  `tran/bench_ngspice_mosmem`, `tran/device_mos6_inverter`,
  `tran/bench_tran_fourbitadder`, `tran/device_hfet_inverter`,
  `multi_analysis/bench_ngspice_rca3040`, `multi_analysis/bench_ngspice_rtlinv`,
  `tran/device_mos1_large_signal`, `tran/bench_ngspice_schmitt`,
  `tran/bench_tline_txl2_3_line`, `tran/device_kinduc`, `stress/vacask_mul`,
  `stress/vacask_graetz`. Value drift: `tran/bench_digital_clamp`,
  `tran/device_mos6_simpleinv`, `tran/bench_bypass_gated_branch`,
  `tran/device_urc`. Also `reference/diode_reverse_recovery` (2 rows in the
  recovery tail).
- [x] **F10 — PSS DC offset.** FIXED (phase 2b): `pss.zig` seeds the
  trapezoid `i_prev` at each period start with -f(x0) on rows with a
  diagonal C entry instead of zeroing it. `pss/rc_default`,
  `pss/rc_minimal_grid`, `pss/rc_negative_amplitude`,
  `pss/rc_slow_settling`, `pss/bench_pss_rlc_driven`, `pss/diode_clipper`
  pass (worst 0.14x). `pss/polynomial_2`, `pss/polynomial_3` pass since
  F3.
- [ ] **F11 — oracle defects, a user decision.** 5 decks:
  `tran/bench_tran_sffm_source` (ngspice's SFFM is wrong),
  `dc/bench_mosfet_cmos_inverter` (row 50 is metastable),
  `convergence/bench_ota_cutoff_abstol` (not an accuracy reference),
  `sens/bench_sens_bridge` (tests ngspice's parameter table, E10),
  `multi_analysis/bench_sens_diffpair` (ngspice reverses the `.tf` plots).
  The mesa inverter deck was filed here too, but ngspice at tight tolerance
  still matches its oracle, so it is under E6.
- Open features, unchanged: multi-probe B sources, now rejected with
  `UnsupportedBsourceExpression` instead of silently wrong
  (`pac/ideal_multiplier_1`, `pac/ideal_multiplier_2`,
  `pnoise/noise_multiplier_1`, `pnoise/noise_multiplier_2`,
  `qpss/square_mixer` — each with a second open feature); C2
  (`hb/current_driven_rc`, `hb/diode_clipper`, `hb/diode_rectifier_rc`);
  C4 (`pac/divider`, `pac/rc`, `pac/two_poles`); C5
  (`pnoise/lti_rc_sidebands_1`, `pnoise/lti_rc_sidebands_3`,
  `pnoise/lti_rc_sidebands_7`); C6 (`pxf/two_poles`); C10
  (`dc/device_b3soidd_output`, `dc/device_b3soifd_output`,
  `op/device_b3soidd`, `op/device_b3soifd`); E3 (`matex/dc`,
  `matex/linear_ramp`, `matex/purely_algebraic`, `matex/sine`); B3
  (`pz/bench_pz_filt_multistage`, `pz/bench_pz_pz2`,
  `multi_analysis/bench_pz_filt_bridge_t`); B6 (`dc/device_resistor_temp`);
  A5 (`hdl/verilog_inverter`); A6 (`stress/vacask_ring`).
- E6 device DC physics: `dc/device_bsim1`, `dc/device_bsim2`,
  `dc/device_bsim2_ngspice`, `dc/device_hisim2`, `dc/device_mesa_output`,
  `dc/device_mesa_inverter`, `dc/device_vdmos_output`,
  `tran/device_mesa_oscillator` (OP 17% off).

---

## A. Blockers and real defects (no `KNOWN GAP` marker — these are regressions)

- [x] **A1 — `matex/dc.sp` aborts with "double free or corruption (out)".**
  `src/analysis/tran/matex.zig`. `opts.m_max` defaults to 80, but the deck's
  circuit has n = 3. The step update reuses `arnoldi_tmp1` — an `n`-long
  buffer — as the m-long dense RHS (`root.zeroSimd(arnoldi_tmp1[0..m])`,
  `DenseLu.solveFactored(m, ...)`), so any Arnoldi that reaches m > n writes
  past the allocation and smashes the heap. A constant (DC) source never
  trips the breakdown test that stops the other three matex decks early.
  Fix: cap `m_max` at `n` — a Krylov subspace of R^n has no more than n
  dimensions, so everything past n was round-off anyway.

- [x] **A2 — `invalid/bench_topology_floating_node.sp` is accepted.**
  Oracle wants `nonunique_operating_point`; the deck solves. Node `island`
  is capacitor-coupled only and has no DC path to ground. The topology pass
  already diagnoses `VoltageSourceLoop` and `CurrentSourceCutset`; it has no
  no-DC-path check.

- [x] **A3 — `invalid/noise_missing_source.sp` is accepted.**
  `.noise v(out) Missing dec 10 1 100`. `prepare.zig:643` takes the source
  token "as syntax only" and never resolves it, so a misspelled source is
  silently ignored. Oracle wants `invalid_analysis_arguments`.

- [x] **A4 — `invalid/sp_zero_impedance.sp` is accepted.**
  `Vp out 0 0 portnum 1 z0 0`. `builder.zig sourcePort()` returns `null` when
  `z0 <= 0`, which downgrades the card to a plain V source instead of
  rejecting the deck. Oracle wants `invalid_analysis_arguments`.

- [ ] **A5 — `hdl/verilog_inverter.sp` → `UnsupportedHdlExtension`.**
  `.hdl "verilog_inverter.assets/v_inv.v"`. `model_loader.zig:78` accepts
  `.va` only, and the rejection is deliberate and correct as written: the
  `.v`/`.sv` route went through `fastvaf.fromVerilog`, which was deleted, and
  its replacement lives in VerA's FastVF and is not wired to this loader. So
  this is a cross-repo feature, not a bug here — but no gap marker, so the
  fixture was added expecting the wiring to exist.

- [ ] **A6 — `stress/vacask_ring.sp` → `UnsupportedDevice` (MOSFET LEVEL 1040).**
  PSP103 is not in the device catalog and `models/` has no psp103 source.

- [ ] **A7 — `convergence/negative_feedback_1000000000.sp` → `OpDidNotConverge`.**
  The other four gains in the same family converge. Homotopy/gmin ladder
  gives up at loop gain 1e9.

- [x] **B1 — `zig build` was blocked by a VerA regression (cleared).**
  `vera` rejects `models/hisimhv_va.va:1140`
  (`MPRco(DDLTSLP, (\`SUBVERSION<3 ? 0 : 10), ...)`) with
  `E1004 unsupported dependent parameter expression` /
  `UnsupportedParameterDefault`. `\`SUBVERSION` expands to `(VERSION*10 % 10)`
  over the *parameter* `VERSION`, so the default is genuinely dependent and
  falls to `codegen.zig` `f64Const`, which cannot render a `?:`. Both the
  diagnostic and the error are new in VerA's uncommitted working tree
  (`src/backend/codegen.zig`, actively being edited in a parallel session).
  It cleared mid-session once that tree settled; recorded because it is the
  failure mode to expect again while `../VerA` is being edited in parallel.

---

## B. Dispatcher gaps — decks rejected before any analysis runs

- [x] **B2 — nonzero transient output-start time (`tstart`) rejected.** 2 decks
  (`tran/device_mesa_oscillator`, and one passing deck). CORRECTED 2026-09-24:
  the marker had been stamped on 51 decks, but only 2 of them give `.tran` a
  nonzero `tstart`; the other 49 never exercised this path, and the 25 of them
  that still fail do so for transient-grid reasons (F1, F9), not `tstart`.
  All 51 stale markers are removed.
  `.tran step stop tstart [tmax]` → `UnsupportedTransientStart`
  (`prepare.zig`). ngspice suppresses output before `tstart`; it does not
  change the integration. Fixed: `requests.Tran.t_start`, both
  `waveform.record` calls gated on it, and one dt clamp so a step lands
  exactly on `t_start` (ngspice uses a breakpoint) — otherwise the first
  printed point is wherever LTE put it and the oracle's `samples` match has
  no coverage at `t_start`. `initialCapacity` sizes the PRINTED window only.

- [ ] **B3 — explicit PZ ports and transfer zeros.** 25 decks.
  `.pz in+ in- out+ out- vol|cur pol|zer|pz` → `UnsupportedPoleZeroArguments`
  (`prepare.zig:672`). `requests.Pz` carries no ports and `analysis/eigen/pz.zig`
  computes circuit poles only — no zeros. Note 11 of the 25 (`pz/rc_tau_*`,
  `pz/rlc_r_*`, `pz/two_equal_uncoupled`, `pz/unbuffered_ladder`,
  `pz/purely_resistive`, `pz/unstable_negative_conductance`) use bare `.pz`
  and already run; they carry the marker for the missing zero set only.

- [x] **B4 — non-DEC frequency sweeps (`lin`, `oct`).** 21 decks.
  `frequencyOptions()` (`prepare.zig:581`) hard-rejects anything but `dec`.
  `requests.Ac/Noise/Stb/Pac/Pxf/Pnoise/Disto` all carry
  `points_per_decade: u16` and every consumer calls
  `numerics.logSweepCount`/`fillLogSweep`. Fixed by replacing all of it with
  one `numerics.FreqSweep {f_start, f_stop, points, kind}` embedded in
  `Ac/Noise/Sp/Stb/Disto/Pac/Pnoise` — `logSweepCount`/`logSweepFreq`/
  `LogSweep`/`fillLogSweep`/`requests.SweepType` are gone. The geometric grid
  now steps by a FIXED ratio and stops at the last point under `f_stop`
  instead of stretching onto it, which is also C11.

- [x] **B5 — STB rejected outright.** 6 decks.
  `prepare.zig` returned `UnsupportedStabilityAnalysis` while
  `src/analysis/ac/stb.zig` sat unused. Fixed: `.stb Vprobe dec N f0 f1`
  binds the named 0 V source's node rows and branch row
  (`QueryBindings.v_pos`/`v_neg`), and the solve drives `rhs[branch] = 1` on
  the deck's OWN branch instead of augmenting to (n+1)². The augmentation was
  unusable: it put a second 0 V source across the same node pair as the
  deck's, two contradictory constraints on one pair. Return ratio is
  `T = −V(+)/V(−)`, which reproduces the fixtures' +10 on a −100·0.1 loop.

- [~] **B6 — `.dc` over a resistor or over TEMP.** 2 decks
  (`dc/resistor_sweep`, `dc/device_resistor_temp`) → `AnalysisSourceNotFound`.
  Fixed for cards: `.dc` now resolves its target through the same card table
  the AC overrides and `.sens` use, so `.dc R2 1k 5k 1k` sweeps the
  resistor's `r`. `.dc TEMP ...` as the PRIMARY variable still errors
  (`UnsupportedTemperatureSweep`): the inner march installs its value through
  one `ParamRef` write, and temperature is a whole-circuit set plus a
  re-derive — the OUTER loop already does that, the inner one does not.
  `dc/device_resistor_temp` also needs C8 (resistor tempco) to match numbers.

- [x] **B7 — mixed V/I DC sweep.** 1 deck (`dc/mixed_voltage_current`).
  `Dc.source_index`/`source2_index`/`source2_is_temp` are replaced by
  `Dc.SweepTarget {type_name, index, param_name, is_temp}`, keyed exactly like
  `ParamRef`, so a V card and an I card with the same ordinal no longer
  alias. `UnsupportedMixedCurrentSweep` is deleted.

- [x] **B8 — differential analysis output `v(a,b)`.** 3 decks
  (`noise/differential_*`, `multi_analysis/bench_sens_diffpair`) →
  `UnsupportedAnalysisOutput`. Fixed: `directiveNodeNameAt` reads the second
  name, `build()` resolves and permutes it alongside the first, and
  `Noise.out_neg` / `Tf.output_neg` / `Sens.output_neg` carry it. Every
  consumer is an adjoint seed, so the whole change is `e_pos − e_neg` instead
  of `e_pos` (and the same projection on the way out). GROUND is the
  single-ended default and is never stamped, so nothing else moves.

- [x] **B9 — TF with current input/output.** 3 decks. `differential_output`
  came with B8; the other two needed the two shapes `Tf` could not express:
  `Tf.output_branch` for `.tf i(Vmeasure) Vin` (the output is a BRANCH row,
  and `dir_nodes` only ever resolved `v(...)`, so `currentProbeName` reads the
  `i(...)` group), and `Tf.input_nodes` for `.tf v(out) Iin` (an I card has no
  branch row to drive — the excitation is a unit current into its node pair,
  which is what the card itself stamps, and the input immittance is then the
  voltage that current develops across its own terminals). `i_pos`/`i_neg` are
  plumbed through the builder and the permutation exactly as `v_pos`/`v_neg`
  were for B5. Verified: `i(Vmeasure)` 0.001 / Rin 1000, `v(out) Iin` 2000,
  `v(a,b)` 0.5 / 2000 / 1500 — all equal to their oracles.

---

## C. Numerical / model gaps — deck runs, answers are wrong

- [x] **C1 — the B-source compiler SILENTLY compiled unsupported
  expressions to an open circuit.** FIXED (phase 2b). `extractPolyCoeffs`
  builds a cubic polynomial in the one control pair: `+ - * /`, unary minus,
  `^`/`**`/`pow()` with a constant integer exponent 0..3, and one
  multiplicative `tanh(k*V)` factor; `models/bsource.va` gained `c3`.
  Anything else (a second V() pair as in `V(a)*V(b)`, `sqrt`, `i()`, degree
  above 3, a non-constant divisor) is a hard error naming the card and the key
  (`UnsupportedBsourceExpression`); the model-side all-zero open-circuit
  backstop is gone, so `v=0` is a 0 V source again. The multi-probe decks
  (`pac/ideal_multiplier_*`, `pnoise/noise_multiplier_*`,
  `qpss/square_mixer`) now fail with that error instead of computing
  `V(a)^2`: a multi-input B source is an open feature.

- [ ] **C2 — HB does not drive from the physical source spectra.** 12 decks
  (`hb/*`, `multi_analysis/bench_hb_tline_guard`). `hb/current_driven_rc`
  additionally fails at dispatch with `AnalysisSourceNotFound`.

- [ ] **C3 — QPSS ignores the physical two-tone source spectra.** 4 decks
  (`qpss/linear_two_tone_*`, `qpss/square_mixer`); all four also fail to
  converge (`QpssDidNotConverge`).

- [ ] **C4 — PAC injects a node current instead of honoring the named
  voltage-source excitation.** 5 decks (`pac/*`).
  Phase 2b: `pac.linearize` and pnoise's sample loops now evaluate under
  analysis("tran"), so SIN/PULSE sources and the LO move (they gave their
  DC value); no deck's bytes changed (the pac/pnoise decks are LTI).

- [ ] **C5 — periodic noise counts LTI sidebands as conversion.** 5 decks
  (`pnoise/lti_rc_sidebands_*`, `pnoise/noise_multiplier_*`). Extra sidebands
  of an LTI circuit must not add noise power.

- [~] **C6 — STALE MARKER, and the one real failure under it was something
  else entirely.** `pxf/divider` and `pxf/rc` pass as-is: `pxf/rc` reproduces
  its oracle's `pxf_h0(out)` to every printed digit
  (996.06768240717, -62.584778270572), so the "adjoint extraction conjugates
  it" note has not described the build for some time. The third deck,
  `pxf/two_poles`, was failing on `DuplicateColumn` — not a number at all.
  Two of its MNA rows are unlabeled (branch/internal unknowns) and the naming
  fallback spelled BOTH `pxf_h0(?)`, so the raw file carried the same column
  name twice and the harness rejected it before comparing anything. The same
  `"?"` fallback was in `analysis/types.zig` `probeNames` and
  `tran/envelope.zig`; all three now fall back to the ROW INDEX, which is
  unique by construction — verified, `two_poles` now emits 50 distinct column
  names.
  What that UNCOVERED, though, is a genuine value bug the structural error had
  been masking: with the columns legal, `pxf/two_poles` reads
  `pxf_h0(out) = 0` against an oracle of 996.0677-62.5848j. So C6 splits —
  the marker was stale and the duplicate-column defect is fixed, but
  `pxf/two_poles` keeps a real failure of its own, now visible for the first
  time. It is the only deck of the three behind a buffer (`Ebuf`), which is
  where to start.

- [x] **C7 — `.disto` now emits ngspice's real output product.** 3 decks
  (`disto/bench_disto_*`), the whole remaining MissingPlot group. All 3 pass,
  all 6 summary decks still pass, corpus 494 -> 497 with zero regressions.
  Two things worth keeping:
  * **The O(n^4) tensor was avoided.** `d3` is only ever used as the single
    contraction `d3(V1,V1,V1)`, so it is taken as a DIRECTIONAL second
    difference of the analytic Jacobian instead of being stored: with
    `V1 = p + jq`, `S(u)[row,a] = (G(x+hu) - 2G(x) + G(x-hu))[row,a]/h^2` and
    `T(w,u,u)[row] = sum_a w[a]*S(u)[row,a]` by symmetry, giving
    `Re = T(p,p,p) - 3T(p,q,q)`, `Im = 3T(p,p,q) - T(q,q,q)`. Four evals per
    frequency point, one extra n*n plane plus 4n of scratch — both far below
    the existing O(n^3) `d2`.
  * **The ×2 is real for the harmonic VECTORS and not for the summary.** The
    oracles' harmonic plots are sinusoid amplitude (DkerProc), twice the
    one-sided phasor; confirmed analytically on `bench_disto_diode_clipper`
    (the closed-form Volterra result is exactly half the expected V2 AND
    exactly half the expected V3) before any code was written. The summary
    columns stay unscaled, which is what keeps E5's `v1_mag = 3.75e-3` intact.
    So E5 and C7 are NOT contradictory: same factor, different products.

  ORIGINAL ENTRY: **`.disto` is missing ngspice's REAL output product.** 3 decks
  (`disto/bench_disto_*`, the whole remaining MissingPlot group). Two
  schemas coexist in the corpus and we only implement one: the six
  `diode_*`/`linear_divider_*` decks want the summary plot `Distortion
  Analysis` (frequency, hd2, v1_mag, v2_mag) and now pass; the three bench
  decks want ngspice's own pair, `DISTORTION - 2nd harmonic` and
  `DISTORTION - 3rd harmonic`, each a COMPLEX column per probe
  (`v(vcc) v(in) v(b) v(c) i(vin) i(vcc)`) — the full distortion solution
  vector, not a 4-column summary at one node. Measured on
  `bench_disto_bjt_ce`: 31 rows (which the new FreqSweep grid already
  matches exactly), `v(vcc)`/`v(in)` identically zero (source-clamped) and
  the rest genuinely nonzero (2nd: v(c) = -7.4419e-3, 3rd: v(c) = 9.1040e-5).
  V2 is already solved as a full vector (`x_work2`) so the 2nd-harmonic plot
  is mostly reshaping. The 3rd needs a `d3` tensor — `disto.zig` builds only
  `d2`, by finite difference on G — plus the third-order Volterra RHS. That
  is the real cost of C7, and it is why both plots are missing rather than
  one.

- [~] **C8 — resistor temperature model DONE; the `.sens` half is not a model
  job at all.**
  Numeric half fixed in `models/resistor.va`: ngspice's `res` temperature model
  (`restemp.c`) — `tnom`, `temp`, `dtemp`, `tc1`, `tc2`, `tce`, with
  `R(T) = r·(1 + tc1·d + tc2·d²)` and the `tce` exponential form REPLACING the
  polynomial rather than multiplying it. All four `temp/resistor_tc_*` decks
  pass. VerA hoists the whole block into `precompute`, so there is no
  per-Newton cost, and `r` stays Model field 0 so it remains the principal and
  prints as `v(r1)`, not `v(r1:r)`.
  Proven not to move anything else: controlled A/B in a worktree at `e1bc608`
  with `models/resistor.va` as the ONLY difference, full corpus both sides —
  494/122 before, 498/118 after, 4 FAIL→PASS, 0 PASS→FAIL. With `tc1=tc2=0`
  the factor is exactly 1.0 and `300.15 − 273.15 = 27.0` is exact (Sterbenz),
  so `rt == r` bit for bit. Every one of the 30 new `.sens` columns on the
  bridge reads exactly 0.0.
  See E10 for why `sens/bench_sens_bridge` is still red.

  ORIGINAL ENTRY (the diagnosis that sent the work to the wrong layer):
  **the resistor model is missing most of its ngspice parameter set.** 6 decks (`temp/resistor_tc_*`,
  `dc/device_resistor_temp`, and `sens/bench_sens_bridge`, which I had
  mis-filed under E8 as a column-naming problem). Measured: `.sens` emits
  184 columns and NOT ONE of the 24 the bridge oracle asks for. For `r5` we
  publish exactly `v(r5)`, `v(r5_mfactor)`, `v(r5_temperature)`; the oracle
  wants `rsh`, `tce`, `wf`, `l`, `bv_max`, `tc1`, `tc2`, `tc`, `temp`,
  `narrow`, `kf`, `ef`, `w`, `scale`. So this is one job in
  `models/resistor.va`, and `.sens` is fine — it faithfully reports the
  parameters the device actually has.
  (`v(vin_phase)` is the one genuine naming miss in that set: we spell the V
  card's AC phase `v(vin:acphase)`.)

- [x] **C9 — diode transit-time charge (`tt`).** 2 decks
  (`reference/diode_charge_ac`, `reference/diode_reverse_recovery`). Fixed
  2026-09-24 in `models/diode.va`, with ngspice's breakdown knee (xbv) in the
  same commit: `diode_charge_ac` passes, `diode_reverse_recovery` went from
  773x to 7.9x worst error and its 2 remaining rows are grid-sensitive
  (espice and ngspice both move ~110x off the oracle at tmax=0.1n, F9), and
  `dc/device_diode_breakdown` is red only on its sweep axis (F2).

- [ ] **C10 — BSIM3SOI FD/DD absent.** 4 decks (`op/device_b3soi*`,
  `dc/device_b3soi*_output`) → `UnsupportedDevice` for LEVEL 55/56.

- [x] **C11 — log frequency grid stretched to `f_stop`.** 1 deck
  (`ac/rc_dec_3_10_730`). Fixed with B4: `count()` is
  `floor(points·log_base(stop/start)) + 1` and `at(k)` is
  `f_start·base^(k/points)`, so `.ac dec 3 10 730` is 6 points ending at
  464.16 — the ngspice grid the oracle was taken on.

- [x] **C12 — Fourier capped at 9 harmonics.** 1 deck
  (`four/harmonic_count_16`). `requests.Four.n_harmonics` defaults to 9 and
  `prepare.zig:668` clamps to it.

- [x] **C13 — pole solver drops real fast poles.** 1 deck
  (`pz/widely_separated_modes`: τ = 1 ns and τ = 1000 s, 2 poles expected,
  1 reported). The filter that removes no-dynamics eigenvalues used a
  RELATIVE cutoff of `1e-9 · max|λ|`, so any deck spanning more than nine
  decades lost its fast modes. The eigenvalues it means to drop are zero to
  within the QR's backward error, so the threshold is `n · eps · max|λ|`
  (~1e-12 relative here, three orders below the 1e-12-relative pole it was
  eating).

---

## E. Unmarked failures found by the harness (2nd pass)

`zig build test` finally ran end to end: **461/616 pass, 155 fail**. 66 of the
155 carry NO `KNOWN GAP` marker, so they were invisible to the first pass
(which could only see decks that exit nonzero). Grouped by root cause:

- [x] **E1 — `.noise` emits the wrong plot, wrong columns, and no
  input-referred noise.** 15 decks (every `noise/*` except the two
  differential ones, which fail for this too). We printed plot `Device Noise`
  with column `noise_density` (V²/Hz); ngspice's — and the oracles' — plot is
  `Noise Spectral Density Curves` with `onoise_spectrum` and
  `inoise_spectrum`, both AMPLITUDE spectra in V/√Hz, and `Integrated Noise`
  carries `v(onoise_total)` + `v(inoise_total)`, not `noise_rms`.
  `inoise = onoise / |gain|`, which is the entire reason `.noise v(out) SRC`
  names a source. Fixed: `Noise.in_branch`, and the gain comes out of the
  adjoint solve already being done — `x_out = e_out^T A⁻¹ e_in =
  (A^-T e_out)^T e_in = y[in_branch]`, so it costs one array read, not a
  second sweep. Also: the `Integrated Noise` plot is emitted even for a
  degenerate band (`noise/single_frequency` pins both totals at 0); the
  "noisean.c:495" guard that suppressed it was wrong.

- [ ] **E2/E3/C2/C3 share ONE root cause: the source waveform is never in
  scope.** `ckt.setSimState(.{ .kind = .tran, .t = ... })` is called by
  `tran.zig`, `tran_noise.zig` and `envelope.zig` — and by nothing in
  `matex.zig`, `pss/`, `hb.zig` or `qpss.zig`. §4.6.1 `analysis("tran")` is
  false in the phase those four run in, so every `SIN`/`PULSE`/`PWL` card
  answers with its DC value and the analyses march an undriven circuit.
  `matex/sine` is the clean proof: 5001 rows, every probe exactly 0, on a
  deck whose only source is `SIN(0 1 1k)`. That is ~31 decks
  (11 PSS + 12 HB + 4 QPSS + 4 MATEX) behind one missing call.
  PSS is fixed this way, at the two sites its fixed-step trapezoid evaluates
  from (`integrateOnePeriod`: the charge seed and each Newton step),
  mirroring `tran.zig`. Measured: `pss/` went 12 failures to 8 — four decks
  (`bench_pss_diode_rect_driven`, `diode_rectifier_rc`, `rc_fast`,
  `rc_offset`) now pass outright, and the rest moved from EXACTLY ZERO to
  within a few parts in 10^3 of the oracle (`pss/rc_default`: -9.2712e-2 vs
  -9.2291e-2, rtol 2e-3) — a remaining integration-start detail, not a dead
  drive.
  MATEX got the same treatment in `evalSourceRhs` and did NOT move: still
  identically zero on every row. The change is right on its own terms (a
  waveform cannot exist outside the transient phase) but it is not what is
  wrong with MATEX. E3 stays open and the next suspect is the propagation
  itself, not the drive.
  HB and QPSS have a SECOND defect stacked on the same one, and it is worth
  stating exactly: both evaluate every time sample at **t = 0**
  (`hb.zig:174` and `qpss.zig:357` are literally `ckt.eval(x_sample, 0)`
  inside a `for (0..nf)` loop over the time samples). Declaring the transient
  phase alone changes nothing for them — sample `k` has to be evaluated at
  `t_k = k / (f0 · nf)` (and at the 2-D mix grid point for QPSS) before a
  source waveform can differ between samples. That is C2/C3, and it is a
  numerical change to the Newton fixed point across 16 decks, so it wants its
  own measured pass rather than a blind edit.

- [ ] **E2 — PSS returns identically zero on every driven deck.** 11 decks
  (`pss/rc_*`, `pss/diode_*`, `pss/polynomial_2`, `pss/bench_pss_*`):
  `v(out)[0]` expected −1.55e-1, got exactly 0. Same signature as C2 (HB) and
  C3 (QPSS) — `multi_analysis/bench_hb_tline_guard` also reads exactly 0 —
  so the three are almost certainly ONE defect: the periodic-analysis family
  never applies the deck's source waveforms. Fix C2/C3/E2 together.

- [ ] **E3 — MATEX is numerically dead after the first step.** 4 decks (all
  of `matex/`). `v(out)[1]` expected 4.84e-3 (linear_ramp) / 3.75e-1
  (purely_algebraic) / 2.94e-2 (sine), got exactly 0; `matex/dc` now exits 0
  (A1 fixed the heap smash) but writes a non-finite sample. A1 removed the
  memory-safety bug and nothing else — the module's answers were never
  checked before, because `matex/dc` aborted the runner. Suspect the Arnoldi
  breakdown path (`ar.m == 0` zeroes `x_new` wholesale) and the R-MATEX
  `T = (h/γ)(I − H⁻¹)` reconstruction.
  Phase 2b fixed two memory bugs on the way, no deck changed: the dense-LU
  pivot buffer was a fixed [256]u32 against a user m_max, and the posterior
  check got an n-long scratch for its 7*m^2 need, so it never ran on a small
  circuit.

- [x] **E4 — a current-swept `.dc` labels its axis `v(v-sweep)`.** 2 decks
  (`dc/current_ascending`, `dc/current_descending` → MissingColumn). The
  oracle's axis is `i(i-sweep)`. `dc.zig` hardcodes the voltage spelling;
  the axis name has to follow the swept card's kind, which is exactly the
  `SweepTarget` B6/B7 need anyway. Fixed with them — and it is not a two-way
  choice: the oracles spell a resistance sweep `res-sweep` and a temperature
  sweep `temp-sweep`, neither of them wrapped in `v()`/`i()`.

- [x] **E5 — `.disto` prints both magnitudes 2× too large.** 6 decks
  (`disto/diode_*`, `disto/linear_divider_*`). Found it: the ½ IS applied to
  the drive, and then `disto.zig` multiplied the answer back up —
  `v1_mag[k] = 2.0 * v1_out_mag`, citing DkerProc's rescale. The oracles say
  otherwise and say it unambiguously: `linear_divider_0p01` is a plain 0.75
  divider on `DISTOF1 0.01` and wants 3.75e-3 = ½·0.01·0.75, and
  `diode_0p01` wants v1 9.9939e-4 / v2 1.5448e-5 against our 1.9988e-3 /
  3.0897e-5 — a clean factor of two on BOTH. `hd2` is their ratio and was
  correct throughout, which is exactly how the factor survived this long.

- [ ] **E10 — `.sens` cannot name an INSTANCE parameter, so 10 of the bridge
  oracle's 24 columns are structurally unreachable from any `.va`.**
  1 deck (`sens/bench_sens_bridge`). The naming rule
  (`src/analysis/sweep/sens.zig:220`) is: Model param → `v(card:param)`,
  Instance param → `v(card_param)`, principal → `v(card)`. The oracle wants 10
  instance-spelled columns (`v(r5_l)`, `v(r4_temp)`, `v(r3_w)`, `v(r1_scale)`,
  …). VerA emits a FIXED `Instance` struct (`../VerA/src/backend/codegen.zig`
  `emitInstance`) — no Verilog-A `parameter` can land in it — and
  `src/analysis/eval.zig:1671` narrows Instance further to the allowlist
  `{temperature, mfactor}`. So a `.va` can only ever produce `:`-spelled
  columns, and adding the 9 remaining ngspice model-card names would deliver
  12/24, leave the deck red, and cost 9 dead f64 per resistor instance. Two
  more columns need their own thing: `v(r4:r)` needs a model default
  resistance separate from the instance value (`builder.zig addPassive`
  hard-codes `value_field = "r"` as the principal), and `v(vin_phase)` is the
  vsource naming miss already noted under C8.
  Our sens NUMBERS are right — `v(r1..r5)` match the ngspice reference raw to
  ~11 significant digits (ours −0.0023863074548945585 vs ngspice
  −0.002386307455259285). This deck fails purely on column names.
  Fixing it is an `eval.zig` + VerA job, not a model job.

- [ ] **E11 — `.options tnom` never reaches R/C/L.** `builder.zig addPassive`
  never calls `deriveModel`, so passives fall back to the emitted 27 °C
  default. Harmless on today's corpus (every oracle uses Tnom = 27) and
  therefore invisible — which is exactly why it is worth writing down.

- [ ] **E12 — model-card tempcos cannot reach a passive.**
  `.model RMOD R (tc1=...)` is dropped: `addPassive` only `applyKv`s the
  DEVICE card. The instance spelling `R1 a b 1k tc1=...` — what every current
  deck uses — works, so the corpus does not catch this.

- [x] **E9 — `i(q1)` in the VBIC oracles is NOT a terminal current.** FIXED
  (phase 2b): the builder aliases it to `v(<q>#xf2)` when TD > 0. 2 decks
  (`dc/device_vbic_temp`, `dc/device_vbic_forced_output` → MissingColumn).
  CORRECTED 2026-09-24: the earlier diagnosis (a missing per-device
  terminal-current probe) was wrong. ngspice `vbicsetup.c:510-525` creates
  `q1#branch` with `CKTmkCur` only when TD > 0 (excess phase): it is the
  branch unknown of the excess-phase network beside nodes `xf1`/`xf2`, and
  its value equals `v(q1#xf2)`. So the column is an internal state of
  ngspice's excess-phase implementation. Options: alias `i(q1)` to the
  `.va`'s excess-phase unknown, or drop the column from both oracles. Either
  way no terminal-current probe capability is needed. The value half of
  these decks is the self-heating route, F4.

- [ ] **E6 — device-model DC accuracy.** 11 decks (`dc/device_bsim1`,
  `device_bsim2*`, `device_hisim2`, `device_mesa_*`, `device_mesfet_*`,
  `device_vbic_*`, `device_vdmos_output`, `device_diode_breakdown`,
  `dc/bench_mosfet_cmos_inverter`) plus `dc/device_vbic_*` MissingColumn.
  Model-physics deltas against ngspice, not plumbing; each needs its own
  comparison and belongs with the device that owns it.

- [ ] **E7 — transmission-line transient accuracy.** 4 decks
  (`tran/bench_tline_txl1_1_line`, `txl2_3_line`, `ltra1_1_line`,
  `tran/bench_ngspice_schmitt`). CORRECTED 2026-09-24 after the native-line
  migration landed: these are not one line-model defect. `txl1` and `ltra1`
  start from a wrong operating point (`v(2)` = 5.005 V on a 5 V supply):
  Newton accepts a residual of ~1.5e-4 A because the gate at
  `newton_core.zig:414` is `10*diag*(reltol*|x|+vntol)`, where ngspice uses
  `reltol*|I|+abstol` (F7). `txl2_3` and `schmitt` are transient-grid drift
  after LTE engages (F9). None of the four points at the line models.

- [ ] **E8 — leftovers.** `envelope/sine`, `envelope/rc_startup_0p001`,
  `four/polynomial_2`, `tran_noise/rc_equilibrium` (MissingTimeCoverage),
  `stress/vacask_graetz`, `stress/vacask_mul`,
  `convergence/bench_ota_cutoff_abstol`. One cause each; no cluster.
  (`sens/bench_sens_bridge` started here and moved to C8 once measured — it
  is a missing device parameter set, not a sensitivity bug.)

---

## D. Hygiene found on the way

- [ ] **D1 — AGENTS.md cites a path that no longer exists.** "the 2 `disto`
  HD2 failures (tests/analyses.zig:972,1070)" — that file is now
  `src/problem/tests/analyses.zig`, and the disto assertions are not in it.

- [ ] **D3 — `src/analysis/tests/executor.zig` "timed worker excludes paused
  time when cancelled" is flaky, and only under the build runner.** It aborted
  three separate `zig build test` runs, each time right after printing
  `timing: query 0 transient ... QueryCancelled`. The same binary rerun
  standalone — including with the failing run's own `--seed` — reports
  `All 238 tests passed` every time, so it is not seed order.
  The assertion is `expectEqual(active, worker.active_ns)` where `active` was
  sampled BEFORE `worker.cancel()`: it demands that cancel + wait accrue
  exactly zero additional active nanoseconds. Under `--listen=-` the runner
  runs tests concurrently, the worker thread can still be scheduled between
  the sample and the join, and the counter moves. An equality assertion on a
  wall-clock counter across a thread join is the bug; the intent ("paused time
  is excluded") is expressible as a bound. Left alone because a fix that
  cannot be reproduced cannot be verified — reproduce it first with the
  runner, not standalone.

- [x] **D4 — some `KNOWN GAP` markers are stale.** Fixed 2026-09-24: every
  marker whose feature landed (B2, B4, B5, B7, B8, B9, C6, C7, C8, C9, C11,
  C12, C13) or whose deck passes was removed, with `netlist_sha256`
  recomputed from the new bytes. 35 markers remain, each on a failing deck
  whose feature is still open.
  ORIGINAL ENTRY: `pxf/rc` (C6) reproduces
  its oracle's `pxf_h0(out)` to every printed digit
  (996.06768240717, -62.584778270572) with the current code, so the
  "adjoint extraction conjugates it" note no longer describes the build.
  Re-audit each C-section marker against the harness before working it.

- [ ] **D2 — untracked fixtures with no catalogue entry in git.**
  `tests/fixtures/op/controlled_source_scaling.*`,
  `tests/fixtures/hdl/veriloga_parallel.*` are untracked working-tree
  additions from a parallel session. Noted so the audit is not read as
  covering them.
