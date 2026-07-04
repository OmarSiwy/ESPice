# ASM-ESD 101.1.0 — Parameter & Equation Reference

> Advanced SPICE Model for ESD Protection Diodes (v101.1.0, April 2025)

## Model Topology

ASM-ESD models ESD protection diodes as either a four-terminal device (Collector C, Base B, Emitter E, thermal node DT) or a two-terminal diode (B, E, DT). The topology is based on the Gummel-Poon BJT model with ESD-specific enhancements: bias-dependent base resistance, multi-pole thermal network for self-heating, post-reverse-breakdown resistance model, transit-time-based overshoot, and a delayed BJT transient response model. Internal nodes $B_i$, $E_i$, $C_i$ separate extrinsic resistances from intrinsic junctions. Terminal B and E represent diode anode/cathode (NPN) or cathode/anode (PNP); C represents substrate.

## Physical Constants

| Symbol | Value | Description |
|--------|-------|-------------|
| $q$ | $1.6021918 \times 10^{-19}$ C | Electronic charge |
| $K_B$ | $1.3806226 \times 10^{-23}$ J/K | Boltzmann constant |
| $K_B/q$ | $8.6170869 \times 10^{-5}$ V/K | Boltzmann constant over electronic charge |
| $E_{g,300}$ | 1.1150877 eV | Band gap at 300.15 K |
| $E_{g0}$ | 1.16 eV | Band gap at 0 K |
| $egta$ | $7.0200 \times 10^{-4}$ | Band gap temperature coefficient $\alpha$ |
| $egtb$ | $1.1080 \times 10^{3}$ K | Band gap temperature coefficient $\beta$ |
| $Ref_t$ | 300.15 K | Reference temperature (27 degC) |

## Parameters

### Model Controllers

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TYPE | $type$ | — | 1 | {-1, 1} | Device type: 1 = NPN, -1 = PNP |
| SHMOD | $shmod$ | — | 2 | [-1, 2] | Self-heating model switch: -1 = external temp, 0 = off, 1 = single RC, 2 = dual RC |
| EXTMOD | $extmod$ | — | 0 | [-1, 2] | Extrinsic p-cell parasitic model switch: 0 = off, 1 = on |
| RBMOD | $rbmod$ | — | 1 | [-1, 2] | Base resistance model switch: 0 = fixed, 1 = bias-dependent |

### Device Size Parameters (Instance)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| L | $l$ | m | 10.0e-6 | [20e-9, inf) | Finger length |
| N | $n$ | — | 1 | [1, inf) | Number of fingers |
| DTEMP | $dtemp$ | degC | 0.0 | (-inf, inf) | Instance temperature offset |

