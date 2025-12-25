# Capacitor (C) -- Parameter & Equation Reference

> Linear capacitor with geometry, dielectric, temperature-coefficient, and multiplicity support.

## Model Topology

The capacitor is a two-terminal device with positive node **p** and negative node **n**. It contributes no resistive current (`i = 0`); its behavior is defined entirely through a charge function `q(v)` where `v = V(p) - V(n)`, yielding displacement current `dq/dt`. The charge is linear in voltage: `q = C_final * v`.

## Parameters

### Model Parameters (`Model`)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cap` | $C_{model}$ | F | 0.0 | -- | Flat model capacitance |
| `cj` | $C_j$ | F/m^2 | 0.0 | -- | Junction (area) capacitance per unit area |
| `cjsw` | $C_{jsw}$ | F/m | 0.0 | -- | Sidewall capacitance per unit perimeter |
| `defw` | $W_{def}$ | m | 1e-5 | -- | Default instance width |
| `defl` | $L_{def}$ | m | 0.0 | -- | Default instance length |
| `narrow` | $\Delta W$ | m | 0.0 | -- | Narrowing due to side etching (width) |
| `short` | $\Delta L$ | m | 0.0 | -- | Shortening due to side etching (length) |
| `del` | $\delta$ | m | 0.0 | -- | Isotropic etch delta (sets narrow and short if not given) |
| `tc1` | $TC_1$ | 1/K | 0.0 | -- | First-order temperature coefficient |
| `tc2` | $TC_2$ | 1/K^2 | 0.0 | -- | Second-order temperature coefficient |
| `tnom` | $T_{nom}$ | degC | 27.0 | -- | Nominal (parameter measurement) temperature |
| `di` | $\varepsilon_r$ | -- | 0.0 | -- | Relative dielectric constant |
| `thick` | $t_{ox}$ | m | 0.0 | -- | Dielectric thickness |
| `bv_max` | $BV_{max}$ | V | 1e99 | -- | Maximum breakdown voltage (currently unused in eval) |

### Instance Parameters (`Instance`)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cap` | $C_{inst}$ | F | 0.0 | -- | Instance capacitance (overrides model/geometry) |
| `ic` | $V_{ic}$ | V | 0.0 | -- | Initial condition (voltage) |
| `temp` | $T_{inst}$ | degC | 0.0 | -- | Instance temperature (overrides circuit temp) |
| `dtemp` | $\Delta T$ | K | 0.0 | -- | Temperature offset from circuit temperature |
| `w` | $W$ | m | 0.0 | -- | Instance width |
| `l` | $L$ | m | 0.0 | -- | Instance length |
| `m` | $M$ | -- | 1.0 | -- | Multiplicity (number of parallel devices) |
| `tc1` | $TC_{1,inst}$ | 1/K | 0.0 | -- | Instance first-order temperature coefficient (overrides model) |
| `tc2` | $TC_{2,inst}$ | 1/K^2 | 0.0 | -- | Instance second-order temperature coefficient (overrides model) |
| `scale` | $S$ | -- | 1.0 | -- | Instance scale factor |

### Constants

| Constant | Symbol | Value | Description |
|----------|--------|-------|-------------|
| `eps0` | $\varepsilon_0$ | 8.854187817e-12 F/m | Vacuum permittivity |

## Equations

### Terminal Voltage

$$ v = V_p - V_n $$

Voltage across the capacitor, positive node minus negative node.

### Dielectric-Based Junction Capacitance

$$ C_j = \frac{\varepsilon_r \cdot \varepsilon_0}{t_{ox}} \quad \text{when } \varepsilon_r > 0 \text{ and } t_{ox} > 0 $$

Overrides the model `cj` parameter when dielectric constant and thickness are both specified.

### Etch Delta Propagation

$$ \Delta W = \begin{cases} \texttt{narrow} & \text{if narrow} \neq 0 \\ 2\delta & \text{otherwise} \end{cases} $$

$$ \Delta L = \begin{cases} \texttt{short} & \text{if short} \neq 0 \\ 2\delta & \text{otherwise} \end{cases} $$

Isotropic etch parameter `del` provides a default for both `narrow` and `short` when they are not explicitly given.

### Base Capacitance Selection (Precedence)

**Priority 1 -- Instance capacitance given:**

$$ C_{base} = C_{inst} $$

**Priority 2 -- Geometry-based ($C_j > 0$):**

$$ W_{eff} = W_{inst} - \Delta W \quad \text{where } W_{inst} = \begin{cases} W & \text{if } W > 0 \\ W_{def} & \text{otherwise} \end{cases} $$

$$ L_{eff} = L_{inst} - \Delta L \quad \text{where } L_{inst} = \begin{cases} L & \text{if } L > 0 \\ L_{def} & \text{otherwise} \end{cases} $$

$$ C_{base} = C_j \cdot W_{eff} \cdot L_{eff} + C_{jsw} \cdot 2 \cdot (W_{eff} + L_{eff}) $$

$$ C_{base} = \max(C_{base},\; 0) $$

**Priority 3 -- Flat model capacitance:**

$$ C_{base} = C_{model} $$

### Instance Scale

$$ C_{base} \leftarrow C_{base} \cdot S $$

Applied after base capacitance selection.

### Temperature Scaling

$$ T_{op} = \begin{cases} T_{inst} & \text{if instance temp given} \\ 27 + \Delta T & \text{otherwise} \end{cases} $$

$$ \Delta t = T_{op} - T_{nom} $$

$$ TC_1 = \begin{cases} TC_{1,inst} & \text{if instance tc1 given} \\ TC_{1,model} & \text{otherwise} \end{cases} $$

$$ TC_2 = \begin{cases} TC_{2,inst} & \text{if instance tc2 given} \\ TC_{2,model} & \text{otherwise} \end{cases} $$

$$ f_{temp} = 1 + TC_1 \cdot \Delta t + TC_2 \cdot (\Delta t)^2 $$

$$ C_{eff} = C_{base} \cdot f_{temp} $$

### Multiplicity

$$ C_{final} = C_{eff} \cdot M $$

### Charge (Constitutive Equation)

$$ q_p = C_{final} \cdot v $$

$$ q_n = -C_{final} \cdot v $$

Charge contributions stamped to positive and negative nodes respectively. The simulator obtains current via $i = dq/dt$.

### Current

$$ i_p = 0, \quad i_n = 0 $$

No resistive (DC) current contribution. All device behavior is through the charge branch.
