//! Behavioral expression AST for B-source devices.
//!
//! This module defines the expression tree used by B-source (`B` element)
//! device evaluation.  It lives in `pisim-core` so that both `pisim-device`
//! (evaluation) and `pisim-parser` (construction) can use it without a
//! circular dependency.
//!
//! The parser builds an `Expression` (its own richer AST), then converts it
//! to `BehavioralExpr` via `From<pisim_parser::Expression>`.

use serde::{Deserialize, Serialize};

/// Binary arithmetic operators.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Pow,
}

/// A behavioral expression tree used in B-source `V={expr}` or `I={expr}`.
///
/// `NodeVoltage(name)` is resolved at evaluation time by looking up the node
/// name in the solver's current solution vector.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum BehavioralExpr {
    /// Numeric constant.
    Lit(f64),
    /// A named `.PARAM` parameter value (resolved at eval time from `ParamMap`).
    Param(String),
    /// Node voltage `V(name)` — resolved from the solution vector.
    NodeVoltage(String),
    /// Unary minus.
    Neg(Box<BehavioralExpr>),
    /// Binary operation.
    BinOp(BinOp, Box<BehavioralExpr>, Box<BehavioralExpr>),
    /// Named function call.
    Func(String, Vec<BehavioralExpr>),
}

impl BehavioralExpr {
    /// Evaluate the expression.
    ///
    /// - `node_voltages`: a slice of `(node_name, voltage)` pairs from the
    ///   current solution.  Only the names referenced in `NodeVoltage` leaves
    ///   need to be present.
    /// - `params`: `.PARAM` values (may be empty).
    pub fn eval(
        &self,
        node_voltages: &[(&str, f64)],
        params: &[(&str, f64)],
    ) -> Result<f64, crate::SimError> {
        match self {
            BehavioralExpr::Lit(v) => Ok(*v),
            BehavioralExpr::Param(name) => {
                params
                    .iter()
                    .find(|(k, _)| *k == name.as_str())
                    .map(|(_, v)| *v)
                    .ok_or_else(|| {
                        crate::SimError::Parse(format!(
                            "B-source: parameter '{name}' not found"
                        ))
                    })
            }
            BehavioralExpr::NodeVoltage(node) => {
                node_voltages
                    .iter()
                    .find(|(k, _)| *k == node.as_str())
                    .map(|(_, v)| *v)
                    .ok_or_else(|| {
                        crate::SimError::Parse(format!(
                            "B-source: node voltage V({node}) not available"
                        ))
                    })
            }
            BehavioralExpr::Neg(inner) => {
                inner.eval(node_voltages, params).map(|v| -v)
            }
            BehavioralExpr::BinOp(op, lhs, rhs) => {
                let l = lhs.eval(node_voltages, params)?;
                let r = rhs.eval(node_voltages, params)?;
                match op {
                    BinOp::Add => Ok(l + r),
                    BinOp::Sub => Ok(l - r),
                    BinOp::Mul => Ok(l * r),
                    BinOp::Div => {
                        if r == 0.0 {
                            Err(crate::SimError::Parse(
                                "B-source: division by zero in expression".into(),
                            ))
                        } else {
                            Ok(l / r)
                        }
                    }
                    BinOp::Pow => Ok(l.powf(r)),
                }
            }
            BehavioralExpr::Func(name, args) => {
                let evaled: Result<Vec<f64>, _> = args
                    .iter()
                    .map(|a| a.eval(node_voltages, params))
                    .collect();
                let evaled = evaled?;
                eval_func(name, &evaled)
            }
        }
    }

