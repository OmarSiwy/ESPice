# VDMOS (Vertical DMOS Power MOSFET) -- Parameter & Equation Reference

> Level-1 vertical double-diffused MOSFET with body diode, subthreshold conduction, quasi-saturation, non-linear gate-drain capacitance, breakdown, and self-heating thermal network.

## Model Topology

Three-terminal device: **Drain (D)**, **Gate (G)**, **Source (S)**. The intrinsic MOSFET channel connects drain to source, controlled by gate-source voltage. An anti-parallel body diode is present from source to drain (forward direction S->D). Gate is ideal (no DC current). Optional series resistances RD, RS, RG, RB are modeled externally. A drain-source shunt resistance RDS provides off-state leakage. PMOS operation is supported via `type_` sign inversion of all terminal voltages.

## Parameters

### Device Type & Geometry

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| type_ | - | - | 1 | {-1, 1} | Device type: 1 = NMOS, -1 = PMOS |
| w | W | m | 1e-6 | >0 | Channel width (instance) |
| l | L | m | 1e-6 | >0 | Channel length (instance) |
| m | M | - | 1.0 | >0 | Parallel device multiplier (instance) |
| area | AREA | - | 1.0 | >0 | Junction area factor (instance) |
| temp | TEMP | K | 300.15 | >0 | Device temperature (instance) |

### DC -- MOSFET Channel

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vto | VTO | V | 0 | - | Threshold voltage |
| kp | KP | A/V^2 | 2e-5 | >0 | Transconductance parameter |
| ld | LD | m | 0 | >=0 | Lateral diffusion |
| phi | PHI | V | 0.6 | >0 | Surface potential |
| lambda | LAMBDA | 1/V | 0 | >=0 | Channel-length modulation parameter |
| theta | THETA | 1/V | 0 | >=0 | V_gs dependence on mobility |
| mtriode | MTRIODE | - | 1 | - | Conductance multiplier in triode region |
| rds | RDS | Ohm | 1e15 | >0 | Drain-source shunt resistance |

### DC -- Subthreshold

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ksubthres | KSUBTHRES | V | 0.1 | >0 | Slope of weak-inversion log-current vs V_gs |
| subshift | SUBSHIFT | V | 0 | - | Shift of weak-inversion curve on V_gs axis |
| tksubthres1 | TKSUBTHRES1 | 1/K | 0 | - | Linear temperature coefficient of KSUBTHRES |
| tksubthres2 | TKSUBTHRES2 | 1/K^2 | 0 | - | Quadratic temperature coefficient of KSUBTHRES |

### DC -- Quasi-Saturation

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rq | RQ | Ohm | 0 | >=0 | Quasi-saturation resistance fitting parameter |
| vq | VQ | V | 0 | >=0 | Quasi-saturation voltage fitting parameter |

### DC -- Body Diode

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| is | IS | A | 1e-14 | >0 | Body diode saturation current |
| n | N | - | 1 | >0 | Body diode emission coefficient |
| bv | BV | V | inf | >0 | V_ds breakdown voltage |
| ibv | IBV | A | 1e-10 | >0 | Current at V_ds = BV |
| nbv | NBV | - | 1 | >0 | V_ds breakdown emission coefficient |
| eg | EG | eV | 1.11 | >0 | Body diode activation energy for temperature effect on I_S |
| xti | XTI | - | 3 | - | Body diode saturation current temperature exponent |
| rb | RB | Ohm | 0 | >=0 | Body diode ohmic resistance |

### Series Resistances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rd | RD | Ohm | 0 | >=0 | Drain ohmic resistance |
| rs | RS | Ohm | 0 | >=0 | Source ohmic resistance |
| rg | RG | Ohm | 0 | >=0 | Gate ohmic resistance |

