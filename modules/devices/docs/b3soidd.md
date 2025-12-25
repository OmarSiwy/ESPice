# BSIM3SOI-DD v2.0 -- Parameter & Equation Reference

> Four-terminal Silicon-on-Insulator MOSFET with dynamic depletion (fully-depleted SOI body), including parasitic BJT, GIDL, impact ionization, junction diodes, and charge-based capacitance model.

## Model Topology

The device has four external terminals: **drain (d)**, **gate (g)**, **source (s)**, and **substrate/back-gate (e)**. The body is floating (SOI); the internal body potential is determined self-consistently through dynamic depletion equations coupling front-gate, back-gate, and body charge. Source/drain are automatically swapped when $V_{ds} < 0$ (symmetric device).

## Parameters

### Instance Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| w | $W$ | m | 1e-6 | Channel width |
| l | $L$ | m | 1e-6 | Channel length |
| temp | $T_{dev}$ | K | 300.15 | Device temperature |
| m | $M$ | -- | 1.0 | Parallel multiplier |

### Model Selectors and Version

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| dev_type | -- | -- | 1 | NMOS (+1) or PMOS (-1) |
| capmod | -- | -- | 2 | Capacitance model selector |
| mobmod | -- | -- | 1 | Mobility model selector |
| noimod | -- | -- | 1 | Noise model selector |
| paramchk | -- | -- | 0 | Model parameter checking selector |
| binunit | -- | -- | 1 | Bin unit selector |
| version | -- | -- | 2 | Model version |
| shmod | -- | -- | 0 | Self-heating mode selector |

### Threshold Voltage Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| vth0 | $V_{th0}$ | V | 0.7 | Threshold voltage |
| k1 | $K_1$ | $\text{V}^{1/2}$ | 0 | Bulk effect coefficient 1 |
| k2 | $K_2$ | -- | 0 | Bulk effect coefficient 2 |
| k3 | $K_3$ | -- | 0 | Narrow width effect coefficient |
| k3b | $K_{3b}$ | 1/V | 0 | Body effect coefficient of k3 |
| nch | $N_{ch}$ | cm$^{-3}$ | 1.7e17 | Channel doping concentration |
| nsub | $N_{sub}$ | cm$^{-3}$ | 6e16 | Substrate doping concentration |
| ngate | $N_{gate}$ | cm$^{-3}$ | 0 | Poly-gate doping concentration |
| gamma1 | $\gamma_1$ | $\text{V}^{1/2}$ | 0 | Vth body coefficient |
| gamma2 | $\gamma_2$ | $\text{V}^{1/2}$ | 0 | Vth body coefficient |
| vbx | $V_{bx}$ | V | 0 | Vth transition body voltage |
| vbm | $V_{bm}$ | V | -3 | Maximum body voltage |

### Short Channel Effect Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| dvt0 | $Dvt_0$ | -- | 2.2 | Short channel effect coeff. 0 |
| dvt1 | $Dvt_1$ | -- | 0.53 | Short channel effect coeff. 1 |
| dvt2 | $Dvt_2$ | 1/V | -0.032 | Short channel effect coeff. 2 |
| dvt0w | $Dvt_{0w}$ | -- | 0 | Narrow width coeff. 0 |
| dvt1w | $Dvt_{1w}$ | 1/m | 5.3e6 | Narrow width effect coeff. 1 |
| dvt2w | $Dvt_{2w}$ | 1/V | -0.032 | Narrow width effect coeff. 2 |
| nlx | $N_{lx}$ | m | 1.74e-7 | Lateral non-uniform doping effect |
| w0 | $W_0$ | m | 2.5e-6 | Narrow width effect parameter |
| xt | $X_t$ | m | 1.55e-7 | Doping depth |

### DIBL Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| eta0 | $\eta_0$ | -- | 0.08 | Subthreshold region DIBL coefficient |
| etab | $\eta_b$ | 1/V | -0.07 | Subthreshold region DIBL body-bias coefficient |
| dsub | $D_{sub}$ | -- | 0.56 | DIBL coefficient in subthreshold region |
| drout | $D_{rout}$ | -- | 0.56 | DIBL coefficient of output resistance |
| pdiblc1 | $pdiblc_1$ | -- | 0.39 | Drain-induced barrier lowering coefficient 1 |
| pdiblc2 | $pdiblc_2$ | -- | 0.0086 | Drain-induced barrier lowering coefficient 2 |
| pdiblcb | $pdiblc_b$ | 1/V | 0 | Body-effect on DIBL |
| pvag | $P_{vag}$ | -- | 0 | Gate dependence of output resistance parameter |

### Subthreshold Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| voff | $V_{off}$ | V | -0.08 | Threshold voltage offset |
| nfactor | $N_{factor}$ | -- | 1 | Subthreshold swing coefficient |
| cdsc | $C_{dsc}$ | F/m$^2$ | 2.4e-4 | Drain/source channel coupling capacitance |
| cdscb | $C_{dscb}$ | F/(V m$^2$) | 0 | Body-bias dependence of cdsc |
| cdscd | $C_{dscd}$ | F/(V m$^2$) | 0 | Drain-bias dependence of cdsc |
| cit | $C_{it}$ | F/m$^2$ | 0 | Interface state capacitance |

### Mobility Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| u0 | $\mu_0$ | m$^2$/(Vs) | 0.067 | Low-field mobility at Tnom |
| ua | $U_a$ | m/V | 2.25e-9 | Linear gate dependence of mobility |
| ub | $U_b$ | (m/V)$^2$ | 5.87e-19 | Quadratic gate dependence of mobility |
| uc | $U_c$ | 1/V | -4.65e-11 | Body-bias dependence of mobility |
| vsat | $v_{sat}$ | m/s | 80000 | Saturation velocity at tnom |
| a0 | $A_0$ | -- | 1 | Non-uniform depletion width effect coefficient |
| ags | $A_{gs}$ | 1/V | 0 | Gate bias coefficient of Abulk |
| a1 | $A_1$ | 1/V | 0 | Non-saturation effect coefficient |
| a2 | $A_2$ | -- | 1 | Non-saturation effect coefficient |
| b0 | $B_0$ | m | 0 | Abulk narrow width parameter |
| b1 | $B_1$ | m | 0 | Abulk narrow width parameter |
| keta | $K_{eta}$ | 1/V | -0.6 | Body-bias coefficient of non-uniform depletion width effect |

### Temperature Coefficients

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| tnom | $T_{nom}$ | K | 300.15 | Parameter measurement temperature |
| at | $A_T$ | m/s | 33000 | Temperature coefficient of vsat |
| kt1 | $K_{t1}$ | V | -0.11 | Temperature coefficient of Vth |
| kt1l | $K_{t1l}$ | V m | 0 | Temperature coefficient of Vth (length dep.) |
| kt2 | $K_{t2}$ | -- | 0.022 | Body-coefficient of kt1 |
| ute | $U_{te}$ | -- | -1.5 | Temperature coefficient of mobility |
| ua1 | $U_{a1}$ | m/V | 4.31e-9 | Temperature coefficient of ua |
| ub1 | $U_{b1}$ | (m/V)$^2$ | -7.61e-18 | Temperature coefficient of ub |
| uc1 | $U_{c1}$ | 1/V | -5.6e-11 | Temperature coefficient of uc |
| prt | $P_{rt}$ | $\Omega$ m | 0 | Temperature coefficient of parasitic resistance |