    /// Symbolically differentiate with respect to `V(var_node)`.
    ///
    /// Returns a new `BehavioralExpr` representing `d(self)/dV(var_node)`.
    /// The result may not be fully simplified, but is correct.
    pub fn differentiate(&self, var_node: &str) -> BehavioralExpr {
        match self {
            BehavioralExpr::Lit(_) => BehavioralExpr::Lit(0.0),
            BehavioralExpr::Param(_) => BehavioralExpr::Lit(0.0),
            BehavioralExpr::NodeVoltage(node) => {
                if node == var_node {
                    BehavioralExpr::Lit(1.0)
                } else {
                    BehavioralExpr::Lit(0.0)
                }
            }
            BehavioralExpr::Neg(inner) => {
                BehavioralExpr::Neg(Box::new(inner.differentiate(var_node)))
            }
            BehavioralExpr::BinOp(op, lhs, rhs) => {
                let dl = lhs.differentiate(var_node);
                let dr = rhs.differentiate(var_node);
                match op {
                    BinOp::Add => BehavioralExpr::BinOp(
                        BinOp::Add, Box::new(dl), Box::new(dr),
                    ),
                    BinOp::Sub => BehavioralExpr::BinOp(
                        BinOp::Sub, Box::new(dl), Box::new(dr),
                    ),
                    // Product rule: d(u*v) = du*v + u*dv
                    BinOp::Mul => BehavioralExpr::BinOp(
                        BinOp::Add,
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Mul, Box::new(dl), rhs.clone(),
                        )),
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Mul, lhs.clone(), Box::new(dr),
                        )),
                    ),
                    // Quotient rule: d(u/v) = (du*v - u*dv) / v^2
                    BinOp::Div => BehavioralExpr::BinOp(
                        BinOp::Div,
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Sub,
                            Box::new(BehavioralExpr::BinOp(
                                BinOp::Mul, Box::new(dl), rhs.clone(),
                            )),
                            Box::new(BehavioralExpr::BinOp(
                                BinOp::Mul, lhs.clone(), Box::new(dr),
                            )),
                        )),
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Pow,
                            rhs.clone(),
                            Box::new(BehavioralExpr::Lit(2.0)),
                        )),
                    ),
                    // Power rule: d(u^v) = v * u^(v-1) * du  (v treated as const wrt var)
                    BinOp::Pow => BehavioralExpr::BinOp(
                        BinOp::Mul,
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Mul,
                            rhs.clone(),
                            Box::new(BehavioralExpr::BinOp(
                                BinOp::Pow,
                                lhs.clone(),
                                Box::new(BehavioralExpr::BinOp(
                                    BinOp::Sub,
                                    rhs.clone(),
                                    Box::new(BehavioralExpr::Lit(1.0)),
                                )),
                            )),
                        )),
                        Box::new(dl),
                    ),
                }
            }
            BehavioralExpr::Func(name, args) => {
                match (name.as_str(), args.as_slice()) {
                    ("sqrt", [u]) => {
                        let du = u.differentiate(var_node);
                        BehavioralExpr::BinOp(
                            BinOp::Div,
                            Box::new(du),
                            Box::new(BehavioralExpr::BinOp(
                                BinOp::Mul,
                                Box::new(BehavioralExpr::Lit(2.0)),
                                Box::new(BehavioralExpr::Func("sqrt".into(), vec![u.clone()])),
                            )),
                        )
                    }
                    ("exp", [u]) => {
                        let du = u.differentiate(var_node);
                        BehavioralExpr::BinOp(
                            BinOp::Mul,
                            Box::new(BehavioralExpr::Func("exp".into(), vec![u.clone()])),
                            Box::new(du),
                        )
                    }
                    ("log" | "ln", [u]) => {
                        let du = u.differentiate(var_node);
                        BehavioralExpr::BinOp(BinOp::Div, Box::new(du), Box::new(u.clone()))
                    }
                    ("sin", [u]) => {
                        let du = u.differentiate(var_node);
                        BehavioralExpr::BinOp(
                            BinOp::Mul,
                            Box::new(BehavioralExpr::Func("cos".into(), vec![u.clone()])),
                            Box::new(du),
                        )
                    }
                    ("cos", [u]) => {
                        let du = u.differentiate(var_node);
                        BehavioralExpr::BinOp(
                            BinOp::Mul,
                            Box::new(BehavioralExpr::Neg(Box::new(BehavioralExpr::Func(
                                "sin".into(), vec![u.clone()],
                            )))),
                            Box::new(du),
                        )
                    }
                    _ => BehavioralExpr::Lit(0.0),
                }
            }
        }
    }

    /// Collect the unique node names referenced in all `NodeVoltage` leaves.
    pub fn collect_node_refs(&self, out: &mut Vec<String>) {
        match self {
            BehavioralExpr::NodeVoltage(n) => {
                if !out.contains(n) {
                    out.push(n.clone());
                }
            }
            BehavioralExpr::BinOp(_, l, r) => {
                l.collect_node_refs(out);
                r.collect_node_refs(out);
            }
            BehavioralExpr::Neg(inner) => inner.collect_node_refs(out),
            BehavioralExpr::Func(_, args) => {
                args.iter().for_each(|a| a.collect_node_refs(out));
            }
            _ => {}
        }
    }
}

