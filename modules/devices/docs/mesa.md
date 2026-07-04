# MESA GaAs MESFET -- Parameter & Equation Reference

> Three-terminal GaAs MESFET (Metal-Semiconductor Field-Effect Transistor) with Schottky gate, supporting three model levels (2, 3, 4) for single-layer, delta-doped, and carrier-concentration-based formulations.

## Model Topology

The MESA device has three external terminals: **drain**, **gate**, **source** (`num_ports = 3`). Internally, three additional nodes are created: **drain_prime**, **gate_prime**, **source_prime**, separated from external terminals by series ohmic resistances `rd`, `rg`, `rs`. The intrinsic device between the primed nodes contains: two Schottky gate diodes (gate_prime-to-source_prime and gate_prime-to-drain_prime), a voltage-controlled channel current source (drain_prime to source_prime), and nonlinear gate-channel capacitances with Ward-Dutton charge partitioning.

## Parameters

### DC Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `vto` | $V_{to}$ | V | -1.26 | | Pinch-off (threshold) voltage |
| `lambda` | $\lambda$ | 1/V | 0.045 | | Output conductance parameter |
| `lambdahf` | $\lambda_{hf}$ | 1/V | 0.045 | | Output conductance parameter at high frequencies |
| `beta` | $\beta$ | A/V^2 | 0.0085 | | Transconductance parameter (model card) |
| `vs` | $v_s$ | m/s | 1.5e5 | | Saturation velocity |
| `n` | $n$ | -- | 1 | | Diode emission coefficient |
| `eta` | $\eta$ | -- | 1.73 | | Subthreshold ideality factor |
| `m` | $M$ | -- | 2.5 | | Knee shape parameter |
| `mc` | $M_c$ | -- | 3 | | Knee shape parameter for $V_{dse}$ |
| `alpha` | $\alpha$ | -- | 0 | | Ionization coefficient (adds to $M$) |
| `sigma0` | $\sigma_0$ | -- | 0.081 | | DIBL / threshold voltage coefficient |
| `vsigmat` | $V_{\sigma t}$ | V | 1.01 | | Sigma transition voltage |
| `vsigma` | $V_\sigma$ | V | 0.1 | | Sigma smoothing parameter |
| `mu` | $\mu$ | m^2/Vs | 0.23 | | Low-field mobility |
| `theta` | $\theta$ | m^2/V^2s | 0 | | Mobility modulation parameter (Level 2 only) |
| `mu1` | $\mu_1$ | | 0 | | Second mobility parameter |
| `mu2` | $\mu_2$ | | 0 | | Third mobility parameter |
| `delta` | $\delta$ | -- | 5 | | Smoothing parameter for subthreshold transition |
| `tc` | $t_c$ | 1/V | 0 | | Transconductance compression factor |
| `zeta` | $\zeta$ | -- | 1 | | Velocity saturation parameter |
| `level` | -- | -- | 2 | {2,3,4} | Model level selector |
| `nmax` | $N_{max}$ | 1/m^2 | 2e16 | | Maximum carrier sheet concentration (Level 4) |
| `gamma` | $\gamma$ | -- | 3 | | Carrier concentration limiting exponent (Level 4) |

### Schottky Gate Diode Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `phib` | $\phi_b$ | eV | 0.5 | | Effective Schottky barrier height |
| `phib1` | $\phi_{b1}$ | eV/K | 0 | | Temperature coefficient of $\phi_b$ |
| `astar` | $A^*$ | A/m^2/K^2 | 4.0e4 | | Effective Richardson constant |
| `ggr` | $g_{gr}$ | S/m^2 | 40 | | Reverse gate diode conductance |
| `del` | $\delta_{gd}$ | 1/V | 0.04 | | Reverse diode exponential parameter |
| `xchi` | $\chi$ | | 0.033 | | Temperature coefficient of $g_{gr}$ |

### Resistance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `rd` | $R_d$ | Ohm | 0 | | Drain ohmic resistance |
| `rs` | $R_s$ | Ohm | 0 | | Source ohmic resistance |
| `rg` | $R_g$ | Ohm | 0 | | Gate ohmic resistance |
| `ri` | $R_i$ | Ohm | 0 | | Gate-source ohmic resistance |
| `rf` | $R_f$ | Ohm | 0 | | Gate-drain ohmic resistance |
| `rdi` | $R_{di}$ | Ohm | 0 | | Intrinsic drain resistance |
| `rsi` | $R_{si}$ | Ohm | 0 | | Intrinsic source resistance |

