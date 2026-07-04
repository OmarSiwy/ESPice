# L-UTSOI 102.9.0 -- Parameter & Equation Reference

> Ultra-thin body SOI MOSFET (FDSOI) -- CEA-Leti compact model for Fully-Depleted Silicon-On-Insulator technologies with low-doped channel. Supports independent double-gate architectures, backplane depletion, asymmetric junctions, poly-depletion, edge transistors, NQS, self-heating, and cryogenic operation.

## Model Topology

The device has five terminals: Drain (D), Gate (G), Source (S), Bulk/Backplane (B), and an internal temperature node (Tnode) for self-heating. The intrinsic MOSFET core uses surface-potential-based physics with front ($\psi_{s1}$) and back ($\psi_{s2}$) interface potentials computed analytically. Parasitic elements include gate resistance, source/drain diffusion resistances, and well resistance. A global multiplication factor $Multf = \text{MULT} \times \text{NF}$ is applied to all output quantities.

---

## Constants

| Symbol | Unit | Description | Value |
|--------|------|-------------|-------|
| $k_B$ | J/K | Boltzmann constant | $1.3806488 \times 10^{-23}$ |
| $\hbar$ | J.s | Reduced Planck constant | $1.054571726 \times 10^{-34}$ |
| $q$ | C | Elementary unit charge | $1.602176565 \times 10^{-19}$ |
| $m_0$ | kg | Electron intrinsic mass | $9.10938291 \times 10^{-31}$ |
| $\epsilon_{ox}$ | F/m | Permittivity of SiO2 (relative 3.9) | $3.45313 \times 10^{-11}$ |
| $\epsilon_{Si}$ | F/m | Permittivity of Si (relative 11.8) | $1.04479 \times 10^{-10}$ |
| $E_{g0,Si}$ | V | Bandgap voltage for Si at 0K | 1.170 |
| $\alpha_{Si}$ | V/K | First bandgap temp dependence for Si | $4.730 \times 10^{-4}$ |
| $\beta_{Si}$ | K | Second bandgap temp dependence for Si | 636.0 |
| $\epsilon_{Ge}$ | F/m | Permittivity of Ge (relative 16.2) | $1.43438 \times 10^{-10}$ |
| $E_{g0,Ge}$ | V | Bandgap voltage for Ge at 0K | 0.744 |
| $\alpha_{Ge}$ | V/K | First bandgap temp dependence for Ge | $4.774 \times 10^{-4}$ |
| $\beta_{Ge}$ | K | Second bandgap temp dependence for Ge | 235.0 |
| $C_G$ | -- | Nonlinearity coefficient for SiGe bandgap | $-0.4$ |
| $n_{i,fact,300}$ | m$^{-3}$ | Intrinsic concentration pre-factor for Si at 300K | $4.05 \times 10^{25}$ |
| $QMN$ | V$^{1/3}$ nm$^{2/3}$ | Constant for quantum confinement of electrons | 1.27520989 |
| $QMP$ | V$^{1/3}$ nm$^{2/3}$ | Constant for quantum confinement of holes | 1.54120870 |

$QMN$ and $QMP$ equal $\left(\frac{9\pi\hbar}{4\sqrt{2 q m_{conf}}}\right)^{2/3}$ with $m_{conf} = 0.918 m_0$ (electrons) or $0.52 m_0$ (holes).

---

## Parameters

### Model Selection, Switches, and General Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SWSCALE | -- | 1 | [0, 1] | Scale level: 0=Local, 1=Global |
| VERSION | -- | 102.80 | -- | Model version |
| SWSUBDEP | -- | 0 | [0, 1] | Flag for backplane depletion effect |
| SWIGATE | -- | 0 | [0, 1] | Flag for gate current model |
| SWGIDL | -- | 0 | [0, 1] | Flag for gate induced source/drain leakage model |
| SWSHE | -- | 0 | [0, 1] | Flag for self-heating effect |
| SWIGN | -- | 0 | [0, 1] | Flag for induced gate noise model |
| SWJUNASYM | -- | 1 | [0, 1] | Flag for source/drain junction asymmetry |
| SWIMPACT | -- | 0 | [0, 1] | Flag for impact ionization current |
| SWPDEP | -- | 0 | [0, 1] | Flag for poly-depletion model |
| SWCRYO | -- | 0 | [0, 1] | Flag for cryogenic temperature simulation |
| SWQMOD | -- | 0 | [0, 1] | Flag for separate charge calculation |
| SWEDGE | -- | 0 | [0, 1] | Flag for drain current of edge transistors |
| QMC | -- | 1.0 | [0.0, --] | Quantum confinement coefficient |
| TYPE | -- | 1 | [-1, 1] | Channel type: +1=NMOS, -1=PMOS |
| TR (TREF) | C | 21.0 | [-273.0, --] | Temperature of parameter extraction |
| TMAX | C | 150.0 | [0.0, --] | Maximum self-heating temperature elevation |
| DTEMP | K | 0.0 | -- | Device temperature offset |

### Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| L | m | $10^{-6}$ | [$10^{-9}$, --] | Drawn channel length |
| W | m | $10^{-6}$ | [$10^{-9}$, --] | Drawn channel width |
| ASOURCE | m$^2$ | $10^{-12}$ | [0.0, --] | Source region area |
| ADRAIN | m$^2$ | $10^{-12}$ | [0.0, --] | Drain region area |
| PSOURCE | m | $10^{-6}$ | [0.0, --] | Source region perimeter |
| PDRAIN | m | $10^{-6}$ | [0.0, --] | Drain region perimeter |
| SA | m | 0.0 | [0.0, --] | Distance between active edge and poly at source side |
| SB | m | 0.0 | [0.0, --] | Distance between active edge and poly at drain side |
| SD | m | 0.0 | [0.0, --] | Distance between neighbouring fingers |
| NF | -- | 1 | [1, --] | Number of fingers |
| MULT | -- | 1 | [0, --] | Number of devices in parallel |
| MULT_I | -- | 1 | [0, --] | Currents multiplication factor |
| MULT_Q | -- | 1 | [0, --] | Charges multiplication factor |
| MULT_FN | -- | 1 | [0, --] | Flicker noise multiplication factor |
| DELVTO | V | 0.0 | -- | Threshold voltage shift parameter |
| FACTUO | -- | 1.0 | [0.0, --] | Low field mobility pre-factor |
| NGCON | -- | 1 | [1, 2] | Number of gate contacts |
| XGW | m | $10^{-7}$ | -- | Distance from gate contact to channel edge |
| NRS | -- | 0.0 | -- | Number of squares of source diffusion |
| NRD | -- | 0.0 | -- | Number of squares of drain diffusion |

### Scaling Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| LVARO | m | 0.0 | -- | Long channel physical-to-drawn gate length difference |
| LVARL | -- | 0.0 | -- | Length dependence of physical-to-drawn gate length difference |
| LVARW | -- | 0.0 | -- | Width dependence of physical-to-drawn gate length difference |
| LAP | m | 0.0 | -- | Effective channel length reduction per side |
| WVARO | m | 0.0 | -- | Wide channel physical-to-drawn active width difference |
| WVARL | -- | 0.0 | -- | Length dependence of physical-to-drawn active width difference |
| WVARW | -- | 0.0 | -- | Width dependence of physical-to-drawn active width difference |
| WOT | m | 0.0 | -- | Effective channel width reduction per side |
| DLQ | m | 0.0 | -- | Effective channel length additional offset for charge model |
| DWQ | m | 0.0 | -- | Effective channel width additional offset for charge model |

### Stress Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SWSTRESS | -- | 1 | [0, 2] | Stress model selection flag |
| SAREF | m | $10^{-6}$ | [$10^{-9}$, --] | Reference distance active edge to poly (one side) |
| SBREF | m | $10^{-6}$ | [$10^{-9}$, --] | Reference distance active edge to poly (other side) |

#### SWSTRESS=1 (STI-Stress Model)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WLOD | m | 0.0 | -- | Width parameter |
| KUO | -- | 0.0 | -- | Mobility degradation/enhancement coefficient |
| KVSAT | -- | 0.0 | [-1.0, 1.0] | Saturation velocity degradation/enhancement coefficient |
| TKUO | -- | 0.0 | -- | Temperature dependence of KUO |
| LKUO | -- | 0.0 | -- | Length dependence of KUO |
| WKUO | -- | 0.0 | -- | Width dependence of KUO |
| PKUO | -- | 0.0 | -- | Cross-term dependence of KUO |
| LLODKUO | m | 0.0 | [0.0, --] | Length parameter for mobility stress effect |
| WLODKUO | m | 0.0 | [0.0, --] | Width parameter for mobility stress effect |
| KVTHO | -- | 0.0 | -- | Threshold voltage shift parameter |
| LKVTHO | -- | 0.0 | -- | Length dependence of KVTHO |
| WKVTHO | -- | 0.0 | -- | Width dependence of KVTHO |
| PKVTHO | -- | 0.0 | -- | Cross-term dependence of KVTHO |
| LLODVTH | m | 0.0 | [0.0, --] | Length parameter for threshold voltage stress effect |
| WLODVTH | m | 0.0 | [0.0, --] | Width parameter for threshold voltage stress effect |
| STETAO | -- | 0.0 | -- | ETAO shift factor related to threshold voltage change |
| LODETAO | -- | 1.0 | [0.0, --] | ETAO shift modification factor |

#### SWSTRESS=2 (Strained-SOI Model)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| STRLAMBDA | m | $10^{-7}$ | [$10^{-9}$, $10^{-5}$] | Strain relaxation characteristic length |
| STRALPHA | -- | 3.0 | [0.5, --] | Strain relaxation asymmetry parameter |
| STRDVFBO | V | 0.0 | -- | Threshold shift parameter |
| STRWDVFBO | -- | 0.0 | -- | Width dependence of threshold shift parameter |
| STRDCFL | -- | 0.0 | -- | DIBL variation parameter |
| STRRUO | -- | 0.0 | -- | Mobility degradation/enhancement coefficient |
| STRTRUO | -- | 0.0 | -- | Temperature dependence of STRRUO |
| STRRVSAT | -- | 0.0 | -- | Saturation velocity degradation/enhancement coefficient |

