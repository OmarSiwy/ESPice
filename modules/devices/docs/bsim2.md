# BSIM2 (Berkeley Short-Channel IGFET Model 2) -- Parameter & Equation Reference

> MOSFET model for short-channel devices (NMOS/PMOS), with W/L-dependent parameter decomposition, subthreshold smoothing, hot-electron effects, and junction diode currents.

## Model Topology

The BSIM2 is a 4-terminal MOSFET (Drain, Gate, Source, Bulk) with two internal nodes (Drain' and Source') separated from the external terminals by parasitic sheet resistances. The intrinsic transistor is connected between Drain', Gate, Source', and Bulk. Junction diodes exist between Bulk-Source' and Bulk-Drain'. Gate overlap capacitances couple Gate to Source', Drain', and Bulk.

**Unknowns (U):**
| Index | Node | Description |
|-------|------|-------------|
| 0 | drain | External drain terminal |
| 1 | gate | External gate terminal |
| 2 | source | External source terminal |
| 3 | bulk | External bulk (substrate) terminal |
| 4 | drain_prime | Internal drain node |
| 5 | source_prime | Internal source node |

External ports: 4 (drain, gate, source, bulk)

## Parameters

### Instance Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| w | $W$ | m | 5e-6 | Channel width |
| l | $L$ | m | 5e-6 | Channel length |
| temp | $T_{dev}$ | K | 300.15 | Device temperature |
| m | $M$ | -- | 1.0 | Parallel multiplier |

### Threshold Voltage Parameters

All model parameters use W/L decomposition: $P_{eff} = P_0 + P_L \cdot \frac{10^{-6}}{L_{eff}} + P_W \cdot \frac{10^{-6}}{W_{eff}}$

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| vfb | $V_{fb,0}$ | V | -1.0 | Flat band voltage |
| lvfb | $V_{fb,L}$ | V*um | 0.0 | Length dependence of vfb |
| wvfb | $V_{fb,W}$ | V*um | 0.0 | Width dependence of vfb |
| phi | $\phi_{s,0}$ | V | 0.75 | Strong inversion surface potential |
| lphi | $\phi_{s,L}$ | V*um | 0.0 | Length dependence of phi |
| wphi | $\phi_{s,W}$ | V*um | 0.0 | Width dependence of phi |
| k1 | $K_{1,0}$ | V^{1/2} | 0.8 | Bulk effect coefficient 1 |
| lk1 | $K_{1,L}$ | V^{1/2}*um | 0.0 | Length dependence of k1 |
| wk1 | $K_{1,W}$ | V^{1/2}*um | 0.0 | Width dependence of k1 |
| k2 | $K_{2,0}$ | -- | 0.0 | Bulk effect coefficient 2 |
| lk2 | $K_{2,L}$ | um | 0.0 | Length dependence of k2 |
| wk2 | $K_{2,W}$ | um | 0.0 | Width dependence of k2 |
| eta0 | $\eta_{0,0}$ | -- | 0.0 | VDS dependence of threshold voltage at VDD=0 |
| leta0 | $\eta_{0,L}$ | um | 0.0 | Length dependence of eta0 |
| weta0 | $\eta_{0,W}$ | um | 0.0 | Width dependence of eta0 |
| etab | $\eta_{b,0}$ | V^{-1} | 0.0 | VBS dependence of eta |
| letab | $\eta_{b,L}$ | V^{-1}*um | 0.0 | Length dependence of etab |
| wetab | $\eta_{b,W}$ | V^{-1}*um | 0.0 | Width dependence of etab |

### Geometry Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| dl | $\Delta L$ | um | 0.0 | Channel length reduction |
| dw | $\Delta W$ | um | 0.0 | Channel width reduction |
| ld | $L_D$ | m | 0.0 | Lateral diffusion length |
| tox | $t_{ox}$ | um | 0.03 | Gate oxide thickness |

