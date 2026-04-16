# IO, Utility, and CLI Crates Research

## 1. IO Crate (`crates/io/src/`)

The `bigospice-io` crate consolidates all output format writers. It is deliberately decoupled from `bigospice-analysis` (receives plain `&[Vec<f64>]` slices rather than analysis types), enabling format writers to be tested independently.

### 1.1 Rawfile Format (`rawfile.rs`)

Berkeley rawfile is the de-facto interchange format for ngspice and waveform viewers (gaw, gwave, kst).

**Two flavors:**
- **ASCII** — header + `Values:` section, one value per line. Human-readable, slow on large datasets.
- **Binary** — same header followed by `Binary:\n` and tightly packed native-endian `f64` values. Point-major (row-major over variables x points). Uses platform-native float endianness (not portable across architectures), matching ngspice convention exactly.

**Header fields:**
```
Title: <title>
Date: <date>
Plotname: <plotname>
Flags: real | complex
No. Variables: <n>
No. Points: <n>
Variables:
    <idx>  <name>  <type>
Values: | Binary:
```

**Complex data:** pairs of f64 stored as `(re, im)` per value. `data[point][2*var]` = real, `data[point][2*var+1]` = imag.

**Key types:**
- `RawFlag` — `Real` or `Complex`
- `RawVariable` — `index`, `name`, `var_type`
- `RawFile` — parsed representation with `data: Vec<Vec<f64>>`
- `RawfileWriter` — builder/writer; `Filetype::Binary` (default) or `Ascii`

**Supported analyses:** Real DC OP, DC sweep, transient. Complex AC sweep.

### 1.2 HSPICE POST=2 Format (`hspice.rs`)

HSPICE POST=2 binary format (`.tr0`, `.ac0`, `.sw0`). Fortran "unformatted sequential" record style: each block wrapped in 4-byte little-endian length prefix + trailer.

**Block layout for waveform files:**
1. **Block 1 (header):** Fixed-width text fields — nauto, nprobe, nsweep, iversn, title-prefix, date, time, copyright, title
2. **Block 2 (variable types):** `(1 + nvars)` ascii integers, 9-char zero-padded fields. Type codes: `1`=independent (time/freq), `2`=voltage, `8`=current, `15`=frequency
3. **Block 3 (variable names):** `(1 + nvars)` 16-char names
4. **Block 4 (data):** Packed little-endian f32 values, one row per sweep point. Trailing `1e30` sentinel marks end-of-data.

**AC files:** Each complex variable contributes magnitude + phase as two consecutive columns (or real+imag sub-columns with `:REAL`/`:IMAG` suffixes).

**ASCII `.mt0`** (measurement output): One-line header + numeric row per measurement. Format: `$DATA1 SOURCE='BigOSpice' VERSION='0.1.0'` then `.TITLE '<title>'`, then column names (16-char padded), then values (16-char, scientific notation).

**Key types:**
- `HspiceVarType` — `Independent(1)`, `Voltage(2)`, `Current(8)`, `Frequency(15)`
- `HspicePostKind` — `Transient`, `Ac`, `DcSweep`
- `HspicePostWriter` — binary waveform writer
- `HspiceMt0Writer` — ASCII measurement output writer

### 1.3 CSV Format (`csv.rs`)

Generic column-major CSV writer. Takes `&[Vec<f64>]` per column (SoA-friendly).

**Features:**
- Configurable delimiter (default: `,`)
- Optional units row (e.g., `"s"`, `"V"`)
- Optional quoted-string headers (RFC 4180 compliant quoting)
- Configurable numeric precision (default: 9)
- Column count and length validation

**Output format:** header row(s), then one row per time point, columns comma-separated in scientific notation (`%.*e`).

### 1.4 Touchstone Format (`touchstone.rs`)

Touchstone `.sNp` writer for RF S/Y/Z parameter data. Reference: IBIS-ATM Touchstone 1.1.

**Option line:** `# <freq_unit> <param> <format> R <z_ref>` (e.g., `# GHz S MA R 50`)

