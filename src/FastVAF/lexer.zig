//! Class 1 — Lexing. LRM §2.1–2.8.
//!
//! Transformation: preprocessed text → token stream (SoA {tag,start}).
//!
//! DOD: emit into a `std.MultiArrayList(token.Stored)` (SoA columns). Store only
//! tag + start offset; recompute token end on demand (`tokenEnd`). Stay scalar —
//! .va files are small (KBs); SIMD loses here (that budget goes to eval_batch.zig).
//!
//! `next()` is a PURE function of (src, pos): it reads no lexer state beyond the
//! cursor and mutates nothing else. That is what makes `tokenEnd` exact — it just
//! re-runs the scanner from the token's start and reports where it stopped.
//!
//! Diagnostics: the lexer never fails (except OOM in `tokenize`). Malformed input
//! becomes exactly one `.invalid` token whose extent `tokenEnd` recovers; the
//! parser owns the message. §2.6 value decoding lives here too (`parseInt`,
//! `parseReal`, `stringContents`) so the SI scale table (Table 2-1, where `M`
//! is 1e6 and `m` is 1e-3) exists in exactly one place.

const std = @import("std");
const token = @import("token.zig");
const diag = @import("diag.zig");

pub const TokenList = std.MultiArrayList(token.Stored);

pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,

    /// Lex the whole buffer into a TokenList (arena-owned). Ends with `.eof`.
    /// Caller owns the list: `list.deinit(arena)` (a no-op under an arena).
    pub fn tokenize(arena: std.mem.Allocator, src: []const u8) !TokenList {
        std.debug.assert(src.len <= std.math.maxInt(u32));

        var list: TokenList = .empty;
        errdefer list.deinit(arena);
        // ~4 source bytes per token including separators: one allocation in practice.
        try list.ensureTotalCapacity(arena, src.len / 4 + 8);

        var lx: Lexer = .{ .src = src };
        while (true) {
            const t = lx.next();
            try list.append(arena, t);
            if (t.tag == .eof) return list;
        }
    }

    /// Produce the next token. LRM §2.2.
    pub fn next(self: *Lexer) token.Stored {
        // §2.3 white space and §2.4 comments are token separators only. An
        // unterminated block comment is the one case that yields a token.
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isWhitespace(c)) { // §2.3: space, tab, newline, formfeed
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.peek(1) == '/') { // §2.4 one_line_comment
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '/' and self.peek(1) == '*') { // §2.4 block_comment — never nested
                const open = self.pos;
                self.pos += 2;
                while (true) {
                    if (self.pos + 1 >= self.src.len) {
                        self.pos = @intCast(self.src.len);
                        return .{ .tag = .invalid, .start = open }; // unterminated
                    }
                    if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }
            break;
        }

        const start = self.pos;
        if (start >= self.src.len) return .{ .tag = .eof, .start = start };

        const tag: token.Tag = switch (self.src[start]) {
            '0'...'9' => self.lexNumber(), // §2.6
            'a'...'z', 'A'...'Z', '_' => self.lexIdentOrKeyword(), // §2.8, §2.8.2
            '\\' => self.lexEscapedIdentifier(), // §2.8.1
            '$' => self.lexSystemIdentifier(), // §2.8.3
            '"' => self.lexString(), // §2.7
            '\'' => self.lexApostrophe(), // §2.6.1 based constant / §4.2.14 '{
            '`' => self.lexDirective(), // §10.6 (the only directives left here)
            else => self.lexOperator(), // §2.5, §2.9
        };
        return .{ .tag = tag, .start = start };
    }

    /// Recompute a token's end by re-lexing from its start. LRM §2.2.
    /// This is why `Stored` needs no `len` field (DOD: recompute, don't store).
    pub fn tokenEnd(self: *const Lexer, start: u32) u32 {
        var relex: Lexer = .{ .src = self.src, .pos = start };
        _ = relex.next();
        return relex.pos;
    }

    /// The exact source text of the token starting at `start`.
    pub fn tokenText(self: *const Lexer, start: u32) []const u8 {
        return self.src[start..self.tokenEnd(start)];
    }

    // ---- scanners ---------------------------------------------------------

    /// LRM §2.6.1 (integer constants) and §2.6.2 (real constants). Cursor is on
    /// a decimal digit. Underscores are legal anywhere but first (§2.6.1).
    fn lexNumber(self: *Lexer) token.Tag {
        self.skipUnsignedNumber(); // `size`, or the whole integer/mantissa

        // §2.6.1 sized based constant: size ' [s|S] base digits.
        if (self.peek(0) == '\'') {
            // Not a base_format (e.g. `2'{`): the number ends before the quote.
            return self.lexBasedTail() orelse .int_literal;
        }

        // §2.6.2: a decimal point needs at least one digit on EACH side, so
        // `9.` and `4.E3` are two tokens and `.12` never starts a number.
        var is_real = false;
        if (self.peek(0) == '.' and std.ascii.isDigit(self.peek(1))) {
            self.pos += 1;
            self.skipUnsignedNumber();
            is_real = true;
        }

        // §2.6.2: `exp [sign] unsigned_number` XOR a scale_factor — never both.
        const e = self.peek(0);
        if (e == 'e' or e == 'E') {
            if (std.ascii.isDigit(self.peek(1))) {
                self.pos += 2;
                self.skipUnsignedNumber();
                return .real_literal;
            }
            if ((self.peek(1) == '+' or self.peek(1) == '-') and std.ascii.isDigit(self.peek(2))) {
                self.pos += 3;
                self.skipUnsignedNumber();
                return .real_literal;
            }
        } else if (scaleExp(e) != null and !isIdentChar(self.peek(1))) {
            // Table 2-1 suffix, and only when it is not the head of an
            // identifier (`4af` is then `4` + `af`, illegal downstream as §2.6.1
            // requires; `7k` is a real).
            self.pos += 1;
            return .real_literal;
        }

        return if (is_real) .real_literal else .int_literal;
    }

    /// LRM §2.6.1 based-constant tail: `' [s|S] base_char digits`. Cursor is on
    /// the apostrophe. Returns null (cursor untouched) if this is not a
    /// base_format. No white space is accepted inside the number — see the
    /// deviation note at the bottom of this file.
    fn lexBasedTail(self: *Lexer) ?token.Tag {
        var i = self.pos + 1;
        if (i < self.src.len and (self.src[i] == 's' or self.src[i] == 'S')) i += 1; // signed designator
        if (i >= self.src.len) return null;
        const radix: u8 = switch (std.ascii.toLower(self.src[i])) {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'h' => 16,
            else => return null,
        };
        i += 1;
        const digits = i;
        while (i < self.src.len and isBasedDigit(self.src[i], radix)) i += 1;
        self.pos = i;
        // §2.6.1: the base format must be followed by an unsigned number.
        return if (i == digits) .invalid else .int_literal;
    }

    /// LRM §2.6.1 unsigned_number: decimal digits with `_` separators. A trailing
    /// `_` is legal (`236.123_763_e-12` is an LRM example).
    fn skipUnsignedNumber(self: *Lexer) void {
        while (true) {
            const c = self.peek(0);
            if (std.ascii.isDigit(c) or c == '_') self.pos += 1 else return;
        }
    }

    /// LRM §2.8 simple identifier / §2.8.2 keyword. Escaped identifiers never
    /// reach here, so `keyword_map` is only ever consulted for real keywords.
    fn lexIdentOrKeyword(self: *Lexer) token.Tag {
        const start = self.pos;
        while (isIdentChar(self.peek(0))) self.pos += 1;
        return token.keyword_map.get(self.src[start..self.pos]) orelse .identifier;
    }

    /// LRM §10.6 `begin_keywords / `end_keywords. The preprocessor consumes
    /// every other compiler directive; these two it passes through verbatim,
    /// because the set of reserved keywords is a property of the design
    /// elements that follow and §10.6 requires the directive to sit outside a
    /// design element — neither fact is visible to a text-level preprocessor.
    /// Any other backtick is `.invalid`: nothing else may reach the lexer.
    fn lexDirective(self: *Lexer) token.Tag {
        const start = self.pos;
        self.pos += 1; // '`'
        const name = self.pos;
        while (isIdentChar(self.peek(0))) self.pos += 1;
        const text = self.src[name..self.pos];
        if (std.mem.eql(u8, text, "begin_keywords")) return .dir_begin_keywords;
        if (std.mem.eql(u8, text, "end_keywords")) return .dir_end_keywords;
        self.pos = start + 1;
        return .invalid;
    }

    /// LRM §2.8.1: `\` then printable ASCII 33–126, terminated by white space.
    /// Neither the backslash nor the terminator is part of the identifier, but
    /// both are inside the token span (the parser strips them).
    fn lexEscapedIdentifier(self: *Lexer) token.Tag {
        self.pos += 1;
        const body = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c < 33 or c > 126) break;
            self.pos += 1;
        }
        return if (self.pos == body) .invalid else .escaped_identifier;
    }

    /// LRM §2.8.3: `$` immediately followed by [a-zA-Z0-9_$]+ (no white space).
    fn lexSystemIdentifier(self: *Lexer) token.Tag {
        self.pos += 1;
        const body = self.pos;
        while (isIdentChar(self.peek(0))) self.pos += 1;
        return if (self.pos == body) .invalid else .system_identifier;
    }

    /// LRM §2.7: double-quoted, single line, `\` escapes (decoded by
    /// `stringContents`). An unterminated string ends at the newline/EOF.
    fn lexString(self: *Lexer) token.Tag {
        self.pos += 1;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') break; // §2.7: contained on a single line
            self.pos += 1;
            if (c == '\\') {
                if (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '"') return .string_literal;
        }
        return .invalid;
    }

    /// `'{` assignment pattern (§4.2.14) or an unsized based constant (§2.6.1).
    fn lexApostrophe(self: *Lexer) token.Tag {
        if (self.peek(1) == '{') {
            self.pos += 2;
            return .apostrophe_lbrace;
        }
        if (self.lexBasedTail()) |t| return t;
        self.pos += 1;
        return .invalid;
    }

    /// LRM §2.5 operators (longest match) and §2.9 attribute delimiters.
    /// Digital-only sequences with no tag (`->`, `=>`, `*>`, `&&&`) are consumed
    /// whole as `.invalid` so the parser reports one error, not three.
    fn lexOperator(self: *Lexer) token.Tag {
        const c = self.src[self.pos];
        self.pos += 1;
        return switch (c) {
            '+' => .plus,
            '-' => if (self.eat('>')) .invalid else .minus, // '->' event trigger: digital only
            '*' => if (self.eat('*')) .star_star // §4.2.4 power
            else if (self.eat(')')) .attr_close // §2.9
            else if (self.eat('>')) .invalid // '*>' specify path
            else .star,
            '/' => .slash, // comments were consumed before the token started
            '%' => .percent,
            '<' => if (self.eat('+')) .contribute // §5.6
            else if (self.eat('<')) (if (self.eat('<')) .lt_lt_lt else .lt_lt) // §4.2.11
            else if (self.eat('=')) .lt_eq else .lt,
            '>' => if (self.eat('>')) (if (self.eat('>')) .gt_gt_gt else .gt_gt) else if (self.eat('=')) .gt_eq else .gt,
            '=' => if (self.eat('=')) (if (self.eat('=')) .eq_eq_eq else .eq_eq) // §4.2.6/§4.2.7
            else if (self.eat('>')) .invalid // '=>' specify path
            else .assign_eq,
            '!' => if (self.eat('=')) (if (self.eat('=')) .bang_eq_eq else .bang_eq) else .bang,
            '&' => if (self.eat('&')) (if (self.eat('&')) .invalid else .amp_amp) else .amp, // '&&&' is specify-only
            '|' => if (self.eat('|')) .pipe_pipe else .pipe,
            '~' => if (self.eat('^')) .tilde_caret // §4.2.9/§4.2.10 xnor
            else if (self.eat('&')) .tilde_amp else if (self.eat('|')) .tilde_pipe else .tilde,
            '^' => if (self.eat('~')) .caret_tilde else .caret,
            '?' => .question,
            ':' => .colon,
            // §2.9 attribute instance. IEEE 1364 also spells a wildcard
            // sensitivity list `@(*)`, which would need a third character of
            // lookahead — it is digital-only (annex C), so it just lexes as
            // `attr_open` `)` and the parser rejects it.
            '(' => if (self.eat('*')) .attr_open else .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot, // §2.6.2 forbids `.5`, so a dot is always punctuation
            '@' => .at,
            '#' => .hash,
            // §2.8.4: the preprocessor consumes every `directive; one reaching
            // the lexer is an unknown or unbalanced directive.
            else => .invalid,
        };
    }

    fn peek(self: *const Lexer, n: u32) u8 {
        const i = self.pos + n;
        return if (i < self.src.len) self.src[i] else 0; // NUL never appears in source
    }

    fn eat(self: *Lexer, c: u8) bool {
        if (self.pos < self.src.len and self.src[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

fn isIdentChar(c: u8) bool {
    // §2.8: letters, digits, `$` and `_` (only the first character is restricted).
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// §2.6.1 binary/octal/hex/decimal digit for `radix`, plus `_`, plus the
/// four-state digits x/X/z/Z/? (lexed here, rejected by `parseInt`).
fn isBasedDigit(c: u8, radix: u8) bool {
    return switch (c) {
        '_', 'x', 'X', 'z', 'Z', '?' => true,
        '0'...'9' => c - '0' < radix,
        'a'...'f', 'A'...'F' => radix == 16,
        else => false,
    };
}

/// LRM §2.6.2 Table 2-1 — scaled notation, as the exponent it stands for.
/// `M` is 1e6 and `m` is 1e-3; `K` and `k` are both 1e3. This table exists
/// exactly once; nothing else in the engine may re-spell it.
fn scaleExp(c: u8) ?[]const u8 {
    return switch (c) {
        'T' => "e12",
        'G' => "e9",
        'M' => "e6",
        'K', 'k' => "e3",
        'm' => "e-3",
        'u' => "e-6",
        'n' => "e-9",
        'p' => "e-12",
        'f' => "e-15",
        'a' => "e-18",
        else => null,
    };
}

// ---- source locations (diagnostics) ---------------------------------------

/// Byte range of token `tok` — the currency every diagnostic reports in.
///
/// This is the one place the engine converts a token index into a `diag.Span`,
/// so a caret is exactly as wide as the token it names. `starts` is the
/// lexer's `.start` column; the end is recomputed by re-lexing (see
/// `Lexer.tokenEnd`), which is why `Stored` needs no length field.
///
/// An out-of-range index yields a zero-width span at end of file, which is the
/// right answer for "expected X, found EOF".
pub fn tokenSpan(src: []const u8, starts: []const u32, tok: u32) diag.Span {
    if (tok >= starts.len) {
        const end: u32 = @intCast(src.len);
        return .{ .start = end, .end = end };
    }
    const start = starts[tok];
    const lx: Lexer = .{ .src = src };
    return .{ .start = start, .end = lx.tokenEnd(start) };
}

/// Why a `.invalid` token that opened with `"` never closed — the one lexical
/// mistake common enough in real models to deserve its own message instead of
/// the parser's "found invalid token".
pub const StringRunaway = enum {
    /// Not a string literal at all; the caller's own message stands.
    none,
    /// Ran off the end of the line (or the file) with no closing quote.
    unterminated,
    /// Ended the line with a backslash: the SystemVerilog line continuation.
    line_continuation,
};

/// Classify the `.invalid` token spanning `span`.
///
/// §2.7 is unambiguous: "A string literal is a sequence of characters enclosed
/// by double quotes (") and contained on a single line." Table 2-2 then lists
/// every escape a string may hold — `\n`, `\t`, `\\`, `\"`, `\ddd` — and
/// `\<newline>` is not among them. Continuing a string across a line break is
/// an IEEE 1800 SystemVerilog addition (§5.9); Verilog-AMS is derived from IEEE
/// 1364-2005 (§1.1), whose §3.6 carries the same single-line rule. So the
/// rejection is correct and stays — but foundry models (bsim4va `$strobe`)
/// use the vendor extension anyway, so the message has to name the rule.
///
/// The trailing backslash cannot be found with `endsWith`: in `"a\\` it is the
/// second half of an escape pair, not a continuation, so the body is walked
/// with `lexString`'s own pairing rule.
pub fn stringRunaway(src: []const u8, span: diag.Span) StringRunaway {
    if (span.start >= src.len or src[span.start] != '"') return .none;
    const text = src[span.start..span.end];
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') return .none; // closed on its own line after all
        if (text[i] != '\\') continue;
        // A `\` with nothing left in the token is the one `lexString` refused
        // to pair, i.e. it sat immediately before the newline that stopped it.
        if (i + 1 == text.len) {
            return if (span.end < src.len) .line_continuation else .unterminated;
        }
        i += 1; // skip the escaped character
    }
    return .unterminated;
}

// ---- token value decoding (§2.6, §2.7) ------------------------------------

pub const ValueError = error{
    /// §2.6.1 x/z/? digit. The device contract is two-state: no representation.
    FourStateDigit,
    /// §2.6.1 `' `: apostrophe with no base_format after it.
    MissingBase,
    /// §2.6.1: a base_format must be followed by at least one digit.
    MissingDigits,
    /// §2.6.1: a digit outside the base's range (`4'b012`).
    DigitOutOfRange,
    /// Value does not fit in 64 bits.
    Overflow,
    /// Literal longer than the fixed decode buffer (see `parseReal`).
    LiteralTooLong,
};

/// A decoded §2.6.1 integer constant. `width` is the declared size in bits, or
/// 0 for an unsized constant — LRM §4.2.13 forbids those in a concatenation
/// ("unsized constant numbers shall not be allowed in concatenations"), and
/// that rule is unanswerable without carrying the size out of the decoder.
pub const IntLiteral = struct {
    value: i64,
    width: u32,
    signed: bool,
};

/// Decode an `.int_literal`'s text — THE decoder for §2.6.1. Handles the plain
/// decimal form and the based form (`16'b0011_0101`, `4'shf`, `'h837ff`), with
/// `_` ignored everywhere.
///
/// §2.6.1 in order: the digits are read in the given base, then truncated from
/// the left to `size` bits ("if the size … is smaller, … the leftmost bits …
/// are truncated"), and only then does the `s`/`S` designator decide how the
/// remaining bits are read — as a two's-complement signed value, which is what
/// makes `4'shf` equal -1 rather than 15.
// ponytail: left padding with x/z is unrepresentable here (see FourStateDigit),
// so a short digit string zero-extends, which is §2.6.1's rule for 0/1 fills.
pub fn parseInt(text: []const u8) ValueError!IntLiteral {
    var digits = text;
    var radix: u8 = 10;
    var width: u32 = 0; // 0 == unsized
    var signed = false;

    if (std.mem.indexOfScalar(u8, text, '\'')) |q| {
        var i = q + 1;
        if (i >= text.len) return error.MissingBase;
        if (text[i] == 's' or text[i] == 'S') {
            signed = true;
            i += 1;
        }
        if (i >= text.len) return error.MissingBase;
        radix = switch (std.ascii.toLower(text[i])) {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'h' => 16,
            else => return error.MissingBase,
        };
        digits = text[i + 1 ..];
        for (text[0..q]) |c| { // size constant, `_` ignored
            if (c == '_') continue;
            width = @min(width * 10 + (c - '0'), 64);
        }
    }

    var v: u64 = 0;
    var any = false;
    for (digits) |c| {
        if (c == '_') continue;
        const d: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.FourStateDigit, // x/X/z/Z/?
        };
        if (d >= radix) return error.DigitOutOfRange;
        v = try std.math.mul(u64, v, radix);
        v = try std.math.add(u64, v, d);
        any = true;
    }
    if (!any) return error.MissingDigits;

    // §2.6.1 truncation to the constant's SIZE. A sized constant says its own
    // width; an UNSIZED one is "at least 32 bits" (§2.5.1) and takes the width
    // of the implementation's `integer`, which here is 64 — every integer in the
    // MIR, in codegen and in the device contract is an `i64`.
    //
    // 32 would be the other legal reading, and it is wrong for this engine: it
    // makes `4294967296` lower to 0 and `2147483648` lower to a negative number,
    // while the arithmetic around them stays 64-bit. It also puts the documented
    // result of §9.11 `$realtobits` — a 64-bit IEEE-754 pattern — permanently out
    // of reach of any literal the source could compare it with.
    // Pinned by tests/fixtures/exhaustive/122_bit_conversions.va.
    const bits: u7 = if (width == 0) 64 else @intCast(@min(width, 64));
    if (bits < 64) v &= (@as(u64, 1) << @intCast(bits)) - 1;

    var value: i64 = @bitCast(v);
    if (signed and bits < 64 and (v >> @intCast(bits - 1)) & 1 == 1) {
        value = @bitCast(v | ~((@as(u64, 1) << @intCast(bits)) - 1)); // sign-extend
    }
    return .{ .value = value, .width = width, .signed = signed };
}

/// Decode a `.real_literal`'s text. LRM §2.6.2. Strips `_` and rewrites a
/// Table 2-1 scale factor into an exponent, so IEEE-754 rounding happens once.
pub fn parseReal(text: []const u8) ValueError!f64 {
    // A scale factor is always the final character and never coexists with an
    // exponent, so one look at the last byte decides.
    var body = text;
    var suffix: []const u8 = "";
    if (text.len > 0) {
        if (scaleExp(text[text.len - 1])) |s| {
            suffix = s;
            body = text[0 .. text.len - 1];
        }
    }

    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (body) |c| {
        if (c == '_') continue; // §2.6.2: underscores are ignored
        if (n == buf.len) return error.LiteralTooLong;
        buf[n] = c;
        n += 1;
    }
    if (n + suffix.len > buf.len) return error.LiteralTooLong;
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;

    // The lexer only produces well-formed real literals; overflow yields inf,
    // which §2.6.2 leaves to IEEE 754 (and invariant 5 forbids clamping).
    return std.fmt.parseFloat(f64, buf[0..n]) catch error.Overflow;
}

/// Decode a `.string_literal`'s text (quotes included) into its bytes.
/// LRM §2.7 Table 2-2: \n \t \\ \" and \ddd (1–3 octal digits).
/// Caller owns the result; intern it and let the arena hold it.
pub fn stringContents(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    std.debug.assert(text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"');
    const body = text[1 .. text.len - 1];

    var out = try gpa.alloc(u8, body.len); // escapes only ever shrink
    errdefer gpa.free(out);

    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\') {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) break;
        switch (body[i]) {
            'n' => {
                out[n] = '\n';
                i += 1;
            },
            't' => {
                out[n] = '\t';
                i += 1;
            },
            '\\', '"' => {
                out[n] = body[i];
                i += 1;
            },
            '0'...'7' => { // \ddd, 1–3 octal digits
                var v: u16 = 0;
                var k: usize = 0;
                while (k < 3 and i < body.len and body[i] >= '0' and body[i] <= '7') : (k += 1) {
                    v = v * 8 + (body[i] - '0');
                    i += 1;
                }
                out[n] = @truncate(v);
            },
            else => { // §2.7 leaves other escapes undefined: pass the character through
                out[n] = body[i];
                i += 1;
            },
        }
        n += 1;
    }
    return gpa.realloc(out, n);
}

// Deviations from tests/fixtures/ch02_lexical snapshots of the OLD engine (each
// fixture is named `*_current_behavior` or documented in COVERAGE.md as "records
// the current rejection", i.e. a snapshot, not a normative requirement):
//   - 27_form_feed_whitespace: form feed IS white space (§2.3), so it separates
//     tokens here instead of being rejected.
//   - 25_base_sign_current_behavior: `8'd -6` is "illegal syntax" per §2.6.1
//     Example 3, so `8'd` lexes as one `.invalid` token.
//   - 14_real_leading_dot: §2.6.2 requires a digit on each side of the point, so
//     `.12` lexes as `.` + `12` and the parser rejects it.
// x/z/? digits (05), unsized based (22), signed based (23) and white space
// inside a based number (36) are all still rejected — by `parseInt`/the parser,
// not by the scanner, so the token stream stays LRM-shaped.

// ---- checks ---------------------------------------------------------------

const testing = std.testing;

fn expectTags(src: []const u8, expected: []const token.Tag) !void {
    var list = try Lexer.tokenize(testing.allocator, src);
    defer list.deinit(testing.allocator);
    try testing.expectEqualSlices(token.Tag, expected, list.items(.tag));
}

test "operators are longest-match (§2.5)" {
    try expectTags("< <= <+ << <<< > >= >> >>> = == === ! != !== ** * ~^ ^~ ~& ~| && || (* *) '{", &.{
        .lt,                .lt_eq,    .contribute,  .lt_lt,       .lt_lt_lt,
        .gt,                .gt_eq,    .gt_gt,       .gt_gt_gt,    .assign_eq,
        .eq_eq,             .eq_eq_eq, .bang,        .bang_eq,     .bang_eq_eq,
        .star_star,         .star,     .tilde_caret, .caret_tilde, .tilde_amp,
        .tilde_pipe,        .amp_amp,  .pipe_pipe,   .attr_open,   .attr_close,
        .apostrophe_lbrace, .eof,
    });
    // No tag for these; each is consumed whole so the parser reports once.
    try expectTags("-> => *> &&&", &.{ .invalid, .invalid, .invalid, .invalid, .eof });
    // §2.9 attributes nest no deeper than one token pair.
    try expectTags("(* full_case = 1 *)", &.{
        .attr_open, .identifier, .assign_eq, .int_literal, .attr_close, .eof,
    });
}

test "white space and comments are separators (§2.3, §2.4)" {
    try expectTags("a\t/* the // token is text here */\n\x0cb // trailing\n", &.{
        .identifier, .identifier, .eof,
    });
    // §2.4: block comments do not nest — the inner close ends the comment.
    try expectTags("/* /* */ x", &.{ .identifier, .eof });
    // Unterminated block comment: one `.invalid` spanning to EOF.
    var lx: Lexer = .{ .src = "a /* forever" };
    _ = lx.next();
    const bad = lx.next();
    try testing.expectEqual(token.Tag.invalid, bad.tag);
    try testing.expectEqual(@as(u32, 2), bad.start);
    try testing.expectEqual(@as(u32, 12), lx.tokenEnd(bad.start));
}

test "identifiers, keywords, escaped and system names (§2.8)" {
    try expectTags("module _bus3 n$657 $temperature \\gain+trim  V", &.{
        .kw_module, .identifier, .identifier, .system_identifier, .escaped_identifier, .identifier, .eof,
    });
    // §2.8.2: an escaped keyword is an ordinary identifier.
    try expectTags("\\module ", &.{ .escaped_identifier, .eof });
    // §2.8.3: `$` must be followed immediately by a name character.
    try expectTags("$ temperature", &.{ .invalid, .identifier, .eof });
    // Annex B out-of-scope keywords still lex as reserved, never identifiers.
    try expectTags("posedge wreal", &.{ .kw_reserved, .kw_reserved, .eof });
}

test "numbers: bases, reals, scale factors (§2.6)" {
    try expectTags("27_195 16'b0011_0101 12'o7460 32'h12ab_f001 8'HAf 'h837ff 4'b01xz", &.{
        .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .eof,
    });
    try expectTags("2394.26331 1.2E12 1.30e-2 23E10 1.3u 7k 236.123_763_e-12", &.{
        .real_literal, .real_literal, .real_literal, .real_literal,
        .real_literal, .real_literal, .real_literal, .eof,
    });
    // §2.6.2: a digit is required on each side of the point.
    try expectTags(".12", &.{ .dot, .int_literal, .eof });
    try expectTags("9.", &.{ .int_literal, .dot, .eof });
    try expectTags("4.E3", &.{ .int_literal, .dot, .identifier, .eof });
    // §2.6.1 Example 1: `4af` is illegal hex — `a` is not eaten as a scale factor.
    try expectTags("4af", &.{ .int_literal, .identifier, .eof });
    // §2.6.1: the base format must be followed by digits (`8 'd -6` is illegal).
    try expectTags("8'd -6", &.{ .invalid, .minus, .int_literal, .eof });
    // A quote that is not a base_format leaves the number intact.
    try expectTags("2'{1}", &.{ .int_literal, .apostrophe_lbrace, .int_literal, .rbrace, .eof });
}

test "strings (§2.7)" {
    try expectTags("\"line1\\nline2\" \"quote=\\\" slash=\\\\\"", &.{
        .string_literal, .string_literal, .eof,
    });
    // §2.7: a string is contained on a single line.
    try expectTags("\"first\nsecond\"", &.{ .invalid, .identifier, .invalid, .eof });
}

test "stringRunaway names the §2.7 mistake (E0138)" {
    const cases = [_]struct { src: []const u8, want: StringRunaway }{
        // IEEE 1800 §5.9 continuation — what bsim4va's $strobe uses.
        .{ .src = "\"open\\\nrest\"", .want = .line_continuation },
        .{ .src = "\"open\nrest\"", .want = .unterminated },
        // `\\` is an escaped backslash (Table 2-2), NOT a continuation.
        .{ .src = "\"open\\\\\nrest\"", .want = .unterminated },
        // A trailing `\` with no newline after it is just end of file.
        .{ .src = "\"open\\", .want = .unterminated },
        .{ .src = "\"closed\"", .want = .none },
        .{ .src = "4'b01xz", .want = .none },
    };
    for (cases) |c| {
        var list = try Lexer.tokenize(testing.allocator, c.src);
        defer list.deinit(testing.allocator);
        const span = tokenSpan(c.src, list.items(.start), 0);
        try testing.expectEqual(c.want, stringRunaway(c.src, span));
    }
}

test "tokenEnd recomputes exact spans (no len is stored)" {
    const src =
        \\analog I(p,n) <+ 1.5k * V(p,n); // c
    ;
    var list = try Lexer.tokenize(testing.allocator, src);
    defer list.deinit(testing.allocator);

    const lx: Lexer = .{ .src = src };
    const expected = [_][]const u8{
        "analog", "I", "(", "p", ",", "n", ")", "<+", "1.5k", "*",
        "V",      "(", "p", ",", "n", ")", ";",
    };
    for (list.items(.start)[0..expected.len], expected) |start, text| {
        try testing.expectEqualStrings(text, lx.tokenText(start));
    }
    // Re-lexing is idempotent: asking twice gives the same end.
    try testing.expectEqual(lx.tokenEnd(0), lx.tokenEnd(0));
}

test "scale factors: M is 1e6, m is 1e-3 (§2.6.2 Table 2-1)" {
    try testing.expectEqual(@as(f64, 1e6), try parseReal("1M"));
    try testing.expectEqual(@as(f64, 1e-3), try parseReal("1m"));
    try testing.expectEqual(@as(f64, 1e3), try parseReal("1K"));
    try testing.expectEqual(@as(f64, 1e3), try parseReal("1k"));
    try testing.expectEqual(@as(f64, 1e12), try parseReal("1T"));
    try testing.expectEqual(@as(f64, 1e9), try parseReal("1G"));
    try testing.expectEqual(@as(f64, 1e-6), try parseReal("1u"));
    try testing.expectEqual(@as(f64, 1e-9), try parseReal("1n"));
    try testing.expectEqual(@as(f64, 1e-12), try parseReal("1p"));
    try testing.expectEqual(@as(f64, 1e-15), try parseReal("1f"));
    try testing.expectEqual(@as(f64, 1e-18), try parseReal("1a"));
    try testing.expectEqual(@as(f64, 1300.0), try parseReal("1.3k"));
    try testing.expectEqual(@as(f64, 1.2e12), try parseReal("1.2E12"));
    try testing.expectEqual(@as(f64, 1234.567), try parseReal("1_234.5_67"));
    try testing.expectEqual(@as(f64, 236.123763e-12), try parseReal("236.123_763_e-12"));
}

test "parseInt decodes every base (§2.6.1)" {
    const val = struct {
        fn f(text: []const u8) ValueError!i64 {
            return (try parseInt(text)).value;
        }
    }.f;
    try testing.expectEqual(@as(i64, 27195), try val("27_195"));
    try testing.expectEqual(@as(i64, 0x35), try val("16'b0011_0101"));
    try testing.expectEqual(@as(i64, 0o7460), try val("12'o7460"));
    try testing.expectEqual(@as(i64, 0x12abf001), try val("32'h12ab_f001"));
    try testing.expectEqual(@as(i64, 0xaf), try val("8'HAf"));
    // §2.6.1: the size is OPTIONAL — an unsized based constant is legal.
    try testing.expectEqual(@as(i64, 0x837ff), try val("'h837ff"));
    try testing.expectEqual(@as(u32, 0), (try parseInt("'h837ff")).width);
    // §2.6.1: a number wider than its size is truncated from the LEFT. These
    // two were silently wrong while the parser had its own decoder.
    try testing.expectEqual(@as(i64, 0xf), try val("4'h1f"));
    try testing.expectEqual(@as(i64, 255), try val("8'hFFFF"));
    // §2.6.1 `s`: truncate to the size first, then read as two's complement.
    try testing.expectEqual(@as(i64, -1), try val("4'shf"));
    try testing.expectEqual(@as(i64, -8), try val("4'sb1000"));
    try testing.expectEqual(@as(i64, 7), try val("4'sd7"));
    try testing.expectEqual(@as(i64, -1), try val("8'SHff"));
    try testing.expect((try parseInt("4'shf")).signed);
    // §4.2.13 needs the declared width to reject unsized constants in a concat.
    try testing.expectEqual(@as(u32, 4), (try parseInt("4'shf")).width);
    try testing.expectError(error.FourStateDigit, parseInt("4'b01xz"));
    try testing.expectError(error.MissingDigits, parseInt("4'h"));
    try testing.expectError(error.MissingBase, parseInt("4'"));
    try testing.expectError(error.DigitOutOfRange, parseInt("4'b012"));
}

test "§10.6 the two keyword directives survive the preprocessor as tokens" {
    var lx: Lexer = .{ .src = "`begin_keywords \"1364-2005\"\n`end_keywords\n`celldefine" };
    try testing.expectEqual(token.Tag.dir_begin_keywords, lx.next().tag);
    try testing.expectEqual(token.Tag.string_literal, lx.next().tag);
    try testing.expectEqual(token.Tag.dir_end_keywords, lx.next().tag);
    // Any other backtick means the preprocessor missed one: one invalid token.
    try testing.expectEqual(token.Tag.invalid, lx.next().tag);
}

test "stringContents decodes Table 2-2 escapes (§2.7)" {
    const s1 = try stringContents(testing.allocator, "\"line1\\nline2\\tend\"");
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("line1\nline2\tend", s1);

    const s2 = try stringContents(testing.allocator, "\"quote=\\\" slash=\\\\\"");
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("quote=\" slash=\\", s2);

    const s3 = try stringContents(testing.allocator, "\"A\\101\\0\"");
    defer testing.allocator.free(s3);
    try testing.expectEqualStrings("AA\x00", s3);
}

test "tokenSpan covers exactly the token" {
    const src = "module foo;";
    var list = try Lexer.tokenize(testing.allocator, src);
    defer list.deinit(testing.allocator);
    const starts = list.items(.start);

    // `module` is 6 bytes at offset 0; `foo` is 3 bytes at offset 7.
    try testing.expectEqual(diag.Span{ .start = 0, .end = 6 }, tokenSpan(src, starts, 0));
    try testing.expectEqual(diag.Span{ .start = 7, .end = 10 }, tokenSpan(src, starts, 1));
    try testing.expectEqualStrings("foo", src[tokenSpan(src, starts, 1).start..tokenSpan(src, starts, 1).end]);

    // Past the end is a zero-width span at EOF, not a panic: "expected X,
    // found end of file" has to point somewhere.
    const past = tokenSpan(src, starts, 9999);
    try testing.expectEqual(@as(u32, src.len), past.start);
    try testing.expectEqual(@as(u32, 0), past.len());
}

test "a real .va fixture lexes with no invalid tokens" {
    const src =
        \\`define GAIN 4.0
        \\module ch02(p, n); // one-line comment
        \\    inout p, n;
        \\    electrical p, n;
        \\    parameter real r = 1.5k from (0:inf);
        \\    real \gain+trim ;
        \\    analog begin
        \\        \gain+trim  = 4.0;
        \\        I(p, n) <+ V(p, n) / 1_000.0 + $temperature * 1u;
        \\    end
        \\endmodule
    ;
    var list = try Lexer.tokenize(testing.allocator, src);
    defer list.deinit(testing.allocator);
    for (list.items(.tag), list.items(.start)) |tag, start| {
        // The backtick is the preprocessor's job; everything else must lex.
        if (src[start] == '`') continue;
        try testing.expect(tag != .invalid);
    }
}
