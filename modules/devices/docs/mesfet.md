# GaAs MESFET (Statz/Curtice) -- Parameter & Equation Reference

> Three-terminal GaAs MESFET with Curtice quadratic drain current model, Schottky gate junctions, depletion capacitances, and source/drain reversal.

## Model Topology

The MESFET has three external terminals: **Drain**, **Gate**, and **Source** (enum indices 0, 1, 2). The equivalent circuit consists of a voltage-controlled drain current source (Curtice model) between drain and source, two Schottky gate-junction diodes (gate-source and gate-drain), depletion capacitances $C_{gs}$ and $C_{gd}$ across the respective junctions, and optional series drain/source resistances $R_d$, $R_s$. Polarity is controlled by the NMF/PMF flag: NMF (N-channel) uses voltages as-is; PMF (P-channel) flips all voltage signs.

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `nmf` | -- | flag | `true` | `true`/`false` | Channel type: `true` = NMF (N-channel), `false` = PMF (P-channel) |
| `vto` | $V_{TO}$ | V | $-2.0$ | $(-\infty, \infty)$ | Pinch-off (threshold) voltage |
| `alpha` | $\alpha$ | 1/V | $2.0$ | $[0, \infty)$ | Saturation voltage parameter |
| `beta` | $\beta$ | A/V$^2$ | $2.5 \times 10^{-3}$ | $[0, \infty)$ | Transconductance coefficient |
| `lambda` | $\lambda$ | 1/V | $0.0$ | $[0, \infty)$ | Channel-length modulation parameter |
| `b` | $B$ | 1/V | $0.3$ | $[0, \infty)$ | Doping tail extending parameter |
| `rd` | $R_d$ | $\Omega$ | $0.0$ | $[0, \infty)$ | Drain ohmic resistance |
| `rs` | $R_s$ | $\Omega$ | $0.0$ | $[0, \infty)$ | Source ohmic resistance |
| `cgs` | $C_{gs}$ | F | $0.0$ | $[0, \infty)$ | Zero-bias gate-source junction capacitance |
| `cgd` | $C_{gd}$ | F | $0.0$ | $[0, \infty)$ | Zero-bias gate-drain junction capacitance |
| `pb` | $\phi_B$ | V | $1.0$ | $(0, \infty)$ | Gate junction built-in potential |
| `is` | $I_S$ | A | $1 \times 10^{-14}$ | $(0, \infty)$ | Gate junction saturation current |
| `fc` | $FC$ | -- | $0.5$ | $[0, 1)$ | Forward-bias depletion capacitance linearization coefficient |
| `kf` | $K_F$ | -- | $0.0$ | $[0, \infty)$ | Flicker noise coefficient |
| `af` | $A_F$ | -- | $1.0$ | $[0, \infty)$ | Flicker noise exponent |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `area` | $AREA$ | -- | $1.0$ | $(0, \infty)$ | Device area scaling factor |

## Equations

### Constants

$$V_T = k_B T / q = 8.617333262145 \times 10^{-5} \times 300.15 \approx 0.025864 \;\text{V}$$

Thermal voltage at nominal temperature ($T = 300.15$ K). Used throughout junction and limiting equations.

$$g_{min} = 1 \times 10^{-12} \;\text{S}$$

Minimum conductance added to junction currents for numerical conditioning.

### Polarity Handling

$$s = \begin{cases} +1 & \text{NMF (N-channel)} \\ -1 & \text{PMF (P-channel)} \end{cases}$$

$$V_{gs,raw} = s \cdot (V_G - V_S)$$

$$V_{gd,raw} = s \cdot (V_G - V_D)$$

$$V_{ds,raw} = V_{gs,raw} - V_{gd,raw}$$

### Source/Drain Reversal

When $V_{ds,raw} < 0$, internal source and drain are swapped:

$$V_{gs,eff} = \begin{cases} V_{gd,raw} & V_{ds,raw} < 0 \\ V_{gs,raw} & V_{ds,raw} \geq 0 \end{cases}$$

$$V_{ds,eff} = |V_{ds,raw}|$$

