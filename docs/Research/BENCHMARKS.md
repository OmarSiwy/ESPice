# BigOSpice Benchmark Methodology

> This document describes the corpus, measurement methodology, and statistical
> conventions used for all BigOSpice performance comparisons.
> For the actual numbers, see `docs/PERFORMANCE.md`.

---

## Table of Contents

1. [Corpus](#corpus)
2. [Measurement Methodology](#measurement-methodology)
3. [Statistical Conventions](#statistical-conventions)
4. [Comparison Methodology](#comparison-methodology)
5. [How to Reproduce](#how-to-reproduce)
6. [Accuracy Validation](#accuracy-validation)
7. [Adding Circuits](#adding-circuits)

---

## Corpus

The Wave I corpus contains 8 circuits chosen to stress different solver paths. All netlists are
in `crates/bench-suite/corpus/`.

### Circuit Descriptions

| File | Description | Nodes | Devices | Analysis | Stress |
|---|---|---|---|---|---|
| `bjt_amp.sp` | Common-emitter BJT amplifier | ~5 | 1 BJT, 3 R | DC OP | Small nonlinear NR convergence |
| `bsim4_invchain_100.sp` | Resistor/RC inverter chain, 100 stages | ~200 | 300 R/C | Transient | Medium-size linear transient |
| `bsim4_invchain_1k.sp` | Resistor/RC inverter chain, 1000 stages | ~2000 | 3000 R/C | Transient | Large linear transient; stamper throughput |
| `mixer.sp` | Passive diode mixer, RF stimulus | ~7 | 1 diode, 3 R/C | Transient | Nonlinear device, small circuit |
| `rc_ladder_100.sp` | RC ladder, 100 stages | ~100 | 200 R/C | Transient | Linear tridiagonal system |
| `rc_ladder_1k.sp` | RC ladder, 1000 stages | ~1000 | 2000 R/C | Transient | Tridiagonal scaling |
| `rc_ladder_10k.sp` | RC ladder, 10000 stages | ~10000 | 20000 R/C | Transient | **Primary regression target; dense LU bottleneck** |
| `sram_bitline.sp` | SRAM bitline RC discharge model | ~50 | 100 R/C | DC OP | Short RC chain, DC solve |

### What These Circuits Measure

- **RC ladders** (100/1k/10k): isolate the linear solver. Nearly tridiagonal sparse structure. The
  10k case is the primary benchmark for sparse vs dense LU performance difference.
- **Inverter chains** (100/1k): measure stamper throughput and linear transient integration step
  count. Device eval is trivial (R/C only).
- **BJT amp, mixer**: nonlinear NR convergence. Small enough that solver time is negligible;
  measures NR iteration count and device model evaluation speed.
- **SRAM bitline**: small RC, DC operating point. Fast circuit that measures overhead (parse,
  setup, teardown).

### Corpus Coverage Gaps (for future waves)

The Wave I corpus does not cover:
- BSIM4 MOSFET transistors (inverter chains use R/C proxies, not real BSIM4)
- AC analysis
- Stiff transient (SMPS, switching regulators)
- Large nonlinear circuits (SRAM arrays, ring oscillators)
- Circuits requiring pseudo-transient continuation for DC convergence

---

## Measurement Methodology

### What is Timed

Wall-clock time is measured from the start of `run_incspice_once()` to completion. This includes:

1. Netlist parse (SPICE tokens → `Circuit` data structure)
2. Device registry initialization
3. Analysis setup (config, initial conditions)
4. All Newton-Raphson iterations
5. Time integration loop (for transient)
6. Result collection

It **excludes**: process startup, binary loading, and report serialization.

For ngspice, wall time is measured from `Command::spawn()` to process exit, including ngspice's
own startup, parse, and raw-file write. This gives ngspice a slight disadvantage on I/O-heavy
runs; BigOSpice does not write rawfiles by default.

### Timing Implementation

```rust
// crates/bench-suite/src/perf.rs
let start = Instant::now();
// ... run analysis ...
let duration = start.elapsed();
```

`std::time::Instant` uses `CLOCK_MONOTONIC` on Linux, which is not affected by NTP adjustments
or system clock changes. It is **not** CPU-time; it measures wall time including OS scheduling
delays.

### Number of Runs

Default: 5 runs per circuit per simulator. The **median** is reported (not mean).

- Run 1 may include filesystem cache warming and Rust runtime initialization effects.
- Runs 2–5 are typically stable.
- Median of 5 eliminates the first-run outlier without requiring more runs.

For statistical confidence on microbenchmarks, increase with `--nruns 20` or more.

### Build Configuration

BigOSpice is built with `--release` (equivalent to `opt-level = 3`, no debug assertions). No LTO,
no PGO. ngspice is used as installed in the nix shell or system PATH.

To enable AVX2 auto-vectorization (may improve performance on supported hardware):

```bash
RUSTFLAGS="-C target-cpu=native" cargo run -p incspice-bench-suite --release -- ...
```

---

## Statistical Conventions

### Geometric Mean

All aggregate speedup numbers use the **geometric mean**, not the arithmetic mean.

**Why geometric mean:**
- Speedup ratios are multiplicative, not additive
- Arithmetic mean is biased toward large values; a single 725x outlier would dominate
- Geometric mean gives equal weight to ratios in log space, which is the correct space for
  comparing multiplicative speedups

**Formula:**

```
geometric_mean_speedup = exp( (1/N) * sum( ln(speedup_i) ) )
                       = (product of speedup_i) ^ (1/N)
```

Where `speedup_i = ngspice_time_i / incspice_time_i` for each circuit i.

**Example:** if BigOSpice is 10x faster on one circuit and 0.1x (10x slower) on another, the
arithmetic mean would be 5.05x (misleadingly positive), but the geometric mean is 1.0x
(correctly reflecting a wash).

### Range Reporting

In addition to the geometric mean, always report:
- Minimum speedup (worst case)
- Maximum speedup (best case)
- N (number of circuits included in the aggregate)

### Excluding Circuits from Aggregates

A circuit should be excluded from the geometric mean only if:
- BigOSpice fails to run it (status != "ok")
- The analysis type is not implemented in BigOSpice

Slow circuits (e.g. rc_ladder_10k) must **not** be excluded from the aggregate; they represent
real use cases and suppressing them would inflate the reported speedup.

---

## Comparison Methodology

### Same Netlist, Same Analysis

Both simulators receive the identical `.sp` file. Analysis parameters (tstep, tstop, npoints)
come from the `.tran` / `.ac` / `.op` statements in the netlist itself. No simulator-specific
tuning is applied.

### ngspice Invocation

```bash
ngspice -b -o /dev/null netlist.sp
```

The `-b` flag runs in batch mode (no interactive shell). Output is discarded; only wall time
is measured. The rawfile is written to a temporary directory and deleted after the run.

### Accuracy Validation

Each benchmark run optionally computes accuracy metrics against ngspice output. This catches
cases where BigOSpice is "fast" but wrong. See [Accuracy Validation](#accuracy-validation).

A circuit where BigOSpice has poor accuracy (max_rel_err > 1e-2 at any node) should be flagged in
the results and investigated before the speedup is reported as meaningful.

---

## How to Reproduce

### Full suite with ngspice comparison (canonical)

```bash
nix develop --command bash scripts/run_benchmarks.sh --with-ngspice --nruns 5
```

This uses the pinned nix environment (same Rust nightly, same ngspice version) to maximize
reproducibility across machines.

### Single circuit

```bash
nix develop --command cargo run -p incspice-bench-suite --release -- \
  --netlist crates/bench-suite/corpus/rc_ladder_10k.sp \
  --analysis tran \
  --nruns 5 \
  --with-ngspice \
  --report /tmp/rc_ladder_10k_bench.json
```

### Without nix (requires Rust nightly + ngspice on PATH)

```bash
cargo run -p incspice-bench-suite --release -- \
  --netlist crates/bench-suite/corpus/rc_ladder_1k.sp \
  --analysis tran \
  --nruns 5
```

### Disable CPU frequency scaling for reproducible timing

```bash
sudo cpupower frequency-set -g performance
nix develop --command bash scripts/run_benchmarks.sh --with-ngspice
sudo cpupower frequency-set -g powersave  # restore
```

### Record system info alongside results

```bash
echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
echo "RAM: $(free -h | awk '/^Mem:/ {print $2}')"
echo "Kernel: $(uname -r)"
echo "Rust: $(rustc --version)"
echo "ngspice: $(ngspice --version 2>&1 | head -1)"
```

---

## Accuracy Validation

The bench harness computes accuracy metrics when `--with-ngspice` is set. Both simulators run
the same netlist, then waveforms are compared point-by-point.

### Metrics

| Metric | Definition |
|---|---|
| `max_abs_err` | max |incspice_v - ngspice_v| across all nodes and time points |
| `max_rel_err` | max |incspice_v - ngspice_v| / (|ngspice_v| + 1e-12) |
| `rmse` | sqrt( mean( (incspice_v - ngspice_v)^2 ) ) |
| `pass_matrix` | bool array: does max_rel_err pass at tolerance [1e-6, 1e-4, 1e-3, 1e-2]? |

### Accuracy Tolerances

| Tolerance | Meaning |
|---|---|
| 1e-6 | SPICE-grade agreement (typical for DC OP on passive circuits) |
| 1e-4 | Acceptable for transient with identical timestep control |
| 1e-3 | Marginal; investigate cause |
| 1e-2 | Fail; BigOSpice result is likely wrong or using incompatible timestep |

Transient accuracy depends on timestep: BigOSpice and ngspice may use different adaptive
timestep algorithms, leading to different discretization error even when both are "correct".
A tolerance of 1e-4 is expected for linear circuits; 1e-3 for nonlinear circuits with
identical device models.

### Interpreting Accuracy Failures

If accuracy fails at 1e-2:
1. Check that BigOSpice's analysis parameters match the netlist (tstep, tstop, fstart, fstop)
2. Check that the device model parameters are read correctly (`--analysis dc` on the same
   circuit may pass even if `tran` fails)
3. Run with `RUST_LOG=debug` to inspect Newton-Raphson convergence

---

## Adding Circuits

See `docs/PERFORMANCE.md` for the step-by-step guide. Requirements for a new corpus circuit:

1. **Self-contained:** all device models defined inline (`.model` statements), no external
   include files
2. **Deterministic:** same result on every run with identical inputs
3. **Runnable by ngspice:** must run with `ngspice -b` without errors
4. **Representative:** targets a specific bottleneck or use case not covered by existing circuits
5. **Named descriptively:** `<topology>_<scale>.sp` format (e.g. `opamp_folded_cascode.sp`)

Place the file in `crates/bench-suite/corpus/` and add its analysis type to the
`CIRCUIT_ANALYSIS` map in `scripts/run_benchmarks.sh`.
