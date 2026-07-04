# MOSVAR 1.4.0 — Parameter & Equation Reference

> PSP-based MOS varactor compact model for analog and RF design. Includes dynamic inversion, finite poly doping, quantum mechanics, gate tunneling currents, and parasitics.

## Model Topology

The MOSVAR device has three external terminals: **g** (gate), **bi** (bulk/well contact), and **b** (substrate), plus internal nodes **gii** (after metal resistance), **gi** (after poly resistance), and **ci** (channel-side internal node). The equivalent circuit consists of a gate-channel capacitance $C$ with gate tunneling currents $I_{gc}$ and $I_{gov}$, fringe/overlap capacitance $C_{fr}$, metal resistance $R_{gsal}$, poly gate resistance $R_{gpv}$, bias-dependent accumulation resistance $R_{ac}$, substrate well resistance $R_{sub}$, and end resistance $R_{end}$. An internal RC circuit (R=1 Ohm, C=TAU F) implements the relaxation time approximation for dynamic inversion charge formation.

## Physical and Numerical Constants

| No. | Symbol | Unit | Value | Description |
|-----|--------|------|-------|-------------|
| 1 | $k_B$ | J/K | $1.3806505 \times 10^{-23}$ | Boltzmann constant |
| 2 | $\hbar$ | J·s | $1.05457168 \times 10^{-34}$ | Reduced Planck constant |
| 3 | $q$ | C | $1.6021918 \times 10^{-19}$ | Elementary unit charge |
| 4 | $m_0$ | kg | $9.1093826 \times 10^{-31}$ | Electron rest mass |
| 5 | $\varepsilon_{ox}$ | F/m | $3.453 \times 10^{-11}$ | Absolute permittivity of oxide |
| 6 | $\varepsilon_{si}$ | F/m | $1.045 \times 10^{-10}$ | Absolute permittivity of silicon |
| 7 | $QMN$ | $\text{V}\,\text{m}^{4/3}\,\text{C}^{-2/3}$ | 5.951993 | QM constant for electrons |
| 8 | $QMP$ | $\text{V}\,\text{m}^{4/3}\,\text{C}^{-2/3}$ | 7.448711 | QM constant for holes |
| 9 | $k_{se1}$ | — | $2.3025850929940458 \times 10^{2}$ | Constant for safe exponential `expl` |
| 10 | $k_{se2}$ | — | $4.6051701859880916 \times 10^{2}$ | Constant for exponentials |

## Parameters

### Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| L | m | $10^{-6}$ | $(0, \infty)$ | Design length of varactor |
| W | m | $10^{-6}$ | $(0, \infty)$ | Design width of varactor |
| m | — | 1 | $(0, \infty)$ | Multiplicity factor (implicit for LRM2.2) |
| NGCON | — | 1 | [1, 2] | Number of gate contacts |
| DTA (alias: DTEMP) | degC | 0 | $(-\infty, \infty)$ | Local temperature offset from ambient |

### Special Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VERSION | — | 1.4 | N/A | Model version |
| SUBVERSION | — | 0 | N/A | Model subversion |
| REVISION | — | 0 | N/A | Model revision |
| LEVEL | — | 1000 | N/A | Model level |
| TMIN | degC | -100 | [-250, 21] | Minimum ambient temperature |
| TMAX | degC | 500 | [21, 1000] | Maximum ambient temperature |
| VMAX | V | 10000 | $(0, \infty)$ | Maximum voltage across node g and b |

### Geometry and Oxide Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 2 | TR (alias: TREF) | degC | 21 | [-250, 1000] | Nominal (reference) temperature |
| 3 | LMIN | m | $10^{-8}$ | $(0, \infty)$ | Minimum allowed drawn length |
| 4 | LMAX | m | $9.9 \times 10^{9}$ | $(0, \infty)$ | Maximum allowed drawn length |
| 5 | WMIN | m | $10^{-8}$ | $(0, \infty)$ | Minimum allowed drawn width |
| 6 | WMAX | m | $9.9 \times 10^{9}$ | $(0, \infty)$ | Maximum allowed drawn width |
| 7 | TOXO | m | $2 \times 10^{-9}$ | [$5 \times 10^{-10}$, $2 \times 10^{-6}$] | Oxide thickness |
| 8 | EPSROXO | — | 3.9 | $[1.0, \infty)$ | Relative dielectric permittivity |
| 15 | DLQ | m | 0 | $(-\infty, \infty)$ | Length delta for capacitor size |
| 16 | DWQ | m | 0 | $(-\infty, \infty)$ | Width delta for capacitor size |
| 17 | DWR | m | 0 | $(-\infty, \infty)$ | Width delta for substrate resistance |

### Doping Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 9 | VFBO | V | 0.0 | $(-\infty, \infty)$ | Flat-band voltage (actual value, not negated for PMOS) |
| 10 | NSUBO | m$^{-3}$ | $3 \times 10^{23}$ | [$10^{18}$, $10^{25}$] | Substrate doping level |
| 11 | MNSUBO | — | 1 | [1, 10] | Max change in absolute doping (limited to 1 order of magnitude increase) |
| 12 | DNSUBO | — | 0 | [0, 100] | Doping profile slope parameter |
| 13 | VNSUBO | — | 0 | [-5, 5] | Doping profile corner voltage parameter |
| 14 | NSLPO | — | 0.1 | [0.1, 1] | Doping profile smoothing parameter |
| 37 | NPO | m$^{-3}$ | $10^{27}$ | [$10^{24}$, $10^{27}$] | Polysilicon doping level |

### Fringing Capacitance Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 18 | CFRL | F/m | 0 | $[0, \infty)$ | Fringing capacitance in length direction |
| 19 | CFRW | F/m | 0 | $[0, \infty)$ | Fringing capacitance in width direction |

### Resistance Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 20 | RSHG | Ohm/sq | 1 | $[0, \infty)$ | Gate sheet resistance |
| 21 | RPV | Ohm$\cdot$m$^2$ | 0 | $[0, \infty)$ | Vertical resistance down through gate |
| 22 | REND | Ohm$\cdot$m | $10^{-4}$ | $[0, \infty)$ | End resistance per width |
| 23 | RSHS | Ohm/sq | 1000 | [0, 10000] | Substrate sheet resistance |
| 24 | UAC | m$^2$/V/s | $5 \times 10^{-2}$ | $(0, \infty)$ | Accumulation layer zero-bias mobility |
| 25 | UACRED | V$^{-1}$ | 0 | $[0, \infty)$ | Accumulation layer mobility degradation factor |

### Temperature Scaling Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 26 | STVFB | V/K | 0 | $(-\infty, \infty)$ | Temperature dependence of $V_{fb}$ |
| 27 | STRSHG | — | 0 | $(-\infty, \infty)$ | Temperature dependence of $R_{shg}$ |
| 28 | STRPV | — | 0 | $(-\infty, \infty)$ | Temperature dependence of $R_{pv}$ |
| 29 | STREND | — | 0 | $(-\infty, \infty)$ | Temperature dependence of $R_{end}$ |
| 30 | STRSHS | — | 0 | $(-\infty, \infty)$ | Temperature dependence of $R_{shs}$ |
| 31 | STUAC | — | 0 | $(-\infty, \infty)$ | Temperature dependence of $U_{ac}$ |

