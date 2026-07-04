# Gummel-Poon BJT (Berkeley SPICE3f5) -- Parameter & Equation Reference

> Gummel-Poon / Ebers-Moll bipolar junction transistor with Early effect, high-injection roll-off, parasitic resistances, junction capacitances, transit times, substrate diode, and 1/f noise.

## Model Topology

Four external terminals: **Collector (C)**, **Base (B)**, **Emitter (E)**, **Substrate (S)**. Three internal nodes: **C'** (intrinsic collector), **B'** (intrinsic base), **E'** (intrinsic emitter). Parasitic resistances RC, RB, RE connect external to internal nodes. The intrinsic transistor sits between B', C', E' with transport current controlled by base charge. A substrate diode connects S to C'. NPN/PNP polarity is handled by a sign factor `type` (+1 NPN, -1 PNP) applied to all junction voltages at input and all currents at output.

## Parameters

### Device Type and Structure
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TYPE | type_ | -- | 1 | {-1, +1} | +1 = NPN, -1 = PNP |
| SUBS | subs | -- | 1 | {0, 1} | Vertical (1) or lateral (0) device |
| TNOM | tnom | degC | 27.0 | -- | Parameter measurement temperature |

### DC Current Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IS | $I_S$ | A | 1.0e-16 | >0 | Transport saturation current |
| IBE | $I_{BE}$ | A | 0.0 | >=0 | Base-emitter saturation current (alternate) |
| IBC | $I_{BC}$ | A | 0.0 | >=0 | Base-collector saturation current (alternate) |
| BF | $\beta_F$ | -- | 100.0 | >0 | Ideal forward current gain |
| NF | $n_F$ | -- | 1.0 | >0 | Forward emission coefficient |
| BR | $\beta_R$ | -- | 1.0 | >0 | Ideal reverse current gain |
| NR | $n_R$ | -- | 1.0 | >0 | Reverse emission coefficient |
| ISE | $I_{SE}$ | A | 0.0 | >=0 | B-E leakage saturation current |
| NE | $n_E$ | -- | 1.5 | >0 | B-E leakage emission coefficient |
| ISC | $I_{SC}$ | A | 0.0 | >=0 | B-C leakage saturation current |
| NC | $n_C$ | -- | 2.0 | >0 | B-C leakage emission coefficient |

### Early Effect and High-Injection
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VAF | $V_{AF}$ | V | 0.0 | >=0 | Forward Early voltage (0 = disabled) |
| VAR | $V_{AR}$ | V | 0.0 | >=0 | Reverse Early voltage (0 = disabled) |
| IKF | $I_{KF}$ | A | 0.0 | >=0 | Forward beta roll-off corner current (0 = disabled) |
| IKR | $I_{KR}$ | A | 0.0 | >=0 | Reverse beta roll-off corner current (0 = disabled) |
| NKF | $n_{KF}$ | -- | 0.5 | >0 | High-current beta roll-off exponent |

### Parasitic Resistances
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RB | $R_B$ | Ohm | 0.0 | >=0 | Zero-bias base resistance |
| RBM | $R_{BM}$ | Ohm | 0.0 | >=0 | Minimum base resistance (default = RB if 0) |
| IRB | $I_{RB}$ | A | 0.0 | >=0 | Current where $R_B$ midpoint = (RB+RBM)/2 |
| RE | $R_E$ | Ohm | 0.0 | >=0 | Emitter resistance |
| RC | $R_C$ | Ohm | 0.0 | >=0 | Collector resistance |

### Junction Capacitances -- Base-Emitter
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJE | $C_{JE}$ | F | 0.0 | >=0 | Zero-bias B-E depletion capacitance |
| VJE | $V_{JE}$ | V | 0.75 | >0 | B-E built-in potential |
| MJE | $m_{JE}$ | -- | 0.33 | 0..1 | B-E junction grading coefficient |

### Junction Capacitances -- Base-Collector
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJC | $C_{JC}$ | F | 0.0 | >=0 | Zero-bias B-C depletion capacitance |
| VJC | $V_{JC}$ | V | 0.75 | >0 | B-C built-in potential |
| MJC | $m_{JC}$ | -- | 0.33 | 0..1 | B-C junction grading coefficient |
| XCJC | $X_{CJC}$ | -- | 1.0 | 0..1 | Fraction of B-C cap connected to internal base |