### Channel Length Modulation

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| pclm | $P_{clm}$ | -- | 1.3 | Channel length modulation coefficient |

### Parasitic Resistance

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| rsh | $R_{sh}$ | $\Omega$/sq | 0 | Source-drain sheet resistance |
| rdsw | $R_{dsw}$ | $\Omega$ $\mu$m | 100 | Source-drain resistance per width |
| prwg | $P_{rwg}$ | 1/V | 0 | Gate-bias effect on parasitic resistance |
| prwb | $P_{rwb}$ | 1/$\text{V}^{1/2}$ | 0 | Body-effect on parasitic resistance |
| wr | $W_r$ | -- | 1 | Width dependence of rds |

### Effective Length/Width Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| lint | $L_{int}$ | m | 0 | Length reduction parameter |
| ll | $L_l$ | -- | 0 | Length reduction parameter |
| lln | $L_{ln}$ | -- | 1 | Length reduction parameter |
| lw | $L_w$ | -- | 0 | Length reduction parameter |
| lwn | $L_{wn}$ | -- | 1 | Length reduction parameter |
| lwl | $L_{wl}$ | -- | 0 | Length reduction parameter |
| wint | $W_{int}$ | m | 0 | Width reduction parameter |
| wl | $W_l$ | -- | 0 | Width reduction parameter |
| wln | $W_{ln}$ | -- | 1 | Width reduction parameter |
| ww | $W_w$ | -- | 0 | Width reduction parameter |
| wwn | $W_{wn}$ | -- | 1 | Width reduction parameter |
| wwl | $W_{wl}$ | -- | 0 | Width reduction parameter |
| dwg | $D_{wg}$ | m/V | 0 | Width reduction parameter (gate bias) |
| dwb | $D_{wb}$ | m/$\text{V}^{1/2}$ | 0 | Width reduction parameter (body bias) |
| xj | $X_j$ | m | 0 | Junction depth |

### SOI-Specific Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| tox | $t_{ox}$ | m | 1e-8 | Gate oxide thickness |
| tbox | $t_{box}$ | m | 3e-7 | Back gate oxide thickness |
| tsi | $t_{si}$ | m | 1e-7 | Silicon-on-insulator body thickness |
| kb1 | $K_{b1}$ | -- | 1 | Backgate coupling coefficient at strong inversion |
| kb3 | $K_{b3}$ | -- | 1 | Backgate coupling coefficient at subthreshold |
| dvbd0 | $Dvbd_0$ | -- | 0 | 1st coefficient of short-channel effect on $V_{bs0t}$ |
| dvbd1 | $Dvbd_1$ | 1/m | 0 | 2nd coefficient of short-channel effect on $V_{bs0t}$ |
| vbsa | $V_{bsa}$ | V | 0 | $V_{bs0t}$ offset voltage |
| delp | $\delta_p$ | V | 0.02 | Offset constant for limiting $V_{bseff}$ to $\phi_s$ |
| rbody | $R_{body}$ | $\Omega$/sq | 0 | Intrinsic body contact sheet resistance |
| rbsh | $R_{bsh}$ | $\Omega$/sq | 0 | Extrinsic body contact sheet resistance |
| adice0 | $Adice_0$ | -- | 1 | DICE constant for bulk charge effect |
| abp | $A_{bp}$ | -- | 1 | Gate bias coefficient for $X_{csat}$ calculation |
| mxc | $M_{xc}$ | -- | -0.9 | Smoothing parameter for $X_{csat}$ calculation |

### Self-Heating Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| rth0 | $R_{th0}$ | K/W | 0 | Self-heating thermal resistance |
| cth0 | $C_{th0}$ | J/K | 0 | Self-heating thermal capacitance |

### Impact Ionization Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| alpha0 | $\alpha_0$ | m/V | 0 | Substrate current model parameter |
| alpha1 | $\alpha_1$ | 1/V | 1 | Substrate current model parameter |
| beta0 | $\beta_0$ | V | 30 | Substrate current model parameter |
| aii | $A_{ii}$ | -- | 0 | 1st $V_{dsatii}$ parameter |
| bii | $B_{ii}$ | -- | 0 | 2nd $V_{dsatii}$ parameter |
| cii | $C_{ii}$ | -- | 0 | 3rd $V_{dsatii}$ parameter |
| dii | $D_{ii}$ | -- | -1 | 4th $V_{dsatii}$ parameter |

### GIDL Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| agidl | $A_{GIDL}$ | A/V | 0 | GIDL second parameter |
| bgidl | $B_{GIDL}$ | V/m | 0 | GIDL third parameter |
| ngidl | $N_{GIDL}$ | V | 0 | GIDL first parameter |

### Diode and BJT Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| ndiode | $n_{diode}$ | -- | 1 | Diode non-ideality factor |
| ntun | $n_{tun}$ | -- | 10 | Reverse tunneling non-ideality factor |
| isbjt | $I_{sbjt}$ | A/m | 1e-6 | BJT emitter injection constant |
| isdif | $I_{sdif}$ | A/m | 0 | Body to S/D diffusion injection constant |
| isrec | $I_{srec}$ | A/m | 1e-5 | Recombination in depletion constant |
| istun | $I_{stun}$ | A/m | 0 | Tunneling diode constant |
| xbjt | $X_{bjt}$ | -- | 2 | Temperature coefficient for Isbjt |
| xrec | $X_{rec}$ | -- | 20 | Temperature coefficient for Isrec |
| xtun | $X_{tun}$ | -- | 0 | Temperature coefficient for Istun |
| edl | $E_{dl}$ | m | 2e-6 | Electron diffusion length |
| kbjt1 | $K_{bjt1}$ | -- | 0 | Vds dependency on BJT base width |
| tt | $\tau_t$ | s | 1e-12 | Diffusion capacitance transit time coefficient |

### Source/Drain Diffusion Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| vsdth | $V_{sdth}$ | V | 0 | S/D diffusion threshold voltage |
| vsdfb | $V_{sdfb}$ | V | 0 | S/D diffusion flatband voltage |
| csdmin | $C_{sdmin}$ | F/m | 1.005e-4 | S/D diffusion bottom minimum capacitance |
| asd | $A_{sd}$ | -- | 0.3 | S/D diffusion smoothing parameter |

### Junction Capacitance Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| pbswg | $\phi_{BSWG}$ | V | 0.7 | S/D (gate side) sidewall junction built-in potential |
| mjswg | $M_{JSWG}$ | -- | 0.5 | S/D (gate side) sidewall junction grading coefficient |
| cjswg | $C_{JSWG}$ | F/m | 1e-10 | S/D (gate side) sidewall junction capacitance per unit width |
| csdesw | $C_{SDESW}$ | F/m | 0 | S/D sidewall fringing constant |

### Overlap Capacitance Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| cgso | $C_{GSO}$ | F/m | 2.072e-10 | Gate-source overlap capacitance per width |
| cgdo | $C_{GDO}$ | F/m | 2.072e-10 | Gate-drain overlap capacitance per width |
| cgeo | $C_{GEO}$ | F/m | 0 | Gate-substrate overlap capacitance |
| xpart | $X_{part}$ | -- | 0 | Channel charge partitioning |
| delta | $\delta$ | V | 0.01 | Effective Vds parameter |

