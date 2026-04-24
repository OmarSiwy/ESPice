# Document 6: Feature Comparison — BigOSpice vs ngspice

**Date:** 2026-04-21 | **Version:** 1.0

---

## 1. Analysis Types — Complete Comparison

### DC Domain

| Analysis | ngspice | BigOSpice | Algorithm Comparison | Pipeline Details |
|----------|---------|-----------|---------------------|-----------------|
| **DC Operating Point** | `CKTop()` | `dc_op::run()` | **ngspice:** NR with MODEINITJCT→MODEINITFIX→MODEINITFLOAT mode transitions. Fallback: GMIN stepping (dynamic 10x reduction) → source stepping (dynamic alpha) → pseudo-transient (supplementary capacitance + ramp). **BigOSpice:** NR with 5-pass topology-aware initial guess. Fallback: GMIN stepping (scheduled [1e-2, 1e-3, 1e-4, 0] + divergence detection with sub-stepping) → source stepping (uniform + bisection) → DC initial guess retry → homotopy continuation → pseudo-transient (C/dt exponential growth). BigOSpice has 2 additional fallback levels and a smarter initial guess. | Both: Stamp MNA matrix → LU factor → solve → check convergence → loop. BigOSpice adds cache-aware stamping (dirty devices only). |
| **DC Sweep** | `DCtrCurv()` | `dc_sweep::run()` | **ngspice:** Iterate source value linearly, warm-start from previous point. Single-variable only (nested requires `.control` scripting). **BigOSpice:** LIN/DEC/OCT sweep, warm-start + cache-aware. Ascending/descending with direction validation. Nested 2-variable DC sweeps supported natively. Bisection fallback if convergence fails mid-sweep. | ngspice: For each sweep point: modify source → full CKTload → full refactor → solve. BigOSpice: For each sweep point: modify param → mark dirty → eval dirty only → Woodbury or refactor → solve. |

### Frequency Domain

| Analysis | ngspice | BigOSpice | Algorithm Comparison | Pipeline Details |
|----------|---------|-----------|---------------------|-----------------|
| **AC Small-Signal** | `ACan()` | `ac::run()` | **ngspice:** Complex Y(jω) = G + jωC matrix. Complex LU factorization. Complex forward/back solve. Stores complex voltage phasors. **BigOSpice:** 2N×2N real block system: [G, -ωC; ωC, G]. Real LU factorization (no complex arithmetic). Extract magnitude/phase from real/imag solution blocks. | ngspice: True complex arithmetic → complex sparse matrix → complex LU. BigOSpice: Real block form → larger matrix but only real arithmetic → simpler LU code, SIMD-friendly. Both produce identical results. |
| **Noise** | `NOISEan()` | `noise::run()` | **Both:** Linearize at DC OP → for each frequency and noisy device: compute PSD S_i(f), inject unit current, solve AC system, accumulate |V|²×S_i(f). **ngspice:** Per-device noise in DEVnoise(). **BigOSpice:** Per-device noise models centralized. Models: thermal (4kT/R), shot (2qI), 1/f flicker. BigOSpice adds per-device contribution breakdown and explicit input-referred noise computation. | Both: Full AC solve per device per frequency point. O(n_freq × n_noisy_devices) AC solves. Computationally expensive for large circuits. |
| **S-Parameters** | Via XSPICE or manual scripting | `sp::run()` | **ngspice:** No native S-parameter analysis. Must set up port terminations manually, run AC, compute wave variables externally. **BigOSpice:** Native N-port wave-variable computation. For each frequency and port p: add termination conductances to non-driven ports, excite port p with 1A test current, solve AC system, compute S_ip = b_i/a_p from wave variables a = (V+ZI)/2√R, b = (V-ZI)/2√R. | BigOSpice: N AC solves per frequency (one per port). Differential and single-ended ports supported. Configurable port impedances (default 50Ω). Output: complex S-matrix [freq][row_port][col_port]. Touchstone output built-in. |

### Time Domain

| Analysis | ngspice | BigOSpice | Algorithm Comparison | Pipeline Details |
|----------|---------|-----------|---------------------|-----------------|
| **Transient** | `DCtran()` | `transient::run()` | **Integration methods:** ngspice: Trapezoidal (default, XMU=0.5) + Gear BDF orders 2-6 (MAXORD default 2). BigOSpice: Backward Euler + Trapezoidal + Gear BDF orders 2-5. ngspice has BDF-6; BigOSpice adds explicit Backward Euler. **Timestep control:** ngspice: Per-device DEVtrunc() proposes dt from LTE. TRTOL=7 fudge factor. Min(all proposals). Breakpoint-aware. BigOSpice: Similar LTE-based adaptive stepping. Companion model discretization matches ngspice formulation. **Digital integration:** ngspice: XSPICE event-driven engine (separate EVTqueue). BigOSpice: DigitalRuntime hook — flush events before each NR step, rollback on NR failure. | Both: DC OP → time loop: update integration coefficients → NR iterations → LTE check → accept/reject → advance time. BigOSpice adds: LTRA history management, checkpoint storage, digital bridge flushing. |

