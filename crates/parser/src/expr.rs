use ahash::AHashMap;
use pisim_core::SimError;

use crate::token::Token;

/// Binary operators supported in SPICE parameter expressions.
#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
    Pow,
}

/// An expression tree for `.PARAM` expressions and B-source behavioral expressions.
#[derive(Debug, Clone, PartialEq)]
pub enum Expression {
    /// A literal numeric value.
    Literal(f64),
    /// A reference to a named parameter.
    Param(String),
    /// A binary operation: `lhs op rhs`.
    BinOp(Op, Box<Expression>, Box<Expression>),
    /// Unary negation.
    UnaryMinus(Box<Expression>),
    /// A function call: `sqrt(x)`, `abs(x)`, etc.
    Func(String, Vec<Expression>),
    /// Node voltage reference `V(node)` or differential `V(n1,n2)`.
    ///
    /// Stored as a node-name string (or "n1,n2" for differential).
    /// During B-source evaluation these are resolved to voltages from the
    /// simulator state via the `refs` index table.
    NodeVoltage(String),
}

impl Expression {
    /// Symbolically differentiate `self` with respect to the node voltage
    /// referenced by `var` (the node name string used in `NodeVoltage`).
    ///
    /// Returns a new `Expression` representing `d(self)/dV(var)`.
    pub fn differentiate(&self, var: &str) -> Expression {
        match self {
            Expression::Literal(_) => Expression::Literal(0.0),
            Expression::Param(_) => Expression::Literal(0.0),
            Expression::NodeVoltage(node) => {
                if node == var {
                    Expression::Literal(1.0)
                } else {
                    Expression::Literal(0.0)
                }
            }
            Expression::UnaryMinus(inner) => {
                Expression::UnaryMinus(Box::new(inner.differentiate(var)))
            }
            Expression::BinOp(op, lhs, rhs) => {
                let dl = lhs.differentiate(var);
                let dr = rhs.differentiate(var);
                match op {
                    Op::Add => Expression::BinOp(Op::Add, Box::new(dl), Box::new(dr)),
                    Op::Sub => Expression::BinOp(Op::Sub, Box::new(dl), Box::new(dr)),
                    // Product rule: d(u*v) = du*v + u*dv
                    Op::Mul => Expression::BinOp(
                        Op::Add,
                        Box::new(Expression::BinOp(Op::Mul, Box::new(dl), rhs.clone())),
                        Box::new(Expression::BinOp(Op::Mul, lhs.clone(), Box::new(dr))),
                    ),
                    // Quotient rule: d(u/v) = (du*v - u*dv) / v^2
                    Op::Div => Expression::BinOp(
                        Op::Div,
                        Box::new(Expression::BinOp(
                            Op::Sub,
                            Box::new(Expression::BinOp(Op::Mul, Box::new(dl), rhs.clone())),
                            Box::new(Expression::BinOp(Op::Mul, lhs.clone(), Box::new(dr))),
                        )),
                        Box::new(Expression::BinOp(
                            Op::Pow,
                            rhs.clone(),
                            Box::new(Expression::Literal(2.0)),
                        )),
                    ),
                    // d(u^v) where v is constant wrt var: v * u^(v-1) * du/dvar
                    // General case (both may depend on var) is complex; for now handle
                    // the common case where exponent is constant.
                    Op::Pow => {
                        // d(u^n) = n * u^(n-1) * du
                        Expression::BinOp(
                            Op::Mul,
                            Box::new(Expression::BinOp(
                                Op::Mul,
                                rhs.clone(),
                                Box::new(Expression::BinOp(
                                    Op::Pow,
                                    lhs.clone(),
                                    Box::new(Expression::BinOp(
                                        Op::Sub,
                                        rhs.clone(),
                                        Box::new(Expression::Literal(1.0)),
                                    )),
                                )),
                            )),
                            Box::new(dl),
                        )
                    }
                }
            }
            Expression::Func(name, args) => {
                // Chain rule for known functions with one argument.
                match (name.as_str(), args.as_slice()) {
                    ("sqrt", [u]) => {
                        // d(sqrt(u)) = du / (2 * sqrt(u))
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Div,
                            Box::new(du),
                            Box::new(Expression::BinOp(
                                Op::Mul,
                                Box::new(Expression::Literal(2.0)),
                                Box::new(Expression::Func("sqrt".into(), vec![u.clone()])),
                            )),
                        )
                    }
                    ("abs", [u]) => {
                        // d(abs(u)) = sign(u) * du  — approximate; zero at origin
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Mul,
                            Box::new(Expression::Func("sign".into(), vec![u.clone()])),
                            Box::new(du),
                        )
                    }
                    ("exp", [u]) => {
                        // d(exp(u)) = exp(u) * du
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Mul,
                            Box::new(Expression::Func("exp".into(), vec![u.clone()])),
                            Box::new(du),
                        )
                    }
                    ("log" | "ln", [u]) => {
                        // d(ln(u)) = du / u
                        let du = u.differentiate(var);
                        Expression::BinOp(Op::Div, Box::new(du), Box::new(u.clone()))
                    }
                    ("log10", [u]) => {
                        // d(log10(u)) = du / (u * ln(10))
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Div,
                            Box::new(du),
                            Box::new(Expression::BinOp(
                                Op::Mul,
                                Box::new(u.clone()),
                                Box::new(Expression::Literal(std::f64::consts::LN_10)),
                            )),
                        )
                    }
                    ("sin", [u]) => {
                        // d(sin(u)) = cos(u) * du
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Mul,
                            Box::new(Expression::Func("cos".into(), vec![u.clone()])),
                            Box::new(du),
                        )
                    }
                    ("cos", [u]) => {
                        // d(cos(u)) = -sin(u) * du
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Mul,
                            Box::new(Expression::UnaryMinus(Box::new(Expression::Func(
                                "sin".into(),
                                vec![u.clone()],
                            )))),
                            Box::new(du),
                        )
                    }
                    ("pow", [u, n]) => {
                        // d(u^n) = n * u^(n-1) * du  (n treated as potentially variable)
                        let du = u.differentiate(var);
                        Expression::BinOp(
                            Op::Mul,
                            Box::new(Expression::BinOp(
                                Op::Mul,
                                Box::new(n.clone()),
                                Box::new(Expression::BinOp(
                                    Op::Pow,
                                    Box::new(u.clone()),
                                    Box::new(Expression::BinOp(
                                        Op::Sub,
                                        Box::new(n.clone()),
                                        Box::new(Expression::Literal(1.0)),
                                    )),
                                )),
                            )),
                            Box::new(du),
                        )
                    }
                    ("min" | "max", _) => {
                        // Not differentiable cleanly — return 0; caller can use FD instead.
                        Expression::Literal(0.0)
                    }
                    _ => Expression::Literal(0.0),
                }
            }
        }
    }

    /// Collect the names of all `NodeVoltage(name)` leaves in this expression.
    pub fn collect_node_refs(&self, out: &mut Vec<String>) {
        match self {
            Expression::NodeVoltage(n) => {
                if !out.contains(n) {
                    out.push(n.clone());
                }
            }
            Expression::BinOp(_, l, r) => {
                l.collect_node_refs(out);
                r.collect_node_refs(out);
            }
            Expression::UnaryMinus(inner) => inner.collect_node_refs(out),
            Expression::Func(_, args) => args.iter().for_each(|a| a.collect_node_refs(out)),
            _ => {}
        }
    }
}

