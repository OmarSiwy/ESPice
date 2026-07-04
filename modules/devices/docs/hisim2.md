# HiSIM2 3.20 -- Parameter & Equation Reference

> Bulk planar MOSFET compact model (Hiroshima University STARC IGFET Model), surface-potential-based, CMC standard.

## Model Topology

HiSIM2 is a 4-terminal (drain **d**, gate **g**, source **s**, bulk **b**) bulk MOSFET model. Internally it creates nodes **dp**, **gp**, **sp**, **bp** (with optional body-resistance nodes **db**, **sb**) connected through optional source/drain series resistances (RS, RD), gate resistance (RSHG), and a 5-resistor substrate network (RBPB, RBPD, RBPS, RBDB, RBSB). NQS operation adds internal nodes `int_nqs_b` and `int_nqs_i`. The intrinsic MOSFET is between dp-gp-sp-bp with drift-diffusion channel current, junction diodes at b-d and b-s, overlap capacitances at gate-drain and gate-source overlap regions, and lateral-field-induced capacitance (Qy).

## Parameters

### Model Flags

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TYPE | TYPE | - | 1 | {-1, 1} | MOSFET type: 1=NMOS, -1=PMOS |
| VERSION | VERSION | - | 3.20 | - | Model version |
| INFO | INFO | - | 0 | - | Information/debug level |
| CORSRD | CORSRD | - | 0 | [-1, 2] | Source/drain resistance handling |
| COIPRV | COIPRV | - | 0 | [0, 1] | Use Ids_prv as initial guess |
| COPPRV | COPPRV | - | 0 | [0, 1] | Not supported |
| COADOV | COADOV | - | 1 | [0, 1] | Add overlap to intrinsic capacitance |
| COISUB | COISUB | - | 0 | [0, 1] | Calculate substrate current |
| COIIGS | COIIGS | - | 0 | [0, 1] | Calculate gate tunneling current |
| COGIDL | COGIDL | - | 0 | [0, 1] | Calculate GIDL/GISL |
| COOVLP | COOVLP | - | 1 | [0, 1] | Calculate overlap charge |
| COFLICK | COFLICK | - | 0 | [0, 1] | Calculate 1/f noise |
| COISTI | COISTI | - | 0 | [0, 1] | Calculate STI leakage |
| CONQS | CONQS | - | 0 | [0, 1] | NQS mode (1) vs QS mode (0) |
| COTHRML | COTHRML | - | 0 | [0, 1] | Calculate thermal noise |
| COIGN | COIGN | - | 0 | [0, 1] | Calculate induced gate noise |
| CODFM | CODFM | - | 0 | [0, 1] | DFM calculation |
| CORECIP | CORECIP | - | 1 | [0, 1] | Accurate capacitance reciprocity |
| COQY | COQY | - | 0 | [0, 1] | Calculate Qy |
| COQOVSM | COQOVSM | - | 1 | [0, 2] | Smoothing method for Qover |
| COERRREP | COERRREP | - | 1 | [0, 1] | Error reporting |
| CODDLT | CODDLT | - | 1 | [0, 1] | DDLT model selector |
| CODIO | CODIO | - | 0 | - | Updated diode model selector |
| CODEP | CODEP | - | 0 | [0, 3] | Depletion device selector |
| CORG | CORG | - | 0 | [0, 1] | Gate resistance (instance/model) |
| CORBNET | CORBNET | - | 0 | [0, 1] | Body resistance network (instance/model) |
| COVDSRES | COVDSRES | - | 3 | [-1, 3] | Vdssatres model switch |
| COPT | COPT | - | 0 | [0, 1] | Punchthrough flag |
| COPSPT | COPSPT | - | 0 | [0, 1] | Ps0 method for deep punchthrough |
| COPB20COMPAT | COPB20COMPAT | - | 1 | [0, 1] | Pb20 compatibility mode |

### Geometry & Process

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| TOX | $t_{ox}$ | m | 3e-9 | (0, inf) | Gate oxide thickness |
| XLD | $X_{LD}$ | m | 0 | [0, inf) | Lateral diffusion of S/D under gate |
| XLDC | $X_{LDC}$ | m | XLD | [0, inf) | Lateral diffusion (capacitance) |
| LOVER | $L_{over}$ | m | 30e-9 | [0, inf) | Gate-S/D overlap length |
| XWD | $X_{WD}$ | m | 0 | - | Lateral diffusion along width |
| XWDC | $X_{WDC}$ | m | XWD | - | Lateral diffusion along width (capacitance) |
| XL | $X_L$ | m | 0 | - | Gate length offset (mask/etch) |
| XW | $X_W$ | m | 0 | - | Gate width offset (mask/etch) |
| LL | $LL$ | m^(LLN+1) | 0 | - | Gate length reduction parameter |
| LLD | $LLD$ | m | 0 | - | Gate length reduction offset |
| LLN | $LLN$ | - | 0 | - | Gate length reduction exponent |
| WL | $WL$ | m^(WLN+1) | 0 | - | Gate width reduction parameter |
| WL1 | $WL1$ | - | 0 | - | Gate width parameter |
| WL1P | $WL1P$ | - | 1.0 | - | Gate width parameter |
| WL2 | $WL2$ | V | 0 | - | Gate width parameter |
| WL2P | $WL2P$ | - | 1.0 | - | Gate width parameter |
| WLD | $WLD$ | m | 0 | - | Gate width reduction offset |
| WLN | $WLN$ | - | 0 | - | Gate width reduction exponent |
| TPOLY | $t_{poly}$ | m | 200e-9 | [0, inf) | Poly gate height |
| KAPPA | $\kappa$ | - | 3.90 | (0, inf) | Dielectric constant for high-k gate |
| TNOM | $T_{nom}$ | degC | 27.0 | [-273.15, inf) | Nominal temperature |
| TOXOV | $t_{oxov}$ | m | TOX | (0, inf) | Oxide thickness of overlap region |

### Doping & Flat-Band

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VFBC | $V_{FBC}$ | V | -1.0 | - | Constant part of flat-band voltage |
| VFBCL | $V_{FBCL}$ | - | 0 | - | Channel length dependence of VFBC |
| VFBCLP | $V_{FBCLP}$ | - | 1.0 | - | Channel length dependence of VFBC (exponent) |
| VBI | $V_{bi}$ | V | 1.1 | - | Built-in potential |
| NSUBC | $N_{SUBC}$ | 1/cm^3 | 5e17 | (0, inf) | Substrate impurity concentration |
| NSUBP | $N_{SUBP}$ | 1/cm^3 | 1e18 | (0, inf) | Maximum pocket concentration |
| NSUBPL | $N_{SUBPL}$ | - | 0.001 | (0, inf) | Gate-length dependence of NSUBP |
| NSUBPFAC | $N_{SUBPFAC}$ | - | 1.0 | - | Minimum reduction factor for NSUBP |
| NSUBPDLT | $N_{SUBPDLT}$ | - | 0.01 | - | Delta for NSUBP smoothing |
| NSUBPW | $N_{SUBPW}$ | - | 0 | - | Width dependence of pocket concentration |
| NSUBPWP | $N_{SUBPWP}$ | - | 1.0 | - | Width dependence of pocket concentration (exp) |
| PARL2 | $P_{ARL2}$ | m | 10e-9 | (-inf, L) | Under-diffusion length |
| LP | $L_P$ | m | 0 | [0, L] | Length of pocket potential |
| LPEXT | $L_{PEXT}$ | m | 1e-50 | (0, inf) | Pocket extension length |
| NPEXT | $N_{PEXT}$ | 1/cm^3 | 5e17 | (0, inf) | Pocket extension concentration |
| NPEXTW | $N_{PEXTW}$ | - | 0 | - | Width dependence of NPEXT |
| NPEXTWP | $N_{PEXTWP}$ | - | 1.0 | - | Width dependence of NPEXT (exponent) |
| VFBOVER | $V_{FBOVER}$ | - | 0 | - | Flat-band voltage in overlap region |
| NOVER | $N_{OVER}$ | 1/cm^3 | 1e19 | [0, inf) | Impurity concentration in overlap region |