### C-V Model Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| cgsl | $C_{GSL}$ | F/m | 0 | New C-V model parameter |
| cgdl | $C_{GDL}$ | F/m | 0 | New C-V model parameter |
| ckappa | $C_{\kappa}$ | F/m | 0.6 | New C-V model parameter |
| cf | $C_f$ | F/m | 8.164e-11 | Fringe capacitance parameter |
| clc | $C_{lc}$ | m | 1e-8 | Vdsat parameter for C-V model |
| cle | $C_{le}$ | -- | 0 | Vdsat parameter for C-V model |
| dwc | $\Delta W_c$ | m | 0 | Delta W for C-V model |
| dlc | $\Delta L_c$ | m | 0 | Delta L for C-V model |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Description |
|-----------|--------|------|---------|-------------|
| noia | $N_{OIA}$ | -- | 1e20 | Flicker noise parameter |
| noib | $N_{OIB}$ | -- | 50000 | Flicker noise parameter |
| noic | $N_{OIC}$ | -- | -1.4e-12 | Flicker noise parameter |
| em | $E_m$ | V/m | 4.1e7 | Flicker noise parameter |
| ef | $E_f$ | -- | 1 | Flicker noise frequency exponent |
| af | $A_f$ | -- | 1 | Flicker noise exponent |
| kf | $K_f$ | -- | 0 | Flicker noise coefficient |
| noif | $N_{OIF}$ | -- | 1 | Floating body excess noise ideality factor |

### Length Dependence Parameters (prefix: l)

All default to 0 except where noted. Applied as: $P_{eff} = P + lP / L_{eff} + wP / W_{eff} + pP / (L_{eff} \cdot W_{eff})$.

| Parameter | Default | Description |
|-----------|---------|-------------|
| lnch | 0 | Length dependence of nch |
| lnsub | 0 | Length dependence of nsub |
| lngate | 0 | Length dependence of ngate |
| lvth0 | 0 | Length dependence of vth0 |
| lk1 | 0 | Length dependence of k1 |
| lk2 | 0 | Length dependence of k2 |
| lk3 | 0 | Length dependence of k3 |
| lk3b | 0 | Length dependence of k3b |
| lvbsa | 0 | Length dependence of vbsa |
| ldelp | 0 | Length dependence of delp |
| lkb1 | 0 | Length dependence of kb1 |
| lkb3 | 1 | Length dependence of kb3 |
| ldvbd0 | 0 | Length dependence of dvbd0 |
| ldvbd1 | 0 | Length dependence of dvbd1 |
| lw0 | 0 | Length dependence of w0 |
| lnlx | 0 | Length dependence of nlx |
| ldvt0 | 0 | Length dependence of dvt0 |
| ldvt1 | 0 | Length dependence of dvt1 |
| ldvt2 | 0 | Length dependence of dvt2 |
| ldvt0w | 0 | Length dependence of dvt0w |
| ldvt1w | 0 | Length dependence of dvt1w |
| ldvt2w | 0 | Length dependence of dvt2w |
| lu0 | 0 | Length dependence of u0 |
| lua | 0 | Length dependence of ua |
| lub | 0 | Length dependence of ub |
| luc | 0 | Length dependence of uc |
| lvsat | 0 | Length dependence of vsat |
| la0 | 0 | Length dependence of a0 |
| lags | 0 | Length dependence of ags |
| lb0 | 0 | Length dependence of b0 |
| lb1 | 0 | Length dependence of b1 |
| lketa | 0 | Length dependence of keta |
| labp | 0 | Length dependence of abp |
| lmxc | 0 | Length dependence of mxc |
| ladice0 | 0 | Length dependence of adice0 |
| la1 | 0 | Length dependence of a1 |
| la2 | 0 | Length dependence of a2 |
| lrdsw | 0 | Length dependence of rdsw |
| lprwb | 0 | Length dependence of prwb |
| lprwg | 0 | Length dependence of prwg |
| lwr | 0 | Length dependence of wr |
| lnfactor | 0 | Length dependence of nfactor |
| ldwg | 0 | Length dependence of dwg |
| ldwb | 0 | Length dependence of dwb |
| lvoff | 0 | Length dependence of voff |
| leta0 | 0 | Length dependence of eta0 |
| letab | 0 | Length dependence of etab |
| ldsub | 0 | Length dependence of dsub |
| lcit | 0 | Length dependence of cit |
| lcdsc | 0 | Length dependence of cdsc |
| lcdscb | 0 | Length dependence of cdscb |
| lcdscd | 0 | Length dependence of cdscd |
| lpclm | 0 | Length dependence of pclm |
| lpdiblc1 | 0 | Length dependence of pdiblc1 |
| lpdiblc2 | 0 | Length dependence of pdiblc2 |
| lpdiblcb | 0 | Length dependence of pdiblcb |
| ldrout | 0 | Length dependence of drout |
| lpvag | 0 | Length dependence of pvag |
| ldelta | 0 | Length dependence of delta |
| laii | 0 | Length dependence of aii |
| lbii | 0 | Length dependence of bii |
| lcii | 0 | Length dependence of cii |
| ldii | 0 | Length dependence of dii |
| lalpha0 | 0 | Length dependence of alpha0 |
| lalpha1 | 0 | Length dependence of alpha1 |
| lbeta0 | 0 | Length dependence of beta0 |
| lagidl | 0 | Length dependence of agidl |
| lbgidl | 0 | Length dependence of bgidl |
| lngidl | 0 | Length dependence of ngidl |
| lntun | 0 | Length dependence of ntun |
| lndiode | 0 | Length dependence of ndiode |
| lisbjt | 0 | Length dependence of isbjt |
| lisdif | 0 | Length dependence of isdif |
| lisrec | 0 | Length dependence of isrec |
| listun | 0 | Length dependence of istun |
| ledl | 0 | Length dependence of edl |
| lkbjt1 | 0 | Length dependence of kbjt1 |
| lvsdfb | 0 | Length dependence of vsdfb |
| lvsdth | 0 | Length dependence of vsdth |

### Width Dependence Parameters (prefix: w)

All default to 0 except where noted.

