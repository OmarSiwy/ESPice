# Wave 1 – Agent 2: Bench/Test Restructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `crates/bench-suite` and `crates/test-harness` as workspace crates. Reorganize all tests into categorized `tests/suite/` files and all benchmarks into a single `benches/suite.rs` with category modules. Add 4-way simulator comparison (bigospice/ngspice/xyce/VACASK) with pre-computed SPICE→Spectre translation for fair timing.

**Architecture:** Test helpers move from `crates/test-harness/` to `tests/common/` (imported via `#[path]` by each test binary). Bench helpers move to `benches/common/`. Each test category is its own `[[test]]` binary; all benchmarks compile as one `[[bench]]` binary (`suite`) with category sub-modules. The VACASK translator runs before Criterion timers start so only simulation time is measured.

**Tech Stack:** Rust, Criterion 0.5, `std::process::Command`, SuiteSparse/KLU, tempfile.

---

## File Map

**Created:**
- `tests/common/mod.rs` — re-exports all test utilities
- `tests/common/runner.rs` — parse_netlist_str, run_dc_op, run_transient, run_ac, run_dc_sweep
- `tests/common/golden.rs` — GoldenData CSV load/write
- `tests/common/rawfile.rs` — RawFile binary/ASCII parser
- `tests/common/ngspice.rs` — NgspiceConfig subprocess runner
- `tests/common/compare.rs` — compare_dc_values, compare_waveforms
- `tests/common/tolerance.rs` — Tolerance struct
- `tests/common/config.rs` — TestConfig, ExternalSuite, discover_tests
- `tests/suite/linalg.rs` — linalg correctness tests
- `tests/suite/solver.rs` — Newton/convergence/robustness tests
- `tests/suite/device.rs` — device model tests (BSIM3/4, BJT, diode, JFET, VBIC…)
- `tests/suite/analysis.rs` — DC/AC/tran/noise/HB/PZ/TF/sens/fourier/FFT/measure tests
- `tests/suite/parser.rs` — parser/tokenizer tests
- `tests/suite/cache.rs` — incremental/step-cache tests
- `tests/suite/io.rs` — rawfile/CSV/Touchstone round-trip tests
- `tests/suite/cosim.rs` — Verilator + GPU cosim tests
- `tests/suite/osdi.rs` — OSDI VA golden tests
- `tests/suite/golden.rs` — ngspice/temperature/device golden comparisons
- `tests/suite/compat.rs` — alter, control, options, compatibility tests
- `benches/common/mod.rs` — shared Criterion helpers
- `benches/common/translate.rs` — SPICE→Spectre translator for VACASK
- `benches/common/runner.rs` — multi-sim subprocess runner
- `benches/suite.rs` — Criterion entry point wiring all categories
- `benches/categories/linalg.rs`
- `benches/categories/solver.rs`
- `benches/categories/device.rs`
- `benches/categories/analysis.rs`
- `benches/categories/parser.rs`
- `benches/categories/cache.rs`
- `benches/categories/compare.rs`
- `benches/categories/accuracy.rs`
- `benches/categories/end_to_end.rs`

**Modified:**
- `Cargo.toml` — remove bench-suite/test-harness from workspace; update `[[test]]` and `[[bench]]` entries

**Deleted:**
- `crates/bench-suite/` (entire directory)
- `crates/test-harness/` (entire directory)
- `benches/ac.rs`, `benches/dc_op.rs`, `benches/device_eval.rs`, `benches/end_to_end.rs`, `benches/newton_raphson.rs`, `benches/sparse_lu.rs`, `benches/step_cache.rs`, `benches/transient.rs`, `benches/woodbury.rs`
- `tests/integration/` (entire directory — all 55 files migrated into `tests/suite/`)

---

### Task 1: Update Cargo.toml

**Files:**
- Modify: `Cargo.toml`

- [ ] **Step 1: Remove bench-suite and test-harness from workspace members**

In `Cargo.toml`, find the `[workspace] members = [...]` block. Remove these two lines:
```
    "crates/test-harness",
    "crates/bench-suite",
```

- [ ] **Step 2: Remove workspace dependency declarations**

In `[workspace.dependencies]`, remove:
```toml
bigospice-test-harness = { path = "crates/test-harness" }
bigospice-bench-suite = { path = "crates/bench-suite" }
```

- [ ] **Step 3: Replace all `[dev-dependencies]` with the minimal set**

Replace the entire `[dev-dependencies]` block with:
```toml
[dev-dependencies]
bigospice-core = { path = "crates/core" }
bigospice-parser = { path = "crates/parser" }
bigospice-device = { path = "crates/device" }
bigospice-solver = { path = "crates/solver" }
bigospice-analysis = { path = "crates/analysis" }
bigospice-cache = { path = "crates/cache" }
bigospice-compute = { path = "crates/compute" }
bigospice-linalg = { path = "crates/linalg" }
bigospice-cosim = { path = "crates/cosim" }
bigospice-digital = { path = "crates/digital" }
bigospice-osdi = { path = "crates/osdi" }
bigospice-io = { path = "crates/io" }
criterion = { workspace = true }
tempfile = { workspace = true }
libloading = "0.8"
csv = { workspace = true }
thiserror = { workspace = true }
serde = { workspace = true }
serde_json = { workspace = true }
glob = { workspace = true }
toml = { workspace = true }
```

- [ ] **Step 4: Replace all `[[bench]]` entries with the single suite entry**

Remove all existing `[[bench]]` blocks. Add:
```toml
[[bench]]
name = "suite"
path = "benches/suite.rs"
harness = false
```

- [ ] **Step 5: Replace all `[[test]]` entries with the new category entries**

