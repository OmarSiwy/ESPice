# JFET2 (Parker-Skellern) -- Parameter & Equation Reference

> Junction FET / MESFET Level 2 model based on Parker-Skellern dual power-law formulation (ngspice psmodel.c / jfet2load.c)

## Model Topology

Three-terminal device (drain, gate, source) with two internal nodes (drain_prime, source_prime) introduced by series resistances Rd and Rs. The gate forms two pn-junction diodes (gate-source, gate-drain) with forward conduction, reverse breakdown, and depletion capacitances. The channel current between drain_prime and source_prime follows the Parker-Skellern dual power-law equation with source-drain reversal symmetry, channel-length modulation, velocity saturation, subthreshold conduction, and thermal current reduction.

**Nodes:** `drain (D)`, `gate (G)`, `source (S)`, `drain_prime (D')`, `source_prime (S')`

**External ports:** 3 (D, G, S)

## Parameters

### Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `acgam` | $\gamma_{ac}$ | -- | 0 | -- | Capacitance modulation parameter |
| `af` | $AF$ | -- | 1 | -- | Flicker noise exponent |
| `beta` | $\beta$ | A/V^Q | 1e-4 | -- | Transconductance parameter |
| `cds` | $C_{ds}$ | F | 0 | -- | Drain-source junction capacitance |
| `cgd` | $C_{gd0}$ | F | 0 | -- | Gate-drain junction capacitance |
| `cgs` | $C_{gs0}$ | F | 0 | -- | Gate-source junction capacitance |
| `delta` | $\delta$ | 1/W | 0 | -- | Coefficient of thermal current reduction |
| `hfeta` | $\eta_{hf}$ | -- | 0 | -- | Drain feedback modulation (HF) |
| `hfe1` | $hfe_1$ | -- | 0 | -- | HF drain feedback parameter 1 |
| `hfe2` | $hfe_2$ | -- | 0 | -- | HF drain feedback parameter 2 |
| `hfg1` | $hfg_1$ | -- | 0 | -- | HF gate feedback parameter 1 |
| `hfg2` | $hfg_2$ | -- | 0 | -- | HF gate feedback parameter 2 |
| `hfgam` | $\gamma_{hf}$ | -- | 0 | -- | High frequency drain feedback parameter |
| `mvst` | $m_{vst}$ | -- | 0 | -- | Modulation index for subthreshold current |
| `mxi` | $m_{\xi}$ | -- | 0 | -- | Saturation potential modulation parameter |
| `fc` | $FC$ | -- | 0.5 | -- | Forward bias junction fit parameter |
| `ibd` | $I_{BD}$ | A | 0 | -- | Breakdown current of diode junction |
| `is` | $I_S$ | A | 1e-14 | -- | Gate junction saturation current |
| `kf` | $KF$ | -- | 0 | -- | Flicker noise coefficient |
| `lambda` | $\lambda$ | 1/V | 0 | -- | Channel length modulation parameter |
| `lfgam` | $\gamma_{lf}$ | -- | 0 | -- | LF drain feedback parameter |
| `lfg1` | $lfg_1$ | -- | 0 | -- | LF gate feedback parameter 1 |
| `lfg2` | $lfg_2$ | -- | 0 | -- | LF gate feedback parameter 2 |
| `n` | $n$ | -- | 1 | -- | Gate junction ideality factor |
| `p` | $P$ | -- | 2 | -- | Power law exponent (triode region) |
| `q` | $Q$ | -- | 2 | -- | Power law exponent (saturated region) |
| `pb` | $\phi_B$ | V | 1 | -- | Gate junction built-in potential |
| `rd` | $R_d$ | Ohm | 0 | -- | Drain ohmic resistance |
| `rs` | $R_s$ | Ohm | 0 | -- | Source ohmic resistance |
| `taud` | $\tau_d$ | s | 0 | -- | Thermal relaxation time |
| `taug` | $\tau_g$ | s | 0 | -- | Drain feedback relaxation time |
| `vbd` | $V_{BD}$ | V | 1 | -- | Breakdown potential of diode junction |
| `ver` | -- | -- | 0 | -- | Version number of PS model |
| `vst` | $V_{ST}$ | V | 0 | -- | Critical potential for subthreshold conduction |
| `vto` | $V_{TO}$ | V | -2 | -- | Threshold voltage |
| `xc` | $x_c$ | -- | 0 | -- | Amount of capacitance reduction at pinch-off |
| `xi` | $\xi$ | -- | 1000 | -- | Velocity saturation index |
| `z` | $Z$ | -- | 1 | -- | Rate of velocity saturation |
| `tnom` | $T_{nom}$ | degC | 27 | -- | Parameter measurement temperature |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `area` | $A$ | -- | 1.0 | -- | Device area multiplier |
| `m` | $M$ | -- | 1.0 | -- | Parallel device multiplier |
| `temp` | $T$ | degC | 27.0 | -- | Device temperature |
| `dtemp` | $\Delta T$ | degC | 0.0 | -- | Temperature offset from circuit |
| `w` | $W$ | m | 1e-6 | -- | Device width |
| `l` | $L$ | m | 1e-6 | -- | Device length |

