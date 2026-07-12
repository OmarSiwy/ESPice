const std = @import("std");
const Token = @import("Token.zig");
const Tag = Token.Tag;

const Lexer = @This();

/// SoA token storage — tag column contiguous for the parser hot path; only
/// {tag, start} is stored (5 B/token). Token text is recovered by re-lexing
/// from `start`, which only happens on identifier/literal reads.
pub const TokenList = std.MultiArrayList(Token.Stored);

/// Re-lex the single token at `start` to recover its end offset.
pub fn tokenEnd(source: []const u8, start: u32) u32 {
    var lexer = init(source);
    lexer.pos = start;
    return lexer.next().end;
}

source: []const u8,
pos: u32,
has_unclosed_comment: bool,

pub fn init(source: []const u8) Lexer {
    return .{ .source = source, .pos = 0, .has_unclosed_comment = false };
}

pub fn next(self: *Lexer) Token {
    self.skipWhitespaceAndComments();

    if (self.pos >= self.source.len) {
        return .{ .tag = .eof, .start = self.pos, .end = self.pos };
    }

    const start = self.pos;
    const c = self.source[self.pos];

    if (c == '"') return self.lexString(start);

    if (c == '`') {
        self.pos += 1;
        if (self.pos < self.source.len and isIdentStart(self.source[self.pos])) {
            self.skipIdent();
            return .{ .tag = .identifier, .start = start, .end = self.pos };
        }
        return .{ .tag = .invalid, .start = start, .end = self.pos };
    }

    if (c == '$') {
        self.pos += 1;
        if (self.pos < self.source.len and isIdentStart(self.source[self.pos])) {
            self.skipIdent();
            return .{ .tag = .system_identifier, .start = start, .end = self.pos };
        }
        return .{ .tag = .invalid, .start = start, .end = self.pos };
    }

    if (c == '\\') {
        self.pos += 1;
        while (self.pos < self.source.len and !isWhitespace(self.source[self.pos])) : (self.pos += 1) {}
        return .{ .tag = .escaped_identifier, .start = start, .end = self.pos };
    }

    if (isDigit(c) or (c == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
        return self.lexNumber(start);
    }

    if (isIdentStart(c)) return self.lexIdentOrKeyword(start);

    self.pos += 1;
    const next_c: u8 = if (self.pos < self.source.len) self.source[self.pos] else 0;

    switch (c) {
        ';' => return .{ .tag = .semicolon, .start = start, .end = self.pos },
        ',' => return .{ .tag = .comma, .start = start, .end = self.pos },
        '.' => return .{ .tag = .dot, .start = start, .end = self.pos },
        ':' => return .{ .tag = .colon, .start = start, .end = self.pos },
        '@' => return .{ .tag = .at_sign, .start = start, .end = self.pos },
        '#' => return .{ .tag = .hash, .start = start, .end = self.pos },
        '?' => return .{ .tag = .question, .start = start, .end = self.pos },
        ')' => return .{ .tag = .r_paren, .start = start, .end = self.pos },
        '{' => return .{ .tag = .l_brace, .start = start, .end = self.pos },
        '}' => return .{ .tag = .r_brace, .start = start, .end = self.pos },
        '[' => return .{ .tag = .l_bracket, .start = start, .end = self.pos },
        ']' => return .{ .tag = .r_bracket, .start = start, .end = self.pos },
        '%' => return .{ .tag = .percent, .start = start, .end = self.pos },
        '(' => {
            if (next_c == '*') {
                self.pos += 1;
                return .{ .tag = .attr_open, .start = start, .end = self.pos };
            }
            return .{ .tag = .l_paren, .start = start, .end = self.pos };
        },
        '=' => {
            if (next_c == '=') {
                self.pos += 1;
                return .{ .tag = .eq2, .start = start, .end = self.pos };
            }
            return .{ .tag = .eq, .start = start, .end = self.pos };
        },
        '!' => {
            if (next_c == '=') {
                self.pos += 1;
                return .{ .tag = .neq, .start = start, .end = self.pos };
            }
            return .{ .tag = .bang, .start = start, .end = self.pos };
        },
        '<' => {
            if (next_c == '+') {
                self.pos += 1;
                return .{ .tag = .contribute, .start = start, .end = self.pos };
            }
            if (next_c == '=') {
                self.pos += 1;
                return .{ .tag = .lte, .start = start, .end = self.pos };
            }
            if (next_c == '<') {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '<') {
                    self.pos += 1;
                    return .{ .tag = .ashl, .start = start, .end = self.pos };
                }
                return .{ .tag = .shl, .start = start, .end = self.pos };
            }
            return .{ .tag = .lt, .start = start, .end = self.pos };
        },
        '>' => {
            if (next_c == '=') {
                self.pos += 1;
                return .{ .tag = .gte, .start = start, .end = self.pos };
            }
            if (next_c == '>') {
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return .{ .tag = .ashr, .start = start, .end = self.pos };
                }
                return .{ .tag = .shr, .start = start, .end = self.pos };
            }
            return .{ .tag = .gt, .start = start, .end = self.pos };
        },
        '+' => return .{ .tag = .plus, .start = start, .end = self.pos },
        '-' => return .{ .tag = .minus, .start = start, .end = self.pos },
        '*' => {
            if (next_c == '*') {
                self.pos += 1;
                return .{ .tag = .pow, .start = start, .end = self.pos };
            }
            if (next_c == ')') {
                self.pos += 1;
                return .{ .tag = .attr_close, .start = start, .end = self.pos };
            }
            return .{ .tag = .star, .start = start, .end = self.pos };
        },
        '/' => return .{ .tag = .slash, .start = start, .end = self.pos },
        '&' => {
            if (next_c == '&') {
                self.pos += 1;
                return .{ .tag = .amp2, .start = start, .end = self.pos };
            }
            return .{ .tag = .amp, .start = start, .end = self.pos };
        },
        '|' => {
            if (next_c == '|') {
                self.pos += 1;
                return .{ .tag = .pipe2, .start = start, .end = self.pos };
            }
            return .{ .tag = .pipe, .start = start, .end = self.pos };
        },
        '^' => {
            if (next_c == '~') {
                self.pos += 1;
                return .{ .tag = .nxor_r, .start = start, .end = self.pos };
            }
            return .{ .tag = .caret, .start = start, .end = self.pos };
        },
        '~' => {
            if (next_c == '^') {
                self.pos += 1;
                return .{ .tag = .nxor_l, .start = start, .end = self.pos };
            }
            return .{ .tag = .tilde, .start = start, .end = self.pos };
        },
        '\'' => {
            if (next_c == '{') {
                self.pos += 1;
                return .{ .tag = .arr_start, .start = start, .end = self.pos };
            }
            return .{ .tag = .invalid, .start = start, .end = self.pos };
        },
        else => return .{ .tag = .invalid, .start = start, .end = self.pos },
    }
}

