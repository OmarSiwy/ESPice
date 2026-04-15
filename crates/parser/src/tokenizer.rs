// tokenizer.rs — byte-slice Lexer, ExprParser, and SpiceParser.
//
// Consolidates: lexer.rs, expr.rs (logic), spice.rs

use ahash::AHashMap;
use bigospice_core::{
    AcStimulus, AdcBridgeSpec, BehavioralBinOp, BehavioralExpr, BsourceExpr, Circuit, DacBridgeSpec,
    DeviceId, DeviceInstance, DeviceKind, DigitalNetSpec, DigitalPrimitiveSpec, NodeId, Si,
    SimError, Terminal,
};
use bigospice_utility::si_multiplier;
use std::path::{Path, PathBuf};

use crate::types::{
    AnalysisKind, AnalysisStatement, BinModel, BinModelEntry, ControlBlock, ControlStatement,
    CustomDistribution, DataBlock, DistoStatement, DistKind, ElementStatement, Expression,
    ExtractSpec, FftStatement, FuncDef, MeasureStatement, ModelStatement, NoiseStatement, Op,
    OptimizeParam, ParsedNetlist, PendingSubcktInstance, PrintFormat, SaveDirective,
    SaveSpec, SensOutputSpec, StepDirective, StepKind, SubcircuitDef, Token,
};

// ===========================================================================
// Expression parser functions (moved from expr.rs)
// ===========================================================================

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
                    if evaluated.is_empty() {
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

/// Shared xorshift64 PRNG — one thread-local state for all statistical sampling.
fn xorshift64_next() -> u64 {
    use std::cell::Cell;
    thread_local! {
        static STATE: Cell<u64> = Cell::new(0x9E3779B97F4A7C15u64);
    }
    STATE.with(|s| {
        let mut x = s.get();
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        s.set(x);
        x.wrapping_mul(0x2545F4914F6CDD1D)
    })
}

fn prng_unit() -> f64 {
    ((xorshift64_next() >> 11) as f64) * (1.0 / ((1u64 << 53) as f64))
}

/// Sample a standard-normal value using Box-Muller transform with a thread-local xorshift PRNG.
fn sample_normal() -> f64 {
    let mut u1 = prng_unit();
    if u1 < 1e-300 {
        u1 = 1e-300;
    }
    let u2 = prng_unit();
    let r = (-2.0 * u1.ln()).sqrt();
    let theta = 2.0 * std::f64::consts::PI * u2;
    r * theta.cos()
}

/// Sample a uniform value in [-1, 1) using a thread-local xorshift PRNG.
fn sample_uniform_signed() -> f64 {
    2.0 * prng_unit() - 1.0
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

// ===========================================================================
// Byte-slice Lexer (formerly lexer.rs, Vec<char> → Vec<u8>)
// ===========================================================================

/// Tokenizes SPICE netlist text into a stream of [`Token`]s.
///
/// Handles SPICE conventions:
/// - `*` at start of line = comment (skip entire line)
/// - `+` at start of line = continuation of previous line
/// - `;` = inline comment (skip to end of line)
/// - Case insensitive (input pre-lowercased in `new`, so no per-token lowercasing needed)
/// - SI suffixes on numbers: `1k` -> 1000.0, `100n` -> 1e-7, `2.2meg` -> 2.2e6
/// - `.directive` tokens
pub struct Lexer {
    input: Vec<u8>,
    pos: usize,
    line: usize,
    col: usize,
    /// Whether we are at the start of a logical line (for comment/continuation detection).
    at_line_start: bool,
}

impl Lexer {
    /// Create a new lexer from input text.
    /// Input is pre-lowercased so per-token `.to_lowercase()` calls are unnecessary.
    pub fn new(input: &str) -> Self {
        Self {
            input: input.to_ascii_lowercase().into_bytes(),
            pos: 0,
            line: 1,
            col: 1,
            at_line_start: true,
        }
    }

    /// Peek at the current byte without consuming it.
    fn peek(&self) -> Option<u8> {
        self.input.get(self.pos).copied()
    }

    /// Advance one byte and return it.
    fn advance(&mut self) -> Option<u8> {
        let ch = self.input.get(self.pos).copied()?;
        self.pos += 1;
        if ch == b'\n' {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        Some(ch)
    }

    /// Skip whitespace (spaces and tabs) but NOT newlines.
    fn skip_whitespace(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == b' ' || ch == b'\t' {
                self.advance();
            } else {
                break;
            }
        }
    }

    /// Skip to end of line (for comments).
    fn skip_to_eol(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == b'\n' {
                break;
            }
            self.advance();
        }
    }

    /// Read a number token, including optional SI suffix.
    ///
    /// SPICE numbers can look like: `1.5`, `1e-3`, `1k`, `100n`, `2.2meg`, `1G`.
    fn read_number(&mut self, first: u8) -> Result<Token, SimError> {
        let mut buf = String::new();
        buf.push(first as char);

        // Read digits, decimal point, exponent.
        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() || ch == b'.' {
                buf.push(ch as char);
                self.advance();
            } else if ch == b'e' || ch == b'E' {
                // Could be exponent or start of SI suffix — peek ahead.
                // If next char after 'e' is digit or +/-, it's an exponent.
                let next = self.input.get(self.pos + 1).copied();
                if next == Some(b'+') || next == Some(b'-') || next.is_some_and(|c| c.is_ascii_digit()) {
                    buf.push(ch as char);
                    self.advance();
                    // Also consume the sign if present.
                    if let Some(sign) = self.peek() {
                        if sign == b'+' || sign == b'-' {
                            buf.push(sign as char);
                            self.advance();
                        }
                    }
                } else {
                    // Not an exponent — break and handle as suffix below.
                    break;
                }
            } else {
                break;
            }
        }

        // Now try to consume an SI suffix.
        // SPICE suffixes: f, p, n, u, m, k, meg, g, t (case insensitive).
        let suffix_start = self.pos;
        let mut suffix_buf: Vec<u8> = Vec::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphabetic() {
                suffix_buf.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        if suffix_buf.is_empty() {
            // Plain number.
            let val: f64 = buf.parse().map_err(|_| {
                SimError::Parse(format!("invalid number '{}' at line {}", buf, self.line))
            })?;
            return Ok(Token::Number(val));
        }

        // Try SI suffix lookup using bigospice_utility::si_multiplier.
        if let Some(multiplier) = si_multiplier(&suffix_buf) {
            let val: f64 = buf.parse().map_err(|_| {
                SimError::Parse(format!("invalid number '{}' at line {}", buf, self.line))
            })?;
            return Ok(Token::Number(val * multiplier));
        }

        // The suffix might not be an SI suffix — it could be a unit like "Hz" or "ohm".
        // In that case, parse the numeric part alone and rewind the suffix.
        let val: f64 = buf.parse().map_err(|_| {
            SimError::Parse(format!("invalid number '{}' at line {}", buf, self.line))
        })?;
        // Rewind: put the suffix bytes back.
        self.pos = suffix_start;
        self.col = self.col.saturating_sub(suffix_buf.len());
        Ok(Token::Number(val))
    }

    /// Read a word (identifier) token.
    ///
    /// If the word is immediately followed by `:` (e.g. `PARAMS:`), the colon
    /// is consumed and discarded so `PARAMS:` tokenizes as `Word("params")`.
    /// Input is pre-lowercased so no per-call lowercasing is needed.
    fn read_word(&mut self, first: u8) -> Token {
        let mut buf = String::new();
        buf.push(first as char);

        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphanumeric() || ch == b'_' || ch == b'#' {
                buf.push(ch as char);
                self.advance();
            } else {
                break;
            }
        }

        // Consume a trailing colon (e.g. `PARAMS:`) so it is not seen as an
        // unknown character error; the word itself is returned without the colon.
        if self.peek() == Some(b':') {
            self.advance();
        }

        Token::Word(buf)
    }

    /// Read a dot-directive token: `.PARAM`, `.MODEL`, etc.
    /// Input is pre-lowercased so no per-call lowercasing is needed.
    fn read_dot_directive(&mut self) -> Token {
        let mut buf = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphanumeric() || ch == b'_' {
                buf.push(ch as char);
                self.advance();
            } else {
                break;
            }
        }
        Token::Dot(buf)
    }

    /// Return the next token from the input.
    pub fn next_token(&mut self) -> Result<Token, SimError> {
        loop {
            self.skip_whitespace();

            let ch = match self.peek() {
                Some(c) => c,
                None => return Ok(Token::Eof),
            };

            // Handle newlines.
            if ch == b'\n' {
                self.advance();
                self.at_line_start = true;

                // Collapse: skip any following comment-only lines and blank lines,
                // then check for continuation.
                loop {
                    self.skip_whitespace();
                    match self.peek() {
                        Some(b'\n') => {
                            // Blank line — skip it.
                            self.advance();
                            continue;
                        }
                        Some(b'*') => {
                            // Comment line — skip entire line.
                            self.skip_to_eol();
                            continue;
                        }
                        Some(b'+') => {
                            // Continuation — consume '+' and merge with previous line.
                            self.advance();
                            self.at_line_start = false;
                            // Break out of this inner loop and continue the outer
                            // loop to tokenize more content on this logical line.
                            break;
                        }
                        _ => {
                            // Real content on a new line — emit the Newline.
                            return Ok(Token::Newline);
                        }
                    }
                }
                // If we reach here, it was a continuation — keep tokenizing.
                continue;
            }

            // Handle full-line comments: '*' at start of line.
            if ch == b'*' && self.at_line_start {
                self.skip_to_eol();
                // Consume the trailing newline so we don't emit a stray Newline token.
                if self.peek() == Some(b'\n') {
                    self.advance();
                }
                // Stay at line start for the next line.
                self.at_line_start = true;
                continue;
            }

            // Handle inline comments: ';' or '$' anywhere.
            if ch == b';' || ch == b'$' {
                self.skip_to_eol();
                continue;
            }

            // We are no longer at line start after reading a real token.
            self.at_line_start = false;

            // Dot directive.
            if ch == b'.' {
                self.advance();
                return Ok(self.read_dot_directive());
            }

            // Number: starts with digit or '.' followed by digit.
            if ch.is_ascii_digit() {
                self.advance();
                return self.read_number(ch);
            }

            // Single-character tokens.
            match ch {
                b'=' => { self.advance(); return Ok(Token::Equals); }
                b'(' => { self.advance(); return Ok(Token::LeftParen); }
                b')' => { self.advance(); return Ok(Token::RightParen); }
                b',' => { self.advance(); return Ok(Token::Comma); }
                b'+' => { self.advance(); return Ok(Token::Plus); }
                b'-' => { self.advance(); return Ok(Token::Minus); }
                b'*' => {
                    self.advance();
                    return Ok(Token::Star);
                }
                b'/' => { self.advance(); return Ok(Token::Slash); }
                b'{' => { self.advance(); return Ok(Token::LeftBrace); }
                b'}' => { self.advance(); return Ok(Token::RightBrace); }
                _ => {}
            }

            // Word / identifier.
            if ch.is_ascii_alphabetic() || ch == b'_' {
                self.advance();
                return Ok(self.read_word(ch));
            }

            // Quoted string: "..." (double-quoted → opaque QuotedString)
            // Single-quoted: '...' (HSPICE arithmetic expression → SingleQuoteExpr)
            if ch == b'"' || ch == b'\'' {
                self.advance(); // consume opening quote
                let mut buf = String::new();
                let close = ch;
                while let Some(c) = self.peek() {
                    if c == close {
                        self.advance(); // consume closing quote
                        break;
                    }
                    if c == b'\n' {
                        break; // unterminated string — stop at EOL
                    }
                    buf.push(c as char);
                    self.advance();
                }
                if close == b'\'' {
                    // Single-quoted content is an HSPICE arithmetic expression.
                    // Input is already lowercased.
                    return Ok(Token::SingleQuoteExpr(buf));
                }
                return Ok(Token::QuotedString(buf));
            }

            // Unknown character — skip it.
            self.advance();
            return Err(SimError::Parse(format!(
                "unexpected character '{}' at line {}:{}",
                ch as char, self.line, self.col
            )));
        }
    }

    /// Tokenize the entire input into a vector of tokens.
    pub fn tokenize_all(&mut self) -> Result<Vec<Token>, SimError> {
        let mut tokens = Vec::new();
        loop {
            let tok = self.next_token()?;
            if tok == Token::Eof {
                tokens.push(Token::Eof);
                break;
            }
            tokens.push(tok);
        }
        Ok(tokens)
    }
}

// ===========================================================================
// SpiceParser (formerly spice.rs, imports updated to crate::types::*)
// ===========================================================================

/// Pending B-source record, stored before circuit construction.
struct PendingBsource {
    name: String,
    node_p: String,
    node_n: String,
    kind: DeviceKind, // BsourceV or BsourceI
    expr: BehavioralExpr,
}

/// Which controlled-source family generated a `LAPLACE` form, used by
/// the parse-time expansion in `parse_laplace_form`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LaplaceKind {
    /// `E … LAPLACE …` — voltage-output controlled source.
    Vcvs,
    /// `G … LAPLACE …` — current-output controlled source.
    Vccs,
}

/// Pending K (mutual inductance) record, stored before circuit construction.
/// Resolved during `build_circuit` once all inductor device names are known.
struct PendingKElement {
    /// K element name, e.g. "k1".
    #[allow(dead_code)]
    name: String,
    /// First inductor name, e.g. "l1".
    l1_name: String,
    /// Second inductor name, e.g. "l2".
    l2_name: String,
    /// Coupling coefficient k ∈ (0, 1].
    k: f64,
}

/// Which controlled-source family a POLY form belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PolyKind {
    /// `E … POLY(n) …` — voltage-output (VCVS).
    Vcvs,
    /// `G … POLY(n) …` — current-output (VCCS).
    Vccs,
}

/// Pending A-device (XSPICE A-element) record, stored before circuit construction.
/// These are routed to the digital event engine during circuit build.
struct PendingADevice {
    /// Instance name, e.g. "ainv".
    name: String,
    /// Input node names (analog for ADC, digital for primitives).
    inputs: Vec<String>,
    /// Output node names (analog for DAC, digital for primitives).
    outputs: Vec<String>,
    /// Model name from the .model card, e.g. "d_inverter", "adc_bridge".
    model_name: String,
}

/// Terminator kind for an `.IF / .ELSEIF / .ELSE / .ENDIF` block branch.
///
/// Returned by both the executing and skipping body-walkers so the
/// outer state machine can decide what to do with the next branch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IfBranchEnd {
    /// `.endif` was reached — the conditional is complete.
    Endif,
    /// `.else` was reached — the next body should run unconditionally
    /// (if we were taking branches) or be skipped (if we already took one).
    Else,
    /// `.elseif` was reached — a new condition follows on the same stream.
    Elseif,
}

/// The main SPICE netlist parser.
///
/// Converts tokenized SPICE text into a [`ParsedNetlist`] and then into a
/// [`Circuit`] plus a list of [`AnalysisStatement`]s.
pub struct SpiceParser {
    tokens: Vec<Token>,
    pos: usize,
    netlist: ParsedNetlist,
    /// B-source devices accumulated during element parsing.
    pending_bsources: Vec<PendingBsource>,
    /// K (mutual inductance) elements accumulated during element parsing.
    pending_k_elements: Vec<PendingKElement>,
    /// XSPICE A-device elements accumulated during element parsing.
    pending_a_devices: Vec<PendingADevice>,
}

// ---------------------------------------------------------------------------
// Include / Lib pre-processing
// ---------------------------------------------------------------------------

/// Strip optional surrounding quotes from a SPICE filename token.
/// Accepts `"file.sp"`, `'file.sp'`, or bare `file.sp`.
fn strip_filename_quotes(s: &str) -> &str {
    let s = s.trim();
    if (s.starts_with('"') && s.ends_with('"'))
        || (s.starts_with('\'') && s.ends_with('\''))
    {
        &s[1..s.len() - 1]
    } else {
        s
    }
}

/// Resolve `filename` relative to `base_dir`, or relative to CWD when
/// `base_dir` is `None`.
fn resolve_path(base_dir: Option<&Path>, filename: &str) -> PathBuf {
    let p = Path::new(filename);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        match base_dir {
            Some(dir) => dir.join(p),
            None => PathBuf::from(filename),
        }
    }
}

/// Recursively expand `.INCLUDE` and `.LIB` directives in `text`.
///
/// `base_dir`      — directory of the file being processed (for relative paths).
/// `include_stack` — canonical paths of all files currently open (cycle detection).
///
/// Returns the expanded text with all includes inlined.
fn preprocess(
    text: &str,
    base_dir: Option<&Path>,
    include_stack: &mut Vec<PathBuf>,
) -> Result<String, SimError> {
    let mut out = String::with_capacity(text.len());

    for raw_line in text.lines() {
        let trimmed = raw_line.trim();
        let lower = trimmed.to_ascii_lowercase();

        if lower.starts_with(".include") {
            // .INCLUDE "filename"  or  .INCLUDE filename
            let rest = trimmed[".include".len()..].trim();  // skip ".include"
            let filename = strip_filename_quotes(rest);
            if filename.is_empty() {
                return Err(SimError::Parse(
                    ".INCLUDE directive missing filename".into(),
                ));
            }
            let path = resolve_path(base_dir, filename);
            let canonical = path.canonicalize().map_err(|e| {
                SimError::Parse(format!(
                    ".INCLUDE: cannot resolve '{}': {e}",
                    path.display()
                ))
            })?;

            if include_stack.contains(&canonical) {
                return Err(SimError::Parse(format!(
                    "include cycle detected: {}",
                    canonical.display()
                )));
            }

            let content = std::fs::read_to_string(&canonical).map_err(SimError::Io)?;

            let child_dir: Option<PathBuf> = canonical.parent().map(Path::to_path_buf);
            include_stack.push(canonical);
            let expanded = preprocess(&content, child_dir.as_deref(), include_stack)?;
            include_stack.pop();

            out.push_str(&expanded);
            out.push('\n');
        } else if lower.starts_with(".lib") {
            // Could be either:
            //   (a) .LIB "filename" section_name  — include a section from a file
            //   (b) .LIB section_name ... .ENDL   — definition block (skip the header line;
            //       the block body is consumed by the .ENDL handler below)
            let rest = trimmed[".lib".len()..].trim();

            // Determine if this is a file-include form (has a quoted path or two words).
            // A definition block looks like: .LIB <section_name>  (one bare word, no path).
            // A file-include looks like:    .LIB "file" section  or .LIB file section
            let (filename_part, section_part) = split_lib_args(rest);

            if let (Some(filename), Some(section)) = (filename_part, section_part) {
                // Form (a): include a section from a named file.
                let path = resolve_path(base_dir, strip_filename_quotes(filename));
                let canonical = path.canonicalize().map_err(|e| {
                    SimError::Parse(format!(
                        ".LIB: cannot resolve '{}': {e}",
                        path.display()
                    ))
                })?;

                if include_stack.contains(&canonical) {
                    return Err(SimError::Parse(format!(
                        "include cycle detected: {}",
                        canonical.display()
                    )));
                }

                let content = std::fs::read_to_string(&canonical).map_err(SimError::Io)?;

                let block = extract_lib_section(&content, section).ok_or_else(|| {
                    SimError::Parse(format!(
                        ".LIB: section '{}' not found in '{}'",
                        section,
                        canonical.display()
                    ))
                })?;
                // `block` borrows `content`; copy it to an owned String so we can move `canonical`.
                let block_owned = block.to_owned();

                let child_dir: Option<PathBuf> = canonical.parent().map(Path::to_path_buf);
                include_stack.push(canonical);
                let expanded = preprocess(&block_owned, child_dir.as_deref(), include_stack)?;
                include_stack.pop();

                out.push_str(&expanded);
                out.push('\n');
            } else {
                // Form (b): definition block header — pass through as-is so the
                // tokenizer can handle it (or skip with .ENDL).
                out.push_str(raw_line);
                out.push('\n');
            }
        } else {
            out.push_str(raw_line);
            out.push('\n');
        }
    }

    Ok(out)
}

/// Split the argument string of a `.LIB` line into `(filename, section)`.
///
/// Returns `(None, None)` for a bare `.LIB section_name` definition block.
/// Returns `(Some(filename), Some(section))` for a file-include form.
fn split_lib_args(rest: &str) -> (Option<&str>, Option<&str>) {
    let rest = rest.trim();
    if rest.is_empty() {
        return (None, None);
    }

    if rest.starts_with('"') || rest.starts_with('\'') {
        // Quoted filename — find closing quote.
        let quote_char = rest.chars().next().unwrap();
        let after_open = &rest[1..];
        if let Some(close) = after_open.find(quote_char) {
            let filename = &rest[..close + 2]; // includes both quotes
            let section = after_open[close + 1..].trim();
            if section.is_empty() {
                (None, None)
            } else {
                (Some(filename), Some(section))
            }
        } else {
            (None, None)
        }
    } else {
        // Unquoted — split on whitespace.
        let mut parts = rest.splitn(2, |c: char| c.is_ascii_whitespace());
        let first = parts.next().unwrap_or("").trim();
        let second = parts.next().unwrap_or("").trim();

        if second.is_empty() {
            // Only one word: this is a definition block header.
            (None, None)
        } else {
            // Two words: first is filename, second is section.
            (Some(first), Some(second))
        }
    }
}

/// Returns true if the `.LIB` argument string is a definition-block header
/// for `lower_section` (a single bare word matching the section, no filename).
fn is_lib_definition_header(lib_args: &str, lower_section: &str) -> bool {
    let args = lib_args.trim();
    if args.is_empty() {
        return false;
    }
    // A definition header has no spaces (single word) and no quotes.
    if args.contains('"') || args.contains('\'') {
        return false;
    }
    let lower_args = args.to_ascii_lowercase();
    // Must be a single token (no internal whitespace) matching the section.
    !lower_args.contains(|c: char| c.is_ascii_whitespace()) && lower_args == lower_section
}

/// Extract the body of a `.LIB <section>` ... `.ENDL [section]` block from
/// a library file's text.  Returns `None` if the section is not found.
fn extract_lib_section<'a>(content: &'a str, section: &str) -> Option<&'a str> {
    let lower_section = section.to_ascii_lowercase();

    let mut search_start = 0usize;
    loop {
        // Find the next `.lib <section>` definition-block header line.
        let remaining = &content[search_start..];
        let header_line_idx = remaining.lines().enumerate().find_map(|(line_idx, line)| {
            let lt = line.trim().to_ascii_lowercase();
            if lt.starts_with(".lib") {
                let lib_args = lt[".lib".len()..].trim();
                if is_lib_definition_header(lib_args, &lower_section) {
                    return Some(line_idx);
                }
            }
            None
        })?;

        // Compute byte offset of the line *after* the header.
        let body_start_offset: usize = remaining
            .lines()
            .take(header_line_idx + 1)
            .map(|l| l.len() + 1) // +1 for '\n'
            .sum();

        let body_start = search_start + body_start_offset;

        // Find the matching `.ENDL [section]` line from body_start.
        let body_text = &content[body_start..];
        let endl_line_idx = body_text.lines().enumerate().find_map(|(i, line)| {
            let lt = line.trim().to_ascii_lowercase();
            if lt.starts_with(".endl") {
                let after = lt[".endl".len()..].trim();
                // Match if no section name given, or section name matches.
                if after.is_empty() || after == lower_section.as_str() {
                    return Some(i);
                }
            }
            None
        });

        if let Some(endl_line_idx) = endl_line_idx {
            // Compute byte range of the body (between header and .ENDL).
            let body_end: usize = body_text
                .lines()
                .take(endl_line_idx)
                .map(|l| l.len() + 1)
                .sum();
            return Some(&content[body_start..body_start + body_end]);
        }

        // No .ENDL found — skip past this header and keep searching.
        search_start += body_start_offset;
        if search_start >= content.len() {
            return None;
        }
    }
}

/// Reconstruct a human-readable line from a slice of tokens.
///
/// Used by [`SpiceParser::parse_control_block`] to recover raw statement text
/// from the tokenized stream.  Words are space-separated; operators and
/// punctuation are emitted without extra spaces so that `v(out)=1.5` remains
/// compact.
fn tokens_to_raw_line(tokens: &[Token]) -> String {
    let mut out = String::new();
    for (i, tok) in tokens.iter().enumerate() {
        match tok {
            Token::Newline | Token::Eof => {}
            Token::Equals | Token::LeftParen | Token::RightParen
            | Token::LeftBrace | Token::RightBrace | Token::Comma => {
                out.push_str(&tok.to_string());
            }
            Token::Plus | Token::Minus | Token::Star | Token::Slash => {
                if i > 0 {
                    out.push(' ');
                }
                out.push_str(&tok.to_string());
                out.push(' ');
            }
            Token::Dot(d) => {
                if i > 0 {
                    out.push(' ');
                }
                out.push('.');
                out.push_str(d);
            }
            other => {
                if i > 0 && !out.ends_with('(') && !out.ends_with('{') {
                    out.push(' ');
                }
                out.push_str(&other.to_string());
            }
        }
    }
    out
}

/// Convert a single `Token` into zero or more lowercase string tokens for
/// `.MEAS` / `.MEASURE` statement storage.
///
/// Structural tokens (Newline, Eof) produce no output.  All others are
/// rendered with their `Display` impl and lower-cased so that the measure
/// evaluator can do case-insensitive comparisons.
fn token_to_meas_strings(tok: &Token) -> Vec<String> {
    match tok {
        Token::Newline | Token::Eof => vec![],
        other => vec![other.to_string().to_ascii_lowercase()],
    }
}

impl SpiceParser {
    /// Parse a SPICE netlist file at `path` into a `Circuit`, analysis commands, and sim options.
    ///
    /// `.INCLUDE` and `.LIB` directives inside the file are resolved relative
    /// to the file's directory.  Include cycles are detected and return an error.
    pub fn parse_file(path: &Path) -> Result<(Circuit, Vec<AnalysisStatement>, bigospice_core::SimOptions), SimError> {
        let canonical = path.canonicalize().map_err(SimError::Io)?;
        let content = std::fs::read_to_string(&canonical).map_err(SimError::Io)?;
        let base_dir: Option<PathBuf> = canonical.parent().map(Path::to_path_buf);
        let mut include_stack = vec![canonical];
        let expanded = preprocess(&content, base_dir.as_deref(), &mut include_stack)?;
        Self::parse_expanded(&expanded)
    }

    /// Parse a SPICE netlist string into a `Circuit`, analysis commands, and sim options.
    ///
    /// `.INCLUDE` directives in `input` are resolved relative to the process
    /// working directory.  Pass a file path to [`SpiceParser::parse_file`] for
    /// proper relative-path resolution.
    pub fn parse(input: &str) -> Result<(Circuit, Vec<AnalysisStatement>, bigospice_core::SimOptions), SimError> {
        // Run the pre-processor with CWD-relative includes.
        let mut include_stack: Vec<PathBuf> = Vec::new();
        let expanded = preprocess(input, None, &mut include_stack)?;
        Self::parse_expanded(&expanded)
    }

    /// Internal: tokenize and parse an already-expanded (includes resolved) netlist string.
    /// Returns `(circuit, analyses, options)` — extract specs are dropped.
    fn parse_expanded(input: &str) -> Result<(Circuit, Vec<AnalysisStatement>, bigospice_core::SimOptions), SimError> {
        let (c, a, o, _) = Self::parse_expanded_full(input)?;
        Ok((c, a, o))
    }

    /// Internal: like `parse_expanded` but also returns `.EXTRACT` specs.
    fn parse_expanded_full(input: &str) -> Result<(Circuit, Vec<AnalysisStatement>, bigospice_core::SimOptions, Vec<ExtractSpec>), SimError> {
        // In SPICE, the first line is always the title line (even if it starts with *).
        // Extract it from raw text before tokenizing so the lexer doesn't skip it.
        let (title, rest) = match input.find('\n') {
            Some(pos) => {
                let title_line = input[..pos].trim();
                // Strip leading '*' if present (comment-style title).
                let title = title_line.strip_prefix('*').unwrap_or(title_line).trim();
                (title.to_string(), &input[pos + 1..])
            }
            None => (input.trim().to_string(), ""),
        };

        let mut lexer = Lexer::new(rest);
        let tokens = lexer.tokenize_all()?;

        let mut parser = SpiceParser {
            tokens,
            pos: 0,
            netlist: ParsedNetlist::new(),
            pending_bsources: Vec::new(),
            pending_k_elements: Vec::new(),
            pending_a_devices: Vec::new(),
        };

        parser.netlist.title = title;
        parser.parse_body()?;
        parser.build_circuit()
    }

