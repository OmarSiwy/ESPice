# Independent Current Source (I) -- Parameter & Equation Reference

> Ideal independent current source with DC, AC, and six transient waveform types (PULSE, SIN, EXP, SFFM, AM).

## Model Topology

Two-terminal device with a positive node (`p`) and a negative node (`n`). Conventional current flows from `p` through the external circuit to `n` (current is injected into node `p` and withdrawn from node `n`). The device contributes **no conductance matrix entries** -- it is a pure current stamp on the RHS vector only (`RHS[p] += I`, `RHS[n] -= I`). No GMIN shunt is applied, consistent with ngspice `ISRCload`.

**Terminals:**

| Index | Name | Description |
|-------|------|-------------|
| 0 | p | Positive terminal |
| 1 | n | Negative terminal |

## Parameters

### Source Configuration

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| dc | $I_{DC}$ | A | 0 | -- | DC value of current source |
| m | $M$ | -- | 1 | -- | Parallel multiplier (number of parallel sources) |
| waveform | -- | -- | dc | {dc, pulse, sin, exp, sffm, am} | Transient waveform type |

### AC Analysis

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| acmag | $I_{AC}$ | A | 1.0 | -- | AC magnitude |
| acphase | $\phi_{AC}$ | deg | 0 | -- | AC phase |

### PULSE Waveform Parameters

SPICE syntax: `PULSE(I1 I2 TD TR TF PW PER [PHASE])`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| pulse_i1 | $I_1$ | A | 0 | -- | Initial current |
| pulse_i2 | $I_2$ | A | 0 | -- | Pulsed current |
| pulse_td | $T_D$ | s | 0 | -- | Delay time |
| pulse_tr | $T_R$ | s | 1e-9 | -- | Rise time |
| pulse_tf | $T_F$ | s | 1e-9 | -- | Fall time |
| pulse_pw | $T_{PW}$ | s | 1e-9 | -- | Pulse width |
| pulse_per | $T_{PER}$ | s | 2e-9 | -- | Period |
| pulse_phase | $\phi_P$ | deg | 0 | -- | Phase offset |

### SIN Waveform Parameters

