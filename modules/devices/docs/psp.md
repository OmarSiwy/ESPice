# PSP 104.0.1 — Parameter & Equation Reference

> Bulk planar MOSFET (surface-potential based)
> NXP Semiconductors / CEA-Leti, October 2024

## Model Topology

PSP is a 4-terminal device (Gate, Drain, Source, Bulk) with an internal parasitic resistance network: gate resistance $R_G$ between G and GP, source resistance $R_{SE}$ between S and SI, drain resistance $R_{DE}$ between DI and D, bulk resistance $R_{BULK}$ between BP and BI, well resistance $R_{WELL}$ between BI and B, and junction-side bulk resistances $R_{JUNS}$ (BS-BI) and $R_{JUND}$ (BD-BI). The intrinsic MOSFET sits between SI, GP, DI, and BP. Two JUNCAP2 junction diodes connect source-bulk and drain-bulk. The model is surface-potential based with explicit surface potential computation at source and drain sides of the channel.

## Physical Constants

| No. | Symbol | Unit | Value | Description |
|-----|--------|------|-------|-------------|
| 1 | $T_0$ | K | 273.15 | Celsius-to-Kelvin offset |
| 2 | $k_B$ | J/K | $1.3806505 \times 10^{-23}$ | Boltzmann constant |
| 3 | $\hbar$ | Js | $1.05457168 \times 10^{-34}$ | Reduced Planck constant |
| 4 | $q$ | C | $1.6021918 \times 10^{-19}$ | Elementary charge |
| 5 | $m_0$ | kg | $9.1093826 \times 10^{-31}$ | Electron rest mass |
| 6 | $\epsilon_0$ | F/m | $8.8541878176 \times 10^{-12}$ | Permittivity of free space |
| 7 | $\epsilon_{r,Si}$ | -- | 11.8 | Relative permittivity of silicon |
| 8 | $QMN$ | $\text{V m}^{4/3}\text{C}^{-2/3}$ | 5.951993 | QM constant for electrons |
| 9 | $QMP$ | $\text{V m}^{4/3}\text{C}^{-2/3}$ | 7.448711 | QM constant for holes |

## Parameters

### Instance Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | L | m | $10^{-6}$ | $10^{-9}$ | -- | Drawn channel length |
| 1 | W | m | $10^{-6}$ | $10^{-9}$ | -- | Drawn channel width (total) |
| 2 | ABSOURCE | m$^2$ | $10^{-12}$ | 0 | -- | Source junction area |
| 3 | LSSOURCE | m | $10^{-6}$ | 0 | -- | STI-edge part of source junction perimeter |
| 4 | LGSOURCE | m | $10^{-6}$ | 0 | -- | Gate-edge part of source junction perimeter |
| 5 | ABDRAIN | m$^2$ | $10^{-12}$ | 0 | -- | Drain junction area |
| 6 | LSDRAIN | m | $10^{-6}$ | 0 | -- | STI-edge part of drain junction perimeter |
| 7 | LGDRAIN | m | $10^{-6}$ | 0 | -- | Gate-edge part of drain junction perimeter |
| 8 | AS | m$^2$ | $10^{-12}$ | 0 | -- | Source junction area (alternative) |
| 9 | PS | m | $10^{-6}$ | 0 | -- | Source STI-edge perimeter (alternative) |
| 10 | AD | m$^2$ | $10^{-12}$ | 0 | -- | Drain junction area (alternative) |
| 11 | PD | m | $10^{-6}$ | 0 | -- | Drain STI-edge perimeter (alternative) |
| 12 | JW | m | $10^{-6}$ | 0 | -- | Junction width |
| 13 | DELVTO | V | 0 | -- | -- | Threshold voltage shift |
| 14 | FACTUO | -- | 1 | 0 | -- | Zero-field mobility pre-factor |
| 15 | DELVTOEDGE | V | 0 | -- | -- | Threshold voltage shift of edge transistor |
| 16 | FACTUOEDGE | -- | 1 | 0 | -- | Zero-field mobility pre-factor of edge transistor |
| 17 | SA | m | 0 | -- | -- | Distance OD-edge to poly (source side) |
| 18 | SB | m | 0 | -- | -- | Distance OD-edge to poly (drain side) |
| 19 | SD | m | 0 | -- | -- | Distance between neighboring fingers |
| 20 | SCA | -- | 0 | 0 | -- | First distribution function integral for WPE |
| 21 | SCB | -- | 0 | 0 | -- | Second distribution function integral for WPE |
| 22 | SCC | -- | 0 | 0 | -- | Third distribution function integral for WPE |
| 23 | SC | m | 0 | -- | -- | Distance OD-edge to nearest well edge |
| 24 | NRS | -- | 0 | -- | -- | Number of squares of source diffusion |
| 25 | NRD | -- | 0 | -- | -- | Number of squares of drain diffusion |
| 26 | NGCON | -- | 1 | 1 | 2 | Number of gate contacts |
| 27 | XGW | m | $10^{-7}$ | -- | -- | Distance gate contact to channel edge |
| 28 | NF | -- | 1 | 1 | -- | Number of fingers |
| 29 | MULT | -- | 1 | 0 | -- | Number of devices in parallel |
| 30 | TRISE / DTEMP | K | 0 | -- | -- | Device temperature offset |

### Switches and Control Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | LEVEL | -- | 104 | -- | -- | Model selection parameter |
| 1 | TYPE | -- | 1 | -1 | 1 | Channel type: 1=NMOS, -1=PMOS |
| 2 | TR / TREF | C | 21 | -273 | -- | Reference temperature |
| 3 | DTA | K | 0 | -- | -- | Temperature offset w.r.t. ambient |
| 4 | PARAMCHK | -- | 0 | -- | -- | Level of clip-warning info |
| 5 | SWGEO | -- | 1 | 0 | 1 | Flag for geometrical model (0=local, 1=global/binning) |
| 6 | SWIGATE | -- | 0 | 0 | 1 | Flag for gate current |
| 7 | SWIMPACT | -- | 0 | 0 | 1 | Flag for impact ionization current |
| 8 | SWGIDL | -- | 0 | 0 | 1 | Flag for GIDL/GISL current |
| 9 | SWJUNCAP | -- | 0 | 0 | 3 | Flag for JUNCAP |
| 10 | SWJUNASYM | -- | 0 | 0 | 1 | Flag for asymmetric junctions |
| 11 | SWNUD | -- | 0 | 0 | 2 | Flag for NUD-effect |
| 12 | SWEDGE | -- | 0 | 0 | 1 | Flag for edge transistor drain current |
| 13 | SWDELVTAC | -- | 0 | 0 | 1 | Flag for separate charge calculation |
| 14 | SWQSAT | -- | 0 | 0 | 1 | Flag for separate charge calc in saturation |
| 15 | SWQPART | -- | 0 | 0 | 1 | Flag for drain/source charge partitioning (0=linear, 1=source) |
| 16 | QMC | -- | 1 | 0 | -- | Quantum-mechanical correction factor |
| 17 | SWOPREXT | -- | 0 | 0 | 1 | Include R_DE, R_SE, R_G in OP output |
| 18 | SWOPPMOS | -- | 0 | 0 | 1 | Switch for PMOS convention |
| 19 | SWOPDRAIN | -- | 0 | 0 | 1 | Switch for drain configuration |

### Electrical Geometry Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 20 | LVARO | m | 0 | -- | -- | Geometry-independent $\Delta L_{PS}$ |
| 21 | LVARL | -- | 0 | -- | -- | Length dependence of $\Delta L_{PS}$ |
| 22 | LVARW | -- | 0 | -- | -- | Width dependence of $\Delta L_{PS}$ |
| 23 | LAP | m | 0 | -- | -- | Effective channel length reduction per side |
| 24 | WVARO | m | 0 | -- | -- | Geometry-independent $\Delta W_{OD}$ |
| 25 | WVARL | -- | 0 | -- | -- | Length dependence of $\Delta W_{OD}$ |
| 26 | WVARW | -- | 0 | -- | -- | Width dependence of $\Delta W_{OD}$ |
| 27 | WOT | m | 0 | -- | -- | Effective channel width reduction per side |
| 28 | DLQ | m | 0 | -- | -- | Effective channel length offset for CV |
| 29 | DWQ | m | 0 | -- | -- | Effective channel width offset for CV |

### Flat-Band Voltage Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 30 | VFB | V | -1 | -- | -- | Flat-band voltage at TR (local) |
| 31 | VFBO | V | -1 | -- | -- | Geometry-independent part |
| 32 | VFBL | V | 0 | -- | -- | Length dependence |
| 33 | VFBLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 34 | VFBW | V | 0 | -- | -- | Width dependence |
| 35 | VFBLW | V | 0 | -- | -- | Area dependence |
| 36 | POVFB | V | -1 | -- | -- | Binning: geom. independent |
| 37 | PLVFB | V | 0 | -- | -- | Binning: length dependence |
| 38 | PWVFB | V | 0 | -- | -- | Binning: width dependence |
| 39 | PLWVFB | V | 0 | -- | -- | Binning: area dependence |
| 40 | STVFB | V/K | $5 \times 10^{-4}$ | -- | -- | Temperature dependence of VFB (local) |
| 41 | STVFBO | V/K | $5 \times 10^{-4}$ | -- | -- | Geometry-independent part |
| 42 | STVFBL | V/K | 0 | -- | -- | Length dependence |
| 43 | STVFBW | V/K | 0 | -- | -- | Width dependence |
| 44 | STVFBLW | V/K | 0 | -- | -- | Area dependence |
| 45 | POSTVFB | V/K | $5 \times 10^{-4}$ | -- | -- | Binning: geom. independent |
| 46 | PLSTVFB | V/K | 0 | -- | -- | Binning: length dependence |
| 47 | PWSTVFB | V/K | 0 | -- | -- | Binning: width dependence |
| 48 | PLWSTVFB | V/K | 0 | -- | -- | Binning: area dependence |
| 49 | ST2VFB | K$^{-1}$ | 0 | -- | -- | Quadratic temperature dependence of VFB (local) |
| 50 | ST2VFBO | K$^{-1}$ | 0 | -- | -- | Geometry-independent parameter |

