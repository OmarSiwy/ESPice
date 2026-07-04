# HiSIM-HV 2.4.4 -- Parameter & Equation Reference

> High-voltage LDMOS MOSFET (Hiroshima-university STARC IGFET Model for High Voltage)
> Copyright Hiroshima University, Oct 2024. CC-BY 4.0.

## Model Topology

HiSIM-HV is a surface-potential-based compact MOSFET model for LDMOS and HVMOS high-voltage devices. It has 4 external terminals (Gate, Drain, Source, Bulk) plus an optional 5th terminal (substrate node Vsub or thermal node, selected by COSUBNODE). Internally, the drain and source sides have resistive drift regions with internal nodes DP and SP; the model solves the Poisson equation iteratively to determine the complete surface potential distribution from source contact through the channel to the drain contact, including the bias-dependent resistance of the drift region.

---

## Parameters

### Model Flags

| Parameter | Default | Description |
|-----------|---------|-------------|
| COSYM | 0 | 0: asymmetrical LDMOS; 1: symmetrical/asymmetrical HVMOS |
| CORDRIFT | 1 | 0: legacy HV1 resistance model; 1: new HV2 diffused resistor model |
| CORS | 1 | 0: no source resistance; 1: source-side resistance included (CORDRIFT=1) |
| CORD | 1 | 0: no drain resistance; 1: drain-side resistance included (CORDRIFT=1) |
| CORSRD | 3 | Resistance model for CORDRIFT=0: 0=none, 1=external, 2=analytical, 3=both, -1=external nodes |
| COADOV | 1 | 0: no overlap charges; 1: overlap charges added to intrinsic |
| COOVLP | 1 | 0: constant overlap cap (drain); 1: bias-dependent |
| COOVLPS | 0 | 0: constant overlap cap (source); 1: bias-dependent |
| COQOVSM | 1 | Overlap potential method: 0=analytical no inversion, 1=iterative, 2=analytical with inversion |
| COSELFHEAT | 0 | 0: off; 1: power clipping; 2: temperature clipping |
| COISUB | 0 | 0: no Isub; 1: substrate current calculated |
| COIIGS | 0 | 0: no Igate; 1: gate current calculated |
| COGIDL | 0 | 0: no IGIDL; 1: GIDL current calculated |
| COISTI | 0 | 0: no STI leakage; 1: STI leakage calculated |
| CONQS | 0 | 0: quasi-static; 1: non-quasi-static model |
| CONQSOV | 0 | 0: no NQS on overlap; 1: NQS overlap charge |
| CORG | 0 | 0: no gate resistance; 1: gate resistance included |
| CORBNET | 0 | 0: no substrate resistance network; 1: substrate network |
| COFLICK | 0 | 0: no 1/f noise; 1: 1/f noise calculated |
| COTHRML | 0 | 0: no thermal noise; 1: thermal noise calculated |
| COIGN | 0 | 0: no induced gate noise; 1: induced gate + cross-correlation noise (requires COTHRML=1) |
| COPPRV | 1 | 0: no previous phi_S; 1: use previous phi_S for iteration |
| CODFM | 0 | 0: no DFM; 1: DFM variation model |
| COIPRV | 0 | 0: no; 1: use previous Ids for resistance (inactivated) |
| COTEMP | 0 | Temperature dependence selection (0-3, see manual Sec. 28) |
| COSUBNODE | 0 | 0: 5th node is thermal; 1: 5th node is Vsub |
| COERRREP | 1 | 0: no range check messages; 1: range check reported |
| CODEP | 0 | 0: conventional; 1: old depletion v2.2; 2: old depletion v2.3; 3: new depletion v2.4 |
| CODDLT | 1 | 0: previous Vds,sat model; 1: new Vds,sat model |
| COHBD | 0 | 0: no hard breakdown; 1 or -1: hard breakdown |
| COSNP | 0 | 0: no snapback; 1: snapback (requires CORBNET=1, COISUB=1) |
| CODIO | 0 | 0: conventional diode; 1: extended diode model |
| CODEG | 0 | 0: no aging; 1: aging simulation |
| CODEGSTEP | 0 | 0: circuit aging; 1: DC stress simulation |
| CODEGES0 | 0 | 0: no midgap density; 1: unoccupied midgap density |
| COOVJUNC | 0 | 0: using phi_s,over; 1: using Vdb for overlap junction |
| COTRENCH | 0 | 0: no trench gate cap; 1: trench gate capacitance |
| COPT | 0 | 0: no punchthrough; 1: punchthrough effects |

### Geometry / Device Size Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TOX | m | 7e-9 | -- | Physical gate-oxide thickness |
| XL | m | 0 | -- | Difference between real and drawn gate length |
| XW | m | 0 | -- | Difference between real and drawn gate width |
| XLD | m | 0 | [0, 50e-9] | Gate-overlap in length at source side |
| XLDLD | m | 1e-6 | [0, --] | Gate-overlap in length at drain side |
| XWD | m | 0 | [-100e-9, 300e-9] | Gate-overlap in width |
| XWDLD | m | 0 | -- | Widening of drift width (given if != XWD) |
| XWDC | m | 0 | [-500e-9, 500e-9] | Gate-overlap in width for capacitance (given if != XWD) |
| TPOLY | m | 200e-9 | -- | Height of gate poly-Si |
| LL | m^(LLN+1) | 0 | -- | Coefficient of gate length modification |
| LLD | m | 0 | -- | Coefficient of gate length modification |
| LLN | -- | 0 | -- | Coefficient of gate length modification |
| WL | m^(WLN+1) | 0 | -- | Coefficient of gate width modification |
| WLD | m | 0 | -- | Coefficient of gate width modification |
| WLN | -- | 0 | -- | Coefficient of gate width modification |
| KAPPA | -- | 3.9 | -- | Dielectric constant of gate dielectric |

### Structural Parameters (LDMOS/HVMOS)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| LOVER | m | 30e-9 | [0, --] | Overlap length at source side (used for LOVERS if LOVERS not given) |
| LOVERS | m | 30e-9 | [0, --] | Overlap length at source side |
| LOVERLD | m | 1e-6 | [0, --] | Overlap length at drain side (and source if COSYM=1) |
| LDRIFT1 | m | 1e-6 | [0, --] | Length of lightly doped drift region (drain; source if COSYM=1) |
| LDRIFT2 | m | 1e-6 | [0, --] | Length of heavily doped drift region (drain; source if COSYM=1) |
| NOVER | cm^-3 | 3e16 | -- | Impurity concentration of LOVERLD (drain; source if COSYM=1) |
| NOVERS | cm^-3 | 1e17 | -- | Impurity concentration at source overlap (COSYM=1) |
| LDRIFT1S | m | 0 | -- | Length of lightly doped drift region at source (COSYM=1) |
| LDRIFT2S | m | 1e-6 | -- | Length of heavily doped drift region at source (COSYM=1) |
| DDRIFT | m | 1e-6 | -- | Depth of the drift region |
| NSUBSUB | cm^-3 | 1e15 | -- | Impurity concentration of substrate (for Vsub dependence) |
| VBSMIN | V | -- | -- | Minimum Vbs (inactivated) |

### Basic Device Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VFBC | V | -1.0 (CODEP=0), -0.2 (CODEP=1,2,3) | [-1.2, 0.0] / [-1.2, 0.8] | Flat-band voltage |
| VBI | V | 1.1 | [1.0, 1.2] | Built-in potential |
| NSUBC | cm^-3 | 3e17 (CODEP=0), 5e16 (CODEP=1,2,3) | [1e16, 1e19] | Substrate impurity concentration |
| NSUBP | cm^-3 | 1e18 (CODEP=0), 1e17 (CODEP=1,2,3) | [1e16, 1e19] | Maximum pocket concentration |
| LP | m | 15e-9 (CODEP=0), 0 (CODEP=1,2,3) | [0, 300e-9] | Pocket penetration length |
| PARL2 | m | 10e-9 | [0, 50e-9] | Depletion width of channel/contact junction |

### Vds Smoothing Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DDLTMAX | -- | 10 | [1, 10] | Smoothing coefficient for Vds |
| DDLTSLP | um^-1 | 10 | [0, 20] | Lgate dependence of smoothing coefficient |
| DDLTICT | -- | 0 | [-3, 20] | Lgate dependence of smoothing coefficient |

### Short-Channel Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SC1 | -- | 0 | [0, 10] | Magnitude of short-channel effect |
| SC2 | V^-1 | 0 | [0, 1] | Vds dependence of short-channel effect |
| SC3 | V^-1 m | 0 | [0, 20e-6] | Vbs dependence of short-channel effect |
| SC4 | V^-1 | 0 | [0, --] | Vbs dependence of short-channel effect |
| SCP1 | -- | 0 | [0, 10] | Magnitude of short-channel effect due to pocket |
| SCP2 | V^-1 | 0 | [0, 1] | Vds dependence of short-channel due to pocket |
| SCP3 | V^-1 m | 0 | [0, 200e-9] | Vbs dependence of short-channel effect due to pocket |
| SCP21 | V | 0 | [0, 5.0] | Short-channel-effect modification for small Vds |
| SCP22 | V^4 | 0 | [0, 0] | Short-channel-effect modification for small Vds (reset to zero) |
| BS1 | V^2 | 0 | [0, 0.05] | Body-coefficient modification due to impurity profile |
| BS2 | V | 0.9 | [0.5, 1.0] | Body-coefficient modification due to impurity profile |
| NPEXT | cm^-3 | 5e17 | [1e16, 1e18] | Maximum concentration of pocket tail |
| LPEXT | m | 1e-50 | [1e-50, 1e-5] | Extension length of pocket tail |

### Punchthrough Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PTL | V | 0 | [0, --] | Strength of punchthrough effect |
| PTLP | -- | 1.0 | -- | Channel-length dependence of punchthrough effect |
| PTP | -- | 3.5 | [3.0, 4.0] | Strength of punchthrough effect |
| PT2 | V^-1 | 0 | [0, --] | Vds dependence of punchthrough effect |
| PT4 | V^-2 | 0 | [0, --] | Vbs dependence of punchthrough effect |
| PT4P | -- | 1 | [0, --] | Vbs dependence of punchthrough effect |
| GDL | -- | 0 | [0, 0.22] | Strength of high-field conductance effect |
| GDLP | -- | 0 | -- | Channel-length dependence of high-field effect |
| GDLD | m | 0 | -- | Channel-length dependence of high-field effect |

### Deep Punchthrough Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NJUNC | cm^-3 | -- | -- | Source/drain diffusion dopant concentration |
| XJPT | m | -- | -- | Effective junction depth for deep punchthrough current |
| MUPT | cm^2/(V s) | -- | -- | Effective mobility for deep punchthrough current |
| PSLIMPT | V | -- | -- | Potential limiter for deep punchthrough current |
| VFBPT | V | -- | -- | Flatband voltage shifter for deep punchthrough current |
| PS0PT | V | -- | -- | Constant Ps0 for deep punchthrough current (if > 0) |

### Poly-Si Gate Depletion Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| PGD1 | V | 0 | [0, 30e-3] | Strength of poly depletion |
| PGD2 | V | 1.0 | [0, 1.5] | Threshold voltage of poly depletion |
| PGD4 | -- | 0 | [0, 3.0] | Lgate dependence of poly depletion |

### Quantum-Mechanical Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| QME1 | V m | 0 | [0, 1e-9] | Vgs dependence |
| QME2 | V | 2.0 | [1.0, 3.0] | Vgs dependence |
| QME3 | m | 0 | [0, 500e-12] | Minimum Tox modification |

### Mobility Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| MUECB0 | cm^2/(V s) | 190 | [100, 100e3] | Coulomb scattering coefficient |
| MUECB1 | cm^2/(V s) | 30 | [5, 10e3] | Coulomb scattering coefficient |
| MUEPH0 | -- | 0.3 | [0.25, 0.35] | Phonon scattering exponent (default recommended) |
| MUEPH1 | cm^2/(V s)(V/cm)^MUEPH0 | 20e3 (nMOS), 9e3 (pMOS) | [2e3, 30e3] | Phonon scattering coefficient |
| MUEEFB | V^-1 | 0.0 | -- | Vbs dependence of phonon mobility |
| MUETMP | -- | 1.5 | [0.5, 2.5] | Temperature dependence of phonon scattering |
| MUEPHL | -- | 0 | -- | Length dependence of phonon mobility reduction |
| MUEPLP | -- | 1.0 | -- | Length dependence of phonon mobility reduction |
| MUESR0 | -- | 2.0 | [1.8, 2.2] | Surface-roughness scattering exponent (default recommended) |
| MUESR1 | cm^2/(V s)(V/cm)^MUESR0 | 5e14 (CODEP=0), 5e15 (CODEP=1,2,3) | [1e14, 1e16] | Surface-roughness scattering coefficient |
| MUESRL | -- | 0 | -- | Length dependence of surface roughness mobility |
| MUESLP | -- | 1.0 | -- | Length dependence of surface roughness mobility |
| NDEP | -- | 1.0 | [0, 1.0] | Depletion charge contribution on effective-electric field |
| NDEPL | -- | 0 | -- | Modification of depletion charge for short-channel |
| NDEPLP | -- | 1.0 | -- | Modification of depletion charge for short-channel |
| NINV | -- | 0.5 | [0, 1.0] | Inversion charge contribution on effective-electric field |
| NINVD | V^-1 | 0.0 | [0, --] | Reduced resistance effect for small Vds |
| NINVDL | -- | -- | -- | Length dependence of NINVD |
| NINVDLP | -- | -- | -- | Length dependence of NINVD |
| NINVDW | -- | 0.0 | [0, --] | Width dependence on high field mobility |
| NINVDWP | -- | 1.0 | [0, --] | Width dependence on high field mobility |
| NINVDT1 | K^-1 | 0.0 | [0, --] | Temperature dependence of NINVD |
| NINVDT2 | K^-2 | 0.0 | [0, --] | Temperature dependence of NINVD |
| BB | -- | 2.0 (nMOS), 1.0 (pMOS) | -- | High-field-mobility degradation exponent |
| VMAX | cm/s | 10e6 | [1e6, 20e6] | Maximum saturation velocity |
| VMAXT1 | cm/(s K) | 0 | -- | Temperature dependence of velocity |
| VMAXT2 | cm/(s K^2) | 0 | -- | Temperature dependence of velocity |
| VOVER | m^VOVERP | 0.3 | [0, 4.0] | Velocity overshoot effect |
| VOVERP | -- | 0.3 | [0, 2.0] | Leff dependence of velocity overshoot |
| VTMP | -- | 0 | [-2.0, 1.0] | Temperature dependence of saturation velocity |
| EYMOD | -- | 1.0 | -- | Modification of Ey for 1/f noise Vgs dependence |

