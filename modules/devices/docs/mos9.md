# MOS Model 9 (Philips MOS9 / SPICE Level 3) -- Parameter & Equation Reference

> Semi-empirical MOSFET model with short-channel effects, velocity saturation, channel-length modulation, weak inversion, and Meyer gate capacitances. Derived from SPICE3f5/ngspice MOS level 3 (MOS9).

## Model Topology

The MOS9 device has four external terminals: **drain (D)**, **gate (G)**, **source (S)**, and **bulk (B)**. Two internal nodes, **drain' (D')** and **source' (S')**, are inserted between the external drain/source and the intrinsic channel to model the parasitic series resistances RD and RS. The intrinsic MOSFET sits between D' and S', with bulk diodes (B-S' and B-D') and Meyer-model gate capacitances distributed across G, D', S', and B.

```
D ──[ RD ]── D' ──┐
                   ├── intrinsic MOSFET ── S' ──[ RS ]── S
G ────────── gate  │
B ──── bulk diodes ┘
```

## Parameters

### DC Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `type_` | -- | -- | `1` | {-1, 1} | Device polarity: 1 = NMOS, -1 = PMOS |
| `vto` | $V_{T0}$ | V | `0` | -- | Zero-bias threshold voltage |
| `kp` | $K_P$ | A/V$^2$ | `2.07189 \times 10^{-5}$ | $\geq 0$ | Transconductance parameter |
| `gamma` | $\gamma$ | $\sqrt{\text{V}}$ | `0` | $\geq 0$ | Bulk threshold (body effect) parameter |
| `phi` | $\phi_s$ | V | `0.6` | $> 0$ | Surface inversion potential |
| `rd` | $R_D$ | $\Omega$ | `0` | $\geq 0$ | Drain ohmic resistance |
| `rs` | $R_S$ | $\Omega$ | `0` | $\geq 0$ | Source ohmic resistance |
| `u0` | $\mu_0$ | cm$^2$/V$\cdot$s | `600` | $> 0$ | Low-field surface mobility |
| `theta` | $\theta$ | 1/V | `0` | $\geq 0$ | Gate-voltage mobility degradation coefficient |
| `vmax` | $v_{max}$ | m/s | `0` | $\geq 0$ | Maximum carrier drift velocity (0 = no velocity saturation) |
| `eta` | $\eta_0$ | -- | `0` | $\geq 0$ | Static-feedback / DIBL coefficient |
| `kappa` | $\kappa$ | -- | `0.2` | $\geq 0$ | Channel-length modulation parameter |
| `alpha` | $\alpha$ | -- | `0` | $\geq 0$ | Impact ionization / CLM parameter |
| `delta` | $\delta$ | -- | `0` | $\geq 0$ | Width effect on threshold voltage (narrow-channel) |
| `input_delta` | -- | -- | `0` | -- | Input delta (user-supplied raw value) |
| `nfs` | $N_{fs}$ | cm$^{-2}$ | `0` | $\geq 0$ | Fast surface state density (0 = no weak inversion) |
| `nsub` | $N_{sub}$ | cm$^{-3}$ | `0` | $\geq 0$ | Substrate doping concentration |
| `nss` | $N_{ss}$ | cm$^{-2}$ | `0` | $\geq 0$ | Surface state density |
| `xj` | $X_j$ | m | `0` | $\geq 0$ | Metallurgical junction depth |
| `xd` | $X_d$ | -- | `0` | $\geq 0$ | Depletion-layer width coefficient |
| `delvto` | $\Delta V_{T0}$ | V | `0` | -- | Threshold voltage adjustment (global shift) |
| `tpg` | -- | -- | `0` | {0, 1, 2} | Gate material type |
| `fc` | $F_C$ | -- | `0.5` | $[0, 1)$ | Forward-bias junction capacitance fitting parameter |

### Geometry Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `tox` | $t_{ox}$ | m | $10^{-7}$ | $> 0$ | Gate oxide thickness |
| `ld` | $L_D$ | m | `0` | $\geq 0$ | Lateral diffusion length |
| `xl` | $X_L$ | m | `0` | -- | Length mask adjustment (delta L) |
| `wd` | $W_D$ | m | `0` | $\geq 0$ | Width narrowing (diffusion) |
| `xw` | $X_W$ | m | `0` | -- | Width mask adjustment (delta W) |
| `rsh` | $R_{sh}$ | $\Omega$/sq | `0` | $\geq 0$ | Drain/source diffusion sheet resistance |

### Junction Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `is_` | $I_S$ | A | $10^{-14}$ | $> 0$ | Bulk junction saturation current |
| `js` | $J_S$ | A/m$^2$ | `0` | $\geq 0$ | Bulk junction saturation current density |
| `pb` | $\phi_B$ | V | `0.8` | $> 0$ | Bulk junction built-in potential |
| `cbd` | $C_{BD}$ | F | `0` | $\geq 0$ | Zero-bias bulk-drain junction capacitance |
| `cbs` | $C_{BS}$ | F | `0` | $\geq 0$ | Zero-bias bulk-source junction capacitance |
| `cj` | $C_J$ | F/m$^2$ | `0` | $\geq 0$ | Zero-bias bottom junction capacitance per unit area |
| `mj` | $M_J$ | -- | `0.5` | $[0, 1)$ | Bottom junction grading coefficient |
| `cjsw` | $C_{JSW}$ | F/m | `0` | $\geq 0$ | Zero-bias sidewall junction capacitance per unit perimeter |
| `mjsw` | $M_{JSW}$ | -- | `0.33` | $[0, 1)$ | Sidewall junction grading coefficient |

### Overlap Capacitance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cgso` | $C_{GSO}$ | F/m | `0` | $\geq 0$ | Gate-source overlap capacitance per unit width |
| `cgdo` | $C_{GDO}$ | F/m | `0` | $\geq 0$ | Gate-drain overlap capacitance per unit width |
| `cgbo` | $C_{GBO}$ | F/m | `0` | $\geq 0$ | Gate-bulk overlap capacitance per unit length |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `kf` | $K_F$ | -- | `0` | $\geq 0$ | Flicker noise coefficient |
| `af` | $A_F$ | -- | `1` | $> 0$ | Flicker noise exponent |

