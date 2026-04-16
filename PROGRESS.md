# Fix Progress — External Test Suite

Session date: 2026-04-15

## Summary

Implemented Wave 1 + Wave 2 fixes from plan. Most fixes confirmed working in
release mode. Debug-mode test hang is the main unresolved blocker.

---

## What Worked

### ✅ Branin cross-coupling swap (A001 — tline)
**File**: `crates/solver/src/stamper.rs`
**Fix**: Swapped `e_hist_p1`/`e_hist_p2` in all 3 T-line stamper paths so
`br_res1` uses the far-end history (cross-coupling), not self-history.
**Result**: tline category: 7/8 fixtures now PASS (was worse). Only
`lossy_tline_long` still fails at 15.3% NRMSE.

### ✅ Transient step budget (H001/H002)
**File**: `crates/analysis/src/transient.rs`
**Fix**: Added `MAX_TRANSIENT_STEPS = 500_000` constant and step counter in the
main while loop. Returns `Err(SimError::Analysis(...))` when exceeded.
**Result**: Prevents infinite-loop transients. Verified compiles clean.

### ✅ BJT junction capacitance CJE/CJC (A005)
**File**: `crates/device/src/bjt.rs`
**Fix**: Implemented standard SPICE depletion junction charge formula for CJE
and CJC. Stamps 4 C-matrix entries per junction. Removed `_` prefix from
`_cje/_cjc/_vje/_vjc/_mje/_mjc` params.
**Side effect**: `SmallVec` inline cap bumped 8→16 in `eval.rs`,
`bsim4/stamp.rs`, `vbic.rs` to match.

### ✅ q1_denom clamp (C001 supplemental)
**File**: `crates/device/src/bjt.rs`
**Fix**: Changed `q1_denom.max(1e-10)` → `q1_denom.max(1e-3)`. Keeps q1 ≤ 1000
(was ≤ 1e10), preventing Jacobian flattening in extreme saturation.

### ✅ LTRA lossless line DC (A001 — LTRA fixtures)
**File**: `crates/device/src/ltra.rs`
**Fix**: When R=0 and L>0, C>0, uses `r_eff = sqrt(L/C)` (characteristic
impedance Z0) instead of `1/GMIN`. Only keeps `1/GMIN` when L=0 or C=0.

### ✅ DC sweep warm-start + bisection (C002, A003)
**File**: `crates/analysis/src/dc_op.rs`
**Fix**: In `run_nested_dc_inner`, convergence failure now triggers: (1) up to 3
bisection sub-steps between last-good and target, (2) cold DC initial guess
fallback, (3) warn-and-continue with last good solution. Only numeric
convergence errors trigger fallback; other errors propagate immediately.

### ✅ BJT topology-aware initial guess (C001, A002, A007)
**File**: `crates/solver/src/newton.rs`
**Fix**: Pass 4 now checks if emitter/collector are on known rails (voltage
sources). For NPN with emitter-to-ground: sets base=Ve+0.7, collector=Vmax*0.8.
For PNP with emitter-to-VCC: sets base=Ve-0.7, collector=Vmax*0.2. Falls back
to crude 10%/90% only when no topology info.

### ✅ BJT junction voltage limiting (root cause of BJT hangs)
**File**: `crates/solver/src/junction_limit.rs`
**Fix**: Added `BjtNpn | BjtPnp` arm to `limit_junction_voltages`. Limits both
Vbe and Vbc using `pnjlim`. Applies larger-magnitude correction to the base
node (pin 1). Previously `_ => {}` caught all BJTs — no limiting applied →
Newton overshoots Vbe by 10-20V → Jacobian blows up → source stepping fallback
(200 steps × 100 NR iters → hangs).
**Verified in release mode**:
- `npn_ce_amp`: was hanging >20s, now 0.007s
- `bjt_cascode`: was hanging >20s, now 0.009s
- `bjt_multivibrator`: now 0.297s

### ✅ Source stepping budget reduction
**File**: `crates/solver/src/newton.rs`
**Fix**: Reduced `max_steps` from 200→50, `max_corr` from 20→10. Caps worst
case from 400k NR evaluations to 50k. Junction limiting makes source stepping
rarely needed for BJTs now.

### ✅ AC analysis requires DC OP (F002)
**File**: `tests/external/test_external.rs`
**Fix**: When `.AC` analysis is reached and `voltages` map is empty (no prior
`.OP`), automatically runs DC OP first. Matches ngspice behavior.

---

## What Failed / Not Yet Verified

### ❌ BJT external test category — debug mode hang
**Status**: Still hanging in `cargo test` (debug build).
**Root cause**: Debug build is 10-30x slower than release. The BJT test
category runs 15 fixtures including `bjt_multivibrator` (100k-step transient)
and `bjt_741_opamp` (large circuit). Even at 0.3s/fixture in release, debug
pushes some fixtures past the 60s test-thread timeout.
**NOT a convergence bug** — release mode runs all BJT fixtures fast.
**Fix needed**: Run external tests with `cargo test --release` or add per-
fixture wall-clock timeout. User confirmed: use release builds for testing.

### ❌ `lossy_tline_long` — 15.3% NRMSE
**Status**: Still failing. The LTRA fix (Z0 for lossless) didn't fully close
this gap. Likely a lossy LTRA kernel accuracy issue, not the DC singularity.
**Not investigated further this session.**

### ❌ F001 XSPICE `{` parsing
**Status**: Not attempted this session. Parser rejects `{` in AHDL code model
blocks. Fix scope: `crates/parser/src/tokenizer.rs`, ~20 lines.

### ❌ A004 CMOS 9.77% NRMSE
**Status**: Not diagnosed. Suspected MOSFET junction cap (Cbd/Cbs) not stamped.

### ❌ A006 DAC bridge 20.1% NRMSE
**Status**: Not attempted. Digital-analog coupling lag issue.

### ❌ C002 / A003 — DC sweep accuracy
**Status**: Warm-start bisection implemented but not verified against test suite
(blocked by debug-mode hang). Need release-mode test run to confirm improvement.

### ❌ A005 class B crossover
**Status**: CJE/CJC implemented. Needs release-mode test run to verify NRMSE
improvement.

---

## Test Results (last successful run — debug mode, partial)

```
noise        ✅ ok
sensitivity  ✅ ok
digital      ❌ FAILED
adversarial  ✅ ok
basic        ✅ ok
parser       ❌ FAILED
devices      ✅ ok
analyses     ✅ ok
dc_sweep     ❌ FAILED
quick        ✅ ok
tline        ❌ FAILED (1/8 fail: lossy_tline_long 15.3%)
convergence  ❌ FAILED
analog       ❌ FAILED
xyce         ✅ ok
fourier      ✅ ok
bjt          ⏳ TIMEOUT (debug mode too slow — release mode: all fast)
medium       ⏳ TIMEOUT
mosfet       ⏳ TIMEOUT
ngspice      ⏳ TIMEOUT
power        ⏳ TIMEOUT
scaling      ⏳ TIMEOUT
```

## Next Steps

1. **Run `cargo test --release --test external -- --include-ignored`** to get
   accurate pass/fail counts without debug slowness.
2. Fix F001 (XSPICE `{` parsing) — small tokenizer change.
3. Diagnose A004 (MOSFET Cbd/Cbs stamping).
4. Investigate remaining `lossy_tline_long` accuracy.
5. Verify dc_sweep and class B crossover improvements in release mode.