### Temperature Coefficients

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tnom | TNOM | degC | 27 | - | Parameter measurement temperature |
| tcvth | TCVTH | V/K | 0 | - | Linear V_th temperature coefficient |
| mu | MU | - | -1.5 | - | Exponent of gain temperature dependency |
| texp0 | TEXP0 | - | 1.5 | - | Drain resistance RD0 temperature exponent |
| texp1 | TEXP1 | - | 0.3 | - | Drain resistance RD1 temperature exponent |
| trd1 | TRD1 | 1/K | 0 | - | Drain resistance linear temperature coefficient |
| trd2 | TRD2 | 1/K^2 | 0 | - | Drain resistance quadratic temperature coefficient |
| trg1 | TRG1 | 1/K | 0 | - | Gate resistance linear temperature coefficient |
| trg2 | TRG2 | 1/K^2 | 0 | - | Gate resistance quadratic temperature coefficient |
| trs1 | TRS1 | 1/K | 0 | - | Source resistance linear temperature coefficient |
| trs2 | TRS2 | 1/K^2 | 0 | - | Source resistance quadratic temperature coefficient |
| trb1 | TRB1 | 1/K | 0 | - | Body resistance linear temperature coefficient |
| trb2 | TRB2 | 1/K^2 | 0 | - | Body resistance quadratic temperature coefficient |

### Capacitances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cgs | CGS | F | 0 | >=0 | Gate-source capacitance (linear) |
| cgdmin | CGDMIN | F | 0 | >=0 | Minimum non-linear gate-drain capacitance |
| cgdmax | CGDMAX | F | 0 | >=0 | Maximum non-linear gate-drain capacitance |
| a | A | 1/V | 1 | >0 | Non-linear C_gd capacitance parameter |
| cjo | CJO | F | 0 | >=0 | Zero-bias body diode junction capacitance |
| vj | VJ | V | 0.8 | >0 | Body diode junction potential |
| m (model) | M | - | 0.5 | 0..1 | Body diode grading coefficient |
| fc | FC | - | 0.5 | 0..1 | Forward-bias depletion capacitance coefficient |
| tt | TT | s | 0 | >=0 | Body diode transit time |

### Self-Heating

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rthjc | RTHJC | K/W | 1 | >0 | Thermal resistance, junction to case |
| rthca | RTHCA | K/W | 1000 | >0 | Thermal resistance, case to ambient |
| cthj | CTHJ | J/K | 1e-5 | >0 | Thermal capacitance at junction |
| rth_ext | RTH_EXT | K/W | 1000 | >0 | Thermal resistance, case to ambient incl. heat sink |
| derating | DERATING | - | 0 | >=0 | Thermal derating for power |

### Noise

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| kf | KF | - | 0 | >=0 | Flicker noise coefficient |
| af | AF | - | 1 | >0 | Flicker noise exponent |

### Absolute Maximum Ratings

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vgs_max | VGS_MAX | V | inf | >0 | Maximum gate-source voltage |
| vgd_max | VGD_MAX | V | inf | >0 | Maximum gate-drain voltage |
| vds_max | VDS_MAX | V | inf | >0 | Maximum drain-source voltage |
| vgsr_max | VGSR_MAX | V | inf | >0 | Maximum reverse gate-source voltage |
| vgdr_max | VGDR_MAX | V | inf | >0 | Maximum reverse gate-drain voltage |
| pd_max | PD_MAX | W | inf | >0 | Maximum device power dissipation |
| id_max | ID_MAX | A | 0 | >=0 | Maximum drain/source current |
| idr_max | IDR_MAX | A | inf | >0 | Maximum drain/source reverse current |
| te_max | TE_MAX | K | inf | >0 | Maximum temperature |

## Equations

### Voltage Preprocessing

PMOS sign inversion:

$$ V_{gs} = (V_g - V_s) \cdot \text{type} $$

$$ V_{ds} = (V_d - V_s) \cdot \text{type} $$

where $\text{type} = +1$ (NMOS) or $-1$ (PMOS).

Source-drain reversal (smooth):

$$ |V_{ds}| = \sqrt{V_{ds}^2 + \varepsilon_{sd}}, \quad \varepsilon_{sd} = 10^{-30} $$

$$ \text{mode} = \frac{V_{ds}}{|V_{ds}|} $$

$$ V_{ds,\text{int}} = |V_{ds}| $$

$$ V_{gs,\text{int}} = V_{gs} - \frac{1 - \text{mode}}{2} \cdot V_{ds} $$

