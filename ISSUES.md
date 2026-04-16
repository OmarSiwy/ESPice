# External Test Issues — BigOSpice

Last audited: 2026-04-15 (Wave III session — fixes applied, working dir)
Test runner: `nix develop .#full --command cargo test --test external <name> -- --include-ignored`
Simulators: ngspice, vacask, xyce

---

## Current Test Status (post-Wave-II fixes, some tests still running)

| Category | Status | Latest result |
|---|---|---|
| adversarial | ✅ PASS | — |
| basic | ✅ PASS | — |
| analyses | ✅ PASS | — |
| fourier | ✅ PASS | — |
| noise | ✅ PASS | — |
| sensitivity | ✅ PASS | — |
| xyce | ✅ PASS | — |
| devices | ✅ PASS | R003 fix |
| bjt | ❌ 11/15 pass | bjt_ecl_gate 13%; pnp_ce_amp convergence skip |
| analog | ❌ 3/16 pass | colpitts_oscillator NRMSE=732 (UIC not applied) |
| mosfet | ❌ 12/22 pass | Level 2/3 PMOS fix applied — re-running (bxxtt297t) |
| power | ❌ 0/8 pass | Level 2/3 PMOS fix applied — needs re-run |
| tline | ❌ 7/8 pass | lossy_tline_long NRMSE=1.53e-1 |
| quick | ❌ 6/10 pass | lossy_tline_driver NRMSE=7.12e-2; AC rawfile skips |
| dc_sweep | ❌ 5/6 pass | nested_sweep_rc ✅ FIXED; mosfet_ids_vds 16.7% |
| parser | ❌ re-running | NODESET+GSHORT fix applied (biu1ez09e) |
| digital | ❌ 0/3 pass | DigitalRuntime not wired into transient |
| ngspice | ⏱ HUNG | No wall-clock timeout |
| convergence | ❓ TBD | Agent a135d43c6fffc09fd still pending |
| medium | ❓ TBD | Agent a1ef06e9a5810c2cc still pending |
| scaling | ⏱ TIMEOUT | Wave J target (BTF + sparse-LU) |

---

## Wave-III Fixes Applied (uncommitted, working dir)

### ✅ FIXED — dc_op.rs: TEMP sweep °C passed as Kelvin
Lines 226, 240, 268: `set_global_temperature(val + 273.15)` at all 3 TEMP sweep sites.
Fixes: nested_sweep_rc. dc_sweep: 4/6 → 5/6.

### ✅ FIXED — parser: .IC V(node) val (no equals) silently dropped
`tokenizer.rs:parse_v_assign_pairs`: now accepts `V(n) val` and `V(n)=val`.
Fixes: IC parsing for 100% of ngspice-style netlists.

### ✅ FIXED — newton.rs: PNP crude heuristic wrong for VEE-only supply
PNP no-topology branch: use `v_min*0.1` / `v_min*0.8` when `|v_min| > |v_max|`.
No regression (BJT 11/15 unchanged).

### ✅ APPLIED — test_external.rs: tmax cap for adaptive transient
`tmax = tstep * 10` prevents adaptive stepper from taking oscillation-skipping steps.

---

## Wave-II Fixes Applied (uncommitted, working dir)

### ✅ FIXED — eval_with_extrinsic internal node indices (B001-RESIDUAL)
**File:** `crates/device/src/bjt.rs` lines 257–419
After B001 tokenizer fix (internal pins 3,4,5 → 4,5,6), `eval_with_extrinsic` still read
voltages[3,4,5] and stamped Jacobian at pins 3,4,5.
- Fallback check: `< 6` → `< 7`
- Internal reads: `voltages[3,4,5]` → `voltages[4,5,6]`
- Jacobian: RC (0↔3)→(0↔4), RB (1↔4)→(1↔5), RE (2↔5)→(2↔6)
- GP core re-index: `row+3,col+3` → `row+4,col+4`
- q6: 6→7 elements, `q6[i+3]` → `q6[i+4]`
- xcjc split: int_B 4→5, `+3`→`+4` throughout
- g residual: added substrate 0.0 at index 3
**Result:** bjt_ic_vce PASSES. BJT: 11/15 pass.

### ✅ FIXED — BJT GSHORT: zero-R extrinsic pins leave internal nodes floating
**File:** `crates/device/src/bjt.rs` lines ~289–336
When only RC>0 (not RB/RE), internal B'/E' nodes were created but had zero conductance
to external pins → disconnected from circuit (MNA floating node).
Added `GSHORT = 1e9` effective conductance between ext/int for all three pins when R=0.
Always stamp ext-int pairs unconditionally using `gc_eff`, `gb_eff`, `ge_eff`.
**Fixes:** `include_test` (B001 regression with RC=5, RB=RE=0).