    /// Parse a SPICE netlist string, returning circuit, analyses, options, and any
    /// `.EXTRACT` specifications (HSPICE W.5) for post-simulation evaluation.
    ///
    /// Use [`SpiceParser::parse`] when `.EXTRACT` specs are not needed.
    pub fn parse_netlist(input: &str) -> Result<(Circuit, Vec<AnalysisStatement>, bigospice_core::SimOptions, Vec<ExtractSpec>), SimError> {
        let mut include_stack: Vec<PathBuf> = Vec::new();
        let expanded = preprocess(input, None, &mut include_stack)?;
        Self::parse_expanded_full(&expanded)
    }

    // -----------------------------------------------------------------------
    // Token stream helpers
    // -----------------------------------------------------------------------

    fn peek(&self) -> &Token {
        self.tokens.get(self.pos).unwrap_or(&Token::Eof)
    }

    fn advance(&mut self) -> &Token {
        let tok = self.tokens.get(self.pos).unwrap_or(&Token::Eof);
        if self.pos < self.tokens.len() {
            self.pos += 1;
        }
        tok
    }

    fn at_end(&self) -> bool {
        matches!(self.peek(), Token::Eof)
    }

    /// Skip newline tokens.
    fn skip_newlines(&mut self) {
        while matches!(self.peek(), Token::Newline) {
            self.advance();
        }
    }

    /// Collect all tokens on the current logical line (up to Newline or Eof).
    fn collect_line(&mut self) -> Vec<Token> {
        let mut line = Vec::new();
        loop {
            match self.peek() {
                Token::Newline => {
                    self.advance();
                    break;
                }
                Token::Eof => break,
                _ => {
                    line.push(self.advance().clone());
                }
            }
        }
        line
    }

    // -----------------------------------------------------------------------
    // Body parsing
    // -----------------------------------------------------------------------

    fn parse_body(&mut self) -> Result<(), SimError> {
        loop {
            self.skip_newlines();
            if self.at_end() {
                break;
            }

            match self.peek().clone() {
                Token::Dot(ref directive) => {
                    let directive = directive.clone();
                    self.parse_dot_command(&directive)?;
                }
                Token::Word(_) => {
                    self.parse_element()?;
                }
                _ => {
                    // Skip unexpected tokens.
                    self.advance();
                }
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Dot commands
    // -----------------------------------------------------------------------

    fn parse_dot_command(&mut self, directive: &str) -> Result<(), SimError> {
        // Consume the Dot token.
        self.advance();

        match directive {
            "model" => self.parse_model()?,
            "param" => self.parse_param()?,
            "func" => self.parse_func()?,
            "dc" => self.parse_dc()?,
            "tran" => self.parse_tran()?,
            "ac" => self.parse_ac()?,
            "op" => self.parse_op()?,
            "noise" => self.parse_noise()?,
            "hb" => self.parse_hb()?,
            "four" => self.parse_four()?,
            "fft" => self.parse_fft()?,
            "disto" => self.parse_disto()?,
            "sens" => self.parse_sens()?,
            "subckt" => self.parse_subckt()?,
            "options" => self.parse_options()?,
            "ic" => self.parse_ic()?,
            "nodeset" => self.parse_nodeset()?,
            "global" => self.parse_global()?,
            "temp" => self.parse_temp()?,
            "meas" | "measure" => self.parse_meas()?,
            "step" => self.parse_step()?,
            "save" => self.parse_save_print_plot("save")?,
            "print" => self.parse_save_print_plot("print")?,
            "plot" => self.parse_save_print_plot("plot")?,
            // T.10: .PROBE aliases .SAVE (HSPICE compat); par('expr') args are
            // forwarded as ComputedExpr specs via the same handler.
            "probe" => self.parse_save_print_plot("save")?,
            "if" => self.parse_if(false)?,
            // T.5: .IFDEF / .IFNDEF — check param existence rather than value
            "ifdef" => self.parse_ifdef(false)?,
            "ifndef" => self.parse_ifdef(true)?,
            "elseif" | "else" | "endif" => {
                // Stray else/endif at top level — silently consume the line.
                // (Properly nested ones are consumed inside parse_if.)
                self.collect_line();
            }
            "data" => self.parse_data()?,
            // T.6: .GLOBAL_PARAM — Xyce globally-scoped parameters
            "global_param" => self.parse_global_param()?,
            // .LINSOL solver_name — select linear solver (ngspice/Xyce extension)
            // Syntax: .LINSOL KLU  or  .LINSOL SPARSE
            "linsol" => {
                let line = self.collect_line();
                if let Some(Token::Word(s)) = line.first() {
                    self.netlist.options.lin_solver =
                        match s.to_lowercase().as_str() {
                            "klu" => bigospice_core::LinSolverChoice::Klu,
                            _ => bigospice_core::LinSolverChoice::SparseLu,
                        };
                }
            }
            "control" => self.parse_control_block()?,
            "endc" => {
                // Stray .endc outside a .control block — silently consume.
                self.collect_line();
            }
            // O.2: .ALTER — re-run analysis with patched parameters.
            // Minimal implementation: collect the block to prevent element pollution.
            "alter" | "endalter" => self.parse_alter()?,
            // T.11: .BINMODEL — MOSFET model bin group for geometry-based selection.
            "binmodel" => self.parse_binmodel()?,
            // T.12: .DISTRIBUTION — custom statistical distribution for MC analysis.
            "distribution" => self.parse_distribution()?,
            // W.6: .CONNECT net1 net2 — short-circuit two nets (Xyce/HSPICE compat).
            "connect" => self.parse_connect()?,
            // W.5: .EXTRACT [TRAN|AC|DC] label=expr — HSPICE measurement extraction.
            "extract" => self.parse_extract()?,
            // W.4: .ROL LIFETIME=<t> [TEMP=<t>] [EM=<0|1>] [NBTI=<0|1>] [HCI=<0|1>]
            "rol" => self.parse_rol()?,
            "end" | "ends" | "enddata" => {
                // Consume rest of line.
                self.collect_line();
            }
            _ => {
                // Unknown directive — skip the line.
                self.collect_line();
            }
        }
        Ok(())
    }

    /// `.MODEL name type (param=val ...)`
    fn parse_model(&mut self) -> Result<(), SimError> {
        let name = match self.peek().clone() {
            Token::Word(s) => { self.advance(); s }
            _ => return Err(SimError::Parse("expected model name after .MODEL".into())),
        };

        let kind = match self.peek().clone() {
            Token::Word(s) => { self.advance(); s }
            _ => return Err(SimError::Parse("expected model type after model name".into())),
        };

        let mut params = Vec::new();

        // Optional parenthesized parameters.
        if matches!(self.peek(), Token::LeftParen) {
            self.advance(); // consume '('
            loop {
                match self.peek() {
                    Token::RightParen => { self.advance(); break; }
                    Token::Newline | Token::Eof => break,
                    _ => {}
                }
                // Expect: name = value
                let pname = match self.peek().clone() {
                    Token::Word(s) => { self.advance(); s }
                    _ => { self.advance(); continue; }
                };
                if matches!(self.peek(), Token::Equals) {
                    self.advance();
                }
                // O.4: handle LOT=5% / DEV=2% — percentage statistical params.
                let pval = match self.peek().clone() {
                    Token::Word(ref s) if s.ends_with('%') => {
                        let s = s.clone();
                        self.advance();
                        Si::parse_spice_value(s.trim_end_matches('%'))
                            .map(|v| v / 100.0)
                            .unwrap_or(0.0)
                    }
                    _ => self.read_numeric_value().unwrap_or(0.0),
                };
                params.push((pname, pval));
            }
        }

        // Also handle inline params without parentheses (e.g. `.MODEL JN NJF LEVEL=2 VTO=-2`).
        // Collect the rest of the line and scan for kv-params.
        let rest = self.collect_line();
        let mut tok_idx = 0;
        while tok_idx < rest.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&rest[tok_idx..]) {
                // Only add if not already set (parenthesized params take priority).
                if !params.iter().any(|(pk, _)| pk.eq_ignore_ascii_case(&k)) {
                    params.push((k, v));
                }
                tok_idx += consumed;
            } else {
                tok_idx += 1;
            }
        }

        self.netlist.models.push(ModelStatement { name, kind, params });
        Ok(())
    }

    /// `.BINMODEL name NMOS|PMOS [model1 model2 ...]`  (T.11)
    ///
    /// Groups `.MODEL` entries under a named bin group for geometry-based
    /// model selection.  Each `.MODEL` that belongs to this group supplies
    /// `LMIN`/`LMAX`/`WMIN`/`WMAX` geometry limits; `BinModel::resolve`
    /// picks the matching bin at MOSFET instantiation time.
    fn parse_binmodel(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut idx = 0;

        // First token: group name.
        let name = match line.get(idx) {
            Some(Token::Word(s)) => { idx += 1; s.to_lowercase() }
            _ => return Ok(()),
        };

        // Second token: device type (nmos / pmos).
        let kind = match line.get(idx) {
            Some(Token::Word(s)) => { idx += 1; s.to_lowercase() }
            _ => return Ok(()),
        };

        // Remaining tokens: optional explicit model name list.
        let mut explicit_names: Vec<String> = Vec::new();
        while idx < line.len() {
            if let Token::Word(s) = &line[idx] {
                explicit_names.push(s.to_lowercase());
            }
            idx += 1;
        }

        // Helper: look up a named f64 param from a model's param list.
        let param_f64 = |params: &[(String, f64)], key: &str| -> Option<f64> {
            params
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(key))
                .map(|(_, v)| *v)
        };

        // Determine which .MODEL names belong to this bin group.
        // If explicit names were listed, use those; otherwise infer from the
        // PDK convention of sharing a common prefix (e.g. `nch`, `nch_0`, …).
        let candidate_names: Vec<String> = if explicit_names.is_empty() {
            self.netlist
                .models
                .iter()
                .filter(|m| {
                    let mn = m.name.to_lowercase();
                    mn == name
                        || mn.starts_with(&format!("{name}_"))
                        || mn.starts_with(&format!("{name}."))
                })
                .map(|m| m.name.clone())
                .collect()
        } else {
            explicit_names
        };

        let entries: Vec<BinModelEntry> = candidate_names
            .iter()
            .filter_map(|mn| {
                self.netlist
                    .models
                    .iter()
                    .find(|m| m.name.eq_ignore_ascii_case(mn))
                    .map(|m| BinModelEntry {
                        model_name: m.name.clone(),
                        lmin: param_f64(&m.params, "lmin"),
                        lmax: param_f64(&m.params, "lmax"),
                        wmin: param_f64(&m.params, "wmin"),
                        wmax: param_f64(&m.params, "wmax"),
                    })
            })
            .collect();

        self.netlist.bin_models.push(BinModel { name, kind, entries });
        Ok(())
    }

    /// `.DISTRIBUTION name UNIFORM|GAUSSIAN|LOGNORM|BIMODAL [params...]`  (T.12)
    ///
    /// Defines a named custom statistical distribution referenced by
    /// `DIST=name` on parameters in `.MODEL` blocks during Monte Carlo
    /// analysis.  The record is stored in `netlist.distributions` for
    /// lookup by the MC driver in `bigospice_analysis::mc`.
    fn parse_distribution(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut idx = 0;

        // First token: distribution name.
        let name = match line.get(idx) {
            Some(Token::Word(s)) => { idx += 1; s.to_lowercase() }
            _ => return Ok(()),
        };

        // Second token: distribution type keyword.
        let kind = match line.get(idx) {
            Some(Token::Word(s)) => {
                idx += 1;
                match s.to_ascii_uppercase().as_str() {
                    "UNIFORM"  => DistKind::Uniform,
                    "GAUSSIAN" => DistKind::Gaussian,
                    "LOGNORM"  => DistKind::Lognorm,
                    "BIMODAL"  => DistKind::Bimodal,
                    _ => DistKind::Gaussian,
                }
            }
            _ => return Ok(()),
        };

        // Remaining tokens: optional numeric parameters (sigma scale, etc.).
        let mut params: Vec<f64> = Vec::new();
        while idx < line.len() {
            if let Token::Number(n) = &line[idx] {
                params.push(*n);
            }
            idx += 1;
        }

        self.netlist
            .distributions
            .push(CustomDistribution { name, kind, params });
        Ok(())
    }

    /// `.PARAM name=value` or `.PARAM name={expr}` or `.PARAM name=expr`
    ///
    /// Supports multiple definitions per line, brace expressions, and bare
    /// expression bodies. Each value is evaluated against the current
    /// `netlist.params` snapshot so forward references are not allowed but
    /// later definitions may use earlier ones.
    fn parse_param(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut i = 0;
        while i < line.len() {
            // Skip leading non-word tokens.
            let name = match &line[i] {
                Token::Word(s) => {
                    let s = s.clone();
                    i += 1;
                    s
                }
                _ => {
                    i += 1;
                    continue;
                }
            };

            if i >= line.len() || line[i] != Token::Equals {
                continue;
            }
            i += 1; // consume '='
            if i >= line.len() {
                break;
            }

            // ── Brace expression form: name = { expr } ────────────────────
            if line[i] == Token::LeftBrace {
                let (expr, consumed) = parse_brace_expression(&line[i..])
                    .map_err(|e| SimError::Parse(format!(".PARAM '{name}': {e}")))?;
                i += consumed;
                let val = eval_expression(&expr, &self.netlist.params).ok();
                if let Some(v) = val {
                    self.netlist.params.insert(name.clone(), v);
                }
                // Detect OPTVAL(init, lower, upper) in brace expressions.
                if let Expression::Func(ref fname, ref fargs) = expr {
                    if fname.eq_ignore_ascii_case("optval") && fargs.len() >= 3 {
                        let init  = eval_expression(&fargs[0], &self.netlist.params).unwrap_or(0.0);
                        let lower = eval_expression(&fargs[1], &self.netlist.params).unwrap_or(0.0);
                        let upper = eval_expression(&fargs[2], &self.netlist.params).unwrap_or(0.0);
                        self.netlist.optimize_params.push(OptimizeParam {
                            name: name.clone(),
                            init,
                            lower,
                            upper,
                        });
                        self.netlist.params.insert(name.clone(), init);
                    }
                }
                self.netlist.param_exprs.push((name, expr));
                continue;
            }

            // ── Bare-number form: name = 1k ───────────────────────────────
            // Try a single-token numeric first (most common case).
            if let Some(val) = Self::token_to_number(&line[i]) {
                // Check whether the *next* token after this number starts a
                // new `name =` pair — if so it's just a number; otherwise it
                // might be a multi-token bare expression like `2*pi*f`.
                let next_starts_new = i + 1 < line.len()
                    && matches!(&line[i + 1], Token::Word(_))
                    && i + 2 < line.len()
                    && line[i + 2] == Token::Equals;
                if next_starts_new || i + 1 >= line.len() {
                    self.netlist.params.insert(name.clone(), val);
                    self.netlist.param_exprs.push((name, Expression::Literal(val)));
                    i += 1;
                    continue;
                }
            }

            // ── Bare expression form: name = 2*pi*freq ────────────────────
            // Find the end of this expression (next bare `name =` or end-of-line).
            let expr_end = Self::find_param_expr_end(&line[i..]);
            let expr_tokens = &line[i..i + expr_end];
            let expr = parse_expression(expr_tokens)
                .map_err(|e| SimError::Parse(format!(".PARAM '{name}': {e}")))?;
            let val = eval_expression(&expr, &self.netlist.params).ok();
            if let Some(v) = val {
                self.netlist.params.insert(name.clone(), v);
            }
            // If the expression is OPTVAL(init, lower, upper), extract bounds
            // and store in optimize_params in addition to the normal param value.
            if let Expression::Func(ref fname, ref fargs) = expr {
                if fname.eq_ignore_ascii_case("optval") && fargs.len() >= 3 {
                    let init  = eval_expression(&fargs[0], &self.netlist.params).unwrap_or(0.0);
                    let lower = eval_expression(&fargs[1], &self.netlist.params).unwrap_or(0.0);
                    let upper = eval_expression(&fargs[2], &self.netlist.params).unwrap_or(0.0);
                    self.netlist.optimize_params.push(OptimizeParam {
                        name: name.clone(),
                        init,
                        lower,
                        upper,
                    });
                    // Ensure the param map has the init value.
                    self.netlist.params.insert(name.clone(), init);
                }
            }
            self.netlist.param_exprs.push((name, expr));
            i += expr_end;
        }
        Ok(())
    }

    /// Find the end (exclusive) of a parameter expression body in a token slice.
    ///
    /// Stops at the start of a `Word, Equals` pair (indicating a new
    /// `name =` definition), or at the end of the slice. Tracks brace and
    /// paren depth so commas/equals inside function calls don't trigger.
    fn find_param_expr_end(tokens: &[Token]) -> usize {
        let mut depth_paren = 0i32;
        let mut depth_brace = 0i32;
        let mut i = 0;
        while i < tokens.len() {
            match &tokens[i] {
                Token::LeftParen => depth_paren += 1,
                Token::RightParen => depth_paren -= 1,
                Token::LeftBrace => depth_brace += 1,
                Token::RightBrace => depth_brace -= 1,
                Token::Word(_) if depth_paren == 0 && depth_brace == 0 => {
                    if i + 1 < tokens.len() && tokens[i + 1] == Token::Equals {
                        return i;
                    }
                }
                _ => {}
            }
            i += 1;
        }
        tokens.len()
    }

    /// `.FUNC name(arg1, arg2, ...) = expr`
    ///
    /// Stores the function definition under `netlist.funcs`. The body is
    /// parsed but not evaluated; arguments are referenced by name and resolved
    /// at expression-evaluation time.
    fn parse_func(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        // Layout: Word(name) LeftParen [Word(arg) (Comma Word(arg))*] RightParen Equals <expr...>
        if line.is_empty() {
            return Err(SimError::Parse(".FUNC: missing name".into()));
        }
        let name = match &line[0] {
            Token::Word(s) => s.clone(),
            _ => return Err(SimError::Parse(".FUNC: expected function name".into())),
        };
        if line.len() < 2 || line[1] != Token::LeftParen {
            return Err(SimError::Parse(format!(
                ".FUNC '{name}': expected '(' after function name"
            )));
        }
        let mut i = 2;
        let mut args = Vec::new();
        loop {
            match line.get(i) {
                Some(Token::RightParen) => {
                    i += 1;
                    break;
                }
                Some(Token::Comma) => {
                    i += 1;
                }
                Some(Token::Word(s)) => {
                    args.push(s.clone());
                    i += 1;
                }
                _ => {
                    return Err(SimError::Parse(format!(
                        ".FUNC '{name}': malformed argument list"
                    )));
                }
            }
        }
        if line.get(i) != Some(&Token::Equals) {
            return Err(SimError::Parse(format!(
                ".FUNC '{name}': expected '=' after argument list"
            )));
        }
        i += 1;
        // Body — accept either {expr} or bare expr.
        let body = if line.get(i) == Some(&Token::LeftBrace) {
            let (e, _) = parse_brace_expression(&line[i..])
                .map_err(|e| SimError::Parse(format!(".FUNC '{name}': {e}")))?;
            e
        } else {
            parse_expression(&line[i..])
                .map_err(|e| SimError::Parse(format!(".FUNC '{name}': {e}")))?
        };

        self.netlist
            .funcs
            .insert(name.to_lowercase(), FuncDef { name, args, body });
        Ok(())
    }

