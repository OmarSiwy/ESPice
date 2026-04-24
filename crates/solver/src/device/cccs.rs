use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

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
        // ── POLY(n) polynomial source ──────────────────────────────────────
        if let Some(poly_deg) = params.get("poly_degree") {
            let degree = poly_deg as usize;
            let ncoeffs = params.get_or("poly_ncoeffs", 0.0) as usize;

            if degree == 1 {
                // Single-variable polynomial: f = c0 + c1*I + c2*I² + ...
                let i_ctrl = params.get_or("ctrl_current", 0.0);
                let mut f = 0.0;
                let mut i_pow = 1.0; // I^k
                for k in 0..ncoeffs {
                    let ck = params.get_or(&format!("poly_c{k}"), 0.0);
                    f += ck * i_pow;
                    i_pow *= i_ctrl;
                }
                // I_out = f(I_ctrl)
                DeviceEval {
                    g: smallvec![0.0, 0.0],
                    q: smallvec![0.0, 0.0],
                    G: SmallVec::new(),
                    C: SmallVec::new(),
                    rhs: smallvec![f, -f],
                }
            } else {
                // Multi-input POLY(n): f = c0 + c1*I1 + c2*I2 + ...
                //                          + c_{n+1}*I1² + c_{n+2}*I1*I2 + ...
                // Control variables: ctrl_current_0, ctrl_current_1, ...
                let mut ctrl: SmallVec<[f64; 4]> = SmallVec::new();
                for k in 0..degree {
                    let key = format!("ctrl_current_{k}");
                    ctrl.push(params.get_or(&key, 0.0));
                }

                // Build monomials in graded lexicographic order (same as vccs.rs)
                let mut f = 0.0;
                let mut ci_idx = 0usize;

                // Degree 0: constant
                if ci_idx < ncoeffs {
                    f += params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                    ci_idx += 1;
                }
                // Degree 1: c1*I1 + c2*I2 + ... + cn*In
                for k in 0..degree {
                    if ci_idx >= ncoeffs { break; }
                    let ci = params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                    f += ci * ctrl[k];
                    ci_idx += 1;
                }
                // Degree 2: graded lex order
                if ci_idx < ncoeffs {
                    for k in 0..degree {
                        for j in k..degree {
                            if ci_idx >= ncoeffs { break; }
                            let ci = params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                            f += ci * ctrl[k] * ctrl[j];
                            ci_idx += 1;
                        }
                    }
                }

                // I_out = f(I1, I2, ...)
                DeviceEval {
                    g: smallvec![0.0, 0.0],
                    q: smallvec![0.0, 0.0],
                    G: SmallVec::new(),
                    C: SmallVec::new(),
                    rhs: smallvec![f, -f],
                }
            }
        }
        // ── Standard linear CCCS ───────────────────────────────────────────
        else {
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

    // ── Additional CCCS tests ──────────────────────────────────────────────────

    /// RHS antisymmetry: rhs[0] + rhs[1] == 0.
    #[test]
    fn cccs_rhs_antisymmetric() {
        let f = Cccs;
        let params = make_params(50.0, 1e-6);
        let eval = f.eval(&[0.0, 0.0], &params);
        assert!(
            (eval.rhs[0] + eval.rhs[1]).abs() < 1e-30,
            "rhs antisymmetry: {} + {}", eval.rhs[0], eval.rhs[1]
        );
    }

    /// Gain scaling: doubling gain doubles output current.
    #[test]
    fn cccs_gain_scaling() {
        let f = Cccs;
        let i_ctrl = 1e-3_f64;
        let params1 = make_params(10.0, i_ctrl);
        let params2 = make_params(20.0, i_ctrl);
        let eval1 = f.eval(&[0.0, 0.0], &params1);
        let eval2 = f.eval(&[0.0, 0.0], &params2);
        let ratio = eval2.rhs[0] / eval1.rhs[0];
        assert!(
            (ratio - 2.0).abs() < 1e-10,
            "doubling gain should double output: ratio={ratio:.6}"
        );
    }

    /// Output is independent of terminal voltages.
    #[test]
    fn cccs_voltage_independent() {
        let f = Cccs;
        let params = make_params(100.0, 1e-6);
        let eval1 = f.eval(&[0.0, 0.0], &params);
        let eval2 = f.eval(&[100.0, -50.0], &params);
        assert!(
            (eval1.rhs[0] - eval2.rhs[0]).abs() < 1e-30,
            "CCCS must be voltage-independent"
        );
    }

    /// No conductance or capacitance stamps.
    #[test]
    fn cccs_no_g_or_c_entries() {
        let f = Cccs;
        let params = make_params(50.0, 1e-6);
        let eval = f.eval(&[0.0, 0.0], &params);
        assert!(eval.G.is_empty(), "CCCS G must be empty");
        assert!(eval.C.is_empty(), "CCCS C must be empty");
    }

    /// g vector is always zero.
    #[test]
    fn cccs_g_vector_zero() {
        let f = Cccs;
        let params = make_params(100.0, 1e-3);
        let eval = f.eval(&[5.0, 0.0], &params);
        assert!(eval.g[0].abs() < 1e-30, "CCCS g[0] must be 0");
        assert!(eval.g[1].abs() < 1e-30, "CCCS g[1] must be 0");
    }

    /// Analytic: I_out = gain * I_ctrl.
    #[test]
    fn cccs_analytic_output() {
        let f = Cccs;
        let gain = 75.0_f64;
        let i_ctrl = 4e-6_f64;
        let params = make_params(gain, i_ctrl);
        let eval = f.eval(&[0.0, 0.0], &params);
        let expected = gain * i_ctrl;
        assert!(
            (eval.rhs[0] - expected).abs() < 1e-15,
            "I_out={} expected {expected}", eval.rhs[0]
        );
    }

    /// Default gain=1 and ctrl_current=0: output is 0.
    #[test]
    fn cccs_default_params_zero_output() {
        let f = Cccs;
        let p = ParamMap::new();
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(eval.rhs[0].abs() < 1e-30, "default: Iout must be 0");
    }

    // ── POLY evaluation tests ────────────────────────────────────────────────

    /// POLY(1) constant-only: f(I) = c0 → I_out = c0.
    #[test]
    fn cccs_poly1_constant() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 1.0);
        p.set("poly_c0", 3.0);
        p.set("ctrl_current", 99.0); // irrelevant for constant
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(
            (eval.rhs[0] - 3.0).abs() < 1e-15,
            "POLY(1) const: Iout={} expected 3.0", eval.rhs[0]
        );
        assert!(
            (eval.rhs[0] + eval.rhs[1]).abs() < 1e-15,
            "RHS antisymmetry"
        );
    }

    /// POLY(1) linear: f(I) = c0 + c1*I.
    #[test]
    fn cccs_poly1_linear() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 2.0);
        p.set("poly_c0", 1.0);
        p.set("poly_c1", 5.0);
        p.set("ctrl_current", 2.0);
        let eval = f.eval(&[0.0, 0.0], &p);
        // f(2) = 1 + 5*2 = 11
        assert!(
            (eval.rhs[0] - 11.0).abs() < 1e-15,
            "POLY(1) linear: Iout={} expected 11", eval.rhs[0]
        );
    }

    /// POLY(1) quadratic: f(I) = c0 + c1*I + c2*I².
    #[test]
    fn cccs_poly1_quadratic() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 3.0);
        p.set("poly_c0", 0.5);
        p.set("poly_c1", 2.0);
        p.set("poly_c2", 1.0);
        let i_ctrl = 3.0_f64;
        p.set("ctrl_current", i_ctrl);
        let expected = 0.5 + 2.0 * i_ctrl + 1.0 * i_ctrl * i_ctrl;
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(
            (eval.rhs[0] - expected).abs() < 1e-14,
            "POLY(1) quadratic: Iout={} expected {expected}", eval.rhs[0]
        );
    }

    /// POLY(1) preserves RHS-only structure (no G entries).
    #[test]
    fn cccs_poly1_no_jacobian() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 2.0);
        p.set("poly_c0", 0.0);
        p.set("poly_c1", 5.0);
        p.set("ctrl_current", 1e-3);
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(eval.G.is_empty(), "POLY(1) CCCS must have no G entries");
        assert!(eval.C.is_empty(), "POLY(1) CCCS must have no C entries");
    }

    /// POLY(2) multi-input: f(I1,I2) = c0 + c1*I1 + c2*I2.
    #[test]
    fn cccs_poly2_linear() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 3.0);
        p.set("poly_c0", 1.0);
        p.set("poly_c1", 2.0);
        p.set("poly_c2", 3.0);
        p.set("ctrl_current_0", 0.5);
        p.set("ctrl_current_1", 1.0);
        // f = 1 + 2*0.5 + 3*1.0 = 5
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(
            (eval.rhs[0] - 5.0).abs() < 1e-14,
            "POLY(2) linear: Iout={} expected 5", eval.rhs[0]
        );
    }

    /// POLY(2) with degree-2 terms: f = c0 + c1*I1 + c2*I2 + c3*I1² + c4*I1*I2 + c5*I2².
    #[test]
    fn cccs_poly2_quadratic() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 6.0);
        p.set("poly_c0", 1.0);
        p.set("poly_c1", 0.0);
        p.set("poly_c2", 0.0);
        p.set("poly_c3", 2.0);  // I1²
        p.set("poly_c4", 0.0);  // I1*I2
        p.set("poly_c5", 3.0);  // I2²
        let i1 = 2.0_f64;
        let i2 = 1.0_f64;
        p.set("ctrl_current_0", i1);
        p.set("ctrl_current_1", i2);
        // f = 1 + 0 + 0 + 2*4 + 0 + 3*1 = 12
        let expected = 1.0 + 2.0 * i1 * i1 + 3.0 * i2 * i2;
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(
            (eval.rhs[0] - expected).abs() < 1e-14,
            "POLY(2) quadratic: Iout={} expected {expected}", eval.rhs[0]
        );
    }

    /// POLY(2) with only cross-term c4=1: f(I1,I2) = I1*I2.
    #[test]
    fn cccs_poly2_cross_term_only() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 5.0);
        p.set("poly_c0", 0.0);
        p.set("poly_c1", 0.0);
        p.set("poly_c2", 0.0);
        p.set("poly_c3", 0.0);
        p.set("poly_c4", 1.0); // I1*I2
        let i1 = 3.0_f64;
        let i2 = 4.0_f64;
        p.set("ctrl_current_0", i1);
        p.set("ctrl_current_1", i2);
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(
            (eval.rhs[0] - 12.0).abs() < 1e-14,
            "POLY(2) cross-term: Iout={} expected 12", eval.rhs[0]
        );
    }

    /// POLY(2) full quadratic with all terms.
    #[test]
    fn cccs_poly2_full_quadratic() {
        let f = Cccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 6.0);
        p.set("poly_c0", 1.0);
        p.set("poly_c1", 2.0);
        p.set("poly_c2", 3.0);
        p.set("poly_c3", 4.0);  // I1²
        p.set("poly_c4", 5.0);  // I1*I2
        p.set("poly_c5", 6.0);  // I2²
        let i1 = 2.0_f64;
        let i2 = 3.0_f64;
        p.set("ctrl_current_0", i1);
        p.set("ctrl_current_1", i2);
        let expected = 1.0 + 2.0*i1 + 3.0*i2 + 4.0*i1*i1 + 5.0*i1*i2 + 6.0*i2*i2;
        let eval = f.eval(&[0.0, 0.0], &p);
        assert!(
            (eval.rhs[0] - expected).abs() < 1e-12,
            "POLY(2) full quadratic: Iout={} expected {expected}", eval.rhs[0]
        );
    }
}
