use std::path::Path;
use pisim_analysis::{
    AcSweepType, DcOpResult, AcResult, DcSweepResult, TransientResult,
    AcConfig, DcSweepConfig, TransientConfig,
};
use pisim_core::{Circuit, SimError};
use pisim_device::DeviceRegistry;
use pisim_parser::SpiceParser;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RunError {
    #[error("parse error: {0}")]
    Parse(#[from] SimError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("no analysis statement in netlist")]
    NoAnalysis,
}

pub fn parse_netlist_file(path: &Path) -> Result<(Circuit, Vec<pisim_parser::AnalysisStatement>), RunError> {
    let content = std::fs::read_to_string(path)?;
    let (circuit, analyses, _opts) = SpiceParser::parse(&content)?;
    Ok((circuit, analyses))
}

pub fn parse_netlist_str(input: &str) -> Result<(Circuit, Vec<pisim_parser::AnalysisStatement>), RunError> {
    let (circuit, analyses, _opts) = SpiceParser::parse(input)?;
    Ok((circuit, analyses))
}

pub fn run_dc_op(circuit: &Circuit) -> Result<DcOpResult, RunError> {
    let registry = DeviceRegistry::new_default();
    let output = pisim_analysis::run_dc_op(circuit, &registry)?;
    Ok(output.result)
}

pub fn run_dc_sweep(
    circuit: &Circuit,
    source: &str,
    start: f64,
    stop: f64,
    step: f64,
) -> Result<DcSweepResult, RunError> {
    let registry = DeviceRegistry::new_default();
    let config = DcSweepConfig::new(source, start, stop, step);
    let result = pisim_analysis::run_dc_sweep(circuit, &registry, &config)?;
    Ok(result)
}

pub fn run_transient(circuit: &Circuit, tstep: f64, tstop: f64) -> Result<TransientResult, RunError> {
    let registry = DeviceRegistry::new_default();
    let config = TransientConfig::new(tstep, tstop);
    let mut circuit = circuit.clone();
    let result = pisim_analysis::run_transient(&mut circuit, &registry, &config)?;
    Ok(result)
}

pub fn run_ac(
    circuit: &Circuit,
    fstart: f64,
    fstop: f64,
    npoints: usize,
    sweep_type: AcSweepType,
) -> Result<AcResult, RunError> {
    let registry = DeviceRegistry::new_default();
    let config = AcConfig::new(fstart, fstop, npoints, sweep_type);
    let result = pisim_analysis::run_ac(circuit, &registry, &config)?;
    Ok(result)
}
