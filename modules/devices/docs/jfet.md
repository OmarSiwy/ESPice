# JFET Level 1 (Shichman-Hodges) -- Parameter & Equation Reference

> Junction Field-Effect Transistor, Level 1 Shichman-Hodges model with doping tail parameter. NJF/PJF support.

## Model Topology

Three-terminal device: **Drain (D)**, **Gate (G)**, **Source (S)**. The gate forms PN junctions to both the source and drain regions, modeled as exponential diodes. The channel between drain and source carries the Shichman-Hodges FET current controlled by the gate-source overdrive voltage. Source-drain reversal is handled automatically when $V_{DS} < 0$.

## Parameters

### DC Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VT0 | $V_{T0}$ | V | -2.0 | $(-\infty, \infty)$ | Threshold (pinch-off) voltage |
| BETA | $\beta$ | A/V^2 | 1e-4 | $[0, \infty)$ | Transconductance parameter |
| LAMBDA | $\lambda$ | 1/V | 0 | $[0, \infty)$ | Channel-length modulation parameter |
| B | $B$ | -- | 1.0 | $(0, \infty)$ | Doping tail profile parameter |
| IS | $I_S$ | A | 1e-14 | $(0, \infty)$ | Gate junction saturation current |
| N | $N$ | -- | 1.0 | $(0, \infty)$ | Emission coefficient |
| TYPE | -- | -- | +1 | {-1, +1} | +1 = NJF, -1 = PJF |

### Parasitic Resistance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RD | $R_D$ | Ohm | 0 | $[0, \infty)$ | Drain ohmic resistance |
| RS | $R_S$ | Ohm | 0 | $[0, \infty)$ | Source ohmic resistance |

### Junction Capacitance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CGS | $C_{GS0}$ | F | 0 | $[0, \infty)$ | Zero-bias gate-source junction capacitance |
| CGD | $C_{GD0}$ | F | 0 | $[0, \infty)$ | Zero-bias gate-drain junction capacitance |
| PB | $\phi_B$ | V | 1.0 | $(0, \infty)$ | Gate junction built-in potential |
| FC | $f_c$ | -- | 0.5 | $[0, 1)$ | Forward-bias depletion capacitance linearization coefficient |

### Temperature Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TNOM | $T_{nom}$ | deg C | 27 | -- | Parameter measurement temperature |
| TCV | -- | V/K | 0 | -- | Threshold voltage temperature coefficient |
| VTOTC | -- | V/K | 0 | -- | Threshold voltage temperature coefficient (alternative) |
| BEX | -- | -- | 0 | -- | Mobility temperature exponent |
| BETATCE | -- | %/K | 0 | -- | Mobility temperature coefficient (alternative) |
| XTI | $X_{TI}$ | -- | 3.0 | -- | Gate junction saturation current temperature exponent |
| EG | $E_g$ | eV | 1.11 | -- | Bandgap voltage |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KF | $K_F$ | -- | 0 | $[0, \infty)$ | Flicker noise coefficient |
| AF | $A_F$ | -- | 1.0 | $(0, \infty)$ | Flicker noise exponent |
| NLEV | -- | -- | 2 | {0, 1, 2, 3} | Noise equation selector |
| GDSNOI | -- | -- | 1.0 | $[0, \infty)$ | Channel noise coefficient |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| AREA | $A$ | -- | 1.0 | $(0, \infty)$ | Device area factor |
| M | $M$ | -- | 1.0 | $(0, \infty)$ | Parallel device multiplier |
| TEMP | $T$ | K | 300.15 | $(0, \infty)$ | Device operating temperature |
| DTEMP | $\Delta T$ | K | 0 | $(-\infty, \infty)$ | Temperature offset from circuit temperature |

## Equations

### Thermal Voltage

$$V_t = k_B \cdot (T_{nom} + 273.15)$$

where $k_B = 8.617333262145 \times 10^{-5}$ eV/K (Boltzmann constant in eV).

$$V_{t,N} = N \cdot V_t$$

Emission-coefficient-scaled thermal voltage.

### Polarity and Source-Drain Reversal

