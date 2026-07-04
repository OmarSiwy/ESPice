# BSIM4 4.8.3 -- Parameter & Equation Reference

> Bulk planar MOSFET (legacy C-based)

## Model Topology

BSIM4 is a four-terminal MOSFET model (Gate, Drain, Source, Body/Bulk) with optional internal nodes for gate resistance (up to two internal gate nodes via `rgateMod`), source/drain LDD resistance (`rdsMod=1` adds internal S/D nodes), substrate resistance network (`rbodyMod=1,2` adds up to five body sub-nodes: bNodePrime, dbNode, sbNode, bNode), and a charge-deficit NQS node (`trnqsMod=1`). The intrinsic device comprises a channel current source between internal source and drain, gate tunneling current sources (Igb, Igcs, Igcd, Igs, Igd), impact ionization current (Iii), GIDL/GISL currents, junction diode IV/CV on both source and drain sides, intrinsic and overlap/fringing capacitances, and noise sources (flicker, thermal, shot).

## Parameters

### A.1 Model Selectors / Controllers

| Parameter | Default | Binnable | Description |
|-----------|---------|----------|-------------|
| LEVEL | 14 | NA | SPICE3 model selector |
| VERSION | 4.83 | NA | Model version number |
| BINUNIT | 1 | NA | Binning unit selector |
| PARAMCHK | 1 | NA | Switch for parameter value check |
| MOBMOD | 0 | NA | Mobility model selector (0-6) |
| MTRLMOD | 0 | NA | New material model selector (0=original, 1=new) |
| RDSMOD | 0 | NA | Bias-dependent S/D resistance model selector (0=internal, 1=external) |
| IGCMOD | 0 | NA | Gate-to-channel tunneling current model selector (0=OFF, 1,2=ON) |
| IGBMOD | 0 | NA | Gate-to-substrate tunneling current model selector (0=OFF, 1=ON) |
| CVCHARGEMOD | 0 | NA | Threshold voltage for C-V model selector |
| CAPMOD | 2 | NA | Capacitance model selector (0,1,2) |
| RGATEMOD | 0 | NA | Gate resistance model selector (0=none, 1=constant, 2=IIR variable, 3=IIR two-node). Also instance parameter. |
| RBODYMOD | 0 | NA | Substrate resistance network model selector (0=off, 1=on, 2=on scalable). Also instance parameter. |
| TRNQSMOD | 0 | NA | Transient NQS model selector (0=OFF, 1=ON). Also instance parameter. |
| ACNQSMOD | 0 | NA | AC small-signal NQS model selector (0=OFF, 1=ON). Also instance parameter. |
| FNOIMOD | 1 | NA | Flicker noise model selector (0=simple, 1=unified) |
| TNOIMOD | 0 | NA | Thermal noise model selector (0=charge-based, 1=holistic, 2=gate+drain) |
| DIOMOD | 1 | NA | Source/drain junction diode IV model selector (0=resistance-free, 1=breakdown-free, 2=resistance-and-breakdown) |
| TEMPMOD | 0 | No | Temperature mode selector (0=original, 1,2,3=new format) |
| PERMOD | 1 | NA | Whether PS/PD includes gate-edge perimeter (1=including) |
| GEOMOD | 0 | NA | Geometry-dependent parasitics model selector for S/D connections. Also instance parameter. |
| RGEOMOD | 0 | NA | S/D diffusion resistance and contact model selector. Instance parameter only. |
| WPEMOD | 0 | NA | Flag for well proximity effect model (1=activate) |
| GIDLMOD | 0 | NA | GIDL current model selector |

### A.2 Process Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| EPSROX | $\epsilon_{ox}/\epsilon_0$ | -- | 3.9 | No | Gate dielectric constant relative to vacuum |
| TOXE | $T_{OXE}$ | m | 3.0e-9 | No | Electrical gate equivalent oxide thickness |
| EOT | -- | m | 1.5e-9 | No | Equivalent SiO2 thickness (for mtrlMod=1) |
| TOXP | $T_{OXP}$ | m | TOXE | No | Physical gate equivalent oxide thickness |
| TOXM | $T_{OXM}$ | m | TOXE | No | Tox at which parameters are extracted |
| DTOX | -- | m | 0.0 | No | Defined as (TOXE - TOXP) |
| XJ | $X_J$ | m | 1.5e-7 | Yes | S/D junction depth |
| GAMMA1 | $\gamma_1$ | V^0.5 | calculated | No | Body-effect coefficient near the surface |
| GAMMA2 | $\gamma_2$ | V^0.5 | calculated | No | Body-effect coefficient in the bulk |
| NDEP | $N_{DEP}$ | cm^-3 | 1.7e17 | Yes | Channel doping concentration at depletion edge for zero body bias |
| NSUB | $N_{SUB}$ | cm^-3 | 6.0e16 | Yes | Substrate doping concentration |
| NGATE | $N_{GATE}$ | cm^-3 | 0.0 | Yes | Poly-Si gate doping concentration |
| NSD | $N_{SD}$ | cm^-3 | 1.0e20 | Yes | Source/drain doping concentration |
| VBX | -- | V | calculated | No | Vbs at which depletion width equals XT |
| XT | -- | m | 1.55e-7 | Yes | Doping depth |
| RSH | -- | ohm/sq | 0.0 | No | Source/drain sheet resistance |
| RSHG | -- | ohm/sq | 0.1 | No | Gate electrode sheet resistance |

### A.3 Basic Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| VTH0 (VTHO) | $V_{TH0}$ | V | 0.7 (NMOS), -0.7 (PMOS) | Yes | Long-channel threshold voltage at Vbs=0 |
| DELVTO | $\Delta V_{TO}$ | V | 0.0 | No | Zero bias threshold voltage variation (instance only) |
| VFB | $V_{FB}$ | V | -1.0 | Yes | Flat-band voltage |
| VDDEOT | -- | V | 1.5 (NMOS), -1.5 (PMOS) | No | Gate voltage at which EOT is measured |
| LEFFEOT | -- | m | 1e-6 | No | Effective gate length at which EOT is measured |
| WEFFEOT | -- | m | 10e-6 | No | Effective width at which EOT is measured |
| TEMPEOT | -- | C | 27 | No | Temperature at which EOT is measured |
| PHIN | $\Phi_N$ | V | 0.0 | Yes | Non-uniform vertical doping effect on surface potential |
| EASUB | -- | eV | 4.05 | No | Electron affinity of substrate |
| EPSRSUB | -- | -- | 11.7 | No | Dielectric constant of substrate relative to vacuum |
| EPSRGATE | -- | -- | 11.7 | No | Dielectric constant of gate relative to vacuum (0 = metal gate) |
| NI0SUB | -- | m^-3 | 1.45e16 | No | Intrinsic carrier concentration at T=300.15K |
| BG0SUB | -- | eV | 1.16 | No | Band-gap of substrate at T=0K |
| TBGASUB | -- | eV/K | 7.02e-4 | No | First parameter of band-gap change due to temperature |
| TBGBSUB | -- | K | 1108.0 | No | Second parameter of band-gap change due to temperature |
| ADOS | -- | -- | 1.0 | No | Density of states parameter to control charge centroid |
| BDOS | -- | -- | 1.0 | No | Density of states parameter to control charge centroid |
| K1 | $K_1$ | V^0.5 | 0.5 | Yes | First-order body bias coefficient |
| K2 | $K_2$ | -- | 0.0 | Yes | Second-order body bias coefficient |
| K3 | $K_3$ | -- | 80.0 | Yes | Narrow width coefficient |
| K3B | $K_{3B}$ | V^-1 | 0.0 | Yes | Body effect coefficient of K3 |
| W0 | $W_0$ | m | 2.5e-6 | Yes | Narrow width parameter |
| LPE0 | $LPE0$ | m | 1.74e-7 | Yes | Lateral non-uniform doping parameter at Vbs=0 |
| LPEB | $LPEB$ | m | 0.0 | Yes | Lateral non-uniform doping effect on K1 |
| VBM | -- | V | -3.0 | Yes | Maximum applied body bias in VTH0 calculation |
| DVT0 | $DVT0$ | -- | 2.2 | Yes | First coefficient of short-channel effect on Vth |
| DVT1 | $DVT1$ | -- | 0.53 | Yes | Second coefficient of short-channel effect on Vth |
| DVT2 | $DVT2$ | V^-1 | -0.032 | Yes | Body-bias coefficient of short-channel effect on Vth |
| DVTP0 | $DVTP0$ | m | 0.0 | Yes | Coefficient of drain-induced Vth shift for pocket implant |
| DVTP1 | $DVTP1$ | V^-1 | 0.0 | Yes | Coefficient of drain-induced Vth shift for pocket implant |
| DVTP2 | $DVTP2$ | V*m^DVTP3 | 0.0 | Yes | Coefficient of drain-induced Vth shift for pocket implant |
| DVTP3 | $DVTP3$ | -- | 0.0 | Yes | Exponent for DVTP2 length dependence |
| DVTP4 | $DVTP4$ | V^-1 | 0.0 | Yes | Coefficient of Vds dependence in tanh term |
| DVTP5 | $DVTP5$ | V | 0.0 | Yes | Constant offset in tanh DITS term |
| DVT0W | $DVT0W$ | -- | 0.0 | Yes | First coefficient of narrow width effect on Vth for small L |
| DVT1W | $DVT1W$ | m^-1 | 5.3e6 | Yes | Second coefficient of narrow width effect on Vth for small L |
| DVT2W | $DVT2W$ | V^-1 | -0.032 | Yes | Body-bias coefficient of narrow width effect for small L |
| U0 | $\mu_0$ | m^2/(Vs) | 0.067 (NMOS), 0.025 (PMOS) | Yes | Low-field mobility |
| UA | $UA$ | m/V | 1.0e-9 (mobMod=0,1); 1.0e-15 (mobMod=2,6) | Yes | First-order mobility degradation coefficient |
| UB | $UB$ | (m/V)^2 | 1.0e-19 | Yes | Second-order mobility degradation coefficient |
| UC | $UC$ | V^-1 or m/V^2 | -0.0465 (mobMod=1,5); -0.0465e-9 (mobMod=0,2) | Yes | Mobility degradation body-bias coefficient |
| UD | $UD$ | m^-2 | 0.0 | Yes | Mobility Coulomb scattering coefficient |
| UCS | $UCS$ | -- | 1.67 (NMOS), 1.0 (PMOS) | Yes | Coulombic scattering exponent |
| UP | $UP$ | m^-2 | 0.0 | Yes | Mobility channel length coefficient |
| LP | $LP$ | m | 1e-8 | Yes | Mobility channel length exponential coefficient |
| EU | $EU$ | -- | 1.67 (NMOS), 1.0 (PMOS) | No | Exponent for mobility degradation (mobMod=2) |
| VSAT | $v_{sat}$ | m/s | 8.0e4 | Yes | Saturation velocity |
| A0 | $A_0$ | -- | 1.0 | Yes | Channel-length dependence of bulk charge effect |
| AGS | $A_{GS}$ | V^-1 | 0.0 | Yes | Vgs dependence of bulk charge effect |
| B0 | $B_0$ | m | 0.0 | Yes | Bulk charge effect coefficient for channel width |
| B1 | $B_1$ | m | 0.0 | Yes | Bulk charge effect width offset |
| KETA | $KETA$ | V^-1 | -0.047 | Yes | Body-bias coefficient of bulk charge effect |
| A1 | $A_1$ | V^-1 | 0.0 | Yes | First non-saturation effect parameter |
| A2 | $A_2$ | -- | 1.0 | Yes | Second non-saturation factor |
| WINT | -- | m | 0.0 | No | Channel-width offset parameter |
| LINT | -- | m | 0.0 | No | Channel-length offset parameter |
| DWG | $DWG$ | m/V | 0.0 | Yes | Coefficient of gate bias dependence of Weff |
| DWB | $DWB$ | m/V^0.5 | 0.0 | Yes | Coefficient of body bias dependence of Weff |
| VOFF | $V_{OFF}$ | V | -0.08 | Yes | Offset voltage in subthreshold region |
| VOFFL | $V_{OFFL}$ | mV | 0.0 | No | Channel-length dependence of VOFF |
| MINV | $MINV$ | -- | 0.0 | Yes | Vgsteff fitting parameter for moderate inversion |
| NFACTOR | -- | -- | 1.0 | Yes | Subthreshold swing factor |
| ETA0 | $ETA0$ | -- | 0.08 | Yes | DIBL coefficient in subthreshold region |
| ETAB | $ETAB$ | V^-1 | -0.07 | Yes | Body-bias coefficient for subthreshold DIBL |
| DSUB | $DSUB$ | -- | DROUT | Yes | DIBL coefficient exponent in subthreshold |
| CIT | $C_{IT}$ | F/m^2 | 0.0 | Yes | Interface trap capacitance |
| CDSC | $C_{DSC}$ | F/m^2 | 2.4e-4 | Yes | Coupling capacitance between S/D and channel |
| CDSCB | -- | F/(Vm^2) | 0.0 | Yes | Body-bias sensitivity of CDSC |
| CDSCD | -- | F/(Vm^2) | 0.0 | Yes | Drain-bias sensitivity of CDSC |
| PCLM | $PCLM$ | -- | 1.3 | Yes | Channel length modulation parameter |
| PDIBLC1 | -- | -- | 0.39 | Yes | DIBL effect on Rout parameter 1 |
| PDIBLC2 | -- | -- | 0.0086 | Yes | DIBL effect on Rout parameter 2 |
| PDIBLCB | -- | V^-1 | 0.0 | Yes | Body bias coefficient of DIBL effect on Rout |
| DROUT | -- | -- | 0.56 | Yes | Channel-length dependence of DIBL on Rout |
| PSCBE1 | -- | V/m | 4.24e8 | Yes | First SCBE parameter |
| PSCBE2 | -- | m/V | 1.0e-5 | Yes | Second SCBE parameter |
| PVAG | -- | -- | 0.0 | Yes | Gate-bias dependence of Early voltage |
| DELTA | $\delta$ | V | 0.01 | Yes | Parameter for DC Vdseff smoothing |
| FPROUT | -- | V/m^0.5 | 0.0 | Yes | Pocket implant effect on Rout degradation |
| PDITS | -- | V^-1 | 0.0 | Yes | Drain-induced Vth shift on Rout |
| PDITSL | -- | m^-1 | 0.0 | No | Channel-length dependence of PDITS |
| PDITSD | -- | V^-1 | 0.0 | Yes | Vds dependence of drain-induced Vth shift for Rout |
| LAMBDA | $\Lambda$ | -- | 0.0 | Yes | Velocity overshoot coefficient (<=0 turns off) |
| VTL | -- | m/s | 2.05e5 | Yes | Thermal velocity (<=0 turns off source-end limit) |
| LC | -- | m | 0.0 | No | Velocity back scattering coefficient |
| XN | -- | -- | 3.0 | Yes | Velocity back scattering coefficient |