### Current Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| IS | $is$ | A/m | 1.0e-17 | [0.0, 1.0] | Saturation current |
| NF | $nf$ | — | 1.0 | (0.0, inf) | Forward current emission coefficient |
| ISR | $isr$ | A/m | 0.0 | [0.0, 1.0] | Tunnel current coefficient |
| NTR | $ntr$ | — | 5.0 | (0.0, 500.0] | Reverse tunnel emission coefficient |
| VTR | $vtr$ | V | 10.0 | [0.0, inf) | Reverse tunnel current bias dependence parameter |
| BVR | $bvr$ | V | 10.0 | [1.0, inf) | Reverse breakdown voltage |
| NBV | $nbv$ | — | 10.0 | (0.0, 500.0] | Slope of current near breakdown for B-E junction |
| IJBV | $ijbv$ | A/m | 5.0 | [0.0, inf) | Post reverse breakdown current parameter for B-E junction |
| THER | $ther$ | 1/V^THEEXP | 0.01 | [0.0, inf) | Post reverse breakdown I-V model parameter |
| THEEXP | $theexp$ | — | 1.11 | [0.0, inf) | Post reverse breakdown resistance non-linearity parameter |
| EG | $eg$ | eV | 1.11 | [0.0, 10.0] | Band gap |
| BF | $bf$ | — | 0.1 | (0.0, inf) | Forward BJT current gain (4-terminal only) |
| BR | $br$ | — | 1.0 | (0.0, inf) | Reverse BJT current gain (4-terminal only) |
| NR | $nr$ | — | 10.0 | (0.0, 10.0] | Forward emission coefficient for B-C junction (4-terminal only) |
| VAF | $vaf$ | V | 0.0 | [0.0, inf) | Forward early voltage parameter (4-terminal only) |
| VAR | $var$ | V | 0.0 | [0.0, inf) | Reverse early voltage parameter (4-terminal only) |
| IKF | $ikf$ | A/m | 0.0 | [0.0, 1000.0] | Forward gain high current roll-off (4-terminal only) |
| XKF | $xkf$ | — | 0.9 | [0.0, inf) | Forward BJT gain roll-off at high current exponent (4-terminal only) |
| IKR | $ikr$ | A/m | 0.0 | [0.0, 1000.0] | Reverse gain high current roll-off (4-terminal only) |
| ISE | $ise$ | A/m | 0.0 | [0.0, 1.0] | B-E leakage saturation current (4-terminal only) |
| NE | $ne$ | — | 1.5 | (0.0, 10.0] | B-E leakage emission coefficient (4-terminal only) |
| ISC | $isc$ | A/m | 0.0 | [0.0, 1.0] | B-C leakage saturation current (4-terminal only) |
| NC | $nc$ | — | 2.0 | (0.0, 10.0] | Emission coefficient for B-C current (4-terminal only) |
| NBVC | $nbvc$ | — | 20.0 | (0.0, 500.0] | Slope of current near breakdown for B-C junction (4-terminal only) |
| IJBVC | $ijbvc$ | A/m | 0.0 | [0.0, inf) | Post reverse breakdown current multiplier for B-C junction (4-terminal only) |
| KBWM | $kbwm$ | V^-XBWM | 0.0 | [0.0, inf) | Base-width modulation impact on BJT gain (4-terminal only) |
| XBWM | $xbwm$ | — | 1.0 | [0.0, inf) | Exponent for base-width modulation effect on BJT gain (4-terminal only) |
| IKBWM | $ikbwm$ | 1/V | 0.0 | [0.0, inf) | Base width modulation multiplier parameter (4-terminal only) |
| CTHBB | $cthbb$ | — | 10.0e-9 | [0.0, inf) | Delayed BJT collector current time-constant parameter (4-terminal only) |
| CDELAY | $cdelay$ | — | 0.0 | [0.0, 1.0] | Delayed BJT current parameter; 0 = no delay (4-terminal only) |
| PTF | $ptf$ | — | 0.0 | [0.0, inf) | Excess phase at freq = 1/(TF*2*pi) Hz (4-terminal only) |

### Resistance Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RB | $rb$ | Ohm.m | 1.0e-5 | [0.0, inf) | Base resistance |
| RE | $re$ | Ohm.m | 1.0e-6 | [0.0, inf) | Emitter resistance |
| RC | $rc$ | Ohm.m | 1.0e-6 | [0.0, inf) | Collector resistance (4-terminal only) |
| RBE | $rbe$ | Ohm.m | 0.0 | [0.0, inf) | Extrinsic base resistance, active when EXTMOD=1 |
| REE | $ree$ | Ohm.m | 0.0 | [0.0, inf) | Extrinsic emitter resistance, active when EXTMOD=1 |
| RCE | $rce$ | Ohm.m | 0.0 | [0.0, inf) | Extrinsic collector resistance, active when EXTMOD=1 (4-terminal only) |
| TF | $tf$ | sec | 0.0 | [0.0, inf) | Forward transit time |
| TR | $tr$ | sec | 0.0 | [0.0, inf) | Reverse transit time (4-terminal only) |
| VTF0 | $vtf0$ | V | 100.0 | (0.0, inf) | Transit time voltage/field threshold |
| TEXP | $texp$ | — | 2.0 | (0.0, inf) | Carrier transit time field dependence parameter, active when RBMOD=1 |
| ATFF | $atff$ | — | 0.0 | [0.0, inf) | Transit time field dependence model multiplier |
| MEXP | $mexp$ | — | 2.0 | (0.0, inf) | Velocity saturation exponent for base resistor |
| MEXPE | $mexpe$ | — | 2.0 | (0.0, inf) | Velocity saturation exponent for emitter resistor |
| VSATB | $vsatb$ | V | 100.0 | (0.0, inf) | Voltage at which velocity saturation starts in base resistor |
| VSATE | $vsate$ | V | 100.0 | (0.0, inf) | Voltage at which velocity saturation starts in emitter resistor |
| QEXP | $qexp$ | — | 1.0 | [0.0, inf) | Charge dependence of base resistance exponent parameter |
| QTT0 | $qtt0$ | C/m | 1.0e-3 | (0.0, inf) | Base resistance charge dependence parameter (alias: VTT0) |
| FC | $fc$ | — | 0.5 | [0.0, 1.0] | Coefficient for forward-bias depletion capacitance linearization |
| MINR | $minr$ | Ohm | 1e-3 | [0.0, inf) | Minimum resistance |

