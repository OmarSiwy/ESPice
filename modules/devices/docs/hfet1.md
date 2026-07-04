# HFET Level 1 -- Parameter & Equation Reference

> Heterostructure Field-Effect Transistor (HFET) Level 1 model -- three-terminal FET for GaAs/AlGaAs HEMTs and similar III-V heterostructure devices.

## Model Topology

The HFET1 is a three-terminal device with external ports: **drain**, **gate**, and **source**. No internal nodes are used. The equivalent circuit consists of a voltage-controlled channel current source between drain and source (with DIBL, subthreshold smoothing, velocity saturation, and knee shaping), gate leakage diodes from gate-to-source and gate-to-drain (dual-exponential plus GGR reverse leakage), nonlinear gate capacitances (Cgs, Cgd) partitioned via a Meyer-like scheme, a parasitic drain-source capacitance Cds, and GMIN conductances across all terminal pairs for numerical conditioning.

## Parameters

### DC / Channel Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vt0 | $V_{T0}$ | V | 0.15 | | Pinch-off (threshold) voltage |
| lambda | $\lambda$ | 1/V | 0.15 | | Output conductance parameter (CLM) |
| eta | $\eta$ | -- | 1.28 | | Subthreshold ideality factor |
| m | $M$ | -- | 3 | | Drain current knee shape parameter |
| mc | $M_C$ | -- | 3 | | Capacitance saturation knee shape parameter |
| gamma | $\gamma$ | -- | 3 | | Saturation limiting power-law exponent |
| sigma0 | $\sigma_0$ | -- | 0.057 | | DIBL threshold voltage coefficient |
| vsigmat | $V_{\sigma t}$ | V | 0.3 | | DIBL transition voltage |
| vsigma | $V_{\sigma}$ | V | 0.1 | | DIBL smoothing width |
| mu | $\mu$ | m^2/Vs | 0.4 | | Low-field mobility |
| di | $d_i$ | m | 4e-08 | | Gate-channel separation (depth of device) |
| delta | $\delta$ | V | 3 | | Subthreshold smoothing parameter |
| vs | $v_s$ | m/s | 150000 | | Carrier saturation velocity |
| nmax | $N_{max}$ | 1/m^2 | 2e+16 | | Maximum sheet carrier density |
| deltad | $\Delta d$ | m | 4.5e-09 | | Thickness correction to effective depth |
| epsi | $\epsilon_s$ | F/m | 1.08411e-10 | | Dielectric permittivity of barrier |
| p | $P_M$ | -- | 1 | | Capacitance partition parameter |

### Gate Leakage / Diode Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| js1d | $J_{s1d}$ | A/m^2 | 1 | | Gate-drain diode saturation current density 1 |
| js2d | $J_{s2d}$ | A/m^2 | 1.15e+06 | | Gate-drain diode saturation current density 2 |
| js1s | $J_{s1s}$ | A/m^2 | 1 | | Gate-source diode saturation current density 1 |
| js2s | $J_{s2s}$ | A/m^2 | 1.15e+06 | | Gate-source diode saturation current density 2 |
| m1d | $m_{1d}$ | -- | 1.32 | | Gate-drain diode ideality factor 1 |
| m2d | $m_{2d}$ | -- | 6.9 | | Gate-drain diode ideality factor 2 |
| m1s | $m_{1s}$ | -- | 1.32 | | Gate-source diode ideality factor 1 |
| m2s | $m_{2s}$ | -- | 6.9 | | Gate-source diode ideality factor 2 |
| ggr | $G_{GR}$ | S/m^2 | 40 | | Gate reverse leakage conductance density |
| del | $\delta_{GR}$ | 1/V | 0.04 | | Gate reverse leakage exponential coefficient |
| gatemod | -- | -- | 0 | {0} | Gate model selector (0 = dual-diode + GGR) |

### Resistance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rd | $R_d$ | Ohm | 0 | | Drain ohmic resistance |
| rs | $R_s$ | Ohm | 0 | | Source ohmic resistance |
| rg | $R_g$ | Ohm | 0 | | Gate ohmic resistance |
| rdi | $R_{di}$ | Ohm | 0 | | Internal drain ohmic resistance |
| rsi | $R_{si}$ | Ohm | 0 | | Internal source ohmic resistance |
| rgs | $R_{gs}$ | Ohm | 90 | | Gate-source ohmic resistance |
| rgd | $R_{gd}$ | Ohm | 90 | | Gate-drain ohmic resistance |
| ri | $R_i$ | Ohm | 0 | | Input resistance (ri) |
| rf | $R_f$ | Ohm | 0 | | Feedback resistance (rf) |