### Narrow-Channel Effect Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WFC | F/m | 0 | [-5e-15, 1e-6] | Threshold voltage change due to edge fringing capacitance |
| WVTH0 | V | 0 | -- | Threshold voltage shift |
| NSUBCW | -- | 0 | -- | Width dependence of substrate-impurity concentration |
| NSUBCWP | -- | 1 | -- | Width dependence of substrate-impurity concentration |
| NSUBP0 | cm^-3 | 0 | -- | Modification of pocket concentration for narrow width |
| NSUBWP | -- | 1.0 | -- | Modification of pocket concentration for narrow width |
| MUEPHW | -- | 0 | -- | Phonon related mobility reduction (width dep.) |
| MUEPWP | -- | 1.0 | -- | Phonon related mobility reduction (width dep.) |
| MUESRW | -- | 0 | -- | Change of surface roughness related mobility (width dep.) |
| MUESWP | -- | 1.0 | -- | Change of surface roughness related mobility (width dep.) |

### STI Leakage Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| VTHSTI | V | 0 | -- | Threshold voltage shift due to STI |
| VDSTI | -- | 0 | -- | Threshold voltage shift dependence on Vds due to STI |
| SCSTI1 | -- | 0 | -- | Short-channel effect at STI edge (like SC1) |
| SCSTI2 | V^-1 | 0 | -- | Short-channel effect at STI edge (like SC2) |
| NSTI | cm^-3 | 5e17 | [1e16, 1e19] | Substrate-impurity concentration at STI edge |
| WSTI | m | 0 | -- | Width of high-field region at STI edge |
| WSTIL | -- | 0 | -- | Channel-length dependence of WSTI |
| WSTILP | -- | 1.0 | -- | Channel-length dependence of WSTI |
| WSTIW | -- | 0 | -- | Channel-width dependence of WSTI |
| WSTIWP | -- | 1.0 | -- | Channel-width dependence of WSTI |

### Small-Geometry Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| WL1 | -- | 0 | -- | Vth shift of STI leakage due to small size |
| WL1P | -- | 1.0 | -- | Vth shift of STI leakage due to small size |
| WL2 | V | 0 | -- | Threshold voltage shift due to small size |
| WL2P | -- | 1.0 | -- | Threshold voltage shift due to small size |
| MUEPHS | -- | 0 | -- | Mobility modification due to small size |
| MUEPSP | -- | 1.0 | -- | Mobility modification due to small size |
| VOVERS | -- | 0 | -- | Modification of maximum velocity due to small size |
| VOVERSP | -- | 0 | -- | Modification of maximum velocity due to small size |

### LOD (Length of Diffusion) / STI Stress Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NSUBPSTI1 | m | 0 | -- | Pocket conc. change due to LOD |
| NSUBPSTI2 | -- | 0 | -- | Pocket conc. change due to LOD |
| NSUBPSTI3 | -- | 1.0 | -- | Pocket conc. change due to LOD |
| MUESTI1 | m | 0 | -- | Mobility change due to LOD |
| MUESTI2 | -- | 0 | -- | Mobility change due to LOD |
| MUESTI3 | -- | 1.0 | -- | Mobility change due to LOD |
| SAREF | m | 1e-6 | -- | Reference diffusion length (gate to STI) |
| SBREF | m | 1e-6 | -- | Reference diffusion length (gate to STI) |

### Channel-Length Modulation Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| CLM1 | -- | 0.05 | [0.01, 1.0] | Hardness coefficient of channel/contact junction |
| CLM2 | -- | 2.0 | [1.0, 4.0] | Coefficient for QB contribution |
| CLM3 | -- | 1.0 | [0.5, 5.0] | Coefficient for QI contribution |
| CLM5 | -- | 1.0 | [0, 2.0] | Effect of pocket implantation |
| CLM6 | -- | 0 | [0, 20.0] | Effect of pocket implantation |

### Temperature Dependence Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TNOM | C | 27 | [22, 32] | Nominal temperature |
| EG0 | eV | 1.1785 | [1.0, 1.3] | Bandgap at TNOM |
| BGTMP1 | eV/K | 90.25e-6 | [50e-6, 1000e-6] | Temperature dependence of bandgap |
| BGTMP2 | eV/K^2 | 0.1e-6 | [-1e-6, 1e-6] | Temperature dependence of bandgap |
| EGIG | V | 0.0 | -- | Bandgap of gate current |
| IGTEMP2 | V K | 0 | -- | Temperature dependence of gate current |
| IGTEMP3 | V K^2 | 0 | -- | Temperature dependence of gate current |
| TRAPTEMP1 | K^-1 | 0 | -- | Temperature dependence of trap density (CODEG=1) |
| TRAPTEMP2 | K^-2 | 0 | -- | Temperature dependence of trap density (CODEG=1) |

### Resistance Parameters (CORDRIFT=1, new model)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RS | Ohm m | 0 | [0, 0.01] | Source-contact resistance of LDD region |
| RD | Ohm m | 0 | [0, 0.1] | Drain-contact resistance of LDD region |
| RSH | Ohm/sq | 0 | [0, 500] | Sheet resistance of diffusion region |
| RDRDL1 | m | 0 | -- | Effective Ldrift of current in drift region |
| RDRDL2 | m | 0 | -- | Pinch-off length in drift region |
| RDRCX | -- | 0 | [0, 1] | Exude of current flow from Xov |
| RDRCAR | m/V | 100e-9 | [0, 50e-9] | High field injection in drift region |
| RDRDJUNC | m | 1e-6 | -- | Junction depth at channel/drift region (drain side) |
| RDRSJUNC | m | -- | -- | Junction depth at channel/drift region (source side) |
| RDRBB | -- | 1.0 | -- | High field mobility in drift region (drain side) |
| RDRBBS | -- | 1.0 | -- | High field mobility in drift region (source side) |
| RDRMUE | cm^2/(V s) | 1000 | [100, 3000] | Mobility in drift region (drain side) |
| RDRMUES | cm^2/(V s) | 1000 | [100, 3000] | Mobility in drift region (source side) |
| RDRMUEL | -- | 0 | -- | Mobility Lgate dependence |
| RDRMUELP | -- | 1 | -- | Mobility Lgate dependence |
| RDRMUETMP | -- | 0 | [0, 2.0] | Temperature dependence of drift mobility |
| RDRVMAX | cm/s | 30e6 | [1e6, 100e6] | Saturation velocity in drift region (drain side) |
| RDRVMAXS | cm/s | 30e6 | [1e6, 100e6] | Saturation velocity in drift region (source side) |
| RDRVMAXL | -- | 0 | -- | Saturation velocity Lgate dependence |
| RDRVMAXLP | -- | 1 | -- | Saturation velocity Lgate dependence |
| RDRVMAXW | -- | 0 | -- | Saturation velocity Wgate dependence |
| RDRVMAXWP | -- | 1 | -- | Saturation velocity Wgate dependence |
| RDRVTMP | -- | 0 | [-2.0, 1.0] | Temperature dependence of drift Vmax |
| RDRBBTMP | K^-1 | 0 | -- | Temperature dependence of RDRBB |
| RDRQOVER | cm^-1 | 1e5 | [0, 1e7] | Inclusion of overlap charge into Rdrift (drain) |
| RDRQOVERS | cm^-1 | -- | -- | Inclusion of overlap charge into Rdrift (source) |
| VBISUB | -- | 0.7 | -- | Built-in potential at drift/substrate junction |
| RDVDSUB | -- | 0.3 | -- | Vds dependence of depletion width |
| RDVSUB | -- | 1.0 | -- | Vsub dependence of depletion width |

### Resistance Parameters (CORDRIFT=0, legacy model)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RDVG11 | -- | 0 | [0, Vds_max/30] | Vgs dependence of RD (CORSRD=1,3) |
| RDVG12 | V^-1 | 100 | [0, Vds_max] | Vgs dependence of RD (CORSRD=1,3) |
| RDVD | Ohm cm/V | 7e-2 | [0, 2.0] | Vds dependence of RD (CORSRD=1,3) |
| RDVB | V^-1 | 0 | [0, 2.0] | Vbs dependence of RD (CORSRD=1,3) |
| RDS | um^RDSP | 0 | [-100, 100] | Size dependence (CORSRD=1,3) |
| RDSP | -- | 1 | [-10, 10] | Size dependence (CORSRD=1,3) |
| RDVDL | um^(-RDVDLP) | 0 | [-100, 100] | Lgate dependence of RDVD (CORSRD=1,3) |
| RDVDLP | -- | 1 | [-10, 10] | Lgate dependence of RDVD (CORSRD=1,3) |
| RDVDS | um^RDVDSP | 0 | [-100, 100] | Size dependence of RDVD (CORSRD=1,3) |
| RDVDSP | -- | 1 | [-10, 10] | Size dependence of RDVD (CORSRD=1,3) |
| RDSLP1 | -- | 0 | [-10, 10] | LDRIFT1 dependence of resistance (CORSRD=1,3) |
| RDICT1 | -- | 1.0 | [-10, 10] | LDRIFT1 dependence of resistance (CORSRD=1,3) |
| RDSLP2 | -- | 1 | [-10, 10] | LDRIFT2 dependence of resistance (CORSRD=1,3) |
| RDICT2 | -- | 0 | [-10, 10] | LDRIFT2 dependence of resistance (CORSRD=1,3) |
| RDOV11 | -- | 0 | [0, 10] | Overlap dependence (CORSRD=1,3) |
| RDOV12 | -- | 1.0 | [0, 2] | Overlap dependence (CORSRD=1,3) |
| RDOV13 | -- | 1.0 | [0, 1.0] | Alternative overlap model (CORSRD=1,3) |
| RD20 | -- | 0 | [0, 30] | RD23 boundary (CORSRD=2,3) |
| RD21 | -- | 1.0 | [0, 1.0] | Vds dependence of RD (CORSRD=2,3) |
| RD22 | Ohm m / V^(RD22D+1) | 0 | [-5.0, 0] | Vbs dependence of RD (CORSRD=2,3) |
| RD22D | -- | 0 | [0, 2.0] | Vbs dependence of RD (CORSRD=2,3) |
| RD23 | Ohm m / V^RD21 | 0.005 | [0, 2.0] | Modification of RD (CORSRD=2,3) |
| RD23L | um^(-RD23LP) | 0 | [-100, 100] | Lgate dependence of RD23 (CORSRD=2,3) |
| RD23LP | -- | 1 | [-10, 10] | Lgate dependence of RD23 (CORSRD=2,3) |
| RD23S | um^(RD23SP+1) | 0 | [-100, 100] | Small size dependence of RD23 (CORSRD=2,3) |
| RD23SP | -- | 1 | [-10, 10] | Small size dependence of RD23 (CORSRD=2,3) |
| RD24 | Ohm m / V^(RD21+1) | 0 | [0, 0.1] | Vgs dependence of RD (CORSRD=2,3) |
| RD25 | V | 0 | [0, Vgs_max] | Vgs dependence of RD (CORSRD=2,3) |
| RDTEMP1 | Ohm cm/K | 0 | [-0.1, 2] | Temperature dependence of resistance (CORDRIFT=0) |
| RDTEMP2 | Ohm cm/K^2 | 0 | [-1e-3, 1e-3] | Temperature dependence of resistance (CORDRIFT=0) |
| RDVDTEMP1 | Ohm cm/(V K) | 0 | [-0.1, 1.0] | Temperature dependence of RDVD |
| RDVDTEMP2 | Ohm cm/(V K^2) | 0 | [-1e-3, 1e-3] | Temperature dependence of RDVD |

### Gate Resistance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RSHG | Ohm/sq | 0 | [0, 100] | Gate sheet resistance |

### Substrate Resistance Network

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RBPB | Ohm | 50 | -- | Substrate resistance (body to body-prime) |
| RBPD | Ohm | 50 | -- | Substrate resistance (body-prime to drain) |
| RBPS | Ohm | 50 | -- | Substrate resistance (body-prime to source) |