### Miscellaneous and QM Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 32 | FETA | — | 1.0 | $[0, \infty)$ | Effective field parameter |
| 38 | QMC | — | 1 | $[0, \infty)$ | Quantum mechanical correction factor |

### Switch Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 33 | SWRES | — | 1 | {0, 1} | Series resistance switch: 0=exclude, 1=include |
| 34 | TYPE | — | -1 | {-1, +1} | Substrate doping type: -1=n-type, +1=p-type |
| 35 | TYPEP | — | -1 | {-1, +1} | Polysilicon doping type: -1=n-type, +1=p-type |
| 36 | TAU | s | 0.1 | [0, 10] | Time constant for inversion charge recombination/generation |
| 39 | SWIGATE | — | 0 | {0, 1} | Gate current flag: 0=off, 1=on |
| 40 | SWQINV | — | 1 | {0, 1} | Inversion charge flag: 0=off, 1=on |
| 41 | RACNOISE | — | 1 | {0, 1, 2} | Rac noise model: 0=off, 1=bias-independent, 2=bias-dependent |

### Gate Tunneling Current Parameters

| No. | Parameter | Unit | Default | Range | Description |
|-----|-----------|------|---------|-------|-------------|
| 42 | CHIBO | V | 3.1 | $[1.0, \infty)$ | Tunneling barrier height for electrons |
| 43 | CHIBPO | V | 4.5 | $[1.0, \infty)$ | Tunneling barrier height for holes |
| 44 | LOV | m | 0 | $[0, \infty)$ | Overlap length |
| 45 | NOVO | m$^{-3}$ | $5 \times 10^{25}$ | [$10^{22}$, $10^{26}$] | Effective doping level of overlap regions |
| 46 | IGINVLW | A | 0 | $[0, \infty)$ | ECB gate channel current pre-factor for 1 um$^2$ channel area |
| 47 | IGOVW | A | 0 | $[0, \infty)$ | ECB gate overlap current pre-factor for 1 um wide gate overlap |
| 48 | GCOO | — | 0 | [-10, 10] | ECB gate tunneling energy adjustment |
| 49 | GC2O | — | 0.375 | [0, 10] | ECB gate current slope factor |
| 50 | GC3O | — | 0.063 | [-10, 10] | ECB gate current curvature factor |
| 51 | IGCHVLW | A | 0 | $[0, \infty)$ | HVB gate channel current pre-factor for 1 um$^2$ channel area |
| 52 | IGOVHVW | A | 0 | $[0, \infty)$ | HVB gate overlap current pre-factor for 1 um wide gate overlap |
| 53 | GCOHVO | — | 0 | [-10, 10] | HVB gate tunneling energy adjustment |
| 54 | GC2HVO | — | 0.375 | [0, 10] | HVB gate current slope factor |
| 55 | GC3HVO | — | 0.063 | [-10, 10] | HVB gate current curvature factor |
| 56 | IGMAX | A | $10^{-5}$ | $[0, \infty)$ | Maximum gate current (warning threshold) |
| 57 | STIG | — | 2.0 | $(-\infty, \infty)$ | Temperature dependence for gate current densities (ECB, HVB) |

---

## Equations

### 3.1 General Parameters — Effective Dimensions

$$L_{eff} = L + \text{DLQ} \tag{3.1}$$

$$W_{eff} = W + \text{DWQ} \tag{3.2}$$

### 3.2 Oxide Capacitance and Body Factors

$$C_{ox} = \varepsilon_{ox} \cdot (\text{EPSROXO}/3.9) / \text{TOXO} \tag{3.3}$$

$$\gamma_s = \sqrt{2 \cdot q \cdot \varepsilon_{si} \cdot \text{NSUBO}} / C_{ox} \tag{3.4}$$

$$\gamma_p = \sqrt{2 \cdot q \cdot \varepsilon_{si} \cdot \text{NPO}} / C_{ox} \tag{3.5}$$

$$\gamma_{ov,s} = \sqrt{2 \cdot q \cdot \varepsilon_{si} \cdot \text{NOVO}} / C_{ox} \tag{3.6}$$

Quantum mechanical factor $qq$:

$$qq = \begin{cases} 0.4 \cdot QMN \cdot \text{QMC} \cdot C_{ox}^{2/3}, & \text{if TYPE} > 0 \\ 0.4 \cdot QMP \cdot \text{QMC} \cdot C_{ox}^{2/3}, & \text{otherwise} \end{cases} \quad \text{if QMC} > 0 \tag{3.7}$$

$$qq = 0 \quad \text{if QMC} = 0 \tag{3.8}$$

Effective field factor:

$$\eta_\mu = \begin{cases} 0.5 \cdot \text{FETA}, & \text{if TYPE} > 0 \\ \frac{1}{3} \cdot \text{FETA}, & \text{otherwise} \end{cases} \tag{3.9}$$

$$\text{normtox} = \text{TOXO} / 10^{-9} \tag{3.10}$$

### 3.3 Temperature-Related Parameters

$$T_{R1} = \begin{cases} \text{TR}, & \text{if TR} \geq -273 \\ -273, & \text{if TR} < -273 \end{cases} \tag{3.11}$$

$$T_{KR} = 273.15 + T_{R1} \tag{3.12}$$

$$T_{KD} = T_A + \text{DTA} \tag{3.13}$$

$$\Delta T = T_{KD} - T_{KR} \tag{3.14}$$

$$\phi_T = k_B \cdot T_{KD} / q \tag{3.15}$$

$$q_{lim2} = 100 \cdot \phi_T^2 \tag{3.16}$$

$$E_g = 1.179 - T_{KD} \cdot (9.025 \times 10^{-5} + 3.05 \times 10^{-7} \cdot T_{KD}) \tag{3.17}$$

$$r_T = (1.045 + 4.5 \times 10^{-4} \cdot T_{KD}) \cdot (0.523 + 1.4 \times 10^{-3} \cdot T_{KD} - 1.48 \times 10^{-6} \cdot T_{KD}^2) \cdot \frac{T_{KD}^2}{90000} \tag{3.18}$$

$$\text{INV}_{ni} = 4 \times 10^{-26} \cdot r_T^{-0.75} \tag{3.19}$$

$$\phi_b = E_g + 2 \cdot \phi_T \cdot \ln(\text{NSUBO} \cdot \text{INV}_{ni}) \tag{3.20}$$

$$V_{fb,T} = \text{VFBO} + \Delta T \cdot \text{STVFB} \tag{3.21}$$

$$R_{shg,T} = \text{RSHG} \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{\text{STRSHG}} \tag{3.22}$$

$$R_{pv,T} = \text{RPV} \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{\text{STRPV}} \tag{3.23}$$

$$R_{end,T} = \text{REND} \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{\text{STREND}} \tag{3.24}$$

$$R_{shs,T} = \text{RSHS} \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{\text{STRSHS}} \tag{3.25}$$

