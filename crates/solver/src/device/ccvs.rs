use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

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
        let v0 = voltages[0];
        let v1 = voltages[1];
        let i_br = branch_current;

        // ── POLY(n) polynomial source ──────────────────────────────────────
        if let Some(poly_deg) = params.get("poly_degree") {
            let degree = poly_deg as usize;
            let ncoeffs = params.get_or("poly_ncoeffs", 0.0) as usize;

            if degree == 1 {
                // Single-variable polynomial: f = c0 + c1*I + c2*I² + ...
                let i_ctrl = params.get_or("ctrl_current", 0.0);
                let mut f = 0.0;
                let mut df = 0.0; // df/dI_ctrl
                let mut i_pow = 1.0; // I^k
                for k in 0..ncoeffs {
                    let ck = params.get_or(&format!("poly_c{k}"), 0.0);
                    f += ck * i_pow;
                    if k > 0 {
                        df += ck * (k as f64) * if k == 1 { 1.0 } else { i_ctrl.powi(k as i32 - 1) };
                    }
                    i_pow *= i_ctrl;
                }
                // Branch equation: V0 - V1 - f(I_ctrl) = 0
                let branch_eq = v0 - v1 - f;

                // The Jacobian w.r.t. I_ctrl is -df, but I_ctrl lives in an
                // external branch variable (the controlling V-source's branch
                // row). The stamper handles that coupling via the ctrl_branch
                // column; we emit it as an RHS-only residual here.
                // Local Jacobian entries: dBranch/dV0 = 1, dBranch/dV1 = -1.
                DeviceEval {
                    g: smallvec![i_br, -i_br, branch_eq],
                    q: smallvec![0.0, 0.0, 0.0],
                    G: smallvec![
                        (0, 2, 1.0),  // dg[0] / dI_br
                        (1, 2, -1.0), // dg[1] / dI_br
                        (2, 0, 1.0),  // dbranch / dV0
                        (2, 1, -1.0), // dbranch / dV1
                    ],
                    C: SmallVec::new(),
                    rhs: SmallVec::new(),
                }
            } else {
                // Multi-input POLY(n): f = c0 + c1*I1 + c2*I2 + ...
                //                          + c_{n+1}*I1² + c_{n+2}*I1*I2 + ...
                // Control variables: I_ctrl_0, I_ctrl_1, ..., I_ctrl_{n-1}
                let mut ctrl: SmallVec<[f64; 4]> = SmallVec::new();
                for k in 0..degree {
                    let key = format!("ctrl_current_{k}");
                    ctrl.push(params.get_or(&key, 0.0));
                }

                // Build monomials in graded lexicographic order (same as vcvs.rs)
                let mut f = 0.0;
                let mut _dfdx: SmallVec<[f64; 4]> = smallvec![0.0; degree];
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
                    _dfdx[k] += ci;
                    ci_idx += 1;
                }
                // Degree 2: graded lex order
                if ci_idx < ncoeffs {
                    for k in 0..degree {
                        for j in k..degree {
                            if ci_idx >= ncoeffs { break; }
                            let ci = params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                            f += ci * ctrl[k] * ctrl[j];
                            _dfdx[k] += ci * ctrl[j];
                            if j != k {
                                _dfdx[j] += ci * ctrl[k];
                            } else {
                                _dfdx[k] += ci * ctrl[k]; // d/dx(c*x²) = 2cx
                            }
                            ci_idx += 1;
                        }
                    }
                }

                // Branch equation: V0 - V1 - f(I1, I2, ...) = 0
                // Control currents are external branch variables; derivatives
                // w.r.t. them are handled by the stamper. Local Jacobian is
                // just dBranch/dV0 = 1, dBranch/dV1 = -1.
                let branch_eq = v0 - v1 - f;

                DeviceEval {
                    g: smallvec![i_br, -i_br, branch_eq],
                    q: smallvec![0.0, 0.0, 0.0],
                    G: smallvec![
                        (0, 2, 1.0),
                        (1, 2, -1.0),
                        (2, 0, 1.0),
                        (2, 1, -1.0),
                    ],
                    C: SmallVec::new(),
                    rhs: SmallVec::new(),
                }
            }
        }
        // ── Standard linear CCVS ───────────────────────────────────────────
        else {
            let rm = params.get_or("transresistance", 1.0);
            let i_ctrl = params.get_or("ctrl_current", 0.0);

            // Branch equation residual: V0 - V1 - rm * I_ctrl
            let branch_eq = v0 - v1 - rm * i_ctrl;

            DeviceEval {
                g: smallvec![i_br, -i_br, branch_eq],
                q: smallvec![0.0, 0.0, 0.0],
                G: smallvec![
                    (0, 2, 1.0),  // dg[0] / dI_br
                    (1, 2, -1.0), // dg[1] / dI_br
                    (2, 0, 1.0),  // dbranch / dV0
                    (2, 1, -1.0), // dbranch / dV1
                ],
                C: SmallVec::new(),
                rhs: SmallVec::new(),
            }
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
        let params = make_params(2.0, 1.0); // expected V = 2.0
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

    // ── Additional CCVS tests ──────────────────────────────────────────────────

    /// KCL at output pins: g[0] + g[1] == 0.
    #[test]
    fn ccvs_kcl_antisymmetry() {
        let h = Ccvs;
        for &i_br in &[0.0_f64, 1e-3, -5e-4, 1.0] {
            let params = make_params(2.0, 1.5);
            let eval = h.eval_with_branch(&[3.0, 0.0], i_br, &params);
            assert!(
                (eval.g[0] + eval.g[1]).abs() < 1e-15,
                "KCL at I_br={i_br}: {}", eval.g[0] + eval.g[1]
            );
        }
    }

    /// Output branch current stamps into g[0] correctly.
    #[test]
    fn ccvs_branch_current_in_g() {
        let h = Ccvs;
        let i_br = 0.05_f64;
        let params = make_params(1.0, 0.0);
        let eval = h.eval_with_branch(&[0.0, 0.0], i_br, &params);
        assert!(
            (eval.g[0] - i_br).abs() < 1e-15,
            "g[0] should equal I_br: {} vs {i_br}", eval.g[0]
        );
        assert!(
            (eval.g[1] + i_br).abs() < 1e-15,
            "g[1] should equal -I_br: {} vs {}", eval.g[1], -i_br
        );
    }

    /// Different transresistance values scale Vout correctly.
    #[test]
    fn ccvs_transresistance_scaling() {
        let h = Ccvs;
        let i_ctrl = 2e-3_f64; // 2 mA control current
        // With rm=500: expected Vout = 500 * 0.002 = 1V
        let params = make_params(500.0, i_ctrl);
        let eval = h.eval_with_branch(&[1.0, 0.0], 0.0, &params);
        assert!(
            eval.g[2].abs() < 1e-15,
            "branch eq should be 0 at rm=500, I_ctrl=2mA, Vout=1V: {}", eval.g[2]
        );
    }

    /// Zero control current → Vout must be 0 at convergence.
    #[test]
    fn ccvs_zero_ctrl_current_zero_vout() {
        let h = Ccvs;
        let params = make_params(1000.0, 0.0);
        // With I_ctrl=0, expected Vout=0 → branch eq = V0-V1 = 0
        let eval = h.eval_with_branch(&[0.0, 0.0], 0.0, &params);
        assert!(eval.g[2].abs() < 1e-15, "zero I_ctrl: branch eq={}", eval.g[2]);
    }

    /// No charge storage.
    #[test]
    fn ccvs_no_charge_storage() {
        let h = Ccvs;
        let params = make_params(1.0, 1e-3);
        let eval = h.eval_with_branch(&[1.0, 0.0], 0.0, &params);
        for (i, &q) in eval.q.iter().enumerate() {
            assert!(q.abs() < 1e-30, "CCVS q[{i}]={q} must be 0");
        }
        assert!(eval.C.is_empty(), "CCVS C must be empty");
    }

    /// Default transresistance (1 Ω) and ctrl_current (0) produce zero Vout.
    #[test]
    fn ccvs_default_params_zero_vout() {
        let h = Ccvs;
        let p = ParamMap::new();
        let eval = h.eval_with_branch(&[0.0, 0.0], 0.0, &p);
        assert!(eval.g[2].abs() < 1e-15, "default params: branch eq={}", eval.g[2]);
    }

    // ── POLY evaluation tests ────────────────────────────────────────────────

    /// POLY(1) constant-only: f(I) = c0 → branch eq = V0 - V1 - c0.
    #[test]
    fn ccvs_poly1_constant() {
        let h = Ccvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 1.0);
        p.set("poly_c0", 5.0);
        p.set("ctrl_current", 1.0); // doesn't matter for constant
        // Satisfied when V0 - V1 = 5
        let eval = h.eval_with_branch(&[5.0, 0.0], 0.0, &p);
        assert!(eval.g[2].abs() < 1e-15, "POLY(1) const: branch eq={}", eval.g[2]);
    }

    /// POLY(1) linear: f(I) = c0 + c1*I → same as standard form with offset.
    #[test]
    fn ccvs_poly1_linear() {
        let h = Ccvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 2.0);
        p.set("poly_c0", 1.0);  // offset
        p.set("poly_c1", 3.0);  // gain
        p.set("ctrl_current", 2.0);
        // f(2) = 1 + 3*2 = 7 → satisfied when V0-V1 = 7
        let eval = h.eval_with_branch(&[7.0, 0.0], 0.0, &p);
        assert!(eval.g[2].abs() < 1e-15, "POLY(1) linear: branch eq={}", eval.g[2]);
    }

    /// POLY(1) quadratic: f(I) = c0 + c1*I + c2*I².
    #[test]
    fn ccvs_poly1_quadratic() {
        let h = Ccvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 3.0);
        p.set("poly_c0", 0.5);
        p.set("poly_c1", 2.0);
        p.set("poly_c2", 1.0);
        let i_ctrl = 3.0_f64;
        p.set("ctrl_current", i_ctrl);
        // f(3) = 0.5 + 2*3 + 1*9 = 0.5 + 6 + 9 = 15.5
        let expected = 0.5 + 2.0 * i_ctrl + 1.0 * i_ctrl * i_ctrl;
        let eval = h.eval_with_branch(&[expected, 0.0], 0.0, &p);
        assert!(
            eval.g[2].abs() < 1e-14,
            "POLY(1) quadratic: branch eq={}, expected 0", eval.g[2]
        );
    }

    /// POLY(1) preserves Jacobian structure (4 entries for 2-pin + branch).
    #[test]
    fn ccvs_poly1_jacobian_structure() {
        let h = Ccvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 1.0);
        p.set("poly_ncoeffs", 2.0);
        p.set("poly_c0", 0.0);
        p.set("poly_c1", 5.0);
        p.set("ctrl_current", 1e-3);
        let eval = h.eval_with_branch(&[0.0, 0.0], 0.0, &p);
        assert_eq!(eval.G.len(), 4, "POLY(1) CCVS must have 4 Jacobian entries");
        assert_eq!(eval.G[0], (0, 2, 1.0));
        assert_eq!(eval.G[1], (1, 2, -1.0));
        assert_eq!(eval.G[2], (2, 0, 1.0));
        assert_eq!(eval.G[3], (2, 1, -1.0));
    }

    /// POLY(2) multi-input: f(I1,I2) = c0 + c1*I1 + c2*I2.
    #[test]
    fn ccvs_poly2_linear() {
        let h = Ccvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 3.0);
        p.set("poly_c0", 1.0);
        p.set("poly_c1", 2.0);
        p.set("poly_c2", 3.0);
        p.set("ctrl_current_0", 0.5);
        p.set("ctrl_current_1", 1.0);
        // f = 1 + 2*0.5 + 3*1.0 = 1 + 1 + 3 = 5
        let eval = h.eval_with_branch(&[5.0, 0.0], 0.0, &p);
        assert!(
            eval.g[2].abs() < 1e-14,
            "POLY(2) linear: branch eq={}", eval.g[2]
        );
    }

    /// POLY(2) with degree-2 terms: f = c0 + c1*I1 + c2*I2 + c3*I1² + c4*I1*I2 + c5*I2².
    #[test]
    fn ccvs_poly2_quadratic() {
        let h = Ccvs;
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
        // f = 1 + 0 + 0 + 2*4 + 0 + 3*1 = 1 + 8 + 3 = 12
        let expected = 1.0 + 2.0 * i1 * i1 + 3.0 * i2 * i2;
        let eval = h.eval_with_branch(&[expected, 0.0], 0.0, &p);
        assert!(
            eval.g[2].abs() < 1e-14,
            "POLY(2) quadratic: branch eq={}, expected 0", eval.g[2]
        );
    }

    /// POLY(2) with only cross-term c4=1: f(I1,I2) = I1*I2.
    #[test]
    fn ccvs_poly2_cross_term_only() {
        let h = Ccvs;
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
        // f = I1*I2 = 12 → branch eq = V0 - V1 - 12 = 0 when V0=12, V1=0
        let eval = h.eval_with_branch(&[12.0, 0.0], 0.0, &p);
        assert!(
            eval.g[2].abs() < 1e-14,
            "POLY(2) cross-term: branch eq={}, expected 0", eval.g[2]
        );
    }

    /// POLY(2) full quadratic with all terms: f = c0 + c1*I1 + c2*I2 + c3*I1² + c4*I1*I2 + c5*I2².
    #[test]
    fn ccvs_poly2_full_quadratic() {
        let h = Ccvs;
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
        // = 1 + 4 + 9 + 16 + 30 + 54 = 114
        let eval = h.eval_with_branch(&[expected, 0.0], 0.0, &p);
        assert!(
            eval.g[2].abs() < 1e-12,
            "POLY(2) full quadratic: branch eq={}, expected 0", eval.g[2]
        );
    }
}
