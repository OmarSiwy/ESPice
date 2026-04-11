use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Current-Controlled Voltage Source (CCVS / H-element).
///
/// Pin 0 = output+, Pin 1 = output-.
/// Branch index = 2 (the local branch row for the output current).
///
/// Control: rather than introducing a separate control branch row, the
/// CCVS reads the control current from a *referenced* voltage source's
/// branch current variable. The parser stores that referenced branch
/// index as `ctrl_branch` in the device's params, and the stamper passes
/// it via the global solution vector during evaluation.
///
/// Because the local pin layout doesn't include the control branch row,
/// the constraint `Vout - rm * I_ctrl = 0` cannot be reduced to a pure
/// local stamp; instead the residual on the local branch row uses the
/// pre-resolved `ctrl_current` (read by the stamper at the right offset)
/// passed in via params under the key `ctrl_current`. The dispatch layer
/// performs that pre-resolution before calling `eval_with_branch`.
///
/// Parameter: `transresistance` (default 1.0, ohms).
///
/// MNA:
///   KCL at pin 0:  ... + I_branch = 0
///   KCL at pin 1:  ... - I_branch = 0
///   Branch eq:     V0 - V1 - rm * I_ctrl = 0
///
/// Where `I_ctrl` is the branch current of the *referenced* vsource,
/// which the stamper resolves into the param `ctrl_current` immediately
/// before calling this device's eval. This keeps the device fully local
/// (no need to know other devices' branch indices itself).
#[derive(Debug, Clone, Copy)]
pub struct Ccvs;

impl DeviceModel for Ccvs {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        let rm = params.get_or("transresistance", 1.0);
        let i_ctrl = params.get_or("ctrl_current", 0.0);

        let v0 = voltages[0];
        let v1 = voltages[1];
        let i_br = branch_current;

        // Branch equation residual: V0 - V1 - rm * I_ctrl
        let branch_eq = v0 - v1 - rm * i_ctrl;

        DeviceEval {
            g: smallvec![i_br, -i_br, branch_eq],
            q: smallvec![0.0, 0.0, 0.0],
            G: smallvec![
                (0, 2, 1.0),    // dg[0] / dI_br
                (1, 2, -1.0),   // dg[1] / dI_br
                (2, 0, 1.0),    // dbranch / dV0
                (2, 1, -1.0),   // dbranch / dV1
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Ccvs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(rm: f64, i_ctrl: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("transresistance", rm);
        p.set("ctrl_current", i_ctrl);
        p
    }

    #[test]
    fn ccvs_branch_equation_zero_at_satisfied() {
        // V_out = rm * I_ctrl  =>  branch residual should be zero
        let h = Ccvs;
        let params = make_params(2.0, 1.5);
        // Vout = 3.0 V across pins
        let eval = h.eval_with_branch(&[3.0, 0.0], 0.01, &params);
        assert!((eval.g[2]).abs() < 1e-15, "branch residual {}", eval.g[2]);
    }

    #[test]
    fn ccvs_branch_equation_violated() {
        let h = Ccvs;
        let params = make_params(2.0, 1.0);  // expected V = 2.0
        let eval = h.eval_with_branch(&[5.0, 0.0], 0.0, &params);
        // Residual = 5 - 0 - 2*1 = 3
        assert!((eval.g[2] - 3.0).abs() < 1e-15);
    }

    #[test]
    fn ccvs_jacobian_structure() {
        let h = Ccvs;
        let params = make_params(1.0, 0.0);
        let eval = h.eval_with_branch(&[1.0, 0.0], 0.0, &params);
        assert_eq!(eval.G.len(), 4);
        assert_eq!(eval.G[0], (0, 2, 1.0));
        assert_eq!(eval.G[1], (1, 2, -1.0));
        assert_eq!(eval.G[2], (2, 0, 1.0));
        assert_eq!(eval.G[3], (2, 1, -1.0));
    }

    #[test]
    fn ccvs_needs_branch() {
        assert!(Ccvs.needs_branch());
    }

    #[test]
    fn ccvs_kind() {
        assert_eq!(Ccvs.kind(), DeviceKind::Ccvs);
    }

    #[test]
    fn ccvs_num_terminals() {
        assert_eq!(Ccvs.num_terminals(), 2);
    }
}
