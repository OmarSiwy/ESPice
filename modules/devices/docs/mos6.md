# MOS Level 6 (Sakurai-Newton Empirical MOSFET) -- Parameter & Equation Reference

> Empirical 4-terminal MOSFET with power-law I-V (Sakurai-Newton), body effect, DIBL, channel-length modulation, Meyer overlap capacitances, and bulk junction diodes.

## Model Topology

The device has four external terminals: **drain** (D), **gate** (G), **source** (S), **bulk** (B), plus two internal nodes **drain'** (D') and **source'** (S') separated from the external terminals by parasitic resistances RD and RS. The intrinsic MOSFET channel connects D' to S' with gate and bulk modulating the channel. Bulk-source and bulk-drain PN junction diodes connect B to S' and B to D' respectively. Overlap capacitances (CGS, CGD, CGB) bridge the gate to the internal source, drain, and bulk nodes.

## Parameters

### DC Model Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VTO | $V_{TO}$ | V | 0 | -- | Zero-bias threshold voltage |
| KV | $K_V$ | -- | 2 | -- | Saturation voltage factor |
| NV | $N_V$ | -- | 0.5 | -- | Saturation voltage exponent |
| KC | $K_C$ | A/V^NC | 5e-5 | -- | Saturation current factor |
| NC | $N_C$ | -- | 1 | -- | Saturation current exponent |
| NVTH | $N_{VTH}$ | 1/V | 0.5 | -- | Threshold voltage coefficient (Vds dependence) |
| PS | $P_S$ | -- | 0 | -- | Saturation current modification parameter |
| GAMMA | $\gamma$ | V^0.5 | 0 | -- | Bulk threshold parameter (body effect) |
| GAMMA1 | $\gamma_1$ | -- | 0 | -- | Secondary bulk threshold parameter (linear Vbs) |
| SIGMA | $\sigma$ | 1/V | 0 | -- | Static feedback / DIBL parameter |
| PHI | $\phi$ | V | 0.6 | -- | Surface potential at strong inversion |
| LAMBDA | $\lambda$ | 1/V | 0 | -- | Channel-length modulation parameter (simple) |
| LAMBDA0 | $\lambda_0$ | 1/V | 0 | -- | Channel-length modulation parameter 0 |
| LAMBDA1 | $\lambda_1$ | 1/V | 0 | -- | Channel-length modulation parameter 1 (body-bias dependent) |

### Parasitic Resistance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RD | $R_D$ | Ohm | 0 | -- | Drain ohmic resistance |
| RS | $R_S$ | Ohm | 0 | -- | Source ohmic resistance |
| RSH | $R_{SH}$ | Ohm/sq | 0 | -- | Sheet resistance |

### Junction Diode Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IS | $I_S$ | A | 1e-14 | -- | Bulk junction saturation current |
| JS | $J_S$ | A/m^2 | 0 | -- | Bulk junction saturation current density |
| PB | $P_B$ | V | 0.8 | -- | Bulk junction built-in potential |

### Capacitance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CBD | $C_{BD}$ | F | 0 | -- | Zero-bias bulk-drain junction capacitance |
| CBS | $C_{BS}$ | F | 0 | -- | Zero-bias bulk-source junction capacitance |
| CGSO | $C_{GSO}$ | F/m | 0 | -- | Gate-source overlap capacitance per unit width |
| CGDO | $C_{GDO}$ | F/m | 0 | -- | Gate-drain overlap capacitance per unit width |
| CGBO | $C_{GBO}$ | F/m | 0 | -- | Gate-bulk overlap capacitance per unit length |
| CJ | $C_J$ | F/m^2 | 0 | -- | Zero-bias bottom junction capacitance per unit area |
| MJ | $M_J$ | -- | 0.5 | -- | Bottom junction grading coefficient |
| CJSW | $C_{JSW}$ | F/m | 0 | -- | Zero-bias sidewall junction capacitance per unit length |
| MJSW | $M_{JSW}$ | -- | 0.5 | -- | Sidewall junction grading coefficient |
| FC | $F_C$ | -- | 0.5 | -- | Forward-bias junction capacitance fitting parameter |

### Technology Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TOX | $t_{ox}$ | m | 0 | -- | Gate oxide thickness |
| U0 | $\mu_0$ | cm^2/Vs | 0 | -- | Low-field surface mobility |
| TPG | -- | -- | 0 | {0,1} | Gate material type |
| NSUB | $N_{SUB}$ | 1/cm^3 | 0 | -- | Substrate doping concentration |
| NSS | $N_{SS}$ | 1/cm^2 | 0 | -- | Surface state density |
| LD | $L_D$ | m | 0 | -- | Lateral diffusion length |
| TNOM | $T_{NOM}$ | K | 300.15 | -- | Parameter measurement temperature |
| TYPE | -- | -- | 1 | {-1, 1} | Device polarity: 1 = NMOS, -1 = PMOS |

### Instance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| W | $W$ | m | 1e-6 | -- | Channel width |
| L | $L$ | m | 1e-6 | -- | Channel drawn length |

## Equations

### Effective Geometry

