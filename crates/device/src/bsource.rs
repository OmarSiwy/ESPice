//! B-source (behavioral source) device models.
//!
//! SPICE `B` element:
//! - `B<name> n+ n- V={expr}` — behavioral voltage source
//! - `B<name> n+ n- I={expr}` — behavioral current source
//!
//! Expressions may reference `V(node)`, `V(n1,n2)`, numeric literals,
//! named parameters, and math functions (`sqrt`, `exp`, `sin`, etc.).
//!
//! ## MNA formulation
//!
//! ### Voltage form (`BsourceV`)
//!
//! Introduces a branch current `I_br`.  The MNA rows are:
//! - KCL at n+:  `... + I_br = 0`
//! - KCL at n-:  `... - I_br = 0`
//! - Branch eq:  `V(n+) - V(n-) - f(V(refs...)) = 0`
//!
//! Jacobian entries (pin 0 = n+, pin 1 = n-, pin 2 = branch):
//! - `(0, 2, +1)`  — KCL n+
//! - `(1, 2, -1)`  — KCL n-
//! - `(2, 0, +1)`  — branch eq: ∂/∂V(n+)
//! - `(2, 1, -1)`  — branch eq: ∂/∂V(n-)
//! - `(2, ref_i, -∂f/∂V(ref_i))`  for each referenced node
//!
//! ### Current form (`BsourceI`)
//!
//! No branch variable.  Injects `f(V(refs...))` as a current:
//! - KCL at n+:  `+f(...)`
//! - KCL at n-:  `-f(...)`
//!
//! Jacobian entries:
//! - `(n+, ref_i, +∂f/∂V(ref_i))`
//! - `(n-, ref_i, -∂f/∂V(ref_i))`
//!
//! ## Jacobian via symbolic differentiation
//!
//! `BehavioralExpr::differentiate` computes exact partial derivatives for
//! algebraic expressions (products, quotients, powers, trig, exp/log).
//! For non-differentiable sub-expressions (`min`, `max`, `if`, `sign`) the
//! derivative returns 0.0, which is a valid but sub-optimal approximation.
//! Users who need accurate Newton convergence with such expressions should
//! use smooth equivalents.

use bigospice_core::{BsourceExpr, DeviceKind};
use smallvec::{SmallVec, smallvec};

use crate::eval::{DeviceEval, DeviceModel};
#[allow(unused_imports)]
use crate::expr_ast::{EvalCtx, ExprAst};

// ─── Stateless model types (held in DeviceDispatch) ──────────────────────────

/// Stateless model placeholder for B-source voltage form.
///
/// The actual per-instance expression lives in `Circuit::bsource_exprs`.
/// The stamper evaluates it directly; this struct satisfies the trait bound
/// in `DeviceDispatch`.
#[derive(Debug, Clone, Copy)]
pub struct BsourceVModel;

/// Stateless model placeholder for B-source current form.
#[derive(Debug, Clone, Copy)]
pub struct BsourceIModel;

// ─── DeviceModel impls ───────────────────────────────────────────────────────

impl DeviceModel for BsourceVModel {
    fn eval(&self, _voltages: &[f64], _params: &bigospice_core::ParamMap) -> DeviceEval {
        // This should never be called directly; the stamper has a special path
        // for BsourceV that passes the expression.  Return an identity DeviceEval.
        DeviceEval::new()
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        true
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::BsourceV
    }
}

impl DeviceModel for BsourceIModel {
    fn eval(&self, _voltages: &[f64], _params: &bigospice_core::ParamMap) -> DeviceEval {
        DeviceEval::new()
    }

    fn num_terminals(&self) -> usize {
        2
    }

    fn needs_branch(&self) -> bool {
        false
    }

    fn kind(&self) -> DeviceKind {
        DeviceKind::BsourceI
    }
}

// ─── Expression-aware evaluation ─────────────────────────────────────────────

