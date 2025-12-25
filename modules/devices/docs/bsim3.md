# BSIM3 v3.3 -- Parameter & Equation Reference

> Berkeley short-channel IGFET MOSFET model (pre-CMC standard, 4-terminal bulk MOSFET)

## Model Topology

BSIM3v3 is a four-terminal MOSFET: Drain (d), Gate (g), Source (s), Bulk (b). All four terminals are external ports (`num_ports = 4`). The equivalent circuit comprises a channel current source between drain and source (including subthreshold, velocity saturation, CLM, DIBL, and SCBE), source-bulk and drain-bulk junction diodes, substrate current (impact ionization), GMIN parasitic conductances between all terminal pairs, and intrinsic/overlap/junction charge storage. Source-drain reversal is handled branchlessly via `mode = sign(Vds)`. PMOS is supported by negating terminal voltages with `type_ = -1`.

## Parameters

### Model Selectors

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| type_ | -- | -- | 1 | {-1, 1} | Device type: 1 = NMOS, -1 = PMOS |
| capmod | -- | -- | 3 | {0,1,2,3} | Capacitance model selector |
| mobmod | -- | -- | 1 | {1,2,3} | Mobility model selector |
| noimod | -- | -- | 1 | {1,2,3,4} | Noise model selector |
| nqsmod | -- | -- | 0 | {0,1} | Non-quasi-static model selector |
| acnqsmod | -- | -- | 0 | {0,1} | AC NQS model selector |
| acm | -- | -- | 0 | {0..12} | Area calculation method selector |
| calcacm | -- | -- | 0 | {0,1} | Area calculation method ACM=12 |
| paramchk | -- | -- | 0 | {0,1} | Model parameter checking selector |
| binunit | -- | -- | 1 | {1,2} | Bin unit selector |
| version | -- | -- | 3.3 | -- | Model version |

### Oxide / Basic Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| tox | $T_{ox}$ | m | 1.5e-8 | >0 | Gate oxide thickness |
| toxm | $T_{oxm}$ | m | 1.5e-8 | >0 | Gate oxide thickness used in extraction |
| cdsc | $C_{dsc}$ | F/m^2 | 2.4e-4 | -- | Drain/source and channel coupling capacitance |
| cdscb | $C_{dscb}$ | F/m^2 | 0 | -- | Body-bias dependence of cdsc |
| cdscd | $C_{dscd}$ | F/m^2 | 0 | -- | Drain-bias dependence of cdsc |
| cit | $C_{it}$ | F/m^2 | 0 | -- | Interface state capacitance |
| nfactor | $N_{factor}$ | -- | 1 | -- | Subthreshold swing coefficient |
| xj | $X_j$ | m | 1.5e-7 | >0 | Junction depth |
| vsat | $v_{sat}$ | m/s | 8.0e4 | >0 | Saturation velocity at tnom |
| at | $A_T$ | m/s | 3.3e4 | -- | Temperature coefficient of vsat |
| a0 | $A_0$ | -- | 1 | -- | Non-uniform depletion width effect coefficient |
| ags | $A_{GS}$ | 1/V | 0 | -- | Gate bias coefficient of Abulk |
| a1 | $A_1$ | 1/V | 0 | -- | Non-saturation effect coefficient |
| a2 | $A_2$ | -- | 1 | -- | Non-saturation effect coefficient |
| keta | $K_{eta}$ | 1/V | -0.047 | -- | Body-bias coefficient of non-uniform depletion width effect |
| nsub | $N_{sub}$ | cm^-3 | 6e16 | >0 | Substrate doping concentration |
| nch | $N_{ch}$ | cm^-3 | 1.7e17 | >0 | Channel doping concentration |
| ngate | $N_{gate}$ | cm^-3 | 0 | >=0 | Poly-gate doping concentration |
| gamma1 | $\gamma_1$ | V^0.5 | 0 | -- | Vth body coefficient |
| gamma2 | $\gamma_2$ | V^0.5 | 0 | -- | Vth body coefficient |
| vbx | $V_{bx}$ | V | 0 | -- | Vth transition body voltage |
| vbm | $V_{bm}$ | V | -3 | -- | Maximum body voltage |
| xt | $X_T$ | m | 1.55e-7 | >0 | Doping depth |
| k1 | $K_1$ | V^0.5 | 0 | -- | Bulk effect coefficient 1 |
| kt1 | $K_{t1}$ | V | -0.11 | -- | Temperature coefficient of Vth |
| kt1l | $K_{t1l}$ | V*m | 0 | -- | Temperature coefficient of Vth (length dependent) |
| kt2 | $K_{t2}$ | -- | 0.022 | -- | Body-coefficient of kt1 |
| k2 | $K_2$ | -- | 0 | -- | Bulk effect coefficient 2 |
| k3 | $K_3$ | -- | 80 | -- | Narrow width effect coefficient |
| k3b | $K_{3b}$ | 1/V | 0 | -- | Body effect coefficient of k3 |
| w0 | $W_0$ | m | 2.5e-6 | -- | Narrow width effect parameter |
| nlx | $N_{LX}$ | m | 1.74e-7 | -- | Lateral non-uniform doping effect |
| dvt0 | $D_{VT0}$ | -- | 2.2 | -- | Short channel effect coeff. 0 |
| dvt1 | $D_{VT1}$ | -- | 0.53 | -- | Short channel effect coeff. 1 |
| dvt2 | $D_{VT2}$ | 1/V | -0.032 | -- | Short channel effect coeff. 2 |
| dvt0w | $D_{VT0W}$ | -- | 0 | -- | Narrow width coeff. 0 |
| dvt1w | $D_{VT1W}$ | 1/m | 5.3e6 | -- | Narrow width effect coeff. 1 |
| dvt2w | $D_{VT2W}$ | 1/V | -0.032 | -- | Narrow width effect coeff. 2 |
| drout | $D_{ROUT}$ | -- | 0.56 | -- | DIBL coefficient of output resistance |
| dsub | $D_{SUB}$ | -- | 0.56 | -- | DIBL coefficient in the subthreshold region |
| vth0 | $V_{TH0}$ | V | 0.7 | -- | Threshold voltage |
| ua | $U_a$ | m/V | 2.25e-9 | -- | Linear gate dependence of mobility |
| ua1 | $U_{a1}$ | m/V | 4.31e-9 | -- | Temperature coefficient of ua |
| ub | $U_b$ | (m/V)^2 | 5.87e-19 | -- | Quadratic gate dependence of mobility |
| ub1 | $U_{b1}$ | (m/V)^2 | -7.61e-18 | -- | Temperature coefficient of ub |
| uc | $U_c$ | 1/V | -4.65e-11 | -- | Body-bias dependence of mobility |
| uc1 | $U_{c1}$ | m/V^2 | -5.6e-11 | -- | Temperature coefficient of uc |
| u0 | $\mu_0$ | m^2/Vs | 0.067 | >0 | Low-field mobility at Tnom |
| ute | $U_{TE}$ | -- | -1.5 | -- | Temperature coefficient of mobility |
| voff | $V_{OFF}$ | V | -0.08 | -- | Threshold voltage offset |
| tnom | $T_{nom}$ | K | 300.15 | >0 | Parameter measurement temperature |
| cgso | $C_{GSO}$ | F/m | 2.07188e-10 | >=0 | Gate-source overlap capacitance per width |
| cgdo | $C_{GDO}$ | F/m | 2.07188e-10 | >=0 | Gate-drain overlap capacitance per width |
| cgbo | $C_{GBO}$ | F/m | 0 | >=0 | Gate-bulk overlap capacitance per length |
| xpart | -- | -- | 0 | {0,0.5,1} | Channel charge partitioning |
| elm | $ELM$ | -- | 5 | -- | Non-quasi-static Elmore constant parameter |
| delta | $\delta$ | V | 0.01 | >0 | Effective Vds smoothing parameter |
| rsh | $R_{SH}$ | ohm/sq | 0 | >=0 | Source-drain sheet resistance |
| rdsw | $R_{DSW}$ | ohm*um^WR | 0 | >=0 | Source-drain resistance per width |
| prwg | $P_{RWG}$ | 1/V | 0 | -- | Gate-bias effect on parasitic resistance |
| prwb | $P_{RWB}$ | 1/V^0.5 | 0 | -- | Body-effect on parasitic resistance |
| prt | $P_{RT}$ | ohm | 0 | -- | Temperature coefficient of parasitic resistance |
| eta0 | $\eta_0$ | -- | 0.08 | -- | Subthreshold region DIBL coefficient |
| etab | $\eta_b$ | 1/V | -0.07 | -- | Subthreshold region DIBL coefficient |
| pclm | $P_{CLM}$ | -- | 1.3 | >0 | Channel length modulation coefficient |
| pdiblc1 | $P_{DIBLC1}$ | -- | 0.39 | -- | Drain-induced barrier lowering coefficient |
| pdiblc2 | $P_{DIBLC2}$ | -- | 0.0086 | -- | Drain-induced barrier lowering coefficient |
| pdiblcb | $P_{DIBLCb}$ | 1/V | 0 | -- | Body-effect on drain-induced barrier lowering |
| pscbe1 | $P_{SCBE1}$ | V/m | 4.24e8 | -- | Substrate current body-effect coefficient |
| pscbe2 | $P_{SCBE2}$ | m/V | 1e-5 | -- | Substrate current body-effect coefficient |
| pvag | $P_{VAG}$ | -- | 0 | -- | Gate dependence of output resistance parameter |

