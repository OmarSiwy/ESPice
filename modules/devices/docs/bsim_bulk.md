# BSIM-BULK 107.2.1 -- Parameter & Equation Reference

> Bulk planar MOSFET (UC Berkeley, February 2025)

## Model Topology

BSIM-BULK is a body-referenced, charge-based compact model for bulk planar MOSFETs. The device has four external terminals: Gate (G), Drain (D), Source (S), and Body/Bulk (B). Internal nodes include optional gate resistance nodes (gNodePrime, gNodeMid), optional body resistance network nodes (bNodePrime, dbNode, sbNode), optional self-heating thermal node (T), and optional drift region nodes (di, di1, si, si1) for high-voltage operation. The equivalent circuit includes intrinsic MOSFET, parasitic source/drain series resistances, junction diodes (source-body and drain-body), substrate resistance network, gate resistance, and overlap/fringe capacitances.

---

## Parameters

### Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| L | m | 10u | -- | Designed gate length |
| W | m | 10u | -- | Designed gate width (per finger) |
| NF | -- | 1 | [1, --] | Number of fingers |
| NRS | -- | 1 | -- | Number of source diffusion squares |
| NRD | -- | 1 | -- | Number of drain diffusion squares |
| VFBSDOFF | V | 0 | -- | Source-drain flat band offset |
| MINZ | -- | 0 | [0, 1] | Minimize either no. of drain or source ends |
| RGATEMOD | -- | 0 | [0, 2] | Gate resistance model selector |
| RBODYMOD | -- | 0 | [0, 2] | Substrate resistance network model selector |
| GEOMOD | -- | 0 | [0, 10] | Geometry-dependent parasitic model selector |
| RGEOMOD | -- | 0 | [0, 8] | Bias independent parasitic resistance model selector |
| RBPB | Ohm | 50 | [1e-3, --] | Resistance between bNodePrime and bNode |
| RBPD | Ohm | 50 | [1e-3, --] | Resistance between bNodePrime and dbNode |
| RBPS | Ohm | 50 | [1e-3, --] | Resistance between bNodePrime and sbNode |
| RBDB | Ohm | 50 | [1e-3, --] | Resistance between dbNode and bNode |
| RBSB | Ohm | 50 | [1e-3, --] | Resistance between sbNode and bNode |
| RDB | Ohm | 50 | [1e-3, --] | Resistance between ddbulk and d node (RBODYHVMOD=1) |
| SA | m | 0 | [0, --] | Distance between OD edge to Poly from one side |
| SB | m | 0 | [0, --] | Distance between OD edge to Poly from other side |
| SD | m | 0 | [0, --] | Distance between neighboring fingers |
| SCA | -- | 0 | [0, --] | Integral of first distribution function for scattered well dopant |
| SCB | -- | 0 | [0, --] | Integral of second distribution function for scattered well dopant |
| SCC | -- | 0 | [0, --] | Integral of third distribution function for scattered well dopant |
| SC | m | 0 | [0, --] | Distance to a single well edge |
| AS | m^2 | 0 | [0, --] | Source to substrate junction area |
| AD | m^2 | 0 | [0, --] | Drain to substrate junction area |
| PS | m | 0 | [0, --] | Source to substrate junction perimeter |
| PD | m | 0 | [0, --] | Drain to substrate junction perimeter |

### Model Controllers and Process Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TYPE | -- | 1 | [-1, 1] | NMOS=1, PMOS=-1 |
| CVMOD | -- | 0 | [0, 1] | IV-CV: Consistent=0, Different=1 |
| GEOMOD | -- | 0 | [0, 10] | S/D connection geometry selector |
| RGEOMOD | -- | 0 | [0, 8] | Bias independent parasitic resistance model selector |
| RGATEMOD | -- | 0 | [0, 2] | Gate resistance model selector |
| ASYMMOD | -- | 0 | [0, 1] | Asymmetry model ON/OFF |
| MOBSCALE | -- | 0 | [0, 1] | Mobility model selector (0 or 1) |
| RBODYMOD | -- | 0 | [0, 2] | Substrate resistance network model selector |
| RBODYHVMOD | -- | 0 | [0, 1] | HV substrate resistance network model selector |
| RDSMOD | -- | 0 | [0, 2] | 0=Bias dependent internal/independent external, 1=External RDS, 2=Internal RDS |
| COVMOD | -- | 0 | [0, 1] | Bias-independent overlap cap=0, Bias-dependent=1 |
| GIDLMOD | -- | 0 | [0, 1] | Turn off GIDL model=0, Turn on=1 |
| SHMOD | -- | 0 | [0, 1] | Turn off Self Heating=0, Turn on=1 |
| PERMOD | -- | 1 | [0, 1] | PS/PD includes gate-edge perimeter (1) or not (0) |
| GADRIFT | -- | 0 | [0, 1] | High Vg/Vd tuning for HV devices |
| TNOIMOD | -- | 0 | [0, 1] | Thermal noise model selector |
| FNOIMOD | -- | 0 | [0, 1] | Flicker noise model selector |
| BINUNIT | -- | 1 | [0, 1] | Binning unit selector |
| IGCMOD | -- | 0 | [0, 1] | Gate-to-channel tunneling current selector |
| IGBMOD | -- | 0 | [0, 1] | Gate-to-substrate tunneling current selector |
| XL | m | 0 | -- | L offset for channel length due to mask/etch effect |
| XW | m | 0 | -- | W offset for channel width due to mask/etch effect |
| LINT (b) | m | 0 | -- | Length reduction parameter |
| WINT (b) | m | 0 | -- | Width reduction parameter |
| DLC (b) | m | 0 | -- | Length reduction parameter for CV |
| DWC (b) | m | 0 | -- | Width reduction parameter for CV |
| TOXE | m | 3.0e-9 | -- | SiO2 equivalent gate dielectric thickness |
| TOXP | m | TOXE | -- | Physical dielectric thickness |
| DTOX | m | 0.0 | -- | TOXE - TOXP difference |
| NDEP (b) | m^-3 | 1e24 | -- | Channel doping concentration. Scaling: NDEPL1, NDEPLEXP1, NDEPL2, NDEPLEXP2, NDEPW, NDEPWEXP, NDEPWL, NDEPWLEXP |
| NSD (b) | m^-3 | 1e26 | [2e25, 1e27] | S/D doping concentration |
| EASUB | eV | 4.05 | -- | Electron affinity of substrate |
| NGATE (b) | m^-3 | 5e25 | -- | Poly gate doping; set NGATE=0 for metal gates |
| VFB (b) | V | -0.5 | -- | Flat band voltage |
| EPSROX | -- | 3.9 | [1, --] | Relative dielectric constant of gate insulator |
| EPSRSUB | -- | 11.9 | [1, --] | Relative dielectric constant of channel material |
| NI0SUB | m^-3 | 1.1e16 | -- | Intrinsic carrier concentration at 300.15K |
| XJ (b) | m | 1.5e-7 | -- | S/D junction depth |
| DMCG | m | 0 | [0, --] | Distance of mid-contact to gate edge |
| DMCI | m | DMCG | [0, --] | Distance of mid-contact to isolation |
| DMDG | m | 0 | [0, --] | Distance of mid-diffusion to gate edge |
| DMCGT | m | 0 | [0, --] | Distance of mid-contact to gate edge in test |