/// Evaluate a `BsourceV` device and produce the `DeviceEval`.
///
/// `voltages[0]` = V(n+), `voltages[1]` = V(n-)
/// `bse.node_refs` names the referenced nodes; `ref_voltages[i]` is their
/// current value.
///
/// Returns `Err` only if the expression contains an unresolvable reference.
pub fn eval_bsource_v(
    bse: &BsourceExpr,
    vp: f64,
    vn: f64,
    ref_voltages: &[(&str, f64)],
    branch_current: f64,
) -> Result<DeviceEval, bigospice_core::SimError> {
    // f = expression value
    let f = bse.expr.eval(ref_voltages, &[])?;

    // Branch equation residual: V(n+) - V(n-) - f(refs)
    let branch_eq = vp - vn - f;

    // g: KCL rows for n+, n-; then branch equation row.
    // Pin layout: 0=n+, 1=n-, 2=branch.
    let g: SmallVec<[f64; 8]> = smallvec![branch_current, -branch_current, branch_eq];
    let q: SmallVec<[f64; 8]> = smallvec![0.0, 0.0, 0.0];

    // Jacobian entries.
    let mut jac: SmallVec<[(u8, u8, f64); 8]> = smallvec![
        (0, 2,  1.0),   // KCL n+: dI/d(I_br) = +1
        (1, 2, -1.0),   // KCL n-: dI/d(I_br) = -1
        (2, 0,  1.0),   // branch eq: d/dV(n+) = +1
        (2, 1, -1.0),   // branch eq: d/dV(n-) = -1
    ];

    // For each referenced node, add: (2, ref_pin, -∂f/∂V(ref))
    // ref_pin is encoded as 3 + i (beyond the 2 terminals + branch).
    for (i, _ref_node) in bse.node_refs.iter().enumerate() {
        let partial = bse.partials[i].eval(ref_voltages, &[])?;
        // ref_voltages[i] corresponds to pin (3 + i) in the extended terminal list
        let pin = (3 + i) as u8;
        jac.push((2, pin, -partial));
    }

    // rhs: voltage sources use rhs[0] = target voltage (f in this case).
    // The stamper checks `has_branch` and uses eval.rhs for the RHS constraint.
    // For B-source voltage: RHS of branch equation = f (the expression value).
    let rhs: SmallVec<[f64; 4]> = smallvec![f];

    Ok(DeviceEval { g, q, G: jac, C: SmallVec::new(), rhs })
}

/// Evaluate a `BsourceI` device and produce the `DeviceEval`.
///
/// `ref_voltages[i]` = value of `bse.node_refs[i]`.
pub fn eval_bsource_i(
    bse: &BsourceExpr,
    ref_voltages: &[(&str, f64)],
) -> Result<DeviceEval, bigospice_core::SimError> {
    let f = bse.expr.eval(ref_voltages, &[])?;

    // MNA convention: current LEAVING a node contributes positively to g[pin].
    // B-source I=+f INJECTS current INTO n+ (raises n+ voltage).
    // Injecting into n+ means current ARRIVES at n+ → it LEAVES n+ as -f.
    // So g[0] = -f (current flowing out of n+ is -f), g[1] = +f.
    // This matches how VCCS (Vccs) stamps: controlled current source injects
    // into n+ with g[0]=-Gm*(Vc+ - Vc-).
    let g: SmallVec<[f64; 8]> = smallvec![-f, f];
    let q: SmallVec<[f64; 8]> = smallvec![0.0, 0.0];

    // Jacobian entries for each referenced node.
    // Pin 0 = n+, pin 1 = n-, ref pins start at 2.
    // dg[0]/dV(ref_i) = -partial, dg[1]/dV(ref_i) = +partial.
    let mut jac: SmallVec<[(u8, u8, f64); 8]> = SmallVec::new();
    for (i, _) in bse.node_refs.iter().enumerate() {
        let partial = bse.partials[i].eval(ref_voltages, &[])?;
        let pin = (2 + i) as u8;
        jac.push((0, pin, -partial));
        jac.push((1, pin,  partial));
    }

    Ok(DeviceEval { g, q, G: jac, C: SmallVec::new(), rhs: SmallVec::new() })
}

// ─── Helper: build ref_voltages slice from solution ───────────────────────────

