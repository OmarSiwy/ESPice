# BSIM-IMG 103.0.0 -- Parameter & Equation Reference

> Independent Multi-Gate MOSFET (UTBB) -- UC Berkeley, January 2020

## Model Topology

BSIM-IMG 103.0.0 models an independent double-gate FDSOI structure as a five-terminal device: front gate (fg), back gate (bg), drain (d), source (s), and thermal node (t). The two gates may have different workfunctions, dielectric thicknesses, and dielectric constants, and are biased independently. The core model is surface-potential-based, solving Poisson's equation in a fully-depleted, lightly-doped body to obtain front and back surface potentials and integrated charge densities at the source and drain ends.

---

## Parameters

### Instance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| L | m | 30n | 1n | -- | Designed gate length |
| W | m | 1e-6 | 1n | -- | Designed gate width |
| NF | -- | 1 | 1 | -- | Number of fingers |
| AS | m^2 | 0 | 0 | -- | Source to substrate overlap area through oxide (all fingers) |
| AD | m^2 | 0 | 0 | -- | Drain to substrate overlap area through oxide (all fingers) |
| PS | m | 0 | 0 | -- | Perimeter of source to substrate overlap region through oxide (all fingers) |
| PD | m | 0 | 0 | -- | Perimeter of drain to substrate overlap region through oxide (all fingers) |
| NRS | -- | 0 | 0 | -- | Number of source diffusion squares (for RGEOMOD=0) |
| NRD | -- | 0 | 0 | -- | Number of drain diffusion squares (for RGEOMOD=0) |

Note: Instance parameters marked (m) are also model parameters.

### Variability Instance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| DTEMP | C | 0 | -- | -- | Variability handle for temperature |
| DELVTRAND | V | 0 | -- | -- | Variability in Vth |
| U0MULT | -- | 1 | -- | -- | Variability in carrier mobility |

### Model Controllers and Process Parameters

(b) = binnable parameter

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| TYPE | -- | 1 (NMOS) | -1 | 1 | NMOS=1, PMOS=-1 |
| WELLTYPE | -- | -1 (p-well) | -1 | 1 | n-well=1, p-well=-1 |
| CHARGEMOD | -- | 0 | 0 | 1 | Inversion charge density model; 0=simplified, 1=more accurate |
| RDSMOD | -- | 0 | 0 | 2 | Source/drain resistance model; 0=internal, 1=external, 2=bias+geometry dependent |
| IGCMOD | -- | 0 | 0 | 1 | Model selector for Igc, Igs, Igd; 1=on, 0=off |
| IGBMOD | -- | 0 | 0 | 1 | Model selector for Igb; 1=on, 0=off |
| GIDLMOD | -- | 0 | 0 | 1 | GIDL/GISL current; 1=on, 0=off |
| SHMOD | -- | 0 | -- | -- | Self-heating mode; 1=on, 0=off |
| RGATEMOD | -- | 0 | -- | -- | Gate resistance model; 1=on, 0=off |
| FNMOD | -- | 0 | -- | -- | Flicker noise model; 1=improved 1/f, 0=BSIM4-like 1/f |
| NFMOD | -- | 0 | -- | -- | Number of finger selector; 1=W is single finger width, 0=W is total width |
| CHARGEWF | -- | 0 | -- | -- | Average channel charge weighting factor (+1:source, 0:middle, -1:drain) |
| XL | m | 0 | -- | -- | L offset for channel length due to mask/etch effect |
| XW | m | 0 | -- | -- | W offset for channel width due to mask/etch effect |
| LINT | m | 0 | -- | -- | Length reduction parameter (dopant diffusion) |
| LL | m^(LLN+1) | 0 | -- | -- | Length reduction parameter (dopant diffusion) |
| LW | m | 0 | -- | -- | Length scaling parameter |
| LWL | m | 0 | -- | -- | Length scaling parameter |
| LLN | -- | 1 | -- | -- | Length reduction parameter (dopant diffusion) |
| LWN | m | 1 | -- | -- | Length scaling parameter |
| WINT (b) | m | 0 | -- | -- | Width reduction parameter (dopant diffusion) |
| WL (b) | m^(WLN+1) | 0 | -- | -- | Width reduction parameter (dopant diffusion) |
| WW (b) | m | 0 | -- | -- | Width scaling parameter |
| WWL (b) | m | 0 | -- | -- | Width scaling parameter |
| WLN (b) | -- | 1 | -- | -- | Width reduction parameter (dopant diffusion) |
| WWN (b) | m | 1 | -- | -- | Width scaling parameter |
| DLC | m | 0 | -- | -- | Length reduction parameter for CV (dopant diffusion) |
| LLC | m | 0 | -- | -- | Length scaling parameter |
| LWC | m | 0 | -- | -- | Length scaling parameter |
| LWLC | m | 0 | -- | -- | Length scaling parameter |
| DWC | m | 0 | -- | -- | Width reduction parameter for CV (dopant diffusion) |
| WLC | m | 0 | -- | -- | Width scaling parameter |
| WWC | m | 0 | -- | -- | Width scaling parameter |
| WWLC | m | 0 | -- | -- | Width scaling parameter |
| EOT1 | m | 1.0n | 0.1n | -- | SiO2 equivalent front gate dielectric thickness (incl. inversion layer) |
| EOT2 | m | 140n | 0.1n | -- | SiO2 equivalent back gate dielectric thickness (incl. substrate depletion) |
| EOT1P | m | EOT1 | 0.1n | -- | Physical front gate dielectric thickness for CV |
| DTOX1 | m | 0.0 | -- | -- | Difference between effective and physical dielectric thickness |
| TSI | m | 8n | 1n | -- | Body (silicon film) thickness |
| NBODY (b) | m^-3 | 1e22 | 1e18 | 5e24 | Channel doping concentration |
| NBG | m^-3 | 5e23 | -- | -- | Substrate (well) or back gate doping level; zero for metal back gate |
| EASUB | eV | 4.05 | 0 | -- | Electron affinity of the substrate material |
| NI0SUB | m^-3 | 1.1e16 | -- | -- | Intrinsic carrier concentration of channel at 300.15K |
| BG0SUB | eV | 1.12 | -- | -- | Band gap of the channel material at 300.15K |
| NC0SUB | m^-3 | 2.86e25 | -- | -- | Conduction band density of states at 300.15K |
| PHIG1 (b) | V | 4.61 | -- | -- | Workfunction of the front gate |
| PHIG2 (b) | V | EASUB+BG0SUB (n-well); EASUB (p-well) | -- | -- | Substrate or back gate workfunction |
| EPSRSUB | -- | 11.9 | -- | -- | Relative dielectric constant of the substrate material |
| EPSROX1 | -- | 3.9 | -- | -- | Relative dielectric constant of the front gate insulator |
| EPSROX2 | -- | 3.9 | -- | -- | Relative dielectric constant of the back gate insulator |
| NSD (b) | m^-3 | 2e26 | 2e25 | 1e27 | S/D doping concentration |

### Basic Model Parameters

(b) = binnable parameter

#### Subthreshold & Short Channel Effect Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| CIT (b) | F/m^2 | 0.0 | -- | -- | Interface trap parameter |
| CDSC (b) | F/m^2 | 0.14 | 0.0 | -- | Coupling capacitance between S/D and channel |
| CDSCD (b) | F/m^2 | 0.14 | 0.0 | -- | Drain-bias sensitivity of CDSC |
| CBGCBG (b) | F/m^2/V | 0.1 | 0.0 | -- | Back-gate bias sensitivity of coupling capacitance |
| CBGCBG0 (b) | F/m^2/V | 0.0 | 0.0 | -- | Back-gate bias sensitivity of SS for long channel |
| CBGCBG0P (b) | F/m^2/V^2 | 0.0 | 0.0 | -- | Sublinear back-gate bias sensitivity of SS for long channel |
| CBGCBGP (b) | F/m^2/V^2 | 0.0 | 0.0 | -- | Nonlinear back-gate bias sensitivity of SS |
| CBGCBGD (b) | F/m^2/V | 0.0 | 0.0 | -- | Back-gate bias sensitivity of CDSCD |
| DVT0 (b) | -- | 19.20 | 0.0 | -- | SCE coefficient |
| DVT1 (b) | -- | 0.45 | 0.0 | -- | SCE exponent coefficient |
| DVTP0 (b) | -- | 0.45 | 0.0 | -- | Coefficient for Drain-Induced Vth Shift (DITS) |
| DVTP1 (b) | -- | 0.45 | 0.0 | -- | DITS exponent coefficient |
| DVTP2 | -- | 0.45 | 0.0 | -- | DITS model parameter |
| PHIN (b) | V | 0.045 | -- | -- | Nonuniform vertical doping effect on surface potential |
| ETA0 (b) | -- | 2.00 | 0.0 | -- | DIBL coefficient |
| ETA1 (b) | -- | 2.00 | 0.0 | -- | DIBL coefficient for low gate overdrive |
| ETAB (b) | 1/V | 0.00 | 0.0 | -- | DIBL coefficient -- back gate bias dependence |
| DSUB (b) | -- | 0.375 | 0.0 | -- | DIBL exponent coefficient |
| K1RSCE (b) | V^(1/2) | -0.32 | -- | -- | Prefactor for reverse short channel effect |
| LPE0 (b) | m | 8.2e-9 | -Leff | -- | Equivalent length of pocket region at zero bias |
| DSC0 | m | 0.0 | -- | -- | Short channel effect at moderate L and high drain bias |
| DSC1 | m | 1n | -- | -- | Short channel effect at moderate L and high drain bias |
| ASCL | -- | 0.0 | -- | -- | Back-gate dependent scale length parameter |
| BSCL | 1/V | 0.0 | -- | -- | Back-gate dependent scale length parameter |

#### Velocity Saturation Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| VSAT (b) | m/s | 85000 | -- | -- | Saturation velocity in the saturation region |
| AVSAT (b) | -- | 0 | -- | -- | VSAT for short channel devices |
| BVSAT (b) | -- | 100.0e-9 | -- | -- | VSAT coefficient for short channel devices |
| VSATB (b) | 1/V | 0.00 | 0.0 | -- | Back gate bias dependence on VSAT at high Vds |
| AVSATB (b) | -- | 0.00 | 0.0 | -- | VSATB for short channel devices |
| BVSATB (b) | -- | 100.0e-9 | 0.0 | -- | VSATB coefficient for short channel devices |
| VSAT1 (b) | m/s | VSAT | -- | -- | Saturation velocity in the linear region |
| AVSAT1 (b) | -- | AVSAT | -- | -- | VSAT1 for short channel devices |
| BVSAT1 (b) | -- | BVSAT | -- | -- | VSAT1 coefficient for short channel devices |
| VSATCV (b) | m/s | VSAT | -- | -- | Saturation velocity for C-V |
| AVSATCV (b) | m/s | AVSAT | -- | -- | VSATCV for short channel devices |
| BVSATCV (b) | m/s | BVSAT | -- | -- | VSATCV coefficient for short channel devices |
| DELTAVSAT | m/s | 1 | 0.01 | -- | Velocity saturation parameter |
| KSATIV (b) | -- | 1.0 | -- | -- | Strong inversion parameter for long channel Vdsat |
| KSUBIV (b) | -- | 1.0 | -- | -- | Weak inversion parameter for long channel Vdsat |
| KSATIVB (b) | -- | 0.0 | -- | -- | Strong inversion back-gate parameter for long channel Vdsat |

#### Smoothing Function Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| MEXP (b) | -- | 4 | 2 | 64 | Smoothing function factor for Vdsat |
| AMEXP (b) | -- | 0 | 0 | -- | MEXP for short channel devices |
| BMEXP (b) | -- | 1 | -- | -- | MEXP coefficient for short channel devices |
| PTWG (b) | 1/V | 0.0 | -- | -- | Correction factor for velocity saturation |
| APTWG (b) | -- | 0.0 | -- | -- | PTWG for short channel devices |
| BPTWG (b) | -- | 100.0e-9 | -- | -- | PTWG coefficient for short channel devices |
| PTWGB (b) | 1/V^3 | 0.0 | -- | -- | Back gate bias sensitivity in PTWG |
| APTWGB (b) | -- | 0.0 | -- | -- | PTWGB for short channel devices |
| BPTWGB (b) | -- | 100.0e-9 | -- | -- | PTWGB coefficient for short channel devices |
| PTWGB2 (b) | 1/V^3 | 0.0 | -- | -- | Back gate bias sensitivity in PTWG (second order) |
| APTWGB2 (b) | -- | 0.0 | -- | -- | PTWGB2 for short channel devices |
| BPTWGB2 (b) | -- | 100.0e-9 | -- | -- | PTWGB2 coefficient for short channel devices |