### Basic Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| LLONG | m | 10u | -- | Length of extracted long channel device |
| WWIDE | m | 10u | -- | Width of extracted wide channel device |
| ASYMP | -- | 0.6 | -- | Tuning parameter for asymmetry mode |
| CIT (b) | F/m^2 | 0 | -- | Interface trap capacitance |
| NFACTOR (b) | -- | 0 | -- | Subthreshold swing factor. Scaling: NFACTORL, NFACTORLEXP, NFACTORW, NFACTORWEXP, NFACTORWL |
| CDSCD (b) | F/m^2/V | 1e-9 | -- | Drain-bias sensitivity of subthreshold swing. Scaling: CDSCDL, CDSCDLEXP |
| CDSCB (b) | F/m^2/V | 1e-9 | -- | Body-bias sensitivity of subthreshold swing. Scaling: CDSCBL, CDSCBLEXP |
| CDSCBR (b) | F/m^2/V | CDSCD | [0, --] | Reverse-mode drain-bias sensitivity. Scaling: CDSCDLR |
| CDSCDR (b) | F/m^2/V | 1e-9 | -- | Drain-bias sensitivity of subthreshold swing (reverse). Scaling: CDSCDR, LCDSCDR |
| DVTP0 (b) | m | 1e-10 | -- | Drain-induced Vth shift coefficient |
| DVTP1 (b) | 1/V | 0 | -- | Drain-induced Vth shift coefficient |
| DVTP2 (b) | m*V | 0 | -- | Drain-induced Vth shift coefficient |
| DVTP3 (b) | -- | 0 | -- | Drain-induced Vth shift coefficient |
| DVTP4 (b) | 1/V | 0 | -- | Drain-induced Vth shift coefficient |
| DVTP5 (b) | V | 0 | -- | Drain-induced Vth shift coefficient |
| PHIN (b) | V | 0.045 | -- | Vertical nonuniform doping effect on surface potential |
| K2 (b) | V | 0 | -- | Vth shift due to nonuniform vertical doping. Scaling: K2L, K2LEXP, K2W, K2WEXP |
| K1 (b) | V^0.5 | 0 | -- | Vth shift due to nonuniform vertical doping. Scaling: K1L, K1LEXP, K1W, K1WL, K1WEXP, K1WLEXP |
| ETA0 (b) | -- | 0.08 | -- | DIBL coefficient |
| ETA0R (b) | -- | 0.08 | -- | DIBL coefficient (reverse) |
| DSUB (b) | -- | 0.375 | (0, --] | DIBL exponent coefficient |
| ETAB (b) | 1/V | -0.07 | -- | Body bias sensitivity to DIBL effect. Scaling: ETABEXP |
| U0 (b) | m^2/V/s | 67e-3 | -- | Low field mobility. Scaling: U0L, U0LEXP |
| ETAMOB | -- | 1.0 | -- | Effective field parameter (1/2 NMOS, 1/3 PMOS when =1) |
| UA (b) | (m/V)^EU | 0.001 | (0, --] | Phonon/surface roughness scattering. Scaling: UAL, UALEXP, UAW, UAWEXP, UAWL |
| EU (b) | -- | 1.5 | (0, --] | Phonon/surface roughness scattering exponent. Scaling: EUL, EULEXP, EUW, EUWEXP, EUWL |
| UD (b) | -- | 0.001 | (0, --] | Coulombic scattering parameter. Scaling: UDL, UDLEXP |
| UCS (b) | -- | 2.0 | [1, 2] | Coulombic scattering exponent |
| UC (b) | (m/V)^EU/V | 0.0 | -- | Body-bias sensitivity on mobility. Scaling: UCL, UCLEXP |
| VSAT (b) | m/s | 1e6 | -- | Saturation velocity. Scaling: VSATL, VSATLEXP, VSATW, VSATWEXP |
| VSATR (b) | m/s | 1e6 | -- | Saturation velocity (reverse). Scaling: LVSATR, WVSATR, PVSATR |
| DELTA (b) | -- | 0.125 | (0, 0.5] | Smoothing factor Vds to Vdsat. Scaling: DELTAL, DELTALEXP |
| AVDSX | -- | 0.16 | (0, --] | Smoothing factor for Vdsx calculation |
| PSAT (b) | -- | 1.0 | [0.25, 1.0] | Velocity saturation exponent. Scaling: PSATL, PSATLEXP |
| PTWG (b) | -- | 0 | -- | Correction factor for velocity saturation. Scaling: PTWGL, PTWGLEXP |
| PTWGR (b) | -- | PTWG | -- | Reverse mode velocity saturation correction. Scaling: PTWGLR, PTWGLEXPR |
| A1 (b) | V^-2 | 0.0 | -- | Non-saturation effect parameter (strong inversion) |
| A2 (b) | V^-1 | 0.0 | -- | Non-saturation effect parameter (moderate inversion) |
| PSATX | -- | 1 | [0.25, 4] | Fine tuning of PTWG effect |
| PSATB (b) | 1/V | 0 | -- | Velocity saturation exponent for non-zero Vbs |
| PCLM (b) | -- | 0.00 | -- | Channel length modulation parameter. Scaling: PCLML, PCLMLEXP |
| PCLMG | V | 0 | -- | Gate bias dependent CLM parameter |
| PSCBE1 (b) | V/m | 4.24e8 | -- | Substrate current body-effect coefficient |
| PSCBE2 (b) | m/V | 1.0e-8 | -- | Substrate current body-effect coefficient |
| PDITS (b) | 1/V | 0 | -- | Drain-induced Vth shift |
| PDITSL | 1/m | 0 | -- | L dependence of drain-induced Vth shift |
| PDITSD (b) | 1/V | 0 | -- | VDS dependence of drain-induced Vth shift |
| RSWMIN (b) | Ohm*um^WR | 0.0 | [0, --] | Source extension resistance per unit width at high Vgs |
| RSW (b) | Ohm*um^WR | 10 | [0, --] | Zero bias source extension resistance. Scaling: RSWL, RSWLEXP |
| RDWMIN (b) | Ohm*um^WR | 0.0 | [0, --] | Drain extension resistance per unit width at high Vgs |
| RDW (b) | Ohm*um^WR | 10 | [0, --] | Zero bias drain extension resistance. Scaling: RDWL, RDWLEXP |
| RDSWMIN (b) | Ohm*um^WR | 0.0 | [0, --] | LDD resistance per unit width at high Vgs (RDSMOD=0) |
| RDSW (b) | Ohm*um^WR | 10 | [0, --] | Zero bias LDD resistance (RDSMOD=0). Scaling: RDSWL, RDSWLEXP |
| PRWG (b) | V^-1 | 1 | [0, --] | Gate bias dependence of S/D extension resistance |
| PRWB (b) | V^-1 | 0 | [0, --] | Body bias dependence of S/D extension resistance. Scaling: PRWBL, PRWBLEXP |
| WR (b) | -- | 1.0 | -- | W dependence parameter of S/D extension resistance |
| RSH | Ohm | 0 | [0, --] | Sheet resistance |
| PDIBLC (b) | -- | 2e-4 | [0, --] | DIBL effect on Rout. Scaling: PDIBLCL, PDIBLCLEXP |
| PDIBLCB (b) | 1/V | 0 | [0, --] | Body-bias sensitivity on DIBL |
| PVAG (b) | -- | 1 | -- | Vgs dependence on early voltage |
| FPROUT (b) | V^0.5/m | 0 | [0, --] | gds degradation due to pocket implant. Scaling: FPROUTL, FPROUTLEXP |
| ABULK | -- | 1 | [1, 2] | Tuning Cgg in strong inversion |
| A0 | -- | 0 | -- | Gate bias dependent parameter for ABULK |
| AGS | -- | 0 | -- | Gate bias dependent parameter for ABULK |
| KETA | -- | 0 | -- | Body bias dependent parameter for ABULK |
| AGS1 | -- | 1 | -- | Parameter for non-linearity of source charge |
| AGIDL (b) | V/m | 0 | -- | Pre-exponential coefficient for GIDL. Scaling: AGIDLL, AGIDLW |
| BGIDL (b) | V/m | 2.3e-9 | -- | Exponential coefficient for GIDL |
| CGIDL (b) | V/m | 0.5 | -- | Body-bias coefficient for GIDL |
| EGIDL (b) | V | 0.8 | -- | Band bending parameter for GIDL |
| AGISL (b) | V/m | 0 | -- | Pre-exponential coefficient for GISL. Scaling: AGISLL, AGISLW |
| BGISL (b) | V/m | 2.3e-9 | -- | Exponential coefficient for GISL |
| CGISL (b) | V/m | 0.5 | -- | Body-bias coefficient for GISL |
| EGISL (b) | V | 0.8 | -- | Band bending parameter for GISL |
| ALPHA0 (b) | m/V | 0.0 | -- | Impact ionization coefficient. Scaling: ALPHA0L, ALPHA0LEXP, ALPHA0W, ALPHA0WEXP |
| ALPHA0R (b) | m/V | ALPHA0 | -- | Reverse mode impact ionization coefficient |
| BETA0 (b) | 1/V | 0.0 | -- | Vds dependent impact ionization coefficient. Scaling: BETA0L, BETA0LEXP, BETA0W, BETA0WEXP |
| BETA0R (b) | 1/V | BETA0 | -- | Reverse mode impact ionization Vds coefficient |
| AIGC (b) | (Fs^2/g)^0.5/m | 1.36e-2 (NMOS), 9.8e-3 (PMOS) | -- | Parameter for Igcs and Igcd. Scaling: AIGCL, AIGCW |
| BIGC (b) | (Fs^2/g)^0.5/m/V | 1.71e-3 (NMOS), 7.59e-4 (PMOS) | -- | Parameter for Igcs and Igcd |
| CIGC (b) | 1/V | 0.075 (NMOS), 0.03 (PMOS) | -- | Parameter for Igcs and Igcd |
| AIGS (b) | (Fs^2/g)^0.5/m | 1.36e-2 (NMOS), 9.8e-3 (PMOS) | -- | Parameter for Igs. Scaling: AIGSL, AIGSW |
| BIGS (b) | (Fs^2/g)^0.5/m/V | 1.71e-3 (NMOS), 7.59e-4 (PMOS) | -- | Parameter for Igs |
| CIGS (b) | 1/V | 0.075 (NMOS), 0.03 (PMOS) | -- | Parameter for Igs |
| DLCIG (b) | m | LINT | -- | S/D overlap length for Igs |
| AIGD (b) | (Fs^2/g)^0.5/m | 1.36e-2 (NMOS), 9.8e-3 (PMOS) | -- | Parameter for Igd. Scaling: AIGDL, AIGDW |
| BIGD (b) | (Fs^2/g)^0.5/m/V | 1.71e-3 (NMOS), 7.59e-4 (PMOS) | -- | Parameter for Igd |
| CIGD (b) | 1/V | 0.075 (NMOS), 0.03 (PMOS) | -- | Parameter for Igd |
| DLCIGD (b) | m | DLCIG | -- | S/D overlap length for Igd |
| POXEDGE (b) | -- | 1.0 | -- | Factor for gate oxide thickness in S/D overlap regions |
| PIGCD (b) | -- | 1.0 | -- | Vds dependence of Igcs and Igcd. Scaling: PIGCDL, PIGCDLEXP |
| NTOX (b) | -- | 1.0 | -- | Exponent for gate oxide ratio |
| TOXREF | m | 3.0e-9 | -- | Nominal gate oxide thickness for gate tunneling model |
| VFBSDOFF (b) | V | 0.0 | -- | Flatband voltage offset parameter |
| NDEPCV (b) | m^-3 | NDEP | -- | Channel doping for CV. Scaling: NDEPCVL1, NDEPCVLEXP1, NDEPCVL2, NDEPCVLEXP2, NDEPCVW, NDEPCVWEXP, NDEPCVWL, NDEPCVWLEXP |
| VFBCV (b) | V | VFB | -- | Flat band voltage for CV. Scaling: VFBCVL, VFBCVLEXP, VFBCVW, VFBCVWEXP, VFBCVWL, VFBCVWLEXP |
| VSATCV (b) | m/s | VSAT | -- | Saturation velocity for CV. Scaling: VSATCVL, VSATCVLEXP, VSATCVW, VSATCVWEXP |
| PCLMCV (b) | -- | PCLM | -- | CLM parameter for CV. Scaling: PCLMCVL, PCLMCVLEXP |
| A0CV | -- | A0 | -- | ABULK parameter for CV |
| AGSCV | -- | AGS | -- | ABULK parameter for CV |
| KETACV | -- | KETA | -- | ABULK body bias parameter for CV |
| DELVFBACC | V | 0 | -- | VFB shift in accumulation (CVMOD=1 only) |
| CF (b) | F/m | 0 | [0, --] | Outer fringe capacitance |
| CFRCOEFF (b) | -- | 1 | [1, --] | Outer fringe cap coefficient |
| CGSO | F/m | calculated | [0, --] | Non-LDD source-gate overlap capacitance per unit width |
| CGDO | F/m | calculated | [0, --] | Non-LDD drain-gate overlap capacitance per unit width |
| CGSL (b) | F/m | 0 | [0, --] | Overlap cap between gate and lightly-doped source |
| CGDL (b) | F/m | 0 | [0, --] | Overlap cap between gate and lightly-doped drain |
| CKAPPAS (b) | V | 0.6 | [0.02, --] | Bias-dependent overlap cap coefficient (source side) |
| CKAPPAS1 | -- | 1e6 | -- | Bias-dependent overlap cap coefficient (source side) |
| CKAPPAS2 | -- | 1 | -- | Bias-dependent overlap cap coefficient (source side) |
| CKAPPAD (b) | V | 0.6 | [0.02, --] | Bias-dependent overlap cap coefficient (drain side) |
| CKAPPAD1 | -- | 1e6 | -- | Bias-dependent overlap cap coefficient (drain side) |
| CKAPPAD2 | -- | 1 | -- | Bias-dependent overlap cap coefficient (drain side) |
| CGBO | F/m | 0 | [0, --] | Gate-substrate overlap cap per unit length |
| ADOS | -- | 0 | [0, --] | Quantum mechanical effect prefactor in inversion |
| BDOS | -- | 1.0 | [0, --] | Charge centroid parameter (QME slope) |
| K0 (b) | -- | 0 | [0, --] | Non-saturation (MNUD) effect parameter |
| M0 (b) | -- | 1.0 | [0, --] | Offset of MNUD effect parameter |
| C0 (b) | V | 0 | -- | Lateral NUD1 voltage parameter |
| C0SI (b) | V | 1.0 | [0, --] | Correction factor for strong inversion in MNUD1 |
| C0SISAT (b) | V | 1.0 | [0, --] | Correction factor for saturation in MNUD1 |
| QM0 | -- | 1e-3 | (0, --] | Charge centroid starting point for QME |
| ETAQM | -- | 0.0 | [0, --] | Bulk charge coefficient for charge centroid |
| DLBIN | -- | 0.0 | -- | Length reduction parameter for binning |
| DWBIN | -- | 0.0 | -- | Width reduction parameter for binning |
| LMLT | -- | 1.0 | (0, --] | Length shrinking factor |
| WMLT | -- | 1.0 | (0, --] | Width shrinking factor |
| CVSLOPE | -- | 1.0 | [1.0, --] | Slope tuning on CV plot (CVMOD=1) |

### Both Model and Instance Parameters

| Parameter | Unit | Default | Description |
|-----------|------|---------|-------------|
| DTEMP | K | 0.0 | Offset of device temperature |
| MULU0 | m^2/V/s | 1.0 | Multiplication factor for low field mobility |
| DELVTO | V | 0 | Zero bias threshold voltage variation |
| IDS0MULT | -- | 1.0 | Variability in drain current |
| XGW | m | 0 | Distance from gate contact center to device edge |
| NGCON | -- | 1 | Number of gate contacts (1 or 2) |
| EDGEFET | -- | 1 | Edge FET model flag: 0=Disable, 1=Enable |
| SSLMOD | -- | 1 | Sub-surface leakage drain current: 0=Off, 1=On |

