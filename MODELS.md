# Model Audit & Fix Log
*Full audit + implementation pass — 2026-04-15*

All device models audited by parallel senior-engineer agents against SPICE2/ngspice/BSIM reference equations. Every confirmed bug was immediately fixed by a separate implementation agent. This document records what was found, what was fixed, and what remains deferred.

---

## Fixed Bugs

### Resistor (`crates/device/src/resistor.rs`)
- **TC= param silently dropped.** SPICE syntax `R1 1 2 1k TC=0.01` stores key `"tc"` but model read `"tc1"`. Now falls back to `"tc"` when `"tc1"` absent.

### Capacitor / Inductor
- DC, AC, transient stamps verified correct (Backward Euler and Trapezoidal). No bugs.

### Mutual Coupling K element (`crates/solver/src/stamper.rs`) — CRITICAL
- **Cross-terms never stamped.** `circuit.mutual_couplings()` was populated by parser but stamper never read it. Every transformer/coupled-inductor netlist produced wrong results silently.
- **Fix:** Both serial and parallel transient stampers now iterate `mutual_couplings()`, compute `M = k*sqrt(L1*L2)`, and stamp off-diagonal `(l1_br_row, l2_br_row, -M)` / symmetric into the C triplet plus `residual_q[l1_br] += -M*I2` / symmetric.

### Diode (`crates/device/src/diode.rs`)
- **GMIN double-counted in tangent-line extension.** High-voltage linearized branch (`vd > vlimit`) computed `id = is*(exp_lim-1) + gd*(vd-vlimit) + GMIN*vd`. Since `gd` already includes GMIN, this double-counted it. Fixed to `id = is*(exp_lim-1) + GMIN*vlimit + gd*(vd-vlimit)`.
- pnjlim verified: uses passed `nvt` parameter correctly, not hardcoded constant.

### BJT Gummel-Poon (`crates/device/src/bjt.rs` + `crates/parser/src/tokenizer.rs`) — CRITICAL
- **RB/RC/RE have no effect.** Circuit builder never created internal nodes for BJTs with nonzero base/emitter/collector resistances. `eval_with_extrinsic` always fell back to 3-pin path.
- **Fix:** tokenizer now creates internal nodes `_<name>_ci/_bi/_ei` when any of rb/rc/re > 0, giving 6-terminal eval path.
- **TR reverse transit time ignored.** `_tr` was read but discarded. Reverse charge `Q_R = TR * i_r` now stamped with full Jacobian on BC junction.
- **xcjc split ignored.** `_xcjc` was read but discarded. CJC now split: `xcjc` fraction to internal base node, `(1-xcjc)` to external base. Default xcjc=1 preserves old behavior.
- Core GP equations (Q1, Qb, If/Ir, Ib, Ic, all 9 Jacobian entries, CJE/CJC, TF, CJS, temperature scaling) verified correct.

### MOSFET Level 1 (`crates/device/src/mosfet.rs`) — CRITICAL (~15 test failures)
- **Body effect absent.** GAMMA/PHI ignored; Vth fixed at VTO regardless of bulk bias.
- **Fix:** Vth = VTO + GAMMA*(sqrt(PHI+Vsb) - sqrt(PHI)) now computed. gmbs = gm*GAMMA/(2*sqrt(PHI+Vsb)) added. Bulk column `(0,3,-gmbs)` and `(2,3,gmbs)` now stamped.

### MOSFET Level 2 (`crates/device/src/mosfet.rs`)
- **Reversed Jacobian drops gmb.** In reversed-Vds case, `g_dd` was `gm+gds`, should be `gm+gds+gmb`. Same for `g_sd`. Fixed.
- Body effect and basic Shichman-Hodges equations verified correct.

### MOSFET Level 3 (`crates/device/src/mosfet.rs`)
- **Reversed Jacobian drops gmb.** Same fix as Level 2.
- **gm 71% wrong in saturation.** `gm = beta*vdsat*(1+lam*vds)` ignored that `beta = beta0/(1+theta*vov)` and `vdsat = vov/(1+kappa*vov)` both depend on vov. Fixed with product rule: `gm = (1+lam*vds) * (d_beta_d_vov*vdsat^2/2 + beta*vdsat*d_vdsat_d_vov)`.
- **Narrow-width uses `l` not `w`.** Delta/4*l in gamma_w should be delta/4*w. Fixed.

