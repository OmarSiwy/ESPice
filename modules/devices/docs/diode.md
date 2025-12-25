# Berkeley SPICE Junction Diode (Level 1) -- Parameter & Equation Reference

> Standard Berkeley SPICE3f5 junction diode with breakdown, recombination, sidewall currents, high-injection knee, transit-time diffusion charge, and depletion capacitance.

## Model Topology

The diode has two external terminals: **p** (anode) and **n** (cathode). An internal node **p'** (p_prime) is inserted between the external anode and the junction to model the ohmic series resistance RS. The equivalent circuit is: external anode (p) -- RS -- internal anode (p') -- [junction diode + capacitances] -- cathode (n). When RS = 0, p' is shorted to p via a large conductance (GSHORT = 1e12 S).

## Parameters

### Core DC Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| LEVEL | - | - | 1 | - | Model level selector |
| IS | $I_S$ | A | 1e-14 | > 0 | Saturation current |
| JSW | $J_{SW}$ | A/m | 0 | $\geq 0$ | Sidewall saturation current density |
| N | $N$ | - | 1 | > 0 | Emission coefficient |
| NS | $N_S$ | - | 1 | > 0 | Sidewall emission coefficient |
| RS | $R_S$ | $\Omega$ | 0 | $\geq 0$ | Ohmic series resistance |
| COND | $G_0$ | S | 0 | $\geq 0$ | Conductance |
| IKF | $I_{KF}$ | A | 0 | $\geq 0$ | Forward knee current (0 = infinity) |
| IKR | $I_{KR}$ | A | 0 | $\geq 0$ | Reverse knee current (0 = infinity) |

### Recombination Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ISR | $I_{SR}$ | A | 0 | $\geq 0$ | Recombination saturation current |
| NR | $N_R$ | - | 2 | > 0 | Recombination emission coefficient |

### Breakdown Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| BV | $BV$ | V | 0 | $\geq 0$ | Reverse breakdown voltage (0 = no breakdown) |
| IBV | $I_{BV}$ | A | 1e-3 | > 0 | Current at breakdown voltage |
| NBV | $N_{BV}$ | - | 1 | > 0 | Breakdown emission coefficient |

### Junction Capacitance Parameters (Bottom)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJO | $C_{J0}$ | F | 0 | $\geq 0$ | Zero-bias bottom junction capacitance |
| VJ | $V_J$ | V | 1 | > 0 | Bottom junction built-in potential |
| M | $M$ | - | 0.5 | 0--1 | Bottom grading coefficient |
| FC | $FC$ | - | 0.5 | 0--1 | Forward-bias depletion capacitance coefficient |

### Junction Capacitance Parameters (Sidewall)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJP | $C_{JP}$ | F/m | 0 | $\geq 0$ | Sidewall zero-bias junction capacitance density |
| PHP | $\phi_P$ | V | 1 | > 0 | Sidewall junction built-in potential |
| MJSW | $M_{JSW}$ | - | 0.33 | 0--1 | Sidewall grading coefficient |
| FCS | $FC_S$ | - | 0.5 | 0--1 | Forward-bias sidewall depletion capacitance coefficient |

### Transit Time Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TT | $\tau_T$ | s | 0 | $\geq 0$ | Transit time |
| TTT1 | $TT_1$ | 1/K | 0 | - | Transit time 1st-order temperature coefficient |
| TTT2 | $TT_2$ | 1/K$^2$ | 0 | - | Transit time 2nd-order temperature coefficient |