### Process Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **TOXE** | m | $2 \times 10^{-9}$ | [$3 \times 10^{-10}$, $10^{-6}$] | Front gate equivalent oxide thickness (EOT) |
| TOXEO | m | $2 \times 10^{-9}$ | [$3 \times 10^{-10}$, $10^{-6}$] | Global scale parameter for TOXE |
| **TSI** | m | $10^{-8}$ | [$3 \times 10^{-9}$, $2 \times 10^{-8}$] | Silicon or SiGe film thickness |
| TSIO | m | $10^{-8}$ | [$3 \times 10^{-9}$, $2 \times 10^{-8}$] | Global scale parameter for TSI |
| **XGE** | -- | 0.0 | [0.0, 1.0] | Fraction of germanium content in the channel |
| XGEO | -- | 0.0 | [0.0, 1.0] | Global scale parameter for XGE |
| **TBOX** | m | $10^{-7}$ | [$3 \times 10^{-10}$, $10^{-6}$] | Back gate equivalent oxide thickness (EOT) |
| TBOXO | m | $10^{-7}$ | [$3 \times 10^{-10}$, $10^{-6}$] | Global scale parameter for TBOX |
| **NCH** | cm$^{-3}$ | 0.0 | [0.0, $10^{19}$] | Thin film doping (positive=p-type, negative=n-type) |
| NCHO | cm$^{-3}$ | 0.0 | [0.0, $10^{19}$] | Global scale parameter for NCH |
| **NSUB** | cm$^{-3}$ | $3 \times 10^{18}$ | [$10^{16}$, $10^{21}$] | Backplane doping level (positive=p-type, negative=n-type) |
| NSUBO | cm$^{-3}$ | $3 \times 10^{18}$ | [$10^{16}$, $10^{21}$] | Global scale parameter for NSUB |
| **CT** | -- | 0.0 | [0.0, --] | Interface states factor |
| CTO | -- | 0.0 | [0.0, --] | Global scale parameter for CT |
| **TOXP** | m | $2 \times 10^{-9}$ | [$3 \times 10^{-10}$, $10^{-6}$] | Front gate physical oxide thickness |
| TOXPO | m | $2 \times 10^{-9}$ | [$3 \times 10^{-10}$, $10^{-6}$] | Global scale parameter for TOXP |
| **NOV** | cm$^{-3}$ | $10^{20}$ | [$10^{15}$, $10^{21}$] | Effective doping level of overlap-LDD regions |
| NOVO | cm$^{-3}$ | $10^{20}$ | [$10^{15}$, $10^{21}$] | Global scale parameter for NOV |
| **NOVD** | cm$^{-3}$ | $10^{20}$ | [$10^{15}$, $10^{21}$] | Effective doping level of overlap-LDD at drain side |
| NOVDO | cm$^{-3}$ | $10^{20}$ | [$10^{15}$, $10^{21}$] | Global scale parameter for NOVD |
| **VFB** | V | 0.0 | -- | Front gate workfunction referenced to Si midgap at TR |
| VFBO | V | 0.0 | -- | Long/wide channel value of VFB |
| VFBL | V | 0.0 | -- | Channel length scaling parameter of VFB |
| VFBLEXP | -- | 2.0 | -- | Channel length scaling exponent of VFB |
| VFBL2 | -- | 0.0 | -- | Second order channel length dependence of VFB |
| VFBLEXP2 | -- | 2.0 | -- | Second order channel length scaling exponent of VFB |
| VFBW | V | 0.0 | -- | Channel width scaling parameter of VFB |
| VFBLW | V | 0.0 | -- | Channel area scaling parameter of VFB |
| **VFBB** | V | 0.0 | -- | Back gate workfunction offset at TR |
| VFBBO | V | 0.0 | -- | Long/wide channel value of VFBB |
| VFBLBO | -- | 0.0 | -- | Back-to-front interface asymmetry factor applied to VFBL |
| **STVFB** | V/K | 0.0 | -- | Temperature dependence of VFB and VFBB |
| STVFBO | V/K | 0.0 | -- | Long/wide channel value of STVFB |
| STVFBL | -- | 0.0 | -- | Channel length scaling parameter of STVFB |
| STVFBW | -- | 0.0 | -- | Channel width scaling parameter of STVFB |
| STVFBLW | -- | 0.0 | -- | Channel area scaling parameter of STVFB |
| **NP** | cm$^{-3}$ | $10^{21}$ | [$10^{19}$, $10^{22}$] | Gate poly-silicon doping |
| NPO | cm$^{-3}$ | $10^{21}$ | [$10^{19}$, $10^{22}$] | Geometry-independent gate poly-silicon doping |
| NPL | -- | 0.0 | -- | Length dependence of gate poly-silicon doping |

### Gate to Interface Coupling Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **CICF** | -- | 1.0 | [0.1, 10.0] | Long channel front interface coupling coefficient |
| CICFO | -- | 1.0 | [0.1, 10.0] | Global scale parameter for CICF |
| **CIC** | -- | 1.0 | [0.1, 10.0] | Long channel back interface coupling coefficient |
| CICO | -- | 1.0 | [0.1, 10.0] | Global scale parameter for CIC |
| **PSCE** | -- | 0.0 | [0.0, 5.0] | Short channel coupling attenuation parameter |
| PSCEL | -- | 0.0 | -- | Channel length scaling parameter of PSCE |
| PSCELEXP | -- | 2.0 | -- | Channel length scaling exponent of PSCE |
| PSCEW | -- | 0.0 | -- | Channel width scaling parameter of PSCE |
| **PSCEB** | -- | 1.0 | [0.0, --] | Short channel back-to-front interface asymmetry factor |
| PSCEBO | -- | 1.0 | [0.0, --] | Global scale parameter for PSCEB |
| **NSDDC** | cm$^{-3}$ | $10^{22}$ | [$10^{18}$, $10^{22}$] | Source/drain effective doping level for DC model |
| NSDDCO | cm$^{-3}$ | $10^{22}$ | [$10^{18}$, $10^{22}$] | Global scale parameter for NSDDC |
| **PSCEDLB** | -- | 0.0 | [0.0, --] | Back bias dependence of short channel effect modulation |
| PSCEDLBO | -- | 0.0 | [0.0, --] | Global scale parameter for PSCEDLB |
| **PNCE** | -- | 0.0 | [-1.0, 1.0] | Narrow channel effect on body factor |
| PNCEW | -- | 0.0 | -- | Channel width scaling parameter of PNCE |

### Drain Induced Barrier Lowering (DIBL) Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **CF** | -- | 0.0 | [0.0, --] | DIBL parameter at TR |
| CFL | -- | 0.0 | -- | Channel length scaling parameter of CF |
| CFLEXP | -- | 2.0 | -- | Channel length scaling exponent of CF |
| CFW | -- | 0.0 | -- | Channel width scaling parameter of CF |
| **CFB** | -- | 1.0 | [0.0, --] | DIBL back-to-front interface asymmetry factor |
| CFBO | -- | 1.0 | [0.0, --] | Global scale parameter for CFB |
| **STCF** | K$^{-1}$ | 0.0 | -- | Temperature dependence of CF |
| STCFL | K$^{-1}$ | 0.0 | -- | Channel length scaling parameter for STCF |
| **CFD** | V | 0.2 | [0.05, --] | Drain voltage dependence parameter of DIBL |
| CFDO | V | 0.2 | [0.05, --] | Global scale parameter for CFD |
| **CFDL** | -- | 0.0 | -- | DIBL modulation due to Leff dependence on biases |
| CFDLL | -- | 0.0 | -- | Channel length scaling parameter of CFDL |
| CFDLW | -- | 0.0 | -- | Channel width scaling parameter of CFDL |
| **CFDLB** | -- | 0.0 | [0.0, --] | Back bias dependence of DIBL modulation |
| CFDLBO | -- | 0.0 | [0.0, --] | Global scale parameter for CFDLB |

