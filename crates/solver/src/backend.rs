use incspice_core::{Circuit, SimError};
use crate::device::DeviceRegistry;

use crate::newton::{NewtonRaphson, NrConfig, NrResult, VoltagePin};

/// Which nonlinear solver algorithm to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SolverKind {
    NewtonRaphson,
    // Future: PseudoTransient, HomotopyContinuation, etc.
}

/// Unified solver configuration.
#[derive(Debug, Clone)]
pub struct SolverConfig {
    pub kind: SolverKind,
    pub nr: NrConfig, // Newton-Raphson specific config
}

impl Default for SolverConfig {
    fn default() -> Self {
        Self {
            kind: SolverKind::NewtonRaphson,
            nr: NrConfig::default(),
        }
    }
}

/// The solver enum — selected at initialization, zero-cost dispatch per iteration.
pub enum Solver {
    NewtonRaphson(NewtonRaphson),
}

impl Solver {
    pub fn new(config: SolverConfig) -> Self {
        match config.kind {
            SolverKind::NewtonRaphson => Self::NewtonRaphson(NewtonRaphson::new(config.nr)),
        }
    }

    /// Build a `Solver` with configuration derived from `.OPTIONS` sim options.
    pub fn with_options(options: &incspice_core::SimOptions) -> Self {
        Self::NewtonRaphson(NewtonRaphson::new(NrConfig::from(options)))
    }

    pub fn solve(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        initial_guess: Option<&[f64]>,
    ) -> Result<NrResult, SimError> {
        match self {
            Self::NewtonRaphson(nr) => nr.solve(circuit, registry, initial_guess),
        }
    }

    pub fn solve_with_ic_pins(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        ic_pins: &[(usize, f64)],
    ) -> Result<NrResult, SimError> {
        match self {
            Self::NewtonRaphson(nr) => nr.solve_with_ic_pins(circuit, registry, ic_pins),
        }
    }

    pub fn solve_with_voltage_pins(
        &self,
        circuit: &Circuit,
        registry: &DeviceRegistry,
        pins: &[VoltagePin],
    ) -> Result<NrResult, SimError> {
        match self {
            Self::NewtonRaphson(nr) => nr.solve_with_voltage_pins(circuit, registry, pins),
        }
    }
}

impl Default for Solver {
    fn default() -> Self {
        Self::new(SolverConfig::default())
    }
}
