# Complete SPICE Device Model Reference

Every device a full SPICE simulator should support, with the **authoritative upstream source** (the lab that authors and releases the reference code) and its reference manual.

There are two tiers:

1. **CMC industry-standard compact models** — the advanced models foundry PDKs use. Each is authored by a specific institution. The _Verilog-A reference code defines the standard_; any simulator must reproduce its outputs.
2. **Intrinsic / primitive devices** — built into every SPICE since Berkeley SPICE3. No external standards body; the simulator's own manual is the reference.

---

## One-stop hub for all CMC models

**Si2 CMC Standard Models download form:** https://si2.org/cmc-standard-models/
Gives Verilog-A source **and** the technical manual for every _public_ CMC model. The newest betas are gated to CMC member companies for 18 months before public release.

---

## TIER 1 — CMC Industry-Standard Compact Models

### Bulk planar CMOS (MOSFET)

| Model                            | Latest std. ver. | Developer                                    | Source / Manual                            |
| -------------------------------- | ---------------- | -------------------------------------------- | ------------------------------------------ |
| BSIM-BULK (was BSIM6)            | 107.2.1          | UC Berkeley BSIM Group                       | https://bsim.berkeley.edu/models/bsimbulk/ |
| PSP                              | 104.0.1          | CEA-Leti (orig. NXP / Arizona / Delft)       | via Si2 form; CEA-Leti                     |
| HiSIM2                           | 3.2.0            | Hiroshima University (HiSIM Research Center) | https://www.hisim.hiroshima-u.ac.jp/       |
| BSIM4 (legacy bulk, C reference) | 4.8.3            | UC Berkeley BSIM Group                       | https://bsim.berkeley.edu/models/bsim4/    |
| BSIM3 (legacy bulk)              | 3.3.0            | UC Berkeley BSIM Group                       | https://bsim.berkeley.edu/models/bsim3/    |

### Planar SOI (silicon-on-insulator)

| Model                       | Latest std. ver. | Developer              | Source / Manual                           |
| --------------------------- | ---------------- | ---------------------- | ----------------------------------------- |
| L-UTSOI (Leti-UTSOI, FDSOI) | 102.8.0          | CEA-Leti               | via Si2 form; CEA-Leti                    |
| BSIM-SOI                    | 4.6.1            | UC Berkeley BSIM Group | https://bsim.berkeley.edu/models/bsimsoi/ |
| Symmetric BSIM-SOI          | 100.1.0          | UC Berkeley BSIM Group | https://bsim.berkeley.edu/models/bsimsoi/ |
| HiSIM_SOI                   | 1.5.0            | Hiroshima University   | https://www.hisim.hiroshima-u.ac.jp/      |
| HiSIM_SOTB                  | 1.3.0            | Hiroshima University   | https://www.hisim.hiroshima-u.ac.jp/      |

### Single & multi-gate 3D (FinFET / nanosheet / UTBB)

| Model                                   | Latest std. ver. | Developer              | Source / Manual                           |
| --------------------------------------- | ---------------- | ---------------------- | ----------------------------------------- |
| BSIM-CMG (common multi-gate, FinFET)    | 111.2.1          | UC Berkeley BSIM Group | https://bsim.berkeley.edu/models/bsimcmg/ |
| BSIM-IMG (independent multi-gate, UTBB) | 103.0.0          | UC Berkeley BSIM Group | https://bsim.berkeley.edu/models/bsimimg/ |

### High-voltage / LDMOS

| Model    | Latest std. ver. | Developer            | Source / Manual                      |
| -------- | ---------------- | -------------------- | ------------------------------------ |
| HiSIM_HV | 2.5.1            | Hiroshima University | https://www.hisim.hiroshima-u.ac.jp/ |

### Bipolar (BJT / HBT / SiGe)

| Model    | Latest std. ver. | Developer                     | Source / Manual                                                |
| -------- | ---------------- | ----------------------------- | -------------------------------------------------------------- |
| HICUM/L2 | 3.1.0            | Michael Schröter (TU Dresden) | https://www.iee.et.tu-dresden.de/iee/eb/hic_new/hic_intro.html |
| HICUM/L0 | 2.1.0            | Michael Schröter (TU Dresden) | https://www.iee.et.tu-dresden.de/iee/eb/hic_new/hic_intro.html |
| MEXTRAM  | 505.5.0          | Auburn University             | via Si2 form; Auburn SiGe group                                |

