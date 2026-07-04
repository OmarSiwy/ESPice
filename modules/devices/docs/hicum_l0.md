# HICUM/L0 2.1.0 -- Parameter & Equation Reference

> BJT compact model (simplified)

## Model Topology

HICUM/L0 is a simplified version of HICUM/L2 for bipolar (including heterojunction) transistors. The equivalent circuit has four external terminals: Base (B), Collector (C), Emitter (E), and Substrate (S), plus an internal thermal node (T). Internal nodes B', C', E', and S' are separated from external terminals by series resistances RBx (external base), RCx (external collector), and RE (emitter). The core intrinsic transistor between B', C', E' includes depletion charges (QjE, QjCi, QjS), minority charges (Qf, Qr), transfer current iT, base currents (ijBE, ijBC), avalanche current iAVL, parasitic capacitances (CBEpar, CBCpar), and an external BC depletion charge QBCx. Adjunct networks model self-heating (Rth, Cth driven by power P) and vertical NQS effects via single-pole RC low-pass filters for both minority charge and transfer current.

## Parameters

### Collector Current

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| is | $I_S$ | A | 1e-16 | [0, 1] | (Modified) saturation current. M-scaled. |
| mcf | $m_{Cf}$ | -- | 1.0 | (0, 10] | Non-ideality coefficient of forward collector current |
| mcr | $m_{Cr}$ | -- | 1.0 | (0, 10] | Non-ideality coefficient of reverse collector current |
| vef | $V_{Ef}$ | V | inf | (0, inf] | Forward Early voltage (normalization voltage) |
| ver | $V_{Er}$ | V | inf | (0, inf] | Reverse Early voltage (normalization voltage) |
| aver | $a_{VEr}$ | -- | 0 | [0, 100] | Parameter for bias dependence of VEr |
| rver | $r_{VEr}$ | -- | 2.0 | (0, 10] | Smoothing parameter for ver(VBE) at high voltage |
| iqf | $I_{Qf}$ | A | inf | (0, inf] | Forward DC high-injection roll-off current. M-scaled. |
| fiqf | $f_{iqf}$ | -- | 0 | [0, 1] | Flag for turning on voltage dependence of iqf |
| iqr | $I_{Qr}$ | A | inf | (0, inf] | Inverse DC high-injection roll-off current. M-scaled. |
| iqfh | $I_{Qfh}$ | A | inf | (0, inf] | High-injection correction current. M-scaled. |
| tfh | $t_{fh}$ | s | 0 | [0, inf) | High-injection correction factor |
| ahq | $a_{hq}$ | -- | 0 | [-0.9, 10] | Smoothing factor for the DC injection width |
| flteft | -- | -- | 0 | {0, 1} | Flag for including (1) or not (0) emitter charge T dependence |
| flitm | -- | -- | 0 | {0, 1} | Switch: 0 = L0v1.2 second-order eq; 1 = Cardano third-order eq |

### Base Current

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ibes | $I_{BES}$ | A | 1e-18 | [0, 1] | BE saturation current. M-scaled. |
| mbe | $m_{BE}$ | -- | 1 | (0, 10] | BE non-ideality factor |
| ires | $I_{RES}$ | A | 0 | [0, 1] | BE recombination saturation current. M-scaled. |
| mre | $m_{RE}$ | -- | 2 | (0, 10] | BE recombination non-ideality factor |
| ibcs | $I_{BCS}$ | A | 1e-16 | [0, 1] | BC saturation current. M-scaled. |
| mbc | $m_{BC}$ | -- | 1 | (0, 10] | BC non-ideality factor |

### BE Depletion Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cje0 | $C_{jE0}$ | F | 1e-20 | (0, inf) | Zero-bias BE depletion capacitance. V-scaled. |
| vde | $V_{DE}$ | V | 0.9 | (0, 10] | BE built-in voltage |
| ze | $z_E$ | -- | 0.5 | (0, 1) | BE exponent factor |
| aje | $a_{jE}$ | -- | 2.5 | [1, inf) | Ratio of maximum to zero-bias value |

### Transit Time

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| t0 | $\tau_0$ | s | 0 | [0, inf) | Low current transit time at VB'C'=0 |
| dt0h | $\Delta\tau_{0h}$ | s | 0 | (-inf, inf) | Base width modulation contribution |
| tbvl | $\tau_{Bfvl}$ | s | 0 | [0, inf) | SCR width modulation contribution |
| tef0 | $\tau_{Ef0}$ | s | 0 | [0, inf) | Storage time in neutral emitter |
| gte | $g_E$ | -- | 1.0 | (0, 10] | Exponent factor for emitter transit time |
| thcs | $\tau_{hcs}$ | s | 0 | [0, inf) | Saturation time at high current densities |
| ahc | $a_{hc}$ | -- | 0.1 | (0, 10] | Smoothing factor for current dependence |
| tr | $\tau_r$ | s | 0 | [0, inf) | Storage time at inverse operation |

### Critical Current

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rci0 | $r_{Ci0}^*$ | Ohm | 150 | (0, inf) | Low-field epi collector resistance under emitter. 1/M-scaled. |
| vlim | $V_{lim}$ | V | 0.5 | (0, 10] | Voltage dividing ohmic and saturation region |
| vpt | $V_{PT}$ | V | inf | (0, 100] | Punch-through voltage |
| vces | $V_{C'E's}$ | V | 0.1 | [0, 1] | CE saturation voltage |
| vdck | $V_{DCk}$ | V | 0.0 | [0, 1] | Reference voltage for calculating critical current as f(VB'C') |
| delck | $\delta_{ck}$ | -- | 2.0 | (0, 10] | Fitting factor for voltage dependence of critical current |
| aick | $a_{ick}$ | -- | 1e-3 | (0, 10] | Smoothing factor for ICK |

### Internal BC Depletion Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cjci0 | $C_{jCi0}$ | F | 1e-20 | (0, inf) | Internal zero-bias BC depletion capacitance. M-scaled. |
| vdci | $V_{DCi}$ | V | 0.7 | (0, 10] | Internal BC built-in voltage |
| zci | $z_{Ci}$ | -- | 0.333 | (0, 1] | Internal BC exponent factor |
| vptci | $V_{PTCi}$ | V | 100 | (0, 100] | Punch-through voltage of internal BC junction |

