//! Behavioral expression AST for B-source devices.
//!
//! This module defines the expression tree used by B-source (`B` element)
//! device evaluation.  It lives in `incspice-core` so that both `incspice-device`
//! (evaluation) and `incspice-parser` (construction) can use it without a
//! circular dependency.
//!
//! The parser builds an `Expression` (its own richer AST), then converts it
//! to `BehavioralExpr` via `From<incspice_parser::Expression>`.

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

/// Returns `true` if the expression is syntactically the literal `0.0`.
/// Used inside `differentiate` to avoid emitting a dead second term in the
/// power rule when the exponent does not depend on the differentiation variable.
fn is_zero_expr(e: &BehavioralExpr) -> bool {
    matches!(e, BehavioralExpr::Lit(v) if *v == 0.0)
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
            BehavioralExpr::Param(name) => params
                .iter()
                .find(|(k, _)| *k == name.as_str())
                .map(|(_, v)| *v)
                .ok_or_else(|| {
                    crate::SimError::Parse(format!("B-source: parameter '{name}' not found"))
                }),
            BehavioralExpr::NodeVoltage(node) => node_voltages
                .iter()
                .find(|(k, _)| *k == node.as_str())
                .map(|(_, v)| *v)
                .ok_or_else(|| {
                    crate::SimError::Parse(format!(
                        "B-source: node voltage V({node}) not available"
                    ))
                }),
            BehavioralExpr::Neg(inner) => inner.eval(node_voltages, params).map(|v| -v),
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
                let evaled: Result<Vec<f64>, _> =
                    args.iter().map(|a| a.eval(node_voltages, params)).collect();
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
                    BinOp::Add => BehavioralExpr::BinOp(BinOp::Add, Box::new(dl), Box::new(dr)),
                    BinOp::Sub => BehavioralExpr::BinOp(BinOp::Sub, Box::new(dl), Box::new(dr)),
                    // Product rule: d(u*v) = du*v + u*dv
                    BinOp::Mul => BehavioralExpr::BinOp(
                        BinOp::Add,
                        Box::new(BehavioralExpr::BinOp(BinOp::Mul, Box::new(dl), rhs.clone())),
                        Box::new(BehavioralExpr::BinOp(BinOp::Mul, lhs.clone(), Box::new(dr))),
                    ),
                    // Quotient rule: d(u/v) = (du*v - u*dv) / v^2
                    BinOp::Div => BehavioralExpr::BinOp(
                        BinOp::Div,
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Sub,
                            Box::new(BehavioralExpr::BinOp(BinOp::Mul, Box::new(dl), rhs.clone())),
                            Box::new(BehavioralExpr::BinOp(BinOp::Mul, lhs.clone(), Box::new(dr))),
                        )),
                        Box::new(BehavioralExpr::BinOp(
                            BinOp::Pow,
                            rhs.clone(),
                            Box::new(BehavioralExpr::Lit(2.0)),
                        )),
                    ),
                    // Full power rule: d(u^v)/dx = v * u^(v-1) * du/dx  +  u^v * ln(u) * dv/dx
                    BinOp::Pow => {
                        // term1: v * u^(v-1) * du/dx
                        let term1 = BehavioralExpr::BinOp(
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
                        );
                        // If dv/dx == 0 (constant exponent), skip the second term.
                        if is_zero_expr(&dr) {
                            term1
                        } else {
                            // term2: u^v * ln(u) * dv/dx
                            let term2 = BehavioralExpr::BinOp(
                                BinOp::Mul,
                                Box::new(BehavioralExpr::BinOp(
                                    BinOp::Mul,
                                    Box::new(BehavioralExpr::BinOp(
                                        BinOp::Pow,
                                        lhs.clone(),
                                        rhs.clone(),
                                    )),
                                    Box::new(BehavioralExpr::Func(
                                        "ln".into(),
                                        vec![*lhs.clone()],
                                    )),
                                )),
                                Box::new(dr),
                            );
                            BehavioralExpr::BinOp(
                                BinOp::Add,
                                Box::new(term1),
                                Box::new(term2),
                            )
                        }
                    }
                }
            }
            BehavioralExpr::Func(name, args) => match (name.as_str(), args.as_slice()) {
                // TABLE chain rule: d/dvar TABLE(x, pts...) = table_slope(x, pts) * dx/dvar
                ("__table__", [x_expr, ..]) if args.len() >= 3 => {
                    let dx = x_expr.differentiate(var_node);
                    if is_zero_expr(&dx) {
                        BehavioralExpr::Lit(0.0)
                    } else {
                        // __table_slope__(x, x0, y0, x1, y1, ...) evaluates to dy/dx
                        // Same arg list as __table__; the marker function
                        // computes the slope instead of the value.
                        let slope_call =
                            BehavioralExpr::Func("__table_slope__".into(), args.clone());
                        BehavioralExpr::BinOp(BinOp::Mul, Box::new(slope_call), Box::new(dx))
                    }
                }
                // __table_slope__ is a runtime-only helper; its own derivative is
                // the second derivative of the piecewise-linear table, which is
                // zero everywhere (PWL is linear in each segment).
                ("__table_slope__", _) => BehavioralExpr::Lit(0.0),
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
                            "sin".into(),
                            vec![u.clone()],
                        )))),
                        Box::new(du),
                    )
                }
                _ => BehavioralExpr::Lit(0.0),
            },
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
        "sqrt" => {
            check(1)?;
            Ok(args[0].sqrt())
        }
        "abs" => {
            check(1)?;
            Ok(args[0].abs())
        }
        "exp" => {
            check(1)?;
            Ok(args[0].exp())
        }
        "log" | "ln" => {
            check(1)?;
            Ok(args[0].ln())
        }
        "log10" => {
            check(1)?;
            Ok(args[0].log10())
        }
        "sin" => {
            check(1)?;
            Ok(args[0].sin())
        }
        "cos" => {
            check(1)?;
            Ok(args[0].cos())
        }
        "tan" => {
            check(1)?;
            Ok(args[0].tan())
        }
        "asin" => {
            check(1)?;
            Ok(args[0].asin())
        }
        "acos" => {
            check(1)?;
            Ok(args[0].acos())
        }
        "atan" => {
            check(1)?;
            Ok(args[0].atan())
        }
        "atan2" => {
            check(2)?;
            Ok(args[0].atan2(args[1]))
        }
        "pow" => {
            check(2)?;
            Ok(args[0].powf(args[1]))
        }
        "min" => {
            check(2)?;
            Ok(args[0].min(args[1]))
        }
        "max" => {
            check(2)?;
            Ok(args[0].max(args[1]))
        }
        "sign" => {
            check(1)?;
            Ok(args[0].signum())
        }
        "if" => {
            check(3)?;
            Ok(if args[0] != 0.0 { args[1] } else { args[2] })
        }
        // --- Rounding / integer ---
        "ceil" => {
            check(1)?;
            Ok(args[0].ceil())
        }
        "floor" => {
            check(1)?;
            Ok(args[0].floor())
        }
        "round" => {
            check(1)?;
            Ok(args[0].round())
        }
        "int" => {
            check(1)?;
            Ok(args[0].trunc())
        }
        "nint" => {
            check(1)?;
            Ok(args[0].round())
        }
        // --- Decibel ---
        "db" => {
            check(1)?;
            Ok(20.0 * args[0].abs().log10())
        }
        // --- Step / ramp ---
        "uramp" => {
            check(1)?;
            Ok(args[0].max(0.0))
        }
        "u" => {
            check(1)?;
            Ok(if args[0] >= 0.0 { 1.0 } else { 0.0 })
        }
        // --- Power (HSPICE B-source) ---
        "pwr" => {
            check(2)?;
            Ok(args[0].abs().powf(args[1]))
        }
        "pwrs" => {
            check(2)?;
            Ok(args[0].signum() * args[0].abs().powf(args[1]))
        }
        // --- Hyperbolic ---
        "cosh" => {
            check(1)?;
            Ok(args[0].cosh())
        }
        "sinh" => {
            check(1)?;
            Ok(args[0].sinh())
        }
        "tanh" => {
            check(1)?;
            Ok(args[0].tanh())
        }
        "acosh" => {
            check(1)?;
            Ok(args[0].acosh())
        }
        "asinh" => {
            check(1)?;
            Ok(args[0].asinh())
        }
        "atanh" => {
            check(1)?;
            Ok(args[0].atanh())
        }
        // --- Log ---
        "log2" => {
            check(1)?;
            Ok(args[0].log2())
        }
        // --- Geometry ---
        "hypot" => {
            check(2)?;
            Ok(args[0].hypot(args[1]))
        }
        // --- Sign alias ---
        "sgn" => {
            check(1)?;
            let x = args[0];
            Ok(if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            })
        }
        // --- Clamp ---
        "limit" => {
            check(3)?;
            Ok(args[0].clamp(args[1], args[2]))
        }
        // --- Statistical (stochastic; use thread-local PRNG) ---
        "gauss" => {
            check(1)?;
            Ok(args[0] * bsource_sample_normal())
        }
        "agauss" => {
            check(2)?;
            Ok(args[0] + args[1] * bsource_sample_normal())
        }
        "unif" => {
            check(1)?;
            Ok(args[0] * bsource_sample_uniform_signed())
        }
        "aunif" => {
            check(2)?;
            Ok(args[0] + args[1] * bsource_sample_uniform_signed())
        }
        "flat" => {
            check(1)?;
            Ok(args[0] * bsource_sample_uniform_signed())
        }
        "__table__" | "__table_slope__" => {
            // args[0] = x value, args[1..] = x0,y0,x1,y1,...
            if args.len() < 3 || args.len() % 2 == 0 {
                return Err(crate::SimError::Parse(
                    "TABLE: need x + at least one (x,y) pair".into(),
                ));
            }
            let x = args[0];
            let mut points: Vec<(f64, f64)> = Vec::with_capacity((args.len() - 1) / 2);
            let mut i = 1;
            while i + 1 < args.len() {
                points.push((args[i], args[i + 1]));
                i += 2;
            }
            points.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
            if name == "__table__" {
                Ok(table_interp_value(&points, x))
            } else {
                Ok(table_interp_slope(&points, x))
            }
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

// ---------------------------------------------------------------------------
// TABLE interpolation helpers (piecewise-linear with endpoint clamping)
// ---------------------------------------------------------------------------

/// Linear interpolation in a sorted piecewise-linear table.  Outside the
/// table range the value is clamped to the nearest endpoint (no extrapolation),
/// consistent with ngspice/hspice behaviour.
fn table_interp_value(points: &[(f64, f64)], x: f64) -> f64 {
    if points.is_empty() {
        return 0.0;
    }
    if x <= points[0].0 {
        return points[0].1;
    }
    let last = points.len() - 1;
    if x >= points[last].0 {
        return points[last].1;
    }
    // Binary search for the segment containing x.
    let i = match points
        .binary_search_by(|p| p.0.partial_cmp(&x).unwrap_or(std::cmp::Ordering::Equal))
    {
        Ok(i) => return points[i].1, // exact hit
        Err(i) => i,
    };
    let (x0, y0) = points[i - 1];
    let (x1, y1) = points[i];
    let t = (x - x0) / (x1 - x0);
    y0 + t * (y1 - y0)
}

/// Slope dy/dx at position `x` for a piecewise-linear table.  Outside the
/// table the slope is zero (clamped extrapolation has zero derivative).
fn table_interp_slope(points: &[(f64, f64)], x: f64) -> f64 {
    if points.len() < 2 {
        return 0.0;
    }
    let last = points.len() - 1;
    if x <= points[0].0 || x >= points[last].0 {
        return 0.0;
    }
    let i = match points
        .binary_search_by(|p| p.0.partial_cmp(&x).unwrap_or(std::cmp::Ordering::Equal))
    {
        Ok(i) => {
            // On a knot — use right-hand slope if available.
            if i + 1 <= last {
                let (x0, y0) = points[i];
                let (x1, y1) = points[i + 1];
                return (y1 - y0) / (x1 - x0);
            }
            return 0.0;
        }
        Err(i) => i,
    };
    let (x0, y0) = points[i - 1];
    let (x1, y1) = points[i];
    (y1 - y0) / (x1 - x0)
}

// ---------------------------------------------------------------------------
// ExprEval — parameter expression evaluator
// ---------------------------------------------------------------------------

/// Error type for `.PARAM` expression evaluation.
#[derive(Debug, Clone, PartialEq)]
pub enum ExprError {
    /// Referenced parameter has not been defined.
    UndefinedParam(String),
    /// Division by zero in the expression.
    DivisionByZero,
    /// Unknown function name.
    UnknownFunction(String),
    /// Parse error (malformed expression string).
    ParseError(String),
    /// Circular dependency detected among parameters.
    CircularDependency(String),
}

impl std::fmt::Display for ExprError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExprError::UndefinedParam(n) => write!(f, "undefined parameter '{n}'"),
            ExprError::DivisionByZero => write!(f, "division by zero"),
            ExprError::UnknownFunction(n) => write!(f, "unknown function '{n}'"),
            ExprError::ParseError(s) => write!(f, "parse error: {s}"),
            ExprError::CircularDependency(s) => write!(f, "circular dependency: {s}"),
        }
    }
}

