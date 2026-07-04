# Coupled Transmission Lines (CPL) -- Parameter & Equation Reference

> Coupled multiconductor transmission lines with modal decomposition (2-conductor symmetric system, history-dependent)

## Model Topology

Six-terminal device: two transmission lines (line 1, line 2) each with a near-end port (A) and far-end port (B), plus independent ground references for each port pair. Terminals are `a1` (line 1 port A), `a2` (line 2 port A), `gnd_a` (port A ground), `b1` (line 1 port B), `b2` (line 2 port B), `gnd_b` (port B ground). The coupled pair is decomposed into even (common) and odd (differential) propagation modes via eigendecomposition of the per-unit-length $\mathbf{L}$ and $\mathbf{C}$ matrices; each mode propagates independently as a single transmission line with its own characteristic impedance and delay, with losses modeled as lumped series resistance and shunt conductance per mode.

## Parameters

### Model Parameters (Per-Unit-Length)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `r` | $R$ | $\Omega/\text{m}$ | 0.2 | $\geq 0$ | Self resistance per unit length (diagonal) |
| `l` | $L$ | $\text{H/m}$ | 9.13e-9 | $\geq 0$ | Self inductance per unit length (diagonal) |
| `c` | $C$ | $\text{F/m}$ | 3.65e-13 | $\geq 0$ | Self capacitance per unit length (diagonal) |
| `g` | $G$ | $\text{S/m}$ | 0.0 | $\geq 0$ | Self conductance per unit length (diagonal) |
| `lm` | $L_m$ | $\text{H/m}$ | 0.0 | -- | Mutual inductance per unit length (off-diagonal) |
| `cm` | $C_m$ | $\text{F/m}$ | 0.0 | -- | Mutual capacitance per unit length (off-diagonal, typically negative) |
| `rm` | $R_m$ | $\Omega/\text{m}$ | 0.0 | -- | Mutual resistance per unit length (off-diagonal) |
| `gm` | $G_m$ | $\text{S/m}$ | 0.0 | -- | Mutual conductance per unit length (off-diagonal) |
| `length` | $\ell$ | m | 10.0 | $> 0$ | Physical length of the coupled lines |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `temp` | $T$ | K | 300.15 | $> 0$ | Device temperature |
| `m` | $M$ | -- | 1.0 | $> 0$ | Parallel multiplier (scales all currents) |

### History Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_delay` | 1e-6 s | Maximum delay buffer length |
| `interp_order` | 1 | Linear interpolation for past-value lookup |

## Equations

### Per-Unit-Length Matrices

The 2x2 per-unit-length parameter matrices:

$$
\mathbf{L} = \begin{bmatrix} L & L_m \\ L_m & L \end{bmatrix}, \qquad
\mathbf{C} = \begin{bmatrix} C & C_m \\ C_m & C \end{bmatrix}
$$

$$
\mathbf{R} = \begin{bmatrix} R & R_m \\ R_m & R \end{bmatrix}, \qquad
\mathbf{G} = \begin{bmatrix} G & G_m \\ G_m & G \end{bmatrix}
$$

### Modal Decomposition (Eigenvalues of $\mathbf{L}\mathbf{C}$)

The orthonormal modal transformation matrix for the symmetric 2-conductor case:

$$
\mathbf{T} = \frac{1}{\sqrt{2}} \begin{bmatrix} 1 & 1 \\ 1 & -1 \end{bmatrix}
$$

Per-mode inductance and capacitance from eigendecomposition:

$$
L_{\text{even}} = L + L_m, \qquad C_{\text{even}} = C + C_m
$$

$$
L_{\text{odd}} = L - L_m, \qquad C_{\text{odd}} = C - C_m
$$

Clamping to avoid degenerate values:

$$
L_{m,\text{safe}} = \max(L_m, 1 \times 10^{-30}), \qquad C_{m,\text{safe}} = \max(C_m, 1 \times 10^{-30})
$$

Applied to both even and odd mode $L$ and $C$ values.

### Characteristic Impedance and Admittance (Per-Mode, Lossless)

$$
Z_{0,\text{even}} = \sqrt{\frac{L_{\text{even,safe}}}{C_{\text{even,safe}}}}, \qquad
Z_{0,\text{odd}} = \sqrt{\frac{L_{\text{odd,safe}}}{C_{\text{odd,safe}}}}
$$

$$
Y_{0,m} = \begin{cases} 1 / Z_{0,m} & \text{if } Z_{0,m} > 0 \\ 1 \times 10^{-12} & \text{otherwise} \end{cases}
$$

### Propagation Delay (Per-Mode)

Eigenvalues of $\mathbf{L}\mathbf{C}$:

$$
\lambda_{\text{even}} = (L + L_m)(C + C_m), \qquad \lambda_{\text{odd}} = (L - L_m)(C - C_m)
$$

Clamped: $\lambda_m = \max(\lambda_m, 1 \times 10^{-30})$

$$
\tau_{\text{even}} = \ell \cdot \sqrt{\lambda_{\text{even}}}, \qquad \tau_{\text{odd}} = \ell \cdot \sqrt{\lambda_{\text{odd}}}
$$

The solver uses these two delays for history-buffer interpolation at $t - \tau_m$.

### Per-Mode Lumped Losses

Series resistance (total, for the full line length):

$$
R_{\text{self,clamped}} = \max(R, 1 \times 10^{-4})
$$

$$
R_{\text{even,total}} = (R_{\text{self,clamped}} + R_m) \cdot \ell
$$