### External BC Depletion Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cjcx0 | $C_{jCx0}$ | F | 1e-20 | [0, inf) | External zero-bias BC depletion capacitance. M-scaled. |
| vdcx | $V_{DCx}$ | V | 0.7 | (0, 10] | External BC built-in voltage |
| zcx | $z_{Cx}$ | -- | 0.333 | (0, 1] | External BC exponent factor |
| vptcx | $V_{PTCx}$ | V | inf | (0, 100] | External BC punch-through voltage |
| fbc | $f_{BC}$ | -- | 1 | [0, 1] | Factor for splitting CjCi0 (if CjCx0 not specified) or CjCx0 (if both specified) |

### Base Resistance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rbi0 | $r_{Bi0}$ | Ohm | 0 | [0, inf) | Internal base resistance at zero-bias. 1/M-scaled. |
| vr0e | $V_{r0E}$ | V | 2.5 | (0, inf] | Reverse Early voltage (normalization voltage for rBi) |
| vr0c | $V_{r0C}$ | V | inf | (0, inf] | Forward Early voltage (normalization voltage for rBi) |
| fgeo | $f_{geo}^*$ | -- | 0.656 | [0, inf] | Geometry factor for emitter current crowding |

### Series Resistances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rbx | $r_{Bx}$ | Ohm | 0 | [0, inf) | External base series resistance |
| rcx | $r_{Cx}$ | Ohm | 0 | [0, inf) | External collector series resistance |
| re | $r_E$ | Ohm | 0 | [0, inf) | Emitter series resistance |

### Substrate Transfer Current, Diode Current and Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| itss | $I_{TSS}$ | A | 0 | [0, 1] | Substrate transistor transfer saturation current |
| msf | $m_{Sf}$ | -- | 1.0 | (0, 10] | Substrate transistor transfer current non-ideality factor |
| iscs | $I_{SCS}$ | A | 0 | [0, 1] | SC saturation current. M-scaled. |
| msc | $m_{SC}$ | -- | 1 | (0, 10] | SC non-ideality factor |
| cjs0 | $C_{jS0}$ | F | 1e-20 | [0, inf) | Zero-bias SC depletion capacitance. M-scaled. |
| vds | $V_{DS}$ | V | 0.3 | (0, 10] | SC built-in voltage |
| zs | $z_S$ | -- | 0.3 | (0, 1] | SC exponent factor |
| vpts | $V_{PTS}$ | V | inf | (0, 100] | SC punch-through voltage |

### Parasitic Capacitances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cbcpar | $C_{BCpar}$ | F | 0 | [0, inf) | Collector-base isolation (overlap) capacitance. M-scaled. |
| cbepar | $C_{BEpar}$ | F | 0 | [0, inf) | Emitter-base oxide capacitance. M-scaled. |

### BC Avalanche Current

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| favl | $f_{AVL}$ | 1/V | 0 | [0, inf) | Avalanche prefactor |
| qavl | $q_{AVL}$ | C | 0 | [0, inf) | Avalanche exponent factor |

### Flicker Noise

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| kf | $K_F$ | -- | 0 | [0, inf) | Flicker noise coefficient. Scaled by $M^{1-A_F}$. |
| af | $A_F$ | -- | 2 | (0, 10] | Flicker noise exponent factor |

### Temperature Dependence

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vgb | $V_{gb}$ | V | 1.2 | (0, 10] | Bandgap voltage (averaged over base region) |
| vge | $V_{ge}$ | V | 1.17 | (0, 10] | Effective emitter bandgap voltage |
| vgc | $V_{gc}$ | V | 1.17 | (0, 10] | Effective collector bandgap voltage |
| vgs | $V_{gs}$ | V | 1.17 | (0, 10] | Effective substrate bandgap voltage |
| dvgbe | $\Delta V_{gBE}$ | -- | 0 | -- | Bandgap difference between base and BE-junction (for T dependence of VEr and IQf) |
| f1vg | $K_1$ | V/K | -1.02377e-4 | -- | Coefficient K1 in T-dependent bandgap equation |
| alt0 | $\alpha_{t0}$ | 1/K | 0 | [-10, 10] | First-order TC of tf0 |
| kt0 | $k_{t0}$ | 1/K^2 | 0 | [-10, 10] | Second-order TC of tf0 |
| zetavgbe | $\zeta_{VgBE}$ | -- | 1 | -- | Temperature parameter for VEr |
| zetaver | $\zeta_{VEr}$ | -- | -1 | -- | Temperature parameter for VEr |
| zetact | $\zeta_{CT}$ | -- | 3 | [-10, 10] | Exponent coefficient in transfer current temperature dependence |
| zetabet | $\zeta_{BET}$ | -- | 3.5 | [-10, 10] | Exponent coefficient in BE junction current temperature dependence |
| zetaiqf | $\zeta_{IQf}$ | -- | 0 | [-10, 10] | Temperature coefficient for IQf |
| zetaci | $\zeta_{Ci}$ | -- | 0 | [-10, 10] | TC of epi-collector diffusivity |
| zetaiqfh | $\zeta_{IQfh}$ | -- | 0 | -- | Temperature dependence of IQfh |
| alvs | $\alpha_{vs}$ | 1/K | 0 | [-10, 10] | Relative TC of saturation drift velocity |
| alces | $\alpha_{CEs}$ | 1/K | 0 | [-10, 10] | Relative TC of vces |
| aldck | $\alpha_{DCk}$ | 1/K | 0 | -- | Relative TC of vdck |
| zetarbi | $\zeta_{RBI}$ | -- | 0 | [-10, 10] | TC of internal base resistance |
| zetarbx | $\zeta_{RBX}$ | -- | 0 | [-10, 10] | TC of external base resistance |
| zetarcx | $\zeta_{RCX}$ | -- | 0 | [-10, 10] | TC of external collector resistance |
| zetare | $\zeta_{RE}$ | -- | 0 | [-10, 10] | TC of emitter resistance |
| alrth | $\alpha_{Rth}$ | 1/K | 0 | [-10, 10] | First-order relative temperature coefficient of Rth |
| zetarth | $\zeta_{Rth}$ | -- | 0 | [-10, 10] | Exponent factor for temperature dependent thermal resistance |
| alfav | $\alpha_{fav}$ | 1/K | 0 | [-10, 10] | Relative TC for fAVL |
| alqav | $\alpha_{qav}$ | 1/K | 0 | [-10, 10] | Relative TC for qAVL |

