### ESPice

An E(gyptian)Spice circuit simulator written in Zig, for full control over
performance and the careful optimizations that control buys. SPICE netlists in;
DC, AC, transient, PSS, noise and sweep analyses out. BSIM3, BSIM4, BSIMSOI and
Verilog-A models are supported natively: device models are compiled from
Verilog-A at build time rather than hand-ported.

Why the naming? The pyramids were built long ago from scratch, were ahead of
their time, and were built to last. This simulator is not ahead of its time, but
it is built to last.

#### Dependencies:

- Zig 0.16
- [VerA](https://github.com/OmarSiwy/VerA): the Verilog-A / Verilog frontends and the device contract
- [Gompute](https://github.com/OmarSiwy/Gompute): GPU compute; compiles the shared device kernels for host, CUDA and HIP

Both are pinned git dependencies in `build.zig.zon`, so a fresh checkout builds
on its own. Co-developing either one means pointing its entry back at a local
`.path` and restoring the pin before you push; the pinned build resolves to the
package cache and will not see your sibling checkout.

#### Project structure:

```
├── src/
│   ├── frontend/     # Netlist parsing (PSpice, Spectre, NGSpice/Xyce) and circuit construction
│   ├── analysis/     # DC/AC/tran/PSS/noise/sweep drivers; solvers/ is private to it
│   ├── problem/      # The owning API, and the C ABI behind include/espice.h
│   ├── output/       # Result writers (PSF, raw, CSV, Touchstone, FSDB)
│   └── main.zig      # CLI
├── models/           # Verilog-A device sources, compiled at build time
├── tests/            # Fixtures, cross-module suites and the bench runner
├── docs/             # Design notes and measured evidence
└── ref/              # SIMD strategy reference
```

`frontend` and `analysis` are siblings: neither imports the other. `problem`
composes both plus `output`, and `main` sees only `problem` and `output`.

#### Build:

```
nix develop                    # the toolchain
nix develop .#benchmarking     # adds ngspice and VACASK for the bench step

zig build           # compiles the app, and device GPU kernels for the detected arch
zig build test      # every suite
zig build bench     # compare against ngspice and VACASK
zig build run -- <netlist>
```

#### Frontend:

The frontend supports 3 netlist formats (PSpice, Spectre, NGSpice/Xyce), and
covers more analysis types than those simulators do.