### Mobility Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **BETN** | m$^2$/V/s | -- | -- | Front channel aspect ratio times low field mobility at TR |
| UO | m$^2$/V/s | 0.05 | [$10^{-10}$, --] | Front channel low field mobility at TR |
| FBET1 | -- | 0.0 | -- | First length dependence modulation of BETN |
| FBET1W | -- | 0.0 | -- | Width dependence of FBET1 |
| LP1 | m | $10^{-8}$ | [$10^{-10}$, --] | First characteristic length of BETN scaling |
| LP1W | -- | 0.0 | -- | Width dependence of LP1 |
| FBET2 | -- | 0.0 | -- | Second length dependence modulation of BETN |
| LP2 | m | $10^{-8}$ | [$10^{-10}$, --] | Second characteristic length of BETN scaling |
| BETW1 | -- | 0.0 | -- | First width dependence modulation of BETN |
| BETW2 | -- | 0.0 | -- | Second width dependence modulation of BETN |
| WBET | m | 0.05 | [$10^{-10}$, --] | Characteristic width of BETN scaling |
| **BETNB** | -- | 1.0 | [0.1, 10.0] | Back/front channel low field mobility ratio |
| BETNBO | -- | 1.0 | [0.1, 10.0] | Global scale parameter for BETNB |
| **STBET** | -- | 1.5 | -- | Temperature dependence exponent of BETN |
| STBETO | -- | 1.5 | -- | Long/wide channel value of STBET |
| STBETL | -- | 0.0 | -- | Channel length scaling parameter of STBET |
| STBETW | -- | 0.0 | -- | Active width scaling parameter of STBET |
| STBETLW | -- | 0.0 | -- | Active area scaling parameter of STBET |
| **CS** | -- | 0.0 | [0.0, --] | Coulomb scattering parameter at TR |
| CSO | -- | 0.0 | -- | Long/wide channel value of CS |
| CSL | -- | 0.0 | -- | Channel length scaling parameter of CS |
| CSLEXP | -- | 1.0 | -- | Channel length scaling exponent of CS |
| CSW | -- | 0.0 | -- | Channel width scaling parameter of CS |
| CSLW | -- | 0.0 | -- | Channel area scaling parameter of CS |
| **CSFI** | -- | 0.0 | [0.0, --] | Field dependence of Coulomb scattering at front interface |
| CSFIO | -- | 0.0 | [0.0, --] | Global scale parameter for CSFI |
| **CSBI** | -- | 0.0 | [0.0, --] | Field dependence of Coulomb scattering at back interface |
| CSBIO | -- | 0.0 | [0.0, --] | Global scale parameter for CSBI |
| **STCS** | -- | 0.0 | -- | Temperature dependence exponent of CS |
| STCSO | -- | 0.0 | -- | Long/wide channel value of STCS |
| STCSL | -- | 0.0 | -- | Channel length scaling parameter of STCS |
| STCSW | -- | 0.0 | -- | Channel width scaling parameter of STCS |
| STCSLW | -- | 0.0 | -- | Channel area scaling parameter of STCS |
| **THECS** | -- | 1.5 | [0.0, --] | Coulomb scattering exponent at TR |
| THECSO | -- | 1.5 | [0.0, --] | Global scale parameter for THECS |
| **STTHECS** | -- | 0.0 | -- | Temperature dependence exponent of THECS |
| STTHECSO | -- | 0.0 | -- | Global scale parameter for STTHECS |
| **CSTHR** | -- | 2.0 | [0.001, --] | Coulomb scattering threshold level |
| CSTHRO | -- | 2.0 | [0.001, --] | Global scale parameter for CSTHR |
| **CSTHRB** | -- | 1.0 | [0.1, --] | Coulomb scattering threshold asymmetry parameter |
| CSTHRBO | -- | 1.0 | [0.1, --] | Global scale parameter for CSTHRB |
| **MUE** | cm/MV | 0.0 | [0.0, --] | High field mobility reduction coefficient at TR |
| MUEO | cm/MV | 0.0 | [0.0, --] | Global scale parameter for MUE |
| **STMUE** | -- | 0.0 | -- | Temperature dependence exponent of MUE |
| STMUEO | -- | 0.0 | -- | Global scale parameter for STMUE |
| **THEMU** | -- | 1.5 | [0.0, --] | High field mobility reduction exponent at TR |
| THEMUO | -- | 1.5 | [0.0, --] | Global scale parameter for THEMU |
| **STTHEMU** | -- | 0.0 | -- | Temperature dependence exponent of THEMU |
| STTHEMUO | -- | 0.0 | -- | Global scale parameter for STTHEMU |
| **XCOR** | -- | 0.0 | -- | High field mobility non-universality factor at TR |
| XCORO | -- | 0.0 | -- | Long/wide channel value of XCOR |
| XCORL | -- | 0.0 | -- | Channel length scaling parameter of XCOR |
| XCORLEXP | -- | 1.0 | -- | Channel length scaling exponent of XCOR |
| XCORW | -- | 0.0 | -- | Channel width scaling parameter of XCOR |
| XCORLW | -- | 0.0 | -- | Channel area scaling parameter of XCOR |
| **XCORB** | -- | 1.0 | -- | Asymmetry term of non-universality factor |
| XCORBO | -- | 1.0 | -- | Global scale parameter for XCORB |
| **STXCOR** | -- | 0.0 | -- | Temperature dependence exponent of XCOR |
| STXCORO | -- | 0.0 | -- | Global scale parameter for STXCOR |
| **FETA** | -- | 1.0 | [0.0, --] | Transverse effective field parameter |
| FETAO | -- | 1.0 | [0.0, --] | Global scale parameter for FETA |

### Series Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **RS** | Ohm | 30.0 | [0.0, --] | Source/drain series resistance at TR |
| RSW1 | Ohm | 30.0 | -- | Series resistance for a WEN width at TR |
| RSW2 | -- | 0.0 | -- | Second order width scaling parameter of RS |
| **RSIG** | -- | 0.0 | [0.0, --] | Source/drain extension resistance coefficient |
| RSIGO | -- | 0.0 | [0.0, --] | Global scale parameter for RSIG |
| **STRS** | -- | 0.0 | -- | Temperature dependence exponent of RS |
| STRSO | -- | 0.0 | -- | Global scale parameter for STRS |
| **RSG** | -- | 0.0 | [-0.5, --] | Transverse electric field dependence of RS |
| RSGO | -- | 0.0 | [-0.5, --] | Global scale parameter for RSG |
| **RSB** | -- | 0.0 | -- | Back bias dependence of RS |
| RSBO | -- | 0.0 | -- | Global scale parameter for RSB |
| **THERSG** | -- | 2.0 | -- | Transverse electric field dependence exponent of RS |
| THERSGO | -- | 2.0 | -- | Global scale parameter for THERSG |

### Velocity Saturation Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **THESAT** | V$^{-1}$ | 0.0 | -- | Velocity saturation parameter at TR |
| THESATO | s/m$^2$ | 0.0 | -- | Long/wide channel parameter for THESAT |
| THESATL | s/m$^2$ | 0.0 | -- | Channel length scaling parameter of THESAT |
| THESATLEXP | -- | 1.0 | -- | Channel length scaling exponent of THESAT |
| THESATW | -- | 0.0 | -- | Channel width scaling parameter of THESAT |
| THESATLW | -- | 0.0 | -- | Channel area scaling parameter of THESAT |
| **STTHESAT** | -- | -0.1 | -- | Temperature dependence exponent of THESAT |
| STTHESATO | -- | -0.1 | -- | Long/wide channel parameter for STTHESAT |
| STTHESATL | -- | 0.0 | -- | Channel length scaling parameter of STTHESAT |
| STTHESATW | -- | 0.0 | -- | Channel width scaling parameter of STTHESAT |
| STTHESATLW | -- | 0.0 | -- | Channel area scaling parameter of STTHESAT |
| **THESATG** | -- | 0.0 | [-0.5, --] | Front gate bias dependence of velocity saturation |
| THESATGO | -- | 0.0 | [-0.5, --] | Global scale parameter for THESATG |
| **THESATB** | -- | 0.0 | [-0.5, --] | Back gate bias dependence of velocity saturation |
| THESATBO | -- | 0.0 | [-0.5, --] | Global scale parameter for THESATB |

### Saturation and Channel Length Modulation Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **AX** | -- | 8.0 | [1.0, 16.0] | Linear/saturation transition exponent |
| AXO | -- | 8.0 | -- | Long/wide channel value of AX |
| AXL | -- | 0.0 | -- | Channel length scaling parameter of AX |
| AXLEXP | -- | 1.0 | -- | Channel length scaling exponent of AX |
| AXL2 | -- | 0.0 | -- | Second order channel length scaling parameter of AX |
| AXLEXP2 | -- | 1.5 | -- | Second order channel length scaling exponent of AX |
| **ALP** | -- | 0.0 | [0.0, --] | Channel length modulation pre-factor |
| ALPL1 | -- | 0.0 | -- | Channel length scaling parameter of ALP |
| ALPLEXP | -- | 1.0 | -- | Channel length scaling exponent of ALP |
| ALPL2 | -- | 0.0 | [0.0, --] | Second order channel length dependence of ALP |
| ALPLEXP2 | -- | 2.0 | -- | Second order channel length scaling exponent of ALP |
| ALPW | -- | 0.0 | -- | Channel width scaling parameter of ALP |
| **ALP1** | V | 0.0 | [0.0, --] | Channel length modulation enhancement above threshold |
| ALP1L1 | V | 0.0 | -- | Channel length scaling parameter of ALP1 |
| ALP1LEXP | -- | 0.5 | -- | Channel length scaling exponent of ALP1 |
| ALP1L2 | V | 0.0 | [0.0, --] | Second order channel length dependence of ALP1 |
| ALP1LEXP2 | -- | 1.5 | -- | Second order channel length scaling exponent of ALP1 |
| ALP1W | -- | 0.0 | -- | Channel width scaling parameter of ALP1 |
| **ALPB** | -- | 0.0 | -- | Back bias dependence of channel length modulation |
| ALPBO | -- | 0.0 | -- | Global scale parameter for ALPB |
| **VP** | V | 0.05 | [$10^{-10}$, --] | Channel length modulation logarithm dependence factor |
| VPO | V | 0.05 | [$10^{-10}$, --] | Global scale parameter for VP |
| **VPG** | -- | 0.0 | [0.0, --] | Transverse field dependence of CLM logarithm factor |
| VPGO | -- | 0.0 | [0.0, --] | Global scale parameter for VPG |

### Gate Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **GCO** | -- | 0.0 | [-10.0, 10.0] | Gate tunneling energy adjustment in inversion mode |
| GCOO | -- | 0.0 | [-10.0, 10.0] | Global scale parameter for GCO |
| **IGINV** | A | 0.0 | [0.0, --] | Gate to channel current pre-factor |
| IGINVLW | A | 0.0 | [0.0, --] | IGINV value for a LEN.WEN area |
| **IGOVINV** | A | 0.0 | [0.0, --] | Gate-overlap current pre-factor in inversion |
| IGOVINVW | A | 0.0 | [0.0, --] | IGOVINV value for a WEN width |
| **IGOVINVD** | A | 0.0 | [0.0, --] | Gate-overlap current pre-factor in inversion at drain side |
| IGOVINVDW | A | 0.0 | [0.0, --] | IGOVINVD for a WEN width |
| **IGOVACC** | A | 0.0 | [0.0, --] | Gate-overlap current pre-factor in accumulation |
| IGOVACCW | A | 0.0 | [0.0, --] | IGOVACC value for a WEN width |
| **IGOVACCD** | A | 0.0 | [0.0, --] | Gate-overlap current pre-factor in accumulation at drain side |
| IGOVACCDW | A | 0.0 | [0.0, --] | IGOVACCD value for a WEN width |
| **STIG** | -- | 0.0 | -- | Temperature dependence of all gate current pre-factors |
| STIGO | -- | 0.0 | -- | Global scale parameter for STIG |
| **GC2CH** | -- | 0.375 | [0.0, 10.0] | Gate to channel current slope factor |
| GC2CHO | -- | 0.375 | [0.0, 10.0] | Global scale parameter for GC2CH |
| **GC3CH** | -- | 0.063 | [-2.0, 2.0] | Gate to channel current curvature factor |
| GC3CHO | -- | 0.063 | [-2.0, 2.0] | Global scale parameter for GC3CH |
| **GC2OVINV** | -- | 0.375 | [0.0, 10.0] | Gate-overlap current slope factor in inversion |
| GC2OVINVO | -- | 0.375 | [0.0, 10.0] | Global scale parameter for GC2OVINV |
| **GC3OVINV** | -- | 0.063 | [-2.0, 2.0] | Gate-overlap current curvature factor in inversion |
| GC3OVINVO | -- | 0.063 | [-2.0, 2.0] | Global scale parameter for GC3OVINV |
| **GC2OVACC** | -- | 0.375 | [0.0, 10.0] | Gate-overlap current slope factor in accumulation |
| GC2OVACCO | -- | 0.375 | [0.0, 10.0] | Global scale parameter for GC2OVACC |
| **GC3OVACC** | -- | 0.063 | [-2.0, 2.0] | Gate-overlap current curvature factor in accumulation |
| GC3OVACCO | -- | 0.063 | [-2.0, 2.0] | Global scale parameter for GC3OVACC |
| **GCDOV** | V$^{-1}$ | 0.0 | -- | High drain voltage dependence of overlap gate current |
| GCDOVL | V$^{-1}$ | 0.0 | -- | GCDOV value for a LEN length |
| **GCVDOV** | V | 1.0 | -- | Threshold of high drain voltage effect on overlap gate current |
| GCVDOVO | V | 1.0 | -- | Global scale parameter for GCVDOV |
| **CHIB** | V | 3.1 | [1.0, --] | Tunneling barrier height |
| CHIBO | V | 3.1 | [1.0, --] | Global scale parameter for CHIB |
| **NIGINV** | -- | 0.0 | [0.0, --] | Gate tunneling slope adjustment in subthreshold regime |
| NIGINVO | -- | 0.0 | [0.0, --] | Global scale parameter for NIGINV |
| **FNOVINV** | A | 0.0 | [0.0, --] | Extra gate to overlap current pre-factor in inversion |
| FNOVINVW | A | 0.0 | [0.0, --] | FNOVINV for a WEN width |
| **FNOVINVD** | A | 0.0 | [0.0, --] | Extra gate to overlap current pre-factor in inversion at drain side |
| FNOVINVDW | A | 0.0 | [0.0, --] | FNOVINVD for a WEN width |
| **GCOVINVFN** | -- | 0.2 | [0.1, 10.0] | Extra gate current slope factor for overlap in inversion |
| GCOVINVFNO | -- | 0.2 | [0.1, 10.0] | Global scale parameter for GCOVINVFN |
| **STIGFN** | -- | 0.0 | -- | Temperature dependence of extra gate to overlap current |
| STIGFNO | -- | 0.0 | -- | Global scale parameter for STIGFN |

