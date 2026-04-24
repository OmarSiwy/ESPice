//! Public API — supplementary types and free functions for the analysis crate.
//!
//! Most types (`TransientConfig`, `IntegrationMethod`, `AcConfig`, etc.) are
//! defined in their respective sub-modules and re-exported from `lib.rs`.
//! This module adds only the types that do not belong to any single analysis:
//!   - `DcSweepConfig` / `run_dc_sweep`
//!   - `NestedDcConfig` / `NestedDcResult` / `run_nested_dc`

use incspice_core::{Circuit, SimError};
use incspice_solver::device::DeviceRegistry;
use crate::result::{DcSweepResult, OpPoint};

// ── DC sweep config ──────────────────────────────────────────────────────────

/// Configuration for a DC sweep analysis.
pub struct DcSweepConfig {
    pub source: String,
    pub start: f64,
    pub stop: f64,
    pub step: f64,
}

impl DcSweepConfig {
    pub fn new(source: &str, start: f64, stop: f64, step: f64) -> Self {
        Self {
            source: source.to_string(),
            start,
            stop,
            step,
        }
    }
}

// ── Nested DC sweep config ───────────────────────────────────────────────────

/// Configuration for a nested (double-sweep) DC analysis.
pub struct NestedDcConfig {
    pub outer_source: String,
    pub outer_param: String,
    pub outer_values: Vec<f64>,
    pub inner_source: String,
    pub inner_param: String,
    pub inner_values: Vec<f64>,
}

impl NestedDcConfig {
    pub fn new(
        outer_src: &str,
        outer_param: &str,
        outer_vals: Vec<f64>,
        inner_src: &str,
        inner_param: &str,
        inner_vals: Vec<f64>,
    ) -> Self {
        Self {
            outer_source: outer_src.to_string(),
            outer_param: outer_param.to_string(),
            outer_values: outer_vals,
            inner_source: inner_src.to_string(),
            inner_param: inner_param.to_string(),
            inner_values: inner_vals,
        }
    }
}

// ── NestedDcResult ────────────────────────────────────────────────────────────

/// Result of a nested (double) DC sweep analysis.
#[derive(Debug, Clone)]
pub struct NestedDcResult {
    pub points: Vec<OpPoint>,
}

// ── Free functions ───────────────────────────────────────────────────────────

/// Run a DC sweep analysis.
///
/// Steps `cfg.source` from `cfg.start` to `cfg.stop` by `cfg.step` and
/// returns all node voltages at each step.
pub fn run_dc_sweep(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &DcSweepConfig,
) -> Result<DcSweepResult, SimError> {
    use incspice_solver::Solver;

    let mut circuit_mut = circuit.clone();
    let solver = Solver::default();
    let nv = circuit.num_vars() as usize;

    let values = sweep_values(cfg.start, cfg.stop, cfg.step)?;
    let mut node_voltages: Vec<Vec<f64>> = Vec::with_capacity(values.len());

    for &val in &values {
        circuit_mut.set_device_param(&cfg.source, "dc", val);
        let result = solver.solve(&circuit_mut, registry, None)?;
        let voltages: Vec<f64> = result.solution[..nv].to_vec();
        node_voltages.push(voltages);
    }

    Ok(DcSweepResult {
        sweep_param: cfg.source.clone(),
        sweep_values: values,
        node_voltages,
    })
}

/// Run a nested (double) DC sweep analysis.
///
/// For each outer value sweeps the inner source and records one `OpPoint`
/// per combination.
pub fn run_nested_dc(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    cfg: &NestedDcConfig,
) -> Result<NestedDcResult, SimError> {
    use incspice_solver::Solver;

    let mut circuit_mut = circuit.clone();
    let solver = Solver::default();
    let nv = circuit.num_vars() as usize;
    let nb = circuit.num_branches() as usize;

    let mut points: Vec<OpPoint> = Vec::with_capacity(
        cfg.outer_values.len() * cfg.inner_values.len(),
    );

    for &outer_val in &cfg.outer_values {
        set_source_param(&mut circuit_mut, &cfg.outer_source, &cfg.outer_param, outer_val);

        for &inner_val in &cfg.inner_values {
            set_source_param(&mut circuit_mut, &cfg.inner_source, &cfg.inner_param, inner_val);

            let result = solver.solve(&circuit_mut, registry, None)?;
            let solution = &result.solution;

            let node_voltages: Vec<(String, f64)> = circuit_mut
                .nodes()
                .iter()
                .filter_map(|n| {
                    n.matrix_index.map(|mi| {
                        let v = solution.get(mi as usize).copied().unwrap_or(0.0);
                        (n.name.clone(), v)
                    })
                })
                .collect();

            let branch_currents: Vec<(String, f64)> = circuit_mut
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

            let _ = nb;
            points.push(OpPoint { node_voltages, branch_currents });
        }
    }

    Ok(NestedDcResult { points })
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn sweep_values(start: f64, stop: f64, step: f64) -> Result<Vec<f64>, SimError> {
    if step == 0.0 {
        return Err(SimError::Analysis("DC sweep step must be non-zero".into()));
    }
    let wrong_direction = (step > 0.0 && start > stop) || (step < 0.0 && start < stop);
    if wrong_direction {
        return Err(SimError::Analysis(format!(
            "DC sweep step {step} does not move from start={start} toward stop={stop}"
        )));
    }

    let mut vals = Vec::new();
    let eps = step.abs() * 1e-9;
    let ascending = step > 0.0;
    let mut v = start;
    while if ascending { v <= stop + eps } else { v >= stop - eps } {
        vals.push(v);
        v += step;
    }
    Ok(vals)
}

fn set_source_param(circuit: &mut Circuit, source: &str, param: &str, value: f64) {
    if param == "temp" {
        circuit.set_device_param(source, "temp", value);
    } else {
        circuit.set_device_param(source, param, value);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transient::IntegrationMethod;

    #[test]
    fn test_dc_sweep_config_new() {
        let cfg = DcSweepConfig::new("V1", 0.0, 5.0, 0.5);
        assert_eq!(cfg.source, "V1");
        assert_eq!(cfg.start, 0.0);
        assert_eq!(cfg.stop, 5.0);
        assert_eq!(cfg.step, 0.5);
    }

    #[test]
    fn test_nested_dc_config_new() {
        let cfg = NestedDcConfig::new(
            "V2",
            "dc",
            vec![1.0, 2.0, 3.0],
            "V1",
            "dc",
            vec![0.0, 0.5, 1.0],
        );
        assert_eq!(cfg.outer_source, "V2");
        assert_eq!(cfg.outer_param, "dc");
        assert_eq!(cfg.outer_values.len(), 3);
        assert_eq!(cfg.inner_source, "V1");
        assert_eq!(cfg.inner_param, "dc");
        assert_eq!(cfg.inner_values.len(), 3);
    }

    #[test]
    fn test_transient_config_with_adaptive_sets_flag() {
        use crate::transient::TransientConfig;
        let cfg = TransientConfig::with_adaptive(1e-9, 1e-6, IntegrationMethod::Trapezoidal);
        assert!(cfg.adaptive);
        assert_eq!(cfg.tstep, 1e-9);
        assert_eq!(cfg.tstop, 1e-6);
        assert_eq!(cfg.method, IntegrationMethod::Trapezoidal);
    }

    #[test]
    fn test_integration_method_trapezoidal() {
        let m = IntegrationMethod::Trapezoidal;
        assert_eq!(m, IntegrationMethod::Trapezoidal);
        assert_ne!(m, IntegrationMethod::BackwardEuler);
        assert_ne!(m, IntegrationMethod::Gear2);
    }
}