impl std::error::Error for ExprError {}

/// Lightweight expression evaluator for `.PARAM` expressions.
///
/// Supports:
/// - Numeric literals (with optional SI suffix: `k`, `m`, `u`, `n`, `p`, `f`, `M`, `G`, `T`, `meg`)
/// - Named parameter references
/// - Arithmetic operators `+`, `-`, `*`, `/`
/// - Parentheses `(` `)` and brace-wrapped expressions `{ }`
/// - Functions: `sqrt`, `pow`, `abs`, `log`, `exp`, `sin`, `cos`, `tan`, `min`, `max`
/// - User-defined functions (registered via `.func` directives)
///
/// Expression strings may optionally be wrapped in `{...}`.
pub struct ExprEval {
    vars: std::collections::HashMap<String, f64>,
    user_funcs: std::collections::HashMap<String, (Vec<String>, String)>,
}

impl ExprEval {
    /// Create a new empty evaluator.
    pub fn new() -> Self {
        Self {
            vars: std::collections::HashMap::new(),
            user_funcs: std::collections::HashMap::new(),
        }
    }

    /// Register a user-defined function (from .func directives).
    pub fn set_user_func(&mut self, name: &str, params: Vec<String>, body: String) {
        self.user_funcs.insert(name.to_ascii_lowercase(), (params, body));
    }

