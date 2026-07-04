# BSIM-SOI 100.1.1 — Parameter & Equation Reference

> SOI MOSFET (symmetric)

## Model Topology

BSIM-SOI 100.1.1 models a Silicon-On-Insulator MOSFET with five external terminals: gate (G), drain (D), source (S), substrate/back-gate (E), and optional body contact (B). An optional thermal node (T) supports self-heating via an RC thermal network. The body potential is either iterated internally (floating body, BODYMOD=0) or set via a body resistance network (BODYMOD=1 or 2). Two operational modes exist: SOIMOD=1 for dynamically depleted (DD) SOI with surface-potential-based core, and SOIMOD=0 for partially depleted (PD) SOI built on the BSIM-BULK 107.1.0 framework.

---

## Parameters

### Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| L | m | 1e-5 | — | Channel length |
| W | m | 1e-5 | — | Total width including fingers |
| NF | — | 1 | [1, inf] | Number of fingers |
| NRS | — | 1 | — | Number of squares in source |
| NRD | — | 1 | — | Number of squares in drain |
| VFBSDOFF | V | 0 | — | Flatband voltage offset |
| MINZ | — | 0 | [0, 1] | Minimize either drain or source |
| RGATEMOD | — | 0 | [0, 3] | Gate resistance model selector |
| GEOMOD | — | 0 | [0, 10] | Geometry-dependent parasitics model |
| RGEOMOD | — | 0 | [0, 8] | Geometry-dependent S/D resistance |
| SA | m | 0 | — | Distance from OD edge to poly (one side) |
| SB | m | 0 | — | Distance from OD edge to poly (other side) |
| SD | m | 0 | — | Distance between neighboring fingers |
| SCA | — | 0 | [-inf, inf] | Integral of 1st distribution function for scattered well dopants |
| SCB | — | 0 | [-inf, inf] | Integral of 2nd distribution function for scattered well dopants |
| SCC | — | 0 | [-inf, inf] | Integral of 3rd distribution function for scattered well dopants |
| SC | m | 0 | [-inf, inf] | Distance to single well edge (<=0 turns off WPE) |
| AS | m^2 | 0 | — | Source-to-body junction area |
| AD | m^2 | 0 | — | Drain-to-body junction area |
| PS | m | 0 | — | Source-to-body junction perimeter |
| PD | m | 0 | — | Drain-to-body junction perimeter |

### Both Model and Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| XGW | m | 0 | — | Distance from gate contact center to device edge |
| NGCON | — | 1 | [1, 2] | Number of gate contacts |
| DTEMP | K | 0 | — | Offset of device temperature |
| MULU0 | m^2/(V*s) | 1 | — | Multiplication factor for low field mobility |
| DELVTO | V | 0 | — | Zero bias threshold voltage variation |
| IDS0MULT | — | 1 | — | Variability in drain current |
| EDGEFET | — | 0 | [0, 1] | 0: Edge FET OFF, 1: Edge FET ON |
| SSLMOD | — | 0 | [0, 1] | Sub-surface leakage drain current selector |

### Model Selectors/Controllers

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SOIMOD | — | 0 | [0, 1] | 0: PDSOI mode, 1: DDSOI mode |
| TYPE | — | ntype | — | N-type=1, P-type=-1 |
| CVMOD | — | 0 | [0, 1] | 0: Consistent I-V/C-V, 1: Different I-V/C-V |
| COVMOD | — | 0 | [0, 1] | 0: Bias-independent overlap cap, 1: Bias-dependent |
| RDSMOD | — | 0 | [0, 2] | S/D resistance model selector |
| WPEMOD | — | 0 | [0, 1] | Well proximity effect model flag |
| ASYMMOD | — | 0 | [0, 1] | 0: Asymmetry OFF, 1: Asymmetry ON |
| GIDLMOD | — | 0 | [0, 1] | GIDL current model selector |
| IGCMOD | — | 0 | [0, 1] | Gate-to-channel current selector |
| IGBMOD | — | 0 | [0, 1] | Gate-to-body current selector |
| TNOIMOD | — | 0 | [0, 1] | Thermal noise model selector |
| TNODEOUT | — | 0 | [0, 1] | External temperature node flag |
| SHMOD | — | 0 | [0, 1] | Self heating model selector |
| MOBSCALE | — | 0 | [0, 1] | Mobility scaling model (0: Old, 1: New) |
| BODYMOD | — | 0 | [0, 2] | Body contact mode (0: floating, 1: linear RB, 2: nonlinear RB) |
| IIIMOD | — | 0 | [0, 2] | Impact ionization model selector |
| MODAGBCP2 | — | 0 | [0, 1] | AGBCP2 model ON/OFF |
| PDEMOD | — | 0 | [0, 1] | Poly depletion effect for DD model |
| FBODY1 | — | 0 | [0, 1] | Extrinsic S/D substrate charge ON/OFF |
| BINUNIT | — | 1 | — | Binning unit (1: um, 0: default) |
| FNOIMOD | — | 0 | [0, 1] | Flicker noise model selector |

### Basic Model Parameters — Geometry

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DLBIN | — | 0 | — | Length reduction for binning |
| DWBIN | — | 0 | — | Width reduction for binning |
| LLONG | m | 1e-5 | — | L of extracted long channel device |
| LMLT | — | 1 | — | Length shrinking parameter |
| WMLT | — | 1 | — | Width shrinking parameter |
| XL | m | 0 | — | L offset due to mask/etch effect |
| WWIDE | m | 1e-5 | — | W of extracted wide channel device |
| XW | m | 0 | — | W offset due to mask/etch effect |
| LINT | m | 0 | — | Delta L for I-V |
| LL | m^(1+LLN) | 0 | — | Length reduction parameter |
| LW | m^(1+LWN) | 0 | — | Length reduction parameter (binnable; scaling: LWL) |
| LLN | — | 1 | — | Length reduction parameter |
| LWN | — | 1 | — | Length reduction parameter |
| WINT | m | 0 | — | Delta W for I-V |
| WL | m^(1+WLN) | 0 | — | Width reduction parameter |
| WW | m^(1+WWN) | 0 | — | Width reduction parameter (scaling: WWL) |
| WLN | — | 1 | — | Width reduction parameter |
| WWN | — | 1 | — | Width reduction parameter |
| DLC | m | 0 | — | Delta L for C-V |
| LLC | m^(1+LLN) | 0 | — | Length reduction parameter for CV |
| LWC | m^(1+LWN) | 0 | — | Length reduction parameter for CV |
| LWLC | m^(1+LWN+LLN) | 0 | — | Length reduction parameter for CV |
| DWC | m | 0 | — | Delta W for C-V |
| WLC | m^(1+WLN) | 0 | — | Width reduction parameter for CV |
| WWC | m^(1+WWN) | 0 | — | Width reduction parameter for CV |

### Basic Model Parameters — Physical

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TSI | m | 4e-8 | [0, inf] | Silicon-on-insulator film thickness |
| TBOX | m | 2e-7 | [0, inf] | Back gate oxide (buried oxide) thickness |
| TOXE | m | 3e-9 | [0, inf] | Effective gate dielectric thickness (relative to SiO2) |
| TOXP | m | TOXE | [0, inf] | Physical gate dielectric thickness |
| DTOX | m | 0 | — | Difference between effective and physical dielectric thickness |
| NDEP | 1/m^3 | 1e+24 | — | Channel doping concentration for I-V (binnable; scaling: NDEPL1, NDEPLEXP1, NDEPL2, NDEPLEXP2, NDEPW, NDEPWEXP, NDEPWL, NDEPWLEXP) |
| NDEPCV | 1/m^3 | NDEP | — | Channel doping concentration for C-V (binnable; scaling: NDEPCVL1, NDEPCVLEXP1, NDEPCVL2, NDEPCVLEXP2, NDEPCVW, NDEPCVWEXP, NDEPCVWL, NDEPCVWLEXP) |
| NGATE | 1/m^3 | 5e+25 | — | Gate doping concentration |
| NI0SUB | 1/m^3 | 1e+16 | — | Intrinsic carrier concentration at 300.15K |
| BG0SUB | eV | 1 | [0, inf] | Bandgap of substrate at 300.15K |
| EPSRSUB | — | 10 | [0, inf] | Relative dielectric constant of channel material |
| EPSROX | — | 4 | [0, inf] | Relative dielectric constant of gate dielectric |
| XJ | m | 1e-7 | — | S/D junction depth (binnable) |
| VFB | V | -0.5 | — | Flatband voltage (binnable; scaling: VFBL, VFBLEXP, VFBW, VFBWEXP, VFBWL, VFBWLEXP) |
| VFBB | V | 0 | — | Flatband voltage for back gate (binnable) |
| VFBCV | V | VFB | — | Flatband voltage for C-V (binnable; scaling: VFBCVL, VFBCVLEXP, VFBCVW, VFBCVWEXP, VFBCVWL, VFBCVWLEXP) |
| DELVFBACC | — | 0 | — | VFB shift in accumulation region (CVMOD=1 only) |
| VFBAGBCP2 | V | VFB | — | Flatband voltage for AGBCP2 C-V |
| NDEPAGBCP2 | 1/m^3 | NDEP | [0, inf] | Channel doping for AGBCP2 |
| NSD | 1/m^3 | 1e+26 | — | S/D doping concentration (binnable) |

### Basic Model Parameters — Threshold Voltage and Short Channel Effects

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DVTP0 | m | 0 | — | DITS parameter (binnable) |
| DVTP1 | 1/V | 0 | — | DITS parameter (binnable) |
| DVTP2 | m*V | 0 | — | DITS parameter (binnable) |
| DVTP3 | — | 0 | — | DITS parameter (binnable) |
| DVTP4 | 1/V | 0 | — | DITS parameter (binnable) |
| DVTP5 | V | 0 | — | DITS parameter (binnable) |
| DVBD0 | — | 0 | — | Coupling from Vd to Vbs (binnable) |
| DVBD1 | — | 0 | — | Coupling from Vd to Vbs (binnable) |
| VSCE | — | 0 | — | Coupling from Vd to Vbs (binnable) |
| CDSBS1 | — | 1 | — | Coupling from Vd to Vbs (binnable) |
| CDSBS | — | 0 | — | Coupling from Vd to Vbs (binnable) |
| PHIN | V | 0.04 | — | Non-uniform vertical doping effect (binnable) |
| ETA0 | — | 0.08 | — | DIBL coefficient (binnable) |
| ETA0R | — | ETA0 | — | Reverse-mode DIBL coefficient (binnable) |
| DSUB | — | 1 | — | Length scaling exponent for DIBL |
| ETAB | 1/V | -0.07 | — | Body bias coefficient for subthreshold DIBL (binnable; scaling: ETABEXP) |
| K1 | V^0.5 | 0 | — | First-order body-bias Vth shift (binnable; scaling: K1L, K1LEXP, K1W, K1WEXP, K1WL, K1WLEXP) |
| K2 | V | 0 | — | Vth shift due to non-uniform doping (binnable; scaling: K2L, K2LEXP, K2W, K2WEXP, K2WL, K2WLEXP) |
| ADOS | — | 0 | — | QME pre-factor in inversion |
| BDOS | — | 1 | — | Charge centroid parameter (QME slope) |
| QM0 | — | 1e-3 | — | Charge centroid starting point for QME |
| ETAQM | — | 0.5 | — | Bulk charge coefficient for QME centroid |
| CIT | F/m^2 | 0 | — | Interface trap capacitance (binnable) |
| NFACTOR | — | 0 | — | Subthreshold slope factor (binnable; scaling: NFACTORL, NFACTORLEXP, NFACTORW, NFACTORWEXP, NFACTORWL, NFACTORWLEXP) |
| ASCL | — | 0 | — | Back-gate dependent scale length parameter (binnable) |
| BSCL | — | 0 | — | Back-gate dependent scale length parameter (binnable) |
| DVT1 | — | 1 | — | SCE coefficient (binnable) |
| CDSCD | F/m^2/V | 0 | — | Drain bias sensitivity of subthreshold slope (binnable; scaling: CDSCDL, CDSCDLEXP) |
| CDSC | F/m^2/V | 1e-9 | — | Coupling capacitance between S/D and channel (binnable) |
| CSECSED | F/(m^2*V^2) | 0 | — | Substrate-bias sensitivity of CDSCD |
| CBCBD | F/(m^2*V^2) | 0 | — | Body bias sensitivity of CDSCD |
| CSECSE0 | F/(m^2*V) | 0 | — | Substrate-bias sensitivity of SS, long channel (binnable; scaling: CSECSE0P) |
| CSECSE | F/(m^2*V) | 0 | — | Substrate-bias sensitivity of SS, long channel (binnable; scaling: CSECSEP) |
| CBCB | F/(m^2*V) | 0 | — | Substrate-bias sensitivity of SS, long channel (binnable; scaling: CBCBP) |
| CBCB0 | F/(m^2*V) | 0 | — | Body-bias sensitivity of SS, long channel (binnable; scaling: CBCB0P) |
| CDSCDR | F/m^2/V | CDSCD | — | Reverse-mode drain bias sensitivity of SS (binnable) |
| CDSCB | F/m^2/V | 0 | — | Body-bias sensitivity of SS (binnable; scaling: CDSCBL, CDSCBLEXP) |
| VBSA | V | 0 | — | VBSA offset voltage |