| Parameter | Default | Description |
|-----------|---------|-------------|
| wnch | 0 | Width dependence of nch |
| wnsub | 0 | Width dependence of nsub |
| wngate | 0 | Width dependence of ngate |
| wvth0 | 0 | Width dependence of vth0 |
| wk1 | 0 | Width dependence of k1 |
| wk2 | 0 | Width dependence of k2 |
| wk3 | 0 | Width dependence of k3 |
| wk3b | 0 | Width dependence of k3b |
| wvbsa | 0 | Width dependence of vbsa |
| wdelp | 0 | Width dependence of delp |
| wkb1 | 0 | Width dependence of kb1 |
| wkb3 | 1 | Width dependence of kb3 |
| wdvbd0 | 0 | Width dependence of dvbd0 |
| wdvbd1 | 0 | Width dependence of dvbd1 |
| ww0 | 0 | Width dependence of w0 |
| wnlx | 0 | Width dependence of nlx |
| wdvt0 | 0 | Width dependence of dvt0 |
| wdvt1 | 0 | Width dependence of dvt1 |
| wdvt2 | 0 | Width dependence of dvt2 |
| wdvt0w | 0 | Width dependence of dvt0w |
| wdvt1w | 0 | Width dependence of dvt1w |
| wdvt2w | 0 | Width dependence of dvt2w |
| wu0 | 0 | Width dependence of u0 |
| wua | 0 | Width dependence of ua |
| wub | 0 | Width dependence of ub |
| wuc | 0 | Width dependence of uc |
| wvsat | 0 | Width dependence of vsat |
| wa0 | 0 | Width dependence of a0 |
| wags | 0 | Width dependence of ags |
| wb0 | 0 | Width dependence of b0 |
| wb1 | 0 | Width dependence of b1 |
| wketa | 0 | Width dependence of keta |
| wabp | 0 | Width dependence of abp |
| wmxc | 0 | Width dependence of mxc |
| wadice0 | 0 | Width dependence of adice0 |
| wa1 | 0 | Width dependence of a1 |
| wa2 | 0 | Width dependence of a2 |
| wrdsw | 0 | Width dependence of rdsw |
| wprwb | 0 | Width dependence of prwb |
| wprwg | 0 | Width dependence of prwg |
| wwr | 0 | Width dependence of wr |
| wnfactor | 0 | Width dependence of nfactor |
| wdwg | 0 | Width dependence of dwg |
| wdwb | 0 | Width dependence of dwb |
| wvoff | 0 | Width dependence of voff |
| weta0 | 0 | Width dependence of eta0 |
| wetab | 0 | Width dependence of etab |
| wdsub | 0 | Width dependence of dsub |
| wcit | 0 | Width dependence of cit |
| wcdsc | 0 | Width dependence of cdsc |
| wcdscb | 0 | Width dependence of cdscb |
| wcdscd | 0 | Width dependence of cdscd |
| wpclm | 0 | Width dependence of pclm |
| wpdiblc1 | 0 | Width dependence of pdiblc1 |
| wpdiblc2 | 0 | Width dependence of pdiblc2 |
| wpdiblcb | 0 | Width dependence of pdiblcb |
| wdrout | 0 | Width dependence of drout |
| wpvag | 0 | Width dependence of pvag |
| wdelta | 0 | Width dependence of delta |
| waii | 0 | Width dependence of aii |
| wbii | 0 | Width dependence of bii |
| wcii | 0 | Width dependence of cii |
| wdii | 0 | Width dependence of dii |
| walpha0 | 0 | Width dependence of alpha0 |
| walpha1 | 0 | Width dependence of alpha1 |
| wbeta0 | 0 | Width dependence of beta0 |
| wagidl | 0 | Width dependence of agidl |
| wbgidl | 0 | Width dependence of bgidl |
| wngidl | 0 | Width dependence of ngidl |
| wntun | 0 | Width dependence of ntun |
| wndiode | 0 | Width dependence of ndiode |
| wisbjt | 0 | Width dependence of isbjt |
| wisdif | 0 | Width dependence of isdif |
| wisrec | 0 | Width dependence of isrec |
| wistun | 0 | Width dependence of istun |
| wedl | 0 | Width dependence of edl |
| wkbjt1 | 0 | Width dependence of kbjt1 |
| wvsdfb | 0 | Width dependence of vsdfb |
| wvsdth | 0 | Width dependence of vsdth |

### Cross-term Dependence Parameters (prefix: p)

All default to 0 except where noted.

| Parameter | Default | Description |
|-----------|---------|-------------|
| pnch | 0 | Cross-term dependence of nch |
| pnsub | 0 | Cross-term dependence of nsub |
| pngate | 0 | Cross-term dependence of ngate |
| pvth0 | 0 | Cross-term dependence of vth0 |
| pk1 | 0 | Cross-term dependence of k1 |
| pk2 | 0 | Cross-term dependence of k2 |
| pk3 | 0 | Cross-term dependence of k3 |
| pk3b | 0 | Cross-term dependence of k3b |
| pvbsa | 0 | Cross-term dependence of vbsa |
| pdelp | 0 | Cross-term dependence of delp |
| pkb1 | 0 | Cross-term dependence of kb1 |
| pkb3 | 1 | Cross-term dependence of kb3 |
| pdvbd0 | 0 | Cross-term dependence of dvbd0 |
| pdvbd1 | 0 | Cross-term dependence of dvbd1 |
| pw0 | 0 | Cross-term dependence of w0 |
| pnlx | 0 | Cross-term dependence of nlx |
| pdvt0 | 0 | Cross-term dependence of dvt0 |
| pdvt1 | 0 | Cross-term dependence of dvt1 |
| pdvt2 | 0 | Cross-term dependence of dvt2 |
| pdvt0w | 0 | Cross-term dependence of dvt0w |
| pdvt1w | 0 | Cross-term dependence of dvt1w |
| pdvt2w | 0 | Cross-term dependence of dvt2w |
| pu0 | 0 | Cross-term dependence of u0 |
| pua | 0 | Cross-term dependence of ua |
| pub_ | 0 | Cross-term dependence of ub |
| puc | 0 | Cross-term dependence of uc |
| pvsat | 0 | Cross-term dependence of vsat |
| pa0 | 0 | Cross-term dependence of a0 |
| pags | 0 | Cross-term dependence of ags |
| pb0 | 0 | Cross-term dependence of b0 |
| pb1 | 0 | Cross-term dependence of b1 |
| pketa | 0 | Cross-term dependence of keta |
| pabp | 0 | Cross-term dependence of abp |
| pmxc | 0 | Cross-term dependence of mxc |
| padice0 | 0 | Cross-term dependence of adice0 |
| pa1 | 0 | Cross-term dependence of a1 |
| pa2 | 0 | Cross-term dependence of a2 |
| prdsw | 0 | Cross-term dependence of rdsw |
| pprwb | 0 | Cross-term dependence of prwb |
| pprwg | 0 | Cross-term dependence of prwg |
| pwr | 0 | Cross-term dependence of wr |
| pnfactor | 0 | Cross-term dependence of nfactor |
| pdwg | 0 | Cross-term dependence of dwg |
| pdwb | 0 | Cross-term dependence of dwb |
| pvoff | 0 | Cross-term dependence of voff |
| peta0 | 0 | Cross-term dependence of eta0 |
| petab | 0 | Cross-term dependence of etab |
| pdsub | 0 | Cross-term dependence of dsub |
| pcit | 0 | Cross-term dependence of cit |
| pcdsc | 0 | Cross-term dependence of cdsc |
| pcdscb | 0 | Cross-term dependence of cdscb |
| pcdscd | 0 | Cross-term dependence of cdscd |
| ppclm | 0 | Cross-term dependence of pclm |
| ppdiblc1 | 0 | Cross-term dependence of pdiblc1 |
| ppdiblc2 | 0 | Cross-term dependence of pdiblc2 |
| ppdiblcb | 0 | Cross-term dependence of pdiblcb |
| pdrout | 0 | Cross-term dependence of drout |
| ppvag | 0 | Cross-term dependence of pvag |
| pdelta | 0 | Cross-term dependence of delta |
| paii | 0 | Cross-term dependence of aii |
| pbii | 0 | Cross-term dependence of bii |
| pcii | 0 | Cross-term dependence of cii |
| pdii | 0 | Cross-term dependence of dii |
| palpha0 | 0 | Cross-term dependence of alpha0 |
| palpha1 | 0 | Cross-term dependence of alpha1 |
| pbeta0 | 0 | Cross-term dependence of beta0 |
| pagidl | 0 | Cross-term dependence of agidl |
| pbgidl | 0 | Cross-term dependence of bgidl |
| pngidl | 0 | Cross-term dependence of ngidl |
| pntun | 0 | Cross-term dependence of ntun |
| pndiode | 0 | Cross-term dependence of ndiode |
| pisbjt | 0 | Cross-term dependence of isbjt |
| pisdif | 0 | Cross-term dependence of isdif |
| pisrec | 0 | Cross-term dependence of isrec |
| pistun | 0 | Cross-term dependence of istun |
| pedl | 0 | Cross-term dependence of edl |
| pkbjt1 | 0 | Cross-term dependence of kbjt1 |
| pvsdfb | 0 | Cross-term dependence of vsdfb |
| pvsdth | 0 | Cross-term dependence of vsdth |