### Temperature Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TNOM | $T_{nom}$ | $^\circ$C | 27 | - | Nominal (reference) temperature |
| TLEV | - | - | 0 | - | Diode temperature equation selector |
| TLEVC | - | - | 0 | - | Diode capacitance temperature equation selector |
| EG | $E_g$ | eV | 1.11 | > 0 | Activation energy (bandgap) |
| GAP1 | $G_1$ | eV/K | 7.02e-4 | - | First bandgap correction factor |
| GAP2 | $G_2$ | K | 1108 | - | Second bandgap correction factor |
| XTI | $X_{TI}$ | - | 3 | $\geq 0$ | Saturation current temperature exponent |
| TRS | $TR_{S1}$ | 1/K | 0 | - | Series resistance 1st-order temperature coefficient |
| TRS2 | $TR_{S2}$ | 1/K$^2$ | 0 | - | Series resistance 2nd-order temperature coefficient |
| TM1 | $TM_1$ | 1/K | 0 | - | Grading coefficient 1st-order temperature coefficient |
| TM2 | $TM_2$ | 1/K$^2$ | 0 | - | Grading coefficient 2nd-order temperature coefficient |
| CTA | $CT_A$ | 1/K | 0 | - | Area junction capacitance temperature coefficient |
| CTP | $CT_P$ | 1/K | 0 | - | Perimeter junction capacitance temperature coefficient |
| TPB | $TP_B$ | V/K | 0 | - | Area junction potential temperature coefficient |
| TPHP | $TP_{HP}$ | V/K | 0 | - | Perimeter junction potential temperature coefficient |
| TCV | $TC_V$ | V/K | 0 | - | Breakdown voltage temperature coefficient |

### Tunneling Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| JTUN | $J_{TUN}$ | A | 0 | $\geq 0$ | Tunneling saturation current |
| JTUNSW | $J_{TUNSW}$ | A/m | 0 | $\geq 0$ | Sidewall tunneling saturation current density |
| NTUN | $N_{TUN}$ | - | 30 | > 0 | Tunneling emission coefficient |
| XTITUN | $X_{TITUN}$ | - | 3 | $\geq 0$ | Tunneling saturation current temperature exponent |
| KEG | $K_{EG}$ | - | 1 | > 0 | EG correction factor for tunneling |

### Noise Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KF | $K_F$ | - | 0 | $\geq 0$ | Flicker noise coefficient |
| AF | $A_F$ | - | 1 | > 0 | Flicker noise exponent |

### Geometry and Scaling (Instance)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| AREA | $A$ | - | 1 | > 0 | Junction area factor |
| PJ | $P_J$ | m | 0 | $\geq 0$ | Junction perimeter |
| M (multiplier) | $M_{mult}$ | - | 1 | > 0 | Parallel device multiplier |
| W | $W$ | m | 0 | $\geq 0$ | Device width |
| L | $L$ | m | 0 | $\geq 0$ | Device length |
| TEMP | $T_{inst}$ | $^\circ$C | -1 (circuit default) | - | Instance temperature |
| DTEMP | $\Delta T$ | K | 0 | - | Temperature offset from circuit temperature |

### Geometry -- Level 3 (Metal/Poly Capacitor)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| LM | $L_M$ | m | 0 | $\geq 0$ | Length of metal capacitor |
| LP | $L_P$ | m | 0 | $\geq 0$ | Length of polysilicon capacitor |
| WM | $W_M$ | m | 0 | $\geq 0$ | Width of metal capacitor |
| WP | $W_P$ | m | 0 | $\geq 0$ | Width of polysilicon capacitor |
| XOM | $X_{OM}$ | m | 1e-6 | > 0 | Metal oxide thickness |
| XOI | $X_{OI}$ | m | 1e-6 | > 0 | Polysilicon oxide thickness |
| XM | $X_M$ | m | 0 | - | Masking/etching effects in metal |
| XP | $X_P$ | m | 0 | - | Masking/etching effects in polysilicon |
| XW | $X_W$ | m | 0 | - | Masking/etching effects (width) |

### Self-Heating Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RTH0 | $R_{TH}$ | K/W | 0 | $\geq 0$ | Thermal resistance |
| CTH0 | $C_{TH}$ | J/K | 1e-5 | > 0 | Thermal capacitance |

### Absolute Maximum Ratings
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| FV_MAX | $V_{F,max}$ | V | $\infty$ | > 0 | Maximum forward voltage |
| BV_MAX | $V_{R,max}$ | V | $\infty$ | > 0 | Maximum reverse voltage |
| ID_MAX | $I_{D,max}$ | A | $\infty$ | > 0 | Maximum current |
| TE_MAX | $T_{max}$ | $^\circ$C | $\infty$ | > 0 | Maximum temperature |
| PD_MAX | $P_{D,max}$ | W | $\infty$ | > 0 | Maximum power dissipation |

## Equations

### Thermal Voltage