### GIDL/GISL Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **AGIDL** | A/V$^3$ | 0.0 | [0.0, --] | GIDL/GISL current pre-factor |
| AGIDLO | A/V$^3$ | 0.0 | -- | Global scale parameter for AGIDL |
| AGIDLW | A/V$^3$ | 0.0 | -- | Channel width scaling parameter of AGIDL |
| **AGIDLD** | A/V$^3$ | 0.0 | [0.0, --] | GIDL current pre-factor at drain side |
| AGIDLDO | A/V$^3$ | 0.0 | -- | Global scale parameter for AGIDLD |
| AGIDLDW | A/V$^3$ | 0.0 | -- | Channel width scaling parameter of AGIDLD |
| **BGIDL** | V | 41 | [0.0, --] | GIDL/GISL probability factor at TR |
| BGIDLO | V | 41 | [0.0, --] | Global scale parameter for BGIDL |
| **BGIDLD** | V | 41 | [0.0, --] | GIDL probability factor at TR at drain side |
| BGIDLDO | V | 41 | [0.0, --] | Global scale parameter for BGIDLD |
| **STBGIDL** | V/K | 0.0 | -- | Temperature dependence of BGIDL |
| STBGIDLO | V/K | 0.0 | -- | Global scale parameter for STBGIDL |
| **STBGIDLD** | V/K | 0.0 | -- | Temperature dependence of BGIDLD |
| STBGIDLDO | V/K | 0.0 | -- | Global scale parameter for STBGIDLD |
| **CGIDL** | V$^{-1}$ | 0.0 | -- | Substrate bias dependence of GIDL/GISL |
| CGIDLO | V$^{-1}$ | 0.0 | -- | Global scale parameter for CGIDL |
| **CGIDLD** | V$^{-1}$ | 0.0 | -- | Substrate bias dependence of GIDL at drain side |
| CGIDLDO | V$^{-1}$ | 0.0 | -- | Global scale parameter for CGIDLD |
| **DGIDL** | V$^{-1}$ | 0.0 | -- | High longitudinal field dependence of GIDL/GISL |
| DGIDLO | V$^{-1}$ | 0.0 | -- | Global scale parameter for DGIDL |
| DGIDLL | V$^{-1}$ | 0.0 | -- | Channel length scaling parameter of DGIDL |
| **DGIDLD** | V$^{-1}$ | 0.0 | -- | High longitudinal field dependence of GIDL at drain side |
| DGIDLDO | V$^{-1}$ | 0.0 | -- | Global scale parameter for DGIDLD |
| DGIDLDL | V$^{-1}$ | 0.0 | -- | Channel length scaling parameter of DGIDLD |

### Edge Transistor Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WEDGE | m | $10^{-8}$ | [0, --] | Electrical width of edge transistor per side |
| WEDGEW | -- | 0 | [0, --] | Main transistor width dependence of WEDGE |
| **CTEDGE** | -- | 0.0 | [0.0, --] | Interface states factor of edge transistors |
| CTEDGEO | -- | 0.0 | [0.0, --] | Global scale parameter for CTEDGE |
| **VFBEDGE** | V | 0.0 | -- | Flat-band voltage of front gate of edge transistors at TR |
| VFBEDGEO | V | 0.0 | -- | Long/wide channel value of VFBEDGE |
| VFBEDGEL | V | 0.0 | -- | Channel length scaling parameter of VFBEDGE |
| VFBEDGELEXP | -- | 2.0 | -- | Channel length scaling exponent of VFBEDGE |
| VFBEDGEW | V | 0.0 | -- | Channel width scaling parameter of VFBEDGE |
| VFBEDGELW | V | 0.0 | -- | Channel area scaling parameter of VFBEDGE |
| **VFBBEDGE** | V | 0.0 | -- | Flat-band voltage of back gate of edge transistors at TR |
| VFBBEDGEO | V | 0.0 | -- | Long/wide channel value of VFBBEDGE |
| **STVFBEDGE** | V/K | 0.0 | -- | Temperature dependence of VFBEDGE and VFBBEDGE |
| STVFBEDGEO | V/K | 0.0 | -- | Long/wide channel value of STVFBEDGE |
| STVFBEDGEL | -- | 0.0 | -- | Channel length scaling parameter of STVFBEDGE |
| STVFBEDGEW | -- | 0.0 | -- | Channel width scaling parameter of STVFBEDGE |
| STVFBEDGELW | -- | 0.0 | -- | Channel area scaling parameter of STVFBEDGE |
| **CICFEDGE** | -- | 1.0 | [0.1, 10.0] | Front interface coupling coefficient of edge transistors |
| CICFEDGEO | -- | 1.0 | [0.1, 10.0] | Global scale parameter for CICFEDGE |
| **CICEDGE** | -- | 1.0 | [0.1, 10.0] | Back interface coupling coefficient of edge transistors |
| CICEDGEO | -- | 1.0 | [0.1, 10.0] | Global scale parameter for CICEDGE |
| PSCEEDGE | -- | 0.0 | [0.0, 5.0] | Short channel effect coefficient of edge transistors |
| PSCEEDGEL | -- | 0.0 | -- | Channel length scaling parameter of PSCEEDGE |
| PSCEEDGELEXP | -- | 2.0 | -- | Channel length scaling exponent of PSCEEDGE |
| PSCEEDGEW | -- | 0.0 | -- | Channel width scaling parameter of PSCEEDGE |
| PSCEBEDGE | -- | 1.0 | [0.0, --] | Short channel back-to-front asymmetry factor of edge transistors |
| PSCEBEDGEO | -- | 1.0 | [0.0, --] | Global scale parameter for PSCEBEDGE |
| CFEDGE | -- | 0.0 | [0.0, --] | DIBL parameter of edge transistors |
| CFEDGEL | -- | 0.0 | -- | Channel length scaling parameter of CFEDGE |
| CFEDGELEXP | -- | 2.0 | -- | Channel length scaling exponent of CFEDGE |
| CFEDGEW | -- | 0.0 | -- | Channel width scaling parameter of CFEDGE |
| CFBEDGE | -- | 1.0 | [0.0, --] | DIBL back-to-front asymmetry factor of edge transistors |
| CFBEDGEO | -- | 1.0 | [0.0, --] | Global scale parameter for CFBEDGE |
| CFDEDGE | -- | 0.2 | [0.05, --] | Drain voltage dependence of DIBL of edge transistors |
| CFDEDGEO | -- | 0.2 | [0.05, --] | Global scale parameter for CFDEDGE |
| BETNEDGE | m$^2$/V/s | 0.05 | [$10^{-10}$, --] | Front channel aspect ratio times zero-field mobility of edge transistors |
| FBETEDGE | -- | 0 | -- | Length dependence of edge transistor mobility |
| LPEDGE | m | $10^{-8}$ | [$10^{-10}$, --] | Exponent for length dependence of edge transistor mobility |
| BETEDGEW | -- | 0 | -- | Width scaling coefficient of edge transistor mobility |
| **STBETEDGE** | -- | 1.5 | -- | Temperature dependence of BETNEDGE |
| STBETEDGEO | -- | 1.5 | -- | Long/wide channel value of STBETEDGE |
| STBETEDGEL | -- | 0.0 | -- | Channel length scaling parameter of STBETEDGE |
| STBETEDGEW | -- | 0.0 | -- | Active width scaling parameter of STBETEDGE |
| STBETEDGELW | -- | 0.0 | -- | Active area scaling parameter of STBETEDGE |

### Impact Ionization Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **A1** | -- | 1.0 | [0.0, --] | Impact ionization pre-factor |
| A1O | -- | 1.0 | -- | Global scale parameter for A1 |
| A1L | -- | 0.0 | -- | Channel length scaling parameter of A1 |
| A1W | -- | 0.0 | -- | Channel width scaling parameter of A1 |
| **A2** | -- | 10.0 | [0.0, --] | Impact ionization exponent at TR |
| A2O | -- | 10.0 | [0.0, --] | Global scale parameter for A2 |
| **STA2** | -- | 0.0 | -- | Temperature dependence of A2 |
| STA2O | -- | 0.0 | -- | Global scale parameter for STA2 |
| **A3** | -- | 1.0 | [0.0, --] | Saturation voltage dependence of impact ionization |
| A3O | -- | 1.0 | -- | Global scale parameter for A3 |
| A3L | -- | 0.0 | -- | Channel length scaling parameter of A3 |
| A3W | -- | 0.0 | -- | Channel width scaling parameter of A3 |