### Vertical NQS Effect

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| flnqs | -- | -- | 0 | {0, 1} | Flag for turning on/off vertical NQS effects |
| alit | $\alpha_{iT}$ | -- | 0.333 | (0, 1] | Factor for additional delay time of transfer current |
| alqf | $\alpha_{Qf}$ | -- | 0.167 | (0, 1] | Factor for additional delay time of minority charge |

### Self-Heating

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| flsh | -- | -- | 0 | {0, 1} | Flag for turning on (1) or off (0) self-heating effect |
| rth | $R_{th}$ | K/W | 0 | [0, inf) | Thermal resistance. 1/M-scaled. |
| cth | $C_{th}$ | Ws/K | 0 | [0, inf) | Thermal capacitance. M-scaled. |

### Backwards Compatibility

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| flcomp | -- | -- | 210 | -- | Flag for obtaining backwards compatible results |

### Circuit Simulator Specific Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tnom | $T_{nom}$ | degC | 27 | -- | Temperature for which parameters are valid |
| dt | $\Delta T$ | K | 0 | -- | Temperature change for particular transistor |
| type | -- | -- | +1 | {+1, -1} | Transistor type: NPN (+1) or PNP (-1) |

## Equations

### 2.2 Depletion Charges and Capacitances

#### 2.2.1 Base-Emitter Junction

**Merged BE depletion capacitance** (2-1):

$$
C_{jE} = C_{jEi} + C_{jEp}
$$

**Auxiliary junction voltage** (hyperbolic smoothing) (2-2):

$$
v_j = V_f - V_T \frac{x + \sqrt{x^2 + a_{fj}}}{2} \le V_f
$$

**Argument for smoothing** (2-3):

$$
x = \frac{V_f - v_{BE}}{V_T}
$$

**Forward intercept voltage** (2-4):

$$
V_f = V_{DEi} \left(1 - a_{jEi}^{-1/z_{Ei}}\right)
$$

**Smoothing constant** (2-5):

$$
a_{fj} = 1.921812
$$

Fixed constant, not a model parameter.

**Total BE depletion capacitance** (2-6):

$$
C_{jE} = \frac{C_{jE0}}{(1 - v_j / V_{DE})^{z_E}} \frac{dv_j}{dv_{BE}} + a_{jE} C_{jE0} \left(1 - \frac{dv_j}{dv_{BE}}\right)
$$

**Derivative of auxiliary voltage** (2-7):

$$
\frac{dv_j}{dv_{BE}} = \frac{x + \sqrt{x^2 + a_{fj}}}{2\sqrt{x^2 + a_{fj}}}
$$

**BE depletion charge** (2-8):

$$
Q_{jE} = \frac{C_{jE0} V_{DE}}{1 - z_E} \left[1 - \left(1 - \frac{v_j}{V_{DE}}\right)^{1-z_E}\right] + a_{jE} C_{jE0} (v_{B'E'} - v_j)
$$

**Zero-bias capacitance from L2** (2-9):

$$
C_{jE0} = C_{jEi0} + C_{jEp0}
$$

**Merged ajE** (2-10):

$$
a_{jE} = \frac{a_{jEi} C_{jEi0} + a_{jEp} C_{jEp0}}{C_{jE0}}
$$

#### 2.2.2 Base-Collector Junction

BC depletion capacitance is partitioned across the base resistance. The internal portion $C_{jCi}$ keeps its separate parameter set. The external depletion capacitance $C_{jCx0} = C'_{jCx0} + C''_{jCx0}$ is split across $r_{Bx}$ according to the partitioning factor $f_{BC}$.

Implementation logic:

```
IF (CjCx0 == 0)
    C_jCi0 = CjCi0 * fBC
    C_jCx02 = 0
    C_jCx01 = CjCi0 * (1 - fBC)
ELSE
    C_jCi0 = CjCi0
    C_jCx02 = CjCx0 * fBC
    C_jCx01 = CjCx0 * (1 - fBC)
END
```

The same depletion charge/capacitance formulation as for CjE (eqs. 2-2 through 2-8) is used for CjCi and CjCx with their respective parameter sets (VDCi, zCi, VPTCi, etc.).

#### 2.2.3 Collector-Substrate Junction

CjS uses the same formulation as CjC (eqs. 2-2 through 2-8) with parameters CjS0, VDS, zS, VPTS.

### 2.3 Minority Charges and Capacitances

**Forward transit time decomposition** (2-11):

$$
\tau_f(v_{C'E'}, i_{Tf}) = \tau_{f0}(v_{B'C'}) + \Delta\tau_f(v_{C'E'}, i_{Tf})
$$

**Total forward mobile charge** (2-12):

$$
Q_f = Q_{f0} + Q_{Ef} + Q_{fh}
$$

#### Low Current Densities

**Low-current transit time** (2-13):

$$
\tau_{f0}(v_{B'C'}) = \tau_0 + \Delta\tau_{0h}(c - 1) + \tau_{Bfvl}\left(\frac{1}{c} - 1\right)
$$

where $c \equiv C_{jCi0}/C_{jCi}$.

**Low-current forward minority charge** (2-14):

$$
Q_{f0} = \tau_{f0} \cdot i_{Tf}
$$

#### Medium and High Current Densities

**Total transit time increase** (2-15):

$$
\Delta\tau_f(v_{C'E'}, i_{Tf}) = \tau_{Ef} + \tau_{fh}
$$

**High-current collector charge/transit time** (2-16):

