# B Source (Behavioral/Arbitrary Source) -- Parameter & Equation Reference

> Voltage-type behavioral source with polynomial expression evaluation and temperature/multiplier scaling (ngspice ASRC)

## Model Topology

The B source has four external ports: **p** and **n** (output terminals) and **ctrl_p** and **ctrl_n** (control input terminals). An internal branch unknown **branch** carries the current through the voltage source. The device enforces a KVL constraint across (p, n) equal to a polynomial function of the control voltage V(ctrl_p) - V(ctrl_n), scaled by temperature and multiplier factors. The control terminals draw zero current (infinite input impedance).

**Unknowns (5):** p (voltage), n (voltage), ctrl_p (voltage), ctrl_n (voltage), branch (current)

**External ports:** 4 (p, n, ctrl_p, ctrl_n)

## Parameters

### Polynomial Coefficients
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `c0` | $c_0$ | V | 0 | $(-\infty, \infty)$ | Constant term in polynomial expression |
| `c1` | $c_1$ | V/V | 0 | $(-\infty, \infty)$ | Linear coefficient in polynomial expression |
| `c2` | $c_2$ | V/V$^2$ | 0 | $(-\infty, \infty)$ | Quadratic coefficient in polynomial expression |

### Temperature
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `tnom` | $T_\mathrm{nom}$ | C | 27 | $(-\infty, \infty)$ | Nominal (reference) temperature |
| `temp` | $T$ | C | 27 | $(-\infty, \infty)$ | Instance operating temperature |
| `dtemp` | $\Delta T$ | C | 0 | $(-\infty, \infty)$ | Instance temperature offset |
| `tc1` | $\mathrm{TC}_1$ | 1/K | 0 | $(-\infty, \infty)$ | First-order temperature coefficient |
| `tc2` | $\mathrm{TC}_2$ | 1/K$^2$ | 0 | $(-\infty, \infty)$ | Second-order temperature coefficient |
| `reciproctc` | -- | flag | 0 | {0, 1} | When 1, use reciprocal temperature factor |

### Scaling
| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `m` | $M$ | -- | 1 | $(-\infty, \infty)$ | Output multiplier |
| `reciprocm` | -- | flag | 0 | {0, 1} | When 1, divide by multiplier instead of multiply |

## Equations

### Control Voltage

$$V_\mathrm{ctrl} = V(\mathrm{ctrl\_p}) - V(\mathrm{ctrl\_n})$$

Differential voltage across the control terminals.

### Polynomial Expression

$$\mathrm{expr} = c_0 + c_1 \cdot V_\mathrm{ctrl} + c_2 \cdot V_\mathrm{ctrl}^2$$

Second-order polynomial of the control voltage.

### Temperature Factor

$$\Delta = (T + \Delta T) - T_\mathrm{nom}$$

Temperature difference computed entirely in Celsius (the Kelvin offsets cancel).

$$f_T = 1 + \mathrm{TC}_1 \cdot \Delta + \mathrm{TC}_2 \cdot \Delta^2$$

Standard SPICE two-term temperature derating polynomial.

$$f_T \leftarrow \frac{1}{f_T} \quad \text{if } \texttt{reciproctc} = 1$$

Reciprocal temperature mode inverts the factor.

### Combined Scaling Factor

$$\mathrm{factor} = \begin{cases} f_T \cdot M & \text{if } \texttt{reciprocm} = 0 \\ f_T \;/\; M & \text{if } \texttt{reciprocm} = 1 \end{cases}$$

### Source Voltage

$$V_\mathrm{source} = \mathrm{factor} \cdot \mathrm{expr}$$

$$V_\mathrm{source} = \mathrm{factor} \cdot \bigl(c_0 + c_1 \, V_\mathrm{ctrl} + c_2 \, V_\mathrm{ctrl}^2\bigr)$$

Fully expanded output voltage expression.

### Branch Equation (KVL Residual)

$$V(p) - V(n) - V_\mathrm{source} = 0$$

$$V(p) - V(n) - \mathrm{factor} \cdot \bigl(c_0 + c_1 \, V_\mathrm{ctrl} + c_2 \, V_\mathrm{ctrl}^2\bigr) = 0$$

The Newton-Raphson residual stamped into the branch equation row.

### KCL Contributions

$$F_p = +I_\mathrm{branch}$$

$$F_n = -I_\mathrm{branch}$$

$$F_{\mathrm{ctrl\_p}} = 0$$

$$F_{\mathrm{ctrl\_n}} = 0$$

$$F_\mathrm{branch} = V(p) - V(n) - \mathrm{factor} \cdot \mathrm{expr}$$

Current flows into **p** and out of **n**. Control terminals draw no current. The branch equation enforces the voltage source constraint.

### Jacobian Stamps (Implicit via Automatic Differentiation)

The `i` function is evaluated through the dual-number AD system (`S` type). The implicit Jacobian entries are:

$$\frac{\partial F_p}{\partial I_\mathrm{branch}} = +1$$

$$\frac{\partial F_n}{\partial I_\mathrm{branch}} = -1$$

$$\frac{\partial F_\mathrm{branch}}{\partial V(p)} = +1$$

$$\frac{\partial F_\mathrm{branch}}{\partial V(n)} = -1$$

$$\frac{\partial F_\mathrm{branch}}{\partial V(\mathrm{ctrl\_p})} = -\mathrm{factor} \cdot (c_1 + 2\,c_2\,V_\mathrm{ctrl})$$

$$\frac{\partial F_\mathrm{branch}}{\partial V(\mathrm{ctrl\_n})} = +\mathrm{factor} \cdot (c_1 + 2\,c_2\,V_\mathrm{ctrl})$$

These are extracted automatically by the AD framework; they are listed here for completeness.

## Notes

- No noise generators are defined for this device.
- No charge (`q`) function is defined; no reactive (capacitive/inductive) behavior.
- No `limit` or `attempt` convergence helpers are defined.
- Temperature is stored in Celsius; the Kelvin conversion cancels in the difference calculation.
- The device follows the ngspice `asrcload.c` voltage-source stamping path (lines 41-52 for temperature).