### RF/Microwave (BigOSpice Exclusive)

| Analysis | ngspice | BigOSpice | Algorithm Details | Pipeline Details |
|----------|---------|-----------|-------------------|-----------------|
| **Harmonic Balance** | **Not available** | `hb::run()` | **Single-tone:** User specifies f0 and K harmonics. Newton-Raphson on frequency-domain residual: F(V) = Y_lin(jω)·V + I_NL(V) - I_src = 0. IDFT V to time domain → evaluate nonlinear devices at each sample → DFT nonlinear currents back → Newton step. **Two-tone:** Box truncation of mixing products m·f1 + n·f2. APFT (Almost-Periodic FFT) for collision-free DFT via Kundert frequency-mapping. **N-tone:** Generalized box truncation with arbitrary fundamentals. | SoA data layout: parallel real/imag vectors per node per harmonic. Newton convergence on harmonic coefficients. Typical: 5-15 NR iterations per HB solve. |
| **Periodic Steady-State** | **Not available** (must use long transient) | `pss::run()` | Shooting method: (1) Integrate one period T = 1/f_fund. (2) Shooting residual: F(x0) = x(T) - x0. (3) Newton on shooting residual with monodromy Jacobian via finite differences. (4) Converge when ||F||∞ < tolerance. Error presets: Liberal (1e-4), Moderate (1e-6), Conservative (1e-9). | O(n) transient runs per Newton step. Typically 3-8 shooting iterations. Much faster than running long transient until steady-state (which may take 100+ periods). |
| **Envelope Following** | **Not available** | `envelope::run()` | Decouples fast carrier (HB at f_carrier) from slow envelope modulation. At each envelope time t_env: evaluate time-varying sources → run HB solve at carrier frequency with warm-start from previous step → record DC + fundamental magnitude. Step forward in envelope time. | Use case: PLLs, switched-supply loops, RF mixers with AM/FM modulation. Avoids simulating every carrier cycle — only envelope dynamics. |

### Analysis and Extraction

| Analysis | ngspice | BigOSpice | Algorithm Comparison | Pipeline Details |
|----------|---------|-----------|---------------------|-----------------|
| **DC Sensitivity** | `SENSitivity()` | `sensitivity::run()` | **ngspice:** Adjoint method — solve one additional system per output (efficient when few outputs, many parameters). **BigOSpice:** Forward finite difference — perturb each parameter individually, re-solve DC OP. h = max(1e-8, 1e-3×|p|). Less efficient than adjoint for many-parameter/few-output case, but simpler and more robust. Computes absolute and relative sensitivities. | ngspice: O(n_outputs) adjoint solves. BigOSpice: O(n_parameters) forward solves. ngspice is better for few outputs, many params. BigOSpice is better for many outputs, few params (or comparable). |
| **AC Sensitivity** | **Not built-in** | `sens_ac::run()` | **BigOSpice exclusive.** Forward FD-perturbed AC sweep at each frequency. Baseline AC sweep → perturbed AC sweep with p+h → compute d|V|/dp and dphase/dp per frequency. | O(n_params × n_freq) AC solves. Computationally expensive but provides crucial information for robust analog design. |
| **Pole-Zero** | `PZan()` | `pz::run()` | **ngspice:** Muller's method — iterative root finder that locates individual poles/zeros one at a time. Can miss closely-spaced poles. **BigOSpice:** QR iteration on state matrix A = -C⁻¹G (with Tikhonov regularization for singular C). Finds ALL poles simultaneously. In-house dense eigensolver for circuits up to ~64 nodes. | ngspice: Sequential pole finding, can miss poles. BigOSpice: Full eigenvalue decomposition, finds all poles at once but limited to smaller circuits (dense eigensolver). |
| **Transfer Function** | `TFan()` | `tf::run()` | **Both:** Compute DC gain dV(out)/dV(in), input impedance Zin, output impedance Zout. Single LU factorization of G matrix, three different RHS vectors. | Identical approach: one factorization, three solves. Same results. Negligible performance difference. |
| **Distortion** | `DISTOan()` | `disto::run()` | **Both:** Volterra-series kernels. Solve AC at kernel frequencies (2f1, 3f1, f1±f2, 2f1±f2). Combine with Taylor coefficients (a2, a3) of dominant nonlinearity. Output: HD2, HD3, IM2, IM3 ratios relative to fundamental. | Same algorithm. Both solve linearized systems at harmonic frequencies and combine with nonlinear coefficients. |