### High-Speed/RF Model Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| XRCRG1 (b) | 12.0 | Distributed channel-resistance effect parameter |
| XRCRG2 (b) | 1.0 | Excess channel diffusion resistance parameter |
| GBMIN | 1.0e-12 mho | Minimum conductance in parallel with substrate resistances |
| RBPS0 | 50 Ohm | Scaling prefactor for RBPS |
| RBPSL | 0.0 | Length scaling for RBPS |
| RBPSW | 0.0 | Width scaling for RBPS |
| RBPSNF | 0.0 | NF scaling for RBPS |
| RBPD0 | 50 Ohm | Scaling prefactor for RBPD |
| RBPDL | 0.0 | Length scaling for RBPD |
| RBPDW | 0.0 | Width scaling for RBPD |
| RBPDNF | 0.0 | NF scaling for RBPD |
| RBPBX0 | 100 Ohm | Scaling prefactor for RBPBX |
| RBPBXL | 0.0 | Length scaling for RBPBX |
| RBPBXW | 0.0 | Width scaling for RBPBX |
| RBPBXNF | 0.0 | NF scaling for RBPBX |
| RBPBY0 | 100 Ohm | Scaling prefactor for RBPBY |
| RBPBYL | 0.0 | Length scaling for RBPBY |
| RBPBYW | 0.0 | Width scaling for RBPBY |
| RBPBYNF | 0.0 | NF scaling for RBPBY |
| RBSBX0 | 100 Ohm | Scaling prefactor for RBSBX |
| RBSBY0 | 100 Ohm | Scaling prefactor for RBSBY |
| RBDBX0 | 100 Ohm | Scaling prefactor for RBDBX |
| RBDBY0 | 100 Ohm | Scaling prefactor for RBDBY |
| RBSDBXL | 0.0 | Length scaling for RBSBX and RBDBX |
| RBSDBXW | 0.0 | Width scaling for RBSBX and RBDBX |
| RBSDBXNF | 0.0 | NF scaling for RBSBX and RBDBX |
| RBSDBYL | 0.0 | Length scaling for RBSBY and RBDBY |
| RBSDBYW | 0.0 | Width scaling for RBSBY and RBDBY |
| RBSDBYNF | 0.0 | NF scaling for RBSBY and RBDBY |

### Flicker and Thermal Noise Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| NOIA | 6.25e41 (NMOS), 6.188e40 (PMOS) | Flicker noise parameter A |
| NOIB | 3.125e26 (NMOS), 1.5e25 (PMOS) | Flicker noise parameter B |
| NOIC | 8.75 | Flicker noise parameter C |
| NOIA3 | 0 | Flicker noise tuning in sub-threshold |
| MPOWER | 1.2 | Sub-threshold to strong inversion transition slope |
| QSREF | 50e-3 C/m^2 | Charge at threshold condition |
| SPFN | 2 | Smoothing parameter for FN model |
| NOIA1 | 0 | Flicker noise fitting in strong inversion |
| NOIAX | 1 | Flicker noise fitting for high VDS |
| NOIA2 | NOIA | Flicker noise parameter A for Halo model |
| LH | 10e-9 m | Length of halo |
| EM | 4.1e7 V/m | Saturation field |
| EF | 1.0 | Flicker noise frequency exponent |
| AFNS | 2.0 | Flicker noise exponent for source resistance |
| BFNS | 1.0 | Flicker noise frequency exponent for source resistance |
| KFNS | 0 | Flicker noise coefficient for source resistance |
| AFND | 2.0 | Flicker noise exponent for drain resistance |
| BFND | 1.0 | Flicker noise frequency exponent for drain resistance |
| KFND | 0 | Flicker noise coefficient for drain resistance |
| LINTNOI | 0.0 m | Length reduction parameter offset for noise |
| NTNOI | 1.0 | Noise factor for short-channel devices (TNOIMOD=0) |
| TNOIA | 1.5 | Channel-length dependence of thermal noise |
| TNOIB | 3.5 | Channel-length dependence for thermal noise partitioning |
| TNOIC | 0 | Length dependent correlation coefficient parameter |
| RNOIA | 0.577 | Thermal noise coefficient |
| RNOIB | 0.5164 | Thermal noise coefficient |
| RNOIC | 0.395 | Correlation coefficient parameter |
| RNOIK | 0.0 | Exponential coefficient for enhanced correlated thermal noise |
| TNOIK | 0.0 | Empirical parameter for Leff trend of Sid at low Ids |
| TNOIK2 | 0.1 | Empirical parameter for sensitivity of RNOIK |

### Layout-Dependent Parasitic Model Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| DWJ | DWC | Offset of S/D junction width |
| XGL | 0.0 m | Offset of gate length due to patterning |

### Asymmetric Source/Drain Junction Diode Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| IJTHSREV, IJTHDREV | 0.1 A (IJTHDREV=IJTHSREV) | Limiting current in reverse bias |
| IJTHSFWD, IJTHDFWD | 0.1 A (IJTHDFWD=IJTHSFWD) | Limiting current in forward bias |
| XJBVS, XJBVD | 1.0 (XJBVD=XJBVS) | Fitting parameter for diode breakdown |
| BVS, BVD | 10.0 V (BVD=BVS) | Breakdown voltage |
| JSS, JSD | 1.0e-4 A/m^2 (JSD=JSS) | Bottom junction reverse saturation current density |
| JSWS, JSWD | 0.0 A/m (JSWD=JSWS) | Isolation-edge sidewall reverse saturation current density |
| JSWGS, JSWGD | 0.0 A/m (JSWGD=JSWGS) | Gate-edge sidewall reverse saturation current density |
| JTSS, JTSD | 0.0 A/m (JTSD=JTSS) | Bottom trap-assisted saturation current density |
| JTSSWS, JTSSWD | 0.0 A/m^2 (JTSSWD=JTSSWS) | STI sidewall trap-assisted saturation current density |
| JTSSWGS, JTSSWGD | 0.0 A/m (JTSSWGD=JTSSWGS) | Gate-edge sidewall trap-assisted saturation current density |
| JTWEFF | 0.0 | Trap-assisted tunneling current density width dependence |
| NJS, NJD | 1.0 (NJD=NJS) | Emission coefficient of junction |
| NJTS, NJTSD | 20.0 (NJTSD=NJTS) | Non-ideality factor for JTSS/JTSD |
| NJTSSW, NJTSSWD | 20.0 (NJTSSWD=NJTSSW) | Non-ideality factor for JTSSWS/JTSSWD |
| NJTSSWG, NJTSSWGD | 20.0 (NJTSSWGD=NJTSSWG) | Non-ideality factor for JTSSWGS/JTSSWGD |
| XTSS, XTSD | 0.02 | Power dependence of JTSS/JTSD on temperature |
| XTSSWS, XTSSWD | 0.02 | Power dependence of JTSSWS/JTSSWD on temperature |
| XTSSWGS, XTSSWGD | 0.02 | Power dependence of JTSSWGS/JTSSWGD on temperature |
| VTSS, VTSD | 10 V (VTSD=VTSS) | Bottom trap-assisted voltage dependent parameter |
| VTSSWS, VTSSWD | 10 V (VTSSWD=VTSSWS) | STI sidewall trap-assisted voltage dependent parameter |
| VTSSWGS, VTSSWGD | 10 V (VTSSWGD=VTSSWGS) | Gate-edge sidewall trap-assisted voltage dependent parameter |
| TNJTS, TNJTSD | 0.0 (TNJTSD=TNJTS) | Temperature coefficient for NJTS/NJTSD |
| TNJTSSW, TNJTSSWD | 0.0 (TNJTSSWD=TNJTSSW) | Temperature coefficient for NJTSSW/NJTSSWD |
| TNJTSSWG, TNJTSSWGD | 0.0 (TNJTSSWGD=TNJTSSWG) | Temperature coefficient for NJTSSWG/NJTSSWGD |
| CJS, CJD | 5.0e-4 F/m^2 (CJD=CJS) | Bottom junction capacitance per unit area at zero bias |
| MJS, MJD | 0.5 (MJD=MJS) | Bottom junction capacitance grading coefficient |
| MJSWS, MJSWD | 0.33 (MJSWD=MJSWS) | Isolation-edge sidewall junction cap grading coefficient |
| CJSWS, CJSWD | 5.0e-10 F/m (CJSWD=CJSWS) | Isolation-edge sidewall junction cap per unit length |
| CJSWGS, CJSWGD | CJSWS (CJSWGD=CJSWS) | Gate-edge sidewall junction cap per unit length |
| MJSWGS, MJSWGD | MJSWS (MJSWGD=MJSWS) | Gate-edge sidewall junction cap grading coefficient |
| PBS | 1.0 V | Source-side bulk junction built-in potential |
| PBD | PBS | Drain-side bulk junction built-in potential |
| PBSWS, PBSWD | 1.0 V (PBSWD=PBSWS) | Isolation-edge sidewall junction built-in potential |
| PBSWGS, PBSWGD | PBSWS (PBSWGD=PBSWS) | Gate-edge sidewall junction built-in potential |

### Temperature Dependence and Self Heating Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| TNOM | 27 C | Temperature at which parameters are extracted |
| UTE (b) | -1.5 | Mobility temperature exponent |
| UCSTE (b) | -4.775e-3 | Temperature coefficient of coulombic mobility |
| TDELTA | 0.0 | Temperature coefficient for DELTA |
| TGIDL (b) | 0.0 | Temperature coefficient for GIDL/GISL |
| IIT (b) | 0.0 | Temperature coefficient for BETA0 |
| KT1 (b) | -0.11 V | Temperature coefficient for threshold voltage |
| KT1EXP | 1.0 | Temperature exponent for threshold voltage |
| KT1L (b) | 0.0 V*m | Channel length dependence of KT1 |
| KT2 (b) | 0.022 | Body-bias coefficient of Vth temperature effect |
| UA1 (b) | 1.0e-9 m/V | Temperature coefficient for UA |
| UC1 (b) | 0.056 1/K | Temperature coefficient for UC |
| UD1 (b) | 0.0 | Temperature coefficient for UD |
| EU1 (b) | 0.0 | Temperature coefficient for EU |
| AT (b) | 3.3e4 m/s | Temperature coefficient for saturation velocity |
| PTWGT | 0.0 K | Temperature coefficient for PTWG |
| PRT (b) | 0.0 | Temperature coefficient for Rdsw |
| PRTHV (b) | 0.0 | Temperature coefficient for drift resistance |
| IGT (b) | 2.5 | Temperature coefficient for gate current |
| XTIS, XTID | 3.0 (XTID=XTIS) | Junction current temperature exponent |
| TPB | 0.0 V/K | Temperature coefficient of PB |
| TPBSW | 0.0 V/K | Temperature coefficient of PBSW |
| TPBSWG | 0.0 V/K | Temperature coefficient of PBSWG |
| TCJ | 0.0 1/K | Temperature coefficient of CJ |
| TCJSW | 0.0 1/K | Temperature coefficient of CJSW |
| TCJSWG | 0.0 1/K | Temperature coefficient of CJSWG |
| TVFBSDOFF | 0.0 1/K | Temperature coefficient of VFBSDOFF |
| TNFACTOR (b) | 0.0 | Temperature coefficient of NFACTOR |
| TETA0 | 0.0 | Temperature coefficient of ETA0 |
| RTH0 | 0.0 K*m/W | Thermal resistance for self-heating |
| CTH0 | 1.0e-5 W*s/m/K | Thermal capacitance for self-heating |
| WTH0 | 0.0 m | Width-dependence coefficient for self heating |
| BG0SUB | eV | Band gap energy at 0K |
| TBGASUB | eV/K | Band gap temperature coefficient A |
| TBGBSUB | K | Band gap temperature coefficient B |

