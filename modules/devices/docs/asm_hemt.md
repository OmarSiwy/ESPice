# ASM-HEMT 101.6.0 -- Parameter & Equation Reference

> GaN HEMT (AlGaN/GaN High Electron Mobility Transistor)

## Model Topology

ASM-HEMT is a surface-potential-based compact model for AlGaN/GaN HEMTs with four external terminals: Gate (G), Drain (D), Source (S), and Substrate (B). The intrinsic device is augmented by bias-dependent source and drain access-region resistances, an RC self-heating network (thermal node dT), up to eight field-plate sub-transistors (four drain-side, four source-side) each selectable as gate-connected or source-connected, trap RC sub-circuits (TRAPMOD 1--5), gate resistance, parasitic/overlap/fringing capacitances, substrate capacitances, gate diode currents, drain-source breakdown, and substrate leakage currents.

---

## Parameters

### Process Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TNOM | deg C | 27 | [-273.15, inf) | Nominal temperature |
| TBAR | m | 2.5e-8 | [0.1e-9, inf) | AlGaN barrier layer thickness |
| TEPI | m | 1.64e-6 | [0.1e-9, inf) | GaN epi layer thickness |
| L | m | 0.25e-6 | [20e-9, inf) | Designed gate length (instance) |
| W | m | 200e-6 | [20e-9, inf) | Designed gate width per finger (instance) |
| NF | -- | 1 | [1, inf) | Number of fingers (integer, instance) |
| MULT_I | -- | 1.0 | [0, inf) | Multiplier for current (instance) |
| MULT_Q | -- | 1.0 | [0, inf) | Multiplier for charge (instance) |
| MULT_FN | -- | MULT_I | [0, inf) | Multiplier for flicker noise (instance) |
| LSG | m | 1e-6 | [0, inf) | Source-gate access region length |
| LDG | m | 1e-6 | [0, inf) | Drain-gate access region length |
| EPSILON | F/m | 10.66e-11 | (0, inf) | Dielectric permittivity of AlGaN layer |
| GAMMA0I | -- | 2.12e-12 | [0, 1] | Schrodinger-Poisson solution variable (E0 subband) |
| GAMMA1I | -- | 3.73e-12 | [0, 1] | Schrodinger-Poisson solution variable (E1 subband) |

### Model Controllers

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RDSMOD | -- | 0 | [0, 1] | Access region resistance model: 0=simplified, 1=accurate |
| GATEMOD | -- | 0 | [0, 4] | Gate current model: 0=off, 1=simple diode, 2=Poole-Frenkel, 3=p-GaN, 4=decoupled fwd/rev |
| SHMOD | -- | 1 | [0, 1] | Self-heating: 0=off, 1=on |
| TRAPMOD | -- | 0 | [0, 5] | Trap model: 0=off, 1=RF, 2=pulsed IV, 3=dynamic Ron, 4=separate DL/GL, 5=SRH dynamic |
| FNMOD | -- | 0 | [0, 1] | Flicker noise: 0=off, 1=on |
| TNMOD | -- | 0 | [0, 1] | Thermal noise: 0=off, 1=on |
| FP1MOD | -- | 0 | [0, 2] | Drain-side field plate 1: 0=none, 1=gate FP, 2=source FP |
| FP2MOD | -- | 0 | [0, 2] | Drain-side field plate 2: 0=none, 1=gate FP, 2=source FP |
| FP3MOD | -- | 0 | [0, 2] | Drain-side field plate 3: 0=none, 1=gate FP, 2=source FP |
| FP4MOD | -- | 0 | [0, 2] | Drain-side field plate 4: 0=none, 1=gate FP, 2=source FP |
| FP1SMOD | -- | 0 | [0, 2] | Source-side field plate 1: 0=none, 1=gate FP, 2=source FP |
| FP2SMOD | -- | 0 | [0, 2] | Source-side field plate 2: 0=none, 1=gate FP, 2=source FP |
| FP3SMOD | -- | 0 | [0, 2] | Source-side field plate 3: 0=none, 1=gate FP, 2=source FP |
| FP4SMOD | -- | 0 | [0, 2] | Source-side field plate 4: 0=none, 1=gate FP, 2=source FP |
| RGATEMOD | -- | 0 | [0, 2] | Gate resistance model: 0=off, 1=simple, 2=advanced (LF/HF) |
| FASTFPMOD | -- | 0 | [0, 1] | Fast field plate model: 0=conventional, 1=fast calculations |

### Basic Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VOFF | V | -2.0 | [-100, 5] | Cut-off (threshold) voltage |
| ASUB | V/V | 0.0 | [-100, 100] | Substrate coupling effect parameter |
| U0 | m^2/(V*s) | 170e-3 | [0, inf) | Low-field mobility |
| UA | V^-1 | 0 | [0, inf) | First-order mobility degradation coefficient |
| UB | V^-2 | 0 | [0, inf) | Second-order mobility degradation coefficient |
| UC | V^-1 | 0 | [0, inf) | Mobility degradation coefficient with Vbs |
| VSAT | m/s | 1.9e5 | [1e3, inf) | Saturation velocity |
| DELTA | -- | 2 | [2, inf) | Exponent of Vd,eff |
| LAMBDA | V^-1 | 0 | [0, inf) | Channel length modulation coefficient |
| ETA0 | -- | 1e-9 | [0, inf) | DIBL parameter |
| VDSCALE | V | 5 | (0, inf) | DIBL scaling with Vds |
| THESAT | V^-2 | 1 | [1, inf) | Velocity saturation parameter |
| NFACTOR | -- | 0.5 | [0, inf) | Sub-Voff slope parameter |
| CDSCD | -- | 1e-3 | [0, inf) | Sub-Voff slope change due to drain voltage |
| IMIN | A | 1e-15 | (0, inf) | Minimum drain current |
| GDSMIN | S | 1e-12 | (0, inf) | Shunt conductance across channel and all field plates |
| TGDSMIN | -- | 0 | [0, inf) | Temperature dependence for GDSMIN |

### Access Region Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VSATACCS | cm/s | 50e3 | (0, inf) | Source access region saturation velocity |
| NS0ACCS | C/m^2 | 5e17 | [1e5, inf) | Source access region 2-DEG charge density |
| NS0ACCD | C/m^2 | 5e17 | [1e5, inf) | Drain access region 2-DEG charge density |
| K0ACCS | -- | 0 | [0, inf) | Gate voltage dependence of source access charge |
| K0ACCD | -- | 0 | [0, inf) | Gate voltage dependence of drain access charge |
| KSUB | V/V | 0 | (-inf, inf) | Substrate voltage dependence of access region charge |
| U0ACCS | m^2/(V*s) | 155e-3 | (0, inf) | Source-side access region mobility |
| U0ACCD | m^2/(V*s) | 155e-3 | (0, inf) | Drain-side access region mobility |
| MEXPACCS | -- | 2 | (0, inf) | Source-side access region resistance exponent |
| MEXPACCD | -- | 2 | (0, inf) | Drain-side access region resistance exponent |
| ARS | -- | 1.0 | (0, inf) | Source-side access region saturation tuning |
| ARD | -- | 1.0 | (0, inf) | Drain-side access region saturation tuning |
| RSC | Ohm*m | 1e-4 | [0, inf) | Source contact resistance |
| RDC | Ohm*m | 1e-4 | [0, inf) | Drain contact resistance |

