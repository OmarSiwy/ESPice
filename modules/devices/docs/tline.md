# Lossless Transmission Line (T) -- Parameter & Equation Reference

> Ideal lossless two-port transmission line using Bergeron DC-coupled companion model (SPICE `T` element).

## Model Topology

The lossless transmission line has four external terminals: `pos1`, `neg1` (port 1) and `pos2`, `neg2` (port 2), plus four internal unknowns: two internal voltage nodes `int1`, `int2` and two branch currents `ibr1`, `ibr2`. At each port a conductance $G_0 = 1/Z_0$ connects the positive terminal to the internal node, and a branch current flows from the negative terminal to the internal node. The two ports are coupled by symmetric Bergeron branch equations that enforce the traveling-wave relationship.

**Equivalent circuit:**

```
Port 1:                                Port 2:
  pos1 ---[G0=1/Z0]--- int1             pos2 ---[G0=1/Z0]--- int2
                         |                                      |
  neg1 -----ibr1--------+               neg2 -----ibr2--------+
```

Branch equation 1 couples port 1 internal voltage to port 2 external voltage; branch equation 2 is symmetric. At DC the line behaves as a short circuit (zero delay).

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `z0` | $Z_0$ | $\Omega$ | 50.0 | $(0, \infty)$ | Characteristic impedance |
| `f` | $f$ | Hz | $1 \times 10^9$ | $(0, \infty)$ | Frequency at which `nl` is specified |
| `td` | $T_d$ | s | 0.0 | $[0, \infty)$ | Transmission delay; if 0, derived as $\mathrm{nl}/f$ |
| `nl` | $NL$ | wavelengths | 0.25 | $(0, \infty)$ | Normalized electrical length |
| `v1` | $V_1$ | V | 0.0 | $(-\infty, \infty)$ | Initial voltage at end 1 |
| `v2` | $V_2$ | V | 0.0 | $(-\infty, \infty)$ | Initial voltage at end 2 |
| `i1` | $I_1$ | A | 0.0 | $(-\infty, \infty)$ | Initial current at end 1 |
| `i2` | $I_2$ | A | 0.0 | $(-\infty, \infty)$ | Initial current at end 2 |
| `reltol` | -- | -- | 1.0 | $(0, \infty)$ | Relative derivative tolerance |
| `abstol` | -- | -- | 1.0 | $(0, \infty)$ | Absolute derivative tolerance |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `temp` | $T$ | K | 300.15 | $(0, \infty)$ | Device temperature |
| `m` | $M$ | -- | 1.0 | $(0, \infty)$ | Parallel multiplier |

## Unknowns

| Index | Name | Kind | Description |
|-------|------|------|-------------|
| 0 | `pos1` | voltage | Positive terminal, port 1 |
| 1 | `neg1` | voltage | Negative terminal, port 1 |
| 2 | `pos2` | voltage | Positive terminal, port 2 |
| 3 | `neg2` | voltage | Negative terminal, port 2 |
| 4 | `int1` | voltage | Internal node, port 1 |
| 5 | `int2` | voltage | Internal node, port 2 |
| 6 | `ibr1` | current | Branch current, port 1 (neg1 $\to$ int1) |
| 7 | `ibr2` | current | Branch current, port 2 (neg2 $\to$ int2) |

## Equations

### Derived Quantities

$$G_0 = \frac{1}{Z_0}$$

Characteristic conductance.

### Convenience Definitions

$$V_{\mathrm{port1}} = V_{\mathrm{int1}} - V_{\mathrm{neg1}}$$

$$V_{\mathrm{port2}} = V_{\mathrm{int2}} - V_{\mathrm{neg2}}$$

Internal port voltages (internal node to negative terminal).

$$V_{\mathrm{ext1}} = V_{\mathrm{pos1}} - V_{\mathrm{neg1}}$$

$$V_{\mathrm{ext2}} = V_{\mathrm{pos2}} - V_{\mathrm{neg2}}$$

External port voltages (positive terminal to negative terminal).

### Transmission Delay Derivation

$$T_d = \begin{cases} T_d & \text{if } T_d > 0 \\ \dfrac{NL}{f} & \text{otherwise} \end{cases}$$

If `td` is zero, the delay is computed from the normalized electrical length and frequency.

### KCL Equations -- Conductance Stamps

$$f_{\mathrm{pos1}} = G_0 \left( V_{\mathrm{pos1}} - V_{\mathrm{int1}} \right)$$

Current into `pos1`: conductance current from pos1 toward int1.

$$f_{\mathrm{neg1}} = -I_{\mathrm{br1}}$$

Current into `neg1`: branch current ibr1 leaves neg1 (flows neg1 $\to$ int1).