### Capacitance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CJE | $cje$ | F/m | 0.0 | [0.0, inf) | Zero-bias B-E junction capacitance |
| VJE | $vje$ | V | 0.75 | [0.0, inf) | B-E junction built-in potential |
| MJE | $mje$ | — | 0.33 | (0.0, 1.0) | B-E junction exponential factor |
| CJC | $cjc$ | F/m | 0.0 | [0.0, inf) | Zero-bias B-C junction capacitance (4-terminal only) |
| VJC | $vjc$ | V | 0.75 | [0.0, inf) | B-C junction built-in potential (4-terminal only) |
| MJC | $mjc$ | — | 0.33 | (0.0, 1.0) | B-C junction exponential factor (4-terminal only) |
| CJS | $cjs$ | F/m | 0.0 | [0.0, inf) | Zero-bias E-C (substrate) junction capacitance (4-terminal only) |
| VJS | $vjs$ | V | 0.75 | [0.0, inf) | E-C junction built-in potential (4-terminal only) |
| MJS | $mjs$ | — | 0.33 | (0.0, 1.0) | E-C junction exponential factor (4-terminal only) |
| XCJC | $xcjc$ | — | 1.0 | [0.0, 1.0] | Fraction of B-C depletion capacitance connected to internal base node (4-terminal only) |

### Noise Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| KF | $kf$ | — | 0.0 | [0.0, inf) | Flicker noise coefficient |
| AF | $af$ | — | 1.0 | [0.0, 10.0] | Flicker noise exponent parameter |

### Temperature Dependence and Self-Heating Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TNOM | $tnom$ | degC | 25.0 | [-40, 125.0] | Nominal temperature for parameter extraction |
| XTI | $xti$ | — | 3.0 | [0.0, 20.0] | Temperature dependence of IS |
| XTIR | $xtir$ | — | 0.5 | [-20.0, 20.0] | Temperature dependence of ISR |
| XTB | $xtb$ | — | 0.0 | [-10.0, 10.0] | Temperature dependence of BF and BR (4-terminal only) |
| XJBV | $xjbv$ | — | 0.0 | [0.0, inf) | Temperature dependence of IJBV |
| XJBVC | $xjbvc$ | — | 5.0 | [0.0, inf) | Temperature dependence of IJBVC (4-terminal only) |
| XBVR | $xbvr$ | — | 0.0 | (-inf, inf) | Temperature dependence of BVR |
| XTHEEXP | $xtheexp$ | — | 0.0 | (-inf, inf) | Temperature dependence of THEEXP |
| ARB | $arb$ | — | 0.0 | [0.0, inf) | Temperature dependence of RB |
| ARE | $are$ | — | 0.0 | [0.0, inf) | Temperature dependence of RE |
| ARC | $arc$ | — | 0.0 | [0.0, inf) | Temperature dependence of RC (4-terminal only) |
| TFAIL | $tfail$ | K | 1000.0 | [0.0, inf) | Failure temperature |
| RTH0 | $rth0$ | K/W | 5.0e-4 | (0.0, inf) | Thermal resistance, active in SHMOD=1 and 2 |
| CTH0 | $cth0$ | s*W/K | 5.0e-4 | [0.0, inf) | Thermal capacitance, active in SHMOD=1 and 2 |
| RTH1 | $rth1$ | K/W | 5.0e-6 | (0.0, inf) | Thermal resistance, active in SHMOD=2 |
| CTH1 | $cth1$ | s*W/K | 1.0e-7 | [0.0, inf) | Thermal capacitance, active in SHMOD=2 |

**Total: 70 parameters** (43 shared between diode and BJT modes + 27 BJT-only in 4-terminal mode)

## Equations

### 2.1 Device Sizing

$$
W_{eff} = N \cdot L
$$

Effective device width used to scale all per-meter quantities to absolute values.

### 2.2 Extrinsic and Intrinsic Voltages

$$
V_{bi} = V_b - R_b \cdot I_b \tag{2.2.1}
$$

$$
V_{ci} = V_c - R_c \cdot I_c \tag{2.2.2}
$$

$$
V_{ei} = V_e - R_e \cdot I_e \tag{2.2.3}
$$

$$
V_{bei} = V_{bi} - V_{ei} \tag{2.2.4}
$$