### A.4 Asymmetric and Bias-Dependent Rds Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| RDSW | $R_{DSW}$ | ohm*um^WR | 200.0 | Yes | Zero bias LDD resistance per unit width (rdsMod=0) |
| RDSWMIN | -- | ohm*um^WR | 0.0 | No | LDD resistance per unit width at high Vgs and zero Vbs (rdsMod=0) |
| RDW | $R_{DW}$ | ohm*um^WR | 100.0 | Yes | Zero bias drain LDD resistance per unit width (rdsMod=1) |
| RDWMIN | -- | ohm*um^WR | 0.0 | No | Drain LDD resistance at high Vgs and zero Vbs (rdsMod=1) |
| RSW | $R_{SW}$ | ohm*um^WR | 100.0 | Yes | Zero bias source LDD resistance per unit width (rdsMod=1) |
| RSWMIN | -- | ohm*um^WR | 0.0 | No | Source LDD resistance at high Vgs and zero Vbs (rdsMod=1) |
| PRWG | -- | V^-1 | 1.0 | Yes | Gate-bias dependence of LDD resistance |
| PRWB | -- | V^-0.5 | 0.0 | Yes | Body-bias dependence of LDD resistance |
| WR | -- | -- | 1.0 | Yes | Channel-width dependence parameter of LDD resistance |
| NRS | -- | -- | 1.0 | No | Number of source diffusion squares (instance only) |
| NRD | -- | -- | 1.0 | No | Number of drain diffusion squares (instance only) |

### A.5 Impact Ionization Current Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| ALPHA0 | $\alpha_0$ | m/V | 0.0 | Yes | First parameter of impact ionization current |
| ALPHA1 | $\alpha_1$ | V^-1 | 0.0 | Yes | Channel length scaling of impact ionization current |
| BETA0 | $\beta_0$ | V | 0.0 | Yes | First Vds dependent parameter of impact ionization current |

### A.6 Gate-Induced Drain Leakage Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| AGIDL | -- | mho | 0.0 | Yes | Pre-exponential coefficient for GIDL |
| BGIDL | -- | V/m | 2.3e9 | Yes | Exponential coefficient for GIDL |
| CGIDL | -- | V^3 | 0.5 | Yes | Body-bias effect parameter on GIDL |
| EGIDL | -- | V | 0.8 | Yes | Fitting parameter for band bending (GIDL) |
| RGIDL | -- | -- | 1.0 | Yes | GIDL gate bias dependence parameter |
| KGIDL | -- | V | 0.0 | Yes | GIDL body bias dependence parameter |
| FGIDL | -- | V | 0.0 | Yes | GIDL body bias dependence parameter |
| AGISL | -- | mho | AGIDL | Yes | Pre-exponential coefficient for GISL |
| BGISL | -- | V/m | BGIDL | Yes | Exponential coefficient for GISL |
| CGISL | -- | V^3 | CGIDL | Yes | Body-bias effect parameter on GISL |
| EGISL | -- | V | EGIDL | Yes | Fitting parameter for band bending (GISL) |
| RGISL | -- | -- | RGIDL | Yes | GISL gate bias dependence parameter |
| KGISL | -- | V | KGIDL | Yes | GISL body bias dependence parameter |
| FGISL | -- | V | FGIDL | Yes | GISL body bias dependence parameter |

### A.7 Gate Dielectric Tunneling Current Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| AIGBACC | -- | (Fs^2/g)^0.5 m^-1 | 9.49e-4 | Yes | Parameter for Igb in accumulation |
| BIGBACC | -- | (Fs^2/g)^0.5 m^-1 V^-1 | 1.71e-3 | Yes | Parameter for Igb in accumulation |
| CIGBACC | -- | V^-1 | 0.075 | Yes | Parameter for Igb in accumulation |
| NIGBACC | -- | -- | 1.0 | Yes | Parameter for Igb in accumulation |
| AIGBINV | -- | (Fs^2/g)^0.5 m^-1 | 1.11e-2 | Yes | Parameter for Igb in inversion |
| BIGBINV | -- | (Fs^2/g)^0.5 m^-1 V^-1 | 9.49e-4 | Yes | Parameter for Igb in inversion |
| CIGBINV | -- | V^-1 | 0.006 | Yes | Parameter for Igb in inversion |
| EIGBINV | -- | V | 1.1 | Yes | Parameter for Igb in inversion |
| NIGBINV | -- | -- | 3.0 | Yes | Parameter for Igb in inversion |
| AIGC | -- | (Fs^2/g)^0.5 m^-1 | 1.36e-2 (NMOS), 9.8e-3 (PMOS) | Yes | Parameter for Igcs and Igcd |
| BIGC | -- | (Fs^2/g)^0.5 m^-1 V^-1 | 1.71e-3 (NMOS), 7.59e-4 (PMOS) | Yes | Parameter for Igcs and Igcd |
| CIGC | -- | V^-1 | 0.075 (NMOS), 0.03 (PMOS) | Yes | Parameter for Igcs and Igcd |
| AIGS | -- | (Fs^2/g)^0.5 m^-1 | 1.36e-2 (NMOS), 9.8e-3 (PMOS) | Yes | Parameter for Igs |
| BIGS | -- | (Fs^2/g)^0.5 m^-1 V^-1 | 1.71e-3 (NMOS), 7.59e-4 (PMOS) | Yes | Parameter for Igs |
| CIGS | -- | V^-1 | 0.075 (NMOS), 0.03 (PMOS) | Yes | Parameter for Igs |
| DLCIG | -- | m | LINT | Yes | Source/drain overlap length for Igs |
| AIGD | -- | (Fs^2/g)^0.5 m^-1 | 1.36e-2 (NMOS), 9.8e-3 (PMOS) | Yes | Parameter for Igd |
| BIGD | -- | (Fs^2/g)^0.5 m^-1 V^-1 | 1.71e-3 (NMOS), 7.59e-4 (PMOS) | Yes | Parameter for Igd |
| CIGD | -- | V^-1 | 0.075 (NMOS), 0.03 (PMOS) | Yes | Parameter for Igd |
| DLCIGD | -- | m | LINT | Yes | Source/drain overlap length for Igd |
| NIGC | -- | -- | 1.0 | Yes | Parameter for Igcs, Igcd, Igs and Igd |
| POXEDGE | -- | -- | 1.0 | Yes | Factor for gate oxide thickness in S/D overlap regions |
| PIGCD | -- | -- | 1.0 | Yes | Vds dependence of Igcs and Igcd |
| NTOX | -- | -- | 1.0 | Yes | Exponent for gate oxide ratio |
| TOXREF | -- | m | 3.0e-9 | No | Nominal gate oxide thickness for tunneling model |
| VFBSDOFF | -- | V | 0.0 | Yes | Flatband voltage offset parameter |

### A.8 Charge and Capacitance Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| XPART | -- | -- | 0.0 | No | Charge partition parameter (0=40/60, 0.5=50/50, 1=0/100) |
| CGSO | -- | F/m | calculated | No | Non-LDD source-gate overlap capacitance per unit width |
| CGDO | -- | F/m | calculated | No | Non-LDD drain-gate overlap capacitance per unit width |
| CGBO | -- | F/m | 0.0 | No | Gate-bulk overlap capacitance per unit channel length |
| CGSL | -- | F/m | 0.0 | Yes | Overlap capacitance gate to lightly-doped source |
| CGDL | -- | F/m | 0.0 | Yes | Overlap capacitance gate to lightly-doped drain |
| CKAPPAS | -- | V | 0.6 | Yes | Bias-dependent overlap capacitance coefficient (source side) |
| CKAPPAD | -- | V | CKAPPAS | Yes | Bias-dependent overlap capacitance coefficient (drain side) |
| CF | -- | F/m | calculated | Yes | Fringing field capacitance |
| CLC | -- | m | 1.0e-7 | Yes | Constant term for short channel CV model |
| CLE | -- | -- | 0.6 | Yes | Exponential term for short channel CV model |
| DLC | -- | m | LINT | No | Channel-length offset parameter for CV model |
| DWC | -- | m | WINT | No | Channel-width offset parameter for CV model |
| VFBCV | -- | V | -1.0 | Yes | Flat-band voltage (capMod=0 only) |
| NOFF | -- | -- | 1.0 | Yes | CV parameter in Vgsteff,CV for weak to strong inversion |
| VOFFCV | -- | V | 0.0 | Yes | CV parameter in Vgsteff,CV for weak to strong inversion |
| VOFFCVL | -- | -- | 0.0 | Yes | Channel-length dependence of VOFFCV |
| MINVCV | -- | -- | 0.0 | Yes | Vgsteff,CV fitting parameter for moderate inversion |
| ACDE | -- | m/V | 1.0 | Yes | Exponential coefficient for charge thickness (capMod=2, accumulation/depletion) |
| MOIN | -- | -- | 15.0 | Yes | Coefficient for gate-bias dependent surface potential |

### A.9 High-Speed/RF Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| XRCRG1 | -- | -- | 12.0 | Yes | Distributed channel-resistance parameter for IIR and NQS |
| XRCRG2 | -- | -- | 1.0 | Yes | Excess channel diffusion resistance for IIR and NQS |
| RBPB | -- | ohm | 50.0 | No | Resistance bNodePrime to bNode (also instance) |
| RBPD | -- | ohm | 50.0 | No | Resistance bNodePrime to dbNode (also instance) |
| RBPS | -- | ohm | 50.0 | No | Resistance bNodePrime to sbNode (also instance) |
| RBDB | -- | ohm | 50.0 | No | Resistance dbNode to bNode (also instance) |
| RBSB | -- | ohm | 50.0 | No | Resistance sbNode to bNode (also instance) |
| GBMIN | -- | mho | 1.0e-12 | No | Minimum conductance in parallel with substrate resistances |
| RBPS0 | -- | ohm | 50.0 | No | Scaling prefactor for RBPS |
| RBPSL | -- | -- | 0.0 | No | Length scaling parameter for RBPS |
| RBPSW | -- | -- | 0.0 | No | Width scaling parameter for RBPS |
| RBPSNF | -- | -- | 0.0 | No | NF scaling parameter for RBPS |
| RBPD0 | -- | ohm | 50.0 | No | Scaling prefactor for RBPD |
| RBPDL | -- | -- | 0.0 | No | Length scaling parameter for RBPD |
| RBPDW | -- | -- | 0.0 | No | Width scaling parameter for RBPD |
| RBPDNF | -- | -- | 0.0 | No | NF scaling parameter for RBPD |
| RBPBX0 | -- | ohm | 100.0 | No | Scaling prefactor for RBPBX |
| RBPBXL | -- | -- | 0.0 | No | Length scaling parameter for RBPBX |
| RBPBXW | -- | -- | 0.0 | No | Width scaling parameter for RBPBX |
| RBPBXNF | -- | -- | 0.0 | No | NF scaling parameter for RBPBX |
| RBPBY0 | -- | ohm | 100.0 | No | Scaling prefactor for RBPBY |
| RBPBYL | -- | -- | 0.0 | No | Length scaling parameter for RBPBY |
| RBPBYW | -- | -- | 0.0 | No | Width scaling parameter for RBPBY |
| RBPBYNF | -- | -- | 0.0 | No | NF scaling parameter for RBPBY |
| RBSBX0 | -- | ohm | 100.0 | No | Scaling prefactor for RBSBX |
| RBSBY0 | -- | ohm | 100.0 | No | Scaling prefactor for RBSBY |
| RBDBX0 | -- | ohm | 100.0 | No | Scaling prefactor for RBDBX |
| RBDBY0 | -- | ohm | 100.0 | No | Scaling prefactor for RBDBY |
| RBSDBXL | -- | -- | 0.0 | No | Length scaling for RBSBX and RBDBX |
| RBSDBXW | -- | -- | 0.0 | No | Width scaling for RBSBX and RBDBX |
| RBSDBXNF | -- | -- | 0.0 | No | NF scaling for RBSBX and RBDBX |
| RBSDBYL | -- | -- | 0.0 | No | Length scaling for RBSBY and RBDBY |
| RBSDBYW | -- | -- | 0.0 | No | Width scaling for RBSBY and RBDBY |
| RBSDBYNF | -- | -- | 0.0 | No | NF scaling for RBSBY and RBDBY |

