# MOS Level 1 (Shichman-Hodges MOSFET) -- Parameter & Equation Reference

> Level 1 long-channel MOSFET model: Shichman-Hodges square-law with body effect, Meyer gate capacitances, and junction diode parasitics.

## Model Topology

Four-terminal device: **Drain (D)**, **Gate (G)**, **Source (S)**, **Bulk (B)**. All four terminals are external ports. The channel current flows between D and S, controlled by G-S and B-S voltages. Parasitic bulk-drain and bulk-source PN junctions model substrate currents. Meyer capacitances (Cgs, Cgd, Cgb) plus overlap and junction depletion capacitances complete the equivalent circuit.

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TYPE | $\text{type}$ | -- | 1 | {-1, 1} | Device polarity: 1 = NMOS, -1 = PMOS |
| VTO | $V_{T0}$ | V | 0 | -- | Zero-bias threshold voltage |
| KP | $K_P$ | A/V^2 | 2e-5 | -- | Transconductance parameter |
| GAMMA | $\gamma$ | V^{1/2} | 0 | -- | Bulk threshold (body effect) parameter |
| PHI | $\phi_s$ | V | 0.6 | -- | Surface inversion potential |
| LAMBDA | $\lambda$ | 1/V | 0 | -- | Channel-length modulation coefficient |
| RD | $R_D$ | Ohm | 0 | -- | Drain ohmic resistance |
| RS | $R_S$ | Ohm | 0 | -- | Source ohmic resistance |
| CBD | $C_{BD}$ | F | 0 | -- | Zero-bias B-D junction capacitance |
| CBS | $C_{BS}$ | F | 0 | -- | Zero-bias B-S junction capacitance |
| IS | $I_S$ | A | 1e-14 | -- | Bulk junction saturation current |
| PB | $\phi_B$ | V | 0.8 | -- | Bulk junction built-in potential |
| CGSO | $C_{GSO}$ | F/m | 0 | -- | Gate-source overlap capacitance per unit width |
| CGDO | $C_{GDO}$ | F/m | 0 | -- | Gate-drain overlap capacitance per unit width |
| CGBO | $C_{GBO}$ | F/m | 0 | -- | Gate-bulk overlap capacitance per unit length |
| RSH | $R_{SH}$ | Ohm/sq | 0 | -- | Diffusion sheet resistance |
| CJ | $C_J$ | F/m^2 | 0 | -- | Bottom junction capacitance per unit area |
| MJ | $M_J$ | -- | 0.5 | -- | Bottom junction grading coefficient |
| CJSW | $C_{JSW}$ | F/m | 0 | -- | Sidewall junction capacitance per unit perimeter |
| MJSW | $M_{JSW}$ | -- | 0.5 | -- | Sidewall junction grading coefficient |
| JS | $J_S$ | A/m^2 | 0 | -- | Bulk junction saturation current density |
| TOX | $t_{ox}$ | m | 0 | -- | Gate oxide thickness |
| LD | $L_D$ | m | 0 | -- | Lateral diffusion length |
| U0 | $\mu_0$ | cm^2/Vs | 0 | -- | Surface mobility |
| FC | $F_C$ | -- | 0.5 | -- | Forward-bias junction capacitance fitting parameter |
| NSUB | $N_{SUB}$ | 1/cm^3 | 0 | -- | Substrate doping concentration |
| TPG | -- | -- | 0 | -- | Gate material type |
| NSS | $N_{SS}$ | 1/cm^2 | 0 | -- | Surface state density |
| TNOM | $T_{nom}$ | degC | 27 | -- | Parameter measurement temperature |
| KF | $K_F$ | -- | 0 | -- | Flicker noise coefficient |
| AF | $A_F$ | -- | 1 | -- | Flicker noise exponent |
| NLEV | -- | -- | 2 | -- | Noise model level selector |
| GDSNOI | -- | -- | 1 | -- | Channel shot noise coefficient |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| W | $W$ | m | 1e-6 | -- | Channel width |
| L | $L$ | m | 1e-6 | -- | Channel length (drawn) |
| TEMP | $T$ | K | 300.15 | -- | Device temperature |
| DTEMP | $\Delta T$ | K | 0 | -- | Temperature offset from circuit temperature |
| M | $M$ | -- | 1 | -- | Parallel device multiplier |
| AD | $A_D$ | m^2 | 0 | -- | Drain diffusion area |
| AS | $A_S$ | m^2 | 0 | -- | Source diffusion area |
| PD | $P_D$ | m | 0 | -- | Drain diffusion perimeter |
| PS | $P_S$ | m | 0 | -- | Source diffusion perimeter |
| NRD | $N_{RD}$ | sq | 0 | -- | Number of drain squares (for RSH) |
| NRS | $N_{RS}$ | sq | 0 | -- | Number of source squares (for RSH) |