$$
V_{bci} = V_{bi} - V_{ci} \tag{2.2.5}
$$

All voltages are polarity-adjusted by TYPE: $V_{bei} = \text{TYPE} \cdot V(bi, ei)$.

### 2.3 Temperature Dependent Calculations

#### Device temperature

$$
T_{amb} = T_{\text{circuit}} + \text{Temp}(dt) + \text{DTEMP} \tag{2.3.1}
$$

$$
T_{dev} = \text{clamp}(T_{amb},\; T_{MIN} + 273.15,\; T_{MAX} + 273.15)
$$

where $T_{MIN} = -100$, $T_{MAX} = 1026.85$.

$$
V_t = \frac{K_B}{q} \cdot T_{dev} \tag{2.3.2}
$$

$$
rT = \frac{T_{dev}}{T_{nom}} \tag{2.3.3}
$$

$$
lnrT = \ln(rT) \tag{2.3.4}
$$

#### BJT gain temperature dependence (4-terminal only)

$$
BF_t = BF \cdot \exp(XTB \cdot lnrT) \tag{2.3.5}
$$

$$
BR_t = BR \cdot \exp(XTB \cdot lnrT) \tag{2.3.6}
$$

#### Base-width modulation factor (4-terminal only)

$$
F_{bwm} = 1 + KBWM \cdot (-\min(V_{bci}, 0))^{XBWM}
$$

$$
BF_t = BF_t \cdot F_{bwm}
$$

#### Saturation current temperature intermediate variables

$$
argt = XTI \cdot lnrT + EG \cdot \frac{rT - 1}{V_t} \tag{2.3.7}
$$

$$
argtr = XTIR \cdot lnrT \tag{2.3.8}
$$

#### Current parameter temperature scaling

$$
IS_t = IS \cdot \exp(argt) \tag{2.3.9}
$$

$$
ISR_t = ISR \cdot \exp(argtr) \tag{2.3.10}
$$

$$
ISE_t = ISE \cdot \frac{\exp(argt / NE)}{\exp(XTB \cdot lnrT)} \tag{2.3.11}
$$

$$
ISC_t = ISC \cdot \frac{\exp(argt / NC)}{\exp(XTB \cdot lnrT)} \tag{2.3.12}
$$

#### Post-breakdown parameter temperature scaling

$$
IJBV_t = IJBV \cdot (1 + XJBV \cdot (rT - 1)) \tag{2.3.13}
$$

$$
BVR_t = BVR \cdot (1 + XBVR \cdot (rT - 1)) \tag{2.3.14}
$$

$$
IJBVC_t = IJBVC \cdot (1 + XJBVC \cdot (rT - 1)) \tag{2.3.15}
$$

$$
THEEXP_t = THEEXP \cdot (1 + XTHEEXP \cdot (rT - 1))
$$

#### Resistance temperature scaling

$$
RB_t = RB \cdot rT^{ARB} \tag{2.3.16}
$$

$$
RE_t = RE \cdot rT^{ARE} \tag{2.3.17}
$$

$$
RC_t = RC \cdot rT^{ARC} \tag{2.3.18}
$$

#### Junction capacitance temperature update

Applied to each junction (B-E, B-C, E-C) with corresponding CJ, VJ, MJ values.

$$
F_1 = \frac{T_{nom}}{Ref_t} \tag{2.3.19}
$$

$$
F_2 = \frac{T_{dev}}{Ref_t} \tag{2.3.20}
$$

$$
E_{g,f} = E_{g0} - \frac{egta \cdot T_{dev}^2}{egtb + T_{dev}} \tag{2.3.21}
$$

$$
Arg_0 = \frac{-E_{g,f}}{2 \cdot K_B \cdot T_{dev}} + \frac{E_{g,300}}{2 \cdot K_B \cdot Ref_t} \tag{2.3.22}
$$

$$
P_f = -2V_t \left(\frac{3}{2}\ln(F_2) + q \cdot Arg_0\right) \tag{2.3.23}
$$

$$
P_0 = \frac{VJ - P_f}{F_1} \tag{2.3.24}
$$

$$
Gm_0 = \frac{VJ - P_0}{P_0} \tag{2.3.25}
$$

$$
CJ_t = \frac{CJ}{1 + MJ \cdot (4 \times 10^{-4} \cdot (T_{nom} - Ref_t) - Gm_0)} \tag{2.3.26}
$$

$$
VJ_t = F_2 \cdot P_0 + P_f \tag{2.3.27}
$$