### Capacitance Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| XQY | m | 0 | [10e-9, 50e-9] | Distance from drain junction to max E-field point |
| XQY1 | F um^(XQY2-1) | 0 | [0, --] | Vbs dependence of Qy |
| XQY2 | -- | 2 | [0, --] | Lgate dependence of Qy |
| VFBOVER | V | 0.5 | [-1.2, 1] | Flat-band voltage in overlap region |
| QOVADD | F/m^2 | 0 | -- | Additional overlap capacitance |
| QOVJUNC | -- | 0 | [-1, 50] | Wjunc coefficient for LoverLD modification |
| CVDSOVER | -- | 0 | [0, 1.0] | Modification of Cgg peak for Vds!=0 (COTRENCH=0 only) |
| OVSLP | m/V | 2.1e-7 | -- | Coefficient for overlap capacitance |
| OVMAG | V | 0.6 | -- | Coefficient for overlap capacitance |
| CGSO | F/m | -- | [0, 100e-9*Cox] | Gate-to-source overlap capacitance (user-set) |
| CGDO | F/m | -- | [0, 100e-9*Cox] | Gate-to-drain overlap capacitance (user-set) |
| CGBO | F/m | 0 | [0, --] | Gate-to-bulk overlap capacitance |
| WTRENCH | m | 0 | [0, --] | Trench length (COTRENCH=1) |
| OLMDLT | -- | 5 | [0, 100] | Smoothing exponent for trench junction voltage (COTRENCH=1) |
| LOVERLD2 | m | -- | -- | Overlap length parameter for trench (used in Vdblim) |

### Substrate Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SUB1 | V^-1 | 10 | -- | Substrate current magnitude |
| SUB1L | m^SUB1LP | 2.5e-3 | -- | Lgate dependence of SUB1 |
| SUB1LP | -- | 1.0 | -- | Lgate dependence of SUB1 |
| SUB2 | V | 25.0 | -- | Substrate current exponential coefficient |
| SUB2L | m | 2e-6 | [0, 1.0] | Lgate dependence of SUB2 |
| SUBTMP | K^-1 | 0 | [0, 5e-3] | Temperature dependence of Isub |
| SVDS | -- | 0.8 | -- | Substrate current dependence on Vds |
| SLG | m | 3e-8 | -- | Substrate current dependence on Lgate |
| SLGL | m^SLGLP | 0 | -- | Substrate current Lgate dependence |
| SLGLP | -- | 1.0 | -- | Substrate current Lgate dependence |
| SVBS | -- | 0.5 | -- | Substrate current dependence on Vbs |
| SVBSL | m^SVBSLP | 0 | -- | Lgate dependence of SVBS |
| SVBSLP | -- | 1.0 | -- | Lgate dependence of SVBS |
| SVGS | -- | 0.8 | -- | Substrate current dependence on Vgs |
| SVGSL | m^SVGSLP | 0 | -- | Lgate dependence of SVGS |
| SVGSLP | -- | 1.0 | -- | Lgate dependence of SVGS |
| SVGSW | m^SVGSWP | 0 | -- | Wgate dependence of SVGS |
| SVGSWP | -- | 1.0 | -- | Wgate dependence of SVGS |
| IBPC1 | V/A | 0 | [0, 1e12] | Impact-ionization induced bulk potential change |
| IBPC1L | -- | 0 | -- | Lgate dependence of IBPC1 |
| IBPC1LP | -- | 1.0 | -- | Lgate dependence of IBPC1 |
| IBPC2 | V^-1 | 0 | [0, 1e12] | Impact-ionization induced bulk potential change |
| SUBLD1 | V^-1 | 0 | -- | Substrate current induced in Ldrift |
| SUBLD1L | um^SUBLD1LP | 0 | -- | Lgate dependence of SUBLD1 |
| SUBLD1LP | -- | 1.0 | -- | Lgate dependence of SUBLD1 |
| SUBLD2 | mV^-1 | 0 | -- | Substrate current induced in Ldrift |
| XPDV | -- | 0 | [0, --] | Potential change for expansion effect |
| XPVDTH | -- | 0 | [0, --] | Potential change for expansion effect |
| XPVDTHG | -- | 0 | [-1, 1] | Potential change for expansion effect |

### Gate Current Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| GLEAK1 | V^(-3/2) s^-1 | 50 | -- | Gate-to-channel current coefficient |
| GLEAK2 | V^(-1/2) cm^-1 | 10e6 | -- | Gate-to-channel current coefficient |
| GLEAK3 | -- | 60e-3 | -- | Gate-to-channel current coefficient |
| GLEAK4 | m^-1 | 4.0 | -- | Gate-to-channel current coefficient |
| GLEAK5 | V/m | 7.5e3 | -- | Short channel correction |
| GLEAK6 | V | 250e-3 | -- | Vds dependence correction |
| GLEAK7 | m^2 | 1e-6 | -- | Gate length/width dependence correction |
| GLKB1 | A/(V^2 m^2) | 5e-16 | -- | Gate-to-bulk current coefficient |
| GLKB2 | m/V | 1.0 | -- | Gate-to-bulk current coefficient |
| GLKB3 | V | 0 | -- | Flat-band shift for gate-to-bulk current |
| GLKSD1 | A m / V^2 | 1e-15 | -- | Gate-to-source/drain current coefficient |
| GLKSD2 | V^-1 m^-1 | 1e3 | -- | Gate-to-source/drain current coefficient |
| GLKSD3 | m^-1 | -1e3 | -- | Gate-to-source/drain current coefficient |
| GLPART1 | -- | 0.5 | [0, 1.0] | Partitioning ratio of gate leakage current |
| FN1 | V^-1.5 m^2 | 50 | -- | Fowler-Nordheim current coefficient |
| FN2 | V^-0.5 m^-1 | 170e-6 | -- | Fowler-Nordheim current coefficient |
| FN3 | V | 0 | -- | Fowler-Nordheim current coefficient |
| FVBS | -- | 12e-3 | -- | Vbs dependence of Fowler-Nordheim current |

### GIDL Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| GIDL1 | V^(-3/2) s^-1 m | 2.0 | -- | Magnitude of GIDL |
| GIDL2 | V^(-0.5) m^-1 | 3e7 | -- | Field dependence of GIDL |
| GIDL3 | -- | 0.9 | -- | Vds dependence of GIDL |
| GIDL4 | V | 0 | -- | Threshold of Vds dependence |
| GIDL5 | -- | 0.2 | -- | Correction of high-field contribution |

### Diode Parameters (Source/Bulk and Drain/Bulk)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| JS0 | A/m^2 | 0.5e-6 | -- | Saturation current density |
| JS0D | A/m^2 | JS0 | -- | Saturation current density (drain) |
| JS0S | A/m^2 | JS0 | -- | Saturation current density (source) |
| JS0SW | A/m | 0 | -- | Sidewall saturation current density |
| JS0SWD | A/m | JS0SW | -- | Sidewall saturation current density (drain) |
| JS0SWS | A/m | JS0SW | -- | Sidewall saturation current density (source) |
| JS0SWG | A/m | 0 | -- | Gate-side saturation current density (CODIO=1) |
| JS0SWGD | A/m | JS0SWG | -- | Gate-side saturation current density drain (CODIO=1) |
| JS0SWGS | A/m | JS0SWG | -- | Gate-side saturation current density source (CODIO=1) |
| NJ | -- | 1.0 | -- | Emission coefficient |
| NJD | -- | NJ | -- | Emission coefficient (drain) |
| NJS | -- | NJ | -- | Emission coefficient (source) |
| NJSW | -- | 1.0 | -- | Sidewall emission coefficient |
| NJSWD | -- | NJSW | -- | Sidewall emission coefficient (drain) |
| NJSWS | -- | NJSW | -- | Sidewall emission coefficient (source) |
| NJSWG | -- | 1.0 | -- | Gate sidewall emission coefficient |
| NJSWGD | -- | NJSWG | -- | Gate sidewall emission coefficient (drain) |
| NJSWGS | -- | NJSWG | -- | Gate sidewall emission coefficient (source) |
| XTI | -- | 2.0 | -- | Temperature coefficient for forward current densities |
| XTID | -- | XTI | -- | Temperature coefficient (drain) |
| XTIS | -- | XTI | -- | Temperature coefficient (source) |
| XTI2 | -- | 0 | -- | Temperature coefficient for reverse current densities |
| XTI2D | -- | XTI | -- | Temperature coefficient (drain) |
| XTI2S | -- | XTI | -- | Temperature coefficient (source) |
| DIVX | V^-1 | 0 | -- | Reverse current coefficient |
| DIVXD | V^-1 | DIVX | -- | Reverse current coefficient (drain) |
| DIVXS | V^-1 | DIVX | -- | Reverse current coefficient (source) |
| CISB | -- | 0 | -- | Reverse biased saturation current |
| CISBD | -- | CISB | -- | Reverse biased saturation current (drain) |
| CISBS | -- | CISB | -- | Reverse biased saturation current (source) |
| CVB | -- | 0 | [-0.1, 0.2] | Bias dependence coefficient of CISB |
| CVBD | -- | CVB | [-0.1, 0.2] | Bias dependence coefficient (drain) |
| CVBS | -- | CVB | [-0.1, 0.2] | Bias dependence coefficient (source) |
| CTEMP | -- | 0 | -- | Temperature coefficient of reverse currents |
| CISBK | A | 0 | -- | Reverse biased saturation current (low temperature) |
| CISBKD | A | CISBK | -- | Reverse biased saturation current (drain, low temp) |
| CISBKS | A | CISBK | -- | Reverse biased saturation current (source, low temp) |
| VDIFFJ | V | 0.6e-3 | -- | Diode threshold voltage |
| VDIFFJD | V | VDIFFJ | -- | Diode threshold voltage (drain) |
| VDIFFJS | V | VDIFFJ | -- | Diode threshold voltage (source) |
| CJ | F/m^2 | 5e-4 | -- | Bottom junction capacitance per unit area at zero bias |
| CJD | F/m^2 | CJ | -- | Bottom junction capacitance (drain) |
| CJS | F/m^2 | CJ | -- | Bottom junction capacitance (source) |
| CJSW | F/m | 5e-10 | -- | Sidewall junction cap. per unit length at zero bias |
| CJSWD | F/m | CJSW | -- | Sidewall junction cap. (drain) |
| CJSWS | F/m | CJSW | -- | Sidewall junction cap. (source) |
| CJSWG | F/m | 5e-10 | -- | Gate sidewall junction cap. per unit length at zero bias |
| CJSWGD | F/m | CJSWG | -- | Gate sidewall junction cap. (drain) |
| CJSWGS | F/m | CJSWG | -- | Gate sidewall junction cap. (source) |
| MJ | -- | 0.5 | -- | Bottom junction cap. grading coefficient |
| MJD | -- | MJ | -- | Bottom junction cap. grading coefficient (drain) |
| MJS | -- | MJ | -- | Bottom junction cap. grading coefficient (source) |
| MJSW | -- | 0.33 | -- | Sidewall junction cap. grading coefficient |
| MJSWD | -- | MJSW | -- | Sidewall junction cap. grading coefficient (drain) |
| MJSWS | -- | MJSW | -- | Sidewall junction cap. grading coefficient (source) |
| MJSWG | -- | 0.33 | -- | Gate sidewall junction cap. grading coefficient |
| MJSWGD | -- | MJSWG | -- | Gate sidewall junction cap. grading coefficient (drain) |
| MJSWGS | -- | MJSWG | -- | Gate sidewall junction cap. grading coefficient (source) |
| PB | V | 1.0 | -- | Bottom junction built-in potential |
| PBD | V | PB | -- | Bottom junction built-in potential (drain) |
| PBS | V | PB | -- | Bottom junction built-in potential (source) |
| PBSW | V | 1.0 | -- | Sidewall junction built-in potential |
| PBSWD | V | PBSW | -- | Sidewall junction built-in potential (drain) |
| PBSWS | V | PBSW | -- | Sidewall junction built-in potential (source) |
| PBSWG | V | 1.0 | -- | Gate sidewall junction built-in potential |
| PBSWGD | V | PBSWG | -- | Gate sidewall built-in potential (drain) |
| PBSWGS | V | PBSWG | -- | Gate sidewall built-in potential (source) |
| TCJBD | K^-1 | 0 | -- | Temp. dependence of drain diode cap. |
| TCJBDSW | K^-1 | 0 | -- | Temp. dependence of drain sidewall diode cap. |
| TCJBDSWG | K^-1 | 0 | -- | Temp. dependence of drain gate-sidewall diode cap. |
| TCJBS | K^-1 | 0 | -- | Temp. dependence of source diode cap. |
| TCJBSSW | K^-1 | 0 | -- | Temp. dependence of source sidewall diode cap. |
| TCJBSSWG | K^-1 | 0 | -- | Temp. dependence of source gate-sidewall diode cap. |

### Hard Breakdown Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| HBDA | -- | 0.0 | -- | Coefficient for hard breakdown voltage |
| HBDB | -- | 0.0 | -- | Coefficient for hard breakdown voltage |
| HBDC | -- | 100.0 | -- | Coefficient for hard breakdown voltage |
| HBDF | -- | 1.0 | -- | Coefficient for hard breakdown voltage |
| HBDCTMP | -- | 0.0 | -- | Temperature dependence of HBDC |

