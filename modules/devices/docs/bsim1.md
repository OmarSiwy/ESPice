# BSIM1 (Berkeley Short-Channel IGFET Model 1) -- Parameter & Equation Reference

> Four-terminal MOSFET model with L/W-dependent parameters, velocity saturation, DIBL, channel length modulation, and subthreshold conduction. NMOS/PMOS via `type_` flag.

## Model Topology

The BSIM1 device has four external terminals: **drain (d)**, **gate (g)**, **source (s)**, **bulk (b)**, and two internal nodes: **d' (d_prime)** and **s' (s_prime)**. External drain and source connect to their internal counterparts through series resistances derived from sheet resistance `RSH`. The intrinsic MOSFET channel conducts between d' and s', with bulk-drain and bulk-source pn-junction diodes. Gate capacitance couples g to d', s', and b via intrinsic charge and overlap capacitances.

## Parameters

### Threshold Voltage Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VFB | $V_{FB}$ | V | 0 | | Flat band voltage |
| LVFB | $L_{VFB}$ | V um | 0 | | Length dependence of VFB |
| WVFB | $W_{VFB}$ | V um | 0 | | Width dependence of VFB |
| PHI | $\phi_s$ | V | 0 | >0.1 (clamped) | Strong inversion surface potential |
| LPHI | $L_{\phi}$ | V um | 0 | | Length dependence of PHI |
| WPHI | $W_{\phi}$ | V um | 0 | | Width dependence of PHI |
| K1 | $K_1$ | V^{1/2} | 0 | | Body effect coefficient 1 |
| LK1 | $L_{K1}$ | V^{1/2} um | 0 | | Length dependence of K1 |
| WK1 | $W_{K1}$ | V^{1/2} um | 0 | | Width dependence of K1 |
| K2 | $K_2$ | 1/V | 0 | | Body effect coefficient 2 |
| LK2 | $L_{K2}$ | um/V | 0 | | Length dependence of K2 |
| WK2 | $W_{K2}$ | um/V | 0 | | Width dependence of K2 |

### DIBL (Drain-Induced Barrier Lowering) Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ETA | $\eta$ | -- | 0 | | VDS dependence of threshold voltage |
| LETA | $L_{\eta}$ | um | 0 | | Length dependence of ETA |
| WETA | $W_{\eta}$ | um | 0 | | Width dependence of ETA |
| X2E | $X_{2E}$ | 1/V | 0 | | VBS dependence of ETA |
| LX2E | $L_{X2E}$ | um/V | 0 | | Length dependence of X2E |
| WX2E | $W_{X2E}$ | um/V | 0 | | Width dependence of X2E |
| X3E | $X_{3E}$ | 1/V | 0 | | VDS dependence of ETA |
| LX3E | $L_{X3E}$ | um/V | 0 | | Length dependence of X3E |
| WX3E | $W_{X3E}$ | um/V | 0 | | Width dependence of X3E |

