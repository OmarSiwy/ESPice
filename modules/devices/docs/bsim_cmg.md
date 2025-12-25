# BSIM-CMG 112.1.0 -- Parameter & Equation Reference

> FinFET / GAA multi-gate MOSFET compact model
> UC Berkeley, April 2026

## Model Topology

BSIM-CMG is a surface-potential-based compact model for common multi-gate (CMG) MOSFET structures including double-gate (DG), triple-gate (TG), quadruple-gate (QG), cylindrical gate-all-around (GAA), and nanosheet FETs. The device has four terminals: Gate (G), Drain (D), Source (S), and Substrate/Body (E). Internal nodes include intrinsic gate (Gi/Ge), intrinsic drain (Di), intrinsic source (Si), and temperature node (T) for self-heating. The equivalent circuit comprises an intrinsic MOSFET core with bias-dependent source/drain extension resistances, bias-independent diffusion resistances, gate electrode resistance, parasitic overlap and fringe capacitances, junction diodes (bulk only), and substrate coupling capacitances.

---

## Parameters

### Instance and Model Geometry Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| L | m | 30e-9 | [1e-9, -] | Designed gate length |
| LOVER | m | 30e-9 | [1e-20, -] | Designed overlap length (HVMOD=1) |
| D | m | 40e-9 | [1e-9, -] | Diameter of cylinder (GEOMOD=3) |
| TFIN | m | 15e-9 | [1e-9, -] | Fin thickness |
| FPITCH | m | 80e-9 | [TFIN, -] | Fin pitch |
| NFIN | - | 1 | [>0, -] | Number of fins per finger |
| NFINNOM | - | 0 | [0, -] | Nominal number of fins per finger |
| NGCON | - | 1 | [1, 2] | Number of gate contacts |
| NF | - | 1 | [1, -] | Number of fingers (pure instance) |
| HFIN | m | 30e-9 | [1e-9, -] | Fin height |
| TGAA | m | 5e-9 | [0, -] | Thickness of individual GAA bodies (GEOMOD=5) |
| TSUS | m | 2e-9 | [0, -] | Separation between GAA bodies (GEOMOD=5) |
| HPFF | m | 5e-9 | [0, -] | Fin height of parasitic FinFET (CGEOMOD=3) |
| WGAA | m | 6e-9 | [0, -] | Width of GAA body (GEOMOD=5) |
| NGAA | - | 1 | [1, 3] | Number of GAA bodies per fin (GEOMOD=5) |
| ASEO | m^2 | 0 | [0, -] | Source to substrate overlap area through oxide |
| ADEO | m^2 | 0 | [0, -] | Drain to substrate overlap area through oxide |
| PSEO | m | 0 | [0, -] | Perimeter of source to substrate overlap region |
| PDEO | m | 0 | [0, -] | Perimeter of drain to substrate overlap region |
| ASEJ | m^2 | 0 | [0, -] | Source junction area (BULKMOD=1) |
| ADEJ | m^2 | 0 | [0, -] | Drain junction area (BULKMOD=1) |
| PSEJ | m | 0 | [0, -] | Source junction perimeter (BULKMOD=1) |
| PDEJ | m | 0 | [0, -] | Drain junction perimeter (BULKMOD=1) |
| LRSD | m | L | [0, -] | Length of source/drain |
| XL (b) | m | 0 | [-, -] | L offset for channel length due to mask/etch effect |
| XW (b) | m | 0 | [-, -] | W offset for GAA channel width (GEOMOD=5) |
| TFIN_BASE | m | 0 | [0, inf] | Base fin thickness for trapezoidal FinFET |
| TFIN_TOP | m | 0 | [0, -] | Top fin thickness for trapezoidal FinFET |
| DWS1 | m | 0 | [-, 0] | Width correction for first GAA body |
| DWS2 | m | DWS1 | [-, 0] | Width correction for second GAA body |
| DWS3 | m | DWS1 | [-, 0] | Width correction for third GAA body |
| DACH1 | m^2 | 0 | [-, 0] | Area correction for first GAA body |
| DACH2 | m^2 | DACH1 | [-, 0] | Area correction for second GAA body |
| DACH3 | m^2 | DACH1 | [-, 0] | Area correction for third GAA body |

### Model Controllers and Process Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TYPE | - | NMOS | [PMOS, NMOS] | NMOS=1, PMOS=-1 |
| BULKMOD | - | 0 | [0, 1] | 0=SOI, 1=bulk substrate |
| GEOMOD | - | 1 | [0, 6] | 0=DG, 1=TG, 2=QG, 3=cylindrical, 4=unified, 5=GAAFET, 6=single-gate |
| GEO1SW | - | 0 | [0, 1] | CGEOMOD=1 per-fin per-finger per-width switch |
| RDSMOD | - | 0 | [0, 1] | 0=internal bias-dep, 1=external, 2=internal all |
| ASYMMOD | - | 0 | [0, 1] | Asymmetric I-V model selector |
| IGCMOD | - | 0 | [0, 1] | Gate-to-channel current selector |
| IGBMOD | - | 0 | [0, 1] | Gate-to-body current selector |
| GIDLMOD | - | 0 | [0, 2] | GIDL/GISL current selector |
| CVMOD | - | 0 | [0, 1] | 0=consistent I-V/C-V, 1=decoupled |
| IIMOD | - | 0 | [0, 2] | Impact ionization: 0=off, 1=BSIM4, 2=BSIMSOI |
| NQSMOD | - | 0 | [0, 1] | NQS gate resistor selector |
| SHMOD | - | 0 | [0, 1] | Self-heating selector |
| RGATEMOD | - | 0 | [0, 1] | Gate electrode resistance selector |
| RSUBMOD | - | 0 | [0, 1] | Substrate resistor network selector |
| RGEOMOD | - | 0 | [0, 1] | Bias-independent parasitic resistance model |
| CGEOMOD | - | 0 | [0, 2] | Parasitic capacitance model selector |
| TEMPMOD | - | 0 | [0, 1] | Temperature dependence model selector |
| CRYOMOD | - | 0 | [0, 2] | Cryogenic model: 0=off, 1=physical, 2=smooth >210K |
| FNMOD | - | 0 | [0, 1] | Flicker noise model: 0=BSIM4, 1=improved |
| TNOIMOD | - | 0 | [0, 1] | Thermal noise: 0=charge-based, 1=correlated |
| HVMOD | - | 0 | [0, 1] | Improved overlap cap for LDD FinFETs |
| SUBBANDMOD | - | 0 | [0, 1] | GAAFET quantum subband model |
| MOBSCMOD | - | 0 | [0, 1] | GAAFET geometry-dependent mobility model |
| SH_WARN | - | 0 | [0, 1] | Self-heating disabled warning |
| IGCLAMP | - | 1 | [0, 1] | Igs/Igd clamp selector |

### Channel Length and Width Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| LINT (b) | m | 0.0 | [-, -] | Length reduction (dopant diffusion) |
| LL | m^(LLN+1) | 0.0 | [-, -] | Length reduction parameter |
| LLN | - | 1.0 | [-, -] | Length reduction exponent |
| DLC | m | 0.0 | [-, -] | Length reduction for C-V |
| DLCACC | m | 0.0 | [-, -] | Length reduction for CV accumulation (BULKMOD=1) |
| LLC | m^(LLN+1) | 0.0 | [-, -] | Length reduction for C-V |
| DLBIN (b) | m | 0.0 | [-, -] | Length reduction for binning |
| DELTAW | m | 0.0 | [-, -] | Reduction of effective width due to fin shape |
| DELTAWCV | m | 0.0 | [-, -] | CV reduction of effective width |
| DWBIN (b) | m | 0.0 | [-, -] | GAA width reduction for binning (GEOMOD=5) |
| DWCACC (b) | m | 0.0 | [-, -] | GAA width reduction for CV accumulation |
| FECH | - | 1.0 | [0, -] | End-channel factor |
| FECHCV | - | 1.0 | [0, -] | CV end-channel factor |

### Process and Material Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| EOT | m | 1.0e-9 | [1e-10, -] | SiO2 equiv. gate dielectric thickness |
| TOXP | m | 1.2e-9 | [1e-10, -] | Physical oxide thickness |
| EOTBOX | m | 140e-9 | [1e-9, -] | SiO2 equiv. buried oxide thickness |
| EOTACC | m | EOT | [1e-10, -] | Gate dielectric thickness for accumulation |
| EPSROX | - | 3.9 | [1, -] | Relative dielectric constant of gate insulator |
| EPSRSUB | - | 11.9 | [1, -] | Relative dielectric constant of channel |
| EASUB | eV | 4.05 | [0, -] | Electron affinity of substrate |
| NI0SUB | m^-3 | 1.1e16 | [-, -] | Intrinsic carrier concentration at 300.15K |
| BG0SUB | eV | 1.12 | [-, -] | Band gap at 300.15K |
| NC0SUB | m^-3 | 2.86e25 | [-, -] | Conduction band DOS at 300.15K |
| NBODY (b) | m^-3 | 1e22 | [-, -] | Channel doping concentration |
| NSD | m^-3 | 2e26 | [2e25, 1e27] | S/D doping concentration |
| NGATE (b) | m^-3 | 0 | [-, -] | Poly gate doping (0=metal gate) |
| PHIG (b) | eV | 4.61 | [-, -] | Gate workfunction |
| PHIGL | eV*m | 0 | [-, -] | Length dependence of gate workfunction |
| PHIGLT | m^-1 | 0.0 | [-, -] | Coupled NFIN-L dependence of PHIG |
| PHIGN1 | - | 0 | [-0.08, -] | NFIN dependence of PHIG |
| PHIGN2 | - | 1e5 | [1e-5, -] | NFIN dependence of PHIG |
| IMIN | A/m^2 | 1e-15 | [0, -] | Voltage clamping for inversion calc |