### Spectral Analysis

| Analysis | ngspice | BigOSpice | Algorithm Comparison |
|----------|---------|-----------|---------------------|
| **Fourier (.FOUR)** | `.FOUR` command | `fourier::run()` | **Both:** Extract harmonics from transient waveform via DFT. **ngspice:** Direct DFT on last period, harmonics 1-9. **BigOSpice:** Same + automatic resampling to uniform grid (1024+ points) + THD computation. |
| **FFT** | `spec` command in nutmeg (post-processing) | `fft::run()` | **ngspice:** Post-processing command, not an analysis. Requires transient data in memory. **BigOSpice:** Built-in analysis type. In-place radix-2 Cooley-Tukey. Window functions: Rectangular, Hanning, Hamming, Blackman, Kaiser. Auto zero-pad to power-of-2. Single-sided spectrum with coherent-gain normalization. |

### Statistical Analysis

| Analysis | ngspice | BigOSpice | Algorithm Comparison | Pipeline Details |
|----------|---------|-----------|---------------------|-----------------|
| **Monte Carlo** | Via `.control` scripting only | `mc::run()` | **ngspice:** No built-in MC. Users write `.control` loops: `foreach sample 1 .. 1000 ... end`. Manual parameter randomization via `gauss()`. No DEV/LOT matching. No deterministic seeding. **BigOSpice:** Built-in `.MC` directive. DEV mode (independent draws per override per sample). LOT mode (grouped draws by lot_tag for model-level matching). Sample 0 = nominal (deterministic baseline). Deterministic PRNG seeding: (seed, sample_idx) → reproducible regardless of execution order. SoA output: values[sample × num_measures + measure]. | BigOSpice MC leverages cache: topology unchanged across samples → symbolic LU reused. Only varied devices dirty → minimal re-evaluation. ~10-50x faster than ngspice scripted MC. |
| **Worst Case** | Via `.control` scripting only | `wcase::run()` | **BigOSpice exclusive (built-in).** Deterministically enumerates ±k·σ corners. Extreme strategy: all overrides at +k together, all at -k → 3 corners. OneAtATime: perturb each individually ± k → 2n+1 corners. Cheap, conservative, not statistically realistic. | 3 or 2n+1 simulations vs 1000+ for MC. Each leverages cache. |
| **Latin Hypercube** | **Not available** | `sampling::run()` | **BigOSpice exclusive.** Quasi-MC with better multi-dimensional coverage. Divide each parameter dimension into N equal-probability intervals. Draw exactly one sample per interval per dimension (stratified). Permute assignments independently. √N faster convergence than pure MC for smooth response surfaces. | Same cache benefits as MC. Better coverage with fewer samples. |

### Meta/Control

| Feature | ngspice | BigOSpice | Comparison |
|---------|---------|-----------|------------|
| **Parameter Sweep (.STEP)** | `.STEP` limited to source DC values | `sweep::run()`: LIN/DEC/OCT/LIST/DATA on any .PARAM or device parameter | BigOSpice sweeps arbitrary parameters. ngspice requires `.control alter` for device params. |
| **Measurements (.MEAS)** | `.MEAS` in `.control` blocks. FIND/WHEN/TRIG-TARG + reductions. | `measure::run()`: same syntax. FIND/WHEN (AT, RISE, FALL, CROSS) + TRIG-TARG + AVG/RMS/MAX/MIN/PP/INTEG/DERIV. AC-specific: VM, VDB, VR, VI, VP. Power: P(device). Binary expressions: signal1 ± × ÷ signal2. | Equivalent capability. BigOSpice adds AC-specific and power measurements natively. |
| **Control Scripting** | `.control`/`.endc` with full nutmeg: let, set, if/else, while, foreach, repeat, define, source, echo, print, run, op, dc, ac, tran, alter, write, wrdata. | `control::interpret()`: Same command set. if/else/end, while/end, foreach/end, repeat N/end, define, let, set, unset, echo, print, run, op, dc, ac, tran, alter, source, wrdata, write, meas. | Similar capability. ngspice has richer nutmeg vector math. BigOSpice covers the core scripting features. |
| **Runtime Modification (.ALTER)** | Via `.control alter device param value` | `alter::apply()`: Built-in `.ALTER` directive + runtime device/model param changes between analyses | BigOSpice supports .ALTER as a directive, not just a control command. |

---

## 2. Device Model Support — Detailed Comparison

### Passive Components

