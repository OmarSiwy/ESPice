# Benchmark harness

Timing + accuracy comparison of zpicey against ngspice on a fixture corpus.

## Usage

```
zig build bench -- [--iters N] [--filter CAT[/NAME]] [--no-ngspice] [--no-xyce] [--timeout S] [--list] [--out PATH] [--rtol 0.01]
```

- `--list` — print every discovered fixture and exit
- `--filter devices` — run only fixtures in the `devices` category
- `--filter devices/resistor` — run one fixture
- `--iters 20` — timed iterations per fixture (default 10)
- `--no-ngspice` — skip ngspice comparison
- `--no-xyce` — skip Xyce comparison
- `--timeout 600` — per-run timeout in seconds (default 300)
- `--rtol 0.005` — per-variable RMS pass threshold (default 1%)
- `--out results.md` — write markdown report (default `benchmark/RESULTS.md`)

## Fixtures

Every fixture is `benchmark/fixtures/<category>/<name>/circuit.sp`. If `circuit.sp` exists, it runs — no metadata files needed.

## What it measures

**Timing**: full process wall-clock (parse + solve + output), median of N runs.

**Memory**: peak RSS via `/usr/bin/time -v`, measured on a separate run.

**Accuracy**: parses both ngspice-format raw files, aligns node voltages by name, computes per-variable max and RMS relative error. Transient waveforms are compared via linear interpolation onto the ngspice time grid.

Pass criterion: worst-variable RMS ≤ rtol, max ≤ 10×rtol.

## VACASK comparison circuits

The `vacask/` fixtures reproduce the [VACASK benchmark suite](https://codeberg.org/arpadbuermen/VACASK/src/branch/main/benchmark): RC pulse (1M timesteps), Graetz rectifier, diode multiplier, 9-stage ring oscillator, and C6288 16×16 CMOS multiplier (10112 PSP MOSFETs, 25380 nodes).
