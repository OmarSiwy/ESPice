//! Analysis trait — every analysis type implements this.

use incspice_cache::CacheManager;
use incspice_core::{Circuit, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use thiserror::Error;
use incspice_solver::SolverError;

#[derive(Debug, Error)]
pub enum AnalysisError {
    #[error("solver: {0}")]
    Solver(#[from] SolverError),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

pub trait Analysis {
    /// Run analysis, streaming results through sink.
    fn run(
        &self,
        circuit: &mut Circuit,
        registry: &DeviceRegistry,
        config: &NrConfig,
        cache: &mut CacheManager,
        sink: &mut dyn StreamingSink,
    ) -> Result<(), AnalysisError>;

    fn name(&self) -> &str;
}
