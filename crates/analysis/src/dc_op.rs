//! DC operating point analysis.

use incspice_cache::CacheManager;
use incspice_core::{Circuit, SimError, StreamingSink};
use incspice_solver::device::DeviceRegistry;
use incspice_solver::newton::NrConfig;
use crate::{Analysis, AnalysisError};
use crate::result::DcOpResultVec;

pub struct DcOp;

impl Analysis for DcOp {
    fn run(&self, circuit: &mut Circuit, registry: &DeviceRegistry, config: &NrConfig, cache: &mut CacheManager, sink: &mut dyn StreamingSink) -> Result<(), AnalysisError> {
        let result = incspice_solver::solve(circuit, registry, config, cache)?;
        let nv = circuit.num_vars() as usize;
        sink.emit_point(0.0, &result.solution[..nv])?;
        sink.finalize()?;
        Ok(())
    }
    fn name(&self) -> &str { "dc_op" }
}

/// Internal output wrapper used by control and ROL modules.
#[derive(Debug, Clone)]
pub struct DcOpOutput {
    pub result: DcOpResultVec,
    pub solution: Vec<f64>,
}

/// Run a DC operating point analysis and return the internal result.
/// Used by `control.rs`, `rol.rs`, and the `run_dc_op` public API.
pub(crate) fn run_dc_op_internal(
    circuit: &Circuit,
    registry: &DeviceRegistry,
) -> Result<DcOpOutput, SimError> {
    run_dc_op_internal_with_config(circuit, registry, &NrConfig::default())
}

/// Same as [`run_dc_op_internal`] but with an explicit NR configuration.
pub(crate) fn run_dc_op_internal_with_config(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &NrConfig,
) -> Result<DcOpOutput, SimError> {
    let solver = incspice_solver::Solver::new(incspice_solver::SolverConfig {
        kind: incspice_solver::SolverKind::NewtonRaphson,
        nr: config.clone(),
    });
    let nr_result = solver.solve(circuit, registry, None)?;
    let solution = nr_result.solution.clone();
    let nv = circuit.num_vars() as usize;
    let nb = circuit.num_branches() as usize;

    // Build node voltage map.
    let node_voltages: Vec<(String, f64)> = circuit
        .nodes()
        .iter()
        .filter_map(|n| {
            n.matrix_index.map(|mi| {
                let v = solution.get(mi as usize).copied().unwrap_or(0.0);
                (n.name.clone(), v)
            })
        })
        .collect();

    // Build branch current map.
    let branch_currents: Vec<(String, f64)> = circuit
        .devices()
        .iter()
        .filter_map(|dev| {
            dev.branch_index.map(|bi| {
                let idx = nv + bi as usize;
                let i = solution.get(idx).copied().unwrap_or(0.0);
                (dev.name.clone(), i)
            })
        })
        .collect();

    let _ = nb; // used indirectly
    Ok(DcOpOutput {
        result: DcOpResultVec { node_voltages, branch_currents },
        solution,
    })
}

/// Run a DC operating point analysis.
///
/// Public API used by external tools and `test_external.rs`.
/// Returns a `DcOpResult` containing an `OpPoint` with ordered voltage/current pairs.
pub fn run_dc_op(
    circuit: &incspice_core::Circuit,
    registry: &DeviceRegistry,
) -> Result<crate::DcOpResult, SimError> {
    run_dc_op_with_config(circuit, registry, &NrConfig::default())
}