## Equations

### Physical Constants

$$\epsilon_{Si} = 1.03594 \times 10^{-10} \text{ F/m}$$

$$\epsilon_{ox} = 3.453133 \times 10^{-11} \text{ F/m}$$

$$q = 1.60219 \times 10^{-19} \text{ C}$$

$$k_B/q = 8.617087 \times 10^{-5} \text{ V/K}$$

$$G_{min} = 1.0 \times 10^{-12} \text{ S}$$

### Effective Geometry

$$L_{eff} = \max(L - 2 \cdot L_{int},\; 1 \times 10^{-8})$$

$$W_{eff} = \max(W - 2 \cdot W_{int},\; 1 \times 10^{-8})$$

Effective length and width after reduction.

### Parameter Binning

$$P_{eff} = P + \frac{lP}{L_{eff}} + \frac{wP}{W_{eff}} + \frac{pP}{L_{eff} \cdot W_{eff}}$$

Applied to all binnable parameters (nch, vth0, k1, k2, k3, k3b, eta0, etab, dsub, u0, ua, ub, uc, voff, nfactor, vsat, a0, ags, keta, rdsw, pclm, pdiblc1, pdiblc2, dvt0, dvt1, cdsc, cdscd, cdscb, delta, pvag, alpha0, alpha1, beta0, agidl, bgidl, ngidl, ndiode, ntun, isbjt, isdif, isrec, istun, kb1, kb3, dvbd0, dvbd1, vbsa, delp, drout, a1, a2).

### Source/Drain Reversal

$$V_{ds,raw} = (V_d - V_s) \cdot \text{type}$$

$$\text{if } V_{ds,raw} \geq 0: \quad V_{DS} = V_{ds,raw}, \quad V_{GS} = V_{gs,raw}$$

$$\text{if } V_{ds,raw} < 0: \quad V_{DS} = -V_{ds,raw}, \quad V_{GS} = V_{gs,raw} - V_{ds,raw}$$

Smooth blendv-based swap; type = +1 (NMOS) or -1 (PMOS).

### Basic Semiconductor Quantities

$$\phi_s = 2 \frac{k_B}{q} T_{nom} \ln\!\left(\frac{\max(N_{ch},\, 10^{10})}{1.45 \times 10^{10}}\right)$$

Surface potential.

$$\sqrt{\phi_s} = \sqrt{\max(\phi_s, 0.1)}$$

$$X_{dep0} = \sqrt{\frac{2 \epsilon_{Si}}{q \cdot \max(N_{ch}, 10^{10}) \cdot 10^6}} \cdot \sqrt{\phi_s}$$

Zero-bias depletion width.

$$V_{bi} = \frac{k_B}{q} T_{nom} \ln\!\left(\frac{10^{20} \cdot \max(N_{ch}, 10^{10})}{(1.45 \times 10^{10})^2}\right)$$

Built-in potential.

### Flatband Voltage

$$V_{fbb} = \begin{cases} -\frac{k_B}{q} T_{nom} \ln\!\left(\frac{\max(N_{ch}, 10^{10})}{N_{sub}}\right) & N_{sub} > 0 \\ -\frac{k_B}{q} T_{nom} \ln\!\left(\frac{-\max(N_{ch}, 10^{10}) \cdot N_{sub}}{(1.45 \times 10^{10})^2}\right) & N_{sub} \leq 0 \end{cases}$$

### SOI Capacitances

$$C_{box} = \frac{\epsilon_{ox}}{t_{box}}$$

$$C_{si} = \frac{\epsilon_{Si}}{t_{si}}$$

$$q_{si} = q \cdot \max(N_{ch}, 10^{10}) \cdot 10^6 \cdot t_{si}$$

### Dynamic Depletion: $V_{bs0t}$ (Threshold Body Voltage)

$$l_{t1} = \sqrt{\frac{\epsilon_{Si}}{q \cdot \max(N_{ch}, 10^{10}) \cdot 10^6}}$$

$$T_1 = Dvbd_0 \left[ \exp\!\left(\min\!\left(\frac{-Dvbd_1 \cdot L_{eff}}{4 l_{t1}}, 80\right)\right) + 2 \exp\!\left(\min\!\left(\frac{-Dvbd_1 \cdot L_{eff}}{2 l_{t1}}, 80\right)\right) \right]$$

$$T_2 = T_1 (V_{bi} - \phi_s)$$

$$T_3 = \frac{q_{si}}{2 C_{si}}$$

$$V_{bs0t} = \phi_s - T_3 + V_{bsa} + T_2$$

Short-channel-corrected threshold body voltage.

### Back-Gate Coupling: $V_{bs0}$

$$T_0 = 1 + \frac{C_{si}}{C_{box}}$$

$$T_{kb} = \frac{K_{b1}}{T_0}$$

$$V_{esfb} = V_{ES} - V_{fbb}$$

$$T_6 = V_{bs0t} - T_{kb}(V_{bs0t} - V_{esfb})$$

Back-gate limited body voltage before smoothing.

### Smoothing $V_{bs0}$ to $\phi_s$

$$\delta_V = 0.005$$

$$T_2 = (\phi_s - \delta_p) - T_6 - \delta_V$$

$$T_3 = \sqrt{T_2^2 + 4 \delta_V}$$

$$V_{bs0} = (\phi_s - \delta_p) - \frac{T_2 + T_3}{2}$$

Smooth upper-bound limiting of body voltage.

### $V_{bs0mos}$ (MOSFET Body Bias)

$$\delta_{bsmos} = 0.005$$

$$T_1 = V_{bs0t} - V_{bs0} - \delta_{bsmos}$$

$$T_2 = \sqrt{T_1^2 + \delta_{bsmos}^2}$$

$$T_3 = \frac{T_1 + T_2}{2}$$

$$T_4 = T_3 \cdot \frac{C_{si}}{q_{si}}$$

$$V_{bs0mos} = V_{bs0} - \frac{T_3 \cdot T_4}{2}$$

### Fully-Depleted Threshold Voltage $V_{thfd}$

$$\Phi_{fd} = \phi_s - V_{bs0mos}$$

$$\sqrt{\Phi_{fd}} = \sqrt{\max(\Phi_{fd}, 10^{-20})}$$

