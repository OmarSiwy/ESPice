// tests/common/mod.rs
// Shared test utilities for all suite categories.
// Each suite file includes this via: #[path = "../common/mod.rs"] mod common;

#[allow(dead_code)]
pub mod tolerance;
#[allow(dead_code)]
pub mod rawfile;
#[allow(dead_code)]
pub mod golden;
#[allow(dead_code)]
pub mod runner;
#[allow(dead_code)]
pub mod ngspice;
#[allow(dead_code)]
pub mod vacask;
#[allow(dead_code)]
pub mod xyce;

// Re-exports used by various test binaries. Not every binary uses every
// symbol, so we allow unused imports here — each test binary uses a
// different subset.
#[allow(unused_imports)]
pub use tolerance::Tolerance;
#[allow(unused_imports)]
pub use golden::GoldenData;
#[allow(unused_imports)]
pub use runner::{parse_netlist_str, run_dc_op, run_dc_sweep, run_transient, run_ac};
#[allow(unused_imports)]
pub use rawfile::{RawFile, RawFlag};
#[allow(unused_imports)]
pub use ngspice::NgspiceConfig;
#[allow(unused_imports)]
pub use vacask::VacaskConfig;
#[allow(unused_imports)]
pub use xyce::XyceConfig;