### Process Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 51 | TOX | m | $2 \times 10^{-9}$ | $10^{-10}$ | -- | Gate oxide thickness (local) |
| 52 | TOXO | m | $2 \times 10^{-9}$ | $10^{-10}$ | -- | Geometry-independent |
| 53 | EPSROX | -- | 3.9 | 1 | -- | Relative permittivity of gate dielectric (local) |
| 54 | EPSROXO | -- | 3.9 | 1 | -- | Geometry-independent |
| 55 | NEFF | m$^{-3}$ | $5 \times 10^{23}$ | $10^{20}$ | $10^{26}$ | Effective substrate doping (local) |
| 56 | NSUBO | m$^{-3}$ | $4 \times 10^{23}$ | $10^{20}$ | -- | Geometry-independent |
| 57 | NSUBW | -- | 0 | -- | -- | Width dependence (segregation) |
| 58 | WSEG | m | $10^{-8}$ | $10^{-10}$ | -- | Characteristic length for segregation |
| 59 | NPCK | m$^{-3}$ | $10^{24}$ | 0 | -- | Pocket doping level |
| 60 | NPCKW | -- | 0 | -- | -- | Width dependence of NPCK |
| 61 | WSEGP | m | $10^{-8}$ | $10^{-10}$ | -- | Characteristic length for pocket segregation |
| 62 | LPCK | m | $10^{-8}$ | $10^{-10}$ | -- | Characteristic length for lateral doping profile |
| 63 | LPCKW | -- | 0 | -- | -- | Width dependence of LPCK |
| 64 | FOL1 | -- | 0 | -- | -- | First order length dependence of short channel body effect |
| 65 | FOL2 | -- | 0 | -- | -- | Second order length dependence |
| 66 | PONEFF | m$^{-3}$ | $5 \times 10^{23}$ | -- | -- | Binning: geom. independent |
| 67 | PLNEFF | m$^{-3}$ | 0 | -- | -- | Binning: length dependence |
| 68 | PWNEFF | m$^{-3}$ | 0 | -- | -- | Binning: width dependence |
| 69 | PLWNEFF | m$^{-3}$ | 0 | -- | -- | Binning: area dependence |
| 70 | GFACNUD | -- | 1 | 0.01 | -- | Body-factor change due to NUD-effect (local) |
| 71 | GFACNUDO | -- | 1 | -- | -- | Geometry-independent |
| 72 | GFACNUDL | -- | 0 | -- | -- | Length dependence |
| 73 | GFACNUDLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 74 | GFACNUDW | -- | 0 | -- | -- | Width dependence |
| 75 | GFACNUDLW | -- | 0 | -- | -- | Area dependence |
| 76 | POGFACNUD | -- | 1 | -- | -- | Binning: geom. independent |
| 77 | PLGFACNUD | -- | 0 | -- | -- | Binning: length dependence |
| 78 | PWGFACNUD | -- | 0 | -- | -- | Binning: width dependence |
| 79 | PLWGFACNUD | -- | 0 | -- | -- | Binning: area dependence |
| 80 | VSBNUD | V | 0 | 0 | -- | Lower VSB-value for NUD (local) |
| 81 | VSBNUDO | V | 0 | 0 | -- | Geometry-independent |
| 82-85 | POVSBNUD..PLWVSBNUD | V | 0 | -- | -- | Binning parameters for VSBNUD |
| 86 | DVSBNUD | V | 1 | 0.1 | -- | VSB-range for NUD (local) |
| 87 | DVSBNUDO | V | 1 | 0.1 | -- | Geometry-independent |
| 88 | DPHIB | V | 0 | -- | -- | Offset voltage of $\phi_B$ (local) |
| 89 | DPHIBO | V | 0 | -- | -- | Geometry-independent |
| 90 | DPHIBL | V | 0 | -- | -- | Length dependence |
| 91 | DPHIBLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 92 | DPHIBW | V | 0 | -- | -- | Width dependence |
| 93 | DPHIBLW | V | 0 | -- | -- | Area dependence |
| 94-97 | PODPHIB..PLWDPHIB | V | 0 | -- | -- | Binning parameters for DPHIB |
| 98 | NP | m$^{-3}$ | $10^{26}$ | 0 | -- | Gate polysilicon doping (local) |
| 99 | NPO | m$^{-3}$ | $10^{26}$ | -- | -- | Geometry-independent |
| 100 | NPL | -- | 0 | -- | -- | Length dependence |
| 101-104 | PONP..PLWNP | m$^{-3}$ | 0 | -- | -- | Binning parameters for NP |
| 105 | TOXOV | m | $2 \times 10^{-9}$ | $10^{-10}$ | -- | Overlap oxide thickness (local) |
| 106 | TOXOVO | m | $2 \times 10^{-9}$ | $10^{-10}$ | -- | Geometry-independent |
| 107 | TOXOVD | m | $2 \times 10^{-9}$ | $10^{-10}$ | -- | Overlap oxide thickness drain side (local) |
| 108 | TOXOVDO | m | $2 \times 10^{-9}$ | $10^{-10}$ | -- | Geometry-independent |
| 109 | LOV | m | $10^{-8}$ | 0 | -- | Overlap length for gate/drain and gate/source |
| 110 | LOVD | m | $10^{-8}$ | 0 | -- | Overlap length for gate/drain |
| 111 | NOV | m$^{-3}$ | $5 \times 10^{25}$ | $10^{23}$ | $10^{27}$ | Effective doping of overlap region (local) |
| 112 | NOVO | m$^{-3}$ | $5 \times 10^{25}$ | $10^{23}$ | $10^{27}$ | Geometry-independent |
| 113-116 | PONOV..PLWNOV | m$^{-3}$ | 0 | -- | -- | Binning parameters for NOV |
| 117 | NOVD | m$^{-3}$ | $5 \times 10^{25}$ | $10^{23}$ | $10^{27}$ | Effective doping overlap region drain side (local) |
| 118 | NOVDO | m$^{-3}$ | $5 \times 10^{25}$ | $10^{23}$ | $10^{27}$ | Geometry-independent |
| 119-122 | PONOVD..PLWNOVD | m$^{-3}$ | 0 | -- | -- | Binning parameters for NOVD |

### Interface States Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 123 | CT | -- | 0 | 0 | -- | Interface states factor (local) |
| 124 | CTO | -- | 0 | -- | -- | Geometry-independent |
| 125 | CTL | -- | 0 | -- | -- | Length dependence |
| 126 | CTLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 127 | CTW | -- | 0 | -- | -- | Width dependence |
| 128 | CTLW | -- | 0 | -- | -- | Area dependence |
| 129-132 | POCT..PLWCT | -- | 0 | -- | -- | Binning parameters for CT |
| 133 | CTB | -- | 0 | 0 | 0.5 | Bulk voltage dependence of interface states (local) |
| 134 | CTBO | -- | 0 | 0 | 0.5 | Geometry-independent |
| 135-138 | POCTB..PLWCTB | -- | 0 | -- | -- | Binning parameters for CTB |
| 139 | CTG | -- | 0 | 0 | 1 | Gate voltage dependence of interface states (local) |
| 140 | CTGO | -- | 0 | 0 | 1 | Geometry-independent |
| 141-144 | POCTG..PLWCTG | -- | 0 | -- | -- | Binning parameters for CTG |
| 145 | STCT | -- | 1 | -- | -- | Temperature dependence of CT (local) |
| 146 | STCTO | -- | 1 | -- | -- | Geometry-independent |
| 147-150 | POSTCT..PLWSTCT | -- | 0 | -- | -- | Binning parameters for STCT |

### DIBL Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 151 | CF | -- | 0 | 0 | -- | DIBL parameter (local) |
| 152 | CFL | -- | 0 | -- | -- | Length dependence |
| 153 | CFLEXP | -- | 2 | -- | -- | Exponent for length dependence |
| 154 | CFW | -- | 0 | -- | -- | Width dependence |
| 155-158 | POCF..PLWCF | -- | 0 | -- | -- | Binning parameters for CF |
| 159 | CFB | V$^{-1}$ | 0 | 0 | 1 | Bulk voltage dependence of DIBL (local) |
| 160 | CFBO | V$^{-1}$ | 0 | 0 | 1 | Geometry-independent |
| 161-164 | POCFB..PLWCFB | V$^{-1}$ | 0 | -- | -- | Binning parameters for CFB |
| 165 | CFD | V$^{-1}$ | 0 | 0 | -- | Drain voltage dependence of DIBL (local) |
| 166 | CFDO | V$^{-1}$ | 0 | 0 | -- | Geometry-independent |
| 167-170 | POCFD..PLWCFD | V$^{-1}$ | 0 | -- | -- | Binning parameters for CFD |

