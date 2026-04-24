use incspice_core::{DeviceKind, ParamMap};
use smallvec::smallvec;

use crate::device::eval::{DeviceEval, DeviceModel};

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
        let r0 = params.get_or("resistance", 1e3);
        // SPICE shorthand: `TC=0.01` stores as key "tc" (no number suffix).
        // Check for "tc1" first; fall back to bare "tc" which maps to TC1.
        let tc1 = if params.contains("tc1") {
            params.get_or("tc1", 0.0)
        } else {
            params.get_or("tc", 0.0)
        };
        let tc2 = params.get_or("tc2", 0.0);
        let temp = params.get_or("temp", 300.15);
        let tnom = params.get_or("tnom", 300.15);
        let dt = temp - tnom;
        // Clamp minimum resistance to avoid near-singular MNA matrices.
        // 1e-6 ohm (1 micro-ohm) gives G_max = 1e6, which keeps the matrix
        // condition number manageable alongside typical circuit conductances
        // (1e-3 to 1e3 S).  This is small enough to be negligible in any
        // practical circuit while avoiding ill-conditioning.
        let r = if tc1 != 0.0 || tc2 != 0.0 {
            (r0 * (1.0 + tc1 * dt + tc2 * dt * dt)).max(1e-6)
        } else {
            r0.max(1e-6)
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

    /// Temperature coefficient TC1: R(T) = R0*(1 + TC1*(T-Tnom)).
    ///
    /// At T = Tnom + 100K with TC1 = 0.001, R should be R0 * 1.1 = 1100 Ω,
    /// so I = 1V / 1100Ω ≈ 909.09 µA.
    #[test]
    fn resistor_temperature_coefficient_tc1() {
        let res = Resistor;
        let r0 = 1000.0_f64;
        let tc1 = 0.001_f64;
        let tnom = 300.15_f64;
        let temp = tnom + 100.0; // +100 K above nominal

        let mut p = ParamMap::new();
        p.set("resistance", r0);
        p.set("tc1", tc1);
        p.set("temp", temp);
        p.set("tnom", tnom);

        let eval = res.eval(&[1.0, 0.0], &p);

        let dt = temp - tnom;
        let r_expected = r0 * (1.0 + tc1 * dt);
        let i_expected = 1.0 / r_expected;

        assert!(
            (eval.g[0] - i_expected).abs() < 1e-10,
            "TC1: i={}, expected {i_expected} (R={r_expected})",
            eval.g[0]
        );
    }

    /// Temperature coefficient TC2: R(T) = R0*(1 + TC2*(T-Tnom)^2).
    ///
    /// Quadratic component only (TC1=0).
    #[test]
    fn resistor_temperature_coefficient_tc2() {
        let res = Resistor;
        let r0 = 500.0_f64;
        let tc2 = 1e-5_f64;
        let tnom = 300.15_f64;
        let temp = tnom + 50.0;

        let mut p = ParamMap::new();
        p.set("resistance", r0);
        p.set("tc2", tc2);
        p.set("temp", temp);
        p.set("tnom", tnom);

        let eval = res.eval(&[2.0, 0.0], &p);

        let dt = temp - tnom;
        let r_expected = r0 * (1.0 + tc2 * dt * dt);
        let i_expected = 2.0 / r_expected;

        assert!(
            (eval.g[0] - i_expected).abs() < 1e-10,
            "TC2: i={}, expected {i_expected} (R={r_expected})",
            eval.g[0]
        );
    }

    /// At Tnom the temperature-coefficient formula is identity: R(Tnom) = R0.
    #[test]
    fn resistor_at_tnom_no_temperature_change() {
        let res = Resistor;
        let r0 = 220.0_f64;
        let tnom = 300.15_f64;

        let mut p = ParamMap::new();
        p.set("resistance", r0);
        p.set("tc1", 0.005);
        p.set("tc2", 1e-5);
        p.set("temp", tnom);
        p.set("tnom", tnom);

        let eval = res.eval(&[1.0, 0.0], &p);
        let i_expected = 1.0 / r0;

        assert!(
            (eval.g[0] - i_expected).abs() < 1e-12,
            "at Tnom, R should equal R0={r0}; got i={}",
            eval.g[0]
        );
    }

    /// The `tc` bare key (TC1 shorthand) is honoured: same result as `tc1`.
    #[test]
    fn resistor_bare_tc_key_alias_for_tc1() {
        let res = Resistor;
        let r0 = 1000.0_f64;
        let tc_val = 0.002_f64;
        let tnom = 300.15_f64;
        let temp = tnom + 50.0;

        let mut p_tc1 = ParamMap::new();
        p_tc1.set("resistance", r0);
        p_tc1.set("tc1", tc_val);
        p_tc1.set("temp", temp);
        p_tc1.set("tnom", tnom);

        let mut p_tc = ParamMap::new();
        p_tc.set("resistance", r0);
        p_tc.set("tc", tc_val);
        p_tc.set("temp", temp);
        p_tc.set("tnom", tnom);

        let eval_tc1 = res.eval(&[1.0, 0.0], &p_tc1);
        let eval_tc = res.eval(&[1.0, 0.0], &p_tc);

        assert!(
            (eval_tc1.g[0] - eval_tc.g[0]).abs() < 1e-15,
            "tc and tc1 should produce identical results: tc1={} tc={}",
            eval_tc1.g[0],
            eval_tc.g[0]
        );
    }

    /// KCL: currents into both terminals must sum to zero (antisymmetry).
    #[test]
    fn resistor_kcl_antisymmetry() {
        let res = Resistor;
        let params = make_params(330.0);
        for &(v0, v1) in &[(5.0_f64, 0.0_f64), (-3.0, 1.0), (0.0, -7.0)] {
            let eval = res.eval(&[v0, v1], &params);
            assert!(
                (eval.g[0] + eval.g[1]).abs() < 1e-15,
                "KCL violation at V=({v0},{v1}): g[0]={} g[1]={}",
                eval.g[0],
                eval.g[1]
            );
        }
    }

    /// Conductance stamp is symmetric: G[0,1] == G[1,0] and G[0,0] == G[1,1].
    #[test]
    fn resistor_conductance_stamp_symmetric() {
        let res = Resistor;
        let params = make_params(680.0);
        let eval = res.eval(&[3.0, 1.0], &params);

        assert_eq!(eval.G.len(), 4, "expected 4 conductance entries");
        // (0,0) == (1,1)
        assert!(
            (eval.G[0].2 - eval.G[3].2).abs() < 1e-15,
            "G[0,0] != G[1,1]"
        );
        // (0,1) == (1,0)
        assert!(
            (eval.G[1].2 - eval.G[2].2).abs() < 1e-15,
            "G[0,1] != G[1,0]"
        );
        // Off-diagonal is negative of on-diagonal
        assert!(
            (eval.G[0].2 + eval.G[1].2).abs() < 1e-15,
            "G[0,0] + G[0,1] should be zero"
        );
    }
}
