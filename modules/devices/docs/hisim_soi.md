# HiSIM-SOI 1.5.0 — Parameter & Equation Reference

> SOI MOSFET

## Model Topology

HiSIM SOI models an SOI-MOSFET with four external terminals (Drain=1, Gate=2, Source=3, Substrate=4) plus optional 5th (Body) and 6th (Thermal) nodes. When COBCNODE=1, Body=5 and Thermal=6; when COBCNODE=0, Thermal=5. The model solves the Poisson equation iteratively across the SOI layer (front oxide / SOI film / buried oxide / substrate) to determine surface potentials, automatically handling fully-depleted (FD), partially-depleted (PD), floating-body (FB), and body-tie (BT) conditions. Internal nodes SP and DP represent source-side and drain-side drift-region connections for parasitic resistance modeling.

## Parameters

### Model Selection Flags

| Parameter | Default | Description |
|-----------|---------|-------------|
| COBCNODE | 0 | 5th node selector: 0=floating body, 1=body tie |
| COADOV | 1 | Overlap and lateral-field charges: 0=no, 1=yes |
| COISUB | 0 | Substrate current: 0=no, 1=yes |
| COFBE | 0 | Floating-body effect: 0=no, 1=yes (requires COISUB=1), 2=body-tie FBE |
| COIIGS | 0 | Gate current: 0=no, 1=yes |
| COGIDL | 0 | GIDL current: 0=no, 1=yes |
| COOVLP | 0 | Overlap capacitance: 0=constant, 1=bias-dependent |
| COQOVSM | 1 | Overlap surface potential: 0=analytical, 1=iterative |
| COQBDSM | 1 | Body-contact MOS cap: 0=analytical, 1=iterative |
| COIGN | 0 | Induced gate noise: 0=no, 1=yes (requires COTHRML=1) |
| COFLICK | 0 | 1/f noise: 0=no, 1=yes |
| COTHRML | 0 | Thermal noise: 0=no, 1=yes |
| COISTI | 0 | STI leakage current: 0=no, 1=yes |
| CONQS | 0 | Non-quasi-static mode: 0=no, 1=yes |
| CORD | 0 | Drain resistance: 0=no, 1=yes |
| CORS | 0 | Source resistance: 0=no, 1=yes |
| CORG | 0 | Gate resistance: 0=no, 1=yes |
| CORBNET | 0 | Body resistance network: 0=no, 1=yes |
| COPPRV | 0 | Previous phi_s for iteration: 0=no, 1=yes |
| COSELFHEAT | 0 | Self-heating: 0=no, 1=yes |
| COHIST | 0 | History effect: 0=no, 1=yes |
| COIEVB | 0 | Valence-band electron tunneling: 0=no, 1=yes |
| COVBSBIZ | 0 | Symmetry treatment: 0=no, 1=yes |
| COLGLEFF | 0 | Use Leff instead of Lgate: 0=no, 1=yes |
| COOLDVER | 0 | Backward compatibility with HiSIM SOI 1.1.1: 0=no, 1=yes |
| COPT | 0 | Punchthrough model: 0=no, 1=yes |
| COSUBSCALE | 0 | Substrate current scaling: 0=backward compat, 1=new |
| COISUBFB | 0 | Re-evaluate body current after Poisson solution for FB: 0=no, 1=yes |
| COPSPT | 0 | (Flag for punchthrough sub-option) |
| CORBULK | 0 | Bulk resistance model: 0=no, 1=yes |
| INFO | 0 | Information output level |

### Basic Device Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VERSION | — | — | 1.50 | [1.00, 1.30] | Model version selector |
| TYPE | — | — | 1 | {-1, 1} | 1 for NMOS, -1 for PMOS |
| TFOX | $T_{FOX}$ | m | 3.5e-9 | (0, 50e-9] | Front gate oxide thickness |
| TBOX | $T_{BOX}$ | m | 110e-9 | (0, 100e-9] | Buried oxide thickness |
| TSOI | $T_{SOI}$ | m | 50e-9 | (0, 100e-9] | Silicon film (SOI layer) thickness |
| XJ | $X_j$ | m | 50e-9 | [0, 100e-9] | Impurity doping depth |
| NSUBS | $N_{subs}$ | cm^-3 | 3e17 | [1e14, 1e19] | SOI layer impurity concentration |
| NSUBB | $N_{subb}$ | cm^-3 | 4e14 | (0, 1e19] | Substrate impurity concentration |
| NSUBP | $N_{subp}$ | cm^-3 | 1e17 | [1e16, —] | Max pocket impurity concentration |
| VFBC | $V_{FBC}$ | V | -1 | [-1.2, -0.8] | Flat-band voltage |
| VBI | $V_{BI}$ | V | 1.1 | [1, 1.2] | Built-in potential |
| NF | — | — | 1 | [1, —] | Number of gate fingers |
| XLD | $XLD$ | m | 0 | [-10e-9, 50e-9] | Gate overlap length |
| XWD | $XWD$ | m | 0 | [-10e-9, 100e-9] | Gate overlap width |
| XLDC | $XLDC$ | m | 0 | [-10e-9, 100e-9] | Length overlap for capacitance (defaults to XLD) |
| XWDC | $XWDC$ | m | 0 | [-10e-9, 100e-9] | Width overlap for capacitance (defaults to XWD) |
| TPOLY | $T_{POLY}$ | m | 0 | [0, —] | Poly-Si gate height for fringing cap |
| LDRIFT | — | m | 1e-6 | (0, —] | Length of drift region (drain side) |
| LDRIFTS | — | m | 1e-6 | (0, —] | Length of drift region (source side) |

### Smoothing Parameters (Vds)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| DDLTMAX | $\Delta_{MAX}$ | — | 10 | [0, 20] | Smoothing coefficient for Vds |
| DDLTSLP | — | um^-1 | 10 | [0, 20] | Lgate-dependence of smoothing coefficient |
| DDLTICT | — | — | 0 | [-3, 20] | Lgate-dependence of smoothing coefficient |
| SUBDLT | — | — | 2e-3 | — | Smoothing parameter (FB only) |

### Mobility and Velocity Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| MUECB0 | $\mu_{CB0}$ | cm^2/(V*s) | 300 | [100, 100k] | Coulomb scattering constant |
| MUECB1 | $\mu_{CB1}$ | cm^2/(V*s) | 30 | [15, 10k] | Coulomb scattering coefficient |
| MUEPH0 | — | — | 0.3 | [0.25, 0.3] | Phonon scattering exponent |
| MUEPH1 | — | (V/cm)^MUEPH0 | 25000 (NMOS) / 9000 (PMOS) | [2k, 30k] | Phonon scattering coefficient |
| MUETMP | — | — | 1.5 | [0.5, 2.2] | Temperature-dependence of phonon scattering |
| MUEPHL | — | — | 0 | — | L-dependence of phonon mobility reduction |
| MUEPLP | — | — | 1 | — | L-dependence exponent for phonon mobility |
| MUESR0 | — | — | 2 | — | Surface-roughness scattering exponent |
| MUESR1 | — | cm^2/(V*s) | 2e15 | — | Surface-roughness scattering coefficient |
| MUESRL | — | — | 0 | — | L-dependence of surface roughness mobility |
| MUESLP | — | — | 1 | — | L-dependence exponent for surface roughness |
| NDEP | — | — | 1 | [0, 1] | Depletion charge contribution to Eeff |
| NINV | — | — | 0.5 | [0, 1] | Inversion charge contribution to Eeff |
| NINVD | — | V^-1 | 0 | — | Reduced resistance effect for small Vds |
| BB | — | — | 2 (NMOS) / 1 (PMOS) | — | High-field mobility degradation exponent |
| VMAX | $V_{max}$ | cm/s | 7e6 | [1e6, 2e7] | Maximum saturation velocity |
| VOVER | — | — | 0.01 | [0, 1] | Velocity overshoot effect |
| VOVERP | — | — | 0.1 | [0, 2] | Leff-dependence of velocity overshoot |
| VTMP | — | — | 0 | [-2, 1] | Temperature-dependence of saturation velocity |

### Short-Channel Effect Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| PARL1 | — | m | 10e-9 | [0, 50e-9] | SOI SCE parameter |
| PARL2 | — | m | 10e-9 | [0, 50e-9] | Depletion width of channel/contact junction |
| SC1 | — | — | 0 | [0, 20] | Magnitude of short-channel effect |
| SC2 | — | V^-1 | 0 | [0, 2] | Vds-dependence of short-channel effect |
| SC3 | — | m*V^-1 | 0 | [0, 100e-9] | Vbs-dependence of short-channel effect |
| SCR1 | — | — | 0 | [0, 5] | SCE via BOX parameter |
| SCR2 | — | — | 0 | [0, 5] | SCE via BOX Vds parameter |
| SCR3 | — | — | 0.23 | [0, 1] | SCE via BOX parameter |
| SCP1 | — | — | 0 | [0, 20] | Short-channel effect due to pocket |
| SCP2 | — | V^-1 | 0 | [0, 2] | Vds-dependence of SCE due to pocket |
| SCP3 | — | m*V^-1 | 0 | [0, 100e-9] | Vbs-dependence of SCE due to pocket |
| LP | $L_P$ | m | 0 | [0, 300e-9] | Pocket penetration length |

### Flat-Band Voltage Shift (Mechanical Stress)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VFBCL1 | — | — | — | — | Channel length dependence of flat-band voltage |
| VFBCL1P | — | — | — | — | Channel length dependence exponent |
| VFBCL2 | — | — | — | — | Channel length dependence of flat-band voltage |
| VFBCL2P | — | — | — | — | Channel length dependence exponent |
| VFBHAMP | — | — | — | — | Channel length dependence of flat-band voltage |

### Poly-Si Gate Depletion Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| PGD1 | — | V | 0 | [0, 50e-3] | Strength of poly-depletion effect |
| PGD2 | — | V | 1 | [0, 1.5] | Threshold voltage of poly-depletion |
| PGD4 | — | — | 0 | [0, 3] | Lgate-dependence of poly-depletion |

### Quantum Mechanical Effect Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| QME1 | — | mV | 0 | [0, 300e-9] | Vgs-dependence of quantum mechanical effect |
| QME2 | — | V | 0 | [0, 3] | Vgs-dependence of quantum mechanical effect |
| QME3 | — | m | 0 | [0, 800e-12] | Minimum TFOX modification |

### Channel-Length Modulation Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CLM1 | — | — | 0.7 | [0.5, 1] | Abruptness coefficient of channel/contact junction |
| CLM2 | — | — | (5e9/(TSOI*NSUBS)) or given | [2, 5] | Coefficient for QB contribution |
| CLM3 | — | — | 1 | [1, 5] | Coefficient for QI contribution |
| CLM5 | — | — | 1 | [0, 5] | CLM parameter (pocket effect) |
| CLM6 | — | — | 0 | [0, 5] | CLM parameter (pocket effect) |

