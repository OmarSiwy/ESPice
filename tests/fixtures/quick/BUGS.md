# BigOSpice Quick-Fixture Bug Log

Bug reports for circuits in `tests/fixtures/quick/`. Used by agents to track convergence failures and accuracy issues.

---

## BUG-001: RLC transient convergence failure (linear circuit fails Newton)

**File:** `rlc_underdamped_step.sp`
**Symptom:** `simulation error: Convergence failure after 50 iterations (residual=1.91e-6)`
**Status:** Open

### Circuit
```spice
V1 in 0 PULSE(0 1 0 1n 1n 100u 200u)
R1 in mid 10
L1 mid out 1m
C1 out 0 100n
.TRAN 1u 500u
```

### Analysis
- Purely **linear** circuit: R, L, C, V source. Newton should converge in exactly 1–2 steps.
- MNA dimension = 5 (3 nodes + 2 branches: i_V1, i_L1).
- L/h = 1e-3/1e-6 = 1000 (large but finite condition number).
- Residual of 1.91e-6 after 50 iterations = NR is NOT converging (for a linear circuit this is impossible unless J or residual is wrong).
- `NEWTON_RESTOL = 1e-9` — the absolute tolerance for the residual.
- Stamper `stamp_circuit_gc_at_time` correctly clears buffers at each call (confirmed lines 437–440).
- `pin_to_global` correctly maps branches to `num_vars + branch_index` (confirmed).
- DC OP at t=0: all-zero solution (PULSE=0V at t=0). First transient step at t=1µs: PULSE=1V.
- Hypothesis: the **linear solver** (SparseLU via `LinSolver::factorize`) may be producing an inaccurate solution for this near-singular-ish matrix. OR there is a subtle sign bug in how `q_prev` is assembled (branch current history for inductor).

### Where to investigate
- `crates/analysis/src/transient.rs`: `newton_solve_step` function (~line 199).
- `crates/solver/src/stamper.rs`: `stamp_circuit_gc_at_time` (~line 427).
- `crates/linalg/src/`: SparseLU solver — check if it handles the 5×5 MNA system correctly.
- Check: does `q_history.push(&residual_q)` at DC-OP initialization produce a valid q_prev (i.e., does it stamp at t=0 correctly and get L*i_L1=0)?

### To reproduce
```bash
./target/release/bigospice tests/fixtures/quick/rlc_underdamped_step.sp --quiet
# → simulation error: Convergence failure after 50 iterations (residual=1.91e-6)
```

---

## BUG-002: Adaptive transient hangs (h collapses to h_min → ~5e11 steps)

**File:** Any circuit with CMOS/nonlinear devices + Trapezoidal adaptive mode
**Symptom:** Simulation runs forever (never terminates)
**Status:** Mitigated (reverted CLI to fixed-step BackwardEuler)

### Root Cause
In `transient.rs` `run_transient_inner_with_arena`:
```rust
let tmax = config.tmax.unwrap_or(h_init);   // line ~407
```
When `config.tmax` is `None`, `tmax = h_init` (the initial timestep). The LTE controller then clamps the new step to `[h_min, tmax]`. For a CMOS inverter with `tstep=1ns`, `tmax=1ns` and `h_min = 1ns * 1e-10 = 1e-19s`. When the LTE ratio is large (nonlinear MOSFET transition), `h` collapses to `h_min = 1e-19`. Then `t` advances by 1e-19s per step, taking `tstop/1e-19 ≈ 5e10` iterations to finish.

### Fix Required
`config.tmax` should default to `tstop` (the simulation end time), not `h_init`. Change:
```rust
let tmax = config.tmax.unwrap_or(h_init);
```
to:
```rust
let tmax = config.tmax.unwrap_or(config.tstop);
```

### Where to fix
`crates/analysis/src/transient.rs` line ~407.

---

## BUG-003: `ac_resistance.sp` — SKIP(parse)

**File:** `ac_resistance.sp`
**Symptom:** The benchmark script returns `SKIP(parse)` — the Python ngspice raw file parser cannot parse ngspice's output.
**Status:** Open — not yet investigated.

### To investigate
Run ngspice on the circuit and inspect the raw file format:
```bash
ngspice -b ac_resistance.sp
```
Compare the raw file format with what `parse_ngspice_raw()` in `scripts/run_benchmarks.sh` expects.

---

## BUG-004: `sens_ac_rc.sp` — SKIP(no-nodes)

**File:** `sens_ac_rc.sp`
**Symptom:** Benchmark returns `SKIP(no-nodes)` — no shared nodes found between ngspice and BigOSpice output.
**Status:** Open — not yet investigated.

### Likely causes
- BigOSpice may be running an AC analysis but not outputting node voltages.
- Or the node naming differs between BigOSpice and ngspice.

---

## BUG-005: `resistor_divider_dc_sweep.sp` — SKIP(bigs) (FIXED in CLI, verify)

**File:** `resistor_divider_dc_sweep.sp`
**Status:** Fixed in `crates/cli/src/main.rs` — added `AnalysisKind::DcSweep` handler.
**Also fixed:** `crates/parser/src/tokenizer.rs` — DC sweep source name now stored as `("__dc_src__<name>", 0.0)` in params.

### To verify
```bash
./target/release/bigospice --output - tests/fixtures/quick/resistor_divider_dc_sweep.sp
# Should output node voltages at the final sweep point
```