    /// Set a named variable/parameter value.
    pub fn set_var(&mut self, name: &str, val: f64) {
        self.vars.insert(name.to_ascii_lowercase(), val);
    }

    /// Get a named variable value (case-insensitive lookup).
    pub fn get_var(&self, name: &str) -> Option<f64> {
        self.vars.get(&name.to_ascii_lowercase()).copied()
    }

    /// Evaluate an expression string.
    ///
    /// The string may be surrounded by `{...}` or not.
    /// Returns the computed `f64` or an `ExprError`.
    pub fn eval(&self, expr: &str) -> Result<f64, ExprError> {
        // Strip surrounding braces if present
        let s = expr.trim();
        let s = if s.starts_with('{') && s.ends_with('}') {
            &s[1..s.len() - 1]
        } else {
            s
        };
        let bytes = s.as_bytes();
        let mut pos = 0usize;
        let val = self.parse_expr(bytes, &mut pos)?;
        Ok(val)
    }

    // ── Internal recursive descent parser ────────────────────────────────────

    fn parse_expr(&self, bytes: &[u8], pos: &mut usize) -> Result<f64, ExprError> {
        self.parse_addition(bytes, pos)
    }

    fn parse_addition(&self, bytes: &[u8], pos: &mut usize) -> Result<f64, ExprError> {
        let mut lhs = self.parse_term(bytes, pos)?;
        loop {
            expr_skip_ws(bytes, pos);
            if *pos < bytes.len() && bytes[*pos] == b'+' {
                *pos += 1;
                let rhs = self.parse_term(bytes, pos)?;
                lhs += rhs;
            } else if *pos < bytes.len() && bytes[*pos] == b'-' {
                *pos += 1;
                let rhs = self.parse_term(bytes, pos)?;
                lhs -= rhs;
            } else {
                break;
            }
        }
        Ok(lhs)
    }

    fn parse_term(&self, bytes: &[u8], pos: &mut usize) -> Result<f64, ExprError> {
        let mut lhs = self.parse_unary(bytes, pos)?;
        loop {
            expr_skip_ws(bytes, pos);
            if *pos < bytes.len() && bytes[*pos] == b'*' {
                *pos += 1;
                let rhs = self.parse_unary(bytes, pos)?;
                lhs *= rhs;
            } else if *pos < bytes.len() && bytes[*pos] == b'/' {
                *pos += 1;
                let rhs = self.parse_unary(bytes, pos)?;
                if rhs == 0.0 {
                    return Err(ExprError::DivisionByZero);
                }
                lhs /= rhs;
            } else {
                break;
            }
        }
        Ok(lhs)
    }

    fn parse_unary(&self, bytes: &[u8], pos: &mut usize) -> Result<f64, ExprError> {
        expr_skip_ws(bytes, pos);
        if *pos < bytes.len() && bytes[*pos] == b'-' {
            *pos += 1;
            let inner = self.parse_primary(bytes, pos)?;
            Ok(-inner)
        } else if *pos < bytes.len() && bytes[*pos] == b'+' {
            *pos += 1;
            self.parse_primary(bytes, pos)
        } else {
            self.parse_primary(bytes, pos)
        }
    }

