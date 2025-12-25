# Diode CMC 3.0 -- Parameter & Equation Reference

> Junction diode (JUNCAP2 200.5 base) + Diode\_CMC extensions (series resistance, ideality factor, flicker noise, transit time, breakdown temperature coefficients, geometry checks) + Hiroshima University recovery model (NQS carrier dynamics, high-injection emission)

## Model Topology

The Diode\_CMC v3.0 is a two-terminal device (`a`, `k`) with an internal series-resistance node `aik` splitting the anode branch into a junction branch (`a` to `aik`) and a resistor branch (`aik` to `k`). Three additional internal NQS nodes (`charge_a`, `charge_k`, `depl_a`) implement RC low-pass filters for the dynamic excess-carrier distribution and depletion-width dynamics of the recovery model. The junction branch carries the sum of bottom-area, STI-edge, and gate-edge components, each contributing depletion charge, ideal current, SRH current, trap-assisted tunneling current, band-to-band tunneling current, and avalanche breakdown multiplication.

---

## Physical Constants

| Symbol | Value | Unit | Description |
|--------|-------|------|-------------|
| $T_0$ | 273.15 | K | Kelvin offset |
| $k_B$ | 1.3806505e-23 | J/K | Boltzmann constant |
| $q$ | 1.6021918e-19 | C | Elementary charge |
| $\hbar$ | 1.05457168e-34 | J s | Reduced Planck constant |
| $m_0$ | 9.1093826e-31 | kg | Electron rest mass |
| $\varepsilon_0$ | 8.8541878176e-12 | F/m | Permittivity of vacuum |
| $\varepsilon_{r,Si}$ | 11.8 | -- | Relative permittivity of silicon |
| $\varepsilon_{Si}$ | $\varepsilon_0 \cdot \varepsilon_{r,Si}$ | F/m | Permittivity of silicon |
| $n_{i0}$ | 1.45e16 | m$^{-3}$ | Intrinsic carrier density at 300 K |
| $\mu_{n0}$ | 1450e-4 | m$^2$/(V s) | Bulk electron mobility |
| $\mu_{p0}$ | 500e-4 | m$^2$/(V s) | Bulk hole mobility |
| $\varphi_{bi}$ | 0.6 | V | Built-in potential of P/N junction (recovery model) |

## Model Constants

| Symbol | Value | Unit | Description |
|--------|-------|------|-------------|
| $T_{min}$ | -250 | C | Minimum temperature for model equations |
| $V_{bi,low}$ | 0.050 | V | Lower boundary for built-in voltage |
| $a$ | 2 | -- | Upper-limit factor for forward capacitance ($a \cdot C_{jo}$) |
| $\varepsilon_{ch}$ | 0.1 | -- | Smoothing constant for charge model |
| $\Delta V_{bi}$ | 0.050 | V | Voltage difference used in BBT model |
| $\varepsilon_{av}$ | 1e-6 | -- | Smoothing constant for effective voltage in avalanche model |
| $V_{br,max}$ | 1e6 | V | Upper limit for VBR; above this, avalanche model is off |
| $V_{max,large}$ | 1e8 | V | Value assigned to $V_{max}$ when $I_{DSAT}$ is zero |
| $a_{erfc}$ | 0.29214664 | -- | Parameter in erfc approximation |
| $p_{erfc}$ | $\sqrt{\pi} \cdot a_{erfc}$ | -- | Parameter in erfc approximation |
| $b_{erfc}$ | $(6 - 5 a_{erfc} - p_{erfc}^{-2})/3$ | -- | Parameter in erfc approximation |
| $c_{erfc}$ | $1 - a_{erfc} - b_{erfc}$ | -- | Parameter in erfc approximation |

---

## Parameters

### Version Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| level | -- | 2002 | -- | Model level (must be 2002) |
| version | -- | 3 | -- | Model version |
| subversion | -- | 0 | -- | Model subversion |
| revision | -- | 0 | -- | Model revision |

### Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ab | m$^2$ | 1e-12 | [0, inf) | Junction area |
| ls | m | 1e-6 | [0, inf) | STI-edge part of junction perimeter |
| lg | m | 0 | [0, inf) | Gate-edge part of junction perimeter |
| dta | C | 0.0 | no bounds | Temperature offset w.r.t. ambient temperature |

Instance parameter aliases: `area` = `ab`, `perim` = `ls`, `pj` = `ls`, `dtemp` = `dta`, `trise` = `dta`, `pt` = `xti`.

### General Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| minr | Ohm | simparam("minr", 1e-3) | [0, inf) | Minimum resistance (node collapse threshold) |
| imax | A | 1000.0 | [1e-12, inf) | Maximum current up to which forward current behaves exponentially |
| trj | C | 21.0 | [-250, inf) | Reference temperature |
| frev | -- | 1e3 | [1e3, 1e10] | Coefficient for reverse breakdown current limitation |
| swbv | -- | 1.0 | [0, 1] | Flag to enable breakdown (1=enabled, 0=disabled) |
| swjunexp | -- | 0.0 | [0, 1] | Flag for JUNCAP Express (0=full model, 1=express) |
| xti | -- | 3.0 | [0.1, inf) | Temperature coefficient of saturation current |
| scale | -- | 1.0 | [0, 1] | Scale parameter for geometry |
| shrink | -- | 0.0 | [0, 100] | Shrink parameter (percent) |
| expceil | -- | 1e20 | [1.0, inf) | Safety valve against carrier concentration explosion |

Alias: `bv_enable` = `swbv`.

### Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| cjorbot | F/m$^2$ | 1e-3 | [1e-12, inf) | Zero-bias capacitance per unit-of-area of bottom component |
| cjorsti | F/m | 1e-9 | [1e-18, inf) | Zero-bias capacitance per unit-of-length of STI-edge component |
| cjorgat | F/m | 1e-9 | [1e-18, inf) | Zero-bias capacitance per unit-of-length of gate-edge component |
| vbirbot | V | 1.0 | [0.05, inf) | Built-in voltage at reference temperature of bottom component |
| vbirsti | V | 1.0 | [0.05, inf) | Built-in voltage at reference temperature of STI-edge component |
| vbirgat | V | 1.0 | [0.05, inf) | Built-in voltage at reference temperature of gate-edge component |
| pbot | -- | 0.5 | [0.05, 0.95] | Grading coefficient of bottom component |
| psti | -- | 0.5 | [0.05, 0.95] | Grading coefficient of STI-edge component |
| pgat | -- | 0.5 | [0.05, 0.95] | Grading coefficient of gate-edge component |

