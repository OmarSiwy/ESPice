# BSIM3SOI-PD v2.0 -- Parameter & Equation Reference

> Berkeley BSIM3 Silicon-On-Insulator Partially-Depleted MOSFET model (4-terminal: D, G, S, E)

## Model Topology

The device has 4 external terminals: **D** (drain), **G** (gate), **S** (source), **E** (substrate/backgate) and 5 internal nodes: **DP** (drain-prime, after drain resistance), **SP** (source-prime, after source resistance), **B** (floating body), **TEMP** (self-heating temperature node), **P** (body contact node). External drain/source connect to internal DP/SP through sheet resistances; the floating body B connects to contact node P through body resistance (`rbody`). The TEMP node models self-heating via thermal resistance `rth0` and thermal capacitance `cth0`. PMOS is handled by negating terminal voltages (`type_ = -1`).

---

## Parameters

### Device Type & Model Selectors

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| type_ | -- | -- | 1 | {-1, 1} | Device polarity: 1 = NMOS, -1 = PMOS |
| capmod | -- | -- | 2 | {0,1,2,3} | Capacitance model selector |
| mobmod | -- | -- | 1 | {1,2,3} | Mobility model selector |
| noimod | -- | -- | 1 | {1,2} | Noise model selector |
| paramchk | -- | -- | 0 | {0,1} | Model parameter checking selector |
| binunit | -- | -- | 1 | {1,2} | Bin unit selector |
| shmod | -- | -- | 0 | {0,1} | Self-heating mode selector |
| ddmod | -- | -- | 0 | {0,1} | Dynamic depletion mode selector |
| igmod | -- | -- | 0 | {0,1} | Gate current model selector |
| version | -- | -- | 2.0 | -- | Model version |

### Geometry & Process

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tox | $t_{ox}$ | m | 1.0e-8 | >0 | Gate oxide thickness |
| dtoxcv | $\Delta t_{ox,CV}$ | m | 0.0 | -- | Delta oxide thickness for CapMod3 |
| tbox | $t_{box}$ | m | 3.0e-7 | >0 | Back gate (buried) oxide thickness |
| tsi | $t_{si}$ | m | 1.0e-7 | >0 | Silicon-on-insulator film thickness |
| xj | $X_j$ | m | NaN | >0 | Junction depth (defaults to Leff if NaN) |
| nsub | $N_{sub}$ | cm^-3 | 6.0e16 | -- | Substrate doping concentration |
| nch | $N_{ch}$ | cm^-3 | 1.7e17 | >0 | Channel doping concentration |
| ngate | $N_{gate}$ | cm^-3 | 0.0 | >=0 | Poly-gate doping concentration |
| xt | $X_t$ | m | 1.55e-7 | >0 | Doping depth |
| tnom | $T_{nom}$ | K | 300.15 | >0 | Parameter measurement temperature |
| toxqm | $t_{ox,qm}$ | m | 1.0e-8 | >0 | Effective oxide thickness (quantum) |
| toxref | $t_{ox,ref}$ | m | 2.5e-9 | >0 | Target oxide thickness for gate current |

### Threshold Voltage

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vth0 | $V_{th0}$ | V | 0.7 | -- | Threshold voltage at zero body bias |
| k1 | $K_1$ | V^0.5 | 0.0 | -- | First-order body effect coefficient |
| k1w1 | $K_{1w1}$ | -- | 0.0 | -- | First body effect width-dependent parameter |
| k1w2 | $K_{1w2}$ | m | 0.0 | -- | Second body effect width-dependent parameter |
| k2 | $K_2$ | -- | 0.0 | -- | Second-order body effect coefficient |
| k3 | $K_3$ | -- | 0.0 | -- | Narrow width effect coefficient |
| k3b | $K_{3b}$ | V^-1 | 0.0 | -- | Body-bias coefficient of k3 |
| gamma1 | $\gamma_1$ | V^0.5 | 0.0 | -- | Body coefficient for Vth |
| gamma2 | $\gamma_2$ | V^0.5 | 0.0 | -- | Body coefficient for Vth |
| vbx | $V_{bx}$ | V | 0.0 | -- | Vth transition body voltage |
| vbm | $V_{bm}$ | V | -3.0 | -- | Maximum body voltage |
| delvt | $\Delta V_t$ | V | 0.0 | -- | Threshold voltage adjust for CV |
| voff | $V_{off}$ | V | -0.08 | -- | Threshold voltage offset |
| nfactor | $n_{factor}$ | -- | 1.0 | -- | Subthreshold swing coefficient |
| cit | $C_{it}$ | F/m^2 | 0.0 | -- | Interface state capacitance |
| cdsc | $C_{dsc}$ | F/m^2 | 2.4e-4 | -- | Drain/source-channel coupling capacitance |
| cdscb | $C_{dscb}$ | F/(V*m^2) | 0.0 | -- | Body-bias dependence of cdsc |
| cdscd | $C_{dscd}$ | F/(V*m^2) | 0.0 | -- | Drain-bias dependence of cdsc |
| ketas | $\kappa_{etas}$ | -- | 0.0 | -- | Surface potential adjustment for bulk charge effect |

### Short-Channel & Narrow-Width Effects

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| dvt0 | $Dvt_0$ | -- | 2.2 | -- | Short-channel effect coefficient 0 |
| dvt1 | $Dvt_1$ | -- | 0.53 | -- | Short-channel effect coefficient 1 |
| dvt2 | $Dvt_2$ | V^-1 | -0.032 | -- | Short-channel effect coefficient 2 |
| dvt0w | $Dvt_{0w}$ | -- | 0.0 | -- | Narrow width coefficient 0 |
| dvt1w | $Dvt_{1w}$ | m^-1 | 5.3e6 | -- | Narrow width coefficient 1 |
| dvt2w | $Dvt_{2w}$ | V^-1 | -0.032 | -- | Narrow width coefficient 2 |
| nlx | $N_{lx}$ | m | 1.74e-7 | -- | Lateral non-uniform doping effect |
| w0 | $W_0$ | m | 2.5e-6 | -- | Narrow width effect parameter |
| eta0 | $\eta_0$ | -- | 0.08 | -- | Subthreshold region DIBL coefficient |
| etab | $\eta_b$ | V^-1 | -0.07 | -- | Body-bias dependence of eta0 |
| dsub | $D_{sub}$ | -- | 0.56 | -- | DIBL coefficient in subthreshold |
| drout | $D_{rout}$ | -- | 0.56 | -- | DIBL coefficient of output resistance |
| pdiblc1 | $pdiblc_1$ | -- | 0.39 | -- | DIBL output resistance coefficient 1 |
| pdiblc2 | $pdiblc_2$ | -- | 0.0086 | -- | DIBL output resistance coefficient 2 |
| pdiblcb | $pdiblcb$ | V^-1 | 0.0 | -- | Body-effect on DIBL output resistance |
| pclm | $pclm$ | -- | 1.3 | -- | Channel length modulation coefficient |
| pvag | $pvag$ | -- | 0.0 | -- | Gate dependence of output resistance |