### Charge Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| AREAQ | m$^2$ | $10^{-12}$ | [$10^{-18}$, --] | Effective channel area for intrinsic charge model |
| **CGBOV** | F | 0.0 | [0.0, --] | Oxide capacitance for gate to substrate overlap |
| CGBOVO | F | 0.0 | -- | Global scale parameter for CGBOV |
| CGBOVL | F | 0.0 | -- | Gate length scaling parameter of CGBOV |
| **NSDAC** | cm$^{-3}$ | $10^{22}$ | [$10^{18}$, $10^{22}$] | Source/drain effective doping level for AC model |
| NSDACO | cm$^{-3}$ | $10^{22}$ | [$10^{18}$, $10^{22}$] | Global scale parameter for NSDAC |
| **FIF** | -- | 0.0 | [0.0, --] | Inner fringe capacitance pre-factor |
| FIFW | -- | 0.0 | [0.0, --] | FIF value for a WEN width |
| **FSCEAC** | -- | 0.0 | [0.0, --] | Short channel effect adjustment factor for charge model |
| FSCEACO | -- | 0.0 | [0.0, --] | Global scale parameter for FSCEAC |
| **VFBAC** | V | 0.0 | -- | Front gate workfunction at TR when SWQMOD=1 |
| VFBACO | V | 0.0 | -- | Long/wide channel value of VFBAC |
| VFBACL | V | 0.0 | -- | Channel length scaling parameter of VFBAC |
| VFBACLEXP | -- | 2.0 | -- | Channel length scaling exponent of VFBAC |
| VFBACL2 | -- | 0.0 | -- | Second order channel length dependence of VFBAC |
| VFBACLEXP2 | -- | 2.0 | -- | Second order channel length scaling exponent of VFBAC |
| VFBACW | V | 0.0 | -- | Channel width scaling parameter of VFBAC |
| VFBACLW | V | 0.0 | -- | Channel area scaling parameter of VFBAC |
| **VFBBAC** | V | 0.0 | -- | Back gate workfunction offset at TR when SWQMOD=1 |
| VFBBACO | V | 0.0 | -- | Long/wide channel value of VFBBAC |
| VFBLBACO | -- | 0.0 | -- | Back-to-front interface asymmetry factor for VFBBAC |
| **PSCEAC** | -- | 0.0 | [0.0, 5.0] | Short channel coupling attenuation when SWQMOD=1 |
| PSCEACL | -- | 0.0 | -- | Channel length scaling parameter of PSCEAC |
| PSCEACLEXP | -- | 2.0 | -- | Channel length scaling exponent of PSCEAC |
| PSCEACW | -- | 0.0 | -- | Channel width scaling parameter of PSCEAC |
| **CFAC** | -- | 0.0 | -- | DIBL parameter at TR when SWQMOD=1 |
| CFACL | -- | 0.0 | -- | Channel length scaling parameter of CFAC |
| CFACLEXP | -- | 2.0 | -- | Channel length scaling exponent of CFAC |
| CFACW | -- | 0.0 | -- | Channel width scaling parameter of CFAC |
| **THESATAC** | V$^{-1}$ | 0.0 | -- | Velocity saturation parameter at TR when SWQMOD=1 |
| THESATACO | s/m$^2$ | 0.0 | -- | Long/wide channel parameter for THESATAC |
| THESATACL | s/m$^2$ | 0.0 | -- | Channel length scaling parameter of THESATAC |
| THESATACLEXP | -- | 1.0 | -- | Channel length scaling exponent of THESATAC |
| THESATACW | -- | 0.0 | -- | Channel width scaling parameter of THESATAC |
| THESATACLW | -- | 0.0 | -- | Channel area scaling parameter of THESATAC |
| **AXAC** | -- | 8.0 | [1.0, 16.0] | Linear/saturation transition exponent when SWQMOD=1 |
| AXACO | -- | 8.0 | -- | Long/wide channel value of AXAC |
| AXACL | -- | 0.0 | -- | Channel length scaling parameter of AXAC |
| AXACLEXP | -- | 1.0 | -- | Channel length scaling exponent of AXAC |
| AXACL2 | -- | 0.0 | -- | Second order channel length scaling parameter of AXAC |
| AXACLEXP2 | -- | 1.5 | -- | Second order channel length scaling exponent of AXAC |
| **ALPAC** | -- | 0.0 | [0.0, --] | Channel length modulation pre-factor when SWQMOD=1 |
| ALPACL1 | -- | 0.0 | -- | Channel length scaling parameter of ALPAC |
| ALPACLEXP | -- | 1.0 | -- | Channel length scaling exponent of ALPAC |
| ALPACL2 | -- | 0.0 | -- | Second order channel length dependence of ALPAC |
| ALPACLEXP2 | -- | 2.0 | -- | Second order channel length scaling exponent of ALPAC |
| ALPACW | -- | 0.0 | -- | Channel width scaling parameter of ALPAC |
| **COV** | F | 0.0 | [0.0, --] | Overlap capacitance per side |
| LOVO | m | 0.0 | [0.0, --] | Overlap length for gate/source-drain overlap capacitance |
| **COVD** | F | 0.0 | [0.0, --] | Overlap capacitance at drain side |
| LOVDO | m | 0.0 | [0.0, --] | Overlap length for gate/drain overlap capacitance |
| **COVDL** | -- | 0.0 | -- | Overlap capacitance modulation due to Leff bias-dependence |
| COVDLO | -- | 0.0 | -- | Wide channel parameter for COVDL |
| COVDLW | -- | 0.0 | -- | Channel width scaling parameter of COVDL |
| **COVDLB** | -- | 0.0 | -- | Overlap capacitance modulation with back bias |
| COVDLBO | -- | 0.0 | -- | Global scale parameter for COVDLB |
| **DVFBOV** | V | 0.0 | -- | Overlap capacitance flat-band voltage adjustment |
| DVFBOVO | V | 0.0 | -- | Global scale parameter for DVFBOV |
| **CFR** | F | 0.0 | [0.0, --] | Outer fringe capacitance per side |
| CFRO | F | 0.0 | -- | Corner related outer fringe capacitance |
| CFRW | F | 0.0 | -- | Outer fringe capacitance per side for a WEN width |
| **CFRD** | F | 0.0 | [0.0, --] | Outer fringe capacitance at drain side |
| CFRDO | F | 0.0 | -- | Corner related outer fringe capacitance at drain side |
| CFRDW | F | 0.0 | -- | Outer fringe capacitance at drain side for a WEN width |
| **CSD** | F | $1.04 \times 10^{-18}$ | [0.0, --] | Drain to source direct capacitance |
| CSDO | -- | 1.0 | [0.0, --] | Drain to source direct capacitance correction factor |
| **CSDBP** | F/m | 0.0 | [0.0, --] | Drain/source to substrate perimeter capacitance |
| CSDBPO | F/m | 0.0 | [0.0, --] | Global scale parameter for CSDBP |

### Self-Heating Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **RTH** | K/W | $10^{4}$ | -- | Thermal resistance |
| RTHO | K/W | $10^{5}$ | -- | Global scale parameter for RTH |
| RTHL | -- | 1.5 | -- | Channel length scaling parameter of RTH and CTH |
| RTHW | -- | 3.0 | -- | Channel width scaling parameter of RTH and CTH |
| RTHLW | -- | 4.5 | -- | Channel area scaling parameter of RTH and CTH |
| **STRTH** | -- | 0.0 | -- | Temperature dependence of RTH |
| STRTHO | -- | 0.0 | -- | Global scale parameter for STRTH |
| **CTH** | J/K | $10^{-11}$ | [0.0, --] | Thermal capacitance |
| CTHO | J/K | $10^{-12}$ | -- | Global scale parameter for CTH |
| LAMBTHO | m | $10^{-7}$ | [$10^{-9}$, --] | Characteristic length of thermal coupling for multi-finger devices |
| FTHO | -- | 0.0 | [0.0, --] | First neighbour thermal coupling factor for multi-finger devices |

### Noise Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **FNT** | -- | 1.0 | [0.0, --] | Thermal noise coefficient |
| FNTO | -- | 1.0 | [0.0, --] | Global scale parameter for FNT |
| **FNTEXC** | -- | 0.0 | [0.0, --] | Excess noise coefficient |
| FNTEXCL | -- | 0.0 | [0.0, --] | Channel length scaling pre-factor of FNTEXC |
| FNTEXCLEXP | -- | 2.0 | -- | Channel length scaling exponent of FNTEXC |
| **NFA** | V$^{-1}$m$^{-4}$ | $8 \times 10^{22}$ | -- | First coefficient of flicker noise |
| NFALW | V$^{-1}$m$^{-4}$ | $8 \times 10^{22}$ | -- | Channel area scaling parameter of NFA |
| NFAW | -- | 0.0 | -- | Channel width scaling parameter of NFA |
| **NFB** | V$^{-1}$m$^{-2}$ | $3 \times 10^{7}$ | [0.0, --] | Second coefficient of flicker noise |
| NFBLW | V$^{-1}$m$^{-2}$ | $3 \times 10^{7}$ | [0.0, --] | NFB value for a LEN.WEN area |
| **NFC** | V$^{-1}$ | 0.0 | [0.0, --] | Third coefficient of flicker noise |
| NFCLW | V$^{-1}$ | 0.0 | [0.0, --] | NFC value for a LEN.WEN area |
| **NFE** | -- | 0.0 | [-1.0, 1.0] | Front interface transverse field effect coefficient |
| NFEO | -- | 0.0 | [-1.0, 1.0] | Global scale parameter for NFE |
| **NFEB** | -- | 0.0 | [-1.0, 1.0] | Back interface transverse field effect coefficient |
| NFEBO | -- | 0.0 | [-1.0, 1.0] | Global scale parameter for NFEB |
| **EF** | -- | 1.0 | [0.1, --] | Frequency dependence exponent of flicker noise |
| EFO | -- | 1.0 | [0.1, --] | Global scale parameter for EF |