### Gate Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| IGSDIO | A/m^2 | 1e-12 | [0, inf) | Gate-source diode saturation current |
| NJGS | -- | 2.5 | (0, 50) | Gate-source diode ideality factor |
| IGDDIO | A/m^2 | 1e-12 | [0, inf) | Gate-drain diode saturation current |
| NJGD | -- | 2.5 | (0, 50) | Gate-drain diode ideality factor |
| KTGS | -- | 0 | (-inf, inf) | Temperature coefficient of gate-source diode current |
| KTGD | -- | 0 | (-inf, inf) | Temperature coefficient of gate-drain diode current |
| RIGSDIO | A/m^2 | 1e-15 | [0, inf) | Gate-source reverse diode Poole-Frenkel multiplier (GATEMOD>=2) |
| RNJGS | -- | 80 | (0, inf) | Gate-source reverse current slope factor (GATEMOD>=2) |
| RIGDDIO | A/m^2 | 1e-15 | [0, inf) | Gate-drain reverse diode Poole-Frenkel multiplier (GATEMOD>=2) |
| RNJGD | -- | 80 | (0, inf) | Gate-drain reverse current slope factor (GATEMOD>=2) |
| RKTGS | -- | 0 | (-inf, inf) | Temperature coefficient of gate-source reverse current (GATEMOD>=2) |
| RKTGD | -- | 0 | (-inf, inf) | Temperature coefficient of gate-drain reverse current (GATEMOD>=2) |
| EBREAKS | V^0.5 | 0 | [0, inf) | Large reverse bias gate-source current parameter (GATEMOD>=2) |
| EBREAKD | V^0.5 | 0 | [0, inf) | Large reverse bias gate-drain current parameter (GATEMOD>=2) |
| AGS | -- | 1.0 | (0, 50) | GATEMOD=3 ideality factor variation with bias (G-S) |
| AGD | -- | 1.0 | (0, 50) | GATEMOD=3 ideality factor variation with bias (G-D) |
| VBIS | V | 1e-4 | (0, inf) | Gate-source diode built-in voltage (GATEMOD=3) |
| VBID | V | 1e-4 | (0, inf) | Gate-drain diode built-in voltage (GATEMOD=3) |
| KTVBIS | V | 0 | (-inf, inf) | Temperature coefficient of VBIS |
| KTVBID | V | 0 | (-inf, inf) | Temperature coefficient of VBID |
| KTNJGS | V | 0 | (-inf, inf) | Temperature coefficient of NJGS (forward, source side) |
| KTNJGD | V | 0 | (-inf, inf) | Temperature coefficient of NJGD (forward, drain side) |
| KTRNJGS | V | 0 | (-inf, inf) | Temperature coefficient of RNJGS (reverse, source side) |
| KTRNJGD | V | 0 | (-inf, inf) | Temperature coefficient of RNJGD (reverse, drain side) |

### Trap Model Parameters -- TRAPMOD=1 (RF Trap Model)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CDLAG | -- | 1e-6 | (0, inf) | Trap network capacitance (shared with TRAPMOD=4) |
| RDLAG | -- | 1e6 | (0, inf) | Trap network resistance (shared with TRAPMOD=4) |
| IDIO | A | 1.0 | (0, inf) | Saturation current for trap model diode |
| ATRAPVOFF | -- | 0.1 | (-inf, inf) | Voff change due to trapping |
| BTRAPVOFF | -- | 0.3 | (-inf, inf) | Voff change proportional to input power |
| ATRAPETA0 | -- | 0 | (-inf, inf) | ETA0 change due to trapping |
| BTRAPETA0 | -- | 0.05 | (-inf, inf) | ETA0 change proportional to input power |
| ATRAPRS | -- | 0.1 | (-inf, inf) | Rs change due to trapping |
| BTRAPRS | -- | 0.6 | (-inf, inf) | Rs change proportional to input power |
| ATRAPRD | -- | 0.5 | (-inf, inf) | Rd change due to trapping |
| BTRAPRD | -- | 0.6 | (-inf, inf) | Rd change proportional to input power |

### Trap Model Parameters -- TRAPMOD=2 (Pulsed IV)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RTRAP1 | Ohm | 1 | (0, inf) | Trap network 1 resistance |
| RTRAP2 | Ohm | 1 | (0, inf) | Trap network 2 resistance |
| CTRAP1 | F | 10e-6 | [0, inf) | Trap network 1 capacitance |
| CTRAP2 | F | 1e-6 | [0, inf) | Trap network 2 capacitance |
| A1 | -- | 0.1 | (-inf, inf) | Trap contribution to VOFF (1st network) |
| VOFFTR | -- | 1e-9 | (-inf, inf) | Trap contribution to VOFF (2nd network) |
| CDSCDTR | -- | 1e-15 | (-inf, inf) | Trap contribution to CDSCD (2nd network) |
| ETA0TR | -- | 1e-15 | (-inf, inf) | Trap contribution to DIBL (2nd network) |
| RONTR1 | -- | 1e-12 | (-inf, inf) | Trap contribution to Ron (1st network) |
| RONTR2 | -- | 1e-13 | (-inf, inf) | Trap contribution to Ron (2nd network) |
| RONTR3 | -- | 1e-13 | (-inf, inf) | Bias independent trap contribution to Ron |

### Trap Model Parameters -- TRAPMOD=3 (Dynamic On-Resistance)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RTRAP3 | Ohm | 1.0 | (0, inf) | Trap network resistance |
| CTRAP3 | F | 1e-4 | [0, inf) | Trap network capacitance |
| VATRAP | -- | 10 | (0, inf) | Division factor for V(trap1) |
| VDLR1 | -- | 2 | (-inf, inf) | Slope for region 1 |
| VDLR2 | -- | 20 | (-inf, inf) | Slope for region 2 |
| WD | -- | 0.016 | (-inf, inf) | Weak dependence of VDLR1 on Vdg |
| VTB | V | 250 | [0, inf) | Breakpoint for Vdg effect on Von |
| SCT | -- | 1 | (0, inf) | Slope parameter for CT variation with Vgs |
| DELTAX | -- | 0.01 | [0, inf) | Smoothing parameter |
| TALPHA | -- | 1.0 | (-inf, inf) | Temperature exponent of Rtrap |

### Trap Model Parameters -- TRAPMOD=4 (Separate Drain-Lag / Gate-Lag)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| REMI | -- | 1.0 | (0, inf) | Drain lag emission resistance |
| CGLAG | -- | 10e-6 | (0, inf) | Gate lag trapping capacitance |
| REMIG | -- | 1.0 | (0, inf) | Gate lag trapping resistance |
| ARCAP | -- | 0 | (-inf, inf) | Drain lag trap potential tuning |
| BRCAP | -- | 0.5 | (0, inf) | Drain lag trap potential tuning |
| ARCAPG | -- | 0 | (-inf, inf) | Gate lag trap potential tuning |
| BRCAPG | -- | 0.5 | (0, inf) | Gate lag trap potential tuning |
| VDLMAX | -- | 20 | (0, inf) | Drain lag: limiting parameter change |
| VGLMAX | -- | 5 | (0, inf) | Gate lag: limiting parameter change |
| DLVOFF | -- | 0 | (-inf, inf) | Voff tuning due to drain lag |
| GLVOFF | -- | 0 | (-inf, inf) | Voff tuning due to gate lag |
| GLU0 | -- | 0 | (-inf, inf) | U0 tuning due to drain lag |
| GLVSAT | -- | 0 | (-inf, inf) | VSAT tuning due to gate lag |
| DLNS0S | -- | 0 | (-inf, inf) | Source-side 2-DEG tune due to drain lag |
| DLNS0D | -- | 0 | (-inf, inf) | Drain-side 2-DEG tune due to drain lag |

### Trap Model Parameters -- TRAPMOD=5 (SRH Dynamic Trap)

Parameters for the first trapping network:

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ALPHAX | -- | 0 | (-inf, inf) | Vgs dependence of trapping |
| ALPHAXD | -- | 0 | (-inf, inf) | Vgd dependence of trapping |
| BETAX | -- | 0.05 | (-inf, inf) | Vds dependence of trapping |
| GAMMAX | -- | 0 | (-inf, inf) | Steady-state trapping voltage parameter |
| ETAX | -- | 0 | (-inf, inf) | Steady-state trapping voltage parameter |
| ENO | -- | 1e4 | (-inf, inf) | Nominal temperature emission rate |
| CX | -- | 1e-7 | (-inf, inf) | Trap capacitance |
| VXMAX | -- | 0.5 | (-inf, inf) | Maximum trapping voltage |
| EA | -- | 0.5 | (-inf, inf) | Activation energy of traps (eV) |