$$X_{dep,fd} = X_{dep0} \cdot \frac{\sqrt{\Phi_{fd}}}{\sqrt{\phi_s}}$$

$$\Delta V_{th,NLX} = K_1 \left(\sqrt{1 + \frac{N_{lx}}{L_{eff}}} - 1\right) \sqrt{\phi_s}$$

Non-uniform lateral doping correction.

### Short Channel Effect (SCE)

$$l_{t,sce} = \sqrt{\frac{\epsilon_{Si} \cdot t_{ox}}{\epsilon_{ox} \cdot \max(N_{ch}, 10^{10}) \cdot 10^6 \cdot q}}$$

$$\text{arg} = \min\!\left(\frac{Dvt_1 \cdot L_{eff}}{2 l_{t,sce}},\; 80\right)$$

$$e_{dvt1} = \exp(-\text{arg})$$

$$\Delta V_{th,SCE} = Dvt_0 \cdot (1 - e_{dvt1})(1 + 2 e_{dvt1})(V_{bi} - \phi_s)$$

### Threshold Voltage

$$V_{thfd} = V_{th0} + K_3 \frac{t_{ox} \phi_s}{W_{eff} + W_0} + \Delta V_{th,NLX} - \Delta V_{th,SCE} + K_1(\sqrt{\Phi_{fd}} - \sqrt{\phi_s}) - K_2 \cdot V_{bs0mos}$$

### Effective $V_{bs0}$ with Gate-Voltage Coupling

$$\delta_{bs0eff} = 0.02$$

$$T_1 = V_{thfd} - V_{GS} - \delta_{bs0eff}$$

$$T_2 = \sqrt{T_1^2 + \delta_{bs0eff}^2}$$

$$V_{bs0teff} = V_{bs0t} - \frac{T_1 + T_2}{2}$$

### Subthreshold Feedback Factor $N_{fb}$

$$T_8 = \sqrt{\max(\phi_s, 0.01)}$$

$$T_5 = \sqrt{1 + \frac{4}{K_1^2}(\phi_s + K_1 T_8)}$$

$$T_{kb3} = K_{b3} \frac{C_{box}}{C_{ox}}$$

$$N_{fb} = \frac{1}{1 + T_{kb3} T_5}$$

### Effective Body Voltage $V_{bseff}$

$$V_{bs0eff} = V_{bs0} - N_{fb} \cdot \frac{T_1 + T_2}{2}$$

Uses the same $T_1, T_2$ from the gate-coupling section.

### Diode Body Voltage $V_{bsdio}$

$$\delta_{dio} = 0.01, \quad \text{off}_{dio} = 0.02$$

$$T_1 = V_{BS} - V_{bs0eff} - \text{off}_{dio} - \delta_{dio}$$

$$T_2 = \sqrt{T_1^2 + \delta_{dio}^2}$$

$$V_{bsdio} = V_{bs0eff} + \text{off}_{dio} + \frac{T_1 + T_2}{2}$$

### MOSFET Body Voltage $V_{bsmos}$

$$T_1 = V_{bs0teff} - V_{bsdio} - \delta_{bsmos}$$

$$T_2 = \sqrt{T_1^2 + \delta_{bsmos}^2}$$

$$T_3 = \frac{T_1 + T_2}{2}$$

$$V_{bsmos} = V_{bsdio} - \frac{T_3^2 \cdot C_{si}}{2 \cdot q_{si}}$$

### Final $V_{bseff}$ Clamped to $\phi_s$

$$\delta_{Vbseff} = 0.005$$

$$T_2 = (\phi_s - \delta_p) - V_{bsmos} - \delta_{Vbseff}$$

$$T_3 = \sqrt{T_2^2 + 4 \delta_{Vbseff} (\phi_s - \delta_p)}$$

$$V_{bseff} = (\phi_s - \delta_p) - \frac{T_2 + T_3}{2}$$

### Surface Potential and Depletion Width

$$\Phi_s = \phi_s - V_{bseff}$$

$$\sqrt{\Phi_s} = \sqrt{\max(\Phi_s, 10^{-20})}$$

$$X_{dep} = \frac{X_{dep0}}{\sqrt{\phi_s}} \sqrt{\Phi_s}$$

### Main Threshold Voltage

$$\text{DIBL}_{Sft} = \eta_0 V_{DS} + \eta_b V_{bseff}$$

$$V_{th} = V_{th0} + K_3 \frac{t_{ox} \phi_s}{W_{eff} + W_0} + \Delta V_{th,NLX} - \Delta V_{th,SCE} + K_1 (\sqrt{\Phi_s} - \sqrt{\phi_s}) - K_2 V_{bseff} - \text{DIBL}_{Sft}$$

### Subthreshold Swing Factor $n$

$$T_{2n} = \frac{N_{factor} \cdot \epsilon_{Si}}{X_{dep}}$$

$$T_{3n} = C_{dsc} + C_{dscd} V_{DS} + C_{dscb} V_{bseff}$$

$$T_{4n} = \frac{T_{2n} + T_{3n} + C_{it}}{C_{ox}}$$

$$n = 1 + \max(T_{4n},\; -0.5)$$

### Effective Gate Overdrive $V_{gsteff}$

$$V_{gst} = V_{GS} - V_{th} - V_{off}$$

$$V_{gstNVt} = \frac{V_{gst}}{2 n V_t}$$

$$V_{gsteff} = 2 n V_t \ln\!\left(1 + \exp\!\left(\text{clamp}(V_{gstNVt},\; -34,\; 34)\right)\right)$$

Smooth transition between weak and strong inversion. $V_t = (k_B/q) T_{nom}$.

$$V_{gst2Vtm} = V_{gsteff} + 2 V_t$$

### Source/Drain Resistance

$$R_{ds0} = \frac{R_{dsw}}{W_{eff} \times 10^6}$$

$$R_{ds} = R_{ds0}$$

### Bulk Charge Effect $A_{bulk}$

$$A_{bulk0,base} = \frac{K_1}{2\sqrt{\phi_s}} \left(A_0 + \frac{B_0}{W_{eff} + B_1}\right)$$

$$A_{bulk0} = \max(A_{bulk0,base},\; 0.01) + 1$$

### $K_{\eta}$ Correction

$$A_{bulk} = \frac{A_{bulk0}}{1 + K_{\eta} V_{bseff}} \quad (\text{denominator clamped} \geq 0.1)$$

$$A_{beff} = \max(A_{bulk},\; 0.01)$$

### Mobility (mobMod=1)

$$T_{0,mob} = V_{gsteff} + 2 V_{th}$$

$$T_{3,mob} = \frac{T_{0,mob}}{t_{ox}}$$

$$D = 1 + (U_a + U_c V_{bseff}) T_{3,mob} + U_b T_{3,mob}^2$$

$$\mu_{eff} = \frac{\mu_0}{\max(D,\; 0.01)}$$

### Saturation Velocity and $E_{sat}$

$$E_{sat} = \frac{2 v_{sat}}{\mu_{eff}}$$

$$E_{sat} L = E_{sat} \cdot L_{eff}$$

### Saturation Voltage $V_{dsat}$

$$V_{dsat} = \frac{E_{sat} L \cdot V_{gst2Vtm}}{A_{beff} \cdot E_{sat} L + V_{gst2Vtm}}$$