### Short-Channel & Pocket Effects (SCE)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| SCP1 | $SCP_1$ | - | 1.0 | - | Pocket SCE parameter |
| SCP2 | $SCP_2$ | 1/V | 0 | - | Pocket SCE Vds dependence |
| SCP3 | $SCP_3$ | m/V | 0 | - | Pocket SCE length dependence |
| SC1 | $SC_1$ | - | 1.0 | - | SCE parameter |
| SC2 | $SC_2$ | 1/V | 0 | - | SCE Vds dependence |
| SC3 | $SC_3$ | m/V | 0 | - | SCE length dependence |
| SC4 | $SC_4$ | 1/V | 0 | - | SCE parameter |
| SCP21 | $SCP_{21}$ | V | 0 | - | SCE modification for small Vds |
| SCP22 | $SCP_{22}$ | V^3 | 0 | - | SCE modification for small Vds |
| BS1 | $BS_1$ | V^2 | 0 | - | Body-coefficient modification |
| BS2 | $BS_2$ | V | 0.9 | - | Body-coefficient modification |
| SC3VBS | $SC3_{VBS}$ | - | 0 | - | Vbs clamping for SC3 |

### Poly-Gate Depletion

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| PGD1 | $PGD_1$ | V | 0 | - | Gate-poly depletion coefficient |
| PGD2 | $PGD_2$ | V | 0.3 | - | Gate-poly depletion threshold |
| PGD4 | $PGD_4$ | - | 0 | - | Gate-poly depletion parameter |

### Quantum Mechanical Effect

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| QME1 | $QME_1$ | V m | 0 | - | Quantum effect strength |
| QME2 | $QME_2$ | V | 2.0 | - | Quantum effect voltage parameter |
| QME3 | $QME_3$ | m | 0 | - | Quantum effect offset |

### Mobility

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| MUECB0 | $\mu_{ECB0}$ | cm^2/Vs | 190 | - | Coulomb scattering constant |
| MUECB1 | $\mu_{ECB1}$ | cm^2/Vs | 30 | - | Coulomb scattering coefficient |
| MUECB0LP | $\mu_{ECB0LP}$ | - | 0 | - | Length dependence of MUECB0 |
| MUECB1LP | $\mu_{ECB1LP}$ | - | 0 | - | Length dependence of MUECB1 |
| MUEPH0 | $\mu_{EPH0}$ | - | 0.3 | - | Phonon scattering Eeff exponent |
| MUEPH1 | $\mu_{EPH1}$ | - | 25e3 (N) / 30e3 (P) | (0, inf) | Phonon scattering coefficient |
| MUEPHL | $\mu_{EPHL}$ | - | 0 | - | Phonon: L dependence |
| MUEPLP | $\mu_{EPLP}$ | - | 1.0 | - | Phonon: L exponent |
| MUEPLD | $\mu_{EPLD}$ | - | 0 | - | Phonon: L offset |
| MUEPHW | $\mu_{EPHW}$ | - | 0 | - | Phonon: W dependence |
| MUEPWP | $\mu_{EPWP}$ | - | 1.0 | - | Phonon: W exponent |
| MUEPWD | $\mu_{EPWD}$ | - | 0 | - | Phonon: W offset |
| MUEPHS | $\mu_{EPHS}$ | - | 0 | - | Phonon: WL dependence |
| MUEPSP | $\mu_{EPSP}$ | - | 1.0 | - | Phonon: WL exponent |
| MUEPHL2 | $\mu_{EPHL2}$ | - | 0 | - | Phonon: 2nd L dependence |
| MUEPLP2 | $\mu_{EPLP2}$ | - | 1.0 | - | Phonon: 2nd L exponent |
| MUEPHW2 | $\mu_{EPHW2}$ | - | 0 | - | Phonon: 2nd W dependence |
| MUEPWP2 | $\mu_{EPWP2}$ | - | 1.0 | - | Phonon: 2nd W exponent |
| MUESR0 | $\mu_{ESR0}$ | - | 2.0 | - | Surface roughness Eeff exponent |
| MUESR1 | $\mu_{ESR1}$ | cm^2/(Vs)(V/cm)^MUESR0 | 5e14 | (0, inf) | Surface roughness coefficient |
| MUESRL | $\mu_{ESRL}$ | - | 0 | - | Surface roughness: L dependence |
| MUESLP | $\mu_{ESLP}$ | - | 1.0 | - | Surface roughness: L exponent |
| MUESRW | $\mu_{ESRW}$ | - | 0 | - | Surface roughness: W dependence |
| MUESWP | $\mu_{ESWP}$ | - | 1.0 | - | Surface roughness: W exponent |
| MUETMP | $\mu_{ETMP}$ | - | 1.5 | - | Mobility temperature exponent |
| NDEP | $N_{DEP}$ | - | 1.0 | - | Eeff coefficient for Qbm |
| NDEPL | $N_{DEPL}$ | - | 0 | - | Eeff: L dependence |
| NDEPLP | $N_{DEPLP}$ | - | 1.0 | - | Eeff: L exponent |
| NDEPW | $N_{DEPW}$ | - | 0 | - | Eeff: W dependence |
| NDEPWP | $N_{DEPWP}$ | - | 1.0 | - | Eeff: W exponent |
| NINV | $N_{INV}$ | - | 0.5 | - | Eeff coefficient for Qnm |
| NINVD | $N_{INVD}$ | 1/V | 0 | - | Vdse dependence on Eeff |
| NINVDL | $N_{INVDL}$ | - | 0 | - | L dependence of NINVD |
| NINVDLP | $N_{INVDLP}$ | - | 1.0 | - | L exponent of NINVD |
| BB | $\beta\beta$ | - | 2 (N) / 1 (P) | [0.1, inf) | Velocity saturation exponent |
| VMAX | $v_{max}$ | cm/s | 1e7 | (0, inf) | Saturation velocity |
| VTMP | $V_{TMP}$ | - | 0 | - | Temperature dependence of Vmax |
| WVTH0 | $W_{VTH0}$ | - | 0 | - | Threshold voltage shift |

### Channel Length Modulation (CLM)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CLM1 | $CLM_1$ | - | 0.7 | - | CLM partition parameter |
| CLM2 | $CLM_2$ | - | 2.0 | - | CLM depletion charge coefficient |
| CLM3 | $CLM_3$ | - | 1.0 | - | CLM inversion charge coefficient |
| CLM5 | $CLM_5$ | - | 1.0 | - | CLM Lgate exponent |
| CLM6 | $CLM_6$ | - | 0 | - | CLM Lgate coefficient |

### Vds Smoothing (DDLT)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| DDLTMAX | $DDLT_{MAX}$ | - | 10 | [1, inf) | Vds smoothing coefficient |
| DDLTSLP | $DDLT_{SLP}$ | um^-1 | 10 | [0, inf) | Lgate dependence of DDLT |
| DDLTICT | $DDLT_{ICT}$ | - | 0 | - | Lgate dependence of DDLT |

### Overshoot

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VOVER | $V_{OVER}$ | - | 0.3 | - | Overshoot parameter |
| VOVERP | $V_{OVERP}$ | - | 0.3 | - | Overshoot exponent |
| VOVERS | $V_{OVERS}$ | - | 0 | - | Overshoot parameter |
| VOVERSP | $V_{OVERSP}$ | - | 0 | - | Overshoot exponent |