When $V_{ds} \ge 0$: normal mode ($V_{gs,\text{int}} = V_{gs}$, $V_{ds,\text{int}} = V_{ds}$). When $V_{ds} < 0$: reversed ($V_{gs,\text{int}} = V_{gs} - V_{ds} = V_{gd}$, $V_{ds,\text{int}} = |V_{ds}|$).

### Temperature Scaling

Temperature difference from nominal:

$$ T_{\text{nom},K} = T_{\text{nom}} + 273.15 $$

$$ \Delta T = T_{\text{dev}} - T_{\text{nom},K} $$

Threshold voltage:

$$ V_{th}(T) = V_{TO} + TCVTH \cdot \Delta T $$

Transconductance parameter:

$$ KP(T) = KP \cdot \left(\frac{T_{\text{dev}}}{T_{\text{nom},K}}\right)^{\mu} $$

### Channel Current

Effective geometry:

$$ L_{\text{eff}} = \max(L - 2 \cdot LD, \; 10^{-9}) $$

$$ W_{\text{eff}} = \max(W, \; 10^{-9}) $$

$$ \beta = \frac{KP(T) \cdot W_{\text{eff}}}{L_{\text{eff}}} $$

Gate overdrive:

$$ V_{gst} = V_{gs} - V_{th} $$

Subthreshold smoothing (softplus):

$$ V_{gst,\text{eff}} = KSUBTHRES \cdot \ln\!\left(1 + \exp\!\left(\min\!\left(\frac{V_{gst} - SUBSHIFT}{KSUBTHRES},\; 80\right)\right)\right) $$

This provides exponential subthreshold roll-off below threshold and approaches $V_{gst}$ above threshold.

Mobility degradation:

$$ f_\theta = \frac{1}{1 + \theta \cdot V_{gst}} $$

Channel-length modulation:

$$ f_\lambda = 1 + \lambda \cdot V_{ds} $$

Effective drain-source voltage (smooth saturation clamp):

$$ V_{dsat} = V_{gst,\text{eff}} $$

$$ V_{ds,\text{eff}} = \frac{V_{ds} + V_{dsat} - \sqrt{(V_{ds} - V_{dsat})^2 + \varepsilon}}{2}, \quad \varepsilon = 10^{-12} $$

This smoothly limits $V_{ds,\text{eff}}$ to $\min(V_{ds}, V_{dsat})$.

Triode multiplier (smooth blend):

$$ s = \frac{1}{2}\left(1 + \frac{V_{ds} - V_{dsat}}{\sqrt{(V_{ds} - V_{dsat})^2 + \varepsilon}}\right) $$

$$ f_{mtr} = MTRIODE + (1 - MTRIODE) \cdot s $$

$s \to 0$ in triode (applies MTRIODE), $s \to 1$ in saturation (factor becomes 1).

Forward drain current:

$$ I_{d,\text{fwd}} = \beta \cdot \left(V_{gst,\text{eff}} \cdot V_{ds,\text{eff}} - \frac{1}{2} V_{ds,\text{eff}}^2\right) \cdot f_\lambda \cdot f_\theta \cdot f_{mtr} $$

Reversal correction:

$$ I_d = I_{d,\text{fwd}} \cdot \text{mode} $$

### Drain-Source Shunt Resistance

$$ I_{rds} = \frac{V_{ds,\text{orig}}}{RDS} \quad \text{if } 0 < RDS < 10^{30}, \text{ else } 0 $$

where $V_{ds,\text{orig}} = (V_d - V_s) \cdot \text{type}$ (unsymmetrized).

### GMIN Convergence Aid

$$ I_{gmin} = g_{min} \cdot V_{ds,\text{orig}}, \quad g_{min} = 10^{-12} $$

### Body Diode Current

Thermal voltage (at device temperature):

$$ V_T = k_B T_{\text{dev}} / q = 8.617333 \times 10^{-5} \cdot T_{\text{dev}} $$

$$ n V_T = N \cdot V_T $$

Forward diode voltage (source-drain, NMOS forward when $V_s > V_d$):

