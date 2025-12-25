# HICUM/L2 3.2.0 -- Parameter & Equation Reference

> BJT full model (SiGe HBT)
> Source: HICUM/L2 v3.2.0 Technical Manual, M. Schroter, 2026

## Model Topology

HICUM/L2 is a physics-based compact model for bipolar junction transistors (BJTs) and heterojunction bipolar transistors (HBTs). The equivalent circuit has five external terminals: base (B), emitter (E), collector (C), substrate (S), and a thermal node. Internal nodes include B\* (perimeter base), B' (internal base), E' (internal emitter), C' (internal collector), S' (internal substrate), and delta-Tj (junction temperature). The internal transistor is defined by the region under the emitter window with effective emitter dimensions. A parasitic substrate transistor (pnp) is formed by elements between B\*, C', and S'. A thermal network (Rth, Cth) models self-heating. Vertical NQS effects are handled by adjunct networks for both the minority charge and the transfer current. Correlated high-frequency noise is modeled by additional adjunct networks.

---

## Parameters

### 3.1 Transfer Current

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `c10` | GICCR constant (related to saturation current by $I_S = c_{10}/Q_{p0}$) | 2e-30 (1e-16) | [0:1] ([0:1]) | 3.76e-32 (1.35e-18) | A^2C (A) | M^2 (M) |
| 2 | `qp0` | Zero-bias hole charge | 2e-14 | (0:1] | 2.78e-14 | C | M |
| 3 | `hf0` | Weight factor for the low current minority charge | 1 | [0:inf) | 1.0 | -- | -- |
| 4 | `hfe` | Emitter minority charge weighting factor in HBTs | 1 | [0:inf] | 1.0 | -- | -- |
| 5 | `hfb` | Base minority charge weighting factor in HBTs | 1 | [0:inf] | 1.0 | -- | -- |
| 6 | `hr0c` | Reverse operation minority charge weighting factor in HBTs | 1 | [0:inf] | 1.0 | -- | -- |
| 7 | `hfc` | Collector minority charge weighting factor in HBTs | 1 | [0:inf] | 1.0 | -- | -- |
| 8 | `hjei0` | B-E depletion charge weighting factor in HBTs | 1 | [0:100] | 1.0 | -- | -- |
| 9 | `ahjei` | Slope factor of $h_{jEi}(V_{BE})$ | 0 | [0:100] | 3.0 | -- | -- |
| 10 | `rhjei` | Smoothing factor for $h_{jEi}(V_{BE})$ at high forward bias | 1 | (0:10) | 2.0 | -- | -- |
| 11 | `hjci` | B-C depletion charge weighting factor in HBTs | 1 | [0:100] | 1.0 | -- | -- |
| 12 | `mcf` | Non-ideality factor (for III-V HBTs) | 1 | (0:10] | 1.0 | -- | -- |

### 3.2 Base Current: Base-Emitter Components

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `ibeis` | Internal B-E saturation current | 1e-18 | [0:1] | 1.16e-20 | A | M |
| 2 | `mbei` | Internal B-E current ideality factor | 1 | (0:10] | 1.0150 | -- | -- |
| 3 | `ireis` | Internal B-E recombination saturation current | 0 | [0:1] | 1.16e-16 | A | M |
| 4 | `mrei` | Internal B-E recombination current ideality factor | 2 | (0:10] | 2.0 | -- | -- |
| 5 | `ibeps` | Peripheral B-E saturation current | 0 | [0:1] | 3.72e-21 | A | M |
| 6 | `mbep` | Peripheral B-E current ideality factor | 1 | (0:10] | 1.0150 | -- | -- |
| 7 | `ireps` | Peripheral B-E recombination saturation current | 0 | [0:1] | 1.0e-30 | A | M |
| 8 | `mrep` | Peripheral B-E recombination current ideality factor | 2 | (0:10] | 2.0 | -- | -- |
| 9 | `tbhrec` | Base current recombination time constant at BC barrier for high forward injection | 0 (=inf) | [0:inf) | 250 | s | -- |

### 3.3 Base Current: Base-Collector Components

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `ibcis` | Internal B-C saturation current | 1e-16 | [0:1] | 1.16e-20 | A | M |
| 2 | `mbci` | Internal B-C current ideality factor | 1 | (0:10] | 1.0150 | -- | -- |
| 3 | `ibcxs` | External B-C saturation current | 0 | [0:1] | 4.39e-20 | A | M |
| 4 | `mbcx` | External B-C current ideality factor | 1 | (0:10] | 1.03 | -- | -- |

### 3.4 Base-Emitter Band-to-Band and Trap-Assisted Tunnelling Current

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `ibetat0` | BE trap-assisted tunnelling (TAT) reference current | 0 | [0:50] | 1.77e-12 | A | M |
| 2 | `vbetat` | BE TAT current voltage parameter | 1.0 | (0:10] | 1.64 | V | -- |
| 3 | `ibets` | BE band-to-band tunnelling (BtBT) saturation current | 0 | [0:50] | 2.035 | A | M |
| 4 | `abet` | Exponent factor for BE BtBT current | 40 | [0:inf) | 24 | -- | -- |
| 5 | `tunode` | Base node connection of BtBT current source (0=internal, 1=perimeter) | 1 | [0/1] | 0 | -- | -- |
| 6 | `ibcts` | BC band-to-band tunnelling (BtBT) saturation current | 1 | [0/1] | 0 | -- | -- |
| 7 | `abct` | Exponent factor for BC BtBT current | 40 | [0:inf) | 24 | -- | -- |

### 3.5 Base-Collector Avalanche and Band-to-Band Tunneling Current

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `favl` | Avalanche current factor | 0 | [0:inf) | 1.186 | 1/V | -- |
| 2 | `qavl` | Exponent factor for avalanche current | 0 | [0:inf) | 11.1e-15 | C | M |
| 3 | `kavl` | Flag/factor for turning strong avalanche on or off | 0 | [0:3] | 0.1 | -- | -- |
| 4 | `hcavl` | Flag/factor for current dependent avalanche model | 0 | [0:10] | 1 | -- | -- |
| 5 | `hvdavl` | Factor for current dependent avalanche (spatially dep. C doping) | 0 | [0:10] | 0.5 | -- | -- |

### 3.6 Series Resistances

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `rbi0` | Zero-bias internal base resistance | 0 | [0:inf) | 71.76 | Ohm | 1/M |
| 2 | `rbx` | External base series resistance | 0 | [0:inf) | 8.83 | Ohm | 1/M |
| 3 | `fgeo` | Factor for geometry dependence of emitter current crowding ($r_{Bi}$) | 0.6557 | [0:inf] | 0.73 | -- | -- |
| 4 | `fdqr0` | Correction factor for modulation by B-E and B-C space charge layer | 0 | [-0.5:100] | 0.2 | -- | -- |
| 5 | `fcrbi` | Ratio of HF shunt to total internal capacitance (lateral NQS effect) | 0 | [0:1] | 0.0 | -- | -- |
| 6 | `fqi` | Ratio of internal to total minority charge | 1.0 | [0:1] | 0.9055 | -- | -- |
| 7 | `re` | Emitter series resistance | 0 | [0:inf) | 12.534 | Ohm | 1/M |
| 8 | `rcx` | External collector series resistance | 0 | [0:inf) | 9.165 | Ohm | 1/M |

### 3.7 Substrate Transistor

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `itss` | Saturation current of substrate transistor transfer current | 0 | [0:1] | 1.0e-16 | A | M |
| 2 | `msf` | Forward ideality factor of substrate transfer current (note: $m_{Sr} = m_{Sf}$) | 1 | (0:10] | 1.05 | -- | -- |
| 3 | `iscs` | Saturation current of C-S diode | 0 | [0:1] | 1e-17 | A | M |
| 4 | `msc` | Ideality factor of C-S diode | 1 | (0:10] | 1.0 | -- | -- |
| 5 | `tsf` | Transit time (forward operation) | 0 | [0:inf) | 1.05 | s | -- |

### 3.8 Intra-Device Substrate Coupling

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `rsu` | Substrate series resistance | 0 | [0:inf) | 0 | Ohm | 1/M |
| 2 | `csu` | Shunt capacitance (caused by substrate permittivity) | 0 | [0:inf) | 0 | F | M |