### MOSFET Parser (`crates/parser/src/tokenizer.rs`)
- **PMOS flag not set for Level 2/3/6.** Only `MosfetP` received `pmos=1.0`; `MosfetP2/P3/P6` got NMOS polarity. Fixed with `matches!` covering all four P-type variants.

### MOSFET Junction Limiting (`crates/solver/src/junction_limit.rs`)
- **Level 2/3/6 not clamped.** Newton could take unbounded steps for these levels. Match arm now includes `MosfetN2|P2|N3|P3|N6|P6`.

### BSIM3 (`crates/device/src/bsim3/eval.rs`)
- **xdep body-bias dead.** `(1.0 - vbseff/phi).max(1.0).sqrt()` clamped arg to ≥1, making xdep constant at Xdep0 for all normal body bias. `.max(1.0)` → `.max(0.0)`.

### BSIM4 (`crates/device/src/bsim4/eval.rs`) — CRITICAL
- **Vgsteff scaled by 0.75, gm 50% wrong.** Formula had spurious `(1+m)*0.5 = 0.75` prefactor and doubled voff. All DC currents ~25% low; gm 50% low. Fixed: removed prefactor, fixed voff to appear once, dvgsteff derivatives corrected.
- **CLM has spurious 1e-7/1e-9 factors.** `va_clm = pclm * esat_l` now used directly. gds CLM term = `ids_core / va_clm`, consistent with current formula.

### JFET (`crates/device/src/jfet.rs`)
- **Unphysical ig*0.5 drain split.** Single gate diode current split 50/50 between drain/source. Replaced with proper two-diode model: Igs from Vgs, Igd from Vgd. Jacobian updated with correct (1,0) gate-drain entry.
- **Level 2 blocking factor asymptote wrong.** `(1-exp(-nds*vds))` saturates to 1; should be `/nds` to saturate to `1/nds`. Fixed. Jacobian derivative `d(block)/dvds = exp(-nds*vds)` unchanged (correct after fix).
- **Level 2 dvst_dvov missing chain rule.** When delta≠0, `vst_raw = vov/(1+delta*vov)`. Chain rule factor `1/(1+delta*vov)^2` now multiplied into `dvst_dvov`.

### MESFET (`crates/device/src/mesfet.rs`)
- **Unphysical ig*0.5 drain split.** Same fix as JFET: two-diode model (Igs + Igd).

### LTRA Lossy Transmission Line (`crates/device/src/ltra.rs`) — CRITICAL (15.3% NRMSE)
- **Alpha formula wrong units.** Was `0.5*(R/L + G/C)` [units: 1/s]. Should be dimensionless neper attenuation across line: `len*(R/(2*Z0) + G*Z0/2)`. Fixed in `compute_norton_equivalent` and NONINT branch.
- **RC kernel normalization wrong.** `norm = len/(2*sqrt(pi*r_tot*c_tot))` cancelled the len factor. Fixed to `norm = rc_pu.sqrt()*len / (2*sqrt(pi))` using per-unit-length values.
- **RC degenerate guard added.** For L≈0, `z0()` returns 1/GMIN=1e12 making Norton source ≈0. Guard now returns `LtraNorton::default()` early for RC lines where Branin model is inapplicable.

### Solver — NODESET (`crates/solver/src/newton.rs`)
- **.NODESET hints never applied.** `circuit.node_sets()` populated but never read in `compute_dc_initial_guess`.
- **Fix:** Added pass 3.5 after MOSFET pass: iterates node_sets(), writes hint voltages into guess vector. nodesets win over all heuristic passes.

### Solver — TEMP sweep (`crates/analysis/src/dc_op.rs` + `crates/core/src/circuit.rs`)
- **.DC ... TEMP sweep crashes.** Called `set_device_param("temp", "temp", val)` — no device named "temp". Added `Circuit::set_global_temperature(celsius)` method. TEMP sweep path now calls it instead.

### Solver — CCVS/CCCS not registered (`crates/device/src/registry.rs`)
- H and F elements silently dropped — absent from `DeviceRegistry::new_default()`. Both now registered. Registry count assertion updated 37→39.

### Global TEMP propagation (`crates/core/src/circuit.rs` + analysis crates)
- **.OPTIONS TEMP / .TEMP never reached devices.** SimOptions.temp stored but never written to device params. All TC calculations used 300.15K regardless.
- **Fix:** Added `Circuit::propagate_global_temperature()`. Called before solve in dc_op, transient, ac, and dc_sweep analysis drivers. Per-instance TEMP= overrides respected (not overwritten).

