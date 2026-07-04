# Mextram 505.5.0 -- Parameter & Equation Reference

> BJT (SiGe HBT) -- Most EXquisite TRAnsistor Model
> Date: October 29, 2024
> Authors: G. Niu (Auburn), R. van der Toorn (TU Delft), J.C.J. Paasschens, W.J. Kloosterman (NXP)

## Model Topology

Mextram is a vertical NPN/PNP bipolar transistor model with external terminals C (collector), B (base), E (emitter), and S (substrate). Internal nodes are: B1 (internal base after constant resistance), B2 (intrinsic base), E1 (intrinsic emitter), C1 (epilayer/base boundary), C2 (intrinsic collector), C3 (extrinsic buried layer), C4 (intrinsic buried layer), and dT (thermal node for self-heating). The intrinsic NPN (IN, IB1, IB2, Iavl, QBE, QBC, QtE, QtC, QE) sits between B2-C2-E1. A parasitic PNP (Iex, IB3, Isub) models extrinsic base-collector-substrate action. The epilayer model (IC1C2) handles quasi-saturation and Kirk effect between C1 and C2. Buried layer resistances RCblx (C3-C4) and RCbli (C4-C1) are optional (default zero, removing nodes C3/C4).

**Total parameters: 159** (including instance parameters DTA, MULT)

---

## Parameters

### Instance and General Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 1 | `dta` | $\text{DTA}$ | C | 0.0 | -- | -- | Difference between local ambient and global ambient temperatures |
| 2 | `mult` | $\text{MULT}$ | -- | 1.0 | 0.0 | -- | Multiplication factor for parallel transistors |
| 3 | `version` | $\text{VERSION}$ | -- | 505.50 | 505.50 | 505.51 | Model version |
| 4 | `type` | $\text{TYPE}$ | -- | 1.0 | -1 | 1 | Flag for NPN (1) or PNP (-1) |
| 5 | `tref` | $T_\text{ref}$ | C | 25.0 | -273 | -- | Reference temperature |
| 6 | `exmod` | $\text{EXMOD}$ | -- | 1 | 0 | 3 | Flag for extended modeling of reverse current gain |
| 7 | `exphi` | $\text{EXPHI}$ | -- | 1 | 0 | 1 | *Flag for distributed HF effects in transient |
| 8 | `exavl` | $\text{EXAVL}$ | -- | 0 | 0 | 1 | Flag for extended modeling of avalanche currents |
| 9 | `exsub` | $\text{EXSUB}$ | -- | 1 | 0 | 1 | Flag for extended modeling of substrate currents |

### Main Current Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 10 | `is` | $I_s$ | A | 22.0e-18 | 0.0 | -- | CE saturation current |
| 11 | `nff` | $\text{NFF}$ | -- | 1.0 | 0.1 | -- | Non-ideality factor of forward main current |
| 12 | `nfr` | $\text{NFR}$ | -- | 1.0 | 0.1 | -- | Non-ideality factor of reverse main current |
| 13 | `ik` | $I_k$ | A | 0.1 | 1.0e-12 | -- | CE high injection knee current |
| 14 | `ver` | $V_{er}$ | V | 2.5 | 0.01 | -- | Reverse Early voltage |
| 15 | `vef` | $V_{ef}$ | V | 44.0 | 0.01 | -- | Forward Early voltage |
| 16 | `issr` | $I_{ssr}$ | -- | 1.0 | 0.0 | -- | Fraction of saturation current for reverse main current |

### Forward Base Current Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 17 | `ibi` | $I_{BI}$ | A | 0.1e-18 | 0.0 | -- | Saturation current of ideal base current IB1 |
| 18 | `nbi` | $N_{BI}$ | -- | 1.0 | 0.1 | -- | Non-ideality factor of ideal base current IB1 |
| 19 | `ibis` | $I_{SBI}$ | A | 0.0 | 0.0 | -- | Saturation current of ideal side wall base current IBS1 |
| 20 | `nbis` | $N_{SBI}$ | -- | 1.0 | 0.1 | -- | Non-ideality factor of ideal side wall base current IBS1 |
| 21 | `ibf` | $I_{Bf}$ | A | 2.7e-15 | 0.0 | -- | Saturation current of non-ideal forward base current IB2 |
| 22 | `mlf` | $m_{Lf}$ | -- | 2.0 | 0.1 | -- | Non-ideality factor of non-ideal forward base current IB2 |
| 23 | `ibfs` | $I_{SBf}$ | A | 0.0 | 0.0 | -- | Saturation current of non-ideal side wall forward base current IBS2 |
| 24 | `mlfs` | $m_{SLf}$ | -- | 2.0 | 0.1 | -- | Non-ideality factor of non-ideal side wall forward base current IBS2 |

### NBR (Neutral Base Recombination) Base Current Parameters (SWIB1)

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 25 | `swib1` | $\text{SWIB1}$ | -- | 0 | 0 | 1 | Switch of IB1 and IBS1 model |
| 26 | `ibinbr` | $I_{BInbr}$ | A | 0.0 | 0.0 | -- | Saturation current of NBR ideal base current (swib1=1) |
| 27 | `ibinbrs` | $I_{SBInbr}$ | A | 0.0 | 0.0 | -- | Saturation current of ideal side wall base current (swib1=1) |
| 28 | `vknbr` | $V_{Knbr}$ | V | 0.68 | 0.05 | -- | High injection knee voltage for NBR IB1 and IBS1 (swib1=1) |
| 29 | `ibinbrqs` | $I_{BInbrqs}$ | A | 0.0 | 0.0 | -- | Saturation current of quasi-saturation component of NBR IB1 (swib1=1) |

### BTBT and TAT Base Current Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 30 | `istat` | $I_{stat}$ | A | 0.0 | 0.0 | -- | Saturation current of TAT current |
| 31 | `vtat` | $V_{tat}$ | V | 1.0 | 0.0 | -- | Coefficient of TAT current |
| 32 | `vbtbt` | $V_{btbt}$ | V | 0.16 | 0.0 | -- | Coefficient of base tunneling current |
| 33 | `kbtbt` | $K_{btbt}$ | -- | 0.0 | -- | -- | Coefficient of base tunneling current |

### Reverse Base Current Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 34 | `ibx` | $I_{BX}$ | A | 3.14e-18 | 0.0 | -- | Saturation current of extrinsic reverse base current Iex |
| 35 | `ikbx` | $I_{kBX}$ | A | 14.29e-3 | 1.0e-12 | -- | Extrinsic CE high injection knee current |
| 36 | `ibr` | $I_{Br}$ | A | 1.0e-15 | 0.0 | -- | Saturation current of non-ideal reverse base current IB3 |
| 37 | `mlr` | $m_{Lr}$ | -- | 2.0 | 0.1 | -- | Non-ideality factor of non-ideal reverse base current IB3 |
| 38 | `xext` | $X_{ext}$ | -- | 0.63 | 0.0 | 1.0 | Part of Iex, Qtex, Qex and Isub that depends on VBC3 |

### Zener Tunneling Current Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 39 | `izeb` | $I_{zEB}$ | A | 0.0 | 0.0 | -- | Pre-factor of emitter-base Zener tunneling current |
| 40 | `nzeb` | $N_{zEB}$ | -- | 22.0 | 0.0 | -- | Coefficient of emitter-base Zener tunneling current |
| 41 | `izcb` | $I_{zCB}$ | A | 0.0 | 0.0 | -- | Pre-factor of CB Zener tunneling current |
| 42 | `nzcb` | $N_{zCB}$ | -- | 22.0 | 0.0 | -- | Coefficient of CB Zener tunneling current |
| 43 | `vzmin` | $V_{zmin}$ | V | 1.0e-6 | 0.0 | -- | Minimum junction reverse voltage for Zener numerical stability |

### Avalanche Current Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 44 | `swavl` | $\text{SWAVL}$ | -- | 1 | 0 | 3 | Switch of avalanche factor GEM model |
| 45 | `aavl` | $A_{avl}$ | -- | 400.0 | 0.0 | -- | Ionization rate coefficient A of GEM (SWAVL=1) |
| 46 | `cavl` | $C_{avl}$ | -- | -0.37 | -- | 0.0 | Exponent in GEM model (SWAVL=1) |
| 47 | `itoavl` | $I_{TOavl}$ | A | 500e-3 | 0.0 | -- | Current dependence parameter of GEM (SWAVL=1) |
| 48 | `bavl` | $B_{avl}$ | -- | 25.0 | 0.0 | -- | Ionization rate coefficient B of GEM (SWAVL=1) |
| 49 | `vdcavl` | $V_{dCavl}$ | V | 0.1 | -- | -- | CB diffusion voltage dedicated for GEM (SWAVL=1) |
| 50 | `wavl` | $W_{avl}$ | m | 1.1e-6 | 1.0e-9 | -- | Epilayer thickness used in weak-avalanche model (SWAVL=2) |
| 51 | `vavl` | $V_{avl}$ | V | 3.0 | 0.01 | -- | Voltage determining curvature of avalanche current (SWAVL=2) |
| 52 | `sfh` | $S_{fH}$ | -- | 0.3 | 0.0 | -- | Current spreading factor of avalanche model (EXAVL=1) |
| 53 | `ihcavl` | $I_{hcavl}$ | A | 4.0e-3 | 1.0e-12 | -- | Critical current for velocity saturation (SWAVL=3) |
| 54 | `davl` | $D_{avl}$ | -- | -0.37 | -- | 0.0 | Coefficient for controlling decrease of GEM with current (SWAVL=3) |
| 55 | `eavl` | $E_{avl}$ | -- | -0.37 | -- | 0.0 | Coefficient for controlling increase of GEM with current (SWAVL=3 extended) |
| 56 | `aexavl` | $A_{exavl}$ | A | 0.3 | 0.0 | -- | Smoothness parameter for onset of SWAVL=3 extended GEM model |
| 57 | `ionexavl` | $I_{onexavl}$ | A | 4.0e-3 | 1.0e-12 | -- | Onset current of SWAVL=3 extended GEM model |
| 58 | `swgemlim` | $\text{SWGEMLIM}$ | -- | 1 | 0 | 1 | Switch of limiting of avalanche factor GEM model |

### Resistance Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 59 | `re` | $R_E$ | Ohm | 5.0 | 1.0e-3 | -- | Emitter resistance |
| 60 | `rbc` | $R_{Bc}$ | Ohm | 23.0 | 1.0e-3 | -- | Constant part of base resistance |
| 61 | `rbv` | $R_{Bv}$ | Ohm | 18.0 | 1.0e-3 | -- | Zero-bias value of variable part of base resistance |
| 62 | `rcc` | $R_{Cc}$ | Ohm | 12.0 | 1.0e-3 | -- | Constant part of collector resistance |
| 63 | `rcblx` | $R_{Cblx}$ | Ohm | 0.0 | 0.0 | -- | Resistance of Collector Buried Layer: extrinsic part |
| 64 | `rcbli` | $R_{Cbli}$ | Ohm | 0.0 | 0.0 | -- | Resistance of Collector Buried Layer: intrinsic part |

### Epilayer Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 65 | `rcv` | $R_{Cv}$ | Ohm | 150.0 | 1.0e-3 | -- | Resistance of un-modulated epilayer |
| 66 | `scrcv` | $SCR_{Cv}$ | Ohm | 1250.0 | 1.0e-3 | -- | Space charge resistance of epilayer |
| 67 | `ihc` | $I_{hc}$ | A | 4.0e-3 | 1.0e-12 | -- | Critical current for velocity saturation in epilayer |
| 68 | `axi` | $a_{xi}$ | -- | 0.3 | 0.02 | -- | Smoothness parameter for onset of quasi-saturation |
| 69 | `vdc` | $V_{dC}$ | V | 0.68 | 0.05 | -- | CB diffusion voltage |