### A.10 Flicker and Thermal Noise Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| NOIA | -- | (eV)^-1 s^(1-EF) m^-3 | 6.25e41 (NMOS), 6.188e40 (PMOS) | No | Flicker noise parameter A |
| NOIB | -- | (eV)^-1 s^(1-EF) m^-1 | 3.125e26 (NMOS), 1.5e25 (PMOS) | No | Flicker noise parameter B |
| NOIC | -- | (eV)^-1 s^(1-EF) m | 8.75 | No | Flicker noise parameter C |
| EM | -- | V/m | 4.1e7 | No | Saturation field |
| AF | -- | -- | 1.0 | No | Flicker noise exponent |
| EF | -- | -- | 1.0 | No | Flicker noise frequency exponent |
| KF | -- | A^(2-EF) s^(1-EF) F | 0.0 | No | Flicker noise coefficient |
| LINTNOI | -- | m | 0.0 | No | Length reduction parameter offset for noise |
| NTNOI | -- | -- | 1.0 | No | Noise factor for short-channel (tnoiMod=0) |
| TNOIA | -- | -- | 1.5 | No | Channel-length dependence of thermal noise |
| TNOIB | -- | -- | 3.5 | No | Thermal noise partitioning length dependence |
| TNOIC | -- | -- | 0.0 | No | Length dependent parameter for correlation coefficient |
| RNOIA | -- | -- | 0.577 | No | Thermal noise coefficient |
| RNOIB | -- | -- | 0.5164 | No | Thermal noise coefficient |
| RNOIC | -- | -- | 0.395 | No | Correlation coefficient parameter |
| GIDLCLAMP | -- | -- | -1e-5 | No | GIDL clamp value |
| IDOVVDSC | -- | -- | 1e-9 | No | Noise clamping limit parameter |

### A.11 Layout-Dependent Parasitic Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| DMCG | -- | m | 0.0 | No | Distance from S/D contact center to gate edge |
| DMCI | -- | m | DMCG | No | Distance from S/D contact center to isolation edge |
| DMDG | -- | m | 0.0 | No | Same as DMCG but for merged device only |
| DMCGT | -- | m | 0.0 | No | DMCG of test structures |
| NF | -- | -- | 1 | No | Number of device fingers (instance only) |
| DWJ | -- | m | DWC | No | Offset of S/D junction width |
| MIN | -- | -- | 0 | No | Minimize drain or source diffusions for even-finger (instance only) |
| XGW | -- | m | 0.0 | No | Distance from gate contact to channel edge (also instance) |
| XGL | -- | m | 0.0 | No | Offset of gate length due to patterning variations |
| XL | -- | m | 0.0 | No | Channel length offset due to mask/etch effect |
| XW | -- | m | 0.0 | No | Channel width offset due to mask/etch effect |
| NGCON | -- | -- | 1 | No | Number of gate contacts (also instance) |

### A.12 Asymmetric Source/Drain Junction Diode Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| IJTHSREV / IJTHDREV | -- | A | 0.1 | No | Limiting current in reverse bias region (source/drain) |
| IJTHSFWD / IJTHDFWD | -- | A | 0.1 | No | Limiting current in forward bias region (source/drain) |
| XJBVS / XJBVD | -- | -- | 1.0 | No | Fitting parameter for diode breakdown |
| BVS / BVD | -- | V | 10.0 | No | Breakdown voltage (source/drain) |
| JSS / JSD | -- | A/m^2 | 1.0e-4 | No | Bottom junction reverse saturation current density |
| JSWS / JSWD | -- | A/m | 0.0 | No | Isolation-edge sidewall reverse saturation current density |
| JSWGS / JSWGD | -- | A/m | 0.0 | No | Gate-edge sidewall reverse saturation current density |
| JTSS / JTSD | -- | A/m^2 | 0.0 | No | Bottom trap-assisted saturation current density |
| JTSSWS / JTSSWD | -- | A/m | 0.0 | No | STI sidewall trap-assisted saturation current density |
| JTSSWGS / JTSSWGD | -- | A/m | 0.0 | No | Gate-edge sidewall trap-assisted saturation current density |
| JTWEFF | -- | -- | 0.0 | No | Trap-assisted tunneling current density width dependence |
| NJTS / NJTSD | -- | -- | 20.0 | No | Non-ideality factor for JTSS/JTSD |
| NJTSSW / NJTSSWD | -- | -- | 20.0 | No | Non-ideality factor for JTSSWS/JTSSWD |
| NJTSSWG / NJTSSWGD | -- | -- | 20.0 | No | Non-ideality factor for JTSSWGS/JTSSWGD |
| XTSS / XTSD | -- | -- | 0.02 | No | Power dependence of JTSS/JTSD on temperature |
| XTSSWS / XTSSWD | -- | -- | 0.02 | No | Power dependence of JTSSWS/JTSSWD on temperature |
| XTSSWGS / XTSSWGD | -- | -- | 0.02 | No | Power dependence of JTSSWGS/JTSSWGD on temperature |
| VTSS / VTSD | -- | V | 10.0 | No | Bottom trap-assisted voltage dependent parameter |
| VTSSWS / VTSSWD | -- | V | 10.0 | No | STI sidewall trap-assisted voltage dependent parameter |
| VTSSWGS / VTSSWGD | -- | V | 10.0 | No | Gate-edge sidewall trap-assisted voltage dependent parameter |
| TNJTS / TNJTSD | -- | -- | 0.0 | No | Temperature coefficient for NJTS/NJTSD |
| TNJTSSW / TNJTSSWD | -- | -- | 0.0 | No | Temperature coefficient for NJTSSW/NJTSSWD |
| TNJTSSWG / TNJTSSWGD | -- | -- | 0.0 | No | Temperature coefficient for NJTSSWG/NJTSSWGD |
| CJS / CJD | -- | F/m^2 | 5.0e-4 | No | Bottom junction capacitance per unit area at zero bias |
| MJS / MJD | -- | -- | 0.5 | No | Bottom junction capacitance grading coefficient |
| MJSWS / MJSWD | -- | -- | 0.33 | No | Isolation-edge sidewall junction capacitance grading coefficient |
| CJSWS / CJSWD | -- | F/m | 5.0e-10 | No | Isolation-edge sidewall junction capacitance per unit length |
| CJSWGS / CJSWGD | -- | F/m | CJSWS | No | Gate-edge sidewall junction capacitance per unit length |
| MJSWGS / MJSWGD | -- | -- | MJSWS | No | Gate-edge sidewall junction capacitance grading coefficient |
| PBS / PBD | -- | V | 1.0 | No | Bottom junction built-in potential |
| PBSWS / PBSWD | -- | V | 1.0 | No | Isolation-edge sidewall junction built-in potential |
| PBSWGS / PBSWGD | -- | V | PBSWS | No | Gate-edge sidewall junction built-in potential |

### A.13 Temperature Dependence Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| TNOM | -- | C | 27 | No | Temperature at which parameters are extracted |
| UTE | -- | -- | -1.5 | Yes | Mobility temperature exponent |
| UCSTE | -- | -- | -4.775e-3 | Yes | Temperature coefficient of coulombic mobility |
| KT1 | -- | V | -0.11 | Yes | Temperature coefficient for threshold voltage |
| KT1L | -- | Vm | 0.0 | Yes | Channel length dependence of KT1 |
| KT2 | -- | -- | 0.022 | Yes | Body-bias coefficient of Vth temperature effect |
| UA1 | -- | m/V | 1.0e-9 | Yes | Temperature coefficient for UA |
| UB1 | -- | (m/V)^2 | -1.0e-18 | Yes | Temperature coefficient for UB |
| UC1 | -- | V^-1 or m/V^2 | -0.056 (mobMod=1,5); -0.056e-9 (mobMod=0,2) | Yes | Temperature coefficient for UC |
| UD1 | -- | m^-2 | 0.0 | Yes | Temperature coefficient for UD |
| AT | -- | m/s | 3.3e4 | Yes | Temperature coefficient for saturation velocity |
| PRT | -- | ohm*um | 0.0 | Yes | Temperature coefficient for Rdsw |
| NJS / NJD | -- | -- | 1.0 | No | Emission coefficients of junction (source/drain) |
| XTIS / XTID | -- | -- | 3.0 | No | Junction current temperature exponents (source/drain) |
| TPB | -- | V/K | 0.0 | No | Temperature coefficient of PB |
| TPBSW | -- | V/K | 0.0 | No | Temperature coefficient of PBSW |
| TPBSWG | -- | V/K | 0.0 | No | Temperature coefficient of PBSWG |
| TCJ | -- | K^-1 | 0.0 | No | Temperature coefficient of CJ |
| TCJSW | -- | K^-1 | 0.0 | No | Temperature coefficient of CJSW |
| TCJSWG | -- | K^-1 | 0.0 | No | Temperature coefficient of CJSWG |
| TVOFF | -- | K^-1 | 0.0 | No | Temperature coefficient of VOFF |
| TVFBSDOFF | -- | K^-1 | 0.0 | No | Temperature coefficient of VFBSDOFF |
| TNFACTOR | -- | -- | 0.0 | Yes | Temperature coefficient of NFACTOR |
| TETA0 | -- | -- | 0.0 | Yes | Temperature coefficient of ETA0 |
| TVOFFCV | -- | K^-1 | 0.0 | Yes | Temperature coefficient of VOFFCV |

### A.14 Stress Effect Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| SA | -- | m | 0.0 | No | Distance OD edge to poly, one side (instance; <=0 turns off) |
| SB | -- | m | 0.0 | No | Distance OD edge to poly, other side (instance; <=0 turns off) |
| SD | -- | m | 0.0 | No | Distance between neighbouring fingers (instance; for NF>1) |
| SAref | -- | m | 1e-6 | No | Reference SA distance |
| SBref | -- | m | 1e-6 | No | Reference SB distance |
| WLOD | -- | m | 0.0 | No | Width parameter for stress effect |
| KU0 | -- | m | 0.0 | No | Mobility degradation/enhancement coefficient for stress |
| KVSAT | -- | m | 0.0 | No | Saturation velocity degradation/enhancement for stress (-1<=KVSAT<=1) |
| TKU0 | -- | -- | 0.0 | No | Temperature coefficient of KU0 |
| LKU0 | -- | -- | 0.0 | No | Length dependence of KU0 |
| WKU0 | -- | -- | 0.0 | No | Width dependence of KU0 |
| PKU0 | -- | -- | 0.0 | No | Cross-term dependence of KU0 |
| LLODKU0 | -- | -- | 0.0 | No | Length parameter for u0 stress effect |
| WLODKU0 | -- | -- | 0.0 | No | Width parameter for u0 stress effect |
| KVTH0 | -- | Vm | 0.0 | No | Threshold shift parameter for stress effect |
| LKVTH0 | -- | -- | 0.0 | No | Length dependence of KVTH0 |
| WKVTH0 | -- | -- | 0.0 | No | Width dependence of KVTH0 |
| PKVTH0 | -- | -- | 0.0 | No | Cross-term dependence of KVTH0 |
| LLODVTH | -- | -- | 0.0 | No | Length parameter for Vth stress effect |
| WLODVTH | -- | -- | 0.0 | No | Width parameter for Vth stress effect |
| STK2 | -- | m | 0.0 | No | K2 shift factor related to Vth0 change |
| LODK2 | -- | -- | 1.0 | No | K2 shift modification factor for stress |
| STETA0 | -- | m | 0.0 | No | ETA0 shift factor related to Vth0 change |
| LODETA0 | -- | -- | 1.0 | No | ETA0 shift modification factor for stress |

### A.15 Well-Proximity Effect Model Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| SCA | -- | -- | 0.0 | No | Integral of first distribution function for scattered well dopant (instance) |
| SCB | -- | -- | 0.0 | No | Integral of second distribution function for scattered well dopant (instance) |
| SCC | -- | -- | 0.0 | No | Integral of third distribution function for scattered well dopant (instance) |
| SC | -- | m | 0.0 | No | Distance to single well edge (instance; <=0 turns off WPE) |
| WEB | -- | -- | 0.0 | No | Coefficient for SCB |
| WEC | -- | -- | 0.0 | No | Coefficient for SCC |
| KVTH0WE | -- | -- | 0.0 | Yes | Threshold shift factor for well proximity effect |
| K2WE | -- | -- | 0.0 | Yes | K2 shift factor for well proximity effect |
| KU0WE | -- | -- | 0.0 | Yes | Mobility degradation factor for well proximity effect |
| SCREF | -- | m | 1e-6 | No | Reference distance to calculate SCA, SCB, SCC |

### A.16 dW and dL Parameters

