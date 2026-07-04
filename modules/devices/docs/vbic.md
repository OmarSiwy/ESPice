# VBIC 1.3 (4T Electrothermal) -- Parameter & Equation Reference

> Vertical Bipolar Inter-Company BJT model with 4 terminals, electrothermal self-heating, excess phase, and quasi-saturation epi-layer modeling.

## Model Topology

External terminals: **C** (collector), **B** (base), **E** (emitter), **S** (substrate), plus optional **dt** (thermal node for self-heating). Internal nodes: **cx** (extrinsic collector), **ci** (intrinsic collector), **bx** (extrinsic base), **bi** (intrinsic base), **bp** (parasitic base), **ei** (intrinsic emitter), **si** (intrinsic substrate). The equivalent circuit contains an intrinsic NPN/PNP transistor (bi-ci-ei) with transport current $I_{tzf} - I_{tzr}$, a parasitic PNP substrate transistor (bx-bp-si), series resistances on all terminals (RCX, RCI with quasi-saturation, RBX, RBI modulated by base charge, RE, RS, RBP modulated by parasitic base charge), depletion and diffusion capacitances on all junctions, overlap capacitances, avalanche multiplication, B-E breakdown, and an optional thermal network (RTH/CTH). Excess phase is modeled via a two-node Bessel filter approximation with delay time TD.

## Parameters

### Transport Current
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IS | $I_S$ | A | 1.0e-16 | (0, $\infty$) | Transport saturation current |
| NF | $N_F$ | -- | 1.0 | (0, $\infty$) | Forward emission coefficient |
| NR | $N_R$ | -- | 1.0 | (0, $\infty$) | Reverse emission coefficient |
| ISRR | $ISRR$ | -- | 1.0 | (0, $\infty$) | Ratio of IS(reverse) to IS(forward) |
| FC | $F_C$ | -- | 0.9 | [0, 1) | Forward bias depletion capacitance limit |
| QBM | $QBM$ | -- | 0 | -- | Base charge model: 0=VBIC (GP), 1=SGP |
| NKF | $N_{KF}$ | -- | 0.5 | (0, $\infty$) | High-current beta rolloff exponent |

### Early Voltage & Knee Currents
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VEF | $V_{EF}$ | V | 0.0 | [0, $\infty$) | Forward Early voltage (0=infinite) |
| VER | $V_{ER}$ | V | 0.0 | [0, $\infty$) | Reverse Early voltage (0=infinite) |
| IKF | $I_{KF}$ | A | 0.0 | [0, $\infty$) | Forward knee current (0=infinite) |
| IKR | $I_{KR}$ | A | 0.0 | [0, $\infty$) | Reverse knee current (0=infinite) |
| IKP | $I_{KP}$ | A | 0.0 | [0, $\infty$) | Parasitic knee current (0=infinite) |

### Base-Emitter Junction
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IBEI | $I_{BEI}$ | A | 1.0e-18 | (0, $\infty$) | Ideal B-E saturation current |
| NEI | $N_{EI}$ | -- | 1.0 | (0, $\infty$) | Ideal B-E emission coefficient |
| IBEN | $I_{BEN}$ | A | 0.0 | [0, $\infty$) | Non-ideal B-E saturation current |
| NEN | $N_{EN}$ | -- | 2.0 | (0, $\infty$) | Non-ideal B-E emission coefficient |
| WBE | $W_{BE}$ | -- | 1.0 | [0, 1] | Partition of IBEI between Vbei (WBE) and Vbex (1-WBE) |

### Base-Collector Junction
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IBCI | $I_{BCI}$ | A | 1.0e-16 | (0, $\infty$) | Ideal B-C saturation current |
| NCI | $N_{CI}$ | -- | 1.0 | (0, $\infty$) | Ideal B-C emission coefficient |
| IBCN | $I_{BCN}$ | A | 0.0 | [0, $\infty$) | Non-ideal B-C saturation current |
| NCN | $N_{CN}$ | -- | 2.0 | (0, $\infty$) | Non-ideal B-C emission coefficient |

### Avalanche Multiplication
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| AVC1 | $A_{VC1}$ | 1/V | 0.0 | [0, $\infty$) | B-C weak avalanche parameter 1 |
| AVC2 | $A_{VC2}$ | -- | 0.0 | [0, $\infty$) | B-C weak avalanche parameter 2 |

### B-E Breakdown
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VBBE | $V_{BBE}$ | V | 0.0 | -- | B-E breakdown voltage |
| NBBE | $N_{BBE}$ | -- | 1.0 | (0, $\infty$) | B-E breakdown emission coefficient |
| IBBE | $I_{BBE}$ | A | 1.0e-6 | -- | B-E breakdown current |
| TVBBE1 | $T_{VBBE1}$ | 1/K | 0.0 | -- | Linear temperature coefficient of VBBE |
| TVBBE2 | $T_{VBBE2}$ | 1/K$^2$ | 0.0 | -- | Quadratic temperature coefficient of VBBE |
| TNBBE | $T_{NBBE}$ | 1/K | 0.0 | -- | Temperature coefficient of NBBE |
| EBBE | $E_{BBE}$ | -- | 0.0 | -- | $\exp(-V_{BBE}/(N_{BBE} \cdot V_t))$ at nominal temp |