### Mobility Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| mu0 | $\mu_0$ | cm^2/V/s | 400.0 | Low-field mobility at VDS=0, VGS=VTH |
| mu0b | $\mu_{0b,0}$ | cm^2/V^2/s | 0.0 | VBS dependence of low-field mobility |
| lmu0b | $\mu_{0b,L}$ | cm^2/V^2/s*um | 0.0 | Length dependence of mu0b |
| wmu0b | $\mu_{0b,W}$ | cm^2/V^2/s*um | 0.0 | Width dependence of mu0b |
| mus0 | $\mu_{s,0}$ | cm^2/V/s | 500.0 | Mobility at VDS=VDD, VGS=VTH |
| lmus0 | $\mu_{s,L}$ | cm^2/V/s*um | 0.0 | Length dependence of mus0 |
| wmus0 | $\mu_{s,W}$ | cm^2/V/s*um | 0.0 | Width dependence of mus0 |
| musb | $\mu_{sb,0}$ | -- | 0.0 | VBS dependence of mus |
| lmusb | $\mu_{sb,L}$ | um | 0.0 | Length dependence of musb |
| wmusb | $\mu_{sb,W}$ | um | 0.0 | Width dependence of musb |
| mu20 | $\mu_{2,0}$ | -- | 1.5 | VDS dependence of mu in tanh term |
| lmu20 | $\mu_{2,L}$ | um | 0.0 | Length dependence of mu20 |
| wmu20 | $\mu_{2,W}$ | um | 0.0 | Width dependence of mu20 |
| mu2b | $\mu_{2b,0}$ | V^{-1} | 0.0 | VBS dependence of mu2 |
| lmu2b | $\mu_{2b,L}$ | V^{-1}*um | 0.0 | Length dependence of mu2b |
| wmu2b | $\mu_{2b,W}$ | V^{-1}*um | 0.0 | Width dependence of mu2b |
| mu2g | $\mu_{2g,0}$ | V^{-1} | 0.0 | VGS dependence of mu2 |
| lmu2g | $\mu_{2g,L}$ | V^{-1}*um | 0.0 | Length dependence of mu2g |
| wmu2g | $\mu_{2g,W}$ | V^{-1}*um | 0.0 | Width dependence of mu2g |
| mu30 | $\mu_{3,0}$ | -- | 10.0 | VDS dependence of mu in linear term |
| lmu30 | $\mu_{3,L}$ | um | 0.0 | Length dependence of mu30 |
| wmu30 | $\mu_{3,W}$ | um | 0.0 | Width dependence of mu30 |
| mu3b | $\mu_{3b,0}$ | V^{-1} | 0.0 | VBS dependence of mu3 |
| lmu3b | $\mu_{3b,L}$ | V^{-1}*um | 0.0 | Length dependence of mu3b |
| wmu3b | $\mu_{3b,W}$ | V^{-1}*um | 0.0 | Width dependence of mu3b |
| mu3g | $\mu_{3g,0}$ | V^{-1} | 0.0 | VGS dependence of mu3 |
| lmu3g | $\mu_{3g,L}$ | V^{-1}*um | 0.0 | Length dependence of mu3g |
| wmu3g | $\mu_{3g,W}$ | V^{-1}*um | 0.0 | Width dependence of mu3g |
| mu40 | $\mu_{4,0}$ | V^{-1} | 0.0 | VDS dependence of mu in linear term |
| lmu40 | $\mu_{4,L}$ | V^{-1}*um | 0.0 | Length dependence of mu40 |
| wmu40 | $\mu_{4,W}$ | V^{-1}*um | 0.0 | Width dependence of mu40 |
| mu4b | $\mu_{4b,0}$ | V^{-2} | 0.0 | VBS dependence of mu4 |
| lmu4b | $\mu_{4b,L}$ | V^{-2}*um | 0.0 | Length dependence of mu4b |
| wmu4b | $\mu_{4b,W}$ | V^{-2}*um | 0.0 | Width dependence of mu4b |
| mu4g | $\mu_{4g,0}$ | V^{-2} | 0.0 | VGS dependence of mu4 |
| lmu4g | $\mu_{4g,L}$ | V^{-2}*um | 0.0 | Length dependence of mu4g |
| wmu4g | $\mu_{4g,W}$ | V^{-2}*um | 0.0 | Width dependence of mu4g |

