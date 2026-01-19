### ESPice

An E(gyptian)Spice circuit simulator written in Zig, for full control over
performance and the careful optimizations that control buys. SPICE netlists in;
DC, AC, transient, PSS, noise and sweep analyses out. BSIM3, BSIM4, BSIMSOI and
Verilog-A models are supported natively — device models are compiled from
Verilog-A at build time rather than hand-ported.

Why the naming? The pyramids were built long ago from scratch, were ahead of
their time, and were built to last. This simulator is not ahead of its time, but
it is built to last.

#### Dependencies:

- Zig 0.16
- `../VerA` — the Verilog-A / Verilog frontends and the device contract
- `../gompute` — GPU compute; compiles the shared device kernels for host, CUDA and HIP
- Verilator (only for the digital HDL models)

Both sibling packages are path dependencies (`build.zig.zon`), so they must sit
beside this checkout.

#### Project Structure:

```
├── src/
│   ├── solvers/      # Sparse LU, Newton, the lane-parallel frequency solver
│   ├── devices/      # Device engine: the derivative scalar, SoA batching, GPU kernels
│   ├── analysis/     # DC/AC/tran/PSS/noise/sweep drivers
│   ├── frontend/     # Netlist parsing (PSpice, Spectre, NGSpice/Xyce)
│   ├── output/       # Result writers (PSF and friends)
│   └── main.zig      # CLI
├── benchmark/        # Fixtures and the bench-runner (its own package)
├── tests/            # Cross-module suites
├── docs/             # Design notes and measured evidence
└── ref/              # SIMD strategy reference and differential oracles
```

Module dependency order is `solvers → devices → analysis → builder → main`.

#### Build:

```
zig build           # compiles the app, and device GPU kernels for the detected arch
zig build test      # every suite
zig build bench     # benchmarks
zig build run -- <netlist>
```

#### Frontend:

The frontend supports 3 netlist formats (PSpice, Spectre, NGSpice/Xyce), and
covers more analysis types than those simulators do.
