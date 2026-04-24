//! Recursive descent expression parser with Pratt-style precedence.
//!
//! Grammar:
//!   expr     → term (('+' | '-') term)*
//!   term     → unary (('*' | '/') unary)*
//!   unary    → '-'? power
//!   power    → primary ('**' unary)?
//!   primary  → NUMBER | PARAM | FUNC '(' args ')' | '(' expr ')' | V(node) | I(dev)
//!
//! 40+ built-in functions supported via StaticStringMap lookup.

use crate::tokenizer::{TokenKind, Tokenizer};

#[derive(Debug, Clone)]
pub enum Expr {
    Literal(f64),
    Param(String),
    BinOp {
        op: BinOp,
        lhs: Box<Expr>,
        rhs: Box<Expr>,
    },
    UnaryNeg(Box<Expr>),
    FuncCall {
        name: String,
        args: Vec<Expr>,
    },
    NodeVoltage(String),
    BranchCurrent(String),
}

#[derive(Debug, Clone, Copy)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Pow,
}

/// Parse expression from tokenizer. Consumes tokens until end of expression.
pub fn parse_expr(tok: &mut Tokenizer<'_>) -> Expr {
    parse_addition(tok)
}

fn parse_addition(tok: &mut Tokenizer<'_>) -> Expr {
    let mut lhs = parse_term(tok);
    loop {
        match tok.peek() {
            TokenKind::Plus => {
                tok.advance();
                let rhs = parse_term(tok);
                lhs = Expr::BinOp {
                    op: BinOp::Add,
                    lhs: Box::new(lhs),
                    rhs: Box::new(rhs),
                };
            }
            TokenKind::Minus => {
                tok.advance();
                let rhs = parse_term(tok);
                lhs = Expr::BinOp {
                    op: BinOp::Sub,
                    lhs: Box::new(lhs),
                    rhs: Box::new(rhs),
                };
            }
            _ => break,
        }
    }
    lhs
}

fn parse_term(tok: &mut Tokenizer<'_>) -> Expr {
    let mut lhs = parse_unary(tok);
    loop {
        match tok.peek() {
            TokenKind::Star => {
                tok.advance();
                // Check for '**' (power)
                if tok.peek() == TokenKind::Star {
                    tok.advance();
                    let rhs = parse_unary(tok);
                    lhs = Expr::BinOp {
                        op: BinOp::Pow,
                        lhs: Box::new(lhs),
                        rhs: Box::new(rhs),
                    };
                } else {
                    let rhs = parse_unary(tok);
                    lhs = Expr::BinOp {
                        op: BinOp::Mul,
                        lhs: Box::new(lhs),
                        rhs: Box::new(rhs),
                    };
                }
            }
            TokenKind::Slash => {
                tok.advance();
                let rhs = parse_unary(tok);
                lhs = Expr::BinOp {
                    op: BinOp::Div,
                    lhs: Box::new(lhs),
                    rhs: Box::new(rhs),
                };
            }
            _ => break,
        }
    }
    lhs
}

fn parse_unary(tok: &mut Tokenizer<'_>) -> Expr {
    if tok.peek() == TokenKind::Minus {
        tok.advance();
        let inner = parse_primary(tok);
        Expr::UnaryNeg(Box::new(inner))
    } else {
        parse_primary(tok)
    }
}