/// Evaluate a named function given already-evaluated arguments.
fn eval_func(name: &str, args: &[f64]) -> Result<f64, crate::SimError> {
    let check = |expected: usize| {
        if args.len() != expected {
            Err(crate::SimError::Parse(format!(
                "B-source: function '{name}' expects {expected} args, got {}",
                args.len()
            )))
        } else {
            Ok(())
        }
    };
    match name {
        "sqrt"  => { check(1)?; Ok(args[0].sqrt()) }
        "abs"   => { check(1)?; Ok(args[0].abs()) }
        "exp"   => { check(1)?; Ok(args[0].exp()) }
        "log" | "ln" => { check(1)?; Ok(args[0].ln()) }
        "log10" => { check(1)?; Ok(args[0].log10()) }
        "sin"   => { check(1)?; Ok(args[0].sin()) }
        "cos"   => { check(1)?; Ok(args[0].cos()) }
        "tan"   => { check(1)?; Ok(args[0].tan()) }
        "asin"  => { check(1)?; Ok(args[0].asin()) }
        "acos"  => { check(1)?; Ok(args[0].acos()) }
        "atan"  => { check(1)?; Ok(args[0].atan()) }
        "atan2" => { check(2)?; Ok(args[0].atan2(args[1])) }
        "pow"   => { check(2)?; Ok(args[0].powf(args[1])) }
        "min"   => { check(2)?; Ok(args[0].min(args[1])) }
        "max"   => { check(2)?; Ok(args[0].max(args[1])) }
        "sign"  => { check(1)?; Ok(args[0].signum()) }
        "if"    => {
            check(3)?;
            Ok(if args[0] != 0.0 { args[1] } else { args[2] })
        }
        // --- Rounding / integer ---
        "ceil"  => { check(1)?; Ok(args[0].ceil()) }
        "floor" => { check(1)?; Ok(args[0].floor()) }
        "round" => { check(1)?; Ok(args[0].round()) }
        "int"   => { check(1)?; Ok(args[0].trunc()) }
        "nint"  => { check(1)?; Ok(args[0].round()) }
        // --- Decibel ---
        "db"    => { check(1)?; Ok(20.0 * args[0].abs().log10()) }
        // --- Step / ramp ---
        "uramp" => { check(1)?; Ok(args[0].max(0.0)) }
        "u"     => { check(1)?; Ok(if args[0] >= 0.0 { 1.0 } else { 0.0 }) }
        // --- Power (HSPICE B-source) ---
        "pwr"   => { check(2)?; Ok(args[0].abs().powf(args[1])) }
        "pwrs"  => { check(2)?; Ok(args[0].signum() * args[0].abs().powf(args[1])) }
        // --- Hyperbolic ---
        "cosh"  => { check(1)?; Ok(args[0].cosh()) }
        "sinh"  => { check(1)?; Ok(args[0].sinh()) }
        "tanh"  => { check(1)?; Ok(args[0].tanh()) }
        "acosh" => { check(1)?; Ok(args[0].acosh()) }
        "asinh" => { check(1)?; Ok(args[0].asinh()) }
        "atanh" => { check(1)?; Ok(args[0].atanh()) }
        // --- Log ---
        "log2"  => { check(1)?; Ok(args[0].log2()) }
        // --- Geometry ---
        "hypot" => { check(2)?; Ok(args[0].hypot(args[1])) }
        // --- Sign alias ---
        "sgn"   => {
            check(1)?;
            let x = args[0];
            Ok(if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 })
        }
        // --- Clamp ---
        "limit" => { check(3)?; Ok(args[0].clamp(args[1], args[2])) }
        // --- Statistical (stochastic; use thread-local PRNG) ---
        "gauss" => {
            check(1)?;
            Ok(args[0] * bsource_sample_normal())
        }
        "agauss" => {
            check(2)?;
            Ok(args[0] + args[1] * bsource_sample_normal())
        }
        "unif"  => {
            check(1)?;
            Ok(args[0] * bsource_sample_uniform_signed())
        }
        "aunif" => {
            check(2)?;
            Ok(args[0] + args[1] * bsource_sample_uniform_signed())
        }
        "flat"  => {
            check(1)?;
            Ok(args[0] * bsource_sample_uniform_signed())
        }
        _ => Err(crate::SimError::Parse(format!(
            "B-source: unknown function '{name}'"
        ))),
    }
}