### Depletion Capacitance Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 70 | `cje` | $C_{jE}$ | F | 73.0e-15 | 0.0 | -- | *Zero-bias EB depletion capacitance |
| 71 | `vde` | $V_{dE}$ | V | 0.95 | 0.05 | -- | EB diffusion voltage |
| 72 | `pe` | $p_E$ | -- | 0.4 | 0.01 | 0.99 | EB grading coefficient |
| 73 | `xcje` | $X_{CjE}$ | -- | 0.4 | 0.0 | 1.0 | *Sidewall fraction of EB depletion capacitance |
| 74 | `cbeo` | $C_{BEO}$ | F | 0.0 | 0.0 | -- | *EB overlap capacitance |
| 75 | `cjc` | $C_{jC}$ | F | 78.0e-15 | 0.0 | -- | *Zero-bias CB depletion capacitance |
| 76 | `vdcctc` | $V_{dCctc}$ | V | 0.68 | 0.05 | -- | CB diffusion voltage of depletion capacitance |
| 77 | `pc` | $p_C$ | -- | 0.5 | 0.01 | 0.99 | CB grading coefficient |
| 78 | `swvchc` | $\text{SWVCHC}$ | -- | 0 | 0 | 1 | Switch of Vch for CB depletion capacitance |
| 79 | `swvjunc` | $\text{SWVJUNC}$ | -- | 0 | 0 | 2 | Switch of Vjunc for CB depletion capacitance |
| 80 | `xp` | $X_p$ | -- | 0.35 | 0.0 | 0.99 | Constant part of CjC (ratio depletion/epilayer thickness) |
| 81 | `mc` | $m_C$ | -- | 0.5 | 0.0 | 1.0 | Coefficient for current modulation of CB depletion capacitance |
| 82 | `xcjc` | $X_{CjC}$ | -- | 32.0e-3 | 0.0 | 1.0 | *Fraction of CB depletion capacitance under emitter |
| 83 | `cbco` | $C_{BCO}$ | F | 0.0 | 0.0 | -- | *CB overlap capacitance |

### Extrinsic Diffusion Charge and CB Breakdown Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 84 | `swqex` | $\text{SWQEX}$ | -- | 0 | 0 | 1 | *Switch for extrinsic diffusion charge model |
| 85 | `vdcex` | $V_{dCex}$ | V | 0.68 | 0.05 | -- | *CB diffusion voltage of diffusion capacitance |
| 86 | `vbrcb` | $V_{brcb}$ | V | 100.0 | 0.0 | 2000.0 | Breakdown voltage for CB junction leakage |
| 87 | `pbrcb` | $p_{brcb}$ | V | 4.0 | 0.0 | 500.0 | Breakdown onset tuning parameter for CB junction leakage |
| 88 | `frevcb` | $f_{revcb}$ | -- | 1000.0 | 10 | 1.0e10 | Coefficient for limiting CB junction breakdown leakage current |
| 89 | `swjbrcb` | $\text{SWJBRCB}$ | -- | 0 | 0 | 1 | Switch for breakdown in CB junction leakage |

### Transit Time Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 90 | `mtau` | $m_\tau$ | -- | 1.0 | 0.1 | -- | *Non-ideality factor of emitter stored charge |
| 91 | `taue` | $\tau_E$ | s | 2.0e-12 | 0.0 | -- | *Minimum transit time of stored emitter charge |
| 92 | `taub` | $\tau_B$ | s | 4.2e-12 | 0.0 | -- | *Transit time of stored base charge |
| 93 | `tepi` | $\tau_{epi}$ | s | 41.0e-12 | 0.0 | -- | *Transit time of stored epilayer charge |
| 94 | `taur` | $\tau_R$ | s | 520.0e-12 | 0.0 | -- | *Transit time of reverse extrinsic stored base charge |
| 95 | `tauex` | $\tau_{ex}$ | s | 10.0e-12 | 0.0 | -- | *Transit time of reverse extrinsic stored epilayer charge (swqex=1) |
| 96 | `nex` | $N_{ex}$ | -- | 1.0 | 0.1 | -- | *Non-ideality factor of reverse extrinsic stored epilayer charge (swqex=1) |

### Heterojunction (SiGe) Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 97 | `deg` | $dE_g$ | eV | 0.0 | -- | -- | Bandgap difference over the base |
| 98 | `xrec` | $X_{rec}$ | -- | 0.0 | 0.0 | -- | Pre-factor of recombination part of IB1 |
| 99 | `xqb` | $X_{QB}$ | -- | 1/3 | 0.0 | 1.0 | Emitter-fraction of base diffusion charge |
| 100 | `ke` | $K_E$ | -- | 0.0 | 0.0 | 1.0 | *Fraction of QE in excess phase shift |

### Temperature Scaling Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 101 | `dtmax` | $DT_{max}$ | K | 200.0 | 0.0 | -- | Maximum temperature rise by self-heating |
| 102 | `aqbo` | $A_{QB0}$ | -- | 0.3 | -- | -- | Temperature coefficient of zero-bias base charge |
| 103 | `ae` | $A_E$ | -- | 0.0 | -- | -- | Temperature coefficient of resistivity of emitter |
| 104 | `ab` | $A_B$ | -- | 1.0 | -- | -- | Temperature coefficient of resistivity of base |
| 105 | `aepi` | $A_{epi}$ | -- | 2.5 | -- | -- | Temperature coefficient of resistivity of epilayer |
| 106 | `aepiex` | $A_{epiex}$ | -- | 2.5 | -- | -- | Temperature coefficient of reverse transit time of extrinsic epilayer |
| 107 | `aex` | $A_{ex}$ | -- | 0.62 | -- | -- | Temperature coefficient of resistivity of extrinsic base |
| 108 | `ac` | $A_C$ | -- | 2.0 | -- | -- | Temperature coefficient of resistivity of collector contact |
| 109 | `acx` | $A_{CX}$ | -- | 1.3 | -- | -- | Temperature coefficient of extrinsic reverse base current |
| 110 | `acbl` | $A_{Cbl}$ | -- | 2.0 | 0.0 | -- | Temperature coefficient of resistivity of collector buried layer |
| 111 | `ktat` | $K_{tat}$ | -- | 0.0 | -- | -- | Temperature coefficient of TAT current |

### Bandgap Voltage Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 112 | `vgb` | $V_{gB}$ | V | 1.17 | 0.1 | -- | Band-gap voltage of base |
| 113 | `vgbnbrqs` | $V_{gBnbrqs}$ | V | 1.12 | 0.1 | -- | Band-gap voltage of QS component of NBR IB1 (swib1=1) |
| 114 | `vgbnbr` | $V_{gBnbr}$ | V | 1.12 | 0.1 | -- | Band-gap voltage of NBR IB1 (swib1=1) |
| 115 | `vgbnbrs` | $V_{gSBnbr}$ | V | 1.12 | 0.1 | -- | Band-gap voltage of NBR IBS1 (swib1=1) |
| 116 | `vgknbr` | $V_{gKnbr}$ | V | 1.12 | 0.1 | -- | Band-gap voltage of high injection knee for NBR (swib1=1) |
| 117 | `vgc` | $V_{gC}$ | V | 1.18 | 0.1 | -- | Band-gap voltage of collector |
| 118 | `vge` | $V_{gE}$ | V | 1.12 | 0.1 | -- | Band-gap voltage of emitter |
| 119 | `vgcx` | $V_{gCX}$ | V | 1.125 | 0.1 | -- | Band-gap voltage of extrinsic collector |
| 120 | `vgj` | $V_{gj}$ | V | 1.15 | 0.1 | -- | Band-gap voltage recombination EB junction |

### Zener Tunneling Bandgap Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 121 | `vgzeb` | $V_{gZEB}$ | V | 1.15 | 0.1 | -- | Band-gap voltage at Tref for EB tunneling |
| 122 | `avgeb` | $A_{VgEB}$ | V/K | 4.73e-4 | -- | -- | Temperature coefficient of band-gap voltage for EB tunneling |
| 123 | `tvgeb` | $T_{VgEB}$ | K | 636.0 | 0.0 | -- | Temperature coefficient of band-gap voltage for EB tunneling |
| 124 | `vgzcb` | $V_{gZCB}$ | V | 1.15 | 0.1 | -- | Band-gap voltage at Tref for CB tunneling |
| 125 | `avgcb` | $A_{VgCB}$ | V/K | 4.73e-4 | -- | -- | Temperature coefficient of band-gap voltage for CB tunneling |
| 126 | `tvgcb` | $T_{VgCB}$ | K | 636.0 | 0.0 | -- | Temperature coefficient of band-gap voltage for CB tunneling |

### Additional Temperature and Tuning Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 127 | `dvgte` | $dV_{g\tau E}$ | V | 0.05 | -- | -- | *Band-gap voltage difference of emitter stored charge |
| 128 | `dais` | $dA_{Is}$ | -- | 0.0 | -- | -- | Fine tuning of temperature dependence of CE saturation current |
| 129 | `tnff` | $t_{NFF}$ | /K | 0.0 | -- | -- | Temperature coefficient of NFF |
| 130 | `tnfr` | $t_{NFR}$ | /K | 0.0 | -- | -- | Temperature coefficient of NFR |
| 131 | `tbavl` | $T_{Bavl}$ | -- | 500e-6 | -- | -- | Temperature scaling parameter of Bavl (SWAVL=1) |

### Noise Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 132 | `af` | $A_f$ | -- | 2.0 | 0.01 | -- | *Exponent of flicker-noise of ideal base current |
| 133 | `afn` | $A_{fN}$ | -- | 2.0 | 0.01 | -- | *Exponent of flicker-noise of non-ideal base current |
| 134 | `kf` | $K_f$ | -- | 20.0e-12 | 0.0 | -- | *Flicker-noise coefficient of ideal base current |
| 135 | `kfn` | $K_{fN}$ | -- | 20.0e-12 | 0.0 | -- | *Flicker-noise coefficient of non-ideal base current |
| 136 | `kavl` | $K_{avl}$ | -- | 0 | 0 | 1 | *Switch for white noise contribution due to avalanche |
| 137 | `kc` | $K_C$ | -- | 0 | 0 | 2 | *Switch for RF correlation noise model selection |
| 138 | `ftaun` | $F_{taun}$ | -- | 0.0 | 0.0 | 1.0 | *Fraction of noise transit time to total transit time |

### Substrate (4-Terminal) Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 139 | `iss` | $I_{Ss}$ | A | 48.0e-18 | 0.0 | -- | Saturation current of parasitic BCS transistor main current |
| 140 | `icss` | $I_{CSs}$ | A | 0.0 | 0.0 | -- | CS junction ideal saturation current |
| 141 | `iks` | $I_{ks}$ | A | 545.5e-6 | 1.0e-12 | -- | Knee current for BCS transistor main current |
| 142 | `ikcs` | $I_{kcs}$ | A | 50.0e-6 | 1.0e-12 | -- | Knee current for CS junction diode current |
| 143 | `cjs` | $C_{jS}$ | F | 315.0e-15 | 0.0 | -- | *Zero-bias CS depletion capacitance |
| 144 | `vds` | $V_{dS}$ | V | 0.62 | 0.05 | -- | *CS diffusion voltage |
| 145 | `ps` | $p_S$ | -- | 0.34 | 0.01 | 0.99 | *CS grading coefficient |
| 146 | `vgs` | $V_{gS}$ | V | 1.20 | 0.1 | -- | Band-gap voltage of the substrate |
| 147 | `as` | $A_S$ | -- | 1.58 | -- | -- | Temperature coeff. (AC for closed BL, Aepi for open BL) |
| 148 | `asub` | $A_{sub}$ | -- | 2.0 | -- | -- | Temperature coefficient for mobility of minorities in substrate |
| 149 | `xisubi` | $X_{isubi}$ | -- | 0.0 | 0.0 | 1.0 | Part of substrate current that belongs to intrinsic region |
| 150 | `swvsch` | $\text{SWVSCH}$ | -- | 0 | 0 | 1 | Switch for VSC induced high injection in BCS transistors |