**Layout per frequency row:**
- 1-port: `freq  S11_a S11_b`
- 2-port: `freq  S11 S21 S12 S22` (note: 2-port is column-major in the spec — S21 before S12)
- N-port (N>=3): row-major, 4 entries per continuation line

**Complex formats:**
- `MA` — magnitude / angle (degrees)
- `DB` — 20·log10(|S|) / angle (degrees)
- `RI` — real / imaginary

**Key types:**
- `FreqUnit` — `Hz`, `KHz`, `MHz`, `GHz`
- `ParamType` — `S`, `Y`, `Z`
- `ComplexFormat` — `MA`, `DB`, `RI`
- `TouchstoneWriter`

### 1.5 Print Select / Wildcard Resolution (`print_select.rs`)

Resolves `.PRINT`/`.SAVE`/`.PLOT` wildcard specs (e.g., `V(*)`, `I(*)`) against the actual circuit namespace at runtime.

**Supported column types:**
- `V(node)` — single node voltage
- `V(n1,n2)` — differential voltage
- `I(branch)` — branch current
- `VM(node)`, `VDB(node)`, `VR(node)`, `VI(node)`, `VP(node)` — AC magnitude/dB/real/imag/phase
- `P(element)` — instantaneous power
- `N(node)` — noise spectral density
- `V(*)`, `I(*)`, `*` — wildcards

**Key function:** `resolve(specs, nodes, branches, strict) -> Result<Vec<PrintColumn>>`. De-duplicates. Ground node `0` is skipped for `V(*)`. `strict=false` allows unknown nodes.

### 1.6 AC Output Helpers (`ac_output.rs`)

Bridges raw complex AC results (`AcData`) to column-major `Vec<Vec<f64>>` for format writers. Designed to have **no dependency on `bigospice-analysis`**.

**`AcData` layout:** All arrays indexed `[freq_point][node_index]`.

**Extractions:**
- `V(node)` / `VM(node)` → magnitude (`sqrt(re^2 + im^2)`)
- `VDB(node)` → `20·log10(|V|)`
- `VR(node)` → real part
- `VI(node)` → imaginary part
- `VP(node)` → phase in degrees (stored as radians → converted)

**`build_ac_columns`** prepends frequency as column 0, returns `(headers, columns)` tuple.

### 1.7 MT0 Writer (`mt0.rs`)

HSPICE-style aggregated `.mt0` output for Monte Carlo / worst-case runs. ASCII format.

**Format:**
```
$DATA1 SOURCE='bigospice-mc' VERSION='1.0'
.TITLE '<title>'
index    <meas1>    <meas2>    ...
  1      ...        ...        ...
  2      ...        ...        ...
```

**Key types:**
- `Mt0Row` — `index: u32` (1-based), `values: Vec<f64>`
- `Mt0Writer` — accumulates rows, `render()` to String, `write_to_path()`

Failed measurements emitted as `nan`. Row count always matches sample count.

### 1.8 Output Format Selection (`format_kind.rs`)

`OutputFormat` enum for runtime dispatch:
- `RawfileBinary` (default, `.raw`)
- `RawfileAscii` (`.raw`)
- `HspicePost` (`.tr0`)
- `Touchstone` (`.s2p`)
- `Csv` (`.csv`)

Supports parsing from canonical names (case-insensitive) and file extension guessing.

---

## 2. Utility Crate (`crates/utility/src/`)

The `bigospice-utility` crate provides data-oriented design primitives. All operate on the principle of **Struct-of-Arrays (SoA)** over Array-of-Structs (AoS) for cache-optimal hot-path iteration.

### 2.1 SoA Container (`soa.rs`)

`soa_define!` macro generates a `{Name}SoaVec` container from a struct definition. Each field stored in its own `Vec`. Enables cache-optimal iteration over hot fields without loading cold fields.

**Macro generates:**
1. Original AoS struct (for construction/single-item work)
2. `{Name}SoaVec` struct with per-field `Vec`s
3. Per-field accessor methods (`x()`, `x_mut()`)
4. Multi-field mutable accessors via `soa_fields_mut!` macro (safe aliasing via separate Vec allocations)
5. `SoaVec` trait implementation: `len`, `reserve`, `capacity`, `push`, `swap_remove`, `get`, `clear`

