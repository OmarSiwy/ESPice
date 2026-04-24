use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

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

    /// KCL antisymmetry: charge stored at pin 0 must equal negated charge at pin 1.
    #[test]
    fn capacitor_kcl_antisymmetry() {
        let cap = Capacitor;
        let c = 33e-9_f64;
        let params = make_params(c);
        for &(v0, v1) in &[(5.0_f64, 0.0_f64), (-2.0, 3.0), (0.0, -10.0)] {
            let eval = cap.eval(&[v0, v1], &params);
            assert!(
                (eval.q[0] + eval.q[1]).abs() < 1e-20,
                "KCL charge antisymmetry violated at V=({v0},{v1}): q[0]={} q[1]={}",
                eval.q[0],
                eval.q[1]
            );
        }
    }

    /// The capacitor has no resistive current (g is always zero).
    #[test]
    fn capacitor_always_zero_resistive_current() {
        let cap = Capacitor;
        let params = make_params(100e-9);
        for &(v0, v1) in &[(0.0_f64, 0.0_f64), (5.0, 0.0), (-3.0, 7.0)] {
            let eval = cap.eval(&[v0, v1], &params);
            assert!(
                eval.g[0].abs() < 1e-20 && eval.g[1].abs() < 1e-20,
                "resistive current should always be zero, got g={:?}",
                (eval.g[0], eval.g[1])
            );
        }
    }

    /// Capacitance Jacobian stamps: C matrix has exactly 4 entries and the
    /// (0,0) entry equals `C` while (0,1) and (1,0) equal `-C`.
    #[test]
    fn capacitor_c_stamp_structure() {
        let cap = Capacitor;
        let c = 10e-12_f64;
        let params = make_params(c);
        let eval = cap.eval(&[1.0, 0.0], &params);

        assert_eq!(eval.C.len(), 4, "C matrix must have 4 entries");

        // Find each (row, col) entry. Row and col indices are u8.
        let find = |r: u8, col: u8| {
            eval.C.iter().find(|&&(ri, ci, _)| ri == r && ci == col).map(|&(_, _, v)| v)
        };
        let c00 = find(0, 0).expect("C[0,0] missing");
        let c01 = find(0, 1).expect("C[0,1] missing");
        let c10 = find(1, 0).expect("C[1,0] missing");
        let c11 = find(1, 1).expect("C[1,1] missing");

        assert!((c00 - c).abs() < 1e-20, "C[0,0]={c00} expected {c}");
        assert!((c11 - c).abs() < 1e-20, "C[1,1]={c11} expected {c}");
        assert!((c01 + c).abs() < 1e-20, "C[0,1]={c01} expected -{c}");
        assert!((c10 + c).abs() < 1e-20, "C[1,0]={c10} expected -{c}");
    }

    /// Default capacitance parameter fallback: when `capacitance` is not set,
    /// the model uses 1 pF by default.
    #[test]
    fn capacitor_default_capacitance_fallback() {
        let cap = Capacitor;
        let p = ParamMap::new(); // no "capacitance" set
        let eval = cap.eval(&[1.0, 0.0], &p);
        let default_c = 1e-12_f64;
        assert!(
            (eval.q[0] - default_c).abs() < 1e-20,
            "default capacitance should be 1 pF, got q[0]={}",
            eval.q[0]
        );
    }

    /// Charge is linear in voltage: Q(2V) = 2 * Q(1V).
    #[test]
    fn capacitor_charge_linearity() {
        let cap = Capacitor;
        let c = 470e-12_f64;
        let params = make_params(c);

        let eval1 = cap.eval(&[1.0, 0.0], &params);
        let eval2 = cap.eval(&[2.0, 0.0], &params);

        assert!(
            (eval2.q[0] - 2.0 * eval1.q[0]).abs() < 1e-20,
            "charge should be linear: Q(2V)={} 2*Q(1V)={}",
            eval2.q[0],
            2.0 * eval1.q[0]
        );
    }

    /// The G (resistive Jacobian) is always empty for a capacitor.
    #[test]
    fn capacitor_g_jacobian_empty() {
        let cap = Capacitor;
        let params = make_params(1e-6);
        let eval = cap.eval(&[5.0, 2.0], &params);
        assert!(
            eval.G.is_empty(),
            "capacitor G (resistive Jacobian) should be empty, got {} entries",
            eval.G.len()
        );
    }
}
