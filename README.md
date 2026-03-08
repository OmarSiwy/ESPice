# ESPice

A SPICE circuit simulator written in Zig. Netlists in, 24 kinds of analysis out,
with device models compiled from Verilog-A at build time instead of hand-ported
into the simulator.

```sh
espice my_circuit.sp --rawfile out.raw
espice my_circuit.sp --format=touchstone --rawfile out.s2p
espice my_circuit.sp --jobs=8 --backend=cuda
```

Pre-release, version 0.1.0. It runs real netlists and every fixture is checked
against ngspice and VACASK, but the conformance suite is not a release gate yet.
[Accuracy and performance](#accuracy-and-performance) says what has actually
been measured.

## Why this one

**Verilog-A is the source of truth.** The 39 device models live in `models/` as
`.va` files and are compiled by [VerA](https://github.com/OmarSiwy/VerA) during
`zig build`. Adding a model means writing Verilog-A, not patching the simulator.

**One device kernel, three targets.** [Gompute](https://github.com/OmarSiwy/Gompute)
emits each kernel once and builds it for the host, CUDA and HIP, so a GPU run is
not a separate code path that can drift from the CPU one.

**Analyses run in parallel.** Queries form a DAG. `--jobs=N` runs the ready
frontier concurrently, and `--plan` prints the DAG without solving anything.

**It is a library too.** `include/espice.h` exposes the C ABI, so the circuit
and its results can be driven from another language.

## Install

```sh
git clone https://github.com/OmarSiwy/ESPice
cd ESPice
nix develop     # Zig 0.16 and the GPU toolchain
zig build       # the app, and device kernels for the detected arch
```

[VerA](https://github.com/OmarSiwy/VerA) and
[Gompute](https://github.com/OmarSiwy/Gompute) are pinned git dependencies in
`build.zig.zon`, so a fresh clone builds on its own. Nothing else is required.

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

## Analyses

| Domain | Analyses |
|---|---|
| DC | `op`, `dc`, `dcmatch`, `sens`, `tf`, `temp` |
| Small-signal | `ac`, `noise`, `sp`, `stb`, `pz`, `disto` |
| Transient | `tran`, `tran_noise`, `four`, `envelope`, `matex` |
| Periodic steady state | `pss`, `pac`, `pnoise`, `pxf`, `qpss`, `hb` |
| Statistical | `mc` |

## Devices

| Class | Models |
|---|---|
| MOSFET | BSIM1, BSIM2, BSIM3, BSIM4, BSIM-SOI, HiSIM2, HiSIM-HV, MOS levels 1/2/3/6/9, VDMOS |
| Bipolar | BJT, VBIC 1.3 4T, HICUM/L2 |
| Other FETs | JFET, JFET2, MESFET, HFET1, HFET2 |
| Passives | resistor, capacitor, inductor, coupled inductor, diode |
| Sources | independent V and I, VCVS, VCCS, CCVS, CCCS, behavioural B-source |
| Switches | voltage- and current-controlled |
| Transmission lines | `tline`, `lossy_tline`, `coupled_tlines`, and native LTRA, TXL and coupled-LTRA |

The transmission lines are the one place native Zig beats the Verilog-A route:
the `.va` versions dropped convolution kernels and fell back to a two-conductor
modal approximation, so the native models stay until a replacement passes the
same numerical comparisons.

## Formats

| | |
|---|---|
| Netlist dialects | ngspice, hspice, spectre |
| Output | binary raw, ASCII raw, CSV, Touchstone, PSF, FSDB, SST2, CITIfile, print |

## Accuracy and performance

`tests/fixtures/` holds 616 netlists across 34 categories, each with a
checked-in `.expected.json`. `zig build bench` runs every deck through ESPice,
ngspice and VACASK, compares each shared output column by name, and reports
speed and agreement side by side:

```sh
nix develop .#benchmarking
zig build bench -- --iters 3 --out results.md
```

Everything below is one such run, all 616 fixtures, against ngspice 45 and
VACASK 2026 on the same machine.

### Agreement

| Compared with | agree | DIFFER | incomplete | other engine could not run it |
|---|---:|---:|---:|---:|
| ngspice 45 | 379 | 26 | 29 | 182 |
| VACASK 2026 | 232 | 17 | 0 | 367 |

The large "could not run it" columns are mostly decks the other simulator has no
counterpart for: `.ic`, `.trannoise`, `u`/`o`/`t`/`z` device cards, and PWL
sources, which this VACASK build aborts on.

Two independent runs of the whole suite returned all 1,848 verdicts identical
(616 fixtures, three engine pairs each), with wall times within a few percent.

### Speed

Of the 439 decks ESPice and ngspice both completed, ESPice was faster on 320,
median ratio 0.66. Against VACASK it was 0.47 over 267 shared decks. Read those
medians narrowly: most fixtures finish in 10 to 30 ms, which is mostly process
startup on all three engines.

The `stress/` set is where the difference is real. Milliseconds, median of 3
runs after a warm-up:

| Fixture | ESPice | ngspice | VACASK | vs ngspice |
|---|---:|---:|---:|---|
| `scaling_resistor_grid_100x100` | 72.4 | 1784.8 | 120.6 | agree |
| `scaling_resistor_grid_32x32` | 9.8 | 29.9 | 23.9 | agree |
| `scaling_resistor_grid` | 6.8 | 17.2 | 16.1 | agree |
| `scaling_rc_ladder_100k` | 2899.1 | 5632.6 | 10039.3 | agree |
| `scaling_rc_ladder_1k` | 40.1 | 50.7 | 89.1 | agree |
| `sweep_opamp_wl_5000` | 1017.7 | 4009.9 | 2563.7 | agree |
| `sweep_opamp_wl_200` | 51.8 | 30.7 | 85.8 | agree |
| `scaling_divider_chain` | 8.0 | 15.6 | 15.4 | agree |
| `scaling_parallel_inverters_100` | 48.6 | 56.1 | 143.6 | agree |
| `scaling_parallel_inverters_2000` | 842.4 | 1124.8 | 3082.8 | DIFFER |
| `scaling_inverter_chain_256` | 432.9 | 365.4 | 2966.7 | DIFFER |
| `scaling_inverter_chain_4k` | 106312.8 | 6802.8 | 79323.3 | DIFFER |
| `vacask_rc` | 4190.7 | 1581.4 | 1286.7 | agree |
| `vacask_graetz` | 5433.2 | 2780.0 | n/a | agree |
| `vacask_mul` | 2976.7 | 1512.4 | n/a | DIFFER |
| `vacask_ring` | n/a | 169.9 | n/a | ESPice produced nothing |

Large sparse DC and sweep problems are the strong case: the 100x100 resistor
grid is 24x faster than ngspice, the 5000-point opamp sweep 4x, the 100k RC
ladder 2x. Long MOS transient runs are the weak case, and the worst of them is
very bad: `scaling_inverter_chain_4k` takes 106 seconds against ngspice's 6.8,
and it disagrees, so that row is not even a like-for-like comparison. Three of
the four `vacask_*` decks are slower too, and `vacask_ring` produced no output
at all.

### A measured before and after

Indexing voltage-source names during binding, and cutting `PatternBuilder`
radix-sort work:

| Fixture | Runs | Before, ms | After, ms |
|---|---:|---:|---:|
| `op/controlled_source_scaling.sp` | 9 | 36.761 | 22.541 |
| `stress/scaling_resistor_grid_100x100.sp` | 7 | 90.336 | 102.385 |

The grid case got slower, and it is printed because it did. The radix change is
an instruction-count win, not a wall-time one: under Callgrind on a
topology-equivalent driver the grid fell 44.7% (11,944,431 to 6,602,513
instructions) and a 100k RC ladder 6.8% (73,456,908 to 68,480,580). Those are
instructions, not elapsed time. Method, paired-sample ranges and binary hashes
are in
[docs/Problem/preparation-performance.md](docs/Problem/preparation-performance.md).

### What is not claimed

The 379-of-405 agreement above is a differential comparison against two other
simulators, not a conformance score, and it only covers the decks all engines
can express. Separately, `zig build test` has scored 492, 494 and 518 out of 616
on one unchanged tree while the emitted device code stayed byte-identical. That
instability is in the host suite, not in the benchmark above, and until it is
fixed no pass rate is quoted as a release number. Per-area status labels live in
`docs/`; a model appearing in a dispatch table does not establish complete SPICE
conformance.

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

`zig build test` runs every suite. `zig build --help` lists the per-area steps
(`test-solvers`, `test-frontend`, `test-output`, and the rest).

Co-developing VerA or Gompute means pointing that entry in `build.zig.zon` back
at a local `.path` and restoring the pin before you push. A pinned build
resolves to the package cache and will not see your sibling checkout.

## Why the name

The pyramids were built long ago from scratch, were ahead of their time, and
were built to last. This simulator is not ahead of its time, but it is built to
last.