### Parasitic Transistor (Substrate PNP)
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ISP | $I_{SP}$ | A | 0.0 | [0, $\infty$) | Parasitic transport saturation current |
| WSP | $W_{SP}$ | -- | 1.0 | [0, 1] | Partition of parasitic collector current |
| NFP | $N_{FP}$ | -- | 1.0 | (0, $\infty$) | Parasitic forward emission coefficient |
| IBEIP | $I_{BEIP}$ | A | 0.0 | [0, $\infty$) | Ideal parasitic B-E saturation current |
| IBENP | $I_{BENP}$ | A | 0.0 | [0, $\infty$) | Non-ideal parasitic B-E saturation current |
| IBCIP | $I_{BCIP}$ | A | 0.0 | [0, $\infty$) | Ideal parasitic B-C saturation current |
| NCIP | $N_{CIP}$ | -- | 1.0 | (0, $\infty$) | Ideal parasitic B-C emission coefficient |
| IBCNP | $I_{BCNP}$ | A | 0.0 | [0, $\infty$) | Non-ideal parasitic B-C saturation current |
| NCNP | $N_{CNP}$ | -- | 2.0 | (0, $\infty$) | Non-ideal parasitic B-C emission coefficient |

### Resistances
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RCX | $R_{CX}$ | $\Omega$ | 0.0 | [0, $\infty$) | Extrinsic collector resistance |
| RCI | $R_{CI}$ | $\Omega$ | 0.0 | [0, $\infty$) | Intrinsic collector resistance |
| VO | $V_O$ | V | 0.0 | [0, $\infty$) | Epi drift saturation voltage |
| GAMM | $\Gamma$ | -- | 0.0 | [0, $\infty$) | Epi doping parameter |
| HRCF | $HRCF$ | -- | 0.0 | [0, $\infty$) | High-current collector resistance factor |
| RBX | $R_{BX}$ | $\Omega$ | 0.0 | [0, $\infty$) | Extrinsic base resistance |
| RBI | $R_{BI}$ | $\Omega$ | 0.0 | [0, $\infty$) | Intrinsic base resistance |
| RE | $R_E$ | $\Omega$ | 0.0 | [0, $\infty$) | Emitter resistance |
| RS | $R_S$ | $\Omega$ | 0.0 | [0, $\infty$) | Substrate resistance |
| RBP | $R_{BP}$ | $\Omega$ | 0.0 | [0, $\infty$) | Parasitic base resistance |

### B-E Depletion Capacitance
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJE | $C_{JE}$ | F | 0.0 | [0, $\infty$) | Zero-bias B-E depletion capacitance |
| PE | $P_E$ | V | 0.75 | (0, $\infty$) | B-E built-in potential |
| ME | $M_E$ | -- | 0.33 | (0, 1) | B-E grading coefficient |
| AJE | $A_{JE}$ | -- | -0.5 | -- | B-E capacitance smoothing factor |
| CBEO | $C_{BEO}$ | F | 0.0 | [0, $\infty$) | Extrinsic B-E overlap capacitance |

### B-C Depletion Capacitance
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJC | $C_{JC}$ | F | 0.0 | [0, $\infty$) | Zero-bias B-C depletion capacitance |
| PC | $P_C$ | V | 0.75 | (0, $\infty$) | B-C built-in potential |
| MC | $M_C$ | -- | 0.33 | (0, 1) | B-C grading coefficient |
| AJC | $A_{JC}$ | -- | -0.5 | -- | B-C capacitance smoothing factor |
| CBCO | $C_{BCO}$ | F | 0.0 | [0, $\infty$) | Extrinsic B-C overlap capacitance |
| QCO | $Q_{CO}$ | C | 0.0 | [0, $\infty$) | Epi charge parameter |
| CJEP | $C_{JEP}$ | F | 0.0 | [0, $\infty$) | Zero-bias extrinsic B-C (parasitic B-E) capacitance |
| VRT | $V_{RT}$ | V | 0.0 | [0, $\infty$) | Punch-through voltage for B-C reach-through |
| ART | $A_{RT}$ | -- | 0.1 | (0, $\infty$) | Smoothing parameter for reach-through |

### Substrate Capacitance
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJCP | $C_{JCP}$ | F | 0.0 | [0, $\infty$) | Zero-bias substrate-collector capacitance |
| PS | $P_S$ | V | 0.75 | (0, $\infty$) | S-C built-in potential |
| MS | $M_S$ | -- | 0.33 | (0, 1) | S-C grading coefficient |
| AJS | $A_{JS}$ | -- | -0.5 | -- | S-C capacitance smoothing factor |
| CCSO | $C_{CSO}$ | F | 0.0 | [0, $\infty$) | Fixed collector-substrate overlap capacitance |