| Parameter | Symbol | Unit | Default | Binnable | Description |
|-----------|--------|------|---------|----------|-------------|
| WL | -- | -- | 0.0 | No | Coefficient of length dependence for width offset |
| WLN | -- | -- | 1.0 | No | Power of length dependence of width offset |
| WW | -- | -- | 0.0 | No | Coefficient of width dependence for width offset |
| WWN | -- | -- | 1.0 | No | Power of width dependence of width offset |
| WWL | -- | -- | 0.0 | No | Length*width cross-term for width offset |
| LL | -- | -- | 0.0 | No | Coefficient of length dependence for length offset |
| LLN | -- | -- | 1.0 | No | Power of length dependence for length offset |
| LW | -- | -- | 0.0 | No | Coefficient of width dependence for length offset |
| LWN | -- | -- | 1.0 | No | Power of width dependence for length offset |
| LWL | -- | -- | 0.0 | No | Length*width cross-term for length offset |
| LLC | -- | -- | LL | No | Length dependence for CV channel length offset |
| LWC | -- | -- | LW | No | Width dependence for CV channel length offset |
| LWLC | -- | -- | LWL | No | Cross-term for CV channel length offset |
| WLC | -- | -- | WL | No | Length dependence for CV channel width offset |
| WWC | -- | -- | WW | No | Width dependence for CV channel width offset |
| WWLC | -- | -- | WWL | No | Cross-term for CV channel width offset |

### A.17 Range Parameters for Model Application

| Parameter | Unit | Default | Description |
|-----------|------|---------|-------------|
| LMIN | m | 0.0 | Minimum channel length |
| LMAX | m | 1.0 | Maximum channel length |
| WMIN | m | 0.0 | Minimum channel width |
| WMAX | m | 1.0 | Maximum channel width |

### A.18 Binning (Note-11)

Each binnable model parameter $M_i$ is calculated as:

$$M_i = M + \frac{LM}{L_{eff}} + \frac{WM}{W_{eff}} + \frac{PM}{L_{eff} \cdot W_{eff}}$$

Default values of all `l*/w*/p*` parameters are zero.

### A.19 Additional Instance Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| KETAC | -0.047 V^-1 | Body-bias coefficient of non-uniform depletion width in dynamic evaluation |

---

## Equations

### Chapter 1: Effective Oxide Thickness, Channel Length and Channel Width

#### Gate Dielectric Model (mtrlMod=1)

$$TOXP = EOT - \frac{3.9}{EPSRSUB} \cdot X_{DC}\big|_{V_{gs}=VDDEOT,\; V_{ds}=V_{bs}=0} \tag{1.1}$$

#### Poly-Silicon Gate Depletion

Voltage drop in poly gate:

$$V_{poly} = \frac{qNGATE \cdot X_{poly}^2}{2\epsilon_{si}} \tag{1.2}$$

Boundary condition at poly-oxide interface:

$$EPSROX \cdot E_{ox} = \epsilon_{si} \cdot E_{poly} = \sqrt{2q\epsilon_{si} \cdot NGATE \cdot V_{poly}} \tag{1.3}$$

Gate voltage equation:

$$V_{gs} - V_{FB} - \phi_s = V_{poly} + V_{ox} \tag{1.4}$$

Quadratic for $V_{poly}$:

$$a(V_{gs} - V_{FB} - \phi_s - V_{poly})^2 - V_{poly} = 0 \tag{1.5}$$

where

$$a = \frac{EPSROX^2}{2q\epsilon_{si} \cdot NGATE \cdot TOXE^2} \tag{1.6}$$

Effective gate voltage (mtrlMod=0):

$$V_{gse} = V_{FB} + \phi_s + \frac{q\epsilon_{si} \cdot NGATE \cdot TOXE^2}{EPSROX^2}\left(\sqrt{1 + \frac{2 \cdot EPSROX^2 (V_{gs}-V_{FB}-\phi_s)}{q\epsilon_{si} \cdot NGATE \cdot TOXE^2}} - 1\right) \tag{1.7}$$

Effective gate voltage (mtrlMod=1):

$$V_{gse} = V_{FB} + \phi_s + \frac{q\epsilon_{gate} \cdot NGATE}{c_{oxe}^2}\left(\sqrt{1 + \frac{2c_{oxe}^2(V_{gs}-V_{FB}-\phi_s)}{q\epsilon_{gate} \cdot NGATE}} - 1\right) \tag{1.8}$$

where $\epsilon_{gate} = EPSRGATE \cdot \epsilon_0$. EPSRGATE=0 means metal gate (no depletion).

#### Effective Channel Length and Width

$$L_{eff} = L_{drawn} + XL - 2 \cdot dL \tag{1.9}$$

$$W_{eff} = \frac{W_{drawn}}{NF} + XW - 2 \cdot dW \tag{1.10}$$

$$W_{eff}' = \frac{W_{drawn}}{NF} + XW - 2 \cdot dW' \tag{1.11}$$

where

$$dW = dW' + DWG \cdot V_{gsteff} + DWB\left(\sqrt{\phi_s - V_{bseff}} - \sqrt{\phi_s}\right) \tag{1.12}$$

$$dW' = WINT + \frac{WL}{L^{WLN}} + \frac{WW}{W^{WWN}} + \frac{WWL}{L^{WLN} \cdot W^{WWN}}$$

$$dL = LINT + \frac{LL}{L^{LLN}} + \frac{LW}{W^{LWN}} + \frac{LWL}{L^{LLN} \cdot W^{LWN}}$$

For capacitance:

$$L_{active} = L_{drawn} + XL - 2 \cdot dL_{CV} \tag{1.13}$$

$$W_{active} = \frac{W_{drawn}}{NF} + XW - 2 \cdot dW_{CV} \tag{1.14}$$

$$dL_{CV} = DLC + \frac{LLC}{L^{LLN}} + \frac{LWC}{W^{LWN}} + \frac{LWLC}{L^{LLN} \cdot W^{LWN}} \tag{1.15}$$

$$dW_{CV} = DWC + \frac{WLC}{L^{WLN}} + \frac{WWC}{W^{WWN}} + \frac{WWLC}{L^{WLN} \cdot W^{WWN}} \tag{1.16}$$

Effective source/drain diffusion width:

$$W_{effcj} = \frac{W_{drawn}}{NF} + XW - 2\left(DWJ + \frac{WLC}{L^{WLN}} + \frac{WWC}{W^{WWN}} + \frac{WWLC}{L^{WLN} \cdot W^{WWN}}\right) \tag{1.17}$$

---

### Chapter 2: Threshold Voltage Model

#### Long-Channel, Uniform Doping

$$V_{th} = VTH0 + \gamma\left(\sqrt{\phi_s - V_{bs}} - \sqrt{\phi_s}\right) \tag{2.1}$$

$$\gamma = \frac{\sqrt{2q\epsilon_{si} \cdot N_{substrate}}}{C_{oxe}} \tag{2.2}$$

Process variation:

$$VTH0 = VTH0 + DELVTO \tag{2.3}$$

If VTH0 not given: $V_{FB} = V_{FB} + DELVTO$; $VTH0 = V_{FB} + \phi_s + \gamma\sqrt{\phi_s}$ (2.4)

#### Non-Uniform Vertical Doping

$$V_{th} = V_{th,NDEP} + \frac{qD_0}{C_{oxe}} + K1_{NDEP}\sqrt{\phi_s - V_{bs}} - \frac{qD_1}{\epsilon_{si}}\sqrt{\phi_s - V_{bs}} \tag{2.5}$$

$$V_{th,NDEP} = VTH0 + K1_{NDEP}\left(\sqrt{\phi_s - V_{bs}} - \sqrt{\phi_s}\right) \tag{2.6}$$

$$\phi_s = 0.4 + \frac{k_BT}{q}\ln\left(\frac{NDEP}{n_i}\right) \tag{2.7}$$

Reduced form:

$$V_{th} = VTH0 + K1\left(\sqrt{\phi_s - V_{bs}} - \sqrt{\phi_s}\right) - K2 \cdot V_{bs} \tag{2.10}$$

$$\phi_s = 0.4 + \frac{k_BT}{q}\ln\left(\frac{NDEP}{n_i}\right) + PHIN \tag{2.11}$$

$$PHIN = -\frac{qD_{10}}{\epsilon_{si}} \tag{2.12}$$

If K1 and K2 not given:

$$K1 = \gamma_2 - 2K2\sqrt{\phi_s - VBM} \tag{2.13}$$

$$K2 = \frac{(\gamma_1 - \gamma_2)(\sqrt{\phi_s - VBX} - \sqrt{\phi_s})}{2\sqrt{\phi_s}(\sqrt{\phi_s - VBM} - \sqrt{\phi_s}) + VBM} \tag{2.14}$$

$$\gamma_1 = \frac{\sqrt{2q\epsilon_{si} \cdot NDEP}}{C_{oxe}} \tag{2.15}$$

$$\gamma_2 = \frac{\sqrt{2q\epsilon_{si} \cdot NSUB}}{C_{oxe}} \tag{2.16}$$

$$\frac{qNDEP \cdot XT^2}{2\epsilon_{si}} = \phi_s - VBX \tag{2.17}$$

#### Non-Uniform Lateral Doping (Pocket/Halo)

$$V_{th} = VTH0 + K1\sqrt{\phi_s - V_{bs}}\left(1 + \frac{LPEB}{L_{eff}}\right) - K2 \cdot V_{bs} + K1\left(\sqrt{1 + \frac{LPE0}{L_{eff}}} - 1\right)\sqrt{\phi_s} \tag{2.18}$$

Drain-induced threshold shift (DITS), tempMod=0,1:

$$\Delta V_{th}(DITS) = -nv_t \cdot \ln\left(\frac{L_{eff}}{L_{eff} + DVTP0 \cdot (1 + e^{-DVTP1 \cdot V_{ds}})}\right) \tag{2.20}$$

tempMod=2,3:

$$\Delta V_{th}(DITS) = -nv_{t,nom} \cdot \ln\left(\frac{L_{eff}}{L_{eff} + DVTP0 \cdot (1 + e^{-DVTP1 \cdot V_{ds}})}\right) \tag{2.21}$$

Complete DITS with asymmetric tanh term:

$$\Delta V_{th}(DITS) = -nv_t \cdot \ln\left(\frac{L_{eff}}{L_{eff} + DVTP0 \cdot (1 + e^{-DVTP1 \cdot V_{ds}})}\right) - \left(DVTP5 + \frac{DVTP2}{L_{eff}^{DVTP3}}\right) \cdot \tanh(DVTP4 \cdot V_{ds}) \tag{2.22}$$

#### Short-Channel and DIBL Effects

$$\Delta V_{th}(SCE, DIBL) = -\theta_{th}(L_{eff})\left[2(V_{bi} - \phi_s) + V_{ds}\right] \tag{2.23}$$

$$V_{bi} = \frac{k_BT}{q}\ln\left(\frac{NDEP \cdot NSD}{n_i^2}\right) \tag{2.24}$$

$$\theta_{th}(L_{eff}) = \frac{0.5}{\cosh\left(\frac{L_{eff}}{l_t}\right) - 1} \tag{2.25}$$

$$l_t = \sqrt{\frac{\epsilon_{si} \cdot TOXE \cdot X_{dep}}{EPSROX}} \tag{2.26}$$

$$X_{dep} = \sqrt{\frac{2\epsilon_{si}(\phi_s - V_{bs})}{qNDEP}} \tag{2.27}$$

SCE:

$$\theta_{th}(SCE) = \frac{0.5 \cdot DVT0}{\cosh\left(DVT1 \cdot \frac{L_{eff}}{l_t}\right) - 1} \tag{2.29}$$

$$\Delta V_{th}(SCE) = -\theta_{th}(SCE) \cdot (V_{bi} - \phi_s) \tag{2.30}$$

$$l_t = \sqrt{\frac{\epsilon_{si} \cdot TOXE \cdot X_{dep}}{EPSROX}}(1 + DVT2 \cdot V_{bs}) \tag{2.31}$$

DIBL:

$$\theta_{th}(DIBL) = \frac{0.5}{\cosh\left(DSUB \cdot \frac{L_{eff}}{l_{t0}}\right) - 1} \tag{2.32}$$

$$\Delta V_{th}(DIBL) = -\theta_{th}(DIBL) \cdot (ETA0 + ETAB \cdot V_{bs}) \cdot V_{ds} \tag{2.33}$$

$$l_{t0} = \sqrt{\frac{\epsilon_{si} \cdot TOXE \cdot X_{dep0}}{EPSROX}} \tag{2.34}$$

$$X_{dep0} = \sqrt{\frac{2\epsilon_{si}\phi_s}{qNDEP}} \tag{2.35}$$

#### Narrow-Width Effect