### Gate-Field Mobility Degradation Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| ua0 | $U_{a,0}$ | V^{-1} | 0.2 | Linear VGS dependence of mobility |
| lua0 | $U_{a,L}$ | V^{-1}*um | 0.0 | Length dependence of ua0 |
| wua0 | $U_{a,W}$ | V^{-1}*um | 0.0 | Width dependence of ua0 |
| uab | $U_{ab,0}$ | V^{-2} | 0.0 | VBS dependence of ua |
| luab | $U_{ab,L}$ | V^{-2}*um | 0.0 | Length dependence of uab |
| wuab | $U_{ab,W}$ | V^{-2}*um | 0.0 | Width dependence of uab |
| ub0 | $U_{b,0}$ | V^{-2} | 0.0 | Quadratic VGS dependence of mobility |
| lub0 | $U_{b,L}$ | V^{-2}*um | 0.0 | Length dependence of ub0 |
| wub0 | $U_{b,W}$ | V^{-2}*um | 0.0 | Width dependence of ub0 |
| ubb | $U_{bb,0}$ | V^{-3} | 0.0 | VBS dependence of ub |
| lubb | $U_{bb,L}$ | V^{-3}*um | 0.0 | Length dependence of ubb |
| wubb | $U_{bb,W}$ | V^{-3}*um | 0.0 | Width dependence of ubb |

### Lateral-Field Mobility Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| u10 | $U_{1,0}$ | -- | 0.1 | VDS dependence of mobility |
| lu10 | $U_{1,L}$ | um | 0.0 | Length dependence of u10 |
| wu10 | $U_{1,W}$ | um | 0.0 | Width dependence of u10 |
| u1b | $U_{1b,0}$ | V^{-1} | 0.0 | VBS dependence of u1 |
| lu1b | $U_{1b,L}$ | V^{-1}*um | 0.0 | Length dependence of u1b |
| wu1b | $U_{1b,W}$ | V^{-1}*um | 0.0 | Width dependence of u1b |
| u1d | $U_{1d,0}$ | V^{-1} | 0.0 | VDS dependence of u1 |
| lu1d | $U_{1d,L}$ | V^{-1}*um | 0.0 | Length dependence of u1d |
| wu1d | $U_{1d,W}$ | V^{-1}*um | 0.0 | Width dependence of u1d |

### Subthreshold Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| n0 | $n_0$ | -- | 1.4 | Subthreshold slope at VDS=0, VBS=0 |
| ln0 | $n_L$ | um | 0.0 | Length dependence of n0 |
| wn0 | $n_W$ | um | 0.0 | Width dependence of n0 |
| nb | $n_b$ | V^{-1} | 0.5 | VBS dependence of n |
| lnb | $n_{b,L}$ | V^{-1}*um | 0.0 | Length dependence of nb |
| wnb | $n_{b,W}$ | V^{-1}*um | 0.0 | Width dependence of nb |
| nd | $n_d$ | V^{-1} | 0.0 | VDS dependence of n |
| lnd | $n_{d,L}$ | V^{-1}*um | 0.0 | Length dependence of nd |
| wnd | $n_{d,W}$ | V^{-1}*um | 0.0 | Width dependence of nd |
| vof0 | $V_{of,0}$ | V | 1.8 | Threshold voltage offset at VDS=0, VBS=0 |
| lvof0 | $V_{of,L}$ | V*um | 0.0 | Length dependence of vof0 |
| wvof0 | $V_{of,W}$ | V*um | 0.0 | Width dependence of vof0 |
| vofb | $V_{of,b}$ | -- | 0.0 | VBS dependence of vof |
| lvofb | $V_{of,bL}$ | um | 0.0 | Length dependence of vofb |
| wvofb | $V_{of,bW}$ | um | 0.0 | Width dependence of vofb |
| vofd | $V_{of,d}$ | -- | 0.0 | VDS dependence of vof |
| lvofd | $V_{of,dL}$ | um | 0.0 | Length dependence of vofd |
| wvofd | $V_{of,dW}$ | um | 0.0 | Width dependence of vofd |