### Junction Capacitances -- Substrate
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJS | $C_{JS}$ | F | 0.0 | >=0 | Zero-bias substrate junction capacitance |
| VJS | $V_{JS}$ | V | 0.75 | >0 | Substrate junction built-in potential |
| MJS | $m_{JS}$ | -- | 0.0 | >=0 | Substrate junction grading coefficient |

### Transit Times
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TF | $\tau_F$ | s | 0.0 | >=0 | Ideal forward transit time |
| XTF | $X_{TF}$ | -- | 0.0 | >=0 | Coefficient for bias dependence of TF |
| VTF | $V_{TF}$ | V | 0.0 | >=0 | Voltage giving VBC dependence of TF |
| ITF | $I_{TF}$ | A | 0.0 | >=0 | High-current parameter for TF |
| PTF | $\phi_{TF}$ | deg | 0.0 | -- | Excess phase at 1/(2*pi*TF) Hz |
| TR | $\tau_R$ | s | 0.0 | >=0 | Ideal reverse transit time |
| FC | $F_C$ | -- | 0.5 | 0..1 | Forward-bias depletion capacitance linearization coefficient |

### Substrate Diode
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ISS | $I_{SS}$ | A | 0.0 | >=0 | Substrate junction saturation current |
| NS | $n_S$ | -- | 1.0 | >0 | Substrate current emission coefficient |

### Epitaxial Region (Quasi-Saturation)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RCO | $R_{CO}$ | Ohm | 0.01 | >0 | Intrinsic collector resistance |
| VO | $V_O$ | V | 10.0 | >0 | Epi drift saturation voltage |
| GAMMA | $\gamma$ | -- | 1.0e-11 | >=0 | Epi doping parameter |
| QCO | $Q_{CO}$ | C | 0.0 | >=0 | Epi charge parameter |
| QUASIMOD | -- | -- | 0 | {0,1} | Quasi-saturation model selector |

### Temperature Dependence (Standard SPICE)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XTB | $X_{TB}$ | -- | 0.0 | -- | Forward and reverse beta temperature exponent |
| EG | $E_g$ | eV | 1.11 | >0 | Energy gap for IS temperature dependency |
| XTI | $X_{TI}$ | -- | 3.0 | -- | Temperature exponent for IS |
| VG | $V_g$ | eV | 1.206 | >0 | Energy gap for quasi-saturation temp dependency |
| CN | $c_n$ | -- | 2.42 | -- | Temperature exponent of RCI |
| D | $d$ | -- | 0.87 | -- | Temperature exponent of VO |

### Temperature Equation Selectors
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TLEV | -- | -- | 0 | {0,1,2} | Temperature equation level selector |
| TLEVC | -- | -- | 0 | {0,1,2} | Capacitance temperature equation selector |

### Temperature Coefficients -- Current Gains
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TBF1 | -- | 1/K | 0.0 | -- | BF 1st-order temperature coefficient |
| TBF2 | -- | 1/K^2 | 0.0 | -- | BF 2nd-order temperature coefficient |
| TBR1 | -- | 1/K | 0.0 | -- | BR 1st-order temperature coefficient |
| TBR2 | -- | 1/K^2 | 0.0 | -- | BR 2nd-order temperature coefficient |

### Temperature Coefficients -- Roll-Off Currents
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TIKF1 | -- | 1/K | 0.0 | -- | IKF 1st-order temperature coefficient |
| TIKF2 | -- | 1/K^2 | 0.0 | -- | IKF 2nd-order temperature coefficient |
| TIKR1 | -- | 1/K | 0.0 | -- | IKR 1st-order temperature coefficient |
| TIKR2 | -- | 1/K^2 | 0.0 | -- | IKR 2nd-order temperature coefficient |

### Temperature Coefficients -- Base Resistance
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TIRB1 | -- | 1/K | 0.0 | -- | IRB 1st-order temperature coefficient |
| TIRB2 | -- | 1/K^2 | 0.0 | -- | IRB 2nd-order temperature coefficient |
| TRB1 | -- | 1/K | 0.0 | -- | RB 1st-order temperature coefficient |
| TRB2 | -- | 1/K^2 | 0.0 | -- | RB 2nd-order temperature coefficient |
| TRM1 | -- | 1/K | 0.0 | -- | RBM 1st-order temperature coefficient |
| TRM2 | -- | 1/K^2 | 0.0 | -- | RBM 2nd-order temperature coefficient |