### Stress Effect Model Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| SAref | 1e-6 m | Reference distance OD edge to poly (one side) |
| SBref | 1e-6 m | Reference distance OD edge to poly (other side) |
| SAEDGE | SA | SA parameter for EDGEFET |
| SBEDGE | SB | SB parameter for EDGEFET |
| WLOD | 0.0 m | Width parameter for stress effect |
| KU0 | 0.0 m | Mobility degradation/enhancement coefficient |
| KVSAT | 0.0 m | Saturation velocity stress parameter |
| TKU0 | 0.0 | Temperature coefficient of KU0 |
| LKU0 | 0.0 | Length dependence of KU0 |
| WKU0 | 0.0 | Width dependence of KU0 |
| PKU0 | 0.0 | Cross-term dependence of KU0 |
| LLODKU0 | 0.0 | Length parameter for U0 stress effect |
| WLODKU0 | 0.0 | Width parameter for U0 stress effect |
| KVTH0 | 0.0 V*m | Threshold shift parameter for stress |
| KVTH0EDGE | 0.0 V*m | KVTH0 for EDGEFET |
| LKVTH0 | 0.0 | Length dependence of KVTH0 |
| WKVTH0 | 0.0 | Width dependence of KVTH0 |
| PKVTH0 | 0.0 | Cross-term dependence of KVTH0 |
| LLODVTH | 0.0 | Length parameter for Vth stress effect |
| WLODVTH | 0.0 | Width parameter for Vth stress effect |
| STK2 | 0.0 m | K2 shift factor for stress |
| STK2EDGE | STK2 m | STK2 for EDGEFET |
| LODK2 | 0.0 | K2 shift modification factor |
| STETA0 | 0.0 m | ETA0 shift factor for stress |
| STETA0EDGE | 0.0 m | STETA0 for EDGEFET |
| LODETA0 | 1.0 | ETA0 shift modification factor |

### Well-Proximity Effect Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| WEB | 0.0 | Coefficient for SCB |
| WEC | 0.0 | Coefficient for SCC |
| KVTH0WE (b) | 0.0 | Threshold shift factor for well proximity |
| K2WE (b) | 0.0 | K2 shift factor for well proximity |
| KVTH0EDGEWE (b) | 0.0 | Threshold shift in EDGEFET for well proximity |
| K2EDGEWE (b) | 0.0 | K2 shift in EDGEFET for well proximity |
| KU0WE (b) | 0.0 | Mobility degradation factor for well proximity |
| SCREF | 1e-6 m | Reference distance for SCA/SCB/SCC |

### Edge FET and Sub-Surface Leakage Parameters

| Parameter | Unit | Default | Description |
|-----------|------|---------|-------------|
| NDEPEDGE (b) | m^-3 | 1e24 | Channel doping for EDGEFET |
| WEDGE | m | 10e-9 | Edge FET width |
| DGAMMA | -- | 0 | Body-bias coefficient difference (Edge vs Main) |
| DGAMMAL | -- | 0 | L dependence of DGAMMA |
| DGAMMALEXP | -- | 1.0 | Exponent of L dependence for DGAMMA |
| DVTEDGE | -- | 0.0 | Vth shift for Edge FET |
| NFACTOREDGE (b) | -- | 0 | NFACTOR for Edge FET |
| CITEDGE (b) | F/m^2 | 0 | CIT for Edge FET |
| CDSCDEDGE (b) | F/m^2/V | 1e-9 | CDSCD for Edge FET |
| CDSCBEDGE (b) | F/m^2/V | 0 | CDSCB for Edge FET |
| ETA0EDGE (b) | -- | 0.08 | DIBL for Edge FET |
| ETABEDGE (b) | 1/V | -0.07 | ETAB for Edge FET |
| K2EDGE | V | 0.0 | Vth shift due to body bias for Edge FET |
| KT1EDGE (b) | V | -0.11 | Temperature Vth coefficient for Edge FET |
| KT1LEDGE (b) | V*m | 0 | Temperature Vth coefficient (L) for Edge FET |
| KT2EDGE (b) | -- | 0.022 | Temperature Vth coefficient for Edge FET |
| KT1EXPEDGE | -- | 1 | Temperature Vth exponent for Edge FET |
| TNFACTOREDGE (b) | -- | 0.0 | Temperature coefficient of subthreshold slope for Edge FET |
| TETA0EDGE | -- | 0 | Temperature coefficient of DIBL for Edge FET |
| DVT0EDGE | -- | 2.2 | First SCE coefficient on Vth for Edge FET |
| DVT1EDGE | -- | 0.53 | Second SCE coefficient on Vth for Edge FET |
| DVT2EDGE | 1/V | 0.0 | Body-bias coefficient for SCE in Edge FET |
| SSL0 | A/m | 400 | Sub-surface leakage parameter |
| SSL1 | 1/m | 3.36e8 | Sub-surface leakage parameter |
| SSL2 | -- | 0.185 | Sub-surface leakage parameter |
| SSL3 | V | 0.3 | Sub-surface leakage parameter |
| SSL4 | 1/V | 1.4 | Sub-surface leakage parameter |
| SSL5 | -- | -- | Sub-surface leakage Vbs parameter |
| SSLEXP1 | -- | 0.490 | Sub-surface leakage exponent |
| SSLEXP2 | -- | 1.42 | Sub-surface leakage exponent |

### High Voltage Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| HVMOD | -- | 0 | [0, 1] | Flag for high voltage mode (set HVMOD=1, RDSMOD=1) |
| RDLCW | Ohm*um^WR | 100 | [0, --] | Resistance of drain at low current |
| RDLCWCV | Ohm*um^WR | RDLCW | [0, --] | Drain low current resistance for CV calculations |
| RSLCW | Ohm*um^WR | 0 | [0, --] | Resistance of source at low current |
| NDRIFTD | 1/m^2 | -- | [--, 5e16] | Drift region charge density (drain) |
| NDRIFTS | 1/m^2 | NDRIFTD | -- | Drift region charge density (source) |
| VDRIFT | m/s | 2e5 | (0, --] | Carrier velocity in drift region |
| PTWGHV | -- | 0 | -- | VDRIFT variation with gate bias |
| PTWGHV1 | -- | 0 | -- | VDRIFT variation with gate bias |
| PSATXHV | -- | 60.0 | -- | Fine tuning of PTWGHV effect |
| PDRWB | -- | 0 | -- | Body bias dependence of drift region resistance |
| MDRIFT | -- | 1 | (0, 4) | Parameter for Id,lin to Id,sat transition |
| DRB1 | -- | 0.0 | -- | Body bias dependency parameter |
| DRB2 | -- | 0.0 | -- | Body bias dependency parameter |
| RDVDS | -- | 8 | -- | Idriftsat variation with drain voltage |
| GADRIFT | -- | 200 | -- | Idriftsat variation with drain voltage |
| RBODYHVMOD | -- | 0 | -- | Drain-body diode partitioning flag |
| XPART | -- | 0.0 | -- | Drain-body diode partitioning parameter |
| HVCAP | -- | 0 | [0, 1] | High voltage capacitance model flag |
| HVFACTOR | -- | 1e-3 | [1e-4, 1] | HV smoothing factor |
| VFBOV | V | -1 | -- | Flat band voltage of drift region |
| LOVER | m | 500e-9 | -- | Length of drift region overlap in inversion |
| LOVERACC | m | LOVER | -- | Length of drift region overlap in accumulation |
| SLHV | -- | 0 | [0, --] | Tuning Cgg slope in accumulation (flag: set=1 to enable) |
| SLHV1 | -- | 0 | [0, --] | Tuning Cgg slope in accumulation |
| NDR | 1/m^3 | NDEP | -- | Doping of drift region |
| ALPHADR | m/V | ALPHA0 | [0, --] | First Iii parameter in drift region |
| BETADR | 1/V | BETA0 | [0, --] | Second Iii parameter in drift region |
| BETA1 | 1/V | 0 | [0, --] | Iii parameter for high drain bias (intrinsic) |
| BETA2 | -- | 0 | [0, --] | Iii parameter for high drain bias (intrinsic) |
| BETA3 | -- | 1 | [0.1, 10] | Iii parameter for high drain bias (intrinsic) |
| ALPHA1 | 1/V | 0 | [0, --] | Iii Vb dependence (intrinsic) |
| ALPHA2 | 1/V^2 | 0 | [0, --] | Iii Vb dependence (intrinsic) |
| ALPHA3 | -- | 0 | -- | Iii parameter (intrinsic, high drain bias) |
| ALPHA4 | -- | 0 | [0, --] | Iii parameter (intrinsic, high drain bias) |
| DRII1 | -- | -- | -- | Drift region current normalization |
| DRII2 | -- | -- | -- | Drift region offset |
| DRII3 | -- | 1 | [0, --] | Drift region Vds dependency |
| DRII4 | -- | 0 | [0, --] | Conductivity modulation voltage drop correction |
| ALPHADR1 | 1/V | 0 | [0, --] | Iii Vb dependence (drift) |
| ALPHADR2 | 1/V^2 | 0 | [0, --] | Iii Vb dependence (drift) |
| ALPHADR3 | 1/V | 0 | -- | VDDROP modulation for Iii (drift) |
| ALPHADR4 | 1/V^2 | 0 | -- | VDDROP modulation for Iii (drift) |
| DREXP | -- | 0 | [0, 5.0] | VDDROP modulation exponent for Iii (drift) |
| PTWGHVII | 1/V | 0 | -- | VDDROP modulation for Iii (drift) |
| PTWGHV1II | 1/V | 0 | -- | VDDROP modulation for Iii (drift) |
| PSATXHVII | 1/V | 60 | -- | VDDROP modulation for Iii (drift) |
| CMD1 | -- | 0 | [0, --] | Conductivity modulation parameter (drain) |
| CMD2 | -- | 1 | [0.5, 5.0] | Conductivity modulation parameter (drain) |
| CMS1 | -- | 0 | [0, --] | Conductivity modulation parameter (source) |
| CMS2 | -- | 1 | [0.5, 5.0] | Conductivity modulation parameter (source) |
| DSMOOTH | -- | 0 | [0, --] | Smoothing for drift region velocity saturation transition |

### Gate Tunneling Current Parameters (supplementary)

| Parameter | Default | Description |
|-----------|---------|-------------|
| AIGBACC | -- | Parameter for Igbacc |
| BIGBACC | -- | Parameter for Igbacc |
| CIGBACC | -- | Parameter for Igbacc |
| NIGBACC | -- | Non-ideality for Igbacc |
| AIGBINV | -- | Parameter for Igbinv |
| BIGBINV | -- | Parameter for Igbinv |
| CIGBINV | -- | Parameter for Igbinv |
| EIGBINV | -- | Energy parameter for Igbinv |
| NIGBINV | -- | Non-ideality for Igbinv |

### Mobility Scaling Parameters (MOBSCALE=1)

| Parameter | Default | Description |
|-----------|---------|-------------|
| UP1 | -- | Mobility exponential fitting parameter |
| UP2 | -- | Mobility exponential fitting parameter |
| LP1 | -- | Mobility length parameter |
| LP2 | -- | Mobility length parameter |

---

## Equations

### Physical Constants (Section 2.1)

$$q = 1.6 \times 10^{-19} \text{ C}$$

$$\epsilon_0 = 8.8542 \times 10^{-12} \text{ F/m}$$

$$\epsilon_{sub} = EPSRSUB \cdot \epsilon_0$$

$$\epsilon_{ox} = EPSROX \cdot \epsilon_0$$

$$C_{ox} = \frac{3.9 \cdot \epsilon_0}{TOXE}$$

$$\epsilon_{ratio} = \frac{EPSRSUB}{3.9}$$

