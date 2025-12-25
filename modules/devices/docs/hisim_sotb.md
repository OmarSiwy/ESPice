# HiSIM-SOTB 1.3.0 -- Parameter & Equation Reference

> Thin-body SOI MOSFET (Silicon-On-Thin-Buried-oxide)
> Copyright 2014-2021 Hiroshima University and STARC
> Manual date: November 16, 2021

## Model Topology

HiSIM SOTB is a surface-potential-based compact model for ultra-thin SOI and BOX layer MOSFETs, including double-gate structures. The device has four terminals: Gate (G), Drain (D), Source (S), and Substrate/Body (E, denoted Ves). Internal nodes SP and DP are introduced for source-side and drain-side parasitic resistances. An optional gate resistance node is also supported. The model solves the Poisson equation simultaneously at front-gate and back-gate surfaces to obtain surface potentials $\phi_s$ (front) and $\phi_b$ (back), from which all charges, currents, and capacitances are derived.

---

## Parameters

### Basic Device Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TYPE | - | 1 | [-1, 1] | 1 for nMOS, -1 for pMOS |
| TFOX | m | 3.5n | (0, -) | Front oxide thickness |
| TBOX | m | 10n | (0, -) | Buried oxide thickness |
| TSOI | m | 10n | (0, -) | Silicon film thickness |
| XLD | m | 0 | [0, 50n] | Gate overlap length |
| XLDL | m | 20.0e-9 | -- | Channel-length dependence of XLD |
| XLDLMIN | m | 10.0e-9 | -- | Minimum value of XLDL |
| XWD | m | 0 | [-10n, 50n] | Gate overlap width |
| XWDC | m | 0 | -- | Different width dependence of capacitance from currents |
| TPOLY | m | 0 | [0, -] | Height of poly-Si gate for fringing capacitance |
| NSUBS | cm^-3 | 1e17 | [1e15, 1e19] | SOI layer impurity concentration |
| NSUBB | cm^-3 | 1e18 | [1e15, -] | Substrate impurity concentration |
| NSUBBL | cm^-3 | 0.0 | -- | Channel-length dependence of NSUBB |
| NSUBBLP | cm^-3 | 1.0 | -- | Channel-length dependence of NSUBB |
| NSUBBW | - | 0.0 | -- | W dependence of NSUBB |
| NSUBBWP | - | 1.0 | -- | W dependence of NSUBB |
| NSUBBMIN | cm^-3 | 1.0e14 | -- | Minimum value of NSUBB |
| NSUBP | cm^-3 | 1e17 | [1e16, 1e19] | Max pocket concentration |
| VFBC | V | -1 | [-1.2, -0.5] | Flat-band voltage |
| VBI | V | 1.1 | [1, 1.2] | Built-in potential |
| VFBCL1 | V | 0.0 | -- | Channel length dependence of flat-band voltage |
| VFBCL1P | - | 1.0 | -- | Channel length dependence of flat-band voltage |
| VFBCL2 | V | 0.0 | -- | Channel length dependence of flat-band voltage |
| VFBCL2P | - | 1.0 | -- | Channel length dependence of flat-band voltage |
| VFBHAMP | V/cm | 0.0 | -- | Channel length dependence of flat-band voltage |
| VBSBND | V | 3.0 | -- | Vbs for smoothing |
| VBSMAX | V | 3.5 | -- | Maximum Vbs |

### Smoothing Coefficients (Linear/Saturation Transition)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DDLTMAX | - | 10 | [1, 20] | Smoothing coefficient for Vds |
| DDLTSLP | um^-1 | 50 | [0, 100] | Lgate-dependence of smoothing coefficient |
| DDLTICT | - | 0 | [-3, 20] | Lgate-dependence of smoothing coefficient |

### Mobility and Velocity (Front Current)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| MUECB0 | cm^2/(V*s) | 300 | [100, 100k] | Coulomb scattering coefficient |
| MUECB0LP | - | 0.0 | -- | Length dependence of Coulomb scattering |
| MUECB0L2 | - | 0.0 | -- | Length dependence of Coulomb scattering |
| MUECB0L2P | - | 1.0 | -- | Length dependence of Coulomb scattering |
| MUECB1 | cm^2/(V*s) | 30 | [1, 10k] | Coulomb scattering coefficient |
| MUECB1LP | - | 0.0 | -- | Length dependence of Coulomb scattering |
| MUECB1L2 | - | 0.0 | -- | Length dependence of Coulomb scattering |
| MUECB1L2P | - | 1.0 | -- | Length dependence of Coulomb scattering |
| MUEPH0 | - | 0.3 | [0.25, 0.35] | Phonon scattering exponent |
| MUEPH1 | cm^2/(V*s) | 25k (nMOS) / 9k (pMOS) | [2k, 100k] | Phonon scattering coefficient |
| MUETMP | - | 1.5 | [0.5, 2] | Temperature dependence of phonon scattering |
| MUETMPL | - | 0.0 | -- | Temperature dependence of phonon scattering |
| MUETMPLP | - | 1.0 | -- | Temperature dependence of phonon scattering |
| MUETMP1 | - | 0.0 | -- | Temperature dependence of phonon scattering |
| MUEPHL | - | 0 | -- | L-dependence of phonon mobility reduction |
| MUEPLP | - | 1 | -- | L-dependence of phonon mobility |
| MUESR0 | - | 2 | [1.8, 2.2] | Surface-roughness scattering exponent |
| MUESR1 | cm^2/(V*s) * (V/cm)^MUESR0 | 2e15 | [1e13, 1e16] | Surface-roughness scattering coefficient |
| MUESRL | - | 0 | -- | L-dependence of surface roughness on mobility |
| MUESLP | - | 1 | -- | L-dependence of surface roughness on mobility |
| NDEP | - | 1 | [0, 1] | Depletion charge contribution to Eeff |
| NDEPL | - | 0.0 | -- | Modify QB contribution for short channel |
| NDEPLP | - | 0.0 | -- | Modify QB contribution for short channel |
| NINV | - | 0.5 | [0, 1] | Inversion charge contribution to Eeff |
| NINVL | - | 0.0 | -- | Length dependence of NINV |
| NINVLP | - | 0.0 | -- | Length dependence of NINV |
| NINVD | V^-1 | 0.0 | [0, -] | Inversion charge parameter |
| NINVDP | - | 1.0 | [0, -] | Inversion charge parameter |
| BB | - | 2 (nMOS) / 1 (pMOS) | -- | High-field-mobility degradation exponent |
| VMAX | cm/s | 7e6 | [1e6, 2e7] | Saturation velocity |
| VOVER | - | 10e-3 | [0, 1] | Velocity overshoot effect parameter |
| VOVERP | - | 100e-3 | [0, 3] | L dependence of velocity overshoot |
| VOVERL | - | 0 | -- | Velocity overshoot effect parameter |
| VOVERLP | - | 1 | -- | L dependence of velocity overshoot |
| VOVERW | - | 0 | -- | Velocity overshoot W-dependence |
| VOVERWP | - | 1 | -- | W dependence of velocity overshoot |
| VTMP | - | 0 | [-2, 1] | Temperature dependence of saturation velocity |
| VTMPL | - | 0 | -- | Temperature dependence of saturation velocity |
| VTMPLP | - | 1.0 | -- | Temperature dependence of saturation velocity |
| VOTMP | - | 0.0 | -- | Temperature-dependence coefficient |
| VOTMP2 | - | 0.0 | -- | Temperature-dependence coefficient |
| MUEQB | - | 0.0 | -- | Magnitude of QbL for front side mobility |
| MUEQBL | - | 0.0 | -- | Length dependence of MUEQB and MUEQBB |
| MUEQBLP | - | 0.0 | -- | Length dependence of MUEQB and MUEQBB |
| MUEQBB | - | 1.0 | -- | Magnitude of QbL for back side mobility |

### Mobility Model (Back Current)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| MUECB0B | - | =MUECB0 | -- | Coulomb scattering for back current |
| MUECB0LPB | - | =MUECB0LP | -- | Length dependence of Coulomb scattering |
| MUECB0L2B | - | =MUECB0L2 | -- | Length dependence of Coulomb scattering |
| MUECB0L2PB | - | =MUECB0L2P | -- | Length dependence of Coulomb scattering |
| MUECB1B | - | =MUECB1 | -- | Coulomb scattering for back current |
| MUECB1LPB | - | =MUECB1LP | -- | Length dependence of Coulomb scattering |
| MUECB1L2B | - | =MUECB1L2 | -- | Length dependence of Coulomb scattering |
| MUECB1L2PB | - | =MUECB1L2P | -- | Length dependence of Coulomb scattering |
| MUEPH0B | - | =MUEPH0 | -- | Phonon scattering for back current |
| MUEPH1B | - | =MUEPH1 | -- | Phonon scattering for back current |
| MUEPHLB | - | =MUEPHL | -- | Length dependence of phonon mobility |
| MUEPLPB | - | =MUEPLP | -- | Length dependence of phonon mobility |
| MUESR0B | - | =MUESR0 | -- | Surface-roughness scattering for back current |
| MUESR1B | - | =MUESR1 | -- | Surface-roughness scattering for back current |
| MUESRLB | - | =MUESRL | -- | Length dependence of surface roughness mobility |
| MUESLPB | - | =MUESLP | -- | Length dependence of surface roughness mobility |

### Short-Channel Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PARL1 | m | 10n | [0, 50n] | SOI SCE parameter |
| PARL2 | m | 10n | [0, 50n] | Depletion width of channel/contact junction |
| SC1 | - | 0 | [0, 20] | Magnitude of short-channel effect |
| SC2 | V^-1 | 0 | [0, 50] | Vds-dependence of short-channel effect |
| SC3 | m/V | 0 | [0, 1m] | Ves-dependence of short-channel effect |
| SC5 | - | 0.0 | -- | SCE parameter |
| SCR1 | - | 0 | [0, 5] | Parameter for SCE via BOX |
| SCR2 | - | 0 | [0, 5] | Parameter for SCE via BOX |
| SCR3 | - | 0.23 | [0, 1] | Parameter for SCE via BOX |
| SCP1 | - | 0 | [0, 50] | Magnitude of short-channel effect due to pocket |
| SCP2 | V^-1 | 0 | [0, 50] | Vds-dependence of SCE due to pocket |
| SCP3 | m/V | 0 | [0, 1m] | Ves-dependence of SCE due to pocket |
| LP | m | 0 | [0, 300n] | Pocket penetration length |
| PTHROU | - | 0.0 | -- | Subthreshold swing parameter |
| VFBSHIFT | - | 0.0 | -- | Coefficient for Vfb shift |

### Poly-Silicon Gate Depletion Effect

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PGD1 | V | 0 | [0, 50m] | Strength of poly-depletion effect |
| PGD2 | V | 1 | [0, 1.5] | Threshold voltage of poly-depletion effect |
| PGD4 | - | 0 | [0, 3] | Lgate-dependence of poly-depletion effect |

### Quantum Mechanical Effect

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| QME1 | m*V | 0 | [0, 300n] | Vgs-dependence of quantum mechanical effect |
| QME2 | V | 0 | [0, 3] | Vgs-dependence of quantum mechanical effect |
| QME3 | m | 0 | [0, 800p] | Minimum TFOX modification |