### Snapback Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| SUB1SNP | V^-1 | SUB1 | -- | Impact ionization parameter for snapback |
| SUB2SNP | V | 0.6*SUB2 | -- | Impact ionization parameter for snapback |
| SVDSSNP | -- | SVDS | -- | Impact ionization parameter for snapback |

### Noise Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NFTRP | V^-1 | 1e10 | -- | Ratio of trap density to attenuation coefficient |
| NFALP | cm s | 1e-19 | -- | Contribution of mobility fluctuation |
| CIT | F/cm^2 | 0 | -- | Capacitance caused by interface trapped carriers |
| FALPH | -- | 1.0 | -- | Power of f describing deviation from 1/f |

### NQS Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DLY1 | s | 100e-12 | -- | Coefficient for delay due to diffusion |
| DLY2 | m^2 | 0.7 | -- | Coefficient for delay due to conduction |
| DLY3 | Ohm m^2 | 0.8e-6 | -- | Coefficient for RC delay of bulk carriers |
| DLYOV | A^-1 | 0.8e-4 | -- | Coefficient for RC delay of overlap charge (CONQSOV=1) |

### Self-Heating Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| RTH0 | K cm/W | 0.1 | [0, 10] | Thermal resistance |
| RTHTEMP1 | m/W | 0 | [-1, 1] | Temperature dependence of thermal resistance |
| RTHTEMP2 | m/(W K) | 0 | [-1, 1] | Temperature dependence of thermal resistance |
| CTH0 | W s/(K cm) | 1e-7 | -- | Thermal capacitance |
| RTH0L | -- | 0 | [-100, 100] | Length dependence of thermal resistance |
| RTH0LP | -- | 1 | [-10, 10] | Length dependence of thermal resistance |
| RTH0W | -- | 0 | [-100, 100] | Width dependence of thermal resistance |
| RTH0WP | -- | 1 | [-10, 10] | Width dependence of thermal resistance |
| RTH0NF | -- | 0 | [-5, 5] | NF dependence of thermal resistance |
| POWRAT | -- | 1.0 | [0, 1.0] | Thermal dissipation ratio |
| PRATTEMP1 | K^-1 | 0 | [-1, 1] | Temperature dependence of thermal dissipation |
| PRATTEMP2 | K^-2 | 0 | [-1, 1] | Temperature dependence of thermal dissipation |
| SHEMAX | K | 500 | [300, 900] | Maximum temperature increase |
| SHEMAXDLT | -- | 0.1 | [0, --] | Smoothing for SHEMAX |

### DFM Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| MPHDFM | -- | -0.3 | [-3, 3] | Mobility dependence of Nsubc due to phonon scattering |

### Binning Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| LBINN | -- | -- | -- | Power of Ldrawn function |
| WBINN | -- | -- | -- | Power of Wdrawn function |
| LMAX | m | -- | -- | Maximum length of Ldrawn valid |
| LMIN | m | -- | -- | Minimum length of Ldrawn valid |
| WMAX | m | -- | -- | Maximum width of Wdrawn valid |
| WMIN | m | -- | -- | Minimum width of Wdrawn valid |

### Depletion Mode Parameters (CODEP=1,2,3 common)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| NDEPM | cm^-3 | 1e17 (CODEP=1,2), 4e16 (CODEP=3) | [5e15, 1e18] | Impurity concentration of surface layer |
| NDEPML | -- | 0 | -- | Lgate dependence of NDEPM |
| NDEPMLP | -- | 1 | -- | Lgate dependence of NDEPM |
| TNDEP | m | 200e-9 (CODEP=1,2), 300e-9 (CODEP=3) | [10e-9, 100e-9] | Thickness of surface layer |
| DEPMUE0 | cm^2/(V s) | 1000 (CODEP=1,2), 1e8 (CODEP=3) | [1, 1e5] / [1, 1e10] | Coulomb scattering in resistor region |
| DEPMUE0L | -- | 0 | -- | Lgate dependence |
| DEPMUE0LP | -- | 1 | -- | Lgate dependence |
| DEPMUE1 | cm^2/(V s) | 0 (CODEP=1,2), 100 (CODEP=3) | -- | Coulomb scattering in resistor region |
| DEPMUE1L | -- | 0 | -- | Lgate dependence |
| DEPMUE1LP | -- | 1 | -- | Lgate dependence |
| DEPMUEPH0 | -- | 0.3 (CODEP=1,2), 0 (CODEP=3) | -- | Phonon scattering in resistor region |
| DEPMUEPH1 | cm^2/(V s) | 5e3 (CODEP=1,2), 400 (CODEP=3) | [1, 1e5] / [100, 2e9] | Phonon scattering in resistor region |
| DEPVMAX | cm/s | 3e7 (CODEP=1,2), 1e7 (CODEP=3) | -- | Saturation velocity in resistor region |
| DEPVMAXL | -- | 0 | -- | Lgate dependence of DEPVMAX |
| DEPVMAXLP | -- | 1 | -- | Lgate dependence of DEPVMAX |
| DEPBB | -- | 1 (CODEP=1,2), 2 (CODEP=3) | [0.01, --] | High-field mobility degradation in resistor |
| DEPMUETMP | -- | 1.5 | -- | Temperature dependence of phonon scattering |
| DEPVTMP | -- | 0.0 | -- | Temperature dependence of DEPVMAX |
| DEPMUE0TMP | -- | 0.0 | -- | Temperature dependence of DEPMUE0 |
| DEPLEAK | V | 0.5 (CODEP=1,2), 0.1 (CODEP=3) | [0, 5] | Leakage current coefficient |
| DEPLEAKL | -- | 0 | -- | Lgate dependence of leakage |
| DEPLEAKLP | -- | 1 | -- | Lgate dependence of leakage |
| DEPSUBSL | -- | 2.0 | [10e-9, --] | Factor of sub-threshold slope |
| DEPVGPSL | V | 0.0 (CODEP=2), 0.2 (CODEP=3) | [0, --] | Smoothing of gm at Vfb |

### Depletion Mode Parameters (CODEP=1 only)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DEPETA | V^-1 | 0 | -- | Vds dependence of Vth shift |
| DEPVDSEF1 | V | 2.0 | -- | Effective drain potential coefficient-1 |
| DEPVDSEF1L | -- | 0 | -- | Lgate dependence |
| DEPVDSEF1LP | -- | 1 | -- | Lgate dependence |
| DEPVDSEF2 | -- | 0.5 | [0.1, 4.0] | Effective drain potential coefficient-2 |
| DEPVDSEF2L | -- | 0 | -- | Lgate dependence |
| DEPVDSEF2LP | -- | 1 | -- | Lgate dependence |
| DEPMUEBACK0 | cm^2/(V s) | 100 | [1, 1e5] | Coulomb scattering in back region |
| DEPMUEBACK0L | -- | 0 | -- | Lgate dependence |
| DEPMUEBACK0LP | -- | 1 | -- | Lgate dependence |
| DEPMUEBACK1 | cm^2/(V s) | 0 | -- | Coulomb scattering in back region |
| DEPMUEBACK1L | -- | 0 | -- | Lgate dependence |
| DEPMUEBACK1LP | -- | 1 | -- | Lgate dependence |

### Depletion Mode Parameters (CODEP=2 only)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| TNDEPV | V^-1 | 0.0 | -- | Vds dependence of surface layer thickness |
| DEPMUEA1 | -- | 0.0 | -- | Modification of mu_res |
| DEPMUE2 | cm^2/(V s) | 1e3 | [0, --] | Coulomb scattering of resistor part |
| DEPDDLT | -- | 3.0 (CODEP=2), 1.0 (CODEP=3) | -- | Smoothing coefficient for Vds,res |
| DEPVSATR | -- | 0 | -- | Vbs dependence of Vds,sat of resistor |
| DEPMUE2TMP | -- | 0.0 | -- | Temperature dependence of DEPMUE2 |
| DEPVFBC | V | -0.2 | -- | Flat-band voltage of resistor part |

### Depletion Mode Parameters (CODEP=3 only)

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DEPDVFBC | V | 0.1 | -- | Adjustment for gate effective voltage of resistor part |
| DEPCAR | m/V | 0 | -- | High field injection in resistor region |
| DEPRDRDL1 | m | 0.0 | -- | Pinch-off length in resistor region (for CLM) |
| DEPRDRDL2 | m | 0.0 | -- | Pinch-off length in resistor region (for mobility) |
| DEPRBR | -- | 1 | [0, 1] | Resistance effect along substrate (minority carrier) |
| DEPJLEAK | A/m^2 | 0 | [0, --] | Leakage current parameter for Jds,leak |
| DEPWLP | -- | 0 | -- | Geometrical scaling exponent for leakage current |
| DEPNINVDC | V^-1 | 100 | -- | Vdse dependence on Eeff (Coulomb mobility) |
| DEPNINVDH | V^-1 | 10 | -- | Vdse dependence on Eeff (phonon mobility) |
| DEPNINVDL | -- | 0 | -- | Lgate dependence of DEPNINVD |
| DEPNINVDLP | -- | 0 | -- | Lgate dependence of DEPNINVD |
| DEPNINVDW | -- | 0 | -- | Wgate dependence of DEPNINVD |
| DEPNINVDWP | -- | 0 | -- | Wgate dependence of DEPNINVD |
| DEPNINVDT1 | -- | 0 | -- | Temperature dependence |
| DEPNINVDT2 | -- | 0 | -- | Temperature dependence |
| DEPQF | V | 0.01 | [10e-9, 8] | Smoothing of Vds,sat to zero |
| DEPQFRES | V | 0.05 | [10e-9, 8] | Smoothing of Vds,sat,res to zero |
| DEPFDPD | V | 0.2 | [10e-9, 4] | Smoothing for FD/PD transition |
| DEPPS | V | 0.01 | -- | Smoothing for phi_S - phi_f |
| DEPVSATA | V | 0.0 | -- | Accumulation mode Vds,sat adjustment |
| DEPSUBSL0 | -- | DEPSUBSL | [10e-9, --] | Vbs dependence of subthreshold slope of Ires |

### Aging Model Parameters

| Parameter | Unit | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| DEGTIME | s | 0.0 | -- | Stress duration |
| DEGTIME0 | s | -- | -- | Circuit simulation duration |
| TRAPTAUCAP | s | 1e-6 | -- | Time constant of trap capture |
| TRAPLX | V | 1 | -- | Vds dependence of deep trap |
| TRAPGC1 | cm^-3 eV^-1 | 1e15 | -- | Deep trap density |
| TRAPGC1MAX | cm^-3 eV^-1 | 5e19 | -- | Time dependent deep trap |
| TRAPGCTIME1 | s | 30 | -- | Aging start time |
| TRAPGCTIME2 | s | 1e8 | -- | Aging saturation time |
| TRAPGCLIM | -- | 1e18 | -- | Limit of trap density |
| TRAPESLIM | -- | 5 | -- | Limit of trap density gradient |
| TRAPES1 | eV | 0.2 | -- | Deep trap density gradient |
| TRAPES1MAX | eV | 1 | -- | Time dependent deep trap density gradient |
| TRAPESTIME1 | s | 100 | -- | Aging start time |
| TRAPESTIME2 | s | 1e8 | -- | Aging saturate time |
| TRAPGC2 | cm^-3 eV^-1 | 5e13 | -- | Shallow trap density |
| TRAPES2 | eV | 0.03 | -- | Shallow trap density coefficient |
| TRAPN | -- | 1.0 | -- | Mobility degradation due to traps |
| TRAPP | -- | 1.0 | -- | Coefficient of BTI trap for Eeff |
| TRAPGC0 | -- | -- | -- | Midgap trap density (CODEGES0=1) |
| TRAPES0 | -- | -- | -- | Midgap trap density gradient (CODEGES0=1) |
| TRAPA | -- | -- | -- | Coefficient of existing interface trap density (NBTI) |
| TRAPB | -- | -- | -- | Coefficient of existing interface trap density (NBTI) |
| TRAPBTI | -- | -- | -- | Coefficient of existing interface trap density (NBTI) |
| TRAPD1MAX | cm^-3 eV^-1 | 30 | -- | Time dependent drift-region trap density |
| TRAPDTIME1 | s | 1000 | -- | Aging start time (drift) |
| TRAPDTIME2 | s | 2e10 | -- | Aging saturate time (drift) |
| TRAPDLX | -- | 1 | -- | Vds dependence of trap in drift region |
| TRAPDVDDP | -- | 0 | -- | Carrier type accumulated in drift region |

### Simulation Control Parameters

| Parameter | Unit | Default | Description |
|-----------|------|---------|-------------|
| VERSION | -- | 2.40 | Model version [2.20, 2.40] |
| GBMIN | -- | 1e-12 | Minimum conductance for circuit simulation |
| GDSLEAK | -- | 0 | Leakage conductance for circuit simulation |
| VGSMIN | V | -100 (nMOS), 100 (pMOS) | Minimum/maximum Vgs (fixed) |
| VZADD0 | V | 0.01 | Fixed smoothing constant |
| PZADD0 | V | 0.005 | Fixed smoothing constant |

### Instance Parameters