SPICE syntax: `SIN(IOFF IAMP FREQ TD THETA PHASE)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| sin_ioff | $I_{OFF}$ | A | 0 | -- | Offset current |
| sin_iamp | $I_{AMP}$ | A | 0 | -- | Amplitude |
| sin_freq | $f$ | Hz | 0 | -- | Frequency |
| sin_td | $T_D$ | s | 0 | -- | Delay time |
| sin_theta | $\theta$ | 1/s | 0 | -- | Damping factor |
| sin_phase | $\phi$ | deg | 0 | -- | Phase offset |

### EXP Waveform Parameters

SPICE syntax: `EXP(I1 I2 TD1 TAU1 TD2 TAU2)`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| exp_i1 | $I_1$ | A | 0 | -- | Initial current |
| exp_i2 | $I_2$ | A | 0 | -- | Pulsed current |
| exp_td1 | $T_{D1}$ | s | 0 | -- | Rise delay time |
| exp_tau1 | $\tau_1$ | s | 1e-9 | -- | Rise time constant |
| exp_td2 | $T_{D2}$ | s | 0 | -- | Fall delay time |
| exp_tau2 | $\tau_2$ | s | 1e-9 | -- | Fall time constant |

### SFFM Waveform Parameters

SPICE syntax: `SFFM(IOFF IAMP FC MDI FS [PHASEC PHASES])`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| sffm_ioff | $I_{OFF}$ | A | 0 | -- | Offset current |
| sffm_iamp | $I_{AMP}$ | A | 0 | -- | Amplitude |
| sffm_fc | $f_C$ | Hz | 0 | -- | Carrier frequency |
| sffm_mdi | $MDI$ | -- | 0 | -- | Modulation index |
| sffm_fs | $f_S$ | Hz | 0 | -- | Signal (modulating) frequency |
| sffm_phasec | $\phi_C$ | deg | 0 | -- | Carrier phase |
| sffm_phases | $\phi_S$ | deg | 0 | -- | Signal phase |

### AM Waveform Parameters

SPICE syntax: `AM(IA IO MF FC TD [PHASEC PHASES])`

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| am_ia | $I_A$ | A | 0 | -- | Amplitude |
| am_io | $I_O$ | -- | 0 | -- | Offset |
| am_mf | $f_M$ | Hz | 0 | -- | Modulating frequency |
| am_fc | $f_C$ | Hz | 0 | -- | Carrier frequency |
| am_td | $T_D$ | s | 0 | -- | Delay time |
| am_phasec | $\phi_C$ | deg | 0 | -- | Carrier phase |
| am_phases | $\phi_S$ | deg | 0 | -- | Signal phase |

## Equations

### Output Stamp

The final device current applied to the circuit after multiplier scaling:

$$I_{out} = M \cdot I_{source}(t)$$

KCL stamp (pure RHS, no conductance matrix entries):

$$RHS_p \mathrel{+}= I_{out}$$

$$RHS_n \mathrel{-}= I_{out}$$

### DC Waveform

$$I_{source} = I_{DC}$$

### PULSE Waveform

Piecewise-linear periodic waveform. For $t \le T_D$:

$$I_{source} = I_1$$

For $t > T_D$, compute phase-adjusted modular time:

$$t' = (t - T_D) + \frac{\phi_P}{360} \cdot T_{PER}$$

$$t_{mod} = t' - \left\lfloor \frac{t'}{T_{PER}} \right\rfloor \cdot T_{PER}$$

Then by segment:

**Rise** ($0 \le t_{mod} < T_R$):

$$I_{source} = I_1 + (I_2 - I_1) \cdot \frac{t_{mod}}{T_R}$$

**High** ($T_R \le t_{mod} < T_R + T_{PW}$):

$$I_{source} = I_2$$

**Fall** ($T_R + T_{PW} \le t_{mod} < T_R + T_{PW} + T_F$):

$$I_{source} = I_2 + (I_1 - I_2) \cdot \frac{t_{mod} - T_R - T_{PW}}{T_F}$$

**Low** ($t_{mod} \ge T_R + T_{PW} + T_F$):

$$I_{source} = I_1$$

### SIN Waveform (Damped Sinusoid)

For $t \le T_D$:

$$I_{source} = I_{OFF} + I_{AMP} \sin(\phi)$$

where $\phi$ is the phase parameter converted to radians: $\phi = \phi_{deg} \cdot \frac{\pi}{180}$.

For $t > T_D$:

$$I_{source} = I_{OFF} + I_{AMP} \cdot e^{-(t - T_D) \cdot \theta} \cdot \sin\!\left(2\pi f (t - T_D) + \phi\right)$$

### EXP Waveform (Double Exponential)

For $t \le T_{D1}$:

$$I_{source} = I_1$$

For $T_{D1} < t \le T_{D2}$ (rising phase only):

$$I_{source} = I_1 + (I_2 - I_1)\left(1 - e^{-(t - T_{D1})/\tau_1}\right)$$

For $t > T_{D2}$ (rising + falling):

$$I_{source} = I_1 + (I_2 - I_1)\left(1 - e^{-(t - T_{D1})/\tau_1}\right) + (I_1 - I_2)\left(1 - e^{-(t - T_{D2})/\tau_2}\right)$$

### SFFM Waveform (Single-Frequency FM)

Valid for all $t$:

$$I_{source} = I_{OFF} + I_{AMP} \sin\!\left(2\pi f_C t + \phi_C + MDI \cdot \sin(2\pi f_S t + \phi_S)\right)$$

where $\phi_C$ and $\phi_S$ are converted from degrees to radians: $\phi_{rad} = \phi_{deg} \cdot \frac{\pi}{180}$.

### AM Waveform (Amplitude Modulation)

For $t < T_D$:

$$I_{source} = 0$$

For $t \ge T_D$:

$$I_{source} = I_A \left(I_O + \sin(2\pi f_M t + \phi_S)\right) \sin(2\pi f_C t + \phi_C)$$

where $\phi_C$ and $\phi_S$ are converted from degrees to radians: $\phi_{rad} = \phi_{deg} \cdot \frac{\pi}{180}$.

### Jacobian Structure

The independent current source has **zero Jacobian contribution** with respect to node voltages. The waveform depends only on time $t$ and model parameters, not on node unknowns $x$. The solver's autodiff yields zero partial derivatives:

$$\frac{\partial I_{source}}{\partial V_p} = 0, \quad \frac{\partial I_{source}}{\partial V_n} = 0$$

No conductance (G) matrix entries are stamped. No charge (q) function is defined, so no capacitance (C) matrix entries exist.

### Noise

No noise generators are defined for this device. The `noise_gens` array is not present in the implementation.

### Convergence Aids

No `limit` (voltage limiting), `attempt` (parameter stepping), or `q` (charge/capacitance) functions are defined. The device is purely algebraic with no reactive or convergence-sensitive behavior.