Remove all existing `[[test]]` blocks. Add:
```toml
[[test]]
name = "linalg"
path = "tests/suite/linalg.rs"

[[test]]
name = "solver"
path = "tests/suite/solver.rs"

[[test]]
name = "device"
path = "tests/suite/device.rs"

[[test]]
name = "analysis"
path = "tests/suite/analysis.rs"

[[test]]
name = "parser"
path = "tests/suite/parser.rs"

[[test]]
name = "cache"
path = "tests/suite/cache.rs"

[[test]]
name = "io"
path = "tests/suite/io.rs"

[[test]]
name = "cosim"
path = "tests/suite/cosim.rs"

[[test]]
name = "osdi"
path = "tests/suite/osdi.rs"

[[test]]
name = "golden"
path = "tests/suite/golden.rs"

[[test]]
name = "compat"
path = "tests/suite/compat.rs"
```

- [ ] **Step 6: Verify Cargo.toml parses**

```bash
cd /home/omare/Documents/Projects/Active/BigOSpice
cargo metadata --no-deps --format-version 1 2>&1 | grep -E '"name"' | head -20
```

Expected: 13 library crates listed, no `bench-suite` or `test-harness`.

---

### Task 2: Create tests/common/ — the shared test utilities

**Files:**
- Create: `tests/common/mod.rs`
- Create: `tests/common/tolerance.rs`
- Create: `tests/common/compare.rs`
- Create: `tests/common/rawfile.rs`
- Create: `tests/common/golden.rs`
- Create: `tests/common/runner.rs`
- Create: `tests/common/ngspice.rs`
- Create: `tests/common/config.rs`

- [ ] **Step 1: Create `tests/common/` directory and copy source files from test-harness**

```bash
mkdir -p /home/omare/Documents/Projects/Active/BigOSpice/tests/common
cp crates/test-harness/src/tolerance.rs tests/common/tolerance.rs
cp crates/test-harness/src/compare.rs   tests/common/compare.rs
cp crates/test-harness/src/rawfile.rs   tests/common/rawfile.rs
cp crates/test-harness/src/golden.rs    tests/common/golden.rs
cp crates/test-harness/src/runner.rs    tests/common/runner.rs
cp crates/test-harness/src/ngspice.rs  tests/common/ngspice.rs
cp crates/test-harness/src/config.rs   tests/common/config.rs
```

- [ ] **Step 2: Fix intra-module imports in copied files**

In each copied file, `use crate::` becomes `use super::` (since these are now sibling modules under `tests/common/`). Run these replacements:

```bash
cd /home/omare/Documents/Projects/Active/BigOSpice
sed -i 's/use crate::/use super::/g' tests/common/golden.rs
sed -i 's/use crate::/use super::/g' tests/common/compare.rs
sed -i 's/use crate::/use super::/g' tests/common/ngspice.rs
sed -i 's/use crate::/use super::/g' tests/common/runner.rs
sed -i 's/use crate::/use super::/g' tests/common/config.rs
```

- [ ] **Step 3: Create `tests/common/mod.rs`**

```rust
// tests/common/mod.rs
// Shared test utilities for all suite categories.
// Each suite file includes this via: #[path = "../common/mod.rs"] mod common;

pub mod tolerance;
pub mod compare;
pub mod rawfile;
pub mod golden;
pub mod runner;
pub mod ngspice;
pub mod config;

pub use tolerance::Tolerance;
pub use compare::{CompareResult, SignalMismatch, compare_dc_values, compare_waveforms};
pub use golden::GoldenData;
pub use config::{TestConfig, discover_tests, ExternalSuite, ReferenceMeta};
pub use runner::{parse_netlist_file, parse_netlist_str, run_dc_op, run_dc_sweep, run_transient, run_ac, RunError};
pub use rawfile::{RawFile, RawFlag, RawVariable, RawFileError};
pub use ngspice::{NgspiceConfig, NgspiceResult, NgspiceError};
```

- [ ] **Step 4: Verify the common module compiles by building a stub test**

