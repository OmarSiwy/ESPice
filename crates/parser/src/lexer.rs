use crate::token::Token;
use pisim_core::units::Si;
use pisim_core::SimError;

/// Tokenizes SPICE netlist text into a stream of [`Token`]s.
///
/// Handles SPICE conventions:
/// - `*` at start of line = comment (skip entire line)
/// - `+` at start of line = continuation of previous line
/// - `;` = inline comment (skip to end of line)
/// - Case insensitive (identifiers lowercased)
/// - SI suffixes on numbers: `1k` -> 1000.0, `100n` -> 1e-7, `2.2meg` -> 2.2e6
/// - `.directive` tokens
pub struct Lexer {
    input: Vec<char>,
    pos: usize,
    line: usize,
    col: usize,
    /// Whether we are at the start of a logical line (for comment/continuation detection).
    at_line_start: bool,
}

impl Lexer {
    /// Create a new lexer from input text.
    pub fn new(input: &str) -> Self {
        Self {
            input: input.chars().collect(),
            pos: 0,
            line: 1,
            col: 1,
            at_line_start: true,
        }
    }

    /// Peek at the current character without consuming it.
    fn peek(&self) -> Option<char> {
        self.input.get(self.pos).copied()
    }

    /// Advance one character and return it.
    fn advance(&mut self) -> Option<char> {
        let ch = self.input.get(self.pos).copied()?;
        self.pos += 1;
        if ch == '\n' {
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
            if ch == ' ' || ch == '\t' {
                self.advance();
            } else {
                break;
            }
        }
    }

    /// Skip to end of line (for comments).
    fn skip_to_eol(&mut self) {
        while let Some(ch) = self.peek() {
            if ch == '\n' {
                break;
            }
            self.advance();
        }
    }

    /// Read a number token, including optional SI suffix.
    ///
    /// SPICE numbers can look like: `1.5`, `1e-3`, `1k`, `100n`, `2.2meg`, `1G`.
    fn read_number(&mut self, first: char) -> Result<Token, SimError> {
        let mut buf = String::new();
        buf.push(first);

        // Read digits, decimal point, exponent.
        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() || ch == '.' {
                buf.push(ch);
                self.advance();
            } else if ch == 'e' || ch == 'E' {
                // Could be exponent or start of SI suffix — peek ahead.
                // If next char after 'e' is digit or +/-, it's an exponent.
                let next = self.input.get(self.pos + 1).copied();
                if next == Some('+') || next == Some('-') || next.is_some_and(|c| c.is_ascii_digit()) {
                    buf.push(ch);
                    self.advance();
                    // Also consume the sign if present.
                    if let Some(sign) = self.peek() {
                        if sign == '+' || sign == '-' {
                            buf.push(sign);
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
        let mut suffix_buf = String::new();
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

        // Combine numeric part with suffix and use Si::parse_spice_value.
        let combined = format!("{buf}{suffix_buf}");
        if let Some(val) = Si::parse_spice_value(&combined) {
            Ok(Token::Number(val))
        } else {
            // The suffix might not be an SI suffix — it could be a unit like "Hz" or "ohm".
            // In that case, parse the numeric part alone and rewind the suffix.
            let val: f64 = buf.parse().map_err(|_| {
                SimError::Parse(format!("invalid number '{}' at line {}", buf, self.line))
            })?;
            // Rewind: put the suffix characters back.
            self.pos = suffix_start;
            self.col -= suffix_buf.len();
            Ok(Token::Number(val))
        }
    }

    /// Read a word (identifier) token.
    ///
    /// If the word is immediately followed by `:` (e.g. `PARAMS:`), the colon
    /// is consumed and discarded so `PARAMS:` tokenizes as `Word("params")`.
    fn read_word(&mut self, first: char) -> Token {
        let mut buf = String::new();
        buf.push(first);

        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphanumeric() || ch == '_' || ch == '#' {
                buf.push(ch);
                self.advance();
            } else {
                break;
            }
        }

        // Consume a trailing colon (e.g. `PARAMS:`) so it is not seen as an
        // unknown character error; the word itself is returned without the colon.
        if self.peek() == Some(':') {
            self.advance();
        }

        Token::Word(buf.to_lowercase())
    }

    /// Read a dot-directive token: `.PARAM`, `.MODEL`, etc.
    fn read_dot_directive(&mut self) -> Token {
        let mut buf = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                buf.push(ch);
                self.advance();
            } else {
                break;
            }
        }
        Token::Dot(buf.to_lowercase())
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
            if ch == '\n' {
                self.advance();
                self.at_line_start = true;

                // Collapse: skip any following comment-only lines and blank lines,
                // then check for continuation.
                loop {
                    self.skip_whitespace();
                    match self.peek() {
                        Some('\n') => {
                            // Blank line — skip it.
                            self.advance();
                            continue;
                        }
                        Some('*') => {
                            // Comment line — skip entire line.
                            self.skip_to_eol();
                            continue;
                        }
                        Some('+') => {
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
            if ch == '*' && self.at_line_start {
                self.skip_to_eol();
                // Consume the trailing newline so we don't emit a stray Newline token.
                if self.peek() == Some('\n') {
                    self.advance();
                }
                // Stay at line start for the next line.
                self.at_line_start = true;
                continue;
            }

            // Handle inline comments: ';' or '$' anywhere.
            if ch == ';' || ch == '$' {
                self.skip_to_eol();
                continue;
            }

            // We are no longer at line start after reading a real token.
            self.at_line_start = false;

            // Dot directive.
            if ch == '.' {
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
                '=' => { self.advance(); return Ok(Token::Equals); }
                '(' => { self.advance(); return Ok(Token::LeftParen); }
                ')' => { self.advance(); return Ok(Token::RightParen); }
                ',' => { self.advance(); return Ok(Token::Comma); }
                '+' => { self.advance(); return Ok(Token::Plus); }
                '-' => { self.advance(); return Ok(Token::Minus); }
                '*' => {
                    self.advance();
                    return Ok(Token::Star);
                }
                '/' => { self.advance(); return Ok(Token::Slash); }
                '{' => { self.advance(); return Ok(Token::LeftBrace); }
                '}' => { self.advance(); return Ok(Token::RightBrace); }
                _ => {}
            }

            // Word / identifier.
            if ch.is_ascii_alphabetic() || ch == '_' {
                self.advance();
                return Ok(self.read_word(ch));
            }

            // Quoted string: "..." (double-quoted → opaque QuotedString)
            // Single-quoted: '...' (HSPICE arithmetic expression → SingleQuoteExpr)
            if ch == '"' || ch == '\'' {
                self.advance(); // consume opening quote
                let mut buf = String::new();
                let close = ch;
                while let Some(c) = self.peek() {
                    if c == close {
                        self.advance(); // consume closing quote
                        break;
                    }
                    if c == '\n' {
                        break; // unterminated string — stop at EOL
                    }
                    buf.push(c);
                    self.advance();
                }
                if close == '\'' {
                    // Single-quoted content is an HSPICE arithmetic expression.
                    return Ok(Token::SingleQuoteExpr(buf.to_lowercase()));
                }
                return Ok(Token::QuotedString(buf.to_lowercase()));
            }

            // Unknown character — skip it.
            self.advance();
            return Err(SimError::Parse(format!(
                "unexpected character '{}' at line {}:{}",
                ch, self.line, self.col
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
