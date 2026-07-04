# JUNCAP2 200.6 -- Parameter & Equation Reference

> Junction diode model (bundled with PSP). Version 200.6.3, NXP/CEA-Leti, October 2024.

## Model Topology

JUNCAP2 is a two-terminal (anode A, cathode K) junction diode model for source/drain junctions in MOSFETs. The total junction is decomposed into three geometrical components -- bottom (area-scaled by AB), STI-edge (perimeter-scaled by LS), and gate-edge (perimeter-scaled by LG) -- each carrying independent capacitance and current contributions that are summed to form the total device charge and current. Each component models depletion capacitance, ideal (Shockley) current, Shockley-Read-Hall (SRH) generation/recombination current, trap-assisted tunneling (TAT) current, band-to-band tunneling (BBT) current, and avalanche breakdown, plus shot noise.

## Physical Constants

| No. | Symbol | Unit | Value | Description |
|-----|--------|------|-------|-------------|
| 1 | $T_0$ | K | 273.15 | Celsius-to-Kelvin offset |
| 2 | $k_B$ | J/K | $1.3806505 \times 10^{-23}$ | Boltzmann constant |
| 3 | $q$ | C | $1.6021918 \times 10^{-19}$ | Elementary charge |
| 4 | $\hbar$ | J s | $1.05457168 \times 10^{-34}$ | Reduced Planck constant |
| 5 | $m_0$ | kg | $9.1093826 \times 10^{-31}$ | Electron rest mass |
| 6 | $\epsilon_0$ | F/m | $8.85418782 \times 10^{-12}$ | Permittivity of vacuum |
| 7 | $\epsilon_{r,Si}$ | -- | 11.8 | Relative permittivity of silicon |

Derived: $\epsilon_{Si} = \epsilon_0 \cdot \epsilon_{r,Si}$

## Other Constants

| No. | Symbol | Unit | Value | Description |
|-----|--------|------|-------|-------------|
| 1 | $T_{min}$ | C | -250 | Minimum temperature for model equations |
| 2 | $V_{bi,low}$ | V | 0.050 | Lower boundary for built-in voltage |
| 3 | $a$ | -- | 2 | Upper-limit factor for forward capacitance ($a \cdot C_{jo}$) |
| 4 | $\epsilon_{ch}$ | -- | 0.1 | Smoothing constant for charge model |
| 5 | $\Delta V_{bi}$ | -- | 0.050 | Voltage difference in BBT model |
| 6 | $\epsilon_{av}$ | -- | $10^{-6}$ | Smoothing constant for effective voltage in avalanche model |
| 7 | $V_{br,max}$ | V | $10^3$ | Upper limit for VBR; above this, avalanche model is off |
| 9 | $V_{max,large}$ | V | $10^8$ | Value assigned to $V_{max}$ when IDSAT is zero |
| 10 | $a_{erfc}$ | -- | 0.29214664 | Parameter in erfc approximation |
| 11 | $p_{erfc}$ | -- | $\sqrt{\pi} \cdot a_{erfc}$ | Parameter in erfc approximation |
| 12 | $b_{erfc}$ | -- | $\frac{6 - 5 \cdot a_{erfc} - p_{erfc}^{-2}}{3}$ | Parameter in erfc approximation |
| 13 | $c_{erfc}$ | -- | $1 - a_{erfc} - b_{erfc}$ | Parameter in erfc approximation |

## Parameters

### Instance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| AB | m$^2$ | $10^{-12}$ | 0 | -- | Junction area |
| LS | m | $10^{-6}$ | 0 | -- | STI-edge part of junction perimeter |
| LG | m | $10^{-6}$ | 0 | -- | Gate-edge part of junction perimeter |
| MULT | -- | 1 | 0 | -- | Multiplication factor |
| TRISE (or DTEMP) | K | 0 | -- | -- | Device temperature offset |

### General Model Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| LEVEL | -- | 200 | 200 | 200 | Model selection parameter |
| TYPE | -- | 1 | -- | -- | Junction polarity switch (-1 or 1): p-n vs n-p |
| IFACTOR | -- | 1 | 0 | -- | Multiplier factor for junction current |
| CFACTOR | -- | 1 | 0 | -- | Multiplier factor for junction capacitance |
| TRJ (or TREF) | C | 21 | $T_{min}$ | -- | Reference temperature |
| SWJUNEXP | -- | 0 | 0 | 1 | Flag: 0 = full JUNCAP2, 1 = Express model |
| DTA | C | 0 | -- | -- | Temperature offset w.r.t. ambient temperature |
| IMAX | A | 1000 | $10^{-12}$ | -- | Maximum current for exponential forward behavior |

### Capacitance Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| CJORBOT | $C_{JOR,bot}$ | F/m$^2$ | $10^{-3}$ | $10^{-12}$ | -- | Zero-bias capacitance per unit area, bottom |
| CJORSTI | $C_{JOR,sti}$ | F/m | $10^{-9}$ | $10^{-18}$ | -- | Zero-bias capacitance per unit length, STI-edge |
| CJORGAT | $C_{JOR,gat}$ | F/m | $10^{-9}$ | $10^{-18}$ | -- | Zero-bias capacitance per unit length, gate-edge |
| VBIRBOT | $V_{BIR,bot}$ | V | 1 | $V_{bi,low}$ | -- | Built-in voltage at ref. temp., bottom |
| VBIRSTI | $V_{BIR,sti}$ | V | 1 | $V_{bi,low}$ | -- | Built-in voltage at ref. temp., STI-edge |
| VBIRGAT | $V_{BIR,gat}$ | V | 1 | $V_{bi,low}$ | -- | Built-in voltage at ref. temp., gate-edge |
| PBOT | $P_{bot}$ | -- | 0.5 | 0.05 | 0.95 | Grading coefficient, bottom |
| PSTI | $P_{sti}$ | -- | 0.5 | 0.05 | 0.95 | Grading coefficient, STI-edge |
| PGAT | $P_{gat}$ | -- | 0.5 | 0.05 | 0.95 | Grading coefficient, gate-edge |