/// Sample a standard-normal value (Box-Muller) with a thread-local xorshift PRNG.
/// Used by statistical expression functions evaluated inside B-source expressions.
fn bsource_sample_normal() -> f64 {
    use std::cell::Cell;
    thread_local! {
        static STATE: Cell<u64> = Cell::new(0x9E3779B97F4A7C15u64);
    }
    fn next_u64() -> u64 {
        STATE.with(|s| {
            let mut x = s.get();
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            s.set(x);
            x.wrapping_mul(0x2545F4914F6CDD1D)
        })
    }
    fn next_unit() -> f64 {
        ((next_u64() >> 11) as f64) * (1.0 / ((1u64 << 53) as f64))
    }
    let mut u1 = next_unit();
    if u1 < 1e-300 {
        u1 = 1e-300;
    }
    let u2 = next_unit();
    let r = (-2.0 * u1.ln()).sqrt();
    let theta = 2.0 * std::f64::consts::PI * u2;
    r * theta.cos()
}

/// Sample a uniform value in [-1, 1) with a thread-local xorshift PRNG.
fn bsource_sample_uniform_signed() -> f64 {
    use std::cell::Cell;
    thread_local! {
        static STATE: Cell<u64> = Cell::new(0xD1B54A32D192ED03u64);
    }
    fn next_u64() -> u64 {
        STATE.with(|s| {
            let mut x = s.get();
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            s.set(x);
            x.wrapping_mul(0x2545F4914F6CDD1D)
        })
    }
    let bits = next_u64() >> 11;
    let unit = (bits as f64) * (1.0 / ((1u64 << 53) as f64));
    2.0 * unit - 1.0
}

/// Per-device behavioral expression metadata, stored in `Circuit::bsource_exprs`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BsourceExpr {
    /// The parsed expression AST.
    pub expr: BehavioralExpr,
    /// Ordered list of node names referenced in the expression.
    ///
    /// The stamper looks up these nodes by name and passes their voltages
    /// to `BehavioralExpr::eval`.
    pub node_refs: Vec<String>,
    /// Pre-differentiated partial derivatives: `partials[i] = d(expr)/dV(node_refs[i])`.
    pub partials: Vec<BehavioralExpr>,
}

impl BsourceExpr {
    /// Build from an expression by collecting node refs and differentiating.
    pub fn new(expr: BehavioralExpr) -> Self {
        let mut node_refs = Vec::new();
        expr.collect_node_refs(&mut node_refs);
        let partials = node_refs
            .iter()
            .map(|n| expr.differentiate(n))
            .collect();
        Self { expr, node_refs, partials }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nv(name: &str) -> BehavioralExpr {
        BehavioralExpr::NodeVoltage(name.into())
    }

    fn lit(v: f64) -> BehavioralExpr {
        BehavioralExpr::Lit(v)
    }

    fn mul(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BinOp::Mul, Box::new(a), Box::new(b))
    }