### Effective Channel Length and Width (Section 2.2)

$$\Delta L = LINT + \frac{LL}{L_{new}^{LLN}} + \frac{LW}{W_{new}^{LWN}} + \frac{LWL}{L_{new}^{LLN} \cdot W_{new}^{LWN}}$$

$$\Delta W = WINT + \frac{WL}{L_{new}^{WLN}} + \frac{WW}{W_{new}^{WWN}} + \frac{WWL}{L_{new}^{WLN} \cdot W_{new}^{WWN}}$$

$$L_{new} = L \cdot LMLT + XL$$

$$W_{new} = \frac{W}{NF} \cdot WMLT + XW$$

$$\Delta L_{CV} = DLC, \quad \Delta W_{CV} = DWC$$

$$L_{eff} = L \cdot LMLT + XL - 2\Delta L$$

$$W_{eff} = W \cdot WMLT + XW - 2\Delta W$$

$$L_{eff,CV} = L \cdot LMLT + XL - 2\Delta L_{CV}$$

$$W_{eff,CV} = W \cdot WMLT + XW - 2\Delta W_{CV}$$

Binning-adjusted effective dimensions use $\Delta L_1$ and $\Delta W_1$ with DLBIN/DWBIN offsets.

### Binning Calculations (Section 2.3)

$$PARAM_i = PARAM + LPARAM \cdot BIN_L + WPARAM \cdot BIN_W + PPARAM \cdot BIN_{WL}$$

When BINUNIT=1:

$$BIN_L = \frac{10^{-6}}{L_{eff} + DLBIN}, \quad BIN_W = \frac{10^{-6}}{W_{eff} + DWBIN}$$

When BINUNIT=0:

$$BIN_L = \frac{1.0}{L_{eff} + DLBIN}, \quad BIN_W = \frac{1.0}{W_{eff} + DWBIN}$$

$$BIN_{WL} = BIN_L \cdot BIN_W$$

### Global Geometrical Scaling (Section 2.4)

General form:

$$PARAM[L] = PARAM \cdot \left[1 + PARAML \cdot \left(\frac{1}{L_{eff}^{PARAM_{LEXP}}} - \frac{1}{LLONG^{PARAM_{LEXP}}}\right) + PARAMW \cdot \left(\frac{1}{W_{eff}^{PARAM_{WEXP}}} - \frac{1}{WWIDE^{PARAM_{WEXP}}}\right) + PARAMWL \cdot \frac{1}{(L_{eff} \cdot W_{eff})^{PARAM_{WLEXP}}}\right]$$

NDEP has dual length scaling terms:

$$NDEP[L] = NDEP \cdot \left[1 + NDEPL1 \cdot \frac{1}{L_{eff}^{NDEPLEXP1}} + NDEPL2 \cdot \frac{1}{L_{eff}^{NDEPLEXP2}} + NDEPW \cdot \frac{1}{W_{eff}^{NDEPWEXP}} + NDEPWL \cdot \frac{1}{(L_{eff} \cdot W_{eff})^{NDEPWLEXP}}\right]$$

Mobility scaling (MOBSCALE=0):

$$U0[L] = \begin{cases} U0 \cdot \left(1 - U0L \cdot \frac{1}{L_{eff}^{U0LEXP}}\right) & \text{if } U0LEXP > 0 \\ U0 \cdot (1 - U0L) & \text{otherwise} \end{cases}$$

Mobility scaling (MOBSCALE=1):

$$U0[L] = U0 \cdot \left[1 - UP1 \cdot \exp\left(\frac{-L_{eff}}{LP1}\right) - UP2 \cdot \exp\left(\frac{-L_{eff}}{LP2}\right)\right]$$

ETA0 scaling:

$$ETA0[L] = ETA0 \cdot \frac{1}{L_{eff}^{DSUB}}$$

Individual parameter scaling equations follow the general form above for: UA, EU, UD, UC, VSAT, PSAT, PTWG, ALPHA0, AGIDL/AGISL, AIGC/AIGS/AIGD, PIGCD, NDEPCV, VFBCV, VSATCV, PCLMCV, K2, PRWB, RSW, RDW, RDSW, FPROUT, PCLM, DELTA, PDIBLC, CDSCD, CDSCB, NFACTOR, ETAB.

### Terminal Voltages (Section 2.5)

$$V_t = \frac{kT}{q}$$

$$V_g = V_{g,ext} - V_b, \quad V_d = V_{d,ext} - V_b, \quad V_s = V_{s,ext} - V_b$$

$$V_{gs} = V_g - V_s, \quad V_{gd} = V_g - V_d, \quad V_{ds} = V_d - V_s$$

Smooth absolute value of Vds:

$$V_{dsx} = \frac{2}{AVDSX} \cdot \ln\left(1 + \exp\left(\frac{AVDSX \cdot V_{DS}}{2}\right)\right) - V_{DS} - \frac{2}{AVDSX} \cdot \ln(2)$$

$$V_{bsx} = -\left(V_s + \frac{1}{2}(V_{ds} - V_{dsx})\right)$$

### Pinch-off Potential with Poly Depletion (Section 2.6.1)

$$\phi_b = \ln\left(\frac{n_{body}}{n_i}\right)$$

$$\gamma_0 = \frac{\sqrt{2 q \epsilon_{si} \cdot NDEP}}{C_{ox}\sqrt{nV_t}}, \quad \gamma_g = \frac{\sqrt{2 q \epsilon_{si} \cdot NGATE}}{C_{ox}\sqrt{nV_t}}$$

$$\delta_{PD} = \frac{NDEP}{NGATE}, \quad \gamma = \frac{\gamma_0}{1 + \delta_{PD}}$$

Pinch-off potential (depletion/inversion, $\psi_p > 0$):

$$\psi_p = \left[\sqrt{\frac{v_g - v_{fb} - 1 + e^{-\psi_{p0}}}{1+\delta_{PD}} + \left(\frac{\gamma}{2}\right)^2} - \frac{\gamma}{2}\right]^2 + 1 - e^{-\psi_{p0}}$$

Accumulation ($\psi_p < 0$):

$$\psi_p = -\ln\left[1 - \psi_{p0} + \left(\frac{v_g - v_{fb} - \psi_{p0}}{\gamma}\right)^2\right]$$

### Normalized Charge Density (Section 2.6.2)

Core charge equation:

$$\ln(q_i) + \ln\left[\frac{2n_q}{γ_0}\left(q_i \cdot \frac{2n_q}{\gamma_0} + 2\sqrt{\psi_p - 2q_i}\right)\right] + 2q_i = \psi_p - 2\phi_f - v_{ch}$$

Subthreshold initial guess ($\ln q_0 \le -80$):

$$n_{q0} = 1 + \frac{\gamma}{2\sqrt{\psi_p}}$$

$$v = \psi_p - 2\phi_f - v_{ch} - \ln\left(4 \cdot \frac{n_{q0}}{\gamma} \cdot \sqrt{\psi_p}\right)$$

$$\ln q_0 = \frac{1}{2}\left[v - 0.201491 - \sqrt{v(v+0.402982) + 2.446562}\right]$$

$$q_0 = e^{\ln q_0}$$

For $\ln q_0 \le -80$:

$$q_{s/d} = q_0 \cdot \left[1 + \psi_p - 2\phi_f - v_{ch} - \ln q_0 - \ln\left(2\frac{n_{q0}}{\gamma}\left(2q_0 \frac{n_{q0}}{\gamma} + 2\sqrt{\psi_p}\right)\right)\right]$$

For $\ln q_0 > -80$, Newton-Halley refinement:

$$f = 2q_0 + \ln\left(\frac{n_q}{\gamma}\left(2q_0 \frac{n_q}{\gamma} + 2\sqrt{\psi_p}\right)\right) - (v_p - 2\phi_f - v_{ch})$$

$$f' = 2 + \frac{1}{q_0} + \frac{\frac{n_{q0}}{\gamma} - \frac{1}{\sqrt{\psi_p}}}{\frac{n_{q0}}{\gamma} \cdot q_0 + \sqrt{\psi_p}}$$

$$q_1 = q_0 - \frac{f}{f'}$$

Then Halley's method:

$$q_{s/d} = q_1 - \frac{f}{f'} \cdot \left(1 + \frac{f \cdot f''}{2 f'^2}\right)$$

### Short Channel Effects (Section 2.7)

Asymmetry weighting:

$$T_0 = \tanh(ASYMP \cdot q \cdot V_{ds,noswap} / kT)$$

$$w_f = 0.5 + 0.5 \cdot T_0, \quad w_r = 1 - w_f$$

Threshold voltage roll-off and DIBL:

$$\psi_{st} = 0.4 + PHIN + \frac{kT}{q} \cdot \ln\frac{NDEP}{n_i}$$

$$X_{dep} = \sqrt{\frac{2 \epsilon_{sub} \cdot \psi_{st,Vbs}}{q \cdot NDEP}}$$

Subthreshold slope factor:

$$n = 1 + \frac{CIT + NFACTOR + CDSCD \cdot V_{dsx} - CDSCB \cdot V_{bsx}}{C_{ox}}$$

$$\Delta V_{th,VNUD} = K1 \cdot (\sqrt{\phi_{st} - V_{bs}} - \sqrt{\phi_{st}}) - K2 \cdot V_{bsx}$$

$$\Delta V_{th,DIBL} = -(ETA0 + ETAB \cdot V_{bsx}) \cdot V_{dsx}$$

$$\Delta V_{th,DITS} = -n\frac{kT}{q} \cdot \ln\left[\frac{L_{eff}}{L_{eff} + DVTP0 \cdot (1+\exp(-DVTP1 \cdot V_{ds}))}\right] - DVTP5 + \frac{DVTP2}{L_{eff}} \cdot DVTP3 \cdot \tanh(DVTP4 \cdot V_{dsx})$$

$$\Delta V_{th,all} = \Delta V_{th,VNUD} + \Delta V_{th,DIBL} + \Delta V_{th,DITS}$$

$$V_{gfb} = V_g - V_{fb} - \Delta V_{th,all}$$

### Drain Saturation Voltage (Section 2.8)

Effective field at source:

$$\eta = \begin{cases} \frac{1}{2} \cdot ETAMOB & \text{NMOS} \\ \frac{1}{3} \cdot ETAMOB & \text{PMOS} \end{cases}$$

$$E_{eff,s} = 10^{-8} \cdot \frac{q_{bs} + \eta \cdot q_{is}}{\epsilon_{ratio} \cdot TOXE}$$

Source-side mobility degradation:

$$D_{mobs} = 1 + (UA + UC \cdot V_{bsx}) \cdot E_{eff,s}^{EU} + \frac{UD}{\left(\frac{1}{2} \cdot \sqrt{1 + \frac{q_{bs}}{q_{is}}}\right)^{UCS}}$$

PSATB smoothing:

$$T_0 = 0.5 \cdot \left(1 - T_{11} + \sqrt{(1-T_{11})^2 + T_{12}}\right), \quad T_{11} = PSATB \cdot V_{bsx}$$

Velocity saturation parameter:

$$\lambda_C = \frac{2 \cdot U0 \cdot nV_t}{D_{mobs}^{1/PSAT} \cdot VSAT \cdot L_{eff}} \cdot \left[1 + PTWG \cdot \frac{10 \cdot PSATX \cdot q_s \cdot T_0}{10 \cdot PSATX + q_s \cdot T_0}\right]$$

$$q_{dsat} = \frac{\lambda_C}{2} \cdot \frac{q_s^2 + q_s}{1 + \frac{\lambda_C}{2}^2 \cdot (1+q_s)}$$