/// Build the `ref_voltages` slice consumed by `eval_bsource_v/i`.
///
/// `node_refs` — ordered list of node names from `BsourceExpr::node_refs`.
/// `solution` — flat MNA solution vector (index = node_id - 1; ground = 0).
/// `circuit`  — used to resolve node names to NodeIds.
pub fn resolve_ref_voltages<'a>(
    node_refs: &'a [String],
    solution: &[f64],
    circuit: &bigospice_core::Circuit,
    buf: &'a mut Vec<(&'a str, f64)>,
) {
    buf.clear();
    for name in node_refs {
        let v = circuit
            .find_node(name)
            .map(|nid| {
                if nid.is_ground() {
                    0.0
                } else {
                    let idx = (nid.0 - 1) as usize;
                    if idx < solution.len() { solution[idx] } else { 0.0 }
                }
            })
            .unwrap_or(0.0);
        buf.push((name.as_str(), v));
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use bigospice_core::{BehavioralExpr, BehavioralBinOp, BsourceExpr};

    fn lit(v: f64) -> BehavioralExpr { BehavioralExpr::Lit(v) }
    fn nv(n: &str) -> BehavioralExpr { BehavioralExpr::NodeVoltage(n.into()) }
    fn mul(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BehavioralBinOp::Mul, Box::new(a), Box::new(b))
    }
    fn div(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BehavioralBinOp::Div, Box::new(a), Box::new(b))
    }

    /// Finite-difference check: ∂f/∂V(node) ≈ (f(V+h) - f(V-h)) / 2h
    fn fd_partial(bse: &BsourceExpr, refs: &[(&str, f64)], node: &str, h: f64) -> f64 {
        let make_refs = |delta: f64| -> Vec<(&str, f64)> {
            refs.iter()
                .map(|&(n, v)| (n, if n == node { v + delta } else { v }))
                .collect()
        };
        let fp = bse.expr.eval(&make_refs(h), &[]).unwrap();
        let fm = bse.expr.eval(&make_refs(-h), &[]).unwrap();
        (fp - fm) / (2.0 * h)
    }

    #[test]
    fn bsource_v_simple_gain() {
        // B1 1 0 V={2*V(2)} — output voltage = 2 * V(2)
        let expr = mul(lit(2.0), nv("2"));
        let bse = BsourceExpr::new(expr);

        let refs: &[(&str, f64)] = &[("2", 1.5)];
        let eval = eval_bsource_v(&bse, 3.0, 0.0, refs, 0.0).unwrap();

        // branch_eq = V(n+) - V(n-) - f = 3.0 - 0.0 - 3.0 = 0
        assert!((eval.g[2]).abs() < 1e-12, "branch_eq should be 0, got {}", eval.g[2]);

        // rhs[0] should be f = 3.0
        assert!((eval.rhs[0] - 3.0).abs() < 1e-12, "rhs[0]={}", eval.rhs[0]);
    }

    #[test]
    fn bsource_v_multiplier_jacobian() {
        // B1 1 0 V={V(a)*V(b)} — test ∂f/∂V(a) = V(b), ∂f/∂V(b) = V(a)
        let expr = mul(nv("a"), nv("b"));
        let bse = BsourceExpr::new(expr);

        assert_eq!(bse.node_refs.len(), 2);

        let refs: &[(&str, f64)] = &[("a", 3.0), ("b", 4.0)];
        let eval = eval_bsource_v(&bse, 12.0, 0.0, refs, 0.0).unwrap();

        // ∂f/∂V(a) = V(b) = 4.0 → Jacobian entry (2, pin_a, -4.0)
        // ∂f/∂V(b) = V(a) = 3.0 → Jacobian entry (2, pin_b, -3.0)
        let jac_a = eval.G.iter().find(|(r, c, _)| *r == 2 && *c == 3).map(|(_, _, v)| *v);
        let jac_b = eval.G.iter().find(|(r, c, _)| *r == 2 && *c == 4).map(|(_, _, v)| *v);
        assert!((jac_a.unwrap() + 4.0).abs() < 1e-12, "jac_a={:?}", jac_a);
        assert!((jac_b.unwrap() + 3.0).abs() < 1e-12, "jac_b={:?}", jac_b);

        // Cross-check with finite differences
        let fd_a = fd_partial(&bse, refs, "a", 1e-6);
        let fd_b = fd_partial(&bse, refs, "b", 1e-6);
        assert!((fd_a - 4.0).abs() < 1e-9, "FD ∂/∂a={fd_a}");
        assert!((fd_b - 3.0).abs() < 1e-9, "FD ∂/∂b={fd_b}");
    }

    #[test]
    fn bsource_i_ohms_law() {
        // B1 1 0 I={V(2)/1k} — current = V(2) / 1000
        let expr = div(nv("2"), lit(1000.0));
        let bse = BsourceExpr::new(expr);

        let refs: &[(&str, f64)] = &[("2", 5.0)];
        let eval = eval_bsource_i(&bse, refs).unwrap();

        // f = 5.0 / 1000.0 = 0.005
        // Convention: g[0]=-f (current injected into n+ leaves as -f), g[1]=+f
        assert!((eval.g[0] + 0.005).abs() < 1e-12, "g[0]={}", eval.g[0]);
        assert!((eval.g[1] - 0.005).abs() < 1e-12, "g[1]={}", eval.g[1]);

        // ∂g[0]/∂V(2) = -∂f/∂V(2) = -1/1000 = -0.001
        let jac = eval.G.iter().find(|(r, c, _)| *r == 0 && *c == 2).map(|(_, _, v)| *v);
        assert!((jac.unwrap() + 0.001).abs() < 1e-12, "jac={:?}", jac);
    }

    #[test]
    fn bsource_v_jacobian_finite_difference() {
        // B1 1 0 V={V(x)^2} — nonlinear test
        let expr = BehavioralExpr::BinOp(
            BehavioralBinOp::Pow,
            Box::new(nv("x")),
            Box::new(lit(2.0)),
        );
        let bse = BsourceExpr::new(expr);

        // At V(x) = 3.0, ∂/∂V(x) = 2 * V(x) = 6.0
        let refs: &[(&str, f64)] = &[("x", 3.0)];

        let fd = fd_partial(&bse, refs, "x", 1e-6);
        let sym = bse.partials[0].eval(refs, &[]).unwrap();

        assert!(
            (fd - sym).abs() < 1e-6,
            "FD={fd} vs sym={sym} for d(V(x)^2)/dV(x) at V(x)=3"
        );
        assert!((sym - 6.0).abs() < 1e-10, "expected 6.0, got {sym}");
    }

    #[test]
    fn bsource_v_needs_branch() {
        assert!(BsourceVModel.needs_branch());
        assert_eq!(BsourceVModel.kind(), DeviceKind::BsourceV);
    }

    #[test]
    fn bsource_i_no_branch() {
        assert!(!BsourceIModel.needs_branch());
        assert_eq!(BsourceIModel.kind(), DeviceKind::BsourceI);
    }
}