### Short Channel Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CIT (b) | F/m^2 | 0.0 | [-, -] | Interface trap parameter |
| CDSC (b) | F/m^2 | 7e-3 | [0, -] | S/D to channel coupling capacitance |
| CDSCN1 | - | 0 | [-0.08, -] | NFIN dependence of CDSC |
| CDSCN2 | - | 1e5 | [-, -] | NFIN dependence of CDSC |
| CDSCD (b) | F/m^2 | 7e-3 | [0, -] | Drain-bias sensitivity of CDSC |
| CDSCDN1 | - | 0 | [-0.08, -] | NFIN dependence of CDSCD |
| CDSCDN2 | - | 1e5 | [1e-5, -] | NFIN dependence of CDSCD |
| CDSCDR (b) | F/m^2 | CDSCD | [0, -] | Reverse-mode drain-bias sensitivity |
| CDSCDRN1 | - | CDSCDN1 | [-0.08, -] | NFIN dependence of CDSCDR |
| CDSCDRN2 | - | CDSCDN2 | [1e-5, -] | NFIN dependence of CDSCDR |
| DVT0 (b) | - | 0.0 | [0, -] | SCE coefficient |
| DVT1 (b) | - | 0.60 | [>0, -] | SCE exponent coefficient |
| DVT1SS (b) | - | DVT1 | [>0, -] | Subthreshold swing exponent coefficient |
| PHIN (b) | V | 0.05 | [-, -] | Nonuniform vertical doping on surface potential |
| ETA0 (b) | - | 0.60 | [0, -] | DIBL coefficient |
| ETA1 (b) | - | 0.00 | [-, -] | DIBL coefficient for low gate overdrive |
| ETA0LT | m^-1 | 0.0 | [-, -] | Coupled NFIN-L dependence of ETA0 |
| ETA0N1 | - | 0 | [-0.08, -] | NFIN dependence of ETA0 |
| ETA0N2 | - | 0 | [1e-5, -] | NFIN dependence of ETA0 |
| ETA0CV (b) | - | ETA0 | [0, -] | DIBL coefficient for C-V |
| DSUB (b) | - | 1.06 | [>0, -] | DIBL exponent coefficient |
| DVTP0 (b) | - | 0 | [-, -] | Coefficient for DITS |
| DVTP1 (b) | - | 0 | [-, -] | DITS exponent coefficient |
| K1RSCE (b) | V^1/2 | 0.0 | [-, -] | Reverse SCE prefactor |
| LPE0 (b) | m | 5e-9 | [-Leff, -] | Pocket region equivalent length |
| DVTSHIFT (b) | V | 0.0 | [-, -] | Additional Vth shift handle |

### Lateral Non-Uniform Doping and Body Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| K0 (b) | V | -- | [-, -] | Lateral NUD parameter |
| K0SI (b) | - | 1.0 | [>0, -] | Strong-inversion correction factor |
| PHIBE (b) | V | 0.7 | [0.2, 1.2] | Body-effect voltage parameter |
| K1 (b) | V^1/2 | 0.0 | [-, -] | Body-effect coefficient for subthreshold |
| DELVFBACC | V | 0.0 | [-, -] | Additional Vfb shift for accumulation |

### Quantum Mechanical Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| QMFACTOR (b) | - | 0.0 | [-, -] | Prefactor for QM Vth shift |
| QMTCENCV (b) | - | 0.0 | [-, -] | QM effective width/tox correction for CV |
| QMTCENCVA (b) | - | 0.0 | [-, -] | QM correction for accumulation CV |
| QM0 | V | 1e-3 | [>0, -] | Normalization for QM charge centroid (inversion) |
| PQM (b) | - | 0.66 | [-, -] | Fitting param for QM charge centroid (inversion) |
| PQML | m^-1 | 0.0 | [-, -] | Length dependence of PQM |
| QM0ACC | V | 1e-3 | [>0, -] | Normalization for QM charge centroid (accumulation) |
| PQMACC | - | 0.66 | [-, -] | Fitting param for QM charge centroid (accumulation) |

### Mobility Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| U0 (b) | m^2/Vs | 3e-2 | [-, -] | Low field mobility |
| U0CV (b) | m^2/Vs | U0 | [-, -] | Low field mobility for CVMOD=1 |
| U0LT | /m | 0.0 | [-, -] | Coupled NFIN-L dependence of U0 |
| U0N1 | - | 0 | [-0.08, -] | NFIN dependence of U0 |
| U0N2 | - | 1e5 | [1e-5, -] | NFIN dependence of U0 |
| U0MULT | - | 1.0 | [>0, -] | Multiplier to mobility |
| ETAMOB (b) | - | 2.0 | [-, -] | Effective field parameter |
| UP (b) | um | 0.0 | [-, -] | Mobility L coefficient |
| LPA | - | 1.0 | [-, -] | Mobility L power coefficient |
| UA (b) | (cmMV^-1)^EU | 0.3 | [>0, -] | Phonon/surface-roughness scattering |
| UACV (b) | (cmMV^-1)^EU | UA | [>0, -] | UA for CVMOD=1 |
| UC (b) | (10^-6 cmMV^-2)^EU | 0.0 | [-, -] | Body effect for mobility (BULKMOD=1) |
| UCCV (b) | (10^-6 cmMV^-2)^EU | UC | [-, -] | UC for CVMOD=1 |
| EU (b) | - | 2.5 | [>0, -] | Coulombic scattering parameter |
| UD (b) | cmMV^-1 | -- | [>0, -] | Phonon/surface-roughness parameter |
| UDCV (b) | cmMV^-1 | UD | [>0, -] | UD for CVMOD=1 |
| UCS (b) | - | 1.0 | [>0, -] | Coulombic scattering parameter |
| UDS (b) | - | 2.0e-5 | [-, -] | Source charge weight in Coulomb (CRYOMOD!=0) |
| UDD (b) | - | -2.0e-5 | [-, -] | Drain charge weight in Coulomb (CRYOMOD!=0) |
| MUHC0 | - | 0.0 | [-, 1.0] | Hot-carrier mobility degradation coefficient |
| MUHC1 | - | 0.0 | [0, -] | Hot-carrier mobility degradation exponent |
| CHARGEWF | - | 0 | [-1, 1] | Average channel charge weighting factor |

### GAAFET Mobility Scaling Parameters (MOBSCMOD=1)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ETAMOBTHIN | - | ETAMOB | [-, -] | Effective field for thin GAA bodies |
| ETAMOBTNI | m | 7.5e-9 | [0, -] | Critical TGAA for non-ideality |
| ETAMOBIR | nm | 0.1 | [0, -] | Ideality parameter |
| UATHIN | (cmMV^-1)^EU | UA | [-, -] | UA for thin GAA bodies |
| UATSAT | m | 9e-9 | [0, -] | Critical TGAA for UA saturation |
| UARTSC | nm^-1 | 0.09 | [0, -] | Rate of UA decay with TGAA |
| UATNI | m | 6.4e-9 | [0, -] | Critical TGAA for non-ideality |
| UAIR | nm | 0.2 | [0, -] | Ideality parameter |
| EUTHIN | cmMV^-1 | EU | [-, -] | EU for thin GAA bodies |
| EUPTSC | - | 3.5 | [0, -] | TGAA scaling exponent of EU |
| EUTNI | m | 6e-9 | [0, -] | Critical TGAA for non-ideality |
| EUIR | nm | 0.2 | [0, -] | Ideality parameter |
| UDTHIN | cmMV^-1 | UD | [-, -] | UD for thin GAA bodies |
| UDTSAT | m | 8.1e9 | [0, -] | Critical TGAA for UD saturation |
| UDPTSC | - | 1.3 | [0, -] | TGAA scaling exponent of UD |
| U0ETAWSC | - | 1.5 | [0, -] | Ratio of sidewall/surface mobility |
| EGBULK | eV | 1.1 | [0, -] | Bulk band-gap |
| U0EMSM1 | meV*nm^2 | 26.6 | [0, -] | Effective mass scaling parameter |
| U0EMSM2 | - | 4 | [-, -] | Effective mass scaling parameter |

### Velocity Saturation Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VSAT (b) | m/s | 85000 | [-, -] | Saturation velocity (saturation region) |
| VSATN1 | - | 0 | [-0.08, -] | NFIN dependence of VSAT |
| VSATN2 | - | 1e5 | [1e-5, -] | NFIN dependence of VSAT |
| VSAT1 (b) | m/s | VSAT | [-, -] | Saturation velocity (linear region, forward) |
| VSAT1N1 | - | 0 | [-0.08, -] | NFIN dependence of VSAT1 |
| VSAT1N2 | - | 1e5 | [1e-5, -] | NFIN dependence of VSAT1 |
| VSAT1R (b) | m/s | VSAT1 | [-, -] | Saturation velocity (linear region, reverse) |
| VSAT1RN1 | - | VSAT1N1 | [-0.08, -] | NFIN dependence of VSAT1R |
| VSAT1RN2 | - | VSAT1N2 | [1e-5, -] | NFIN dependence of VSAT1R |
| VSATDR (b) | m/s | 85000 | [-, -] | Saturation velocity under overlap |
| VSATCV (b) | m/s | VSAT | [-, -] | Saturation velocity for C-V |
| DELTAVSAT (b) | - | 1.0 | [0.01, -] | Velocity saturation parameter (linear) |
| DELTAVSATCV (b) | - | DELTAVSAT | [0.01, -] | DELTAVSAT for C-V |
| PSAT (b) | - | 2.0 | [2.0, -] | Field exponent for velocity saturation |
| PSATCV (b) | - | PSAT | [2.0, -] | PSAT for C-V |
| ASAT (b) | - | 1 | [-, -] | Velocity saturation fitting for CV |
| KSATIV (b) | - | 1.0 | [-, -] | Long channel Vdsat parameter |
| KSATIVDR (b) | - | 1.0 | [-, -] | Long channel Vdsat in overlap region |
| PTWG (b) | V^-2 | 0.0 | [-, -] | Velocity saturation correction (forward) |
| PTWGR (b) | V^-2 | PTWG | [-, -] | Velocity saturation correction (reverse) |
| A1 (b) | V^-2 | 0.0 | [-, -] | Non-saturation effect (strong inversion) |
| A2 (b) | V^-1 | 0.0 | [-, -] | Non-saturation effect (moderate inversion) |
| MEXP (b) | - | 4 | [2, -] | Vdsat smoothing factor |
| MEXPR (b) | - | MEXP | [2, -] | Reverse-mode Vdsat smoothing |
| MEXPDR (b) | - | 4 | [2, -] | Vdsat smoothing in overlap region |

### Output Conductance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PCLM (b) | - | 0.013 | [>0, -] | Channel length modulation parameter |
| PCLMG (b) | - | 0 | [-, -] | Gate-bias dependent CLM parameter |
| PCLMCV (b) | - | PCLM | [>0, -] | CLM parameter for C-V |
| PDIBL1 (b) | - | 1.30 | [0, -] | DIBL effect on Rout (forward) |
| PDIBL1R (b) | - | PDIBL1 | [0, -] | DIBL effect on Rout (reverse) |
| PDIBL2 (b) | - | 2e-4 | [0, -] | DIBL effect on Rout |
| DROUT (b) | - | 1.06 | [>0, -] | L dependence of DIBL on Rout |
| PVAG (b) | - | 1.0 | [-, -] | Vgs dependence on early voltage |

