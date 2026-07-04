# Inductor (L) -- Parameter & Equation Reference

> Linear inductor with flux-based formulation, temperature coefficients, geometry-based inductance, and parallel multiplicity.

## Model Topology

The inductor is a two-terminal device with external ports **p** (positive) and **n** (negative) plus one internal branch-current unknown **br**. It uses a current-through formulation: the branch current `I_br` flows from p to n, and the device stamps KCL contributions `+I_br` at node p, `-I_br` at node n, and a voltage/flux relation at the branch equation. The charge function contributes flux $\Phi = L_{\text{eff}} \cdot I_{br}$ on the branch row; the solver differentiates this to obtain $V = L \, dI/dt$.

## Parameters

### Model Parameters (`Model`)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `ind` | $L_{\text{model}}$ | H | 0 | $\geq 0$ | Model inductance |
| `tc1` | $TC_1$ | 1/K | 0 | any | First-order temperature coefficient |
| `tc2` | $TC_2$ | 1/K$^2$ | 0 | any | Second-order temperature coefficient |
| `tnom` | $T_{\text{nom}}$ | degC | 27 | any | Parameter measurement temperature |
| `csect` | $A$ | m$^2$ | 0 | $\geq 0$ | Inductor cross-section area |
| `length` | $\ell$ | m | 0 | $\geq 0$ | Mean magnetic path length |
| `nt` | $N_{\text{model}}$ | -- | 0 | $\geq 0$ | Model number of turns |
| `mu` | $\mu_r$ | -- | 0 | $\geq 0$ | Relative magnetic permeability (0 treated as 1) |

### Instance Parameters (`Instance`)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `inductance` | $L_{\text{inst}}$ | H | 0 | $\geq 0$ | Instance inductance override (0 = use model) |
| `ic` | $I_{\text{ic}}$ | A | 0 | any | Initial current through inductor |
| `m` | $M$ | -- | 1.0 | $> 0$ | Parallel multiplier |
| `temp` | $T_{\text{inst}}$ | degC | 27.0 | any | Instance operating temperature |
| `dtemp` | $\Delta T$ | K | 0 | any | Temperature offset from circuit temperature |
| `tc1` | $TC_{1,\text{inst}}$ | 1/K | 0 | any | Instance first-order temp coefficient (overrides model) |
| `tc2` | $TC_{2,\text{inst}}$ | 1/K$^2$ | 0 | any | Instance second-order temp coefficient (overrides model) |
| `scale` | $S$ | -- | 1.0 | $> 0$ | Scale factor applied to inductance |
| `nt` | $N_{\text{inst}}$ | -- | 0 | $\geq 0$ | Number of turns (overrides model) |
| `temp_given` | -- | -- | false | -- | Flag: instance temp was explicitly set |
| `tc1_given` | -- | -- | false | -- | Flag: instance tc1 was explicitly set |
| `tc2_given` | -- | -- | false | -- | Flag: instance tc2 was explicitly set |

### Constants

| Constant | Symbol | Value | Description |
|----------|--------|-------|-------------|
| `MU_0` | $\mu_0$ | $1.2566370614359 \times 10^{-6}$ H/m | Permeability of free space |

## Equations

### Operating Temperature

$$T = \begin{cases} T_{\text{inst}} + 273.15 & \text{if } \texttt{temp\_given} \\ 300.15 + \Delta T & \text{otherwise (circuit default 27\degree C)} \end{cases}$$

$$T_{\text{nom}} = T_{\text{nom,model}} + 273.15$$

$$\Delta T_{\text{coeff}} = T - T_{\text{nom}}$$

Temperature difference used in the temperature derating polynomial.

### Base Inductance Selection

Three-way priority for the base inductance value:

$$L_{\text{base}} = \begin{cases} L_{\text{inst}} & \text{if } L_{\text{inst}} \neq 0 \\[6pt] \dfrac{\mu_{\text{eff}} \cdot A \cdot N^2}{\ell} & \text{if } A > 0 \text{ and } \ell > 0 \\[6pt] L_{\text{model}} & \text{otherwise} \end{cases}$$

where the geometry-based path uses:

$$N = \begin{cases} N_{\text{inst}} & \text{if } N_{\text{inst}} > 0 \\ N_{\text{model}} & \text{otherwise} \end{cases}$$

$$\mu_{\text{eff}} = \mu_0 \cdot \begin{cases} \mu_r & \text{if } \mu_r > 0 \\ 1 & \text{otherwise} \end{cases}$$

### Scale Factor

$$L_{\text{scaled}} = L_{\text{base}} \cdot S$$

### Temperature Coefficient

Effective coefficients (instance overrides model when explicitly given):

$$TC_{1,\text{eff}} = \begin{cases} TC_{1,\text{inst}} & \text{if } \texttt{tc1\_given} \\ TC_{1,\text{model}} & \text{otherwise} \end{cases}$$

$$TC_{2,\text{eff}} = \begin{cases} TC_{2,\text{inst}} & \text{if } \texttt{tc2\_given} \\ TC_{2,\text{model}} & \text{otherwise} \end{cases}$$

Temperature derating factor:

$$F_T = 1 + TC_{1,\text{eff}} \cdot \Delta T_{\text{coeff}} + TC_{2,\text{eff}} \cdot \Delta T_{\text{coeff}}^2$$

### Effective Inductance

$$L_{\text{eff}} = L_{\text{scaled}} \cdot F_T$$

### Parallel Multiplicity

$M$ parallel inductors yield:

$$L_{\text{final}} = \frac{L_{\text{eff}}}{M}$$

### KCL Contributions (Resistive / `i` function)

The stateless current stamp enforces KVL across the inductor and distributes branch current to the port nodes:

$$I_p = +I_{br}$$

$$I_n = -I_{br}$$

$$f_{br} = V_p - V_n$$

The branch equation $f_{br} = V_p - V_n$ is the voltage across the inductor; the solver combines this with the time-derivative of the flux (from the charge function) to enforce $V = L \, dI/dt$.

### Flux / Charge Contributions (`q` function)

The charge function returns flux $\Phi$ on the branch row. The solver computes $d\Phi/dt$ to obtain the inductive voltage:

$$q_p = 0$$

$$q_n = 0$$

$$q_{br} = \Phi = L_{\text{final}} \cdot I_{br}$$

The resulting constitutive relation after time differentiation by the solver is:

$$V_p - V_n = L_{\text{final}} \, \frac{dI_{br}}{dt}$$

### Unknown Classification

| Index | Unknown | Kind | Description |
|-------|---------|------|-------------|
| 0 | `p` | voltage | Positive terminal voltage |
| 1 | `n` | voltage | Negative terminal voltage |
| 2 | `br` | current | Branch current through inductor |