### NQS Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **KDRIFT** | -- | 1.0 | [0.0, --] | Drift component parameter of NQS effect |
| KDRIFTO | -- | 1.0 | [0.0, --] | Geometry independent drift component parameter |
| KDRIFTL | -- | 0.0 | -- | Length dependence of KDRIFT |
| **KDIFF** | -- | 1.0 | [0.0, --] | Diffusion component parameter of NQS effect |
| KDIFFO | -- | 1.0 | [0.0, --] | Geometry independent diffusion component parameter |
| KDIFFL | -- | 0.0 | -- | Length dependence of KDIFF |
| **FRACINV** | -- | 1.0 | [0.0, 1.0] | Fraction of inversion charge for second pole of NQS transition |
| FRACINVO | -- | 1.0 | [0.0, 1.0] | Global scale parameter for FRACINV |
| **KFRACINV** | -- | $10^{-15}$ | [$10^{-15}$, 1.0] | Second pole frequency coefficient of NQS transition |
| KFRACINVO | -- | $10^{-15}$ | [$10^{-15}$, 1.0] | Global scale parameter for KFRACINV |

### Cryogenic Temperature Effect Parameters (SWCRYO=1)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TMIN | K | 1.0 | [1.0, --] | Minimum temperature |
| ATMIN | -- | 0.0 | [0.0, 1.0] | Minimum temperature slope |
| BTMIN | K$^2$ | $10^{-3}$ | [0.0, $10^3$] | Minimum temperature smoothing parameter |

### Parasitic Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| **RG** | Ohm | 0 | [0, --] | Gate resistance |
| RGO | Ohm | 0 | -- | Geometry independent gate resistance |
| RINT | Ohm.m$^2$ | 0 | -- | Contact resistance between silicide and poly |
| RVPOLY | Ohm.m$^2$ | 0 | -- | Vertical poly resistance |
| RSHG | Ohm/sq | 0 | -- | Gate electrode diffusion sheet resistance |
| DLSIL | m | 0 | -- | Silicide extension over the physical gate length |
| RSE | Ohm | 0 | [0, --] | External source resistance |
| RSH | Ohm/sq | 0 | [0, --] | Sheet resistance of source diffusion |
| RDE | Ohm | 0 | [0, --] | External drain resistance |
| RSHD | Ohm/sq | 0 | [0, --] | Sheet resistance of drain diffusion |
| RWELL | Ohm | 0 | [0, --] | Well resistance |
| RWELLO | Ohm | 0 | [0, --] | Global scale parameter for RWELL |

---

## Equations

### 3.1 Scaling Equations -- Effective Dimensions

$$W_f = W / NF \tag{3.1}$$

$$A_{source,f} = \text{ASOURCE} / NF \tag{3.2}$$

$$A_{drain,f} = \text{ADRAIN} / NF \tag{3.3}$$

$$P_{source,f} = \text{PSOURCE} / NF \tag{3.4}$$

$$P_{drain,f} = \text{PDRAIN} / NF \tag{3.5}$$

$$Multf = \text{MULT} \cdot NF \tag{3.6}$$

Reference lengths: $L_{EN} = 10^{-6}$, $W_{EN} = 10^{-6}$.

$$\Delta L_{PS} = \text{LVARO} \cdot \left(1 + \text{LVARL} \cdot \frac{L_{EN}}{L}\right) \cdot \left(1 + \text{LVARW} \cdot \frac{W_{EN}}{W_f}\right) \tag{3.9}$$

$$\Delta W_{OD} = \text{WVARO} \cdot \left(1 + \text{WVARL} \cdot \frac{L_{EN}}{L}\right) \cdot \left(1 + \text{WVARW} \cdot \frac{W_{EN}}{W_f}\right) \tag{3.10}$$

$$L_E = L + \Delta L_{PS} - 2 \cdot \text{LAP} \tag{3.11}$$

$$W_E = W_f + \Delta W_{OD} - 2 \cdot \text{WOT} \tag{3.12}$$

$$L_{E,CV} = L + \Delta L_{PS} - 2 \cdot \text{LAP} + \text{DLQ} \tag{3.13}$$

$$W_{E,CV} = W_f + \Delta W_{OD} - 2 \cdot \text{WOT} + \text{DWQ} \tag{3.14}$$

$$L_{phy} = L + \Delta L_{PS} \tag{3.15}$$

$$W_{phy} = W_f + \Delta W_{OD} \tag{3.16}$$

### 3.1.2 Scaling -- Process Parameters

Direct assignments: $\text{TOXE}=\text{TOXEO}$, $\text{TSI}=\text{TSIO}$, $\text{XGE}=\text{XGEO}$, $\text{TBOX}=\text{TBOXO}$, $\text{NCH}=\text{NCHO}$, $\text{NSUB}=\text{NSUBO}$, $\text{CT}=\text{CTO}$, $\text{TOXP}=\text{TOXPO}$, $\text{NOV}=\text{NOVO}$, $\text{NOVD}=\text{NOVDO}$.

$$\text{VFB} = \text{VFBO} + \frac{\text{VFBL} \cdot \left(\frac{L_{EN}}{L_E}\right)^{\text{VFBLEXP}}}{1 + \text{VFBL2} \cdot \left(\frac{L_{EN}}{L_E}\right)^{\text{VFBLEXP2}}} + \text{VFBW} \cdot \frac{W_{EN}}{W_E} + \text{VFBLW} \cdot \frac{L_{EN}}{L_E} \cdot \frac{W_{EN}}{W_E} \tag{3.27}$$

$$\text{VFBB} = \text{VFBBO} + \text{VFBLBO} \cdot \frac{\text{TBOX}}{\text{TOXE}} \cdot \frac{\text{VFBL} \cdot \left(\frac{L_{EN}}{L_E}\right)^{\text{VFBLEXP}}}{1 + \text{VFBL2} \cdot \left(\frac{L_{EN}}{L_E}\right)^{\text{VFBLEXP2}}} \tag{3.28}$$

$$\text{STVFB} = \text{STVFBO} \cdot \left(1 + \text{STVFBL} \cdot \frac{L_{EN}}{L_E}\right) \cdot \left(1 + \text{STVFBW} \cdot \frac{W_{EN}}{W_E}\right) \cdot \left(1 + \text{STVFBLW} \cdot \frac{L_{EN}}{L_E} \cdot \frac{W_{EN}}{W_E}\right) \tag{3.29}$$

$$\text{NP} = \text{NPO} \cdot \max\left(10^{-6},\; 1 + \text{NPL} \cdot \frac{L_{EN}}{L_E}\right) \tag{3.30}$$

### 3.1.3 Scaling -- Gate to Interface Coupling

$$\lambda_{2D} = \sqrt{\frac{\epsilon_{Si}(1-\text{XGE}) + \epsilon_{Ge}\cdot\text{XGE}}{\epsilon_{ox}} \cdot \text{TSI} \cdot (\text{TOXE} + 4\times10^{-10})} \tag{3.33}$$

$$\text{PSCE} = 2 \cdot \text{PSCEL} \cdot \left(\frac{\lambda_{2D}}{L_E}\right)^{\text{PSCELEXP}} \cdot \left(1 + \text{PSCEW} \cdot \frac{W_{EN}}{W_E}\right) \tag{3.34}$$

### 3.1.4 Scaling -- DIBL

$$\text{CF} = \text{CFL} \cdot \left(\frac{\lambda_{2D}}{L_E}\right)^{\text{CFLEXP}} \cdot \left(1 + \text{CFW} \cdot \frac{W_{EN}}{W_E}\right) \tag{3.39}$$

$$\text{STCF} = \text{STCFL} \cdot \left(\frac{\lambda_{2D}}{L_E}\right)^{\text{CFLEXP}} \cdot \left(1 + \text{CFW} \cdot \frac{W_{EN}}{W_E}\right) \tag{3.41}$$

### 3.1.5 Scaling -- Mobility

$$LP1_{eff} = \text{LP1} \cdot \max\left(1 + \text{LP1W} \cdot \frac{W_{EN}}{W_E},\; 10^{-3}\right) \tag{3.45}$$

$$GPE = \max\left(1 + \text{FBET1}\left(1+\text{FBET1W}\frac{W_{EN}}{W_E}\right)\frac{1-e^{-L_E/LP1_{eff}}}{L_E/LP1_{eff}} + \text{FBET2}\frac{1-e^{-L_E/\text{LP2}}}{L_E/\text{LP2}},\; 10^{-6}\right) \tag{3.46}$$

$$GWE = \max\left(1 + \text{BETW1}\frac{W_{EN}}{W_E} + \text{BETW2}\frac{W_{EN}}{W_E}\ln\left(1+\frac{W_E}{\text{WBET}}\right),\; 10^{-6}\right) \tag{3.47}$$

$$GE = \text{UO} \cdot \frac{GWE}{GPE} \tag{3.48}$$

$$\text{BETN} = GE \cdot \frac{W_E}{L_E} \tag{3.49}$$

### 3.1.7 Scaling -- Velocity Saturation

$$\text{THESAT} = GE \cdot \left(\text{THESATO} + \text{THESATL}\left(\frac{L_{EN}}{L_E}\right)^{\text{THESATLEXP}}\right) \cdot \left(1+\text{THESATW}\frac{W_{EN}}{W_E}\right)\left(1+\text{THESATLW}\frac{L_{EN}}{L_E}\frac{W_{EN}}{W_E}\right) \tag{3.74}$$

### 3.1.8 Scaling -- Saturation and CLM

$$\text{AX} = \frac{\text{AXO}}{\left(1+\text{AXL}\left(\frac{L_{EN}}{L_E}\right)^{\text{AXLEXP}}\right)\left(1+\text{AXL2}\left(\frac{L_{EN}}{L_E}\right)^{\text{AXLEXP2}}\right)} \tag{3.78}$$

### 4.1 Internal Parameters -- Temperature Dependences

$$T_{KR} = 273.15 + \text{TR} \tag{4.1}$$

$$t_{kd} = 273.15 + T_{Ambient} + \text{DTEMP} \tag{4.2}$$

$$T_{KD} = \begin{cases}\text{MAX\_FUNC}(t_{kd}, \text{TMIN}+\text{ATMIN}\cdot t_{kd}, \text{BTMIN}) & \text{if SWCRYO}=1 \\ \text{MAX\_FUNC}(t_{kd}, 1.0, 10^{-3}) & \text{else}\end{cases} \tag{4.3}$$

$$T_{KC} = \begin{cases}T_{KD} + \Delta T_C & \text{if SWSHE}=1 \\ T_{KD} & \text{else}\end{cases} \tag{4.4}$$

$$\phi_{T0} = \frac{k_B \cdot T_{KC}}{q} \tag{4.6}$$

### 4.1.2 Local Process Parameters

$$\epsilon_{ch} = \epsilon_{Si}(1-\text{XGE}) + \epsilon_{Ge}\cdot\text{XGE} \tag{4.8}$$