### Substrate Current (Isub)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| SUB1 | $SUB_1$ | 1/V | 10 | - | Impact ionization coefficient |
| SUB2 | $SUB_2$ | V | 25 | - | Impact ionization critical field |
| SUB1L | $SUB_{1L}$ | - | 2.5e-3 | - | L dependence of SUB1 |
| SUB1LP | $SUB_{1LP}$ | - | 1.0 | - | L exponent of SUB1 |
| SUB2L | $SUB_{2L}$ | m | 2e-6 | - | L dependence of SUB2 |
| SVGS | $SV_{GS}$ | - | 0.8 | - | Vg coefficient for Psislsat |
| SVBS | $SV_{BS}$ | - | 0.5 | - | Vbs coefficient for Psislsat |
| SVBSL | $SV_{BSL}$ | - | 0 | - | L dependence of SVBS |
| SVBSLP | $SV_{BSLP}$ | - | 1.0 | - | L exponent of SVBS |
| SVDS | $SV_{DS}$ | - | 0.8 | - | Vds dependence of Isub |
| SLG | $SLG$ | m | 30e-9 | [0, inf) | Lgate dependence of Isub |
| SLGL | $SLGL$ | - | 0 | - | L dependence of SLG |
| SLGLP | $SLGLP$ | - | 1.0 | - | L exponent of SLG |
| SVGSL | $SV_{GSL}$ | - | 0 | - | L dependence of SVGS |
| SVGSLP | $SV_{GSLP}$ | - | 1.0 | - | L exponent of SVGS |
| SVGSW | $SV_{GSW}$ | - | 0 | - | W dependence of SVGS |
| SVGSWP | $SV_{GSWP}$ | - | 1.0 | - | W exponent of SVGS |
| SUBTMP | $SUB_{TMP}$ | 1/degC | 0 | - | Temperature dependence of Isub |
| IBPC1 | $IBPC_1$ | V/A | 0 | - | IBPC parameter |
| IBPC2 | $IBPC_2$ | 1/A | 0 | - | IBPC dVth dependence |

### Gate Current (Tunneling)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| GLEAK1 | $GL_1$ | V^(-3/2) s^-1 | 50 | - | Gate current pre-exponential |
| GLEAK2 | $GL_2$ | V^(-1/2)/m | 10e6 | - | Gate current exponential coefficient |
| GLEAK3 | $GL_3$ | - | 0.06 | - | Gate current Psdl coefficient |
| GLEAK4 | $GL_4$ | 1/m | 4.0 | - | Gate current dVth scaling |
| GLEAK5 | $GL_5$ | V/m | 7.5e3 | (0, inf) | Gate current field enhancement |
| GLEAK6 | $GL_6$ | V | 0.25 | - | Gate current Vds partitioning |
| GLEAK7 | $GL_7$ | m^2 | 1e-6 | - | Gate current area scaling |
| GLKSD1 | $GLKSD_1$ | A m/V^2 | 1e-15 | - | S/D gate current coefficient |
| GLKSD2 | $GLKSD_2$ | 1/(V m) | 5e6 | - | S/D gate current field parameter |
| GLKSD3 | $GLKSD_3$ | 1/m | -5e6 | - | S/D gate current constant |
| GLKB1 | $GLKB_1$ | A/(V^2 m^2) | 5e-16 | - | Gate-bulk current coefficient |
| GLKB2 | $GLKB_2$ | m/V | 1.0 | - | Gate-bulk current field parameter |
| GLKB3 | $GLKB_3$ | V | 0 | - | Gate-bulk current offset |
| EGIG | $E_{GIG}$ | V | 0 | - | Gate current bandgap parameter |
| IGTEMP2 | $IG_{T2}$ | V K | 0 | - | Gate current temperature coefficient |
| IGTEMP3 | $IG_{T3}$ | V K^2 | 0 | - | Gate current temperature coefficient |

### GIDL/GISL

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| GIDL1 | $GIDL_1$ | V^(-3/2) s^-1 m | 2.0 | - | GIDL pre-exponential |
| GIDL2 | $GIDL_2$ | V^-0.5 m^-1 | 3e7 | - | GIDL exponential coefficient |
| GIDL3 | $GIDL_3$ | - | 0.9 | - | GIDL Vds coefficient |
| GIDL4 | $GIDL_4$ | V | 0 | - | GIDL Vds offset |
| GIDL5 | $GIDL_5$ | - | 0.2 | - | GIDL dVth scaling |
| GIDL6 | $GIDL_6$ | - | 0 | - | GIDL Vbs dependence |
| GIDL7 | $GIDL_7$ | - | 1.0 | - | GIDL high-field correction exponent |

### Narrow Channel Effect

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| WFC | $W_{FC}$ | F/m | 0 | - | Narrow channel fringing capacitance |
| NSUBCW | $N_{SUBCW}$ | - | 0 | - | Width dependence of substrate concentration |
| NSUBCWP | $N_{SUBCWP}$ | - | 1.0 | - | Width exponent of substrate concentration |
| NSUBCMAX | $N_{SUBCMAX}$ | 1/cm^3 | 5e18 | - | Upper limit of substrate concentration |
| NSUBCW2 | $N_{SUBCW2}$ | - | 0 | - | 2nd width dependence |
| NSUBCWP2 | $N_{SUBCWP2}$ | - | 1.0 | - | 2nd width exponent |

### Series Resistance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RS | $R_S$ | Ohm m | 0 | [0, inf) | Source contact resistance |
| RD | $R_D$ | Ohm m | 0 | [0, inf) | Drain contact resistance |
| RSH | $R_{SH}$ | Ohm/sq | 0 | [0, inf) | Diffusion sheet resistance |
| RSHG | $R_{SHG}$ | Ohm/sq | 0 | [0, inf) | Gate electrode sheet resistance |
| RMIN | $R_{MIN}$ | - | 1e-4 | (0, inf) | Minimum resistance for RS/RD |

### Body Resistance Network

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| RBPB | $R_{BPB}$ | Ohm | 50 | [0, inf) | Body-to-internal-body resistance |
| RBPD | $R_{BPD}$ | Ohm | 50 | [0, inf) | Body-to-drain resistance |
| RBPS | $R_{BPS}$ | Ohm | 50 | [0, inf) | Body-to-source resistance |
| RBDB | $R_{BDB}$ | Ohm | 50 | [0, inf) | Drain-body resistance |
| RBSB | $R_{BSB}$ | Ohm | 50 | [0, inf) | Source-body resistance |
| GBMIN | $G_{BMIN}$ | - | 1e-12 | [0, 1e4] | Minimum substrate conductance |

### STI (Shallow Trench Isolation)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NSTI | $N_{STI}$ | 1/cm^3 | 5e17 | (0, inf) | STI impurity concentration |
| WSTI | $W_{STI}$ | m | 0 | - | STI width parameter |
| WSTIL | $W_{STIL}$ | - | 0 | - | L dependence of WSTI |
| WSTILP | $W_{STILP}$ | - | 1.0 | - | L exponent of WSTI |
| WSTIW | $W_{STIW}$ | - | 0 | - | W dependence of WSTI |
| WSTIWP | $W_{STIWP}$ | - | 1.0 | - | W exponent of WSTI |
| SCSTI1 | $SCSTI_1$ | - | 0 | - | STI SCE parameter |
| SCSTI2 | $SCSTI_2$ | 1/V | 0 | - | STI SCE Vds dependence |
| VTHSTI | $V_{THSTI}$ | V | 0 | - | STI threshold shift |
| VDSTI | $V_{DSTI}$ | - | 0 | - | STI Vds dependence |
| MUESTI1 | $\mu_{ESTI1}$ | m | 0 | [0, inf) | STI stress mobility |
| MUESTI2 | $\mu_{ESTI2}$ | - | 0 | (-1, inf) | STI stress mobility |
| MUESTI3 | $\mu_{ESTI3}$ | - | 1.0 | - | STI stress mobility exponent |
| NSUBPSTI1 | $N_{SUBPSTI1}$ | m | 0 | [0, inf) | STI stress pocket |
| NSUBPSTI2 | $N_{SUBPSTI2}$ | - | 0 | (-1, inf) | STI stress pocket |
| NSUBPSTI3 | $N_{SUBPSTI3}$ | - | 1.0 | - | STI stress pocket exponent |
| NSUBCSTI1 | $N_{SUBCSTI1}$ | m | 0 | [0, inf) | STI stress channel concentration |
| NSUBCSTI2 | $N_{SUBCSTI2}$ | - | 0 | (-1, inf) | STI stress channel concentration |
| NSUBCSTI3 | $N_{SUBCSTI3}$ | - | 1.0 | - | STI stress channel concentration exponent |