    fn parse_primary(&self, bytes: &[u8], pos: &mut usize) -> Result<f64, ExprError> {
        expr_skip_ws(bytes, pos);
        if *pos >= bytes.len() {
            return Ok(0.0);
        }
        match bytes[*pos] {
            b'(' => {
                *pos += 1;
                let val = self.parse_expr(bytes, pos)?;
                expr_skip_ws(bytes, pos);
                if *pos < bytes.len() && bytes[*pos] == b')' {
                    *pos += 1;
                }
                Ok(val)
            }
            b'{' => {
                *pos += 1;
                let val = self.parse_expr(bytes, pos)?;
                expr_skip_ws(bytes, pos);
                if *pos < bytes.len() && bytes[*pos] == b'}' {
                    *pos += 1;
                }
                Ok(val)
            }
            b'0'..=b'9' | b'.' => {
                // Parse number with optional SI suffix
                parse_number_with_suffix(bytes, pos)
            }
            b'a'..=b'z' | b'A'..=b'Z' | b'_' => {
                // Identifier: param ref or function call
                let name_start = *pos;
                while *pos < bytes.len()
                    && (bytes[*pos].is_ascii_alphanumeric() || bytes[*pos] == b'_')
                {
                    *pos += 1;
                }
                let name = std::str::from_utf8(&bytes[name_start..*pos])
                    .map_err(|_| ExprError::ParseError("invalid UTF-8 in name".into()))?;
                let name_lower = name.to_ascii_lowercase();

                expr_skip_ws(bytes, pos);
                if *pos < bytes.len() && bytes[*pos] == b'(' {
                    // Function call
                    *pos += 1;
                    let mut args = Vec::new();
                    loop {
                        expr_skip_ws(bytes, pos);
                        if *pos >= bytes.len() || bytes[*pos] == b')' {
                            break;
                        }
                        args.push(self.parse_expr(bytes, pos)?);
                        expr_skip_ws(bytes, pos);
                        if *pos < bytes.len() && bytes[*pos] == b',' {
                            *pos += 1;
                        } else {
                            break;
                        }
                    }
                    if *pos < bytes.len() && bytes[*pos] == b')' {
                        *pos += 1;
                    }
                    // Check user-defined functions first, then built-ins
                    if let Some((param_names, body)) = self.user_funcs.get(&name_lower) {
                        let param_names = param_names.clone();
                        let body = body.clone();
                        if args.len() != param_names.len() {
                            return Err(ExprError::ParseError(format!(
                                "function '{}' expects {} args, got {}",
                                name_lower, param_names.len(), args.len()
                            )));
                        }
                        let mut child = ExprEval {
                            vars: self.vars.clone(),
                            user_funcs: self.user_funcs.clone(),
                        };
                        for (pname, &aval) in param_names.iter().zip(args.iter()) {
                            child.set_var(pname, aval);
                        }
                        child.eval(&body)
                    } else {
                        eval_expr_func(&name_lower, &args)
                    }
                } else {
                    // Parameter reference
                    self.vars
                        .get(&name_lower)
                        .copied()
                        .ok_or_else(|| ExprError::UndefinedParam(name.to_string()))
                }
            }
            _ => {
                *pos += 1;
                Ok(0.0)
            }
        }
    }
}

impl Default for ExprEval {
    fn default() -> Self {
        Self::new()
    }
}

/// Skip ASCII whitespace in a byte slice.
#[inline]
fn expr_skip_ws(bytes: &[u8], pos: &mut usize) {
    while *pos < bytes.len() && matches!(bytes[*pos], b' ' | b'\t' | b'\r' | b'\n') {
        *pos += 1;
    }
}

/// Parse a floating-point number followed by an optional SI suffix.
///
/// Recognises: `k` (×1e3), `m` (×1e-3), `u` (×1e-6), `n` (×1e-9),
/// `p` (×1e-12), `f` (×1e-15), `M`/`meg` (×1e6), `G` (×1e9), `T` (×1e12).
fn parse_number_with_suffix(bytes: &[u8], pos: &mut usize) -> Result<f64, ExprError> {
    expr_skip_ws(bytes, pos);
    let start = *pos;
    // Digits and decimal point
    while *pos < bytes.len() && (bytes[*pos].is_ascii_digit() || bytes[*pos] == b'.') {
        *pos += 1;
    }
    // Optional exponent
    if *pos < bytes.len() && (bytes[*pos] == b'e' || bytes[*pos] == b'E') {
        *pos += 1;
        if *pos < bytes.len() && (bytes[*pos] == b'+' || bytes[*pos] == b'-') {
            *pos += 1;
        }
        while *pos < bytes.len() && bytes[*pos].is_ascii_digit() {
            *pos += 1;
        }
    }
    let num_end = *pos;
    let num_str = std::str::from_utf8(&bytes[start..num_end])
        .map_err(|_| ExprError::ParseError("invalid number".into()))?;
    let base: f64 = num_str
        .parse()
        .map_err(|_| ExprError::ParseError(format!("cannot parse '{num_str}' as number")))?;

    // Check for SI suffix — scan alphabetic chars
    let suffix_start = *pos;
    while *pos < bytes.len() && bytes[*pos].is_ascii_alphabetic() {
        *pos += 1;
    }
    let suffix = std::str::from_utf8(&bytes[suffix_start..*pos]).unwrap_or("");
    let suffix_lower = suffix.to_ascii_lowercase();
    let multiplier = match suffix_lower.as_str() {
        "k" | "kil" | "kilo" => 1e3,
        "meg" | "mega" => 1e6,
        "m" | "mil" | "milli" => 1e-3,
        "u" | "micro" => 1e-6,
        "n" | "nano" => 1e-9,
        "p" | "pico" => 1e-12,
        "f" | "femto" => 1e-15,
        "g" | "giga" => 1e9,
        "t" | "tera" => 1e12,
        // Capital M in SPICE traditionally means mega (1e6)
        // but we get lowercase here — empty means no suffix
        "" => 1.0,
        // Unknown suffix — ignore
        _ => 1.0,
    };
    Ok(base * multiplier)
}