## Equations

### Terminal Voltages and Source-Drain Reversal

Raw terminal voltages referenced to source, with PMOS sign flip ($\sigma = +1$ NMOS, $-1$ PMOS):

$$ V_{GS,raw} = \sigma (V_G - V_S) $$
$$ V_{DS,raw} = \sigma (V_D - V_S) $$
$$ V_{BS,raw} = \sigma (V_B - V_S) $$

Branchless source-drain swap when $V_{DS,raw} < 0$:

$$ V_{DS,eff} = |V_{DS,raw}| $$
$$ V_{GS,eff} = V_{GS,raw} - \min(V_{DS,raw},\; 0) $$
$$ V_{BS,eff} = V_{BS,raw} - \min(V_{DS,raw},\; 0) $$

Mode indicator for current direction reconstruction:

$$ \text{mode} = \frac{V_{DS,raw}}{V_{DS,eff} + 10^{-30}} $$

### Thermal Voltage

$$ V_T = k_B T / q = 8.617333262145 \times 10^{-5} \cdot T $$

where $T$ is the instance temperature in Kelvin.

### Effective Dimensions

$$ W_{eff} = \max(W,\; 10^{-9}) $$
$$ L_{eff} = \max(L - 2 L_D,\; 10^{-9}) $$

### Body Effect and Threshold Voltage

Body-effect factor $s_{arg}$ (branchless reverse/forward bias selection):

**Reverse bias** ($V_{BS,eff} \le 0$):

$$ s_{arg} = \sqrt{\max(\phi_s - V_{BS,eff},\; 10^{-30})} $$

**Forward bias** ($V_{BS,eff} > 0$):

$$ s_{arg} = \max\!\left(\sqrt{\phi_s} - \frac{V_{BS,eff}}{2\sqrt{\phi_s}},\; 0\right) $$

Threshold voltage:

$$ V_{th} = V_{T0} + \gamma \left(s_{arg} - \sqrt{\phi_s}\right) $$

Gate overdrive:

$$ V_{GST} = V_{GS,eff} - V_{th} $$

### Drain Current (Shichman-Hodges)

Transconductance gain:

$$ \beta = K_P \cdot \frac{W_{eff}}{L_{eff}} $$

Smooth cutoff clamping:

$$ V_{GST}^{+} = \max(V_{GST},\; 0) $$
$$ V_{DSAT} = V_{GST}^{+} $$

Unified linear/saturation channel voltage:

$$ V_{DS,ch} = \min(V_{DS,eff},\; V_{DSAT}) $$

Drain current (single expression covering cutoff, linear, and saturation):

$$ I_D = \beta \left(V_{GST}^{+} - \tfrac{1}{2} V_{DS,ch}\right) V_{DS,ch} \left(1 + \lambda \, V_{DS,eff}\right) $$

Scaled by parallel multiplier:

$$ I_{D,scaled} = M \cdot I_D $$

### Bulk Junction Diode Currents

Using raw (non-mode-swapped) voltages:

$$ V_{BD} = V_{BS,raw} - V_{DS,raw} $$

Exponential with gmin shunt and overflow clamp:

$$ I_{BD} = I_S \left(\exp\!\left(\min\!\left(\frac{V_{BD}}{V_T},\; 80\right)\right) - 1\right) + g_{min} \cdot V_{BD} $$

$$ I_{BS} = I_S \left(\exp\!\left(\min\!\left(\frac{V_{BS,raw}}{V_T},\; 80\right)\right) - 1\right) + g_{min} \cdot V_{BS,raw} $$

where $g_{min} = 10^{-12}$ S.

Scaled: $I_{BD,s} = M \cdot I_{BD}$, $I_{BS,s} = M \cdot I_{BS}$.

### KCL Terminal Currents

$$ I_{drain} = \sigma \left(\text{mode} \cdot I_{D,scaled} - I_{BD,s}\right) $$
$$ I_{gate} = 0 $$
$$ I_{source} = \sigma \left(-\text{mode} \cdot I_{D,scaled} - I_{BS,s}\right) $$
$$ I_{bulk} = \sigma \left(I_{BD,s} + I_{BS,s}\right) $$

### Oxide Capacitance

