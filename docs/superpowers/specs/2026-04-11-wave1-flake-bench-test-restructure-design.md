# Wave 1 Design: flake.nix + Bench/Test Restructure

**Date:** 2026-04-11
**Scope:** Agent 1 (flake.nix) + Agent 2 (benches/tests restructure) from TODO.md
**Status:** Approved — ready for implementation planning

---

## 1. flake.nix Architecture

### Two devShell outputs

| Command | Contents |
|---------|----------|
| `nix develop` | `devShells.default` — Rust toolchain + build deps only (suitesparse, openblas, cmake, mold, dev tools) |
| `nix develop .#full` | `devShells.full` — default + ngspice + xyce-parallel + VACASK |

`packages.default` (the bigospice binary) has no simulator dependencies.

### VACASK nix build

VACASK is not in nixpkgs. We write a `pkgs.stdenv.mkDerivation` that:
- Fetches source from Codeberg (`arpadbuermen/VACASK`)
- Builds with cmake (reuses `suitesparse` already in the flake for KLU)
- Produces a `vacask` binary on `$PATH` inside `.#full`

### Simulator availability flag

The `.#full` `shellHook` exports `BIGOSPICE_HAVE_SIMS=1`. Benches and tests gate on this env var at runtime — they silently skip simulator comparisons when running in the minimal shell or CI without sims.

---

## 2. Crate Restructure

### Removed workspace crates

`crates/bench-suite` and `crates/test-harness` are deleted entirely. Removed from `Cargo.toml` workspace members and all dependency lists.

### Test structure

All existing `tests/integration/*.rs` files are deleted and replaced with organized categories. Each category is its own `[[test]]` entry in `Cargo.toml` enabling targeted runs (e.g. `cargo test --test analysis`).

```
tests/
  common/
    mod.rs        ← parse_netlist_str, run_dc_op, run_transient, and other harness helpers
    fixtures.rs   ← netlist constants + fixture file loader
    golden.rs     ← golden file diff utilities
  suite/
    linalg.rs     ← sparse LU, KLU, BTF correctness
    solver.rs     ← Newton-Raphson, convergence, robustness, gmin, pseudo-transient
    device.rs     ← BSIM3/4, BJT, diode, JFET, MOSFET, VBIC, MESFET, switches
    analysis.rs   ← DC OP, DC sweep, transient, AC, noise, FFT, HB, PZ, TF, sens
    parser.rs     ← netlist parsing, tokenizer, extensions, poly sources
    cache.rs      ← incremental, step cache, compiled eval
    io.rs         ← rawfile, CSV, Touchstone, HSPICE round-trips
    cosim.rs      ← Verilator/digital co-simulation
    osdi.rs       ← OSDI VA golden tests
    golden.rs     ← all golden comparisons (ngspice golden, temp, BSIM goldens, etc.)
    compat.rs     ← compatibility: alter, control scripts, e/g value forms, options
```

Each test file in `tests/suite/` includes common utilities via `#[path = "../common/mod.rs"] mod common;` — required because each `[[test]]` is a separate binary and Rust resolves modules relative to the source file.

New categories drop in as new files — no changes to existing categories required.

### Bench structure

All existing `benches/*.rs` files are deleted and replaced with a single organized entry point.

```
benches/
  common/
    mod.rs        ← shared criterion helpers, timing utilities
    translate.rs  ← SPICE→Spectre translator for VACASK (see Section 3)
    runner.rs     ← subprocess runner for all 4 simulators (see Section 3)
  suite.rs        ← single criterion entry point; wires all categories via criterion_main!
  categories/
    linalg.rs     ← sparse LU, KLU, BTF, Woodbury, matrix ops
    solver.rs     ← Newton-Raphson, convergence, gmin stepping
    device.rs     ← device eval (BSIM3/4, BJT, diode, MOSFET, etc.)
    analysis.rs   ← DC OP, DC sweep, transient, AC, noise, FFT, HB
    parser.rs     ← netlist parse throughput, tokenizer
    cache.rs      ← incremental/step cache, compiled eval
    compare.rs    ← 4-way executable comparison (gates on BIGOSPICE_HAVE_SIMS)
    accuracy.rs   ← speed + accuracy parity vs ngspice/xyce/VACASK: numeric error (max_abs, max_rel, RMSE) + wall-time speedup ratio per circuit, reported together so perf and correctness are always co-located
    end_to_end.rs ← full pipeline: parse → solve → output
```