$$\text{polarity} = \text{TYPE} \quad (+1 \text{ for NJF}, -1 \text{ for PJF})$$

$$V_{GS,raw} = (V_G - V_S) \cdot \text{polarity}$$

$$V_{GD,raw} = (V_G - V_D) \cdot \text{polarity}$$

$$V_{DS,raw} = V_{GS,raw} - V_{GD,raw}$$

Source-drain reversal when $V_{DS,raw} < 0$:

$$V_{GS,eff} = \begin{cases} V_{GS,raw} & V_{DS,raw} \ge 0 \\ V_{GD,raw} & V_{DS,raw} < 0 \end{cases}$$

$$V_{GD,eff} = \begin{cases} V_{GD,raw} & V_{DS,raw} \ge 0 \\ V_{GS,raw} & V_{DS,raw} < 0 \end{cases}$$

$$V_{DS,eff} = V_{GS,eff} - V_{GD,eff} \ge 0$$

### Gate Junction Diode Currents

$$I_{GS} = I_S \left( e^{\min(V_{GS,eff}/V_{t,N},\; 80)} - 1 \right) + G_{min} \cdot V_{GS,eff}$$

$$I_{GD} = I_S \left( e^{\min(V_{GD,eff}/V_{t,N},\; 80)} - 1 \right) + G_{min} \cdot V_{GD,eff}$$

where $G_{min} = 10^{-12}$ S. The $\min(\cdot, 80)$ guards against exponential overflow.

### Shichman-Hodges Channel Current

Gate overdrive:

$$V_{GST} = V_{GS,eff} - V_{T0}$$

$$V_{GST}^{+} = \max(V_{GST},\; 0)$$

Saturation voltage:

$$V_{DSAT} = \frac{V_{GST}^{+}}{B}$$

Output-conductance-modulated beta:

$$\beta' = \beta \cdot (1 + \lambda \cdot V_{DS,eff})$$

**Cutoff** ($V_{GST} \le 0$): $V_{GST}^{+} = 0$, so $I_D = 0$.

**Saturation** ($V_{DS,eff} \ge V_{DSAT}$):

$$I_D = \beta' \cdot \frac{(V_{GST}^{+})^2}{2B}$$

**Linear** ($V_{DS,eff} < V_{DSAT}$):

$$I_D = \beta' \cdot V_{DS,eff} \left( V_{GST}^{+} - \frac{B \cdot V_{DS,eff}}{2} \right)$$

### Area and Multiplier Scaling

$$I_D = I_{D,raw} \cdot A \cdot M$$

$$I_{GS} = I_{GS,raw} \cdot A \cdot M$$

$$I_{GD} = I_{GD,raw} \cdot A \cdot M$$

### Terminal Current Assembly

Normal mode ($V_{DS,raw} \ge 0$):

$$I_{drain} = (I_D - I_{GD}) \cdot \text{polarity}$$

$$I_{source} = (-I_D - I_{GS}) \cdot \text{polarity}$$

Reversed mode ($V_{DS,raw} < 0$):

$$I_{drain} = (-I_D - I_{GD}) \cdot \text{polarity}$$

$$I_{source} = (I_D - I_{GS}) \cdot \text{polarity}$$

Gate current (both modes):

$$I_{gate} = I_{GS} + I_{GD}$$

### Junction Charge (Depletion Capacitance)

Junction grading coefficient $m = 0.5$ (fixed for JFET).

**Reverse / depletion bias** ($V < f_c \cdot \phi_B$):

$$Q_{dep}(V) = 2 \cdot C_{j0} \cdot \phi_B \left(1 - \sqrt{1 - \frac{V}{\phi_B}}\right)$$

where the argument is clamped: $\max\!\left(1 - V/\phi_B,\; 10^{-30}\right)$.

**Forward bias extension** ($V \ge f_c \cdot \phi_B$):

$$f_1 = \frac{C_{j0} \cdot \phi_B}{1 - m}\left(1 - (1 - f_c)^{1-m}\right)$$

$$f_2 = (1 - f_c)^{1+m}$$

$$f_3 = 1 - f_c(1 + m)$$