/// Recursive-descent expression parser operating on a slice of tokens.
struct ExprParser<'a> {
    tokens: &'a [Token],
    pos: usize,
}

impl<'a> ExprParser<'a> {
    fn new(tokens: &'a [Token]) -> Self {
        Self { tokens, pos: 0 }
    }

    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.pos)
    }

    fn advance(&mut self) -> Option<&Token> {
        let tok = self.tokens.get(self.pos)?;
        self.pos += 1;
        Some(tok)
    }

    /// Parse an expression (entry point): handles addition and subtraction.
    fn parse_expr(&mut self) -> Result<Expression, SimError> {
        let mut left = self.parse_term()?;
        loop {
            match self.peek() {
                Some(Token::Plus) => {
                    self.advance();
                    let right = self.parse_term()?;
                    left = Expression::BinOp(Op::Add, Box::new(left), Box::new(right));
                }
                Some(Token::Minus) => {
                    self.advance();
                    let right = self.parse_term()?;
                    left = Expression::BinOp(Op::Sub, Box::new(left), Box::new(right));
                }
                _ => break,
            }
        }
        Ok(left)
    }

    /// Parse a term: handles multiplication and division.
    fn parse_term(&mut self) -> Result<Expression, SimError> {
        let mut left = self.parse_unary()?;
        loop {
            match self.peek() {
                Some(Token::Star) => {
                    self.advance();
                    // Check for '**' (power) — two consecutive stars.
                    if self.peek() == Some(&Token::Star) {
                        self.advance();
                        let right = self.parse_unary()?;
                        left = Expression::BinOp(Op::Pow, Box::new(left), Box::new(right));
                    } else {
                        let right = self.parse_unary()?;
                        left = Expression::BinOp(Op::Mul, Box::new(left), Box::new(right));
                    }
                }
                Some(Token::Slash) => {
                    self.advance();
                    let right = self.parse_unary()?;
                    left = Expression::BinOp(Op::Div, Box::new(left), Box::new(right));
                }
                _ => break,
            }
        }
        Ok(left)
    }

    /// Parse unary minus.
    fn parse_unary(&mut self) -> Result<Expression, SimError> {
        if self.peek() == Some(&Token::Minus) {
            self.advance();
            let inner = self.parse_unary()?;
            return Ok(Expression::UnaryMinus(Box::new(inner)));
        }
        if self.peek() == Some(&Token::Plus) {
            self.advance();
            return self.parse_unary();
        }
        self.parse_primary()
    }

    /// Parse primary: number, parameter, function call, or parenthesized expression.
    fn parse_primary(&mut self) -> Result<Expression, SimError> {
        match self.peek().cloned() {
            Some(Token::Number(n)) => {
                self.advance();
                Ok(Expression::Literal(n))
            }
            Some(Token::Word(name)) => {
                self.advance();
                // Check if it's a function call.
                if self.peek() == Some(&Token::LeftParen) {
                    self.advance(); // consume '('

                    // Special case: V(node) or V(n1,n2) → NodeVoltage
                    if name == "v" {
                        let node1 = match self.peek().cloned() {
                            Some(Token::Word(n)) => { self.advance(); n }
                            Some(Token::Number(n)) => {
                                self.advance();
                                // Integer node names like 0, 1, 2
                                if n == (n as u64) as f64 && n >= 0.0 {
                                    format!("{}", n as u64)
                                } else {
                                    format!("{n}")
                                }
                            }
                            other => return Err(SimError::Parse(format!(
                                "expected node name inside V(...), got {other:?}"
                            ))),
                        };
                        if self.peek() == Some(&Token::Comma) {
                            self.advance(); // consume ','
                            let node2 = match self.peek().cloned() {
                                Some(Token::Word(n)) => { self.advance(); n }
                                Some(Token::Number(n)) => {
                                    self.advance();
                                    if n == (n as u64) as f64 && n >= 0.0 {
                                        format!("{}", n as u64)
                                    } else {
                                        format!("{n}")
                                    }
                                }
                                other => return Err(SimError::Parse(format!(
                                    "expected second node name in V(n1,n2), got {other:?}"
                                ))),
                            };
                            if self.peek() == Some(&Token::RightParen) {
                                self.advance();
                            } else {
                                return Err(SimError::Parse("expected ')' after V(n1,n2)".into()));
                            }
                            // V(n1,n2) = V(n1) - V(n2)
                            return Ok(Expression::BinOp(
                                Op::Sub,
                                Box::new(Expression::NodeVoltage(node1)),
                                Box::new(Expression::NodeVoltage(node2)),
                            ));
                        } else {
                            if self.peek() == Some(&Token::RightParen) {
                                self.advance();
                            } else {
                                return Err(SimError::Parse("expected ')' after V(node)".into()));
                            }
                            return Ok(Expression::NodeVoltage(node1));
                        }
                    }

                    let mut args = Vec::new();
                    if self.peek() != Some(&Token::RightParen) {
                        args.push(self.parse_expr()?);
                        while self.peek() == Some(&Token::Comma) {
                            self.advance();
                            args.push(self.parse_expr()?);
                        }
                    }
                    if self.peek() == Some(&Token::RightParen) {
                        self.advance();
                    } else {
                        return Err(SimError::Parse(
                            "expected ')' in function call".into(),
                        ));
                    }
                    Ok(Expression::Func(name, args))
                } else {
                    Ok(Expression::Param(name))
                }
            }
            Some(Token::LeftParen) => {
                self.advance();
                let inner = self.parse_expr()?;
                if self.peek() == Some(&Token::RightParen) {
                    self.advance();
                } else {
                    return Err(SimError::Parse("expected ')'".into()));
                }
                Ok(inner)
            }
            Some(other) => Err(SimError::Parse(format!(
                "unexpected token in expression: {other}"
            ))),
            None => Err(SimError::Parse("unexpected end of expression".into())),
        }
    }
}