### Mobility

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| u0 | $\mu_0$ | m^2/(V*s) | 0.067 | >0 | Low-field mobility at Tnom |
| ua | $U_a$ | m/V | 2.25e-9 | -- | Linear gate dependence of mobility |
| ub | $U_b$ | (m/V)^2 | 5.87e-19 | -- | Quadratic gate dependence of mobility |
| uc | $U_c$ | V^-1 | -4.65e-11 | -- | Body-bias dependence of mobility |
| vsat | $v_{sat}$ | m/s | 80000.0 | >0 | Saturation velocity at Tnom |
| at | $A_t$ | m/s | 33000.0 | -- | Temperature coefficient of vsat |
| a0 | $A_0$ | -- | 1.0 | -- | Non-uniform depletion width effect coefficient |
| ags | $A_{gs}$ | V^-1 | 0.0 | -- | Gate-bias coefficient of Abulk |
| a1 | $A_1$ | V^-1 | 0.0 | -- | Non-saturation effect coefficient |
| a2 | $A_2$ | -- | 1.0 | -- | Non-saturation effect coefficient (Lambda) |
| b0 | $B_0$ | m | 0.0 | -- | Abulk narrow width parameter |
| b1 | $B_1$ | m | 0.0 | -- | Abulk narrow width parameter |
| keta | $\kappa$ | V^-1 | -0.6 | -- | Body-bias coefficient of non-uniform depletion width |
| delta | $\delta$ | V | 0.01 | -- | Effective Vds parameter |

### Temperature Coefficients

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| kt1 | $K_{t1}$ | V | -0.11 | -- | Temperature coefficient of Vth |
| kt1l | $K_{t1l}$ | V*m | 0.0 | -- | Length dependence of kt1 |
| kt2 | $K_{t2}$ | -- | 0.022 | -- | Body-coefficient of kt1 |
| ute | $U_{te}$ | -- | -1.5 | -- | Temperature exponent of mobility |
| ua1 | $U_{a1}$ | m/V | 4.31e-9 | -- | Temperature coefficient of ua |
| ub1 | $U_{b1}$ | (m/V)^2 | -7.61e-18 | -- | Temperature coefficient of ub |
| uc1 | $U_{c1}$ | V^-1 | -5.6e-11 | -- | Temperature coefficient of uc |
| prt | $P_{rt}$ | Ohm*um^wr | 0.0 | -- | Temperature coefficient of parasitic resistance |
| tii | $T_{ii}$ | -- | 0.0 | -- | Temperature parameter for impact ionization |

### Parasitic Resistance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rsh | $R_{sh}$ | Ohm/sq | 0.0 | >=0 | Source-drain sheet resistance |
| rdsw | $R_{dsw}$ | Ohm*um^wr | 100.0 | >=0 | Source-drain resistance per width |
| prwg | $P_{rwg}$ | V^-1 | 0.0 | -- | Gate-bias effect on parasitic resistance |
| prwb | $P_{rwb}$ | V^-0.5 | 0.0 | -- | Body-effect on parasitic resistance |
| wr | $W_r$ | -- | 1.0 | -- | Width dependence exponent of rds |
| rbody | $R_{body}$ | Ohm | 0.0 | >=0 | Intrinsic body contact sheet resistance |
| rbsh | $R_{bsh}$ | Ohm/sq | 0.0 | >=0 | Extrinsic body contact sheet resistance |

### Self-Heating

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| rth0 | $R_{th0}$ | K/W | 0.0 | >=0 | Self-heating thermal resistance |
| cth0 | $C_{th0}$ | J/K | 0.0 | >=0 | Self-heating thermal capacitance |
| wth0 | $W_{th0}$ | m | 0.0 | >=0 | Minimum width for thermal resistance |

### SOI Body Currents -- BJT

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| isbjt | $I_{s,bjt}$ | A | 1.0e-6 | >=0 | BJT injection saturation current |
| nbjt | $n_{bjt}$ | -- | 1.0 | >=0 | Power coefficient of Leff for bipolar current |
| lbjt0 | $L_{bjt0}$ | m | 2.0e-7 | >=0 | Reference channel length for bipolar current |
| ln | $L_n$ | m | 2.0e-6 | >0 | Electron/hole diffusion length |
| vabjt | $V_{A,bjt}$ | V | 10.0 | >0 | Early voltage for bipolar current |
| aely | $A_{ely}$ | -- | 0.0 | -- | Channel length dependence of Early voltage |
| ahli | $A_{hli}$ | -- | 0.0 | -- | High level injection parameter |
| xbjt | $X_{bjt}$ | -- | 1.0 | -- | Temperature coefficient for Isbjt |
| fbjtii | $f_{bjtii}$ | -- | 0.0 | [0,1] | Fraction of bipolar current affecting impact ionization |

### SOI Body Currents -- Diffusion

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| isdif | $I_{s,dif}$ | A/m | 0.0 | >=0 | Body-source/drain diffusion saturation current |
| ndiode | $n_{diode}$ | -- | 1.0 | >0 | Diode non-ideality factor |
| xdif | $X_{dif}$ | -- | 1.0 | -- | Temperature coefficient for Isdif |
| ldif0 | $L_{dif0}$ | -- | 1.0 | -- | Channel-length dependency of diffusion capacitance |
| ndif | $n_{dif}$ | -- | -1.0 | -- | Power coefficient of Leff for diffusion capacitance |
| tt | $\tau_t$ | s | 1.0e-12 | >=0 | Diffusion capacitance transit time |

### SOI Body Currents -- Recombination

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| isrec | $I_{s,rec}$ | A | 1.0e-5 | >=0 | Recombination saturation current |
| nrecf0 | $n_{recf0}$ | -- | 2.0 | >0 | Recombination ideality factor (forward) |
| nrecr0 | $n_{recr0}$ | -- | 10.0 | >0 | Recombination ideality factor (reverse) |
| vrec0 | $V_{rec0}$ | V | 0.0 | >=0 | Voltage parameter for recombination |
| xrec | $X_{rec}$ | -- | 1.0 | -- | Temperature coefficient for Isrec |
| ntrecf | $n_{trecf}$ | -- | 0.0 | -- | Temperature coefficient for Nrecf |
| ntrecr | $n_{trecr}$ | -- | 0.0 | -- | Temperature coefficient for Nrecr |

### SOI Body Currents -- Tunneling

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| istun | $I_{s,tun}$ | A | 0.0 | >=0 | Reverse tunneling saturation current |
| ntun | $n_{tun}$ | -- | 10.0 | >0 | Reverse tunneling non-ideality factor |
| vtun0 | $V_{tun0}$ | V | 0.0 | >=0 | Voltage parameter for tunneling current |
| xtun | $X_{tun}$ | -- | 0.0 | -- | Temperature coefficient for Istun |

### GIDL (Gate-Induced Drain Leakage)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| agidl | $A_{gidl}$ | A/V | 0.0 | >=0 | GIDL coefficient |
| bgidl | $B_{gidl}$ | V | 0.0 | >=0 | GIDL exponential coefficient |
| ngidl | $N_{gidl}$ | V | 1.2 | -- | GIDL voltage offset |