### Mobility Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| MUZ | $\mu_0$ | cm^2/Vs | 0 | | Zero-field mobility at VDS=0, VGS=VTH |
| X2MZ | $X_{2MZ}$ | cm^2/V^2s | 0 | | VBS dependence of MUZ (base) |
| LX2MZ | $L_{X2MZ}$ | cm^2 um/V^2s | 0 | | Length dependence of X2MZ |
| WX2MZ | $W_{X2MZ}$ | cm^2 um/V^2s | 0 | | Width dependence of X2MZ |
| MUS | $\mu_s$ | cm^2/Vs | 0 | | Mobility at VDS=VDD, VGS=VTH (CLM) |
| LMUS | $L_{MUS}$ | cm^2 um/Vs | 0 | | Length dependence of MUS |
| WMUS | $W_{MUS}$ | cm^2 um/Vs | 0 | | Width dependence of MUS |
| X2MS | $X_{2MS}$ | cm^2/V^2s | 0 | | VBS dependence of MUS |
| LX2MS | $L_{X2MS}$ | cm^2 um/V^2s | 0 | | Length dependence of X2MS |
| WX2MS | $W_{X2MS}$ | cm^2 um/V^2s | 0 | | Width dependence of X2MS |
| X3MS | $X_{3MS}$ | cm^2/V^2s | 0 | | VDS dependence of MUS |
| LX3MS | $L_{X3MS}$ | cm^2 um/V^2s | 0 | | Length dependence of X3MS |
| WX3MS | $W_{X3MS}$ | cm^2 um/V^2s | 0 | | Width dependence of X3MS |
| U0 | $U_0$ | 1/V | 0 | | VGS dependence of mobility (gate-field degradation) |
| LU0 | $L_{U0}$ | um/V | 0 | | Length dependence of U0 |
| WU0 | $W_{U0}$ | um/V | 0 | | Width dependence of U0 |
| X2U0 | $X_{2U0}$ | 1/V^2 | 0 | | VBS dependence of U0 |
| LX2U0 | $L_{X2U0}$ | um/V^2 | 0 | | Length dependence of X2U0 |
| WX2U0 | $W_{X2U0}$ | um/V^2 | 0 | | Width dependence of X2U0 |
| U1 | $U_1$ | um/V | 0 | | VDS dependence of mobility (velocity saturation) |
| LU1 | $L_{U1}$ | um^2/V | 0 | | Length dependence of U1 |
| WU1 | $W_{U1}$ | um^2/V | 0 | | Width dependence of U1 |
| X2U1 | $X_{2U1}$ | um/V^2 | 0 | | VBS dependence of U1 |
| LX2U1 | $L_{X2U1}$ | um^2/V^2 | 0 | | Length dependence of X2U1 |
| WX2U1 | $W_{X2U1}$ | um^2/V^2 | 0 | | Width dependence of X2U1 |
| X3U1 | $X_{3U1}$ | um/V^2 | 0 | | VDS dependence of U1 |
| LX3U1 | $L_{X3U1}$ | um^2/V^2 | 0 | | Length dependence of X3U1 |
| WX3U1 | $W_{X3U1}$ | um^2/V^2 | 0 | | Width dependence of X3U1 |

### Subthreshold Slope Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| N0 | $N_0$ | -- | 0 | | Subthreshold slope coefficient |
| LN0 | $L_{N0}$ | um | 0 | | Length dependence of N0 |
| WN0 | $W_{N0}$ | um | 0 | | Width dependence of N0 |
| NB | $N_B$ | 1/V | 0 | | VBS dependence of subthreshold slope |
| LNB | $L_{NB}$ | um/V | 0 | | Length dependence of NB |
| WNB | $W_{NB}$ | um/V | 0 | | Width dependence of NB |
| ND | $N_D$ | 1/V | 0 | | VDS dependence of subthreshold slope |
| LND | $L_{ND}$ | um/V | 0 | | Length dependence of ND |
| WND | $W_{ND}$ | um/V | 0 | | Width dependence of ND |

### Process Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TOX | $t_{ox}$ | um | 0 | >0 | Gate oxide thickness |
| DL | $\Delta L$ | um | 0 | | Channel length reduction |
| DW | $\Delta W$ | um | 0 | | Channel width reduction |
| LD | $L_D$ | m | 0 | | Lateral diffusion length |
| VDD | $V_{DD}$ | V | 0 | | Supply voltage (reference for MUS) |
| TEMP | -- | C | 0 | | Model temperature (degrees Celsius) |