### 3.9 Depletion Charge and Capacitance Components

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `cjei0` | Internal B-E zero-bias depletion capacitance | 1e-20 | [0:inf) | 8.11e-15 | F | M |
| 2 | `vdei` | Internal B-E built-in potential | 0.9 | (0:10] | 0.95 | V | -- |
| 3 | `zei` | Internal B-E grading coefficient | 0.5 | (0:1) | 0.5 | -- | -- |
| 4 | `ajei` | Ratio of max to zero-bias value of internal B-E capacitance | 2.5 | [0:inf) | 1.8 | -- | -- |
| 5 | `cjep0` | Peripheral B-E zero-bias depletion capacitance | 1e-20 | [0:inf) | 2.07e-15 | F | M |
| 6 | `vdep` | Peripheral B-E built-in potential | 0.9 | (0:10] | 1.05 | V | -- |
| 7 | `zep` | Peripheral B-E grading coefficient | 0.5 | (0:1) | 0.4 | -- | -- |
| 8 | `ajep` | Ratio of max to zero-bias value of peripheral B-E capacitance | 2.5 | [0:inf) | 2.4 | -- | -- |
| 9 | `cjci0` | Internal B-C zero-bias depletion capacitance | 1e-20 | [0:inf) | 1.16e-15 | F | M |
| 10 | `vdci` | Internal B-C built-in potential | 0.7 | (0:10] | 0.8 | V | -- |
| 11 | `zci` | Internal B-C grading coefficient | 0.4 | (0:1) | 0.333 | -- | -- |
| 12 | `ajci` | Ratio of max to zero-bias value of internal B-C capacitance | 2.4 | [0:inf) | 2.0 | -- | -- |
| 13 | `vptci` | Internal B-C punch-through voltage | 100 | (0:100] | 100 | V | -- |
| 14 | `cjcx0` | External B-C zero-bias depletion capacitance | 1e-20 | [0:inf) | 5.4e-15 | F | M |
| 15 | `vdcx` | External B-C built-in potential | 0.7 | (0:10] | 0.700 | V | -- |
| 16 | `zcx` | External B-C grading coefficient | 0.4 | (0:1) | 0.333 | -- | -- |
| 17 | `ajcx` | Ratio of max to zero-bias value of external B-C capacitance | 2.4 | [0:inf) | 2.0 | -- | -- |
| 18 | `vptcx` | External B-C punch-through voltage | 100 | (0:100] | 100 | V | -- |
| 19 | `cjs0` | C-S zero-bias depletion capacitance | 0 | [0:inf) | 3.64e-14 | F | M |
| 20 | `vds` | C-S built-in potential | 0.6 | (0:10] | 0.6 | V | -- |
| 21 | `zs` | C-S grading coefficient | 0.5 | (0:1) | 0.447 | -- | -- |
| 22 | `ajs` | Ratio of max to zero-bias value of (bottom) S-C capacitance | 2.4 | [0:inf) | 2.0 | -- | -- |
| 23 | `vpts` | C-S punch-through voltage | 100 | (0:100] | 100 | V | -- |
| 24 | `cscp0` | Peripheral C-S zero-bias depletion capacitance | 0 | [0:inf) | 3.64e-14 | F | M |
| 25 | `vdsp` | Peripheral C-S built-in potential | 0.6 | (0:10] | 0.6 | V | -- |
| 26 | `zsp` | Peripheral C-S grading coefficient | 0.5 | (0:1) | 0.447 | -- | -- |
| 27 | `vptsp` | Peripheral C-S punch-through voltage | 100 | (0:100] | 100 | V | -- |

### 3.10 Minority Charge Storage Effects

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `t0` | Low-current forward transit time at $V_{BC}=0$ | 0 | [0:inf) | 4.75e-12 | s | -- |
| 2 | `dt0h` | Time constant for base and B-C space charge layer width modulation | 0 | (-inf:inf) | 2.1e-12 | s | -- |
| 3 | `tbvl` | Time constant for modelling carrier jam at low $V_{CE}$ | 0 | (-inf:inf) | 4.0e-12 | s | -- |
| 4 | `tef0` | Neutral emitter storage time | 0 | [0:inf) | 1.8e-12 | s | -- |
| 5 | `gtfe` | Exponent factor for current dependence of neutral emitter storage time | 1 | (0:10] | 1.4 | -- | -- |
| 6 | `thcs` | Saturation time constant at high current densities | 0 | [0:inf) | 30e-12 | s | -- |
| 7 | `ahc` | Smoothing factor for current dependence of base and collector transit time | 0.1 | (0:50] | 0.75 | -- | -- |
| 8 | `fthc` | Partitioning factor for base and collector portion | 0 | [0:1] | 0.6 | -- | -- |
| 9 | `rci0` | Internal collector resistance at low electric field | 150 | (0:inf) | 127.8 | Ohm | 1/M |
| 10 | `vlim` | Voltage separating ohmic and saturation velocity regime | 0.5 | (0:10] | 0.70 | V | -- |
| 11a | `vces` | Internal C-E saturation voltage | 0.1 | [0:1] | 0.1 | V | -- |
| 11b | `vdck` | Internal BC built-in voltage | 0 | [0:1] | 0.8 | V | -- |
| 12 | `avcsm` | Smoothing factor for effective internal collector voltage (hard saturation) | 1.921812 | [0:inf] | 1 | -- | -- |
| 13 | `vpt` | Collector punch-through voltage | 0 (=inf) | (0:inf] | 5 | V | -- |
| 14 | `delck` | Field dependence factor for $I_{CK}$ | 2.0 | (0:10] | 2.0 | -- | -- |
| 15 | `aick` | Smoothing factor for $I_{CK}$ in punch-through | 1e-3 | (0:10] | 1e-3 | -- | -- |
| 16 | `tr` | Storage time for reverse operation | 0 | [0:inf) | 0 | s | -- |
| 17 | `vcbar` | BC barrier voltage | 0 | [0:1] | 0 | V | -- |
| 18 | `icbar` | Current normalization parameter | 0 | [0:1] | 0 | A | M |
| 19 | `acbar` | Smoothing parameter for bias dependence of barrier voltage | 0.01 | (0:10] | 0.1 | -- | -- |

### 3.11 Parasitic Isolation Capacitances

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `cbepar` | Total parasitic BE capacitance (spacer and metal component) | 0.0 | [0:inf) | 0.6e-15 | F | M |
| 2 | `fbepar` | Partitioning factor of parasitic BE cap (1.0 = v2.1 compatible) | 1.0 | [0:1] | 0.5 | -- | -- |
| 3 | `cbcpar` | Total parasitic BC capacitance (trench and metal component) | 0.0 | [0:inf) | 2.97e-15 | F | M |
| 4 | `fbcpar` | Partitioning factor of parasitic BC cap (0.0 = v2.1 compatible) | 0.0 | [0:1] | 0.5 | -- | -- |
| 5 | `ccepar` | Total parasitic CE capacitance (trench and metal component) | 0.0 | [0:inf) | 3e-15 | F | M |

### 3.12 Vertical Non-Quasi-Static Effects

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `alqf` | Factor for additional delay time of minority charge ($\alpha_{Qf}$) | 0.167 | [0:1] | 0.225 | -- | -- |
| 2 | `alit` | Factor for additional delay time of transfer current ($\alpha_{iT}$) | 0.333 | [0:1] | 0.45 | -- | -- |
| 3 | `flnqs` | Flag for turning on (1) or off (0) vertical NQS effects | 0 | [0/1] | 1 | -- | -- |

### 3.13 Noise

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `kf` | Flicker noise coefficient | 0 | [0:inf) | 1.43e-8 | -- | M^(1-AF) |
| 2 | `af` | Flicker noise exponent factor | 2 | (0:10] | 2 | -- | -- |
| 3 | `cfbe` | Flag for flicker noise source location (-1=internal, -2=perimeter) | -1 | [-2/-1] | -2 | -- | -- |
| 4 | `kfre` | Emitter resistance flicker noise coefficient | 0 | [0:inf) | 0 | -- | M^(1-AFRE) |
| 5 | `afre` | Emitter resistance flicker noise exponent factor | 2 | (0:10] | 2 | -- | -- |
| 6 | `flcono` | Flag for turning correlated noise on/off | 0 | [0:1] | 1 | -- | -- |

### 3.14 Lateral Geometry Scaling (at High Current Densities)

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `latb` | Scaling factor for collector minority charge in direction of emitter width $b_E$ | 0 | [0:inf) | 3.765 | -- | -- |
| 2 | `latl` | Scaling factor for collector minority charge in direction of emitter length $l_E$ | 0 | [0:inf) | 0.342 | -- | -- |

### 3.15 Temperature Dependence

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `vgb` | Bandgap voltage $V_{gBeff}$ extrapolated to 0K | 1.17 | (0:10] | 1.17 | V | -- |
| 2 | `f1vg` | Coefficient $K_1$ in T-dependent bandgap equation | -1.02377e-4 | -- | -1.02377e-4 | V/K | -- |
| 3 | `f2vg` | Coefficient $K_2$ in T-dependent bandgap equation | 4.3215e-4 | -- | 4.3215e-4 | V/K | -- |
| 4 | `zetact` | Exponent coefficient in transfer current temperature dependence ($\zeta_{CT}$) | 3.0 | [-10:10] | 3.5 | -- | -- |
| 5 | `vge` | Effective emitter bandgap voltage ($V_{gEeff}$) | VGB | (0:10] | 1.07 | V | -- |
| 6 | `zetabet` | Exponent coefficient in BE junction current temperature dependence ($\zeta_{BET}$) | 3.5 | [-10:10] | 4 | -- | -- |
| 7 | `vgc` | Effective collector bandgap voltage ($V_{gCeff}$) | VGB | (0:10] | 1.14 | V | -- |
| 8 | `vgs` | Effective substrate bandgap voltage ($V_{gSeff}$) | VGB | (0:10] | 1.17 | V | -- |
| 9 | `dvgbe` | Bandgap difference between neutral base and BE SCR (for $h_{jEi0}$ and $h_{f0}$) | 0 | [-10:10] | 0 | V | -- |
| 10 | `zetahjei` | Temperature coefficient for $a_{hjEi}$ ($\zeta_{hjEi}$) | 1 | [-10:10] | 1 | -- | -- |
| 11 | `zetavgbe` | Temperature coefficient for $h_{jEi0}$ ($\zeta_{VgBE}$) | 1 | [-10:10] | 1 | -- | -- |
| 12 | `alt0` | First-order relative temperature coefficient of $\tau_0$ ($\alpha_{\tau0}$) | 0 | -- | 0 | 1/K | -- |
| 13 | `kt0` | Second-order relative temperature coefficient of $\tau_0$ ($k_{\tau0}$) | 0 | -- | 0 | 1/K^2 | -- |
| 14 | `zetaci` | Temperature exponent for $r_{Ci0}$ ($\zeta_{Ci}$) | 0 | [-10:10] | 1.6 | -- | -- |
| 15 | `alvs` | Relative temperature coefficient of saturation drift velocity ($\alpha_{vs}$) | 0 | -- | 1e-3 | 1/K | -- |
| 16a | `alces` | Relative TC of $V_{C'E's}$ ($\alpha_{CEs}$) | 0 | -- | 0.4e-3 | 1/K | -- |
| 16b | `aldck` | Relative TC of $V_{DCk}$ ($\alpha_{DCk}$) | 0 | -- | 0 | 1/K | -- |
| 17 | `zetarbi` | Temperature exponent of internal base resistance ($\zeta_{rBi}$) | 0 | [-10:10] | 0.588 | -- | -- |
| 18 | `zetarbx` | Temperature exponent of external base resistance ($\zeta_{rBx}$) | 0 | [-10:10] | 0.206 | -- | -- |
| 19 | `zetarcx` | Temperature exponent of external collector resistance ($\zeta_{rCx}$) | 0 | [-10:10] | 0.223 | -- | -- |
| 20 | `zetare` | Temperature exponent of emitter resistance ($\zeta_{rE}$) | 0 | [-10:10] | 0 | -- | -- |
| 21 | `zetarth` | Temperature exponent of thermal resistance ($\zeta_{Rth}$) | 0 | [-10:10] | 0 | -- | -- |
| 22 | `alrth` | First-order relative temperature coefficient of $R_{th}$ ($\alpha_{Rth}$) | 0 | [0:1] | 0 | 1/K | -- |
| 23 | `zetacx` | Temperature exponent of mobility in substrate transistor transit time ($\zeta_{Cx}$) | 1.0 | [-10:10] | 2.2 | -- | -- |
| 24 | `alfav` | Relative temperature coefficient for $f_{AVL}$ ($\alpha_{fav}$) | 0 | -- | 8.25e-5 | 1/K | -- |
| 25 | `alqav` | Relative temperature coefficient for $q_{AVL}$ ($\alpha_{qav}$) | 0 | -- | 1.96e-4 | 1/K | -- |