### Ideal-Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| phigbot | V | 1.16 | no bounds | Zero-temperature bandgap voltage of bottom component |
| phigsti | V | 1.16 | no bounds | Zero-temperature bandgap voltage of STI-edge component |
| phiggat | V | 1.16 | no bounds | Zero-temperature bandgap voltage of gate-edge component |
| idsatrbot | A/m$^2$ | 1e-12 | [0, inf) | Saturation current density at reference temperature of bottom component |
| idsatrsti | A/m | 1e-18 | [0, inf) | Saturation current density at reference temperature of STI-edge component |
| idsatrgat | A/m | 1e-18 | [0, inf) | Saturation current density at reference temperature of gate-edge component |
| nfabot | -- | 1.0 | [0.1, inf) | Ideality factor of bottom component |
| nfasti | -- | 1.0 | [0.1, inf) | Ideality factor of STI-edge component |
| nfagat | -- | 1.0 | [0.1, inf) | Ideality factor of gate-edge component |

### Shockley-Read-Hall Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| csrhbot | A/m$^3$ | 1e2 | [0, inf) | SRH prefactor of bottom component |
| csrhsti | A/m$^2$ | 1e-4 | [0, inf) | SRH prefactor of STI-edge component |
| csrhgat | A/m$^2$ | 1e-4 | [0, inf) | SRH prefactor of gate-edge component |
| xjunsti | m | 1e-7 | [1e-9, inf) | Junction depth of STI-edge component |
| xjungat | m | 1e-7 | [1e-9, inf) | Junction depth of gate-edge component |

### Trap-Assisted Tunneling Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ctatbot | A/m$^3$ | 1e2 | [0, inf) | TAT prefactor of bottom component |
| ctatsti | A/m$^2$ | 1e-4 | [0, inf) | TAT prefactor of STI-edge component |
| ctatgat | A/m$^2$ | 1e-4 | [0, inf) | TAT prefactor of gate-edge component |
| mefftatbot | -- | 0.25 | [0.01, inf) | Relative effective mass for TAT of bottom component |
| mefftatsti | -- | 0.25 | [0.01, inf) | Relative effective mass for TAT of STI-edge component |
| mefftatgat | -- | 0.25 | [0.01, inf) | Relative effective mass for TAT of gate-edge component |

### Band-to-Band Tunneling Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| cbbtbot | A V$^{-3}$ | 1e-12 | [0, inf) | BBT prefactor of bottom component |
| cbbtsti | A V$^{-3}$ m | 1e-18 | [0, inf) | BBT prefactor of STI-edge component |
| cbbtgat | A V$^{-3}$ m | 1e-18 | [0, inf) | BBT prefactor of gate-edge component |
| fbbtrbot | V/m | 1e9 | no bounds | Normalization field at reference temperature for BBT of bottom component |
| fbbtrsti | V/m | 1e9 | no bounds | Normalization field at reference temperature for BBT of STI-edge component |
| fbbtrgat | V/m | 1e9 | no bounds | Normalization field at reference temperature for BBT of gate-edge component |
| stfbbtbot | K$^{-1}$ | -1e-3 | no bounds | Temperature scaling parameter for BBT of bottom component |
| stfbbtsti | K$^{-1}$ | -1e-3 | no bounds | Temperature scaling parameter for BBT of STI-edge component |
| stfbbtgat | K$^{-1}$ | -1e-3 | no bounds | Temperature scaling parameter for BBT of gate-edge component |

### Avalanche and Breakdown Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| vbrbot | V | 10.0 | [0.1, inf) | Breakdown voltage of bottom component |
| vbrsti | V | 10.0 | [0.1, inf) | Breakdown voltage of STI-edge component |
| vbrgat | V | 10.0 | [0.1, inf) | Breakdown voltage of gate-edge component |
| pbrbot | V | 4.0 | [0.1, inf) | Breakdown onset tuning parameter of bottom component |
| pbrsti | V | 4.0 | [0.1, inf) | Breakdown onset tuning parameter of STI-edge component |
| pbrgat | V | 4.0 | [0.1, inf) | Breakdown onset tuning parameter of gate-edge component |
| stvbrbot1 | K$^{-1}$ | 0.0 | no bounds | Temperature coefficient of breakdown voltage (1st order) of bottom component |
| stvbrbot2 | K$^{-2}$ | 0.0 | no bounds | Temperature coefficient of breakdown voltage (2nd order) of bottom component |
| stvbrsti1 | K$^{-1}$ | 0.0 | no bounds | Temperature coefficient of breakdown voltage (1st order) of STI-edge component |
| stvbrsti2 | K$^{-2}$ | 0.0 | no bounds | Temperature coefficient of breakdown voltage (2nd order) of STI-edge component |
| stvbrgat1 | K$^{-1}$ | 0.0 | no bounds | Temperature coefficient of breakdown voltage (1st order) of gate-edge component |
| stvbrgat2 | K$^{-2}$ | 0.0 | no bounds | Temperature coefficient of breakdown voltage (2nd order) of gate-edge component |

### Series Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| rsbot | V A$^{-1}$ m$^2$ | 0.0 | [0, inf) | Series resistance per unit-of-area of bottom component |
| rssti | V A$^{-1}$ m | 0.0 | [0, inf) | Series resistance per unit-of-length of STI-edge component |
| rsgat | V A$^{-1}$ m | 0.0 | [0, inf) | Series resistance per unit-of-length of gate-edge component |
| rscom | V A$^{-1}$ | 0.0 | [0, inf) | Common series resistance (no scaling) |
| strs | -- | 0.0 | [0, inf) | Temperature scaling parameter for series resistance |

### Noise Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| kf | -- | 0.0 | [0, inf) | Flicker noise coefficient |
| af | -- | 1.0 | [0.1, inf) | Flicker noise exponent |

### Transit Time Parameter

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| tt | s | 0.0 | [0, inf) | Transit time (diffusion capacitance; overridden to 0 when corecovery=1) |

### Geometry Checking Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| abmin | m$^2$ | 0.0 | [0, inf) | Minimum allowed junction area |
| abmax | m$^2$ | 1.0 | [0, inf) | Maximum allowed junction area |
| lsmin | m | 0.0 | [0, inf) | Minimum allowed STI-edge perimeter |
| lsmax | m | 1.0 | [0, inf) | Maximum allowed STI-edge perimeter |
| lgmin | m | 0.0 | [0, inf) | Minimum allowed gate-edge perimeter |
| lgmax | m | 1.0 | [0, inf) | Maximum allowed gate-edge perimeter |
| tempmin | C | -55 | [-250, inf) | Minimum allowed junction temperature |
| tempmax | C | 155 | [-250, inf) | Maximum allowed junction temperature |
| vfmax | V | 0.0 | [0, inf) | Maximum allowed forward junction bias |
| vrmax | V | 0.0 | [0, inf) | Maximum allowed reverse junction bias |

