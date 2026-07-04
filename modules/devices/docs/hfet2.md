# HFET Level 2 -- Parameter & Equation Reference

> Heterostructure Field-Effect Transistor, enhanced model with two-layer charge model, DIBL, and velocity saturation (Berkeley SPICE3f5 / ngspice `hfeta2`)

## Model Topology

Three external terminals: **Drain (D)**, **Gate (G)**, **Source (S)**. Two internal nodes: **Drain' (D')** and **Source' (S')** separated from the external drain and source by parasitic resistances $R_D$ and $R_S$. The intrinsic device between D' and S' consists of a velocity-saturated channel current source $I_{ds}$, Schottky gate junction diodes (gate-source, gate-drain), and gate-channel capacitances $C_{gs}$, $C_{gd}$ partitioned from the total gate capacitance.

## Parameters

### Model Parameters (DC)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `vt0` | $V_{T0}$ | V | 0.15 | | Pinch-off (threshold) voltage |
| `lambda` | $\lambda$ | 1/V | 0.15 | | Output conductance (CLM) parameter |
| `mu` | $\mu$ | m$^2$/(V$\cdot$s) | 0.4 | | Low-field mobility |
| `nmax` | $N_{max}$ | cm$^{-2}$ | 2e16 | | Maximum sheet charge density |
| `eta` | $\eta$ | -- | 1.28 | | Subthreshold ideality factor |
| `vs` | $v_s$ | m/s | 1.5e5 | | Saturation velocity |
| `sigma0` | $\sigma_0$ | -- | 0.057 | | DIBL coefficient |
| `vsigma` | $V_\sigma$ | V | 0.1 | | DIBL transition width |
| `vsigmat` | $V_{\sigma t}$ | V | 0.3 | | DIBL transition center voltage |
| `gamma` | $\gamma$ | -- | 3 | | Knee shape / charge saturation exponent |
| `m` | $m$ | -- | 3 | | Drain saturation knee shape parameter |
| `mc` | $m_c$ | -- | 3 | | Capacitance saturation knee shape parameter |
| `delta` | $\delta$ | -- | 3 | | Subthreshold transition smoothing width |
| `n` | $n$ | -- | 5 | | Gate diode ideality (subthreshold swing) |
| `p` | $p$ | -- | 1 | | Capacitance partition power-law exponent |
| `del` | $\Delta$ | -- | 0.04 | | Gate reverse-bias conductance decay parameter |

### Model Parameters (Parasitics & Junction)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `rd` | $R_D$ | $\Omega$ | 0 | | Drain ohmic resistance (0 $\to$ short) |
| `rs` | $R_S$ | $\Omega$ | 0 | | Source ohmic resistance (0 $\to$ short) |
| `rdi` | $R_{Di}$ | $\Omega$ | 0 | | Internal drain resistance (for $g_{ch}$ feedback) |
| `rsi` | $R_{Si}$ | $\Omega$ | 0 | | Internal source resistance (for $g_{ch}$ feedback) |
| `js` | $J_S$ | A/m$^2$ | 0 | | Gate junction saturation current density |
| `ggr` | $G_{GR}$ | S/m$^2$ | 0 | | Gate-drain reverse-bias leakage conductance density |

### Model Parameters (Capacitance)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cf` | $C_f$ | F | 0 | | Fringing capacitance (per side) |
| `d1` | $d_1$ | m | 3e-8 | | First capacitance layer thickness |
| `d2` | $d_2$ | m | 2e-7 | | Second capacitance layer thickness |
| `di` | $d_i$ | m | 4e-8 | | Intrinsic channel depth |
| `deltad` | $\Delta d$ | m | 4.5e-9 | | Thickness correction to $d_i$ |
| `epsi` | $\varepsilon_i$ | F/m | 1.084e-10 | | Dielectric constant of insulator |
| `eta1` | $\eta_1$ | -- | 2 | | First-layer capacitance ideality |
| `eta2` | $\eta_2$ | -- | 2 | | Second-layer capacitance / charge ideality |
| `vt1` | $V_{T1}$ | V | 1.3323 | | Capacitance transition voltage ($C_{g1}$) |
| `vt2` | $V_{T2}$ | V | 0.15 | | Second-layer charge threshold voltage |