### Ideal-Current Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| PHIGBOT | $\phi_{G,bot}$ | V | 1.16 | -- | -- | Zero-temperature bandgap voltage, bottom |
| PHIGSTI | $\phi_{G,sti}$ | V | 1.16 | -- | -- | Zero-temperature bandgap voltage, STI-edge |
| PHIGGAT | $\phi_{G,gat}$ | V | 1.16 | -- | -- | Zero-temperature bandgap voltage, gate-edge |
| IDSATRBOT | $I_{DSAT,R,bot}$ | A/m$^2$ | $10^{-12}$ | 0 | -- | Saturation current density at ref. temp., bottom |
| IDSATRSTI | $I_{DSAT,R,sti}$ | A/m | $10^{-18}$ | 0 | -- | Saturation current density at ref. temp., STI-edge |
| IDSATRGAT | $I_{DSAT,R,gat}$ | A/m | $10^{-18}$ | 0 | -- | Saturation current density at ref. temp., gate-edge |

### Shockley-Read-Hall Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| CSRHBOT | $C_{SRH,bot}$ | A/m$^3$ | $10^{2}$ | 0 | -- | SRH prefactor, bottom |
| CSRHSTI | $C_{SRH,sti}$ | A/m$^2$ | $10^{-4}$ | 0 | -- | SRH prefactor, STI-edge |
| CSRHGAT | $C_{SRH,gat}$ | A/m$^2$ | $10^{-4}$ | 0 | -- | SRH prefactor, gate-edge |
| XJUNSTI | $X_{JUN,sti}$ | m | $10^{-7}$ | $10^{-9}$ | -- | Junction depth, STI-edge |
| XJUNGAT | $X_{JUN,gat}$ | m | $10^{-7}$ | $10^{-9}$ | -- | Junction depth, gate-edge |

### Trap-Assisted Tunneling Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| CTATBOT | $C_{TAT,bot}$ | A/m$^3$ | $10^{2}$ | 0 | -- | TAT prefactor, bottom |
| CTATSTI | $C_{TAT,sti}$ | A/m$^2$ | $10^{-4}$ | 0 | -- | TAT prefactor, STI-edge |
| CTATGAT | $C_{TAT,gat}$ | A/m$^2$ | $10^{-4}$ | 0 | -- | TAT prefactor, gate-edge |
| MEFFTATBOT | $m_{eff,TAT,bot}$ | -- | 0.25 | 0.01 | -- | Relative effective mass for TAT, bottom |
| MEFFTATSTI | $m_{eff,TAT,sti}$ | -- | 0.25 | 0.01 | -- | Relative effective mass for TAT, STI-edge |
| MEFFTATGAT | $m_{eff,TAT,gat}$ | -- | 0.25 | 0.01 | -- | Relative effective mass for TAT, gate-edge |

### Band-to-Band Tunneling Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| CBBTBOT | $C_{BBT,bot}$ | A V$^{-3}$ | $10^{-12}$ | 0 | -- | BBT prefactor, bottom |
| CBBTSTI | $C_{BBT,sti}$ | A V$^{-3}$ m | $10^{-18}$ | 0 | -- | BBT prefactor, STI-edge |
| CBBTGAT | $C_{BBT,gat}$ | A V$^{-3}$ m | $10^{-18}$ | 0 | -- | BBT prefactor, gate-edge |
| FBBTRBOT | $F_{BBT,R,bot}$ | V/m | $10^{9}$ | -- | -- | Normalization field at ref. temp. for BBT, bottom |
| FBBTRSTI | $F_{BBT,R,sti}$ | V/m | $10^{9}$ | -- | -- | Normalization field at ref. temp. for BBT, STI-edge |
| FBBTRGAT | $F_{BBT,R,gat}$ | V/m | $10^{9}$ | -- | -- | Normalization field at ref. temp. for BBT, gate-edge |
| STFBBTBOT | $ST_{FBBT,bot}$ | K$^{-1}$ | $-10^{-3}$ | -- | -- | Temperature scaling for BBT, bottom |
| STFBBTSTI | $ST_{FBBT,sti}$ | K$^{-1}$ | $-10^{-3}$ | -- | -- | Temperature scaling for BBT, STI-edge |
| STFBBTGAT | $ST_{FBBT,gat}$ | K$^{-1}$ | $-10^{-3}$ | -- | -- | Temperature scaling for BBT, gate-edge |

