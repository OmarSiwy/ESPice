# Diagnostics and errors

When a deck fails, ESPice prints what went wrong on stderr and exits with
status 1. The last line is always `Error: <file>: <ErrorName>`; the lines
before it usually say which card and why. Warnings (`warning: ...`) and
notes (`note: ...`) do not stop the run.

```text
error: analysis: .ac dec 10 100: InvalidAnalysisArguments
Error: bad_args.sp: InvalidAnalysisArguments
```

## Reading the deck

| Error | Cause | Fix |
|---|---|---|
| `FileNotFound` | the deck, an `.include`, a `.lib` file or a data file does not exist | paths resolve against the directory of the file that names them |
| `ParseError` | a card ESPice cannot read: a missing node or value, an unbalanced parenthesis, a keyword where a node belongs | check the card's syntax in the [reference](reference.md) |
| `UnsupportedCard` | a dot card or element form ESPice does not simulate; the line is printed | see [what is not supported](dialects.md#what-is-not-supported-or-differs) |
| `UnresolvedParameter` | an `R`, `C` or `L` value names a parameter no `.param` defines | define it, or check its spelling and scope |
| `OsdiUnsupported` | `pre_osdi` or `.osdi_include` | load the Verilog-A source with `.hdl`; see [Verilog-A](devices.md#osdi-is-not-loaded) |
| `UnsupportedDevice` | a `.model` LEVEL with no built-in model; a warning names it | see the [LEVEL tables](devices.md#model-type-and-level) |
| `LibrarySectionNotFound`, `InvalidLibrarySection` | `.lib file section` names a section the file does not have | check the section names inside the library |
| `IncludeDepthExceeded` | includes nested more than 32 deep, usually a file including itself | |

```text
error: netlist: unsupported card: .foo 1 2
Error: bad_card.sp: UnsupportedCard
```

```text
warning: devices: MOSFET LEVEL 57 needs model 'b3soipd', which is not in the device catalog
Error: bad_level.sp: UnsupportedDevice
```

A common `ParseError`: in an E, F, G or H card the word right after the
output nodes is first checked against the behavioural keywords (`poly`,
`value`, `table`, `laplace`, `pole`, `delay`, `vcr`, `vccap`, `vol`,
`cur`, ...). A control node named `pole` turns the card into a POLE source
and the rest of the line no longer parses. Rename the node.

## Building the circuit

| Error | Cause |
|---|---|
| `FloatingNode` | a node, or a group of nodes, has no DC path to ground: only capacitors, or nothing, connect it |
| `VoltageSourceLoop` | voltage sources (and inductors) form a loop that breaks Kirchhoff's voltage law, such as two different sources in parallel |
| `InvalidParameterValue` | a value out of its allowed range, such as a URC model's `K` |
| `UnknownParameter`, `WrongNodeCount` | a Verilog-A instance sets a parameter its module does not declare, or has the wrong number of nodes |

```text
error: topology: a node has no DC path to ground (capacitor-only island) — the operating point is not unique
Error: divider.sp: FloatingNode
```

```text
error: topology: 'v2' closes an inconsistent voltage-source/inductor loop (-1 V of KVL violation)
Error: bad_short.sp: VoltageSourceLoop
```

## Analysis cards

| Error | Cause |
|---|---|
| `InvalidAnalysisArguments` | wrong number of arguments, a negative or zero step, an unknown keyword |
| `UnsupportedFrequencySweep` | a sweep type other than `dec`, `oct`, `lin` (or `poi`) |
| `AnalysisNodeNotFound` | the card's output node does not exist, or is ground |
| `AnalysisSourceNotFound` | the card names a source (or probe) the deck does not have |
| `MissingAnalysisCard` | an HSPICE form that borrows another card's settings, and that card is missing: `.noise v(out) src` needs an `.ac`, `.fft` a `.tran`, `.snac` an `.sn` |
| `UnsupportedAnalysisOutput` | an output form the analysis cannot give, such as `i(...)` in `.pz v(out) src` |

```text
error: analysis: .tf v(b) V9: AnalysisSourceNotFound
Error: bad_source.sp: AnalysisSourceNotFound
```

## Simulation

| Error | Cause |
|---|---|
| `SingularMatrix` | the circuit matrix cannot be factored: usually a floating sub-circuit the topology check missed, or a device with zero conductance everywhere |
| `TimestepTooSmall` | the transient step fell below its minimum without converging: a discontinuity too sharp for the tolerances, or a model misbehaving |
| `OpDidNotConverge` | the operating point failed even after gmin and source stepping |
| `HbDidNotConverge`, `QpssDidNotConverge`, `PzDidNotConverge`, `EnvelopeDidNotConverge`, `PacDidNotConverge` | the named analysis did not converge |
| `OscillatorDidNotStart` | an autonomous `.pss` or `.hbosc` found no oscillation |

For convergence trouble:

- Give the solver a starting point with `.nodeset`, or start a transient
  from `.ic` values with `uic`.
- Raise the iteration limits: `.options itl1=500 itl4=50`.
- Loosen `reltol` (`.options reltol=1e-2`) to see whether the circuit
  converges at all, then tighten it back.
- For transients, cap the step (`tmax` on `.tran`, or `.options delmax=`)
  so sharp edges are not jumped over, or switch the integrator with
  `.options method=gear`.
- Run with `--timing-in-depth` to see the Newton iteration counts of each
  query.

## Output

| Error | Cause |
|---|---|
| `NotSParameterData` | `--format=touchstone` or `citi` on a result that is not S-parameters |
| `NoPorts` | an S-parameter format on an `.sp` with no ports |
| `FormatLimitExceeded` | a result too large for the format, such as more than 64 variables in `sst2` |
| `DeliveryFailed` | writing the output file failed; the line after it says why (`Output error: AccessDenied`) |

## Measurements

A `.meas` card whose event never happens prints an error and the run
carries on. The exit status is unaffected:

```text
Error: measure  t50 : out of interval
```

## Verilog-A loading

| Message | Cause |
|---|---|
| `CompilerGone` | the Zig compiler could not be started for `.hdl`: put Zig 0.17.0 on `PATH` or set `ZIG` |
| VerA diagnostics (file, line, error code) | the Verilog-A source does not compile |

See [Verilog-A](devices.md#your-own-verilog-a) for the requirements.

## Why does my deck fail?

**It works in ngspice.** Check, in this order:

1. Is it written for HSPICE? Run it with `--tokenizer=hspice`. Quoted
   expressions, `.alter`, `.data`, `P` ports and `$` comments after a blank
   are HSPICE habits.
2. Does it load OSDI, or rely on a `.control` script? ESPice runs the
   analysis cards only; replace the OSDI line with `.hdl` and move the
   script's analyses into the deck as cards.
3. Does it use a model LEVEL ESPice does not have? The warning names it.
4. Look up the card in [what is not supported, or differs](dialects.md#what-is-not-supported-or-differs).

**The numbers differ from ngspice.** Small differences in the last digits
are normal for any two simulators: time steps, iteration counts and
rounding differ. Large ones are worth a look. The
[dialects page](dialects.md#what-is-not-supported-or-differs) lists every
place ESPice deliberately does something else. Two to check first: the
HSPICE dialect runs the circuit at 25 °C by default, not 27 °C, and ESPice
uses `.ic` only with `uic`.

**A model name is misspelled.** Check that every element names a model
that exists: in testing, a `D` card naming an undefined model ran with
default diode parameters and no warning.

**Nothing is written.** Without `--rawfile`, ESPice writes no result file;
the summary and the `.meas` results are the whole output.