### Subthreshold Slope Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 171 | PSCE | -- | 0 | 0 | -- | Subthreshold slope coefficient for SCE (local) |
| 172 | PSCEL | -- | 0 | -- | -- | Length dependence |
| 173 | PSCELEXP | -- | 2 | -- | -- | Exponent for length dependence |
| 174 | PSCEW | -- | 0 | -- | -- | Width dependence |
| 175-178 | POPSCE..PLWPSCE | -- | 0 | -- | -- | Binning parameters for PSCE |
| 179 | PSCEB | V$^{-1}$ | 0 | 0 | 1 | Bulk voltage dependence of PSCE (local) |
| 180 | PSCEBO | V$^{-1}$ | 0 | 0 | 1 | Geometry-independent |
| 181-184 | POPSCEB..PLWPSCEB | V$^{-1}$ | 0 | -- | -- | Binning parameters for PSCEB |
| 185 | PSCED | V$^{-1}$ | 0 | 0 | -- | Drain voltage dependence of PSCE (local) |
| 186 | PSCEDO | V$^{-1}$ | 0 | 0 | -- | Geometry-independent |
| 187-190 | POPSCED..PLWPSCED | V$^{-1}$ | 0 | -- | -- | Binning parameters for PSCED |

### Mobility Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 191 | BETN | m$^2$/V/s | $3 \times 10^{-2}$ | 0 | -- | Product of W/L ratio and zero-field mobility at TR (local) |
| 192 | UO | m$^2$/V/s | $3 \times 10^{-2}$ | 0 | -- | Zero-field mobility at TR |
| 193 | FBET1 | -- | 0 | -- | -- | Relative mobility decrease (first lateral profile) |
| 194 | FBET1W | -- | 0 | -- | -- | Width dependence of FBET1 |
| 195 | LP1 | m | $10^{-8}$ | $10^{-10}$ | -- | Mobility characteristic length (first lateral profile) |
| 196 | LP1W | -- | 0 | -- | -- | Width dependence of LP1 |
| 197 | FBET2 | -- | 0 | -- | -- | Relative mobility decrease (second lateral profile) |
| 198 | LP2 | m | $10^{-8}$ | $10^{-10}$ | -- | Mobility characteristic length (second lateral profile) |
| 199 | BETW1 | -- | 0 | -- | -- | First higher-order width scaling of BETN |
| 200 | BETW2 | -- | 0 | -- | -- | Second higher-order width scaling of BETN |
| 201 | WBET | m | $10^{-9}$ | $10^{-10}$ | -- | Characteristic width for BETN scaling |
| 202-205 | POBETN..PLWBETN | m$^2$/V/s | 0 | -- | -- | Binning parameters for BETN |
| 206 | STBET | -- | 1 | -- | -- | Temperature dependence of BETN (local) |
| 207 | STBETO | -- | 1 | -- | -- | Geometry-independent |
| 208-214 | STBETL..PLWSTBET | -- | 0 | -- | -- | Scaling/binning parameters for STBET |
| 215 | MUE | m/V | 0.5 | 0 | -- | High field mobility reduction coefficient (local) |
| 216 | MUEO | m/V | 0.5 | -- | -- | Geometry-independent |
| 217 | MUEW | -- | 0 | -- | -- | Width dependence |
| 218-221 | POMUE..PLWMUE | m/V | 0 | -- | -- | Binning parameters for MUE |
| 222 | STMUE | -- | 0 | -- | -- | Temperature dependence of MUE (local) |
| 223 | STMUEO | -- | 0 | -- | -- | Geometry-independent |
| 224 | THEMU | -- | 1.5 | 0 | -- | High field mobility reduction exponent (local) |
| 225 | THEMUO | -- | 1.5 | 0 | -- | Geometry-independent |
| 226-229 | POTHEMU..PLWTHEMU | -- | 0 | -- | -- | Binning parameters for THEMU |
| 230 | STTHEMU | -- | 1.5 | -- | -- | Temperature dependence of THEMU (local) |
| 231 | STTHEMUO | -- | 1.5 | -- | -- | Geometry-independent |
| 232 | CS | -- | 0 | 0 | -- | Coulomb scattering parameter (local) |
| 233 | CSO | -- | 0 | -- | -- | Geometry-independent |
| 234 | CSL | -- | 0 | -- | -- | Length dependence |
| 235 | CSLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 236 | CSW | -- | 0 | -- | -- | Width dependence |
| 237 | CSLW | -- | 0 | -- | -- | Area dependence |
| 238-241 | POCS..PLWCS | -- | 0 | -- | -- | Binning parameters for CS |
| 242 | STCS | -- | 0 | -- | -- | Temperature dependence of CS (local) |
| 243 | STCSO | -- | 0 | -- | -- | Geometry-independent |
| 244 | THECS | -- | 2 | 0 | -- | Coulomb scattering exponent (local) |
| 245 | THECSO | -- | 2 | 0 | -- | Geometry-independent |
| 246-249 | POTHECS..PLWTHECS | -- | 0 | -- | -- | Binning parameters for THECS |
| 250 | STTHECS | -- | 0 | -- | -- | Temperature dependence of THECS (local) |
| 251 | STTHECSO | -- | 0 | -- | -- | Geometry-independent |
| 252 | XCOR | V$^{-1}$ | 0 | 0 | -- | Non-universality parameter (local) |
| 253 | XCORO | V$^{-1}$ | 0 | -- | -- | Geometry-independent |
| 254-260 | XCORL..PLWXCOR | -- | 0 | -- | -- | Scaling/binning parameters for XCOR |
| 261 | STXCOR | -- | 0 | -- | -- | Temperature dependence of XCOR (local) |
| 262 | STXCORO | -- | 0 | -- | -- | Geometry-independent |
| 263 | FETA | -- | 1 | 0 | -- | Effective field parameter (local) |
| 264 | FETAO | -- | 1 | 0 | -- | Geometry-independent |

### Series Resistance Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 265 | RS | Ohm | 50 | 0 | -- | Source/drain series resistance (local) |
| 266 | RSW1 | Ohm | 50 | -- | -- | First order width dependence |
| 267 | RSW2 | -- | 0 | -- | -- | Second order width dependence |
| 268-271 | PORS..PLWRS | Ohm | 0 | -- | -- | Binning parameters for RS |
| 272 | STRS | -- | 1 | -- | -- | Temperature dependence of RS (local) |
| 273 | STRSO | -- | 1 | -- | -- | Geometry-independent |
| 274-277 | POSTRS..PLWSTRS | -- | 0 | -- | -- | Binning parameters for STRS |
| 278 | RSB | V$^{-1}$ | 0 | -0.5 | 1 | Bulk voltage dependence of RS (local) |
| 279 | RSBO | V$^{-1}$ | 0 | -0.5 | 1 | Geometry-independent |
| 280-283 | PORSB..PLWRSB | V$^{-1}$ | 0 | -- | -- | Binning parameters for RSB |
| 284 | RSG | V$^{-1}$ | 0 | -0.5 | -- | Gate voltage dependence of RS (local) |
| 285 | RSGO | V$^{-1}$ | 0 | -0.5 | -- | Geometry-independent |
| 286-289 | PORSG..PLWRSG | V$^{-1}$ | 0 | -- | -- | Binning parameters for RSG |

### Velocity Saturation Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 290 | THESAT | V$^{-1}$ | 0.3 | 0 | -- | Velocity saturation parameter (local) |
| 291 | THESATO | V$^{-1}$ | 0 | -- | -- | Geometry-independent |
| 292 | THESATL | V$^{-1}$ | 0.3 | -- | -- | Length dependence |
| 293 | THESATLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 294 | THESATW | -- | 0 | -- | -- | Width dependence |
| 295 | THESATLW | -- | 0 | -- | -- | Area dependence |
| 296-299 | POTHESAT..PLWTHESAT | V$^{-1}$ | 0 | -- | -- | Binning parameters for THESAT |
| 300 | STTHESAT | -- | 1 | -- | -- | Temperature dependence of THESAT (local) |
| 301-308 | STTHESATO..PLWSTTHESAT | -- | 0 | -- | -- | Scaling/binning parameters for STTHESAT |
| 309 | THESATB | V$^{-1}$ | 0 | -0.5 | 1 | Bulk voltage dependence of velocity saturation (local) |
| 310 | THESATBO | V$^{-1}$ | 0 | -0.5 | 1 | Geometry-independent |
| 311-314 | POTHESATB..PLWTHESATB | V$^{-1}$ | 0 | -- | -- | Binning parameters for THESATB |
| 315 | THESATG | V$^{-1}$ | 0 | -0.5 | -- | Gate voltage dependence of velocity saturation (local) |
| 316 | THESATGO | V$^{-1}$ | 0 | -0.5 | -- | Geometry-independent |
| 317-320 | POTHESATG..PLWTHESATG | V$^{-1}$ | 0 | -- | -- | Binning parameters for THESATG |
| 321 | THESATT | -- | 1 | 0.01 | -- | Threshold for gate voltage dependence of velocity saturation (local) |
| 322 | THESATTO | -- | 1 | 0.01 | -- | Geometry-independent |

### Linear-Saturation Transition Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 323 | AX | -- | 8 | 2 | -- | Linear/saturation transition factor (local) |
| 324 | AXO | -- | 16 | -- | -- | Geometry-independent |
| 325 | AXL | -- | 1 | 0 | -- | Length dependence |
| 326-329 | POAX..PLWAX | -- | 0 | -- | -- | Binning parameters for AX |