### Gate-Source Junction Diode Current

Schottky diode with cubic reverse-bias protection (ngspice convention):

**Forward/mild reverse** ($V_{gs,raw} / V_T \geq -3$):

$$I_{gs} = I_S \left( e^{\min(V_{gs,raw}/V_T,\; 80)} - 1 \right) + g_{min} \cdot V_{gs,raw}$$

Exponential argument clamped to 80 to prevent overflow.

**Deep reverse** ($V_{gs,raw} / V_T < -3$):

$$\text{arg} = \left( \frac{3 V_T}{V_{gs,raw} \cdot e} \right)^3$$

$$I_{gs} = -I_S \left(1 + \text{arg}\right) + g_{min} \cdot V_{gs,raw}$$

### Gate-Drain Junction Diode Current

Identical structure to gate-source, evaluated at $V_{gd,raw}$:

**Forward/mild reverse** ($V_{gd,raw} / V_T \geq -3$):

$$I_{gd} = I_S \left( e^{\min(V_{gd,raw}/V_T,\; 80)} - 1 \right) + g_{min} \cdot V_{gd,raw}$$

**Deep reverse** ($V_{gd,raw} / V_T < -3$):

$$\text{arg} = \left( \frac{3 V_T}{V_{gd,raw} \cdot e} \right)^3$$

$$I_{gd} = -I_S \left(1 + \text{arg}\right) + g_{min} \cdot V_{gd,raw}$$

### Drain Current (Curtice Model)

**Intermediate quantities:**

$$V_{gst} = V_{gs,eff} - V_{TO}$$

$$V_{gst}^{+} = \max(V_{gst},\; 0) \quad \text{(cutoff when } V_{gst} \leq 0\text{)}$$

$$\beta' = \beta \cdot (1 + \lambda \cdot V_{ds,eff})$$

$$\text{denom} = 1 + B \cdot V_{gst}^{+}$$

**Saturation region** ($V_{ds,eff} \geq 3/\alpha$):

$$I_{d,sat} = \beta' \cdot \frac{(V_{gst}^{+})^2}{\text{denom}}$$

**Linear region** ($V_{ds,eff} < 3/\alpha$):

$$a_{fact} = 1 - \frac{\alpha \cdot V_{ds,eff}}{3}$$

$$\ell_{fact} = 1 - a_{fact}^3$$

$$I_{d,lin} = \beta' \cdot \frac{(V_{gst}^{+})^2}{\text{denom}} \cdot \ell_{fact}$$

**Region selection:**

$$I_{d,raw} = \begin{cases} I_{d,sat} & V_{ds,eff} \geq 3/\alpha \\ I_{d,lin} & V_{ds,eff} < 3/\alpha \end{cases}$$

**Reversal correction:**

$$I_d = \begin{cases} -I_{d,raw} & V_{ds,raw} < 0 \\ I_{d,raw} & V_{ds,raw} \geq 0 \end{cases}$$

### Area Scaling

$$I_d^{scaled} = I_d \cdot AREA$$

$$I_{gs}^{scaled} = I_{gs} \cdot AREA$$

$$I_{gd}^{scaled} = I_{gd} \cdot AREA$$

### KCL Terminal Currents

Positive current flows into the device terminal:

$$I_{Drain} = s \cdot \left( I_d^{scaled} - I_{gd}^{scaled} \right)$$

$$I_{Gate} = s \cdot \left( I_{gs}^{scaled} + I_{gd}^{scaled} \right)$$

$$I_{Source} = s \cdot \left( -I_d^{scaled} - I_{gs}^{scaled} \right)$$

### Gate-Source Depletion Charge

Junction grading coefficient fixed at $m = 0.5$.

**Depletion region** ($V_{gs} < FC \cdot \phi_B$):

$$Q_{gs,dep} = \frac{C_{gs} \cdot \phi_B}{1 - m} \left[ 1 - \left(1 - \frac{V_{gs}}{\phi_B}\right)^{1-m} \right]$$

**Forward-bias linearization** ($V_{gs} \geq FC \cdot \phi_B$):