### Channel-Length Modulation

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CLM1 | - | 0.7 | [0.5, 1] | Abruptness coefficient of channel/contact junction |
| CLM2 | - | Eq.(127) | [2, -] | Coefficient for QB contribution |
| CLM3 | - | 1 | [1, 5] | Coefficient for QI contribution |
| CLM5 | - | 1 | [0, 5] | CLM parameter |
| CLM6 | um^-CLM5 | 0 | [0, 5] | CLM parameter |

### Punchthrough Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PTL | V^(PTP-1)*m^PTLP | 0 | [0, -] | Punchthrough strength |
| PTLP | - | 1 | -- | Punchthrough Lgate dependence |
| PTP | - | 3.5 | [3, 4] | Punchthrough exponent |
| PT2 | V^-1 | 0 | [0, -] | Punchthrough Vds dependence |
| PT4 | - | 0 | [0, -] | Punchthrough Ves dependence |
| PT4P | - | 1 | [0, -] | Punchthrough Ves Lgate dependence |
| GDL | m^GDLP | 0 | [0, 220m] | Strength of high-field effect in front current |
| GDLP | - | 0.0 | -- | Modification of channel conductance |
| GDLD | m | 0 | -- | Modification of channel conductance |

### Narrow-Channel Effect Parameters (Front)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WFC | F/(cm^2*m) | 0 | [-5e-15, 1e-6] | Threshold voltage change due to cap change |
| WVTH0 | V*um | 0 | -- | Threshold voltage shift |
| NSUBSW | um^NSUBSWP | 0 | -- | W dependence of NSUBS |
| NSUBSWP | - | 1 | -- | W dependence of NSUBS |
| NSUBSMAX | cm^-3 | 5e18 | -- | Upper limit of SOI layer concentration |
| NSUBP0 | um^NSUBWP | 0 | -- | Modification of pocket concentration for narrow W |
| NSUBWP | - | 1 | -- | Modification of pocket concentration for narrow W |
| MUEPHW | um^MUEPWP | 0 | -- | Phonon-related mobility reduction |
| MUEPWP | - | 1 | -- | Phonon-related mobility reduction |
| MUESRW | um^MUESWP | 0 | -- | Surface roughness-related mobility change |
| MUESWP | - | 1 | -- | Surface roughness-related mobility change |
| WL2 | V*um^WL2P | 0 | -- | Threshold voltage shift due to small-size effect |
| WL2P | - | 1 | -- | Threshold voltage shift due to small-size effect |
| MUEPHS | um^MUEPSP | 0 | -- | Mobility change due to small size |
| MUEPSP | - | 1 | -- | Mobility change due to small size |
| VOVERS | - | 0 | -- | Modification of max velocity due to small size |
| VOVERSP | - | 1 | -- | Modification of max velocity due to small size |

### Narrow-Channel Effect Parameters (Back)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| MUEPHWB | um^MUEPWP | 0 | -- | Phonon-related mobility reduction (back) |
| MUEPWPB | - | 1 | -- | Phonon-related mobility reduction (back) |
| MUEPHSB | um^MUEPSP | 0 | -- | Mobility change due to small size (back) |
| MUEPSPB | - | 1 | -- | Mobility change due to small size (back) |
| MUESRWB | um^MUESWP | 0 | -- | Surface roughness-related mobility change (back) |
| MUESWPB | - | 1 | -- | Surface roughness-related mobility change (back) |

### Well-Proximity Effect

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NSUBSWPE | cm^-3 | 0 | -- | Channel concentration change due to WPE |
| NSUBPWPE | cm^-3 | 0 | -- | Pocket concentration change due to WPE |
| WEB | - | 0 | -- | Modification of layout characterization factor |
| WEC | - | 0 | -- | Modification of layout characterization factor |

### STI Effects

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VTHSTI | V | 0 | -- | Threshold voltage shift due to STI |
| VDSTI | - | 0 | -- | Vds dependence of STI subthreshold |
| SCSTI1 | - | 0 | -- | Same effect as SC1 but at STI edge |
| SCSTI2 | V^-1 | 0 | -- | Same effect as SC2 but at STI edge |
| NSTI | cm^-3 | 5e17 | [1e16, 1e19] | Substrate impurity concentration at STI edge |
| NSTIL | um^NSTILP | 0 | -- | Channel-length dependence of NSTI |
| NSTILP | - | 1.0 | -- | Channel-length dependence of NSTI |
| NSTIW | um^NSTIWP | 0 | -- | Channel-width dependence of NSTI |
| NSTIWP | - | 1.0 | -- | Channel-width dependence of NSTI |
| WSTI | m | 0 | -- | Width of high-field region at STI edge |
| WSTIL | um^WSTILP | 0 | -- | Channel-length dependence of WSTI |
| WSTILP | - | 1.0 | -- | Channel-length dependence of WSTI |
| WSTIW | um^WSTIWP | 0 | -- | Channel-width dependence of WSTI |
| WSTIWP | - | 1.0 | -- | Channel-width dependence of WSTI |
| RATWSTI | - | 0.0 | -- | Ratio of WSTI |
| WL1 | um^(2*WL1P+1) | 0 | -- | Small-size effect parameter for STI leakage |
| WL1P | - | 1.0 | -- | Small-size effect parameter for STI leakage |

### STI Diffusion-Length Effects

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NSUBSSTI1 | m | 0 | -- | Channel concentration modifier |
| NSUBSSTI2 | - | 0 | -- | Channel concentration modifier |
| NSUBSSTI3 | - | 1.0 | -- | Channel concentration modifier |
| NSUBPSTI1 | m | 0 | -- | Pocket concentration modifier |
| NSUBPSTI2 | - | 0 | -- | Pocket concentration modifier |
| NSUBPSTI3 | - | 1 | -- | Pocket concentration modifier |
| MUESTI1 | m | 0 | -- | Mobility change due to diffusion length |
| MUESTI2 | - | 0 | -- | Mobility change due to diffusion length |
| MUESTI3 | - | 1 | -- | Mobility change due to diffusion length |
| SAREF | m | 1e-6 | -- | Ref-dist between OD edge to poly of one side |
| SBREF | m | 1e-6 | -- | Ref-dist between OD edge to poly of other side |

### Temperature Dependence

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| EG0 | eV | 1.1785 | [1, 1.3] | Bandgap |
| BGTMP1 | eV/K | 90.25e-6 | [50e-6, 100e-6] | Temperature dependence of bandgap |
| BGTMP2 | eV/K^2 | 0.1e-6 | [-1e-6, 1e-6] | Temperature dependence of bandgap |
| TNOM | degC | 27 | [22, 32] | Nominal temperature |

### Parasitic Resistance (Drift Region)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RSHG | Ohm/sq | 0 | -- | Gate sheet resistance |
| RSH | Ohm/sq | 0 | [0, 10m] | Source/drain sheet resistance |
| LDRIFT | m | 1u | -- | Length of drift region (drain side) |
| LDRIFTS | m | 1u | -- | Length of drift region (source side) |
| RDRBBD | - | 1 | -- | High field mobility in drift region (drain side) |
| RDRBBS | - | 1 | -- | High field mobility in drift region (source side) |
| RDRMUED | - | 1e3 | -- | Mobility in drift region (drain side) |
| RDRMUES | - | 1e3 | -- | Mobility in drift region (source side) |
| RDRVMAXD | - | 3e7 | -- | Saturation velocity in drift region (drain side) |
| RDRVMAXS | - | 3e7 | -- | Saturation velocity in drift region (source side) |
| RDRVTMP | - | 0 | -- | Temperature dependence of resistance |
| RDRMUETMP | - | 0 | -- | Temperature dependence of resistance |
| RDRBBTMP | - | 0 | -- | Temperature dependence of resistance |
| NOVERS | cm^-3 | 1e19 | -- | Impurity concentration in overlap region (source side) |
| RDRDJUNC | m | 1u | -- | Junction depth at channel/drift region |
| RDRVMAXL | - | 0 | -- | Saturation velocity Lgate dependence |
| RDRVMAXLP | - | 1 | -- | Saturation velocity Lgate dependence |
| RDRVMAXW | - | 0 | -- | Saturation velocity Wgate dependence |
| RDRVMAXWP | - | 1 | -- | Saturation velocity Wgate dependence |
| RDRMUEL | - | 0 | -- | Mobility in drift region Lgate dependence |
| RDRMUELP | - | 1 | -- | Mobility in drift region Lgate dependence |

### Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| XQY | m | 0 | [0, 50n] | Distance from junction to max field point |
| XQY1 | F*um^(XQY2-1) | 0 | [0, -] | Ves-dependence of Qy |
| XQY2 | - | 2 | [0, -] | Lgate-dependence of Qy |
| LOVER | m | 30n | (0, -) | Overlap length |
| NOVER | cm^-3 | 1e19 | -- | Impurity concentration in overlap region |
| VFBOVER | V | 0 | -- | Flat-band voltage in overlap region |
| CGDO | F/m | none | [0, 102n*CFOX] | Gate-to-drain overlap cap (used only if specified) |
| CGSO | F/m | none | [0, 102n*CFOX] | Gate-to-source overlap cap (used only if specified) |
| CGBO | F/m | none | [0, -] | Gate-to-bulk overlap cap (used only if specified) |

### Substrate Current (Impact Ionization)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VFBSUB | V | -1 | -- | Flatband voltage for Isub calculation |
| VFBSUBL | um^VFBSUBLP | 0 | -- | Lgate-dependence of VFBSUB |
| VFBSUBLP | - | 1 | -- | Lgate-dependence of VFBSUB |
| SUB1 | V^-1 | 10 | -- | Substrate current coefficient of magnitude |
| SUB1L | m | 2.5e-3 | -- | Lgate-dependence of SUB1 |
| SUB1LP | - | 1 | -- | Lgate-dependence of SUB1 |
| SUB2 | V | 20 | -- | Substrate current coefficient of exponential term |
| SUB2L | m | 2e-6 | [0, 1] | Lgate-dependence of SUB2 |
| SUBDLT | - | 2e-3 | -- | Smoothing parameter |
| SVDS | - | 0.8 | -- | Substrate current dependence on Vds |
| SLG | m | 3e-8 | -- | Substrate current dependence on Lgate |
| SVGS | - | 0.8 | -- | Substrate current dependence on Vgs |
| SVGSL | m^SVGSLP | 0 | -- | Lgate-dependence of SVGS |
| SVGSLP | - | 1 | -- | Lgate-dependence of SVGS |
| SVGSW | m^SVGSWP | 0 | -- | Wgate-dependence of SVGS |
| SVGSWP | - | 1 | -- | Wgate-dependence of SVGS |
| SVBS | - | 0.5 | -- | Substrate current dependence on Ves |
| SVBSL | m^SVBSLP | 0 | -- | Lgate-dependence of SVBS |
| SVBSLP | - | 1 | -- | Lgate-dependence of SVBS |
| IBPC1 | V/A | 0 | [0, 1e12] | Impact-ionization-induced bulk potential change |
| IBPC2 | V^-1 | 0 | [0, 1e12] | Impact-ionization-induced bulk potential change |