/// Parse a token slice into an expression tree.
pub fn parse_expression(tokens: &[Token]) -> Result<Expression, SimError> {
    let mut parser = ExprParser::new(tokens);
    let expr = parser.parse_expr()?;
    // Ensure all tokens were consumed (ignoring Eof/Newline/RightBrace).
    while parser.pos < parser.tokens.len() {
        match &parser.tokens[parser.pos] {
            Token::Eof | Token::Newline | Token::RightBrace => {
                parser.pos += 1;
            }
            other => {
                return Err(SimError::Parse(format!(
                    "unexpected token after expression: {other}"
                )));
            }
        }
    }
    Ok(expr)
}

/// Parse a brace-enclosed behavioral expression `{expr}` from a token slice.
///
/// The slice must start with `LeftBrace`. Consumes tokens up to and including
/// the matching `RightBrace` and returns `(expr, tokens_consumed)`.
pub fn parse_brace_expression(tokens: &[Token]) -> Result<(Expression, usize), SimError> {
    if tokens.is_empty() || tokens[0] != Token::LeftBrace {
        return Err(SimError::Parse(
            "expected '{' to start brace expression".into(),
        ));
    }

    // Find the matching closing brace (depth-aware).
    let mut depth = 0usize;
    let mut end = 0;
    for (i, tok) in tokens.iter().enumerate() {
        match tok {
            Token::LeftBrace => depth += 1,
            Token::RightBrace => {
                depth -= 1;
                if depth == 0 {
                    end = i;
                    break;
                }
            }
            _ => {}
        }
    }
    if depth != 0 {
        return Err(SimError::Parse("unmatched '{' in brace expression".into()));
    }

    // Parse the tokens between the braces (exclusive).
    let inner = &tokens[1..end];
    let expr = parse_expression(inner)?;
    Ok((expr, end + 1)) // +1 to include the closing '}'
}