### Junction Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| js | $J_S$ | A/m^2 | 1e-4 | >=0 | Source/drain junction reverse saturation current density |
| jsw | $J_{SW}$ | A/m | 0 | >=0 | Sidewall junction reverse saturation current density |
| pb | $P_B$ | V | 1 | >0 | Source/drain junction built-in potential |
| nj | $N_J$ | -- | 1 | >0 | Source/drain junction emission coefficient |
| xti | $X_{TI}$ | -- | 3 | -- | Junction current temperature exponent |
| mj | $M_J$ | -- | 0.5 | -- | Source/drain bottom junction capacitance grading coefficient |
| pbsw | $P_{BSW}$ | V | 1 | >0 | Source/drain sidewall junction capacitance built-in potential |
| mjsw | $M_{JSW}$ | -- | 0.33 | -- | Source/drain sidewall junction capacitance grading coefficient |
| pbswg | $P_{BSWG}$ | V | 1 | >0 | Source/drain (gate side) sidewall junction cap. built-in potential |
| mjswg | $M_{JSWG}$ | -- | 0.33 | -- | Source/drain (gate side) sidewall junction cap. grading coefficient |
| cj | $C_J$ | F/m^2 | 5e-4 | >=0 | Source/drain bottom junction capacitance per unit area |
| vfbcv | $V_{FBCV}$ | V | -1 | -- | Flat band voltage parameter for capmod=0 only |
| vfb | $V_{FB}$ | V | 0 | -- | Flat band voltage |
| cjsw | $C_{JSW}$ | F/m | 5e-10 | >=0 | Source/drain sidewall junction capacitance per unit periphery |
| cjswg | $C_{JSWG}$ | F/m | 5e-10 | >=0 | Source/drain (gate side) sidewall junction cap. per unit width |
| tpb | $T_{PB}$ | V/K | 0 | -- | Temperature coefficient of pb |
| tcj | $T_{CJ}$ | 1/K | 0 | -- | Temperature coefficient of cj |
| tpbsw | $T_{PBSW}$ | V/K | 0 | -- | Temperature coefficient of pbsw |
| tcjsw | $T_{CJSW}$ | 1/K | 0 | -- | Temperature coefficient of cjsw |
| tpbswg | $T_{PBSWG}$ | V/K | 0 | -- | Temperature coefficient of pbswg |
| tcjswg | $T_{CJSWG}$ | 1/K | 0 | -- | Temperature coefficient of cjswg |
| acde | $ACDE$ | -- | 1 | -- | Exponential coefficient for finite charge thickness |
| moin | $MOIN$ | -- | 15 | -- | Coefficient for gate-bias dependent surface potential |
| noff | $N_{OFF}$ | -- | 1 | -- | C-V turn-on/off parameter |
| voffcv | $V_{OFFCV}$ | V | 0 | -- | C-V lateral-shift parameter |
| lintnoi | $LINT_{noi}$ | m | 0 | -- | lint offset for noise calculation |

### Length Reduction Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| lint | $LINT$ | m | 0 | -- | Length reduction parameter |
| ll | $LL$ | m^LLN | 0 | -- | Length reduction parameter |
| llc | $LLC$ | m^LLN | 0 | -- | Length reduction parameter for CV |
| lln | $LLN$ | -- | 1 | -- | Length reduction parameter |
| lw | $LW$ | m^LWN | 0 | -- | Length reduction parameter |
| lwc | $LWC$ | m^LWN | 0 | -- | Length reduction parameter for CV |
| lwn | $LWN$ | -- | 1 | -- | Length reduction parameter |
| lwl | $LWL$ | m^(LLN+LWN) | 0 | -- | Length reduction parameter |
| lwlc | $LWLC$ | m^(LLN+LWN) | 0 | -- | Length reduction parameter for CV |
| lmin | $L_{min}$ | m | 0 | >=0 | Minimum length for the model |
| lmax | $L_{max}$ | m | 1 | >0 | Maximum length for the model |
| xl | $XL$ | m | 0 | -- | Length correction parameter |
| xw | $XW$ | m | 0 | -- | Width correction parameter |

### Width Reduction Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| wr | $W_R$ | -- | 1 | -- | Width dependence of rds |
| wint | $WINT$ | m | 0 | -- | Width reduction parameter |
| dwg | $DWG$ | m/V | 0 | -- | Width reduction parameter (gate bias) |
| dwb | $DWB$ | m/V^0.5 | 0 | -- | Width reduction parameter (body bias) |
| wl | $WL$ | m^WLN | 0 | -- | Width reduction parameter |
| wlc | $WLC$ | m^WLN | 0 | -- | Width reduction parameter for CV |
| wln | $WLN$ | -- | 1 | -- | Width reduction parameter |
| ww | $WW$ | m^WWN | 0 | -- | Width reduction parameter |
| wwc | $WWC$ | m^WWN | 0 | -- | Width reduction parameter for CV |
| wwn | $WWN$ | -- | 1 | -- | Width reduction parameter |
| wwl | $WWL$ | m^(WLN+WWN) | 0 | -- | Width reduction parameter |
| wwlc | $WWLC$ | m^(WLN+WWN) | 0 | -- | Width reduction parameter for CV |
| wmin | $W_{min}$ | m | 0 | >=0 | Minimum width for the model |
| wmax | $W_{max}$ | m | 1 | >0 | Maximum width for the model |

### Narrow Width Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| b0 | $B_0$ | m | 0 | -- | Abulk narrow width parameter |
| b1 | $B_1$ | m | 0 | -- | Abulk narrow width parameter |

### C-V Model Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| cgsl | $C_{GSL}$ | F/m | 0 | >=0 | New C-V model parameter |
| cgdl | $C_{GDL}$ | F/m | 0 | >=0 | New C-V model parameter |
| ckappa | $C_{\kappa}$ | F/m | 0.6 | -- | New C-V model parameter |
| cf | $C_F$ | F/m | 7.29897e-11 | >=0 | Fringe capacitance parameter |
| clc | $CLC$ | m | 1e-7 | >0 | Vdsat parameter for C-V model |
| cle | $CLE$ | -- | 0.6 | -- | Vdsat parameter for C-V model |
| dwc | $DWC$ | m | 0 | -- | Delta W for C-V model |
| dlc | $DLC$ | m | 0 | -- | Delta L for C-V model |

