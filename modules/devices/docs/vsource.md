# Independent Voltage Source (V) -- Parameter & Equation Reference

> Independent voltage source with DC, AC, and transient waveform support (PULSE, SIN, EXP, PWL, SFFM, AM).

## Model Topology

The voltage source is a two-terminal device with external nodes **p** (positive) and **n** (negative), plus an internal **branch** unknown carrying the source current. It is formulated as a Modified Nodal Analysis (MNA) voltage source: a branch current $I_{branch}$ is added as an unknown, KCL stamps $\pm I_{branch}$ into the p and n nodes, and a branch equation constrains $V_p - V_n = V_{source}(t)$. The `u_kinds` declaration marks p and n as `.voltage` and branch as `.current`.

## Parameters

### DC / AC Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `dc` | $V_{DC}$ | V | 0 | $(-\infty, \infty)$ | DC value of the source |
| `acmag` | $V_{AC}$ | V | 1.0 | $[0, \infty)$ | AC analysis magnitude |
| `acphase` | $\phi_{AC}$ | deg | 0 | $(-\infty, \infty)$ | AC analysis phase angle |
| `waveform` | -- | -- | `dc` | enum | Waveform selector: `dc`, `pulse`, `sin`, `exp`, `pwl`, `sffm`, `am` |

### PULSE Parameters -- `PULSE(V1 V2 TD TR TF PW PER PHASE)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `pulse_v1` | $V_1$ | V | 0 | $(-\infty, \infty)$ | Initial (low) voltage |
| `pulse_v2` | $V_2$ | V | 0 | $(-\infty, \infty)$ | Pulsed (high) voltage |
| `pulse_td` | $T_D$ | s | 0 | $[0, \infty)$ | Delay time before first pulse |
| `pulse_tr` | $T_R$ | s | 1e-9 | clamped $\geq 10^{-12}$ | Rise time |
| `pulse_tf` | $T_F$ | s | 1e-9 | clamped $\geq 10^{-12}$ | Fall time |
| `pulse_pw` | $PW$ | s | 1e-9 | $[0, \infty)$ | Pulse width (high duration) |
| `pulse_per` | $PER$ | s | 2e-9 | clamped $\geq T_R + PW + T_F + 10^{-12}$ | Period |
| `pulse_phase` | $\phi_{pulse}$ | deg | 0 | $(-\infty, \infty)$ | Phase shift within period |

### SIN Parameters -- `SIN(VO VA FREQ TD THETA PHASE)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `sin_vo` | $V_O$ | V | 0 | $(-\infty, \infty)$ | Offset voltage |
| `sin_va` | $V_A$ | V | 0 | $(-\infty, \infty)$ | Amplitude |
| `sin_freq` | $f$ | Hz | 0 | $[0, \infty)$ | Frequency |
| `sin_td` | $T_D$ | s | 0 | $[0, \infty)$ | Delay time |
| `sin_theta` | $\theta$ | 1/s | 0 | $[0, \infty)$ | Damping factor |
| `sin_phase` | $\phi$ | deg | 0 | $(-\infty, \infty)$ | Phase offset |

### EXP Parameters -- `EXP(V1 V2 TD1 TAU1 TD2 TAU2)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `exp_v1` | $V_1$ | V | 0 | $(-\infty, \infty)$ | Initial voltage |
| `exp_v2` | $V_2$ | V | 0 | $(-\infty, \infty)$ | Target voltage |
| `exp_td1` | $T_{D1}$ | s | 0 | $[0, \infty)$ | Rise delay time |
| `exp_tau1` | $\tau_1$ | s | 1e-9 | clamped $\geq 10^{-15}$ | Rise time constant |
| `exp_td2` | $T_{D2}$ | s | 0 | $[0, \infty)$ | Fall delay time |
| `exp_tau2` | $\tau_2$ | s | 1e-9 | clamped $\geq 10^{-15}$ | Fall time constant |

### PWL Parameters -- `PWL(T1 V1 T2 V2 ...)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `pwl_times` | $t_k$ | s | all 0 | $[0, \infty)$ | Breakpoint times (array, max 64) |
| `pwl_values` | $v_k$ | V | all 0 | $(-\infty, \infty)$ | Breakpoint voltages (array, max 64) |
| `pwl_len` | $N_{pwl}$ | -- | 0 | $[0, 64]$ | Number of active breakpoints |
| `pwl_repeat` | $T_{repeat}$ | s | 0 | $[0, \infty)$ | Repeat start time (0 = no repeat) |
| `pwl_td` | $T_D$ | s | 0 | $[0, \infty)$ | PWL delay |