| Device | ngspice | BigOSpice | Detailed Comparison |
|--------|---------|-----------|---------------------|
| **Resistor** | R with TC1/TC2 + semiconductor model + noise (thermal 4kT/R) | R with TC1/TC2 + temperature scaling R(T)=R0×(1+TC1×ΔT+TC2×ΔT²) | ngspice has semiconductor resistor model (sheet resistance). BigOSpice covers standard analog R. |
| **Capacitor** | C linear + voltage-dependent (C0+VC1×V+VC2×V²) + semiconductor (area/perimeter models) | C linear: Q = C×V, no DC current, charge-based for transient | ngspice has more capacitor models (voltage-dependent, semiconductor). BigOSpice covers standard linear C. |
| **Inductor** | L linear + mutual coupling (K element) + core saturation | L linear + mutual coupling (K element) + flux-based for transient | Similar core capability. ngspice has core saturation model. |
| **Mutual Inductance** | K element: `K1 L1 L2 0.99` | MutualCoupling: couples two inductors via coefficient k | Equivalent. |

### Diodes

| Device | ngspice | BigOSpice | Detailed Comparison |
|--------|---------|-----------|---------------------|
| **Diode** | Level 1 (Shockley) + Level 3 (improved) + junction capacitance (Cj0, Vj, Mj, fc) + transit time + breakdown (BV, IBV) + noise (shot + 1/f) + temperature (XTI, EG) | Shockley + Zener: I=Is×(exp(V/(N×Vt))-1) + Isr×(exp(V/(Nr×Vt))-1) + BV/IBV breakdown + junction caps (Cj0, Vj, Mj, fc) + transit time (tt) + area/M scaling + temperature (tnom, temp, XTI) | Similar. ngspice Level 3 adds some corrections. Both have complete junction cap and temperature models. |

### Bipolar Transistors

| Device | ngspice | BigOSpice | Detailed Comparison |
|--------|---------|-----------|---------------------|
| **BJT (Gummel-Poon)** | Full GP model: If, Ir, base charge factor (Early + Webster), recombination leakage, substrate diode, resistances (rb, re, rc), transit time, capacitances (Cje, Cjc), noise (shot + 1/f + base resistance thermal). Level 1 (simplified EM) + Level 2 (VBIC). | Level 0 (simplified Ebers-Moll: no Early, no high-injection, no leakage) + Level 1 (full Gummel-Poon: If, Ir, base charge factor, recombination leakage, terminal currents). Core params: Is, Bf/Br, Vaf/Var, Ikf/Ikr, Ise/Isc, Ne/Nc, transit time, caps. Temperature (xtb, eg, xti). Resistances accepted but deferred. | BigOSpice Level 1 is functionally equivalent to ngspice default GP. Missing: substrate diode, parasitic resistance stamping (deferred to Phase 2). |
| **VBIC** | Full VBIC4 (Vertical Bipolar Inter-Company): parasitic substrate, self-heating, avalanche multiplication, excess phase. | VBIC basic implementation: available but underutilized. | ngspice VBIC is more complete. |
| **MEXTRAM** | Full MEXTRAM 504 (Most EXquisite TRAnsistor Model) | **Not available** | ngspice exclusive. |
| **HICUM** | HICUM/L2 (High-Current Model): transit time at high current densities, self-heating, NQS effects. | **Not available** | ngspice exclusive. |

### MOSFETs

| Device | ngspice | BigOSpice | Detailed Comparison |
|--------|---------|-----------|---------------------|
| **Level 1** | Shichman-Hodges: Id = Kp×(Vgs-Vth)²×(1+λ×Vds). Basic parabolic model. | Same: Id = Kp×W/L×(Vgs-Vth)²×(1+lambda×Vds). Cutoff/linear/saturation regions. | Equivalent. |
| **Level 2** | Improved S-H: velocity saturation, body effect, short-channel effects. | Implemented with velocity saturation and body effect. | Similar. |
| **Level 3** | Semi-empirical short-channel: empirical mobility, narrow-width corrections. | Implemented. | Similar. |
| **Level 6** | MOS6 model. | Implemented with advanced effects. | Similar. |
| **BSIM3v3** | ~500 parameters. Threshold-voltage based. W/L binning. Process corner support. | Full BSIM3v3.3 port: DC current path (Vth, mobility degradation, Vdsat, CLM/DIBL/SCBE, Isub), Jacobian stamping, temperature scaling, W/L binning. Cold/warm/hot tier data layout. | Functionally equivalent. BigOSpice BSIM3 uses data-oriented 3-tier architecture (cold params → warm instance → hot eval). |
| **BSIM4v7/v8** | BSIM4.7 (latest in ngspice): ~500 parameters. Sub-threshold smoothing, GIDL/GISL, stress effects, well proximity, NQS. | BSIM4.8.3 (hand-port from Berkeley): ~500 parameters. Full DC physics (Vth + SCE/DIBL/RSCE → Vgsteff smoothing → mobility → Vdsat → Idso → CLM/DIBL/SCBE → GIDL/GISL). 4-terminal stamping (D, G, S, B). Cold/warm/hot tier with branchless eval. | BigOSpice has newer BSIM4 version (4.8.3 vs 4.7). Both implement the full BSIM4 DC model. BigOSpice's data-oriented implementation (SmallVec Jacobian output, no heap allocation in eval) is faster per-evaluation. |
| **BSIMSOI** | Full SOI variant of BSIM: floating body, self-heating, partially/fully depleted. | **Not available** | ngspice exclusive. Critical for SOI processes (FDSOI, GlobalFoundries 22FDX). |
| **EKV** | Enz-Krummenacher-Vittoz: charge-based, continuous from weak to strong inversion. Favored for low-power analog. | **Not available** | ngspice exclusive. Important for ultra-low-power design. |
| **PSP** | Surface-Potential-based: physics-based, no empirical smoothing functions. Penn State Philips model. | **Not available** | ngspice exclusive. Used by some foundries (NXP, GlobalFoundries). |