$$V_t = k_B \cdot (T_{nom} + 273.15)$$

where $k_B = 8.617333 \times 10^{-5}$ eV/K (Boltzmann constant divided by electron charge). All equations below use $V_t$ evaluated at $T_{nom}$.

### Junction Voltage Definition

$$V_d = V_{p'} - V_n$$

Voltage across the internal anode (p') to cathode (n).

### Forward/Reverse Junction Current

$$I_{d,normal} = I_S \left( e^{\min\left(\frac{V_d}{N \cdot V_t},\; 80\right)} - 1 \right)$$

Standard Shockley diode equation with exponential overflow clamping at argument = 80.

### Deep Reverse Linear Extension

For $V_d < -3 N V_t$:

$$I_{d,deep} = -I_S$$

The current is clamped to $-I_S$ in the deep reverse region. Selection uses a branch blend:

$$I_d = \begin{cases} -I_S & \text{if } V_d < -3 N V_t \\ I_S\left(e^{V_d/(N V_t)} - 1\right) & \text{otherwise} \end{cases}$$

### Recombination Current

When $I_{SR} > 0$:

$$I_{rec} = I_{SR} \left( e^{\min\left(\frac{V_d}{N_R \cdot V_t},\; 80\right)} - 1 \right)$$

$$I_d \mathrel{+}= I_{rec}$$

### Sidewall Current

When $J_{SW} \neq 0$ and $P_J > 0$:

$$I_{SW} = J_{SW} \cdot P_J \left( e^{\min\left(\frac{V_d}{N_S \cdot V_t},\; 80\right)} - 1 \right)$$

$$I_d \mathrel{+}= I_{SW}$$

### High-Injection Knee Current (IKF)

When $I_{KF} > 0$:

$$I_d = \frac{I_d}{\sqrt{\max\left(1 + \frac{I_d}{I_{KF}},\; 10^{-30}\right)}}$$

The $\max$ clamp prevents square root of negative values.

### Reverse Breakdown Current

When $BV > 0$:

$$I_{BD} = -I_S \cdot e^{\min\left(\frac{-(V_d + BV)}{N_{BV} \cdot V_t},\; 80\right)}$$

$$I_d \mathrel{+}= I_{BD}$$

### GMIN Convergence Conductance

$$I_d \mathrel{+}= G_{min} \cdot V_d$$

where $G_{min} = 10^{-12}$ S.

### Area and Multiplier Scaling

$$I_d = I_d \cdot A \cdot M_{mult}$$

### Series Resistance Current

$$G_{RS} = \begin{cases} \frac{A \cdot M_{mult}}{R_S} & \text{if } R_S \neq 0 \\ 10^{12} & \text{if } R_S = 0 \text{ (short circuit)} \end{cases}$$

$$I_{RS} = (V_p - V_{p'}) \cdot G_{RS}$$

### KCL Node Stamps

$$I_p = I_{RS}$$
$$I_n = -I_d$$
$$I_{p'} = I_d - I_{RS}$$

Convention: positive current leaves the node.

---

### Bottom Junction Depletion Charge

**Reverse and moderate forward bias** ($V_d < FC \cdot V_J$):

$$Q_{dep} = \frac{C_{J0} \cdot V_J}{1 - M} \left[ 1 - \left(\max\left(1 - \frac{V_d}{V_J},\; 10^{-30}\right)\right)^{1-M} \right]$$

**Strong forward bias** ($V_d \geq FC \cdot V_J$) -- quadratic extension:

Precomputed coefficients:
$$F_1 = \frac{C_{J0} \cdot V_J}{1 - M} \left[ 1 - (1 - FC)^{1-M} \right]$$
$$F_2 = (1 - FC)^{1+M}$$
$$F_3 = 1 - FC \cdot (1 + M)$$

$$Q_{fwd} = F_1 + \frac{C_{J0}}{F_2} \left[ F_3 (V_d - FC \cdot V_J) + \frac{M}{2 V_J} \left( V_d^2 - (FC \cdot V_J)^2 \right) \right]$$

Region selection:
$$Q_{bottom} = \begin{cases} Q_{dep} & \text{if } V_d < FC \cdot V_J \\ Q_{fwd} & \text{otherwise} \end{cases}$$

Scaled by area: $Q_{bottom} = Q_{bottom} \cdot A$

### Sidewall Depletion Charge

**Reverse and moderate forward bias** ($V_d < FC_S \cdot \phi_P$):

$$Q_{sw,dep} = \frac{C_{JP} \cdot P_J \cdot \phi_P}{1 - M_{JSW}} \left[ 1 - \left(\max\left(1 - \frac{V_d}{\phi_P},\; 10^{-30}\right)\right)^{1-M_{JSW}} \right]$$

**Strong forward bias** ($V_d \geq FC_S \cdot \phi_P$) -- quadratic extension:

$$F_1^{sw} = \frac{C_{JP} \cdot P_J \cdot \phi_P}{1 - M_{JSW}} \left[ 1 - (1 - FC_S)^{1-M_{JSW}} \right]$$
$$F_2^{sw} = (1 - FC_S)^{1+M_{JSW}}$$
$$F_3^{sw} = 1 - FC_S \cdot (1 + M_{JSW})$$

$$Q_{sw,fwd} = F_1^{sw} + \frac{C_{JP} \cdot P_J}{F_2^{sw}} \left[ F_3^{sw} (V_d - FC_S \cdot \phi_P) + \frac{M_{JSW}}{2 \phi_P} \left( V_d^2 - (FC_S \cdot \phi_P)^2 \right) \right]$$

Region selection:
$$Q_{sw} = \begin{cases} Q_{sw,dep} & \text{if } V_d < FC_S \cdot \phi_P \\ Q_{sw,fwd} & \text{otherwise} \end{cases}$$

### Diffusion Charge (Transit Time)

When $TT \neq 0$:

$$I_{d,fwd} = I_S \left( e^{\min\left(\frac{V_d}{N \cdot V_t},\; 80\right)} - 1 \right)$$

$$Q_{diff} = \tau_T \cdot I_{d,fwd} \cdot A$$

### Total Charge

$$Q_{total} = \left( Q_{bottom} + Q_{sw} + Q_{diff} \right) \cdot M_{mult}$$

### Charge Node Stamps

$$Q_p = 0$$
$$Q_{p'} = Q_{total}$$
$$Q_n = -Q_{total}$$

Charge is associated with the p'--n junction branch; the external anode carries no charge (series resistance is purely resistive).

---

### Voltage Limiting (DEVpnjlim)

Critical voltage:

$$V_{crit} = N \cdot V_t \cdot \ln\!\left( \frac{N \cdot V_t}{\sqrt{2} \cdot I_S} \right)$$

Limiting logic applied to $V_{d,new}$ when $V_{d,new} > V_{crit}$ and $|V_{d,new} - V_{d,old}| > 2 N V_t$:

**Case 1:** $V_{d,old} > 0$ and step is positive ($\arg > 0$ where $\arg = (V_{d,new} - V_{d,old}) / (N V_t)$):

$$V_{d,new} = V_{d,old} + N V_t \left( 2 + \ln(\arg - 2) \right)$$

**Case 2:** $V_{d,old} > 0$ and step is negative ($\arg \leq 0$):

$$V_{d,new} = V_{d,old} - N V_t \left( 2 + \ln(2 - \arg) \right)$$

**Case 3:** $V_{d,old} \leq 0$:

$$V_{d,new} = N V_t \cdot \ln\!\left( \frac{V_{d,new}}{N V_t} \right)$$

The correction $\Delta = V_{d,new}^{(limited)} - V_{d,new}^{(original)}$ is applied to the $V_{p'}$ node only, preserving the external anode and cathode voltages.

---

### Noise Equations (Model Parameters Only)

The model defines flicker noise parameters; the standard SPICE noise contributions are:

**Shot noise:**
$$S_I^{shot} = 2 q \cdot I_d$$

**Flicker (1/f) noise:**
$$S_I^{flicker} = K_F \cdot \frac{I_d^{A_F}}{f}$$

**Thermal noise (series resistance):**
$$S_I^{thermal} = \frac{4 k_B T}{R_S}$$

(Noise equations follow standard SPICE3f5 formulation; KF, AF are extracted from the model struct.)