### SFFM Parameters -- `SFFM(VO VA FC MDI FS PHASEC PHASES)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `sffm_vo` | $V_O$ | V | 0 | $(-\infty, \infty)$ | Offset voltage |
| `sffm_va` | $V_A$ | V | 0 | $(-\infty, \infty)$ | Amplitude |
| `sffm_fc` | $f_C$ | Hz | 0 | $[0, \infty)$ | Carrier frequency |
| `sffm_mdi` | $MDI$ | -- | 0 | $[0, \infty)$ | Modulation index |
| `sffm_fs` | $f_S$ | Hz | 0 | $[0, \infty)$ | Signal (modulating) frequency |
| `sffm_phasec` | $\phi_C$ | deg | 0 | $(-\infty, \infty)$ | Carrier phase |
| `sffm_phases` | $\phi_S$ | deg | 0 | $(-\infty, \infty)$ | Signal phase |

### AM Parameters -- `AM(VA VO MF FC TD PHASEC PHASES)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `am_va` | $V_A$ | V | 0 | $(-\infty, \infty)$ | Amplitude |
| `am_vo` | $V_O$ | -- | 0 | $(-\infty, \infty)$ | Offset (modulation depth) |
| `am_mf` | $f_M$ | Hz | 0 | $[0, \infty)$ | Modulating frequency |
| `am_fc` | $f_C$ | Hz | 0 | $[0, \infty)$ | Carrier frequency |
| `am_td` | $T_D$ | s | 0 | $[0, \infty)$ | Delay time |
| `am_phasec` | $\phi_C$ | deg | 0 | $(-\infty, \infty)$ | Carrier phase |
| `am_phases` | $\phi_S$ | deg | 0 | $(-\infty, \infty)$ | Signal phase |

## Equations

### MNA Stamp (KCL + Branch Equation)

The physics function returns three residuals corresponding to unknowns $(V_p, V_n, I_{branch})$:

$$F_p = +I_{branch}$$

KCL at the positive node: branch current flows into node p.

$$F_n = -I_{branch}$$

KCL at the negative node: branch current flows out of node n.

$$F_{branch} = V_p - V_n - V_{source}(t)$$

Branch constitutive equation: constrains the terminal voltage to equal the source waveform.

### DC Waveform

$$V_{source} = V_{DC}$$

### PULSE Waveform

Parameter clamping:

$$T_R \leftarrow \max(T_R,\; 10^{-12})$$

$$T_F \leftarrow \max(T_F,\; 10^{-12})$$

$$PER \leftarrow \max(PER,\; T_R + PW + T_F + 10^{-12})$$

For $t < T_D$:

$$V_{source} = V_1$$

For $t \geq T_D$, compute the effective time with optional phase shift:

$$t_{eff} = (t - T_D) + \frac{\phi_{pulse}}{360} \cdot PER$$

$$t_{mod} = t_{eff} \bmod PER$$

Piecewise regions within one period:

$$V_{source} = \begin{cases}
V_1 + (V_2 - V_1)\,\dfrac{t_{mod}}{T_R} & 0 \leq t_{mod} < T_R \\[6pt]
V_2 & T_R \leq t_{mod} < T_R + PW \\[6pt]
V_2 - (V_2 - V_1)\,\dfrac{t_{mod} - T_R - PW}{T_F} & T_R + PW \leq t_{mod} < T_R + PW + T_F \\[6pt]
V_1 & T_R + PW + T_F \leq t_{mod} < PER
\end{cases}$$

### SIN Waveform

Phase conversion:

$$\phi_{rad} = \frac{2\pi \cdot \phi}{360}$$

For $t < T_D$:

$$V_{source} = V_O + V_A \sin(\phi_{rad})$$

For $t \geq T_D$:

$$\Delta t = t - T_D$$

$$V_{source} = V_O + V_A \sin(2\pi f \,\Delta t + \phi_{rad})\; e^{-\theta \,\Delta t}$$

### EXP Waveform

Parameter clamping:

$$\tau_1 \leftarrow \max(\tau_1,\; 10^{-15})$$