### Temperature Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `tnom` | $T_{nom}$ | $^\circ$C | `27` | -- | Parameter measurement temperature |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `w` | $W$ | m | $10^{-6}$ | $> 0$ | Channel width |
| `l` | $L$ | m | $10^{-6}$ | $> 0$ | Channel length |

## Equations

### Effective Geometry

$$L_{eff} = \max(L - 2 L_D + X_L,\; 10^{-9})$$

$$W_{eff} = \max(W - 2 W_D + X_W,\; 10^{-9})$$

Drawn dimensions adjusted for lateral diffusion and mask bias; clamped to 1 nm minimum.

### Physical Constants (Computed)

$$V_T = k_B (T_{nom} + 273.15) / q = 8.617333 \times 10^{-5} \cdot (T_{nom} + 273.15)$$

$$\varepsilon_{ox} = 3.9 \times 8.854188 \times 10^{-12} \;\text{F/m}$$

$$C_{ox} = \varepsilon_{ox} / t_{ox}$$

$$C_{ox,tot} = C_{ox} \cdot L_{eff} \cdot W_{eff}$$

$$\varepsilon_{si} = 11.7 \times 8.854188 \times 10^{-12} \;\text{F/m}$$

$$\beta_0 = K_P \cdot W_{eff} / L_{eff}$$

### Parasitic Resistances

$$G_D = \begin{cases} 1/R_D & R_D > 0 \\ 10^{12} & R_D = 0 \end{cases}$$

$$G_S = \begin{cases} 1/R_S & R_S > 0 \\ 10^{12} & R_S = 0 \end{cases}$$