| Parameter | Unit | Default | Description |
|-----------|------|---------|-------------|
| L | m | 2e-6 | Gate length (Lgate) |
| W | m | 5e-6 | Gate width (Wgate) |
| NF | -- | 1 | Number of gate fingers |
| M | -- | 1 | Multiplication factor |
| AD | m^2 | -- | Area of drain junction |
| AS | m^2 | -- | Area of source junction |
| PD | m | -- | Perimeter of drain junction |
| PS | m | -- | Perimeter of source junction |
| NRS | -- | -- | Number of source squares |
| NRD | -- | -- | Number of drain squares |
| XGW | m | -- | Distance from gate contact to channel edge |
| XGL | m | -- | Offset of gate length |
| NGCON | -- | -- | Number of gate contacts |
| DTEMP | K | 0 | Device temperature change from TEMP |
| SA | m | -- | Length of diffusion between gate and STI |
| SB | m | -- | Length of diffusion between gate and STI |
| SD | m | -- | Length of diffusion between gate and gate |
| NSUBCDFM | cm^-3 | -- | Substrate impurity concentration (DFM) |
| RBPB | Ohm | 50 | Substrate resistance network |
| RBPD | Ohm | 50 | Substrate resistance network |
| RBPS | Ohm | 50 | Substrate resistance network |
| COSELFHEAT | -- | -- | Flag to switch on self-heating effect |
| COSUBNODE | -- | -- | Flag for selection of 5th node |

---

## Equations

### Device Size (Sec. 3)

$$L_{\text{gate}} = L_{\text{drawn}} + \text{XL}$$
(1)

$$W_{\text{gate}} = \frac{W_{\text{drawn}}}{\text{NF}} + \text{XW}$$
(2)

$$L_{\text{poly}} = L_{\text{gate}} - 2 \cdot \frac{\text{LL}}{(L_{\text{gate}} + \text{LLD})^{\text{LLN}}}$$
(3)

$$W_{\text{poly}} = W_{\text{gate}} - 2 \cdot \frac{\text{WL}}{(W_{\text{gate}} + \text{WLD})^{\text{WLN}}}$$
(4)

$$L_{\text{eff}} = L_{\text{poly}} - \text{XLD} - \text{XLDLD}$$
(5)

$$W_{\text{eff}} = W_{\text{poly}} - 2 \cdot \text{XWD}$$
(6)

$$W_{\text{eff,LD}} = W_{\text{poly}} - 2 \cdot \text{XWDLD}$$
(7)

$$W_{\text{effc}} = W_{\text{poly}} - 2 \cdot \text{XWDC}$$
(8)

### Charges (Sec. 4)

Oxide capacitance:

$$C_{\text{ox}} = \frac{\epsilon_0 \cdot \text{KAPPA}}{\text{TOX}}$$
(10)

Effective gate voltage:

$$V_G' = V_{gs} - \text{VFBC} + \Delta V_{th}$$
(11)

Inverse thermal voltage:

$$\beta = \frac{q}{kT}$$
(12)

Quasi-Fermi potential relationship:

$$\phi_f(L_{\text{eff}}) - \phi_f(0) = V_{ds,\text{eff}}$$
(13)

Effective drain-source voltage:

$$V_{ds,\text{eff}} = \frac{V_{ds}}{\left(1 + \left(\frac{V_{ds}}{V_{ds,\text{sat}}}\right)^\Delta\right)^{1/\Delta}}$$
(14)

**CODDLT=0:**

$$\Delta = \frac{\text{DDLTMAX} \cdot T1}{\text{DDLTMAX} + T1} + 1$$
(15)

$$T1 = \text{DDLTSLP} \cdot L_{\text{gate}} \cdot 10^6 + \text{DDLTICT}$$
(16)

**CODDLT=1 (default):**

$$\Delta = \frac{\text{DDLTMAX} \cdot T1}{\text{DDLTMAX} + T1} + \text{DDLTICT}$$
(17)

$$T1 = \text{DDLTSLP} \cdot L_{\text{gate}} \cdot 10^6$$
(18)

Saturation voltage:

$$V_{ds,\text{sat}} = V_G' + \frac{qN_{\text{sub}}\epsilon_{\text{Si}}}{C_{\text{ox}}^2}\left(1 - \sqrt{1 + \frac{2C_{\text{ox}}^2}{qN_{\text{sub}}\epsilon_{\text{Si}}}\left(V_G' - \frac{1}{\beta} - V_{bs}\right)}\right)$$
(19)

Equilibrium electron concentration:

$$n_{p0} = \frac{n_i^2}{p_{p0}}$$
(20)

Intrinsic carrier concentration:

$$n_i = n_{i0} \cdot T^{3/2} \cdot \exp\left(-\frac{E_g}{2q}\beta\right)$$
(21)

Bulk charge $Q_B$: (Eq. 22 -- full analytical expression in terms of $\phi_{S0}$, $\phi_{SL}$, $V_{bs}$, $\text{const}_0$, $C_{\text{ox}}$)

$$Q_B = -\frac{\mu(W_{\text{eff}} \cdot \text{NF})^2}{I_{ds}}\left[\text{const}_0 C_{\text{ox}}(V_G - \text{VFBC})\frac{1}{\beta^3}\left[\left(\beta(\phi_S - V_{bs}) - 1\right)^{3/2}\right]_{\phi_{S0}}^{\phi_{SL}} - \cdots\right]$$
(22)

where $\text{const}_0 = \sqrt{\frac{2\epsilon_{\text{Si}} q N_{\text{sub}}}{\beta}}$.

Inversion charge:

$$Q_I = -W L C_{\text{ox}}(VgVt)\frac{2}{3}\frac{1+\alpha+\alpha^2}{1+\alpha}$$
(23)

Drain charge:

$$Q_D = Q_I\left(\frac{3}{5} - \frac{1}{5}\frac{1+2\alpha}{(1+\alpha)(1+\alpha+\alpha^2)}\right)$$
(24)

$$\alpha = 1 - \frac{(1+\delta)(\phi_{SL} - \phi_{S0})}{VgVt}$$
(25)

$$VgVt = V_{gs} - \text{VFBC} + \phi_{S0} + \frac{\text{const}_0}{C_{\text{ox}}} BPS0^{1/2}$$
(26)

$$\delta = \frac{4}{3} C0_{\text{Cox}} \frac{1}{\beta}\frac{BPS_L^{3/2} - BPS_0^{3/2}}{(\phi_{SL}-\phi_{S0})^2} - 2C0_{\text{Cox}} \frac{1}{\beta}\frac{BPS_L^{1/2} - BPS_0^{1/2}}{(\phi_{SL}-\phi_{S0})^2} - 2C0_{\text{Cox}}\frac{BPS_0^{1/2}}{\phi_{SL}-\phi_{S0}}$$
(27)

where $C0_{\text{Cox}} = \text{const}_0/C_{\text{ox}}$, $BPS_L^{1/2} = \sqrt{\beta(\phi_{SL}-V_{bs})-1}$, $BPS_0^{1/2} = \sqrt{\beta(\phi_{S0}-V_{bs})-1}$.
(28)

### Drain Current (Sec. 5)

$$I_{ds} = \frac{W_{\text{eff}} \cdot \text{NF}}{L_{\text{eff}}} \cdot \mu \cdot \frac{I_{dd}}{\beta}$$
(29)