### ACM Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| hdif | $HDIF$ | m | 0 | >=0 | Distance gate to contact |
| ldif | $LDIF$ | m | 0 | >=0 | Length of LDD gate-source/drain |
| ld | $LD$ | m | 0 | >=0 | Length of LDD under gate |
| rd | $R_D$ | ohm | 0 | >=0 | Resistance of LDD drain side |
| rs | $R_S$ | ohm | 0 | >=0 | Resistance of LDD source side |
| rdc | $R_{DC}$ | ohm | 0 | >=0 | Resistance contact drain side |
| rsc | $R_{SC}$ | ohm | 0 | >=0 | Resistance contact source side |
| wmlt | $WMLT$ | -- | 1 | >0 | Width shrink factor |

### Substrate Current Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| alpha0 | $\alpha_0$ | m/V | 0 | -- | Substrate current model parameter |
| alpha1 | $\alpha_1$ | 1/V | 0 | -- | Substrate current model parameter |
| beta0 | $\beta_0$ | V | 30 | >0 | Substrate current model parameter |
| ijth | $I_{JTH}$ | A | 0.1 | >0 | Diode limiting current |

### Length Dependence Parameters

All default to 0. Effective parameter: $P_{eff} = P + LP / L_{eff}^{LLN}$.

| Parameter | Base Param | Default | Description |
|-----------|------------|---------|-------------|
| lcdsc | cdsc | 0 | Length dependence of cdsc |
| lcdscb | cdscb | 0 | Length dependence of cdscb |
| lcdscd | cdscd | 0 | Length dependence of cdscd |
| lcit | cit | 0 | Length dependence of cit |
| lnfactor | nfactor | 0 | Length dependence of nfactor |
| lxj | xj | 0 | Length dependence of xj |
| lvsat | vsat | 0 | Length dependence of vsat |
| lat | at | 0 | Length dependence of at |
| la0 | a0 | 0 | Length dependence of a0 |
| lags | ags | 0 | Length dependence of ags |
| la1 | a1 | 0 | Length dependence of a1 |
| la2 | a2 | 0 | Length dependence of a2 |
| lketa | keta | 0 | Length dependence of keta |
| lnsub | nsub | 0 | Length dependence of nsub |
| lnch | nch | 0 | Length dependence of nch |
| lngate | ngate | 0 | Length dependence of ngate |
| lgamma1 | gamma1 | 0 | Length dependence of gamma1 |
| lgamma2 | gamma2 | 0 | Length dependence of gamma2 |
| lvbx | vbx | 0 | Length dependence of vbx |
| lvbm | vbm | 0 | Length dependence of vbm |
| lxt | xt | 0 | Length dependence of xt |
| lk1 | k1 | 0 | Length dependence of k1 |
| lkt1 | kt1 | 0 | Length dependence of kt1 |
| lkt1l | kt1l | 0 | Length dependence of kt1l |
| lkt2 | kt2 | 0 | Length dependence of kt2 |
| lk2 | k2 | 0 | Length dependence of k2 |
| lk3 | k3 | 0 | Length dependence of k3 |
| lk3b | k3b | 0 | Length dependence of k3b |
| lw0 | w0 | 0 | Length dependence of w0 |
| lnlx | nlx | 0 | Length dependence of nlx |
| ldvt0 | dvt0 | 0 | Length dependence of dvt0 |
| ldvt1 | dvt1 | 0 | Length dependence of dvt1 |
| ldvt2 | dvt2 | 0 | Length dependence of dvt2 |
| ldvt0w | dvt0w | 0 | Length dependence of dvt0w |
| ldvt1w | dvt1w | 0 | Length dependence of dvt1w |
| ldvt2w | dvt2w | 0 | Length dependence of dvt2w |
| ldrout | drout | 0 | Length dependence of drout |
| ldsub | dsub | 0 | Length dependence of dsub |
| lvth0 | vth0 | 0 | Length dependence of vth0 |
| lua | ua | 0 | Length dependence of ua |
| lua1 | ua1 | 0 | Length dependence of ua1 |
| lub | ub | 0 | Length dependence of ub |
| lub1 | ub1 | 0 | Length dependence of ub1 |
| luc | uc | 0 | Length dependence of uc |
| luc1 | uc1 | 0 | Length dependence of uc1 |
| lu0 | u0 | 0 | Length dependence of u0 |
| lute | ute | 0 | Length dependence of ute |
| lvoff | voff | 0 | Length dependence of voff |
| lelm | elm | 0 | Length dependence of elm |
| ldelta | delta | 0 | Length dependence of delta |
| lrdsw | rdsw | 0 | Length dependence of rdsw |
| lprwg | prwg | 0 | Length dependence of prwg |
| lprwb | prwb | 0 | Length dependence of prwb |
| lprt | prt | 0 | Length dependence of prt |
| leta0 | eta0 | 0 | Length dependence of eta0 |
| letab | etab | 0 | Length dependence of etab |
| lpclm | pclm | 0 | Length dependence of pclm |
| lpdiblc1 | pdiblc1 | 0 | Length dependence of pdiblc1 |
| lpdiblc2 | pdiblc2 | 0 | Length dependence of pdiblc2 |
| lpdiblcb | pdiblcb | 0 | Length dependence of pdiblcb |
| lpscbe1 | pscbe1 | 0 | Length dependence of pscbe1 |
| lpscbe2 | pscbe2 | 0 | Length dependence of pscbe2 |
| lpvag | pvag | 0 | Length dependence of pvag |
| lwr | wr | 0 | Length dependence of wr |
| ldwg | dwg | 0 | Length dependence of dwg |
| ldwb | dwb | 0 | Length dependence of dwb |
| lb0 | b0 | 0 | Length dependence of b0 |
| lb1 | b1 | 0 | Length dependence of b1 |
| lcgsl | cgsl | 0 | Length dependence of cgsl |
| lcgdl | cgdl | 0 | Length dependence of cgdl |
| lckappa | ckappa | 0 | Length dependence of ckappa |
| lcf | cf | 0 | Length dependence of cf |
| lclc | clc | 0 | Length dependence of clc |
| lcle | cle | 0 | Length dependence of cle |
| lalpha0 | alpha0 | 0 | Length dependence of alpha0 |
| lalpha1 | alpha1 | 0 | Length dependence of alpha1 |
| lbeta0 | beta0 | 0 | Length dependence of beta0 |
| lvfbcv | vfbcv | 0 | Length dependence of vfbcv |
| lvfb | vfb | 0 | Length dependence of vfb |
| lacde | acde | 0 | Length dependence of acde |
| lmoin | moin | 0 | Length dependence of moin |
| lnoff | noff | 0 | Length dependence of noff |
| lvoffcv | voffcv | 0 | Length dependence of voffcv |

### Width Dependence Parameters

All default to 0. Effective parameter: $P_{eff} = P + WP / W_{eff}^{WWN}$.