$$E_{g,Si} = E_{g0,Si} - \frac{\alpha_{Si}\cdot T_{KC}^2}{\beta_{Si}+T_{KC}} \tag{4.9}$$

$$E_{g,Ge} = E_{g0,Ge} - \frac{\alpha_{Ge}\cdot T_{KC}^2}{\beta_{Ge}+T_{KC}} \tag{4.10}$$

$$\delta E_g = (E_{g,Ge} - E_{g,Si} + C_G(1-\text{XGE}))\cdot\text{XGE} \tag{4.11}$$

$$E_g = E_{g,Si} + \delta E_g \tag{4.12}$$

$$n_{eff} = \frac{n_{i,fact,300}}{\sqrt{1+10\cdot\text{XGE}}} \cdot \left(\frac{T_{KC}}{300}\right)^{3/2} \tag{4.13}$$

### 4.1.3 Interface Coupling Internal Parameters

$$C'_{ox1} = \frac{\epsilon_{ox}}{\text{TOXE}}, \quad C'_{ox2} = \frac{\epsilon_{ox}}{\text{TBOX}}, \quad C'_{Si0} = \frac{\epsilon_{ch}}{\text{TSI}} \tag{4.17--4.19}$$

$$\phi_T = \phi_{T0}\left(1+\text{CT}\cdot\frac{T_{KR}}{T_{KC}}\right) \tag{4.20}$$

$$k_{1,1D} = \frac{C'_{ox1}}{C'_{Si0}}, \quad k_{2,1D} = \frac{C'_{ox2}}{C'_{Si0}}, \quad k_{eq,1D} = \frac{1}{1+1/k_{1,1D}+1/k_{2,1D}} \tag{4.21--4.23}$$

### 4.1.4 DIBL Internal Parameters

$$CF_1 = \text{CF} + \text{STCF}\cdot\Delta T \tag{4.29}$$

$$CF_2 = \text{CF}\cdot\text{CFB}\cdot\frac{\text{TBOX}}{\text{TOXE}} + \text{STCF}\cdot\Delta T \tag{4.30}$$

$$x_{d0} = \frac{\text{CFD}}{\phi_T} \tag{4.31}$$

### 4.1.8 Mobility Internal Parameters

$$\beta_{N1} = \text{BETN}\cdot\left(\frac{T_{KR}}{T_{KC}}\right)^{\text{STBET}} \tag{4.47}$$

$$\beta_{N2} = \text{BETN}\cdot\text{BETNB}\cdot\left(\frac{T_{KR}}{T_{KC}}\right)^{\text{STBET}} \tag{4.48}$$

$$\mu_E = \text{MUE}\cdot\left(\frac{T_{KR}}{T_{KC}}\right)^{\text{STMUE}} \tag{4.49}$$

### 4.1.10 Velocity Saturation Internal Parameters

$$\theta_{sat} = \text{FACTUO}\cdot\text{THESAT}\cdot\left(\frac{T_{KR}}{T_{KC}}\right)^{\text{STTHESAT}+\text{STBET}} \tag{4.60}$$

$$f_{vsat} = \phi_T\cdot\theta_{sat} \tag{4.61}$$

### 4.1.11 CLM Internal Parameters

$$\gamma_{AX} = (216/\text{AX} - 1)^{3/8} - 1 \tag{4.62}$$

### 4.1.12 Gate Current Internal Parameters

$$B_{ch} = \frac{4}{3}\cdot\frac{\sqrt{2q\cdot m_0\cdot\text{CHIB}}}{\hbar}\cdot\text{TOXP} \tag{4.71}$$

$$\alpha_b = \frac{E_g}{2} \tag{4.76}$$

### 4.2 Intrinsic Surface Potentials and Charges

#### 4.2.1 Terminal Voltage Conditioning

$$x_d = \frac{V_{DS}}{\phi_T} \tag{4.111}$$

$$x_{dsx} = \frac{\sqrt{V_{DS}^2+0.01}-0.1}{\phi_T} \tag{4.112}$$

$$x_{g10} = \frac{V_{GS}-VFB_1}{\phi_T} - \frac{x_d-x_{dsx}}{2} - \frac{E_g}{2\phi_{T0}} \tag{4.113}$$

$$x_{g20} = \frac{-V_{SB}-VFB_2}{\phi_T} - \frac{x_d-x_{dsx}}{2} - \frac{E_g}{2\phi_{T0}} \tag{4.114}$$

#### 4.2.4 Short Channel Effects

$$\delta l_{eff} = \sqrt{1 + 2\frac{x_{th,1D}-x_{1D}}{x_{SD,dep}}} - 1 \tag{4.175}$$

$$csce_1 = \frac{1}{1+PSCE_1\cdot\text{MAX\_FUNC}(1+\text{PSCEDLB}\cdot x_{g20shift}, 0.5, 0.01)} \tag{4.177}$$

$$\delta x_{g1,DIBL} = 2\cdot CF_1\cdot x_{d0}\left(\sqrt{1+x_{dsx}/x_{d0}}-1\right)(1+\text{CFDL}\cdot\delta l_{eff})(1+\text{CFDLB}\cdot x_{g20shift}) \tag{4.179}$$

$$x_{g1} = (x_{g10}-x_{edge}+\delta x_{g1,DIBL})\cdot csce_1 + x_{edge} + \frac{x_d-x_{dsx}}{2} \tag{4.181}$$

$$x_{g1x} = \text{MIN\_FUNC}(x_{g2}+\text{CICF}\cdot(x_{g1}-x_{g2}),\; x_{satmax},\; 0.01) \tag{4.183}$$

#### 4.2.6 Inversion Charge at Source

$$q_{1S} = \text{CHARGE\_DENSITY}(x_{g1x}, x_{g2x}, 0) \tag{4.194}$$

$$Ae_{1S} = A_0\cdot\exp(x_{g1x}-q_{1S}) \tag{4.195}$$

$$qi_S = k_1\cdot q_{1S} + k_2\cdot q_{2S} \tag{4.212}$$

#### 4.2.7 Mobility Attenuation at Source

$$e_{surf1S} = 2\ln(1+\exp(k_1 q_{1S}/2)) \tag{4.221}$$

$$e_{eff1S} = \eta_\mu\cdot e_{surf1S} + (1-\eta_\mu)\cdot e_{cpl1S} \tag{4.225}$$

$$Gmob_S = f_{cor,S}\cdot\frac{c_{1S}+c_{2S}}{c_{1S}/Gmob_{1S}+c_{2S}/Gmob_{2S}} \tag{4.237}$$

#### 4.2.8 Drain Saturation Voltage

$$x_{Deff} = \frac{x_D}{\left[(1+\gamma_{AX}(x_D/x_{nDS,sat})^{8/3})^4 + (x_D/x_{nDS,sat})^{16}\right]^{1/16}} \tag{4.285}$$

#### 4.2.13 Channel Length Modulation

$$\Delta L/L = \text{ALP}\cdot f_{clm}\cdot r_1 \tag{4.344}$$

$$f_{clm} = \ln\left(1+\frac{x_D-x_{Deff}}{\text{VP}/\phi_T + \text{VPG}\cdot q_{im}^2}\right) \tag{4.343}$$

#### 4.2.14 Velocity Saturation

$$G_\gamma = f_{vsat}\cdot\delta x_{drift}\cdot\frac{satfact_1+satfact_2}{2} \tag{4.350}$$

$$z_{sat} = \frac{G_\gamma}{Gmob\cdot G_{\Delta L}} \tag{4.351}$$

#### 4.2.16 Normalized Channel Current

$$i_{DS,norm} = q_{im}\cdot\delta x_{drift} + \delta i_{drift} + qi_S - qi_D \tag{4.364}$$

### 4.3 Channel Current

$$\beta_{Neff} = \text{FACTUO}\cdot\frac{c_{sum,dc}}{e_{surf1,dc}+e_{surf2,dc}} \tag{4.383}$$

$$I_{DS} = \frac{F_{\Delta L}}{G_{vsat}\cdot qmfact}\cdot\beta_{Neff}\cdot\phi_T^2\cdot C'_{Si,dc}\cdot i_{DS,norm,dc} \tag{4.389}$$

### 4.5 Gate Current

#### Gate to Source Overlap

$$\psi_t = \text{MIN\_FUNC}(V_{ovS}+D_{ov}, 0, 0.01) \tag{4.410}$$

$$I_{GS,ov} = I_{G,oveff}\cdot\ln\frac{1+\Delta_{Si}}{1+\Delta_{gate}}\cdot\exp\left(B_{ov}\cdot z_g(GC2_{oveff}+z_g\cdot GC3_{oveff})-\tfrac{3}{2}\right)\cdot f_{GS,ov} - I_{G,oveff,fowler}\cdot\exp\left(-B_{ov}\cdot\frac{\text{GCOVINVFN}}{z_g}\right)\cdot f_{GS,ov} \tag{4.420}$$

#### Gate to Channel

$$I_{GC0} = I_{G,inv}\cdot\ln\frac{1+\Delta_{Si}}{1+\Delta_{gate}}\cdot\exp\left(B_{ch}\cdot z_g(GC2CH+z_g\cdot GC3CH)-\tfrac{3}{2}\right) \tag{4.441}$$

$$I_{GS} = I_{GCS} + I_{GS,ov} \tag{4.454}$$

$$I_{GD} = I_{GCD} + I_{GD,ov} \tag{4.455}$$

### 4.6 GIDL/GISL

$$V_{tovS} = \sqrt{V_{ovS}^2 + \text{CGIDL}^2\cdot V_{SB}^2 + 10^{-6}} \tag{4.456}$$

$$I_{GISL} = -\overline{\text{AGIDL}}\cdot V_{SD}\cdot V_{ovS}\cdot V_{tovS}\cdot\exp\left(-\frac{\overline{\text{BGIDL}}}{V_{tovS}}\right)\cdot\frac{1+\exp(\text{DGIDL}\cdot V_{SD})}{2} \tag{4.457}$$

$$I_{GIDL} = -\overline{\text{AGIDLD}}\cdot V_{DS}\cdot V_{ovD}\cdot V_{tovD}\cdot\exp\left(-\frac{\overline{\text{BGIDLD}}}{V_{tovD}}\right)\cdot\frac{1+\exp(\text{DGIDLD}\cdot V_{DS})}{2} \tag{4.459}$$

### 4.7 Edge Transistor Current