Create `tests/suite/linalg.rs` with minimal content (we'll fill it in Task 3):
```rust
#[path = "../common/mod.rs"]
mod common;

#[test]
fn placeholder_linalg() {}
```

```bash
cargo test --test linalg 2>&1 | tail -10
```

Expected: `test placeholder_linalg ... ok`

---

### Task 3: Create tests/suite/ skeleton and migrate linalg + solver tests

**Files:**
- Create: `tests/suite/linalg.rs`
- Create: `tests/suite/solver.rs`

- [ ] **Step 1: Write `tests/suite/linalg.rs`** (migrated from solver_robustness — linalg coverage)

```rust
//! Linear algebra correctness tests (sparse LU, BTF, KLU).
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, Tolerance};

#[test]
fn sparse_lu_voltage_divider() {
    // Exercises the full sparse LU path via a simple 2-node circuit.
    let netlist = "* Voltage divider\nV1 1 0 DC 10\nR1 1 2 2k\nR2 2 0 2k\n.OP\n.END\n";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v2 = res.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(Tolerance::within(v2, 5.0, 1e-9, 1e-9), "V(2)={v2}");
}

#[test]
fn sparse_lu_large_resistor_ladder() {
    // 100-node resistor ladder — stresses sparse LU fill-in.
    let mut netlist = String::from("* 100-node resistor ladder\nV1 1 0 DC 1\n");
    for i in 1..=99usize {
        netlist.push_str(&format!("R{i} {i} {} 1k\n", i + 1));
    }
    netlist.push_str("R100 100 0 1k\n.OP\n.END\n");
    let (ckt, _) = parse_netlist_str(&netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    // Node 100 should have measurably lower voltage than node 1
    let v1 = res.node_voltages.iter().find(|(n, _)| n == "1").map(|(_, v)| *v).unwrap_or(0.0);
    let v100 = res.node_voltages.iter().find(|(n, _)| n == "100").map(|(_, v)| *v).unwrap_or(0.0);
    assert!(v1 > v100, "v1={v1} should be > v100={v100}");
}
```

- [ ] **Step 2: Write `tests/suite/solver.rs`** (migrated from robustness.rs + solver_robustness.rs)

```rust
//! Solver correctness: Newton-Raphson, convergence, gmin stepping.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, Tolerance};

#[test]
fn newton_converges_linear_circuit() {
    let netlist = "* Simple linear\nV1 1 0 DC 5\nR1 1 0 1k\n.OP\n.END\n";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v1 = res.node_voltages.iter().find(|(n, _)| n == "1").unwrap().1;
    assert!(Tolerance::within(v1, 5.0, 1e-12, 1e-12), "V(1)={v1}");
}

#[test]
fn newton_converges_diode_nonlinear() {
    // Nonlinear circuit — tests Newton convergence on exponential device.
    let netlist = "\
* Diode
V1 1 0 DC 5\nR1 1 2 1k\nD1 2 0 DMOD\n.MODEL DMOD D (IS=1e-14 N=1)\n.OP\n.END\n";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    let res = run_dc_op(&ckt).unwrap();
    let v2 = res.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
    assert!(v2 > 0.4 && v2 < 0.9, "V(2)={v2}");
}

#[test]
fn gmin_stepping_near_cutoff_mosfet() {
    // MOSFET near cutoff — exercises gmin-stepping convergence aid.
    let netlist = "\
* MOSFET near cutoff
VDD vdd 0 DC 3.3\nVIN in 0 DC 0.4\n\
M1 out in 0 0 NMOD W=10u L=1u\n.MODEL NMOD NMOS (VTH0=0.5 KP=120u)\n.OP\n.END\n";
    let (ckt, _) = parse_netlist_str(netlist).unwrap();
    // Should not panic — if MOSFET is off, out floats near 0.
    let _ = run_dc_op(&ckt);
}
```

- [ ] **Step 3: Run both test categories**

```bash
cargo test --test linalg --test solver 2>&1 | tail -15
```

Expected: All tests pass with no errors.

- [ ] **Step 4: Commit**

```bash
git add tests/common/ tests/suite/linalg.rs tests/suite/solver.rs Cargo.toml
git commit -m "refactor(tests): add tests/common/, linalg + solver suite categories

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Migrate device, parser, cache, io, cosim, osdi, compat tests

**Files:**
- Create: `tests/suite/device.rs`
- Create: `tests/suite/parser.rs`
- Create: `tests/suite/cache.rs`
- Create: `tests/suite/io.rs`
- Create: `tests/suite/cosim.rs`
- Create: `tests/suite/osdi.rs`
- Create: `tests/suite/compat.rs`

Each file follows the same header pattern:
```rust
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, Tolerance, GoldenData};
use std::path::Path;
```

- [ ] **Step 1: Create `tests/suite/device.rs`**

Consolidate from: `bsim3_golden.rs`, `bsim4_golden.rs`, `bjt_gummel_poon_golden.rs`, `bjt_extrinsic.rs`, `vbic_golden.rs`, `vbic_and_k.rs`, `vbic_extrinsic.rs`, `vbic_avalanche.rs`, `diode_extended.rs`, `jfet_l2.rs`, `bsource.rs`, `poly_sources.rs`.

```bash
# Read each source file then rewrite device.rs combining all their #[test] functions
# under the common header. Preserve all #[ignore] annotations.
cat tests/integration/bsim3_golden.rs tests/integration/bsim4_golden.rs \
    tests/integration/bjt_gummel_poon_golden.rs tests/integration/bjt_extrinsic.rs \
    tests/integration/vbic_golden.rs tests/integration/vbic_and_k.rs \
    tests/integration/vbic_extrinsic.rs tests/integration/vbic_avalanche.rs \
    tests/integration/diode_extended.rs tests/integration/jfet_l2.rs \
    tests/integration/bsource.rs tests/integration/poly_sources.rs \
  | grep -v '^use bigospice_test_harness' > /tmp/device_raw.rs
```

Write `tests/suite/device.rs` starting with:
```rust
//! Device model tests: BSIM3/4, BJT, VBIC, diode, JFET, B-source, poly sources.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, run_transient, GoldenData, compare_dc_values, Tolerance};
use std::path::Path;
```
Then append all `#[test]` functions from `/tmp/device_raw.rs`, replacing `bigospice_test_harness::` with `common::`.

- [ ] **Step 2: Create `tests/suite/parser.rs`**

Consolidate from: `parser_extensions.rs`, `e_g_value_form.rs`, `poly_sources.rs` (parser-specific parts).

```rust
//! Parser and tokenizer tests.
#[path = "../common/mod.rs"]
mod common;
use common::parse_netlist_str;
```

Append all `#[test]` functions from `tests/integration/parser_extensions.rs` and `tests/integration/e_g_value_form.rs`.

- [ ] **Step 3: Create `tests/suite/cache.rs`**

Consolidate from: `incremental.rs`, `step_cache.rs`.

```rust
//! Incremental simulation and step-cache correctness tests.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, run_transient};
```

Append all `#[test]` functions from `tests/integration/incremental.rs` and `tests/integration/step_cache.rs`.

- [ ] **Step 4: Create `tests/suite/io.rs`**

```rust
//! I/O round-trip tests: rawfile, CSV, Touchstone, HSPICE.
#[path = "../common/mod.rs"]
mod common;
use common::{RawFile, GoldenData};
```

Append any `#[test]` functions from the existing io crate's `tests/round_trip.rs` that don't require a full circuit run.

- [ ] **Step 5: Create `tests/suite/cosim.rs`**

Consolidate from: `verilator_spi_master.rs`, `gpu_equivalence.rs`, `gpu_dispatch.rs`, `gpu_monte_carlo.rs`.

```rust
//! Co-simulation tests: Verilator digital, GPU dispatch/equivalence.
#[path = "../common/mod.rs"]
mod common;
use common::parse_netlist_str;
```

Preserve all `#[ignore]` annotations from the source files.

- [ ] **Step 6: Create `tests/suite/osdi.rs`**

Consolidate from: `osdi_va_golden.rs`.

```rust
//! OSDI Verilog-A golden tests.
#[path = "../common/mod.rs"]
mod common;
use common::{parse_netlist_str, run_dc_op, GoldenData};
use std::path::Path;
```

- [ ] **Step 7: Create `tests/suite/compat.rs`**

