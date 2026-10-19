# Devices and models

Every device in ESPice, from the resistor to BSIM4, is a Verilog-A model.
ESPice's own sources live in
[`models/`](https://github.com/OmarSiwy/ESPice/tree/main/models). Third-party
compact models (PSP, JUNCAP2, BSIM-IMG, BSIM-CMG, BSIM-BULK, BSIM-SOI,
L-UTSOI, HiSIM, HICUM, Mextram, ASM-HEMT, ASM-ESD, MVSG, DIODE_CMC, R2/R3_CMC,
MOSVAR) are built from their upstream release exactly as published:
`build.zig.zon` lists each release's download link and hash. Releases from
si2's registration form, whose links expire, are mirrored byte for byte on
[ESPice's `models-si2-2026-10` release](https://github.com/OmarSiwy/ESPice/releases/tag/models-si2-2026-10).
Everything is compiled into the simulator at build time, so a built-in model
and a model you load yourself run through the same code.

## Built-in devices

| Class | Devices | Cards |
|---|---|---|
| Passives | resistor, capacitor, inductor, mutual inductance | `R`, `C`, `L`, `K` |
| Sources | independent V and I, VCVS, VCCS, CCCS, CCVS, behavioural B (V, I and charge forms), Laplace, pole-zero and delay E/G forms | `V`, `I`, `E`, `G`, `F`, `H`, `B` |
| Switches | voltage- and current-controlled | `S`, `W` |
| Transmission lines | lossless `T`, LTRA (`O`), TXL (`Y`), coupled CPL lines of 2 to 4 conductors (`P`), uniform RC (`U`) | `T`, `O`, `Y`, `P`, `U` |
| HSPICE data elements | S-parameter blocks of 1 to 4 ports, W-element lines of 1 to 4 conductors | `S`, `W` in the HSPICE dialect |
| Diode | junction diode, JUNCAP2 200.6.2, DIODE_CMC 3.0, ASM-ESD 101.1 | `D`, `N` |
| BJT | Gummel-Poon, VBIC 1.3 (4 terminal), HICUM/L2 3.2.0, HICUM/L0 2.1.0, Mextram 505.6 (with and without self-heating) | `Q`, `N` |
| MOSFET | MOS levels 1, 2, 3, 6, 9; BSIM1, BSIM2, BSIM3, BSIM4; BSIM-SOI 101.0, B3SOI-FD, B3SOI-DD; BSIM-IMG 103.1, BSIM-CMG 112.1, BSIM-BULK 107.2.1; L-UTSOI 102.9; HiSIM2, HiSIM_HV 2.5.1, HiSIM_SOI 1.5, HiSIM_SOTB 1.3; PSP 103.8.2 and 104.1 (QS, NQS and self-heating); MOSVAR 1.4; VDMOS | `M`, `N` |
| HEMT | ASM-HEMT 101.6, MVSG_CMC 5.0 | `N` |
| Resistor | R2_CMC 1.0.2, R3_CMC 1.1.2 | `N` |
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
| 72 | BSIM-CMG |
| 73 | HiSIM-HV |
| 76 | L-UTSOI |
| 77 | BSIM-BULK |
| 78 | BSIM-IMG |
| 1040 | PSP 103 (ngspice has no PSP level; this is the number VACASK-derived decks use) |

ngspice has no built-in level for BSIM-CMG, L-UTSOI, BSIM-BULK or BSIM-IMG;
those four are HSPICE's numbers.

`.model name VDMOS(...)` selects VDMOS whatever the level (N-channel only:
a `pchan` model is refused). An `N` card whose
`.model` type is a model's Verilog-A module name, the name ngspice loads it
under as OSDI, selects the built-in model: `psp103va`, `pspnqs103va`,
`psp103tva`, `psp104va`, `pspnqs104va`, `psp104tva`, `juncap200`, `bsimimg`,
`bsimcmg`, `bsimbulk`, `l_utsoi`, `hisimhv_va`, `hisimsoi_va`,
`hisimsotb_va`, `mosvar`, `hicuml2va`, `hicuml0va`, `bjt505`, `bjt505t`,
`diode_cmc`, `asmesd`, `asmesd_dio`, `r2_cmc`, `r3_cmc`, `mvsg_cmc` and
`asmhemt`. A PSP
103 card that sets `SWNQS` to a nonzero value runs the non-quasi-static
build, which carries four times the unknowns per instance.

**BJTs** (`.model name NPN|PNP (LEVEL=n ...)`): 1 and 2 are Gummel-Poon, 4
and 9 VBIC 1.3, 6 Mextram 505 (HSPICE's number), 8 HICUM/L2.

**Diodes** (`.model name D`): levels 1 and 3, the SPICE junction diode; 6
JUNCAP2 (HSPICE's number).

**JFETs** (`NJF`, `PJF`): 1 is JFET, 2 JFET2.

**MESFETs and HFETs** (`NMF`, `PMF`, and `NHFET`, `PHFET` on an N card): 1
is MESFET, 2 to 4 MESA, 5 HFET1, 6 HFET2.

A LEVEL outside these tables (B3SOI-PD at 57, SOI3 at 60, or any other
number) is refused with `UnsupportedDevice` and errors naming the level
and the card. So is a card whose model is another element's type (a `D`
card on an `NPN` model), as ngspice's "incorrect model type". ESPice never
substitutes a different model. P-type MESA (`PMF` at levels 2 to 4) is
refused too: the model has no polarity parameter.

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

A source named more than once, by several `.lib` sections or `.include`s,
compiles and loads once.

A model's display tasks print to standard output: `$strobe`, `$display`,
`$write`, `$warning` and `$info` once at each accepted point (the operating
point, each DC sweep point, each transient step), never for a Newton
iterate or a rejected step, with `%m` as the instance name. A model with

```verilog
$strobe("%m vdrop = %g", V(p, n));
```

prints `n1 vdrop = 0.35` for instance `N1` at its operating point. `$debug`
prints at the accepted points too, not per Newton iteration, and
`$monitor` does not print (VerA warns W0850). The built-in models keep
their display tasks silent.

A `.hdl` file compiles as Verilog-AMS 2023, as most built-in models do. A
2.3-era model that declares a name 2023 reserves (BSIM-CMG 112's `expm1`)
must rename it or wrap the module in `` `begin_keywords "VAMS-2.3" `` …
`` `end_keywords ``. When a model does not compile, VerA's diagnostics (file, line,
error code) print and the deck fails. An instance parameter the module does
not declare, or a card with more nodes than the module has ports, is an error
(`UnknownParameter`, `WrongNodeCount`). A card that omits trailing ports
leaves them floating, as ngspice does for an OSDI card (BSIM-CMG's `t`). An
internal net or a floating port of the module appears in the results as
`v(<instance>#<net>)`, the name ngspice gives an OSDI device's internal node.

### VPI applications { #vpi-applications }

A system function or task that no standard defines, such as
`$espice_gain(2.0)` or a testbench's `$my_monitor(V(out))`, is a VPI system
function (LRM §12.32): a VPI application defines it, and VerA warns W0852
naming it. Load the application, a C shared library that exports
`vlog_startup_routines` (LRM §12.33.2), with `--vpi app.so` or, in the deck,
`.options vpi="app.so"` (relative to the deck):

```c
#include "vpi_user.h"   /* VerA's src/vpi/vpi_user.h */

static PLI_INT32 gain_calltf(p_cb_data cb)
{
  vpiHandle call = vpi_handle(vpiSysTfCall, NULL);
  s_vpi_value v = { .format = vpiRealVal };
  vpi_get_value(vpi_handle_by_index(call, 1), &v);
  vpi_put_value(call, &v, NULL, vpiNoDelay);   /* the call's value */
  return 0;
}

static void register_gain(void)
{
  static char name[] = "$espice_gain";
  s_vpi_analog_systf_data d = { .type = vpiAnalogSysFunc, .sysfunctype = vpiRealFunc,
                                .tfname = name, .calltf = gain_calltf };
  vpi_register_analog_systf(&d);
}

void (*vlog_startup_routines[])(void) = { register_gain, 0 };
```

Build it as a shared library with its `vpi_*` symbols left undefined
(`zig cc -shared -I<VerA>/src/vpi gain.c -o gain.so`); they resolve
against the `espice` executable when it loads the application. The ESPice
library (the C API, an embedding) loads no application: there it is
`VpiUnavailable`.

What ESPice supports, and what it refuses by name:

- a calltf that returns a value and its partials (`derivtf`, LRM §12.22.1)
  and puts output arguments (LRM §12.22.2);
- the LRM §12.31.3 analog callbacks in `.op` and `.tran` (#198):
  acbInitialStep, acbAcceptedPoint and acbFinalStep on each accepted
  solution; acbAbsTime and acbElapsedTime force a transient solution at
  their time; a non-zero acbConvergenceTest, or §12.36
  vpiRejectTransientStep, backs up to half the step; §12.36
  vpiTransientFailConverge solves the step again;
- a second module in one run that calls a `$systf` is refused,
  `VpiSecondSystfModule`.

These limits return a value instead of refusing, so check for them in your
application:

- the other analyses (`.dc`, `.ac`, ...) deliver no analog callbacks;
- `vpi_get_value` on a net that is not one of the call's arguments reads
  NaN;
- one module per run may call a `$systf`, and calltf must be stateless:
  every instance of the module shares one call object, so state kept per
  call handle is shared by all of them.

A call no application registered is an error, `UnregisteredSystf`, naming
the call, since the LRM gives it no value. A task call whose value nothing
reads is refused the same way for now. Once VerA marks task calls, it will
run as a no-op with the warning `$name: no VPI application registered (LRM
12.32); the call does nothing`.

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