### Capacitance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cds | $C_{ds}$ | F | 0 | | Drain-source parasitic capacitance |
| eta1 | $\eta_1$ | -- | 2 | | Gate capacitance ideality factor 1 |
| d1 | $d_1$ | m | 3e-08 | | Gate capacitance depth parameter 1 |
| vt1 | $V_{T1}$ | V | 1.3323 | | Gate capacitance threshold voltage 1 |
| eta2 | $\eta_2$ | -- | 2 | | Gate capacitance ideality factor 2 |
| d2 | $d_2$ | m | 2e-07 | | Gate capacitance depth parameter 2 |
| vt2 | $V_{T2}$ | V | 0.15 | | Gate capacitance threshold voltage 2 |

### Temperature Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tf | $T_f$ | K | 300.15 | | Nominal (reference) temperature |
| klambda | $k_\lambda$ | 1/(V K) | 0 | | Temperature coefficient of lambda |
| kmu | $k_\mu$ | m^2/(Vs K) | 0 | | Temperature coefficient of mobility |
| kvto | $k_{V_{T0}}$ | V/K | 0 | | Temperature coefficient of threshold voltage |
| talpha | $T_\alpha$ | -- | 1200 | | Temperature alpha parameter |
| mt1 | $m_{T1}$ | -- | 3.5 | | Temperature exponent 1 |
| mt2 | $m_{T2}$ | -- | 9.9 | | Temperature exponent 2 |
| phib | $\phi_b$ | J | 8.01088e-20 | | Barrier height (energy) |
| astar | $A^*$ | A/(m^2 K^2) | 40000 | | Richardson constant |

### Miscellaneous Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cm3 | $C_{m3}$ | -- | 0.17 | | Capacitance model coefficient 3 |
| a1 | $a_1$ | -- | 0 | | Auxiliary parameter a1 |
| a2 | $a_2$ | -- | 0 | | Auxiliary parameter a2 |
| mv1 | $m_{v1}$ | -- | 3 | | Auxiliary exponent mv1 |
| kappa | $\kappa$ | -- | 0 | | Kappa parameter |
| delf | $\Delta f$ | -- | 0 | | Frequency shift parameter |
| fgds | $f_{gds}$ | -- | 0 | | Output conductance frequency factor |
| ck1 | $C_{k1}$ | -- | 1 | | Capacitance knee parameter 1 |
| ck2 | $C_{k2}$ | -- | 0 | | Capacitance knee parameter 2 |
| cm1 | $C_{m1}$ | -- | 3 | | Capacitance model coefficient 1 |
| cm2 | $C_{m2}$ | -- | 0 | | Capacitance model coefficient 2 |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| w | $W$ | m | 20e-6 | | Device width |
| l | $L$ | m | 1e-6 | | Device length (gate length) |
| temp | $T$ | K | 300.15 | | Device operating temperature |
| m_mult | $M$ | -- | 1.0 | | Parallel device multiplier |

## Equations

### Temperature Scaling

$$\Delta T = T - T_f$$

Temperature offset from nominal.

$$\mu_T = \mu + k_\mu \cdot \Delta T$$

Temperature-adjusted low-field mobility.

$$V_{T0,T} = V_{T0} + k_{V_{T0}} \cdot \Delta T$$

Temperature-adjusted threshold voltage.

$$\lambda_T = \lambda + k_\lambda \cdot \Delta T$$

Temperature-adjusted output conductance parameter.

### Derived Constants

$$d_{eff} = d_i + \Delta d$$

Effective gate-to-channel depth.

$$n_0 = \frac{\epsilon_s}{q \cdot d_{eff}}$$

Sheet charge coefficient (carrier density per volt of gate overdrive).

$$g_{\chi 0} = \frac{2 \, q \, W \, \mu_T}{L}$$

Intrinsic channel conductance prefactor.

$$I_{max} = q \cdot N_{max} \cdot v_s \cdot W$$

Maximum channel current (velocity-saturated limit).

$$v_L = \frac{v_s}{\mu_T} \cdot L$$

Characteristic velocity-saturation voltage.