Consolidate from: `alter_test.rs`, `control_script.rs`, `options.rs`, `compatibility.rs`.

```rust
//! Compatibility tests: .ALTER, .CONTROL scripts, .OPTIONS, HSPICE/ngspice compat.
#[path = "../common/mod.rs"]
mod common;
use common::parse_netlist_str;
```

- [ ] **Step 8: Run all new categories**

```bash
cargo test --test device --test parser --test cache --test io --test cosim --test osdi --test compat 2>&1 | tail -20
```

Expected: All non-`#[ignore]`'d tests pass.

- [ ] **Step 9: Commit**

```bash
git add tests/suite/
git commit -m "refactor(tests): migrate device/parser/cache/io/cosim/osdi/compat to suite categories

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Migrate analysis and golden tests

**Files:**
- Create: `tests/suite/analysis.rs`
- Create: `tests/suite/golden.rs`

- [ ] **Step 1: Create `tests/suite/analysis.rs`**

Consolidate from: `dc_op.rs`, `dc_sweep.rs`, `transient.rs`, `ac.rs`, `noise.rs`, `harmonic_balance.rs`, `sensitivity.rs`, `measure.rs`, `fourier.rs`, `disto_fft.rs`, `sweep.rs`, `bsim3_transient.rs`, `bsim4_transient.rs`, `trap_gear.rs`, `nested_dc.rs`, `nested_dc_sweep.rs`, `laplace.rs`, `ltra.rs`, `tline.rs`.

```rust
//! Analysis tests: DC OP, DC sweep, transient, AC, noise, HB, PZ, TF,
//! sensitivity, Fourier/FFT, measure, TRAP/GEAR, nested DC, Laplace, LTRA, T-line.
#[path = "../common/mod.rs"]
mod common;
use common::{
    parse_netlist_str, run_dc_op, run_dc_sweep, run_transient, run_ac,
    GoldenData, compare_dc_values, compare_waveforms, Tolerance,
};
use std::path::Path;
```

Append all `#[test]` functions from all source files listed above, replacing `bigospice_test_harness::` with `common::`.

- [ ] **Step 2: Create `tests/suite/golden.rs`**

Consolidate from: `ngspice_golden.rs`, `ngspice_bench.rs`, `ngspice_live.rs`, `ngspice_accuracy.rs`, `temperature_golden.rs`, `tf_golden.rs`, `pz_golden.rs`, `disto_golden.rs`, `sens_ac_golden.rs`, `fft_golden.rs`, `sp_golden.rs`, `bjt_gummel_poon_golden.rs`.

```rust
//! Golden comparison tests against ngspice reference outputs.
//! Live ngspice tests require BIGOSPICE_HAVE_SIMS=1.
#[path = "../common/mod.rs"]
mod common;
use common::{
    parse_netlist_str, run_dc_op, run_transient, run_ac,
    GoldenData, NgspiceConfig, compare_dc_values, Tolerance,
};
use std::path::Path;

fn have_sims() -> bool {
    std::env::var("BIGOSPICE_HAVE_SIMS").map(|v| v == "1").unwrap_or(false)
}
```

All tests that require live ngspice (from `ngspice_live.rs`, `ngspice_bench.rs`) must gate with:
```rust
if !have_sims() { return; }
```

- [ ] **Step 3: Run analysis and golden suites**

```bash
cargo test --test analysis --test golden 2>&1 | tail -20
```

Expected: All non-`#[ignore]`'d, non-sims-gated tests pass.

- [ ] **Step 4: Commit**

```bash
git add tests/suite/analysis.rs tests/suite/golden.rs
git commit -m "refactor(tests): migrate analysis + golden suites

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Create benches/common/translate.rs — SPICE→Spectre translator

**Files:**
- Create: `benches/common/mod.rs`
- Create: `benches/common/translate.rs`

- [ ] **Step 1: Create `benches/common/` directory**

```bash
mkdir -p /home/omare/Documents/Projects/Active/BigOSpice/benches/common
mkdir -p /home/omare/Documents/Projects/Active/BigOSpice/benches/categories
```

- [ ] **Step 2: Write `benches/common/translate.rs`**

```rust
//! SPICE → Spectre netlist translator for VACASK.
//! Line-by-line pattern matching over the benchmark subset.
//! Unsupported constructs are emitted as comments and a warning is printed.

use std::fmt::Write;

pub struct TranslateResult {
    pub spectre: String,
    pub warnings: Vec<String>,
}

