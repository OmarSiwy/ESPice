use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Voltage-Controlled Voltage Source (VCVS / E-element): 4-terminal + branch.
///
/// Pin 0 = output+, Pin 1 = output-, Pin 2 = control+, Pin 3 = control-.
/// Branch index = 4 (the branch current row in the local system).
/// Parameter: `gain` (voltage gain, default 1.0).
///
/// MNA formulation:
///   KCL at pin 0: ... + I_branch = 0
///   KCL at pin 1: ... - I_branch = 0
///   Branch eq: V0 - V1 = gain * (V2 - V3)
#[derive(Debug, Clone, Copy)]
pub struct Vcvs;

impl DeviceModel for Vcvs {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        self.eval_with_branch(voltages, 0.0, params)
    }

    fn eval_with_branch(
        &self,
        voltages: &[f64],
        branch_current: f64,
        params: &ParamMap,
    ) -> DeviceEval {
        let gain = params.get_or("gain", 1.0);
        let v0 = voltages[0];
        let v1 = voltages[1];
        let v2 = voltages[2];
        let v3 = voltages[3];
        let i_br = branch_current;

        let branch_eq = v0 - v1 - gain * (v2 - v3);

        DeviceEval {
            g: smallvec![i_br, -i_br, 0.0, 0.0, branch_eq],
            q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 4, 1.0),
                (1, 4, -1.0),
                (4, 0, 1.0),
                (4, 1, -1.0),
                (4, 2, -gain),
                (4, 3, gain),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn needs_branch(&self) -> bool {
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Vcvs
    }
}

// ─── VcvsExpr: E-source VALUE={expr} / TABLE form ────────────────────────────

/// Stateless model placeholder for E-source `VALUE={expr}` and `TABLE` forms.
///
/// When the parser encounters:
///   `E<name> n+ n- VALUE={expr}`
///   `E<name> n+ n- TABLE(expr) = (x1,y1) (x2,y2) ...`
///
/// it stores a `BsourceExpr` in `Circuit::bsource_exprs` (indexed by device
/// id) and records the device kind as `DeviceKind::VcvsExpr`.  The stamper
/// detects `VcvsExpr` and takes the same expression-evaluation path as
/// `BsourceV`, using `eval_bsource_v` with the stored expression.
///
/// This struct satisfies the `DeviceModel` trait bound in `DeviceDispatch`
/// but its `eval` / `eval_with_branch` methods are **never called** on the
/// hot path — the stamper bypasses them just like it does for `BsourceVModel`.
///
/// Pin layout (for `num_terminals` reporting only):
///   Pin 0 = output+, Pin 1 = output-
///   The control nodes are encoded in `BsourceExpr::node_refs`.
#[derive(Debug, Clone, Copy)]
pub struct VcvsExpr;

impl DeviceModel for VcvsExpr {
    fn eval(&self, _voltages: &[f64], _params: &ParamMap) -> DeviceEval {
        // Never called on the hot path; stamper handles VcvsExpr directly.
        DeviceEval::new()
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::VcvsExpr
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vcvs_branch_equation() {
        let e = Vcvs;
        let mut params = ParamMap::new();
        params.set("gain", 2.0);
        let eval = e.eval_with_branch(&[6.0, 0.0, 3.0, 0.0], 0.01, &params);
        assert!((eval.g[4]).abs() < 1e-15);
    }

    #[test]
    fn vcvs_needs_branch() {
        assert!(Vcvs.needs_branch());
    }

    #[test]
    fn vcvs_expr_model_kind_and_branch() {
        let m = VcvsExpr;
        assert_eq!(m.kind(), DeviceKind::VcvsExpr);
        assert!(m.needs_branch());
        assert_eq!(m.num_terminals(), 2);
        // eval returns an empty DeviceEval (stamper takes the special path).
        let eval = m.eval(&[1.0, 0.0], &ParamMap::new());
        assert!(eval.g.is_empty());
    }
}