### 3.16 Self-Heating

| # | Parameter | Description | Default | Range | Test | Unit | M-factor |
|---|-----------|-------------|---------|-------|------|------|----------|
| 1 | `rth` | Thermal resistance | 0 | [0:inf) | 0.0 | K/W | 1/M |
| 2 | `cth` | Thermal capacitance | 0 | [0:inf) | 0.0 | Ws/K | M |
| 3 | `flsh` | Flag for self-heating (0=off, 1=main currents, 2=all currents) | 0 | [0/1/2] | 1 | -- | -- |

### 3.17 Circuit Simulator Specific Parameters

| # | Parameter | Description | Default | Unit |
|---|-----------|-------------|---------|------|
| 1 | `tnom` | Temperature at which parameters are specified | 27 | degC |
| 2 | `dt` | Temperature change w.r.t. chip temperature for particular transistor | 0 | degC |
| 3 | `flcomp` | Compatibility flag and model version identifier (integer) | 310 | -- |
| 4 | `type` | Transistor type NPN (+1) or PNP (-1) | 1 | -- |
| 5 | `minr` | Minimum resistor value below which branch nodes are collapsed | simulator value | -- |

---

## Equations

### 2.2 Quasi-Static Transfer Current

#### A. Basic GICCR Formulation

$$
i_T = \frac{c_{10}}{Q_{p,T}} \left[ \exp\!\left(\frac{v_{B'E'}}{V_T}\right) - \exp\!\left(\frac{v_{B'C'}}{V_T}\right) \right]
\tag{2-1}
$$

GICCR constant:

$$
c_{10} = (qA_E)^2 V_T^2 \mu_{nr} n_{ir}^2
\tag{2-2}
$$

Modified hole charge in the GICCR denominator:

$$
Q_{p,T} = Q_{p0} + h_{jEi} Q_{jEi} + h_{jCi} Q_{jCi} + Q_{f,T} + Q_{r,T}
\tag{2-3}
$$

Collector saturation current:

$$
I_S = \frac{c_{10}}{Q_{p0}}
\tag{2-4}
$$

Normalized form of GICCR:

$$
i_T = \frac{I_S}{Q_{p,T} / Q_{p0}} \left[ \exp\!\left(\frac{v_{B'E'}}{V_T}\right) - \exp\!\left(\frac{v_{B'C'}}{V_T}\right) \right]
\tag{2-5}
$$

Forward transfer current component:

$$
i_{Tf} = \frac{c_{10}}{Q_{p,T}} \exp\!\left(\frac{v_{B'E'}}{V_T}\right)
\tag{2-6}
$$

Reverse transfer current component:

$$
i_{Tr} = \frac{c_{10}}{Q_{p,T}} \exp\!\left(\frac{v_{B'C'}}{V_T}\right)
\tag{2-7}
$$

#### D. HBT Extensions -- Weighted Minority Charge

Forward operation weighted minority charge:

$$
Q_{f,T} = Q_{fT0} + h_{fE} \Delta Q_{Ef} + h_{fB} \Delta Q_{Bf} + h_{fC} \Delta Q_{Cf}
\tag{2-8}
$$

$$
Q_{fT0} = h_{f0} \tau_0 \, i_{Tf}
\tag{2-9}
$$

Reverse operation weighted minority charge:

$$
Q_{r,T} = h_{r0} Q_r
\tag{2-10}
$$

BC depletion charge weight factor (bandgap grading):

$$
h_{jCi} = \frac{\mu_{nr} n_{ir}^2}{\mu_{nBCj} n_{iBCj}^2} = \exp\!\left(-\frac{a_G w_{B0}}{V_T}\right)
\tag{2-11}
$$

BE depletion charge weight factor:

$$
h_{jEi} = \frac{\mu_{nr} n_{ir}^2}{\mu_{nBEj} n_{iBEj}^2}
\tag{2-12}
$$

Bias-dependent $h_{jEi}$:

$$
h_{jEi}(v_{B'E'}) = h_{jEi0} \frac{\exp(u) - 1}{u}
\tag{2-13}
$$

with auxiliary variable:

$$
u = a_{hjEi} \left[ 1 - \left(1 - \frac{v_{j,u}}{V_{DEi}}\right)^{z_{Ei}} \right]
\tag{2-14}
$$

Smoothing of $v_{j,u}$ near $V_{DEi}$:

$$
v_{j,u} = V_{DEi} - r_{hjEi} V_T \frac{x_u + \sqrt{x_u^2 + a_{fi}}}{2}, \quad x_u = \frac{V_{DEi} - v_{B'E'}}{r_{hjEi} V_T}
\tag{2-17}
$$

Smoothing constant: $a_{fi} = 1.921812$.

Bernoulli function implementation:

$$
B(u) = \begin{cases}
\frac{\exp(u) - 1}{u} & \text{for } u \geq u_{\min} \\
1 + \frac{u}{2} & \text{for } u < u_{\min}
\end{cases}
\tag{2-18}
$$

with $u_{\min} = 0.001$.

Emitter and collector weight factors:

$$
h_{fE} = \frac{\mu_{nr} n_{ir}^2}{\mu_{nE} n_{iE}^2}, \quad h_{fC} = \frac{\mu_{nr} n_{ir}^2}{\mu_{nC} n_{iC}^2}
\tag{2-19}
$$

#### E. Non-ideality for III-V HBTs

$$
i_{Tf} = \frac{c_{10}}{Q_{p,T}} \exp\!\left(\frac{v_{B'E'}}{m_{Cf} V_T}\right)
\tag{2-20}
$$

#### F. Final Transfer Current

$$
i_T = i_{Tf} - i_{Tr}
\tag{2-21}
$$

Low-current hole charge (depletion components only):

$$
Q_{pT,j} = Q_{p0} + h_{jEi} Q_{jEi} + h_{jCi} Q_{jCi}
\tag{2-22}
$$

Smoothing to prevent negative $Q_{pT,j}$ (base punch-through protection), with $Q_{B,rt} = 0.05 Q_{p0}$:

$$
Q_{pT,\text{low}} = Q_{B,rt} \left(1 + \frac{x + \sqrt{x^2 + a}}{2}\right), \quad x = \frac{Q_{pT,j}}{Q_{B,rt}} - 1
\tag{2-23}
$$

with $a = 1.921812$.

Explicit quadratic solution for $Q_{p,T}$ at low current densities:

$$
Q_{p,T} = \frac{Q_{pT,\text{low}}}{2} + \sqrt{\left(\frac{Q_{pT,\text{low}}}{2}\right)^2 + h_{f0} \tau_0 c_{10} \exp\!\left(\frac{v_{B'E'}}{m_{cf} V_T}\right) + \tau_r c_{10} \exp\!\left(\frac{v_{B'C'}}{V_T}\right)}
\tag{2-24}
$$

Initial guess for Newton iteration:

$$
Q_{p,T,\text{initial}} = Q_{pT,\text{low}} + h_{f0} \tau_0 i_{Tf} + \tau_r i_{Tr}
\tag{2-25}
$$

### 2.3 Minority Charge, Transit Times, and Diffusion Capacitances

Transit time definition:

$$
\tau = \frac{dQ}{dI}
\tag{2-26}
$$

Forward minority charge from transit time integration:

$$
Q_f = \int_0^{i_{Tf}} \tau_f \, di
\tag{2-27}
$$

Total forward transit time:

$$
\tau_f(v_{C'E'}, i_{Tf}) = \tau_{f0}(v_{B'C'}) + \Delta\tau_f(v_{C'E'}, i_{Tf})
\tag{2-28}
$$

#### Effective Collector Voltage (versions <= 3.0.0)

$$
v_{ceff} = V_T \left(1 + \frac{u + \sqrt{u^2 + 1.921812}}{2}\right), \quad u = \frac{v_c - V_T}{V_T}
\tag{2-29}
$$

$$
v_c = v_{C'E'} - V_{C'E's}
\tag{2-30}
$$

#### Effective Collector Voltage (versions >= 3.1.0, $V_{DCk}$ option)

$$
v_c = V_{DCk} - v_{B'C'}
\tag{2-31}
$$

$$
v_{ceff} = V_{T0} \frac{u + \sqrt{u^2 + a_{vceff}}}{2}, \quad u = \frac{v_c}{V_{T0}}
\tag{2-33}
$$