### Other Active Devices

| Device | ngspice | BigOSpice | Comparison |
|--------|---------|-----------|------------|
| **JFET** | Level 1 + Level 2 (Parker-Skellern) | Level 1 (N/P polarity) | ngspice has Level 2 JFET. |
| **MESFET** | Statz + Curtis + TOM models | Basic MESFET (N/P polarity) | ngspice has more MESFET models. |

### Sources

| Device | ngspice | BigOSpice | Comparison |
|--------|---------|-----------|------------|
| **V-source waveforms** | DC + PULSE + SIN + PWL + EXP + SFFM + AM + TRNOISE + TRRANDOM + PWL FILE | DC + PULSE + SIN + PWL + EXP + SFFM + AM + TRNOISE + TRRANDOM + PWL FILE + PWL REPEAT | Equivalent + BigOSpice adds PWL REPEAT. |
| **I-source** | Same waveforms as V-source | Same waveforms as V-source | Equivalent. |
| **Controlled sources (linear)** | E (VCVS), G (VCCS), F (CCCS), H (CCVS): linear + polynomial + TABLE forms | VCVS, VCCS, CCCS, CCVS: linear gain only | ngspice has polynomial and TABLE nonlinear forms for controlled sources. BigOSpice is linear only. |
| **Behavioral (B-source)** | Expression-based V/I: math functions, V()/I() references, IF-THEN-ELSE, TABLE | Expression-based V/I: 40+ functions including stochastic (gauss, agauss, unif, aunif, flat), TABLE with interpolation, symbolic differentiation for Jacobians | Similar core capability. BigOSpice adds stochastic functions and symbolic differentiation. ngspice has wider compatibility testing. |

### Transmission Lines

| Device | ngspice | BigOSpice | Comparison |
|--------|---------|-----------|------------|
| **Ideal T-line (T)** | Lossless, Branin's method, 2-port delay | Tline: lossless, Branin's method, 2 branch variables per port | Equivalent. |
| **Lossy T-line (LTRA)** | Frequency-dependent R, L, G, C + history buffer + convolution | LTRA: frequency-dependent R, L, G, C + SoA history (times, v1, v2, i1, i2) + Roychowdhury-Pederson convolution | Equivalent algorithm. BigOSpice uses SoA layout for history. |
| **TXL** | Frequency-domain lossy stub model | WLossy: frequency-domain lossy stub | Similar. |
| **URC** | Uniform RC ladder (1D diffusion) | URC: Uniform RC ladder | Equivalent. |

### Switches

| Device | ngspice | BigOSpice | Comparison |
|--------|---------|-----------|------------|
| **V-controlled switch** | SW: von/voff thresholds, ron/roff, hysteresis | Switch: same model | Equivalent. |
| **I-controlled switch** | CSW: ion/ioff thresholds, ron/roff | CSwitch: same model | Equivalent. |

### Digital/Mixed-Signal

