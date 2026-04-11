use bigospice_core::{Circuit, SimError};
use bigospice_device::DeviceRegistry;

use crate::newton::{NewtonRaphson, NrConfig, NrResult};

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
    pub fn with_options(options: &bigospice_core::SimOptions) -> Self {
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
}

impl Default for Solver {
    fn default() -> Self {
        Self::new(SolverConfig::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::convergence::ConvergenceCriteria;
    use bigospice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId, SimOptions};

    #[test]
    fn solver_from_simoptions_uses_provided_tolerances() {
        let mut opts = SimOptions::default();
        opts.abstol = 1e-15;
        opts.reltol = 1e-5;
        opts.vntol = 1e-7;
        opts.itl1 = 200;

        let criteria = ConvergenceCriteria::from(&opts);
        assert_eq!(criteria.abs_tol, 1e-15);
        assert_eq!(criteria.rel_tol, 1e-5);
        assert_eq!(criteria.v_tol, 1e-7);
        assert_eq!(criteria.max_iter, 200);

        // Also verify the solver builds and solves a trivial circuit with these options.
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let v1 = DeviceInstance::new(
            DeviceId::new(0), "V1", DeviceKind::VoltageSource,
            &[(0, n1), (1, NodeId::GROUND)],
        ).with_param("dc", 1.0);
        let r1 = DeviceInstance::new(
            DeviceId::new(0), "R1", DeviceKind::Resistor,
            &[(0, n1), (1, NodeId::GROUND)],
        ).with_param("resistance", 1000.0);
        ckt.add_device(v1);
        ckt.add_device(r1);
        ckt.build_topology();

        let solver = Solver::with_options(&opts);
        let reg = DeviceRegistry::new_default();
        let result = solver.solve(&ckt, &reg, None).unwrap();
        assert!(result.converged);
        assert!((result.solution[0] - 1.0).abs() < 1e-6);
    }
}