$$L_{eff} = \max(L - 2 L_D,\; 1\times10^{-9})$$

$$W_{eff} = \max(W,\; 1\times10^{-9})$$

### Terminal Voltages and Source/Drain Reversal

Terminal voltages are referenced to the internal source node S'. For PMOS ($\text{TYPE} = -1$), all terminal voltages are negated before evaluation.

$$V_{GS} = V_G - V_{S'}, \quad V_{DS} = V_{D'} - V_{S'}, \quad V_{BS} = V_B - V_{S'}$$

Source/drain reversal uses a smooth step function to handle $V_{DS} < 0$:

$$V_{DS,eff} = |V_{DS}|$$

$$\alpha_{fwd} = \frac{V_{DS} + |V_{DS}|}{2\,(|V_{DS}| + \epsilon_{mode})}, \quad \epsilon_{mode} = 10^{-30}$$

$$V_{GS,use} = \alpha_{fwd} \cdot V_{GS} + (1 - \alpha_{fwd}) \cdot (V_{GS} - V_{DS})$$

$$V_{BS,use} = \alpha_{fwd} \cdot V_{BS} + (1 - \alpha_{fwd}) \cdot (V_{BS} - V_{DS})$$

$$V_{BD} = V_{BS,use} - V_{DS,eff}$$

### Thermal Voltage

$$V_T = k_B T_{NOM} / q = 8.617333262145 \times 10^{-5} \cdot T_{NOM}$$

### Threshold Voltage

Base threshold with body effect (when $\gamma \neq 0$):

$$V_{TH} = V_{TO} + \gamma \left(\sqrt{\max(\phi - V_{BS,use},\; 10^{-30})} - \sqrt{\phi}\right)$$

Secondary body effect (when $\gamma_1 \neq 0$):

$$V_{TH} \mathrel{+}= \gamma_1 \cdot V_{BS,use}$$

DIBL / static feedback (when $\sigma \neq 0$):

$$V_{TH} \mathrel{+}= \sigma \cdot V_{DS,eff}$$

Threshold voltage Vds dependence (when $N_{VTH} \neq 0$):

$$V_{TH} \mathrel{*}= (1 + N_{VTH} \cdot V_{DS,eff})$$

### Gate Overdrive

$$V_{GST} = V_{GS,use} - V_{TH}$$

Clamped positive overdrive (for power-law evaluation):

$$V_{GST,+} = \frac{V_{GST} + |V_{GST}|}{2} + 10^{-30}$$

### Saturation Voltage (Sakurai-Newton)

$$V_{DSAT} = K_V \cdot V_{GST,+}^{N_V}$$

### Drain Current (Sakurai-Newton)

Saturation current:

$$I_{SAT} = \frac{K_C \cdot W_{eff}}{L_{eff}} \cdot V_{GST,+}^{N_C}$$

Smooth linear/saturation transition using the ratio $r = V_{DS,eff} / (V_{DSAT} + 10^{-20})$:

$$r_{clamped} = \frac{r + 1 - \sqrt{(r - 1)^2 + \epsilon_s^2}}{2}, \quad \epsilon_s = 10^{-4}$$

$$f_{lin} = 2 r_{clamped} - r_{clamped}^2$$

$$I_{DS} = I_{SAT} \cdot f_{lin}$$

This is a smooth approximation of $\min(r, 1)$ followed by the parabolic linear-region factor $f_{lin} = 1 - (1 - r_{clamped})^2$.

### Channel-Length Modulation

When $\lambda_0 \neq 0$ (with optional body-bias dependence via $\lambda_1$):

$$\lambda_{eff} = \lambda_0 + \lambda_1 \cdot V_{BS,use}$$

$$I_{DS} \mathrel{*}= 1 + \lambda_{eff} \cdot \max(V_{DS,eff} - V_{DSAT},\; 0)$$

When $\lambda_0 = 0$ but $\lambda \neq 0$ (simple CLM):

$$I_{DS} \mathrel{*}= 1 + \lambda \cdot \max(V_{DS,eff} - V_{DSAT},\; 0)$$

### Current Sign and Polarity

Reversal mode sign (maps smooth step back to signed current):

$$\text{mode} = 2\alpha_{fwd} - 1$$

$$I_{DS} \mathrel{*}= \text{mode}$$

For PMOS, the final drain current and junction currents are multiplied by $\text{TYPE}$ ($-1$).

### Bulk Junction Diode Currents

Exponential diode model with overflow guard ($V/V_T$ clamped to 80):

$$I_{BS} = I_S \left[\exp\!\left(\min\!\left(\frac{V_{BS,use}}{V_T},\; 80\right)\right) - 1\right]$$

$$I_{BD} = I_S \left[\exp\!\left(\min\!\left(\frac{V_{BD}}{V_T},\; 80\right)\right) - 1\right]$$

### Parasitic Resistance Currents

$$G_D = \begin{cases} 1/R_D & R_D \neq 0 \\ 10^{12} & R_D = 0 \end{cases}, \quad G_S = \begin{cases} 1/R_S & R_S \neq 0 \\ 10^{12} & R_S = 0 \end{cases}$$

