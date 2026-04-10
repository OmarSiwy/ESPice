//! Head-to-head benchmarking platform for PiSIM vs ngspice.
//!
//! Provides accuracy comparison and wall-clock performance measurement
//! across a curated corpus of SPICE netlists.

pub mod accuracy;
pub mod perf;

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Which analysis to drive end-to-end.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Analysis {
    Dc,
    Ac,
    Tran,
}

impl std::str::FromStr for Analysis {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "dc" | "op" => Ok(Analysis::Dc),
            "ac" => Ok(Analysis::Ac),
            "tran" | "transient" => Ok(Analysis::Tran),
            other => Err(format!("unknown analysis: {other}")),
        }
    }
}

/// Top-level run configuration for the bench CLI.
#[derive(Debug, Clone)]
pub struct BenchRunConfig {
    pub netlist: PathBuf,
    pub analysis: Analysis,
    pub nruns: usize,
    pub with_ngspice: bool,
    pub report: Option<PathBuf>,
}

/// Final per-netlist report record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BenchReport {
    pub netlist: String,
    pub analysis: String,
    pub pisim_status: String,
    pub ngspice_status: String,
    pub perf: perf::PerfReport,
    pub accuracy: Option<accuracy::AccuracyReport>,
}