### Band Gap & Temperature

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| EG0 | $E_{g0}$ | eV | 1.1785 | (0, inf) | Bandgap at 0K |
| BGTMP1 | $BG_{TMP1}$ | eV/K | 90.25e-6 | - | 1st order bandgap temperature coefficient |
| BGTMP2 | $BG_{TMP2}$ | eV/K^2 | 1e-7 | - | 2nd order bandgap temperature coefficient |

### Overlap Capacitance

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| CGSO | $C_{GSO}$ | F/m | 0 | [0, inf) | Gate-source overlap capacitance/width |
| CGDO | $C_{GDO}$ | F/m | 0 | [0, inf) | Gate-drain overlap capacitance/width |
| CGBO | $C_{GBO}$ | F/m | 0 | [0, inf) | Gate-bulk overlap capacitance/length |
| OVSLP | $OV_{SLP}$ | m/V | 2.1e-7 | - | Overlap capacitance slope |
| OVMAG | $OV_{MAG}$ | V | 0.6 | - | Overlap capacitance magnitude |
| OVINVDLT | $OV_{INVDLT}$ | - | 75.0 | (0, inf) | Analytical overlap inversion (COQOVSM=2) |

### Lateral-Field Capacitance (Qy)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| XQY | $X_{QY}$ | m | 10e-9 | [0, inf) | Distance from drain junction to max E-field |
| XQY1 | $X_{QY1}$ | F | 0 | - | Vbs dependence of Qy |
| XQY2 | $X_{QY2}$ | - | 2.0 | - | Lgate dependence of Qy |
| QYRAT | $Q_{YRAT}$ | - | 0.5 | - | Qy drain/source partitioning ratio |

### Junction Diode

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| JS0 | $J_{S0}$ | A/m^2 | 0.5e-6 | - | Saturation current density |
| JS0SW | $J_{S0SW}$ | A/m | 0 | - | Sidewall saturation current density |
| NJ | $n_J$ | - | 1.0 | (0, inf) | Emission coefficient |
| NJSW | $n_{JSW}$ | - | 1.0 | (0, inf) | Sidewall emission coefficient |
| XTI | $X_{TI}$ | - | 2.0 | - | Temperature exponent |
| XTI2 | $X_{TI2}$ | - | 0 | - | 2nd temperature coefficient |
| CISB | $C_{ISB}$ | - | 0 | - | Reverse bias saturation current |
| CVB | $C_{VB}$ | - | 0 | - | Bias dependence of CISB |
| CTEMP | $C_{TEMP}$ | - | 0 | - | Temperature coefficient |
| CISBK | $C_{ISBK}$ | A | 0 | - | Reverse bias saturation current |
| CVBK | $C_{VBK}$ | - | CVB | - | Bias dependence of CISBK |
| DIVX | $DIV_X$ | 1/V | 0 | - | Reverse current coefficient |
| VDIFFJ | $V_{DIFFJ}$ | V | 0.6e-3 | - | Junction diode threshold voltage |
| CJ | $C_J$ | F/m^2 | 5e-4 | - | Bottom junction capacitance at zero bias |
| CJSW | $C_{JSW}$ | F/m | 5e-10 | - | Sidewall junction capacitance at zero bias |
| CJSWG | $C_{JSWG}$ | F/m | 5e-10 | - | Gate sidewall junction capacitance at zero bias |
| MJ | $M_J$ | - | 0.5 | (-inf, 1) | Bottom junction grading coefficient |
| MJSW | $M_{JSW}$ | - | 0.33 | (-inf, 1) | Sidewall grading coefficient |
| MJSWG | $M_{JSWG}$ | - | 0.33 | (-inf, 1) | Gate sidewall grading coefficient |
| PB | $\phi_B$ | V | 1.0 | (0, inf) | Bottom junction built-in potential |
| PBSW | $\phi_{BSW}$ | V | 1.0 | (0, inf) | Sidewall built-in potential |
| PBSWG | $\phi_{BSWG}$ | V | 1.0 | (0, inf) | Gate sidewall built-in potential |
| TCJBD | $TC_{JBD}$ | K^-1 | 0 | - | Temperature dependence of CJ (drain) |
| TCJBS | $TC_{JBS}$ | K^-1 | 0 | - | Temperature dependence of CJ (source) |
| TCJBDSW | $TC_{JBDSW}$ | K^-1 | 0 | - | Temperature dependence of CJSW (drain) |
| TCJBSSW | $TC_{JBSSW}$ | K^-1 | 0 | - | Temperature dependence of CJSW (source) |
| TCJBDSWG | $TC_{JBDSWG}$ | K^-1 | 0 | - | Temperature dependence of CJSWG (drain) |
| TCJBSSWG | $TC_{JBSSWG}$ | K^-1 | 0 | - | Temperature dependence of CJSWG (source) |

Note: Separate drain/source junction parameters (JS0D, JS0S, NJD, NJS, CJD, CJS, etc.) default to the shared parameter values and follow the same pattern.

### Symmetry

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| VZADD0 | $V_{ZADD0}$ | V | 0.02 | (0, inf) | Vzadd at Vds=0 |
| PZADD0 | $P_{ZADD0}$ | V | 0.02 | (0, inf) | Pzadd at Vds=0 |

### NQS (Non-Quasi-Static)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| DLY1 | $DLY_1$ | s | 100e-12 | (0, inf) | Transit time parameter |
| DLY2 | $DLY_2$ | m^2 | 0.7 | - | Transit time parameter |
| DLY3 | $DLY_3$ | Ohm m^2 | 0.8e-6 | (0, inf) | Bulk charge time constant |

### 1/f Noise

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NFTRP | $N_{FTRP}$ | V^-1 | 10e9 | - | Trap density / attenuation coefficient ratio |
| NFALP | $N_{FALP}$ | cm s | 1e-19 | - | Mobility fluctuation contribution |
| NFALP1 | $N_{FALP1}$ | cm s | NFALP | - | Mobility fluctuation (channel) |
| NFALP2 | $N_{FALP2}$ | cm s | NFALP | - | Mobility fluctuation (drain) |
| FALPH | $f_{\alpha}$ | s m^3 | 1.0 | (0, inf) | 1/f noise frequency exponent |
| SIDP | $SID_P$ | - | 2.0 | - | Ids exponent in 1/f noise |
| DLNOISE | $\Delta L_{noise}$ | m | 0 | - | Noise channel length offset |
| CIT | $C_{IT}$ | F/m^2 | 0 | - | Interface trap capacitance |

### Punchthrough

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| PTL | $PTL$ | V^(PTP-1) | 0 | - | Punchthrough strength |
| PTP | $PTP$ | - | 3.5 | - | Punchthrough exponent |
| PT2 | $PT_2$ | V^-1 | 0 | - | Vds dependence of punchthrough |
| PTLP | $PTLP$ | - | 1.0 | - | L dependence of punchthrough |
| PT4 | $PT_4$ | V^-1 | 0 | - | Vbs dependence of punchthrough |
| PT4P | $PT4P$ | - | 1.0 | - | Vbs exponent of punchthrough |
| GDL | $GDL$ | - | 0 | - | High-field effect strength |
| GDLP | $GDLP$ | - | 0 | - | L dependence of high-field effect |
| GDLD | $GDLD$ | - | 0 | - | L offset of high-field effect |
| XJPT | $X_{JPT}$ | m | 3e-8 | (0, 1] | Junction depth for deep punchthrough |
| NJUNC | $N_{JUNC}$ | cm^-3 | 1e20 | (0, inf) | Junction doping for deep punchthrough |
| MUPT | $\mu_{PT}$ | m^2/V/s | 0 | [0, inf) | Mobility for deep punchthrough |
| VFBPT | $V_{FBPT}$ | V | 0 | - | dVfb for deep punchthrough |
| PSLIMPT | $Ps_{LIMPT}$ | V | 0 | - | Ps0 limit for deep punchthrough |