### Punchthrough Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| PTL | — | V^(1-PTP) | 0 | [0, —] | Strength of shallow punchthrough |
| PTLP | — | — | 1 | — | Lgate dependence of shallow punchthrough |
| PTP | — | — | 3.5 | [3, 4] | Power exponent for shallow punchthrough |
| PT2 | — | V^-1 | 0 | — | Vds dependence of punchthrough |
| PT4 | — | — | 0 | — | Vbs dependence of punchthrough |
| PT4P | — | — | 1 | — | Vbs exponent for punchthrough |
| NJUNC | — | cm^-3 | 1e20 | (0, —] | Source/drain junction dopant concentration |
| XJPT | — | m | TSOI | (0, 1.2*TSOI] | Effective junction depth for deep punchthrough |
| MUPT | — | m^2/(V*s) | 0 | [0, —] | Effective mobility for deep punchthrough |
| VFBPT | — | V | 0 | — | Flat-band voltage shift for deep punchthrough |
| PSLIMPT | — | V | 0 | [0, 220e-3] | Potential limiter for deep punchthrough |
| GDL | — | — | 0 | — | Strength of high-field effect (channel conductance) |
| GDLP | — | — | 0 | — | Lgate dependence of channel conductance |
| GDLD | — | m | 0 | — | Lgate offset for channel conductance |

### Narrow-Channel Effect Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| WFC | — | F/(cm^2 * m) | 0 | [-5e-15, 1e-6] | Edge-fringing capacitance for Vth |
| WVTH0 | — | V*um | 0 | — | Threshold voltage shift for narrow width |
| NSUBCW | — | — | 0 | — | Substrate concentration modifier for narrow W |
| NSUBCWP | — | — | 1 | — | Substrate concentration exponent for narrow W |
| NSUBCL | — | — | 0 | — | Substrate concentration modifier for short L |
| NSUBCLP | — | — | 1 | — | Substrate concentration exponent for short L |
| NSUBCMAX | — | cm^-3 | 5e18 | — | Upper limit of substrate concentration |
| NSUBP0 | — | — | 0 | — | Pocket concentration modifier for narrow W |
| NSUBWP | — | — | 1 | — | Pocket concentration exponent for narrow W |
| MUEPHW | — | — | 0 | — | Phonon mobility reduction for narrow W |
| MUEPWP | — | — | 1 | — | Phonon mobility exponent for narrow W |
| MUESRW | — | — | 0 | — | Surface roughness mobility for narrow W |
| MUESWP | — | — | 1 | — | Surface roughness mobility exponent for narrow W |

### Small Geometry Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| WL2 | — | — | 0 | — | Threshold voltage shift due to small-size effect |
| WL2P | — | — | 1 | — | Exponent for small-size Vth shift |
| MUEPHS | — | — | 0 | — | Mobility change due to small size |
| MUEPSP | — | — | 1 | — | Mobility exponent for small size |
| VOVERS | — | — | 0 | — | Max velocity modification due to small size |
| VOVERSP | — | — | 1 | — | Max velocity exponent for small size |

### STI (Shallow Trench Isolation) Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NSTI | $N_{STI}$ | cm^-3 | 5e17 | [1e16, 1e19] | Substrate impurity concentration at STI edge |
| VTHSTI | — | V | 0 | — | Threshold voltage shift due to STI |
| VDSTI | — | V^-1 | 0 | — | Vds dependence of STI Vth shift |
| SCSTI1 | — | — | 0 | — | SC1 equivalent at STI edge |
| SCSTI2 | — | — | 0 | — | SC2 equivalent at STI edge |
| WSTI | — | m | 0 | — | Width of high-field region at STI edge |
| WSTIL | — | — | 0 | — | Channel-length dependence of WSTI |
| WSTILP | — | — | 1 | — | Channel-length exponent of WSTI |
| WSTIW | — | — | 0 | — | Channel-width dependence of WSTI |
| WSTIWP | — | — | 1 | — | Channel-width exponent of WSTI |
| WL1 | — | — | 0 | — | Small-size effect for STI leakage |
| WL1P | — | — | 1 | — | Small-size exponent for STI leakage |

### STI Diffusion Length (LOD) Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NSUBCSTI1 | — | — | 0 | — | Channel concentration modifier |
| NSUBCSTI2 | — | — | 0 | — | Channel concentration modifier |
| NSUBCSTI3 | — | — | 1 | — | Channel concentration exponent |
| NSUBPSTI1 | — | — | 0 | — | Pocket concentration modifier |
| NSUBPSTI2 | — | — | 0 | — | Pocket concentration modifier |
| NSUBPSTI3 | — | — | 1 | — | Pocket concentration exponent |
| MUESTI1 | — | — | 0 | — | Mobility change due to diffusion length |
| MUESTI2 | — | — | 0 | — | Mobility change due to diffusion length |
| MUESTI3 | — | — | 1 | — | Mobility change exponent |
| SAREF | — | m | 1e-6 | — | Reference distance OD edge to poly (one side) |
| SBREF | — | m | 1e-6 | — | Reference distance OD edge to poly (other side) |

### Temperature Dependence Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| EG0 | $E_{g0}$ | eV | 1.1785 | [1, 1.3] | Bandgap at 0 K |
| BGTMP1 | — | eV/K | 90.25e-6 | [50e-6, 100e-6] | Temperature dependence of bandgap (linear) |
| BGTMP2 | — | eV/K^2 | 0.1e-6 | [-1e-6, 1e-6] | Temperature dependence of bandgap (quadratic) |
| TNOM | — | deg C | 27 | [22, 32] | Nominal temperature |
| MUETMP | — | — | 1.5 | [0.5, 2.2] | Temperature-dependence of phonon scattering |
| VTMP | — | — | 0 | [-2, 1] | Temperature-dependence of Vmax |
| RDRVTMP | — | — | 0 | — | Temperature dependence of drift Vmax |
| RDRMUETMP | — | — | 0 | — | Temperature dependence of drift mobility |
| RDRBBTMP | — | 1/K | 0 | — | Temperature dependence of RDRBB/RDRBBS |

### Parasitic Resistance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RSH | — | Ohm/sq | 0 | [0, —] | Sheet resistance of diffusion region |
| RSHG | — | Ohm/sq | 0 | [0, —] | Gate sheet resistance |
| NOVER | $N_{OVER}$ | cm^-3 | 1e19 | — | Impurity concentration in overlap/drift region |
| NOVERS | — | cm^-3 | 1e19 | — | Impurity concentration in overlap region (source) |
| RDRDJUNC | — | m | 1e-6 | — | Junction depth at channel/drift region |
| RDRMUE | — | cm^2/(V*s) | 1000 | — | Mobility in drift region (drain) |
| RDRMUES | — | cm^2/(V*s) | 1000 | — | Mobility in drift region (source) |
| RDRMUEL | — | — | 0 | — | Mobility Lgate dependence in drift region |
| RDRMUELP | — | — | 1 | — | Mobility Lgate exponent in drift region |
| RDRVMAX | — | cm/s | 3e7 | — | Saturation velocity in drift region (drain) |
| RDRVMAXS | — | cm/s | 3e7 | — | Saturation velocity in drift region (source) |
| RDRVMAXL | — | — | 0 | — | Drift Vmax Lgate dependence |
| RDRVMAXLP | — | — | 1 | — | Drift Vmax Lgate exponent |
| RDRVMAXW | — | — | 0 | — | Drift Vmax Wgate dependence |
| RDRVMAXWP | — | — | 1 | — | Drift Vmax Wgate exponent |
| RDRBB | — | — | 1 | — | High field mobility exponent in drift (drain) |
| RDRBBS | — | — | 1 | — | High field mobility exponent in drift (source) |
| RBULK0 | — | Ohm | 0 | — | Body resistance constant offset (COBCNODE=1) |
| RBULKW | — | Ohm/m | 0 | — | Body resistance width coefficient (COBCNODE=1) |

### Capacitance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XQY | — | m | 0 | [0, 50e-9] | Distance from junction to max field point |
| XQY1 | — | F*um^(XQY2-1) | 0 | — | Vbs-dependence of lateral-field charge Qy |
| XQY2 | — | — | 2 | — | Lgate-dependence of lateral-field charge Qy |
| LOVER | — | m | 30e-9 | (0, —] | Drain overlap length |
| NOVER | $N_{OVER}$ | cm^-3 | 1e19 | — | Impurity concentration in overlap region |
| VFBOVER | — | V | 0 | [-2, 1] | Flat-band voltage in overlap region |
| OVSLP | — | m/V | 2.1e-7 | — | Coefficient for overlap capacitance |
| OVMAG | — | V | 0.6 | — | Coefficient for overlap capacitance |
| CGDO | — | F/m | — | [0, —] | Gate-to-drain overlap cap (user-defined) |
| CGSO | — | F/m | — | [0, —] | Gate-to-source overlap cap (user-defined) |
| CGBO | — | F/m | — | [0, —] | Gate-to-bulk overlap cap |

### Substrate Current Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| SUB1 | — | V^-1 | 0.01 | — | Substrate current magnitude coefficient |
| SUB1L | — | — | 2.5e-3 | — | Lgate-dependence of SUB1 |
| SUB1LP | — | — | 1 | — | Lgate exponent of SUB1 |
| SUB2 | — | V | 20 | — | Substrate current exponential coefficient |
| SUB2L | — | m | 2e-6 | — | Lgate-dependence of SUB2 |
| SVDS | — | — | 3 | — | Substrate current Vds dependence |
| SLG | — | — | 3e-8 | — | Substrate current Lgate dependence |
| SLGL | — | — | 0 | — | Substrate current Lgate dependence (COSUBSCALE=1) |
| SLGLP | — | — | 1 | — | Substrate current Lgate exponent (COSUBSCALE=1) |
| SVGS | — | — | 0.8 | — | Substrate current Vgs dependence |
| SVGSL | — | — | 0 | — | Lgate-dependence of SVGS |
| SVGSLP | — | — | 1 | — | Lgate exponent of SVGS |
| SVGSW | — | — | 0 | — | Wgate-dependence of SVGS |
| SVGSWP | — | — | 1 | — | Wgate exponent of SVGS |
| SVBS | — | — | 0.5 | — | Substrate current Vbs dependence |
| SVBSL | — | — | 0 | — | Lgate-dependence of SVBS |
| SVBSLP | — | — | 1 | — | Lgate exponent of SVBS |
| VFBSUB | — | V | -1 | — | Flat-band voltage for Isub calculation |
| VFBSUBL | — | — | 0 | — | Lgate-dependence of VFBSUB |
| VFBSUBLP | — | — | 1 | — | Lgate exponent of VFBSUB |
| DVGPSUB | — | — | 0 | — | Vth shift for pseudo-FBE in body-tie Isub |
| DVBSSUB | — | — | 0 | — | Bias shift for pseudo-FBE charge Qh in body-tie Isub |
| IBPC1 | — | V/A | 0 | — | Impact-ionization bulk potential change coefficient |
| IBPC2 | — | V^-1 | 0 | — | Impact-ionization bulk potential change coefficient |