$$U_{ac,T} = \text{UAC} \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\text{STUAC}} \tag{3.26}$$

### 3.4 Polysilicon and Overlap Region Parameters

$$G_p = \gamma_p / \sqrt{\phi_T} \tag{3.27}$$

$$\xi_p = 1 + G_p / \sqrt{2} \tag{3.28}$$

$$x_{mrgp} = 10^{-5} \cdot \xi_p \tag{3.29}$$

$$\phi_p = E_g + 2 \cdot \phi_T \cdot \ln(\text{NPO} \cdot \text{INV}_{ni}) \tag{3.30}$$

$$x_{np} = \phi_p / \phi_T \tag{3.31}$$

$$\Delta_{np} = \begin{cases} \exp(-x_{np}), & \text{if } x_{np} < k_{se2} \\ \dfrac{10^{-200}}{P_3(x_{np} - k_{se2})}, & \text{otherwise} \end{cases} \tag{3.32}$$

$$G_{ov,s} = \gamma_{ov,s} / \sqrt{\phi_T} \tag{3.33}$$

$$\xi_{ov,s} = 1 + G_{ov,s} / \sqrt{2} \tag{3.34}$$

$$x_{mrgov,s} = 10^{-5} \cdot \xi_{ov,s} \tag{3.35}$$

$$\phi_{b,ov} = E_g + 6 \cdot \phi_T \tag{3.36}$$

$$x_1 = 1.25 \tag{3.37}$$

$$x_{g1,ov} = x_1 + G_{ov,s} \cdot \sqrt{\exp(-x_1) + x_1 - 1} \tag{3.38}$$

### 3.5 Fringing Capacitance

$$C_{fr} = 2 \cdot (\text{CFRW} \cdot W + \text{CFRL} \cdot L) \tag{3.39}$$

### 3.6 Resistances

When SWRES = 1 (true):

$$R_{gsal} = \frac{R_{shg,T} \cdot W}{L \cdot [3 + 9 \cdot (\text{NGCON} - 1)]} \tag{3.40a}$$

$$R_{gpv} = \frac{R_{pv,T}}{W \cdot L} \tag{3.40b}$$

$$R_{end} = \frac{R_{end,T}}{2 \cdot (W + \text{DWR})} \tag{3.40c}$$

$$R_{sub} = \frac{R_{shs,T} \cdot L}{12 \cdot (W + \text{DWR})} \tag{3.40d}$$

After calculation, each resistance is clamped:

$$R_{gsal} = \text{CLIP\_BOTH}(R_{gsal},\; 10^{-3},\; 10) \tag{3.40e}$$

$$R_{gpv} = \text{CLIP\_BOTH}(R_{gpv},\; 10^{-3},\; 100) \tag{3.40f}$$

$$R_{end} = \text{CLIP\_BOTH}(R_{end},\; 10^{-3},\; 10) \tag{3.40g}$$

$$R_{sub} = \text{CLIP\_BOTH}(R_{sub},\; 10^{-3},\; 1000) \tag{3.40h}$$

$$U_{ac,T} = \text{CLIP\_BOTH}(U_{ac,T},\; 10^{-3},\; 20) \tag{3.40i}$$

Conductances:

$$G_{gsal} = 1 / R_{gsal} \tag{3.40j}$$

$$G_{gpv} = 1 / R_{gpv} \tag{3.40k}$$

$$G_{end} = 1 / R_{end} \tag{3.40l}$$

$$G_{sub} = 1 / R_{sub} \tag{3.40m}$$

$$G_{ac0} = 12 \cdot U_{ac,T} \cdot W / L \tag{3.40n}$$

When SWRES = 0 (false):

$$G_{gsal} = G_{gpv} = G_{end} = G_{sub} = G_{ac0} = 0 \tag{3.41}$$

### 3.7 Noise Parameter

$$nt_0 = 4 \cdot k_B \cdot T_{KD} \tag{3.42}$$

### 3.8 Gate Tunneling Parameters

When SWIGATE = 1 (true):

$$I_{ginv} = \text{IGINVLW} \cdot W_{eff} \cdot L_{eff} \cdot 10^{12} \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\text{STIG}} \tag{3.43a}$$

$$I_{gov} = 2 \cdot \text{IGOVW} \cdot \text{LOV} \cdot W_{eff} \cdot 10^{12} \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\text{STIG}} \tag{3.43b}$$

$$I_{gcHVB} = \text{IGCHVLW} \cdot W_{eff} \cdot L_{eff} \cdot 10^{12} \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\text{STIG}} \tag{3.43c}$$

$$I_{govHVB} = 2 \cdot \text{IGOVHVW} \cdot \text{LOV} \cdot W_{eff} \cdot 10^{12} \cdot \left(\frac{T_{KD}}{T_{KR}}\right)^{\text{STIG}} \tag{3.43d}$$

$$\text{INVCHIB} = 1 / \text{CHIBO} \tag{3.43e}$$

$$\text{INVCHIB}_{HVB} = 1 / \text{CHIBPO} \tag{3.43f}$$

$$B_{CH} = \frac{4}{3} \cdot \text{TOXO} \cdot \frac{\sqrt{2 \cdot q \cdot m_0 \cdot \text{CHIBO}}}{\hbar} \tag{3.43g}$$

$$B_{OV} = B_{CH} \tag{3.43h}$$

$$B_{CH,HVB} = \frac{4}{3} \cdot \text{TOXO} \cdot \frac{\sqrt{2 \cdot q \cdot m_0 \cdot \text{CHIBPO}}}{\hbar} \tag{3.43i}$$

$$B_{OV,HVB} = B_{CH,HVB} \tag{3.43j}$$

$$Q_{CQ} = \begin{cases} -0.495 \cdot \text{GC2O} / \text{GC3O}, & \text{if GC3O} < 0 \\ 0, & \text{otherwise} \end{cases} \tag{3.43k}$$

$$Q_{CQ,HVB} = \begin{cases} -0.495 \cdot \text{GC2HVO} / \text{GC3HVO}, & \text{if GC3HVO} < 0 \\ 0, & \text{otherwise} \end{cases} \tag{3.43l}$$

$$\alpha_{b,s} = 0.5 \cdot (E_g + \text{TYPE} \cdot \phi_b) \tag{3.43m}$$

$$\alpha_{b,ov} = 0.5 \cdot (E_g + \text{TYPE} \cdot \phi_{b,ov}) \tag{3.43n}$$

$$D_{ch} = \text{GCOO} \cdot \phi_T \tag{3.43o}$$

$$D_{ch,HVB} = \text{GCOHVO} \cdot \phi_T \tag{3.43p}$$

When SWIGATE = 0 (false), all gate tunneling variables are set to zero:

$$I_{ginv} = I_{gov} = I_{gcHVB} = I_{govHVB} = 0 \tag{3.44a}$$

$$\text{INVCHIB} = \text{INVCHIB}_{HVB} = 0.1 \tag{3.44b}$$

$$B_{CH} = B_{OV} = B_{CH,HVB} = B_{OV,HVB} = 0 \tag{3.44c}$$