### Well Proximity Effect (WPE)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| WEB | $WEB$ | - | 0 | - | WPE SCB coefficient |
| WEC | $WEC$ | - | 0 | - | WPE SCC coefficient |
| NSUBCWPE | $N_{SUBCWPE}$ | 1/cm^3 | 0 | - | Channel concentration change due to WPE |
| NPEXTWPE | $N_{PEXTWPE}$ | 1/cm^3 | 0 | - | Pocket-tail change due to WPE |
| NSUBPWPE | $N_{SUBPWPE}$ | 1/cm^3 | 0 | - | Pocket concentration change due to WPE |

### DFM (Design For Manufacturing)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| MPHDFM | $MPH_{DFM}$ | - | -0.3 | - | NSUBCDFM dependence of phonon scattering |

### STI Reference Distances

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| SAREF | $SA_{REF}$ | m | 1e-6 | [0, inf) | Reference STI-to-gate distance |
| SBREF | $SB_{REF}$ | m | 1e-6 | [0, inf) | Reference STI-to-gate distance |

### GMIN

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| GMIN | $G_{MIN}$ | - | 0 | [0, 1e4] | Minimum conductance |

### Vertical Doping (NSUBD)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NSUBD | $N_{SUBD}$ | 1/cm^3 | NSUBC | [0, inf) | Substrate concentration for Vbs-dependent dVth |
| VSFTD | $V_{SFTD}$ | V | 0 | - | Vth shift for vertical doping |
| SC2D | $SC_{2D}$ | 1/V | 0 | - | Vds-dependent SCE for vertical doping |
| WDEPV | $W_{DEPV}$ | V^1/2 | 10 | - | Crossover depletion width parameter |
| NSUBDNW | $N_{SUBDNW}$ | 1/cm^3 | 0 | - | Narrow-W vertical doping |
| NSUBDW | $N_{SUBDW}$ | - | 0 | - | W-dependence coefficient |
| NSUBDWP | $N_{SUBDWP}$ | - | 1 | - | W-dependence exponent |
| NSUBDW0 | $N_{SUBDW0}$ | 1/cm^3 | NSUBD | - | W-dependence constant term |
| VBSRFAR | $V_{BSRFAR}$ | V | -TYPE*30 | - | Farthest reverse Vbs |

### Instance Parameters

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| L | $L$ | m | 5e-6 | (1n, inf) | Gate length |
| W | $W$ | m | 5e-6 | (1n, inf) | Gate width |
| NF | $N_F$ | - | 1 | [1, inf) | Number of fingers |
| NRD | $N_{RD}$ | - | 0 | [0, inf) | Number of drain squares |
| NRS | $N_{RS}$ | - | 0 | [0, inf) | Number of source squares |
| NGCON | $N_{GCON}$ | - | 1 | [1, inf) | Number of gate contacts |
| XGW | $X_{GW}$ | m | 0 | - | Gate contact to channel edge distance |
| XGL | $X_{GL}$ | m | 0 | - | Gate length patterning offset |
| SA | $SA$ | m | 0 | [0, inf) | STI-to-gate distance (source side) |
| SB | $SB$ | m | 0 | [0, inf) | STI-to-gate distance (drain side) |
| SD | $SD$ | m | 0 | [0, inf) | Gate-to-gate distance |
| DTEMP | $\Delta T$ | degC | 0 | - | Device temperature offset |
| AD | $A_D$ | m^2 | 0 | [0, inf) | Drain area |
| AS | $A_S$ | m^2 | 0 | [0, inf) | Source area |
| PD | $P_D$ | m | 0 | [0, inf) | Drain perimeter |
| PS | $P_S$ | m | 0 | [0, inf) | Source perimeter |
| SCA | $SCA$ | - | 0 | - | Layout characterization factor |
| SCB | $SCB$ | - | 0 | - | Layout characterization factor |
| SCC | $SCC$ | - | 0 | - | Layout characterization factor |
| NSUBCDFM | $N_{SUBCDFM}$ | 1/cm^3 | 5e17 | (0, inf) | Substrate concentration for DFM |
| VGSMIN | $V_{GSMIN}$ | V | -5*TYPE | - | Min/max expected Vgs |

### Binning Parameters

The binning formula for any base parameter P is:

$$ P_{eff} = P + \frac{LP}{L_{bin}} + \frac{WP}{W_{bin}} + \frac{PP}{L_{bin} \cdot W_{bin}} $$

where $L_{bin} = L_G^{LBINN}$, $W_{bin} = W_G^{WBINN}$, and $L_G$, $W_G$ are gate dimensions in micrometers.

| Parameter | Unit | Default | Description |
|-----------|------|---------|-------------|
| LMIN, LMAX | m | 0, 1 | Length range |
| WMIN, WMAX | m | 0, 1 | Width range |
| LBINN | - | 1 | L binning exponent |
| WBINN | - | 1 | W binning exponent |

Length (L-), Width (W-), and Cross-term (P-) prefixed binning parameters exist for: VMAX, BGTMP1, BGTMP2, EG0, LOVER, VFBOVER, NOVER, WL2, VFBC, NSUBC, NSUBP, SCP1, SCP2, SCP3, SC1, SC2, SC3, SC4, PGD1, NDEP, NINV, MUECB0, MUECB1, MUEPH1, VTMP, WVTH0, MUESR1, MUETMP, SUB1, SUB2, SVDS, SVBS, SVGS, NSTI, WSTI, SCSTI1, SCSTI2, VTHSTI, MUESTI1, MUESTI2, MUESTI3, NSUBPSTI1-3, NSUBCSTI1-3, CGSO, CGDO, CLM1, CLM2, CLM3, WFC, GIDL1, GIDL2, GLEAK1-3, GLEAK6, GLKSD1-2, GLKB1-2, NFTRP, NFALP, IBPC1, IBPC2, JS0, JS0SW, NJ, CISBK, VDIFFJ (and D/S variants).

### Depletion-Mode MOSFET (CODEP != 0)