### Gate Leakage Current

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| GLEAK1 | V^(-3/2)/s | 1e4 | -- | Gate-to-channel current coefficient |
| GLEAK2 | V^(-1/2)/m | 20e6 | -- | Gate-to-channel current coefficient |
| GLEAK3 | - | 3e-1 | -- | Gate-to-channel current coefficient |
| GLEAK4 | m^-1 | 0 | -- | Gate-to-channel current coefficient |
| GLEAK5 | V/m | 7.5e3 | -- | G-t-C short channel correction |
| GLEAK6 | V | 2.5e-1 | -- | G-t-C Vds-dependence correction |
| GLEAK7 | m^2 | 1e-6 | -- | G-t-C L and W dependence correction |
| GLEAK8 | - | 1.0 | -- | Gate-to-channel current coefficient |
| GLEAK9 | - | 5.0e-1 | -- | Gate-to-channel current coefficient |
| GLEAK10 | - | 0.0 | -- | Gate-to-channel current coefficient |
| GLKSD1 | A*m/V^2 | 1e-15 | -- | G-t-S/D current coefficient |
| GLKSD2 | V^-1/m | 5e6 | -- | G-t-S/D current coefficient |
| GLKSD3 | m^-1 | -5e6 | -- | G-t-S/D current coefficient |
| GLKSD4 | - | 0.0 | -- | G-t-S/D current coefficient |
| GLKSD5 | - | 1.0 | -- | G-t-S/D current coefficient |
| GLKB1 | A/V^2 | 5e-16 | -- | G-t-B current coefficient (accumulation) |
| GLKB2 | m/V | 1 | -- | G-t-B current coefficient |
| GLKB3 | V | 0 | -- | G-t-B current coefficient |
| GLKB4 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB5 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB6 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB7 | - | 10e-12 | -- | G-t-B current coefficient |
| GLKB8 | - | 15e-12 | -- | G-t-B current coefficient |
| GLKB21 | - | 5e-16 | -- | G-t-B current coefficient (2nd component) |
| GLKB22 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB23 | - | 0.0 | -- | G-t-B current coefficient |
| GLKB24 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB25 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB26 | - | 1.0 | -- | G-t-B current coefficient |
| GLKB27 | - | 10e-12 | -- | G-t-B current coefficient |
| GLKB28 | - | 15e-12 | -- | G-t-B current coefficient |

### Gate-Induced Drain/Source Leakage (GIDL/GISL)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| GIDL1 | A*V^(-3/2)*C^-1*m^(1/2) | 5e-6 | -- | Magnitude of GIDL |
| GIDL2 | V^-2*m^-1*F^(-3/2) | 1e6 | -- | Field-dependence of GIDL |
| GIDL3 | - | 0.3 | -- | Vds-dependence of GIDL |
| GIDL4 | V | 0 | -- | Threshold for Vds dependence |
| GIDL5 | - | 0.2 | -- | High-field correction |
| GIDLBPL1 | m | 1.0e-6 | -- | Length for GIDL/GISL parasitic bipolar effect |
| GIDLBPLT | - | 0.0 | -- | Temperature effect for GIDLBPL1 |
| TFOXGIDL | m | 3.5e-9 | -- | TFOX for GIDL |

### Valence Band Electron Tunneling

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| EVB1 | V^-2/s | 0 | [0, -] | Electron tunneling from valence band |
| EVB2 | V/m | 0 | [0, -] | Electron tunneling from valence band |
| EVB3 | - | 0 | -- | Electron tunneling from valence band |
| FVBS | - | 0 | [0, -] | Ves dependence of Fowler-Nordheim current |

### Floating-Body Effect

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| QHE1 | - | 1.5 | (0, -) | FBE parameter |
| QHE2 | V | 0.55 | (0, -) | FBE parameter |
| HIST1 | V | 1e-8 | (0, -) | History-effect parameter |
| HIST2 | A | 1e-20 | (0, -) | History-effect parameter |

### 1/f Noise

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NFALP | cm*s | 1e-16 | -- | Contribution of mobility fluctuation |
| NFTRP | V^-1 | 1e10 | -- | Ratio of trap density to attenuation coefficient |
| CIT | F/cm^2 | 0 | -- | Capacitance caused by interface trapped carriers |
| FALPH | s*m^3 | 1.0 | -- | Power of f describing deviation from 1/f |

### Non-Quasi-Static Model

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DLY1 | s | 1e-10 | -- | Coefficient for delay due to diffusion of carriers |
| DLY2 | - | 0.7 | -- | Coefficient for delay due to conduction of carriers |
| DLY3 | Ohm | 8e-7 | -- | Coefficient for RC delay of bulk carriers |

### Self-Heating

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RTH0 | K*cm/W | 0.1 | -- | Thermal resistance |
| CTH0 | W*s/(K*cm) | 1e-7 | -- | Thermal capacitance |

### Symmetry Conservation (Vds=0)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VZADD0 | V | 10m | -- | Symmetry conservation coefficient |
| PZADD0 | V | 5m | -- | Symmetry conservation coefficient |

### Model Selection Flags

| Flag | Default | Description |
|------|---------|-------------|
| COOVLP | 0 | Overlap cap model: 0=constant, 1=bias-dependent |
| COQOVSM | 1 | Overlap cap surface potential: 0=analytical, 1=iterative |
| COISUB | 0 | Substrate current: 0=no, 1=yes |
| COIIGS | 0 | Gate current: 0=no, 1=yes |
| COGIDL | 0 | GIDL current: 0=no, 1=yes |
| COISTI | 0 | STI leakage current: 0=no, 1=yes |
| COADOV | 1 | Lateral field / overlap charges: 0=no, 1=yes |
| CONQS | 0 | Non-quasi-static: 0=no, 1=yes |
| CORS | 0 | Source resistance: 0=no, 1=yes |
| CORD | 0 | Drain resistance: 0=no, 1=yes |
| CORG | 0 | Gate resistance: 0=no, 1=yes |
| COFLICK | 0 | 1/f noise: 0=no, 1=yes |
| COTHRML | 0 | Thermal noise: 0=no, 1=yes |
| COIGN | 0 | Induced gate noise: 0=no (requires COTHRML=1) |
| COPPRV | 1 | Iterative Poisson from previous step: 0=no, 1=yes |
| COSELFHEAT | 0 | Self-heating: 0=no, 1=yes |
| COFBE | 0 | Floating-body effect: 0=no, 1=yes (requires COISUB=1) |
| COHIST | 0 | History effect: 0=no, 1=yes |
| COIEVB | 0 | Valence-band electron tunneling: 0=no, 1=yes |
| COVBSBIZ | 0 | Symmetry treatment: 0=no, 1=yes |
| COCINV | 0 | Inversion capacitance: 0=no, 1=yes |
| CONEWMUB | 0 | New mobility model: 0=old, 1=new |

### Instance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| L | m | 5e-6 | (0, -) | Gate length (Lgate) |
| W | m | 5e-6 | (0, -) | Gate width (Wgate) |
| XGL | m | 0 | (-L, L) | Offset of gate length |
| XGW | m | 0 | [0, -] | Distance from gate contact to channel edge |
| M | - | 1 | (0, -) | Multiplication factor |
| NF | - | 1 | (0, -) | Number of gate fingers |
| NGCON | - | 1 | (0, -) | Number of gate contacts |
| SA | m | 0 | [0, -] | Length of diffusion between gate and STI |
| SB | m | 0 | [0, -] | Length of diffusion between gate and STI |
| SD | m | 0 | [0, -] | Length of diffusion between gate and gate |
| SCA | - | 0 | -- | Layout characterization factor for WPE |
| SCB | - | 0 | -- | Layout characterization factor for WPE |
| SCC | - | 0 | -- | Layout characterization factor for WPE |
| TEMP | degC | 27 | -- | Device temperature |
| DTEMP | degC | 0 | -- | Device temperature change |
| NRD | - | 1 | -- | Number of drain squares |
| NRS | - | 1 | -- | Number of source squares |
| LDRIFT | m | 1u | -- | Length of drift region (drain side) |
| LDRIFTS | m | 1u | -- | Length of drift region (source side) |

---

## Equations

### 1. Device Geometry

$$L_{gate} = L_{drawn} \tag{1}$$

$$W_{gate} = \frac{W_{drawn}}{NF} \tag{2}$$

$$L_{eff} = L_{gate} - 2 \times X_{ld} \tag{3}$$

$$W_{eff} = W_{gate} - 2 \times XWD - 2 \times W_{STI,mod} \tag{4}$$

$$W_{effc} = W_{gate} - 2 \times XWDC - 2 \times W_{STI,mod} \tag{5}$$

$$X_{ldmod} = \frac{XLD \cdot L_{gate}}{XLDL + XLDLMIN} \tag{6}$$

$$X_{ld} = \begin{cases} \min(X_{ldmod},\, XLD) & (XLD > 0) \\ \max(X_{ldmod},\, XLD) & (XLD \le 0) \end{cases} \tag{7}$$

### 2. Basic Poisson Equation (SOTB Core)

$$\phi_s = V_{G0} + \frac{Q_{bulk} + Q_i + Q_{dep,SOI} + Q_b + Q_h}{C_{FOX}} \tag{8}$$

$$V_{G0} = V_{gs} - V_{FB} + \Delta V_{th} \tag{9}$$

Condition (i): $Q_{bulk} < 0$ (smooth potential):

$$\phi_s = \phi_b^{\prime} + \frac{Q_{bulk} + \tfrac{1}{2}Q_{dep,SOI} + Q_b}{C_{SOI}} \tag{10}$$

Condition (ii): $Q_{bulk} > 0$ (smooth potential):

$$\phi_b = \phi_b^{\prime} + \frac{Q_{bulk} - \tfrac{1}{2}Q_{dep,SOI}}{C_{SOI}} \tag{11}$$

Condition (iii): $Q_{bulk} \approx 0$ (potential peak in SOI):

$$\phi_s = \phi_b^{\prime} + \frac{Q_{bulk} + \tfrac{1}{2}Q_{dep,SOI} + Q_b}{C_{SOI}} \tag{12a}$$

$$\phi_b = \phi_b^{\prime} + \frac{Q_{bulk} - \tfrac{1}{2}Q_{dep,SOI}}{C_{SOI}} \tag{12b}$$

Gauss law at BOX:

$$\phi_{bulk} = \phi_b + \frac{Q_{bulk}}{C_{BOX}} \tag{13}$$

Capacitance definitions:

$$C_{FOX} = \frac{\epsilon_{ox}}{TFOX} \tag{14}$$

$$C_{BOX} = \frac{\epsilon_{ox}}{TBOX} \tag{15}$$

$$C_{SOI} = \frac{\epsilon_{Si}}{TSOI} \tag{16}$$

### 2a. Charge Equations

$$Q_{dep,SOI} = -qN_{subs} \cdot TSOI = Q_{s,dep} + Q_{b,dep} \tag{17}$$

$$Q_{s,dep} = -\sqrt{\frac{2\epsilon_{Si} q N_{subs}}{\beta}} \left[\exp(-\beta\phi_s(y)) + \beta(\phi_s(y) - \phi_b^{\prime}(y)) - 1\right]^{1/2} \tag{18}$$

