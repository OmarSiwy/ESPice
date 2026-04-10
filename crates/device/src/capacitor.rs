use smallvec::{SmallVec, smallvec};
use pisim_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Linear capacitor: 2-terminal device.
///
/// Pin 0 = positive terminal, Pin 1 = negative terminal.
/// Parameter: `capacitance` (farads).
///
/// Q = C * (V0 - V1). No DC resistive current.
#[derive(Debug, Clone, Copy)]
pub struct Capacitor;

impl DeviceModel for Capacitor {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let c = params.get_or("capacitance", 1e-12);
        let vd = voltages[0] - voltages[1];
        let charge = c * vd;

        DeviceEval {
            g: smallvec![0.0, 0.0],
            q: smallvec![charge, -charge],
            G: SmallVec::new(),
            C: smallvec![(0, 0, c), (0, 1, -c), (1, 0, -c), (1, 1, c)],
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Capacitor
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(c: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("capacitance", c);
        p
    }

    #[test]
    fn capacitor_charge() {
        let cap = Capacitor;
        let params = make_params(1e-6);
        let eval = cap.eval(&[5.0, 2.0], &params);

        let expected_q = 1e-6 * 3.0;
        assert!((eval.q[0] - expected_q).abs() < 1e-20);
        assert!((eval.q[1] + expected_q).abs() < 1e-20);
    }

    #[test]
    fn capacitor_no_dc_current() {
        let cap = Capacitor;
        let params = make_params(1e-9);
        let eval = cap.eval(&[10.0, 0.0], &params);

        assert!((eval.g[0]).abs() < 1e-20);
        assert!((eval.g[1]).abs() < 1e-20);
    }

    #[test]
    fn capacitor_jacobian() {
        let cap = Capacitor;
        let c = 4.7e-6;
        let params = make_params(c);
        let eval = cap.eval(&[1.0, 0.0], &params);

        assert_eq!(eval.C.len(), 4);
        assert!((eval.C[0].2 - c).abs() < 1e-20); // (0,0) = C
        assert!((eval.C[1].2 + c).abs() < 1e-20); // (0,1) = -C
        assert!((eval.C[2].2 + c).abs() < 1e-20); // (1,0) = -C
        assert!((eval.C[3].2 - c).abs() < 1e-20); // (1,1) = C
    }

    #[test]
    fn capacitor_jacobian_finite_difference() {
        let cap = Capacitor;
        let c = 2.2e-9;
        let params = make_params(c);
        let h = 1e-7;

        let v0 = [3.0, 1.0];
        let eval0 = cap.eval(&v0, &params);

        // Perturb V0
        let eval_p0 = cap.eval(&[v0[0] + h, v0[1]], &params);
        let dq0_dv0 = (eval_p0.q[0] - eval0.q[0]) / h;
        let dq1_dv0 = (eval_p0.q[1] - eval0.q[1]) / h;

        // Perturb V1
        let eval_p1 = cap.eval(&[v0[0], v0[1] + h], &params);
        let dq0_dv1 = (eval_p1.q[0] - eval0.q[0]) / h;
        let dq1_dv1 = (eval_p1.q[1] - eval0.q[1]) / h;

        assert!((dq0_dv0 - c).abs() < 1e-6 * c);
        assert!((dq0_dv1 + c).abs() < 1e-6 * c);
        assert!((dq1_dv0 + c).abs() < 1e-6 * c);
        assert!((dq1_dv1 - c).abs() < 1e-6 * c);
    }

    #[test]
    fn capacitor_zero_voltage() {
        let cap = Capacitor;
        let params = make_params(1e-6);
        let eval = cap.eval(&[0.0, 0.0], &params);

        assert!((eval.q[0]).abs() < 1e-20);
        assert!((eval.q[1]).abs() < 1e-20);
    }

    #[test]
    fn capacitor_various_values() {
        let cap = Capacitor;
        for &c_val in &[1e-15, 1e-12, 1e-9, 1e-6, 1e-3] {
            let params = make_params(c_val);
            let eval = cap.eval(&[1.0, 0.0], &params);
            assert!(
                (eval.q[0] - c_val).abs() < 1e-20 * c_val.recip().min(1e15),
                "Failed for C={c_val}"
            );
        }
    }
}
