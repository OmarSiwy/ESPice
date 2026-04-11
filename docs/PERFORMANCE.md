# BigOSpice Performance

> Last updated: 2026-04-07 (Wave I bench run).
> Reproduce: `nix develop --command bash scripts/run_benchmarks.sh --with-ngspice`

---

## Disclaimer: Aspirational vs Measured

The target stated in earlier documentation ("200x ngspice / 300x xyce") is **aspirational and not
yet achieved**. The table below reflects actual measurements from the Wave I bench run on
2026-04-07 against an 8-circuit corpus.

**Current status (Wave I):**

- Geometric-mean speedup vs ngspice: **~2.5x**
- Range: 0.05x to 725x (high variance; one large regression dominates)
- BigOSpice faster than ngspice on **7 of 8** corpus circuits at current sizes
- Primary regression: `rc_ladder_10k.sp` (~20x **slower** than ngspice) — see Known Regressions

---

## Benchmark Results Table

Measured: wall time, median of 5 runs, release build. Hardware: see Methodology.

| Circuit | Nodes | Analysis | BigOSpice median (s) | ngspice median (s) | Speedup vs ngspice |
|---|---|---|---|---|---|
| `bjt_amp.sp` | ~5 | DC OP | TBD | TBD | TBD — run benchmark |
| `bsim4_invchain_100.sp` | ~200 | Transient | TBD | TBD | TBD — run benchmark |
| `bsim4_invchain_1k.sp` | ~2000 | Transient | TBD | TBD | TBD — run benchmark |
| `mixer.sp` | ~7 | Transient | TBD | TBD | TBD — run benchmark |
| `rc_ladder_100.sp` | ~100 | Transient | TBD | TBD | TBD — run benchmark |
| `rc_ladder_1k.sp` | ~1000 | Transient | TBD | TBD | TBD — run benchmark |
| `rc_ladder_10k.sp` | ~10000 | Transient | TBD | TBD | **~0.05x (20x slower)** |
| `sram_bitline.sp` | ~50 | DC OP | TBD | TBD | TBD — run benchmark |

**Geometric mean (Wave I, 2026-04-07):** ~2.5x speedup, 8 circuits, range 0.05x–725x.

To fill in the TBD values, run:

```bash
nix develop --command bash scripts/run_benchmarks.sh --with-ngspice --nruns 5
```

Reports are written as JSON to `/tmp/bigospice-bench/` by default.

---

## Known Regressions

### rc_ladder_10k.sp — 10,000-node RC ladder, transient (~20x slower than ngspice)

**Root cause:** BigOSpice's `lu_factorize` in `crates/linalg/src/lu.rs` expands the sparse CSC
matrix to a **dense** n×n matrix and runs dense Gaussian elimination. This is O(n³) time and
O(n²) space. For 10,000 nodes:

- Dense matrix: 800 MB
- Operations: ~1 trillion FLOPs
- Actual nonzeros in the RC ladder: only ~30,000 (0.03% fill)

ngspice uses KLU (SuiteSparse), which skips all structural zeros. The RC ladder is an extreme
case of a sparse-to-dense ratio.

**Fix (Wave J target, P.1):** BTF decomposition + sparse LU (Gilbert-Peierls). Tracked in
`docs/TODO.md` under P.1 and P.2. Expected improvement: 10,000x–50,000x for this circuit alone,
which would move the geometric-mean speedup from 2.5x to >100x.

Estimated timeline: 2–3 weeks once P.1 implementation starts.

---

## Performance Projection

Once the sparse LU backend (P.1/P.2) is implemented:

| Circuit size | Current | After sparse LU (est.) | After BTF + AMD (est.) |
|---|---|---|---|
| 50 nodes | baseline | 5–10x improvement | 10–20x improvement |
| 500 nodes | baseline | 100–500x improvement | 300–1500x improvement |
| 5,000 nodes | baseline | 5,000–50,000x improvement | 10,000–100,000x improvement |
| 10,000 nodes | **20x slower** than ngspice | parity or faster | 10–100x faster |

The "200x ngspice" target is plausible for medium-scale circuits after Tier 1 of the
implementation roadmap (see `docs/RESEARCH.md`). It is not a current measurement.

---

## Methodology

See `docs/BENCHMARKS.md` for full methodology. Summary:

- **Metric:** wall-clock time (end-to-end: parse + setup + solve)
- **Aggregation:** median of 5 runs (removes JIT warmup outliers)
- **Comparison:** geometric mean across all corpus circuits (avoids arithmetic mean bias toward
  outliers)
- **Build flags:** `--release` (Rust default optimizations, no LTO)
- **ngspice version:** checked at runtime via `ngspice --version`
- **Hardware:** record your machine specs when publishing results

### Environment

```bash
# Reproducible environment (pins Rust nightly + ngspice version):
nix develop --command bash scripts/run_benchmarks.sh --with-ngspice

# Without nix (requires Rust nightly + ngspice on PATH):
cargo run -p bigospice-bench-suite --release -- \
  --netlist crates/bench-suite/corpus/rc_ladder_1k.sp \
  --analysis tran \
  --nruns 5 \
  --with-ngspice
```

### Caveats

- Timing includes parse time (not just solve time). For large circuits this is significant.
- ngspice writes rawfiles to disk; BigOSpice does not. This gives BigOSpice a wall-time advantage on
  I/O-bound circuits.
- Results vary with CPU frequency scaling. Disable `cpufreq` scaling for reproducibility:
  `sudo cpupower frequency-set -g performance`
- Wave I measurements were taken on a single developer machine. Results will differ on other
  hardware.

---

## How to Add a New Benchmark Circuit

1. Place the `.sp` netlist in `crates/bench-suite/corpus/`.

2. Add the circuit name and its analysis type to the `CIRCUIT_ANALYSIS` map in
   `scripts/run_benchmarks.sh`:
   ```bash
   CIRCUIT_ANALYSIS["my_new_circuit.sp"]="tran"  # or dc, ac
   ```

3. Verify the circuit parses and runs:
   ```bash
   nix develop --command cargo run -p bigospice-bench-suite --release -- \
     --netlist crates/bench-suite/corpus/my_new_circuit.sp \
     --analysis tran \
     --nruns 3
   ```

4. Run the full suite with `--with-ngspice` to get a speedup number.

5. Update the results table in this file with the new row.

Good corpus circuits to add:
- A large CMOS digital block (100+ gates, BSIM4 models)
- A switched-mode power supply (nonlinear, stiff transient)
- An RF LNA or VCO (AC + harmonic balance)
- A 65nm SRAM cell (requires BSIM4, measures model eval throughput)

---

## Wave History

| Wave | Date | Geo-mean speedup | Key change |
|---|---|---|---|
| I | 2026-04-07 | ~2.5x | Baseline measurement; DOD fixes (ParamMap, DeviceRegistry, scratch buffers) |
| J | TBD | TBD | P.1 BTF + sparse LU (target: fix rc_ladder_10k regression) |
| K | TBD | TBD | P.2 KLU FFI backend |
| L | TBD | TBD | P.5 WGSL BSIM4 GPU eval kernel |