$$v_{dsat} = \psi_p - \frac{2\phi_b}{n} - 2q_{dsat} - \ln\left(\frac{2q_{dsat} \cdot n_q}{gam} \cdot \left(\frac{2q_{dsat} \cdot n_q}{gam} + \frac{gam}{n_q - 1}\right)\right)$$

### Mobility Degradation (Section 2.9)

$$E_{eff,m} = 10^{-8} \cdot \frac{q_{ba} + \eta \cdot q_{ia}}{\epsilon_{ratio} \cdot TOXE}$$

$$D_{mob} = 1 + (UA + UC \cdot V_{bsx}) \cdot E_{eff,m}^{EU} + \frac{UD}{\left(\frac{1}{2}\sqrt{1 + q_{ba}/q_{ia}}\right)^{UCS}}$$

### Parasitic Series Resistance (Section 2.10)

**RDSMOD=0** (internal bias-dependent):

$$T_0 = 1 + PRWG \cdot q_{ia}$$

$$T_1 = PRWB \cdot (\sqrt{\phi_s - V_{bs}} - \sqrt{\phi_s})$$

$$T_3 = \frac{1}{2}\left(T_2 + \sqrt{T_2^2 + 0.01}\right), \quad T_2 = \frac{1}{T_0} + T_1$$

$$R_{ds}(V) = NF \cdot W_{eff}^{WR} \cdot (RDSWMIN + RDSW \cdot T_3)$$

$$D_r = 1 + \frac{\mu_0}{D_{mob} \cdot D_{vsat}} \cdot C_{ox} \cdot \frac{W_{eff}}{L_{eff}} \cdot q_{ia} \cdot R_{ds}$$

**RDSMOD=1** (external bias-dependent):

$$V_{gs,eff} = \frac{1}{2}\left(V_{gs1} - V_{fbsdr} + \sqrt{(V_{gs1} - V_{fbsdr})^2 + 10^{-2}}\right)$$

$$R_{source} = \frac{1}{W_{eff}^{WR} \cdot NF} \cdot \left(RSWMIN + RSW \cdot \left(-PRWB \cdot V_{sb1} + \frac{1}{1+PRWG_i \cdot V_{gs,eff}}\right)\right) + R_{s,geo}$$

(Analogous for $R_{drain}$ with RDW parameters and $V_{gd,eff}$.)

**Sheet Resistance:**

$$R_{s,geo} = NRS \cdot RSHS, \quad R_{d,geo} = NRD \cdot RSHD$$

### Output Conductance (Section 2.11)

**CLM:**

$$E_{sat} = \frac{2 \cdot VSAT}{U0/D_{mob}}$$

$$F = \begin{cases} 1 & \text{if } FPROUT \le 0 \\ \frac{1}{1+FPROUT\sqrt{L_{eff}}} & \text{if } FPROUT > 0 \end{cases}$$

$$C_{clm} = \begin{cases} PCLM \cdot \left(1 + PCLMG \cdot \frac{q_{ia} + 2nV_t}{E_{sat} \cdot L_{eff}}\right) \cdot \frac{1}{F} & \text{if } PCLMG > 0 \\ \frac{PCLM}{1 - PCLMG \cdot \frac{q_{ia}}{E_{sat} \cdot L_{eff}}} \cdot \frac{1}{F} & \text{if } PCLMG < 0 \end{cases}$$

$$V_{asat} = V_{dssat} + E_{sat} \cdot L_{eff}$$

$$M_{CLM} = 1 + C_{clm} \cdot \ln\left(1 + \frac{V_{ds} - V_{dsef\!f}}{V_{asat}}\right) \cdot \frac{1}{C_{clm}}$$

**DIBL:**

$$PVAGfactor = \begin{cases} 1 + PVAG \cdot \frac{q_{im}}{E_{sat} \cdot L_{eff}} & \text{if } PVAG > 0 \\ \frac{1}{1 - PVAG \cdot \frac{q_{im}}{E_{sat} \cdot L_{eff}}} & \text{if } PVAG < 0 \end{cases}$$

$$VA_{DIBL} = \frac{q_{ia} + 2kT/q}{PDIBLC} \cdot \left(1 - \frac{V_{dssat}}{V_{dssat} + q_{ia} + 2kT/q}\right) \cdot PVAGfactor \cdot \frac{1}{1+PDIBLCB \cdot V_{bsx}}$$

$$M_{DIBL} = 1 + \frac{V_{ds} - V_{dsef\!f}}{VA_{DIBL}}$$

**DITS:**

$$VA_{DITS} = \frac{1}{PDITS} \cdot F \cdot [1 + (1 + PDITSL \cdot L_{eff}) \cdot \exp(PDITSD \cdot V_{ds})]$$

$$M_{DITS} = 1 + \frac{V_{ds} - V_{dsef\!f}}{VA_{DITS}}$$

**SCBE:**

$$litl = \sqrt{\frac{\epsilon_{sub}}{\epsilon_{ox}} \cdot TOXE \cdot XJ}$$

$$VA_{SCBE} = \frac{L_{eff}}{PSCBE2} \cdot \exp\left(\frac{PSCBE1 \cdot litl}{V_{ds} - V_{dsef\!f}}\right)$$

$$M_{SCBE} = 1 + \frac{V_{ds} - V_{dsef\!f}}{VA_{SCBE}}$$

$$M_{oc} = M_{DIBL} \cdot M_{CLM} \cdot M_{DITS} \cdot M_{SCBE}$$

### Velocity Saturation (Section 2.12)

$$T_1 = 2\lambda_C(q_s - q_{deff})$$

$$D_{vsat} = \frac{1}{2}\left[\sqrt{1+T_1^2} + \frac{1}{T_1}\ln(T_1 + \sqrt{1+T_1^2})\right]$$

$$D_{tot} = D_{mob} \cdot D_{vsat} \cdot D_r$$

**Non-saturation effect:**

$$T_0 = A1 + \frac{A2}{q_{ia} + 2nV_t}$$

$$N_{sat} = 0.5(1 + \sqrt{1 + T_3}), \quad T_3 = -1 + 0.5(T_2 + \sqrt{T_2^2 + 0.004})$$

$$I_{ds} = I_{ds} / N_{sat}$$

### Effective Mobility (Section 2.13)

$$\mu_{eff} = \frac{U0}{D_{tot}}$$

### Drain Current (Section 2.14)

Without velocity saturation:

$$I_{DS} = 2 n_q \cdot \mu_{eff} \cdot \frac{W_{eff}}{L_{eff}} \cdot C_{ox} \cdot (nV_t)^2 \cdot (q_s - q_{deff})(q_s + q_{deff} + 1)$$

Including velocity saturation and output conductance:

$$I_{DS} = 2 n_q \cdot \mu_{eff} \cdot \frac{W_{eff}}{L_{eff}} \cdot C_{ox} \cdot (nV_t)^2 \cdot (q_s - q_{deff})(q_s + q_{deff} + 1) \cdot M_{oc}$$

where $\mu_{eff} = U0/D_{tot}$ and $D_{tot} = D_{mob} \cdot D_{vsat} \cdot D_r$.

### Threshold Voltage (Section 2.15)

Long channel:

$$V_{TH,long} = V_{FB} + \psi_{p,th} \cdot V_t - \gamma\sqrt{\psi_{p,th} \cdot V_t}$$

Short channel:

$$V_{TH} = V_{TH,long} - \Delta V_{th,all}$$

### MNUD Model (Section 2.16)

$$MNUD = 1 + K0 \cdot \left[\frac{q_s - q_{deff}}{M0 + q_s + q_{deff}}\right]^2$$

$$I_{DS} = I_{DS,base} / MNUD$$

### MNUD1 Model (Section 2.17)

$$MNUD1 = \exp\left[\frac{-C0}{(C0SI + C0SISAT \cdot (q_s-q_{deff})^2)(q_s+q_{deff}) + 2nV_t}\right]$$

$$I_{DS} = I_{DS,base} / (MNUD \cdot MNUD1)$$

### AbulkIV Model (Section 2.18)

$$T_1 = \frac{L_{eff}}{L_{eff} + \sqrt{XJ \cdot X_{dep}}}$$

$$AbulkIV = 1 + \frac{A0 \cdot T_1 - AGS \cdot q_s^{AGS1} \cdot V_t \cdot T_1}{1 + KETA \cdot V_{bsx}}$$

$$V_{dssat} = V_{dssat} / AbulkIV$$

$$V_{dsef\!f} = V_{ds} \cdot (1 + T_7)^{-DELTA}, \quad T_7 = (V_{ds}/V_{dssat})^{1/DELTA}$$

### Subthreshold Hump / Edge FET (Section 2.19)

$$I_{ds,EDGE} = 2 \cdot NF \cdot n_q \cdot \mu_{eff} \cdot \frac{WEDGE}{L_{eff}} \cdot C_{ox} \cdot nV_t \cdot (q_s - q_{deff})(1 + q_s + q_{deff}) \cdot M_{oc}$$

$$I_{total} = I_{ds} + I_{ds,EDGE}$$

### Sub-Surface Leakage (Section 2.20)

$$T_1 = \left(\frac{NDEP}{10^{23}}\right)^{SSLEXP1}, \quad T_2 = \left(\frac{300}{T}\right)^{SSLEXP2}$$

$$T_3 = \frac{devsign \cdot SSL5 \cdot V_{bs}}{V_t}$$

$$T_5 = SSL3 \cdot \tanh\left[\exp(devsign \cdot SSL4 \cdot (V_{gb} - V_{TH} - V_{sb}))\right]$$

$$I_{ssl} = sigvds \cdot NF \cdot W_{eff} \cdot SSL0_{NT} \cdot \exp(T_3) \cdot \exp\left(-SSL1_{NT} \cdot L + \frac{T_5}{V_t}\right) \cdot \left[\exp\left(SSL2 \cdot \frac{V_{dsx}}{V_t}\right) - 1\right]$$

### Impact Ionization (Section 2.21)

Intrinsic (HVMOD=0):

$$I_{ii} = ALPHA0 \cdot (V_{ds} - V_{dsef\!f}) \cdot \exp\left(\frac{-BETA0}{V_{ds} - V_{dsef\!f}}\right) \cdot \frac{I_{ds}}{M_{SCBE}}$$

Intrinsic (HVMOD=1):

$$ALPHA0_{eff} = \frac{ALPHA0}{1 + ALPHA4 \cdot \exp(ALPHA3 \cdot V_d)} \cdot (1 + ALPHA1 \cdot V_{bsx} + ALPHA2 \cdot V_{bsx}^2)$$

$$V_{dseff,ii} = V_{ds} \cdot \left[1 + \left(\frac{V_{ds}}{(1+BETA1 \cdot V_{ds}) \cdot V_{dssat}}\right)^{1/DELTA}\right]^{-DELTA}$$

$$BETA0_{eff} = \frac{BETA0}{2} \cdot \left(1 + \frac{BETA2}{V_{dseff,ii}}\right)$$

Drift region secondary impact ionization:

$$I_{sub,DR} = ALPHADR_{eff} \cdot E_m \cdot I_{ds} \cdot \exp\left(\frac{-BETADR}{E_m}\right)$$

$$N_{tot} = \frac{DRII1 \cdot I_{ds}}{NF \cdot W_{eff} \cdot q \cdot V_{DRIFTeff}}$$

$$E_m = \sqrt{\frac{2q(N_{tot}/NDRIFT - 1)}{\epsilon}} \cdot V_{DDROP}^{0.5}$$

$$V_{DDROP} = V(d,s) - DRII3 \cdot V_{dseff,ii} - DRII2 - CMD1 \cdot V_{bcm}^{DRII4}$$

### GIDL/GISL Current (Section 2.22)