### Parasitic Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RDSWMIN | Ohm*um^WR | 0.0 | [0, -] | RDSMOD=0 min S/D resistance at high Vgs |
| RDSW (b) | Ohm*um^WR | 100 | [0, -] | RDSMOD=0 zero-bias S/D resistance |
| RSWMIN | Ohm*um^WR | 0.0 | [0, -] | RDSMOD=1 source min resistance |
| RSW (b) | Ohm*um^WR | 50 | [0, -] | RDSMOD=1 zero-bias source resistance |
| RDWMIN | Ohm*um^WR | 0.0 | [0, -] | RDSMOD=1 drain min resistance |
| RDW (b) | Ohm*um^WR | 50 | [0, -] | RDSMOD=1 zero-bias drain resistance |
| WR (b) | - | 1.0 | [-, -] | W dependence of S/D extension resistance |
| PRWGS (b) | V^-1 | 0.0 | [-, -] | Source quasi-saturation parameter |
| PRWGD (b) | V^-1 | PRWGS | [-, -] | Drain quasi-saturation parameter |
| RSDR | V^-PRSDR | 0.0 | [0, -] | RDSMOD=1 source drift resistance (forward) |
| RSDRR | V^-PRSDR | RSDR | [0, -] | Source drift resistance (reverse) |
| RDDR | V^-PRDDR | 0.0 | [0, -] | RDSMOD=1 drain drift resistance (forward) |
| RDDRR | V^-PRDDR | RDDR | [0, -] | Drain drift resistance (reverse) |
| PRSDR | - | 1.0 | [0, -] | Source drift resistance exponent |
| PRDDR | - | PRSDR | [0, -] | Drain drift resistance exponent |
| RSHS | Ohm | 0.0 | [0, -] | Source-side sheet resistance |
| RSHD | Ohm | RSHS | [0, -] | Drain-side sheet resistance |
| NRS | - | 0 | [0, -] | Source diffusion squares (RGEOMOD=0) |
| NRD | - | 0 | [0, -] | Drain diffusion squares (RGEOMOD=0) |

### S/D Velocity Saturation Resistance Parameters (RDSMOD=1)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RDLCW | Ohm*um^WR | 0.0 | [0, -] | Drain region low-current resistance |
| RSLCW | Ohm*um^WR | 0.0 | [0, -] | Source region low-current resistance |
| NVSRD | m^-2 | 5.0e16 | [>0, -] | Charge density in drain region |
| NVSRS | m^-2 | NVSRD | [>0, -] | Charge density in source region |
| VSATRSD | m/s | 1.0e5 | [>0, -] | Saturation velocity in S/D region |
| PTWGVSRSD | V^-1 | 0.0 | [0, -] | VSATRSD gate-bias variation |
| PTWG1VSRSD | V | 0.0 | [0, -] | VSATRSD gate-bias variation |
| PSATXVSRSD | V | 60.0 | [0, -] | Fine tuning of PTWGVSRSD |
| MVSRSD | - | 1.0 | [0, -] | Non-linear resistance parameter |
| VSRDFACTOR | - | 1.0e-3 | [1e-4, 1.0] | Delta_vsrd tuning |
| VSRSFACTOR | - | 1.0e-3 | [1e-4, 1.0] | Delta_vsrs tuning |
| RDVDS | V | 8.0 | [-, -] | Isat,rd drain voltage variation |
| GAVSRD | V^-1 | 0.0 | [0, -] | Isat,rd drain voltage variation |

### Gate Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RGEXT | Ohm | 0.0 | [0, -] | Gate electrode external resistance |
| RGINT | Ohm | 0.0 | [0, -] | Gate electrode internal resistance |
| RGP | Ohm | 0.0 | [0, -] | Gate resistance charging parasitic caps |
| RGFIN | Ohm | 1.0e-3 | [1e-3, -] | Gate resistance per fin per finger |
| GBMIN | Ohm^-1 | 1e-12 | [0, -] | Minimum substrate conductance |

### Substrate Network Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RBPB | Ohm | 50 | [1e-3, -] | e to ex node resistance |
| RBSB | Ohm | 50 | [1e-3, -] | se to ex node resistance |
| RBDB | Ohm | 50 | [1e-3, -] | de to ex node resistance |
| RBPS | Ohm | 50 | [1e-3, -] | se to e node resistance |
| RBPD | Ohm | 50 | [1e-3, -] | de to e node resistance |

### Gate Tunneling Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TOXREF | m | 1.2e-9 | [>0, -] | Nominal gate oxide for tunneling |
| TOXG | m | TOXP | [>0, -] | Oxide thickness for gate current |
| NTOX (b) | - | 1.0 | [-, -] | Exponent for gate oxide ratio |
| AIGBINV (b) | (Fs^2g^-1)^0.5 m^-1 | 1.11e-2 | [-, -] | Igb inversion parameter |
| BIGBINV (b) | V^-1 | 9.49e-4 | [-, -] | Igb inversion parameter |
| CIGBINV (b) | V^-1 | 6.00e-3 | [-, -] | Igb inversion parameter |
| EIGBINV (b) | - | 1.1 | [-, -] | Igb inversion parameter |
| NIGBINV | - | 3.0 | [>0, -] | Igb inversion parameter |
| AIGBACC (b) | (Fs^2g^-1)^0.5 m^-1 | 1.36e-2 | [-, -] | Igb accumulation parameter |
| BIGBACC (b) | V^-1 | 1.71e-3 | [-, -] | Igb accumulation parameter |
| CIGBACC (b) | V^-1 | 7.5e-2 | [-, -] | Igb accumulation parameter |
| NIGBACC | - | 1.0 | [>0, -] | Igb accumulation parameter |
| AIGC (b) | (Fs^2g^-1)^0.5 m^-1 | 1.36e-2 | [-, -] | Igc inversion parameter |
| BIGC (b) | V^-1 | 1.71e-3 | [-, -] | Igc inversion parameter |
| CIGC (b) | - | 0.075 | [-, -] | Igc inversion parameter |
| PIGCD (b) | - | 1.0 | [>0, -] | Vds dependence of Igcs/Igcd |
| DLCIGS | m | 0.0 | [-, -] | Delta L for Igs model |
| DLCIGD | m | DLCIGS | [-, -] | Delta L for Igd model |
| AIGS (b) | (Fs^2g^-1)^0.5*m^-1 | 1.36e-2 | [-, -] | Igs inversion parameter |
| BIGS (b) | m^-1 V^-1 | 1.71e-3 | [-, -] | Igs inversion parameter |
| CIGS (b) | m^-1 V^-1 | 0.075 | [-, -] | Igs inversion parameter |
| AIGD (b) | (Fs^2g^-1)^0.5*m^-1 | AIGS | [-, -] | Igd inversion parameter |
| BIGD (b) | m^-1 V^-1 | BIGS | [-, -] | Igd inversion parameter |
| CIGD (b) | m^-1 V^-1 | CIGS | [-, -] | Igd inversion parameter |
| POXEDGE (b) | - | 1 | [>0, -] | Gate edge Tox factor |
| VFBSD | V | 0.0 | [-, -] | Flat band voltage for S/D region |
| VFBSDCV | V | VFBSD | [-, -] | VFBSD for CV |
| IGB0MULT | - | 1.0 | [0, -] | Gate-body current multiplier |
| IGC0MULT | - | 1.0 | [0, -] | Gate-channel current multiplier |

### GIDL/GISL Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| AGIDL (b) | Ohm^-1 | 6.055e-12 | [-, -] | GIDL pre-exponential coefficient |
| BGIDL (b) | V/m | 0.3e9 | [-, -] | GIDL exponential coefficient |
| CGIDL (b) | V^3 | 0.2 | [-, -] | GIDL body bias parameter |
| EGIDL (b) | V | 0.2 | [-, -] | GIDL band bending parameter |
| PGIDL (b) | - | 1.0 | [-, -] | GIDL electric field exponent |
| AGISL (b) | Ohm^-1 | AGIDL | [-, -] | GISL pre-exponential coefficient |
| BGISL (b) | V/m | BGIDL | [-, -] | GISL exponential coefficient |
| CGISL (b) | V^3 | CGIDL | [-, -] | GISL body bias parameter |
| EGISL (b) | V | EGIDL | [-, -] | GISL band bending parameter |
| PGISL (b) | - | PGIDL | [-, -] | GISL electric field exponent |
| AGIDLB (b) | Ohm^-1 | 6.055e-12 | [-, -] | Parasitic substrate GIDL pre-exp (GIDLMOD=2,3) |
| BGIDLB (b) | V/m | 0.3e9 | [-, -] | Parasitic substrate GIDL exp coeff |
| CGIDLB (b) | V^3 | 0.2 | [-, -] | Parasitic substrate GIDL body bias |
| EGIDLB (b) | V | 0.2 | [-, -] | Parasitic substrate GIDL band bending |
| PGIDLB (b) | - | 1.0 | [-, -] | Parasitic substrate GIDL exponent |
| AGISLB (b) | Ohm^-1 | AGIDLB | [-, -] | Parasitic substrate GISL pre-exp |
| BGISLB (b) | V/m | BGIDLB | [-, -] | Parasitic substrate GISL exp coeff |
| CGISLB (b) | V^3 | CGIDLB | [-, -] | Parasitic substrate GISL body bias |
| EGISLB (b) | V | EGIDLB | [-, -] | Parasitic substrate GISL band bending |
| PGISLB (b) | - | PGIDLB | [-, -] | Parasitic substrate GISL exponent |
| VFBDRIFTS | V | -0.2 | [-, -] | Drift region flat-band voltage (di-side) |
| VFBDRIFTD | V | -0.2 | [-, -] | Drift region flat-band voltage (di1-side) |

### TAT GIDL/GISL Parameters (GIDLMOD=3)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ATATD (b) | A*m^2 | 1.0e-27 | [-, -] | TAT GIDL pre-exponential |
| BTATD (b) | V^-1 | 6.3e-5 | [-, -] | TAT GIDL field correction |
| CTATD (b) | - | 0.215 | [-, -] | TAT GIDL field correction |
| DTATD (b) | V | 0.382 | [-, -] | TAT GIDL field correction |
| ATATS (b) | A*m^2 | ATATD | [-, -] | TAT GISL pre-exponential |
| BTATS (b) | V^-1 | BTATD | [-, -] | TAT GISL field correction |
| CTATS (b) | - | CTATD | [-, -] | TAT GISL field correction |
| DTATS (b) | V | DTATD | [-, -] | TAT GISL field correction |

### Impact Ionization Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ALPHA0 (b) | m*V^-1 | 0.0 | [-, -] | First Iii parameter (IIMOD=1) |
| ALPHA1 (b) | V^-1 | 0.0 | [-, -] | L scaling of Iii (IIMOD=1) |
| BETA0 (b) | V^-1 | 0.0 | [-, -] | Vds dependent Iii (IIMOD=1) |
| ALPHAII0 (b) | m*V^-1 | 0.0 | [-, -] | First Iii parameter (IIMOD=2) |
| ALPHAII1 (b) | V^-1 | 0.0 | [-, -] | L scaling of Iii (IIMOD=2) |
| BETAII0 (b) | V^-1 | 0.0 | [-, -] | Vds dependent Iii (IIMOD=2) |
| BETAII1 (b) | - | 0.0 | [-, -] | Vds dependent Iii (IIMOD=2) |
| BETAII2 (b) | V | 0.1 | [-, -] | Vds dependent Iii (IIMOD=2) |
| ESATII (b) | V/m | 1.0e7 | [-, -] | Saturation E-field for Iii (IIMOD=2) |
| LII (b) | V*m | 0.5e-9 | [-, -] | Channel length dependent Iii (IIMOD=2) |
| SII0 (b) | V | 0.5 | [-, -] | Vgs dependent Iii (IIMOD=2) |
| SII1 (b) | - | 0.1 | [-, -] | Vgs dependent Iii (IIMOD=2) |
| SII2 (b) | V | 0.0 | [-, -] | Vgs dependent Iii (IIMOD=2) |
| SIID (b) | V | 0.0 | [-, -] | Vds dependent Iii (IIMOD=2) |

