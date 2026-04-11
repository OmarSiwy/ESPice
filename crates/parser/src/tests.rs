// tests.rs — consolidated test suite for the bigospice-parser crate.
//
// Gathers all #[cfg(test)] modules from the original files:
//   token.rs, lexer.rs, expr.rs, netlist.rs, spice.rs

use ahash::AHashMap;
use bigospice_core::{DeviceId, DeviceInstance, DeviceKind, NodeId};

use crate::tokenizer::{eval_expression, parse_brace_expression, parse_expression, Lexer, SpiceParser};
use crate::types::{
    AnalysisKind, AnalysisStatement, ElementStatement, ModelStatement, ParsedNetlist, SubcircuitDef,
    Token,
};

// ===========================================================================
// Token tests (from token.rs)
// ===========================================================================

#[test]
fn token_equality() {
    assert_eq!(Token::Word("r1".into()), Token::Word("r1".into()));
    assert_ne!(Token::Word("r1".into()), Token::Word("r2".into()));
    assert_eq!(Token::Number(1e3), Token::Number(1e3));
    assert_eq!(Token::Equals, Token::Equals);
    assert_eq!(Token::Dot("param".into()), Token::Dot("param".into()));
}

#[test]
fn token_display() {
    assert_eq!(format!("{}", Token::Word("vdd".into())), "vdd");
    assert_eq!(format!("{}", Token::Number(3.14)), "3.14");
    assert_eq!(format!("{}", Token::Equals), "=");
    assert_eq!(format!("{}", Token::LeftParen), "(");
    assert_eq!(format!("{}", Token::RightParen), ")");
    assert_eq!(format!("{}", Token::Comma), ",");
    assert_eq!(format!("{}", Token::Plus), "+");
    assert_eq!(format!("{}", Token::Minus), "-");
    assert_eq!(format!("{}", Token::Star), "*");
    assert_eq!(format!("{}", Token::Slash), "/");
    assert_eq!(format!("{}", Token::Dot("model".into())), ".model");
    assert_eq!(format!("{}", Token::Newline), "\\n");
    assert_eq!(format!("{}", Token::Eof), "EOF");
    assert_eq!(format!("{}", Token::QuotedString("hello".into())), "\"hello\"");
    assert_eq!(format!("{}", Token::SingleQuoteExpr("r0*scale".into())), "'r0*scale'");
}

#[test]
fn token_clone() {
    let t = Token::Word("hello".into());
    let t2 = t.clone();
    assert_eq!(t, t2);
}

// ===========================================================================
// Lexer tests (from lexer.rs)
// ===========================================================================

/// Helper for approximate f64 comparison in Token::Number.
fn assert_number_approx(tok: &Token, expected: f64) {
    match tok {
        Token::Number(n) => {
            assert!(
                (n - expected).abs() < expected.abs() * 1e-12 + 1e-30,
                "expected {expected}, got {n}"
            );
        }
        other => panic!("expected Number({expected}), got {other:?}"),
    }
}