## Equations

### Effective Area and Thermal Voltage

$$A_{eff} = \text{area} \cdot M$$

$$T_{dev} = T + 273.15 + \Delta T$$

$$NV_T = T_{dev} \cdot \frac{k}{q} \cdot n$$

where $k/q = 8.617333262145 \times 10^{-5}$ V/K.

### Junction Voltages

$$V_{GS} = V_G - V_{S'}$$
$$V_{GD} = V_G - V_{D'}$$
$$V_{DS} = V_{D'} - V_{S'}$$

### Series Resistances

$$G_{Rd} = \frac{A_{eff}}{R_d}, \quad G_{Rs} = \frac{A_{eff}}{R_s}$$

If $R_d = 0$ or $R_s = 0$, conductance is set to $10^{12}$ S (short circuit).

$$I_{Rd} = G_{Rd} \cdot (V_D - V_{D'})$$
$$I_{Rs} = G_{Rs} \cdot (V_S - V_{S'})$$

### Gate Junction Diode -- Forward Conduction

Three-region piecewise model with constants $F_X = -10$, $M_X = 40$, $E_{MX} = e^{40}$.

$$\text{arg} = \frac{V}{NV_T}$$

**Region 1** ($\text{arg} \le F_X$, extreme cutoff):
$$I_{fwd} = -I_{SAT} + G_{min} \cdot V$$

**Region 2** ($F_X < \text{arg} < M_X$, normal):
$$I_{fwd} = I_{SAT} \left(e^{\text{arg}} - 1\right) + G_{min} \cdot V$$

**Region 3** ($\text{arg} \ge M_X$, overflow linearization):
$$I_{fwd} = I_{SAT} \cdot E_{MX} \cdot (\text{arg} - M_X + 1) - I_{SAT} + G_{min} \cdot V$$

where $I_{SAT} = I_S \cdot A_{eff}$ and $G_{min} = 10^{-12}$ S.

Applied to both gate-source ($V = V_{GS}$) and gate-drain ($V = V_{GD}$) junctions.

### Gate Junction Diode -- Reverse Breakdown

$$\text{arg} = \frac{-V}{V_{BD}}$$

**Region 1** ($\text{arg} \le F_X$, below breakdown):
$$I_{rev} = I_{BD}$$

**Region 2** ($F_X < \text{arg} < M_X$, normal breakdown):
$$I_{rev} = -\left(I_{BD} \cdot e^{\text{arg}} - I_{BD}\right)$$

**Region 3** ($\text{arg} \ge M_X$, extreme breakdown linearization):
$$I_{rev} = -\left(I_{BD} \cdot E_{MX} \cdot (\text{arg} - M_X + 1) - I_{BD}\right)$$

where $I_{BD} = \text{ibd} \cdot A_{eff}$.

**Total junction currents:**
$$I_{GS} = I_{GS,fwd} + I_{GS,rev}$$
$$I_{GD} = I_{GD,fwd} + I_{GD,rev}$$

### Source-Drain Reversal

The model enforces $V_{DS}^{eff} \ge 0$ via source-drain swapping:

$$V_{GS}^{arg} = \begin{cases} V_{GD} & V_{DS} < 0 \\ V_{GS} & V_{DS} \ge 0 \end{cases}$$

$$V_{GD}^{arg} = \begin{cases} V_{GS} & V_{DS} < 0 \\ V_{GD} & V_{DS} \ge 0 \end{cases}$$

$$V_{DS}^{eff} = V_{GS}^{arg} - V_{GD}^{arg} \ge 0$$

### Precomputed Model Constants

$$w_{oo} = \phi_B - V_{TO}$$
$$\xi \cdot w_{oo} = \xi \cdot w_{oo}$$
$$z_a = \frac{\sqrt{1 + Z}}{2}$$
$$d_3 = \frac{P}{Q \cdot w_{oo}^{P-Q}}$$

### Drain Feedback on Threshold

$$\text{lfg}_{term} = \gamma_{lf} - lfg_1 \cdot V_{GS}^{arg} + lfg_2 \cdot V_{GD}^{arg}$$

$$V_{GST} = V_{GS}^{arg} - V_{TO} - \text{lfg}_{term} \cdot V_{GD}^{arg}$$

### Subthreshold Conduction

When $V_{ST} = 0$ (no subthreshold model):

$$V_{GT} = \max(V_{GST},\; 0)$$

When $V_{ST} > 0$:

$$V_{ST}^{eff} = V_{ST} \cdot (1 + m_{vst} \cdot V_{DS}^{eff})$$

Softplus smooth transition (three regions via clamping):

$$\text{arg} = \frac{V_{GST}}{V_{ST}^{eff}}$$

$$\text{arg}_{cl} = \min(\text{arg},\; M_X)$$

$$V_{GT} = V_{ST}^{eff} \cdot \ln\!\left(1 + e^{\max(\text{arg}_{cl},\; F_X)}\right)$$

This implements the subthreshold-to-above-threshold transition:
- $V_{GST} \ll 0$: $V_{GT} \approx 0$ (cutoff)
- $V_{GST} \gg V_{ST}^{eff}$: $V_{GT} \approx V_{GST}$ (above threshold)

### Core Parker-Skellern Drain Current (psids_core)

**Dual power-law drain voltage:**
$$V_{DP} = V_{DS}^{eff} \cdot d_3 \cdot V_{GT}^{P-Q}$$

**Velocity saturation:**
$$V_{satFac} = \frac{V_{GT}}{m_{\xi} \cdot V_{GT} + \xi \cdot w_{oo}}$$

$$V_{sat} = \frac{V_{GT}}{1 + V_{satFac}}$$

**Smoothed drain saturation voltage:**
$$a_a = z_a \cdot V_{DP} + \frac{V_{sat}}{2}$$

$$a_{aa} = a_a - V_{sat}$$

$$\text{arg} = \frac{V_{sat}^2 \cdot Z}{4}$$

$$\text{rpt} = \sqrt{a_a^2 + \text{arg}}$$

$$a_{\text{rpt}} = \sqrt{a_{aa}^2 + \text{arg}}$$

$$V_{DT} = \text{rpt} - a_{\text{rpt}}$$

**Intrinsic Q-law FET current:**
$$I_{drain} = V_{DT} \cdot (V_{GT} - V_{DT})^{Q-1} + V_{GT} \cdot \left[V_{GT}^{Q-1} - (V_{GT} - V_{DT})^{Q-1}\right]$$

This is equivalent to $I_{drain} = V_{GT}^Q - (V_{GT} - V_{DT})^Q$ for integer $Q$.

### Channel-Length Modulation

$$I_D^{CLM} = I_{drain} \cdot \beta \cdot A_{eff} \cdot (1 + \lambda \cdot V_{DS}^{eff})$$

### Thermal Current Reduction (DC Mode)

$$P_{avg} = V_{DS}^{eff} \cdot I_D^{CLM}$$

$$P_{fac} = 1 + P_{avg} \cdot \frac{\delta}{A_{eff}}$$

$$I_D^{thermal} = \frac{I_D^{CLM}}{P_{fac}}$$

### Final Drain Current with Reversal

$$I_D = \begin{cases} -I_D^{thermal} & V_{DS} < 0 \\ +I_D^{thermal} & V_{DS} \ge 0 \end{cases}$$

### GMIN Convergence Aid

$$I_{gmin} = G_{min} \cdot V_{DS}$$

where $G_{min} = 10^{-12}$ S.

### KCL Node Currents

$$I_{drain} = I_{Rd}$$
$$I_{gate} = I_{GS} + I_{GD}$$
$$I_{source} = I_{Rs}$$
$$I_{D'} = -I_{Rd} + I_D - I_{GD} + I_{gmin}$$
$$I_{S'} = -I_{Rs} - I_D - I_{GS} - I_{gmin}$$

## Charge / Capacitance Model (Statz)

### Precomputed Capacitance Constants

$$w_{oo} = \phi_B - V_{TO}$$
$$\alpha = \frac{(\xi \cdot w_{oo})^2}{4(\xi + 1)^2}$$
$$V_{max} = FC \cdot \phi_B$$
$$C_{ZGS} = C_{gs0} \cdot A_{eff}, \quad C_{ZGD} = C_{gd0} \cdot A_{eff}$$

### Effective Gate Voltage

$$V_{ert} = \sqrt{V_{DS}^2 + \alpha}$$

$$V_{eff} = \frac{1}{2}(V_{GS} + V_{GD} + V_{ert}) + \gamma_{ac} \cdot V_{DS}$$

### Pinch-off Smoothing

$$V_{NR} = (1 - x_c)(V_{eff} - V_{TO})$$

$$V_{NRT} = \sqrt{V_{NR}^2 + 0.04}$$

$$V_{new} = V_{eff} + \frac{1}{2}(V_{NRT} - V_{NR})$$

### Gate Charge -- Two Regions

**Region 1** ($V_{new} < V_{max}$, depletion):

$$q_{rt,1} = \sqrt{1 - \frac{V_{new}}{\phi_B}}$$

$$Q_{GG,1} = C_{ZGS} \cdot 2\phi_B (1 - q_{rt,1}) + C_{ZGD} \cdot (V_{eff} - V_{ert})$$

**Region 2** ($V_{new} \ge V_{max}$, forward extension):

$$V_x = \frac{V_{new} - V_{max}}{2}$$

$$\text{par} = 1 + \frac{V_x}{\phi_B - V_{max}}$$

$$q_{rt,2} = \sqrt{1 - \frac{V_{max}}{\phi_B}}$$

$$\text{ext} = \frac{V_x \cdot (1 + \text{par})}{q_{rt,2}}$$

$$Q_{GG,2} = C_{ZGS} \cdot \left[2\phi_B(1 - q_{rt,2}) + \text{ext}\right] + C_{ZGD} \cdot (V_{eff} - V_{ert})$$

### Capacitance Factor

$$C_{fac} = \frac{1}{2}\left(1 + x_c + \frac{(1-x_c) \cdot V_{NR}}{V_{NRT}}\right)$$

**Region-dependent effective capacitance factor:**

$$C_{GSO}^{eff} = \begin{cases} C_{fac} / q_{rt,1} & V_{new} < V_{max} \\ C_{fac} \cdot \text{par} / q_{rt,2} & V_{new} \ge V_{max} \end{cases}$$

### Capacitance Partitioning

$$c_{pm} = \frac{V_{DS}}{V_{ert}}$$

$$c_{+} = \frac{1 + c_{pm}}{2}, \quad c_{-} = c_{+} - c_{pm} = \frac{1 - c_{pm}}{2}$$

$$C_{GS} = C_{GSO}^{eff} \cdot C_{ZGS} \cdot (c_{+} + \gamma_{ac}) + C_{ZGD} \cdot (c_{-} + \gamma_{ac})$$

$$C_{GD} = C_{GSO}^{eff} \cdot C_{ZGS} \cdot (c_{-} - \gamma_{ac}) + C_{ZGD} \cdot (c_{+} - \gamma_{ac})$$

### Charge Partitioning

$$C_{tot} = C_{GS} + C_{GD}$$

$$Q_{GS} = Q_{GG} \cdot \frac{C_{GS}}{C_{tot}}$$

$$Q_{GD} = Q_{GG} \cdot \frac{C_{GD}}{C_{tot}}$$

### Drain-Source Capacitance

$$Q_{DS} = C_{ds} \cdot A_{eff} \cdot V_{DS}$$

### KCL Charge Contributions

$$Q_{gate} = Q_{GS} + Q_{GD}$$
$$Q_{D'} = -Q_{GD} + Q_{DS}$$
$$Q_{S'} = -Q_{GS} - Q_{DS}$$
$$Q_{drain} = 0, \quad Q_{source} = 0$$

## Newton Limiting (Convergence Aids)

### Critical Voltage

$$V_{crit} = n \cdot V_T \cdot \ln\!\left(\frac{n \cdot V_T}{\sqrt{2} \cdot I_S}\right)$$

where $V_T = \frac{k}{q} \cdot T_{dev}$.

### PN Junction Limiting (pnjlim)

Applied to both $V_{GS}$ and $V_{GD}$.

When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 \cdot nV_T$:

**Case** $V_{old} > 0$:
$$\text{arg} = \frac{V_{new} - V_{old}}{nV_T}$$

$$V_{lim} = \begin{cases} V_{old} + nV_T \cdot (2 + \ln(\text{arg} - 2)) & \text{arg} > 2 \\ V_{old} + 2 \cdot nV_T & \text{arg} \le 2 \end{cases}$$

**Case** $V_{old} \le 0$:
$$V_{lim} = \begin{cases} nV_T \cdot \ln\!\left(\frac{V_{new}}{nV_T}\right) & V_{new} > 0 \\ V_{crit} & V_{new} \le 0 \end{cases}$$

Otherwise: $V_{lim} = V_{new}$ (no limiting).

### FET Voltage Limiting (fetlim)

Applied to both $V_{GS}$ and $V_{GD}$ after pnjlim.

$$V_{tsthi} = |2(V_{old} - V_{TO})| + 2$$
$$V_{tstlo} = \frac{V_{tsthi}}{2} + 2$$
$$V_{tox} = V_{TO} + 3.5$$
$$\Delta V = V_{new} - V_{old}$$

**When** $V_{old} \ge V_{TO}$:
- If $V_{old} \ge V_{tox}$:
  - Decreasing ($\Delta V \le 0$): $V_{lim} = V_{old} - V_{tsthi}$ if $V_{new} \ge V_{tox}$ and $-\Delta V > V_{tsthi}$; else $V_{lim} = \max(V_{new}, V_{TO}+2)$ if $V_{new} < V_{tox}$
  - Increasing ($\Delta V > 0$): $V_{lim} = V_{old} + V_{tsthi}$ if $\Delta V \ge V_{tsthi}$
- If $V_{TO} \le V_{old} < V_{tox}$:
  - Decreasing: $V_{lim} = V_{old} - V_{tsthi}$ if $-\Delta V > V_{tsthi}$
  - Increasing: $V_{lim} = V_{old} + V_{tstlo}$ if $\Delta V \ge V_{tstlo}$

**When** $V_{old} < V_{TO}$ (below threshold):
- Decreasing: $V_{lim} = V_{old} - V_{tsthi}$ if $-\Delta V > V_{tsthi}$
- Increasing: $V_{lim} = V_{old} + V_{tstlo}$ if $\Delta V \ge V_{tstlo}$

Otherwise: $V_{lim} = V_{new}$ (no limiting).

## Noise Model

| Generator | Nodes | Type | Spectral Density |
|-----------|-------|------|------------------|
| Drain resistance thermal | D -- D' | Thermal | $S_I = 4kT \cdot G_{Rd}$ |
| Source resistance thermal | S -- S' | Thermal | $S_I = 4kT \cdot G_{Rs}$ |
| Channel shot noise | D' -- S' | Shot | $S_I = 2q \cdot I_{DS}$ |
| Channel flicker noise | D' -- S' | Flicker | $S_I = KF \cdot I_{DS}^{AF} / f$ |