### Basic Model Parameters — Mobility and Velocity Saturation

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VSAT | m/s | 1e+5 | — | Saturation velocity (binnable; scaling: VSATL, VSATLEXP, VSATW, VSATWEXP, VSATWL, VSATWLEXP) |
| VSATR | m/s | VSAT | — | Reverse-mode saturation velocity (binnable) |
| DELTA | — | 0.1 | — | Smoothing factor for Vdsat (binnable; scaling: DELTAL, DELTALEXP) |
| VSATCV | m/s | VSAT | — | VSAT for C-V (binnable; scaling: VSATCVL, VSATCVLEXP, VSATCVW, VSATCVWEXP, VSATCVWL, VSATCVWLEXP) |
| THESAT | — | 0.3 | — | Saturation velocity dependent parameter (binnable) |
| LPE1 | — | 0 | — | Equivalent pocket region length at zero bias (binnable) |
| UP1 | — | 0 | [-inf, inf] | Mobility channel length coefficient |
| LP1 | m | 1e-8 | — | Mobility channel length exponential coefficient |
| UP2 | — | 0 | [-inf, inf] | Mobility channel length coefficient |
| LP2 | m | 1e-8 | — | Mobility channel length exponential coefficient |
| U0 | m^2/V/s | 0.07 | — | Low field mobility (binnable; scaling: U0L, U0LEXP) |
| U0R | m^2/V/s | U0 | — | Reverse-mode low field mobility (binnable) |
| ETAMOB | — | 1 | — | Effective field parameter |
| UA | (m/V)^EU | 1e-3 | — | Mobility reduction coefficient (binnable; scaling: UAL, UALEXP, UAW, UAWEXP, UAWL, UAWLEXP) |
| UAR | (m/V)^EU | UA | — | Reverse-mode mobility reduction (binnable) |
| EU | — | 2 | — | Mobility reduction exponent (binnable; scaling: EUL, EULEXP, EUW, EUWEXP, EUWL, EUWLEXP) |
| UD | — | 1e-3 | — | Coulomb scattering parameter (binnable; scaling: UDL, UDLEXP) |
| UDR | — | UD | — | Reverse-mode Coulomb scattering (binnable) |
| UCS | — | 2 | — | Coulomb scattering parameter (binnable) |
| UCSR | — | UCS | — | Reverse-mode Coulomb scattering (binnable) |
| UC | (m/V)^EU/V | 0 | — | Mobility reduction with body bias (binnable; scaling: UCL, UCLEXP, UCW, UCWEXP, UCWL, UCWLEXP) |
| UCR | (m/V)^EU/V | UC | — | Reverse-mode mobility reduction with body bias (binnable) |

### Basic Model Parameters — Output Conductance

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PCLM | — | 3e-3 | — | CLM pre-factor (binnable; scaling: PCLML, PCLMLEXP) |
| PCLMR | — | PCLM | — | Reverse-mode CLM pre-factor (binnable) |
| PCLMG | V | 0 | — | CLM pre-factor gate voltage dependence |
| PCLMCV | — | PCLM | — | CLM for C-V (binnable; scaling: PCLMCVL, PCLMCVLEXP) |
| PSCBE1 | V/m | 4e+8 | — | Substrate current body-effect coefficient (binnable) |
| PSCBE2 | m/V | 1e-8 | — | Substrate current body-effect coefficient (binnable) |
| PDITS | 1/V | 0 | — | Drain-induced Vth shift coefficient (binnable; scaling: PDITSL) |
| PDITSD | 1/V | 0 | — | Vds dependence of DITS (binnable) |
| PDIBLC | — | 0 | — | DIBL effect on Rout (binnable; scaling: PDIBLCL, PDIBLCLEXP) |
| PDIBLCR | — | PDIBLC | — | Reverse-mode DIBL on Rout (binnable) |
| PDIBLCB | 1/V | 0 | — | DIBL effect on Rout (binnable) |
| PVAG | — | 1 | — | Vg dependence of early voltage (binnable) |
| FPROUT | V^0.5/m | 0 | — | Gds degradation due to pocket implants (binnable; scaling: FPROUTL, FPROUTLEXP) |

### Basic Model Parameters — Resistance

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RSH | ohm/sq | 0 | — | Source-drain sheet resistance |
| PRWG | 1/V | 1 | — | Gate bias dependence of S/D extension resistance (binnable) |
| PRWB | 1/V | 0 | — | Body bias dependence of resistance (binnable; scaling: PRWBL, PRWBLEXP) |
| WR | — | 1 | — | W dependence of S/D extension resistance (binnable) |
| RSWMIN | ohm*um^WR | 0 | — | Source resistance at high Vgs (RDSMOD=1) (binnable) |
| RSW | ohm*um^WR | 10 | — | Zero bias source resistance (RDSMOD=1) (binnable; scaling: RSWL, RSWLEXP) |
| RDWMIN | ohm*um^WR | RSWMIN | — | Drain resistance at high Vgs (RDSMOD=1) (binnable) |
| RDW | ohm*um^WR | RSW | — | Zero bias drain resistance (RDSMOD=1) (binnable; scaling: RDWL, RDWLEXP) |
| RDSWMIN | ohm*um^WR | 0 | — | S/D resistance at high Vgs (RDSMOD=0,2) (binnable) |
| RDSW | ohm*um^WR | 20 | — | Zero bias resistance (RDSMOD=0,2) (binnable; scaling: RDSWL, RDSWLEXP) |

### Basic Model Parameters — Velocity Saturation / Ids Tuning

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PSAT | — | 1 | — | Gmsat variation with gate bias (binnable; scaling: PSATL, PSATLEXP) |
| PSATB | 1/V | 0 | — | Body bias effect on Idsat (binnable) |
| PSATR | — | PSAT | — | Reverse-mode Gmsat variation (binnable) |
| PSATX | — | 1 | — | Fine tuning of PTWG effect |
| PTWG | — | 0 | — | Idsat variation with gate bias (binnable; scaling: PTWGL, PTWGLEXP) |
| VP | — | 0.05 | — | CLM dependence on VSAT (DD Model) |
| ALP | — | 0.01 | — | CLM dependence on VSAT (DD Model) |
| PTWGR | — | PTWG | — | Reverse-mode Idsat variation (binnable) |
| KSATIV | — | 1 | — | Vdsat parameter (binnable) |
| A1 | 1/V^2 | 0 | — | Non-saturation effect for strong inversion (binnable) |
| A11 | — | 0 | — | Temperature dependence of A1 (binnable) |
| A2 | 1/V | 0 | — | Non-saturation effect for moderate inversion (binnable) |
| A21 | — | 0 | — | Temperature dependence of A2 (binnable) |

### Basic Model Parameters — BJT and Impact Ionization

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| BJTOFF | — | 0 | [0, 1] | BJT on/off flag |
| VABJT | V | 10 | — | Early voltage for bipolar current (binnable) |
| AELY | V/m | 0 | — | Channel length dependency of Early voltage (binnable) |
| AHLI | — | 0 | — | High level injection parameter (binnable) |
| AHLID | — | AHLI | — | High level injection parameter drain side (binnable) |
| XBJT | — | 1 | — | Temperature coefficient for Isbjt (binnable) |
| NDIODE | — | 1 | — | Diode non-ideality factor (binnable) |
| ISBJT | A/m^2 | 0 | — | BJT injection saturation current (binnable) |
| IDBJT | A/m^2 | ISBJT | — | BJT injection saturation current drain (binnable) |
| NBJT | — | 1 | — | Power coefficient of L dependency for bipolar current (binnable) |
| LLBJT0 | m^2 | 0 | — | Length dependence of LBJT0 |
| WLBJT0 | m^2 | 0 | — | Width dependence of LBJT0 |
| PLBJT0 | m^3 | 0 | — | Cross-term dependence of LBJT0 |
| LBJT0 | m | 2e-7 | — | Reference channel length for bipolar current (binnable) |
| LN | m | 2e-6 | [0, inf] | Electron/hole diffusion length |
| VDSATII0 | — | 0.9 | — | Nominal drain saturation voltage at Vth for Iii (binnable) |
| TII | — | 0 | — | Temperature dependent parameter for Iii |
| ALPHA0 | m/V | 0 | — | Substrate current parameter (binnable; scaling: ALPHA0L, ALPHA0LEXP) |
| BETA0 | 1/V | 0 | — | 1st Vds dependent parameter of Iii (binnable) |
| BETA1 | — | 0 | — | 2nd Vds dependent parameter of Iii (binnable) |
| BETA2 | V | 0.1 | — | 3rd Vds dependent parameter of Iii (binnable) |
| LII | — | 0 | — | Channel length dependent parameter for Iii (binnable) |
| SII0 | — | 0.5 | — | 1st Vgs dependent parameter for Iii (binnable) |
| SII1 | — | 0.1 | — | 2nd Vgs dependent parameter for Iii (binnable) |
| SII2 | — | 0 | — | 3rd Vgs dependent parameter for Iii (binnable) |
| SIID | — | 0 | — | Vds dependent parameter for Iii Vdsat (binnable) |
| ESATII | V/m | 1e+7 | — | Saturation electric field for Iii (binnable) |
| IIMOD2CLAMP1 | V | 0.1 | — | Clamp1 for IIMOD=2 |
| IIMOD2CLAMP2 | V | 0.1 | — | Clamp2 for IIMOD=2 |
| IIMOD2CLAMP3 | V | 0.1 | — | Clamp3 for IIMOD=2 |
| FBJTII | — | 0 | — | Fraction of BJT current in Iii (binnable) |
| EBJTII | — | 0 | — | Iii parameter for BJT part (binnable) |
| CBJTII | m | 0 | — | Length scaling for II BJT part (binnable) |
| ABJTII | 1/V | 0 | — | Exponent factor for avalanche current (binnable) |
| VBCI | V | 0 | — | Internal B-C built-in potential (binnable) |
| TVBCI | — | 0 | — | Temperature coefficient for VBCI |
| MBJTII | — | 0.4 | — | Internal B-C grading coefficient (binnable) |