### Effective $V_{DS}$ (Smooth Saturation Clamp)

$$T_1 = V_{dsat} - V_{DS} - \delta$$

$$T_2 = \sqrt{T_1^2 + 4 \delta \cdot V_{dsat}}$$

$$V_{dseff} = V_{dsat} - \frac{T_1 + T_2}{2}$$

Smooth $\min(V_{DS}, V_{dsat})$.

$$\Delta V_{ds} = V_{DS} - V_{dseff}$$

### Channel Length Modulation (VACLM)

$$l_{itl} = \sqrt{\frac{\epsilon_{Si} \cdot t_{ox}}{\epsilon_{ox}}}$$

$$VA_{CLM} = \frac{l_{itl}}{P_{clm} \cdot L_{eff}} \cdot L_{eff}\!\left(A_{beff} + \frac{V_{gsteff}}{E_{sat} L}\right) \cdot \Delta V_{ds} + 10^{-20}$$

When $P_{clm} \leq 0$: $VA_{CLM} = 5.835 \times 10^{14}$ (effectively infinite).

### Drain-Induced Barrier Lowering (VADIBL)

$$l_{t,dibl} = \sqrt{\frac{\epsilon_{Si} \cdot t_{ox}}{\epsilon_{ox} \cdot \max(N_{ch}, 10^{10}) \cdot 10^6 \cdot q}}$$

$$\theta_{Rout} = pdiblc_1 \cdot \exp\!\left(-\min\!\left(\frac{D_{rout} L_{eff}}{2 l_{t,dibl}},\; 80\right)\right) + pdiblc_2$$

$$VA_{DIBL} = \frac{V_{gst2Vtm} - \frac{V_{gst2Vtm} \cdot A_{beff} \cdot V_{dsat}}{V_{gst2Vtm} + A_{beff} \cdot V_{dsat}}}{\theta_{Rout}} + 10^{-20}$$

When $\theta_{Rout} \leq 0$: $VA_{DIBL} = 5.835 \times 10^{14}$.

### $P_{vag}$ Gate-Bias Dependence

$$T_{pvag} = 1 + \frac{P_{vag} \cdot V_{gsteff}}{E_{sat} L}$$

### Early Voltage Assembly

$$VA_1 = \frac{VA_{CLM} \cdot VA_{DIBL}}{VA_{CLM} + VA_{DIBL}}$$

### Vasat (Saturation VA)

$$tmp_4 = 1 - \frac{A_{beff} \cdot V_{dsat}}{2 V_{gst2Vtm}}$$

$$T_{9,vasat} = W_{eff} v_{sat} C_{ox} R_{ds} \cdot V_{gsteff}$$

$$T_{0,vasat} = E_{sat} L + V_{dsat} + 2 T_{9,vasat} \cdot tmp_4$$

$$T_{1,vasat} = 1 + W_{eff} v_{sat} C_{ox} R_{ds} \cdot A_{beff}$$

$$V_{asat} = \frac{T_{0,vasat}}{T_{1,vasat}}$$

### Total Early Voltage

$$V_A = V_{asat} + T_{pvag} \cdot VA_1$$

### Drain Current

$$C_{oxWL} = \frac{C_{ox} W_{eff}}{L_{eff}}$$

$$\beta = \mu_{eff} \cdot C_{oxWL}$$

$$f_{gche1} = V_{gsteff} \left(1 - \frac{A_{beff} \cdot V_{dseff}}{2 V_{gst2Vtm}}\right)$$

$$f_{gche2} = 1 + \frac{V_{dseff}}{E_{sat} L}$$

$$g_{che} = \frac{\beta \cdot f_{gche1}}{f_{gche2}}$$

$$I_{dL} = g_{che} \cdot \frac{V_{dseff}}{1 + g_{che} R_{ds}}$$

Channel current before CLM.

$$I_{DS} = I_{dL} \left(1 + \frac{\Delta V_{ds}}{V_A}\right)$$

Final drain-source current with channel length modulation.

### Impact Ionization Current

$$\alpha_{ii} = \alpha_1 + \frac{\alpha_0}{L_{eff}}$$

$$I_{ii} = \alpha_{ii} \cdot \Delta V_{ds} \cdot \exp\!\left(\max\!\left(\frac{-\beta_0}{\max(\Delta V_{ds}, 10^{-20})},\; -34\right)\right) \cdot I_{DS}$$

Zero when $\alpha_{ii} \leq 0$ or $\beta_0 \leq 0$.

### GIDL Current

$$T_{1,gidl} = \max\!\left(\frac{V_{DS} - V_{GS} - N_{GIDL}}{3 t_{ox}},\; 0\right)$$

$$I_{GIDL} = W_{eff} A_{GIDL} \cdot T_{1,gidl} \cdot \exp\!\left(-\min\!\left(\frac{B_{GIDL}}{T_{1,gidl} + 10^{-20}},\; 34\right)\right)$$

Zero when $A_{GIDL} \leq 0$ or $B_{GIDL} \leq 0$.

### Junction Diode Currents

$$W_{Tsi} = W_{eff} \cdot t_{si}$$

$$NV_{tm1} = \frac{k_B T_{nom}}{q} \cdot n_{diode}$$

$$NV_{tm2} = \frac{k_B T_{nom}}{q} \cdot n_{tun}$$

#### Diffusion Current (source/drain)

$$I_{bs1} = W_{Tsi} I_{sdif} \left[\exp\!\left(\min\!\left(\frac{V_{BS}}{NV_{tm1}}, 30\right)\right) - 1\right]$$

$$I_{bd1} = W_{Tsi} I_{sdif} \left[\exp\!\left(\min\!\left(\frac{V_{BD}}{NV_{tm1}}, 30\right)\right) - 1\right]$$

#### Recombination Current

$$I_{bs2} = W_{Tsi} I_{srec} \left[\sqrt{\max\!\left(\exp\!\left(\min\!\left(\frac{V_{BS}}{NV_{tm1}}, 30\right)\right), 10^{-40}\right)} - 1\right]$$

$$I_{bd2} = W_{Tsi} I_{srec} \left[\sqrt{\max\!\left(\exp\!\left(\min\!\left(\frac{V_{BD}}{NV_{tm1}}, 30\right)\right), 10^{-40}\right)} - 1\right]$$

#### BJT Current

$$I_{bs3} = W_{Tsi} I_{sbjt} \left[\exp\!\left(\min\!\left(\frac{V_{BS}}{NV_{tm1}}, 30\right)\right) - 1\right]$$

$$I_{bd3} = W_{Tsi} I_{sbjt} \left[\exp\!\left(\min\!\left(\frac{V_{BD}}{NV_{tm1}}, 30\right)\right) - 1\right]$$

Zero when $I_{sbjt} \leq 0$.

#### Tunneling Current

$$I_{bs4} = W_{Tsi} I_{stun} \left[1 - \exp\!\left(\min\!\left(\frac{-V_{BS}}{NV_{tm2}}, 30\right)\right)\right]$$

$$I_{bd4} = W_{Tsi} I_{stun} \left[1 - \exp\!\left(\min\!\left(\frac{-V_{BD}}{NV_{tm2}}, 30\right)\right)\right]$$

Zero when $I_{stun} \leq 0$.