$$I_{GIDL} = AGIDL \cdot W_{eff} \cdot NF \cdot \frac{V_{ds} - V_{gse} - EGIDL}{3 \cdot T_{oxe}} \cdot \exp\left(\frac{-3 T_{oxe} \cdot BGIDL}{V_{ds} - V_{gse} - EGIDL}\right) \cdot \frac{V_{db}^3}{CGIDL + V_{db}^3}$$

$$I_{GISL} = AGISL \cdot W_{eff} \cdot NF \cdot \frac{-V_{ds} - V_{gde} - EGISL}{3 \cdot T_{oxe}} \cdot \exp\left(\frac{-3 T_{oxe} \cdot BGISL}{-V_{ds} - V_{gde} - EGISL}\right) \cdot \frac{V_{sb}^3}{CGISL + V_{sb}^3}$$

### Gate Tunneling Current (Section 2.23)

$$V_{ox} = nV_t \cdot (v_g - v_{fb} - \psi_p + q_s + q_{deff})$$

$$V_{oxacc} = \frac{1}{2}(-V_{ox} + \sqrt{V_{ox}^2 + 10^{-4}})$$

$$V_{oxdepinv} = \frac{1}{2}(V_{ox} + \sqrt{V_{ox}^2 + 10^{-4}})$$

$$ToxRatio = \left(\frac{TOXREF}{TOXE}\right)^{NTOX} \cdot \frac{1}{TOXE^2}$$

**Igbacc** (accumulation, ECB):

$$I_{gbacc} = NF \cdot W_{eff} \cdot L_{eff} \cdot A \cdot ToxRatio \cdot V_{gb} \cdot V_{aux} \cdot igtemp \cdot \exp[-B \cdot TOXE(AIGBACC - BIGBACC \cdot V_{oxacc})(1+CIGBACC \cdot V_{oxacc})]$$

$$V_{aux} = NIGBACC \cdot V_t \cdot \log\left(1 + \exp\left(\frac{-V_{ox}}{NIGBACC \cdot V_t}\right)\right)$$

**Igbinv** (inversion, EVB):

$$I_{gbinv} = NF \cdot W_{eff} \cdot L_{eff} \cdot A \cdot ToxRatio \cdot V_{gb} \cdot V_{aux} \cdot igtemp \cdot \exp[-B \cdot TOXE(AIGBINV - BIGBINV \cdot V_{oxdepinv})(1+CIGBINV \cdot V_{oxdepinv})]$$

**Igc0** (gate-to-channel at Vds=0):

$$I_{gc0} = NF \cdot W_{eff} \cdot L_{eff} \cdot A \cdot ToxRatio \cdot V_{gse} \cdot V_{aux} \cdot igtemp \cdot \exp[-B \cdot TOXE(AIGC - BIGC \cdot V_{oxdepinv})(1 + CIGC \cdot V_{oxdepinv})]$$

$$V_{aux} = n_q \cdot nV_t \cdot (q_s + q_{deff})$$

Partition:

$$I_{gcs} = I_{gc0} \cdot \frac{PIGCD \cdot V_{dseffx} + \exp(-PIGCD \cdot V_{dseffx}) - 1 + 10^{-4}}{(PIGCD \cdot V_{dseffx})^2 + 2 \times 10^{-4}}$$

$$I_{gcd} = I_{gc0} \cdot \frac{1 - (PIGCD \cdot V_{dseffx}+1)\exp(-PIGCD \cdot V_{dseffx}) + 10^{-4}}{(PIGCD \cdot V_{dseffx})^2 + 2 \times 10^{-4}}$$

**Igs, Igd** (gate-to-S/D diffusion):

$$I_{gs} = NF \cdot W_{eff} \cdot DLCIG \cdot A \cdot ToxRatioEdge \cdot V_{gs} \cdot V'_{gs} \cdot igtemp \cdot \exp[-B \cdot TOXE \cdot POXEDGE(AIGS - BIGS \cdot V'_{gs})(1+CIGS \cdot V'_{gs})]$$

$$V'_{gs} = \sqrt{(V_{gs}-V_{fbsd})^2 + 10^{-4}}$$

(Analogous for $I_{gd}$ with AIGD, BIGD, CIGD, DLCIGD.)

### Gate Resistance (Section 2.24.1)

$$R_{geltd} = \frac{RSHG \cdot (XGW + \frac{W_{eff,ci}}{3 \cdot NGCON})}{NGCON \cdot (L_{drawn} - XGL) \cdot NF}$$

RGATEMOD=2 (IIR):

$$\frac{1}{R_{ii}} = XRCRG1 \cdot NF \cdot \frac{I_{ds}}{V_{dsef\!f}} + XRCRG2 \cdot \frac{W_{eff} \cdot \mu_{eff} \cdot C_{ox,eff} \cdot V_t}{L_{eff}}$$

### Substrate Resistance Network (Section 2.24.2)

RBODYMOD=2 (scalable):

$$RBPS = RBPS0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBPSL} \cdot \left(\frac{W}{10^{-6}}\right)^{RBPSW} \cdot NF^{RBPSNF}$$

$$RBPD = RBPD0 \cdot \left(\frac{L}{10^{-6}}\right)^{RBPDL} \cdot \left(\frac{W}{10^{-6}}\right)^{RBPDW} \cdot NF^{RBPDNF}$$

$$RBPB = \frac{RBPBX \cdot RBPBY}{RBPBX + RBPBY}$$

(RBSBX, RBSBY, RBDBX, RBDBY follow same pattern.)

### Flicker Noise (Section 2.25.1)

**FNOIMOD=0:**

$$N_0 = \frac{2n_q C_{ox} V_t q_s}{q}, \quad N_l = \frac{2n_q C_{ox} V_t q_{deff}}{q}, \quad N^* = \frac{V_t(C_{ox} + C_d + CIT)}{q}$$

$$S_{id,inv}(f) = \frac{kT q^2 \mu_{eff} I_{ds}}{C_{oxe} L_{eff,NOI}^2 \cdot NOI \cdot f^{EF} \cdot 10^{10}} \cdot \left[NOIA \cdot \ln\frac{N_0+N^*}{N_l+N^*} + NOIB(N_0-N_l) + \frac{NOIC}{2}(N_0^2-N_l^2)\right] + \frac{kT I_{ds}^2}{W_{eff} L_{eff}^2} \cdot \frac{\Delta L_{clm} \cdot T_{0C}}{NOI \cdot f^{EF} \cdot 10^{10} \cdot (N_l+N^*)^2}$$

$$S_{id,subVt}(f) = \frac{NOIA_{eff} \cdot kT \cdot I_{ds}^2}{W_{eff} L_{eff} \cdot f^{EF} \cdot N^{*2} \cdot 10^{10}}$$

$$S_{id}(f) = \frac{S_{id,inv} \cdot S_{id,subVt}}{S_{id,inv} + S_{id,subVt}}$$

Tuning flexibility:

$$S_{id,new} = \frac{S_{id,old}}{1 + NOIA1 \cdot (q_s - q_{deff})^{NOIAX}}$$

### Channel Thermal Noise (Section 2.25.2)

**TNOIMOD=0:**

$$Q_{inv} = |Q_{s,intrinsic} + Q_{d,intrinsic}| \times NF_{total}$$

$$i_d^2 = \begin{cases} NTNOI \cdot \frac{4kT\Delta f}{L^2} \cdot \frac{1}{R_{ds} + \frac{\mu_{eff}}{Q_{eff,inv}}} & \text{RDSMOD=0} \\ NTNOI \cdot \frac{4kT\Delta f}{L_{eff}^2} \cdot \mu_{eff} Q_{inv} & \text{RDSMOD=1} \end{cases}$$

**TNOIMOD=1:**

$$\beta_{tnoi} = RNOIA \cdot \left[1 + TNOIA \cdot L_{eff} \cdot \left(\frac{q_{ia}}{E_{sat,noi} \cdot L_{eff}}\right)^2\right]$$

$$S_{id} = 4kT \cdot \mu C_{ox} \frac{W_{eff}}{L_{vsat}} V_t D_{ptwg} M_{oc} \cdot \frac{q_s+q_{deff}}{2} \cdot \left[1 + \frac{\beta_{lowId}}{TNOIK2+q_{ia}} \cdot \frac{V_{dsef\!f}}{V_{dsat}} + (3\beta_{tnoi})^2 \cdot \frac{(q_s-q_{deff})^2}{12\left(\frac{1+q_s+q_{deff}}{2}\right)^2}\right]$$

### Gate Current Shot Noise (Section 2.25.3)

$$i_{gs}^2 = 2q(I_{gcs} + I_{gs})$$

$$i_{gd}^2 = 2q(I_{gcd} + I_{gd})$$

$$i_{gb}^2 = 2qI_{gbinv}$$

### Self Heating (Section 2.26)

$$R_{th} = \frac{RTH0}{(WTH0 + W_{eff}) \cdot NF}$$

$$C_{th} = CTH0 \cdot (WTH0 + W_{eff}) \cdot NF$$

### Junction Diode IV (Section 3.1)

Source/Body:

$$I_{bs} = I_{sbs}\left[\exp\left(\frac{V_{bs}}{NJS \cdot V_t}\right) - 1\right] \cdot f_{breakdown} + V_{bs} \cdot G_{min}$$

$$I_{sbs} = A_{s,eff} \cdot J_{ss}(T) + P_{s,eff} \cdot J_{ssws}(T) + W_{eff,cj} \cdot NF \cdot J_{sswgs}(T)$$

$$f_{breakdown} = 1 + XJBVS \cdot \exp\left(\frac{-(BVS + V_{bs})}{NJS \cdot V_t}\right)$$

(Analogous for drain-side with JSD, NJD, BVD, XJBVD parameters.)

Total with tunneling:

$$I_{bs,total} = I_{bs} - W_{eff,cj} NF \cdot Jtsswgs(T) \cdot \exp\left(\frac{-V_{bs}}{NJTSSWG(T) \cdot V_{tm0}}\right) \cdot \frac{VTSSWGS}{VTSSWGS - V_{bs}} - P_{s,eff} Jtssws(T) \cdot \left[\exp\left(\frac{-V_{bs}}{NJTSSW(T) \cdot V_{tm0}}\right) \cdot \frac{VTSSWS}{VTSSWS - V_{bs}} - 1\right] - A_{s,eff} Jtss(T) \cdot \left[\exp\left(\frac{-V_{bs}}{NJTS(T) \cdot V_{tm0}}\right) \cdot \frac{VTSS}{VTSS - V_{bs}} - 1\right]$$

### Junction Diode CV (Section 3.2)

$$C_{bs} = A_{s,eff} \cdot C_{jbs} + P_{s,eff} \cdot C_{jbssw} + W_{eff,cj} \cdot NF \cdot C_{jbsswg}$$

$$C_{jbs} = \begin{cases} CJS(T) \cdot \left(1 - \frac{V_{bs}}{PBS(T)}\right)^{-MJS} & \text{if } V_{bs}/PBS(T) \le 0.9 \\ CJS(T) \cdot \frac{1}{(1-0.9)^{MJS}} \cdot \left[1 + MJS\left(\frac{V_{bs}/PBS(T) - 1}{1-0.9}\right)\right] & \text{otherwise} \end{cases}$$

(Analogous for sidewall and gate-edge components with CJSWS/MJSWS/PBSWS and CJSWGS/MJSWGS/PBSWGS parameters. Drain side uses CJD, MJD, PBD, etc.)

### Temperature Dependence (Section 5)

**Threshold Voltage:**

$$V_{th}(T) = V_{th}(TNOM) + (KT1_i + KT2_i \cdot V_{bref\!f}) \cdot \left[\left(\frac{T}{TNOM}\right)^{KT1EXP} - 1\right]$$

