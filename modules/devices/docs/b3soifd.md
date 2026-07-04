# BSIM3SOI-FD v2.0 -- Parameter & Equation Reference

> Berkeley BSIM3 Silicon-on-Insulator Fully-Depleted MOSFET model (4-terminal SOI FET with self-heating)

## Model Topology

The device has 4 external ports: **Drain (d)**, **Gate (g)**, **Source (s)**, **Substrate/back-gate (e)**. Internally it adds 5 nodes: **Drain-prime (dp)** and **Source-prime (sp)** (parasitic S/D resistances), **Body (b)** (floating body), **Temp (temp)** (self-heating thermal node), and **P** (body-contact node connecting body to substrate via sheet resistance). The intrinsic MOSFET sits between dp, g, sp, b; the back-gate couples through buried-oxide capacitance from e to b. The thermal node models power dissipation through Rth0/Cth0.

## Parameters

### Model Selectors

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| capmod | - | - | 2 | {0,1,2} | Capacitance model selector |
| mobmod | - | - | 1 | {1,2,3} | Mobility model selector |
| noimod | - | - | 1 | {1,2} | Noise model selector |
| paramchk | - | - | 0 | {0,1} | Model parameter checking selector |
| binunit | - | - | 1 | {1,2} | Bin unit selector |
| shmod | - | - | 0 | {0,1} | Self-heating mode selector |
| version | - | - | 2.0 | - | Model version |
| type_ | - | - | 1 | {-1,1} | Device type: 1=NMOS, -1=PMOS |

### Process / Geometry

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tox | $t_{ox}$ | m | 1.0e-8 | >0 | Gate oxide thickness |
| tbox | $t_{box}$ | m | 3.0e-7 | >0 | Back-gate (buried) oxide thickness |
| tsi | $t_{si}$ | m | 1.0e-7 | >0 | Silicon-on-insulator film thickness |
| nsub | $N_{sub}$ | cm$^{-3}$ | 6.0e16 | >0 | Substrate doping concentration |
| nch | $N_{ch}$ | cm$^{-3}$ | 1.7e17 | >0 | Channel doping concentration |
| ngate | $N_{gate}$ | cm$^{-3}$ | 0 | >=0 | Poly-gate doping concentration |
| xt | $x_t$ | m | 1.55e-7 | >0 | Doping depth |
| xj | $x_j$ | m | NaN | >0 | Junction depth (defaults to 1.55e-7 if NaN) |
| ld | $L_d$ | m | 0 | - | Lateral diffusion length |

### Threshold Voltage

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vth0 | $V_{th0}$ | V | 0.7 | - | Threshold voltage at zero bias |
| k1 | $K_1$ | V$^{0.5}$ | 0 | - | First-order body effect coefficient (auto-calculated if 0) |
| k2 | $K_2$ | - | 0 | - | Second-order body effect coefficient |
| k3 | $K_3$ | - | 0 | - | Narrow width effect coefficient |
| k3b | $K_{3b}$ | V$^{-1}$ | 0 | - | Body effect coefficient of K3 |
| w0 | $W_0$ | m | 2.5e-6 | - | Narrow width effect parameter |
| nlx | $N_{lx}$ | m | 1.74e-7 | - | Lateral non-uniform doping effect |
| dvt0 | $Dvt_0$ | - | 2.2 | - | Short channel effect coefficient 0 |
| dvt1 | $Dvt_1$ | - | 0.53 | - | Short channel effect coefficient 1 |
| dvt2 | $Dvt_2$ | V$^{-1}$ | -0.032 | - | Short channel effect coefficient 2 |
| dvt0w | $Dvt_{0w}$ | - | 0 | - | Narrow width coefficient 0 |
| dvt1w | $Dvt_{1w}$ | m$^{-1}$ | 5.3e6 | - | Narrow width effect coefficient 1 |
| dvt2w | $Dvt_{2w}$ | V$^{-1}$ | -0.032 | - | Narrow width effect coefficient 2 |
| gamma1 | $\gamma_1$ | V$^{0.5}$ | 0 | - | Vth body coefficient |
| gamma2 | $\gamma_2$ | V$^{0.5}$ | 0 | - | Vth body coefficient |
| vbx | $V_{bx}$ | V | 0 | - | Vth transition body voltage |
| vbm | $V_{bm}$ | V | -3.0 | - | Maximum body voltage |
| eta0 | $\eta_0$ | - | 0.08 | - | Subthreshold region DIBL coefficient |
| etab | $\eta_b$ | V$^{-1}$ | -0.07 | - | Subthreshold region DIBL body-bias coefficient |
| dsub | $D_{sub}$ | - | 0.56 | - | DIBL coefficient in subthreshold region |
| voff | $V_{off}$ | V | -0.08 | - | Threshold voltage offset for subthreshold |
| nfactor | $N_{factor}$ | - | 1.0 | - | Subthreshold swing coefficient |
| cdsc | $C_{dsc}$ | F/m$^2$ | 2.4e-4 | - | Drain/source-channel coupling capacitance |
| cdscb | $C_{dscb}$ | F/(V-m$^2$) | 0 | - | Body-bias dependence of Cdsc |
| cdscd | $C_{dscd}$ | F/(V-m$^2$) | 0 | - | Drain-bias dependence of Cdsc |
| cit | $C_{it}$ | F/m$^2$ | 0 | - | Interface state capacitance |

### Temperature

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tnom | $T_{nom}$ | K | 300.15 | >0 | Parameter measurement temperature |
| kt1 | $K_{t1}$ | V | -0.11 | - | Temperature coefficient of Vth |
| kt1l | $K_{t1l}$ | V-m | 0 | - | Temperature coefficient of Vth (length-dependent) |
| kt2 | $K_{t2}$ | - | 0.022 | - | Body-coefficient of Kt1 |
| ute | $U_{te}$ | - | -1.5 | - | Temperature exponent of mobility |
| ua1 | $U_{a1}$ | m/V | 4.31e-9 | - | Temperature coefficient of Ua |
| ub1 | $U_{b1}$ | (m/V)$^2$ | -7.61e-18 | - | Temperature coefficient of Ub |
| uc1 | $U_{c1}$ | m/V$^2$ | -5.6e-11 | - | Temperature coefficient of Uc |
| at | $A_t$ | m/s | 33000 | - | Temperature coefficient of Vsat |
| prt | $P_{rt}$ | $\Omega$-$\mu$m | 0 | - | Temperature coefficient of parasitic resistance |

### Mobility

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| u0 | $\mu_0$ | cm$^2$/(V-s) | 0.067 | >0 | Low-field mobility at Tnom |
| ua | $U_a$ | m/V | 2.25e-9 | - | Linear gate dependence of mobility |
| ub | $U_b$ | (m/V)$^2$ | 5.87e-19 | - | Quadratic gate dependence of mobility |
| uc | $U_c$ | m/V$^2$ | -4.65e-11 | - | Body-bias dependence of mobility |

### Saturation / Velocity

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vsat | $v_{sat}$ | m/s | 80000 | >0 | Saturation velocity at Tnom |
| a0 | $A_0$ | - | 1.0 | - | Non-uniform depletion width effect coefficient |
| ags | $A_{gs}$ | V$^{-1}$ | 0 | - | Gate bias coefficient of Abulk |
| a1 | $A_1$ | - | 0 | - | Non-saturation effect coefficient |
| a2 | $A_2$ | - | 1.0 | - | Non-saturation effect coefficient (lambda) |
| b0 | $B_0$ | m | 0 | - | Abulk narrow width parameter |
| b1 | $B_1$ | m | 0 | - | Abulk narrow width parameter |
| keta | $K_{eta}$ | V$^{-1}$ | -0.047 | - | Body-bias coefficient of non-uniform depletion width |
| delta | $\delta$ | V | 0.01 | - | Effective Vds smoothing parameter |

### Output Resistance / CLM / DIBL

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| pclm | $P_{clm}$ | - | 1.3 | - | Channel length modulation coefficient |
| pdiblc1 | $P_{diblc1}$ | - | 0.39 | - | DIBL coefficient 1 |
| pdiblc2 | $P_{diblc2}$ | - | 0.0086 | - | DIBL coefficient 2 |
| pdiblcb | $P_{diblcb}$ | V$^{-1}$ | 0 | - | Body-effect on DIBL |
| drout | $D_{rout}$ | - | 0.56 | - | DIBL coefficient of output resistance |
| pvag | $P_{vag}$ | - | 0 | - | Gate dependence of output resistance parameter |

