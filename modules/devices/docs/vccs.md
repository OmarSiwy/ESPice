# VCCS (G Element) -- Parameter & Equation Reference

> Voltage-Controlled Current Source -- linear transconductance element (SPICE G-source)

## Model Topology

The VCCS is a four-terminal device with output port (`p_out`, `n_out`) and control port (`p_ctrl`, `n_ctrl`). A current proportional to the control-port voltage difference is injected into the output port. The device is purely resistive (no charge storage, no internal nodes).

**Terminals (external ports = 4):**
| Index | Node   | Description                        |
|-------|--------|------------------------------------|
| 0     | p_out  | Positive output terminal           |
| 1     | n_out  | Negative output terminal           |
| 2     | p_ctrl | Positive controlling voltage node  |
| 3     | n_ctrl | Negative controlling voltage node  |

All unknowns are voltages (default `u_kinds`). No internal nodes.

## Parameters

### Instance Parameters

| Parameter    | Symbol          | Unit | Default | Range        | Description                                        |
|--------------|-----------------|------|---------|--------------|----------------------------------------------------|
| `gain`       | $g_m$           | S    | 0.0     | $(-\infty, \infty)$ | Transconductance (gain) of the source          |
| `m`          | $M$             | --   | 1.0     | $(-\infty, \infty)$ | Parallel multiplier -- scales effective gain   |
| `ic`         | $V_{ic}$        | V    | 0.0     | $(-\infty, \infty)$ | Initial condition of controlling source voltage |
| `sens_trans` | --              | --   | false   | {true,false} | Flag to request sensitivity w.r.t. transconductance |

### Model Parameters

No model-level parameters (empty `Model` struct). All parameters are instance-level.

## Equations

### Control Voltage

$$V_{ctrl} = V(p\_ctrl) - V(n\_ctrl)$$

Differential voltage across the controlling port.

### Effective Transconductance Coefficient

$$g_{eff} = g_m \cdot M$$

The gain and parallel multiplier are pre-folded into a single coefficient at parameter-set time (matches ngspice behavior).

### Output Current

$$I_{out} = g_{eff} \cdot V_{ctrl}$$

Linear voltage-controlled current. Positive $I_{out}$ flows **into** `p_out` and **out of** `n_out`.

### KCL Stamp (Current Contributions)

$$I(p\_out) = +I_{out}$$

$$I(n\_out) = -I_{out}$$

$$I(p\_ctrl) = 0$$

$$I(n\_ctrl) = 0$$

No current flows into the control port (infinite input impedance).

### Jacobian (Conductance Matrix) Contributions

By automatic differentiation of the current contributions with respect to node voltages:

$$\frac{\partial I(p\_out)}{\partial V(p\_ctrl)} = +g_{eff}$$

$$\frac{\partial I(p\_out)}{\partial V(n\_ctrl)} = -g_{eff}$$

$$\frac{\partial I(n\_out)}{\partial V(p\_ctrl)} = -g_{eff}$$

$$\frac{\partial I(n\_out)}{\partial V(n\_ctrl)} = +g_{eff}$$

All other partial derivatives are zero. This is the standard 4-terminal transconductance stamp.

## Notes

- **No charge function (`q`):** Device is purely resistive; no reactive (C dV/dt) contributions.
- **No limiting function (`limit`):** No Newton step damping required for a linear element.
- **No attempt function (`attempt`):** No continuation/parameter-stepping for convergence aid.
- **No noise generators:** No `noise_gens` declared; device contributes no noise.
- **No state:** Stateless device (variant A: `i` function). No `State` struct or history dependence.
- **Autodiff compatible:** The `i` function is generic over scalar type `S`, supporting both `f64` evaluation and dual-number Jacobian extraction.