#### A. Low-Current Transit Time

$$
\tau_{f0}(v_{B'C'}) = \tau_0 + \Delta\tau_{0h}(c - 1) + \tau_{Bvl}\left(\frac{1}{c} - 1\right)
\tag{2-34}
$$

where $1/c = C_{jCi,t}(V_{B'C'})/C_{jCi0}$. $C_{jCi,t}$ is evaluated with the same parameters as $C_{jCi}$ but with infinite punch-through voltage.

Low-current forward minority charge:

$$
Q_{f0} = \tau_{f0} \, i_{Tf}
\tag{2-35}
$$

#### B. Medium and High Current Densities

Critical current:

$$
I_{CK} = \frac{v_{ceff}}{r_{Ci0}} \frac{1}{\left[1 + \left(\frac{v_{ceff}}{V_{lim}}\right)^{\delta_{ck}}\right]^{1/\delta_{ck}}} \left(1 + \frac{x + \sqrt{x^2 + a_{ick}}}{2}\right)
\tag{2-36}
$$

with $x = (v_{ceff} - V_{lim})/V_{PT}$ and $a_{ick} = 10^{-3}$.

Internal collector resistance (physics-based):

$$
r_{Ci0} = \frac{w_C}{q \mu_{nC0} N_{Ci} A_E f_{cs}}
\tag{2-37}
$$

Velocity-field boundary voltage:

$$
V_{lim} = \frac{v_{sn}}{\mu_{nC0}} w_C
\tag{2-38}
$$

Collector punch-through voltage:

$$
V_{PT} = \frac{qN_{Ci}}{2\varepsilon} w_C^2
\tag{2-39}
$$

Emitter transit time increase at high currents:

$$
\Delta\tau_{Ef} = \tau_{Ef0} \left(\frac{i_{Tf}}{I_{CK}}\right)^{g_{\tau E}}
\tag{2-40}
$$

Emitter storage time:

$$
\tau_{Ef0} = \frac{\tau_{pE0}}{\beta_0} \approx \frac{1}{\beta_0}\left(\frac{w_E}{v_{Ke}} + \frac{w_E^2}{2\mu_{pE} V_T}\right)
\tag{2-41}
$$

Emitter charge at high currents:

$$
\Delta Q_{Ef} = \Delta\tau_{Ef} \frac{i_{Tf}}{1 + g_{\tau E}}
\tag{2-42}
$$

Collector hole charge (high currents):

$$
\Delta Q_{Cf} = Q_{Cf} = Q_{pC} = \tau_{pCs} \, i_{Tf} \, w^2
\tag{2-43}
$$

Collector saturation storage time:

$$
\tau_{pCs} = \frac{w_C^2}{4\mu_{nC0} V_T}
\tag{2-44}
$$

Normalized injection width (smoothed):

$$
w = \frac{w_i}{w_C} = \frac{i + \sqrt{i^2 + a_{hc}}}{1 + \sqrt{1 + a_{hc}}}
\tag{2-45}
$$

$$
i = 1 - \frac{I_{CK}}{i_{Tf}}
\tag{2-46}
$$

Collector storage time:

$$
\Delta\tau_{Cf} = \tau_{Cf} = \tau_{pC} = \frac{dQ_{pC}}{dI_{Tf}} = \tau_{pCs} w^2 \left(1 + \frac{I_{CK}}{i_{Tf}} \frac{2}{\sqrt{i^2 + a_{hc}}}\right)
\tag{2-47}
$$

Additional base charge at high currents:

$$
\Delta Q_{Bf} = \tau_{Bfvs} \, i_{Tf} \, w^2
\tag{2-48}
$$

Base saturation storage time:

$$
\tau_{Bfvs} = \frac{w_{Bm} w_C}{2 G_{\zeta i} \mu_{nC0} V_T}
\tag{2-49}
$$

Additional base transit time:

$$
\Delta\tau_{Bf} = \frac{d\Delta Q_{Bf}}{dI_{Tf}} = \tau_{Bfvs} w^2 \left(1 + \frac{I_{CK}}{i_{Tf}} \frac{2}{\sqrt{i^2 + a_{hc}}}\right)
\tag{2-50}
$$

Total saturation time constant (model parameter):

$$
\tau_{hcs} = \tau_{pCs} + \tau_{Bfvs} = \frac{w_C^2}{4\mu_{nC0} V_T} + \frac{w_{Bm} w_C}{2 G_{\zeta i} \mu_{nC0} V_T}
\tag{2-51}
$$

Partitioning constant:

$$
f_{\tau hc} = \frac{\tau_{pCs}}{\tau_{hcs}} = \frac{w_C}{w_C + 2w_{Bm}}
\tag{2-52}
$$

Lumped base+collector high-current charge (1D, $f_{\tau hc}=0$):

$$
\Delta Q_{fh} = \Delta Q_{Bf} + Q_{Cf} = \tau_{hcs} \, i_{Tf} \, w^2
\tag{2-53}
$$

Lumped base+collector high-current transit time:

$$
\Delta\tau_{fh} = \Delta\tau_{Bf} + \tau_{Cf} = \tau_{hcs} w^2 \left(1 + \frac{I_{CK}}{i_{Tf}} \frac{2}{\sqrt{i^2 + a_{hc}}}\right)
\tag{2-54}
$$

Total minority charge:

$$
Q_f = Q_{f0} + \Delta Q_{Ef} + \Delta Q_{fh}
\tag{2-55}
$$

Total forward transit time:

$$
\tau_f = \tau_{f0} + \Delta\tau_{Ef} + \Delta\tau_{fh}
\tag{2-56}
$$

#### BC Barrier Effect (SiGe HBTs)

Barrier voltage:

$$
\Delta V_{cB} = V_{cBar} \exp\!\left(-\frac{2}{i_{Bar} + \sqrt{i_{Bar}^2 + a_{cBar}}}\right)
\tag{2-57}
$$

$$
i_{Bar} = \frac{i_{Tf} - I_{CK}}{i_{cBar}}
\tag{2-58}
$$

With barrier, the charge and transit time become:

$$
Q_f = Q_{f0} + \Delta Q_{Ef} + \Delta Q_{fh,c} + \Delta Q_{Bf,b}
\tag{2-59}
$$

$$
\tau_f = \tau_{f0} + \Delta\tau_{Ef} + \Delta\tau_{fh,c} + \Delta\tau_{Bf,b}
\tag{2-60}
$$

Barrier-related base charge:

$$
\Delta Q_{Bf,b} = \tau_{Bfvs} \, i_{Tf} \left[\exp\!\left(\frac{\Delta V_{cB}}{V_T}\right) - 1\right]
\tag{2-61}
$$

with $\tau_{Bfvs} = (1 - f_{\tau hc})\tau_{hCs}$.

Kirk-effect collector charge delayed by barrier:

$$
\Delta Q_{fh,c} = \tau_{hCs} \, i_{Tf} \, w^2 \exp\!\left(\frac{\Delta V_{cB} - V_{cBar}}{V_T}\right) = \Delta Q_{fh} \exp\!\left(\frac{\Delta V_{cB} - V_{cBar}}{V_T}\right)
\tag{2-62}
$$

Total additional base charge:

$$
\Delta Q_{Bf} = \Delta Q_{Bf,b} + \Delta Q_{Bf,c}
\tag{2-63}
$$

Collector component:

$$
\Delta Q_{Cf,c} = f_{\tau hc} \Delta Q_{fh,c}
\tag{2-64}
$$

Base component from collector splitting:

$$
\Delta Q_{Bf,c} = (1 - f_{\tau hc}) \Delta Q_{fh,c}
\tag{2-65}
$$

Sum invariance:

$$
\Delta Q_{fh,c} + \Delta Q_{Bf,b} = \Delta Q_{Cf,c} + \Delta Q_{Bf}
\tag{2-66}
$$

#### Reverse Minority Charge

$$
Q_r = \tau_r \, i_{Tr}
\tag{2-67}
$$

### 2.4 Depletion Charges and Capacitances

Classical depletion charge:

$$
Q_j = \int_0^v C_j \, dv' = \frac{C_{j0} V_D}{1 - z} \left[1 - \left(1 - \frac{v}{V_D}\right)^{1-z}\right]
\tag{2-68}
$$

Classical depletion capacitance:

$$
C_j = \frac{C_{j0}}{\left(1 - \frac{v}{V_D}\right)^z}
\tag{2-69}
$$

#### 2.4.1 Base-Emitter Junction

Internal BE depletion charge:

$$
Q_{jEi} = \frac{C_{jEi0} V_{DEi}}{1 - z_{Ei}} \left[1 - \left(1 - \frac{v_j}{V_{DEi}}\right)^{1-z_{Ei}}\right] + a_{jEi} C_{jEi0} (v_{B'E'} - v_j)
\tag{2-70}
$$

Smoothed auxiliary junction voltage (hyperbolic smoothing):

$$
v_j = V_f - V_T \frac{x + \sqrt{x^2 + a_{fj}}}{2} < V_f
\tag{2-71}
$$

$$
x = \frac{V_f - v_{B'E'}}{V_T}
\tag{2-72}
$$

Forward-bias intercept voltage:

$$
V_f = V_{DEi} \left[1 - a_{jEi}^{-1/z_{Ei}}\right]
\tag{2-73}
$$

Internal BE depletion capacitance (derivative of charge):

$$
C_{jEi} = \frac{C_{jEi0}}{(1 - v_j/V_{DEi})^{z_{Ei}}} \cdot \frac{dv_j}{dv_{B'E'}} + a_{jEi} C_{jEi0} \left(1 - \frac{dv_j}{dv_{B'E'}}\right)
\tag{2-74}
$$

Derivative of $v_j$:

$$
\frac{dv_j}{dv_{B'E'}} = \frac{x + \sqrt{x^2 + a_{fj}}}{2\sqrt{x^2 + a_{fj}}}
\tag{2-75}
$$

Smoothing constant:

$$
a_{fj} = 4\ln^2(2) = 1.921812
\tag{2-76}
$$

#### 2.4.2 Internal Base-Collector Junction

Effective BC punch-through voltage:

$$
V_{jPCi} = V_{PTCi} - V_{DCi} = \frac{qN_{Ci}}{2\varepsilon} w_{Ci}^2 - V_{DCi}
\tag{2-77}
$$

Forward-bias intercept for BC:

$$
V_{fCi} = V_{DCi}\left[1 - a_{jCi}^{-1/z_{Ci}}\right]
\tag{2-78}
$$

Transition voltage (medium to large reverse bias):

$$
V_r = 0.1 V_{jPCi} + 4V_T
\tag{2-79}
$$

Total BC depletion capacitance (three components):

$$
C_{jCi} = C_{jCi,cl} + C_{jCi,PT} + C_{jCi,fb}
\tag{2-80}
$$

Medium bias (classical) component:

$$
C_{jCi,cl} = \frac{C_{jCi0}}{(1 - v_{j,m}/V_{DCi})^{z_{Ci}}} \cdot \frac{e_{j,r}}{1 + e_{j,r}} \cdot \frac{e_{j,m}}{1 + e_{j,m}}
\tag{2-81}
$$

Punch-through smoothing voltage:

$$
v_{j,r} = V_{fCi} - V_T \ln[1 + e_{j,r}], \quad e_{j,r} = \exp\!\left(\frac{V_{fCi} - v_{B'C'}}{V_T}\right)
\tag{2-82}
$$

Forward-bias maximum capacitance:

$$
C_{jCi,fb} = a_{jCi} C_{jCi0} \frac{1}{1 + e_{j,r}}
\tag{2-83}
$$

Punch-through component:

$$
C_{jCi,PT} = \frac{C_{jCi0,r}}{(1 - v_{j,r}/V_{DCi})^{z_{Ci,r}}} \cdot \frac{1}{1 + e_{j,m}}
\tag{2-84}
$$

Large-reverse-bias smoothing voltage:

$$
v_{j,m} = -V_{jPCi} + V_r \ln(1 + e_{j,m}) - \exp\!\left(-\frac{V_{jPCi} + V_{fCi}}{V_r}\right)
\tag{2-85a}
$$

$$
e_{j,m} = \exp\!\left(\frac{V_{jPCi} + v_{j,r}}{V_r}\right)
\tag{2-85b}
$$

BC depletion charge:

$$
Q_{jCi} = Q_{jCi,m} + Q_{jCi,r} - Q_{jCi,c} + a_{jCi} C_{jCi0} (v_{B'C'} - v_{j,r})
\tag{2-86}
$$

Medium-bias charge:

$$
Q_{jCi,m} = \frac{C_{jCi0} V_{DCi}}{1 - z_{Ci}} \left[1 - \left(1 - \frac{v_{j,m}}{V_{DCi}}\right)^{1-z_{Ci}}\right]
\tag{2-87}
$$

Large-reverse-bias charge:

$$
Q_{jCi,r} = \frac{C_{jCi0,r} V_{DCi}}{1 - z_{Ci,r}} \left[1 - \left(1 - \frac{v_{j,r}}{V_{DCi}}\right)^{1-z_{Ci,r}}\right]
\tag{2-88}
$$

Correction charge:

$$
Q_{jCi,c} = \frac{C_{jCi0,r} V_{DCi}}{1 - z_{Ci,r}} \left[1 - \left(1 - \frac{v_{j,m}}{V_{DCi}}\right)^{1-z_{Ci,r}}\right]
\tag{2-89}
$$

Punch-through zero-bias capacitance (internal):

$$
C_{jCi0,r} = C_{jCi0} \cdot \left(\frac{V_{DCi}}{V_{PTCi}}\right)^{z_{Ci} - z_{Ci,r}}
\tag{2-90}
$$

with $z_{Ci,r} = z_{Ci}/4$ (internally set).

#### 2.4.3 External Base-Collector Junction

BC capacitance partitioning factor:

$$
f_{BCpar} = \frac{C_{BCx2}}{C_{BCx}}
\tag{2-91}
$$

External BC capacitance split:

$$
C_{BCx} = C_{BCx1} + C_{BCx2} = (1 - f_{BCpar}) C_{BCx} + f_{BCpar} C_{BCx}
\tag{2-92}
$$

External BC depletion charge/capacitance uses the same formulation as the internal BC junction with parameters $C_{jCx0}$, $V_{DCx}$, $z_{Cx}$, $a_{jCx}$, and $V_{PTCx}$.

#### 2.4.4 Collector-Substrate Junction

Uses the same formulation as external BC with parameters $C_{jS0}$, $V_{DS}$, $z_S$, $a_{jS}$, $V_{PTS}$ for the bottom component and $C_{SCp0}$, $V_{DSp}$, $z_{Sp}$, $a_{jS}$, $V_{PTSp}$ for the perimeter component.

### 2.5 Static Base Current Components

#### 2.5.1 Internal BE Junction Current

$$
i_{jBEi} = I_{BEiS}\left[\exp\!\left(\frac{v_{B'E'}}{m_{BEi} V_T}\right) - 1\right] + I_{REiS}\left[\exp\!\left(\frac{v_{B'E'}}{m_{REi} V_T}\right) - 1\right]
\tag{2-93}
$$

#### 2.5.1 Peripheral BE Junction Current

$$
i_{jBEp} = I_{BEpS}\left[\exp\!\left(\frac{v_{B^*E'}}{m_{BEp} V_T}\right) - 1\right] + I_{REpS}\left[\exp\!\left(\frac{v_{B^*E'}}{m_{REp} V_T}\right) - 1\right]
\tag{2-94}
$$

#### 2.5.2 BE Band-to-Band Tunneling Current

Tunneling current density (physics):

$$
J_{BEt} = \frac{\sqrt{2m^*/E_g} \, q(-V)}{h^2} E_{BEj} \exp\!\left(-\frac{8\pi\sqrt{2m^* E_g} E_g}{3qhE_{BEj}}\right)
\tag{2-95}
$$

Electric field at junction:

$$
E_{BEj} = 2\frac{V_{DE} - V}{w_{BE}}
\tag{2-96}
$$

SCR width:

$$
w_{BE} = w_{BE0} (1 - V/V_{DE})^{z_E}
\tag{2-97}
$$

Zero-bias SCR width:

$$
w_{BE0} = \begin{cases}
\varepsilon_{Si} A_{E0} / C_{jEi0} & \text{bottom junction} \\
\varepsilon_{Si} P_{E0} \cdot 0.8(\pi/2)x_{je} / C_{jEp0} & \text{perimeter junction}
\end{cases}
\tag{2-98}
$$

Final BtB tunneling current (numerically stable form using normalized capacitance $C_e = C_{jE}(v)/C_{jE0}$):

$$
i_{BEt} = I_{BEtS}(-V_e) C_e^{1-1/z_E} \exp\!\left[-a_{BEt} C_e^{1/z_E - 1}\right]
\tag{2-101}
$$

Saturation current:

$$
I_{BEtS} = 2\frac{\sqrt{2m^*/E_g} \, q \, V_{DE}^3}{h^2 \varepsilon_{Si}} C_{jE0}
\tag{2-102}
$$

Exponent coefficient:

$$
a_{BEt} = \frac{8\pi\sqrt{2m^* E_g} E_g}{3qh} \cdot \frac{w_{BE0}}{2V_{DE}}
\tag{2-103}
$$

#### 2.5.3 Trap-Assisted Tunneling Current

$$
i_{BEtat} = I_{TAT0}(T) \left[\exp\!\left(\frac{v_{B'E'}}{V_{TAT}}\right) - 1\right]
\tag{2-104}
$$

Total tunneling current:

$$
I_{BEti} = I_{BEt} + I_{BEtat}, \quad I_{BEtp} = I_{BEt}
\tag{2-105}
$$

#### 2.5.4 Internal BC Junction Current

$$
i_{jBCi} = I_{BCiS}\left[\exp\!\left(\frac{v_{B'C'}}{m_{BCi} V_T}\right) - 1\right]
\tag{2-106}
$$

#### 2.5.4 External BC Junction Current