### Parasitic Resistance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rsh | $R_{sh}$ | $\Omega$/sq | 0 | >=0 | Source-drain sheet resistance |
| rdsw | $R_{dsw}$ | $\Omega$-$\mu$m | 100 | >=0 | Source-drain resistance per width |
| prwg | $P_{rwg}$ | V$^{-1}$ | 0 | - | Gate-bias effect on parasitic resistance |
| prwb | $P_{rwb}$ | V$^{-0.5}$ | 0 | - | Body-effect on parasitic resistance |
| wr | $W_r$ | - | 1.0 | - | Width dependence of Rds |

### SOI Specific

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| kb1 | $K_{b1}$ | - | 1.0 | - | Backgate coupling coefficient at strong inversion |
| kb3 | $K_{b3}$ | - | 1.0 | - | Backgate coupling coefficient at subthreshold |
| dvbd0 | $D_{vbd0}$ | - | 0 | - | 1st coefficient of short-channel effect on Vbs0t |
| dvbd1 | $D_{vbd1}$ | - | 0 | - | 2nd coefficient of short-channel effect on Vbs0t |
| vbsa | $V_{bsa}$ | V | 0 | - | Vbs0t offset voltage |
| delp | $\delta_p$ | V | 0.02 | - | Offset constant for limiting Vbseff to Phis |
| rbody | $R_{body}$ | $\Omega$ | 0 | >=0 | Intrinsic body contact sheet resistance |
| rbsh | $R_{bsh}$ | $\Omega$ | 0 | >=0 | Extrinsic body contact sheet resistance |
| adice0 | $A_{dice0}$ | - | 1.0 | - | DICE constant for bulk charge effect |
| abp | $A_{bp}$ | - | 1.0 | - | Gate bias coefficient for Xcsat calculation |
| mxc | $M_{xc}$ | - | -0.9 | - | Smoothing parameter for Xcsat calculation |

### Self-Heating

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rth0 | $R_{th0}$ | K/W | 0 | >=0 | Self-heating thermal resistance |
| cth0 | $C_{th0}$ | J/K | 0 | >=0 | Self-heating thermal capacitance |

### Impact Ionization / Vdsatii

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| aii | $A_{ii}$ | - | 0 | - | 1st Vdsatii parameter |
| bii | $B_{ii}$ | - | 0 | - | 2nd Vdsatii parameter |
| cii | $C_{ii}$ | - | 0 | - | 3rd Vdsatii parameter |
| dii | $D_{ii}$ | - | -1.0 | - | 4th Vdsatii parameter |
| alpha0 | $\alpha_0$ | - | 0 | - | Substrate current model parameter |
| alpha1 | $\alpha_1$ | - | 1.0 | - | Substrate current model parameter |
| beta0 | $\beta_0$ | - | 30 | - | Substrate current model parameter |

### GIDL (Gate-Induced Drain Leakage)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| agidl | $A_{gidl}$ | - | NaN | - | GIDL second parameter |
| bgidl | $B_{gidl}$ | - | NaN | - | GIDL third parameter |
| ngidl | $N_{gidl}$ | - | NaN | - | GIDL first parameter |

### Diode / BJT

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ndiode | $N_{diode}$ | - | 1.0 | - | Diode non-ideality factor |
| ntun | $N_{tun}$ | - | 10 | - | Reverse tunneling non-ideality factor |
| isbjt | $I_{sbjt}$ | A | 1.0e-6 | - | BJT emitter injection constant |
| isdif | $I_{sdif}$ | A | 0 | - | Body-to-S/D injection constant |
| isrec | $I_{srec}$ | A | 1.0e-5 | - | Recombination in depletion constant |
| istun | $I_{stun}$ | A | 0 | - | Tunneling diode constant |
| xbjt | $X_{bjt}$ | - | 2.0 | - | Temperature coefficient for Isbjt |
| xrec | $X_{rec}$ | - | 20 | - | Temperature coefficient for Isrec |
| xtun | $X_{tun}$ | - | 0 | - | Temperature coefficient for Istun |
| edl | $E_{dl}$ | m | 2.0e-6 | - | Electron diffusion length |
| kbjt1 | $K_{bjt1}$ | - | 0 | - | Vds dependency on BJT base width |

### Source/Drain Diffusion Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tt | $t_t$ | s | 1.0e-12 | - | Diffusion capacitance transit time coefficient |
| vsdth | $V_{sdth}$ | V | 0 | - | Source/drain diffusion threshold voltage |
| vsdfb | $V_{sdfb}$ | V | 0 | - | Source/drain diffusion flatband voltage |
| csdmin | $C_{sdmin}$ | F/m$^2$ | 1.005e-4 | - | Source/drain diffusion bottom minimum capacitance |
| asd | $A_{sd}$ | - | 0.3 | - | Source/drain diffusion smoothing parameter |
| pbswg | $P_{bswg}$ | V | 0.7 | - | S/D (gate side) sidewall junction capacitance built-in potential |
| mjswg | $M_{jswg}$ | - | 0.5 | - | S/D (gate side) sidewall junction capacitance grading coefficient |
| cjswg | $C_{jswg}$ | F/m | 1.0e-10 | - | S/D (gate side) sidewall junction capacitance per unit width |
| csdesw | $C_{sdesw}$ | F/m | 0 | - | Source/drain sidewall fringing constant |

### Overlap Capacitance / C-V Model

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cgso | $C_{gso}$ | F/m | 2.072e-10 | - | Gate-source overlap capacitance per width |
| cgdo | $C_{gdo}$ | F/m | 2.072e-10 | - | Gate-drain overlap capacitance per width |
| cgeo | $C_{geo}$ | F/m | 0 | - | Gate-substrate overlap capacitance |
| cgsl | $C_{gsl}$ | F/m | 0 | - | New C-V model parameter (gate-source overlap) |
| cgdl | $C_{gdl}$ | F/m | 0 | - | New C-V model parameter (gate-drain overlap) |
| ckappa | $C_{\kappa}$ | V | 0.6 | - | New C-V model parameter |
| cf | $C_f$ | F/m | 8.164e-11 | - | Fringe capacitance parameter |
| clc | $C_{lc}$ | m | 1.0e-8 | - | Vdsat parameter for C-V model |
| cle | $C_{le}$ | - | 0 | - | Vdsat parameter for C-V model |
| dwc | $\Delta W_c$ | m | 0 | - | Delta W for C-V model |
| dlc | $\Delta L_c$ | m | 0 | - | Delta L for C-V model |
| xpart | $X_{part}$ | - | 0 | {0,0.5,1} | Channel charge partitioning (0=0/100, 0.5=50/50, 1=40/60) |

### Noise

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| noia | $N_{oia}$ | - | 1.0e20 | - | Flicker noise parameter A |
| noib | $N_{oib}$ | - | 5.0e4 | - | Flicker noise parameter B |
| noic | $N_{oic}$ | - | -1.4e-12 | - | Flicker noise parameter C |
| em | $E_m$ | V/m | 4.1e7 | - | Flicker noise parameter |
| ef | $E_f$ | - | 1.0 | - | Flicker noise frequency exponent |
| af | $A_f$ | - | 1.0 | - | Flicker noise exponent |
| kf | $K_f$ | - | 0 | - | Flicker noise coefficient |
| noif | $N_{oif}$ | - | 1.0 | - | Floating body excess noise ideality factor |

### Length/Width Reduction

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| lint | $L_{int}$ | m | 0 | - | Length reduction parameter |
| ll | $L_l$ | - | 0 | - | Length reduction parameter |
| lln | $L_{ln}$ | - | 1.0 | - | Length reduction parameter |
| lw | $L_w$ | - | 0 | - | Length reduction parameter |
| lwn | $L_{wn}$ | - | 1.0 | - | Length reduction parameter |
| lwl | $L_{wl}$ | - | 0 | - | Length reduction parameter |
| wint | $W_{int}$ | m | 0 | - | Width reduction parameter |
| wl | $W_l$ | - | 0 | - | Width reduction parameter |
| wln | $W_{ln}$ | - | 1.0 | - | Width reduction parameter |
| ww | $W_w$ | - | 0 | - | Width reduction parameter |
| wwn | $W_{wn}$ | - | 1.0 | - | Width reduction parameter |
| wwl | $W_{wl}$ | - | 0 | - | Width reduction parameter |
| dwg | $\Delta W_g$ | m/V | 0 | - | Gate-bias width reduction parameter |
| dwb | $\Delta W_b$ | m/V$^{0.5}$ | 0 | - | Body-bias width reduction parameter |