$$Q_{CQ} = Q_{CQ,HVB} = 0 \tag{3.44d}$$

$$\alpha_{b,s} = \alpha_{b,ov} = 0 \tag{3.44e}$$

$$D_{ch} = D_{ch,HVB} = 0 \tag{3.44f}$$

---

### 4.1 Static Evaluations — Bias-Dependent Doping

$$N_{b,lim} = \text{NSUBO} \cdot \text{MNSUBO} \tag{4.1}$$

$$N_{b1} = \text{NSUBO} \cdot [1 + \text{DNSUBO} \cdot \text{MAXA}(\text{TYPE} \cdot (V_C - \text{VNSUBO}),\; 0,\; \text{NSLPO})] \tag{4.2}$$

where $V_C$ is the voltage across capacitor $C$ (nodes gi to ci).

$$N_{b,v} = \text{NSUBO} \cdot \text{MINA}(N_{b1}/\text{NSUBO},\; \text{MNSUBO},\; 10^{-6}) \tag{4.3}$$

$$\text{normnsub} = N_{b,v} / 10^{23} \tag{4.4}$$

$$\phi_{b1} = E_g + 2 \cdot \phi_T \cdot \ln(N_{b,v} \cdot \text{INV}_{ni}) \tag{4.5}$$

$$\gamma_{s1} = \sqrt{2 \cdot q \cdot \varepsilon_{si} \cdot N_{b,v}} / C_{ox} \tag{4.6}$$

When QMC > 0:

$$q_{b0} = \sqrt{\gamma_s^2 \cdot \phi_b} \tag{4.7a}$$

$$d\phi_{bq} = 0.75 \cdot qq \cdot q_{b0}^{2/3} \tag{4.7b}$$

$$\phi_b = \phi_{b1} + d\phi_{bq} \tag{4.7c}$$

$$\gamma_s = \gamma_{s1} \cdot \left(1 + \frac{4}{3} \cdot \frac{d\phi_{bq}}{q_{b0}}\right) \tag{4.7d}$$

$$G_s = \gamma_s / \sqrt{\phi_T} \tag{4.8}$$

$$\xi_s = 1 + G_s / \sqrt{2} \tag{4.9}$$

$$x_{mrgs} = 10^{-5} \cdot \xi_s \tag{4.10}$$

$$x_{ns} = \phi_b / \phi_T \tag{4.11}$$

$$\Delta_{ns} = \begin{cases} \exp(-x_{ns}), & \text{if } x_{ns} < k_{se2} \\ \dfrac{10^{-200}}{P_3(x_{ns} - k_{se2})}, & \text{otherwise} \end{cases} \tag{4.12}$$

$$x_{g1} = x_1 + G_s \cdot \sqrt{\exp(-x_1) + x_1 - 1} \tag{4.13}$$

$$x_{g1,ov} = x_1 + G_{ov,s} \cdot \sqrt{\exp(-x_1) + x_1 - 1} \tag{4.14}$$

### 4.2 Surface Potential at the Channel Side — Macro $\Phi_s$

Macro $\Phi_s$ computes normalized surface potential $x_s = \phi_s / \phi_T$ from inputs: $x_g$, $x_{ns}$, $\Delta_{ns}$, $G$, $G^2$, $G^{-2}$, $\xi$, $\xi^{-1}$, $x_{mrg}$.

**Case 1: Accumulation** ($x_g < -x_{mrg}$)

$$y_g = -x_g \tag{4.15a}$$

$$z = 1.25 \cdot y_g / \xi \tag{4.15b}$$

$$\eta = z + \left[10 - \sqrt{(z-6)^2 + 64}\right] / 2 \tag{4.15c}$$

$$a = (y_g - \eta)^2 + G^2 \cdot (\eta + 1) \tag{4.15d}$$

$$c = 2 \cdot (y_g - \eta) - G^2 \tag{4.15e}$$

$$\tau = -\eta + \ln(a / G^2) \tag{4.15f}$$

$$y_0 = \sigma_1(a, c, \tau, \eta) \tag{4.15g}$$

$$\Delta_0 = \text{explhigh}(y_0) \tag{4.15h}$$

$$p = 2 \cdot (y_g - y_0) + G^2 \cdot [\Delta_0 - 1 + \Delta_{ns} \cdot (1 - 1/\Delta_0)] \tag{4.15i}$$

$$q = (y_g - y_0)^2 + G^2 \cdot [y_0 - \Delta_0 + 1 + \Delta_{ns} \cdot (1 - 1/\Delta_0 - 2 y_0)] \tag{4.15j}$$

$$x_s = -y_0 - \frac{2q}{p + \sqrt{p^2 - 2q \cdot [2 - G^2 \cdot (\Delta_0 + \Delta_{ns}/\Delta_0)]}} \tag{4.15k}$$

**Case 2: Near flat-band** ($|x_g| \leq x_{mrg}$)

$$x_s = \frac{x_g}{\xi} \cdot \left(1 + G \cdot x_g \cdot \frac{1 - \Delta_{ns}}{\xi^2 \cdot 6\sqrt{2}}\right) \tag{4.16}$$

**Case 3: Depletion/Inversion** ($x_g > x_{mrg}$)

$$\hat{x}_{g1} = x_1 + G \cdot \sqrt{\exp(-x_1) + x_1 - 1} \tag{4.17a}$$

$$\bar{x} = \frac{x_g}{\xi} \cdot \left(1 + x_g \cdot \frac{\xi \cdot x_1 - \hat{x}_{g1}}{\hat{x}_{g1}^2}\right) \tag{4.17b}$$

$$x_0 = x_g + G^2/2 - G \cdot \sqrt{x_g + G^2/4 - 1 + \text{expllow}(-\bar{x})} \tag{4.17c}$$

$$b_x = x_{ns} + 3 \tag{4.17d}$$

$$\eta = \text{MINA}(x_0, b_x, 5) - b_x - \sqrt{b_x^2 + 5}/2 \tag{4.17e}$$

$$a = (x_g - \eta)^2 - G^2 \cdot [\exp(-\eta) + \eta - 1 - \Delta_{ns} \cdot (\eta + 1)] \tag{4.17f}$$

$$b = 1 - G^2/2 \cdot \exp(-\eta) \tag{4.17g}$$

$$c = 2 \cdot (x_g - \eta) + G^2 \cdot [1 - \exp(-\eta) - \Delta_{ns}] \tag{4.17h}$$

$$\tau = x_{ns} - \eta + \ln(a / G^2) \tag{4.17i}$$

$$y_0 = \sigma_2(a, b, c, \tau, \eta) \tag{4.17j}$$

$$\Delta_0 = \begin{cases} \exp(y_0), & \text{if } y_0 < k_{se1} \\ \exp(y_0 - x_{ns}), & \text{if } y_0 > x_{ns} - k_{se1} \\ \dfrac{10^{-100}}{P_3(x_{ns} - y_0 - k_{se1})}, & \text{otherwise} \end{cases} \tag{4.17k}$$