$$Q_{b,dep} = -\sqrt{\frac{2\epsilon_{Si} q N_{subs}}{\beta}} \left[\exp(-\beta\phi_b(y)) + \beta(\phi_b(y) - \phi_b^{\prime}(y)) - 1\right]^{1/2} \tag{19}$$

$$Q_i = -\left[\sqrt{Q_{s,dep}^2 + \frac{n_{p0}}{p_{p0}}\left(\exp(\beta(\phi_s - \phi_f)) - \exp(\beta(\phi_b^{\prime} - \phi_f))\right)} - Q_{s,dep}\right] \tag{20}$$

$$Q_b = -\left[\sqrt{Q_{b,dep}^2 + \frac{n_{p0}}{p_{p0}}\left(\exp(\beta(\phi_b - \phi_f)) - \exp(\beta(\phi_b^{\prime} - \phi_f))\right)} - Q_{b,dep}\right] \tag{21}$$

$$Q_{bulk} = -\sqrt{\frac{2\epsilon_{Si} q N_{subb}}{\beta}} \left[\exp(-\beta(\phi_{bulk}(y) - V_{es})) + \beta(\phi_{bulk}(y) - V_{es}) - 1 + \frac{n_{p0}}{p_{p0}}\left(\exp(\beta\phi_{bulk}(y)) - \exp(\beta V_{es})\right)\right]^{1/2} \tag{22}$$

Shorthand constants:

$$const0 = \sqrt{\frac{2\epsilon_{Si} q N_{subs}}{\beta}} \tag{23}$$

$$const0_{bulk} = \sqrt{\frac{2\epsilon_{Si} q N_{subb}}{\beta}} \tag{24}$$

$$\beta = \frac{q}{kT} \tag{25}$$

$$n_{p0} = \frac{n_i^2}{p_{p0}} \tag{26}$$

$$n_i = n_{i0} \cdot T^{3/2} \cdot \exp\left(-\beta\frac{E_g}{2q}\right) \tag{27}$$

### 2b. Surface Potential Definitions

$$\phi_{s0} := \phi_s(y=0) \tag{28}$$

$$\phi_{b0} := \phi_b(y=0) \tag{29}$$

$$\phi_{sL} := \phi_s(y=L_{eff}-\Delta L) \tag{30}$$

$$\phi_{bL} := \phi_b(y=L_{eff}-\Delta L) \tag{31}$$

$$\phi_f(L_{eff}-\Delta L) - \phi_f(0) = V_{ds,eff} \tag{32}$$

### 2c. Effective Drain Voltage

$$V_{ds,eff} = \frac{V_{ds}}{\left(1 + \left(\frac{V_{ds}}{V_{ds,sat}}\right)^\Delta\right)^{1/\Delta}} \tag{33}$$

$$\Delta = \frac{DDLTMAX \cdot T_1}{DDLTMAX + T_1} + DDLTICT \tag{34}$$

$$T_1 = DDLTSLP \cdot L_{gate} \cdot 10^6 \tag{35}$$

$$V_{ds,sat} = V_{G0} + \frac{q N_{subs} \epsilon_{Si}}{C_{FOX}^2}\left(1 - \sqrt{1 + \frac{2C_{FOX}^2}{\beta q N_{subs} \epsilon_{Si}}(\beta V_{G0} - 1)}\right) \tag{36}$$

### 2d. Charge Notation

$$Q_{i0} := Q_i(y=0),\quad Q_{b0} := Q_b(y=0) \tag{37,38}$$

$$Q_{iL} := Q_i(y=L_{eff}),\quad Q_{bL} := Q_b(y=L_{eff}) \tag{39,40}$$

Trapezoidal integration approximation:

$$\frac{1}{L_{eff}}\int_0^{L_{eff}} Q_x(y)\,dy = \frac{Q_x(y=0) + Q_x(y=L_{eff})}{2} \tag{43}$$

### 3. Drain Current

$$I_{ds} = I_{ds,f} + I_{ds,b} \tag{44}$$

Front-gate current:

$$I_{ds,f} = \frac{W_{eff} \cdot NF}{L_{eff} - \Delta L} \cdot \mu_f \cdot \frac{I_{dd,f}}{\beta} \tag{45}$$

$$I_{dd,f} = -\left[\beta \cdot \frac{(Q_{iL} + Q_{i0}) \cdot (\phi_{sL} - \phi_{s0})}{2} + Q_{iL} - Q_{i0}\right] \tag{46}$$

Back-gate current:

$$I_{ds,b} = \frac{W_{eff} \cdot NF}{L_{eff} - \Delta L} \cdot \mu_b \cdot \frac{I_{dd,b}}{\beta} \tag{47}$$

$$I_{dd,b} = -\left[\beta \cdot \frac{(Q_{bL} + Q_{b0}) \cdot (\phi_{bL} - \phi_{b0})}{2} + Q_{bL} - Q_{b0}\right] \tag{48}$$

### 4. Threshold Voltage Shift

$$\Delta V_{th} = \Delta V_{th,SC} + \Delta V_{th,R} + \Delta V_{th,P} + \Delta V_{th,SCR} + \Delta V_{th,W} + \Delta V_{th,sm} - \phi_{Spg} \tag{49}$$

#### 4.1 Short-Channel Effects

$$\Delta V_{th,SC} = \frac{\epsilon_{Si}}{C_{FOX}} W_d \frac{dE_y}{dy} \tag{50}$$

$W_d$ is fixed to TSOI. The lateral field gradient:

$$\frac{dE_y}{dy} = \frac{2(V_{BI} - 2\Phi_B^{\prime})}{(L_{gate} - PARL2)^2}\left(SC1 + SC2 \cdot V_{ds} + SC3 \cdot \frac{2\Phi_B - V_{es}}{L_{gate}} + SC5 \cdot V_{es}\right) \tag{51}$$

$$\Phi_B^{\prime} = \Phi_B + PTHROU \cdot (\Phi_B^{\prime\prime}(V_{gs}) - \Phi_B) \tag{52}$$

$$\Phi_B^{\prime\prime}(V_{gs}) = V_G + \frac{const0^2\beta}{C_{FOX}^2}\left(1 - \sqrt{1 + \frac{4\beta(V_G - V_{es}) - 4}{\left(\frac{\beta\cdot const0}{C_{FOX}}\right)^2}}\right) \tag{53}$$

$$V_G = V_{gs} - VFBC + \Delta V_{th,SCR} \tag{54}$$

SCE via BOX:

$$\Delta V_{th,SCR} = \frac{SCR1 \cdot TFOX(E_g + 2\Phi_B - SCR3 + SCR2 \cdot V_{ds})}{\left(\frac{L_{gate}}{2}\right) + PARL1} \tag{55}$$

#### 4.2 Reverse Short-Channel (Pocket Implantation)

$$\Delta V_{th,P} = (V_{th,R} - V_{th0})\frac{\epsilon_{Si}}{C_{FOX}} TSOI \frac{dE_{y,P}}{dy} \tag{56}$$

$$V_{th,R} = V_{FB} + 2\Phi_B + \frac{Q_{B0}}{C_{FOX}} + P_{tovr} \tag{57}$$

$$Q_{B0} = \sqrt{2q \cdot N_{subs} \cdot \epsilon_{Si} \cdot (2\Phi_B - V_{es})} \tag{58}$$

$$V_{th0} = V_{FB} + 2\Phi_{BC} + \frac{\sqrt{2qN_{subsp}\epsilon_{Si}(2\Phi_{BC} - V_{es})}}{C_{FOX}} \tag{59}$$

$$\frac{dE_{y,P}}{dy} = \frac{2(V_{BI} - 2\Phi_B)}{LP^2}\left(SCP1 + SCP2 \cdot V_{ds} + SCP3 \cdot \frac{2\Phi_B - V_{es}}{LP}\right) \tag{60}$$

$$P_{tovr} = \begin{cases} \frac{1}{\beta}\ln\frac{N_{subb0}}{N_{subsp}} & (L_{gate} \le 2 \cdot LP) \\ 0 & (L_{gate} > 2 \cdot LP) \end{cases} \tag{61}$$

$$N_{subp0} = 2 \cdot N_{subps} - \frac{(N_{subps} - N_{subsp}) \cdot L_{gate}}{LP} - N_{subsp} \tag{62}$$

$$\Phi_{BC} = \frac{2}{\beta}\ln\frac{N_{subs}}{n_i} \tag{63}$$

$$\Phi_B = \frac{2}{\beta}\ln\frac{N_{subsp}}{n_i} \tag{64}$$

$$N_{subs} = \begin{cases} \frac{N_{subsp}(L_{gate} - LP) + N_{subps} \cdot LP}{L_{gate}} & (L_{gate} > LP) \\ N_{subps} + \frac{(N_{subps} - N_{subsp})(LP - L_{gate})}{LP} & (L_{gate} \le LP) \end{cases} \tag{65}$$

#### 4.3 Lateral Inhomogeneity of NSUBB

$$N_{subb} = NSUBB \cdot \left(1 + \frac{NSUBBL}{(L_{gate} \cdot 10^6)^{NSUBBLP}}\right) \tag{66}$$

#### 4.4 Flat-Band Voltage Shift (Mechanical Stress)

$$V_{fb} = f(V_{fb1}, V_{fb2}, V_{fb3}) \tag{67}$$

$V_{fb1}$ is smoothly limited not to exceed $V_{fb2}$; the result is smoothly limited not to exceed $V_{fb3}$.

$$V_{fb1} = VFBC \cdot \left(1 + \frac{VFBCL1}{(L_{gate} \cdot 10^6)^{VFBCL1P}}\right) \tag{68}$$

$$V_{fb2} = VFBC \cdot \left(1 + \frac{VFBCL2}{(L_{gate} \cdot 10^6)^{VFBCL2P}}\right) \tag{69}$$

$$V_{fb3} = VFBC + VFBHAMP \cdot (L_{gate} \cdot 10^6) \tag{70}$$

### 5. Punchthrough

$$I_{punch} = I_{PUNCH,f} + I_{PUNCH,b}$$

Front:

$$I_{PUNCH,f} = \frac{W_{eff} \cdot NF}{L_{eff}} \cdot \frac{\mu}{\beta} \cdot (\phi_{sL} - \phi_{s0}) \cdot C_{FOX} \cdot \beta \cdot \frac{PTL}{(L_{gate} \cdot 10^6)^{PTLP}} \cdot (V_{bi} - \phi_{s0})^{PTP} \cdot \left(1 + PT2 \cdot V_{ds} + \frac{PT4 \cdot (\phi_{s0} - V_{es})}{(L_{gate} \cdot 10^6)^{PT4P}} + COND\right) \tag{71}$$

Back:

$$I_{PUNCH,b} = \frac{W_{eff} \cdot NF}{L_{eff}} \cdot \frac{\mu}{\beta} \cdot (\phi_{bL} - \phi_{b0}) \cdot C_{FOX} \cdot \beta \cdot \frac{PTL}{(L_{gate} \cdot 10^6)^{PTLP}} \cdot (V_{bi} - \phi_{b0})^{PTP} \cdot \left(1 + PT2 \cdot V_{ds} + \frac{PT4 \cdot (\phi_{b0} - V_{es})}{(L_{gate} \cdot 10^6)^{PT4P}} + COND\right) \tag{72}$$