### Self-Heating Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 151 | `swnlsh` | $\text{SWNLSH}$ | -- | 0 | 0 | 1 | Switch for nonlinear self-heating |
| 152 | `rth` | $R_{th}$ | K/W | 300.0 | 0.0 | -- | Thermal resistance |
| 153 | `cth` | $C_{th}$ | J/K | 3.0e-9 | 0.0 | -- | *Thermal capacitance |
| 154 | `ath` | $A_{th}$ | -- | 0.0 | -- | -- | Temperature coefficient of thermal resistance |

### Reliability and Convergence Parameters

| # | Parameter | Symbol | Unit | Default | Clip Low | Clip High | Description |
|---|-----------|--------|------|---------|----------|-----------|-------------|
| 155 | `isibrel` | $I_{SIBrel}$ | A | 0.0 | 0.0 | -- | Saturation current of base current for reliability simulation |
| 156 | `nfibrel` | $N_{FIBrel}$ | -- | 2.0 | 0.1 | -- | Non-ideality factor of base current for reliability simulation |
| 157 | `vexlim` | $V_{exlim}$ | -- | -- | -- | -- | Upper limit of exp() function argument for convergence |
| 158 | `p0starlim` | $P^*_{0lim}$ | -- | 1.0e-40 | 0.0 | 1.0e-10 | Lower limit for p*0 clipping |
| 159 | `pwlim` | $PW_{lim}$ | -- | 1.0e-40 | 0.0 | 1.0e-10 | Lower limit for pW clipping |

Parameters marked with * are not used in DC model.

---

## Equations

### Model Constants

$$k = 1.3806226 \times 10^{-23} \; \text{J/K} \tag{4.2}$$

$$q = 1.6021918 \times 10^{-19} \; \text{C} \tag{4.3}$$

$$\frac{k}{q} = 0.86171 \times 10^{-4} \; \text{V/K} \tag{4.4}$$

$$V_{d,low} = 0.05 \; \text{V} \tag{4.5}$$

$$\alpha_{jE} = 3.0 \tag{4.6}$$

$$\alpha_{jC} = 2.0 \tag{4.7}$$

$$\alpha_{jS} = 2.0 \tag{4.8}$$

Impact ionization constants (SWAVL=2), NPN:

$$A_n = 7.03 \times 10^7 \; \text{m}^{-1} \tag{4.9}$$

$$B_n = 1.23 \times 10^8 \; \text{V m}^{-1} \tag{4.10}$$

Impact ionization constants (SWAVL=2), PNP:

$$A_n = 1.58 \times 10^8 \; \text{m}^{-1} \tag{4.11}$$

$$B_n = 2.04 \times 10^8 \; \text{V m}^{-1} \tag{4.12}$$

### MULT-Scaling

Parameters multiplied by MULT:

$$I_s, I_k, I_{kBX}, I_{Bf}, I_{Br}, I_{BX}, I_{BI}, I_{SBI}, I_{SBf}, I_{hc}, I_{Ss}, I_{CSs}, I_{ks}, I_{kcs}, I_{zEB}, I_{zCB}, I_{SIBrel}, I_{TOavl} \tag{4.13a}$$

$$C_{jE}, C_{jC}, C_{jS}, C_{BEO}, C_{BCO}, C_{th} \tag{4.13b}$$

Parameters divided by MULT:

$$R_E, R_{Bc}, R_{Bv}, R_{Cc}, R_{Cblx}, R_{Cbli}, R_{Cv}, SCR_{Cv}, R_{th} \tag{4.14}$$

Flicker-noise scaling:

$$K_f \to K_f \cdot \text{MULT}^{1-A_f} \tag{4.15}$$

$$K_{fN} \to K_{fN} \cdot \text{MULT}^{1-A_{fN}} \tag{4.16}$$

### Temperature Scaling

#### Conversion to Kelvin

$$T_K = \text{TEMP} + \text{DTA} + 273.15 + V_{dT} \tag{4.17a}$$

$$T_{amb} = \text{TEMP} + \text{DTA} + 273.15 \tag{4.17b}$$

$$T_{RK} = T_{ref} + 273.15 \tag{4.18}$$

$$t_N = \frac{T_K}{T_{RK}} \tag{4.19}$$

#### Thermal Voltage

$$V_T = \frac{k}{q} T_K \tag{4.20}$$

$$V_{TR} = \frac{k}{q} T_{RK} \tag{4.21}$$

$$\frac{1}{V_{\Delta T}} = \frac{1}{V_T} - \frac{1}{V_{TR}} \tag{4.22}$$

#### Diffusion Voltages

$$U_{dET} = -3 V_T \ln t_N + V_{dE} \, t_N + (1 - t_N) V_{gB} \tag{4.23a}$$

$$V_{dET} = U_{dET} + V_T \ln\{1 + \exp[(V_{d,low} - U_{dET})/V_T]\} \tag{4.23b}$$

$$U_{dCT} = -3 V_T \ln t_N + V_{dC} \, t_N + (1 - t_N) V_{gC} \tag{4.24a}$$

$$V_{dCT} = U_{dCT} + V_T \ln\{1 + \exp[(V_{d,low} - U_{dCT})/V_T]\} \tag{4.24b}$$

$$U_{dCctcT} = -3 V_T \ln t_N + V_{dCctc} \, t_N + (1 - t_N) V_{gC} \tag{4.25a}$$

$$V_{dCctcT} = U_{dCctcT} + V_T \ln\{1 + \exp[(V_{d,low} - U_{dCctcT})/V_T]\} \tag{4.25b}$$

$$U_{dST} = -3 V_T \ln t_N + V_{dS} \, t_N + (1 - t_N) V_{gS} \tag{4.26a}$$

$$V_{dST} = U_{dST} + V_T \ln\{1 + \exp[(V_{d,low} - U_{dST})/V_T]\} \tag{4.26b}$$

$$U_{dCexT} = -3 V_T \ln t_N + V_{dCex} \, t_N + (1 - t_N) V_{gC} \tag{4.27a}$$

$$V_{dCexT} = U_{dCexT} + V_T \ln\{1 + \exp[(V_{d,low} - U_{dCexT})/V_T]\} \tag{4.27b}$$

$$U_{KnbrT} = -3 V_T \ln t_N + V_{Knbr} \, t_N + (1 - t_N) V_{gKnbr} \tag{4.28a}$$

$$V_{KnbrT} = U_{KnbrT} + V_T \ln\{1 + \exp[(V_{d,low} - U_{KnbrT})/V_T]\} \tag{4.28b}$$

#### Depletion Capacitances (Temperature)

$$C_{jET} = C_{jE} \left(\frac{V_{dE}}{V_{dET}}\right)^{p_E} \tag{4.29}$$

$$C_{jST} = C_{jS} \left(\frac{V_{dS}}{V_{dST}}\right)^{p_S} \tag{4.30}$$

$$C_{jCT} = C_{jC} \left[ (1 - X_p) \left(\frac{V_{dC}}{V_{dCT}}\right)^{p_C} + X_p \right] \tag{4.31}$$

$$X_{pT} = X_p \left[ (1 - X_p) \left(\frac{V_{dC}}{V_{dCT}}\right)^{p_C} + X_p \right]^{-1} \tag{4.32}$$

#### Resistances (Temperature)

$$R_{ET} = R_E \, t_N^{A_E} \tag{4.33}$$

$$R_{BvT} = R_{Bv} \, t_N^{A_B - A_{QB0}} \tag{4.34}$$

$$R_{BcT} = R_{Bc} \, t_N^{A_{ex}} \tag{4.35}$$

$$R_{CvT} = R_{Cv} \, t_N^{A_{epi}} \tag{4.36}$$

$$R_{CcT} = R_{Cc} \, t_N^{A_C} \tag{4.37a}$$

$$R_{CblxT} = R_{Cblx} \, t_N^{A_{Cbl}} \tag{4.37b}$$

$$R_{CbliT} = R_{Cbli} \, t_N^{A_{Cbl}} \tag{4.37c}$$

#### Conductances

$$\text{if } R_{Cc} > 0 \text{ then } G_{CcT} = 1/R_{CcT}, \; \text{else } G_{CcT} = 0 \tag{4.37d}$$

$$\text{if } R_{Cblx} > 0 \text{ then } G_{CblxT} = 1/R_{CblxT}, \; \text{else } G_{CblxT} = 0 \tag{4.37e}$$

$$\text{if } R_{Cbli} > 0 \text{ then } G_{CbliT} = 1/R_{CbliT}, \; \text{else } G_{CbliT} = 0 \tag{4.37f}$$

#### Currents and Voltages (Temperature)

$$I_{sT} = I_s \, t_N^{(4 - A_B - A_{QB0} + dA_{Is})/\text{NFF}_T} \exp\!\left[-\frac{V_{gB}}{\text{NFF}_T \, V_{\Delta T}}\right] \tag{4.38}$$

$$I_{kT} = I_k \, t_N^{1 - A_B} \tag{4.39}$$

$$I_{statT} = I_{stat} \sqrt{t_N} \exp[K_{tat}(T_K - T_{RK})] \tag{4.40}$$

$$I_{BInbrT} = I_{BInbr} \exp\!\left[-\frac{V_{gBnbr}}{N_{BI} \, V_{\Delta T}}\right] \tag{4.41}$$

$$I_{BInbrqsT} = I_{BInbrqs} \exp\!\left[-\frac{V_{gBnbrqs}}{V_{\Delta T}}\right] \tag{4.42}$$

$$I_{SBInbrT} = I_{SBInbr} \exp\!\left[-\frac{V_{gSBnbr}}{N_{SBI} \, V_{\Delta T}}\right] \tag{4.43}$$

$$I_{BIT} = I_{BI} \, t_N^{(4 - A_E + dA_{Is})/N_{BI}} \exp\!\left[-\frac{V_{gE}}{N_{BI} \, V_{\Delta T}}\right] \tag{4.44}$$

$$I_{SBIT} = I_{SBI} \, t_N^{(4 - A_E + dA_{Is})/N_{SBI}} \exp\!\left[-\frac{V_{gE}}{N_{SBI} \, V_{\Delta T}}\right] \tag{4.45}$$

$$I_{SSIB2T} = I_{SBf} \, t_N^{(6 - 2m_{SLf})} \exp\!\left[-\frac{V_{gj}}{m_{SLf} \, V_{\Delta T}}\right] \tag{4.46}$$

$$I_{BXT} = I_{BX} \, t_N^{4 - A_{CX} + dA_{Is}} \exp\!\left[-\frac{V_{gCX}}{V_{\Delta T}}\right] \tag{4.47}$$

$$I_{kBXT} = I_{kBX} \, t_N^{1 - A_{CX}} \tag{4.48}$$

$$I_{BfT} = I_{Bf} \, t_N^{(6 - 2m_{Lf})} \exp\!\left[-\frac{V_{gj}}{m_{Lf} \, V_{\Delta T}}\right] \tag{4.49}$$

$$I_{BrT} = I_{Br} \, t_N^{(6 - 2m_{Lr})} \exp\!\left[-\frac{V_{gC}}{m_{Lr} \, V_{\Delta T}}\right] \tag{4.50}$$