$$p = 2 \cdot (x_g - y_0) + G^2 \cdot [1 - 1/\Delta_0 + \Delta_{ns} \cdot (\Delta_0 - 1)] \tag{4.17l}$$

$$q = (x_g - y_0)^2 - G^2 \cdot [y_0 + 1/\Delta_0 - 1 + \Delta_{ns} \cdot (\Delta_0 - y_0 - 1)] \tag{4.17m}$$

$$x_s = y_0 + \frac{2q}{p + \sqrt{p^2 - 2q \cdot [2 - G^2 \cdot (1/\Delta_0 + \Delta_{ns} \cdot \Delta_0)]}} \tag{4.17n}$$

### 4.3 Surface Potential in Overlap Regions — Macro $\Phi_{ov}$

Macro $\Phi_{ov}$ computes normalized overlap surface potential $x_{ov}$ from inputs: $x_g$, $G_{ov}$, $G_{ov}^2$, $x_{mrgov}$, $\xi_{ov}$, $x_{g1}$.

**Case 1: Accumulation** ($x_g < -x_{mrgov}$)

$$y_g = -x_g \tag{4.18a}$$

$$z = x_1 \cdot y_g / \xi_{ov} \tag{4.18b}$$

$$\eta = z + \left[10 - \sqrt{(z-6)^2 + 64}\right] / 2 \tag{4.18c}$$

$$a = (y_g - \eta)^2 + G_{ov}^2 \cdot (\eta + 1) \tag{4.18d}$$

$$c = 2 \cdot (y_g - \eta) - G_{ov}^2 \tag{4.18e}$$

$$\tau = -\eta + \ln(a / G_{ov}^2) \tag{4.18f}$$

$$y_0 = \sigma_1(a, c, \tau, \eta) \tag{4.18g}$$

$$\Delta_0 = \exp(y_0) \tag{4.18h}$$

$$p = 2 \cdot (y_g - y_0) + G_{ov}^2 \cdot (\Delta_0 - 1) \tag{4.18i}$$

$$q = (y_g - y_0)^2 + G_{ov}^2 \cdot (y_0 - \Delta_0 + 1) \tag{4.18j}$$

$$x_{ov} = -y_0 - \frac{2q}{p + \sqrt{p^2 - 2q \cdot (2 - G_{ov}^2 \cdot \Delta_0)}} \tag{4.18k}$$

**Case 2: Near flat-band** ($|x_g| < x_{mrgov}$)

$$x_{ov} = x_g / \xi_{ov} \tag{4.18l}$$

**Case 3: Depletion** ($x_g > x_{mrgov}$)

$$\bar{x} = \frac{x_g}{\xi_{ov}} \cdot \left(1 + x_g \cdot \frac{\xi_{ov} \cdot x_1 - x_{g1}}{x_{g1}^2}\right) \tag{4.18m}$$

$$\omega = \begin{cases} 1 - \exp(-\bar{x}), & \text{if } \bar{x} < k_{se2} \\ 1 - \dfrac{10^{-200}}{P_3(\bar{x} - k_{se2})}, & \text{otherwise} \end{cases} \tag{4.18n}$$

$$x_0 = x_g + G_{ov}^2/2 - G_{ov} \cdot \sqrt{x_g + G_{ov}^2/4 - \omega} \tag{4.18o}$$

$$\Delta_0 = \begin{cases} \exp(-x_0), & \text{if } x_0 < k_{se2} \\ \dfrac{10^{-200}}{P_3(x_0 - k_{se2})}, & \text{otherwise} \end{cases} \tag{4.18p}$$

$$p = 2 \cdot (x_g - x_0) + G_{ov}^2 \cdot (1 - \Delta_0) \tag{4.18q}$$

$$q = (x_g - x_0)^2 - G_{ov}^2 \cdot (x_0 + \Delta_0 - 1) \tag{4.18r}$$

$$x_{ov} = x_0 + \frac{2q}{p + \sqrt{p^2 - 2q \cdot (2 - G_{ov}^2 \cdot \Delta_0)}} \tag{4.18s}$$

### 4.4 Surface Potential without Poly Effect

$$V_{gb1} = \text{TYPE} \cdot (V_C - V_{fb,T}) \tag{4.19}$$

$$x_g = V_{gb1} / \phi_T \tag{4.20}$$

$$x_{s0} = \Phi_s(x_g, x_{ns}, \Delta_{ns}, G_s, G_s^2, G_s^{-2}, \xi_s, \xi_s^{-1}, x_{mrgs}) \tag{4.21}$$

$$\psi_{s0} = x_{s0} \cdot \phi_T \tag{4.22}$$

### 4.5 Surface Potential with Poly Effect

When NPO $\geq 10^{27}$, $\psi_{p0} = 0$. When NPO $< 10^{27}$:

$$x_{gp} = -\text{TYPE} \cdot \text{TYPEP} \cdot (V_{gb1} - \psi_{s0}) / \phi_T \tag{4.23}$$

$$x_{p0} = \Phi_s(x_{gp}, x_{np}, \Delta_{np}, G_p, G_p^2, G_p^{-2}, \xi_p, \xi_p^{-1}, x_{mrgp}) \tag{4.24}$$

$$\psi_{p0} = -\text{TYPE} \cdot \text{TYPEP} \cdot x_{p0} \cdot \phi_T \tag{4.25}$$

$$x_g = (V_{gb1} - \psi_{p0}) / \phi_T \tag{4.26}$$

$$x_{s0} = \Phi_s(x_g, x_{ns}, \Delta_{ns}, G_s, G_s^2, G_s^{-2}, \xi_s, \xi_s^{-1}, x_{mrgs}) \tag{4.27}$$

$$\psi_{s0} = x_{s0} \cdot \phi_T \tag{4.28}$$

### 4.6 Static Inversion Charge Calculations

$$\text{If } x_g \leq 0: \quad q_{is} = 0 \tag{4.29}$$

When $x_g > 0$:

$$\Delta_{ls} = 0 \tag{4.30}$$

$$\text{If } x_{s0} < k_{se1}: \quad \Delta_{ls1} = \exp(x_{s0}), \quad E_s = \Delta_{ls1}^{-1}, \quad \Delta_{ls} = \Delta_{ns} \cdot \Delta_{ls1}, \quad D_s = \Delta_{ns} \cdot (E_s^{-1} - x_{s0} - 1) \tag{4.31a}$$

$$\text{else if } x_{s0} > x_{ns} - k_{se1}: \quad \Delta_{ls} = \exp(x_{s0} - x_{ns}), \quad E_s = \Delta_{ns}/\Delta_{ls}, \quad D_s = \Delta_{ls} - \Delta_{ns} \cdot (x_{s0} + 1) \tag{4.31b}$$

$$\text{else}: \quad \Delta_{ls} = \frac{10^{-100}}{P_3(x_{ns} - x_{s0} - k_{se1})}, \quad E_s = \frac{10^{-100}}{P_3(x_{s0} - k_{se1})}, \quad D_s = \Delta_{ls} - \Delta_{ns} \cdot (x_{s0} + 1) \tag{4.31c}$$