$$I_{dd} = C_{\text{ox}}(\beta V_G' + 1)(\phi_{SL} - \phi_{S0}) - \frac{\beta}{2}C_{\text{ox}}(\phi_{SL}^2 - \phi_{S0}^2) - \frac{2}{3}\text{const}_0\left[\left(\beta(\phi_{SL}-V_{bs})-1\right)^{3/2} - \left(\beta(\phi_{S0}-V_{bs})-1\right)^{3/2}\right] + \text{const}_0\left[\left(\beta(\phi_{SL}-V_{bs})-1\right)^{1/2} - \left(\beta(\phi_{S0}-V_{bs})-1\right)^{1/2}\right]$$
(30)

### Threshold Voltage Shift (Sec. 6)

**Short-channel effect:**

$$\Delta V_{th,SC} = \frac{\epsilon_{\text{Si}}}{C_{\text{ox}}} W_d \frac{dE_y}{dy}$$
(31)

$$W_d = \sqrt{\frac{2\epsilon_{\text{Si}}(2\Phi_B - V_{bs})}{qN_{\text{sub}}}}$$
(32)

$$2\Phi_B = \frac{2}{\beta}\ln\left(\frac{N_{\text{sub}}}{n_i}\right)$$
(33)

$$\frac{dE_y}{dy} = \frac{2(\text{VBI} - 2\Phi_B)}{(L_{\text{gate}} - \text{PARL2})^2}\left(\text{SC1} + \text{SC2}\cdot V_{ds}\cdot\{1+\text{SC4}\cdot(2\Phi_B-V_{bs})\} + \text{SC3}\cdot\frac{2\Phi_B-V_{bs}}{L_{\text{gate}}}\right)$$
(34)

**Reverse short-channel (retrograde):**

$$Q_{B,\text{mod}} = \sqrt{2q\cdot N_{\text{sub}}\cdot\epsilon_{\text{Si}}\cdot\left(2\Phi_B - V_{bs} - \frac{\text{BS1}}{\text{BS2}-V_{bs}}\right)}$$
(35)

**Pocket implant:**

$$\Delta V_{th,P} = (V_{th,R} - V_{th0})\frac{\epsilon_{\text{Si}}}{C_{\text{ox}}}W_d\frac{dE_{y,P}}{dy}$$
(36)

$$V_{th,R} = \text{VFBC} + 2\Phi_B + \frac{Q_{B,\text{mod}}}{C_{\text{ox}}} + \frac{1}{\beta}\log\left(\frac{N_{\text{subb}}}{N_{\text{subc}}}\right)$$
(37)

$$V_{th0} = \text{VFBC} + 2\Phi_{BC} + \frac{\sqrt{2qN_{\text{subc}}\epsilon_{\text{Si}}(2\Phi_{BC}-V_{bs})}}{C_{\text{ox}}}$$
(38)

$$\frac{dE_{y,P}}{dy} = \frac{2(\text{VBI}-2\Phi_B)}{LP^2}\left(\text{SCP1} + \text{SCP2}\cdot V_{ds} + \text{SCP3}\cdot\frac{2\Phi_B-V_{bs}}{LP}\right)$$
(39)

$$N_{\text{subb}} = 2\cdot\text{NSUBP} - \frac{(\text{NSUBP}-N_{\text{subc}})\cdot L_{\text{gate}}}{LP} - N_{\text{subc}}$$
(40)

$$\Phi_{BC} = \frac{1}{\beta}\ln\left(\frac{N_{\text{subc}}}{n_i}\right)$$
(41)

$$\Phi_B = \frac{1}{\beta}\ln\left(\frac{N_{\text{sub}}}{n_i}\right)$$
(42)

$$N_{\text{sub}} = \frac{N_{\text{subc}}(L_{\text{gate}}-LP) + \text{NSUBP}\cdot LP}{L_{\text{gate}}}$$
(43)

**Pocket small-Vds correction:**

$$\Delta V_{th,P} = \Delta V_{th,P} - \frac{\text{SCP22}}{(\text{SCP21}+V_{ds})^2}$$
(44)

**Pocket tail:**

$$N_{\text{sub}} = N_{\text{sub}} + \frac{\text{NPEXT}-N_{\text{subc}}}{xx^{-1} + \text{LPEXT}\cdot L_{\text{gate}}}$$
(45)

where $xx = 0.5\cdot L_{\text{gate}} - LP$.
(46)

### Punchthrough (Sec. 7)

$$I_{ds} = I_{ds,\text{intrinsic}} + I_{ds,\text{punch}} + I_{ds,\text{pinchoff}}$$
(47)

$$I_{ds,\text{punch}} = I_{\text{surfacePT}} + I_{\text{deepPT}}$$
(48)

**Shallow punchthrough:**

$$\text{POTENTIAL} = (\text{VBI} - \phi_{S0})^{\text{PTP}}$$
(49)

$$I_{\text{shallowPT}} = \frac{W_{\text{eff}}\cdot\text{NF}}{L_{\text{eff}}}\frac{\mu}{\beta}\cdot(\phi_{SL}-\phi_{S0})\cdot C_{\text{ox}}\cdot\beta\frac{\text{PTL}}{(L_{\text{gate}}\cdot10^6)^{\text{PTLP}}}\cdot\text{POTENTIAL}\cdot\left(1+\text{PT2}\cdot V_{ds}+\frac{\text{PT4}\cdot(\phi_{S0}-V_{bs})}{(L_{\text{gate}}\cdot10^6)^{\text{PT4P}}}\right)$$
(50)

**Deep punchthrough:**

$$I_{PT,\text{deep}} = J_{PT,\text{deep}}\cdot W_{\text{eff}}\cdot\text{NF}\cdot(1-\exp(-\beta V_{ds}))$$
(51)

$$J_{PT,\text{deep}} = \frac{2}{\beta L_{\text{eff}}}\cdot Q_{n0,PT}\cdot\text{MUPT}\cdot\exp(+\beta\phi_m)$$
(52)

$$Q_{n0,PT} = \sqrt{\frac{2q\cdot\text{NJUNC}\cdot\epsilon_{\text{Si}}}{\beta}}\sqrt{\beta\phi_{m,\text{gate}}}$$
(53)

$$\phi_m = \phi_{m,\text{gate}} + \phi_{m,SD}$$
(54)

$$\phi_{m,\text{gate}} = (\phi_{s,\text{deepPT}} - \phi_{m,SD})\cdot wfactor$$
(55)

$$wfactor = \begin{cases} 1 - \left(\frac{\text{XJPT}}{W_{\text{depl,PT}}}\right)^2 & W_{\text{depl,PT}} \geq \text{XJPT}\\ 0 & W_{\text{depl,PT}} < \text{XJPT} \end{cases}$$
(56)

$$W_{\text{depl,PT}} = \begin{cases} Q_{bu,PT}/(q\cdot N_{\text{subs}}) & \phi_{s,\text{deepPT}} \geq \phi_{m,SD}\\ 0 & \phi_{s,\text{deepPT}} < \phi_{m,SD} \end{cases}$$
(57)

$$Q_{bu,PT} = \text{const}_0\cdot\sqrt{\exp(-\beta(\phi_{s,\text{deepPT}}-\phi_{m,SD}))-1+\beta(\phi_{s,\text{deepPT}}-\phi_{m,SD})}$$
(58)

$$\phi_{m,SD} = -\frac{1}{4}\frac{(E_{\text{cri}}\cdot L_{\text{eff}})^2}{(E_{\text{cri}}\cdot L_{\text{eff}})+V_{ds}}$$
(59)

$$E_{\text{cri}} = \sqrt{\frac{2q(V_{bi}-V_{bs})}{\epsilon_{\text{Si}}}\frac{N_{\text{sub}}\cdot\text{NJUNC}}{N_{\text{sub}}+\text{NJUNC}}}$$
(60)

Flat-band voltage for deep punchthrough: $\text{VFBC} + \text{VFBPT}$
(61)

When PS0PT > 0:

$$J_{PT,\text{deep}} = \frac{2}{\beta L_{\text{eff}}}\cdot Q_{n0,PT}\cdot\text{MUPT}\cdot\exp\left[\beta(\phi_m-(V_{bi}-V_{bs}))\right]$$
(62)

**Channel conductance (high-field):**

$$I_{ds} = I_{ds} + \frac{W_{\text{eff}}\cdot\text{NF}}{L_{\text{eff}}}\frac{\mu}{\beta}\cdot(\phi_{SL}-\phi_{S0})\cdot\text{CONDUCTANCE}$$

$$\text{CONDUCTANCE} = C_{\text{ox}}\cdot\beta\frac{\text{GDL}}{(L_{\text{gate}}\cdot10^6+\text{GDLD}\cdot10^6)^{\text{GDLP}}}\cdot V_{ds}$$
(63)

### Poly-Si Gate Depletion (Sec. 8)

$$\phi_{Spg} = \text{PGD1}\left(1+\frac{1}{L_{\text{gate}}\cdot10^6}\right)^{\text{PGD4}}\exp\left(\frac{V_{gs}-\text{PGD2}}{V}\right)$$
(64)

### Quantum-Mechanical Effects (Sec. 9)

$$T_{\text{ox}} = \text{TOX} + \Delta T_{\text{ox}}$$
(65)

$$\Delta T_{\text{ox}} = \frac{\text{QME1}}{V_{gs} - V_{th}(T_{\text{ox}}=\text{TOX}) + \text{QME2}} + \text{QME3}$$
(66)

### Mobility (Sec. 10)

$$\frac{1}{\mu_0} = \frac{1}{\mu_{CB}} + \frac{1}{\mu_{PH}} + \frac{1}{\mu_{SR}}$$
(67)

$$\mu_{CB} = \text{MUECB0} + \text{MUECB1}\frac{Q_i}{q\cdot10^{11}}$$
(68)

$$\mu_{PH} = \frac{Muephonon}{E_{\text{eff}}^{\text{MUEPH0}}}$$
(69)

$$\mu_{SR} = \frac{Muesurface}{E_{\text{eff}}^{\text{MUESR1}}}$$
(70)

$$E_{\text{eff}} = E_{\text{eff0}}\cdot(1+\text{MUEEFB}\cdot V_{bs})$$
(71)

$$E_{\text{eff0}} = \frac{1}{\epsilon_{\text{Si}}}(Ndep\cdot Q_b + \text{NINV}\cdot Q_i)\cdot f(\phi_S)$$
(72)

$$f(\phi_S) = \frac{1}{1+(\phi_{SL}-\phi_{S0})\cdot Ninvd}$$
(73)

$$Ndep = \frac{\text{NDEP}}{1+\frac{\text{NDEPL}}{(L_{\text{gate}}/10^{-6})^{\text{NDEPLP}}}}$$
(75)

$$Ninvd = \text{NINVD}\cdot\left(1+\frac{\text{NINVDL}}{(L_{\text{gate}}/10^{-6})^{\text{NINVDLP}}}\right)$$
(76)

$$Muephonon = \text{MUEPH1}\cdot\left(1+\frac{\text{MUEPHL}}{(L_{\text{gate}}/10^{-6})^{\text{MUEPLP}}}\right)$$
(81)

$$Muesurface = \text{MUESR0}\cdot\left(1+\frac{\text{MUESRL}}{(L_{\text{gate}}/10^{-6})^{\text{MUESLP}}}\right)$$
(82)

High-field mobility:

$$\mu = \frac{\mu_0}{\left(1+\left(\frac{\mu_0 E_y}{V_{\text{max}}}\right)^{\text{BB}}\right)^{1/\text{BB}}}$$
(83)

Velocity overshoot:

$$V_{\text{max}} = \text{VMAX}\cdot\left(1+\frac{\text{VOVER}}{(L_{\text{gate}}/10^{-6})^{\text{VOVERP}}}\right)$$
(84)

### Channel-Length Modulation (Sec. 11)

$$\phi_S(\Delta L) = (1-\text{CLM1})\cdot\phi_{SL} + \text{CLM1}\cdot(\phi_{S0}+V_{ds})$$
(85)

$$\Delta L = \frac{1}{2}\left[-\frac{1}{L_{\text{eff}}}\left(\frac{I_{dd}}{\beta Q_i}z + 2\frac{qN_{\text{sub}}}{\epsilon_{\text{Si}}}(\phi_S(\Delta L)-\phi_{SL})z^2 + E_0 z^2\right) + \sqrt{\frac{1}{L_{\text{eff}}^2}\left(\cdots\right)^2 + 4\frac{2qN_{\text{sub}}}{\epsilon_{\text{Si}}}(\phi_S(\Delta L)-\phi_{SL})z^2 + E_0 z^2}\right]$$
(86)

where $E_0 = 10^5$ and:

$$z = \frac{\epsilon_{\text{Si}}\cdot W_d}{\text{CLM2}\cdot Q_b + \text{CLM3}\cdot Q_i}$$
(87)

$$\Delta L = \Delta L\left(1 + \text{CLM6}\cdot(L_{\text{gate}}\cdot10^6)^{\text{CLM5}}\right)$$
(88)

### Narrow-Channel Effects (Sec. 12)

$$\Delta V_{th,W} = \left(\frac{1}{C_{\text{ox}}} - \frac{1}{C_{\text{ox}}+2C_{ef}/(L_{\text{eff}}W_{\text{eff}})}\right)qN_{\text{sub}}W_d + \frac{\text{WVTH0}}{W_{\text{gate}}\cdot10^6}$$
(89)

$$C_{ef} = \frac{2\epsilon_{\text{ox}}}{\pi}L_{\text{eff}}\ln\left(\frac{2T_{\text{fox}}}{T_{\text{ox}}}\right) = \frac{\text{WFC}}{2}L_{\text{eff}}$$
(90)

Total threshold voltage shift:

$$\Delta V_{th} = \Delta V_{th,SC} + \Delta V_{th,R} + \Delta V_{th,P} + \Delta V_{th,W} - \phi_{Spg}$$
(91)

Width-dependent pocket concentration:

$$N_{\text{subp}} = \text{NSUBP}\cdot\left(1+\frac{\text{NSUBP0}}{(W_{\text{gate}}\cdot10^6)^{\text{NSUBWP}}}\right)$$
(92)

Width-dependent substrate concentration:

$$N_{\text{subc}} = \text{NSUBC}\cdot\left(1+\frac{\text{NSUBCW}}{(W_{\text{gate}}\cdot10^6)^{\text{NSUBCWP}}}\right)$$
(93)

Width-dependent phonon mobility:

$$Muephonon = Muephonon\cdot\left(1+\frac{\text{MUEPHW}}{(W_{\text{gate}}\cdot10^6)^{\text{MUEPWP}}}\right)$$
(94)

Width-dependent surface roughness:

$$Muesurface = Muesurface\cdot\left(1+\frac{\text{MUESRW}}{(W_{\text{gate}}\cdot10^6)^{\text{MUESWP}}}\right)$$
(95)

$$Ninvd = Ninvd\cdot\left(1+\frac{\text{NINVDW}}{(W_{\text{gate}}\cdot10^6)^{\text{NINVDWP}}}\right)$$
(96)

**STI leakage:**

$$\phi_{S,\text{STI}} = V_{gs,\text{STI}}' + \frac{\epsilon_{\text{Si}}Q_{N,\text{STI}}}{C_{\text{ox}}'^2}\left(1-\sqrt{1+\frac{2C_{\text{ox}}'^2}{\epsilon_{\text{Si}}Q_{N,\text{STI}}}(V_{gs,\text{STI}}'-V_{bs}-1/\beta)}\right)$$
(97)

$$Q_{N,\text{STI}} = q\cdot\text{NSTI}$$
(98)

$$V_{gs,\text{STI}}' = V_{gs} - \text{VFBC} + VthSTI + \Delta V_{th,\text{SCSTI}}$$
(99)

$$VthSTI = \text{VTHSTI} - \text{VDSTI}\cdot V_{ds}$$
(100)

$$\Delta V_{th,\text{SCSTI}} = \frac{\epsilon_{\text{Si}}}{C_{\text{ox}}}W_{d,\text{STI}}\frac{dE_y}{dy}$$
(101)

$$W_{d,\text{STI}} = \sqrt{\frac{2\epsilon_{\text{Si}}(2\Phi_{B,\text{STI}}-V_{bs})}{q\text{NSTI}}}$$
(102)

$$\frac{dE_y}{dy} = \frac{2(\text{VBI}-2\Phi_{B,\text{STI}})}{(L_{\text{gate,sm}}-\text{PARL2})^2}(\text{SCSTI1}+\text{SCSTI2}\cdot V_{ds})$$
(103)

$$L_{\text{gate,sm}} = L_{\text{gate}} + \frac{\text{WL1}}{wl^{\text{WL1P}}}$$
(104)

$$wl = (W_{\text{gate}}\cdot10^6)\times(L_{\text{gate}}\cdot10^6)$$
(105)

$$I_{ds,\text{STI}} = 2\frac{\text{WSTI}}{L_{\text{eff}}-\Delta L}\mu\frac{Q_{i,\text{STI}}}{\beta}(1-\exp(-\beta V_{ds}))$$
(106)

$$\text{WSTI}_{\text{eff}} = \text{WSTI}\left(1+\frac{\text{WSTIL}}{(L_{\text{gate,sm}}\cdot10^6)^{\text{WSTILP}}}\right)\left(1+\frac{\text{WSTIW}}{(W_{\text{gate,sm}}\cdot10^6)^{\text{WSTIWP}}}\right)$$
(107)

**Small geometry:**

$$\Delta V_{th} = \Delta V_{th,SC} + \Delta V_{th,R} + \Delta V_{th,P} + \Delta V_{th,W} + \Delta V_{th,sm} - \phi_{Spg}$$
(108)

$$\Delta V_{th,sm} = \frac{\text{WL2}}{wl^{\text{WL2P}}}$$
(109)

$$Muephonon = Muephonon\cdot\left(1+\frac{\text{MUEPHS}}{wl^{\text{MUEPSP}}}\right)$$
(110)

$$V_{\text{max}} = V_{\text{max}}\cdot\left(1+\frac{\text{VOVERS}}{wl^{\text{VOVERSP}}}\right)$$
(111)

### LOD / STI Stress Effects (Sec. 13)

$$N_{\text{substi}} = \frac{1+T_1\cdot T_2}{1+T_1\cdot T_3}$$
(112)

where $T_1 = 1/(1+\text{NSUBPSTI2})$, $T_2 = \text{NSUBPSTI1}^{\text{NSUBPSTI3}}/Lod_{\text{half}}$, $T_3 = \text{NSUBPSTI1}^{\text{NSUBPSTI3}}/Lod_{\text{half\_ref}}$.
(113)

$$N_{\text{subp}} = N_{\text{subp}}\cdot N_{\text{substi}}$$
(114)

$$Muesti = \frac{1+T_1\cdot T_2}{1+T_1\cdot T_3}$$
(115-116)

$$Muephonon = Muephonon\cdot Muesti$$
(117)

### Temperature Dependences (Sec. 14)

$$T_0 = \text{TEMP} + \text{DTEMP}$$
(118)

$$T = T_0 + \delta T$$
(119)

$$E_g = E_{g,\text{nom}} - \text{BGTMP1}\cdot(T-\text{TNOM}) - \text{BGTMP2}\cdot(T-\text{TNOM})^2$$
(120)

$$E_{g,\text{nom}} = \text{EG0} - 90.25\times10^{-6}\cdot\text{TNOM} - 1.0\times10^{-7}\cdot\text{TNOM}^2$$
(121)

$$n_i = n_{i0}\cdot T^{3/2}\cdot\exp\left(-\frac{E_g}{2q}\beta\right)$$
(122)