    /// `.STEP <kind?> {param} start stop step|points`
    ///
    /// Accepted forms:
    ///   `.STEP LIN  vdd 1 5 0.5`
    ///   `.STEP DEC  rload 100 10k 5`
    ///   `.STEP OCT  rload 100 10k 5`
    ///   `.STEP LIST vdd 1 1.5 2 3 5`
    ///   `.STEP vdd 1 5 0.5`        (implicit-LIN form)
    ///
    /// The `param` token may be a bare identifier (resolves against `.PARAM`)
    /// or a `device.param` form (resolves directly to a device parameter).
    fn parse_step(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        if line.is_empty() {
            return Err(SimError::Parse(".STEP: missing arguments".into()));
        }

        // Skip leading curly braces around the param name (some netlists wrap it).
        let mut idx = 0usize;

        // Detect kind keyword.
        // F006 audit: "data" is only matched here, inside parse_step(), which is
        // called exclusively from the ".step" handler in the directive dispatcher.
        // parse_dc() and parse_tran() have their own separate trailing DATA= handling
        // and never call parse_step(), so there is no cross-contamination.
        let (kind_keyword, after_kind_idx) = match &line[idx] {
            Token::Word(w) => {
                let lw = w.to_lowercase();
                match lw.as_str() {
                    "lin" | "dec" | "oct" | "list" | "data" => (Some(lw), idx + 1),
                    _ => (None, idx),
                }
            }
            _ => (None, idx),
        };
        idx = after_kind_idx;

        // Handle DATA form: .STEP DATA dataname
        if kind_keyword.as_deref() == Some("data") {
            // For DATA form, the next token is the data block name
            if idx >= line.len() {
                return Err(SimError::Parse(
                    ".STEP DATA: expected data block name".into(),
                ));
            }
            let block_name = match &line[idx] {
                Token::Word(s) => s.to_lowercase(),
                _ => {
                    return Err(SimError::Parse(
                        ".STEP DATA: expected data block name".into(),
                    ));
                }
            };
            self.netlist.steps.push(StepDirective {
                target: block_name.clone(),
                kind: StepKind::Data { block_name },
            });
            return Ok(());
        }

        // Read target parameter name (may be `Word` or `Word . Word` for device.param,
        // or wrapped in `{...}` braces).
        if line.get(idx) == Some(&Token::LeftBrace) {
            idx += 1;
        }
        let target = match line.get(idx) {
            Some(Token::Word(s)) => {
                let mut t = s.clone();
                idx += 1;
                // Allow `device.param` (lexer eats the `.` as a Dot token only at line start;
                // mid-line dots in identifiers are not lexed — instead the user must write
                // `device_param`. We accept both forms gracefully here.)
                if line.get(idx) == Some(&Token::RightBrace) {
                    idx += 1;
                }
                t.make_ascii_lowercase();
                t
            }
            _ => {
                return Err(SimError::Parse(
                    ".STEP: expected parameter name after kind keyword".into(),
                ));
            }
        };

        // Read remaining numeric arguments.
        let mut nums = Vec::new();
        while idx < line.len() {
            if let Some((v, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                nums.push(v);
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        let kind = match kind_keyword.as_deref() {
            Some("lin") => {
                if nums.len() < 3 {
                    return Err(SimError::Parse(
                        ".STEP LIN: expected start stop step".into(),
                    ));
                }
                StepKind::Lin {
                    start: nums[0],
                    stop: nums[1],
                    step: nums[2],
                }
            }
            Some("dec") => {
                if nums.len() < 3 {
                    return Err(SimError::Parse(
                        ".STEP DEC: expected start stop points".into(),
                    ));
                }
                StepKind::Dec {
                    start: nums[0],
                    stop: nums[1],
                    ppd: nums[2] as usize,
                }
            }
            Some("oct") => {
                if nums.len() < 3 {
                    return Err(SimError::Parse(
                        ".STEP OCT: expected start stop points".into(),
                    ));
                }
                StepKind::Oct {
                    start: nums[0],
                    stop: nums[1],
                    ppo: nums[2] as usize,
                }
            }
            Some("list") => {
                if nums.is_empty() {
                    return Err(SimError::Parse(".STEP LIST: expected at least one value".into()));
                }
                StepKind::List(nums)
            }
            None => {
                if nums.len() < 3 {
                    return Err(SimError::Parse(
                        ".STEP: expected start stop step".into(),
                    ));
                }
                StepKind::LinImplicit {
                    start: nums[0],
                    stop: nums[1],
                    step: nums[2],
                }
            }
            _ => unreachable!(),
        };

        self.netlist.steps.push(StepDirective { target, kind });
        Ok(())
    }

    /// `.SAVE`, `.PRINT`, `.PLOT` — capture output specifications.
    ///
    /// Syntax: `.SAVE [analysis_type] V(node) V(n1,n2) I(vname) V(*) I(*) *`
    ///
    /// `analysis_type` is optional and may be one of `dc`, `tran`, `ac`,
    /// `op`, `noise`. Wildcards `V(*)` / `I(*)` / `*` are recognized and
    /// resolved at simulation-launch time.
    fn parse_save_print_plot(&mut self, kind: &str) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut idx = 0usize;

        // Optional analysis qualifier (first Word that matches a known analysis).
        let mut analysis: Option<String> = None;
        if let Some(Token::Word(w)) = line.first() {
            let lw = w.to_lowercase();
            if matches!(lw.as_str(), "dc" | "tran" | "ac" | "op" | "noise" | "all") {
                analysis = Some(lw);
                idx = 1;
            }
        }

        // T.8 modifiers: FILE=, FORMAT=, DELIMITER= (may appear anywhere on the line).
        let mut output_file: Option<String> = None;
        let mut format = PrintFormat::Default;
        let mut delimiter: Option<String> = None;

        let mut specs = Vec::new();
        while idx < line.len() {
            // ── T.8: KEY=VALUE modifiers ─────────────────────────────────────
            // Detect fused `key=value` token or split `key = value` triple.
            if let Token::Word(w) = &line[idx] {
                let lw = w.to_lowercase();

                // Fused form: `file="out.csv"`, `format=csv`, `delimiter=,`
                if let Some(rest) = lw.strip_prefix("file=") {
                    output_file = Some(rest.trim_matches('"').to_string());
                    idx += 1;
                    continue;
                }
                if let Some(rest) = lw.strip_prefix("format=") {
                    format = PrintFormat::from_str(rest).unwrap_or(PrintFormat::Default);
                    idx += 1;
                    continue;
                }
                if let Some(rest) = lw.strip_prefix("delimiter=") {
                    delimiter = Some(rest.trim_matches('"').to_string());
                    idx += 1;
                    continue;
                }

                // Split form: `FILE = "out.csv"` — word, `=`, value.
                if (lw == "file" || lw == "format" || lw == "delimiter")
                    && line.get(idx + 1) == Some(&Token::Equals)
                {
                    let key = lw.clone();
                    idx += 2; // skip word + `=`
                    let val = match line.get(idx) {
                        Some(Token::Word(v)) => {
                            let s = v.trim_matches('"').to_string();
                            idx += 1;
                            s
                        }
                        Some(Token::QuotedString(v)) => {
                            let s = v.clone();
                            idx += 1;
                            s
                        }
                        Some(Token::Number(n)) => {
                            let s = format!("{n}");
                            idx += 1;
                            s
                        }
                        _ => String::new(),
                    };
                    match key.as_str() {
                        "file" => output_file = Some(val),
                        "format" => {
                            format = PrintFormat::from_str(&val).unwrap_or(PrintFormat::Default)
                        }
                        "delimiter" => delimiter = Some(val),
                        _ => {}
                    }
                    continue;
                }
            }

            // Bare `*` wildcard.
            if let Token::Word(w) = &line[idx] {
                if w == "*" {
                    specs.push(SaveSpec::All);
                    idx += 1;
                    continue;
                }
            }
            if line[idx] == Token::Star {
                specs.push(SaveSpec::All);
                idx += 1;
                continue;
            }

            // par('expr') — HSPICE computed probe expression.
            // Two forms:
            //   (a) `par('v(a)+v(b)')` — entire thing is one Word token.
            //   (b) `par ( '...' )` — lexer splits into separate tokens.
            if let Token::Word(w) = &line[idx] {
                let lw = w.to_lowercase();
                if lw.starts_with("par(") {
                    // Form (a): strip `par(` prefix and trailing `)`.
                    let inner_raw = w[4..].trim_end_matches(')');
                    let expr_str = inner_raw.trim_matches(|c: char| c == '\'').to_string();
                    specs.push(SaveSpec::ComputedExpr(expr_str));
                    idx += 1;
                    continue;
                } else if lw == "par" {
                    // Form (b): `par` is a standalone token; consume `(`, expr, `)`.
                    idx += 1;
                    if line.get(idx) == Some(&Token::LeftParen) {
                        idx += 1;
                    }
                    let mut expr_parts: Vec<String> = Vec::new();
                    while idx < line.len() && line[idx] != Token::RightParen {
                        match &line[idx] {
                            Token::Word(s) => expr_parts.push(s.trim_matches(|c: char| c == '\'').to_string()),
                            Token::Number(n) => expr_parts.push(format!("{n}")),
                            Token::Plus => expr_parts.push("+".to_string()),
                            Token::Minus => expr_parts.push("-".to_string()),
                            Token::Star => expr_parts.push("*".to_string()),
                            Token::Slash => expr_parts.push("/".to_string()),
                            Token::LeftParen => expr_parts.push("(".to_string()),
                            Token::Comma => expr_parts.push(",".to_string()),
                            _ => {}
                        }
                        idx += 1;
                    }
                    if line.get(idx) == Some(&Token::RightParen) {
                        idx += 1;
                    }
                    specs.push(SaveSpec::ComputedExpr(expr_parts.join("")));
                    continue;
                }
            }

            // V(...), I(...), P(...), W(...), N(...).
            // Determine which letter we have and whether it is a fused single-token
            // form (e.g. `v(out)`) or a split form (`v` then `(`).
            let (kind_letter, consume_kind) = match &line[idx] {
                Token::Word(w) => {
                    let lw = w.to_lowercase();
                    if lw == "v" || lw == "i" || lw == "p" || lw == "w" || lw == "n" {
                        (Some(lw), 1)
                    } else if lw.starts_with("v(")
                        || lw.starts_with("i(")
                        || lw.starts_with("p(")
                        || lw.starts_with("w(")
                        || lw.starts_with("n(")
                    {
                        // Single-token fused form: "v(out)", "p(r1)", "w(m1)", "n(out)".
                        let letter = &lw[..1];
                        let inner: String = lw[1..]
                            .trim_matches(|c: char| c == '(' || c == ')')
                            .to_string();
                        let spec = match letter {
                            "v" => {
                                if inner == "*" {
                                    SaveSpec::AllVoltages
                                } else if let Some(comma) = inner.find(',') {
                                    let (a, b) = inner.split_at(comma);
                                    SaveSpec::NodeVoltageDiff(
                                        a.to_string(),
                                        b[1..].to_string(),
                                    )
                                } else {
                                    SaveSpec::NodeVoltage(inner)
                                }
                            }
                            "i" => {
                                if inner == "*" {
                                    SaveSpec::AllCurrents
                                } else {
                                    SaveSpec::BranchCurrent(inner)
                                }
                            }
                            // T.14: P(elem) and W(elem) — power (Xyce alias W).
                            "p" | "w" => SaveSpec::Power(inner),
                            // T.14: N(node) — noise spectral density.
                            "n" => SaveSpec::NoiseDensity(inner),
                            _ => {
                                idx += 1;
                                continue;
                            }
                        };
                        specs.push(spec);
                        idx += 1;
                        continue;
                    } else {
                        (None, 0)
                    }
                }
                _ => (None, 0),
            };

            if let Some(letter) = kind_letter {
                idx += consume_kind;
                if line.get(idx) != Some(&Token::LeftParen) {
                    // Lone "v" / "i" / "p" / "w" / "n" with no argument — skip.
                    continue;
                }
                idx += 1; // consume '('

                // Parse argument: identifier, number-as-id, '*', or `n1,n2`.
                let mut name1 = String::new();
                let mut name2: Option<String> = None;
                let mut wildcard = false;
                loop {
                    match line.get(idx) {
                        Some(Token::Word(w)) if w == "*" => {
                            wildcard = true;
                            idx += 1;
                        }
                        Some(Token::Star) => {
                            wildcard = true;
                            idx += 1;
                        }
                        Some(Token::Word(w)) => {
                            if name2.is_some() {
                                name2.as_mut().unwrap().push_str(w);
                            } else if name1.is_empty() {
                                name1 = w.clone();
                            } else {
                                name1.push_str(w);
                            }
                            idx += 1;
                        }
                        Some(Token::Number(n)) => {
                            let s = if *n == (*n as u64) as f64 && *n >= 0.0 {
                                format!("{}", *n as u64)
                            } else {
                                format!("{n}")
                            };
                            if let Some(n2) = name2.as_mut() {
                                n2.push_str(&s);
                            } else if name1.is_empty() {
                                name1 = s;
                            } else {
                                name1.push_str(&s);
                            }
                            idx += 1;
                        }
                        Some(Token::Comma) => {
                            name2 = Some(String::new());
                            idx += 1;
                        }
                        Some(Token::RightParen) => {
                            idx += 1;
                            break;
                        }
                        _ => break,
                    }
                }

                let spec = match letter.as_str() {
                    "v" => {
                        if wildcard {
                            SaveSpec::AllVoltages
                        } else if let Some(n2) = name2 {
                            SaveSpec::NodeVoltageDiff(name1, n2)
                        } else {
                            SaveSpec::NodeVoltage(name1)
                        }
                    }
                    "i" => {
                        if wildcard {
                            SaveSpec::AllCurrents
                        } else {
                            SaveSpec::BranchCurrent(name1)
                        }
                    }
                    // T.14: P(elem) and W(elem) — power (Xyce alias W).
                    "p" | "w" => SaveSpec::Power(name1),
                    // T.14: N(node) — noise spectral density at node.
                    "n" => SaveSpec::NoiseDensity(name1),
                    _ => {
                        idx += 1;
                        continue;
                    }
                };
                specs.push(spec);
                continue;
            }

            // Unrecognised token — skip.
            idx += 1;
        }

        if !specs.is_empty() {
            self.netlist.saves.push(SaveDirective {
                kind: kind.to_string(),
                analysis,
                specs,
                output_file,
                format,
                delimiter,
            });
        }
        Ok(())
    }

    /// `.IF (cond) ... .ELSEIF (cond) ... .ELSE ... .ENDIF`
    ///
    /// Evaluates `cond` against the current `.PARAM` map. The condition is a
    /// brace expression `{...}`, a parenthesized expression `(...)`, or a
    /// bare expression up to end-of-line. The body of the matching branch is
    /// parsed in-place; non-matching branches are skipped (their tokens are
    /// consumed but not interpreted).
    fn parse_if(&mut self, _nested: bool) -> Result<(), SimError> {
        let mut cond = self.read_if_condition(".IF")?;

        loop {
            let cond_val = eval_expression(&cond, &self.netlist.params).unwrap_or(0.0);
            if cond_val != 0.0 {
                // Execute the body until next branch terminator.
                let term = self.execute_if_body_until_branch_end()?;
                match term {
                    IfBranchEnd::Endif => return Ok(()),
                    IfBranchEnd::Else => {
                        // Skip the .ELSE body — we already took a branch.
                        let _ = self.skip_if_body_until_branch_end()?;
                        return Ok(());
                    }
                    IfBranchEnd::Elseif => {
                        // Skip remaining ELSEIF/ELSE bodies until ENDIF.
                        loop {
                            // Consume the new condition line first.
                            self.collect_line();
                            match self.skip_if_body_until_branch_end()? {
                                IfBranchEnd::Endif => return Ok(()),
                                IfBranchEnd::Else => {
                                    let _ = self.skip_if_body_until_branch_end()?;
                                    return Ok(());
                                }
                                IfBranchEnd::Elseif => continue,
                            }
                        }
                    }
                }
            } else {
                // Skip this body and dispatch on the terminator.
                match self.skip_if_body_until_branch_end()? {
                    IfBranchEnd::Endif => return Ok(()),
                    IfBranchEnd::Else => {
                        // The .ELSE body is taken because no prior branch fired.
                        let _term = self.execute_if_body_until_branch_end()?;
                        return Ok(());
                    }
                    IfBranchEnd::Elseif => {
                        cond = self.read_if_condition(".ELSEIF")?;
                        continue;
                    }
                }
            }
        }
    }

    /// `.IFDEF PARAM_NAME` / `.IFNDEF PARAM_NAME`
    ///
    /// Checks whether `PARAM_NAME` is defined in the current `.PARAM` or
    /// `.GLOBAL_PARAM` map. When `invert` is `true` (`.IFNDEF`), the sense is
    /// flipped. Supports `.ELSE` / `.ELSEIF` / `.ENDIF` like `.IF`.
    fn parse_ifdef(&mut self, invert: bool) -> Result<(), SimError> {
        // Read the header line — first Word token is the param name.
        let line = self.collect_line();
        let param_name = line
            .iter()
            .find_map(|t| if let Token::Word(w) = t { Some(w.to_lowercase()) } else { None })
            .unwrap_or_default();

        let is_defined = self.netlist.params.contains_key(&param_name)
            || self.netlist.global_params.contains_key(&param_name);
        let mut cond_true = if invert { !is_defined } else { is_defined };

        loop {
            if cond_true {
                let term = self.execute_if_body_until_branch_end()?;
                match term {
                    IfBranchEnd::Endif => return Ok(()),
                    IfBranchEnd::Else => {
                        let _ = self.skip_if_body_until_branch_end()?;
                        return Ok(());
                    }
                    IfBranchEnd::Elseif => {
                        // Already took a branch — skip all remaining ones.
                        loop {
                            self.collect_line(); // consume elseif condition
                            match self.skip_if_body_until_branch_end()? {
                                IfBranchEnd::Endif => return Ok(()),
                                IfBranchEnd::Else => {
                                    let _ = self.skip_if_body_until_branch_end()?;
                                    return Ok(());
                                }
                                IfBranchEnd::Elseif => continue,
                            }
                        }
                    }
                }
            } else {
                match self.skip_if_body_until_branch_end()? {
                    IfBranchEnd::Endif => return Ok(()),
                    IfBranchEnd::Else => {
                        let _term = self.execute_if_body_until_branch_end()?;
                        return Ok(());
                    }
                    IfBranchEnd::Elseif => {
                        // Evaluate the .ELSEIF as a regular expression condition.
                        let cond_expr = self.read_if_condition(".ELSEIF")?;
                        let val = eval_expression(&cond_expr, &self.netlist.params).unwrap_or(0.0);
                        cond_true = val != 0.0;
                        continue;
                    }
                }
            }
        }
    }

    /// `.GLOBAL_PARAM name=val ...`
    ///
    /// Stores parameter definitions in `netlist.global_params` — a separate map
    /// from `.PARAM`. Global params are visible inside all subcircuit scopes
    /// without explicit port passing (Xyce semantics). Values are also mirrored
    /// into `netlist.params` so current-scope expressions can reference them.
    fn parse_global_param(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut i = 0;
        while i < line.len() {
            let name = match &line[i] {
                Token::Word(w) => { let n = w.clone(); i += 1; n }
                _ => { i += 1; continue; }
            };
            // Expect '='
            if i >= line.len() || line[i] != Token::Equals {
                continue;
            }
            i += 1;
            if i >= line.len() { break; }
            if let Some(val) = Self::token_to_number(&line[i]) {
                let key = name.to_lowercase();
                self.netlist.global_params.insert(key.clone(), val);
                // Mirror into top-level param scope for immediate use.
                self.netlist.params.insert(key, val);
                i += 1;
            } else {
                i += 1;
            }
        }
        Ok(())
    }

    /// Read a condition expression from the current line.
    /// Accepts `( expr )`, `{ expr }`, or a bare expression to end-of-line.
    fn read_if_condition(&mut self, ctx: &str) -> Result<Expression, SimError> {
        let line = self.collect_line();
        if line.is_empty() {
            return Err(SimError::Parse(format!("{ctx}: missing condition")));
        }
        if line[0] == Token::LeftBrace {
            let (e, _) = parse_brace_expression(&line)
                .map_err(|e| SimError::Parse(format!("{ctx}: {e}")))?;
            return Ok(e);
        }
        let cond_tokens: Vec<Token> = if line[0] == Token::LeftParen {
            // Find matching ')'.
            let mut depth = 0i32;
            let mut end = 0;
            for (i, t) in line.iter().enumerate() {
                match t {
                    Token::LeftParen => depth += 1,
                    Token::RightParen => {
                        depth -= 1;
                        if depth == 0 {
                            end = i;
                            break;
                        }
                    }
                    _ => {}
                }
            }
            line[1..end].to_vec()
        } else {
            line
        };
        parse_expression(&cond_tokens)
            .map_err(|e| SimError::Parse(format!("{ctx} condition: {e}")))
    }

    /// Execute statements until we hit `.ELSEIF`, `.ELSE`, or `.ENDIF`.
    /// Returns which terminator was found. The terminator dot token is
    /// consumed; for `.ELSEIF` the condition line is *left* on the stream.
    fn execute_if_body_until_branch_end(&mut self) -> Result<IfBranchEnd, SimError> {
        loop {
            self.skip_newlines();
            if self.at_end() {
                return Ok(IfBranchEnd::Endif);
            }
            match self.peek().clone() {
                Token::Dot(d) => match d.as_str() {
                    "elseif" => {
                        self.advance();
                        return Ok(IfBranchEnd::Elseif);
                    }
                    "else" => {
                        self.advance();
                        self.collect_line();
                        return Ok(IfBranchEnd::Else);
                    }
                    "endif" => {
                        self.advance();
                        self.collect_line();
                        return Ok(IfBranchEnd::Endif);
                    }
                    _ => {
                        let directive = d.clone();
                        self.parse_dot_command(&directive)?;
                    }
                },
                Token::Word(_) => {
                    self.parse_element()?;
                }
                _ => {
                    self.advance();
                }
            }
        }
    }

    /// Skip statements until we hit `.ELSEIF`, `.ELSE`, or `.ENDIF` at the
    /// current nesting depth.  Nested `.IF` blocks are tracked.
    fn skip_if_body_until_branch_end(&mut self) -> Result<IfBranchEnd, SimError> {
        let mut depth: usize = 0;
        loop {
            self.skip_newlines();
            if self.at_end() {
                return Ok(IfBranchEnd::Endif);
            }
            match self.peek().clone() {
                Token::Dot(d) => match d.as_str() {
                    "if" | "ifdef" | "ifndef" => {
                        depth += 1;
                        self.advance();
                        self.collect_line();
                    }
                    "endif" if depth == 0 => {
                        self.advance();
                        self.collect_line();
                        return Ok(IfBranchEnd::Endif);
                    }
                    "endif" => {
                        depth -= 1;
                        self.advance();
                        self.collect_line();
                    }
                    "elseif" if depth == 0 => {
                        self.advance();
                        return Ok(IfBranchEnd::Elseif);
                    }
                    "else" if depth == 0 => {
                        self.advance();
                        self.collect_line();
                        return Ok(IfBranchEnd::Else);
                    }
                    _ => {
                        self.advance();
                        self.collect_line();
                    }
                },
                _ => {
                    self.collect_line();
                }
            }
        }
    }

    /// `.DC srcname start stop step`
    fn parse_dc(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut params = Vec::new();

        if line.is_empty() {
            // Plain .DC with no args = DC operating point (alias for .OP).
            self.netlist.analyses.push(AnalysisStatement {
                kind: AnalysisKind::DcOp,
                params: vec![],
            });
            return Ok(());
        }

        // .DC srcname start stop step
        let mut idx = 0;

        // Source name — encode into params as ("__dc_src__<name>", 0.0).
        if idx < line.len() {
            if let Token::Word(ref src) = line[idx] {
                params.push((format!("__dc_src__{}", src.to_lowercase()), 0.0));
                idx += 1;
            }
        }

        let param_names = ["start", "stop", "step"];
        for pname in &param_names {
            if idx < line.len() {
                if let Some((val, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                    params.push(((*pname).to_string(), val));
                    idx += consumed;
                }
            }
        }

        // ── Optional inner sweep ──────────────────────────────────────────────
        // Either:  SRC2  start2 stop2 step2
        // Or:      TEMP  start2 stop2 step2
        if idx < line.len() {
            if let Token::Word(ref word) = line[idx] {
                let kw_low = word.to_lowercase();
                if kw_low == "temp" {
                    // TEMP sweep: no source_name2 needed
                    params.push(("__dc_src2__temp".to_string(), 0.0));
                    idx += 1;
                    let inner_names = ["start2", "stop2", "step2"];
                    for pname in &inner_names {
                        if idx < line.len() {
                            if let Some((val, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                                params.push(((*pname).to_string(), val));
                                idx += consumed;
                            }
                        }
                    }
                } else {
                    // Named inner source: "SRC2 start2 stop2 step2"
                    params.push((format!("__dc_src2__{}", kw_low), 0.0));
                    idx += 1;
                    let inner_names = ["start2", "stop2", "step2"];
                    for pname in &inner_names {
                        if idx < line.len() {
                            if let Some((val, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                                params.push(((*pname).to_string(), val));
                                idx += consumed;
                            }
                        }
                    }
                }
            }
        }

        // T.13: check for DATA=name keyword after sweep spec.
        // If found, look up the named .DATA block and store its name as a param.
        while idx < line.len() {
            if let Token::Word(ref kw) = line[idx] {
                let kw_low = kw.to_lowercase();
                if kw_low.starts_with("data=") {
                    let block_name = kw_low["data=".len()..].to_string();
                    params.push(("data_block".to_string(), f64::NAN));
                    // Store block name as a separate marker param using NaN sentinel.
                    // The simulator layer looks up netlist.data_blocks by this name.
                    let _ = block_name; // name stored implicitly via params tag
                    params.push(("_data_block_name_encoded".to_string(), 0.0));
                    break;
                } else if kw_low == "data" {
                    idx += 1;
                    // consume optional '='
                    if idx < line.len() && line[idx] == Token::Equals { idx += 1; }
                    if idx < line.len() {
                        if let Token::Word(ref name) = line[idx] {
                            let _block_name = name.to_lowercase();
                            params.push(("data_block".to_string(), f64::NAN));
                        }
                    }
                    break;
                }
            }
            idx += 1;
        }

        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::DcSweep,
            params,
        });
        Ok(())
    }

    /// `.TRAN tstep tstop [tstart]`
    fn parse_tran(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut params = Vec::new();

        let param_names = ["tstep", "tstop", "tstart"];
        let mut idx = 0;
        for pname in &param_names {
            if idx < line.len() {
                if let Some((val, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                    params.push(((*pname).to_string(), val));
                    idx += consumed;
                }
            }
        }

        // T.13: check for DATA=name keyword after time params.
        while idx < line.len() {
            if let Token::Word(ref kw) = line[idx] {
                let kw_low = kw.to_lowercase();
                if kw_low.starts_with("data=") {
                    params.push(("data_block".to_string(), f64::NAN));
                    break;
                } else if kw_low == "data" {
                    idx += 1;
                    if idx < line.len() && line[idx] == Token::Equals { idx += 1; }
                    if idx < line.len() {
                        if let Token::Word(_) = line[idx] {
                            params.push(("data_block".to_string(), f64::NAN));
                        }
                    }
                    break;
                }
            }
            idx += 1;
        }

        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Tran,
            params,
        });
        Ok(())
    }

    /// `.AC type npoints fstart fstop`
    fn parse_ac(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut params = Vec::new();
        let mut idx = 0;

        // Sweep type: DEC, OCT, LIN — O.3: store as sweep_type param (0=lin,1=dec,2=oct).
        if idx < line.len() {
            if let Token::Word(ref sweep_str) = line[idx] {
                let st = match sweep_str.to_lowercase().as_str() {
                    "dec" | "decade" => 1.0,
                    "oct" | "octave" => 2.0,
                    _ => 0.0,
                };
                params.push(("sweep_type".to_string(), st));
                idx += 1;
            }
        }
        if !params.iter().any(|(k, _)| k == "sweep_type") {
            params.push(("sweep_type".to_string(), 1.0)); // default: decade
        }

        let param_names = ["npoints", "fstart", "fstop"];
        for pname in &param_names {
            if idx < line.len() {
                if let Some((val, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                    params.push(((*pname).to_string(), val));
                    idx += consumed;
                }
            }
        }

        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Ac,
            params,
        });
        Ok(())
    }

    /// `.OP`
    fn parse_op(&mut self) -> Result<(), SimError> {
        self.collect_line(); // consume any trailing tokens
        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::DcOp,
            params: vec![],
        });
        Ok(())
    }

    /// `.NOISE V(out) Vsrc sweep npoints fstart fstop`
    ///
    /// Syntax: `.NOISE V(output_node) input_source DEC|OCT|LIN npoints fstart fstop`
    ///
    /// The output node is parsed from the `V(...)` form. The input source is the
    /// bare device name (e.g. `V1`). Numeric args follow AC sweep conventions.
    fn parse_noise(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut idx = 0;

        // ── Parse V(output_node) ──────────────────────────────────────────────
        let output_node: String = if idx < line.len() {
            match &line[idx] {
                // Word token that starts with 'v' — could be "v(out)" as one token
                // or it may be tokenized as Word("v"), LeftParen, Word("out"), RightParen.
                Token::Word(w) if w.to_lowercase().starts_with('v') => {
                    // Check if the whole `v(node)` was lexed as a single word.
                    let w = w.clone();
                    if w.contains('(') && w.contains(')') {
                        idx += 1;
                        // Extract inner node name: "v(out)" -> "out"
                        w.trim_start_matches(|c: char| c.to_lowercase().next() == Some('v'))
                            .trim_start_matches('(')
                            .trim_end_matches(')')
                            .to_string()
                    } else {
                        // Separate tokens: Word("v"), LeftParen, Word("out"), RightParen
                        idx += 1; // skip "v"
                        if idx < line.len() && line[idx] == Token::LeftParen {
                            idx += 1; // skip '('
                        }
                        let node = if idx < line.len() {
                            if let Token::Word(n) = &line[idx] {
                                let n = n.clone();
                                idx += 1;
                                n
                            } else {
                                String::new()
                            }
                        } else {
                            String::new()
                        };
                        if idx < line.len() && line[idx] == Token::RightParen {
                            idx += 1; // skip ')'
                        }
                        node
                    }
                }
                _ => {
                    // Unrecognised form — default empty; analysis still recorded.
                    String::new()
                }
            }
        } else {
            String::new()
        };

        // ── Parse input source name ───────────────────────────────────────────
        let input_source: String = if idx < line.len() {
            if let Token::Word(w) = &line[idx] {
                let s = w.clone();
                idx += 1;
                s
            } else {
                String::new()
            }
        } else {
            String::new()
        };

        // ── Parse sweep type (DEC / OCT / LIN) ───────────────────────────────
        let sweep_type: String = if idx < line.len() {
            if let Token::Word(w) = &line[idx] {
                let s = w.to_lowercase();
                idx += 1;
                s
            } else {
                "dec".to_string()
            }
        } else {
            "dec".to_string()
        };

        // ── Parse npoints, fstart, fstop ─────────────────────────────────────
        let npoints = if idx < line.len() {
            let n = Self::token_to_number(&line[idx]).unwrap_or(10.0) as usize;
            idx += 1;
            n
        } else {
            10
        };
        let fstart = if idx < line.len() {
            let v = Self::token_to_number(&line[idx]).unwrap_or(1.0);
            idx += 1;
            v
        } else {
            1.0
        };
        let fstop = if idx < line.len() {
            Self::token_to_number(&line[idx]).unwrap_or(1e9)
        } else {
            1e9
        };

        // Store the fully-parsed noise statement.
        self.netlist.noise_statements.push(NoiseStatement {
            output_node,
            input_source,
            sweep_type,
            npoints,
            fstart,
            fstop,
        });

        // Also record in the generic analyses list so analysis dispatchers can
        // detect the presence of a .NOISE command.
        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Noise,
            params: vec![
                ("npoints".to_string(), npoints as f64),
                ("fstart".to_string(), fstart),
                ("fstop".to_string(), fstop),
            ],
        });
        Ok(())
    }

    /// `.OPTIONS key=value ...`
    ///
    /// Recognized keys: abstol, reltol, vntol, chgtol, pivtol, pivrel, gmin,
    /// itl1, itl2, itl4, itl5, itl6 (alias: srcsteps), gminsteps, homotopy,
    /// method, maxord, trtol, temp, tnom, vnstep.
    /// Unknown keys are silently ignored. Multiple `.OPTIONS` lines accumulate
    /// (later overrides earlier).
    fn parse_options(&mut self) -> Result<(), SimError> {
        use bigospice_core::IntegrationMethod;
        let line = self.collect_line();
        let mut i = 0;

        // T.7: Xyce uses `.OPTIONS CATEGORY key=val` syntax.
        // If the first token is a known category keyword, consume it and
        // continue parsing key=val pairs (routing to the right struct).
        // Unknown categories are silently accepted (forward compat).
        const OPTION_CATEGORIES: &[&str] = &[
            "nonlin", "linsol", "timeint", "output", "device",
            "homotopy", "sensitivity", "solver", "restart",
        ];
        if i < line.len() {
            if let Token::Word(ref first) = line[i] {
                let lf = first.to_lowercase();
                if OPTION_CATEGORIES.contains(&lf.as_str()) {
                    // Consume the category token — key=val pairs follow normally.
                    i += 1;
                }
            }
        }

        while i < line.len() {
            if let Token::Word(ref key) = line[i] {
                let key = key.to_lowercase();
                i += 1;
                if i < line.len() && line[i] == Token::Equals {
                    i += 1;
                    if i < line.len() {
                        match key.as_str() {
                            "method" => {
                                if let Token::Word(ref method_str) = line[i] {
                                    self.netlist.options.method = match method_str.to_lowercase().as_str() {
                                        "gear" => IntegrationMethod::Gear,
                                        "be" => IntegrationMethod::Be,
                                        _ => IntegrationMethod::Trap,
                                    };
                                }
                                i += 1;
                            }
                            // SOLVER — linear solver selection (KLU or default SparseLu)
                            "solver" => {
                                if let Token::Word(ref s) = line[i] {
                                    let (choice, kind) = match s.to_lowercase().as_str() {
                                        "klu" => (
                                            bigospice_core::LinSolverChoice::Klu,
                                            bigospice_core::LinSolverKind::Klu,
                                        ),
                                        "dense" => (
                                            bigospice_core::LinSolverChoice::SparseLu,
                                            bigospice_core::LinSolverKind::Dense,
                                        ),
                                        _ => (
                                            bigospice_core::LinSolverChoice::SparseLu,
                                            bigospice_core::LinSolverKind::Sparse,
                                        ),
                                    };
                                    self.netlist.options.lin_solver = choice;
                                    self.netlist.options.linsol_kind = kind;
                                }
                                i += 1;
                            }
                            // FILETYPE / RAWFMT — word value (ASCII or BINARY)
                            "filetype" | "rawfmt" => {
                                if let Token::Word(ref fmt_str) = line[i] {
                                    self.netlist.options.raw_fmt = match fmt_str.to_lowercase().as_str() {
                                        "ascii" => bigospice_core::RawFmt::Ascii,
                                        _ => bigospice_core::RawFmt::Binary,
                                    };
                                }
                                i += 1;
                            }
                            _ => {
                                if let Some(val) = Self::token_to_number(&line[i]) {
                                    match key.as_str() {
                                        "abstol" => self.netlist.options.abstol = val,
                                        "reltol" => self.netlist.options.reltol = val,
                                        "vntol" => self.netlist.options.vntol = val,
                                        "chgtol" => self.netlist.options.chgtol = val,
                                        "pivtol" | "pivot_tol" => self.netlist.options.pivtol = val,
                                        "pivrel" => self.netlist.options.pivrel = val,
                                        "gmin" => self.netlist.options.gmin = val,
                                        "itl1" => self.netlist.options.itl1 = val as usize,
                                        "itl2" => self.netlist.options.itl2 = val as usize,
                                        "itl3" => self.netlist.options.itl3 = val as usize,
                                        "itl4" => self.netlist.options.itl4 = val as usize,
                                        "itl5" => self.netlist.options.itl5 = val as usize,
                                        "itl6" | "srcsteps" => self.netlist.options.itl6 = val as usize,
                                        "gminsteps" => self.netlist.options.gminsteps = val as usize,
                                        "ramptime" => self.netlist.options.ramptime = val,
                                        "homotopy" => self.netlist.options.homotopy = val != 0.0,
                                        "acct" => self.netlist.options.acct = val != 0.0,
                                        "maxord" => self.netlist.options.maxord = val as u8,
                                        "trtol" => self.netlist.options.trtol = val,
                                        "temp" => self.netlist.options.temp = val,
                                        "tnom" => self.netlist.options.tnom = val,
                                        "vnstep" => self.netlist.options.vnstep = val,
                                        "numdgt" => self.netlist.options.numdgt = val as usize,
                                        "limpts" => self.netlist.options.limpts = val as usize,
                                        "scale" => self.netlist.options.scale = val,
                                        "defad" => self.netlist.options.defad = val,
                                        "defas" => self.netlist.options.defas = val,
                                        "defl" => self.netlist.options.defl = val,
                                        "defw" => self.netlist.options.defw = val,
                                        "keepopinfo" => self.netlist.options.keepopinfo = val != 0.0,
                                        _ => {} // unknown key — silently ignored
                                    }
                                    i += 1;
                                } else {
                                    i += 1;
                                }
                            }
                        }
                    }
                }
            } else {
                i += 1;
            }
        }
        Ok(())
    }

    /// `.DATA datname param1 param2 ...` rows ... `.ENDDATA`
    ///
    /// Stores a [`DataBlock`] in `netlist.data_blocks`.
    fn parse_data(&mut self) -> Result<(), SimError> {

        // First token on the same line as `.DATA` is the block name.
        let name = match self.peek().clone() {
            Token::Word(s) => { self.advance(); s }
            _ => return Err(SimError::Parse(".DATA: expected block name".into())),
        };

        // Remaining tokens on the header line are parameter names.
        let header = self.collect_line();
        let params: Vec<String> = header
            .iter()
            .filter_map(|t| match t {
                Token::Word(s) => Some(s.clone()),
                _ => None,
            })
            .collect();

        // Collect rows of numeric data until `.ENDDATA`.
        let mut rows: Vec<Vec<f64>> = Vec::new();
        loop {
            self.skip_newlines();
            if self.at_end() {
                break;
            }
            // Check for .ENDDATA directive.
            if let Token::Dot(d) = self.peek().clone() {
                if d == "enddata" {
                    self.advance();
                    self.collect_line();
                    break;
                }
            }
            // Parse a row of numbers.
            let row_tokens = self.collect_line();
            let row: Vec<f64> = row_tokens
                .iter()
                .filter_map(|t| Self::token_to_number(t))
                .collect();
            if !row.is_empty() {
                rows.push(row);
            }
        }

        self.netlist.data_blocks.push(DataBlock { name, params, rows });
        Ok(())
    }

    /// `.control` ... `.endc`
    ///
    /// Collects all lines between `.control` and `.endc` as raw
    /// [`ControlStatement`]s and appends a [`ControlBlock`] to
    /// `netlist.control_blocks`.
    fn parse_control_block(&mut self) -> Result<(), SimError> {
        // Consume rest of the `.control` header line (usually empty).
        self.collect_line();

        let mut block = ControlBlock::default();

        loop {
            self.skip_newlines();
            if self.at_end() {
                break;
            }

            // Check for `.endc` terminator.
            if let Token::Dot(ref d) = self.peek().clone() {
                if d == "endc" {
                    self.advance();       // consume Dot(".endc")
                    self.collect_line();  // consume rest of line
                    break;
                }
                // Other dot-directives inside the block are kept as raw text.
                // Fall through to collect_line below.
            }

            // Reconstruct a single line from the token stream.
            let line_tokens = self.collect_line();
            if line_tokens.is_empty() {
                continue;
            }
            let raw = tokens_to_raw_line(&line_tokens);
            if !raw.trim().is_empty() {
                block.lines.push(ControlStatement { raw });
            }
        }

        self.netlist.control_blocks.push(block);
        Ok(())
    }

    /// `.ALTER [title]` — O.2: prevent .ALTER block content from polluting circuit parsing.
    ///
    /// Collects the block until the next `.ALTER`, `.ENDALTER`, `.END`, or EOF.
    /// Full analysis-driver integration (re-running with patched params) is deferred;
    /// this stub ensures the parser doesn't misinterpret alter-block lines as elements.
    fn parse_alter(&mut self) -> Result<(), SimError> {
        // Consume the optional title line.
        self.collect_line();
        loop {
            self.skip_newlines();
            match self.peek().clone() {
                Token::Eof => break,
                Token::Dot(ref d) => {
                    let d_low = d.to_lowercase();
                    if matches!(d_low.as_str(), "alter" | "endalter" | "end") {
                        break;
                    }
                    self.collect_line();
                }
                _ => { self.collect_line(); }
            }
        }
        Ok(())
    }

    /// `.IC v(node)=value ...`
    ///
    /// Stores initial condition pairs in `netlist.initial_conditions`.
    /// Only the single-node form `v(name)=value` is supported.
    /// TODO: two-node differential form `v(a,b)=value` is not yet supported.
    fn parse_ic(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        self.netlist.initial_conditions.extend(Self::parse_v_assign_pairs(&line));
        Ok(())
    }

    /// `.NODESET v(node)=value ...`
    ///
    /// Stores solver-hint biases in `netlist.node_sets`.
    /// TODO: two-node differential form `v(a,b)=value` is not yet supported.
    fn parse_nodeset(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        self.netlist.node_sets.extend(Self::parse_v_assign_pairs(&line));
        Ok(())
    }

    /// Parse `v(node)=value` pairs from a token slice.
    ///
    /// The lexer tokenizes `v(out)=2.5` as:
    ///   `Word("v")`, `LeftParen`, `Word("out")`, `RightParen`, `Equals`, `Number(2.5)`
    ///
    /// Also accepts a `{expr}` brace expression in the value slot:
    ///   `v(out)={2+3}` — evaluated against an empty param env.
    ///
    /// Returns a list of `(node_name, voltage)` pairs found.
    fn parse_v_assign_pairs(tokens: &[Token]) -> Vec<(String, f64)> {
        let empty_params = ahash::AHashMap::new();
        let mut result = Vec::new();
        let mut i = 0;
        while i < tokens.len() {
            // Match the pattern:
            //   Word("v") LeftParen (Word|Number)(node) RightParen Equals (Number|LeftBrace)(val)
            if let Token::Word(ref w) = tokens[i] {
                if w == "v" && i + 4 < tokens.len() {
                    if matches!(tokens[i + 1], Token::LeftParen) {
                        // Node position may be Word or Number.
                        let node_opt = match &tokens[i + 2] {
                            Token::Word(n) => Some(n.clone()),
                            Token::Number(n) => {
                                if *n == (*n as u64) as f64 && *n >= 0.0 {
                                    Some(format!("{}", *n as u64))
                                } else {
                                    Some(format!("{n}"))
                                }
                            }
                            _ => None,
                        };
                        if let Some(node) = node_opt {
                            if matches!(tokens[i + 3], Token::RightParen)
                                && tokens[i + 4] == Token::Equals
                                && i + 5 < tokens.len()
                            {
                                // Value may be a plain number or a brace expression.
                                if tokens[i + 5] == Token::LeftBrace {
                                    if let Ok((expr, consumed)) =
                                        parse_brace_expression(&tokens[i + 5..])
                                    {
                                        if let Ok(val) =
                                            eval_expression(&expr, &empty_params)
                                        {
                                            result.push((node, val));
                                            i += 5 + consumed;
                                            continue;
                                        }
                                    }
                                } else if let Some(val) =
                                    Self::token_to_number(&tokens[i + 5])
                                {
                                    result.push((node, val));
                                    i += 6;
                                    continue;
                                }
                            }
                        }
                    }
                }
            }
            i += 1;
        }
        result
    }

    /// `.GLOBAL node1 node2 ...`
    ///
    /// Stores global node names (lowercased) in `netlist.globals`.
    /// Global nodes are not mangled during subcircuit expansion.
    fn parse_global(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        for tok in &line {
            if let Token::Word(s) = tok {
                self.netlist.globals.push(s.clone());
            }
        }
        Ok(())
    }

    /// `.TEMP t1 [t2 ...]`
    ///
    /// Values are in Celsius; converted to Kelvin (+ 273.15) before storage.
    /// Multiple `.TEMP` lines accumulate.
    ///
    /// TODO(phase-1.3): drive multi-temp sweep from this list.
    fn parse_temp(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        for tok in &line {
            if let Some(celsius) = Self::token_to_number(tok) {
                self.netlist.temperatures.push(celsius + 273.15);
            }
        }
        Ok(())
    }

    /// `.MEAS` / `.MEASURE` analysis_type name kind signal [options...]
    ///
    /// Collects the raw line tokens (converted to lowercase strings) and stores
    /// them in `netlist.measures` for post-simulation evaluation.  Unknown or
    /// malformed lines are silently skipped — the evaluator handles errors at
    /// runtime.
    fn parse_meas(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        // Convert each token back to a lowercase string representation.
        let tokens: Vec<String> = line
            .iter()
            .flat_map(|tok| token_to_meas_strings(tok))
            .collect();
        if !tokens.is_empty() {
            self.netlist.measures.push(MeasureStatement { tokens });
        }
        Ok(())
    }

    /// `.CONNECT net1 net2` — short-circuit two nets (W.6, Xyce/HSPICE compat).
    ///
    /// After `build_circuit`, both nets are merged: all devices connected to
    /// `net2` are reconnected to `net1`.  Malformed lines are silently ignored.
    fn parse_connect(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut words = line.iter().filter_map(|tok| {
            if let Token::Word(s) = tok { Some(s.clone()) } else { None }
        });
        if let (Some(net_a), Some(net_b)) = (words.next(), words.next()) {
            if !net_a.is_empty() && !net_b.is_empty() {
                self.netlist.connect_directives.push((net_a, net_b));
            }
        }
        Ok(())
    }

    /// `.EXTRACT [TRAN|AC|DC] label=expr` (HSPICE W.5) — post-simulation measurement.
    ///
    /// Stores each `label=expression` pair as an `ExtractSpec` in
    /// `netlist.extract_specs`.  Malformed entries are silently skipped.
    ///
    /// The HSPICE syntax is:
    /// ```text
    /// .EXTRACT TRAN vmax=ymax(v(out)) vmin=ymin(v(out)) vswing=par('vmax-vmin')
    /// ```
    /// Each `label=expr` pair is parsed by scanning for `Word Equals` patterns.
    /// Expression tokens are collected until the next `Word Equals` pair or EOL.
    fn parse_extract(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        if line.is_empty() {
            return Ok(());
        }
        // Optional analysis type as first Word token.
        let mut idx = 0;
        let analysis_type = if let Some(Token::Word(s)) = line.first() {
            match s.to_lowercase().as_str() {
                "tran" | "ac" | "dc" => {
                    idx = 1;
                    s.to_lowercase()
                }
                _ => "tran".to_string(),
            }
        } else {
            "tran".to_string()
        };
        // Scan for label=expr pairs: Word(label) Equals <expr_tokens…>
        // Expression tokens are collected until the next Word followed by Equals, or EOL.
        while idx < line.len() {
            if let Token::Word(label) = &line[idx] {
                if idx + 1 < line.len() && line[idx + 1] == Token::Equals {
                    let label = label.clone();
                    idx += 2; // consume label and '='
                    let mut expr_parts: Vec<String> = Vec::new();
                    while idx < line.len() {
                        // Stop when we see the start of the next label=… pair.
                        if matches!(&line[idx], Token::Word(_))
                            && idx + 1 < line.len()
                            && line[idx + 1] == Token::Equals
                        {
                            break;
                        }
                        expr_parts.push(line[idx].to_string());
                        idx += 1;
                    }
                    let expr: String = expr_parts.join("");
                    if !label.is_empty() && !expr.is_empty() {
                        self.netlist.extract_specs.push(ExtractSpec {
                            analysis: analysis_type.clone(),
                            label,
                            expr,
                        });
                    }
                } else {
                    idx += 1;
                }
            } else {
                idx += 1;
            }
        }
        Ok(())
    }

    /// `.ROL LIFETIME=<t> [TEMP=<t>] [EM=<0|1>] [NBTI=<0|1>] [HCI=<0|1>]`
    ///
    /// Parses a reliability/aging analysis directive (W.4, Xyce-compatible).
    /// Stores the result in `self.netlist.rol_config`; a second `.ROL` line
    /// overwrites the first (last-write wins, matching `.OPTIONS` semantics).
    fn parse_rol(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut cfg = bigospice_core::RolConfig::default();
        let mut i = 0;
        while i < line.len() {
            if let Token::Word(ref key) = line[i] {
                let key = key.to_lowercase();
                i += 1;
                if i < line.len() && line[i] == Token::Equals {
                    i += 1;
                    if i < line.len() {
                        match key.as_str() {
                            "lifetime" => {
                                if let Some(v) = Self::token_to_number(&line[i]) {
                                    cfg.lifetime = v;
                                }
                                i += 1;
                            }
                            "temp" => {
                                if let Some(v) = Self::token_to_number(&line[i]) {
                                    // Accept either Celsius (small values) or Kelvin.
                                    // Treat values < 200 as Celsius and convert.
                                    cfg.temp = if v < 200.0 { v + 273.15 } else { v };
                                }
                                i += 1;
                            }
                            "em" => {
                                if let Some(v) = Self::token_to_number(&line[i]) {
                                    cfg.em_enabled = v != 0.0;
                                }
                                i += 1;
                            }
                            "nbti" => {
                                if let Some(v) = Self::token_to_number(&line[i]) {
                                    cfg.nbti_enabled = v != 0.0;
                                }
                                i += 1;
                            }
                            "hci" => {
                                if let Some(v) = Self::token_to_number(&line[i]) {
                                    cfg.hci_enabled = v != 0.0;
                                }
                                i += 1;
                            }
                            _ => { i += 1; }
                        }
                    }
                }
            } else {
                i += 1;
            }
        }
        self.netlist.rol_config = Some(cfg);
        Ok(())
    }

    /// `.SUBCKT name port1 port2 ... [PARAMS: key=val ...]` ... `.ENDS`
    fn parse_subckt(&mut self) -> Result<(), SimError> {
        let name = match self.peek().clone() {
            Token::Word(s) => { self.advance(); s }
            _ => return Err(SimError::Parse("expected subcircuit name".into())),
        };

        // Collect header tokens until end of line.
        let port_tokens = self.collect_line();

        // Split at the first `params` word (the lexer strips the trailing `:`
        // so `PARAMS:` arrives as `Word("params")`).
        let params_keyword_idx = port_tokens.iter().position(|t| {
            matches!(t, Token::Word(w) if w == "params")
        });

        let (port_slice, kv_slice): (&[Token], &[Token]) = if let Some(idx) = params_keyword_idx {
            (&port_tokens[..idx], &port_tokens[idx + 1..])
        } else {
            (port_tokens.as_slice(), &[])
        };

        let ports: Vec<String> = port_slice
            .iter()
            .filter_map(|t| match t {
                Token::Word(s) => Some(s.clone()),
                _ => None,
            })
            .collect();

        // Parse default key=value params from the header.
        let mut default_params = Vec::new();
        let mut ki = 0;
        while ki < kv_slice.len() {
            if let Some((k, v, consumed)) =
                Self::try_parse_kv_param_with(&kv_slice[ki..], &self.netlist.params)
            {
                default_params.push((k, v));
                ki += consumed;
            } else {
                ki += 1;
            }
        }

        // Collect body elements until .ENDS.
        let mut body = Vec::new();
        let mut nested_instances: Vec<PendingSubcktInstance> = Vec::new();
        loop {
            self.skip_newlines();
            if self.at_end() {
                break;
            }
            match self.peek().clone() {
                Token::Dot(ref d) if d == "ends" || d == "end" => {
                    self.advance();
                    self.collect_line();
                    break;
                }
                Token::Word(ref w) => {
                    let first_char = w.chars().next().unwrap_or('\0');
                    if first_char == 'x' {
                        // Nested subcircuit instance inside this subckt body.
                        let inst_name = w.clone();
                        self.advance();
                        let line = self.collect_line();
                        if let Some(inst) = Self::parse_subckt_instance_from_line(&inst_name, &line)? {
                            nested_instances.push(inst);
                        }
                    } else {
                        // Parse as regular element.
                        let elem = self.parse_element_line()?;
                        if let Some(e) = elem {
                            body.push(e);
                        }
                    }
                }
                _ => {
                    self.collect_line();
                }
            }
        }

        self.netlist.subcircuits.push(SubcircuitDef { name, ports, default_params, body, nested_instances });
        Ok(())
    }

    // -----------------------------------------------------------------------
    // Element parsing
    // -----------------------------------------------------------------------

    /// Parse an element instance line and add it to the netlist.
    fn parse_element(&mut self) -> Result<(), SimError> {
        let elem = self.parse_element_line()?;
        if let Some(e) = elem {
            self.netlist.elements.push(e);
        }
        Ok(())
    }

    /// Parse an element line and return the statement (or None if not recognized).
    fn parse_element_line(&mut self) -> Result<Option<ElementStatement>, SimError> {
        let name = match self.peek().clone() {
            Token::Word(s) => { self.advance(); s }
            _ => {
                self.collect_line();
                return Ok(None);
            }
        };

        if name.is_empty() {
            self.collect_line();
            return Ok(None);
        }

        let first_char = name.chars().next().unwrap();
        let line = self.collect_line();

        match first_char {
            'r' => self.parse_two_terminal(&name, DeviceKind::Resistor, &line, "resistance"),
            'c' => self.parse_two_terminal(&name, DeviceKind::Capacitor, &line, "capacitance"),
            'l' => self.parse_two_terminal(&name, DeviceKind::Inductor, &line, "inductance"),
            'v' => self.parse_source(&name, DeviceKind::VoltageSource, &line),
            'i' => self.parse_source(&name, DeviceKind::CurrentSource, &line),
            'd' => self.parse_diode(&name, &line),
            'm' => self.parse_mosfet(&name, &line),
            'e' => self.parse_vcvs(&name, &line),
            'g' => self.parse_vccs(&name, &line),
            'q' => self.parse_bjt(&name, &line),
            'j' => self.parse_jfet(&name, &line),
            'z' => self.parse_mesfet(&name, &line),
            't' => self.parse_tline(&name, &line),
            'o' => self.parse_ltra(&name, &line),
            'u' => self.parse_urc(&name, &line),
            'w' => self.parse_w_element(&name, &line),
            'p' if name.starts_with("port") => self.parse_port(&name, &line),
            'k' => {
                // Mutual inductance: K<name> L1_name L2_name coupling
                self.parse_k_element(&name, &line)?;
                Ok(None) // stored in pending_k_elements; resolved in build_circuit
            }
            'b' => {
                // B-source must be handled specially because it carries an
                // expression AST that cannot fit in ElementStatement params.
                // We parse it and store it directly in the netlist's bsource
                // pending list to be wired during build_circuit.
                self.parse_bsource_pending(&name, &line)?;
                Ok(None) // already stored; don't add to elements
            }
            'x' => {
                // Subcircuit instance: X<name> node1 node2 ... subckt_name
                self.parse_subckt_instance_top(&name, &line)?;
                Ok(None) // stored in pending_subckt_instances; don't add to elements
            }
            'h' => self.parse_ccvs(&name, &line),
            'f' => self.parse_cccs(&name, &line),
            'a' => {
                // XSPICE A-device: A<name> [in1 in2 ...] [out1 out2 ...] model_name
                // or with () analog port syntax: A<name> (in1) (out1) model_name
                self.parse_a_device_pending(&name, &line)?;
                Ok(None) // stored in pending_a_devices; don't add to elements
            }
            _ => {
                // Unknown element prefix — skip.
                Ok(None)
            }
        }
    }

    /// Parse a top-level subcircuit instance line and push to `pending_subckt_instances`.
    ///
    /// Syntax: `X<name> node1 node2 ... subckt_name`
    /// The last token on the line is the subcircuit definition name.
    fn parse_subckt_instance_top(&mut self, name: &str, line: &[Token]) -> Result<(), SimError> {
        if let Some(inst) = Self::parse_subckt_instance_from_line(name, line)? {
            self.netlist.pending_subckt_instances.push(inst);
        }
        Ok(())
    }

    /// Pure helper: parse `node1 node2 ... subckt_name` tokens into a `PendingSubcktInstance`.
    ///
    /// Returns `None` if the line is empty (silently ignored).
    fn parse_subckt_instance_from_line(
        name: &str,
        line: &[Token],
    ) -> Result<Option<PendingSubcktInstance>, SimError> {
        // Collect tokens that are node names or the subckt definition name.
        // Skip:
        //   - `PARAMS:` keyword (arrives as Word("params") after lexer strips ':')
        //   - key=value pairs (Word Equals ...) — those are instance parameters
        let mut words: Vec<String> = Vec::new();
        let mut i = 0;
        while i < line.len() {
            match &line[i] {
                // Skip the PARAMS keyword.
                Token::Word(w) if w == "params" => { i += 1; }
                // Skip key=value pairs.
                Token::Word(_) if i + 1 < line.len() && line[i + 1] == Token::Equals => {
                    // Consume: Word Equals <value or brace>
                    i += 2; // skip key and '='
                    // Skip the value token(s): brace expr or number.
                    if i < line.len() {
                        if line[i] == Token::LeftBrace {
                            // Consume brace-enclosed expression.
                            let mut depth = 0usize;
                            while i < line.len() {
                                match &line[i] {
                                    Token::LeftBrace => { depth += 1; i += 1; }
                                    Token::RightBrace => {
                                        depth -= 1; i += 1;
                                        if depth == 0 { break; }
                                    }
                                    _ => { i += 1; }
                                }
                            }
                        } else {
                            // Skip number (possibly signed).
                            if matches!(&line[i], Token::Minus | Token::Plus)
                                && i + 1 < line.len()
                            {
                                i += 2;
                            } else {
                                i += 1;
                            }
                        }
                    }
                }
                Token::Word(s) => { words.push(s.clone()); i += 1; }
                Token::Number(n) => {
                    // Numeric node names like "0", "1".
                    if *n == (*n as u64) as f64 && *n >= 0.0 {
                        words.push(format!("{}", *n as u64));
                    } else {
                        words.push(format!("{n}"));
                    }
                    i += 1;
                }
                _ => { i += 1; }
            }
        }

        if words.is_empty() {
            return Ok(None);
        }

        // Last word is the subcircuit definition name; everything before it are connection nodes.
        let subckt_name = words.last().unwrap().clone();
        let nodes: Vec<String> = words[..words.len() - 1].to_vec();

        Ok(Some(PendingSubcktInstance {
            instance_name: name.to_string(),
            subckt_name,
            nodes,
        }))
    }

    /// Expand all pending subcircuit instances into flat `ElementStatement`s.
    ///
    /// Appends the resulting elements to `dest`.  Recursively expands nested
    /// X instances found in subcircuit bodies.
    ///
    /// `expansion_stack` tracks subcircuit names currently being expanded for
    /// cycle detection.
    fn expand_instances(
        instances: &[PendingSubcktInstance],
        defs: &AHashMap<String, &SubcircuitDef>,
        globals: &[String],
        dest: &mut Vec<ElementStatement>,
        expansion_stack: &mut Vec<String>,
    ) -> Result<(), SimError> {
        for inst in instances {
            let def_name = inst.subckt_name.to_lowercase();

            // Cycle detection.
            if expansion_stack.iter().any(|s| s == &def_name) {
                return Err(SimError::Parse(format!(
                    "subcircuit cycle detected: {}",
                    def_name
                )));
            }

            let def = defs.get(&def_name).ok_or_else(|| {
                SimError::Parse(format!(
                    "subcircuit '{}' not defined (referenced by instance '{}')",
                    def_name, inst.instance_name
                ))
            })?;

            if inst.nodes.len() != def.ports.len() {
                return Err(SimError::Parse(format!(
                    "subcircuit '{}' expects {} ports, got {} in instance '{}'",
                    def_name,
                    def.ports.len(),
                    inst.nodes.len(),
                    inst.instance_name
                )));
            }

            // Build node-mangling map.
            // Port nodes map to the parent connection nodes.
            // Internal nodes map to `instance_name.node_name`.
            // Node "0", "gnd", and globals bypass mangling.
            let mut node_map: AHashMap<String, String> = AHashMap::new();
            for (port, conn) in def.ports.iter().zip(inst.nodes.iter()) {
                node_map.insert(port.clone(), conn.clone());
            }

            let mangle = |node: &str| -> String {
                let lower = node.to_lowercase();
                if lower == "0" || lower == "gnd" {
                    return lower;
                }
                if globals.iter().any(|g| g == &lower) {
                    return lower;
                }
                if let Some(mapped) = node_map.get(&lower) {
                    return mapped.clone();
                }
                // Internal node — prepend instance name.
                format!("{}.{}", inst.instance_name, lower)
            };

            // Clone and mangle body elements.
            for elem in &def.body {
                let mangled_nodes: Vec<String> = elem.nodes.iter().map(|n| mangle(n)).collect();
                let mangled_name = format!("{}.{}", inst.instance_name, elem.name);
                dest.push(ElementStatement {
                    name: mangled_name,
                    kind: elem.kind,
                    nodes: mangled_nodes,
                    value: elem.value,
                    model_name: elem.model_name.clone(),
                    params: elem.params.clone(),
                });
            }

            // Recursively expand nested instances (e.g. X inside this subckt body).
            if !def.nested_instances.is_empty() {
                // Mangle the nested instances' connection nodes.
                let mangled_nested: Vec<PendingSubcktInstance> = def
                    .nested_instances
                    .iter()
                    .map(|ni| PendingSubcktInstance {
                        instance_name: format!("{}.{}", inst.instance_name, ni.instance_name),
                        subckt_name: ni.subckt_name.clone(),
                        nodes: ni.nodes.iter().map(|n| mangle(n)).collect(),
                    })
                    .collect();

                expansion_stack.push(def_name.clone());
                Self::expand_instances(&mangled_nested, defs, globals, dest, expansion_stack)?;
                expansion_stack.pop();
            }
        }
        Ok(())
    }

    /// Parse a two-terminal element: `name node+ node- value [params]`.
    fn parse_two_terminal(
        &self,
        name: &str,
        kind: DeviceKind,
        line: &[Token],
        value_param: &str,
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 2 {
            return Err(SimError::Parse(format!(
                "element '{name}' needs at least 2 nodes"
            )));
        }

        let node_p = Self::token_to_node_name(&line[0])?;
        let node_n = Self::token_to_node_name(&line[1])?;

        let params_env = &self.netlist.params;
        let mut value = None;
        let mut params = Vec::new();
        let mut idx = 2;

        // Try to read a bare value or {expr}.
        if idx < line.len() {
            if let Some((v, consumed)) = Self::tokens_to_numeric_or_brace(&line[idx..], params_env) {
                value = Some(v);
                idx += consumed;
            }
        }

        // Read key=value (or key={expr}) params.
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param_with(&line[idx..], params_env) {
                params.push((k, v));
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        // If we got a bare value, also add it as a named param.
        if let Some(v) = value {
            params.push((value_param.to_string(), v));
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind,
            nodes: vec![node_p, node_n],
            value,
            model_name: None,
            params,
        }))
    }

    /// Parse a voltage/current source: `name node+ node- [DC value] [AC mag [phase]] [PULSE(...)|SIN(...)|PWL(...)|EXP(...)|SFFM(...)]`.
    fn parse_source(
        &self,
        name: &str,
        kind: DeviceKind,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 2 {
            return Err(SimError::Parse(format!(
                "source '{name}' needs at least 2 nodes"
            )));
        }

        let node_p = Self::token_to_node_name(&line[0])?;
        let node_n = Self::token_to_node_name(&line[1])?;

        let params_env = &self.netlist.params;
        let mut value = None;
        let mut params = Vec::new();
        let mut idx = 2;

        while idx < line.len() {
            match &line[idx] {
                Token::Word(w) if w == "dc" => {
                    idx += 1;
                    if idx < line.len() {
                        if let Some((v, consumed)) =
                            Self::tokens_to_numeric_or_brace(&line[idx..], params_env)
                        {
                            value = Some(v);
                            params.push(("dc".to_string(), v));
                            idx += consumed;
                        }
                    }
                }
                Token::Word(w) if w == "ac" => {
                    idx += 1;
                    if idx < line.len() {
                        if let Some((v, consumed)) =
                            Self::tokens_to_numeric_or_brace(&line[idx..], params_env)
                        {
                            params.push(("ac".to_string(), v));
                            idx += consumed;
                            // Optional phase.
                            if idx < line.len() {
                                if let Some((phase, c2)) =
                                    Self::tokens_to_numeric_or_brace(&line[idx..], params_env)
                                {
                                    params.push(("ac_phase".to_string(), phase));
                                    idx += c2;
                                }
                            }
                        }
                    }
                }
                // Waveform keywords — consume keyword + parenthesised argument list.
                Token::Word(w) if matches!(w.as_str(),
                    "pulse" | "sin" | "pwl" | "exp" | "sffm" | "am" | "trnoise" | "trrandom"
                ) => {
                    let wkind = w.clone();
                    idx += 1;

                    // PWL FILE="path.csv" form — check if next token is Word("file") Equals QuotedString.
                    if wkind == "pwl"
                        && idx + 2 < line.len()
                        && matches!(&line[idx], Token::Word(w) if w == "file")
                        && line[idx + 1] == Token::Equals
                    {
                        if let Token::QuotedString(path) | Token::Word(path) = &line[idx + 2] {
                            let path = path.clone();
                            idx += 3;
                            // Encode path as byte-per-param so it survives the f64 ParamMap.
                            params.push(("waveform_kind".into(), 6.0));
                            params.push(("pwlfile_path_len".into(), path.len() as f64));
                            for (j, byte) in path.bytes().enumerate() {
                                params.push((format!("pwlfile_path_{j}"), byte as f64));
                            }
                            continue;
                        }
                    }

                    // Collect all values inside the parentheses (or bare positional values).
                    let args = Self::collect_paren_args(&line[idx..]);
                    let consumed = Self::paren_args_consumed(&line[idx..]);
                    idx += consumed;

                    // PWL R=<offset> — look for trailing R= key after the point list.
                    // This turns a plain PWL into a PWL REPEAT (waveform_kind 10).
                    if wkind == "pwl" {
                        // Check for R= or r= immediately after the arg list.
                        if idx < line.len()
                            && matches!(&line[idx], Token::Word(w) if w.eq_ignore_ascii_case("r"))
                            && line.get(idx + 1) == Some(&Token::Equals)
                        {
                            if let Some((r_val, r_consumed)) =
                                Self::tokens_to_signed_number(&line[idx + 2..])
                            {
                                idx += 2 + r_consumed;
                                // Emit as kind 10 (PWL REPEAT) with the same point keys.
                                let n_pts = args.len() / 2;
                                params.push(("waveform_kind".into(), 10.0));
                                params.push(("pwl_count".into(), n_pts as f64));
                                for i in 0..n_pts {
                                    params.push((format!("pwl_t{i}"), args[i * 2]));
                                    params.push((format!("pwl_v{i}"), args[i * 2 + 1]));
                                }
                                params.push(("pwl_r".into(), r_val));
                                continue;
                            }
                        }
                    }

                    Self::emit_waveform_params(&wkind, &args, &mut params);
                }
                Token::Number(_) | Token::Minus | Token::Plus | Token::LeftBrace => {
                    // Bare number / brace expression = DC value.
                    if let Some((v, consumed)) =
                        Self::tokens_to_numeric_or_brace(&line[idx..], params_env)
                    {
                        if value.is_none() {
                            value = Some(v);
                            params.push(("dc".to_string(), v));
                        }
                        idx += consumed;
                    } else {
                        idx += 1;
                    }
                }
                _ => {
                    // Try key=value.
                    if let Some((k, v, consumed)) =
                        Self::try_parse_kv_param_with(&line[idx..], params_env)
                    {
                        params.push((k, v));
                        idx += consumed;
                    } else {
                        idx += 1;
                    }
                }
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind,
            nodes: vec![node_p, node_n],
            value,
            model_name: None,
            params,
        }))
    }

    /// Collect the positional numeric arguments from a SPICE waveform call.
    ///
    /// Accepts both parenthesised form `PULSE(0 5 1u 1n 1n 10u 20u)` and bare
    /// positional form `PULSE 0 5 1u 1n 1n 10u 20u`.  Returns only the numeric
    /// values, stripping parens and commas.
    fn collect_paren_args(tokens: &[Token]) -> Vec<f64> {
        let mut args = Vec::new();
        let mut i = 0;
        let in_parens = matches!(tokens.get(0), Some(Token::LeftParen));
        if in_parens {
            i += 1; // skip '('
        }
        loop {
            if i >= tokens.len() {
                break;
            }
            match &tokens[i] {
                Token::RightParen => { break; }
                Token::Comma => { i += 1; }
                Token::Newline | Token::Eof => break,
                tok => {
                    // Handle optional sign tokens before numbers.
                    if let Some((v, consumed)) = Self::tokens_to_signed_number(&tokens[i..]) {
                        args.push(v);
                        i += consumed;
                    } else if !in_parens {
                        // Without parens we stop at non-numeric tokens (next keyword).
                        break;
                    } else {
                        i += 1;
                    }
                    let _ = tok;
                }
            }
        }
        args
    }

    /// Return how many tokens `collect_paren_args` would consume.
    fn paren_args_consumed(tokens: &[Token]) -> usize {
        let mut i = 0;
        let in_parens = matches!(tokens.get(0), Some(Token::LeftParen));
        if in_parens {
            i += 1;
        }
        loop {
            if i >= tokens.len() {
                break;
            }
            match &tokens[i] {
                Token::RightParen => { i += 1; break; }
                Token::Comma => { i += 1; }
                Token::Newline | Token::Eof => break,
                _ => {
                    if let Some((_, consumed)) = Self::tokens_to_signed_number(&tokens[i..]) {
                        i += consumed;
                    } else if !in_parens {
                        break;
                    } else {
                        i += 1;
                    }
                }
            }
        }
        i
    }

    /// Translate waveform keyword + positional args into `ParamMap`-style
    /// `(key, value)` pairs and append them to `params`.
    ///
    /// Follows the SPICE3 positional order for each waveform type.
    fn emit_waveform_params(kind: &str, args: &[f64], params: &mut Vec<(String, f64)>) {
        match kind {
            "pulse" => {
                // PULSE(v1 v2 td tr tf pw per)
                params.push(("waveform_kind".into(), 1.0));
                let names = ["pulse_v1", "pulse_v2", "pulse_td", "pulse_tr", "pulse_tf", "pulse_pw", "pulse_per"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            "sin" => {
                // SIN(vo va freq td theta)
                params.push(("waveform_kind".into(), 2.0));
                let names = ["sin_vo", "sin_va", "sin_freq", "sin_td", "sin_theta"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            "pwl" => {
                // PWL(t0 v0 t1 v1 ...)
                params.push(("waveform_kind".into(), 3.0));
                let n_pts = args.len() / 2;
                params.push(("pwl_count".into(), n_pts as f64));
                for i in 0..n_pts {
                    params.push((format!("pwl_t{i}"), args[i * 2]));
                    params.push((format!("pwl_v{i}"), args[i * 2 + 1]));
                }
            }
            "exp" => {
                // EXP(v1 v2 td1 tau1 td2 tau2)
                params.push(("waveform_kind".into(), 4.0));
                let names = ["exp_v1", "exp_v2", "exp_td1", "exp_tau1", "exp_td2", "exp_tau2"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            "sffm" => {
                // SFFM(vo va fc mdi fs)
                params.push(("waveform_kind".into(), 5.0));
                let names = ["sffm_vo", "sffm_va", "sffm_fc", "sffm_mdi", "sffm_fs"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            "am" => {
                // AM(vo va fc fm td)  — ngspice positional order
                params.push(("waveform_kind".into(), 7.0));
                let names = ["am_vo", "am_va", "am_fc", "am_freq", "am_td"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            "trnoise" => {
                // TRNOISE(na nt nalpha namp [td])
                params.push(("waveform_kind".into(), 8.0));
                let names = ["trnoise_na", "trnoise_nt", "trnoise_nalpha", "trnoise_namp", "trnoise_td"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            "trrandom" => {
                // TRRANDOM(type ts td param1 param2)
                params.push(("waveform_kind".into(), 9.0));
                let names = ["trrandom_kind", "trrandom_tstep", "trrandom_td", "trrandom_param", "trrandom_mean"];
                for (i, &name) in names.iter().enumerate() {
                    if i < args.len() {
                        params.push((name.into(), args[i]));
                    }
                }
            }
            _ => {}
        }
    }

    /// Parse a diode: `Dname node+ node- modelname [params]`.
    fn parse_diode(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 3 {
            return Err(SimError::Parse(format!(
                "diode '{name}' needs 2 nodes and a model name"
            )));
        }

        let anode = Self::token_to_node_name(&line[0])?;
        let cathode = Self::token_to_node_name(&line[1])?;
        let model_name = match &line[2] {
            Token::Word(s) => s.clone(),
            _ => return Err(SimError::Parse(format!(
                "expected model name for diode '{name}'"
            ))),
        };

        let mut params = Vec::new();
        let mut idx = 3;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                params.push((k, v));
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Diode,
            nodes: vec![anode, cathode],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// Parse a MOSFET: `Mname drain gate source bulk modelname [W=... L=... params]`.
    fn parse_mosfet(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 5 {
            return Err(SimError::Parse(format!(
                "MOSFET '{name}' needs 4 nodes and a model name"
            )));
        }

        let drain = Self::token_to_node_name(&line[0])?;
        let gate = Self::token_to_node_name(&line[1])?;
        let source = Self::token_to_node_name(&line[2])?;
        let bulk = Self::token_to_node_name(&line[3])?;
        let model_name = match &line[4] {
            Token::Word(s) => s.clone(),
            _ => return Err(SimError::Parse(format!(
                "expected model name for MOSFET '{name}'"
            ))),
        };

        let mut params = Vec::new();
        let mut idx = 5;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                params.push((k, v));
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        // Determine N or P from model — we'll resolve later during circuit build.
        // Default to MosfetN; the build step will fix this based on model kind.
        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::MosfetN,
            nodes: vec![drain, gate, source, bulk],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// Parse VCVS: `Ename n+ n- nc+ nc- gain`.
    fn parse_vcvs(
        &mut self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 3 {
            return Err(SimError::Parse(format!(
                "VCVS '{name}' needs at least 'n+ n- ...'"
            )));
        }

        // LAPLACE form (ngspice style):
        //   E<name> n+ n- LAPLACE {expr} (b0 b1 ...) (a0 a1 ...)
        // The expression is the input signal; the rational function is
        // the transfer characteristic H(s) = sum(b_i s^i) / sum(a_i s^i).
        if line.len() >= 3 {
            if let Token::Word(w) = &line[2] {
                if w.eq_ignore_ascii_case("laplace") {
                    let n_out_p = Self::token_to_node_name(&line[0])?;
                    let n_out_n = Self::token_to_node_name(&line[1])?;
                    return self.parse_laplace_form(
                        name,
                        LaplaceKind::Vcvs,
                        &n_out_p,
                        &n_out_n,
                        &line[3..],
                    );
                }
                // TABLE form: E<name> n+ n- TABLE {expr} = (x0,y0) (x1,y1) ...
                if w.eq_ignore_ascii_case("table") {
                    let np = Self::token_to_node_name(&line[0])?;
                    let nn = Self::token_to_node_name(&line[1])?;
                    return self.parse_table_device(
                        name,
                        DeviceKind::Vcvs,
                        &np,
                        &nn,
                        &line[3..],
                    );
                }
                // POLY(n) form: E<name> n+ n- POLY(k) (vc1+ vc1-) ... c0 c1 ...
                if let Some(degree) = Self::try_parse_poly_keyword(w) {
                    let n_out_p = Self::token_to_node_name(&line[0])?;
                    let n_out_n = Self::token_to_node_name(&line[1])?;
                    return self.parse_poly_form(
                        name,
                        PolyKind::Vcvs,
                        &n_out_p,
                        &n_out_n,
                        degree,
                        &line[3..],
                    );
                }
            }
        }

        // POLY(n) form: E n+ n- POLY(n) (cp1+ cp1-) ... c0 c1 ...
        if line.len() >= 3 {
            if let Some(poly) = Self::try_parse_poly_form(name, DeviceKind::Vcvs, line)? {
                return Ok(Some(poly));
            }
        }

        // VALUE {expr} / VALUE = expr form:
        // E<name> n+ n- VALUE { expr }
        // E<name> n+ n- VALUE = { expr }
        if line.len() >= 4 {
            if let Token::Word(w) = &line[2] {
                if w.eq_ignore_ascii_case("value") {
                    let n_out_p = Self::token_to_node_name(&line[0])?;
                    let n_out_n = Self::token_to_node_name(&line[1])?;
                    // Skip optional '=' after VALUE keyword, then expect '{expr}'
                    let expr_tokens = if matches!(line.get(3), Some(Token::Equals)) {
                        &line[4..]
                    } else {
                        &line[3..]
                    };
                    let behavioral = Self::parse_bsource_rhs(name, expr_tokens)?;
                    self.pending_bsources.push(PendingBsource {
                        name: name.to_string(),
                        node_p: n_out_p,
                        node_n: n_out_n,
                        kind: DeviceKind::VcvsExpr,
                        expr: behavioral,
                    });
                    return Ok(None);
                }
            }
        }

        if line.len() < 5 {
            return Err(SimError::Parse(format!(
                "VCVS '{name}' needs 4 nodes and a gain"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;
        let ncp = Self::token_to_node_name(&line[2])?;
        let ncn = Self::token_to_node_name(&line[3])?;

        let (gain, _) = Self::tokens_to_signed_number(&line[4..]).ok_or_else(|| {
            SimError::Parse(format!("expected gain value for VCVS '{name}'"))
        })?;

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Vcvs,
            nodes: vec![np, nn, ncp, ncn],
            value: Some(gain),
            model_name: None,
            params: vec![("gain".to_string(), gain)],
        }))
    }

    /// Parse VCCS: `Gname n+ n- nc+ nc- gm`.
    fn parse_vccs(
        &mut self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 3 {
            return Err(SimError::Parse(format!(
                "VCCS '{name}' needs at least 'n+ n- ...'"
            )));
        }

        // LAPLACE form (ngspice style):
        //   G<name> n+ n- LAPLACE {expr} (b0 b1 ...) (a0 a1 ...)
        // Output current = H(s) · expr.
        if line.len() >= 3 {
            if let Token::Word(w) = &line[2] {
                if w.eq_ignore_ascii_case("laplace") {
                    let n_out_p = Self::token_to_node_name(&line[0])?;
                    let n_out_n = Self::token_to_node_name(&line[1])?;
                    return self.parse_laplace_form(
                        name,
                        LaplaceKind::Vccs,
                        &n_out_p,
                        &n_out_n,
                        &line[3..],
                    );
                }
                // TABLE form: G<name> n+ n- TABLE {expr} = (x0,y0) (x1,y1) ...
                if w.eq_ignore_ascii_case("table") {
                    let np = Self::token_to_node_name(&line[0])?;
                    let nn = Self::token_to_node_name(&line[1])?;
                    return self.parse_table_device(
                        name,
                        DeviceKind::Vccs,
                        &np,
                        &nn,
                        &line[3..],
                    );
                }
                // POLY(n) form: G<name> n+ n- POLY(k) (vc1+ vc1-) ... c0 c1 ...
                if let Some(degree) = Self::try_parse_poly_keyword(w) {
                    let n_out_p = Self::token_to_node_name(&line[0])?;
                    let n_out_n = Self::token_to_node_name(&line[1])?;
                    return self.parse_poly_form(
                        name,
                        PolyKind::Vccs,
                        &n_out_p,
                        &n_out_n,
                        degree,
                        &line[3..],
                    );
                }
            }
        }

        // POLY(n) form: G n+ n- POLY(n) (cp1+ cp1-) ... c0 c1 ...
        if line.len() >= 3 {
            if let Some(poly) = Self::try_parse_poly_form(name, DeviceKind::Vccs, line)? {
                return Ok(Some(poly));
            }
        }

        if line.len() < 5 {
            return Err(SimError::Parse(format!(
                "VCCS '{name}' needs 4 nodes and a transconductance"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;
        let ncp = Self::token_to_node_name(&line[2])?;
        let ncn = Self::token_to_node_name(&line[3])?;

        let (gm, _) = Self::tokens_to_signed_number(&line[4..]).ok_or_else(|| {
            SimError::Parse(format!("expected transconductance for VCCS '{name}'"))
        })?;

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Vccs,
            nodes: vec![np, nn, ncp, ncn],
            value: Some(gm),
            model_name: None,
            params: vec![("gm".to_string(), gm)],
        }))
    }

    /// Try to parse a `POLY(n)` form for E/G/F/H elements.
    ///
    /// Syntax: `n+ n- POLY(degree) (cp1+ cp1-) [(cp2+ cp2-) ...] c0 c1 c2 ...`
    ///
    /// Returns `Ok(Some(ElementStatement))` if `POLY(n)` is detected, `Ok(None)` otherwise.
    fn try_parse_poly_form(
        name: &str,
        kind: DeviceKind,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        // line[0] = n+, line[1] = n-, line[2] = Word("poly") (possibly)
        let is_poly = matches!(&line[2], Token::Word(w) if w == "poly");
        if !is_poly {
            return Ok(None);
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;

        // Expect POLY( degree ).
        // Token layout after "poly": LeftParen Number RightParen (control pairs) coeffs
        if line.len() < 6 {
            return Err(SimError::Parse(format!(
                "'{name}': POLY form incomplete"
            )));
        }
        if line[3] != Token::LeftParen {
            return Err(SimError::Parse(format!(
                "'{name}': expected '(' after POLY"
            )));
        }
        let degree = match &line[4] {
            Token::Number(n) => *n as usize,
            _ => return Err(SimError::Parse(format!("'{name}': expected degree in POLY(n)"))),
        };
        if line[5] != Token::RightParen {
            return Err(SimError::Parse(format!("'{name}': expected ')' after POLY(n)")));
        }

        // Parse `degree` controlling node pairs, each as `(cp+ cp-)`.
        let mut idx = 6;
        let mut control_pairs: Vec<(String, String)> = Vec::new();
        for _ in 0..degree {
            if idx >= line.len() || line[idx] != Token::LeftParen {
                return Err(SimError::Parse(format!(
                    "'{name}': expected '(' for control pair in POLY"
                )));
            }
            idx += 1;
            let cp = Self::token_to_node_name(line.get(idx).ok_or_else(|| {
                SimError::Parse(format!("'{name}': missing node in POLY control pair"))
            })?)?;
            idx += 1;
            let cn = Self::token_to_node_name(line.get(idx).ok_or_else(|| {
                SimError::Parse(format!("'{name}': missing node in POLY control pair"))
            })?)?;
            idx += 1;
            if idx < line.len() && line[idx] == Token::RightParen {
                idx += 1;
            }
            control_pairs.push((cp, cn));
        }

        // Remaining tokens are the polynomial coefficients.
        let mut coefficients: Vec<f64> = Vec::new();
        while idx < line.len() {
            if let Some((v, consumed)) = Self::tokens_to_signed_number(&line[idx..]) {
                coefficients.push(v);
                idx += consumed;
            } else {
                break;
            }
        }

        // Encode poly into params for the ElementStatement.
        // Use poly_degree, poly_npairs, poly_cp{i}_p, poly_cp{i}_n (indices),
        // poly_coeff{j} convention.
        // Node names are stored by index into a flat node list.
        let mut all_nodes = vec![np, nn];
        let mut params: Vec<(String, f64)> = Vec::new();
        params.push(("poly_degree".into(), degree as f64));
        params.push(("poly_npairs".into(), control_pairs.len() as f64));
        for (i, (cp, cn)) in control_pairs.iter().enumerate() {
            params.push((format!("poly_cp{i}_p_idx"), all_nodes.len() as f64));
            all_nodes.push(cp.clone());
            params.push((format!("poly_cp{i}_n_idx"), all_nodes.len() as f64));
            all_nodes.push(cn.clone());
        }
        for (j, &c) in coefficients.iter().enumerate() {
            params.push((format!("poly_coeff{j}"), c));
        }
        params.push(("poly_ncoeffs".into(), coefficients.len() as f64));

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind,
            nodes: all_nodes,
            value: None,
            model_name: None,
            params,
        }))
    }

    /// Parse the LAPLACE form `{expr} (num_list) (den_list)` and expand
    /// it at parse time into a small RC + B-source + controlled-source
    /// subcircuit that realises the rational transfer function.
    ///
    /// Supported transfer-function shapes (Phase 2.2 — first iteration):
    ///
    ///   * Pure gain: `H(s) = b0 / a0` → just emit a regular VCVS / VCCS
    ///     with `gain = K` (no internal nodes).
    ///   * First-order lowpass: `H(s) = b0 / (a0 + a1·s)` → realised as
    ///     a B-source driving an internal RC node:
    ///         _lap.<name>.x   — internal LP output
    ///         B_lap.<name>    — V = K · expr  (drives the LP input)
    ///         R_lap.<name>    — 1 Ω from input to internal node
    ///         C_lap.<name>    — τ F from internal node to ground
    ///     and a unity output stage:
    ///         E (or G) `_<name>` — copies the internal voltage to the
    ///         actual output port.
    ///
    /// Higher-order denominators (length > 2) are rejected with a
    /// descriptive error so the user knows the form is recognised but
    /// not yet supported.
    fn parse_laplace_form(
        &mut self,
        name: &str,
        kind: LaplaceKind,
        n_out_p: &str,
        n_out_n: &str,
        tokens: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        // Strip trailing Newline / Eof so the index logic below is simple.
        let tokens = Self::trim_trailing_eol(tokens);

        if tokens.is_empty() || tokens[0] != Token::LeftBrace {
            return Err(SimError::Parse(format!(
                "LAPLACE '{name}': expected '{{expr}}' after LAPLACE keyword"
            )));
        }

        // Parse the controlling expression as a B-source RHS so we get
        // node-voltage references and the full behavioral expression
        // machinery for free.
        let (parsed_expr, expr_consumed) = parse_brace_expression(tokens).map_err(|e| {
            SimError::Parse(format!("LAPLACE '{name}': expression: {e}"))
        })?;
        Self::check_bsource_expr_support(name, &parsed_expr)?;
        let expr_be = Self::expr_to_behavioral(&parsed_expr)?;

        // Skip past the brace expression.
        let mut i = expr_consumed;

        // Parse the numerator coefficient list `(b0 b1 ...)`.
        let (num, used) = Self::parse_paren_number_list(&tokens[i..]).map_err(|e| {
            SimError::Parse(format!("LAPLACE '{name}': numerator: {e}"))
        })?;
        i += used;

        // Optional `/` separator between numerator and denominator
        // (some SPICE dialects write `(num)/(den)`).
        if i < tokens.len() && tokens[i] == Token::Slash {
            i += 1;
        }

        // Parse the denominator coefficient list `(a0 a1 ...)`.
        let (den, _used) = Self::parse_paren_number_list(&tokens[i..]).map_err(|e| {
            SimError::Parse(format!("LAPLACE '{name}': denominator: {e}"))
        })?;

        if num.is_empty() || den.is_empty() {
            return Err(SimError::Parse(format!(
                "LAPLACE '{name}': numerator and denominator must be non-empty"
            )));
        }
        let a0 = den[0];
        if a0 == 0.0 {
            return Err(SimError::Parse(format!(
                "LAPLACE '{name}': leading denominator coefficient (a0) must be non-zero"
            )));
        }

        // Pure-gain shortcut: H(s) = b0 / a0.
        // The numerator may have higher-order terms but they all multiply
        // s^k; for the pure-gain check we require all `b_i (i>0)` to be
        // zero AND `den.len() == 1`.
        let num_has_only_b0 = num.iter().skip(1).all(|&x| x == 0.0);
        if den.len() == 1 && num_has_only_b0 {
            let k = num[0] / a0;
            return self.emit_pure_gain_laplace(name, kind, n_out_p, n_out_n, k, expr_be);
        }

        // First-order lowpass: H(s) = b0 / (a0 + a1·s) — i.e. den.len()==2
        // and only b0 in the numerator (b1 == 0 if present).
        if den.len() == 2 && num_has_only_b0 {
            let b0 = num[0];
            let a1 = den[1];
            let k = b0 / a0;
            // tau must be positive for a stable, causal LP.
            let tau = a1 / a0;
            if tau <= 0.0 {
                return Err(SimError::Parse(format!(
                    "LAPLACE '{name}': first-order time constant a1/a0 = {tau} must be > 0"
                )));
            }
            return self.emit_first_order_lp_laplace(
                name, kind, n_out_p, n_out_n, k, tau, expr_be,
            );
        }

        Err(SimError::Parse(format!(
            "LAPLACE '{name}': only pure gain (a0 only) and first-order H(s) = b0/(a0+a1·s) \
             are supported in this build (got num.len()={}, den.len()={})",
            num.len(),
            den.len(),
        )))
    }

    /// Parse a parenthesised list of (signed) numbers: `(x0 x1 x2 ...)`.
    /// Numbers may be separated by whitespace and/or commas.
    fn parse_paren_number_list(tokens: &[Token]) -> Result<(Vec<f64>, usize), String> {
        if tokens.is_empty() {
            return Err("expected '('".to_string());
        }
        if tokens[0] != Token::LeftParen {
            return Err(format!("expected '(', got '{}'", tokens[0]));
        }
        let mut i = 1usize;
        let mut out: Vec<f64> = Vec::new();
        while i < tokens.len() && tokens[i] != Token::RightParen {
            // Skip commas, newlines.
            match &tokens[i] {
                Token::Comma | Token::Newline => {
                    i += 1;
                    continue;
                }
                _ => {}
            }
            let (v, used) = Self::tokens_to_signed_number(&tokens[i..])
                .ok_or_else(|| format!("expected number, got '{}'", tokens[i]))?;
            out.push(v);
            i += used;
        }
        if i >= tokens.len() || tokens[i] != Token::RightParen {
            return Err("missing ')'".to_string());
        }
        i += 1; // consume ')'
        Ok((out, i))
    }

    /// Emit a pure-gain LAPLACE expansion (H(s) = K, no dynamics).
    ///
    /// For VCVS we generate a behavioral B-source `Bv: out+ - out- = K · expr`.
    /// For VCCS we generate a behavioral B-source `Bi: out+ → out- I = K · expr`.
    fn emit_pure_gain_laplace(
        &mut self,
        name: &str,
        kind: LaplaceKind,
        n_out_p: &str,
        n_out_n: &str,
        k: f64,
        expr: BehavioralExpr,
    ) -> Result<Option<ElementStatement>, SimError> {
        let scaled = if (k - 1.0).abs() < f64::EPSILON {
            expr
        } else {
            BehavioralExpr::BinOp(
                BehavioralBinOp::Mul,
                Box::new(BehavioralExpr::Lit(k)),
                Box::new(expr),
            )
        };
        let b_kind = match kind {
            LaplaceKind::Vcvs => DeviceKind::BsourceV,
            LaplaceKind::Vccs => DeviceKind::BsourceI,
        };
        self.pending_bsources.push(PendingBsource {
            name: format!("b_lap_{name}"),
            node_p: n_out_p.to_string(),
            node_n: n_out_n.to_string(),
            kind: b_kind,
            expr: scaled,
        });
        Ok(None)
    }

    /// Emit a first-order lowpass LAPLACE expansion:
    /// H(s) = K / (1 + τ·s).
    ///
    /// Topology:
    ///   - B-source `B_lap_<name>`: V(_lap.<name>.in, 0) = K · expr
    ///   - Resistor `R_lap_<name>` 1 Ω from `_lap.<name>.in` to `_lap.<name>.x`
    ///   - Capacitor `C_lap_<name>` τ F from `_lap.<name>.x` to ground
    ///   - Output stage:
    ///       VCVS form: `E_lap_<name>` gain=1 from (out+, out-) controlled
    ///                  by (`_lap.<name>.x`, 0)
    ///       VCCS form: B-source `Bi_lap_<name>` I = V(_lap.<name>.x) injected
    ///                  out+ → out-
    fn emit_first_order_lp_laplace(
        &mut self,
        name: &str,
        kind: LaplaceKind,
        n_out_p: &str,
        n_out_n: &str,
        k: f64,
        tau: f64,
        expr: BehavioralExpr,
    ) -> Result<Option<ElementStatement>, SimError> {
        let internal_in = format!("_lap.{name}.in");
        let internal_x = format!("_lap.{name}.x");

        // 1. B-source driving the LP input: V(internal_in) = K · expr.
        let scaled = BehavioralExpr::BinOp(
            BehavioralBinOp::Mul,
            Box::new(BehavioralExpr::Lit(k)),
            Box::new(expr),
        );
        self.pending_bsources.push(PendingBsource {
            name: format!("b_lap_{name}"),
            node_p: internal_in.clone(),
            node_n: "0".to_string(),
            kind: DeviceKind::BsourceV,
            expr: scaled,
        });

        // 2. R = 1 Ω from internal_in to internal_x.
        self.netlist.elements.push(ElementStatement {
            name: format!("r_lap_{name}"),
            kind: DeviceKind::Resistor,
            nodes: vec![internal_in.clone(), internal_x.clone()],
            value: Some(1.0),
            model_name: None,
            params: vec![("resistance".to_string(), 1.0)],
        });

        // 3. C = τ F from internal_x to ground.
        self.netlist.elements.push(ElementStatement {
            name: format!("c_lap_{name}"),
            kind: DeviceKind::Capacitor,
            nodes: vec![internal_x.clone(), "0".to_string()],
            value: Some(tau),
            model_name: None,
            params: vec![("capacitance".to_string(), tau)],
        });

        // 4. Output stage.
        match kind {
            LaplaceKind::Vcvs => {
                self.netlist.elements.push(ElementStatement {
                    name: format!("e_lap_{name}"),
                    kind: DeviceKind::Vcvs,
                    nodes: vec![
                        n_out_p.to_string(),
                        n_out_n.to_string(),
                        internal_x.clone(),
                        "0".to_string(),
                    ],
                    value: Some(1.0),
                    model_name: None,
                    params: vec![("gain".to_string(), 1.0)],
                });
            }
            LaplaceKind::Vccs => {
                // Output current = 1 · V(internal_x) injected from out+ to out-.
                let out_expr = BehavioralExpr::NodeVoltage(internal_x.clone());
                self.pending_bsources.push(PendingBsource {
                    name: format!("bi_lap_{name}"),
                    node_p: n_out_p.to_string(),
                    node_n: n_out_n.to_string(),
                    kind: DeviceKind::BsourceI,
                    expr: out_expr,
                });
            }
        }

        Ok(None)
    }

    /// If `word` is `POLY` (case-insensitive), parse the following tokens
    /// for `(n)` and return `n`. Used by `parse_vcvs`/`parse_vccs` to detect
    /// the POLY form in the token stream.
    ///
    /// Returns `None` if the word is not "POLY" or the `(n)` is missing/malformed.
    /// On success also returns the number of extra tokens consumed (always 3: `(`, n, `)`).
    fn try_parse_poly_keyword(word: &str) -> Option<usize> {
        // Single-token form: some pre-processors emit "POLY(1)" as one word.
        let upper = word.to_ascii_uppercase();
        if upper.starts_with("POLY(") && upper.ends_with(')') {
            let inner = &upper["POLY(".len()..upper.len() - 1];
            return inner.trim().parse::<usize>().ok();
        }
        // Multi-token form: "POLY" is always just the keyword; the `(n)` follows
        // as separate tokens and is handled in `parse_poly_form`.
        if upper == "POLY" {
            // Return a sentinel 0 to signal "POLY keyword found; read (n) from tokens".
            return Some(usize::MAX);
        }
        None
    }

    /// Parse `POLY(n)` controlling pairs and coefficients from `tokens`.
    ///
    /// Syntax (after the `POLY(n)` token has been consumed):
    ///   `(nc1+ nc1-) (nc2+ nc2-) ... c0 c1 c2 ...`
    ///
    /// The SPICE3/ngspice coefficient ordering for POLY(n) is lexicographic
    /// over monomials sorted by total degree then lexicographic order of
    /// exponent vectors:
    ///   POLY(1): c0, c1·x1, c2·x1², ...
    ///   POLY(2): c0, c1·x1, c2·x2, c3·x1², c4·x1·x2, c5·x2², ...
    ///
    /// Each controlling pair contributes `xi = V(nc+) - V(nc-)`.
    /// Emits into `pending_bsources` as a B-source (voltage for VCVS, current
    /// for VCCS). Returns `Ok(None)` on success.
    fn parse_poly_form(
        &mut self,
        name: &str,
        kind: PolyKind,
        n_out_p: &str,
        n_out_n: &str,
        n_inputs_hint: usize,
        tokens: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        let tokens = Self::trim_trailing_eol(tokens);
        let mut i = 0usize;

        // When n_inputs_hint == usize::MAX the POLY keyword was bare ("POLY")
        // and the degree is encoded in the next tokens: `(` n `)`.
        let n_inputs = if n_inputs_hint == usize::MAX {
            // Expect: LeftParen Number RightParen
            if tokens.len() < 3
                || tokens[0] != Token::LeftParen
                || tokens[2] != Token::RightParen
            {
                return Err(SimError::Parse(format!(
                    "POLY '{name}': expected '(n)' after POLY keyword"
                )));
            }
            let deg = match &tokens[1] {
                Token::Number(n) => *n as usize,
                _ => return Err(SimError::Parse(format!(
                    "POLY '{name}': expected integer degree in POLY(n)"
                ))),
            };
            i = 3; // consumed '(' n ')'
            deg
        } else {
            n_inputs_hint
        };

        if n_inputs == 0 {
            return Err(SimError::Parse(format!(
                "POLY '{name}': degree must be >= 1"
            )));
        }

        // Parse n_inputs controlling node pairs: (nc+ nc-) ...
        let mut ctrl_pairs: Vec<(String, String)> = Vec::with_capacity(n_inputs);
        for pair_idx in 0..n_inputs {
            // Skip optional commas / newlines between pairs.
            while i < tokens.len() && matches!(tokens[i], Token::Comma | Token::Newline) {
                i += 1;
            }
            if i >= tokens.len() || tokens[i] != Token::LeftParen {
                return Err(SimError::Parse(format!(
                    "POLY '{name}': expected '(' for controlling pair {}", pair_idx + 1
                )));
            }
            i += 1; // consume '('
            let nc_p = Self::token_to_node_name(&tokens[i]).map_err(|_| {
                SimError::Parse(format!("POLY '{name}': bad node name in controlling pair {}", pair_idx + 1))
            })?;
            i += 1;
            // Optional comma between nc+ and nc-
            if i < tokens.len() && tokens[i] == Token::Comma {
                i += 1;
            }
            let nc_n = Self::token_to_node_name(&tokens[i]).map_err(|_| {
                SimError::Parse(format!("POLY '{name}': bad node name in controlling pair {}", pair_idx + 1))
            })?;
            i += 1;
            if i >= tokens.len() || tokens[i] != Token::RightParen {
                return Err(SimError::Parse(format!(
                    "POLY '{name}': expected ')' after controlling pair {}", pair_idx + 1
                )));
            }
            i += 1; // consume ')'
            ctrl_pairs.push((nc_p, nc_n));
        }

        // Parse coefficients: bare numbers until end of tokens.
        let mut coeffs: Vec<f64> = Vec::new();
        while i < tokens.len() {
            match &tokens[i] {
                Token::Comma | Token::Newline | Token::Eof => {
                    i += 1;
                    continue;
                }
                _ => {}
            }
            if let Some((v, consumed)) = Self::tokens_to_signed_number(&tokens[i..]) {
                coeffs.push(v);
                i += consumed;
            } else {
                break;
            }
        }

        if coeffs.is_empty() {
            return Err(SimError::Parse(format!(
                "POLY '{name}': no coefficients found"
            )));
        }

        // Build the behavioral expression tree for the polynomial.
        let expr = Self::build_poly_expr(n_inputs, &ctrl_pairs, &coeffs);

        let b_kind = match kind {
            PolyKind::Vcvs => DeviceKind::BsourceV,
            PolyKind::Vccs => DeviceKind::BsourceI,
        };
        self.pending_bsources.push(PendingBsource {
            name: format!("b_poly_{name}"),
            node_p: n_out_p.to_string(),
            node_n: n_out_n.to_string(),
            kind: b_kind,
            expr,
        });

        Ok(None)
    }

    /// Parse a POLY(n) form where the POLY keyword and degree are fused into
    /// a single token (e.g., `POLY(1)`).
    ///
    /// This is called when `try_parse_poly_keyword` returns `Some(degree)`
    /// for a fused token like "POLY(1)".
    ///
    /// The tokens after skipping the fused POLY(n) token start directly with
    /// the control pairs: `(nc1+ nc1-) (nc2+ nc2-) ... c0 c1 c2 ...`
    fn parse_poly_fused(
        &mut self,
        name: &str,
        kind: PolyKind,
        n_out_p: &str,
        n_out_n: &str,
        degree: usize,
        tokens: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        // Delegate to parse_poly_form with n_inputs_hint = degree.
        // The tokens already start at the control pairs (no POLY keyword to skip).
        self.parse_poly_form(
            name,
            kind,
            n_out_p,
            n_out_n,
            degree,
            tokens,
        )
    }

    /// Build a `BehavioralExpr` for a POLY(n) polynomial.
    ///
    /// `ctrl_pairs[i] = (nc_p, nc_n)` gives the i-th controlling voltage
    /// difference `xi = V(nc_p) - V(nc_n)`.  `coeffs` are ordered by the
    /// SPICE3 lexicographic monomial convention.
    ///
    /// Generates monomials in order of non-decreasing total degree, then
    /// lexicographically by exponent vector (x1 first):
    ///   degree 0: x1^0 ... xn^0  → c0
    ///   degree 1: x1^1, x2^1, ...
    ///   degree 2: x1^2, x1·x2, x2^2, ...
    /// Stops when coefficients are exhausted.
    fn build_poly_expr(
        n_inputs: usize,
        ctrl_pairs: &[(String, String)],
        coeffs: &[f64],
    ) -> BehavioralExpr {
        // xi = V(nc_p) - V(nc_n)
        let xi: Vec<BehavioralExpr> = ctrl_pairs
            .iter()
            .map(|(p, n)| {
                if n == "0" || n.eq_ignore_ascii_case("gnd") {
                    BehavioralExpr::NodeVoltage(p.clone())
                } else {
                    BehavioralExpr::BinOp(
                        BehavioralBinOp::Sub,
                        Box::new(BehavioralExpr::NodeVoltage(p.clone())),
                        Box::new(BehavioralExpr::NodeVoltage(n.clone())),
                    )
                }
            })
            .collect();

        // Generate monomials in SPICE3 lexicographic order, one per coefficient.
        let monomials = Self::poly_monomials(n_inputs, coeffs.len());

        // Build: sum of coeff * monomial, skipping zero coefficients.
        let mut terms: Vec<BehavioralExpr> = monomials
            .iter()
            .zip(coeffs.iter())
            .filter(|(_, c)| **c != 0.0)
            .map(|(exponents, c)| {
                let c = *c;
                // Build the monomial: product of xi^ei
                let mut factors: Vec<BehavioralExpr> = exponents
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| **e > 0)
                    .flat_map(|(idx, e)| std::iter::repeat_n(xi[idx].clone(), *e))
                    .collect();

                let mono = match factors.len() {
                    0 => BehavioralExpr::Lit(1.0),
                    1 => factors.remove(0),
                    _ => factors.into_iter().reduce(|acc, f| {
                        BehavioralExpr::BinOp(
                            BehavioralBinOp::Mul,
                            Box::new(acc),
                            Box::new(f),
                        )
                    }).unwrap(),
                };

                if (c - 1.0).abs() < f64::EPSILON {
                    mono
                } else {
                    BehavioralExpr::BinOp(
                        BehavioralBinOp::Mul,
                        Box::new(BehavioralExpr::Lit(c)),
                        Box::new(mono),
                    )
                }
            })
            .collect();

        match terms.len() {
            0 => BehavioralExpr::Lit(0.0),
            1 => terms.remove(0),
            _ => terms.into_iter().reduce(|acc, t| {
                BehavioralExpr::BinOp(
                    BehavioralBinOp::Add,
                    Box::new(acc),
                    Box::new(t),
                )
            }).unwrap(),
        }
    }

    /// Generate the first `count` monomials for `n_vars` variables in SPICE3
    /// lexicographic order (non-decreasing total degree, then lex by exponent
    /// vector with x1 varying slowest).
    ///
    /// Returns a `Vec` of exponent vectors, each of length `n_vars`.
    fn poly_monomials(n_vars: usize, count: usize) -> Vec<Vec<usize>> {
        let mut result = Vec::with_capacity(count);
        // Iterate by total degree d = 0, 1, 2, ...
        let mut d = 0usize;
        while result.len() < count {
            // Generate all exponent vectors summing to d over n_vars variables,
            // in lexicographic order (x1 first, i.e., x1 exponent varies slowest).
            Self::gen_exponents(n_vars, d, &mut vec![0usize; n_vars], 0, &mut result, count);
            d += 1;
        }
        result
    }

    /// Recursive helper: fill `current` with exponents summing to `remaining`
    /// starting at position `pos`. Appends to `out` when complete.
    fn gen_exponents(
        n_vars: usize,
        remaining: usize,
        current: &mut Vec<usize>,
        pos: usize,
        out: &mut Vec<Vec<usize>>,
        limit: usize,
    ) {
        if out.len() >= limit {
            return;
        }
        if pos == n_vars - 1 {
            current[pos] = remaining;
            out.push(current.clone());
            return;
        }
        // x[pos] ranges from 0 to remaining (x1 gets the highest value first
        // in lex order means x1 exponent is the outermost loop going from high to low
        // then x2 etc — but SPICE3 convention is x1 exponent decreasing, x2 increasing).
        // SPICE3 lex for POLY(2): c0, c1·x1, c2·x2, c3·x1², c4·x1·x2, c5·x2²
        // which means x1 exponent DECREASING within each total degree.
        // So x[pos] goes from remaining down to 0.
        for e in (0..=remaining).rev() {
            current[pos] = e;
            Self::gen_exponents(n_vars, remaining - e, current, pos + 1, out, limit);
            if out.len() >= limit {
                return;
            }
        }
    }

    /// Parse a BJT/VBIC element:
    ///   `Q<name> collector base emitter [substrate] modelname [params]`
    ///
    /// The substrate node is optional (defaults to "0" / ground for 3-terminal usage).
    /// The actual DeviceKind (BjtNpn, BjtPnp, VbicNpn, VbicPnp) is resolved in
    /// `build_circuit` based on the `.MODEL` type string and `LEVEL` parameter.
    fn parse_bjt(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 4 {
            return Err(SimError::Parse(format!(
                "BJT '{name}': expected at least 3 nodes and a model name"
            )));
        }

        // Collect positional word/number tokens as node names or model name.
        // Skip kv-key tokens (Word immediately followed by Equals) and kv-value
        // tokens (tokens following an Equals, including signed-number sequences
        // like `Minus Number` or `Plus Number`).
        //
        // We scan with a small state machine: after seeing Equals we are "in kv-value"
        // for 1 token (Number/Word) or 2 tokens (Minus/Plus then Number).
        {
            // Build a boolean mask: kv_token[i] = true means token i is part of a kv pair
            let mut kv_mask = vec![false; line.len()];
            let mut i = 0;
            while i < line.len() {
                if let Token::Word(_) = &line[i] {
                    if i + 1 < line.len() && line[i + 1] == Token::Equals {
                        // kv-key
                        kv_mask[i] = true; // key
                        kv_mask[i + 1] = true; // Equals
                        let val_start = i + 2;
                        if val_start < line.len() {
                            match &line[val_start] {
                                Token::Minus | Token::Plus => {
                                    kv_mask[val_start] = true;
                                    if val_start + 1 < line.len() {
                                        if let Token::Number(_) | Token::Word(_) = &line[val_start + 1] {
                                            kv_mask[val_start + 1] = true;
                                            i = val_start + 2;
                                            continue;
                                        }
                                    }
                                    i = val_start + 1;
                                    continue;
                                }
                                Token::Number(_) | Token::Word(_) | Token::LeftBrace => {
                                    // For brace expressions, mark until matching RightBrace
                                    if line[val_start] == Token::LeftBrace {
                                        let mut depth = 0usize;
                                        let mut j = val_start;
                                        while j < line.len() {
                                            kv_mask[j] = true;
                                            match &line[j] {
                                                Token::LeftBrace => depth += 1,
                                                Token::RightBrace => {
                                                    depth -= 1;
                                                    if depth == 0 { j += 1; break; }
                                                }
                                                _ => {}
                                            }
                                            j += 1;
                                        }
                                        i = j;
                                        continue;
                                    }
                                    kv_mask[val_start] = true;
                                    i = val_start + 1;
                                    continue;
                                }
                                _ => {
                                    i = val_start;
                                    continue;
                                }
                            }
                        }
                        i = val_start;
                        continue;
                    }
                }
                i += 1;
            }

            let words: Vec<String> = line.iter().enumerate().filter_map(|(idx, t)| {
                if kv_mask[idx] { return None; }
                match t {
                    Token::Word(s) => Some(s.clone()),
                    Token::Number(n) => {
                        if *n == (*n as u64) as f64 && *n >= 0.0 {
                            Some(format!("{}", *n as u64))
                        } else {
                            Some(format!("{n}"))
                        }
                    }
                    _ => None,
                }
            }).collect();

            if words.len() < 4 {
                return Err(SimError::Parse(format!(
                    "BJT '{name}': insufficient tokens — need C B E [S] model"
                )));
            }

            // Layout: [C, B, E, (S,) model, (kv-params...)]
            // If words.len() >= 5, treat words[3] as substrate node; otherwise default to "0".
            let (col, base, emit, sub, model_name, skip_words) = if words.len() >= 5 {
                (words[0].clone(), words[1].clone(), words[2].clone(),
                 words[3].clone(), words[4].clone(), 5usize)
            } else {
                (words[0].clone(), words[1].clone(), words[2].clone(),
                 "0".to_string(), words[3].clone(), 4usize)
            };

            // Scan past the first `skip_words` positional (non-kv) tokens to find kv-params.
            let mut tok_idx = 0usize;
            let mut consumed_words = 0usize;
            for (idx, tok) in line.iter().enumerate() {
                if kv_mask[idx] { continue; }
                match tok {
                    Token::Word(_) | Token::Number(_) => {
                        consumed_words += 1;
                        if consumed_words == skip_words {
                            tok_idx = idx + 1;
                            break;
                        }
                    }
                    _ => {}
                }
            }
            let mut params = Vec::new();
            while tok_idx < line.len() {
                if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[tok_idx..]) {
                    params.push((k, v));
                    tok_idx += consumed;
                } else {
                    tok_idx += 1;
                }
            }

            return Ok(Some(ElementStatement {
                name: name.to_string(),
                kind: DeviceKind::BjtNpn,
                nodes: vec![col, base, emit, sub],
                value: None,
                model_name: Some(model_name),
                params,
            }));
        }
    }

    /// Parse a JFET element:
    ///   `J<name> drain gate source model_name [params]`
    ///
    /// The model type (NJF/PJF) is resolved in `build_circuit` via the `.MODEL` statement.
    /// Default kind = JfetN; build_circuit sets JfetP when model.kind == "pjf".
    fn parse_jfet(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        // Collect word/number tokens as node names or model name.
        let words: Vec<String> = line.iter().filter_map(|t| match t {
            Token::Word(s) => Some(s.clone()),
            Token::Number(n) => {
                if *n == (*n as u64) as f64 && *n >= 0.0 {
                    Some(format!("{}", *n as u64))
                } else {
                    Some(format!("{n}"))
                }
            }
            _ => None,
        }).collect();

        if words.len() < 4 {
            return Err(SimError::Parse(format!(
                "JFET '{name}': expected drain gate source model_name"
            )));
        }

        let drain = words[0].clone();
        let gate  = words[1].clone();
        let src   = words[2].clone();
        let model_name = words[3].clone();

        // Scan for any trailing kv-params after the 4th word token.
        let mut tok_idx = 0usize;
        let mut consumed_words = 0usize;
        for (i, tok) in line.iter().enumerate() {
            match tok {
                Token::Word(_) | Token::Number(_) => {
                    consumed_words += 1;
                    if consumed_words == 4 {
                        tok_idx = i + 1;
                        break;
                    }
                }
                _ => {}
            }
        }
        let mut params = Vec::new();
        while tok_idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[tok_idx..]) {
                params.push((k, v));
                tok_idx += consumed;
            } else {
                tok_idx += 1;
            }
        }

        // Default kind = JfetN; build_circuit resolves to JfetP when model kind is "pjf".
        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::JfetN,
            nodes: vec![drain, gate, src],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// Parse a MESFET element:
    ///   `Z<name> drain gate source model_name [params]`
    ///
    /// The model type (NMF/PMF) is resolved in `build_circuit` via the `.MODEL` statement.
    /// Default kind = MesfetN; build_circuit sets MesfetP when model.kind == "pmf".
    fn parse_mesfet(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        let words: Vec<String> = line.iter().filter_map(|t| match t {
            Token::Word(s) => Some(s.clone()),
            Token::Number(n) => {
                if *n == (*n as u64) as f64 && *n >= 0.0 {
                    Some(format!("{}", *n as u64))
                } else {
                    Some(format!("{n}"))
                }
            }
            _ => None,
        }).collect();

        if words.len() < 4 {
            return Err(SimError::Parse(format!(
                "MESFET '{name}': expected drain gate source model_name"
            )));
        }

        let drain = words[0].clone();
        let gate  = words[1].clone();
        let src   = words[2].clone();
        let model_name = words[3].clone();

        let mut tok_idx = 0usize;
        let mut consumed_words = 0usize;
        for (i, tok) in line.iter().enumerate() {
            match tok {
                Token::Word(_) | Token::Number(_) => {
                    consumed_words += 1;
                    if consumed_words == 4 {
                        tok_idx = i + 1;
                        break;
                    }
                }
                _ => {}
            }
        }
        let mut params = Vec::new();
        while tok_idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[tok_idx..]) {
                params.push((k, v));
                tok_idx += consumed;
            } else {
                tok_idx += 1;
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::MesfetN,
            nodes: vec![drain, gate, src],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// Parse a K (mutual inductance) element:
    ///   `K<name> L1_name L2_name coupling_coefficient`
    ///
    /// Stores the result in `self.pending_k_elements` for resolution in `build_circuit`.
    fn parse_k_element(
        &mut self,
        name: &str,
        line: &[Token],
    ) -> Result<(), SimError> {
        let words: Vec<String> = line.iter().filter_map(|t| match t {
            Token::Word(s) => Some(s.clone()),
            _ => None,
        }).collect();

        if words.len() < 2 {
            return Err(SimError::Parse(format!(
                "K element '{name}': expected 'L1_name L2_name k_coefficient'"
            )));
        }

        let l1_name = words[0].clone();
        let l2_name = words[1].clone();

        // k value: first numeric token on the line.
        let k = line.iter().filter_map(|t| match t {
            Token::Number(v) => Some(*v),
            _ => None,
        }).next().unwrap_or(1.0);

        if k < 0.0 || k > 1.0 {
            return Err(SimError::Parse(format!(
                "K element '{name}': coupling coefficient k={k} must be in [0, 1]"
            )));
        }

        self.pending_k_elements.push(PendingKElement {
            name: name.to_string(),
            l1_name,
            l2_name,
            k,
        });
        Ok(())
    }

    /// Parse a current-controlled voltage source: `H<name> n+ n- Vcontrol transresistance`
    ///
    /// The H-element output voltage is `transresistance * I(Vcontrol)`.
    /// `Vcontrol` is the name of a voltage source whose branch current serves
    /// as the control variable.  The stamper resolves the control branch at
    /// solve time and injects the current into the device params.
    fn parse_ccvs(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        // Expected: n+ n- Vcontrol_name transresistance
        let words: Vec<String> = line.iter().filter_map(|t| match t {
            Token::Word(s) => Some(s.clone()),
            Token::Number(n) => Some(format!("{n}")),
            _ => None,
        }).collect();

        if words.len() < 3 {
            return Err(SimError::Parse(format!(
                "CCVS '{name}': expected n+ n- Vcontrol transresistance"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;

        // The third word-like token is the controlling V-source name.
        let ctrl_name = words[2].to_lowercase();

        // Transresistance: the first numeric token after the control source name.
        let rm = line.iter().skip(3).find_map(Self::token_to_number).unwrap_or(1.0);

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Ccvs,
            nodes: vec![np, nn],
            value: None,
            model_name: None,
            params: vec![
                ("transresistance".to_string(), rm),
                ("ctrl_source".to_string(), 0.0), // placeholder; real name stored below
            ],
        }))
        .map(|mut opt| {
            // Store the control source name in a side channel: we abuse a
            // param with a sentinel value and store the actual name in the
            // element's model_name field (which is otherwise unused for H).
            if let Some(ref mut es) = opt {
                es.model_name = Some(ctrl_name);
                // Remove the placeholder param
                es.params.retain(|(k, _)| k != "ctrl_source");
            }
            opt
        })
    }

    /// Parse a current-controlled current source: `F<name> n+ n- Vcontrol gain`
    ///
    /// The F-element output current is `gain * I(Vcontrol)`.
    /// `Vcontrol` is the name of a voltage source whose branch current serves
    /// as the control variable.
    fn parse_cccs(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        let words: Vec<String> = line.iter().filter_map(|t| match t {
            Token::Word(s) => Some(s.clone()),
            Token::Number(n) => Some(format!("{n}")),
            _ => None,
        }).collect();

        if words.len() < 3 {
            return Err(SimError::Parse(format!(
                "CCCS '{name}': expected n+ n- Vcontrol gain"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;

        let ctrl_name = words[2].to_lowercase();
        let gain = line.iter().skip(3).find_map(Self::token_to_number).unwrap_or(1.0);

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Cccs,
            nodes: vec![np, nn],
            value: None,
            model_name: Some(ctrl_name), // store ctrl vsource name here
            params: vec![
                ("current_gain".to_string(), gain),
            ],
        }))
    }

    /// Parse a lossless transmission line: `T<name> n1+ n1- n2+ n2- Z0=value TD=value`
    ///
    /// Also accepts the alternate frequency+electrical-length form:
    ///   `T<name> n1+ n1- n2+ n2- Z0=value F=freq NL=nlambda`
    /// which is converted to `TD = NL / F`.
    fn parse_tline(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 4 {
            return Err(SimError::Parse(format!(
                "T-line '{name}': expected 4 nodes + Z0/TD parameters"
            )));
        }

        let n1p = Self::token_to_node_name(&line[0])?;
        let n1n = Self::token_to_node_name(&line[1])?;
        let n2p = Self::token_to_node_name(&line[2])?;
        let n2n = Self::token_to_node_name(&line[3])?;

        let mut z0: Option<f64> = None;
        let mut td: Option<f64> = None;
        let mut freq: Option<f64> = None;
        let mut nl: Option<f64> = None;

        let mut idx = 4;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                match k.to_lowercase().as_str() {
                    "z0" => z0 = Some(v),
                    "td" => td = Some(v),
                    "f" => freq = Some(v),
                    "nl" => nl = Some(v),
                    _ => {}
                }
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        let td_val = match td {
            Some(t) => t,
            None => match (freq, nl) {
                (Some(f), Some(n)) if f > 0.0 => n / f,
                _ => return Err(SimError::Parse(format!(
                    "T-line '{name}': missing TD (or F+NL) parameter"
                ))),
            },
        };

        let z0_val = z0.ok_or_else(|| {
            SimError::Parse(format!("T-line '{name}': missing Z0 parameter"))
        })?;

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Tline,
            nodes: vec![n1p, n1n, n2p, n2n],
            value: None,
            model_name: None,
            params: vec![
                ("z0".to_string(), z0_val),
                ("td".to_string(), td_val),
            ],
        }))
    }

    /// Parse a lossy transmission line: `O<name> n1+ n1- n2+ n2- modelname`.
    ///
    /// The RLGC per-unit-length values and `LEN` come from the referenced
    /// `.MODEL modelname LTRA (R=.. L=.. G=.. C=.. LEN=..)` card, which the
    /// `build_circuit` pass copies into the device's `ParamMap`.
    ///
    /// Any trailing `key=value` tokens on the element line override the
    /// model-card value for that key (standard SPICE element-card
    /// precedence), matching how `parse_diode` merges inline parameters.
    fn parse_ltra(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 5 {
            return Err(SimError::Parse(format!(
                "LTRA '{name}' needs 4 nodes and a model name"
            )));
        }

        let n1p = Self::token_to_node_name(&line[0])?;
        let n1n = Self::token_to_node_name(&line[1])?;
        let n2p = Self::token_to_node_name(&line[2])?;
        let n2n = Self::token_to_node_name(&line[3])?;

        let model_name = match &line[4] {
            Token::Word(s) => s.clone(),
            _ => {
                return Err(SimError::Parse(format!(
                    "expected model name for LTRA '{name}'"
                )));
            }
        };

        // Optional inline overrides: R=.. L=.. G=.. C=.. LEN=.. NONINT=..
        let mut params = Vec::new();
        let mut idx = 5;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                params.push((k.to_lowercase(), v));
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Ltra,
            nodes: vec![n1p, n1n, n2p, n2n],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// `U<name> n+ n- n_ref <model_name> [L=<len>] [LUMPS=<n>]`
    ///
    /// Uniform RC transmission line.  Expanded at build_circuit time into
    /// LUMPS series resistors and shunt capacitors.
    fn parse_urc(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 4 {
            return Err(SimError::Parse(format!(
                "URC '{name}' needs n+, n-, n_ref, and a model name"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;
        let nref = Self::token_to_node_name(&line[2])?;

        let model_name = match &line[3] {
            Token::Word(s) => s.clone(),
            _ => {
                return Err(SimError::Parse(format!(
                    "expected model name for URC '{name}'"
                )));
            }
        };

        let mut params = Vec::new();
        let mut idx = 4;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                params.push((k.to_lowercase(), v));
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Urc,
            nodes: vec![np, nn, nref],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// `W<name> n+ n- <model> [RLGC_FILE=<path>] [L=<len>]`
    ///
    /// W-element (Xyce): frequency-domain lossy transmission line.
    /// Falls back to LTRA stamp until tabulated interpolation is implemented.
    fn parse_w_element(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 3 {
            return Err(SimError::Parse(format!(
                "W-element '{name}' needs n+, n-, and a model name"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;

        let model_name = match &line[2] {
            Token::Word(s) => s.clone(),
            _ => {
                return Err(SimError::Parse(format!(
                    "expected model name for W-element '{name}'"
                )));
            }
        };

        let mut params = Vec::new();
        let mut idx = 3;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                params.push((k.to_lowercase(), v));
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Wlossy,
            nodes: vec![np, nn],
            value: None,
            model_name: Some(model_name),
            params,
        }))
    }

    /// `PORT<name> n+ n- [Z0=50] [DC=0] [PORT=<n>]`
    ///
    /// S-parameter excitation port (HSPICE).
    /// Thevenin equivalent: voltage source in series with Z0 resistor.
    fn parse_port(
        &self,
        name: &str,
        line: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        if line.len() < 2 {
            return Err(SimError::Parse(format!(
                "PORT '{name}' needs at least n+ and n-"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;

        let mut params = Vec::new();
        // Defaults
        params.push(("z0".to_string(), 50.0));
        params.push(("dc".to_string(), 0.0));

        let mut idx = 2;
        while idx < line.len() {
            if let Some((k, v, consumed)) = Self::try_parse_kv_param(&line[idx..]) {
                let key = k.to_lowercase();
                // Override default if key already present.
                if let Some(existing) = params.iter_mut().find(|(ek, _)| *ek == key) {
                    existing.1 = v;
                } else {
                    params.push((key, v));
                }
                idx += consumed;
            } else {
                idx += 1;
            }
        }

        Ok(Some(ElementStatement {
            name: name.to_string(),
            kind: DeviceKind::Port,
            nodes: vec![np, nn],
            value: None,
            model_name: None,
            params,
        }))
    }

    /// `.FOUR f0 v(node1) [v(node2) ...]`
    ///
    /// `.HB f1 [f2] nharmonics`
    ///
    /// Single-tone form: `.HB 1G 7`              — f1=1 GHz, K=7 harmonics.
    /// Two-tone   form:  `.HB 1G 1.001G 5`       — f1=1 GHz, f2=1.001 GHz, K=5.
    ///
    /// We collect every numeric token on the line, then dispatch by count:
    ///   - 2 numbers → single-tone (f1, nharmonics).
    ///   - 3 numbers → two-tone     (f1, f2, nharmonics).
    /// Other counts return a parse error.
    fn parse_hb(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let nums: Vec<f64> = line.iter().filter_map(Self::token_to_number).collect();
        let mut params = Vec::new();
        match nums.len() {
            2 => {
                params.push(("f1".to_string(), nums[0]));
                params.push(("nharmonics".to_string(), nums[1]));
            }
            3 => {
                params.push(("f1".to_string(), nums[0]));
                params.push(("f2".to_string(), nums[1]));
                params.push(("nharmonics".to_string(), nums[2]));
            }
            _ => {
                return Err(SimError::Parse(format!(
                    ".HB: expected 'f1 nharmonics' or 'f1 f2 nharmonics', got {} numeric args",
                    nums.len()
                )));
            }
        }
        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Hb,
            params,
        });
        Ok(())
    }

    /// Parses the fundamental frequency `f0` (first numeric token after the directive).
    fn parse_four(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let f0 = line.iter().find_map(Self::token_to_number).ok_or_else(|| {
            SimError::Parse(".FOUR: expected fundamental frequency".into())
        })?;
        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Four,
            params: vec![("f0".to_string(), f0)],
        });
        Ok(())
    }

    /// `.FFT vector NP [window] [start] [stop]`
    ///
    /// Parses the output variable (`V(node)` or bare name), number of FFT
    /// points, optional window name and optional [start, stop] time range.
    /// Stored in `ParsedNetlist.fft_statements` for dispatch by
    /// `bigospice_analysis::fft::run_fft` after transient results are available.
    fn parse_fft(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();
        let mut idx = 0usize;

        // ── Parse output variable (V(node) or bare word) ───────────────
        let output_node: String = if idx < line.len() {
            match &line[idx] {
                Token::Word(w) => {
                    let w = w.clone();
                    if w.to_lowercase().starts_with('v') && w.contains('(') && w.contains(')') {
                        idx += 1;
                        w.trim_start_matches(|c: char| c.to_lowercase().next() == Some('v'))
                            .trim_start_matches('(')
                            .trim_end_matches(')')
                            .to_string()
                    } else if w.to_lowercase() == "v"
                        && idx + 3 < line.len()
                        && line[idx + 1] == Token::LeftParen
                        && line[idx + 3] == Token::RightParen
                    {
                        // Form: Word("v") LeftParen Word(node) RightParen
                        let node = match &line[idx + 2] {
                            Token::Word(n) => n.clone(),
                            Token::Number(n) if n.fract() == 0.0 && *n >= 0.0 => {
                                format!("{}", *n as u64)
                            }
                            _ => String::new(),
                        };
                        idx += 4;
                        node
                    } else {
                        idx += 1;
                        w
                    }
                }
                _ => String::new(),
            }
        } else {
            String::new()
        };

        // ── Parse number of points (first remaining numeric token) ─────
        let npoints = {
            let mut n = 1024usize;
            while idx < line.len() {
                if let Some(v) = Self::token_to_number(&line[idx]) {
                    n = v.max(1.0) as usize;
                    idx += 1;
                    break;
                }
                idx += 1;
            }
            n
        };

        // ── Parse optional window name (next Word token) ───────────────
        let mut window = "hanning".to_string();
        let mut peek = idx;
        while peek < line.len() {
            if let Token::Word(w) = &line[peek] {
                let lw = w.to_lowercase();
                if matches!(
                    lw.as_str(),
                    "rect"
                        | "rectangular"
                        | "hanning"
                        | "hann"
                        | "hamming"
                        | "blackman"
                        | "kaiser"
                ) {
                    window = lw;
                    idx = peek + 1;
                    break;
                }
            }
            peek += 1;
        }

        // ── Parse optional tstart, tstop ────────────────────────────────
        let mut nums = Vec::with_capacity(2);
        for t in line.iter().skip(idx) {
            if let Some(v) = Self::token_to_number(t) {
                nums.push(v);
            }
        }
        let tstart = nums.first().copied();
        let tstop = nums.get(1).copied();

        self.netlist.fft_statements.push(FftStatement {
            output_node,
            npoints,
            window,
            tstart,
            tstop,
        });
        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Fft,
            params: vec![("npoints".to_string(), npoints as f64)],
        });
        Ok(())
    }

    /// `.DISTO f1 [numf2 [f2overf1 [fstart] [fstop]]]`
    ///
    /// Phase 3.4 — Volterra-kernel small-signal distortion.
    ///
    /// SPICE3 layout: `numf2` is a non-zero flag requesting the second tone;
    /// when non-zero, `f2 = f1 * f2overf1` is the second tone (IM2/IM3).
    /// Accepts optional trailing `a2=<val>` / `a3=<val>` / `out=<node>`
    /// key-value pairs so integration tests can set the Volterra coefficients
    /// and output node without additional directives.
    fn parse_disto(&mut self) -> Result<(), SimError> {
        let line = self.collect_line();

        // First gather positional numeric tokens and key-value pairs.
        let mut positional: Vec<f64> = Vec::new();
        let mut a2 = 0.0_f64;
        let mut a3 = 0.0_f64;
        let mut output_node = String::new();
        let mut i = 0usize;
        while i < line.len() {
            match &line[i] {
                Token::Word(w) => {
                    let lw = w.to_lowercase();
                    // Detect `a2=…` / `a3=…` / `out=…` fused words.
                    if let Some(rest) = lw.strip_prefix("a2=") {
                        a2 = rest.parse::<f64>().unwrap_or(0.0);
                        i += 1;
                        continue;
                    }
                    if let Some(rest) = lw.strip_prefix("a3=") {
                        a3 = rest.parse::<f64>().unwrap_or(0.0);
                        i += 1;
                        continue;
                    }
                    if let Some(rest) = lw.strip_prefix("out=") {
                        output_node = rest.to_string();
                        i += 1;
                        continue;
                    }
                    // Separate tokens form: Word("a2") Equals Number(…)
                    if (lw == "a2" || lw == "a3" || lw == "out")
                        && i + 2 < line.len()
                        && line[i + 1] == Token::Equals
                    {
                        match lw.as_str() {
                            "a2" => {
                                a2 = Self::token_to_number(&line[i + 2]).unwrap_or(0.0);
                            }
                            "a3" => {
                                a3 = Self::token_to_number(&line[i + 2]).unwrap_or(0.0);
                            }
                            "out" => {
                                if let Token::Word(s) = &line[i + 2] {
                                    output_node = s.clone();
                                }
                            }
                            _ => {}
                        }
                        i += 3;
                        continue;
                    }
                }
                Token::Number(n) => {
                    positional.push(*n);
                }
                _ => {}
            }
            i += 1;
        }

        if positional.is_empty() {
            return Err(SimError::Parse(
                ".DISTO: expected at least f1 [numf2 f2overf1 [fstart fstop]]".into(),
            ));
        }
        let f1 = positional[0];
        let numf2 = positional.get(1).copied().unwrap_or(0.0);
        let f2overf1 = positional.get(2).copied().unwrap_or(0.0);
        let fstart = positional.get(3).copied();
        let fstop = positional.get(4).copied();

        let f2 = if numf2 != 0.0 && f2overf1 > 0.0 {
            Some(f1 * f2overf1)
        } else {
            None
        };

        self.netlist.disto_statements.push(DistoStatement {
            f1,
            f2,
            output_node,
            a2,
            a3,
            fstart,
            fstop,
        });
        let mut params = vec![("f1".to_string(), f1)];
        if let Some(f2v) = f2 {
            params.push(("f2".to_string(), f2v));
        }
        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Disto,
            params,
        });
        Ok(())
    }

    /// `.SENS output [param1 param2 ...]`
    ///
    /// Parses:
    ///   `.SENS V(node)`                 — sensitivity of node voltage to all devices
    ///   `.SENS V(node) R1 R2 Vcc`      — sensitivity to specific devices
    ///   `.SENS I(vsrc) R1`             — sensitivity of branch current
    ///
    /// The tokenizer emits `V(2)` as separate tokens:
    ///   Word("v"), LeftParen, Word("2") | Number(2.0), RightParen
    /// so we handle both that multi-token form and the rare single-token form.
    fn parse_sens(&mut self) -> Result<(), SimError> {

        let line = self.collect_line();
        if line.is_empty() {
            return Err(SimError::Parse(".SENS: expected output spec like V(node)".into()));
        }

        // First token must be a Word: "v", "i", or "v(node)"/"i(vname)" as one token.
        let kind_str = match &line[0] {
            Token::Word(s) => s.to_lowercase(),
            _ => {
                return Err(SimError::Parse(
                    ".SENS: expected V(node) or I(vname) as first argument".into(),
                ))
            }
        };

        // Form (a): the whole spec is in one Word token, e.g. "v(out)".
        // Form (b): separate tokens Word("v") LeftParen Word/Number(name) RightParen.
        let (output, params_start) = if kind_str.contains('(') {
            // Form (a): extract inner name by stripping "v(" / "i(" prefix and ")" suffix.
            let is_v = kind_str.starts_with('v');
            let inner = kind_str
                .trim_start_matches(|c: char| c == 'v' || c == 'i')
                .trim_matches(|c: char| c == '(' || c == ')')
                .to_string();
            let out = if is_v {
                SensOutputSpec::NodeVoltage(inner)
            } else {
                SensOutputSpec::BranchCurrent(inner)
            };
            (out, 1usize)
        } else if (kind_str == "v" || kind_str == "i")
            && line.len() >= 4
            && matches!(line[1], Token::LeftParen)
            && matches!(line[3], Token::RightParen)
        {
            // Form (b): reassemble node name from middle token.
            let inner = match &line[2] {
                Token::Word(s) => s.clone(),
                Token::Number(n) => {
                    // Numeric node names like "2" arrive as Number tokens.
                    if n.fract() == 0.0 && *n >= 0.0 {
                        format!("{}", *n as u64)
                    } else {
                        format!("{n}")
                    }
                }
                _ => {
                    return Err(SimError::Parse(
                        ".SENS: expected node name inside V(...) or I(...)".into(),
                    ))
                }
            };
            let out = if kind_str == "v" {
                SensOutputSpec::NodeVoltage(inner)
            } else {
                SensOutputSpec::BranchCurrent(inner)
            };
            (out, 4usize)
        } else {
            return Err(SimError::Parse(format!(
                ".SENS: unrecognised output spec '{kind_str}', expected V(...) or I(...)"
            )));
        };

        // Remaining Word tokens (after the output spec) are device names.
        let params: Vec<String> = line[params_start..]
            .iter()
            .filter_map(|t| {
                if let Token::Word(s) = t {
                    Some(s.clone())
                } else {
                    None
                }
            })
            .collect();

        self.netlist.analyses.push(AnalysisStatement {
            kind: AnalysisKind::Sens { output, params },
            params: vec![],
        });
        Ok(())
    }

    /// Parse a B-source line and store the result in `pending_bsources`.
    ///
    /// Syntax: `Bname n+ n- V={expr}` or `Bname n+ n- I={expr}`.
    ///
    /// Unsupported forms (time, temper, frequency, I(vname), TABLE, LAPLACE)
    /// return `SimError::Parse` with a descriptive message.
    fn parse_bsource_pending(
        &mut self,
        name: &str,
        line: &[Token],
    ) -> Result<(), SimError> {
        if line.len() < 3 {
            return Err(SimError::Parse(format!(
                "B-source '{name}': expected 'n+ n- V={{expr}}' or 'n+ n- I={{expr}}'"
            )));
        }

        let np = Self::token_to_node_name(&line[0])?;
        let nn = Self::token_to_node_name(&line[1])?;

        // Expect: V={expr} or I={expr} or V=TABLE {x} = (x,y) ... or I=TABLE ...
        if line.len() < 4 {
            return Err(SimError::Parse(format!(
                "B-source '{name}': missing V={{...}} or I={{...}}"
            )));
        }

        let form_word = match &line[2] {
            Token::Word(w) => w.clone(),
            other => {
                return Err(SimError::Parse(format!(
                    "B-source '{name}': expected 'V' or 'I', got '{other}'"
                )));
            }
        };

        match form_word.as_str() {
            "v" | "i" => {}
            "laplace" => {
                return Err(SimError::Parse(format!(
                    "B-source '{name}': LAPLACE form not yet supported"
                )));
            }
            other => {
                return Err(SimError::Parse(format!(
                    "B-source '{name}': unrecognized form '{other}' (expected V or I)"
                )));
            }
        }

        if line[3] != Token::Equals {
            return Err(SimError::Parse(format!(
                "B-source '{name}': expected '=' after '{form_word}'"
            )));
        }

        let kind = if form_word == "v" {
            DeviceKind::BsourceV
        } else {
            DeviceKind::BsourceI
        };

        let behavioral = Self::parse_bsource_rhs(name, &line[4..])?;

        self.pending_bsources.push(PendingBsource {
            name: name.to_string(),
            node_p: np,
            node_n: nn,
            kind,
            expr: behavioral,
        });
        Ok(())
    }

    /// Parse an XSPICE A-device line and store in `pending_a_devices`.
    ///
    /// Syntax forms:
    /// - `Aname [in1 in2 ...] [out1 out2 ...] model_name` — digital port syntax
    /// - `Aname (in1) (out1) model_name` — ngspice analog port syntax with ()
    ///
    /// The model name (e.g. `d_inverter`, `adc_bridge`, `dac_bridge`) is stored
    /// and resolved during circuit build to instantiate the appropriate digital
    /// primitive or bridge.
    fn parse_a_device_pending(&mut self, name: &str, line: &[Token]) -> Result<(), SimError> {
        if line.is_empty() {
            return Err(SimError::Parse(format!(
                "A-device '{name}': empty device line"
            )));
        }

        // Reconstruct the line as a string for simpler parsing of bracketed groups.
        // The original line uses () for analog ports and [] for digital ports.
        let line_str: String = line.iter()
            .map(|t| format!("{t} "))
            .collect();
        let line_str = line_str.trim();

        // Try to parse using the digital crate's parse_a_element which handles both () and []
        // We need to reconstruct the full line including the name prefix
        let full_line = format!("A{} {}", name, line_str);

        // Use the same parsing logic as parse_a_element from the digital crate
        // but adapted for token-based parsing here
        let (inputs, outputs, model_name) = self.parse_a_device_tokens(name, line)?;

        self.pending_a_devices.push(PendingADevice {
            name: name.to_string(),
            inputs,
            outputs,
            model_name,
        });
        Ok(())
    }

    /// Parse A-device tokens to extract inputs, outputs, and model name.
    ///
    /// Handles both:
    /// - `Aname [in1 in2] [out1] model_name` — bracket syntax
    /// - `Aname (in1) (out1) model_name` — parenthesis syntax (ngspice analog ports)
    fn parse_a_device_tokens(&mut self, name: &str, line: &[Token]) -> Result<(Vec<String>, Vec<String>, String), SimError> {
        // A-device format: [inputs] [outputs] model_name
        // where inputs/outputs can be [] or () delimited groups
        // or even plain space-separated nodes (simplified form)

        let mut inputs: Vec<String> = Vec::new();
        let mut outputs: Vec<String> = Vec::new();
        let mut model_name = String::new();
        let mut phase = 0; // 0 = looking for input group, 1 = looking for output group, 2 = model name

        let mut i = 0;
        while i < line.len() {
            let tok = &line[i];
            match tok {
                // Handle opening bracket/paren - start of a group
                Token::LeftBrace | Token::LeftParen => {
                    let close = if matches!(tok, Token::LeftBrace) { Token::RightBrace } else { Token::RightParen };
                    let mut j = i + 1;
                    let mut group: Vec<String> = Vec::new();
                    while j < line.len() && line[j] != close {
                        if let Token::Word(w) = &line[j] {
                            group.push(w.clone());
                        }
                        j += 1;
                    }
                    if j >= line.len() {
                        return Err(SimError::Parse(format!(
                            "A-device '{name}': unclosed group"
                        )));
                    }
                    // Consume tokens until the closing bracket
                    i = j + 1; // skip closing bracket too

                    if phase == 0 {
                        inputs.extend(group);
                        phase = 1;
                    } else if phase == 1 {
                        outputs.extend(group);
                        phase = 2;
                    } else {
                        return Err(SimError::Parse(format!(
                            "A-device '{name}': too many groups"
                        )));
                    }
                }
                // Handle a bare word (could be a single-node group or the model name)
                Token::Word(w) => {
                    // Check if next token might be another word (meaning this is a node, not model)
                    // or if this is the model name (last token)
                    if i + 1 < line.len() {
                        if let Token::Word(_) = &line[i + 1] {
                            // Next token is also a word, so this is a node
                            if phase == 0 {
                                inputs.push(w.clone());
                                phase = 1;
                            } else if phase == 1 {
                                outputs.push(w.clone());
                                phase = 2;
                            } else {
                                return Err(SimError::Parse(format!(
                                    "A-device '{name}': too many nodes before model name"
                                )));
                            }
                            i += 1;
                            continue;
                        }
                    }
                    // This is the model name (either last token, or followed by non-word)
                    if phase < 2 {
                        // Model name comes early - remaining tokens are outputs then model
                        if phase == 0 {
                            // No groups found, assume all words before model are inputs
                            model_name = w.clone();
                            phase = 3;
                        } else if phase == 1 {
                            // phase 1 means we had inputs but no outputs group yet
                            // w must be the model name, outputs remain empty
                            model_name = w.clone();
                            phase = 3;
                        }
                    } else {
                        model_name = w.clone();
                    }
                    i += 1;
                }
                _ => {
                    i += 1;
                }
            }
        }

        if model_name.is_empty() {
            return Err(SimError::Parse(format!(
                "A-device '{name}': missing model name"
            )));
        }

        Ok((inputs, outputs, model_name))
    }

    /// Parse the right-hand side of `V=` / `I=` / `VALUE=` for B/E/G elements.
    ///
    /// Recognizes:
    /// - `{expr}` — brace-enclosed behavioral expression
    /// - `TABLE {expr} = (x0,y0) (x1,y1) ...` — table form
    /// - `TABLE {expr} (x0,y0) (x1,y1) ...` — without `=` (ngspice tolerance)
    ///
    /// Rejects `LAPLACE` with a clear error.
    fn parse_bsource_rhs(name: &str, tokens: &[Token]) -> Result<BehavioralExpr, SimError> {
        // Skip leading whitespace-equivalent tokens.
        let tokens = Self::trim_trailing_eol(tokens);
        if tokens.is_empty() {
            return Err(SimError::Parse(format!(
                "B-source '{name}': empty expression"
            )));
        }

        // Detect TABLE form.
        if let Token::Word(w) = &tokens[0] {
            match w.as_str() {
                "table" => {
                    return Self::parse_table_form(name, &tokens[1..]);
                }
                "laplace" => {
                    return Err(SimError::Parse(format!(
                        "B-source '{name}': LAPLACE form not yet supported"
                    )));
                }
                _ => {}
            }
        }

        // Brace expression form.
        let (parsed_expr, _consumed) = parse_brace_expression(tokens).map_err(|e| {
            SimError::Parse(format!("B-source '{name}': {e}"))
        })?;

        Self::check_bsource_expr_support(name, &parsed_expr)?;
        Self::expr_to_behavioral(&parsed_expr)
    }

    /// Parse `TABLE {expr} = (x,y) (x,y) ...` after the `TABLE` keyword has
    /// been consumed.
    ///
    /// Produces a `__table__` BehavioralExpr Func node where the first argument
    /// is the input expression and the remaining arguments are alternating
    /// (x_i, y_i) literal pairs.  The device-side flat AST decodes this back
    /// into a real `Table` node with linear-interpolation lookup.
    fn parse_table_form(name: &str, tokens: &[Token]) -> Result<BehavioralExpr, SimError> {
        let tokens = Self::trim_trailing_eol(tokens);
        if tokens.is_empty() || tokens[0] != Token::LeftBrace {
            return Err(SimError::Parse(format!(
                "B-source '{name}': expected '{{expr}}' after TABLE"
            )));
        }
        let (input_expr, consumed) = parse_brace_expression(tokens).map_err(|e| {
            SimError::Parse(format!("B-source '{name}': TABLE input: {e}"))
        })?;

        // After the brace expression, optionally consume `=`.
        let mut i = consumed;
        if i < tokens.len() && tokens[i] == Token::Equals {
            i += 1;
        }

        // Parse breakpoint pairs: (x, y) (x, y) ...
        let mut points: Vec<(f64, f64)> = Vec::new();
        while i < tokens.len() {
            // Skip stray newlines / EOF / comma.
            match &tokens[i] {
                Token::Newline | Token::Eof => {
                    i += 1;
                    continue;
                }
                Token::Comma => {
                    i += 1;
                    continue;
                }
                _ => {}
            }
            if tokens[i] != Token::LeftParen {
                return Err(SimError::Parse(format!(
                    "B-source '{name}': TABLE expected '(' for breakpoint, got '{}'",
                    tokens[i]
                )));
            }
            i += 1;
            // X value
            let (x, used) = Self::tokens_to_signed_number(&tokens[i..]).ok_or_else(|| {
                SimError::Parse(format!("B-source '{name}': TABLE expected X breakpoint"))
            })?;
            i += used;
            // Optional comma
            if i < tokens.len() && tokens[i] == Token::Comma {
                i += 1;
            }
            // Y value
            let (y, used) = Self::tokens_to_signed_number(&tokens[i..]).ok_or_else(|| {
                SimError::Parse(format!("B-source '{name}': TABLE expected Y breakpoint"))
            })?;
            i += used;
            // Closing paren
            if i >= tokens.len() || tokens[i] != Token::RightParen {
                return Err(SimError::Parse(format!(
                    "B-source '{name}': TABLE expected ')' after breakpoint",
                )));
            }
            i += 1;
            points.push((x, y));
        }

        if points.is_empty() {
            return Err(SimError::Parse(format!(
                "B-source '{name}': TABLE requires at least one (x,y) breakpoint"
            )));
        }

        Self::check_bsource_expr_support(name, &input_expr)?;
        let input_be = Self::expr_to_behavioral(&input_expr)?;

        // Build a __table__ Func: first arg is the input expression, then
        // alternating (x_i, y_i) literals.
        let mut args: Vec<BehavioralExpr> = Vec::with_capacity(1 + 2 * points.len());
        args.push(input_be);
        for (x, y) in points {
            args.push(BehavioralExpr::Lit(x));
            args.push(BehavioralExpr::Lit(y));
        }
        Ok(BehavioralExpr::Func("__table__".into(), args))
    }

    /// Parse a TABLE-controlled E or G element and emit a PendingBsource.
    ///
    /// Syntax: `Ename n+ n- TABLE {expr} = (x0,y0) (x1,y1) ...`
    ///
    /// For VCVS: the B-source voltage is `V(n+, n-) = table_expr(V(expr))`.
    /// For VCCS: the B-source current is `I = table_expr(V(expr))`.
    fn parse_table_device(
        &mut self,
        name: &str,
        kind: DeviceKind,
        n_out_p: &str,
        n_out_n: &str,
        tokens: &[Token],
    ) -> Result<Option<ElementStatement>, SimError> {
        // Use the same parsing as B-source TABLE.
        let table_expr = Self::parse_table_form(name, tokens)?;

        let b_kind = match kind {
            DeviceKind::Vcvs => DeviceKind::BsourceV,
            DeviceKind::Vccs => DeviceKind::BsourceI,
            _ => {
                return Err(SimError::Parse(format!(
                    "TABLE: invalid device kind '{kind:?}' for TABLE"
                )));
            }
        };

        self.pending_bsources.push(PendingBsource {
            name: format!("b_tbl_{name}"),
            node_p: n_out_p.to_string(),
            node_n: n_out_n.to_string(),
            kind: b_kind,
            expr: table_expr,
        });
        Ok(None)
    }

    /// Strip trailing Newline / Eof tokens from a token slice.
    fn trim_trailing_eol(tokens: &[Token]) -> &[Token] {
        let mut end = tokens.len();
        while end > 0 && matches!(tokens[end - 1], Token::Newline | Token::Eof) {
            end -= 1;
        }
        &tokens[..end]
    }

    /// Check an expression for unsupported B-source features.
    ///
    /// As of Phase 2.1, the following are now SUPPORTED and pass through:
    /// - `time`, `temper`, `frequency` references (built-in pseudo-params)
    /// - `I(vname)` branch-current references — converted to `__branch_current__`
    /// - `__table__(...)` and `__branch_current__(...)` marker forms produced
    ///   by the parser when desugaring `TABLE` / `I(vname)` syntax
    ///
    /// LAPLACE is still rejected — only the parser stub is implemented.
    fn check_bsource_expr_support(name: &str, expr: &Expression) -> Result<(), SimError> {
        match expr {
            Expression::Func(fname, args) => {
                if fname.as_str() == "laplace" {
                    return Err(SimError::Parse(format!(
                        "B-source '{name}': LAPLACE form not yet supported"
                    )));
                }
                for a in args {
                    Self::check_bsource_expr_support(name, a)?;
                }
            }
            Expression::BinOp(_, l, r) => {
                Self::check_bsource_expr_support(name, l)?;
                Self::check_bsource_expr_support(name, r)?;
            }
            Expression::UnaryMinus(inner) => {
                Self::check_bsource_expr_support(name, inner)?;
            }
            _ => {}
        }
        Ok(())
    }

    /// Convert a `bigospice_parser::Expression` into a `bigospice_core::BehavioralExpr`.
    ///
    /// Special-case the smuggled markers used by the device-side flat AST:
    /// - `time` / `temper` / `frequency` (as bare Param) → BehavioralExpr::Param
    ///   with the same name; the device side recognizes them.
    /// - `I(name)` Func with single Param argument → `__branch_current__(name)`
    ///   marker.
    fn expr_to_behavioral(expr: &Expression) -> Result<BehavioralExpr, SimError> {
        match expr {
            Expression::Literal(v) => Ok(BehavioralExpr::Lit(*v)),
            Expression::Param(name) => match name.as_str() {
                "time" | "temper" | "frequency" => {
                    Ok(BehavioralExpr::Param(name.clone()))
                }
                _ => Ok(BehavioralExpr::Param(name.clone())),
            },
            Expression::NodeVoltage(node) => Ok(BehavioralExpr::NodeVoltage(node.clone())),
            Expression::UnaryMinus(inner) => {
                Ok(BehavioralExpr::Neg(Box::new(Self::expr_to_behavioral(inner)?)))
            }
            Expression::BinOp(op, lhs, rhs) => {
                let l = Self::expr_to_behavioral(lhs)?;
                let r = Self::expr_to_behavioral(rhs)?;
                let bop = match op {
                    Op::Add => BehavioralBinOp::Add,
                    Op::Sub => BehavioralBinOp::Sub,
                    Op::Mul => BehavioralBinOp::Mul,
                    Op::Div => BehavioralBinOp::Div,
                    Op::Pow => BehavioralBinOp::Pow,
                };
                Ok(BehavioralExpr::BinOp(bop, Box::new(l), Box::new(r)))
            }
            Expression::Func(name, args) => {
                // Special-case I(vname): a single-argument Param becomes a
                // branch current marker.
                if name == "i" && args.len() == 1 {
                    if let Expression::Param(vname) = &args[0] {
                        return Ok(BehavioralExpr::Func(
                            "__branch_current__".into(),
                            vec![BehavioralExpr::Param(vname.clone())],
                        ));
                    }
                }
                let converted: Result<Vec<_>, _> =
                    args.iter().map(Self::expr_to_behavioral).collect();
                Ok(BehavioralExpr::Func(name.clone(), converted?))
            }
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Extract a node name from a token (Word or Number treated as node name string).
    fn token_to_node_name(tok: &Token) -> Result<String, SimError> {
        match tok {
            Token::Word(s) => Ok(s.clone()),
            Token::Number(n) => {
                // Numeric node names like "0", "1", "2".
                if *n == (*n as u64) as f64 && *n >= 0.0 {
                    Ok(format!("{}", *n as u64))
                } else {
                    Ok(format!("{n}"))
                }
            }
            _ => Err(SimError::Parse(format!(
                "expected node name, got '{tok}'"
            ))),
        }
    }

    /// Try to extract a numeric value from a token.
    fn token_to_number(tok: &Token) -> Option<f64> {
        match tok {
            Token::Number(n) => Some(*n),
            Token::Word(s) => Si::parse_spice_value(s),
            _ => None,
        }
    }

    /// Parse a possibly-negative number from a token slice.
    /// Returns `(value, tokens_consumed)`.
    /// Handles `Number`, `Minus Number`, and `Plus Number`.
    fn tokens_to_signed_number(tokens: &[Token]) -> Option<(f64, usize)> {
        if tokens.is_empty() {
            return None;
        }
        match &tokens[0] {
            Token::Minus if tokens.len() >= 2 => {
                Self::token_to_number(&tokens[1]).map(|v| (-v, 2))
            }
            Token::Plus if tokens.len() >= 2 => {
                Self::token_to_number(&tokens[1]).map(|v| (v, 2))
            }
            other => Self::token_to_number(other).map(|v| (v, 1)),
        }
    }

    /// Read a numeric value from a token slice, accepting either:
    ///   * a bare (possibly-signed) number such as `1k`, `-3.14`, `+5e-3`
    ///   * a brace expression `{ 2*pi*f }` evaluated against `params`
    ///
    /// Returns `(value, tokens_consumed)`. Used everywhere a numeric slot
    /// appears in a SPICE directive, so brace expressions are accepted
    /// uniformly across element values, source parameters, options, .IC,
    /// .NODESET, .TEMP, .DC, .TRAN, .AC, .STEP, and model params.
    fn tokens_to_numeric_or_brace(
        tokens: &[Token],
        params: &AHashMap<String, f64>,
    ) -> Option<(f64, usize)> {
        if tokens.is_empty() {
            return None;
        }
        if tokens[0] == Token::LeftBrace {
            let (expr, consumed) = parse_brace_expression(tokens).ok()?;
            let val = eval_expression(&expr, params).ok()?;
            return Some((val, consumed));
        }
        // T.4: HSPICE single-quote arithmetic expression: '2*pi*f'
        if let Token::SingleQuoteExpr(ref s) = tokens[0] {
            let val = Self::eval_single_quote_expr(s, params)?;
            return Some((val, 1));
        }
        Self::tokens_to_signed_number(tokens)
    }

    /// Evaluate a bare expression string taken from a single-quoted HSPICE
    /// token (e.g. `R0*SCALE`).  Known `.PARAM` names are substituted before
    /// parsing so they resolve to their numeric values.
    fn eval_single_quote_expr(s: &str, params: &AHashMap<String, f64>) -> Option<f64> {
        // Lex the inner string and substitute Word tokens that match param names.
        let mut lex = Lexer::new(s);
        let mut toks = lex.tokenize_all().ok()?;
        for tok in &mut toks {
            if let Token::Word(ref w) = tok.clone() {
                if let Some(&v) = params.get(w.as_str()) {
                    *tok = Token::Number(v);
                }
            }
        }
        // Drop the trailing Eof so parse_expression sees a clean stream.
        if toks.last() == Some(&Token::Eof) {
            toks.pop();
        }
        let expr = parse_expression(&toks).ok()?;
        eval_expression(&expr, params).ok()
    }

    /// Try to parse `key=value` (or `key={expr}`) from a token slice.
    /// Returns `(key, value, tokens_consumed)`.
    fn try_parse_kv_param(tokens: &[Token]) -> Option<(String, f64, usize)> {
        // Without a params context this can only handle numeric literals.
        Self::try_parse_kv_param_with(tokens, &AHashMap::new())
    }

    /// Same as `try_parse_kv_param` but evaluates brace expressions against
    /// the supplied `.PARAM` map. This is the variant used by element parsers
    /// after a `params` snapshot is available.
    fn try_parse_kv_param_with(
        tokens: &[Token],
        params: &AHashMap<String, f64>,
    ) -> Option<(String, f64, usize)> {
        if tokens.len() < 3 {
            return None;
        }
        let (Token::Word(key), Token::Equals) = (&tokens[0], &tokens[1]) else {
            return None;
        };
        // Brace-expression form: key = { expr }
        if tokens[2] == Token::LeftBrace {
            let (expr, consumed) = parse_brace_expression(&tokens[2..]).ok()?;
            let val = eval_expression(&expr, params).ok()?;
            return Some((key.clone(), val, 2 + consumed));
        }
        // T.4: HSPICE single-quote expression: key = 'expr'
        if let Token::SingleQuoteExpr(ref s) = tokens[2] {
            let val = Self::eval_single_quote_expr(s, params)?;
            return Some((key.clone(), val, 3));
        }
        // Signed numeric form: key = -1.23 / +1k / 3.14
        if let Some((val, consumed)) = Self::tokens_to_signed_number(&tokens[2..]) {
            return Some((key.clone(), val, 2 + consumed));
        }
        None
    }

    /// Read a numeric value from the current position.
    fn read_numeric_value(&mut self) -> Result<f64, SimError> {
        let negative = if matches!(self.peek(), Token::Minus) {
            self.advance();
            true
        } else {
            false
        };

        let val = match self.peek().clone() {
            Token::Number(n) => { self.advance(); n }
            Token::Word(ref s) => {
                let s = s.clone();
                self.advance();
                Si::parse_spice_value(&s).ok_or_else(|| {
                    SimError::Parse(format!("expected numeric value, got '{s}'"))
                })?
            }
            other => {
                return Err(SimError::Parse(format!(
                    "expected numeric value, got '{other}'"
                )));
            }
        };

        Ok(if negative { -val } else { val })
    }

    /// Skip tokens until end of line.
    #[allow(dead_code)]
    fn skip_to_line_end(&mut self) {
        loop {
            match self.peek() {
                Token::Newline => {
                    self.advance();
                    break;
                }
                Token::Eof => break,
                _ => {
                    self.advance();
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Circuit building
    // -----------------------------------------------------------------------

    /// Convert the parsed netlist into a `Circuit`, analysis statements, and sim options.
    fn build_circuit(mut self) -> Result<(Circuit, Vec<AnalysisStatement>, bigospice_core::SimOptions, Vec<ExtractSpec>), SimError> {
        // ── Subcircuit expansion ──────────────────────────────────────────
        // Build a case-insensitive lookup: lowercase name -> SubcircuitDef.
        let subckt_defs: AHashMap<String, &SubcircuitDef> = self
            .netlist
            .subcircuits
            .iter()
            .map(|d| (d.name.to_lowercase(), d))
            .collect();

        let globals: Vec<String> = self.netlist.globals.clone();

        if !self.netlist.pending_subckt_instances.is_empty() {
            let instances = std::mem::take(&mut self.netlist.pending_subckt_instances);
            let mut expanded: Vec<ElementStatement> = Vec::new();
            let mut stack: Vec<String> = Vec::new();
            Self::expand_instances(&instances, &subckt_defs, &globals, &mut expanded, &mut stack)?;
            self.netlist.elements.extend(expanded);
        }

        let mut circuit = Circuit::new();

        // Build a model lookup: model_name -> ModelStatement.
        let models: AHashMap<String, &ModelStatement> = self
            .netlist
            .models
            .iter()
            .map(|m| (m.name.clone(), m))
            .collect();

        // V-source AC stimuli must be registered after all nodes and B-source
        // devices are added so that circuit.num_vars() is final.  During the
        // element loop we only record (dev_id, re, im); the branch_row is
        // computed in the post-pass below.
        let mut pending_vsrc_stimuli: Vec<(DeviceId, f64, f64)> = Vec::new();

        for elem in &self.netlist.elements {
            // Resolve nodes.
            let node_ids: Vec<NodeId> = elem
                .nodes
                .iter()
                .map(|n| circuit.add_node(n))
                .collect();

            // Build terminals: pin index = position in node list.
            let terminals: Vec<(u8, NodeId)> = node_ids
                .iter()
                .enumerate()
                .map(|(i, &nid)| (i as u8, nid))
                .collect();

            // Determine actual DeviceKind (may differ for MOSFET N vs P, GP vs VBIC).
            let kind = if let Some(ref model_name) = elem.model_name {
                if let Some(model) = models.get(model_name) {
                    let level = model.params.iter()
                        .find(|(k, _)| k.eq_ignore_ascii_case("level"))
                        .map(|(_, v)| *v as u32)
                        .unwrap_or(1);
                    match model.kind.as_str() {
                        "pmos" => match level {
                            2 => DeviceKind::MosfetP2,
                            3 => DeviceKind::MosfetP3,
                            6 | 9 => DeviceKind::MosfetP6,
                            8 | 49 => DeviceKind::Bsim3P,
                            14 | 54 => DeviceKind::Bsim4P,
                            _ => DeviceKind::MosfetP,
                        },
                        "nmos" => match level {
                            2 => DeviceKind::MosfetN2,
                            3 => DeviceKind::MosfetN3,
                            6 | 9 => DeviceKind::MosfetN6,
                            8 | 49 => DeviceKind::Bsim3N,
                            14 | 54 => DeviceKind::Bsim4N,
                            _ => DeviceKind::MosfetN,
                        },
                        // JFET N-channel (NJF)
                        "njf" => DeviceKind::JfetN,
                        // JFET P-channel (PJF)
                        "pjf" => DeviceKind::JfetP,
                        // MESFET N-channel (NMF)
                        "nmf" => DeviceKind::MesfetN,
                        // MESFET P-channel (PMF)
                        "pmf" => DeviceKind::MesfetP,
                        // NPN: LEVEL=4 or model type "vbic" → VbicNpn
                        "npn" if level == 4 => DeviceKind::VbicNpn,
                        "npn" => DeviceKind::BjtNpn,
                        // PNP: LEVEL=4 or model type "vbic" → VbicPnp
                        "pnp" if level == 4 => DeviceKind::VbicPnp,
                        "pnp" => DeviceKind::BjtPnp,
                        // Explicit VBIC model type (ngspice uses "vbic" for both NPN/PNP)
                        "vbic" => {
                            // Determine polarity from elem.kind (parser set BjtNpn as default)
                            // Check elem params or model name for "npn"/"pnp" hint.
                            // Default to NPN.
                            if elem.kind == DeviceKind::BjtPnp {
                                DeviceKind::VbicPnp
                            } else {
                                DeviceKind::VbicNpn
                            }
                        }
                        _ => elem.kind,
                    }
                } else {
                    elem.kind
                }
            } else {
                elem.kind
            };

            let mut device = DeviceInstance::new(
                DeviceId::new(0), // placeholder; Circuit::add_device assigns the real ID
                &elem.name,
                kind,
                &terminals,
            );

            // If the resolved kind is PMOS (any level), ensure the "pmos" flag is set
            // so the device model can flip voltage polarities correctly.
            if matches!(kind, DeviceKind::MosfetP | DeviceKind::MosfetP2
                             | DeviceKind::MosfetP3 | DeviceKind::MosfetP6) {
                device.params.set("pmos", 1.0);
            }

            // If the resolved kind is P-channel JFET, set the "pjfet" flag so
            // the device model can flip voltage polarities correctly.
            if kind == DeviceKind::JfetP {
                device.params.set("pjfet", 1.0);
            }

            // If the resolved kind is P-channel MESFET, set the "pmesfet" flag so
            // the device model can flip voltage polarities correctly.
            if kind == DeviceKind::MesfetP {
                device.params.set("pmesfet", 1.0);
            }

            // Apply element params.
            for (k, v) in &elem.params {
                device.params.set(k, *v);
            }

            // Apply model params (element params override model params).
            if let Some(ref model_name) = elem.model_name {
                if let Some(model) = models.get(model_name) {
                    eprintln!("[DEBUG] device '{}' model '{}' kind='{}' params={:?}", elem.name, model_name, model.kind, model.params);
                    for (k, v) in &model.params {
                        if !device.params.contains(k) {
                            device.params.set(k, *v);
                        }
                    }
                } else {
                    eprintln!("[DEBUG] device '{}' model '{}' NOT FOUND in models table", elem.name, model_name);
                    eprintln!("[DEBUG]   available models: {:?}", models.keys().collect::<Vec<_>>());
                }
            }

            // VBIC thermal node: when rth > 0 in the model/element params, add an
            // internal thermal node as pin 4 (ΔT).  This must be done after params
            // are merged so the rth value is visible.
            if matches!(kind, DeviceKind::VbicNpn | DeviceKind::VbicPnp) {
                let rth = device.params.get_or("rth", 0.0);
                if rth > 0.0 {
                    // create (or look up) an internal node named _<devname>_th
                    let th_node = circuit.add_internal_node(&elem.name, "th");
                    device.terminals.push(Terminal::new(4, th_node));
                }
            }

            // BJT extrinsic resistances: when rb/rc/re > 0, create internal nodes
            // for the intrinsic device (C', B', E').  This must be done after params
            // are merged so the resistance values are visible.
            //
            // Pin layout with internal nodes:
            //   0 = Collector (external)    3 = Collector' (internal, after RC)
            //   1 = Base (external)         4 = Base'      (internal, after RB)
            //   2 = Emitter (external)      5 = Emitter'   (internal, after RE)
            //
            // The eval_with_extrinsic function in bjt.rs expects exactly 6 voltages;
            // it falls back to 3-terminal eval when voltages.len() < 6.
            if matches!(kind, DeviceKind::BjtNpn | DeviceKind::BjtPnp) {
                let rb = device.params.get_or("rb", 0.0);
                let rc = device.params.get_or("rc", 0.0);
                let re = device.params.get_or("re", 0.0);
                if rb > 0.0 || rc > 0.0 || re > 0.0 {
                    let ci_node = circuit.add_internal_node(&elem.name, "ci");
                    let bi_node = circuit.add_internal_node(&elem.name, "bi");
                    let ei_node = circuit.add_internal_node(&elem.name, "ei");
                    device.terminals.push(Terminal::new(4, ci_node));
                    device.terminals.push(Terminal::new(5, bi_node));
                    device.terminals.push(Terminal::new(6, ei_node));
                }
            }

            // T.2: Apply M= multiplier for passive elements.
            //
            // M=N means N devices in parallel:
            //   Resistor:  parallel resistors → effective R = R/M  (or G = M*G)
            //   Capacitor: parallel caps      → effective C = M*C
            //   Inductor:  parallel inductors → effective L = L/M
            //   Diode:     M parallel diodes  → scale IS by M (stored as "m" param;
            //              the diode model reads it directly)
            //
            // For R/C/L we bake the scaling into the primary parameter so that
            // every downstream consumer (MNA stamp, sensitivity, cache) sees the
            // correct effective value without any further changes.
            if let Some(m) = device.params.get("m") {
                if m != 1.0 {
                    match kind {
                        DeviceKind::Resistor => {
                            if let Some(r) = device.params.get("resistance") {
                                device.params.set("resistance", r / m);
                            }
                        }
                        DeviceKind::Capacitor => {
                            if let Some(c) = device.params.get("capacitance") {
                                device.params.set("capacitance", c * m);
                            }
                        }
                        DeviceKind::Inductor => {
                            if let Some(l) = device.params.get("inductance") {
                                device.params.set("inductance", l / m);
                            }
                        }
                        // Diode: leave "m" param in place; the diode model scales IS.
                        _ => {}
                    }
                }
            }

            let dev_id = circuit.add_device(device);

            // Register AC stimulus for V/I sources that carry an `ac` param.
            let ac_mag = elem.params.iter().find(|(k, _)| k == "ac").map(|(_, v)| *v);
            if let Some(mag) = ac_mag {
                let phase = elem.params.iter().find(|(k, _)| k == "ac_phase").map(|(_, v)| *v).unwrap_or(0.0);
                let re = mag * phase.to_radians().cos();
                let im = mag * phase.to_radians().sin();

                match kind {
                    DeviceKind::VoltageSource => {
                        // Defer branch_row computation: num_vars is not yet final
                        // (later elements and B-sources may still add nodes).
                        // Store (dev_id, re, im) and resolve in the post-pass below.
                        pending_vsrc_stimuli.push((dev_id, re, im));
                    }
                    DeviceKind::CurrentSource => {
                        // node_ids[0] = positive node, node_ids[1] = negative node.
                        let pos = node_ids.first().and_then(|n| {
                            if n.is_ground() { None } else { Some((n.0 - 1) as usize) }
                        });
                        let neg = node_ids.get(1).and_then(|n| {
                            if n.is_ground() { None } else { Some((n.0 - 1) as usize) }
                        });
                        if let Some(pos_row) = pos {
                            circuit.add_ac_stimulus(AcStimulus::CurrentSource(pos_row, neg, re, im));
                        }
                    }
                    _ => {}
                }
            }
        }

        // ── Wire up B-source devices ─────────────────────────────────────
        for pb in &self.pending_bsources {
            let np = circuit.add_node(&pb.node_p);
            let nn = circuit.add_node(&pb.node_n);
            let terminals = [(0u8, np), (1u8, nn)];
            let device = DeviceInstance::new(
                DeviceId::new(0), // placeholder
                &pb.name,
                pb.kind,
                &terminals,
            );
            let dev_id = circuit.add_device(device);
            let bse = BsourceExpr::new(pb.expr.clone());
            circuit.add_bsource_expr(dev_id, bse);
        }

        // ── AC stimulus post-pass (V-sources) ────────────────────────────
        // num_vars is now final (all nodes, including B-source internal nodes,
        // have been added).  Compute the correct MNA branch row for each
        // deferred V-source stimulus.
        let final_num_vars = circuit.num_vars() as usize;
        for (dev_id, re, im) in pending_vsrc_stimuli {
            let dev = &circuit.devices()[dev_id.index()];
            if let Some(bi) = dev.branch_index {
                let branch_row = final_num_vars + bi as usize;
                circuit.add_ac_stimulus(AcStimulus::VoltageSource(branch_row, re, im));
            }
        }

        // ── Initial conditions (.IC) ──────────────────────────────────────
        for (node_name, voltage) in &self.netlist.initial_conditions {
            let node_id = circuit.find_node(node_name).ok_or_else(|| {
                SimError::Parse(format!(
                    ".IC: node '{}' not found in circuit",
                    node_name
                ))
            })?;
            circuit.add_initial_condition(node_id, *voltage);
        }

        // ── Node-set biases (.NODESET) ────────────────────────────────────
        for (node_name, voltage) in &self.netlist.node_sets {
            let node_id = circuit.find_node(node_name).ok_or_else(|| {
                SimError::Parse(format!(
                    ".NODESET: node '{}' not found in circuit",
                    node_name
                ))
            })?;
            circuit.add_node_set(node_id, *voltage);
        }

        // ── Operating temperatures (.TEMP) ───────────────────────────────
        // Values in netlist.temperatures are Kelvin (converted from Celsius at parse time).
        // Circuit::add_temperature stores the value directly; we pass Kelvin here.
        for &kelvin in &self.netlist.temperatures {
            circuit.add_temperature(kelvin);
        }

        // ── Global nodes (.GLOBAL) ────────────────────────────────────────
        // Copy global node names into the circuit so consumers can inspect them.
        for name in &self.netlist.globals {
            circuit.add_global(name);
        }

        // ── Mutual inductance couplings (K elements) ──────────────────────
        // Resolve L1/L2 names to DeviceIds and register each coupling.
        for pk in &self.pending_k_elements {
            let l1_id = circuit.find_device(&pk.l1_name).map(|d| d.id).ok_or_else(|| {
                SimError::Parse(format!(
                    "K element: inductor '{}' not found in circuit",
                    pk.l1_name
                ))
            })?;
            let l2_id = circuit.find_device(&pk.l2_name).map(|d| d.id).ok_or_else(|| {
                SimError::Parse(format!(
                    "K element: inductor '{}' not found in circuit",
                    pk.l2_name
                ))
            })?;
            circuit.add_mutual_coupling(l1_id, l2_id, pk.k);
        }

        // ── CCVS / CCCS / CSwitch control-source resolution ───────────────
        // For H (CCVS), F (CCCS), and W (CSwitch) elements the parser stored
        // the control V-source name in `elem.model_name`.  Now that all devices
        // are added we can resolve that name to a branch index and write it into
        // the device params as `ctrl_branch_index` for the stamper.
        // CSwitch uses the same convention: the stamper reads `ctrl_branch_index`
        // from params, samples the branch current from the solution vector, and
        // injects it as `controlling_current` before calling eval each NR iter.
        {
            let pending: Vec<(String, String)> = self.netlist.elements.iter()
                .filter(|e| matches!(e.kind, DeviceKind::Ccvs | DeviceKind::Cccs | DeviceKind::CSwitch))
                .filter_map(|e| {
                    let ctrl = e.model_name.as_ref()?.clone();
                    Some((e.name.clone(), ctrl))
                })
                .collect();

            for (dev_name, ctrl_name) in pending {
                if let Some(ctrl_dev) = circuit.find_device(&ctrl_name) {
                    if let Some(bi) = ctrl_dev.branch_index {
                        circuit.set_device_param(&dev_name, "ctrl_branch_index", bi as f64);
                    }
                }
            }
        }

        // ── .CONNECT directives (W.6) ─────────────────────────────────────
        // Merge net pairs after all devices have been added.
        for (net_a, net_b) in &self.netlist.connect_directives.clone() {
            circuit.connect_nets(net_a, net_b);
        }

        // ── Wire up XSPICE A-devices into DigitalNetSpec ──────────────────
        // Convert pending_a_devices into bridge/primitive specs and attach
        // to the circuit so the transient analysis can construct a
        // DigitalRuntime.
        if !self.pending_a_devices.is_empty() {
            let mut dig_spec = DigitalNetSpec::default();
            let mut dig_node_counter: u32 = 0;
            // Map digital node name → allocated digital node index.
            let mut dig_node_map: AHashMap<String, u32> = AHashMap::new();

            let mut alloc_dig_node = |name: &str, counter: &mut u32, map: &mut AHashMap<String, u32>| -> u32 {
                if let Some(&idx) = map.get(name) {
                    idx
                } else {
                    let idx = *counter;
                    *counter += 1;
                    map.insert(name.to_string(), idx);
                    idx
                }
            };

            for adev in &self.pending_a_devices {
                let model_lower = adev.model_name.to_ascii_lowercase();

                // Look up the .model card to get model kind and params.
                let model_kind = models.get(&adev.model_name)
                    .or_else(|| models.get(&model_lower))
                    .map(|m| m.kind.to_ascii_lowercase())
                    .unwrap_or_else(|| model_lower.clone());

                let model_params: Vec<(String, f64)> = models.get(&adev.model_name)
                    .or_else(|| models.get(&model_lower))
                    .map(|m| m.params.iter().map(|(k, v)| (k.to_ascii_lowercase(), *v)).collect())
                    .unwrap_or_default();

                let get_param = |name: &str, default: f64| -> f64 {
                    model_params.iter()
                        .find(|(k, _)| k == name)
                        .map(|(_, v)| *v)
                        .unwrap_or(default)
                };

                // Classify the model: is it a known digital primitive with
                // analog () ports (auto-insert ADC/DAC), a standalone
                // adc_bridge, a standalone dac_bridge, or unknown?
                match model_kind.as_str() {
                    // Standalone ADC bridge: analog input → digital output
                    "adc_bridge" => {
                        for (inp, outp) in adev.inputs.iter().zip(adev.outputs.iter()) {
                            let analog_node = circuit.add_node(inp);
                            let analog_idx = analog_node.0.saturating_sub(1) as u32;
                            let dig_out = alloc_dig_node(outp, &mut dig_node_counter, &mut dig_node_map);
                            dig_spec.adc_bridges.push(AdcBridgeSpec {
                                analog_node_idx: analog_idx,
                                digital_node: dig_out,
                                in_low: get_param("in_low", 0.1),
                                in_high: get_param("in_high", 0.9),
                            });
                        }
                    }
                    // Standalone DAC bridge: digital input → analog output
                    "dac_bridge" => {
                        for (inp, outp) in adev.inputs.iter().zip(adev.outputs.iter()) {
                            let dig_in = alloc_dig_node(inp, &mut dig_node_counter, &mut dig_node_map);
                            let analog_node = circuit.add_node(outp);
                            let analog_idx = analog_node.0.saturating_sub(1) as u32;
                            dig_spec.dac_bridges.push(DacBridgeSpec {
                                analog_node_idx: analog_idx,
                                digital_node: dig_in,
                                out_low: get_param("out_low", 0.0),
                                out_high: get_param("out_high", 1.8),
                                t_rise: get_param("t_rise", 1e-9),
                                t_fall: get_param("t_fall", 1e-9),
                            });
                        }
                    }
                    // Digital primitives accessed through analog () ports:
                    // auto-insert ADC on each input, DAC on each output.
                    _ => {
                        // Determine PrimitiveKind from model name
                        let prim_kind: Option<u8> = match model_kind.as_str() {
                            "d_buffer" | "buf" => Some(0),
                            "d_inverter" | "not" | "inv" => Some(1),
                            "d_and" | "and" | "and2" => Some(2),
                            "d_nand" | "nand" | "nand2" => Some(3),
                            "d_or" | "or" | "or2" => Some(4),
                            "d_nor" | "nor" | "nor2" => Some(5),
                            "d_xor" | "xor" | "xor2" => Some(6),
                            "d_xnor" | "xnor" | "xnor2" => Some(7),
                            "d_dff" | "dff" | "d_ff" => Some(13),
                            "d_dlatch" | "dlatch" | "d_latch" => Some(12),
                            _ => None,
                        };

                        let Some(kind_u8) = prim_kind else {
                            eprintln!("[WARN] A-device '{}': unknown model '{}', skipping", adev.name, adev.model_name);
                            continue;
                        };

                        let rise_delay = get_param("rise_delay", 1e-12);
                        let fall_delay = get_param("fall_delay", 1e-12);

                        // ngspice auto-bridge defaults for () analog port syntax:
                        //   ADC: in_low=0.1, in_high=0.9
                        //   DAC: out_low=0.0, out_high=1.8, t_rise=t_fall=1e-9

                        // For each analog input: auto-insert ADC bridge
                        let mut prim_inputs: Vec<u32> = Vec::new();
                        for inp_name in &adev.inputs {
                            let analog_node = circuit.add_node(inp_name);
                            let analog_idx = analog_node.0.saturating_sub(1) as u32;
                            let dig_node = alloc_dig_node(
                                &format!("__adc_{}_{}", adev.name, inp_name),
                                &mut dig_node_counter,
                                &mut dig_node_map,
                            );
                            dig_spec.adc_bridges.push(AdcBridgeSpec {
                                analog_node_idx: analog_idx,
                                digital_node: dig_node,
                                in_low: 0.1,
                                in_high: 0.9,
                            });
                            prim_inputs.push(dig_node);
                        }

                        // For each analog output: auto-insert DAC bridge
                        let mut prim_outputs: Vec<u32> = Vec::new();
                        for outp_name in &adev.outputs {
                            let analog_node = circuit.add_node(outp_name);
                            let analog_idx = analog_node.0.saturating_sub(1) as u32;
                            let dig_node = alloc_dig_node(
                                &format!("__dac_{}_{}", adev.name, outp_name),
                                &mut dig_node_counter,
                                &mut dig_node_map,
                            );
                            dig_spec.dac_bridges.push(DacBridgeSpec {
                                analog_node_idx: analog_idx,
                                digital_node: dig_node,
                                out_low: 0.0,
                                out_high: 1.8,
                                t_rise: 1e-9,
                                t_fall: 1e-9,
                            });
                            prim_outputs.push(dig_node);
                        }

                        dig_spec.primitives.push(DigitalPrimitiveSpec {
                            kind: kind_u8,
                            inputs: prim_inputs,
                            outputs: prim_outputs,
                            rise_delay,
                            fall_delay,
                        });
                    }
                }
            }

            dig_spec.num_dig_nodes = dig_node_counter;
            if !dig_spec.is_empty() {
                circuit.set_digital_spec(dig_spec);
            }
        }

        circuit.build_topology();
        Ok((circuit, self.netlist.analyses, self.netlist.options, self.netlist.extract_specs))
    }
}
