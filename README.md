# IncSpice

An incremental SPICE circuit simulator built in Rust.

## Overview

IncSpice is a high-performance SPICE simulator focused on incremental computation and caching to accelerate iterative design workflows. Rather than re-simulating entire circuits from scratch, IncSpice tracks what changed and recomputes only what's necessary.

## Workspace Crates

| Crate | Description |
|-------|-------------|
| `incspice-core` | Core data structures: circuit graph, devices, nodes, parameters, stamps |
| `incspice-parser` | Netlist tokenizer and parser (SPICE, HSPICE dialects) |
| `incspice-solver` | Newton-Raphson solver, sparse LU, device models (BSIM3/4, BJT, diode, etc.) |
| `incspice-cache` | Incremental computation engine, topology caching, Woodbury updates |
| `incspice-analysis` | Analysis types: DC, AC, transient, noise, Monte Carlo, S-parameters, etc. |
| `incspice-cli` | Command-line interface and output formatting (rawfile, CSV, Touchstone) |

## Building

```bash
cargo build --release
```

## Testing

```bash
# Unit tests across all crates
cargo test --workspace

# External test suite (SPICE netlists)
cargo test --test test_external
```

## Benchmarks

```bash
cargo bench --bench bench_external
```

## License

LGPL-3.0
