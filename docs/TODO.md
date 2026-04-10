# PiSIM — Open Work

**State (2026-04-10):** Waves A–N complete. Waves O/P/Q/R/T/U/V largely complete (see below). Remaining work: O.1 brace-expr wiring, O.15 OSDI verification, P.1/P.2/P.5/P.6 performance, Q.1–Q.6/Q.8 advanced analysis, R.5 .control integration test, U.1–U.3 MOSFET Level 2/3/6 (in progress), U.5/U.6/U.8 device stubs, W.1–W.6 integration & polish. Targeting full drop-in parity with ngspice, HSPICE, and Xyce.

---

## Wave O — Correctness Bugs

### O.1 Brace expressions everywhere
Wire `{expr}` into every numeric slot (element values, model params, source amplitudes).
Evaluator exists in `expr.rs`; only call sites in `spice.rs` are missing.

### O.15 OSDI end-to-end verification
Run `scripts/build_va_models.sh`, enable `tests/integration/osdi_va_golden.rs`.
Test Berkeley BSIM4.8 Verilog-A + BSIM-CMG via OpenVAF.
`crates/osdi/`, `scripts/`

---

## Wave P — Performance

### P.1 rc_ladder_10k regression (primary target)
10 000-node transient is ~20x slower than ngspice. Implement BTF decomposition.
`crates/linalg/src/`

### P.2 KLU linear solver backend
FFI to SuiteSparse libklu (already in the nix shell). Directly addresses large-circuit slowness.
`crates/linalg/src/klu.rs` (new), `crates/parser/src/spice.rs` (`.LINSOL` directive)

### P.5 WGSL BSIM4 eval kernel
Wire existing WGSL shader into `eval_bsim4_batch`.
`crates/compute/`

### P.6 Benchmark numbers
Run full bench suite, populate `docs/PERFORMANCE.md`, caveat the "200x ngspice" claim.

---

## Wave Q — Advanced Analysis

### Q.1 N-tone Harmonic Balance
Add N-tone (full spectral Toeplitz block). Currently limited to single-tone and two-tone.
`crates/analysis/src/hb.rs`

### Q.2 Periodic Steady State (PSS)
For circuits with periodic forcing. Builds on shooting-method HB.
`crates/analysis/src/pss.rs` (new)

### Q.3 Envelope Following
AM/FM modulated system analysis for RF mixer, PLL simulations.
`crates/analysis/src/envelope.rs` (new)

### Q.4 HB ↔ OSDI integration
OSDI-loaded models (HICUM, PSP) callable from harmonic balance solver.
`crates/analysis/src/hb.rs`, `crates/osdi/`

### Q.5 BDF order 3–5
`SimOptions::maxord` is parsed but only Gear-2 (BDF-2) is wired. Add Gear-3/4/5.
`crates/analysis/src/companion.rs`, `crates/analysis/src/transient.rs`

### Q.6 `.SAMPLING` quasi-Monte Carlo
Latin Hypercube / quasi-MC analysis (Xyce feature).
`crates/analysis/src/sampling.rs` (new)

### Q.8 Transient checkpoint restart
Parametric sweep over transient restarts from the nearest checkpoint.
`TransientArena` infrastructure exists in `crates/cache/src/checkpoint.rs`; needs wiring
into `run_transient` time loop and a `run_transient_from_checkpoint` entry point.
`crates/analysis/src/transient.rs`, `crates/cache/`

---

## Wave R — .control Scripting Shell

### R.5 Integration test
Script with `foreach` sweep, `.tran`, `meas` rise time, `wrdata` — verified vs ngspice.

---

## Wave T — Parser & Expression Completeness

### T.7 `.OPTIONS` category dispatch
Xyce uses `.OPTIONS NONLIN key=val`, `.OPTIONS LINSOL key=val`, `.OPTIONS TIMEINT key=val`.
Current `parse_options` is a flat key=val bag. Add category dispatch.
`crates/parser/src/spice.rs`, `crates/core/src/options.rs`

---

## Wave U — Device Model Completeness

### U.5 URC element (Uniform RC line)
`U` element prefix. Approximated internally by LTRA ladder.
`crates/device/src/urc.rs` (new), parser `U` prefix

### U.6 W-element lossy line (frequency-domain tabulated)
Xyce `W` element takes tabulated S/Y/Z-parameter files — distinct from LTRA.
`crates/device/src/wlossy.rs` (new)

### U.8 `PORT` element for S-parameter analysis
HSPICE `PORT` element drives `.SP` port excitation. No `DeviceKind` variant or parser dispatch.
`crates/device/src/port.rs` (new), `crates/core/src/device.rs`, `crates/parser/src/spice.rs`

---

## Wave W — Integration & Polish

### W.1 Test suite clean
`cargo test --workspace` fully passing or every failure intentionally `#[ignore]`d with issue link.

### W.2 Mixed-signal integration test
Schmitt trigger → digital counter → DAC, simulated end-to-end.
`crates/digital/`, `crates/cosim/`

### W.3 Documentation
- `docs/DEVICES.md` — supported device models with parameter tables.
- `docs/NETLIST.md` — all supported SPICE cards and expressions.
- `docs/EXAMPLES/` — working example netlists per analysis type.
- Update `FEATURES.md` with complete supported-feature checklist.
- Caveat or remove "200x ngspice / 300x xyce" from `CLAUDE.md` pending real measurements.

### W.4 `.ROL` reliability/aging analysis
Xyce-specific electromigration / NBTI / HCI analysis.
`crates/analysis/src/rol.rs` (new)

### W.5 HSPICE `.EXTRACT` statements
Post-simulation measurement extraction with `AC`/`DC`/`TRAN` qualifiers and `par()` results.
`crates/parser/src/spice.rs`, `crates/analysis/src/measure.rs` — **in progress** (agent a9ca445e7cf40f16c)

### W.6 `.CONNECT` directive
Short-circuit two named nets at the netlist level.
`crates/parser/src/spice.rs`, `crates/core/src/circuit.rs` — **in progress** (agent a9ca445e7cf40f16c)