| Parameter | Base Param | Default | Description |
|-----------|------------|---------|-------------|
| wcdsc | cdsc | 0 | Width dependence of cdsc |
| wcdscb | cdscb | 0 | Width dependence of cdscb |
| wcdscd | cdscd | 0 | Width dependence of cdscd |
| wcit | cit | 0 | Width dependence of cit |
| wnfactor | nfactor | 0 | Width dependence of nfactor |
| wxj | xj | 0 | Width dependence of xj |
| wvsat | vsat | 0 | Width dependence of vsat |
| wat | at | 0 | Width dependence of at |
| wa0 | a0 | 0 | Width dependence of a0 |
| wags | ags | 0 | Width dependence of ags |
| wa1 | a1 | 0 | Width dependence of a1 |
| wa2 | a2 | 0 | Width dependence of a2 |
| wketa | keta | 0 | Width dependence of keta |
| wnsub | nsub | 0 | Width dependence of nsub |
| wnch | nch | 0 | Width dependence of nch |
| wngate | ngate | 0 | Width dependence of ngate |
| wgamma1 | gamma1 | 0 | Width dependence of gamma1 |
| wgamma2 | gamma2 | 0 | Width dependence of gamma2 |
| wvbx | vbx | 0 | Width dependence of vbx |
| wvbm | vbm | 0 | Width dependence of vbm |
| wxt | xt | 0 | Width dependence of xt |
| wk1 | k1 | 0 | Width dependence of k1 |
| wkt1 | kt1 | 0 | Width dependence of kt1 |
| wkt1l | kt1l | 0 | Width dependence of kt1l |
| wkt2 | kt2 | 0 | Width dependence of kt2 |
| wk2 | k2 | 0 | Width dependence of k2 |
| wk3 | k3 | 0 | Width dependence of k3 |
| wk3b | k3b | 0 | Width dependence of k3b |
| ww0 | w0 | 0 | Width dependence of w0 |
| wnlx | nlx | 0 | Width dependence of nlx |
| wdvt0 | dvt0 | 0 | Width dependence of dvt0 |
| wdvt1 | dvt1 | 0 | Width dependence of dvt1 |
| wdvt2 | dvt2 | 0 | Width dependence of dvt2 |
| wdvt0w | dvt0w | 0 | Width dependence of dvt0w |
| wdvt1w | dvt1w | 0 | Width dependence of dvt1w |
| wdvt2w | dvt2w | 0 | Width dependence of dvt2w |
| wdrout | drout | 0 | Width dependence of drout |
| wdsub | dsub | 0 | Width dependence of dsub |
| wvth0 | vth0 | 0 | Width dependence of vth0 |
| wua | ua | 0 | Width dependence of ua |
| wua1 | ua1 | 0 | Width dependence of ua1 |
| wub | ub | 0 | Width dependence of ub |
| wub1 | ub1 | 0 | Width dependence of ub1 |
| wuc | uc | 0 | Width dependence of uc |
| wuc1 | uc1 | 0 | Width dependence of uc1 |
| wu0 | u0 | 0 | Width dependence of u0 |
| wute | ute | 0 | Width dependence of ute |
| wvoff | voff | 0 | Width dependence of voff |
| welm | elm | 0 | Width dependence of elm |
| wdelta | delta | 0 | Width dependence of delta |
| wrdsw | rdsw | 0 | Width dependence of rdsw |
| wprwg | prwg | 0 | Width dependence of prwg |
| wprwb | prwb | 0 | Width dependence of prwb |
| wprt | prt | 0 | Width dependence of prt |
| weta0 | eta0 | 0 | Width dependence of eta0 |
| wetab | etab | 0 | Width dependence of etab |
| wpclm | pclm | 0 | Width dependence of pclm |
| wpdiblc1 | pdiblc1 | 0 | Width dependence of pdiblc1 |
| wpdiblc2 | pdiblc2 | 0 | Width dependence of pdiblc2 |
| wpdiblcb | pdiblcb | 0 | Width dependence of pdiblcb |
| wpscbe1 | pscbe1 | 0 | Width dependence of pscbe1 |
| wpscbe2 | pscbe2 | 0 | Width dependence of pscbe2 |
| wpvag | pvag | 0 | Width dependence of pvag |
| wwr | wr | 0 | Width dependence of wr |
| wdwg | dwg | 0 | Width dependence of dwg |
| wdwb | dwb | 0 | Width dependence of dwb |
| wb0 | b0 | 0 | Width dependence of b0 |
| wb1 | b1 | 0 | Width dependence of b1 |
| wcgsl | cgsl | 0 | Width dependence of cgsl |
| wcgdl | cgdl | 0 | Width dependence of cgdl |
| wckappa | ckappa | 0 | Width dependence of ckappa |
| wcf | cf | 0 | Width dependence of cf |
| wclc | clc | 0 | Width dependence of clc |
| wcle | cle | 0 | Width dependence of cle |
| walpha0 | alpha0 | 0 | Width dependence of alpha0 |
| walpha1 | alpha1 | 0 | Width dependence of alpha1 |
| wbeta0 | beta0 | 0 | Width dependence of beta0 |
| wvfbcv | vfbcv | 0 | Width dependence of vfbcv |
| wvfb | vfb | 0 | Width dependence of vfb |
| wacde | acde | 0 | Width dependence of acde |
| wmoin | moin | 0 | Width dependence of moin |
| wnoff | noff | 0 | Width dependence of noff |
| wvoffcv | voffcv | 0 | Width dependence of voffcv |

### Cross-term (L*W) Dependence Parameters

All default to 0. Effective parameter: $P_{eff} = P + LP/L + WP/W + PP/(L \cdot W)$.

