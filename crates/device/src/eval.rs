use smallvec::SmallVec;
use pisim_core::{DeviceKind, ParamMap};

/// Result of evaluating a device model at a given operating point.
///
/// - `g` = resistive current contributions (one per terminal/branch row)
/// - `q` = charge/flux contributions (one per terminal/branch row)
/// - `G` = dg/dx conductance Jacobian entries: `(row_pin, col_pin, value)`
/// - `C` = dq/dx capacitance Jacobian entries: `(row_pin, col_pin, value)`
/// - `rhs` = direct RHS contributions (for independent sources)
#[derive(Debug, Clone)]
#[allow(non_snake_case)]
pub struct DeviceEval {
    /// Resistive currents per terminal/branch row.
    pub g: SmallVec<[f64; 8]>,
    /// Charges per terminal/branch row.
    pub q: SmallVec<[f64; 8]>,
    /// Conductance Jacobian: (row_pin, col_pin, value).
    pub G: SmallVec<[(u8, u8, f64); 8]>,
    /// Capacitance Jacobian: (row_pin, col_pin, value).
    pub C: SmallVec<[(u8, u8, f64); 8]>,
    /// RHS contributions (for sources).
    pub rhs: SmallVec<[f64; 4]>,
}

impl DeviceEval {
    /// Create a new empty `DeviceEval`.
    pub fn new() -> Self {
        Self {
            g: SmallVec::new(),
            q: SmallVec::new(),
            G: SmallVec::new(),
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }
}

impl Default for DeviceEval {
    fn default() -> Self {
        Self::new()
    }
}

/// The device model trait. Every device implements this.
///
/// Models compute resistive contributions `g(x)`, reactive contributions `q(x)`,
/// and their Jacobians `G = dg/dx`, `C = dq/dx`.
pub trait DeviceModel: Send + Sync {
    /// Evaluate g(x), q(x), G, C at the given terminal voltages.
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval;

    /// Number of external terminals.
    fn num_terminals(&self) -> usize;

    /// Whether this device needs a branch current variable in MNA.
    fn needs_branch(&self) -> bool {
        false
    }

    /// Device kind.
    fn kind(&self) -> DeviceKind;

    /// Evaluate with branch current (for V-sources, inductors).
    fn eval_with_branch(
        &self,
        voltages: &[f64],
        _branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        self.eval(voltages, params)
    }

    /// Evaluate at a specific simulation time `t` (seconds).
    ///
    /// This is the time-aware variant used by transient analysis so that
    /// independent sources can produce time-varying waveforms.  The default
    /// implementation delegates to `eval`, which is correct for all devices
    /// whose output does not depend on absolute simulation time (resistors,
    /// capacitors, MOSFETs, …).
    ///
    /// Override this in `VoltageSource` and `CurrentSource` to evaluate the
    /// configured waveform at `t` rather than always using `t = 0`.
    fn eval_at_time(&self, voltages: &[f64], params: &ParamMap, _t: f64) -> DeviceEval {
        self.eval(voltages, params)
    }

    /// Evaluate with branch current at a specific simulation time `t`.
    ///
    /// Like `eval_at_time` but also supplies the branch current for devices
    /// that need it (voltage sources, inductors).  The default implementation
    /// delegates to `eval_with_branch`.
    fn eval_with_branch_at_time(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
        _t: f64,
    ) -> DeviceEval {
        self.eval_with_branch(voltages, branch_current, params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_eval_default() {
        let e = DeviceEval::new();
        assert!(e.g.is_empty());
        assert!(e.q.is_empty());
        assert!(e.G.is_empty());
        assert!(e.C.is_empty());
        assert!(e.rhs.is_empty());
    }
}
