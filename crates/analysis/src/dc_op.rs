use pisim_core::{Circuit, SimError, SimOptions};
use pisim_device::DeviceRegistry;
use pisim_solver::{Solver, SolverConfig, NrConfig};
use pisim_cache::IncrementalCache;

use crate::result::DcOpResult;

/// Result of a DC operating point analysis, including cache state for incremental re-use.
#[derive(Debug)]
pub struct DcOpOutput {
    pub result: DcOpResult,
    pub cache: IncrementalCache,
}

/// Extract node voltages and branch currents from solution vector.
fn extract_results(circuit: &Circuit, solution: &[f64]) -> DcOpResult {
    let node_voltages = circuit.nodes().iter()
        .filter_map(|node| node.matrix_index.map(|idx| (node.name.clone(), solution[idx as usize])))
        .collect();

    let branch_currents = circuit.devices().iter()
        .filter_map(|dev| dev.branch_index.map(|bi| {
            let idx = circuit.num_vars() as usize + bi as usize;
            (dev.name.clone(), solution[idx])
        }))
        .collect();

    DcOpResult { node_voltages, branch_currents }
}

/// Run a DC operating point analysis with default solver settings.
pub fn run_dc_op(
    circuit: &Circuit,
    registry: &DeviceRegistry,
) -> Result<DcOpOutput, SimError> {
    run_dc_op_with_config(circuit, registry, None, None)
}

/// Run a DC operating point analysis with optional solver config and cache.
pub fn run_dc_op_with_config(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    nr_config: Option<NrConfig>,
    cache: Option<&IncrementalCache>,
) -> Result<DcOpOutput, SimError> {
    let solver = match nr_config {
        Some(cfg) => Solver::new(SolverConfig { nr: cfg, ..SolverConfig::default() }),
        None => Solver::default(),
    };

    let warm_start = cache.and_then(|c| c.warm_start()).map(|s| s.to_vec());
    let nr_result = solver.solve(circuit, registry, warm_start.as_deref())?;

    let mut new_cache = IncrementalCache::new(circuit.devices().len());
    new_cache.store_topology(circuit);
    new_cache.store_op(&nr_result.solution);

    Ok(DcOpOutput {
        result: extract_results(circuit, &nr_result.solution),
        cache: new_cache,
    })
}

/// Run a DC operating point analysis with simulation options from `.OPTIONS`.
pub fn run_dc_op_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    opts: &SimOptions,
) -> Result<DcOpOutput, SimError> {
    run_dc_op_with_config(circuit, registry, Some(NrConfig::from(opts)), None)
}

/// Configuration for a two-variable nested DC sweep (N.1.4).
///
/// Sweeps `outer` across `outer_values` and `inner` across `inner_values` for
/// each outer point, producing `outer_values.len() × inner_values.len()` DC
/// operating points.
///
/// Both `outer_device`/`outer_param` and `inner_device`/`inner_param` identify
/// a device instance parameter to mutate (e.g. `"v1"` / `"dc"`).
#[derive(Debug, Clone)]
pub struct NestedDcConfig {
    pub outer_device: String,
    pub outer_param: String,
    pub outer_values: Vec<f64>,
    pub inner_device: String,
    pub inner_param: String,
    pub inner_values: Vec<f64>,
}

impl NestedDcConfig {
    /// Construct with explicit value vectors.
    pub fn new(
        outer_device: impl Into<String>,
        outer_param: impl Into<String>,
        outer_values: Vec<f64>,
        inner_device: impl Into<String>,
        inner_param: impl Into<String>,
        inner_values: Vec<f64>,
    ) -> Self {
        Self {
            outer_device: outer_device.into(),
            outer_param: outer_param.into(),
            outer_values,
            inner_device: inner_device.into(),
            inner_param: inner_param.into(),
            inner_values,
        }
    }
}

/// Result of a nested DC sweep.
///
/// `points[i * inner_len + j]` is the DC OP result for outer index `i` and
/// inner index `j`.  `outer_values` and `inner_values` are the corresponding
/// parameter values.
#[derive(Debug)]
pub struct NestedDcResult {
    pub outer_values: Vec<f64>,
    pub inner_values: Vec<f64>,
    /// Row-major: `points[outer_idx * inner_len + inner_idx]`.
    pub points: Vec<DcOpResult>,
}

impl NestedDcResult {
    /// Number of outer sweep points.
    pub fn outer_len(&self) -> usize {
        self.outer_values.len()
    }