### JUNCAP Express Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| vjunref | V | 2.5 | [0.5, inf) | Typical maximum junction voltage (usually ~2 $\cdot V_{sup}$) |
| fjunq | -- | 0.03 | [0, inf) | Fraction below which junction capacitance components are neglected |

### Recovery and High-Injection Parameters (Hiroshima model)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| corecovery | -- | 0 | [0, 1] | Flag for recovery equations (0=original TT model, 1=Hiroshima model) |
| tnom | C | 21 | [-250, inf) | Alias reference temperature for trj |
| njh | -- | 1.0 | [0.5, 5] | High-injection emission coefficient |
| njdv | V$^{-1}$ | 0.1 | [0, 1e6] | Transition slope of emission coefficient |
| ndibot | cm$^{-3}$ | 1e16 | [1, 1e23] | Doping concentration of drift region (bottom) |
| ndisti | cm$^{-3}$ | 1e16 | [1, 1e23] | Doping concentration of drift region (STI-edge) |
| ndigat | cm$^{-3}$ | 1e16 | [1, 1e23] | Doping concentration of drift region (gate-edge) |
| inj1 | -- | 1.0 | [0, 3] | Factor for recovery charge density |
| inj2 | V$^{-2}$ | 10.0 | [0, 50] | Voltage dependence of recovery charge density (high injection) |
| nqs | s | 5e-9 | [0, 1e-3] | Carrier delay time |
| tau | s | 2e-7 | [1e-12, 1e-3] | Carrier lifetime |
| wi | m | 5e-6 | [0, 1.0] | Length of drift region |
| depnqs | s | 0.0 | [0, 1e-3] | Depletion delay time |
| taut | -- | 0.0 | [0, 100] | Temperature coefficient of carrier lifetime |
| injt | -- | 0.0 | [0, 20] | Temperature coefficient of carrier density in high-injection condition |

**Total parameter count: 4 version + 4 instance + 10 general + 9 capacitance + 9 ideal-current + 5 SRH + 6 TAT + 9 BBT + 12 avalanche/breakdown + 5 series resistance + 2 noise + 1 transit time + 10 geometry check + 2 express + 15 recovery = 103 parameters** (plus 6 aliases).

---

## Equations

All equations below use a generic notation where the subscript `x` stands for `bot` (bottom), `sti` (STI-edge), or `gat` (gate-edge). The same functional form is evaluated three times, once per geometrical component, with the appropriate per-component parameter values.

### Auxiliary Smoothing Functions

$$
\text{hyp1}(x;\, \varepsilon) = \frac{1}{2}\left(x + \sqrt{x^2 + 4\varepsilon^2}\right)
$$

Smooth approximation to $\max(x, 0)$.

$$
\text{hyp2}(x;\, x_0,\, \varepsilon) = x - \text{hyp1}(x - x_0;\, \varepsilon)
$$

Smooth approximation to $\min(x, x_0)$.

$$
\text{hyp5}(x;\, x_0,\, \varepsilon) = x_0 - \text{hyp1}\!\left(x_0 - x - \frac{\varepsilon^2}{x_0};\, \varepsilon\right)
$$

Smooth approximation to $\min(x, x_0)$ with improved behavior near $x_0$.

$$
\text{smoothUpper}(x,\, x_{max},\, \delta): \quad y = x_{max} - \frac{1}{2}\!\left(f_1 + \sqrt{f_1^2 + |4\,x_{max}\,\delta|}\right), \quad f_1 = x_{max} - x - \delta
$$

$$
\text{smoothLower}(x,\, x_{min},\, \delta): \quad y = x_{min} + \frac{1}{2}\!\left(f_1 + \sqrt{f_1^2 + |4\,x_{min}\,\delta|}\right), \quad f_1 = x - x_{min} - \delta
$$

$$
\text{smoothZero}(x,\, \delta): \quad y = \frac{1}{2}\!\left(x + \sqrt{x^2 + 4\delta^2}\right)
$$

These are used in the recovery model to clip $n_j$ within $[\text{NFA}, \text{NJH}]$.

### Safe Exponential Function

$$
\text{expl}(x) = \begin{cases}
\dfrac{k_{e05}}{P_3(-s_{e05} - x)} & \text{if } x < -s_{e05} \\[6pt]
\exp(x) & \text{if } |x| < s_{e05} \\[6pt]
k_{e05}^{-1} \cdot P_3(x - s_{e05}) & \text{if } x > s_{e05}
\end{cases}
$$

where $s_{e05} = \ln(10^{100}) \approx 230.26$, $k_{e05} = 10^{-100}$, and $P_3(u) = 1 + u(1 + \tfrac{1}{2}u(1 + \tfrac{1}{3}u))$.

---

### Thermal Voltage and Temperature

$$
T_{KR} = T_0 + \text{TRJ} \tag{4.1}
$$

$$
T_{KD} = T_0 + \max(T_A + \text{DTA},\; T_{min}) \tag{4.2}
$$

$$
\phi_{TR} = \frac{k_B \cdot T_{KR}}{q} \tag{4.3}
$$

$$
\phi_{TD} = \frac{k_B \cdot T_{KD}}{q} \tag{4.4}
$$

### Bandgap Voltage

$$
\Delta\phi_{GR} = -\frac{7.02 \times 10^{-4} \cdot T_{KR}^2}{1108.0 + T_{KR}} \tag{4.5}
$$

$$
\phi_{GR,x} = \text{PHIG}_x + \Delta\phi_{GR} \tag{4.6--4.8}
$$

$$
\Delta\phi_{GD} = -\frac{7.02 \times 10^{-4} \cdot T_{KD}^2}{1108.0 + T_{KD}} \tag{4.9}
$$

$$
\phi_{GD,x} = \text{PHIG}_x + \Delta\phi_{GD} \tag{4.10--4.12}
$$

### Intrinsic Carrier Concentration Ratio

The Diode\_CMC v3.0 generalizes the JUNCAP2 $F_{TD}$ by including both the XTI parameter and the ideality factor NFA:

$$
F_{TD,x} = \left(\frac{T_{KD}}{T_{KR}}\right)^{\!\text{XTI}/2} \cdot \exp\!\left(\frac{\phi_{GR,x}}{2\,\phi_{TR}} - \frac{\phi_{GD,x}}{2\,\phi_{TD}}\right) \tag{4.13--4.15}
$$

For use with ideality factor $\neq 1$ (recovery/high-injection model):

$$
F_{TD2,x} = \left(\frac{T_{KD}}{T_{KR}}\right)^{\!\text{XTI}/(2\,\text{NFA}_x)} \cdot \exp\!\left(\frac{1}{2\,\text{NFA}_x}\left(\frac{\phi_{GR,x}}{\phi_{TR}} - \frac{\phi_{GD,x}}{\phi_{TD}}\right)\right)
$$

### Saturation Current Density at Device Temperature

$$
I_{DSAT,x} = \text{IDSATR}_x \cdot F_{TD2,x}^{\,2} \tag{4.16--4.18}
$$

### Determination of $V_{max}$

$$
V_{max,x} = \begin{cases}
V_{max,large} & \text{if } I_{DSAT,x} \cdot G_x = 0 \\[4pt]
\phi_{TD} \cdot \text{NFA}_x \cdot \ln\!\left(\dfrac{\text{IMAX}}{I_{DSAT,x} \cdot G_x} + 1\right) & \text{otherwise}
\end{cases} \tag{4.19--4.21}
$$

where $G_{bot} = \text{AB}$, $G_{sti} = \text{LS}$, $G_{gat} = \text{LG}$.

$$
V_{max} = \min(V_{max,bot},\; V_{max,sti},\; V_{max,gat}) \tag{4.22}
$$

### Built-in Voltages

$$
U_{bi,x} = \text{VBIR}_x \cdot \frac{T_{KD}}{T_{KR}} - 2\,\phi_{TD}\,\ln F_{TD,x} \tag{4.23, 4.25, 4.27}
$$

$$
V_{bi,x} = U_{bi,x} + \phi_{TD}\,\ln\!\left(1 + \exp\!\left(\frac{V_{bi,low} - U_{bi,x}}{\phi_{TD}}\right)\right) \tag{4.24, 4.26, 4.28}
$$

### Forward Voltage Limits

$$
V_{bi,min} = \min(V_{bi,bot},\; V_{bi,sti},\; V_{bi,gat}) \tag{4.29}
$$

(only active components considered; e.g., if $\text{AB}=0$, $V_{bi,bot}$ is excluded)

$$
V_{F,min} = V_{bi,min}\!\left(1 - a^{-1/P_{max}}\right) \tag{4.30}
$$

where $P_{max}$ is the grading coefficient of the component whose $V_{bi}$ equals $V_{bi,min}$.

$$
V_{ch} = \varepsilon_{ch} \cdot V_{bi,min} \tag{4.31}
$$

### Avalanche Parameter

$$
\alpha_{av} = 1 - \frac{1}{\text{FREV}} = \frac{\text{FREV} - 1}{\text{FREV}} \tag{4.32}
$$

### Breakdown Voltage Temperature Scaling (Diode\_CMC extension)

$$
\text{VBR}_x(T) = \text{VBR}_x(T_{RJ}) \cdot \left[1 + (T_{KD} - T_{KR})\left(\text{STVBR}_{x,1} + (T_{KD} - T_{KR}) \cdot \text{STVBR}_{x,2}\right)\right]
$$

### Series Resistance (Diode\_CMC extension)

Temperature-scaled component resistances:

$$
R_{x} = \text{RS}_x \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\!\text{STRS}}
$$

Geometry scaling (conductance sum):

$$
G = \frac{\text{AB}}{R_{bot}} + \frac{\text{LS}}{R_{sti}} + \frac{\text{LG}}{R_{gat}}
$$

$$
R_{total} = \begin{cases}
\dfrac{1}{G} + R_{com} & \text{if } G > 0 \\[4pt]
R_{com} & \text{otherwise}
\end{cases}
$$

If $R_{total} > 0$ and $R_{total} \geq \text{minr}$, the internal node `aik` carries the resistor branch $I = V_{RS}/R_{total}$. Otherwise the node is collapsed ($V(\text{aik},k) = 0$).

### Geometry Scaling with Shrink

$$
L_{shrink} = 1 - 0.01 \cdot \text{SHRINK}
$$

$$
\text{AB}_i = \text{ab} \cdot \text{SCALE}^2 \cdot L_{shrink}^2, \quad \text{LS}_i = \text{ls} \cdot \text{SCALE} \cdot L_{shrink}, \quad \text{LG}_i = \text{lg} \cdot \text{SCALE} \cdot L_{shrink}
$$

---

### Zero-Bias Capacitance at Device Temperature

$$
C_{jo,x} = \text{CJOR}_x \cdot \left(\frac{\text{VBIR}_x}{V_{bi,x}}\right)^{P_x} \tag{4.33}
$$

### Junction Charge (per component)

$$
V_j = \text{hyp5}(V_{AK};\; V_{F,min},\; V_{ch}) \tag{4.34}
$$

$$
Q'_{j,x} = \frac{C_{jo,x} \cdot V_{bi,x}}{1 - P_x}\left[1 - \left(1 - \frac{V_j}{V_{bi,x}}\right)^{1-P_x}\right] + a \cdot C_{jo,x} \cdot (V_{AK} - V_j) \tag{4.35}
$$

### Ideal Current (per component, with high-injection and ideality factor)

For $V_{AK} < V_{max}$:

$$
z_{inv} = \sqrt{\exp\!\left(\frac{V_{AK}}{2\,\phi_{TD}}\right)}, \qquad z = 1/z_{inv}
$$

$$
M_{ID,x} = \exp\!\left(\frac{1}{\phi_{TD}}\left(\frac{V_{AK}}{n_{jA,x}} + V_{HA,x} \cdot \frac{n_{jA,x} - \text{NFA}_x}{\text{NFA}_x \cdot \text{NJH}}\right)\right) \tag{2a}
$$

For $V_{AK} \geq V_{max}$, the current is linearized:

$$
M_{ID,x} = \left(1 + (V_{AK} - V_{max}) \cdot \frac{dV_{max,eff}}{dV_{AK}}\Big|_{V_{max}}\right) \cdot \exp\!\left(\frac{1}{\phi_{TD}}\left(\frac{V_{max}}{n_{jA,x}(V_{max})} + V_{HA,x} \cdot \frac{n_{jA,x}(V_{max}) - \text{NFA}_x}{\text{NFA}_x \cdot \text{NJH}}\right)\right) \tag{2b}
$$