Parameters for the second trapping network:

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ALPHAY | -- | 0 | (-inf, inf) | Vgs dependence of 2nd trapping network |
| ALPHAYD | -- | 0 | (-inf, inf) | Vgd dependence of 2nd trapping network |
| BETAY | -- | 0.05 | (-inf, inf) | Vds dependence of 2nd trapping network |
| GAMMAY | -- | 0 | (-inf, inf) | Steady-state 2nd trapping parameter |
| ETAY | -- | 0 | (-inf, inf) | Steady-state 2nd trapping parameter |
| ENO1 | -- | 1e4 | (-inf, inf) | Nominal temperature emission rate (2nd network) |
| CY | -- | 1e-7 | (-inf, inf) | Trap capacitance (2nd network) |
| VYMAX | -- | 0.5 | (-inf, inf) | Maximum trapping voltage (2nd network) |
| EA1 | -- | 0.5 | (-inf, inf) | Activation energy (eV, 2nd network) |

TRAPMOD=5 degradation parameters (shared with TRAPMOD=4 where applicable):

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DLVOFF | -- | 0 | (-inf, inf) | Voff tuning due to drain lag |
| DLNS0S | -- | 0 | (-inf, inf) | Source-side 2-DEG tune due to drain lag |
| DLNS0D | -- | 0 | (-inf, inf) | Drain-side 2-DEG tune due to drain lag |
| GLNS0S | -- | 0 | (-inf, inf) | Source-side 2-DEG tune with trap potential (TRAPMOD=5) |
| GLNS0D | -- | 0 | (-inf, inf) | Drain-side 2-DEG tune with trap potential (TRAPMOD=5) |
| GLVOFF | -- | 0 | (-inf, inf) | Voff tuning due to gate lag |
| GLU0 | -- | 0 | (-inf, inf) | U0 tuning due to drain lag |
| GLVSAT | -- | 0 | (-inf, inf) | VSAT tuning due to gate lag |

### Field Plate Parameters -- FP1

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| IMINFP1 | A | 1e-15 | (0, inf) | Minimum drain current, FP1 region |
| VOFFFP1 | V | -25.0 | [-500, 5] | Cut-off voltage for FP1 |
| DFP1 | m | 50e-9 | [0.1e-9, inf) | Distance of FP1 from 2-DEG (instance) |
| LFP1 | m | 1e-6 | (0, inf) | Length of FP1 (instance) |
| KTFP1 | -- | 50e-3 | (-inf, inf) | Temperature dependence for VOFFFP1 |
| U0FP1 | m^2/(V*s) | 100e-3 | [0, inf) | FP1 region mobility |
| VSATFP1 | m/s | 100e3 | [0, inf) | Saturation velocity, FP1 region |
| NFACTORFP1 | -- | 0.5 | [0, inf) | Sub-Voff slope, FP1 |
| CDSCDFP1 | -- | 0 | [0, inf) | Sub-Voff slope Vds dependence, FP1 |
| ETA0FP1 | -- | 1e-9 | [0, inf) | DIBL parameter, FP1 |
| VDSCALEFP1 | V | 10.0 | (0, inf) | DIBL Vds scaling, FP1 |
| GAMMA0FP1 | -- | 2.12e-12 | [0, 1] | Schrodinger-Poisson variable, FP1 |
| GAMMA1FP1 | -- | 3.73e-12 | [0, 1] | Schrodinger-Poisson variable, FP1 |

### Field Plate Parameters -- FP2

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| IMINFP2 | A | 1e-15 | (0, inf) | Minimum drain current, FP2 region |
| VOFFFP2 | V | -80.0 | [-100, 5] | Cut-off voltage for FP2 |
| DFP2 | m | 100e-9 | [0.1e-9, inf) | Distance of FP2 from 2-DEG (instance) |
| LFP2 | m | 1e-6 | (0, inf) | Length of FP2 (instance) |
| KTFP2 | -- | 50e-3 | (-inf, inf) | Temperature dependence for VOFFFP2 |
| U0FP2 | m^2/(V*s) | 100e-3 | [0, inf) | FP2 region mobility |
| VSATFP2 | m/s | 100e3 | [0, inf) | Saturation velocity, FP2 region |
| NFACTORFP2 | -- | 0.5 | [0, inf) | Sub-Voff slope, FP2 |
| CDSCDFP2 | -- | 0 | [0, inf) | Sub-Voff slope Vds dependence, FP2 |
| ETA0FP2 | -- | 1e-9 | [0, inf) | DIBL parameter, FP2 |
| VDSCALEFP2 | V | 10.0 | (0, inf) | DIBL Vds scaling, FP2 |
| GAMMA0FP2 | -- | 2.12e-12 | [0, 1] | Schrodinger-Poisson variable, FP2 |
| GAMMA1FP2 | -- | 3.73e-12 | [0, 1] | Schrodinger-Poisson variable, FP2 |

### Field Plate Parameters -- FP3

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| IMINFP3 | A | 1e-15 | (0, inf) | Minimum drain current, FP3 region |
| VOFFFP3 | V | -75.0 | [-500, 5] | Cut-off voltage for FP3 |
| DFP3 | m | 150e-9 | [0.1e-9, inf) | Distance of FP3 from 2-DEG (instance) |
| LFP3 | m | 1e-6 | (0, inf) | Length of FP3 (instance) |
| KTFP3 | -- | 50e-3 | (-inf, inf) | Temperature dependence for VOFFFP3 |
| U0FP3 | m^2/(V*s) | 100e-3 | [0, inf) | FP3 region mobility |
| VSATFP3 | m/s | 100e3 | [0, inf) | Saturation velocity, FP3 region |
| NFACTORFP3 | -- | 0.5 | [0, inf) | Sub-Voff slope, FP3 |
| CDSCDFP3 | -- | 0 | [0, inf) | Sub-Voff slope Vds dependence, FP3 |
| ETA0FP3 | -- | 1e-9 | [0, inf) | DIBL parameter, FP3 |
| VDSCALEFP3 | V | 10.0 | (0, inf) | DIBL Vds scaling, FP3 |
| GAMMA0FP3 | -- | 2.12e-12 | [0, 1] | Schrodinger-Poisson variable, FP3 |
| GAMMA1FP3 | -- | 3.73e-12 | [0, 1] | Schrodinger-Poisson variable, FP3 |

### Field Plate Parameters -- FP4

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| IMINFP4 | A | 1e-15 | (0, inf) | Minimum drain current, FP4 region |
| VOFFFP4 | V | -100.0 | [-500, 5] | Cut-off voltage for FP4 |
| DFP4 | m | 200e-9 | [0.1e-9, inf) | Distance of FP4 from 2-DEG (instance) |
| LFP4 | m | 1e-6 | (0, inf) | Length of FP4 (instance) |
| KTFP4 | -- | 50e-3 | (-inf, inf) | Temperature dependence for VOFFFP4 |
| U0FP4 | m^2/(V*s) | 100e-3 | [0, inf) | FP4 region mobility |
| VSATFP4 | m/s | 100e3 | [0, inf) | Saturation velocity, FP4 region |
| NFACTORFP4 | -- | 0.5 | [0, inf) | Sub-Voff slope, FP4 |
| CDSCDFP4 | -- | 0 | [0, inf) | Sub-Voff slope Vds dependence, FP4 |
| ETA0FP4 | -- | 1e-9 | [0, inf) | DIBL parameter, FP4 |
| VDSCALEFP4 | V | 10.0 | (0, inf) | DIBL Vds scaling, FP4 |
| GAMMA0FP4 | -- | 2.12e-12 | [0, 1] | Schrodinger-Poisson variable, FP4 |
| GAMMA1FP4 | -- | 3.73e-12 | [0, 1] | Schrodinger-Poisson variable, FP4 |

### Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CGSO | F | 10e-15 | [0, inf) | Gate-source overlap capacitance |
| CGDO | F | 10e-15 | [0, inf) | Gate-drain overlap capacitance |
| CDSO | F | 10e-15 | [0, inf) | Drain-source capacitance |
| CGDL | F | 0 | [0, inf) | Bias Vds dependence in CGDO |
| VDSATCV | V | 100 | (0, inf) | Saturation voltage at drain side in CV model |
| CBDO | F | 0 | [0, inf) | Substrate-drain capacitance |
| CBSO | F | 0 | [0, inf) | Substrate-source capacitance |
| CBGO | F | 0 | [0, inf) | Substrate-gate capacitance |
| CFG | F | 0 | [0, inf) | Gate fringing capacitance |
| CFD | F | 0 | [0, inf) | Drain fringing capacitance |
| CFGD | F | 0 | [0, inf) | Fringing capacitance gate-drain |
| CFGDSM | F | 1e-24 | [0, inf) | Capacitance smoothing parameter |
| CFGD0 | F | 0 | [0, inf) | Fringing capacitance parameter |
| CJ0 | F | 0 | [0, inf) | Zero-bias access region depletion capacitance |
| VBI | V | 0.9 | (0, inf) | Drain-end built-in potential |
| MZ | -- | 0.5 | (0, 1) | Grading factor of depletion capacitance |
| AJ | -- | 100e-3 | (0, inf) | Limiting factor of depletion capacitance in forward bias |
| DJ | -- | 1.0 | [0, 2] | Fitting parameter for Caccd |

### Quantum Mechanical Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ADOSI | -- | 0 | [0, inf) | QME prefactor/switch for intrinsic device |
| BDOSI | -- | 1 | [0, inf) | Charge centroid slope of CV under QME |
| QM0I | -- | 1e-3 | (0, inf) | Charge centroid starting point for QME |
| ADOSFP1 | -- | 0 | [0, inf) | QME prefactor for FP1 |
| BDOSFP1 | -- | 1 | [0, inf) | Charge centroid slope, FP1 |
| QM0FP1 | -- | 1e-3 | (0, inf) | Charge centroid starting point, FP1 |
| ADOSFP2 | -- | 0 | [0, inf) | QME prefactor for FP2 |
| BDOSFP2 | -- | 1 | [0, inf) | Charge centroid slope, FP2 |
| QM0FP2 | -- | 1e-3 | (0, inf) | Charge centroid starting point, FP2 |
| ADOSFP3 | -- | 0 | [0, inf) | QME prefactor for FP3 |
| BDOSFP3 | -- | 1 | [0, inf) | Charge centroid slope, FP3 |
| QM0FP3 | -- | 1e-3 | (0, inf) | Charge centroid starting point, FP3 |
| ADOSFP4 | -- | 0 | [0, inf) | QME prefactor for FP4 |
| BDOSFP4 | -- | 1 | [0, inf) | Charge centroid slope, FP4 |
| QM0FP4 | -- | 1e-3 | (0, inf) | Charge centroid starting point, FP4 |

### Cross-Coupling & Substrate Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CFP1SCALE | -- | 0 | [0, inf) | Cross-coupling charge scaling under FP1 |
| CFP2SCALE | -- | 0 | [0, inf) | Cross-coupling charge scaling under FP2 |
| CFP3SCALE | -- | 0 | [0, inf) | Cross-coupling charge scaling under FP3 |
| CFP4SCALE | -- | 0 | [0, inf) | Cross-coupling charge scaling under FP4 |
| CSUBSCALEI | -- | 0 | [0, inf) | Substrate capacitance scaling, intrinsic |
| CSUBSCALE1 | -- | 0 | [0, inf) | Substrate capacitance scaling, FP1 |
| CSUBSCALE2 | -- | 0 | [0, inf) | Substrate capacitance scaling, FP2 |
| CSUBSCALE3 | -- | 0 | [0, inf) | Substrate capacitance scaling, FP3 |
| CSUBSCALE4 | -- | 0 | [0, inf) | Substrate capacitance scaling, FP4 |

### Gate Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| XGW | m | 0 | [0, inf) | Distance from gate contact center to device edge |
| NGCON | -- | 1 | [1, 2] | Number of gate contacts (integer, instance) |
| RSHG | Ohm/sq | 1e-3 | [1e-3, inf) | Gate sheet resistance |

### Noise Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NOIA | -- | 15e-12 | (-inf, inf) | Flicker noise parameter (carrier number fluctuation) |
| NOIB | -- | 0 | [0, inf) | Flicker noise parameter |
| NOIC | -- | 0 | [0, inf) | Flicker noise parameter |
| EF | -- | 1 | (0, inf) | Exponent of frequency (slope on log plot) |
| TNSC | -- | 1e27 | (0, inf) | Thermal noise scaling parameter |

### Drain-Source Breakdown Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| BVDSL | V | 200 | [10, inf) | Drain-source breakdown voltage (punch-through) |
| ASL | A/m | 0 | [0, inf) | Breakdown current multiplier (also model switch; 0=off) |
| NSL | -- | 10 | [1, inf) | Breakdown model exponent |
| KASL | -- | 0 | (-inf, inf) | Temperature dependence of ASL |
| KNSL | -- | 0 | (-inf, inf) | Temperature dependence of NSL |
| KBVDSL | -- | 0 | (-inf, inf) | Temperature dependence of BVDSL |

### Temperature & Self-Heating Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| AT | -- | 0 | (-inf, inf) | Temperature dependence of saturation velocity |
| UTE | -- | -0.5 | [-10, 0] | Temperature dependence of mobility |
| KT1 | -- | 0 | (-inf, inf) | Temperature dependence of Voff |
| KNS0 | -- | 0 | [0, inf) | Temperature dependence of 2-DEG access charge |
| ATS | -- | 0 | (-inf, inf) | Temperature dependence of access region Vsat |
| UTES | -- | 0 | (-inf, inf) | Temperature dependence of source-side access mobility |
| UTED | -- | 0 | (-inf, inf) | Temperature dependence of drain-side access mobility |
| KRSC | -- | 0 | [0, inf) | Temperature dependence of source contact resistance |
| KRDC | -- | 0 | [0, inf) | Temperature dependence of drain contact resistance |
| KTVBI | -- | 0 | [0, inf) | Temperature dependence of VBI |
| KTCFG | -- | 0 | [0, inf) | Temperature dependence of gate fringing capacitance |
| KTCFGD | -- | 0 | [0, inf) | Temperature dependence of CFGD fringing capacitance |
| RTH0 | K/W | 5 | [0, inf) | Thermal resistance |
| CTH0 | s*W/K | 1e-9 | [0, inf) | Thermal capacitance |
| TALPHA | -- | 1.0 | (-inf, inf) | Temperature exponent of Rtrap |
| DTEMP | -- | 0 | (-inf, inf) | Temperature variability offset (instance) |

### Substrate Leakage Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| ISBL | A/m^2 | 0 | [0, inf) | Source-to-substrate saturation current |
| NSB | -- | 100 | [0, 5000] | Source-to-substrate non-linearity parameter |
| VBISB | V | 50 | [0, inf) | Source-to-substrate leakage turn-on voltage |
| IDBL | A/m^2 | 0 | [0, inf) | Drain-to-substrate saturation current |
| NDB | -- | 100 | [0, 5000] | Drain-to-substrate non-linearity parameter |
| VBIDB | V | 50 | [0, inf) | Drain-to-substrate leakage turn-on voltage |
| KTISB | -- | 0 | (-inf, inf) | Temperature dependence of ISBL |
| KTIDB | -- | 0 | (-inf, inf) | Temperature dependence of IDBL |
| KTNSB | -- | 0 | (-inf, inf) | Temperature dependence of NSB |
| KTNDB | -- | 0 | (-inf, inf) | Temperature dependence of NDB |
| KTVBISB | V | 0 | (-inf, inf) | Temperature dependence of VBISB |
| KTVBIDB | V | 0 | (-inf, inf) | Temperature dependence of VBIDB |

---

## Equations

### Physical Constants

$$q = 1.6 \times 10^{-19} \text{ C}$$

$$\epsilon_{\text{AlGaN}} = 10.66 \times 10^{-11} \text{ F/m}$$

$$K_B = 8.636 \times 10^{-5} \text{ eV/K}$$

$$\gamma_0 = 2.12 \times 10^{-12}$$

$$\gamma_1 = 3.73 \times 10^{-12}$$