$$
Gm_n = \frac{VJ_t - P_0}{P_0} \tag{2.3.28}
$$

$$
CJ_{t,final} = CJ_t \cdot \left(1 + MJ \cdot (4 \times 10^{-4} \cdot (T_{dev} - Ref_t) - Gm_n)\right) \tag{2.3.29}
$$

### 2.4 Current Calculations

#### Softplus limiting function

Used throughout the model to avoid numerical overflow:

$$
\text{ln\_exp\_plus\_1}(x) = \begin{cases}
x & \text{if } x \geq 37 \\
e^x & \text{if } x \leq -37 \\
\ln(e^x + 1) & \text{otherwise}
\end{cases}
$$

#### Exponential limiting function

For any argument $arg$:

$$
le = \begin{cases}
(1 + arg - 80) \cdot e^{80} & \text{if } arg > 80 \\
e^{arg} & \text{otherwise}
\end{cases}
$$

Linearizes the exponential beyond the limit to prevent overflow.

#### Forward diode current (IDIO macro)

Applies to B-E junction (with $IS_t$, $NF$, $NBV$, $BVR_t$, $IJBV_t$, $THER$, $THEEXP_t$, $V_{bei}$) and B-C junction (with appropriate parameters).

When $IS_t > 0$:

$$
arg = \frac{V_{bei}}{NF \cdot V_t}
$$

$$
arg_{bv} = \frac{-V_{bei} - BVR_t}{NBV \cdot V_t}
$$

$$
arg_{bv,vt} = \frac{-BVR_t}{NBV \cdot V_t}
$$

$$
I_1 = IS_t \cdot (le(arg) - 1) \tag{2.4.4}
$$

$$
I_2 = \frac{IJBV_t}{1 + THER \cdot |V_{bei}|^{THEEXP_t}} \cdot \left[\text{ln\_exp\_plus\_1}(arg_{bv}) - \text{ln\_exp\_plus\_1}(arg_{bv,vt})\right] \tag{2.4.5}
$$

$$
I_f = I_1 - I_2 \tag{2.4.3}
$$

The $\text{ln\_exp\_plus\_1}$ smoothing replaces the hard $(\exp(x)-1)$ formulation used in the manual's Eq. 2.4.5 for numerical robustness near breakdown.

#### Reverse tunnel current (IDIOR macro)

When $ISR_t > 0$:

$$
t_0 = \max(VTR - V_{bei},\; 0.001)
$$

$$
arg = \frac{-V_{bei} \cdot VTR}{NTR \cdot V_t \cdot t_0}
$$

$$
I_{be,r,tunnel} = ISR_t \cdot (le(arg) - 1) \tag{2.4.6a}
$$

#### B-E leakage/recombination current (4-terminal only)

$$
I_{be,r,leak} = ISE_t \cdot \left(\exp\!\left(\frac{V_{bei}}{NE \cdot V_t}\right) - 1\right) \tag{2.4.6b}
$$

$$
I_{be,r} = I_{be,r,tunnel} + I_{be,r,leak} \tag{2.4.6}
$$

#### Total base-emitter current

Two-terminal (diode) mode:

$$
I_{be} = I_f - I_{be,r,tunnel} \tag{diode}
$$

Four-terminal (BJT) mode:

$$
I_{be} = \frac{I_f}{BF_t} + I_{be,r,leak} \tag{2.4.2}
$$

#### Base-collector junction current (4-terminal only)

$$
I_3 = IS_t \cdot \left(\exp\!\left(\frac{V_{bci}}{NR \cdot V_t}\right) - 1\right) \tag{2.4.9}
$$

$$
I_4 = \frac{IJBVC_t}{1 + THER \cdot |V_{bci}|^{THEEXP}} \cdot \left[\text{ln\_exp\_plus\_1}\!\left(\frac{-V_{bci} - BVR_t}{NBVC \cdot V_t}\right) - \text{ln\_exp\_plus\_1}\!\left(\frac{-BVR_t}{NBVC \cdot V_t}\right)\right] \tag{2.4.10}
$$

$$
I_r = I_3 - I_4 \tag{2.4.8}
$$

$$
I_{bc,r} = ISR_t \cdot \left(\exp\!\left(\frac{-V_{bci} \cdot VTR}{NTR \cdot V_t \cdot \max(VTR - V_{bci},\, 0.001)}\right) - 1\right) + ISC_t \cdot \left(\exp\!\left(\frac{V_{bci}}{NC \cdot V_t}\right) - 1\right) \tag{2.4.11}
$$