### Length Dependence (l-prefix)

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| lnch | $L_{nch}$ | - | 0 | Length dependence of nch |
| lnsub | $L_{nsub}$ | - | 0 | Length dependence of nsub |
| lngate | $L_{ngate}$ | - | 0 | Length dependence of ngate |
| lvth0 | $L_{vth0}$ | - | 0 | Length dependence of vth0 |
| lk1 | $L_{k1}$ | - | 0 | Length dependence of k1 |
| lk2 | $L_{k2}$ | - | 0 | Length dependence of k2 |
| lk3 | $L_{k3}$ | - | 0 | Length dependence of k3 |
| lk3b | $L_{k3b}$ | - | 0 | Length dependence of k3b |
| lvbsa | $L_{vbsa}$ | - | 0 | Length dependence of vbsa |
| ldelp | $L_{delp}$ | - | 0 | Length dependence of delp |
| lkb1 | $L_{kb1}$ | - | 0 | Length dependence of kb1 |
| lkb3 | $L_{kb3}$ | - | 0 | Length dependence of kb3 |
| ldvbd0 | $L_{dvbd0}$ | - | 0 | Length dependence of dvbd0 |
| ldvbd1 | $L_{dvbd1}$ | - | 0 | Length dependence of dvbd1 |
| lw0 | $L_{w0}$ | - | 0 | Length dependence of w0 |
| lnlx | $L_{nlx}$ | - | 0 | Length dependence of nlx |
| ldvt0 | $L_{dvt0}$ | - | 0 | Length dependence of dvt0 |
| ldvt1 | $L_{dvt1}$ | - | 0 | Length dependence of dvt1 |
| ldvt2 | $L_{dvt2}$ | - | 0 | Length dependence of dvt2 |
| ldvt0w | $L_{dvt0w}$ | - | 0 | Length dependence of dvt0w |
| ldvt1w | $L_{dvt1w}$ | - | 0 | Length dependence of dvt1w |
| ldvt2w | $L_{dvt2w}$ | - | 0 | Length dependence of dvt2w |
| lu0 | $L_{u0}$ | - | 0 | Length dependence of u0 |
| lua | $L_{ua}$ | - | 0 | Length dependence of ua |
| lub | $L_{ub}$ | - | 0 | Length dependence of ub |
| luc | $L_{uc}$ | - | 0 | Length dependence of uc |
| lvsat | $L_{vsat}$ | - | 0 | Length dependence of vsat |
| la0 | $L_{a0}$ | - | 0 | Length dependence of a0 |
| lags | $L_{ags}$ | - | 0 | Length dependence of ags |
| lb0 | $L_{b0}$ | - | 0 | Length dependence of b0 |
| lb1 | $L_{b1}$ | - | 0 | Length dependence of b1 |
| lketa | $L_{keta}$ | - | 0 | Length dependence of keta |
| labp | $L_{abp}$ | - | 0 | Length dependence of abp |
| lmxc | $L_{mxc}$ | - | 0 | Length dependence of mxc |
| ladice0 | $L_{adice0}$ | - | 0 | Length dependence of adice0 |
| la1 | $L_{a1}$ | - | 0 | Length dependence of a1 |
| la2 | $L_{a2}$ | - | 0 | Length dependence of a2 |
| lrdsw | $L_{rdsw}$ | - | 0 | Length dependence of rdsw |
| lprwb | $L_{prwb}$ | - | 0 | Length dependence of prwb |
| lprwg | $L_{prwg}$ | - | 0 | Length dependence of prwg |
| lwr | $L_{wr}$ | - | 0 | Length dependence of wr |
| lnfactor | $L_{nfactor}$ | - | 0 | Length dependence of nfactor |
| ldwg | $L_{dwg}$ | - | 0 | Length dependence of dwg |
| ldwb | $L_{dwb}$ | - | 0 | Length dependence of dwb |
| lvoff | $L_{voff}$ | - | 0 | Length dependence of voff |
| leta0 | $L_{eta0}$ | - | 0 | Length dependence of eta0 |
| letab | $L_{etab}$ | - | 0 | Length dependence of etab |
| ldsub | $L_{dsub}$ | - | 0 | Length dependence of dsub |
| lcit | $L_{cit}$ | - | 0 | Length dependence of cit |
| lcdsc | $L_{cdsc}$ | - | 0 | Length dependence of cdsc |
| lcdscb | $L_{cdscb}$ | - | 0 | Length dependence of cdscb |
| lcdscd | $L_{cdscd}$ | - | 0 | Length dependence of cdscd |
| lpclm | $L_{pclm}$ | - | 0 | Length dependence of pclm |
| lpdiblc1 | $L_{pdiblc1}$ | - | 0 | Length dependence of pdiblc1 |
| lpdiblc2 | $L_{pdiblc2}$ | - | 0 | Length dependence of pdiblc2 |
| lpdiblcb | $L_{pdiblcb}$ | - | 0 | Length dependence of pdiblcb |
| ldrout | $L_{drout}$ | - | 0 | Length dependence of drout |
| lpvag | $L_{pvag}$ | - | 0 | Length dependence of pvag |
| ldelta | $L_{delta}$ | - | 0 | Length dependence of delta |
| laii | $L_{aii}$ | - | 0 | Length dependence of aii |
| lbii | $L_{bii}$ | - | 0 | Length dependence of bii |
| lcii | $L_{cii}$ | - | 0 | Length dependence of cii |
| ldii | $L_{dii}$ | - | 0 | Length dependence of dii |
| lalpha0 | $L_{\alpha 0}$ | - | 0 | Length dependence of alpha0 |
| lalpha1 | $L_{\alpha 1}$ | - | 0 | Length dependence of alpha1 |
| lbeta0 | $L_{\beta 0}$ | - | 0 | Length dependence of beta0 |
| lagidl | $L_{agidl}$ | - | 0 | Length dependence of agidl |
| lbgidl | $L_{bgidl}$ | - | 0 | Length dependence of bgidl |
| lngidl | $L_{ngidl}$ | - | 0 | Length dependence of ngidl |
| lntun | $L_{ntun}$ | - | 0 | Length dependence of ntun |
| lndiode | $L_{ndiode}$ | - | 0 | Length dependence of ndiode |
| lisbjt | $L_{isbjt}$ | - | 0 | Length dependence of isbjt |
| lisdif | $L_{isdif}$ | - | 0 | Length dependence of isdif |
| lisrec | $L_{isrec}$ | - | 0 | Length dependence of isrec |
| listun | $L_{istun}$ | - | 0 | Length dependence of istun |
| ledl | $L_{edl}$ | - | 0 | Length dependence of edl |
| lkbjt1 | $L_{kbjt1}$ | - | 0 | Length dependence of kbjt1 |
| lvsdfb | $L_{vsdfb}$ | - | 0 | Length dependence of vsdfb |
| lvsdth | $L_{vsdth}$ | - | 0 | Length dependence of vsdth |