### Avalanche and Breakdown Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| VBRBOT | $V_{BR,bot}$ | V | 10 | 0.1 | -- | Breakdown voltage, bottom |
| VBRSTI | $V_{BR,sti}$ | V | 10 | 0.1 | -- | Breakdown voltage, STI-edge |
| VBRGAT | $V_{BR,gat}$ | V | 10 | 0.1 | -- | Breakdown voltage, gate-edge |
| PBRBOT | $P_{BR,bot}$ | V | 4 | 0.1 | -- | Breakdown onset tuning parameter, bottom |
| PBRSTI | $P_{BR,sti}$ | V | 4 | 0.1 | -- | Breakdown onset tuning parameter, STI-edge |
| PBRGAT | $P_{BR,gat}$ | V | 4 | 0.1 | -- | Breakdown onset tuning parameter, gate-edge |
| FREV | -- | -- | $10^{3}$ | $10^{3}$ | $10^{10}$ | Tunes current increase after reverse breakdown |

### JUNCAP Express Parameters

| Parameter | Symbol | Unit | Default | Min | Max | Description |
|-----------|--------|------|---------|-----|-----|-------------|
| VJUNREF | $V_{JUNREF}$ | V | 2.5 | 0.5 | -- | Typical maximum junction voltage (~$2 \cdot V_{sup}$) |
| FJUNQ | $F_{JUNQ}$ | V | 0.03 | 0 | -- | Fraction below which capacitance components are neglected |

**Total model parameter count: 52** (LEVEL through FJUNQ, numbered 0--51), plus 5 instance parameters (AB, LS, LG, MULT, TRISE/DTEMP).

## Equations

### 4.1 Internal Parameters (Bias-Independent, Initialization Phase)

#### Thermal Voltage

$$
T_{KR} = T_0 + TRJ \tag{4.1}
$$

If TREF is defined, TRJ is replaced by TREF.

$$
T_{KD} = T_0 + \max(T_A + DTA + TRISE,\; T_{min}) \tag{4.2}
$$

If DTEMP is defined, TRISE is replaced by DTEMP.

$$
\phi_{TR} = \frac{k_B \cdot T_{KR}}{q} \tag{4.3}
$$

$$
\phi_{TD} = \frac{k_B \cdot T_{KD}}{q} \tag{4.4}
$$

#### Band Gap

$$
\Delta\phi_{GR} = -\frac{7.02 \times 10^{-4} \cdot T_{KR}^{2}}{1108.0 + T_{KR}} \tag{4.5}
$$

$$
\phi_{GR,bot} = \text{PHIGBOT} + \Delta\phi_{GR} \tag{4.6}
$$

$$
\phi_{GR,sti} = \text{PHIGSTI} + \Delta\phi_{GR} \tag{4.7}
$$

$$
\phi_{GR,gat} = \text{PHIGGAT} + \Delta\phi_{GR} \tag{4.8}
$$

$$
\Delta\phi_{GD} = -\frac{7.02 \times 10^{-4} \cdot T_{KD}^{2}}{1108.0 + T_{KD}} \tag{4.9}
$$

$$
\phi_{GD,bot} = \text{PHIGBOT} + \Delta\phi_{GD} \tag{4.10}
$$

$$
\phi_{GD,sti} = \text{PHIGSTI} + \Delta\phi_{GD} \tag{4.11}
$$

$$
\phi_{GD,gat} = \text{PHIGGAT} + \Delta\phi_{GD} \tag{4.12}
$$

#### Intrinsic Carrier Concentration Ratio

$$
F_{TD,bot} = \left(\frac{T_{KD}}{T_{KR}}\right)^{1.5} \cdot \exp\!\left(\frac{\phi_{GR,bot}}{2\,\phi_{TR}} - \frac{\phi_{GD,bot}}{2\,\phi_{TD}}\right) \tag{4.13}
$$

$$
F_{TD,sti} = \left(\frac{T_{KD}}{T_{KR}}\right)^{1.5} \cdot \exp\!\left(\frac{\phi_{GR,sti}}{2\,\phi_{TR}} - \frac{\phi_{GD,sti}}{2\,\phi_{TD}}\right) \tag{4.14}
$$

$$
F_{TD,gat} = \left(\frac{T_{KD}}{T_{KR}}\right)^{1.5} \cdot \exp\!\left(\frac{\phi_{GR,gat}}{2\,\phi_{TR}} - \frac{\phi_{GD,gat}}{2\,\phi_{TD}}\right) \tag{4.15}
$$

#### Saturation Current Density at Device Temperature

$$
I_{DSAT,bot} = \text{IDSATRBOT} \cdot F_{TD,bot}^{2} \tag{4.16}
$$

$$
I_{DSAT,sti} = \text{IDSATRSTI} \cdot F_{TD,sti}^{2} \tag{4.17}
$$

$$
I_{DSAT,gat} = \text{IDSATRGAT} \cdot F_{TD,gat}^{2} \tag{4.18}
$$

#### Determination of $V_{max}$

$$
V_{max,bot} = \begin{cases} V_{max,large} & \text{if } I_{DSAT,bot} \cdot AB = 0 \\[6pt] \phi_{TD} \cdot \ln\!\left(\dfrac{IMAX}{I_{DSAT,bot} \cdot AB} + 1\right) & \text{if } I_{DSAT,bot} \cdot AB \neq 0 \end{cases} \tag{4.19}
$$

$$
V_{max,sti} = \begin{cases} V_{max,large} & \text{if } I_{DSAT,sti} \cdot LS = 0 \\[6pt] \phi_{TD} \cdot \ln\!\left(\dfrac{IMAX}{I_{DSAT,sti} \cdot LS} + 1\right) & \text{if } I_{DSAT,sti} \cdot LS \neq 0 \end{cases} \tag{4.20}
$$