$$ C_{ox,total} = \frac{\varepsilon_{ox}}{t_{ox}} \cdot W_{eff} \cdot L_{eff} = \frac{3.9 \times 8.854 \times 10^{-12}}{t_{ox}} \cdot W_{eff} \cdot L_{eff} $$

Set to 0 when $t_{ox} = 0$.

### Meyer Gate Capacitance Model

Four operating regions based on $V_{GST} = V_{GS,eff} - V_{th}$:

#### Accumulation ($V_{GST} \le -\phi_s$)

$$ C_{GS} = 0, \quad C_{GD} = 0, \quad C_{GB} = C_{ox} $$

#### Depletion ($-\phi_s < V_{GST} \le -\phi_s/2$)

$$ C_{GS} = 0, \quad C_{GD} = 0, \quad C_{GB} = -\frac{V_{GST}}{\phi_s} \cdot C_{ox} $$

#### Weak Inversion ($-\phi_s/2 < V_{GST} \le 0$)

$$ C_{GS} = \frac{V_{GST}}{1.5\,\phi_s} \cdot C_{ox} + \frac{C_{ox}}{3} $$
$$ C_{GD} = 0 $$
$$ C_{GB} = -\frac{V_{GST}}{\phi_s} \cdot C_{ox} $$

#### Strong Inversion ($V_{GST} > 0$)

Define $V_{DSAT}' = \max(V_{DSAT}, 10^{-30})$ and intermediate terms:

$$ V_{ddif} = \max(2 V_{DSAT}' - V_{DS,eff},\; 10^{-30}) $$
$$ V_{ddif1} = V_{DSAT}' - V_{DS,eff} $$

**Linear region** ($V_{DS,eff} < V_{DSAT}'$):

$$ C_{GS} = \frac{2}{3} C_{ox} \left(1 - \frac{V_{ddif1}^2}{V_{ddif}^2}\right) $$
$$ C_{GD} = \frac{2}{3} C_{ox} \left(1 - \frac{V_{DSAT}'^2}{V_{ddif}^2}\right) $$
$$ C_{GB} = 0 $$

**Saturation region** ($V_{DS,eff} \ge V_{DSAT}'$):

$$ C_{GS} = \frac{2}{3} C_{ox}, \quad C_{GD} = 0, \quad C_{GB} = 0 $$

### Meyer Gate Charges

Effective branch voltages for charge computation:

$$ V_{GD,eff} = V_{GS,eff} - V_{DS,eff} $$
$$ V_{GB,eff} = V_{GS,eff} - V_{BS,eff} $$

Gate charges (Q = C * V):

$$ Q_{GS,meyer} = C_{GS} \cdot V_{GS,eff} $$
$$ Q_{GD,meyer} = C_{GD} \cdot V_{GD,eff} $$
$$ Q_{GB,meyer} = C_{GB} \cdot V_{GB,eff} $$

### Overlap Charges

Using raw (un-flipped) terminal voltages:

$$ Q_{GS,ov} = C_{GSO} \cdot W_{eff} \cdot (V_G - V_S) $$
$$ Q_{GD,ov} = C_{GDO} \cdot W_{eff} \cdot (V_G - V_D) $$
$$ Q_{GB,ov} = C_{GBO} \cdot 2 L_{eff} \cdot (V_G - V_B) $$

### Junction Depletion Charges

For each junction $j \in \{BS, BD\}$ with capacitance $C_j$, grading $M_J$, built-in potential $\phi_B$, and forward-bias parameter $F_C$. Voltages: $V_{BS,junc} = V_{BS,raw}$, $V_{BD,junc} = V_{BS,raw} - V_{DS,raw}$.

**Reverse bias** ($V_j \le F_C \phi_B$):

$$ Q_j = \frac{C_j \phi_B}{1 - M_J}\left(1 - \left(\max\!\left(1 - \frac{V_j}{\phi_B},\; 10^{-30}\right)\right)^{1-M_J}\right) $$

**Forward bias** ($V_j > F_C \phi_B$):

$$ F_1 = \frac{C_j \phi_B}{1 - M_J}\left(1 - (1 - F_C)^{1-M_J}\right) $$
$$ F_2 = (1 - F_C)^{1+M_J} $$
$$ F_3 = 1 - F_C(1 + M_J) $$
$$ Q_j = F_1 + \frac{C_j}{F_2}\left(F_3 (V_j - F_C \phi_B) + \frac{M_J}{2\phi_B}(V_j^2 - (F_C \phi_B)^2)\right) $$

Charges are zero when $C_j = 0$.

### Total Charge per Terminal

$$ Q_{gate} = Q_{GS,meyer} + Q_{GD,meyer} + Q_{GB,meyer} + Q_{GS,ov} + Q_{GD,ov} + Q_{GB,ov} $$
$$ Q_{drain} = -Q_{GD,meyer} - Q_{GD,ov} - Q_{BD,junc} $$
$$ Q_{source} = -Q_{GS,meyer} - Q_{GS,ov} - Q_{BS,junc} $$
$$ Q_{bulk} = -Q_{GB,meyer} - Q_{GB,ov} + Q_{BS,junc} + Q_{BD,junc} $$

### Newton Limiting Functions

#### Critical Voltage

$$ V_{crit} = V_T \ln\!\left(\frac{V_T}{\sqrt{2}\; I_S}\right) $$

#### DEVfetlim -- Gate Voltage Limiting

Intermediate values:

$$ V_{tox} = V_{T0} + 3.5 $$
$$ V_{tsthi} = |2(V_{GS,old} - V_{T0})| + 2 $$
$$ V_{tstlo} = V_{tsthi}/2 + 2 $$
$$ \Delta V = V_{GS,new} - V_{GS,old} $$

**Case 1:** $V_{GS,old} \ge V_{T0}$ and $V_{GS,old} \ge V_{tox}$:

$$ V_{GS,lim} = \begin{cases} \max(V_{GS,new},\; V_{GS,old} - V_{tstlo}) & \Delta V \le 0 \\ \min(V_{GS,new},\; V_{GS,old} + V_{tsthi}) & \Delta V > 0 \end{cases} $$

**Case 2:** $V_{GS,old} \ge V_{T0}$ and $V_{GS,old} < V_{tox}$:

$$ V_{GS,lim} = \begin{cases} \max(V_{GS,new},\; V_{T0} - 0.5) & \Delta V \le 0 \\ \min(V_{GS,new},\; V_{GS,old} + V_{tsthi}) & \Delta V > 0 \end{cases} $$

**Case 3:** $V_{GS,old} < V_{T0}$:

$$ V_{GS,lim} = \begin{cases} \max(V_{GS,new},\; V_{GS,old} - V_{tstlo}) & \Delta V \le 0 \\ \min(V_{GS,new},\; V_{T0} + 0.5) & \Delta V > 0 \end{cases} $$

#### DEVlimvds -- Drain-Source Voltage Limiting

$$ V_{DS,lim} = \begin{cases} \max(V_{DS,new},\; -0.5\, V_{DS,old}) & V_{DS,old} \ge 3.5 \text{ and } \Delta V \le 0 \\ \min(V_{DS,new},\; 2.0\, V_{DS,old}) & V_{DS,old} \ge 3.5 \text{ and } \Delta V > 0 \\ \min(V_{DS,new},\; 4.0) & V_{DS,old} < 3.5 \text{ and } V_{DS,new} > 4.0 \\ V_{DS,new} & \text{otherwise} \end{cases} $$

#### DEVpnjlim -- PN Junction Voltage Limiting

When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 V_T$:

$$ V_{lim} = \begin{cases} V_{old} + V_T\!\left(2 + \ln\!\left(\frac{V_{new} - V_{old}}{V_T} - 2\right)\right) & V_{old} > 0 \text{ and } \frac{V_{new} - V_{old}}{V_T} > 0 \\ V_{crit} & V_{old} > 0 \text{ and } \frac{V_{new} - V_{old}}{V_T} \le 0 \\ V_T \ln\!\left(\frac{V_{new}}{V_T}\right) & V_{old} \le 0 \end{cases} $$

Otherwise: $V_{lim} = V_{new}$ (no limiting applied).

### Noise Sources

Four noise generators are declared between drain (D, node 0) and source (S, node 2):

| Source | Nodes | Type | Spectral Density |
|--------|-------|------|-----------------|
| Drain resistance thermal | D-S | Thermal | $S_I = 4 k_B T / R_D$ |
| Source resistance thermal | S-D | Thermal | $S_I = 4 k_B T / R_S$ |
| Channel shot noise | D-S | Shot | $S_I = \text{GDSNOI} \cdot \frac{8}{3} k_B T \, g_{ds}$ |
| Flicker (1/f) noise | D-S | Flicker | $S_I = K_F \cdot I_D^{A_F} / (C_{ox,area} \cdot L_{eff}^2 \cdot f)$ |

Noise model details are controlled by NLEV, KF, AF, and GDSNOI parameters.