$$I_{SIBrelT} = I_{SIBrel} \, t_N^{4/N_{FIBrel}} \exp\!\left[-\frac{V_{gj}}{N_{FIBrel} \, V_{\Delta T}}\right] \tag{4.51}$$

$$V_{efT} = V_{ef} \, t_N^{A_{QB0}} \left[ (1 - X_p) \left(\frac{V_{dC}}{V_{dCT}}\right)^{p_C} + X_p \right]^{-1} \tag{4.52}$$

$$V_{erT} = V_{er} \, t_N^{A_{QB0}} \left(\frac{V_{dE}}{V_{dET}}\right)^{-p_E} \tag{4.53}$$

$$I_{SsT} = I_{Ss} \, t_N^{4 - A_S} \exp[-V_{gS}/V_{\Delta T}] \tag{4.54}$$

$$I_{ksT} = I_{ks} \, t_N^{1 - A_S} \tag{4.55}$$

$$I_{CSsT} = I_{CSs} \, t_N^{3.5 - 0.5 A_{sub}} \exp[-V_{gS}/V_{\Delta T}] \tag{4.56}$$

$$I_{kcsT} = I_{kcs} \, t_N^{1 - A_{sub}} \tag{4.57}$$

#### Transit Times (Temperature)

$$\tau_{ET} = \tau_E \, t_N^{(A_B - 2)} \exp[-dV_{g\tau E}/V_{\Delta T}] \tag{4.58}$$

$$\tau_{BT} = \tau_B \, t_N^{A_{QB0} + A_B - 1} \tag{4.59}$$

$$\tau_{epiT} = \tau_{epi} \, t_N^{A_{epi} - 1} \tag{4.60}$$

$$\tau_{RT} = \tau_R \frac{\tau_{BT} + \tau_{epiT}}{\tau_B + \tau_{epi}} \tag{4.61}$$

$$\tau_{exT} = \tau_{ex} \, t_N^{A_{epiex} - 1} \tag{4.62}$$

#### Avalanche Constant (Temperature)

SWAVL=1:

$$B_{avlT} = B_{avl} [1 + \lambda_{avl}(T_K - T_{ref})] \tag{4.63}$$

where $\lambda_{avl} = T_{Bavl}$.

SWAVL=2, for $T_K < 525$ K:

$$B_{nT} = B_n [1 + 7.2 \times 10^{-4}(T_K - 300) - 1.6 \times 10^{-6}(T_K - 300)^2] \tag{4.64a}$$

For $T_K \ge 525$ K:

$$B_{nT} = B_n \cdot 1.081 \tag{4.64b}$$

#### Heterojunction Temperature

$$dE_{gT} = dE_g \, t_N^{A_{QB0}} \tag{4.65}$$

#### EB Zener Tunneling Temperature

$$V_{gZEB0K} = \text{max\_logexp}\!\left(V_{gZEB} + \frac{A_{VgEB} \cdot T_{RK}^2}{T_{RK} + T_{VgEB}},\; 0.05;\; 0.1\right) \tag{4.66}$$

$$V_{gZEBT} = \text{max\_logexp}\!\left(V_{gZEB0K} - \frac{A_{VgEB} \cdot T_K^2}{T_K + T_{VgEB}},\; 0.05;\; 0.1\right) \tag{4.67}$$

$$N_{zEBT} = N_{zEB} \left(\frac{V_{gZEBT}}{V_{gZEB}}\right)^{3/2} \left(\frac{V_{dET}}{V_{dE}}\right)^{p_E - 1} \tag{4.68}$$

$$I_{zEBT} = I_{zEB} \left(\frac{V_{gZEBT}}{V_{gZEB}}\right)^{-1/2} \left(\frac{V_{dET}}{V_{dE}}\right)^{2 - p_E} \exp(N_{zEB} - N_{zEBT}) \tag{4.69}$$

#### CB Zener Tunneling Temperature

$$V_{gZCB0K} = \text{max\_logexp}\!\left(V_{gZCB} + \frac{A_{VgCB} \cdot T_{RK}^2}{T_{RK} + T_{VgCB}},\; 0.05;\; 0.1\right) \tag{4.70}$$

$$V_{gZCBT} = \text{max\_logexp}\!\left(V_{gZCB0K} - \frac{A_{VgCB} \cdot T_K^2}{T_K + T_{VgCB}},\; 0.05;\; 0.1\right) \tag{4.71}$$

$$N_{zCBT} = N_{zCB} \left(\frac{V_{gZCBT}}{V_{gZCB}}\right)^{3/2} \left(\frac{V_{dCT}}{V_{dC}}\right)^{p_C - 1} \tag{4.72}$$

$$I_{zCBT} = I_{zCB} \left(\frac{V_{gZCBT}}{V_{gZCB}}\right)^{-1/2} \left(\frac{V_{dCT}}{V_{dC}}\right)^{2 - p_C} \exp(N_{zCB} - N_{zCBT}) \tag{4.73}$$

#### Self-Heating Thermal Resistance Temperature

$$R_{th,Tamb} = R_{th} \cdot \left(\frac{T_{amb}}{T_{RK}}\right)^{A_{th}} \tag{4.74}$$

---

### Main Current

Ideal forward and reverse current:

$$I_f = I_{sT} \exp\!\left[\frac{\mathcal{V}_{B2E1}}{\text{NFF}_T \, V_T}\right] \tag{4.75}$$

$$I_r = \begin{cases} I_{ssr} \, I_{sT} \, e^{V^*_{B2C2}/(\text{NFR}_T \, V_T)} & I_{C1C2} \ge 0 \\ I_{ssr} \, I_{sT} \, e^{\mathcal{V}_{B2C2}/(\text{NFR}_T \, V_T)} & I_{C1C2} \le 0 \end{cases} \tag{4.76}$$

NFF temperature dependence (when $t_{NFF} \ne 0$):

$$\text{NFF}_{T,tmp} = \text{NFF} \cdot (1 + dT \cdot t_{NFF})$$
$$\text{NFF}_{T,tmp} = \text{max\_logexp}(\text{NFF}_{T,tmp},\; 1.0;\; 0.001) \tag{4.77}$$
$$\text{NFF}_T = \text{NFF}_{T,tmp} - 0.001 \cdot \ln(2)$$

NFR temperature dependence (when $t_{NFR} \ne 0$):

$$\text{NFR}_{T,tmp} = \text{NFR} \cdot (1 + dT \cdot t_{NFR})$$
$$\text{NFR}_{T,tmp} = \text{max\_logexp}(\text{NFR}_{T,tmp},\; 1.0;\; 0.001) \tag{4.78}$$
$$\text{NFR}_T = \text{NFR}_{T,tmp} - 0.001 \cdot \ln(2)$$

When $t_{NFF} = 0$: $\text{NFF}_T = \text{NFF}$. When $t_{NFR} = 0$: $\text{NFR}_T = \text{NFR}$.

Early effect and base charge:

$$q_0^I = 1 + \frac{V_{tE}}{V_{erT}} + \frac{V_{tC}}{V_{efT}} \tag{4.79}$$

$$q_1^I = \frac{q_0^I + \sqrt{(q_0^I)^2 + 0.01}}{2} \tag{4.80}$$

$$q_B^I = q_1^I \left(1 + \tfrac{1}{2} n_0 + \tfrac{1}{2} n_B\right) \tag{4.81}$$

$$I_N = \frac{I_f - I_r}{q_B^I} \tag{4.82}$$

### Forward Base Currents

#### SWIB1 = 0 Model

$$I_{B1} = I_{B1E} + I_{B1\,nbr} \tag{4.83}$$

$$I_{B1E} = I_{BIT}\!\left[(1 - X_{rec})\left(e^{\mathcal{V}_{B2E1}/(N_{BI}\,V_T)} - 1\right)\right] \tag{4.84}$$

$$I_{B1\,nbr} = I_{B1\,nbr,EB} + I_{Bqs1\,nbr} \tag{4.85}$$

$$I_{B1\,nbr,EB} = X_{rec} \, I_{BIT}\!\left(e^{\mathcal{V}_{B2E1}/(N_{BI}\,V_T)} - 1\right)\!\left(1 + \frac{V_{tC}}{V_{efT}}\right) \tag{4.86}$$

$$I_{Bqs1\,nbr} = X_{rec} \, I_{BIT}\!\left(e^{V^*_{B2C2}/V_T} - 1\right)\!\left(1 + \frac{V_{tC}}{V_{efT}}\right) \tag{4.87}$$

$$I_{BS1} = I_{BS1E} \tag{4.88}$$

$$I_{BS1E} = I_{SBIT}\!\left(e^{\mathcal{V}_{B1E1}/(N_{SBI}\,V_T)} - 1\right) \tag{4.89}$$

#### SWIB1 = 1 Model (NBR)

$$I_{B1} = I_{B1E} + I_{B1\,nbr} \tag{4.90}$$

$$I_{B1E} = I_{BIT}\!\left(e^{\mathcal{V}_{B2E1}/(N_{BI}\,V_T)} - 1\right) \tag{4.91}$$

$$I_{B1\,nbr} = I_{B1\,nbr,EB} + I_{Bqs1\,nbr} \tag{4.92}$$

$$I_{B1\,nbr,EB} = \frac{2\, I_{BInbrT}\,(1 + V_{tC}/V_{efT})\,(e^{\mathcal{V}_{B2E1}/(N_{BI}\,V_T)} - 1)}{1 + \sqrt{1 + 4\, e^{(\mathcal{V}_{B2E1} - V_{KnbrT})/V_T}}} \tag{4.93}$$

$$I_{Bqs1\,nbr} = I_{BInbrqsT}\!\left(e^{V^*_{B2C2}} - 1\right) \frac{e^{I_N/I_{sT}} - 0.001}{1 + e^{I_N/I_{sT}} - 0.001} \tag{4.94}$$

$$I_{BS1} = I_{BS1E} + I_{BS1\,nbr} \tag{4.95}$$

$$I_{BS1E} = I_{SBIT}\!\left(e^{\mathcal{V}_{B1E1}/(N_{SBI}\,V_T)} - 1\right) \tag{4.96}$$

$$I_{BS1\,nbr} = \frac{2\, I_{SBInbrT}\,(e^{\mathcal{V}_{B1E1}/(N_{SBI}\,V_T)} - 1)}{1 + \sqrt{1 + 4\, e^{(\mathcal{V}_{B1E1} - V_{KnbrT})/V_T}}} \tag{4.97}$$

#### Band-to-Band Tunneling (BTBT) Current

$$V_{tmp1} = \text{min\_logexp}(\mathcal{V}_{B2E1},\; V_{btbt};\; 0.001) \tag{4.98}$$

$$I_{BTBT} = K_{btbt} \, V_{tmp1} \, (V_{btbt} - V_{tmp1})^2 \tag{4.99}$$

#### Trap-Assisted Tunneling (TAT) Current

$$V_{tmp2} = \text{max\_logexp}(\mathcal{V}_{B2E1},\; 0.0;\; 0.0001) \tag{4.100}$$

$$I_{TAT} = I_{statT}\!\left(e^{V_{tmp2}/V_{stat}} - 1.0\right) \tag{4.101}$$

where $V_{stat} = V_{tat}$.

#### Non-Ideal Base Currents

$$I_{B2} = I_{BfT}\!\left(e^{\mathcal{V}_{B2E1}/(m_{Lf}\,V_T)} - 1\right) \tag{4.102}$$

$$I_{BS2} = I_{SSIB2T}\!\left(e^{\mathcal{V}_{B2E1}/(m_{SLf}\,V_T)} - 1\right) \tag{4.103}$$