### Transit Time
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TF | $\tau_F$ | s | 0.0 | [0, $\infty$) | Ideal forward transit time |
| QTF | $Q_{TF}$ | -- | 0.0 | [0, $\infty$) | Variation of TF with base-width modulation |
| XTF | $X_{TF}$ | -- | 0.0 | [0, $\infty$) | Coefficient for bias dependence of TF |
| VTF | $V_{TF}$ | V | 0.0 | [0, $\infty$) | Voltage giving VBC dependence of TF |
| ITF | $I_{TF}$ | A | 0.0 | [0, $\infty$) | High-current parameter for TF |
| TR | $\tau_R$ | s | 0.0 | [0, $\infty$) | Ideal reverse transit time |
| TD | $\tau_D$ | s | 0.0 | [0, $\infty$) | Forward excess-phase delay time |

### Noise
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KFN | $K_{FN}$ | -- | 0.0 | [0, $\infty$) | B-E flicker noise coefficient |
| AFN | $A_{FN}$ | -- | 1.0 | (0, $\infty$) | B-E flicker noise current exponent |
| BFN | $B_{FN}$ | -- | 1.0 | (0, $\infty$) | B-E flicker noise 1/f exponent |

### Self-Heating
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RTH | $R_{TH}$ | K/W | 0.0 | [0, $\infty$) | Thermal resistance |
| CTH | $C_{TH}$ | J/K | 0.0 | [0, $\infty$) | Thermal capacitance |

### Temperature Dependence -- Resistance Exponents
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XRE | $X_{RE}$ | -- | 0.0 | -- | Temperature exponent of RE |
| XRBI | $X_{RBI}$ | -- | 0.0 | -- | Temperature exponent of RBI |
| XRCI | $X_{RCI}$ | -- | 0.0 | -- | Temperature exponent of RCI |
| XRS | $X_{RS}$ | -- | 0.0 | -- | Temperature exponent of RS |
| XVO | $X_{VO}$ | -- | 0.0 | -- | Temperature exponent of VO |
| XRCX | $X_{RCX}$ | -- | 0.0 | -- | Temperature exponent of RCX |
| XRBX | $X_{RBX}$ | -- | 0.0 | -- | Temperature exponent of RBX |
| XRBP | $X_{RBP}$ | -- | 0.0 | -- | Temperature exponent of RBP |
| XIKF | $X_{IKF}$ | -- | 0.0 | -- | Temperature exponent of IKF |

### Temperature Dependence -- Activation Energies
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| EA | $E_A$ | V | 1.12 | -- | Activation energy for IS |
| EAIE | $E_{AIE}$ | V | 1.12 | -- | Activation energy for IBEI |
| EAIC | $E_{AIC}$ | V | 1.12 | -- | Activation energy for IBCI/IBEIP |
| EAIS | $E_{AIS}$ | V | 1.12 | -- | Activation energy for IBCIP |
| EANE | $E_{ANE}$ | V | 1.12 | -- | Activation energy for IBEN |
| EANC | $E_{ANC}$ | V | 1.12 | -- | Activation energy for IBCN/IBENP |
| EANS | $E_{ANS}$ | V | 1.12 | -- | Activation energy for IBCNP |
| EAP | $E_{AP}$ | V | 1.12 | -- | Activation energy for ISP |
| DEAR | $\Delta E_{AR}$ | V | 0.0 | -- | Delta activation energy for ISRR |

### Temperature Dependence -- Current Exponents
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XIS | $X_{IS}$ | -- | 3.0 | -- | Temperature exponent of IS |
| XII | $X_{II}$ | -- | 3.0 | -- | Temperature exponent of IBEI, IBCI, IBEIP, IBCIP |
| XIN | $X_{IN}$ | -- | 3.0 | -- | Temperature exponent of IBEN, IBCN, IBENP, IBCNP |
| XISR | $X_{ISR}$ | -- | 0.0 | -- | Temperature exponent of ISRR |
| TNF | $T_{NF}$ | 1/K | 0.0 | -- | Temperature coefficient of NF (and NR) |
| TAVC | $T_{AVC}$ | 1/K | 0.0 | -- | Temperature coefficient of AVC2 |

### Reference & Miscellaneous
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TNOM | $T_{NOM}$ | degC | 27.0 | -- | Nominal parameter extraction temperature |
| DTEMP | $\Delta T$ | K | 0.0 | -- | Local temperature offset from circuit temperature |
| VERS | -- | -- | 1.2 | -- | Model revision version |
| VREV | -- | -- | 0.0 | -- | Model reference version |

### Parameter Aliases
| Alias | Maps To |
|-------|---------|
| TREF | TNOM |
| V0 | VO |
| GAMMA | GAMM |
| CBE0 | CBEO |
| CBC0 | CBCO |
| CCS0 | CCSO |
| QC0 | QCO |
| XV0 | XVO |
| DTMP | DTEMP |
| VERSION | VERS |

## Equations

### Temperature Mapping

$$T_{ini} = 273.15 + T_{NOM}$$
Nominal temperature in Kelvin.