/// Evaluate a built-in math function with already-evaluated arguments.
fn eval_expr_func(name: &str, args: &[f64]) -> Result<f64, ExprError> {
    let check = |n: usize| {
        if args.len() != n {
            Err(ExprError::ParseError(format!(
                "function '{name}' expects {n} args, got {}",
                args.len()
            )))
        } else {
            Ok(())
        }
    };
    match name {
        "sqrt" => { check(1)?; Ok(args[0].sqrt()) }
        "abs"  => { check(1)?; Ok(args[0].abs()) }
        "exp"  => { check(1)?; Ok(args[0].exp()) }
        "log" | "ln" | "log10" => {
            check(1)?;
            if name == "log10" { Ok(args[0].log10()) } else { Ok(args[0].ln()) }
        }
        "log2" => { check(1)?; Ok(args[0].log2()) }
        "sin"  => { check(1)?; Ok(args[0].sin()) }
        "cos"  => { check(1)?; Ok(args[0].cos()) }
        "tan"  => { check(1)?; Ok(args[0].tan()) }
        "asin" => { check(1)?; Ok(args[0].asin()) }
        "acos" => { check(1)?; Ok(args[0].acos()) }
        "atan" => { check(1)?; Ok(args[0].atan()) }
        "atan2" => { check(2)?; Ok(args[0].atan2(args[1])) }
        "pow"  => { check(2)?; Ok(args[0].powf(args[1])) }
        "min"  => { check(2)?; Ok(args[0].min(args[1])) }
        "max"  => { check(2)?; Ok(args[0].max(args[1])) }
        "floor" => { check(1)?; Ok(args[0].floor()) }
        "ceil"  => { check(1)?; Ok(args[0].ceil()) }
        "round" => { check(1)?; Ok(args[0].round()) }
        "sign" | "sgn" => { check(1)?; Ok(args[0].signum()) }
        "int"   => { check(1)?; Ok(args[0].trunc()) }
        "hypot" => { check(2)?; Ok(args[0].hypot(args[1])) }
        _ => Err(ExprError::UnknownFunction(name.to_string())),
    }
}

/// Topologically sort `.PARAM` definitions so that dependencies are evaluated first.
///
/// `params` is a list of `(name, raw_expr_string)` pairs.  Returns the names
/// in evaluation order, or an `ExprError::CircularDependency` if a cycle exists.
pub fn topo_sort_params(params: &[(String, String)]) -> Result<Vec<usize>, ExprError> {
    let n = params.len();
    // Build a quick name→index lookup (case-insensitive)
    let mut name_to_idx: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for (i, (name, _)) in params.iter().enumerate() {
        name_to_idx.insert(name.to_ascii_lowercase(), i);
    }

    // Build adjacency list: edges[i] = list of indices that i depends on
    let mut deps: Vec<Vec<usize>> = vec![vec![]; n];
    for (i, (_, expr_str)) in params.iter().enumerate() {
        let names = extract_param_names(expr_str);
        for dep_name in names {
            if let Some(&j) = name_to_idx.get(&dep_name.to_ascii_lowercase()) {
                if j != i {
                    deps[i].push(j);
                }
            }
        }
    }

    // Kahn's algorithm (topological sort)
    let mut in_degree = vec![0usize; n];
    for i in 0..n {
        for &j in &deps[i] {
            in_degree[j] += 1; // j is needed before i → j's out-degree += 1
        }
    }
    // Recompute: in_degree[i] = number of dependencies i has not yet resolved
    let mut in_deg2 = vec![0usize; n];
    for i in 0..n {
        in_deg2[i] = deps[i].len();
    }
    let mut queue: std::collections::VecDeque<usize> = std::collections::VecDeque::new();
    for i in 0..n {
        if in_deg2[i] == 0 {
            queue.push_back(i);
        }
    }
    let mut order = Vec::with_capacity(n);
    // Build reverse adjacency: rev_adj[j] = indices that depend on j
    let mut rev_adj: Vec<Vec<usize>> = vec![vec![]; n];
    for i in 0..n {
        for &j in &deps[i] {
            rev_adj[j].push(i);
        }
    }
    while let Some(node) = queue.pop_front() {
        order.push(node);
        for &dependent in &rev_adj[node] {
            in_deg2[dependent] -= 1;
            if in_deg2[dependent] == 0 {
                queue.push_back(dependent);
            }
        }
    }
    if order.len() != n {
        // Find a param involved in the cycle for a useful error message
        let cycle_names: Vec<&str> = params
            .iter()
            .enumerate()
            .filter(|(i, _)| !order.contains(i))
            .map(|(_, (name, _))| name.as_str())
            .collect();
        return Err(ExprError::CircularDependency(cycle_names.join(", ")));
    }
    Ok(order)
}