### Basic Model Parameters — Gate Tunneling Current

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VECB | — | 0.03 | [0, inf] | Vaux parameter for conduction-band electron tunneling |
| ALPHAGB1 | 1/V | 0.3 | — | 1st Vox dependent param for gate current in inversion (binnable) |
| ALPHAGB1_T | — | 0 | — | Temperature coefficient of ALPHAGB1 (binnable) |
| BETAGB1 | 1/V^2 | 0.03 | — | 2nd Vox dependent param for gate current in inversion (binnable) |
| ALPHAGB2 | 1/V | 0.4 | — | 1st Vox dependent param for gate current in accumulation (binnable) |
| ALPHAGB2_T | — | 0 | — | Temperature coefficient of ALPHAGB2 (binnable) |
| BETAGB2 | 1/V^2 | 0.05 | — | 2nd Vox dependent param for gate current in accumulation (binnable) |
| VGB2 | V | 20 | — | 3rd Vox param for gate current in accumulation |
| VGB1 | V | 300 | — | 3rd Vox param for gate current in inversion |
| AGB1 | — | 4e-7 | — | A for Igb1 tunneling |
| BGB1 | — | -3e+10 | — | B for Igb1 tunneling |
| AGB2 | — | 5e-7 | — | A for Igb2 tunneling |
| BGB2 | — | -2e+10 | — | B for Igb2 tunneling |
| AGBC2N | — | 3e-7 | — | NMOS A for tunneling |
| AGBC2P | — | 5e-7 | — | PMOS A for tunneling |
| BGBC2N | — | 1e+12 | — | NMOS B for tunneling |
| BGBC2P | — | 7e+11 | — | PMOS B for tunneling |
| EIGBINV | V | 1 | — | Si bandgap parameter for Igbinv (binnable) |
| AIGC | (F*s^2/g)^0.5/m | (NMOS: 1.36e-2, PMOS: 9.8e-3) | — | Parameter for Igc (binnable; scaling: AIGCL, AIGCW) |
| BIGC | (F*s^2/g)^0.5/m/V | (NMOS: 1.71e-3, PMOS: 7.59e-4) | — | Parameter for Igc (binnable) |
| CIGC | 1/V | (NMOS: 0.075, PMOS: 0.03) | — | Parameter for Igc (binnable) |
| AIGS | (F*s^2/g)^0.5/m | (NMOS: 1.36e-2, PMOS: 9.8e-3) | — | Parameter for Igs (binnable; scaling: AIGSL, AIGSW) |
| AIGS1 | — | 0 | — | Temperature coefficient of AIGS (binnable) |
| BIGS | (F*s^2/g)^0.5/m/V | (NMOS: 1.71e-3, PMOS: 7.59e-4) | — | Parameter for Igs (binnable) |
| CIGS | 1/V | (NMOS: 0.075, PMOS: 0.03) | — | Parameter for Igs (binnable) |
| AIGD | (F*s^2/g)^0.5/m | (NMOS: 1.36e-2, PMOS: 9.8e-3) | — | Parameter for Igd (binnable; scaling: AIGDL, AIGDW) |
| AIGD1 | — | 0 | — | Temperature coefficient of AIGD (binnable) |
| BIGD | (F*s^2/g)^0.5/m/V | (NMOS: 1.71e-3, PMOS: 7.59e-4) | — | Parameter for Igd (binnable) |
| CIGD | 1/V | (NMOS: 0.075, PMOS: 0.03) | — | Parameter for Igd (binnable) |
| DLCIG | m | LINT | — | Delta L for Ig model (binnable) |
| DLCIGD | m | DLCIG | — | Delta L for Ig model drain (binnable) |
| POXEDGE | — | 1 | — | Factor for gate edge Tox (binnable) |
| NTOX | — | 1 | — | Exponent for Tox ratio (binnable) |
| TOXREF | m | 3e-9 | — | Target Tox value |
| PIGCD | — | 1 | [-50, 50] | Igc S/D partition parameter (binnable; scaling: PIGCDL) |
| AIGC1 | — | 0 | — | Temperature coefficient of AIGC (binnable) |
| AIGBCP2 | 1/V^2 | 0.04 | — | 1st Vgp param for gate current in AGBCP2 region (binnable) |
| AIGBCP2_T | — | 0 | — | Temperature coefficient of AIGBCP2 (binnable) |
| BIGBCP2 | 1/V^2 | 5e-3 | — | 2nd Vgp param for AGBCP2 region (binnable) |
| CIGBCP2 | 1/V^2 | 7e-3 | — | 3rd Vgp param for AGBCP2 region (binnable) |

### Basic Model Parameters — GIDL/GISL

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| AGIDL | V/m | 0 | — | Pre-exponential coefficient for GIDL (binnable; scaling: AGIDLL, AGIDLW) |
| BGIDL | V/m | 2e+9 | — | Exponential coefficient for GIDL (binnable) |
| BGIDL1 | V/m | 0 | — | Temperature coefficient of BGIDL (binnable) |
| CGIDL | V/m | 0.5 | — | Exponential coefficient for GIDL (binnable) |
| EGIDL | V | 0.8 | — | Band bending parameter for GIDL (binnable) |
| AGISL | V/m | AGIDL | — | Pre-exponential coefficient for GISL (binnable; scaling: AGISLL, AGISLW) |
| BGISL | V/m | BGIDL | — | Exponential coefficient for GISL (binnable) |
| BGISL1 | V/m | BGIDL1 | — | Temperature coefficient of BGISL (binnable) |
| CGISL | V/m | CGIDL | — | Exponential coefficient for GISL (binnable) |
| EGISL | V | EGIDL | — | Band bending parameter for GISL (binnable) |
| RGIDL | — | 1 | — | GIDL Vg parameter (binnable) |
| KGIDL | V | 0 | — | GIDL Vb parameter (binnable) |
| FGIDL | — | 0 | — | GIDL Vb parameter (binnable) |
| RGISL | — | RGIDL | — | GISL Vg parameter (binnable) |
| KGISL | V | KGIDL | — | GISL Vb parameter (binnable) |
| FGISL | — | FGIDL | — | GISL Vb parameter (binnable) |

### Basic Model Parameters — Capacitance

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CF | F/m | 0 | — | Outer fringe capacitance (binnable) |
| CFRCOEFF | F/m | 1 | [1, inf] | Coefficient for outer fringe capacitance |
| CGSO | F/m | 0 | — | Gate-to-source overlap capacitance |
| CGDO | F/m | 0 | — | Gate-to-drain overlap capacitance |
| CGBO | F/m | 0 | — | Gate-to-body overlap capacitance |
| CGSL | F/m | 0 | — | Overlap capacitance gate-LDD source (binnable) |
| CGDL | F/m | 0 | — | Overlap capacitance gate-LDD drain (binnable) |
| CKAPPAS | V | 0.6 | — | Bias-dependent overlap cap source side (binnable) |
| CKAPPAS1 | — | 1e+6 | — | Parameter for tuning CGS |
| CKAPPAS2 | — | 1 | — | Parameter for tuning CGS |
| CKAPPPAD | V | 0.6 | — | Bias-dependent overlap cap drain side (binnable) |
| CKAPPAD1 | — | 1e+6 | — | Parameter for tuning CGD |
| CKAPPAD2 | — | 1 | — | Parameter for tuning CGD |
| XRCRG1 | — | 10 | — | 1st fitting parameter for bias-dependent Rg |
| XRCRG2 | — | 1 | — | 2nd fitting parameter for bias-dependent Rg |

### Basic Model Parameters — Sub-Surface Leakage / Miscellaneous

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SSL0 | A/m | 400 | — | Temperature/doping independent param for SSL current |
| SSL1 | 1/m | 3e+8 | — | Gate length param for SSL current |
| SSL2 | — | 0.2 | — | Barrier height fitting param for SSL |
| SSL3 | V | 0.3 | — | Gate voltage effect for SSL |
| SSL4 | 1/V | 1 | — | Gate voltage effect for SSL |
| SSL5 | 1/V | 0 | — | Gate voltage effect for SSL |
| SSLEXP1 | — | 0.5 | — | Exponent for SSL doping effect |
| SSLEXP2 | — | 1 | — | Exponent for SSL temperature |
| AVDSX | — | 20 | [5, 100] | Smoothing parameter in Vdsx |
| ABULK | — | 1 | [1, 2] | Tuning Cgg in strong inversion |
| A0 | — | 0 | — | Depletion width dependence in AbulkIV |
| AGS | — | 0 | — | Source charge dependence in AbulkIV |
| AGS1 | — | 1 | — | qs nonlinear term for Id-Vd flexibility |
| KETA | — | 0 | — | Back-bias dependence in AbulkIV |
| A0CV | — | A0 | — | Depletion width dependence in AbulkCV |
| AGSCV | — | AGS | — | Source charge dependence in AbulkCV |
| KETACV | — | KETA | — | Back-bias dependence in AbulkCV |
| C0 | V | 0 | — | Lateral NUD1 voltage parameter (binnable) |
| C01 | 1/K | 0 | — | Temperature dependence of C0 (binnable) |
| C0SI | V | 1 | — | Correction factor for Mnud1 (binnable) |
| C0SI1 | 1/K | 0 | — | Temperature dependence of C0SI (binnable) |
| C0SISAT | V | 0 | — | Correction factor for Mnud1 (binnable) |
| C0SISAT1 | 1/K | 0 | — | Temperature dependence of C0SISAT (binnable) |
| IGCLAMP | — | 1 | [0, 1] | Ig clamping flag |
| K0 | — | 0 | — | Non-saturation effect for strong inversion (binnable) |
| K01 | 1/K | 0 | — | Temperature coefficient for K0 (binnable) |
| M0 | — | 1 | — | Non-saturation effect offset (binnable) |
| M01 | 1/K | 0 | — | Temperature coefficient for M0 (binnable) |
| minr | ohm | 1e-3 | — | Minimum S/D resistance for simulation efficiency |

