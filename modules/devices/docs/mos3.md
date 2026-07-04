# MOS Level 3 (MOS3) -- Parameter & Equation Reference

> Semi-empirical short-channel MOSFET model (Berkeley SPICE3f5 Level 3)

## Model Topology

Four external terminals: **Drain (D)**, **Gate (G)**, **Source (S)**, **Bulk (B)**. Two internal nodes: **Drain' (D')** and **Source' (S')** separated from external drain and source by series resistances $R_D$ and $R_S$. The intrinsic MOSFET connects D'--G--S'--B with gate oxide capacitances (Meyer model), bulk junction diodes (B-S', B-D'), and the channel current source between D' and S'.

## Parameters

### DC Model Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `vto` | $V_{T0}$ | V | 0 | | Zero-bias threshold voltage |
| `kp` | $K_P$ | A/V^2 | 2.07189e-5 | | Transconductance parameter |
| `gamma` | $\gamma$ | V^{1/2} | 0 | | Bulk threshold (body effect) parameter |
| `phi` | $\phi$ | V | 0.6 | | Surface potential at strong inversion |
| `nsub` | $N_{SUB}$ | cm^{-3} | 0 | | Substrate doping concentration |
| `nss` | $N_{SS}$ | cm^{-2} | 0 | | Surface state density |
| `nfs` | $N_{FS}$ | cm^{-2} | 0 | | Fast surface state density |
| `tpg` | | | 0 | 0,1,-1 | Gate type (0=aluminum, +1=opposite, -1=same as substrate) |
| `eta` | $\eta$ | | 0 | | Vds dependence of threshold voltage (DIBL) |
| `delta` | $\delta$ | | 0 | | Width effect on threshold voltage (narrow channel) |
| `input_delta` | | | 0 | | Input delta |
| `theta` | $\theta$ | 1/V | 0 | | Vgs dependence of mobility (mobility degradation) |
| `kappa` | $\kappa$ | | 0.2 | | Channel-length modulation parameter |
| `alpha` | $\alpha$ | | 0 | | Alpha (impact ionization) |
| `u0` | $\mu_0$ | cm^2/V-s | 600 | | Low-field surface mobility |
| `vmax` | $v_{max}$ | m/s | 0 | | Maximum carrier drift velocity |
| `xj` | $X_J$ | m | 0 | | Metallurgical junction depth |
| `delvto` | $\Delta V_{T0}$ | V | 0 | | Threshold voltage adjust |
| `type_` | | | 1 | {-1, 1} | Device polarity: 1=NMOS, -1=PMOS |

### Geometry Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `l` | $L$ | m | 1e-6 | | Drawn channel length |
| `w` | $W$ | m | 1e-6 | | Drawn channel width |
| `ld` | $L_D$ | m | 0 | | Lateral diffusion length |
| `xl` | $X_L$ | m | 0 | | Length mask adjustment |
| `wd` | $W_D$ | m | 0 | | Width narrowing (diffusion) |
| `xw` | $X_W$ | m | 0 | | Width mask adjustment |
| `tox` | $t_{ox}$ | m | 1e-7 | | Gate oxide thickness |

### Series Resistance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `rd` | $R_D$ | Ohm | 0 | | Drain ohmic resistance |
| `rs` | $R_S$ | Ohm | 0 | | Source ohmic resistance |
| `rsh` | $R_{SH}$ | Ohm/sq | 0 | | Sheet resistance |

### Junction Diode Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `is_` | $I_S$ | A | 1e-14 | | Bulk junction saturation current |
| `js` | $J_S$ | A/m^2 | 0 | | Bulk junction saturation current density |
| `pb` | $P_B$ | V | 0.8 | | Bulk junction built-in potential |
| `fc` | $F_C$ | | 0.5 | | Forward-bias junction capacitance fitting parameter |