| Parameter | Symbol | Unit | Default | Range | Description |
|-----------|--------|------|---------|-------|-------------|
| NDEPM | $N_{DEPM}$ | cm^-3 | 1e17 | (0, inf) | N- layer concentration |
| NDEPML | - | - | 0 | - | L dependence of NDEPM |
| NDEPMLP | - | - | 1.0 | - | L exponent of NDEPM |
| TNDEP | $t_{NDEP}$ | m | 0.2e-6 | (0, inf) | N- layer thickness |
| DEPLEAK | - | V | 0 | - | Leakage current modification |
| DEPLEAKL, DEPLEAKLP | - | - | 0, 1 | - | L dependence of DEPLEAK |
| DEPETA | - | 1/V | 0 | - | Vds dependence of Vth shift |
| DEPMUE0 | - | cm^2/Vs | 1e3 | - | Coulomb scattering in resistor region |
| DEPMUE0L, DEPMUE0LP | - | - | 0, 1 | - | L dependence of DEPMUE0 |
| DEPMUE1 | - | cm^2/Vs | 0 | - | Additional Coulomb scattering |
| DEPMUE1L, DEPMUE1LP | - | - | 0, 1 | - | L dependence of DEPMUE1 |
| DEPMUE2 | - | cm^2/Vs | 1e3 | (0, inf) | Coulomb (CODEP=2) |
| DEPMUEBACK0 | - | cm^2/Vs | 100 | - | Back-region Coulomb (CODEP=1) |
| DEPMUEBACK0L, DEPMUEBACK0LP | - | - | 0, 1 | - | L dependence |
| DEPMUEBACK1 | - | - | 0 | - | Back-region phonon (CODEP=1) |
| DEPMUEBACK1L, DEPMUEBACK1LP | - | - | 0, 1 | - | L dependence |
| DEPMUEPH0 | - | - | 0.3 | - | Phonon scattering exponent |
| DEPMUEPH1 | - | cm^2/Vs | 5e3 | (0, inf) | Phonon scattering coefficient |
| DEPVMAX | - | cm/s | 3e7 | (0, inf) | Saturation velocity |
| DEPVMAXL, DEPVMAXLP | - | - | 0, 1 | - | L dependence of DEPVMAX |
| DEPVDSEF1 | - | V | 2.0 | - | Effective drain potential coeff-1 |
| DEPVDSEF1L, DEPVDSEF1LP | - | - | 0, 1 | - | L dependence |
| DEPVDSEF2 | - | - | 0.5 | - | Effective drain potential coeff-2 |
| DEPVDSEF2L, DEPVDSEF2LP | - | - | 0, 1 | - | L dependence |
| DEPBB | - | - | 1.0 | [0.03, inf) | High-field degradation exponent |
| DEPMUETMP | - | - | 1.5 | - | Temperature exponent of phonon |
| DEPDDLT | - | - | 3.0 | [0.5, 32] | Vds smoothing coefficient |
| DEPRBR | - | - | 1 | [0, 1] | Substrate resistance factor (CODEP=3) |
| DEPSUBSL | - | - | 2.0 | [1e-8, inf) | Subthreshold slope factor |
| DEPVGPSL | - | V | 0/0.2 | [0, inf) | gm smoothing coefficient |
| DEPNINVD | - | 1/V | NINVD | - | NINVD for resistor mobility |
| DEPVFBC | - | V | VFBC | - | Flat-band voltage of resistor part |
| DEPPS | - | V | 0.01 | - | Ps_delta smoothing (CODEP=3) |
| DEPQF | - | V | 0.01 | [1e-8, 8] | Vdseff smoothing (CODEP=3) |
| DEPFDPD | - | V | 0.2 | [1e-8, 4] | FD/PD transition smoothing (CODEP=3) |
| DEPPB0 | - | V | 0.5 | [0, 0.5] | Eeff floor for resistor mobility |

## Equations

### Physical Constants

$$ q = 1.6022 \times 10^{-19}\;\text{C}, \quad k_B = 1.3806 \times 10^{-23}\;\text{J/K} $$
$$ \varepsilon_{Si} = 1.0349 \times 10^{-10}\;\text{F/m}, \quad \varepsilon_{ox} = 3.4531 \times 10^{-11}\;\text{F/m} $$
$$ n_{i,300K} = 1.04 \times 10^{16}\;\text{m}^{-3} $$

### Temperature

$$ T = T_{NOM} + \Delta T + 273.15 \quad\text{[K]} $$
$$ \beta = \frac{q}{k_B T}, \quad \beta^{-1} = \frac{k_B T}{q} $$
$$ E_g(T) = EG_0 - T \cdot (BGTMP_1 + T \cdot BGTMP_2) $$

### Effective Geometry

$$ L_{gate} = L + XL, \quad W_{gate} = W/NF + XW $$
$$ \Delta L = XLD + \frac{LL}{(L_{gate}+LLD)^{LLN}}, \quad \Delta W = XWD + \frac{WL}{(W_{gate}+WLD)^{WLN}} $$
$$ L_{eff} = L_{gate} - 2\Delta L, \quad W_{eff} = W_{gate} - 2\Delta W $$

### Oxide Capacitance

$$ C_{ox} = \frac{\varepsilon_{ox}}{T_{oxe}}, \quad C_{ox,inv} = \frac{T_{oxe}}{\varepsilon_{ox}} $$
Quantum effect modifies $T_{oxe}$:
$$ \Delta T_{ox} = QME_1 \cdot f(V_{gs}, V_{bs}, V_{thq}) + QME_3 $$
$$ T_{oxe} = t_{ox} + \Delta T_{ox} $$

### Flat-Band Voltage & Threshold Voltage

$$ V_{FB} = V_{FBC} \cdot \left(1 + \frac{VFBCL}{L_G^{VFBCLP}}\right) $$
$$ \phi_{B0} = 2\beta^{-1} \ln\left(\frac{N_{SUB}}{n_i}\right) $$
$$ cnst_0 = \sqrt{2 q \cdot N_{SUB} \cdot \varepsilon_{Si}} $$
$$ fac_1 = \frac{cnst_0}{C_{ox}}, \quad fac_1^2 = fac_1^2 $$
$$ V_{th} = \phi_{B2} + V_{FB} + \frac{\sqrt{2 q N_{SUB} \varepsilon_{Si} (\phi_{B2} - V_{bsz})}}{C_{ox}} - \Delta V_{th} $$

### Short-Channel Effect (dVth)

$$ \Delta V_{th0} = \frac{2(V_{bi} - \phi_{B20}) \cdot \varepsilon_{Si} \cdot w_{dpl}}{C_{ox} \cdot (L_{gate} - PARL_2)^2} \cdot \sqrt{\phi_{Bsum}} $$

SCE contribution:
$$ \Delta V_{thSC} = \Delta V_{th0} \cdot \left(SC_1 + \frac{SC_3}{L_{gate}} \cdot \phi_{Bsum} + SC_2 \cdot V_{dsz} \cdot (1 + SC_4 \cdot \phi_{Bsum})\right) $$

Pocket contribution (when $L_P \neq 0$):
$$ \Delta V_{thLP} = (V_{thp} - V_{th0}) \cdot \Delta V_{th0} \cdot \left(SCP_1 + \frac{SCP_3 \cdot \phi_{Bsum}}{L_P} + SCP_2 \cdot V_{dsz}\right) + \Delta Q_b - \frac{SCP_{22}}{V_{dx}^2} $$

Narrow-channel effect:
$$ \Delta V_{thW} = Q_{b0} \cdot \left(\frac{1}{C_{ox}} - \frac{1}{C_{ox} + WFC/W_{eff,cv}}\right) + \frac{WVTH_0}{W_G} $$

Total:
$$ \Delta V_{th} = \Delta V_{thSC} + \Delta V_{thLP} + \Delta V_{thW} + \Delta V_{thsm} $$

### Poly-Gate Depletion

$$ \Delta P_{pg} = cnst_{pgd} \cdot \text{SZ}\left(\text{ExpLim}(V_{gsz} - PGD_2) - 1\right) $$
Clamped: $\Delta P_{pg} \leq 1.0$ V.

### Effective Gate Voltage

$$ V_{gp} = V_{gs} - V_{FB} + \Delta V_{th} - \Delta P_{pg} $$

### Symmetry Modification

$$ V_{zadd} = \frac{V_{zadd0}}{1 + \frac{2x}{V_{zadd0}}(1/2 + \cdots)}, \quad x = \frac{\Delta V_{bsc} \cdot V_{ds}}{2} $$
$$ V_{bsz} = V_{bs} + V_{zadd}, \quad V_{dsz} = V_{ds} + 2 V_{zadd}, \quad V_{gsz} = V_{gs} + V_{zadd} $$

### Surface Potential (Ps0) -- Source Side

Solve the implicit Poisson equation by Newton iteration:
$$ F(\Psi_{s0}) = V_{gp} - \Psi_{s0} - fac_1 \cdot \sqrt{\chi + e^{-\chi} - 1 + cnst_1(e^{\beta(\Psi_{s0}-P_{SLIM})} - e^{\beta(V_{bscl}-P_{SLIM})}(\chi+1))} = 0 $$
where $\chi = \beta(\Psi_{s0} - V_{bscl})$.

Analytical initial guess (zone D1/D2):
$$ T_X = 1 + \frac{4(\beta(V_{gp} - V_{bscl}) - 1)}{fac_1^2 \cdot \beta^2} $$
$$ \Psi_{s0,ini,A} = V_{gp} + \frac{fac_1^2 \beta}{2}(1 - \sqrt{T_X}) $$

Strong inversion upper bound:
$$ \Psi_{s0,ini,B} = \frac{\ln(V_{gp}^2 / (cnst_1 \cdot cnst_{Coxi}))}{\beta + 2/V_{gp}} + P_{SLIM} $$

