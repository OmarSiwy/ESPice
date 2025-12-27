# Benchmark Accuracy Report

## Changes applied (2026-07-04)

1. **`if (limited) continue` in Newton/JFNK** — prevents declaring convergence when device limiting (pnjlim/fetlim) was active. Matches SPICE3f5 behavior. Fixed: `devices/urc` (FAIL→PASS).
2. **`dt_max = min(dt_max, t_stop/50)`** — SPICE2 heuristic, prevents astronomically large timesteps.
3. **BE-at-breakpoints + order promotion** — starts at backward Euler, promotes to configured method when LTE confirms stability, drops back to BE after source breakpoints. Suppresses trap companion ringing at PULSE/PWL edges.
4. **Fourier `dt_max = 1/(200*f_fund)`** — ensures ≥200 samples/period for FFT. Fixed: `fourier/sine_1k` error 0.83→0.024.

## 1. DC Operating Point (error = 1.00)

Still the #1 issue. The `if (limited) continue` fix prevents false convergence but doesn't help these circuits find the correct fixed point — they now correctly report non-convergence or converge to the same wrong solution.

**Still FAIL (1.00e0):** diff_pair, cascode, diode_bridge, cmos_inverter, parallel_inverters, gated_branch, mos1_large_signal, mos6_inverter, rtlinv, fourbitadder

**Root cause:** all-zeros initial guess + no supply-aware heuristic + no residual (KCL) check. Transfer sweeps pass because they warm-start from the previous point.

**Next fix:** supply-aware initial guess (set nodes connected to voltage sources to their DC value), and add `max|F(x)| < abstol` residual check alongside the update criterion.

## 2. Transient Integration

| Fixture | Before | After | Note |
|---------|--------|-------|------|
| golden/tran | PASS (1.72e-3) | PASS (1.80e-3) | Stable |
| bypass/idle_ladder | PASS (4.07e-3) | PASS (3.72e-3) | Improved |
| bypass/burst_clock | PASS (5.53e-3) | FAIL (1.23e-2) | **Regression** — BE steps at breakpoints less accurate than trap for this circuit |
| tran/rc_pulse | FAIL (4.36e-3) | FAIL (4.36e-3) | Unchanged |
| promote/long_tran | FAIL (6.82e-3) | FAIL (6.82e-3) | Unchanged |
| digital/buffer_rc | FAIL (3.70e-3) | FAIL (6.71e-3) | **Regression** |
| digital/clamp | FAIL (3.20e-2) | FAIL (1.24e-1) | **Regression** |
| digital/rc_filter_chain | FAIL (1.19e-2) | FAIL (4.37e-2) | **Regression** |

**Regressions:** BE-at-breakpoints uses order-1 (BE) after each PULSE edge. BE has O(h²) LTE vs trap's O(h³). For circuits with many edges and tight tolerances, the extra BE steps degrade accuracy. The order-promotion threshold (`trial_dt > 1.05 * dt`) may be too conservative — trap isn't restored quickly enough after the edge passes.

**Root cause of remaining failures:** `lte_tol = 1e-3` allows too much per-step error for multi-cycle simulations, but tightening it triggers the variable-step trapezoidal companion current oscillation (`i_prev` recursion `i_n = α·Δq - i_{n-1}` has no numerical dissipation). This is the fundamental trap stability issue; ngspice mitigates it with XMU damping (default 0.5 = undamped, but users set 0.495–0.499).

## 3. Fourier

| Fixture | Before | After | Note |
|---------|--------|-------|------|
| fourier/sine_1k | FAIL (8.26e-1) | FAIL (2.42e-2) | **34x better** — dt_max fix gives dense samples |
| fourier/clipped_sine | FAIL (7.21e-1) | FAIL (5.53e-2) | **13x better** |
| golden/four | FAIL (9.76e-1) | FAIL (8.74e-2) | **11x better** |
| fourier/square_harmonics | FAIL (1.00e0) | FAIL (1.00e0) | Unchanged (likely comparison methodology) |

Fourier is dramatically better but still FAIL. Remaining error sources:
- `.four` directive not handled in `engine.zig:buildJob()` — benchmark compares transient waveforms, not harmonic tables
- No `tstep` output interpolation — zpicey outputs at raw adaptive steps, ngspice at uniform intervals
- square_harmonics: the 1.00e0 error suggests a comparison issue (ngspice may output different harmonic normalization)

## 4. Scaling

| Fixture | Before | After | Note |
|---------|--------|-------|------|
| resistor_grid (DC) | PASS | PASS | All sizes pass |
| rc_ladder_1k/10k/100k | FAIL (6.55e-2) | FAIL (6.55e-2) | Unchanged — same error at all sizes |
| rc_chain_500 | FAIL (1.00e0) | FAIL (1.00e0) | Wrong OP, not transient |
| parallel_inverters | FAIL (0.70) | FAIL (0.70) | Wrong OP (MOS1 switching threshold) |

rc_ladder error is constant across sizes → the error is at the driven end's PULSE edge, independent of chain length. The `dt_max = t_stop/50` doesn't help because these circuits already had user-specified tight timesteps.

## 5. Device-Level

**New PASS:** `devices/urc` (was FAIL 5.24e-1, now PASS 1.69e-6) — the `if (limited) continue` fix allowed the Newton solver to find the correct operating point instead of declaring false convergence at a limiter-forced value.

**Still FAIL:** bjt_npn (2.49e-2), bjt_pnp (1.00e0), vbic (2.36e0), hicum2 (2.84e0), bsim3 (8.67e-1), jfet (1.02e-1), switch (8.61e-1), tline (4.97e-1), lossy_tline (4.55e0), kinduc (5.24e-1)

## Summary of root causes (updated priority)

1. **Wrong DC operating point** — ~20 fixtures. Needs supply-aware initial guess + residual check. The `if (limited) continue` fix is necessary but not sufficient.
2. **Transient: trap companion stability** — the i_prev recursion oscillates with variable step. BE-at-breakpoints helps for startup but regresses some edge-heavy circuits. Needs XMU damping or tighter LTE with oscillation suppression.
3. **Fourier comparison methodology** — dt_max fix dramatically improved accuracy but benchmark still compares raw waveforms, not harmonic tables. Missing `.four` handler in engine.
4. **Transmission line model** — 1e30+ errors = numerical blowup. Separate issue.
5. **Device model correctness** — bjt_npn (2.49e-2), hicum2 (2.84e0) etc. may be model parameter or equation bugs.
