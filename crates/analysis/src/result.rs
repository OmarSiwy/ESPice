/// Unified simulation result container.
#[derive(Debug, Clone)]
pub struct SimResult {
    pub analysis: String,
    pub node_names: Vec<String>,
    pub data: ResultData,
}

#[derive(Debug, Clone)]
pub enum ResultData {
    DcOp(DcOpResultVec),
    DcSweep(DcSweepResult),
    Transient(TransientResult),
    Ac(AcResult),
    Sp(crate::sp::SpResult),
    Hb(crate::hb::HbResult),
    Pss(crate::pss::PssResult),
    PoleZero(PoleZeroResultData),
    Sensitivity(SensitivityResultData),
}

/// Pole-zero analysis result stored in `ResultData`.
#[derive(Debug, Clone)]
pub struct PoleZeroResultData {
    /// Poles as (real, imaginary) pairs.
    pub poles: Vec<(f64, f64)>,
}

/// DC sensitivity analysis result stored in `ResultData`.
#[derive(Debug, Clone)]
pub struct SensitivityResultData {
    /// Nominal node voltages.
    pub nominal: Vec<f64>,
    /// One entry per (device, parameter) pair: `(device, param, absolute_sensitivities)`.
    pub entries: Vec<(String, String, Vec<f64>)>,
}

/// Internal DC OP result using `Vec<(String, f64)>` for ordered iteration.
/// Used by internal analyses and control/ROL modules.
#[derive(Debug, Clone)]
pub struct DcOpResultVec {
    pub node_voltages: Vec<(String, f64)>,
    pub branch_currents: Vec<(String, f64)>,
}

/// Public DC OP result wrapping an `OpPoint`.
/// Returned by `run_dc_op` for external callers.
#[derive(Debug, Clone)]
pub struct DcOpResult {
    pub result: OpPoint,
}

/// Named voltage and current maps for a DC operating point.
#[derive(Debug, Clone)]
pub struct OpPoint {
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
    pub branch_names: Vec<String>,
    /// Flat row-major branch current buffer: index `step * num_branches() + branch`.
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
    /// Names of branch current variables, matching the order of `branch_reals`/`branch_imags`.
    pub branch_names: Vec<String>,
    /// Real part of complex branch current per frequency: `branch_reals[freq][branch]`.
    pub branch_reals: Vec<Vec<f64>>,
    /// Imaginary part of complex branch current per frequency: `branch_imags[freq][branch]`.
    pub branch_imags: Vec<Vec<f64>>,
}

#[derive(Debug, Clone)]
pub struct TemperaturePoint<T> {
    pub temperature_kelvin: f64,
    pub result: T,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dc_op_result_creation() {
        let r = DcOpResultVec {
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

    #[test]
    fn transient_result_num_steps() {
        let r = TransientResult {
            times: vec![0.0, 1e-9, 2e-9],
            node_voltages: vec![vec![1.0], vec![2.0], vec![3.0]],
            node_voltages_flat: vec![1.0, 2.0, 3.0],
            num_nodes: 1,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };
        assert_eq!(r.num_steps(), 3);
    }

    #[test]
    fn transient_result_voltage_accessor() {
        let r = TransientResult {
            times: vec![0.0, 1.0],
            node_voltages: vec![vec![3.0, 4.0], vec![5.0, 6.0]],
            node_voltages_flat: vec![3.0, 4.0, 5.0, 6.0],
            num_nodes: 2,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };
        assert!((r.voltage(0, 0) - 3.0).abs() < 1e-15);
        assert!((r.voltage(0, 1) - 4.0).abs() < 1e-15);
        assert!((r.voltage(1, 0) - 5.0).abs() < 1e-15);
        assert!((r.voltage(1, 1) - 6.0).abs() < 1e-15);
    }

    #[test]
    fn transient_result_no_branches() {
        let r = TransientResult {
            times: vec![0.0],
            node_voltages: vec![vec![1.0]],
            node_voltages_flat: vec![1.0],
            num_nodes: 1,
            branch_names: vec![],
            branch_currents_flat: vec![],
        };
        assert_eq!(r.num_branches(), 0);
        assert_eq!(r.num_steps(), 1);
    }

    #[test]
    fn dc_op_result_vec_node_lookup() {
        let r = DcOpResultVec {
            node_voltages: vec![("vdd".into(), 5.0), ("out".into(), 2.5)],
            branch_currents: vec![("V1".into(), -0.005)],
        };
        let out_v = r.node_voltages.iter()
            .find(|(n, _)| n == "out").map(|(_, v)| *v);
        assert_eq!(out_v, Some(2.5));
    }

    #[test]
    fn dc_sweep_result_fields() {
        let r = DcSweepResult {
            sweep_param: "V1".into(),
            sweep_values: vec![1.0, 2.0, 3.0],
            node_voltages: vec![vec![0.5], vec![1.0], vec![1.5]],
        };
        assert_eq!(r.sweep_values.len(), 3);
        assert_eq!(r.node_voltages.len(), 3);
        assert!((r.node_voltages[1][0] - 1.0).abs() < 1e-15);
    }

    #[test]
    fn ac_result_fields_consistent() {
        let r = AcResult {
            frequencies: vec![100.0, 200.0],
            node_magnitudes: vec![vec![0.9], vec![0.7]],
            node_phases: vec![vec![-0.1], vec![-0.5]],
            node_reals: vec![vec![0.9], vec![0.65]],
            node_imags: vec![vec![-0.1], vec![-0.3]],
            branch_names: vec![],
            branch_reals: vec![vec![], vec![]],
            branch_imags: vec![vec![], vec![]],
        };
        assert_eq!(r.frequencies.len(), 2);
        assert_eq!(r.node_magnitudes.len(), 2);
        assert_eq!(r.node_phases.len(), 2);
    }

    #[test]
    fn transient_result_branch_current_two_steps() {
        let r = TransientResult {
            times: vec![0.0, 1e-6, 2e-6],
            node_voltages: vec![vec![5.0], vec![5.0], vec![5.0]],
            node_voltages_flat: vec![5.0, 5.0, 5.0],
            num_nodes: 1,
            branch_names: vec!["V1".into()],
            branch_currents_flat: vec![-0.005, -0.005, -0.005],
        };
        assert!((r.branch_current(2, 0) + 0.005).abs() < 1e-12);
    }
}