$$
I_{bc} = \frac{I_r}{BR_t} + I_{bc,r} \tag{2.4.7}
$$

#### Total base current

$$
I_b = I_{be} + I_{bc} \tag{2.4.1}
$$

#### Collector current (4-terminal only)

$$
I_c = I_{tf} - I_{tr} \tag{2.4.12}
$$

$$
I_{tf} = I_f \cdot Ik_1 \tag{2.4.13}
$$

$$
I_{tr} = I_r \cdot Ik_1 \tag{2.4.14}
$$

#### Integral charge control factor (Kqb)

$$
\text{ovaf} = \begin{cases} 1/VAF & \text{if } VAF > 0 \\ 0 & \text{otherwise} \end{cases}
$$

$$
\text{ovar} = \begin{cases} 1/VAR & \text{if } VAR > 0 \\ 0 & \text{otherwise} \end{cases}
$$

$$
\text{oikf} = \begin{cases} 1/IKF & \text{if } IKF > 0 \\ 0 & \text{otherwise} \end{cases}
$$

$$
\text{oikr} = \begin{cases} 1/IKR & \text{if } IKR > 0 \\ 0 & \text{otherwise} \end{cases}
$$

$$
\text{oikf}' = \text{oikf} \cdot (1 + V_{bci} \cdot IKBWM)
$$

$$
Kq_2 = I_f \cdot \text{oikf}' + I_r \cdot \text{oikr} \tag{2.4.16}
$$

$$
T_0 = |1 + 4 \cdot Kq_2|
$$

$$
Dkqb = 1 + T_0^{XKF} \tag{from code}
$$

$$
iKq_1 = 1 - V_{bei} \cdot \text{ovar} - V_{bci} \cdot \text{ovaf} \tag{2.4.15}
$$

$$
Ik_1 = \frac{2 \cdot iKq_1}{Dkqb} \tag{2.4.15}
$$

#### Delayed BJT response (4-terminal only)

Differential equation for the delayed voltage node $V_{tbb}$:

$$
(V_{bei} - V_{tbb}) + 10^{-6} \cdot V_{tbb} + CTHBB \cdot \frac{dV_{tbb}}{dt} = 0 \tag{2.4.17}
$$

Delayed current ratio:

$$
d_{ratio} = \frac{|\min(V_{tbb}, V_{bei})|}{\max(|V_{bei}|, 10^{-9})} \tag{2.4.18}
$$

Modified transfer current:

$$
I_{tf,f} = I_{tf} \cdot d_{ratio} \cdot CDELAY + (1 - CDELAY) \cdot I_{tf} \tag{2.4.19}
$$

### 2.5 Base Resistance Formulations

#### Velocity saturation in base resistor

$$
T_1 = 1 + \left(\frac{|V_{bbi}|}{VSATB}\right)^{MEXP} \tag{2.5.2}
$$

$$
RB = RB_t \cdot T_1^{1/MEXP} \tag{2.5.1a}
$$

#### Velocity saturation in emitter resistor

$$
T_{1e} = 1 + \left(\frac{|V_{eei}|}{VSATE}\right)^{MEXPE}
$$

$$
RE = RE_t \cdot T_{1e}^{1/MEXPE}
$$

#### Charge modulation of base resistance (RBMOD=1)

Differential equation for accumulated charge $Q_m$:

$$
\frac{dQ_m}{dt} + \frac{Q_m}{T_f} - \frac{I_f}{BF} = 0 \tag{2.5.4}
$$

Implemented via a filter node: $I(itt) = -I_f/BF \cdot T_f$, $I(rtt) = V(tt)$, $I(ctt) = T_f \cdot dV(tt)/dt$.

In the diode mode, the charge source is $-I_f \cdot T_f$ (no BF divisor).

$$
T_2 = \left(\frac{|Q_m|}{QTT0}\right)^{QEXP} \tag{2.5.3}
$$

$$
RB_{final} = \frac{RB}{1 + T_2} \tag{2.5.1}
$$

When RBMOD=0, $RB_{final} = RB$ (no charge modulation).

#### Transit time field dependence

$$
V_{tff} = \left(\frac{|V_{be}|}{VTF0}\right)^{TEXP} \tag{2.5.8}
$$

$$
V_{tff1} = (1 + V_{tff})^{1/TEXP} - 1 \tag{2.5.9}
$$

$$
T_f = TF \cdot (1 + ATFF \cdot V_{tff1}) \tag{2.5.10}
$$

