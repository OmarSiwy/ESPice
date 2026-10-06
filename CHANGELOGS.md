# Changelog

Newest first. Bullets only, one line each. Every fix cites its GitHub issue,
`(#123)`; open one first if none exists.

## Unreleased

- An operating point whose Newton ran away (node voltages near 1e24 V) is
  refused instead of being published with exit 0; the ladder falls through to
  gmin stepping (#3).
- `zig build wasm`: espice.wasm (CPU, single-threaded, built-in models) and
  cktimg.wasm for the docs playground; `docs/playground.md` runs every spice block.
- Nix flake: `nix run github:OmarSiwy/ESPice`, `packages.espice` (CPU) and
  `espice-cuda` (CUDA), `overlays.default`, smoke `checks`; CI pushes builds
  to the `omarsiwy` Cachix cache.
- `.hdl` parameters named with `__`, a leading or trailing `_`, or a capital
  `Z` bind from the instance card instead of failing as unknown (#2).
- `bench-suites -Dsuite=cmcqa`: 3,218 single-device decks from the public CMC QA
  sets (HICUM/L2 2.4.0, PSP 103) and the GF180MCU BSIM4 regression, each with
  its reference results.
- `bench-suites -Dsuite=circuitsim90`: the 43 MCNC CircuitSim90 decks (MOS2,
  MOS3, BJT; up to chip2) from Xyce_Regression, converted to ngspice dialect.
- `bench-suites -Dsuite=ngspice`: 353 decks from ngspice-45's `tests/` and
  `examples/` and the Quality-page archives (paranoia, ISCAS85 on PTM 45 nm
  BSIM4, KiCad).
- `bench-suites -Dsuite=powergrid`: IBM power grids (ibmpg1-3, ibmpg1t) and
  SRAM-PG ssram with their reference solutions; `POWERGRID_LARGE=1` adds
  ibmpg4-8, ibmpg2t-6t and the multi-million-node SRAM-PG designs.

## 1.0.0 (2026-10-05)

- Zig 0.17.0. VerA (by its `v1.0.0` tag), Gompute and stdpp are pinned by git
  URL and content hash; `zig build --fork=<path>` builds against a local checkout.
- Licensed Apache-2.0. Models keep their own licences; see
  `models/LICENSES.md` (`bsim4va` is CC-BY-NC).
- stdpp pipelines carry the hot elementwise loops again, each with a scalar
  oracle test.
- Noise: table generators, `PsdTerm.coeff`, to-ground generators and
  correlated sources work in every noise analysis (device ABI 24).
- Verilog-A models see the stepped gmin and source scale during operating-point
  homotopy (`$simparam`), a documented divergence from ngspice.
- Verilog-A internal nets publish as `v(<instance>#<net>)` (device ABI 25).
- `--backend cuda|hip` fails, naming the detected hardware, instead of falling
  back to the CPU; `auto` still falls back.
- GPU instance sync merges host and device changes, so a parameter written
  after a GPU eval survives.
- C API: argument errors return `ESPICE_INVALID_ARGUMENT`.
- sky130 PDK decks run as written; PWL sources past 64 points chain instead of
  truncating; an OSDI card is an error naming the `.hdl` card to use.
- BSIM4 gets ngspice-style voltage limiting.
- A transient that ends within 100 ulps of `tstop` finishes, as in ngspice.
- About 90 hardening fixes across the parser, solvers, analyses, output and
  device loader (overflows, NaN guards, leaks, crashes on malformed decks),
  with over 300 new unit tests. Corpus: 797 of 799 decks pass.
- `zig build bench` passes each deck's dialect and reads empty plots;
  `test-gpu` skips decks with nothing GPU-eligible. README benchmark charts
  against ngspice and VACASK.
- `zig build bench-suites` fetches external SPICE suites at pinned revisions
  (`tests/suites/`) and benches ESPice against ngspice and VACASK on them.
- Release CI installs Zig 0.17.0 instead of 0.16.0, and the tarballs ship
  `LICENSE` and `CHANGELOGS.md` (#1).
- Removed `ref/` (SIMD notes and the standalone `verify.zig`) and `.agents/`;
  SIMD differential tests live in each module's `zig build test` suite.
