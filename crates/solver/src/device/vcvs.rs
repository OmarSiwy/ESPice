use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

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
        let v0 = voltages[0];
        let v1 = voltages[1];
        let i_br = branch_current;

        // ── POLY(n) polynomial source ──────────────────────────────────────
        if let Some(poly_deg) = params.get("poly_degree") {
            let degree = poly_deg as usize;
            let ncoeffs = params.get_or("poly_ncoeffs", 0.0) as usize;

            if degree == 1 {
                // Single-variable polynomial: f = c0 + c1*x + c2*x² + ...
                let vc = voltages[2] - voltages[3];
                let mut f = 0.0;
                let mut df = 0.0; // df/dVc
                let mut vc_pow = 1.0; // x^i
                for i in 0..ncoeffs {
                    let ci = params.get_or(&format!("poly_c{i}"), 0.0);
                    f += ci * vc_pow;
                    if i > 0 {
                        df += ci * (i as f64) * if i == 1 { 1.0 } else { vc.powi(i as i32 - 1) };
                    }
                    vc_pow *= vc;
                }
                let branch_eq = v0 - v1 - f;
                let n = voltages.len() as u8;
                DeviceEval {
                    g: {
                        let mut g = smallvec![i_br, -i_br, 0.0, 0.0];
                        g.push(branch_eq);
                        g
                    },
                    q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0],
                    G: smallvec![
                        (0, n, 1.0),
                        (1, n, -1.0),
                        (n, 0, 1.0),
                        (n, 1, -1.0),
                        (n, 2, -df),
                        (n, 3, df),
                    ],
                    C: SmallVec::new(),
                    rhs: SmallVec::new(),
                }
            } else {
                // Multi-variable polynomial POLY(n):
                // For POLY(2): f = c0 + c1*x1 + c2*x2 + c3*x1² + c4*x1*x2 + c5*x2² + ...
                // Control voltages: x_k = V(2+2k) - V(2+2k+1)
                let mut ctrl: SmallVec<[f64; 4]> = SmallVec::new();
                for k in 0..degree {
                    let vp = voltages.get(2 + 2 * k).copied().unwrap_or(0.0);
                    let vm = voltages.get(2 + 2 * k + 1).copied().unwrap_or(0.0);
                    ctrl.push(vp - vm);
                }

                // Build monomials in graded lexicographic order
                let mut f = 0.0;
                let mut dfdx: SmallVec<[f64; 4]> = smallvec![0.0; degree];
                let mut ci_idx = 0usize;

                // Degree 0: constant
                if ci_idx < ncoeffs {
                    f += params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                    ci_idx += 1;
                }
                // Degree 1: c1*x1 + c2*x2 + ... + cn*xn
                for k in 0..degree {
                    if ci_idx >= ncoeffs { break; }
                    let ci = params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                    f += ci * ctrl[k];
                    dfdx[k] += ci;
                    ci_idx += 1;
                }
                // Degree 2: graded lex order
                if ci_idx < ncoeffs {
                    for k in 0..degree {
                        for j in k..degree {
                            if ci_idx >= ncoeffs { break; }
                            let ci = params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                            f += ci * ctrl[k] * ctrl[j];
                            dfdx[k] += ci * ctrl[j];
                            if j != k {
                                dfdx[j] += ci * ctrl[k];
                            } else {
                                dfdx[k] += ci * ctrl[k]; // d/dx(c*x²) = 2cx
                            }
                            ci_idx += 1;
                        }
                    }
                }

                let branch_eq = v0 - v1 - f;
                let n_terms = voltages.len() as u8;
                let branch_idx = n_terms;

                let mut g_vec: SmallVec<[f64; 8]> = SmallVec::new();
                g_vec.push(i_br);   // pin 0
                g_vec.push(-i_br);  // pin 1
                for _ in 0..n_terms - 2 { g_vec.push(0.0); }
                g_vec.push(branch_eq);

                let mut q_vec: SmallVec<[f64; 8]> = SmallVec::new();
                for _ in 0..=n_terms { q_vec.push(0.0); }

                let mut jac: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();
                jac.push((0, branch_idx, 1.0));
                jac.push((1, branch_idx, -1.0));
                jac.push((branch_idx, 0, 1.0));
                jac.push((branch_idx, 1, -1.0));
                for k in 0..degree {
                    let pin_p = (2 + 2 * k) as u8;
                    let pin_m = (2 + 2 * k + 1) as u8;
                    jac.push((branch_idx, pin_p, -dfdx[k]));
                    jac.push((branch_idx, pin_m, dfdx[k]));
                }

                DeviceEval {
                    g: g_vec,
                    q: q_vec,
                    G: jac,
                    C: SmallVec::new(),
                    rhs: SmallVec::new(),
                }
            }
        }
        // ── TABLE piecewise-linear source ──────────────────────────────────
        else if params.get("table_pairs").is_some() {
            let n_pairs = params.get_or("table_pairs", 0.0) as usize;
            let vc = voltages[2] - voltages[3];

            // Build table from params
            let mut xs: SmallVec<[f64; 8]> = SmallVec::new();
            let mut ys: SmallVec<[f64; 8]> = SmallVec::new();
            for i in 0..n_pairs {
                xs.push(params.get_or(&format!("table_x{i}"), 0.0));
                ys.push(params.get_or(&format!("table_y{i}"), 0.0));
            }

            // PWL interpolation
            let (f, slope) = if n_pairs == 0 {
                (0.0, 0.0)
            } else if vc <= xs[0] {
                // Clamp to first point (zero slope extrapolation)
                (ys[0], 0.0)
            } else if vc >= xs[n_pairs - 1] {
                // Clamp to last point
                (ys[n_pairs - 1], 0.0)
            } else {
                // Find segment
                let mut seg = 0;
                for i in 1..n_pairs {
                    if vc < xs[i] { seg = i - 1; break; }
                }
                let dx = xs[seg + 1] - xs[seg];
                let dy = ys[seg + 1] - ys[seg];
                let s = if dx.abs() > 1e-30 { dy / dx } else { 0.0 };
                (ys[seg] + s * (vc - xs[seg]), s)
            };

            let branch_eq = v0 - v1 - f;
            let n = voltages.len() as u8;
            DeviceEval {
                g: smallvec![i_br, -i_br, 0.0, 0.0, branch_eq],
                q: smallvec![0.0, 0.0, 0.0, 0.0, 0.0],
                G: smallvec![
                    (0, n, 1.0),
                    (1, n, -1.0),
                    (n, 0, 1.0),
                    (n, 1, -1.0),
                    (n, 2, -slope),
                    (n, 3, slope),
                ],
                C: SmallVec::new(),
                rhs: SmallVec::new(),
            }
        }
        // ── Standard linear gain ──────────��────────────────────────────────
        else {
            let gain = params.get_or("gain", 1.0);
            let v2 = voltages[2];
            let v3 = voltages[3];

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

    // ── Additional VCVS tests ──────────────────────────────────────────────────

    /// Branch equation satisfied: Vout = gain * Vctrl at convergence.
    #[test]
    fn vcvs_branch_equation_gain_2() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("gain", 2.0);
        // Satisfied: Vout = 6V = 2 * (3-0) = gain * Vctrl
        let eval = e.eval_with_branch(&[6.0, 0.0, 3.0, 0.0], 0.0, &p);
        assert!(
            eval.g[4].abs() < 1e-15,
            "branch eq should be 0: g[4]={}", eval.g[4]
        );
    }

    /// Branch equation violation: Vout != gain * Vctrl → nonzero residual.
    #[test]
    fn vcvs_branch_eq_violated() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("gain", 3.0);
        // Expected Vout = 3*(2-0) = 6, actual Vout = 1-0 = 1 → residual = -5
        let eval = e.eval_with_branch(&[1.0, 0.0, 2.0, 0.0], 0.0, &p);
        assert!(
            (eval.g[4] - (-5.0)).abs() < 1e-15,
            "branch eq residual should be -5, got {}", eval.g[4]
        );
    }

    /// KCL at output pins: g[0] + g[1] == 0.
    #[test]
    fn vcvs_kcl_output_pins() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("gain", 5.0);
        let eval = e.eval_with_branch(&[10.0, 0.0, 2.0, 0.0], 0.025, &p);
        assert!(
            (eval.g[0] + eval.g[1]).abs() < 1e-15,
            "KCL: g[0]+g[1]={}", eval.g[0] + eval.g[1]
        );
    }

    /// Control terminals produce no current: g[2] = g[3] = 0.
    #[test]
    fn vcvs_control_terminals_no_current() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("gain", 2.0);
        let eval = e.eval_with_branch(&[4.0, 0.0, 2.0, 0.0], 1e-3, &p);
        assert!(eval.g[2].abs() < 1e-15, "g[2] must be 0 (control+)");
        assert!(eval.g[3].abs() < 1e-15, "g[3] must be 0 (control-)");
    }

    /// Gain=1: unity buffer — Vout equals Vctrl exactly.
    #[test]
    fn vcvs_unity_gain() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("gain", 1.0);
        let vctrl = 3.7_f64;
        let eval = e.eval_with_branch(&[vctrl, 0.0, vctrl, 0.0], 0.0, &p);
        assert!(
            eval.g[4].abs() < 1e-15,
            "unity gain: branch eq should be 0, got {}", eval.g[4]
        );
    }

    /// Negative gain: inverts polarity.
    #[test]
    fn vcvs_negative_gain() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("gain", -1.0);
        // Vout = -1 * (2-0) = -2; pins: [Vout+, Vout-, Vctrl+, Vctrl-] = [-2, 0, 2, 0]
        let eval = e.eval_with_branch(&[-2.0, 0.0, 2.0, 0.0], 0.0, &p);
        assert!(
            eval.g[4].abs() < 1e-15,
            "negative gain: branch eq should be 0, got {}", eval.g[4]
        );
    }

    /// Jacobian entries match expected MNA stamp structure.
    #[test]
    fn vcvs_jacobian_gain_entries() {
        let e = Vcvs;
        let gain = 3.5_f64;
        let mut p = ParamMap::new();
        p.set("gain", gain);
        let eval = e.eval_with_branch(&[7.0, 0.0, 2.0, 0.0], 0.0, &p);
        // Branch eq: G[4,0]=1, G[4,1]=-1, G[4,2]=-gain, G[4,3]=+gain
        let find = |r: u8, c: u8| {
            eval.G.iter().find(|(ri, ci, _)| *ri == r && *ci == c)
                .map(|(_, _, v)| *v)
        };
        assert_eq!(find(4, 0), Some(1.0), "G[4,0] must be +1");
        assert_eq!(find(4, 1), Some(-1.0), "G[4,1] must be -1");
        assert!((find(4, 2).unwrap_or(0.0) - (-gain)).abs() < 1e-15, "G[4,2] must be -gain");
        assert!((find(4, 3).unwrap_or(0.0) - gain).abs() < 1e-15, "G[4,3] must be +gain");
    }

    /// Num terminals is 4 (2 output + 2 control).
    #[test]
    fn vcvs_num_terminals() {
        assert_eq!(Vcvs.num_terminals(), 4);
    }

    /// Kind is Vcvs.
    #[test]
    fn vcvs_kind() {
        assert_eq!(Vcvs.kind(), DeviceKind::Vcvs);
    }

    // ── POLY(2) cross-term tests ────────────────────────────────────────────

    /// POLY(2) with only c4=1 (cross-term): f(x1,x2) = x1*x2.
    #[test]
    fn vcvs_poly2_cross_term_only() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 5.0);
        p.set("poly_c0", 0.0);
        p.set("poly_c1", 0.0);
        p.set("poly_c2", 0.0);
        p.set("poly_c3", 0.0);
        p.set("poly_c4", 1.0); // x1*x2
        // x1 = V(2)-V(3) = 3, x2 = V(4)-V(5) = 4 → f = 3*4 = 12
        let eval = e.eval_with_branch(&[12.0, 0.0, 3.0, 0.0, 4.0, 0.0], 0.0, &p);
        assert!(
            eval.g.last().copied().unwrap_or(f64::NAN).abs() < 1e-14,
            "POLY(2) cross-term: branch eq should be 0, got {:?}",
            eval.g.last()
        );
    }

    /// POLY(2) full quadratic: f = c0 + c1*x1 + c2*x2 + c3*x1² + c4*x1*x2 + c5*x2².
    #[test]
    fn vcvs_poly2_full_quadratic() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 6.0);
        p.set("poly_c0", 1.0);
        p.set("poly_c1", 2.0);
        p.set("poly_c2", 3.0);
        p.set("poly_c3", 4.0);  // x1²
        p.set("poly_c4", 5.0);  // x1*x2
        p.set("poly_c5", 6.0);  // x2²
        let x1 = 2.0_f64;
        let x2 = 3.0_f64;
        let expected = 1.0 + 2.0*x1 + 3.0*x2 + 4.0*x1*x1 + 5.0*x1*x2 + 6.0*x2*x2;
        // expected = 1 + 4 + 9 + 16 + 30 + 54 = 114
        let eval = e.eval_with_branch(&[expected, 0.0, x1, 0.0, x2, 0.0], 0.0, &p);
        assert!(
            eval.g.last().copied().unwrap_or(f64::NAN).abs() < 1e-12,
            "POLY(2) full quadratic: branch eq should be 0, got {:?}",
            eval.g.last()
        );
    }

    /// POLY(2) cross-term Jacobian: df/dx1 includes c4*x2, df/dx2 includes c4*x1.
    #[test]
    fn vcvs_poly2_cross_term_jacobian() {
        let e = Vcvs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 5.0);
        p.set("poly_c0", 0.0);
        p.set("poly_c1", 0.0);
        p.set("poly_c2", 0.0);
        p.set("poly_c3", 0.0);
        p.set("poly_c4", 1.0); // x1*x2 only
        let x1 = 3.0_f64;
        let x2 = 4.0_f64;
        let f = x1 * x2; // = 12
        let eval = e.eval_with_branch(&[f, 0.0, x1, 0.0, x2, 0.0], 0.0, &p);
        // df/dx1 = x2 = 4, df/dx2 = x1 = 3
        // Jacobian: branch_idx = 6 (voltages.len())
        // (branch_idx, pin2, -df/dx1) = (6, 2, -4.0)
        // (branch_idx, pin3, +df/dx1) = (6, 3, +4.0)
        // (branch_idx, pin4, -df/dx2) = (6, 4, -3.0)
        // (branch_idx, pin5, +df/dx2) = (6, 5, +3.0)
        let find = |r: u8, c: u8| {
            eval.G.iter().find(|(ri, ci, _)| *ri == r && *ci == c).map(|(_, _, v)| *v)
        };
        let n = 6u8;
        assert!(
            (find(n, 2).unwrap_or(0.0) - (-x2)).abs() < 1e-14,
            "G[n,2] should be -{x2}, got {:?}", find(n, 2)
        );
        assert!(
            (find(n, 3).unwrap_or(0.0) - x2).abs() < 1e-14,
            "G[n,3] should be {x2}, got {:?}", find(n, 3)
        );
        assert!(
            (find(n, 4).unwrap_or(0.0) - (-x1)).abs() < 1e-14,
            "G[n,4] should be -{x1}, got {:?}", find(n, 4)
        );
        assert!(
            (find(n, 5).unwrap_or(0.0) - x1).abs() < 1e-14,
            "G[n,5] should be {x1}, got {:?}", find(n, 5)
        );
    }
}