### Temperature Coefficients -- Emission Coefficients
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TNC1 | -- | 1/K | 0.0 | -- | NC 1st-order temperature coefficient |
| TNC2 | -- | 1/K^2 | 0.0 | -- | NC 2nd-order temperature coefficient |
| TNE1 | -- | 1/K | 0.0 | -- | NE 1st-order temperature coefficient |
| TNE2 | -- | 1/K^2 | 0.0 | -- | NE 2nd-order temperature coefficient |
| TNF1 | -- | 1/K | 0.0 | -- | NF 1st-order temperature coefficient |
| TNF2 | -- | 1/K^2 | 0.0 | -- | NF 2nd-order temperature coefficient |
| TNR1 | -- | 1/K | 0.0 | -- | NR 1st-order temperature coefficient |
| TNR2 | -- | 1/K^2 | 0.0 | -- | NR 2nd-order temperature coefficient |

### Temperature Coefficients -- Parasitic Resistances
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TRC1 | -- | 1/K | 0.0 | -- | RC 1st-order temperature coefficient |
| TRC2 | -- | 1/K^2 | 0.0 | -- | RC 2nd-order temperature coefficient |
| TRE1 | -- | 1/K | 0.0 | -- | RE 1st-order temperature coefficient |
| TRE2 | -- | 1/K^2 | 0.0 | -- | RE 2nd-order temperature coefficient |

### Temperature Coefficients -- Early Voltages
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TVAF1 | -- | 1/K | 0.0 | -- | VAF 1st-order temperature coefficient |
| TVAF2 | -- | 1/K^2 | 0.0 | -- | VAF 2nd-order temperature coefficient |
| TVAR1 | -- | 1/K | 0.0 | -- | VAR 1st-order temperature coefficient |
| TVAR2 | -- | 1/K^2 | 0.0 | -- | VAR 2nd-order temperature coefficient |

### Temperature Coefficients -- Junction Capacitances
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CTC | -- | 1/K | 0.0 | -- | CJC temperature coefficient |
| CTE | -- | 1/K | 0.0 | -- | CJE temperature coefficient |
| CTS | -- | 1/K | 0.0 | -- | CJS temperature coefficient |
| TVJC | -- | V/K | 0.0 | -- | VJC temperature coefficient |
| TVJE | -- | V/K | 0.0 | -- | VJE temperature coefficient |
| TVJS | -- | V/K | 0.0 | -- | VJS temperature coefficient |
| TMJE1 | -- | 1/K | 0.0 | -- | MJE 1st-order temperature coefficient |
| TMJE2 | -- | 1/K^2 | 0.0 | -- | MJE 2nd-order temperature coefficient |
| TMJC1 | -- | 1/K | 0.0 | -- | MJC 1st-order temperature coefficient |
| TMJC2 | -- | 1/K^2 | 0.0 | -- | MJC 2nd-order temperature coefficient |
| TMJS1 | -- | 1/K | 0.0 | -- | MJS 1st-order temperature coefficient |
| TMJS2 | -- | 1/K^2 | 0.0 | -- | MJS 2nd-order temperature coefficient |

### Temperature Coefficients -- Saturation Currents
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TIS1 | -- | 1/K | 0.0 | -- | IS 1st-order temperature coefficient |
| TIS2 | -- | 1/K^2 | 0.0 | -- | IS 2nd-order temperature coefficient |
| TISE1 | -- | 1/K | 0.0 | -- | ISE 1st-order temperature coefficient |
| TISE2 | -- | 1/K^2 | 0.0 | -- | ISE 2nd-order temperature coefficient |
| TISC1 | -- | 1/K | 0.0 | -- | ISC 1st-order temperature coefficient |
| TISC2 | -- | 1/K^2 | 0.0 | -- | ISC 2nd-order temperature coefficient |
| TISS1 | -- | 1/K | 0.0 | -- | ISS 1st-order temperature coefficient |
| TISS2 | -- | 1/K^2 | 0.0 | -- | ISS 2nd-order temperature coefficient |
| TNS1 | -- | 1/K | 0.0 | -- | NS 1st-order temperature coefficient |
| TNS2 | -- | 1/K^2 | 0.0 | -- | NS 2nd-order temperature coefficient |