| Feature | ngspice | BigOSpice | Comparison |
|---------|---------|-----------|------------|
| **Digital engine** | XSPICE event-driven: EVTqueue, 12-state logic (0/1/X/Z × strong/resistive/HiZ/unknown), ~100+ code models (AND, OR, NAND, NOR, XOR, DFF, Latch, ADC, DAC, Schmitt, RAM, ROM, ...) | DigitalRuntime: 12-state logic (DigState u8), event queue (SoA min-heap), combinational primitives (Buf, Not, And, Nand, Or, Nor, Xor, Xnor, Mux2, Mux4, Demux2, Demux4), sequential (DLatch, DFlipFlop), sources (DPulse, DSource), state machines (DState). ADC/DAC bridges with hysteresis. | **ngspice far more extensive** — 100+ XSPICE code models vs BigOSpice's ~20 digital primitives. But BigOSpice's SoA event queue and DigitalRuntime hook into analog NR are more performance-oriented. |
| **Verilog-A (OSDI)** | Via OpenVAF compiler → `.osdi` shared object → runtime dlopen | Same: OpenVAF → `.osdi` → dlopen via OsdiRegistry + OsdiTrampoline. SoaBuffers for batch eval. | **Equivalent.** Both use the OSDI 0.3 ABI standard. |
| **Co-simulation** | XSPICE IPC interface: socket-based connection to external simulators | Verilator `.so` loader: compile Verilog → `libdesign.so` → dlopen + DPI-C bridge | Different approach. ngspice: generic IPC (language-agnostic). BigOSpice: direct Verilog co-sim via Verilator (faster, tighter integration). |
| **XSPICE code models** | ~100+ extensible models with C code model preprocessor (cmpp) | Not supported | ngspice exclusive. Major ecosystem advantage. |

---

## 3. Solver Technology — Detailed Comparison

### Newton-Raphson Core

| Feature | ngspice | BigOSpice | Technical Details |
|---------|---------|-----------|-------------------|
| **Damping** | Fixed: if any |dV| > 10V → damp = min(10/max_change, 0.1) applied globally | BankRose adaptive: α=0.5 if ||F(x_new)|| > ||F(x_old)||, else α=1.0 | ngspice always damps large steps. BigOSpice monitors residual growth — if NR is converging (residual shrinking), take full step; if diverging (residual growing), half-step. More aggressive when safe, more cautious when needed. |
| **Anderson Acceleration** | Not available | Type-1 Walker-Ni (2011): history window m=5, mixing β=1.0, Tikhonov λ=1e-10. Solve normal equations on Gram matrix of ΔF history. | BigOSpice exclusive. Accelerates convergence by ~30% for well-conditioned problems. Disabled by default (zero overhead when off). |
| **Homotopy** | Not available (users must script manually) | Built-in via `.OPTIONS HOMOTOPY=1`. Continuation method that smoothly deforms a simple problem into the target problem. | BigOSpice exclusive as built-in feature. |
| **Junction Limiting** | Per-device in DEVload (scattered across 50+ device files): pnjlim for PN junctions, fetlim for MOSFET Vgs, limvds for MOSFET Vds | Centralized module `junction_limit.rs`: `pnjlim(v_new, v_old, vt, vcrit)`, `fetlim(vgs_new, vgs_old, vto)`, `limvds(vds_new, vds_old)`, BJT limiting. All called from stamper before device eval. | Same math. BigOSpice centralizes for maintainability and testability. ngspice duplicates limiting logic across many device files. |
| **Initial Guess** | Junction voltages only (MODEINITJCT: ~0.6V forward bias for silicon junctions) | 5-pass topology-aware: (1) V-source terminals, (2) midpoint between known voltages, (3) MOSFET bias (Vgs > Vth), (4) BJT bias (Vbe≈0.7V, Vce≈0.8×VDD), (5) .NODESET overrides. CMOS inverter-aware (shared drain with same gate). | BigOSpice's smarter initial guess reduces first-iteration NR count by ~20-30%. |
| **Watchdog** | None (can hang indefinitely on pathological circuits) | Optional wall-clock timeout: abort solver if exceeds configured limit | Safety feature for batch simulation. |

### Sparse Matrix Solvers

| Feature | ngspice Sparse 1.3 | ngspice KLU | BigOSpice Native | BigOSpice KLU |
|---------|--------------------|-----------|-----------------|----|
| **Matrix format** | Per-element malloc linked list | CSC workspace (pre-allocated) | CSC workspace (Rust Vec) | CSC (SuiteSparse FFI) |
| **Ordering** | Markowitz (dynamic, per-factorization) | BTF + AMD (static, once per topology) | BTF + AMD (Rust, once per topology) | BTF + AMD (C, once per topology) |
| **Factorization** | Markowitz pivot + threshold + dynamic fill-in malloc | Gilbert-Peierls left-looking LU with partial pivoting per BTF block | Gilbert-Peierls left-looking LU with partial pivoting per BTF block | Same (C implementation) |
| **Refactorization** | Reuse ordering only (still O(nnz) numeric work) | Reuse symbolic + pivot pattern (5-10x faster) | Reuse symbolic + pivot pattern | Same |
| **Fill-in handling** | Dynamic malloc per fill element | Pre-allocated in symbolic phase | Pre-allocated in symbolic phase | Same |
| **Memory overhead** | ~48 bytes per nonzero (struct + pointers + malloc header) | ~16 bytes per nonzero (CSC: value + row_index) | ~16 bytes per nonzero | Same |
| **Index type** | int (32-bit) | int32 or int64 | u32 | i64 |
| **Max size** | ~100K nodes | ~1M nodes | ~65K nodes (u32) | ~1M nodes |
| **Performance** | Baseline | 5-100x faster for large circuits | Similar to KLU for moderate circuits | Highly optimized C |