where $V_{bi} = 1.1$ V.

High-field conductance term (front only):

$$COND = C_{FOX} \cdot \beta \cdot \frac{GDL}{(L_{gate} \cdot 10^6 + GDLD \cdot 10^6)^{GDLP}} \cdot V_{ds} \tag{73}$$

### 6. Poly-Si Gate Depletion

$$\phi_{Spg} = PGD1\left(1 + \frac{1}{L_{gate} \cdot 10^6}\right)^{PGD4} \exp\left(\frac{V_{gs} - PGD2}{1\text{V}}\right) \tag{74}$$

The function is smoothed so that $\phi_{Spg}$ does not exceed $\phi_{s0}$ for very large $V_{gs}$.

### 7. Quantum-Mechanical Effects

$$TFOX \rightarrow TFOX + \Delta TFOX \tag{75}$$

$$\Delta TFOX = \frac{QME1}{V_{gs} - V_{th}(TFOX) - QME2} + QME3 \tag{76}$$

### 8. Mobility Model

#### 8.1 Front Side Low-Field Mobility

$$\frac{1}{\mu_0} = \frac{1}{\mu_{CB}} + \frac{1}{\mu_{PH}} + \frac{1}{\mu_{SR}} \tag{77}$$

$$\mu_{CB} = MCoulomb0 + MCoulomb1 \cdot \frac{|Q_I|}{q \times 10^{11}} \tag{78}$$

$$\mu_{PH} = \frac{Muephonon}{E_{eff}^{MUEPH0}} \tag{79}$$

$$\mu_{SR} = \frac{MUESR1}{E_{eff}^{Muesurface}} \tag{80}$$

$$E_{eff} = \max(E_{eff},\, 3 \times 10^3) \tag{81}$$

$$E_{eff} = \begin{cases} E_{eff0} & (\text{CONEWMUB}=0) \\ E_{eff0} + \frac{\epsilon_{ox}}{\epsilon_{Si}} \cdot \frac{\phi_b - \phi_{bulk} - V_{es}}{TBOX} & (\text{CONEWMUB}=1) \end{cases} \tag{82}$$

$$E_{eff0} = \frac{1}{\epsilon_{Si}}(N_{dep} \cdot \overline{Q_{s,dep}} + N_{inv} \cdot QIB) \cdot \frac{1}{1 + P_{ds2} \cdot NINVD} \tag{83}$$

$$QIB = \overline{QI} - MUEqb \cdot Q_b(L) \tag{84}$$

$$N_{dep} = NDEP \cdot \left(1 + \frac{NDEPL}{(L_{gate} \cdot 10^6)^{NDEPLP}}\right) \tag{85}$$

$$N_{inv} = NINV \cdot \left(1 + \frac{NINVL}{(L_{gate} \cdot 10^6)^{NINVLP}}\right) \tag{86}$$

$$P_{ds2} = (\phi_{sL} - \phi_{s0})^{NINVDP} \tag{87}$$

$$\overline{Q_{s,dep}} = \frac{Q_{s,dep}(L) + Q_{s,dep}(0)}{2} \tag{88}$$

$$\overline{QI} = \frac{Q_i(L) + Q_i(0)}{2} \tag{89}$$

$$MUEqb = MUEQB \cdot \left(1 + \frac{MUEQBL}{(L_{gate} \cdot 10^6)^{MUEQBLP}}\right) \tag{90}$$

Phonon mobility channel-length dependence:

$$Muephonon = MUEPH1 \cdot \left(1 + \frac{MUEPHL}{(L_{gate} \cdot 10^6)^{MUEPLP}}\right) \tag{95}$$

Surface-roughness channel-length dependence:

$$Muesurface = MUESR0 \cdot \left(1 + \frac{MUESRL}{(L_{gate} \cdot 10^6)^{MUESLP}}\right) \tag{96}$$

Coulomb screening channel-length dependence:

$$MCoulomb0 = MUECB0 \cdot (L_{gate} \cdot 10^6)^{MUECB0LP} \cdot \left(1 + \frac{MUECB0L2}{(L_{gate} \cdot 10^6)^{MUECB0L2P}}\right) \tag{97}$$

$$MCoulomb1 = MUECB1 \cdot (L_{gate} \cdot 10^6)^{MUECB1LP} \cdot \left(1 + \frac{MUECB1L2}{(L_{gate} \cdot 10^6)^{MUECB1L2P}}\right) \tag{98}$$

#### 8.1a Front Side High-Field Mobility

$$\mu_f = \frac{\mu_0}{\left(1 + \left(\frac{\mu_0 E_y}{V_{max}}\right)^{BB}\right)^{1/BB}} \tag{99}$$

$$E_y = \sqrt{\left(\frac{I_{dd,f}}{\beta \cdot Q_i(0) \cdot L_{eff}}\right)^2 + \left(\frac{0.2 \cdot V_{max}}{\mu_0}\right)^2} \tag{100}$$

$$V_{max} = VMAX \cdot \left(1 + \frac{VOVER}{(L_{gate} \cdot 10^6)^{VOVERP}}\right) \cdot \left(1 + \frac{VOVERL}{(L_{gate} \cdot 10^6)^{VOVERLP}}\right) \tag{101}$$

#### 8.2 Back Side Low-Field Mobility

$$\frac{1}{\mu_0} = \frac{1}{\mu_{CB}} + \frac{1}{\mu_{PH}} + \frac{1}{\mu_{SR}} \tag{102}$$

$$\mu_{CB} = MCoulomb0b + MCoulomb1b \cdot \frac{|Q_B|}{q \times 10^{11}} \tag{103}$$

$$\mu_{PH} = \frac{Muephononb}{E_{eff}^{MUEPH0B}} \tag{104}$$

$$\mu_{SR} = \frac{MUESR1B}{E_{eff}^{Muesurfaceb}} \tag{105}$$

$$E_{eff} = \max(E_{eff},\, 3 \times 10^1) \tag{106}$$

$$E_{eff} = \begin{cases} E_{eff0} & (\text{CONEWMUB}=0) \\ \frac{\epsilon_{ox}}{\epsilon_{Si}} \cdot \frac{\phi_b - \phi_{bulk}}{TBOX} & (\text{CONEWMUB}=1) \end{cases} \tag{107}$$

$$E_{eff0} = \frac{1}{\epsilon_{Si}}(N_{dep} \cdot \overline{Q_{b,dep}} + N_{inv} \cdot QIB) \cdot \frac{1}{1 + P_{dsb2} \cdot NINVD} \tag{108}$$

$$QIB = \overline{QB} - MUEqb \cdot Q_i(L) \tag{109}$$

$$P_{dsb2} = (\phi_{bL} - \phi_{b0})^{NINVDP} \tag{110}$$

$$\overline{Q_{b,dep}} = \frac{Q_{b,dep}(L) + Q_{b,dep}(0)}{2} \tag{111}$$

$$\overline{QB} = \frac{Q_b(L) + Q_b(0)}{2} \tag{112}$$

$$\overline{QI} = \frac{Q_i(L) + Q_i(0)}{2} \tag{113}$$

$$MUEqb = MUEQBB \cdot \left(1 + \frac{MUEQBL}{(L_{gate} \cdot 10^6)^{MUEQBLP}}\right) \tag{114}$$

Back-side phonon channel-length dependence:

$$Muephononb = MUEPH1B \cdot \left(1 + \frac{MUEPHLB}{(L_{gate} \cdot 10^6)^{MUEPLPB}}\right) \tag{118}$$

Back-side surface-roughness channel-length dependence:

$$Muesurfaceb = MUESR0B \cdot \left(1 + \frac{MUESRLB}{(L_{gate} \cdot 10^6)^{MUESLPB}}\right) \tag{119}$$

Back-side Coulomb screening:

$$MCoulomb0b = MUECB0B \cdot (L_{gate} \cdot 10^6)^{MUECB0LPB} \cdot \left(1 + \frac{MUECB0L2B}{(L_{gate} \cdot 10^6)^{MUECB0L2PB}}\right) \tag{120}$$

$$MCoulomb1b = MUECB1B \cdot (L_{gate} \cdot 10^6)^{MUECB1LPB} \cdot \left(1 + \frac{MUECB1L2B}{(L_{gate} \cdot 10^6)^{MUECB1L2PB}}\right) \tag{121}$$

#### 8.2a Back Side High-Field Mobility

$$\mu_b = \frac{\mu_0}{\left(1 + \left(\frac{\mu_0 E_y}{V_{max}}\right)^{BB}\right)^{1/BB}} \tag{122}$$

$$E_y = \sqrt{\left(\frac{I_{dd,b}}{\beta \cdot Q_b(0) \cdot L_{eff}}\right)^2 + \left(\frac{0.2 \cdot V_{max}}{\mu_0}\right)^2} \tag{123}$$

### 9. Channel-Length Modulation

$$\phi_S(\Delta L) = (1 - CLM1) \cdot \phi_{sL} + CLM1 \cdot (\phi_{s0} + V_{ds}) \tag{124}$$

$$\Delta L = -\frac{1}{2}\frac{1}{L_{eff}}\left(\frac{I_{dd,f}}{\beta Q_i} \cdot 2z + \frac{qN_{subs}}{\epsilon_{Si}}(\phi_s(\Delta L) - \phi_{sL})z^2 + E_0 z^2\right)$$
$$+ \sqrt{\frac{1}{L_{eff}^2}\left(\frac{I_{dd,f}}{\beta Q_i} \cdot 2z + \frac{qN_{subs}}{\epsilon_{Si}}(\phi_s(\Delta L) - \phi_{sL})z^2 + E_0 z^2\right)^2 + 4\frac{qN_{sub}}{\epsilon_{Si}}(\phi_s(\Delta L) - \phi_{sL})z^2 + E_0 z^2} \tag{125}$$

where $E_0 = 10^5$ and:

$$z = \frac{\epsilon_{Si} W_d}{CLM2 \cdot Q_b + CLM3 \cdot Q_i} \tag{126}$$

$$CLM2 = \begin{cases} \frac{5.0 \times 10^9}{TSOI \cdot NSUBS} & (\text{default}) \\ CLM2 & (\text{if given}) \end{cases} \tag{127}$$

Pocket-implant CLM enhancement:

$$\Delta L \leftarrow \Delta L \cdot \left(1 + CLM6 \cdot (L_{gate} \cdot 10^6)^{CLM5}\right) \tag{128}$$

### 10. Narrow-Channel Effects

#### 10.1 Threshold Voltage Modification

$$\Delta V_{th,W} = \left(\frac{1}{C_{FOX}} - \frac{1}{C_{FOX} + 2C_{ef}/(L_{eff} W_{eff})}\right) \cdot Q_{dep,SOI} + \frac{WVTH0}{W_{gate} \cdot 10^6} \tag{129}$$

$$C_{ef} = \frac{2\epsilon_{ox}}{\pi} L_{eff} \ln\left(\frac{2 \cdot T_{oxiso}}{TFOX}\right) \tag{130}$$

