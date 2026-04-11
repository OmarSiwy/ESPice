use smallvec::{SmallVec, smallvec};
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Voltage-Controlled Current Source (VCCS / G-element): 4-terminal, no branch.
///
/// Pin 0 = output+, Pin 1 = output-, Pin 2 = control+, Pin 3 = control-.
/// Parameter: `gm` (transconductance, default 1e-3).
///
/// I_out = gm * (V2 - V3), flowing from pin 0 to pin 1.
#[derive(Debug, Clone, Copy)]
pub struct Vccs;

impl DeviceModel for Vccs {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let gm = params.get_or("gm", 1e-3);
        let vc = voltages[2] - voltages[3];
        let iout = gm * vc;

        DeviceEval {
            g: smallvec![iout, -iout, 0.0, 0.0],
            q: smallvec![0.0, 0.0, 0.0, 0.0],
            G: smallvec![
                (0, 2, gm),
                (0, 3, -gm),
                (1, 2, -gm),
                (1, 3, gm),
            ],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        4
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Vccs
    }
}

// ─── VccsExpr: G-source VALUE={expr} / TABLE form ────────────────────────────

/// Stateless model placeholder for G-source `VALUE={expr}` and `TABLE` forms.
///
/// When the parser encounters:
///   `G<name> n+ n- VALUE={expr}`
///   `G<name> n+ n- TABLE(expr) = (x1,y1) (x2,y2) ...`
///
/// it stores a `BsourceExpr` in `Circuit::bsource_exprs` (indexed by device
/// id) and records the device kind as `DeviceKind::VccsExpr`.  The stamper
/// detects `VccsExpr` and takes the same expression-evaluation path as
/// `BsourceI`, using `eval_bsource_i` with the stored expression.
///
/// This struct satisfies the `DeviceModel` trait bound in `DeviceDispatch`
/// but its `eval` method is **never called** on the hot path — the stamper
/// bypasses it just like it does for `BsourceIModel`.
///
/// Pin layout (for `num_terminals` reporting only):
///   Pin 0 = output+, Pin 1 = output-
///   The control nodes are encoded in `BsourceExpr::node_refs`.
#[derive(Debug, Clone, Copy)]
pub struct VccsExpr;

impl DeviceModel for VccsExpr {
    fn eval(&self, _voltages: &[f64], _params: &ParamMap) -> DeviceEval {
        // Never called on the hot path; stamper handles VccsExpr directly.
        DeviceEval::new()
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        false
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::VccsExpr
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vccs_output_current() {
        let g = Vccs;
        let mut params = ParamMap::new();
        params.set("gm", 0.01);
        let eval = g.eval(&[0.0, 0.0, 3.0, 1.0], &params);
        assert!((eval.g[0] - 0.02).abs() < 1e-15);
        assert!((eval.g[1] + 0.02).abs() < 1e-15);
    }

    #[test]
    fn vccs_no_branch() {
        assert!(!Vccs.needs_branch());
    }

    #[test]
    fn vccs_expr_model_kind_and_branch() {
        let m = VccsExpr;
        assert_eq!(m.kind(), DeviceKind::VccsExpr);
        assert!(!m.needs_branch());
        assert_eq!(m.num_terminals(), 2);
        // eval returns an empty DeviceEval (stamper takes the special path).
        let eval = m.eval(&[1.0, 0.0], &ParamMap::new());
        assert!(eval.g.is_empty());
    }
}