**Performance:** 2-10x faster than AoS for iteration over 1-2 fields; equal for full-struct iteration.

### 2.2 Arena Allocator (`arena.rs`)

Bump allocator for phase-scoped data. Groups allocations into contiguous blocks; frees all at once via `reset()`.

**Performance:**
- Allocation: O(1) — bump a pointer
- Deallocation: O(1) amortized — reset cursor
- Memory overhead: ~0 per allocation
- Cache behavior: excellent — sequential allocations are contiguous

**Methods:**
- `alloc(value)` — single value
- `alloc_slice_copy(src)` — copy from existing slice
- `alloc_slice_default::<T>(count)` — zero-initialized slice
- `alloc_str(s)` — string slice
- `reset()` — free all (keep first block)
- `bytes_allocated()`, `bytes_reserved()`

### 2.3 Pool / Handle (`pool.rs`)

Generational index pool. Items referenced by `Handle` (index + generation), not pointer.

**Handle:** 8 bytes (two u32s). Valid iff `handle.generation == slot.generation` AND slot is `Occupied`.

**Benefits:**
- Use-after-free detection at runtime (stale handles return `None`)
- Half the size of pointers
- Reallocation-safe references
- Serialization-friendly
- Cache-friendly flat storage

**LIFO free list** for cache locality — recently freed slots reused first.

### 2.4 Typed Index (`index.rs`)

`typed_index!(MyIdx)` macro generates zero-cost newtype wrapper around `u32` for type-safe indexing. Prevents passing `entity_idx` where `mesh_idx` expected.

**Generated type:** `#[repr(transparent)] struct MyIdx(u32)` with methods: `new()`, `raw()`, `idx()`, `none()`, `is_none()`, `is_some()`. Derives `Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash`.

**`IndexVec<I, T>`** — `Vec` wrapper indexed by `TypedIndex` instead of `usize`. `push()` returns typed index.

### 2.5 BitSet (`bitset.rs`)

Growable dense bitset backed by `Vec<u64>`. 1 bit per entry (vs 8 bytes for `bool`).

**Existence-based processing:** Maintains separate bitset for alive/dirty/sparse entities. Iteration skips entire 64-entity blocks that are all-zero; `trailing_zeros()` finds next set bit in one CPU instruction.

**Operations:** `insert`, `remove`, `contains`, `toggle`, `count`, `clear`, `is_empty`, `iter()`, `intersection`, `union`, `difference`.

### 2.6 SIMD (`simd.rs`)

Batch f32 operations using SSE2 (128-bit, 4 floats at a time) on x86_64. Falls back to scalar on other platforms.

**Requires SoA layout** — contiguous arrays of the same type.

**Functions (all `#[inline]`, x86_64 with SSE2 fallback):**
- `add_scaled_f32(dst, src, scalar)` — `dst[i] += src[i] * scalar` (physics integration kernel)
- `mul_scalar_f32(dst, scalar)` — uniform scaling
- `add_f32(dst, a, b)` — `dst[i] = a[i] + b[i]`
- `sum_f32(data)` — sum all elements (SIMD horizontal add)
- `min_f32(data)`, `max_f32(data)` — find extremes
- `clamp_f32(data, min, max)` — clamp in-place
- `lerp_f32(dst, a, b, t)` — `dst[i] = a[i] + (b[i] - a[i]) * t`
- `dot_f32(a, b)` — dot product

Compile with `RUSTFLAGS="-C target-cpu=native"` for AVX2.

### 2.7 SI Suffix Map (`static_map.rs`)

PHF-backed (perfect hash function) map for SPICE numeric suffix parsing.

**Supported suffixes:** `f` (1e-15), `p` (1e-12), `n` (1e-9), `u` (1e-6), `m` (1e-3), `k` (1e3), `meg` (1e6), `g` (1e9), `t` (1e12).