/// Evaluate an expression tree given a parameter environment.
///
/// `params` may contain both named `.PARAM` values and node-voltage entries
/// stored under the key used by `NodeVoltage` (e.g. `"2"` for `V(2)`).
pub fn eval_expression(
    expr: &Expression,
    params: &AHashMap<String, f64>,
) -> Result<f64, SimError> {
    match expr {
        Expression::Literal(v) => Ok(*v),
        Expression::Param(name) => params.get(name.as_str()).copied().ok_or_else(|| {
            SimError::Parse(format!("undefined parameter '{name}'"))
        }),
        Expression::NodeVoltage(node) => params.get(node.as_str()).copied().ok_or_else(|| {
            SimError::Parse(format!("node voltage V({node}) not available in expression context"))
        }),
        Expression::UnaryMinus(inner) => {
            let v = eval_expression(inner, params)?;
            Ok(-v)
        }
        Expression::BinOp(op, lhs, rhs) => {
            let l = eval_expression(lhs, params)?;
            let r = eval_expression(rhs, params)?;
            match op {
                Op::Add => Ok(l + r),
                Op::Sub => Ok(l - r),
                Op::Mul => Ok(l * r),
                Op::Div => {
                    if r == 0.0 {
                        Err(SimError::Parse("division by zero".into()))
                    } else {
                        Ok(l / r)
                    }
                }
                Op::Pow => Ok(l.powf(r)),
            }
        }
        Expression::Func(name, args) => {
            let evaluated: Vec<f64> = args
                .iter()
                .map(|a| eval_expression(a, params))
                .collect::<Result<_, _>>()?;
            match name.as_str() {
                "sqrt" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].sqrt())
                }
                "abs" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].abs())
                }
                "exp" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].exp())
                }
                "log" | "ln" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].ln())
                }
                "log10" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].log10())
                }
                "sin" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].sin())
                }
                "cos" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].cos())
                }
                "pow" => {
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].powf(evaluated[1]))
                }
                "min" => {
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].min(evaluated[1]))
                }
                "max" => {
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].max(evaluated[1]))
                }
                "sign" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].signum())
                }
                "tan" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].tan())
                }
                "asin" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].asin())
                }
                "acos" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].acos())
                }
                "atan" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].atan())
                }
                "atan2" => {
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].atan2(evaluated[1]))
                }
                "if" => {
                    // if(cond, then_val, else_val)
                    check_arity(name, &evaluated, 3)?;
                    Ok(if evaluated[0] != 0.0 { evaluated[1] } else { evaluated[2] })
                }
                // --- Rounding / integer ---
                "ceil" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].ceil())
                }
                "floor" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].floor())
                }
                "round" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].round())
                }
                "int" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].trunc())
                }
                "nint" => {
                    // nearest integer — same as round
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].round())
                }
                // --- Decibel ---
                "db" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(20.0 * evaluated[0].abs().log10())
                }
                // --- Step / ramp ---
                "uramp" => {
                    // unit ramp: max(x, 0)
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].max(0.0))
                }
                "u" => {
                    // unit step: 1 if x >= 0, else 0
                    check_arity(name, &evaluated, 1)?;
                    Ok(if evaluated[0] >= 0.0 { 1.0 } else { 0.0 })
                }
                // --- Power (HSPICE B-source) ---
                "pwr" => {
                    // pwr(x, y) = abs(x)^y
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].abs().powf(evaluated[1]))
                }
                "pwrs" => {
                    // pwrs(x, y) = sign(x) * abs(x)^y
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].signum() * evaluated[0].abs().powf(evaluated[1]))
                }
                // --- Hyperbolic ---
                "cosh" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].cosh())
                }
                "sinh" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].sinh())
                }
                "tanh" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].tanh())
                }
                "acosh" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].acosh())
                }
                "asinh" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].asinh())
                }
                "atanh" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].atanh())
                }
                // --- Log ---
                "log2" => {
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0].log2())
                }
                // --- Geometry ---
                "hypot" => {
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0].hypot(evaluated[1]))
                }
                // --- Sign alias ---
                "sgn" => {
                    // alias for sign(x): +1, -1, or 0
                    check_arity(name, &evaluated, 1)?;
                    let x = evaluated[0];
                    Ok(if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 })
                }
                // --- Clamp ---
                "limit" => {
                    // limit(x, min, max) — deterministic clamp
                    check_arity(name, &evaluated, 3)?;
                    Ok(evaluated[0].clamp(evaluated[1], evaluated[2]))
                }
                // --- Statistical (stochastic; use thread-local PRNG) ---
                "gauss" => {
                    // gauss(sigma): Gaussian with mean=0, std=sigma
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0] * sample_normal())
                }
                "agauss" => {
                    // agauss(mu, sigma): Gaussian with given mean and std
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0] + evaluated[1] * sample_normal())
                }
                "unif" => {
                    // unif(range): uniform in [-range, range]
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0] * sample_uniform_signed())
                }
                "aunif" => {
                    // aunif(mu, range): uniform in [mu-range, mu+range]
                    check_arity(name, &evaluated, 2)?;
                    Ok(evaluated[0] + evaluated[1] * sample_uniform_signed())
                }
                "flat" => {
                    // flat(range): alias for unif(range)
                    check_arity(name, &evaluated, 1)?;
                    Ok(evaluated[0] * sample_uniform_signed())
                }
                // HSPICE OPTVAL(init, lower, upper) — returns init for normal simulation;
                // bounds are stored in ParsedNetlist.optimize_params by the parser.
                "optval" => {
                    if evaluated.len() < 1 {
                        return Err(SimError::Parse(
                            "optval() requires at least 1 argument (init)".into(),
                        ));
                    }
                    Ok(evaluated[0]) // use init value
                }
                _ => Err(SimError::Parse(format!(
                    "unknown function '{name}'"
                ))),
            }
        }
    }
}

