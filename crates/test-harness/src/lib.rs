pub mod tolerance;
pub mod compare;
pub mod golden;
pub mod config;
pub mod runner;
pub mod rawfile;
pub mod ngspice;
pub mod report;

pub use tolerance::Tolerance;
pub use compare::{CompareResult, SignalMismatch, compare_dc_values, compare_waveforms};
pub use golden::GoldenData;
pub use config::{TestConfig, discover_tests, ExternalSuite, ReferenceMeta};
pub use runner::{parse_netlist_file, parse_netlist_str, run_dc_op, run_dc_sweep, run_transient, run_ac};
pub use rawfile::{RawFile, RawFlag, RawVariable, RawFileError};
pub use ngspice::{NgspiceConfig, NgspiceResult, NgspiceError};
pub use report::{ComparisonReport, ReportEntry, TestStatus};