$$
R_{\text{odd,total}} = \max\!\bigl((R_{\text{self,clamped}} - R_m) \cdot \ell,\; 1 \times 10^{-30}\bigr)
$$

Series conductance (inverse of series resistance):

$$
G_{\text{series,even}} = \frac{1}{R_{\text{even,total}}}, \qquad G_{\text{series,odd}} = \frac{1}{R_{\text{odd,total}}}
$$

Shunt conductance (total, for the full line length):

$$
G_{\text{even,total}} = (G + G_m) \cdot \ell
$$

$$
G_{\text{odd,total}} = \max\!\bigl((G - G_m) \cdot \ell,\; 0\bigr)
$$

### Modal Voltage Transformation

Port voltages relative to ground references:

$$
V_{a1} = V(\texttt{a1}) - V(\texttt{gnd\_a}), \quad V_{a2} = V(\texttt{a2}) - V(\texttt{gnd\_a})
$$

$$
V_{b1} = V(\texttt{b1}) - V(\texttt{gnd\_b}), \quad V_{b2} = V(\texttt{b2}) - V(\texttt{gnd\_b})
$$

Physical-to-modal transformation:

$$
V_{a,\text{even}} = \frac{V_{a1} + V_{a2}}{\sqrt{2}}, \qquad V_{a,\text{odd}} = \frac{V_{a1} - V_{a2}}{\sqrt{2}}
$$

$$
V_{b,\text{even}} = \frac{V_{b1} + V_{b2}}{\sqrt{2}}, \qquad V_{b,\text{odd}} = \frac{V_{b1} - V_{b2}}{\sqrt{2}}
$$

### Per-Mode Current Contributions

**Wave admittance stamp** (instantaneous):

$$
I_{a,m}^{\text{wave}} = Y_{0,m} \cdot V_{a,m}, \qquad I_{b,m}^{\text{wave}} = Y_{0,m} \cdot V_{b,m}
$$

**DC series resistance stamp** (port A to port B per mode):

$$
I_{\text{series},m} = G_{\text{series},m} \cdot (V_{a,m} - V_{b,m})
$$

**Shunt conductance stamp** (at each port per mode):

$$
I_{\text{shunt},a,m} = G_{m,\text{total}} \cdot V_{a,m}, \qquad I_{\text{shunt},b,m} = G_{m,\text{total}} \cdot V_{b,m}
$$

**Total modal current at each port:**

$$
I_{a,m}^{\text{total}} = I_{a,m}^{\text{wave}} + I_{\text{series},m} + I_{\text{shunt},a,m}
$$

$$
I_{b,m}^{\text{total}} = I_{b,m}^{\text{wave}} - I_{\text{series},m} + I_{\text{shunt},b,m}
$$

Note: series current enters port A and exits port B (sign reversal at port B).

### Modal-to-Physical Current Transformation (Inverse)

$$
I_{a1}^{\text{phys}} = \frac{I_{a,\text{even}}^{\text{total}} + I_{a,\text{odd}}^{\text{total}}}{\sqrt{2}}, \qquad
I_{a2}^{\text{phys}} = \frac{I_{a,\text{even}}^{\text{total}} - I_{a,\text{odd}}^{\text{total}}}{\sqrt{2}}
$$

$$
I_{b1}^{\text{phys}} = \frac{I_{b,\text{even}}^{\text{total}} + I_{b,\text{odd}}^{\text{total}}}{\sqrt{2}}, \qquad
I_{b2}^{\text{phys}} = \frac{I_{b,\text{even}}^{\text{total}} - I_{b,\text{odd}}^{\text{total}}}{\sqrt{2}}
$$

### GMIN Convergence Aid

Small conductance to ground added at each physical port node:

$$
G_{\min} = 1 \times 10^{-12} \;\text{S}
$$

### Final Node Currents (KCL Residuals)

Scaled by the parallel multiplier $M$:

$$
I_{\texttt{a1}} = M \cdot \bigl(I_{a1}^{\text{phys}} + G_{\min} \cdot V_{a1}\bigr)
$$

$$
I_{\texttt{a2}} = M \cdot \bigl(I_{a2}^{\text{phys}} + G_{\min} \cdot V_{a2}\bigr)
$$

$$
I_{\texttt{b1}} = M \cdot \bigl(I_{b1}^{\text{phys}} + G_{\min} \cdot V_{b1}\bigr)
$$

$$
I_{\texttt{b2}} = M \cdot \bigl(I_{b2}^{\text{phys}} + G_{\min} \cdot V_{b2}\bigr)
$$

Ground node return currents (KCL conservation):

$$
I_{\texttt{gnd\_a}} = -(I_{\texttt{a1}} + I_{\texttt{a2}})
$$

$$
I_{\texttt{gnd\_b}} = -(I_{\texttt{b1}} + I_{\texttt{b2}})
$$

### History Output Function

The history buffer records a weighted sum of all modal port voltages at each accepted timepoint:

$$
\text{histOut} = Y_{0,\text{even}} \cdot V_{a,\text{even}} + Y_{0,\text{odd}} \cdot V_{a,\text{odd}} + Y_{0,\text{even}} \cdot V_{b,\text{even}} + Y_{0,\text{odd}} \cdot V_{b,\text{odd}}
$$

This derives from the incident wave definition $a = (V + Z_0 I)/2$; for the lossless characteristic admittance stamp where $I = Y_0 V$, this reduces to $a = V$, so modal voltages weighted by their admittances capture the wave state. The solver interpolates past values at $t - \tau_m$ for each mode to compute reflected wave current sources.