$$I_{RD} = (V_D - V_{D'}) \cdot G_D$$

$$I_{RS} = (V_S - V_{S'}) \cdot G_S$$

When $R_D = 0$ or $R_S = 0$, a large conductance ($10^{12}$ S) effectively shorts the external terminal to the internal node.

### Terminal Voltages

All internal voltages are referenced to source' and sign-flipped for PMOS ($\sigma = +1$ for NMOS, $-1$ for PMOS):

$$V_{GS} = (V_G - V_{S'}) \cdot \sigma$$

$$V_{DS} = (V_{D'} - V_{S'}) \cdot \sigma$$

$$V_{BS} = (V_B - V_{S'}) \cdot \sigma$$

$$V_{BD} = (V_B - V_{D'}) \cdot \sigma$$

### Source-Drain Reversal

If $V_{DS} < 0$, the source and drain roles are swapped:

$$V_{DS,neg} = \min(V_{DS}, 0)$$

$$V_{GS,eff} = V_{GS} - V_{DS,neg}$$

$$V_{BS,eff} = V_{BS} - V_{DS,neg}$$

In normal mode ($V_{DS} \geq 0$): $V_{GS,eff} = V_{GS}$, $V_{BS,eff} = V_{BS}$.
In inverse mode ($V_{DS} < 0$): $V_{GS,eff} = V_{GD}$, $V_{BS,eff} = V_{BD}$.

### Bulk-Junction Diode Currents

$$I_{BS} = I_S \left[\exp\!\left(\min\!\left(\frac{V_{BS}}{V_T},\, 80\right)\right) - 1\right] + g_{min} \cdot V_{BS}$$

$$I_{BD} = I_S \left[\exp\!\left(\min\!\left(\frac{V_{BD}}{V_T},\, 80\right)\right) - 1\right] + g_{min} \cdot V_{BD}$$

where $g_{min} = 10^{-12}$ S. The exponential argument is clamped to 80 to prevent overflow.

### Short-Channel Effect (fshort)

Active when both $X_j \neq 0$ and $X_d \neq 0$:

$$W_{PS} = X_d \cdot \sqrt{\phi_s - V_{BS,eff}}$$

Polynomial fit coefficients: $c_0 = 0.0631353$, $c_1 = 0.8013292$, $c_2 = -0.01110777$.

$$W_P/X_j = W_{PS} / X_j$$

$$W_C/X_j = c_0 + c_1 \cdot (W_P/X_j) + c_2 \cdot (W_P/X_j)^2$$

$$\arg_a = W_C/X_j + L_D / X_j$$

$$\arg_c = \frac{W_P/X_j}{1 + W_P/X_j}$$

$$\arg_b = \sqrt{\max(1 - \arg_c^2,\; 10^{-20})}$$

$$f_{short} = 1 - \frac{X_j}{L_{eff}} \left(\arg_a \cdot \arg_b - \frac{L_D}{X_j}\right)$$

When $X_j = 0$ or $X_d = 0$: $f_{short} = 1$ (no short-channel correction).

### Body Effect

$$\phi_{BS} = \max(\phi_s - V_{BS,eff},\; 0.001)$$

$$\gamma_s = \gamma \cdot f_{short}$$

$$f_{body,s} = \frac{\gamma_s}{2\sqrt{\phi_{BS}}}$$

Narrow-channel factor:

$$f_{narrow} = \frac{\delta \cdot \pi \cdot \varepsilon_{si}}{2 \cdot C_{ox} \cdot W_{eff}}$$

$$f_{body} = f_{body,s} + f_{narrow}$$

$$\frac{1}{1 + f_{body}} = onfbdy$$

Charge term:

$$Q_B / C_{ox} = \gamma_s \sqrt{\phi_{BS}} + f_{narrow} \cdot \phi_{BS}$$

### Threshold Voltage

Built-in voltage (includes $\Delta V_{T0}$):

$$V_{bi} = V_{T0} + \Delta V_{T0} - \gamma \sqrt{\phi_s}$$

DIBL eta factor (computed from physical parameters):

$$\eta_{eff} = \eta_0 \cdot \frac{8.15 \times 10^{-22}}{C_{ox} \cdot L_{eff}^3}$$

$$V_{bix} = V_{bi} - \eta_{eff} \cdot |V_{DS}|$$

$$V_{th} = V_{bix} + Q_B/C_{ox}$$

### Weak Inversion (Subthreshold)

Active when $N_{fs} \neq 0$:

$$C_s/C_{ox} = \frac{q \cdot N_{fs} \cdot 10^4 \cdot L_{eff} \cdot W_{eff}}{C_{ox,tot}}$$

$$C_d/C_{ox} = \frac{Q_B/C_{ox}}{2\,\phi_{BS}}$$

$$x_n = 1 + C_s/C_{ox} + C_d/C_{ox}$$

$$V_{on} = V_{th} + V_T \cdot x_n$$

When $N_{fs} = 0$: $V_{on} = V_{th}$, $x_n = 1$ (no weak-inversion transition).

### Effective Gate Voltage

$$V_{GS,x} = \max(V_{GS,eff},\; V_{on})$$

Clamps the gate voltage to $V_{on}$ for strong-inversion evaluation.

### Mobility Degradation

$$f_{gate} = \frac{1}{1 + \theta \cdot (V_{GS,x} - V_{th})}$$

$$\mu_s = \mu_0 \times 10^{-4} \cdot f_{gate}$$

$\mu_0$ is in cm$^2$/V$\cdot$s; the $10^{-4}$ factor converts to m$^2$/V$\cdot$s.

### Saturation Voltage

**Without velocity saturation** ($v_{max} = 0$):

$$V_{dsat} = (V_{GS,x} - V_{th}) \cdot onfbdy$$

**With velocity saturation** ($v_{max} > 0$):

$$V_{DSC} = \frac{L_{eff} \cdot v_{max}}{\mu_s}$$

$$V_{dsat,0} = (V_{GS,x} - V_{th}) \cdot onfbdy$$

$$V_{dsat} = V_{dsat,0} + V_{DSC} - \sqrt{V_{dsat,0}^2 + V_{DSC}^2}$$

This is the standard harmonic-mean clamping formula ensuring $V_{dsat} \leq \min(V_{dsat,0}, V_{DSC})$.

### Effective Drain-Source Voltage

$$V_{DS,x} = \min(|V_{DS}|,\; V_{dsat})$$

Clamps the drain-source voltage to saturation for current computation.

### Drain Current

**Linear/saturation unified formula:**

$$I_{DS,norm} = \left[V_{GS,x} - V_{th} - \frac{1}{2}(1 + f_{body}) \cdot V_{DS,x}\right] \cdot V_{DS,x}$$

$$\beta_{eff} = \beta_0 \cdot f_{gate}$$

$$I_{DS} = \beta_{eff} \cdot I_{DS,norm}$$

### Velocity Saturation Correction

Active when $v_{max} > 0$:

$$f_{drain} = \frac{1}{1 + V_{DS,x} / V_{DSC}}$$

$$I_{DS} \leftarrow I_{DS} \cdot f_{drain}$$

### Channel-Length Modulation (CLM)

Active when both $\alpha \neq 0$ and $\kappa \neq 0$:

$$V_{DS,over} = \max(|V_{DS}| - V_{dsat},\; 0)$$

$$\Delta L = \sqrt{\max(\kappa \cdot \alpha \cdot V_{DS,over},\; 0)}$$

$$\frac{\Delta L}{L_{eff}} = \min\!\left(\frac{\Delta L}{L_{eff}},\; 0.499\right)$$

$$f_{CLM} = \frac{1}{1 - \Delta L / L_{eff}}$$

$$I_{DS} \leftarrow I_{DS} \cdot f_{CLM}$$

The $\Delta L / L_{eff}$ ratio is clamped to 0.499 to prevent singularity.

### Weak-Inversion Current Correction

Active when $N_{fs} \neq 0$:

$$w_{arg} = \text{clamp}\!\left(\frac{V_{GS,eff} - V_{on}}{V_T / x_n},\; -40,\; 40\right)$$

$$w_{fact} = \min\!\left(e^{w_{arg}},\; 1\right)$$

$$I_{DS} \leftarrow I_{DS} \cdot w_{fact}$$

In weak inversion ($V_{GS} < V_{on}$), $w_{fact} < 1$ exponentially reduces current. In strong inversion ($V_{GS} \geq V_{on}$), $w_{fact} = 1$ (no effect since $V_{GS,x}$ was clamped to $V_{on}$).

### External Channel Current (with reversal and PMOS sign)

Smooth sign function:

$$\text{sgn}(V_{DS}) = \frac{V_{DS}}{|V_{DS}| + 10^{-30}}$$

$$I_{DS,ext} = I_{DS} \cdot \text{sgn}(V_{DS}) \cdot \sigma$$

The $\epsilon = 10^{-30}$ prevents division by zero while preserving sign.

### KCL Stamp (DC)

| Node | Current Contribution |
|------|---------------------|
| D | $-I_{RD}$ |
| D' | $+I_{RD} - I_{DS,ext} + I_{BD}$ |
| G | $0$ |
| S | $-I_{RS}$ |
| S' | $+I_{RS} + I_{DS,ext} + I_{BS}$ |
| B | $-I_{BS} - I_{BD}$ |

### Gate Overlap Charges

$$Q_{GS,ov} = C_{GSO} \cdot W_{eff} \cdot V_{GS}$$

$$Q_{GD,ov} = C_{GDO} \cdot W_{eff} \cdot V_{GD}$$

$$Q_{GB,ov} = C_{GBO} \cdot L_{eff} \cdot V_{GB}$$

Note: In the charge function, terminal voltages are referenced directly (not type-flipped for PMOS), as charges are symmetric.

### Intrinsic Gate Charges (Smooth Meyer Model)

Simplified threshold for charge model (without short-channel effects):

$$\phi_{BS,q} = \max(\phi_s - V_{BS},\; 0.001)$$

$$V_{th,q} = V_{bi} + \gamma \sqrt{\phi_{BS,q}}$$

$$V_{GST} = V_{GS} - V_{th,q}$$

$$V_{dsat,q} = \max(V_{GST},\; 0.01)$$

Smooth inversion transition function:

$$V_{GST,+} = \max(V_{GST},\; 0)$$

$$f_{inv} = \frac{V_{GST,+}}{V_{GST,+} + 0.1}$$

Smooth saturation factor:

$$f_{sat} = \frac{|V_{DS}|}{V_{dsat,q} + |V_{DS}|}$$

where $|V_{DS}|$ has a $10^{-20}$ additive floor for numerical safety.

Intrinsic capacitances as fractions of $C_{ox,tot}$:

$$C_{GS,intr} = \tfrac{2}{3}\, C_{ox,tot} \cdot f_{inv}$$

$$C_{GD,intr} = \tfrac{2}{3}\, C_{ox,tot} \cdot f_{inv} \cdot (1 - f_{sat})$$

$$C_{GB,intr} = C_{ox,tot} \cdot (1 - f_{inv})$$

Intrinsic charges:

$$Q_{GS,intr} = C_{GS,intr} \cdot V_{GS}$$

$$Q_{GD,intr} = C_{GD,intr} \cdot V_{GD}$$

$$Q_{GB,intr} = C_{GB,intr} \cdot V_{GB}$$

### Total Gate Charges

$$Q_{GS} = Q_{GS,ov} + Q_{GS,intr}$$

$$Q_{GD} = Q_{GD,ov} + Q_{GD,intr}$$

$$Q_{GB} = Q_{GB,ov} + Q_{GB,intr}$$

### Bulk-Junction Depletion Charges

Standard SPICE junction charge model. Active when $C_{BS} > 0$ or $C_J > 0$:

$$Q_{BS} = \frac{C_{BS} \cdot \phi_B}{1 - M_J} \left[1 - \left(\max\!\left(1 - \frac{V_{BS}}{\phi_B},\; 0.001\right)\right)^{1-M_J}\right]$$

$$Q_{BD} = \frac{C_{BD} \cdot \phi_B}{1 - M_J} \left[1 - \left(\max\!\left(1 - \frac{V_{BD}}{\phi_B},\; 0.001\right)\right)^{1-M_J}\right]$$

The argument to the power function is clamped to $\geq 0.001$ for numerical safety.

### KCL Stamp (Charge)

| Node | Charge Contribution |
|------|---------------------|
| D | $0$ |
| D' | $-Q_{GD} - Q_{BD}$ |
| G | $+Q_{GS} + Q_{GD} + Q_{GB}$ |
| S | $0$ |
| S' | $-Q_{GS} - Q_{BS}$ |
| B | $-Q_{GB} + Q_{BS} + Q_{BD}$ |

The solver computes displacement currents as $I_C = dQ/dt$ for transient analysis.

### Noise Sources

Four noise generators are defined:

| Source | Nodes | Type | Spectral Density |
|--------|-------|------|-----------------|
| Drain resistance | D -- D' | Thermal | $S_I = 4kT \cdot G_D$ |
| Source resistance | S -- S' | Thermal | $S_I = 4kT \cdot G_S$ |
| Channel shot noise | D' -- S' | Shot | $S_I = 2q \cdot I_{DS}$ |
| Channel flicker noise | D' -- S' | Flicker | $S_I = K_F \cdot I_{DS}^{A_F} / f$ |

### Convergence Aid: Parameter Stepping (attempt)

For continuation-method convergence, the junction saturation current is scaled with homotopy factor $\lambda \in [0, 1]$:

$$I_S(\lambda) = I_S + g_{min} \cdot (1 - \lambda)$$

where $g_{min} = 10^{-12}$. At $\lambda = 0$ (start), the extra conductance linearizes the junctions; at $\lambda = 1$ (final), the original parameters are recovered.

### Voltage Limiting (Newton Step Damping)

Three limiting functions are applied each Newton iteration to prevent overshoot.

#### FET Gate Voltage Limiting (fetLimit)

Limits $V_{GS}$ based on proximity to $V_{T0}$:

$$V_{tsthi} = |2(V_{GS,old} - V_{T0})| + 2$$

$$V_{tstlo} = V_{tsthi}/2 + 2$$

$$V_{tox} = V_{T0} + 3.5$$

**Region logic:**

- If $V_{GS,old} \geq V_{tox}$ (deep conduction):
  - $\Delta V \leq 0$: $V_{GS,new} \leftarrow \max(V_{GS,new},\; V_{GS,old} - V_{tstlo})$
  - $\Delta V > 0$: $V_{GS,new} \leftarrow \min(V_{GS,new},\; V_{GS,old} + V_{tsthi})$
- If $V_{T0} \leq V_{GS,old} < V_{tox}$ (near threshold):
  - $\Delta V \leq 0$: $V_{GS,new} \leftarrow \max(V_{GS,new},\; V_{T0} - 0.5)$
  - $\Delta V > 0$: $V_{GS,new} \leftarrow \min(V_{GS,new},\; V_{GS,old} + V_{tsthi})$
- If $V_{GS,old} < V_{T0}$ (below threshold):
  - $\Delta V \leq 0$: $V_{GS,new} \leftarrow \max(V_{GS,new},\; V_{GS,old} - V_{tstlo})$
  - $\Delta V > 0$: $V_{GS,new} \leftarrow \min(V_{GS,new},\; V_{T0} + 0.5)$

#### Drain-Source Voltage Limiting (limvds)

If $V_{DS,old} \geq 3.5$:
- $\Delta V \leq 0$: $V_{DS,new} \leftarrow \max(V_{DS,new},\; -0.5 \cdot V_{DS,old})$
- $\Delta V > 0$: $V_{DS,new} \leftarrow \min(V_{DS,new},\; 2 \cdot V_{DS,old})$

If $V_{DS,old} < 3.5$ and $V_{DS,new} > 4$: $V_{DS,new} \leftarrow 4$.

Otherwise: no limiting.

#### PN Junction Voltage Limiting (pnLimit)

Applied to both $V_{BS}$ and $V_{BD}$. Uses $V_T = 0.02585$ V, $V_{crit} = 0.6166$ V.

If $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2V_T$:

- If $V_{old} > 0$:

$$\arg = 1 + \frac{V_{new} - V_{old}}{V_T}$$

$$V_{new} \leftarrow \begin{cases} V_{old} + V_T \ln(\arg) & \arg > 0 \\ V_{crit} & \arg \leq 0 \end{cases}$$

- If $V_{old} \leq 0$:

$$V_{new} \leftarrow V_T \ln\!\left(\frac{V_{new}}{V_T}\right)$$

Otherwise: no limiting applied.

#### Limiting Application Order

1. $V_{GS}$ limited via fetLimit, gate node adjusted: $V_G = V_{S'} + V_{GS,lim}$
2. $V_{DS}$ limited via limvds, drain' node adjusted: $V_{D'} = V_{S'} + V_{DS,lim}$
3. $V_{BS}$ limited via pnLimit, bulk node adjusted: $V_B = V_{S'} + V_{BS,lim}$
4. $V_{BD}$ limited via pnLimit, drain' node re-adjusted: $V_{D'} = V_B - V_{BD,lim}$