#### Mobility Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| U0 (b) | m^2/V-s | 3e-2 | -- | -- | Low field mobility at front gate |
| U02 (b) | m^2/V-s | 3e-2 | -- | -- | Low field mobility at back gate |
| ETAMOB | -- | 2.0 | -- | -- | Effective field parameter (front gate) |
| ETAMOB2 | -- | 2.0 | -- | -- | Effective field parameter (back gate) |
| CHARGEWF | -- | 0 | -- | -- | Average channel charge weighting factor at front gate |
| CHARGEWF2 | -- | 0 | -- | -- | Average channel charge weighting factor at back gate |
| UP (b) | -- | 0.0 | -- | -- | Mobility L coefficient (front gate) |
| LPA | um | 1.0 | -- | -- | Mobility L power coefficient (front gate) |
| UP2 (b) | -- | 0.0 | -- | -- | Mobility L coefficient (back gate) |
| LPA2 | um | 1.0 | -- | -- | Mobility L power coefficient (back gate) |
| UA (b) | (cm/MV)^EU | 0.3 | 0.0 | -- | Phonon/surface roughness scattering (front gate) |
| AUA (b) | -- | 0 | -- | -- | UA for short channel devices |
| BUA (b) | -- | 100.0e-9 | -- | -- | UA coefficient for short channel devices |
| UA2 (b) | (cm/MV)^EU | 0.3 | 0.0 | -- | Phonon/surface roughness scattering (back gate) |
| AUA2 (b) | -- | 0 | -- | -- | UA2 for short channel devices |
| BUA2 (b) | -- | 100.0e-9 | -- | -- | UA2 coefficient for short channel devices |
| EU (b) | cm/MV | 2.5 | 0.0 | -- | Phonon/surface roughness scattering exponent (front gate) |
| AEU (b) | -- | 0 | -- | -- | EU for short channel devices |
| BEU (b) | -- | 100.0e-9 | -- | -- | EU coefficient for short channel devices |
| EU2 (b) | cm/MV | 2.5 | 0.0 | -- | Phonon/surface roughness scattering exponent (back gate) |
| AEU2 (b) | -- | 0 | -- | -- | EU2 for short channel devices (back gate) |
| BEU2 (b) | -- | 100.0e-9 | -- | -- | EU2 coefficient for short channel devices (back gate) |
| EUB (b) | cm/MV | 2.5 | 0.0 | -- | Back gate sensitivity on phonon/surface roughness (front gate) |
| AEUB (b) | -- | 0 | -- | -- | EUB for short channel devices |
| BEUB (b) | -- | 100.0e-9 | -- | -- | EUB coefficient for short channel devices |
| EUB2 (b) | cm/MV | 2.5 | 0.0 | -- | Back gate sensitivity on phonon/surface roughness (back gate) |
| AEUB2 (b) | -- | 0 | -- | -- | EUB2 for short channel devices (back gate) |
| BEUB2 (b) | -- | 100.0e-9 | -- | -- | EUB2 coefficient for short channel devices (back gate) |
| UD (b) | cm/MV | 0.0 | 0.0 | -- | Coulombic scattering (front gate) |
| AUD (b) | -- | 0.0 | -- | -- | UD for short channel devices |
| BUD (b) | -- | 50.0e-9 | -- | -- | UD coefficient for short channel devices |
| UD2 (b) | cm/MV | 0.0 | 0.0 | -- | Coulombic scattering (back gate) |
| AUD2 (b) | -- | 0.0 | -- | -- | UD2 for short channel devices |
| BUD2 (b) | -- | 50.0e-9 | -- | -- | UD2 coefficient for short channel devices |
| UDB (b) | cm/MV | 0.0 | 0.0 | -- | Back bias sensitivity on coulombic scattering (front gate) |
| AUDB (b) | -- | 0.0 | -- | -- | UDB for short channel devices |
| BUDB (b) | -- | 50.0e-9 | -- | -- | UDB coefficient for short channel devices |
| UDB2 (b) | cm/MV | 0.0 | 0.0 | -- | Back bias sensitivity on coulombic scattering (back gate) |
| AUDB2 (b) | -- | 0.0 | -- | -- | UDB2 for short channel devices |
| BUDB2 (b) | -- | 50.0e-9 | -- | -- | UDB2 coefficient for short channel devices |
| UC (b) | (cm/MV)^EU/V | 0.0 | 0.0 | -- | Back gate bias dependence on mobility at low Vds (front gate) |
| AUC (b) | -- | 0.0 | -- | -- | UC for short channel devices |
| BUC (b) | -- | 100.0e-9 | -- | -- | UC coefficient for short channel devices |
| UC2 (b) | (cm/MV)^EU/V | 0.0 | 0.0 | -- | Back gate bias dependence on mobility at low Vds (back gate) |
| AUC2 (b) | -- | 0.0 | -- | -- | UC2 for short channel devices |
| BUC2 (b) | -- | 100.0e-9 | -- | -- | UC2 coefficient for short channel devices |
| UCS (b) | -- | 1.0 | 0.0 | -- | Coulombic scattering exponent (front gate) |
| UCS2 (b) | -- | 1.0 | 0.0 | -- | Coulombic scattering exponent (back gate) |

#### Output Conductance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| PCLM (b) | -- | 0.013 | 0.0 | -- | Channel length modulation (CLM) parameter |
| APCLM (b) | -- | 0 | -- | -- | PCLM for short channel devices |
| BPCLM (b) | -- | 100.0e-9 | -- | -- | PCLM coefficient for short channel devices |
| PCLMG | -- | 0 | -- | -- | Gate bias dependent CLM parameter |
| PCLMCV | -- | 0.013 | 0.0 | -- | CLM parameter for C-V |
| PDIBL1 (b) | -- | 1.30 | 0.0 | -- | DIBL effect on Rout parameter |
| PDIBL2 (b) | -- | 2e-4 | 0.0 | -- | DIBL effect on Rout parameter |
| DROUT (b) | -- | 1.06 | 0.0 | -- | L dependence of DIBL effect on Rout |
| PVAG (b) | -- | 1.0 | -- | -- | Vgs dependence on early voltage |

#### Parasitic Resistance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| RDSWMIN (b) | Ohm-um^WR | 0.0 | 0.0 | -- | RDSMOD=0: S/D extension resistance per unit width at high Vgs |
| RDSW (b) | Ohm-um^WR | 100 | 0.0 | -- | RDSMOD=0: Zero bias S/D extension resistance per unit width |
| ARDSW (b) | -- | 0 | -- | -- | RDSW for short channel devices |
| BRDSW (b) | -- | 100.0e-9 | -- | -- | RDSW coefficient for short channel devices |
| RSWMIN | Ohm-um^WR | 0.0 | 0.0 | -- | RDSMOD=1: Source extension resistance at high Vgs |
| RSW (b) | Ohm-um^WR | 50 | 0.0 | -- | RDSMOD=1: Zero bias source extension resistance |
| ARSW (b) | -- | 0 | -- | -- | RSW for short channel devices |
| BRSW (b) | -- | 100.0e-9 | -- | -- | RSW coefficient for short channel devices |
| RDWMIN | Ohm-um^WR | RSWMIN | 0.0 | -- | RDSMOD=1: Drain extension resistance at high Vgs |
| RDW (b) | Ohm-um^WR | RSW | 0.0 | -- | RDSMOD=1: Zero bias drain extension resistance |
| ARDW (b) | -- | ARSW | -- | -- | RDW for short channel devices |
| BRDW (b) | -- | BRSW | -- | -- | RDW coefficient for short channel devices |
| PRWG (b) | 1/V | 0.0 | 0.0 | -- | Front gate bias dependence of S/D extension resistance |
| PRWB (b) | 1/V | 0.0 | -- | -- | Back gate bias dependence of S/D extension resistance |
| WR (b) | -- | 1.0 | -- | -- | W dependence parameter of S/D extension resistance |
| RSHS | Ohm | 0.0 | 0.0 | -- | Source-side sheet resistance |
| RSHD | Ohm | RSHS | 0.0 | -- | Drain-side sheet resistance |

#### Gate Resistance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| XGW | m | 0 | -- | -- | Distance from gate contact center to device edge |
| XGL | m | 0 | -- | -- | Variation in Ldrawn |
| NGCON | -- | 1 | -- | -- | Number of gate contacts |
| RSHG | Ohm | 0.1 | -- | -- | Gate sheet resistance |

#### Gate Tunneling Current Parameters (Igb)

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| AIGBINV (b) | (F s^2/g)^0.5 m^-1 | 1.11e-2 | -- | -- | Igb inversion parameter |
| BIGBINV (b) | (F s^2/g)^0.5 m^-1 | 9.49e-4 | -- | -- | Igb inversion parameter |
| CIGBINV (b) | 1/V | 6.00e-3 | -- | -- | Igb inversion parameter |
| EIGBINV (b) | V | 1.1 | -- | -- | Igb inversion parameter |
| NIGBINV (b) | -- | 3.0 | 0.0 | -- | Igb inversion parameter |
| AIGBACC (b) | (F s^2/g)^0.5 m^-1 | 1.36e-2 | -- | -- | Igb accumulation parameter |
| BIGBACC (b) | (F s^2/g)^0.5 m^-1 | 1.71e-3 | -- | -- | Igb accumulation parameter |
| CIGBACC (b) | 1/V | 7.5e-2 | -- | -- | Igb accumulation parameter |
| NIGBACC (b) | -- | 1.0 | 0.0 | -- | Igb accumulation parameter |
| TOXP | m | -- | -- | -- | Physical oxide thickness |

#### Gate Tunneling Current Parameters (Igc)

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| AIGC (b) | (F s^2/g)^0.5 m^-1 | 1.36e-2 | -- | -- | Igc inversion parameter |
| BIGC (b) | (F s^2/g)^0.5 m^-1 | 1.71e-3 | -- | -- | Igc inversion parameter |
| CIGC (b) | 1/V | 0.075 | -- | -- | Igc inversion parameter |
| DIGC (b) | -- | 1.0 | -- | -- | Igc inversion parameter |
| PIGCD | -- | 1.0 | 0.0 | -- | Vds dependence of Igcs and Igcd |

#### Gate-to-Source/Drain Current Parameters (Igs, Igd)

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| DLCIGS | m | 0.0 | -- | -- | Delta L for Igs model |
| DLCIGD | m | DLCIGS | -- | -- | Delta L for Igd model |
| AIGS (b) | (F s^2/g)^0.5 m^-1 | 1.36e-2 | -- | -- | Igs parameter |
| BIGS (b) | (F s^2/g)^0.5 m^-1 | 1.71e-3 | -- | -- | Igs parameter |
| CIGS (b) | 1/V | 0.075 | -- | -- | Igs parameter |
| DIGS (b) | -- | 1.0 | -- | -- | Igs back-gate sensitivity parameter |
| AIGD (b) | (F s^2/g)^0.5 m^-1 | AIGS | -- | -- | Igd parameter |
| BIGD (b) | (F s^2/g)^0.5 m^-1 | BIGS | -- | -- | Igd parameter |
| CIGD (b) | 1/V | CIGS | -- | -- | Igd parameter |
| DIGD (b) | -- | DIGS | -- | -- | Igd back-gate sensitivity parameter |
| POXEDGE (b) | -- | 1 | 0.0 | -- | Factor for gate edge Tox |
| TOXREF | m | 1.2n | 0.0 | -- | Nominal gate oxide thickness for gate tunneling current |
| NTOX (b) | -- | 1.0 | -- | -- | Exponent for gate oxide ratio |