$$f_{\mathrm{pos2}} = G_0 \left( V_{\mathrm{pos2}} - V_{\mathrm{int2}} \right)$$

Current into `pos2`: conductance current from pos2 toward int2.

$$f_{\mathrm{neg2}} = -I_{\mathrm{br2}}$$

Current into `neg2`: branch current ibr2 leaves neg2 (flows neg2 $\to$ int2).

$$f_{\mathrm{int1}} = G_0 \left( V_{\mathrm{int1}} - V_{\mathrm{pos1}} \right) + I_{\mathrm{br1}}$$

Current into `int1`: conductance current from int1 toward pos1 plus incoming branch current.

$$f_{\mathrm{int2}} = G_0 \left( V_{\mathrm{int2}} - V_{\mathrm{pos2}} \right) + I_{\mathrm{br2}}$$

Current into `int2`: conductance current from int2 toward pos2 plus incoming branch current.

### Branch Equations -- Bergeron DC Coupling

$$f_{\mathrm{ibr1}} = V_{\mathrm{port1}} - V_{\mathrm{ext2}} - Z_0 \cdot I_{\mathrm{br2}} = 0$$

Expanded:

$$V_{\mathrm{int1}} - V_{\mathrm{neg1}} - (V_{\mathrm{pos2}} - V_{\mathrm{neg2}}) - Z_0 \cdot I_{\mathrm{br2}} = 0$$

Couples port 1 internal voltage to port 2 external voltage with cross-impedance on opposite branch current.

$$f_{\mathrm{ibr2}} = V_{\mathrm{port2}} - V_{\mathrm{ext1}} - Z_0 \cdot I_{\mathrm{br1}} = 0$$

Expanded:

$$V_{\mathrm{int2}} - V_{\mathrm{neg2}} - (V_{\mathrm{pos1}} - V_{\mathrm{neg1}}) - Z_0 \cdot I_{\mathrm{br1}} = 0$$

Couples port 2 internal voltage to port 1 external voltage with cross-impedance on opposite branch current. Symmetric to branch equation 1.

### Residual Vector

The device returns the 8-element residual vector:

$$\mathbf{f} = \begin{bmatrix} f_{\mathrm{pos1}} \\ f_{\mathrm{neg1}} \\ f_{\mathrm{pos2}} \\ f_{\mathrm{neg2}} \\ f_{\mathrm{int1}} \\ f_{\mathrm{int2}} \\ f_{\mathrm{ibr1}} \\ f_{\mathrm{ibr2}} \end{bmatrix}$$

### Jacobian Structure (Implicit via Autodiff)

The Jacobian $\partial \mathbf{f} / \partial \mathbf{x}$ is extracted automatically by the solver's autodiff system. The non-zero entries implied by the equations are:

**From conductance stamps** ($G_0$ blocks):

| Row | Col | Entry |
|-----|-----|-------|
| pos1 | pos1 | $+G_0$ |
| pos1 | int1 | $-G_0$ |
| int1 | pos1 | $-G_0$ |
| int1 | int1 | $+G_0$ |
| pos2 | pos2 | $+G_0$ |
| pos2 | int2 | $-G_0$ |
| int2 | pos2 | $-G_0$ |
| int2 | int2 | $+G_0$ |

**From branch current stamps:**

| Row | Col | Entry |
|-----|-----|-------|
| neg1 | ibr1 | $-1$ |
| int1 | ibr1 | $+1$ |
| neg2 | ibr2 | $-1$ |
| int2 | ibr2 | $+1$ |

**From Bergeron branch equations:**

| Row | Col | Entry |
|-----|-----|-------|
| ibr1 | int1 | $+1$ |
| ibr1 | neg1 | $-1$ |
| ibr1 | pos2 | $-1$ |
| ibr1 | neg2 | $+1$ |
| ibr1 | ibr2 | $-Z_0$ |
| ibr2 | int2 | $+1$ |
| ibr2 | neg2 | $-1$ |
| ibr2 | pos1 | $-1$ |
| ibr2 | neg1 | $+1$ |
| ibr2 | ibr1 | $-Z_0$ |

## Notes

- **DC only**: The current implementation is a DC-coupled Bergeron companion model. Full transient history-dependent (`iH`) behavior with delayed signal lookup is marked as TODO in the source. At DC, the lossless transmission line acts as a short circuit.
- **No charge contributions**: The `q` function (reactive/charge terms) is not implemented; no capacitive or inductive energy storage is modeled in this formulation.
- **No noise sources**: No `noise_gens` are defined for this device.
- **No limiting or convergence aids**: Neither `limit` (Newton step damping) nor `attempt` (parameter stepping) functions are implemented.
- **No temperature dependence**: The `temp` instance parameter is declared but not used in the current equations.