### Impact Ionization

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| alpha0 | $\alpha_0$ | -- | 0.0 | >=0 | Substrate current model parameter |
| beta0 | $\beta_0$ | V^-2 | 0.0 | -- | First Vds-dependent II parameter |
| beta1 | $\beta_1$ | V^-1 | 0.0 | -- | Second Vds-dependent II parameter |
| beta2 | $\beta_2$ | V | 0.1 | >0 | Third Vds-dependent II parameter |
| vdsatii0 | $V_{dsatii0}$ | V | 0.9 | >0 | Drain saturation voltage at threshold for II |
| lii | $L_{ii}$ | V*m | 0.0 | -- | Channel length parameter for II |
| sii0 | $S_{ii0}$ | -- | 0.5 | -- | First Vgs-dependent II parameter |
| sii1 | $S_{ii1}$ | V^-1 | 0.1 | -- | Second Vgs-dependent II parameter |
| sii2 | $S_{ii2}$ | -- | 0.0 | -- | Third Vgs-dependent II parameter |
| siid | $S_{iid}$ | V^-1 | 0.0 | -- | Vds-dependent parameter of Vdsatii |
| esatii | $E_{satii}$ | V/m | 1.0e7 | >0 | Saturation electric field for II |

### Gate Current

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| ntox | $n_{tox}$ | -- | 1.0 | -- | Power term of gate current |
| ebg | $E_{bg}$ | eV | 1.2 | -- | Effective bandgap for gate current |
| vevb | $V_{evb}$ | V | 0.075 | -- | Vaux parameter for valence-band tunneling |
| alphagb1 | $\alpha_{gb1}$ | -- | 0.35 | -- | First Vox parameter for gate current (inversion) |
| betagb1 | $\beta_{gb1}$ | -- | 0.03 | -- | Second Vox parameter for gate current (inversion) |
| vgb1 | $V_{gb1}$ | -- | 300.0 | -- | Third Vox parameter for gate current (inversion) |
| vecb | $V_{ecb}$ | V | 0.026 | -- | Vaux for conduction-band electron tunneling |
| alphagb2 | $\alpha_{gb2}$ | -- | 0.43 | -- | First Vox parameter for gate current (accumulation) |
| betagb2 | $\beta_{gb2}$ | -- | 0.05 | -- | Second Vox parameter for gate current (accumulation) |
| vgb2 | $V_{gb2}$ | -- | 17.0 | -- | Third Vox parameter for gate current (accumulation) |
| voxh | $V_{oxh}$ | V | 5.0 | -- | Limit of Vox in gate current calculation |
| deltavox | $\Delta V_{ox}$ | V | 0.005 | -- | Smoothing parameter in Vox function |
| rhalo | $\rho_{halo}$ | cm^-3 | 1.0e15 | -- | Body halo sheet resistance |

### Overlap & Fringe Capacitances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cgso | $C_{gso}$ | F/m | 2.07188e-10 | >=0 | Gate-source overlap capacitance per width |
| cgdo | $C_{gdo}$ | F/m | 2.07188e-10 | >=0 | Gate-drain overlap capacitance per width |
| cgeo | $C_{geo}$ | F/m | 0.0 | >=0 | Gate-substrate overlap capacitance per length |
| cgsl | $C_{gsl}$ | F/m | 0.0 | >=0 | New C-V model parameter (source side) |
| cgdl | $C_{gdl}$ | F/m | 0.0 | >=0 | New C-V model parameter (drain side) |
| ckappa | $C_{\kappa}$ | F/m | 0.6 | -- | New C-V model parameter |
| cf | $C_f$ | F/m | 8.16367e-11 | >=0 | Fringe capacitance parameter |
| clc | $C_{lc}$ | m | 1.0e-8 | >=0 | Vdsat parameter for C-V model |
| cle | $C_{le}$ | -- | 0.0 | -- | Vdsat parameter for C-V model |
| xpart | $X_{part}$ | -- | 0.0 | [0,1] | Channel charge partitioning |

### Junction Capacitances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cjswg | $C_{jswg}$ | F/m | 1.0e-10 | >=0 | Gate-side sidewall junction cap per width |
| pbswg | $P_{bswg}$ | V | 0.7 | >0 | Gate-side sidewall junction built-in potential |
| mjswg | $M_{jswg}$ | -- | 0.5 | [0,1) | Gate-side sidewall junction grading coefficient |
| tcjswg | $tc_{jswg}$ | K^-1 | 0.0 | -- | Temperature coefficient of Cjswg |
| tpbswg | $tp_{bswg}$ | K^-1 | 0.0 | -- | Temperature coefficient of Pbswg |

### SOI Diffusion Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vsdfb | $V_{sdfb}$ | V | 0.0 | -- | S/D bottom diffusion cap flatband voltage |
| vsdth | $V_{sdth}$ | V | 0.0 | -- | S/D bottom diffusion cap threshold voltage |
| csdmin | $C_{sdmin}$ | F/m^2 | 1.00544e-4 | >=0 | S/D bottom diffusion minimum capacitance |
| asd | $A_{sd}$ | -- | 0.3 | -- | S/D bottom diffusion smoothing parameter |
| csdesw | $C_{sdesw}$ | F/m | 0.0 | >=0 | S/D sidewall fringing capacitance per length |

### Backgate Charge

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| kb1 | $K_{b1}$ | -- | 1.0 | -- | Scaling factor for backgate charge |
| dlbg | $\Delta L_{bg}$ | m | 0.0 | -- | Length offset for backgate charge |
| fbody | $f_{body}$ | -- | 1.0 | [0,1] | Scaling factor for body charge |

### C-V Model (CapMod=3)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| acde | $acde$ | -- | 1.0 | -- | Exponential coefficient for charge thickness |
| moin | $moin$ | -- | 15.0 | -- | Coefficient for gate-bias dependent surface potential |

### Noise

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| noia | $N_{oiA}$ | -- | 1.0e20 | -- | Flicker noise parameter A |
| noib | $N_{oiB}$ | -- | 50000.0 | -- | Flicker noise parameter B |
| noic | $N_{oiC}$ | -- | -1.4e-12 | -- | Flicker noise parameter C |
| em | $E_m$ | V/m | 4.1e7 | -- | Flicker noise parameter |
| ef | $E_f$ | -- | 1.0 | -- | Flicker noise frequency exponent |
| af | $A_f$ | -- | 1.0 | -- | Flicker noise exponent |
| kf | $K_f$ | -- | 0.0 | -- | Flicker noise coefficient |
| noif | $N_{oif}$ | -- | 1.0 | -- | Floating body excess noise ideality factor |

### Geometry Reduction (Length)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| lint | $L_{int}$ | m | 0.0 | -- | Length reduction parameter |
| ll | $L_l$ | -- | 0.0 | -- | Length reduction parameter |
| llc | $L_{lc}$ | -- | 0.0 | -- | Length reduction parameter for CV |
| lln | $L_{ln}$ | -- | 1.0 | -- | Length reduction parameter |
| lw | $L_w$ | -- | 0.0 | -- | Length reduction parameter |
| lwc | $L_{wc}$ | -- | 0.0 | -- | Length reduction parameter for CV |
| lwn | $L_{wn}$ | -- | 1.0 | -- | Length reduction parameter |
| lwl | $L_{wl}$ | -- | 0.0 | -- | Length reduction parameter |
| lwlc | $L_{wlc}$ | -- | 0.0 | -- | Length reduction parameter for CV |
| dlc | $\Delta L_c$ | m | 0.0 | -- | Delta L for C-V model |
| dlcb | $\Delta L_{cb}$ | m | 0.0 | -- | Length offset for body charge fitting |