$$I_{Brel} = I_{SIBrelT}\!\left(e^{\mathcal{V}_{B2E1}/(N_{FIBrel}\,V_T)} - 1\right) \tag{4.104}$$

### Reverse Base Currents

$$I_{B3} = I_{BrT}\!\left(e^{\mathcal{V}_{B1C4}/(m_{Lr}\,V_T)} - 1\right) \tag{4.105}$$

#### Substrate Currents (EXSUB=0)

$$I_{sub\,int} = X_{isubi} \frac{2\, I_{SsT}\!\left(e^{\mathcal{V}_{B2C2}/V_T} - 1\right)}{1 + \sqrt{1 + 4\,\frac{I_{SsT}}{I_{ksT}}\, e^{\mathcal{V}_{B2C2}/V_T}}} \tag{4.106a}$$

$$I_{sub} = (1 - X_{isubi}) \frac{2\, I_{SsT}\!\left(e^{\mathcal{V}_{B1C4}/V_T} - 1\right)}{1 + \sqrt{1 + 4\,\frac{I_{SsT}}{I_{ksT}}\, e^{\mathcal{V}_{B1C4}/V_T}}} \tag{4.106b}$$

#### Substrate Currents (EXSUB=1)

$$I_{sub\,int} = X_{isubi} \frac{2\, I_{SsT}\!\left(e^{\mathcal{V}_{B2C2}/V_T} - e^{\mathcal{V}_{SC1}/V_T}\right)}{1 + \sqrt{1 + 4\,\frac{I_{SsT}}{I_{ksT}}\!\left(e^{\mathcal{V}_{B2C2}/V_T} + \text{SWVSCH}\, e^{\mathcal{V}_{SC1}/V_T}\right)}} \tag{4.106c}$$

$$I_{sub} = (1 - X_{isubi}) \frac{2\, I_{SsT}\!\left(e^{\mathcal{V}_{B1C4}/V_T} - e^{\mathcal{V}_{SC4}/V_T}\right)}{1 + \sqrt{1 + 4\,\frac{I_{SsT}}{I_{ksT}}\!\left(e^{\mathcal{V}_{B1C4}/V_T} + \text{SWVSCH}\, e^{\mathcal{V}_{SC4}/V_T}\right)}} \tag{4.106d}$$

#### Substrate-Collector Diode Current

$$I_{Sf} = \frac{2\, I_{CSsT}\!\left(e^{\mathcal{V}_{SC1}/V_T} - 1\right)}{1 + \sqrt{1 + \text{SWVSCH} \cdot 4\,\frac{I_{CSsT}}{I_{kcsT}}\, e^{\mathcal{V}_{SC1}/V_T}}} \tag{4.107}$$

#### Extrinsic Reverse Base Current

$$I_{ex} = \frac{2\, I_{BXT}\!\left(e^{\mathcal{V}_{B1C4}/V_T} - 1\right)}{1 + \sqrt{1 + 4\,\frac{I_{BXT}}{I_{kBXT}}\, e^{\mathcal{V}_{B1C4}/V_T}}} \tag{4.108}$$

### Avalanche Current

In reverse mode ($I_{C1C2} \le 0$) or hard saturation ($\mathcal{V}_{B2C1} \ge V_{dCT}$):

$$G_{EM} = 0, \quad I_{avl} = 0 \tag{4.109}$$

#### SWAVL=0

$$G_{EM} = 0, \quad I_{avl} = 0 \tag{4.110}$$

#### SWAVL=1 (default)

$$\phi = (V_{dCavl} + \mathcal{V}_{C2B1}) \exp\!\left(-\frac{I_N}{I_{TOavl}}\right) \tag{4.111}$$

$$G_{EM} = \frac{A_{avl}}{B_{avlT}} \, \phi \, \exp(-B_{avlT} \, \phi^{C_{avl}}) \tag{4.112}$$

#### SWAVL=2 (Mextram 504 model)

$$dEdx_0 = \frac{2\, V_{avl}}{W_{avl}^2} \tag{4.113}$$

$$x_D = \sqrt{\frac{2}{dEdx_0} \cdot \frac{V_{dCT} - \mathcal{V}_{B2C1}}{1 - I_{cap}/I_{hc}}} \tag{4.114}$$

EXAVL=0:

$$W_{eff} = W_{avl} \tag{4.115}$$

EXAVL=1:

$$W_{eff} = W_{avl}\!\left(1 - \frac{x_i}{2\, W_{epi}}\right)^2 \tag{4.116}$$

$$W_D = \frac{x_D \, W_{eff}}{\sqrt{x_D^2 + W_{eff}^2}} \tag{4.117}$$

$$E_{av} = \frac{V_{dCT} - \mathcal{V}_{B2C1}}{W_D} \tag{4.118}$$

$$E_0 = E_{av} + \tfrac{1}{2} W_D \, dEdx_0 \!\left(1 - \frac{I_{cap}}{I_{hc}}\right) \tag{4.119}$$

EXAVL=0: $E_M = E_0$ (4.120)

EXAVL=1:

$$SHW = 1 + 2\, S_{fH}\!\left(1 + \frac{2\, x_i}{W_{epi}}\right) \tag{4.121}$$

$$E_{fi} = \frac{1 + S_{fH}}{1 + 2\, S_{fH}} \tag{4.122}$$

$$E_W = E_{av} - \tfrac{1}{2} W_D \, dEdx_0\!\left(E_{fi} - \frac{I_{C1C2}}{I_{hc} \, SHW}\right) \tag{4.123}$$

$$E_M = \tfrac{1}{2}\!\left[E_W + E_0 + \sqrt{(E_W - E_0)^2 + 0.1\, E_{av}^2 \, I_{cap}/I_{hc}}\right] \tag{4.124}$$

$$\lambda_D = \frac{E_M \, W_D}{2(E_M - E_{av})} \tag{4.125}$$

$$G_{EM} = \frac{A_n}{B_{nT}} E_M \lambda_D \left[\exp\!\left(-\frac{B_{nT}}{E_M}\right) - \exp\!\left(-\frac{B_{nT}}{E_M}\!\left(1 + \frac{W_{eff}}{\lambda_D}\right)\right)\right] \tag{4.126}$$

When $E_M \approx E_{av}$ ($(1 - E_{av}/E_M) < 10^{-7}$):

$$G_{EM} = A_n \, W_{eff} \exp\!\left(-\frac{B_{nT}}{E_M}\right) \tag{4.127}$$

#### SWAVL=3

$$V_{DEP,tmp} = (V_{dCavl} - \mathcal{V}_{B2C1})^{C_{avl}} \!\left(1 - \frac{I_N}{I_{hcavl} + I_N}\right)^{D_{avl}} \tag{4.128}$$

EXAVL=0:

$$V_{DEP} = V_{DEP,tmp} \tag{4.129}$$

EXAVL=1:

$$I_{N,shift} = \text{max\_logexp}\!\left(\frac{I_N - I_{onexavl}}{I_{hcavl}},\; 1.0;\; A_{exavl}\right) \tag{4.130a}$$

$$V_{DEP} = V_{DEP,tmp} \, I_{N,shift}^{E_{avl}} \tag{4.130b}$$

$$G_{EM} = \frac{A_{avl}}{B_{avlT}} (V_{dCavl} - \mathcal{V}_{B2C1}) \exp(-B_{avlT} \, V_{DEP}) \tag{4.131}$$

#### GEM Limiting (SWGEMLIM=1)

$$G_{max} = \frac{V_T}{I_N(R_{BcT} + R_{B2})} + \frac{q_B^I \, I_{BIT}}{I_{sT}} + \frac{R_{ET}}{R_{BcT} + R_{B2}} \tag{4.132}$$

For SWAVL=1, 2:

$$G_{EM} = \frac{G_{EM} \, G_{max}}{G_{EM} + G_{max}} \tag{4.133a}$$

$$I_{avl} = I_N \, G_{EM} \tag{4.133b}$$

For SWAVL=3:

$$G_{EM} = \text{min\_logexp}(G_{EM},\; G_{max};\; 1 \times 10^{-6}) \tag{4.134a}$$

$$I_{avl} = I_N \, G_{EM} \tag{4.134b}$$

### Emitter-Base Zener Tunneling Current

For $\mathcal{V}_{B2E1} < 0$ (reverse bias):

$$x_z = \frac{\mathcal{V}_{B2E1}}{V_{dET}} \tag{4.135a}$$

$$\tilde{E}_{0EB} = \frac{1}{6(-x_z)^{2+p_E}} \left[p_E(1-p_E)(2-3x_z(p_E-1)-6x_z^2(p_E-1+x_z))\right] \tag{4.135b}$$

$$D_{zEB} = -\mathcal{V}_{B2E1} - \frac{V_{gZEBT}}{2^{2-p_E} N_{zEBT}} \tilde{E}_{0EB}\!\left(1 - \exp\!\left(\frac{2^{2-p_E} N_{zEBT} \mathcal{V}_{B2E1}}{V_{gZEBT} \tilde{E}_{0EB}}\right)\right) \tag{4.136}$$

$$I_{ztEB} = \frac{I_{zEBT}}{2^{1-p_E} V_{dET}} D_{zEB} \tilde{E}_{0EB} \exp\!\left(N_{zEBT}\!\left(1 - \frac{2^{1-p_E}}{\tilde{E}_{0EB}}\right)\right) \tag{4.137}$$

$I_{ztEB}$ is positive from E1 to B2. For $\mathcal{V}_{B2E1} \ge 0$: $I_{ztEB} = 0$.

### Collector-Base Zener Tunneling Current

$$x_z = \frac{\mathcal{V}_{B2C1}}{V_{dCctcT}} \tag{4.138a}$$

$$\tilde{E}_{0CB} = \frac{1}{6(-x_z)^{2+p_C}} \left[p_C(1-p_C)(2-3x_z(p_C-1)-6x_z^2(p_C-1+x_z))\right] \tag{4.138b}$$

$$D_{zCB} = -\mathcal{V}_{B2C1} - \frac{V_{gZCBT}}{2^{2-p_C} N_{zCBT}} \tilde{E}_{0CB}\!\left(1 - \exp\!\left(\frac{2^{2-p_C} N_{zCBT} \mathcal{V}_{B2C1}}{V_{gZCBT} \tilde{E}_{0CB}}\right)\right) \tag{4.139}$$

$$I_{ztCB} = \frac{I_{zCBT}}{2^{1-p_C} V_{dCctcT}} D_{zCB} \tilde{E}_{0CB} \exp\!\left(N_{zCBT}\!\left(1 - \frac{2^{1-p_C}}{\tilde{E}_{0CB}}\right)\right) \tag{4.140}$$

$I_{ztCB}$ is positive from C2 to B2.

### Variable Base Resistance

$$q_0^Q = 1 + \frac{V_{tE}}{V_{erT}} + \frac{V_{tC}}{V_{efT}} \tag{4.141}$$

$$q_1^Q = \frac{q_0^Q + \sqrt{(q_0^Q)^2 + 0.01}}{2} \tag{4.142}$$

$$q_B^Q = q_1^Q\!\left(1 + \tfrac{1}{2} n_0 + \tfrac{1}{2} n_B\right) \tag{4.143}$$

$$R_{B2} = \frac{3\, R_{BvT}}{q_B^Q} \tag{4.144}$$

$$I_{B1B2} = \frac{2 V_T}{R_{B2}}\!\left(e^{\mathcal{V}_{B1B2}/V_T} - 1\right) + \frac{\mathcal{V}_{B1B2}}{R_{B2}} \tag{4.145}$$

### Variable Collector Resistance: Epilayer Model

$$K_0 = \sqrt{1 + 4\, e^{(\mathcal{V}_{B2C2} - V_{dCT})/V_T}} \tag{4.146}$$