#[test]
fn tokenize_simple_element() {
    // "R1 1 2 1k" — bare integers tokenize as Number, not Word.
    let mut lex = Lexer::new("R1 1 2 1k\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("r1".into()));
    assert_eq!(tokens[1], Token::Number(1.0));
    assert_eq!(tokens[2], Token::Number(2.0));
    assert_eq!(tokens[3], Token::Number(1e3));
    assert_eq!(tokens[4], Token::Newline);
    assert_eq!(tokens[5], Token::Eof);
}

#[test]
fn tokenize_si_suffixes() {
    let mut lex = Lexer::new("100n 2.2meg 47p 10u 1k 1G\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_number_approx(&tokens[0], 100e-9);
    assert_number_approx(&tokens[1], 2.2e6);
    assert_number_approx(&tokens[2], 47e-12);
    assert_number_approx(&tokens[3], 10e-6);
    assert_number_approx(&tokens[4], 1e3);
    assert_number_approx(&tokens[5], 1e9);
}

#[test]
fn tokenize_comment_line() {
    let mut lex = Lexer::new("* This is a comment\nR1 1 2 1k\n");
    let tokens = lex.tokenize_all().unwrap();
    // The comment line is skipped; we get R1 line tokens.
    assert_eq!(tokens[0], Token::Word("r1".into()));
}

#[test]
fn tokenize_inline_comment() {
    let mut lex = Lexer::new("R1 1 2 1k ; this is a resistor\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("r1".into()));
    assert_eq!(tokens[1], Token::Number(1.0));
    assert_eq!(tokens[2], Token::Number(2.0));
    assert_eq!(tokens[3], Token::Number(1e3));
    assert_eq!(tokens[4], Token::Newline);
    assert_eq!(tokens[5], Token::Eof);
}

#[test]
fn tokenize_dollar_inline_comment() {
    // ngspice/HSPICE: '$' starts an inline comment; everything after is ignored.
    let mut lex = Lexer::new("R1 a b 1k $ this is a comment\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("r1".into()));
    assert_eq!(tokens[1], Token::Word("a".into()));
    assert_eq!(tokens[2], Token::Word("b".into()));
    assert_eq!(tokens[3], Token::Number(1e3));
    assert_eq!(tokens[4], Token::Newline);
    assert_eq!(tokens[5], Token::Eof);
    // No tokens from "$ this is a comment" should appear.
    assert_eq!(tokens.len(), 6);
}

#[test]
fn tokenize_continuation_line() {
    let input = "R1 1 2\n+ 1k\n";
    let mut lex = Lexer::new(input);
    let tokens = lex.tokenize_all().unwrap();
    // Continuation merges lines — no Newline between R1's nodes and 1k.
    assert_eq!(tokens[0], Token::Word("r1".into()));
    assert_eq!(tokens[1], Token::Number(1.0));
    assert_eq!(tokens[2], Token::Number(2.0));
    assert_eq!(tokens[3], Token::Number(1e3));
    assert_eq!(tokens[4], Token::Newline);
    assert_eq!(tokens[5], Token::Eof);
}

#[test]
fn tokenize_dot_directive() {
    let mut lex = Lexer::new(".MODEL NMOD NMOS (VTH0=0.5)\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Dot("model".into()));
    assert_eq!(tokens[1], Token::Word("nmod".into()));
    assert_eq!(tokens[2], Token::Word("nmos".into()));
    assert_eq!(tokens[3], Token::LeftParen);
    assert_eq!(tokens[4], Token::Word("vth0".into()));
    assert_eq!(tokens[5], Token::Equals);
    assert_eq!(tokens[6], Token::Number(0.5));
    assert_eq!(tokens[7], Token::RightParen);
}

#[test]
fn tokenize_voltage_source() {
    let mut lex = Lexer::new("V1 1 0 DC 5\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("v1".into()));
    assert_eq!(tokens[1], Token::Number(1.0));
    assert_eq!(tokens[2], Token::Number(0.0));
    assert_eq!(tokens[3], Token::Word("dc".into()));
    assert_eq!(tokens[4], Token::Number(5.0));
    assert_eq!(tokens[5], Token::Newline);
    assert_eq!(tokens[6], Token::Eof);
}

#[test]
fn tokenize_scientific_notation() {
    let mut lex = Lexer::new("1e-3 2.5E6 1e+9\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Number(1e-3));
    assert_eq!(tokens[1], Token::Number(2.5e6));
    assert_eq!(tokens[2], Token::Number(1e9));
}

#[test]
fn tokenize_equals_params() {
    let mut lex = Lexer::new("W=10u L=1u\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("w".into()));
    assert_eq!(tokens[1], Token::Equals);
    assert_number_approx(&tokens[2], 10e-6);
    assert_eq!(tokens[3], Token::Word("l".into()));
    assert_eq!(tokens[4], Token::Equals);
    assert_number_approx(&tokens[5], 1e-6);
    assert_eq!(tokens[6], Token::Newline);
    assert_eq!(tokens[7], Token::Eof);
}

#[test]
fn tokenize_multiple_comment_lines() {
    let input = "* comment 1\n* comment 2\nR1 1 0 1k\n";
    let mut lex = Lexer::new(input);
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("r1".into()));
}

#[test]
fn tokenize_end_directive() {
    let mut lex = Lexer::new(".END\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Dot("end".into()));
}

#[test]
fn tokenize_ac_analysis() {
    let mut lex = Lexer::new(".AC DEC 10 1 1G\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Dot("ac".into()));
    assert_eq!(tokens[1], Token::Word("dec".into()));
    assert_eq!(tokens[2], Token::Number(10.0));
    assert_eq!(tokens[3], Token::Number(1.0));
    assert_number_approx(&tokens[4], 1e9);
}

#[test]
fn tokenize_empty_input() {
    let mut lex = Lexer::new("");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens, vec![Token::Eof]);
}

#[test]
fn tokenize_title_line() {
    // In SPICE, the first line is the title. We treat it as words.
    let mut lex = Lexer::new("Simple voltage divider\n");
    let tokens = lex.tokenize_all().unwrap();
    assert_eq!(tokens[0], Token::Word("simple".into()));
    assert_eq!(tokens[1], Token::Word("voltage".into()));
    assert_eq!(tokens[2], Token::Word("divider".into()));
    assert_eq!(tokens[3], Token::Newline);
}

// ===========================================================================
// Expression evaluator tests (from expr.rs)
// ===========================================================================

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

// ===========================================================================
// ParsedNetlist / type construction tests (from netlist.rs)
// ===========================================================================

#[test]
fn parsed_netlist_default() {
    let nl = ParsedNetlist::new();
    assert!(nl.title.is_empty());
    assert!(nl.elements.is_empty());
    assert!(nl.models.is_empty());
    assert!(nl.analyses.is_empty());
    assert!(nl.params.is_empty());
    assert!(nl.subcircuits.is_empty());
}

#[test]
fn element_statement_construction() {
    let elem = ElementStatement {
        name: "r1".into(),
        kind: DeviceKind::Resistor,
        nodes: vec!["1".into(), "2".into()],
        value: Some(1e3),
        model_name: None,
        params: vec![],
    };
    assert_eq!(elem.name, "r1");
    assert_eq!(elem.kind, DeviceKind::Resistor);
    assert_eq!(elem.nodes.len(), 2);
    assert_eq!(elem.value, Some(1e3));
}

#[test]
fn model_statement_construction() {
    let model = ModelStatement {
        name: "nmod".into(),
        kind: "nmos".into(),
        params: vec![("vth0".into(), 0.5), ("kp".into(), 120e-6)],
    };
    assert_eq!(model.name, "nmod");
    assert_eq!(model.kind, "nmos");
    assert_eq!(model.params.len(), 2);
}

#[test]
fn analysis_statement_construction() {
    let analysis = AnalysisStatement {
        kind: AnalysisKind::Tran,
        params: vec![("tstep".into(), 1e-9), ("tstop".into(), 1e-6)],
    };
    assert_eq!(analysis.kind, AnalysisKind::Tran);
    assert_eq!(analysis.params.len(), 2);
}

#[test]
fn subcircuit_def_construction() {
    let sub = SubcircuitDef {
        name: "inv".into(),
        ports: vec!["in".into(), "out".into(), "vdd".into(), "vss".into()],
        default_params: vec![],
        body: vec![],
        nested_instances: vec![],
    };
    assert_eq!(sub.name, "inv");
    assert_eq!(sub.ports.len(), 4);
    assert!(sub.body.is_empty());
}

#[test]
fn analysis_kind_equality() {
    assert_eq!(AnalysisKind::DcOp, AnalysisKind::DcOp);
    assert_ne!(AnalysisKind::DcOp, AnalysisKind::Tran);
    assert_ne!(AnalysisKind::Ac, AnalysisKind::DcSweep);
}

#[test]
fn parsed_netlist_with_data() {
    let mut nl = ParsedNetlist::new();
    nl.title = "Test circuit".into();
    nl.params.insert("vdd".into(), 3.3);
    nl.elements.push(ElementStatement {
        name: "r1".into(),
        kind: DeviceKind::Resistor,
        nodes: vec!["1".into(), "0".into()],
        value: Some(1e3),
        model_name: None,
        params: vec![],
    });
    nl.analyses.push(AnalysisStatement {
        kind: AnalysisKind::DcOp,
        params: vec![],
    });
    assert_eq!(nl.title, "Test circuit");
    assert_eq!(nl.params.get("vdd"), Some(&3.3));
    assert_eq!(nl.elements.len(), 1);
    assert_eq!(nl.analyses.len(), 1);
}

// ===========================================================================
// SpiceParser integration tests (from spice.rs)
// ===========================================================================

/// Approximate f64 comparison for SI-suffix values that may have float precision noise.
fn approx_eq(a: f64, b: f64) -> bool {
    if a == b {
        return true;
    }
    let diff = (a - b).abs();
    let mag = a.abs().max(b.abs());
    if mag == 0.0 {
        diff < 1e-30
    } else {
        diff / mag < 1e-10
    }
}

fn assert_param_approx(device: &DeviceInstance, key: &str, expected: f64) {
    let val = device.params.get(key).unwrap_or_else(|| {
        panic!("param '{key}' not found on device '{}'", device.name);
    });
    assert!(
        approx_eq(val, expected),
        "param '{key}' on '{}': expected {expected}, got {val}",
        device.name,
    );
}

#[test]
fn parse_voltage_divider() {
    let netlist = "\
* Simple voltage divider
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    // 3 devices: V1, R1, R2.
    assert_eq!(circuit.devices().len(), 3);

    // Nodes: GND(0), 1, 2.
    assert_eq!(circuit.nodes().len(), 3);
    assert_eq!(circuit.num_vars(), 2);

    // V1 is a voltage source with branch.
    let v1 = circuit.find_device("v1").unwrap();
    assert_eq!(v1.kind, DeviceKind::VoltageSource);
    assert_param_approx(v1, "dc", 5.0);
    assert!(v1.needs_branch());

    // R1 has resistance = 1000.
    let r1 = circuit.find_device("r1").unwrap();
    assert_eq!(r1.kind, DeviceKind::Resistor);
    assert_param_approx(r1, "resistance", 1e3);

    // R2 has resistance = 1000.
    let r2 = circuit.find_device("r2").unwrap();
    assert_eq!(r2.kind, DeviceKind::Resistor);
    assert_param_approx(r2, "resistance", 1e3);

    // One analysis: .OP.
    assert_eq!(analyses.len(), 1);
    assert_eq!(analyses[0].kind, AnalysisKind::DcOp);

    // MNA dimension: 2 nodes + 1 branch = 3.
    assert_eq!(circuit.mna_dimension(), 3);
}

#[test]
fn parse_rc_lowpass() {
    let netlist = "\
* RC lowpass
V1 in 0 DC 1 AC 1
R1 in out 1k
C1 out 0 1n
.AC DEC 10 1 1G
.END
";
    let (circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    assert_eq!(circuit.devices().len(), 3);
    // Nodes: GND, in, out.
    assert_eq!(circuit.nodes().len(), 3);

    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "dc", 1.0);
    assert_param_approx(v1, "ac", 1.0);

    let r1 = circuit.find_device("r1").unwrap();
    assert_param_approx(r1, "resistance", 1e3);

    let c1 = circuit.find_device("c1").unwrap();
    assert_eq!(c1.kind, DeviceKind::Capacitor);
    assert_param_approx(c1, "capacitance", 1e-9);

    assert_eq!(analyses.len(), 1);
    assert_eq!(analyses[0].kind, AnalysisKind::Ac);
    // AC params: sweep_type, npoints=10, fstart=1, fstop=1G.
    assert_eq!(analyses[0].params.len(), 4);
}

#[test]
fn parse_nmos_amplifier() {
    let netlist = "\
* NMOS amplifier
VDD 1 0 DC 3.3
VIN 2 0 DC 0.7
M1 3 2 0 0 NMOD W=10u L=1u
R1 1 3 10k
.MODEL NMOD NMOS (VTH0=0.5 KP=120u)
.OP
.END
";
    let (circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    assert_eq!(circuit.devices().len(), 4); // VDD, VIN, M1, R1

    // Check VDD.
    let vdd = circuit.find_device("vdd").unwrap();
    assert_eq!(vdd.kind, DeviceKind::VoltageSource);
    assert_param_approx(vdd, "dc", 3.3);

    // Check VIN.
    let vin = circuit.find_device("vin").unwrap();
    assert_param_approx(vin, "dc", 0.7);

    // Check M1 — should be NMOS with model params applied.
    let m1 = circuit.find_device("m1").unwrap();
    assert_eq!(m1.kind, DeviceKind::MosfetN);
    assert_eq!(m1.terminal_count(), 4);
    assert_param_approx(m1, "w", 10e-6);
    assert_param_approx(m1, "l", 1e-6);
    // Model params: vth0 and kp should be inherited.
    assert_param_approx(m1, "vth0", 0.5);
    assert_param_approx(m1, "kp", 120e-6);

    // Check R1.
    let r1 = circuit.find_device("r1").unwrap();
    assert_param_approx(r1, "resistance", 10e3);

    // Nodes: GND(0), 1, 2, 3.
    assert_eq!(circuit.nodes().len(), 4);

    assert_eq!(analyses.len(), 1);
    assert_eq!(analyses[0].kind, AnalysisKind::DcOp);
}

#[test]
fn parse_with_comments_and_continuations() {
    let netlist = "\
* Test circuit with comments
* This is another comment
V1 1 0
+ DC 5
R1 1 2 1k ; inline comment
R2 2 0 2k
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "dc", 5.0);

    let r1 = circuit.find_device("r1").unwrap();
    assert_param_approx(r1, "resistance", 1e3);

    let r2 = circuit.find_device("r2").unwrap();
    assert_param_approx(r2, "resistance", 2e3);
}

#[test]
fn parse_tran_analysis() {
    let netlist = "\
* Transient test
V1 1 0 DC 5
R1 1 0 1k
.TRAN 1n 100n
.END
";
    let (_circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(analyses.len(), 1);
    assert_eq!(analyses[0].kind, AnalysisKind::Tran);
    assert_eq!(analyses[0].params.len(), 2);
    // tstep = 1n, tstop = 100n — use approximate comparison for SI values.
    assert_eq!(analyses[0].params[0].0, "tstep");
    assert!(approx_eq(analyses[0].params[0].1, 1e-9));
    assert_eq!(analyses[0].params[1].0, "tstop");
    assert!(approx_eq(analyses[0].params[1].1, 100e-9));
}

#[test]
fn parse_dc_sweep() {
    let netlist = "\
* DC sweep test
V1 1 0 DC 0
R1 1 0 1k
.DC V1 0 5 0.1
.END
";
    let (_circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(analyses.len(), 1);
    assert_eq!(analyses[0].kind, AnalysisKind::DcSweep);
    assert_eq!(analyses[0].params.len(), 3);
}

#[test]
fn parse_diode_circuit() {
    let netlist = "\
* Diode test
V1 1 0 DC 5
R1 1 2 1k
D1 2 0 DMOD
.MODEL DMOD D (IS=1e-14 N=1)
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    let d1 = circuit.find_device("d1").unwrap();
    assert_eq!(d1.kind, DeviceKind::Diode);
    assert_eq!(d1.terminal_count(), 2);
    assert_param_approx(d1, "is", 1e-14);
    assert_param_approx(d1, "n", 1.0);
}

#[test]
fn parse_vcvs_circuit() {
    let netlist = "\
* VCVS test
V1 1 0 DC 1
R1 1 0 1k
E1 3 0 1 0 10
R2 3 0 1k
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    let e1 = circuit.find_device("e1").unwrap();
    assert_eq!(e1.kind, DeviceKind::Vcvs);
    assert_eq!(e1.terminal_count(), 4);
    assert_param_approx(e1, "gain", 10.0);
    assert!(e1.needs_branch());
}

#[test]
fn parse_pmos_circuit() {
    let netlist = "\
* PMOS test
VDD 1 0 DC 3.3
M1 2 3 1 1 PMOD W=20u L=0.5u
R1 2 0 10k
.MODEL PMOD PMOS (VTH0=-0.5 KP=60u)
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    let m1 = circuit.find_device("m1").unwrap();
    assert_eq!(m1.kind, DeviceKind::MosfetP);
    assert_param_approx(m1, "w", 20e-6);
    assert_param_approx(m1, "l", 0.5e-6);
    assert_param_approx(m1, "vth0", -0.5);
}

#[test]
fn parse_multiple_analyses() {
    let netlist = "\
* Multi-analysis
V1 1 0 DC 1 AC 1
R1 1 0 1k
.OP
.AC DEC 10 1 1G
.END
";
    let (_circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(analyses.len(), 2);
    assert_eq!(analyses[0].kind, AnalysisKind::DcOp);
    assert_eq!(analyses[1].kind, AnalysisKind::Ac);
}

#[test]
fn parse_param_directive() {
    let netlist = "\
* Param test
.PARAM VDD=3.3
V1 1 0 DC 3.3
R1 1 0 1k
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    // Just verify it parses without error and devices are correct.
    assert_eq!(circuit.devices().len(), 2);
}

#[test]
fn parse_inductor() {
    let netlist = "\
* Inductor test
V1 1 0 DC 5
L1 1 2 10u
R1 2 0 100
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    let l1 = circuit.find_device("l1").unwrap();
    assert_eq!(l1.kind, DeviceKind::Inductor);
    assert_param_approx(l1, "inductance", 10e-6);
    assert!(l1.needs_branch());
}

#[test]
fn parse_case_insensitive() {
    let netlist = "\
* Case test
v1 1 0 dc 5
r1 1 2 1K
R2 2 0 1k
.op
.end
";
    let (circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(circuit.devices().len(), 3);
    assert_eq!(analyses.len(), 1);
}

#[test]
fn parse_topology_built() {
    let netlist = "\
* Topology test
V1 1 0 DC 5
R1 1 2 1k
R2 2 0 1k
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let topo = circuit.topology().unwrap();
    assert!(topo.nnz() > 0);
}

#[test]
fn parse_node_name_aliases() {
    let netlist = "\
* Node alias test
V1 vdd gnd DC 3.3
R1 vdd out 1k
R2 out 0 1k
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    // "0" is always ground (registered in Circuit::new).
    assert_eq!(circuit.find_node("0"), Some(NodeId::GROUND));
    // "vdd" and "out" are regular nodes.
    assert!(circuit.find_node("vdd").is_some());
    assert!(circuit.find_node("out").is_some());
    assert_ne!(circuit.find_node("vdd"), Some(NodeId::GROUND));
    assert_ne!(circuit.find_node("out"), Some(NodeId::GROUND));
    // Verify the circuit has correct node count: GND + vdd + out = 3.
    assert_eq!(circuit.nodes().len(), 3);
    // Verify V1 connects vdd to ground.
    let v1 = circuit.find_device("v1").unwrap();
    assert!(v1.node(1).unwrap().is_ground());
}

#[test]
fn parse_empty_netlist() {
    let netlist = "\
* Empty circuit
.END
";
    let (circuit, analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(circuit.devices().len(), 0);
    assert!(analyses.is_empty());
}

#[test]
fn parse_vccs_circuit() {
    let netlist = "\
* VCCS test
V1 1 0 DC 1
G1 2 0 1 0 0.001
R1 2 0 1k
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    let g1 = circuit.find_device("g1").unwrap();
    assert_eq!(g1.kind, DeviceKind::Vccs);
    assert_eq!(g1.terminal_count(), 4);
    assert_param_approx(g1, "gm", 0.001);
}

// -----------------------------------------------------------------------
// Waveform parsing tests
// -----------------------------------------------------------------------

#[test]
fn parse_pulse_waveform() {
    let netlist = "\
* PULSE waveform
V1 1 0 PULSE(0 5 1u 1n 1n 10u 20u)
R1 1 0 1k
.TRAN 1n 100n
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    // waveform_kind = 1 (PULSE)
    assert_param_approx(v1, "waveform_kind", 1.0);
    assert_param_approx(v1, "pulse_v1", 0.0);
    assert_param_approx(v1, "pulse_v2", 5.0);
    assert!(approx_eq(v1.params.get_or("pulse_td", -1.0), 1e-6));
    assert!(approx_eq(v1.params.get_or("pulse_pw", -1.0), 10e-6));
    assert!(approx_eq(v1.params.get_or("pulse_per", -1.0), 20e-6));
}

#[test]
fn parse_sin_waveform() {
    let netlist = "\
* SIN waveform
V1 1 0 SIN(0 1 1k 0 0)
R1 1 0 1k
.TRAN 1u 1m
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 2.0);
    assert_param_approx(v1, "sin_vo", 0.0);
    assert_param_approx(v1, "sin_va", 1.0);
    assert!(approx_eq(v1.params.get_or("sin_freq", -1.0), 1e3));
}

#[test]
fn parse_pwl_waveform() {
    let netlist = "\
* PWL waveform
V1 1 0 PWL(0 0 1u 5 2u 5 3u 0)
R1 1 0 1k
.TRAN 100n 4u
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 3.0);
    assert_param_approx(v1, "pwl_count", 4.0);
    assert_param_approx(v1, "pwl_t0", 0.0);
    assert_param_approx(v1, "pwl_v0", 0.0);
    assert!(approx_eq(v1.params.get_or("pwl_t1", -1.0), 1e-6));
    assert_param_approx(v1, "pwl_v1", 5.0);
    assert!(approx_eq(v1.params.get_or("pwl_t3", -1.0), 3e-6));
    assert_param_approx(v1, "pwl_v3", 0.0);
}

#[test]
fn parse_pulse_with_dc_prefix() {
    // DC value + PULSE waveform on the same line — both should be captured.
    let netlist = "\
* DC + PULSE
V1 1 0 DC 0 PULSE(0 5 0 1n 1n 5u 10u)
R1 1 0 1k
.TRAN 1n 50n
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "dc", 0.0);
    assert_param_approx(v1, "waveform_kind", 1.0);
    assert_param_approx(v1, "pulse_v2", 5.0);
}

#[test]
fn parse_isource_sin_waveform() {
    let netlist = "\
* Current source with SIN
I1 0 1 SIN(0 1m 1k)
R1 1 0 1k
.TRAN 10u 1m
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let i1 = circuit.find_device("i1").unwrap();
    assert_param_approx(i1, "waveform_kind", 2.0);
    assert_param_approx(i1, "sin_va", 1e-3);
    assert!(approx_eq(i1.params.get_or("sin_freq", -1.0), 1e3));
}

#[test]
fn parse_sffm_waveform() {
    let netlist = "\
* SFFM waveform
V1 1 0 SFFM(0 1 1k 5 100)
R1 1 0 1k
.TRAN 1u 10m
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 5.0);
    assert_param_approx(v1, "sffm_vo", 0.0);
    assert_param_approx(v1, "sffm_va", 1.0);
    assert!(approx_eq(v1.params.get_or("sffm_fc", -1.0), 1e3));
    assert_param_approx(v1, "sffm_mdi", 5.0);
    assert_param_approx(v1, "sffm_fs", 100.0);
}

#[test]
fn parse_am_waveform() {
    let netlist = "\
* AM waveform
V1 1 0 AM(0.5 1 1k 100k 0)
R1 1 0 1k
.TRAN 1n 100u
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 7.0);
    assert_param_approx(v1, "am_vo", 0.5);
    assert_param_approx(v1, "am_va", 1.0);
    assert!(approx_eq(v1.params.get_or("am_fc", -1.0), 1e3));
    assert!(approx_eq(v1.params.get_or("am_freq", -1.0), 100e3));
    assert_param_approx(v1, "am_td", 0.0);
}

#[test]
fn parse_trnoise_waveform() {
    let netlist = "\
* TRNOISE waveform
V1 1 0 TRNOISE(1m 10n 0 0 100n)
R1 1 0 1k
.TRAN 1n 1u
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 8.0);
    assert!(approx_eq(v1.params.get_or("trnoise_na", -1.0), 1e-3));
    assert!(approx_eq(v1.params.get_or("trnoise_nt", -1.0), 10e-9));
    assert_param_approx(v1, "trnoise_nalpha", 0.0);
    assert_param_approx(v1, "trnoise_namp", 0.0);
    assert!(approx_eq(v1.params.get_or("trnoise_td", -1.0), 100e-9));
}

#[test]
fn parse_trrandom_waveform() {
    let netlist = "\
* TRRANDOM waveform — uniform
V1 1 0 TRRANDOM(1 1u 0 2 0)
R1 1 0 1k
.TRAN 100n 10u
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 9.0);
    assert_param_approx(v1, "trrandom_kind", 1.0);
    assert!(approx_eq(v1.params.get_or("trrandom_tstep", -1.0), 1e-6));
    assert_param_approx(v1, "trrandom_td", 0.0);
    assert_param_approx(v1, "trrandom_param", 2.0);
    assert_param_approx(v1, "trrandom_mean", 0.0);
}

#[test]
fn parse_pwl_repeat_waveform() {
    let netlist = "\
* PWL R= waveform
V1 1 0 PWL(0 0 1u 5 2u 0) R=0
R1 1 0 1k
.TRAN 100n 10u
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 10.0);
    assert_param_approx(v1, "pwl_count", 3.0);
    assert_param_approx(v1, "pwl_r", 0.0);
    assert!(approx_eq(v1.params.get_or("pwl_t1", -1.0), 1e-6));
    assert_param_approx(v1, "pwl_v1", 5.0);
    assert!(approx_eq(v1.params.get_or("pwl_t2", -1.0), 2e-6));
    assert_param_approx(v1, "pwl_v2", 0.0);
}

#[test]
fn parse_pwl_repeat_nonzero_offset() {
    // R=1u means the repeating window starts at t=1u in the PWL table.
    let netlist = "\
* PWL R=1u
V1 1 0 PWL(0 0 1u 5 3u 0) R=1u
R1 1 0 1k
.TRAN 100n 20u
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let v1 = circuit.find_device("v1").unwrap();
    assert_param_approx(v1, "waveform_kind", 10.0);
    assert!(approx_eq(v1.params.get_or("pwl_r", -1.0), 1e-6));
}

// -----------------------------------------------------------------------
// .INCLUDE and .LIB tests
// -----------------------------------------------------------------------

#[test]
fn parse_include_directive() {
    // Write a child file containing R1.
    let dir = tempfile::tempdir().unwrap();
    let child_path = dir.path().join("child.sp");
    std::fs::write(&child_path, "R1 1 0 1k\n").unwrap();

    // Parent file .INCLUDEs the child.
    let parent_path = dir.path().join("parent.sp");
    let parent_content = format!(
        "* Parent\n.INCLUDE \"{}\"\n.OP\n.END\n",
        child_path.display()
    );
    std::fs::write(&parent_path, &parent_content).unwrap();

    let (circuit, _, _opts) = SpiceParser::parse_file(&parent_path).unwrap();
    let r1 = circuit.find_device("r1").expect("R1 should be present after .INCLUDE");
    assert_param_approx(r1, "resistance", 1e3);
}

#[test]
fn parse_include_relative_path() {
    // Child in a subdirectory; parent uses a relative path.
    let dir = tempfile::tempdir().unwrap();
    let sub = dir.path().join("sub");
    std::fs::create_dir(&sub).unwrap();
    let child_path = sub.join("child.sp");
    std::fs::write(&child_path, "R2 2 0 2k\n").unwrap();

    let parent_path = dir.path().join("top.sp");
    std::fs::write(
        &parent_path,
        "* Top\n.INCLUDE \"sub/child.sp\"\n.OP\n.END\n",
    )
    .unwrap();

    let (circuit, _, _opts) = SpiceParser::parse_file(&parent_path).unwrap();
    let r2 = circuit.find_device("r2").expect("R2 should be present");
    assert_param_approx(r2, "resistance", 2e3);
}

#[test]
fn parse_include_cycle_detected() {
    // A.sp includes B.sp, B.sp includes A.sp → cycle error.
    let dir = tempfile::tempdir().unwrap();
    let a_path = dir.path().join("a.sp");
    let b_path = dir.path().join("b.sp");

    std::fs::write(
        &a_path,
        format!("* A\n.INCLUDE \"{}\"\n.END\n", b_path.display()),
    )
    .unwrap();
    std::fs::write(
        &b_path,
        format!("* B\n.INCLUDE \"{}\"\n.END\n", a_path.display()),
    )
    .unwrap();

    let err = SpiceParser::parse_file(&a_path).unwrap_err();
    let msg = format!("{err}");
    assert!(
        msg.contains("include cycle detected"),
        "expected cycle error, got: {msg}"
    );
}

#[test]
fn parse_lib_directive() {
    // Library file with two sections: TT and SS.
    let dir = tempfile::tempdir().unwrap();
    let lib_path = dir.path().join("models.lib");
    std::fs::write(
        &lib_path,
        "\
.LIB TT
R_TT 1 0 1k
.ENDL TT
.LIB SS
R_SS 1 0 500
.ENDL SS
",
    )
    .unwrap();

    // Netlist that requests only the TT section.
    let top_path = dir.path().join("top.sp");
    std::fs::write(
        &top_path,
        format!(
            "* Top\n.LIB \"{}\" TT\n.OP\n.END\n",
            lib_path.display()
        ),
    )
    .unwrap();

    let (circuit, _, _opts) = SpiceParser::parse_file(&top_path).unwrap();
    // R_TT from the TT section should be present.
    assert!(
        circuit.find_device("r_tt").is_some(),
        "R_TT from TT section should be present"
    );
    // R_SS from the SS section should NOT be present.
    assert!(
        circuit.find_device("r_ss").is_none(),
        "R_SS from SS section should not be present"
    );
}

#[test]
fn parse_include_quoted_and_unquoted() {
    // Both .INCLUDE "x.sp" and .INCLUDE x.sp should work.
    let dir = tempfile::tempdir().unwrap();
    let child_path = dir.path().join("x.sp");
    std::fs::write(&child_path, "R3 3 0 3k\n").unwrap();

    // Quoted form.
    let quoted_path = dir.path().join("quoted.sp");
    std::fs::write(
        &quoted_path,
        format!(
            "* Quoted\n.INCLUDE \"{}\"\n.OP\n.END\n",
            child_path.display()
        ),
    )
    .unwrap();
    let (circuit, _, _opts) = SpiceParser::parse_file(&quoted_path).unwrap();
    assert!(circuit.find_device("r3").is_some(), "R3 via quoted include");

    // Unquoted form (absolute path without quotes).
    let unquoted_path = dir.path().join("unquoted.sp");
    std::fs::write(
        &unquoted_path,
        format!(
            "* Unquoted\n.INCLUDE {}\n.OP\n.END\n",
            child_path.display()
        ),
    )
    .unwrap();
    let (circuit2, _, _opts2) = SpiceParser::parse_file(&unquoted_path).unwrap();
    assert!(circuit2.find_device("r3").is_some(), "R3 via unquoted include");
}

// -----------------------------------------------------------------------
// .OPTIONS tests
// -----------------------------------------------------------------------

#[test]
fn parse_options_basic() {
    let netlist = "\
* Options test
V1 1 0 DC 1
R1 1 0 1k
.OPTIONS abstol=1e-15 reltol=1e-4 gmin=1e-10
.OP
.END
";
    let (_, _, opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(opts.abstol, 1e-15);
    assert_eq!(opts.reltol, 1e-4);
    assert_eq!(opts.gmin, 1e-10);
    // Unchanged defaults.
    assert_eq!(opts.vntol, 1e-6);
    assert_eq!(opts.itl1, 100);
}

#[test]
fn parse_options_method_gear() {
    let netlist = "\
* Method test
V1 1 0 DC 1
R1 1 0 1k
.OPTIONS method=gear
.TRAN 1n 1u
.END
";
    let (_, _, opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(opts.method, bigospice_core::IntegrationMethod::Gear);
}

#[test]
fn parse_options_multiple_directives_accumulate() {
    let netlist = "\
* Multiple .OPTIONS test
V1 1 0 DC 1
R1 1 0 1k
.OPTIONS abstol=1e-15 reltol=1e-4
.OPTIONS gmin=1e-10 reltol=1e-5
.OP
.END
";
    let (_, _, opts) = SpiceParser::parse(netlist).unwrap();
    // Second .OPTIONS overrides reltol.
    assert_eq!(opts.reltol, 1e-5);
    // First .OPTIONS set abstol; second didn't touch it.
    assert_eq!(opts.abstol, 1e-15);
    // Second .OPTIONS set gmin.
    assert_eq!(opts.gmin, 1e-10);
}

#[test]
fn parse_options_unknown_key_ignored() {
    let netlist = "\
* Unknown key test
V1 1 0 DC 1
R1 1 0 1k
.OPTIONS abstol=1e-15 nonsense=42
.OP
.END
";
    let (_, _, opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(opts.abstol, 1e-15);
    // Default is unchanged for everything else.
    assert_eq!(opts.reltol, 1e-3);
}

#[test]
fn parse_options_case_insensitive() {
    let netlist = "\
* Case insensitive test
V1 1 0 DC 1
R1 1 0 1k
.OPTIONS ABSTOL=1e-15 Method=Gear
.OP
.END
";
    let (_, _, opts) = SpiceParser::parse(netlist).unwrap();
    assert_eq!(opts.abstol, 1e-15);
    assert_eq!(opts.method, bigospice_core::IntegrationMethod::Gear);
}

// -----------------------------------------------------------------------
// Subcircuit expansion tests
// -----------------------------------------------------------------------

#[test]
fn parse_subckt_instance_simple() {
    // A 2-port "divider" subcircuit with two resistors.
    let netlist = "\
* Subcircuit expansion simple
.SUBCKT divider a b
R1 a mid 1k
R2 mid b 1k
.ENDS
Xdiv top bot divider
V1 top 0 DC 5
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    // Both resistors should appear with mangled names.
    assert!(
        circuit.find_device("xdiv.r1").is_some(),
        "expected xdiv.r1 in circuit"
    );
    assert!(
        circuit.find_device("xdiv.r2").is_some(),
        "expected xdiv.r2 in circuit"
    );

    // xdiv.r1 connects top (port a) to the internal mangled node xdiv.mid.
    let r1 = circuit.find_device("xdiv.r1").unwrap();
    let top_id = circuit.find_node("top").unwrap();
    let mid_id = circuit.find_node("xdiv.mid").unwrap();
    assert_eq!(r1.terminals[0].node, top_id, "r1 positive node should be 'top'");
    assert_eq!(r1.terminals[1].node, mid_id, "r1 negative node should be 'xdiv.mid'");
}

#[test]
fn parse_subckt_instance_node_mangling() {
    // Internal node `mid` inside subckt body becomes `xfoo.mid` after instantiation.
    let netlist = "\
* Node mangling test
.SUBCKT halfbridge p n
R1 p mid 500
R2 mid n 500
.ENDS
Xfoo vdd vss halfbridge
V1 vdd 0 DC 3.3
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    // Internal node 'mid' should be mangled to 'xfoo.mid'.
    assert!(
        circuit.find_node("xfoo.mid").is_some(),
        "internal node 'mid' should be mangled to 'xfoo.mid'"
    );
    // The port-connected node 'vdd' should NOT be mangled.
    assert!(
        circuit.find_node("vdd").is_some(),
        "port node 'vdd' should remain as 'vdd'"
    );
    assert!(
        circuit.find_node("xfoo.vdd").is_none(),
        "port node should not be double-mangled to 'xfoo.vdd'"
    );
}

#[test]
fn parse_subckt_instance_arity_mismatch() {
    // Wrong number of connection nodes should return Err.
    let netlist = "\
* Arity mismatch test
.SUBCKT inv in out vdd vss
R1 in out 1k
.ENDS
Xinv1 a b inv
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_err(), "expected error for arity mismatch");
    let msg = format!("{:?}", result.unwrap_err());
    assert!(
        msg.contains("ports") || msg.contains("port") || msg.contains("2") || msg.contains("4"),
        "error message should mention port count mismatch: {msg}"
    );
}

#[test]
fn parse_subckt_nested() {
    // Subcircuit A contains `xb ... B`; subcircuit B has one resistor.
    // Instantiating A yields the resistor with fully-mangled name xa.xb.<origname>.
    let netlist = "\
* Nested subcircuit test
.SUBCKT B p n
R1 p n 1k
.ENDS
.SUBCKT A p n
Xb p n B
.ENDS
Xa top bot A
V1 top 0 DC 5
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    // The resistor inside B, instantiated via xa.xb, should appear as xa.xb.r1.
    assert!(
        circuit.find_device("xa.xb.r1").is_some(),
        "expected nested device 'xa.xb.r1' in circuit, devices: {:?}",
        circuit.devices().iter().map(|d| &d.name).collect::<Vec<_>>()
    );
}

#[test]
fn parse_subckt_cycle_detected() {
    // A instantiates B, B instantiates A — should return Err with "cycle".
    let netlist = "\
* Cycle detection test
.SUBCKT A p n
Xb p n B
.ENDS
.SUBCKT B p n
Xa p n A
.ENDS
Xinst top bot A
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_err(), "expected error for subcircuit cycle");
    let msg = format!("{:?}", result.unwrap_err());
    assert!(
        msg.to_lowercase().contains("cycle"),
        "error should mention 'cycle': {msg}"
    );
}

#[test]
fn parse_subckt_case_insensitive() {
    // .SUBCKT INV defined in uppercase, instantiated as `xinv1 a b inv` (lowercase).
    let netlist = "\
* Case insensitive subcircuit lookup
.SUBCKT INV in out
R1 in out 1k
.ENDS
Xinv1 a b inv
V1 a 0 DC 1
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    assert!(
        circuit.find_device("xinv1.r1").is_some(),
        "expected 'xinv1.r1' from case-insensitive lookup"
    );
}

// -----------------------------------------------------------------------
// .IC / .NODESET / .GLOBAL / .TEMP tests
// -----------------------------------------------------------------------

#[test]
fn parse_ic_directive() {
    // .IC v(out)=2.5 v(in)=0
    let netlist = "\
* IC directive test
V1 in 0 DC 5
R1 in out 1k
R2 out 0 1k
.IC v(out)=2.5 v(in)=0
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let ics = circuit.initial_conditions();
    assert_eq!(ics.len(), 2, "expected 2 initial conditions, got {}", ics.len());

    let out_id = circuit.find_node("out").unwrap();
    let in_id = circuit.find_node("in").unwrap();

    let out_ic = ics.iter().find(|(n, _)| *n == out_id);
    let in_ic = ics.iter().find(|(n, _)| *n == in_id);

    assert!(out_ic.is_some(), "expected IC for node 'out'");
    assert!(in_ic.is_some(), "expected IC for node 'in'");
    assert_eq!(out_ic.unwrap().1, 2.5);
    assert_eq!(in_ic.unwrap().1, 0.0);
}

#[test]
fn parse_nodeset_directive() {
    // .NODESET v(out)=1.0
    let netlist = "\
* NODESET directive test
V1 in 0 DC 5
R1 in out 1k
R2 out 0 1k
.NODESET v(out)=1.0
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let ns = circuit.node_sets();
    assert_eq!(ns.len(), 1, "expected 1 nodeset, got {}", ns.len());
    let out_id = circuit.find_node("out").unwrap();
    assert_eq!(ns[0].0, out_id);
    assert_eq!(ns[0].1, 1.0);
}

#[test]
fn parse_global_directive() {
    // .GLOBAL vdd vss — verify names land in circuit.globals() and subckt expansion works.
    let netlist = "\
* Global directive test
.GLOBAL vdd vss
.SUBCKT inv in out
R1 in out 1k
.ENDS
Xinv1 a b inv
V1 a 0 DC 1
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    // Subcircuit device should exist (expansion works).
    assert!(circuit.find_device("xinv1.r1").is_some());
    // Global names must be persisted in the circuit.
    let globals = circuit.globals();
    assert!(globals.contains(&"vdd".to_string()), "circuit.globals() missing 'vdd': {globals:?}");
    assert!(globals.contains(&"vss".to_string()), "circuit.globals() missing 'vss': {globals:?}");
}

#[test]
fn parse_global_subckt_no_mangling() {
    // .GLOBAL vdd — a device inside the subckt that connects to vdd should connect to
    // the parent's vdd node (not xfoo.vdd) after expansion.
    let netlist = "\
* Global no-mangle test
.GLOBAL vdd
.SUBCKT buf in out
R1 in out 1k
R2 out vdd 500
.ENDS
Xfoo sig sigout buf
Vdd vdd 0 DC 3.3
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();

    // 'vdd' should exist as the parent node, not 'xfoo.vdd'.
    let vdd_id = circuit.find_node("vdd");
    assert!(vdd_id.is_some(), "global node 'vdd' should exist in circuit");
    assert!(
        circuit.find_node("xfoo.vdd").is_none(),
        "global node 'vdd' should not be mangled to 'xfoo.vdd'"
    );

    // xfoo.r2 should have vdd as its positive node.
    let r2 = circuit.find_device("xfoo.r2").unwrap();
    assert_eq!(
        r2.terminals[1].node,
        vdd_id.unwrap(),
        "xfoo.r2 should connect to global vdd node"
    );
}

#[test]
fn parse_temp_directive_single() {
    // .TEMP 27 — should be stored as 300.15 K in circuit.temperatures().
    let netlist = "\
* TEMP directive single
V1 1 0 DC 1
R1 1 0 1k
.TEMP 27
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let temps = circuit.temperatures();
    assert_eq!(temps.len(), 1);
    let diff = (temps[0] - 300.15_f64).abs();
    assert!(diff < 1e-9, "expected 300.15 K, got {}", temps[0]);
}

#[test]
fn parse_temp_directive_multiple() {
    // .TEMP 0 27 100 — three Kelvin values.
    let netlist = "\
* TEMP directive multiple
V1 1 0 DC 1
R1 1 0 1k
.TEMP 0 27 100
.OP
.END
";
    let (circuit, _analyses, _opts) = SpiceParser::parse(netlist).unwrap();
    let temps = circuit.temperatures();
    assert_eq!(temps.len(), 3, "expected 3 temperatures");
    let expected = [273.15_f64, 300.15, 373.15];
    for (got, exp) in temps.iter().zip(expected.iter()) {
        let diff = (got - exp).abs();
        assert!(diff < 1e-9, "expected {exp} K, got {got}");
    }
}

// -----------------------------------------------------------------------
// PARAMS: keyword on X lines
// -----------------------------------------------------------------------

#[test]
fn parse_x_line_params_keyword() {
    let netlist = "\
* PARAMS: keyword test
.SUBCKT inv in out
R1 in out 1k
.ENDS
Xfoo a b inv PARAMS: W=1u L=100n
V1 a 0 DC 1
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "parse failed: {:?}", result.err());
    let (circuit, _, _) = result.unwrap();
    assert!(circuit.find_device("xfoo.r1").is_some(), "xfoo.r1 should exist");
}

#[test]
fn parse_x_line_params_without_colon() {
    let netlist = "\
* PARAMS without colon test
.SUBCKT buf in out
R1 in out 500
.ENDS
Xbuf1 net1 net2 buf PARAMS W=2u
V1 net1 0 DC 3
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "parse with PARAMS (no colon) failed: {:?}", result.err());
}

// -----------------------------------------------------------------------
// .SUBCKT default params
// -----------------------------------------------------------------------

#[test]
fn parse_subckt_default_params_stored() {
    let netlist = "\
* Subckt default params
.SUBCKT inv in out PARAMS: W=1u L=100n
R1 in out 1k
.ENDS
Xinv1 a b inv
V1 a 0 DC 1
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "subckt default params parse failed: {:?}", result.err());
    let (circuit, _, _) = result.unwrap();
    assert!(circuit.find_device("xinv1.r1").is_some());
}

#[test]
fn parse_subckt_default_params_header() {
    let input = "\
* Default params header
.SUBCKT testbuf in out PARAMS: GAIN=2.0 OFFSET=0.5
R1 in out 1k
.ENDS
Xbuf in out testbuf
V1 in 0 DC 1
.OP
.END
";
    let result = SpiceParser::parse(input);
    assert!(result.is_ok(), "parse failed: {:?}", result.err());
}

// -----------------------------------------------------------------------
// .NODESET brace expressions
// -----------------------------------------------------------------------

#[test]
fn parse_nodeset_brace_expr() {
    let netlist = "\
* NODESET brace expr
V1 1 0 DC 1
R1 1 0 1k
.NODESET v(1)={2+3}
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "NODESET brace expr failed: {:?}", result.err());
}

#[test]
fn parse_ic_brace_expr() {
    let netlist = "\
* IC brace expr
V1 1 0 DC 1
R1 1 0 1k
.IC v(1)={1.5*2}
.TRAN 1n 10n
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "IC brace expr failed: {:?}", result.err());
}

// -----------------------------------------------------------------------
// .DATA / .ENDDATA
// -----------------------------------------------------------------------

#[test]
fn parse_data_block_basic() {
    let netlist = "\
* DATA block test
V1 1 0 DC 1
R1 1 0 1k
.DATA mydata vdd vss
1.8 0
3.3 0
5.0 0
.ENDDATA
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "DATA block parse failed: {:?}", result.err());
}