$$C_{ef} = \frac{WFC}{2} L_{eff} \tag{131}$$

Pocket concentration width dependence:

$$N_{subpp} = NSUBP \cdot \left(1 + \frac{NSUBP0}{(W_{gate} \cdot 10^6)^{NSUBWP}}\right) \tag{132}$$

SOI impurity width dependence:

$$N_{subsp} = \min\left(NSUBSMAX,\, NSUBS \cdot \left(1 + \frac{NSUBSW}{(W_{gate} \cdot 10^6)^{NSUBSWP}}\right)\right) \tag{133}$$

Substrate impurity width dependence:

$$N_{subbl} = NSUBB \cdot \left(1 + \frac{NSUBBW}{(W_{gate} \cdot 10^6)^{NSUBBWP}}\right) \tag{134}$$

#### 10.2 Mobility Modification (Mechanical Stress)

Front phonon:

$$Muephonon \leftarrow Muephonon \cdot \left(1 + \frac{MUEPHW}{(W_{gate} \cdot 10^6)^{MUEPWP}}\right) \tag{135}$$

Back phonon:

$$Muephononb \leftarrow Muephononb \cdot \left(1 + \frac{MUEPHWB}{(W_{gate} \cdot 10^6)^{MUEPWPB}}\right) \tag{136}$$

Front surface roughness:

$$Muesurface \leftarrow Muesurface \cdot \left(1 + \frac{MUESRW}{(W_{gate} \cdot 10^6)^{MUESWP}}\right) \tag{137}$$

Back surface roughness:

$$Muesurfaceb \leftarrow Muesurfaceb \cdot \left(1 + \frac{MUESRWB}{(W_{gate} \cdot 10^6)^{MUESWPB}}\right) \tag{138}$$

Velocity overshoot W-dependence:

$$V_{max} \leftarrow V_{max} \cdot \left(1 + \frac{VOVERW}{wl^{VOVERWP}}\right) \tag{139}$$

#### 10.3 STI Leakage (Hump in Ids)

$$\phi_{S,STI} = V_{gs,STI}^{\prime} + \frac{\epsilon_{Si} Q_{N,STI}}{C_{FOX}^{\prime 2}}\left(1 - \sqrt{1 + \frac{2C_{FOX}^{\prime 2}}{\epsilon_{Si} Q_{N,STI}}\left(V_{gs,STI}^{\prime} - V_{bs} - \frac{1}{\beta}\right)}\right) \tag{140}$$

$$Q_{N,STI} = q \cdot NSTI \tag{141}$$

$$V_{gs,STI}^{\prime} = V_{gs} - VFBC + V_{thSTI} + \Delta V_{th,SCSTI} \tag{142}$$

$$V_{thSTI} = VTHSTI - VDSTI \cdot V_{ds} \tag{143}$$

$$\Delta V_{th,SCSTI} = \frac{\epsilon_{Si}}{C_{FOX}} W_{d,STI} \frac{dE_y}{dy} \tag{144}$$

$$W_{d,STI} = \sqrt{\frac{2\epsilon_{Si}(2\Phi_{B,STI} - V_{bs})}{q \cdot NSTI}} \tag{145}$$

$$\frac{dE_y}{dy} = \frac{2(V_{BI} - 2\Phi_{B,STI})}{(L_{gate,sm} - PARL2)^2}(SCSTI1 + SCSTI2 \cdot V_{ds}) \tag{146}$$

$$L_{gate,sm} = L_{gate} + \frac{WL1}{wl^{WL1P}} \tag{147}$$

$$wl = (W_{gate} \cdot 10^6) \cdot (L_{gate} \cdot 10^6) \tag{148}$$

STI leakage current:

$$I_{ds,STI} = 2 \frac{WSTI}{L_{eff} - \Delta L} \mu \frac{Q_{i,STI}}{\beta} [1 - \exp(-\beta V_{ds})] \tag{149}$$

NSTI and WSTI geometry dependence:

$$NSTI \leftarrow NSTI\left(1 + \frac{NSTIL}{(L_{gate,sm} \cdot 10^6)^{NSTILP}}\right)\left(1 + \frac{NSTIW}{(W_{gate,sm} \cdot 10^6)^{NSTIWP}}\right) \tag{150}$$

$$WSTI \leftarrow WSTI\left(1 + \frac{WSTIL}{(L_{gate,sm} \cdot 10^6)^{WSTILP}}\right)\left(1 + \frac{WSTIW}{(W_{gate,sm} \cdot 10^6)^{WSTIWP}}\right) \tag{151}$$

$$W_{gate,sm} = W_{gate} + \frac{WL1}{wl^{WL1P}} \tag{152}$$

$$W_{STI,mod} = WSTI \cdot RATWSTI \tag{153}$$

#### 10.4 Small Geometry

$$\Delta V_{th,sm} = \frac{WL2}{wl^{WL2P}} \tag{154}$$

$$wl = (W_{gate} \cdot 10^6) \cdot (L_{gate} \cdot 10^6) \tag{155}$$

Front phonon small-geometry:

$$Muephonon \leftarrow Muephonon \cdot \left(1 + \frac{MUEPHS}{wl^{MUEPSP}}\right) \tag{156}$$

Back phonon small-geometry:

$$Muephononb \leftarrow Muephononb \cdot \left(1 + \frac{MUEPHSB}{wl^{MUEPSPB}}\right) \tag{157}$$

Velocity small-geometry:

$$V_{max} \leftarrow V_{max} \cdot \left(1 + \frac{VOVERS}{wl^{VOVERSP}}\right) \tag{158}$$

### 11. Well-Proximity Effect

$$NSUBS \leftarrow NSUBS + NSUBSWPE \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC) \tag{159}$$

$$NSUBP \leftarrow NSUBP + NSUBPWPE \cdot (SCA + WEB \cdot SCB + WEC \cdot SCC) \tag{160}$$

### 12. Source/Drain Diffusion Length (STI)

Channel concentration modifier:

$$N_{substi} = \frac{1 + T_1 \cdot T_2}{1 + T_1 \cdot T_3} \tag{161}$$

$$T_1 = \frac{1}{1 + NSUBSSTI2},\quad T_2 = \frac{NSUBSSTI1}{Lod_{half}^{NSUBSSTI3}},\quad T_3 = \frac{NSUBSSTI1}{Lod_{half\_ref}^{NSUBSSTI3}} \tag{162-164}$$

$$N_{subs} \leftarrow N_{subs} \cdot N_{substi} \tag{165}$$

Pocket concentration modifier:

$$T_{substi} = \frac{1 + T_1 \cdot T_2}{1 + T_1 \cdot T_3} \tag{166}$$

$$T_1 = \frac{1}{1 + NSUBPSTI2},\quad T_2 = \frac{NSUBPSTI1}{Lod_{half}^{NSUBPSTI3}},\quad T_3 = \frac{NSUBPSTI1}{Lod_{half\_ref}^{NSUBPSTI3}} \tag{167-169}$$

$$N_{subps} = \begin{cases} N_{subpp} \cdot T_{substi} & (Lod_{half} > 0) \\ N_{subpp} & (Lod_{half} \le 0) \end{cases} \tag{170}$$

Mobility modifier:

$$Muesti = \frac{1 + T_1 \cdot T_2}{1 + T_1 \cdot T_3} \tag{171}$$

$$T_1 = \frac{1}{1 + MUESTI2},\quad T_2 = \frac{MUESTI1}{Lod_{half}^{MUESTI3}},\quad T_3 = \frac{MUESTI1}{Lod_{half\_eff}^{MUESTI3}} \tag{172}$$

$$Muephonon \leftarrow Muephonon \cdot Muesti \tag{173}$$

### 13. Temperature Dependence

$$T = TEMP + DTEMP \tag{174}$$

(or $T = TEMP$ if TEMP is an instance parameter) (175)

Bandgap:

$$E_g = E_{g,TNOM} - BGTMP1 \cdot (T - TNOM) - BGTMP2 \cdot (T^2 - TNOM^2) \tag{176}$$

$$E_{g,TNOM} = EG0 - 90.25 \times 10^{-6} \cdot TNOM - 1.0 \times 10^{-7} \cdot TNOM^2 \tag{177}$$

Intrinsic carrier concentration:

$$n_i = n_{i0} \cdot T^{3/2} \cdot \exp\left(-\beta\frac{E_g}{2q}\right) \tag{178}$$

Phonon mobility temperature dependence:

$$\mu_{PH} = \frac{Muephonon}{(T/TNOM)^{M_{tmp}} \cdot E_{eff}^{MUEPH0}} \tag{179}$$

$$M_{tmp} = MUETMP \cdot \left(1 + \frac{MUETMPL}{(L_{gate} \cdot 10^6)^{MUETMPLP}}\right) + MUETMP1 \cdot (T/TNOM)^2 \tag{180}$$

Saturation velocity temperature dependence:

$$V_{max}(T) = \frac{V_{max}}{1.8 + 0.4(T/TNOM) + 0.1(T/TNOM)^2 - V_{tmp} \cdot (1 - T/TNOM)} \tag{181}$$

$$V_{tmp} = VTMP \cdot \left(1 + \frac{VTMPL}{(L_{gate} \cdot 10^6)^{VTMPLP}}\right) \tag{182}$$

GIDL temperature dependence:

$$IGIDL(T) = \frac{IGIDL}{1.0 - \exp\left(\frac{-L_{eff}}{GIDLBPL1 \cdot (T/TNOM)^{GIDLBPLT}}\right)} \tag{183}$$

Drift mobility temperature:

$$\mu_{drift0,temp} = \frac{RDRMUED}{(T/TNOM)^{RDRMUETMP}} \tag{184}$$

$$\mu_{source0,temp} = \frac{RDRMUES}{(T/TNOM)^{RDRMUETMP}} \tag{185}$$

Drift velocity temperature:

$$V_{max\_drift,temp} = \frac{RDRVMAXD}{1.8 + 0.4(T/TNOM) + 0.1(T/TNOM)^2 - RDRVTMP \cdot (1 - T/TNOM)} \tag{187}$$

$$V_{max\_source,temp} = \frac{RDRVMAXS}{1.8 + 0.4(T/TNOM) + 0.1(T/TNOM)^2 - RDRVTMP \cdot (1 - T/TNOM)} \tag{188}$$

Drift resistance BB temperature:

$$R_{drbb,temp} = RDRBBD + RDRBBTMP(T - TNOM) \tag{189}$$

$$R_{srbb,temp} = RDRBBS + RDRBBTMP(T - TNOM) \tag{190}$$

### 14. Resistances

#### 14.1 Drain-Side Resistance

$$R_{drift} = \frac{V_{ddp}}{I_{ddp}} + RSH \cdot NRD \tag{191}$$

$$I_{ddp} = W_{eff} \cdot NF \cdot X_{ov} \cdot q \cdot NOVER \cdot \mu_{drift} \cdot \frac{V_{ddp}}{LDRIFT} \tag{192}$$

$$\mu_{drift} = \frac{\mu_{drift0}}{\left(1 + \left(\frac{\mu_{drift0}}{V_{max\_drift}} \cdot \frac{V_{ddp}}{LDRIFT}\right)^{R_{drbb,temp}}\right)^{1/R_{drbb,temp}}} \tag{193}$$