$$
I'_{D,x} = (M_{ID,x} - 1) \cdot I_{DSAT,x} \tag{4.37}
$$

#### Bias-Dependent Emission Coefficient

$$
n_{jA,x}(V_{AK}) = \text{NJDV} \cdot (V_{AK} - V_{HA,x}) + \text{NFA}_x \tag{4--6}
$$

Clamped within $[\text{NFA}_x,\; \text{NJH}]$ using smoothUpper/smoothLower functions.

#### High-Injection Threshold Voltages

$$
V_{HA,x} = \phi_{TD} \cdot \text{NFA}_x \cdot \ln\!\left(\frac{\text{NDI}_x}{p_{n0,x}}\right) \tag{7--9}
$$

$$
p_{n0,x} = \frac{n_{in}^2}{\text{NDI}_x} \tag{10--12}
$$

$$
n_{in} = n_{i0} \cdot F_{TD2,bot} \tag{13}
$$

The linearization derivative at $V_{max}$:

$$
dV_{max,eff} = \frac{1}{\phi_{TD}}\left(\frac{n_{jA}(V_{max}) - V_{max} \cdot \left.\frac{dn_{jA}}{dV_{AK}}\right|_{V_{max}}}{n_{jA}(V_{max})^2} + V_{HA} \cdot \frac{\left.\frac{dn_{jA}}{dV_{AK}}\right|_{V_{max}}}{\text{NFA} \cdot \text{NJH}}\right) \tag{3}
$$

### Shockley-Read-Hall Current

(Skipped entirely when $\text{CSRH}_x = \text{CTAT}_x = 0$.)

$$
\psi^* = \begin{cases}
\phi_{TD} \cdot \ln\!\left(z + 2 + \sqrt{(z+1)(z+3)}\right) & \text{if } V_{AK} > 0 \\[4pt]
-V_{AK} + \phi_{TD} \cdot \ln\!\left(1 + 2\,z_{inv} + \sqrt{(1+z_{inv})(1+3\,z_{inv})}\right) & \text{if } V_{AK} \leq 0
\end{cases} \tag{4.40}
$$

$$
V_{j,lim} = V_{bi,min} - 2\,\psi^* \tag{4.41}
$$

$$
V_{j,SRH} = \text{hyp2}(V_{AK};\; V_{j,lim},\; \phi_{TD}) \tag{4.42}
$$

$$
w_{SRH,step} = 1 - \sqrt{1 - \frac{2\,\psi^*}{V_{bi,x} - V_{j,SRH}}} \tag{4.43}
$$

$$
\Delta w_{SRH} = \left(\frac{w_{SRH,step}^2 \cdot \ln w_{SRH,step}}{1 - w_{SRH,step}} + w_{SRH,step}\right)(1 - 2P_x) \tag{4.44}
$$

(When $P_x = 0.5$, $\Delta w_{SRH} = 0$.)

$$
w_{SRH} = w_{SRH,step} + \Delta w_{SRH} \tag{4.45}
$$

$$
W_{dep} = \frac{\text{XJUN}_x \cdot \varepsilon_{Si}}{\text{CJOR}_x} \cdot \left(\frac{V_{bi,x} - V_{j,SRH}}{\text{VBIR}_x}\right)^{P_x} \tag{4.46}
$$

(For bottom component, $\text{XJUN} = 1$ so $W_{dep,bot} = \varepsilon_{Si}/\text{CJORBOT} \cdot (\ldots)^{P_{bot}}$.)

$$
I'_{SRH,x} = \text{CSRH}_x \cdot F_{TD,x} \cdot (z_{inv} - 1) \cdot w_{SRH} \cdot W_{dep} \tag{4.47}
$$

### Trap-Assisted Tunneling Current

(Skipped entirely when $\text{CTAT}_x = 0$.)

$$
F_{max} = \frac{V_{bi,x} - V_{j,SRH}}{W_{dep} \cdot (1 - P_x)} \tag{4.48}
$$

$$
m_{eff} = \text{MEFFTAT}_x \cdot m_0 \tag{4.49}
$$

$$
\Delta E = \max\!\left(\frac{\phi_{GD,x}}{2},\; \phi_{TD}\right) \tag{4.50}
$$

$$
a_{TAT} = \frac{\Delta E}{\phi_{TD}} \tag{4.51}
$$

$$
b_{TAT} = \frac{\sqrt{32\,m_{eff}\,q\,(\Delta E)^3}}{3\,\hbar \cdot F_{max}} \tag{4.52}
$$

$$
u'_{max} = \left(\frac{2\,a_{TAT}}{3\,b_{TAT}}\right)^2 \tag{4.53}
$$

$$
u_{max} = \sqrt{\frac{u'^2_{max}}{u'^2_{max} + 1}} \tag{4.54}
$$

$$
w_\Gamma = \left(1 + b_{TAT} \cdot u_{max}^{3/2}\right)^{P_x/(P_x - 1)} \tag{4.55}
$$

$$
w_{TAT} = \frac{w_{SRH} \cdot w_\Gamma}{w_{SRH} + w_\Gamma} \tag{4.56}
$$

$$
k_{TAT} = \sqrt{\frac{3\,b_{TAT}}{8\,\sqrt{u_{max}}}} \tag{4.57}
$$

$$
l_{TAT} = \frac{4\,a_{TAT}}{3\,b_{TAT}} \sqrt{u_{max}} - u_{max} \tag{4.58}
$$

$$
m_{TAT} = \frac{2\,a_{TAT}^2}{3\,b_{TAT}} \sqrt{u_{max}} - a_{TAT}\,u_{max} + \frac{b_{TAT}}{2}\,u_{max}^{3/2} \tag{4.59}
$$

#### Erfc Approximation

$$
t_{erfc} = \begin{cases}
\dfrac{1}{1 + p_{erfc} \cdot y} & \text{if } y > 0 \\[6pt]
\dfrac{1}{1 - p_{erfc} \cdot y} & \text{if } y \leq 0
\end{cases} \tag{4.60}
$$

$$
\text{erfcapprox}^+(y) = \left(a_{erfc}\,t_{erfc} + b_{erfc}\,t_{erfc}^2 + c_{erfc}\,t_{erfc}^3\right) \cdot e^{-y^2}
$$

$$
\text{erfcapprox}(y) = \begin{cases}
\text{erfcapprox}^+(y) & \text{if } y > 0 \\
2 - \text{erfcapprox}^+(y) & \text{if } y \leq 0
\end{cases}
$$

Combined erfc-times-exp computation used in TAT:

$$
\text{calcerfcexpmtat}(y, m) = \begin{cases}
\left(a_{erfc}\,t + b_{erfc}\,t^2 + c_{erfc}\,t^3\right) \cdot \exp(-y^2 + m) & y > 0 \\
2\exp(m) - \text{above} & y \leq 0
\end{cases}
$$

$$
\Gamma_{max} = \frac{\sqrt{\pi}}{2} \cdot \frac{a_{TAT} \cdot \text{calcerfcexpmtat}(k_{TAT}(l_{TAT}-1),\; m_{TAT})}{k_{TAT}} \tag{4.61}
$$

$$
I'_{TAT,x} = \text{CTAT}_x \cdot F_{TD,x} \cdot (z_{inv} - 1) \cdot \Gamma_{max} \cdot w_{TAT} \cdot W_{dep} \tag{4.62}
$$

### Band-to-Band Tunneling Current

(Skipped entirely when $\text{CBBT}_x = 0$.)

$$
V_{BBT,lim} = \min(\text{VBIRBOT},\; \text{VBIRSTI},\; \text{VBIRGAT}) - \Delta V_{bi} \tag{4.63}
$$

$$
V_{BBT} = \text{hyp2}(V_{AK};\; V_{BBT,lim},\; \phi_{TR}) \tag{4.64}
$$

$$
W_{dep,r} = \frac{\text{XJUN}_x \cdot \varepsilon_{Si}}{\text{CJOR}_x} \cdot \left(\frac{\text{VBIR}_x - V_{BBT}}{\text{VBIR}_x}\right)^{P_x} \tag{4.65}
$$

$$
F_{max,r} = \frac{\text{VBIR}_x - V_{BBT}}{W_{dep,r} \cdot (1 - P_x)} \tag{4.66}
$$

$$
F_{BBT} = \text{FBBTR}_x \cdot \left[1 + \text{STFBBT}_x \cdot (T_{KD} - T_{KR})\right] \tag{4.67}
$$

$$
I'_{BBT,x} = \text{CBBT}_x \cdot V_{AK} \cdot F_{max,r}^2 \cdot \exp\!\left(-\frac{F_{BBT}}{F_{max,r}}\right) \tag{4.68}
$$

### Avalanche and Breakdown

(Skipped when $\text{VBR}_x > V_{br,max}$ or $\text{swbv} = 0$; $f_{breakdown} = 1$ in that case.)

$$
V_{av} = \text{hyp2}(V_{AK};\; 0,\; \varepsilon_{av}) \tag{4.69}
$$

$$
f_{stop} = \frac{1}{1 - \alpha_{av}^{PBR_x}} \tag{4.70}
$$

$$
s_f = -f_{stop}^2 \cdot \alpha_{av}^{PBR_x - 1} \cdot \frac{PBR_x}{VBR_x} \tag{4.71}
$$

$$
f_{breakdown} = \begin{cases}
\dfrac{1}{1 - \left|\dfrac{V_{av}}{VBR_x}\right|^{PBR_x}} & \text{if } V_{av} > -\alpha_{av} \cdot VBR_x \\[10pt]
f_{stop} + (V_{av} + \alpha_{av} \cdot VBR_x) \cdot s_f & \text{if } V_{av} \leq -\alpha_{av} \cdot VBR_x
\end{cases} \tag{4.72}
$$

### Total Current per Component

$$
I'_{j,x} = \left(I'_{D,x} + I'_{SRH,x} + I'_{TAT,x} + I'_{BBT,x}\right) \cdot f_{breakdown,x} \tag{4.73}
$$

### Geometrical Assembly

$$
V_{AK} = V(a) - V(aik) \tag{4.74}
$$

$$
Q_j = \text{AB} \cdot Q'_{j,bot} + \text{LS} \cdot Q'_{j,sti} + \text{LG} \cdot Q'_{j,gat} \tag{4.78}
$$

$$
I_j = \text{AB} \cdot I'_{j,bot} + \text{LS} \cdot I'_{j,sti} + \text{LG} \cdot I'_{j,gat} \tag{4.82}
$$

(Note: v3.0 removes the TYPE and MULT multipliers from the external interface; polarity is handled by netlisting.)

---

### Noise Models

#### Shot Noise

$$
S_I^{shot} = 2q\left[(I_{jun} - I_{non}) + 2\,I_{sat,total} + |I_{non}|\right] \tag{4.83 ext}
$$

where $I_{non} = \text{AB} \cdot I_{non,bot} + \text{LS} \cdot I_{non,sti} + \text{LG} \cdot I_{non,gat}$ is the non-ideal (SRH+TAT+BBT) part of the total current, and $I_{sat,total} = \text{AB} \cdot I_{DSAT,bot} + \text{LS} \cdot I_{DSAT,sti} + \text{LG} \cdot I_{DSAT,gat}$.

#### Flicker Noise (Diode\_CMC extension)

$$
S_I^{flicker} = \text{KF} \cdot |I_{jun}|^{\text{AF}} \cdot \frac{1}{f}
$$

#### Thermal Noise of Series Resistance (Diode\_CMC extension)

$$
S_I^{thermal} = \frac{4\,k_B\,T_{KD}}{R_{total}} \quad (\text{if } R_{total} > 0 \text{ and } R_{total} \geq \text{minr})
$$

### Diffusion Capacitance (Original TT model, when corecovery=0)

$$
I_{diffusion} = \text{TT} \cdot \frac{d(I_{jun} - I_{non})}{dt}
$$

---

### Recovery Model (Hiroshima, corecovery=1)

When `corecovery=1`, the transit-time parameter `tt` is set to zero and the full NQS carrier-dynamics model is used instead.

#### Diffusion Coefficients (temperature-dependent)

$$
T_1 = \left(\frac{T_{KD}}{T_{KR}}\right)^{-1.5} \tag{phonon scattering}
$$

$$
D_n = \phi_{TD} \cdot \mu_{n0} \cdot T_1 \tag{29}
$$

$$
D_p = \phi_{TD} \cdot \mu_{p0} \cdot T_1 \tag{30}
$$

$$
D_a = \frac{2\,D_n\,D_p}{D_n + D_p} \tag{28}
$$

#### Carrier Lifetime and Diffusion Length

$$
\tau_{HL} = \text{TAU} \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\!\text{TAUT}} \tag{27}
$$

$$
L_a = \sqrt{\tau_{HL} \cdot D_a} \tag{26}
$$

#### High-Injection Threshold Voltages

