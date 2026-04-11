use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Current-Controlled Current Source (CCCS / F-element).
///
/// Pin 0 = output+ (current exits), Pin 1 = output- (current enters).
///
/// Control: like the CCVS, the CCCS reads the control current from a
/// referenced voltage source's branch current. The stamper resolves the
/// referenced vsource's branch current and stores it in the param key
/// `ctrl_current` immediately before calling `eval`. The parser stores
/// the gain as `current_gain` and the referenced source name as
/// `ctrl_source` (consumed by the stamper, not by `eval`).
///
/// Parameter: `current_gain` (default 1.0, dimensionless current ratio).
///
/// I_out = current_gain * I_ctrl, flowing from pin 0 to pin 1.
/// Pure RHS contribution; no conductance terms (since I_ctrl is treated
/// as a known constant during stamp-time — the dependency is captured by
/// the stamper threading the actual control current at solve time, and
/// the linearization across the global Jacobian is handled by the
/// off-diagonal column in stamper.rs that maps pin currents to the
/// referenced branch column).
///
/// For now, this matches the simplest viable implementation: the value
/// is read at the current solution and stamped as RHS, which is correct
/// at converged Newton steps and gives quadratic convergence as long as
/// the control current is read from the *current* iterate.
#[derive(Debug, Clone, Copy)]
pub struct Cccs;

impl DeviceModel for Cccs {
    fn eval(&self, _voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let gain = params.get_or("current_gain", 1.0);
        let i_ctrl = params.get_or("ctrl_current", 0.0);
        let iout = gain * i_ctrl;

        DeviceEval {
            g: smallvec![0.0, 0.0],
            q: smallvec![0.0, 0.0],
            G: SmallVec::new(),
            C: SmallVec::new(),
            // RHS contributions: pin 0 emits current (positive), pin 1 sinks
            rhs: smallvec![iout, -iout],
        }
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        false
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Cccs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(gain: f64, i_ctrl: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("current_gain", gain);
        p.set("ctrl_current", i_ctrl);
        p
    }

    #[test]
    fn cccs_output_current() {
        let f = Cccs;
        let params = make_params(50.0, 1e-6);
        let eval = f.eval(&[0.0, 0.0], &params);
        // I_out = 50 * 1e-6 = 5e-5
        assert!((eval.rhs[0] - 5e-5).abs() < 1e-15);
        assert!((eval.rhs[1] + 5e-5).abs() < 1e-15);
    }

    #[test]
    fn cccs_zero_control() {
        let f = Cccs;
        let params = make_params(100.0, 0.0);
        let eval = f.eval(&[0.0, 0.0], &params);
        assert!(eval.rhs[0].abs() < 1e-30);
    }

    #[test]
    fn cccs_negative_gain() {
        let f = Cccs;
        let params = make_params(-2.0, 1e-3);
        let eval = f.eval(&[0.0, 0.0], &params);
        assert!((eval.rhs[0] + 2e-3).abs() < 1e-15);
    }

    #[test]
    fn cccs_no_branch() {
        assert!(!Cccs.needs_branch());
    }

    #[test]
    fn cccs_kind() {
        assert_eq!(Cccs.kind(), DeviceKind::Cccs);
    }
}