$$
i_{jBCx} = I_{BCxS}\left[\exp\!\left(\frac{v_{B^*C'}}{m_{BCx} V_T}\right) - 1\right]
\tag{2-107}
$$

#### 2.5.5 BC Barrier Recombination Current

$$
i_{Bhrec} = \frac{\Delta Q_{Bf}}{\tau_{Bhrec}}
\tag{2-108}
$$

#### 2.5.6 Impact Ionization (Avalanche)

$$
i_{AVL} = i_{Tf}(M - 1) = i_{Tf} \frac{g_{AVL}}{1 - k_{AVL} g_{AVL}}
\tag{2-110}
$$

Basic avalanche generation factor:

$$
g_{AVL} = f_{AVL}(V_{DCi} - v_{B'C'}) \exp\!\left(-\frac{q_{AVL}}{C_{jCi}(V_{DCi} - v_{B'C'})}\right)
\tag{2-111}
$$

Physics-based model parameters:

$$
f_{AVL} = 2a_n/b_n
\tag{2-112}
$$

$$
q_{AVL} = b_n \varepsilon A_E / 2
\tag{2-113}
$$

Denominator smoothing (prevents division by zero):

$$
d = \frac{(1 - k_{AVL} g_{AVL}) + \sqrt{(1 - k_{AVL} g_{AVL})^2 + 10^{-4}}}{2}
\tag{2-114}
$$

Current-dependent avalanche (versions >= 2.34):

$$
g_{AVL} = f_{AVL}(V_{DCi} - v_{B'C'}) \exp\!\left(-\frac{q_{AVL}}{C_{jCi}(V_{DCi} - v_{B'C'})f_{avi}}\right)
\tag{2-115}
$$

$$
f_{avi} = \sqrt{s_{mavl} \ln\!\left[\exp\!\left(\frac{c_{mavl} C_{jCi}}{s_{mavl} C_{jCi0}}\right) - 2 + 2\cosh\!\left(\frac{1 - I_{Tf}/I_{lim,avl}}{s_{mavl}}\right)\right]}
\tag{2-116}
$$

with fixed smoothing parameters $s_{mavl} = 0.1$, $c_{mavl} = 1$.

$$
I_{lim,avl} = h_{CAVL} I_{lim} + h_{VDAVL} I_{Tf}
\tag{2-117}
$$

with $I_{lim} = V_{lim}/r_{Ci0}$.

#### 2.5.7 BC Band-to-Band Tunneling Current

$$
i_{BCt} = I_{BCtS}(-V_c) C_c^{1-1/z_{Ci}} \exp\!\left[-a_{BCt} C_c^{1/z_{Ci}-1}\right]
\tag{2-118}
$$

with $C_c = C_{jCi}(v_{B'C'})/C_{jCi0}$ and $V_c = 1 - C_c^{-1/z_{Ci}}$.

### 2.6 Internal Base Resistance

$$
r_{Bi} = r_i \psi(\eta)
\tag{2-124}
$$

Conductivity modulation:

$$
r_i = r_{Bi0} \frac{Q_0}{Q_0 + \Delta Q_p}
\tag{2-125}
$$

$$
\Delta Q_p = Q_{jEi} + Q_{jCi} + Q_f + Q_r \approx Q_{jEi} + Q_{jCi} + Q_f
\tag{2-126}
$$

$$
Q_0 = (1 + f_{dQr0}) Q_{p0}
\tag{2-127}
$$

Smoothed conductivity modulation (with $q_r = 1 + \Delta Q_p / Q_0$):

$$
r_i = r_{Bi0} \frac{1}{f(q_r)}, \quad f(q_r) = \frac{q_r + \sqrt{q_r^2 + a_{qr}}}{2}, \quad a_{qr} = 0.01
\tag{2-128, 2-129}
$$

Zero-bias internal base resistance:

$$
r_{Bi0} = r_{SBi0} \frac{b_E}{l_E n_E} g_i
\tag{2-130}
$$

Geometry function:

$$
g_i = \frac{1}{12} - \left(\frac{1}{12} - \frac{1}{28.6}\right)\frac{b_E}{l_E}
\tag{2-131}
$$

Emitter current crowding function:

$$
\psi(\eta) = \frac{\ln(1 + \eta)}{\eta}
\tag{2-132}
$$

Current crowding factor:

$$
\eta = f_{geo} \frac{r_i \, i_{jBEi}}{V_T}
\tag{2-133}
$$

Final internal base resistance:

$$
r_{Bi} = r_i \cdot \frac{\ln(1 + \eta)}{\eta}
\tag{2-134}
$$

Modified $r_{Bi}^*$ accounting for peripheral charge (transient):

$$
r_{Bi}^* = r_{Bi} \frac{\Delta Q_i}{\Delta Q_i + Q_{fp}} = r_{Bi} \frac{Q_{jEi} + f_{Qi} Q_f}{Q_{jEi} + Q_f}
\tag{2-135, 2-138}
$$

$$
Q_{fi} = f_{Qi} Q_f, \quad Q_{fp} = (1 - f_{Qi}) Q_f
\tag{2-137}
$$

Small-signal modification:

$$
r_{Bi}^* = r_{Bi} \frac{C_{jEi} + f_{Qi} C_{dE}}{C_{jEi} + C_{dE}}
\tag{2-141}
$$

### 2.7 Parasitic Capacitances

Total parasitic BE capacitance:

$$
C_{BEpar} = C_{BEiso} + C_{BE,metal}
\tag{2-142}
$$

Partitioning factor:

$$
f_{BEpar} = \frac{C_{BEpar,2}}{C_{BEpar}} = \frac{C_{BEiso,2} + C_{BE,metal}}{C_{BEiso} + C_{BE,metal}}
\tag{2-143}
$$

### 2.9 Non-Quasi-Static Effects

#### 2.9.1 Vertical NQS Effects

Delay times related to transit time:

$$
\tau_2 = \alpha_{Qf} \tau_f, \quad \tau_m = \alpha_{iT} \tau_f
\tag{2-146}
$$

#### 2.9.2 Lateral NQS Effect

Shunt capacitance for dynamic emitter current crowding:

$$
C_{rBi} = f_{CrBi} C_i
\tag{2-147}
$$

Total capacitance at internal base node:

$$
C_i = C_{jEi} + C_{jCi} + C_{dE} + C_{dC}
\tag{2-148}
$$

Simplified diffusion capacitances for $C_{rBi}$ calculation:

$$
C_{dE} = \frac{i_{Tf}}{V_T} \tau_{f0}, \quad C_{dC} = \frac{i_{Tr}}{V_T} \tau_r
\tag{2-149}
$$

Charge on $C_{rBi}$:

$$
Q_{rBi} = C_{rBi} V_{B^*B'}
\tag{2-150}
$$

### 2.10 Substrate Network

Parameters: $r_{Su}$, $C_{Su}$ (model parameters). Applied to bottom CS capacitance $C_{jS}$ only (from v2.34).

### 2.11 Parasitic Substrate Transistor

Transfer current:

$$
i_{TS} = I_{TSf} - I_{TSr} = I_{TSS}\left[\exp\!\left(\frac{v_{B^*C'}}{m_{Sf} V_T}\right) - \exp\!\left(\frac{v_{S'C'}}{m_{Sr} V_T}\right)\right]
\tag{2-151}
$$

with $m_{Sr} = m_{Sf}$.

SC junction diode current:

$$
i_{jSC} = I_{SCS}\left[\exp\!\left(\frac{v_{S'C'}}{m_{SC} V_T}\right) - 1\right]
\tag{2-152}
$$

Substrate diffusion charge:

$$
Q_{dS} = \tau_{Sf} \, i_{TSf}
\tag{2-153}
$$

### 2.12 Noise Model

#### 2.12.1 Thermal Noise

$$
I_{r,n} = \sqrt{\frac{4 k_B T \Delta f}{r}}
\tag{2-154}
$$

where $r \in \{r_E, r_{Cx}, r_{Bx}, r_{Bi}\}$.

#### 2.12.1 Shot Noise

Transfer current:

$$
I_{T,n} = \sqrt{2 q I_T \Delta f}
\tag{2-155}
$$

Avalanche current:

$$
I_{AVL,n} = \sqrt{2 q M I_{AVL} \Delta f}
\tag{2-156}
$$

Junction currents ($X \in \{jBEi, jBCi, jBEp, jBCx, jSC, BEt, BCt\}$):

$$
I_{X,n} = \sqrt{2 q I_X \Delta f}
\tag{2-157}
$$

#### 2.12.2 Flicker Noise

BE flicker noise:

$$
I_{BEx,F} = \sqrt{k_F (I_{jBEi} + I_{jBEp})^{a_F} \frac{\Delta f}{f}}
\tag{2-158}
$$

Emitter resistance flicker noise (added to thermal):

$$
I_{rE,n} = \sqrt{k_{FrE}\left(\frac{v_{E'E}}{r_E}\right)^{a_{FrE}} \frac{\Delta f}{f} + \frac{4k_B T \Delta f}{r_E}}
\tag{2-159}
$$

#### 2.12.3 Correlated Noise

Cross-spectral density between base and collector noise:

$$
S_{i_{nb} i_{nc}} = 2q j\omega \alpha_{iT} \tau_{Bf} I_T
\tag{2-160}
$$

Collector noise spectral density:

$$
S_{i_{nc}} = 2q I_T
\tag{2-161}
$$

Base current noise spectral density (with correlation):

$$
S_{i_{nb}} = 2q I_{jBEi} \left[1 + 2\alpha_{qf} B_f (\omega \tau_{Bf})^2\right]
\tag{2-162}
$$

Condition for enabling noise correlation: $\alpha_{qf} > \alpha_{iT}^2 / 2$.

### 2.13 Temperature Dependence

#### 2.13.1 Bandgap Voltage

$$
V_g(T) = V_g(0) + K_1 T \ln(T) + K_2 T
\tag{2-163}
$$

| Parameter | Value (original) | Value (improved) |
|-----------|-----------------|-----------------|
| $K_1$ [V/K] | -8.459e-5 | -1.02377e-4 |
| $K_2$ [V/K] | 3.042e-4 | 4.3215e-4 |
| $V_g(0)$ [V] | 1.1774 | 1.170 |

Reformulated in terms of reference temperature $T_0$:

$$
V_g(T) = V_g(T_0) + k_1 \frac{T}{T_0}\ln\!\left(\frac{T}{T_0}\right) + k_2\left(\frac{T}{T_0} - 1\right)
\tag{2-165}
$$

$$
k_1 = K_1 T_0, \quad k_2 = K_2 T_0 + k_1 \ln(T_0)
\tag{2-166}
$$

$$
V_g(T_0) = k_2 + V_g(0)
\tag{2-167}
$$

Effective intrinsic carrier density:

$$
n_{ie}^2(T) = n_{ie}^2(T_0) \left(\frac{T}{T_0}\right)^{m_g} \exp\!\left[\frac{V_{geff}(0)}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-168}
$$

$$
m_g = 3 - \frac{k_1}{V_{T0}} = 3 - \frac{qK_1}{k_B}
\tag{2-169}
$$

For Si: $m_g = 4.188$.

#### 2.13.2 Transfer Current

$$
c_{10}(T) = c_{10}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{CT}} \exp\!\left[\frac{V_{gBeff}(0)}{V_T(T)}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-170}
$$

$$
\zeta_{CT} = m_g + 1 - \zeta_{\mu mB}
\tag{2-171}
$$

Default: $\zeta_{CT} = 3$.

#### 2.13.3 Zero-Bias Hole Charge

$$
Q_{p0}(T) = Q_{p0}(T_0) \left[2 - \left(\frac{V_{DEi}(T)}{V_{DEi}(T_0)}\right)^{z_{Ei}}\right]
\tag{2-172}
$$

#### 2.13.4 Weight Factors

General weight factor temperature dependence:

$$
h(T) = h(T_0) \exp\!\left[\frac{V_{g,h}}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-173}
$$

| Weight factor | $V_{g,h}$ |
|---------------|-----------|
| $h_{f0}$ | $\Delta V_{gBE}$ |
| $h_{fE}$ | $V_{gB} - V_{gE}$ |
| $h_{fC}$ | $V_{gB} - V_{gC}$ |

$h_{jEi0}$ temperature dependence:

$$
h_{jEi0}(T) = h_{jEi0}(T_0) \exp\!\left[\frac{\Delta V_{gBE}}{V_T}\left(\left(\frac{T}{T_0}\right)^{\zeta_{VgBE}} - 1\right)\right]
\tag{2-174}
$$

$a_{hjEi}$ temperature dependence:

$$
a_{hjEi}(T) = a_{hjEi}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{hjEi}}
\tag{2-175}
$$

#### 2.13.5 Base (Junction) Current Components

Internal BE saturation current:

$$
I_{BEiS}(T) = I_{BEiS}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{BET}} \exp\!\left[\frac{V_{gEeff}(0)}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-176}
$$

Generic saturation current formulation:

$$
I_{jS}(T) = I_{jS}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_T} \exp\!\left[\frac{V_{geff}(0)}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-179}
$$

Recombination saturation current:

$$
I_{jRS}(T) = I_{jRS}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_T/m_{jR}} \exp\!\left[\frac{V_{geff}(0)}{m_{jR} V_T}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-181}
$$

Collector mobility temperature dependence:

$$
\mu_{Ci}(T) = \mu_{Ci}(T_0) \left(\frac{T}{T_0}\right)^{-\zeta_{Ci}}
\tag{2-182}
$$

Derived temperature exponents:

$$
\zeta_{BCiT} = m_g + 1 - \zeta_{Ci}
\tag{2-183}
$$

$$
\zeta_{BCxT} = m_g + 1 - \zeta_{Cx}
\tag{2-184}
$$

$$
\zeta_{SCT} = m_g + 1 - \zeta_{\mu pS} \approx m_g + 1 - 2.5
\tag{2-185}
$$

For Si: $\zeta_{BCT} = 5.188 - \zeta_{Ci}$, $\zeta_{SCT} = 2.69$.

#### 2.13.6 Transit Time and Minority Charge

Internal collector resistance:

$$
r_{Ci}(T) = r_{Ci}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{Ci}}
\tag{2-186}
$$

$V_{lim}$ temperature dependence:

$$
V_{lim}(T) = \frac{v_s(T)}{\mu_{nCi0}(T)}
\tag{2-187}
$$

Saturation velocity:

$$
v_s(T) = v_{s0}\left(\frac{T}{T_0}\right)^{-a_{vs}}
\tag{2-188}
$$

$$
a_{vs} = \alpha_{vs} T_0
\tag{2-189}
$$

$V_{lim}$ combined:

$$
V_{lim}(T) = V_{lim}(T_0) \left(\frac{T}{T_0}\right)^{\zeta_{Ci} - a_{vs}}
\tag{2-190}
$$

CE saturation voltage:

$$
V_{C'E's}(T) = V_{C'E's}(T_0)[1 + \alpha_{CEs}\Delta T]
\tag{2-191}
$$

Optional $V_{DCk}$:

$$
V_{DCk}(T) = V_{DCk}(T_0)[1 - \alpha_{DCk}\Delta T]
\tag{2-192}
$$

Low-current transit time:

$$
\tau_0(T) = \tau_0(T_0)[1 + \alpha_{\tau 0}\Delta T + k_{\tau 0}\Delta T^2]
\tag{2-193}
$$

High-current saturation time constant:

$$
\tau_{hcs}(T) = \tau_{hcs}(T_0)\left(\frac{T}{T_0}\right)^{\zeta_{Ci}-1}
\tag{2-194}
$$

#### 2.13.7 Built-In Voltages

Auxiliary voltage at reference temperature:

$$
V_{Dj}(T_0) = 2V_{T0}\ln\!\left[\exp\!\left(\frac{V_D(T_0)}{2V_{T0}}\right) - \exp\!\left(-\frac{V_D(T_0)}{2V_{T0}}\right)\right]
\tag{2-195}
$$

Temperature-dependent auxiliary voltage:

$$
V_{Dj}(T) = V_{Dj}(T_0)\frac{T}{T_0} - m_g V_T\ln\!\left(\frac{T}{T_0}\right) - V_{geff}(0)\left(\frac{T}{T_0} - 1\right)
\tag{2-197}
$$

Final built-in voltage with smoothing:

$$
V_D(T) = V_{Dj}(T) + 2V_T\ln\!\left[\frac{1}{2}\left(1 + \sqrt{1 + 4\exp\!\left(-\frac{V_{Dj}(T)}{V_T}\right)}\right)\right]
\tag{2-198}
$$

Average effective bandgap for junctions:

$$
V_{geff} \to V_{g(x,y)eff} = \frac{V_{gxeff} + V_{gyeff}}{2}
\tag{2-199}
$$

with $(x,y) = (B,E), (B,C), (C,S)$.

Temperature derivative at $T_0$:

$$
\frac{dV_{Dj}(T)}{dT}\bigg|_{T_0} = \frac{V_{Dj}(T_0) - V_{geff}(0) - m_g V_{T0}}{T_0}
\tag{2-201}
$$

#### 2.13.8 Depletion Charges and Capacitances

Zero-bias capacitance temperature dependence:

$$
C_{j0}(T) = C_{j0}(T_0)\left(\frac{V_D(T_0)}{V_D(T)}\right)^z
\tag{2-202}
$$

Forward-bias ratio temperature dependence:

$$
a_j(T) = a_j(T_0)\frac{V_D(T)}{V_D(T_0)}
\tag{2-203}
$$

#### 2.13.9 Series Resistances

Internal base resistance:

$$
r_{Bi0}(T) = r_{Bi0}(T_0)\left(\frac{T}{T_0}\right)^{\zeta_{rBi}}
\tag{2-204}
$$

Same form for $r_{Bx}$ ($\zeta_{rBx}$), $r_{Cx}$ ($\zeta_{rCx}$), and $r_E$ ($\zeta_{rE}$).

#### 2.13.10 Avalanche Current

$$
f_{AVL}(T) = f_{AVL}(T_0)\exp(\alpha_{fav}\Delta T), \quad q_{AVL}(T) = q_{AVL}(T_0)\exp(\alpha_{qav}\Delta T)
\tag{2-207}
$$

with $\alpha_{fav} = \alpha_{na} - \alpha_{nb}$ and $\alpha_{qav} = \alpha_{nb}$.

$$
k_{AVL}(T) = k_{AVL}(T_0)\exp(\alpha_{kav}\Delta T)
\tag{2-208}
$$

#### 2.13.11 Tunnelling Currents

BE BtB tunneling saturation current:

$$
I_{BEtS}(T) = I_{BEtS}(T_0)\frac{V_{gBEeff}(T_0)}{V_{gBEeff}(T)}\left(\frac{V_{DE}(T)}{V_{DE}(T_0)}\right)^2 \frac{C_{jE0}(T)}{C_{jE0}(T_0)}
\tag{2-209}
$$

BE BtB tunneling exponent:

$$
a_{BEt}(T) = a_{BEt}(T_0)\left(\frac{V_{gBEeff}(T)}{V_{gBEeff}(T_0)}\right)^{3/2} \frac{V_{DE}(T_0)}{V_{DE}(T)} \frac{C_{jE0}(T_0)}{C_{jE0}(T)}
\tag{2-210}
$$

$$
V_{gBEeff}(T) = \frac{V_{gBeff}(T) + V_{gEeff}(T)}{2}
\tag{2-211}
$$

BC BtB tunneling saturation current:

$$
I_{BCtS}(T) = I_{BCtS}(T_0)\frac{V_{gBCeff}(T_0)}{V_{gBCeff}(T)}\left(\frac{V_{DCi}(T)}{V_{DCi}(T_0)}\right)^2 \frac{C_{jCi0}(T)}{C_{jCi0}(T_0)}
\tag{2-212}
$$

BC BtB tunneling exponent:

$$
a_{BCt}(T) = a_{BCt}(T_0)\left(\frac{V_{gBCeff}(T)}{V_{gBCeff}(T_0)}\right)^{3/2} \frac{V_{DCi}(T_0)}{V_{DCi}(T)} \frac{C_{jCi0}(T_0)}{C_{jCi0}(T)}
\tag{2-213}
$$

$$
V_{gBCeff}(T) = \frac{V_{gBeff}(T) + V_{gCeff}(T)}{2}
\tag{2-214}
$$

Trap-assisted tunneling temperature dependence:

$$
I_{TAT0}(T) = I_{TAT0}(T_0)\exp\!\left(\frac{V_D(T_0) - V_D(T)}{V_{TAT}}\right)
\tag{2-215}
$$

#### 2.13.12 Parasitic Substrate Transistor

Transfer current:

$$
I_{TS}(T) = I_{TSS}(T_0)\left(\frac{T}{T_0}\right)^{\zeta_{BCxT}} \exp\!\left[\frac{V_{gCeff}(0)}{V_T}\left(\frac{T}{T_0} - 1\right)\right]
\tag{2-216}
$$

Transit time:

$$
\tau_{Sf}(T) = \tau_{Sf}(T_0)\left(\frac{T}{T_0}\right)^{\zeta_{Cx}-1}
\tag{2-217}
$$

#### 2.13.13 Thermal Resistance

$$
R_{th}(T) = R_{th}(T_0)[1 + \alpha_{Rth}\Delta T]\left(\frac{T}{T_0}\right)^{\zeta_{Rth}}
\tag{2-218}
$$

### 2.14 Self-Heating

Full power dissipation (FLSH=2):

$$
P = I_T V_{C'E'} + \sum_d I_{jd} V_{diode} + I_{AVL}(V_{DCi} - V_{B'C'}) + \sum_n \frac{\Delta V_n^2}{r_n}
\tag{2-219}
$$

with $d \in \{BEi, BCi, BEp, BCx, SC\}$ and $r_n \in \{r_{Bi}, r_{Bx}, r_E, r_{Cx}\}$ (non-zero).

Simplified power dissipation (FLSH=1):

$$
P = I_T V_{C'E'} + I_{AVL}(V_{DCi} - V_{B'C'})
\tag{2-220}
$$

### 2.15 Lateral Scaling

#### 2.15.1 Bias-Dependent Collector Current Spreading

Normalized injection width (2D/3D):

$$
w = \frac{w_i}{w_C} = \begin{cases}
\dfrac{\kappa - 1}{\zeta_l - \kappa\zeta_b} & l_{E0} > b_{E0} \\[1em]
\dfrac{1}{\zeta_b}\left(\dfrac{1 + \zeta_b}{1 + i_{ck}\zeta_b} - 1\right) & l_{E0} = b_{E0}
\end{cases}
\tag{2-221}
$$

Spreading factors:

$$
\zeta_b = \xi_b w_{Ci}, \quad \zeta_l = \xi_l w_{Ci}
\tag{2-222}
$$

$$
\kappa = \frac{1 + \zeta_l}{1 + \zeta_b}\exp\!\left[i_{ck}\ln\!\left(\frac{1 + \zeta_b}{1 + \zeta_l}\right)\right] = \left(\frac{1 + \zeta_b}{1 + \zeta_l}\right)^{i_{ck}-1}
\tag{2-223}
$$

$$
i_{ck} = 1 - \frac{i + \sqrt{i^2 + a_{hc}}}{1 + \sqrt{1 + a_{hc}}}, \quad i = 1 - \frac{I_{CK}}{I_{Tf}}
\tag{2-224}
$$

Extended collector charge with current spreading ($l_{E0} > b_{E0}$):

$$
Q_{Cf} = \tau_{pCS} I_{Tf} \exp\!\left(\frac{\Delta V_{cBar} - V_{cBar}}{V_T}\right) \cdot 2\frac{f_{CSl} - f_{CSb}}{\zeta_b - \zeta_l}
\tag{2-225}
$$

For square emitter ($l_{E0} = b_{E0}$):

$$
Q_{Cf} = \tau_{pCS} I_{Tf} \exp\!\left(\frac{\Delta V_{cBar} - V_{cBar}}{V_T}\right) \cdot \frac{1 + \zeta_b w/3}{1 + \zeta_b w} w^2
$$

Auxiliary spreading functions:

$$
f_{CSl} = \frac{\ln(1 + \zeta_l w)}{\zeta_l}\left(\frac{1}{2} - \frac{\zeta_b}{6\zeta_l}\right) + w\left(\frac{\zeta_b}{6\zeta_l} + \frac{\zeta_b w}{6}\right)
\tag{2-226}
$$

$$
f_{CSb} = \frac{\ln(1 + \zeta_b w)}{\zeta_b}\left(\frac{1}{2} - \frac{\zeta_l}{6\zeta_b}\right) + w\left(\frac{\zeta_l}{6\zeta_b} + \frac{\zeta_l w}{6}\right)
\tag{2-227}
$$

2D reduction ($\zeta_l = 0$):

$$
f_{CCS}(\zeta_l = 0) = \frac{2}{\zeta_b}w\left(\frac{1}{2} + \frac{\zeta_b}{4}w\right) - \frac{\ln(1 + \zeta_b w)}{\zeta_b}\frac{1}{2}
\tag{2-228}
$$

Collector transit time (2D/3D):

$$
\tau_{Cf} = \frac{dQ_{Cf}}{dI_{Tf}}\bigg|_{V_{C'E'}}
\tag{2-229}
$$

Collector current spreading function:

$$
f_{cs} = \begin{cases}
\dfrac{\zeta_b - \zeta_l}{\ln[(1+\zeta_b)/(1+\zeta_l)]} & l_E > b_E \\[1em]
1 + \zeta_b & l_E = b_E
\end{cases}
\tag{2-230}
$$

#### 2.15.3 Emitter Current Crowding

Geometry functions:

$$
g_\eta = 18.3 - 12.2\frac{b_E}{l_E} - 19.6\left(\frac{b_E}{l_E}\right)^2
\tag{2-236a}
$$

$$
g_i = \frac{1}{12} - \left(\frac{1}{12} - \frac{1}{28.6}\right)\frac{b_E}{l_E}
\tag{2-236b}
$$

$$
f_{geo} = \frac{1}{g_i g_\eta}
\tag{2-235}
$$

### Operating Point Equations (Chapter 4)

Internal transconductance:

$$
g_{mT} = \frac{\partial I_T}{\partial V_{B'E'}}\bigg|_{V_{C'E'}}
\tag{4-2a}
$$

Output conductance:

$$
g_{oT} = \frac{\partial I_T}{\partial V_{C'E'}}\bigg|_{V_{B'E'}}
\tag{4-2b}
$$

Avalanche elements:

$$
g_{av,f} = \frac{\partial I_{avl}}{\partial V_{B'E'}}\bigg|_{V_{B'C'}}, \quad g_{av,r} = \frac{\partial I_{avl}}{\partial V_{B'C'}}\bigg|_{V_{B'E'}}
\tag{4-3}
$$

Lumped BE conductance:

$$
g_{bei} = g_{jbei} - g_{bet} + g_{bhr,f}
\tag{4-11a}
$$

Lumped BC conductance:

$$
g_{\mu i} = g_{jbci} - g_{av,r} + g_{bhr,r}
\tag{4-11b}
$$

Internal BE capacitance:

$$
C_{\pi i} = C_{jEi} + C_{dE,f}
\tag{4-12a}
$$

Internal BC capacitance:

$$
C_{\mu i} = C_{jCi} + C_{dC,r}
\tag{4-12b}
$$

Total intrinsic transconductance:

$$
g_{mi} = g_{mT} + g_{av,f}
\tag{4-13}
$$

Internal output resistance:

$$
r_{oi} = \frac{1}{g_{oT} - g_{av,r}}
\tag{4-14}
$$

Total BE resistance:

$$
r_\pi = \frac{1}{g_{bei} - g_{av,f} + g_{jbep}}
\tag{4-15}
$$

Total feedback resistance:

$$
r_\mu = \frac{1}{g_{\mu i} + g_{\mu x}}
\tag{4-17}
$$

External BE capacitance:

$$
C_{\pi x} = C_{jEp} + C_{BEpar}
\tag{4-19}
$$

External BC capacitance:

$$
C_{\mu x} = C_{jCx} + C_{BCpar} + C_{dS}
\tag{4-20}
$$

Total CS capacitance:

$$
C_{CS} = C_{jS} + C_{SCp}
\tag{4-21}
$$

AC current gain:

$$
\beta_{AC} = \frac{\partial I_{Ci}/\partial V_{B'E'}|_{V_{C'E'}}}{\partial I_{Bi}/\partial V_{B'E'}|_{V_{C'E'}}} = \frac{g_{mi} - g_{\mu i}}{g_{\pi i} + g_{\mu i}}
\tag{4-22 to 4-24}
$$

Intrinsic voltage gain:

$$
A_{Vi} = -\frac{g_{mi} - g_{\mu i}}{g_{oi} + g_{\mu i}}
\tag{4-25}
$$

Transit frequency approximation:

$$
f_T = \frac{g_{mi}}{2\pi(C_\pi + C_\mu + r \cdot C_\mu \cdot g_{mi})}
\tag{4-26}
$$

$$
C_\pi = C_{\pi x} + C_{\pi i}, \quad C_\mu = C_{\mu x} + C_{\mu i}
\tag{4-27, 4-28}
$$

$$
r = R_{Cx} + R_E + \frac{R_B + R_E}{\beta_{ac}}
\tag{4-29}
$$

---

## Internal Constants

| Constant | Value | Description |
|----------|-------|-------------|
| $a_{fj}$ | 1.921812 | Smoothing constant for depletion charge ($= 4\ln^2 2$) |
| $a_{fi}$ | 1.921812 | Smoothing constant for $v_{j,u}$ in $h_{jEi}$ |
| $a_{qr}$ | 0.01 | Smoothing constant for conductivity modulation |
| $a_{ick}$ | 1e-3 | Smoothing constant for $I_{CK}$ punch-through |
| $a_{vceff}$ | 1.921812 | Smoothing constant for effective collector voltage (versions <= 3.0.0) |
| $u_{\min}$ | 0.001 | Boundary for Bernoulli function series expansion |
| $Q_{B,rt}$ | $0.05 Q_{p0}$ | Minimum hole charge (base reach-through limit) |
| $s_{mavl}$ | 0.1 | Smoothing parameter for current-dependent avalanche |
| $c_{mavl}$ | 1 | Fixed parameter for current-dependent avalanche |
| $m_g$ | 4.188 (Si) | Bandgap temperature exponent |
| $z_{Ci,r}$ | $z_{Ci}/4$ | Internal parameter for punch-through grading coefficient |
