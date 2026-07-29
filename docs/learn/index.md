# Learn SPICE

This part teaches SPICE from nothing, using ESPice to run every example.
It starts with one source and two resistors and ends with noise, periodic
steady state and Monte Carlo. Each chapter builds on the one before, so read
them in order the first time.

| Chapter | You learn |
|---|---|
| [1. A first circuit](first-circuit.md) | the netlist file, nodes and ground, element cards, values, `.op` |
| [2. Sources](sources.md) | DC, AC and time-varying sources; controlled and behavioural sources |
| [3. The four core analyses](analyses.md) | `.op`, `.dc`, `.ac`, `.tran`, initial conditions |
| [4. Semiconductor models](models.md) | `.model`, diodes, BJTs, MOSFETs and their `LEVEL`s |
| [5. Subcircuits](subcircuits.md) | `.subckt`, instance parameters, `.include` and `.lib` |
| [6. Parameters and sweeps](parameters.md) | `.param`, expressions, `.step` |
| [7. Measurements](measure.md) | `.measure`: delays, peaks, crossings, averages |
| [8. Noise and periodic analyses](noise-periodic.md) | `.noise`, `.pss`, `.pac`, `.hb` |
| [9. Monte Carlo](monte-carlo.md) | `.mc`, `agauss`, `MONTE=` sweeps |

## Running the examples

Every example is a complete netlist. Save it to a file and run it:

```sh
espice divider.sp
```

ESPice prints a one-line summary per analysis on stderr: how many points
and how many variables (columns) each result has. To see the numbers, write
the results to a file. `--format=print` gives a plain text table:

```sh
espice divider.sp --rawfile divider.txt --format=print
cat divider.txt
```

Without `--format`, `--rawfile` writes an ngspice binary raw file, which
anything that reads ngspice raw files can open (ngspice's own `load`
command, for one). [Output](../using/output.md) lists every format.

All the examples are also in the repository under
[`docs/examples/`](https://github.com/OmarSiwy/ESPice/tree/main/docs/examples).

Each chapter ends with exercises. Try them before opening the answers;
editing a working deck and predicting the result is how SPICE sticks.