#### Extrinsic resistance addition (EXTMOD=1)

$$
RB_{total} = RB_{final} + RBE
$$

$$
RE_{total} = RE + REE
$$

$$
RC_{total} = RC_t + RCE \quad \text{(4-terminal only)}
$$

#### Effective terminal resistance

All resistances are scaled and clamped before use in branch equations:

$$
R_{b,eff} = \max\!\left(\frac{RB_{total}}{W_{eff}},\; MINR\right)
$$

$$
R_{e,eff} = \max\!\left(\frac{RE_{total}}{W_{eff}},\; MINR\right)
$$

$$
R_{c,eff} = \max\!\left(\frac{RC_{total}}{W_{eff}},\; MINR\right)
$$

If the nominal (unscaled parameter / Weff) resistance is zero or below MINR, the branch is shorted (voltage source = 0) instead.

### 2.6 Capacitance / Charge Formulations

#### Junction charge with FC linearization (QJ macro)

Used for B-E and B-C junctions. Given $CJ_t$, $V$, $P = VJ_t$, $M = MJ$, $FC$:

$$
dv_0 = -P \cdot FC
$$

$$
dv_h = V + dv_0
$$

**If $dv_h > 0$ (forward bias beyond FC):**

$$
pwq = (1 - FC)^{-1-M}
$$

$$
Q_{lo} = P \cdot \frac{1 - (1-FC)^{1-M} \cdot pwq \cdot (1-FC)^2 }{1 - M} = P \cdot \frac{1 - (1-FC)^{1-M}}{1-M}
$$

$$
Q_{hi} = dv_h \cdot \left(1 - FC + \frac{M \cdot dv_h}{2P}\right) \cdot pwq
$$

**If $dv_h \leq 0$ (reverse or moderate forward bias):**

$$
Q_{lo} = P \cdot \frac{1 - (1 - V/P)^{1-M}}{1 - M}
$$

$$
Q_{hi} = 0
$$

**Total:**

$$
Q_j = CJ_t \cdot (Q_{lo} + Q_{hi})
$$

The equivalent capacitance (for reference) is:

$$
C_{be} = \frac{CJE_t}{(1 - V_{bei}/VJE_t)^{MJE}} + T_f \cdot \frac{dI_f}{dV_{bei}} \tag{2.6.1}
$$

$$
C_{bc} = \frac{CJC_t}{(1 - V_{bci}/VJC_t)^{MJC}} + TR \cdot \frac{dI_r}{dV_{bci}} \tag{2.6.2}
$$

#### Junction charge without linearization (QJZ macro, substrate)

Used for E-C (substrate) junction. Given $CJ_t$, $V$, $P = VJ_t$, $M = MJ$:

**If $V \leq 0$:**

$$
Q_j = CJ_t \cdot P \cdot \frac{1 - (1 - V/P)^{1-M}}{1 - M}
$$

**If $V > 0$:**

$$
Q_j = CJ_t \cdot V \cdot \left(1 + \frac{M \cdot V}{2P}\right)
$$

#### B-C capacitance partitioning (4-terminal only)

$$
Q_{jcx} = (1 - XCJC) \cdot QJ(CJC_t, V_{bci,ext}, VJC_t, MJC, FC)
$$

$$
Q_{jci} = XCJC \cdot QJ(CJC_t, V_{bci}, VJC_t, MJC, FC)
$$

#### Diffusion charges

$$
Q_{de} = T_f \cdot I_f \quad \text{(diode: } T_f \cdot I_{tzf}\text{)}
$$

$$
Q_{dc} = TR \cdot I_{tr} \quad \text{(4-terminal only)}
$$

#### Excess phase charge (4-terminal only)

When $PTF \neq 0$ and $TF \neq 0$:

$$
Q_{xf1} = \text{TYPE} \cdot PTF \cdot \frac{\pi}{180} \cdot TF \cdot I_{tf}
$$

Otherwise $Q_{xf1} = 0$. This charge is subtracted from B-E and added to B-C to model excess phase.

### 2.7 Self-Heating Model

#### SHMOD = 1 (single time-constant RC network)

$$
P_{diss} = |I_{be} \cdot V_{be}| \quad \text{(diode)} \quad \text{or} \quad |I_{be} \cdot V_{be}| + |I_{bc} \cdot V_{bc}| \quad \text{(BJT)}
$$