### Geometry Reduction (Width)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| wint | $W_{int}$ | m | 0.0 | -- | Width reduction parameter |
| dwg | $\Delta W_g$ | m/V | 0.0 | -- | Width reduction parameter (gate bias) |
| dwb | $\Delta W_b$ | m/V^0.5 | 0.0 | -- | Width reduction parameter (body bias) |
| wl | $W_l$ | -- | 0.0 | -- | Width reduction parameter |
| wlc | $W_{lc}$ | -- | 0.0 | -- | Width reduction parameter for CV |
| wln | $W_{ln}$ | -- | 1.0 | -- | Width reduction parameter |
| ww | $W_w$ | -- | 0.0 | -- | Width reduction parameter |
| wwc | $W_{wc}$ | -- | 0.0 | -- | Width reduction parameter for CV |
| wwn | $W_{wn}$ | -- | 1.0 | -- | Width reduction parameter |
| wwl | $W_{wl}$ | -- | 0.0 | -- | Width reduction parameter |
| wwlc | $W_{wlc}$ | -- | 0.0 | -- | Width reduction parameter for CV |
| dwc | $\Delta W_c$ | m | 0.0 | -- | Delta W for C-V model |
| dwbc | $\Delta W_{bc}$ | m | 0.0 | -- | Width offset for body contact isolation |

### Length Dependence (L-prefix)

All default to 0.0. Applied as: $P_{eff} = P_0 + LP / L_{eff}$.

| Parameter | Description |
|-----------|-------------|
| lnch, lnsub, lngate | Length dep. of nch, nsub, ngate |
| lvth0 | Length dep. of vth0 |
| lk1, lk1w1, lk1w2, lk2, lk3, lk3b, lkb1 | Length dep. of body effect params |
| lw0, lnlx | Length dep. of narrow width params |
| ldvt0, ldvt1, ldvt2, ldvt0w, ldvt1w, ldvt2w | Length dep. of SCE/NWE params |
| lu0, lua, lub, luc, lvsat | Length dep. of mobility params |
| la0, lags, lb0, lb1, lketa, lketas | Length dep. of Abulk params |
| la1, la2 | Length dep. of non-saturation params |
| lrdsw, lprwb, lprwg, lwr | Length dep. of resistance params |
| lnfactor, ldwg, ldwb, lvoff | Length dep. of subthreshold params |
| leta0, letab, ldsub | Length dep. of DIBL params |
| lcit, lcdsc, lcdscb, lcdscd | Length dep. of capacitance params |
| lpclm, lpdiblc1, lpdiblc2, lpdiblcb, ldrout, lpvag | Length dep. of output resistance params |
| ldelta | Length dep. of delta |
| lalpha0 | Length dep. of alpha0 |
| lfbjtii, lbeta0, lbeta1, lbeta2, lvdsatii0, llii, lesatii | Length dep. of II params |
| lsii0, lsii1, lsii2, lsiid | Length dep. of II Vgs params |
| lagidl, lbgidl, lngidl | Length dep. of GIDL params |
| lntun, lndiode, lnrecf0, lnrecr0 | Length dep. of junction ideality |
| lisbjt, lisdif, lisrec, listun | Length dep. of saturation currents |
| lvrec0, lvtun0 | Length dep. of junction voltage params |
| lnbjt, llbjt0, lvabjt, laely, lahli | Length dep. of BJT params |
| lvsdfb, lvsdth | Length dep. of diffusion cap params |
| ldelvt, lacde, lmoin | Length dep. of CV params |

### Width Dependence (W-prefix)

All default to 0.0. Applied as: $P_{eff} = P_0 + WP / W_{eff}$.

Same set of suffixes as L-prefix above, with `w` prefix (wnch, wnsub, ..., wmoin).

### Cross-Term Dependence (P-prefix)

All default to 0.0. Applied as: $P_{eff} = P_0 + LP/L + WP/W + PP/(L \cdot W)$.

Same set of suffixes as L-prefix above, with `p` prefix (pnch, pnsub, ..., pmoin). Note: `pub_` in Zig maps to SPICE parameter `pub`.

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| w | $W$ | m | 1e-6 | >0 | Channel width |
| l | $L$ | m | 1e-6 | >0 | Channel length |
| temp | $T$ | K | 300.15 | >0 | Device temperature |
| m | $M$ | -- | 1.0 | >0 | Multiplier (parallel instances) |
| nrd | $N_{rd}$ | sq | 1.0 | >0 | Number of drain resistance squares |
| nrs | $N_{rs}$ | sq | 1.0 | >0 | Number of source resistance squares |

---

## Equations

### Physical Constants

$$\epsilon_{Si} = 1.03594 \times 10^{-10} \text{ F/m}$$

$$\epsilon_{ox} = 3.453133 \times 10^{-11} \text{ F/m}$$

$$q = 1.60219 \times 10^{-19} \text{ C}$$

$$k_B/q = 8.617087 \times 10^{-5} \text{ V/K}$$

### Effective Geometry

$$L_{eff} = \max(L - 2 \cdot L_{int},\; 1 \times 10^{-9})$$

$$W_{eff} = \max(W - 2 \cdot W_{int},\; 1 \times 10^{-9})$$

### External Resistance

$$G_{d,ext} = \begin{cases} \frac{W \cdot M}{R_{sh} \cdot N_{rd}} & R_{sh} > 0 \\ 10^3 & R_{sh} = 0 \end{cases}$$

$$G_{s,ext} = \begin{cases} \frac{W \cdot M}{R_{sh} \cdot N_{rs}} & R_{sh} > 0 \\ 10^3 & R_{sh} = 0 \end{cases}$$

$$I_{D \to DP} = (V_D - V_{DP}) \cdot G_{d,ext}$$

$$I_{S \to SP} = (V_S - V_{SP}) \cdot G_{s,ext}$$

### Terminal Voltages & Source-Drain Reversal

$$V_{gs} = (V_G - V_{SP}) \cdot \text{type}$$

$$V_{ds} = (V_{DP} - V_{SP}) \cdot \text{type}$$

$$V_{bs} = (V_B - V_{SP}) \cdot \text{type}$$

Smooth source-drain swap using smooth absolute value:

$$|V_{ds}|_{smooth} = \sqrt{V_{ds}^2 + 10^{-30}}$$

$$\text{mode} = \frac{V_{ds}}{|V_{ds}|_{smooth}}$$

$$w_{fwd} = \frac{1 + \text{mode}}{2}, \quad w_{rev} = \frac{1 - \text{mode}}{2}$$

$$v_{ds} = |V_{ds}|_{smooth}$$

$$v_{gs} = w_{fwd} \cdot V_{gs} + w_{rev} \cdot (V_{gs} - V_{ds})$$

$$v_{bs} = w_{fwd} \cdot V_{bs} + w_{rev} \cdot (V_{bs} - V_{ds})$$

$$V_{bd} = v_{bs} - v_{ds}$$

### Temperature

$$T_{dev} = T_{nom} + \Delta T \quad (\Delta T = x_{TEMP})$$

$$V_{tm} = \frac{k_B}{q} \cdot T_{dev}$$

$$\text{TempRatio} - 1 = \frac{\Delta T}{T_{nom}}$$

### Oxide Capacitance

$$C_{ox} = \frac{\epsilon_{ox}}{t_{ox}}$$

### Surface Potential and Depletion Width