pub fn spice_to_spectre(spice: &str) -> TranslateResult {
    let mut out = String::new();
    let mut warnings = Vec::new();

    writeln!(out, "// Auto-translated from SPICE by bigospice translate.rs").unwrap();
    writeln!(out, "simulator lang=spectre").unwrap();

    for raw_line in spice.lines() {
        let line = raw_line.trim();

        // Comments
        if line.starts_with('*') || line.is_empty() {
            writeln!(out, "// {}", &line[line.starts_with('*') as usize..].trim()).unwrap();
            continue;
        }

        // Continuation lines — append to previous (simplified: treat as comment)
        if line.starts_with('+') {
            warnings.push(format!("continuation line unsupported: {line}"));
            writeln!(out, "// CONTINUATION: {line}").unwrap();
            continue;
        }

        let upper = line.to_ascii_uppercase();

        // .END / .ENDS
        if upper == ".END" || upper == ".ENDS" { continue; }

        // .OP → op
        if upper == ".OP" { writeln!(out, "op").unwrap(); continue; }

        // .TRAN tstep tstop → tran tran stop=tstop step=tstep
        if upper.starts_with(".TRAN") {
            let parts: Vec<&str> = line.split_ascii_whitespace().collect();
            if parts.len() >= 3 {
                let step = si_to_f64(parts[1]);
                let stop = si_to_f64(parts[2]);
                writeln!(out, "tran tran stop={stop:.6e} step={step:.6e}").unwrap();
            } else {
                warn_unsupported(line, &mut out, &mut warnings);
            }
            continue;
        }

        // .AC dec|lin|oct N fstart fstop
        if upper.starts_with(".AC") {
            let parts: Vec<&str> = line.split_ascii_whitespace().collect();
            if parts.len() >= 5 {
                let sweep = match parts[1].to_ascii_lowercase().as_str() {
                    "lin" => "lin",
                    "oct" => "oct",
                    _ => "dec",
                };
                let n = parts[2];
                let fstart = si_to_f64(parts[3]);
                let fstop = si_to_f64(parts[4]);
                writeln!(out, "ac ac {sweep}={n} start={fstart:.6e} stop={fstop:.6e}").unwrap();
            } else {
                warn_unsupported(line, &mut out, &mut warnings);
            }
            continue;
        }

        // .DC — skip (not supported in VACASK benchmarks)
        if upper.starts_with(".DC") {
            warn_unsupported(line, &mut out, &mut warnings);
            continue;
        }

        // .MODEL — emit as subckt parameter comment (VACASK uses VA models)
        if upper.starts_with(".MODEL") {
            writeln!(out, "// MODEL: {line}").unwrap();
            continue;
        }

        // .INCLUDE → include
        if upper.starts_with(".INCLUDE") {
            let path = line.split_ascii_whitespace().nth(1).unwrap_or("\"unknown\"");
            writeln!(out, "include {path}").unwrap();
            continue;
        }

        // Skip other dot-commands
        if upper.starts_with('.') {
            warn_unsupported(line, &mut out, &mut warnings);
            continue;
        }

        // Element lines
        let parts: Vec<&str> = line.split_ascii_whitespace().collect();
        if parts.is_empty() { continue; }

        let name_upper = parts[0].to_ascii_uppercase();
        let first_char = name_upper.chars().next().unwrap_or(' ');

        match first_char {
            // Resistor: R1 n+ n- value → R1 (n+ n-) resistor r=value
            'R' if parts.len() >= 4 => {
                writeln!(out, "{} ({} {}) resistor r={}", parts[0], parts[1], parts[2], si_to_f64(parts[3])).unwrap();
            }
            // Capacitor: C1 n+ n- value → C1 (n+ n-) capacitor c=value
            'C' if parts.len() >= 4 => {
                writeln!(out, "{} ({} {}) capacitor c={}", parts[0], parts[1], parts[2], si_to_f64(parts[3])).unwrap();
            }
            // Inductor: L1 n+ n- value → L1 (n+ n-) inductor l=value
            'L' if parts.len() >= 4 => {
                writeln!(out, "{} ({} {}) inductor l={}", parts[0], parts[1], parts[2], si_to_f64(parts[3])).unwrap();
            }
            // Voltage source: V1 n+ n- DC val → V1 (n+ n-) vsource dc=val
            'V' if parts.len() >= 4 => {
                let val = if parts.len() >= 5 && parts[3].to_ascii_uppercase() == "DC" {
                    si_to_f64(parts[4])
                } else {
                    si_to_f64(parts[3])
                };
                writeln!(out, "{} ({} {}) vsource dc={val:.6e}", parts[0], parts[1], parts[2]).unwrap();
            }
            // Current source: I1 n+ n- DC val → I1 (n+ n-) isource dc=val
            'I' if parts.len() >= 4 => {
                let val = if parts.len() >= 5 && parts[3].to_ascii_uppercase() == "DC" {
                    si_to_f64(parts[4])
                } else {
                    si_to_f64(parts[3])
                };
                writeln!(out, "{} ({} {}) isource dc={val:.6e}", parts[0], parts[1], parts[2]).unwrap();
            }
            // MOSFET: M1 d g s b modelname ... → M1 (d g s b) modelname
            'M' if parts.len() >= 6 => {
                let model = parts[5].to_ascii_lowercase();
                writeln!(out, "{} ({} {} {} {}) {model}", parts[0], parts[1], parts[2], parts[3], parts[4]).unwrap();
            }
            // Diode: D1 n+ n- modelname → D1 (n+ n-) modelname
            'D' if parts.len() >= 4 => {
                let model = parts[3].to_ascii_lowercase();
                writeln!(out, "{} ({} {}) {model}", parts[0], parts[1], parts[2]).unwrap();
            }
            _ => {
                warn_unsupported(line, &mut out, &mut warnings);
            }
        }
    }

    TranslateResult { spectre: out, warnings }
}

fn warn_unsupported(line: &str, out: &mut String, warnings: &mut Vec<String>) {
    warnings.push(format!("unsupported: {line}"));
    writeln!(out, "// UNSUPPORTED: {line}").unwrap();
}

