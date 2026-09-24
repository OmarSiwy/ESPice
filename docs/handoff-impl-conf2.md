# Handoff: conformance phase 2b (impl-conf2)

Branch `worktree-agent-a46a8a243003386e8`, based on main `b1054dc`. Scope:
the phase-2b list (recipes in `docs/conformance-phase2.md`, index in
`issues.md` section F). Every commit here moves numbers, each toward its
deck's reference; the exceptions are listed with their reason.

## Gate

Run on the committed tree, checked out in a gate worktree beside the repo
(never the working tree):

- `zig build -Dgpu=false` and `zig build test -Dgpu=false`: 284/284 unit
  tests; fixtures 526 (b1054dc) -> 539 (after the first four commits) ->
  549 (code complete) -> 554 (with the regenerated oracles). No deck on
  b1054dc's pass list fails at any gate. (`zig build test` exits 1 on main
  too: the correctness step reports its known failures.)
- `zig build test-prepared` holds the new B-source tests; it is not wired
  into `zig build test` (see r-conformance "Tests"). Its 25 tests pass when
  the binary is run directly.
- All 616 decks byte-compared (`--backend=cpu --format=binary -b -r`)
  against a `-Dgpu=false` build of b1054dc (two base runs were
  byte-identical, so every difference is the change). Every changed deck is
  scored as worst error/tolerance, max over columns and axis
  (scratchpad `p2b/score.py`, an approximation of the harness).
- Commits touching disjoint analyses were gated together at the tip of
  their batch (A = the first four, B = the next nine); a deck's change is
  attributed by the analysis it runs.

GPU builds off by instruction.

## Commits

| commit | change | fixed decks |
|---|---|---|
| `92df755` | dc: accumulate the sweep value (+ temp_sweep endpoint nudge) | F2: diode_breakdown, mesfet_transfer, mesfet_subthreshold |
| `e16462d` | tran: firsttime /10 kept under the t=0 breakpoint clamp; no first-step growth | F1: rc_ladder_50, buck_open, res_array |
| `6ccb2a7` | pss: carry the trapezoid i_prev across the period seam | F10: pss rc_default, rc_minimal_grid, rc_negative_amplitude, rc_slow_settling, rlc_driven, diode_clipper |
| `30b509b` | envelope: probe labels; trapezoid RMS window | envelope/sine |
| `4ac92a4` | B-source: ^, **, integer pow, c3; hard error outside the subset | four/polynomial_2/3, monotonic_cubic_1/1000, hb/polynomial_2/3, pss/polynomial_2/3 |
| `23946b5` | VBIC: sw_et = 0 on a 4-node card; i(q) aliased to xf2 | dc/device_vbic_temp |
| `ff3e91f` | sens: linearize at ctx.x_op (no cold Newton) | none (no deck bytes changed) |
| `c9b25b2` | matex: pivots and posterior scratch sized by m_max | none (no deck bytes changed) |
| `57d0d44` | pac, pnoise: sources evaluated under analysis("tran") | none (LTI decks, no bytes changed) |
| `c0023c8` | hb, qpss: charge term from q(t) at every sample | none (linear decks move by roundoff) |
| `557d833` | op: stepping rungs with itl2 and cktop.c factor rules | 4k chain OP now correct, 308 s -> 15 s (deck fails in tran) |
| `ee748c7` | op: OPtran returns the confirming Newton's verdict | none |
| `74df137` | envelope: trapezoid steps carry the capacitor history | envelope/rc_startup_0p001 |
| `0243d0b` | fixtures: five group-15 oracles regenerated (user-approved) | all five pass |

## Decks that moved away from their reference (kept, with reason)

- `dc/diode_reverse` 3e-7 -> 0.28, `dc/diode_reverse_continuation` 8e-7 ->
  0.14: analytic axis (start + k*step); the axis now carries ngspice's
  accumulated bits, which the ngspice-derived oracles pin (F2).