### Parasitic Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CFS (b) | F/m | 2.5e-11 | [-, -] | Source outer fringe cap (CGEOMOD=0) |
| CFD (b) | F/m | CFS | [-, -] | Drain outer fringe cap (CGEOMOD=0) |
| CGSO | F/m | calculated | [0, -] | Source-gate overlap cap (CGEOMOD=0,2) |
| CGDO | F/m | calculated | [0, -] | Drain-gate overlap cap (CGEOMOD=0,2) |
| CGSL (b) | F/m | 0 | [-, -] | Gate-LDD source overlap cap (CGEOMOD=0,2,3) |
| CGDL (b) | F/m | CGSL | [-, -] | Gate-LDD drain overlap cap (CGEOMOD=0,2,3) |
| CKAPPAS (b) | V | 0.6 | [-, -] | Bias-dependent overlap cap (source) |
| CKAPPAD (b) | V | CKAPPAS | [-, -] | Bias-dependent overlap cap (drain) |
| COVS (b) | F or F/m | see GEO1SW | [0, -] | Gate-source overlap cap (CGEOMOD=1) |
| COVD (b) | F or F/m | COVS | [-, -] | Gate-drain overlap cap (CGEOMOD=1) |
| CGSP | F or F/m | see GEO1SW | [0, -] | Gate-source fringe cap (CGEOMOD=1) |
| CGDP | F or F/m | see GEO1SW | [0, -] | Gate-drain fringe cap (CGEOMOD=1) |
| CDSP | F | 0 | [0, -] | Drain-source fringe cap |
| CGBO | F/m | 0 | [0, -] | Gate-substrate overlap cap per length per finger per contact |
| CGBN | F/m | 0 | [0, -] | Gate-substrate overlap cap per length per fin |
| CSDESW | F/m | 0 | [0, -] | S/D sidewall fringing cap per unit length |
| CBOX | F/m^2 | -- | -- | Buried oxide cap per unit area |

### Junction Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CJS | F/m^2 | 0.0005 | [0, -] | Source junction cap at zero bias |
| CJD | F/m^2 | CJS | [0, -] | Drain junction cap at zero bias |
| CJSWS | F/m | 5.0e-10 | [0, -] | Source sidewall junction cap at zero bias |
| CJSWD | F/m | CJSWS | [0, -] | Drain sidewall junction cap at zero bias |
| CJSWGS | F/m | 0.0 | [0, -] | Source gate-sidewall junction cap |
| CJSWGD | F/m | CJSWGS | [0, -] | Drain gate-sidewall junction cap |
| PBS | V | 1.0 | [0.01, -] | Source bottom junction built-in potential |
| PBD | V | PBS | [0.01, -] | Drain bottom junction built-in potential |
| PBSWS | V | 1.0 | [0.01, -] | Source sidewall junction built-in potential |
| PBSWD | V | PBSWS | [0.01, -] | Drain sidewall junction built-in potential |
| PBSWGS | V | PBSWS | [0.01, -] | Source gate-sidewall built-in potential |
| PBSWGD | V | PBSWGS | [0.01, -] | Drain gate-sidewall built-in potential |
| MJS | - | 0.5 | [>0, -] | Source bottom grading coefficient |
| MJD | - | MJS | [>0, -] | Drain bottom grading coefficient |
| MJSWS | - | 0.33 | [>0, -] | Source sidewall grading coefficient |
| MJSWD | - | MJSWS | [>0, -] | Drain sidewall grading coefficient |
| MJSWGS | - | MJSWS | [>0, -] | Source gate-sidewall grading coefficient |
| MJSWGD | - | MJSWGS | [>0, -] | Drain gate-sidewall grading coefficient |
| SJS | - | 0.0 | [0, -] | Two-step second junction constant (source) |
| SJD | - | SJS | [0, -] | Two-step second junction constant (drain) |
| SJSWS | - | 0.0 | [0, -] | Two-step sidewall junction constant (source) |
| SJSWD | - | SJSWS | [0, -] | Two-step sidewall junction constant (drain) |
| SJSWGS | - | 0.0 | [0, -] | Two-step gate-sidewall junction constant (source) |
| SJSWGD | - | SJSWGS | [0, -] | Two-step gate-sidewall junction constant (drain) |
| MJS2 | - | 0.125 | [-, -] | Two-step source bottom grading |
| MJD2 | - | MJS2 | [-, -] | Two-step drain bottom grading |
| MJSWS2 | - | 0.083 | [-, -] | Two-step source sidewall grading |
| MJSWD2 | - | MJSWS2 | [-, -] | Two-step drain sidewall grading |
| MJSWGS2 | - | MJSWS2 | [-, -] | Two-step source gate-sidewall grading |
| MJSWGD2 | - | MJSWGS2 | [-, -] | Two-step drain gate-sidewall grading |

### Junction Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| JSS | A/m^2 | 1.0e-4 | [0, -] | Source bottom junction saturation current density |
| JSD | A/m^2 | JSS | [0, -] | Drain bottom junction saturation current density |
| JSWS | A/m | 0 | [0, -] | Source sidewall junction saturation current |
| JSWD | A/m | JSWS | [0, -] | Drain sidewall junction saturation current |
| JSWGS | A/m | 0 | [0, -] | Source gate-sidewall junction current |
| JSWGD | A/m | JSWGS | [0, -] | Drain gate-sidewall junction current |
| JTSS | A/m^2 | 0 | [0, -] | Source trap-assisted saturation current density |
| JTSD | A/m^2 | JTSS | [0, -] | Drain trap-assisted saturation current density |
| JTSSWS | A/m | 0 | [0, -] | Source sidewall trap-assisted current |
| JTSSWD | A/m | JTSSWS | [0, -] | Drain sidewall trap-assisted current |
| JTSSWGS | A/m | 0 | [0, -] | Source gate-sidewall trap-assisted current |
| JTSSWGD | A/m | JTSSWGS | [0, -] | Drain gate-sidewall trap-assisted current |
| JTWEFF | m | 0 | [0, -] | Trap-assisted tunneling width dependence |
| NJS | - | 1.0 | [0, -] | Source junction emission coefficient |
| NJD | - | NJS | [0, -] | Drain junction emission coefficient |
| NJTS | - | 20 | [0, -] | Non-ideality for JTSS |
| NJTSD | - | NJTS | [0, -] | Non-ideality for JTSD |
| NJTSSW | - | 20 | [0, -] | Non-ideality for JTSSWS |
| NJTSSWD | - | NJTSSW | [0, -] | Non-ideality for JTSSWD |
| NJTSSWG | - | 20 | [0, -] | Non-ideality for JTSSWGS |
| NJTSSWGD | - | NJTSSWG | [0, -] | Non-ideality for JTSSWGD |
| VTSS | V | 10 | [0, -] | Source trap-assisted voltage parameter |
| VTSD | V | VTSS | [0, -] | Drain trap-assisted voltage parameter |
| VTSSWS | V | 10 | [0, -] | Source sidewall trap-assisted voltage |
| VTSSWD | V | VTSSWS | [0, -] | Drain sidewall trap-assisted voltage |
| VTSSWGS | V | 10 | [0, -] | Source gate-sidewall trap-assisted voltage |
| VTSSWGD | V | VTSSWGS | [0, -] | Drain gate-sidewall trap-assisted voltage |
| IJTHSFWD | A | 0.1 | [10*Isbs, -] | Source forward breakdown limiting current |
| IJTHDFWD | A | IJTHSFWD | [10*Isbd, -] | Drain forward breakdown limiting current |
| IJTHSREV | A | 0.1 | [10*Isbs, -] | Source reverse breakdown limiting current |
| IJTHDREV | A | IJTHSREV | [10*Isbd, -] | Drain reverse breakdown limiting current |
| BVS | V | 10.0 | [-, -] | Source diode breakdown voltage |
| BVD | V | BVS | [-, -] | Drain diode breakdown voltage |
| XJBVS | - | 1.0 | [-, -] | Source breakdown current fitting |
| XJBVD | - | XJBVS | [-, -] | Drain breakdown current fitting |

### Generation-Recombination Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| LINTIGEN | m | 0.0 | [-, Leff/2] | Lint offset for R/G current |
| NTGEN (b) | - | 1.0 | [>0, -] | R/G current parameter |
| AIGEN (b) | m^-3 V^-1 | 0.0 | [-, -] | R/G current parameter |
| BIGEN (b) | m^-3 V^-3 | 0.0 | [-, -] | R/G current parameter |

### Noise Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| EF | - | 1.0 | [>0, 2.0] | Flicker noise frequency exponent |
| LINTNOI | m | 0.0 | [-, -] | Lint offset for flicker noise |
| EM | V/m | 4.1e7 | [-, -] | Flicker noise CLM parameter |
| NOIA (b) | eV^-1 m^-3 s^(1-EF) | 6.250e39 | [-, -] | Flicker noise parameter |
| NOIA2 (b) | eV^-1 m^-3 s^(1-EF) | NOIA | [-, -] | Flicker noise for FNMOD=1 |
| NOIB (b) | eV^-1 m^-1 s^(1-EF) | 3.125e24 | [-, -] | Flicker noise parameter |
| NOIC (b) | eV^-1 m^-1 s^(1-EF) | 8.750e7 | [-, -] | Flicker noise parameter |
| QSREF | - | 0.05 | [-, -] | Charge at threshold for FNMOD=1 |
| MPOWER (b) | - | 1.2 | [-, -] | Sub-to-strong inversion slope (FNMOD=1) |
| SMOOTH | - | 2 | [>0, -] | Smoothing parameter (FNMOD=1) |
| K0NOI | - | 1 | [0, -] | Flicker noise drain factor (FNMOD=2) |
| K1NOI | - | 1 | [>0, -] | Flicker noise drain exponent (FNMOD=2) |
| NTNOI | - | 1.0 | [0, -] | Thermal noise parameter |
| RNOIA | - | 0.577 | [-, -] | Thermal noise parameter (TNOIMOD=1) |
| RNOIB | - | 0.37 | [-, -] | Thermal noise parameter (TNOIMOD=1) |
| TNOIA | m^-1 | 1.5 | [0, -] | Thermal noise Leff parameter (TNOIMOD=1) |
| TNOIB | m^-1 | 3.5 | [0, -] | Thermal noise Leff parameter (TNOIMOD=1) |
| RNOIK | - | 0 | [0, -] | Sid level at low Ids (TNOIMOD=1) |
| TNOIK | m^-1 | 0 | [-, -] | Leff trend at low Ids (TNOIMOD=1) |
| TNOIK2 | - | 0.1 | [0, -] | Leff trend at low Ids (TNOIMOD=1) |