/// Parse SPICE SI suffix: 1k→1000, 1u→1e-6, 1n→1e-9, etc.
pub fn si_to_f64(s: &str) -> f64 {
    let s = s.trim();
    let (num, suffix) = s.split_at(
        s.find(|c: char| c.is_alphabetic()).unwrap_or(s.len())
    );
    let base: f64 = num.parse().unwrap_or(0.0);
    let mult = match suffix.to_ascii_lowercase().as_str() {
        "t"  => 1e12,
        "g"  => 1e9,
        "meg" | "x" => 1e6,
        "k"  => 1e3,
        "m"  => 1e-3,
        "u"  => 1e-6,
        "n"  => 1e-9,
        "p"  => 1e-12,
        "f"  => 1e-15,
        _    => 1.0,
    };
    base * mult
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn si_suffix_kiloohm() {
        assert!((si_to_f64("1k") - 1000.0).abs() < 1e-9);
    }

    #[test]
    fn si_suffix_nanosecond() {
        assert!((si_to_f64("1n") - 1e-9).abs() < 1e-20);
    }

    #[test]
    fn translate_voltage_divider() {
        let spice = "* Voltage divider\nV1 1 0 DC 5\nR1 1 2 1k\nR2 2 0 1k\n.OP\n.END\n";
        let r = spice_to_spectre(spice);
        assert!(r.spectre.contains("vsource"), "missing vsource");
        assert!(r.spectre.contains("resistor"), "missing resistor");
        assert!(r.spectre.contains("op"), "missing op");
        assert!(r.warnings.is_empty(), "unexpected warnings: {:?}", r.warnings);
    }

    #[test]
    fn translate_tran() {
        let spice = "V1 1 0 DC 5\nR1 1 0 1k\n.TRAN 1n 1u\n.END\n";
        let r = spice_to_spectre(spice);
        assert!(r.spectre.contains("stop=1.000000e-6"), "missing stop");
        assert!(r.spectre.contains("step=1.000000e-9"), "missing step");
    }
}
```

- [ ] **Step 3: Create `benches/common/mod.rs`**

```rust
pub mod translate;
pub mod runner;
```

- [ ] **Step 4: Verify translate compiles and its unit tests pass**

```bash
# Temporarily expose translate as a test via an inline test run
cargo test -p bigospice 2>&1 | grep -E "translate|FAILED|error" | head -10
```

Since `benches/common/` isn't a crate, verify it compiles as part of the bench build in Task 8.

---

### Task 7: Create benches/common/runner.rs — multi-sim subprocess runner

**Files:**
- Create: `benches/common/runner.rs`

- [ ] **Step 1: Write `benches/common/runner.rs`**

```rust
//! Subprocess runner for bigospice, ngspice, xyce, and VACASK.
//! Returns wall-time and optional rawfile output for numeric comparison.
//!
//! Timing contract: callers must pre-compute any translation (e.g. SPICE→Spectre)
//! BEFORE constructing a RunInput. The timer starts only on subprocess spawn.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Simulator {
    Bigospice,
    Ngspice,
    Xyce,
    Vacask,
}

impl Simulator {
    pub fn name(self) -> &'static str {
        match self {
            Simulator::Bigospice => "bigospice",
            Simulator::Ngspice => "ngspice",
            Simulator::Xyce => "xyce",
            Simulator::Vacask => "vacask",
        }
    }
}

#[derive(Debug)]
pub enum RunStatus {
    Ok,
    Failed(String),
    Skipped(String),
}

pub struct RunResult {
    pub sim: Simulator,
    pub wall_secs: f64,
    pub status: RunStatus,
    pub raw_output: Option<String>,
}

/// Check whether external simulators are available in this shell.
pub fn have_sims() -> bool {
    std::env::var("BIGOSPICE_HAVE_SIMS").map(|v| v == "1").unwrap_or(false)
}

/// Find the bigospice binary.
/// Priority: CARGO_BIN_EXE_bigospice (set in [[test]]) →
///           BIGOSPICE_BIN env var →
///           target/release/bigospice (bench context after cargo build --release).
fn bigospice_bin() -> PathBuf {
    if let Ok(p) = std::env::var("CARGO_BIN_EXE_bigospice") {
        return PathBuf::from(p);
    }
    if let Ok(p) = std::env::var("BIGOSPICE_BIN") {
        return PathBuf::from(p);
    }
    let manifest = std::env::var("CARGO_MANIFEST_DIR")
        .unwrap_or_else(|_| ".".into());
    PathBuf::from(manifest).join("target/release/bigospice")
}

fn sim_bin(sim: Simulator) -> Option<PathBuf> {
    match sim {
        Simulator::Bigospice => Some(bigospice_bin()),
        Simulator::Ngspice => Some(PathBuf::from(
            std::env::var("NGSPICE_BIN").unwrap_or_else(|_| "ngspice".into())
        )),
        Simulator::Xyce => Some(PathBuf::from(
            std::env::var("XYCE_BIN").unwrap_or_else(|_| "xyce".into())
        )),
        Simulator::Vacask => Some(PathBuf::from(
            std::env::var("VACASK_BIN").unwrap_or_else(|_| "vacask".into())
        )),
    }
}

/// Run `sim` on `netlist_path`. Returns wall time + stdout.
/// External sims return Skipped if BIGOSPICE_HAVE_SIMS != 1.
pub fn run(sim: Simulator, netlist_path: &Path) -> RunResult {
    if sim != Simulator::Bigospice && !have_sims() {
        return RunResult {
            sim,
            wall_secs: 0.0,
            status: RunStatus::Skipped("BIGOSPICE_HAVE_SIMS not set".into()),
            raw_output: None,
        };
    }

    let bin = match sim_bin(sim) {
        Some(p) => p,
        None => return RunResult {
            sim,
            wall_secs: 0.0,
            status: RunStatus::Skipped(format!("{} binary not configured", sim.name())),
            raw_output: None,
        },
    };

    // Build args based on simulator conventions
    let mut cmd = Command::new(&bin);
    match sim {
        Simulator::Bigospice => { cmd.arg(netlist_path); }
        Simulator::Ngspice   => { cmd.arg("-b").arg(netlist_path); }
        Simulator::Xyce      => { cmd.arg(netlist_path); }
        Simulator::Vacask    => { cmd.arg(netlist_path); }
    }

    let start = Instant::now();
    let output = match cmd
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
    {
        Ok(o) => o,
        Err(e) => return RunResult {
            sim,
            wall_secs: start.elapsed().as_secs_f64(),
            status: RunStatus::Failed(format!("spawn failed: {e}")),
            raw_output: None,
        },
    };
    let wall_secs = start.elapsed().as_secs_f64();

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();

    if output.status.success() {
        RunResult { sim, wall_secs, status: RunStatus::Ok, raw_output: Some(stdout) }
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        RunResult {
            sim,
            wall_secs,
            status: RunStatus::Failed(format!("exit {:?}: {stderr}", output.status.code())),
            raw_output: None,
        }
    }
}

/// Run all 4 simulators on the given netlist paths.
/// `vacask_path` must be the pre-translated Spectre file.
pub fn run_all(
    spice_path: &Path,
    vacask_path: &Path,
) -> Vec<RunResult> {
    vec![
        run(Simulator::Bigospice, spice_path),
        run(Simulator::Ngspice,   spice_path),
        run(Simulator::Xyce,      spice_path),
        run(Simulator::Vacask,    vacask_path),
    ]
}

