# MOS Level 2 (Grove-Frohman) -- Parameter & Equation Reference

> Analytical long-channel MOSFET with velocity saturation, narrow-width effect, field-dependent mobility, subthreshold conduction, and channel-length modulation (SPICE Level 2).

## Model Topology

Four external terminals: **Drain (D)**, **Gate (G)**, **Source (S)**, **Bulk (B)**. Two internal nodes **D'** (drain-prime) and **S'** (source-prime) separate the intrinsic channel from the external drain and source ohmic resistances RD and RS. The gate draws no DC current. Bulk-source and bulk-drain p-n junction diodes model substrate leakage. The intrinsic MOSFET conducts current from D' to S' controlled by the gate-source and drain-source voltages, with automatic source/drain reversal when $V_{DS} < 0$.

## Parameters

### DC Model Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VTO | $V_{T0}$ | V | 0 | -- | Zero-bias threshold voltage |
| KP | $K_P$ | A/V^2 | 2.07189e-5 | > 0 | Transconductance parameter |
| GAMMA | $\gamma$ | V^{1/2} | 0 | >= 0 | Bulk threshold (body effect) parameter |
| PHI | $\phi$ | V | 0.6 | > 0 | Surface potential at strong inversion |
| LAMBDA | $\lambda$ | 1/V | 0 | >= 0 | Channel-length modulation (fallback when NSUB=0) |
| TOX | $t_{ox}$ | m | 1e-7 | > 0 | Gate oxide thickness |
| NSUB | $N_{SUB}$ | cm^{-3} | 0 | >= 0 | Substrate doping concentration |
| NSS | $N_{SS}$ | cm^{-2} | 0 | >= 0 | Surface state density |
| NFS | $N_{FS}$ | cm^{-2} | 0 | >= 0 | Fast surface state density (subthreshold) |
| TPG | -- | -- | 0 | 0,1,-1 | Gate material type |
| NEFF | $N_{EFF}$ | -- | 1 | > 0 | Total channel charge coefficient |
| DELTA | $\delta$ | -- | 0 | >= 0 | Narrow-width effect coefficient |
| LD | $L_D$ | m | 0 | >= 0 | Lateral diffusion length |
| U0 | $\mu_0$ | cm^2/V-s | 600 | > 0 | Low-field surface mobility |
| UCRIT | $E_{CRIT}$ | V/cm | 10000 | > 0 | Critical field for mobility degradation |
| UEXP | $U_{EXP}$ | -- | 0 | >= 0 | Critical field exponent for mobility degradation |
| VMAX | $v_{MAX}$ | m/s | 0 | >= 0 | Maximum carrier drift velocity (0 = disabled) |
| XJ | $X_J$ | m | 0 | >= 0 | Metallurgical junction depth |
| TYPE | -- | -- | 1 | 1, -1 | Device polarity: 1 = NMOS, -1 = PMOS |

### Parasitic Resistance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RD | $R_D$ | Ohm | 0 | >= 0 | Drain ohmic resistance |
| RS | $R_S$ | Ohm | 0 | >= 0 | Source ohmic resistance |
| RSH | $R_{SH}$ | Ohm/sq | 0 | >= 0 | Sheet resistance |

### Junction Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IS | $I_S$ | A | 1e-14 | > 0 | Bulk junction saturation current |
| JS | $J_S$ | A/m^2 | 0 | >= 0 | Bulk junction saturation current density |
| PB | $\phi_B$ | V | 0.8 | > 0 | Bulk junction built-in potential |
| CBD | $C_{BD}$ | F | 0 | >= 0 | Zero-bias B-D junction capacitance |
| CBS | $C_{BS}$ | F | 0 | >= 0 | Zero-bias B-S junction capacitance |
| CJ | $C_J$ | F/m^2 | 0 | >= 0 | Bottom junction capacitance per unit area |
| MJ | $M_J$ | -- | 0.5 | 0..1 | Bottom junction grading coefficient |
| CJSW | $C_{JSW}$ | F/m | 0 | >= 0 | Sidewall junction capacitance per unit length |
| MJSW | $M_{JSW}$ | -- | 0.33 | 0..1 | Sidewall junction grading coefficient |
| FC | $F_C$ | -- | 0.5 | 0..1 | Forward-bias junction capacitance fitting parameter |