### NQS Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| XRCRG1 (b) | - | 12.0 | [0 or >=1e-3, -] | NQS gate resistance (NQSMOD=1,2) |
| XRCRG2 (b) | - | 1.0 | [-, -] | NQS gate resistance (NQSMOD=1,2) |

### Self-Heating Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RTH0 | Ohm*m*K/W | 0.01 | [0, -] | Thermal resistance |
| CTH0 | W*s/(m*K) | 1.0e-5 | [0, -] | Thermal capacitance |
| WTH0 | m | 0.0 | [0, -] | Width-dependence for self-heating |
| ASHEXP | - | 1.0 | [0, -] | Exponent for NFINTOTAL in RTH |
| BSHEXP | - | 1.0 | [0, -] | Exponent for NF in RTH |
| CSHEXP | - | 1.0 | [0, -] | Exponent for NGAA in RTH |
| ASH | - | 1.0 | [0, -] | Coefficient for NGAA in RTH |
| CSH | - | 1.0 | [0, -] | Coefficient for NGAA in RTH |

### Temperature Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TNOM | degC | 27 | [-273.15, -] | Extraction temperature |
| DTEMP | K | 0.0 | [-, -] | Device temperature shift |
| TBGASUB | eV/K | 7.02e-4 | [-, -] | Bandgap temperature coefficient |
| TBGBSUB | K | 1108.0 | [-, -] | Bandgap temperature coefficient |
| KT1 (b) | V | 0.0 | [-, -] | Vth temperature coefficient |
| KT1L | V*m | 0.0 | [-, -] | Vth temperature coefficient (length) |
| KT11 | V | 0.01 | [-, -] | Vth temperature coefficient (CRYOMOD!=0) |
| KT12 | K^-1 | 0.1 | [-, -] | Vth temperature coefficient (CRYOMOD!=0) |
| TVTH | K | 40.0 | [-, -] | Transition temperature in Vth model (CRYOMOD!=0) |
| TSS (b) | K^-1 | 0.0 | [-, -] | SS temperature coefficient |
| TLOW | K | 50.0 | [0, -] | SS transition temperature (CRYOMOD!=0) |
| DTLOW | K | 1.0 | [>0, -] | Smoothing for TLOW |
| TLOW1 | K | 0.0 | [0, -] | SS second transition temperature (CRYOMOD!=0) |
| DTLOW1 | K | 1.0e-3 | [>0, -] | Smoothing for TLOW1 |
| KLOW1 | - | 0.0 | [0, -] | SS rise slope below TLOW1 |
| TETA0 | K^-1 | 0.0 | [-, -] | Temperature dependence of DIBL |
| TETA0R | K^-1 | 0.0 | [-, -] | Temperature dependence of reverse DIBL |
| UTE (b) | - | 0.0 | [-, -] | Mobility temperature exponent for U0 |
| UTL (b) | - | -1.5e-3 | [-, -] | Mobility linear temperature coefficient |
| UTE1 (b) | - | -0.4 | [-, -] | Mobility temperature coefficient (CRYOMOD!=0) |
| EMOBT (b) | - | 0.0 | [-, -] | Temperature coefficient of ETAMOB |
| UA1 (b) | - | 1.032e-3 | [-, -] | Mobility temperature coefficient for UA |
| UA2 (b) | - | -0.04 | [-, -] | Mobility temperature coefficient for UA (CRYOMOD!=0) |
| UC1 (b) | - | 0.056e-9 | [-, -] | Mobility temperature coefficient for UC |
| UD1 (b) | - | 0.0 | [-, -] | Mobility temperature coefficient |
| UD2 (b) | - | -0.04 | [-, -] | UD temperature coefficient (CRYOMOD!=0) |
| UCSTE (b) | - | -4.775e-3 | [-, -] | Mobility temperature coefficient |
| UCSTE1 (b) | - | -0.04 | [-, -] | UCS temperature coefficient (CRYOMOD!=0) |
| UDS1 (b) | - | -10 | [-, -] | UDS temperature coefficient (CRYOMOD!=0) |
| UDD1 (b) | - | -10 | [-, -] | UDD temperature coefficient (CRYOMOD!=0) |
| AT (b) | K^-1 | -0.00156 | [-, -] | VSAT temperature coefficient |
| AT2 | K^-2 | 2.0e-6 | [-, -] | VSAT temperature coefficient (CRYOMOD!=0) |
| ATCV (b) | K^-1 | AT | [-, -] | VSATCV temperature coefficient |
| AT2CV | K^-2 | AT2 | [-, -] | VSATCV temperature (CRYOMOD!=0) |
| ATVSRSD (b) | K^-1 | 0 | [-, -] | VSATRSD temperature coefficient |
| KSATIVT1 | K^-1 | -2.0e-4 | [-, -] | KSATIV temperature (CRYOMOD!=0) |
| KSATIVT2 | K^-2 | -2.0e-7 | [-, -] | KSATIV temperature (CRYOMOD!=0) |
| PCLMT | 1/K | -2.0e-5 | [-, -] | PCLM temperature coefficient |
| PTWGT (b) | K^-1 | 0.004 | [-, -] | PTWG temperature coefficient |
| TMEXP (b) | K^-1 | 0.0 | [-, -] | MEXP temperature coefficient |
| TMEXPR (b) | K^-1 | TMEXP | [-, -] | Reverse-mode MEXP temperature |
| TMEXP2 | K^-2 | -4.0e-6 | [-, -] | MEXP temperature (CRYOMOD!=0) |
| PRT (b) | K^-1 | 0.001 | [-, -] | Series resistance temperature coefficient |
| PRTVSRSD (b) | K^-1 | 0.001 | [-, -] | VSRSD resistance temperature |
| PRT1 (b) | K^-1 | 4.0e-4 | [-, -] | Low-T resistance temperature (CRYOMOD!=0) |
| TR0 (b) | K | 170.0 | [-, -] | Corner temperature in dual-slope model (CRYOMOD!=0) |
| SPRT (b) | - | 0.01 | [-, -] | Smoothing for TR0 (CRYOMOD!=0) |
| TRSDR (b) | K^-1 | 0.0 | [-, -] | Source drift resistance temperature |
| TRDDR (b) | K^-1 | TRSDR | [-, -] | Drain drift resistance temperature |
| IIT (b) | - | -0.5 | [-, -] | Iii temperature exponent (IIMOD=1) |
| TII (b) | - | 0.0 | [-, -] | Iii temperature coefficient (IIMOD=2) |
| ALPHA01 (b) | m*V^-1 K^-1 | 0.0 | [-, -] | ALPHA0 temperature |
| ALPHA11 (b) | V^-1 K^-1 | 0.0 | [-, -] | ALPHA1 temperature |
| ALPHAII01 (b) | m*V^-1 K^-1 | 0.0 | [-, -] | ALPHAII0 temperature |
| ALPHAII11 (b) | V^-1 K^-1 | 0.0 | [-, -] | ALPHAII1 temperature |
| TGIDL (b) | K^-1 | -0.003 | [-, -] | GIDL/GISL temperature |
| IGT (b) | - | 2.5 | [-, -] | Gate current temperature exponent |
| AIGBINV1 (b) | K^-1 | 0.0 | [-, -] | AIGBINV temperature |
| AIGBACC1 (b) | K^-1 | 0.0 | [-, -] | AIGBACC temperature |
| AIGC1 (b) | K^-1 | 0.0 | [-, -] | AIGC temperature |
| AIGS1 (b) | K^-1 | 0.0 | [-, -] | AIGS temperature |
| AIGD1 (b) | K^-1 | 0.0 | [-, -] | AIGD temperature |
| A11 (b) | V^-2 K^-1 | 0.0 | [-, -] | A1 temperature |
| A21 (b) | V^-1 K^-1 | 0.0 | [-, -] | A2 temperature |
| K01 (b) | V/K | 0.0 | [-, -] | K0 temperature |
| K0SI1 (b) | K^-1 | 0.0 | [-, -] | K0SI temperature |
| K11 (b) | V^1/2 K^-1 | 0.0 | [-, -] | K1 temperature |
| TCJ | K^-1 | 0.0 | [-, -] | CJS/CJD temperature |
| TCJSW | K^-1 | 0.0 | [-, -] | CJSWS/CJSWD temperature |
| TCJSWG | K^-1 | 0.0 | [-, -] | CJSWGS/CJSWGD temperature |
| TPB | K^-1 | 0.0 | [-, -] | PBS/PBD temperature |
| TPBSW | K^-1 | 0.0 | [-, -] | PBSWS/PBSWD temperature |
| TPBSWG | K^-1 | 0.0 | [-, -] | PBSWGS/PBSWGD temperature |
| XTIS | - | 3.0 | [-, -] | Source junction current temperature exponent |
| XTID | - | XTIS | [-, -] | Drain junction current temperature exponent |
| XTSS | - | 0.02 | [-, -] | JTSS temperature power dependence |
| XTSD | - | XTSS | [-, -] | JTSD temperature power dependence |
| XTSSWS | - | 0.02 | [-, -] | JTSSWS temperature |
| XTSSWD | - | XTSSWS | [-, -] | JTSSWD temperature |
| XTSSWGS | - | 0.02 | [-, -] | JTSSWGS temperature |
| XTSSWGD | - | XTSSWGS | [-, -] | JTSSWGD temperature |
| TNJTS | - | 0.0 | [-, -] | NJTS temperature |
| TNJTSD | - | TNJTS | [-, -] | NJTSD temperature |
| TNJTSSW | - | 0.0 | [-, -] | NJTSSW temperature |
| TNJTSSWD | - | TNJTSSW | [-, -] | NJTSSWD temperature |
| TNJTSSWG | - | 0.0 | [-, -] | NJTSSWG temperature |
| TNJTSSWGD | - | TNJTSSWG | [-, -] | NJTSSWGD temperature |

