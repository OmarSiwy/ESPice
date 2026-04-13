# Handoff: transient step control mirrors dctran.c (impl-drift)

Scope: fixes 1-5 of the r-drift diagnosis (issues.md F9). Each commit
changes one step-control rule in `src/analysis/tran/tran.zig` to the ngspice
44.2 `dctran.c` rule it names. Fix 6 (one q-tape slot per `ddt()` site) needs
VerA and is not here; neither are the Newton-robustness items
(MODEINITPRED, fetlim/limvds, CKTconvTest), OP precision or URC.

## Gate (every commit)

`zig build -Dgpu=false`, `zig build test -Dgpu=false` (fixtures), `zig build
test-analysis -Dgpu=false`. All 616 decks byte-compared
(`--backend=cpu --format=binary -b -r`) against a `-Dgpu=false` build of
a151db0; every changed deck is scored as worst error/tolerance (max over
columns and axis). Base failing set: the 62 decks failing at 0424baf.

## Commits

| # | change | pass | changed decks (worst err/tol, base -> after) |
|---|---|---|---|
| 1 | LTE rejection keeps the order (dctran.c:966) | 554 | see below |
| 2 | Newton failure: dt/8 and order 1, no same-dt BE retry (:815, :823) | 554 | 3 decks |
| 3 | divided-difference history seeded with the max step (:312) | 554 | 4 decks |
| 4 | CKTterr on the charge at the published solution | 558 | 69 decks, 4 fixed |
| 5 | coupled inductors: LTE on INDflux (indload.c:72-76) | 559 | device_kinduc fixed |

### 1. LTE rejection keeps the integration order

Deleted the "drop to BE and retry at the same dt" block: ngspice only sets
`CKTdelta = newdelta` on an LTE reject; order 1 is reserved for a Newton
failure (:823). No pass/fail flip. Changed decks:

- passing, closer to the reference: `reference/bridge_capacitor_transient`
  0.998 -> 0.0056, `reference/cmos_inverter_tran` 0.135 -> 9.2e-5,
  `reference/rlc_underdamped_step` 0.052 -> 2.8e-9,
  `reference/stiff_two_time_constants` 0.40 -> 2.1e-7.
- failing, closer: `rtlinv` 4.13 -> 3.28, `inverter_chain_256` 1.43e5 ->
  1.23e4, `inverter_chain_4k` 503 -> 117, `parallel_inverters_100` 537 ->
  178, `vacask_mul` 242 -> 234, `bypass_idle_ladder` 9.42 -> 1.27,
  `txl2_3_line` 7.36e3 -> 988.
- failing, unchanged at 3 digits: `rca3040` 322, `parallel_inverters_2000`
  1.86e3, `ltra1_1_line` / `txl1_1_line` 1.37e6.
- failing, further: `diode_reverse_recovery` 7.87 -> 13.6, `mosamp` 2.6e5 ->
  3.84e5, `pvt_corners` 3.48e3 -> 3.73e3. The diagnosis measured these on
  an instrumented ngspice: the grid now follows ngspice's (diode recovery
  tracks it to 4e-5; mosamp's oracle is ngspice's ~710 Newton /8 cuts in the
  MOS2 slew, fix 2's territory).

### 2. Newton failure cuts dt by 8 and drops to order 1 in one retry

The same-dt BE retry and the halving are gone; ngspice does `CKTdelta /= 8`
and `CKTorder = 1` together. No pass/fail flip, no `op/` deck changed bytes (OPtran shares
`tran.simulate`, so a deck reaching that rung would move). Against commit 1:

- `hfet_inverter` 1.85e3 -> 704, `pvt_corners` 3.73e3 -> 3.23e3.
- `mos6_inverter` 453 -> 668: predicted by the diagnosis (rows 317 -> 315,
  ngspice's count); the residual is the per-terminal q tape (fix 6, VerA).

### 3. The divided-difference history starts at the max step

`dt_prev`/`dt_prev2` start at `effective_dt_max` (ngspice
`CKTdeltaOld[i] = CKTmaxStep`), not at the first dt. Only the first few LTE
calls see it. No flip. Against commit 2: `vacask_mul` 234 -> 200,
`vacask_graetz` 13.2 -> 13.5 (its grid is ngspice's point for point; the
value gap is fix 4), `lc_energy_gear` / `lc_energy_trap` last-digit moves
(both pass, 0.0016 / 0.0004).

### 4. The LTE reads the charge at the published solution

`newton()` returns x_k+1 while the planes hold q(x_k). Before the LTE, one
`evalQ(trial, t + dt)` fills `q_hist[0]` / `qt_hist[0]`, so CKTterr,
`advanceCurrent` and the next residual all read q at the accepted point.
That made the per-iteration `q_snap` / `qt_snap` copies in `TranHook` dead:
deleted (byte-identical on all 616 decks). The post-accept `has_state_q`
re-read stays: without it 4 decks change bytes (txl2_3, hfet, mesa_osc,
mos6_inverter), so the commit does move q on some devices.

Fixtures 554 -> 558, no regression. FIXED: `vacask_graetz` 13.2 -> 0.17
(base -> after), `vacask_mul` 242 -> 0.71, `bench_bypass_gated_branch`
10.8 -> 0.63, `bench_digital_clamp` 1.11 -> 0.92. 69 decks change bytes;
most passing ones move in the 3rd digit or not at all at the tolerance
scale. Notable against commit 3: `ltra2_2_line` 0.67 -> 0.24,
`power_rectifier` 0.20 -> 0.11, `rtlinv` 3.28 -> 3.09; further:
`diode_reverse_recovery` 13.6 -> 20.5 (predicted, ngspice grid),
`inverter_chain_4k` 117 -> 193 (still below base 503), `idle_ladder` 1.27 ->
1.38, `txl2_3` 988 -> 997.

Cost, callgrind Ir, commit 3 -> commit 4 (whole run, parse included):

| deck | before | after | |
|---|---|---|---|
| tran/device_mos6_inverter | 115.3M | 121.6M | +5.4% |
| tran/bench_tran_fourbitadder | 290.4M | 297.4M | +2.4% |
| stress/scaling_parallel_inverters_100 | 330.0M | 350.2M | +6.1% |
| tran/bench_bypass_gated_branch | 36.4M | 39.3M | +8.0% |

No cheaper pass keeps the values: the Jacobian-extrapolated C·dx is not
q(x) for a nonlinear charge, and the re-read after the commit cannot move
before the accept.

### 5. Coupled inductors truncate on INDflux

ngspice folds M·i_other into the inductor's flux before INDtrunc and MUT has
no trunc routine; the q tape kept L·i and every M·i as separate states. With
a kinduc batch present, `lteSnap` zeroes the inductor and kinduc tape spans
(a flat zero history never binds) and appends the row plane at every
current row, where an inductor's branch row sums to INDflux. Picked over
`n_qt = 0` for K circuits because every other device keeps its per-state
LTE. Circuits without a K card are byte-identical.
`tran/device_kinduc` 51.7 -> 0.0013 (PASS), bit-identical to the
`ZP_NO_QTAPE=1` run. Fixtures 558 -> 559; no other deck changed bytes
(`reference/coupled_inductors_ac` runs no transient).

Ceiling: every current row is appended, not just the inductors'. A device
charging its own branch row appears twice with the same value (the min is
unchanged); V-source rows are zero. Exact inductor rows need the tape's
`rhs_idx` exposed by Circuit.

## Every changed deck, a151db0 -> tip (worst err/tol)

67 of 616 decks change bytes; no `op/` deck is among them. Pass count
554 -> 559, and no deck on the base pass list fails.

| deck | base | tip | status |
|---|---|---|---|
| `layout/fanout_tran` | 1.95e-08 | 1.93e-08 | pass -> pass |
| `multi_analysis/bench_ngspice_rca3040` | 322 | 322 | FAIL -> FAIL |
| `multi_analysis/bench_ngspice_rtlinv` | 4.13 | 3.09 | FAIL -> FAIL |
| `reference/bridge_capacitor_transient` | 0.998 | 0.00544 | pass -> pass |
| `reference/cmos_inverter_tran` | 0.135 | 9.2e-05 | pass -> pass |
| `reference/diode_reverse_recovery` | 7.87 | 20.5 | FAIL -> FAIL |
| `reference/rlc_underdamped_step` | 0.0517 | 3.18e-09 | pass -> pass |
| `reference/stiff_two_time_constants` | 0.399 | 2.12e-07 | pass -> pass |
| `stress/scaling_inverter_chain_256` | 1.43e+05 | 1.19e+04 | FAIL -> FAIL |
| `stress/scaling_inverter_chain_4k` | 503 | 193 | FAIL -> FAIL |
| `stress/scaling_parallel_inverters_100` | 537 | 174 | FAIL -> FAIL |
| `stress/scaling_parallel_inverters_2000` | 1.86e+03 | 1.86e+03 | FAIL -> FAIL |
| `stress/scaling_rc_ladder_100k` | 1.66e-07 | 1.66e-07 | pass -> pass |
| `stress/scaling_rc_ladder_1k` | 1.66e-07 | 1.66e-07 | pass -> pass |
| `stress/vacask_graetz` | 13.2 | 0.167 | FAIL -> pass |
| `stress/vacask_mul` | 242 | 0.712 | FAIL -> pass |
| `stress/vacask_rc` | 5.89e-07 | 5.89e-07 | pass -> pass |
| `syntax/subckt_params` | 0.00152 | 0.00152 | pass -> pass |
| `tran/bench_bypass_burst_clock` | 1.67e-07 | 1.67e-07 | pass -> pass |
| `tran/bench_bypass_gated_branch` | 10.8 | 0.633 | FAIL -> pass |
| `tran/bench_bypass_idle_ladder` | 9.42 | 1.38 | FAIL -> FAIL |
| `tran/bench_digital_buffer_rc` | 5.89e-07 | 5.89e-07 | pass -> pass |
| `tran/bench_digital_clamp` | 1.11 | 0.916 | FAIL -> pass |
| `tran/bench_digital_rc_filter_chain` | 1.32e-07 | 1.32e-07 | pass -> pass |
| `tran/bench_ensemble_opamp_mc` | 0.00138 | 0.00138 | pass -> pass |
| `tran/bench_ensemble_pvt_corners` | 3.48e+03 | 3.23e+03 | FAIL -> FAIL |
| `tran/bench_medium_rc_ladder_50` | 1.36e-05 | 1.36e-05 | pass -> pass |
| `tran/bench_ngspice_mosamp` | 2.6e+05 | 3.84e+05 | FAIL -> FAIL |
| `tran/bench_ngspice_mosmem` | 3.15e+07 | 3.16e+07 | FAIL -> FAIL |
| `tran/bench_ngspice_rc` | 3.5e-10 | 3.49e-10 | pass -> pass |
| `tran/bench_ngspice_schmitt` | 500 | 500 | FAIL -> FAIL |
| `tran/bench_power_buck_open` | 0.0047 | 0.0047 | pass -> pass |
| `tran/bench_power_rectifier` | 0.198 | 0.112 | pass -> pass |
| `tran/bench_tline_ltra1_1_line` | 1.37e+06 | 1.37e+06 | FAIL -> FAIL |
| `tran/bench_tline_ltra2_2_line` | 0.67 | 0.238 | pass -> pass |
| `tran/bench_tline_txl1_1_line` | 1.37e+06 | 1.37e+06 | FAIL -> FAIL |
| `tran/bench_tline_txl2_3_line` | 7.36e+03 | 997 | FAIL -> FAIL |
| `tran/bench_tran_exp_source` | 3.7e-10 | 4.03e-10 | pass -> pass |
| `tran/bench_tran_fourbitadder` | 2.66 | 2.66 | FAIL -> FAIL |
| `tran/bench_tran_rc_pulse` | 4.53e-08 | 4.53e-08 | pass -> pass |
| `tran/bench_tran_sffm_source` | 0.167 | 0.167 | pass -> pass |
| `tran/device_hfet_inverter` | 1.85e+03 | 704 | FAIL -> FAIL |
| `tran/device_kinduc` | 51.7 | 0.00127 | FAIL -> pass |
| `tran/device_mesa_oscillator` | 1.9e+03 | 1.9e+03 | FAIL -> FAIL |
| `tran/device_mos1_large_signal` | 13.9 | 13.9 | FAIL -> FAIL |
| `tran/device_mos6_inverter` | 453 | 668 | FAIL -> FAIL |
| `tran/device_mos6_simpleinv` | 3.49 | 3.49 | FAIL -> FAIL |
| `tran/device_urc` | 22.8 | 22.8 | FAIL -> FAIL |
| `tran/finite_rise_negative` | 0.019 | 0.019 | pass -> pass |
| `tran/finite_rise_positive` | 0.019 | 0.019 | pass -> pass |
| `tran/ic_large` | 0.000321 | 0.000321 | pass -> pass |
| `tran/ic_negative` | 0.000321 | 0.000321 | pass -> pass |
| `tran/ic_small` | 0.000321 | 0.000321 | pass -> pass |
| `tran/lc_energy_gear` | 0.00159 | 0.00159 | pass -> pass |
| `tran/lc_energy_trap` | 0.000398 | 0.000398 | pass -> pass |
| `tran/rc_discharge_euler_0p001` | 0.582 | 0.582 | pass -> pass |
| `tran/rc_discharge_euler_1` | 0.582 | 0.582 | pass -> pass |
| `tran/rc_discharge_euler_1e-06` | 0.582 | 0.582 | pass -> pass |
| `tran/rc_discharge_gear_0p001` | 0.00209 | 0.00209 | pass -> pass |
| `tran/rc_discharge_gear_1` | 0.00209 | 0.00209 | pass -> pass |
| `tran/rc_discharge_gear_1e-06` | 0.00209 | 0.00209 | pass -> pass |
| `tran/rc_discharge_trap_0p001` | 0.000523 | 0.000523 | pass -> pass |
| `tran/rc_discharge_trap_1` | 0.000523 | 0.000523 | pass -> pass |
| `tran/rc_discharge_trap_1e-06` | 0.000523 | 0.000523 | pass -> pass |
| `tran/rc_pulse_history_gear` | 0.00252 | 0.00252 | pass -> pass |
| `tran/rc_pulse_history_trap` | 0.019 | 0.019 | pass -> pass |
| `tran/rc_sinusoidal_startup` | 0.000135 | 0.000135 | pass -> pass |

Further from the reference and failing either way (acceptable: the grid
now follows ngspice's, per the r-drift A/B on an instrumented ngspice 44.2):
`diode_reverse_recovery` 7.87 -> 20.5 (recovery tail tracks ngspice's grid
to 4e-5), `mosamp` 2.6e5 -> 3.84e5 (the oracle carries ngspice's ~710
Newton /8 cuts in the MOS2 slew: rebuild it tighter or mark KNOWN GAP),
`mos6_inverter` 453 -> 668 (row count now ngspice's 315; per-terminal q
tape, fix 6). `ltra1_1_line` / `txl1_1_line` / `rca3040` / `schmitt` /
`parallel_inverters_2000` move below 3 digits.

## Not done here

- Fix 6, one tape slot per `ddt()` site with a per-site LTE mask: VerA.
- Newton robustness (MODEINITPRED, fetlim/limvds, CKTconvTest), OP
  precision, URC: separate owners per r-drift.
- `tran_noise/rc_equilibrium` (F6) is a checker window one ulp past
  t_stop, not the controller.