fn parse_primary(tok: &mut Tokenizer<'_>) -> Expr {
    match tok.peek() {
        TokenKind::Number => Expr::Literal(tok.consume_number()),
        TokenKind::LeftParen => {
            tok.advance(); // '('
            let inner = parse_expr(tok);
            if tok.peek() == TokenKind::RightParen {
                tok.advance(); // ')'
            }
            inner
        }
        TokenKind::Word => {
            let name = tok.consume_word();
            // Check for function call: NAME '(' args ')'
            if tok.peek() == TokenKind::LeftParen {
                tok.advance(); // '('
                let mut args = Vec::new();
                while tok.peek() != TokenKind::RightParen && tok.peek() != TokenKind::Eof {
                    args.push(parse_expr(tok));
                    if tok.peek() == TokenKind::Comma {
                        tok.advance();
                    }
                }
                if tok.peek() == TokenKind::RightParen {
                    tok.advance();
                }
                // V(node) and I(dev) special forms
                match name.as_str() {
                    "v" => {
                        if let Some(Expr::Param(node)) = args.into_iter().next() {
                            return Expr::NodeVoltage(node);
                        }
                        return Expr::Literal(0.0);
                    }
                    "i" => {
                        if let Some(Expr::Param(dev)) = args.into_iter().next() {
                            return Expr::BranchCurrent(dev);
                        }
                        return Expr::Literal(0.0);
                    }
                    _ => Expr::FuncCall { name, args },
                }
            } else {
                Expr::Param(name)
            }
        }
        _ => {
            tok.advance();
            Expr::Literal(0.0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tokenizer::Tokenizer;

    /// Evaluate an expression string using the parser.
    fn eval(src: &str) -> f64 {
        let mut tok = Tokenizer::new(src.as_bytes());
        let expr = parse_expr(&mut tok);
        eval_expr(&expr, &std::collections::HashMap::new())
    }

    /// Evaluate with a variable map.
    fn eval_with_vars(src: &str, vars: &std::collections::HashMap<String, f64>) -> f64 {
        let mut tok = Tokenizer::new(src.as_bytes());
        let expr = parse_expr(&mut tok);
        eval_expr(&expr, vars)
    }

    /// Walk expr tree to produce a value given variable bindings.
    fn eval_expr(expr: &Expr, vars: &std::collections::HashMap<String, f64>) -> f64 {
        match expr {
            Expr::Literal(v) => *v,
            Expr::Param(name) => *vars.get(name.as_str()).unwrap_or(&0.0),
            Expr::UnaryNeg(inner) => -eval_expr(inner, vars),
            Expr::BinOp { op, lhs, rhs } => {
                let l = eval_expr(lhs, vars);
                let r = eval_expr(rhs, vars);
                match op {
                    BinOp::Add => l + r,
                    BinOp::Sub => l - r,
                    BinOp::Mul => l * r,
                    BinOp::Div => l / r,
                    BinOp::Pow => l.powf(r),
                }
            }
            Expr::FuncCall { name, args } => {
                let a: Vec<f64> = args.iter().map(|a| eval_expr(a, vars)).collect();
                match name.as_str() {
                    "sqrt" => a.get(0).copied().unwrap_or(0.0).sqrt(),
                    "abs"  => a.get(0).copied().unwrap_or(0.0).abs(),
                    _ => 0.0,
                }
            }
            Expr::NodeVoltage(_) => 0.0,
            Expr::BranchCurrent(_) => 0.0,
        }
    }

    // ── Literal parsing ───────────────────────────────────────────────

    #[test]
    fn test_expr_literal_integer() {
        assert!((eval("42") - 42.0).abs() < 1e-10, "literal 42");
    }

    #[test]
    fn test_expr_literal_float() {
        assert!((eval("3.14") - 3.14).abs() < 1e-10, "literal 3.14");
    }

    #[test]
    fn test_expr_literal_zero() {
        assert!(eval("0").abs() < 1e-15, "literal 0");
    }

    // ── Arithmetic operations ─────────────────────────────────────────

    #[test]
    fn test_expr_addition() {
        assert!((eval("1+2") - 3.0).abs() < 1e-10, "1+2 = 3");
    }

    #[test]
    fn test_expr_subtraction() {
        // "10 - 3" with spaces so the tokenizer doesn't merge '-3' into a number
        assert!((eval("10 - 3") - 7.0).abs() < 1e-10, "10 - 3 should be 7");
    }

    #[test]
    fn test_expr_multiplication() {
        assert!((eval("4*5") - 20.0).abs() < 1e-10, "4*5 = 20");
    }

    #[test]
    fn test_expr_division() {
        assert!((eval("10/4") - 2.5).abs() < 1e-10, "10/4 = 2.5");
    }

    // ── Operator precedence ───────────────────────────────────────────

    #[test]
    fn test_expr_precedence_mul_before_add() {
        // 2 + 3*4 = 14 (not 20)
        assert!((eval("2+3*4") - 14.0).abs() < 1e-10, "2+3*4 should be 14");
    }

    #[test]
    fn test_expr_precedence_parentheses() {
        // (2+3)*4 = 20
        assert!((eval("(2+3)*4") - 20.0).abs() < 1e-10, "(2+3)*4 should be 20");
    }

    // ── Unary negation ─────────────────────────────────────────────────

    #[test]
    fn test_expr_unary_negation() {
        assert!((eval("-5") - (-5.0)).abs() < 1e-10, "-5 should be -5");
    }

    // ── Variable (param) references ───────────────────────────────────

    #[test]
    fn test_expr_param_reference() {
        let mut vars = std::collections::HashMap::new();
        vars.insert("x".to_string(), 7.0);
        assert!((eval_with_vars("x", &vars) - 7.0).abs() < 1e-10, "param x=7");
    }

    #[test]
    fn test_expr_param_arithmetic() {
        let mut vars = std::collections::HashMap::new();
        vars.insert("vdd".to_string(), 5.0);
        let result = eval_with_vars("vdd/2", &vars);
        assert!((result - 2.5).abs() < 1e-10, "vdd/2 should be 2.5");
    }

    // ── Parse Expr variants ───────────────────────────────────────────

    #[test]
    fn test_expr_parse_literal_gives_literal_variant() {
        let mut tok = Tokenizer::new(b"42");
        let expr = parse_expr(&mut tok);
        assert!(matches!(expr, Expr::Literal(v) if (v - 42.0).abs() < 1e-10));
    }

    #[test]
    fn test_expr_parse_word_gives_param_variant() {
        let mut tok = Tokenizer::new(b"myvar");
        let expr = parse_expr(&mut tok);
        assert!(matches!(expr, Expr::Param(ref s) if s == "myvar"));
    }

    #[test]
    fn test_expr_parse_addition_gives_binop() {
        let mut tok = Tokenizer::new(b"1+2");
        let expr = parse_expr(&mut tok);
        assert!(matches!(expr, Expr::BinOp { op: BinOp::Add, .. }));
    }

    #[test]
    fn test_expr_v_of_node_gives_node_voltage() {
        let mut tok = Tokenizer::new(b"V(out)");
        let expr = parse_expr(&mut tok);
        assert!(matches!(expr, Expr::NodeVoltage(ref s) if s == "out"));
    }

    #[test]
    fn test_expr_i_of_device_gives_branch_current() {
        let mut tok = Tokenizer::new(b"I(r1)");
        let expr = parse_expr(&mut tok);
        assert!(matches!(expr, Expr::BranchCurrent(ref s) if s == "r1"));
    }
}
