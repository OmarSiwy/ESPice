# Coupled Inductors (K Element) -- Parameter & Equation Reference

> Mutual inductance coupling element linking two inductor branch currents via coupling coefficient k.

## Model Topology

The K element couples two separate inductor instances (L1, L2) by adding mutual flux contributions between their branch current unknowns. It has no external port voltages of its own; its two unknowns (`ibr1`, `ibr2`) are the branch currents of the two coupled inductors. The element contributes zero DC current (purely reactive); all coupling enters through the charge/flux function `q`, which the solver differentiates in time to produce $M \, dI/dt$ voltage terms in each inductor's KVL equation.

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `k` | $k$ | -- | 0.00099 | $(-1, 1)$ | Mutual inductance coupling coefficient |

### Instance Parameters

None. The K element has an empty instance parameter struct.

### Related: Inductor Parameters (L Element)

The K element operates on the branch currents of two inductor instances. The mutual inductance $M$ is resolved at a higher level as $M = k \sqrt{L_1 L_2}$, where $L_1$ and $L_2$ are the effective inductances of the coupled inductors after temperature, scaling, and multiplicity processing. The inductor parameters that feed into this are documented below for completeness.

#### Inductor Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `ind` | $L_\text{model}$ | H | 0 | $\geq 0$ | Model inductance |
| `tc1` | $\text{TC}_1$ | 1/K | 0 | -- | First-order temperature coefficient |
| `tc2` | $\text{TC}_2$ | 1/K$^2$ | 0 | -- | Second-order temperature coefficient |
| `tnom` | $T_\text{nom}$ | degC | 27 | -- | Parameter measurement temperature |
| `csect` | $A$ | m$^2$ | 0 | $\geq 0$ | Inductor cross-section area |
| `length` | $\ell$ | m | 0 | $\geq 0$ | Mean magnetic path length |
| `nt` | $N$ | -- | 0 | $\geq 0$ | Number of turns (model default) |
| `mu` | $\mu_r$ | -- | 0 | $\geq 0$ | Relative magnetic permeability (0 treated as 1) |

#### Inductor Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `inductance` | $L_\text{inst}$ | H | 0 | $\geq 0$ | Instance inductance override (0 = use model) |
| `ic` | $I_0$ | A | 0 | -- | Initial current through inductor |
| `m` | $m$ | -- | 1.0 | $> 0$ | Parallel multiplier |
| `temp` | $T$ | degC | 27.0 | -- | Instance operating temperature |
| `dtemp` | $\Delta T$ | degC | 0 | -- | Temperature offset from circuit temperature |
| `tc1` | $\text{TC}_{1,\text{inst}}$ | 1/K | 0 | -- | Instance first-order temp coefficient (overrides model) |
| `tc2` | $\text{TC}_{2,\text{inst}}$ | 1/K$^2$ | 0 | -- | Instance second-order temp coefficient (overrides model) |
| `scale` | $s$ | -- | 1.0 | $> 0$ | Scale factor applied to inductance |
| `nt` | $N_\text{inst}$ | -- | 0 | $\geq 0$ | Number of turns (overrides model if > 0) |
| `temp_given` | -- | -- | false | -- | Flag: instance temp was explicitly set |
| `tc1_given` | -- | -- | false | -- | Flag: instance tc1 was explicitly set |
| `tc2_given` | -- | -- | false | -- | Flag: instance tc2 was explicitly set |

## Equations

### DC Current Contribution (K Element)

$$i_{\text{ibr1}} = 0, \qquad i_{\text{ibr2}} = 0$$

The K element contributes zero resistive (DC) current. All coupling is purely through mutual flux in the charge function.

### Mutual Flux Contribution (K Element -- `q` function)

$$q_{\text{ibr1}} = k \cdot I_{\text{br2}}$$

$$q_{\text{ibr2}} = k \cdot I_{\text{br1}}$$

Cross-coupling flux: the charge contribution to inductor 1's branch equation is proportional to inductor 2's branch current, and vice versa. The solver time-differentiates these to produce $k \, dI_{\text{br2}}/dt$ and $k \, dI_{\text{br1}}/dt$ voltage terms.

At the system level, the actual mutual inductance is:

$$M = k \sqrt{L_1 \cdot L_2}$$

The `k` stored in the K element's parameter is the raw coupling coefficient. The resolution to physical mutual inductance $M$ (incorporating the two inductors' effective inductance values) occurs at a higher level in the simulator framework.

### Inductor Self-Flux (L Element -- `q` function)

The following equations define the effective inductance of each coupled inductor, which feeds into the mutual inductance calculation.

#### Base Inductance Selection

$$L_\text{base} = \begin{cases} L_\text{inst} & \text{if } L_\text{inst} \neq 0 \\ \mu_\text{eff} \cdot A \cdot N_\text{eff}^2 / \ell & \text{if } A > 0 \text{ and } \ell > 0 \\ L_\text{model} & \text{otherwise} \end{cases}$$

where:

$$\mu_\text{eff} = \mu_0 \cdot \begin{cases} \mu_r & \text{if } \mu_r > 0 \\ 1 & \text{otherwise} \end{cases}$$

$$N_\text{eff} = \begin{cases} N_\text{inst} & \text{if } N_\text{inst} > 0 \\ N_\text{model} & \text{otherwise} \end{cases}$$

$$\mu_0 = 1.2566370614359 \times 10^{-6} \; \text{H/m}$$

#### Scaled Inductance

$$L_\text{scaled} = L_\text{base} \cdot s$$

#### Temperature Dependence

$$T_K = \begin{cases} T_\text{inst} + 273.15 & \text{if temp\_given} \\ 300.15 + \Delta T & \text{otherwise} \end{cases}$$

$$T_{\text{nom},K} = T_\text{nom} + 273.15$$

$$\Delta t = T_K - T_{\text{nom},K}$$

Temperature coefficients are resolved with instance override priority:

$$\text{TC}_{1,\text{eff}} = \begin{cases} \text{TC}_{1,\text{inst}} & \text{if tc1\_given} \\ \text{TC}_{1,\text{model}} & \text{otherwise} \end{cases}$$

$$\text{TC}_{2,\text{eff}} = \begin{cases} \text{TC}_{2,\text{inst}} & \text{if tc2\_given} \\ \text{TC}_{2,\text{model}} & \text{otherwise} \end{cases}$$

$$f_T = 1 + \text{TC}_{1,\text{eff}} \cdot \Delta t + \text{TC}_{2,\text{eff}} \cdot \Delta t^2$$

#### Effective Inductance

$$L_\text{eff} = L_\text{scaled} \cdot f_T$$

#### Multiplicity

$$L_\text{final} = \frac{L_\text{eff}}{m}$$

#### Self-Flux Stamp

$$\Phi_\text{br} = L_\text{final} \cdot I_\text{br}$$

The solver differentiates this to produce $L_\text{final} \, dI_\text{br}/dt$.

### Inductor KCL/KVL Stamps (L Element -- `i` function)

The inductor uses a branch current formulation with three unknowns: $V_p$, $V_n$, $I_\text{br}$.

$$i_p = I_\text{br}$$

$$i_n = -I_\text{br}$$

$$i_\text{br} = V_p - V_n$$

This stamps the inductor's KCL (current into positive and negative nodes) and KVL (branch voltage equals node voltage difference) into the MNA system.

### Noise

No noise sources are declared for either the K element or the inductor.