$$DOS = 3.24 \times 10^{17} \text{ m}^{-2}\text{eV}^{-1}$$

$$\text{eppsi} = 0.3 \quad \text{(smoothing constant)}$$

### Voltage Calculation and Pre-Conditioning

#### Terminal Voltages

$$V_{ds} = V_d - V_s \tag{3.2.1}$$

$$V_{gs} = V_g - V_s \tag{3.2.2}$$

$$V_{gd} = V_g - V_d \tag{3.2.3}$$

$$V_{dsx} = \sqrt{V_{ds}^2 + 0.01} \tag{3.2.4}$$

#### DIBL-Adjusted Cut-off Voltage

$$V_{off,DIBL} = VOFF - (ETA0 - TRAPETA0 \cdot v_{cap} + \text{eta0trap}) \cdot \frac{V_{dsx} \cdot VDSCALE}{\sqrt{V_{dsx}^2 + VDSCALE^2}} \tag{3.2.5}$$

#### Effective Gate Voltage

$$V_{gs,min} = V_{off,DIBL}(T) + V_{tv} \ln\!\left(\frac{L}{2 W \cdot q \cdot DOS \cdot V_{tv}^2}\right) \tag{3.2.6}$$

$$V_{gs,eff} = \frac{1}{2}\left[(V_{gs} - V_{gs,min}) + \sqrt{(V_{gs} - V_{gs,min})^2 + 0.0001}\right] \tag{3.2.7}$$

$$V_{g0} = V_{gs,eff} - V_{off,DIBL} \tag{3.2.8}$$

$$V_{g0,eff} = \frac{1}{2}\left(V_{g0} + \sqrt{V_{g0}^2 + 4\,\text{eppsi}^2}\right) \tag{3.2.9}$$

#### Saturation and Effective Drain Voltage

$$V_{dsat} = \frac{(2\,VSAT(T)/\mu_{eff}) \cdot L \cdot V_{g0,eff}}{(2\,VSAT(T)/\mu_{eff}) \cdot L + V_{g0,eff}} \tag{3.2.10}$$

$$V_{d,eff} = \frac{V_{ds}}{\left(1 + \left(\frac{V_{ds}}{V_{dsat}}\right)^{DELTA}\right)^{1/DELTA}} \tag{3.2.11}$$

$$V_{gd0} = V_{g0} - V_{d,eff} \tag{3.2.12}$$

$$V_{gd,eff} = \frac{1}{2}\left(V_{gd0} + \sqrt{V_{gd0}^2 + 4\,\text{eppsi}^2}\right) \tag{3.2.13}$$

#### Bias-Independent Quantities

$$C_g = \frac{\epsilon_{\text{AlGaN}}}{TBAR} \tag{3.2.14}$$

$$C_{g,fp} = \frac{\epsilon_{\text{AlGaN}}}{DFP} \tag{3.2.15}$$

$$C_{epi} = \frac{\epsilon_{\text{AlGaN}}}{TEPI} \tag{3.2.16}$$

$$C_{g,sfp} = \frac{\epsilon_{\text{AlGaN}}}{DSFP} \tag{3.2.17}$$

$$\beta = \frac{C_g}{q \cdot DOS \cdot K_B \cdot T_{dev}} \tag{3.2.18}$$

$$\alpha_n = \frac{e}{\beta} \tag{3.2.19}$$

$$\alpha_d = \frac{1}{\beta} \tag{3.2.20}$$

### Temperature Dependence

$$T_{dev} = T + V(r_{th}) \tag{3.3.1}$$

$$cdsc = 1 + NFACTOR + (CDSCD + \text{cdscdtrap}) \cdot V_{dsx} \tag{3.3.2}$$

$$V_{tv} = K_B \cdot T_{dev} \cdot cdsc \tag{3.3.3}$$

$$V_{off,DIBL}(T) = V_{off,DIBL} - \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KT1 + TRAPVOFF \cdot v_{cap} + \text{vofftrap} + \frac{C_{epi}}{C_{epi} + C_g} \cdot V_{sb} \tag{3.3.4}$$

$$U0(T) = U0 \cdot \left(\frac{T_{dev}}{TNOM}\right)^{UTE} \tag{3.3.5}$$

$$VSAT(T) = VSAT \cdot \left(\frac{T_{dev}}{TNOM}\right)^{AT} \tag{3.3.6}$$

$$NS0ACCS(T) = NS0ACCS \cdot \left(1 - KNS0 \cdot \left(\frac{T_{dev}}{TNOM} - 1\right)\right) \cdot (1 + K0ACCS \cdot V_{g0,eff}) + \frac{KSUB \cdot V_{bs} \cdot C_{epi}}{q} \tag{3.3.7}$$

$$VSATACCS(T) = VSATACCS \cdot \left(\frac{T_{dev}}{TNOM}\right)^{ATS} \tag{3.3.8}$$

$$U0ACCS(T) = U0ACCS \cdot \left(\frac{T_{dev}}{TNOM}\right)^{UTES} \tag{3.3.9}$$

$$NS0ACCD(T) = NS0ACCS \cdot \left(1 - KNS0 \cdot \left(\frac{T_{dev}}{TNOM} - 1\right)\right) \cdot (1 + K0ACCD \cdot V_{g0,eff}) + \frac{KSUB \cdot V_{bs} \cdot C_{epi}}{q} \tag{3.3.10}$$

$$U0ACCD(T) = U0ACCD \cdot \left(\frac{T_{dev}}{TNOM}\right)^{UTES} \tag{3.3.11}$$

$$RSC(T) = RSC \cdot \left(1 + KRSC \cdot \left(\frac{T_{dev}}{TNOM} - 1\right)\right) \tag{3.3.12}$$

$$RDC(T) = RDC \cdot \left(1 + KRSC \cdot \left(\frac{T_{dev}}{TNOM} - 1\right)\right) \tag{3.3.13}$$

$$VBI(T) = VBI - \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KTVBI \tag{3.3.14}$$

$$CFG(T) = CFG - \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KTCFG \tag{3.3.15}$$

### Surface Potential Calculation

Surface potential at position $x$ along the channel:

$$\psi_x(V_g) = V_f(V_g) + V_x \tag{3.4.1}$$

where $V_f$ is the Fermi-level potential in the triangular potential well.

#### Sub-band Energies

$$E_n = \frac{\hbar^2}{2m_1} \left(\frac{3}{2}\pi q E\right)^{2/3} \left(n + \frac{3}{4}\right)^{2/3} \tag{3.4.2}$$

Keeping only the two lowest sub-bands:

$$E_0 = \gamma_0 \cdot E^{2/3} \tag{3.4.3}$$

$$E_1 = \gamma_1 \cdot E^{2/3} \tag{3.4.4}$$

#### Poisson's Equation

$$E = q \cdot n_s \tag{3.4.5}$$

Substituting:

$$E_0 = \gamma_0 \cdot (q \cdot n_s)^{2/3} \tag{3.4.6}$$

$$E_1 = \gamma_1 \cdot (q \cdot n_s)^{2/3} \tag{3.4.7}$$

#### Fermi-Dirac Statistics

$$n_s = DOS \cdot V_{tv} \cdot \ln\!\left[(1 + e^{(E_f - E_0)/V_{tv}})(1 + e^{(E_f - E_1)/V_{tv}})\right] \tag{3.4.9}$$

#### Charge Balance

$$n_s = \frac{C_g}{q}(V_{g0} - V_f) \tag{3.4.10}$$

#### Region 1: Sub-Voff ($V_g < V_{off}$)

$$n_{s,\text{sub-Voff}} = 2 \cdot DOS \cdot V_{tv} \cdot e^{V_{g0}/V_{tv}} \tag{3.4.11}$$

$$V_{f,\text{sub-Voff}} = V_{g0} - \frac{2q \cdot DOS \cdot V_{tv}}{C_g} \cdot e^{V_{g0}/V_{tv}} \tag{3.4.12}$$

#### Region 2: $V_g > V_{off}$, $E_f < E_0$