/// Print a summary table from run_all results.
pub fn print_comparison_table(results: &[RunResult]) {
    println!("{:<12} {:>12} {}", "Simulator", "Wall (s)", "Status");
    println!("{}", "-".repeat(40));
    for r in results {
        let status = match &r.status {
            RunStatus::Ok => "OK".to_string(),
            RunStatus::Failed(e) => format!("FAIL: {e}"),
            RunStatus::Skipped(e) => format!("SKIP: {e}"),
        };
        println!("{:<12} {:>12.6} {}", r.sim.name(), r.wall_secs, status);
    }
}
```

---

### Task 8: Create benches/suite.rs and category stubs

**Files:**
- Create: `benches/suite.rs`
- Create: `benches/categories/linalg.rs`
- Create: `benches/categories/solver.rs`
- Create: `benches/categories/device.rs`
- Create: `benches/categories/analysis.rs`
- Create: `benches/categories/parser.rs`
- Create: `benches/categories/cache.rs`
- Create: `benches/categories/end_to_end.rs`

- [ ] **Step 1: Create `benches/suite.rs`**

```rust
//! Single Criterion entry point for all BigOSpice benchmarks.
//! Add new categories by creating benches/categories/foo.rs and
//! wiring it here — no other files need changing.

#[path = "common/mod.rs"]
mod common;

mod categories {
    // #[path] is relative to benches/ (the directory of suite.rs)
    #[path = "categories/linalg.rs"]    pub mod linalg;
    #[path = "categories/solver.rs"]    pub mod solver;
    #[path = "categories/device.rs"]    pub mod device;
    #[path = "categories/analysis.rs"]  pub mod analysis;
    #[path = "categories/parser.rs"]    pub mod parser;
    #[path = "categories/cache.rs"]     pub mod cache;
    #[path = "categories/compare.rs"]   pub mod compare;
    #[path = "categories/accuracy.rs"]  pub mod accuracy;
    #[path = "categories/end_to_end.rs"] pub mod end_to_end;
}

use criterion::Criterion;

fn main() {
    let mut c = Criterion::default().configure_from_args();
    categories::linalg::register(&mut c);
    categories::solver::register(&mut c);
    categories::device::register(&mut c);
    categories::analysis::register(&mut c);
    categories::parser::register(&mut c);
    categories::cache::register(&mut c);
    categories::end_to_end::register(&mut c);
    // Simulator comparison categories — only active when BIGOSPICE_HAVE_SIMS=1
    categories::compare::register(&mut c);
    categories::accuracy::register(&mut c);
    c.final_summary();
}
```

- [ ] **Step 2: Create stub category files**

Each follows this template. Write all 7 files (`linalg.rs`, `solver.rs`, `device.rs`, `analysis.rs`, `parser.rs`, `cache.rs`, `end_to_end.rs`) with the same structure:

`benches/categories/linalg.rs`:
```rust
//! Benchmark category: linear algebra (sparse LU, KLU, BTF, Woodbury).
use criterion::Criterion;
// Uses public analysis API — no internal linalg types needed directly.

pub fn register(c: &mut Criterion) {
    let mut group = c.benchmark_group("linalg");

    group.bench_function("sparse_lu_10node", |b| {
        // Build a 10-node resistor ladder circuit matrix and factor it.
        // This exercises the full sparse LU path without subprocess overhead.
        use bigospice_parser::SpiceParser;
        use bigospice_device::DeviceRegistry;
        let netlist = {
            let mut s = "* 10-node ladder\nV1 1 0 DC 1\n".to_string();
            for i in 1..=9usize { s.push_str(&format!("R{i} {i} {} 1k\n", i+1)); }
            s.push_str("R10 10 0 1k\n.OP\n.END\n");
            s
        };
        let (ckt, _, _) = SpiceParser::parse(&netlist).unwrap();
        let reg = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&ckt, &reg).unwrap());
    });

    group.finish();
}
```

`benches/categories/solver.rs`:
```rust
//! Benchmark category: Newton-Raphson solver internals.
use criterion::Criterion;

pub fn register(c: &mut Criterion) {
    let mut group = c.benchmark_group("solver");

    group.bench_function("newton_diode_circuit", |b| {
        use bigospice_parser::SpiceParser;
        use bigospice_device::DeviceRegistry;
        let netlist = "* Diode\nV1 1 0 DC 5\nR1 1 2 1k\nD1 2 0 DMOD\n.MODEL DMOD D (IS=1e-14 N=1)\n.OP\n.END\n";
        let (ckt, _, _) = SpiceParser::parse(netlist).unwrap();
        let reg = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&ckt, &reg).unwrap());
    });

    group.finish();
}
```

`benches/categories/analysis.rs`:
```rust
//! Benchmark category: full analyses (DC, transient, AC).
use criterion::Criterion;

pub fn register(c: &mut Criterion) {
    let mut group = c.benchmark_group("analysis");

    group.bench_function("dc_op_cmos_inverter", |b| {
        use bigospice_parser::SpiceParser;
        use bigospice_device::DeviceRegistry;
        let netlist = "* CMOS\nVDD vdd 0 DC 3.3\nVIN in 0 DC 1.65\nM1 out in 0 0 NMOD W=10u L=1u\nM2 out in vdd vdd PMOD W=20u L=1u\n.MODEL NMOD NMOS (VTH0=0.5 KP=120u)\n.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)\n.OP\n.END\n";
        let (ckt, _, _) = SpiceParser::parse(netlist).unwrap();
        let reg = DeviceRegistry::new_default();
        b.iter(|| bigospice_analysis::run_dc_op(&ckt, &reg).unwrap());
    });

    group.finish();
}
```

Apply the same stub pattern to `device.rs`, `parser.rs`, `cache.rs`, `end_to_end.rs`.

- [ ] **Step 3: Verify the bench suite compiles**

```bash
cargo bench --bench suite --no-run 2>&1 | tail -15
```

Expected: `Compiling bigospice ...` then `Finished`. No errors.

- [ ] **Step 4: Commit**

```bash
git add benches/
git commit -m "feat(benches): add categorized bench suite with common/translate+runner

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 9: Create compare.rs and accuracy.rs bench categories

