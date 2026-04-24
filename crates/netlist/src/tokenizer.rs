//! Zig-compiler-style tokenizer.
//!
//! Design: struct with `bytes: &[u8]`, `pos: usize`. Call `next()` to advance.
//! Zero-copy — tokens are slices into source. SI suffixes resolved to f64 inline.
//!
//! Pattern from Zig's `std.zig.Tokenizer`:
//!   - State machine driven by current byte
//!   - peek() returns next token kind without consuming
//!   - advance() consumes current token
//!   - consume_*() helpers for typed extraction

use crate::static_map;
use memchr::{memchr, memchr2};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    Word,
    Number,
    Dot,          // directive marker: .TRAN, .MODEL
    QuotedString, // "sky130.lib"
    SingleQuote,  // 'R0*SCALE' (HSPICE expression)
    BraceExpr,    // {1k*2} — entire expression as one token
    LeftBrace,
    RightBrace,
    Equals,
    Plus,
    Minus,
    Star,
    Slash,
    LeftParen,
    RightParen,
    Comma,
    Newline,
    Comment,
    Eof,
}

#[derive(Debug, Clone)]
pub struct Token<'a> {
    pub kind: TokenKind,
    pub text: &'a [u8],
    pub line: usize,
}

pub struct Tokenizer<'a> {
    bytes: &'a [u8],
    pos: usize,
    line: usize,
    peeked: Option<Token<'a>>,
}