#### GIDL/GISL Current Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| AGIDL (b) | Ohm^-1 | 6.055e-12 | -- | -- | Pre-exponential coefficient for GIDL |
| BGIDL (b) | V/m | 0.3e9 | -- | -- | Exponential coefficient for GIDL |
| EGIDL (b) | V | 0.2 | -- | -- | Band bending parameter for GIDL |
| PGIDL (b) | -- | 1.0 | -- | -- | Exponent of electric field for GIDL |
| VBGIDL | -- | 1.0 | -- | -- | Back gate correction factor for GIDL |
| VBEGIDL (b) | V | 0.5 | -- | -- | Back band bending parameter for GIDL |
| AGISL (b) | Ohm^-1 | AGIDL | -- | -- | Pre-exponential coefficient for GISL |
| BGISL (b) | V/m | BGIDL | -- | -- | Exponential coefficient for GISL |
| EGISL (b) | V | EGIDL | -- | -- | Band bending parameter for GISL |
| PGISL (b) | -- | PGIDL | -- | -- | Exponent of electric field for GISL |
| VBGISL | -- | VBGIDL | -- | -- | Back gate correction factor for GISL |
| VBEGISL (b) | V | VBEGIDL | -- | -- | Back band bending parameter for GISL |

#### Impact Ionization Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| ALPHA0 (b) | m/V | 0.0 | -- | -- | First parameter of Iii |
| ALPHA1 (b) | 1/V | 0.0 | -- | -- | L scaling parameter of Iii |
| BETA0 | 1/V | 0.0 | -- | -- | Vds dependent parameter of Iii |

#### Parasitic Capacitance Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| LOVS | m | 0.0 | -- | -- | Overlap length for gate/source overlap capacitance |
| LOVD | m | LOVS | -- | -- | Overlap length for gate/drain overlap capacitance |
| CFS | F/m | 0.0 | -- | -- | Outer fringe capacitance (source side) |
| CFD | F/m | CFS | -- | -- | Outer fringe capacitance (drain side) |
| CGSL (b) | F/m | 0 | 0.0 | -- | Overlap capacitance between gate and lightly-doped source |
| CGDL (b) | F/m | CGSL | 0.0 | -- | Overlap capacitance between gate and lightly-doped drain |
| CKAPPAS (b) | V | 0.6 | 0.02 | -- | Bias-dependent overlap capacitance coefficient (source) |
| CKAPPAD (b) | V | CKAPPAS | 0.02 | -- | Bias-dependent overlap capacitance coefficient (drain) |
| CSDBGSW | F/m | 0.0 | -- | -- | Prefactor for bias-dependent inner fringe capacitance |
| PCOVBS0 | V | 0.0 | -- | -- | Back-gate dependent overlap capacitance shift voltage (source) |
| PCOVBS1 | -- | 0.0 | -- | -- | Back-gate dependent overlap capacitance parameter (source) |
| PCOVBD0 | V | PCOVBS0 | -- | -- | Back-gate dependent overlap capacitance shift voltage (drain) |
| PCOVBD1 | -- | PCOVBS1 | -- | -- | Back-gate dependent overlap capacitance parameter (drain) |

#### Back Gate Biasing Parameters (P-well)

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| KBG0PW | -- | 1.0 | -- | -- | P-type substrate factor |
| KBG1PW | -- | 0 | -- | -- | Length dependence of p-type substrate factor |
| KBG2PW | -- | -1 | -- | -- | Length dependence of p-type substrate factor |
| DBGPW | -- | 0.12 | -- | -- | Length dependence of p-type substrate factor |
| BPFACTORPW | -- | 0.0 | 0.0 | 1.0 | Back-plane effect for p-type substrate (0=no BP) |
| VKNEE1PW | V | 0.0 | -- | -- | Back gate voltage at which p-type substrate depletion starts |
| VKNEE2PW | V | 1.0 | 0.0 | -- | Maximum potential drop below BOX for p-type substrate |

#### Back Gate Biasing Parameters (N-well)

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| KBG0NW | -- | 1.0 | -- | -- | N-type substrate factor |
| KBG1NW | -- | 0 | -- | -- | Length dependence of n-type substrate factor |
| KBG2NW | -- | -1 | -- | -- | Length dependence of n-type substrate factor |
| DBGNW | -- | 0.12 | -- | -- | Length dependence of n-type substrate factor |
| BPFACTORNW | -- | 0.0 | 0.0 | 1.0 | Back-plane effect for n-type substrate (0=no BP) |
| VKNEE1NW | V | 0.0 | -- | -- | Back gate voltage at which n-type substrate depletion starts |
| VKNEE2NW | V | 1.0 | 0.0 | -- | Maximum potential drop below BOX for n-type substrate |

#### Quantum Mechanical Effect Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| QMTCENCV (b) | -- | 0.0 | -- | -- | Prefactor/switch for QM effective width and oxide thickness correction for CV |
| ETAQM (b) | -- | 0.54 | -- | -- | Body-charge coefficient for QM charge centroid |
| QM0 (b) | V | 1e-3 | 0.0 | -- | Normalization parameter for QM charge centroid (inversion) |
| PQM (b) | -- | 0.66 | -- | -- | Fitting parameter for QM charge centroid (inversion) |

#### Lateral Non-Uniform Doping Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| K0 (b) | V | 0.0 | -- | -- | Lateral NUD voltage parameter |
| K01 (b) | V/K | 0.0 | -- | -- | Temperature dependence of K0 |
| K0SI (b) | -- | 1.0 | -- | -- | Correction factor for strong inversion in Mnud |
| K0SI1 (b) | 1/K | 0.0 | -- | -- | Temperature dependence of K0SI |

#### Noise Parameters

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| EF | -- | 1.0 | 0.0 | 2.0 | Flicker noise frequency exponent |
| LINTNOI | m | 0.0 | -- | Leff/2 | Lint offset for flicker noise calculation |
| EM | V/m | 4.1e7 | -- | -- | Flicker noise parameter |
| NOIA | eV^-1 s^(1-EF) m^-3 | 6.250e39 | >0 | -- | Flicker noise parameter |
| NOIB | eV^-1 s^(1-EF) m^-1 | 3.125e24 | >0 | -- | Flicker noise parameter |
| NOIC | eV^-1 s^(1-EF) | 8.750e7 | >0 | -- | Flicker noise parameter |
| NOIA2 | eV^-1 s^(1-EF) | NOIA | >0 | -- | Noise parameter for FNMOD=1 (sub-threshold) |
| SMOOTH | -- | 2 | >0 | -- | Smoothing parameter |
| MPOWER | -- | 1.2 | >0 | -- | Sub-threshold to strong inversion transition slope parameter |
| QSREF | -- | 50m | >0 | -- | Charge at threshold condition |
| NTNOI (b) | -- | 1.0 | 0.0 | -- | Thermal noise parameter |

### Parameters for Temperature Dependence and Self Heating

| Parameter | Unit | Default | Min | Max | Description |
|-----------|------|---------|-----|-----|-------------|
| TNOM | C | 27 (273.15K) | -- | -- | Temperature at which model is extracted |
| TMAXC | C | 400 | -- | -- | Maximum device temperature |
| TBGASUB | eV/K | 7.02e-4 | -- | -- | Bandgap temperature coefficient |
| TBGBSUB | K | 1108.0 | -- | -- | Bandgap temperature coefficient |
| KT1 (b) | V | 0.0 | -- | -- | Vth temperature coefficient |
| KT1L | V-m | 0.0 | -- | -- | Vth temperature coefficient (length-dependent) |
| KT2 (b) | -- | 0.0 | -- | -- | Vth temperature coefficient (back-gate dependent) |
| KT2L | m | 0.0 | -- | -- | Length dependent parameter for Vth temperature Vbg coefficient |
| UTE (b) | -- | 0.0 | -- | -- | Mobility temperature coefficient |
| UTL (b) | -- | -1.5e-3 | -- | -- | Mobility temperature coefficient |
| UA1 (b) | -- | 1.032e-3 | -- | -- | Mobility temperature coefficient for UA |
| UC1 (b) | -- | 0.0 | -- | -- | Mobility temperature coefficient for UC |
| UD1 (b) | -- | 0.0 | -- | -- | Mobility temperature coefficient |
| UCSTE (b) | -- | -4.775e-3 | -- | -- | Mobility temperature coefficient |
| AT (b) | 1/K | -0.00156 | -- | -- | Saturation velocity temperature coefficient |
| ATL (b) | m | 0.0 | -- | -- | Length scaling parameter for AT |
| TMEXP (b) | -- | 0 | -- | -- | Temperature coefficient for MEXP smoothing factor |
| ATB (b) | 1/K | 0.0 | -- | -- | Back bias sensitivity for saturation velocity temperature coefficient |
| ATBL (b) | m | 0.0 | -- | -- | Length scaling parameter for ATB |
| PTWGT (b) | 1/K | 0.004 | -- | -- | PTWG temperature coefficient |
| PRT (b) | 1/K | 0.001 | -- | -- | Series resistance temperature coefficient |
| TETA0 (b) | -- | 0.0 | -- | -- | Temperature dependence for DIBL effect |
| IIT (b) | -- | -0.5 | -- | -- | Impact ionization temperature coefficient |
| TGIDL (b) | 1/K | -0.003 | -- | -- | GIDL temperature coefficient |
| TGISL (b) | 1/K | TGIDL | -- | -- | GISL temperature coefficient |
| IGT | -- | 2.5 | -- | -- | Gate current temperature coefficient |
| EMOBT | -- | -- | -- | -- | ETAMOB temperature coefficient (used in eq. 3.66) |
| RTH0 | Ohm-m-K/W | 0.01 | 0.0 | -- | Thermal resistance for self-heating |
| CTH0 | W-s/m/K | 1.0e-5 | 0.0 | -- | Thermal capacitance for self-heating |
| WTH0 | m | 0.0 | 0.0 | -- | Width-dependence coefficient for self-heating |

---

## Equations

### 3.1 Bias Independent Calculations

#### 3.1.1 Physical Constants

$$q = 1.6 \times 10^{-19} \quad \text{(3.3)}$$

$$\epsilon_0 = 8.8542 \times 10^{-12} \quad \text{(3.4)}$$

$$k = 1.3787 \times 10^{-23} \quad \text{(3.5)}$$

$$\epsilon_{si} = EPSRSUB \cdot \epsilon_0 \quad \text{(3.6)}$$

$$\epsilon_{sub} = EPSRSUB \cdot \epsilon_0 \quad \text{(3.7)}$$

$$\epsilon_{ox1} = EPSROX1 \cdot \epsilon_0 \quad \text{(3.8)}$$

$$\epsilon_{ox2} = EPSROX2 \cdot \epsilon_0 \quad \text{(3.9)}$$

$$ratio = \frac{EPSRSUB}{3.9} \quad \text{(3.10)}$$

$$C_{ox1} = \frac{3.9 \cdot \epsilon_0}{EOT1} \quad \text{(3.11)}$$

$$C_{ox2} = \frac{3.9 \cdot \epsilon_0}{EOT2} \quad \text{(3.12)}$$

$$C_{ox1P} = \frac{3.9 \cdot \epsilon_0}{EOT1P} \quad \text{(3.13)}$$

$$C_{ox2P} = \frac{3.9 \cdot \epsilon_0}{EOT2P} \quad \text{(3.14)}$$

$$C_{si} = \frac{\epsilon_{si}}{TSI} \quad \text{(3.15)}$$

$$v_{tm} = \frac{kT}{q} \quad \text{(3.16)}$$

$$\delta_2 = 10^{-3} \quad \text{(3.17)}$$

#### 3.1.2 Effective Channel Length and Width

$$L_{new} = L + XL \quad \text{(3.18)}$$

$$L_{LLN} = L_{new}^{-LLN} \quad \text{(3.19)}$$

$$L_{WLN} = L_{new}^{-WLN} \quad \text{(3.20)}$$

$$L_{WLLN\text{-}LWN} = L_{LLN} \cdot W_{LWN} \quad \text{(3.21)}$$

$$dL_{IV} = LINT + LL \cdot L_{LLN} + LW \cdot W_{LWN} + LWL \cdot L_{WLLN\text{-}LWN} \quad \text{(3.22)}$$

$$L_{eff} = L_{new} - 2.0 \cdot dL_{IV} \quad \text{(3.23)}$$

$$dL_{CV} = DLC + LLC \cdot L_{LLN} + LWC \cdot W_{LWN} + LWLC \cdot L_{WLLN\text{-}LWN} \quad \text{(3.24)}$$