$$\text{If } x_{s0} < 10^{-5}:$$

$$P_s = 0.5 \cdot x_{s0}^2 \cdot \left(1 - \frac{1}{3} x_{s0} \cdot (1 - 0.25 \cdot x_{s0})\right) \tag{4.32a}$$

$$D_s = \frac{1}{6} \Delta_{ns} \cdot x_{s0}^3 \cdot (1 + 1.75 \cdot x_{s0}) \tag{4.32b}$$

$$S_{qs} = x_{s0} \cdot \sqrt{0.5 - \frac{1}{6} x_{s0} \cdot (1 - 0.25 \cdot x_{s0})} \tag{4.32c}$$

$$\text{else}:$$

$$P_s = x_{s0} + E_s - 1 \tag{4.32d}$$

$$S_{qs} = \sqrt{P_s} \tag{4.32e}$$

$$x_{gs} = G_s \cdot \sqrt{P_s + D_s} \tag{4.33a}$$

$$q_{is} = \phi_T \cdot G_s^2 \cdot D_s / (x_{gs} + G_s \cdot S_{qs}) \tag{4.33b}$$

Normalized static inversion charge:

$$Q_{i0} = -q_{is} \quad \text{(when SWQINV = 1)} \tag{4.34}$$

$$Q_{i0} = 0 \quad \text{(when SWQINV = 0)} \tag{4.35}$$

### 4.7 Time-Dependent Surface Potential without Poly Effect

$$x_{g,t} = (V_{gb1} + V_n) / \phi_T \tag{4.36}$$

where $V_n$ is the voltage at the internal time-constant node $n$.

$$x_s = \Phi_{ov}(x_{g,t}, G_s, G_s^2, x_{mrgs}, \xi_s, x_{g1}) \tag{4.37}$$

$$\psi_s = x_s \cdot \phi_T \tag{4.38}$$

### 4.8 Time-Dependent Poly Surface Potential Correction

When NPO $\geq 10^{27}$, $\psi_p = 0$. Otherwise:

$$x_{gp,t} = -\text{TYPE} \cdot \text{TYPEP} \cdot (V_{gb1} - \psi_s) / \phi_T \tag{4.39}$$

$$x_p = \Phi_s(x_{gp,t}, x_{np}, \Delta_{np}, G_p, G_p^2, G_p^{-2}, \xi_p, \xi_p^{-1}, x_{mrgp}) \tag{4.40}$$

$$\psi_p = -\text{TYPE} \cdot \text{TYPEP} \cdot x_p \cdot \phi_T \tag{4.41}$$

$$x_{g,t} = (V_{gb1} + V_n - \psi_p) / \phi_T \tag{4.42}$$

$$x_s = \Phi_{ov}(x_{g,t}, G_s, G_s^2, x_{mrgs}, \xi_s, x_{g1}) \tag{4.43}$$

$$\psi_s = x_s \cdot \phi_T \tag{4.44}$$

### 4.9 Quantum Mechanical Corrections

$$\Delta_{ls} = 0 \tag{4.45}$$

$$\text{If } x_s < k_{se1}: \quad \Delta_{ls} = \exp(x_s), \quad E_s = \Delta_{ls}^{-1} \tag{4.46a}$$

$$\text{else if } x_s > x_{ns} - k_{se1}: \quad \Delta_{ls} = \exp(x_{ns} - x_s), \quad E_s = \Delta_{ns} \cdot \Delta_{ls} \tag{4.46b}$$

$$\text{else}: \quad E_s = \frac{10^{-100}}{P_3(x_s - k_{se1})} \tag{4.46c}$$

$$\text{If } x_s < -x_{mrgs}: \quad P_s = E_s + x_s - 1, \quad S_{qs} = -\sqrt{P_s} \tag{4.47a}$$

$$\text{else if } |x_s| \leq x_{mrgs}: \quad P_s = 0.5 \cdot x_s^2 \cdot \left(1 - \frac{1}{3} x_s \cdot (1 - 0.25 \cdot x_s)\right), \quad S_{qs} = x_s \cdot \sqrt{0.5 - \frac{1}{6} x_s \cdot (1 - 0.25 \cdot x_s)} \tag{4.47b}$$

$$\text{else}: \quad P_s = x_s + E_s - 1, \quad S_{qs} = \sqrt{P_s} \tag{4.47c}$$

$$q_{bs} = \phi_T \cdot S_{qs} \cdot G_s \tag{4.48a}$$

$$\epsilon = 1.62 \cdot [(1 + \text{normnsub}) \cdot (1 + 0.37 \cdot \text{normtox})]^2 \cdot \left(\frac{T_{KR}}{T_{KD}}\right)^{1.5} \cdot \phi_T^2 \tag{4.48b}$$

$$q_{eff} = \text{MAXA}(q_{bs}, -q_{bs}, \epsilon) + \eta_\mu \cdot \text{MAXA}(-V_n, V_n, \epsilon) \tag{4.48c}$$

Quantum-corrected oxide capacitance (all regions):

$$C_{ox,qm} = \begin{cases} C_{ox}, & \text{if } qq = 0 \\ \dfrac{C_{ox}}{1 + qq \cdot (q_{eff}^2 + q_{lim2})^{-1/6}}, & \text{if } qq > 0 \end{cases} \tag{4.49}$$

### 4.10 Accumulation Resistance Bias Dependence

$$\text{frac} = \begin{cases} \phi_T \cdot \exp(-10), & \text{if } x_{s0} > 10 \\ \phi_T \cdot \exp(-x_{s0}), & \text{otherwise} \end{cases} \tag{4.50}$$

$$q_{ac} = \gamma_s \cdot C_{ox,qm} \cdot \sqrt{\text{frac}} \tag{4.51}$$

$$\text{maxs} = 0.5 \cdot \left(-V_{gb1} + \sqrt{V_{gb1}^2 + 0.04}\right) \tag{4.52}$$

$$G_{ac} = G_{ac0} \cdot q_{ac} / (1 + \text{UACRED} \cdot \text{maxs}) \tag{4.53}$$

### 4.11 Gate Tunneling Current Macro — $I_{gate}$

$I_{gate}$ is a function of: $I_{gin}$, $I_{ginHVB}$, $E_g$, $V_{ov}$, $D_{ch}$, $D_{ch,HVB}$, INVCHIB, INVCHIB$_{HVB}$, GC2O, GC3O, GC2HVO, GC3HVO, $Q_{CQ}$, $Q_{CQ,HVB}$, $I_{g,type}$, $x_s$, $\alpha_{b,s}$, $\alpha_{b,ov}$, $\phi_T^{-1}$, TYPEP, TYPE, $V_{b,ig}$, $B_{OV}$, $B_{OV,HVB}$.

**HVB component** (when TYPEP = 1):

$$\psi_t = \text{MAXA}(0, \text{TYPE} \cdot V_{ov} + D_{ch,HVB}, 0.01) \tag{4.54a}$$

$$z_g = \sqrt{V_{ov}^2 + 10^{-6}} \cdot \text{INVCHIB}_{HVB} \tag{4.54b}$$