$$C_f = \frac{1}{2} \, \epsilon_s \, W$$

Fringing capacitance.

### Gate Leakage Diode Scaling

$$I_{s1d} = \frac{J_{s1d} \cdot W \cdot L}{2}, \quad I_{s2d} = \frac{J_{s2d} \cdot W \cdot L}{2}$$

$$I_{s1s} = \frac{J_{s1s} \cdot W \cdot L}{2}, \quad I_{s2s} = \frac{J_{s2s} \cdot W \cdot L}{2}$$

Scaled diode saturation currents (gate-drain and gate-source).

$$G_{GR,WL} = G_{GR} \cdot \frac{L \cdot W}{2}$$

Scaled GGR reverse leakage conductance.

### Gate Leakage Current (gatemod = 0)

$$V_{t1,gs} = \frac{k_B T}{q} \cdot m_{1s}, \quad V_{t2,gs} = \frac{k_B T}{q} \cdot m_{2s}$$

Ideality-scaled thermal voltages for gate-source diodes.

$$I_{gs,leak} = I_{s1s} \left( e^{\min(V_{gs}/V_{t1,gs},\;80)} - 1 \right) + I_{s2s} \left( e^{\min(V_{gs}/V_{t2,gs},\;80)} - 1 \right) + G_{GR,WL} \cdot e^{\min(\delta_{GR} \cdot V_{gs},\;80)}$$

Gate-source leakage: dual-exponential diode plus GGR reverse leakage. The $\min(\cdot, 80)$ clamps the exponent argument to prevent overflow.

$$V_{t1,gd} = \frac{k_B T}{q} \cdot m_{1d}, \quad V_{t2,gd} = \frac{k_B T}{q} \cdot m_{2d}$$

$$I_{gd,leak} = I_{s1d} \left( e^{\min(V_{gd}/V_{t1,gd},\;80)} - 1 \right) + I_{s2d} \left( e^{\min(V_{gd}/V_{t2,gd},\;80)} - 1 \right) + G_{GR,WL} \cdot e^{\min(\delta_{GR} \cdot V_{gd},\;80)}$$

Gate-drain leakage: same dual-exponential diode plus GGR model.

### Channel Current -- Threshold and DIBL

$$V_{gt0} = V_{gs} - V_{T0,T}$$

Raw gate overdrive voltage.

$$\sigma = \frac{\sigma_0}{1 + e^{(V_{ds} - V_{\sigma t}) / V_{\sigma}}}$$

DIBL coefficient with smooth drain-voltage-dependent activation. The exponential argument is clamped to 80.

$$V_{gt} = V_{gt0} + \sigma \cdot V_{ds}$$

Effective gate overdrive including DIBL shift.

### Channel Current -- Subthreshold Smoothing

$$V_{gte} = \frac{1}{2} \left( V_{gt} + \sqrt{V_{gt}^2 + \delta^2} \right)$$

Smooth soft-turn-on function. Transitions from exponential subthreshold to linear above-threshold. For $V_{gt} \gg \delta$, $V_{gte} \approx V_{gt}$; for $V_{gt} \ll -\delta$, $V_{gte} \approx \delta^2 / (4|V_{gt}|) \to 0$.

### Channel Current -- Sheet Charge and Saturation Limiting

$$n_{sm} = n_0 \cdot V_{gte}$$

Linear (unsaturated) sheet carrier density. Floored to $10^{-38}$ for numerical safety.

$$c = \left( \frac{n_{sm}}{N_{max}} \right)^\gamma$$

$$n_s = \frac{n_{sm}}{\left(1 + c\right)^{1/\gamma}}$$

Sheet charge with power-law saturation clamp at $N_{max}$. As $n_{sm} \to N_{max}$, $n_s$ smoothly saturates.

### Channel Current -- Conductance and Velocity Saturation

$$g_\chi = g_{\chi 0} \cdot n_s$$

Intrinsic channel conductance.

$$R_T = R_{si} + R_{di}$$

$$g_{ch} = \frac{g_\chi}{1 + g_\chi \cdot R_T}$$

Effective channel conductance including source/drain series resistance.

$$g_{\chi m} = g_{\chi 0} \cdot n_{sm}$$

Unsaturated intrinsic conductance (uses $n_{sm}$ before $N_{max}$ clipping).

$$h = \sqrt{1 + 2 \, g_{\chi m} \, R_{si} + \frac{V_{gte}^2}{v_L^2}}$$

