use incspice_core::{DeviceKind, ParamMap};
use smallvec::{SmallVec, smallvec};

use crate::device::eval::{DeviceEval, DeviceModel};

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
        // ��─ POLY(n) polynomial source ──────────────────────────────────────
        if let Some(poly_deg) = params.get("poly_degree") {
            let degree = poly_deg as usize;
            let ncoeffs = params.get_or("poly_ncoeffs", 0.0) as usize;

            // Control voltages
            let mut ctrl: SmallVec<[f64; 4]> = SmallVec::new();
            for k in 0..degree {
                let vp = voltages.get(2 + 2 * k).copied().unwrap_or(0.0);
                let vm = voltages.get(2 + 2 * k + 1).copied().unwrap_or(0.0);
                ctrl.push(vp - vm);
            }

            let mut f = 0.0;
            let mut dfdx: SmallVec<[f64; 4]> = smallvec![0.0; degree];
            let mut ci_idx = 0usize;

            // Degree 0
            if ci_idx < ncoeffs {
                f += params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                ci_idx += 1;
            }
            // Degree 1
            for k in 0..degree {
                if ci_idx >= ncoeffs { break; }
                let ci = params.get_or(&format!("poly_c{ci_idx}"), 0.0);
                f += ci * ctrl[k];
                dfdx[k] += ci;
                ci_idx += 1;
            }
            // Degree 2
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
                            dfdx[k] += ci * ctrl[k];
                        }
                        ci_idx += 1;
                    }
                }
            }

            let n_terms = voltages.len();
            let mut g_vec: SmallVec<[f64; 8]> = SmallVec::new();
            g_vec.push(f);
            g_vec.push(-f);
            for _ in 2..n_terms { g_vec.push(0.0); }

            let mut q_vec: SmallVec<[f64; 8]> = SmallVec::new();
            for _ in 0..n_terms { q_vec.push(0.0); }

            let mut jac: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();
            for k in 0..degree {
                let pin_p = (2 + 2 * k) as u8;
                let pin_m = (2 + 2 * k + 1) as u8;
                jac.push((0, pin_p, dfdx[k]));
                jac.push((0, pin_m, -dfdx[k]));
                jac.push((1, pin_p, -dfdx[k]));
                jac.push((1, pin_m, dfdx[k]));
            }

            DeviceEval {
                g: g_vec,
                q: q_vec,
                G: jac,
                C: SmallVec::new(),
                rhs: SmallVec::new(),
            }
        } else {
            let gm = params.get_or("gm", 1e-3);
            let vc = voltages[2] - voltages[3];
            let iout = gm * vc;

            DeviceEval {
                g: smallvec![iout, -iout, 0.0, 0.0],
                q: smallvec![0.0, 0.0, 0.0, 0.0],
                G: smallvec![(0, 2, gm), (0, 3, -gm), (1, 2, -gm), (1, 3, gm),],
                C: SmallVec::new(),
                rhs: SmallVec::new(),
            }
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

    // ── Additional VCCS tests ──────────────────────────────────────────────────

    /// Output current is proportional to Gm and control voltage.
    #[test]
    fn vccs_output_current_analytic() {
        let g = Vccs;
        let gm = 0.005_f64;
        let mut p = ParamMap::new();
        p.set("gm", gm);
        // Control: V2=3, V3=1 → Vc=2V; Iout = gm*Vc = 0.005*2 = 0.01A
        let eval = g.eval(&[0.0, 0.0, 3.0, 1.0], &p);
        let expected = gm * (3.0 - 1.0);
        assert!(
            (eval.g[0] - expected).abs() < 1e-15,
            "Iout={} expected {expected}", eval.g[0]
        );
    }

    /// KCL at output pins: g[0] + g[1] == 0.
    #[test]
    fn vccs_kcl_output_antisymmetry() {
        let g = Vccs;
        let mut p = ParamMap::new();
        p.set("gm", 0.01);
        let eval = g.eval(&[5.0, 0.0, 2.0, 0.0], &p);
        assert!(
            (eval.g[0] + eval.g[1]).abs() < 1e-15,
            "VCCS KCL: {}", eval.g[0] + eval.g[1]
        );
    }

    /// Zero control voltage → zero output current.
    #[test]
    fn vccs_zero_control_voltage() {
        let g = Vccs;
        let mut p = ParamMap::new();
        p.set("gm", 0.01);
        // V2=V3=2 → Vctrl=0
        let eval = g.eval(&[5.0, 0.0, 2.0, 2.0], &p);
        assert!(eval.g[0].abs() < 1e-15, "zero Vctrl → zero Iout: {}", eval.g[0]);
        assert!(eval.g[1].abs() < 1e-15, "zero Vctrl → zero -Iout: {}", eval.g[1]);
    }

    /// Negative Gm inverts output current direction.
    #[test]
    fn vccs_negative_gm() {
        let g = Vccs;
        let mut p = ParamMap::new();
        p.set("gm", -0.01);
        // Vctrl = 1V → Iout = -0.01 A
        let eval = g.eval(&[0.0, 0.0, 1.0, 0.0], &p);
        assert!(eval.g[0] < 0.0, "negative Gm: Iout should be negative, got {}", eval.g[0]);
    }

    /// Jacobian structure: G[0,2]=+Gm, G[0,3]=-Gm, G[1,2]=-Gm, G[1,3]=+Gm.
    #[test]
    fn vccs_jacobian_structure() {
        let g = Vccs;
        let gm = 0.025_f64;
        let mut p = ParamMap::new();
        p.set("gm", gm);
        let eval = g.eval(&[0.0, 0.0, 2.0, 1.0], &p);
        let find = |r: u8, c: u8| {
            eval.G.iter().find(|(ri, ci, _)| *ri == r && *ci == c)
                .map(|(_, _, v)| *v).unwrap_or(0.0)
        };
        assert!((find(0, 2) - gm).abs() < 1e-15, "G[0,2]={} expected {gm}", find(0, 2));
        assert!((find(0, 3) + gm).abs() < 1e-15, "G[0,3]={} expected {}", find(0, 3), -gm);
        assert!((find(1, 2) + gm).abs() < 1e-15, "G[1,2]={} expected {}", find(1, 2), -gm);
        assert!((find(1, 3) - gm).abs() < 1e-15, "G[1,3]={} expected {gm}", find(1, 3));
    }

    /// Output is independent of output terminal voltages (ideal transconductance).
    #[test]
    fn vccs_output_voltage_independent() {
        let g = Vccs;
        let mut p = ParamMap::new();
        p.set("gm", 0.01);
        // Same Vctrl=2, different output voltage
        let eval1 = g.eval(&[0.0, 0.0, 2.0, 0.0], &p);
        let eval2 = g.eval(&[100.0, 50.0, 2.0, 0.0], &p);
        assert!(
            (eval1.g[0] - eval2.g[0]).abs() < 1e-15,
            "VCCS output current must be voltage-independent"
        );
    }

    /// Default Gm (1e-3): with Vctrl=1V, Iout=1e-3 A.
    #[test]
    fn vccs_default_gm() {
        let g = Vccs;
        let p = ParamMap::new(); // no gm → default 1e-3
        let eval = g.eval(&[0.0, 0.0, 1.0, 0.0], &p);
        assert!(
            (eval.g[0] - 1e-3).abs() < 1e-15,
            "default Gm=1e-3: Iout={} expected 1e-3", eval.g[0]
        );
    }

    /// No charge storage (q is always zero).
    #[test]
    fn vccs_no_charge_storage() {
        let g = Vccs;
        let mut p = ParamMap::new();
        p.set("gm", 0.01);
        let eval = g.eval(&[5.0, 0.0, 3.0, 0.0], &p);
        for (i, &q) in eval.q.iter().enumerate() {
            assert!(q.abs() < 1e-30, "VCCS q[{i}]={q} must be 0");
        }
        assert!(eval.C.is_empty(), "VCCS C must be empty");
    }

    // ── POLY(2) cross-term tests ────────────────────────────────────────────

    /// POLY(2) with only c4=1 (cross-term): f(x1,x2) = x1*x2.
    #[test]
    fn vccs_poly2_cross_term_only() {
        let g = Vccs;
        let mut p = ParamMap::new();
        p.set("poly_degree", 2.0);
        p.set("poly_ncoeffs", 5.0);
        p.set("poly_c0", 0.0);
        p.set("poly_c1", 0.0);
        p.set("poly_c2", 0.0);
        p.set("poly_c3", 0.0);
        p.set("poly_c4", 1.0); // x1*x2
        // x1 = V(2)-V(3) = 3, x2 = V(4)-V(5) = 4 → f = 12
        let eval = g.eval(&[0.0, 0.0, 3.0, 0.0, 4.0, 0.0], &p);
        assert!(
            (eval.g[0] - 12.0).abs() < 1e-14,
            "POLY(2) cross-term: g[0] should be 12, got {}", eval.g[0]
        );
        assert!(
            (eval.g[1] + 12.0).abs() < 1e-14,
            "POLY(2) cross-term: g[1] should be -12, got {}", eval.g[1]
        );
    }

    /// POLY(2) full quadratic: f = c0 + c1*x1 + c2*x2 + c3*x1² + c4*x1*x2 + c5*x2².
    #[test]
    fn vccs_poly2_full_quadratic() {
        let g = Vccs;
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
        let eval = g.eval(&[0.0, 0.0, x1, 0.0, x2, 0.0], &p);
        assert!(
            (eval.g[0] - expected).abs() < 1e-12,
            "POLY(2) full quadratic: g[0]={} expected {expected}", eval.g[0]
        );
    }

    /// POLY(2) cross-term Jacobian: df/dx1 includes c4*x2, df/dx2 includes c4*x1.
    #[test]
    fn vccs_poly2_cross_term_jacobian() {
        let g = Vccs;
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
        let eval = g.eval(&[0.0, 0.0, x1, 0.0, x2, 0.0], &p);
        // df/dx1 = x2 = 4, df/dx2 = x1 = 3
        // G stamps: (0, pin2, +df/dx1), (0, pin3, -df/dx1), etc.
        let find = |r: u8, c: u8| {
            eval.G.iter().find(|(ri, ci, _)| *ri == r && *ci == c).map(|(_, _, v)| *v)
        };
        assert!(
            (find(0, 2).unwrap_or(0.0) - x2).abs() < 1e-14,
            "G[0,2] should be {x2} (df/dx1), got {:?}", find(0, 2)
        );
        assert!(
            (find(0, 4).unwrap_or(0.0) - x1).abs() < 1e-14,
            "G[0,4] should be {x1} (df/dx2), got {:?}", find(0, 4)
        );
    }
}