### Gate Leakage Current Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| GLEAK1 | — | V^(-3/2) * s^-1 | 1e4 | — | Gate-to-channel current coefficient |
| GLEAK2 | — | V^(-1/2) * m^-1 | 2e7 | — | Gate-to-channel current coefficient |
| GLEAK3 | — | — | 0.3 | — | Gate-to-channel current coefficient |
| GLEAK4 | — | — | 4 | — | Gate-to-channel current coefficient |
| GLEAK5 | — | V*cm^-1 | 7.5e3 | — | Gate-to-channel short channel correction |
| GLEAK6 | — | V | 0.25 | — | Gate-to-channel Vds-dependence correction |
| GLEAK7 | — | m^2 | 1e-6 | — | Gate-to-channel L and W dependence |
| GLKB1 | — | A*V^-2 | 5e-16 | — | Gate-to-body current coefficient |
| GLKB2 | — | m/V | 1 | — | Gate-to-body current coefficient |
| GLKB3 | — | V | 0 | — | Gate-to-body current coefficient |
| GLKSD1 | — | A*m*V^-2 | 1e-15 | — | Gate-to-S/D current coefficient |
| GLKSD2 | — | V^-1 * m^-1 | 5e6 | — | Gate-to-S/D current coefficient |
| GLKSD3 | — | m^-1 | -5e6 | — | Gate-to-S/D current coefficient |

### GIDL Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| GIDL1 | — | A*V^(-3/2)*C^-1*m | 5e-6 | — | Magnitude of GIDL |
| GIDL2 | — | V^-2 * m^-1 * F^(-3/2) | 1e6 | — | Field-dependence of GIDL |
| GIDL3 | — | — | 0.3 | — | Vds-dependence of GIDL |
| GIDL4 | — | V | 0 | — | Threshold for Vds dependence |
| GIDL5 | — | — | 0.2 | — | High-field correction |
| GIDLVB | — | V^3 | 0.5 | — | Body bias dependence coefficient |

### Valence Band Electron Tunneling Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| EVB1 | — | V^-2 * s^-1 | 0 | [0, —] | Electron tunneling from valence band |
| EVB2 | — | V*m^-1 | 0 | [0, —] | Electron tunneling from valence band |
| EVB3 | — | — | 0 | [0, —] | Electron tunneling from valence band |
| FVBS | — | — | 0 | — | Vbs dependence of Fowler-Nordheim current |

### Floating-Body Effect Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| QHE1 | — | — | 1.5 | (0, —] | Floating-body effect parameter |
| QHE2 | — | V | 0.35 | (0, —] | Floating-body effect parameter |
| QHSMAX | — | C/m^2 | 1e-3 | — | Upper limit of floating-body charge (COBCNODE=1, COFBE=2) |

### History Effect Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| HIST1 | — | V | 1e-8 | (0, —] | History effect parameter |
| HIST2 | — | A | 1e-20 | (0, —] | History effect parameter |

### Self-Heating Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RTH0 | $R_{th}$ | K*cm/W | 0.1 | — | Thermal resistance |
| CTH0 | $C_{th}$ | W*s/(K*cm) | 1e-7 | — | Thermal capacitance |

### Source/Body and Drain/Body Diode Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| JS0 | $J_{S0}$ | A/m^2 | 1e-4 | (0, —] | Saturation current density |
| NJ | — | — | 1 | — | Emission coefficient |
| XTI | — | — | 2 | — | Temp coefficient for forward current |
| XTI2 | — | — | 0 | — | Temp coefficient for reverse current |
| VDIFFJ | — | V | 1.6e-3 | — | Diode threshold voltage at junction |
| DIVX | — | V^-1 | 0 | — | Reverse current coefficient |
| CJ | — | F/m^2 | 5e-4 | — | Bottom junction cap/unit area at zero bias |
| CJSW | — | F/m | 5e-10 | — | Sidewall junction cap per unit length at zero bias |
| CJSWG | — | F/m | 5e-10 | — | Gate-sidewall junction cap per unit length |
| MJ | — | — | 0.33 | — | Bottom junction cap grading coefficient |
| MJSW | — | — | 0.33 | — | Sidewall junction cap grading coefficient |
| MJSWG | — | — | 0.33 | — | Gate-sidewall junction cap grading coefficient |
| PB | — | V | 1 | — | Bottom junction built-in potential |
| PBSW | — | V | 1 | — | Sidewall junction built-in potential |
| PBSWG | — | V | 1 | — | Gate-sidewall junction built-in potential |

### Body-Tie Contact Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XWDBT | — | m | 0 | — | Body-tie overlap width |
| CBTBN | — | F/m^2 | — | — | N+ poly capacitance (user-defined) |
| CBTBP | — | F/m^2 | — | — | P+ poly capacitance (user-defined) |
| VFBBTP | — | V | 0.12 | — | Flat-band voltage for body-tie MOSFET part |

### Noise Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NFALP | — | cm*s | 1e-19 | — | Contribution of mobility fluctuation |
| NFTRP | — | V^-1 | 1e10 | — | Ratio of trap density to attenuation coefficient |
| CIT | — | F/cm^2 | 0 | — | Interface-trapped carrier capacitance |
| FALPH | — | — | 1.0 | — | Exponent of frequency f in 1/f^FALPH |

### NQS (Non-Quasi-Static) Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| DLY1 | — | s | 1e-10 | — | Coefficient for delay due to diffusion |
| DLY2 | — | — | 0.7 | — | Coefficient for delay due to conduction |
| DLY3 | — | Ohm | 8e-7 | — | Coefficient for RC delay of bulk carriers |

### Symmetry Conservation Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VZADD0 | — | V | 0.01 | — | Symmetry conservation coefficient |
| PZADD0 | — | V | 0.005 | — | Symmetry conservation coefficient |

### Internal Limiter

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VGSMIN | — | V | -5 (NMOS) / 5 (PMOS) | — | Surface potential limiter (BT only) |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| L | $L_{gate}$ | m | 5e-6 | (0, —] | Gate length |
| W | $W_{gate}$ | m | 5e-6 | (0, —] | Gate width |
| AD | — | m^2 | 0 | [0, —] | Area of drain junction |
| AS | — | m^2 | 0 | [0, —] | Area of source junction |
| PD | — | m | 0 | [0, —] | Perimeter of drain junction |
| PS | — | m | 0 | [0, —] | Perimeter of source junction |
| NRD | — | — | 1 | [0, —] | Number of drain diffusion squares |
| NRS | — | — | 1 | [0, —] | Number of source diffusion squares |
| LDRIFT | — | m | 1e-6 | [0, —] | Length of drift region (drain side) |
| LDRIFTS | — | m | 1e-6 | [0, —] | Length of drift region (source side) |
| XGW | — | m | 0 | [0, —] | Distance from gate contact to channel edge |
| XGL | — | m | 0 | [0, —] | Offset of gate length |
| M | — | — | 1 | [1, —] | Multiplication factor |
| NF | — | — | 1 | [1, —] | Number of gate fingers |
| NGCON | — | — | 1 | [1, —] | Number of gate contacts |
| SA | — | m | 0 | [0, —] | Length of diffusion gate-to-STI (one side) |
| SB | — | m | 0 | [0, —] | Length of diffusion gate-to-STI (other side) |
| SD | — | m | 0 | [0, —] | Length of diffusion gate-to-gate |
| LOD | — | m | 1e-5 | — | Diffusion length between gate and STI edge |
| RBDB | — | Ohm | 50 | [0, —] | Body resistance (drain side, CORBNET=1) |
| RBSB | — | Ohm | 50 | [0, —] | Body resistance (source side, CORBNET=1) |
| PDBCP | — | m | 0 | [0, —] | Parasitic perimeter length for body contact at drain |
| PSBCP | — | m | 0 | [0, —] | Parasitic perimeter length for body contact at source |
| NBT | — | — | 1 | [0, —] | Number of body contacts |
| LBT | — | m | 0 | [0, —] | Length of gate over body-contact well |
| WBTN | — | m | 0 | [0, —] | Distance of gate protrusion over N+ body-contact well |
| WBTP | — | m | 0 | [0, —] | Distance of gate protrusion over P+ body-contact well |
| ABTN | — | m^2 | 0 | — | Area of N+ poly area of body contact |
| ABTP | — | m^2 | 0 | — | Area of P+ poly area of body contact |
| TEMP | — | deg C | 27 | — | Device temperature |
| DTEMP | — | deg C | 0 | — | Device temperature change |

---

## Equations

### Section 1: Effective Geometry

$$
L_{gate} = L_{drawn}
\tag{1}
$$

$$
W_{gate} = \frac{W_{drawn}}{NF}
\tag{2}
$$

$$
L_{eff} = L_{gate} - 2 \cdot XLD
\tag{3}
$$

$$
L_{effc} = L_{gate} - 2 \cdot XLDC
\tag{4}
$$

$$
W_{eff} = W_{gate} - 2 \cdot XWD
\tag{5}
$$

$$
W_{effc} = W_{gate} - 2 \cdot XWDC
\tag{6}
$$

### Section 2: Poisson Equation and Core Potentials

Three coupled equations solved simultaneously for SOI surface/body/substrate potentials:

$$
\phi_{s,SOI} = V_{G0} + \frac{Q_{s,bulk} + Q_i + Q_{dep,SOI} + Q_h}{C_{FOX}}
\tag{7}
$$

$$
\phi_{b,SOI} = \phi_{s,SOI} + \frac{Q_{s,bulk} + \frac{1}{2} Q_{dep,SOI}}{C_{SOI}}
\tag{8}
$$

$$
\phi_{s,bulk} = \phi_{b,SOI} + \frac{Q_{s,bulk}}{C_{BOX}}
\tag{9}
$$

where:

$$
V_{G0} = V_{gs} - V_{FBC} + \Delta V_{th}
\tag{10}
$$

$$
C_{FOX} = \frac{\epsilon_{ox}}{T_{FOX}}
\tag{11}
$$

$$
C_{BOX} = \frac{\epsilon_{ox}}{T_{BOX}}
\tag{12}
$$

$$
C_{SOI} = \frac{\epsilon_{Si}}{T_{SOI}}
\tag{13}
$$

### Section 2: Charge Expressions

Depletion charge in SOI:

$$
-Q_{dep,SOI}(y) = Q_{s,dep} + Q_{b,dep}
\tag{14}
$$

Fully depleted:

$$
-Q_{dep,SOI} = q N_{subs} T_{SOI}
\tag{15}
$$

FB partially depleted:

$$
-Q_{dep,SOI} = \frac{\text{const}_0}{\beta} \left[ \exp\left(-\beta(\phi_{s,SOI} - \phi_{b,SOI})\right) + \beta(\phi_{s,SOI} - \phi_{b,SOI}) - 1 \right]^{1/2}
\tag{16}
$$

BC partially depleted:

$$
-Q_{dep,SOI} = \frac{\text{const}_0}{\beta} \left[ \exp\left(-\beta(\phi_{s,SOI} - V_{bcs})\right) + \beta(\phi_{s,SOI} - V_{bcs}) - 1 \right]^{1/2}
\tag{17}
$$

Inversion charge:

$$
-Q_i(y) = \sqrt{Q_{dep,SOI}^2 + \frac{2q\epsilon_{Si}}{\beta}\exp(\beta\phi_{s,SOI})} - Q_{dep,SOI}
\tag{18}
$$

Substrate charge:

$$
-Q_{s,bulk}(y) = \sqrt{\frac{2\epsilon_{Si} q N_{subb}}{\beta}\left[\exp\left(-\beta(\phi_{s,bulk} - V_{es})\right) + \beta(\phi_{s,bulk} - V_{es}) - 1\right] + \frac{n_{p0}}{p_{p0}}\left[\exp\beta(\phi_{s,bulk} - \phi_f) - \exp\beta(V_{es} - \phi_f)\right]}
\tag{19}
$$

Auxiliary constants:

$$
\text{const}_0 = \sqrt{\frac{2\epsilon_{Si} q N_{subs}}{\beta}}
\tag{20}
$$

$$
\text{const}_b = \sqrt{\frac{2\epsilon_{Si} q N_{subb}}{\beta}}
\tag{21}
$$

$$
\beta = \frac{q}{kT}
\tag{22}
$$

Quasi-Fermi potential relationship:

$$
\phi_f(L_{eff}) - \phi_f(0) = V_{ds,eff}
\tag{23}
$$

### Section 2: Vds Smoothing

$$
V_{ds,eff} = \frac{V_{ds}}{\left[1 + \left(\frac{V_{ds}}{V_{ds,sat}}\right)^\Delta\right]^{1/\Delta}}
\tag{24}
$$

$$
\Delta = \frac{DDLTMAX \cdot T_1}{DDLTMAX + T_1} + DDLTICT
\tag{25}
$$

$$
T_1 = DDLTSLP \cdot L_{gate} \times 10^6
\tag{26}
$$