### Channel Length Modulation (CLM) Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 330 | ALP | -- | 0.01 | 0 | -- | CLM pre-factor (local) |
| 331 | ALPL | -- | 0.01 | -- | -- | Length dependence |
| 332 | ALPLEXP | -- | 1 | -- | -- | Exponent for length dependence |
| 333 | ALPW | -- | 0 | -- | -- | Width dependence |
| 334-337 | POALP..PLWALP | -- | 0 | -- | -- | Binning parameters for ALP |
| 338 | ALP1 | V | 0 | 0 | -- | CLM enhancement above threshold (local) |
| 339 | ALP1L1 | V | 0 | -- | -- | Length dependence |
| 340 | ALP1LEXP | -- | 0.5 | -- | -- | Exponent for length dependence |
| 341 | ALP1L2 | -- | 0 | 0 | -- | Second order length dependence |
| 342 | ALP1W | -- | 0 | -- | -- | Width dependence |
| 343-346 | POALP1..PLWALP1 | V | 0 | -- | -- | Binning parameters for ALP1 |
| 347 | ALP2 | V$^{-1}$ | 0 | 0 | -- | CLM enhancement below threshold (local) |
| 348-355 | ALP2L1..PLWALP2 | -- | 0 | -- | -- | Scaling/binning parameters for ALP2 |
| 356 | VP | V | 0.05 | $10^{-10}$ | -- | CLM logarithmic dependence factor (local) |
| 357 | VPO | V | 0.05 | $10^{-10}$ | -- | Geometry-independent |

### Impact Ionization Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 358 | A1 | -- | 1 | 0 | -- | Impact ionization pre-factor (local) |
| 359 | A1O | -- | 1 | -- | -- | Geometry-independent |
| 360-365 | A1L..PLWA1 | -- | 0 | -- | -- | Scaling/binning parameters for A1 |
| 366 | A2 | V | 10 | 0 | -- | Impact ionization exponent (local) |
| 367 | A2O | V | 10 | 0 | -- | Geometry-independent |
| 368 | STA2 | V | 0 | -- | -- | Temperature dependence of A2 (local) |
| 369-373 | STA2O..PLWSTA2 | V | 0 | -- | -- | Scaling/binning parameters for STA2 |
| 374 | A3 | -- | 1 | 0 | -- | Saturation-voltage dependence of II (local) |
| 375-381 | A3O..PLWA3 | -- | 0 | -- | -- | Scaling/binning parameters for A3 |
| 382 | A4 | V$^{-1/2}$ | 0 | 0 | -- | Bulk voltage dependence of II (local) |
| 383-389 | A4O..PLWA4 | V$^{-1/2}$ | 0 | -- | -- | Scaling/binning parameters for A4 |

### Gate Current Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 390 | GCO | -- | 0 | -10 | 10 | Gate tunnelling energy adjustment (local) |
| 391 | GCOO | -- | 0 | -10 | 10 | Geometry-independent |
| 392 | IGINV | A | 0 | 0 | -- | Gate channel current pre-factor (local) |
| 393 | IGINVLW | A | 0 | 0 | -- | Area dependence |
| 394-397 | POIGINV..PLWIGINV | A | 0 | -- | -- | Binning parameters |
| 398 | IGOV | A | 0 | 0 | -- | Gate overlap current pre-factor (local) |
| 399 | IGOVW | A | 0 | 0 | -- | Width dependence |
| 400-403 | POIGOV..PLWIGOV | A | 0 | -- | -- | Binning parameters |
| 404 | IGOVD | A | 0 | 0 | -- | Gate overlap current pre-factor drain side (local) |
| 405 | IGOVDW | A | 0 | 0 | -- | Width dependence |
| 406-409 | POIGOVD..PLWIGOVD | A | 0 | -- | -- | Binning parameters |
| 410 | STIG | -- | 2 | -- | -- | Temperature dependence of IGINV/IGOV (local) |
| 411 | STIGO | -- | 2 | -- | -- | Geometry-independent |
| 412-415 | POSTIG..PLWSTIG | -- | 0 | -- | -- | Binning parameters |
| 416 | GC2 | -- | 0.375 | 0 | 10 | Gate current slope factor (local) |
| 417 | GC2O | -- | 0.375 | 0 | 10 | Geometry-independent |
| 418 | GC3 | -- | 0.063 | -2 | 2 | Gate current curvature factor (local) |
| 419 | GC3O | -- | 0.063 | -2 | 2 | Geometry-independent |
| 420 | GC2OV | -- | GC2 | 0 | 10 | Gate overlap current slope factor (local) |
| 421 | GC2OVO | -- | GC2O | 0 | 10 | Geometry-independent |
| 422 | GC3OV | -- | GC3 | -2 | 2 | Gate overlap current curvature factor (local) |
| 423 | GC3OVO | -- | GC3O | -2 | 2 | Geometry-independent |
| 424 | CHIB | V | 3.1 | 1 | -- | Tunnelling barrier height (local) |
| 425 | CHIBO | V | 3.1 | 1 | -- | Geometry-independent |

### GIDL Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 426 | AGIDL | A/V$^3$ | 0 | 0 | -- | GIDL pre-factor (local) |
| 427 | AGIDLW | A/V$^3$ | 0 | 0 | -- | Width dependence |
| 428-431 | POAGIDL..PLWAGIDL | A/V$^3$ | 0 | -- | -- | Binning parameters |
| 432 | AGIDLD | A/V$^3$ | 0 | 0 | -- | GIDL pre-factor drain side (local) |
| 433-437 | AGIDLDW..PLWAGIDLD | A/V$^3$ | 0 | -- | -- | Scaling/binning parameters |
| 438 | BGIDL | V | 41 | 0 | -- | GIDL probability factor (local) |
| 439 | BGIDLO | V | 41 | 0 | -- | Geometry-independent |
| 440 | BGIDLD | V | 41 | 0 | -- | GIDL probability factor drain side (local) |
| 441 | BGIDLDO | V | 41 | 0 | -- | Geometry-independent |
| 442 | STBGIDL | V/K | 0 | -- | -- | Temperature dependence of BGIDL (local) |
| 443-447 | STBGIDLO..PLWSTBGIDL | V/K | 0 | -- | -- | Scaling/binning parameters |
| 448 | STBGIDLD | V/K | 0 | -- | -- | Temperature dependence of BGIDLD (local) |
| 449-453 | STBGIDLDO..PLWSTBGIDLD | V/K | 0 | -- | -- | Scaling/binning parameters |
| 454 | CGIDL | -- | 0 | -- | -- | Bulk voltage dependence of GIDL (local) |
| 455 | CGIDLO | -- | 0 | -- | -- | Geometry-independent |
| 456 | CGIDLD | -- | 0 | -- | -- | Bulk voltage dependence of GIDL drain side (local) |
| 457 | CGIDLDO | -- | 0 | -- | -- | Geometry-independent |

### Charge Model Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 458 | COX | F | $10^{-14}$ | 0 | -- | Oxide capacitance for intrinsic channel (local) |
| 459-462 | POCOX..PLWCOX | F | 0 | -- | -- | Binning parameters |
| 463 | DELVTAC | V | 0 | -- | -- | $\phi_B$ offset in separate charge calc (local) |
| 464-472 | DELVTACO..PLWDELVTAC | V | 0 | -- | -- | Scaling/binning parameters |
| 473 | FACNEFFAC | -- | 1 | 0 | -- | Pre-factor for NEFF in separate charge calc (local) |
| 474-481 | FACNEFFACO..PLWFACNEFFAC | -- | 0 | -- | -- | Scaling/binning parameters |
| 482 | THESATAC | V$^{-1}$ | THESAT | 0 | -- | Velocity saturation for charge model (SWQSAT=1) (local) |
| 483-491 | THESATACO..PLWTHESATAC | V$^{-1}$ | -- | -- | -- | Scaling/binning parameters |
| 492 | AXAC | -- | AX | 2 | -- | Linear/saturation transition for charge model (local) |
| 493-498 | AXACO..PLWAXAC | -- | -- | -- | -- | Scaling/binning parameters |
| 499 | ALPAC | -- | 0 | -- | -- | CLM pre-factor of charge model (local) |
| 500-506 | ALPACL..PLWALPAC | -- | 0 | -- | -- | Scaling/binning parameters |
| 507 | ALP1AC | V | 0 | 0 | -- | CLM enhancement above threshold for charge model (local) |
| 508-515 | ALP1ACL1..PLWALP1AC | V | 0 | -- | -- | Scaling/binning parameters |
| 516 | CGOV | F | $10^{-15}$ | 0 | -- | Oxide cap for gate-drain/source overlap (local) |
| 517-520 | POCGOV..PLWCGOV | F | 0 | -- | -- | Binning parameters |
| 521 | CGOVD | F | $10^{-15}$ | 0 | -- | Oxide cap for gate-drain overlap (local) |
| 522-525 | POCGOVD..PLWCGOVD | F | 0 | -- | -- | Binning parameters |
| 526 | FCGOVACC | -- | 0.5 | 0 | 1 | Factor for overlap cap in accumulation (local) |
| 527 | FCGOVACCO | -- | 0.5 | 0 | 1 | Geometry-independent |
| 528 | FCGOVACCD | -- | 0.5 | 0 | 1 | Factor for overlap cap in accumulation drain side (local) |
| 529 | FCGOVACCDO | -- | 0.5 | 0 | 1 | Geometry-independent |
| 530 | CGOVACCG | -- | 1 | 0.1 | 1 | Gate voltage dependence of overlap cap in accumulation (local) |
| 531 | CGOVACCGO | -- | 1 | 0.1 | 1 | Geometry-independent |
| 532 | CGBOV | F | $10^{-15}$ | 0 | -- | Oxide cap for gate-bulk overlap (local) |
| 533 | CGBOVL | F | $10^{-15}$ | 0 | -- | Length dependence |
| 534-537 | POCGBOV..PLWCGBOV | F | 0 | -- | -- | Binning parameters |
| 538 | CINR | F | $5 \times 10^{-16}$ | 0 | -- | Inner fringe capacitance (local) |
| 539 | CINRW | F | $5 \times 10^{-16}$ | 0 | -- | Width dependence |
| 540-543 | POCINR..PLWCINR | F | 0 | -- | -- | Binning parameters |
| 544 | CINRD | F | $5 \times 10^{-16}$ | 0 | -- | Inner fringe cap drain side (local) |
| 545-549 | CINRWD..PLWCINRD | F | 0 | -- | -- | Scaling/binning parameters |
| 550 | DVFBINR | V | 0 | -- | -- | Flat-band voltage offset of inner fringe caps (local) |
| 551 | DVFBINRO | V | 0 | -- | -- | Geometry-independent |
| 552 | FCINRDEP | -- | 0.3 | 0 | 1 | Bias dependence of inner fringe in depletion (local) |
| 553 | FCINRDEPO | -- | 0.3 | 0 | 1 | Geometry-independent |
| 554 | FCINRACC | -- | 0.5 | 0 | -- | Bias dependence of inner fringe in accumulation (local) |
| 555 | FCINRACCO | -- | 0.5 | 0 | -- | Geometry-independent |
| 556 | AXINR | -- | 0.4 | 0.1 | 4 | Accumulation/depletion transition factor of inner fringe (local) |
| 557 | AXINRO | -- | 0.4 | 0.1 | 4 | Geometry-independent |
| 558 | CFR | F | $10^{-15}$ | 0 | -- | Outer fringe capacitance (local) |
| 559-563 | CFRW..PLWCFR | F | 0 | -- | -- | Scaling/binning parameters |
| 564 | CFRD | F | $10^{-15}$ | 0 | -- | Outer fringe cap drain side (local) |
| 565-569 | CFRDW..PLWCFRD | F | 0 | -- | -- | Scaling/binning parameters |