$$\mu_{drift0} = \mu_{drift0,temp}\left(1 + \frac{RDRMUEL}{(L_{gate} \cdot 10^6)^{RDRMUELP}}\right) \tag{194}$$

$$V_{max\_drift} = V_{max\_drift,temp}\left(1 + \frac{RDRVMAXL}{(L_{gate} \cdot 10^6)^{RDRVMAXLP}}\right)\left(1 + \frac{RDRVMAXW}{(W_{gate} \cdot 10^6)^{RDRVMAXWP}}\right) \tag{195}$$

$$X_{ov} = \sqrt{XLD^2 + RDRDJUNC^2} \tag{196}$$

#### 14.2 Source-Side Resistance

$$R_{source} = \frac{V_{ssp}}{I_{ssp}} + RSH \cdot NRS \tag{197}$$

$$I_{ssp} = W_{eff} \cdot NF \cdot X_{ov} \cdot q \cdot NOVERS \cdot \mu_{source} \cdot \frac{V_{ssp}}{LDRIFTS} \tag{198}$$

$$\mu_{source} = \frac{\mu_{source0}}{\left(1 + \left(\frac{\mu_{source0}}{V_{max\_source}} \cdot \frac{V_{ssp}}{LDRIFTS}\right)^{R_{srbb,temp}}\right)^{1/R_{srbb,temp}}} \tag{199}$$

$$\mu_{source0} = \mu_{source0,temp}\left(1 + \frac{RDRMUEL}{(L_{gate} \cdot 10^6)^{RDRMUELP}}\right) \tag{200}$$

$$V_{max\_source} = V_{max\_source,temp}\left(1 + \frac{RDRVMAXL}{(L_{gate} \cdot 10^6)^{RDRVMAXLP}}\right)\left(1 + \frac{RDRVMAXW}{(W_{gate} \cdot 10^6)^{RDRVMAXWP}}\right) \tag{201}$$

$$X_{ov} = \sqrt{XLD^2 + RDRDJUNC^2} \tag{202}$$

#### 14.3 Gate Resistance

$$R_g = \frac{RSHG \cdot \left(XGW + \frac{W_{eff}}{3 \cdot NGCON}\right)}{NGCON \cdot (L_{drawn} - XGL) \cdot NF} \tag{203}$$

### 15. Capacitances

#### 15.1 Intrinsic Capacitances / Lateral Field Charge

$$Q_y = \epsilon_{Si} W_{effc} \cdot NF \cdot W_d \left(\frac{\phi_{s0} + V_{ds} - \phi_s(\Delta L)}{XQY}\right) + \frac{XQY1 \cdot W_{effc} \cdot 10^6 \cdot NF}{(L_{gate} \cdot 10^6)^{XQY2}} V_{es} \tag{204}$$

#### 15.2 Overlap Capacitances

$$\frac{Q_{god}}{W_{effc} \cdot NF \cdot C_{FOX}} = \int_0^{LOVER} (V_{gs} - \phi_s)\,dy \tag{205}$$

$$\frac{Q_{gos}}{W_{effc} \cdot NF \cdot C_{FOX}} = \int_0^{LOVERS} (V_{gs} - \phi_s)\,dy \tag{206}$$

Constant overlap capacitances (COOVLP=0):

$$C_{gso} = C_{FOX} \cdot LOVER \cdot W_{effc} \tag{207}$$

$$C_{gdo} = C_{FOX} \cdot LOVER \cdot W_{effc} \tag{208}$$

User-specified overlap:

$$C_{ov} = -\frac{\epsilon_{ox}}{TFOX} \cdot LOVER \cdot W_{effc} \cdot NF \tag{209}$$

Gate-bulk overlap:

$$C_{gbo\_loc} = -CGBO \cdot L_{gate} \tag{210}$$

Bias-dependent overlap (COOVLP=1):

$$Q_{over} = W_{effc} \cdot NF \cdot LOVER \cdot C_{FOX}(V_{gs} - V_{bs} - VFBOVER - \phi_s) \tag{211}$$

#### 15.3 Extrinsic (Fringing) Capacitance

$$C_{fringe} = \frac{\epsilon_{ox}}{\pi/2} W_{gate} \cdot NF \cdot \ln\left(1 + \frac{TPOLY}{TFOX}\right) \tag{212}$$

### 16. Parasitic Currents

#### 16.1 Body Current (Impact Ionization)

$$I_{sub} = \frac{C_1}{C_2}(\phi(y) - \phi(0)) I_{ds,SUB} \exp\left(\frac{-\lambda C_2}{\phi(y) - \phi(0)}\right) \tag{213}$$

$$\lambda^2 = \frac{\epsilon_{Si} X_j TFOX}{\epsilon_{ox}} \tag{214}$$

$$I_{ds,SUB} = \frac{W_{eff}}{L_{eff}} \mu_{sub} \frac{Q_{i,SUB}}{\beta}[1 - \exp(-\beta V_{ds})] \tag{215}$$

Analytical surface potential for Isub:

$$\phi_{STI} = \phi_{sb,STI} - 0.5 \cdot \phi_{sab,STI} + \sqrt{\phi_{sab,STI}^2 + 4 \cdot SUBDLT \cdot \phi_{sb,STI}} \tag{216}$$

$$\phi_{sab,STI} = \phi_{sb,STI} - \phi_{sa,STI} - SUBDLT \tag{217}$$

$$\phi_{sb,STI} = \frac{\ln(ASTI \cdot V_{gp,SUB}^{\prime})}{\beta + \frac{2}{V_{gp,SUB}^{\prime}}} \tag{218}$$

$$ASTI = \frac{\beta \cdot C_{FOX}^2 \cdot N_{subs}}{2 \cdot q \cdot \epsilon_{Si} \cdot n_i^2 \cdot N_{subs}} \tag{219}$$

$$\phi_{sa,STI} = V_{gp,SUB}^{\prime} + \frac{\epsilon_{Si} qN_{subs}}{C_{FOX}^2}\left(1 - \sqrt{1 + \frac{2C_{FOX}^2}{\epsilon_{Si} qN_{subs}}\left(V_{gp,SUB}^{\prime} - \frac{1}{\beta}\right)}\right) \tag{220}$$

$$V_{gp,SUB}^{\prime} = V_{gs} - VFBSUBI - \Delta V_{th} - \phi_{Spg} \tag{221}$$

$$VFBSUBI = VFBSUB\left(1 + \frac{VFBSUBL}{L_{gate}^{VFBSUBLP}}\right) \tag{222}$$

Modified substrate current:

$$I_{sub} = X_{sub1} \cdot Psisubsat \cdot I_{ds,SUB} \cdot \exp\left(\frac{-X_{sub2}}{Psisubsat}\right) \tag{223}$$

$$X_{sub1} = SUB1 \cdot \left(1 + \frac{SUB1L}{L_{gate}^{SUB1LP}}\right) \tag{224}$$

$$X_{sub2} = SUB2 \cdot \left(1 + \frac{SUB2L}{L_{gate}}\right) \tag{225}$$

$$Psisubsat = SVDS \cdot V_{ds} + \phi_{STI} - \frac{L_{gate}}{L_{gate} + SLG}\left(1 + \frac{SVGSW}{W_{gate}^{SVGSWP}}\right) Psislsat \tag{226}$$

$$Psislsat = V_{gp,SUB}^{\prime} \cdot SVGSI + \frac{q \cdot \epsilon_{Si} \cdot N_{subs}}{C_{FOX}^2}\left(1 - \sqrt{1 + \frac{2C_{FOX}^2}{q \cdot \epsilon_{Si} \cdot N_{subs}}\left(V_{gp,SUB}^{\prime} - \frac{1}{\beta}\right)}\right) - X_{vbs} \cdot V_{es} \tag{227}$$

$$SVGSI = SVGS\left(1 + \frac{SVGSL}{L_{gate}^{SVGSLP}}\right) \tag{228}$$

$$X_{vbs} = SVBS \cdot \left(1 + \frac{SVBSL}{L_{gate}^{SVBSLP}}\right) \tag{229}$$

Impact-ionization body potential change current:

$$I_{ds,BPC} = \frac{2}{3}\sqrt{\frac{2\epsilon_{Si} qN_{subs}}{\beta}} \left[(\beta(\phi_{sL}-V_{es})-1)^{3/2}\frac{\beta\Delta V_{body}}{2(\beta(\phi_{sL}-V_{es})-1)} - (\beta(\phi_{s0}-V_{es})-1)^{3/2}\frac{\beta\Delta V_{body}}{2(\beta(\phi_{s0}-V_{es})-1)}\right]$$
$$- \sqrt{\frac{2\epsilon_{Si} qN_{subs}}{\beta}} \left[(\beta(\phi_{sL}-V_{es})-1)^{1/2}\frac{\beta\Delta V_{body}}{2(\beta(\phi_{sL}-V_{es})-1)} - (\beta(\phi_{s0}-V_{es})-1)^{1/2}\frac{\beta\Delta V_{body}}{2(\beta(\phi_{s0}-V_{es})-1)}\right] \tag{230}$$

$$\Delta V_{body} = IBPC1 \cdot (1 + IBPC2 \cdot \Delta V_{th}) \cdot I_{sub} \tag{231}$$

#### 16.2 Front Gate Tunneling Current

Gate-to-channel:

$$I_{gate} = q \cdot GLEAK1 \cdot \frac{E^2}{E_{gp}^2} \cdot \exp\left(-\frac{E_{gp}^{3/2} \cdot GLEAK2}{E}\right) \cdot \left(\frac{Q_i}{const0}\right)^{GLEAK9} \cdot W_{eff} \cdot NF \cdot L_{eff} \cdot \frac{GLEAK6}{GLEAK6 + V_{ds}} \cdot \frac{GLEAK7}{GLEAK7 + W_{eff} \cdot NF \cdot L_{eff}} \tag{232}$$

$$E = \left(1 + \frac{E_y}{GLEAK5}\right) \cdot \left(1 - \frac{1}{1 + V_{gs}^2}\right) \cdot \frac{VG}{TFOX} \tag{233}$$

$$VG = V_{gs} - GLEAK8 \cdot V_{fb} + \frac{GLEAK4 \cdot \Delta V_{th} - GLEAK10 \cdot V_{es}}{L_{eff}} - GLEAK3 \cdot \phi_s(\Delta L) \tag{234}$$

Gate current partitioning:

$$I_{gate} = I_{gate,s} + I_{gate,d} \tag{235}$$

$$I_{gate,s} = (1 - Partition) \cdot I_{gate} \tag{236}$$

$$I_{gate,d} = Partition \cdot I_{gate} \tag{237}$$

$$Partition = \frac{1}{I_{gate}} \int_0^{L_{eff}} \frac{y}{L_{eff}} I_{gate}(y)\,dy \tag{238}$$

Gate-to-bulk (accumulation):

$$I_{gb1} = GLKB1 \cdot E_{gb}^{GLKB5} \cdot \exp\left(\frac{-GLKB2}{E_{gb}} - GLKB6\right) \cdot W_{eff} \cdot NF \cdot f1(LG) \tag{239}$$