#### Total Junction Currents

$$I_{BS} = I_{bs1} + I_{bs2} + I_{bs3} + I_{bs4}$$

$$I_{BD} = I_{bd1} + I_{bd2} + I_{bd3} + I_{bd4}$$

### KCL Current Assembly

$$I_d = (I_{DS} - I_{BD} + I_{ii} + I_{GIDL}) \cdot \text{type} \cdot M$$

$$I_g = 0$$

$$I_s = (-I_{DS} - I_{BS}) \cdot \text{type} \cdot M$$

$$I_e = (I_{BS} + I_{BD} - I_{ii} - I_{GIDL}) \cdot \text{type} \cdot M$$

Source/drain currents are swapped when $V_{DS,raw} < 0$. GMIN conductance ($G_{min} \cdot V_{DS}$) is added to drain and subtracted from source for convergence.

### Convergence Aid: GMIN

$$I_{d,final} = I_d + G_{min} \cdot V_{ds,raw} \cdot \text{type}$$

$$I_{s,final} = I_s - G_{min} \cdot V_{ds,raw} \cdot \text{type}$$

## Charge Equations

### Gate Inversion Charge

$$V_{th,q}$$: Same threshold voltage equation as DC, using binned parameters.

$$V_{gsteff,q} = 2 n V_t \ln(1 + \exp(\text{clamp}(V_{gstNVt,q}, -34, 34)))$$

$$C_{oxWL} = C_{ox} \cdot W_{eff} \cdot L_{eff}$$

$$A_{bulkCV}$$: Same as $A_{bulk0}$ calculation using C-V binned parameters.

### CV Saturation Voltage

$$V_{dsatCV} = \frac{V_{gsteff}}{A_{bulkCV}} + 10^{-5}$$

### Smooth $V_{dseff,CV}$

$$\Delta_4 = 0.02$$

$$V_4 = V_{dsatCV} - V_{DS} - \Delta_4$$

$$T_0 = \sqrt{V_4^2 + 4 \Delta_4 V_{dsatCV}}$$

$$V_{dseff,CV} = V_{dsatCV} - \frac{V_4 + T_0}{2}$$

### Channel Charge (Ward-Dutton)

$$T_0 = A_{bulkCV} \cdot V_{dseff,CV}$$

$$T_1 = 12 \left(V_{gsteff} - \frac{T_0}{2} + 10^{-20}\right)$$

$$T_2 = \frac{V_{dseff,CV}}{T_1}$$

$$Q_{inv} = C_{oxWL} \left(V_{gsteff} - \frac{V_{dseff,CV}}{2} + T_0 T_2\right)$$

### Charge Partitioning (50/50)

$$Q_{src} = -\frac{Q_{inv}}{2}$$

$$Q_{drn,ch} = -Q_{inv} - Q_{src} = -\frac{Q_{inv}}{2}$$

### Flatband Voltage and Accumulation Charge

$$V_{fb} = V_{th} - \phi_s - K_1 \sqrt{\Phi_s}$$

$$V_3 = V_{fb} - V_{GS} + V_{bseff} - 0.02$$

$$T_0 = \sqrt{V_3^2 + 0.08(|V_{fb}| + 0.02)}$$

$$V_{fbeff} = V_{fb} - \frac{V_3 + T_0}{2}$$

$$Q_{ac0} = -C_{oxWL}(V_{fbeff} - V_{fb})$$

### Depletion Charge

$$T_3 = V_{GS} - V_{fbeff} - V_{bseff} - V_{gsteff}$$

$$T_1 = \sqrt{\left(\frac{K_1}{2}\right)^2 + \max(T_3, 0)}$$

$$Q_{sub0} = C_{oxWL} K_1 \left(\frac{K_1}{2} - T_1\right)$$

### Body Charge

$$Q_{bf} = Q_{ac0} + Q_{sub0}$$

### Junction Depletion Charges

$$C_{jsbs} = C_{JSWG} \cdot W_{eff} \cdot \frac{t_{si}}{10^{-7}}$$

#### Source Junction Charge

$$Q_{js} = C_{jsbs} \cdot V_{BS,jct} \cdot \left(1 + \frac{M_{JSWG} \cdot 0}{2 \phi_{BSWG}}\right)$$

Simplified for floating body ($V_{BS} \approx 0$).

#### Drain Junction Charge

$$V_{BD,jct} = V_{BS,jct} - V_{DS}$$

For $M_{JSWG} = 0.5$:

$$Q_{jd} = \frac{C_{jsbs} \phi_{BSWG}}{1 - M_{JSWG}} \left[1 - \frac{\max\!\left(1 - \frac{V_{BD}}{\phi_{BSWG}}, 0.01\right)}{\sqrt{\max\!\left(1 - \frac{V_{BD}}{\phi_{BSWG}}, 0.01\right)}}\right]$$

General case:

$$Q_{jd} = \frac{C_{jsbs} \phi_{BSWG}}{1 - M_{JSWG}} \left[1 - \max\!\left(1 - \frac{V_{BD}}{\phi_{BSWG}}, 0.01\right) \cdot \exp\!\left(-M_{JSWG} \ln\!\left(\max\!\left(1 - \frac{V_{BD}}{\phi_{BSWG}}, 0.01\right)\right)\right)\right]$$

### Transit Time Diffusion Charge

$$Q_{js,total} = Q_{js} + \tau_t \cdot I_{bs1}$$

$$Q_{jd,total} = Q_{jd} + \tau_t \cdot I_{bd1}$$

Where $I_{bs1}, I_{bd1}$ are recomputed in the charge function using binned $n_{diode}$ and $I_{sdif}$.

### Overlap Charges

$$Q_{gs,ov} = C_{GSO} \cdot W_{eff} \cdot (V_G - V_S)$$

$$Q_{gd,ov} = C_{GDO} \cdot W_{eff} \cdot (V_G - V_D)$$

$$Q_{ge,ov} = C_{GEO} \cdot W_{eff} \cdot (V_G - V_E)$$

### Total Node Charges

Source/drain channel charges and junction charges are swapped with S/D reversal.

$$Q_G = (Q_{inv} - Q_{bf} + Q_{gs,ov} + Q_{gd,ov} + Q_{ge,ov}) \cdot M$$

$$Q_D = (Q_{drn,ch} - Q_{jd,total} - Q_{gd,ov}) \cdot M$$

$$Q_S = (Q_{src} - Q_{js,total} - Q_{gs,ov}) \cdot M$$

$$Q_E = (Q_{bf} + Q_{js,total} + Q_{jd,total} - Q_{ge,ov}) \cdot M$$

## Newton Limiting

### Absolute Voltage Limiting

$$|V_{node}^{(k+1)} - V_{node}^{(k)}| \leq 3 \text{ V} \quad \forall \text{ nodes } \{d, g, s, e\}$$

### Gate-Source Voltage Limiting

$$|V_{gs}^{(k+1)} - V_{gs}^{(k)}| \leq 0.5 \text{ V}$$

### Drain-Source Voltage Limiting

$$|V_{ds}^{(k+1)} - V_{ds}^{(k)}| \leq 3 \text{ V}$$

## Attempt (Continuation)

Identity mapping: `attempt` returns unmodified parameters for all $\lambda \in [0, 1]$.