$$K_W = \sqrt{1 + 4\, e^{(\mathcal{V}_{B2C1} - V_{dCT})/V_T}} \tag{4.147}$$

$$p_W = \frac{2\, e^{(\mathcal{V}_{B2C1} - V_{dCT})/V_T}}{1 + K_W} \tag{4.148}$$

$$E_c = V_T\!\left(K_0 - K_W - \ln\!\frac{K_0 + 1}{K_W + 1}\right) \tag{4.149}$$

$$I_{C1C2} = \frac{E_c + \mathcal{V}_{C1C2}}{R_{CvT}} \tag{4.150}$$

#### Forward Mode ($I_{C1C2} > 0$)

$$V_{qs}^{th} = V_{dCT} + 2 V_T \ln\!\left(\frac{I_{C1C2} R_{CvT}}{2 V_T} + 1\right) - \mathcal{V}_{B2C1} \tag{4.151}$$

$$V_{qs} = \tfrac{1}{2}\!\left[V_{qs}^{th} + \sqrt{(V_{qs}^{th})^2 + 4(0.1\, V_{dCT})^2}\right] \tag{4.152}$$

$$I_{qs} = \frac{V_{qs}}{SCR_{Cv}} \cdot \frac{V_{qs} + I_{hc}\, SCR_{Cv}}{V_{qs} + I_{hc}\, R_{CvT}} \tag{4.153}$$

$$\alpha = \frac{1 + a_{xi} \ln\{1 + \exp[(I_{C1C2}/I_{qs} - 1)/a_{xi}]\}}{1 + a_{xi} \ln\{1 + \exp[-1/a_{xi}]\}} \tag{4.154}$$

Solve for $y_i$ from:

$$\alpha\, I_{qs} = \frac{V_{qs}}{SCR_{Cv}\, y_i^2} \cdot \frac{V_{qs} + SCR_{Cv}\, I_{hc}\, y_i}{V_{qs} + R_{CvT}\, I_{hc}} \tag{4.155}$$

$$v = \frac{V_{qs}}{I_{hc}\, SCR_{Cv}} \tag{4.156}$$

$$y_i = \frac{1 + \sqrt{1 + 4\,\alpha\, v\,(1+v)}}{2\,\alpha\,(1+v)} \tag{4.157}$$

Injection thickness:

$$\frac{x_i}{W_{epi}} = 1 - \frac{y_i}{1 + p_W\, y_i} \tag{4.158}$$

Hole density at junction:

$$g = \frac{I_{C1C2}\, R_{CvT}}{2 V_T} \cdot \frac{x_i}{W_{epi}} \tag{4.159}$$

$$p_0^* = \frac{g-1}{2} + \sqrt{\left(\frac{g-1}{2}\right)^2 + 2g + p_W(p_W + g + 1)} \tag{4.160}$$

When $p_0^* < e^{-40}$: $p_0^* \to 0$.

$$e^{V^*_{B2C2}/V_T} = p_0^*(p_0^* + 1)\, e^{V_{dCT}/V_T} \tag{4.161}$$

#### Reverse Mode ($I_{C1C2} \le 0$)

$$p_0^* = \frac{2\, e^{(\mathcal{V}_{B2C2} - V_{dCT})/V_T}}{1 + K_0} \tag{4.162}$$

$$e^{V^*_{B2C2}/V_T} = e^{\mathcal{V}_{B2C2}/V_T} \tag{4.163}$$

$$\frac{x_i}{W_{epi}} = \frac{E_c}{E_c + \mathcal{V}_{B2C2} - \mathcal{V}_{B2C1}} \tag{4.164}$$

When $|V_{C1C2}| < 10^{-5} V_T$ or $|E_c| < e^{-40} V_T (K_0 + K_W)$:

$$p_{av} = \frac{p_0^* + p_W}{2} \tag{4.165}$$

$$\frac{x_i}{W_{epi}} = \frac{p_{av}}{p_{av} + 1} \tag{4.166}$$

### Breakdown of CB Junction (SWJBRCB=1)

$$I_{ztCB} \to f_{brcb} \cdot I_{ztCB} \tag{4.167a}$$

$$I_{ex} \to f_{brcb} \cdot I_{ex} \tag{4.167b}$$

$$I_{B3} \to f_{brcb} \cdot I_{B3} \tag{4.167c}$$

$$XI_{ex} \to f_{brcb} \cdot XI_{ex} \tag{4.167d}$$

$$f_{brcb} = \begin{cases} \dfrac{1}{\left(1 - V_{cbeff}/V_{brcb}\right)^{p_{brcb}}} & V_{cbeff} < \alpha_{brcb}\, V_{brcb} \\[6pt] f_{stop} + (V_{cbeff} - \alpha_{brcb}\, V_{brcb})\, df_{brcb} & V_{cbeff} \ge \alpha_{brcb}\, V_{brcb} \end{cases} \tag{4.168}$$

$$V_{cbeff} = 0.5 \cdot \!\left(\sqrt{\mathcal{V}_{C1B1}^2 + \epsilon^2} + \mathcal{V}_{C1B1}\right), \quad \epsilon = 10^{-6} \tag{4.169}$$

$$\alpha_{brcb} = 1 - \frac{1}{f_{revcb}} \tag{4.170}$$

$$f_{stop} = \frac{1}{(1 - \alpha_{brcb})^{p_{brcb}}} \tag{4.171}$$

$$df_{brcb} = f_{stop}^2 \, \alpha_{brcb}^{p_{brcb}-1} \frac{p_{brcb}}{V_{brcb}} \tag{4.172}$$

When SWJBRCB=0: $f_{brcb} = 1$.

### Emitter Depletion Charges

$$V_{FE} = V_{dET}\!\left(1 - \alpha_{jE}^{-1/p_E}\right) \tag{4.173}$$

$$V_{jE} = \mathcal{V}_{B2E1} - 0.1\, V_{dET}\, \ln\{1 + \exp[(\mathcal{V}_{B2E1} - V_{FE})/(0.1\, V_{dET})]\} \tag{4.174}$$

$$E_{0EB} = (1 - V_{jE}/V_{dET})^{1-p_E} \tag{4.175a}$$

$$V_{tE} = \frac{V_{dET}}{1 - p_E}(1 - E_{0EB}) + \alpha_{jE}(\mathcal{V}_{B2E1} - V_{jE}) \tag{4.175b}$$

$$Q_{tE} = (1 - X_{CjE})\, C_{jET}\, V_{tE} \tag{4.176}$$

Sidewall component:

$$V_{jE}^S = \mathcal{V}_{B1E1} - 0.1\, V_{dET}\, \ln\{1 + \exp[(\mathcal{V}_{B1E1} - V_{FE})/(0.1\, V_{dET})]\} \tag{4.177}$$

$$Q_{tE}^S = X_{CjE}\, C_{jET}\!\left[\frac{V_{dET}}{1 - p_E}\!\left(1 - (1 - V_{jE}^S/V_{dET})^{1-p_E}\right) + \alpha_{jE}(\mathcal{V}_{B1E1} - V_{jE}^S)\right] \tag{4.178}$$

### Intrinsic Collector Depletion Charge

Forward mode ($I_{C1C2} > 0$):

$$B_1 = \tfrac{1}{2}\, SCR_{Cv}(I_{C1C2} - I_{hc}) \tag{4.179}$$

$$B_2 = SCR_{Cv}\, R_{CvT}\, I_{hc}\, I_{C1C2} \tag{4.180}$$

$$V_{x_i=0} = B_1 + \sqrt{B_1^2 + B_2} \tag{4.181}$$

Reverse mode ($I_{C1C2} \le 0$):

$$V_{x_i=0} = \mathcal{V}_{C1C2} \tag{4.182}$$

Junction voltage:

$$V_{junc} = \mathcal{V}_{B2C1} + V_{x_i=0} \tag{4.183}$$

Transition voltage:

$$V_{ch} = \begin{cases} 0.1\, V_{dCT} & I_{C1C2} \le 0 \\[4pt] V_{dCT}\!\left(0.1 + 2\,\dfrac{I_{C1C2}}{I_{C1C2} + I_{qs}}\right) & I_{C1C2} > 0 \end{cases} \tag{4.184}$$

$$b_{jC} = \frac{\alpha_{jC} - X_{pT}}{1 - X_{pT}} \tag{4.185}$$

$$V_{FC} = V_{dCctcT}\!\left(1 - b_{jC}^{-1/p_C}\right) \tag{4.186}$$

$$V_{jC} = V_{junc} - V_{ch}\, \ln\{1 + \exp[(V_{junc} - V_{FC})/V_{ch}]\} \tag{4.187}$$

$$E_{0CB} = (1 - V_{jC}/V_{dCT})^{1-p_C} \tag{4.188}$$

Current dependence:

$$I_{cap} = \begin{cases} \dfrac{I_{hc}\, I_{C1C2}}{I_{hc} + I_{C1C2}} & I_{C1C2} > 0 \\[4pt] I_{C1C2} & I_{C1C2} \le 0 \end{cases} \tag{4.189}$$

$$f_I = \left(1 - \frac{I_{cap}}{I_{hc}}\right)^{m_C} \tag{4.190}$$

$$V_{CV} = \frac{V_{dCctcT}}{1 - p_C}\!\left[1 - f_I\,(1 - V_{jC}/V_{dCctcT})^{1-p_C} + f_I\, b_{jC}(V_{junc} - V_{jC})\right] \tag{4.191}$$

$$V_{tC} = (1 - X_{pT})\, V_{CV} + X_{pT}\, \mathcal{V}_{B2C1} \tag{4.192}$$

$$Q_{tC} = X_{CjC}\, C_{jCT}\, V_{tC} \tag{4.193}$$

### Extrinsic Collector Depletion Charges

$$V_{jCex} = \mathcal{V}_{B1C4} - 0.1\, V_{dCT}\, \ln\{1 + \exp[(\mathcal{V}_{B1C4} - V_{FC})/(0.1\, V_{dCT})]\} \tag{4.194}$$

$$V_{texV} = \frac{V_{dCT}}{1-p_C}\!\left[1 - (1 - V_{jCex}/V_{dCT})^{1-p_C} + b_{jC}(\mathcal{V}_{B1C4} - V_{jCex})\right] \tag{4.195}$$

$$Q_{tex} = C_{jCT}\!\left[(1 - X_{pT})\, V_{texV} + X_{pT}\, \mathcal{V}_{B1C4}\right](1 - X_{CjC})(1 - X_{ext}) \tag{4.196}$$

$$XV_{jCex} = \mathcal{V}_{BC3} - 0.1\, V_{dCT}\, \ln\{1 + \exp[(\mathcal{V}_{BC3} - V_{FC})/(0.1\, V_{dCT})]\} \tag{4.197}$$

$$XV_{texV} = \frac{V_{dCT}}{1-p_C}\!\left[1 - (1 - XV_{jCex}/V_{dCT})^{1-p_C} + b_{jC}(\mathcal{V}_{BC3} - XV_{jCex})\right] \tag{4.198}$$

$$XQ_{tex} = C_{jCT}\!\left[(1 - X_{pT})\, XV_{texV} + X_{pT}\, \mathcal{V}_{BC3}\right](1 - X_{CjC})\, X_{ext} \tag{4.199}$$

### Substrate Depletion Charge

$$V_{FS} = V_{dST}\!\left(1 - \alpha_{jS}^{-1/p_S}\right) \tag{4.200}$$

$$V_{jS} = \mathcal{V}_{SC1} - 0.1\, V_{dST}\, \ln\{1 + \exp[(\mathcal{V}_{SC1} - V_{FS})/(0.1\, V_{dST})]\} \tag{4.201}$$