// ── Internal helpers ──────────────────────────────────────────────────

fn lexString(self: *Lexer, start: u32) Token {
    self.pos += 1;
    while (self.pos < self.source.len) {
        if (self.source[self.pos] == '\\') {
            self.pos += 2;
            continue;
        }
        if (self.source[self.pos] == '"') {
            self.pos += 1;
            return .{ .tag = .string_literal, .start = start, .end = self.pos };
        }
        self.pos += 1;
    }
    return .{ .tag = .string_literal, .start = start, .end = self.pos };
}

fn lexNumber(self: *Lexer, start: u32) Token {
    var is_real = false;

    while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) : (self.pos += 1) {}

    if (self.pos < self.source.len and self.source[self.pos] == '\'') {
        if (self.pos + 1 < self.source.len) {
            const base_char = self.source[self.pos + 1];
            if (base_char == 'h' or base_char == 'H' or
                base_char == 'b' or base_char == 'B' or
                base_char == 'o' or base_char == 'O' or
                base_char == 'd' or base_char == 'D')
            {
                self.pos += 2;
                while (self.pos < self.source.len and isHexDigitOrUnderscore(self.source[self.pos])) : (self.pos += 1) {}
                return .{ .tag = .int_literal, .start = start, .end = self.pos };
            }
        }
    }

    if (self.pos < self.source.len and self.source[self.pos] == '.') {
        if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
            is_real = true;
            self.pos += 1;
            while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) : (self.pos += 1) {}
        }
    }

    if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
        is_real = true;
        self.pos += 1;
        if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-'))
            self.pos += 1;
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) : (self.pos += 1) {}
    }

    if (self.pos < self.source.len) {
        const sc = self.source[self.pos];
        if (isSiScale(sc)) {
            if (self.pos + 1 >= self.source.len or !isIdentChar(self.source[self.pos + 1])) {
                self.pos += 1;
                return .{ .tag = .si_real_literal, .start = start, .end = self.pos };
            }
        }
    }

    return .{ .tag = if (is_real) .real_literal else .int_literal, .start = start, .end = self.pos };
}

fn lexIdentOrKeyword(self: *Lexer, start: u32) Token {
    self.skipIdent();
    const text = self.source[start..self.pos];

    if (Token.keyword_map.get(text)) |kw| {
        return .{ .tag = kw, .start = start, .end = self.pos };
    }
    return .{ .tag = .identifier, .start = start, .end = self.pos };
}

fn skipIdent(self: *Lexer) void {
    while (self.pos < self.source.len and isIdentChar(self.source[self.pos])) : (self.pos += 1) {}
}