/// Extract identifiers from an expression string that look like parameter references.
///
/// Simple heuristic: collect sequences of `[a-zA-Z_][a-zA-Z0-9_]*` that are NOT
/// known function names.
fn extract_param_names(expr: &str) -> Vec<String> {
    // Strip surrounding braces
    let s = expr.trim();
    let s = if s.starts_with('{') && s.ends_with('}') {
        &s[1..s.len() - 1]
    } else {
        s
    };

    const BUILTIN_FUNCS: &[&str] = &[
        "sqrt", "abs", "exp", "log", "ln", "log10", "log2", "sin", "cos", "tan",
        "asin", "acos", "atan", "atan2", "pow", "min", "max", "floor", "ceil",
        "round", "sign", "sgn", "int", "hypot",
    ];

    let bytes = s.as_bytes();
    let mut pos = 0;
    let mut names = Vec::new();
    while pos < bytes.len() {
        if bytes[pos].is_ascii_alphabetic() || bytes[pos] == b'_' {
            let start = pos;
            while pos < bytes.len() && (bytes[pos].is_ascii_alphanumeric() || bytes[pos] == b'_') {
                pos += 1;
            }
            let name = &s[start..pos];
            let name_lower = name.to_ascii_lowercase();
            // Skip if it's a builtin function followed by '('
            let next_pos = {
                let mut p = pos;
                while p < bytes.len() && matches!(bytes[p], b' ' | b'\t') { p += 1; }
                p
            };
            let is_func_call = next_pos < bytes.len() && bytes[next_pos] == b'(';
            if !is_func_call && !BUILTIN_FUNCS.contains(&name_lower.as_str()) {
                names.push(name_lower);
            }
        } else {
            pos += 1;
        }
    }
    names
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
        let partials = node_refs.iter().map(|n| expr.differentiate(n)).collect();
        Self {
            expr,
            node_refs,
            partials,
        }
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
        assert!(
            (val - 4.0).abs() < 1e-12,
            "d(V(a)*V(b))/dV(a) = V(b) = 4.0, got {val}"
        );
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

    fn pow(base: BehavioralExpr, exp: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(BinOp::Pow, Box::new(base), Box::new(exp))
    }

    #[test]
    fn differentiate_pow_constant_exponent() {
        // d(V(n)^2) / dV(n) = 2 * V(n)
        let e = pow(nv("n"), lit(2.0));
        let de = e.differentiate("n");
        // At V(n) = 3.0: 2 * 3 = 6
        let val = de.eval(&[("n", 3.0)], &[]).unwrap();
        assert!(
            (val - 6.0).abs() < 1e-12,
            "d(V(n)^2)/dV(n) at V(n)=3 should be 6.0, got {val}"
        );
        // At V(n) = 5.0: 2 * 5 = 10
        let val2 = de.eval(&[("n", 5.0)], &[]).unwrap();
        assert!(
            (val2 - 10.0).abs() < 1e-12,
            "d(V(n)^2)/dV(n) at V(n)=5 should be 10.0, got {val2}"
        );
    }

    #[test]
    fn differentiate_variable_exponent() {
        // d(2^V(n)) / dV(n) = 2^V(n) * ln(2)
        // At V(n) = 1.0: 2^1 * ln(2) = 2 * 0.693147... ≈ 1.386294...
        // At V(n) = 2.0: 2^2 * ln(2) = 4 * 0.693147... ≈ 2.772589...
        let e = pow(lit(2.0), nv("n"));
        let de = e.differentiate("n");

        let v1 = de.eval(&[("n", 1.0)], &[]).unwrap();
        let expected1 = 2.0_f64.powf(1.0) * 2.0_f64.ln();
        assert!(
            (v1 - expected1).abs() < 1e-10,
            "d(2^V(n))/dV(n) at V(n)=1 should be {expected1}, got {v1}"
        );

        let v2 = de.eval(&[("n", 2.0)], &[]).unwrap();
        let expected2 = 2.0_f64.powf(2.0) * 2.0_f64.ln();
        assert!(
            (v2 - expected2).abs() < 1e-10,
            "d(2^V(n))/dV(n) at V(n)=2 should be {expected2}, got {v2}"
        );
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
        assert_eq!(func1("ceil", 1.2), 2.0);
        assert_eq!(func1("ceil", -1.2), -1.0);
        assert_eq!(func1("floor", 1.9), 1.0);
        assert_eq!(func1("floor", -1.1), -2.0);
        assert_eq!(func1("round", 1.5), 2.0);
        assert_eq!(func1("round", 1.4), 1.0);
        assert_eq!(func1("int", 3.9), 3.0);
        assert_eq!(func1("int", -3.9), -3.0);
        assert_eq!(func1("nint", 2.6), 3.0);
        assert_eq!(func1("nint", 2.4), 2.0);
    }

    #[test]
    fn eval_db() {
        assert!((func1("db", 1.0)).abs() < 1e-10);
        assert!((func1("db", 10.0) - 20.0).abs() < 1e-10);
        assert!((func1("db", -10.0) - 20.0).abs() < 1e-10);
    }

    #[test]
    fn eval_uramp_and_u() {
        assert_eq!(func1("uramp", 3.0), 3.0);
        assert_eq!(func1("uramp", -2.0), 0.0);
        assert_eq!(func1("u", 1.0), 1.0);
        assert_eq!(func1("u", 0.0), 1.0);
        assert_eq!(func1("u", -1.0), 0.0);
    }

    #[test]
    fn eval_pwr_and_pwrs() {
        assert_eq!(func2("pwr", -2.0, 3.0), 8.0);
        assert_eq!(func2("pwr", 2.0, 3.0), 8.0);
        assert_eq!(func2("pwrs", -2.0, 3.0), -8.0);
        assert_eq!(func2("pwrs", 2.0, 3.0), 8.0);
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
        assert_eq!(func1("sgn", 5.0), 1.0);
        assert_eq!(func1("sgn", -3.0), -1.0);
        assert_eq!(func1("sgn", 0.0), 0.0);
    }

    #[test]
    fn eval_limit_clamp() {
        assert_eq!(func3("limit", 5.0, 0.0, 10.0), 5.0);
        assert_eq!(func3("limit", -1.0, 0.0, 10.0), 0.0);
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

    #[test]
    fn test_user_func_single_arg() {
        let mut eval = ExprEval::new();
        eval.set_user_func("square", vec!["x".into()], "{x*x}".into());
        let result = eval.eval("{square(4.0)}").unwrap();
        assert!((result - 16.0).abs() < 1e-10, "square(4) should be 16, got {result}");
    }

    #[test]
    fn test_user_func_two_args() {
        let mut eval = ExprEval::new();
        eval.set_user_func("mul", vec!["a".into(), "b".into()], "{a*b}".into());
        let result = eval.eval("{mul(3.0, 7.0)}").unwrap();
        assert!((result - 21.0).abs() < 1e-10, "mul(3,7) should be 21, got {result}");
    }

    #[test]
    fn test_user_func_uses_global_param() {
        let mut eval = ExprEval::new();
        eval.set_var("pi", std::f64::consts::PI);
        eval.set_user_func("circle_area", vec!["r".into()], "{pi*r*r}".into());
        let result = eval.eval("{circle_area(2.0)}").unwrap();
        let expected = std::f64::consts::PI * 4.0;
        assert!((result - expected).abs() < 1e-10, "circle_area(2) = {expected}, got {result}");
    }

    #[test]
    fn test_user_func_wrong_arg_count() {
        let mut eval = ExprEval::new();
        eval.set_user_func("add", vec!["a".into(), "b".into()], "{a+b}".into());
        let result = eval.eval("{add(1.0)}");
        assert!(result.is_err(), "should error on wrong arg count");
    }

    #[test]
    fn test_expr_eval_power_function() {
        let eval = ExprEval::new();
        let result = eval.eval("{pow(2.0, 10.0)}").unwrap();
        assert!((result - 1024.0).abs() < 1e-6, "pow(2,10)=1024, got {result}");
    }

    #[test]
    fn test_expr_eval_nested_functions() {
        let eval = ExprEval::new();
        let result = eval.eval("{sqrt(pow(3.0, 2.0) + pow(4.0, 2.0))}").unwrap();
        assert!((result - 5.0).abs() < 1e-6, "Pythagorean triple: got {result}");
    }

    #[test]
    fn test_expr_eval_min_max() {
        let eval = ExprEval::new();
        assert!((eval.eval("{min(3.0, 7.0)}").unwrap() - 3.0).abs() < 1e-10);
        assert!((eval.eval("{max(3.0, 7.0)}").unwrap() - 7.0).abs() < 1e-10);
    }

    #[test]
    fn test_expr_eval_trig() {
        let mut eval = ExprEval::new();
        eval.set_var("pi", std::f64::consts::PI);
        assert!(eval.eval("{sin(0.0)}").unwrap().abs() < 1e-10);
        assert!((eval.eval("{cos(pi)}").unwrap() + 1.0).abs() < 1e-10);
    }

    #[test]
    fn test_expr_eval_abs() {
        let eval = ExprEval::new();
        assert!((eval.eval("{abs(-5.0)}").unwrap() - 5.0).abs() < 1e-10);
        assert!((eval.eval("{abs(3.0)}").unwrap() - 3.0).abs() < 1e-10);
    }

    #[test]
    fn test_expr_eval_chained_params() {
        let mut eval = ExprEval::new();
        eval.set_var("a", 2.0);
        eval.set_var("b", 3.0);
        let result = eval.eval("{a * b + a}").unwrap();
        assert!((result - 8.0).abs() < 1e-10, "2*3+2=8, got {result}");
    }

    #[test]
    fn test_expr_eval_case_insensitive_params() {
        let mut eval = ExprEval::new();
        eval.set_var("Vdd", 3.3);
        let result = eval.eval("{VDD / 2}").unwrap();
        assert!((result - 1.65).abs() < 1e-10, "VDD/2=1.65, got {result}");
    }

    #[test]
    fn test_expr_eval_si_suffixes() {
        let eval = ExprEval::new();
        assert!((eval.eval("{1k}").unwrap() - 1000.0).abs() < 1.0);
        assert!((eval.eval("{1u}").unwrap() - 1e-6).abs() < 1e-12);
        assert!((eval.eval("{1n}").unwrap() - 1e-9).abs() < 1e-15);
    }

    #[test]
    fn test_expr_eval_division_by_zero() {
        let eval = ExprEval::new();
        let result = eval.eval("{1.0 / 0.0}");
        assert!(result.is_err(), "should error on division by zero");
    }

    #[test]
    fn test_topo_sort_simple_chain() {
        use crate::topo_sort_params;
        // b depends on a, c depends on b
        let params = vec![
            ("b".to_string(), "{a * 2}".to_string()),
            ("c".to_string(), "{b + 1}".to_string()),
            ("a".to_string(), "5.0".to_string()),
        ];
        let order = topo_sort_params(&params).unwrap();
        // a must come before b, b must come before c
        let pos_a = order.iter().position(|&i| i == 2).unwrap();
        let pos_b = order.iter().position(|&i| i == 0).unwrap();
        let pos_c = order.iter().position(|&i| i == 1).unwrap();
        assert!(pos_a < pos_b, "a must be evaluated before b");
        assert!(pos_b < pos_c, "b must be evaluated before c");
    }

    // --- BehavioralExpr eval tests ---

    fn bop(op: BinOp, l: BehavioralExpr, r: BehavioralExpr) -> BehavioralExpr {
        BehavioralExpr::BinOp(op, Box::new(l), Box::new(r))
    }

    #[test]
    fn behavioral_lit_evaluates_to_constant() {
        let e = lit(3.14);
        assert!((e.eval(&[], &[]).unwrap() - 3.14).abs() < 1e-12);
    }

    #[test]
    fn behavioral_neg_negates_value() {
        let e = BehavioralExpr::Neg(Box::new(lit(5.0)));
        assert!((e.eval(&[], &[]).unwrap() + 5.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_add_sums_literals() {
        let e = bop(BinOp::Add, lit(2.0), lit(3.0));
        assert!((e.eval(&[], &[]).unwrap() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_sub_differences_literals() {
        let e = bop(BinOp::Sub, lit(10.0), lit(4.0));
        assert!((e.eval(&[], &[]).unwrap() - 6.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_mul_multiplies_literals() {
        let e = bop(BinOp::Mul, lit(3.0), lit(4.0));
        assert!((e.eval(&[], &[]).unwrap() - 12.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_div_divides_literals() {
        let e = bop(BinOp::Div, lit(10.0), lit(2.0));
        assert!((e.eval(&[], &[]).unwrap() - 5.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_div_by_zero_returns_error() {
        let e = bop(BinOp::Div, lit(1.0), lit(0.0));
        assert!(e.eval(&[], &[]).is_err());
    }

    #[test]
    fn behavioral_pow_raises_to_power() {
        let e = bop(BinOp::Pow, lit(2.0), lit(8.0));
        assert!((e.eval(&[], &[]).unwrap() - 256.0).abs() < 1e-8);
    }

    #[test]
    fn behavioral_node_voltage_resolved() {
        let e = nv("out");
        let result = e.eval(&[("out", 1.5)], &[]).unwrap();
        assert!((result - 1.5).abs() < 1e-12);
    }

    #[test]
    fn behavioral_node_voltage_missing_returns_error() {
        let e = nv("missing");
        assert!(e.eval(&[], &[]).is_err());
    }

    #[test]
    fn behavioral_param_resolved() {
        let e = BehavioralExpr::Param("vdd".into());
        let result = e.eval(&[], &[("vdd", 3.3)]).unwrap();
        assert!((result - 3.3).abs() < 1e-12);
    }

    #[test]
    fn behavioral_param_missing_returns_error() {
        let e = BehavioralExpr::Param("missing".into());
        assert!(e.eval(&[], &[]).is_err());
    }

    #[test]
    fn behavioral_func_sqrt_evaluates() {
        let e = BehavioralExpr::Func("sqrt".into(), vec![lit(9.0)]);
        assert!((e.eval(&[], &[]).unwrap() - 3.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_func_exp_evaluates() {
        let e = BehavioralExpr::Func("exp".into(), vec![lit(0.0)]);
        assert!((e.eval(&[], &[]).unwrap() - 1.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_func_abs_evaluates() {
        let e = BehavioralExpr::Func("abs".into(), vec![lit(-7.0)]);
        assert!((e.eval(&[], &[]).unwrap() - 7.0).abs() < 1e-12);
    }

    #[test]
    fn behavioral_func_unknown_returns_error() {
        let e = BehavioralExpr::Func("nonexistent_func".into(), vec![lit(1.0)]);
        assert!(e.eval(&[], &[]).is_err());
    }

    #[test]
    fn differentiate_lit_gives_zero() {
        let e = lit(42.0);
        let d = e.differentiate("n");
        assert_eq!(d, BehavioralExpr::Lit(0.0));
    }

    #[test]
    fn differentiate_node_voltage_same_node_gives_one() {
        let e = nv("n");
        let d = e.differentiate("n");
        assert_eq!(d, BehavioralExpr::Lit(1.0));
    }

    #[test]
    fn differentiate_node_voltage_different_node_gives_zero() {
        let e = nv("m");
        let d = e.differentiate("n");
        assert_eq!(d, BehavioralExpr::Lit(0.0));
    }

    #[test]
    fn differentiate_param_gives_zero() {
        let e = BehavioralExpr::Param("vdd".into());
        let d = e.differentiate("n");
        assert_eq!(d, BehavioralExpr::Lit(0.0));
    }

    #[test]
    fn collect_node_refs_finds_all_nodes() {
        // V(a) * V(b) + V(a)  → should find [a, b] (deduped)
        let e = bop(
            BinOp::Add,
            bop(BinOp::Mul, nv("a"), nv("b")),
            nv("a"),
        );
        let mut refs = Vec::new();
        e.collect_node_refs(&mut refs);
        assert!(refs.contains(&"a".to_string()));
        assert!(refs.contains(&"b".to_string()));
        assert_eq!(refs.len(), 2, "should deduplicate a");
    }

    #[test]
    fn behavioral_binop_clone_and_equality() {
        let e1 = bop(BinOp::Add, lit(1.0), lit(2.0));
        let e2 = e1.clone();
        assert_eq!(e1, e2);
    }

    // --- ExprEval tests ---

    #[test]
    fn expr_eval_literal_no_suffix() {
        let eval = ExprEval::new();
        let v = eval.eval("42.0").unwrap();
        assert!((v - 42.0).abs() < 1e-10);
    }

    #[test]
    fn expr_eval_negative_literal() {
        let eval = ExprEval::new();
        let v = eval.eval("-7.5").unwrap();
        assert!((v + 7.5).abs() < 1e-10);
    }

    #[test]
    fn expr_eval_addition_and_subtraction() {
        let eval = ExprEval::new();
        assert!((eval.eval("10 - 3 + 2").unwrap() - 9.0).abs() < 1e-10);
    }

    #[test]
    fn expr_eval_multiplication_precedence() {
        let eval = ExprEval::new();
        // 2 + 3 * 4 = 14, not 20
        assert!((eval.eval("2 + 3 * 4").unwrap() - 14.0).abs() < 1e-10);
    }

    #[test]
    fn expr_eval_parentheses_override_precedence() {
        let eval = ExprEval::new();
        assert!((eval.eval("(2 + 3) * 4").unwrap() - 20.0).abs() < 1e-10);
    }

    #[test]
    fn expr_eval_get_var_returns_none_for_missing() {
        let eval = ExprEval::new();
        assert!(eval.get_var("undefined").is_none());
    }

    #[test]
    fn expr_eval_set_and_get_var() {
        let mut eval = ExprEval::new();
        eval.set_var("x", 99.0);
        assert_eq!(eval.get_var("x"), Some(99.0));
        assert_eq!(eval.get_var("X"), Some(99.0), "lookup must be case-insensitive");
    }

    #[test]
    fn expr_eval_braces_stripped() {
        let eval = ExprEval::new();
        let v = eval.eval("{5.0 + 3.0}").unwrap();
        assert!((v - 8.0).abs() < 1e-10);
    }

    #[test]
    fn expr_eval_log_function() {
        let eval = ExprEval::new();
        let v = eval.eval("{log(1.0)}").unwrap();
        assert!(v.abs() < 1e-10, "ln(1)=0, got {v}");
    }

    #[test]
    fn expr_eval_exp_function() {
        let eval = ExprEval::new();
        let v = eval.eval("{exp(0.0)}").unwrap();
        assert!((v - 1.0).abs() < 1e-10, "exp(0)=1, got {v}");
    }
}
