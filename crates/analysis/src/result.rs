/// Unified simulation result container.
#[derive(Debug, Clone)]
pub struct SimResult {
    pub analysis: String,
    pub node_names: Vec<String>,
    pub data: ResultData,
}

#[derive(Debug, Clone)]
pub enum ResultData {
    DcOp(DcOpResult),
    DcSweep(DcSweepResult),
    Transient(TransientResult),
    Ac(AcResult),
}

#[derive(Debug, Clone)]
pub struct DcOpResult {
    pub node_voltages: Vec<(String, f64)>,
    pub branch_currents: Vec<(String, f64)>,
}

#[derive(Debug, Clone)]
pub struct DcSweepResult {
    pub sweep_param: String,
    pub sweep_values: Vec<f64>,
    /// node_voltages[sweep_point][node_index]
    pub node_voltages: Vec<Vec<f64>>,
}

#[derive(Debug, Clone)]
pub struct TransientResult {
    pub times: Vec<f64>,
    /// node_voltages[time_index][node_index] (legacy nested view).
    pub node_voltages: Vec<Vec<f64>>,
    /// Flat row-major buffer: index `step * num_nodes + node`. Preferred for new code.
    pub node_voltages_flat: Vec<f64>,
    /// Number of node-voltage entries per timestep (width of `node_voltages_flat`).
    pub num_nodes: usize,
    /// Names of branch current variables, in the same order as `branch_currents_flat`.
    /// One entry per MNA branch variable (voltage sources, inductors, etc.).
    pub branch_names: Vec<String>,
    /// Flat row-major branch current buffer: index `step * num_branches() + branch`.
    /// Empty when the circuit has no branch variables.
    pub branch_currents_flat: Vec<f64>,
}

impl TransientResult {
    /// Get the voltage at the given step and node from the flat buffer.
    #[inline]
    pub fn voltage(&self, step: usize, node: usize) -> f64 {
        self.node_voltages_flat[step * self.num_nodes + node]
    }

    /// Number of branch current variables recorded.
    #[inline]
    pub fn num_branches(&self) -> usize {
        self.branch_names.len()
    }

    /// Get the branch current at the given step and branch index.
    ///
    /// Panics if `branch_currents_flat` is empty or indices are out of range.
    #[inline]
    pub fn branch_current(&self, step: usize, branch: usize) -> f64 {
        self.branch_currents_flat[step * self.num_branches() + branch]
    }

    /// Number of timesteps stored.
    #[inline]
    pub fn num_steps(&self) -> usize {
        self.times.len()
    }
}

#[derive(Debug, Clone)]
pub struct AcResult {
    pub frequencies: Vec<f64>,
    /// Voltage magnitude per frequency per node: `node_magnitudes[freq][node]`.
    pub node_magnitudes: Vec<Vec<f64>>,
    /// Voltage phase (radians) per frequency per node: `node_phases[freq][node]`.
    pub node_phases: Vec<Vec<f64>>,
    /// Real part of complex node voltage per frequency: `node_reals[freq][node]`.
    pub node_reals: Vec<Vec<f64>>,
    /// Imaginary part of complex node voltage per frequency: `node_imags[freq][node]`.
    pub node_imags: Vec<Vec<f64>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dc_op_result_creation() {
        let r = DcOpResult {
            node_voltages: vec![("1".into(), 5.0), ("2".into(), 2.5)],
            branch_currents: vec![("V1".into(), -0.0025)],
        };
        assert_eq!(r.node_voltages.len(), 2);
    }

    #[test]
    fn transient_result_branch_accessors() {
        let r = TransientResult {
            times: vec![0.0, 1e-6],
            node_voltages: vec![vec![5.0], vec![5.0]],
            node_voltages_flat: vec![5.0, 5.0],
            num_nodes: 1,
            branch_names: vec!["v1".into()],
            branch_currents_flat: vec![-0.005, -0.005],
        };
        assert_eq!(r.num_branches(), 1);
        assert!((r.branch_current(0, 0) + 0.005).abs() < 1e-12);
    }
}