### Convergence Aid Comparison

| Aid | ngspice | BigOSpice |
|-----|---------|-----------|
| **GMIN Stepping** | Dynamic: start at 1e-2 S, reduce by 10x per step. Adaptive step factor (accelerate on success, decelerate on failure). Final GMIN = 1e-12 S (or Gshunt option). `diagGmin` option for all diagonals. | Scheduled: [1e-2, 1e-3, 1e-4, 0]. Divergence detection: if any node voltage exceeds 3× supply bound, interpolate with 5 finer sub-steps. Less adaptive but more predictable. |
| **Source Stepping** | Dynamic: alpha from 0→1 with adaptive step sizing (double on success, halve on failure). Fails for regenerative circuits. | Uniform schedule: α = k/itl6 with bisection on failure. itl6 default = 10 (10 uniform steps). More predictable, same limitation for regenerative circuits. |
| **Pseudo-Transient** | Supplementary capacitance + source ramping over RAMPTIME. Nearly always succeeds. Slowest method. | C/dt exponential growth: c_init=1.0 F, dt_growth=2.0, max_steps=200. Stamp C/dt to diagonals, grow dt geometrically until true residual converges. Check true residual (without stamp) against tolerance. |

---

## 4. I/O and Format Support — Detailed Comparison

| Format | ngspice | BigOSpice | Technical Details |
|--------|---------|-----------|-------------------|
| **SPICE Netlist** | SPICE3/Berkeley standard + HSPICE/PSpice/LTspice compatibility modes | SPICE3 + HSPICE extensions (OPTVAL, .DISTRIBUTION, .BINMODEL, .EXTRACT, single-quoted expressions) + Xyce compat (.LINSOL, .GLOBAL_PARAM) | BigOSpice focuses on HSPICE/Xyce compatibility. ngspice has broader PSpice/LTspice support. |
| **Rawfile (Binary)** | Native: packed double, little-endian, column-major | Native: packed f64, native-endian, column-major. Round-trip compatible with ngspice. | Equivalent. |
| **Rawfile (ASCII)** | Native: decimal scientific notation | Native: same format. Controlled by `.OPTIONS FILETYPE=ASCII` or `.OPTIONS RAWFMT=ASCII`. | Equivalent. |
| **CSV** | Via nutmeg `wrdata file signal1 signal2 ...` (post-hoc) | Built-in `CsvWriter`: customizable delimiter, optional header/units row, configurable precision (default 9 sig figs), RFC 4180 compliant. | BigOSpice has built-in CSV with more options. |
| **HSPICE POST** | **Not supported** | Built-in: `.tr0` (transient), `.ac0` (AC), `.sw0` (DC sweep). Fortran-style unformatted records (4-byte LE length prefix/suffix). Header + type codes + variable names + LE f32 data + 1e30 sentinel. | **BigOSpice exclusive.** Critical for HSPICE waveform viewer compatibility in production IC design. |
| **Touchstone** | **Not supported** | Built-in: `.s1p`, `.s2p`, `.sNp`. IBIS-ATM 1.1 format. Complex formats: MA (magnitude/angle°), DB (dB/angle°), RI (real/imag). Frequency units: Hz/kHz/MHz/GHz. Port-count-aware formatting (1-port inline, 2-port column-major, N-port row-major). | **BigOSpice exclusive.** Essential for RF/microwave design and S-parameter exchange. |
| **MT0 (Monte Carlo)** | **Not supported** | Built-in: `Mt0Writer`. ASCII measurement table. `$DATA1 SOURCE='incspice-mc'` header + `.TITLE` + column headers + data rows. One row per MC sample/corner. Failed = `nan`. | **BigOSpice exclusive.** Standard format for HSPICE Monte Carlo results. |
| **Interactive Plotting** | nutmeg/X11 plotting + Xgraph. `plot v(out) vs v(in)`. Color, grid, axis labels configurable. | **Not supported** (CLI-only, write to file) | ngspice exclusive. BigOSpice targets batch workflows. |
| **Shared Library API** | `libngspice.so`: `ngSpice_Init()`, `ngSpice_Command()`, `ngSpice_Circ()`, callbacks for data delivery, background thread support. | **Not supported** | ngspice exclusive. Enables embedding in GUI tools, Python bindings (PySpice), MATLAB. |

---

## 5. Summary Tables

### BigOSpice Exclusive Features (Not in ngspice)