$$
\tau_{fh} = \tau_{hcs} \cdot w^2 \left(1 + \frac{2 I_{CK}}{i_{Tf} \sqrt{i^2 + a_{hc}}}\right)
$$

**Normalized injection width** (2-17):

$$
w(i_{Tf}) = \frac{w_i}{w_C} = \frac{i + \sqrt{i^2 + a_{hc}}}{1 + \sqrt{1 + a_{hc}}}
$$

**Bias dependent variable** (2-18):

$$
i = 1 - \frac{I_{CK}}{I_{Tf}}
$$

**Critical current** (2-19):

$$
I_{CK} = \frac{v_{ceff}}{r_{Ci0}^* \left(1 + \left(\frac{v_{ceff}}{V_{lim}}\right)^{\delta_{ck}}\right)^{1/\delta_{ck}}} \left(1 + \frac{x + \sqrt{x^2 + a_{ick}}}{2}\right)
$$

where $x = (v_{ceff} - V_{lim})/V_{PT}$, $a_{ick} = 10^{-3}$.

**Effective CE voltage** (clamped to positive) (2-20):

$$
v_{ceff} = V_T \left(1 + \frac{u + \sqrt{u^2 + 1.921812}}{2}\right), \quad u = \frac{v_c - V_T}{V_T}
$$

**Collector voltage options** (2-21):

$$
v_c = v_{C'E'} - V_{C'E's} \quad \text{or} \quad v_c = V_{DCk} - v_{B'C'}
$$

The second option is selected when $V_{DCk} > 0$.

**High-current collector charge** (2-22):

$$
Q_{fh} = \tau_{hcs} \cdot i_{Tf} \cdot w^2
$$

**Emitter transit time component** (2-23):

$$
\tau_{Ef} = \tau_{Ef0} \left(\frac{i_{Tf}}{I_{CK}}\right)^{g_E}
$$

**Emitter charge component** (2-24):

$$
Q_{Ef} = \tau_{Ef} \cdot \frac{i_{Tf}}{1 + g_E}
$$

**Reverse minority charge** (2-25):

$$
Q_r = Q_{r0} = \tau_r \cdot i_{Tr}
$$

### 2.4 Transfer Current

**Transfer current** (2-26):

$$
i_T = \frac{i_{Tfi} - i_{Tri}}{q_{pT}}
$$

**Ideal current components** (2-27):

$$
i_{Tfi} = I_S \exp\left(\frac{v_{BE}}{m_{Cf} V_T}\right), \qquad i_{Tri} = I_S \exp\left(\frac{v_{BC}}{m_{Cr} V_T}\right)
$$

**Normalized hole charge** (2-28):

$$
q_{pT} = q_j + q_{fl} + q_{fT}
$$

**Simplified normalized depletion charge** (2-29):

$$
q_j = 1 + \frac{v_{jEi}}{V_{Er}} + \frac{v_{jCi}}{V_{Ef}}
$$

**BE charge component** (2-30):

$$
v_{jEi} = Q_{jE} / C_{jE0}
$$

**BC charge component** (2-31):

$$
v_{jCi} = Q_{jCi} / C_{jCi0}
$$

**Normalized low-injection mobile charge** (2-32):

$$
q_{fl} = \frac{i_{Tf}}{I_{Qf}(v_{BC})} + \frac{i_{Tr}}{I_{Qr}}
$$

**Forward and reverse transfer current components** (2-33):

$$
i_{Tf} = \frac{i_{Tfi}}{q_{pT}}, \qquad i_{Tr} = \frac{i_{Tri}}{q_{pT}}
$$

**Voltage-dependent IQf** (2-34):

$$
I_{Qf}(v_{BC}) = \frac{I_{Qf}}{1 + f_{iqf}\left(\frac{\tau_{f0}(v_{BC})}{\tau_0} - 1\right)}
$$

**High-injection normalized forward mobile charge** (2-35):

$$
q_{fT} = w(i_{Tf})^2 \frac{i_{Tf}}{I_{Qfh}} + t_{fh} \frac{i_{Tf}}{I_{CK}} \cdot \frac{i_{Tf}}{I_{Qfh}}
$$

**Normalized charge components for Cardano approach** (2-36):

$$
q_{BCfi} = \frac{w(q_{pT})^2}{I_{Qfh}} \cdot i_{Tfi}
$$

(2-37):

$$
q_{Efi} = t_{fh} \frac{i_{Tfi}^2}{I_{CK} \cdot I_{Qfh}}
$$

**qfT as function of qpT** (2-38):

$$
q_{fT} = \frac{q_{BCfi}}{q_{pT}} + \frac{q_{Efi}}{q_{pT}^2}
$$

**qfli definition** (2-39):

$$
q_{fli} = \frac{i_{Tfi}}{I_{Qf}(v_{BC})} + \frac{i_{Tri}}{I_{Qr}}
$$

**Full normalized charge equation** (2-40):

$$
q_{pT} = q_j + \frac{q_{fli}}{q_{pT}} + \frac{q_{BCfi}}{q_{pT}} + \frac{q_{Efi}}{q_{pT}^2}
$$

**Third-order equation (Cardano)** (2-41):

$$
q_{pT}^3 - q_j q_{pT}^2 - q_{fli} q_{pT} - q_{BCfi} q_{pT} - q_{pT} q_{Efi} = 0
$$

Solved explicitly via Cardano's method (see Appendix).

#### Simplified (Quadratic) Approach

**Approximated emitter charge** (2-42):

$$
q_{fTE} = t_{fh} \left(\frac{i_{Tfi}^2}{I_{CK} I_{Qfh}}\right)^{2/3} \frac{1}{q_{pT}}
$$

**Modified qEfi** (2-43):

$$
q_{Efi} = t_{fh} \left(\frac{i_{Tfi}^2}{I_{CK} I_{Qfh}}\right)^{2/3}
$$

**Quadratic equation** (with $w=1$) (2-44):

$$
q_{pT}^2 - q_j q_{pT} - \left(q_{fli} + q_{BCfi}(w=1) + q_{Efi}\right) = 0
$$

**Quadratic solution** (2-45):