### Temperature Coefficients -- Transit Times
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TITF1 | -- | 1/K | 0.0 | -- | ITF 1st-order temperature coefficient |
| TITF2 | -- | 1/K^2 | 0.0 | -- | ITF 2nd-order temperature coefficient |
| TTF1 | -- | 1/K | 0.0 | -- | TF 1st-order temperature coefficient |
| TTF2 | -- | 1/K^2 | 0.0 | -- | TF 2nd-order temperature coefficient |
| TTR1 | -- | 1/K | 0.0 | -- | TR 1st-order temperature coefficient |
| TTR2 | -- | 1/K^2 | 0.0 | -- | TR 2nd-order temperature coefficient |

### Noise
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KF | $K_F$ | -- | 0.0 | >=0 | Flicker noise coefficient |
| AF | $A_F$ | -- | 0.0 | >=0 | Flicker noise exponent |

### Absolute Maximum Ratings
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VBE_MAX | -- | V | inf | >0 | Maximum B-E junction voltage |
| VBC_MAX | -- | V | inf | >0 | Maximum B-C junction voltage |
| VCE_MAX | -- | V | inf | >0 | Maximum C-E branch voltage |
| PD_MAX | -- | W | inf | >0 | Maximum device power dissipation |
| IC_MAX | -- | A | inf | >0 | Maximum collector current |
| IB_MAX | -- | A | inf | >0 | Maximum base current |
| TE_MAX | -- | degC | inf | >0 | Maximum device temperature |
| RTH0 | $R_{TH0}$ | K/W | 0.0 | >=0 | Thermal resistance junction-to-ambient |

### Instance Parameters
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| AREA | -- | -- | 1.0 | >0 | Device area scaling factor |
| M | $M$ | -- | 1.0 | >0 | Parallel multiplier |
| TEMP | -- | degC | 0.0 | -- | Instance temperature (overrides circuit default) |
| DTEMP | -- | K | 0.0 | -- | Temperature offset from circuit temperature |

## Equations

### Thermal Voltage

$$V_t = k_B \cdot T_{dev}$$

where $k_B = 8.617333262145 \times 10^{-5}$ eV/K and $T_{dev}$ is device temperature in Kelvin:

$$T_{dev} = \begin{cases} \text{TEMP} + 273.15 & \text{if TEMP given} \\ \text{TNOM} + 273.15 + \text{DTEMP} & \text{otherwise} \end{cases}$$

### Junction Voltages (PNP Handling)

All internal voltages are in NPN convention. For PNP ($p = -1$):

$$V_{BE} = (V_{B'} - V_{E'}) \cdot p$$

$$V_{BC} = (V_{B'} - V_{C'}) \cdot p$$

where $p = +1$ for NPN, $p = -1$ for PNP.

### Forward and Reverse Diode Currents

$$C_{BE} = I_S \left( e^{\min(V_{BE} / n_F V_t,\; 80)} - 1 \right)$$

$$C_{BC} = I_S \left( e^{\min(V_{BC} / n_R V_t,\; 80)} - 1 \right)$$

Exponential overflow guard: argument clamped to 80.

### Base-Emitter Leakage Current

$$I_{BE,leak} = I_{SE} \left( e^{\min(V_{BE} / n_E V_t,\; 80)} - 1 \right)$$

### Base-Collector Leakage Current

$$I_{BC,leak} = I_{SC} \left( e^{\min(V_{BC} / n_C V_t,\; 80)} - 1 \right)$$

### Base Charge Factor (Early Effect + High Injection)

Early effect reciprocal base charge:

$$q_1 = \frac{1}{1 - \dfrac{V_{BC}}{V_{AF}} - \dfrac{V_{BE}}{V_{AR}}}$$

Terms with $V_{AF} = 0$ or $V_{AR} = 0$ are omitted (disabled).

High-injection base charge:

$$q_2 = \frac{C_{BE}}{I_{KF}} + \frac{C_{BC}}{I_{KR}}$$

Terms with $I_{KF} = 0$ or $I_{KR} = 0$ are omitted (disabled).