#[test]
fn parse_data_block_two_params() {
    let netlist = "\
* DATA block two params
V1 1 0 DC 1
R1 1 0 1k
.DATA sweep_data r_val c_val
1000 1e-9
2000 2e-9
4000 4e-9
.ENDDATA
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "DATA block two params failed: {:?}", result.err());
}

// -----------------------------------------------------------------------
// PWL FILE="..."
// -----------------------------------------------------------------------

#[test]
fn parse_pwl_file_source() {
    let netlist = "\
* PWL FILE test
V1 1 0 PWL FILE=\"/nonexistent/waveform.csv\"
R1 1 0 1k
.TRAN 1n 10n
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "PWL FILE parse failed: {:?}", result.err());
}

#[test]
fn parse_pwl_file_waveform_kind() {
    let netlist = "\
* PWL FILE waveform_kind test
V1 out 0 PWL FILE=\"test.csv\"
R1 out 0 1k
.TRAN 1n 10n
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "PWL FILE waveform_kind parse failed: {:?}", result.err());
    let (circuit, _, _) = result.unwrap();
    assert!(circuit.find_device("v1").is_some(), "V1 device should exist");
}

// -----------------------------------------------------------------------
// POLY(n) parsing
// -----------------------------------------------------------------------

#[test]
fn parse_poly1_vcvs() {
    // E n+ n- POLY(1) (v1+ v1-) c0 c1
    let netlist = "\
* POLY(1) VCVS test
V1 vc 0 DC 1
E1 out 0 POLY(1) (vc 0) 0 2.5
R1 out 0 1k
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "POLY(1) VCVS parse failed: {:?}", result.err());
    let (circuit, _, _) = result.unwrap();
    // POLY form is realised as a B-source named b_poly_{instance}.
    assert!(circuit.find_device("b_poly_e1").is_some(), "b_poly_e1 B-source should exist after POLY parse");
}