### Source/Drain Resistance and Junction Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RSH | $R_{sh}$ | ohm/sq | 0 | | Sheet resistance of source/drain diffusion |
| JS | $J_s$ | A/m^2 | 0 | | Junction saturation current density |
| PB | $\phi_B$ | V | 0.1 | >0.01 (clamped) | Bulk junction built-in potential |
| MJ | $M_J$ | -- | 0 | | Bottom junction grading coefficient |
| PBSW | $\phi_{BSW}$ | V | 0.1 | >0.01 (clamped) | Sidewall junction built-in potential |
| MJSW | $M_{JSW}$ | -- | 0 | | Sidewall junction grading coefficient |
| CJ | $C_J$ | F/m^2 | 0 | | Bottom junction capacitance per unit area |
| CJSW | $C_{JSW}$ | F/m | 0 | | Sidewall junction capacitance per unit length |
| WDF | $W_{df}$ | um | 0 | | Default width of source/drain diffusion |
| DELL | $\Delta_{ell}$ | um | 0 | | Length reduction of source/drain diffusion |

### Overlap Capacitance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CGSO | $C_{GSO}$ | F/m | 0 | | Gate-source overlap capacitance per unit width |
| CGDO | $C_{GDO}$ | F/m | 0 | | Gate-drain overlap capacitance per unit width |
| CGBO | $C_{GBO}$ | F/m | 0 | | Gate-bulk overlap capacitance per unit length |

### Noise Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KF | $K_F$ | -- | 0 | | Flicker noise coefficient |
| AF | $A_F$ | -- | 1 | | Flicker noise exponent |

### Model Type
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XPART | -- | flag | false | | Channel charge partitioning flag (false=40/60, true=0/100) |
| TYPE | -- | -- | 1 | {-1, 1} | Device polarity: 1=NMOS, -1=PMOS |

### Instance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| W | $W$ | m | 5e-6 | >0 | Channel width |
| L | $L$ | m | 5e-6 | >0 | Channel length |
| TEMP | $T$ | K | 300.15 | >0 | Instance temperature |
| M | $M$ | -- | 1.0 | >0 | Parallel device multiplier |

## Equations

### Effective Geometry

$$L_{eff} = \max\bigl(L - \Delta L \times 10^{-6},\; 10^{-9}\bigr)$$
Effective channel length in meters. $\Delta L$ is in micrometers.

$$W_{eff,raw} = \max(W,\; 10^{-9})$$

$$L_{eff,\mu m} = L_{eff} \times 10^{6}, \quad W_{eff,\mu m} = W_{eff,raw} \times 10^{6} - \Delta W$$

$$W_{eff,m} = W_{eff,raw} - \Delta W \times 10^{-6}$$

All effective dimensions are clamped: $L_{eff,\mu m} \ge 0.01$, $W_{eff,\mu m} \ge 0.01$, $W_{eff,m} \ge 10^{-8}$.

### Oxide Capacitance

$$t_{ox,cm} = \begin{cases} t_{ox} \times 10^{-4} & t_{ox} > 0 \\ 10^{-5} & \text{otherwise} \end{cases}$$

$$C_{ox} = \frac{\varepsilon_{SiO_2}}{t_{ox,cm}} = \frac{3.453 \times 10^{-13}}{t_{ox,cm}} \quad [\text{F/cm}^2]$$

### L/W-Dependent Effective Parameters

All L/W-dependent parameters follow the same form:

$$P_{eff} = P_0 + \frac{L_P}{L_{eff,\mu m}} + \frac{W_P}{W_{eff,\mu m}}$$

Applied to: $V_{FB}$, $\phi_s$ (clamped $\ge 0.1$), $K_1$, $K_2$, $\eta$, $X_{2E}$, $X_{3E}$, $X_{2MZ}$, $\mu_s$, $X_{2MS}$, $X_{3MS}$, $U_0$, $X_{2U0}$, $U_1$, $X_{2U1}$, $X_{3U1}$, $N_0$, $N_B$, $N_D$.

Note: $\mu_0$ (MUZ) is used directly without L/W scaling.

### Beta Factor

$$\text{BetaFactor} = C_{ox} \times \frac{W_{eff,\mu m}}{L_{eff,\mu m}} \times 10^{-4}$$

$$\beta_0^{(0)} = \mu_0 \times \text{BetaFactor}$$

$$\beta_{0,B} = X_{2MZ,eff} \times \text{BetaFactor}$$

$$\beta_{VDD} = \mu_{s,eff} \times \text{BetaFactor}$$