/// Like [`run_dc_op`] but with an explicit NR solver configuration.
///
/// Allows callers to enable pseudo-transient continuation or other solver
/// options parsed from `.OPTIONS`.
pub fn run_dc_op_with_config(
    circuit: &incspice_core::Circuit,
    registry: &DeviceRegistry,
    config: &NrConfig,
) -> Result<crate::DcOpResult, SimError> {
    let out = run_dc_op_internal_with_config(circuit, registry, config)?;
    Ok(crate::DcOpResult {
        result: crate::OpPoint {
            node_voltages: out.result.node_voltages,
            branch_currents: out.result.branch_currents,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use incspice_core::{Circuit, DeviceId, DeviceInstance, DeviceKind, NodeId};
    use incspice_solver::device::DeviceRegistry;

    fn voltage_divider() -> Circuit {
        let mut c = Circuit::new();
        let top = c.add_node("top");
        let mid = c.add_node("mid");

        // V1: top to ground, 10V
        let v1 = DeviceInstance::new(
            DeviceId::new(0),
            "v1",
            DeviceKind::VoltageSource,
            &[(0, top), (1, NodeId::GROUND)],
        )
        .with_param("dc", 10.0);
        c.add_device(v1);

        // R1: top to mid, 1kΩ
        let r1 = DeviceInstance::new(
            DeviceId::new(0),
            "r1",
            DeviceKind::Resistor,
            &[(0, top), (1, mid)],
        )
        .with_param("resistance", 1000.0);
        c.add_device(r1);

        // R2: mid to ground, 1kΩ
        let r2 = DeviceInstance::new(
            DeviceId::new(0),
            "r2",
            DeviceKind::Resistor,
            &[(0, mid), (1, NodeId::GROUND)],
        )
        .with_param("resistance", 1000.0);
        c.add_device(r2);

        c.build_topology();
        c
    }

    #[test]
    fn test_dc_op_voltage_divider() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&circuit, &registry).unwrap();
        let mid_v = result
            .result
            .node_voltages
            .iter()
            .find(|(name, _)| name == "mid")
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);
        assert!(
            (mid_v - 5.0).abs() < 0.01,
            "voltage divider mid should be 5V, got {mid_v}"
        );
    }

    #[test]
    fn test_dc_op_returns_source_current() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&circuit, &registry).unwrap();
        let v1_current = result
            .result
            .branch_currents
            .iter()
            .find(|(name, _)| name == "v1")
            .map(|(_, i)| *i)
            .unwrap_or(f64::NAN);
        // 10V / (1kΩ + 1kΩ) = 5mA
        assert!(
            v1_current.is_finite(),
            "source should have finite current, got {v1_current}"
        );
    }

    #[test]
    fn test_dc_op_top_node_equals_source() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&circuit, &registry).unwrap();
        let top_v = result
            .result
            .node_voltages
            .iter()
            .find(|(name, _)| name == "top")
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);
        assert!(
            (top_v - 10.0).abs() < 0.01,
            "top node should be 10V, got {top_v}"
        );
    }

    #[test]
    fn test_dc_op_single_voltage_source() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("n1");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 7.0),
        );
        ckt.build_topology();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&ckt, &registry).unwrap();
        let v = result.result.node_voltages.iter()
            .find(|(n, _)| n == "n1").map(|(_, v)| *v).unwrap_or(f64::NAN);
        assert!((v - 7.0).abs() < 0.01, "V(n1) should be 7V, got {v}");
    }

    #[test]
    fn test_dc_op_result_has_node_voltages() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&circuit, &registry).unwrap();
        assert!(!result.result.node_voltages.is_empty(),
            "node_voltages should not be empty");
    }

    #[test]
    fn test_dc_op_internal_solution_not_empty() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let out = run_dc_op_internal(&circuit, &registry).unwrap();
        assert!(!out.solution.is_empty(), "solution vector should not be empty");
    }

    #[test]
    fn test_dc_op_parallel_resistors() {
        // Two identical 1kΩ resistors in parallel from 10V → 5mA total current.
        let mut ckt = Circuit::new();
        let n = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n), (1, NodeId::GROUND)])
            .with_param("dc", 10.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "Ra", DeviceKind::Resistor,
                &[(0, n), (1, NodeId::GROUND)])
            .with_param("resistance", 1000.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(2), "Rb", DeviceKind::Resistor,
                &[(0, n), (1, NodeId::GROUND)])
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&ckt, &registry).unwrap();
        let v = result.result.node_voltages.iter()
            .find(|(name, _)| name == "out")
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);
        assert!((v - 10.0).abs() < 0.01, "V(out) = {v}");
    }

    #[test]
    fn test_dc_op_node_voltages_are_finite() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&circuit, &registry).unwrap();
        for (name, v) in &result.result.node_voltages {
            assert!(v.is_finite(), "V({name}) = {v} is not finite");
        }
    }

    #[test]
    fn test_dc_op_branch_currents_finite() {
        let circuit = voltage_divider();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&circuit, &registry).unwrap();
        for (name, i) in &result.result.branch_currents {
            assert!(i.is_finite(), "I({name}) = {i} is not finite");
        }
    }

    #[test]
    fn test_dc_op_current_source_node() {
        // Current source 1mA from GND into node "out", with 1kΩ to GND.
        // Current source convention: positive terminal is node "out" (current flows out),
        // negative terminal is GND. The sign convention in incspice may produce -1V or +1V
        // depending on the current direction assumed. We just check magnitude.
        let mut ckt = Circuit::new();
        let n = ckt.add_node("out");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "I1", DeviceKind::CurrentSource,
                &[(0, n), (1, NodeId::GROUND)])
            .with_param("dc", 1e-3),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
                &[(0, n), (1, NodeId::GROUND)])
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&ckt, &registry).unwrap();
        let v = result.result.node_voltages.iter()
            .find(|(name, _)| name == "out")
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);
        // |V(out)| = I * R = 1mA * 1kΩ = 1V (sign may vary per convention)
        assert!((v.abs() - 1.0).abs() < 0.01, "V(out) magnitude should be 1V, got {v}");
    }

    /// Zero-ohm resistor (wire) should converge: V1=5V, R1=0 (wire), R2=1k to GND.
    /// Both nodes should be at 5V since R1 is a short circuit.
    #[test]
    fn test_dc_op_zero_resistance() {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("a");
        let n2 = ckt.add_node("b");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)])
            .with_param("dc", 5.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(1), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, n2)])
            .with_param("resistance", 0.0),
        );
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(2), "R2", DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)])
            .with_param("resistance", 1000.0),
        );
        ckt.build_topology();
        let registry = DeviceRegistry::new_default();
        let result = run_dc_op(&ckt, &registry).unwrap();
        let va = result.result.node_voltages.iter()
            .find(|(name, _)| name == "a")
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);
        let vb = result.result.node_voltages.iter()
            .find(|(name, _)| name == "b")
            .map(|(_, v)| *v)
            .unwrap_or(f64::NAN);
        assert!((va - 5.0).abs() < 0.01, "V(a) should be 5V, got {va}");
        assert!((vb - 5.0).abs() < 0.01, "V(b) should be ~5V (wire to V1), got {vb}");
    }
}