### GaN HEMT (high electron mobility transistor)

| Model    | Latest std. ver. | Developer                    | Source / Manual |
| -------- | ---------------- | ---------------------------- | --------------- |
| ASM-HEMT | 101.4.0          | Macquarie University         | via Si2 form    |
| MVSG_CMC | 4.0.0            | MIT / University of Waterloo | via Si2 form    |

### ESD diode

| Model   | Latest std. ver. | Developer            | Source / Manual |
| ------- | ---------------- | -------------------- | --------------- |
| ASM-ESD | 101.1.0          | Macquarie University | via Si2 form    |

### CMC models gated to members (exist, but not on the public form)

Passive/varactor/diode standards that are typically CMC-member-only:
**R2_CMC, R3_CMC** (resistors), **DIODE_CMC**, **MOSVAR** (MOS varactor), **JUNCAP2** (junction diode, usually bundled with PSP). Obtain via a foundry PDK or CMC membership.

---

## TIER 1b — Widely used standard models NOT currently CMC-administered

Every serious simulator still ships these; sources are the original authoring groups.

| Model                 | Type            | Developer             | Source / Manual                                   |
| --------------------- | --------------- | --------------------- | ------------------------------------------------- |
| VBIC                  | Bipolar         | Colin McAndrew et al. | https://www.designers-guide.org/vbic/             |
| EKV 2.6               | MOSFET          | EPFL                  | https://www.epfl.ch/labs/iclab/ (EKV model pages) |
| MOS Model 9 / 11 / 20 | MOSFET (legacy) | NXP / Philips         | NXP compact model archive                         |
| Parker-Skellern       | JFET            | Macquarie University  | published model spec                              |

---

## TIER 2 — Intrinsic / Primitive Devices

Built into every SPICE engine from Berkeley SPICE3 onward. There is **no external standards body** — the canonical reference is the simulator's own manual.

**Reference documents:**

- Original Berkeley SPICE3 User's Guide / Manual (UC Berkeley EECS technical reports)
- ngspice manual (open implementation, very complete): https://ngspice.sourceforge.io/docs.html

### Passive elements

- **R** — Resistor (with temperature, optional semiconductor resistor model)
- **C** — Capacitor (with optional semiconductor capacitor model)
- **L** — Inductor
- **K** — Coupled (mutual) inductors / transformer

### Sources

- **V** — Independent voltage source
- **I** — Independent current source
- **E** — Voltage-controlled voltage source (VCVS)
- **F** — Current-controlled current source (CCCS)
- **G** — Voltage-controlled current source (VCCS)
- **H** — Current-controlled voltage source (CCVS)
- Behavioral sources (B-source / arbitrary expressions)

### Switches

- **S** — Voltage-controlled switch
- **W** — Current-controlled switch

### Transmission lines

- **T** — Lossless transmission line
- **O** — Lossy transmission line (LTRA)
- **U** — Uniform distributed RC line

### Semiconductor devices (built-in)

- **D** — Junction diode (Berkeley diode model)
- **Q** — BJT, Gummel-Poon model (Berkeley); also Ebers-Moll levels
- **J** — JFET (Berkeley levels 1–2)
- **Z** — MESFET (Berkeley level 1, plus others)
- **M** — MOSFET levels 1 (Shichman-Hodges), 2, 3 (Berkeley); BSIM1 (level 4), BSIM2 (level 5) early Berkeley models
- **VDMOS** — simple power-MOS model (in ngspice)

---

## How to actually use a Tier-1 model (write/compile path)

For any natively-Verilog-A model above:

1. Download the `.va` reference from the developer site or the Si2 form.
2. Compile with **OpenVAF** (https://openvaf.semimod.de) → produces a `.osdi` shared library.
3. Load the `.osdi` into ngspice; instantiate with an `N` device line in your netlist.

Note: **BSIM4 and BSIM3 reference code is C, not Verilog-A** (they predate the Verilog-A standardization). The newer BSIM family members (CMG, IMG, BULK, SOI 4.4+) are native Verilog-A and compile cleanly through OpenVAF.

Model _equations_ come from these sources; model _parameter values_ for a real process come from the foundry PDK, never from the model author.

When we write the models to bench them, we can bench them against their Verilog-A equivalent from here: https://github.com/dwarning/VA-Models