$$
V_{max,gat} = \begin{cases} V_{max,large} & \text{if } I_{DSAT,gat} \cdot LG = 0 \\[6pt] \phi_{TD} \cdot \ln\!\left(\dfrac{IMAX}{I_{DSAT,gat} \cdot LG} + 1\right) & \text{if } I_{DSAT,gat} \cdot LG \neq 0 \end{cases} \tag{4.21}
$$

$$
V_{max} = \min(V_{max,bot},\; V_{max,sti},\; V_{max,gat}) \tag{4.22}
$$

#### Built-in Voltages

$$
U_{bi,bot} = \text{VBIRBOT} \cdot \frac{T_{KD}}{T_{KR}} - 2\,\phi_{TD} \cdot \ln F_{TD,bot} \tag{4.23}
$$

$$
V_{bi,bot} = U_{bi,bot} + \phi_{TD} \cdot \ln\!\left(1 + \exp\!\left(\frac{V_{bi,low} - U_{bi,bot}}{\phi_{TD}}\right)\right) \tag{4.24}
$$

$$
U_{bi,sti} = \text{VBIRSTI} \cdot \frac{T_{KD}}{T_{KR}} - 2\,\phi_{TD} \cdot \ln F_{TD,sti} \tag{4.25}
$$

$$
V_{bi,sti} = U_{bi,sti} + \phi_{TD} \cdot \ln\!\left(1 + \exp\!\left(\frac{V_{bi,low} - U_{bi,sti}}{\phi_{TD}}\right)\right) \tag{4.26}
$$

$$
U_{bi,gat} = \text{VBIRGAT} \cdot \frac{T_{KD}}{T_{KR}} - 2\,\phi_{TD} \cdot \ln F_{TD,gat} \tag{4.27}
$$

$$
V_{bi,gat} = U_{bi,gat} + \phi_{TD} \cdot \ln\!\left(1 + \exp\!\left(\frac{V_{bi,low} - U_{bi,gat}}{\phi_{TD}}\right)\right) \tag{4.28}
$$

#### Determination of $V_{F,min}$ and $V_{ch}$

$$
V_{bi,min} = \min(V_{bi,bot},\; V_{bi,sti},\; V_{bi,gat}) \tag{4.29}
$$

Note: only contributions with nonzero geometry (AB, LS, LG) are included in the minimum.

$$
V_{F,min} = \begin{cases} V_{bi,min} \cdot \left(1 - a^{-1/P_{BOT}}\right) & \text{if } V_{bi,min} = V_{bi,bot} \\[4pt] V_{bi,min} \cdot \left(1 - a^{-1/P_{STI}}\right) & \text{if } V_{bi,min} = V_{bi,sti} \\[4pt] V_{bi,min} \cdot \left(1 - a^{-1/P_{GAT}}\right) & \text{if } V_{bi,min} = V_{bi,gat} \end{cases} \tag{4.30}
$$

$$
V_{ch} = \epsilon_{ch} \cdot V_{bi,min} \tag{4.31}
$$

#### Determination of $\alpha_{av}$

$$
\alpha_{av} = 1 - \frac{1}{FREV} \tag{4.32}
$$

---

### 4.2 The juncap-function

The juncap-function is evaluated once per geometrical component (bottom, STI-edge, gate-edge). Its inputs are listed above in the Parameters section. Outputs: junction current per unit area/length $I_j'$ and junction charge per unit area/length $Q_j'$.

#### Junction Charge

$$
C_{jo} = CJOR \cdot \left(\frac{VBIR}{V_{bi}}\right)^{P} \tag{4.33}
$$

$$
V_j = \mathrm{hyp5}(V_{AK};\; V_{F,min},\; V_{ch}) \tag{4.34}
$$

$$
Q_j' = CFACTOR \cdot \left\{ \frac{C_{jo} \cdot V_{bi}}{1 - P} \cdot \left[1 - \left(1 - \frac{V_j}{V_{bi}}\right)^{1-P}\right] + a \cdot C_{jo} \cdot (V_{AK} - V_j) \right\} \tag{4.35}
$$

#### Ideal Current

$$
M_{ID} = \begin{cases} \exp\!\left(\dfrac{V_{AK}}{\phi_{TD}}\right) & \text{if } V_{AK} < V_{max} \\[8pt] \left(1 + \dfrac{V_{AK} - V_{MAX}}{\phi_{TD}}\right) \cdot \exp\!\left(\dfrac{V_{MAX}}{\phi_{TD}}\right) & \text{if } V_{AK} \ge V_{max} \end{cases} \tag{4.36}
$$

$$
I_D' = (M_{ID} - 1) \cdot I_{DSAT} \tag{4.37}
$$

#### Shockley-Read-Hall Current

Note: if $CSRH = CTAT = 0$, skip Eqs. (4.38)--(4.47) and set $I_{SRH}' = 0$.

$$
z_{inv} = \sqrt{M_{ID}} \tag{4.38}
$$

$$
z = \frac{1}{z_{inv}} \tag{4.39}
$$

$$
\psi^{*} = \begin{cases} \phi_{TD} \cdot \ln\!\left[z + \sqrt{(z+1)(z+3)}\,\right] & \text{if } V_{AK} > 0 \\[6pt] -V_{AK} + \phi_{TD} \cdot \ln\!\left[1 + 2\,z_{inv} + \sqrt{(1 + z_{inv})(1 + 3\,z_{inv})}\,\right] & \text{if } V_{AK} \le 0 \end{cases} \tag{4.40}
$$

