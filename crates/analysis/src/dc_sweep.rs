use bigospice_core::{Circuit, SimError, SimOptions};
use bigospice_device::DeviceRegistry;
use bigospice_solver::{Solver, SolverConfig, NrConfig};

use crate::result::DcSweepResult;

/// Configuration for a DC sweep analysis.
#[derive(Debug, Clone)]
pub struct DcSweepConfig {
    pub source_name: String,
    pub param_name: String,
    pub start: f64,
    pub stop: f64,
    pub step: f64,
}

impl DcSweepConfig {
    pub fn new(source: &str, start: f64, stop: f64, step: f64) -> Self {
        Self {
            source_name: source.to_string(),
            param_name: "dc".to_string(),
            start, stop, step,
        }
    }
}

/// Run a DC sweep analysis — sweep a source parameter and solve at each point.
pub fn run_dc_sweep(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &DcSweepConfig,
) -> Result<DcSweepResult, SimError> {
    run_dc_sweep_inner(circuit, registry, config, None)
}

/// Run a DC sweep analysis with simulation options from `.OPTIONS`.
pub fn run_dc_sweep_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &DcSweepConfig,
    opts: &SimOptions,
) -> Result<DcSweepResult, SimError> {
    run_dc_sweep_inner(circuit, registry, config, Some(opts))
}

fn run_dc_sweep_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &DcSweepConfig,
    opts: Option<&SimOptions>,
) -> Result<DcSweepResult, SimError> {
    let mut ckt = circuit.clone();
    let num_nodes = ckt.num_vars() as usize;
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig { nr: NrConfig::from(o), ..SolverConfig::default() }),
        None => Solver::default(),
    };

    let mut sweep_values = Vec::new();
    let mut node_voltages = Vec::new();
    let mut prev_solution: Option<Vec<f64>> = None;

    let mut val = config.start;
    while val <= config.stop + config.step * 0.5 {
        ckt.set_device_param(&config.source_name, &config.param_name, val);

        let result = solver.solve(&ckt, registry, prev_solution.as_deref())?;

        sweep_values.push(val);
        node_voltages.push(result.solution[..num_nodes].to_vec());
        prev_solution = Some(result.solution);

        val += config.step;
    }

    Ok(DcSweepResult {
        sweep_param: format!("{}:{}", config.source_name, config.param_name),
        sweep_values,
        node_voltages,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::*;

    #[test]
    fn dc_sweep_voltage_divider() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 0.0));
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, n2)]).with_param("resistance", 1000.0));
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)]).with_param("resistance", 1000.0));
        ckt.build_topology();

        let reg = DeviceRegistry::new_default();
        let config = DcSweepConfig::new("V1", 0.0, 10.0, 2.0);
        let result = run_dc_sweep(&ckt, &reg, &config).unwrap();

        assert_eq!(result.sweep_values.len(), 6); // 0,2,4,6,8,10
        // V(2) should be half of V(1) at each point
        for (i, &v_src) in result.sweep_values.iter().enumerate() {
            let v2 = result.node_voltages[i][1]; // node 2 is index 1
            assert!((v2 - v_src / 2.0).abs() < 1e-4,
                "At V1={v_src}: V(2)={v2} expected {}", v_src / 2.0);
        }
    }
}