### Junction Diode Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CJS | F/m^2 | 5e-4 | — | Unit area source junction capacitance at zero bias |
| CJD | F/m^2 | CJS | — | Unit area drain junction capacitance at zero bias |
| CJSWS | F/m | 5e-10 | — | Unit length source sidewall junction cap |
| CJSWD | F/m | CJSWS | — | Unit length drain sidewall junction cap |
| CJSWGS | F/m | 0 | — | Unit length source gate-side sidewall junction cap |
| CJSWGD | F/m | CJSWGS | — | Unit length drain gate-side sidewall junction cap |
| PBS | V | 1 | — | Source bulk junction built-in potential |
| PBD | V | PBS | — | Drain bulk junction built-in potential |
| PBSWS | V | 1 | — | Source sidewall junction built-in potential |
| PBSWD | V | PBSWS | — | Drain sidewall junction built-in potential |
| PBSWGS | V | PBSWS | — | Source gate-sidewall junction built-in potential |
| PBSWGD | V | PBSWGS | — | Drain gate-sidewall junction built-in potential |
| MJS | — | 0.5 | — | Source bottom junction grading coefficient |
| MJD | — | MJS | — | Drain bottom junction grading coefficient |
| MJSWS | — | 0.3 | — | Source sidewall junction grading coefficient |
| MJSWD | — | MJSWS | — | Drain sidewall junction grading coefficient |
| MJSWGS | — | MJSWS | — | Source gate-sidewall grading coefficient |
| MJSWGD | — | MJSWGS | — | Drain gate-sidewall grading coefficient |
| TT | s | 1e-12 | — | Diffusion capacitance transit time |
| LDIF0 | — | 1 | — | Channel-length dependency of diffusion cap |
| NDIF | — | -1 | — | Power coefficient for diffusion cap L dependency (binnable) |
| VTM00 | V | 0.03 | [0, 1] | Hard coded 25 degC thermal voltage |
| PERMOD | — | 1 | [0, 1] | Whether PS/PD include gate-edge perimeter |
| DWJ | m | DWC | — | Delta W for S/D junctions |
| XDIF | — | XBJT | — | Temperature coefficient for Isdif (binnable) |
| ISDIF | A/m^2 | 1e-7 | — | Body to S/D injection saturation current (binnable) |
| IDDIF | A/m^2 | ISDIF | — | Drain side injection saturation current (binnable) |
| NRECF0 | — | 2 | — | Recombination non-ideality factor, forward (binnable) |
| NRECR0 | — | 10 | — | Recombination non-ideality factor, reverse (binnable) |
| XREC | — | 1 | — | Temperature coefficient for Isrec (binnable) |
| ISREC | A/m^2 | 1e-5 | — | Recombination saturation current (binnable) |
| IDREC | A/m^2 | ISREC | — | Drain recombination saturation current (binnable) |
| NTRECF | — | 0 | — | Temperature coefficient for Nrecf (binnable) |
| NTRECR | — | 0 | — | Temperature coefficient for Nrecr (binnable) |
| ISTUN | A/m^2 | 1e-8 | — | Reverse tunneling saturation current (binnable) |
| IDTUN | A/m^2 | ISTUN | — | Drain reverse tunneling saturation current (binnable) |
| XTUN | — | 0 | — | Temperature coefficient for Istun (binnable) |
| XTUND | — | XTUN | — | Temperature coefficient for Idtun (binnable) |
| NTUN | — | 10 | — | Reverse tunneling non-ideality factor (binnable) |
| NTUND | — | NTUN | — | Drain tunneling non-ideality factor (binnable) |
| VTUN0 | V | 0 | — | Voltage dependent parameter for tunneling (binnable) |
| VTUN0D | V | VTUN0 | — | Drain voltage dependent tunneling parameter (binnable) |
| VREC0 | V | 0 | — | Voltage dependent parameter for recombination (binnable) |
| VREC0D | V | VREC0 | — | Drain voltage dependent recombination parameter (binnable) |

### Layout-Dependent Parasitic Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DMCG | m | 0 | — | Distance of mid-contact to gate edge |
| DMCI | m | DMCG | — | Distance of mid-contact to isolation |
| DMDG | m | 0 | — | Distance of mid-diffusion to gate edge |
| DMCGT | m | 0 | — | Distance of mid-contact to gate edge in test |
| XGL | m | 0 | [-inf, L*LMLT+XL] | Variation in Ldrawn |
| RSHG | ohm | 0.1 | — | Gate sheet resistance |

### EdgeFET Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WEDGE | m | 1e-8 | [1e-9, inf] | Edge FET width |
| DGAMMAEDGE | — | 0 | [-inf, inf] | Body-bias coeff difference Edge vs Main FET (binnable; scaling: DGAMMAEDGEL, DGAMMAEDGELEXP) |
| DVTEDGE | — | 0 | [-inf, inf] | Vth shift for Edge FET |
| NDEPEDGE | 1/m^3 | 1e+24 | — | Channel doping for EDGEFET (binnable) |
| NFACTOREDGE | — | 0 | — | NFACTOR for Edge FET (binnable) |
| CITEDGE | F/m^2 | 0 | — | CIT for Edge FET (binnable) |
| CDSCEDGE | F/m^2/V | 1e-9 | — | CDSC for Edge FET (binnable) |
| CDSCDEDGE | F/m^2/V | 1e-9 | — | CDSCD for Edge FET (binnable) |
| CDSCDEDGER | F/m^2/V | 1e-9 | — | CDSCDR for Edge FET (binnable) |
| CSECSEEDGE | F/(m^2*V) | 0 | — | CSECSE for edge FET |
| CSECSEPEDGE | F/(m^2*V) | 0 | — | CSECSEP for edge FET |
| CSECSE0EDGE | F/(m^2*V) | 0 | — | CSECSE0 for edge FET |
| CSECSE0PEDGE | F/(m^2*V^2) | 0 | — | CSECSE0P for edge FET |
| CSECSEDEDGE | F/(m^2*V^2) | 0 | — | CSECSED for edge FET |
| CBCB0EDGE | F/(m^2*V) | 0 | — | CBCB0 for edge FET |
| CBCB0PEDGE | F/(m^2*V^2) | 0 | — | CBCB0P for edge FET |
| CDSCBEDGE | F/m^2/V | 0 | — | CDSCB for Edge FET (binnable) |
| CBCBPEDGE | F/(m^2*V) | 0 | — | CBCBP for edge FET |
| CBCBEDGE | F/(m^2*V) | 0 | — | CBCB for edge FET (binnable) |
| CBCBDEDGE | F/(m^2*V^2) | 0 | — | CBCBD for edge FET |
| K1EDGE | V^0.5 | 0 | — | K1 for Edge FET (binnable) |
| K1LEDGE | — | 0 | — | Length dependence of K1EDGE |
| K1LEXPEDGE | — | 1 | — | Length exponent of K1EDGE |
| K1WEDGE | — | 0 | — | Width dependence of K1EDGE |
| K1WEXPEDGE | — | 1 | — | Width exponent of K1EDGE |
| K1WLEDGE | — | 0 | — | Width-length dependence of K1EDGE |
| K1WLEXPEDGE | — | 1 | — | Width-length exponent of K1EDGE |
| ETA0EDGE | — | 0.08 | — | DIBL for Edge FET (binnable) |
| ETABEDGE | 1/V | -0.07 | — | ETAB for Edge FET (binnable) |
| KT1EDGE | V | -0.1 | — | Temp dependence of Vth for Edge FET (binnable) |
| KT1LEDGE | V*m | 0 | — | Temp dependence of Vth for Edge FET (binnable) |
| KT2EDGE | — | 0.02 | — | Temp dependence of Vth for Edge FET (binnable) |
| KT1EXPEDGE | — | 1 | — | Temp dependence of Vth for Edge FET (binnable) |
| TNFACTOREDGE | — | 0 | — | Temp dependence of NFACTOR for Edge FET (binnable) |
| TETA0EDGE | — | 0 | — | Temp dependence of DIBL for Edge FET (binnable) |
| DVTP0EDGE | m | 0 | — | DVTP0 for Edge FET (binnable) |
| DVTP1EDGE | 1/V | 0 | — | DVTP1 for Edge FET (binnable) |
| DVTP2EDGE | m*V | 0 | — | DVTP2 for Edge FET (binnable) |
| DVTP3EDGE | — | 0 | — | DVTP3 for Edge FET (binnable) |
| DVTP4EDGE | 1/V | 0 | — | DVTP4 for Edge FET (binnable) |
| DVTP5EDGE | V | 0 | — | DVTP5 for Edge FET (binnable) |
| DVT0EDGE | — | 2 | — | 1st SCE coefficient for Edge FET |
| DVT1EDGE | — | 0.5 | — | 2nd SCE coefficient for Edge FET |
| DVT2EDGE | 1/V | 0 | — | Body-bias SCE coefficient for Edge FET |
| K2EDGE | V | 0 | — | K2 for Edge FET (binnable) |
| K2LEDGE | m^K2LEXP | 0 | — | Length dependence of K2EDGE |
| K2LEXPEDGE | — | 1 | — | Length exponent of K2EDGE |
| K2WEDGE | m^K2WEXP | 0 | — | Width dependence of K2EDGE |
| K2WEXPEDGE | — | 1 | — | Width exponent of K2EDGE |
| K2WLEDGE | m^(2*K2WLEXP) | 0 | — | Width-length dependence of K2EDGE |
| K2WLEXPEDGE | — | 1 | — | Width-length exponent of K2EDGE |
| KVTH0EDGE | V*m | 0 | — | Stress effect Vth shift for Edge FET (binnable) |
| KVTH0EDGEWE | — | 0 | — | WPE Vth shift for Edge FET (binnable) |
| K2EDGEWE | — | 0 | — | WPE K2 shift for Edge FET (binnable) |
| STK2EDGE | m | 0 | — | K2 shift for stress in Edge FET (binnable) |
| STETA0EDGE | m | 0 | — | ETA0 shift for stress in Edge FET (binnable) |

### Noise Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| EF | — | 1 | [0, 2] | Flicker noise frequency exponent |
| EM | V/m | 4e+7 | — | Saturation field |
| NOIA | s^(1-EF)/(eV)/m^3 | 6e+40 | — | Flicker noise parameter A |
| NOIB | s^(1-EF)/(eV)/m | 3e+25 | — | Flicker noise parameter B |
| NOIC | s^(1-EF)*m/(eV) | 9e+8 | — | Flicker noise parameter C |
| LINTNOI | m | 0 | — | Length reduction offset for noise |
| NOIA1 | — | 0 | — | Flicker noise fitting parameter (strong inversion) |
| NOIAX | — | 1 | — | Flicker noise fitting parameter (high Vds) |
| NTNOI | — | 1 | — | Noise factor for short-channel (TNOIMOD=0) |
| RNOIA | — | 0.6 | — | Noise parameter (TNOIMOD=1) |
| RNOIB | — | 0.5 | — | Noise parameter (TNOIMOD=1) |
| RNOIC | — | 0.4 | — | Noise correlation coefficient (TNOIMOD=1) |
| TNOIA | — | 2 | [-inf, inf] | Noise parameter (TNOIMOD=1) |
| TNOIB | — | 4 | [-inf, inf] | Noise parameter (TNOIMOD=1) |
| TNOIC | — | 0 | [-inf, inf] | Noise correlation coefficient (TNOIMOD=1) |
| LP | m | 1e-5 | — | Length scaling for thermal noise |
| RNOIK | — | 0 | — | Exponential coefficient for enhanced correlated thermal noise |
| TNOIK | 1/m | 0 | [-inf, inf] | Empirical Leff trend of Sid at low Ids |
| TNOIK2 | 1/m | 0.1 | — | Sensitivity parameter for RNOIK |
| NEDGE | — | 1 | — | Flicker noise parameter for edge FET |
| NOIA1_EDGE | — | 0 | — | Flicker noise fitting for edge FET (strong inversion) |
| NOIAX_EDGE | — | 1 | — | Flicker noise fitting for edge FET |
| LH | m | 1e-8 | [0, L] | Length of halo transistor |
| NOIA2 | s^(1-EF)/(eV)/m^3 | NOIA | — | Flicker noise A for halo |
| HNDEP | 1/m^3 | NDEP | — | Halo doping concentration |
| AFNS | — | — | — | Flicker noise exponent for source resistance |
| BFNS | — | — | — | Flicker noise frequency exponent for source resistance |
| KFNS | — | — | — | Flicker noise coefficient for source resistance |
| AFND | — | — | — | Flicker noise exponent for drain resistance |
| BFND | — | — | — | Flicker noise frequency exponent for drain resistance |
| KFND | — | — | — | Flicker noise coefficient for drain resistance |