### Junction Capacitance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cbd` | $C_{BD}$ | F | 0 | | Zero-bias bulk-drain junction capacitance |
| `cbs` | $C_{BS}$ | F | 0 | | Zero-bias bulk-source junction capacitance |
| `cj` | $C_J$ | F/m^2 | 0 | | Zero-bias bottom junction capacitance per unit area |
| `mj` | $M_J$ | | 0.5 | | Bottom junction grading coefficient |
| `cjsw` | $C_{JSW}$ | F/m | 0 | | Zero-bias sidewall junction capacitance per unit length |
| `mjsw` | $M_{JSW}$ | | 0.33 | | Sidewall junction grading coefficient |

### Overlap Capacitance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cgso` | $C_{GSO}$ | F/m | 0 | | Gate-source overlap capacitance per unit width |
| `cgdo` | $C_{GDO}$ | F/m | 0 | | Gate-drain overlap capacitance per unit width |
| `cgbo` | $C_{GBO}$ | F/m | 0 | | Gate-bulk overlap capacitance per unit length |

### Noise Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `kf` | $K_F$ | | 0 | | Flicker noise coefficient |
| `af` | $A_F$ | | 1 | | Flicker noise exponent |
| `nlev` | | | 2 | | Noise model selection level |
| `gdsnoi` | | | 1 | | Channel shot noise coefficient |

### Temperature & Instance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `tnom` | $T_{nom}$ | deg C | 27 | | Parameter measurement temperature |
| `temp` | $T$ | deg C | 27.0 | | Device operating temperature |
| `m` | $M$ | | 1.0 | | Multiplier (parallel instances) |

## Equations

### Effective Geometry

$$L_{eff} = \max(L - 2 L_D + X_L,\; 1\times10^{-9})$$

$$W_{eff} = \max(W - 2 W_D + X_W,\; 1\times10^{-9})$$

### Physical Constants (Computed)

$$\varepsilon_{Si} = 11.7 \times 8.854214871\times10^{-12} \;\text{F/m}$$

$$C_{ox}' = \frac{3.9 \times 8.854214871\times10^{-12}}{t_{ox}} \quad (\text{oxide capacitance per unit area})$$

### Thermal Voltage

$$V_T = \frac{k T_{device}}{q} = 8.617333 \times 10^{-5} \cdot (T + 273.15)$$

### Series Resistances

$$G_{RD} = \begin{cases} 1/R_D & R_D > 0 \\ 10^{12} & R_D = 0 \end{cases}$$

$$G_{RS} = \begin{cases} 1/R_S & R_S > 0 \\ 10^{12} & R_S = 0 \end{cases}$$

