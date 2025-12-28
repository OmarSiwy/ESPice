# NGSPICE compliance triage — cause list

From 2026-07-10 bench run. Three issue classes: CPU↔ngspice mismatch, CPU↔GPU
mismatch (different convergence path), scaling. Each cause below lists evidence
(file:line) and affected fixtures. Hypotheses from static analysis — verify
each before fixing.

Note: bench runner computed `gpu_accuracy` but never printed it
(runner.zig:197); gpu-max/gpu-rms/gpu columns now added. Re-run bench to get
actual GPU mismatch data before touching GPU causes.

## A. Analysis bugs (transient integrator)

| # | Cause | Evidence | Fixtures |
|---|-------|----------|----------|
| A1 | First step uses raw `dt_init`, overshoots first breakpoint — breakpoint clamp runs only AFTER an accepted step, so a 1 ns PULSE edge at t≈0 is skipped entirely | tran.zig ~:496 (clamp after accept), no pre-loop first-breakpoint adjust | fourier/square_harmonics (max 1.0), golden/four, digital/clamp |
| A2 | `nextBreakpoint` returns null for SIN/EXP/SFFM — no timestep steering on smooth sources, error accumulates over many cycles | vsource.zig:322-346 (only PULSE/PWL) | ngspice/sin_source, promote/long_tran, fourier/sine_1k |
| A3 | Trap promotion delayed: q_hist needs 2 accepted steps, so edges integrate with BE (order 1) exactly where accuracy matters | tran.zig:472 (`q_levels < 2`), :381 | digital/*, ngspice/tran_pulse, bypass/burst_clock |
| A4 | `effective_dt_max = min(dt_max, t_stop/50)` caps growth at fixture's tstep forever | tran.zig:369 | long transients generally |
| A5 | rc_ladder catastrophic error (max 9.99e-1) — suspect `.ic`/initial condition not applied, or wrong variable aligned in comparison | tran.zig:356-363 (no visible .ic path) | medium/rc_ladder_50, scaling/rc_chain_500 |
| A6 | Fourier fixtures never exercise four.zig — runner compares raw transient waveforms; failures above are transient causes, not post-proc | runner.zig compareRawFiles | fourier/*, golden/four |

## B. OP convergence (CPU fails, ngspice ok; GPU sometimes ok → path divergence)

| # | Cause | Evidence | Fixtures |
|---|-------|----------|----------|
| B1 | CPU Newton uses device limiting (pnjlim/fetlim), GPU JFNK disables it (`finalizeStep(..., false)`) — two entirely different globalization strategies. Whichever has the bug, they can never agree | converger.zig:163 vs :429, comment :218-220 | all CPU-only OpDidNotConverge: bsim4, hicum2, vbic_ce_amp/temp, bypass/*, ngspice/mosmem, rca3040, inverter_chain_1k |
| B2 | GPU solve bypasses gmin/source-stepping ladder in op.zig — ladder only wraps CPU Newton | op.zig:54-81, converger.zig:460-465 | GPU-side OpDidNotConverge (bsim2_ngspice, mos6_inverter, mosamp, inverter_chain_256) |
| B3 | No source stepping at all? ngspice falls back itl1→gmin→source stepping; verify zpicey ladder matches | op.zig:54-81 | ngspice/diffpair, mosamp, rca3040 |
| B4 | JFNK backtrack skips `applyLimits` sync (Newton path calls it) — stale device limit state | converger.zig:148-154 vs :300-303 | GPU-converged-but-wrong cases (need gpu-rms data) |
| B5 | diode_breakdown SingularMatrix — breakdown region stamp produces singular J (missing gmin on breakdown branch?) | diode impl | devices/diode_breakdown |

## C. Device models wrong vs ngspice

| # | Cause | Evidence | Fixtures |
|---|-------|----------|----------|
| C1 | S-switch: instant ron↔roff toggle; ngspice smooth-interpolates in VT±VH band | switch.zig:168-171 | devices/switch, switch_hysteresis (both max 9.99e-1) |
| C2 | W-switch control source lookup fails → MissingControlSource | netlist.zig ~:360 addBranchRef | devices/cswitch |
| C3 | Tline: zero-order-hold history lookup at t−td, ngspice interpolates | tline.zig:137-152 | devices/tline (4.97e-1) |
| C4 | Lossy tline: lumped pi-network approx + no interpolation vs ngspice LTRA convolution | lossy_tline.zig:221-254 | devices/lossy_tline (4.55e0) |
| C5 | Coupled tlines: device exists but 'P' letter never wired into letter_map | devices/src/root.zig:74-96 | devices/coupled_tlines (UnsupportedDevice) |
| C6 | K coupled inductors: mutual coupling sign / M=k·sqrt(L1L2) resolution suspect | kinduc.zig:58-71 | devices/kinduc (5.24e-1) |
| C7 | MOS1 (Shichman-Hodges) diverges from ngspice mos1: CLM formula (`lambda*vds_eff` vs `lambda*(vds-vdsat)`?) and/or body effect — same 4.65e-1 max at every replication count = systematic per-device error | mos1.zig:437-464 vs ngspice mos1load.c | scaling/parallel_inverters_* (all sizes, identical max), mos1_large_signal, mosfet/nmos_cs, ensemble/pvt_corners, ngspice/rtlinv, rc (RTL/MOS circuits) |
| C8 | MOS1 `mode = vds_raw/(vds_eff+1e-30)` → inf/NaN when vds_eff→0 in series-stacked inverter | mos1.zig:417 | mosfet/cmos_inverter (max = inf) |
| C9 | Big-model .op region divergence: bsim3/vbic/jfet/mesa fail at single .op bias while their _transfer/_gummel sweeps pass → wrong equations or wrong defaults in saturation/output region (jfet lambda, vbic parasitic PNP / thermal node, bsim3 Vth region) | bsim3.zig:789-990, vbic.zig:321-448, jfet.zig:211-289, mesa.zig | devices/bsim3, vbic, jfet, mesa*, hfet_inverter, b3soipd, b4soi, mos6_simpleinv, convergence/diode_bridge, adversarial/near_singular |

## D. Parser / elaboration

| # | Cause | Evidence | Fixtures |
|---|-------|----------|----------|
| D1 | `.param` values parsed but never substituted into device values — only subckt `.defaults` are; `C1 out 0 cval` silently becomes garbage | parser.zig:245-257, :878-880; netlist.zig:705-718, valueNumber :733-738 | parser/subckt_params (9.99e-1), parser/hspice_suffix (partial) |
| D2 | B-source: collectTerms only handles poly forms c0+c1·V+c2·V²; complex expressions mis-lowered or crash | netlist.zig:507-554 | ngspice/behavioral_bsrc (1.00e0) |
| D3 | fourbitadder "preflight failed" = first run crashed (runner.zig:128-135); nested 4-deep subckt expansion suspect — reproduce with binary for real error | parser.zig:847-908 | ngspice/fourbitadder |

## E. Scaling / performance

| # | Cause | Evidence | Fixtures |
|---|-------|----------|----------|
| E1 | ngspice/rc: 2.6 s / 78.5 MB vs 10 ms — waveform pre-alloc `16·t_stop/dt_init` capped at 4M points, plus likely millions of actual steps from A2/A4 (no dt growth). Also accuracy FAIL → same transient bugs | tran.zig:144-147 | ngspice/rc (260x slow) |
| E2 | Factorization every Newton iteration — tri/BBD/LU all refactor unconditionally, no reuse across iterations or steps | solvers/src/direct.zig:108-144 | scaling/*, medium/ladder_filter (0.2x) |
| E3 | GPU fixed ~230 ms launch overhead swamps small circuits (every fixture ~240 ms regardless of size) — expected; GPU only pays off at large N | — | all gpu/ng ≈ 0.1x rows |
| E4 | GPU preflight fails at 4k unknowns: `maxCoopBlocks` returns 0 → cooperative-launch/workspace ceiling; no adaptive GMRES m or fallback | gpu_solver.zig:59-72, gpu_abi.zig:92-105 (max_blocks=1024) | scaling/inverter_chain_4k |

## Suggested attack order

1. **D1** (.param substitution) — one bug, kills parser/subckt_params + contaminates any fixture using params.
2. **A1+A2** (breakpoints) — kills fourier/*, sin_source, tran_pulse, digital/* in one go.
3. **C7+C8** (mos1 audit vs ngspice mos1load.c) — kills all parallel_inverters, cmos_inverter inf, rtlinv, nmos_cs.
4. **B1/B2** (unify CPU/GPU convergence: limiting on both paths, gmin ladder wraps GPU too) — kills OpDidNotConverge cluster AND the CPU/GPU divergence class.
5. **C1-C6** (switch/tline/kinduc) — isolated device fixes.
6. **C9** big models one at a time (bsim3 → vbic → jfet → mesa), diffing .op internals against ngspice.
7. **E1/E2** perf after correctness — perf tuning on wrong numbers is wasted.
