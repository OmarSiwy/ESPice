# VCVS (E-Element) -- Parameter & Equation Reference

> Linear voltage-controlled voltage source (SPICE E-element)

## Model Topology

The VCVS has four external terminals: positive output (`p_out`), negative output (`n_out`), positive control (`p_ctrl`), and negative control (`n_ctrl`), plus one internal branch current unknown (`ibr`). The device forces the output voltage $V_{out} = V(p\_out) - V(n\_out)$ to equal a gain factor times the control voltage $V_{ctrl} = V(p\_ctrl) - V(n\_ctrl)$. The branch current `ibr` flows from `p_out` through the source to `n_out`; the controlling port draws zero current.

## Parameters

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `gain` | $E$ | -- | 0.0 | $(-\infty, +\infty)$ | Voltage gain (dimensionless) |
| `ic` | $V_{ic}$ | V | 0.0 | $(-\infty, +\infty)$ | Initial condition of controlling source voltage |

### Model Parameters

*None.* The VCVS defines an empty `Model` struct; all behavior is controlled by instance parameters.

## Unknowns & Port Mapping

| Index | Name | Kind | Role |
|-------|------|------|------|
| 0 | `p_out` | voltage | Positive output terminal (external port) |
| 1 | `n_out` | voltage | Negative output terminal (external port) |
| 2 | `p_ctrl` | voltage | Positive controlling terminal (external port) |
| 3 | `n_ctrl` | voltage | Negative controlling terminal (external port) |
| 4 | `ibr` | current | Branch current through the source (internal unknown) |

`num_ports = 4`. The fifth unknown (`ibr`) is an internal current variable added by the device to enforce the voltage constraint via Modified Nodal Analysis (MNA).

## Equations

### Branch Constitutive Equation

$$V_{out} - E \cdot V_{ctrl} = 0$$

where:

$$V_{out} = V(p\_out) - V(n\_out)$$

$$V_{ctrl} = V(p\_ctrl) - V(n\_ctrl)$$

This is the constraint row (KVL) stamped into the MNA system at the `ibr` row. The solver finds $I_{br}$ such that this equation is satisfied.

### KCL Current Contributions

The device stamps the branch current into the output port nodes and zero current into the control port nodes:

$$I(p\_out) = +I_{br}$$

$$I(n\_out) = -I_{br}$$

$$I(p\_ctrl) = 0$$

$$I(n\_ctrl) = 0$$

### MNA Stamp (Jacobian Structure)

The linearized system contributions are:

$$\frac{\partial I(p\_out)}{\partial I_{br}} = +1$$

$$\frac{\partial I(n\_out)}{\partial I_{br}} = -1$$

$$\frac{\partial F_{ibr}}{\partial V(p\_out)} = +1$$

$$\frac{\partial F_{ibr}}{\partial V(n\_out)} = -1$$

$$\frac{\partial F_{ibr}}{\partial V(p\_ctrl)} = -E$$

$$\frac{\partial F_{ibr}}{\partial V(n\_ctrl)} = +E$$

where $F_{ibr} = V_{out} - E \cdot V_{ctrl}$ is the constraint residual.

### Charge Contributions

*None.* No `q` function is defined -- the device is purely algebraic with no reactive (capacitive/inductive) behavior.

### Noise Sources

*None.* No `noise_gens` are declared -- an ideal VCVS contributes no noise.

### Convergence Aids

*None.* No `limit` or `attempt` functions are defined -- the device is linear and requires no Newton step damping or parameter continuation.