$$Q_{gs} = C_{gs} \left[ Q_{dep}(FC \cdot \phi_B) + \frac{V_{gs} - FC \cdot \phi_B}{(1 - FC)^m} \right]$$

where $Q_{dep}(FC \cdot \phi_B)$ is the normalized depletion charge evaluated at $V_{gs} = FC \cdot \phi_B$:

$$Q_{dep}(FC \cdot \phi_B) = \frac{\phi_B}{1-m} \left[ 1 - (1 - FC)^{1-m} \right]$$

If $C_{gs} = 0$, then $Q_{gs} = 0$ (capacitor omitted).

### Gate-Drain Depletion Charge

Identical to gate-source charge, evaluated at $V_{gd}$:

**Depletion region** ($V_{gd} < FC \cdot \phi_B$):

$$Q_{gd,dep} = \frac{C_{gd} \cdot \phi_B}{1 - m} \left[ 1 - \left(1 - \frac{V_{gd}}{\phi_B}\right)^{1-m} \right]$$

**Forward-bias linearization** ($V_{gd} \geq FC \cdot \phi_B$):

$$Q_{gd} = C_{gd} \left[ Q_{dep}(FC \cdot \phi_B) + \frac{V_{gd} - FC \cdot \phi_B}{(1 - FC)^m} \right]$$

If $C_{gd} = 0$, then $Q_{gd} = 0$ (capacitor omitted).

### Charge Area Scaling

$$Q_{gs}^{scaled} = Q_{gs} \cdot AREA$$

$$Q_{gd}^{scaled} = Q_{gd} \cdot AREA$$

### Charge KCL Contributions

$$Q_{Drain} = -Q_{gd}^{scaled}$$

$$Q_{Gate} = Q_{gs}^{scaled} + Q_{gd}^{scaled}$$

$$Q_{Source} = -Q_{gs}^{scaled}$$

Displacement currents are obtained by the solver via $I_C = dQ/dt$.

### Noise Sources

Four noise generators declared on this device:

| Generator | Nodes | Type | Spectral Density |
|-----------|-------|------|-----------------|
| Drain resistance thermal | Drain--Source | Thermal | $S_I = 4 k_B T / R_d$ |
| Source resistance thermal | Source--Drain | Thermal | $S_I = 4 k_B T / R_s$ |
| Drain current shot | Drain--Source | Shot | $S_I = 2 q I_d$ |
| Drain current flicker | Drain--Source | Flicker | $S_I = K_F \cdot I_d^{A_F} / f$ |

### Newton Voltage Limiting

Critical voltage for junction limiting:

$$V_{crit} = V_T \cdot \ln\!\left(\frac{V_T}{\sqrt{2} \cdot I_S}\right)$$

Applied independently to $V_{gs}$ and $V_{gd}$. Limiting activates when $V_{jn,new} > V_{crit}$ **and** $|V_{jn,new} - V_{jn,old}| > 2 V_T$:

**Case 1:** $V_{jn,old} > 0$ and $\text{arg} = (V_{jn,new} - V_{jn,old})/V_T > 0$:

$$V_{jn,lim} = V_{jn,old} + V_T \left(2 + \ln(\text{arg} - 2)\right)$$

**Case 2:** $V_{jn,old} > 0$ and $\text{arg} \leq 0$:

$$V_{jn,lim} = V_{crit}$$

**Case 3:** $V_{jn,old} \leq 0$:

$$V_{jn,lim} = V_T \cdot \ln\!\left(\frac{V_{jn,new}}{V_T}\right)$$

The gate node voltage is then adjusted: $V_G \mathrel{+}= V_{jn,lim} - V_{jn,new}$.

### Convergence Aid: Parameter Stepping (Gmin Stepping)

During continuation ($\lambda \in [0, 1]$), the saturation current is relaxed:

$$I_S(\lambda) = I_S + (10^{-12} - I_S) \cdot (1 - \lambda)$$

At $\lambda = 0$: $I_S = 10^{-12}$ A (easy convergence). At $\lambda = 1$: $I_S$ returns to its model value.