$$Q_{tS} = C_{jST}\!\left[\frac{V_{dST}}{1-p_S}\!\left(1 - (1 - V_{jS}/V_{dST})^{1-p_S}\right) + \alpha_{jS}(\mathcal{V}_{SC1} - V_{jS})\right] \tag{4.202}$$

### Stored Emitter Charge

$$Q_{E0} = \tau_{ET}\, I_{kT}\!\left(\frac{I_{sT}}{I_{kT}}\right)^{1/m_\tau} \tag{4.203}$$

$$Q_E = Q_{E0}\, e^{\mathcal{V}_{B2E1}/(m_\tau\, V_T)} \tag{4.204}$$

### Stored Base Charges

$$Q_{B0} = \tau_{BT}\, I_{kT} \tag{4.205}$$

Base-emitter part:

$$f_1 = \frac{4\, I_{sT}}{I_{kT}}\, e^{\mathcal{V}_{B2E1}/(\text{NFF}_T\, V_T)} \tag{4.206}$$

$$n_0 = \frac{f_1}{1 + \sqrt{1 + f_1}} \tag{4.207}$$

$$Q_{BE} = \tfrac{1}{2}\, Q_{B0}\, n_0\, q_1^Q \tag{4.208}$$

Base-collector part:

$$f_2 = \frac{4\, I_{sT}}{I_{kT}}\, e^{V^*_{B2C2}/V_T} \tag{4.209}$$

$$n_B = \frac{f_2}{1 + \sqrt{1 + f_2}} \tag{4.210}$$

$$Q_{BC} = \tfrac{1}{2}\, Q_{B0}\, n_B\, q_1^Q \tag{4.211}$$

### Stored Epilayer Charge

$$Q_{epi0} = \frac{4\, \tau_{epiT}\, V_T}{R_{CvT}} \tag{4.212}$$

$$Q_{epi} = \tfrac{1}{2}\, Q_{epi0} \frac{x_i}{W_{epi}}(p_0^* + p_W + 2) \tag{4.213}$$

### Stored Extrinsic Charges

$$g_1 = \frac{4\, I_{sT}}{I_{kT}}\!\left(e^{\mathcal{V}_{B1C4}/V_T} - 1\right) \tag{4.214}$$

$$n_{Bex} = \frac{4\, I_{sT}(e^{\mathcal{V}_{B1C4}/V_T} - 1)}{I_{kT}(1 + \sqrt{1 + g_1})} \tag{4.215}$$

$$g_2 = 4\, e^{(\mathcal{V}_{B1C4} - V_{dCT})/V_T} \tag{4.216}$$

$$p_{Wex} = \frac{g_2}{1 + \sqrt{1 + g_2}} \tag{4.217}$$

SWQEX=0 (default):

$$Q_{ex} = \frac{\tau_{RT}}{\tau_{BT} + \tau_{epiT}}\!\left(\tfrac{1}{2}\, Q_{B0}\, n_{Bex} + \tfrac{1}{2}\, Q_{epi0}\, p_{Wex}\right) \tag{4.218}$$

SWQEX=1:

$$Q_{ex} = \frac{2\, I_{BXT}\, \tau_{exT}\, e^{\mathcal{V}_{B1C4}/V_T}}{1 + \sqrt{1 + 4\, e^{(\mathcal{V}_{B1C4} - V_{dCexT})/(N_{ex}\, V_T)}}} \tag{4.219}$$

### Extended Reverse Current Gain (EXMOD > 0)

#### Currents

$$I_{ex} \to (1 - X_{ext})\, I_{ex} \tag{4.220}$$

$$I_{sub} \to (1 - X_{ext})\, I_{sub} \tag{4.221}$$

EXMOD=1 or 3, SWQEX=0:

$$Xg_1 = \frac{4\, I_{sT}}{I_{kT}}\, e^{\mathcal{V}_{BC3}/V_T} \tag{4.222}$$

$$Xn_{Bex} = \frac{4\, I_{sT}(e^{\mathcal{V}_{BC3}/V_T} - 1)}{I_{kT}(1 + \sqrt{1 + Xg_1})} \tag{4.223}$$

$$XI_{Mex} = X_{ext} \frac{2\, I_{BXT}(e^{\mathcal{V}_{BC3}/V_T} - 1)}{1 + \sqrt{1 + 4\,\frac{I_{BXT}}{I_{kBXT}}\, e^{\mathcal{V}_{BC3}/V_T}}} \tag{4.224}$$

EXSUB=0:

$$XI_{Msub} = (1-X_{isubi})\, X_{ext} \frac{2\, I_{SsT}(e^{\mathcal{V}_{BC3}/V_T} - 1)}{1 + \sqrt{1 + 4\,\frac{I_{SsT}}{I_{ksT}}\, e^{\mathcal{V}_{BC3}/V_T}}} \tag{4.225a}$$

EXSUB=1:

$$XI_{Msub} = (1-X_{isubi})\, X_{ext} \frac{2\, I_{SsT}(e^{\mathcal{V}_{BC3}/V_T} - e^{\mathcal{V}_{SC3}/V_T})}{1 + \sqrt{1 + 4\,\frac{I_{SsT}}{I_{ksT}}(e^{\mathcal{V}_{BC3}/V_T} + \text{SWVSCH}\, e^{\mathcal{V}_{SC3}/V_T})}} \tag{4.225b}$$

Current limiting (EXMOD=1):

$$V_{ex} = V_T\!\left(2 - \ln\!\frac{X_{ext}(I_{BXT} + I_{SsT})\, R_{CcT}}{V_T}\right) \tag{4.226}$$

$$V_{Bex} = \tfrac{1}{2}\!\left[(\mathcal{V}_{BC3} - V_{ex}) + \sqrt{(\mathcal{V}_{BC3} - V_{ex})^2 + 0.0121}\right] \tag{4.227}$$

EXMOD=1:

$$F_{ex} = \frac{V_{Bex}}{X_{ext}(I_{BXT} + I_{SsT})\, R_{CcT} + (XI_{Mex} + XI_{Msub})\, R_{CcT} + V_{Bex}} \tag{4.228a}$$

EXMOD=2 or 3:

$$F_{ex} = 1 \tag{4.228b}$$

$$XI_{ex} = F_{ex}\, XI_{Mex} \tag{4.229}$$

$$XI_{sub} = F_{ex}\, XI_{Msub} \tag{4.230}$$

#### Charges (EXMOD > 0)

$$Q_{ex} \to (1 - X_{ext})\, Q_{ex} \tag{4.231}$$

EXMOD=1 or 3, SWQEX=0:

$$Xg_2 = 4\, e^{(\mathcal{V}_{BC3} - V_{dCT})/V_T} \tag{4.232}$$

$$Xp_{Wex} = \frac{Xg_2}{1 + \sqrt{1 + Xg_2}} \tag{4.233}$$

$$XQ_{ex} = F_{ex}\, X_{ext} \frac{\tau_{RT}}{\tau_{BT} + \tau_{epiT}}\!\left(\tfrac{1}{2}\, Q_{B0}\, Xn_{Bex} + \tfrac{1}{2}\, Q_{epi0}\, Xp_{Wex}\right) \tag{4.234}$$

SWQEX=1:

$$XQ_{ex} = \frac{2\, X_{ext}\, I_{BXT}\, \tau_{exT}\, e^{\mathcal{V}_{BC3}/V_T}}{1 + \sqrt{1 + 4\, e^{(\mathcal{V}_{BC3} - V_{dCexT})/V_T}}} \tag{4.235}$$

EXMOD=2: $Q_{ex}$ is not partitioned, $XQ_{ex} = 0$.

### Distributed High-Frequency Effects (EXPHI=1)

AC current crowding charge:

$$Q_{B1B2} = \tfrac{1}{5}\, \mathcal{V}_{B1B2}\!\left(\frac{dQ_{tE}}{d\mathcal{V}_{B2E1}} + \tfrac{1}{2}\, Q_{B0}\, q_1 \frac{dn_0}{d\mathcal{V}_{B2E1}} + \frac{dQ_E}{d\mathcal{V}_{B2E1}}\right) \tag{4.236}$$

Excess phase-shift (base-charge partitioning):

$$Q_{BC} \to X_{QB} \cdot (Q_{BE} + K_E\, Q_E) + Q_{BC} \tag{4.238}$$

$$Q_{BE} \to (1 - X_{QB}) \cdot (Q_{BE} + K_E\, Q_E) \tag{4.239}$$

Total charge between B2 and E1:

$$Q_{B2E1} = Q_{tE} + Q_{BE} + Q_E \cdot (1 - K_E \cdot \text{EXPHI}) \tag{4.240}$$

### Heterojunction Features (dEg != 0)

When $dE_g \ne 0$, redefine $q_0^I$:

$$q_0^I \to \frac{\exp\!\left(\dfrac{V_{tE}}{V_{erT}} + 1\right)\dfrac{dE_{gT}}{V_T} - \exp\!\left(\dfrac{-V_{tC}}{V_{efT}}\right)\dfrac{dE_{gT}}{V_T}}{\exp\!\left(\dfrac{dE_{gT}}{V_T}\right) - 1} \tag{4.241}$$

$q_0^Q$ remains unchanged.

### Noise Model

#### Thermal Noise

$$\overline{i_{NR_E}^2} = \frac{4\, k T_K}{R_{ET}} \Delta f \tag{4.242}$$

$$\overline{i_{NR_{Bc}}^2} = \frac{4\, k T_K}{R_{BcT}} \Delta f \tag{4.243}$$

$$\overline{i_{NR_{Cc}}^2} = 4\, k T_K\, G_{CcT}\, \Delta f \tag{4.244a}$$

$$\overline{i_{NR_{Cblx}}^2} = 4\, k T_K\, G_{CblxT}\, \Delta f \tag{4.244b}$$

$$\overline{i_{NR_{Cbli}}^2} = 4\, k T_K\, G_{CbliT}\, \Delta f \tag{4.244c}$$

Variable base resistance noise (with current crowding):

$$\overline{i_{NR_{Bv}}^2} = \frac{4\, k T_K}{R_{B2}} \cdot \frac{4\, e^{\mathcal{V}_{B1B2}/V_T} + 5}{3}\, \Delta f \tag{4.245}$$

#### Intrinsic Transistor Noise

Base current shot noise + 1/f noise (between B2 and E1):

$$\overline{i_{b0} i_{b0}^*} = \left\{2q(|I_{B1}| + |I_{B2}| + |I_{ztEB}|) + \frac{K_f}{f}|I_{B1}|^{A_f} + \frac{K_{fN}}{f}|I_{B2}|^{A_{fN}}\right\}\Delta f \tag{4.246}$$

Collector current shot noise:

$$\overline{i_{C0} i_{C0}^*} = 2q\, I_{C0}\, \Delta f \tag{4.247a}$$

$$I_{C0} = \frac{I_f + I_r}{q_B^I} \tag{4.247b}$$

Correlated base noise:

$$i_{b1} = j\omega\, \tau_n\, i_{C0} \tag{4.248}$$

Noise transit time:

$$\tau_n = \begin{cases} 0 & K_C = 0 \\ X_{QB}\, \tau_{Bn} & K_C = 1 \\ F_{taun}\, \tau_{Bn} & K_C = 2 \end{cases} \tag{4.249a}$$

$$\tau_{Bn} = \begin{cases} \dfrac{Q_{BE} + Q_{BC}}{I_{C0}} & I_{C0} > 0 \\[6pt] \tau_{BT}\, q_1\, q_B & I_{C0} = 0 \end{cases} \tag{4.250}$$

Avalanche multiplication noise:

$$i_M = K_{avl}(M-1)\, i_{C0} \tag{4.251}$$