### Noise Model Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 570 | FNT | -- | 1 | 0 | -- | Thermal noise coefficient (local) |
| 571 | FNTO | -- | 1 | 0 | -- | Geometry-independent |
| 572 | FNTEXC | -- | 0 | 0 | -- | Excess noise coefficient (local) |
| 573 | FNTEXCL | -- | 0 | 0 | -- | Length dependence |
| 574-577 | POFNTEXC..PLWFNTEXC | -- | 0 | -- | -- | Binning parameters |
| 578 | NFA | V$^{-1}$m$^{-4}$ | $8 \times 10^{22}$ | 0 | -- | First flicker noise coefficient (local) |
| 579 | NFALW | V$^{-1}$m$^{-4}$ | $8 \times 10^{22}$ | 0 | -- | Width dependence |
| 580-583 | PONFA..PLWNFA | V$^{-1}$m$^{-4}$ | 0 | -- | -- | Binning parameters |
| 584 | NFB | V$^{-1}$m$^{-2}$ | $3 \times 10^{7}$ | 0 | -- | Second flicker noise coefficient (local) |
| 585-589 | NFBLW..PLWNFB | V$^{-1}$m$^{-2}$ | 0 | -- | -- | Scaling/binning parameters |
| 590 | NFC | V$^{-1}$ | 0 | 0 | -- | Third flicker noise coefficient (local) |
| 591-595 | NFCLW..PLWNFC | V$^{-1}$ | 0 | -- | -- | Scaling/binning parameters |
| 596 | EF | -- | 1 | 0 | -- | Flicker noise frequency exponent (local) |
| 597 | EFO | -- | 1 | 0 | -- | Geometry-independent |
| 598 | LINTNOI | m | 0 | -- | -- | Length offset for flicker noise |
| 599 | ALPNOI | -- | 2 | -- | -- | Exponent for length offset |

### Edge Transistor Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 600 | WEDGE | m | $10^{-8}$ | 0 | -- | Electrical width of edge transistor per side |
| 601 | WEDGEW | m | 0 | 0 | -- | Main transistor width dependence of WEDGE |
| 602-607 | VFBEDGE..PLWVFBEDGE | V | -- | -- | -- | Flat-band voltage of edge transistors and scaling |
| 608-616 | STVFBEDGE..PLWSTVFBEDGE | V/K | -- | -- | -- | Temperature dependence of VFBEDGE and scaling |
| 617-626 | DPHIBEDGE..PLWDPHIBEDGE | V | -- | -- | -- | $\phi_B$ offset for edge transistors and scaling |
| 627-636 | NEFFEDGE..PLWNEFFEDGE | m$^{-3}$ | -- | -- | -- | Effective doping of edge transistors and scaling |
| 637-644 | CTEDGE..PLWCTEDGE | -- | -- | -- | -- | Interface states of edge transistors and scaling |
| 645-652 | BETNEDGE..PLWBETNEDGE | m$^2$/V/s | -- | -- | -- | Mobility of edge transistors and scaling |
| 653-661 | STBETEDGE..PLWSTBETEDGE | -- | -- | -- | -- | Temperature dependence of BETNEDGE and scaling |
| 662-669 | PSCEEDGE..PLWPSCEEDGE | -- | -- | -- | -- | Subthreshold slope of edge transistors and scaling |
| 670-675 | PSCEBEDGE..PLWPSCEBEDGE | V$^{-1}$ | -- | -- | -- | Bulk voltage dependence for edge PSCE |
| 676-681 | PSCEDEDGE..PLWPSCEDEDGE | V$^{-1}$ | -- | -- | -- | Drain voltage dependence for edge PSCE |
| 682-689 | CFEDGE..PLWCFEDGE | -- | -- | -- | -- | DIBL of edge transistors and scaling |
| 690-695 | CFBEDGE..PLWCFBEDGE | V$^{-1}$ | -- | -- | -- | Bulk voltage dependence of edge DIBL |
| 696-701 | CFDEDGE..PLWCFDEDGE | V$^{-1}$ | -- | -- | -- | Drain voltage dependence of edge DIBL |
| 702-703 | FNTEDGE, FNTEDGEO | -- | 1 | 0 | -- | Thermal noise of edge transistors |
| 704-721 | NFAEDGE..PLWNFCEDGE | -- | -- | -- | -- | Flicker noise of edge transistors |
| 722-723 | EFEDGE, EFEDGEO | -- | 1 | 0 | -- | Flicker noise frequency exponent of edge transistors |

### Self Heating Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | RTH | K/W | 0 | 0 | -- | Thermal resistance (local) |
| 1 | RTHO | K/W | 0 | -- | -- | Geometry-independent |
| 2 | RTHW1 | K/W | 0 | -- | -- | Width dependence |
| 3 | RTHW2 | -- | 0 | -- | -- | Offset in width dependence |
| 4 | RTHLW | -- | 0 | -- | -- | Length-correction to width dependence |
| 5-8 | PORTH..PLWRTH | K/W | 0 | -- | -- | Binning parameters |
| 9 | CTH | J/K | 0 | 0 | -- | Thermal capacitance (local) |
| 10 | CTHO | J/K | 0 | -- | -- | Geometry-independent |
| 11-17 | CTHW1..PLWCTH | J/K | 0 | -- | -- | Scaling/binning parameters |
| 18 | STRTH | -- | 0 | -- | -- | Temperature dependence of RTH (local) |
| 19-23 | STRTHO..PLWSTRTH | -- | 0 | -- | -- | Scaling/binning parameters |

### NQS Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | SWNQS | -- | 0 | 0 | 9 | Switch for NQS effects / number of collocation points |
| 1 | MUNQS | -- | 1 | 0 | -- | Relative mobility for NQS modeling (local) |
| 2 | MUNQSO | -- | 1 | 0 | -- | Geometry-independent |
| 3-6 | POMUNQS..PLWMUNQS | -- | 0 | -- | -- | Binning parameters |

### Stress Model Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | SAREF | m | $10^{-6}$ | $10^{-9}$ | -- | Reference SA distance |
| 1 | SBREF | m | $10^{-6}$ | $10^{-9}$ | -- | Reference SB distance |
| 2 | WLOD | m | 0 | -- | -- | Width parameter |
| 3 | KUO | m | 0 | -- | -- | Mobility degradation/enhancement coefficient |
| 4 | KVSAT | m | 0 | -1 | 1 | Saturation velocity degradation/enhancement |
| 5 | KVSATAC | m | KVSAT | -1 | 1 | Saturation velocity for charge model (SWQSAT=1) |
| 6 | TKUO | -- | 0 | -- | -- | Temperature coefficient of KUO |
| 7 | LKUO | m$^{LLODKUO}$ | 0 | -- | -- | Length dependence of KUO |
| 8 | WKUO | m$^{WLODKUO}$ | 0 | -- | -- | Width dependence of KUO |
| 9 | PKUO | m$^{LLODKUO+WLODKUO}$ | 0 | -- | -- | Cross-term dependence of KUO |
| 10 | LLODKUO | -- | 0 | 0 | -- | Length parameter for mobility stress |
| 11 | WLODKUO | -- | 0 | 0 | -- | Width parameter for mobility stress |
| 12 | KVTHO | Vm | 0 | -- | -- | Threshold shift parameter |
| 13 | LKVTHO | m$^{LLODVTH}$ | 0 | -- | -- | Length dependence of KVTHO |
| 14 | WKVTHO | m$^{WLODVTH}$ | 0 | -- | -- | Width dependence of KVTHO |
| 15 | PKVTHO | m$^{LLODVTH+WLODVTH}$ | 0 | -- | -- | Cross-term dependence of KVTHO |
| 16 | LLODVTH | -- | 0 | 0 | -- | Length parameter for Vth stress |
| 17 | WLODVTH | -- | 0 | 0 | -- | Width parameter for Vth stress |
| 18 | STETAO | m | 0 | -- | -- | ETAO shift factor for Vth change |
| 19 | LODETAO | -- | 1 | 0 | -- | ETAO shift modification factor |

