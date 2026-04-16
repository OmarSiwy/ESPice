# Analysis Crate Research — BigOSpice

**Date:** 2026-04-16
**Crate:** `crates/analysis/src/`
**Related:** `crates/solver/src/newton.rs`, `crates/core/src/`, `crates/solver/src/stamper.rs`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [DC Operating Point Analysis (`dc_op.rs`)](#2-dc-operating-point-analysis-dc_oprs)
3. [DC Sweep Analysis (`dc_sweep.rs`)](#3-dc-sweep-analysis-dc_sweeprs)
4. [Nested DC Sweep (`dc_op.rs`)](#4-nested-dc-sweep)
5. [Transient Analysis (`transient.rs`)](#5-transient-analysis-transientrs)
6. [Time Integration Methods (`companion.rs`)](#6-time-integration-methods-companionrs)
7. [AC Small-Signal Analysis (`ac.rs`)](#7-ac-small-signal-analysis-acrs)
8. [Noise Analysis (`noise.rs`)](#8-noise-analysis-noisers)
9. [Harmonic Balance (`hb.rs`)](#9-harmonic-balance-hbrs)
10. [Periodic Steady-State — Shooting Method (`pss.rs`)](#10-periodic-steady-state---shooting-method-pssrs)
11. [Envelope Following (`envelope.rs`)](#11-envelope-following-envelopers)
12. [Fourier Analysis (`fourier.rs`)](#12-fourier-analysis-fourriers)
13. [Transfer Function (`tf.rs`)](#13-transfer-function-tfrs)
14. [DC Sensitivity (`sensitivity.rs`)](#14-dc-sensitivity-sensitivityrs)
15. [AC Sensitivity (`sens_ac.rs`)](#15-ac-sensitivity-sens_acrs)
16. [Pole-Zero Analysis (`pz.rs`)](#16-pole-zero-analysis-pzrs)
17. [Distortion Analysis (`disto.rs`)](#17-distortion-analysis-distors)
18. [S-Parameter Analysis (`sp.rs`)](#18-s-parameter-analysis-sprs)
19. [Result Types (`result.rs`)](#19-result-types-resultrs)
20. [Newton-Raphson Solver (`solver/src/newton.rs`)](#20-newton-raphson-solver-solvernewtonrs)

---

## 1. Architecture Overview

The `crates/analysis` crate is organized as a library of pure analysis functions. There is **no monolithic `Analyzer` object** — each analysis (`run_dc_op`, `run_transient`, `run_ac`, etc.) is a standalone function that takes a `Circuit`, `DeviceRegistry`, and analysis-specific config, returning typed result structs.

### Public API Surface (`lib.rs`)

```rust
pub use dc_op::{run_dc_op, run_dc_op_with_config, run_dc_op_with_options,
                run_dc_op_with_ic_pins, DcOpOutput,
                run_nested_dc, NestedDcConfig, NestedDcResult};
pub use dc_sweep::{run_dc_sweep, DcSweepConfig};
pub use transient::{run_transient, TransientConfig, IntegrationMethod};
pub use ac::{run_ac, AcConfig, AcSweepType};
pub use fourier::{run_fourier, run_fft, FourierConfig, FourierResult};
pub use sensitivity::{run_sens_dc, SensConfig, SensOutput};
pub use noise::{NoiseConfig, NoiseResult, DeviceNoiseContribution, run_noise};
pub use tf::{run_tf, TfConfig, TfResult};
pub use pz::{run_pz, PzConfig, PzResult, Complex};
pub use sens_ac::{run_sens_ac, SensAcConfig, SensAcResult};
pub use disto::{run_disto, DistoConfig, DistoResult};
pub use fft::{run_fft, FftConfig, FftWindow, FftResult};
pub use mc::{run_mc, McConfig};
pub use wcase::{run_wcase, WcaseConfig};
pub use pss::{run_pss, PssConfig, ErrPreset};
pub use envelope::{run_envelope, EnvelopeConfig, EnvelopeResult};
pub use hb::{run_hb_n_tone, HbNToneConfig, HbResult, OsdiHbDevice};
pub use sp::{run_sp, SpConfig, SpResult, SpPort};
pub use sweep::ParamSweep;
pub use companion::{CompanionMethod, assemble_be_jacobian,
                    assemble_be_residual, assemble_gear2_residual};
```

### Data Flow Pattern

Most analyses share a common pattern:

```
Circuit + DeviceRegistry
      │
      ▼
┌─────────────────┐
│  DC OP Solve    │  ← Solver::solve() → NrResult
└────────┬────────┘
         │ dc.solution (bias point)
         ▼
┌─────────────────┐
│ stamp_circuit_  │  ← Builds G (conductance) + C (capacitance) Jacobians
│ gc_into()       │    as TripletMatrix at the linearisation point
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Per-analysis    │  ← AC: build 2N×2N block matrix, solve per freq
│ solve          │    Noise: accumulate per-device PSD contributions
└─────────────────┘
```

---

## 2. DC Operating Point Analysis (`dc_op.rs`)

### Mathematical Formulation

DC OP solves the nonlinear circuit equations at a single bias point (all frequency-dependent terms vanish):

$$F(x) = G(x) + I_{src} = 0$$

where:
- $x$ = node voltages (MNA unknowns)
- $G(x)$ = nonlinear device currents evaluated at $x$
- $I_{src}$ = independent source contributions

The Jacobian is:
$$J_{ij} = \frac{\partial F_i}{\partial x_j} = G_{ij} = \frac{\partial I_i}{\partial x_j}$$

### Algorithm

```
1. Clone circuit, propagate .TEMP / .OPTIONS TEMP to devices
2. Solver::solve(circuit, registry, warm_start=None)
   a. Build initial guess via topology-aware logic (voltage sources, CMOS nodes, BJT nodes)
   b. Newton-Raphson loop (newton.rs):
      - stamp_circuit_gc_at_time: build residual + Jacobian at x
      - J · Δx = −F(x)
      - x ← x + Δx (with damping)
      - Convergence check: ||F||∞ < abstol AND max|Δx| < vntol
   c. Handle non-convergence: fallback through homotopy strategies
      (gmin stepping → source stepping → pseudo-transient → Anderson acceleration)
3. Extract node voltages and branch currents from solution vector
4. Return DcOpOutput { result: DcOpResult, cache: IncrementalCache }
```

### Key Data Structures

```rust
pub struct DcOpOutput {
    pub result: DcOpResult,
    pub cache: IncrementalCache,
}

pub struct DcOpResult {
    pub node_voltages: Vec<(String, f64)>,    // (node_name, voltage)
    pub branch_currents: Vec<(String, f64)>,   // (device_name, current)
}
```

### `.IC` Pinning (`run_dc_op_with_ic_pins`)

For `.TRAN UIC`-free runs (standard mode), ngspice holds `.IC`-specified nodes at their initial voltages during DC OP via a **stiff conductance** (large $G_{IC}$), then releases them for transient. This prevents the DC OP from ignoring user-specified initial conditions (e.g., Colpitts oscillator tank voltages).

Implementation: `Solver::solve_with_ic_pins(circuit, registry, &ic_pins)` — passes `(matrix_index, voltage)` pairs to the solver, which stamps `G_{IC}` into the Jacobian diagonal.

### Temperature Propagation

- `opts.temp` (Kelvin) is injected as global temperature if no `.TEMP` directive populated `circuit.temperatures()`
- `ckt.propagate_global_temperature()` fans it out to all devices lacking explicit instance temperature

---

## 3. DC Sweep Analysis (`dc_sweep.rs`)

### Algorithm

```
for val in start → stop (step):
    ckt.set_device_param(source_name, "dc", val)
    result = Solver::solve(circuit, registry, prev_solution.as_deref())
    record val, node_voltages
    prev_solution = result.solution
```

### Key Design Points

- **Warm-starting**: Each sweep point uses the previous solution as initial guess, which dramatically improves convergence for smooth sweeps
- **Bisection fallback** (in nested DC): if NR fails at sweep point $i$, bisection is attempted between points $i-1$ (good) and $i$ (failed), with up to 3 midpoints
- Sweep parameter stored as `"dc"` on the named source device
- Temperature propagation done once on base circuit clone

---

## 4. Nested DC Sweep

### Algorithm (`.DC src1 START STOP STEP src2 START STOP STEP`)

```
for outer_val in outer_values:
    ckt.set_device_param(outer_device, outer_param, outer_val)
    prev_solution = None
    for inner_val in inner_values:
        ckt.set_device_param(inner_device, inner_param, inner_val)
        attempt1 = solver.solve(warm=prev_solution)
        if fails:
            attempt2 = solver.solve(warm=bisection_midpoint)  # up to 3 bisections
            if fails:
                attempt3 = solver.solve(cold=None)           # last resort
        record result (or reuse last good)
```

### Bisection Scheme

When `solver.solve()` fails with `Convergence` or `SingularMatrix`:
1. Between last good point $V_{i-1}$ and target $V_i$, try midpoint $V_m = 0.5(V_{i-1} + V_i)$
2. Up to 3 bisection iterations
3. Final fallback: cold-start (pass `None`)
4. If all fail: warn, reuse last good solution, continue sweep

---

## 5. Transient Analysis (`transient.rs`)

### Mathematical Formulation

The circuit DAEs are:

$$q'(x, t) + g(x, t) = 0$$

where $q$ = reactive (capacitor/inductor) charges, $g$ = resistive currents.

Discretized with a BDF-$k$ method at timestep $h$:

$$\sum_{j=0}^{k} \alpha_j \, q(x_{n-j}) + g(x_n) = 0$$

Rearranged for Newton residual:

$$F(x_n) = g(x_n) + \alpha_0 \, q(x_n) + \sum_{j=1}^{k} c_j \, q(x_{n-j}) = 0$$

where the history coefficients $c_j$ are pre-computed from the BDF table.

### Algorithm

```
1. DC OP (or UIC initial conditions)
2. Initialize charge history q_history[slot] = q(x_0)
3. t = 0
4. while t < tstop:
     h_step = min(h_current, tstop - t)
     effective_method = bootstrap_method(target_order, steps_done)
     q_hist_slice = q_history[0..history_depth]

     if adaptive AND method is Gear2/Trap:
         # LTE estimation via Richardson extrapolation
         x_BE = newton_solve(method=BE, h)
         x_ord2 = newton_solve(method=effective, h)
         ratio = lte_error_ratio(x_ord2, x_BE)
         if ratio > 1: reject, shrink h
         else: accept x_ord2, predict next h
     else:
         x_new = newton_solve(method=effective, h)
         if not converged: return error

     stamp q(x_new) into q_history[0], shift others right
     record t, x_new
     t += h_step
```

### Adaptive Timestep (LTE-Based)

**Richardson Extrapolation**: The difference between BDF-1 (BE) and BDF-2 (Gear-2/Trap) solutions is an $O(h^2)$ estimate of the local truncation error.

$$\text{LTE}[i] = \frac{|x_{ord2}[i] - x_{BE}[i]|}{\text{TRTOL} \cdot (\text{reltol} \cdot |x_{ord2}[i]| + \text{abstol})}$$

With `TRTOL = 7.0` (ngspice default), step is **accepted** if `ratio < 1.0`, rejected otherwise.

**Predictor** (for next step):

$$h_{new} = \text{clamp}\left(0.9 \cdot h \cdot \text{ratio}^{-1/3}, \; h_{min}, \; t_{max}\right)$$

where $p = 2$ (order of the high-order method).

### Bootstrap Order

Gear methods need $k-1$ historical charge vectors. The first steps bootstrap:

| Steps done | Gear-2 | Gear-3 | Gear-4 | Gear-5 |
|---|---|---|---|---|
| 0 | BE | BE | BE | BE |
| 1 | Gear-2 | Gear-2 | Gear-2 | Gear-2 |
| 2 | Gear-2 | Gear-3 | Gear-3 | Gear-3 |
| 3 | Gear-2 | Gear-3 | Gear-4 | Gear-4 |
| 4+ | Gear-2 | Gear-3 | Gear-5 | Gear-5 |

### Checkpointing

- Every `checkpoint_interval` accepted steps: snapshot `(t, x, q_history)` into `TransientArena`
- Resume: `run_transient_inner(circuit, cfg, Some(snapshot), resume_t)`
- Charge history restored from snapshot, DC OP skipped

### Digital/XSPICE Support

- `DigitalRuntime` from `bigospice_digital` crate
- ADC bridges: threshold comparison at DC OP → digital state
- DAC bridges: `G_DAC = 1\,\text{GS}$ conductance stamped to pin analog node to DAC output voltage
- `init_digital_state()`: zero-delay combinational evaluation (up to 32 passes)
- `rt.flush(t_next)`: event-driven simulation up to `t_next`

---

## 6. Time Integration Methods (`companion.rs`)

### BDF Coefficients Table

The standard BDF-$k$ form:
$$\sum_{j=0}^{k} \alpha_j \, x_{n-j} = h \, \beta_0 \, f_n$$

Rearranged for residual form (with $q$ as reactive charge):

$$F = g(x_n) + \frac{\alpha_0}{h \beta_0} \cdot q(x_n) - \sum_{j=1}^{k} \frac{\alpha_j}{h \beta_0} \cdot q(x_{n-j})$$

| Order | Method | $\alpha = \alpha_0/(h\beta_0)$ | History coeffs (newest→oldest) |
|---|---|---|---|
| 1 | Backward Euler | $1/h$ | $-1/h$ (BE only: $F = g + \alpha(q-q_{n-1})$) |
| 2 | Gear (BDF-2) | $3/(2h)$ | $-\frac{4}{3}\alpha$, $+\frac{1}{3}\alpha$ |
| 3 | Gear (BDF-3) | $11/(6h)$ | $-\frac{18}{11}\alpha$, $+\frac{9}{11}\alpha$, $-\frac{2}{11}\alpha$ |
| 4 | Gear (BDF-4) | $25/(12h)$ | $-\frac{48}{25}\alpha$, $+\frac{36}{25}\alpha$, $-\frac{16}{25}\alpha$, $+\frac{3}{25}\alpha$ |
| 5 | Gear (BDF-5) | $137/(60h)$ | $-\frac{300}{137}\alpha$, $+\frac{300}{137}\alpha$, $-\frac{200}{137}\alpha$, $+\frac{75}{137}\alpha$, $-\frac{12}{137}\alpha$ |

### Trapezoidal (Gear-1 with history averaging)

$$F = g(x_n) + g(x_{n-1}) + \frac{2}{h}(q(x_n) - q(x_{n-1}))$$

Note: $\alpha = 2/h$ (not $1/h$ as in BE). The `g_prev` (resistive residual at previous step) is needed.

### Jacobian Structure

For all methods, the Jacobian is:

$$J = G + \alpha \cdot C$$

where $G = \partial g/\partial x$ and $C = \partial q/\partial x$ (capacitance matrix — constant for linear elements).

### Residual Assembly Functions

```rust
// Backward Euler: F = g + α(q - q_prev)
assemble_be_residual(residual_g, residual_q, q_prev, α, dest)

// Trapezoidal: F = g + g_prev + α(q - q_prev)
assemble_trap_residual(residual_g, residual_q, q_prev, g_prev, α, dest)

// Gear-2: F = g + α·q - (4/3)α·q_{n-1} + (1/3)α·q_{n-2}
assemble_gear2_residual(residual_g, residual_q, q_prev1, q_prev2, α, dest)

// General BDF-k
assemble_bdfk_residual(residual_g, residual_q, q_history[], &BdfCoeffs, dest)
```

---

## 7. AC Small-Signal Analysis (`ac.rs`)

### Mathematical Formulation

Linearized at DC OP: $G + sC$ where $G$ =conductance Jacobian, $C$ = capacitance Jacobian.

At frequency $\omega$ ($s = j\omega$):

$$(G + j\omega C) \cdot V(\omega) = I_{src}(\omega)$$

### Block Matrix Formulation (Real Arithmetic)

The complex $N \times N$ system is converted to a real $2N \times 2N$ block:

$$\begin{bmatrix} G & -\omega C \\ \omega C & G \end{bmatrix} \begin{bmatrix} V_{re} \\ V_{im} \end{bmatrix} = \begin{bmatrix} I_{re} \\ I_{im} \end{bmatrix}$$

### Algorithm

```
1. DC OP solve → dc.solution (bias point)
2. stamp_circuit_gc_into(circuit, dc_solution, …) → G_triplet, C_triplet
3. For each frequency f:
     ω = 2πf
     Build block matrix:
       block[r,c]      += G[r,c]      (top-left)
       block[r,c+N]    += -ω*C[r,c]   (top-right)
       block[r+N,c]    +=  ω*C[r,c]   (bottom-left)
       block[r+N,c+N]  +=  G[r,c]     (bottom-right)
     Build RHS from AcStimulus list
     SparseLU → solve
     Extract magnitude = sqrt(V_re² + V_im²), phase = atan2(V_im, V_re)
```

### Frequency Sweep Generation

| Sweep Type | Formula |
|---|---|
| Linear | $f_i = f_{start} + i \cdot \frac{f_{stop}-f_{start}}{N-1}$ |
| Decade | Logarithmically spaced points: $10^{\log_{10}(f_{start}) + i \cdot \Delta\log}$ |
| Octave | Logarithmically spaced: $2^{\log_2(f_{start}) + i \cdot \Delta\log}$ |

### AC Stimulus

- `AcStimulus::VoltageSource(branch_row, re, im)`: injected at KVL branch equation row
- `AcStimulus::CurrentSource(pos_mna, neg_opt, re, im)`: injected at node KCL rows
- Fallback: unit current at node 0 if no stimuli registered

---

## 8. Noise Analysis (`noise.rs`)

### Physical Noise Models

| Device | Noise Type | PSD Formula |
|---|---|---|
| Resistor | Thermal (Johnson-Nyquist) | $S_I = \frac{4kT}{R}$ [A²/Hz] |
| Diode | Shot | $S_I = 2qI_D$ [A²/Hz] |
| BJT | Shot (Ic + Ib) + Flicker | $S_I = 2q(I_C + I_B) + \frac{K_f I_B^{A_f}}{f}$ |
| MOSFET | Thermal + Flicker | $S_I = \frac{8}{3}kT \cdot g_m + \frac{K_f I_D^{A_f}}{C_{ox}L^2 f}$ |

### Algorithm

```
1. DC OP → bias point (dc_solution)
2. Build G, C at OP (stamp_circuit_gc_into)
3. For each frequency f:
     Build Y(jω) = G + jωC as 2N×2N block matrix
     Factorize once (SparseLU)

     # Compute |H(f)|² (transfer from input source to output)
     RHS = unit stimulus at input source branch
     H_sol = lin.solve(RHS)
     |H|² = H_re² + H_im²

     For each noisy device:
         Inject unit noise current at device terminals
         Solve for V_out (transfer function from device to output)
         |V_out|² = V_re² + V_im²
         Contribution = |V_out|² × S_device(f)
         Accumulate to total output noise
4. Input-referred = Output / |H|²
```

### Noise Model Details

**Resistor thermal noise** at temperature $T$ [K]:
$$S_I = \frac{4k_B T}{R}, \quad k_B = 1.380649 \times 10^{-23} \text{ J/K}$$

**BJT combined noise**:
$$S_I = 2q(I_C + I_B) + \frac{K_f \cdot I_B^{A_f}}{f}$$

**MOSFET flicker noise**:
$$S_I = \frac{8}{3}k_B T \cdot g_m + \frac{K_f \cdot I_D^{A_f}}{C_{ox} \cdot L^2 \cdot f}$$

### Temperature Handling

Default $T = 300.15$ K (27°C). Can be overridden via `.OPTIONS TEMP` (passed in Kelvin).

---

## 9. Harmonic Balance (`hb.rs`)

### Mathematical Formulation

For a periodic steady-state with fundamental $f_0$ and $K$ harmonics:

$$F(V) = Y_{lin}(j\omega) \cdot V + I_{NL}(V) - I_{src} = 0$$

Where:
- $V$ = vector of complex Fourier coefficients $[V_0, V_1, V_{-1}, ..., V_K, V_{-K}]$
- $Y_{lin}(j\omega)$ = diagonal matrix of linear admittances at each harmonic: $Y_h = G + j\omega_h C$
- $I_{NL}(V)$ = nonlinear branch currents in frequency domain (IDFT → evaluate devices → DFT)
- $I_{src}$ = source current phasors

### Single-Tone HB Algorithm

```
1. N = 2K + 1 time samples per period (Nyquist limit for K harmonics)
2. Build DFT matrix W[k,n] = exp(-j2πkn/N)
3. Initial guess: DC operating point
4. Newton loop:
     For iteration it = 0..max_iter:
       # Time domain:
       v_td = IDFT(V)          # N real time samples
       i_nl_td = eval_nonlinear_devices(v_td)  # time-domain currents
       i_nl_fd = DFT(i_nl_td)  # back to frequency domain

       # Frequency domain residual:
       F(V)_h = (G + jω_h C)·V_h + i_nl_fd,h - I_src,h

       # Jacobian via forward AD:
       ∂i_nl_fd/∂V = (∂i_nl_td/∂v_td) · ∂v_td/∂V = diag(g_j) · W/N
         (g_j = ∂i_nl_td[j]/∂v_td[j] per time point)

       J = Y_diagonal + DFT_diag(g)  # block-diagonal + mixing

       ΔV = solve(J, -F(V))
       V = V + ΔV
       if ||ΔV|| < tol: converged
5. Return V (Fourier coefficients)
```

### Two-Tone HB (Box Truncation + APFT)

- **Box truncation**: include all mixing products $m \cdot f_1 + n \cdot f_2$ with $|m| \le K$, $|n| \le K$, $m \cdot f_1 + n \cdot f_2 > 0$
- **APFT** (Almost-Periodic FFT): choose $T_s$ such that all mixing products map to distinct DFT bins (collision-free)
- Envelope: $N_s = \text{lcm}(N_1, N_2)$ time samples for two-tone grid

### OSDI Device Support

OSDILHB Device: wraps an OpenVAF/Modelica DLL for HB evaluation. Provides:
- `init()`: initialize device state
- `evaluate(v_re[], v_im[], freq, &i_re[], &i_im[], &g_re[], &g_im[])`: frequency-domain evaluation
- `get_fmax()`, `get_num_ports()`

---

## 10. Periodic Steady-State — Shooting Method (`pss.rs`)

### Mathematical Formulation

Shooting seeks $x_0$ such that after one period $T = 1/f_{fund}$:

$$F(x_0) = x(T; x_0) - x_0 = 0$$

i.e., the state after one period equals the initial state (periodic boundary condition).

### Algorithm (Shooting Method)

```
1. DC OP → initial guess x₀
2. Newton loop on shooting residual:
   for it = 0..max_iter:
     # (a) Shoot: integrate one period from x₀
     inject_ic(x₀)
     tran = run_transient(circuit, UIC, tstop=T, tstep=T/(2K+1))
     x_T = extract_final_state(tran)

     # (b) Residual: F = x(T) - x₀
     F = x_T - x₀
     if ||F||∞ < tol: converged

     # (c) Monodromy matrix Φ = ∂x(T)/∂x₀ via finite differences
     for j = 0..n_state-1:
       x₀_pert = x₀; x₀_pert[j] += ε
       inject_ic(x₀_pert)
       tran_j = run_transient(...)
       x_T_j = extract_final_state(tran_j)
       Φ[:,j] = (x_T_j - x_T) / ε

     # (d) Jacobian: J = Φ - I
     # (e) Δx₀ = solve(J, -F)
     # (f) x₀ = x₀ + Δx₀
3. Final: record waveforms from converged transient
```

### Monodromy Matrix

The monodromy matrix $\Phi = \partial x(T)/\partial x_0$ maps initial state perturbations to final state perturbations. Computed via **finite differences** (O(n) transient runs per NR iteration):

$$\Phi_{ij} = \frac{x_i(T; x_0 + \epsilon \cdot e_j) - x_i(T; x_0)}{\epsilon}$$

### Convergence

- Shooting residual $\infty$-norm: $\|F\|_\infty < \text{tol}$
- Error presets: Liberal ($10^{-4}$), Moderate ($10^{-6}$), Conservative ($10^{-9}$)
- Max iterations: 20

---

## 11. Envelope Following (`envelope.rs`)

### Algorithm

```
for t_env in 0, tstep, 2*tstep, …, tstop:
    ckt_t = circuit.clone()
    apply_envelope_time(ckt_t, t_env)   # time-varying source params
    hb_result = run_hb_single_tone(ckt_t, fund, nharm)
    record hb_result.dc, hb_result.magnitude(1)
```

### Key Points

- **Two timescale separation**: fast carrier at $f_{fund}$, slow envelope varying on `tstep` grid
- At each envelope point, a **single-tone HB solve** is performed at the carrier frequency
- HB is warm-started from the previous envelope step's spectral state
- `apply_envelope_time()` is currently a **no-op placeholder** — circuit parameters are treated as static within each HB solve

---

## 12. Fourier Analysis (`fourier.rs`)

### `.FOUR` Algorithm (Branin's Direct DFT)

```
1. Extract waveform for node_index from TransientResult
2. Find last complete period: t_start = t_end - T, T = 1/freq
3. Resample uniformly onto N=1024 (or longer) uniform grid over [t_start, t_end]
4. Compute DC: a₀ = (1/N) Σ v[n]
5. For each harmonic k = 1..9:
     a_k = (2/N) Σ v[n] · cos(2πkn/N)
     b_k = (2/N) Σ v[n] · sin(2πkn/N)
     mag_k = sqrt(a_k² + b_k²)
     phase_k = atan2(b_k, a_k) [degrees]
6. THD = sqrt(Σ mag_k² for k≥2) / mag_1 × 100%
```

### Key Design Points

- Uses the **last complete period** in the transient data (not the first)
- Uniform resampling via linear interpolation (binary search for interval)
- Returns **THD as percentage**: $\text{THD} = \frac{\sqrt{\sum_{k=2}^{N_h} |V_k|^2}}{|V_1|} \times 100\%$
- `.FFT` is a **stub** returning `SimError::Analysis("unsupported")` — TODO for Phase 3.4

---

## 13. Transfer Function (`tf.rs`)

### Algorithm (Small-Signal DC Gain)

```
1. DC OP → G (at ω=0, C matrix discarded)
2. Factor G once (SparseLU)
3. Gain: RHS = unit source at input branch row
   V = solve(G, RHS)
   gain = V[out_node] - V[ref_node]
4. Input Z: Zin = -1 / (dI_branch/dV_in)
   (from same solve: i_branch_sens = V[branch_row])
5. Output Z: RHS = unit current at out node (input source shorted = zero RHS at branch row)
   V_z = solve(G, RHS)
   Zout = V_z[out_node] - V_z[ref_node]
```

### Key Equations

**Voltage gain** (small-signal):
$$A_v = \frac{\partial V_{out}}{\partial V_{in}} = \frac{V_{out}}{1 \text{ V injected at branch}}$$

**Input impedance** (for voltage-source input):
$$Z_{in} = \frac{V_{in}}{I_{in}} = \frac{1}{\partial I_{branch} / \partial V_{in}} = -\frac{1}{i_{branch,sens}}$$

**Output impedance** (with input source shorted):
$$Z_{out} = \frac{\partial V_{out}}{\partial I_{out}}\bigg|_{V_{in}=0}$$

---

## 14. DC Sensitivity (`sensitivity.rs`)

### Algorithm (Forward Finite Differences)

```
For each parameter p:
    h = max(1e-8, 1e-3 * |p₀|)   # perturbation
    V₀ = DC_OP(circuit)           # baseline
    V₊ = DC_OP(circuit with p ← p₀ + h)
    output₊ = extract_output(V₊)
    output₀ = extract_output(V₀)
    absolute = (output₊ - output₀) / h
    relative = (p₀ / output₀) * absolute   # if |output₀| > 1e-20
```

### Key Design Points

- **Per-parameter perturbation**: each device perturbed independently
- **Forward difference** (not central): $O(1)$ DC solves per parameter
- Only **one DC OP per parameter** (baseline is shared across all parameters)
- Supported devices: R, C, L, V, I, Diode (BJT/MOSFET via `is` parameter)
- Capacitor/Inductor return zero sensitivity when their primary param is 0

---

## 15. AC Sensitivity (`sens_ac.rs`)

### Algorithm

```
1. Run baseline AC sweep → AcResult (baseline_mag[f], baseline_phase[f])
2. For each parameter p:
     h = max(1e-8, 1e-3 * |p₀|)
     perturbed_circuit = circuit with p ← p₀ + h
     pert_result = run_ac(perturbed_circuit)
     d_mag/dp[f] = (pert_mag[f] - base_mag[f]) / h
     d_phase/dp[f] = (pert_phase[f] - base_phase[f]) / h
```

### Re-uses `run_ac()`

The heavy lifting (DC OP, frequency sweep, complex block solve) is in `run_ac()`. The sensitivity layer only orchestrates perturbations.

---

## 16. Pole-Zero Analysis (`pz.rs`)

### Mathematical Formulation

The linearized circuit state-space at DC OP:

$$(G + sC) \cdot x = b$$

Poles are eigenvalues $s$ where $\det(G + sC) = 0$, i.e.:

$$G \cdot x = -s C \cdot x \iff (-C^{-1} G) \cdot x = s \cdot x$$

### Algorithm

```
1. DC OP → G, C at bias point
2. Tikhonov regularisation: C ← C + εI (ε = 1e-18 F) to handle singular C
3. Solve C · X = -G  →  X = -C⁻¹ · G   [LU factorisation]
4. Compute eigenvalues of X via QR iteration on Hessenberg form:
     (a) Hessenberg reduction: O(n³) → O(n²)
     (b) Francis QR iteration with implicit shifts
5. Return eigenvalues as poles (complex s = σ + jω)
```

### Implementation Notes

- **In-house dense linear algebra**: `lu_in_place()`, `lu_solve_one()`, `dense_solve()` — no external dependencies
- QR iteration uses **implicit double shifts** (Francis algorithm)
- Matrix reduced to **upper Hessenberg form** first (Wilkinson's elementary similarity approach)
- Max iterations: $30n$, bails out with diagonal approximation on failure

---

## 17. Distortion Analysis (`disto.rs`)

### Volterra-Series Formulation

For a nonlinear element with Taylor expansion $i = a_1 v + a_2 v^2 + a_3 v^3 + \cdots$:

$$H_2(f_1, f_2) = |a_2| \cdot |H(f_1)| \cdot |H(f_2)| \cdot |H(f_1 + f_2)|$$
$$H_3(f_1, f_2, f_3) = |a_3| \cdot |H(f_1)| \cdot |H(f_2)| \cdot |H(f_3)| \cdot |H(f_1 + f_2 + f_3)|$$

### Harmonic Distortion (Single Tone)

| Type | Formula |
|---|---|
| HD2 | $\frac{|a_2| \cdot |H(f_1)|^2 \cdot |H(2f_1)|}{|H(f_1)|}$ |
| HD3 | $\frac{|a_3| \cdot |H(f_1)|^3 \cdot |H(3f_1)|}{|H(f_1)|}$ |

### Intermodulation Distortion (Two Tones)

| Type | Formula |
|---|---|
| IM2 | $\frac{|a_2| \cdot |H(f_1)| \cdot |H(f_2)| \cdot |H(f_1+f_2)|}{|H(f_1)|}$ |
| IM3 | $\frac{|a_3| \cdot |H(f_1)|^2 \cdot |H(f_2)| \cdot |H(2f_1-f_2)|}{|H(f_1)|}$ |

### Algorithm

```
1. DC OP → G, C at bias
2. Build Y(jω) = G + jωC as 2N×2N block (per frequency)
3. For each kernel frequency (f1, 2f1, 3f1, f1±f2, 2f1±f2):
     Build block matrix, factor (re-used across same frequency)
     Solve for transfer function at output node
     Record |H(f)| = sqrt(re² + im²)
4. Combine with a2, a3 coefficients
```

---

## 18. S-Parameter Analysis (`sp.rs`)

### Wave Variable Definition (IEEE Std 1597)

$$a_i = \frac{V_i + R_i \cdot I_i}{2\sqrt{R_i}}$$ (incident wave)
$$b_i = \frac{V_i - R_i \cdot I_i}{2\sqrt{R_i}}$$ (reflected wave)
$$S_{ij} = \frac{b_i}{a_j}\bigg|_{a_k=0 \text{ for } k \neq j}$$

### Algorithm

```
For each frequency f:
    Build Y(jω) = G + jωC as 2N×2N block matrix

    For each driven port p (0..N_ports-1):
        Build termination conductances for all OTHER ports q ≠ p:
            G_q = 1/R_q added to diagonal entries of port q nodes

        Inject unit current (1 A real) at port p nodes
        Solve Y · V = I
        Compute a_p, b_i for all ports i
        S_ip = b_i / a_p
```

### Port Termination

- Port impedance defaults to **50 Ω** (SPICE standard)
- Non-driven ports terminated with $G_{port} = 1/R_{port}$ conductance
- Differential ports: both pos and neg nodes terminated, with off-diagonal $-G$ terms

---

## 19. Result Types (`result.rs`)

### TransientResult (SoA Layout)

```rust
pub struct TransientResult {
    pub times: Vec<f64>,
    pub node_voltages: Vec<Vec<f64>>,      // Legacy nested view
    pub node_voltages_flat: Vec<f64>,      // SoA: flat row-major buffer
    pub num_nodes: usize,                   // Width of flat buffer
    pub branch_names: Vec<String>,
    pub branch_currents_flat: Vec<f64>,     // SoA: flat row-major
}
```

Access pattern: `voltage(step, node) = node_voltages_flat[step * num_nodes + node]`

### AcResult

```rust
pub struct AcResult {
    pub frequencies: Vec<f64>,
    pub node_magnitudes: Vec<Vec<f64>>,   // [freq_idx][node_idx]
    pub node_phases: Vec<Vec<f64>>,       // radians
    pub node_reals: Vec<Vec<f64>>,
    pub node_imags: Vec<Vec<f64>>,
}
```

---

## 20. Newton-Raphson Solver (`solver/src/newton.rs`)

### Core Newton Loop

```rust
for iter in 0..max_iters {
    # 1. Stamp residual (g) and Jacobian (G) at current x
    stamper.stamp_at(circuit, x, t, &mut residual, &mut jac_triplet);

    # 2. Convergence check
    res_norm = residual.norm_inf();
    if res_norm < abstol { converged = true; break; }

    # 3. Solve J · Δx = -F
    lu = LinSolver::factorize(jac_triplet.to_csc());
    dx = lu.solve(-residual);

    # 4. Damping
    x_new = damp(x, dx);   # Bank-Rose or other damping strategy

    # 5. Voltage limit check (vnstep)
    x_new = clamp(x_new, prev_x, max_step);
}
```

### Homotopy Strategies (Fallback on Divergence)

| Strategy | Description |
|---|---|
| **Gmin stepping** | Gradually increase $g_{min}$ conductance from $10^{-12}$ to 1 S, solve at each level |
| **Source stepping** | Ramp independent sources from 0 to full value in steps |
| **Pseudo-transient** | Add $\frac{dx}{dt} = \frac{x - x_{prev}}{\tau}$ companion for reactive elements |
| **Anderson acceleration** | $x_{n+1} = x_n + \sum_{j=0}^{m-1} \alpha_j (x_{n-j} - x_{n-j-1})$ |

### Convergence Criteria

```rust
ConvergenceCriteria {
    abstol: 1e-12,   // ||F||∞ < abstol
    vntol:  1e-6,    // max|Δx| < vntol
    reltol: 1e-3,    // relative tolerance on solution change
    itl4:   50,      // max NR iterations per operating point
}
```

### Voltage Limiting (Junction Limits)

`junction_limit.rs`: For semiconductor junctions (BJTs, MOSFETs), the voltage difference between any two nodes is clamped per iteration to prevent unrealistic values that could cause convergence issues.

### Topology-Aware Initial Guess

The solver computes an **initial guess** from circuit topology before Newton iteration:

1. **Pass 1**: Set known nodes (ground=0, voltage source terminals from KVL)
2. **Pass 2**: Resistor division for node pairs
3. **Pass 3**: CMOS-aware guess (gate→drain for inverters, balanced for CMOS pairs)
4. **Pass 4**: BJT initial guess (V_BE ≈ 0.7V, etc.)

### Pre-allocated Scratch Buffers

All `Vec<f64>` and `TripletMatrix` buffers are **allocated once** and reused across NR iterations to avoid per-iteration allocation overhead:

```rust
struct NrScratch {
    x_new: Vec<f64>,           // trial solution after damping
    x_prev: Vec<f64>,          // previous iteration (for voltage limiting)
    neg_res: DenseVec,         // -F (RHS to lu_solve)
    jac_triplet: TripletMatrix,
    residual: DenseVec,
}
```

---

## Summary of Analysis Types and Their Dependencies

| Analysis | DC OP | Stamp G/C | Frequency Sweep | NR Solve | Special |
|---|---|---|---|---|---|
| DC OP | — | Yes | No | Yes (Newton) | Temperature propagation |
| DC Sweep | Yes (per point) | Yes (per point) | No | Yes (Newton) | Warm-starting |
| Nested DC | Yes (per point) | Yes (per point) | No | Yes (Newton) | Bisection fallback |
| Transient | Yes (initial) | Yes (per step) | No | Yes (Newton) | BDF/Gear, LTE, checkpoints |
| AC | Yes | Yes | Yes | No (LU only) | 2N×2N block matrix |
| Noise | Yes | Yes | Yes | No (LU per freq) | Per-device PSD summation |
| HB | Yes | Yes | Implicit | Yes (Newton) | IDFT/DFT round-trip |
| PSS | Yes | Yes | No | Yes (shooting) | Monodromy via FD |
| Envelope | — | — | — | — (HB sub-solves) | HB sub-solver per env step |
| Fourier | No | No | No | No | DFT of TransientResult |
| TF | Yes | Yes | No | No (LU only) | Unit source injection |
| DC Sens | Yes | Yes | No | Yes (per param) | Forward FD |
| AC Sens | Yes | Yes | Yes | No | AC + FD perturbation |
| PZ | Yes | Yes | No | No (eigenvalue) | QR on dense Hessenberg |
| Disto | Yes | Yes | Yes | No (LU per freq) | Volterra kernels |
| SP | Yes | Yes | Yes | No (LU per port+freq) | Wave variables |