$$
q_{pT} = \frac{q_j}{2} + \sqrt{\left(\frac{q_j}{2}\right)^2 + q_{fli} + q_{BCfi}(w=1) + q_{Efi}}
$$

In HICUM/L0, $q_{pT}$ is calculated three times: first with $w=0$, then with $w=1$ to get the collector-related minority charge, and finally the actual $w$ is computed to solve for the transfer current.

### 2.4.1 Heterojunction Effects (Low/Medium Current)

**Bias-dependent reverse Early voltage** (2-46):

$$
V_{Er} = V_{Er0} \cdot \frac{\exp(u) - 1}{u}
$$

**Argument u** (2-47):

$$
u = a_{VEr} \left[1 - \left(1 - \frac{v_{ju}}{V_{DE}}\right)^{z_E}\right]
$$

**Smoothed junction voltage for VEr** (2-48):

$$
v_{ju} = V_{DE} - r_{VEr} V_T \frac{x_u + \sqrt{x_u^2 + a_{fi}}}{2}, \quad x_u = \frac{V_{DE} - v_{B'E'}}{r_{VEr} V_T}
$$

with smoothing constant $a_{fi} = 1.921812$.

**Bernoulli function implementation** (2-49):

$$
B(u) = \begin{cases}
\dfrac{\exp(u) - 1}{u} & \text{for } |u| \ge u_{min} \\[6pt]
1 + \dfrac{u}{2} & \text{for } |u| < u_{min}
\end{cases}
$$

where $u_{min} = 0.001$.

### 2.5 Static Base Current Components

#### 2.5.1 BE Junction Current

**BE diode current** (unnumbered, sec 2.5.1):

$$
i_{jBE} = I_{BES}\left[\exp\left(\frac{v_{B'E'}}{m_{BE} V_T}\right) - 1\right] + I_{RES}\left[\exp\left(\frac{v_{B'E'}}{m_{RE} V_T}\right) - 1\right]
$$

**Saturation current mapping from L2** (2-50):

$$
I_{BES} = I_{BEiS} + I_{BEpS}, \qquad I_{RES} = I_{REiS} + I_{REpS}
$$

**Constant current gain relation** (2-51):

$$
I_{BES} = I_{CS} / B_f, \qquad m_{BE} = m_{Cf}
$$

#### 2.5.2 BC Junction Current

**BC diode current** (unnumbered, sec 2.5.2):

$$
i_{jBC} = I_{jBCS}\left[\exp\left(\frac{v_{B'C'}}{m_{BC} V_T}\right) - 1\right]
$$

#### 2.5.3 Avalanche Current

**Weak avalanche current** (unnumbered, sec 2.5.3):

$$
i_{AVL} = i_{Tf} \frac{f_{AVL}}{C_c^{1/z_{Ci}}} \cdot V_{DCi} \cdot \exp\left(-\frac{q_{AVL}}{C_{jCi0} V_{DCi}} \cdot C_c^{(1/z_{Ci})-1}\right)
$$

where $C_c = C_{jCi}(v_{B'C'}) / C_{jCi0}$.

**Avalanche factors** (2-52):

$$
f_{AVL} = \frac{2a_n}{b_n}, \qquad q_{AVL} = \frac{b_n A_E}{2}
$$

#### 2.5.4 Substrate Transistor and CS Diode

**Substrate transistor transfer current** (2-53):

$$
I_{TS} = I_{TSS}\left[\exp\left(\frac{v_{B'C'}}{m_S V_T}\right) - \exp\left(\frac{v_{S'C'}}{m_S V_T}\right)\right]
$$

**CS diode current** (2-54):

$$
i_{jSC} = I_{SCS}\left[\exp\left(\frac{v_{S'C'}}{m_{SC} V_T}\right) - 1\right]
$$

### 2.6 Internal Base Resistance

**Normalized charge for base resistance** (2-55):

$$
\frac{1}{q_{rb}} = \frac{r_{SBi}}{r_{SBi0}} = \frac{1}{1 + \frac{Q_{jEi} + Q_{jCi}}{Q_{rb0}} + \frac{Q_f + Q_r}{Q_{rb0}}}
$$

**Modified zero-bias charge** (2-56):

$$
Q_{rb0} = Q_{p0} + \Delta Q_{rb0} = (1 + f_{DQr0}) Q_{p0} \approx Q_{p0}
$$

**Depletion charge ratio approximation** (2-57):

$$
\frac{Q_{jEi} + Q_{jCi}}{Q_{rb0}} \approx \frac{v_{jE}}{V_{r0E}} + \frac{v_{jCi}}{V_{r0C}}
$$

**Minority charge ratio simplification** (2-58):

$$
\frac{Q_f + Q_r}{Q_{rb0}} \approx \frac{I_{Tf}}{I_{rBif}} + \frac{I_{Tr}}{I_{rBir}}
$$

where $I_{rBif} = I_{Qf}$ and $I_{rBir} = I_{Qr}$.

**Combined Qz function** (2-59):

$$
Q_z = 1 + \frac{v_{jE}}{V_{r0E}} + \frac{v_{jCi}}{V_{r0C}} + \frac{I_{Tf}}{I_{Qf}} + \frac{I_{Tr}}{I_{Qr}}
$$

**Base resistance (conductivity modulation only)** (2-60):

$$
r_i = \frac{r_{Bi0}}{f_{Qz}}
$$

**Smoothing function** (2-61):

$$
f_{Qz} = \frac{1}{2}\left(Q_z + \sqrt{Q_z^2 + 0.01}\right)
$$

Avoids divide-by-zero at large reverse bias.

**Emitter current crowding function** (2-62):

$$
\Gamma(\zeta) = \frac{\ln(1 + \zeta)}{\zeta}
$$

**Current crowding factor** (2-63):

$$
\zeta = f_{geo} \frac{r_i \cdot I_{BE}}{V_T}
$$

**Modified geometry factor** (2-64):

$$
f_{geo}^* = \frac{f_{geo}}{1 + \beta_B(P_{E0} / A_{E0})}
$$

**Modified current crowding factor** (2-65):