### Well Proximity Effect Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | SCREF | m | $10^{-6}$ | 0 | -- | Reference distance OD-edge to well edge |
| 1 | WEB | -- | 0 | -- | -- | Coefficient for SCB |
| 2 | WEC | -- | 0 | -- | -- | Coefficient for SCC |
| 3 | KVTHOWEO | -- | 0 | -- | -- | Geometry-independent threshold shift |
| 4 | KVTHOWEL | -- | 0 | -- | -- | Length dependence |
| 5 | KVTHOWEW | -- | 0 | -- | -- | Width dependence |
| 6 | KVTHOWELW | -- | 0 | -- | -- | Area dependence |
| 7 | KUOWEO | -- | 0 | -- | -- | Geometry-independent mobility degradation |
| 8 | KUOWEL | -- | 0 | -- | -- | Length dependence |
| 9 | KUOWEW | -- | 0 | -- | -- | Width dependence |
| 10 | KUOWELW | -- | 0 | -- | -- | Area dependence |

### JUNCAP2 Junction Parameters (Source-Bulk)

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | TRJ | C | 21 | $T_{min}$ | -- | Junction reference temperature |
| 1 | SWJUNEXP | -- | 0 | 0 | 1 | Flag for JUNCAP2 Express |
| 2 | IFACTOR | -- | 1 | 0 | -- | Multiplier for current |
| 3 | CFACTOR | -- | 1 | 0 | -- | Multiplier for depletion capacitance |
| 4 | IMAX | A | $10^3$ | $10^{-12}$ | -- | Maximum forward current |
| 5 | FREV | -- | $10^3$ | $10^3$ | $10^{10}$ | Reverse breakdown current limitation |
| 6 | CJORBOT | F/m$^2$ | $10^{-3}$ | $10^{-12}$ | -- | Zero-bias cap/area (bottom) |
| 7 | CJORSTI | F/m | $10^{-9}$ | $10^{-18}$ | -- | Zero-bias cap/length (STI-edge) |
| 8 | CJORGAT | F/m | $10^{-9}$ | $10^{-18}$ | -- | Zero-bias cap/length (gate-edge) |
| 9 | VBIRBOT | V | 1 | $V_{bi,low}$ | -- | Built-in voltage (bottom) |
| 10 | VBIRSTI | V | 1 | $V_{bi,low}$ | -- | Built-in voltage (STI-edge) |
| 11 | VBIRGAT | V | 1 | $V_{bi,low}$ | -- | Built-in voltage (gate-edge) |
| 12 | PBOT | -- | 0.5 | 0.05 | 0.95 | Grading coefficient (bottom) |
| 13 | PSTI | -- | 0.5 | 0.05 | 0.95 | Grading coefficient (STI-edge) |
| 14 | PGAT | -- | 0.5 | 0.05 | 0.95 | Grading coefficient (gate-edge) |
| 15-17 | PHIGBOT..PHIGGAT | V | 1.16 | -- | -- | Zero-temperature bandgap voltages |
| 18-20 | IDSATRBOT..IDSATRGAT | A/m$^2$ or A/m | $10^{-12}$/$10^{-18}$ | 0 | -- | Saturation current densities |
| 21-23 | CSRHBOT..CSRHGAT | A/m$^3$ or A/m$^2$ | $10^2$/$10^{-4}$ | 0 | -- | SRH prefactors |
| 24 | XJUNSTI | m | $10^{-7}$ | $10^{-9}$ | -- | Junction depth (STI-edge) |
| 25 | XJUNGAT | m | $10^{-7}$ | $10^{-9}$ | -- | Junction depth (gate-edge) |
| 26-28 | CTATBOT..CTATGAT | A/m$^3$ or A/m$^2$ | $10^2$/$10^{-4}$ | 0 | -- | Trap-assisted tunneling prefactors |
| 29-31 | MEFFTATBOT..MEFFTATGAT | -- | 0.25 | 0.01 | -- | Effective mass for TAT |
| 32-34 | CBBTBOT..CBBTGAT | AV$^{-3}$ or AV$^{-3}$m | $10^{-12}$/$10^{-18}$ | 0 | -- | Band-to-band tunneling prefactors |
| 35-37 | FBBTRBOT..FBBTRGAT | Vm$^{-1}$ | $10^9$ | -- | -- | BBT normalization fields |
| 38-40 | STFBBTBOT..STFBBTGAT | K$^{-1}$ | $-10^{-3}$ | -- | -- | BBT temperature scaling |
| 41-43 | VBRBOT..VBRGAT | V | 10 | 0.1 | -- | Breakdown voltages |
| 44-46 | PBRBOT..PBRGAT | V | 4 | 0.1 | -- | Breakdown onset tuning |
| 47 | VJUNREF | V | 2.5 | 0.5 | -- | Typical max source-bulk junction voltage |
| 48 | FJUNQ | V | 0.03 | 0 | -- | Fraction for neglecting cap components |

JUNCAP2 drain-bulk junction parameters (Nos. 49-91, suffix 'D') mirror the source-bulk parameters above and are activated when SWJUNASYM=1.

### Parasitic Resistance Parameters

| No. | Parameter | Unit | Default | Min | Max | Description |
|-----|-----------|------|---------|-----|-----|-------------|
| 0 | RG | Ohm | 0 | 0 | -- | Gate resistance (local) |
| 1 | RGO | Ohm | 0 | -- | -- | Geometry-independent |
| 2 | RINT | Ohm m$^2$ | 0 | 0 | -- | Contact resistance silicide-poly |
| 3 | RVPOLY | Ohm m$^2$ | 0 | 0 | -- | Vertical poly resistance |
| 4 | RSHG | Ohm/sq | 0 | 0 | -- | Gate electrode sheet resistance |
| 5 | DLSIL | m | 0 | -- | -- | Silicide extension over gate |
| 6 | RSE | Ohm | 0 | 0 | -- | External source resistance (local) |
| 7 | RSH | Ohm/sq | 0 | 0 | -- | Sheet resistance of source diffusion |
| 8 | RDE | Ohm | 0 | 0 | -- | External drain resistance (local) |
| 9 | RSHD | Ohm/sq | 0 | 0 | -- | Sheet resistance of drain diffusion |
| 10 | RBULK | Ohm | 0 | 0 | -- | Bulk resistance (local) |
| 11 | RBULKO | Ohm | 0 | 0 | -- | Geometry-independent |
| 12 | RWELL | Ohm | 0 | 0 | -- | Well resistance (local) |
| 13 | RWELLO | Ohm | 0 | 0 | -- | Geometry-independent |
| 14 | RJUNS | Ohm | 0 | 0 | -- | Source-side bulk resistance (local) |
| 15 | RJUNSO | Ohm | 0 | 0 | -- | Geometry-independent |
| 16 | RJUND | Ohm | 0 | 0 | -- | Drain-side bulk resistance (local) |
| 17 | RJUNDO | Ohm | 0 | 0 | -- | Geometry-independent |

## Equations

### Effective Length and Width

$$L_{EN} = 10^{-6}, \quad W_{EN} = 10^{-6}, \quad A_{EN} = 10^{-12}$$

$$W_f = W / NF$$

$$\Delta L_{PS} = LVARO \cdot \left(1 + LVARL \cdot \frac{L_{EN}}{L}\right) \cdot \left(1 + LVARW \cdot \frac{W_{EN}}{W_f}\right)$$

$$\Delta W_{OD} = WVARO \cdot \left(1 + WVARL \cdot \frac{L_{EN}}{L}\right) \cdot \left(1 + WVARW \cdot \frac{W_{EN}}{W_f}\right)$$

$$L_E = L + \Delta L_{PS} - 2 \cdot LAP$$

$$W_E = W_f + \Delta W_{OD} - 2 \cdot WOT$$

$$A_E = L_E \cdot W_E$$

$$L_{E,CV} = L + \Delta L_{PS} - 2 \cdot LAP + DLQ$$

$$W_{E,CV} = W_f + \Delta W_{OD} - 2 \cdot WOT + DWQ$$

### Internal Parameters and Temperature Scaling (Section 4.1)

Transistor temperatures:

$$T_{KR} = T_0 + TR, \quad T_{KA} = T_0 + TA + DTA + TRISE$$

$$T_{KD} = T_{KA} + V_{dt}, \quad \Delta T = T_{KD} - T_{KR}$$

$$\phi_T = k_B T_{KD}/q, \quad \phi_{TA} = k_B T_{KA}/q$$

Flat-band voltage with temperature:

$$\mathbf{VFB} = VFB + STVFB \cdot \Delta T \cdot (1 + ST2VFB \cdot \Delta T) + DELVTO$$

Bandgap and intrinsic concentration:

$$E_g/q = 1.179 - 9.025 \times 10^{-5} \cdot T_{KD} - 3.05 \times 10^{-7} \cdot T_{KD}^2$$

$$n_i = 2.5 \times 10^{25} \cdot r_T^{3/4} \cdot (T_{KD}/300)^{3/2} \cdot \exp\!\left(-\frac{E_g/q}{2\phi_T}\right)$$

Surface potential $\phi_B$:

$$\phi_{B,dc}^{cl} = \max\!\left(DPHIB + 2\phi_T \ln(NEFF/n_i),\; 0.05\right)$$

Oxide capacitance per unit area:

$$C_{ox} = \epsilon_{ox}/TOX, \quad \epsilon_{ox} = EPSROX \cdot \epsilon_0$$

Body-effect coefficient:

$$\gamma_{0,dc} = \sqrt{2 q \epsilon_{Si} \cdot NEFF}/C_{ox}, \quad G_{0,dc} = \gamma_{0,dc}/\sqrt{\phi_T}$$

Quantum-mechanical corrections:

$$q_q = 0.4 \cdot QMC \cdot QMN \cdot C_{ox}^{2/3} \quad \text{(NMOS)}$$

$$\phi_{B,dc} = \phi_{B,dc}^{cl} + 0.75 \cdot q_q \cdot q_{b0,dc}^{2/3}$$

$$G_{0,dc} = G_{0,dc}^{cl} \cdot \left(1 + q_q \cdot q_{b0,dc}^{-1/3}\right)$$

Polysilicon depletion parameter:

$$k_P = 2\phi_T \cdot C_{ox}^2 / (q \epsilon_{Si} \cdot NP_2) \quad \text{if } NP > 0$$

Mobility parameters:

$$\beta = FACTUO \cdot BETN \cdot C_{ox} \cdot (T_{KR}/T_{KD})^{STBET}$$

$$\theta_\mu = THEMU \cdot (T_{KR}/T_{KD})^{STTHEMU}$$

$$\mu_E = MUE \cdot (T_{KR}/T_{KD})^{STMUE}$$

$$\mathbf{Xcor} = XCOR \cdot (T_{KR}/T_{KD})^{STXCOR}$$

$$\mathbf{CS} = CS \cdot (T_{KR}/T_{KD})^{STCS}$$

Series resistance:

$$R_s = RS \cdot (T_{KR}/T_{KD})^{STRS}, \quad \theta_R = 2\beta R_s$$

Velocity saturation:

$$\theta_{sat} = THESAT \cdot (T_{KR}/T_{KD})^{STTHESAT}$$

Linear-saturation transition:

$$a_r = \frac{2^{-2/AX+1} - 2}{\max(4 \cdot 2^{-2/AX+1} - 1,\; 10^{-4})}$$

Gate tunneling parameter:

$$B = \frac{4}{3}\cdot\frac{TOX}{\hbar}\sqrt{2qm_0 \cdot CHIB} = 6.830909 \times 10^9 \cdot TOX \cdot \sqrt{CHIB}$$

### Current Model -- Conditioning of Terminal Voltages (Section 4.2.1)

$$V_{GB}^* = V_{GB} - \mathbf{VFB}$$

$$V_{dsx} = \frac{V_{DS}^2}{\sqrt{V_{DS}^2 + 0.01} + 0.1}$$

$$V_{SB,dc}^* = V_{SB} - MINA(\phi_V, 0, a_\phi) + \phi_X^*$$

### Interface States (Section 4.2.2)

$$\phi_{T,ct} = \phi_T \cdot \left(1 + CT \cdot \exp\!\left(CTG \cdot \frac{x_{ct}}{x_{ct,max}} + 1\right)\right)$$

### Short Channel Effects (Section 4.2.3)

$$\Delta\phi_T^* = PSCE \cdot (1 + PSCED \cdot V_{dsx}) \cdot (1 + PSCEB \cdot V_{sbx})$$

$$\phi_T^* = \phi_{T,ct} \cdot (1 + \Delta\phi_T^*)$$

$$G = G_0 \cdot (\phi_T / \phi_T^*)$$

DIBL:

$$V_{ds}^* = \frac{2V_{dsx}}{1 + \sqrt{1 + CFD \cdot V_{dsx}}}$$

$$\Delta\phi_B = CF \cdot V_{ds}^* \cdot (1 + CFB \cdot V_{sbx})$$

### Surface Potential at Source Side (Section 4.2.4)

The surface potential $x_s$ is computed from an explicit approximation using Newton-like iterations with the implicit equation:

$$(x_g - x_s)^2 = G^2[x_s - 1 + \exp(-x_s) + \Delta_{ns}(1/\exp(-x_s) - x_s - 1 - \chi(x_s))]$$

where $x_g = V_{GB}^*/\phi_T^*$, $\Delta_{ns} = \exp(-x_{ns})$, and $\chi(y) = y^2/(2+y^2)$.

Three regimes are handled: $x_g < -x_{mrg}$ (accumulation), $|x_g| \le x_{mrg}$ (flat-band), $x_g > x_{mrg}$ (depletion/inversion), using the $\sigma_1$ and $\sigma_2$ auxiliary functions.

### Drain Saturation Voltage (Section 4.2.5)

Inversion charge at source:

$$q_{is} = \frac{G^2 \phi_T^* D_s}{x_{gs} + G\sqrt{P_s}}$$

Mobility reduction:

$$G_{mob,s} = \frac{1 + (\mu_E \cdot E_{eff,s})^{\theta_\mu} + CS \cdot \left(\frac{q_{bs}}{q_{is}+q_{bs}}\right)^{\theta_{cs}} + \rho_s}{\mu_x}$$

Saturation voltage:

$$y_{sat} = \frac{\phi_T^* \cdot \theta_{sat,s}^* \cdot x_\infty / \sqrt{2}}{\sqrt{1 + \phi_T^* \cdot \theta_{sat,s}^* \cdot x_\infty / \sqrt{2}}} \quad \text{(PMOS)}$$

$$V_{dsat} = \phi_T^* \cdot \left(x_{sat} - \ln\!\left(1 + x_{sat} \cdot \frac{x_{sat} - 2a_{sat}}{G^2 D_s}\right)\right)$$

### Effective Drain Voltage (Section 4.2.6)

$$V_{dse} = \frac{2\sqrt{1+a_r} \cdot V_{DS}}{\left(\sqrt{1+a_r} \cdot \frac{V_{DS}}{V_{dsat}} - 1 + \sqrt{a_r}\right) + \left(\sqrt{1+a_r} \cdot \frac{V_{DS}}{V_{dsat}} + 1 + \sqrt{a_r}\right)}$$

Smooth clipping of $V_{DS}$ to $V_{dsat}$ with transition parameter $a_r$.

### Surface Potential at Drain Side (Section 4.2.7)

Computed identically to source side with $x_{nd} = (\phi_B + V_{SB}^* + V_{dse})/\phi_T^*$ and $\Delta_{nd} = \Delta_{ns} \cdot k_{ds}$ where $k_{ds} = \exp(-V_{dse}/\phi_T^*)$.

### Channel Length Modulation (Section 4.2.11)

$$S_1 = \ln\!\left(\frac{1 + (V_{DS} - \Delta\psi)/VP}{1 + (V_{dse} - \Delta\psi)/VP}\right)$$

$$\Delta L/L = \left(ALP + \frac{ALP1}{q_{im}^*}\right)\cdot\frac{q_{im}}{q_{im}^*}\cdot S_1 + ALP2 \cdot q_{bm} \cdot \left(\frac{\alpha_m \phi_T^*}{q_{im}^*}\right)^2 \cdot S_2$$

$$G_{\Delta L} = \frac{1}{1 + \Delta L/L + (\Delta L/L)^2}$$

### Drain-Source Channel Current (Section 4.2.12)

$$\theta_{sat}^* = \theta_{sat}' / G_{\Delta L}$$

$$z_{sat} = \theta_{sat}^{*2} \cdot \Delta\psi^2 \quad \text{(NMOS)}, \quad \frac{\theta_{sat}^{*2}\Delta\psi^2}{1+\theta_{sat}^*\Delta\psi} \quad \text{(PMOS)}$$

$$G_{vsat} = \frac{G_{mob} \cdot G_{\Delta L}}{2}\left(1 + \sqrt{1 + 2z_{sat}}\right)$$

$$I_{DS} = \beta \cdot \frac{q_{im}^*}{G_{vsat}} \cdot \Delta\psi$$

### Gate Current (Section 4.2.14)

Gate-channel current:

$$I_{GCO} = IGINV \cdot F_S \cdot \exp\!\left(B\left[-\tfrac{3}{2} + z_g(GC2 + GC3 \cdot z_g)\right]\right)$$

Gate overlap current (function $IG_{Xov}$):

$$IG_{ov} = IG \cdot FS_{ov} \cdot \exp\!\left(B_{ov}\left[-\tfrac{3}{2} + z_g(GC2OV + GC3OV \cdot z_g)\right]\right)$$

### GIDL/GISL Current (Section 4.2.15)

$$I_{gixl} = -A \cdot t \cdot \exp\!\left(-\frac{B}{V_{tov}}\right) \quad \text{for } V_{ov} < 0$$