    /// Number of inner sweep points.
    pub fn inner_len(&self) -> usize {
        self.inner_values.len()
    }

    /// Access a specific operating-point result by (outer, inner) index.
    pub fn get(&self, outer: usize, inner: usize) -> &DcOpResult {
        &self.points[outer * self.inner_len() + inner]
    }
}

/// Run a nested two-variable DC sweep (implements `.DC src1 … src2 …`).
///
/// Outer loop: set `outer_device.outer_param = outer_values[i]`.
/// Inner loop: set `inner_device.inner_param = inner_values[j]`, run DC OP.
///
/// Returns a row-major matrix of `DcOpResult`s.
pub fn run_nested_dc(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &NestedDcConfig,
) -> Result<NestedDcResult, SimError> {
    run_nested_dc_inner(circuit, registry, config, None)
}

/// Same as [`run_nested_dc`] but honours `.OPTIONS` Newton-solver settings.
pub fn run_nested_dc_with_options(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &NestedDcConfig,
    opts: &SimOptions,
) -> Result<NestedDcResult, SimError> {
    run_nested_dc_inner(circuit, registry, config, Some(opts))
}

fn run_nested_dc_inner(
    circuit: &Circuit,
    registry: &DeviceRegistry,
    config: &NestedDcConfig,
    opts: Option<&SimOptions>,
) -> Result<NestedDcResult, SimError> {
    let solver = match opts {
        Some(o) => Solver::new(SolverConfig { nr: NrConfig::from(o), ..SolverConfig::default() }),
        None => Solver::default(),
    };

    let n_outer = config.outer_values.len();
    let n_inner = config.inner_values.len();
    let mut points = Vec::with_capacity(n_outer * n_inner);

    let outer_lower = config.outer_device.to_lowercase();
    let inner_lower = config.inner_device.to_lowercase();

    for &outer_val in &config.outer_values {
        let mut outer_ckt = circuit.clone();
        if !outer_ckt.set_device_param(&outer_lower, &config.outer_param, outer_val) {
            return Err(SimError::Parse(format!(
                "nested_dc: outer device '{}' param '{}' not found",
                config.outer_device, config.outer_param
            )));
        }

        let mut prev_solution: Option<Vec<f64>> = None;
        for &inner_val in &config.inner_values {
            let mut ckt = outer_ckt.clone();
            if !ckt.set_device_param(&inner_lower, &config.inner_param, inner_val) {
                return Err(SimError::Parse(format!(
                    "nested_dc: inner device '{}' param '{}' not found",
                    config.inner_device, config.inner_param
                )));
            }

            let nr_result = solver.solve(&ckt, registry, prev_solution.as_deref())?;
            points.push(extract_results(&ckt, &nr_result.solution));
            prev_solution = Some(nr_result.solution);
        }
    }

    Ok(NestedDcResult {
        outer_values: config.outer_values.clone(),
        inner_values: config.inner_values.clone(),
        points,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use pisim_core::*;

    fn voltage_divider() -> Circuit {
        let mut ckt = Circuit::new();
        let n1 = ckt.add_node("1");
        let n2 = ckt.add_node("2");
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "V1", DeviceKind::VoltageSource,
                &[(0, n1), (1, NodeId::GROUND)]).with_param("dc", 5.0));
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R1", DeviceKind::Resistor,
                &[(0, n1), (1, n2)]).with_param("resistance", 1000.0));
        ckt.add_device(
            DeviceInstance::new(DeviceId::new(0), "R2", DeviceKind::Resistor,
                &[(0, n2), (1, NodeId::GROUND)]).with_param("resistance", 1000.0));
        ckt.build_topology();
        ckt
    }

    #[test]
    fn dc_op_voltage_divider() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let output = run_dc_op(&ckt, &reg).unwrap();

        assert_eq!(output.result.node_voltages.len(), 2);
        let v2 = output.result.node_voltages.iter().find(|(n, _)| n == "2").unwrap().1;
        assert!((v2 - 2.5).abs() < 1e-6, "V(2)={v2} expected 2.5");
    }

    #[test]
    fn dc_op_branch_current() {
        let ckt = voltage_divider();
        let reg = DeviceRegistry::new_default();
        let output = run_dc_op(&ckt, &reg).unwrap();

        assert_eq!(output.result.branch_currents.len(), 1);
        let iv1 = output.result.branch_currents[0].1;
        assert!((iv1 + 0.0025).abs() < 1e-6, "I(V1)={iv1} expected -0.0025");
    }
}