### Model Parameters (Temperature Coefficients)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `kvto` | $K_{VT0}$ | V/K | 0 | | Threshold voltage temperature coefficient |
| `klambda` | $K_\lambda$ | 1/(V$\cdot$K) | 0 | | $\lambda$ temperature coefficient |
| `kmu` | $K_\mu$ | m$^2$/(V$\cdot$s$\cdot$K) | 0 | | Mobility temperature coefficient |
| `knmax` | $K_{Nmax}$ | cm$^{-2}$/K | 0 | | $N_{max}$ temperature coefficient |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `w` | $W$ | m | 20e-6 | | Gate width |
| `l` | $L$ | m | 1e-6 | | Gate length |
| `temp` | $T$ | K | 300.15 | | Device temperature |
| `dtemp` | $\Delta T$ | K | 0 | | Temperature offset from nominal |
| `m` | $M$ | -- | 1 | | Parallel device multiplier |
| `type_nfet` | $s$ | -- | +1 | $\{-1, +1\}$ | Device polarity (+1 NFET, -1 PFET) |

## Equations

### Physical Constants

$$q = 1.60217663 \times 10^{-19} \;\text{C}$$
$$k/q = 8.617333262145 \times 10^{-5} \;\text{V/K}$$

### Temperature-Adjusted Parameters

$$T_{dev} = T + \Delta T$$
$$\Delta T_{nom} = T_{dev} - T_{nom}, \quad T_{nom} = 300.15\;\text{K}$$
$$V_{T0,eff} = s \cdot V_{T0} - K_{VT0} \cdot \Delta T_{nom}$$
$$\lambda_{eff} = \lambda + K_\lambda \cdot \Delta T_{nom}$$
$$\mu_{eff} = \mu - K_\mu \cdot \Delta T_{nom}$$
$$N_{max,eff} = N_{max} - K_{Nmax} \cdot \Delta T_{nom}$$
$$V_t = (k/q) \cdot T_{dev}$$

### Derived Quantities

$$G_{Dpar} = \begin{cases} 1/R_D & R_D \neq 0 \\ 10^{12} & R_D = 0 \end{cases}$$

$$G_{Spar} = \begin{cases} 1/R_S & R_S \neq 0 \\ 10^{12} & R_S = 0 \end{cases}$$

$$N_0 = \frac{\varepsilon_i \cdot \eta \cdot V_t}{2q(d_i + \Delta d)}$$

$$N_{02} = \begin{cases} \dfrac{\varepsilon_i \cdot \eta_2 \cdot V_t}{2q \cdot d_2} & d_2 \neq 0 \\ 0 & d_2 = 0 \end{cases}$$

$$g_{\chi 0} = \frac{q \cdot W \cdot \mu_{eff}}{L}$$

$$I_{max} = q \cdot W \cdot v_s \cdot N_{max,eff}$$

$$J_{S,LW} = J_S \cdot \frac{W \cdot L}{2}$$

$$G_{GR,LW} = G_{GR} \cdot \frac{W \cdot L}{2}$$

$$V_L = \frac{v_s}{\mu_{eff}} \cdot L$$

### Terminal Voltages and Source/Drain Reversal