$$
\zeta = f_{geo}^* \frac{r_i \cdot I_{BE}}{V_T}
$$

**Final internal base resistance** (2-66):

$$
r_{Bi} = r_i \cdot \Gamma(\zeta)
$$

**Low-current approximation (SGPM-like)** (2-67):

$$
\frac{r_{SBi}}{r_{SBi0}} = \frac{1}{1 + \frac{v_{B'E'}}{V_{rBif}} + \frac{v_{B'C'}}{V_{rBir}}}
$$

### 2.7 External Series Resistances

**Total base resistance** (2-68):

$$
r_B = r_{Bi} + r_{Bx}
$$

### 2.9 Non-Quasi-Static Effects

**NQS minority charge transfer function** (2-69):

$$
\frac{\tilde{Q}_{f,nqs}}{\tilde{Q}_f} = \frac{1}{1 + j\omega\tau_{Qf}}
$$

**Minority charge delay time** (2-70):

$$
\tau_{Qf} = \alpha_{Qf} \cdot \tau_0
$$

**NQS transfer current transfer function** (2-71):

$$
\frac{\tilde{i}_{T,nqs}}{\tilde{i}_T} = \frac{1}{1 + j\omega\tau_{IT}}
$$

**Transfer current delay time** (2-72):

$$
\tau_{IT} = \alpha_{iT} \cdot \tau_0
$$

Both implemented as RC sub-circuits. Controlled by flag `flnqs`.

### 2.10 Self-Heating

**Temperature-dependent thermal resistance** (2-73):

$$
R_{th}(T) = R_{th}(T_0)\left(1 + \alpha_{Rth} \Delta T\right)\left(\frac{T}{T_0}\right)^{\zeta_{Rth}}
$$

**Power dissipation** (for flsh=1) (2-74):

$$
P = I_T V_{C'E'} + I_{AVL}(V_{DCi} - V_{B'C'})
$$

### 2.11 Temperature Dependence

#### Bandgap Voltage

**Bandgap voltage (absolute T)** (2-75):

$$
V_g(T) = V_g(0) + K_1 T \ln(T) + K_2 T
$$

Default coefficients for Si: $K_1 = -1.02377 \times 10^{-4}$ V/K, $K_2 = 4.3215 \times 10^{-4}$ V/K, $V_g(0) = 1.170$ V.

**Classical quadratic bandgap** (2-76):

$$
V_g(T) = V_{g,cq}(0) - \frac{\beta_g T^2}{T + T_g}
$$

**Bandgap relative to reference T0** (2-77):

$$
V_g(T) = V_g(T_0) + k_1 \frac{T}{T_0} \ln\left(\frac{T}{T_0}\right) + k_2\left(\frac{T}{T_0} - 1\right)
$$

**Coefficient definitions** (2-78):

$$
k_1 = K_1 T_0, \qquad k_2 = K_2 T_0 + k_1 \ln(T_0)
$$

**Bandgap at reference temperature** (2-79):

$$
V_g(T_0) = k_2 + V_g(0)
$$

#### Intrinsic Carrier Concentration

**Effective intrinsic carrier density** (2-80):