$$\tau_2 \leftarrow \max(\tau_2,\; 10^{-15})$$

Piecewise definition:

$$V_{source} = \begin{cases}
V_1 & t \leq T_{D1} \\[6pt]
V_1 + (V_2 - V_1)\left(1 - e^{-(t - T_{D1})/\tau_1}\right) & T_{D1} < t \leq T_{D2} \\[6pt]
V_1 + (V_2 - V_1)\left(1 - e^{-(t - T_{D1})/\tau_1}\right) + (V_1 - V_2)\left(1 - e^{-(t - T_{D2})/\tau_2}\right) & t > T_{D2}
\end{cases}$$

### PWL Waveform

If $N_{pwl} = 0$, falls back to DC value:

$$V_{source} = V_{DC}$$

Effective time with delay:

$$t_{eff} = t - T_D$$

If $t_{eff} < 0$:

$$V_{source} = v_0$$

Repeat logic (when $T_{repeat} > 0$ and $N_{pwl} > 1$):

$$\text{period} = t_{N-1} - T_{repeat}$$

$$t_{eff} \leftarrow T_{repeat} + (t_{eff} - T_{repeat}) \bmod \text{period} \quad \text{if } t_{eff} > t_{N-1} \text{ and } t_{N-1} > T_{repeat} \text{ and period} > 0$$

Boundary conditions:

$$V_{source} = v_0 \quad \text{if } t_{eff} \leq t_0$$

$$V_{source} = v_{N-1} \quad \text{if } t_{eff} \geq t_{N-1}$$

Linear interpolation between breakpoints $k$ and $k+1$ where $t_k \leq t_{eff} < t_{k+1}$:

$$\alpha = \frac{t_{eff} - t_k}{\max(t_{k+1} - t_k,\; 10^{-15})}$$

$$V_{source} = v_k + (v_{k+1} - v_k)\,\alpha$$

### SFFM Waveform

Phase conversions:

$$\phi_C^{rad} = \frac{2\pi \cdot \phi_C}{360}, \qquad \phi_S^{rad} = \frac{2\pi \cdot \phi_S}{360}$$

$$V_{source} = V_O + V_A \sin\!\Big(2\pi f_C\, t + \phi_C^{rad} + MDI \sin(2\pi f_S\, t + \phi_S^{rad})\Big)$$

### AM Waveform

Phase conversions:

$$\phi_C^{rad} = \frac{2\pi \cdot \phi_C}{360}, \qquad \phi_S^{rad} = \frac{2\pi \cdot \phi_S}{360}$$

For $t < T_D$:

$$V_{source} = 0$$

For $t \geq T_D$:

$$V_{source} = V_A \Big(V_O + \sin(2\pi f_M\, t + \phi_S^{rad})\Big) \sin(2\pi f_C\, t + \phi_C^{rad})$$

## Device Unknowns

| Index | Name | Kind | Description |
|-------|------|------|-------------|
| 0 | `p` | voltage | Positive terminal voltage |
| 1 | `n` | voltage | Negative terminal voltage |
| 2 | `branch` | current | Branch current through source (positive from p to n internally) |

## Sparse Jacobian Structure

No `g_pattern_override` or `c_pattern_override` is declared; the solver assumes a dense $3 \times 3$ block. The analytical Jacobian (from the MNA stamp) has the following nonzero structure:

| Row | Col | Entry |
|-----|-----|-------|
| p | branch | $+1$ |
| n | branch | $-1$ |
| branch | p | $+1$ |
| branch | n | $-1$ |

The branch equation's dependence on the source voltage is time-dependent only (no dependence on node unknowns beyond $V_p$ and $V_n$), so no additional conductance terms appear.

## Notes

- No charge function (`q`) is defined -- the voltage source is purely algebraic (no reactive/capacitive contributions).
- No limiting function (`limit`) -- voltage sources do not require Newton step damping.
- No convergence aid (`attempt`) -- no parameter stepping is implemented.
- No noise generators (`noise_gens`) -- ideal voltage source has zero internal noise.
- No state (`State`) -- the source is stateless; waveform depends only on time and parameters.
- The `Instance` struct is empty -- all parameters live in `Model`.
- Waveform evaluation is performed in `f64` (not in the autodiff scalar type `S`) because transcendental functions (sin, exp, mod) are only needed as functions of time, not of node voltages. The result is lifted into `S` via `S.lift()`.