| Feature | Category | Value |
|---------|----------|-------|
| Harmonic Balance (single/multi/N-tone) | RF Analysis | Periodic steady-state in frequency domain |
| Periodic Steady-State (shooting) | RF Analysis | Find periodic solution without long transient |
| Envelope Following | RF Analysis | Efficient modulated-RF simulation |
| AC Sensitivity | Extraction | Frequency-dependent parameter sensitivity |
| S-Parameter Analysis | RF Analysis | Native N-port S/Y/Z computation |
| Built-in Monte Carlo (.MC) | Statistical | DEV/LOT matching, deterministic seeding |
| Built-in Worst Case (.WCASE) | Statistical | Extreme + OneAtATime corner enumeration |
| Latin Hypercube Sampling | Statistical | Quasi-MC with √N convergence |
| 6-Layer Incremental Cache | Performance | Topology + dirty + affine + Woodbury + checkpoint |
| Anderson Acceleration | Solver | Type-1 NR acceleration |
| Homotopy Continuation | Solver | Built-in convergence aid |
| HSPICE POST Output | I/O | .tr0/.ac0/.sw0 binary waveforms |
| Touchstone Output | I/O | .sNp S-parameter files |
| MT0 Output | I/O | Monte Carlo measurement tables |
| GPU Compute Backend | Performance | wgpu (cross-platform WebGPU) |
| SIMD Batch Operations | Performance | SSE2 intrinsics for f32 ops |
| Data-Oriented Design | Architecture | SoA layout, index-based, zero-alloc hot paths |
| Verilator Co-simulation | Digital | Direct Verilog module integration via .so |

### ngspice Exclusive Features (Not in BigOSpice)

| Feature | Category | Value |
|---------|----------|-------|
| BSIMSOI | Device Model | SOI MOSFET (FDSOI, PD-SOI) |
| EKV | Device Model | Low-power analog MOSFET |
| PSP | Device Model | Surface-potential MOSFET |
| HICUM | Device Model | High-current BJT |
| MEXTRAM | Device Model | Advanced BJT |
| XSPICE Code Models | Digital | 100+ extensible models |
| Polynomial Controlled Sources | Device Model | E/F/G/H with POLY form |
| Voltage-Dependent Capacitor | Device Model | C with VC1, VC2 coefficients |
| Interactive Plotting | UI | nutmeg/X11 waveform viewer |
| Shared Library API | Integration | libngspice.so for embedding |
| PSpice Compatibility | Compat | Full PSpice dialect support |
| LTspice Compatibility | Compat | Full LTspice dialect support |
| Gear BDF-6 | Solver | 6th-order time integration |
| Adjoint Sensitivity | Solver | More efficient for many-param/few-output |

### Feature Parity (Both Implement)

| Feature | Notes |
|---------|-------|
| DC OP, DC Sweep, AC, Transient, Noise, TF, Distortion, Fourier | Core SPICE analyses |
| BSIM3v3, BSIM4 | Industrial MOSFET models |
| Gummel-Poon BJT, VBIC | Bipolar models |
| Newton-Raphson + GMIN + Source Stepping + PTC | Convergence aids |
| KLU Sparse Solver | BTF + AMD + Gilbert-Peierls |
| OSDI (Verilog-A) Plugin | OpenVAF compiled .osdi loading |
| Rawfile Output (Binary + ASCII) | Standard SPICE waveform format |
| .MEAS Measurements | FIND/WHEN/TRIG-TARG + reductions |
| .control Scripting | if/while/foreach/define/let/set |
| Temperature Scaling | Per-device and global .TEMP |
| Subcircuit Support | .SUBCKT/.ENDS with nesting |
| Parameter Expressions | .PARAM with math functions |

---

## 6. What Each Simulator Does Best

| Use Case | Best Choice | Why |
|----------|-------------|-----|
| Quick interactive exploration | ngspice | nutmeg plotting, shared library API |
| Batch W/L characterization | **BigOSpice** | Cache-accelerated parameter sweeps |
| RF circuit design | **BigOSpice** | HB, PSS, Envelope, S-params |
| Monte Carlo yield analysis | **BigOSpice** | Built-in MC with cache, MT0 output |
| SOI process design | ngspice | BSIMSOI model |
| Ultra-low-power analog | ngspice | EKV model |
| Large linear networks (>10K nodes) | ngspice | KLU + BTF optimization |
| HSPICE migration | **BigOSpice** | HSPICE extensions, POST/MT0 output |
| EDA tool integration | ngspice | libngspice.so shared library |
| Production IC tapeout | Both | ngspice has more PDK testing; BigOSpice has faster sweeps |
| Teaching/learning SPICE | ngspice | Extensive documentation, community |
| High-performance batch simulation | **BigOSpice** | SoA + cache + GPU + SIMD |