### Hot-Electron Effect Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| ai0 | $A_{i,0}$ | -- | 0.0 | Pre-factor of hot-electron effect |
| lai0 | $A_{i,L}$ | um | 0.0 | Length dependence of ai0 |
| wai0 | $A_{i,W}$ | um | 0.0 | Width dependence of ai0 |
| aib | $A_{ib,0}$ | V^{-1} | 0.0 | VBS dependence of ai |
| laib | $A_{ib,L}$ | V^{-1}*um | 0.0 | Length dependence of aib |
| waib | $A_{ib,W}$ | V^{-1}*um | 0.0 | Width dependence of aib |
| bi0 | $B_{i,0}$ | V | 0.0 | Exponential factor of hot-electron effect |
| lbi0 | $B_{i,L}$ | V*um | 0.0 | Length dependence of bi0 |
| wbi0 | $B_{i,W}$ | V*um | 0.0 | Width dependence of bi0 |
| bib | $B_{ib,0}$ | -- | 0.0 | VBS dependence of bi |
| lbib | $B_{ib,L}$ | um | 0.0 | Length dependence of bib |
| wbib | $B_{ib,W}$ | um | 0.0 | Width dependence of bib |

### Cubic Spline Bounds

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| vghigh | $V_{g,high}$ | V | 0.2 | Upper bound of cubic spline function |
| lvghigh | $V_{g,highL}$ | V*um | 0.0 | Length dependence of vghigh |
| wvghigh | $V_{g,highW}$ | V*um | 0.0 | Width dependence of vghigh |
| vglow | $V_{g,low}$ | V | -0.15 | Lower bound of cubic spline function |
| lvglow | $V_{g,lowL}$ | V*um | 0.0 | Length dependence of vglow |
| wvglow | $V_{g,lowW}$ | V*um | 0.0 | Width dependence of vglow |

### Voltage Clamp / Operating Point Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| vdd | $V_{DD}$ | V | 5.0 | Maximum VDS |
| vgg | $V_{GG}$ | V | 5.0 | Maximum VGS |
| vbb | $V_{BB}$ | V | 5.0 | Maximum VBS |
| temp | $T_{nom}$ | degC | 27.0 | Nominal temperature |
| type_ | -- | -- | 1 | Device type: 1=NMOS, -1=PMOS |

### Capacitance Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| cgso | $C_{GSO}$ | F/m | 0.0 | Gate-source overlap capacitance per unit channel width |
| cgdo | $C_{GDO}$ | F/m | 0.0 | Gate-drain overlap capacitance per unit channel width |
| cgbo | $C_{GBO}$ | F/m | 0.0 | Gate-bulk overlap capacitance per unit channel length |
| xpart | -- | -- | 0.0 | Flag for channel charge partitioning |

### Junction Diode Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| js | $J_S$ | A/m^2 | 0.0 | Source/drain junction saturation current per unit area |
| pb | $\phi_B$ | V | 0.8 | Source/drain junction built-in potential |
| mj | $M_J$ | -- | 0.0 | Bottom junction capacitance grading coefficient |
| pbsw | $\phi_{BSW}$ | V | 0.8 | Side junction capacitance built-in potential |
| mjsw | $M_{JSW}$ | -- | 0.0 | Side junction capacitance grading coefficient |
| cj | $C_J$ | F/m^2 | 0.0 | Bottom junction capacitance per unit area |
| cjsw | $C_{JSW}$ | F/m | 0.0 | Side junction capacitance per unit area |

### Parasitic Resistance Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| rsh | $R_{SH}$ | Ohm/sq | 0.0 | Source/drain diffusion sheet resistance |
| wdf | $W_{DF}$ | um | 10.0 | Default width of source/drain diffusion |
| dell | $\Delta L_D$ | um | 0.0 | Length reduction of source/drain diffusion |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| kf | $K_F$ | -- | 0.0 | Flicker noise coefficient |
| af | $A_F$ | -- | 1.0 | Flicker noise exponent |