$$T_{dev} = T_{circuit} + \Delta T + V_{rth}$$
Device temperature including self-heating ($V_{rth}$ is the thermal node voltage).

$$V_{tv} = \frac{k_B \cdot T_{dev}}{q}$$
Thermal voltage at device temperature.

$$r_T = \frac{T_{dev}}{T_{ini}}, \qquad \Delta T = T_{dev} - T_{ini}$$
Temperature ratio and delta.

### Temperature-Scaled Parameters

$$IKF_T = IKF \cdot r_T^{X_{IKF}}$$

$$RCX_T = RCX \cdot r_T^{X_{RCX}}, \quad RCI_T = RCI \cdot r_T^{X_{RCI}}, \quad RBX_T = RBX \cdot r_T^{X_{RBX}}$$

$$RBI_T = RBI \cdot r_T^{X_{RBI}}, \quad RE_T = RE \cdot r_T^{X_{RE}}, \quad RS_T = RS \cdot r_T^{X_{RS}}$$

$$RBP_T = RBP \cdot r_T^{X_{RBP}}, \quad VO_T = VO \cdot r_T^{X_{VO}}$$

$$IS_T = IS \cdot \left( r_T^{X_{IS}} \cdot \exp\!\left(\frac{-E_A(1 - r_T)}{V_{tv}}\right) \right)^{1/N_F}$$