| Parameter | Base Param | Default | Description |
|-----------|------------|---------|-------------|
| pcdsc | cdsc | 0 | Cross-term dependence of cdsc |
| pcdscb | cdscb | 0 | Cross-term dependence of cdscb |
| pcdscd | cdscd | 0 | Cross-term dependence of cdscd |
| pcit | cit | 0 | Cross-term dependence of cit |
| pnfactor | nfactor | 0 | Cross-term dependence of nfactor |
| pxj | xj | 0 | Cross-term dependence of xj |
| pvsat | vsat | 0 | Cross-term dependence of vsat |
| pat | at | 0 | Cross-term dependence of at |
| pa0 | a0 | 0 | Cross-term dependence of a0 |
| pags | ags | 0 | Cross-term dependence of ags |
| pa1 | a1 | 0 | Cross-term dependence of a1 |
| pa2 | a2 | 0 | Cross-term dependence of a2 |
| pketa | keta | 0 | Cross-term dependence of keta |
| pnsub | nsub | 0 | Cross-term dependence of nsub |
| pnch | nch | 0 | Cross-term dependence of nch |
| pngate | ngate | 0 | Cross-term dependence of ngate |
| pgamma1 | gamma1 | 0 | Cross-term dependence of gamma1 |
| pgamma2 | gamma2 | 0 | Cross-term dependence of gamma2 |
| pvbx | vbx | 0 | Cross-term dependence of vbx |
| pvbm | vbm | 0 | Cross-term dependence of vbm |
| pxt | xt | 0 | Cross-term dependence of xt |
| pk1 | k1 | 0 | Cross-term dependence of k1 |
| pkt1 | kt1 | 0 | Cross-term dependence of kt1 |
| pkt1l | kt1l | 0 | Cross-term dependence of kt1l |
| pkt2 | kt2 | 0 | Cross-term dependence of kt2 |
| pk2 | k2 | 0 | Cross-term dependence of k2 |
| pk3 | k3 | 0 | Cross-term dependence of k3 |
| pk3b | k3b | 0 | Cross-term dependence of k3b |
| pw0 | w0 | 0 | Cross-term dependence of w0 |
| pnlx | nlx | 0 | Cross-term dependence of nlx |
| pdvt0 | dvt0 | 0 | Cross-term dependence of dvt0 |
| pdvt1 | dvt1 | 0 | Cross-term dependence of dvt1 |
| pdvt2 | dvt2 | 0 | Cross-term dependence of dvt2 |
| pdvt0w | dvt0w | 0 | Cross-term dependence of dvt0w |
| pdvt1w | dvt1w | 0 | Cross-term dependence of dvt1w |
| pdvt2w | dvt2w | 0 | Cross-term dependence of dvt2w |
| pdrout | drout | 0 | Cross-term dependence of drout |
| pdsub | dsub | 0 | Cross-term dependence of dsub |
| pvth0 | vth0 | 0 | Cross-term dependence of vth0 |
| pua | ua | 0 | Cross-term dependence of ua |
| pua1 | ua1 | 0 | Cross-term dependence of ua1 |
| pub_ | ub | 0 | Cross-term dependence of ub |
| pub1 | ub1 | 0 | Cross-term dependence of ub1 |
| puc | uc | 0 | Cross-term dependence of uc |
| puc1 | uc1 | 0 | Cross-term dependence of uc1 |
| pu0 | u0 | 0 | Cross-term dependence of u0 |
| pute | ute | 0 | Cross-term dependence of ute |
| pvoff | voff | 0 | Cross-term dependence of voff |
| pelm | elm | 0 | Cross-term dependence of elm |
| pdelta | delta | 0 | Cross-term dependence of delta |
| prdsw | rdsw | 0 | Cross-term dependence of rdsw |
| pprwg | prwg | 0 | Cross-term dependence of prwg |
| pprwb | prwb | 0 | Cross-term dependence of prwb |
| pprt | prt | 0 | Cross-term dependence of prt |
| peta0 | eta0 | 0 | Cross-term dependence of eta0 |
| petab | etab | 0 | Cross-term dependence of etab |
| ppclm | pclm | 0 | Cross-term dependence of pclm |
| ppdiblc1 | pdiblc1 | 0 | Cross-term dependence of pdiblc1 |
| ppdiblc2 | pdiblc2 | 0 | Cross-term dependence of pdiblc2 |
| ppdiblcb | pdiblcb | 0 | Cross-term dependence of pdiblcb |
| ppscbe1 | pscbe1 | 0 | Cross-term dependence of pscbe1 |
| ppscbe2 | pscbe2 | 0 | Cross-term dependence of pscbe2 |
| ppvag | pvag | 0 | Cross-term dependence of pvag |
| pwr | wr | 0 | Cross-term dependence of wr |
| pdwg | dwg | 0 | Cross-term dependence of dwg |
| pdwb | dwb | 0 | Cross-term dependence of dwb |
| pb0 | b0 | 0 | Cross-term dependence of b0 |
| pb1 | b1 | 0 | Cross-term dependence of b1 |
| pcgsl | cgsl | 0 | Cross-term dependence of cgsl |
| pcgdl | cgdl | 0 | Cross-term dependence of cgdl |
| pckappa | ckappa | 0 | Cross-term dependence of ckappa |
| pcf | cf | 0 | Cross-term dependence of cf |
| pclc | clc | 0 | Cross-term dependence of clc |
| pcle | cle | 0 | Cross-term dependence of cle |
| palpha0 | alpha0 | 0 | Cross-term dependence of alpha0 |
| palpha1 | alpha1 | 0 | Cross-term dependence of alpha1 |
| pbeta0 | beta0 | 0 | Cross-term dependence of beta0 |
| pvfbcv | vfbcv | 0 | Cross-term dependence of vfbcv |
| pvfb | vfb | 0 | Cross-term dependence of vfb |
| pacde | acde | 0 | Cross-term dependence of acde |
| pmoin | moin | 0 | Cross-term dependence of moin |
| pnoff | noff | 0 | Cross-term dependence of noff |
| pvoffcv | voffcv | 0 | Cross-term dependence of voffcv |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| noia | $NOIA$ | -- | 1e20 | -- | Flicker noise parameter (noimod=2) |
| noib | $NOIB$ | -- | 5e4 | -- | Flicker noise parameter (noimod=2) |
| noic | $NOIC$ | -- | -1.4e-12 | -- | Flicker noise parameter (noimod=2) |
| em | $E_M$ | V/m | 4.1e7 | >0 | Flicker noise parameter |
| ef | $E_F$ | -- | 1 | -- | Flicker noise frequency exponent |
| af | $A_F$ | -- | 1 | -- | Flicker noise exponent (noimod=1) |
| kf | $K_F$ | -- | 0 | >=0 | Flicker noise coefficient (noimod=1) |

### Maximum Voltage Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| vgs_max | $V_{GS,max}$ | V | +inf | >0 | Maximum voltage G-S branch |
| vgd_max | $V_{GD,max}$ | V | +inf | >0 | Maximum voltage G-D branch |
| vgb_max | $V_{GB,max}$ | V | +inf | >0 | Maximum voltage G-B branch |
| vds_max | $V_{DS,max}$ | V | +inf | >0 | Maximum voltage D-S branch |
| vbs_max | $V_{BS,max}$ | V | +inf | >0 | Maximum voltage B-S branch |
| vbd_max | $V_{BD,max}$ | V | +inf | >0 | Maximum voltage B-D branch |
| vgsr_max | $V_{GSR,max}$ | V | +inf | >0 | Maximum voltage G-S branch (reverse) |
| vgdr_max | $V_{GDR,max}$ | V | +inf | >0 | Maximum voltage G-D branch (reverse) |
| vgbr_max | $V_{GBR,max}$ | V | +inf | >0 | Maximum voltage G-B branch (reverse) |
| vbsr_max | $V_{BSR,max}$ | V | +inf | >0 | Maximum voltage B-S branch (reverse) |
| vbdr_max | $V_{BDR,max}$ | V | +inf | >0 | Maximum voltage B-D branch (reverse) |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| w | $W$ | m | 1e-6 | >0 | Channel width |
| l | $L$ | m | 1e-6 | >0 | Channel length |
| temp | $T$ | K | 300.15 | >0 | Instance temperature |
| m | $M$ | -- | 1.0 | >0 | Parallel multiplier |
| ad | $A_D$ | m^2 | 0 | >=0 | Drain area |
| as_ | $A_S$ | m^2 | 0 | >=0 | Source area |
| pd | $P_D$ | m | 0 | >=0 | Drain perimeter |
| ps | $P_S$ | m | 0 | >=0 | Source perimeter |
| nrd | $NRD$ | -- | 0 | >=0 | Number of drain squares |
| nrs | $NRS$ | -- | 0 | >=0 | Number of source squares |

## Equations

### Physical Constants

$$\epsilon_{Si} = 1.03594 \times 10^{-10} \text{ F/m}$$

$$\epsilon_{ox} = 3.453133 \times 10^{-11} \text{ F/m}$$

$$q = 1.60219 \times 10^{-19} \text{ C}$$

$$k_B/q = 8.617333262145 \times 10^{-5} \text{ eV/K}$$

$$n_i = 1.45 \times 10^{10} \text{ cm}^{-3}$$

Intrinsic carrier concentration of silicon at 300 K.

### Terminal Voltage Preparation

$$V_{GS,typed} = (V_G - V_S) \cdot \text{type}$$

$$V_{DS,typed} = (V_D - V_S) \cdot \text{type}$$

$$V_{BS,typed} = (V_B - V_S) \cdot \text{type}$$

PMOS type sign: `type_ = -1` negates all terminal voltages.

#### Source-Drain Reversal (Branchless)

$$V_{DS} = |V_{DS,typed}|$$

$$V_{GS} = V_{GS,typed} - \min(V_{DS,typed},\; 0)$$

$$V_{BS} = V_{BS,typed} - \min(V_{DS,typed},\; 0)$$

$$V_{BD} = V_{BS} - V_{DS}$$

Swaps source/drain references when $V_{DS,typed} < 0$ without branching (autodiff-safe).

### Thermal Voltage

$$V_{tm} = \frac{k_B}{q} \cdot T_{inst}$$

Instance temperature used (not tnom).

### Oxide Capacitance

$$C_{ox} = \frac{\epsilon_{ox}}{T_{ox}}$$

### Effective Geometry

$$L_{eff} = \max(L - 2 \cdot LINT,\; 10^{-9})$$