### Overlap Capacitance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CGSO | $C_{GSO}$ | F/m | 0 | >= 0 | Gate-source overlap capacitance per unit width |
| CGDO | $C_{GDO}$ | F/m | 0 | >= 0 | Gate-drain overlap capacitance per unit width |
| CGBO | $C_{GBO}$ | F/m | 0 | >= 0 | Gate-bulk overlap capacitance per unit length |

### Noise Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KF | $K_F$ | -- | 0 | >= 0 | Flicker noise coefficient |
| AF | $A_F$ | -- | 1 | > 0 | Flicker noise exponent |
| NLEV | -- | -- | 2 | -- | Noise model selection level |
| GDSNOI | -- | -- | 1 | >= 0 | Channel shot noise coefficient |

### Temperature Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TNOM | $T_{NOM}$ | degC | 27 | -- | Parameter measurement temperature |

### Instance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| W | $W$ | m | 1e-6 | > 0 | Channel width |
| L | $L$ | m | 1e-6 | > 0 | Channel length |

## Equations

### Effective Dimensions

$$L_{eff} = \max(L - 2 L_D,\; 1 \times 10^{-9})$$

$$W_{eff} = \max(W,\; 1 \times 10^{-9})$$

### Thermal Voltage

$$V_T = k_B T_{NOM+273.15} / q = 8.617333 \times 10^{-5} \cdot (T_{NOM} + 273.15)$$

where $k_B/q = 8.617333 \times 10^{-5}$ V/K.

### PMOS Handling and Source/Drain Reversal

All internal voltages are referred to the internal source node S' and sign-flipped for PMOS:

$$V_{GS,raw} = (V_G - V_{S'}) \cdot \text{type}$$
$$V_{DS,raw} = (V_{D'} - V_{S'}) \cdot \text{type}$$
$$V_{BS,raw} = (V_B - V_{S'}) \cdot \text{type}$$

Smooth absolute value for source/drain reversal:

$$|V_{DS}| = \sqrt{V_{DS,raw}^2 + \epsilon_{sd}}, \quad \epsilon_{sd} = 10^{-12}$$

Smooth sign function:

$$\text{mode} = \frac{V_{DS,raw}}{|V_{DS}|}$$

Effective terminal voltages after reversal:

$$V_{DS} = |V_{DS}|$$
$$V_{GS} = V_{GS,raw} - \frac{1 - \text{mode}}{2} \cdot V_{DS,raw}$$
$$V_{BS} = V_{BS,raw} - \frac{1 - \text{mode}}{2} \cdot V_{DS,raw}$$

When $V_{DS,raw} \ge 0$: mode $\approx +1$, so $V_{GS} = V_{GS,raw}$, $V_{BS} = V_{BS,raw}$ (normal).
When $V_{DS,raw} < 0$: mode $\approx -1$, so $V_{GS} \to V_{GD,raw}$, $V_{BS} \to V_{BD,raw}$ (swapped).

### Body Effect

Depletion factor with linearized forward-bias region:

$$s_{arg} = \begin{cases} \sqrt{\phi - V_{BS}} & \text{if } V_{BS} \le 0 \\ \sqrt{\phi}\left(1 - \dfrac{V_{BS}}{2\phi}\right) & \text{if } V_{BS} > 0 \end{cases}$$

Smooth blend via `blendv` on the sign of $V_{BS}$.

Lower clamp on $\phi - V_{BS}$:

$$\phi - V_{BS} \gets \max(\phi - V_{BS},\; 10^{-30})$$

### Threshold Voltage

Base threshold:

$$V_{th} = V_{T0} + \gamma \cdot (s_{arg} - \sqrt{\phi})$$

### Narrow-Width Effect (DELTA)

When $\delta > 0$:

$$F_{\delta} = \frac{\delta \cdot \pi \cdot \epsilon_{Si}}{2 \cdot C_{ox} \cdot W_{eff}}$$

where $\epsilon_{Si} = 1.0356 \times 10^{-10}$ F/m and $C_{ox} = \epsilon_{ox} / t_{ox}$ with $\epsilon_{ox} = 3.9 \times 8.854 \times 10^{-12}$ F/m.

$$\Delta V_{th,narrow} = F_{\delta} \cdot 2 \cdot s_{arg}$$

Effective threshold:

$$V_{th,eff} = V_{th} + \Delta V_{th,narrow}$$

Gate overdrive:

$$V_{gst} = V_{GS} - V_{th,eff}$$

### Field-Dependent Mobility (UCRIT, UEXP)

Smooth positive gate overdrive:

$$V_{gst,+} = \frac{V_{gst} + \sqrt{V_{gst}^2 + 10^{-12}}}{2}$$

When UEXP > 0 and UCRIT > 0:

$$E_{CRIT,SI} = E_{CRIT} \times 100 \quad \text{(V/cm} \to \text{V/m)}$$

$$E_{eff} = \frac{V_{gst,+}}{t_{ox}} + 1$$

$$r_{eff} = \max\!\left(\frac{E_{eff}}{E_{CRIT,SI}},\; 10^{-30}\right)$$

$$\mu_{ratio} = \exp\!\left(\min\!\left(-U_{EXP} \cdot \ln(r_{eff}),\; 80\right)\right) = r_{eff}^{-U_{EXP}}$$

When UEXP = 0 or UCRIT = 0: $\mu_{ratio} = 1$.

### Transconductance

$$\beta_0 = K_P \cdot \frac{W_{eff}}{L_{eff}}$$

$$\beta = \beta_0 \cdot \mu_{ratio}$$

### Saturation Voltage (VMAX)

When $v_{MAX} > 0$:

$$\mu_{0,SI} = \mu_0 \times 10^{-4} \quad \text{(cm}^2/\text{V-s} \to \text{m}^2/\text{V-s)}$$

$$\mu_{eff,SI} = \mu_{0,SI} \cdot \mu_{ratio}$$

$$V_{DSAT,vmax} = \frac{v_{MAX} \cdot L_{eff}}{\max(\mu_{eff,SI},\; 10^{-30})}$$

Smooth minimum with NEFF correction:

$$V_{DSAT} = \frac{V_{gst,+} + N_{EFF} \cdot V_{DSAT,vmax} - \sqrt{(V_{gst,+} - N_{EFF} \cdot V_{DSAT,vmax})^2 + 10^{-12}}}{2}$$

When $v_{MAX} = 0$:

$$V_{DSAT} = V_{gst,+}$$

### Subthreshold Conduction (NFS)

When $N_{FS} > 0$:

$$C_{ox} = \frac{\epsilon_{ox}}{t_{ox}}, \quad \epsilon_{ox} = 3.9 \times 8.854 \times 10^{-12}$$

$$\frac{C_d}{C_{ox}} = \frac{\epsilon_{Si} \cdot \gamma}{\max(2 \cdot s_{arg} \cdot C_{ox},\; 10^{-30})}$$

$$x_n = 1 + \frac{q \cdot N_{FS} \times 10^4}{C_{ox}} + \frac{C_d}{C_{ox}}$$

where $q = 1.602 \times 10^{-19}$ C and $N_{FS}$ is converted from cm$^{-2}$ to m$^{-2}$ by $\times 10^4$.

$$V_{on} = V_{th,eff} + x_n \cdot V_T$$

$$\alpha_{sub} = \min\!\left(\frac{V_{GS} - V_{on}}{x_n \cdot V_T},\; 80\right)$$

$$f_{sub} = \frac{\exp(\alpha_{sub}) + 1 - \sqrt{(\exp(\alpha_{sub}) - 1)^2 + 10^{-12}}}{2}$$

This yields $f_{sub} \approx \exp(\alpha_{sub})$ when $V_{GS} \ll V_{on}$ (subthreshold) and $f_{sub} \approx 1$ when $V_{GS} \ge V_{on}$ (above threshold).

When $N_{FS} = 0$: $f_{sub} = 1$.

### Effective Drain-Source Voltage (Saturation Clamp)

Smooth minimum of $V_{DS}$ and $V_{DSAT}$:

$$V_{DS,eff} = \frac{V_{DS} + V_{DSAT} - \sqrt{(V_{DS} - V_{DSAT})^2 + 10^{-12}}}{2}$$

### Core Drain Current

$$I_{D,core} = \beta \cdot \left(V_{gst,+} \cdot V_{DS,eff} - \frac{1}{2} V_{DS,eff}^2\right)$$

### Channel-Length Modulation (NSUB-based)

When $N_{SUB} > 0$:

$$N_{SUB,SI} = N_{SUB} \times 10^6 \quad \text{(cm}^{-3} \to \text{m}^{-3}\text{)}$$

$$K_{depl} = \frac{2 \epsilon_{Si}}{q \cdot N_{SUB,SI}}$$

$$V_{DS,excess} = \max(V_{DS} - V_{DSAT},\; 0)$$

$$\Delta L = \sqrt{\max(K_{depl} \cdot V_{DS,excess},\; 10^{-30})}$$

When $X_J > 0$ (junction-depth correction):

$$\Delta L = X_J \cdot \left(\sqrt{1 + \frac{2 \Delta L}{X_J}} - 1\right)$$

Ratio clamped to 0.5 (punch-through protection):

$$r = \frac{\Delta L}{L_{eff}}$$

$$r_{clamp} = \frac{r + 0.5 - \sqrt{(r - 0.5)^2 + 10^{-12}}}{2}$$

$$f_{CLM} = \frac{1}{1 - r_{clamp}}$$

### Channel-Length Modulation (Lambda fallback)

When $N_{SUB} = 0$:

$$f_{CLM} = 1 + \lambda \cdot V_{DS}$$

### Final Drain Current

$$I_{DS,internal} = I_{D,core} \cdot f_{CLM} \cdot f_{sub}$$

With source/drain reversal and PMOS sign:

$$I_{D'S'} = I_{DS,internal} \cdot \text{mode} \cdot \text{type}$$

### Parasitic Resistance Currents

$$G_{D,ext} = \begin{cases} 1/R_D & \text{if } R_D > 0 \\ 10^{12} & \text{if } R_D = 0 \end{cases}$$

$$G_{S,ext} = \begin{cases} 1/R_S & \text{if } R_S > 0 \\ 10^{12} & \text{if } R_S = 0 \end{cases}$$

$$I_{RD} = (V_D - V_{D'}) \cdot G_{D,ext}$$
$$I_{RS} = (V_S - V_{S'}) \cdot G_{S,ext}$$

### Bulk Junction Diode Currents

$$I_{BS} = I_S \cdot \left(\exp\!\left(\min\!\left(\frac{V_{BS,jct}}{V_T},\; 80\right)\right) - 1\right) + G_{MIN} \cdot V_{BS,jct}$$

$$I_{BD} = I_S \cdot \left(\exp\!\left(\min\!\left(\frac{V_{BD,jct}}{V_T},\; 80\right)\right) - 1\right) + G_{MIN} \cdot V_{BD,jct}$$

where $V_{BS,jct} = V_B - V_{S'}$, $V_{BD,jct} = V_B - V_{D'}$, and $G_{MIN} = 10^{-12}$ S.

### KCL Node Assembly

| Node | Current Contribution |
|------|---------------------|
| D (drain) | $-I_{RD}$ |
| G (gate) | $0$ |
| S (source) | $-I_{RS}$ |
| B (bulk) | $-I_{BS} - I_{BD}$ |
| D' (drain_prime) | $I_{RD} - I_{D'S'} + I_{BD}$ |
| S' (source_prime) | $I_{RS} + I_{D'S'} + I_{BS}$ |

### Charge Contributions (q function)

Gate overlap charges:

$$Q_{CGSO} = C_{GSO} \cdot V_{GS'}$$
$$Q_{CGDO} = C_{GDO} \cdot V_{GD'}$$
$$Q_{CGBO} = C_{GBO} \cdot V_{GB}$$

where $V_{GS'} = V_G - V_{S'}$, $V_{GD'} = V_G - V_{D'}$, $V_{GB} = V_G - V_B$.

Bulk junction charges (linear approximation):

$$Q_{BD} = C_{BD} \cdot V_{BD'} \quad \text{(if } C_{BD} > 0\text{)}$$
$$Q_{BS} = C_{BS} \cdot V_{BS'} \quad \text{(if } C_{BS} > 0\text{)}$$

where $V_{BD'} = V_B - V_{D'}$ and $V_{BS'} = V_B - V_{S'}$.

Node charge assembly:

| Node | Charge |
|------|--------|
| D (drain) | $0$ |
| G (gate) | $Q_{CGSO} + Q_{CGDO} + Q_{CGBO}$ |
| S (source) | $0$ |
| B (bulk) | $Q_{BS} + Q_{BD} - Q_{CGBO}$ |
| D' (drain_prime) | $-Q_{CGDO} - Q_{BD}$ |
| S' (source_prime) | $-Q_{CGSO} - Q_{BS}$ |

The solver computes displacement currents as $I_C = dQ/dt$.

### Noise Sources

Four noise generators declared:

| Source | Nodes | Type | Expression |
|--------|-------|------|------------|
| Drain resistance | D -- D' | Thermal | $S_I = 4 k_B T / R_D$ |
| Source resistance | S -- S' | Thermal | $S_I = 4 k_B T / R_S$ |
| Channel | D' -- S' | Shot | $S_I = \text{GDSNOI} \cdot g_{ds}$ (level-dependent) |
| Flicker | D' -- S' | Flicker | $S_I = K_F \cdot I_{DS}^{A_F} / f$ |

Noise model selected by NLEV parameter (default 2).

### Newton Convergence: Voltage Limiting

#### Critical Voltage

$$V_{crit} = V_T \cdot \ln\!\left(\frac{V_T}{\sqrt{2} \cdot I_S}\right)$$

#### PN Junction Limiting (pnjlim)

Applied to $V_{BS}$ and $V_{BD}$. Given proposed $V_{new}$, previous $V_{old}$:

$$V_{lim} = \begin{cases} V_{old} + V_T(2 + \ln(\tfrac{V_{new} - V_{old}}{V_T} - 2)) & \text{if } V_{new} > V_{crit} \text{ and } |V_{new} - V_{old}| > 2V_T \text{ and } V_{old} > 0 \text{ and } V_{new} > V_{old} \\ V_{crit} & \text{if } V_{new} > V_{crit} \text{ and } |V_{new} - V_{old}| > 2V_T \text{ and } V_{old} > 0 \text{ and } V_{new} \le V_{old} \\ V_T \ln(V_{new}/V_T) & \text{if } V_{new} > V_{crit} \text{ and } |V_{new} - V_{old}| > 2V_T \text{ and } V_{old} \le 0 \\ V_{new} & \text{otherwise} \end{cases}$$

For $V_{BD}$, the correction is applied with inverted sign on the drain-prime node: $V_{D'} \mathrel{+}= V_{BD,old} - V_{BD,lim}$.

#### FET Gate Voltage Limiting (fetlim)

Applied to $V_{GS}$. Define:

$$V_{tst,hi} = |2(V_{GS,old} - V_{T0})| + 2$$
$$V_{tst,lo} = \frac{V_{tst,hi}}{2} + 2$$
$$V_{tox} = V_{T0} + 3.5$$

$$V_{GS,lim} = \begin{cases} \max(V_{new},\; V_{old} - V_{tst,lo}) & \text{if } V_{old} \ge V_{tox},\; \Delta V \le 0 \\ \min(V_{new},\; V_{old} + V_{tst,hi}) & \text{if } V_{old} \ge V_{tox},\; \Delta V > 0 \\ \max(V_{new},\; V_{T0} - 0.5) & \text{if } V_{T0} \le V_{old} < V_{tox},\; \Delta V \le 0 \\ \min(V_{new},\; V_{old} + V_{tst,hi}) & \text{if } V_{T0} \le V_{old} < V_{tox},\; \Delta V > 0 \\ \max(V_{new},\; V_{old} - V_{tst,lo}) & \text{if } V_{old} < V_{T0},\; \Delta V \le 0 \\ \min(V_{new},\; V_{T0} + 0.5) & \text{if } V_{old} < V_{T0},\; \Delta V > 0 \end{cases}$$

#### Drain-Source Voltage Limiting (limvds)

$$V_{DS,lim} = \begin{cases} \max(V_{new},\; -0.5 \cdot V_{old}) & \text{if } V_{old} \ge 3.5,\; \Delta V \le 0 \\ \min(V_{new},\; 2.0 \cdot V_{old}) & \text{if } V_{old} \ge 3.5,\; \Delta V > 0 \\ \min(V_{new},\; 4.0) & \text{if } V_{old} < 3.5 \text{ and } V_{new} > 4.0 \\ V_{new} & \text{otherwise} \end{cases}$$

### Convergence Aid: Parameter Stepping (attempt)

For continuation-method convergence with factor $\lambda \in [0, 1]$:

$$I_{S,eff} = I_S + (10^{-12} - I_S)(1 - \lambda)$$

At $\lambda = 0$: $I_{S,eff} = 10^{-12}$ (linearized). At $\lambda = 1$: $I_{S,eff} = I_S$ (original).

## Physical Constants Used

| Constant | Symbol | Value | Unit |
|----------|--------|-------|------|
| Boltzmann/charge | $k_B/q$ | 8.617333e-5 | V/K |
| Silicon permittivity | $\epsilon_{Si}$ | 1.0356e-10 | F/m |
| Oxide permittivity | $\epsilon_{ox}$ | 3.453e-11 | F/m |
| Electron charge | $q$ | 1.602e-19 | C |
| GMIN | $G_{MIN}$ | 1e-12 | S |
| Smoothing epsilon | $\epsilon$ | 1e-12 | -- |