### Device Geometry Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `d` | $d$ | m | 1.2e-7 | | Channel depth |
| `nd` | $N_d$ | 1/m^3 | 2e23 | | Channel doping density |
| `du` | $d_u$ | m | 3.5e-8 | | Upper layer depth (Level 3) |
| `ndu` | $N_{du}$ | 1/m^3 | 1e22 | | Upper layer doping density (Level 3) |
| `th` | $t_h$ | m | 1e-8 | | Delta-doped layer thickness (Level 3) |
| `ndelta` | $N_\delta$ | 1/m^3 | 6e24 | | Delta-doped layer doping density (Level 3) |
| `epsi` | $\varepsilon$ | F/m | 1.08411e-10 | | Permittivity (default = $\varepsilon_{GaAs}$) |

### Capacitance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `cas` | $C_{as}$ | -- | 1 | | Gate-source capacitance scaling (Level 4) |
| `cbs` | $C_{bs}$ | -- | 1 | | Gate-drain capacitance scaling (Level 4) |

### Temperature Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `tvto` | $t_{V_{to}}$ | V/K | 0 | | Temperature coefficient for $V_{to}$ |
| `tlambda` | $t_\lambda$ | K | $+\infty$ | | Temperature coefficient for $\lambda$ |
| `teta0` | $t_{\eta 0}$ | K | $+\infty$ | | Temperature coefficient for $\eta$ (divisor) |
| `teta1` | $t_{\eta 1}$ | -- | 0 | | Second temperature coefficient for $\eta$ |
| `tmu` | $T_\mu$ | K | 300.15 | | Reference temperature for mobility |
| `xtm0` | $x_{tm0}$ | -- | 0 | | Exponent for temperature dependence of mobility |
| `xtm1` | $x_{tm1}$ | -- | 0 | | Second exponent for mobility temperature |
| `xtm2` | $x_{tm2}$ | -- | 0 | | Third exponent for mobility temperature |
| `rtc1` | $r_{tc1}$ | 1/K | 0 | | Resistance temperature coefficient 1 |
| `rtc2` | $r_{tc2}$ | 1/K^2 | 0 | | Resistance temperature coefficient 2 |
| `tf` | $T_f$ | K | 300.15 | | Characteristic temperature (traps) |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `flo` | $f_{lo}$ | Hz | 0 | | Low frequency noise corner frequency |
| `delfo` | $\Delta f_o$ | -- | 0 | | Low frequency noise parameter |
| `ag` | $A_g$ | -- | 0 | | Gate noise coefficient |

### Sidegating Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `ks` | $k_s$ | -- | 0 | | Sidegating coefficient |
| `vsg` | $V_{sg}$ | V | 0 | | Sidegating voltage |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| `w` | $W$ | m | 20e-6 | | Gate width |
| `l` | $L$ | m | 1e-6 | | Gate length |
| `m` | $m$ | -- | 1.0 | | Parallel device multiplier |
| `temp` | $T$ | K | 300.15 | | Device temperature |
| `dtemp` | $\Delta T$ | K | 0 | | Temperature offset from nominal |

## Equations

### Physical Constants

$$k/q = 8.617333 \times 10^{-5} \;\text{V/K}$$

$$q = 1.602176634 \times 10^{-19} \;\text{C}$$

$$k_B = 1.380649 \times 10^{-23} \;\text{J/K}$$

$$\varepsilon_{GaAs} = 12.244 \times 8.85418 \times 10^{-12} \;\text{F/m}$$

$$G_{min} = 10^{-12} \;\text{S}$$

### Thermal Voltages

$$V_{ts} = \frac{k}{q} \cdot T_s$$

$$V_{td} = \frac{k}{q} \cdot T_d$$

$$V_{tes} = n \cdot V_{ts}$$

$$V_{ted} = n \cdot V_{td}$$

### Temperature-Adjusted Parameters

**Mobility:**

$$\mu_T = \mu \cdot \left(\frac{T_s}{T_\mu}\right)^{x_{tm0}}$$

When $x_{tm0} = 0$, $\mu_T = \mu$.

**Threshold voltage:**

$$V_{to,T} = V_{to} - t_{V_{to}} \cdot (T_s - 300.15)$$

**Output conductance:**

$$\lambda_T = \lambda \cdot \left(1 - \frac{T_s}{t_\lambda}\right)$$

