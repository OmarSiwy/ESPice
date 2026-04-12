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