$$
V_{j,lim} = V_{bi,min} - 2\,\psi^{*} \tag{4.41}
$$

$$
V_{j,SRH} = \mathrm{hyp2}(V_{AK};\; V_{j,lim},\; \phi_{TD}) \tag{4.42}
$$

$$
w_{SRH,step} = 1 - \sqrt{1 - \frac{2\,\psi^{*}}{V_{bi} - V_{j,SRH}}} \tag{4.43}
$$

$$
\Delta w_{SRH} = \left(\frac{w_{SRH,step}^{2} \cdot \ln w_{SRH,step}}{1 - w_{SRH,step}} + w_{SRH,step}\right) \cdot (1 - 2P) \tag{4.44}
$$

$$
w_{SRH} = w_{SRH,step} + \Delta w_{SRH} \tag{4.45}
$$

$$
W_{dep} = \frac{XJUN \cdot \epsilon_{Si}}{CJOR} \cdot \left(\frac{V_{bi} - V_{j,SRH}}{VBIR}\right)^{P} \tag{4.46}
$$

$$
I_{SRH}' = CSRH \cdot F_{TD} \cdot (z_{inv} - 1) \cdot w_{SRH} \cdot W_{dep} \tag{4.47}
$$

#### Trap-Assisted Tunneling Current

Note: if $CTAT = 0$, skip Eqs. (4.48)--(4.62) and set $I_{TAT}' = 0$.

$$
F_{max} = \frac{V_{bi} - V_{j,SRH}}{W_{dep} \cdot (1 - P)} \tag{4.48}
$$

$$
m_{eff} = MEFFTAT \cdot m_0 \tag{4.49}
$$

$$
\Delta E = \max\!\left(\frac{\phi_{GD}}{2},\; \phi_{TD}\right) \tag{4.50}
$$

$$
a_{TAT} = \frac{\Delta E}{\phi_{TD}} \tag{4.51}
$$

$$
b_{TAT} = \frac{\sqrt{32\, m_{eff}\, q\, (\Delta E)^3}}{3\,\hbar\, F_{max}} \tag{4.52}
$$

$$
u'_{max} = \frac{2\, a_{TAT}^{2}}{3\, b_{TAT}} \tag{4.53}
$$

$$
u_{max} = \sqrt{\frac{u_{max}'^{2}}{u_{max}'^{2} + 1}} \tag{4.54}
$$

$$
w_{\Gamma} = 1 + b_{TAT} \cdot u_{max}^{3/2} \cdot \frac{P}{P - 1} \tag{4.55}
$$

$$
w_{TAT} = \frac{w_{SRH} \cdot w_{\Gamma}}{w_{SRH} + w_{\Gamma}} \tag{4.56}
$$

$$
k_{TAT} = \sqrt{\frac{3\, b_{TAT}}{8\, \sqrt{u_{max}}}} \tag{4.57}
$$

$$
l_{TAT} = \frac{4\, a_{TAT}}{3\, b_{TAT}} \cdot \sqrt{u_{max}} - u_{max} \tag{4.58}
$$

$$
m_{TAT} = \frac{2\, a_{TAT}^{2}}{3\, b_{TAT}} \cdot \sqrt{u_{max}} - a_{TAT} \cdot u_{max} + \frac{b_{TAT}}{2} \cdot u_{max}^{3/2} \tag{4.59}
$$

##### erfc Approximation

$$
\mathrm{erfcapprox}(y): \quad t_{erfc} = \begin{cases} \dfrac{1}{1 + p_{erfc} \cdot y} & \text{if } y > 0 \\[6pt] \dfrac{1}{1 - p_{erfc} \cdot y} & \text{if } y \le 0 \end{cases} \tag{4.60a}
$$

$$
\mathrm{erfcapprox}^{+} = \left(a_{erfc} \cdot t_{erfc} + b_{erfc} \cdot t_{erfc}^{2} + c_{erfc} \cdot t_{erfc}^{3}\right) \cdot \exp(-y^2) \tag{4.60b}
$$

$$
\mathrm{erfcapprox}(y) = \begin{cases} \mathrm{erfcapprox}^{+} & \text{if } y > 0 \\ 2 - \mathrm{erfcapprox}^{+} & \text{if } y \le 0 \end{cases} \tag{4.60c}
$$

##### Field-Enhancement Factor

$$
\Gamma_{max} = \frac{a_{TAT} \cdot \exp(m_{TAT}) \cdot \mathrm{erfcapprox}\!\left[k_{TAT} \cdot (l_{TAT} - 1)\right] \cdot \sqrt{\pi}}{2\, k_{TAT}} \tag{4.61}
$$

$$
I_{TAT}' = CTAT \cdot F_{TD} \cdot (z_{inv} - 1) \cdot \Gamma_{max} \cdot w_{TAT} \cdot W_{dep} \tag{4.62}
$$

#### Band-to-Band Tunneling Current

Note: if $CBBT = 0$, skip Eqs. (4.65)--(4.68) and set $I_{BBT}' = 0$.

$$
V_{BBT,lim} = \min(\text{VBIRBOT},\;\text{VBIRSTI},\;\text{VBIRGAT}) - \Delta V_{bi} \tag{4.63}
$$

$$
V_{BBT} = \mathrm{hyp2}(V_{AK},\; V_{BBT,lim},\; \phi_{TR}) \tag{4.64}
$$