$$
n_{ie}^2(T) = n_{ie}^2(T_0) \left(\frac{T}{T_0}\right)^{m_g} \exp\left[\frac{V_{geff}(0)}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
$$

**Temperature exponent** (2-81):

$$
m_g = 3 - \frac{k_1}{V_{T0}} = 3 - \frac{qK_1}{k_B}
$$

For Si: $m_g = 4.188$.

**Effective bandgap at 0K** (2-82):

$$
V_{geff}(0) = V_g(T_0) - k_2
$$

#### Saturation Currents

**Transfer saturation current** (2-83):

$$
I_S(T) = I_S(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{CT}} \exp\left[\frac{V_{gb}}{V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**BE base current saturation** (2-84):

$$
I_{BES}(T) = I_{BES}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{BET}} \exp\left[\frac{V_{ge}}{V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**BE recombination saturation current** (2-85):

$$
I_{RES}(T) = I_{RES}(T_0) \left(\frac{T}{T_0}\right)^{m_g/2} \exp\left[\frac{V_{gbe}}{2V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**BC base current saturation** (2-86):

$$
I_{BCS}(T) = I_{BCS}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{BCi}} \exp\left[\frac{V_{gc}}{V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**SC diode saturation current** (2-87):

$$
I_{SCS}(T) = I_{SCS}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{SCT}} \exp\left[\frac{V_{gs}}{V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**Substrate transistor saturation current** (2-88):

$$
I_{TSS}(T) = I_{TSS}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{SCT}} \exp\left[\frac{V_{gc}}{V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
$$

where $\zeta_{SCT} = m_g - 1.5$ and $V_{gbe} = (V_{gb} + V_{ge})/2$.

#### IQf and High-Current Temperature Dependence

**IQf temperature dependence** (2-89):

$$
I_{Qf}(T) = I_{Qf}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{IQf}} \exp\left[\frac{-\Delta V_{gBE}}{V_T(T_0)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**IQfh temperature dependence** (2-90):

$$
I_{Qfh}(T) = I_{Qfh}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{IQfh}}
$$

**tfh temperature dependence** (2-91):

$$
t_{fh}(T) = t_{fh}(T_0) \frac{I_{Qfh}(T)}{I_{Qfh}(T_0)} \exp\left[\frac{V_{gb} - V_{ge}}{V_T(T_0)}\left(\frac{T}{T_0} - 1\right)\right]
$$

**tef0 temperature dependence** (2-92):

$$
\tau_{ef}(T) = \tau_{ef}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{tef}} \exp\left[\frac{-(V_{gb} - V_{ge})}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
$$

Flag `flteft` turns T dependence of tef0 on/off.

**Simplified bandgap assumption** (2-93):

$$
V_{gsc} = V_{gbx} = V_{gb}
$$

#### Zero-Bias Capacitance Temperature Dependence

**Junction capacitance** (2-94):

$$
C_{j0}(T) = C_{j0}(T_0) \left(\frac{V_D(T_0)}{V_D(T)}\right)^z
$$

**Parameter aj temperature dependence** (2-95):

$$
a_j(T) = a_j(T_0) \frac{V_D(T)}{V_D(T_0)}
$$

#### Avalanche Temperature Dependence

**fAVL temperature** (2-96):

$$
f_{AVL}(T) = f_{AVL}(T_0) \exp\left[\alpha_{fav}(T - T_0)\right]
$$

**qAVL temperature** (2-97):

$$
q_{AVL}(T) = q_{AVL}(T_0) \exp\left[\alpha_{qav}(T - T_0)\right]
$$

#### Built-in Voltage Temperature Dependence

**Auxiliary voltage at reference temperature** (2-98):

$$
V_{Dj}(T_0) = 2V_{T0} \ln\left[\exp\left(\frac{V_D(T_0)}{2V_{T0}}\right) - \exp\left(-\frac{V_D(T_0)}{2V_{T0}}\right)\right]
$$

**Classical built-in voltage at temperature T** (2-99):

$$
V_{Dj}(T) = V_{Dj}(T_0)\frac{T}{T_0} + V_g\left(1 - \frac{T}{T_0}\right) - m_g V_T \ln\left(\frac{T}{T_0}\right)
$$

**Final built-in voltage (smoothed)** (2-100):

$$
V_D(T) = V_{Dj}(T) + 2V_T \ln\left(\frac{1 + \sqrt{1 + 4\exp\left(-V_{Dj}(T)/V_T\right)}}{2}\right)
$$

#### Transit Time Temperature Dependence

**Low-current transit time** (2-101):

$$
\tau_0(T) = \tau_0(T_0)\left[1 + \alpha_{t0}(T - T_0) + k_{t0}(T - T_0)^2\right]
$$

#### Early Voltage Temperature Dependence

**Reverse Early voltage** (2-102):

$$
V_{Er0}(T) = V_{Er0}(T_0) \exp\left[\frac{-\Delta V_{gBE}^{\zeta_{VgBE}}}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
$$

**aVEr temperature dependence** (2-103):

$$
a_{VEr}(T) = a_{VEr}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{VEr}}
$$

#### Collector Resistance Temperature Dependence

**Internal collector resistance** (2-104):

$$
r_{Ci0}(T) = r_{Ci0}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{Ci}}
$$

**Vlim temperature dependence** (2-105):

$$
V_{lim}(T) = V_{lim}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{Ci} - \alpha_{vs}}
$$

**CE saturation voltage** (2-106):

$$
V_{C'E's}(T) = V_{C'E's}(T_0)(1 + \alpha_{CEs} \Delta T)
$$

**VDCk temperature dependence** (2-107):

$$
V_{DCk}(T) = V_{DCk}(T_0)(1 - \alpha_{DCk} \Delta T)
$$

#### Series Resistance Temperature Dependence

**External collector resistance** (2-108):

$$
r_{Cx}(T) = r_{Cx}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{RCX}}
$$

**External base resistance** (2-109):

$$
r_{Bx}(T) = r_{Bx}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{RBX}}
$$

**Internal base resistance** (2-110):

$$
r_{Bi0}(T) = r_{Bi0}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{RBI}}
$$

**Emitter resistance** (2-111):

$$
r_E(T) = r_E(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{RE}}
$$

**Thermal resistance** (2-112):

$$
R_{th}(T) = R_{th}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{Rth}}
$$

### 2.12 Noise

**Thermal noise for series resistors** (2-113):

$$
\overline{I_r^2} = \frac{4k_BT\Delta f}{r}
$$

where $r \in \{r_E, r_{Cx}, r_B\}$.

**Transfer current shot noise** (2-114):

$$
\overline{I_T^2} = 2qI_T\Delta f
$$

**BE junction noise (shot + flicker)** (2-115):

$$
\overline{I_{BE}^2} = 2qI_{jBE}\Delta f + K_F I_{jBE}^{A_F} \frac{\Delta f}{f}
$$

**Other junction shot noise** (2-116):

$$
\overline{I_{j,diode}^2} = 2qI_{j,diode}\Delta f
$$

for diode $\in$ {BC, CS}.

**Avalanche shot noise** (2-117):

$$
\overline{I_{AVL}^2} = 2qI_{AVL}\Delta f
$$

**Total BC junction noise** (2-118):

$$
\overline{I_{BC}^2} = \overline{I_{jBC}^2} + \overline{I_{AVL}^2}
$$

### 4. Operating Point Small-Signal Equations

**Base current conductances** (4-1):

$$
g_{bei} = \frac{\partial I_{jBE}}{\partial V_{B'E'}}\bigg|_{V_{B'C'}}, \qquad g_{bci} = \frac{\partial I_{jBC}}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
$$

**Transconductance and output conductance** (4-2):

$$
g_{mT} = \frac{\partial I_T}{\partial V_{B'E'}}\bigg|_{V_{C'E'}}, \qquad g_{oT} = \frac{\partial I_T}{\partial V_{C'E'}}\bigg|_{V_{B'E'}}
$$

**Avalanche small-signal elements** (4-3):

$$
g_{av,f} = \frac{\partial I_{avl}}{\partial V_{B'E'}}\bigg|_{V_{B'C'}}, \qquad g_{av,r} = \frac{\partial I_{avl}}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
$$

Note: $g_{av,r}$ is negative.

**Depletion capacitances** (4-4):

$$
C_{jE} = \frac{\partial Q_{jE}}{\partial V_{B'E'}}\bigg|_{V_{B'C'}}, \qquad C_{jCi} = \frac{\partial Q^*_{jCi}}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
$$

**Diffusion capacitances** (4-5):

$$
C_{dE,f} = \frac{\partial Q_f}{\partial V_{B'E'}}\bigg|_{V_{B'C'}}, \qquad C_{dE,r} = \frac{\partial Q_f}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
$$

**Lumped BE and BC capacitances** (4-6):

$$
C_{BEi} = C_{jE} + C_{dE,f}, \qquad C_{BCi} = C_{jCi} + C_{dC,r}
$$

**Trans-capacitances** (4-7):

$$
C_{dC,f} = \frac{\partial Q_r}{\partial V_{B'E'}}\bigg|_{V_{B'C'}}, \qquad C_{dE,r} = \frac{\partial Q_f}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
$$

**Trans-capacitance controlled sources** (4-8):

$$
\tilde{c}_{dC,f}\tilde{V}_{B'E'} = j\omega C_{dC,f}\tilde{V}_{B'E'}, \qquad \tilde{c}_{dE,r}\tilde{V}_{B'C'} = j\omega C_{dE,r}\tilde{V}_{B'C'}
$$

**Feedback conductance** (4-9):

$$
g_{\mu i} = g_{bci} - g_{av,r}
$$

**Pi-topology capacitances** (4-10, 4-11):

$$
C_{\pi i} = C_{BEi} = C_{jE} + C_{dE,f}
$$

$$
C_{\mu i} = C_{BCi} = C_{jCi} + C_{dC,r}
$$

**Intrinsic BE resistance** (4-12):

$$
r_{\pi i} = \frac{1}{g_{\pi i}} = \frac{1}{g_{bei} - g_{av,f}}
$$

**Total intrinsic transconductance** (4-13):

$$
g_{mi} = g_{mT} + g_{av,f}
$$

**Internal output resistance** (4-14):

$$
r_{oi} = 1 / g_{oT}
$$

**Internal feedback resistance** (4-15):

$$
r_{\mu i} = 1 / g_{\mu i}
$$

**External BC depletion capacitance** (4-16):

$$
C_{jCx} = \frac{\partial Q^*_{jCx}}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
$$

**CS depletion capacitance** (4-17):

$$
C_{jS} = \frac{\partial Q_{jS}}{\partial V_{S'C'}}\bigg|_{V_{B'C'}}
$$

**Intrinsic small-signal current gain** (4-18):

$$
\beta_{AC} = \frac{I_{Ci}}{I_{Bi}}\bigg|_{V_{C'E'}} = \frac{\frac{\partial I_{Ci}}{\partial V_{B'E'}}\big|_{V_{C'E'}}}{\frac{\partial I_{Bi}}{\partial V_{B'E'}}\big|_{V_{C'E'}}}
$$

**Numerator derivative** (4-19):

$$
\frac{\partial I_{Ci}}{\partial V_{B'E'}}\bigg|_{V_{C'E'}} = g_{mi} - g_{\mu i}
$$

**Denominator derivative** (4-20):

$$
\frac{\partial I_{Bi}}{\partial V_{B'E'}}\bigg|_{V_{C'E'}} = g_{\pi i} + g_{\mu i}
$$

**Intrinsic voltage gain** (4-21):

$$
A_{Vi} = \frac{\partial V_{C'E'}}{\partial V_{B'E'}}\bigg|_{I_C} = -\frac{g_{mi} - g_{\mu i}}{g_{oT} + g_{\mu i}}
$$

**Transit frequency** (4-22):

$$
f_T = \frac{g_{mi}}{2\pi(C_\Sigma + C_\Lambda + r_\Lambda C_\Lambda g_{mi})}
$$

**Sum capacitance** (4-23):

$$
C_\Sigma = C_{\pi i} + C_{BEpar}
$$

**Feedback capacitance** (4-24):

$$
C_\Lambda = C_{\mu i} + C_{jCx} + C_{BCpar}
$$

**Effective resistance** (4-25):

$$
r_\Lambda = R_{Cx} + R_E + \frac{R_{Bx} + R_{Bi} + R_E}{\beta_{ac}}
$$

### 6.2 Solution of Transfer Current Equation (Cardano)

**General third-order equation** (6-1):

$$
x^3 + ax^2 + bx + c = 0
$$

**Coefficients** (6-2):

$$
a = -\left(1 + \frac{q_{jE}}{V_{Er}} + \frac{q_{jC}}{V_{Ef}}\right)
$$

$$
b = -\left(\frac{i_{Tfi}}{I_{Qf}} + \frac{i_{Tri}}{I_{Qr}} + w^2\frac{I_{Tfi}}{I_{Qfh}}\right)
$$

$$
c = -\frac{I_{Tfi}^2 t_{fh}}{I_{CK} I_{Qfh}}
$$

**Depressed cubic** (via substitution $x = z - a/3$) (6-3):

$$
z^3 + pz + q = 0
$$

**Depressed cubic coefficients** (6-4):

$$
p = b - \frac{a^2}{3}, \qquad q = \frac{2a^3}{27} - \frac{ab}{3} + c
$$

**Determinant** (6-5):

$$
D = \left(\frac{q}{2}\right)^2 + \left(\frac{p}{3}\right)^3
$$

**Low-injection limit** ($D = 0$) (6-6, 6-7):

$$
z = \frac{3q}{p} = -\frac{2}{3}a \implies x = -a = 1 + \frac{q_{jE}}{V_{Er}} + \frac{q_{jC}}{V_{Ef}}
$$

**D < 0 case (three real roots):**

**Determinant for c=0** (6-8):

$$
D = \frac{4b^3 - b^2 a^2}{108}
$$

**Reference angle** (6-9):

$$
\phi = \arccos\left(-\frac{q}{2}\sqrt{\frac{27}{-p^3}}\right)
$$

**Three solutions** (6-10):

$$
z_1 = -\sqrt{-\frac{4}{3}p}\cos\left(\frac{1}{3}\phi - \frac{\pi}{3}\right)
$$

$$
z_2 = -\sqrt{-\frac{4}{3}p}\cos\left(\frac{1}{3}\phi\right)
$$

$$
z_3 = -\sqrt{-\frac{4}{3}p}\cos\left(\frac{1}{3}\phi + \frac{\pi}{3}\right)
$$

Only $z_2$ yields a physically meaningful $q_{pT}$.

**D > 0 case (one real root)** (6-11, 6-12):

$$
u = \sqrt[3]{-\frac{q}{2} + \sqrt{D}}, \qquad v = \sqrt[3]{-\frac{q}{2} - \sqrt{D}}
$$

$$
z_1 = u + v, \qquad x_1 = z_1 - \frac{a}{3}
$$