$$
V_{HA} = \phi_{TD} \cdot \text{NFA}_{bot} \cdot \ln\!\left(\frac{\text{NDI}_{bot}}{p_{n0}}\right) \tag{7}
$$

$$
V_{HK} = \phi_{TD} \cdot \text{NFA}_{bot} \cdot \left(\ln\!\left(\frac{\text{NDI}_{bot}}{p_{n0}}\right) + \frac{\text{WI}}{L_a}\right) \tag{25}
$$

#### Cathode-Side Emission Coefficient

$$
n_{jK} = \text{NJDV} \cdot (V_{AK} - V_{HK}) + \text{NFA}_{bot} \tag{24}
$$

Clamped to $[\text{NFA}_{bot},\; \text{NJH}]$.

#### Exponential Quantities

$$
\text{exp}_A = M_{ID,bot} \quad \text{(from the DC ideal-current model)} \tag{22}
$$

$$
\text{exp}_K = \exp\!\left(\frac{1}{\phi_{TD}}\left(\frac{V_{AK}}{n_{jK}} - \frac{V_{HK} - V_{HA}}{n_{jK}} + \frac{V_{HK}(n_{jK} - \text{NFA}_{bot})}{\text{NFA}_{bot} \cdot \text{NJH}}\right)\right) \tag{23}
$$

#### Injected Carrier Densities

Anode-side:

$$
q_{pexA} = q \cdot \text{AB} \cdot \left(p_{n0} \cdot \text{exp}_A \cdot \text{INJ1} \cdot \exp\!\left(-\text{INJ2}\,(V_{AK} - V_{HA})^2 \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{\!\text{INJT}}\right) - p_{n0}\right) \tag{20}
$$

Cathode-side:

$$
q_{pexK} = q \cdot \text{AB} \cdot \left(p_{n0} \cdot \text{exp}_K \cdot \text{INJ1} \cdot \exp\!\left(-\text{INJ2}\,(V_{AK} - V_{HK})^2 \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{\!\text{INJT}}\right) - p_{n0}\right) \tag{21}
$$

(The exponential product is clamped to `expceil` for numerical safety. When $\text{INJ2} = 0$ or $V_{AK} < V_{HA/HK}$, the $\exp(-\text{INJ2}\ldots)$ factor is omitted.)

#### Depletion Width

$$
W_{depA} = \sqrt{\frac{2\,\varepsilon_{Si}\,(\varphi_{bi} - V_{AK})}{q \cdot \text{NDI}_{bot}}} \tag{31}
$$

where $\varphi_{bi} = 0.6$ V (in v3.0 replaced by `vbirbot_i` for consistency). The result is clamped to $\leq \text{WI}$ via smoothUpper with $\delta = 10^{-7}$.

#### NQS Equations for Anode-Side Excess Carriers

Discrete-time form (for understanding):

$$
q_{pexA,nqs} = q_{pexA,nqs,prev} + \frac{\Delta t}{\text{NQS} + \Delta t}(q_{pexA} - q_{pexA,nqs,prev}) \tag{32}
$$

Differential-equation form implemented as an RC circuit on node `charge_a`:

$$
\frac{q_{pexA}}{\text{NQS}} = \frac{q_{pexA,nqs}}{\text{NQS}} + \frac{d(q_{pexA,nqs})}{dt} \tag{33}
$$

$$
q_{pexA,nqs} = V(\text{charge\_a}) \tag{34}
$$

$$
I(\text{charge\_a}) = \frac{q_{pexA,nqs} - q_{pexA}}{\text{NQS}} + \frac{d(q_{pexA,nqs})}{dt} \tag{35}
$$

#### NQS Equations for Cathode-Side Excess Carriers

$$
q_{pexK,nqs} = V(\text{charge\_k}) \tag{38}
$$

$$
I(\text{charge\_k}) = \frac{q_{pexK,nqs} - q_{pexK}}{\text{NQS}} + \frac{d(q_{pexK,nqs})}{dt} \tag{39}
$$

#### NQS Equation for Depletion Width

$$
W_{depA,nqs} = V(\text{depl\_a}) \tag{42}
$$

$$
I(\text{depl\_a}) = \frac{W_{depA,nqs} - W_{depA}}{\text{DEPNQS}} + \frac{d(W_{depA,nqs})}{dt} \tag{43}
$$

(When $\text{NQS} = 0$, the quasi-static value is used directly: $q_{pexA,nqs} = q_{pexA}$. When $\text{DEPNQS} = 0$, $W_{depA,nqs} = W_{depA}$.)

#### NQS Node Scaling (v3.0)

To bring internal-node potentials/flows to the same order of magnitude as electrical quantities:

| Factor | For nodes | Value |
|--------|-----------|-------|
| QC\_scale | charge\_a, charge\_k (flow) | 1e-12 |
| Q\_scale | charge\_a, charge\_k (potential) | 1e-23 / $q_{pex0}$ |
| WC\_scale | depl\_a (flow) | 1e-13 |
| W\_scale | depl\_a (potential) | 1 / $W_{depA0}$ |

where $q_{pex0} = q \cdot \text{AB}$ and $W_{depA0} = \sqrt{2\varepsilon_{Si}/(q \cdot \text{NDI})}$ (clamped to $\leq$ WI).

#### Recovery Charge Components

Equilibrium electron charge:

$$
Q_{n0} = -\text{AB} \cdot q \cdot \text{NDI}_{bot} \cdot \text{WI} \tag{17}
$$

Excess charge from anode:

$$
Q_{nexA,nqs} = -L_a \cdot q_{pexA,nqs} \cdot \left(\exp\!\left(-\frac{W_{depA,nqs}}{L_a}\right) - \exp\!\left(-\frac{\text{WI}}{L_a}\right)\right) \tag{18}
$$

Excess charge from cathode:

$$
Q_{nexK,nqs} = -L_a \cdot q_{pexK,nqs} \cdot \left(\exp\!\left(-\frac{\text{WI} - W_{depA,nqs}}{L_a}\right) - 1\right) \tag{19}
$$

#### Total Recovery Charge

$$
Q_{rr} = -(Q_{n0} + Q_{nexA,nqs} + Q_{nexK,nqs}) \tag{16}
$$

#### Final Junction Charge and Current

$$
Q_j = Q_{j,juncap} + Q_{rr} \tag{15}
$$

$$
I(a, aik) = I_j + \frac{dQ_j}{dt} \tag{14}
$$

---

### JUNCAP Express Model

Activated when `swjunexp = 1`. Replaces the full per-bias current computation with pre-computed exponential fits. Only evaluated during initialization at five sample voltages.