### Surface Potential (Psl) -- Drain Side

Same Poisson equation with quasi-Fermi level shifted by $V_{ds}$:
$$ \chi_l = \beta(\Psi_{sl} - V_{bscl} - V_{ds}) $$

Newton iteration converges Psl.

### Drift-Diffusion Current

$$ P_{ds} = \Psi_{sl} - \Psi_{s0} $$

Bulk charge at source:
$$ Q_{b0} = cnst_0 \cdot \sqrt{\Psi_{s0} - V_{bs}} $$

Inversion charge density at source:
$$ Q_{n0} = cnst_0 \cdot (\sqrt{\xi_0 + e^{-\xi_0} - 1 + cnst_1 \cdot e^{\beta \Psi_{s0}}} - \sqrt{\xi_0}) $$
where $\xi_0 = \beta(\Psi_{s0} - V_{bs}) - 1$.

Overdrive:
$$ V_{gVt} = \frac{Q_{n0}}{C_{ox}} $$

Drift-diffusion function:
$$ F_{dd} = \beta C_{ox}\left(V_{gp} + \beta^{-1} - \frac{2\Psi_{s0} + P_{ds}}{2}\right) + \beta \cdot cnst_0 \cdot (F_{00} - F_{10}) $$
where $F_{00} = \sqrt{\xi_0}$, $F_{10} = \sqrt{\xi_l}$.

$$ I_{dd} = P_{ds} \cdot F_{dd} $$

### Effective Mobility

Effective field:
$$ E_{eff} = \frac{N_{DEP} \cdot Q_{bu} + N_{INV} \cdot Q_{iu}}{\varepsilon_{Si}} \cdot \frac{1}{1 + N_{INVD} \cdot P_{dsz}} $$

Universal mobility (CGS):
$$ \frac{1}{\mu_{un}} = \frac{1}{\mu_{ECB0} + \mu_{ECB1} \cdot R_{ns}/10^{11}} + \frac{E_{eff}^{MUEPH_0}}{\mu_{eph}} + \frac{E_{eff}^{\mu_{esr}}}{\mu_{ESR1}} $$

Temperature dependence:
$$ \mu_{eph}(T) = \mu_{eph} \cdot \left(\frac{T}{T_{nom}}\right)^{-MUETMP} $$

Velocity saturation:
$$ E_m = \mu_{un} \cdot E_y, \quad E_y = \frac{I_{dd}}{\beta Q_{n0} L_{ch}} $$
$$ \mu = \frac{\mu_{un}}{\left(1 + \left(\frac{E_m}{v_{max}}\right)^{BB}\right)^{1/BB}} $$

Special cases: BB=2 (NMOS): $\mu = \mu_{un}/\sqrt{1 + (E_m/v_{max})^2}$; BB=1 (PMOS): $\mu = \mu_{un}/(1 + E_m/v_{max})$.

### Channel Length Modulation

$$ \Delta L = \frac{-T_7 + \sqrt{T_7^2 + T_8}}{2} \cdot F_{MDVDS} \cdot clm_{mod} $$
where:
$$ T_7 = \left(\frac{2 I_{dd}}{\beta Q_{n0}} + 2 \frac{q N_{sub}}{\varepsilon_{Si}} \Delta\Psi \cdot T_4 + E_0^2 \cdot T_4\right) / L_{eff} \cdot T_4 $$
$$ L_{ch} = L_{eff} - \Delta L $$

### Channel Current

$$ \beta_{WL} = \frac{W_{eff} \cdot \beta^{-1}}{L_{ch}} $$
$$ I_{ds0} = \beta_{WL} \cdot I_{dd} \cdot \mu $$

With CLM resistance (CORSRD=2):
$$ I_{ds} = \frac{I_{ds0}}{1 + R_{dd} \cdot I_{ds0} / V_{ds}} + G_{dsmin} \cdot V_{ds} $$

### Charge Partitioning

$$ \alpha = 1 - \frac{(1+\Delta) P_{ds}}{V_{gVt}} $$

Inversion charge per unit area:
$$ Q_{iu} = \frac{2}{3} V_{gVt} \cdot \frac{1 + \alpha + \alpha^2}{1 + \alpha} \cdot C_{ox} $$

Drain charge ratio:
$$ Q_{drat} = 0.6 - 0.4 \cdot \frac{0.5 + \alpha}{(1+\alpha)(1+\alpha+\alpha^2)} $$

Integrated charges:
$$ Q_b = -W_{eff,cv} \cdot L_{eff,cv} \cdot Q_{bu} $$
$$ Q_i = -W_{eff,cv} \cdot L_{eff,cv} \cdot Q_{iu} $$
$$ Q_d = Q_i \cdot Q_{drat}, \quad Q_s = Q_i - Q_d $$
$$ Q_g = -(Q_b + Q_i) $$

### Substrate Current (Impact Ionization)

$$ \Psi_{subsat} = SV_{DS} \cdot V_{dsz} + \Psi_{s0z} - \frac{L_{gate}}{x_{gate} + L_{gate}} \cdot \Psi_{slsat} $$
$$ I_{sub} = \frac{SUB_1 \cdot x_{subtmp}}{x_{subtmp}} \cdot \Psi_{subsat} \cdot I_{ds} \cdot \exp\left(-\frac{SUB_2 \cdot x_{subtmp}}{\Psi_{subsat}}\right) $$

### Gate Tunneling Current

$$ E_{tun} = \frac{V_{gsz} - V_{FB} + GLEAK_4 \cdot (\Delta V_{th} - \Delta P_{pg}) \cdot L_{eff} - \Psi_{sdlz} \cdot GLEAK_3}{T_{ox0}} \cdot \left(1 + \frac{E_y}{GLEAK_5}\right) $$
$$ I_{gate} = GLEAK_1 \cdot \frac{q \cdot W_{eff} L_{eff}}{E_g^{1/2}} \cdot \sqrt{\frac{Q_{iu} + C_{ox} \cdot V_{gVt,small}}{cnst_0}} \cdot E_{tun}^2 \cdot \exp\left(-\frac{GLEAK_2 \cdot E_g^{3/2}}{E_{tun}}\right) \cdot f_7 \cdot f_9 $$

S/D direct tunneling:
$$ I_{gs} = \frac{GLKSD_1}{10^6} W_{eff} \cdot \frac{V_{gs}^2}{T_{ox}^2} \cdot \exp\left(T_{ox}(-GLKSD_2 \cdot V_{gs} + GLKSD_3)\right) $$
$$ I_{gd} = \frac{GLKSD_1}{10^6} W_{eff} \cdot \frac{(V_{gs}-V_{ds})^2}{T_{ox}^2} \cdot \exp\left(T_{ox}(-GLKSD_2 (V_{gs}-V_{ds}) + GLKSD_3)\right) $$

Gate-bulk:
$$ I_{gb} = GLKB_1 \cdot W_{eff} L_{eff} \cdot E_{tun,b}^2 \cdot \exp\left(-\frac{GLKB_2}{E_{tun,b}}\right) $$

### GIDL/GISL

$$ E_{GIDL} = \frac{GIDL_3 (V_{ds} + GIDL_4) - V_{gs} + (\Delta V_{thSC} + \Delta V_{thLP}) \cdot GIDL_5 - GIDL_6 \cdot Q_{b0}/C_{ox}}{T_{ox}} $$
$$ I_{GIDL} = \frac{GIDL_1 \cdot q \cdot W_{eff}}{E_g^{1/2}} \cdot E_{GIDL}^2 \cdot \exp\left(-\frac{GIDL_2 \cdot E_g^{3/2}}{E_{GIDL}^{GIDL_7}}\right) \cdot \frac{V_{db}^3}{V_{db}^3 + 0.5} $$

### Overlap Charge