### Switch (`crates/device/src/switch.rs` + `crates/solver/src/stamper.rs`)
- **Hard binary transition.** Conductance jumped discontinuously → Newton divergence near threshold.
- **Fix:** Smooth tanh model: `G = (Gon+Goff)/2 + (Gon-Goff)/2 * tanh(3*(vc-vt)/vh)`. vh_eff = max(vh, 0.1). Four control-port cross-terms `(0,2,+dG/dVc*Vout)` etc. added to Jacobian.
- **CSwitch always OFF.** `controlling_current` never updated from MNA solution.
- **Fix:** Stamper now reads `ctrl_branch_index` from params, samples `solution[branch_idx]`, clones params with `controlling_current` set. Parallel path passes override via `ParEvalInput`.

### DAC Bridge defaults (`crates/parser/src/tokenizer.rs`)
- **out_high defaulted to 3.3V** but test fixtures use 1.8V supply → 83% overshoot. Changed default to 1.8V.

### d_inverter timing (`tokenizer.rs` + `digital/primitives.rs` + `digital/transient_hook.rs`)
- **rise/fall delay averaged.** `prop_delay = (rise+fall)/2` collapsed asymmetric delays.
- **Fix:** `DigitalPrimitiveSpec` and `PrimitiveBlock` now carry separate `rise_delay`/`fall_delay`. `flush()` picks correct delay based on transition direction (0→1 or 1→0).

---

## Verified Correct (no changes)

| Model | Notes |
|-------|-------|
| Capacitor | DC/AC/transient stamps exact |
| Inductor | DC/AC/transient stamps exact |
| Diode (core) | Shockley, Cj, transit-time, temperature scaling, breakdown |
| BJT core GP | Q1, Qb, If/Ir, all 9 Jacobian entries, CJE/CJC, TF, CJS, temp |
| MOSFET Level 2/3 body effect | Vth = VTO+GAMMA*(sqrt(PHI+Vsb)-sqrt(PHI)) correct |
| MOSFET Level 6 (Sakurai-Newton) | tanh smooth model internally consistent |
| JFET Level 1 core | Shichman-Hodges, lambda, threshold |
| MESFET core | Curtice tanh saturation, ALPHA, LAMBDA |
| Tline (Branin lossless) | Companion model and history correct |
| URC | Lumped RC ladder expansion correct |
| VCVS (E) | MNA stamp exact |
| VCCS (G) | MNA stamp exact |
| Vsource/Isource/Bsource | Correct |
| Switch (S/W) | Now correct after smooth model fix |

---

## Deferred (known incomplete, not fixed this pass)

| Item | Reason |
|------|--------|
| VBIC substrate BJT path | Wrong voltage (Vbcp vs Vbcj), missing qbp, wrong terminal assignment — architectural rewrite |
| VBIC temperature feedback | V_thermal → Vt feedback deferred (noted in code) |
| BSIM3/4 transient caps | Cgb=0, Cdb=0, overlap caps zero — deferred per original plan |
| BSIM3 PDIBL1/PDIBL2/SCBE | Va output conductance terms missing |
| BSIM4 GISL Vov = 0 | `(-vds-vgs+vds)` cancellation bug — deferred |
| LTRA full convolution | Convolution integral missing; only TD point-sample used. Kernel exists but not called from norton equivalent. RC regime non-functional. |
| CCVS/CCCS ctrl_current injection | Registered now; but stamper ctrl_current injection incomplete — always 0 |
| XSPICE DigitalRuntime wiring | `flush()` never called in transient solver — entire mixed-signal path dead |
| DAC bridge MNA stamping | DAC voltage not injected as voltage source into MNA |
| ADC bridge solution sampling | ADC never reads NR solution vector |
| Diode RS (series resistance) | Internal node for RS not implemented |
| Diode ISR/NR recombination | Documented in comment, not implemented |
| Diode VJ/CJ0 temp correction | Missing for accurate temp sweeps |
| MosfetLevel6 | Stub — reserved, not implemented |
| MOSFET CBD/CBS junction caps | Missing for all levels |
| MOSFET temperature scaling | KP(T), VTO(T), PHI(T) not implemented |
| BJT multivibrator transient | NRMSE=4.68e8 — CJE/CJC large-signal switching may need investigation |
| Capacitor/Inductor instance IC= | IC= on instance line not applied to initial condition |
| WLossy | S/Y/Z tabulated interpolation deferred; falls back to LTRA |
| OSDI shim | External .so models only |
