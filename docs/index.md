# ESPice

ESPice is a SPICE circuit simulator. It reads ngspice, HSPICE and Spectre
netlists and runs DC, AC, transient, noise, S-parameter, stability,
periodic steady-state, harmonic-balance and Monte Carlo analyses, 36
analysis types in all. Every device model, from the resistor to
BSIM4 and PSP, is Verilog-A compiled into the simulator, and you can load
your own with one `.hdl` line. Device evaluation can run on a CUDA or HIP
GPU, and the whole simulator is also a C library.

In one benchmark run over its 795-deck test corpus it was a median 3.3x
faster than ngspice and 3.5x faster than VACASK on the decks each could
run, and it agreed with ngspice on 424 of the 437 decks where the two
reached a verdict. The
[benchmarks](performance/index.md) have the details and the caveats.

## Quick start

Install it ([other ways](using/install.md)):

```sh
nix profile install github:OmarSiwy/ESPice
```

Save this as `rc.sp`:

```spice
--8<-- "examples/rc_lowpass.sp"
```

Run it:

```sh
espice rc.sp --rawfile rc.raw
```

```text
RC low-pass filter: 3 devices
  Operating Point: 1 points, 3 variables
  AC Analysis: 41 points, 4 variables
  Transient Analysis: 519 points, 4 variables
```

`rc.raw` is an ngspice raw file with all three results. Add
`--format=print` for plain text tables or `--format=csv` for a spreadsheet.

## Where to go next

| If you want to | Read |
|---|---|
| learn SPICE from the start | [Learn SPICE](learn/index.md) |
| run an existing ngspice or HSPICE deck | [Dialects](using/dialects.md), then [Diagnostics](using/diagnostics.md) |
| look up a card or element | [Language reference](using/reference.md), [Analyses](using/analyses.md) |
| know every command-line flag | [Command line](using/cli.md) |
| use your own Verilog-A model | [Devices and models](using/devices.md#your-own-verilog-a) |
| read the results in another tool | [Output](using/output.md) |
| simulate on a GPU | [GPU backend](using/gpu.md) |
| call ESPice from C or Zig | [Embedding ESPice](embed/c-api.md) |
| see how fast and how accurate it is | [Accuracy and performance](performance/index.md) |

ESPice is Apache-2.0. Its source, issues and releases are on
[GitHub](https://github.com/OmarSiwy/ESPice). The developer reference, on
how ESPice is built inside, is on
[DeepWiki](https://deepwiki.com/OmarSiwy/ESPice).