$$L_{eff,CV} = L_{new} - 2.0 \cdot dL_{CV} \quad \text{(3.25)}$$

NFMOD switch for $W_{new}$:

$$W_{new} = \begin{cases} \frac{W}{NF} & \text{NFMOD} = 0 \\ W + XW & \text{NFMOD} = 1 \end{cases} \quad \text{(3.26)}$$

$$W_{LWN} = W_{new}^{-LWN} \quad \text{(3.27)}$$

$$W_{WWN} = W_{new}^{-WWN} \quad \text{(3.28)}$$

$$L_{WWLN\text{-}WWN} = L_{WLN} \cdot W_{WWN} \quad \text{(3.29)}$$

$$dW_{IV} = WINT + WL \cdot L_{WLN} + WW \cdot W_{WWN} + WWL \cdot L_{WWLN\text{-}WWN} \quad \text{(3.30)}$$

$$W_{eff} = W_{new} - 2.0 \cdot dW_{IV} \quad \text{(3.31)}$$

$$dW_{CV} = DWC + WLC \cdot L_{WLN} + WWC \cdot W_{WWN} + WWLC \cdot L_{WWLN\text{-}WWN} \quad \text{(3.32)}$$

$$W_{eff,CV} = W_{new} - 2.0 \cdot dW_{CV} \quad \text{(3.33)}$$

#### 3.1.3 Binning Calculations

$$PARAM_i = PARAM + \frac{1}{L_{eff}} \cdot LPARAM + \frac{1}{W_{eff}} \cdot WPARAM + \frac{1}{W_{eff} L_{eff}} \cdot PPARAM \quad \text{(3.34)}$$

#### 3.1.4 Length Scaling Equations

$$U0(2)_{[L]} = \begin{cases} U0(2)_i \cdot \left[1 - UP(2)_i \cdot L_{eff}^{-LPA(2)}\right] & LPA(2) > 0 \\ U0(2)_i \cdot \left[1 - UP(2)_i\right] & \text{otherwise} \end{cases} \quad \text{(3.35)}$$

$$UA(2)_{[L]} = UA(2)_i + AUA(2) \cdot \exp\left(-\frac{L_{eff}}{BUA(2)}\right) \quad \text{(3.36)}$$

$$EU(2)_{[L]} = EU(2)_i + AEU(2) \cdot \exp\left(-\frac{L_{eff}}{BEU(2)}\right) \quad \text{(3.37)}$$

$$EUB(2)_{[L]} = EUB(2)_i + AEUB(2) \cdot \exp\left(-\frac{L_{eff}}{BEUB(2)}\right) \quad \text{(3.38)}$$

$$UD(2)_{[L]} = UD(2)_i + AUD(2) \cdot \exp\left(-\frac{L_{eff}}{BUD(2)}\right) \quad \text{(3.39)}$$

$$UDB(2)_{[L]} = UDB(2)_i + AUDB(2) \cdot \exp\left(-\frac{L_{eff}}{BUDB(2)}\right) \quad \text{(3.40)}$$

$$UC(2)_{[L]} = UC(2)_i + AUC(2) \cdot \exp\left(-\frac{L_{eff}}{BUC(2)}\right) \quad \text{(3.41)}$$

$$MEXP_{[L]} = MEXP_i + AMEXP \cdot L_{eff}^{-BMEXP} \quad \text{(3.42)}$$

$$PCLM_{[L]} = PCLM_i + APCLM \cdot \exp\left(-\frac{L_{eff}}{BPCLM}\right) \quad \text{(3.43)}$$

$$PTWG_{[L]} = PTWG_i + APTWG \cdot \exp\left(-\frac{L_{eff}}{BPTWG}\right) \quad \text{(3.44)}$$

$$PTWGB_{[L]} = PTWGB_i + APTWGB \cdot \exp\left(-\frac{L_{eff}}{BPTWGB}\right) \quad \text{(3.45)}$$

$$PTWGR_{[L]} = PTWGR_i + APTWG \cdot \exp\left(-\frac{L_{eff}}{BPTWG}\right) \quad \text{(3.46)}$$

$$VSAT_{[L]} = VSAT_i + AVSAT \cdot \exp\left(-\frac{L_{eff}}{BVSAT}\right) \quad \text{(3.47)}$$

$$VSATB_{[L]} = VSATB_i + AVSATB \cdot \exp\left(-\frac{L_{eff}}{BVSATB}\right) \quad \text{(3.48)}$$

$$VSAT1_{[L]} = VSAT1_i + AVSAT1 \cdot \exp\left(-\frac{L_{eff}}{BVSAT1}\right) \quad \text{(3.49)}$$

$$VSATCV_{[L]} = VSAT_i + AVSATCV \cdot \exp\left(-\frac{L_{eff}}{BVSATCV}\right) \quad \text{(3.50)}$$

$$DVTP0_{[L]} = DVTP0_i + ADVTP0 \cdot \exp\left(-\frac{L_{eff}}{BDVTP0}\right) \quad \text{(3.51)}$$

$$DVTP1_{[L]} = DVTP1_i + ADVTP1 \cdot \exp\left(-\frac{L_{eff}}{BDVTP1}\right) \quad \text{(3.52)}$$

If RDSMOD = 0:

$$RDSW_{[L]} = RDSW_i + ARDSW \cdot \exp\left(-\frac{L_{eff}}{BRDSW}\right) \quad \text{(3.54)}$$

If RDSMOD = 1:

$$RSW_{[L]} = RSW_i + ARSW \cdot \exp\left(-\frac{L_{eff}}{BRSW}\right) \quad \text{(3.55)}$$

$$RDW_{[L]} = RDW_i + ARDW \cdot \exp\left(-\frac{L_{eff}}{BRDW}\right) \quad \text{(3.56)}$$

#### 3.1.5 Temperature Effects

$$E_g = BG0SUB - \frac{TBGASUB \cdot T^2}{T + TBGBSUB} \quad \text{(3.57)}$$

$$n_i = NI0SUB \cdot \left(\frac{T}{300.15}\right)^{3/2} \cdot \exp\left(\frac{BG0SUB \cdot q}{2k \cdot 300.15} - \frac{E_g \cdot q}{2k \cdot T}\right) \quad \text{(3.58)}$$

$$N_c = NC0SUB \cdot \left(\frac{T}{300.15}\right)^{3/2} \quad \text{(3.59)}$$

$$V_{bi} = \frac{kT}{q} \cdot \ln\left(\frac{NSD \cdot NBODY}{n_i^2}\right) \quad \text{(3.60)}$$

$$\Phi_B = \frac{kT}{q} \cdot \ln\left(\frac{NBODY}{n_i}\right) \quad \text{(3.61)}$$

$$\Phi_{SUB} = \frac{kT}{q} \cdot \ln\left(\frac{NBG}{n_i}\right) \quad \text{(3.62)}$$

$$\Delta V_{th,temp} = \left(KT1 + \frac{KT1L}{L_{eff}}\right) \cdot \left(\frac{T}{TNOM} - 1\right) + \left(KT2 + \frac{KT2L}{L_{eff}}\right) \cdot \left(\frac{T}{TNOM} - 1\right) \cdot V_{bgx} \quad \text{(3.63)}$$

$$\mu_0(T) = U0_{[L]} \cdot \left(\frac{T}{TNOM}\right)^{UTE_i} + UTL_i \cdot (T - TNOM) \quad \text{(3.64)}$$

$$MEXP(T) = MEXP_{[L]} \cdot (1.0 + TMEXP \cdot (T - TNOM)) \quad \text{(3.65)}$$

$$ETAMOB(T) = ETAMOB_i \cdot [1 + EMOBT_i \cdot (T - TNOM)] \quad \text{(3.66)}$$

$$UA(T) = UA_{[L]} + UA1_i \cdot (T - TNOM) \quad \text{(3.67)}$$

$$UC(T) = UC_{[L]} + UC1 \cdot (T - TNOM) \quad \text{(3.68)}$$

$$UD(T) = UD_{[L]} \cdot \left(\frac{T}{TNOM}\right)^{UD1_i} \quad \text{(3.69)}$$

$$UCS(T) = UCS_i \cdot \left(\frac{T}{TNOM}\right)^{UCSTE_i} \quad \text{(3.70)}$$

$$ETA0(T) = ETA0_{[L]} \cdot (1.0 + TETA0 \cdot (T - TNOM)) \quad \text{(3.71)}$$

$$AT = AT \cdot \left(1.0 + \frac{10^{-6}}{L_{eff}} \cdot ATL\right) \quad \text{(3.72)}$$

$$ATB = ATB \cdot \left(1.0 + \frac{10^{-6}}{L_{eff}} \cdot ATBL\right) \quad \text{(3.73)}$$

$$VSAT(T) = VSAT_{[L]} \cdot (1 - AT \cdot (T - TNOM)) \quad \text{(3.74)}$$

$$VSAT1(T) = VSAT1_{[L]} \cdot (1 - AT \cdot (T - TNOM)) \quad \text{(3.75)}$$

$$VSATB(T) = VSATB_{[L]} \cdot (1 - ATB \cdot (T - TNOM)) \quad \text{(3.76)}$$

$$VSATCV(T) = VSATCV_{[L]} \cdot (1 - AT \cdot (T - TNOM)) \quad \text{(3.77)}$$

$$PTWG(T) = PTWG_{[L]} \cdot (1 - PTWGT \cdot (T - TNOM)) \quad \text{(3.78)}$$

$$BETA0(T) = BETA0_i \cdot \left(\frac{T}{TNOM}\right)^{IIT} \quad \text{(3.79)}$$

$$K0(T) = K0_i + K01_i \cdot (T - TNOM) \quad \text{(3.80)}$$

$$K0SI(T) = K0SI_i + K0SI1_i \cdot (T - TNOM) \quad \text{(3.81)}$$

$$BGIDL(T) = BGIDL_i \cdot (1 + TGIDL \cdot (T - TNOM)) \quad \text{(3.82)}$$

$$BGISL(T) = BGISL_i \cdot (1 + TGISL \cdot (T - TNOM)) \quad \text{(3.83)}$$

$$RDSWMIN(T) = RDSWMIN \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.84)}$$

$$RDSW(T) = RDSW_{[L]} \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.85)}$$

$$RSWMIN(T) = RSWMIN \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.86)}$$

$$RDWMIN(T) = RDWMIN \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.87)}$$

$$RSW(T) = RSW_{[L]} \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.88)}$$

$$RDW(T) = RDW_{[L]} \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.89)}$$

$$R_{s,geo}(T) = R_{s,geo} \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.90)}$$

$$R_{d,geo}(T) = R_{d,geo} \cdot (1 + PRT \cdot (T - TNOM)) \quad \text{(3.91)}$$

$$Ig_{temp} = \left(\frac{T}{TNOM}\right)^{IGT} \quad \text{(3.92)}$$

#### 3.1.6 Front and Back Gate Workfunction Calculation

$$PHIG2_i = \begin{cases} PHIG2 + 0.5 \cdot BG0SUB - \Phi_{SUB} & \text{for N-WELL} \\ PHIG2 - 0.5 \cdot BG0SUB + \Phi_{SUB} & \text{for P-WELL} \end{cases} \quad \text{(3.93)}$$

$$\Phi_{ref} = \begin{cases} EASUB & \text{for NMOS} \\ EASUB + E_g & \text{for PMOS} \end{cases} \quad \text{(3.94)}$$

$$devsign = \begin{cases} 1 & \text{for NMOS} \\ -1 & \text{for PMOS} \end{cases} \quad \text{(3.95)}$$

$$\Delta\Phi_1 = devsign \cdot (PHIG1_i - \Phi_{ref}) \quad \text{(3.96)}$$

$$\Delta\Phi_2 = devsign \cdot (PHIG2_i - \Phi_{ref}) \quad \text{(3.97)}$$

$$\Phi_{sd} = EASUB + \frac{E_g}{2} - devsign \cdot \min\left(\frac{E_g}{2},\; \frac{kT}{q} \cdot \ln\left(\frac{NSD}{n_i}\right)\right) \quad \text{(3.98)}$$

$$V_{fbsd} = devsign \cdot (PHIG1_i - \Phi_{sd}) \quad \text{(3.99)}$$

### 3.2 Terminal Voltages and Pre-conditioning