### Body-Contact Parasitics Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RBODY | ohm/sq | 0 | — | Intrinsic body contact sheet resistance |
| FRBODY | — | 1 | — | Layout dependent body-resistance coefficient |
| RBSH | ohm/sq | 0 | — | Extrinsic body contact sheet resistance |
| NRB | — | 1 | — | Number of squares in body |
| RHALO | ohm/m | 1e+15 | — | Body halo sheet resistance |
| UB | m^2/V/s | 0.07 | — | Mobility of majority carriers in body (binnable) |
| UBTE | — | 1 | — | Mobility temperature exponent (binnable) |
| NEFF | 1/m^3 | 5e+24 | — | Effective substrate doping (binnable) |
| NSEG | — | 1 | [0, inf] | Number of segments for width partitioning |
| RBODYAGBCP2 | ohm | 1e-3 | — | Body resistance for AGBCP2 FET |
| NBC | — | 0 | — | Number of body contact isolation edges (0=float, 1=T-gate, 2=H-gate) |
| DWBC | m | 0 | — | Width offset for body contact isolation edge |
| PDBCP | m | 0 | — | Perimeter length for BC parasitics at drain side |
| PSBCP | m | 0 | — | Perimeter length for BC parasitics at source side |
| AGBCP | m^2 | 0 | — | Gate to body overlap area for BC parasitics |
| AGBCP2 | m^2 | 2e-12 | — | Parasitic gate to body overlap area (opposite-type) |
| AGBCPD | m^2 | AGBCP | — | Gate to body overlap area for BC parasitics in DC |
| AEBCP | m^2 | 0 | — | Substrate to body overlap area for BC parasitics |
| EGGBCP2 | eV | 1 | — | Bandgap in AGBCP2 region |

### Temperature Dependence and Self-Heating Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TNOM | degC | 30 | — | Temperature at which model was extracted |
| TBGASUB | eV/K | 5e-4 | — | Bandgap temperature coefficient |
| TBGBSUB | K | 600 | — | Bandgap temperature coefficient |
| TNFACTOR | — | 0 | — | Temperature exponent for NFACTOR |
| UTE | — | -2 | — | Mobility temperature exponent (binnable; scaling: UTEL) |
| UA1 | m/V | 1e-3 | — | Temperature coefficient for UA (binnable; scaling: UA1L) |
| UC1 | 1/K | 6e-11 | — | Temperature coefficient for UC (binnable) |
| UD1 | 1/m^2 | 0 | — | Temperature coefficient for UD (binnable; scaling: UD1L) |
| EU1 | — | 0 | — | Temperature coefficient for EU (binnable) |
| UCSTE | — | -5e-3 | — | Temperature coefficient for UCS (binnable) |
| TETA0 | — | 0 | — | Temperature coefficient for ETA0 |
| PRT | — | 0 | — | Temperature coefficient for resistance (binnable) |
| AT | m/s | -2e-3 | — | Temperature coefficient for Vsat (binnable; scaling: ATL) |
| TDELTA | 1/K | 0 | — | Temperature coefficient for DELTA |
| PTWGT | 1/K | 0 | — | Temperature coefficient for PTWG (binnable; scaling: PTWGTL) |
| KT1 | V | -0.1 | — | Temperature coefficient for Vth (binnable; scaling: KT1EXP, KT1L) |
| KT2 | — | 0.02 | — | Temperature coefficient for Vth (binnable) |
| IIT | — | 0 | — | Temperature coefficient for BETA0 (binnable) |
| IGT | — | 2 | — | Gate current temperature dependence (binnable) |
| TCJ | 1/K | 0 | — | Temperature coefficient for CJS/CJD |
| TCJSW | 1/K | 0 | — | Temperature coefficient for CJSWS/CJSWD |
| TCJSWG | 1/K | 0 | — | Temperature coefficient for CJSWGS/CJSWGD |
| TPB | V/K | 0 | — | Temperature coefficient for PBS/PBD |
| TPBSW | V/K | 0 | — | Temperature coefficient for PBSWS/PBSWD |
| TPBSWG | V/K | 0 | — | Temperature coefficient for PBSWGS/PBSWGD |
| RTH0 | m*K/W | 0 | [0, inf] | Thermal resistance |
| CTH0 | s*W/(m*K) | 1e-5 | [0, inf] | Thermal capacitance |
| WTH0 | m | 0 | — | Width dependence coefficient for Rth and Cth |

### Stress and Well-Proximity Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SAREF | m | 1e-6 | — | Reference SA distance |
| SBREF | m | 1e-6 | — | Reference SB distance |
| WLOD | m | 0 | — | Width parameter for stress effect |
| KU0 | m | 0 | — | Mobility degradation/enhancement for stress (binnable) |
| KVSAT | m | 0 | — | Vsat degradation/enhancement for stress |
| TKU0 | — | 0 | — | Temperature coefficient for KU0 |
| LLODKU0 | — | 0 | — | Length parameter for U0 stress |
| WLODKU0 | — | 0 | — | Width parameter for U0 stress |
| KVTH0 | V*m | 0 | — | Threshold shift for stress (binnable) |
| LLODVTH | — | 0 | — | Length parameter for Vth stress |
| WLODVTH | — | 0 | — | Width parameter for Vth stress |
| STK2 | m | 0 | — | K2 shift factor for stress |
| LODK2 | — | 0 | — | K2 modification factor for stress |
| STETA0 | m | 0 | — | ETA0 shift for stress |
| LODETA0 | — | 0 | — | ETA0 modification factor for stress |
| WEB | — | 0 | — | Coefficient for SCB |
| WEC | — | 0 | — | Coefficient for SCC |
| KVTH0WE | — | 0 | — | Vth shift for well proximity (binnable) |
| K2WE | — | 0 | — | K2 shift for well proximity (binnable) |
| KU0WE | — | 0 | — | Mobility degradation for well proximity (binnable) |
| SCREF | m | 1e-6 | [0, inf] | Reference distance for SCA/SCB/SCC |

---

## Equations

### Physical Constants (Sec. 5.1)

$$q = 1.6 \times 10^{-19} \text{ C}$$

$$\epsilon_0 = 8.8542 \times 10^{-12} \text{ F/m}$$

$$\epsilon_{sub} = EPSRSUB \cdot \epsilon_0$$

$$\epsilon_{ox} = EPSROX \cdot \epsilon_0$$

$$C_{ox} = \frac{3.9 \cdot \epsilon_0}{TOXE}$$

$$\epsilon_{ratio} = \frac{EPSRSUB}{3.9}$$

### Effective Channel Length and Width (Sec. 5.2)

$$\Delta L = LINT + \frac{LL}{L_{new}^{LLN}} + \frac{LW}{W_{new}^{LWN}} + \frac{LWL}{L_{new}^{LLN} \cdot W_{new}^{LWN}}$$

$$\Delta W = WINT + \frac{WL}{L_{new}^{WLN}} + \frac{WW}{W_{new}^{WWN}} + \frac{WWL}{L_{new}^{WLN} \cdot W_{new}^{WWN}}$$

$$L_{new} = L \cdot LMLT + XL, \quad W_{new} = \frac{W}{NF} \cdot WMLT + XW$$

$$L_{eff} = L \cdot LMLT + XL - 2\Delta L$$

$$W_{eff} = W \cdot WMLT + XW - 2\Delta W$$

$$L_{eff,CV} = L \cdot LMLT + XL - 2 \cdot DLC$$

$$W_{eff,CV} = W \cdot WMLT + XW - 2 \cdot DWC$$

### Binning Calculations (Sec. 5.3)

$$PARAM_i = PARAM + LPARAM \cdot BIN_L + WPARAM \cdot BIN_W + PPARAM \cdot BIN_{WL}$$

When BINUNIT=1:

$$BIN_L = \frac{10^{-6}}{L_{eff} + DLBIN}, \quad BIN_W = \frac{10^{-6}}{W_{eff} + DWBIN}$$

When BINUNIT=0:

$$BIN_L = \frac{1}{L_{eff} + DLBIN}, \quad BIN_W = \frac{1}{W_{eff} + DWBIN}$$

$$BIN_{WL} = BIN_L \cdot BIN_W$$

### Global Geometrical Scaling (Sec. 5.4)

General form:

$$PARAM[L] = PARAM \cdot \left[1 + PARAML \cdot \frac{1}{L_{eff}^{PARAMLEXP}} + PARAMW \cdot \frac{1}{W_{eff}^{PARAMWEXP}} + PARAMWL \cdot \frac{1}{(L_{eff} \cdot W_{eff})^{PARAMWLEXP}}\right]$$

Mobility scaling (MOBSCALE=0):

$$U0[L] = \begin{cases} U0 \cdot \left(1 - U0L \cdot L_{eff}^{-U0LEXP}\right) & \text{if } U0LEXP > 0 \\ U0 \cdot (1 - U0L) & \text{otherwise} \end{cases}$$

Mobility scaling (MOBSCALE=1):

$$U0[L] = U0 \cdot \left[1 - UP1 \cdot e^{-L_{eff}/LP1} - UP2 \cdot e^{-L_{eff}/LP2}\right]$$

### Terminal Voltages (Sec. 5.5)

$$V_t = \frac{kT}{q}$$

$$V_{gs} = V_g - V_s, \quad V_{gd} = V_g - V_d, \quad V_{ds} = V_d - V_s$$

$$V_{es} = V_e - V_s, \quad V_{ed} = V_e - V_d$$

$$V_{dsx} = \frac{2}{AVDSX} \cdot \ln\left(1 + \exp\frac{AVDSX \cdot V_{ds}}{2}\right) - V_{ds} - \frac{2}{AVDSX}\ln(2)$$

$$V_{bsx} = -\left(V_s + \frac{1}{2}(V_{ds} - V_{dsx})\right)$$

### Physical Quantities (Sec. 5.6)

$$\phi_b = \ln\frac{n_{body}}{n_i}$$

$$\gamma_0 = \frac{\sqrt{2q \epsilon_{si} \cdot NDEP}}{C_{ox}\sqrt{nV_t}}, \quad \gamma_g = \frac{\sqrt{2q \epsilon_{si} \cdot NGATE}}{C_{ox}\sqrt{nV_t}}$$

$$\delta_{PD} = \frac{NDEP}{NGATE}, \quad \gamma = \frac{\gamma_0}{1 + \delta_{PD}}$$

$$C_B = \frac{\epsilon_{si}}{TSI}, \quad C_{BOX} = \frac{\epsilon_{ox}}{TBOX}$$

$$RC = \frac{C_{BOX} + CDSBS}{C_B}, \quad RT = \frac{TOXE}{TBOX}$$

### Parasitic Series Resistance (Sec. 2.2)

**RDSMOD=0** (internal bias-dependent, external bias-independent):

$$T_0 = 1 + PRWG \cdot q_{ia}$$

$$T_1 = PRWB \cdot (\sqrt{\phi_s - V_{bs}} - \sqrt{\phi_s})$$

$$T_3 = \frac{1}{2}\left(T_2 + \sqrt{T_2^2 + 0.01}\right), \quad T_2 = \frac{1}{T_0} + T_1$$

$$R_{ds}(V) = NF \cdot \frac{W_R}{W_{eff}} \left(RDSWMIN + RDSW \cdot T_3\right)$$

$$D_r = 1 + \frac{\mu_0}{D_{mob} \cdot D_{vsat}} \cdot C_{ox} \cdot \frac{W_{eff}}{L_{eff}} \cdot q_{ia} \cdot R_{ds}$$

$$R_{source} = R_{s,geo}, \quad R_{drain} = R_{d,geo}$$

**RDSMOD=1** (external bias-dependent):

$$V_{gs,eff} = \frac{1}{2}\left(V_{gs1} - V_{fbsdr} + \sqrt{(V_{gs,noswap} - V_{fbsdr})^2 + 10^{-2}}\right)$$

$$R_{source} = \frac{W_R}{W_{eff} \cdot NF}\left(RSWMIN + RSW \cdot \left(-PRWB \cdot V_{sb,noswap} + \frac{1}{1 + PRWG_i \cdot V_{gs,eff}}\right)\right) + R_{s,geo}$$