$$\phi_s = 2 \frac{k_B}{q} T_{nom} \ln\!\left(\frac{N_{ch}}{1.45 \times 10^{10}}\right), \quad \phi_s \ge 0.1 \text{ (clamped to 0.6 if not)}$$

$$V_{bi} = \frac{k_B}{q} T_{nom} \ln\!\left(\frac{10^{20} \cdot N_{ch}}{(1.45 \times 10^{10})^2}\right)$$

$$V_0 = V_{bi} - \phi_s$$

$$X_{dep0} = \sqrt{\frac{2 \epsilon_{Si}}{q \cdot N_{ch} \cdot 10^6}} \cdot \sqrt{\phi_s}$$

### Vbseff -- Smooth Body-Bias Clamping

Three-stage smooth limiting of $v_{bs}$:

**Stage 1** -- Lower limit at -5 V:

$$T_0 = v_{bs} + 4.999$$

$$T_1 = \sqrt{T_0^2 + 0.02}$$

$$V_{bs,low} = -5 + \frac{T_0 + T_1}{2}$$

**Stage 2** -- Upper limit at 1.5 V:

$$T_0 = 1.5 - V_{bs,low} - 0.002$$

$$T_3 = \sqrt{T_0^2 + 0.012}$$

$$V_{bsh} = 1.5 - \frac{T_0 + T_3}{2}$$

**Stage 3** -- Upper limit at $0.95\phi_s$:

$$T_1 = 0.95\phi_s - V_{bsh} - 0.002$$

$$T_2 = \sqrt{T_1^2 + 0.0076\phi_s}$$

$$V_{bseff} = 0.95\phi_s - \frac{T_1 + T_2}{2}$$

### Depletion Width (Bias-Dependent)

$$\phi_{is} = \phi_s - V_{bseff}$$

$$\sqrt{\phi_{is}} = \sqrt{\phi_s - V_{bseff}}$$

$$X_{dep} = X_{dep0} \cdot \frac{\sqrt{\phi_{is}}}{\sqrt{\phi_s}}$$

### Threshold Voltage

**Short-channel effect (SCE):**

$$\text{factor1} = \sqrt{\frac{\epsilon_{Si}}{\epsilon_{ox}/t_{ox}}}$$

$$lt_1 = \text{factor1} \cdot \sqrt{X_{dep}} \cdot \max(1 + Dvt_2 \cdot V_{bseff},\; 0.2) + 10^{-20}$$

$$\Theta_0 = e^{-Dvt_1 \cdot L_{eff}/(2 \cdot lt_1)} \cdot \left(1 + 2 e^{-Dvt_1 \cdot L_{eff}/(2 \cdot lt_1)}\right)$$

Exponential argument clamped to $[-80, 80]$.

$$\Delta V_{th,SCE} = Dvt_0 \cdot \Theta_0 \cdot V_0$$

**Narrow-width effect (NWE):**

$$\text{tmp2} = \frac{t_{ox} \cdot \phi_s}{W_{eff} + W_0}$$

$$\Delta V_{th,NW} = Dvt_{0w} \cdot \Theta_{0w} \cdot V_0$$

where $\Theta_{0w} = e^{-Dvt_{1w} W_{eff} L_{eff}/(2 \cdot lt_w)} (1 + 2 e^{...})$ and $lt_w = \text{factor1} \cdot \sqrt{X_{dep0}}$.

**DIBL:**

$$\Theta_{0,vb0} = e^{-D_{sub} L_{eff}/(2 T_1)} (1 + 2 e^{-D_{sub} L_{eff}/(2 T_1)})$$

where $T_1 = \sqrt{(\epsilon_{Si}/\epsilon_{ox}) \cdot t_{ox} \cdot X_{dep0}}$.

$$\eta_{eff} = \max(\eta_0 + \eta_b \cdot V_{bseff},\; 10^{-4})$$

$$\text{DIBL}_{sft} = \eta_{eff} \cdot \Theta_{0,vb0} \cdot v_{ds}$$

**K1eff (width-dependent):**

$$K_{1,eff} = K_1 \left(1 + \frac{K_{1w1}}{W_{eff} + K_{1w2}}\right)$$

(denominator clamped: $\max(W_{eff} + K_{1w2}, 10^{-8})$)

**Temperature effect on Vth:**

$$\Delta V_{th,T} = K_{1,eff}(\sqrt{1 + N_{lx}/L_{eff}} - 1)\sqrt{\phi_s} + \left(K_{t1} + \frac{K_{t1l}}{L_{eff}} + K_{t2} V_{bseff}\right) \frac{\Delta T}{T_{nom}}$$

**Final Vth:**

$$V_{th} = V_{th0} + K_{1,eff}(\sqrt{\phi_{is}} - \sqrt{\phi_s}) - K_2 V_{bseff} - \Delta V_{th,SCE} - \Delta V_{th,NW} + (K_3 + K_{3b} V_{bseff}) \cdot \text{tmp2} + \Delta V_{th,T} - \text{DIBL}_{sft}$$

### Subthreshold Swing Factor

$$T_2 = \frac{n_{factor} \cdot \epsilon_{Si}}{X_{dep} + 10^{-20}}$$

$$T_3 = C_{dsc} + C_{dscb} \cdot V_{bseff} + C_{dscd} \cdot v_{ds}$$

$$T_4 = \frac{T_2 + T_3 \cdot \Theta_0 + C_{it}}{C_{ox}}$$

$$n = \max(1 + T_4,\; 0.5)$$

### Effective Gate Overdrive (Vgsteff)

$$V_{gst} = V_{gs,eff} - V_{th}$$

Smooth subthreshold-to-strong-inversion transition:

$$V_{gsteff} = 2 n V_{tm} \ln\!\left(1 + \exp\!\left(\frac{V_{gst}}{2 n V_{tm}}\right)\right)$$

Exponential argument clamped to $\le 80$.

$$V_{gst2Vtm} = V_{gsteff} + 2 V_{tm}$$

### Mobility

Temperature-scaled low-field mobility:

$$\mu_{0,T} = \mu_0 \left(1 + \frac{\Delta T}{T_{nom}}\right)^{U_{te}}$$

Effective field (mobMod=1):

$$E_{eff} = \frac{V_{gsteff} + 2 V_{th}}{t_{ox}}$$

Degradation denominator:

$$D = \max\!\left(1 + U_a E_{eff} + U_b E_{eff}^2 + U_c V_{bseff},\; 0.2\right)$$

$$\mu_{eff} = \frac{\mu_{0,T}}{D}$$

### Saturation Velocity

$$v_{sat,T} = \max(v_{sat} - A_t \cdot \frac{\Delta T}{T_{nom}},\; 10^3)$$

$$E_{sat} = \frac{2 v_{sat,T}}{\mu_{eff}}$$

$$E_{sat} L = E_{sat} \cdot L_{eff}$$

$$W V_{Cox} = W_{eff} \cdot v_{sat,T} \cdot C_{ox}$$

### Bulk Charge Effect (Abulk)

$$T_{10,\kappa} = \kappa \cdot V_{bseff}$$

$$T_{11,\kappa} = \frac{1}{\max(1 + T_{10,\kappa},\; 0.1)}$$

$$T_{13} = \frac{V_{bseff} \cdot T_{11,\kappa}}{\phi_s + \kappa_{etas}}$$