#[test]
fn parse_poly1_vccs() {
    // G n+ n- POLY(1) (v1+ v1-) c0 c1
    let netlist = "\
* POLY(1) VCCS test
V1 vc 0 DC 1
G1 out 0 POLY(1) (vc 0) 0 0.001
R1 out 0 1k
.OP
.END
";
    let result = SpiceParser::parse(netlist);
    assert!(result.is_ok(), "POLY(1) VCCS parse failed: {:?}", result.err());
    let (circuit, _, _) = result.unwrap();
    // POLY form is realised as a B-source named b_poly_{instance}.
    assert!(circuit.find_device("b_poly_g1").is_some(), "b_poly_g1 B-source should exist after POLY parse");
}

#[test]
fn parse_brace_expression_unclosed() {
    use crate::tokenizer::parse_brace_expression;
    use crate::types::Token;
    // Simulate tokens: { 1 + 2  (no closing brace)
    let tokens = vec![
        Token::LeftBrace,
        Token::Number(1.0),
        Token::Plus,
        Token::Number(2.0),
    ];
    assert!(parse_brace_expression(&tokens).is_err());
}

#[test]
fn parse_brace_expression_valid() {
    use crate::tokenizer::{eval_expression, parse_brace_expression};
    use crate::types::Token;
    let tokens = vec![
        Token::LeftBrace,
        Token::Number(3.0),
        Token::Plus,
        Token::Number(4.0),
        Token::RightBrace,
    ];
    let (expr, consumed) = parse_brace_expression(&tokens).unwrap();
    assert_eq!(consumed, 5);
    let params = AHashMap::new();
    assert_eq!(eval_expression(&expr, &params).unwrap(), 7.0);
}