$$R_{drain} = \frac{W_R}{W_{eff} \cdot NF}\left(RDWMIN + RDW \cdot \left(-PRWB \cdot V_{db,noswap} + \frac{1}{1 + PRWG_i \cdot V_{gd,eff}}\right)\right) + R_{d,geo}$$

**RDSMOD=2** (all internal):

$$R_{ds}(V) = R_{s,geo} + NF \cdot \frac{W_R}{W_{eff}}\left(RDSWMIN + RDSW \cdot T_3\right) + R_{d,geo}$$

Geometry resistances:

$$R_{s,geo} = NRS \cdot RSHS, \quad R_{d,geo} = NRD \cdot RSHD$$

### Diode and Parasitic BJT Currents (Sec. 3.1)

Backward injection:

$$I_{bs1} = W_{dios} \cdot T_{si} \cdot j_{difs} \left(\exp\frac{V_{bs}}{n_{diodes} V_t} - 1\right)$$

$$I_{bd1} = W_{diod} \cdot T_{si} \cdot j_{difd} \left(\exp\frac{V_{bd}}{n_{dioded} V_t} - 1\right)$$

Recombination and trap-assisted tunneling:

$$I_{bs2} = W_{dios} T_{si} j_{recs}\left(\exp\frac{V_{bs}}{0.026 \cdot n_{recfs}} - \exp\frac{V_{sb}}{0.026 \cdot n_{recrs}} \cdot \frac{V_{rec0s}}{V_{rec0s} + V_{sb}}\right)$$

Reverse bias tunneling:

$$I_{bs4} = W_{dios} T_{si} j_{tuns}\left(1 - \exp\frac{V_{sb}}{0.026 \cdot n_{tuns}} \cdot \frac{V_{tun0s}}{V_{tun0s} + V_{sb}}\right)$$

Recombination in neutral body:

$$I_{bs3} = (1 - \alpha_{bjt}) I_{ens}\left(\exp\frac{V_{bs}}{n_{diodes} V_t} - 1\right) \frac{1}{\sqrt{E_{hlis} + 1}}$$

$$I_{ens} = W'_{eff} T_{si} j_{bjts} L_{bjt0}\left(\frac{1}{L_{eff}} + \frac{1}{L_n}\right)^{N_{bjt}}$$

$$E_{hlis} = A_{hlis,eff}\left(\exp\frac{V_{bs}}{n_{diodes} V_t} - 1\right)$$

$$\alpha_{bjt} = \exp\left(-0.5\left(\frac{L_{eff}}{L_n}\right)^2\right)$$

Parasitic BJT collector current:

$$I_c = \alpha_{bjt} I_{en}\left(\exp\frac{V_{bs}}{n_{diodes} V_t} - \exp\frac{V_{bd}}{n_{dioded} V_t}\right) \frac{1}{E_{2nd}}$$

$$E_{2nd} = \frac{E_{ely} + \sqrt{E_{ely}^2 + 4E_{hli}}}{2}$$

$$E_{ely} = 1 + \frac{V_{bs} + V_{bd}}{VA_{bjt} + AELY \cdot L_{eff}}$$

Total drain current including BJT:

$$I_{ds,total} = I_{ds,MOSFET} + I_c$$

### Impact Ionization Current (Sec. 3.2)

**IIIMOD=0:**

$$I_{ii} = ALPHA0 \cdot (V_{ds} - V_{dseff}) \cdot \exp\left(\frac{BETA0}{V_{ds} - V_{dseff}}\right) \cdot \frac{I_{ds}}{MSCBE}$$

**IIIMOD=1:**

$$I_{ii} = ALPHA0 \cdot (I_{ds} + I_{ii,BJT}) \cdot \exp\left(\frac{V_{diff}}{BETA2 + BETA1 \cdot V_{diff} + BETA0 \cdot V_{diff}^2}\right)$$

$$I_{ii,BJT} = FBJTII \cdot I_c$$

$$V_{diff} = V_{ds} - V_{dsatii}$$

$$V_{dsatii} = VgsStep + V_{dsatii0}\left(1 + TII\left(\frac{T}{T_{nom}} - 1\right)\right) - \frac{LII}{L_{eff}}$$

$$VgsStep = \frac{ESATII \cdot L_{eff}}{1 + ESATII \cdot L_{eff}} \cdot \frac{1}{1 + SII1 \cdot V_{gsteff}} + SII2 \cdot \frac{SII0 \cdot V_{gst}}{1 + SIID \cdot V_{ds}}$$

**IIIMOD=2:**

$$I_{ii,BJT} = \frac{CBJTII + EBJTII \cdot L_{eff}}{L_{eff}} \cdot I_c \cdot (V_{bci} - V_{bd}) \cdot \exp\left(-ABJTII \cdot (V_{bci} - V_{bd})^{MBJTII-1}\right)$$

$$V_{bci} = VBCI\left(1 + TVBCI\left(\frac{T}{T_{nom}} - 1\right)\right)$$

### GIDL/GISL Current (Sec. 3.3)

**GIDLMOD=0:**

$$I_{GIDL} = AGIDL \cdot W_{diod} \cdot NF \cdot \frac{V_{ds} - V_{gse} - EGIDL + V_{fbsd}}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGIDL}{V_{ds} - V_{gse} - EGIDL}\right) \cdot \frac{V_{db}^3}{CGIDL + V_{db}^3}$$

$$I_{GISL} = AGISL \cdot W_{dios} \cdot NF \cdot \frac{-V_{ds} - V_{gse} - EGISL + V_{fbsd}}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGISL}{-V_{ds} - V_{gse} - EGISL}\right) \cdot \frac{V_{sb}^3}{CGISL + V_{sb}^3}$$

**GIDLMOD=1:**

$$I_{GIDL} = AGIDL \cdot W_{diod} \cdot NF \cdot \frac{V_{ds} - RGIDL \cdot V_{gse} - EGIDL + V_{fbsd}}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGIDL}{V_{ds} - V_{gse} - EGIDL}\right) \cdot \exp\left(\frac{KGIDL}{V_{ds} - FGIDL}\right)$$

### Gate Tunneling Current (Sec. 3.4)

Oxide voltage:

$$V_{ox} = nV_t \cdot (v_g - v_{fb} - \psi_p + q_s + q_{deff})$$

$$V_{ox,acc} = \frac{1}{2}\left(-V_{ox} + \sqrt{V_{ox}^2 + 10^{-4}}\right)$$

$$V_{ox,depinv} = \frac{1}{2}\left(V_{ox} + \sqrt{V_{ox}^2 + 10^{-4}}\right)$$

Gate-to-body tunneling (inversion):

$$J_{gb,inv} = A \cdot \frac{V_{gb} \cdot V_{aux}}{TOXE^2} \cdot \left(\frac{TOXREF}{TOXE}\right)^{NTOX} \cdot \exp\left(\frac{-B(\alpha_{gb1} - \beta_{gb1}|V_{ox}|) \cdot T_{ox}}{1 - |V_{ox}|/V_{gb1}}\right)$$

Gate-to-channel current at $V_{ds}=0$:

$$I_{gc0} = W_{eff} L_{eff} \cdot A \cdot ToxRatio \cdot V_{gse} \cdot V_{aux} \cdot \exp\left[(-B \cdot TOXE \cdot AIGC - BIGC \cdot V_{ox,depinv})(1 + CIGC \cdot V_{ox,depinv})\right]$$

Gate-to-S/D:

$$I_{gs} = W_{eff} \cdot DLCIG \cdot A \cdot ToxRatioEdge \cdot V_{gs} \cdot V'_{gs} \cdot ig_{temp} \cdot \exp\left[-B \cdot TOXE \cdot POXEDGE \cdot (AIGS - BIGS \cdot V'_{gs})(1 + CIGS \cdot V'_{gs})\right]$$

Partition of $I_{gc}$:

$$I_{gcs} = I_{gc0} \cdot \frac{PIGCD \cdot V_{dseff,x} + \exp(-PIGCD \cdot V_{dseff,x}) - 1 + 10^{-4}}{(PIGCD \cdot V_{dseff,x})^2 + 2 \times 10^{-4}}$$

$$I_{gcd} = I_{gc0} \cdot \frac{1 - (PIGCD \cdot V_{dseff,x} + 1) \exp(-PIGCD \cdot V_{dseff,x}) + 10^{-4}}{(PIGCD \cdot V_{dseff,x})^2 + 2 \times 10^{-4}}$$

### Body Contact Current (Sec. 3.5)

**BODYMOD=1** (linear):

$$R_{bi,b} = R_{body}\left(\frac{W'_{eff}}{L_{eff}}\right) \| R_{halo}\left(\frac{W'_{eff}}{2}\right), \quad R_{bodyext} = RBSH \cdot NRB$$

**BODYMOD=2** (nonlinear):

$$R_{bi,b} = \frac{W_{EFF}^2}{UB \cdot Q_{body}}$$

$$Q_{body} = q \cdot NEFF \cdot TSI \cdot W_{EFF} \cdot L_{EFF} - Q_B$$

Body contact current:

$$I_{bi,b} = \frac{V_{bi,b}}{R_{bi,b} + R_{bodyext}}$$

Body contact width corrections:

$$W_{eff} = W_{drawn} - N_{bc} \cdot dW_{bc} - (2 - N_{bc}) \cdot dW$$

$$W_{diod} = W'_{eff} + PDBCP, \quad W_{dios} = W'_{eff} + PSBCP$$

Body node KCL:

$$(I_{bs} + I_{bd}) + I_{bp} - I_{ii} - (I_{dgidl} + I_{sgisl}) - I_{gb} = 0$$

### Short Channel Effects (Sec. 5.8)

Scale length:

$$\lambda_f = \sqrt{TSI \cdot \epsilon_{ratio} \cdot TOXE}$$

$$\lambda_s = \sqrt{TSI \cdot \epsilon_{ratio} \cdot (TOXE + \frac{3}{8} TSI)}$$

Subthreshold slope (SOIMOD=0):

$$n = 1 + \frac{CIT + NFACTOR + CDSCD \cdot V_{dsx} - CDSCB \cdot V_{bsx}}{C_{ox}}$$

Subthreshold slope (SOIMOD=1):

$$n = 1 + \frac{CIT + NFACTOR + C_{dsc}}{C_{ox} + C_B \| C_{BOX}}$$

Threshold voltage shifts:

$$\Delta V_{th,VNUD} = K1 \cdot (\sqrt{\phi_{st} - V_{bs}} - \sqrt{\phi_{st}}) - K2 \cdot V_{bsx}$$

$$\Delta V_{th,DIBL} = -(ETA0 + ETAB \cdot V_{bsx}) \cdot V_{dsx}$$

$$\Delta V_{th,DITS} = -n\frac{kT}{q} \ln\left(\frac{L_{eff}}{L_{eff} + DVTP0 \cdot (1 + e^{-DVTP1 \cdot V_{ds}})}\right) - \left(DVTP5 + \frac{DVTP2}{L_{eff}}\right) \cdot DVTP3 \cdot \tanh(DVTP4 \cdot V_{dsx})$$

$$V_{gfb} = V_g - V_{fb} - \Delta V_{th,all}$$

### Drain Saturation Voltage (Sec. 5.9)

Effective field:

$$E_{eff,s} = 10^{-8} \cdot \frac{q_{bs} + \eta \cdot q_{is}}{\epsilon_{ratio} \cdot TOXE}$$

where $\eta = \frac{1}{2} \cdot ETAMOB$ (NMOS) or $\frac{1}{3} \cdot ETAMOB$ (PMOS).

Mobility degradation for Vdsat:

$$D_{mobs} = 1 + (UA + UC \cdot V_{bsx}) \cdot E_{eff,s}^{EU} + \frac{UD}{\left(\frac{1}{2} \cdot \sqrt{1 + q_{bs}/q_{is}}\right)^{UCS}}$$

**SOIMOD=0:**

$$\lambda_C = \frac{2 \cdot U0 \cdot nV_t}{D_{mobs}^{PSAT} \cdot VSAT \cdot L_{eff}} \cdot \left[1 + PTWG \cdot \frac{10 \cdot PSATX \cdot q_s \cdot T_0}{10 \cdot PSATX + q_s \cdot T_0}\right]$$

$$q_{dsat} = \frac{\lambda_C}{2} \cdot \frac{q_s^2 + q_s}{1 + \frac{\lambda_C}{2}(1 + q_s)}$$

**SOIMOD=1 without Rds:**

$$V_{dsat} = \frac{E_{sat}L \cdot KSATIV_i \cdot (q_{is} + 2kT/q)}{E_{sat}L + KSATIV_i \cdot (q_{is} + 2kT/q)}$$

**SOIMOD=1 with Rds:**

$$V_{dsat} = \frac{T_b - \sqrt{T_b^2 - 2T_a T_c}}{T_a}$$

where $T_a = 2 \cdot WVCox \cdot R_{ds,s}$, $T_b = KSATIV_i(q_{is} + 2kT/q)(1 + 3 \cdot WVCox \cdot R_{ds,s}) + E_{sat}L$.

### Mobility Degradation (Sec. 5.10)

$$E_{eff,m} = 10^{-8} \cdot \frac{q_{ba} + \eta \cdot q_{ia}}{\epsilon_{ratio} \cdot TOXE}$$

$$D_{mob} = 1 + (UA + UC \cdot V_{bsx}) \cdot E_{eff,m}^{EU} + \frac{UD}{\left(\frac{1}{2}\sqrt{1 + q_{ba}/q_{ia}}\right)^{UCS}}$$

### Output Conductance (Sec. 5.11)

Channel Length Modulation:

$$M_{CLM} = 1 + C_{clm} \cdot \ln\left(1 + \frac{V_{ds} - V_{dseff}}{V_{asat}}\right) \cdot \frac{1}{C_{clm}}$$

$$V_{asat} = V_{dssat} + E_{sat} \cdot L_{eff}$$

DIBL:

$$VA_{DIBL} = \frac{q_{ia} + 2kT/q}{\theta_{rout}} \cdot \left(1 - \frac{V_{dssat}}{V_{dssat} + q_{ia} + 2kT/q}\right) \cdot PVAGfactor \cdot \frac{1}{1 + PDIBLCB \cdot V_{bsx}}$$

$$M_{DIBL} = 1 + \frac{V_{ds} - V_{dseff}}{VA_{DIBL}}$$

DITS:

$$VA_{DITS} = \frac{1}{PDITS} \cdot F \cdot [1 + (1 + PDITSL \cdot L_{eff})\exp(PDITSD \cdot V_{ds})]$$

SCBE:

$$VA_{SCBE} = \frac{L_{eff}}{PSCBE2} \cdot \exp\left(\frac{PSCBE1 \cdot litl}{V_{ds} - V_{dseff}}\right)$$

Total output conductance multiplier:

$$M_{oc} = M_{DIBL} \cdot M_{CLM} \cdot M_{DITS} \cdot M_{SCBE}$$

### Velocity Saturation (Sec. 5.12)

**SOIMOD=1:**

$$D_{vsat} = \frac{D_{mob} \cdot D_{\Delta L}}{2} \cdot (1 + \sqrt{1 + 2 \cdot Z_{sat}})$$

$$D_{tot} = D_{mob} \cdot D_{vsat} \cdot D_r$$

**SOIMOD=0:**

$$T_1 = 2\lambda_C(q_s - q_{deff})$$

$$D_{vsat} = \frac{1}{2}\left(\sqrt{1 + T_1^2} + \frac{1}{T_1}\ln(T_1 + \sqrt{1 + T_1^2})\right)$$

Non-saturation effect:

$$T_0 = A1 + \frac{A2}{q_{ia} + 2nV_t}$$

$$N_{sat} = 0.5(1 + \sqrt{1 + T_3}), \quad I_{ds} = I_{ds}/N_{sat}$$

### Effective Mobility (Sec. 5.13)

$$\mu_{eff} = \frac{U0}{D_{tot}}$$

### Drain Current Model (Sec. 5.14)

**SOIMOD=1, without velocity saturation:**

$$I_{ds} = -\frac{W_{eff}}{L_{eff}} \cdot C_{ox} \cdot \mu_{eff} \cdot (Q_{im} + V_t \cdot \alpha_{DD}) \cdot (\psi_d - \psi_s)$$

**SOIMOD=1, with velocity saturation:**

$$I_{ds} = -\frac{W_{eff}}{L_{eff}} \cdot C_{ox} \cdot \mu_{eff} \cdot (Q_{im} + V_t \cdot \alpha_{DD}) \cdot \frac{(\psi_d - \psi_s)}{D_{vsat}}$$

**SOIMOD=0, without velocity saturation:**

$$I_{DS} = 2 n_q \mu_{eff} \frac{W_{eff}}{L_{eff}} C_{ox} nV_t^2 [(q_s - q_{deff})(q_s + q_{deff} + 1)]$$

**SOIMOD=0, with velocity saturation:**

$$I_{DS} = 2 n_q \mu_{eff} \frac{W_{eff}}{L_{eff}} C_{ox} nV_t^2 [(q_s - q_{deff})(q_s + q_{deff} + 1)] \cdot M_{oc}$$

where $\mu_{eff} = U0/D_{tot}$ and $D_{tot} = D_{mob} \cdot D_{vsat} \cdot D_r$.

### MNUD Models (Sec. 5.16-5.17)

$$MNUD = 1 + K0 \cdot \left[\frac{q_s - q_{deff}}{M0 + q_s + q_{deff}}\right]^2$$

$$MNUD1 = \exp\left[\frac{-C0}{(C0SI + C0SISAT \cdot (q_s - q_{deff})^2)(q_s + q_{deff}) + 2nV_t}\right]$$

$$I_{DS} = I_{DS} \cdot M_{oc} / (MNUD \cdot MNUD1)$$

### AbulkIV Model (Sec. 5.18)

$$AbulkIV = 1 + \frac{A0 \cdot T_1 - AGS \cdot q_s^{AGS1} \cdot V_T \cdot T_1}{1 + KETA \cdot V_{bsx}}$$

$$T_1 = \frac{L_{eff}}{L_{eff} + \sqrt{XJ \cdot X_{dep}}}$$

$$V_{dssat} = V_{dssat}/AbulkIV$$

### Threshold Voltage (Sec. 5.15)

$$V_{TH,long} = VFB + \psi_{p,th} \cdot V_t - \gamma' \sqrt{\psi_{p,th} \cdot V_t}$$

$$V_{TH} = V_{TH,long} - \Delta V_{th,all}$$

### Subthreshold Hump / Edge FET (Sec. 5.19)

Edge FET current is added to main $I_{ds}$ when EDGEFET=1, using WEDGE instead of $W_{eff}$ and separate edge parameters (DGAMMAEDGE, DVTEDGE, NFACTOREDGE, etc.).

### Sub-Surface Leakage (Sec. 5.20)

$$I_{ssl} = sigvds \cdot NF \cdot W_{eff} \cdot SSL0_{NT} \cdot e^{T_3} \cdot \exp\left(-SSL1_{NT} \cdot L + \frac{T_5}{V_t}\right) \cdot \left(\exp\frac{SSL2 \cdot V_{dsx}}{V_t} - 1\right)$$

### Gate Resistance (Sec. 5.21)

$$R_{geltd} = \frac{RSHG \cdot \left(XGW + \frac{W_{eff,ci}}{3 \cdot NGCON}\right)}{NGCON \cdot (L_{drawn} - XGL) \cdot NF}$$

IIR model (RGATEMOD=2):

$$\frac{1}{R_{ii}} = XRCRG1 \cdot NF \cdot \frac{I_{ds}}{V_{dseff}} + XRCRG2 \cdot \frac{W_{eff} \mu_{eff} C_{ox,eff} V_t}{L_{eff}}$$

### Source/Drain Junction Charges (Sec. 4.2)

$$Q_{jswg} = Q_{bsdep} + Q_{bsdif}$$

Diffusion charges:

$$Q_{bsdif} = \tau \frac{W'_{eff}}{N_{seg}} T_{si} J_{sbjt}\left(1 + L_{dif0} L_{bj0}\left(\frac{1}{L_{eff}} + \frac{1}{L_n}\right)^{N_{dif}}\right) \left(\exp\frac{V_{bs}}{n_{dios} V_t} - 1\right) \frac{1}{\sqrt{E_{hlis} + 1}}$$

### Extrinsic Capacitances (Sec. 4.3)

Substrate-to-source bottom capacitance:

$$C_{esb} = \frac{C_{box} - C_{min}}{2} \tanh(ACESB \cdot V_{es} + BCESB) + \frac{C_{box} + C_{min}}{2}$$

Substrate-to-source sidewall capacitance:

$$C_{s/d,esw} = C_{sdesw} \cdot \log\left(CFRCOEFF \cdot \left(1 + \frac{T_{si}}{T_{box}}\right)\right)$$

### Junction Diode CV Model (Sec. 6.1)

Source junction capacitance:

$$C_{bs} = As_{eff} \cdot C_{jbs} + Ps_{eff} \cdot C_{jbssw} + W_{eff,cj} \cdot NF \cdot C_{jbsswg}$$

Unit-area capacitance with grading:

$$C_{jbs} = \begin{cases} CJS(T) \cdot \left(1 - \frac{V_{bs}}{PBS(T)}\right)^{-MJS} & \text{if } V_{bs}/PBS(T) \le 0.9 \\ CJS(T) \cdot \frac{1}{(1-0.9)^{MJS}} \cdot \left(1 + MJS\left(\frac{V_{bs}/PBS(T) - 1}{1 - 0.9} + 1\right)\right) & \text{otherwise} \end{cases}$$

Analogous expressions for $C_{jbssw}$, $C_{jbsswg}$, $C_{jbd}$, $C_{jbdsw}$, $C_{jbdswg}$ with respective parameters.

### Noise Models (Sec. 5.22)

**Flicker Noise (FNOIMOD=0):**

$$S_{id,inv}(f) = \frac{kTq^2\mu_{eff}I_{ds}}{C_{oxe}L_{eff}^2 \cdot NOIFEF \cdot 10^{10}} \left[NOIA \cdot \ln\frac{N_0 + N^*}{N_l + N^*} + NOIB(N_0 - N_l) + \frac{NOIC}{2}(N_0^2 - N_l^2)\right]$$

$$+ \frac{kT I_{ds}^2 \Delta L_{clm}}{W_{eff} L_{eff}^2 \cdot NOIFEF \cdot 10^{10}} \cdot \frac{NOIA + NOIB \cdot N_l + NOIC \cdot N_l^2}{(N_l + N^*)^2}$$

$$S_{id,subVt}(f) = \frac{NOIA \cdot kT \cdot I_{ds}^2}{W_{eff} L_{eff} f^{EF} N^{*2} \cdot 10^{10}}$$

$$S_{id}(f) = \frac{S_{id,inv} \cdot S_{id,subVt}}{S_{id,inv} + S_{id,subVt}}$$

$$N_0 = \frac{2n_q C_{ox} V_t q_s}{q}, \quad N_l = \frac{2n_q C_{ox} V_t q_{deff}}{q}, \quad N^* = \frac{V_t(C_{ox} + C_d + CIT)}{q}$$

Flicker noise tuning:

$$S_{ID,new} = \frac{S_{ID,old}}{1 + NOIA1 \cdot (q_s - q_{deff})^{NOIAX}}$$

S/D resistance flicker noise:

$$S_{id,Rs} = \frac{KFNS \cdot W \cdot (I_d/W)^{AFNS}}{f^{BFNS}}$$

**Thermal Noise (TNOIMOD=0):**

$$Q_{inv} = |Q_{s,intrinsic} + Q_{d,intrinsic}| \cdot NF_{INtotal}$$

$$i_d^2 = NTNOI \cdot \frac{4kT\Delta f}{L_{eff}^2} \cdot \frac{\mu_{eff} Q_{inv}}{R_{ds} + \mu_{eff} Q_{inv}} \quad \text{(RDSMOD=0)}$$

**Thermal Noise (TNOIMOD=1):**

$$\beta_{tnoi} = RNOIA \cdot \left(1 + TNOIA \cdot L_{eff} \cdot \left(\frac{q_{ia}}{E_{sat,noi}L_{eff}}\right)^2\right)$$

$$S_{id} = 4kT \mu C_{ox} \frac{W_{eff}}{L_{vsat}} V_t D_{ptwg} M_{oc} \cdot \frac{q_s + q_{deff}}{2} \cdot \left[\left(1 + \frac{\beta_{lowId}}{TNOIK2 + q_{ia}} \cdot \frac{V_{dseff}}{V_{dsat}}\right) + (3\beta_{tnoi})^2 \frac{(q_s - q_{deff})^2}{12(1 + (q_s + q_{deff})/2)}\right]$$

**Gate Current Shot Noise:**

$$i^2_{gs} = 2q(I_{gcs} + I_{gs}), \quad i^2_{gd} = 2q(I_{gcd} + I_{gd}), \quad i^2_{gb} = 2qI_{gb,inv}$$

**Resistor Noise:**

$$\frac{i^2_{RS}}{\Delta f} = \frac{4kT}{R_{source}}, \quad \frac{i^2_{RD}}{\Delta f} = \frac{4kT}{R_{drain}}, \quad \frac{i^2_{RG}}{\Delta f} = \frac{4kT}{R_{geltd}}$$

### Self Heating (Sec. 5.23)

$$R_{th} = \frac{RTH0}{(WTH0 + W_{eff}) \cdot NF}$$

$$C_{th} = CTH0 \cdot (WTH0 + W_{eff}) \cdot NF$$

### Temperature Dependence (Sec. 8)

Threshold voltage:

$$V_{th}(T) = V_{th}(TNOM) + (KT1_i + KT2_i \cdot V_{bseff}) \cdot \left(\frac{T}{TNOM}\right)^{KT1EXP} - 1)$$

$$V_{fb}(T) = V_{fb}(TNOM) - KT1 \cdot \left(\frac{T}{TNOM} - 1\right)$$

$$NFACTOR(T) = NFACTOR(TNOM) + TFACTOR \cdot \left(\frac{T}{TNOM} - 1\right)$$

$$ETA0(T) = ETA0(TNOM) + TETA0 \cdot \left(\frac{T}{TNOM} - 1\right)$$

Mobility:

$$U0(T) = U0(TNOM) \cdot (T/TNOM)^{UTE}$$

$$UA(T) = UA(TNOM) \cdot [1 + UA1 \cdot (T - TNOM)]$$

$$UC(T) = UC(TNOM) \cdot [1 + UC1 \cdot (T - TNOM)]$$

$$UD(T) = UD(TNOM) \cdot (T/TNOM)^{UD1}$$

$$UCS(T) = UCS(TNOM) \cdot (T/TNOM)^{UCSTE}$$

$$EU(T) = EU(TNOM) \cdot (1 + EU1 \cdot (T/TNOM - 1))$$

Saturation velocity:

$$VSAT(T) = VSAT(TNOM) \cdot (T/TNOM)^{-AT}$$

LDD resistance:

$$rdstemp = (T/TNOM)^{PRT}$$

$$RDSW(T) = RDSW(TNOM) \cdot rdstemp$$

Junction diode IV (source side):

$$J_{ss}(T) = JSS(TNOM) \cdot \exp\left(\frac{E_g(TNOM)/(V_t(TNOM)) - E_g(T)/V_t(T) + XTIS \cdot \ln(T/TNOM)}{NJS}\right)$$

Junction diode CV:

$$CJS(T) = CJS(TNOM) + TCJ \cdot (T - TNOM)$$

$$PBS(T) = PBS(TNOM) - TPB \cdot (T - TNOM)$$

Bandgap:

$$E_{g0} = BG0SUB - \frac{TBGASUB \times T_{nom}^2}{T_{nom} + TBGBSUB}$$

$$E_g = BG0SUB - \frac{TBGASUB \times T^2}{T + TBGBSUB}$$

Intrinsic carrier concentration:

$$n_i = NI0SUB \times \left(\frac{T}{T_{nom}}\right)^{3/2} \times \exp\left(\frac{E_g}{2kT_{nom}} - \frac{E_g}{2kT}\right)$$

### Stress Effect Model (Sec. 9)

$$\rho_{\mu_{eff}} = \frac{KU0}{K_{stress,u0}} \cdot (Inv_{sa} + Inv_{sb})$$

$$Inv_{sa} = \frac{1}{SA + 0.5 \cdot L_{drawn}}, \quad Inv_{sb} = \frac{1}{SB + 0.5 \cdot L_{drawn}}$$

$$K_{stress,u0} = \left(1 + \frac{LKU0}{(L_{drawn}+XL)^{LLODKU0}} + \frac{WKU0}{(W_{drawn}+XW+WLOD)^{WLODKU0}} + \ldots\right) \times \left(1 + TKU0 \cdot \left(\frac{T}{TNOM} - 1\right)\right)$$

$$\mu_{eff} = \frac{1 + \rho_{\mu_{eff}}(SA, SB)}{1 + \rho_{\mu_{eff}}(SA_{ref}, SB_{ref})} \cdot \mu_{eff,0}$$

$$v_{sat,temp} = \frac{1 + KVSAT \cdot \rho_{\mu_{eff}}(SA, SB)}{1 + KVSAT \cdot \rho_{\mu_{eff}}(SA_{ref}, SB_{ref})} \cdot v_{sat,0}$$

Vth-related:

$$VTH0 = VTH0_{orig} + \frac{KVTH0}{K_{stress,vth0}} \cdot (Inv_{sa} + Inv_{sb} - Inv_{sa,ref} - Inv_{sb,ref})$$

### Well Proximity Effect (Sec. 10)

If SCA, SCB, SCC given:

$$V_{th0} = V_{th0,org} + KVTH0WE \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC)$$

