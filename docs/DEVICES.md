# BigOSpice Device Model Reference

This document describes every device type supported by BigOSpice. Each entry covers
the element instance line syntax, required/optional parameters, model card
parameters, key equations, and a minimal example.

Element names are case-insensitive. Node names are case-insensitive strings;
`0` and `gnd` are always ground.

---

## Table of Contents

1. [R — Resistor](#r--resistor)
2. [C — Capacitor](#c--capacitor)
3. [L — Inductor](#l--inductor)
4. [K — Mutual Inductance](#k--mutual-inductance)
5. [D — Diode](#d--diode)
6. [Q — BJT (Gummel-Poon)](#q--bjt-gummel-poon)
7. [Q (VBIC) — VBIC Bipolar](#q-vbic--vbic-bipolar)
8. [M — MOSFET Level 1](#m--mosfet-level-1)
9. [M — MOSFET Level 2](#m--mosfet-level-2)
10. [M — MOSFET Level 3](#m--mosfet-level-3)
11. [M — MOSFET Level 6 (Sakurai-Newton)](#m--mosfet-level-6-sakurai-newton)
12. [M — BSIM3v3](#m--bsim3v3)
13. [M — BSIM4](#m--bsim4)
14. [J — JFET](#j--jfet)
15. [Z — MESFET (Curtice)](#z--mesfet-curtice)
16. [V — Voltage Source](#v--voltage-source)
17. [I — Current Source](#i--current-source)
18. [E — VCVS](#e--vcvs)
19. [G — VCCS](#g--vccs)
20. [H — CCVS](#h--ccvs)
21. [F — CCCS](#f--cccs)
22. [B — Behavioral Source](#b--behavioral-source)
23. [S — Voltage-Controlled Switch](#s--voltage-controlled-switch)
24. [W — Current-Controlled Switch](#w--current-controlled-switch)
25. [T — Lossless Transmission Line](#t--lossless-transmission-line)
26. [O — LTRA Lossy Transmission Line](#o--ltra-lossy-transmission-line)
27. [U — Uniform RC Line](#u--uniform-rc-line)
28. [W (Wlossy) — Frequency-Domain Lossy Line](#w-wlossy--frequency-domain-lossy-line)
29. [PORT — S-Parameter Port](#port--s-parameter-port)

---

## R — Resistor

**Element prefix:** `R`

**Instance line:**
```
Rname  n+  n-  <value|{expr}>  [TC1=val]  [TC2=val]  [MODEL=mname]
```

**Parameters:**

| Parameter | Description                              | Unit  | Default |
|-----------|------------------------------------------|-------|---------|
| value     | Resistance (positional or `R=`)          | Ohm   | —       |
| TC1       | First-order temperature coefficient      | 1/K   | 0       |
| TC2       | Second-order temperature coefficient     | 1/K²  | 0       |

**Temperature dependence:**
```
R(T) = R0 * [1 + TC1*(T - Tnom) + TC2*(T - Tnom)^2]
```

**Model card (.MODEL) — type RES:**

| Parameter | Description                    | Default |
|-----------|--------------------------------|---------|
| TC1       | First-order TC                 | 0       |
| TC2       | Second-order TC                | 0       |
| TNOM      | Nominal temperature [°C]       | 27      |

**Example:**
```spice
R1  in  out  1k
R2  vdd  0   {R_LOAD}  TC1=1e-3
```

---

## C — Capacitor

**Element prefix:** `C`

**Instance line:**
```
Cname  n+  n-  <value|{expr}>  [IC=val]  [MODEL=mname]
```

**Parameters:**

| Parameter | Description                    | Unit | Default |
|-----------|--------------------------------|------|---------|
| value     | Capacitance                    | F    | —       |
| IC        | Initial condition voltage      | V    | 0       |

**Constitutive relation:** `i = C * dv/dt`

**Model card (.MODEL) — type CAP:**

| Parameter | Description                    | Default |
|-----------|--------------------------------|---------|
| C         | Capacitance multiplier         | 1       |
| TC1       | First-order TC                 | 0       |
| TC2       | Second-order TC                | 0       |

**Example:**
```spice
C1  out  0  100p  IC=0
```

---

## L — Inductor

**Element prefix:** `L`

**Instance line:**
```
Lname  n+  n-  <value|{expr}>  [IC=val]
```

**Parameters:**

| Parameter | Description               | Unit | Default |
|-----------|---------------------------|------|---------|
| value     | Inductance                | H    | —       |
| IC        | Initial condition current | A    | 0       |

**Constitutive relation:** `v = L * di/dt`

Inductors with a branch current variable in MNA — they contribute one extra row
and column to the system matrix.

**Example:**
```spice
L1  drain  0  10n  IC=0
```

---

## K — Mutual Inductance

**Element prefix:** `K`

**Instance line:**
```
Kname  Lxxx  Lyyy  <k>
```

`k` is the coupling coefficient, `0 < k <= 1`.

Adds off-diagonal terms to the inductor stamp:
```
M = k * sqrt(L1 * L2)
```

**Example:**
```spice
L1  p1  0   100n
L2  p2  0   100n
K1  L1  L2  0.95
```

---

## D — Diode

**Element prefix:** `D`

**Instance line:**
```
Dname  n+  n-  mname  [AREA=val]  [IC=val]
```

**Parameters:**

| Parameter | Description          | Unit | Default |
|-----------|----------------------|------|---------|
| AREA      | Area multiplier      | —    | 1       |
| IC        | Initial condition    | V    | 0       |

**Model card (.MODEL) — type D:**

| Parameter | Description                           | Unit  | Default   |
|-----------|---------------------------------------|-------|-----------|
| IS        | Saturation current                    | A     | 1e-14     |
| N         | Ideality factor                       | —     | 1         |
| RS        | Ohmic series resistance               | Ohm   | 0         |
| CJO       | Zero-bias junction capacitance        | F     | 0         |
| VJ        | Built-in potential                    | V     | 1         |
| M         | Grading coefficient                   | —     | 0.5       |
| EG        | Activation energy                     | eV    | 1.11      |
| XTI       | Saturation current temperature exp    | —     | 3         |
| BV        | Reverse breakdown voltage             | V     | inf       |
| IBV       | Reverse breakdown current             | A     | 1e-3      |
| TT        | Transit time                          | s     | 0         |
| FC        | Forward-bias depletion cap coefficient| —     | 0.5       |

**Key equation (Shockley):**
```
Id = IS * AREA * [exp(Vd / (N * Vt)) - 1]
```

**Example:**
```spice
.MODEL D1N4148 D (IS=2.52e-9 N=1.752 RS=0.568 CJO=4p VJ=0.7 M=0.333 TT=20n)
D1  anode  cathode  D1N4148
```

---

## Q — BJT (Gummel-Poon)

**Element prefix:** `Q`

**Instance line:**
```
Qname  C  B  E  [S]  mname  [AREA=val]  [IC=vbe,vce]
```

The substrate node `S` is optional (defaults to ground).

**Parameters:**

| Parameter | Description                 | Unit | Default |
|-----------|-----------------------------|------|---------|
| AREA      | Area multiplier             | —    | 1       |
| IC        | Initial conditions Vbe,Vce  | V    | 0,0     |

**Model card (.MODEL) — type NPN or PNP:**

| Parameter | Description                              | Default   |
|-----------|------------------------------------------|-----------|
| IS        | Transport saturation current [A]         | 1e-16     |
| BF        | Ideal max forward beta                   | 100       |
| NF        | Forward current emission coefficient     | 1         |
| VAF       | Forward Early voltage [V]                | inf       |
| IKF       | High-level injection knee current [A]    | inf       |
| ISE       | B-E leakage saturation current [A]       | 0         |
| NE        | B-E leakage emission coefficient         | 1.5       |
| BR        | Ideal max reverse beta                   | 1         |
| NR        | Reverse current emission coefficient     | 1         |
| VAR       | Reverse Early voltage [V]                | inf       |
| IKR       | High-level injection reverse knee [A]    | inf       |
| ISC       | B-C leakage saturation current [A]       | 0         |
| NC        | B-C leakage emission coefficient         | 2         |
| RB        | Zero-bias base resistance [Ohm]          | 0         |
| RC        | Collector resistance [Ohm]               | 0         |
| RE        | Emitter resistance [Ohm]                 | 0         |
| CJE       | B-E zero-bias depletion capacitance [F]  | 0         |
| VJE       | B-E built-in potential [V]               | 0.75      |
| MJE       | B-E grading coefficient                  | 0.33      |
| CJC       | B-C zero-bias depletion capacitance [F]  | 0         |
| VJC       | B-C built-in potential [V]               | 0.75      |
| MJC       | B-C grading coefficient                  | 0.33      |
| TF        | Ideal forward transit time [s]           | 0         |
| TR        | Ideal reverse transit time [s]           | 0         |
| TNOM      | Nominal temperature [°C]                 | 27        |

**Example:**
```spice
.MODEL Q2N2222 NPN (IS=14.34e-15 BF=255 NF=1 VAF=74.3 IKF=0.2847
+                   CJE=22.01p VJE=0.756 MJE=0.5 TF=411p)
Q1  coll  base  emit  Q2N2222
```

---

## Q (VBIC) — VBIC Bipolar

**Element prefix:** `Q`

VBIC (Vertical Bipolar Inter-Company) is a 4-terminal model with explicit
substrate node. Activated when the model type is `NPN` or `PNP` and a key
VBIC parameter (`RCX`, `RCI`, `VO`, etc.) is present, or via `LEVEL=4`.

**Instance line:**
```
Qname  C  B  E  S  mname
```

**Selected model parameters (key differences from GP):**

| Parameter | Description                               |
|-----------|-------------------------------------------|
| RCX       | Extrinsic collector resistance [Ohm]      |
| RCI       | Intrinsic collector resistance [Ohm]      |
| VO        | Epi drift saturation voltage [V]          |
| GAMM      | Epi doping parameter                      |
| HRCF      | High current RC factor                    |
| RBXS      | Extrinsic base-substrate resistance [Ohm] |
| AVC1, AVC2| Avalanche multiplication coefficients     |
| ITSS      | Substrate transport saturation current    |

For the full VBIC parameter set refer to the VBIC 1.3 standard.

**Example:**
```spice
.MODEL VBIC_NPN NPN LEVEL=4 (RCX=10 RCI=60 VO=2 GAMM=2e-11)
Q1  coll  base  emit  sub  VBIC_NPN
```

---

## M — MOSFET Level 1

**Element prefix:** `M`

**Instance line:**
```
Mname  D  G  S  B  mname  [L=val]  [W=val]  [AD=val]  [AS=val]
+      [PD=val]  [PS=val]  [NRD=val]  [NRS=val]  [IC=vds,vgs,vbs]
```

**Instance parameters:**

| Parameter | Description                      | Unit | Default    |
|-----------|----------------------------------|------|------------|
| L         | Channel length                   | m    | DEFL (100n)|
| W         | Channel width                    | m    | DEFW (100n)|
| AD        | Drain diffusion area             | m²   | 0          |
| AS        | Source diffusion area            | m²   | 0          |
| PD        | Drain diffusion perimeter        | m    | 0          |
| PS        | Source diffusion perimeter       | m    | 0          |
| NRD       | Drain square count               | —    | 1          |
| NRS       | Source square count              | —    | 1          |

**Model card (.MODEL) — type NMOS or PMOS, LEVEL=1:**

| Parameter | Description                           | Default   |
|-----------|---------------------------------------|-----------|
| VTO       | Threshold voltage [V]                 | 0 (n) / 0 |
| KP        | Transconductance [A/V²]               | 2e-5      |
| GAMMA     | Body effect coefficient [V^0.5]       | 0         |
| PHI       | Surface potential [V]                 | 0.6       |
| LAMBDA    | Channel-length modulation [1/V]       | 0         |
| RD        | Drain resistance [Ohm]                | 0         |
| RS        | Source resistance [Ohm]               | 0         |
| CBD       | B-D zero-bias capacitance [F]         | 0         |
| CBS       | B-S zero-bias capacitance [F]         | 0         |
| IS        | Bulk junction saturation current [A]  | 1e-14     |
| TOX       | Gate oxide thickness [m]              | 1e-7      |
| NSUB      | Substrate doping [1/cm³]              | 0         |
| NSS       | Surface state density [1/cm²]         | 0         |
| TNOM      | Nominal temperature [°C]              | 27        |

**Example:**
```spice
.MODEL NFET NMOS (LEVEL=1 VTO=0.7 KP=120e-6 GAMMA=0.4 PHI=0.65 LAMBDA=0.02)
M1  drain  gate  source  bulk  NFET  L=250n  W=1u
```

---

## M — MOSFET Level 2

**Element prefix:** `M`

Grove-Frohman bulk-charge model. Activated with `LEVEL=2` in the model card.
Same instance line as Level 1.

**Additional model parameters:**

| Parameter | Description                                   | Default |
|-----------|-----------------------------------------------|---------|
| NFS       | Fast surface state density [1/cm²/V]          | 0       |
| NEFF      | Total effective channel charge coefficient    | 1       |
| UEXP      | Mobility degradation exponent                 | 0       |
| UCRIT     | Critical field for mobility [V/cm]            | 1e4     |
| DELTA     | Narrow-width threshold adjustment             | 0       |
| VMAX      | Maximum carrier drift velocity [m/s]          | 0       |

**Example:**
```spice
.MODEL NMOS2 NMOS (LEVEL=2 VTO=0.8 KP=80e-6 GAMMA=0.5 PHI=0.6 LAMBDA=0.015
+                  NFS=1e11 UEXP=0.1 UCRIT=5e4)
M2  d  g  s  b  NMOS2  L=500n  W=2u
```

---

## M — MOSFET Level 3

**Element prefix:** `M`

Empirical model with DIBL and mobility degradation. Activated with `LEVEL=3`.
Same instance line as Level 1.

**Key additional model parameters:**

| Parameter | Description                                    | Default |
|-----------|------------------------------------------------|---------|
| ETA       | Static feedback parameter (DIBL)               | 0       |
| KAPPA     | Saturation field factor                        | 0.2     |
| THETA     | Mobility modulation [1/V]                      | 0       |
| DELTA     | Narrow-width effect coefficient                | 0       |
| VMAX      | Maximum carrier drift velocity [m/s]           | 0       |
| XJ        | Metallurgical junction depth [m]               | 0       |
| NFS       | Fast surface state density [1/cm²/V]           | 0       |

**Example:**
```spice
.MODEL NMOS3 NMOS (LEVEL=3 VTO=0.75 KP=90e-6 GAMMA=0.45 PHI=0.6
+                  ETA=0.02 THETA=0.05 KAPPA=0.3)
M3  d  g  s  b  NMOS3  L=350n  W=1.5u
```

---

## M — MOSFET Level 6 (Sakurai-Newton)

**Element prefix:** `M`

Power-law compact model suitable for digital timing analysis. Activated with `LEVEL=6`.
Same instance line as Level 1.

**Key model parameters:**

| Parameter | Description                          | Default |
|-----------|--------------------------------------|---------|
| VTO       | Threshold voltage [V]                | 0       |
| KP        | Process transconductance [A/V²]      | 2e-5    |
| MU        | Mobility degradation factor          | 1       |
| MJ        | Drain current power-law exponent     | 2       |
| LAMBDA    | Channel-length modulation [1/V]      | 0       |

**Example:**
```spice
.MODEL NMOSSK NMOS (LEVEL=6 VTO=0.6 KP=150e-6 MU=1.2 MJ=1.8 LAMBDA=0.01)
M4  d  g  s  b  NMOSSK  L=180n  W=720n
```

---

## M — BSIM3v3

**Element prefix:** `M`

Berkeley Short-Channel IGFET Model, version 3.3. Activated with `LEVEL=8` (ngspice)
or `LEVEL=49` (HSPICE/Xyce). 4-terminal: D, G, S, B.

**Instance line:** same as Level 1, with optional `NF=` (number of fingers).

**Key model parameters (selected):**

| Parameter | Description                              |
|-----------|------------------------------------------|
| TNOM      | Nominal temperature [°C]                 |
| TOX       | Gate oxide thickness [m]                 |
| TOXE      | Electrical oxide thickness [m]           |
| XJ        | Source/drain junction depth [m]          |
| NCH       | Channel doping [1/cm³]                   |
| VTH0      | Threshold voltage (long channel) [V]     |
| K1        | First-order body effect coefficient [V^½]|
| K2        | Second-order body effect coefficient     |
| U0        | Low-field mobility [cm²/V·s]             |
| UA, UB    | Mobility degradation coefficients        |
| VSAT      | Saturation velocity [m/s]                |
| A0        | Bulk charge effect coefficient           |
| KETA      | Body-bias coefficient of bulk charge     |
| RDSW      | Source/drain resistance per width [Ohm·m]|
| CGSO, CGDO| Gate-source/drain overlap cap [F/m]     |
| CJ        | Bottom junction capacitance [F/m²]       |
| CJSW      | Sidewall junction capacitance [F/m]      |

For the complete BSIM3v3.3 parameter set refer to the UC Berkeley BSIM3 manual.

**Example:**
```spice
.MODEL nmos_bsim3 NMOS LEVEL=8 (TOX=4.2e-9 XJ=1.2e-7 NCH=2.3e17
+   VTH0=0.481 K1=0.559 U0=350 UA=1.8e-9 VSAT=1.0e5)
M1  d  g  s  b  nmos_bsim3  L=250n  W=1u
```

---

## M — BSIM4

**Element prefix:** `M`

Berkeley Short-Channel IGFET Model 4.8.3. Activated with `LEVEL=14` (ngspice)
or `LEVEL=54` (HSPICE/Xyce). 4-terminal: D, G, S, B.

**Instance line:** same as BSIM3, with optional `NF=`, `SA=`, `SB=`, `SD=`.

**Key model parameters (selected):**

| Parameter | Description                                     |
|-----------|-------------------------------------------------|
| TOXE      | Electrical gate-oxide thickness [m]             |
| TOXP      | Physical gate-oxide thickness [m]               |
| TOXM      | Gate-oxide thickness at which params extracted  |
| NDEP      | Channel doping at depletion edge [1/cm³]        |
| VTH0      | Long-channel threshold at Vbs=0 [V]             |
| K1        | First-order body-effect coefficient [V^½]       |
| K2        | Second-order body-effect coefficient            |
| U0        | Low-field mobility [cm²/V·s]                    |
| UA, UB, UC| Mobility degradation coefficients               |
| VSAT      | Saturation velocity [m/s]                       |
| A1, A2    | Saturation voltage coefficients                 |
| RDSW      | Source/drain resistance [Ohm·µm]                |
| PCLM      | Channel-length modulation coefficient           |
| PDIBLC1/2 | DIBL effect coefficients                        |
| DROUT     | DIBL coefficient in channel-length modulation   |
| PVAG      | Gate dependence of output resistance            |
| CGSO, CGDO| Gate-overlap capacitance [F/m]                 |
| CGSL, CGDL| Gate-to-S/D lightly-doped region cap [F/m]     |
| CJ        | Bottom junction capacitance [F/m²]              |
| MOBMOD    | Mobility model selector (0/1/2)                 |
| CAPMOD    | Capacitance model selector (0/1/2/3)            |
| IGCMOD    | Gate current model selector                     |
| WPEMOD    | Well-proximity effect model selector            |

For the complete BSIM4.8.3 parameter set refer to the UC Berkeley BSIM4 manual
or the Verilog-A source distributed with BigOSpice (`crates/osdi/`).

**Example:**
```spice
.MODEL nmos4 NMOS LEVEL=14 (TOXE=1.8e-9 NDEP=1.7e17 VTH0=0.42
+   K1=0.45 U0=450 VSAT=9.0e4 RDSW=150)
M1  d  g  s  b  nmos4  L=65n  W=260n  NF=4
```

---

## J — JFET

**Element prefix:** `J`

Shichman-Hodges Level 1 model. N-channel (`NJFET`) or P-channel (`PJFET`).

**Instance line:**
```
Jname  D  G  S  mname  [AREA=val]
```

**Model card (.MODEL) — type NJF or PJF:**

| Parameter | Description                             | Default |
|-----------|-----------------------------------------|---------|
| VTO       | Threshold (pinch-off) voltage [V]       | -2 (N)  |
| BETA      | Transconductance [A/V²]                 | 1e-4    |
| LAMBDA    | Channel-length modulation [1/V]         | 0       |
| RD        | Drain ohmic resistance [Ohm]            | 0       |
| RS        | Source ohmic resistance [Ohm]           | 0       |
| CGS       | Zero-bias gate-source capacitance [F]   | 0       |
| CGD       | Zero-bias gate-drain capacitance [F]    | 0       |
| PB        | Gate junction potential [V]             | 1       |
| IS        | Gate junction saturation current [A]    | 1e-14   |

**Example:**
```spice
.MODEL J2SK170 NJF (VTO=-0.6 BETA=10m LAMBDA=0.01 RD=1 RS=1)
J1  drain  gate  source  J2SK170
```

---

## Z — MESFET (Curtice)

**Element prefix:** `Z`

Curtice quadratic model for GaAs MESFETs. N-channel (`NMESFET`) or P-channel (`PMESFET`).

**Instance line:**
```
Zname  D  G  S  mname  [AREA=val]
```

**Model card (.MODEL) — type NMF or PMF:**

| Parameter | Description                             | Default |
|-----------|-----------------------------------------|---------|
| VTO       | Pinch-off voltage [V]                   | -2      |
| ALPHA     | Saturation voltage parameter [1/V]      | 2       |
| BETA      | Transconductance [A/V²]                 | 1e-4    |
| LAMBDA    | Channel-length modulation [1/V]         | 0       |
| RD        | Drain resistance [Ohm]                  | 0       |
| RS        | Source resistance [Ohm]                 | 0       |
| CGS       | Gate-source capacitance [F]             | 0       |
| CGD       | Gate-drain capacitance [F]              | 0       |

**Key equation:**
```
Ids = BETA * (Vgs - VTO)^2 * (1 + LAMBDA*Vds) * tanh(ALPHA*Vds)   [saturation]
```

**Example:**
```spice
.MODEL GaAsFET NMF (VTO=-1.5 ALPHA=3 BETA=20m LAMBDA=0.005 CGS=0.5p CGD=0.1p)
Z1  drain  gate  source  GaAsFET
```

---

## V — Voltage Source

**Element prefix:** `V`

**Instance line:**
```
Vname  n+  n-  [DC val]  [AC mag [phase]]  [waveform]
```

**DC/AC values:**

| Keyword | Description                      |
|---------|----------------------------------|
| DC      | DC value [V] (default 0)         |
| AC      | AC magnitude [V] and phase [deg] |

**Waveform specifications** — see [NETLIST.md](NETLIST.md#source-waveforms) for full syntax.

Supported: `PULSE`, `SIN`, `EXP`, `PWL`, `SFFM`, `AM`, `TRNOISE`, `TRRANDOM`.

Voltage sources contribute a branch current variable to MNA.

**Example:**
```spice
V1  vdd  0  DC 3.3
V2  in   0  DC 0 AC 1 SIN(0 1 1MEG)
```

---

## I — Current Source

**Element prefix:** `I`

**Instance line:**
```
Iname  n+  n-  [DC val]  [AC mag [phase]]  [waveform]
```

Positive conventional current flows from `n+` to `n-` through the source (into
`n+` in the external circuit).

Same waveform support as `V` sources.

**Example:**
```spice
I1  out  0  DC 1m
I2  in   0  AC 1 PULSE(0 1m 0 1n 1n 500n 1u)
```

---

## E — VCVS

**Element prefix:** `E`

**Instance line (linear):**
```
Ename  n+  n-  nc+  nc-  <gain>
```

**Instance line (behavioral):**
```
Ename  n+  n-  VALUE={expr}
```

**Instance line (LAPLACE):**
```
Ename  n+  n-  nc+  nc-  LAPLACE={H(s)}  [IC=val]
```

**Instance line (POLY):**
```
Ename  n+  n-  POLY(n)  nc1+  nc1-  ...  c0  c1  c2  ...
```

`V(n+,n-) = gain * V(nc+,nc-)`

**Example:**
```spice
E1  out  0  in  0  10
E2  vfb  0  VALUE={V(out)*0.1 + V(ref)*0.9}
```

---

## G — VCCS

**Element prefix:** `G`

**Instance line (linear):**
```
Gname  n+  n-  nc+  nc-  <transconductance>
```

**Instance line (behavioral):**
```
Gname  n+  n-  VALUE={expr}
```

`I(n+ → n-) = gm * V(nc+,nc-)`

**Example:**
```spice
G1  drain  source  gate  source  20m
```

---

## H — CCVS

**Element prefix:** `H`

**Instance line:**
```
Hname  n+  n-  Vxxx  <transresistance>
```

`V(n+,n-) = rm * I(Vxxx)`

`Vxxx` must be the name of a voltage source element (used as a current probe).

**Example:**
```spice
Vsense  node1  node2  DC 0
H1  out  0  Vsense  1k
```

---

## F — CCCS

**Element prefix:** `F`

**Instance line:**
```
Fname  n+  n-  Vxxx  <gain>
```

`I(n+ → n-) = gain * I(Vxxx)`

**Example:**
```spice
Vsense  a  b  DC 0
F1  c  d  Vsense  50
```

---

## B — Behavioral Source

**Element prefix:** `B`

**Instance line (voltage):**
```
Bname  n+  n-  V={expr}
```

**Instance line (current):**
```
Bname  n+  n-  I={expr}
```

Expressions may reference:
- `V(node)`, `V(n1,n2)` — node voltages
- `I(Vxxx)` — branch currents through voltage sources
- `.PARAM` values and mathematical functions
- `time`, `temper`, `frequency`

**Example:**
```spice
B1  out  0  V={V(in)*exp(-V(ctrl))}
B2  out  0  I={1m * tanh(V(in)/25m)}
```

---

## S — Voltage-Controlled Switch

**Element prefix:** `S`

**Instance line:**
```
Sname  n+  n-  nc+  nc-  mname  [ON|OFF]
```

**Model card (.MODEL) — type SW:**

| Parameter | Description                   | Default |
|-----------|-------------------------------|---------|
| RON       | On resistance [Ohm]           | 1       |
| ROFF      | Off resistance [Ohm]          | 1e12    |
| VON       | Control voltage for ON [V]    | 1       |
| VOFF      | Control voltage for OFF [V]   | 0       |

**Example:**
```spice
.MODEL SW1 SW (RON=0.1 ROFF=1e9 VON=2.5 VOFF=0.5)
S1  drain  source  gate  0  SW1
```

---

## W — Current-Controlled Switch

**Element prefix:** `W`

**Instance line:**
```
Wname  n+  n-  Vxxx  mname  [ON|OFF]
```

**Model card (.MODEL) — type CSW:**

| Parameter | Description                     | Default |
|-----------|---------------------------------|---------|
| RON       | On resistance [Ohm]             | 1       |
| ROFF      | Off resistance [Ohm]            | 1e12    |
| ION       | Control current for ON [A]      | 1e-3    |
| IOFF      | Control current for OFF [A]     | 0       |

**Example:**
```spice
Vprobe  ctrl_a  ctrl_b  DC 0
.MODEL CW1 CSW (RON=0.5 ROFF=1e9 ION=5m IOFF=1m)
W1  out+  out-  Vprobe  CW1
```

---

## T — Lossless Transmission Line

**Element prefix:** `T`

Branin's method: lossless two-port with characteristic impedance and time delay.

**Instance line:**
```
Tname  in+  in-  out+  out-  Z0=val  TD=val
```

or equivalently `NL=val` (normalized length, requires `F=val` frequency).

**Parameters:**

| Parameter | Description                        | Unit | Required |
|-----------|------------------------------------|------|----------|
| Z0        | Characteristic impedance           | Ohm  | yes      |
| TD        | Propagation delay                  | s    | yes*     |
| NL        | Normalized electrical length       | —    | alt      |
| F         | Frequency at which NL is defined   | Hz   | w/ NL    |

**Example:**
```spice
T1  in+  in-  out+  out-  Z0=50  TD=1n
```

---

## O — LTRA Lossy Transmission Line

**Element prefix:** `O`

Roychowdhury-Pederson convolution model. Per-unit-length RLGC parameters.

**Instance line:**
```
Oname  in+  in-  out+  out-  mname
```

**Model card (.MODEL) — type LTRA:**

| Parameter | Description                          | Unit    | Default |
|-----------|--------------------------------------|---------|---------|
| R         | Resistance per unit length           | Ohm/m   | 0       |
| L         | Inductance per unit length           | H/m     | 0       |
| G         | Conductance per unit length          | S/m     | 0       |
| C         | Capacitance per unit length          | F/m     | 0       |
| LEN       | Total line length                    | m       | 1       |

**Example:**
```spice
.MODEL COAX50 LTRA (R=0.5 L=250n C=100p LEN=0.1)
O1  in+  in-  out+  out-  COAX50
```

---

## U — Uniform RC Line

**Element prefix:** `U`

Distributed RC transmission line, expanded at parse time into `LUMPS`
series-R / shunt-C ladder segments.

**Instance line:**
```
Uname  in  out  gnd  mname  [L=val]  [LUMPS=n]
```

**Model card (.MODEL) — type URC:**

| Parameter | Description                    | Unit   | Default |
|-----------|--------------------------------|--------|---------|
| K         | Propagation constant           | —      | 1.5     |
| FMAX      | Maximum frequency of interest  | Hz     | 1e9     |
| RPERL     | Resistance per unit length     | Ohm/m  | 1000    |
| CPERL     | Capacitance per unit length    | F/m    | 1e-9    |
| ISPERL    | Saturation current per length  | A/m    | 0       |

**Example:**
```spice
.MODEL RCLINE URC (RPERL=500 CPERL=2n FMAX=100MEG)
U1  vbus  vout  0  RCLINE  L=100u  LUMPS=10
```

---

## W (Wlossy) — Frequency-Domain Lossy Line

**Element prefix:** `W`

Xyce W-element: frequency-domain tabulated lossy line (S/Y/Z parameter file).
Currently a stub that falls back to an LTRA approximation with placeholder R/L/C
values until full tabulated-parameter interpolation is implemented (Wave U.6).

**Instance line:**
```
Wname  in+  in-  out+  out-  mname
```

**Model card (.MODEL) — type W or LTRA (stub):**
Same parameters as LTRA above. Full tabulated-file support pending.

---

## PORT — S-Parameter Port

**Element prefix:** `PORT`

HSPICE S-parameter excitation port. Internally expanded to a Thevenin equivalent:
voltage source in series with a reference impedance resistor.

**Instance line:**
```
PORTname  n+  n-  [Z0=val]  [DC=val]  [AC=mag[,phase]]
```

**Parameters:**

| Parameter | Description                   | Unit | Default |
|-----------|-------------------------------|------|---------|
| Z0        | Reference impedance           | Ohm  | 50      |
| DC        | DC bias voltage               | V    | 0       |
| AC        | AC excitation magnitude       | V    | 1       |

Used with `.SP` analysis for S-parameter simulation.

**Example:**
```spice
PORT1  rf_in  0  Z0=50  AC=1
PORT2  rf_out 0  Z0=50
.SP LIN 101 1MEG 10GIG
```

---

*For Verilog-A device models loaded via OSDI (OpenVAF), see `crates/osdi/` and
`scripts/build_va_models.sh`.*