$$Q_{fwd}(V) = f_1 + \frac{C_{j0}}{f_2}\left[ f_3(V - f_c \phi_B) + \frac{m}{2\phi_B}(V^2 - (f_c \phi_B)^2) \right]$$

Applied to both junctions:

$$Q_{GS} = Q(V_{GS}) \cdot A \cdot M \quad \text{using } C_{j0} = C_{GS0}$$

$$Q_{GD} = Q(V_{GD}) \cdot A \cdot M \quad \text{using } C_{j0} = C_{GD0}$$

Note: $V_{GS}$ and $V_{GD}$ in the charge equations use the raw (un-reversed) terminal voltages, not the effective voltages.

### Charge-to-Terminal Mapping

$$Q_{drain} = -Q_{GD}$$

$$Q_{gate} = Q_{GS} + Q_{GD}$$

$$Q_{source} = -Q_{GS}$$

Displacement currents are obtained by the solver via $I_C = dQ/dt$.

### Noise Sources

Five noise generators declared on the device:

| Source | Nodes | Type | Standard PSD |
|--------|-------|------|--------------|
| Drain resistance thermal | D -- S | thermal | $S_I = 4kT / R_D$ |
| Source resistance thermal | S -- D | thermal | $S_I = 4kT / R_S$ |
| Channel flicker (1/f) | D -- S | flicker | $S_I = K_F \cdot I_D^{A_F} / f$ |
| Gate-drain shot | G -- D | shot | $S_I = 2q \cdot I_{GD}$ |
| Gate-source shot | G -- S | shot | $S_I = 2q \cdot I_{GS}$ |

Noise equation selection (NLEV) and GDSNOI affect channel noise computation at the analysis level.

### Convergence Aids

#### PN Junction Voltage Limiting (pnjlim)

Critical voltage:

$$V_{crit} = V_{t,N} \cdot \ln\!\left(\frac{V_{t,N}}{\sqrt{2} \cdot I_S}\right)$$

Applied to both $V_{GS}$ and $V_{GD}$ each Newton iteration. When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 V_{t,N}$:

If $V_{old} > 0$:

$$\text{arg} = \frac{V_{new} - V_{old}}{V_{t,N}}$$

$$V_{lim} = \begin{cases} V_{old} + V_{t,N}(2 + \ln(\text{arg} - 2)) & \text{arg} > 2 \\ V_{old} + 2 V_{t,N} & \text{arg} \le 2 \end{cases}$$

If $V_{old} \le 0$ and $V_{new} > 0$:

$$V_{lim} = V_{t,N} \cdot \ln\!\left(\frac{V_{new}}{V_{t,N}}\right)$$

Otherwise: $V_{lim} = V_{crit}$.

#### FET Gate Overdrive Limiting (fetlim)

Applies to $V_{GS}$ after pnjlim. Limits the step size near and above $V_{T0}$:

$$V_{tsthi} = |2(V_{old} - V_{T0})| + 2$$

$$V_{tstlo} = \frac{|V_{tsthi}|}{2} + 2$$

$$V_{tox} = V_{T0} + 3.5$$

Three regions based on $V_{old}$ relative to $V_{T0}$ and $V_{tox}$:

**Region 1** ($V_{old} \ge V_{tox}$): Clamp upward steps to $V_{tsthi}$, downward steps to $V_{tstlo}$, with floor at $V_{T0} + 2$.

**Region 2** ($V_{T0} \le V_{old} < V_{tox}$): Clamp upward steps to $V_{tsthi}$, with floor at $V_{T0} - 0.5$.

**Region 3** ($V_{old} < V_{T0}$): Clamp downward steps to $V_{tsthi}$, upward steps to $V_{tstlo}$, with ceiling at $V_{T0} + 0.5$.

#### Gmin Stepping (attempt)

For source-stepping convergence aid, the gate saturation current is ramped:

$$I_S(\lambda) = I_S + (10^{-12} - I_S)(1 - \lambda)$$

At $\lambda = 0$: $I_S = 10^{-12}$ A (easy to converge). At $\lambda = 1$: $I_S$ returns to the model value.