$$V_{fb}(T) = V_{fb}(TNOM) - KT1 \cdot \left(\frac{T}{TNOM} - 1\right)$$

$$NFACTOR(T) = NFACTOR(TNOM) + TNFACTOR \cdot \left(\frac{T}{TNOM} - 1\right)$$

$$ETA0(T) = ETA0(TNOM) + TETA0 \cdot \left(\frac{T}{TNOM} - 1\right)$$

**Mobility:**

$$U0(T) = U0(TNOM) \cdot (T/TNOM)^{UTE}$$

$$UA(T) = UA(TNOM) \cdot [1 + UA1 \cdot (T-TNOM)]$$

$$UC(T) = UC(TNOM) \cdot [1 + UC1 \cdot (T-TNOM)]$$

$$UD(T) = UD(TNOM) \cdot (T/TNOM)^{UD1}$$

$$UCS(T) = UCS(TNOM) \cdot (T/TNOM)^{UCSTE}$$

$$EU(T) = EU(TNOM) \cdot (1 + EU1 \cdot (T/TNOM - 1))$$

**Saturation Velocity:**

$$VSAT(T) = VSAT(TNOM) \cdot (T/TNOM)^{-AT}$$

**LDD Resistance:**

$$rdstemp = (T/TNOM)^{PRT}$$

$$RDSW(T) = RDSW(TNOM) \cdot rdstemp$$

(Analogous for RSW, RDW, RSWMIN, RDWMIN, RDSWMIN.)

**Junction Diode IV:**

$$J_{ss}(T) = JSS(TNOM) \cdot \exp\left[\frac{E_g(TNOM)/(V_t(TNOM)) - E_g(T)/V_t(T) + XTIS \cdot \ln(T/TNOM)}{NJS}\right]$$

**Junction Diode CV:**

$$CJS(T) = CJS(TNOM) + TCJ \cdot (T - TNOM)$$

$$PBS(T) = PBS(TNOM) - TPB \cdot (T - TNOM)$$

**Energy Gap:**

$$E_{g0} = BG0SUB - \frac{TBGASUB \cdot T_{nom}^2}{T_{nom} + TBGBSUB}$$

$$E_g = BG0SUB - \frac{TBGASUB \cdot T^2}{T + TBGBSUB}$$

**Intrinsic Carrier Concentration:**

$$n_i = NI0SUB \cdot \left(\frac{T}{T_{nom}}\right)^{3/2} \cdot \exp\left(\frac{E_g}{2kT_{nom}/q} - \frac{E_g}{2kT/q}\right)$$

### Stress Effect (Section 6)

$$\rho_{\mu_{eff}} = \frac{KU0}{K_{stress,u0}} \cdot (Inv_{sa} + Inv_{sb})$$

$$Inv_{sa} = \frac{1}{SA + 0.5 \cdot L_{drawn}}, \quad Inv_{sb} = \frac{1}{SB + 0.5 \cdot L_{drawn}}$$

$$K_{stress,u0} = \left(1 + \frac{LKU0}{(L_{drawn}+XL)^{LLODKU0}} + \frac{WKU0}{(W_{drawn}+XW+WLOD)^{WLODKU0}} + \frac{PKU0}{(L_{drawn}+XL)^{LLODKU0}(W_{drawn}+XW+WLOD)^{WLODKU0}}\right) \cdot \left(1 + TKU0 \cdot \left(\frac{T}{TNOM}-1\right)\right)$$

$$\mu_{eff} = \frac{1+\rho_{\mu_{eff}}(SA,SB)}{1+\rho_{\mu_{eff}}(SA_{ref},SB_{ref})} \cdot \mu_{eff,0}$$

$$V_{SAT,temp} = \frac{1 + KVSAT \cdot \rho_{\mu_{eff}}(SA,SB)}{1 + KVSAT \cdot \rho_{\mu_{eff}}(SA_{ref},SB_{ref})} \cdot V_{SAT,0}$$

Vth-related stress:

$$VTH0 = VTH0_{orig} + \frac{KVTH0}{K_{stress,vth0}} \cdot (Inv_{sa} + Inv_{sb} - Inv_{sa,ref} - Inv_{sb,ref})$$

$$K2 = K2_{orig} + \frac{STK2}{K_{stress,vth0}^{LODK2}} \cdot (Inv_{sa} + Inv_{sb} - Inv_{sa,ref} - Inv_{sb,ref})$$

$$ETA0 = ETA0_{orig} + \frac{STETA0}{K_{stress,vth0}^{LODETA0}} \cdot (Inv_{sa} + Inv_{sb} - Inv_{sa,ref} - Inv_{sb,ref})$$

### Well Proximity Effect (Section 7)

$$V_{th0} = V_{th0,org} + KVTH0WE \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC)$$

$$K2 = K2_{org} + K2WE \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC)$$

$$\mu_{eff} = \mu_{eff,org} \cdot (1 + KU0WE \cdot (SCA + WEB \cdot SCB + WEB \cdot SCC))$$

When SCA/SCB/SCC not given, computed from SC and SCREF.

### High Voltage Drift Resistance (Section 8)

Drain side:

$$R_{drift,satD} = R_o \cdot \left[1 + \left(\frac{\delta^{1/MDRIFT} \cdot |V(di1,di)|}{V_{drift,sat,D}}\right)^{MDRIFT}\right]^{1/MDRIFT}$$

$$R_o = rdstemphv \cdot RDLCW \cdot W_{eff}^{WR} \cdot (1 - PDRWB \cdot V_{sb,noswap})$$

$$V_{drift,sat,D} = I_{drift,sat,D} \cdot R_o$$

$$\delta = \frac{|V(di1,di)|^{4-MDRIFT}}{|V(di1,di)|^{4-MDRIFT} + HVFACTOR \cdot V_{drift,satD}^{4-MDRIFT}}$$

$$I_{drift,satD} = NDRIFTD \cdot W \cdot NF \cdot V_{DRIFTeff} \cdot T_0 \cdot \gamma \cdot (1 + CMD1 \cdot V_{bcm}^{CMD2})$$

$$V_{DRIFTeff} = VDRIFT \cdot (1 + PTWGHV \cdot T_2)$$

$$\gamma = 1 - DRB1 \cdot \sqrt{1 + V_{sb,noswap}/V_{bi,drift}} - DRB2 \cdot V_{sb,noswap}$$

Decoupled CV drift resistance:

$$V_{di,CV} = V_{di,IV} + devsign \cdot \left(1 - \frac{RDLCWCV}{RDLCW}\right) \cdot V(di1,di)$$

### C-V Model (Section 9)

**Inversion charge:**

$$q_I = n_q \cdot \left[q_s + q_d + \frac{1}{3} \cdot \frac{(q_s-q_d)^2}{1+q_s+q_d}\right]$$

**Bulk charge:**

$$q_B = v_g - v_{fb} - \psi_p - (n_q-1)\left[q_s + q_d + \frac{1}{3} \cdot \frac{(q_s-q_d)^2}{1+q_s+q_d}\right]$$

**Bulk charge with poly depletion:**

$$q_B = A + B + \frac{1}{3} \cdot \frac{\Delta q^2}{C^3} \cdot \left[\frac{4}{5}(C^2 + PQ) \cdot \left(\frac{1}{1+q_s+q_d} + \frac{2}{\gamma_g'^2}\right)\right] - n_q \left[q_s + q_d + \frac{1}{3} \cdot \frac{(q_s-q_d)^2}{1+q_s+q_d}\right]$$

where:

$$P = \sqrt{\frac{1}{4} + \frac{v_g-v_{fb}-\psi_p+2q_s}{\gamma_g'^2}}, \quad Q = \sqrt{\frac{1}{4} + \frac{v_g-v_{fb}-\psi_p+2q_d}{\gamma_g'^2}}, \quad C = P+Q$$

$$A = \frac{v_g-v_{fb}-\psi_p+2q_s}{1+2\sqrt{\frac{1}{4}+\frac{v_g-v_{fb}-\psi_p+2q_s}{\gamma_g'^2}}}, \quad B = \frac{v_g-v_{fb}-\psi_p+2q_d}{1+2\sqrt{\frac{1}{4}+\frac{v_g-v_{fb}-\psi_p+2q_d}{\gamma_g'^2}}}$$

**Source/drain charge partition:**

$$Q_s = \frac{n_q}{3}\left[2q_s + q_{deff} + \frac{1}{2}\left(1+\frac{4}{5}q_s+\frac{6}{5}q_{deff}\right)\frac{(q_s-q_{deff})^2}{1+q_s+q_{deff}}\right]$$

$$Q_d = \frac{n_q}{3}\left[q_s + 2q_{deff} + \frac{1}{2}\left(1+\frac{6}{5}q_s+\frac{4}{5}q_{deff}\right)\frac{(q_s-q_{deff})^2}{1+q_s+q_{deff}}\right]$$

**With CLM and velocity saturation:**

$$Q_i = \frac{n_q}{MDL}\left[(q_s+q_{deff}) + \frac{1}{3}(q_s-q_{deff})^2 \cdot \frac{AbulkCV \cdot DVSAT}{MDL \cdot (1+q_s+q_{deff})}\right] + 2n_q(MDL-1)q_{deff}$$

where $MDL = M_{CLM} \cdot D_{vsat}$.

**Quantum Mechanical Effect:**

$$X_{DC}^{inv} = \frac{ADOS \cdot 1.9 \times 10^{-9}}{\left[1 + \frac{Q_i + ETAQM \cdot Q_B}{QM0}\right]^{0.7 \cdot BDOS}}$$

$$C_{ox}^{inv} = \frac{3.9 \cdot \epsilon_0}{TOXP \cdot \frac{3.9}{EPSROX} + \frac{X_{DC}^{inv}}{\epsilon_{ratio}}}$$

**CVMOD=1 modified charge:**

$$CVSLOPE \cdot \ln\left[\frac{2n_q q_i}{\gamma_0}\left(\frac{2n_q q_i}{\gamma_0} + 2\sqrt{\psi_p-2q_i}\right)\right] + 2q_i = \psi_p - 2\phi_f - v_{ch}$$

**Bias-dependent overlap capacitance:**

$$V_{gs,overlap} = \frac{1}{2}\left(V_{gs}-V_{fbsd}+\delta_1 - \sqrt{(V_{gs}-V_{fbsd}+\delta_1)^2+4\delta_1}\right)$$

$$\frac{Q_{gs,ov}}{NF \cdot W_{eff,CV}} = CGSO \cdot V_{gs} + CGSL \cdot \left[V_{gs}-V_{fbsd}-V_{gs,overlap} - \frac{CKAPPAS}{2}\left(\sqrt{1-\frac{4T_6}{CKAPPAS}}-1\right)\right]$$

$$T_6 = \frac{V_{gs,overlap}}{\left[1+\left(\frac{-V_{gs,overlap}}{CKAPPAS1}\right)\right]^{1/CKAPPAS2}}$$

(Analogous for drain side with CGDO, CGDL, CKAPPAD parameters.)

**Outer fringe capacitance:**

$$CF = \frac{2 \cdot EPSROX \cdot \epsilon_0}{\pi} \cdot \ln\left[CFRCOEFF \cdot \left(1+\frac{0.4 \times 10^{-6}}{TOX}\right)\right]$$

### Smoothing Function (Appendix A)

For continuous third-order derivatives over region $-\Delta x/2 < x < \Delta x/2$:

$$f(x) = x_0 + \Delta x \cdot \left[\frac{5}{64} + \frac{z}{2} + z^2\left(\frac{15}{16} - z^2\left(\frac{5}{4} - z^2\right)\right)\right]$$

where $z = (x-x_0)/\Delta x$, with $x_0 = (x_1+x_2)/2$ and $\Delta x = x_1 - x_2$.