impl<'a> Tokenizer<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            pos: 0,
            line: 1,
            peeked: None,
        }
    }

    /// Current line number (1-based).
    pub fn current_line(&self) -> usize {
        self.line
    }

    // ── Core: peek / advance ──────────────────────────────────────────

    pub fn peek(&mut self) -> TokenKind {
        if self.peeked.is_none() {
            self.peeked = Some(self.scan_token());
        }
        self.peeked.as_ref().unwrap().kind
    }

    pub fn advance(&mut self) -> Token<'a> {
        if let Some(tok) = self.peeked.take() {
            tok
        } else {
            self.scan_token()
        }
    }

    // ── Typed consumers ───────────────────────────────────────────────

    pub fn consume_word(&mut self) -> String {
        let tok = self.advance();
        std::str::from_utf8(tok.text)
            .unwrap_or("")
            .to_ascii_lowercase()
    }

    pub fn consume_number(&mut self) -> f64 {
        let tok = self.advance();
        let s = std::str::from_utf8(tok.text).unwrap_or("0");
        parse_spice_number(s)
    }

    /// Consume ".DIRECTIVE" → return directive name (lowercase, no dot).
    pub fn consume_directive(&mut self) -> String {
        let _dot = self.advance(); // consume '.'
        self.consume_word()
    }

    pub fn skip_line(&mut self) {
        loop {
            let kind = self.peek();
            if kind == TokenKind::Newline || kind == TokenKind::Eof {
                if kind == TokenKind::Newline {
                    self.advance();
                }
                break;
            }
            self.advance();
        }
    }

    // ── State machine scanner ─────────────────────────────────────────

    fn scan_token(&mut self) -> Token<'a> {
        self.skip_whitespace();

        if self.pos >= self.bytes.len() {
            return Token {
                kind: TokenKind::Eof,
                text: &[],
                line: self.line,
            };
        }

        let start = self.pos;
        let b = self.bytes[self.pos];
        let line = self.line;

        match b {
            b'\n' => {
                self.pos += 1;
                self.line += 1;
                // Line continuation: '+' at start of next non-blank line
                self.skip_whitespace_no_newline();
                if self.pos < self.bytes.len() && self.bytes[self.pos] == b'+' {
                    self.pos += 1; // consume continuation '+'
                    return self.scan_token(); // continue to next real token
                }
                Token {
                    kind: TokenKind::Newline,
                    text: &self.bytes[start..start + 1],
                    line,
                }
            }
            b'*' if self.is_line_start(start) => {
                // Comment: * at line start
                let end = self.find_eol();
                self.pos = end;
                Token {
                    kind: TokenKind::Comment,
                    text: &self.bytes[start..end],
                    line,
                }
            }
            b';' | b'$' => {
                let end = self.find_eol();
                self.pos = end;
                Token {
                    kind: TokenKind::Comment,
                    text: &self.bytes[start..end],
                    line,
                }
            }
            b'.' => {
                if self.pos + 1 < self.bytes.len() && self.bytes[self.pos + 1].is_ascii_digit() {
                    self.pos += 1; // consume leading decimal point
                    self.scan_number(start, line)
                } else {
                    self.pos += 1;
                    Token {
                        kind: TokenKind::Dot,
                        text: &self.bytes[start..self.pos],
                        line,
                    }
                }
            }
            b'"' => self.scan_quoted_string(start, line),
            b'\'' => self.scan_single_quote(start, line),
            b'{' => self.scan_brace_expr(start, line),
            b'}' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::RightBrace,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b'(' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::LeftParen,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b')' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::RightParen,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b'=' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::Equals,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b'+' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::Plus,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b'-' => {
                // If '-' is immediately followed by a number, scan as a negative number.
                if self.pos + 1 < self.bytes.len()
                    && (self.bytes[self.pos + 1].is_ascii_digit()
                        || (self.bytes[self.pos + 1] == b'.'
                            && self.pos + 2 < self.bytes.len()
                            && self.bytes[self.pos + 2].is_ascii_digit()))
                {
                    self.pos += 1; // consume '-'
                    self.scan_number(start, line)
                } else {
                    self.pos += 1;
                    Token {
                        kind: TokenKind::Minus,
                        text: &self.bytes[start..self.pos],
                        line,
                    }
                }
            }
            b'*' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::Star,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b'/' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::Slash,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b',' => {
                self.pos += 1;
                Token {
                    kind: TokenKind::Comma,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
            b'0'..=b'9' => self.scan_number(start, line),
            _ if is_word_start(b) => self.scan_word(start, line),
            _ => {
                self.pos += 1;
                Token {
                    kind: TokenKind::Word,
                    text: &self.bytes[start..self.pos],
                    line,
                }
            }
        }
    }

    fn scan_word(&mut self, start: usize, line: usize) -> Token<'a> {
        while self.pos < self.bytes.len() && is_word_body(self.bytes[self.pos]) {
            self.pos += 1;
        }
        Token {
            kind: TokenKind::Word,
            text: &self.bytes[start..self.pos],
            line,
        }
    }

    fn scan_number(&mut self, start: usize, line: usize) -> Token<'a> {
        // Consume digits, '.', 'e'/'E', sign after e
        while self.pos < self.bytes.len() {
            let c = self.bytes[self.pos];
            if c.is_ascii_digit() || c == b'.' {
                self.pos += 1;
            } else if c == b'e' || c == b'E' {
                self.pos += 1;
                if self.pos < self.bytes.len()
                    && (self.bytes[self.pos] == b'+' || self.bytes[self.pos] == b'-')
                {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
        // SI suffix: consume trailing alpha (u, n, p, meg, etc.)
        let _num_end = self.pos;
        let _suffix_start = self.pos;
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_alphabetic() {
            self.pos += 1;
        }
        // Suffix gets resolved at parse_spice_number time (kept in token text)
        Token {
            kind: TokenKind::Number,
            text: &self.bytes[start..self.pos],
            line,
        }
    }

    fn scan_quoted_string(&mut self, start: usize, line: usize) -> Token<'a> {
        self.pos += 1; // skip opening "
        if let Some(p) = memchr(b'"', &self.bytes[self.pos..]) {
            self.pos += p + 1; // skip to after closing "
        } else {
            self.pos = self.bytes.len(); // unterminated string
        }
        Token {
            kind: TokenKind::QuotedString,
            text: &self.bytes[start..self.pos],
            line,
        }
    }

    fn scan_single_quote(&mut self, start: usize, line: usize) -> Token<'a> {
        self.pos += 1; // skip opening '
        if let Some(p) = memchr(b'\'', &self.bytes[self.pos..]) {
            self.pos += p + 1; // skip to after closing '
        } else {
            self.pos = self.bytes.len(); // unterminated
        }
        Token {
            kind: TokenKind::SingleQuote,
            text: &self.bytes[start..self.pos],
            line,
        }
    }

    /// Scan `{...}` as a single `BraceExpr` token (handles nested braces).
    fn scan_brace_expr(&mut self, start: usize, line: usize) -> Token<'a> {
        self.pos += 1; // consume opening '{'
        let mut depth = 1usize;
        while depth > 0 {
            if let Some(p) = memchr2(b'{', b'}', &self.bytes[self.pos..]) {
                if self.bytes[self.pos + p] == b'{' {
                    depth += 1;
                } else {
                    depth -= 1;
                }
                self.pos += p + 1;
            } else {
                self.pos = self.bytes.len();
                break;
            }
        }
        Token {
            kind: TokenKind::BraceExpr,
            text: &self.bytes[start..self.pos],
            line,
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────

    fn skip_whitespace(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn skip_whitespace_no_newline(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\r' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn find_eol(&self) -> usize {
        memchr(b'\n', &self.bytes[self.pos..])
            .map(|p| self.pos + p)
            .unwrap_or(self.bytes.len())
    }

    fn is_line_start(&self, pos: usize) -> bool {
        pos == 0 || (pos > 0 && self.bytes[pos - 1] == b'\n')
    }
}

// ── Character classification ──────────────────────────────────────────

fn is_word_start(b: u8) -> bool {
    b.is_ascii_alphabetic() || b == b'_'
}

fn is_word_body(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b':' || b == b'.'
}

// ── SPICE number parsing with SI suffix resolution ────────────────────

pub fn parse_spice_number(s: &str) -> f64 {
    let (num_part, suffix) = split_number_suffix(s);
    let base: f64 = num_part.parse().unwrap_or(0.0);
    if let Some(mult) = static_map::si_suffix(suffix.as_bytes()) {
        base * mult
    } else {
        base
    }
}

fn split_number_suffix(s: &str) -> (&str, &str) {
    let bytes = s.as_bytes();
    let mut i = 0;

    // Optional leading sign
    if i < bytes.len() && (bytes[i] == b'-' || bytes[i] == b'+') {
        i += 1;
    }
    // Integer part
    while i < bytes.len() && (bytes[i].is_ascii_digit() || bytes[i] == b'.') {
        i += 1;
    }
    // Exponent
    if i < bytes.len() && (bytes[i] == b'e' || bytes[i] == b'E') {
        i += 1;
        if i < bytes.len() && (bytes[i] == b'+' || bytes[i] == b'-') {
            i += 1;
        }
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
    }
    (&s[..i], &s[i..])
}

// ── Helper: collect non-comment, non-newline tokens from a string ──────

#[cfg(test)]
fn tokenize_line(src: &str) -> Vec<(TokenKind, String)> {
    let mut t = Tokenizer::new(src.as_bytes());
    let mut out = Vec::new();
    loop {
        let tok = t.advance();
        match tok.kind {
            TokenKind::Eof => break,
            TokenKind::Comment => {} // skip comments
            TokenKind::Newline => {} // skip newlines for line-level tests
            k => out.push((k, std::str::from_utf8(tok.text).unwrap().to_owned())),
        }
    }
    out
}

#[cfg(test)]
mod robustness_tests {
    use super::*;

    // ── 1. Line continuation ─────────────────────────────────────────

    #[test]
    fn test_line_continuation_plus() {
        // "R1 a b\n+ 1k" should yield the same tokens as "R1 a b 1k"
        let with_cont = tokenize_line("R1 a b\n+ 1k");
        let flat = tokenize_line("R1 a b 1k");
        assert_eq!(
            with_cont.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>(),
            flat.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>(),
            "line continuation '+' should join lines transparently"
        );
    }

    // ── 2. Semicolon inline comment ──────────────────────────────────

    #[test]
    fn test_semicolon_comment_mid_line() {
        // "R1 a b 1k ; this is a comment" — tokens after ';' stripped
        let toks = tokenize_line("R1 a b 1k ; this is a comment");
        let words: Vec<_> = toks.iter().map(|(_, s)| s.as_str()).collect();
        assert_eq!(words, vec!["R1", "a", "b", "1k"]);
    }

    // ── 3. Dollar-sign comment ───────────────────────────────────────

    #[test]
    fn test_dollar_comment() {
        // "R1 a b 1k $ comment" — tokens after '$' stripped
        let toks = tokenize_line("R1 a b 1k $ comment");
        let words: Vec<_> = toks.iter().map(|(_, s)| s.as_str()).collect();
        assert_eq!(words, vec!["R1", "a", "b", "1k"]);
    }

    // ── 4. Quoted string token ───────────────────────────────────────

    #[test]
    fn test_quoted_string_token() {
        // ".INCLUDE "file.sp"" — the quoted part is a single QuotedString token
        let toks = tokenize_line(".INCLUDE \"file.sp\"");
        let qs: Vec<_> = toks
            .iter()
            .filter(|(k, _)| *k == TokenKind::QuotedString)
            .map(|(_, s)| s.as_str())
            .collect();
        assert_eq!(qs, vec!["\"file.sp\""], "quoted string should be one token");
    }

    // ── 5. Brace expression token ────────────────────────────────────

    #[test]
    fn test_brace_expression_token() {
        // ".PARAM x={1k+2}" — {1k+2} is a single BraceExpr token
        let toks = tokenize_line(".PARAM x={1k+2}");
        let brace: Vec<_> = toks
            .iter()
            .filter(|(k, _)| *k == TokenKind::BraceExpr)
            .map(|(_, s)| s.as_str())
            .collect();
        assert_eq!(brace, vec!["{1k+2}"], "brace expression should be one token");
    }

    // ── 6. Scientific notation variants ─────────────────────────────

    #[test]
    fn test_scientific_notation_variants() {
        assert!(
            (parse_spice_number("1.5e-3") - 0.0015).abs() < 1e-12,
            "1.5e-3 should be 0.0015"
        );
        assert!(
            (parse_spice_number("1.5E+3") - 1500.0).abs() < 1e-9,
            "1.5E+3 should be 1500.0"
        );
        assert!(
            (parse_spice_number("1.5e3") - 1500.0).abs() < 1e-9,
            "1.5e3 should be 1500.0"
        );
    }

    // ── 7. Negative number after operator ───────────────────────────

    #[test]
    fn test_negative_number_parsing() {
        // parse_spice_number should handle leading '-'
        assert!(
            (parse_spice_number("-1.5k") - (-1500.0)).abs() < 1e-9,
            "-1.5k should be -1500.0"
        );
    }

    // ── 8. Negative number tokenized correctly ───────────────────────

    #[test]
    fn test_negative_number_tokenized() {
        // "-1.5k" at the start of input should produce a Number token "-1.5k"
        let toks = tokenize_line("-1.5k");
        assert_eq!(toks.len(), 1, "should be exactly one token");
        assert_eq!(toks[0].0, TokenKind::Number, "should be a Number token");
        let val = parse_spice_number(&toks[0].1);
        assert!(
            (val - (-1500.0)).abs() < 1e-9,
            "parsed value should be -1500.0, got {val}"
        );
    }

    // ── 9. SI suffix — all multipliers ────────────────────────────────

    #[test]
    fn test_si_suffix_kilo() {
        assert!((parse_spice_number("1k") - 1000.0).abs() < 1e-9, "1k should be 1000");
    }

    #[test]
    fn test_si_suffix_mega() {
        assert!((parse_spice_number("2meg") - 2e6).abs() < 1.0, "2meg should be 2e6");
    }

    #[test]
    fn test_si_suffix_micro() {
        assert!((parse_spice_number("1u") - 1e-6).abs() < 1e-15, "1u should be 1e-6");
    }

    #[test]
    fn test_si_suffix_nano() {
        assert!((parse_spice_number("10n") - 10e-9).abs() < 1e-18, "10n should be 10e-9");
    }

    #[test]
    fn test_si_suffix_pico() {
        assert!((parse_spice_number("100p") - 100e-12).abs() < 1e-21, "100p should be 100e-12");
    }

    #[test]
    fn test_si_suffix_milli() {
        assert!((parse_spice_number("5m") - 5e-3).abs() < 1e-12, "5m should be 5e-3");
    }

    #[test]
    fn test_si_no_suffix() {
        // Plain integer, no suffix
        assert!((parse_spice_number("1000") - 1000.0).abs() < 0.001, "1000 should be 1000.0");
    }

    #[test]
    fn test_si_decimal_no_suffix() {
        assert!((parse_spice_number("3.14") - 3.14).abs() < 1e-10, "3.14 should be 3.14");
    }

    // ── 10. Dot token ─────────────────────────────────────────────────

    #[test]
    fn test_dot_token_kind() {
        let toks = tokenize_line(".TRAN");
        assert!(!toks.is_empty(), "should have tokens");
        assert_eq!(toks[0].0, TokenKind::Dot, "first token should be Dot");
    }

    #[test]
    fn test_leading_decimal_tokenized_as_number() {
        let toks = tokenize_line(".1 -.2 +.3");
        assert_eq!(toks[0].0, TokenKind::Number);
        assert_eq!(toks[0].1, ".1");
        assert_eq!(toks[1].0, TokenKind::Number);
        assert_eq!(toks[1].1, "-.2");
        assert_eq!(toks[2].0, TokenKind::Plus);
        assert_eq!(toks[3].0, TokenKind::Number);
        assert_eq!(toks[3].1, ".3");
    }

    // ── 11. Equals token ──────────────────────────────────────────────

    #[test]
    fn test_equals_token() {
        let toks = tokenize_line("W=1u");
        let has_equals = toks.iter().any(|(k, _)| *k == TokenKind::Equals);
        assert!(has_equals, "W=1u should produce an Equals token");
    }

    // ── 12. Single-quote expression token ────────────────────────────

    #[test]
    fn test_single_quote_token() {
        let toks = tokenize_line(".PARAM x='R0*2'");
        let sq = toks.iter().filter(|(k, _)| *k == TokenKind::SingleQuote).count();
        assert_eq!(sq, 1, "should have one SingleQuote token");
    }

    // ── 13. Multiple line continuation ────────────────────────────────

    #[test]
    fn test_double_line_continuation() {
        let with_cont = tokenize_line("R1\n+ a\n+ b");
        let flat = tokenize_line("R1 a b");
        assert_eq!(
            with_cont.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>(),
            flat.iter().map(|(_, s)| s.as_str()).collect::<Vec<_>>(),
            "double line continuation should yield same tokens as flat"
        );
    }

    // ── 14. Empty input → EOF immediately ─────────────────────────────

    #[test]
    fn test_empty_input_eof() {
        let mut t = Tokenizer::new(b"");
        let kind = t.peek();
        assert_eq!(kind, TokenKind::Eof, "empty input should produce Eof");
    }

    // ── 15. Comma token ───────────────────────────────────────────────

    #[test]
    fn test_comma_token() {
        let toks = tokenize_line("a,b");
        let has_comma = toks.iter().any(|(k, _)| *k == TokenKind::Comma);
        assert!(has_comma, "a,b should produce a Comma token");
    }

    // ── 16. LeftParen / RightParen tokens ─────────────────────────────

    #[test]
    fn test_paren_tokens() {
        let toks = tokenize_line("sin(x)");
        let has_lp = toks.iter().any(|(k, _)| *k == TokenKind::LeftParen);
        let has_rp = toks.iter().any(|(k, _)| *k == TokenKind::RightParen);
        assert!(has_lp, "should have LeftParen");
        assert!(has_rp, "should have RightParen");
    }

    // ── 17. Brace expression with nested braces ───────────────────────

    #[test]
    fn test_nested_brace_expression() {
        let toks = tokenize_line("{a+{b}}");
        let brace = toks.iter().filter(|(k, _)| *k == TokenKind::BraceExpr).count();
        assert_eq!(brace, 1, "nested braces should still be one BraceExpr token");
    }

    // ── 18. Star token (multiply) ─────────────────────────────────────

    #[test]
    fn test_star_not_at_line_start_is_not_comment() {
        // '*' not at line start should be a Star token, not Comment
        let toks = tokenize_line("a * b");
        let has_star = toks.iter().any(|(k, _)| *k == TokenKind::Star);
        assert!(has_star, "'*' mid-line should be Star token, not Comment");
    }
}