### Geometry-Dependent Parasitic Parameters (RGEOMOD=1, CGEOMOD=2)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| HEPI | m | 10e-9 | [-, -] | Height of raised S/D on top of fin |
| TSILI | m | 10e-9 | [-, -] | Silicide thickness on raised S/D |
| RHOC | Ohm*m^2 | 1e-12 | [1e-18, 10e-9] | Contact resistivity |
| RHORSD | Ohm*m | calculated | [0, -] | Silicon resistivity in raised S/D |
| CRATIO | - | 0.5 | [0, 1] | Corner area fill ratio |
| DELTAPRSD | m | 0.0 | [-, -] | S/D interface length change |
| SDTERM | - | 0 | [0, 1] | S/D silicide termination indicator |
| LSP | m | 0.2*(L+XL) | [>0, -] | Gate sidewall spacer thickness |
| EPSRSP | - | 3.9 | [1, -] | Spacer dielectric constant |
| TGATE | m | 30e-9 | [0, -] | Gate height on hard mask |
| TMASK | m | 30e-9 | [0, -] | Hard mask height on fin |
| ASILIEND | m^2 | 0 | [0, -] | Extra silicide area at FinFET ends |
| ARSDEND | m^2 | 0 | [0, -] | Extra raised S/D area at FinFET ends |
| PRSDEND | m | 0 | [0, -] | Extra S/D perimeter at FinFET ends |
| NSDE | m^-3 | 2e25 | [1e25, 1e26] | Active doping at channel edge |
| RGEOA | - | 1.0 | [-, -] | Fitting parameter (RGEOMOD=1) |
| RGEOB | m^-1 | 0 | [-, -] | Fitting parameter (RGEOMOD=1) |
| RGEOC | m^-1 | 0 | [-, -] | Fitting parameter (RGEOMOD=1) |
| RGEOD | m^-1 | 0 | [-, -] | Fitting parameter (RGEOMOD=1) |
| RGEOE | m^-1 | 0 | [-, -] | Fitting parameter (RGEOMOD=1) |
| CGEOA | - | 1.0 | [-, -] | Fitting parameter (CGEOMOD=2,3) |
| CGEOB | m^-1 | 0 | [-, -] | Fitting parameter (CGEOMOD=2,3) |
| CGEOC | m^-1 | 0 | [-, -] | Fitting parameter (CGEOMOD=2,3) |
| CGEOD | m^-1 | 0 | [-, -] | Fitting parameter (CGEOMOD=2,3) |
| CGEOE | - | 1.0 | [-, -] | Fitting parameter (CGEOMOD=2,3) |

### GAAFET Subband Model Parameters (SUBBANDMOD=1)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WGAANOM | m | 8e-9 | [0, -] | Nominal WGAA |
| WDIM0 | m | 9.5e-9 | [0, -] | WGAA at dimension change |
| WDIMR | nm | 0.1 | [0, -] | Rate of dimension change |
| WSSP0 | m | WDIM0 | [0, -] | WGAA for SSP change |
| WSSPR | nm | WDIMR | [0, -] | Rate of SSP change |
| DIM1H | - | 3.0 | [1.0, 3.0] | Max dimension for first subband |
| DIMENSION1 | - | 2.0 | [-, -] | Dimension for first subband |
| DIM2H | - | 3.0 | [-, -] | Max dimension for second subband |
| DIMENSION2 | - | 2.6 | [-, -] | Dimension for second subband |
| DIM3H | - | 3 | [1, 3] | Max dimension for third subband |
| DIMENSION3 | - | 2.6 | [-, -] | Dimension for third subband |
| E2NOM (b) | eV | 0.139 | [-, -] | Second subband energy at WGAANOM |
| E3NOM (b) | eV | 2.0 | [-, -] | Third subband energy at WGAANOM |
| MFE2 | - | 1.0 | [-, -] | Rate of second subband energy change |
| MFE3 | - | 1.0 | [-, -] | Rate of third subband energy change |
| WSFE2 | - | 1.0 | [0, -] | WGAA scaling for second subband energy |
| WSFE3 | - | 1.0 | [0, -] | WGAA scaling for third subband energy |
| TSRE2 | - | 1.8 | [0, -] | TGAA scaling for second subband energy |
| TDWSE2 | - | 1.0 | [0, -] | TGAA dependence of WGAA scaling (2nd subband energy) |
| TSRE3 | - | 0.67 | [0, -] | TGAA scaling for third subband energy |
| TDWSE3 | - | 0.23 | [0, -] | TGAA dependence of WGAA scaling (3rd subband energy) |
| SSP1 (b) | - | 14.0 | [-, -] | First subband smoothing |
| SSP2 (b) | - | 24.0 | [-, -] | Second subband smoothing |
| SSP3 (b) | - | 24.0 | [-, -] | Third subband smoothing |
| DSSP1 (b) | - | 2.0 | [0, -] | SSP1 change with WGAA scaling |
| DSSP2 (b) | - | 0.0 | [0, -] | SSP2 change with WGAA scaling |
| DSSP3 (b) | - | 0.0 | [0, -] | SSP3 change with WGAA scaling |
| MFQ1NOM (b) | - | 11.2 | [-, -] | First subband charge scaling at WGAANOM |
| MFQ2NOM (b) | - | 8.02 | [-, -] | Second subband charge scaling at WGAANOM |
| MFQ3NOM (b) | - | 6.18 | [-, -] | Third subband charge scaling at WGAANOM |
| MFQ1 | - | 1.0 | [-, -] | Rate of first subband charge change |
| MFQ2 | - | 1.0 | [-, -] | Rate of second subband charge change |
| MFQ3 | - | 1.0 | [-, -] | Rate of third subband charge change |
| WSFQ1 | - | 1.0 | [0, -] | WGAA scaling for first subband charge |
| WSFQ2 | - | 1.0 | [0, -] | WGAA scaling for second subband charge |
| WSFQ3 | - | 1.0 | [0, -] | WGAA scaling for third subband charge |
| TSRQ1 | - | 1.1 | [0, -] | TGAA scaling for first subband charge |
| TDWSQ1 | - | 2.4 | [0, -] | TGAA dep. of WGAA scaling (1st subband charge) |
| TSRQ2 | - | 2.0 | [0, -] | TGAA scaling for second subband charge |
| TDWSQ2 | - | 2.0 | [0, -] | TGAA dep. of WGAA scaling (2nd subband charge) |
| TSRQ3 | - | 6.0 | [0, -] | TGAA scaling for third subband charge |
| TDWSQ3 | - | 2.4 | [0, -] | TGAA dep. of WGAA scaling (3rd subband charge) |

### Variability Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DELVTRAND | V | 0.0 | [-, -] | Threshold voltage shift handle |
| IDS0MULT | - | 1.0 | [0, -] | Multiplier to drain current |

### Unified Model Parameters (GEOMOD=4)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ACH_UFCM | m^2 | 1 | [-, -] | Channel area for unified model |
| CINS_UFCM | F/m | 1 | [-, -] | Insulator capacitance |
| W_UFCM | m | 1 | [-, -] | Effective channel width |
| ALPHA_UFCM | - | 1.8 | [-, -] | Mobile charge scaling (QM) |

### Override Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NVTM | V | nkT/q | [0, -] | Override nkT/q in model |
| THETASCE | - | computed | [-, -] | Override SCE theta |
| THETASW | - | computed | [-, -] | Override SW theta |
| THETADIBL | - | computed | [-, -] | Override DIBL theta |

---

## Equations

### Physical Constants (3.1-3.10)

$$q = 1.60219 \times 10^{-19} \text{ C}$$

$$\epsilon_0 = 8.8542 \times 10^{-12} \text{ F/m}$$

$$\hbar = 1.05457 \times 10^{-34} \text{ J s}$$

$$m_e = 9.11 \times 10^{-31} \text{ kg}$$

$$k = 1.3787 \times 10^{-23} \text{ J/K}$$

$$\epsilon_{sub} = EPSRSUB \cdot \epsilon_0$$

$$\epsilon_{ox} = EPSROX \cdot \epsilon_0$$

$$C_{ox} = \frac{3.9 \cdot \epsilon_0}{EOT}$$

$$C_{si} = \frac{\epsilon_{sub}}{TFIN}$$

$$\epsilon_{ratio} = \frac{EPSRSUB}{3.9}$$

### Effective Channel Length (3.11-3.15)

$$\Delta L = LINT + \frac{LL}{(L + XL)^{LLN}}$$

$$L_{eff} = L + XL - 2\Delta L$$

$$\Delta L_{CV} = DLC + \frac{LLC}{(L + XL)^{LLN}}$$

$$L_{eff,CV} = L + XL - 2\Delta L_{CV}$$

If BULKMOD=1: $L_{eff,CV,acc} = L_{eff,CV} - DLCACC$

### Effective Width by GEOMOD (3.18-3.57)

For all GEOMODs, effective width for IV and CV:

$$W_{eff0} = W_{eff,UFCM} - DELTAW$$

$$W_{eff,CV0} = W_{eff,UFCM} - DELTAWCV$$

**GEOMOD=0 (Double Gate):**
$W_{eff,UFCM} = 2 \cdot HFIN$, $A_{CH} = HFIN \cdot TFIN$

**GEOMOD=1 (Triple Gate):**
$W_{eff,UFCM} = 2 \cdot HFIN + TFIN$, $A_{CH} = HFIN \cdot TFIN$

**GEOMOD=2 (Quadruple Gate):**
$W_{eff,UFCM} = 2 \cdot HFIN + 2 \cdot TFIN$, $A_{CH} = HFIN \cdot TFIN$

**GEOMOD=3 (Cylindrical):**
$W_{eff,UFCM} = \pi \cdot D$, $A_{CH} = \pi \cdot D \cdot D/4$

$$C_{INS} = \frac{2\pi \cdot EPSROX \cdot \epsilon_0}{\ln(1 + 2 \cdot EOT / D)}$$

**GEOMOD=5 (GAAFET):**
$W_{eff,i} = 2(W_{GAA,eff} + TGAA) + DW_{Si}$; $W_{eff,UFCM} = \sum_{i=1}^{NGAA} W_{eff,i}$

$A_{ch,i} = W_{GAA,eff} \cdot TGAA + DACH_i$; $A_{ch} = \sum_{i=1}^{NGAA} A_{ch,i}$

For all GEOMODs (except cylindrical):

$$C_{INS} = W_{eff,UFCM} \cdot EPSROX \cdot \frac{\epsilon_0}{EOT}$$

$$r_c = \frac{2 \cdot C_{INS}}{\epsilon_{SUB}}$$

$$q_{dep} = -q \cdot NBODY_i \cdot \frac{A_{CH}}{C_{INS}}$$

### Binning Calculations (3.74-3.78)

$$PARAM_i = PARAM + \frac{1.0\times10^{-6}}{L_{eff1}+DLBIN} \cdot LPARAM + \frac{1.0}{NFIN} \cdot NPARAM + \frac{1.0\times10^{-6}}{NFIN \cdot (L_{eff1}+DLBIN)} \cdot PPARAM$$

For GEOMOD=5, two additional terms:

$$+ \frac{1.0\times10^{-6}}{WGAA} \cdot WPARAM + \frac{1.0\times10^{-12}}{WGAA \times L_{eff1}} \cdot P2PARAM$$

### NFIN Scaling (3.79-3.88)

General form (example for PHIG):

$$PHIG[L,N] = PHIG_i \cdot \left(1 + \frac{PHIGN1}{NFIN} \times \ln\left(1 + \frac{NFIN}{PHIGN2}\right)\right) \times \left[1 + (NFIN - NFINNOM) \cdot PHIGLT \cdot L_{eff}\right]$$