$$V_{GS,raw} = s \cdot (V_G - V_{S'})$$
$$V_{GD,raw} = s \cdot (V_G - V_{D'})$$
$$V_{DS,raw} = V_{GS,raw} - V_{GD,raw}$$
$$V_{DS} = \max(|V_{DS,raw}|,\; 10^{-30})$$

Source/drain reversal: when $V_{DS,raw} < 0$, the effective gate-source voltage is swapped:
$$V_{GS} = \begin{cases} V_{GD,raw} & V_{DS,raw} < 0 \\ V_{GS,raw} & V_{DS,raw} \geq 0 \end{cases}$$

### Parasitic Resistance Currents

$$I_{RD} = (V_D - V_{D'}) \cdot G_{Dpar}$$
$$I_{RS} = (V_S - V_{S'}) \cdot G_{Spar}$$

### Gate Junction Currents (Schottky Diode)

Computed with **pre-swap** (raw) voltages.

$$V_{tn} = n \cdot V_t$$

**Gate-source diode:**
$$I_{GS} = J_{S,LW}\left[\exp\!\left(\min\!\left(\frac{V_{GS,raw}}{V_{tn}},\;80\right)\right) - 1\right] + G_{GR,LW} \cdot V_{GS,raw} \cdot \exp\!\left(\min\!\left(\frac{-V_{GS,raw} \cdot \Delta}{V_t},\;80\right)\right)$$

**Gate-drain diode:**
$$I_{GD} = J_{S,LW}\left[\exp\!\left(\min\!\left(\frac{V_{GD,raw}}{V_{tn}},\;80\right)\right) - 1\right] + G_{GR,LW} \cdot V_{GD,raw} \cdot \exp\!\left(\min\!\left(\frac{-V_{GD,raw} \cdot \Delta}{V_t},\;80\right)\right)$$

**Total gate current:**
$$I_G = I_{GS} + I_{GD}$$

### Channel Current -- Core HFET2 Equations

**DIBL-adjusted threshold:**
$$\sigma = \frac{\sigma_0}{1 + \exp\!\left(\min\!\left(\dfrac{V_{GS} - V_{T0,eff} - V_{\sigma t}}{V_\sigma},\;80\right)\right)}$$

**Effective gate overdrive with DIBL:**
$$V_{GT0} = V_{GS} - V_{T0,eff}$$
$$V_{GT} = V_{GT0} + \sigma \cdot V_{DS}$$

**Subthreshold smoothing (soft turn-on):**
$$u = \frac{V_{GT}}{2V_t} - 1$$
$$t = \sqrt{\delta^2 + u^2}$$
$$V_{GTE} = V_t(2 + u + t)$$

**Charge density $b$-factor:**
$$b = \exp\!\left(\min\!\left(\frac{V_{GT}}{\eta \cdot V_t},\;80\right)\right)$$

**Sheet charge density $n_{sm}$:**

Single-layer model ($\eta_2 = 0$ or $d_2 = 0$):
$$n_{sm} = 2N_0 \ln\!\left(1 + \tfrac{1}{2}b\right)$$

Two-layer model ($\eta_2 \neq 0$ and $d_2 \neq 0$):
$$n_{sc} = N_{02} \cdot \exp\!\left(\min\!\left(\frac{V_{GT} + V_{T0,eff} - V_{T2}}{\eta_2 \cdot V_t},\;80\right)\right)$$
$$n_{sn} = 2N_0 \ln\!\left(1 + \tfrac{1}{2}b\right)$$
$$n_{sm} = \frac{n_{sn} \cdot n_{sc}}{n_{sn} + n_{sc}}$$

**Safe floor on $n_{sm}$:**
$$n_{sm,safe} = \sqrt{n_{sm}^2 + 10^{-76}}$$

**Charge saturation (hard clamp at $N_{max}$):**
$$c = \left(\frac{n_{sm,safe}}{N_{max,eff}}\right)^\gamma$$
$$Q_{sat} = (1 + c)^{1/\gamma}$$
$$n_s = \frac{n_{sm,safe}}{Q_{sat}}$$

**Channel conductance:**
$$g_{\chi i} = g_{\chi 0} \cdot n_s$$
$$g_{ch} = \frac{g_{\chi i}}{1 + g_{\chi i}(R_{Si} + R_{Di})}$$

**Saturation current (velocity saturation limited):**
$$g_{\chi im} = g_{\chi 0} \cdot n_{sm,safe}$$
$$h = \sqrt{1 + 2\,g_{\chi im}\,R_{Si} + \frac{V_{GTE}^2}{V_L^2}}$$
$$P = 1 + g_{\chi im}\,R_{Si} + h$$
$$I_{sat,m} = \frac{g_{\chi im} \cdot V_{GTE}}{P}$$

**Imax clamp:**
$$g_{clamp} = \left(\frac{I_{sat,m}}{I_{max}}\right)^\gamma$$
$$I_{sat} = \frac{I_{sat,m}}{(1 + g_{clamp})^{1/\gamma}}$$

**Effective saturation voltage:**
$$V_{sat,e} = \frac{I_{sat}}{g_{ch}}$$

**Drain current with knee smoothing and CLM:**
$$D = \left(\frac{V_{DS}}{V_{sat,e}}\right)^m$$
$$E = (1 + D)^{1/m}$$
$$I_{drain} = \frac{g_{ch} \cdot V_{DS} \cdot (1 + \lambda_{eff} \cdot V_{DS})}{E}$$

**Source/drain reversal sign:**
$$I_{drain,signed} = \begin{cases} -I_{drain} & V_{DS,raw} < 0 \\ +I_{drain} & V_{DS,raw} \geq 0 \end{cases}$$

**Type and multiplier:**
$$I_{drain,final} = s \cdot M \cdot I_{drain,signed}$$

### GMIN Convergence Aid

$$I_{GMIN} = 10^{-12} \cdot (V_{D'} - V_{S'})$$

### KCL Node Stamps

$$I_{Drain} = -I_{RD}$$
$$I_{Gate} = s \cdot M \cdot I_G$$
$$I_{Source} = -I_{RS}$$
$$I_{D'} = I_{RD} + I_{drain,final} - s \cdot M \cdot I_{GD} + I_{GMIN}$$
$$I_{S'} = I_{RS} - I_{drain,final} - s \cdot M \cdot (I_G - I_{GD}) - I_{GMIN}$$

### Capacitance Model

All channel quantities ($V_{GT}$, $n_{sm}$, $g_{ch}$, $V_{sat,e}$, etc.) are recomputed identically to the DC section using post-swap voltages.

**Derivative of saturated charge w.r.t. unsaturated charge:**
$$\frac{\partial n_s}{\partial n_{sm}} = \frac{n_s}{n_{sm}} \left(1 - \frac{c}{1+c}\right)$$

**Derivative of sheet charge w.r.t. gate overdrive (single layer):**
$$\frac{\partial n_{sm}}{\partial V_{GT}}\bigg|_{base} = \frac{N_0}{\eta V_t} \cdot \frac{1}{1/b + 0.5}$$

**Derivative of sheet charge w.r.t. gate overdrive (two-layer):**
$$\frac{\partial n_{sm}}{\partial V_{GT}} = \frac{n_{sc}\left(n_{sc}\dfrac{\partial n_{sm}}{\partial V_{GT}}\bigg|_{base} + \dfrac{n_{sn}^2}{\eta_2 V_t}\right)}{(n_{sc} + n_{sn})^2}$$

**Derivative of $V_{GT}$ w.r.t. $V_{GS}$ (DIBL effect):**
$$\frac{\partial V_{GT}}{\partial V_{GS}} = 1 - V_{DS}\,\frac{\sigma_0}{V_\sigma}\,\frac{s_{exp}}{(1+s_{exp})^2}$$
where $s_{exp} = \exp\!\left(\min\!\left(\dfrac{V_{GT0} - V_{\sigma t}}{V_\sigma},\;80\right)\right)$.

**First-layer parasitic capacitance:**
$$C_{g1} = \frac{1}{\dfrac{d_1}{\varepsilon_i} + \eta_1 V_t \exp\!\left(\min\!\left(\dfrac{-(V_{GS} - V_{T1})}{\eta_1 V_t},\;80\right)\right)}$$

**Total intrinsic gate capacitance per unit area:**
$$C_{gc} = W \cdot L \left(q\,\frac{\partial n_s}{\partial n_{sm}}\,\frac{\partial n_{sm}}{\partial V_{GT}}\,\frac{\partial V_{GT}}{\partial V_{GS}} + C_{g1}\right)$$

**Effective drain-source voltage for capacitance partition:**
$$V_{DSE} = V_{DS}\left(1 + \left(\frac{V_{DS}}{V_{sat,e}}\right)^{m_c}\right)^{-1/m_c}$$

**Ward-Dutton capacitance partition:**
$$\alpha_{GS} = \left(\frac{V_{sat,e} - V_{DSE}}{2V_{sat,e} - V_{DSE}}\right)^2$$
$$\alpha_{GD} = \left(\frac{V_{sat,e}}{2V_{sat,e} - V_{DSE}}\right)^2$$

**Partition blending factor:**
$$p_{cap} = p + (1-p)\exp\!\left(\frac{-V_{DS}}{V_{sat,e}}\right)$$

**Terminal capacitances:**
$$C_{GS} = C_f + \frac{4}{3}\,C_{gc}\,(1 - \alpha_{GS})\,\frac{1}{1 + p_{cap}}$$
$$C_{GD} = C_f + \frac{4}{3}\,p_{cap}\,C_{gc}\,(1 - \alpha_{GD})\,\frac{1}{1 + p_{cap}}$$

**Source/drain reversal for capacitances:**
$$C_{GS,eff} = \begin{cases} C_{GD} & V_{DS,raw} < 0 \\ C_{GS} & V_{DS,raw} \geq 0 \end{cases}, \quad C_{GD,eff} = \begin{cases} C_{GS} & V_{DS,raw} < 0 \\ C_{GD} & V_{DS,raw} \geq 0 \end{cases}$$

### Charge Stamps

Charges use **unsigned** terminal voltages:
$$Q_{GS} = M \cdot C_{GS,eff} \cdot (V_G - V_{S'})$$
$$Q_{GD} = M \cdot C_{GD,eff} \cdot (V_G - V_{D'})$$

**Node charge contributions (KCL for displacement current $dQ/dt$):**
$$Q_{Gate} = Q_{GS} + Q_{GD}$$
$$Q_{D'} = -Q_{GD}$$
$$Q_{S'} = -Q_{GS}$$
$$Q_{Drain} = 0, \quad Q_{Source} = 0$$

### Newton Limiting -- fetlim (Gate Voltages)

Applied to $V_{GS}$ and $V_{GD}$ (gate vs. internal source/drain nodes) with threshold $V_{T0}$:

$$V_{tox} = V_{T0} + 3.5$$
$$V_{tst,hi} = |2(V_{old} - V_{T0})| + 2$$
$$V_{tst,lo} = \tfrac{1}{2}V_{tst,hi} + 2$$

**If $V_{old} \geq V_{T0}$:**

- If $V_{old} \geq V_{tox}$:
  - $\Delta V \leq 0$: $V_{new} \gets \max(V_{new},\; V_{old} - V_{tst,lo})$
  - $\Delta V > 0$: $V_{new} \gets \min(V_{new},\; V_{old} + V_{tst,hi})$
- If $V_{old} < V_{tox}$:
  - $\Delta V \leq 0$: $V_{new} \gets \max(V_{new},\; V_{T0} - 0.5)$
  - $\Delta V > 0$: $V_{new} \gets \min(V_{new},\; V_{old} + V_{tst,hi})$

**If $V_{old} < V_{T0}$:**
- $\Delta V \leq 0$: $V_{new} \gets \max(V_{new},\; V_{old} - V_{tst,lo})$
- $\Delta V > 0$: $V_{new} \gets \min(V_{new},\; V_{T0} + 0.5)$

### Newton Limiting -- limvds (Drain-Source Voltage)

Applied to $V_{DS} = V_{D'} - V_{S'}$:

**If $V_{old} \geq 3.5$:**
- $\Delta V \leq 0$: $V_{new} \gets \max(V_{new},\; -0.5\,V_{old})$
- $\Delta V > 0$: $V_{new} \gets \min(V_{new},\; 2\,V_{old})$

**If $V_{old} < 3.5$:**
- $V_{new} > 4$: $V_{new} \gets 4$