$$
W_{dep,r} = \frac{XJUN \cdot \epsilon_{Si}}{CJOR} \cdot \left(\frac{VBIR - V_{BBT}}{VBIR}\right)^{P} \tag{4.65}
$$

$$
F_{max,r} = \frac{VBIR - V_{BBT}}{W_{dep,r} \cdot (1 - P)} \tag{4.66}
$$

$$
F_{BBT} = FBBTR \cdot \left[1 + STFBBT \cdot (T_{KD} - T_{KR})\right] \tag{4.67}
$$

$$
I_{BBT}' = CBBT \cdot V_{AK} \cdot F_{max,r}^{2} \cdot \exp\!\left(-\frac{F_{BBT}}{F_{max,r}}\right) \tag{4.68}
$$

#### Avalanche and Breakdown

Note: if $VBR > V_{br,max}$, skip Eqs. (4.69)--(4.72) and set $f_{breakdown} = 1$.

$$
V_{av} = \mathrm{hyp2}(V_{AK};\; 0,\; \epsilon_{av}) \tag{4.69}
$$

$$
f_{stop} = \frac{1}{1 - \alpha_{av}^{PBR}} \tag{4.70}
$$

$$
s_f = -f_{stop}^{2} \cdot \alpha_{av}^{PBR-1} \cdot \frac{PBR}{VBR} \tag{4.71}
$$

$$
f_{breakdown} = \begin{cases} \dfrac{1}{\left(1 - \dfrac{-V_{av}}{VBR}\right)^{PBR}} & \text{if } V_{av} > -\alpha_{av} \cdot VBR \\[10pt] f_{stop} + (V_{av} + \alpha_{av} \cdot VBR) \cdot s_f & \text{if } V_{av} \le -\alpha_{av} \cdot VBR \end{cases} \tag{4.72}
$$

#### Total Current (per unit area/length)

$$
I_j' = IFACTOR \cdot \left(I_D' + I_{SRH}' + I_{TAT}' + I_{BBT}'\right) \cdot f_{breakdown} \tag{4.73}
$$

---

### 4.3 The JUNCAP Model (Full, SWJUNEXP = 0)

#### Anode-Cathode Voltage

$$
V_{AK} = TYPE \cdot (V_A - V_K) \tag{4.74}
$$

#### Junction Charge -- Component Evaluation

The juncap-function $Q_j'$ is called three times with component-specific parameters:

$$
Q_{j,bot}' = Q_j'(\ldots,\; CJOR = \text{CJORBOT},\; VBIR = \text{VBIRBOT},\; P = \text{PBOT},\; XJUN = 1,\; \ldots) \tag{4.75}
$$

$$
Q_{j,sti}' = Q_j'(\ldots,\; CJOR = \text{CJORSTI},\; VBIR = \text{VBIRSTI},\; P = \text{PSTI},\; XJUN = \text{XJUNSTI},\; \ldots) \tag{4.76}
$$

$$
Q_{j,gat}' = Q_j'(\ldots,\; CJOR = \text{CJORGAT},\; VBIR = \text{VBIRGAT},\; P = \text{PGAT},\; XJUN = \text{XJUNGAT},\; \ldots) \tag{4.77}
$$