$$p_{val} = 1 + g_{\chi m} \cdot R_{si} + h$$

$$I_{sat,m} = \frac{g_{\chi m} \cdot V_{gte}}{p_{val}}$$

Saturation current before $N_{max}$ limiting. Accounts for source resistance and velocity saturation.

$$g_{sat} = \left( \frac{I_{sat,m}}{I_{max}} \right)^\gamma$$

$$I_{sat} = \frac{I_{sat,m}}{\left(1 + g_{sat}\right)^{1/\gamma}}$$

Final saturation current with $I_{max}$ power-law clamp.

$$V_{sat,e} = \frac{I_{sat}}{g_{ch}}$$

Effective saturation voltage (knee voltage).

### Channel Current -- Drain Current with Knee Shaping

$$\left|\frac{V_{ds}}{V_{sat,e}}\right|_{smooth} = \sqrt{\left(\frac{V_{ds}}{V_{sat,e}}\right)^2 + 10^{-30}}$$

Smooth absolute value of $V_{ds}/V_{sat,e}$ for safe exponentiation.

$$d = \left|\frac{V_{ds}}{V_{sat,e}}\right|_{smooth}^{M}$$

$$I_{drain} = \frac{g_{ch} \cdot V_{ds} \cdot (1 + \lambda_T \cdot V_{ds})}{(1 + d)^{1/M}}$$

Drain current with knee shaping via power-law saturation (exponent $M$) and channel-length modulation ($\lambda_T$).

### GMIN Conditioning

$$I_{gmin,ds} = G_{min} \cdot V_{ds}, \quad I_{gmin,gs} = G_{min} \cdot V_{gs}, \quad I_{gmin,gd} = G_{min} \cdot V_{gd}$$

where $G_{min} = 10^{-12}$ S. Added to all branches for numerical conditioning.

### KCL Assembly

$$I_{gate} = \left( I_{gs,leak} + I_{gd,leak} + I_{gmin,gs} + I_{gmin,gd} \right) \cdot M$$

$$I_{drain,total} = \left( I_{drain} - I_{gd,leak} + I_{gmin,ds} - I_{gmin,gd} \right) \cdot M$$

$$I_{source} = -\left( I_{gate} + I_{drain,total} \right)$$

Terminal currents with parallel multiplier $M$. Source current enforces KCL ($\sum I = 0$).

### Charge Model -- Channel Capacitance Derivatives

$$\frac{\partial n_s}{\partial n_{sm}} = \frac{n_s}{n_{sm}} \cdot \left(1 - \frac{c}{1 + c}\right)$$

Derivative of saturated sheet charge w.r.t. unsaturated sheet charge.

$$\frac{\partial V_{gte}}{\partial V_{gt}} = \frac{1}{2}\left(1 + \frac{V_{gt}}{\sqrt{V_{gt}^2 + \delta^2}}\right)$$

Derivative of smoothed overdrive w.r.t. raw overdrive.

$$\frac{\partial n_{sm}}{\partial V_{gt}} = n_0 \cdot \frac{\partial V_{gte}}{\partial V_{gt}}$$

$$\frac{\partial V_{gt}}{\partial V_{gs}} = 1$$

Since $\sigma$ depends on $V_{ds}$ (not $V_{gs}$), the gate-voltage derivative is unity.

### Charge Model -- Gate Capacitance (cg1)

$$C_{g1} = \frac{1}{\dfrac{d_1}{\epsilon_s} + \eta_1 \cdot V_t \cdot e^{\min\left(-\frac{V_{gs} - V_{T1}}{\eta_1 V_t},\;80\right)}}$$

Quantum-well gate capacitance contribution. Activates as $V_{gs}$ exceeds $V_{T1}$.

### Charge Model -- Total Gate Channel Capacitance

$$C_{gc} = W \cdot L \cdot \left( q \cdot \frac{\partial n_s}{\partial n_{sm}} \cdot \frac{\partial n_{sm}}{\partial V_{gt}} \cdot \frac{\partial V_{gt}}{\partial V_{gs}} + C_{g1} \right)$$

Total intrinsic gate-channel capacitance per unit area, scaled by device geometry.

### Charge Model -- Saturation Voltage for Capacitance

$$\left|\frac{V_{ds}}{V_{sat,e}}\right|_{smooth} = \sqrt{\left(\frac{V_{ds}}{V_{sat,e}}\right)^2 + 10^{-30}}$$