### Width Dependence (w-prefix)

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| wnch | $W_{nch}$ | - | 0 | Width dependence of nch |
| wnsub | $W_{nsub}$ | - | 0 | Width dependence of nsub |
| wngate | $W_{ngate}$ | - | 0 | Width dependence of ngate |
| wvth0 | $W_{vth0}$ | - | 0 | Width dependence of vth0 |
| wk1 | $W_{k1}$ | - | 0 | Width dependence of k1 |
| wk2 | $W_{k2}$ | - | 0 | Width dependence of k2 |
| wk3 | $W_{k3}$ | - | 0 | Width dependence of k3 |
| wk3b | $W_{k3b}$ | - | 0 | Width dependence of k3b |
| wvbsa | $W_{vbsa}$ | - | 0 | Width dependence of vbsa |
| wdelp | $W_{delp}$ | - | 0 | Width dependence of delp |
| wkb1 | $W_{kb1}$ | - | 0 | Width dependence of kb1 |
| wkb3 | $W_{kb3}$ | - | 0 | Width dependence of kb3 |
| wdvbd0 | $W_{dvbd0}$ | - | 0 | Width dependence of dvbd0 |
| wdvbd1 | $W_{dvbd1}$ | - | 0 | Width dependence of dvbd1 |
| ww0 | $W_{w0}$ | - | 0 | Width dependence of w0 |
| wnlx | $W_{nlx}$ | - | 0 | Width dependence of nlx |
| wdvt0 | $W_{dvt0}$ | - | 0 | Width dependence of dvt0 |
| wdvt1 | $W_{dvt1}$ | - | 0 | Width dependence of dvt1 |
| wdvt2 | $W_{dvt2}$ | - | 0 | Width dependence of dvt2 |
| wdvt0w | $W_{dvt0w}$ | - | 0 | Width dependence of dvt0w |
| wdvt1w | $W_{dvt1w}$ | - | 0 | Width dependence of dvt1w |
| wdvt2w | $W_{dvt2w}$ | - | 0 | Width dependence of dvt2w |
| wu0 | $W_{u0}$ | - | 0 | Width dependence of u0 |
| wua | $W_{ua}$ | - | 0 | Width dependence of ua |
| wub | $W_{ub}$ | - | 0 | Width dependence of ub |
| wuc | $W_{uc}$ | - | 0 | Width dependence of uc |
| wvsat | $W_{vsat}$ | - | 0 | Width dependence of vsat |
| wa0 | $W_{a0}$ | - | 0 | Width dependence of a0 |
| wags | $W_{ags}$ | - | 0 | Width dependence of ags |
| wb0 | $W_{b0}$ | - | 0 | Width dependence of b0 |
| wb1 | $W_{b1}$ | - | 0 | Width dependence of b1 |
| wketa | $W_{keta}$ | - | 0 | Width dependence of keta |
| wabp | $W_{abp}$ | - | 0 | Width dependence of abp |
| wmxc | $W_{mxc}$ | - | 0 | Width dependence of mxc |
| wadice0 | $W_{adice0}$ | - | 0 | Width dependence of adice0 |
| wa1 | $W_{a1}$ | - | 0 | Width dependence of a1 |
| wa2 | $W_{a2}$ | - | 0 | Width dependence of a2 |
| wrdsw | $W_{rdsw}$ | - | 0 | Width dependence of rdsw |
| wprwb | $W_{prwb}$ | - | 0 | Width dependence of prwb |
| wprwg | $W_{prwg}$ | - | 0 | Width dependence of prwg |
| wwr | $W_{wr}$ | - | 0 | Width dependence of wr |
| wnfactor | $W_{nfactor}$ | - | 0 | Width dependence of nfactor |
| wdwg | $W_{dwg}$ | - | 0 | Width dependence of dwg |
| wdwb | $W_{dwb}$ | - | 0 | Width dependence of dwb |
| wvoff | $W_{voff}$ | - | 0 | Width dependence of voff |
| weta0 | $W_{eta0}$ | - | 0 | Width dependence of eta0 |
| wetab | $W_{etab}$ | - | 0 | Width dependence of etab |
| wdsub | $W_{dsub}$ | - | 0 | Width dependence of dsub |
| wcit | $W_{cit}$ | - | 0 | Width dependence of cit |
| wcdsc | $W_{cdsc}$ | - | 0 | Width dependence of cdsc |
| wcdscb | $W_{cdscb}$ | - | 0 | Width dependence of cdscb |
| wcdscd | $W_{cdscd}$ | - | 0 | Width dependence of cdscd |
| wpclm | $W_{pclm}$ | - | 0 | Width dependence of pclm |
| wpdiblc1 | $W_{pdiblc1}$ | - | 0 | Width dependence of pdiblc1 |
| wpdiblc2 | $W_{pdiblc2}$ | - | 0 | Width dependence of pdiblc2 |
| wpdiblcb | $W_{pdiblcb}$ | - | 0 | Width dependence of pdiblcb |
| wdrout | $W_{drout}$ | - | 0 | Width dependence of drout |
| wpvag | $W_{pvag}$ | - | 0 | Width dependence of pvag |
| wdelta | $W_{delta}$ | - | 0 | Width dependence of delta |
| waii | $W_{aii}$ | - | 0 | Width dependence of aii |
| wbii | $W_{bii}$ | - | 0 | Width dependence of bii |
| wcii | $W_{cii}$ | - | 0 | Width dependence of cii |
| wdii | $W_{dii}$ | - | 0 | Width dependence of dii |
| walpha0 | $W_{\alpha 0}$ | - | 0 | Width dependence of alpha0 |
| walpha1 | $W_{\alpha 1}$ | - | 0 | Width dependence of alpha1 |
| wbeta0 | $W_{\beta 0}$ | - | 0 | Width dependence of beta0 |
| wagidl | $W_{agidl}$ | - | 0 | Width dependence of agidl |
| wbgidl | $W_{bgidl}$ | - | 0 | Width dependence of bgidl |
| wngidl | $W_{ngidl}$ | - | 0 | Width dependence of ngidl |
| wntun | $W_{ntun}$ | - | 0 | Width dependence of ntun |
| wndiode | $W_{ndiode}$ | - | 0 | Width dependence of ndiode |
| wisbjt | $W_{isbjt}$ | - | 0 | Width dependence of isbjt |
| wisdif | $W_{isdif}$ | - | 0 | Width dependence of isdif |
| wisrec | $W_{isrec}$ | - | 0 | Width dependence of isrec |
| wistun | $W_{istun}$ | - | 0 | Width dependence of istun |
| wedl | $W_{edl}$ | - | 0 | Width dependence of edl |
| wkbjt1 | $W_{kbjt1}$ | - | 0 | Width dependence of kbjt1 |
| wvsdfb | $W_{vsdfb}$ | - | 0 | Width dependence of vsdfb |
| wvsdth | $W_{vsdth}$ | - | 0 | Width dependence of vsdth |