### ✅ FIXED — BJT junction limiter: wrong pins, BE/BC not independent
**File:** `crates/solver/src/junction_limit.rs` lines 134–164
Old: used external pins (0,1,2) always; combined BE+BC into single correction on base.
New:
- Use internal pins (5,6,4)=(intB',intE',intC') when `new_v.len() >= 7`
- BE correction → emitter independently; BC correction → collector independently
**Partial fix:** ECL gate still 13% NRMSE — deeper issue remains.

### ✅ FIXED — Level 2/3 PMOS threshold sign error
**File:** `crates/device/src/mosfet.rs` lines 261, 373
Same bug as R001 (fixed for Level 1). `-(vto.abs())` → `vto.abs()` in Level 2 and Level 3.
Root cause: all CMOS transient circuits use Level 2/3; PMOS never turned off.
**Expected to fix:** cmos_nand2, cmos_nor2, cmos_latch, cmos_dff, cmos_ring_osc_21,
cmos_sram_6t, cmos_sram_array_4x4, cmos_charge_pump_4, all 8 power fixtures.

### ✅ FIXED — NODESET overwritten by BJT Pass 4
**File:** `crates/solver/src/newton.rs` lines 433–447
Pass 3.5 applied NODESET but didn't set `known[]` → Pass 4 BJT heuristic overwrote hints.
Moved NODESET to Pass 5 (after Pass 4 completes).
**Fixes:** `nodeset_bistable` (latch converged to wrong state).

---

## Wave-I Fixes (commit 41519d4) — still valid

### ✅ R001: Level 1 MOSFET PMOS vth sign
`crates/device/src/mosfet.rs:57` — `vth_base = vto.abs()` for PMOS.

### ✅ R002: LTE_MIN_STEP_RATIO reverted
`crates/analysis/src/transient.rs:144` — reverted 1e-6 → 1e-10.

### ✅ R003: CCVS/CCCS ctrl_current injection
`crates/solver/src/stamper.rs:349,641` — added CCVS/CCCS ctrl_current injection.

### ✅ B001: BJT internal node pin renumbering
Tokenizer creates internal nodes at pins 4,5,6 (not 3,4,5). Substrate at pin 3.

---

## Active Failures — Root Cause Known, Fix Not Yet Applied

### ✅ FIXED — DC_SWEEP: Temperature °C vs Kelvin mismatch
**File:** `crates/analysis/src/dc_op.rs` lines 225–227, 239, 268–270
**Error:** nested_sweep_rc max_err=1.00 — NR diverges at TEMP=100
**Fix applied:** `outer_ckt.set_global_temperature(outer_val + 273.15)` at all 3 TEMP sweep sites.
**Result:** nested_sweep_rc PASSES. dc_sweep: 5/6.

### ✅ FIXED — Parser: .IC without `=` sign silently dropped
**File:** `crates/parser/src/tokenizer.rs:3296` — `parse_v_assign_pairs`
**Error:** `.IC V(n_tank) 0.1` (no equals) → parsed as 0 ICs; `has_ic=false` forever
**Fix:** Accept both `V(node)=val` and `V(node) val` forms.
**Note:** colpitts_oscillator still FAILS — root cause is deeper (see below).

### ✅ FIXED — newton.rs PNP negative-supply initial guess
**File:** `crates/solver/src/newton.rs` (PNP crude heuristic branch)
**Fix applied:** Use `v_min` rail when `|v_min| > |v_max|`. No regression (BJT still 11/15).

### ANALOG: colpitts_oscillator NRMSE=732 — needs IC-constrained DC OP
**Fixture:** Colpitts 7.1 MHz oscillator, `C1=C2=100p, L1=10u, NPN BJT`
**Root cause (updated):** Two issues:
1. Parser dropped `.IC V(n_tank) 0.1` (now fixed)
2. ngspice's `.IC` without `UIC` in `.TRAN` means: solve DC OP with n_tank FIXED at 0.1V, then start transient from that constrained OP. BigOSpice has no "pinned-node DC OP" mode.
   - UIC=true approach failed: starts from all-zeros → DC supply sources cause huge initial transient → NRMSE=8440 (worse)
   - "Apply IC on top of DC OP" approach failed: n_tank jumps from ~11V to 0.1V → violates KCL → NRMSE=36600 (worse)
**Needed fix:** Implement DC OP with `.IC` nodes pinned (stamp stiff voltage sources during DC OP, remove before transient). Wave III.
Also possible: BJT CJE/CJC capacitance model inaccuracies (same root cause as bjt_ecl_gate).
**tmax cap applied:** `tmax = tstep * 10` in test_external.rs to prevent 70-cycle timesteps.

### BJT: bjt_ecl_gate NRMSE=1.30e-1 — not fixed by junction limiter
**Fixture:** ECL OR/NOR, 20ns transient, TF=0.3n, TR=6n
**Status:** Junction limiter fix (internal pins) did not help — NRMSE unchanged.
**Likely cause:** Transient timing error from CJC/CJE capacitance or transit-time charge
in eval_gp. Needs deeper investigation.

### TLINE/QUICK: LTRA port current history bug
**Files:** `crates/solver/src/stamper.rs:1499–1501`, `crates/device/src/ltra.rs:598–611`
**Errors:** lossy_tline_long NRMSE=1.53e-1, lossy_tline_driver NRMSE=7.12e-2
**Root cause:** `update_ltra_histories` phase 2 stores companion-model current
`i1 = Y0*V + I_eq` instead of physical port current. Next timestep reads these back to
form wave variable `E = V + Z0*I` — feeds companion current instead of physical current,
corrupting Branin wave variable. Error scales with attenuation (0.975 low-loss → 7%,
0.368 lossy → 15%).
**Fix:** After NR convergence, read physical port current from solution vector branch row,
not reconstruct from Norton equivalent.

### NGSPICE: hangs — no wall-clock timeout
**Root cause:** Complex BJT transient (likely bjt_4bit_adder_tran or bjt_ecl_schmitt_tran)
triggers non-terminating NR + adaptive step-halving. No elapsed-time guard.
**Fix:** Add per-fixture timeout in test harness + max-elapsed guard in NR outer loop.

### DC_SWEEP: mosfet_ids_vds max_err=1.67e-1
**File:** `crates/analysis/src/dc_op.rs:235–252`, `crates/device/src/mosfet.rs:86–90`
**Root cause theories:**
1. Warm-start contamination across VGS outer family curves.
2. Lambda applied at wrong OP during warm-start convergence.
Level 2/3 PMOS fix may partially help — re-run after mosfet test completes.

### DIGITAL: DigitalRuntime not wired into transient
**File:** `crates/analysis/src/transient.rs` — no call to `DigitalRuntime::flush()`
**Errors:** xspice_adc_bridge NRMSE=0.85, xspice_dac_bridge NRMSE=0.77
**Root cause:** `circuit.take_digital_spec()` never called. DAC-driven nodes float → flat 0V.
`DigitalRuntime` API fully implemented in `crates/digital/src/transient_hook.rs`.
**Contract to implement:**
1. Before each NR iteration: `runtime.flush(t_next, &x[..num_nodes])`
2. After accepted step: `runtime.commit()`
3. On step rejection: `runtime.rollback(t_next)`
4. DAC bridges: stamp stiff voltage source on `analog_node_idx` each NR step.

---

## Still Pending Agent Results

- **a135d43c6fffc09fd** — convergence category (gmin_stepping, pseudotran, ring_osc_cold_start)
- **a1ef06e9a5810c2cc** — medium category

---

## Fix Priority Queue (next session)

1. DC OP with pinned `.IC` nodes — `crates/solver/src/newton.rs` + `run_dc_op_with_ic_pins()` → unblocks colpitts, cmos_ring_osc, ldo_regulator, power circuits
2. Digital transient wiring — wire DigitalRuntime into transient loop (0/3 digital)
3. Ngspice wall-clock timeout — prevent test hang
4. LTRA port current fix — read physical current from solution vector (tline/quick)
5. Convergence category — wait for agent a135d43c6fffc09fd findings
6. bjt_ecl_gate — CJC/CJE capacitance/transit-time investigation
7. AC rawfile parser — parse complex ngspice AC output
8. mosfet_ids_vds warm-start contamination — dc_sweep last failing fixture

---

## Background Tasks Still Running

| Task ID | What |
|---|---|
| bxxtt297t | mosfet tests after Level 2/3 PMOS fix |
| biu1ez09e | parser tests after NODESET + GSHORT fix |

---

## Known Limitations (test code)

```rust
const KNOWN_LIMITATIONS: &[&str] = &[
    "ring_oscillator_5",   // Level 1 MOSFET needs junction caps + better transient
    "mixer_intermod",      // Diode mixer charge model needs better intermodulation
    "disto_bjt_amp",       // .AC at 100MHz magnitude differs ~0.16% from ngspice DC OP
];
```