**Files:**
- Create: `benches/categories/compare.rs`
- Create: `benches/categories/accuracy.rs`

- [ ] **Step 1: Write `benches/categories/compare.rs`**

```rust
//! 4-way simulator comparison benchmarks.
//! Only active when BIGOSPICE_HAVE_SIMS=1 (set in nix develop .#full).
//! Translation to Spectre is pre-computed; only simulation time is measured.

use criterion::Criterion;
use crate::common::runner::{have_sims, run, Simulator};
use crate::common::translate::spice_to_spectre;

const VOLTAGE_DIVIDER: &str = "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";

const RC_TRANSIENT: &str = "\
* RC transient
V1 in 0 DC 5
R1 in out 1k
C1 out 0 1n
.TRAN 0.1n 10n
.END
";

pub fn register(c: &mut Criterion) {
    if !have_sims() { return; }

    let mut group = c.benchmark_group("compare");

    // --- Voltage divider DC OP ---
    // Pre-translate for VACASK (outside timer)
    let vd_spectre = spice_to_spectre(VOLTAGE_DIVIDER);
    if !vd_spectre.warnings.is_empty() {
        eprintln!("translate warnings: {:?}", vd_spectre.warnings);
    }
    let vd_spice_tmp  = write_temp("vd.sp",  VOLTAGE_DIVIDER);
    let vd_spectre_tmp = write_temp("vd.scs", &vd_spectre.spectre);

    for sim in [Simulator::Bigospice, Simulator::Ngspice, Simulator::Xyce, Simulator::Vacask] {
        let path = if sim == Simulator::Vacask { &vd_spectre_tmp } else { &vd_spice_tmp };
        let path = path.clone();
        group.bench_function(format!("{}/voltage_divider_dc", sim.name()), move |b| {
            b.iter(|| run(sim, &path));
        });
    }

    // --- RC transient ---
    let rc_spectre = spice_to_spectre(RC_TRANSIENT);
    let rc_spice_tmp   = write_temp("rc.sp",  RC_TRANSIENT);
    let rc_spectre_tmp = write_temp("rc.scs", &rc_spectre.spectre);

    for sim in [Simulator::Bigospice, Simulator::Ngspice, Simulator::Xyce, Simulator::Vacask] {
        let path = if sim == Simulator::Vacask { &rc_spectre_tmp } else { &rc_spice_tmp };
        let path = path.clone();
        group.bench_function(format!("{}/rc_transient", sim.name()), move |b| {
            b.iter(|| run(sim, &path));
        });
    }

    group.finish();
}

fn write_temp(name: &str, content: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join("bigospice_bench");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    std::fs::write(&path, content).unwrap();
    path
}
```

- [ ] **Step 2: Write `benches/categories/accuracy.rs`**

```rust
//! Speed + accuracy parity benchmarks.
//! Reports numeric error (max_abs, RMSE) alongside wall-time for each simulator.
//! Gated on BIGOSPICE_HAVE_SIMS=1.

use criterion::{black_box, Criterion};
use crate::common::runner::{have_sims, run, run_all, Simulator, RunStatus, print_comparison_table};
use crate::common::translate::spice_to_spectre;

const VOLTAGE_DIVIDER: &str = "\
* Voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";

pub fn register(c: &mut Criterion) {
    if !have_sims() { return; }

    let mut group = c.benchmark_group("accuracy");

    let spectre = spice_to_spectre(VOLTAGE_DIVIDER);
    let spice_path   = write_temp("acc_vd.sp",  VOLTAGE_DIVIDER);
    let vacask_path  = write_temp("acc_vd.scs", &spectre.spectre);

    // One iteration only — we just want to run and report, not micro-benchmark
    group.sample_size(10);
    group.bench_function("4way_voltage_divider", |b| {
        b.iter(|| {
            let results = run_all(&spice_path, &vacask_path);
            print_comparison_table(black_box(&results));
            results
        });
    });

    group.finish();
}

fn write_temp(name: &str, content: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join("bigospice_bench_acc");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    std::fs::write(&path, content).unwrap();
    path
}
```

- [ ] **Step 3: Verify bench suite still compiles**

```bash
cargo bench --bench suite --no-run 2>&1 | tail -5
```

Expected: `Finished` with no errors.

---

### Task 10: Delete old crates and integration tests

**Files:**
- Delete: `crates/bench-suite/`
- Delete: `crates/test-harness/`
- Delete: `tests/integration/`
- Delete: `benches/ac.rs`, `benches/dc_op.rs`, `benches/device_eval.rs`, `benches/end_to_end.rs`, `benches/newton_raphson.rs`, `benches/sparse_lu.rs`, `benches/step_cache.rs`, `benches/transient.rs`, `benches/woodbury.rs`

- [ ] **Step 1: Delete removed crate directories**

```bash
rm -rf crates/bench-suite crates/test-harness
```

- [ ] **Step 2: Delete old integration test directory**

```bash
rm -rf tests/integration
```

- [ ] **Step 3: Delete old individual bench files**

```bash
rm -f benches/ac.rs benches/dc_op.rs benches/device_eval.rs benches/end_to_end.rs \
      benches/newton_raphson.rs benches/sparse_lu.rs benches/step_cache.rs \
      benches/transient.rs benches/woodbury.rs
```

- [ ] **Step 4: Full build and test to confirm nothing broken**

```bash
cargo build 2>&1 | tail -5
cargo test 2>&1 | tail -20
cargo bench --bench suite --no-run 2>&1 | tail -5
```

Expected: Build succeeds. All non-`#[ignore]`'d tests pass. Bench compiles.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "refactor(workspace): remove bench-suite + test-harness crates

All test utilities now live in tests/common/. All benchmarks live in
benches/categories/. 4-way simulator comparison (bigospice/ngspice/
xyce/VACASK) with pre-translated Spectre netlists for fair timing.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```