### Cross-Term Dependence (p-prefix)

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| pnch | $P_{nch}$ | - | 0 | Cross-term dependence of nch |
| pnsub | $P_{nsub}$ | - | 0 | Cross-term dependence of nsub |
| pngate | $P_{ngate}$ | - | 0 | Cross-term dependence of ngate |
| pvth0 | $P_{vth0}$ | - | 0 | Cross-term dependence of vth0 |
| pk1 | $P_{k1}$ | - | 0 | Cross-term dependence of k1 |
| pk2 | $P_{k2}$ | - | 0 | Cross-term dependence of k2 |
| pk3 | $P_{k3}$ | - | 0 | Cross-term dependence of k3 |
| pk3b | $P_{k3b}$ | - | 0 | Cross-term dependence of k3b |
| pvbsa | $P_{vbsa}$ | - | 0 | Cross-term dependence of vbsa |
| pdelp | $P_{delp}$ | - | 0 | Cross-term dependence of delp |
| pkb1 | $P_{kb1}$ | - | 0 | Cross-term dependence of kb1 |
| pkb3 | $P_{kb3}$ | - | 0 | Cross-term dependence of kb3 |
| pdvbd0 | $P_{dvbd0}$ | - | 0 | Cross-term dependence of dvbd0 |
| pdvbd1 | $P_{dvbd1}$ | - | 0 | Cross-term dependence of dvbd1 |
| pw0 | $P_{w0}$ | - | 0 | Cross-term dependence of w0 |
| pnlx | $P_{nlx}$ | - | 0 | Cross-term dependence of nlx |
| pdvt0 | $P_{dvt0}$ | - | 0 | Cross-term dependence of dvt0 |
| pdvt1 | $P_{dvt1}$ | - | 0 | Cross-term dependence of dvt1 |
| pdvt2 | $P_{dvt2}$ | - | 0 | Cross-term dependence of dvt2 |
| pdvt0w | $P_{dvt0w}$ | - | 0 | Cross-term dependence of dvt0w |
| pdvt1w | $P_{dvt1w}$ | - | 0 | Cross-term dependence of dvt1w |
| pdvt2w | $P_{dvt2w}$ | - | 0 | Cross-term dependence of dvt2w |
| pu0 | $P_{u0}$ | - | 0 | Cross-term dependence of u0 |
| pua | $P_{ua}$ | - | 0 | Cross-term dependence of ua |
| pub_ | $P_{ub}$ | - | 0 | Cross-term dependence of ub |
| puc | $P_{uc}$ | - | 0 | Cross-term dependence of uc |
| pvsat | $P_{vsat}$ | - | 0 | Cross-term dependence of vsat |
| pa0 | $P_{a0}$ | - | 0 | Cross-term dependence of a0 |
| pags | $P_{ags}$ | - | 0 | Cross-term dependence of ags |
| pb0 | $P_{b0}$ | - | 0 | Cross-term dependence of b0 |
| pb1 | $P_{b1}$ | - | 0 | Cross-term dependence of b1 |
| pketa | $P_{keta}$ | - | 0 | Cross-term dependence of keta |
| pabp | $P_{abp}$ | - | 0 | Cross-term dependence of abp |
| pmxc | $P_{mxc}$ | - | 0 | Cross-term dependence of mxc |
| padice0 | $P_{adice0}$ | - | 0 | Cross-term dependence of adice0 |
| pa1 | $P_{a1}$ | - | 0 | Cross-term dependence of a1 |
| pa2 | $P_{a2}$ | - | 0 | Cross-term dependence of a2 |
| prdsw | $P_{rdsw}$ | - | 0 | Cross-term dependence of rdsw |
| pprwb | $P_{prwb}$ | - | 0 | Cross-term dependence of prwb |
| pprwg | $P_{prwg}$ | - | 0 | Cross-term dependence of prwg |
| pwr | $P_{wr}$ | - | 0 | Cross-term dependence of wr |
| pnfactor | $P_{nfactor}$ | - | 0 | Cross-term dependence of nfactor |
| pdwg | $P_{dwg}$ | - | 0 | Cross-term dependence of dwg |
| pdwb | $P_{dwb}$ | - | 0 | Cross-term dependence of dwb |
| pvoff | $P_{voff}$ | - | 0 | Cross-term dependence of voff |
| peta0 | $P_{eta0}$ | - | 0 | Cross-term dependence of eta0 |
| petab | $P_{etab}$ | - | 0 | Cross-term dependence of etab |
| pdsub | $P_{dsub}$ | - | 0 | Cross-term dependence of dsub |
| pcit | $P_{cit}$ | - | 0 | Cross-term dependence of cit |
| pcdsc | $P_{cdsc}$ | - | 0 | Cross-term dependence of cdsc |
| pcdscb | $P_{cdscb}$ | - | 0 | Cross-term dependence of cdscb |
| pcdscd | $P_{cdscd}$ | - | 0 | Cross-term dependence of cdscd |
| ppclm | $P_{pclm}$ | - | 0 | Cross-term dependence of pclm |
| ppdiblc1 | $P_{pdiblc1}$ | - | 0 | Cross-term dependence of pdiblc1 |
| ppdiblc2 | $P_{pdiblc2}$ | - | 0 | Cross-term dependence of pdiblc2 |
| ppdiblcb | $P_{pdiblcb}$ | - | 0 | Cross-term dependence of pdiblcb |
| pdrout | $P_{drout}$ | - | 0 | Cross-term dependence of drout |
| ppvag | $P_{pvag}$ | - | 0 | Cross-term dependence of pvag |
| pdelta | $P_{delta}$ | - | 0 | Cross-term dependence of delta |
| paii | $P_{aii}$ | - | 0 | Cross-term dependence of aii |
| pbii | $P_{bii}$ | - | 0 | Cross-term dependence of bii |
| pcii | $P_{cii}$ | - | 0 | Cross-term dependence of cii |
| pdii | $P_{dii}$ | - | 0 | Cross-term dependence of dii |
| palpha0 | $P_{\alpha 0}$ | - | 0 | Cross-term dependence of alpha0 |
| palpha1 | $P_{\alpha 1}$ | - | 0 | Cross-term dependence of alpha1 |
| pbeta0 | $P_{\beta 0}$ | - | 0 | Cross-term dependence of beta0 |
| pagidl | $P_{agidl}$ | - | 0 | Cross-term dependence of agidl |
| pbgidl | $P_{bgidl}$ | - | 0 | Cross-term dependence of bgidl |
| pngidl | $P_{ngidl}$ | - | 0 | Cross-term dependence of ngidl |
| pntun | $P_{ntun}$ | - | 0 | Cross-term dependence of ntun |
| pndiode | $P_{ndiode}$ | - | 0 | Cross-term dependence of ndiode |
| pisbjt | $P_{isbjt}$ | - | 0 | Cross-term dependence of isbjt |
| pisdif | $P_{isdif}$ | - | 0 | Cross-term dependence of isdif |
| pisrec | $P_{isrec}$ | - | 0 | Cross-term dependence of isrec |
| pistun | $P_{istun}$ | - | 0 | Cross-term dependence of istun |
| pedl | $P_{edl}$ | - | 0 | Cross-term dependence of edl |
| pkbjt1 | $P_{kbjt1}$ | - | 0 | Cross-term dependence of kbjt1 |
| pvsdfb | $P_{vsdfb}$ | - | 0 | Cross-term dependence of vsdfb |
| pvsdth | $P_{vsdth}$ | - | 0 | Cross-term dependence of vsdth |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| w | $W$ | m | 1.0e-6 | >0 | Channel width |
| l | $L$ | m | 1.0e-6 | >0 | Channel length |
| temp | $T$ | K | 300.15 | >0 | Instance temperature |
| m | $M$ | - | 1.0 | >0 | Multiplicity factor |

## Equations

### Physical Constants

$$\epsilon_{Si} = 1.03594 \times 10^{-10} \text{ F/m}$$

$$\epsilon_{ox} = 3.453133 \times 10^{-11} \text{ F/m}$$

$$q = 1.60219 \times 10^{-19} \text{ C}$$

$$k_B / q = 8.617087 \times 10^{-5} \text{ V/K}$$

$$E_{g,300} = 1.115 \text{ eV}$$

### Effective Geometry

$$L_{eff} = \max(L - 2 L_d,\; 1 \times 10^{-9})$$

$$W_{eff} = \max(W,\; 1 \times 10^{-9})$$

C-V effective dimensions:

$$L_{eff,CV} = L_{eff} - 2 \Delta L_c$$

$$W_{eff,CV} = W_{eff} - 2 \Delta W_c$$

### Gate Oxide Capacitance

$$C_{ox} = \frac{\epsilon_{ox}}{t_{ox}}$$

### Parasitic Source/Drain Resistance

$$G_{ds,ext} = \begin{cases} \frac{1}{\max(R_{sh} \cdot 0.5,\; 10^{-6})} & R_{sh} > 0 \\ 10^{12} & R_{sh} = 0 \end{cases}$$

External drain-to-drain-prime current:

$$I_{d,dp} = (V_d - V_{dp}) \cdot G_{ds,ext}$$

External source-to-source-prime current:

$$I_{s,sp} = (V_s - V_{sp}) \cdot G_{ss,ext}$$

Internal source-drain resistance:

$$R_{ds0} = \begin{cases} \frac{R_{dsw} + P_{rt} \cdot \Delta T}{W_{eff} \times 10^6} & R_{dsw} > 0 \\ 0 & \text{otherwise} \end{cases}$$

### Temperature Dependence

$$\Delta T = T - T_{nom}$$

$$\text{TempRatio} = \frac{\Delta T}{T_{nom}}$$

Temperature-dependent mobility:

$$\mu_0(T) = \begin{cases} \mu_0 \cdot \exp\!\left(U_{te} \cdot \ln\!\left(\frac{T}{T_{nom}}\right)\right) & U_{te} \neq 0 \\ \mu_0 & U_{te} = 0 \end{cases}$$

Temperature-dependent saturation velocity:

$$v_{sat}(T) = v_{sat} - A_t \cdot \Delta T$$

Thermal voltage:

$$V_{tm} = \frac{k_B}{q} \cdot T$$

### Pre-computed Parameters

Surface potential:

$$\phi = 2 \frac{k_B}{q} T_{nom} \ln\!\left(\frac{N_{ch}}{1.45 \times 10^{10}}\right), \quad \phi = \max(\phi, 0.1) \; [\text{floor at } 0.7 \text{ if} \leq 0.1]$$

Depletion width at zero bias:

$$x_{dep0} = \sqrt{\frac{2 \epsilon_{Si}}{q \cdot N_{ch} \cdot 10^6}} \cdot \sqrt{\phi}$$

Built-in potential:

$$V_{bi} = \frac{k_B}{q} T_{nom} \ln\!\left(\frac{10^{20} \cdot N_{ch}}{(1.45 \times 10^{10})^2}\right)$$

Flat-band voltage:

$$V_{fbb} = \begin{cases} -\frac{k_B}{q} T_{nom} \ln\!\left(\frac{N_{ch}}{N_{sub}}\right) & N_{sub} > 0 \\ -0.9 & \text{otherwise} \end{cases}$$

Short-channel factor:

$$\text{factor1} = \sqrt{\frac{\epsilon_{Si}}{\epsilon_{ox}} \cdot t_{ox}}$$

$$K_1 = \begin{cases} K_1 & K_1 > 0 \\ \frac{2\sqrt{2 \epsilon_{Si} \cdot q \cdot N_{ch} \cdot 10^6 \cdot \phi}}{C_{ox}} & K_1 = 0 \end{cases}$$

### Operating Mode Selection (Smooth)

Smooth absolute value for mode detection:

$$|V_{ds}|_s = \sqrt{V_{ds}^2 + \varepsilon}, \quad \varepsilon = 10^{-12}$$

Smooth sign:

$$\text{sgn}(V_{ds}) = \frac{V_{ds}}{|V_{ds}|_s}$$

Forward/reverse weight factors:

$$w_{fwd} = \frac{1 + \text{sgn}(V_{ds})}{2}, \quad w_{rev} = 1 - w_{fwd}$$

Mode-adjusted branch voltages:

$$V_{DS} = w_{fwd} \cdot V_{ds} + w_{rev} \cdot (-V_{ds})$$

$$V_{GS} = w_{fwd} \cdot V_{gs} + w_{rev} \cdot (V_{gs} - V_{ds})$$

$$V_{ES} = w_{fwd} \cdot V_{es} + w_{rev} \cdot (V_{es} - V_{ds})$$

$$V_{PS} = w_{fwd} \cdot V_{ps} + w_{rev} \cdot (V_{ps} - V_{ds})$$

### SOI Fully-Depleted Body Voltage

Buried oxide and silicon film capacitances:

$$C_{box} = \frac{\epsilon_{ox}}{t_{box}}$$

$$C_{si} = \frac{2 \epsilon_{Si}}{t_{si}}$$

$$C_{si,eff} = \frac{\epsilon_{Si}}{t_{si}}$$

Characteristic length:

$$l_{itl} = \sqrt{\frac{\epsilon_{Si} \cdot t_{si} \cdot t_{ox}}{\epsilon_{ox}}}$$

Short-channel Vbs0t correction:

$$f_{dvbd1} = -D_{vbd1} \cdot \frac{L_{eff}}{l_{itl}}$$

$$D_{vbd,T} = D_{vbd0} \cdot \left(\exp\!\left(\min\!\left(\frac{f_{dvbd1}}{2}, 80\right)\right) + 2 \exp\!\left(\min(f_{dvbd1}, 80)\right)\right)$$

Silicon depletion charge per area:

$$Q_{si} = q \cdot N_{ch} \cdot 10^6 \cdot t_{si}$$

$$V_0 = V_{bi} - \phi$$

Body potential at zero back-gate bias:

$$V_{bs0t} = \phi - \frac{Q_{si}}{C_{si}} + V_{bsa} + D_{vbd,T} \cdot V_0$$

Back-gate coupling:

$$K_{b1,eff} = \frac{K_{b1}}{1 + C_{si,eff}/C_{box}}$$

$$V_{esfb} = V_{ES} - V_{fbb}$$

$$V_{bs0,raw} = V_{bs0t} - K_{b1,eff} \cdot (V_{bs0t} - V_{esfb})$$

Smooth upper-limiting of $V_{bs0}$ to $\phi - \delta_p$:

$$\delta_{vbs} = 0.005$$

$$T_2 = (\phi - \delta_p) - V_{bs0,raw} - \delta_{vbs}$$

$$T_3 = \sqrt{T_2^2 + 4 \delta_{vbs} (\phi - \delta_p)}$$

$$V_{bs0} = (\phi - \delta_p) - \frac{T_2 + T_3}{2}$$

Charge-sharing correction:

$$r_{csi} = \frac{q \cdot N_{ch} \cdot 10^6 \cdot t_{si}}{2 C_{si} \cdot \phi}$$

$$C_{si,eff,corr} = \begin{cases} C_{si}(1 - r_{csi}) & r_{csi} < 1 \\ 0.01 \cdot C_{si} & r_{csi} \geq 1 \end{cases}$$

$$Q_{si,eff} = Q_{si} \left(1 - \frac{q \cdot N_{ch} \cdot 10^6 \cdot t_{si}}{4 C_{si} \cdot \phi}\right)$$

$$V_{bs0,mos} = V_{bs0} \cdot \frac{C_{si,eff,corr}}{Q_{si,eff}} \cdot t_{si}$$

Gate-dependent feedback:

$$C_{dep0} = \sqrt{\frac{\epsilon_{Si} \cdot q \cdot N_{ch} \cdot 10^6}{2 \phi}}$$

$$N_{fb} = \frac{C_{ox}}{C_{ox} + C_{dep0}}$$

$$V_{bs0,eff} = V_{bs0} + N_{fb} \cdot (V_{GS} - V_{th0} - V_{bs0})$$

Final smooth limiting of $V_{bseff}$ to $\phi - \delta_p$:

$$T_2' = (\phi - \delta_p) - V_{bs0,eff} - \delta_{vbs}$$

$$T_3' = \sqrt{T_2'^2 + 4 \delta_{vbs}(\phi - \delta_p)}$$

$$V_{bseff} = (\phi - \delta_p) - \frac{T_2' + T_3'}{2}$$

### Threshold Voltage

Surface potential with body effect:

$$\phi_s = \phi - V_{bseff}$$

$$\sqrt{\phi_s} = \sqrt{|\phi_s| + 10^{-12}}$$

Depletion width:

$$x_{dep} = x_{dep0} \cdot \frac{\sqrt{\phi_s}}{\sqrt{\phi}}$$

Short channel effect ($\Theta_0$):

$$T_1 = 1 + Dvt_2 \cdot V_{bseff}$$

$$L_{t1} = \text{factor1} \cdot \sqrt{x_{dep}} \cdot T_1$$

$$\text{arg}_{dvt1} = \frac{-0.5 \cdot Dvt_1 \cdot L_{eff}}{|L_{t1}| + 10^{-20}}$$

$$\Theta_0 = e^{\min(\text{arg},80)} \cdot \left(1 + 2 e^{\min(\text{arg},80)}\right)$$

$$\Delta V_{th,SCE} = Dvt_0 \cdot \Theta_0 \cdot V_0$$

Narrow width effect:

$$T_{1w} = 1 + Dvt_{2w} \cdot V_{bseff}$$

$$L_{tw} = \text{factor1} \cdot \sqrt{x_{dep}} \cdot T_{1w}$$

$$\text{arg}_{dvtw} = \frac{-0.5 \cdot Dvt_{1w} \cdot W_{eff} \cdot L_{eff}}{|L_{tw}| + 10^{-20}}$$

$$T_{2w} = e^{\min(\text{arg}_{dvtw}, 80)} \cdot \left(1 + 2 e^{\min(\text{arg}_{dvtw}, 80)}\right)$$

$$\Delta V_{th,NW} = Dvt_{0w} \cdot T_{2w} \cdot V_0$$

Temperature shift:

$$\Delta V_{th,T} = K_1 \cdot \left(\sqrt{1 + N_{lx}/L_{eff}} - 1\right) \sqrt{\phi} + \left(K_{t1} + \frac{K_{t1l}}{L_{eff}}\right) \cdot \text{TempRatio}$$

DIBL:

$$\text{arg}_{dsub} = \frac{-D_{sub} \cdot L_{eff}}{|L_{t1}| + 10^{-20}}$$

$$\Theta_{0,DIBL} = e^{\min(\text{arg}_{dsub}, 80)} \cdot \left(1 + 2 e^{\min(\text{arg}_{dsub}, 80)}\right)$$