$$M - 1 = \frac{I_{avl}}{I_{C0}} \tag{4.252}$$

Impact ionization noise:

$$\overline{i_{II} i_{II}^*} = K_{avl} \cdot 2q\, I_{C0}(M-1)\, M\, \Delta f \tag{4.253}$$

#### Parasitic Noise

Side-wall and non-ideal base current noise (between B1 and E1):

$$\overline{i_{B1E1} i_{B1E1}^*} = \left\{2q(|I_{BS1}| + |I_{BS2}| + |I_{Brel}|) + \frac{K_{fN}}{f}(|I_{B2}| + |I_{BS2}| + |I_{Brel}|)^{A_{fN}}\right\}\Delta f \tag{4.254}$$

Reverse base current noise:

$$\overline{i_{NIB3}^2} = \left(2q|I_{B3}| + \frac{K_f}{f}|I_{B3}|^{A_f} + 2q\, I_{ztCB}\right)\Delta f \tag{4.255}$$

Extrinsic current noise (EXMOD=0):

$$\overline{i_{NIex}^2} = \left(2q|I_{ex}| + \frac{K_f}{f}|I_{ex}|^{A_f}\right)\Delta f \tag{4.256}$$

Extrinsic current noise (EXMOD=1):

$$\overline{i_{NIex}^2} = \left\{2q|I_{ex}| + \frac{K_f}{f}(1-X_{ext})\!\left(\frac{|I_{ex}|}{1-X_{ext}}\right)^{A_f}\right\}\Delta f \tag{4.257}$$

$$\overline{i_{NXIex}^2} = \left\{2q|XI_{ex}| + \frac{K_f}{f} X_{ext}\!\left(\frac{|XI_{ex}|}{X_{ext}}\right)^{A_f}\right\}\Delta f \tag{4.258}$$

Substrate current noise:

$$\overline{i_{NIsub\,int}^2} = 2q|I_{sub\,int}|\, \Delta f \tag{4.259}$$

$$\overline{i_{NIsub}^2} = 2q|I_{sub}|\, \Delta f \tag{4.260}$$

$$\overline{i_{NXIsub}^2} = 2q|XI_{sub}|\, \Delta f \tag{4.261}$$

### Self-Heating

Power dissipation:

$$P_{diss} = I_N(\mathcal{V}_{B2E1} - V^*_{B2C2}) + I_{C1C2}(V^*_{B2C2} - \mathcal{V}_{B2C1}) - I_{avl}\, V^*_{B2C2}$$
$$+ \mathcal{V}_{EE1}^2/R_{ET} + \mathcal{V}_{BB1}^2/R_{BcT}$$
$$+ \mathcal{V}_{CC3}^2\, G_{CcT} + \mathcal{V}_{C3C4}^2\, G_{CblxT} + \mathcal{V}_{C4C1}^2\, G_{CbliT}$$
$$+ I_{B1B2}\, \mathcal{V}_{B1B2} + (I_{B1} + I_{B2} - I_{ztEB} + I_{BTBT} + I_{TAT})\, \mathcal{V}_{B2E1} - I_{ztCB}\, \mathcal{V}_{B2C2}$$
$$+ (I_{BS1} + I_{BS2} + I_{Brel})\, \mathcal{V}_{B1E1} + (I_{ex} + I_{B3})\, \mathcal{V}_{B1C4} + XI_{ex}\, \mathcal{V}_{BC3}$$
$$+ I_{sub}\, \mathcal{V}_{B1S} + I_{sub\,int}\, \mathcal{V}_{B2S} + XI_{sub}\, \mathcal{V}_{BS} - I_{Sf}\, \mathcal{V}_{C1S} \tag{4.262}$$

SWNLSH=0 (linear):

$$P_{rth} = \frac{V_{dT}}{R_{th,Tamb}} \tag{4.263}$$

SWNLSH=1 (nonlinear):

$$P_{rth} = \frac{T_{amb}}{(1-A_{th})\, R_{th,Tamb}}\!\left[(1 + V_{dT}/T_{amb})^{1-A_{th}} - 1\right] \tag{4.264}$$

When $A_{th} \to 1$:

$$P_{rth} = \frac{T_{amb}}{R_{th,Tamb}} \ln(1 + V_{dT}/T_{amb}) \tag{4.265}$$

### Convergence Aid

Non-ideal base currents with $G_{min}$:

$$I_{B2} = I_{BfT}(e^{\mathcal{V}_{B2E1}/(m_{Lf}\,V_T)} - 1) + G_{min}\, \mathcal{V}_{B2E1} \tag{4.266}$$

$$I_{B3} = I_{BrT}(e^{\mathcal{V}_{B1C4}/(m_{Lr}\,V_T)} - 1) + G_{min}\, \mathcal{V}_{B1C4} \tag{4.267}$$

### Transition Functions

Smooth minimum:

$$\text{min\_logexp}(x,\, x_0;\, a) = x - a\, \ln\{1 + \exp[(x - x_0)/a]\} \tag{4.268}$$

Implementation:

$$\text{min\_logexp}(x,\, x_0;\, a) = \begin{cases} x - a\, \ln\{1 + \exp[(x - x_0)/a]\} & x < x_0 \\ x_0 - a\, \ln\{1 + \exp[(x_0 - x)/a]\} & x \ge x_0 \end{cases} \tag{4.269}$$

Smooth maximum:

$$\text{max\_logexp}(x,\, x_0;\, a) = x_0 + a\, \ln\{1 + \exp[(x - x_0)/a]\} \tag{4.270}$$

Implementation:

$$\text{max\_logexp}(x,\, x_0;\, a) = \begin{cases} x_0 + a\, \ln\{1 + \exp[(x - x_0)/a]\} & x < x_0 \\ x + a\, \ln\{1 + \exp[(x_0 - x)/a]\} & x \ge x_0 \end{cases} \tag{4.271}$$

Hyperbolic smooth maximum:

$$\text{max\_hyp}(x,\, x_0;\, \epsilon) = \tfrac{1}{2}\!\left[\sqrt{(x - x_0)^2 + 4\epsilon^2} + x + x_0\right] \tag{4.272}$$

Implementation:

$$\text{max\_hyp}(x,\, x_0;\, \epsilon) = \begin{cases} x_0 + \dfrac{2\epsilon^2}{\sqrt{(x-x_0)^2+4\epsilon^2} + x_0 - x} & x < x_0 \\[6pt] x + \dfrac{2\epsilon^2}{\sqrt{(x-x_0)^2+4\epsilon^2} + x - x_0} & x \ge x_0 \end{cases} \tag{4.273}$$

### Derivative Identities

$$n_0 = \frac{f_1}{1 + \sqrt{1+f_1}} = \sqrt{1+f_1} - 1 \tag{4.274a}$$

$$n_B = \frac{f_2}{1 + \sqrt{1+f_2}} = \sqrt{1+f_2} - 1 \tag{4.274b}$$

$$p_{Wex} = \frac{g_2}{1 + \sqrt{1+g_2}} = \sqrt{1+g_2} - 1 \tag{4.274c}$$

$$Xp_{Wex} = \frac{Xg_2}{1 + \sqrt{1+Xg_2}} = \sqrt{1+Xg_2} - 1 \tag{4.274d}$$

$$p_W = \frac{2\,e^{(\mathcal{V}_{B2C1}-V_{dCT})/V_T}}{1+K_W} = \tfrac{1}{2}(K_W - 1) \tag{4.274e}$$

$$p_0^* = \frac{2\,e^{(\mathcal{V}_{B2C2}-V_{dCT})/V_T}}{1+K_0} = \tfrac{1}{2}(K_0 - 1) \quad \text{(reverse mode only)} \tag{4.274f}$$

### Numerical Stability of $p_0^*$

$$p_0^* = \begin{cases} \dfrac{g-1}{2} + \sqrt{\left(\dfrac{g-1}{2}\right)^2 + 2g + p_W(p_W+g+1)} & g > 1 \\[10pt] \dfrac{2g + p_W(p_W+g+1)}{\dfrac{1-g}{2} + \sqrt{\left(\dfrac{1-g}{2}\right)^2 + 2g + p_W(p_W+g+1)}} & g < 1 \end{cases} \tag{4.275}$$

### PNP Embedding

For PNP transistors:
1. Negate all internal voltages ($\mathcal{V} \to -\mathcal{V}$), except $V_{dT}$
2. Compute currents and charges using NPN equations
3. Negate all resulting currents ($I \to -I$) and charges ($Q \to -Q$)
4. Noise densities and $P_{diss}$ do not change sign; derivatives $\partial P_{diss}/\partial \mathcal{V}$ need extra sign change
5. Use PNP-specific $A_n$, $B_n$ constants for SWAVL=2

---

## Summary of Currents

| Current | Placement | Description |
|---------|-----------|-------------|
| $I_N$ | B2-E1, B2-C2 | Main transport current |
| $I_{C1C2}$ | C1-C2 | Epilayer (variable collector resistance) current |
| $I_{B1B2}$ | B1-B2 | Variable base resistance current |
| $I_{B1}$ | B2-E1 | Ideal forward base current |
| $I_{BS1}$ | B1-E1 | Ideal side-wall base current |
| $I_{B2}$ | B2-E1 | Non-ideal forward base current |
| $I_{BS2}$ | B2-E1 | Non-ideal side-wall forward base current |
| $I_{Brel}$ | B2-E1 | Base current for reliability simulation |
| $I_{BTBT}$ | B2-E1 | Band-to-band tunneling current |
| $I_{TAT}$ | B2-E1 | Trap-assisted tunneling current |
| $I_{B3}$ | B1-C4 | Non-ideal reverse base current |
| $I_{avl}$ | B2-C2 | Avalanche current |
| $I_{ztEB}$ | E1-B2 | EB Zener tunneling current |
| $I_{ztCB}$ | C2-B2 | CB Zener tunneling current |
| $I_{ex}$ | B1-C4 | Extrinsic reverse base current |
| $XI_{ex}$ | B-C3 | Extended extrinsic reverse base current |
| $I_{sub\,int}$ | B2-C2 to S | Intrinsic substrate current |
| $I_{sub}$ | B1-C4 to S | Extrinsic substrate current |
| $XI_{sub}$ | B-C3 to S | Extended extrinsic substrate current |
| $I_{Sf}$ | S-C1 | Substrate failure (diode) current |

## Summary of Charges

| Charge | Placement | Description |
|--------|-----------|-------------|
| $Q_{tE}$ | B2-E1 | Base-emitter depletion charge (bulk) |
| $Q_{tE}^S$ | B1-E1 | Base-emitter depletion charge (sidewall) |
| $Q_E$ | B2-E1 | Emitter stored (neutral) charge |
| $Q_{BE}$ | B2-E1 | Base-emitter diffusion charge |
| $Q_{BC}$ | B2-C2 | Base-collector diffusion charge |
| $Q_{tC}$ | B2-C2 | Base-collector depletion charge (intrinsic) |
| $Q_{epi}$ | B2-C2 | Epilayer diffusion charge |
| $Q_{B1B2}$ | B1-B2 | AC current crowding charge |
| $Q_{tex}$ | B1-C4 | Extrinsic BC depletion charge |
| $XQ_{tex}$ | B-C3 | Extended extrinsic BC depletion charge |
| $Q_{ex}$ | B1-C4 | Extrinsic BC diffusion charge |
| $XQ_{ex}$ | B-C3 | Extended extrinsic BC diffusion charge |
| $Q_{tS}$ | S-C1 | Collector-substrate depletion charge |
| $C_{BEO}$ | B-E | EB overlap capacitance (constant) |
| $C_{BCO}$ | B-C | BC overlap capacitance (constant) |
