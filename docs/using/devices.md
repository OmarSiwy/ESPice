# Devices and models

Every device in ESPice, from the resistor to BSIM4, is a Verilog-A model.
The sources live in
[`models/`](https://github.com/OmarSiwy/ESPice/tree/main/models) and are
compiled into the simulator at build time, so a built-in model and a model
you load yourself run through the same code.

## Built-in devices

| Class | Devices | Cards |
|---|---|---|
| Passives | resistor, capacitor, inductor, mutual inductance | `R`, `C`, `L`, `K` |
| Sources | independent V and I, VCVS, VCCS, CCCS, CCVS, behavioural B (V, I and charge forms), Laplace, pole-zero and delay E/G forms | `V`, `I`, `E`, `G`, `F`, `H`, `B` |
| Switches | voltage- and current-controlled | `S`, `W` |
| Transmission lines | lossless `T`, LTRA (`O`), TXL (`Y`), coupled CPL lines of 2 to 4 conductors (`P`), uniform RC (`U`) | `T`, `O`, `Y`, `P`, `U` |
| HSPICE data elements | S-parameter blocks of 1 to 4 ports, W-element lines of 1 to 4 conductors | `S`, `W` in the HSPICE dialect |
| Diode | junction diode | `D` |
| BJT | Gummel-Poon, VBIC 1.3 (4 terminal), HICUM/L2 | `Q` |
| MOSFET | MOS levels 1, 2, 3, 6, 9; BSIM1, BSIM2, BSIM3, BSIM4; BSIM-SOI, B3SOI-FD, B3SOI-DD; HiSIM2, HiSIM-HV; PSP 103; VDMOS | `M` |
| Other FETs | JFET, JFET2, MESFET, MESA, HFET1, HFET2 | `J`, `Z` |

The `O`, `Y` and `P` cards run exact transcriptions of ngspice's LTRA, TXL
and CPL algorithms. Two approximate line models, `lossy_tline` and
`coupled_tlines`, also ship; the only card that uses one is an `O` card
for a static RG line (no L or C), which gets `lossy_tline`. A lossless LC
`O` card runs as a `T` line.

## Model type and LEVEL

A semiconductor card names a `.model`, whose type and `LEVEL` (1 when left
out) choose the device. The tables follow ngspice's `inpdomod.c`.

**MOSFETs** (`.model name NMOS|PMOS (LEVEL=n ...)`):

| LEVEL | Model |
|---|---|
| 1 | MOS1, Shichman-Hodges |
| 2 | MOS2 |
| 3 | MOS3 |
| 4 | BSIM1 |
| 5 | BSIM2 |
| 6 | MOS6 |
| 8, 49 | BSIM3 |
| 9 | MOS9 |
| 10, 58 | BSIM-SOI |
| 14, 54 | BSIM4 (Cogenda VA-BSIM48) |
| 55 | B3SOI-FD |
| 56 | B3SOI-DD |
| 68 | HiSIM2 |
| 73 | HiSIM-HV |
| 1040 | PSP 103 (ngspice has no PSP level; this is the number VACASK-derived decks use) |

`.model name VDMOS(...)` selects VDMOS whatever the level, and
`.model name psp103va(...)`, the name ngspice loads PSP 103 under as OSDI,
selects the built-in PSP 103. A PSP card that sets `SWNQS` to a nonzero
value runs the non-quasi-static build, which carries four times the
unknowns per instance.

**BJTs** (`.model name NPN|PNP (LEVEL=n ...)`): 1 and 2 are Gummel-Poon, 4
and 9 VBIC 1.3, 8 HICUM/L2.

**Diodes** (`.model name D`): levels 1 and 3, the SPICE junction diode.

**JFETs** (`NJF`, `PJF`): 1 is JFET, 2 JFET2.

**MESFETs and HFETs** (`NMF`, `PMF`, and `NHFET`, `PHFET` on an N card): 1
is MESFET, 2 to 4 MESA, 5 HFET1, 6 HFET2.

A LEVEL outside these tables (B3SOI-PD at 57, SOI3 at 60, or any other
number) is refused with `UnsupportedDevice` and a warning naming the
level. ESPice never substitutes a different model.

## Model licences

ESPice is Apache-2.0, but the model files keep the licences of the code
they come from, indexed in
[`models/LICENSES.md`](https://github.com/OmarSiwy/ESPice/blob/main/models/LICENSES.md).
Most are BSD or royalty-free. One is not: `models/bsim4va.va`, the BSIM4
behind `LEVEL=14` and `54`, is Cogenda's VA-BSIM48 under CC-BY-NC 4.0, so a
commercial user must replace it with a commercially licensed BSIM4.

## Your own Verilog-A { #your-own-verilog-a }

A deck loads a Verilog-A module at run time with `.hdl`, and an `N` card
instantiates it by module name, with its parameters as `key=value` pairs:

```text
--8<-- "examples/hdl_divider.sp"
```

`vres.va`:

```verilog
--8<-- "examples/vres.va"
```

```sh
espice hdl_divider.sp --rawfile hdl.txt --format=print
```

```text
loader: compiling 'vres' (./vres.va) — first load, cached afterwards
Divider with a Verilog-A resistor: 3 devices
  Operating Point: 1 points, 3 variables
```

`v(out)` is 0.75 V: the 3k Verilog-A resistor under the 1k R1.

`.include` of a file ending in `.va`, `.vams` or `.veriloga` loads it the
same way, and a Verilog-1364 design (`.v`, `.sv`, or the `.verilog` card)
works too. A `.model` card can name the module as its type
(`.model myres vres r=3k`), and an instance then names the model.

ESPice compiles the source itself, with the VerA compiler, into a shared
library. The first load of a model takes a few seconds and needs:

- the Zig compiler ESPice was built with (0.17.0) on `PATH`, or its path in
  `$ZIG` (the Nix package sets this for you);
- a release build of ESPice (any `-Doptimize` except `Debug`, which cannot
  load the library);
- the evaluator sources that `zig build` installs in `share/espice/` next to
  `bin/espice`. The Nix package includes them.

Builds are cached by content under `$ESPICE_CACHE/hdl`, else
`$XDG_CACHE_HOME/espice/hdl`, else `~/.cache/espice/hdl`, so a later run of
an unchanged model starts at once. The cache key covers the model and every
file it includes, with comments and whitespace stripped: a comment-only
edit reuses the build, any code edit recompiles.

When a model does not compile, VerA's diagnostics (file, line, error code)
print and the deck fails. An instance parameter the module does not
declare, or a card with the wrong number of nodes, is an error
(`UnknownParameter`, `WrongNodeCount`). An internal net of the module
appears in the results as `v(<instance>#<net>)`, the name ngspice gives an
OSDI device's internal node.

### OSDI is not loaded

ESPice never loads OSDI binaries. A `pre_osdi` or `.osdi_include` card,
including `pre_osdi` inside a `.control` block, is an error,
`OsdiUnsupported`, whose message names the card to use instead:

```text
error: netlist: pre_osdi model.osdi: espice does not load OSDI binaries; load the Verilog-A source with .hdl "model.va"
```

If you have the `.osdi` file you almost certainly have, or can get, the
Verilog-A source it was compiled from: replace the OSDI line with
`.hdl "model.va"`. For PSP 103, the built-in model already answers
`.model ... psp103va`, so delete the OSDI line.

The browser playground cannot compile Verilog-A, so `.hdl` examples run
only with the command-line ESPice.