$$V_{ds,e} = \frac{V_{ds}}{\left(1 + \left|\frac{V_{ds}}{V_{sat,e}}\right|_{smooth}^{M_C}\right)^{1/M_C}}$$

Effective drain-source voltage for capacitance partitioning, smoothly limited at $V_{sat,e}$ with knee exponent $M_C$.

### Charge Model -- Meyer-like Capacitance Partition

$$\alpha_{gs} = \left( \frac{V_{sat,e} - V_{ds,e}}{2 \, V_{sat,e} - V_{ds,e}} \right)^2$$

$$\alpha_{gd} = \left( \frac{V_{sat,e}}{2 \, V_{sat,e} - V_{ds,e}} \right)^2$$

Ward-Munro / Meyer-like partition factors. In the denominator, $10^{-30}$ is added for safety.

$$P_{part} = P_M + (1 - P_M) \cdot e^{\min(-V_{ds}/V_{sat,e},\;80)}$$

Partition weighting factor. At $V_{ds} = 0$, $P_{part} = 1$ (symmetric); at large $V_{ds}$, $P_{part} \to P_M$.

### Charge Model -- Terminal Capacitances

$$C_{gs} = C_f + \frac{4}{3} \cdot C_{gc} \cdot \frac{1 - \alpha_{gs}}{1 + P_{part}}$$

$$C_{gd} = C_f + \frac{4}{3} \cdot P_{part} \cdot C_{gc} \cdot \frac{1 - \alpha_{gd}}{1 + P_{part}}$$

Gate-source and gate-drain capacitances with fringing capacitance $C_f$ and asymmetric partition.

### Charge Model -- Terminal Charges

$$Q_{gs} = C_{gs} \cdot V_{gs}$$

$$Q_{gd} = C_{gd} \cdot V_{gd}$$

$$Q_{ds} = C_{ds} \cdot V_{ds}$$

Linearized charge-voltage relation at each branch.

$$Q_{gate} = (Q_{gs} + Q_{gd}) \cdot M$$

$$Q_{drain} = (-Q_{gd} + Q_{ds}) \cdot M$$

$$Q_{source} = (-Q_{gs} - Q_{ds}) \cdot M$$

Terminal charge contributions satisfying charge conservation, scaled by multiplier $M$.

### Newton Limiting -- FET Voltage Limiter (fetlim)

Applied to $V_{gs}$ each Newton iteration:

$$V_{thr} = V_{T0} + V_t, \quad V_t = 0.026 \text{ V}, \quad V_{tstep} = 2 V_t$$

- If $V_{gs}^{new} > V_{gs}^{old}$ and $V_{gs}^{old} \ge V_{thr}$: clamp step to $V_{tstep}$, i.e. $V_{gs}^{lim} = \min(V_{gs}^{new},\; V_{gs}^{old} + V_{tstep})$
- If $V_{gs}^{new} > V_{gs}^{old}$ and $V_{gs}^{old} < V_{thr}$: clamp to threshold, i.e. $V_{gs}^{lim} = \min(V_{gs}^{new},\; V_{thr})$
- If $V_{gs}^{new} < V_{gs}^{old}$ and $V_{gs}^{old} \ge V_{thr}$: clamp step to $V_{tstep}$, i.e. $V_{gs}^{lim} = \max(V_{gs}^{new},\; V_{gs}^{old} - V_{tstep})$
- Otherwise: $V_{gs}^{lim} = V_{gs}^{new}$ (no limiting)

### Newton Limiting -- Drain-Source Voltage Limiter (limvds)

Applied to $V_{ds}$ each Newton iteration:

- If $V_{ds}^{old} \ge 3.5$:
  - Upward step clamped: if $V_{ds}^{new} - V_{ds}^{old} > 2(V_{ds}^{old} + 1)$, then $V_{ds}^{lim} = 3 V_{ds}^{old} + 2$
  - Downward clamped to floor: if $V_{ds}^{new} < 3.5$, then $V_{ds}^{lim} = 3.5$
- If $V_{ds}^{old} < 3.5$:
  - Upward clamped to ceiling: if $V_{ds}^{new} > 4.0$, then $V_{ds}^{lim} = 4.0$
- Otherwise: $V_{ds}^{lim} = V_{ds}^{new}$ (no limiting)
