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
and `CKTorder = 1` together. No pass/fail flip, no OP deck changed (OPtran
never runs on the corpus). Against commit 1:

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