$$W_{eff} = \max(W - 2 \cdot WINT,\; 10^{-9})$$

### Junction Diode Currents

$$N V_{tm} = V_{tm} \cdot N_J$$

$$A_{jct} = W_{eff} \cdot 10^{-6}$$

$$I_{S,source} = J_S \cdot A_{jct} + 10^{-14}$$

$$I_{S,drain} = J_S \cdot A_{jct} + 10^{-14}$$

#### Source Junction

$$I_{BS} = I_{S,source} \left( \exp\!\left[\min\!\left(\frac{V_{BS}}{N V_{tm}},\; 80\right)\right] - 1 \right)$$

Exponent clamped to 80 to prevent overflow.

#### Drain Junction

$$I_{BD} = I_{S,drain} \left( \exp\!\left[\min\!\left(\frac{V_{BD}}{N V_{tm}},\; 80\right)\right] - 1 \right)$$

### Surface Potential and Body Effect

#### Surface Potential $\phi_s$

$$\phi = 2 V_{tm} \ln\!\left(\frac{N_{ch}}{n_i}\right)$$

$$\sqrt{\phi} = \sqrt{\phi}$$

#### Effective Body Voltage $V_{BS,eff}$ (Smooth Limiting)

$$V_{BSC} = -0.9 \cdot \phi$$

**Reverse bias path** ($V_{BS} < 0$):

$$T_0 = V_{BS} - V_{BSC} - 0.001$$

$$T_1 = \sqrt{T_0^2 - 0.004 \cdot V_{BSC}}$$

$$V_{BS,rev} = V_{BSC} + \frac{1}{2}(T_0 + T_1)$$

**Forward bias path** ($V_{BS} \ge 0$):

$$V_{BS,fwd} = \phi - \frac{\phi^2}{\max(\phi + V_{BS},\; 0.001)}$$

**Blending**: uses reverse path when $V_{BS} < 0$, forward path otherwise.

#### Phis

$$\Phi_s = \max(\phi - V_{BS,eff},\; 10^{-30})$$

$$\sqrt{\Phi_s} = \sqrt{\Phi_s}$$

### Depletion Width

$$X_{dep0,bare} = \sqrt{\frac{2\epsilon_{Si}}{q \cdot N_{ch} \cdot 10^6}}$$

$$X_{dep0} = X_{dep0,bare} \cdot \sqrt{\phi}$$

$$X_{dep} = X_{dep0,bare} \cdot \sqrt{\Phi_s}$$

$X_{dep0}$ is the nominal (zero-bias) depletion width; $X_{dep}$ tracks bias through $\Phi_s$.

### Threshold Voltage $V_{th}$

#### Short Channel Effect (SCE)

$$\text{factor1} = \sqrt{\frac{\epsilon_{Si}}{\epsilon_{ox}} \cdot T_{ox}}$$

$$lt_1 = \text{factor1} \cdot \sqrt{X_{dep}} \cdot (1 + DVT2 \cdot V_{BS,eff})$$

$$\Theta_0 = \exp\!\left[\max\!\left(\frac{-0.5 \cdot DVT1 \cdot L_{eff}}{lt_1},\; -34\right)\right] \cdot \left(1 + 2\exp\!\left[\cdots\right]\right)$$

$$V_{bi} = V_{tm} \cdot \ln\!\left(\frac{10^{20} \cdot N_{ch}}{n_i^2}\right)$$

$$V_0 = V_{bi} - \phi$$

$$\Delta V_{th,SCE} = DVT0 \cdot \Theta_0 \cdot V_0$$

#### DIBL Shift

$$T_{1,nom} = \sqrt{\frac{\epsilon_{Si}}{\epsilon_{ox}} \cdot T_{ox} \cdot X_{dep0}}$$

$$T_{0,dsub} = \exp\!\left[\max\!\left(\frac{-0.5 \cdot D_{SUB} \cdot L_{eff}}{T_{1,nom}},\; -34\right)\right]$$

$$\Theta_{0vb0} = T_{0,dsub} \cdot (1 + 2 T_{0,dsub})$$

$$\eta = \eta_0 + \eta_b \cdot V_{BS,eff}$$

$$\text{DIBL}_{sft} = \eta \cdot \Theta_{0vb0} \cdot V_{DS}$$

#### NLX Correction and Temperature Adjustment

$$\text{NLX}_{term} = K_{1,ox} \left(\sqrt{1 + \frac{NLX}{L_{eff}}} - 1\right) \sqrt{\phi}$$

$$T_{ratio} = \frac{T_{inst}}{T_{nom}} - 1$$

$$T_{V_{th}} = \text{NLX}_{term} + \left(K_{t1} + \frac{K_{t1l}}{L_{eff}} + K_{t2} \cdot V_{BS,eff}\right) \cdot T_{ratio}$$

where:

$$K_{1,ox} = K_1 \cdot \frac{T_{ox}}{T_{oxm}}, \quad K_{2,ox} = K_2 \cdot \frac{T_{ox}}{T_{oxm}}$$

#### Narrow Width Effect

$$T_{0,NW} = \exp\!\left[\max\!\left(\frac{-0.5 \cdot DVT1W \cdot W_{eff} \cdot L_{eff}}{T_{1,nom}},\; -34\right)\right]$$

$$\Theta_{NW} = T_{0,NW} \cdot (1 + 2 T_{0,NW})$$

$$\text{Narrow}_{sft} = DVT0W \cdot \Theta_{NW} \cdot V_0$$

Skip if $DVT0W = 0$.

#### Narrow Width Contribution via $K_3$

$$\text{tmp2}_W = \frac{T_{ox} \cdot \phi}{W_{eff} + W_0}$$

#### Full $V_{th}$

$$V_{th} = V_{TH0} - K_1 \sqrt{\phi} + K_{1,ox}\sqrt{\Phi_s} - K_{2,ox} V_{BS,eff} - \Delta V_{th,SCE} - \text{Narrow}_{sft} + (K_3 + K_{3b} V_{BS,eff}) \cdot \text{tmp2}_W + T_{V_{th}} - \text{DIBL}_{sft}$$

### Subthreshold Slope Factor $n$

$$n = \max\!\left(1 + \frac{N_{factor} \cdot \epsilon_{Si} / X_{dep} + (C_{dsc} + C_{dscd} \cdot V_{DS} + C_{dscb} \cdot V_{BS,eff}) \cdot \Theta_0 + C_{it}}{C_{ox}},\;\; 0.5\right)$$

### Effective Gate Overdrive $V_{gst,eff}$ (Subthreshold Smoothing)

$$V_{gst} = V_{GS} - V_{th}$$

$$T_{10} = 2 n V_{tm}$$

$$V_{gstNVt} = \frac{V_{gst} - V_{OFF}}{T_{10}}$$

$$V_{gst,eff} = \max\!\left(T_{10} \cdot \ln\!\left(1 + \exp\!\left[\min(V_{gstNVt},\; 80)\right]\right),\;\; 10^{-20}\right)$$

Smooth $\log(1+\exp)$ form: for $x > 80$, $\ln(1+e^x) \approx x$.

### Effective Channel Width (Bias-Dependent)

$$W_{eff,dyn} = \max\!\left(W_{eff} - 2\left(DWG \cdot V_{gst,eff} + DWB \cdot (\sqrt{\Phi_s} - \sqrt{\phi})\right),\;\; 2 \times 10^{-8}\right)$$

### Source-Drain Resistance $R_{ds}$

$$R_{ds0} = \frac{R_{DSW}}{(W_{eff} \cdot 10^6)^{W_R}}$$

$$R_{ds} = R_{ds0} \cdot \left(1 + P_{RWG} \cdot V_{gst,eff} + P_{RWB} \cdot (\sqrt{\Phi_s} - \sqrt{\phi})\right)$$