When $t_\lambda = +\infty$, $\lambda_T = \lambda$.

**Subthreshold ideality factor:**

$$\eta_T = \eta \cdot \left(1 + \frac{T_s}{t_{\eta 0}}\right) + \frac{t_{\eta 1}}{T_s}$$

When $t_{\eta 0} = +\infty$, $\eta_T = \eta$.

### Derived Intermediate Parameters

**Pre-computed beta (all levels):**

$$\beta_{pre} = \frac{2 \varepsilon_{GaAs} \cdot v_s \cdot \zeta \cdot W}{d}$$

**Subthreshold carrier concentration scale ($n_0$):**

Level 2, 3:

$$n_0 = \frac{\varepsilon_{GaAs} \cdot \eta_T \cdot V_{ts}}{q \cdot d'}$$

where $d' = d$ for Level 2, $d' = d_u$ for Level 3.

Level 4:

$$n_0 = \frac{\varepsilon \cdot \eta_T \cdot V_{ts}}{2 q \cdot d}$$

**Subthreshold carrier concentration for two-layer ($n_{sb0}$, Level 3):**

$$n_{sb0} = \frac{\varepsilon_{GaAs} \cdot \eta_T \cdot V_{ts}}{q \cdot (d_u + t_h)}$$

**Saturation current scale ($I_{satb0}$):**

$$I_{satb0} = \frac{q \cdot n_0 \cdot V_{ts} \cdot W}{L}$$

**Channel conductance prefactor ($g_{\chi 0}$):**

Level 2:

$$g_{\chi 0} = \frac{q \cdot W}{L}$$

Level 3, 4:

$$g_{\chi 0} = \frac{q \cdot W}{L} \cdot \mu_T$$

**Maximum current:**

$$I_{max} = q \cdot N_{max} \cdot v_s \cdot W$$

### Pinch-off Voltages

**Level 2 (single layer):**

$$V_{po} = \frac{q \cdot N_d \cdot d^2}{2 \varepsilon_{GaAs}}$$

**Level 3 (delta-doped, two-layer):**

$$V_{po,u} = \frac{q \cdot N_{du} \cdot d_u^2}{2 \varepsilon_{GaAs}}$$

$$V_{po,d} = \frac{q \cdot N_\delta \cdot t_h \cdot (2 d_u + t_h)}{2 \varepsilon_{GaAs}}$$

$$V_{po} = V_{po,u} + V_{po,d}$$

### Gate Schottky Diode Currents

**Saturation currents:**

$$I_{sat,fs} = \frac{1}{2} A^* T_s^2 \exp\!\left(\frac{-\phi_b \cdot q}{k_B T_s}\right) \cdot W \cdot L$$

$$I_{sat,fd} = \frac{1}{2} A^* T_d^2 \exp\!\left(\frac{-\phi_b \cdot q}{k_B T_d}\right) \cdot W \cdot L$$

$$g_{gr,WL} = g_{gr} \cdot W \cdot L$$

**Source-side gate diode current:**

$$I_{gs} = m \cdot \left[ I_{sat,fs}\!\left(e^{\min(V_{gs}/V_{tes},\,80)} - 1\right) + g_{gr,WL} \cdot V_{gs} \cdot e^{\min(-V_{gs} \delta_{gd}/V_{ts},\,80)} + G_{min} \cdot V_{gs} \right]$$

**Drain-side gate diode current:**

$$I_{gd} = m \cdot \left[ I_{sat,fd}\!\left(e^{\min(V_{gd}/V_{ted},\,80)} - 1\right) + g_{gr,WL} \cdot V_{gd} \cdot e^{\min(-V_{gd} \delta_{gd}/V_{td},\,80)} + G_{min} \cdot V_{gd} \right]$$

### Inverse Mode Handling (Smooth Blending)

$$|V_{ds}| = \sqrt{V_{ds}^2 + \epsilon_{smooth}}, \quad \epsilon_{smooth} = 10^{-6}$$

$$\text{blend} = \frac{1}{2}\left(1 + \frac{V_{ds}}{|V_{ds}|}\right)$$

$$V_{gs,eff} = \text{blend} \cdot V_{gs} + (1 - \text{blend}) \cdot V_{gd}$$

When $V_{ds} > 0$ (normal mode), blend $\approx 1$ and $V_{gs,eff} = V_{gs}$. When $V_{ds} < 0$ (inverse mode), blend $\approx 0$ and $V_{gs,eff} = V_{gd}$.

### DIBL / Sigma Correction

$$V_{gt0} = V_{gs,eff} - V_{on}, \quad V_{on} = V_{to,T}$$

$$\sigma = \frac{\sigma_0}{1 + e^{\min((V_{gt0} - V_{\sigma t})/V_\sigma,\,80)}}$$

$$V_{gt} = V_{gt0} + \sigma \cdot |V_{ds}|$$

### Smoothed Subthreshold Transition

Used in all levels to compute the effective gate overdrive $V_{gte}$.

**Level 2:**

$$u = \frac{V_{gt}}{V_{ts}} - 1, \quad t = \sqrt{\delta^2 + u^2}$$

$$V_{gte} = \frac{V_{ts}}{2}(2 + u + t)$$

**Level 3:**

$$t = \frac{V_{gt}}{V_{ts}} - 1, \quad q = \sqrt{\delta^2 + t^2}$$

$$V_{gte} = \frac{V_{ts}}{2}(2 + t + q)$$

**Level 4:**

$$u = \frac{V_{gt}}{2 V_{ts}} - 1, \quad t = \sqrt{\delta^2 + u^2}$$

$$V_{gte} = V_{ts}(2 + u + t)$$

### Channel Current -- Level 2 (mesa1)

**Mobility with modulation:**

$$\mu_{eff} = \mu_T + \theta \cdot V_{gt}$$

**Saturation voltage parameter:**

$$V_l = \frac{v_s}{\mu_{eff}} \cdot L$$

**Beta:**

$$\beta_2 = \frac{\beta_{pre}}{V_{po} + 3 V_l}$$

**Acceleration parameter:**

$$a = 2 \beta_2 \cdot V_{gte}$$

**Subthreshold factor:**

$$b = e^{\min(-V_{gt}/(\eta_T V_{ts}),\,80)}$$

**Sheet carrier density:**

$$\sqrt{1} = \sqrt{\max\!\left(0,\; 1 - \frac{V_{gte}}{V_{po}}\right)}$$

$$n_s = \frac{1}{\frac{1}{N_d \cdot d \cdot (1 - \sqrt{1})} + \frac{b}{n_0}}$$

Smooth clamping: when $V_{gte} > V_{po}$, $\sqrt{1} \to 0$ and $n_s \to N_d \cdot d$.

**Channel conductance:**

$$g_{\chi i} = g_{\chi 0} \cdot \mu_{eff} \cdot n_s$$

$$g_{ch} = \frac{g_{\chi i}}{1 + g_{\chi i} \cdot (R_{si} + R_{di})}$$

**Saturation current (velocity-limited):**

$$f = \sqrt{1 + 2 a R_{si}}$$

$$D = 1 + a R_{si} + f$$

$$e = 1 + t_c \cdot V_{gte}$$

$$I_{sat,a} = \frac{a \cdot V_{gte}}{D \cdot e}$$

**Saturation current (diffusion-limited):**

$$I_{sat,b} = I_{satb0} \cdot \mu_{eff} \cdot e^{\min(V_{gt}/(\eta_T V_{ts}),\,80)}$$

**Combined saturation current (harmonic mean):**

$$I_{sat} = \frac{I_{sat,a} \cdot I_{sat,b}}{I_{sat,a} + I_{sat,b}}$$

**Saturation voltage:**

$$V_{sat,e} = \frac{I_{sat}}{g_{ch}}$$

**Effective knee shape:**

$$M_{eff} = M + \alpha \cdot V_{gte}$$

**Drain current:**

$$h = \left(1 + \left(\frac{|V_{ds}|}{V_{sat,e}}\right)^{M_{eff}}\right)^{1/M_{eff}}$$

$$I_d = g_{ch} \cdot \frac{|V_{ds}|}{h} \cdot (1 + \lambda_T \cdot |V_{ds}|)$$

### Channel Current -- Level 3 (mesa2)

Uses the same $V_{gte}$ smoothing, but with a two-layer carrier density model.

**Acceleration parameter:**

$$a = 2 \beta_{pre} \cdot V_{gte}$$

**Subthreshold factor:**

$$b = e^{\min(V_{gt}/(\eta_T V_{ts}),\,80)}$$

**Sheet carrier density (two-layer):**

$$n_{sa,max} = N_\delta \cdot t_h + N_{du} \cdot d_u$$

$$r = \sqrt{\frac{\max(0,\; 1 - V_{gte}/V_{po})}{V_{po,u}/V_{po}}}$$

$$n_{sa} = n_{sa,max} - N_{du} \cdot d_u \cdot r$$

$$n_{sb} = n_{sb0} \cdot b$$

$$n_s = \frac{n_{sa} \cdot n_{sb}}{n_{sa} + n_{sb}}$$

**Channel conductance:**

$$g_{\chi i} = g_{\chi 0} \cdot n_s$$

$$g_{ch} = \frac{g_{\chi i}}{1 + g_{\chi i} \cdot (R_{si} + R_{di})}$$

**Saturation currents:**

$$f = \sqrt{1 + 2 a R_{si}}, \quad D = 1 + a R_{si} + f, \quad e = 1 + t_c \cdot V_{gte}$$

$$I_{sat,a} = \frac{a \cdot V_{gte}}{D \cdot e}$$

$$I_{sat,b} = I_{satb0} \cdot b$$

$$I_{sat} = \frac{I_{sat,a} \cdot I_{sat,b}}{I_{sat,a} + I_{sat,b}}$$

**Drain current (same functional form as Level 2 but with $M_{eff} = M$, no $\alpha$ correction):**

$$V_{sat,e} = \frac{I_{sat}}{g_{ch}}, \quad h = \left(1 + \left(\frac{|V_{ds}|}{V_{sat,e}}\right)^M\right)^{1/M}$$

$$I_d = g_{ch} \cdot \frac{|V_{ds}|}{h} \cdot (1 + \lambda_T \cdot |V_{ds}|)$$

### Channel Current -- Level 4 (mesa3)

**Velocity parameter:**

$$V_l = \frac{v_s}{\mu_T} \cdot L$$

**Carrier concentration (Fermi-Dirac-like):**

$$n_{sm} = 2 n_0 \cdot \ln\!\left(1 + \frac{b}{2}\right)$$

where $b = e^{\min(V_{gt}/(\eta_T V_{ts}),\,80)}$.

**NMAX limiting:**

$$c = \left(\frac{n_{sm}}{N_{max}}\right)^\gamma$$

$$n_s = \frac{n_{sm}}{(1 + c)^{1/\gamma}}$$

**Channel conductance:**

$$g_{\chi i} = g_{\chi 0} \cdot n_s, \quad g_{ch} = \frac{g_{\chi i}}{1 + g_{\chi i} \cdot (R_{si} + R_{di})}$$

$$g_{\chi i,m} = g_{\chi 0} \cdot n_{sm}$$

**Saturation current (two-term denominator):**

$$h_{sat} = \sqrt{1 + 2 g_{\chi i,m} R_{si} + \frac{V_{gte}^2}{V_l^2}}$$

$$p = 1 + g_{\chi i,m} R_{si} + h_{sat}$$

$$I_{sat,m} = \frac{g_{\chi i,m} \cdot V_{gte}}{p}$$

**NMAX limiting on saturation current:**

$$I_{sat} = \frac{I_{sat,m}}{\left(1 + \left(\frac{I_{sat,m}}{I_{max}}\right)^\gamma\right)^{1/\gamma}}$$

**Drain current:**

$$V_{sat,e} = \frac{I_{sat}}{g_{ch}}$$

$$e = \left(1 + \left(\frac{|V_{ds}|}{V_{sat,e}}\right)^M\right)^{1/M}$$

$$I_d = g_{ch} \cdot \frac{|V_{ds}|}{e} \cdot (1 + \lambda_T \cdot |V_{ds}|)$$

### Sign Convention and Multiplier

$$I_{d,signed} = I_d \cdot (2 \cdot \text{blend} - 1) \cdot m$$

The factor $(2 \cdot \text{blend} - 1)$ maps $[0,1] \to [-1,+1]$, flipping drain current sign in inverse mode.

### Parasitic Resistance Currents

When $R \neq 0$: $g = 1/R$. When $R = 0$: $g = G_{short} = 10^{12}$ (shorts internal to external node).

$$I_{Rd} = (V_d - V_{d'}) \cdot g_d$$

$$I_{Rs} = (V_s - V_{s'}) \cdot g_s$$

$$I_{Rg} = (V_g - V_{g'}) \cdot g_g$$

### KCL Node Stamping

$$I_{drain} = -I_{Rd}$$

$$I_{gate} = -I_{Rg}$$

$$I_{source} = -I_{Rs}$$

$$I_{gate'} = I_{Rg} - I_{gs} - I_{gd}$$

$$I_{drain'} = I_{Rd} + I_{d,signed} + I_{gd}$$

$$I_{source'} = I_{Rs} - I_{d,signed} + I_{gs}$$

### Charge / Capacitance Model

#### Fringing Capacitance

Level 2, 3:

$$C_f = \frac{\varepsilon_{GaAs} \cdot W}{2}$$

Level 4:

$$C_f = \frac{\varepsilon \cdot W}{2}$$

#### Gate-Channel Capacitance -- Level 2

$$C_{gc} = \frac{W \cdot L \cdot \varepsilon_{GaAs}}{d \cdot \left(\sqrt{\max(0,\; 1 - V_{gt}/V_{po})} + b\right)}$$

where $b = e^{\min(-V_{gt}/(\eta_T V_{ts}),\,80)}$.

#### Gate-Channel Capacitance -- Level 3

$$C_a = \frac{\varepsilon_{GaAs}}{d_u \cdot r}, \quad C_b = \frac{\varepsilon_{GaAs}}{d_u + t_h} \cdot b$$

$$C_{gc} = \frac{W \cdot L \cdot C_a \cdot C_b}{C_a + C_b}$$

where $r$ is the depletion ratio from the carrier density calculation and $b = e^{\min(V_{gt}/(\eta_T V_{ts}),\,80)}$.

#### Gate-Channel Capacitance -- Level 4

$$C_a^{-1} = \frac{d}{C_{as} \cdot \varepsilon}$$

$$C_b^{-1} = \frac{\eta_T V_{ts}}{C_{bs} \cdot q \cdot n_0} \cdot e^{\min(-V_{gt}/(\eta_T V_{ts}),\,80)}$$

$$C_{gc,m} = \frac{1}{C_a^{-1} + C_b^{-1}}$$

$$C_{gc} = \frac{W \cdot L \cdot C_{gc,m}}{(1 + c)^{1 + 1/\gamma}}$$

where $c = (n_{sm}/N_{max})^\gamma$.

#### Effective Drain-Source Voltage for Capacitance (All Levels)

$$V_{dse} = |V_{ds}| \cdot \left(1 + \left(\frac{|V_{ds}|}{V_{sat,e}}\right)^{M_c}\right)^{-1/M_c}$$

#### Ward-Dutton Charge Partitioning (All Levels)

$$f_{gs} = \frac{V_{sat,e} - V_{dse}}{2 V_{sat,e} - V_{dse}}$$

$$f_{gd} = \frac{V_{sat,e}}{2 V_{sat,e} - V_{dse}}$$

$$C_{gs} = C_f + \frac{2}{3} C_{gc} (1 - f_{gs}^2)$$

$$C_{gd} = C_f + \frac{2}{3} C_{gc} (1 - f_{gd}^2)$$

#### Inverse-Mode Capacitance Swapping

$$C_{gs,eff} = \text{blend} \cdot C_{gs} + (1 - \text{blend}) \cdot C_{gd}$$

$$C_{gd,eff} = \text{blend} \cdot C_{gd} + (1 - \text{blend}) \cdot C_{gs}$$

#### Charge Contributions

$$Q_{gs} = C_{gs,eff} \cdot V_{gs}$$

$$Q_{gd} = C_{gd,eff} \cdot V_{gd}$$

#### Charge KCL Stamping

$$Q_{gate'} = Q_{gs} + Q_{gd}$$

$$Q_{source'} = -Q_{gs}$$

$$Q_{drain'} = -Q_{gd}$$

$$Q_{drain} = Q_{gate} = Q_{source} = 0$$

### Noise Sources

Four noise generators are declared between internal nodes (drain_prime=3, source_prime=5):

| Generator | Nodes | Type | Description |
|-----------|-------|------|-------------|
| 1 | (drain', source') | Thermal | Drain resistance thermal noise |
| 2 | (source', drain') | Thermal | Source resistance thermal noise |
| 3 | (drain', source') | Shot | Drain current shot noise |
| 4 | (drain', source') | Flicker | $1/f$ noise (controlled by `flo`, `delfo`, `ag`) |

### Exponential Clamping

All exponential evaluations are clamped to prevent overflow:

$$e^x \to e^{\min(x, 80)}$$

This applies uniformly to diode exponentials, subthreshold factors, and capacitance terms.