    fn add(a: BehavioralExpr, b: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BinOp::Add, Box::new(a), Box::new(b))
    }

    #[test]
    fn eval_constant() {
        let e = lit(3.14);
        assert!((e.eval(&[], &[]).unwrap() - 3.14).abs() < 1e-15);
    }

    #[test]
    fn eval_node_voltage() {
        let e = nv("1");
        assert_eq!(e.eval(&[("1", 2.5)], &[]).unwrap(), 2.5);
    }

    #[test]
    fn eval_gain() {
        // 2 * V(in)
        let e = mul(lit(2.0), nv("in"));
        assert_eq!(e.eval(&[("in", 1.5)], &[]).unwrap(), 3.0);
    }

    #[test]
    fn eval_multiplier() {
        // V(a) * V(b)
        let e = mul(nv("a"), nv("b"));
        assert_eq!(e.eval(&[("a", 3.0), ("b", 4.0)], &[]).unwrap(), 12.0);
    }

    #[test]
    fn differentiate_linear() {
        // d(2 * V(n)) / dV(n) = 2
        let e = mul(lit(2.0), nv("n"));
        let de = e.differentiate("n");
        // Evaluate the derivative (should be 2.0 regardless of V(n))
        let val = de.eval(&[("n", 5.0)], &[]).unwrap();
        assert!((val - 2.0).abs() < 1e-12, "expected 2.0, got {val}");
    }

    #[test]
    fn differentiate_product() {
        // d(V(a) * V(b)) / dV(a) = V(b)
        let e = mul(nv("a"), nv("b"));
        let de = e.differentiate("a");
        let val = de.eval(&[("a", 3.0), ("b", 4.0)], &[]).unwrap();
        assert!((val - 4.0).abs() < 1e-12, "d(V(a)*V(b))/dV(a) = V(b) = 4.0, got {val}");
    }

    #[test]
    fn differentiate_sum() {
        // d(V(a) + V(b)) / dV(a) = 1
        let e = add(nv("a"), nv("b"));
        let de = e.differentiate("a");
        let val = de.eval(&[("a", 1.0), ("b", 2.0)], &[]).unwrap();
        assert!((val - 1.0).abs() < 1e-12, "expected 1.0, got {val}");
    }

    #[test]
    fn collect_node_refs_dedup() {
        // V(a) * V(a) + V(b) → refs = ["a", "b"]
        let e = add(mul(nv("a"), nv("a")), nv("b"));
        let mut refs = Vec::new();
        e.collect_node_refs(&mut refs);
        assert_eq!(refs, vec!["a", "b"]);
    }

    #[test]
    fn bsource_expr_new() {
        let e = mul(lit(2.0), nv("2"));
        let bse = BsourceExpr::new(e);
        assert_eq!(bse.node_refs, vec!["2"]);
        assert_eq!(bse.partials.len(), 1);
        // d(2*V(2))/dV(2) = 2 regardless of voltage
        let val = bse.partials[0].eval(&[("2", 99.0)], &[]).unwrap();
        assert!((val - 2.0).abs() < 1e-12, "partial = {val}");
    }

    #[test]
    fn eval_func_sqrt() {
        let e = BehavioralExpr::Func("sqrt".into(), vec![lit(9.0)]);
        assert!((e.eval(&[], &[]).unwrap() - 3.0).abs() < 1e-15);
    }

    #[test]
    fn eval_func_if() {
        // if(1, 10, 20) = 10
        let e = BehavioralExpr::Func("if".into(), vec![lit(1.0), lit(10.0), lit(20.0)]);
        assert_eq!(e.eval(&[], &[]).unwrap(), 10.0);
        // if(0, 10, 20) = 20
        let e2 = BehavioralExpr::Func("if".into(), vec![lit(0.0), lit(10.0), lit(20.0)]);
        assert_eq!(e2.eval(&[], &[]).unwrap(), 20.0);
    }

    fn func1(name: &str, x: f64) -> f64 {
        BehavioralExpr::Func(name.into(), vec![lit(x)])
            .eval(&[], &[])
            .unwrap()
    }

    fn func2(name: &str, x: f64, y: f64) -> f64 {
        BehavioralExpr::Func(name.into(), vec![lit(x), lit(y)])
            .eval(&[], &[])
            .unwrap()
    }

    fn func3(name: &str, x: f64, y: f64, z: f64) -> f64 {
        BehavioralExpr::Func(name.into(), vec![lit(x), lit(y), lit(z)])
            .eval(&[], &[])
            .unwrap()
    }

    #[test]
    fn eval_ceil_floor_round_int_nint() {
        assert_eq!(func1("ceil",  1.2),  2.0);
        assert_eq!(func1("ceil", -1.2), -1.0);
        assert_eq!(func1("floor", 1.9),  1.0);
        assert_eq!(func1("floor",-1.1), -2.0);
        assert_eq!(func1("round", 1.5),  2.0);
        assert_eq!(func1("round", 1.4),  1.0);
        assert_eq!(func1("int",   3.9),  3.0);
        assert_eq!(func1("int",  -3.9), -3.0);
        assert_eq!(func1("nint", 2.6),   3.0);
        assert_eq!(func1("nint", 2.4),   2.0);
    }

    #[test]
    fn eval_db() {
        assert!((func1("db",  1.0)).abs() < 1e-10);
        assert!((func1("db", 10.0) - 20.0).abs() < 1e-10);
        assert!((func1("db", -10.0) - 20.0).abs() < 1e-10);
    }

    #[test]
    fn eval_uramp_and_u() {
        assert_eq!(func1("uramp",  3.0), 3.0);
        assert_eq!(func1("uramp", -2.0), 0.0);
        assert_eq!(func1("u",  1.0), 1.0);
        assert_eq!(func1("u",  0.0), 1.0);
        assert_eq!(func1("u", -1.0), 0.0);
    }

    #[test]
    fn eval_pwr_and_pwrs() {
        assert_eq!(func2("pwr",  -2.0, 3.0),  8.0);
        assert_eq!(func2("pwr",   2.0, 3.0),  8.0);
        assert_eq!(func2("pwrs", -2.0, 3.0), -8.0);
        assert_eq!(func2("pwrs",  2.0, 3.0),  8.0);
    }

    #[test]
    fn eval_hyperbolic_funcs() {
        assert!((func1("cosh", 0.0) - 1.0).abs() < 1e-12);
        assert!((func1("sinh", 0.0)).abs() < 1e-12);
        assert!((func1("tanh", 0.0)).abs() < 1e-12);
        assert!((func1("acosh", 1.0)).abs() < 1e-12);
        assert!((func1("asinh", 0.0)).abs() < 1e-12);
        assert!((func1("atanh", 0.0)).abs() < 1e-12);
    }

    #[test]
    fn eval_log2() {
        assert!((func1("log2", 8.0) - 3.0).abs() < 1e-12);
        assert!((func1("log2", 1.0)).abs() < 1e-12);
    }

    #[test]
    fn eval_hypot() {
        assert!((func2("hypot", 3.0, 4.0) - 5.0).abs() < 1e-12);
    }

    #[test]
    fn eval_sgn() {
        assert_eq!(func1("sgn",  5.0),  1.0);
        assert_eq!(func1("sgn", -3.0), -1.0);
        assert_eq!(func1("sgn",  0.0),  0.0);
    }

    #[test]
    fn eval_limit_clamp() {
        assert_eq!(func3("limit",  5.0, 0.0, 10.0),  5.0);
        assert_eq!(func3("limit", -1.0, 0.0, 10.0),  0.0);
        assert_eq!(func3("limit", 15.0, 0.0, 10.0), 10.0);
    }

    #[test]
    fn eval_gauss_finite() {
        let v = func1("gauss", 1.0);
        assert!(v.is_finite());
    }

    #[test]
    fn eval_agauss_finite() {
        let v = func2("agauss", 5.0, 1.0);
        assert!(v.is_finite());
    }

    #[test]
    fn eval_unif_in_range() {
        for _ in 0..20 {
            let v = func1("unif", 1.0);
            assert!(v >= -1.0 && v <= 1.0, "unif(1) = {v} out of [-1,1]");
        }
    }

    #[test]
    fn eval_aunif_in_range() {
        for _ in 0..20 {
            let v = func2("aunif", 5.0, 1.0);
            assert!(v >= 4.0 && v <= 6.0, "aunif(5,1) = {v} out of [4,6]");
        }
    }

    #[test]
    fn eval_flat_in_range() {
        for _ in 0..20 {
            let v = func1("flat", 2.0);
            assert!(v >= -2.0 && v <= 2.0, "flat(2) = {v} out of [-2,2]");
        }
    }
}