$$\eta = \eta_0 + \eta_b \cdot V_{bseff}$$

$$\text{DIBL}_{shift} = \eta \cdot V_{DS} \cdot \Theta_{0,DIBL}$$

Narrow width term:

$$\text{tmp}_{NW} = \frac{t_{ox} \cdot \phi}{W_{eff} + W_0}$$

Final threshold voltage:

$$V_{th} = V_{th0} + K_1(\sqrt{\phi_s} - \sqrt{\phi}) - K_2 \cdot V_{bseff} - \Delta V_{th,SCE} - \Delta V_{th,NW} + (K_3 + K_{3b} \cdot V_{bseff}) \cdot \text{tmp}_{NW} + \Delta V_{th,T} - \text{DIBL}_{shift}$$

### Subthreshold / Effective Gate Overdrive

Subthreshold ideality factor $n$:

$$T_{nfac} = \frac{N_{factor} \cdot \epsilon_{Si}}{x_{dep}}$$

$$C_{dsc,term} = C_{dsc} + C_{dscd} \cdot V_{DS} + C_{dscb} \cdot V_{bseff}$$

$$n = 1 + \frac{T_{nfac} + C_{dsc,term} \cdot \Theta_0 + C_{it}}{C_{ox}}$$

Effective gate overdrive $V_{gsteff}$ (smooth subthreshold-to-inversion):

$$\frac{C_{dep0}}{C_{ox}} = \frac{\sqrt{\epsilon_{Si} \cdot q \cdot N_{ch} \cdot 10^6 / (2\phi)}}{C_{ox}}$$

$$\text{ExpVgst} = \exp\!\left(\min\!\left(\frac{V_{GS} - V_{th} - V_{off}}{n \cdot V_{tm}}, 80\right)\right)$$

$$V_{gsteff} = \frac{n V_{tm} \cdot \ln(1 + \text{ExpVgst})}{1 + \frac{C_{dep0}/C_{ox}}{1 + \text{ExpVgst}}}$$

$$V_{gst2Vtm} = V_{gsteff} + 2 V_{tm}$$

### Bulk Charge Effect (Abulk)

$$T_{1,abulk} = \frac{K_1}{2\sqrt{\phi}}$$

$$\sqrt{x_j \cdot x_{dep}} = \sqrt{x_j} \cdot \sqrt{x_{dep}}$$

$$T_5 = \frac{L_{eff}}{L_{eff} + 2\sqrt{x_j \cdot x_{dep}}}$$

$$\text{tmp}_2 = A_0 \cdot T_5 + \frac{B_0}{W_{eff} + B_1}$$

$$A_{bulk,0} = T_{1,abulk} \cdot \text{tmp}_2$$

Gate-voltage modulation via $A_{gs}$:

$$T_8 = A_{gs} \cdot A_0 \cdot T_5^3$$

$$\frac{dA_{bulk}}{dV_g} = -T_{1,abulk} \cdot T_8$$

$$A_{bulk,pre} = A_{bulk,0} + \frac{dA_{bulk}}{dV_g} \cdot V_{gsteff}$$

Keta correction:

$$T_{0,keta} = \frac{1}{1 + K_{eta} \cdot V_{bseff}}$$

$$A_{bulk} = A_{bulk,pre} \cdot T_{0,keta} + 1$$

SOI DICE correction:

$$A_{beff} = A_{bulk} \cdot A_{dice0} + (1 - A_{dice0})$$

### Mobility

MobMod=1 (default):

$$T_0 = V_{gsteff} + V_{th} + V_{th}$$

$$T_3 = \frac{T_0}{t_{ox}}$$

$$T_5 = T_3 \cdot \left(U_a + U_c \cdot V_{bseff} + U_b \cdot T_3\right)$$

$$\mu_{eff} = \frac{\mu_0(T)}{1 + T_5}$$

### Saturation Voltage

$$W V_{cox} = W_{eff} \cdot v_{sat}(T) \cdot C_{ox}$$

$$E_{sat} = \frac{2 v_{sat}(T)}{\mu_{eff}}$$

$$E_{sat} L = E_{sat} \cdot L_{eff}$$

$$T_0 = 1 - A_1 \cdot (1 + W V_{cox} \cdot R_{ds} \cdot A_{beff})$$

$$V_{dsat} = \frac{E_{sat} L \cdot V_{gst2Vtm}}{|A_{beff} \cdot E_{sat} L + V_{gst2Vtm} \cdot T_0| + 10^{-20}}$$

### Effective Drain-Source Voltage (Smooth Clipping)

$$T_1 = V_{dsat} - V_{DS} - \delta$$

$$T_2 = \sqrt{T_1^2 + 4 \delta \cdot V_{dsat}}$$

$$V_{dseff} = V_{dsat} - \frac{T_1 + T_2}{2}$$

$$\Delta V_{ds} = V_{DS} - V_{dseff}$$

### Channel Length Modulation (VACLM)

$$l_{itl,clm} = \sqrt{3 \cdot t_{ox} \cdot x_{dep0}}$$

$$V_{ACLM} = \begin{cases} \frac{1}{P_{clm} \cdot A_{beff} \cdot l_{itl,clm}} \cdot L_{eff} \cdot \left(A_{beff} + \frac{V_{gsteff}}{E_{sat}L}\right) \cdot \Delta V_{ds} & P_{clm} > 0 \\ 5.835 \times 10^{14} & P_{clm} = 0 \end{cases}$$

### DIBL Output Resistance (VADIBL)

$$\text{arg}_{drout} = \frac{-D_{rout} \cdot L_{eff}}{|L_{t1}| + 10^{-20}}$$

$$\Theta_{rout} = P_{diblc1} \cdot e^{\min(\text{arg}_{drout},80)} \cdot (1 + 2 e^{\min(\text{arg}_{drout},80)}) + P_{diblc2}$$

$$T_8 = A_{beff} \cdot V_{dsat}$$

$$V_{A,pre} = \frac{V_{gst2Vtm} - \frac{V_{gst2Vtm} \cdot T_8}{V_{gst2Vtm} + T_8 + 10^{-20}}}{\Theta_{rout} + 10^{-20}}$$

Pdiblcb body-bias correction:

$$T_3 = \frac{1}{1 + P_{diblcb} \cdot V_{bseff}}$$

$$V_{ADIBL} = V_{A,pre} \cdot T_3$$

### Combined Early Voltage

Harmonic mean of CLM and DIBL:

$$V_{A,combined} = \frac{V_{ACLM} \cdot V_{ADIBL}}{V_{ACLM} + V_{ADIBL} + 10^{-20}}$$

PVAG effect:

$$T_0^{pvag} = 1 + \frac{P_{vag}}{E_{sat}L} \cdot V_{gsteff}$$

Velocity saturation Early voltage:

$$V_{ASAT} = \frac{E_{sat}L + V_{dsat} + 2 W V_{cox} R_{ds} V_{gsteff}}{\frac{2}{A_2} - 1 + W V_{cox} R_{ds} A_{beff} + 10^{-20}}$$

Total:

$$V_A = V_{ASAT} + T_0^{pvag} \cdot V_{A,combined}$$

### Drain Current

Transconductance parameter:

$$\beta = \mu_{eff} \cdot \frac{C_{ox} \cdot W_{eff}}{L_{eff}}$$

Gradual-channel terms:

$$f_{gche1} = V_{gsteff} \cdot \left(1 - \frac{A_{beff} \cdot V_{dseff}}{2 V_{gst2Vtm}}\right)$$

$$f_{gche2} = 1 + \frac{V_{dseff}}{E_{sat}L}$$

Channel conductance:

$$g_{che} = \frac{\beta \cdot f_{gche1}}{f_{gche2}}$$

Linear-region drain current (with Rds):

$$I_{dl} = \frac{g_{che} \cdot V_{dseff}}{1 + g_{che} \cdot R_{ds}}$$

Drain current with CLM:

$$I_{ds} = I_{dl} \cdot \left(1 + \frac{\Delta V_{ds}}{V_A + 10^{-20}}\right)$$

Mode and type adjustment:

$$I_{ds,actual} = I_{ds} \cdot \text{sgn}(V_{ds}) \cdot \text{type}$$

### GMIN Convergence Aid

$$I_{dp} \mathrel{+}= I_{ds,actual} + (V_{dp} - V_{sp}) \cdot G_{min}$$