$$
Q_j = TYPE \cdot MULT \cdot \left(AB \cdot Q_{j,bot}' + LS \cdot Q_{j,sti}' + LG \cdot Q_{j,gat}'\right) \tag{4.78}
$$

#### Junction Current -- Component Evaluation

$$
I_{j,bot}' = I_j'(\ldots,\; CJOR = \text{CJORBOT},\; VBIR = \text{VBIRBOT},\; P = \text{PBOT},\; XJUN = 1,\; \ldots) \tag{4.79}
$$

$$
I_{j,sti}' = I_j'(\ldots,\; CJOR = \text{CJORSTI},\; VBIR = \text{VBIRSTI},\; P = \text{PSTI},\; XJUN = \text{XJUNSTI},\; \ldots) \tag{4.80}
$$

$$
I_{j,gat}' = I_j'(\ldots,\; CJOR = \text{CJORGAT},\; VBIR = \text{VBIRGAT},\; P = \text{PGAT},\; XJUN = \text{XJUNGAT},\; \ldots) \tag{4.81}
$$

$$
I_j = TYPE \cdot MULT \cdot \left(AB \cdot I_{j,bot}' + LS \cdot I_{j,sti}' + LG \cdot I_{j,gat}'\right) \tag{4.82}
$$

#### Junction Noise

$$
S_I = 2\, q \cdot |I_j| \tag{4.83}
$$

---

### 4.4 JUNCAP Express (SWJUNEXP = 1)

#### 4.4.1 Initialization -- Current Model

$$
V_1 = -0.4 \cdot VJUNREF \tag{4.84}
$$

$$
V_2 = -0.65 \cdot VJUNREF \tag{4.85}
$$

$$
V_3 = -0.8 \cdot VJUNREF \tag{4.86}
$$

$$
V_4 = 0.1 \tag{4.87}
$$

$$
V_5 = 0.2 \tag{4.88}
$$

$$
I_n = f_{juncap}(V_n) \quad \text{for } n = 1 \ldots 5 \tag{4.89}
$$

where $f_{juncap}(V)$ is Eq. (4.82) evaluated with $V_{AK} = V$, $MULT = 1$, $TYPE = 1$.

$$
g(V, I_0, m) = I_0 \cdot \left[\exp\!\left(\frac{V \cdot m}{\phi_{TD}}\right) - 1\right] \tag{4.90}
$$

##### Ideal Forward Current

$$
I_{SATFOR1} = AB \cdot I_{DSAT,bot} + LS \cdot I_{DSAT,sti} + LG \cdot I_{DSAT,gat} \tag{4.91}
$$

$$
M_{FOR1} = 1 \tag{4.92}
$$

##### Non-Ideal Forward Current

$$
I_{4,cor} = I_4 - g(V_4,\; I_{SATFOR1},\; M_{FOR1}) \tag{4.93}
$$

$$
I_{5,cor} = I_5 - g(V_5,\; I_{SATFOR1},\; M_{FOR1}) \tag{4.94}
$$

$$
\alpha_{for} = \frac{I_{4,cor}}{I_{5,cor}} \tag{4.95}
$$

$$
M_{FOR2} = \phi_{TD} \cdot \frac{\ln(\alpha_{for})}{V_4 - V_5} \tag{4.96}
$$

$$
I_{SATFOR2} = \frac{I_{4,cor}}{\exp(V_4 \cdot M_{FOR2} / \phi_{TD}) - 1} \tag{4.97}
$$

##### Reverse Current

$$
I_{1,cor} = I_1 - g(V_1,\; I_{SATFOR1},\; M_{FOR1}) - g(V_1,\; I_{SATFOR2},\; M_{FOR2}) \tag{4.98}
$$

$$
I_{2,cor} = I_2 - g(V_2,\; I_{SATFOR1},\; M_{FOR1}) - g(V_2,\; I_{SATFOR2},\; M_{FOR2}) \tag{4.99}
$$

$$
I_{3,cor} = I_3 - g(V_3,\; I_{SATFOR1},\; M_{FOR1}) - g(V_3,\; I_{SATFOR2},\; M_{FOR2}) \tag{4.100}
$$

$$
\alpha_{rev} = \frac{I_{1,cor}}{I_{2,cor}} \tag{4.101}
$$

$$
m_0 = \phi_{TD} \cdot \frac{\ln \alpha_{rev}}{V_2 - V_1} \tag{4.102}
$$

$$
\Delta m = \phi_{TD} \cdot \frac{(\alpha_{rev} - 1) \cdot \alpha_{rev}^{V_2/(V_2 - V_1)} - 1}{\alpha_{rev} \cdot V_1 - V_2 + (V_2 - V_1) \cdot \alpha_{rev}^{V_1/(V_1 - V_2)}} \tag{4.103}
$$

$$
M_{REV} = m_0 + \Delta m \tag{4.104}
$$

$$
I_{SATREV} = \frac{-I_{3,cor}}{\exp(-V_3 \cdot M_{REV} / \phi_{TD}) - 1} \tag{4.105}
$$

#### 4.4.1 Initialization -- Charge Model

$$
C_{jo,bot} = \text{CJORBOT} \cdot \left(\frac{\text{VBIRBOT}}{V_{bi,bot}}\right)^{P_{BOT}} \tag{4.106}
$$

$$
C_{jo,sti} = \text{CJORSTI} \cdot \left(\frac{\text{VBIRSTI}}{V_{bi,sti}}\right)^{P_{STI}} \tag{4.107}
$$

$$
C_{jo,gat} = \text{CJORGAT} \cdot \left(\frac{\text{VBIRGAT}}{V_{bi,gat}}\right)^{P_{GAT}} \tag{4.108}
$$

$$
Z_{bot} = AB \cdot C_{jo,bot} \tag{4.109}
$$

$$
Z_{sti} = LS \cdot C_{jo,sti} \tag{4.110}
$$

$$
Z_{gat} = LG \cdot C_{jo,gat} \tag{4.111}
$$

$$
Z_{tot} = Z_{bot} + Z_{sti} + Z_{gat} \tag{4.112}
$$

#### 4.4.2 Express Model Equations (Bias-Dependent)

##### Express Currents

$$
I_{for1} = g(V_{AK},\; I_{SATFOR1},\; M_{FOR1}) \tag{4.113}
$$

$$
I_{for2} = g(V_{AK},\; I_{SATFOR2},\; M_{FOR2}) \tag{4.114}
$$

$$
I_{rev} = -g(-V_{AK},\; I_{SATREV},\; M_{REV}) \tag{4.115}
$$

$$
I_j = TYPE \cdot MULT \cdot (I_{for1} + I_{for2} + I_{rev}) \tag{4.116}
$$

##### Express Charge Model

$$
V_j = \mathrm{hyp5}(V_{AK};\; V_{F,min},\; V_{ch}) \tag{4.117}
$$

$$
Q_{j,bot}' = \begin{cases} \dfrac{C_{jo,bot} \cdot V_{bi,bot}}{1 - P_{BOT}} \cdot \left[1 - \left(1 - \dfrac{V_j}{V_{bi,bot}}\right)^{1-P_{BOT}}\right] + a \cdot C_{jo,bot} \cdot (V_{AK} - V_j) & \text{if } Z_{bot} > FJUNQ \cdot Z_{tot} \\[6pt] 0 & \text{otherwise} \end{cases} \tag{4.118}
$$

$$
Q_{j,sti}' = \begin{cases} \dfrac{C_{jo,sti} \cdot V_{bi,sti}}{1 - P_{STI}} \cdot \left[1 - \left(1 - \dfrac{V_j}{V_{bi,sti}}\right)^{1-P_{STI}}\right] + a \cdot C_{jo,sti} \cdot (V_{AK} - V_j) & \text{if } Z_{sti} > FJUNQ \cdot Z_{tot} \\[6pt] 0 & \text{otherwise} \end{cases} \tag{4.119}
$$

$$
Q_{j,gat}' = \begin{cases} \dfrac{C_{jo,gat} \cdot V_{bi,gat}}{1 - P_{GAT}} \cdot \left[1 - \left(1 - \dfrac{V_j}{V_{bi,gat}}\right)^{1-P_{GAT}}\right] + a \cdot C_{jo,gat} \cdot (V_{AK} - V_j) & \text{if } Z_{gat} > FJUNQ \cdot Z_{tot} \\[6pt] 0 & \text{otherwise} \end{cases} \tag{4.120}
$$

$$
Q_j = TYPE \cdot MULT \cdot \left(AB \cdot Q_{j,bot}' + LS \cdot Q_{j,sti}' + LG \cdot Q_{j,gat}'\right) \tag{4.121}
$$

##### Express Noise

$$
S_I = 2\, q \cdot |I_j| \tag{4.122}
$$

---

### Auxiliary Equations (Appendix A) -- hyp-Functions

$$
\mathrm{hyp1}(x;\; \epsilon) = \frac{1}{2} \cdot \left(x + \sqrt{x^2 + 4\,\epsilon^2}\right) \tag{A.1}
$$

$$
\mathrm{hyp2}(x;\; x_0,\; \epsilon) = x - \mathrm{hyp1}(x - x_0;\; \epsilon) \tag{A.2}
$$

$$
\mathrm{hyp5}(x;\; x_0,\; \epsilon) = x_0 - \mathrm{hyp1}\!\left(x_0 - x - \frac{\epsilon^2}{x_0};\; \epsilon\right) \tag{A.3}
$$

$\mathrm{hyp1}$ is a smooth lower-clamping function that approaches $\max(x, 0)$ as $\epsilon \to 0$. $\mathrm{hyp2}$ smoothly clamps $x$ from above at $x_0$. $\mathrm{hyp5}$ smoothly clamps $x$ from above at $x_0$ with a different transition shape.

---

## DC Operating Point Outputs

| No. | Name | Unit | Value | Description |
|-----|------|------|-------|-------------|
| 0 | idsatsbot | A | $MULT \cdot AB \cdot I_{DSAT,bot}$ | Total bottom saturation current |
| 1 | idsatssti | A | $MULT \cdot LS \cdot I_{DSAT,sti}$ | Total STI-edge saturation current |
| 2 | idsatsgat | A | $MULT \cdot LG \cdot I_{DSAT,gat}$ | Total gate-edge saturation current |
| 3 | cjosbot | F | $MULT \cdot AB \cdot C_{jo,bot}$ | Total bottom zero-bias capacitance |
| 4 | cjossti | F | $MULT \cdot LS \cdot C_{jo,sti}$ | Total STI-edge zero-bias capacitance |
| 5 | cjosgat | F | $MULT \cdot LG \cdot C_{jo,gat}$ | Total gate-edge zero-bias capacitance |
| 6 | vbisbot | V | $V_{bi,bot}$ | Built-in voltage, bottom |
| 7 | vbissti | V | $V_{bi,sti}$ | Built-in voltage, STI-edge |
| 8 | vbisgat | V | $V_{bi,gat}$ | Built-in voltage, gate-edge |
| 9 | vak | V | $V_{AK}$ | Anode-cathode voltage |
| 10 | cj | F | $cj_{bot} + cj_{sti} + cj_{gat}$ | Total junction capacitance |
| 11 | cjbot | F | $MULT \cdot AB \cdot \partial Q_{j,bot}'/\partial V_{AK}$ | Bottom junction capacitance |
| 12 | cjsti | F | $MULT \cdot LS \cdot \partial Q_{j,sti}'/\partial V_{AK}$ | STI-edge junction capacitance |
| 13 | cjgat | F | $MULT \cdot LG \cdot \partial Q_{j,gat}'/\partial V_{AK}$ | Gate-edge junction capacitance |
| 14 | ij | A | $ij_{bot} + ij_{sti} + ij_{gat}$ | Total junction current |
| 15 | ijbot | A | $MULT \cdot AB \cdot I_{j,bot}'$ | Bottom junction current |
| 16 | ijsti | A | $MULT \cdot LS \cdot I_{j,sti}'$ | STI-edge junction current |
| 17 | ijgat | A | $MULT \cdot LG \cdot I_{j,gat}'$ | Gate-edge junction current |
| 18 | si | A$^2$/Hz | $S_I$ | Junction current noise spectral density |

Note: when SWJUNEXP = 1, ijbot/ijsti/ijgat are all 0; ij is the total Express current.

## Feature Switch-Off Table

| Feature | Bottom off | STI-edge off | Gate-edge off |
|---------|-----------|-------------|--------------|
| Ideal current | IDSATRBOT = 0 | IDSATRSTI = 0 | IDSATRGAT = 0 |
| SRH current | CSRHBOT = 0 | CSRHSTI = 0 | CSRHGAT = 0 |
| TAT current | CTATBOT = 0 | CTATSTI = 0 | CTATGAT = 0 |
| BBT current | CBBTBOT = 0 | CBBTSTI = 0 | CBBTGAT = 0 |
| Breakdown | VBRBOT > 1000 | VBRSTI > 1000 | VBRGAT > 1000 |
| Geometry | AB = 0 | LS = 0 | LG = 0 |