$$ V_{sd} = (V_s - V_d) \cdot \text{type} $$

Diode current:

$$ I_{\text{diode}} = IS \cdot \left(\exp\!\left(\min\!\left(\frac{V_{sd}}{n V_T},\; 80\right)\right) - 1\right) + g_{min} \cdot V_{sd} $$

### Body Diode Breakdown

Active only when $BV < \infty$:

$$ I_{\text{bkdn}} = -IS \cdot \exp\!\left(\min\!\left(\frac{-(BV + V_{sd})}{NBV \cdot V_T},\; 80\right)\right) $$

$$ I_{\text{diode,total}} = I_{\text{diode}} + I_{\text{bkdn}} $$

### Total Node Currents (KCL)

$$ I_{d,\text{total}} = (I_d + I_{rds} + I_{gmin} - I_{\text{diode,total}}) \cdot M $$

Output with PMOS sign restoration:

$$ I_{D,\text{out}} = I_{d,\text{total}} \cdot \text{type} $$

$$ I_{G,\text{out}} = 0 $$

$$ I_{S,\text{out}} = -I_{D,\text{out}} $$

### Gate-Source Charge

$$ Q_{gs} = CGS \cdot V_{gs} $$

Linear capacitance; $V_{gs} = V_g - V_s$ (without PMOS sign flip in charge function).

### Gate-Drain Charge (Non-Linear Cgd)

Capacitance model (ngspice tanh form):

$$ C_{gd}(V_{gd}) = C_{gd,\min} + \frac{C_{gd,\max} - C_{gd,\min}}{1 + \exp(2a \cdot V_{gd})} $$

Charge (analytical integral of $C_{gd}$):

When $C_{gd,\min} = C_{gd,\max}$:

$$ Q_{gd} = C_{gd,\min} \cdot V_{gd} $$

Otherwise:

$$ Q_{gd} = C_{gd,\min} \cdot V_{gd} + \frac{C_{gd,\max} - C_{gd,\min}}{2a} \cdot \left(2a \cdot V_{gd} - \ln\!\left(1 + \exp\!\left(\min(2a \cdot V_{gd},\; 80)\right)\right)\right) $$

### Body Diode Junction Charge

Depletion charge (when $CJO > 0$):

$$ Q_{\text{dep}} = \frac{CJO \cdot VJ}{1 - M_j} \cdot \left(1 - \left(1 - \frac{V_{sd}}{VJ}\right)^{1-M_j}\right) $$

Transit time diffusion charge:

$$ I_{\text{diode,q}} = IS \cdot \left(\exp\!\left(\min\!\left(\frac{V_{sd}}{n V_T},\; 80\right)\right) - 1\right) $$

$$ Q_{tt} = TT \cdot I_{\text{diode,q}} $$

Total body diode charge:

$$ Q_{sd} = Q_{\text{dep}} + Q_{tt} $$

### Charge Node Contributions

$$ Q_D = -Q_{gd} - Q_{sd} $$

$$ Q_G = Q_{gs} + Q_{gd} $$

$$ Q_S = -Q_{gs} + Q_{sd} $$

Displacement currents are obtained by the solver via $I_C = dQ/dt$.

### Noise Sources

Four noise generators between drain (node 0) and source (node 2):

**Drain resistance thermal noise** (D-S):

$$ S_{I,\text{th}} = 4 k_B T \cdot g_{ds} $$

**Source resistance thermal noise** (S-D):

$$ S_{I,\text{th}} = 4 k_B T \cdot g_{sd} $$

**Drain current shot noise** (D-S):

$$ S_{I,\text{shot}} = 2 q \cdot |I_D| $$

**Drain current flicker noise** (D-S):

$$ S_{I,\text{flicker}} = \frac{KF \cdot |I_D|^{AF}}{f} $$

### Newton Limiting -- Body Diode (PN Junction)

Critical voltage:

$$ V_{\text{crit}} = n V_T \cdot \ln\!\left(\frac{n V_T}{\sqrt{2} \cdot IS}\right) $$

where $V_T$ is evaluated at $T_{\text{nom}}$.