$$I_{RD} = (V_D - V_{D'}) \cdot G_{RD}$$

$$I_{RS} = (V_S - V_{S'}) \cdot G_{RS}$$

### Source/Drain Reversal (Mode Selection)

For PMOS, all terminal voltages are negated: $V_{GS} \leftarrow -V_{GS}$, $V_{DS} \leftarrow -V_{DS}$, $V_{BS} \leftarrow -V_{BS}$.

Source/drain interchange when $V_{DS} < 0$:
$$V_{DS,eff} = |V_{DS}|$$

$$\text{step}_{fwd} = \frac{V_{DS} + |V_{DS}|}{2 \cdot (|V_{DS}| + \epsilon)}$$

$$V_{GS,use} = V_{GS,fwd} \cdot \text{step}_{fwd} + V_{GS,rev} \cdot (1 - \text{step}_{fwd})$$

$$V_{BS,use} = V_{BS,fwd} \cdot \text{step}_{fwd} + V_{BS,rev} \cdot (1 - \text{step}_{fwd})$$

where $V_{GS,rev} = V_{GS} - V_{DS}$, $V_{BS,rev} = V_{BS} - V_{DS}$, $\epsilon = 10^{-30}$.

### Bulk Junction Diode Currents

$$I_{BS} = I_S \left(\exp\!\left(\min\!\left(\frac{V_{BS,use}}{V_T},\, 80\right)\right) - 1\right) + G_{MIN} \cdot V_{BS,use}$$

$$I_{BD} = I_S \left(\exp\!\left(\min\!\left(\frac{V_{BD}}{V_T},\, 80\right)\right) - 1\right) + G_{MIN} \cdot V_{BD}$$

where $V_{BD} = V_{BS,use} - V_{DS,eff}$ and $G_{MIN} = 10^{-12}$.

### Depletion Layer Coefficient

$$\alpha_{dep} = \frac{2 \varepsilon_{Si}}{q \cdot N_{SUB} \times 10^{6}} \quad (N_{SUB} > 0)$$

$$\text{coeffDepLayWidth} = \sqrt{\alpha_{dep}}$$

### Square Root of Surface Potential (Bias-Dependent)

Reverse bias ($V_{BS} \le 0$):
$$\sqrt{\phi_{BS}} = \sqrt{\phi - V_{BS,use}}$$

Forward bias ($V_{BS} > 0$):
$$\sqrt{\phi_{BS}} = \frac{\sqrt{\phi}}{1 + V_{BS,use}/(2\phi)}$$

Smooth blend using sign-based step functions:
$$\sqrt{\phi_{BS}} = \sqrt{\phi_{BS,rev}} \cdot s_{neg} + \sqrt{\phi_{BS,fwd}} \cdot s_{pos}$$

where $s_{neg} = \frac{\max(-V_{BS}, 0)}{|V_{BS}| + \epsilon}$, $s_{pos} = \frac{\max(V_{BS}, 0)}{|V_{BS}| + \epsilon}$.

### Narrow Channel Effect

$$F_{narrow} = \frac{\delta \cdot \pi \cdot \varepsilon_{Si}}{2 \cdot C_{ox}'}$$

### ETA Scaling (DIBL Coefficient)

$$\eta_{scaled} = \frac{\eta \times 8.15\times10^{-22}}{C_{ox}' \cdot L_{eff}^3}$$

### Short-Channel Effect Factor

$$W_{PS} = \text{coeffDepLayWidth} \cdot \sqrt{\phi_{BS}}$$

$$W_{P/X_J} = \frac{W_{PS}}{X_J}$$

$$W_{C/X_J} = 0.0631353 + 0.8013292 \cdot W_{P/X_J} - 0.01110777 \cdot W_{P/X_J}^2$$

$$\text{argc} = \frac{W_{P/X_J}}{1 + W_{P/X_J}}$$

$$f_{short} = 1 - \frac{X_J}{L_{eff}} \left[(W_{C/X_J} + \frac{L_D}{X_J})\sqrt{1 - \text{argc}^2} - \frac{L_D}{X_J}\right]$$

If $X_J = 0$ or $\text{coeffDepLayWidth} = 0$, then $f_{short} = 1$.

### Body Effect

$$\gamma_s = \gamma \cdot f_{short}$$

$$f_{body,s} = \frac{\gamma_s}{4\sqrt{\phi_{BS}}}$$

$$f_{body} = f_{body,s} + \frac{F_{narrow}}{W_{eff}}$$

### Threshold Voltage

Built-in potential (temperature-adjusted):
$$V_{bi} = \Delta V_{T0} + V_{T0} - \text{type} \cdot \gamma \sqrt{\phi}$$

Bulk charge:
$$Q_{B}/C_{ox} = \gamma_s \sqrt{\phi_{BS}} + \frac{F_{narrow}}{W_{eff}} \cdot \phi_{BS}$$

Static feedback (DIBL):
$$V_{bix} = V_{bi} \cdot \text{type} - \eta_{scaled} \cdot V_{DS,eff}$$

Threshold voltage:
$$V_{th} = V_{bix} + Q_B/C_{ox}$$

### Subthreshold Region (Weak Inversion)

When $N_{FS} > 0$:

$$C_{s}/C_{ox} = \frac{q \cdot N_{FS} \times 10^4}{C_{ox}'}$$

$$C_{d}/C_{ox} = \frac{Q_B/C_{ox}}{2 \phi_{BS}}$$

$$x_n = 1 + C_s/C_{ox} + C_d/C_{ox}$$

$$V_{on} = V_{th} + V_T \cdot x_n$$

If $N_{FS} = 0$: $V_{on} = V_{th}$, $x_n = 1$.

Effective gate voltage (clamped to $V_{on}$):
$$V_{GSX} = \max(V_{GS,use},\; V_{on})$$

### Mobility Degradation

$$\beta = K_P \cdot \frac{W_{eff}}{L_{eff}}$$

$$f_{gate}^{-1} = 1 + \theta (V_{GSX} - V_{th})$$

### Saturation Voltage

Without velocity saturation ($v_{max} = 0$):
$$V_{DSAT} = \frac{V_{GSX} - V_{th}}{1 + f_{body}}$$

With velocity saturation ($v_{max} > 0$):
$$V_{DSC} = \frac{v_{max} \cdot L_{eff} \cdot f_{gate}^{-1}}{\mu_0 \times 10^{-4} \cdot f_{gate}}$$

$$a = \frac{V_{GSX} - V_{th}}{1 + f_{body}}, \quad b = \sqrt{a^2 + V_{DSC}^2}$$

$$V_{DSAT} = a + V_{DSC} - b$$

### Drain Current (Strong Inversion)

$$V_{DSX} = \min(V_{DS,eff},\; \max(V_{DSAT}, 0))$$

Channel charge factor:
$$C_{DO} = V_{GSX} - V_{th} - \frac{1}{2}(1 + f_{body}) V_{DSX}$$

Normalized channel current:
$$I_{Dnorm} = C_{DO} \cdot V_{DSX}$$

Base drain current (with mobility degradation):
$$I_{DS,base} = \beta \cdot f_{gate} \cdot I_{Dnorm}$$

### Velocity Saturation Factor

When $v_{max} > 0$:
$$f_{drain} = \frac{1}{1 + V_{DSX}/V_{DSC}}$$

$$I_{DS} = I_{DS,base} \cdot f_{drain}$$

When $v_{max} = 0$: $f_{drain} = 1$.

### Channel-Length Modulation (CLM)

Excess drain voltage:
$$V_{DS,excess} = \max(V_{DS,eff} - V_{DSAT}, 0)$$

**Primary path** ($\alpha_{dep} > 0$ and $\kappa > 0$):
$$\Delta L = \sqrt{\kappa \cdot \alpha_{dep} \cdot \left(V_{DS,excess} + \frac{V_{DSAT}}{8}\right)}$$

$$\Delta L_{limited} = \min\!\left(\Delta L,\; \frac{L_{eff}}{2}\right)$$

$$f_{CLM} = \frac{1}{1 - \Delta L_{limited} / L_{eff}}$$

**Fallback path** ($\kappa > 0$, $N_{SUB} > 0$, $\alpha_{dep} = 0$):
$$\Delta L_{raw} = \sqrt{\alpha_{dep}} \cdot \sqrt{V_{DS,excess}}$$

With junction depth correction ($X_J > 0$):
$$\Delta L_{corr} = X_J \left(\sqrt{1 + \frac{2 \Delta L_{raw}}{X_J}} - 1\right)$$

$$f_{CLM} = \frac{1}{1 - \min(\Delta L_{corr}/L_{eff},\; 0.5)}$$

Otherwise: $f_{CLM} = 1$.

Post-CLM current:
$$I_{DS,sat} = I_{DS} \cdot f_{CLM}$$

### Subthreshold Current Factor

With $N_{FS} > 0$ (exponential roll-off):
$$I_{DS,final} = I_{DS,sat} \cdot \exp\!\left(\min\!\left(\frac{V_{GS,use} - V_{on}}{x_n \cdot V_T},\; 0\right)\right)$$

Without $N_{FS}$ (smooth sigmoid cutoff):
$$\sigma = \frac{1}{1 + \exp\!\left(\min(-100 \cdot (V_{GS,use} - V_{on}),\; 80)\right)}$$

$$I_{DS,final} = I_{DS,sat} \cdot \sigma$$

### Mode Sign and Output Currents

Mode sign recovers forward/reverse sense:
$$\text{mode} = 2 \cdot \text{step}_{fwd} - 1$$

$$I_{channel} = I_{DS,final} \cdot \text{mode}$$

PMOS sign and multiplier:
$$I_{channel,out} = I_{channel} \cdot \text{type} \cdot M$$

$$I_{BS,out} = I_{BS} \cdot \text{type} \cdot M$$

$$I_{BD,out} = I_{BD} \cdot \text{type} \cdot M$$

### KCL Node Stamping (DC)

| Node | Current |
|------|---------|
| Drain | $I_{RD}$ |
| Gate | $0$ |
| Source | $I_{RS}$ |
| Bulk | $I_{BD,out} + I_{BS,out}$ |
| Drain' | $-I_{RD} + I_{channel,out} - I_{BD,out}$ |
| Source' | $-I_{RS} - I_{channel,out} - I_{BS,out}$ |

---

## Charge Model (Meyer Gate Capacitances)

### Threshold Voltage (Charge Model)

Reverse bias ($V_{BS} \le 0$):
$$S_{arg} = \sqrt{\phi - V_{BS}}$$

Forward bias ($V_{BS} > 0$):
$$S_{arg} = \sqrt{\phi} \cdot \left(1 - \frac{V_{BS}}{2\phi}\right)$$

$$V_{th,q} = V_{T0} + \Delta V_{T0} + \gamma (S_{arg} - \sqrt{\phi})$$

### Effective Oxide Capacitance

$$C_{ox,eff} = \frac{K_P}{\mu_0 \times 10^{-4}} \quad (\mu_0 > 0)$$

Fallback: $C_{ox,eff} = 3.9 \times 8.854\times10^{-12} / t_{ox}$ when $\mu_0 = 0$.

### Gate Overlap Charges

$$Q_{GS,ov} = C_{GSO} \cdot V_{GS}$$

$$Q_{GD,ov} = C_{GDO} \cdot V_{GD}$$

$$Q_{GB,ov} = C_{GBO} \cdot V_{GB}$$

### Meyer Intrinsic Gate Charges

Effective overdrives:
$$V_{GS,eff} = \max(V_{GS} - V_{th,q},\; 0)$$

$$V_{GD,eff} = \max(V_{GD} - V_{th,q},\; 0)$$

**Accumulation region** ($V_{GS} < V_{on}$):
$$Q_{GB,Meyer} = C_{ox,eff} \cdot \min(V_{GS} - V_{on},\; 0)$$

**Gate-source (saturation + linear)**:
$$r_d = \frac{V_{GD,eff}}{|2 V_{GS,eff} - V_{GD,eff}| + \epsilon}$$

$$Q_{GS,Meyer} = \frac{2}{3} C_{ox,eff} \cdot V_{GS,eff} \cdot (1 - r_d^2)$$

In saturation ($V_{GD,eff} = 0$): reduces to $Q_{GS} = \frac{2}{3} C_{ox,eff} \cdot V_{GS,eff}$.

**Gate-drain (linear region)**:
$$r_s = \frac{V_{GS,eff}}{|2 V_{GD,eff} - V_{GS,eff}| + \epsilon}$$

$$Q_{GD,Meyer} = \frac{2}{3} C_{ox,eff} \cdot V_{GD,eff} \cdot (1 - r_s^2)$$

In saturation ($V_{GD,eff} = 0$): $Q_{GD,Meyer} = 0$.

### Total Gate Charges

$$Q_{GS} = Q_{GS,ov} + Q_{GS,Meyer}$$

$$Q_{GD} = Q_{GD,ov} + Q_{GD,Meyer}$$

$$Q_{GB} = Q_{GB,ov} + Q_{GB,Meyer}$$

### Bulk Junction Depletion Charges

Standard SPICE depletion charge ($V < F_C \cdot P_B$):

$$Q_{BS} = \frac{C_{BS} \cdot P_B}{1 - M_J} \left[1 - \left(1 - \frac{V_{BS}}{P_B}\right)^{1-M_J}\right]$$

$$Q_{BD} = \frac{C_{BD} \cdot P_B}{1 - M_J} \left[1 - \left(1 - \frac{V_{BD}}{P_B}\right)^{1-M_J}\right]$$

Argument clamped: $\left(1 - V/P_B\right) \ge 10^{-8}$.

### KCL Node Stamping (Charge)

| Node | Charge |
|------|--------|
| Gate | $+Q_{GS} + Q_{GD} + Q_{GB}$ |
| Drain' | $-Q_{GD} - Q_{BD}$ |
| Source' | $-Q_{GS} - Q_{BS}$ |
| Bulk | $-Q_{GB} + Q_{BS} + Q_{BD}$ |
| Drain | $0$ |
| Source | $0$ |

---

## Newton Limiting Functions

### PN Junction Limiting (`pnjlim`)

Critical voltage:
$$V_{crit} = V_T \ln\!\left(\frac{V_T}{\sqrt{2} \cdot I_S}\right)$$

When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 V_T$:

If $V_{old} > 0$:
$$V_{lim} = \begin{cases} V_{old} + V_T(2 + \ln(\arg - 2)) & \arg > 0 \\ V_{crit} & \arg \le 0 \end{cases}$$
where $\arg = (V_{new} - V_{old})/V_T$.

If $V_{old} \le 0$:
$$V_{lim} = V_T \ln(V_{new}/V_T)$$

Otherwise: $V_{lim} = V_{new}$.

Applied to: $V_{BS}$ and $V_{BD}$.

### FET Gate Voltage Limiting (`fetlim`)

$$V_{tsthi} = |2(V_{old} - V_{T0})| + 2$$

$$V_{tstlo} = V_{tsthi}/2 + 2$$

$$V_{tox} = V_{T0} + 3.5$$

If $V_{old} \ge V_{T0}$:
- If $V_{old} \ge V_{tox}$: clamp to $[V_{old} - V_{tstlo},\; V_{old} + V_{tsthi}]$
- Else: lower bound $V_{T0} - 0.5$, upper bound $V_{old} + V_{tsthi}$

If $V_{old} < V_{T0}$:
- Lower bound $V_{old} - V_{tstlo}$, upper bound $V_{T0} + 0.5$

Applied to: $V_{GS}$.

### Drain-Source Voltage Limiting (`limvds`)

If $V_{old} \ge 3.5$:
$$V_{lim} \in [-0.5 \cdot V_{old},\; 2.0 \cdot V_{old}]$$

If $V_{old} < 3.5$:
$$V_{lim} = \min(V_{new},\; 4.0)$$

Applied to: $V_{DS}$.

---

## Convergence Aid (Parameter Stepping)

Source-stepping of junction saturation current at continuation factor $\lambda \in [0,1]$:

$$I_S(\lambda) = I_S + (10^{-12} - I_S)(1 - \lambda)$$

At $\lambda = 0$: $I_S = 10^{-12}$ (easy). At $\lambda = 1$: $I_S = I_{S,model}$ (physical).

---

## Noise Sources

| Source | Nodes | Type | Spectral Density |
|--------|-------|------|-----------------|
| Drain resistance | D -- D' | Thermal | $S_I = 4kT \cdot G_{RD}$ |
| Source resistance | S -- S' | Thermal | $S_I = 4kT \cdot G_{RS}$ |
| Channel thermal | D' -- S' | Thermal | $S_I = 4kT \cdot \frac{2}{3} g_m$ |
| Channel flicker | D' -- S' | Flicker | $S_I = \frac{K_F \cdot I_{DS}^{A_F}}{f}$ |