fn skipWhitespaceAndComments(self: *Lexer) void {
    while (self.pos < self.source.len) {
        const c = self.source[self.pos];
        if (isWhitespace(c)) {
            self.pos += 1;
            continue;
        }
        if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
            self.pos += 2;
            while (self.pos < self.source.len and self.source[self.pos] != '\n') : (self.pos += 1) {}
            continue;
        }
        if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '*') {
            self.pos += 2;
            var found_close = false;
            while (self.pos + 1 < self.source.len) {
                if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                    self.pos += 2;
                    found_close = true;
                    break;
                }
                self.pos += 1;
            }
            if (!found_close) {
                self.pos = @intCast(self.source.len);
                self.has_unclosed_comment = true;
            }
            continue;
        }
        if (c == '`') {
            const dir_start = self.pos + 1;
            var dir_end = dir_start;
            while (dir_end < self.source.len and isIdentChar(self.source[dir_end])) : (dir_end += 1) {}
            const directive = self.source[dir_start..dir_end];
            if (std.mem.eql(u8, directive, "include") or
                std.mem.eql(u8, directive, "define") or
                std.mem.eql(u8, directive, "undef") or
                std.mem.eql(u8, directive, "ifdef") or
                std.mem.eql(u8, directive, "ifndef") or
                std.mem.eql(u8, directive, "else") or
                std.mem.eql(u8, directive, "endif") or
                std.mem.eql(u8, directive, "resetall"))
            {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') : (self.pos += 1) {}
                continue;
            }
            break;
        }
        break;
    }
}

// ── Character classification ──────────────────────────────────────────

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or isDigit(c) or c == '$';
}

fn isHexDigitOrUnderscore(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '_' or c == 'x' or c == 'X' or c == 'z' or c == 'Z';
}

fn isSiScale(c: u8) bool {
    return switch (c) {
        'T', 'G', 'M', 'K', 'k', 'm', 'u', 'n', 'p', 'f', 'a' => true,
        else => false,
    };
}

// ── Tokenize into SoA storage ─────────────────────────────────────────

pub const TokenizeResult = struct {
    tokens: TokenList,
    has_unclosed_comment: bool,
};

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !TokenizeResult {
    var lexer = init(source);
    var tokens: TokenList = .empty;
    // ponytail: ~1 token per 4 source bytes on average
    try tokens.ensureTotalCapacity(allocator, source.len / 4 + 16);
    while (true) {
        const tok = lexer.next();
        tokens.appendAssumeCapacity(.{ .tag = tok.tag, .start = tok.start });
        if (tok.tag == .eof) break;
    }
    return .{ .tokens = tokens, .has_unclosed_comment = lexer.has_unclosed_comment };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "lex basic tokens" {
    var lex = init("module foo(a, b); endmodule");
    const expected = [_]Tag{
        .kw_module, .identifier, .l_paren, .identifier, .comma, .identifier, .r_paren, .semicolon, .kw_endmodule, .eof,
    };
    for (expected) |exp| {
        const tok = lex.next();
        try std.testing.expectEqual(exp, tok.tag);
    }
}

test "lex operators" {
    var lex = init("<+ ** == != <= >= && || << >> <<< >>>");
    const expected = [_]Tag{
        .contribute, .pow, .eq2, .neq, .lte, .gte, .amp2, .pipe2, .shl, .shr, .ashl, .ashr, .eof,
    };
    for (expected) |exp| {
        const tok = lex.next();
        try std.testing.expectEqual(exp, tok.tag);
    }
}

test "lex numbers" {
    var lex = init("42 3.14 1.5e-3 2.2u");
    try std.testing.expectEqual(Tag.int_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.real_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.real_literal, lex.next().tag);
    try std.testing.expectEqual(Tag.si_real_literal, lex.next().tag);
}

test "lex system identifier" {
    var lex = init("$temperature $vt $display");
    try std.testing.expectEqual(Tag.system_identifier, lex.next().tag);
    try std.testing.expectEqual(Tag.system_identifier, lex.next().tag);
    try std.testing.expectEqual(Tag.system_identifier, lex.next().tag);
}

test "tokenize SoA" {
    const source = "module foo; endmodule";
    var result = try tokenize(std.testing.allocator, source);
    defer result.tokens.deinit(std.testing.allocator);

    const tags = result.tokens.items(.tag);
    try std.testing.expectEqual(Tag.kw_module, tags[0]);
    try std.testing.expectEqual(Tag.identifier, tags[1]);
    try std.testing.expectEqual(Tag.semicolon, tags[2]);
    try std.testing.expectEqual(Tag.kw_endmodule, tags[3]);
    try std.testing.expectEqual(Tag.eof, tags[4]);
    try std.testing.expectEqual(false, result.has_unclosed_comment);
}