When $V_{sd,\text{new}} > V_{\text{crit}}$ and $|V_{sd,\text{new}} - V_{sd,\text{old}}| > 2 n V_T$:

If $V_{sd,\text{old}} > 0$:

$$
V_{sd,\text{lim}} = \begin{cases}
V_{sd,\text{old}} + n V_T \cdot (2 + \ln(\arg - 2)) & \text{if } \arg > 0 \\
V_{\text{crit}} & \text{otherwise}
\end{cases}
$$

where $\arg = (V_{sd,\text{new}} - V_{sd,\text{old}}) / (n V_T)$.

If $V_{sd,\text{old}} \le 0$:

$$ V_{sd,\text{lim}} = n V_T \cdot \ln(V_{sd,\text{new}} / n V_T) $$

The limiting delta is applied to $V_S$.

### Newton Limiting -- MOSFET Gate (DEVfetlim)

Threshold parameters:

$$ V_{\text{tsthi}} = |2(V_{gs,\text{old}} - V_{TO})| + 2 $$

$$ V_{\text{tstlo}} = V_{\text{tsthi}} / 2 + 2 $$

$$ V_{tox} = V_{TO} + 3.5 $$

$$ \delta V = V_{gs,\text{new}} - V_{gs,\text{old}} $$

**Above threshold** ($V_{gs,\text{old}} \ge V_{TO}$):

- If $V_{gs,\text{old}} \ge V_{tox}$ (well above):
  - Decreasing ($\delta V \le 0$): if $V_{gs,\text{new}} \ge V_{tox}$ and $-\delta V > V_{\text{tsthi}}$, clamp to $V_{gs,\text{old}} - V_{\text{tsthi}}$; else clamp to $\max(V_{gs,\text{new}},\, V_{TO} + 2)$.
  - Increasing ($\delta V > 0$): if $\delta V \ge V_{\text{tsthi}}$, clamp to $V_{gs,\text{old}} + V_{\text{tsthi}}$.
- If $V_{gs,\text{old}} < V_{tox}$ (transition region):
  - Decreasing: clamp to $V_{gs,\text{old}} - V_{\text{tsthi}}$ if $-\delta V > V_{\text{tsthi}}$.
  - Increasing: clamp to $V_{gs,\text{old}} + V_{\text{tstlo}}$ if $\delta V \ge V_{\text{tstlo}}$.

**Below threshold** ($V_{gs,\text{old}} < V_{TO}$):

- Decreasing: clamp to $V_{gs,\text{old}} - V_{\text{tsthi}}$ if $-\delta V > V_{\text{tsthi}}$.
- Increasing: clamp to $V_{gs,\text{old}} + V_{\text{tstlo}}$ if $\delta V \ge V_{\text{tstlo}}$.

### Newton Limiting -- Drain-Source (DEVlimvds)

If $V_{ds,\text{old}} \ge 3.5$:

$$
V_{ds,\text{lim}} = \begin{cases}
\min(V_{ds,\text{new}},\; 3 V_{ds,\text{old}} + 2) & \text{if } V_{ds,\text{new}} > V_{ds,\text{old}} \\
\max(V_{ds,\text{new}},\; 2) & \text{if } V_{ds,\text{new}} < 3.5 \\
V_{ds,\text{new}} & \text{otherwise}
\end{cases}
$$

If $V_{ds,\text{old}} < 3.5$:

$$
V_{ds,\text{lim}} = \begin{cases}
\min(V_{ds,\text{new}},\; 4) & \text{if } V_{ds,\text{new}} > V_{ds,\text{old}} \\
\max(V_{ds,\text{new}},\; -0.5) & \text{otherwise}
\end{cases}
$$

### Convergence Aid -- Parameter Stepping (Gmin Stepping)

At continuation factor $\lambda \in [0, 1]$:

$$ IS_{\text{eff}} = IS + (10^{-12} - IS) \cdot (1 - \lambda) $$

At $\lambda = 0$: $IS_{\text{eff}} = 10^{-12}$ (easy convergence). At $\lambda = 1$: $IS_{\text{eff}} = IS$ (nominal).