When NOVER = 0 (simple model):
$$ Q_{gos} = V_{gs} \cdot C_{ox,ov} W_{eff,cv} L_{ov} - OV_{SLP} \cdot C_{ox,ov} W_{eff,cv} \cdot (OV_{MAG} + V_{gs}) \cdot (1.2 - \Psi_{s0}) $$

When NOVER > 0 (surface-potential-based), the overlap surface potential $\Psi_{s0,LD}$ is solved iteratively using the same Poisson equation as the intrinsic region but with overlap doping NOVER and overlap oxide TOXOV.

### Lateral-Field Capacitance (Qy)

$$ Q_y = -(\Psi_{s0} + V_{ds} - \Psi_{sdl,k}) \cdot \frac{\varepsilon_{Si} \cdot W_{eff,cv} \cdot 1.3 \cdot w_{dpl}}{XQY} \cdot F_{MDVDS} $$
Partitioned: $Q_{yd} = Q_y \cdot QYRAT$, $Q_{ys} = Q_y \cdot (1 - QYRAT)$.

### Junction Diode Current

$$ I_{dio} = I_s \left(\exp\left(\frac{V_{dio}}{n_j V_t}\right) - 1\right) + C_{ISB} \cdot I_{s2} \cdot \left(\exp(-CVB \cdot V_{dio} / (n_j V_t)) - 1\right) + C_{ISBK} \left(\exp(-CVBK \cdot V_{dio} / (n_j V_t)) - 1\right) + DIV_X \cdot I_{s2} \cdot V_{dio} $$

With linearization above $V_{diffj}$.

### Junction Capacitance

$$ Q_{junc} = \begin{cases} \frac{\phi_B \cdot C_z}{1 - M_J}\left(1 - \left(1 - \frac{V}{P_B}\right)^{1-M_J}\right) & V < 0 \\ V \cdot C_z + \frac{V^2}{2} \cdot C_z \cdot \frac{M_J}{P_B} & V \geq 0 \end{cases} $$

Temperature dependence: $C_z(T) = C_z \cdot (1 + TC_{JBx} \cdot \Delta T)$.

### NQS Model

Inversion charge time constant:
$$ \tau = \frac{DLY_2 \cdot DLY_1 \cdot L_{ch}^2}{\mu \cdot V_{gVt} \cdot DLY_1 + DLY_2 \cdot L_{ch}^2} $$

Bulk charge time constant:
$$ \tau_b = DLY_3 \cdot C_{ox} $$

NQS charge relaxation:
$$ \frac{dQ_{i,nqs}}{dt} = \frac{Q_{i,nqs} - Q_i}{\tau}, \quad \frac{dQ_{b,nqs}}{dt} = \frac{Q_{b,nqs} - Q_b}{\tau_b} $$

### STI Leakage

$$ I_{dsSTI} = \frac{2 \cdot W_{STI} \cdot NF \cdot \beta^{-1}}{L_{ch}} \cdot \mu \cdot Q_{n0,STI} \cdot \frac{V_{ds}}{V_{dsat,STI}} $$
where $Q_{n0,STI}$ is computed from a separate surface potential $\Psi_{STI}$ using the STI doping $N_{STI}$.

### Punchthrough Current (deep)

$$ E_c = \sqrt{\frac{2q(V_{bipn} - V_{bs})}{\varepsilon_{Si}} \cdot \frac{N_{SUB} \cdot N_{JUNC}}{N_{SUB} + N_{JUNC}}} $$
$$ \Delta\phi_{vds} = -\frac{(E_c \cdot L_{eff})^2}{4(V_{ds} + E_c \cdot L_{eff})} $$
$$ I_{dsPT1} = \frac{2\beta^{-1}}{L_{eff}} \cdot Q_{n0,npt} \cdot \mu_{PT} \cdot W_{eff} \cdot \left(e^{\beta \phi_m} - e^{\beta(\phi_m - V_{ds})}\right) $$

### 1/f Noise

$$ S_{Id,1/f} = \frac{I_{ds}^{SIDP} \cdot N_{FTRP}}{(L_{ch} - \Delta L_{noise}) \cdot \beta \cdot W_{eff,cv}} \cdot \left(\frac{1}{(N_s + N_t)(N_d + N_t)} + \frac{2 N_{FALP1} E_y \mu}{N_d - N_s} \ln\frac{N_d + N_t}{N_s + N_t} + (N_{FALP2} E_y \mu)^2\right) $$

### Thermal Noise

$$ S_{Id,th} = 4 k_B T \cdot W_{eff,cv} C_{ox} V_{gVt} \mu \cdot \frac{(1+3\alpha+6\alpha^2)\mu_d^2 + (3+4\alpha+3\alpha^2)\mu_d \mu + (6+3\alpha+\alpha^2)\mu^2}{15 L_{ch} (1+\alpha) \mu_{Ave}^2} $$

### Induced Gate Noise

$$ S_{Ig} = \frac{16}{135} \cdot q \beta^{-1} \cdot \frac{C_{gs}^2}{g_{ds0,ign}} \cdot \kappa_{ig} \cdot w_{corr} $$
Cross-correlation:
$$ c = \frac{\sqrt{15} \cdot \kappa_{00L} \cdot T_7}{6 \cdot T_2 \cdot \sqrt{\gamma \cdot T_2 \cdot V_{gVt} \cdot T_5}} $$

### Smoothing Functions

SmoothZero (floor to zero):
$$ \text{SZ}(x, \delta) = \frac{1}{2}\left(x + \sqrt{x^2 + 4\delta^2}\right) $$

SmoothUpper (ceiling):
$$ \text{SU}(x, x_{max}, \delta) = x_{max} - \frac{1}{2}\left((x_{max} - x - \delta) + \sqrt{(x_{max} - x - \delta)^2 + 4|x_{max}|\delta}\right) $$

SmoothLower (floor):
$$ \text{SL}(x, x_{min}, \delta) = x_{min} + \frac{1}{2}\left((x - x_{min} - \delta) + \sqrt{(x - x_{min} - \delta)^2 + 4|x_{min}|\delta}\right) $$

CeilingPow:
$$ \text{CP}(x, x_{max}, pw) = \frac{x \cdot x_{max}}{(x^{2pw} + x_{max}^{2pw})^{1/(2pw)}} $$

SymAdd (symmetry at Vds=0):
$$ \text{SymAdd}(x, a_0) = \frac{a_0}{1 + T_1(1/2 + T_1(1/6 + \cdots))}, \quad T_1 = \frac{2x}{a_0} $$

Limited exponential:
$$ \text{lexp}(x) = \begin{cases} e^{80}(1 + x - 80) & x > 80 \\ e^{-80} & x < -80 \\ e^x & \text{otherwise} \end{cases} $$

### KCL Stamp (Normal Mode, NMOS)

$$ I(dp \to sp) = TYPE \cdot I_{ds} $$
$$ I(dp \to bp) = TYPE \cdot (I_{GIDL} + I_{sub}) $$
$$ I(sp \to bp) = TYPE \cdot (I_{GISL} + I_{subs}) $$
$$ I(sb \to sp) = TYPE \cdot I_{bs}, \quad I(db \to dp) = TYPE \cdot I_{bd} $$
$$ I(gp \to sp) = TYPE \cdot I_{gs}, \quad I(gp \to dp) = TYPE \cdot I_{gd}, \quad I(gp \to bp) = TYPE \cdot I_{gb} $$

Charge contributions (displacement current via ddt):
$$ I(gp \to sp) \mathrel{+}= TYPE \cdot \frac{dQ_g}{dt} $$
$$ I(dp \to sp) \mathrel{+}= TYPE \cdot \frac{dQ_d}{dt} $$
$$ I(bp \to sp) \mathrel{+}= TYPE \cdot \frac{dQ_b}{dt} $$

Source: Verilog-A from [VA-Models/hisim2](https://github.com/dwarning/VA-Models/tree/main/code/hisim2/vacode) (v3.20, 2021.10.08, ECL-2.0).
Cross-referenced with Zig implementation at `modules/devices/src/hisim2.zig`.