$$n_s = DOS \cdot V_{tv} \cdot e^{(E_f - E_0)/V_{tv}} \tag{3.4.13}$$

$$V_{fI} = V_{g0} \cdot \frac{V_{tv} \ln(\beta V_{g0}) + \gamma_0 \left(\frac{C_g \cdot V_{g0}}{q}\right)^{2/3}}{V_{g0} + V_{tv} + \frac{2\gamma_0}{3}\left(\frac{C_g \cdot V_{g0}}{q}\right)^{2/3}} \tag{3.4.14}$$

#### Region 3: $V_g > V_{off}$, $E_f > E_0$

$$n_s = DOS \cdot (E_f - E_0) \tag{3.4.15}$$

$$V_{fII} = V_{g0} \cdot \frac{\beta V_{tv} V_{g0} + \gamma_0 \left(\frac{C_g \cdot V_{g0}}{q}\right)^{2/3}}{V_{g0}(1 + \beta V_{tv}) + \frac{2\gamma_0}{3}\left(\frac{C_g \cdot V_{g0}}{q}\right)^{2/3}} \tag{3.4.16}$$

#### Combined Above-Voff

$$V_{f,above} = V_{g0}\,(1 - H(V_{g0})) \tag{3.4.17}$$

where

$$H(V_{g0}) = \frac{V_{g0} + V_{tv}\left[1 - \ln(\beta V_{g0n})\right] - \frac{\gamma_0}{3}\left(\frac{C_g \cdot V_{g0}}{q}\right)^{2/3}}{V_{g0}\left(1 + \frac{V_{tv}}{V_{g0d}}\right) + \frac{2\gamma_0}{3}\left(\frac{C_g \cdot V_{g0}}{q}\right)^{2/3}} \tag{3.4.18}$$

Interpolation:

$$V_{g0x} = \frac{V_{g0} \cdot \alpha_x}{\sqrt{V_{g0}^2 + \alpha_x^2}} \tag{3.4.19}$$

where $\alpha_n = e/\beta$ and $\alpha_d = 1/\beta$.

#### Unified Vf (All Regions)

$$V_{f,unified} = V_{g0} - \frac{2V_{tv}\ln\!\left(1 + e^{V_{g0}/(2V_{tv})}\right)}{\frac{C_g}{q \cdot DOS} \cdot e^{V_{g0}/(2V_{tv})} + \frac{1}{H(V_{g0,eff})}} \tag{3.4.20}$$

#### Householder Correction

$$V_f = V_{f,unified} - \frac{p \cdot r}{1 + \frac{p}{2q} \cdot \frac{r}{2q}} \tag{3.4.21}$$

Quantities for the Householder iteration (Table 1):

| Quantity | Expression |
|----------|------------|
| $k_{0,1}$ | $\gamma_{0,1}\left(\frac{C_g}{q}\right)^{2/3}$ |
| $V_{gef}$ | $V_g - V_{off} - E_f$ |
| $\xi_{0,1}$ | $\exp\!\left(\frac{E_{f,unified} - k_{0,1} V_{gef}^{2/3}}{V_{tv}}\right)$ |
| $p$ | $\frac{C_g}{q} V_{gef} - \sum_{i=0}^{1} DOS \cdot V_{tv} \ln(\xi_i + 1)$ |
| $q$ | $-\frac{C_g}{q} - \sum_{i=0}^{1} \frac{DOS}{1 + \xi_i^{-1}}\left(1 + \frac{2}{3}k_i V_{gef}^{-1/3}\right)$ |
| $r$ | $\sum_{i=0}^{1} \frac{DOS \cdot k_i (1+\xi_i^{-1}) + \frac{DOS}{V_{tv}}\left(1+\frac{2}{3}k_i V_{gef}^{-1/3}\right)^2 \cdot \frac{2}{9}V_{gef}^{-4/3}}{(1+\xi_i^{-1})^2}$ |

Source-end: $\psi_s = V_f + V_s$. Drain-end: replace $V_{g0}, V_{g0,eff}$ with $V_{gd0}, V_{gd,eff}$; then $\psi_d = V_f + V_{d,eff}$.

### Intrinsic Charge Calculation

#### Gate Charge

$$Q_g = -q W \int_0^L C_g(V_{g0} - \psi(x))\,dx \tag{3.5.1}$$

Using current continuity:

$$dx = \frac{L(V_{g0} - \psi + V_{tv})}{(\psi_d - \psi_s)(V_{g0} - \psi_m + V_{tv})}\,d\psi \tag{3.5.2}$$

$$Q_g = \frac{C_g L W}{V_{g0} - \psi_m + V_{tv}} \left[V_{g0}^2 + \frac{1}{3}(\psi_d^2 + \psi_s^2 + \psi_d\psi_s) - V_{g0}(\psi_d + \psi_s - V_{tv}) - V_{tv}\psi_m\right] \tag{3.5.3}$$

#### Ward-Dutton Partitioning

$$Q_d = \int_0^L \frac{x}{L}\,Q_{ch}(V_g, V_x)\,dx \tag{3.5.4}$$

$$Q_s = \int_0^L \left(1 - \frac{x}{L}\right) Q_{ch}(V_g, V_x)\,dx \tag{3.5.5}$$

$$Q_g = -Q_s - Q_d \tag{3.5.6}$$

Position along channel:

$$x = \frac{L(\psi(x) - \psi_s)}{V_{g0} - \psi_m + V_{tv}} \left(V_{g0} + V_{tv} - \frac{\psi(x) + \psi_s}{2}\right) \tag{3.5.7}$$

#### Drain Charge

$$Q_d = -\frac{C_g L W}{120(V_{g0} - \psi_m + V_{tv})^2} \Big[12\psi_d^3 + 8\psi_s^3 + \psi_s^2(16\psi_d - 5(V_{tv} + 8V_{g0}))$$
$$+ 2\psi_s(12\psi_d^2 - 5\psi_d(5V_{tv} + 8V_{g0}) + 10(V_{tv} + V_{g0})(V_{tv} + 4V_{g0}))$$
$$+ 15\psi_d^2(3V_{tv} + 4V_{g0}) - 60V_{g0}(V_{tv} + V_{g0})^2$$
$$+ 20\psi_d(V_{tv} + V_{g0})(2V_{tv} + 5V_{g0})\Big] \tag{3.5.8}$$

Source charge:

$$Q_s = -Q_g - Q_d$$

### Drain Current Model

Drift-diffusion at point $x$:

$$I_d = -\mu W Q_{ch}\frac{d\psi}{dx} + \mu W V_{tv}\frac{dQ_{ch}}{dx} \tag{3.6.1}$$

Integrated form:

$$I_d = \frac{W}{L}\,\mu\,C_g\,(V_{g0} - \psi_m + V_{tv})\,\psi_{ds} \tag{3.6.2}$$

where $\psi_m = (\psi_d + \psi_s)/2$ and $\psi_{ds} = \psi_d - \psi_s$.

### Self-Heating Model

Modeled as an RC thermal network. Thermal node voltage gives temperature rise $\Delta T$:

$$T_{dev} = T + V(r_{th})$$

Power dissipated $P_d = I \cdot V$ heats through $R_{th}$ (RTH0) with thermal capacitance $C_{th}$ (CTH0).

### Mobility Degradation

$$\mu_{eff} = \frac{U0(T)}{1 + UA \cdot E_{y,eff} + UB \cdot E_{y,eff}^2 + UC \cdot E_b} \tag{3.8.1}$$

where $E_{y,eff} = Q_{ch}/\epsilon_{\text{AlGaN}}$ with $Q_{ch} = C_g |V_{g0} - \psi_m|$, and the substrate electric field:

$$E_b = \frac{|V_{bs} - \psi_s|}{TEPI} \tag{3.8.2}$$

$\mu_{eff}$ replaces $\mu$ in the drain current equation.

### Short Channel Effects

#### Velocity Saturation

$$\mu_{eff,sat} = \frac{\mu_{eff}}{\sqrt{1 + (\mu_{eff}\cdot E_x / VSAT)^2}} \tag{3.9.1}$$

