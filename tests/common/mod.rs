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