### Bulk Charge Effect $A_{bulk}$

$$T_1 = \frac{K_{1,ox}}{2\sqrt{\Phi_s}}$$

$$T_5 = \frac{L_{eff}}{L_{eff} + 2\sqrt{X_j \cdot X_{dep}}}$$

$$T_2 = A_0 \cdot T_5 + \frac{B_0}{W_{eff} + B_1}$$

$$A_{bulk,0} = 1 + T_1 \cdot T_2$$

$$T_8 = A_{GS} \cdot A_0 \cdot T_5^3$$

$$A_{bulk} = \max\!\left(\frac{A_{bulk,0} - T_1 \cdot T_8 \cdot V_{gst,eff}}{1 + K_{eta} \cdot V_{BS,eff}},\;\; 0.1\right)$$

Both $A_{bulk,0}$ and $A_{bulk}$ are clamped to $\ge 0.1$. The denominator $(1 + K_{eta} V_{BS,eff})$ is clamped to $\ge 0.1$.

### Mobility $\mu_{eff}$ (mobMod=1)

$$T_0 = V_{gst,eff} + 2V_{th}$$

$$T_3 = \frac{T_0}{T_{ox}}$$

$$T_5 = T_3 \cdot \left((U_a + U_c \cdot V_{BS,eff}) + U_b \cdot T_3\right)$$

$$\mu_{eff} = \frac{\mu_0}{\max(1 + T_5,\; 0.2)}$$

### Saturation Velocity and $E_{sat}$

$$E_{sat} = \frac{2 v_{sat}}{\mu_{eff}}$$

$$E_{sat}L = E_{sat} \cdot L_{eff}$$

$$V_{gst2Vtm} = V_{gst,eff} + 2 V_{tm}$$

### Saturation Voltage $V_{dsat}$

$$\Lambda = A_1 \cdot V_{gst2Vtm} + A_2$$

$$WVC_{oxRds} = W_{eff,dyn} \cdot v_{sat} \cdot C_{ox} \cdot R_{ds}$$

$$V_{dsat} = \max\!\left(\frac{E_{sat}L \cdot V_{gst2Vtm}}{A_{bulk} \cdot E_{sat}L + V_{gst2Vtm}(1 + WVC_{oxRds})} \cdot \Lambda,\;\; 10^{-20}\right)$$

### Effective Drain Voltage $V_{DS,eff}$ (Smooth Saturation Clamp)

$$T_1 = V_{dsat} - V_{DS} - \delta$$

$$T_2 = \sqrt{T_1^2 + 4\delta \cdot V_{dsat}}$$

$$V_{DS,eff} = \min\!\left(V_{dsat} - \frac{1}{2}(T_1 + T_2),\;\; |V_{DS}|\right)$$

Smooth $\min(V_{DS}, V_{dsat})$ via hyperbolic construction with parameter $\delta$.

$$\Delta V_{DS} = V_{DS} - V_{DS,eff}$$

### Channel Length Modulation (VACLM)

$$\text{litl} = \sqrt{3 \cdot X_j \cdot T_{ox}}$$

$$VA_{CLM} = \max\!\left(\frac{L_{eff} \cdot (A_{bulk} + V_{gst,eff}/E_{sat}L)}{P_{CLM} \cdot \text{litl}/L_{eff}},\;\; 10^{-20}\right)$$

Set to $5.835 \times 10^{14}$ (MAX_EXP_VAL) when $P_{CLM} = 0$.

### DIBL Output Resistance (VADIBL)

$$T_{0,drout} = \exp\!\left[\max\!\left(\frac{-0.5 \cdot D_{ROUT} \cdot L_{eff}}{T_{1,nom}},\; -34\right)\right]$$

$$\Theta_{Rout} = P_{DIBLC1} \cdot T_{0,drout} \cdot (1 + 2 T_{0,drout}) + P_{DIBLC2}$$

$$VA_{DIBL} = \max\!\left(\frac{V_{gst2Vtm} - \frac{A_{bulk} \cdot V_{dsat} \cdot V_{gst2Vtm}}{V_{gst2Vtm} + A_{bulk} \cdot V_{dsat}}}{\Theta_{Rout}} \cdot \frac{1}{1 + P_{DIBLCb} \cdot V_{BS,eff}},\;\; 10^{-20}\right)$$

Set to MAX_EXP_VAL when $\Theta_{Rout} \le 0$. The body-bias denominator $(1 + P_{DIBLCb} V_{BS,eff})$ clamped to $\ge 0.1$.

### PVAG Effect

$$VA_{PVAG} = \max\!\left(1 + \frac{P_{VAG}}{E_{sat}L} \cdot V_{gst,eff},\;\; 0.1\right)$$

### Combined Early Voltage $V_A$

#### Vasat

$$VA_{sat} = \frac{E_{sat}L + V_{dsat} + 2 WVC_{oxRds} \cdot V_{gst,eff} \cdot \left(1 - \frac{A_{bulk} \cdot V_{dsat}}{2 V_{gst2Vtm}}\right)}{\frac{2}{\Lambda} - 1 + WVC_{oxRds} \cdot A_{bulk}}$$

#### Harmonic Combination

$$\frac{1}{V_A} = \frac{1}{VA_{sat}} + \frac{1}{VA_{CLM}} + \frac{1}{VA_{DIBL}}$$

$$V_A = \max\!\left(\frac{VA_{PVAG}}{1/VA_{sat} + 1/VA_{CLM} + 1/VA_{DIBL}},\;\; 10^{-20}\right)$$

### Substrate Current Body Effect (VASCBE)

$$VA_{SCBE} = \frac{L_{eff} \cdot \exp\!\left[\min\!\left(\frac{P_{SCBE1} \cdot \text{litl}}{\Delta V_{DS} + 10^{-20}},\; 80\right)\right]}{P_{SCBE2}} + 10^{-20}$$

Set to MAX_EXP_VAL when $P_{SCBE2} = 0$.

### Drain Current $I_{DS}$

$$\beta = \mu_{eff} \cdot C_{ox} \cdot \frac{W_{eff,dyn}}{L_{eff}}$$

$$f_{gche1} = V_{gst,eff} \left(1 - \frac{A_{bulk} \cdot V_{DS,eff}}{2 V_{gst2Vtm}}\right)$$

$$f_{gche2} = 1 + \frac{V_{DS,eff}}{E_{sat}L}$$

$$g_{che} = \frac{\beta \cdot f_{gche1}}{f_{gche2}}$$

$$I_{DL} = \frac{g_{che} \cdot V_{DS,eff}}{1 + g_{che} \cdot R_{ds}}$$

Channel current with velocity saturation and source-drain resistance.

$$I_{DSA} = I_{DL} \cdot \left(1 + \frac{\Delta V_{DS}}{V_A}\right)$$

CLM + DIBL correction.

$$I_{DS} = I_{DSA} \cdot \left(1 + \frac{\Delta V_{DS}}{VA_{SCBE}}\right)$$

SCBE correction.

### Substrate Current $I_{sub}$

$$\alpha_{eff} = \alpha_0 + \alpha_1 \cdot L_{eff}$$

$$I_{sub} = \frac{\alpha_{eff}}{L_{eff}} \cdot \Delta V_{DS} \cdot \exp\!\left[\max\!\left(\frac{-\beta_0}{\Delta V_{DS} + 10^{-20}},\; -80\right)\right] \cdot I_{DSA}$$

Zero when $\alpha_{eff} \le 0$ or $\beta_0 \le 0$.

### KCL Terminal Currents

Internal NMOS-equivalent frame (before source-drain unswap and PMOS flip):

$$I_{drain,int} = (I_{DS} - I_{BD} + I_{sub}) \cdot M$$

