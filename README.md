# ESPice

A SPICE circuit simulator written in Zig. Netlists in, 24 kinds of analysis out,
with device models compiled from Verilog-A at build time instead of hand-ported
into the simulator.

```sh
espice my_circuit.sp --rawfile out.raw
espice my_circuit.sp --format=touchstone --rawfile out.s2p
espice my_circuit.sp --jobs=8 --backend=cuda
```

Status: version 0.1.0, pre-release. It runs real netlists and is checked against
ngspice and VACASK on every fixture, but the conformance suite is not yet a
release gate. See [Accuracy and performance](#accuracy-and-performance) for
exactly what has been measured.

## Why this one

**Verilog-A is the source of truth.** 39 device models live in `models/` as
`.va` files and are compiled by [VerA](https://github.com/OmarSiwy/VerA) during
`zig build`. Adding a model means writing Verilog-A, not patching the simulator.
The LTRA, TXL and coupled-line models are the exception and stay native Zig: the
Verilog-A routes for those cards dropped convolution kernels and fell back to a
two-conductor modal approximation, so the native paths are kept until a
replacement passes the same numerical comparisons.

**The same device code runs on CPU and GPU.** Kernels are emitted once by
[Gompute](https://github.com/OmarSiwy/Gompute) and built for the host, CUDA and
HIP from one source, so a GPU run is not a separate code path that can drift.

**Independent analyses run in parallel.** Queries form a DAG; `--jobs=N` runs the
ready frontier concurrently, and `--plan` prints the DAG without solving
anything.

**It is a library too.** `include/espice.h` exposes the C ABI, so the circuit
`Problem` and its results can be driven from another language.

## Install

```sh
git clone https://github.com/OmarSiwy/ESPice
cd ESPice
nix develop          # toolchain: Zig 0.16 and the GPU deps
zig build            # builds the app and the device kernels for the detected arch
```

The only dependencies are Zig 0.16 and two pinned git dependencies in
`build.zig.zon`: [VerA](https://github.com/OmarSiwy/VerA) for the Verilog-A and
Verilog frontends and the device contract, and
[Gompute](https://github.com/OmarSiwy/Gompute) for the GPU kernels. A fresh
clone builds on its own.

If you are co-developing VerA or Gompute, point that entry back at a local
`.path` while you work and restore the pin before you push. A pinned build
resolves to the package cache and will not see your sibling checkout.

## Usage

```
Usage: espice [OPTION]... FILE...
  -b, --batch                 Run all queries (default)
  -r, --rawfile=FILE          Result destination
      --format=FMT            binary|ascii|csv|touchstone|psf|fsdb|sst2|citi|print
      --backend=BE            cpu|auto|cuda|hip (default cpu)
      --gpu                   Require an available GPU
      --jobs=N                Maximum parallel queries (default 1)
      --print-dag             Print the next query frontier before running
      --plan                  Print the DAG without running analyses
      --timing-in-depth       Time preparation, queries, and individual steps
      --tokenizer=FMT         ngspice|hspice|spectre
  -v, --version               Version
```

## What is supported

**Analyses.** `op`, `dc`, `ac`, `tran`, `noise`, `tran_noise`, `pnoise`, `pss`,
`pac`, `pxf`, `qpss`, `hb`, `envelope`, `matex`, `sp`, `stb`, `pz`, `tf`,
`dcmatch`, `sens`, `disto`, `four`, `mc`, `temp`. That is a wider set than the
open-source simulators ESPice is measured against.

**Devices.** BSIM1/2/3/4, BSIM-SOI, HiSIM2, HiSIM-HV, HICUM/L2, VBIC 1.3 4T,
MOS levels 1/2/3/6/9, VDMOS, JFET, MESFET, HFET, diode, BJT, the passives and
controlled sources, switches, and transmission lines (`tline`, `lossy_tline`,
`coupled_tlines`, plus the native LTRA, TXL and coupled-LTRA models).

**Netlist dialects.** ngspice, hspice, spectre.

**Output formats.** Binary and ASCII raw, CSV, Touchstone, PSF, FSDB, SST2,
CITIfile, and SPICE-style print.

## Accuracy and performance

Every claim here comes from a run you can reproduce. Nothing in this section is
estimated.

The suite is 616 netlists under `tests/fixtures/`, each with a checked-in
`.expected.json`, spread across 34 categories from `op` and `tran` through
`qpss`, `pxf` and `stb`. `zig build bench` runs each deck through ESPice,
ngspice and VACASK, compares every shared output column by name, and reports
speed and agreement side by side:

```sh
nix develop .#benchmarking              # adds ngspice and VACASK
zig build bench -- --iters 9 --out results.md
```

The report is one row per fixture with three timings (median of N runs after a
warm-up, process startup and output included) and three verdicts, one per engine
pair: `agree`, `DIFFER`, or `incomplete`.

### Preparation, September 2026

One measured before/after, from indexing voltage-source names during binding and
cutting `PatternBuilder.radixSort` work. Medians of `zig build bench`, startup
and output included; ESPice, ngspice and VACASK agreed on both.

| Fixture | Runs | Before, ms | After, ms |
|---|---:|---:|---:|
| `op/controlled_source_scaling.sp` | 9 | 36.761 | 22.541 |
| `stress/scaling_resistor_grid_100x100.sp` | 7 | 90.336 | 102.385 |

The grid case got slower. It is printed here because it did: the radix change is
an instruction-count win, not a wall-time one. Under Callgrind on a
topology-equivalent driver, the grid fell from 11,944,431 to 6,602,513
instructions (44.7% fewer) and a 100k RC ladder from 73,456,908 to 68,480,580
(6.8% fewer), and those are instructions, not elapsed time. Full method,
paired-sample ranges and binary hashes:
[docs/Problem/preparation-performance.md](docs/Problem/preparation-performance.md).

### What is not claimed

The host fixture suite scored 492, 494 and 518 out of 616 on one unchanged tree,
while the emitted device code stayed byte-identical. The suite moves on its own,
so no pass rate is quoted as a conformance number until that is fixed. Docs
under `docs/` carry per-area status labels; a model appearing in a dispatch table
does not establish complete SPICE conformance.

## Project structure

```
├── src/
│   ├── frontend/     # Netlist parsing and circuit construction
│   ├── analysis/     # The analysis drivers; solvers/ is private to it
│   ├── problem/      # The owning API, and the C ABI behind include/espice.h
│   ├── output/       # Result writers
│   └── main.zig      # CLI
├── models/           # Verilog-A device sources, compiled at build time
├── tests/            # 616 fixtures, the cross-module suites and the bench runner
├── docs/             # Design notes and measured evidence
└── ref/              # SIMD strategy reference
```

`frontend` and `analysis` are siblings; neither imports the other. `problem`
composes both plus `output`, and `main` sees only `problem` and `output`.

Build steps beyond the defaults: `zig build test` runs every suite, and
`zig build --help` lists the per-area test steps (`test-solvers`,
`test-frontend`, `test-output`, and the rest).

## Why the name

The pyramids were built long ago from scratch, were ahead of their time, and
were built to last. This simulator is not ahead of its time, but it is built to
last.