Same form applies to: ETA0, CDSC, CDSCD, CDSCDR, NBODY, VSAT, VSAT1, VSAT1R, U0.

### Length Scaling (3.89-3.104)

$$PHIG[L,N] = PHIG[N] + PHIGL \cdot L_{eff}$$

$$U0[L,N] = \begin{cases} U0[N] \cdot (1 - UP_i \cdot L_{eff}^{-LPA}) & LPA > 0 \\ U0[N] \cdot (1 - UP_i) & \text{otherwise} \end{cases}$$

$$MEXP[L] = MEXP_i + AMEXP \cdot L_{eff}^{-BMEXP}$$

$$PCLM[L] = PCLM_i + APCLM \cdot \exp\left(-\frac{L_{eff}}{BPCLM}\right)$$

$$UA[L] = UA_i + AUA \cdot \exp\left(-\frac{L_{eff}}{BUA}\right)$$

$$RDSW[L] = RDSW_i + ARDSW \cdot \exp\left(-\frac{L_{eff}}{BRDSW}\right)$$

$$VSAT[L,N] = VSAT[N] + AVSAT \cdot \exp\left(-\frac{L_{eff}}{BVSAT}\right)$$

$$PSAT[L] = PSAT_i + APSAT \cdot \exp\left(-\frac{L_{eff}}{BPSAT}\right)$$

### Temperature Effects (3.105-3.200)

$$T = \$temperature + DTEMP$$

Bandgap and intrinsic carrier:

$$E_{g,Tnom} = BG0SUB - \frac{TBGASUB \cdot T_{nom}^2}{T_{nom} + TBGBSUB}$$

$$E_g = BG0SUB - \frac{TBGASUB \cdot T^2}{T + TBGBSUB}$$

$$n_i = NI0SUB \cdot \left(\frac{T}{300.15}\right)^{3/2} \cdot \exp\left(\frac{BG0SUB \cdot q}{2k \cdot 300.15} - \frac{E_g \cdot q}{2k \cdot T}\right)$$

Built-in potential:

$$V_{bi} = \frac{kT}{q} \cdot \ln\left(\frac{NSD \cdot NBODY_i}{n_i^2}\right)$$

Threshold voltage temperature shift:

$$\Delta V_{th,temp} = \left(KT1 + \frac{KT1L}{L_{eff}}\right) \cdot \left(\frac{T}{T_{nom}} - 1\right)$$

Mobility temperature:

$$\mu_0(T) = U0[L,N] \cdot \left(\frac{T}{T_{nom}}\right)^{UTE_i} + UTL_i \cdot (T - T_{nom})$$

$$UA(T) = UA[L] + UA1_i \cdot (T - T_{nom})$$

Saturation velocity temperature:

$$VSAT(T) = VSAT[L,N] \cdot (1 - AT \cdot (T - T_{nom}))$$

Junction current temperature (source side):

$$T_{3s} = \exp\left(\frac{qE_{g,Tnom}}{kT_{nom}} - \frac{qE_g}{kT} + XTIS \cdot \ln\frac{T}{T_{nom}}\right)$$

$$J_{ss}(T) = JSS \cdot T_{3s}^{NJS}$$

Junction capacitance temperature:

$$CJS(T) = CJS \cdot [1 + TCJ \cdot (T - T_{nom})]$$

$$PBS(T) = PBS(T_{nom}) - TPB \cdot (T - T_{nom})$$

### Short Channel Effects (3.411-3.422)

Characteristic field penetration:

$$scl = \sqrt{\frac{\epsilon_{SUB} \cdot A_{CH}}{C_{INS}} \cdot \left(1 + \frac{A_{CH} \cdot C_{INS}}{2 \cdot \epsilon_{SUB} \cdot W_{eff,UFCM}^2}\right)}$$

Subthreshold slope degradation:

$$\Theta_{SW} = \frac{0.5}{\cosh\left(DVT1SS_i \cdot \frac{L_{eff}}{\lambda}\right) - 1}$$

$$C_{dsc} = \Theta_{SW} \cdot (CDSC[N] + CDSCD_a \cdot V_{dsx})$$

$$n = \Theta_{SS} \cdot \left(1 + \frac{CIT_i + C_{dsc}}{(2C_{si}) \| C_{ox}}\right)$$

SCE and DIBL:

$$\Theta_{SCE} = -\frac{0.5}{\cosh\left(DVT1_i \cdot \frac{L_{eff}}{\lambda}\right) - 1}$$

$$\Delta V_{th,SCE} = \Theta_{SCE} \cdot DVT0_i \cdot (V_{bi} - \psi_{st})$$

$$\Theta_{DIBL} = -\frac{0.5}{\cosh\left(DSUB_i \cdot \frac{L_{eff}}{\lambda}\right) - 1}$$

$$\Delta V_{th,DIBL} = \Theta_{DIBL} \cdot \left[ETA0_i \cdot (V_{dsx} + ETA1\sqrt{V_{dsx}+0.01}) + DVTP0 \cdot \Theta_{DITS} \cdot (V_{dsx}+0.01)^{DVTP1}\right]$$

$$\Delta V_{th,RSCE} = K1RSCE_i \cdot \left[\sqrt{1 + \frac{LPE0_i}{L_{eff}}} - 1\right] \cdot \psi_{st}$$

$$\Delta V_{th,all} = \Delta V_{th,SCE} + \Delta V_{th,DIBL} + \Delta V_{th,RSCE} + \Delta V_{th,temp}$$

$$V_{gsfb} = V_{gs} - \Delta\phi - \Delta V_{th,all} - DVTSHIFT$$

### Surface Potential Calculation (3.423-3.468)

QM Vth correction (GEOMOD!=3):

$$E_0 = \frac{\hbar^2 \pi^2}{2m_x \cdot TFIN^2}, \quad E_0' = \frac{\hbar^2 \pi^2}{2m_x' \cdot TFIN^2}$$

$$\gamma = 1 + \exp\left(\frac{E_0 - E_1}{kT}\right) + \frac{g'm_d'}{gm_d}\exp\left(\frac{E_0 - E_0'}{kT}\right) + \exp\left(\frac{E_0 - E_1'}{kT}\right)$$

$$\Delta V_{t,QM} = QMFACTOR_i \cdot \left[\frac{E_0}{q} - \frac{kT}{q}\ln\left(\frac{g \cdot m_d}{N_c \cdot TFIN} \cdot \frac{kT}{\pi\hbar^2} \cdot \gamma\right)\right]$$

Source-side surface potential via Householder cubic iteration:

$$T_2 = \frac{V_{gsbeff} - v_{ch}}{nV_{tm}}$$

$$F_0 = -T_2 + T_1$$

Initial guess from exponential approximation, then two Householder iterations:

$$e_0 = F_0 - q_m + \ln(-q_m) + \ln(T_5) + QMFACTOR \cdot (-(q_m+q_{dep}))^{2/3}$$

$$e_1 = -1 + \frac{1}{q_m} + \left(\frac{1}{T_8-T_4-1}\right) \cdot r_c - \frac{2}{3}QMFACTOR \cdot (-(q_m+q_{dep}))^{-1/3}$$

$$q_m = q_m - \frac{e_0}{e_1}\left(1 + \frac{e_2 \cdot e_2}{2 \cdot e_1^2}\right)$$

Source-side inversion charge:

$$q_{is} = -q_m \cdot nV_{tm}$$

$$\psi_s = V_{gsfbeff} - q_{is}$$

### Drain Saturation Voltage (3.473-3.487)

$$E_{sat} = \frac{2 \cdot VSAT(T)}{\mu_0(T)/D_{mobs}}$$

If $R_{ds,s} = 0$:

$$V_{dsat} = \frac{E_{sat}L \cdot KSATIV_i \cdot (V_{gsfbeff} - \psi_s + 2kT/q)}{E_{sat}L + KSATIV_i \cdot (V_{gsfbeff} - \psi_s + 2kT/q)}$$

Else (with series resistance):

$$V_{dsat} = \frac{T_b - \sqrt{T_b^2 - 2T_a T_c}}{T_a}$$

where $T_a = 2 \cdot W_{eff0} \cdot VSAT(T) \cdot C_{ox} \cdot R_{ds,s}$.

Effective Vds:

$$V_{dseff} = \frac{V_{ds}}{\left(1 + \left(\frac{V_{ds}}{V_{dsat}}\right)^{MEXP(T)}\right)^{1/MEXP(T)}}$$

### Mobility Degradation (3.518-3.524)

$$E_{effa} = 10^{-8} \cdot \frac{q_{ba} + \eta \cdot q_{ia2}}{\epsilon_{ratio} \cdot EOT}$$

BULKMOD=0:

$$D_{mob} = 1 + UA(T) \cdot (E_{effa})^{EU} + \frac{1}{2} \cdot \frac{UD(T)}{1 + \frac{q_{ia2}}{1\times10^{-2}/C_{ox}}}^{UCS(T)}$$

BULKMOD=1 adds $UC(T) \cdot V_{eseff}$ to the UA term.

Hot-carrier degradation:

$$u_{0multv} = U0MULT \cdot (1 - MUHC0 \cdot \exp(-MUHC1 \cdot V_{dseff}))$$

$$D_{mob} = D_{mob} / u_{0multv}$$

### Lateral Non-Uniform Doping (3.525)

$$M_{nud} = \exp\left(-\frac{K0(T)}{\max(0, K0SI(T) + K0SISAT(T) \cdot \Delta q_i^2) \cdot q_{ia} + 2nkT/q}\right)$$

### Output Conductance (3.558-3.565)

Channel length modulation:

$$M_{clm} = 1 + \frac{1}{C_{clm}} \ln\left(1 + \frac{V_{ds} - V_{dseff}}{V_{dsat} + E_{sat}L} \cdot C_{clm}\right)$$

DIBL on Rout:

$$\theta_{rout} = \frac{0.5 \cdot PDIBL1_a}{\cosh(DROUT_i \cdot L_{eff}/\lambda) - 1} + PDIBL2_i$$

$$VA_{DIBL} = \frac{V_{dsat}}{theta_{rout}} \cdot \left(1 - \frac{T_1 + 2kT/q}{V_{dsat} + T_1 + 2kT/q}\right) \cdot PVAG_{factor}$$

$$M_{oc} = 1 + \frac{V_{ds} - V_{dseff}}{VA_{DIBL}} \cdot M_{clm}$$

### Velocity Saturation (3.566-3.571)

$$E_{sat1} = \frac{2 \cdot VSAT1_a \cdot D_{mob}}{\mu_0(T)}$$

$$D_{vsat} = \frac{1 + \left(\delta_{vsat} + \frac{\Delta q_i}{E_{sat1} L_{eff}}\right)^{PSAT(L)}}{1 + (\delta_{vsat})^{PSAT(L)}} + \frac{1}{2} \cdot PTWG_a \cdot q_{ia} \cdot \Delta q_i^2$$