$$I_{source,int} = (-I_{DS} - I_{BS}) \cdot M$$

$$I_{bulk,int} = (I_{BD} + I_{BS} - I_{sub}) \cdot M$$

#### Source-Drain Unswap and Type Flip

$$\text{mode} = \frac{V_{DS,typed}}{|V_{DS,typed}| + 10^{-30}}$$

$$I_{drain,ext} = \text{mode} \cdot I_{drain,int} \cdot \text{type}$$

$$I_{source,ext} = \text{mode} \cdot I_{source,int} \cdot \text{type}$$

$$I_{bulk,ext} = I_{bulk,int} \cdot \text{type}$$

### GMIN Parasitic Conductance

$$g_{min} = 10^{-12} \text{ S}$$

Applied on raw (physical) terminal voltages:

$$I_{gmin,DS} = (V_D - V_S) \cdot g_{min}$$

$$I_{gmin,GS} = (V_G - V_S) \cdot g_{min}$$

$$I_{gmin,BS} = (V_B - V_S) \cdot g_{min}$$

#### Final KCL Stamps

$$I_D = I_{drain,ext} + I_{gmin,DS}$$

$$I_G = I_{gmin,GS}$$

$$I_S = I_{source,ext} - I_{gmin,DS} - I_{gmin,GS} - I_{gmin,BS}$$

$$I_B = I_{bulk,ext} + I_{gmin,BS}$$

### Charge Model (q function)

#### Gate Overlap Charges

$$Q_{GDO} = C_{GDO} \cdot W_{eff} \cdot V_{GD}$$

$$Q_{GSO} = C_{GSO} \cdot W_{eff} \cdot V_{GS}$$

$$Q_{GBO} = C_{GBO} \cdot L_{eff} \cdot V_{GB}$$

#### Effective Body Voltage for CV

$$V_{BS,eff,CV} = \phi - \max(-V_{BS},\; 0)$$

#### Threshold Voltage for CV (capMod=0)

$$\sqrt{\Phi_{s,CV}} = \sqrt{\max(\phi - V_{BS,eff,CV},\; 10^{-30})}$$

$$V_{th,CV} = V_{FBCV} + \phi + K_1 \cdot \sqrt{\Phi_{s,CV}}$$

#### Gate Overdrive for CV

$$V_{gst,CV} = V_{GS} - V_{th,CV}$$

$$V_{gst,eff,CV} = \max\!\left(2V_{tm} \cdot \ln\!\left(1 + \exp\!\left[\min\!\left(\frac{V_{gst,CV}}{2V_{tm}},\; 80\right)\right]\right),\; 10^{-20}\right)$$

#### Saturation Voltage for CV

$$V_{dsat,CV} = \frac{\max(V_{gst,CV},\; 0.001)}{A_{bulk,CV}}$$

where $A_{bulk,CV} = 1$ (simplified).

#### Effective $V_{DS}$ for CV

$$V_4 = V_{dsat,CV} - V_{DS} - 0.02$$

$$V_{DS,eff,CV} = \max\!\left(V_{dsat,CV} - \frac{1}{2}\left(V_4 + \sqrt{V_4^2 + 4 \cdot 0.02 \cdot V_{dsat,CV}}\right),\; 0\right)$$

#### Intrinsic Charges

$$T_0 = A_{bulk,CV} \cdot V_{DS,eff,CV}$$

$$T_1 = 12 \cdot (V_{gst,eff,CV} - \tfrac{1}{2} T_0 + 10^{-20})$$

$$T_3 = \frac{T_0 \cdot V_{DS,eff,CV}}{T_1}$$

$$Q_{gate,intr} = C_{ox} W_{eff} L_{eff} \cdot \left(V_{gst,eff,CV} - \frac{1}{2}V_{DS,eff,CV} + T_3\right)$$

$$Q_{bulk,intr} = C_{ox} W_{eff} L_{eff} \cdot (1 - A_{bulk,CV}) \cdot \left(\frac{1}{2}V_{DS,eff,CV} - T_3\right)$$

$$Q_{src,intr} = -\frac{1}{2}(Q_{gate,intr} + Q_{bulk,intr})$$

50/50 charge partition (xpart=0 default).

$$Q_{drn,intr} = -(Q_{gate,intr} + Q_{bulk,intr} + Q_{src,intr})$$

#### Junction Depletion Charges

For $V < P_B$ (reverse bias):

$$Q_J = \frac{P_B \cdot C_J \cdot A_{jct}}{1 - M_J} \left(1 - \left(1 - \frac{V}{P_B}\right)^{1-M_J}\right)$$

Applied to both source ($V = V_{BS}$) and drain ($V = V_{BD}$) junctions. The ratio $(1 - V/P_B)$ is clamped to $\ge 10^{-30}$.

#### Total Terminal Charges

$$Q_G = (Q_{gate,intr} + Q_{GDO} + Q_{GSO} + Q_{GBO}) \cdot M$$

$$Q_D = (Q_{drn,intr} - Q_{GDO} - Q_{BD,jct}) \cdot M$$

$$Q_B = (Q_{bulk,intr} - Q_{GBO} + Q_{BD,jct} + Q_{BS,jct}) \cdot M$$

$$Q_S = -(Q_G + Q_D + Q_B)$$

Charge conservation enforced by computing $Q_S$ as the negative sum.

### Newton Limiting Functions

#### DEVfetlim (Gate Voltage Limiting)

$$V_{tsthi} = |2(V_{old} - V_{TO})| + 2$$

$$V_{tstlo} = \frac{V_{tsthi}}{2} + 2$$

$$V_{tox} = V_{TO} + 3.5$$

Piecewise clamp of $V_{new}$:
- **$V_{old} \ge V_{tox}$, going down**: $V_{new} \ge \max(V_{new}, V_{old} - V_{tsthi})$
- **$V_{old} \ge V_{tox}$, going up**: $V_{new} \le V_{old} + V_{tsthi}$
- **$V_{TO} \le V_{old} < V_{tox}$**: clamp within $[V_{old} - V_{tstlo},\; V_{old} + V_{tstlo}]$
- **$V_{old} < V_{TO}$, going up past $V_{TO}+0.5$**: cap at $V_{TO} + 0.5$
- **$V_{old} < V_{TO}$**: clamp within $[V_{old} - V_{tstlo},\; V_{old} + V_{tstlo}]$

#### DEVlimvds (Drain-Source Voltage Limiting)

Piecewise clamp:
- **$V_{old} \ge 3.5$, increasing**: $V_{new} \le 3 V_{old} + 2$
- **$V_{old} \ge 3.5$, decreasing below 3.5**: $V_{new} \ge 2$
- **$V_{old} < 3.5$, increasing**: $V_{new} \le 4$
- **$V_{old} < 3.5$, decreasing**: $V_{new} \ge -0.5$

#### DEVpnjlim (PN Junction Voltage Limiting)

$$V_{crit} = V_t \cdot \ln\!\left(\frac{V_t}{\sqrt{2} \cdot (J_S \cdot 10^{-6} + 10^{-14})}\right)$$

When $V_{new} > V_{crit}$ and $|V_{new} - V_{old}| > 2 V_t$:
- **$V_{old} > 0$, $\Delta V > 0$**: $V_{lim} = V_{old} + V_t \cdot (2 + \ln(\Delta V / V_t - 2))$
- **$V_{old} > 0$, $\Delta V < 0$**: $V_{lim} = V_{old} - V_t \cdot (2 + \ln(2 - \Delta V / V_t))$
- **$V_{old} \le 0$**: $V_{lim} = V_t \cdot \ln(V_{new} / V_t)$

Otherwise $V_{lim} = V_{new}$ (no limiting).

Applied to $V_{BS}$ and $V_{BD}$ junction voltages each Newton iteration.