$$\Delta V_{th}(NW1) = (K3 + K3B \cdot V_{bs}) \cdot \frac{TOXE}{W_{eff}' + W0} \cdot \sqrt{\phi_s} \tag{2.37}$$

$$\Delta V_{th}(NW2) = -\frac{0.5 \cdot DVT0W}{\cosh\left(DVT1W \cdot \frac{\sqrt{L_{eff} \cdot W_{eff}'}}{l_{tw}}\right) - 1}(V_{bi} - \phi_s) \tag{2.38}$$

$$l_{tw} = \sqrt{\frac{\epsilon_{si} \cdot TOXE \cdot X_{dep}}{EPSROX}}(1 + DVT2W \cdot V_{bs}) \tag{2.39}$$

#### Complete Vth Model

$$V_{th} = VTH0 + K1_{ox}\left(\sqrt{\phi_s - V_{bseff}} - K1\sqrt{\phi_s}\right)\left(1 + \frac{LPEB}{L_{eff}}\right) - K2_{ox} \cdot V_{bseff}$$
$$+ K1_{ox}\left(\sqrt{1 + \frac{LPE0}{L_{eff}}} - 1\right)\sqrt{\phi_s} + (K3 + K3B \cdot V_{bseff})\frac{TOXE}{W_{eff}'+W0}\sqrt{\phi_s}$$
$$- 0.5\left[\frac{DVT0W}{\cosh(DVT1W\frac{\sqrt{L_{eff}W_{eff}'}}{l_{tw}})-1} + \frac{DVT0}{\cosh(DVT1\frac{L_{eff}}{l_t})-1}\right](V_{bi}-\phi_s)$$
$$- \frac{0.5}{\cosh(DSUB\frac{L_{eff}}{l_{t0}})-1}(ETA0+ETAB \cdot V_{bseff})V_{ds}$$
$$- nv_t \cdot \ln\left(\frac{L_{eff}}{L_{eff}+DVTP0(1+e^{-DVTP1 \cdot V_{ds}})}\right) - \left(DVTP5+\frac{DVTP2}{L_{eff}^{DVTP3}}\right)\tanh(DVTP4 \cdot V_{ds}) \tag{2.40}$$

$$K1_{ox} = K1 \cdot \frac{TOXE}{TOXM} \tag{2.41}$$

$$K2_{ox} = K2 \cdot \frac{TOXE}{TOXM} \tag{2.42}$$

#### Vbseff Clamping

$$V_{bseff} = V_{bc} + 0.5\left[(V_{bs}-V_{bc}-\delta_1) + \sqrt{(V_{bs}-V_{bc}-\delta_1)^2 - 4\delta_1 V_{bc}}\right] \tag{2.43}$$

where $\delta_1 = 0.001$ V and

$$V_{bc} = 0.9\left(\phi_s - \frac{K1^2}{4K2^2}\right) \tag{2.44}$$

Upper bound for positive Vbs:

$$V_{bseff} = 0.95\phi_s - 0.5\left[0.95\phi_s - V_{bseff}' - \delta_1 + \sqrt{(0.95\phi_s - V_{bseff}' - \delta_1)^2 + 4\delta_1 \cdot 0.95\phi_s}\right] \tag{2.45}$$

---

### Chapter 3: Channel Charge and Subthreshold Swing Models

#### Channel Charge Model

$$V_{off}' = VOFF + \frac{VOFFL}{L_{eff}} \tag{3.1}$$

Strong inversion charge density:

$$Q_{chs0} = C_{oxe} \cdot (V_{gse} - V_{th}) \tag{3.3}$$

Unified charge density:

$$Q_{ch0} = C_{oxeff} \cdot V_{gsteff} \tag{3.4}$$

$$C_{oxeff} = \frac{C_{oxe} \cdot C_{cen}}{C_{oxe} + C_{cen}}, \quad C_{cen} = \frac{\epsilon_{si}}{X_{DC}} \tag{3.5}$$

$$X_{DC} = \frac{ADOS \cdot 1.9 \times 10^{-9}}{\left(1 + \frac{V_{gsteff} + 4(VTH0 - V_{FB} - \phi_s)}{2TOXP}\right)^{0.7 \cdot BDOS}} \tag{3.6}$$

Effective $V_{gsteff}$:

$$V_{gsteff} = \frac{nv_t \ln\left[1+\exp\left(\frac{m(V_{gse}-V_{th})}{nv_t}\right)\right]}{m + \frac{nC_{oxe}}{\sqrt{2qNDEP\epsilon_{si}}} \exp\left(-\frac{(1-m)(V_{gse}-V_{th})-V_{off}'}{nv_t}\right)} \tag{3.7}$$

$$m = 0.5 + \frac{\arctan(MINV)}{\pi} \tag{3.8}$$

Channel charge along channel:

$$Q_{ch}(y) = C_{oxeff} \cdot V_{gsteff}\left(1 - \frac{V_F(y)}{V_b}\right) \tag{3.18}$$

$$V_b = \frac{V_{gsteff} + 2v_t}{A_{bulk}} \tag{3.17}$$

#### Subthreshold Swing n

$$n = 1 + NFACTOR \cdot \frac{C_{dep}}{C_{oxe}} + \frac{C_{dsc-Term} + CIT}{C_{oxe}} \tag{3.21}$$

$$C_{dsc-Term} = (CDSC + CDSCD \cdot V_{ds} + CDSCB \cdot V_{bseff}) \cdot \frac{0.5}{\cosh(DVT1 \cdot L_{eff}/l_t) - 1} \tag{3.22}$$

---

### Chapter 4: Gate Direct Tunneling Current Model

#### Oxide Voltage

$$V_{oxacc} = V_{fbzb} - V_{FBeff} \tag{4.1}$$

$$V_{oxdepinv} = K1_{ox}\sqrt{\phi_s} + V_{gsteff} \tag{4.2}$$

$$V_{fbzb} = V_{th}\big|_{V_{bs}=0,V_{ds}=0} - \phi_s - K1\sqrt{\phi_s} \tag{4.3}$$

$$V_{FBeff} = V_{fbzb} - 0.5\left[(V_{fbzb}-V_{gb}-0.02) + \sqrt{(V_{fbzb}-V_{gb}-0.02)^2 + 0.08V_{fbzb}}\right] \tag{4.4}$$

#### Gate-to-Substrate Current

Accumulation (Igbacc):

$$I_{gbacc} = W_{eff}L_{eff} \cdot A \cdot ToxRatio \cdot V_{gb} \cdot V_{aux} \cdot \exp[-B \cdot TOXE(AIGBACC - BIGBACC \cdot V_{oxacc})(1 + CIGBACC \cdot V_{oxacc})] \tag{4.5}$$

$$ToxRatio = \left(\frac{TOXREF}{TOXE}\right)^{NTOX} \cdot \frac{1}{TOXE^2} \tag{4.6}$$

$$V_{aux} = NIGBACC \cdot v_t \cdot \log\left[1 + \exp\left(-\frac{V_{gb}-V_{fbzb}}{NIGBACC \cdot v_t}\right)\right] \tag{4.7}$$

Inversion (Igbinv):

$$I_{gbinv} = W_{eff}L_{eff} \cdot A \cdot ToxRatio \cdot V_{gb} \cdot V_{aux} \cdot \exp[-B \cdot TOXE(AIGBINV - BIGBINV \cdot V_{oxdepinv})(1 + CIGBINV \cdot V_{oxdepinv})] \tag{4.8}$$

$$V_{aux} = NIGBINV \cdot v_t \cdot \log\left[1 + \exp\left(\frac{V_{oxdepinv}-EIGBINV}{NIGBINV \cdot v_t}\right)\right] \tag{4.9}$$

Physical constants: $A_{acc} = 4.97232 \times 10^{-7}$ A/V^2, $B_{acc} = 7.45669 \times 10^{11}$ (g/F-s^2)^0.5; $A_{inv} = 3.75956 \times 10^{-7}$ A/V^2, $B_{inv} = 9.82222 \times 10^{11}$ (g/F-s^2)^0.5.

#### Gate-to-Channel Current

$$I_{gc0} = W_{eff}L_{eff} \cdot A \cdot ToxRatio \cdot V_{gse} \cdot V_{aux} \cdot \exp[-B \cdot TOXE(AIGC - BIGC \cdot V_{oxdepinv})(1 + CIGC \cdot V_{oxdepinv})] \tag{4.10}$$

igcMod=1: $V_{aux} = NIGC \cdot v_t \cdot \log[1 + \exp((V_{gse}-VTH0)/(NIGC \cdot v_t))]$ (4.11)

igcMod=2: $V_{aux} = NIGC \cdot v_t \cdot \log[1 + \exp((V_{gse}-V_{th})/(NIGC \cdot v_t))]$ (4.12)

#### Gate-to-S/D Current

$$I_{gs} = W_{eff} \cdot DLCIG \cdot A \cdot ToxRatioEdge \cdot V_{gs} \cdot V_{gs}' \cdot \exp[-B \cdot TOXE \cdot POXEDGE(AIGS-BIGS \cdot V_{gs}')(1+CIGS \cdot V_{gs}')] \tag{4.13}$$

$$I_{gd} = W_{eff} \cdot DLCIGD \cdot A \cdot ToxRatioEdge \cdot V_{gd} \cdot V_{gd}' \cdot \exp[-B \cdot TOXE \cdot POXEDGE(AIGD-BIGD \cdot V_{gd}')(1+CIGD \cdot V_{gd}')] \tag{4.14}$$

$$ToxRatioEdge = \left(\frac{TOXREF}{TOXE \cdot POXEDGE}\right)^{NTOX}\frac{1}{(TOXE \cdot POXEDGE)^2} \tag{4.15}$$

$$V_{gs}' = \sqrt{(V_{gs}-V_{fbsd})^2 + 1.0 \times 10^{-4}} \tag{4.16}$$

$$V_{gd}' = \sqrt{(V_{gd}-V_{fbsd})^2 + 1.0 \times 10^{-4}} \tag{4.17}$$

If NGATE > 0: $V_{fbsd} = \frac{k_BT}{q}\log(NGATE/NSD) + VFBSDOFF$ (4.18); else $V_{fbsd} = 0$.

#### Partition of Igc

$$I_{gcs} = I_{gc0} \cdot \frac{PIGCD \cdot V_{dseff} + \exp(-PIGCD \cdot V_{dseff}) - 1 + 1.0 \times 10^{-4}}{PIGCD^2 \cdot V_{dseff}^2 + 2.0 \times 10^{-4}} \tag{4.19}$$

$$I_{gcd} = I_{gc0} \cdot \frac{1-(PIGCD \cdot V_{dseff}+1)\exp(-PIGCD \cdot V_{dseff}) + 1.0 \times 10^{-4}}{PIGCD^2 \cdot V_{dseff}^2 + 2.0 \times 10^{-4}} \tag{4.20}$$

If PIGCD not given:

$$PIGCD = \frac{B \cdot TOXE}{V_{gsteff}}\left(\frac{1}{2} - \frac{V_{dseff}}{2V_{gsteff}}\right) \tag{4.21}$$

---

### Chapter 5: Drain Current Model

#### Bulk Charge Effect

$$A_{bulk} = \left(1 + F_{doping}\left[\frac{A0 \cdot L_{eff}}{L_{eff}+2\sqrt{X_J \cdot X_{dep}}}\left(1-AGS \cdot V_{gsteff}\frac{L_{eff}}{L_{eff}+2\sqrt{X_J \cdot X_{dep}}}\right) + \frac{B0}{W_{eff}'+B1}\right]\right)\frac{1}{1+KETA \cdot V_{bseff}} \tag{5.1}$$

$$F_{doping} = \frac{(1+LPEB/L_{eff})K1_{ox}}{2\sqrt{\phi_s - V_{bseff}}} + K2_{ox} - K3B\frac{TOXE}{W_{eff}'+W0}\sqrt{\phi_s} \tag{5.2}$$

#### Unified Mobility Model

Effective field (general):

$$E_{eff} = \frac{Q_B + Q_n/2}{\epsilon_{si}} \approx \frac{V_{gs}+V_{th}}{6 \cdot TOXE} \tag{5.3--5.5}$$

**mobMod=0** (mtrlMod=0):

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + (UA+UC \cdot V_{bseff})\frac{V_{gsteff}+2V_{th}}{TOXE} + UB\left(\frac{V_{gsteff}+2V_{th}}{TOXE}\right)^2 + UD\left(\frac{V_{th} \cdot TOXE}{\sqrt{V_{gsteff}^2+2V_{th}^2+0.0001}}\right)^2} \tag{5.6}$$

**mobMod=1** (mtrlMod=0):

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + \left[UA\frac{V_{gsteff}+2V_{th}}{TOXE} + UB\left(\frac{V_{gsteff}+2V_{th}}{TOXE}\right)^2\right](1+UC \cdot V_{bseff}) + UD\left(\frac{V_{th} \cdot TOXE}{\sqrt{V_{gsteff}^2+2V_{th}^2+0.0001}}\right)^2} \tag{5.7}$$

**mobMod=2** (mtrlMod=0):

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + (UA+UC \cdot V_{bseff})\left(\frac{V_{gsteff}+C_0(VTH0-V_{FB}-\phi_s)}{TOXE}\right)^{EU} + UD\left(\frac{V_{th} \cdot TOXE}{\sqrt{V_{gsteff}^2+2V_{th}^2+0.0001}}\right)^2} \tag{5.8}$$

where $C_0 = 2$ (NMOS) or 2.5 (PMOS).

$$f(L_{eff}) = 1 - UP \cdot \exp\left(-\frac{L_{eff}}{LP}\right) \tag{5.9}$$

**mtrlMod=1** effective field:

$$E_{eff} = \frac{V_{gsteff} + 2V_{th} - 2 \cdot type \cdot (PHIG - EASUB - E_g/2 + 0.45)}{EOT} \cdot \frac{3.9}{EPSRSUB} \tag{5.10}$$

**mobMod=3**:

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + (UA+UC \cdot V_{bseff})\left[\frac{V_{gsteff}+C_0(VTH0-V_{fb}-\phi_s)}{6 \cdot TOXE} \times 10^{-8}\right]^{EU} + \frac{UD}{[0.5(1+V_{gsteff}/V_{gsteff,Vth})]^{UCS}}} \tag{5.13}$$

**mobMod=4** (modified mobMod=0 for variability):

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + (UA+UC \cdot V_{bseff})\frac{V_{gsteff}+C_0(VTH0-V_{FB}-\phi_s)}{TOXE} + UB\left(\frac{V_{gsteff}+C_0(VTH0-V_{FB}-\phi_s)}{TOXE}\right)^2 + UD\left(\frac{C_0(VTH0-V_{FB}-\phi_s) \cdot TOXE}{\sqrt{V_{gsteff}^2+2C_0^2(VTH0-V_{FB}-\phi_s)^2+0.0001}}\right)^2} \tag{5.14}$$

**mobMod=5** (modified mobMod=1):

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + \left[UA\frac{V_{gsteff}+C_0(VTH0-V_{FB}-\phi_s)}{TOXE}+UB\left(\frac{V_{gsteff}+C_0(VTH0-V_{FB}-\phi_s)}{TOXE}\right)^2\right](1+UC \cdot V_{bseff}) + UD(\cdots)^2} \tag{5.15}$$

**mobMod=6** (modified mobMod=2):

$$\mu_{eff} = \frac{U0 \cdot f(L_{eff})}{1 + (UA+UC \cdot V_{bseff})\left[\frac{V_{gsteff}+C_0(VTH0-V_{FB}-\phi_s)}{TOXE}\right]^{EU} + UD(\cdots)^2} \tag{5.16}$$

#### Source/Drain Resistance

**rdsMod=0** (internal):

$$R_{ds}(V) = \frac{RDSWMIN+RDSW}{\left(\sqrt{PRWB(\sqrt{\phi_s-V_{bseff}}-\sqrt{\phi_s})+1}+PRWG \cdot V_{gsteff}\right)} \cdot (10^6 \cdot W_{effcj})^{WR} \tag{5.17}$$

**rdsMod=1** (external):

$$R_d(V) = \frac{RDWMIN+RDW}{\left(\sqrt{-PRWB \cdot V_{bd}+1}+PRWG(V_{gd}-V_{fbsd})\right)} \cdot \frac{(10^6 \cdot W_{effcj})^{WR}}{NF} \tag{5.18}$$

$$R_s(V) = \frac{RSWMIN+RSW}{\left(\sqrt{-PRWB \cdot V_{bs}+1}+PRWG(V_{gs}-V_{fbsd})\right)} \cdot \frac{(10^6 \cdot W_{effcj})^{WR}}{NF} \tag{5.19}$$

#### Drain Current

Triode, intrinsic ($R_{ds}=0$ or rdsMod=1):

$$I_{ds0} = \frac{W\mu_{eff}Q_{ch0}V_{ds}(1-V_{ds}/2V_b)}{L(1+V_{ds}/(E_{sat}L))} \tag{5.23}$$

Triode with internal Rds ($R_{ds}>0$, rdsMod=0):

$$I_{ds} = \frac{I_{ds0}}{1 + R_{ds}I_{ds0}/V_{ds}} \tag{5.24}$$

#### Velocity Saturation

$$E_{sat} = \frac{2 \cdot VSAT}{\mu_{eff}} \tag{5.26}$$

#### Saturation Voltage

Intrinsic:

$$V_{dsat} = \frac{E_{sat}L(V_{gsteff}+2v_t)}{A_{bulk}E_{sat}L + V_{gsteff}+2v_t} \tag{5.27}$$

Extrinsic:

$$V_{dsat} = \frac{-b-\sqrt{b^2-4ac}}{2a} \tag{5.28}$$

$$a = A_{bulk}^2 W_{eff} VSAT \cdot C_{oxe} R_{ds} + A_{bulk}(1/\lambda - 1) \tag{5.29}$$

$$b = -\frac{(V_{gsteff}+2v_t)(1/\lambda - 1 + A_{bulk}E_{sat}L_{eff})}{+3A_{bulk}(V_{gsteff}+2v_t)W_{eff}VSAT \cdot C_{oxe}R_{ds}} \tag{5.30}$$

$$c = (V_{gsteff}+2v_t)E_{sat}L_{eff} + 2(V_{gsteff}+2v_t)^2 W_{eff}VSAT \cdot C_{oxe}R_{ds} \tag{5.31}$$

$$\lambda = A1 \cdot V_{gsteff} + A2 \tag{5.32}$$

Vdseff smoothing:

$$V_{dseff} = V_{dsat} - \frac{1}{2}\left[(V_{dsat}-V_{ds}-\delta) + \sqrt{(V_{dsat}-V_{ds}-\delta)^2 + 4\delta V_{dsat}}\right] \tag{5.33}$$

#### Output Conductance (Early Voltages)

CLM:

$$V_{ACLM} = C_{clm}(V_{ds}-V_{dsat}) \tag{5.37}$$

$$C_{clm} = \frac{1}{PCLM}\left[F\left(1+PVAG\frac{V_{gsteff}}{E_{sat}L_{eff}}\right)\left(1+\frac{R_{ds}I_{ds0}}{V_{dseff}}\right)\left(L_{eff}+\frac{V_{dsat}}{E_{sat}}\right)\right]\frac{1}{litl} \tag{5.38}$$

$$F = \frac{1}{1+FPROUT\sqrt{L_{eff}/(V_{gsteff}+2v_t)}} \tag{5.39}$$

$$litl = \sqrt{\frac{\epsilon_{si}TOXE \cdot X_J}{EPSROX}} \tag{5.40}$$

DIBL:

$$V_{ADIBL} = \frac{V_{gsteff}+2v_t}{r_{out}(1+PDIBLCB \cdot V_{bseff})}\left(1-\frac{A_{bulk}V_{dsat}}{A_{bulk}V_{dsat}+V_{gsteff}+2v_t}\right)\left(1+PVAG\frac{V_{gsteff}}{E_{sat}L_{eff}}\right) \tag{5.42}$$

$$r_{out} = \frac{PDIBLC1}{2\cosh(DROUT \cdot L_{eff}/l_{t0})-2} + PDIBLC2 \tag{5.43}$$

SCBE:

$$\frac{1}{V_{ASCBE}} = \frac{PSCBE2}{L_{eff}}\exp\left(-\frac{PSCBE1 \cdot litl}{V_{ds}-V_{dsat}}\right) \tag{5.47}$$

DITS:

$$V_{ADITS} = \frac{1}{PDITS} \cdot F \cdot [1+(1+PDITSL \cdot L_{eff})\exp(PDITSD \cdot V_{ds})] \tag{5.48}$$

#### Single-Equation Channel Current

$$I_{ds} = \frac{I_{ds0} \cdot NF}{1+\frac{R_{ds}I_{ds0}}{V_{dseff}}}\left(1+\frac{1}{C_{clm}}\ln\frac{V_A}{V_{Asat}}\right)\left(1+\frac{V_{ds}-V_{dseff}}{V_{ADIBL}}\right)\left(1+\frac{V_{ds}-V_{dseff}}{V_{ADITS}}\right)\left(1+\frac{V_{ds}-V_{dseff}}{V_{ASCBE}}\right) \tag{5.49}$$

$$V_A = V_{Asat} + V_{ACLM} \tag{5.50}$$

$$V_{Asat} = \frac{E_{sat}L_{eff}+V_{dsat}+2R_{ds}v_{sat}C_{oxe}W_{eff}V_{gsteff}\left(1-\frac{V_{dsat}}{2(A_{bulk}V_{dsat}+2v_t)}\right)}{R_{ds}v_{sat}C_{oxe}W_{eff}A_{bulk}-1+\frac{2}{\lambda}} \tag{5.51}$$

#### Velocity Overshoot

$$I_{DS,HD} = I_{DS}\frac{1+V_{dseff}/(L_{eff}E_{sat})}{1+V_{dseff}/(L_{eff}E_{sat}^{OV})} \tag{5.53}$$

$$E_{sat}^{OV} = E_{sat}\left(1+\frac{LAMBDA}{L_{eff}\mu_{eff}}\cdot\frac{\sqrt{1+\left(\frac{V_{ds}-V_{dseff}}{E_{sat} \cdot litl}\right)^2}-1}{\sqrt{1+\left(\frac{V_{ds}-V_{dseff}}{E_{sat} \cdot litl}\right)^2}+1}\right) \tag{5.54}$$

#### Source End Velocity Limit

$$v_{sHD} = \frac{I_{DS,HD}}{W \cdot q_s} \tag{5.55}$$

$$v_{sBT} = \frac{1-r}{1+r}VTL \tag{5.56}$$

$$r = \frac{L_{eff}}{XN \cdot L_{eff} + LC}, \quad XN \geq 3.0 \tag{5.57}$$

$$I_{DS} = \frac{I_{DS,HD}}{\left[1+(v_{sHD}/v_{sBT})^{2MM}\right]^{1/2MM}}, \quad MM=2 \tag{5.58}$$

---

### Chapter 6: Body Current Models

#### Impact Ionization Current

$$I_{ii} = \frac{ALPHA0+ALPHA1 \cdot L_{eff}}{L_{eff}}(V_{ds}-V_{dseff})\exp\left(\frac{-BETA0}{V_{ds}-V_{dseff}}\right)I_{dsNoSCBE} \tag{6.1}$$

$I_{dsNoSCBE}$ is $I_{ds}$ without the SCBE term (Eq. 5.49 without VASCBE factor) (6.2).

#### GIDL/GISL (gidlMod=0, mtrlMod=0)

$$I_{GIDL} = AGIDL \cdot W_{effCJ} \cdot NF \cdot \frac{V_{ds}-V_{gse}-EGIDL}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGIDL}{V_{ds}-V_{gse}-EGIDL}\right)\frac{V_{db}^3}{CGIDL+V_{db}^3} \tag{6.3}$$

$$I_{GISL} = AGISL \cdot W_{effCJ} \cdot NF \cdot \frac{-V_{ds}-V_{gde}-EGISL}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGISL}{-V_{ds}-V_{gde}-EGISL}\right)\frac{V_{sb}^3}{CGISL+V_{sb}^3} \tag{6.4}$$

#### GIDL/GISL (mtrlMod=1)

Flat-band voltage:

$$V_{fbsd} = PHIG - \left(EASUB + \frac{E_{g0}}{2} - type \cdot \min\left(\frac{E_{g0}}{2},\; v_t\ln\frac{NSD}{n_i}\right)\right) \tag{6.5}$$

$$I_{GIDL} = AGIDL \cdot W_{effCJ} \cdot NF \cdot \frac{V_{ds}-V_{gse}-EGIDL+V_{fbsd}}{EOT \cdot EPSRSUB/3.9} \cdot \exp\left(\frac{-EOT \cdot \frac{EPSRSUB}{3.9} \cdot BGIDL}{V_{ds}-V_{gse}-EGIDL+V_{fbsd}}\right)\frac{V_{db}^3}{CGIDL+V_{db}^3} \tag{6.6}$$

(Analogous for GISL, Eq. 6.7.)

#### GIDL/GISL (gidlMod=1)

$$I_{GIDL} = AGIDL \cdot W_{diod} \cdot NF \cdot \frac{V_{ds}-RGIDL \cdot V_{gse}-EGIDL+V_{fbsd}}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGIDL}{V_{ds}-V_{gse}-EGIDL}\right)\exp\left(\frac{KGIDL}{V_{bd}-FGIDL}\right) \tag{6.8}$$

$$I_{GISL} = AGISL \cdot W_{dios} \cdot NF \cdot \frac{-V_{ds}-RGISL \cdot V_{gse}-EGISL+V_{fbsd}}{3 \cdot TOXE} \cdot \exp\left(\frac{-3 \cdot TOXE \cdot BGISL}{V_{ds}-V_{gse}-EGISL}\right)\exp\left(\frac{KGISL}{V_{bs}-FGISL}\right) \tag{6.9}$$

---

### Chapter 7: Capacitance Model

#### Intrinsic Charge Formulation

$$Q_g = -(Q_{sub}+Q_{inv}+Q_{acc}) \tag{7.1}$$

$$Q_b = Q_{acc}+Q_{sub};\quad Q_{inv}=Q_s+Q_d$$

$$V_{th}(y) = V_{th}(0) + (A_{bulk}-1)V_y \tag{7.3}$$

$$C_{ij} = \frac{\partial Q_i}{\partial V_j} \tag{7.7}$$

#### Short Channel CV (cvchargeMod=0)

$$V_{dsat,CV} = \frac{V_{gsteff,CV}}{A_{bulk}'\left(1+(CLC/L_{active})^{CLE}\right)} \tag{7.10}$$

$$V_{gsteff,CV} = NOFF \cdot nv_t \cdot \ln\left[1+\exp\left(\frac{V_{gse}-V_{th}-VOFFCV}{NOFF \cdot nv_t}\right)\right] \tag{7.11}$$

#### Short Channel CV (cvchargeMod=1)

$$V_{gsteff,CV} = \frac{nv_t\ln\left[1+\exp\left(\frac{m^*(V_{gse}-V_{th})}{nv_t}\right)\right]}{m^* + \frac{nC_{oxe}}{\sqrt{2qNDEP\epsilon_{si}}}\exp\left(-\frac{(1-m^*)(V_{gse}-V_{th})-V_{off}'}{nv_t}\right)} \tag{7.14}$$

$$m^* = 0.5 + \frac{\arctan(MINVCV)}{\pi} \tag{7.15}$$

$$V_{off}' = VOFFCV + \frac{VOFFCVL}{L_{eff}} \tag{7.16}$$

#### Charge-Thickness Capacitance Model (CTM, capMod=2)

$$C_{oxeff} = \frac{C_{oxp} \cdot C_{cen}}{C_{oxp}+C_{cen}} \tag{7.23}$$

Accumulation/depletion charge thickness:

$$X_{DC} = \frac{1}{3}L_{debye}\exp\left(-ACDE\left(\frac{NDEP}{2\times10^{16}}\right)^{-0.25}\frac{V_{gse}-V_{bseff}-V_{FBeff}}{TOXP}\right) \tag{7.25}$$

Clamped:

$$X_{DC} = X_{max} - \frac{1}{2}\left(X_0 + \sqrt{X_0^2+4\delta_xX_{max}}\right) \tag{7.26}$$

where $X_0 = X_{max}-X_{DC}-\delta_x$, $X_{max}=L_{debye}/3$, $\delta_x=10^{-3}TOXE$.

Inversion charge thickness:

$$X_{DC} = \frac{ADOS \cdot 1.9\times10^{-9}}{\left(1+\frac{V_{gsteff}+4(VTH0-V_{FB}-\phi_s)}{2TOXP}\right)^{0.7 \cdot BDOS}} \tag{7.28}$$

Body charge thickness deviation:

$$\Delta\phi = \phi_s - 2\phi_B = v_t\ln\left(1+\frac{V_{gsteff,CV}(V_{gsteff,CV}+2K1_{ox}\sqrt{2\phi_B})}{MOIN \cdot K1_{ox}^2 v_t}\right) \tag{7.29}$$

#### capMod=0 Equations

Accumulation: $Q_g = W_{active}L_{active}C_{oxe}(V_{gs}-V_{bs}-VFBCV)$ (7.34)

Subthreshold: $Q_{sub0} = -W_{active}L_{active}C_{oxe}\frac{K1_{ox}^2}{2}\left(-1+\sqrt{1+\frac{4(V_{gs}-VFBCV-V_{bs})}{K1_{ox}^2}}\right)$ (7.37)

Strong inversion linear: See Eqs. (7.43)--(7.50); saturation: Eqs. (7.51)--(7.57).

#### capMod=1 Equations

Eqs. (7.58)--(7.70) define $Q_g$, $Q_{acc}$, $Q_{sub0}$, $Q_{inv}$, $\Delta Q_{sub}$ with all three charge partitioning options.

#### capMod=2 Equations

Eqs. (7.71)--(7.85) define charges with $C_{oxeff}$ replacing $C_{oxe}$, and $\Delta\phi_{eff}$ corrections.

$$Q_{acc} = W_{active}L_{active}C_{oxeff}V_{gbacc} \tag{7.71}$$

$$V_{gbacc} = \frac{1}{2}\left(V_0 + \sqrt{V_0^2 + 0.08V_{fbzb}}\right) \tag{7.72}$$

$$V_0 = V_{fbzb}+V_{bseff}-V_{gs}-0.02 \tag{7.73}$$

Smoothing: $V_{cveff} = V_{dsat}-\frac{1}{2}(V_1+\sqrt{V_1^2+0.08V_{dsat}})$ (7.74)

#### Fringing Capacitance

$$CF = \frac{2\epsilon_{ox}\epsilon_0}{\pi}\log\left(1+\frac{4.0\times10^{-7}}{TOXE}\right) \tag{7.86}$$

#### Overlap Capacitance (capMod != 0)

Source side:

$$\frac{Q_{overlap,s}}{W_{active}} = CGSO \cdot V_{gs} + CGSL\left(V_{gs}-V_{gs,overlap}-\frac{CKAPPAS}{2}\left(-1+\sqrt{1-\frac{4V_{gs,overlap}}{CKAPPAS}}\right)\right) \tag{7.87}$$

$$V_{gs,overlap} = \frac{1}{2}\left(V_{gs}+\delta_1-\sqrt{(V_{gs}+\delta_1)^2+4\delta_1}\right),\quad \delta_1=0.02\text{V} \tag{7.88}$$

Drain side: Eqs. (7.89)--(7.90) analogous with CGDO, CGDL, CKAPPAD.

Gate overlap charge:

$$Q_{overlap,g} = -(Q_{overlap,d}+Q_{overlap,s}+CGBO \cdot L_{active} \cdot V_{gb}) \tag{7.91}$$

Bias-independent (capMod=0):

$$Q_{overlap,s} = W_{active} \cdot CGSO \cdot V_{gs} \tag{7.92}$$

$$Q_{overlap,d} = W_{active} \cdot CGDO \cdot V_{gd} \tag{7.93}$$

$$Q_{overlap,b} = L_{active} \cdot CGBO \cdot V_{gb} \tag{7.94}$$

---

### Chapter 8: New Material Models (mtrlMod=1)

Band-gap:

$$E_{g0} = BG0SUB - \frac{TBGASUB \cdot T_{nom}^2}{T_{nom}+TBGBSUB} \tag{8.1}$$

$$n_i = NI0SUB\left(\frac{T_{nom}}{300.15}\right)^{3/2}\exp\left(\frac{E_g(300.15)-E_{g0}}{2v_t}\right) \tag{8.3}$$

$$E_g(T) = BG0SUB - \frac{TBGASUB \cdot T^2}{T+TBGBSUB} \tag{8.4}$$

---

### Chapter 9: High-Speed/RF Models

#### NQS Charge Deficit

$$Q_{def}(t) = V_{def} \cdot C_{fact} \tag{9.1}$$

$$\frac{\partial Q_{d,g,s}(t)}{\partial t} = \frac{\partial Q_{cheq}(t)}{\partial t} - \frac{Q_{def}(t)}{\tau} \tag{9.4}$$

AC NQS:

$$Q_{ch}(\omega) = \frac{Q_{cheq}(\omega)}{1+j\omega\tau} \tag{9.7}$$

#### Intrinsic-Input Resistance

$$\frac{1}{R_{ii}} = XRCRG1 \cdot \frac{I_{ds}}{V_{dseff}} + XRCRG2 \cdot \frac{W_{eff}L_{eff}C_{oxeff}k_BT}{qL_{eff}} \tag{9.6}$$

#### Gate Electrode Resistance

$$R_{geltd} = \frac{RSHG \cdot (XGW + W_{effcj}/(3 \cdot NGCON))}{NGCON \cdot (L_{drawn}-XGL) \cdot NF} \tag{9.10}$$

#### Scalable Substrate Resistance (rbodyMod=2)

$$RBPS = RBPS0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBPSL} \cdot \left(\frac{W}{10^{-6}}\right)^{RBPSW} \cdot NF^{RBPSNF} \tag{9.11}$$

$$RBPD = RBPD0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBPDL} \cdot \left(\frac{W}{10^{-6}}\right)^{RBPDW} \cdot NF^{RBPDNF} \tag{9.12}$$

$$RBPBX = RBPBX0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBPBXL}\left(\frac{W}{10^{-6}}\right)^{RBPBXW}NF^{RBPBXNF} \tag{9.13}$$

$$RBPBY = RBPBY0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBPBYL}\left(\frac{W}{10^{-6}}\right)^{RBPBYW}NF^{RBPBYNF} \tag{9.14}$$

$$RBPB = \frac{RBPBX \cdot RBPBY}{RBPBX+RBPBY} \tag{9.15}$$

$$RBSBX = RBSBX0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBSDBXL}\left(\frac{W}{10^{-6}}\right)^{RBSDBXW}NF^{RBSDBXNF} \tag{9.16}$$

$$RBSBY = RBSBY0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBSDBYL}\left(\frac{W}{10^{-6}}\right)^{RBSDBYW}NF^{RBSDBYNF} \tag{9.17}$$

$$RBSB = \frac{RBSBX \cdot RBSBY}{RBSBX+RBSBY} \tag{9.18}$$

(RBDB follows same structure with RBDBX0, RBDBY0.)

---

### Chapter 10: Noise Modeling

#### Flicker Noise (fnoiMod=0)

$$S_{id}(f) = \frac{KF \cdot I_{ds}^{AF}}{C_{oxe} \cdot L_{eff}^2 \cdot f^{EF}} \tag{10.1}$$

#### Flicker Noise (fnoiMod=1)

Inversion:

$$S_{id,inv}(f) = \frac{k_BTq^2\mu_{eff}I_{ds}}{C_{oxe}(L_{eff}-2 \cdot LINTNOI)^2 A_{bulk}f^{EF}10^{10}}\left[NOIA\log\frac{N_0+N^*}{N_l+N^*}+NOIB(N_0-N_l)+\frac{NOIC}{2}(N_0^2-N_l^2)\right]$$

$$+ \frac{k_BTI_{ds}^2L_{clm}^2}{W_{eff}(L_{eff}-2 \cdot LINTNOI)^2 f^{EF}10^{10}} \cdot \frac{NOIA+NOIB \cdot N_l+NOIC \cdot N_l^2}{(N_l+N^*)^2} \tag{10.2}$$

$$N_0 = C_{oxe}V_{gsteff}/q \tag{10.3}$$

$$N_l = C_{oxe}V_{gsteff}\left(1-\frac{A_{bulk}V_{dseff}}{V_{gsteff}+2v_t}\right)/q \tag{10.4}$$

$$N^* = \frac{k_BT(C_{oxe}+C_d+CIT)}{q^2} \tag{10.5}$$

$$L_{clm} = litl \cdot \log\left(\frac{V_{ds}-V_{dseff}}{litl}+EM\right)/E_{sat} \tag{10.6}$$

Subthreshold:

$$S_{id,subVt}(f) = \frac{NOIA \cdot k_BT \cdot I_{ds}^2}{W_{eff}L_{eff}f^{EF}N^{*2}10^{10}} \tag{10.7}$$

Total: $S_{id} = S_{id,inv} \cdot S_{id,subVt}/(S_{id,subVt}+S_{id,inv})$ (10.8)

#### Channel Thermal Noise (tnoiMod=0)

$$\overline{i_d^2} = \frac{4k_BT\Delta f}{R_{ds}(V)+\frac{\mu_{eff}}{L_{eff}^2}Q_{inv}^{NTNOI}} \tag{10.9}$$

$$Q_{inv} = W_{active}L_{active}C_{oxeff} \cdot NF \left(V_{gsteff}-\frac{A_{bulk}V_{dseff}}{2}+\frac{A_{bulk}^2V_{dseff}^2}{12(V_{gsteff}-A_{bulk}V_{dseff}/2)}\right) \tag{10.10}$$

#### Channel Thermal Noise (tnoiMod=1)

$$\overline{v_d^2} = 4k_BT \cdot tnoi^2 \cdot \frac{V_{dseff}\Delta f}{I_{ds}} \tag{10.11}$$

$$\overline{i_d^2} = 4k_BT\frac{V_{dseff}\Delta f}{I_{ds}}\left[G_{ds}+tnoi(G_m+G_{mbs})\right]^2 - \overline{v_d^2}(G_m+G_{ds}+G_{mbs})^2 \tag{10.12}$$

$$tnoi = RNOIB\left(1+TNOIB \cdot L_{eff}\left(\frac{V_{gsteff}}{E_{sat}L_{eff}}\right)^2\right) \tag{10.13}$$

$$tnoi' = RNOIA\left(1+TNOIA \cdot L_{eff}\left(\frac{V_{gsteff}}{E_{sat}L_{eff}}\right)^2\right) \tag{10.14}$$

#### Channel Thermal Noise (tnoiMod=2)

Implements both gate and drain noise current sources with correlation coefficient $c$ controlled by RNOIC. Formulations use $\gamma$, $\delta$, $\beta_{tnoi}$, $\theta_{tnoi}$ auxiliary variables (Eqs. 10.15--10.31). Gate noise scales as $\omega^2$.

---

### Chapter 11: Asymmetric MOS Junction Diode Models

#### Junction Diode IV

**dioMod=0** (source side):

$$I_{bs} = I_{sbs}\left[\exp\left(\frac{qV_{bs}}{NJS \cdot k_BT_{NOM}}\right)-1\right]f_{breakdown}+V_{bs} \cdot G_{min} \tag{11.1}$$

$$I_{sbs} = A_{seff}J_{ss}(T)+P_{seff}J_{ssws}(T)+W_{effcj} \cdot NF \cdot J_{sswgs}(T) \tag{11.2}$$

$$f_{breakdown} = 1+XJBVS \cdot \exp\left(\frac{-q(BVS+V_{bs})}{NJS \cdot k_BT_{NOM}}\right) \tag{11.3}$$

**dioMod=1**: No breakdown; linearized at IJTHSFWD.

$$I_{bs} = I_{sbs}\left[\exp\left(\frac{qV_{bs}}{NJS \cdot k_BT_{NOM}}\right)-1\right]+V_{bs} \cdot G_{min} \tag{11.4}$$

**dioMod=2**: Breakdown always modeled; linearized at both IJTHSFWD and IJTHSREV.

Drain-side diode: Eqs. (11.6)--(11.10) identical structure with JSD, JSWD, JSWGD, NJD, BVD, XJBVD.

#### Total Diode Including Tunneling (source)

$$I_{bs,total} = I_{bs} - W_{effcj}NF \cdot J_{tsswgs}(T)\left[\exp\left(\frac{-V_{bs}}{NJTSSWG(T)V_{tm0}}\right)\frac{VTSSWGS}{VTSSWGS-V_{bs}}-1\right]$$
$$- P_{seff}J_{tssws}(T)\left[\exp\left(\frac{-V_{bs}}{NJTSSW(T)V_{tm0}}\right)\frac{VTSSWS}{VTSSWS-V_{bs}}-1\right]$$
$$- A_{seff}J_{tss}(T)\left[\exp\left(\frac{-V_{bs}}{NJTS(T)V_{tm0}}\right)\frac{VTSS}{VTSS-V_{bs}}-1\right]+g'_{min}V_{bs} \tag{11.11}$$

(Drain side Eq. 11.12 analogous.)

#### Junction Diode CV (source)

$$C_{bs} = A_{seff}C_{jbs}+P_{seff}C_{jbssw}+W_{effcj} \cdot NF \cdot C_{jbsswg} \tag{11.13}$$

For $V_{bs}<0$:

$$C_{jbs} = CJS(T)\left(1-\frac{V_{bs}}{PBS(T)}\right)^{-MJS} \tag{11.14}$$

For $V_{bs}\geq0$:

$$C_{jbs} = CJS(T)\left(1+MJS\frac{V_{bs}}{PBS(T)}\right) \tag{11.15}$$

Sidewall capacitances (Eqs. 11.16--11.19 for source isolation-edge and gate-edge) and drain-side (Eqs. 11.20--11.26) follow the same pattern with respective parameters.

---

### Chapter 12: Layout-Dependent Parasitics

$$R_{geltd} = \frac{RSHG(XGW+W_{effcj}/(3 \cdot NGCON))}{NGCON(L_{drawn}-XGL) \cdot NF} \tag{12.1}$$

Effective perimeter: If PS given and perMod=1: $P_{seff}=PS-W_{effcj} \cdot NF$; if perMod=0: $P_{seff}=PS$.

Diffusion resistance: $R_{sdiff}=NRS \cdot RSH$; $R_{ddiff}=NRD \cdot RSH$.

---

### Chapter 13: Temperature Dependence Model

#### Threshold Voltage

$$V_{th}(T) = V_{th}(T_{NOM})+\left(KT1+\frac{KT1L}{L_{eff}}+KT2 \cdot V_{bseff}\right)\left(\frac{T}{T_{NOM}}-1\right) \tag{13.1}$$

$$V_{fb}(T) = V_{fb}(T_{NOM})-KT1\left(\frac{T}{T_{NOM}}-1\right) \tag{13.2}$$

$$VOFF(T) = VOFF(T_{NOM})[1+TVOFF(T-T_{NOM})] \tag{13.3}$$

$$VOFFCV(T) = VOFFCV(T_{NOM})[1+TVOFFCV(T-T_{NOM})] \tag{13.4}$$

$$VFBSDOFF(T) = VFBSDOFF(T_{NOM})[1+TVFBSDOFF(T-T_{NOM})] \tag{13.5}$$

$$NFACTOR(T) = NFACTOR(T_{NOM})+TNFACTOR\left(\frac{T}{T_{NOM}}-1\right) \tag{13.6}$$

$$ETA0(T) = ETA0(T_{NOM})+TETA0\left(\frac{T}{T_{NOM}}-1\right) \tag{13.7}$$

#### Mobility

**tempMod=0:**

$$U0(T) = U0(T_{NOM})(T/T_{NOM})^{UTE} \tag{13.8}$$

$$UA(T)=UA(T_{NOM})+UA1(T/T_{NOM}-1) \tag{13.9}$$

$$UB(T)=UB(T_{NOM})+UB1(T/T_{NOM}-1) \tag{13.10}$$

$$UC(T)=UC(T_{NOM})+UC1(T/T_{NOM}-1) \tag{13.11}$$

$$UD(T)=UD(T_{NOM})+UD1(T/T_{NOM}-1) \tag{13.12}$$

**tempMod=1,2:**

$$U0(T) = U0(T_{NOM})(T/T_{NOM})^{UTE} \tag{13.13}$$

$$UA(T)=UA(T_{NOM})[1+UA1(T-T_{NOM})] \tag{13.14}$$

$$UB(T)=UB(T_{NOM})+UB1(T/T_{NOM}-1) \tag{13.15}$$

$$UC(T)=UC(T_{NOM})[1+UC1(T-T_{NOM})] \tag{13.16}$$

$$UD(T)=UD(T_{NOM})[1+UD1(T-T_{NOM})] \tag{13.17}$$

**tempMod=3:**

$$U0(T)=U0(T_{NOM})(T/T_{NOM})^{UTE} \tag{13.18}$$

$$UCS(T)=UCS(T_{NOM})(T/T_{NOM})^{UCSTE} \tag{13.19}$$

$$UA(T)=UA(T_{NOM})(T/T_{NOM})^{UA1} \tag{13.20}$$

$$UB(T)=UB(T_{NOM})(T/T_{NOM})^{UB1} \tag{13.21}$$

$$UC(T)=UC(T_{NOM})(T/T_{NOM})^{UC1} \tag{13.22}$$

$$UD(T)=UD(T_{NOM})(T/T_{NOM})^{UD1} \tag{13.23}$$

#### Saturation Velocity

tempMod=0: $VSAT(T) = VSAT(T_{NOM})-AT(T/T_{NOM}-1)$ (13.24)

tempMod=1,2,3: $VSAT(T) = VSAT(T_{NOM})[1-AT(T-T_{NOM})]$ (13.25)

#### LDD Resistance

**tempMod=0, rdsMod=0:**

$$RDSW(T)=RDSW(T_{NOM})+PRT(T/T_{NOM}-1) \tag{13.26}$$

$$RDSWMIN(T)=RDSWMIN(T_{NOM})+PRT(T/T_{NOM}-1) \tag{13.27}$$

**tempMod=0, rdsMod=1:** Eqs. (13.28)--(13.31) analogous for RDW, RDWMIN, RSW, RSWMIN.

**tempMod=1,2,3, rdsMod=0:**

$$RDSW(T)=RDSW(T_{NOM})[1+PRT(T-T_{NOM})] \tag{13.32}$$

**tempMod=1,2,3, rdsMod=1:** Eqs. (13.34)--(13.37) analogous.

#### Junction Diode IV Temperature

Source saturation current:

$$I_{sbs} = A_{seff}J_{ss}(T)+P_{seff}J_{ssws}(T)+W_{effcj} \cdot NF \cdot J_{sswgs}(T) \tag{13.38}$$

Temperature-dependent current densities follow Arrhenius-type scaling with $XTIS$, $E_g$ (Eqs. 13.39--13.45 for source; 13.42--13.45 for drain).

TAT ideality factor temperature:

$$NJTSSWG(T)=NJTSSWG(T_{NOM})\left[1+TNJTSSWG\left(\frac{T}{T_{NOM}}-1\right)\right] \tag{13.52}$$

$$NJTS(T)=NJTS(T_{NOM})\left[1+TNJTS\left(\frac{T}{T_{NOM}}-1\right)\right] \tag{13.53}$$

(Drain-side analogous: Eqs. 13.54--13.57.)

#### Junction Diode CV Temperature

Source:

$$CJS(T) = CJS(T_{NOM})+TCJ(T-T_{NOM}) \tag{13.49}$$

$$CJSWS(T)=CJSWS(T_{NOM})+TCJSW(T-T_{NOM}) \tag{13.50}$$

$$CJSWGS(T)=CJSWGS(T_{NOM})[1+TCJSWG(T-T_{NOM})] \tag{13.51}$$

$$PBS(T)=PBS(T_{NOM})-TPB(T-T_{NOM}) \tag{13.52}$$

$$PBSWS(T)=PBSWS(T_{NOM})-TPBSW(T-T_{NOM}) \tag{13.53}$$

$$PBSWGS(T)=PBSWGS(T_{NOM})-TPBSWG(T-T_{NOM}) \tag{13.54}$$

Drain side: Eqs. (13.55)--(13.60) analogous with CJD, CJSWD, CJSWGD, PBD, PBSWD, PBSWGD.

#### Energy Band-Gap and Intrinsic Carrier (mtrlMod=0)

$$E_g(T_{NOM}) = 1.16 - \frac{7.02\times10^{-4}T_{NOM}^2}{T_{NOM}+1108} \tag{13.61}$$

$$E_g(T) = 1.16 - \frac{7.02\times10^{-4}T^2}{T+1108} \tag{13.62}$$

$$n_i = 1.45\times10^{10}\frac{T_{NOM}}{300.15}\sqrt{\frac{T_{NOM}}{300.15}}\exp\left[21.5565981-\frac{qE_g(T_{NOM})}{2k_BT_{NOM}}\right] \tag{13.63}$$

#### Energy Band-Gap and Intrinsic Carrier (mtrlMod=1)

$$E_{g0} = BG0SUB-\frac{TBGASUB \cdot T_{nom}^2}{T_{nom}+TBGBSUB} \tag{13.64}$$

$$E_g(300.15)=BG0SUB-\frac{TBGASUB \cdot 300.15^2}{300.15+TBGBSUB} \tag{13.65}$$

$$E_g(T)=BG0SUB-\frac{TBGASUB \cdot T^2}{T+TBGBSUB} \tag{13.66}$$

$$n_i = NI0SUB\left(\frac{T_{nom}}{300.15}\right)^{3/2}\exp\left(\frac{E_g(300.15)-E_{g0}}{2v_t}\right) \tag{13.67}$$

---

### Chapter 14: Stress Effect Model

#### Mobility-Related

$$\Delta\mu_{eff} = \frac{KU0}{K_{stress,u0}}(Inv\_sa+Inv\_sb) \tag{14.3}$$

$$Inv\_sa = \frac{1}{SA+0.5 \cdot L_{drawn}},\quad Inv\_sb = \frac{1}{SB+0.5 \cdot L_{drawn}} \tag{14.4}$$

$$K_{stress,u0} = 1+\frac{LKU0}{(L_{drawn}+XL)^{LLODKU0}}+\frac{WKU0}{(W_{drawn}+XW+WLOD)^{WLODKU0}}$$
$$+\frac{PKU0}{(L_{drawn}+XL)^{LLODKU0}(W_{drawn}+XW+WLOD)^{WLODKU0}}\left(1+TKU0\left(\frac{T}{T_{NOM}}-1\right)\right)$$

$$\mu_{eff} = \frac{1+\Delta\mu_{eff}(SA,SB)}{1+\Delta\mu_{eff}(SA_{ref},SB_{ref})}\mu_{eff,0} \tag{14.5}$$

$$v_{sat,temp} = \frac{1+KVSAT \cdot \Delta\mu_{eff}(SA,SB)}{1+KVSAT \cdot \Delta\mu_{eff}(SA_{ref},SB_{ref})}v_{sat,temp,0} \tag{14.6}$$

#### Vth-Related

$$VTH0 = VTH0_{orig}+\frac{KVTH0}{K_{stress,vth0}}(Inv\_sa+Inv\_sb-Inv\_sa_{ref}-Inv\_sb_{ref}) \tag{14.7}$$

$$K2 = K2_{orig}+\frac{STK2}{K_{stress,vth0}^{LODK2}}(Inv\_sa+Inv\_sb-Inv\_sa_{ref}-Inv\_sb_{ref})$$

$$ETA0 = ETA0_{orig}+\frac{STETA0}{K_{stress,vth0}^{LODETA0}}(Inv\_sa+Inv\_sb-Inv\_sa_{ref}-Inv\_sb_{ref})$$

$$K_{stress,vth0} = 1+\frac{LKVTH0}{(L_{drawn}+XL)^{LLODKVTH}}+\frac{WKVTH0}{(W_{drawn}+XW+WLOD)^{WLODKVTH}}+\frac{PKVTH0}{(L_{drawn}+XL)^{LLODKVTH}(W_{drawn}+XW+WLOD)^{WLODKVTH}} \tag{14.9}$$

#### Multiple Finger Device

$$Inv\_sa = \frac{1}{NF}\sum_{i=0}^{NF-1}\frac{1}{SA+0.5L_{drawn}+i(SD+L_{drawn})}$$

$$Inv\_sb = \frac{1}{NF}\sum_{i=0}^{NF-1}\frac{1}{SB+0.5L_{drawn}+i(SD+L_{drawn})}$$

#### Effective SA/SB for Irregular LOD

$$\frac{1}{SA_{eff}+0.5L_{drawn}} = \sum_{i=1}^{n}\frac{sw_i}{W_{drawn}}\frac{1}{sa_i+0.5L_{drawn}} \tag{14.10}$$

---

### Chapter 15: Well Proximity Effect Model

$$V_{th0} = V_{th0,org}+KVTH0WE \cdot (SCA+WEB \cdot SCB+WEC \cdot SCC) \tag{15.1}$$

$$K2 = K2_{org}+K2WE \cdot (SCA+WEB \cdot SCB+WEC \cdot SCC)$$

$$\mu_{eff} = \mu_{eff,org}(1+KU0WE \cdot (SCA+WEB \cdot SCB+WEC \cdot SCC))$$