#### Initialization Voltages

$$
V_1 = -0.4 \cdot \text{VJUNREF}, \quad V_2 = -0.65 \cdot \text{VJUNREF}, \quad V_3 = -0.8 \cdot \text{VJUNREF} \tag{4.84--4.86}
$$

$$
V_4 = 0.1, \quad V_5 = 0.2 \tag{4.87--4.88}
$$

$$
I_n = f_{juncap}(V_n) \quad \text{for } n = 1\ldots 5 \tag{4.89}
$$

The generic exponential function:

$$
g(V, I_0, m) = I_0 \cdot [\exp(V \cdot m / \phi_{TD}) - 1] \tag{4.90}
$$

#### Ideal Forward Current Parameters

$$
I_{SATFOR1} = \text{AB} \cdot I_{DSAT,bot} + \text{LS} \cdot I_{DSAT,sti} + \text{LG} \cdot I_{DSAT,gat} \tag{4.91}
$$

$$
M_{FOR1} = \text{NFA} \quad (\text{must be equal for all active components in Express mode}) \tag{4.92}
$$

#### Non-Ideal Forward Current Parameters

$$
I_{4,cor} = I_4 - g(V_4,\; I_{SATFOR1},\; M_{FOR1}) \tag{4.93}
$$

$$
I_{5,cor} = I_5 - g(V_5,\; I_{SATFOR1},\; M_{FOR1}) \tag{4.94}
$$

$$
\alpha_{for} = I_{4,cor} / I_{5,cor} \tag{4.95}
$$

$$
M_{FOR2} = \phi_{TD} \cdot \frac{\ln(\alpha_{for})}{V_4 - V_5} \tag{4.96}
$$

$$
I_{SATFOR2} = \frac{I_{4,cor}}{\exp(V_4 \cdot M_{FOR2} / \phi_{TD}) - 1} \tag{4.97}
$$

#### Reverse Current Parameters

$$
I_{n,cor} = I_n - g(V_n, I_{SATFOR1}, M_{FOR1}) - g(V_n, I_{SATFOR2}, M_{FOR2}) \quad n=1,2,3 \tag{4.98--4.100}
$$

$$
\alpha_{rev} = I_{1,cor} / I_{2,cor} \tag{4.101}
$$

$$
m_0 = \phi_{TD} \cdot \frac{\ln \alpha_{rev}}{V_2 - V_1} \tag{4.102}
$$

$$
\Delta m = \phi_{TD} \cdot \frac{(\alpha_{rev} - 1)(\alpha_{rev}^{V_2/(V_2-V_1)} - 1)}{\alpha_{rev}^{V_1/(V_1-V_2)} \cdot (V_2 - V_1) + \alpha_{rev} \cdot V_1 - V_2} \tag{4.103}
$$

$$
M_{REV} = m_0 + \Delta m \tag{4.104}
$$

$$
I_{SATREV} = \frac{-I_{3,cor}}{\exp(-V_3 \cdot M_{REV}/\phi_{TD}) - 1} \tag{4.105}
$$

#### Express Charge Model Initialization

$$
C_{jo,x} = \text{CJOR}_x \cdot \left(\frac{\text{VBIR}_x}{V_{bi,x}}\right)^{P_x} \tag{4.106--4.108}
$$

$$
Z_{bot} = \text{AB} \cdot C_{jo,bot}, \quad Z_{sti} = \text{LS} \cdot C_{jo,sti}, \quad Z_{gat} = \text{LG} \cdot C_{jo,gat} \tag{4.109--4.111}
$$

$$
Z_{tot} = Z_{bot} + Z_{sti} + Z_{gat} \tag{4.112}
$$

#### Express Current Evaluation (per bias step)

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
I_j = I_{for1} + I_{for2} + I_{rev} \tag{4.116}
$$

(The `expll` safe exponential with linear extrapolation beyond $x_{high}$ is used in implementation.)

#### Express Charge Evaluation (per bias step)

For each component $x$, if $Z_x > \text{FJUNQ} \cdot Z_{tot}$:

$$
V_j = \text{hyp5}(V_{AK};\; V_{F,min},\; V_{ch}) \tag{4.117}
$$

$$
Q'_{j,x} = \frac{C_{jo,x} \cdot V_{bi,x}}{1 - P_x}\left[1 - \left(1 - \frac{V_j}{V_{bi,x}}\right)^{1-P_x}\right] + a \cdot C_{jo,x} \cdot (V_{AK} - V_j) \tag{4.118--4.120}
$$

Otherwise $Q'_{j,x} = 0$.

$$
Q_j = \text{AB} \cdot Q'_{j,bot} + \text{LS} \cdot Q'_{j,sti} + \text{LG} \cdot Q'_{j,gat} \tag{4.121}
$$

#### Express Noise

$$
S_I = 2q \cdot |I_j| \tag{4.122}
$$

---

### DC Operating Point Output Variables

| Name | Unit | Value | Description |
|------|------|-------|-------------|
| vak | V | $V_{AK}$ | Voltage between anode and cathode (excl. series resistor) |
| cj | F | $c_{jbot} + c_{jsti} + c_{jgat}$ | Total junction capacitance |
| cjbot | F | $\text{AB} \cdot \partial Q'_{j,bot}/\partial V_{AK}$ | Bottom component junction capacitance |
| cjsti | F | $\text{LS} \cdot \partial Q'_{j,sti}/\partial V_{AK}$ | STI-edge component junction capacitance |
| cjgat | F | $\text{LG} \cdot \partial Q'_{j,gat}/\partial V_{AK}$ | Gate-edge component junction capacitance |
| ij | A | $I_{j,bot} + I_{j,sti} + I_{j,gat}$ | Total junction current |
| ijbot | A | $\text{AB} \cdot I'_{j,bot}$ | Bottom component junction current |
| ijsti | A | $\text{LS} \cdot I'_{j,sti}$ | STI-edge component junction current |
| ijgat | A | $\text{LG} \cdot I'_{j,gat}$ | Gate-edge component junction current |
| si | A$^2$/Hz | $S_I^{shot}$ | Shot noise spectral density |
| sf | A$^2$/Hz | $S_I^{flicker}$ | Flicker noise spectral density |
| sr | A$^2$/Hz | $S_I^{thermal}$ | Series resistance thermal noise spectral density |
| vrs | V | $V(\text{aik}, k)$ | Voltage across series resistor |
| rseries | Ohm | $R_{total}$ | Series resistance value |
| qrr | C | $Q_{rr}$ | Recovery charge |