$$T_{14} = \min\!\left(\frac{1}{\sqrt{\max(1 - T_{13},\; 0.04)}},\; 6\right)$$

$$T_1 = \frac{0.5 \cdot K_{1,eff}}{\sqrt{\phi_s + \kappa_{etas}}} \cdot T_{14}$$

$$T_9 = \sqrt{X_j \cdot X_{dep}}, \quad T_5 = \frac{L_{eff}}{L_{eff} + 2 T_9}$$

$$T_2 = A_0 \cdot T_5 + \frac{B_0}{W_{eff} + B_1}$$

$$A_{bulk,0} = 1 + T_1 \cdot T_2$$

$$T_8 = A_{gs} \cdot A_0 \cdot T_5^3$$

$$A_{bulk} = \max(A_{bulk,0} - T_1 \cdot T_8 \cdot V_{gsteff},\; 0.01)$$

### Source-Drain Resistance (Rds)

$$\text{rds0denom} = (W_{eff} \times 10^6)^{W_r}$$

$$R_{dsw,T} = R_{dsw} + P_{rt} \cdot \frac{\Delta T}{T_{nom}}$$

$$R_{ds0} = \frac{R_{dsw,T}}{\text{rds0denom}}$$

$$R_{ds} = R_{ds0} \cdot \left(1 + P_{rwg} \cdot V_{gsteff} + P_{rwb}(\sqrt{\phi_{is}} - \sqrt{\phi_s})\right)$$

### Saturation Voltage (Vdsat)

When $R_{ds} > 0$ (quadratic solution):

$$a = A_{bulk} \cdot W V_{Cox} \cdot R_{ds}$$

$$b = -(V_{gst2Vtm} + A_{bulk} \cdot E_{sat}L \cdot (1 + W V_{Cox} R_{ds}))$$

$$c = V_{gst2Vtm} \cdot E_{sat}L$$

$$V_{dsat} = \frac{-b - \sqrt{b^2 - 4ac}}{2a}$$

Discriminant clamped: $\max(b^2 - 4ac, 10^{-30})$.

When $R_{ds} \approx 0$:

$$V_{dsat} = \frac{E_{sat}L \cdot V_{gst2Vtm}}{A_{bulk} \cdot E_{sat}L + V_{gst2Vtm}}$$

### Effective Drain-Source Voltage (Vdseff)

Smooth clamp of $v_{ds}$ to $V_{dsat}$:

$$T_1 = V_{dsat} - v_{ds} - \delta$$

$$T_2 = \sqrt{T_1^2 + 4\delta \cdot V_{dsat}}$$

$$V_{dseff} = V_{dsat} - \frac{T_1 + T_2}{2}$$

Then: $V_{dseff} = V_{dseff} + \min(v_{ds} - V_{dseff}, 0)$ to enforce $V_{dseff} \le v_{ds}$.

$$\Delta V_{ds} = v_{ds} - V_{dseff}$$

### Channel Current (Ids)

$$\beta = \mu_{eff} \cdot \frac{C_{ox} \cdot W_{eff}}{L_{eff}}$$

$$f_{gche1} = V_{gsteff} \left(1 - \frac{A_{bulk} \cdot V_{dseff}}{2 V_{gst2Vtm}}\right)$$

$$f_{gche2} = 1 + \frac{V_{dseff}}{E_{sat}L}$$

$$g_{che} = \frac{\beta \cdot f_{gche1}}{f_{gche2}}$$

$$I_{dl} = \frac{g_{che} \cdot V_{dseff}}{1 + g_{che} \cdot R_{ds}}$$

### Channel Length Modulation (VACLM)

$$\text{litl} = \sqrt{3 X_j \cdot t_{ox} \cdot \frac{\epsilon_{Si}}{\epsilon_{ox}}}$$

$$T_0 = \frac{1}{pclm \cdot \text{litl} \cdot A_{bulk}}$$

$$T_1 = L_{eff} \cdot \left(A_{bulk} + \frac{V_{gsteff}}{E_{sat}L}\right)$$

$$V_{A,CLM} = T_0 \cdot T_1 \cdot (\Delta V_{ds} + 10^{-10})$$

If $pclm \le 0$ or $pclm \ge 10^{10}$: $V_{A,CLM} = 10^{30}$.

### DIBL Output Resistance (VADIBL)

$$\Theta_{rout} = pdiblc_1 \left(e^{-D_{rout} L_{eff}/(2 lt_1)} + 2 e^{-D_{rout} L_{eff}/lt_1}\right) + pdiblc_2$$

where $lt_1 = \text{factor1} \cdot \sqrt{X_{dep0}}$.

$$T_8 = A_{bulk} \cdot V_{dsat}$$

$$V_{A,DIBL} = \frac{V_{gst2Vtm} - \frac{V_{gst2Vtm} \cdot T_8}{V_{gst2Vtm} + T_8}}{\Theta_{rout}} \cdot \frac{1}{\max(1 + pdiblcb \cdot V_{bseff},\; 0.1)}$$

If $\Theta_{rout} \le 0$: $V_{A,DIBL} = 10^{30}$.

### Vasat

$$\text{tmp4} = 1 - \frac{A_{bulk} \cdot V_{dsat}}{2 V_{gst2Vtm}}$$

$$T_9 = W V_{Cox} R_{ds} \cdot V_{gsteff}$$

$$T_0 = E_{sat}L + V_{dsat} + 2 T_9 \cdot \text{tmp4}$$

$$\Lambda = A_2$$

$$T_1 = \frac{2}{\Lambda} - 1 + W V_{Cox} R_{ds} \cdot A_{bulk}$$

$$V_{A,sat} = \frac{T_0}{T_1}$$

### Output Resistance -- Final Early Voltage

$$\text{PVAG factor} = 1 + \frac{pvag \cdot V_{gsteff}}{E_{sat}L}$$

$$V_{A,CLM+DIBL} = \frac{V_{A,CLM} \cdot V_{A,DIBL}}{V_{A,CLM} + V_{A,DIBL}}$$

$$V_A = V_{A,sat} + \text{PVAG factor} \cdot V_{A,CLM+DIBL}$$

### Total Drain Current

$$I_{ds} = I_{dl} \cdot \left(1 + \frac{\Delta V_{ds}}{V_A}\right) \cdot M$$

### GIDL Current (Gate-Induced Drain Leakage)

**Drain side:**

$$T_0 = 3 t_{ox}$$

$$T_1 = \max\!\left(\frac{v_{ds} - V_{gs,eff} - N_{gidl}}{T_0},\; 10^{-20}\right)$$

$$I_{GIDL} = A_{gidl} \cdot W_{eff} \cdot T_1 \cdot \exp\!\left(\max\!\left(\frac{-B_{gidl}}{T_1},\; -80\right)\right)$$

**Source side (GISL):** symmetric with $T_1 = \max((-V_{gs,eff} - N_{gidl})/T_0, 10^{-20})$.

If $A_{gidl} = 0$ or $B_{gidl} = 0$: $I_{GIDL} = I_{GISL} = 0$.

### Junction Diode Currents

$$nV_{tm} = n_{diode} \cdot V_{tm}$$

**Diffusion current (Ibs1/Ibd1):**

$$I_{bs1} = W_{eff} \cdot t_{si} \cdot I_{s,dif} \cdot (e^{v_{bs}/nV_{tm}} - 1)$$