where $V_{tov} = \sqrt{V_{ov}^2 + C^2 V_{XB}^2 + 10^{-6}}$ and $t = V_{XB} \cdot V_{tov} \cdot V_{ov}$.

### Impact Ionization (Section 4.2.17)

$$\Delta V_{sat} = V_{DS} - A3 \cdot \Delta\psi$$

$$M_{avl} = A1 \cdot \Delta V_{sat} \cdot \exp\!\left(-\frac{a_2^*}{\Delta V_{sat}}\right) \quad \text{for } \Delta V_{sat} > 0$$

$$I_{avl} = M_{avl} \cdot (I_{DS} + I_{DS,edge})$$

### Total Terminal Currents (Section 4.2.18)

$$I_D = I_{DS} + I_{DS,edge} + I_{avl} - IG_{Dov} - IG_{CD} + I_{gidl}$$

$$I_S = -I_{DS} - I_{DS,edge} - IG_{Sov} - IG_{CS} + I_{gisl}$$

$$I_G = IG_C + IG_B + IG_{Dov} + IG_{Sov}$$

$$I_B = -I_{avl} - IG_B - I_{gidl} - I_{gisl}$$

### Charge Model -- Intrinsic Charges (Section 4.3.2)

For $x_{g,ac} > 0$:

$$Q_G'^{(i)} = C_{OX}^{qm}\left(V_{oxm,ac} + \frac{\eta_p \Delta\psi_{ac}}{2}\cdot\frac{G_{\Delta L}}{3}F_j + G_{\Delta L} - 1\right)$$

$$Q_I'^{(i)} = -C_{OX}^{qm} \cdot G_{\Delta L}\left(q_{im,ac} + \frac{\alpha_m \Delta\psi_{ac}}{6}F_j\right) - Q_{\Delta L}$$

### Total Terminal Charges (Section 4.3.5)

$$Q_G = Q_G^{(i)} + Q_{sov} + Q_{dov} + Q_{ofs} + Q_{ofd} + Q_{bov}$$

$$Q_S = Q_S^{(i)} - Q_{sov} - Q_{ofs}$$

$$Q_D = Q_D^{(i)} - Q_{dov} - Q_{ofd}$$

$$Q_B = Q_B^{(i)} - Q_{bov}$$

### Noise Model (Section 4.4)

Flicker noise ($x_{g,dc} > 0$):

$$S_{fl} = \frac{q\phi_{T,dc}^2 \beta I_{DS}}{f_{op}^{EF} C_{ox} G_{vsat} N^*}\left[(NFA - NFB \cdot N^* + NFC \cdot N^{*2})\ln\!\frac{N_m^* + \Delta N/2}{N_m^* - \Delta N/2} + (NFB + NFC(N_m^* - 2N^*))\Delta N\right]$$

Thermal noise (channel):

$$S_{id} = NT \cdot m_{id}, \quad NT = FNT \cdot 4k_B T_{KD}$$

Induced gate noise:

$$S_{ig} = NT \cdot \frac{(2\pi f_{op} C_{Geff})^2 m_{ig}}{1 + (2\pi f_{op} C_{Geff} m_{ig})^2}$$

Cross-correlation:

$$S_{igid} = NT \cdot \frac{2\pi j f_{op} C_{Geff} m_{igid}}{1 + 2\pi j f_{op} C_{Geff} m_{ig}}$$

Shot noise:

$$S_{igs} = 2q(I_{GCS} + IG_{Sov}), \quad S_{igd} = 2q(I_{GCD} + IG_{Dov})$$

$$S_{avl} = 2q(1 + M_{avl})I_{avl}$$

### Self Heating (Section 4.5)

$$P_{diss} = I_{DS} \cdot V_{DS} + I_{impact}(V_{DS} + V_{SB}) + V_{SIS}^2/R_{source} + V_{DID}^2/R_{drain}$$

Thermal network: $RTH$ in parallel with $CTH$, temperature rise $V_{dt}$.

### NQS Model (Section 5)

Collocation points: $n = SWNQS + 1$, step $h = 1/n$.

Continuity equation at collocation points:

$$\frac{\partial q_i}{\partial t} + T_{norm} \cdot f\!\left(x_{g,ac}, q_i, \frac{\partial q_i}{\partial y}, \frac{\partial^2 q_i}{\partial y^2}\right) = 0$$

where $T_{norm} = MUNQS \cdot \phi_T^* \cdot \beta / (C_{OX}^{qm}) \cdot G_{mob,ac} \cdot G_{\Delta L,ac}$.

NQS terminal charges computed via numerical integration (Simpson's rule for odd SWNQS, 3/8-rule for SWNQS=2):

$$Q_S^{NQS} = C_{OX}^{qm}\phi_T^* q_S^{NQS}, \quad Q_D^{NQS} = C_{OX}^{qm}\phi_T^* q_D^{NQS}$$

$$Q_B^{NQS} = -(Q_S^{NQS} + Q_D^{NQS} + Q_G^{NQS})$$

## Auxiliary Functions (Appendix A)

Smooth minimum:

$$MINA(x,y,a) = \frac{1}{2}\left(x + y - \sqrt{(x-y)^2 + a}\right)$$

Smooth maximum:

$$MAXA(x,y,a) = \frac{1}{2}\left(x + y + \sqrt{(x-y)^2 + a}\right)$$

Bounded smooth min/max:

$$MNE(x,y,\varepsilon) = \frac{2}{A}\left(x+y - \sqrt{(x+y)^2 - Axy}\right), \quad A = 4 - \varepsilon$$

$$MXE(x,y,\varepsilon) = \frac{2}{A}\left(x+y + \sqrt{(x+y)^2 - Axy}\right)$$

Chi function and derivatives:

$$\chi(y) = \frac{y^2}{2+y^2}, \quad \chi'(y) = \frac{4y}{(2+y^2)^2}, \quad \chi''(y) = \frac{8-12y^2}{(2+y^2)^3}$$

Surface potential approximation functions:

$$\nu = a + c, \quad \mu_1 = \nu^2/\tau + c^2/2 - a$$

$$\sigma_1(a,c,\tau,\eta) = \frac{a\nu}{\mu_1 + (c^2/3 - a)c\nu/\mu_1} + \eta$$

$$\mu_2 = \nu^2/\tau + c^2/2 - ab$$

$$\sigma_2(a,b,c,\tau,\eta) = \frac{a\nu}{\mu_2 + (c^2/3 - ab)c\nu/\mu_2} + \eta$$

## Physical Scaling Rules Summary (Section 3.3)

These equations compute local parameters from global parameters. Representative examples (the full set follows identical patterns):

$$VFB = VFBO + VFBL \cdot \left(\frac{L_{EN}}{L_E}\right)^{VFBLEXP} + VFBW \cdot \frac{W_{EN}}{W_E} + VFBLW \cdot \frac{A_{EN}}{A_E}$$

$$BETN = \frac{UO}{G_{P,E}} \cdot \frac{W_E}{L_E} \cdot G_{W,E}$$

$$THESAT = \left(THESATO + THESATL \cdot \frac{G_{W,E}}{G_{P,E}} \cdot \left(\frac{L_{EN}}{L_E}\right)^{THESATLEXP}\right)\left(1 + THESATW \cdot \frac{W_{EN}}{W_E}\right)\left(1 + THESATLW \cdot \frac{A_{EN}}{A_E}\right)$$

$$COX = \epsilon_{ox} \cdot \frac{W_{E,CV} \cdot L_{E,CV}}{TOX}$$

## Binning Rules Summary (Section 3.4)

Standard binning form for parameter $YYY$:

$$YYY = F_{YYY} \cdot \left(POYYY + PLYYY \cdot \frac{L_{EN}}{L_E} + PWYYY \cdot \frac{W_{EN}}{W_E} + PLWYYY \cdot \frac{A_{EN}}{A_E}\right)$$

where $F_{YYY}$ is an optional pre-factor preserving physical scaling behavior (e.g., $F_{COX} = L_{E,CV} W_{E,CV}/A_{EN}$, $F_{BETN} = W_E/L_E$, $F_{CF} = (L_{EN}/L_E)^2$).

## Stress Model Equations (Section 3.6)

$$\rho_\beta = \frac{KUO}{K_{u0}}(R_A + R_B), \quad \rho_{\beta,ref} = \frac{KUO}{K_{u0}}(R_{A,ref} + R_{B,ref})$$

$$BETN = \frac{1+\rho_\beta}{1+\rho_{\beta,ref}} \cdot BETN_{ref}$$

$$THESAT = \frac{1+\rho_\beta}{1+\rho_{\beta,ref}} \cdot \frac{1+KVSAT\cdot\rho_{\beta,ref}}{1+KVSAT\cdot\rho_\beta} \cdot THESAT_{ref}$$

$$VFB = VFB_{ref} + KVTHO \cdot \frac{\Delta R}{K_{vth0}}$$

## Well Proximity Effect Equations (Section 3.7)

$$VFB = VFB_{ref} + K_{vthowe} \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC)$$

$$BETN = BETN_{ref} \cdot [1 + K_{uowe} \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC)]$$

## Parasitic Resistance Equations (Section 3.5)

$$R_G = RGO + \frac{1}{NF}\left(\frac{RSHG \cdot (W_{E,f}/(3 \cdot NGCON) + XGWE)}{NGCON \cdot L_{sil,f}} + \frac{RINT + RVPOLY}{W_{E,f} \cdot L_f}\right)$$

$$RSE = NRS \cdot RSH, \quad RDE = NRD \cdot RSHD$$