Each category file exposes a single `pub fn register(c: &mut Criterion)` function. `suite.rs` calls all of them:

Since `suite.rs` lives at `benches/suite.rs`, Rust resolves modules relative to that file. Use explicit `#[path]` attributes:

```rust
// benches/suite.rs
#[path = "common/mod.rs"] mod common;
#[path = "categories/linalg.rs"] mod linalg;
#[path = "categories/solver.rs"] mod solver;
// ...

fn main() {
    let mut c = Criterion::default().configure_from_args();
    categories::linalg::register(&mut c);
    categories::solver::register(&mut c);
    // ...
    c.final_summary();
}
```

---

## 3. SPICE→Spectre Translator + Subprocess Runner

### Translator (`benches/common/translate.rs`)

Converts a SPICE netlist string to Spectre syntax for VACASK. Line-by-line pattern matching over the common benchmark subset:

| SPICE | Spectre |
|-------|---------|
| `.op` | `op` |
| `.tran 1n 1u` | `tran tran stop=1u step=1n` |
| `.ac dec 10 1k 1g` | `ac ac start=1k stop=1g dec=10` |
| `V1 1 0 DC 5` | `V1 (1 0) vsource dc=5` |
| `R1 1 2 1k` | `R1 (1 2) resistor r=1k` |
| `M1 d g s b NMOS` | `M1 (d g s b) nmos` |

Unsupported constructs log a warning and the VACASK run is marked `Skipped` for that circuit — no panic, no bench failure.

### Fair timing: translation happens before the timer starts

Translation is a **pre-computation step** that runs before any benchmark timer is started. The Spectre netlist is written to a temp file once, then the VACASK timer starts. This ensures wall-time measurements compare only simulation time across all four simulators.

```rust
// In compare.rs setup (outside b.iter()):
let spice_netlist = load_fixture("rc_ladder.sp");
let spectre_netlist = translate::spice_to_spectre(&spice_netlist);  // pre-computed
let vacask_input = write_temp_file(&spectre_netlist);               // pre-computed

// Inside b.iter() — only simulation time measured:
group.bench_function("vacask/rc_ladder", |b| {
    b.iter(|| runner::run(Simulator::Vacask, &vacask_input))
});
```

### Subprocess runner (`benches/common/runner.rs`)

```rust
pub enum Simulator { Bigospice, Ngspice, Xyce, Vacask }

pub struct RunResult {
    pub sim: Simulator,
    pub wall_secs: f64,
    pub output: Option<RawfileData>,  // parsed waveform for numeric diff
    pub status: RunStatus,            // Ok / Failed / Skipped(reason)
}

pub fn run(sim: Simulator, netlist_path: &Path) -> RunResult
```

- `Bigospice` — for `[[test]]` binaries, path from `CARGO_BIN_EXE_bigospice` (set by Cargo). For `[[bench]]`, resolved via `env!("CARGO_MANIFEST_DIR")` + `/target/release/bigospice` (bench harness does not set `CARGO_BIN_EXE_*`).
- `Ngspice`, `Xyce`, `Vacask` — require `BIGOSPICE_HAVE_SIMS=1`; return `Skipped` silently otherwise

`compare.rs` collects results from all 4, prints a comparison table, and asserts numeric agreement within tolerance for correctness.

---

## 4. Cargo.toml Changes

- Remove `crates/bench-suite` and `crates/test-harness` from `[workspace] members`
- Remove all `bigospice-bench-suite` and `bigospice-test-harness` entries from `[dev-dependencies]`
- Replace old `[[test]]` entries with new category-based entries
- Replace old `[[bench]]` entries with single `suite` entry:
  ```toml
  [[bench]]
  name = "suite"
  harness = false
  ```

---

## 5. What Does NOT Change

- All 13 remaining library crates (`core`, `compute`, `device`, `linalg`, `solver`, `cache`, `analysis`, `parser`, `utility`, `io`, `osdi`, `digital`, `cosim`) are untouched
- Existing test fixtures in `tests/fixtures/` and `tests/golden/` stay in place
- Existing SPICE netlist corpus in `tests/regression/` and `tests/external/` stays in place
- `scripts/run_benchmarks.sh` is updated to use `nix develop .#full`

---

## 6. Out of Scope for Wave 1

- Agent 3 (lib.rs API surface audit) — Wave 2
- Code quality, profiling, docs, CI/CD — Waves 3–4
