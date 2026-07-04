# Resistor (R) -- Parameter & Equation Reference

> Standard SPICE resistor with sheet-resistance geometry, temperature coefficients, and thermal noise.

## Model Topology

The resistor is a two-terminal device with nodes **p** (positive) and **n** (negative).
The equivalent circuit is a single conductance $G = m / R_{\text{eff}}$ between terminals p and n, with one thermal noise source in parallel.
Current flows from p to n for positive voltage $V_{pn}$.

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `r` | $R$ | $\Omega$ | 0 | -- | Default resistance value |
| `rsh` | $R_{sh}$ | $\Omega/\square$ | 0 | -- | Sheet resistance |
| `narrow` | $\Delta W$ | m | 0 | -- | Narrowing due to side etching |
| `short` | $\Delta L$ | m | 0 | -- | Shortening due to side etching |
| `defw` | $W_0$ | m | 10e-6 | -- | Default width |
| `defl` | $L_0$ | m | 10e-6 | -- | Default length |
| `tc1` | $TC_1$ | $1/\degree C$ | 0 | -- | First-order temperature coefficient |
| `tc2` | $TC_2$ | $1/\degree C^2$ | 0 | -- | Second-order temperature coefficient |
| `tnom` | $T_{nom}$ | $\degree C$ | 27 | -- | Parameter measurement temperature |
| `kf` | $K_f$ | -- | 0 | -- | Flicker noise coefficient |
| `af` | $A_f$ | -- | 1.0 | -- | Flicker noise exponent |
| `bv_max` | $BV_{max}$ | V | 1e99 | -- | Maximum breakdown voltage |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `resist` | $R_{inst}$ | $\Omega$ | 0 | -- | Instance resistance value |
| `w` | $W$ | m | 0 | -- | Resistor width |
| `l` | $L$ | m | 0 | -- | Resistor length |
| `temp` | $T_{inst}$ | $\degree C$ | not set | -- | Instance temperature (overrides circuit temp) |
| `dtemp` | $\Delta T$ | $\degree C$ | 0 | -- | Temperature offset from circuit temperature |
| `m` | $M$ | -- | 1.0 | -- | Parallel multiplier |
| `scale` | $S$ | -- | 1.0 | -- | Instance scale factor |
| `tc1` | $TC_{1,inst}$ | $1/\degree C$ | not set | -- | Instance first-order temp coefficient (overrides model) |
| `tc2` | $TC_{2,inst}$ | $1/\degree C^2$ | not set | -- | Instance second-order temp coefficient (overrides model) |
| `bv_max` | $BV_{max,inst}$ | V | not set | -- | Instance maximum breakdown voltage (overrides model) |

## Equations

### Operating Temperature

$$T_K = \begin{cases} T_{inst} + 273.15 & \text{if } T_{inst} \text{ given} \\ T_{circuit} + \Delta T & \text{otherwise} \end{cases}$$

Instance temperature in Kelvin. Circuit temperature defaults to $T_{circuit} = 300.15\;\text{K}\;(27\degree C)$.

$$T_{nom,K} = T_{nom} + 273.15$$

Nominal temperature in Kelvin.

$$\Delta T_{coeff} = T_K - T_{nom,K}$$

Temperature difference used in coefficient evaluation.

### Base Resistance

$$R_{base} = \begin{cases} R_{inst} & \text{if } R_{inst} > 0 \\ R_{sh} \cdot \dfrac{L_{eff}}{W_{eff}} & \text{if } R_{sh} > 0 \text{ and } L_{eff} > 0 \text{ and } W_{eff} > 0 \\ R & \text{otherwise} \end{cases}$$

Priority: explicit instance resistance, then geometry-based computation, then model default.

#### Effective Geometry

$$W_{used} = \begin{cases} W & \text{if } W > 0 \\ W_0 & \text{otherwise} \end{cases}$$

$$L_{used} = \begin{cases} L & \text{if } L > 0 \\ L_0 & \text{otherwise} \end{cases}$$

$$L_{eff} = L_{used} - \Delta L$$

$$W_{eff} = W_{used} - \Delta W$$

### Scale Factor

$$R_{base,scaled} = R_{base} \cdot S$$

Instance scale factor applied to base resistance.

### Temperature Dependence

$$TC_1 = \begin{cases} TC_{1,inst} & \text{if } TC_{1,inst} \text{ given} \\ TC_{1,model} & \text{otherwise} \end{cases}$$

$$TC_2 = \begin{cases} TC_{2,inst} & \text{if } TC_{2,inst} \text{ given} \\ TC_{2,model} & \text{otherwise} \end{cases}$$

Instance-level temperature coefficients override model-level when specified (sentinel value $-10^{99}$ = not set).

$$F_{temp} = 1 + TC_1 \cdot \Delta T_{coeff} + TC_2 \cdot \Delta T_{coeff}^2$$

$$R_{eff} = R_{base,scaled} \cdot F_{temp}$$

### Resistance Clamping

$$R_{eff} = \max(R_{eff},\; 10^{-3}\;\Omega)$$

Minimum resistance clamp at 1 milliohm to prevent numerical singularity.

### Conductance and Current

$$G = \frac{M}{R_{eff}}$$

Effective conductance including parallel multiplier.

$$V_{pn} = V_p - V_n$$

$$I_R = G \cdot V_{pn}$$

Current contribution to node p is $+I_R$; current contribution to node n is $-I_R$.

### Noise

#### Thermal Noise

$$S_{I,thermal} = \frac{4\,k_B\,T}{R_{eff}}$$

Thermal (Johnson-Nyquist) noise current spectral density between nodes p and n. Declared as a single thermal noise generator across the p-n port pair.

#### Flicker Noise (Model Parameters Only)

$$S_{I,flicker} = \frac{K_f \cdot I^{A_f}}{f}$$

Flicker (1/f) noise. Parameters $K_f$ and $A_f$ are present in the model struct; the noise generator list currently declares only the thermal source. Flicker noise is parameterized but not instantiated in the current noise generator array.
