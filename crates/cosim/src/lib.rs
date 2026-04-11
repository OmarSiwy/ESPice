//! `bigospice-cosim` — Verilator / SystemVerilog co-simulation bridge.
//!
//! Phase 4.2 of the BigOSpice mixed-signal plan.  We do **not** bundle, link,
//! redistribute, or wrap Verilator's source code in any way; instead we treat
//! the user's `verilator --cc design.v --build -j` *output* (a `libdesign.so`
//! shared object) as a black box and dispatch into it via `libloading`.
//!
//! ## Public API summary
//!
//! ```text
//! VerilatorModel        — RAII wrapper around a loaded `.so`
//! VerilatorSymbols      — function-pointer table resolved at load time
//! DCosim                — `d_cosim` device exposing the model as digital nodes
//! ClockMode             — clock-driven vs continuous-assignment
//! DpiBridge             — DPI-C callback registry
//! ```
//!
//! See `tests/spi_master.rs` for an end-to-end example using a SystemVerilog
//! SPI master driven from BigOSpice (the test is `#[ignore]` if Verilator is not
//! available on `PATH`).

pub(crate) mod loader;
pub(crate) mod d_cosim;
pub(crate) mod dpi;
pub(crate) mod clock_mode;

pub use loader::{CosimError, VerilatorModel, VerilatorSymbols};
pub use d_cosim::{DCosim, DCosimPort, PortDirection};
pub use clock_mode::{ClockMode, ClockSpec};
pub use dpi::{DpiBridge, DpiCallback};