$$
\frac{\Delta T}{RTH0} + CTH0 \cdot \frac{d(\Delta T)}{dt} = P_{diss}
$$

#### SHMOD = 2 (dual time-constant RC network)

$$
\frac{T(dt) - T(dt1)}{RTH0} + CTH0 \cdot \frac{dT(dt)}{dt} = P_{diss}
$$

$$
\frac{T(dt1)}{RTH1} + CTH1 \cdot \frac{dT(dt1)}{dt} = \frac{T(dt) - T(dt1)}{RTH0}
$$

The two-stage network provides a more accurate frequency response of the thermal impedance.

#### SHMOD = -1 (external temperature)

Power dissipation is computed and injected into the DT node, but the DT node temperature is determined by the external circuit. Internal node dt1 is grounded.

#### SHMOD = 0 (self-heating off)

Both dt and dt1 are grounded (temperature rise = 0).

### 2.8 Failure Warning

$$
\text{if } T_{dev} > TFAIL: \quad \text{report "Device temperature has reached failure"}
$$

### 2.9 Flicker Noise Model

$$
S_N(f) = \frac{KF \cdot |I_{be}|^{AF}}{f} \tag{2.9.1}
$$

Active only when $AF > 0$ and $KF > 0$. The noise is applied to the B-E branch with the sign of $\text{TYPE} \cdot I_{be}$.

### 2.10 Thermal Noise Model

White noise from each resistance:

$$
S_{Rb} = \frac{4 \cdot K_B \cdot T_{dev}}{R_b / W_{eff}} \tag{2.10.1}
$$

$$
S_{Rc} = \frac{4 \cdot K_B \cdot T_{dev}}{R_c / W_{eff}} \tag{2.10.2}
$$

$$
S_{Re} = \frac{4 \cdot K_B \cdot T_{dev}}{R_e / W_{eff}} \tag{2.10.3}
$$

Each noise source is active only when the corresponding resistance is non-zero and >= MINR.

### 2.11 Shot Noise

$$
S_{I,be} = 2q \cdot |I_{be}| \quad \text{(on B-E branch)}
$$

$$
S_{I,ce} = 2q \cdot |I_{tf} - I_{tr}| \quad \text{(on C-E branch, 4-terminal only)}
$$

### 2.12 Device Size Scaling

All per-meter parameters (currents, capacitances, resistances) are scaled by $W_{eff} = N \cdot L$. Current and charge contributions are multiplied by $W_{eff}$; resistance branches use $R/W_{eff}$. The model assumes linear, uniform scaling -- layout-dependent effects require an external wrapper.

### 2.13 Branch Loading Summary (Diode Mode)

| Branch | Contributions |
|--------|---------------|
| $B \to B_i$ | $V_{bbi} / R_{b,eff}$ + thermal noise |
| $E \to E_i$ | $V_{eei} / R_{e,eff}$ + thermal noise |
| $B_i \to E_i$ | $\text{TYPE} \cdot I_{be} \cdot W_{eff}$ + $G_{min} \cdot V_{bei}$ + $dQ_{je}/dt$ + $dQ_{de}/dt$ + flicker noise + shot noise |
| $DT$ | Self-heating network |

### 2.14 Branch Loading Summary (4-Terminal BJT Mode)

| Branch | Contributions |
|--------|---------------|
| $B \to B_i$ | $V_{bbi} / R_{b,eff}$ + thermal noise |
| $E \to E_i$ | $V_{eei} / R_{e,eff}$ + thermal noise |
| $C \to C_i$ | $V_{cci} / R_{c,eff}$ + thermal noise |
| $B_i \to E_i$ | $\text{TYPE} \cdot I_{be} \cdot W_{eff}$ + $G_{min} \cdot V_{bei}$ + $dQ_{je}/dt$ + $dQ_{de}/dt$ - $dQ_{xf1}/dt$ + flicker noise + shot noise |
| $B_i \to C_i$ | $\text{TYPE} \cdot I_{bc} \cdot W_{eff}$ + $G_{min} \cdot V_{bci}$ + $dQ_{jci}/dt$ + $dQ_{dc}/dt$ + $dQ_{xf1}/dt$ |
| $B \to C_i$ | $dQ_{jcx}/dt$ |
| $C_i \to E_i$ | $\text{TYPE} \cdot (I_{tf,f} - I_{tr}) \cdot W_{eff}$ + $G_{min} \cdot V_{cei}$ + shot noise |
| $E \to C_i$ | $dQ_{js}/dt$ |
| $DT$ | Self-heating network |
