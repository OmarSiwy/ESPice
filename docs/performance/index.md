# Accuracy and performance

ESPice is checked two ways: against its own numeric corpus, and against
ngspice and VACASK running the same decks.

## Accuracy

`tests/fixtures/` holds 799 netlists in 43 categories, each with a
checked-in `.expected.json` oracle. `zig build test` scores every deck
against its oracle: 797 pass. The other 2 are known gaps, marked in the
deck with a `* KNOWN GAP:` comment (two VBIC model versions).

## Speed against ngspice and VACASK

`zig build bench` runs the corpus through ESPice, ngspice 45 and VACASK.
It times each deck (median of 3 runs after a warm-up, process startup
included) and compares every output column the simulators share, by name.

Every number and chart in this part comes from two bench reports, checked
in beside the charts: [corpus report](bench/corpus/results.md) and
[post-layout report](bench/postlayout/results.md).
`tools/bench_plot.py` reads a report and writes the charts and the tables
below; nothing here is typed by hand. Both reports were measured on
2026-10-04 on an Intel i9-14900HX, ESPice on the CPU backend, from the
pre-1.0 tree (the binary reported `espice 0.1.0`). The reports name the
simulator versions but not the ESPice commit. Absolute times move with
machine load from run to run, so compare simulators within one report.

### Against circuit size

Each point is one deck. The x axis is its device count after subcircuit
expansion.

![Wall time against circuit size, all decks](bench/corpus/all.png)

![ESPice speedup over ngspice and VACASK](bench/corpus/speedup.png)

"Agree / differ" counts the decks where both simulators produced the
shared columns and the comparison reached a verdict. The second table is
the eight largest decks:

--8<-- "performance/bench/corpus/summary.md"

Most decks finish in tens of milliseconds, so at the small end the speedup
is mostly process startup. The large circuits are where the comparison
means something.

### Per analysis

One chart per analysis type, on the same axes:

| | | |
|---|---|---|
| ![op](bench/corpus/op.png) | ![dc](bench/corpus/dc.png) | ![ac](bench/corpus/ac.png) |
| ![tran](bench/corpus/tran.png) | ![noise](bench/corpus/noise.png) | ![sp](bench/corpus/sp.png) |
| ![pss](bench/corpus/pss.png) | ![hb](bench/corpus/hb.png) | ![pz](bench/corpus/pz.png) |

Neither ngspice nor VACASK ran the periodic analyses (pss, pac, pnoise, hb,
qpss) here, so those charts show ESPice alone.

??? note "The other 35 charts, mixed-analysis decks included"

    | | | |
    |---|---|---|
    | ![ac+dc+tran](bench/corpus/ac+dc+tran.png) | ![ac+pz](bench/corpus/ac+pz.png) | ![acmatch](bench/corpus/acmatch.png) |
    | ![dc+tran](bench/corpus/dc+tran.png) | ![dcmatch](bench/corpus/dcmatch.png) | ![dcxf](bench/corpus/dcxf.png) |
    | ![disto](bench/corpus/disto.png) | ![envelope](bench/corpus/envelope.png) | ![fft](bench/corpus/fft.png) |
    | ![four](bench/corpus/four.png) | ![hbac](bench/corpus/hbac.png) | ![hblin](bench/corpus/hblin.png) |
    | ![hbnoise](bench/corpus/hbnoise.png) | ![hbxf](bench/corpus/hbxf.png) | ![lstb](bench/corpus/lstb.png) |
    | ![matex](bench/corpus/matex.png) | ![mc](bench/corpus/mc.png) | ![op+ac](bench/corpus/op+ac.png) |
    | ![op+dc](bench/corpus/op+dc.png) | ![op+hb](bench/corpus/op+hb.png) | ![op+pz](bench/corpus/op+pz.png) |
    | ![op+tran](bench/corpus/op+tran.png) | ![op+tran+ac](bench/corpus/op+tran+ac.png) | ![pac](bench/corpus/pac.png) |
    | ![phasenoise](bench/corpus/phasenoise.png) | ![pnoise](bench/corpus/pnoise.png) | ![pxf](bench/corpus/pxf.png) |
    | ![qpss](bench/corpus/qpss.png) | ![sens](bench/corpus/sens.png) | ![stb](bench/corpus/stb.png) |
    | ![temp](bench/corpus/temp.png) | ![tf](bench/corpus/tf.png) | ![tf+sens](bench/corpus/tf+sens.png) |
    | ![tran_noise](bench/corpus/tran_noise.png) | ![trannoise](bench/corpus/trannoise.png) |  |

