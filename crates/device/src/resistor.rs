use smallvec::smallvec;
use bigospice_core::{DeviceKind, ParamMap};

use crate::eval::{DeviceEval, DeviceModel};

/// Linear resistor: 2-terminal device.
///
/// Pin 0 = positive terminal, Pin 1 = negative terminal.
/// Parameter: `resistance` (ohms).
///
/// I = (V0 - V1) / R, flowing from pin 0 to pin 1.
#[derive(Debug, Clone, Copy)]
pub struct Resistor;

impl DeviceModel for Resistor {
    fn eval(&self, voltages: &[f64], params: &ParamMap) -> DeviceEval {
        let r0   = params.get_or("resistance", 1e3);
        let tc1  = params.get_or("tc1", 0.0);
        let tc2  = params.get_or("tc2", 0.0);
        let temp = params.get_or("temp", 300.15);
        let tnom = params.get_or("tnom", 300.15);
        let dt   = temp - tnom;
        let r    = if tc1 != 0.0 || tc2 != 0.0 {
            (r0 * (1.0 + tc1 * dt + tc2 * dt * dt)).max(1e-12)
        } else {
            r0
        };
        let g = 1.0 / r;
        let vd = voltages[0] - voltages[1];
        let i = g * vd;

        DeviceEval {
            g: smallvec![i, -i],
            q: smallvec![0.0, 0.0],
            G: smallvec![(0, 0, g), (0, 1, -g), (1, 0, -g), (1, 1, g)],
            C: SmallVec::new(),
            rhs: SmallVec::new(),
        }
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::Resistor
    }
}

use smallvec::SmallVec;

#[cfg(test)]
mod tests {
    use super::*;

    fn make_params(r: f64) -> ParamMap {
        let mut p = ParamMap::new();
        p.set("resistance", r);
        p
    }

    #[test]
    fn resistor_basic_iv() {
        let res = Resistor;
        let params = make_params(1000.0);
        let eval = res.eval(&[5.0, 2.0], &params);

        let expected_i = 3.0 / 1000.0;
        assert!((eval.g[0] - expected_i).abs() < 1e-15);
        assert!((eval.g[1] + expected_i).abs() < 1e-15);
    }

    #[test]
    fn resistor_zero_voltage() {
        let res = Resistor;
        let params = make_params(100.0);
        let eval = res.eval(&[3.0, 3.0], &params);

        assert!((eval.g[0]).abs() < 1e-15);
        assert!((eval.g[1]).abs() < 1e-15);
    }

    #[test]
    fn resistor_negative_voltage() {
        let res = Resistor;
        let params = make_params(500.0);
        let eval = res.eval(&[1.0, 4.0], &params);

        let expected_i = -3.0 / 500.0;
        assert!((eval.g[0] - expected_i).abs() < 1e-15);
        assert!((eval.g[1] + expected_i).abs() < 1e-15);
    }

    #[test]
    fn resistor_jacobian() {
        let res = Resistor;
        let params = make_params(250.0);
        let eval = res.eval(&[1.0, 0.0], &params);

        let g = 1.0 / 250.0;
        // G should be [[g, -g], [-g, g]]
        assert_eq!(eval.G.len(), 4);
        assert!((eval.G[0].2 - g).abs() < 1e-15); // (0,0) = g
        assert!((eval.G[1].2 + g).abs() < 1e-15); // (0,1) = -g
        assert!((eval.G[2].2 + g).abs() < 1e-15); // (1,0) = -g
        assert!((eval.G[3].2 - g).abs() < 1e-15); // (1,1) = g
    }

    #[test]
    fn resistor_jacobian_finite_difference() {
        let res = Resistor;
        let params = make_params(470.0);
        let h = 1e-7;

        let v0 = [2.0, 1.0];
        let eval0 = res.eval(&v0, &params);

        // Perturb V0
        let eval_p0 = res.eval(&[v0[0] + h, v0[1]], &params);
        let dg0_dv0 = (eval_p0.g[0] - eval0.g[0]) / h;
        let dg1_dv0 = (eval_p0.g[1] - eval0.g[1]) / h;

        // Perturb V1
        let eval_p1 = res.eval(&[v0[0], v0[1] + h], &params);
        let dg0_dv1 = (eval_p1.g[0] - eval0.g[0]) / h;
        let dg1_dv1 = (eval_p1.g[1] - eval0.g[1]) / h;

        let g = 1.0 / 470.0;
        assert!((dg0_dv0 - g).abs() < 1e-6);
        assert!((dg0_dv1 + g).abs() < 1e-6);
        assert!((dg1_dv0 + g).abs() < 1e-6);
        assert!((dg1_dv1 - g).abs() < 1e-6);
    }

    #[test]
    fn resistor_various_r_values() {
        let res = Resistor;
        for &r in &[1.0, 10.0, 100.0, 1e3, 1e6, 1e9] {
            let params = make_params(r);
            let eval = res.eval(&[1.0, 0.0], &params);
            let expected = 1.0 / r;
            assert!(
                (eval.g[0] - expected).abs() < 1e-15 * expected.max(1.0),
                "Failed for R={r}: got {} expected {expected}",
                eval.g[0]
            );
        }
    }
}