$$E_{gb} = -\frac{V_{gs} - GLKB4 \cdot V_{es} - V_{fb} - GLKB3}{TFOX} \tag{240}$$

$$f1(LG) = L_{gate} \cdot 10^6 + GLKB7 \tag{241}$$

clamped: $f1(LG) > GLKB8$

$$I_{gb2} = GLKB21 \cdot E_{gb}^{GLKB25} \cdot \exp\left(\frac{-GLKB22}{E_{gb}} - GLKB26\right) \cdot W_{eff} \cdot NF \cdot f2(LG) \tag{242}$$

$$E_{gb} = -\frac{V_{gs} - GLKB24 \cdot V_{es} - V_{fb} - GLKB23}{TFOX} \tag{243}$$

$$f2(LG) = L_{gate} \cdot 10^6 + GLKB27 \tag{244}$$

clamped: $f2(LG) > GLKB28$

Gate-to-source/drain overlap:

$$I_{gs} = \text{sign} \cdot GLKSD1 \cdot E_{gs}^2 \cdot \exp(TFOX(-GLKSD2 \cdot V_{gs} + GLKSD3)) \cdot W_{eff} \cdot NF \cdot f1(LG) \tag{245}$$

$$f1(LG) = (L_{gate} \cdot 10^6)^{GLKSD4} \tag{246}$$

$$E_{gs} = \frac{GLKSD5 \cdot V_{gs}}{TFOX} \tag{247}$$

$$I_{gd} = \text{sign} \cdot GLKSD1 \cdot E_{gd}^2 \cdot \exp(TFOX(GLKSD2 \cdot (-V_{gs} + V_{ds}) + GLKSD3)) \cdot W_{eff} \cdot NF \cdot f2(LG) \tag{248}$$

$$f2(LG) = (L_{gate} \cdot 10^6)^{GLKSD4} \tag{249}$$

$$E_{gd} = \frac{GLKSD5 \cdot (V_{gs} - V_{ds})}{TFOX} \tag{250}$$

sign = +1 for E < 0, sign = -1 for E >= 0

#### 16.3 GIDL

$$I_{GIDL} = q \cdot GIDL1 \cdot \frac{E^2}{E_{g2}} \cdot \exp\left(-GIDL2 \cdot \frac{E_{g2}^{3/2}}{E}\right) \cdot W_{eff} \cdot NF \cdot T_1 \tag{251}$$

$$T_1 = \frac{1}{1.0 + \exp(-\beta \cdot V_{ds})} \tag{252}$$

$$E = \frac{GIDL3 \cdot (V_{ds} + GIDL4) - VG0}{TFOXGIDL} \tag{253}$$

$$VG0 = V_{gs} + (\Delta V_{th,SC} + \Delta V_{th,P}) \cdot GIDL5 \tag{254}$$

#### 16.4 Valence Band Electron Tunneling

$$I_{evb} = EVB1 \cdot q \cdot \left(\frac{\phi_b}{VFOX}\right)\left(\frac{2\phi_b}{VFOX} - 1\right) \cdot EFOX^2 \cdot \exp\left(-\frac{EVB2\left(1 - \left(1 - \frac{VFOX}{\phi_b}\right)^{3/2}\right)}{EFOX}\right) \cdot W_{eff} \cdot NF \cdot L_{eff} \tag{255}$$

where $\phi_b = 4.12$ eV (barrier height for holes).

$$EFOX = -\frac{FVBS \cdot V_{es} - VFOX + \Delta V_{th,SC} + \Delta V_{th,P} + E_g + EVB3}{TFOX} \tag{256}$$

$$VFOX = VG0 - \phi_s \tag{257}$$

### 17. Floating-Body Effect

$$Q_h = \left[\exp(-\beta(\phi_{s0} - \Delta V_{sb})) + \beta(\phi_{s0} - \Delta V_{sb}) - 1\right]^{1/2} - \left[\exp(-\beta\phi_{s0}) + \beta\phi_{s0} - 1\right]^{1/2} \tag{258}$$

$$\Delta V_{sb} = QHE1 \cdot \frac{1}{\beta} \log\left(1 + \frac{(I_{sub} + I_{evb})L_p L_n}{q \cdot TSOI \cdot W_{eff} \cdot e^{-\beta \cdot QHE2}(D_n N_d L_p + D_p N_d L_n)}\right) \tag{259}$$

$$L_n = \sqrt{D_n \cdot 10^{-7}},\quad L_p = \sqrt{D_p \cdot 10^{-7}} \tag{260,261}$$

$$N_d = 10^{20}\text{ cm}^{-3},\quad D_n = 36\text{ cm}^2/\text{s},\quad D_p = 13\text{ cm}^2/\text{s} \tag{262-264}$$

### 18. History Effect

$$\tau_h = R_{sb} \cdot C_{FOX} \tag{265}$$

$$R_{sb} = \frac{HIST1}{I_{sub} + HIST2} \tag{266}$$

$$Q_h(t) = Q_h(t - \Delta t) + \frac{\Delta t}{\tau_h + \Delta t} \cdot (Q_{h0} - Q_h(t - \Delta t)) \tag{267}$$

### 19. Self-Heating Effect

C-R thermal network with thermal resistance RTH0 and capacitance CTH0. The temperature increment $\Delta T_{emp}$ is solved from:

$$P_{diss} = I_{ds} \cdot V_{ds} = \frac{\Delta T_{emp}}{RTH0} + CTH0 \cdot \frac{d(\Delta T_{emp})}{dt}$$

Activated when COSELFHEAT=1 and RTH0 != 0.

### 20. Noise Models

#### 20.1 1/f Noise

$$S_{Ids} = \frac{I_{ds}^2 \cdot NFTRP}{\beta f (L_{eff} - \Delta L) W_{eff} \cdot NF} \left[\frac{1}{(N_0 + N^*)(N_L + N^*)} + \frac{2\mu_f E_y NFALP}{N_L - N_0} \ln\frac{N_L + N^*}{N_0 + N^*} + (\mu_f E_y NFALP)^2\right] \tag{268}$$

$$N^* = \frac{C_{FOX} + C_{dep} + CIT}{q\beta} \tag{269}$$

$$N_{flick} = S_{Ids} \cdot f \tag{270}$$

#### 20.2 Thermal Noise

$$S_{id} = 4kT \frac{W_{eff} \cdot NF \cdot C_{FOX} V_{gvt}}{L_{eff} - \Delta L} \cdot \frac{\mu_f(1 + 3\eta + 6\eta^2)\mu_d^2 + (3 + 4\eta + 3\eta^2)\mu_d\mu_f + (6 + 3\eta + \eta^2)\mu_f}{15(1 + \eta)\mu_{av}^2} \tag{271}$$

$$\mu_d = \left(1.0 + \left(\frac{\mu_0 E_{yd}}{V_{max,therm}}\right)^{BB}\right)^{1/BB} \tag{272}$$

$$\mu_{av} = \frac{\mu_f + \mu_d}{2.0} \tag{273}$$

$$\eta = 1 - \frac{(\phi_{sL} - \phi_{s0}) + \chi(\phi_{sL} - \phi_{s0})}{V_{gvt}} \tag{274}$$

$$\chi = \frac{const0^2}{C_{FOX}} \left[\frac{2}{3\beta} \cdot \frac{(\beta(\phi_{sL} - V_{es}) - 1)^{3/2} - (\beta(\phi_{s0} - V_{es}) - 1)^{3/2}}{\phi_{sL} - \phi_{s0}} - \sqrt{\beta(\phi_{s0} - V_{es}) - 1}\right] \tag{275}$$

$$N_{thrml} = \frac{S_{id}}{4kT} \tag{276}$$

#### 20.3 Induced Gate Noise

$$N_{igate} = \frac{S_{igate}}{f^2} \tag{277}$$

No additional model parameters.

#### 20.4 Coupling Noise

$$N_{cross} = \frac{S_{igid}}{\sqrt{S_{igate} \cdot S_{id}}} \tag{278}$$

No additional model parameters.

### 21. Non-Quasi-Static (NQS) Model

#### 21.1 Carrier Formation

$$q(t_i) = \frac{q(t_{i-1}) + \frac{\Delta t}{\tau}Q(t_i)}{1 + \frac{\Delta t}{\tau}} \tag{279}$$

#### 21.2 Delay Mechanisms

$$\tau_{diff} = DLY1 \tag{280}$$

$$\tau_{cond} = DLY2 \cdot \frac{Q_i}{I_{ds}} \tag{281}$$

$$\frac{1}{\tau} = \frac{1}{\tau_{diff}} + \frac{1}{\tau_{cond}} \tag{282}$$

$$\tau_B = DLY3 \cdot C_{FOX} \tag{283}$$

#### 21.4 AC Analysis

$$\hat{q}_a(\omega) = \left(\frac{1}{1 + (\tau\omega)^2} - i\frac{\tau\omega}{1 + (\tau\omega)^2}\right) \hat{Q}_a(\omega) \tag{284}$$

NQS capacitances:

$$C_{ab} = \frac{\partial q_a}{\partial V_b} = -\frac{2(\tau\omega)^2}{(1 + (\tau\omega)^2)^2}\frac{1}{\tau}\frac{\partial\tau}{\partial V_b} Q_{a,QS} + \frac{1}{1 + (\tau\omega)^2} C_{ab,QS} - i\left(\frac{\tau\omega(1 - (\tau\omega)^2)}{(1 + (\tau\omega)^2)^2}\frac{1}{\tau}\frac{\partial\tau}{\partial V_b} Q_{a,QS} + \frac{\tau\omega}{1 + (\tau\omega)^2} C_{ab,QS}\right) \tag{285}$$

NQS y-parameter:

$$y_{ab} = \frac{i\omega}{1 + (\tau\omega)^2}\left(C_{ab,QS} + (\tau\omega)^2 A_{ab}(\omega) - i[\tau\omega B_{ab}(\omega) + \tau\omega C_{ab,QS}]\right) \tag{286}$$

$$A_{ab} = \frac{1}{\tau}\frac{-2}{1 + (\tau\omega)^2}\frac{\partial\tau}{\partial V_b} Q_{a,QS} \tag{287}$$

$$B_{ab} = \frac{1}{\tau}\frac{1 - (\tau\omega)^2}{1 + (\tau\omega)^2}\frac{\partial\tau}{\partial V_b} Q_{a,QS} \tag{288}$$

Example ($y_{gg}$):

$$y_{gg} = \frac{i\omega}{1 + (\tau\omega)^2}\left(C_{gg,QS} + (\tau\omega)^2 A_{gg}(\omega) - i[\tau\omega B_{gg}(\omega) + \tau\omega C_{gg,QS}]\right) \tag{289}$$

### Disabling Model Effects

| Effect | Parameter Settings |
|--------|-------------------|
| Short-channel effect | SC1 = SC2 = SC3 = 0 |
| Reverse-short-channel effect | LP = 0 |
| Quantum-mechanical effect | QME1 = QME3 = 0 |
| Channel-length modulation | CLM1 = CLM2 = CLM3 = 0 |
| Narrow-channel effect | WFC = MUEPHW = 0 |
| Small-size effect | WL2 = 0 |