## Equations

### Effective Dimensions

$$ L_{eff} = \max(L - \Delta L,\; 10^{-9}) $$

$$ W_{eff} = \max(W - \Delta W,\; 10^{-9}) $$

Effective channel length and width after reduction. Clamped to 1 nm minimum.

### W/L Parameter Decomposition

$$ P_{eff} = P_0 + P_L \cdot \frac{10^{-6}}{L_{eff}} + P_W \cdot \frac{10^{-6}}{W_{eff}} $$

All bias-independent model parameters (phi, k1, k2, eta0, etab, vfb, n0, nb, nd, vof0, vofb, vofd, ua0, uab, ub0, ubb, mu0b, mu20, mu2b, mu2g, mu30, mu3b, mu3g, mu40, mu4b, mu4g, ai0, aib, bi0, bib, vghigh, vglow) use this decomposition.

### Terminal Voltages and Source/Drain Swap

$$ V_{gs,raw} = (V_G - V_{S'}) \cdot \text{type} $$
$$ V_{ds,raw} = (V_{D'} - V_{S'}) \cdot \text{type} $$
$$ V_{bs,raw} = (V_B - V_{S'}) \cdot \text{type} $$

where $\text{type} = +1$ for NMOS, $-1$ for PMOS.

Source/drain reversal when $V_{ds,raw} < 0$:

$$ V_{ds,neg} = \min(V_{ds,raw},\; 0) $$
$$ V_{BS} = \max(V_{bs,raw} - V_{ds,neg},\; -V_{BB}) $$
$$ V_{GS} = \min(V_{gs,raw} - V_{ds,neg},\; V_{GG}) $$
$$ V_{DS} = \min(|V_{ds,raw}|,\; V_{DD}) $$

### Thermal Voltage

$$ V_t = k_B T_{dev} / q = 8.617333 \times 10^{-5} \cdot T_{dev} $$

where $T_{dev}$ is the device temperature in Kelvin.

### Threshold Voltage

Surface potential with body effect:

$$ V_{BS,clamp} = \max(V_{BS},\; -\phi_s + 0.01) $$

$$ \phi_{sB} = \frac{\phi_s^2}{\max(\phi_s + V_{BS,clamp},\; 0.01)} $$

$$ T_{1s} = \sqrt{\phi_{sB}} $$

DIBL coefficient:

$$ \eta = \eta_0 + \eta_b \cdot V_{BS} $$

Threshold voltage:

$$ V_{th} = V_{fb} + \phi_s + K_1 \cdot T_{1s} - K_2 \cdot \phi_{sB} - \eta \cdot V_{DS} $$

### Subthreshold Region

Subthreshold slope factor:

$$ n = n_0 + n_b \cdot V_{BS} + n_d \cdot V_{DS} $$

Threshold voltage offset:

$$ V_{of} = V_{of,0} + V_{of,b} \cdot V_{BS} + V_{of,d} \cdot V_{DS} $$

Transition voltage:

$$ V_{on} = V_{th} + V_{of} $$

Subthreshold factor (applied multiplicatively to $I_{DS}$):

$$ f_{sub} = \exp\left(\text{clamp}\left(\frac{V_{GS} - V_{on}}{n \cdot V_t},\; -80,\; 0\right)\right) $$

$f_{sub} = 1$ when $V_{GS} \geq V_{on}$; exponentially decays below threshold.

### Mobility Model

Gate-field mobility degradation coefficients:

$$ U_a = U_{a,0} + U_{ab} \cdot V_{BS} $$
$$ U_b = U_{b,0} + U_{bb} \cdot V_{BS} $$

Gate overdrive (clamped positive):

$$ V_{ov} = \max(V_{GS} - V_{th},\; 0) $$

Vertical field degradation factor:

$$ U_{vert} = \max\left(1 + V_{ov} \cdot (U_a + V_{ov} \cdot U_b),\; 0.2\right) $$

### Saturation Voltage

$$ V_{dsat} = \max\left(\frac{V_{ov}}{U_{vert}},\; 10^{-18}\right) $$

### Transconductance Parameter (Beta)

Base mobility with body bias dependence:

$$ \beta_0 = \mu_0 + \mu_{0b} \cdot V_{BS} $$

VDS-dependent beta factors:

$$ \beta_2 = \mu_{2,0} + \mu_{2b} \cdot V_{BS} + \mu_{2g} \cdot V_{GS} $$
$$ \beta_3 = \mu_{3,0} + \mu_{3b} \cdot V_{BS} + \mu_{3g} \cdot V_{GS} $$
$$ \beta_4 = \mu_{4,0} + \mu_{4b} \cdot V_{BS} + \mu_{4g} \cdot V_{GS} $$

Tanh argument (clamped to $[-30, 30]$):

$$ x_{\beta} = \text{clamp}(\beta_3 \cdot V_{DS},\; -30,\; 30) $$

Beta multiplicative correction:

$$ f_{\beta} = \max\left(1 - \beta_2 \cdot \left(\tanh(x_{\beta}) - \beta_3 \cdot V_{DS}\right) - \beta_4 \cdot V_{DS},\; 0.1\right) $$

where $\tanh$ is computed as:

$$ \tanh(x) = \frac{e^{2x} - 1}{e^{2x} + 1} $$

Final transconductance parameter:

$$ \beta = \beta_0 \cdot f_{\beta} $$

### Drain Current

Effective channel voltage (smooth triode/saturation unification):

$$ V_{DS,eff} = \min(V_{DS},\; V_{dsat}) $$

Core drain current:

$$ I_{DS,core} = \beta \cdot \left(V_{ov} - \frac{V_{DS,eff}}{2}\right) \cdot V_{DS,eff} $$

### Channel Length Modulation (Hot-Electron Effect)

$$ A_i = A_{i,0} + A_{ib} \cdot V_{BS} $$
$$ B_i = B_{i,0} + B_{ib} \cdot V_{BS} $$

Excess drain voltage:

$$ \Delta V_{DS} = \max(V_{DS} - V_{dsat},\; 10^{-20}) $$

CLM factor (only when $A_{i,0} \neq 0$ or $A_{ib} \neq 0$):

$$ f_{CLM} = 1 + A_i \cdot \exp\left(-\min\left(\frac{B_i}{\Delta V_{DS}},\; 30\right)\right) $$

Otherwise $f_{CLM} = 1$.

### Full Drain Current

Strong-inversion current:

$$ I_{DS,strong} = \max(I_{DS,core} \cdot f_{CLM},\; 0) $$

With subthreshold and GMIN:

$$ I_{DS,intrinsic} = I_{DS,strong} \cdot f_{sub} $$

$$ I_{DS} = \left(I_{DS,intrinsic} + G_{min} \cdot V_{DS}\right) \cdot M \cdot \text{type} $$

where $G_{min} = 10^{-12}$ S (convergence conductance).

### Junction Diode Currents

Junction saturation current:

$$ J_S = \max(js,\; 10^{-15}) $$

Drain-bulk voltage:

$$ V_{BD} = V_{BS} - V_{DS} $$

Source-bulk junction current:

$$ I_{BS} = M \cdot \left[J_S \cdot \left(\exp\left(\min\left(\frac{V_{BS}}{V_t},\; 80\right)\right) - 1\right) + 10^{-12} \cdot V_{BS}\right] $$

Drain-bulk junction current:

$$ I_{BD} = M \cdot \left[J_S \cdot \left(\exp\left(\min\left(\frac{V_{BD}}{V_t},\; 80\right)\right) - 1\right) + 10^{-12} \cdot V_{BD}\right] $$

### Parasitic Resistances

When $R_{SH} \neq 0$:

$$ G_D = \frac{1}{R_{SH}}, \quad G_S = \frac{1}{R_{SH}} $$

When $R_{SH} = 0$ (shorted, internal nodes tied to external):

$$ G_D = G_S = 10^{12} \;\text{S} $$

Resistance currents:

$$ I_{RD} = G_D \cdot (V_D - V_{D'}) $$
$$ I_{RS} = G_S \cdot (V_S - V_{S'}) $$

### KCL Node Stamps

$$ I_{drain} = -I_{RD} $$
$$ I_{gate} = 0 $$
$$ I_{source} = -I_{RS} $$
$$ I_{bulk} = -I_{BS} - I_{BD} $$
$$ I_{drain'} = I_{RD} + I_{DS} + I_{BD} $$
$$ I_{source'} = I_{RS} - I_{DS} + I_{BS} $$

## Charge Equations

### Gate Overlap Charges

$$ Q_{GS,ov} = C_{GSO} \cdot W_{eff} \cdot (V_G - V_{S'}) $$
$$ Q_{GD,ov} = C_{GDO} \cdot W_{eff} \cdot (V_G - V_{D'}) $$
$$ Q_{GB,ov} = C_{GBO} \cdot L_{eff} \cdot (V_G - V_B) $$

### Intrinsic Gate Charge (Simplified Meyer)

Oxide capacitance:

$$ C_{ox} = \frac{\varepsilon_{ox}}{t_{ox}} = \frac{3.453 \times 10^{-11}}{\max(t_{ox} \cdot 10^{-6},\; 10^{-12})} \;\text{F/m}^2 $$

$$ C_{ox,WL} = C_{ox} \cdot W_{eff} \cdot L_{eff} $$

Approximate threshold for charge:

$$ V_{th,q} = V_{fb} + \phi_s + K_1 \cdot \sqrt{\max(\phi_s,\; 10^{-20})} $$

Intrinsic gate charge:

$$ Q_{G,intr} = C_{ox,WL} \cdot \left(V_{GS} - V_{fb} - \frac{\phi_s}{2}\right) $$

### Junction Depletion Charges

**Forward bias** ($V_{xS} \geq 0$, blended with sigmoid):

$$ Q_{BS,fwd} = V_{BS} \cdot (C_J + C_{JSW}) + V_{BS}^2 \cdot \left(\frac{C_J \cdot M_J}{2 \phi_B} + \frac{C_{JSW} \cdot M_{JSW}}{2 \phi_{BSW}}\right) $$

**Reverse bias** ($V_{xS} < 0$):

$$ \text{arg}_{BS} = \max\left(1 - \frac{V_{BS}}{\phi_B},\; 0.01\right) $$
$$ \text{arg}_{SW,BS} = \max\left(1 - \frac{V_{BS}}{\phi_{BSW}},\; 0.01\right) $$

$$ Q_{BS,rev} = \frac{\phi_B \cdot C_J \cdot \left(1 - \text{arg}_{BS}^{1-M_J+1}\right)}{\max(1 - M_J,\; 0.01)} + \frac{\phi_{BSW} \cdot C_{JSW} \cdot \left(1 - \text{arg}_{SW,BS}^{1-M_{JSW}+1}\right)}{\max(1 - M_{JSW},\; 0.01)} $$

Note: The exponent in the reverse-bias term is $\text{arg}^{(1-M_J)} \cdot \text{arg} = \text{arg} \cdot \text{arg}^{(1-M_J)}$ from the `arg.mul(sarg)` pattern in the source, i.e. the full power term is $\text{arg}^{(2-M_J)}$. More precisely:

$$ Q_{BS,rev} = \frac{\phi_B \cdot C_J}{\max(1-M_J, 0.01)} \cdot \left(1 - \text{arg}_{BS} \cdot \text{arg}_{BS}^{(1-M_J)}\right) + \frac{\phi_{BSW} \cdot C_{JSW}}{\max(1-M_{JSW}, 0.01)} \cdot \left(1 - \text{arg}_{SW} \cdot \text{arg}_{SW}^{(1-M_{JSW})}\right) $$

**Smooth blending** using sigmoid:

$$ \sigma(V) = \frac{1}{2}\left(1 + \tanh\left(\text{clamp}(100 \cdot V,\; -30,\; 30)\right)\right) $$

$$ Q_{BS} = (1 - \sigma(V_{BS})) \cdot Q_{BS,rev} + \sigma(V_{BS}) \cdot Q_{BS,fwd} $$

The drain junction charge $Q_{BD}$ uses identical formulas with $V_{BD}$ replacing $V_{BS}$.

### Charge Node Stamps

$$ Q_{gate} = Q_{GS,ov} + Q_{GD,ov} + Q_{GB,ov} + Q_{G,intr} $$
$$ Q_{source'} = -Q_{GS,ov} - Q_{BS} $$
$$ Q_{drain'} = -Q_{GD,ov} - Q_{BD} $$
$$ Q_{bulk} = -Q_{GB,ov} - Q_{G,intr} + Q_{BS} + Q_{BD} $$
$$ Q_{drain} = 0 $$
$$ Q_{source} = 0 $$

## Convergence Limiting Functions

### PN Junction Limiting (pnjlim)

Applied to $V_{BS}$ and $V_{BD}$:

$$ V_{crit} = V_t \cdot \ln\left(\frac{V_t}{\sqrt{2} \cdot \max(J_S, 10^{-15})}\right) $$

When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 V_t$:

$$
V_{lim} = \begin{cases}
V_{old} + V_t \cdot \ln(1 + (V_{new} - V_{old})/V_t) & \text{if } V_{old} > 0 \text{ and } 1 + (V_{new}-V_{old})/V_t > 0 \\
V_{crit} & \text{if } V_{old} > 0 \text{ and } 1 + (V_{new}-V_{old})/V_t \leq 0 \\
V_t \cdot \ln(V_{new}/V_t) & \text{if } V_{old} \leq 0
\end{cases}
$$

Otherwise $V_{lim} = V_{new}$.

### FET Voltage Limiting (fetlim)

Applied to $V_{GS}$. Defines:

$$ V_{tsthi} = |2(V_{old} - V_{th})| + 2 $$
$$ V_{tstlo} = V_{tsthi}/2 + 2 $$
$$ V_{tox} = V_{th} + 3.5 $$

where $V_{th}$ for limiting uses the simplified form $V_{th} = V_{fb} + \phi_s + K_1 \cdot \sqrt{\max(\phi_s, 10^{-20})}$.

**Region: $V_{old} \geq V_{th}$ and $V_{old} \geq V_{tox}$:**
- Decreasing ($\delta V \leq 0$): if $V_{new} \geq V_{tox}$, clamp to $V_{old} - V_{tsthi}$; else clamp to $\max(V_{new}, V_{th}+2)$
- Increasing ($\delta V > 0$): clamp to $V_{old} + V_{tsthi}$

**Region: $V_{old} \geq V_{th}$ and $V_{old} < V_{tox}$:**
- Decreasing: clamp to $\max(V_{new}, V_{th}-0.5)$
- Increasing: clamp to $V_{old} + V_{tstlo}$

**Region: $V_{old} < V_{th}$ (off):**
- Decreasing: clamp to $V_{old} - V_{tsthi}$
- Increasing: clamp to $V_{old} + V_{tstlo}$

### VDS Limiting (limvds)

Applied to $V_{DS}$:

**When $V_{old} \geq 3.5$:**
$$
V_{lim} = \begin{cases}
\min(V_{new},\; 3 V_{old} + 2) & V_{new} > V_{old} \\
\max(V_{new},\; 2.0) & V_{new} < 3.5 \\
V_{new} & \text{otherwise}
\end{cases}
$$

**When $V_{old} < 3.5$:**
$$
V_{lim} = \begin{cases}
\min(V_{new},\; 4.0) & V_{new} > V_{old} \\
\max(V_{new},\; -0.5) & V_{new} \leq V_{old}
\end{cases}
$$