$$\text{If GC3HVO} < 0: \quad z_g = \text{MINA}(z_g, Q_{CQ,HVB}, 10^{-6}) \tag{4.54c}$$

$$\Delta_{si} = \begin{cases} \exp\left[-\text{TYPE} \cdot x_s - (E_g - \alpha_{b,ov} + \psi_t) \cdot \phi_T^{-1}\right], & \text{if } I_{g,type} = 0 \\ \exp\left[-\text{TYPE} \cdot x_s - (E_g - \alpha_{b,s} + \psi_t) \cdot \phi_T^{-1}\right], & \text{if } I_{g,type} = 1 \end{cases} \tag{4.54d}$$

$$\Delta_{gate} = \Delta_{si} \cdot \exp\left(\text{TYPE} \cdot V_{b,ig} \cdot \phi_T^{-1}\right) \tag{4.54e}$$

$$D = \exp\{B_{OV,HVB} \cdot [-1.5 + z_g \cdot (\text{GC2HVO} + \text{GC3HVO} \cdot z_g)]\} \tag{4.54f}$$

$$I_{gout,HVB} = I_{ginHVB} \cdot D \cdot \text{TYPE} \cdot \ln\!\left(\frac{1 + \Delta_{gate}}{1 + \Delta_{si}}\right) \tag{4.54g}$$

**ECB component:**

$$\psi_t = \text{MINA}(0, \text{TYPE} \cdot V_{ov} + D_{ch}, 0.01) \tag{4.55}$$

$$z_g = \sqrt{V_{ov}^2 + 10^{-6}} \cdot \text{INVCHIB} \tag{4.56}$$

$$\text{If GC3O} < 0: \quad z_g = \text{MINA}(z_g, Q_{CQ}, 10^{-6}) \tag{4.57}$$

$$\Delta_{si} = \begin{cases} \exp\left[\text{TYPE} \cdot x_s + (-\alpha_{b,ov} + \psi_t) \cdot \phi_T^{-1}\right], & \text{if } I_{g,type} = 0 \\ \exp\left[\text{TYPE} \cdot x_s + (-\alpha_{b,s} + \psi_t) \cdot \phi_T^{-1}\right], & \text{if } I_{g,type} = 1 \end{cases} \tag{4.58}$$

$$\Delta_{gate} = \Delta_{si} \cdot \exp\left(-\text{TYPE} \cdot V_{b,ig} \cdot \phi_T^{-1}\right) \tag{4.59}$$

$$D = \exp\{B_{OV} \cdot [-1.5 + z_g \cdot (\text{GC2O} + \text{GC3O} \cdot z_g)]\} \tag{4.60}$$

$$I_{gout,ECB} = I_{gin} \cdot D \cdot \text{TYPE} \cdot \ln\!\left(\frac{1 + \Delta_{si}}{1 + \Delta_{gate}}\right) \tag{4.61}$$

**Total:**

$$I_{gout} = I_{gout,HVB} + I_{gout,ECB} \tag{4.62}$$

**Overflow prevention approximation** (when $A_{si}$ is large):

$$\ln(1 + \Delta_{si}) = \ln(1 + \exp(A_{si})) \approx A_{si} \tag{4.63}$$

### 4.12 Gate Tunneling Current

$$V_{fb,ov} = \begin{cases} \text{TYPEP} \cdot E_g, & \text{if TYPE} \cdot \text{TYPEP} = -1 \\ 0, & \text{otherwise} \end{cases} \tag{4.64}$$

$$x_{g,ov} = \text{TYPE} \cdot (V_{b,ov} - V_{fb,ov}) / \phi_T \tag{4.65}$$

If SWIGATE $\neq 0$ and $I_{gov} + I_{govHVB} > 0$:

$$x_{ov,s0} = \Phi_{ov}(x_{g,ov}, G_{ov,s}, G_{ov,s}^2, x_{mrgov,s}, \xi_{ov,s}, x_{g1,ov}) \tag{4.66}$$

$$V_{ov} = \phi_T \cdot (x_{g,ov} - x_{ov,s0}) \tag{4.67}$$

Otherwise:

$$V_{ov} = 0, \quad x_{ov,s0} = 0 \tag{4.68-4.69}$$

Initial values:

$$I_{GC} = 0, \quad I_{GOV} = 0 \tag{4.70-4.71}$$

When SWIGATE = 1:

If $I_{gov} + I_{govHVB} > 0$:

$$V_{bov,ig} = V_{b,ov} \cdot \text{TYPE} \tag{4.72}$$

$$I_{GOV} = I_{gate}(I_{gov}, I_{govHVB}, E_g, V_{ov}, D_{ch}, D_{ch,HVB}, \text{INVCHIB}, \text{INVCHIB}_{HVB}, \text{GC2O}, \text{GC3O}, \text{GC2HVO}, \text{GC3HVO}, Q_{CQ}, 0, x_{ov,s0}, \alpha_{b,s}, \alpha_{b,ov}, \phi_T^{-1}, \text{TYPEP}, \text{TYPE}, V_{bov,ig}, B_{OV}, B_{OV,HVB}) \tag{4.73}$$

If $I_{ginv} + I_{gcHVB} > 0$:

$$V_{bci,ig} = V_C \cdot \text{TYPE} \tag{4.74}$$

$$V_{ox} = (x_g - x_s) \cdot \phi_T \tag{4.75}$$

$$I_{GC} = I_{gate}(I_{ginv}, I_{gcHVB}, E_g, V_{ox}, D_{ch}, D_{ch,HVB}, \text{INVCHIB}, \text{INVCHIB}_{HVB}, \text{GC2O}, \text{GC3O}, \text{GC2HVO}, \text{GC3HVO}, Q_{CQ}, 1, x_s, \alpha_{b,s}, \alpha_{b,ov}, \phi_T^{-1}, \text{TYPEP}, \text{TYPE}, V_{bci,ig}, B_{CH}, B_{CH,HVB}) \tag{4.76}$$

### 4.13 Currents

**DC Current through gate terminal:**

$$I_{g,DC} = I_{GC} + I_{GOV} \tag{4.77}$$

**Resistor currents** (when SWRES = 1):

$$I_{Rgsal} = V_{Rgsal} \cdot G_{gsal} \tag{4.78}$$

$$I_{Rgpv} = V_{Rgpv} \cdot G_{gpv} \tag{4.79}$$

$$I_{Rsub} = V_{Rsub} \cdot G_{sub} \tag{4.80}$$

$$I_{Rend} = V_{Rend} \cdot G_{end} \tag{4.81}$$

### 4.14 Terminal Charges

Total charge at the gate:

$$Q_{g,total} = (V_{gb1} - \phi_s - \phi_p) \cdot L_{eff} \cdot W_{eff} \cdot C_{ox,qm} \cdot \text{TYPE} + C_{fr} \cdot V_{C,fr} \tag{4.82}$$

Total charge at the bulk:

$$Q_{b,total} = -(V_{gb1} - \phi_s - \phi_p) \cdot L_{eff} \cdot W_{eff} \cdot C_{ox,qm} \cdot \text{TYPE} - C_{fr} \cdot V_{C,fr} \tag{4.83}$$