Non-saturation:

$$N_{sat} = \frac{1 + T_0}{2}, \quad D_{vsat} = D_{vsat} \cdot N_{sat}$$

### Drain Current (3.572-3.576)

$$\eta_{iv} = \frac{q_0}{q_0 + q_{ia}}$$

$$T_2 = (2 - \eta_{iv}) \cdot \frac{nkT}{q}$$

$$\frac{ids_0}{\Delta q_i} = T_1 + T_2$$

$$I_{ds} = IDS0MULT \cdot \mu_0(T) \cdot C_{ox} \cdot \frac{W_{eff}}{L_{eff}} \cdot ids_0 \cdot \frac{M_{oc} \cdot M_{ob} \cdot M_{nud}}{D_{mob} \cdot D_r \cdot D_{vsat}} \times NF_{total}$$

### Intrinsic Capacitance (3.589-3.622)

Terminal charges:

$$T_{11} = \frac{(2 \cdot q_{ia} + nV_{tm})}{D_{vsatCV}}$$

$$q_g = q_{ia} + \frac{\Delta q_i^2}{6 \cdot T_{11}}$$

$$q_d = 0.5 \cdot \left(q_{ia} - \frac{\Delta q_i}{6.0} \cdot \left(1 - \frac{\Delta q_i}{T_{11}} \cdot \left(1 + \frac{\Delta q_i}{5 \cdot T_{11}}\right)\right)\right)$$

CLM correction:

$$q_g = \frac{q_g}{M_{clm,CV}} + (M_{clm,CV} - 1) \cdot q_{id}$$

$$q_s = -q_g - q_d$$

Scaling to terminal charges:

$$Q_{g,intrinsic} = NF_{total} \cdot C_{ox,eff} \cdot W_{eff,CV} \cdot L_{eff,CV} \cdot q_g$$

### Overlap Capacitance (3.673-3.677)

$$\frac{Q_{gs,ov}}{NF_{total} \cdot W_{eff,CV}} = CGSO \cdot V_{gs} + CGSL \cdot \left[V_{gs} - V_{fbsd} - V_{gs,overlap} - \frac{CKAPPAS}{2}\left(\sqrt{1 - \frac{4V_{gs,overlap}}{CKAPPAS}} - 1\right)\right]$$

where:

$$V_{gs,overlap} = \frac{1}{2}\left[V_{gs} - V_{fbsd} + \delta_1 - \sqrt{(V_{gs}-V_{fbsd}+\delta_1)^2 + 4\delta_1}\right], \quad \delta_1 = 0.02\text{V}$$

### GIDL/GISL Current (3.735-3.738)

$$T_0 = AGIDL_i \cdot W_{eff0} \cdot \left(\frac{V_{ds} - V_{gs} - EGIDL_i + V_{fbsd}}{\epsilon_{ratio} \cdot EOT}\right)^{PGIDL_i} \times \exp\left(-\frac{\epsilon_{ratio} \cdot EOT \cdot BGIDL(T)}{V_{ds} - V_{gs} - EGIDL_i + V_{fbsd}}\right) \times NF_{total}$$

$$I_{gidl} = T_0 \cdot \frac{V_{de}^3}{CGIDL_i + V_{de}^3} \quad (\text{BULKMOD}=1)$$

### Impact Ionization (3.730-3.734)

IIMOD=1:

$$I_{ii} = \frac{ALPHA0(T) + ALPHA1(T) \cdot L_{eff}}{L_{eff}} \cdot (V_{ds} - V_{dseff}) \cdot \exp\left(\frac{-BETA0(T)}{V_{ds} - V_{dseff}}\right) \cdot I_{ds}$$

IIMOD=2:

$$I_{ii} = \frac{ALPHAII0(T) + ALPHAII1(T) \cdot L_{eff}}{L_{eff}} \cdot I_{ds} \cdot \exp\left(\frac{V_{diff}}{BETAII2_i + BETAII1_i V_{diff} + BETAII0_i V_{diff}^2}\right)$$

### Gate Tunneling Current (3.752-3.781)

$$T_{ox,ratio} = \frac{1}{TOXG^2} \cdot \left(\frac{TOXREF}{TOXG}\right)^{NTOX_i}$$

Gate to body (inversion):

$$I_{gbinv} = IGB0MULT \cdot W_{eff0} \cdot L_{eff} \cdot A \cdot T_{ox,ratio} \cdot V_{ge} \cdot V_{aux,igbinv} \cdot Ig_{temp} \cdot NF_{total}$$
$$\times \exp(-B \cdot TOXG \cdot (AIGBINV(T) - BIGBINV_i \cdot T_1)(1 + CIGBINV_i \cdot T_1))$$

Gate to channel:

$$I_{gc0} = IGC0MULT \cdot W_{eff0} \cdot L_{eff} \cdot A \cdot T_{ox,ratio} \cdot Ig_{temp} \cdot NF_{total} \cdot T_0$$
$$\times \exp(-B \cdot TOXG \cdot (AIGC(T) - BIGC_i \cdot T_1)(1 + CIGC_i \cdot T_1))$$

Partition between source and drain via $PIGCD_i$.

### Self-Heating (3.860-3.864)

$$\frac{1}{R_{th}} = G_{th} = \frac{WTH0 \cdot NF^{BSHEXP} + ASH \cdot FPITCH \cdot NF_{total}^{ASHEXP}}{RTH0}$$

$$C_{th} = CTH0 \cdot (WTH0 \cdot NF^{BSHEXP} + ASH \cdot FPITCH \cdot NF_{total}^{ASHEXP})$$

### Noise Models (3.865-3.895)

Flicker noise (FNMOD=0):

$$S_{si} = \frac{kT \cdot q^2 \mu_{eff} \cdot I_{ds}}{C_{oxe}^2 L_{eff,noi}^2 f^{EF} \cdot 10^{10}} \cdot FN_1 + \frac{kT \cdot I_{ds}^2 \cdot \Delta L_{clm}}{W_{eff} \cdot NF_{total} \cdot L_{eff,noi}^2 f^{EF} \cdot 10^{10}} \cdot FN_2$$

Thermal noise (TNOIMOD=0):

$$\overline{i_d^2} = 4kT \cdot NTNOI \cdot \frac{\Delta f}{L_{eff}^2/(R_{ds} + \mu_{eff} Q_{inv})} \cdot \mu_{eff} Q_{inv}$$

Thermal noise (TNOIMOD=1):

$$S_{id} = 4kT\gamma g_{d0}$$

$$\gamma = \frac{M_{oc}}{D_{vsat}} \cdot \left[T_8 \cdot \frac{1+\eta}{2} + T_1 \cdot \frac{(1-\eta)^2}{6(1+\eta)}\right]$$

Gate noise:

$$S_{ig} = 4kT \cdot \delta \cdot \frac{\omega^2(NF_{total} \cdot C_{ox} \cdot W_{eff} \cdot L_{eff})^2}{g_{d0}}$$

Shot noise:

$$\overline{i_{gs}^2} = 2q(I_{gcs} + I_{gs}), \quad \overline{i_{gd}^2} = 2q(I_{gcd} + I_{gd})$$

Resistor noise:

$$\overline{i_{RS}^2}/\Delta f = 4kT/R_{source}, \quad \overline{i_{RD}^2}/\Delta f = 4kT/R_{drain}$$

### Junction Current (3.789-3.827)

Source-side bias-independent:

$$I_{sbs} = ASEJ \cdot J_{ss}(T) + PSEJ \cdot J_{sws}(T) + TFIN \cdot NF_{total} \cdot J_{swgs}(T)$$

Bias-dependent (normal operation, $V_{jsmRev} \le V_{es} \le V_{jsmFwd}$):

$$I_{es} = I_{sbs} \cdot \left[\exp\left(\frac{V_{es}}{NV_{tms}}\right) + XExpBVS - 1 - XJBVS \cdot \exp\left(-\frac{BVS + V_{es}}{NV_{tms}}\right)\right]$$

### Junction Capacitance (3.828-3.850)

Source side ($V_{es} > 0$):

$$Q_{es1} = C_{zbs} \cdot PBS(T) \cdot \frac{1 - \left(1 - \frac{V_{es}}{PBS(T)}\right)^{1-MJS}}{1 - MJS}$$

Source side ($V_{es} \le 0$):

$$Q_{es1} = V_{es} \cdot C_{zbs} + V_{es}^2 \cdot \frac{MJS \cdot C_{zbs}}{2 \cdot PBS(T)}$$

### Threshold Voltage (3.896-3.900)

At threshold, source-side charge:

$$Q_{is} = C_{ox} \cdot \frac{kT}{q}$$

Long-channel threshold:

$$V_{th0} = V_{fb} + \frac{kT}{q} + \phi_B + \Delta V_{t,QM} + \frac{kT}{q}\ln\left(\frac{C_{ox} \cdot kT/q \cdot (C_{ox} \cdot kT/q + 2Q_{bulk} + 5C_{si} \cdot kT/q)}{2qn_i\epsilon_{sub} \cdot kT/q}\right) + q_{bs}$$

$$V_{th} = V_{th0} + \Delta V_{th,all}$$

### Generation-Recombination Current (3.788)

$$I_{ds,gen} = HFIN \cdot TFIN \cdot (L_{eff} - LINTIGEN) \cdot (AIGEN_i \cdot V_{ds} + BIGEN_i \cdot V_{ds}^3) \cdot \exp\left(\frac{qE_g}{NTGEN_i \cdot kT} \cdot \left(\frac{T}{TNOM} - 1\right)\right) \times NF_{total}$$

### NQS Models (3.782-3.787)

NQSMOD=1 (gate resistance):

$$\frac{1}{R_{ii}} = NF \cdot NFIN \cdot \left(XRCRG1_i \cdot IdovVds + XRCRG2 \cdot \frac{\mu_{eff} C_{oxe} W_{eff} kT}{qL_{eff}}\right)$$

NQSMOD=2 (charge deficit):

$$\frac{1}{\tau} = \frac{1}{R_{ii} \cdot C_{ox} \cdot W_{eff} \cdot L_{eff}}$$

Partition ratio: $X_{d,part} = -q_d/q_g$

---

## Length Scaling Auxiliary Parameters (for binning)

All "A-" and "B-" prefixed parameters (e.g., AMEXP, BMEXP, AUA, BUA, ARDSW, BRDSW, AVSAT, BVSAT, AVSAT1, BVSAT1, APTWG, BPTWG, APSAT, BPSAT, APCLM, BPCLM, AUD, BUD, ARSW, BRSW, ARDW, BRDW, AVSATCV, BVSATCV, AVSAT1, BVSAT1, AMEXPR, BMEXPR, APTWG, BPTWG) have default value 0 and serve as coefficients in the exponential length-scaling equations documented in Section 3.1.7. All "L-", "N-", "P-", "W-", "P2-" prefixed binning parameters have default value 0.
