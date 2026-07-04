# CCVS (H-Element) -- Parameter & Equation Reference

> Current-Controlled Voltage Source: output voltage is proportional to a controlling branch current.

## Model Topology

The CCVS has four unknowns: two external voltage nodes (`p`, `n`), a controlling branch current (`ctrl_br`) sensed from another element, and its own internal branch current (`br`). The device forces `V(p) - V(n) = gain * I_ctrl` via a branch equation, while its branch current `I_br` flows from `p` to `n` through the external circuit. Three of the four unknowns are external ports (`p`, `n`, `ctrl_br`); the fourth (`br`) is the device's own branch current unknown classified as a current-type unknown.

### Unknown Vector

| Index | Name     | Kind    | Role                              |
|-------|----------|---------|-----------------------------------|
| 0     | `p`      | voltage | Positive output terminal          |
| 1     | `n`      | voltage | Negative output terminal          |
| 2     | `ctrl_br`| current | Controlling branch current (port) |
| 3     | `br`     | current | Device branch current (internal)  |

**External ports:** 3 (`p`, `n`, `ctrl_br`)

## Parameters

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `gain`    | $H$    | Ohm (V/A) | 0.0 | $(-\infty, +\infty)$ | Transresistance gain: $V_{out} = H \cdot I_{ctrl}$ |

### Model Parameters

None. The CCVS `Model` struct is empty; all behavior is controlled by the instance parameter.

## Equations

### Branch Constitutive Equation

The device is purely algebraic (no charge function `q`, no state). The physics function `i` returns a 4-element KCL residual vector.

#### Output voltage constraint (branch equation)

$$f_3 = V_p - V_n - H \cdot I_{ctrl} = 0$$

This is the defining equation of the CCVS. It constrains the voltage across the output terminals to equal the transresistance gain multiplied by the controlling branch current. Entered as residual in the branch-current row.

#### KCL at terminal p

$$f_0 = I_{br}$$

The device's branch current flows **into** the positive terminal.

#### KCL at terminal n

$$f_1 = -I_{br}$$

The device's branch current flows **out of** the negative terminal (current conservation).

#### Controlling branch contribution

$$f_2 = 0$$

The device contributes zero current to the controlling branch equation (it only senses that current).

### Full Residual Vector

$$\mathbf{f} = \begin{bmatrix} I_{br} \\ -I_{br} \\ 0 \\ V_p - V_n - H \cdot I_{ctrl} \end{bmatrix}$$

### Jacobian (Stamp) Structure

The Jacobian $\partial \mathbf{f} / \partial \mathbf{x}$ where $\mathbf{x} = [V_p,\; V_n,\; I_{ctrl},\; I_{br}]^T$:

$$G = \begin{bmatrix}
0 & 0 & 0 & 1 \\
0 & 0 & 0 & -1 \\
0 & 0 & 0 & 0 \\
1 & -1 & -H & 0
\end{bmatrix}$$

| Entry | Row | Col | Value | Origin |
|-------|-----|-----|-------|--------|
| $G_{0,3}$  | `p`  | `br`     | $+1$ | $\partial f_0 / \partial I_{br}$ |
| $G_{1,3}$  | `n`  | `br`     | $-1$ | $\partial f_1 / \partial I_{br}$ |
| $G_{3,0}$  | `br` | `p`      | $+1$ | $\partial f_3 / \partial V_p$ |
| $G_{3,1}$  | `br` | `n`      | $-1$ | $\partial f_3 / \partial V_n$ |
| $G_{3,2}$  | `br` | `ctrl_br`| $-H$ | $\partial f_3 / \partial I_{ctrl}$ |

### Charge / Reactive Terms

None. No `q` function is defined; the device is purely resistive/algebraic with no energy storage.

### Noise

None. No `noise_gens` declared.

### Limiting / Convergence Aids

None. No `limit` or `attempt` functions defined.

### Temperature Dependence

None. No temperature coefficients or temperature processing.