### 4.15 Noise

#### 4.15.1 Thermal Noise

When SWRES = 1 (noise PSD values; when SWRES = 0 all are zero):

$$S_{Rgsal} = nt_0 \cdot G_{gsal} \tag{4.84}$$

$$S_{Rgpv} = nt_0 \cdot G_{gpv} \tag{4.85}$$

$$S_{Rend} = nt_0 \cdot G_{end} \tag{4.86}$$

$$S_{Rsub} = nt_0 \cdot G_{sub} \tag{4.87}$$

Accumulation resistance noise:

$$S_{Rac} = 0 \quad \text{(RACNOISE = 0)} \tag{4.88}$$

$$S_{Rac} = nt_0 \cdot G_{ac0} \quad \text{(RACNOISE = 1)} \tag{4.89}$$

$$S_{Rac} = nt_0 \cdot G_{ac} \quad \text{(RACNOISE = 2)} \tag{4.90}$$

#### 4.15.2 Shot Noise

When SWIGATE = 1:

$$S_{Igc} = 2 \cdot q \cdot |I_{GC}| \tag{4.91}$$

$$S_{Igov} = 2 \cdot q \cdot |I_{GOV}| \tag{4.92}$$

### 5.1 Parasitic Element Equations (Physical Description)

**Fringing capacitance:**

$$C_{fr} = 2 \cdot (\text{CFRW} \cdot W + \text{CFRL} \cdot L) \tag{5.1}$$

**Well resistance (bias-independent):**

$$R_{sub} = \frac{R_{shs,T} \cdot L}{12 \cdot (W + \text{DWR})} \tag{5.2}$$

**Accumulation resistance:**

$$R_{ac} = \frac{L}{12 \cdot W \cdot \mu_{acV} \cdot Q_{ac}} \tag{5.3}$$

where $\mu_{acV} = \text{UAC} / [1 + \text{UACRED} \cdot (\text{VFBO} - V_{GBi})]$ and $Q_{ac}$ is the accumulation charge density from the surface potential.

**End resistance:**

$$R_{end} = \frac{R_{end,T}}{2 \cdot (W + \text{DWR})} \tag{5.4}$$

**Salicided poly gate resistance:**

$$R_{gsal} = \frac{R_{shg,T} \cdot W}{L \cdot [3 + 9 \cdot (\text{NGCON} - 1)]} \tag{5.5}$$

**Vertical gate resistance:**

$$R_{gpv} = \frac{R_{pv,T}}{W \cdot L} \tag{5.6}$$

**Total capacitance model:**

$$C(V) = C_o(V) \cdot L \cdot W + C_{fr} \tag{5.7}$$

$$C_{fr} = 2 \cdot \text{CFRW} \cdot W + 2 \cdot \text{CFRL} \cdot L \tag{5.8}$$

### 5.2 Parameter Extraction Equations

$$\text{XINT}_{wg} = -\text{DWQ} \tag{5.9}$$

$$\text{YINT}_{cwg} = 2 \cdot \text{CFRL} \cdot (L_g + \text{DLQ}) \cdot m \tag{5.10}$$

$$\text{XINT}_{lg} = -\text{DLQ} \tag{5.11}$$

$$\text{YINT}_{clg} = 2 \cdot \text{CFRW} \cdot (W_g + \text{DWQ}) \cdot m \tag{5.12}$$

**Extracted NWELL resistance:**

$$R_{nwx} = R_{meas@V_{GB}=0} - (R_{gm} + R_{sm} + R_{gsal}) \tag{5.13}$$

---

## Appendix A — Auxiliary Functions

### MINA Smoothing Function

$$\text{MINA}(x, y, a) = \begin{cases} y - \frac{1}{2}\left(y - x + \sqrt{(y-x)(y-x) + a}\right), & \text{if } (y-x) > \text{MEPS} \\ y - \frac{1}{2} \cdot a \,/\, \left(x - y + \sqrt{(x-y)(x-y) + a}\right), & \text{if } (x-y) > \text{MEPS} \\ y - \frac{1}{2}\left(y - x + \sqrt{\text{MEPSSQ} + a}\right), & \text{otherwise} \end{cases} \tag{A.1}$$

### MAXA Smoothing Function

$$\text{MAXA}(x, y, a) = \begin{cases} y + \frac{1}{2}\left(x - y + \sqrt{(x-y)(x-y) + a}\right), & \text{if } (x-y) > \text{MEPS} \\ y + \frac{1}{2} \cdot a \,/\, \left(y - x + \sqrt{(y-x)(y-x) + a}\right), & \text{if } (y-x) > \text{MEPS} \\ y + \frac{1}{2}\left(x - y + \sqrt{\text{MEPSSQ} + a}\right), & \text{otherwise} \end{cases} \tag{A.2}$$

where $\text{MEPS} = 10^{-16}$ and $\text{MEPSSQ} = 10^{-32}$.

### Surface Potential Approximation Functions $\sigma_1$ and $\sigma_2$

$$\nu = a + c \tag{A.3}$$

$$\mu_1 = \frac{\nu^2}{\tau} + \frac{c^2}{2} - a \tag{A.4}$$

$$\sigma_1(a, c, \tau, \eta) = \frac{a \cdot \nu}{\mu_1 + (c^2/3 - a) \cdot c \cdot \nu / \mu_1} + \eta \tag{A.5}$$

$$\mu_2 = \frac{\nu^2}{\tau} + \frac{c^2}{2} - a \cdot b \tag{A.6}$$

$$\sigma_2(a, b, c, \tau, \eta) = \frac{a \cdot \nu}{\mu_2 + (c^2/3 - a \cdot b) \cdot c \cdot \nu / \mu_2} + \eta \tag{A.7}$$

### Polynomial Function

$$P_3(u) = 1 + u \cdot [1 + 0.5 \cdot u \cdot (1 + u/3)] \tag{A.8}$$

### Safe Exponential Functions

$$\text{expl}(x) = \begin{cases} \exp(x), & \text{if } |x| < k_{se1} \\ \dfrac{10^{-100}}{P_3(-k_{se1} - x)}, & \text{if } x < -k_{se1} \\ 10^{100} \cdot P_3(x - k_{se1}), & \text{otherwise} \end{cases} \tag{A.9}$$

$$\text{expllow}(x) = \begin{cases} \exp(x), & \text{if } x > -k_{se1} \\ \dfrac{10^{-100}}{P_3(-k_{se1} - x)}, & \text{otherwise} \end{cases} \tag{A.10}$$

$$\text{explhigh}(x) = \begin{cases} \exp(x), & \text{if } x < k_{se1} \\ 10^{100} \cdot P_3(x - k_{se1}), & \text{otherwise} \end{cases} \tag{A.11}$$

### Inversion Charge Relaxation Time Approximation

$$q_i = q_{i0} - \text{TAU} \cdot \frac{dq_i}{dt} \tag{1.1}$$

Implemented as an RC circuit: current source = $q_{i0}$, R = 1 Ohm, C = TAU F.