$$
V_{ds,sat} = V_{g0} + \frac{q N_{subs} \epsilon_{Si}}{C_{FOX}^2}\left(1 - \sqrt{1 + \frac{2C_{FOX}^2}{q N_{subs} \epsilon_{Si}}\left(V_{g0}' - \frac{1}{\beta}\right)}\right)
\tag{27}
$$

### Section 2: Intrinsic Carrier Concentration

$$
n_{p0} = \frac{n_i^2}{p_{p0}}
\tag{28}
$$

$$
n_i = n_{i0} \cdot T^{3/2} \exp\left(-\beta\frac{E_g}{2q}\right)
\tag{29}
$$

Trapezoidal charge integration (FD case):

$$
Q = \frac{Q(0) + Q(L)}{2}
\tag{30}
$$

### Section 3: Drain Current

FB case:

$$
I_{ds} = \frac{W_{eff} \cdot NF}{L_{eff} - \Delta L} \cdot \mu \cdot \frac{I_{dd}}{\beta}
\tag{31}
$$

$$
I_{dd} = Q_i(L) - Q_i(0) - \frac{\beta \left[Q_i(L) + Q_i(0)\right]}{2} \cdot (\phi_{sL} - \phi_{s0})
\tag{33}
$$

BT case:

$$
I_{dd} = C_{FOX}(\beta V_{G0} + 1)(\phi_{sL,SOI} - \phi_{s0,SOI}) - C_{FOX}\frac{\beta}{2}(\phi_{sL,SOI}^2 - \phi_{s0,SOI}^2)
$$
$$
- \frac{2}{3}\text{const}_0\left[\left(\beta(\phi_{sL,SOI} - V_{bcs}) - 1\right)^{3/2} - \left(\beta(\phi_{s0,SOI} - V_{bcs}) - 1\right)^{3/2}\right]
$$
$$
+ \text{const}_0\left[\left(\beta(\phi_{sL,SOI} - V_{bcs}) - 1\right)^{1/2} - \left(\beta(\phi_{s0,SOI} - V_{bcs}) - 1\right)^{1/2}\right]
\tag{35}
$$

$$
C_{FOX} = \frac{\epsilon_{ox}}{T_{FOX}}
\tag{36}
$$

### Section 4: Threshold Voltage Shift

Total Vth shift:

$$
\Delta V_{th} = \Delta V_{th,SC} + \Delta V_{th,R} + \Delta V_{th,P} + \Delta V_{th,SCR} + \Delta V_{th,W} + \Delta V_{th,sm} - \phi_{Spg}
\tag{37}
$$

#### Short-Channel Effects

$$
\Delta V_{th,SC} = \frac{\epsilon_{Si}}{C_{FOX}} W_d \frac{dE_y}{dy}
\tag{38}
$$

$$
W_d = \sqrt{\frac{2\epsilon_{Si}(2\Phi_B - V_{bs}')}{q N_{sub}}}
\tag{39}
$$

$$
2\Phi_B = \frac{2}{\beta}\ln\left(\frac{N_{sub}}{n_i}\right)
\tag{40}
$$

$$
\frac{dE_y}{dy} = \frac{2(V_{BI} - 2\Phi_B)}{(L_{gate} - PARL2)^2}\left(SC1 + SC2 \cdot V_{ds} + SC3 \cdot \frac{2\Phi_B - V_{bs}'}{L_{gate}}\right)
\tag{41}
$$

SOI-specific short-channel effect via BOX:

$$
\Delta V_{th,SCR} = \frac{SCR1 \cdot T_{FOX}(E_g + 2\Phi_B - SCR3 + SCR2 \cdot V_{ds})}{L_{gate}/2 + PARL1}
\tag{42}
$$

#### Reverse Short-Channel (Pocket Implant)

$$
\Delta V_{th,P} = (V_{th,R} - V_{th0}) \cdot \frac{\epsilon_{Si}}{C_{FOX}} W_d \frac{dE_{y,P}}{dy}
\tag{43}
$$

$$
V_{th,R} = V_{FB} + 2\Phi_B + \frac{Q_{B0}}{C_{FOX}} + P_{tovr}
\tag{44}
$$

$$
Q_{B0} = \sqrt{2q \cdot N_{sub} \cdot \epsilon_{Si} \cdot (2\Phi_B - V_{bs}')}
\tag{45}
$$

$$
V_{th0} = V_{FB} + 2\Phi_{BC} + \frac{\sqrt{2q \cdot N_{subs} \cdot \epsilon_{Si} \cdot (2\Phi_{BC} - V_{bs}')}}{C_{FOX}}
\tag{46}
$$

$$
\frac{dE_{y,P}}{dy} = \frac{2(V_{BI} - 2\Phi_B)}{LP^2}\left(SCP1 + SCP2 \cdot V_{ds} + SCP3 \cdot \frac{2\Phi_B - V_{bs}'}{LP}\right)
\tag{47}
$$

$$
P_{tovr} = \begin{cases} \frac{1}{\beta}\ln\frac{N_{subb0}}{N_{subs}} & (L_{gate} \leq 2 \cdot LP) \\ 0 & (L_{gate} > 2 \cdot LP) \end{cases}
\tag{48}
$$

$$
N_{subb0} = 2 \cdot N_{subps} - \frac{(N_{subps} - N_{subs}) \cdot L_{gate}}{LP} - N_{subs}
\tag{49}
$$

$$
\Phi_{BC} = \frac{1}{\beta}\ln\frac{N_{subs}}{n_i}
\tag{50}
$$

$$
\Phi_B = \frac{1}{\beta}\ln\frac{N_{sub}}{n_i}
\tag{51}
$$

$$
N_{sub} = \begin{cases} \frac{N_{subs}(L_{gate} - LP) + N_{subps} \cdot LP}{L_{gate}} & (L_{gate} > LP) \\ N_{subps} + \frac{(N_{subps} - N_{subs})(LP - L_{gate})}{LP} & (L_{gate} \leq LP) \end{cases}
\tag{52}
$$

#### Flat-Band Voltage Shift (Mechanical Stress)

$$
V_{fb} = f(V_{fb1}, V_{fb2}, V_{fb3})
\tag{53}
$$

$$
V_{fb1} = VFBC \cdot \left(1 + \frac{VFBCL1}{(L_{gate} \cdot 10^6)^{VFBCL1P}}\right)
\tag{54}
$$

$$
V_{fb2} = VFBC \cdot \left(1 + \frac{VFBCL2}{(L_{gate} \cdot 10^6)^{VFBCL2P}}\right)
\tag{55}
$$

$$
V_{fb3} = VFBC + VFBHAMP \cdot (L_{gate} \cdot 10^6)
\tag{56}
$$

### Section 5: Punchthrough

Total drain current with punchthrough:

$$
I_{ds} = I_{ds,intrinsic} + I_{ds,punch} + I_{ds,pinchoff}
\tag{57}
$$

$$
I_{ds,punch} = I_{surfacePT} + I_{deepPT}
\tag{58}
$$

#### Shallow Punchthrough

$$
POTEN = \left(\frac{V_{ds} - (\phi_{sL,SOI} - \phi_{s0,SOI})}{1.1 - \phi_{s0,SOI} + 2}\right)^{PTP}
\tag{59}
$$

$$
I_{shallowPT} = \frac{W_{eff} \cdot NF}{L_{eff}} \cdot \frac{\mu}{\beta} \cdot (\phi_{sL,SOI} - \phi_{s0,SOI}) \cdot C_{FOX} \cdot \beta \cdot \frac{PTL}{(L_{gate} \cdot 10^6)^{PTLP}} \cdot POTEN \cdot \left(1 + PT2 \cdot V_{ds} + \frac{PT4 \cdot (\phi_{s0,SOI} - V_{bs})}{(L_{gate} \cdot 10^6)^{PT4P}}\right)
\tag{60}
$$

#### Deep Punchthrough

$$
I_{PT,deep} = J_{PT,deep} \cdot W_{eff} \cdot NF \cdot (1 - \exp(-\beta V_{ds}))
\tag{61}
$$

$$
J_{PT,deep} = \frac{2}{\beta L_{eff}} \cdot Q_{n0,PT} \cdot MUPT \cdot \exp(-\beta\phi_m)
\tag{62}
$$

$$
Q_{n0,PT} = \sqrt{\frac{2q \cdot NJUNC \cdot \epsilon_{Si}}{\beta}} \cdot \sqrt{\beta\phi_{m,gate}}
\tag{63}
$$

$$
\phi_m = \phi_{m,gate} + \phi_{m,SD}
\tag{64}
$$

$$
\phi_{m,gate} = (\phi_{s,deepPT} - \phi_{m,SD}) \cdot wfactor
\tag{65}
$$

$$
wfactor = \begin{cases} \left(1 - \frac{XJPT}{W_{depl,PT}}\right)^2 & (W_{depl,PT} \geq XJPT) \\ 0 & (W_{depl,PT} < XJPT) \end{cases}
\tag{66}
$$

$$
W_{depl,PT} = \begin{cases} Q_{bu,PT}/(q \cdot N_{subs}) & (\phi_{s,deepPT} \geq \phi_{m,SD}) \\ 0 & (\phi_{s,deepPT} < \phi_{m,SD}) \end{cases}
\tag{67}
$$

$$
Q_{bu,PT} = \text{const}_0 \cdot \sqrt{\exp(-\beta(\phi_{s,deepPT} - \phi_{m,SD})) - 1 + \beta(\phi_{s,deepPT} - \phi_{m,SD})}
\tag{68}
$$

$$
\phi_{m,SD} = -\frac{1}{4}\frac{(E_{cri} \cdot L_{eff})^2}{(E_{cri} \cdot L_{eff}) + V_{ds}}
\tag{69}
$$

$$
E_{cri} = \sqrt{\frac{2q(V_{bi} - V_{bs})}{\epsilon_{Si}} \cdot \frac{N_{sub} \cdot NJUNC}{N_{sub} + NJUNC}}
\tag{70}
$$

Deep punchthrough flat-band shift uses $VFBC + VFBPT$ (71). PSLIMPT limits $\phi_{s,deepPT}$ maximum value.

#### Channel Conductance (Pinch-off Current)

$$
I_{ds,pinchoff} = \frac{W_{eff} \cdot NF}{L_{eff}} \cdot \frac{\mu}{\beta} \cdot (\phi_{sL,SOI} - \phi_{s0,SOI}) \cdot COND
\tag{72}
$$

$$
COND = C_{FOX} \cdot \beta \cdot \frac{GDL}{(L_{gate} \cdot 10^6 + GDLD \cdot 10^6)^{GDLP}} \cdot V_{ds}
$$

### Section 6: Poly-Si Gate Depletion

$$
\phi_{Spg} = PGD1\left(1 + \frac{1}{L_{gate} \times 10^6}\right)^{PGD4} \exp\left(\frac{V_{gs} - PGD2}{[1V]}\right)
\tag{73}
$$

Smoothed so $\phi_{Spg}$ does not exceed $\phi_{s0}$ for large $V_{gs}$.

### Section 7: Quantum Mechanical Effects

$$
T_{FOX} = T_{FOX} + \Delta T_{FOX}
\tag{74}
$$

$$
\Delta T_{ox} = \frac{QME1}{V_{gs} - V_{bs}' - V_{th}(T_{FOX} = T_{FOX}) + QME2} + QME3
\tag{75}
$$

### Section 8: Mobility Model

Low-field mobility (Matthiessen's rule):

$$
\frac{1}{\mu_0} = \frac{1}{\mu_{CB}} + \frac{1}{\mu_{PH}} + \frac{1}{\mu_{SR}}
\tag{76}
$$

$$
\mu_{CB} = MUECB0 + MUECB1 \cdot \frac{Q_i}{q \times 10^{11}}
\tag{77}
$$

$$
\mu_{PH} = \frac{Muephonon}{E_{eff}^{MUEPH0}}
\tag{78}
$$

$$
\mu_{SR} = \frac{Muesurface}{E_{eff}^{MUESR1}}
\tag{79}
$$

Effective field:

$$
E_{eff} = \frac{1}{\epsilon_{Si}} \cdot \frac{NDEP \cdot \overline{Q}_{b,SOI} + NINV \cdot \overline{Q}_i}{1 + (\phi_{sL,SOI} - \phi_{s0,SOI})^{NINVD}}
\tag{80}
$$

$$
\overline{Q}_{b,SOI} = \frac{Q_{b,SOI}(L) + Q_{b,SOI}(0)}{2}
\tag{81}
$$

$$
\overline{Q}_i = \frac{Q_i(L) + Q_i(0)}{2}
\tag{82}
$$

L-dependent phonon mobility:

$$
Muephonon = MUEPH1 \times \left(1 + \frac{MUEPHL}{(L_{gate} \times 10^6)^{MUEPLP}}\right)
\tag{87}
$$

L-dependent surface roughness:

$$
Muesurface = MUESR0 \times \left(1 + \frac{MUESRL}{(L_{gate} \times 10^6)^{MUESLP}}\right)
\tag{88}
$$

High-field mobility:

$$
\mu = \frac{\mu_0}{\left[1 + \left(\frac{\mu_0 E_y}{V_{max}}\right)^{BB}\right]^{1/BB}}
\tag{89}
$$

$$
E_y = \sqrt{\left(\frac{I_{dd}}{\beta \cdot Q_i(0) \cdot (L_{eff} \cdot 10^6)}\right)^2 + \left(\frac{0.2 \cdot V_{max}}{\mu_0}\right)^2}
\tag{90}
$$

Velocity overshoot:

$$
V_{max} = VMAX \cdot \left(1 + \frac{VOVER}{(L_{gate} \times 10^6)^{VOVERP}}\right)
\tag{91}
$$

### Section 9: Channel-Length Modulation

$$
\phi_{s,SOI}(\Delta L) = (1 - CLM1) \cdot \phi_{sL,SOI} + CLM1 \cdot (\phi_{s0,SOI} + V_{ds})
\tag{92}
$$

$$
\Delta L = -\frac{1}{2}\left(\frac{q N_{subs}}{\epsilon_{Si}} z + 2\frac{I_{dd}}{\beta Q_i L_{eff}}\right)(\phi_{s,SOI}(\Delta L) - \phi_{sL,SOI})z + E_0 z^2
$$
$$
+ \sqrt{\left(\frac{q N_{subs}}{\epsilon_{Si}} z + 2\frac{I_{dd}}{\beta Q_i L_{eff}^2}\right)(\phi_{s,SOI}(\Delta L) - \phi_{sL,SOI})z^2 + E_0 z^2 + 4\frac{q^2 N_{subs}^2}{\epsilon_{Si}^2}(\phi_{s,SOI}(\Delta L) - \phi_{sL,SOI})z^2 + E_0 z^2}
\tag{93}
$$

where $E_0 = 10^5$ and:

$$
z = \frac{\epsilon_{Si} W_d}{CLM2 \cdot Q_b + CLM3 \cdot Q_i}
\tag{94}
$$

$$
CLM2 = \begin{cases} \frac{5.0 \times 10^9}{T_{SOI} \cdot N_{SUBS}} & \text{(default)} \\ CLM2 & \text{(if given)} \end{cases}
\tag{95}
$$

Pocket effect on CLM:

$$
\Delta L \leftarrow \Delta L \left(1 + CLM6 \cdot (L_{gate} \times 10^6)^{CLM5}\right)
\tag{96}
$$

### Section 10: Narrow-Channel Effects

#### Threshold Voltage Modification

$$
\Delta V_{th,W} = \frac{1}{C_{FOX}}\left(\frac{1}{1} - \frac{1}{C_{FOX} + 2C_{ef}/(L_{eff} W_{eff})}\right) q N_{subc} W_d + \frac{WVTH0}{W_{gate} \times 10^6}
\tag{97}
$$

$$
C_{ef} = \frac{2\epsilon_{ox}}{\pi} L_{eff} \ln\left(\frac{2 \cdot T_{oxiso}}{T_{FOX}}\right)
\tag{98}
$$

$$
WFC = \frac{C_{ef}}{L_{eff}}
\tag{99}
$$

Width-dependent pocket concentration:

$$
N_{subpp} = NSUBP \times \left(1 + \frac{NSUBP0}{(W_{gate} \times 10^6)^{NSUBWP}}\right)
\tag{100}
$$

Device-size-dependent substrate concentration:

$$
N_{subs} = \min\left(NSUBCMAX,\; NSUBS \cdot \left(1 + \frac{NSUBCW}{(W_{gate} \cdot 10^6)^{NSUBCWP}}\right) \cdot \left(1 + \frac{NSUBCL}{(L_{gate} \cdot 10^6)^{NSUBCLP}}\right)\right)
\tag{101}
$$

#### Mobility Change (Narrow Width)

$$
Muephonon \leftarrow Muephonon \times \left(1 + \frac{MUEPHW}{(W_{gate} \times 10^6)^{MUEPWP}}\right)
\tag{102}
$$

$$
Muesurface \leftarrow Muesurface \times \left(1 + \frac{MUESRW}{(W_{gate} \times 10^6)^{MUESWP}}\right)
\tag{103}
$$

#### STI Leakage (Hump in Ids)

$$
\phi_{s,STI} = V'_{gs,STI} + \frac{2C_{FOX}^2}{\epsilon_{Si} Q_{N,STI}}\left(1 - \sqrt{1 + \frac{\epsilon_{Si} Q_{N,STI}}{C_{FOX}^2}\left[\beta(V'_{gs,STI} - V'_{bs}) - 1\right]}\right)
\tag{104}
$$

$$
Q_{N,STI} = q \cdot NSTI
\tag{105}
$$

$$
V'_{gs,STI} = V_{gs} - VFBC + V_{thSTI} + \Delta V_{th,SCSTI}
\tag{106}
$$

$$
V_{thSTI} = VTHSTI - VDSTI \cdot V_{ds}
\tag{107}
$$

$$
\Delta V_{th,SCSTI} = \frac{\epsilon_{Si}}{C_{FOX}} W_{d,STI} \frac{dE_y}{dy}
\tag{108}
$$

$$
W_{d,STI} = \sqrt{\frac{2\epsilon_{Si}(2\Phi_{B,STI} - V'_{bs})}{q \cdot NSTI}}
\tag{109}
$$

$$
\frac{dE_y}{dy} = \frac{2(V_{BI} - 2\Phi_{B,STI})}{(L_{gate,sm} - PARL2)^2}(SCSTI1 + SCSTI2 \cdot V_{ds})
\tag{110}
$$

$$
L_{gate,sm} = L_{gate} + \frac{WL1}{wl^{WL1P}}
\tag{111}
$$

$$
wl = (W_{gate} \cdot 10^6) \cdot (L_{gate} \cdot 10^6)
\tag{112}
$$

STI leakage current:

$$
I_{ds,STI} = 2 \cdot \frac{WSTI}{L_{eff} - \Delta L} \cdot \frac{Q_{i,STI}}{\beta} \cdot \mu \cdot [1 - \exp(-\beta V_{ds})]
\tag{113}
$$

$$
WSTI = WSTI\left(1 + \frac{WSTIL}{(L_{gate,sm} \cdot 10^6)^{WSTILP}} + \frac{WSTIW}{(W_{gate} \cdot 10^6)^{WSTIWP}}\right)
\tag{114}
$$

#### Small Geometry Vth Shift

$$
\Delta V_{th,sm} = \frac{WL2}{wl^{WL2P}}
\tag{115}
$$

$$
wl = (W_{gate} \times 10^6) \times (L_{gate} \times 10^6)
\tag{116}
$$

Small geometry mobility modification:

$$
Muephonon \leftarrow Muephonon \times \left(1 + \frac{MUEPHS}{wl^{MUEPSP}}\right)
\tag{117}
$$

$$
V_{max} \leftarrow V_{max} \cdot \left(1 + \frac{VOVERS}{wl^{VOVERSP}}\right)
\tag{118}
$$

### Section 11: STI Diffusion Length (LOD) Effects

Channel concentration modifier:

$$
N_{substi} = \frac{1 + T_1 \cdot T_2}{1 + T_1 \cdot T_3}
\tag{119}
$$

$$
T_1 = \frac{1}{1 + NSUBCSTI2}
\tag{120}
$$

$$
T_2 = \frac{NSUBCSTI1}{Lod_{half}^{NSUBCSTI3}}
\tag{121}
$$

$$
T_3 = \frac{NSUBCSTI1}{Lod_{half,ref}^{NSUBCSTI3}}
\tag{122}
$$

$$
N_{subs} = N_{subs} \cdot N_{substi}
\tag{123}
$$

Pocket concentration modifier (same form):

$$
N_{substi} = \frac{1 + T_1 \cdot T_2}{1 + T_1 \cdot T_3}
\tag{124}
$$

with $T_1 = 1/(1+NSUBPSTI2)$, $T_2 = NSUBPSTI1/Lod_{half}^{NSUBPSTI3}$, $T_3 = NSUBPSTI1/Lod_{half,ref}^{NSUBPSTI3}$ (125-127).

$$
N_{subps} = N_{subpp} \cdot N_{substi}
\tag{128}
$$

Mobility modifier:

$$
Muesti = \frac{1 + T_1 \cdot T_2}{1 + T_1 \cdot T_3}
\tag{129}
$$

with $T_1 = 1/(1+MUESTI2)$, $T_2 = MUESTI1/Lod_{half}^{MUESTI3}$, $T_3 = MUESTI1/Lod_{half,eff}^{MUESTI3}$ (130-132).

$$
Muephonon = Muephonon \times Muesti
\tag{133}
$$

### Section 12: Temperature Dependence

$$
T = TEMP + DTEMP + 273.15
\tag{134}
$$

$$
T = TEMP + 273.15 \quad\text{(if TEMP is instance param)}
\tag{135}
$$

$$
TNOM_{abs} = TNOM + 273.15
\tag{136}
$$

$$
\beta_{tnom} = \frac{q}{k_B \cdot TNOM_{abs}}
\tag{137}
$$

$$
\beta = \frac{q}{k_B T}
\tag{138}
$$

Bandgap temperature dependence:

$$
E_g = E_{g,tnom} - BGTMP1 \cdot (T - TNOM_{abs}) - BGTMP2 \cdot (T^2 - TNOM_{abs}^2)
\tag{139}
$$

$$
E_{g,tnom} = EG0 - 90.25 \times 10^{-6} \cdot TNOM_{abs} - 1.0 \times 10^{-7} \cdot TNOM_{abs}^2
\tag{140}
$$

$$
n_i = n_{i0} \cdot T^{3/2} \cdot \exp\left(-\beta\frac{E_g}{2q}\right)
\tag{141}
$$

Phonon mobility temperature dependence:

$$
\mu_{PH} = \frac{Muephonon}{(T/TNOM)^{MUETMP} \times E_{eff}^{MUEPH0}}
\tag{142}
$$

Saturation velocity temperature dependence:

$$
V_{max} = \frac{VMAX}{1.8 + 0.4(T/TNOM) + 0.1(T/TNOM)^2 - VTMP \cdot (1 - T/TNOM)}
\tag{143}
$$

Drift region mobility temperature:

$$
\mu_{drift0,temp} = \frac{RDRMUE}{(T/TNOM)^{RDRMUETMP}}
\tag{144}
$$

$$
\mu_{source0,temp} = \frac{RDRMUES}{(T/TNOM)^{RDRMUETMP}}
\tag{145}
$$

Drift region Vmax temperature:

$$
V_{max,drift,temp} = \frac{RDRVMAX}{1.8 + 0.4(T/TNOM) + 0.1(T/TNOM)^2 - RDRVTMP \cdot (1 - T/TNOM)}
\tag{147}
$$

$$
V_{max,source,temp} = \frac{RDRVMAXS}{1.8 + 0.4(T/TNOM) + 0.1(T/TNOM)^2 - RDRVTMP \cdot (1 - T/TNOM)}
\tag{148}
$$

$$
R_{drbb,temp} = RDRBB + RDRBBTMP(T - TNOM)
\tag{149}
$$

$$
R_{srbb,temp} = RDRBBS + RDRBBTMP(T - TNOM)
\tag{150}
$$

### Section 13: Resistances

#### Drain-Side Resistance

$$
R_{drift} = \frac{V_{ddp}}{I_{ddp}} + RSH \cdot NRD
\tag{151}
$$

$$
I_{ddp} = W_{eff} \cdot NF \cdot X_{ov} \cdot q \cdot NOVER \cdot \mu_{drift} \cdot \frac{V_{ddp}}{LDRIFT}
\tag{152}
$$

$$
\mu_{drift} = \frac{\mu_{drift0}}{\left[1 + \left(\frac{V_{ddp}}{V_{max,drift} \cdot LDRIFT \cdot \mu_{drift0}}\right)^{R_{drbb,temp}}\right]^{1/R_{drbb,temp}}}
\tag{153}
$$

$$
\mu_{drift0} = \mu_{drift0,temp}\left(1 + \frac{RDRMUEL}{(L_{gate} \cdot 10^6)^{RDRMUELP}}\right)
\tag{154}
$$

$$
V_{max,drift} = V_{max,drift,temp}\left(1 + \frac{RDRVMAXL}{(L_{gate} \cdot 10^6)^{RDRVMAXLP}}\right)\left(1 + \frac{RDRVMAXW}{(W_{gate} \cdot 10^6)^{RDRVMAXWP}}\right)
\tag{155}
$$

$$
X_{ov} = \sqrt{XLD^2 + RDRDJUNC^2}
\tag{156}
$$

#### Source-Side Resistance

$$
R_{source} = \frac{V_{ssp}}{I_{ssp}} + RSH \cdot NRS
\tag{157}
$$

$$
I_{ssp} = W_{eff} \cdot NF \cdot X_{ov} \cdot q \cdot NOVER \cdot \mu_{source} \cdot \frac{V_{ssp}}{LDRIFTS}
\tag{158}
$$

$$
\mu_{source} = \frac{\mu_{source0}}{\left[1 + \left(\frac{V_{ssp}}{V_{max,source} \cdot LDRIFTS \cdot \mu_{source0}}\right)^{R_{srbb,temp}}\right]^{1/R_{srbb,temp}}}
\tag{159}
$$

$$
\mu_{source0} = \mu_{source0,temp}\left(1 + \frac{RDRMUEL}{(L_{gate} \cdot 10^6)^{RDRMUELP}}\right)
\tag{160}
$$

$$
V_{max,source} = V_{max,source,temp}\left(1 + \frac{RDRVMAXL}{(L_{gate} \cdot 10^6)^{RDRVMAXLP}}\right)\left(1 + \frac{RDRVMAXW}{(W_{gate} \cdot 10^6)^{RDRVMAXWP}}\right)
\tag{161}
$$

#### Gate Resistance

$$
R_g = \frac{RSHG \cdot \left(XGW + \frac{W_{eff}}{3 \cdot NGCON}\right)}{NGCON \cdot (L_{drawn} - XGL) \cdot NF}
\tag{162}
$$

#### Bulk Resistance

$$
\Delta V_{bs} = I_{sub} \cdot R_{bulk}
\tag{163}
$$

$$
R_{bulk} = RBULKW \cdot W_{eff} + RBULK0
\tag{164}
$$

### Section 14: Capacitances

#### Intrinsic Capacitances

$$
C_{jk} = \delta \frac{\partial Q_j}{\partial V_k}, \quad \delta = \begin{cases} -1 & j \neq k \\ 1 & j = k \end{cases}
\tag{165}
$$

#### Lateral-Field Induced Charge

$$
Q_y = \epsilon_{Si} W_{eff} \cdot NF \cdot W_d \left(\frac{\phi_{s0} + V_{ds} - \phi_s(\Delta L)}{XQY} + \frac{XQY1 \cdot W_{eff} \times 10^6 \cdot NF}{(L_{gate} \times 10^6)^{XQY2}} V'_{bs}\right)
\tag{166}
$$

#### Overlap Charges

Drain-side overlap charge:

$$
Q_{god} = W_{effc} \cdot NF \cdot C_{FOX} \int_0^{LOVER} (V_{gs} - \phi_s)\, dy
\tag{167}
$$

Source-side overlap charge:

$$
Q_{gos} = W_{effc} \cdot NF \cdot C_{FOX} \int_0^{LOVER} (V_{gs} - \phi_s)\, dy
\tag{168}
$$

Surface-potential-based overlap (depletion/accumulation):

$$
Q_{over} = W_{effc} \cdot NF \cdot LOVER \sqrt{\frac{2\epsilon_{Si} q \cdot NOVER}{\beta}} \sqrt{\beta(\phi_s + V_{ds}) - 1}
\tag{169}
$$

Surface-potential-based overlap (inversion):

$$
Q_{over} = W_{effc} \cdot NF \cdot LOVER \cdot C_{FOX}(V_{gs} - VFBOVER - \phi_s)
\tag{170}
$$

Simplified bias-dependent overlap:

$$
Q_{god} = W_{effc} \cdot NF \cdot C_{FOX}\left[(V_{gs} - V_{ds})LOVER - OVSLP \cdot (1.2 - (\phi_{sL} - V_{ds})) \cdot (OVMAG + (V_{gs} - V_{ds}))\right]
\tag{171}
$$

Overlap capacitance per unit length:

$$
C_{ov} = C_{ov}' \cdot W_{effc} \cdot NF
\tag{172}
$$

For drain: $C_{ov}' = CGDO$ (if given) or $\frac{\epsilon_{ox}}{T_{FOX}} \cdot LOVER$ (173-174).

For source: $C_{ov}' = CGSO$ (if given) or $\frac{\epsilon_{ox}}{T_{FOX}} \cdot LOVER$ (175-176).

Gate-to-bulk overlap:

$$
C_{gbo} = -CGBO \cdot L_{gate}
\tag{177}
$$

#### Gate-Fringing Capacitance

$$
C_{fring} = \frac{\epsilon_{ox}}{\pi/2} W_{gate} \cdot NF \cdot \ln\left(1 + \frac{T_{POLY}}{T_{FOX}}\right)
\tag{178}
$$

### Section 15: Leakage Currents

#### Substrate (Body) Current

$$
I_{sub} = \frac{C_1}{C_2}\left[\phi(y) - \phi(0)\right] I_{ds} \exp\left(\frac{-\lambda C_2}{\phi(y) - \phi(0)}\right)
\tag{179}
$$

$$
\lambda^2 = \frac{\epsilon_{Si} X_j T_{FOX}}{\epsilon_{ox}}
\tag{180}
$$

Parameterized form:

$$
I_{sub} = SUB1 \cdot \left(1 + \frac{SUB1L}{(L/10^{-6})^{SUB1LP}}\right) \cdot Psisubsat \cdot I_{ds} \cdot \exp\left(\frac{-SUB2 \cdot \left(1 + \frac{SUB2L}{L/10^{-6}}\right)}{Psisubsat}\right)
\tag{181}
$$

COSUBSCALE=0 (backward compatible):

$$
Psisubsat = SVDS \cdot V_{ds} + P_{s0} - \left[\frac{1}{1 + \frac{SLG}{1 + L/10^{-6}}}\right] \cdot
$$
$$
\left[SVGS \cdot \left(1 + \frac{SVGSL}{(L/10^{-6})^{SVGSLP}}\right) \cdot \frac{1}{1 + \frac{SVGSW}{(W/10^{-6})^{SVGSWP}}}\right] \cdot
$$
$$
\left[V_{g0,sub} + \frac{qN_{SOI}\epsilon_{Si}}{C_{fox}^2}\left(1 - \sqrt{1 + \frac{2C_{fox}^2}{qN_{SOI}\epsilon_{Si}}\left(V_{g0,sub} - \frac{1}{\beta}\right)} - xvbs \cdot V'_{bs}\right)\right]
\tag{182}
$$

For body-tie devices with COFBE=2, an additional term $+DVBSSUB \cdot Q_h/C_{SOI}$ is added (183).

COSUBSCALE=1 (new): Uses similar form with $a$ factor and $SLGL/(L/10^{-6})^{SLGLP}$ dependence (187-188).

$$
V_{g0,sub} = V_{gs} - VFBSUB \cdot \left(1 + \frac{VFBSUBL}{(L/10^{-6})^{VFBSUBLP}}\right) + \Delta V_{th} - \phi_{Spg}
\tag{184}
$$

For body-tie COFBE=2: $V_{g0,sub}$ adds $+DVGPSUB$ (185, 191).

$$
xvbs = SVBS \cdot \left(1 + \frac{SVBSL}{(L/10^{-6})^{SVBSLP}}\right)
\tag{186}
$$

Impact-ionization bulk potential change:

$$
\Delta I_{ds} = \frac{2}{3}\sqrt{\frac{2\epsilon_{Si}qN_{subs}}{\beta}} \cdot \left[\frac{3\beta\Delta V_{bulk}}{2(\beta(\phi_{sL}-V'_{bs})-1)} \cdot (\beta(\phi_{sL}-V'_{bs})-1)^{3/2} - \ldots\right]
\tag{193}
$$

$$
\Delta V_{bulk} = IBPC1 \cdot (1 + IBPC2 \cdot \Delta V_{th}) \cdot I_{sub}
\tag{194}
$$

#### Gate Current

(i) Gate-to-channel:

$$
I_{gate} = q \cdot GLEAK1 \cdot \frac{E_1^2}{E} \cdot \exp\left(-\frac{E_{gp}^{3/2}}{GLEAK2 \cdot E}\right) \cdot \frac{Q_i}{\text{const}_0} \cdot W_{eff} \cdot NF \cdot L_{eff} \cdot \frac{GLEAK6}{GLEAK6 + V_{ds}} \cdot \frac{GLEAK7}{GLEAK7 + W_{eff} \cdot NF \cdot L_{eff}}
\tag{195}
$$

$$
E = \left(1 + \frac{E_y}{GLEAK5}\right) \cdot \left(1 - \frac{1}{1 + V_{gs}^2}\right) \cdot \frac{V_G}{T_{FOX}}
\tag{196}
$$

$$
V_G = V_{gs} - V_{fb} + GLEAK4 \cdot (\Delta V_{th} - \phi_{Spg}) \cdot L_{eff} - GLEAK3 \cdot \phi_s(\Delta L)
\tag{197}
$$

Gate current partition:

$$
I_{gate} = I_{gate,s} + I_{gate,d}
\tag{198}
$$

$$
I_{gate,s} = (1 - Partition) \cdot I_{gate}
\tag{199}
$$

$$
I_{gate,d} = Partition \cdot I_{gate}
\tag{200}
$$

$$
Partition = \frac{1}{I_{gate}} \int_0^{L_{eff}} \frac{y}{L_{eff}} I_{gate}(y)\, dy
\tag{201}
$$

(ii) Gate-to-bulk:

$$
I_{gb} = GLKB1 \cdot E_{gb}^2 \cdot \exp\left(\frac{-GLKB2}{E_{gb}}\right) \cdot W_{eff} \cdot NF \cdot L_{eff}
\tag{202}
$$

$$
E_{gb} = -\frac{V_{gs} - VFBC + GLKB3}{T_{FOX}}
\tag{203}
$$

(iii) Gate-to-source/drain:

$$
I_{gs} = \text{sign} \cdot GLKSD1 \cdot E_{gs}^2 \cdot \exp\left(T_{FOX}(-GLKSD2 \cdot V_{gs} + GLKSD3)\right) \cdot W_{eff} \cdot NF
\tag{204}
$$

$$
E_{gs} = \frac{V_{gs}}{T_{FOX}}
\tag{205}
$$

$$
I_{gd} = \text{sign} \cdot GLKSD1 \cdot E_{gd}^2 \cdot \exp\left(T_{FOX}(GLKSD2 \cdot (-V_{gs} + V_{ds}) + GLKSD3)\right) \cdot W_{eff} \cdot NF
\tag{206}
$$

$$
E_{gd} = \frac{V_{gs} - V_{ds}}{T_{FOX}}
\tag{207}
$$

#### GIDL

$$
I_{GIDL} = q \cdot GIDL1 \cdot \frac{E_1^2}{E} \cdot \exp\left(-GIDL2 \cdot \frac{E_g^{3/2}}{E}\right) \cdot W_{eff} \cdot NF \cdot \frac{V_{db}^3}{V_{db}^3 + GIDLVB}
\tag{208}
$$

$$
E = \frac{GIDL3 \cdot (V_{ds} + GIDL4) - V_{G0}}{T_{FOX}}
\tag{209}
$$

$$
V_{G0} = V_{gs} - \Delta V_{th} \cdot GIDL5
\tag{210}
$$

$$
V_{db} = V_{ds} - V'_{bs}
\tag{211}
$$

$$
\Delta V_{th} = \Delta V_{th,SC} + \Delta V_{th,P}
\tag{212}
$$

#### Valence Band Electron Tunneling

$$
I_{evb} = EVB1 \cdot q \left(\frac{\phi_b}{V_{FOX}} - 1\right) \cdot E_{FOX}^2 \cdot \exp\left(-\frac{EVB2\left(1 - (1 - \frac{V_{FOX}}{2\phi_b})^{3/2}\right)}{E_{FOX}}\right) \cdot W_{eff} \cdot NF \cdot L_{eff}
\tag{213}
$$

where $\phi_b = 4.12$ V (barrier height for hole).

$$
E_{FOX} = -\frac{FVBS \cdot V'_{bs} - V_{FOX} + \Delta V_{th,SC} + \Delta V_{th,P} + E_g + EVB3}{T_{FOX}}
\tag{214}
$$

$$
V_{FOX} = V_{G0} - \phi_{s,SOI}
\tag{215}
$$

### Section 16: Floating-Body Effect

$$
Q_h = \left[\exp(-\beta(\phi_{s0,SOI} - \Delta V_{sb})) + \beta(\phi_{s0,SOI} - \Delta V_{sb}) - 1\right]^{1/2} - \left[\exp(-\beta\phi_{s0,SOI}) + \beta\phi_{s0,SOI} - 1\right]^{1/2}
\tag{216}
$$

$$
\Delta V_{sb} = QHE1 \cdot \frac{1}{\beta}\log\left(1 + \frac{(I_{sub} + I_{evb}) L_p L_n}{q \cdot T_{SOI} \cdot W_{eff} \cdot e^{-\beta \cdot QHE2}(D_n N_d L_p + D_p N_d L_n)}\right)
\tag{217}
$$

where:

$$
L_n = \sqrt{D_n \cdot 10^{-7}}, \quad L_p = \sqrt{D_p \cdot 10^{-7}}
\tag{218-219}
$$

$$
N_d = 10^{20}\text{ cm}^{-3}, \quad D_n = 36\text{ cm}^2\text{/s}, \quad D_p = 13\text{ cm}^2\text{/s}
\tag{220-222}
$$

### Section 17: History Effect

$$
\tau_h = R_{sb} \cdot C_{FOX}
\tag{223}
$$

$$
R_{sb} = \frac{HIST1}{I_{sub} + HIST2}
\tag{224}
$$

$$
Q_h(t) = Q_h(t - \Delta t) + \frac{\Delta t}{\tau_h + \Delta t} \cdot (Q_{h0} - Q_h(t - \Delta t))
\tag{225}
$$

### Section 18: Self-Heating

Modeled as C-R thermal network. Power dissipation $I_{ds} V_{ds}$ flows through thermal resistance $R_{th}$ (RTH0) with thermal capacitance $C_{th}$ (CTH0). Temperature increment $\Delta Temp$ is fed back into temperature-dependent equations.

### Section 19: Source/Body and Drain/Body Diode

$$
T_{tnom} = \frac{T}{TNOM}
\tag{226}
$$

Forward current density:

$$
j_s = JS0 \cdot \exp\left(\frac{E_{g,tnom} \cdot \beta_{tnom} - E_g\beta + XTI \cdot \log(T_{tnom})}{NJ}\right)
\tag{227}
$$

Backward current density:

$$
j_{s2} = JS0 \cdot \exp\left(\frac{E_{g,tnom} \cdot \beta_{tnom} - E_g\beta + XTI2 \cdot \log(T_{tnom})}{NJ}\right)
\tag{228}
$$

$$
Nvtm = \frac{NJ}{\beta}
\tag{231}
$$

Saturation currents:

$$
I_{sbd} = W_{eff} \cdot NF \cdot T_{SOI} \cdot j_s
\tag{232}
$$

$$
I_{sbd2} = W_{eff} \cdot NF \cdot T_{SOI} \cdot j_{s2}
\tag{233}
$$

Drain-body junction voltage:

$$
V_{bcd} = V_{bcs} - V_{ds}
\tag{234}
$$

Transition voltage:

$$
vbdt = Nvtm \cdot \log\left(\frac{VDIFFJ}{I_{sbd}} \cdot (T_{tnom})^2 + 1\right)
\tag{235}
$$

Drain-body diode current ($V_{bcd} < vbdt$):

$$
I_{bd} = I_{sbd}\left[\exp\left(\frac{V_{bcd}}{Nvtm}\right) - 1\right]
\tag{236}
$$

Drain-body diode current ($V_{bcd} \geq vbdt$):

$$
I_{bd} = I_{sbd}\left[\exp\left(\frac{vbdt}{Nvtm}\right) - 1\right] + \frac{I_{sbd}}{Nvtm}\exp\left(\frac{vbdt}{Nvtm}\right)(V_{bcd} - vbdt)
\tag{237}
$$

$$
I_{bd} = I_{bd} + DIVX \cdot I_{sbd2} \cdot V_{bcd}
\tag{238}
$$

Source-body diode: Same equations (239-244) with $V_{bcs}$ replacing $V_{bcd}$.

### Section 19.2: Diode Capacitance

Area component:

$$
czb\theta = CJ \cdot A_\Theta
\tag{245}
$$

$$
czb\theta_{sw} = CJSW \cdot (P_\Theta - W_{effc} \cdot NF)
\tag{246}
$$

$$
czb\theta_{swg} = CJSWG \cdot W_{effc} \cdot NF
\tag{247}
$$

For $V_{bc\theta} = 0$: $Q_{b\theta} = 0$, $Cap_{b\theta} = czb\theta + czb\theta_{sw} + czb\theta_{swg}$ (248-249).

For $V_{bc\theta} < 0$ with $czb\theta > 0$:

$$
arg = 1 - \frac{V_{bc\theta}}{PB}
\tag{250}
$$

$$
sarg = \begin{cases} 1/\sqrt{arg} & (MJ = 0.5) \\ \exp(-MJ \cdot \log(arg)) & (MJ \neq 0.5) \end{cases}
\tag{251-252}
$$

$$
Q_{b\theta} = \frac{PB \cdot czb\theta(1 - arg \cdot sarg)}{1 - MJ}
\tag{253}
$$

$$
Cap_{b\theta} = czb\theta \cdot sarg
\tag{254}
$$

Maximum depletion charge (SOI limited by BOX):

$$
Q_{b\theta,max} = q \cdot N_{subs} \cdot (T_{SOI} - XJ) \cdot A_\Theta
\tag{255}
$$

Sidewall components follow same pattern with PBSW/MJSW (258-262) and PBSWG/MJSWG (263-267).

For $V_{bc\theta} > 0$:

$$
Q_{b\theta} = V_{bc\theta}(czb\theta + czb\theta_{sw} + czb\theta_{swg}) + V_{bc\theta}^2\left(\frac{czb\theta \cdot MJ}{2 \cdot PB} + \frac{czb\theta_{sw} \cdot MJSW}{2 \cdot PBSW} + \frac{czb\theta_{swg} \cdot MJSWG}{2 \cdot PBSWG}\right)
\tag{268}
$$

$$
Cap_{b\theta} = czb\theta + czb\theta_{sw} + czb\theta_{swg} + V_{bc\theta}\left(\frac{czb\theta \cdot MJ}{PB} + \frac{czb\theta_{sw} \cdot MJSW}{PBSW} + \frac{czb\theta_{swg} \cdot MJSWG}{PBSWG}\right)
\tag{269}
$$

Case $P_\Theta \leq W_{eff}$: $czb\theta_{swg} = CJSWG \cdot P_\Theta$ (270), no sidewall SW component, similar sub-equations (271-286).

### Section 20: Body-Tie Models

$$
ABTN = LBT \cdot WBTN
\tag{287}
$$

$$
ABTP = LBT \cdot WBTP
\tag{288}
$$

Body-tie gate capacitance:

$$
C_{gb,bt} = CbtN \cdot ABTN + CbtP \cdot ABTP
\tag{289}
$$

where $CbtN = CBTBN$ (if given) or computed from MOSFET with n-poly (290-291), $CbtP = CBTBP$ (if given) or computed from MOSFET with p-poly (292-293).

Effective width with body-tie periphery:

$$
W_{effc,source} = W_{effc} + PSBCP
\tag{294}
$$

$$
W_{effc,drain} = W_{effc} + PDBCP
\tag{295}
$$

$$
W_{effc} = W_{gate} - NBT \cdot XWDBT - (2 - NBT) \cdot XWDC
\tag{296}
$$

$$
W_{eff,source} = W_{eff} + PSBCP
\tag{297}
$$

$$
W_{eff,drain} = W_{eff} + PDBCP
\tag{298}
$$

$$
W_{eff} = W_{gate} - NBT \cdot XWDBT - (2 - NBT) \cdot XWD
\tag{299}
$$

Body-tie fringing capacitance:

$$
C_{fring,bt} = \frac{\epsilon_{ox}}{\pi/2} LBT \cdot NF \cdot \ln\left(1 + \frac{T_{POLY}}{T_{FOX}}\right)
\tag{300}
$$

Additional fringing from body-tie periphery:

$$
C_{fringing} = C_{fringing} + \frac{\epsilon_{ox}}{\pi/2} PSBCP \cdot NF \cdot \ln\left(1 + \frac{T_{POLY}}{T_{FOX}}\right) + \frac{\epsilon_{ox}}{\pi/2} PDBCP \cdot NF \cdot \ln\left(1 + \frac{T_{POLY}}{T_{FOX}}\right)
\tag{301-303}
$$

### Section 21: Noise Models

#### 1/f Noise

$$
S_{Ids} = \frac{I_{ds}^2}{\beta f^{FALPH} (L_{eff} - \Delta L) W_{eff} \cdot NF} \cdot \left[\frac{NFTRP}{(N_0 + N^*)(N_L + N^*)} + \frac{2\mu E_y \cdot NFALP}{N_L - N_0} \ln\frac{N_L + N^*}{N_0 + N^*} + (\mu E_y \cdot NFALP)^2\right]
\tag{304}
$$

$$
N^* = \frac{C_{FOX} + C_{dep} + CIT}{q\beta}
\tag{305}
$$

$$
Nflick = S_{Ids} \cdot f
\tag{306}
$$

#### Thermal Noise

$$
S_{id} = 4kT \frac{W_{eff} \cdot NF \cdot C_{FOX} V_{gvt}}{L_{eff} - \Delta L} \cdot \frac{\mu_f(1 + 3\eta + 6\eta^2)\mu_d^2 + (3 + 4\eta + 3\eta^2)\mu_d\mu_f + (6 + 3\eta + \eta^2)\mu_f}{15(1 + \eta)\mu_{av}^2}
\tag{307}
$$

$$
\mu_d = \frac{1}{1 + \left(\frac{\mu_0 E_{yd}}{V_{max,therm}}\right)^{BB}}
\tag{308}
$$

$$
\mu_{av} = \frac{\mu_f + \mu_d}{2}
\tag{309}
$$

$$
\eta = 1 - \frac{(\phi_{sL,SOI} - \phi_{s0,SOI}) + \chi(\phi_{sL,SOI} - \phi_{s0,SOI})}{V_{gvt}}
\tag{310}
$$

$$
\chi = 2\frac{\text{const}_0}{C_{FOX}} \left[\frac{2}{3\beta}\frac{(\beta(\phi_{sL,SOI}-V'_{bs})-1)^{3/2} - (\beta(\phi_{s0,SOI}-V'_{bs})-1)^{3/2}}{\phi_{sL,SOI}-\phi_{s0,SOI}} - \sqrt{\beta(\phi_{s0,SOI}-V'_{bs})-1}\right]
\tag{311}
$$

$$
Nthrml = S_{id}/(4kT)
\tag{312}
$$

#### Induced Gate Noise

$$
Nigate = S_{igate}/f^2
\tag{313}
$$

#### Coupling Noise

$$
Ncross = \frac{S_{igd}}{\sqrt{S_{igate} \cdot S_{id}}}
\tag{314}
$$

### Section 22: Non-Quasi-Static (NQS) Model

Carrier formation:

$$
q(t_i) = \frac{q(t_{i-1}) + \frac{\Delta t}{\tau}Q(t_i)}{1 + \frac{\Delta t}{\tau}}
\tag{315}
$$

Diffusion delay:

$$
\tau_{diff} = DLY1
\tag{316}
$$

Conduction delay:

$$
\tau_{cond} = DLY2 \cdot \frac{Q_i}{I_{ds}}
\tag{317}
$$

Combined delay (Matthiessen's rule):

$$
\frac{1}{\tau} = \frac{1}{\tau_{diff}} + \frac{1}{\tau_{cond}}
\tag{318}
$$

Body carrier RC delay:

$$
\tau_B = DLY3 \cdot C_{FOX}
\tag{319}
$$

#### AC Analysis

NQS charge in frequency domain:

$$
\hat{q}_a(\omega) = \left(\frac{1}{1 + (\tau\omega)^2} - i\frac{\tau\omega}{1 + (\tau\omega)^2}\right)\hat{Q}_a(\omega)
\tag{320}
$$

NQS capacitance:

$$
C_{ab} = -\frac{2(\tau\omega)^2}{(1+(\tau\omega)^2)^2} \cdot \frac{1}{\tau}\frac{\partial\tau}{\partial V_b} Q_{a,QS} + \frac{1}{1+(\tau\omega)^2} C_{ab,QS}
$$
$$
- i\left[\frac{\tau\omega(1-(\tau\omega)^2)}{(1+(\tau\omega)^2)^2} \cdot \frac{1}{\tau}\frac{\partial\tau}{\partial V_b} Q_{a,QS} + \frac{\tau\omega}{1+(\tau\omega)^2} C_{ab,QS}\right]
\tag{321}
$$

NQS y-parameters:

$$
y_{ab} = \frac{i\omega}{1+(\tau\omega)^2}\left[C_{ab,QS} + (\tau\omega)^2 A_{ab}(\omega) - i[\tau\omega B_{ab}(\omega) + \tau\omega C_{ab,QS}]\right]
\tag{322}
$$

$$
A_{ab} = -\frac{2}{\tau(1+(\tau\omega)^2)} \frac{\partial\tau}{\partial V_b} Q_{a,QS}
\tag{323}
$$

$$
B_{ab} = \frac{1}{\tau} \frac{1-(\tau\omega)^2}{1+(\tau\omega)^2} \frac{\partial\tau}{\partial V_b} Q_{a,QS}
\tag{324}
$$

$$
y_{gg} = \frac{i\omega}{1+(\tau\omega)^2}\left[C_{gg,QS} + (\tau\omega)^2 A_{gg}(\omega) - i[\tau\omega B_{gg}(\omega) + \tau\omega C_{gg,QS}]\right]
\tag{325}
$$

### Section 23: Multiplication Factor

All currents, capacitances, and noise quantities are multiplied by instance parameter $M$.