$$I_{sp} \mathrel{-}= I_{ds,actual} + (V_{dp} - V_{sp}) \cdot G_{min}$$

where $G_{min} = 10^{-12}$ S.

### Body Contact Resistance

$$G_{body} = \frac{1}{R_{body}}, \quad R_{body} = \begin{cases} R_{body} & R_{body} > 0 \\ 10^{12} & R_{body} = 0 \end{cases}$$

$$I_{b \to p} = (V_b - V_p) \cdot G_{body}$$

### Self-Heating (shmod=1)

Thermal conductance:

$$G_{th} = \frac{1}{R_{th0}}$$

Power dissipation:

$$P = I_{ds,actual} \cdot V_{ds}$$

Thermal node current:

$$I_{th} = \frac{\Delta T_{emp}}{R_{th0}} - P$$

When shmod=0 or Rth0=0:

$$I_{th} = \Delta T_{emp} \cdot 10^3$$

### Substrate (Back-gate) Node

DC substrate current (simplified FD SOI):

$$I_e = (V_e - V_s) \cdot 10^{-12}$$

### External Body Sheet Resistance

When $R_{bsh} > 0$:

$$I_{p \to e} = \frac{V_p - V_e}{R_{bsh}}$$

### Multiplicity Scaling

All node currents scaled by $M$:

$$I_k \leftarrow I_k \cdot M \quad \forall k$$

---

## Charge Model (q function)

### C-V Effective Geometry

$$L_{eff,CV} = \max(L_{eff} - 2\Delta L_c,\; 10^{-8})$$

$$W_{eff,CV} = \max(W_{eff} - 2\Delta W_c,\; 10^{-8})$$

$$C_{ox} W L = C_{ox} \cdot W_{eff,CV} \cdot L_{eff,CV}$$

### Mode Selection (Charge)

Same smooth $|V_{ds}|$ and $\text{sgn}(V_{ds})$ formulation as the current function.

### Simplified Vth for Charge

$$V_{bseff} = 0 \quad \text{(FD SOI simplified)}$$

$$V_{th} = V_{th0} + K_1 (\sqrt{\phi} - \sqrt{\phi})$$

### Charge-Model Gate Overdrive

$$n = 1 + \frac{N_{factor} \cdot \epsilon_{Si}}{x_{dep0} \cdot C_{ox}}$$

$$V_{gsteff} = 2 n V_{tm} \cdot \ln\!\left(1 + \exp\!\left(\frac{V_{GS} - V_{th}}{2 n V_{tm}}\right)\right) + 10^{-4}$$

### AbulkCV

$$A_{bulk,CV} = \frac{K_1 \cdot A_0}{2\sqrt{\phi}} + 1$$

### Saturation Voltage for CV

$$V_{dsat,CV} = \frac{V_{gsteff}}{A_{bulk,CV}} + 10^{-5}$$

### Effective VdsCV (Smooth Clipping)

$$\delta_4 = 0.02$$

$$V_4 = V_{dsat,CV} - V_{DS} - \delta_4$$

$$V_{dseff,CV} = V_{dsat,CV} - \frac{V_4 + \sqrt{V_4^2 + 4\delta_4 \cdot V_{dsat,CV}}}{2}$$

### Inversion Charge

$$T_0 = A_{bulk,CV} \cdot V_{dseff,CV}$$

$$T_1 = 12 \cdot \left(V_{gsteff} - \frac{T_0}{2} + 10^{-20}\right)$$

$$T_3 = T_0 \cdot \frac{V_{dseff,CV}}{T_1}$$

$$Q_{inv} = C_{ox} W L \cdot \left(V_{gsteff} - \frac{V_{dseff,CV}}{2} + T_3\right)$$

### Charge Partitioning

$$Q_{src} = \begin{cases} -Q_{inv} & X_{part} < 0.25 \text{ (0/100)} \\ -0.5 \cdot Q_{inv} & 0.25 \leq X_{part} \leq 0.75 \text{ (50/50)} \\ -0.6 \cdot Q_{inv} & X_{part} > 0.75 \text{ (40/60)} \end{cases}$$

$$Q_{drn,inv} = -Q_{inv} - Q_{src}$$

### Flat-band Voltage for Accumulation Charge

$$V_{fb} = V_{th} - \phi - K_1 \sqrt{\phi_s}$$

### Accumulation Charge

$$\delta_3 = 0.02$$

$$V_3 = V_{fb} - V_{GS} + V_{bseff} - \delta_3$$

$$V_{fbeff} = V_{fb} - \frac{V_3 + \sqrt{V_3^2 + 4\delta_3 (|V_{fb}| + \delta_3)}}{2}$$

$$Q_{ac0} = -C_{ox} W L \cdot (V_{fbeff} - V_{fb})$$

### Depletion Charge

$$T_0 = \frac{K_1}{2}$$

$$T_3 = V_{GS} - V_{fbeff} - V_{bseff} - V_{gsteff}$$

$$T_1 = \sqrt{T_0^2 + |T_3|}$$

$$Q_{sub0} = C_{ox} W L \cdot K_1 \cdot (T_0 - T_1)$$

### Backgate Charge

$$C_{box} W L = K_{b3} \cdot C_{box} \cdot W_{eff,CV} \cdot L_{eff,CV}$$

$$Q_{e1} = -C_{box} W L \cdot (V_{bseff} - V_{ES} + V_{fbb})$$

### Gate Overlap Charges

Gate-drain overlap ($\delta_1 = 0.02$):

$$T_0 = V_{gd} + \delta_1$$

$$T_2 = \frac{T_0 - \sqrt{T_0^2 + 4\delta_1}}{2}$$

$$T_4 = \sqrt{\left|1 - \frac{4 T_2}{C_\kappa}\right| + 10^{-20}}$$

$$Q_{gdo} = (C_{gdo} + C_{gdl} W_{eff,CV}) \cdot V_{gd} - C_{gdl} W_{eff,CV} \cdot \left(T_2 + \frac{C_\kappa}{2}(T_4 - 1)\right)$$

Gate-source overlap:

$$T_0' = V_{gs} + \delta_1$$

$$T_2' = \frac{T_0' - \sqrt{T_0'^2 + 4\delta_1}}{2}$$

$$T_4' = \sqrt{\left|1 - \frac{4 T_2'}{C_\kappa}\right| + 10^{-20}}$$

$$Q_{gso} = (C_{gso} + C_{gsl} W_{eff,CV}) \cdot V_{gs} - C_{gsl} W_{eff,CV} \cdot \left(T_2' + \frac{C_\kappa}{2}(T_4' - 1)\right)$$

Gate-substrate overlap:

$$Q_{ge} = C_{geo} \cdot V_{ge}$$

### Total Charge Assembly

$$Q_{gate} = Q_{inv} + Q_{gdo} + Q_{gso} + Q_{ge}$$

$$Q_{drn} = Q_{drn,inv} - Q_{gdo}$$

$$Q_{src,total} = Q_{src} - Q_{gso}$$

$$Q_{body} = -(Q_{ac0} + Q_{sub0}) - Q_{e1}$$

$$Q_{sub} = Q_{e1}$$

Charge stamping with mode selection:

$$Q_{dp} = w_{fwd} \cdot Q_{drn} + w_{rev} \cdot Q_{src,total}$$

$$Q_{sp} = w_{fwd} \cdot Q_{src,total} + w_{rev} \cdot Q_{drn}$$

Substrate node:

$$Q_e = Q_{sub} - Q_{ge}$$

### Thermal Capacitance

When shmod=1 and $C_{th0} > 0$:

$$Q_{temp} = C_{th0} \cdot \Delta T_{emp}$$

---

## Newton Step Limiting

Per-iteration voltage clamps applied to proposed Newton updates:

| Node(s) | Limit |
|---------|-------|
| d, g, s, e, dp, sp, p | $\pm 3.0$ V per step |
| b (body) | $\pm 0.2$ V per step |
| temp | $\pm 5.0$ K per step |

$$V_k^{new} = \begin{cases} V_k^{old} + \Delta_{max} & \Delta V_k > \Delta_{max} \\ V_k^{old} - \Delta_{max} & \Delta V_k < -\Delta_{max} \\ V_k^{new} & \text{otherwise} \end{cases}$$