## Post-layout circuits

`zig build bench-postlayout` generates synthetic extracted netlists:
standard cells as subcircuits, RC-segmented signal nets, coupling
capacitors and a meshed power grid. There are four families (inverter
chains, ring oscillators, random logic, a 6T SRAM array), each with BSIM4
and PSP103 transistors, from 1k to 100k cells. ngspice 45 has no PSP103, so
it runs only the BSIM4 decks. Each run has a 300 s limit; a missing bar
means the simulator timed out or could not run the deck.

![Post-layout decks](bench/postlayout/bars.png)

![Post-layout wall time against size](bench/postlayout/all.png)

--8<-- "performance/bench/postlayout/summary.md"

The VACASK differences are open: for PSP103 there is no third simulator
here to say which side is right. A deck with no ESPice time did not finish
within the limit.

Per family:

| | |
|---|---|
| ![chain_bsim4](bench/postlayout/chain_bsim4.png) | ![chain_psp103](bench/postlayout/chain_psp103.png) |
| ![ring_bsim4](bench/postlayout/ring_bsim4.png) | ![ring_psp103](bench/postlayout/ring_psp103.png) |
| ![logic_bsim4](bench/postlayout/logic_bsim4.png) | ![logic_psp103](bench/postlayout/logic_psp103.png) |
| ![sram_bsim4](bench/postlayout/sram_bsim4.png) | ![sram_psp103](bench/postlayout/sram_psp103.png) |

![Post-layout speedup](bench/postlayout/speedup.png)

## What is not claimed

The bench is a differential comparison against two simulators, so it covers
only decks all three can express. "Could not run it" is mostly decks the
other simulator has no counterpart for: `.ic`, `.trannoise`, `u`/`o`/`t`/`z`
device cards, HSPICE-only syntax, and PWL sources, which this VACASK build
aborts on. Having a model in the dispatch table does not establish full SPICE
conformance for it.

## Reproduce the numbers

The benchmarking shell has ngspice, VACASK, OpenVAF, matplotlib and the
profilers:

```sh
nix develop .#benchmarking
zig build bench -- --iters 3              # writes zig-out/benchmark-results.md
zig build bench-postlayout -- --iters 3   # writes zig-out/postlayout-results.md
```

Redraw the charts from those reports:

```sh
cp zig-out/benchmark-results.md docs/performance/bench/corpus/results.md
cp zig-out/postlayout-results.md docs/performance/bench/postlayout/results.md
python3 tools/bench_plot.py docs/performance/bench/corpus/results.md tests/fixtures docs/performance/bench/corpus
python3 tools/bench_plot.py docs/performance/bench/postlayout/results.md zig-out/postlayout docs/performance/bench/postlayout
```

`tools/bench_plot.py` writes `all.png`, `speedup.png`, one chart per
analysis type (per `family_model` for the post-layout report, plus
`bars.png`) and `summary.md`, the tables this page includes. The x axis is the device count
after subcircuit expansion, the y axis the median wall time, both log.

Run the benchmarks on a quiet machine. Wall time under load is not
comparable between runs.

### External suites

`zig build bench-suites` fetches external SPICE suites at pinned
revisions into `zig-out/suites/` (nothing is vendored) and times ESPice on
them against ngspice and VACASK, like `bench`. The report goes to
`zig-out/suites-results.md`. `-Dsuite=NAME` runs one suite:

```sh
zig build bench-suites -Dsuite=cmcqa
```

Each suite has a README under `tests/suites/<name>/` with its sources, pins,
licences and known gaps. `cmcqa` is 3,218 single-device decks from the
public CMC QA sets (HICUM/L2 2.4.0, PSP 103) and the GF180MCU BSIM4
regression, each with its reference result.