With $E_x = \psi_{ds}/L$:

$$\mu_{eff,sat} = \frac{\mu_{eff}}{\sqrt{1 + THESAT^2 \cdot \psi_{ds}^2}} \tag{3.9.2}$$

where $THESAT$ has initial value $\mu_{eff}/(VSAT \cdot L)$.

#### DIBL

$$V_{off,DIBL} = VOFF - (ETA0 - TRAPETA0 \cdot v_{cap} + \text{eta0trap}) \cdot \frac{V_{dsx} \cdot VDSCALE}{\sqrt{V_{dsx}^2 + VDSCALE^2}} \tag{3.9.3}$$

#### Subthreshold Slope

$$cdsc = 1 + NFACTOR + (CDSCD + \text{cdscdtrap}) \cdot V_{dsx} \tag{3.9.4}$$

#### Channel Length Modulation

$$I_{ds,clm} = I_{ds} \cdot (1 + LAMBDA \cdot (V_{dsx} - V_{d,eff})) \tag{3.9.5}$$

### Access Region and Parasitic Resistances

#### Source Region Resistance (RDSMOD=1)

$$R_{source} = \frac{RSC(T)}{W \cdot NF} + TRAPRS \cdot v_{cap} + \frac{LSG}{W \cdot NF \cdot q \cdot NS0ACCS(T) \cdot U0ACCS(T)} \cdot \left(1 - \left(\frac{I_{ds}}{I_{sat,source}}\right)^{MEXPACCS}\right)^{-(MEXPACCS-1)} \tag{3.10.1}$$

where $I_{sat,source} = W \cdot NF \cdot NS0ACCS(T) \cdot VSATACCS(T)$.

If RDSMOD=0: $R_{source} = 10^{-6}$.

#### Drain Region Resistance (RDSMOD=1)

$$R_{drain} = \frac{RDC(T)}{W \cdot NF} + TRAPRD \cdot v_{cap} + R_{trap}(T) + \text{rontrap} + \frac{LDG}{W \cdot NF \cdot q \cdot NS0ACCD(T) \cdot U0ACCD(T)} \cdot \left(1 - \left(\frac{I_{ds}}{I_{sat,drain}}\right)^{MEXPACCD}\right)^{-(MEXPACCD-1)} \tag{3.10.2}$$

where $I_{sat,drain} = W \cdot NF \cdot NS0ACCD(T) \cdot VSATACCS(T)$.

If RDSMOD=0: $R_{drain} = 10^{-6}$.

#### Alternative Access Region Model (when AR is specified)

$$k_v = 1 + AT \cdot \sqrt{I_{ds}} \tag{3.10.3}$$

$$k_{vv} = \frac{k_v}{I_{sat,accs}} \tag{3.10.4}$$

$$t_0 = 1 + AR + k_{vv}^2 \tag{3.10.5}$$

$$t_1 = \sqrt{t_0 - 2 \cdot k_{vv}} + \sqrt{t_0 + 2 \cdot k_{vv}} \tag{3.10.6}$$

$$I_{d,eff} = \frac{2 \cdot k_v}{t_1} \tag{3.10.7}$$

$$R_{source} = \frac{LSG}{W \cdot NF \cdot q \cdot NS0ACCS \cdot U0ACCS} \cdot \frac{1}{1 - (I_{d,eff}/I_{sat,accs})} \tag{3.10.8}$$

#### Gate Region Conductance

$$R_{gate} = RSHG \cdot \frac{XGW + W/(3 \cdot NGCON)}{NGCON \cdot NF \cdot L} \tag{3.10.9}$$

If $R_{gate} > 0$: $G_{gate} = 1/R_{gate}$; else $G_{gate} = 10^3$.

### Parasitic Capacitances

#### Access Region Capacitance

$$C_{accd} = \frac{CJ0}{\left(1 + \frac{V_{ds}}{VBI}\right)^{MZ}} \tag{3.11.1}$$

#### Overlap Capacitances

CGSO, CDSO, CGDO, and CGDL are model parameters applied directly as overlap capacitance contributions.

#### Fringing Capacitances

CFD and CFG are model parameters for fringing capacitance effects. CFG has temperature dependence through KTCFG.

### Trap Model

#### TRAPMOD=5: SRH Dynamic Trap

Forcing potential:

$$\phi_n = \ln\!\left(\exp(\alpha \cdot V_{gs} + \alpha_d \cdot V_{gd} + \beta \cdot V_{ds} + \gamma) + \eta\right) \tag{3.12.1}$$

Emission rate (temperature dependent):

$$EN = ENO \cdot \exp\!\left(\frac{EA}{k \cdot T_{dev}} - \frac{EA}{k \cdot T_{nom}}\right) \tag{3.12.2}$$

Capture current:

$$I_{cn} = CX \cdot EN \cdot (VXMAX - V_x) \cdot \frac{\exp(2\phi_n) - 1}{2} \tag{3.12.3}$$

Emission current:

$$I_{en} = CX \cdot EN \cdot V_x \tag{3.12.4}$$

#### Trap Degradation Function (TRAPMOD=4,5)

$$T_0 = V_{INP} \cdot V_{MAX} \tag{3.12.5}$$

$$T_1 = \sqrt{V_{INP}^2 + V_{MAX}^2} \tag{3.12.6}$$

$$p_{out} = PTUNE \cdot PIN \cdot \frac{T_0}{T_1} \tag{3.12.7}$$

where $V_{INP} \to V_x$, $V_{MAX} \to VDLMAX$, $PIN$ is the untrapped parameter value, and $PTUNE \in \{DLVOFF, DLNS0S, DLNS0D\}$.

### Gate Current Model

#### GATEMOD=1 (Simple Diode)