**Key design:** Tries 3-char prefix first (to catch `"meg"` before `"m"`), then 1-char prefix.

### 2.8 Utility Crate Summary

| Module | Purpose |
|--------|---------|
| `soa` | SoA container macro for cache-optimal iteration |
| `arena` | Bump allocator for phase-scoped data |
| `pool` | Generational index pool with stale handle detection |
| `index` | Typed index newtypes for compile-time safety |
| `bitset` | Dense bitset for existence-based processing |
| `simd` | SSE2 batch f32 operations on SoA data |
| `static_map` | SI suffix lookup for SPICE numeric parsing |

---

## 3. CLI Crate (`crates/cli/src/main.rs`)

The `bigospice-cli` binary provides the command-line interface.

### 3.1 Command-Line Interface

**Usage:** `bigospice [--output <file|->] [--quiet] <netlist.sp>`

**Flags:**
- `--output -` — write results to stdout
- `--output <file>` — write results to file
- `--quiet` / `-q` — suppress non-error messages
- `--no-output` — suppress output (default, for backwards compatibility)
- `-h` / `--help` — show usage

### 3.2 Supported Analyses

The CLI dispatches to analysis functions based on parsed `.sp` file:

**DC Operating Point (`.OP`):**
- Calls `run_dc_op(&circuit, &registry)`
- Output: `v(node)=value` and `i(branch)=value` lines

**DC Sweep (`.DC`):**
- Single sweep: `run_dc_sweep(&circuit, &registry, &cfg)`
- Nested (two-variable): `run_nested_dc(&circuit, &registry, &nested_cfg)`
- Output: last operating point values

**Transient (`.TRAN`):**
- Calls `run_transient(&mut circuit, &registry, &cfg)`
- Output: tab-separated `time\tnode\tvalue` per time step

**AC Analysis (`.AC`):**
- Calls `run_ac(&circuit, &registry, &cfg)`
- Output: tab-separated `freq\tnode\tmag\tphase` per frequency point

**Unsupported:** `.FOUR`, `.DISTO`, `.NOISE`, `.PZ`, `.TF`, `.SEN`, `.MC` — silently skipped (unless non-quiet mode shows warning).

### 3.3 Output Format

The CLI currently writes **plain tab-separated text** output (not rawfile/HSPICE/etc.). The `bigospice-io` crate is available but not yet integrated into the CLI for format selection.

**DC OP output format:**
```
v(node_name)=1.234567890123e+00
i(branch_name)=5.678901234567e-03
```

**Transient output format:**
```
time\tnodename\tvalue
1.000000000000e-09\tout\t4.567890123456e+00
```

### 3.4 Circuit Node Ordering

`circuit_node_names()` extracts nodes ordered by `matrix_index` (MNA order), excluding ground (`0`).

---

## 4. Benchmark Suite

### 4.1 Benchmark Script (`scripts/run_benchmarks.sh`)

Head-to-head comparison of BigOSpice vs ngspice (and optionally VACASK, Xyce).

**Usage:**
```bash
nix develop .#full --command bash scripts/run_benchmarks.sh [OPTIONS]
```

**Options:**
- `--no-ngspice`, `--no-vacask`, `--no-xyce` — exclude simulators
- `--nruns N` — timing runs per circuit (default: 10)
- `--warmup N` — warmup runs (default: 3)
- `--corpus DIR` — corpus directory
- `--category NAME` — run only one fixture category
- `--circuit NAME` — run only circuits matching NAME
- `--tol-pass N` — relative error threshold for PASS (default: 1e-3 = 0.1%)

**Workflow:**
1. Build BigOSpice release binary (`cargo build --release -p bigospice-cli`)
2. Auto-detect simulators in PATH
3. For each corpus circuit:
   - Run ngspice and BigOSpice
   - Compare outputs via Python script (parse rawfile, compare node values)
   - Only run hyperfine timing if accuracy PASSES
4. Print table: Circuit | BigOSpice | ngspice | Accuracy | Speed
5. Final geomean speedup and accuracy pass rate