$$\beta_{VDD,B} = X_{2MS,eff} \times \text{BetaFactor}$$

$$\beta_{VDD,D} = X_{3MS,eff} \times \text{BetaFactor}$$

### Mobility Degradation Parameters (Scaled)

$$U_{gs} = U_{0,eff} \times \text{BetaFactor}$$

$$U_{gs,B} = X_{2U0,eff} \times \text{BetaFactor}$$

$$U_{ds} = U_{1,eff} \times \text{BetaFactor}$$

$$U_{ds,B} = X_{2U1,eff} \times \text{BetaFactor}$$

$$U_{ds,D} = X_{3U1,eff} \times \text{BetaFactor}$$

### Source/Drain Resistance

$$G_D = G_S = \begin{cases} \frac{M}{R_{sh}} & R_{sh} > 0 \\ 10^{12} \times M & R_{sh} = 0 \end{cases}$$

$$I_{RD} = G_D \cdot (V_d - V_{d'})$$

$$I_{RS} = G_S \cdot (V_s - V_{s'})$$

### Junction Saturation Current

$$A_{drain} = A_{source} = \begin{cases} W_{df} \times \Delta_{ell} & W_{df} > 0 \\ W_{eff,m} \times 10^{-6} & \text{otherwise} \end{cases}$$

$$I_{s,drain} = \max(A_{drain} \times J_s,\; 10^{-15})$$

$$I_{s,source} = \max(A_{source} \times J_s,\; 10^{-15})$$

### Thermal Voltage

$$V_T = k_B T / q = 8.617333262145 \times 10^{-5} \times T \quad [V]$$

Where $T$ is instance temperature in Kelvin.

### Terminal Voltage Conditioning (PMOS and S/D Swap)

$$V_{DS,typed} = (V_{d'} - V_{s'}) \times \text{type}$$

$$V_{GS,typed} = (V_g - V_{s'}) \times \text{type}$$

$$V_{BS,typed} = (V_b - V_{s'}) \times \text{type}$$

Source/drain swap for reverse bias ($V_{DS} < 0$):

$$V_{DS} = |V_{DS,typed}|$$

$$V_{DS,neg} = \min(V_{DS,typed},\; 0)$$

$$V_{GS} = V_{GS,typed} - V_{DS,neg}$$

$$V_{BS} = V_{BS,typed} - V_{DS,neg}$$

$$V_{BD} = V_{BS} - V_{DS}$$

### Junction Diode Currents

$$I_{BS} = I_{s,source} \left[\exp\!\left(\min\!\left(\frac{V_{BS}}{V_T},\; 80\right)\right) - 1\right] + g_{min} \cdot V_{BS}$$

$$I_{BD} = I_{s,drain} \left[\exp\!\left(\min\!\left(\frac{V_{BD}}{V_T},\; 80\right)\right) - 1\right] + g_{min} \cdot V_{BD}$$

Where $g_{min} = 10^{-12}$ S. Exponential argument clamped at 80 to prevent overflow.

### Gate-Field Mobility Degradation ($U_{gs}$)

$$U_{gs,raw} = U_{gs} + U_{gs,B} \cdot V_{BS}$$

$$U_{gs,eff} = \max(U_{gs,raw},\; 0)$$

### Velocity Saturation Parameter ($U_{ds}$)

$$U_{ds,raw} = U_{ds} + U_{ds,B} \cdot V_{BS} + U_{ds,D} \cdot (V_{DS} - V_{DD})$$

$$U_{ds,scaled} = \frac{\max(U_{ds,raw},\; 0)}{L_{eff,\mu m}}$$

### DIBL Effect ($\eta$)

$$\eta_{raw} = \eta_{eff} + X_{2E,eff} \cdot V_{BS} + X_{3E,eff} \cdot (V_{DS} - V_{DD})$$

$$\eta_{clamp} = \min\bigl(\max(\eta_{raw},\; 0),\; 1\bigr)$$

### Surface Potential and Body Effect

$$V_{PB} = \phi_s - \min(V_{BS},\; 0)$$

$$\sqrt{V_{PB}} = \sqrt{\max(V_{PB},\; 0.001)}$$

### Threshold Voltage

$$V_{on} = V_{FB,eff} + \phi_{s,eff} + K_{1,eff} \sqrt{V_{PB}} - K_{2,eff} \cdot V_{PB} - \eta_{clamp} \cdot V_{DS}$$

### Gate Overdrive

$$V_{GS} - V_{th} = V_{GS} - V_{on}$$

### G and A Factors

$$G = 1 - \frac{1}{1.744 + 0.8364 \cdot V_{PB}}$$

$$A = \max\!\left(1 + \frac{G \cdot K_{1,eff}}{2\sqrt{V_{PB}}},\; 1\right)$$

### Mobility Degradation Factor (Arg)

$$\text{Arg} = \max\!\left(1 + U_{gs,eff} \cdot (V_{GS} - V_{th}),\; 1\right)$$

### Beta Interpolation (Quadratic in $V_{DS}$)

For $V_{DD} > 0.001$:

$$\beta_{V_{DS}=0} = \beta_0^{(0)} + \beta_{0,B} \cdot V_{BS}$$

$$\beta_{V_{DD}} = \beta_{VDD} + \beta_{VDD,B} \cdot V_{BS}$$

$$C_1 = \frac{-\beta_{V_{DD}} + \beta_{V_{DS}=0} + \beta_{VDD,D} \cdot V_{DD}}{V_{DD}^2}$$

$$C_2 = \frac{2(\beta_{V_{DD}} - \beta_{V_{DS}=0})}{V_{DD}} - \beta_{VDD,D}$$

$$\beta_0 = (C_1 \cdot V_{DS} + C_2) \cdot V_{DS} + \beta_{V_{DS}=0}$$

For $V_{DD} \le 0.001$:

$$\beta_0 = \beta_{V_{DS}=0}$$

### Beta with Mobility Degradation

$$\beta = \frac{\beta_0}{\text{Arg}}$$

### Saturation Voltage ($V_{DSAT}$)

$$V_C = \max\!\left(\frac{U_{ds,scaled} \cdot (V_{GS}-V_{th})}{A},\; 0\right)$$

$$K = \frac{1}{2}\left(1 + V_C + \sqrt{1 + 2V_C}\right)$$

$$V_{DSAT} = \max\!\left(\frac{V_{GS} - V_{th}}{A \sqrt{K}},\; 0\right)$$

### Drain Current (Unified Model)

Effective drain voltage (smooth transition between triode and saturation):

$$V_{DS,eff} = \min(V_{DS},\; V_{DSAT})$$

Triode-style core current:

$$\text{Argl1} = \max\!\left(1 + U_{ds,scaled} \cdot V_{DS,eff},\; 1\right)$$

$$\text{Argl2} = (V_{GS} - V_{th})^+ - \frac{A}{2} V_{DS,eff}$$

$$I_{D,base} = \beta \cdot \text{Argl2} \cdot \frac{V_{DS,eff}}{\text{Argl1}}$$

Where $(V_{GS}-V_{th})^+ = \max(V_{GS}-V_{th},\; 0)$.

### Channel Length Modulation (CLM)

Excess drain voltage beyond saturation:

$$V_{DS,excess} = \max(V_{DS} - V_{DSAT},\; 0)$$

When velocity saturation parameters are nonzero ($U_{ds}$, $X_{2U1}$, or $X_{3U1} > 10^{-20}$):

$$I_{D,main} = I_{D,base} \cdot \left(1 + U_{ds,scaled} \cdot V_{DS,excess}\right)$$

Otherwise:

$$I_{D,main} = I_{D,base}$$

### Subthreshold Current

Disabled when $N_0 \ge 200$. Otherwise:

$$n = \max\!\left(N_{0,eff} + N_{B,eff} \cdot V_{BS} + N_{D,eff} \cdot V_{DS},\; 0.5\right)$$

$$W_{DS} = 1 - \exp\!\left(-\frac{V_{DS}}{V_T}\right)$$

$$W_{GS} = \exp\!\left(\frac{V_{GS} - V_{th}}{n \cdot V_T}\right)$$

$$I_{weak,0} = 6.04965 \cdot V_T^2 \cdot \beta_0^{(0)} \cdot W_{GS} \cdot W_{DS}$$

$$I_{limit} = 4.5 \cdot V_T^2 \cdot \beta_0^{(0)}$$

$$I_{subth} = \frac{I_{limit} \cdot I_{weak,0}}{I_{limit} + I_{weak,0}}$$

Smooth parallel limiting prevents subthreshold current from exceeding $I_{limit}$.

### Total Drain Current

$$I_{D} = \max\!\left(I_{D,main} + I_{subth},\; 0\right) \cdot \text{type} \cdot M$$

### KCL Assembly

$$I_d = I_{RD}$$

$$I_g = 0$$

$$I_s = I_{RS}$$

$$I_b = (I_{BD} + I_{BS}) \cdot M$$

$$I_{d'} = -I_{RD} + I_D \cdot \text{type} \cdot M - I_{BD} \cdot M$$

$$I_{s'} = -I_{RS} - I_D \cdot \text{type} \cdot M - I_{BS} \cdot M$$

## Charge Equations

### Gate Intrinsic Charge (40/60 Partition, Saturation Region)

Threshold voltage for charge model (without DIBL):

$$V_{th,0} = V_{FB,eff} + \phi_{s,eff} + K_{1,eff} \sqrt{V_{PB}}$$

Saturation region gate charge:

$$Q_G^{sat} = W_L C_{ox} \left(V_{GS} - V_{FB,eff} - \phi_{s,eff} - \frac{V_{GS} - V_{th,0}}{3A}\right)$$

Where $W_L C_{ox} = C_{ox} \cdot L_{eff,m} \cdot W_{eff,m} \times 10^{4}$.

Saturation region bulk charge:

$$Q_B^{sat} = W_L C_{ox} \left(V_{FB,eff} + \phi_{s,eff} - V_{th,0} + \frac{(1-A)(V_{GS}-V_{th,0})}{3A}\right)$$

Saturation region drain charge:

$$Q_D^{sat} = -\frac{4}{15} W_L C_{ox} (V_{GS} - V_{th,0})$$

### Overlap Charges

$$Q_{GD,ov} = C_{GDO} \cdot W_{eff,m} \cdot V_{GD}$$

$$Q_{GS,ov} = C_{GSO} \cdot W_{eff,m} \cdot V_{GS}$$

$$Q_{GB,ov} = C_{GBO} \cdot L_{eff,m} \cdot V_{GB}$$

### Total Gate Charge

$$Q_{gate} = Q_G^{sat} + Q_{GD,ov} + Q_{GS,ov} + Q_{GB,ov}$$

### Bulk Junction Depletion Charges

Bottom and sidewall zero-bias capacitances:

$$C_{zbs} = C_J \cdot A_{source}, \quad C_{zbssw} = C_{JSW} \cdot P_{source}$$

$$C_{zbd} = C_J \cdot A_{drain}, \quad C_{zbdsw} = C_{JSW} \cdot P_{drain}$$

Where $P_{drain} = P_{source} = 2 W_{eff,m}$.

Linearized junction charge (source side):

$$Q_{BS} = V_{BS}\left(C_{zbs} + C_{zbssw}\right) + \frac{V_{BS}^2}{2}\left(\frac{C_{zbs} \cdot M_J}{\phi_B} + \frac{C_{zbssw} \cdot M_{JSW}}{\phi_{BSW}}\right)$$

Linearized junction charge (drain side):

$$Q_{BD} = V_{BD}\left(C_{zbd} + C_{zbdsw}\right) + \frac{V_{BD}^2}{2}\left(\frac{C_{zbd} \cdot M_J}{\phi_B} + \frac{C_{zbdsw} \cdot M_{JSW}}{\phi_{BSW}}\right)$$

### Intrinsic Drain and Bulk Charges

$$Q_{drn} = Q_D^{sat} - Q_{GD,ov}$$

$$Q_{bulk} = Q_B^{sat} - Q_{GB,ov}$$

### Node Charge Assembly

$$Q_d = 0 \quad \text{(external drain, resistance node)}$$

$$Q_g = Q_{gate} \cdot M$$

$$Q_s = 0 \quad \text{(external source, resistance node)}$$

$$Q_b = (Q_{bulk} + Q_{BD} + Q_{BS}) \cdot M$$

$$Q_{d'} = (Q_{drn} - Q_{BD}) \cdot M$$

$$Q_{s'} = -(Q_g + Q_b + Q_{d'}) \quad \text{(charge conservation)}$$

## Newton Limiting Functions

### PN Junction Limiting (`pnjlim`)

Critical voltage:

$$V_{crit} = V_T \ln\!\left(\frac{V_T}{\sqrt{2}\; I_s}\right)$$

For $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2V_T$:

$$V_{lim} = \begin{cases} V_{old} + V_T\!\left(2 + \ln\!\left(\frac{V_{new}-V_{old}}{V_T} - 2\right)\right) & V_{old} > 0,\; \frac{V_{new}-V_{old}}{V_T} > 0 \\ V_{crit} & V_{old} > 0,\; \frac{V_{new}-V_{old}}{V_T} \le 0 \\ V_T \ln\!\left(\frac{V_{new}}{V_T}\right) & V_{old} \le 0 \end{cases}$$

Otherwise $V_{lim} = V_{new}$.

Applied to: $V_{BS}$, $V_{BD}$.

### FET Gate Voltage Limiting (`fetlim`)

$$V_{tst,hi} = |2(V_{old} - V_{th,0})| + 2$$

$$V_{tst,lo} = \frac{V_{tst,hi}}{2} + 2$$

$$V_{tox} = V_{th,0} + 3.5$$

Region-dependent clamping of $V_{GS}$:

| Condition | $\Delta V \le 0$ | $\Delta V > 0$ |
|-----------|-------------------|-----------------|
| $V_{old} \ge V_{tox}$ | $\max(V_{new},\; V_{th,0}+2)$ if $V_{new} < V_{tox}$; else clamp $-\Delta V \le V_{tst,hi}$ | Clamp $\Delta V \le V_{tst,hi}$ |
| $V_{th,0} \le V_{old} < V_{tox}$ | Clamp $V_{new} \ge V_{th,0} - V_{tst,lo}$ | Clamp $\Delta V \le V_{tst,hi}$ |
| $V_{old} < V_{th,0}$ | Clamp $-\Delta V \le V_{tst,hi}$ | Clamp $V_{new} \le V_{th,0} + V_{tst,lo}$ |

Applied to: $V_{GS}$.

### Drain-Source Voltage Limiting (`limvds`)

| Condition | $V_{new} > V_{old}$ | $V_{new} \le V_{old}$ |
|-----------|----------------------|------------------------|
| $V_{old} \ge 3.5$ | $\min(V_{new},\; 3V_{old}+2)$ | $\max(V_{new},\; 0.5 V_{old})$ if $V_{new} < 3.5$; else $\max(V_{new},\; 2)$ |
| $V_{old} < 3.5$ | $\min(V_{new},\; 4)$ | $\max(V_{new},\; -0.5)$ |

Applied to: $V_{DS}$.

### Limiting Application Order

1. $V_{GS}$ via `fetlim` (using $V_{th,0}$ estimate)
2. $V_{DS}$ via `limvds`
3. $V_{BS}$ via `pnjlim` (using $V_{crit}$)
4. $V_{BD}$ via `pnjlim` (using $V_{crit}$, after $V_{BS}$ and $V_{DS}$ are limited)