- `four/*` 0.33 -> 0.34 (7 decks), `tran/sine`, `tran/sine_offset_phase`
  +2%: their accepted grid is now ngspice's point for point (checked);
  the residual is our `.four` interpolation.
- `tran/bench_ngspice_mosamp` 2.9e4 -> 2.6e5 (failing either way): first
  step now ngspice's; the run publishes 198 points against ngspice's 2316,
  the group-14 LTE gap.
- `op/device_vbic` 0.0033 -> 0.0037: self-heating off on a 4-node card, as
  ngspice runs it.
- `hb/dc_offset`, `hb/negative_dc` 2e-10 -> 2e-8: DFT of q(t) instead of
  C*X, roundoff.
- `pac/ideal_multiplier_{1,2}`, `pnoise/noise_multiplier_{1,2}`,
  `qpss/square_mixer` (failing before): now exit 1 with
  `UnsupportedBsourceExpression` (two V() pairs) instead of computing the
  wrong polynomial.

## Oracle regeneration (group 15, user-approved)

No generator lives in the repo; `p2b/regen.py` in the scratchpad did it,
one branch per deck, and recomputes `netlist_sha256`. What each oracle is
now is written into its `oracle.derivation`.

| deck | before (old oracle) | after (new oracle) |
|---|---|---|
| `tran/bench_tran_sffm_source` | 1.4e7x (ngspice's wrong SFFM) | 0.17x |
| `dc/bench_mosfet_cmos_inverter` | 1 row fails (metastable) | 0.50x |
| `convergence/bench_ota_cutoff_abstol` | 733x | 4e-6x |
| `sens/bench_sens_bridge` | MissingColumn | 1.5e-7x |
| `multi_analysis/bench_sens_diffpair` | MissingColumn / plot order | pass (harness) |

sffm: the tolerances had to widen (v(out) atol 2e-6 -> 1e-3 V, i(v1)
1e-11 -> 1e-6 A): a closed form also scores truncation error, and
ngspice 44.2 and espice at default options land on the same 3.1e-4 V off
it (espice matches ngspice's run of the closed-form B source bit for bit
on this deck). The sample times are ngspice's accepted grid for that
circuit, so linear interpolation onto them is exact for either engine.

## Not done, and why

- F6 `tran_noise/rc_equilibrium`: misdiagnosed. The run ends on its t_stop,
  which is `10u` = 10 * 1e-6 = 9.999999999999999e-06, exactly as ngspice's
  INPevaluate/numparse compute it; the analytic oracle's check window ends
  at the literal 1e-5 and `time_weighted_moments` compares coverage
  exactly. Fix is the oracle window (user decision) or a correctly rounded
  suffix parse, which would move every other deck off ngspice's bits.
- Group 8 (Newton acceptance, ltra1/txl1 v(2) = 5.005 V over a 5 V
  supply): findings only, as instructed. The residual gate
  (`solvers/newton_core.zig residualConverged`, ~:414) accepts
  |f_i| <= max(residual_tol, 10 * diag_i * (reltol*|x_i| + vntol)): a
  voltage tolerance scaled by the row's diagonal conductance, ~1.5e-4 A on
  these rows, where ngspice's NIconvTest checks the current as
  reltol*max(|I_new|,|I_old|) + abstol. Loosening/tightening it is global;
  it needs its own full-corpus A/B.
- Group 12 (missing models) and roundoff-only speedups: out of scope.
- Group 14 re-measured after F1: all 22 drift decks are byte-identical to
  b1054dc (none has a binding t=0 breakpoint and all carry charge, so
  neither F1 defect touched them). `scaling_inverter_chain_4k` joins them
  (OP now right, transient i(vdd) 503x).
- VBIC noise at M=2 (recipe 5b, double mfactor in `vbic13_4t.va`) and the
  mesa/E6 model recipes: not on this list.
- HB/QPSS Jacobians keep C(t0) (quasi-Newton for nonlinear charge; the
  residual is exact). `ponytail:` comments name the upgrade.

## Full byte-compare table (b1054dc -> branch tip, code changes)

Every deck whose raw changed, worst error/tolerance (`MISSCOL`: a column
the oracle wants is absent; `NORAW`: the run exited nonzero). The five
oracle decks are in the table above.

| deck | before | after |
|---|---|---|
| `aliases/envlp` | 0 | 0 |
| `convergence/bench_mos_latch_ladder` | 0.963 | 0.963 |
| `convergence/bench_mos_series_r` | 0.012 | 0.012 |
| `convergence/monotonic_cubic_0p001` | 0.01 | 0 |
| `convergence/monotonic_cubic_1` | 4.66e+03 | 9.76e-12 |
| `convergence/monotonic_cubic_1000` | 9.93e+05 | 2.67e-11 |
| `dc/bench_bjt_diff_amp` | 0.0156 | 0.00873 |
| `dc/bench_dc_sweep_nested_sweep` | 2.17e-08 | 5.84e-08 |
| `dc/bench_dc_sweep_param_sweep` | 0.831 | 0.831 |
| `dc/bench_ensemble_sweep_lanes` | 0.825 | 0.825 |
| `dc/bench_sweep_amp_bias_sweep` | 0.0786 | 0.0786 |
| `dc/bench_sweep_cmos_inv_sizing` | 0.977 | 0.977 |
| `dc/bench_sweep_nmos_wl_opt` | 0.304 | 0.304 |
| `dc/bench_sweep_pmos_wl_opt` | 0.00992 | 0.00992 |
| `dc/device_b3soipd_output` | 0.013 | 0.013 |
| `dc/device_b4soi_output` | 0.00171 | 0.00171 |
| `dc/device_bjt_npn_early` | 0.0204 | 0.0204 |
| `dc/device_bjt_npn_gummel` | 0.015 | 0.015 |
| `dc/device_bjt_npn_high_injection` | 0.00927 | 0.00927 |
| `dc/device_bjt_npn_output` | 0.681 | 0.681 |
| `dc/device_bjt_npn_saturation` | 0.0104 | 0.0104 |
| `dc/device_bjt_npn_temp` | 0.00947 | 0.00947 |
| `dc/device_bjt_pnp_output` | 0.676 | 0.676 |
| `dc/device_bsim1` | 0.516 | 0.516 |
| `dc/device_bsim2` | 2.45e-06 | 2.45e-06 |
| `dc/device_bsim2_ngspice` | 0.0249 | 0.0249 |
| `dc/device_bsim3_body_effect` | 2.19e-08 | 9.13e-07 |
| `dc/device_bsim3_output` | 1.96e-08 | 8.17e-08 |
| `dc/device_bsim3_pmos` | 1.96e-08 | 8.17e-08 |
| `dc/device_bsim3_temp` | 2.19e-08 | 9.13e-07 |
| `dc/device_bsim3_transfer` | 0.0824 | 0.0824 |
| `dc/device_bsim4_output` | 0.0819 | 0.0819 |
| `dc/device_bsim4_pmos` | 0.0932 | 0.0932 |
| `dc/device_bsim4_transfer` | 0.145 | 0.145 |
| `dc/device_diode_breakdown` | 150 | 0.636 |
| `dc/device_diode_high_injection` | 0.00666 | 0.00666 |
| `dc/device_diode_iv_sweep` | 0.00727 | 0.00727 |
| `dc/device_diode_recombination` | 0.00747 | 0.00747 |
| `dc/device_diode_temp` | 0.0165 | 0.0165 |
| `dc/device_hfet1_output` | 0.00884 | 0.00884 |
| `dc/device_hfet2_output` | 0.298 | 0.298 |
| `dc/device_hfet_id_vgs` | 0.00391 | 0.00391 |
| `dc/device_hicum2_gummel` | 0.27 | 0.27 |
| `dc/device_hicum2_output` | 0.425 | 0.425 |
| `dc/device_hisim2` | 0.299 | 0.299 |
| `dc/device_hisimhv` | 0.545 | 0.545 |
| `dc/device_jfet2` | 0.989 | 0.989 |
| `dc/device_jfet_output` | 2.55e-05 | 2.55e-05 |
| `dc/device_jfet_transfer` | 0.00554 | 0.00554 |
| `dc/device_mesa_inverter` | 0.972 | 0.972 |
| `dc/device_mesa_output` | 0.0306 | 0.0306 |
| `dc/device_mesfet_output` | 0.00654 | 0.00654 |
| `dc/device_mesfet_subthreshold` | 2.29 | 0.244 |
| `dc/device_mesfet_transfer` | 1.64 | 0.00577 |
| `dc/device_mos1_body_effect` | 2.26e-06 | 1.12e-06 |
| `dc/device_mos1_output` | 2.17e-08 | 2.59e-07 |
| `dc/device_mos1_pmos` | 2.17e-08 | 2.59e-07 |
| `dc/device_mos1_subthreshold` | 1.97e-08 | 8.29e-08 |
| `dc/device_mos1_temp` | 0.000336 | 0.000336 |
| `dc/device_mos1_transfer` | 2.26e-06 | 1.13e-06 |
| `dc/device_mos2` | 9.65e-06 | 9.65e-06 |
| `dc/device_mos2_transfer` | 9.65e-06 | 9.65e-06 |
| `dc/device_mos3` | 0.0196 | 0.0196 |
| `dc/device_mos3_transfer` | 0.0166 | 0.0166 |
| `dc/device_mos6` | 0.00306 | 0.00306 |
| `dc/device_mos9` | 2.17e-08 | 2.59e-07 |
| `dc/device_vbic_forced_output` | MISSCOL | 3.26 |
| `dc/device_vbic_gummel` | 0.28 | 0.28 |
| `dc/device_vbic_output` | 0.348 | 0.348 |
| `dc/device_vbic_temp` | MISSCOL | 0.343 |
| `dc/device_vdmos_output` | 0.0666 | 0.0666 |
| `dc/diode_forward` | 1.85e-07 | 1.85e-07 |
| `dc/diode_reverse` | 3.23e-07 | 0.278 |
| `dc/diode_reverse_continuation` | 8.33e-07 | 0.139 |
| `dc/fine_step` | 1.93e-07 | 1.93e-07 |
| `dc/zero_crossing` | 2.78e-07 | 9.25e-12 |
| `envelope/dc_offset` | 0.28 | 2.68e-14 |
| `envelope/dc_only` | 0 | 0 |
| `envelope/negative_offset` | 0.28 | 2.68e-14 |
| `envelope/rc_startup_0p001` | 498 | 0.137 |
| `envelope/rc_startup_1e-05` | 0.57 | 0.0623 |
| `envelope/sine` | 1.54 | 7.85e-13 |
| `envelope/zero` | 0 | 0 |
| `four/dc_only` | 0 | 0 |
| `four/harmonic_count_1` | 0.166 | 0.172 |
| `four/harmonic_count_16` | 0.332 | 0.344 |
| `four/harmonic_count_3` | 0.331 | 0.344 |
| `four/offset` | 0.332 | 0.344 |
| `four/phase_0` | 0.332 | 0.344 |
| `four/phase_180` | 0.332 | 0.344 |
| `four/phase_30` | 0.288 | 0.299 |
| `four/phase_90` | 0.0682 | 0.0681 |
| `four/polynomial_2` | 625 | 0.204 |
| `four/polynomial_3` | 714 | 0.336 |
| `four/sine` | 0.332 | 0.344 |
| `hb/dc_offset` | 4.54e-10 | 3.01e-08 |
| `hb/diode_clipper` | 2.56 | 2.56 |
| `hb/negative_dc` | 2.1e-10 | 2.02e-08 |
| `hb/polynomial_2` | 500 | 7.19e-09 |
| `hb/polynomial_3` | 500 | 9.08e-09 |
| `multi_analysis/bench_ngspice_rca3040` | 322 | 322 |
| `multi_analysis/bench_ngspice_res_array` | 8.64e+03 | 4.5e-06 |
| `multi_analysis/bench_ngspice_rtlinv` | 4.13 | 4.13 |
| `multi_analysis/device_vbic_ce_amp` | MISSCOL | 0.00819 |
| `noise/device_vbic_noise_scale` | 28.3 | 28.2 |
| `op/device_vbic` | 0.00333 | 0.00371 |
| `pac/ideal_multiplier_1` | 333 | NORAW |
| `pac/ideal_multiplier_2` | 333 | NORAW |
| `pnoise/noise_multiplier_1` | 100 | NORAW |
| `pnoise/noise_multiplier_2` | 100 | NORAW |
| `pss/bench_pss_diode_rect_driven` | 0.0329 | 0.0156 |
| `pss/bench_pss_rlc_driven` | 20.8 | 0.095 |
| `pss/diode_clipper` | 2.09 | 0.0291 |
| `pss/diode_rectifier_rc` | 0.113 | 0.0949 |
| `pss/polynomial_2` | 286 | 3.89e-13 |
| `pss/polynomial_3` | 286 | 2.77e-12 |
| `pss/rc_default` | 3.91 | 0.0251 |
| `pss/rc_fast` | 0.00101 | 0.00101 |
| `pss/rc_minimal_grid` | 2.95 | 0.142 |
| `pss/rc_negative_amplitude` | 3.91 | 0.0251 |
| `pss/rc_offset` | 0.147 | 0.0027 |
| `pss/rc_slow_settling` | 6.52 | 0.0218 |
| `qpss/linear_two_tone_1_1` | 5.01e-05 | 5.01e-05 |
| `qpss/linear_two_tone_2_2` | 5.01e-05 | 5.01e-05 |
| `qpss/linear_two_tone_3_2` | 6.72e-05 | 6.72e-05 |
| `qpss/square_mixer` | 333 | NORAW |
| `reference/bjt_emitter_degenerated_dc` | 0.0052 | 1.04e-06 |
| `reference/cmos_inverter_dc` | 0.000686 | 0.000686 |
| `reference/lossless_transmission_line` | 3.82e-10 | 3.82e-10 |
| `reference/voltage_switch_hysteresis` | 1.6e-08 | 1.6e-08 |
| `stress/scaling_inverter_chain_4k` | 2.3e+08 | 503 |
| `syntax/subckt_params` | 0.00154 | 0.00152 |
| `tran/bench_medium_rc_ladder_50` | 8.61 | 1.36e-05 |
| `tran/bench_ngspice_mosamp` | 2.93e+04 | 2.6e+05 |
| `tran/bench_power_buck_open` | 2.96e+03 | 0.0047 |
| `tran/bench_tline_cpl3_4_line` | 0.000765 | 0.000765 |
| `tran/bench_tline_cpl_ibm2` | 8.17e+03 | 2.19e+03 |
| `tran/bench_tline_delay_line` | 111 | 111 |
| `tran/bench_tline_ideal_tline` | 5.77e-14 | 0 |
| `tran/bench_tline_terminated` | 0.574 | 0.574 |
| `tran/dc_only` | 0 | 0 |
| `tran/device_coupled_tlines` | 0.000292 | 0.000292 |
| `tran/device_cswitch` | 3.55e-07 | 3.55e-07 |
| `tran/device_lossy_tline` | 1.42e-09 | 1.42e-09 |
| `tran/device_switch` | 8.88e-10 | 8.88e-10 |
| `tran/device_switch_hysteresis` | 1.53e-09 | 1.53e-09 |
| `tran/device_tline` | 2.15e-10 | 2.15e-10 |
| `tran/device_vsource` | 1.13e-10 | 1.13e-10 |
| `tran/pwl_nonzero_start` | 0 | 0 |
| `tran/pwl_triangle` | 1.56e-12 | 1.56e-12 |
| `tran/sine` | 0.00385 | 0.00394 |
| `tran/sine_offset_phase` | 0.00763 | 0.0078 |