#### 3.2.1 Terminal Voltages and Vdsx Calculation

$$V_{fgs} = V_{fg} - V_s \quad \text{(3.100)}$$

$$V_{fgd} = V_{fg} - V_d \quad \text{(3.101)}$$

$$V_{bgs} = V_{bg} - V_s \quad \text{(3.102)}$$

$$V_{bgd} = V_{bg} - V_d \quad \text{(3.103)}$$

$$V_{ds} = V_d - V_s \quad \text{(3.104)}$$

$$V_{gfb1} = V_{fgs} - \Delta\Phi_1 \quad \text{(3.105)}$$

$$V_{gfb2} = V_{bgs} - \Delta\Phi_2 \quad \text{(3.106)}$$

$$V_{dsx} = \sqrt{V_{ds}^2 + 0.0004} - 0.02 \quad \text{(3.107)}$$

$$symmetry\_factor = \frac{1}{2}(V_{dsx} - V_{ds}) \quad \text{(3.108)}$$

$$V_{bgx} = V_{bgs} + symmetry\_factor \quad \text{(3.109)}$$

#### 3.2.2 Back Gate Biasing Effect

If p-well:

$$K_{vbg} = KBG0PW - \frac{0.5 \cdot KBG1PW}{\cosh\left(DBGPW \cdot \frac{L_{eff}}{\lambda}\right)} \quad \text{(3.110)}$$

$$K^*_{vbg} = KBG2PW + \frac{1}{2}\left(K_{vbg} - KBG2PW + \sqrt{(K_{vbg} - KBG2PW)^2 + 0.0001}\right) \quad \text{(3.111)}$$

If n-well:

$$K_{vbg} = KBG0NW - \frac{0.5 \cdot KBG1NW}{\cosh\left(DBGNW \cdot \frac{L_{eff}}{\lambda}\right)} \quad \text{(3.112)}$$

$$K^*_{vbg} = KBG2NW + \frac{1}{2}\left(K_{vbg} - KBG2NW + \sqrt{(K_{vbg} - KBG2NW)^2 + 0.0001}\right) \quad \text{(3.113)}$$

$$\gamma_0 = -\frac{C_{ox2} \cdot C_{si}}{(C_{ox2} + C_{si}) \cdot C_{ox1}} \quad \text{(3.114)}$$

$$V_{gfb2,eff} = V_{gfb2n} - symmetry\_factor \quad \text{(3.115)}$$

where $V_{gfb2n} = -1.2$ (clamp limit).

#### 3.2.3 Back-gate Depletion

If P-type back gate:

$$welsign = -1, \quad Vknee1 = VKNEE1PW, \quad Vknee2 = VKNEE2PW, \quad bpfactor = BPFACTORPW$$

If N-type back gate:

$$welsign = 1, \quad Vknee1 = VKNEE1NW, \quad Vknee2 = VKNEE2NW, \quad bpfactor = BPFACTORNW$$

#### 3.2.4 Threshold Voltage Shift due to Substrate Depletion Effect

$$T_0 = \begin{cases} \sqrt{1 + \frac{\max[welsign(V_{bgx} - Vknee1), 0]}{V_{subdep0}}} - 1 & \text{NMOS} \\ \sqrt{1 + \frac{\max[-welsign(V_{bgx} + Vknee1), 0]}{V_{subdep0}}} - 1 & \text{PMOS} \end{cases} \quad \text{(3.125)}$$

$$V_{subdep0} = \frac{1}{2} \cdot \frac{q \cdot NBG_{sub}}{C_{ox2}^2} \quad \text{(3.126)}$$

$$V_{subdep} = V_{subdep0} \cdot T_0^2 \quad \text{(3.127)}$$

$$T_1 = -V_{subdep0} + Vknee2 - 10^{-2} \quad \text{(3.128)}$$

$$V_{subdep} = -Vknee2 + \frac{1}{2}\left(T_1 + \sqrt{T_1^2 + 0.04 \cdot V_{subdep0}}\right) \quad \text{(3.129)}$$

$$\Delta V_{th,vbg} = \begin{cases} \gamma_0 \cdot K^*_{vbg} \cdot [V_{gfb2} - (welsign \cdot bpfactor \cdot V_{subdep}) - V_{gfb2,eff}] & \text{NMOS} \\ \gamma_0 \cdot K^*_{vbg} \cdot [V_{gfb2} + (welsign \cdot bpfactor \cdot V_{subdep}) - V_{gfb2,eff}] & \text{PMOS} \end{cases} \quad \text{(3.130)}$$

### 3.3 Short Channel Effects

#### 3.3.1 Scale Length

$$\lambda_f = \sqrt{TSI \cdot ratio \cdot EOT1} \quad \text{(3.131)}$$

$$\lambda_s = \sqrt{TSI \cdot ratio \cdot EOT1 + \frac{3}{8} \cdot TSI} \quad \text{(3.132)}$$

$$T_0 = \frac{V_{gfb1} \cdot EOT2 \cdot ratio + V_{gfb2} \cdot (EOT1 \cdot ratio + TSI)}{t_{eff}} + symmetry\_factor \quad \text{(3.133)}$$

$$x_\lambda = \frac{1}{2} + \frac{1}{\pi}\tan^{-1}[ASCL + BSCL \cdot T_0] \quad \text{(3.134)}$$

$$\lambda = \lambda_s + x_\lambda(\lambda_f - \lambda_s)$$

#### 3.3.2 Vt Roll-off

$$\phi_{st} = 0.4 + \Phi_B + PHIN_i \quad \text{(3.135)}$$

$$\Delta V_{th,SCE} = -\frac{0.5 \cdot DVT0}{\cosh\left(DVT1 \cdot \frac{L_{eff}}{\lambda}\right) - 1} \cdot (V_{bi} - \phi_{st}) \quad \text{(3.136)}$$

#### 3.3.3 DIBL

$$\Delta V_{th,DIBL} = -\frac{0.5 \cdot (ETA0(T) + ETAB_{[L]} \cdot V_{bgx})}{\cosh\left(DSUB \cdot \frac{L_{eff}}{\lambda}\right) - 1} \cdot (V_{dsx} + 0.01) + ETA1_{[L]} \cdot (V_{dsx} + 0.01)$$

$$- DVTP0 \cdot \frac{1}{\left(1 + DVTP2 \cdot \cosh\left(DSUB \cdot \frac{L_{eff}}{\lambda}\right) - 2\right)} \cdot (V_{dsx} + 0.01)^{DVTP1} \quad \text{(3.137)}$$

#### 3.3.4 Vt Roll on/off at Moderate Channel Lengths

$$\Delta V_{th,RSCE} = K1RSCE \cdot \left[\sqrt{1 + \frac{LPE0}{L_{eff}}} - 1\right] \cdot \phi_{st} \quad \text{(3.138)}$$

#### 3.3.5 Vt Roll on/off at Moderate Channel Lengths and High Vds

$$\Delta V_{th,DSC} = -\frac{DSC0}{DSC1 + L_{eff}} \cdot V_{dsx} \quad \text{(3.139)}$$

#### 3.3.6 Sub-threshold Slope Degradation

$$V_{bgx,pos} = 0.5 \cdot \left(V_{bgx} + \sqrt{V_{bgx}^2 + 4\delta_2^2}\right) \quad \text{(3.140)}$$

$$\delta_1 = (CDSCD + CBGCBGD \cdot V_{bgx,pos}) \cdot V_{dsx} \quad \text{(3.141)}$$

$$\theta_{SCE} = \frac{0.5}{\cosh\left(DVT1 \cdot \frac{L_{eff}}{\lambda}\right) - 1} \quad \text{(3.142)}$$

$$C_{dsc} = CBGCBG0 \cdot V_{bgx} + CBGCBG0P \cdot V_{bgx}^2 + \theta_{SCE} \cdot CDSC + CBGCBG \cdot V_{bgx} + CBGCBGP \cdot V_{bgx}^2 + \delta_1 \quad \text{(3.143)}$$

$$n = 1 + \frac{CIT + C_{dsc}}{C_{ox1} + C_{si} \| C_{ox2}} \quad \text{(3.144)}$$

where $C_{si} \| C_{ox2} = \frac{C_{si} \cdot C_{ox2}}{C_{si} + C_{ox2}}$.

#### 3.3.7 Body Doping Effects

$$\Delta V_{th,nbody} = \frac{q \cdot NBODY \cdot TSI}{C_{ox1}} \left(1 - \frac{0.5 \cdot TSI}{TSI + ratio \cdot EOT2}\right) \quad \text{(3.145)}$$

#### 3.3.8 Cumulative Threshold Voltage Adder

$$\Delta V_{th,all} = \Delta V_{th,vtroll} + \Delta V_{th,dibl} + \Delta V_{th,rsce} + \Delta V_{th,dsc} + \Delta V_{th,nbody} + \Delta V_{th,temp} + \Delta V_{th,vbg} \quad \text{(3.146)}$$

### 3.4 Surface Potential Calculation

Core equations from 1D Poisson's equation:

$$\alpha^2 = k_f(x_f - \varphi_f)^2 - A_0 e^{\varphi_f} \quad \text{(3.147)}$$

$$\alpha^2 = k_b(x_b - \varphi_b)^2 - A_0 e^{\varphi_b} \quad \text{(3.148)}$$

$$\alpha \coth(\alpha/2)(k_f(x_f - \varphi_f) + k_b(x_b - \varphi_b)) + k_f k_b(x_b - \varphi_b)(x_f - \varphi_f) + \alpha^2 = 0 \quad \text{(3.149)}$$

Single-variable equation:

$$f(\varphi_f) = (k_f(x_f - \varphi_f) + \alpha\coth(\alpha/2))(k_f(x_f - \varphi_f) + k_b(x_b - \varphi_b)) - A_0 e^{\varphi_f} = 0 \quad \text{(3.150)}$$

$$\varphi_b = \varphi_f - \ln(k_f(x_f - \varphi_f) + \alpha\coth(\alpha/2)) + \ln\left(\frac{2}{\alpha}\sinh(\alpha/2)\right) \quad \text{(3.151)}$$

Saturation potential (maximum front potential):

$$-4\pi^2 = k_f(x_f - \varphi_{f,max})^2 - A_0 e^{\varphi_{f,max}} \quad \text{(3.152)}$$

Initial guess:

$$\varphi_{f,guess} = \max_s\left(\frac{r \cdot EOT_f \cdot (x_f - x_b)}{T_{fin} + r(EOT_f + EOT_b)} + x_b,\; \varphi_{f,max}\right) \quad \text{(3.153)}$$

Newton update with smooth limiting:

$$\varphi_{f,n} = \varphi_{f,n-1} - \min_s\left(\frac{f}{f'},\; \frac{\varphi_{f,max} - \varphi_{f,n-1}}{2}\right) \quad \text{(3.154)}$$

where $\varphi_{f,0} = \varphi_{f,guess}$.

### 3.5 Integrated Inversion Charge Density

$$qmtot_{s(d)} = \frac{k_f(x_f - \varphi_{fs(d)}) - \alpha\coth(\alpha/2)}{1 - \frac{\alpha^2}{A_0 \sinh^2(\alpha/2)}} \exp(\varphi_{fs(d)}) \quad \text{(3.155)}$$

At source end ($V_{ch} = 0$):

$$\varphi_{fs} = \text{front gate source side surface potential} \quad \text{(3.156)}$$

$$\varphi_{bs} = \text{back gate source side surface potential} \quad \text{(3.157)}$$

$$q_{fronts} = (x_f - \varphi_{fs}) \cdot C_{ox1} \cdot n \cdot v_{tm} \quad \text{(3.158)}$$

$$q_{tots} = qmtot_s \cdot C_{si} \cdot n \cdot v_{tm} \quad \text{(3.159)}$$

$$q_{backs} = q_{tots} - q_{fronts} \quad \text{(3.160)}$$

At drain end ($V_{ch} = V_{ds}$):

$$\varphi_{fd} = \text{front gate drain side surface potential} \quad \text{(3.161)}$$

$$\varphi_{bd} = \text{back gate drain side surface potential} \quad \text{(3.162)}$$

$$q_{frontd} = (x_f - \varphi_{fd}) \cdot C_{ox1} \cdot n \cdot v_{tm} \quad \text{(3.163)}$$

$$q_{totd} = qmtot_d \cdot C_{si} \cdot n \cdot v_{tm} \quad \text{(3.164)}$$

$$q_{backd} = q_{totd} - q_{frontd} \quad \text{(3.165)}$$

### 3.6 Drain Saturation Voltage

#### 3.6.1 Electric Field Calculations

$$q_{is} = \frac{Q_{tots}}{C_{ox1}} \quad \text{(3.166)}$$

$$q_{bs} = \frac{q \cdot NBODY \cdot TSI}{C_{ox1}} \quad \text{(3.167)}$$

Front side:

$$\eta = \begin{cases} \frac{1}{2} \cdot ETAMOB & \text{for NMOS} \\ \frac{1}{3} \cdot ETAMOB & \text{for PMOS} \end{cases} \quad \text{(3.168)}$$

$$T_2 = \eta \cdot \frac{Q_{fronts}}{C_{ox1}} + q_{bs} \quad \text{(3.169)}$$

$$T_3 = \frac{1}{2}\left(T_2 + \sqrt{T_2^2 + 0.001}\right) \quad \text{(3.170)}$$

$$E_{eff,s} = 10^{-8} \cdot \frac{C_{ox1}}{\epsilon_{si}} \cdot T_3 \quad \text{(3.171)}$$

Back side:

$$\eta_2 = \begin{cases} \frac{1}{2} \cdot ETAMOB2 & \text{for NMOS} \\ \frac{1}{3} \cdot ETAMOB2 & \text{for PMOS} \end{cases} \quad \text{(3.172)}$$

$$T_2 = \eta_2 \cdot \frac{Q_{backs}}{C_{ox2}} + q_{bs} \quad \text{(3.173)}$$

$$T_3 = \frac{1}{2}\left(T_2 + \sqrt{T_2^2 + 0.001}\right) \quad \text{(3.174)}$$

$$E_{eff,s2} = 10^{-8} \cdot \frac{C_{ox2}}{\epsilon_{si}} \cdot T_3 \quad \text{(3.175)}$$

#### 3.6.2 Drain Saturation Voltage

$$q_{b0} = \frac{10^{-2}}{C_{ox1}} \quad \text{(3.176)}$$

$$Dmob_s = 1 + (UA(T) + UC(T) \cdot V_{bgs}) \cdot (E_{eff,s})^{EU + EUB \cdot V_{bgs}} + \frac{UD(T)}{UCS(T)} \cdot \left(\frac{q_{is}}{q_{b0}}\right)^{1/2} \quad \text{(3.177)}$$

$$\mu_{eff} = \frac{\mu_0(T)}{Dmob_s} \quad \text{(3.178)}$$

$$Dmob_{s2} = 1 + (UA2 + UC2 \cdot V_{bgs}) \cdot (E_{eff,s2})^{EU2 + EUB2 \cdot V_{bgs}} + \frac{UD2}{UCS2} \cdot \left(\frac{q_{is}}{q_{b0}}\right)^{1/2} \quad \text{(3.179)}$$

$$\mu_{eff2} = \frac{\mu_{02}}{Dmob_{s2}} \quad \text{(3.180)}$$

Charge-based weighting for total mobility:

$$T_0 = V_{gfb1,eff} - \frac{Q_{fronts}}{C_{ox1}} \quad \text{(3.181)}$$

$$T_1 = V_{gfb2} - \Delta V_{th,all} - \frac{Q_{backs}}{C_{ox2}} \quad \text{(3.182)}$$

$$w_1 = \frac{e^{T_0/(n \cdot v_{tm})}}{e^{T_0/(n \cdot v_{tm})} + e^{T_1/(n \cdot v_{tm})}} \quad \text{(3.183)}$$

$$w_2 = \frac{e^{T_1/(n \cdot v_{tm})}}{e^{T_0/(n \cdot v_{tm})} + e^{T_1/(n \cdot v_{tm})}} \quad \text{(3.184)}$$

$$\mu_{total} = w_1 \cdot \mu_{eff} + w_2 \cdot \mu_{eff2} \quad \text{(3.185)}$$

$$E_{sat} = \frac{2 \cdot VSAT(T)}{\mu_{total}} \quad \text{(3.186)}$$

RDSMOD = 0, 2:

$$T_6 = KSATIV \cdot \frac{Q_{tots}}{C_{ox1} + C_{ox2}} + 2V_t \cdot KSUBIV + V_{bgx,pos} \cdot KSATIVB \quad \text{(3.187)}$$

$$a = 2W \cdot VSAT \cdot C_{ox1} \cdot R_{ds}(V) \quad \text{(3.188)}$$

$$b = T_6 + E_{sat}L_{eff} + 3T_6 W_{eff} \cdot VSAT \cdot C_{ox1} \cdot R_{ds}(V) \quad \text{(3.189)}$$

$$c = T_6 \cdot [E_{sat}L_{eff} + T_6 \cdot a] \quad \text{(3.190)}$$

$$V_{dsat} = \frac{b - \sqrt{b^2 - 2ac}}{a} \quad \text{(3.191)}$$

RDSMOD = 1:

$$V_{dsat} = \frac{E_{sat}L_{eff} \cdot \frac{Q_{tots}}{C_{ox1} + C_{ox2}}}{E_{sat}L_{eff} + \frac{Q_{tots}}{C_{ox1} + C_{ox2}}} \quad \text{(3.192)}$$

Effective drain-source voltage (smoothing):

$$V_{ds,eff} = \frac{V_{ds}}{\left(1 + \left(\frac{V_{ds}}{V_{dsat}}\right)^{MEXP}\right)^{1/MEXP}} \quad \text{(3.193)}$$

### 3.7 Average Field, Potential, and Charge Calculation

$$q_{ia} = \frac{Q_{tots} + Q_{totd}}{2C_{ox1}} \quad \text{(3.194)}$$

$$q_{ba} = \frac{q \cdot NBODY \cdot TSI}{C_{ox1}} \quad \text{(3.195)}$$

$$E_{ba} = \frac{E_{bs} + E_{bd}}{2} \quad \text{(3.196)}$$

$$\Delta\psi = \psi_{fd} - \psi_{fs} \quad \text{(3.197)}$$

$$\Delta q_i = \frac{Q_{tots} - Q_{totd}}{C_{ox1}} \quad \text{(3.198)}$$

### 3.8 Quantum Mechanical Effects

$$T_5 = 1 + \frac{q_{ia} + ETAQM_i \cdot q_{ba}}{QM0_i} \quad \text{(3.199)}$$

$$C_{ox,eff} = \begin{cases} \frac{3.9 \cdot \epsilon_0}{\frac{EOT1P}{EPSROX1} \cdot T_5^{PQM_i} + \frac{3.9}{ratio} \cdot cen0} & \text{if QMTCENCV}_i = 1 \\ C_{ox1P} & \text{if QMTCENCV}_i = 0 \end{cases} \quad \text{(3.200)}$$

### 3.9 Mobility Degradation

Front side charge averaging:

$$q_{fronttot} = 0.5 \cdot \frac{Q_{fronts} + Q_{frontd}}{C_{ox1}} \quad \text{(3.201)}$$

$$\Delta q_{front} = \frac{Q_{fronts} - Q_{frontd}}{C_{ox1}} \quad \text{(3.202)}$$

$$q_{ia2} = \begin{cases} q_{fronttot} & \text{for CHARGEWF} = 0 \\ q_{fronttot} + CHARGEWF \cdot (1 - \exp(-a/2)) \cdot 0.5 \cdot \Delta q_{front} & \text{for CHARGEWF} \neq 0 \end{cases} \quad \text{(3.203)}$$

where $a$ is defined in equation (3.188).

Front side mobility:

$$T_2 = \eta \cdot q_{ia2} + q_{ba} \quad \text{(3.204)}$$

$$T_3 = \frac{1}{2}\left(T_2 + \sqrt{T_2^2 + 0.001}\right) \quad \text{(3.205)}$$

$$E_{eff,m} = 10^{-8} \cdot \frac{C_{ox1}}{\epsilon_{si}} \cdot T_3 \quad \text{(3.206)}$$

$$Dmob_0 = 1 + (UA(T) + UC(T) \cdot V_{bgx}) \cdot (E_{eff,m})^{EU + EUB \cdot V_{bgx}} + \frac{UD(T) + UDB \cdot V_{bgx}}{UCS(T)} \cdot \left(\frac{q_{ia}}{q_{b0}}\right)^{1/2} \quad \text{(3.207)}$$

$$Dmob = \frac{Dmob_0}{U0MULT} \quad \text{(3.208)}$$

$$\mu_{eff} = \frac{\mu_0(T)}{Dmob} \quad \text{(3.209)}$$

Back side charge averaging:

$$q_{backtot} = 0.5 \cdot \frac{Q_{backs} + Q_{backd}}{C_{ox2}} \quad \text{(3.210)}$$

$$\Delta q_{back} = \frac{Q_{backs} - Q_{backd}}{C_{ox2}} \quad \text{(3.211)}$$

$$q_{ib2} = \begin{cases} q_{backtot} & \text{for CHARGEWF2} = 0 \\ q_{backtot} + CHARGEWF2 \cdot (1 - \exp(-a/2)) \cdot 0.5 \cdot \Delta q_{back} & \text{for CHARGEWF2} \neq 0 \end{cases} \quad \text{(3.212)}$$

Back side mobility:

$$T_2 = \eta \cdot q_{ib2} + q_{ba} \quad \text{(3.213)}$$

$$T_3 = \frac{1}{2}\left(T_2 + \sqrt{T_2^2 + 0.001}\right) \quad \text{(3.214)}$$

$$E_{eff,m2} = 10^{-8} \cdot \frac{C_{ox2}}{\epsilon_{si}} \cdot T_3 \quad \text{(3.215)}$$

$$Dmob_{02} = 1 + (UA2 + UC2 \cdot V_{bgx}) \cdot (E_{eff,m2})^{EU2 + EUB2 \cdot V_{bgx}} + \frac{UD2 + UDB2 \cdot V_{bgx}}{UCS2} \cdot \left(\frac{q_{ia}}{q_{b0}}\right)^{1/2} \quad \text{(3.216)}$$

$$Dmob_2 = \frac{Dmob_{02}}{U0MULT} \quad \text{(3.217)}$$

$$\mu_{eff2} = \frac{\mu_{02}}{Dmob_2} \quad \text{(3.218)}$$

Total mobility (charge-based weighting):

$$T_0 = V_{gfb1,eff} - \frac{Q_{fronts} + Q_{frontd}}{C_{ox1}} \quad \text{(3.219)}$$

$$T_1 = V_{gfb2} - \Delta V_{th,all} - \frac{Q_{backs} + Q_{backd}}{C_{ox2}} \quad \text{(3.220)}$$

$$w_1 = \frac{e^{T_0/(n \cdot v_{tm})}}{e^{T_0/(n \cdot v_{tm})} + e^{T_1/(n \cdot v_{tm})}} \quad \text{(3.221)}$$

$$w_2 = \frac{e^{T_1/(n \cdot v_{tm})}}{e^{T_0/(n \cdot v_{tm})} + e^{T_1/(n \cdot v_{tm})}} \quad \text{(3.222)}$$

$$\mu_{total} = w_1 \cdot \mu_{eff} + w_2 \cdot \mu_{eff2} \quad \text{(3.223)}$$

### 3.10 Lateral Non-uniform Doping Model

$$M_{nud} = \exp\left(-\frac{K0(T)}{K0SI(T) \cdot q_{ia} + 2.0 \cdot nkT/q}\right) \quad \text{(3.224)}$$

### 3.11 Output Conductance

#### 3.11.1 Channel Length Modulation

$$\frac{1}{C_{clm}} = \begin{cases} PCLM + PCLMG \cdot q_{ia} & \text{for } PCLMG \geq 0 \\ \frac{1}{PCLM} \cdot \frac{1}{1 - PCLMG \cdot q_{ia}} & \text{for } PCLMG < 0 \end{cases} \quad \text{(3.225)}$$

$$M_{clm} = \begin{cases} 1 + \frac{1}{C_{clm}} \ln\left(1 + \frac{V_{ds} - V_{ds,eff}}{V_{dsat} + E_{sat}L} \cdot C_{clm}\right) & \text{for } PCLM > 0 \\ 1 & \text{for } PCLM \leq 0 \end{cases} \quad \text{(3.226)}$$

#### 3.11.2 Output Conductance due to DIBL

$$PVAG_{factor} = \begin{cases} 1 + PVAG \cdot \frac{q_{ia}}{E_{sat}L_{eff}} & \text{for } PVAG > 0 \\ \left(1 - PVAG \cdot \frac{q_{ia}}{E_{sat}L_{eff}}\right)^{-1} & \text{for } PVAG \leq 0 \end{cases} \quad \text{(3.227)}$$

$$\theta_{rout} = \frac{0.5 \cdot PDIBL1}{\cosh\left(DROUT \cdot \frac{L_{eff}}{\lambda}\right) - 1} + PDIBL2 \quad \text{(3.228)}$$

$$VA_{DIBL} = \frac{q_{ia} + 2kT/q}{\theta_{rout}} \cdot \left(1 - \frac{V_{dsat}}{V_{dsat} + q_{ia} + 2kT/q}\right) \cdot PVAG_{factor} \quad \text{(3.229)}$$

$$M_{oc} = 1 + \frac{V_{ds} - V_{ds,eff}}{VA_{DIBL}} \cdot M_{clm} \quad \text{(3.230)}$$

### 3.12 Velocity Saturation

$$E_{sat1} = \frac{2 \cdot VSAT1(T)}{\mu_{total}} \quad \text{(3.231)}$$

$$\delta_{vsat} = DELTAVSAT \quad \text{(3.232)}$$

$$T_0 = 0.8 + VSATB(T) \cdot V_{bgx} \quad \text{(3.233)}$$

$$X_{sat} = 0.2 + \frac{T_0 + \sqrt{T_0^2 + 0.01}}{2} \quad \text{(3.234)}$$

$$D_{vsat} = \sqrt{1 + \left(\frac{\Delta q_i}{E_{sat1} L_{eff} \cdot X_{sat}}\right)^2} + \delta_{vsat} + \frac{1}{2} \cdot (PTWG(T) - PTWGB \cdot V_{bgx,pos} - PTWGB2 \cdot V_{bgx}) \cdot q_{ia} \cdot \Delta q_i^2 \quad \text{(3.235)}$$

### 3.13 Drain Current Model

$$ids_0 = 2 \cdot v_{tm} \cdot C_{si} \cdot n \cdot v_{tm} \cdot (qmtot_s - qmtot_d) + \frac{C_{si} \cdot n \cdot v_{tm} \cdot (qmtot_s^2 - qmtot_d^2)}{2 \cdot C_{ox1}} \quad \text{(3.236)}$$

$$I_{ds0} = \mu_{total} \cdot \frac{W_{eff}}{L_{eff}} \cdot ids_0 \cdot \frac{M_{oc}}{D_r \cdot D_{vsat}} \quad \text{(3.237)}$$

$$I_{ds} = I_{ds0} \cdot NF \quad \text{(3.238)}$$

### 3.14 C-V Model

$$q_{fg} = \frac{q_{fronts} + q_{frontd}}{2} \quad \text{(3.239)}$$

$$q_{bg} = \frac{q_{backs} + q_{backd}}{2} \quad \text{(3.240)}$$

$$q_s = \frac{1}{6} \cdot (2 \cdot q_{tots} + q_{totd}) \quad \text{(3.241)}$$

$$q_d = \frac{1}{6} \cdot (q_{tots} + 2 \cdot q_{totd}) \quad \text{(3.242)}$$

#### 3.14.1 Assign Variables

$$Q_{fg} = \frac{NF}{M_{clm,CV}} \cdot W_{eff} \cdot L_{eff} \cdot q_{fg} \quad \text{(3.243)}$$

$$Q_{bg} = \frac{NF}{M_{clm,CV}} \cdot W_{eff} \cdot L_{eff} \cdot q_{bg} \quad \text{(3.244)}$$

$$Q_{d,intrinsic} = \frac{NF}{M_{clm,CV}} \cdot W_{eff} \cdot L_{eff} \cdot (-q_{d1} - q_{d2}) \quad \text{(3.245)}$$

$$Q_{s,intrinsic} = -Q_{d,intrinsic} - Q_{fg} - Q_{bg} \quad \text{(3.246)}$$

### 3.15 Parasitic Resistances and Capacitance Models

#### 3.15.1 Bias-independent Diffusion Resistance

$$R_{s,geo} = NRS \cdot RSHS \quad \text{(3.247)}$$

$$R_{d,geo} = NRD \cdot RSHD \quad \text{(3.248)}$$

#### 3.15.2 Bias-dependent Extension Resistance

**RDSMOD = 0 (Internal):**

$$R_{ds}(V) = \frac{1}{NF \times W_{eff}^{WR}} \cdot \left(RDSWMIN(T) + \frac{RDSW(T)}{1 + PRWG \cdot q_{ia}}\right) \quad \text{(3.249)}$$

$$D_r = 1.0 + NF \times \mu_{total} \cdot C_{ox1} \cdot \frac{W_{eff}}{L_{eff}} \cdot \frac{ids_0}{\Delta q_i} \cdot \frac{1}{D_{vsat}} \cdot R_{ds}(V) \quad \text{(3.250)}$$

**RDSMOD = 1 (External):**

$$R_{ds}(V) = 0.0 \quad \text{(3.251)}$$

$$V_{gs,eff} = \frac{1}{2}\left(V_{gs} - V_{fbsd} + \sqrt{(V_{gs} - V_{fbsd})^2 + 10^{-4}}\right) \quad \text{(3.252)}$$

$$V_{gd,eff} = \frac{1}{2}\left(V_{gd} - V_{fbsd} + \sqrt{(V_{gd} - V_{fbsd})^2 + 10^{-4}}\right) \quad \text{(3.253)}$$

$$R_{source} = \frac{1}{W_{new}^{WR} \cdot NF} \cdot \left(RSWMIN(T) + \frac{RSW(T)}{1 + PRWG \cdot V_{gs,eff}}\right) + R_{s,geo} \quad \text{(3.254)}$$

$$R_{drain} = \frac{1}{W_{new}^{WR} \cdot NF} \cdot \left(RDWMIN(T) + \frac{RDW(T)}{1 + PRWG \cdot V_{gd,eff}}\right) + R_{d,geo} \quad \text{(3.255)}$$

$$D_r = 1.0 \quad \text{(3.256)}$$

**RDSMOD = 2 (Internal and Geometry dependent):**

$$R_{ds}(V) = \frac{1}{NF \times W_{eff}^{WR}} \cdot \left(R_{s,geo} + R_{d,geo} + RDSWMIN(T) + \frac{RDSW(T)}{1 + PRWG \cdot q_{ia}}\right) \quad \text{(3.257)}$$

$$D_r = 1.0 + NF \times \mu_{total} \cdot C_{ox1} \cdot \frac{W_{eff}}{L_{eff}} \cdot \frac{ids_0}{\Delta q_i} \cdot \frac{1}{D_{vsat}} \cdot R_{ds}(V) \quad \text{(3.258)}$$

#### 3.15.3 Overlap Capacitances

$$V_{fbsd,bg} = devsign \cdot (PHIG2_i - \Phi_{sd}) \quad \text{(3.259)}$$

Source-side overlap:

$$T_0 = V_{fgs} - V_{fbsd} + \delta_1 + PCOVBS1 \cdot (V_{bgs} - V_{fbsd,bg} - PCOVBS0) \quad \text{(3.260)}$$

$$V_{fgs,ov} = \frac{1}{2}\left(T_0 - \sqrt{T_0^2 + 4\delta_1}\right) \quad \text{(3.261)}$$

$$T_1 = NF \cdot W_{eff,CV} \cdot LOVS \cdot C_{ox1} \cdot V_{g,es} \quad \text{(3.262)}$$

$$T_2 = \frac{1}{2} \cdot CKAPPAS \cdot \left(\sqrt{1 - \frac{4 \cdot V_{fgs,ov}}{CKAPPAS}} - 1\right) \quad \text{(3.263)}$$

$$Q_{fgs,ov} = \left\{T_1 + NF \cdot W_{eff,CV} \cdot CGSL \cdot (V_{fgs} - V_{fbsd} - V_{fgs,ov} - T_2)\right\} \cdot devsign \quad \text{(3.264)}$$

Drain-side overlap:

$$T_0 = V_{fgd} - V_{fbsd} + \delta_1 + PCOVBD1 \cdot (V_{bgs} - V_{fbsd,bg} - PCOVBD0) \quad \text{(3.265)}$$

$$V_{fgd,ov} = \frac{1}{2}\left(T_0 - \sqrt{T_0^2 + 4\delta_1}\right) \quad \text{(3.266)}$$

$$T_1 = NF \cdot W_{eff,CV} \cdot LOVD \cdot C_{ox1} \cdot V_{g,ed} \quad \text{(3.267)}$$

$$T_2 = \frac{1}{2} \cdot CKAPPAD \cdot \left(\sqrt{1 - \frac{4 \cdot V_{fgd,ov}}{CKAPPAD}} - 1\right) \quad \text{(3.268)}$$

$$Q_{fgd,ov} = \left\{T_1 + NF \cdot W_{eff,CV} \cdot CGDL \cdot (V_{fgd} - V_{fbsd} - V_{fgd,ov} - T_2)\right\} \cdot devsign \quad \text{(3.269)}$$

#### 3.15.4 Outer Fringe Capacitances

$$Q_{fgs,of} = NF \cdot W_{eff,CV} \cdot CFS \cdot V_{g,es} \quad \text{(3.270)}$$

$$Q_{fgd,of} = NF \cdot W_{eff,CV} \cdot CFD \cdot V_{g,ed} \quad \text{(3.271)}$$

#### 3.15.5 Source/Drain to Substrate Capacitances

$$C_{sdbgsw0} = CSDBGSW \cdot \ln\left(1 + \frac{TSI}{EOT2}\right) \quad \text{(3.272)}$$

$$Q_{sbg} = NF \cdot [C_{ox2} \cdot AS + (PS - W) \cdot C_{sdbgsw0}] \cdot V_{s,bg} \quad \text{(3.273)}$$

$$Q_{dbg} = NF \cdot [C_{ox2} \cdot AD + (PD - W) \cdot C_{sdbgsw0}] \cdot V_{d,bg} \quad \text{(3.274)}$$

### 3.16 Impact Ionization Current

$$I_{ii} = \frac{ALPHA0 + ALPHA1 \cdot L_{eff}}{L_{eff}} \cdot (V_{ds} - V_{ds,eff}) \cdot e^{-BETA0/(V_{ds} - V_{ds,eff})} \cdot I_{ds} \quad \text{(3.275)}$$

### 3.17 Gate Induced Source/Drain Leakage

#### 3.17.1 GIDL

$$I_{gidl} = AGIDL \cdot W_{eff} \cdot NF \cdot \left(\frac{V_{ds} - V_{fgs} - EGIDL + V_{fbsd} + VBGIDL \cdot \gamma_0 \cdot (V_{bgs} - V_{fbsd,bg} - VBEGIDL)}{ratio \cdot EOT1}\right)^{PGIDL}$$

$$\times \exp\left(-\frac{ratio \cdot EOT1 \cdot BGIDL}{V_{ds} - V_{fgs} - EGIDL + V_{fbsd} + VBGIDL \cdot \gamma_0 \cdot (V_{bgs} - V_{fbsd,bg} - VBEGIDL)}\right) \quad \text{(3.276)}$$

#### 3.17.2 GISL

$$I_{gisl} = AGISL \cdot W_{eff} \cdot NF \cdot \left(\frac{V_{ds} - V_{fgs} - EGISL + V_{fbsd} + VBGISL \cdot \gamma_0 \cdot (V_{bgs} - V_{fbsd,bg} - VBEGISL)}{ratio \cdot EOT1}\right)^{PGISL}$$

$$\times \exp\left(-\frac{ratio \cdot EOT1 \cdot BGISL}{V_{ds} - V_{fgs} - EGISL + V_{fbsd} + VBGISL \cdot \gamma_0 \cdot (V_{bgs} - V_{fbsd,bg} - VBEGISL)}\right) \quad \text{(3.277)}$$

### 3.18 Front Gate Tunneling Current

$$Tox_{ratio} = \frac{1}{TOXP^2} \cdot \left(\frac{TOXREF}{TOXP}\right)^{NTOX} \quad \text{(3.278)}$$

#### 3.18.1 Gate-to-Body Current

Igbinv and Igbacc calculated only if IGBMOD = 1.

Constants for Igbinv:

$$A = 3.75956 \times 10^{-7}, \quad B = 9.82222 \times 10^{11} \quad \text{(3.279), (3.280)}$$

$$V_{aux,igbinv} = NIGBINV \cdot \frac{kT}{q} \cdot \ln\left(1 + \exp\left(\frac{q_{ia} - EIGBINV}{NIGBINV \cdot kT/q}\right)\right) \quad \text{(3.281)}$$

$$I_{gbinv} = W_{new} \cdot L_{eff} \cdot NF \cdot A \cdot Tox_{ratio} \cdot V_{gbg} \cdot V_{aux,igbinv} \cdot Ig_{temp}$$

$$\times \exp(-B \cdot TOXP \cdot (AIGBINV - BIGBINV \cdot q_{ia}) \cdot (1 + CIGBINV \cdot q_{ia})) \quad \text{(3.282)}$$

Constants for Igbacc:

$$A = 4.97232 \times 10^{-7}, \quad B = 7.45669 \times 10^{11} \quad \text{(3.283), (3.284)}$$

$$V_{fbzb} = \Delta\Phi_1 - E_g/2 - \phi_B \quad \text{(3.285)}$$

$$T_0 = V_{fbzb} - V_{gbg} \quad \text{(3.286)}$$

$$T_1 = T_0 - 0.02 \quad \text{(3.287)}$$

$$V_{aux,igbacc} = NIGBACC \cdot \frac{kT}{q} \cdot \ln\left(1 + \exp\left(\frac{T_0}{NIGBACC \cdot kT/q}\right)\right) \quad \text{(3.288)}$$

$$V_{oxacc} = \begin{cases} 0.5 \cdot [T_1 + \sqrt{T_1^2 - 0.08 \cdot V_{fbzb}}] & V_{fbzb} \leq 0 \\ 0.5 \cdot [T_1 + \sqrt{T_1^2 + 0.08 \cdot V_{fbzb}}] & V_{fbzb} > 0 \end{cases} \quad \text{(3.289)}$$

$$I_{gbacc} = W_{new} \cdot L_{eff} \cdot NF \cdot A \cdot Tox_{ratio} \cdot V_{gbg} \cdot V_{aux,igbacc} \cdot Ig_{temp}$$

$$\times \exp(-B \cdot TOXP \cdot (AIGBACC - BIGBACC \cdot V_{oxacc}) \cdot (1 + CIGBACC \cdot V_{oxacc})) \quad \text{(3.290)}$$

Partition into source and drain components:

$$T_0 = \tanh\left(\frac{0.6 \cdot q \cdot V_{ds}}{kT}\right) \quad \text{(3.291)}$$

$$W_f = 0.5 + 0.5 \cdot T_0 \quad \text{(3.292)}$$

$$W_r = 0.5 - 0.5 \cdot T_0 \quad \text{(3.293)}$$

$$I_{gbs} = (I_{gbinv} + I_{gbacc}) \cdot W_f \quad \text{(3.294)}$$

$$I_{gbd} = (I_{gbinv} + I_{gbacc}) \cdot W_r \quad \text{(3.295)}$$

#### 3.18.2 Gate-to-Channel Current

Igc calculated only for IGCMOD = 1.

$$A = \begin{cases} 4.97232 \times 10^{-7} & \text{NMOS} \\ 3.42536 \times 10^{-7} & \text{PMOS} \end{cases} \quad \text{(3.296)}$$

$$B = \begin{cases} 7.45669 \times 10^{11} & \text{NMOS} \\ 1.16645 \times 10^{12} & \text{PMOS} \end{cases} \quad \text{(3.297)}$$

$$T_0 = q_{ia} \cdot (V_{gbg} - 0.5 \cdot V_{dsx} + 0.5 \cdot V_{bgs} + 0.5 \cdot V_{bgd}) \quad \text{(3.298)}$$

$$I_{gc0} = W_{new} \cdot L_{eff} \cdot NF \cdot A \cdot Tox_{ratio} \cdot Ig_{temp} \cdot T_0$$

$$\times \exp(-B \cdot TOXP \cdot (AIGC - BIGC \cdot (V_{gfb1} - DIGC \cdot \psi_{fs})) \cdot (1 + CIGC \cdot (V_{gfb1} - DIGC \cdot \psi_{fs}))) \quad \text{(3.299)}$$

$$V_{ds,effx} = \sqrt{V_{ds,eff}^2 + 0.01} - 0.1 \quad \text{(3.300)}$$

$$I_{gcs} = I_{gc0} \cdot \frac{PIGCD \cdot V_{ds,effx} + \exp(PIGCD \cdot V_{ds,effx}) - 1.0 + 10^{-4}}{PIGCD^2 \cdot V_{ds,effx}^2 + 2 \times 10^{-4}} \quad \text{(3.301)}$$

$$I_{gcd} = I_{gc0} \cdot \frac{1.0 - (PIGCD \cdot V_{ds,effx} + 1.0)\exp(-PIGCD \cdot V_{ds,effx}) + 10^{-4}}{PIGCD^2 \cdot V_{ds,effx}^2 + 2 \times 10^{-4}} \quad \text{(3.302)}$$

#### 3.18.3 Gate-to-Source/Drain Current

Igs, Igd calculated only for IGCMOD = 1.

$$A = \begin{cases} 4.97232 \times 10^{-7} & \text{NMOS} \\ 3.42536 \times 10^{-7} & \text{PMOS} \end{cases} \quad \text{(3.303)}$$

$$B = \begin{cases} 7.45669 \times 10^{11} & \text{NMOS} \\ 1.16645 \times 10^{12} & \text{PMOS} \end{cases} \quad \text{(3.304)}$$

$$V'_{gs} = \sqrt{(V_{gs} - V_{fbsd} + DIGS \cdot \gamma_0 \cdot (V_{bgs} - V_{fbsd,bg}))^2 + 10^{-4}} \quad \text{(3.305)}$$

$$V'_{gd} = \sqrt{(V_{gd} - V_{fbsd} + DIGD \cdot \gamma_0 \cdot (V_{bgs} - V_{fbsd,bg}))^2 + 10^{-4}} \quad \text{(3.306)}$$

$$igsd\_mult = Ig_{temp} \cdot \frac{W_{new} \cdot A}{TOXP \cdot POXEDGE} \cdot \left(\frac{TOXREF}{TOXP \cdot POXEDGE}\right)^{NTOX} \quad \text{(3.307)}$$

$$I_{gs} = NF \cdot igsd\_mult \cdot DLCIGS \cdot V_{gs} \cdot V'_{gs}$$

$$\times \exp(-B \cdot TOXP \cdot POXEDGE \cdot (AIGS - BIGS \cdot V'_{gs}) \cdot (1 + CIGS \cdot V'_{gs})) \quad \text{(3.308)}$$

$$I_{gd} = NF \cdot igsd\_mult \cdot DLCIGD \cdot V_{gd} \cdot V'_{gd}$$

$$\times \exp(-B \cdot TOXP \cdot POXEDGE \cdot (AIGD - BIGD \cdot V'_{gd}) \cdot (1 + CIGD \cdot V'_{gd})) \quad \text{(3.309)}$$

### 3.19 Gate Resistance Network

RGATEMOD = 0: No gate resistance.

RGATEMOD = 1 (constant resistance):

$$R_{geltd} = \frac{RSHG \cdot \left(XGW + \frac{W_{eff}}{3 \cdot NGCON}\right)}{NGCON \cdot (L_{eff} - XGL) \cdot NF} \quad \text{(3.310)}$$

### 3.20 Self-Heating Model

$$\frac{1}{R_{th}} = G_{th} = \frac{WTH0 + W_{eff}}{RTH0} \cdot NF \quad \text{(3.311)}$$

$$C_{th} = CTH0 \cdot (WTH0 + W_{eff}) \cdot NF \quad \text{(3.312)}$$

### 3.21 Noise Modeling

#### 3.21.1 Flicker Noise Model

$$E_{sat,noi} = \frac{2 \cdot VSAT(T)}{\mu_{total}} \quad \text{(3.313)}$$

$$L_{eff,noi} = L_{eff} - 2 \cdot LINTNOI \quad \text{(3.314)}$$

$$\Delta L_{clm} = l \cdot \ln\left(\frac{V_{ds} - V_{ds,eff}}{E_{sat,noi}} + EM\right) \cdot \frac{1}{l} \quad \text{(3.315)}$$

$$N_0 = \frac{C_{ox1} \cdot q_{is}}{q} \quad \text{(3.316)}$$

$$N_l = \frac{C_{ox1} \cdot q_{id}}{q} \quad \text{(3.317)}$$

$$N^* = \frac{kT}{q^2}(C_{ox1} + CIT) \quad \text{(3.318)}$$

FNMOD = 1:

$$NOIA_{eff} = \max\left(1,\; \frac{NOIA2}{1 + \left(\frac{q_{ia2}}{QSREF}\right)^{MPOWER}}\right) \cdot NOIA \quad \text{(3.319)}$$

FNMOD = 0:

$$NOIA_{eff} = NOIA \quad \text{(3.320)}$$

$$FN1 = NOIA_{eff} \cdot \ln\left(\frac{N_0 + N^*}{N_l + N^*}\right) + NOIB \cdot (N_0 - N_l) + \frac{NOIC}{2}(N_0^2 - N_l^2) \quad \text{(3.321)}$$

$$FN2 = \frac{NOIA_{eff} + NOIB \cdot N_l + NOIC \cdot N_l^2}{(N_l + N^*)^2} \quad \text{(3.322)}$$

Strong inversion noise density:

$$S_{si} = \frac{kT \cdot q^2 \cdot \mu_{total} \cdot I_{ds}}{C_{ox1}^2 \cdot L_{eff,noi}^2 \cdot 10^{10}} \cdot FN1 + \frac{kT \cdot I_{ds}^2 \cdot \Delta L_{clm}}{W_{eff} \cdot NF \cdot L_{eff,noi}^2 \cdot 10^{10}} \cdot FN2 \quad \text{(3.323)}$$

Subthreshold noise density:

$$S_{wi} = \frac{NOIA_{eff} \cdot kT \cdot I_{ds}^2}{W_{eff} \cdot NF \cdot L_{eff,noi} \cdot 10^{10} \cdot N^{*2}} \quad \text{(3.324)}$$

Total flicker noise:

$$S_{id,flicker} = \frac{S_{wi} \cdot S_{si}}{S_{wi} + S_{si}} \quad \text{(3.325)}$$

#### 3.21.2 Thermal Noise Model

TNOIMOD = 0 (charge-based model):

$$Q_{inv} = |Q_{s,intrinsic} + Q_{d,intrinsic}| \quad \text{(3.326)}$$

$$\frac{i_d^2}{\Delta f} = \begin{cases} \frac{NTNOI \cdot 4kT}{R_{ds}(V) + \frac{L^2}{\mu_{total} \cdot Q_{inv}}} & \text{if RDSMOD} = 0 \\ NTNOI \cdot \frac{4kT}{L_{eff}^2} \cdot \mu_{total} \cdot Q_{inv} & \text{if RDSMOD} = 1 \end{cases} \quad \text{(3.327)}$$

#### Gate Current Shot Noise

$$i_{gs}^2 = 2q(I_{gcs} + I_{gs} + I_{gbs}) \quad \text{(3.328)}$$

$$i_{gd}^2 = 2q(I_{gcd} + I_{gd} + I_{gbd}) \quad \text{(3.329)}$$

#### 3.21.3 Resistor Noise Model

If RDSMOD = 1:

$$\frac{i_{RS}^2}{\Delta f} = 4kT \cdot \frac{1}{R_{source}} \quad \text{(3.330)}$$

$$\frac{i_{RD}^2}{\Delta f} = 4kT \cdot \frac{1}{R_{drain}} \quad \text{(3.331)}$$

If RGATEMOD = 1:

$$\frac{i_{RG}^2}{\Delta f} = 4kT \cdot \frac{1}{R_{geltd}} \quad \text{(3.332)}$$