$$I_{bd1} = W_{eff} \cdot t_{si} \cdot I_{s,dif} \cdot (e^{V_{bd}/nV_{tm}} - 1)$$

**Recombination current (Ibs2/Ibd2):**

Forward term:

$$T_{10} = e^{v_{bs}/(0.026 \cdot n_{recf0})}$$

Reverse term (when $V_{rec0} > 0$):

$$T_{11} = -\exp\!\left(\frac{-v_{bs}}{0.026 \cdot n_{recr0}} \cdot \frac{V_{rec0}}{\max(V_{rec0} - v_{bs},\; 10^{-3})}\right)$$

$$I_{bs2} = W_{eff} \cdot t_{si} \cdot I_{s,rec} \cdot (T_{10} + T_{11})$$

Drain-side $I_{bd2}$ uses $V_{bd}$ in place of $v_{bs}$.

**BJT current (Ibs3/Ibd3):**

$$\text{lratio} = \left(L_{bjt0} \left(\frac{1}{L_{eff}} + \frac{1}{L_n}\right)\right)^{n_{bjt}}$$

$$\alpha_{bjt} = \exp\!\left(\frac{-L_{eff}^2}{2 L_n^2}\right)$$

$$I_{en} = W_{eff} \cdot t_{si} \cdot I_{s,bjt} \cdot \text{lratio}$$

$$I_{bs3} = (1 - \alpha_{bjt}) \cdot I_{en} \cdot (e^{v_{bs}/nV_{tm}} - 1)$$

$$I_{bd3} = (1 - \alpha_{bjt}) \cdot I_{en} \cdot (e^{V_{bd}/nV_{tm}} - 1)$$

**BJT collector current:**

$$I_c = \alpha_{bjt} \cdot I_{en} \cdot (e^{v_{bs}/nV_{tm}} - e^{V_{bd}/nV_{tm}})$$

If $\alpha_{bjt} < 0.01$: $I_c = 0$.

**Tunneling current (Ibs4/Ibd4):**

When $I_{s,tun} > 0$ and $V_{tun0} > 0$:

$$nV_{tm2} = 0.026 \cdot n_{tun}$$

$$T_0 = \frac{-v_{bs}}{nV_{tm2}} \cdot \frac{V_{tun0}}{\max(V_{tun0} - v_{bs},\; 10^{-3})}$$

$$I_{bs4} = W_{eff} \cdot t_{si} \cdot I_{s,tun} \cdot (1 - e^{T_0})$$

Drain-side $I_{bd4}$ uses $V_{bd}$.

**Total junction currents (with gmin):**

$$I_{bs} = I_{bs1} + I_{bs2} + I_{bs3} + I_{bs4} + g_{min} \cdot v_{bs}$$

$$I_{bd} = I_{bd1} + I_{bd2} + I_{bd3} + I_{bd4} + g_{min} \cdot V_{bd}$$

$g_{min} = 10^{-12}$ S.

### Impact Ionization Current

When $\alpha_0 > 0$:

$$V_{dsatii} = V_{dsatii0} - \frac{L_{ii}}{L_{eff}} + V_{gs,step}$$

$$T_{1,sii} = \frac{S_{ii0} \cdot E_{satii} \cdot L_{eff}}{1 + E_{satii} \cdot L_{eff}}$$

$$V_{gs,step} = T_{1,sii} \cdot V_{gst} \cdot \left(\frac{1}{1 + S_{ii1} \cdot V_{gsteff}} + S_{ii2}\right) \cdot \frac{1}{1 + S_{iid} \cdot v_{ds}}$$

$$V_{diff} = v_{ds} - V_{dsatii}$$

$$T_0 = \beta_2 + \beta_1 V_{diff} + \beta_0 V_{diff}^2, \quad T_0 \ge 10^{-5}$$

$$\text{Ratio} = \min\!\left(\alpha_0 \cdot \exp\!\left(\text{clamp}\!\left(\frac{V_{diff}}{T_0},\; -80, 80\right)\right),\; 10\right)$$

$$I_{ii} = \text{Ratio} \cdot (I_{ds} + f_{bjtii} \cdot I_c)$$

### Body Resistance Current

$$I_{bp} = \begin{cases} (V_B - V_P) / R_{body} & R_{body} > 0 \\ (V_B - V_P) \cdot 10^3 & R_{body} = 0 \end{cases}$$

### Self-Heating (Thermal Node)

When shmod=1 and $R_{th0} > 0$:

$$P_{diss} = I_{ds} \cdot v_{ds}$$

$$I_{temp} = \frac{\Delta T}{R_{th0}} - P_{diss}$$

When shmod=0 or $R_{th0} = 0$:

$$I_{temp} = \Delta T \cdot 10^3 \quad \text{(shorts temp node to ground)}$$

### KCL Node Stamps

$$I_D = I_{D \to DP}$$

$$I_G = I_{gb} + g_{min}(V_G - V_S)$$

$$I_S = I_{S \to SP} - g_{min}(V_G - V_S) - g_{min}(V_E - V_S) - g_{min}(V_P - V_S)$$

$$I_E = g_{min}(V_E - V_B) + g_{min}(V_E - V_S)$$

$$I_{DP} = -I_{D \to DP} + I_{ds} \cdot \text{mode} + I_c - I_{bd} - I_{ii} + I_{GIDL} + g_{min}(V_{DP} - V_{SP})$$

$$I_{SP} = -I_{S \to SP} - I_{ds} \cdot \text{mode} - I_c - I_{bs} + I_{GISL} - g_{min}(V_{DP} - V_{SP}) - g_{min}(V_B - V_{SP})$$

$$I_B = I_{bs} + I_{bd} + I_{bp} + I_{ii} - I_{GIDL} - I_{GISL} - I_{gb} + g_{min}(V_B - V_{SP}) - g_{min}(V_E - V_B)$$

$$I_{TEMP} = \text{(see Self-Heating above)}$$

$$I_P = -I_{bp} + g_{min}(V_P - V_S)$$

---

## Charge Model (q function)

### Gate Charge (CapMod=2)

Vth for CV uses the same formula as DC Vth but without temperature or narrow-width corrections.

**Subthreshold swing factor for CV:**

$$C_{dep0} = \sqrt{q \cdot \epsilon_{Si} \cdot N_{ch} \cdot 10^6}$$

$$C_{dep} = \frac{C_{dep0}}{\sqrt{\phi_{is}}}$$

$$n_{CV} = \max\!\left(1 + \frac{C_{dep}}{C_{ox}} + C_{dsc} + C_{dscd} v_{ds} + C_{dscb} V_{bseff} + \frac{C_{it}}{C_{ox}},\; 1\right)$$

**Vgsteff for CV:**

$$V_{gsteff,CV} = n_{CV} V_{tm} \ln\!\left(1 + e^{V_{gst}/(n_{CV} V_{tm})}\right)$$

**Abulk for CV (simplified):**

$$A_{bulk,CV} = \max\!\left(\frac{1 + \frac{0.5 K_1}{\sqrt{\phi_{is}}} \left(1 - \frac{X_j}{X_{dep} + X_j}\right)}{1 + \kappa \cdot V_{bseff}},\; 0.1\right)$$

**VdsatCV and VdseffCV:**

$$V_{dsat,CV} = \frac{V_{gsteff,CV}}{A_{bulk,CV}}$$