$$I_{RD} = G_D \cdot (V_D - V_{D'}), \quad I_{RS} = G_S \cdot (V_S - V_{S'})$$

### GMIN Stabilization Currents

A minimum conductance $G_{MIN} = 10^{-12}$ S is applied across key node pairs to prevent singular matrices:

$$I_{GMIN,DS} = G_{MIN} \cdot (V_{D'} - V_{S'})$$

$$I_{GMIN,GS} = G_{MIN} \cdot (V_G - V_{S'})$$

$$I_{GMIN,GD} = G_{MIN} \cdot (V_G - V_{D'})$$

### KCL Node Stamps

| Node | Current Expression |
|------|--------------------|
| D (ext) | $-I_{RD}$ |
| G | $-I_{GMIN,GS} - I_{GMIN,GD}$ |
| S (ext) | $-I_{RS}$ |
| B | $-I_{BS} - I_{BD}$ |
| D' (int) | $I_{RD} + I_{DS} + I_{BD} + I_{GMIN,GD} - I_{GMIN,DS}$ |
| S' (int) | $I_{RS} - I_{DS} + I_{BS} + I_{GMIN,GS} + I_{GMIN,DS}$ |

Sign convention: positive current flows INTO the node.

### Gate Overlap Charges (Meyer Model)

$$Q_{GS} = C_{GSO} \cdot V_{GS}$$

$$Q_{GD} = C_{GDO} \cdot V_{GD}$$

$$Q_{GB} = C_{GBO} \cdot V_{GB}$$

These are linear overlap capacitances only (no intrinsic gate charge partitioning in this implementation).

### Bulk Junction Depletion Charges

Bulk-source junction charge (when $C_{BS} \neq 0$):

$$Q_{BS} = \frac{C_{BS} \cdot P_B}{1 - M_J} \left[1 - \left(\max\!\left(1 - \frac{V_{BS}}{P_B},\; 10^{-30}\right)\right)^{1-M_J}\right]$$

Bulk-drain junction charge (when $C_{BD} \neq 0$):

$$Q_{BD} = \frac{C_{BD} \cdot P_B}{1 - M_J} \left[1 - \left(\max\!\left(1 - \frac{V_{BD}}{P_B},\; 10^{-30}\right)\right)^{1-M_J}\right]$$

### Charge Node Stamps

| Node | Charge Expression |
|------|-------------------|
| G | $+Q_{GS} + Q_{GD} + Q_{GB}$ |
| B | $-Q_{GB} + Q_{BS} + Q_{BD}$ |
| D' | $-Q_{GD} - Q_{BD}$ |
| S' | $-Q_{GS} - Q_{BS}$ |

The solver differentiates charges with respect to time to obtain displacement currents ($I = dQ/dt$).

## Convergence Aids

### PN Junction Voltage Limiting

Critical voltage:

$$V_{crit} = V_T \cdot \ln\!\left(\frac{V_T}{\sqrt{2}\; I_S}\right)$$

Applied to $V_{BS}$ and $V_{BD}$ each Newton iteration:

$$V_{new,lim} = \begin{cases}
V_{old} + V_T \ln(1 + (V_{new} - V_{old})/V_T) & \text{if } V_{new} > V_{crit} \text{ and } |V_{new} - V_{old}| > 2V_T \text{ and } V_{old} > 0 \text{ and arg} > 0 \\
V_{crit} & \text{if } V_{new} > V_{crit} \text{ and } |V_{new} - V_{old}| > 2V_T \text{ and } V_{old} > 0 \text{ and arg} \leq 0 \\
V_T \ln(V_{new}/V_T) & \text{if } V_{new} > V_{crit} \text{ and } |V_{new} - V_{old}| > 2V_T \text{ and } V_{old} \leq 0 \\
V_{new} & \text{otherwise}
\end{cases}$$

where $\text{arg} = 1 + (V_{new} - V_{old})/V_T$.

### MOS Gate/Drain Voltage Limiting

Applied to $V_{GS}$ and $V_{DS}$ each Newton iteration:

$$V_{new,lim} = \begin{cases}
V_{old} + 2V_T & \text{if } V_{new} - V_{old} > 2V_T \\
V_{old} - 2V_T & \text{if } V_{old} - V_{new} > 2V_T \\
V_{new} & \text{otherwise}
\end{cases}$$

### Source Stepping (Convergence Aid)

During continuation ($\lambda \in [0, 1]$), the saturation current is augmented:

$$I_{S,eff} = I_S + G_{MIN} \cdot (1 - \lambda), \quad G_{MIN} = 10^{-12}$$

At $\lambda = 0$ the device is nearly linear; at $\lambda = 1$ the original parameters are restored.

## Noise Sources

| Source | Nodes | Type | Description |
|--------|-------|------|-------------|
| Rd thermal | D -- D' | Thermal | Drain resistance thermal noise |
| Rs thermal | S -- S' | Thermal | Source resistance thermal noise |
| Channel thermal | D' -- S' | Thermal | Channel thermal noise |
| Channel 1/f | D' -- S' | Flicker | Channel flicker (1/f) noise |