$$I_{gs} = W \cdot L \cdot NF \cdot \left\{IGSDIO + \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KTGS\right\} \cdot \left(\exp\!\left(\frac{V_{gs}}{NJGS \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.13.1}$$

$$I_{gd} = W \cdot L \cdot NF \cdot \left\{IGDDIO + \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KTGD\right\} \cdot \left(\exp\!\left(\frac{V_{gd}}{NJGD \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.13.2}$$

#### GATEMOD=2 (Poole-Frenkel Reverse Current)

Forward part same as GATEMOD=1:

$$I_{gs,dio} = W \cdot L \cdot NF \cdot \left\{IGSDIO + \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KTGS\right\} \cdot \left(\exp\!\left(\frac{V_{gs}}{NJGS \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.13.3}$$

Electric field:

$$E_{field} = V_{gs} / TBAR \tag{3.13.4}$$

Reverse saturation current (temperature scaled):

$$RIGSDIOT = RIGSDIO + \exp\!\left(\frac{T}{TNOM} - 1\right) \cdot RKTGS \tag{3.13.5}$$

Total with Poole-Frenkel:

$$I_{gs} = I_{gs,dio} \cdot \left(1 + RIGSDIOT \cdot E_{field} \cdot \exp\!\left(\frac{\sqrt{V_{gs}} + EBREAKS}{RNJGS \cdot K_B \cdot T}\right)\right) \tag{3.13.6}$$

#### GATEMOD=3 (p-GaN)

$$I_{gs,dio} = W \cdot NF \cdot IGSDIO \cdot \exp\!\left(\frac{(V_{bi,s})}{NJGS \cdot K_B \cdot T_{dev}}\right) \cdot \left(\exp\!\left(\frac{(V_{gs})^{AGS}}{NJGS \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.13.7}$$

Reverse leakage uses Eq. 3.13.6 form.

Temperature scaling for GATEMOD=3:

$$NJGS(T) = NJGS + KTNJGS \cdot \left(\frac{T_{dev}}{T_{nom}} - 1\right) \tag{3.13.8}$$

$$VBIS(T) = VBIS + KTVBIS \cdot \left(\frac{T_{dev}}{T_{nom}} - 1\right) \tag{3.13.9}$$

$$IGSDIO(T) = IGSDIO \cdot \exp\!\left(KTGS \cdot \left(\frac{T_{dev}}{T_{nom}} - 1\right)\right) \tag{3.13.10}$$

Equivalent equations exist for gate-drain with parameters IGDDIO, NJGD, AGD, VBID, etc.

#### GATEMOD=4 (Decoupled Forward/Reverse)

Smooth max function:

$$\text{hypmax}(x, x_{min}, c) = x_{min} + x - 0.5\left(x_{min} + x - \sqrt{(x - x_{min})^2 + c}\right) \tag{3.13.11}$$

$$V_{gs,p} = \text{hypmax}(V_{gs}, 0, 0) \tag{3.13.12}$$

$$V_{gs,n} = \text{hypmax}(-V_{gs}, 0, 0) \tag{3.13.13}$$

Forward current:

$$I_{gs,dio,p} = W \cdot L \cdot NF \cdot \left\{IGSDIO + \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot KTGS\right\} \cdot \left(\exp\!\left(\frac{V_{gs,p}}{NJGS \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.13.14}$$

Reverse current:

$$I_{gs,dio,n} = W \cdot L \cdot NF \cdot \left\{RIGSDIO + \left(\frac{T_{dev}}{TNOM} - 1\right) \cdot RKTGS\right\} \cdot \left(\exp\!\left(\frac{V_{gs,n}}{RNJGS \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.13.15}$$

Total:

$$I_{gs} = I_{gs,dio,p} - I_{gs,dio,n} \tag{3.13.16}$$

### Field Plate Model

Each field plate transistor (T1=intrinsic, T2=gate FP, T3=source FP, etc.) uses the same surface potential, charge, and current equations with its own parameter set (VOFFFPx, DFPx, LFPx, etc.).

FPxMOD=1: gate-connected field plate. FPxMOD=2: source-connected field plate.

#### Cross-Coupling Capacitances

For dual field-plate topology (FP1MOD=1, FP2MOD=2):

$$Q_{cc,cgd} = -CFP2SCALE \cdot W \cdot LFP2 \cdot C_{g,FP2} \left\{V_{g0,FP2} - \frac{1}{2}(\psi_{s,FP2} + \psi_{d,FP2}) + \frac{(\psi_{d,FP2} - \psi_{s,FP2})^2}{12\left(V_{g0,FP2} - \frac{K_BT}{q} - \frac{1}{2}(\psi_{s,FP2} + \psi_{d,FP2})\right)}\right\} \tag{3.14.1}$$

$$Q_{cc,csd} = -CFP1SCALE \cdot W \cdot LFP1 \cdot C_{g,FP1} \left\{V_{g0,FP1} - \frac{1}{2}(\psi_{s,FP1} + \psi_{d,FP1}) + \frac{(\psi_{d,FP1} - \psi_{s,FP1})^2}{12\left(V_{g0,FP1} - \frac{K_BT}{q} - \frac{1}{2}(\psi_{s,FP1} + \psi_{d,FP1})\right)}\right\} \tag{3.14.2}$$

#### Substrate Capacitance

$$Q_{sub,K} = -CSUBSCALE_K \cdot W \cdot L_K \cdot C_{g,K} \left\{V_{g0,K} - \frac{1}{2}(\psi_{s,K} + \psi_{d,K}) + \frac{(\psi_{d,K} - \psi_{s,K})^2}{12\left(V_{g0,K} - \frac{K_BT}{q} - \frac{1}{2}(\psi_{s,K} + \psi_{d,K})\right)}\right\} \tag{3.14.3}$$

where $K \in \{i, 1, 2\}$ for intrinsic, FP1, and FP2 transistors respectively.

#### Quantum Mechanical Effects

$$C_g = \frac{\epsilon_{\text{AlGaN}}}{TBAR + \frac{ADOSI}{(1 + CDOSI \cdot (Q_g/QM0I))^{BDOSI}}} \tag{3.14.4}$$

(Note: In the VA code, CDOSI is simply 1 and ADOSI is the prefactor/switch. The parameter is named ADOSI with BDOSI controlling the slope.)

### Noise Model

#### Flicker Noise (FNMOD=1)

Trap number fluctuation PSD:

$$S_N(f) = N_t \cdot \frac{k_B T_{dev}}{N_{Pt} \cdot f^{EF}} \tag{3.15.1}$$

Drain current noise PSD:

$$S_{if}(f) = \frac{S_N(f)}{W L^2} \int_0^L \left(\frac{\partial I_{DS}}{\partial N_t}\right)^2 dx \tag{3.15.2}$$

Current expression:

$$I_{DS} = \mu W (-Q_{ch}(x))\frac{\partial\psi}{\partial x} \tag{3.15.3}$$

$$\partial I_{DS} = I_{DS}\left(\frac{qR}{-Q_{ch}} \pm \frac{1}{\mu}\frac{\partial\mu}{\partial N_t}\right) \tag{3.15.5}$$

Final flicker noise PSD:

$$S_{if}(f) = \frac{K_r}{W L^2 f^{EF} C_g^2} \cdot k_B T \cdot I_{DS}^2 \left[NOIA \cdot V_{tv} \cdot C_g \left(\frac{1}{Q_{ch,d}} - \frac{1}{Q_{ch,s}}\right)\right.$$

$$+ (NOIA + NOIB \cdot V_{tv} \cdot C_g)\ln\frac{Q_{ch,d}}{Q_{ch,s}}$$

$$+ (NOIB + NOIC \cdot V_{tv} \cdot C_g)(-Q_{ch,d} + Q_{ch,s})$$

$$\left.+ \frac{NOIC}{2}(Q_{ch,d}^2 - Q_{ch,s}^2)\right] \tag{3.15.6-7}$$

where $K_r = L/[(V_{g0} - \psi_m + V_{tv})(\psi_d - \psi_s)]$ and $Q_{ch,(d/s)} = q C_g(V_{g0} - \psi_{(d/s)})$.

#### Thermal Noise (TNMOD=1)

$$S_{it} = \frac{4 k_B T_{dev}}{I_D L_{eff}^2} \int_{\psi_s}^{\psi_d} g^2(\psi)\,d\psi \tag{3.15.8}$$

where $g(\psi) = \mu_{eff,sat} \cdot W \cdot q \cdot n_s$.

$$S_{it} = \frac{4 k_B T_{dev}}{I_D L_{eff}^2}\,(\mu_{eff,sat}\,W\,q\,C_g)^2 \left[V_{g0}^2\,\psi_{ds} + \frac{\psi_d^3 - \psi_s^3}{3} - V_{g0}(\psi_d^2 - \psi_s^2)\right] \tag{3.15.9}$$

### Drain-Source Breakdown Model

$$I_{ds,bv} = ASL \cdot W \cdot NF \cdot \left(e^{(V_{ds} - BVDSL)/(NSL \cdot V_{tv})} - e^{(-BVDSL)/(NSL \cdot V_{tv})}\right) \tag{3.15.10}$$

Temperature scaling:

$$NSLT = NSL \cdot \left(1 + KNSL \cdot \left(\frac{T}{T_{nom}} - 1\right)\right) \tag{3.15.11}$$

$$BVDSLT = BVDSL \cdot \left(1 + KBVDSL \cdot \left(\frac{T}{T_{nom}} - 1\right)\right) \tag{3.15.12}$$

$$ASLT = ASL \cdot \left(1 + KASL \cdot \left(\frac{T}{T_{nom}} - 1\right)\right) \tag{3.15.13}$$

### Substrate Leakage Model

$$T_3 = \max(V_{db} - VBIDB,\; 0) \tag{3.16.1}$$

$$I_{db} = W \cdot NF \cdot IDBL \cdot \left(\exp\!\left(\frac{T_3}{NBD \cdot K_B \cdot T_{dev}}\right) - 1\right) \tag{3.16.2}$$

Equivalent equations for source-to-substrate leakage use ISBL, NSB, VBISB.

### AC Symmetry Test Functions (Benchmark)

$$\delta_{cg} = \frac{C_{GS} - C_{GD}}{C_{GS} + C_{GD}} \tag{5.4.1}$$

$$\delta_{csd} = \frac{C_{SS} - C_{DD}}{C_{SS} + C_{DD}} \tag{5.4.2}$$