Calculated when SWEDGE=1 and BETNEDGE>0. Uses dedicated flat-band, coupling, and DIBL parameters for the edge transistor.

$$I_{DS,edge} = \frac{C'_{ox1}\cdot\beta_{N,edge}\cdot\phi_{T,edge}^2}{Gmob}\cdot i_{DS,norm,edge} \tag{4.487}$$

### 4.8 Impact Ionization

$$\Delta V_{sat} = (x_{d,dc}-\text{A3}\cdot x_{Deff,dc})\cdot\phi_T \tag{4.488}$$

$$M_{avl} = \begin{cases}0 & \Delta V_{sat}\le 0 \\ \text{A1}\cdot\Delta V_{sat}\cdot\exp\left(-\frac{a_2}{\Delta V_{sat}}\right) & \Delta V_{sat}>0\end{cases} \tag{4.489}$$

$$I_{impact} = M_{avl}\cdot I_{DS} \tag{4.490}$$

### 4.9 Charge Model

#### Intrinsic Charges

$$Q_G = C'_{Si,ac}\cdot f_{area}\cdot\left(k_1 q_{1eff}\cdot ratio_{pd,ac} + \frac{\Delta k_1 q_{1,ac}}{3}\cdot P_{1,ac}\right) \tag{4.495}$$

$$Q_B = C'_{Si,ac}\cdot f_{area}\cdot\left(k_2 q_{2eff} + \frac{\Delta k_2 q_{2,ac}}{3}\cdot P_{2,ac}\right) \tag{4.496}$$

$$Q_D = -\frac{1}{2}C'_{Si,ac}\cdot f_{area}\cdot\left[\left(k_1 q_{1eff}\cdot ratio_{pd,ac}+\frac{\Delta k_1 q_{1,ac}}{3}\right)\left(1+P_{1,ac}-\frac{P_{1,ac}^2}{5}\right) + \left(k_2 q_{2eff}+\frac{\Delta k_2 q_{2,ac}}{3}\right)\left(1+P_{2,ac}-\frac{P_{2,ac}^2}{5}\right)\right] \tag{4.497}$$

#### Parasitic Charges

$$Q_{GS} = \text{CFR}\cdot V_{GS}, \quad Q_{GD} = \text{CFRD}\cdot V_{GD} \tag{4.514--4.515}$$

$$Q_{ovS} = \text{COV}\cdot V_{ovS,cv}\cdot\text{MAX\_FUNC}(1-\text{COVDL}\cdot\delta l_{eff,ac}(1-\text{COVDLB}\cdot x_{g20shift,ac}), 0, 0.01) \tag{4.516}$$

$$Q_{GB} = \text{CGBOV}\cdot V_{GB} \tag{4.518}$$

$$Q_{DS} = \text{CSD}\cdot V_{DS} \tag{4.519}$$

$$Q_{BS} = -\left(\frac{\epsilon_{ox}}{\text{TBOX}}\cdot A_{source,f} + \text{CSDBP}\cdot P_{source,f}\right)\cdot V_{SB} \tag{4.520}$$

### 4.10 Self-Heating

$$\Delta T_C = \text{Temp}(T_{node}) \tag{4.522}$$

$$I_{th} = \frac{\Delta T_C}{R_{th}} - I_{DS}\cdot V_{DS} \tag{4.523}$$

$$Q_{th} = \text{CTH}\cdot\Delta T_C \tag{4.524}$$

### 4.11 Noise Model

#### Channel Thermal Noise

$$g_{ideal} = \beta_{Neff}\cdot C'_{Si,dc}\cdot\phi_T\cdot q^*_{im}\cdot\frac{F_{\Delta L}}{G_{vsat}\cdot qmfact} \tag{4.531}$$

$$S_{ids,th} = \text{MULT\_I}\cdot n_T\cdot g_{Sid} \tag{4.534}$$

where $n_T = 4 k_B T_{KC}\cdot\text{FNT}$.

#### Channel Flicker Noise

$$S_{ids,fl} = \frac{q\cdot\beta_{Neff}\cdot\phi_T^2\cdot I_{DS}}{f_{op}^{EF}\cdot G_{vsat,dc}\cdot N^*}\cdot f_{NFE}\cdot\left[\left(\text{NFA}-\text{NFB}\cdot N^*+\text{NFC}\cdot N^{*2}\right)\cdot\ln\frac{N^*_m+\Delta N/2}{N^*_m-\Delta N/2}+(\text{NFB}+\text{NFC}(N^*_m-2N^*))\cdot\Delta N\right] \tag{4.554}$$

#### Shot Noises

$$S_{igs,sh} = \text{MULT\_I}\cdot 2q|I_{GS}| \tag{4.555}$$

$$S_{igd,sh} = \text{MULT\_I}\cdot 2q|I_{GD}| \tag{4.556}$$

$$S_{ids,sh} = \text{MULT\_I}\cdot 2q|I_{GIDL}-I_{GISL}| \tag{4.557}$$

$$S_{avl} = \text{MULT\_I}\cdot 2q(M_{avl}+1)|I_{impact}| \tag{4.558}$$

#### Parasitic Resistance Noise

$$S_{RG} = \text{MULT\_I}\cdot 4k_B T_{KD}/RG \tag{4.559}$$

$$S_{RS} = \text{MULT\_I}\cdot 4k_B T_{KD}/RSE \tag{4.560}$$

$$S_{RD} = \text{MULT\_I}\cdot 4k_B T_{KD}/RDE \tag{4.561}$$

### 4.12 Total Currents and Charges

#### Static Currents

$$I_{DS} = \text{MULT\_I}\cdot Multf\cdot\text{TYPE}\cdot(I_{DS}+I_{GIDL}-I_{GISL}+I_{impact}+I_{DS,edge}) \tag{4.563}$$

$$I_{GS} = \text{MULT\_I}\cdot Multf\cdot\text{TYPE}\cdot I_{GS} \tag{4.564}$$

$$I_{GD} = \text{MULT\_I}\cdot Multf\cdot\text{TYPE}\cdot I_{GD} \tag{4.565}$$

#### Total Charges

$$Q_{G,tot} = \text{MULT\_Q}\cdot Multf\cdot\text{TYPE}\cdot(Q_G+Q_{GS,if}+Q_{GD,if}+Q_{GS}+Q_{GD}+Q_{ovS}+Q_{ovD}+Q_{GB}) \tag{4.569}$$

$$Q_{D,tot} = \text{MULT\_Q}\cdot Multf\cdot\text{TYPE}\cdot(Q_D+Q_{DS}-Q_{GD,if}-Q_{GD}-Q_{ovD}-Q_{BD,if}-Q_{BD}) \tag{4.570}$$

$$Q_{B,tot} = \text{MULT\_Q}\cdot Multf\cdot\text{TYPE}\cdot(Q_B+Q_{BS,if}+Q_{BD,if}+Q_{BS}+Q_{BD}-Q_{GB}) \tag{4.571}$$

$$Q_{S,tot} = -Q_{G,tot}-Q_{D,tot}-Q_{B,tot} \tag{4.572}$$

### 4.12.4 NQS Dynamic Currents

$$Q_{i,wo,mult} = Q_{G,wo,mult} + Q_{B,wo,mult} \tag{4.579}$$

$$\frac{1}{\tau} = \text{MULT\_I}\cdot\frac{\beta_{Neff}}{G_{vsat}\cdot\text{AREAQ}}\cdot\left(\text{KDRIFT}\cdot\frac{Q_{i,wo,mult}}{\text{AREAQ}\cdot C'_{ox1}}+\text{KDIFF}\cdot\phi_T\right) \tag{4.580}$$

---

## Appendix: Useful Functions

$$\text{MIN\_FUNC}(x,y,a) = \frac{1}{2}\left(x+y-\sqrt{(x-y)^2+a}\right) \tag{C.1}$$

$$\text{MAX\_FUNC}(x,y,a) = \frac{1}{2}\left(x+y+\sqrt{(x-y)^2+a}\right) \tag{C.2}$$

$$W_0(x) \approx \ln(1+x)\cdot\left(1-\frac{\ln(1+\ln(1+x))}{2+\ln(1+x)}\right) \tag{C.8}$$

Sigma functions for backplane surface potential:

$$\nu = a+c \tag{C.3}$$

$$\mu_3 = \frac{\nu^2}{\tau} + \frac{c^2}{2} - a \tag{C.4}$$

$$\sigma_3(a,c,\tau,\eta) = \eta + \frac{a\nu}{\mu_3 + c\cdot\frac{c^2/3 - a}{\nu}\cdot\mu_3} \tag{C.5}$$

$$\mu_2 = \frac{\nu^2}{\tau} + \frac{c^2}{2} - ab \tag{C.6}$$

$$\sigma_2(a,b,c,\tau,\eta) = \eta + \frac{a\nu}{\mu_2 + c\cdot\frac{c^2/3 - ab}{\nu}\cdot\mu_2} \tag{C.7}$$

## Appendix: Surface Potential Calculation (Appendix A)

The CHARGE_DENSITY function computes the front gate charge density $q_1$ for given normalized gate voltages $x_{g1}$, $x_{g2}$ and quasi-Fermi level $\delta_n$:

1. **Initial guess** (A.2): Compute saturation and weak-inversion estimates $x_{1,sat}$, $x_{2,sat}$, then smooth between them.
2. **Global correction** (A.1): Newton-like iteration on the implicit charge equation using second-order correction.
3. **First strong-inversion correction**: Refine $q_1$ using $q_2$ from the initial guess with an approximate $fqsq$ formula.
4. **Second strong-inversion correction**: Further refine $q_1$.
5. **Two more global corrections** (total of 4 global corrections, plus an extra if SWCRYO=1 and error > 0.01).

The global correction solves:

$$f_{zero} = qi_{int}\cdot f_{en} - A_0\cdot\exp(x_{g1}-q_1-\delta_n) \tag{A.56}$$

using a Halley-like update:

$$\epsilon_2 = -\frac{f_{zero}\cdot d_{1,zero}\cdot d_{temp}}{d_{temp}^2 + 10^{-200}} \tag{A.60}$$

where $d_{temp} = d_{1,zero}^2 - 0.5\cdot f_{zero}\cdot d_{2,zero}$.

## Appendix: Overlap Surface Potential (Appendix B)

The SP_FDSOI_OV function computes the surface potential in the overlap region using a PSP-like approach with three regimes (small signal, accumulation, inversion) and a sigma-function based solver.