$$\mu_{PH}(\text{phonon}) = \frac{Muephonon}{(T/\text{TNOM})^{\text{MUETMP}}\cdot E_{\text{eff}}^{\text{MUEPH0}}}$$
(123)

$$V_{\text{max}} = \frac{\text{VMAX}}{1.8+0.4(T/\text{TNOM})+0.1(T/\text{TNOM})^2-\text{VTMP}\cdot(1-T/\text{TNOM})}$$
(124)

Gate current bandgap:

$$E_{gp} = E_{g0} + \text{EGIG} + \text{IGTEMP2}\left(\frac{1}{T}-\frac{1}{\text{TNOM}}\right) + \text{IGTEMP3}\left(\frac{1}{T^2}-\frac{1}{\text{TNOM}^2}\right)$$
(127)

**CORDRIFT=1 drift mobility temperature:**

$$\mu_{\text{drift0,temp}} = \frac{\text{RDRMUE}}{(T/\text{TNOM})^{\text{RDRMUETMP}}}$$
(128)

$$V_{\text{max\_drift,temp}} = \frac{\text{RDRVMAX}}{1.8+0.4(T/\text{TNOM})+0.1(T/\text{TNOM})^2-\text{RDRVTMP}\cdot(1-T/\text{TNOM})}$$
(129)

$$Rdrbb = \text{RDRBB} + \text{RDRBBTMP}(T-\text{TNOM})$$
(136)

**CORDRIFT=0 temperature:**

$$R_{d0,\text{temp}} = \text{RDTEMP1}\cdot(T_0-\text{TNOM}) + \text{RDTEMP2}\cdot(T_0^2-\text{TNOM}^2)$$
(137)

$$R_{dvd,\text{temp}} = \text{RDVDTEMP1}\cdot(T_0-\text{TNOM}) + \text{RDVDTEMP2}\cdot(T_0^2-\text{TNOM}^2)$$
(138)

Additional temperature dependencies:

$$V_{\text{max}} = \text{VMAX}\cdot(1+\text{VMAXT1}\cdot(T_0-\text{TNOM})+\text{VMAXT2}\cdot(T_0^2-\text{TNOM}^2))$$
(139)

$$Ninvd = Ninvd\cdot(1+\text{NINVDT1}\cdot(T_0-\text{TNOM})+\text{NINVDT2}\cdot(T_0^2-\text{TNOM}^2))$$
(140)

Aging temperature:

$$N_{tA}(T) = N_{tA}(\text{TNOM})\cdot(1+\text{TRAPTEMP1}\cdot(T_0-\text{TNOM})+\text{TRAPTEMP2}\cdot(T_0^2-\text{TNOM}^2))$$
(141)

### Resistances -- CORDRIFT=1 (Sec. 15.1)

**Drain side:**

$$R_{\text{drift}} = \frac{V_{ddp}}{I_{ddp}}\cdot T_{\text{drift}} + \text{RSH}\cdot\text{NRD}$$
(142)

$$I_{ddp} = W_{\text{eff,LD}}\cdot\text{NF}\cdot X_{ov}\cdot q\cdot N_{\text{drift}}\cdot\mu_{\text{drift}}\frac{V_{ddp}}{L_{\text{drift}}+\text{RDRDL1}}$$
(145)

$$W_{\text{dep,sub}} = \sqrt{\frac{2\epsilon_{\text{Si}}(\text{VBISUB}-(\text{RDVDSUB}\cdot V_{ds}+\text{RDVSUB}\cdot V_{\text{sub,s}}))}{q}\cdot\frac{\text{NSUBSUB}}{\text{NOVER}\cdot(\text{NSUBSUB}+\text{NOVER})}}$$
(146)

$$L_{\text{drift}} = \text{LDRIFT1} + \text{LDRIFT2}$$
(147)

$$\mu_{\text{drift}} = \frac{\mu_{\text{drift0}}}{\left(1+\left(\frac{\mu_{\text{drift0}}}{V_{\text{max\_drift}}}\cdot\frac{V_{ddp}}{L_{\text{drift}}}\right)^{Rdrbb}\right)^{1/Rdrbb}}$$
(148)

$$\mu_{\text{drift0}} = \mu_{\text{drift0,temp}}\left(1+\frac{\text{RDRMUEL}}{(L_{\text{gate}}\cdot10^6)^{\text{RDRMUELP}}}\right)$$
(149)

$$V_{\text{max\_drift}} = V_{\text{max\_drift,temp}}\left(1+\frac{\text{RDRVMAXL}}{(L_{\text{gate}}\cdot10^6)^{\text{RDRVMAXLP}}}\right)\left(1+\frac{\text{RDRVMAXW}}{(W_{\text{gate}}\cdot10^6)^{\text{RDRVMAXWP}}}\right)$$
(150)

$$X_{ov} = W_0 - \text{RDRCX}\cdot\left(\frac{W_0}{\text{RDRDJUNC}}W_{\text{dep}} + \frac{W_0}{\text{XLDLD}}W_{\text{junc}}\right)$$
(151)

$$W_0 = \sqrt{\text{XLDLD}^2 + \text{RDRDJUNC}^2}$$
(152)

$$W_{\text{dep}} = \sqrt{\frac{2\epsilon_{\text{Si}}(-\phi_{s,\text{over}})}{q\cdot\text{NOVER}}}$$
(153)

$$W_{\text{junc}} = \sqrt{\frac{2\epsilon_{\text{Si}}(V_{dps}-V_{bs}+V_{bi})}{q}\cdot\frac{N_{\text{sub}}}{\text{NOVER}(N_{\text{sub}}+\text{NOVER})}}$$
(154)

$$N_{\text{drift}} = \text{NOVER}\left(1+\text{RDRCAR}\frac{V_{ddp}}{L_{\text{drft}}-\text{RDRDL2}}\left(1-\frac{V_{ddp}}{1+\frac{\mu_{\text{drift0}}}{V_{\text{max\_drift}}}\cdot L_{\text{drift}}}\right)\right) + \text{RDRQOVER}\frac{-Q_{\text{over}}'}{q}$$
(155)

**Source side:**

$$R_{\text{source}} = \frac{V_{ssp}}{I_{ssp}}\cdot T_{\text{drifts}} + \text{RSH}\cdot\text{NRS}$$
(156)

$$I_{ssp} = W_{\text{eff,LD}}\cdot\text{NF}\cdot X_{ov}\cdot q\cdot\text{NOVERS}\cdot\mu_{\text{source}}\frac{V_{ssp}}{\text{LDRIFTS}}$$
(158)

### Resistances -- CORDRIFT=0 (Sec. 15.2)

$$V_{gs,\text{eff}} = V_{gs} - I_{ds}\cdot R_s$$
(162)

$$V_{ds,\text{eff}} = V_{ds} - I_{ds}\cdot(R_s + R_{\text{drift}})$$
(163)

$$R_s = \frac{\text{RS}}{W_{\text{eff,LD}}\cdot\text{NF}} + \text{NRS}\cdot\text{RSH}$$
(165)

Analytical resistance (CORSRD=2,3):

$$I_{ds} = \frac{I_{ds0}}{1+I_{ds0}\frac{R_d}{V_{ds}}}$$
(166)

$$R_d = \frac{1}{W_{\text{eff}}}R_d'\cdot V_{ds}^{\text{RD21}}(R_d' + V_{bs}\cdot V_{ds}^{\text{RD22D}}\cdot\text{RD22})$$
(167)

External node resistance (CORSRD=1,3):

$$R_{\text{drift}} = (R_d + V_{ds}\cdot\text{RDVD})\left(1+\text{RDVG11}-\frac{\text{RDVG11}}{\text{RDVG12}}\right)\cdot V_{gs}\cdot(1-V_{bs}\cdot\text{RDVB})\cdot T_{\text{drift}}$$
(171)

### Gate Resistance (Sec. 15.3)

$$R_g = \frac{\text{RSHG}\cdot(\text{XGW}+W_{\text{eff}}/(3\cdot\text{NGCON}))}{\text{NGCON}\cdot(L_{\text{drawn}}-\text{XGL})\cdot\text{NF}}$$
(179)

### Capacitances (Sec. 16)

Intrinsic capacitances:

$$C_{jk} = \delta\frac{\partial Q_j}{\partial V_k}, \quad \delta=-1 \text{ for } j\neq k, \quad \delta=1 \text{ for } j=k$$
(180)

Lateral-field charge:

$$Q_y = \epsilon_{\text{Si}} W_{\text{eff}}\cdot\text{NF}\cdot W_d\left(\frac{\phi_{S0}+V_{ds}-\phi_S(\Delta L)}{\text{XQY}}+\frac{\text{XQY1}}{L_{\text{gate}}^{\text{XQY2}}}V_{bs}\right)$$
(181)

**Overlap charge (surface-potential model):**

Depletion/accumulation:

$$Q_{\text{over}}' = \sqrt{\frac{2\epsilon_{\text{Si}} q\cdot\text{NOVER}}{\beta}}(\sqrt{\beta\phi_{s,\text{over}}}-1)$$

$$Q_{\text{over}} = W_{\text{eff}}\cdot\text{NF}\cdot L_{\text{overLD,mod}}\cdot Q_{\text{over}}'$$
(182)

Inversion:

$$Q_{\text{over}} = W_{\text{eff}}\cdot\text{NF}\cdot L_{\text{overLD,mod}}\cdot C_{\text{ox}}(V_{gs}-\text{VFBOVER}-\phi_{s,\text{over}})$$
(183)

$$Q_{\text{over,d}} = Q_{\text{over}} + W_{\text{eff}}\cdot\text{NF}\cdot\text{QOVADD}\cdot L_{\text{overLD,mod}}\cdot(V_{dp}-V_{ch})$$
(184)

$$V_{ch} = \phi_{SL} - \phi_{S0}$$
(185)

$$C_{ov} = (1-\text{CVDSOVER})\cdot C_{ov}(\text{int})+\text{CVDSOVER}\cdot C_{ov}(\text{ext})$$
(186)

**Simplified bias-dependent overlap:**

$$Q_{god} = W_{\text{eff}}\cdot\text{NF}\cdot C_{\text{ox}}[(V_{gs}-V_{ds})\text{LOVERLD}-\text{OVSLP}\cdot(1.2-(\phi_{SL}-V_{ds}))\cdot(\text{OVMAG}+(V_{gs}-V_{ds}))]$$
(189)

Constant overlap:

$$C_{ov} = \frac{\epsilon_{\text{ox}}}{\text{TOX}}\cdot\text{LOVERLD}\cdot W_{\text{eff}}\cdot\text{NF}$$
(190)

$$C_{gbo\_loc} = -\text{CGBO}\cdot L_{\text{gate}}$$
(191)

**Bias-dependent overlap length:**

$$L_{\text{overLD,mod}} = \text{LOVERLD} - W_{\text{junc,ov}}$$
(192)

$$W_{\text{junc,ov}} = \text{QOVJUNC}\cdot\sqrt{\frac{2\epsilon_{\text{Si}}(V_x+V_{bi})}{q}\cdot\frac{N_{\text{sub}}}{\text{NOVER}(N_{\text{sub}}+\text{NOVER})}}$$
(193)

Extrinsic fringing capacitance:

$$C_f = \frac{\epsilon_{\text{ox}}}{\pi/2}\cdot W_{\text{gate}}\cdot\text{NF}\cdot\ln\left(1+\frac{\text{TPOLY}}{T_{\text{ox}}}\right)$$
(195)

**Trench overlap:**

$$L_{\text{overLD,mod}} = \text{LOVERLD}+\text{WTRENCH}-W_{\text{junc,ov}}$$
(196)

$$V_{xdb} = \frac{V_{db}}{\left(1+\left(\frac{V_{db}}{V_{db,\text{lim}}}\right)^{\text{OLMDLT}}\right)^{1/\text{OLMDLT}}}$$
(198)

### Substrate Current (Sec. 17.1)

$$I_{\text{sub}} = X_{\text{sub1}}\cdot\Psi_{\text{subsat}}\cdot I_{ds}\cdot\exp\left(-\frac{X_{\text{sub2}}}{\Psi_{\text{subsat}}}\right)$$
(201)

$$X_{\text{sub1}} = \text{SUB1}\cdot\left(1+\frac{\text{SUB1L}}{L_{\text{gate}}^{\text{SUB1LP}}}\right)\cdot X_{\text{subTmp}}$$
(202)

$$X_{\text{sub2}} = \text{SUB2}\cdot\left(1+\frac{\text{SUB2L}}{L_{\text{gate}}}\right)\cdot\frac{1}{X_{\text{subTmp}}}$$
(203)

$$\Psi_{\text{subsat}} = \text{SVDS}\cdot V_{ds}+\phi_{S0}-\frac{L_{\text{gate}}\cdot\Psi_{\text{slsat}}}{X_{\text{gate}}+L_{\text{gate}}}$$
(204)

$$X_{\text{gate}} = \text{SLG}\cdot\left(1+\frac{\text{SLGL}}{L_{\text{gate}}^{\text{SLGLP}}}\right)$$
(205)

$$X_{\text{subTmp}} = 1.0+\text{SUBTMP}\cdot(T-\text{TNOM})$$
(209)

**Impact-ionization bulk potential change:**

$$\Delta V_{\text{bulk}} = IBPC1\cdot(1+\text{IBPC2}\cdot\Delta V_{th})\cdot I_{\text{sub}}$$
(211)

**Impact-ionization in drift region:**