Normalized base charge:

$$q_b = q_1 \cdot \frac{1 + \text{sqarg}}{2}$$

where:

$$\text{sqarg} = \begin{cases} \sqrt{\max(0,\; 1 + 4 q_2)} & \text{if } n_{KF} = 0.5 \\ \left[\max(0,\; 1 + 4 q_2)\right]^{n_{KF}} & \text{otherwise} \end{cases}$$

### Transport Current

$$I_{CC} = \frac{C_{BE} - C_{BC}}{q_b}$$

### Ideal Base Currents

$$I_{BE,ideal} = \frac{C_{BE}}{\beta_F}$$

$$I_{BC,ideal} = \frac{C_{BC}}{\beta_R}$$

### Terminal Currents (Intrinsic)

Collector current:

$$I_C = I_{CC} - I_{BC,ideal} - I_{BC,leak}$$

Base current:

$$I_B = I_{BE,ideal} + I_{BE,leak} + I_{BC,ideal} + I_{BC,leak}$$

### GMIN Convergence Aid

$g_{min} = 10^{-12}$ S added to junction branches:

$$I_C' = I_C - g_{min} \cdot V_{BC}$$

$$I_B' = I_B + g_{min} \cdot V_{BE} + g_{min} \cdot V_{BC}$$

### Area and Multiplier Scaling

All intrinsic currents scaled by AREA $\times$ M:

$$I_{C,scaled} = I_C' \cdot \text{AREA} \cdot M$$

$$I_{B,scaled} = I_B' \cdot \text{AREA} \cdot M$$

### Parasitic Resistance Currents

Collector resistance ($G_{SHORT} = 10^{12}$ S used when R = 0):