**Accuracy check:** Parses ngspice ASCII rawfile and BigOSpice text output, compares shared `v(*)` nodes. Max relative error vs `max(|ng|, 1e-12)`.

### 4.2 Fixture Corpus (`tests/fixtures/`)

**Categories:**
- `basic/` — RC circuits, CMOS inverter, diff pair, current mirror, RLC bandpass, etc.
- `ngspice/` — ngspice reference circuits (bjt, mos, resistor, jfet, lc, etc.)
- `xyce/` — Xyce reference circuits (diode, npn/pnp BJT, nmos, vpulse, vsin, etc.)
- `quick/` — Quick sanity checks (rc step, rlc underdamped, cmos inverter, sensitivity, etc.)
- `scaling/` — Scaling benchmarks:
  - `rc_ladder_*.sp` — 10 to 100,000 RCs
  - `rc_mesh_NxN.sp` — 5x5 to 50x50 mesh
  - `inverter_chain_*.sp` — 10 to 1000 inverters
  - `ring_osc_*.sp` — 11 to 501 stage ring oscillators
  - `resistor_star_*.sp` — star topologies
- `adversarial/` — Edge cases: empty, no ground, floating node, zero resistance, etc.
- `medium/` — Medium complexity

### 4.3 Profiling Script (`scripts/profile.sh`)

```bash
nix develop --command bash scripts/profile.sh [NETLIST] [OUTPUT_SVG] [--bench NAME]
```

Uses `cargo-flamegraph` for CPU profiling. Builds release binary with debug info. Profiles either a specific netlist or a named benchmark.

---

## 5. Build System

### 5.1 Nix Flake (`flake.nix`)

**Default dev shell (`nix develop`):**
- Stable Rust with rust-src, rust-analyzer, clippy, rustfmt
- pkg-config, openssl, clang
- suitesparse, openblas, lapack (linear algebra)
- cmake, gnumake
- cargo-watch, cargo-nextest, cargo-tarpaulin, cargo-flamegraph, cargo-expand
- hyperfine (benchmarking)
- verilator, verible (mixed-signal cosimulation)
- `RUSTFLAGS="-C target-cpu=native"` for SIMD

**Full dev shell (`nix develop .#full`):**
Adds ngspice, Xyce, VACASK

**Environment variables:**
- `RUST_BACKTRACE=1`
- `RUST_LOG=bigospice=debug`
- `SUITESPARSE_DIR`, `OPENBLAS_DIR`

### 5.2 Build Commands

```bash
cargo build                    # debug build
cargo build --release          # release build
cargo test                     # run tests
RUSTFLAGS="-C target-cpu=native" cargo build --release  # SIMD-optimized
nix develop .#full --command bash scripts/run_benchmarks.sh  # full benchmarks
```

---

## 6. Key Architectural Observations

### 6.1 IO Crate Design Principles
1. **No analysis dependency** — all writers accept plain `&[Vec<f64>]` slices, enabling isolated testing
2. **Decoupled format dispatch** — `OutputFormat` enum for runtime selection
3. **Column-major SoA layout** — matches SoAVec structure for batch writes
4. **Comprehensive test coverage** — every module has round-trip tests (write → read → verify)

### 6.2 Missing CLI Integration
The CLI currently writes plain text output. The `bigospice-io` crate (with all its format writers) is **not yet integrated** into the CLI. The format selection via `--format` flag is absent.

### 6.3 Utility Crate DOD Philosophy
- **SoA over AoS** for hot loops over hundreds+ of items
- **Indices over pointers** — `u32` index beats 8-byte pointer
- **Existence-based processing** — `BitSet` for alive/dead, no per-item branching
- **Batch operations** — `&[f32]` slices processed by SIMD, not individual items
- **Arena for phase-scoped data** — O(1) allocation, O(1) bulk deallocation

### 6.4 Performance Target
Per CLAUDE.md: geomean **2.5x faster than ngspice** on 7/8 corpus items. `rc_ladder_10k.sp` is **20x slower** — primary Wave J target (BTF + sparse-LU).