/// Sample a standard-normal value using Box-Muller transform with a thread-local xorshift PRNG.
/// Used by the statistical expression functions (gauss, agauss, etc.) in general expression
/// evaluation contexts outside the Monte Carlo driver.
fn sample_normal() -> f64 {
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

/// Sample a uniform value in [-1, 1) using a thread-local xorshift PRNG.
fn sample_uniform_signed() -> f64 {
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

fn check_arity(name: &str, args: &[f64], expected: usize) -> Result<(), SimError> {
    if args.len() != expected {
        Err(SimError::Parse(format!(
            "function '{name}' expects {expected} argument(s), got {}",
            args.len()
        )))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexer::Lexer;

    /// Helper: tokenize an expression string (without newline/eof concerns).
    fn tokenize_expr(s: &str) -> Vec<Token> {
        let mut lex = Lexer::new(s);
        let mut tokens = lex.tokenize_all().unwrap();
        // Remove trailing Newline/Eof for expression parsing.
        tokens.retain(|t| !matches!(t, Token::Newline | Token::Eof));
        tokens
    }

    #[test]
    fn eval_literal() {
        let tokens = tokenize_expr("42");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 42.0);
    }

    #[test]
    fn eval_addition() {
        let tokens = tokenize_expr("1000 + 2000");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 3000.0);
    }

    #[test]
    fn eval_si_addition() {
        // "1k + 2k" — the lexer resolves SI suffixes, so tokens are Number(1000) + Number(2000).
        let tokens = tokenize_expr("1k + 2k");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 3000.0);
    }

    #[test]
    fn eval_multiplication() {
        let tokens = tokenize_expr("3 * 4");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 12.0);
    }

    #[test]
    fn eval_precedence() {
        // 2 + 3 * 4 = 14
        let tokens = tokenize_expr("2 + 3 * 4");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 14.0);
    }

    #[test]
    fn eval_parentheses() {
        // (2 + 3) * 4 = 20
        let tokens = tokenize_expr("(2 + 3) * 4");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 20.0);
    }

    #[test]
    fn eval_unary_minus() {
        let tokens = tokenize_expr("-5");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), -5.0);
    }

    #[test]
    fn eval_sqrt() {
        let tokens = tokenize_expr("sqrt(4)");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 2.0);
    }

    #[test]
    fn eval_abs() {
        let tokens = tokenize_expr("abs(-3)");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 3.0);
    }

    #[test]
    fn eval_exp_and_log() {
        let tokens = tokenize_expr("log(exp(1))");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        let result = eval_expression(&expr, &params).unwrap();
        assert!((result - 1.0).abs() < 1e-10);
    }

    #[test]
    fn eval_sin_cos() {
        let tokens = tokenize_expr("sin(0)");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert!((eval_expression(&expr, &params).unwrap()).abs() < 1e-10);

        let tokens = tokenize_expr("cos(0)");
        let expr = parse_expression(&tokens).unwrap();
        assert!((eval_expression(&expr, &params).unwrap() - 1.0).abs() < 1e-10);
    }

    #[test]
    fn eval_param_substitution() {
        let tokens = tokenize_expr("vdd * 2");
        let expr = parse_expression(&tokens).unwrap();
        let mut params = AHashMap::new();
        params.insert("vdd".to_string(), 3.3);
        assert_eq!(eval_expression(&expr, &params).unwrap(), 6.6);
    }

    #[test]
    fn eval_complex_expression() {
        // sqrt(r1 * r2)
        let tokens = tokenize_expr("sqrt(100 * 400)");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 200.0);
    }

    #[test]
    fn eval_division_by_zero() {
        let tokens = tokenize_expr("1 / 0");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert!(eval_expression(&expr, &params).is_err());
    }

    #[test]
    fn eval_undefined_param() {
        let tokens = tokenize_expr("missing");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert!(eval_expression(&expr, &params).is_err());
    }

    #[test]
    fn eval_nested_functions() {
        // abs(sqrt(16) - 5) = abs(4 - 5) = 1
        let tokens = tokenize_expr("abs(sqrt(16) - 5)");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 1.0);
    }

    #[test]
    fn eval_power_via_stars() {
        // 2 ** 3 = 8 — tokenized as Star, Star which parse_term handles.
        let tokens = tokenize_expr("2 ** 3");
        let expr = parse_expression(&tokens).unwrap();
        let params = AHashMap::new();
        assert_eq!(eval_expression(&expr, &params).unwrap(), 8.0);
    }

    // --- Tests for new functions ---

    fn eval(s: &str) -> f64 {
        let tokens = tokenize_expr(s);
        let expr = parse_expression(&tokens).unwrap();
        eval_expression(&expr, &AHashMap::new()).unwrap()
    }

    #[test]
    fn eval_ceil() {
        assert_eq!(eval("ceil(1.2)"), 2.0);
        assert_eq!(eval("ceil(-1.2)"), -1.0);
        assert_eq!(eval("ceil(3.0)"), 3.0);
    }

    #[test]
    fn eval_floor() {
        assert_eq!(eval("floor(1.9)"), 1.0);
        assert_eq!(eval("floor(-1.1)"), -2.0);
    }

    #[test]
    fn eval_round() {
        assert_eq!(eval("round(1.5)"), 2.0);
        assert_eq!(eval("round(1.4)"), 1.0);
        assert_eq!(eval("round(-1.5)"), -2.0);
    }

    #[test]
    fn eval_int_trunc() {
        assert_eq!(eval("int(3.9)"), 3.0);
        assert_eq!(eval("int(-3.9)"), -3.0);
    }

    #[test]
    fn eval_nint() {
        assert_eq!(eval("nint(2.6)"), 3.0);
        assert_eq!(eval("nint(2.4)"), 2.0);
    }

    #[test]
    fn eval_db() {
        // db(1) = 20 * log10(1) = 0
        assert!((eval("db(1)")).abs() < 1e-10);
        // db(10) = 20 * log10(10) = 20
        assert!((eval("db(10)") - 20.0).abs() < 1e-10);
        // db accepts negative input via abs
        assert!((eval("db(-10)") - 20.0).abs() < 1e-10);
    }

    #[test]
    fn eval_uramp() {
        assert_eq!(eval("uramp(3.0)"), 3.0);
        assert_eq!(eval("uramp(-2.0)"), 0.0);
        assert_eq!(eval("uramp(0)"), 0.0);
    }

    #[test]
    fn eval_u_step() {
        assert_eq!(eval("u(1)"), 1.0);
        assert_eq!(eval("u(0)"), 1.0);
        assert_eq!(eval("u(-1)"), 0.0);
    }

    #[test]
    fn eval_pwr() {
        // pwr(-2, 3) = abs(-2)^3 = 8
        assert_eq!(eval("pwr(-2, 3)"), 8.0);
        assert_eq!(eval("pwr(2, 3)"), 8.0);
    }

    #[test]
    fn eval_pwrs() {
        // pwrs(-2, 3) = sign(-2) * abs(-2)^3 = -8
        assert_eq!(eval("pwrs(-2, 3)"), -8.0);
        assert_eq!(eval("pwrs(2, 3)"), 8.0);
    }

    #[test]
    fn eval_hyperbolic() {
        assert!((eval("cosh(0)") - 1.0).abs() < 1e-12);
        assert!((eval("sinh(0)")).abs() < 1e-12);
        assert!((eval("tanh(0)")).abs() < 1e-12);
    }

    #[test]
    fn eval_inverse_hyperbolic() {
        // asinh(sinh(1)) = 1
        assert!((eval("asinh(1)") - 1.0_f64.asinh()).abs() < 1e-12);
        assert!((eval("acosh(1)")).abs() < 1e-12);
        assert!((eval("atanh(0)")).abs() < 1e-12);
    }

    #[test]
    fn eval_log2() {
        assert!((eval("log2(8)") - 3.0).abs() < 1e-12);
        assert!((eval("log2(1)")).abs() < 1e-12);
    }

    #[test]
    fn eval_hypot() {
        // hypot(3, 4) = 5
        assert!((eval("hypot(3, 4)") - 5.0).abs() < 1e-12);
    }

    #[test]
    fn eval_sgn() {
        assert_eq!(eval("sgn(5)"), 1.0);
        assert_eq!(eval("sgn(-3)"), -1.0);
        assert_eq!(eval("sgn(0)"), 0.0);
    }

    #[test]
    fn eval_limit_clamp() {
        assert_eq!(eval("limit(5, 0, 10)"), 5.0);
        assert_eq!(eval("limit(-1, 0, 10)"), 0.0);
        assert_eq!(eval("limit(15, 0, 10)"), 10.0);
    }

    #[test]
    fn eval_gauss_returns_f64() {
        // gauss(sigma): just verify it returns a finite value — it's stochastic
        let tokens = tokenize_expr("gauss(1)");
        let expr = parse_expression(&tokens).unwrap();
        let result = eval_expression(&expr, &AHashMap::new()).unwrap();
        assert!(result.is_finite());
    }

    #[test]
    fn eval_agauss_returns_f64() {
        let tokens = tokenize_expr("agauss(5, 1)");
        let expr = parse_expression(&tokens).unwrap();
        let result = eval_expression(&expr, &AHashMap::new()).unwrap();
        assert!(result.is_finite());
    }

    #[test]
    fn eval_unif_in_range() {
        // unif(1) must produce a value in [-1, 1]
        for _ in 0..20 {
            let tokens = tokenize_expr("unif(1)");
            let expr = parse_expression(&tokens).unwrap();
            let v = eval_expression(&expr, &AHashMap::new()).unwrap();
            assert!(v >= -1.0 && v <= 1.0, "unif(1) = {v} out of range");
        }
    }

    #[test]
    fn eval_aunif_in_range() {
        // aunif(5, 1) must produce a value in [4, 6]
        for _ in 0..20 {
            let tokens = tokenize_expr("aunif(5, 1)");
            let expr = parse_expression(&tokens).unwrap();
            let v = eval_expression(&expr, &AHashMap::new()).unwrap();
            assert!(v >= 4.0 && v <= 6.0, "aunif(5, 1) = {v} out of range");
        }
    }

    #[test]
    fn eval_flat_in_range() {
        // flat(2) must produce a value in [-2, 2]
        for _ in 0..20 {
            let tokens = tokenize_expr("flat(2)");
            let expr = parse_expression(&tokens).unwrap();
            let v = eval_expression(&expr, &AHashMap::new()).unwrap();
            assert!(v >= -2.0 && v <= 2.0, "flat(2) = {v} out of range");
        }
    }
}