$$I_{RC} = (V_C - V_{C'}) \cdot G_C, \quad G_C = \begin{cases} \dfrac{\text{AREA} \cdot M}{R_C} & R_C \neq 0 \\ G_{SHORT} & R_C = 0 \end{cases}$$

Emitter resistance:

$$I_{RE} = (V_E - V_{E'}) \cdot G_E, \quad G_E = \begin{cases} \dfrac{\text{AREA} \cdot M}{R_E} & R_E \neq 0 \\ G_{SHORT} & R_E = 0 \end{cases}$$

### Base Resistance (Three Modes)

**Case 1: $R_B = 0$ (no base resistance):**

$$I_{RB} = (V_B - V_{B'}) \cdot G_{SHORT}$$

**Case 2: Constant base resistance ($R_{BM} = 0$ or $R_{BM} = R_B$, IRB = 0):**

$$I_{RB} = (V_B - V_{B'}) \cdot \frac{\text{AREA} \cdot M}{R_B}$$

Note: when RBM is not given (0), it defaults to RB, making resistance constant.

**Case 3: $q_b$-dependent base resistance (IRB = 0, $R_{BM} \neq R_B$):**

$$R_{B,eff} = \frac{R_{BM}}{\text{AREA}} + \frac{R_B - R_{BM}}{\text{AREA} \cdot q_b}$$

$$I_{RB} = (V_B - V_{B'}) \cdot \frac{M}{R_{B,eff}}$$

**Case 4: Current-dependent base resistance (IRB $\neq$ 0):**

Rational approximation of the ngspice tan/atan formula:

$$R_{B,eff} = \frac{R_{BM}}{\text{AREA}} + \frac{R_B - R_{BM}}{\text{AREA} \cdot \left(1 + \sqrt{\dfrac{|I_B| \cdot \text{AREA} \cdot M}{I_{RB}} + 10^{-9}}\right)}$$

$$I_{RB} = (V_B - V_{B'}) \cdot \frac{M}{R_{B,eff}}$$

### Substrate Diode Current

Active when $I_{SS} \neq 0$:

$$V_{sub} = (V_S - V_{C'}) \cdot p$$

$$I_{sub} = I_{SS} \left( e^{\min(V_{sub} / n_S V_t,\; 80)} - 1 \right) \cdot \text{AREA} \cdot M$$

### KCL Node Stamps

External nodes (current flowing out of external terminal):

$$I[C] = -I_{RC}$$

$$I[B] = -I_{RB}$$

$$I[E] = -I_{RE}$$

Internal nodes:

$$I[C'] = I_{RC} + I_{C,scaled} \cdot p + I_{sub} \cdot p$$

$$I[B'] = I_{RB} - I_{B,scaled} \cdot p$$

$$I[E'] = I_{RE} - (I_{C,scaled} + I_{B,scaled}) \cdot p$$

$$I[S] = -I_{sub} \cdot p$$

---

## Charge Equations

### B-E Depletion Charge ($C_{JE} \neq 0$)

**Reverse bias and moderate forward bias** ($V_{BE} < F_C \cdot V_{JE}$):

$$Q_{BE,dep} = \frac{C_{JE} \cdot V_{JE}}{1 - m_{JE}} \left[ 1 - \left(\max\left(1 - \frac{V_{BE}}{V_{JE}},\; 10^{-30}\right)\right)^{1 - m_{JE}} \right]$$

**Strong forward bias** ($V_{BE} \geq F_C \cdot V_{JE}$):

Transition-point charge:

$$Q_{FC} = \frac{C_{JE} \cdot V_{JE}}{1 - m_{JE}} \left[ 1 - (1 - F_C)^{1 - m_{JE}} \right]$$

Linearization coefficients:

$$f_2 = (1 - F_C)^{1 + m_{JE}}$$

$$f_3 = 1 - F_C (1 + m_{JE})$$

Quadratic extension:

$$Q_{BE,fwd} = Q_{FC} + \frac{C_{JE}}{f_2} \left[ f_3 (V_{BE} - F_C V_{JE}) + \frac{m_{JE}}{2 V_{JE}} \left( V_{BE}^2 - (F_C V_{JE})^2 \right) \right]$$

Selection via smooth blend:

$$Q_{BE,dep} = \text{blendv}(V_{BE} - F_C V_{JE},\; Q_{dep},\; Q_{fwd})$$

### B-E Diffusion Charge (Forward Transit Time, $\tau_F \neq 0$)

$$Q_{BE,diff} = \tau_F \cdot I_S \left( e^{\min(V_{BE}/n_F V_t,\; 80)} - 1 \right)$$

### Total B-E Charge

$$Q_{BE} = (Q_{BE,dep} + Q_{BE,diff}) \cdot \text{AREA} \cdot M$$

### B-C Depletion Charge ($C_{JC} \neq 0$)

**Reverse bias and moderate forward bias** ($V_{BC} < F_C \cdot V_{JC}$):

$$Q_{BC,dep} = \frac{C_{JC} \cdot V_{JC}}{1 - m_{JC}} \left[ 1 - \left(\max\left(1 - \frac{V_{BC}}{V_{JC}},\; 10^{-30}\right)\right)^{1 - m_{JC}} \right]$$

**Strong forward bias** ($V_{BC} \geq F_C \cdot V_{JC}$):

$$Q_{FC} = \frac{C_{JC} \cdot V_{JC}}{1 - m_{JC}} \left[ 1 - (1 - F_C)^{1 - m_{JC}} \right]$$

$$f_2 = (1 - F_C)^{1 + m_{JC}}, \quad f_3 = 1 - F_C (1 + m_{JC})$$

$$Q_{BC,fwd} = Q_{FC} + \frac{C_{JC}}{f_2} \left[ f_3 (V_{BC} - F_C V_{JC}) + \frac{m_{JC}}{2 V_{JC}} \left( V_{BC}^2 - (F_C V_{JC})^2 \right) \right]$$

$$Q_{BC,dep} = \text{blendv}(V_{BC} - F_C V_{JC},\; Q_{dep},\; Q_{fwd})$$

### B-C Diffusion Charge (Reverse Transit Time, $\tau_R \neq 0$)

$$Q_{BC,diff} = \tau_R \cdot I_S \left( e^{\min(V_{BC}/n_R V_t,\; 80)} - 1 \right)$$

### Total B-C Charge

$$Q_{BC} = (Q_{BC,dep} + Q_{BC,diff}) \cdot \text{AREA} \cdot M$$

### Substrate Junction Charge ($C_{JS} \neq 0$)

**When $m_{JS} \neq 0$ (graded junction):**

Reverse/moderate forward ($V_{sub} < F_C \cdot V_{JS}$):

$$Q_{sub,dep} = \frac{C_{JS} \cdot V_{JS}}{1 - m_{JS}} \left[ 1 - \left(\max\left(1 - \frac{V_{sub}}{V_{JS}},\; 10^{-30}\right)\right)^{1 - m_{JS}} \right]$$

Strong forward ($V_{sub} \geq F_C \cdot V_{JS}$):

$$Q_{FC} = \frac{C_{JS} \cdot V_{JS}}{1 - m_{JS}} \left[ 1 - (1 - F_C)^{1 - m_{JS}} \right]$$

$$C_{FC} = \frac{C_{JS}}{(1 - F_C)^{m_{JS}}}$$

$$Q_{sub,fwd} = Q_{FC} + C_{FC} \cdot (V_{sub} - F_C V_{JS})$$

$$Q_{sub} = \text{blendv}(V_{sub} - F_C V_{JS},\; Q_{sub,dep},\; Q_{sub,fwd})$$

**When $m_{JS} = 0$ (linear capacitance):**

$$Q_{sub} = C_{JS} \cdot V_{sub}$$

Scaled: $Q_{sub} = Q_{sub} \cdot \text{AREA} \cdot M$

### Charge KCL Stamps

$$Q[B'] \mathrel{+}= Q_{BE} \cdot p + Q_{BC} \cdot p$$

$$Q[E'] \mathrel{-}= Q_{BE} \cdot p$$

$$Q[C'] \mathrel{-}= Q_{BC} \cdot p - Q_{sub} \cdot p$$

$$Q[S] \mathrel{-}= Q_{sub} \cdot p$$

The solver differentiates these charges w.r.t. time to obtain displacement currents ($I = dQ/dt$).

---

## Newton Limiting (Convergence)

### Critical Voltage

$$V_{crit} = V_t \cdot \ln\!\left(\frac{V_t}{\sqrt{2}\; I_S}\right)$$

### PN Junction Limiter (`pnLimit`)

Applied independently to $V_{BE}$ and $V_{BC}$ each Newton iteration. Given proposed $V_{new}$, previous $V_{old}$:

**If** $V_{new} > V_{crit}$ **and** $|V_{new} - V_{old}| > 2 V_t$:

$$V_{lim} = \begin{cases} V_{old} + V_t \ln(1 + (V_{new} - V_{old})/V_t) & \text{if } V_{old} > 0 \text{ and } 1 + (V_{new}-V_{old})/V_t > 2 \\ V_{crit} & \text{if } V_{old} > 0 \text{ and } 1 + (V_{new}-V_{old})/V_t \leq 2 \\ V_t \ln(V_{new}/V_t) & \text{if } V_{old} \leq 0 \text{ and } V_{new}/V_t > 0 \\ V_{crit} & \text{if } V_{old} \leq 0 \text{ and } V_{new}/V_t \leq 0 \end{cases}$$

**Else:** $V_{lim} = V_{new}$ (no limiting).

The limiter is applied sequentially: first $V_{BE}$ is limited (adjusting $V_{B'}$), then $V_{BC}$ is limited using the already-adjusted $V_{B'}$.

---

## Source Stepping (Convergence Aid)

At continuation factor $\lambda \in [0, 1]$:

$$I_S' = I_S + g_{min} \cdot (1 - \lambda)$$

At $\lambda = 0$ (start), saturation current is increased by $g_{min} = 10^{-12}$ to ease convergence. At $\lambda = 1$ (final), original parameters are recovered.

---

## Noise Sources

Six noise generators between the indicated node pairs:

| Source | Nodes | Type | Spectral Density |
|--------|-------|------|-----------------|
| RC thermal | C -- C' | Thermal | $S_I = 4 k_B T \cdot G_C$ |
| RB thermal | B -- B' | Thermal | $S_I = 4 k_B T \cdot G_B$ |
| RE thermal | E -- E' | Thermal | $S_I = 4 k_B T \cdot G_E$ |
| IC shot | C' -- E' | Shot | $S_I = 2 q |I_C|$ |
| IB shot | B' -- E' | Shot | $S_I = 2 q |I_B|$ |
| 1/f | B' -- E' | Flicker | $S_I = K_F \cdot |I_B|^{A_F} / f$ |

where $k_B$ is Boltzmann's constant, $q$ is electron charge, and $f$ is frequency.