$$I_{\text{subLD}} = I_{ds}\cdot SUBLD1\cdot E_y\cdot L_{\text{drift}}\cdot\exp\left(\frac{-\text{SUBLD2}}{E_y\cdot f(VgVt)}\right)$$
(213)

### Gate Current (Sec. 17.2)

**Gate-to-channel:**

$$I_{\text{gate}} = q\cdot\text{GLEAK1}\cdot\frac{E^2}{E_{gp}^{3/2}}\cdot\exp\left(-\text{GLEAK2}\frac{E_{gp}^{3/2}}{E}\right)\cdot\sqrt{\frac{Q_i}{\text{const}_0}}\cdot W_{\text{eff}}\cdot\text{NF}\cdot L_{\text{eff}}\cdot\frac{\text{GLEAK6}}{\text{GLEAK6}+V_{ds}}\cdot\frac{\text{GLEAK7}}{\text{GLEAK7}+W_{\text{eff}}\cdot\text{NF}\cdot L_{\text{eff}}}$$
(220)

$$E = \frac{\{V_G-\text{GLEAK3}\cdot\phi_S(\Delta L)\}^2}{T_{\text{ox}}}\cdot\left(1+\frac{E_y}{\text{GLEAK5}}\right)$$
(221)

**Gate-to-bulk:**

$$I_{gb} = \text{GLKB1}\cdot E_{gb}^2\cdot\exp\left(-\frac{\text{GLKB2}}{E_{gb}}\right)\cdot W_{\text{eff}}\cdot\text{NF}\cdot L_{\text{eff}}$$
(228)

**Fowler-Nordheim:**

$$I_{FN} = \frac{q\cdot\text{FN1}\cdot E_{FN}^2}{E_g^{1/2}}\cdot\exp\left(-\frac{\text{FN2}\cdot E_g^{3/2}}{E_{FN}}\right)\cdot W_{\text{eff}}\cdot\text{NF}\cdot L_{\text{eff}}$$
(230)

**Gate-to-source/drain:**

$$I_{gs} = \text{sign}\cdot\text{GLKSD1}\cdot E_{gs}^2\exp(\text{TOX}(-\text{GLKSD2}\cdot V_{gs}+\text{GLKSD3}))\cdot W_{\text{eff}}\cdot\text{NF}$$
(235)

$$I_{gd} = \text{sign}\cdot\text{GLKSD1}\cdot E_{gd}^2\exp(\text{TOX}(\text{GLKSD2}\cdot(-V_{gs}+V_{ds})+\text{GLKSD3}))\cdot W_{\text{eff}}\cdot\text{NF}$$
(237)

### GIDL (Sec. 17.3)

$$I_{\text{GIDL}} = q\cdot\text{GIDL1}\cdot\frac{E^2}{E_{g2}}\cdot\exp\left(-\text{GIDL2}\cdot\frac{E_{g2}^3}{E}\right)\cdot W_{\text{eff}}\cdot\text{NF}\cdot A$$
(240)

$$E = \frac{\text{GIDL3}\cdot(V_{ds}+\text{GIDL4})-V_G'}{T_{\text{ox}}}$$
(241)

$$A = \frac{V_{db}^3}{V_{db}^3+0.5}$$
(243)

### Diode Current (Sec. 18)

**Region a: $V_{b\theta} < V_1$:**

$$I_{b\theta} = I_{sb\theta}\left(\exp\frac{V_{b\theta}}{Nvtm}-1\right) + I_{sb\theta 2}\cdot C_{isb}\cdot\left(\exp\frac{-V_{b\theta}\cdot CVB\Theta}{Nvtm}-1\right) + \text{CISBK}\Theta\cdot\left(\exp\frac{-V_{b\theta}\cdot CVB\Theta}{Nvtm}-1\right) + \text{DIVX}\Theta\cdot I_{sb\theta 2}\cdot V_{b\theta}$$
(250)

**Region b: $V_{b\theta} \geq V_1$ (linearized):**

$$I_{b\theta} = I_{sb\theta}\left(\exp\frac{V_1}{Nvtm}-1\right)+\frac{I_{sb\theta}}{Nvtm}\exp\frac{V_1}{Nvtm}(V_{b\theta}-V_1)+\cdots$$
(251)

$$Nvtm = \frac{NJ\Theta}{\beta}$$
(271)

$$V_1 = Nvtm\cdot\log\left(\frac{Vdiffj}{I_{sb\theta}}+1\right)$$
(272)

Forward current densities:

$$js = \text{JS0}\Theta\cdot\exp\frac{E_g(\text{TNOM})\beta(\text{TNOM})-E_g\beta+\text{XTI}\Theta\cdot\log(Ttnom)}{NJ\Theta}$$
(276)

### Diode Capacitance (Sec. 18.2)

$V_{\text{arg}} < 0$:

$$Q_{b\theta,\text{btm}}(V_{\text{arg}}) = \frac{PB\Theta\cdot czb\theta\{1-(1-V_{\text{arg}}/PB\Theta)^{1-MJ\Theta}\}}{1-MJ\Theta}$$
(290)

$V_{\text{arg}} \geq 0$:

$$Q_{b\theta,\text{btm}}(V_{\text{arg}}) = czb\theta\cdot V_{\text{arg}}+\frac{1}{2}\frac{czb\theta\cdot MJ\Theta}{PB\Theta}\cdot V_{\text{arg}}^2$$
(293)

Temperature dependence:

$$CJ\Theta = CJ\Theta\cdot(1+\text{TCJB}\Theta\cdot(T-\text{TNOM}))$$
(299)

### Hard Breakdown (Sec. 19)

$$I_{\text{hbreak}} = \text{HBDF}\cdot\exp(\beta\cdot(V_{dse}-HBdv))$$
(302)

$$HBdv_{\text{base}} = \text{HBDA}\cdot(V_{gs}-\text{HBDB})^2+HBDCeff$$
(307)

$$HBDCeff = \text{HBDC}+\text{HBDCTMP}\cdot(T-\text{TNOM})$$
(308)

### Snapback (Sec. 19.2)

$$I_{\text{bjt}} = (1+X_{\text{sub1SNP}}\cdot\Psi_{\text{subsat\_SNP}}\cdot\exp(-X_{\text{sub2SNP}}/\Psi_{\text{subsat\_SNP}}))\cdot I_{bs}$$
(309)

### 1/f Noise (Sec. 20.1)

$$S_{Ids} = \frac{I_{ds}^2\cdot\text{NFTRP}}{\beta f(L_{\text{eff}}-\Delta L)W_{\text{eff}}\cdot\text{NF}}\left(\frac{1}{(N_0+N^*)(N_L+N^*)}+\frac{2\mu E_y\cdot\text{NFALP}}{N_L-N_0}\ln\frac{N_L+N^*}{N_0+N^*}+(\mu E_y\cdot\text{NFALP})^2\right)$$
(313)

$$N^* = \frac{C_{\text{ox}}+C_{\text{dep}}+\text{CIT}}{q\beta}$$
(314)

$$N_{\text{flick}} = S_{Ids}\cdot f^{\text{FALPH}}$$
(315)

### Thermal Noise (Sec. 20.2)

$$S_{id} = 4kT\frac{W_{\text{eff}}\cdot\text{NF}\cdot C_{\text{ox}}\cdot VgVt\cdot\mu}{L_{\text{eff}}-\Delta L}\frac{(1+3\eta+6\eta^2)\mu_d^2+(3+4\eta+3\eta^2)\mu_d\mu_s+(6+3\eta+\eta^2)\mu_s}{15(1+\eta)\mu_{\text{av}}^2}$$
(319)

$$\eta = 1-\frac{(\phi_{SL}-\phi_{S0})+\chi(\phi_{SL}-\phi_{S0})}{VgVt}$$
(320)

### NQS Model (Sec. 21)

$$q(t_i) = \frac{q(t_{i-1})+\frac{\Delta t}{\tau}Q(t_i)}{1+\frac{\Delta t}{\tau}}$$
(325)

$$\tau_{\text{diff}} = \text{DLY1}$$
(326)

$$\tau_{\text{cond}} = \text{DLY2}\cdot\frac{Q_i}{I_{ds}}$$
(327)

$$\frac{1}{\tau} = \frac{1}{\tau_{\text{diff}}}+\frac{1}{\tau_{\text{cond}}}$$
(328)

$$\tau_B = \text{DLY3}\cdot C_{\text{ox}}$$
(329)

$$\tau_{LD} = \text{DLYOV}\cdot C_{\text{ox0}}\cdot\phi_{s,LD}$$
(330)

### Self-Heating (Sec. 22)

$$T = T + R_{th}\cdot I_{ds}\cdot V_{ds}$$
(331)

$$R_{th} = \frac{R_{th0}}{W_{\text{eff}}}\cdot\frac{1}{\text{NF}^{\text{RTH0NF}}}\left(1+\frac{\text{RTH0L}}{(L_{\text{gate}}/10^{-6})^{\text{RTH0LP}}}\right)\left(1+\frac{\text{RTH0W}}{(W_{\text{gate}}/10^{-6})^{\text{RTH0WP}}}\right)$$
(332)

$$R_{th0} = \text{RTH0}+\text{RTHTEMP1}\cdot(T_0-\text{TNOM})+\text{RTHTEMP2}\cdot(T_0^2-\text{TNOM}^2)$$
(333)

$$C_{th} = \text{CTH0}\cdot W_{\text{eff}}$$
(334)

Thermal dissipation:

$$V_{ds}' = V_{dsi}+\text{POWratio}\cdot(V_{ds}-V_{dsi})$$
(336)

$$\text{POWratio} = \text{POWRAT}+\text{PRATTEMP1}\cdot(T_0-\text{TNOM})+\text{PRATTEMP2}\cdot(T_0^2-\text{TNOM}^2)$$
(337)

### DFM (Sec. 24)

$$Muephonon = \text{MUEPH1}[\text{MPHDFM}\{\ln(\text{NSUBCDFM})-\ln(N_{\text{subc}})\}+1]$$
(338)

### Binning (Sec. 27)

$$\text{Bin\_param} = \text{param} + \frac{P1}{L_{\text{bin}}} + \frac{P2}{W_{\text{bin}}} + \frac{P3}{L_{\text{bin}}W_{\text{bin}}}$$
(504)

$$L_{\text{bin}} = (L_{\text{gate}}\cdot10^6)^{\text{LBINN}}$$
(505)

$$W_{\text{bin}} = (W_{\text{gate}}\cdot10^6)^{\text{WBINN}}$$
(506)

### Depletion Mode (CODEP=3, Sec. 25.3)

**Accumulation current:**

$$I_{ds} = \frac{W_{\text{eff}}}{L_{\text{eff}}}\cdot\text{NF}\cdot\frac{1}{\beta}(\mu\cdot I_{dd})+I_{ds,\text{res}}$$
(427)

$$I_{dd} = -\beta\frac{Q_{n0}+Q_{nl}}{2}\cdot(\phi_{SL}-\phi_{S0})$$
(428)

**Resistor current:**

$$I_{ds,\text{res}} = I_{\text{res}} + I_{\text{res,leak}}$$
(439)

$$I_{\text{res}} = q\cdot\text{NF}\cdot N_{\text{res}}\cdot\mu_{\text{res}}\cdot W_{\text{res}}\cdot W_{\text{eff}}\cdot E_{\text{dri}}$$
(440)

$$E_{\text{dri}} = \frac{V_{ds,\text{res}}}{L_{\text{eff}}'+\text{DEPRDRDL1}}$$
(441)

**Resistor leakage:**

$$I_{\text{res,leak}} = \text{NF}\cdot W_{\text{res,leak}}\cdot\text{DEPJLEAK}\cdot\left(\frac{W_{\text{eff}}}{L_{\text{eff}}}\right)^{\text{DEPWLP}}\cdot\frac{V_{ds,\text{res0}}^3}{V_{ds,\text{res0}}^3+0.0005}$$
(468)

### Aging -- HC Model (Sec. 26.1)

Trap density in Poisson equation:

$$\nabla^2\phi = -\frac{q}{\epsilon_{\text{Si}}}(p-n+N_D-N_A-N_{tA})$$
(475)

$$N_{tA} = N_{tA1}+N_{tA2}$$
(476)

$$N_{tA,n} = N_{0,n}\exp\left(\frac{E_f-E_c}{E_{s,n}}\right)$$
(477)

Deep trap level:

$$gc_{1,\text{deg}} = \text{TRAPGC1}+\frac{\text{TRAPGC1MAX}}{gc\_time_1}\exp\left(-\frac{1}{2}\left(\frac{gc\_time-gc\_time_2}{gc\_time_1}\right)^2\right)$$
(480)

### Aging -- NBTI Model (Sec. 26.1.2)

$$\delta V_{th,\text{trap}} = \text{TRAPA}\cdot\exp(\text{TRAPB}\cdot E_{\text{ox}})\cdot\left(1-\exp\left(-\frac{t_s}{\text{TRAPBTI}}\right)\right)$$
(492)

### Aging -- Drift Region (Sec. 26.2)

$$N_{\text{drift}} = N_{\text{drift}} + \text{NOVER}\cdot Dvddp$$
(496)

$$Dvddp = Dvddp_{\text{deg}}\cdot\exp\left(-\frac{V_{ds,\text{eff}}-\phi_{SL}+\phi_{S0}}{\text{TRAPDLX}}\right)$$
(497)