$$T = V_{dsat,CV} - V_{ds} - 0.02$$

$$V_{dseff,CV} = V_{dsat,CV} - \frac{T + \sqrt{T^2 + 0.08 V_{dsat,CV}}}{2}$$

**Flat-band voltage for CV:**

$$V_{fb,CV} = V_{th0} - \phi_s - K_1 \sqrt{\phi_s}$$

**Vfbeff (smooth clamp):**

$$T = V_{fb,CV} - V_{gs} + V_{bseff} - 0.08$$

$$V_{fbeff} = V_{fb,CV} - \frac{T + \sqrt{T^2 + 0.32 |V_{fb,CV}|}}{2}$$

**Accumulation charge:**

$$Q_{ac0} = f_{body} \cdot C_{ox} W_{eff} L_{eff} \cdot (V_{fbeff} - V_{fb,CV})$$

**Depletion/subthreshold charge:**

$$Q_{sub0} = f_{body} \cdot C_{ox} W_{eff} L_{eff} \cdot K_1 \left(\sqrt{(K_1/2)^2 + \max(T_3, 0)} - K_1/2\right)$$

where $T_3 = V_{gs} - V_{fbeff} - V_{bseff} - V_{gsteff,CV}$.

**Inversion charge:**

$$T_0 = A_{bulk,CV} \cdot V_{dseff,CV}$$

$$T_1 = 12 (V_{gsteff,CV} - T_0/2 + 10^{-20})$$

$$T_2 = V_{dseff,CV} / T_1$$

$$T_3 = T_0 \cdot T_2$$

$$Q_{inv} = C_{ox} W_{eff} L_{eff} (V_{gsteff,CV} - V_{dseff,CV}/2 + T_3)$$

**Bulk charge:**

$$Q_{bulk} = f_{body} \cdot C_{ox} W_{eff} L_{eff} \cdot (1 - A_{bulk,CV}) \cdot (V_{dseff,CV}/2 - T_3)$$

**Source charge (50/50 partitioning):**

$$Q_{src} = -\frac{Q_{inv} + Q_{bulk}}{2}$$

### Backgate (Substrate) Charge

$$C_{box} = \frac{\epsilon_{ox}}{t_{box}}$$

$$C_{box,WL} = K_{b1} \cdot f_{body} \cdot C_{box} \cdot W_{eff} \cdot L_{eff}$$

$$V_{fbb} = \begin{cases} -\frac{k_B}{q} T_{nom} \ln(N_{ch}/N_{sub}) & N_{sub} > 0 \\ -\frac{k_B}{q} T_{nom} \ln(-N_{ch} N_{sub}/(1.45 \times 10^{10})^2) & N_{sub} \le 0 \end{cases}$$

$$Q_{e1} = C_{box,WL} \cdot (V_{ES} - V_{fbb} - V_{bs})$$

### Overlap Capacitance Charges

$$Q_{gs,ov} = C_{gso} \cdot W_{eff} \cdot V_{gs}$$

$$Q_{gd,ov} = C_{gdo} \cdot W_{eff} \cdot V_{gd}$$

### Junction Depletion Charges

When $C_{jswg} > 0$ and $P_{bswg} > 0$ and $1 - M_{jswg} > 0.01$:

$$Q_{js} = C_{jswg} \cdot W_{eff} \cdot \frac{P_{bswg}}{1 - M_{jswg}} \left(1 - \max\!\left(1 - \frac{V_{bs}}{P_{bswg}},\; 0.01\right)^{1-M_{jswg}}\right)$$

$$Q_{jd} = C_{jswg} \cdot W_{eff} \cdot \frac{P_{bswg}}{1 - M_{jswg}} \left(1 - \max\!\left(1 - \frac{V_{bd}}{P_{bswg}},\; 0.01\right)^{1-M_{jswg}}\right)$$

### Transit Time (Diffusion) Charges

$$Q_{tt,s} = \tau_t \cdot W_{eff} \cdot t_{si} \cdot I_{s,dif} \cdot (e^{V_{bs}/(n_{diode} V_{tm})} - 1)$$

$$Q_{tt,d} = \tau_t \cdot W_{eff} \cdot t_{si} \cdot I_{s,dif} \cdot (e^{V_{bd}/(n_{diode} V_{tm})} - 1)$$

### Thermal Capacitance Charge

$$Q_{th} = C_{th0} \cdot \Delta T$$

### Charge Node Assembly

$$Q_D = 0$$

$$Q_G = Q_{inv} + Q_{ac0} + Q_{sub0} + Q_{gs,ov} + Q_{gd,ov}$$

$$Q_S = 0$$

$$Q_E = Q_{e1}$$

$$Q_{DP} = Q_{drn} - Q_{gd,ov} + Q_{jd} + Q_{tt,d}$$

$$Q_{SP} = Q_{src} - Q_{gs,ov} + Q_{js} + Q_{tt,s}$$

$$Q_B = Q_{bulk} - Q_{ac0} - Q_{sub0} - Q_{e1}$$

$$Q_{TEMP} = C_{th0} \cdot \Delta T$$

$$Q_P = 0$$

where:

$$Q_{gate} = Q_{inv} + Q_{ac0} + Q_{sub0}$$

$$Q_{drn} = -(Q_{gate} + Q_{src} + Q_{body} + Q_{sub})$$

$$Q_{body} = Q_{bulk} - Q_{ac0} - Q_{sub0} - Q_{e1}$$

---

## Convergence Helpers

### Voltage Limiting (limit function)

Applied each Newton iteration to damp step sizes.

**Gate voltage limiting (fetlim):**

Standard SPICE DEVfetlim algorithm with $V_{to} = 0.5$ V:

$$V_{tsthi} = |2(V_{old} - V_{to})| + 2$$

$$V_{tstlo} = V_{tsthi}/2 + 2$$

$$V_{tox} = V_{to} + 3.5$$

When above threshold and rising: $\Delta V \le V_{tsthi}$. When below threshold: $|\Delta V| \le V_{tstlo}$.

**Drain-source limiting (limvds):**

When $V_{old} \ge 3.5$ and rising:

$$\Delta V \le \frac{V_{old} - 3.5}{2} + 4$$

Otherwise: $|\Delta V| \le 4$.

**PN junction limiting (pnjlim):**

When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 V_t$ with $V_{crit} = 0.6$ V, $V_t = 0.026$ V:

If $V_{old} > 0$ and $\text{arg} = (V_{new} - V_{old})/V_t > 0$:

$$V_{lim} = V_{old} + V_t (2 + \ln(\text{arg} - 2))$$

If arg < 0:

$$V_{lim} = V_{old} - V_t (2 + \ln(2 - \text{arg}))$$

If $V_{old} \le 0$:

$$V_{lim} = V_t \ln(V_{new}/V_t)$$

**Temperature limiting:**

$$|\Delta T_{new} - \Delta T_{old}| \le 5 \text{ K}$$

### Gmin Conductances

Minimum conductances ($g_{min} = 10^{-12}$ S) added between node pairs to prevent floating nodes:

- DP-SP, B-SP, G-S, E-B, E-S, P-S

Short conductance ($G_{SHORT} = 10^3$ S) used when resistance parameters are zero (rbody=0 shorts B to P; rth0=0 shorts TEMP to ground).