$$K2 = K2_{org} + K2WE \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC)$$

$$\mu_{eff} = \mu_{eff,org} \cdot (1 + KU0WE \cdot (SCA + WEB \cdot SCB + WEB \cdot SCC))$$

Otherwise computed from SC using SCREF and local SCA/SCB/SCC formulas.

### C-V Model Charges (Sec. 11)

**SOIMOD=1 — Inversion charge from surface potential:**

Gate charge:

$$Q_G = v_{gfb} - \psi_m + \frac{\Delta\psi^2}{12H}$$

Drain charge (Ward-Dutton partition):

$$Q_D = \frac{q_{im}}{2} + \frac{\alpha_{DD} \cdot \Delta\psi}{12}\left(1 - \frac{\Delta\psi}{2H} - \frac{\Delta\psi^2}{20H^2}\right)$$

$$Q_S = Q_I - Q_D$$

$$Q_I = q_{im} + \frac{\alpha_{DD} \cdot \Delta\psi^2}{12H}$$

$$Q_B = Q_G - Q_I$$

**SOIMOD=0 — Normalized charge-based:**

$$q_I = n_q \left[q_s + q_d + \frac{1}{3} \cdot \frac{(q_s - q_d)^2}{1 + q_s + q_d}\right]$$

$$q_B = v_g - v_{fb} - \psi_p - (n_q - 1)\left[q_s + q_d + \frac{1}{3} \cdot \frac{(q_s - q_d)^2}{1 + q_s + q_d}\right]$$

Source and drain charges:

$$Q_s = \frac{n_q}{3}\left[2q_s + q_{deff} + \frac{1}{2}\left(1 + \frac{4}{5}q_s + \frac{6}{5}q_{deff}\right)\frac{(q_s - q_{deff})^2}{1 + q_s + q_{deff}}\right]$$

$$Q_d = \frac{n_q}{3}\left[q_s + 2q_{deff} + \frac{1}{2}\left(1 + \frac{6}{5}q_s + \frac{4}{5}q_{deff}\right)\frac{(q_s - q_{deff})^2}{1 + q_s + q_{deff}}\right]$$

With CLM and velocity saturation:

$$Q_i = \frac{n_q}{MDL}\left[(q_s + q_{deff}) + \frac{1}{3}(q_s - q_{deff})^2 \frac{AbulkCV \cdot DVSAT}{MDL(1 + q_s + q_{deff})}\right] + 2n_q(MDL - 1)q_{deff}$$

**Quantum Mechanical Effect:**

$$X_{DC}^{inv} = \frac{ADOS \cdot 1.9 \times 10^{-9}}{\left(1 + \frac{Q_i + ETAQM \cdot Q_B}{QM0}\right)^{0.7 \cdot BDOS}}$$

$$C_{ox}^{inv} = \frac{3.9\epsilon_0}{TOXP \cdot \frac{3.9}{EPSROX} + \frac{X_{DC}^{inv}}{\epsilon_{ratio}}}$$

**Bias-dependent overlap capacitance:**

$$V_{gs,overlap} = \frac{1}{2}\left(V_{gs} - V_{fbsd} + \delta_1 - \sqrt{(V_{gs} - V_{fbsd} + \delta_1)^2 + 4\delta_1}\right)$$

$$\frac{Q_{gs,ov}}{NF \cdot W_{eff,CV}} = CGSO \cdot V_{gs} + CGSL\left[V_{gs} - V_{fbsd} - V_{gs,overlap} - \frac{CKAPPAS}{2}\left(\sqrt{\frac{4T_6}{CKAPPAS}} - 1\right)\right]$$

Outer fringing capacitance:

$$CF = \frac{2 \cdot EPSROX \cdot \epsilon_0}{\pi} \ln\left[CFRCOEFF \cdot \left(1 + \frac{0.4 \times 10^{-6}}{TOX}\right)\right]$$

### Smoothing Functions (Appendix B)

Polynomial smoothing for $f(x) = x$ when $x > x_1$ and $f(x) = k$ when $x < x_2$, with continuous 3rd-order derivatives:

$$f(x) = x_0 + \Delta x \cdot \left[\frac{5}{64} + \frac{z}{2} + z^2 \left(\frac{15}{16} - z^2\left(\frac{5}{4} - z^2\right)\right)\right]$$

where $z = (x - x_0)/\Delta x$, $x_0 = (x_1 + x_2)/2$, $\Delta x = x_1 - x_2$.

Sigma functions used in SOIMOD=1 initial guess:

$$\texttt{sigma0}(d, f, \tau, \eta, z): \quad \nu = d + f, \quad \mu_\tau = \frac{\nu^2}{\tau} + \frac{f}{2} \cdot \left(\frac{f}{2} - d\right)$$

$$z = \eta + \frac{d \cdot \nu \cdot \tau}{\mu_\tau + \frac{\mu_\tau}{\tau^2} \cdot f\left(\frac{f^2}{3} - d\right)/\nu}$$

PE3 (3rd-order polynomial expansion of exp):

$$PE3(k) = 1 + k\left(1 + 0.5k\left(1 + \frac{k}{3}\right)\right)$$
