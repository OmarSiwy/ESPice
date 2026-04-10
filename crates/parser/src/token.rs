use std::fmt;

/// A single token produced by the SPICE lexer.
#[derive(Debug, Clone, PartialEq)]
pub enum Token {
    /// Identifiers, node names, model names.
    Word(String),
    /// Numeric values (with SI suffix already resolved to f64).
    Number(f64),
    /// `=`
    Equals,
    /// `(`
    LeftParen,
    /// `)`
    RightParen,
    /// `,`
    Comma,
    /// `+` (not at start of line — that is a continuation)
    Plus,
    /// `-`
    Minus,
    /// `*` (not at start of line — that is a comment)
    Star,
    /// `/`
    Slash,
    /// Dot-directive: `.PARAM`, `.MODEL`, `.TRAN`, `.DC`, `.AC`, etc.
    Dot(String),
    /// End of statement (after continuation handling).
    Newline,
    /// `{`
    LeftBrace,
    /// `}`
    RightBrace,
    /// A quoted string literal, e.g. `"filename.csv"`.
    /// The surrounding quotes are stripped; the inner text is lowercased.
    QuotedString(String),
    /// A single-quoted HSPICE arithmetic expression, e.g. `'R0*SCALE'`.
    /// The surrounding quotes are stripped; the inner text is lowercased.
    /// Distinct from `QuotedString` (double-quoted) — this is evaluated as
    /// an arithmetic expression wherever a numeric value is expected.
    SingleQuoteExpr(String),
    /// End of file.
    Eof,
}

impl fmt::Display for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Token::Word(s) => write!(f, "{s}"),
            Token::Number(n) => write!(f, "{n}"),
            Token::Equals => write!(f, "="),
            Token::LeftParen => write!(f, "("),
            Token::RightParen => write!(f, ")"),
            Token::Comma => write!(f, ","),
            Token::Plus => write!(f, "+"),
            Token::Minus => write!(f, "-"),
            Token::Star => write!(f, "*"),
            Token::Slash => write!(f, "/"),
            Token::Dot(s) => write!(f, ".{s}"),
            Token::LeftBrace => write!(f, "{{"),
            Token::RightBrace => write!(f, "}}"),
            Token::QuotedString(s) => write!(f, "\"{s}\""),
            Token::SingleQuoteExpr(s) => write!(f, "'{s}'"),
            Token::Newline => write!(f, "\\n"),
            Token::Eof => write!(f, "EOF"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    }

    #[test]
    fn token_clone() {
        let t = Token::Word("hello".into());
        let t2 = t.clone();
        assert_eq!(t, t2);
    }
}
