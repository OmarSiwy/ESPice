# CCCS (F Device) -- Parameter & Equation Reference

> Current-Controlled Current Source — linear dependent source whose output current is proportional to a controlling branch current.

## Model Topology

The CCCS is a three-terminal primitive with two output port nodes (**p**, **n**) and one controlling branch reference (**ctrl_br**). The controlling branch is the current through an associated voltage source (typically a zero-volt V-source used as an ammeter). The device injects a current $I_{out} = G \cdot I_{ctrl}$ into node **p** and extracts it from node **n**; the controlling branch itself sees zero contribution from this device.

**Unknown classification:**

| Unknown | Kind    | Role                              |
|---------|---------|-----------------------------------|
| `p`     | voltage | Positive output terminal          |
| `n`     | voltage | Negative output terminal          |
| `ctrl_br` | current | Controlling branch current (from V-source) |

External port count: **3**

## Parameters

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `gain`    | $G$    | A/A  | 1.0     | $(-\infty, +\infty)$ | Current gain (dimensionless ratio) |
| `m`       | $M$    | —    | 1.0     | $(-\infty, +\infty)$ | Parallel multiplier — folded into gain at evaluation time |
| `sens_gain` | —   | —    | false   | bool  | Flag to request sensitivity analysis w.r.t. gain |

### Model Parameters

None. The CCCS has no `.model` card parameters; all behavior is controlled by instance parameters.

## Equations

### Output Current

$$I_{out} = (G \cdot M) \cdot I_{ctrl}$$

The effective coefficient is the product of the current gain $G$ and the parallel multiplier $M$, computed once and applied to the instantaneous controlling branch current.

### KCL Stamp (Current Contributions)

$$I_p = +I_{out}$$

$$I_n = -I_{out}$$

$$I_{ctrl\_br} = 0$$

Current $I_{out}$ is injected into the positive output terminal and withdrawn from the negative output terminal. The device contributes zero current to the controlling branch equation (it only senses, does not load, the controlling source).

### Jacobian (Conductance Matrix)

The linearized stamp is obtained by differentiating the current contributions with respect to the unknowns. Since $I_{out}$ depends only on $I_{ctrl}$:

$$\frac{\partial I_p}{\partial I_{ctrl}} = +G \cdot M$$

$$\frac{\partial I_n}{\partial I_{ctrl}} = -G \cdot M$$

All other partial derivatives are zero. This produces two nonzero entries in the conductance (G) matrix at positions $(p,\; ctrl\_br)$ and $(n,\; ctrl\_br)$.

### Charge / Reactive Contributions

None. The CCCS is a purely resistive (memoryless) device — no `q` function is defined, so no capacitance matrix entries are generated.

### Noise

None. No `noise_gens` are declared; the ideal CCCS contributes no noise.

### Limiting / Convergence Aids

None. No `limit` or `attempt` functions are defined; the linear nature of this device requires no Newton-step damping or parameter continuation.