$$ISRR_T = ISRR \cdot \left( r_T^{X_{ISR}} \cdot \exp\!\left(\frac{-\Delta E_{AR}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_R}$$

$$ISP_T = ISP \cdot \left( r_T^{X_{IS}} \cdot \exp\!\left(\frac{-E_{AP}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{FP}}$$

$$IBEI_T = IBEI \cdot \left( r_T^{X_{II}} \cdot \exp\!\left(\frac{-E_{AIE}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{EI}}$$

$$IBEN_T = IBEN \cdot \left( r_T^{X_{IN}} \cdot \exp\!\left(\frac{-E_{ANE}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{EN}}$$

$$IBCI_T = IBCI \cdot \left( r_T^{X_{II}} \cdot \exp\!\left(\frac{-E_{AIC}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{CI}}$$

$$IBCN_T = IBCN \cdot \left( r_T^{X_{IN}} \cdot \exp\!\left(\frac{-E_{ANC}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{CN}}$$

$$IBEIP_T = IBEIP \cdot \left( r_T^{X_{II}} \cdot \exp\!\left(\frac{-E_{AIC}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{CI}}$$

$$IBENP_T = IBENP \cdot \left( r_T^{X_{IN}} \cdot \exp\!\left(\frac{-E_{ANC}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{CN}}$$

$$IBCIP_T = IBCIP \cdot \left( r_T^{X_{II}} \cdot \exp\!\left(\frac{-E_{AIS}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{CIP}}$$

$$IBCNP_T = IBCNP \cdot \left( r_T^{X_{IN}} \cdot \exp\!\left(\frac{-E_{ANS}(1 - r_T)}{V_{tv}}\right) \right)^{1/N_{CNP}}$$

$$NF_T = NF \cdot (1 + \Delta T \cdot T_{NF}), \qquad NR_T = NR \cdot (1 + \Delta T \cdot T_{NF})$$

$$AVC2_T = AVC2 \cdot (1 + \Delta T \cdot T_{AVC})$$

$$VBBE_T = VBBE \cdot (1 + \Delta T \cdot (T_{VBBE1} + \Delta T \cdot T_{VBBE2}))$$

$$NBBE_T = NBBE \cdot (1 + \Delta T \cdot T_{NBBE})$$

$$EBBE_T = \exp\!\left(\frac{-VBBE_T}{NBBE_T \cdot V_{tv}}\right)$$

$$\Gamma_T = \Gamma \cdot r_T^{X_{IS}} \cdot \exp\!\left(\frac{-E_A(1 - r_T)}{V_{tv}}\right)$$

### Temperature-Scaled Built-In Potentials

For each junction $J \in \{E, C, S\}$ with built-in potential $P_J$ and activation energy $EA_J$:

$$\psi_{io} = \frac{2 V_{tv}}{r_T} \ln\!\left(\exp\!\left(\frac{P_J \cdot r_T}{2 V_{tv}}\right) - \exp\!\left(\frac{-P_J \cdot r_T}{2 V_{tv}}\right)\right)$$

$$\psi_{in} = \psi_{io} \cdot r_T - 3 V_{tv} \ln(r_T) - EA_J (r_T - 1)$$

$$P_{J,T} = \psi_{in} + 2 V_{tv} \ln\!\left(\frac{1 + \sqrt{1 + 4\exp(-\psi_{in}/V_{tv})}}{2}\right)$$

### Temperature-Scaled Capacitances

$$CJE_T = CJE \cdot \left(\frac{P_E}{PE_T}\right)^{M_E}$$

$$CJC_T = CJC \cdot \left(\frac{P_C}{PC_T}\right)^{M_C}$$

$$CJEP_T = CJEP \cdot \left(\frac{P_C}{PC_T}\right)^{M_C}$$

$$CJCP_T = CJCP \cdot \left(\frac{P_S}{PS_T}\right)^{M_S}$$

### Reciprocal Helpers (Computed Once)

$$IVEF = \begin{cases} 1/VEF & VEF > 0 \\ 0 & \text{otherwise} \end{cases}, \qquad IVER = \begin{cases} 1/VER & VER > 0 \\ 0 & \text{otherwise} \end{cases}$$

$$IIKF = \begin{cases} 1/IKF_T & IKF > 0 \\ 0 & \text{otherwise} \end{cases}, \qquad IIKR = \begin{cases} 1/IKR & IKR > 0 \\ 0 & \text{otherwise} \end{cases}$$

$$IIKP = \begin{cases} 1/IKP & IKP > 0 \\ 0 & \text{otherwise} \end{cases}, \qquad IVO = \begin{cases} 1/VO_T & VO > 0 \\ 0 & \text{otherwise} \end{cases}$$

$$IHRCF = \begin{cases} 1/HRCF & HRCF > 0 \\ 0 & \text{otherwise} \end{cases}$$

$$IVTF = \begin{cases} 1/VTF & VTF > 0 \\ 0 & \text{otherwise} \end{cases}, \qquad IITF = \begin{cases} 1/ITF & ITF > 0 \\ 0 & \text{otherwise} \end{cases}$$

$$slTF = \begin{cases} 0 & ITF > 0 \\ 1 & \text{otherwise} \end{cases}$$

### Branch Voltages

$$V_{bei} = V(bi) - V(ei), \quad V_{bex} = V(bx) - V(ei), \quad V_{bci} = V(bi) - V(ci)$$

$$V_{bcx} = V(bi) - V(cx), \quad V_{bep} = V(bx) - V(bp), \quad V_{bcp} = V(si) - V(bp)$$

$$V_{rcx} = V(c) - V(cx), \quad V_{rci} = V(cx) - V(ci), \quad V_{rbx} = V(b) - V(bx)$$

$$V_{rbi} = V(bx) - V(bi), \quad V_{re} = V(e) - V(ei), \quad V_{rbp} = V(bp) - V(cx), \quad V_{rs} = V(s) - V(si)$$

### Forward and Reverse Transport Currents

$$I_{fi} = IS_T \cdot \left(\exp\!\left(\frac{V_{bei}}{NF_T \cdot V_{tv}}\right) - 1\right)$$
Forward diffusion current.

$$I_{ri} = IS_T \cdot ISRR_T \cdot \left(\exp\!\left(\frac{V_{bci}}{NR_T \cdot V_{tv}}\right) - 1\right)$$
Reverse diffusion current.

### Depletion Charge (Generic Junction)

For a junction with voltage $V$, built-in potential $P$, grading $M$, forward limit $FC$, and smoothing factor $AJ$:

**Case AJ $\leq$ 0 (standard SPICE piecewise):**

If $V < -FC \cdot P$:
$$q_{lo} = \frac{P}{1-M}\left(1 - \left(1 - \frac{V}{P}\right)^{1-M}\right), \quad q_{hi} = 0$$

If $V \geq -FC \cdot P$:
$$p_{wq} = (1 - FC)^{-1-M}$$
$$q_{lo} = \frac{P\left(1 - p_{wq}(1-FC)^2\right)}{1-M}$$
$$q_{hi} = (V + FC \cdot P)\left(1 - FC + \frac{M(V + FC \cdot P)}{2P}\right) p_{wq}$$

$$q_d = q_{lo} + q_{hi}$$

With reach-through ($VRT > 0$ and $V < -VRT$):
$$q_{lo} = \frac{P}{1-M}\left(1 - \left(1 + \frac{VRT}{P}\right)^{1-M}\left(1 - \frac{(1-M)(V + VRT)}{P + VRT}\right)\right)$$

**Case AJ $>$ 0 (smoothed model):**

$$dv_0 = -P \cdot FC$$
$$mv_0 = \sqrt{dv_0^2 + 4 \cdot AJ^2}, \qquad vl_0 = -\frac{1}{2}(dv_0 + mv_0)$$
$$q_0 = \frac{-P}{1-M}\left(1 - \frac{vl_0}{P}\right)^{1-M}$$
$$dv = V + dv_0, \qquad mv = \sqrt{dv^2 + 4 \cdot AJ^2}$$
$$vl = \frac{1}{2}(dv - mv) - dv_0$$
$$q_{lo} = \frac{-P}{1-M}\left(1 - \frac{vl}{P}\right)^{1-M}$$
$$q_d = q_{lo} + (1 - FC)^{-M}(V - vl + vl_0) - q_0$$

**Case AJ $>$ 0 with reach-through ($VRT > 0$, $ART > 0$):**

$$vn_0 = \frac{VRT + dv_0}{VRT - dv_0}$$
$$vnl_0 = \frac{2 vn_0}{\sqrt{(vn_0-1)^2 + 4 AJ^2} + \sqrt{(vn_0+1)^2 + 4 ART^2}}$$
$$vl_0 = \frac{1}{2}(vnl_0(VRT - dv_0) - VRT - dv_0)$$
$$qlo_0 = \frac{P}{1-M}\left(1 - \left(1 - \frac{vl_0}{P}\right)^{1-M}\right)$$
$$vn = \frac{2V + VRT + dv_0}{VRT - dv_0}$$
$$vnl = \frac{2 vn}{\sqrt{(vn-1)^2 + 4 AJ^2} + \sqrt{(vn+1)^2 + 4 ART^2}}$$
$$vl = \frac{1}{2}(vnl(VRT - dv_0) - VRT - dv_0)$$
$$q_{lo} = \frac{P}{1-M}\left(1 - \left(1 - \frac{vl}{P}\right)^{1-M}\right)$$
$$sel = \frac{1}{2}(vnl + 1)$$
$$c_{rt} = \left(1 + \frac{VRT}{P}\right)^{-M}, \qquad c_{mx} = \left(1 + \frac{dv_0}{P}\right)^{-M}$$
$$cl = (1 - sel) \cdot c_{rt} + sel \cdot c_{mx}$$
$$q_d = (V - vl + vl_0) \cdot cl + q_{lo} - qlo_0$$

### Specific Junction Charges

$$qdbe = q_d(V_{bei},\; PE_T,\; ME,\; FC,\; AJE)$$
$$qdbex = q_d(V_{bex},\; PE_T,\; ME,\; FC,\; AJE)$$
$$qdbc = q_d(V_{bci},\; PC_T,\; MC,\; FC,\; AJC)$$
$$qdbep = q_d(V_{bep},\; PC_T,\; MC,\; FC,\; AJC)$$
$$qdbcp = q_d(V_{bcp},\; PS_T,\; MS,\; FC,\; AJS)$$

### Base Charge (Early Effect + High Injection)

$$q_{1z} = 1 + qdbe \cdot IVER + qdbc \cdot IVEF$$
Normalized base charge from Early effect (depletion charge formulation).

$$q_1 = \frac{1}{2}\left(\sqrt{(q_{1z} - 10^{-4})^2 + 10^{-8}} + q_{1z} - 10^{-4}\right) + 10^{-4}$$
Smoothed clamp of $q_{1z}$ to prevent negative values.

$$q_2 = I_{fi} \cdot IIKF + I_{ri} \cdot IIKR$$
High-injection component.

**VBIC formulation (QBM < 0.5):**
$$q_b = \frac{1}{2}\left(q_1 + \left(q_1^{1/N_{KF}} + 4 q_2\right)^{N_{KF}}\right)$$

**SGP formulation (QBM $\geq$ 0.5):**
$$q_b = \frac{1}{2} q_1 \left(1 + \left(1 + 4 q_2\right)^{N_{KF}}\right)$$

### Normalized Transport Currents

$$I_{tzf} = \frac{I_{fi}}{q_b}, \qquad I_{tzr} = \frac{I_{ri}}{q_b}$$

### Base-Emitter Current

$$I_{be} = W_{BE} \left[ IBEI_T \left(\exp\!\left(\frac{V_{bei}}{N_{EI} V_{tv}}\right) - 1\right) + IBEN_T \left(\exp\!\left(\frac{V_{bei}}{N_{EN} V_{tv}}\right) - 1\right) \right]$$

With B-E breakdown ($VBBE > 0$):
$$I_{be} = W_{BE} \left[ IBEI_T (e^{V_{bei}/(N_{EI} V_{tv})} - 1) + IBEN_T (e^{V_{bei}/(N_{EN} V_{tv})} - 1) - IBBE \left(e^{(-VBBE_T - V_{bei})/(NBBE_T \cdot V_{tv})} - EBBE_T\right) \right]$$

### Extrinsic Base-Emitter Current

$$I_{bex} = (1 - W_{BE}) \left[ IBEI_T \left(\exp\!\left(\frac{V_{bex}}{N_{EI} V_{tv}}\right) - 1\right) + IBEN_T \left(\exp\!\left(\frac{V_{bex}}{N_{EN} V_{tv}}\right) - 1\right) \right]$$

With B-E breakdown ($VBBE > 0$), same structure with $V_{bex}$ replacing $V_{bei}$.

### Base-Collector Junction Current

$$I_{bcj} = IBCI_T \left(\exp\!\left(\frac{V_{bci}}{N_{CI} V_{tv}}\right) - 1\right) + IBCN_T \left(\exp\!\left(\frac{V_{bci}}{N_{CN} V_{tv}}\right) - 1\right)$$

### Avalanche Current

If $AVC1 > 0$:

$$vl = \frac{1}{2}\left(\sqrt{(PC_T - V_{bci})^2 + 0.01} + (PC_T - V_{bci})\right)$$
Smoothed positive part of $(PC - V_{bci})$.

$$\alpha_{av} = AVC1 \cdot vl \cdot \exp\!\left(-AVC2_T \cdot vl^{M_C - 1}\right)$$

$$I_{gc} = (I_{tzf} - I_{tzr} - I_{bcj}) \cdot \alpha_{av}$$

$$I_{bc} = I_{bcj} - I_{gc}$$

### Parasitic B-E Current

$$I_{bep} = IBEIP_T \left(\exp\!\left(\frac{V_{bep}}{N_{CI} V_{tv}}\right) - 1\right) + IBENP_T \left(\exp\!\left(\frac{V_{bep}}{N_{CN} V_{tv}}\right) - 1\right)$$
Uses B-C emission coefficients $N_{CI}$, $N_{CN}$.

### Parasitic Transport Current

If $ISP > 0$:

$$I_{fp} = ISP_T \left(W_{SP} \cdot \exp\!\left(\frac{V_{bep}}{N_{FP} V_{tv}}\right) + (1 - W_{SP}) \cdot \exp\!\left(\frac{V_{bci}}{N_{FP} V_{tv}}\right) - 1\right)$$

$$I_{rp} = ISP_T \left(\exp\!\left(\frac{V_{bcp}}{N_{FP} V_{tv}}\right) - 1\right)$$

$$q_{2p} = I_{fp} \cdot IIKP$$

$$q_{bp} = \frac{1}{2}\left(1 + \sqrt{1 + 4 q_{2p}}\right)$$

$$I_{ccp} = \frac{I_{fp} - I_{rp}}{q_{bp}}$$

### Parasitic B-C Current (Substrate)

$$I_{bcp} = IBCIP_T \left(\exp\!\left(\frac{V_{bcp}}{N_{CIP} V_{tv}}\right) - 1\right) + IBCNP_T \left(\exp\!\left(\frac{V_{bcp}}{N_{CNP} V_{tv}}\right) - 1\right)$$

### Resistor Currents

$$I_{rcx} = \frac{V_{rcx}}{RCX_T}$$
Extrinsic collector resistance.

$$I_{rbx} = \frac{V_{rbx}}{RBX_T}$$
Extrinsic base resistance.

$$I_{rbi} = \frac{V_{rbi} \cdot q_b}{RBI_T}$$
Intrinsic base resistance, modulated by normalized base charge $q_b$.

$$I_{re} = \frac{V_{re}}{RE_T}$$
Emitter resistance.

$$I_{rbp} = \frac{V_{rbp} \cdot q_{bp}}{RBP_T}$$
Parasitic base resistance, modulated by parasitic base charge $q_{bp}$.

$$I_{rs} = \frac{V_{rs}}{RS_T}$$
Substrate resistance.

### Intrinsic Collector Resistance (Quasi-Saturation Epi Model)

$$K_{bci} = \sqrt{1 + \Gamma_T \cdot \exp(V_{bci}/V_{tv})}$$

$$K_{bcx} = \sqrt{1 + \Gamma_T \cdot \exp(V_{bcx}/V_{tv})}$$

$$rKp1 = \frac{K_{bci} + 1}{K_{bcx} + 1}$$

$$I_{ohm} = \frac{V_{rci} + V_{tv}(K_{bci} - K_{bcx} - \ln(rKp1))}{RCI_T}$$
Ohmic component including epi-layer modulation.

$$derf = \frac{IVO \cdot RCI_T \cdot I_{ohm}}{1 + 0.5 \cdot IVO \cdot IHRCF \cdot \sqrt{V_{rci}^2 + 0.01}}$$
Velocity saturation factor.

$$I_{rci} = \frac{I_{ohm}}{\sqrt{1 + derf^2}}$$

### Forward Transit Time (Bias-Dependent)

$$sg_{If} = \begin{cases} 1 & I_{fi} > 0 \\ 0 & \text{otherwise} \end{cases}$$

$$r_{If} = I_{fi} \cdot sg_{If} \cdot IITF$$

$$m_{If} = \frac{r_{If}}{r_{If} + 1}$$

$$\tau_{ff} = TF \cdot (1 + QTF \cdot q_1) \cdot \left(1 + XTF \cdot \exp\!\left(\frac{V_{bci} \cdot IVTF}{1.44}\right) \cdot (slTF + m_{If}^2) \cdot sg_{If}\right)$$

### Stored Charges

$$Q_{be} = CJE_T \cdot qdbe \cdot W_{BE} + \tau_{ff} \cdot \frac{I_{fi}}{q_b}$$
B-E depletion + diffusion charge.

$$Q_{bex} = CJE_T \cdot qdbex \cdot (1 - W_{BE})$$
Extrinsic B-E depletion charge.

$$Q_{bc} = CJC_T \cdot qdbc + \tau_R \cdot I_{ri} + QCO \cdot K_{bci}$$
B-C depletion + diffusion + epi charge.

$$Q_{bcx} = QCO \cdot K_{bcx}$$
Extrinsic B-C epi charge.

$$Q_{bep} = CJEP_T \cdot qdbep + \tau_R \cdot I_{fp}$$
Parasitic B-E depletion + diffusion charge.

$$Q_{bcp} = CJCP_T \cdot qdbcp + CCSO \cdot V_{bcp}$$
Substrate depletion + overlap charge.

$$Q_{beo} = CBEO \cdot V_{be}$$
External B-E overlap charge.

$$Q_{bco} = CBCO \cdot V_{bc}$$
External B-C overlap charge.

### Excess Phase (Bessel Filter Approximation)

Two internal nodes $xf1$, $xf2$ approximate the phase delay $\tau_D$:

$$I_{xf1} = V_{xf2} - I_{tzf}$$

$$I_{xf2} = V_{xf2} - V_{xf1}$$

$$Q_{xf1} = \tau_D \cdot V_{xf1}$$

$$Q_{xf2} = \frac{\tau_D}{3} \cdot V_{xf2}$$

The output transport current with excess phase is $I_{txf} = V_{xf1}$ (replaces $I_{tzf}$ in branch contributions).

### Thermal Network (Self-Heating)

$$P_{diss} = I_{be} V_{bei} + I_{bc} V_{bci} + (I_{txf} - I_{tzr}) V_{cei} + I_{bex} V_{bex} + I_{bep} V_{bep}$$
$$\quad + I_{rcx} V_{rcx} + I_{rci} V_{rci} + I_{rbx} V_{rbx} + I_{rbi} V_{rbi} + I_{re} V_{re} + I_{rbp} V_{rbp} + I_{bcp} V_{bcp} + I_{ccp} V_{cep} + I_{rs} V_{rs}$$
Total instantaneous power dissipation.

$$I_{th} = -P_{diss}$$
Thermal current source (heat generation).

$$I_{rth} = \frac{V_{rth}}{RTH}$$
Thermal resistance current (heat flow to ambient).

$$Q_{cth} = CTH \cdot V_{rth}$$
Thermal capacitance charge (thermal inertia).

### Noise Sources

**Shot noise (white):**

$$S_{I,bei} = 2q|I_{be}|, \qquad S_{I,bex} = 2q|I_{bex}|$$

$$S_{I,cei} = 2q|I_{tzf}|, \qquad S_{I,bep} = 2q|I_{bep}|$$

**Thermal noise (white):**

$$S_{I,rcx} = \frac{4 k_B T}{RCX_T}$$

$$S_{I,rci} = 4 k_B T \cdot \frac{|I_{rci}| + 10^{-10}/RCI_T}{|V_{rci}| + 10^{-10}}$$
Nonlinear RCI thermal noise uses instantaneous conductance.

$$S_{I,rbx} = \frac{4 k_B T}{RBX_T}, \qquad S_{I,rbi} = \frac{4 k_B T \cdot q_b}{RBI_T}$$

$$S_{I,re} = \frac{4 k_B T}{RE_T}, \qquad S_{I,rbp} = \frac{4 k_B T \cdot q_{bp}}{RBP_T}$$

**Flicker noise:**

$$S_{I,bei}^{1/f} = KFN \cdot \frac{|I_{be}|^{AFN}}{f^{BFN}}$$

$$S_{I,bex}^{1/f} = KFN \cdot \frac{|I_{bex}|^{AFN}}{f^{BFN}}$$

$$S_{I,bep}^{1/f} = KFN \cdot \frac{|I_{bep}|^{AFN}}{f^{BFN}}$$

### KCL Node Stamping

| Node | Current Contributions |
|------|-----------------------|
| c | $-I_{rcx}$ |
| b | $-I_{rbx}$ |
| e | $-I_{re}$ |
| s | $-I_{rs}$ |
| cx | $+I_{rcx} - I_{rci} + I_{rbp}$ |
| ci | $+I_{rci} - I_{cei} + I_{bc}$ |
| bx | $+I_{rbx} - I_{rbi} - I_{bex} - I_{bep} - I_{ccp}$ |
| bi | $+I_{rbi} - I_{be} - I_{bc}$ |
| bp | $+I_{bep} - I_{rbp} + I_{bcp}$ |
| ei | $+I_{re} + I_{be} + I_{bex} + I_{cei}$ |
| si | $+I_{rs} - I_{bcp} + I_{ccp}$ |

Where $I_{cei} = I_{txf} - I_{tzr}$ (or $I_{tzf} - I_{tzr}$ without excess phase).

### Charge Stamping (dQ/dt Contributions)

| Branch | Charge |
|--------|--------|
| bi $\to$ ei | $Q_{be}$ |
| bx $\to$ ei | $Q_{bex}$ |
| bi $\to$ ci | $Q_{bc}$ |
| bi $\to$ cx | $Q_{bcx}$ |
| bx $\to$ bp | $Q_{bep}$ |
| si $\to$ bp | $Q_{bcp}$ |
| b $\to$ e | $Q_{beo}$ |
| b $\to$ c | $Q_{bco}$ |
| dt (thermal) | $Q_{cth}$ |
| xf1 (excess phase) | $Q_{xf1}$ |
| xf2 (excess phase) | $Q_{xf2}$ |
