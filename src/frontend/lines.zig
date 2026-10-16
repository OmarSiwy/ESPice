//! Bytes to logical lines to fields, per dialect, plus SPICE number literals.
//! A field is a slice of the line: `=`, `(`, `)` and `,` are one-byte fields,
//! a `{...}` or quoted field keeps its delimiters (its kind is its first
//! byte), and anything else is a word.
//!
//! Cites tests/grammar/{ngspice,hspice,spectre}_lines.peg (the line rules),
//! dev/research/{ngspice,hspice,spectre}-syntax.md (§ and rule ids), ngspice
//! inpeval.c INPevaluate and the HSPICE User Guide B-2008.09 for number
//! literals, and glibc's pow(10, e) for the scale (#36).
const std = @import("std");

/// Input syntax.
pub const Dialect = enum { ngspice, hspice, spectre };

/// A field splitter over one line. `quotes` are the quote bytes, `braces`
/// keeps `{...}` whole.
pub fn Fields(comptime quotes: []const u8, comptime braces: bool) type {
    return struct {
        line: []const u8,
        pos: usize = 0,

        const Self = @This();

        /// A splitter at the start of `line`; fields borrow `line`.
        pub fn init(line: []const u8) Self {
            return .{ .line = line };
        }

        /// The unread part of the line, blank-trimmed.
        pub fn rest(self: Self) []const u8 {
            return std.mem.trim(u8, self.line[self.pos..], " \t");
        }

        /// The next field, without consuming it.
        pub fn peek(self: Self) ?[]const u8 {
            var copy = self;
            return copy.next();
        }

        /// First byte of the next field, skipping blanks but not consuming it.
        pub fn nextByte(self: *Self) ?u8 {
            while (self.pos < self.line.len and (self.line[self.pos] == ' ' or self.line[self.pos] == '\t')) self.pos += 1;
            return if (self.pos < self.line.len) self.line[self.pos] else null;
        }

        /// Consumes a `=` field if one is next: the word just read is a key.
        pub fn takeEq(self: *Self) bool {
            if (self.nextByte() != '=') return false;
            self.pos += 1;
            return true;
        }

        /// True unless `f` is a punctuation, quoted or braced field.
        /// Asserts `f` is non-empty, as every field `next` returns is.
        pub fn isWord(f: []const u8) bool {
            return !isBreak(f[0]);
        }

        const breaks: [256]bool = blk: {
            var t: [256]bool = @splat(false);
            for (" \t=(),") |c| t[c] = true;
            for (quotes) |q| t[q] = true;
            if (braces) t['{'] = true;
            break :blk t;
        };

        fn isBreak(c: u8) bool {
            return breaks[c];
        }

        /// True for this dialect's quote bytes.
        pub fn isQuote(c: u8) bool {
            inline for (quotes) |q| if (c == q) return true;
            return false;
        }

        /// A `{...}` or quoted field without its delimiters; an unterminated
        /// one loses only its opening byte. Asserts `f` is non-empty.
        pub fn body(f: []const u8) []const u8 {
            const close: u8 = if (f[0] == '{') '}' else f[0];
            return if (f.len >= 2 and f[f.len - 1] == close) f[1 .. f.len - 1] else f[1..];
        }

        /// Consumes and returns the next field; null at the end of the line.
        /// An unterminated quote or brace runs to the end of the line.
        pub fn next(self: *Self) ?[]const u8 {
            const line = self.line;
            while (self.pos < line.len and (line[self.pos] == ' ' or line[self.pos] == '\t')) self.pos += 1;
            if (self.pos >= line.len) return null;
            const start = self.pos;
            const c = line[start];
            switch (c) {
                '=', '(', ')', ',' => {
                    self.pos += 1;
                    return line[start..self.pos];
                },
                else => {},
            }
            if (isQuote(c)) {
                const end = std.mem.indexOfScalarPos(u8, line, start + 1, c) orelse line.len;
                self.pos = @min(end + 1, line.len);
                return line[start..self.pos];
            }
            if (braces and c == '{') {
                var depth: usize = 0;
                var i = start;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '{') depth += 1;
                    if (line[i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                self.pos = @min(i + 1, line.len);
                return line[start..self.pos];
            }
            while (self.pos < line.len and !isBreak(line[self.pos])) self.pos += 1;
            return line[start..self.pos];
        }
    };
}

/// A plain number: decimal or scientific notation (Touchstone 2.0 rule 6;
/// an HSPICE RLGC or vector file's too), and nothing parseFloat also takes
/// (`inf`, `nan`, hex, `_`). Null for anything else.
pub fn plainNumber(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    const int_start = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    const int_digits = i > int_start;
    var frac_digits = false;
    if (i < t.len and t[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        frac_digits = i > frac_start;
    }
    if (!int_digits and !frac_digits) return null;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const exp_start = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == exp_start) return null;
    }
    if (i != t.len) return null;
    return std.fmt.parseFloat(f64, t) catch null;
}

const NumParts = struct { base: f64, suffix: []const u8 };

/// The leading decimal literal of `text` and the suffix after it. With
/// `d_exp`, `d` is an exponent letter like `e` (`1d3`), as SPICE reads it
/// (ngspice inpeval.c INPevaluate; HSPICE User Guide B-2008.09 p. 49).
fn parseNumBase(text: []const u8, comptime d_exp: bool) ?NumParts {
    if (text.len == 0) return null;
    var end: usize = 0;
    var seen_digit = false;
    var seen_dot = false;
    var seen_exp = false;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (c >= '0' and c <= '9') {
            seen_digit = true;
        } else if (c == '.' and !seen_dot and !seen_exp) {
            seen_dot = true;
        } else if ((c == 'e' or c == 'E' or d_exp and (c == 'd' or c == 'D')) and !seen_exp and seen_digit and end + 1 < text.len and
            (std.ascii.isDigit(text[end + 1]) or text[end + 1] == '-' or text[end + 1] == '+'))
        {
            seen_exp = true;
            end += 1;
            if (!std.ascii.isDigit(text[end])) {
                if (end + 1 >= text.len or !std.ascii.isDigit(text[end + 1])) return null;
            }
        } else if ((c == '+' or c == '-') and end == 0) {
            // leading sign
        } else {
            break;
        }
    }
    if (!seen_digit) return null;
    var buf: [64]u8 = undefined;
    // parseFloat reads only `e`; a `d` exponent is the same number.
    const lit = if (d_exp and end <= buf.len) blk: {
        @memcpy(buf[0..end], text[0..end]);
        for (buf[0..end]) |*b| if (b.* == 'd' or b.* == 'D') {
            b.* = 'e';
        };
        break :blk buf[0..end];
    } else text[0..end];
    const base = std.fmt.parseFloat(f64, lit) catch return null;
    return .{ .base = base, .suffix = text[end..] };
}

/// A number with a SPICE scale suffix (`10meg`, `2.5u`); HSPICE also reads
/// `x` as 1e6. An unknown suffix scales by 1.
inline fn parseSpiceNum(text: []const u8, comptime hspice_suffix: bool) ?f64 {
    const parsed = parseNumBase(text, true) orelse return null;
    const s = parsed.suffix;
    const scale_exp: i32 = if (s.len == 0)
        0
    else if (std.mem.startsWith(u8, s, "meg"))
        6
    else if (std.mem.startsWith(u8, s, "mil"))
        -6
    else switch (s[0]) {
        't' => 12,
        'g' => 9,
        'x' => if (hspice_suffix) 6 else 0,
        'k' => 3,
        'm' => -3,
        'u' => -6,
        'n' => -9,
        'p' => -12,
        'f' => -15,
        'a' => -18,
        else => 0,
    };
    const lit = text[0 .. text.len - s.len];
    return inpEvaluate(lit, scale_exp, std.mem.startsWith(u8, s, "mil"));
}

/// The value of the literal `lit` (as `parseNumBase` delimits it) with scale
/// exponent `scale_exp`, computed as ngspice's INPevaluate does (inpeval.c):
/// every digit accumulates into one f64 mantissa, then `sign * mantissa *
/// pow(10, exponent)`. That is not the correctly rounded value: `0.1n` reads
/// 1e-10 here and in ngspice, where parseFloat("0.1") * 1e-9 is
/// 1.0000000000000002e-10, and a time grid built from it drifts off
/// ngspice's by an ulp per step.
fn inpEvaluate(lit: []const u8, scale_exp: i32, mil: bool) f64 {
    var i: usize = 0;
    var sign: f64 = 1;
    if (lit[0] == '+' or lit[0] == '-') {
        if (lit[0] == '-') sign = -1;
        i = 1;
    }
    var mantis: f64 = 0;
    var e: i32 = scale_exp;
    while (i < lit.len and std.ascii.isDigit(lit[i])) : (i += 1)
        mantis = 10 * mantis + @as(f64, @floatFromInt(lit[i] - '0'));
    if (i < lit.len and lit[i] == '.') {
        i += 1;
        while (i < lit.len and std.ascii.isDigit(lit[i])) : (i += 1) {
            mantis = 10 * mantis + @as(f64, @floatFromInt(lit[i] - '0'));
            e -= 1;
        }
    }
    if (i < lit.len) { // `parseNumBase` admits only an exponent here
        i += 1;
        var esign: i32 = 1;
        if (lit[i] == '+' or lit[i] == '-') {
            if (lit[i] == '-') esign = -1;
            i += 1;
        }
        var x: i32 = 0;
        while (i < lit.len) : (i += 1) x = @min(10 * x + (lit[i] - '0'), 100_000);
        e += esign * x;
    }
    if (mil) mantis *= 25.4;
    // ngspice returns 0 * inf = NaN for `0e400`; zero is zero at any scale.
    if (mantis == 0) return sign * 0;
    return sign * mantis * pow10(e);
}

/// 10^e as glibc's pow(10.0, e) returns it: the correctly rounded power for
/// every e but 23 and 210, 0 below 1e-330 and inf past 1e308 (#36).
fn pow10(e: i32) f64 {
    const lo = -330;
    const hi = 308;
    const table = comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var t: [hi - lo + 1]f64 = undefined;
        for (&t, 0..) |*p, k| p.* = std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{@as(i32, k) + lo})) catch unreachable;
        // glibc rounds these two up.
        t[23 - lo] = 1.0000000000000001e23;
        t[210 - lo] = 1.0000000000000001e210;
        break :blk t;
    };
    if (e < lo) return 0;
    if (e > hi) return std.math.inf(f64);
    return table[@intCast(e - lo)];
}

/// Copies `src` lowercased into `dst` (at least as long) and returns its
/// newline count, in one pass. W = 1 is the scalar oracle and the tail.
pub fn normalize(comptime W: comptime_int, dst: []u8, src: []const u8) usize {
    const V = @Vector(W, u8);
    var lines: usize = 0;
    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: V = src[i..][0..W].*;
        const upper = (v >= @as(V, @splat('A'))) & (v <= @as(V, @splat('Z')));
        dst[i..][0..W].* = v | @select(u8, upper, @as(V, @splat(0x20)), @as(V, @splat(0)));
        const newlines: @Int(.unsigned, W) = @bitCast(v == @as(V, @splat('\n')));
        lines += @popCount(newlines);
    }
    if (W > 1) lines += normalize(1, dst[i..], src[i..]);
    return lines;
}

/// Appends a continuation piece to a logical line, copying `head` on first use.
fn join(arena: std.mem.Allocator, joined: *?std.ArrayList(u8), head: []const u8, piece: []const u8) !void {
    if (joined.* == null) {
        joined.* = .empty;
        try joined.*.?.appendSlice(arena, head);
    }
    try joined.*.?.append(arena, ' ');
    try joined.*.?.appendSlice(arena, piece);
}

/// The next physical line without its `\r`, advancing `rest`.
// ponytail: all dialects share physical lines; comment and continuation rules stay local.
fn nextPhysicalLine(rest: *[]const u8) ?[]const u8 {
    const src = rest.*;
    if (src.len == 0) return null;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const line = std.mem.trimEnd(u8, src[0..nl], "\r");
    rest.* = if (nl == src.len) src[nl..] else src[nl + 1 ..];
    return line;
}

/// ngspice: title line, case folded, `*` comments, `$`/`;` tails, `+` continuation.
pub const ngspice = struct {
    /// The first line is the deck title, not a card.
    pub const title_line = true;
    /// Operator bytes beyond `* /` at their level: numparam's remainder and
    /// integer division (ngspice-syntax.md §2.2).
    pub const remainder_ops = "%\\";
    /// Unary `!` is numparam's logical not (ngspice-syntax.md §2.2).
    pub const unary_not = true;
    /// Cards are case-insensitive: the text is lowercased before parsing.
    pub const fold_case = true;
    /// Field splitter over one logical line.
    pub const Split = Fields("'", true);

    /// Logical-line iterator; a joined line is allocated in `arena`.
    /// tests/grammar/ngspice_lines.peg is the spec; section numbers cite
    /// dev/research/ngspice-syntax.md.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        /// A first byte that makes the line a comment [§1.5]: `*`, `#`, `$`,
        /// `;` silently, and the punctuation ngspice rewrites to `*` with a
        /// warning.
        fn isCommentLead(c: u8) bool {
            return std.mem.indexOfScalar(u8, "*#$;=[]?()&%\"!:,\x0c", c) != null;
        }

        /// `line` up to its end-of-line comment [§1.5], trimmed: `;` or `//`
        /// anywhere, `$` at the start or after a blank, tab or comma, all
        /// outside quotes (a backslash escapes a quote). Braces do not
        /// protect. One scalar pass: cards are short, and stdlib vector
        /// scans cost more in setup than they save.
        fn stripComment(line: []const u8) []const u8 {
            var quote: u8 = 0;
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                const c = line[i];
                if (quote != 0) {
                    if (c == '\\') {
                        i += 1;
                    } else if (c == quote) quote = 0;
                    continue;
                }
                switch (c) {
                    '\'', '"' => quote = c,
                    ';' => break,
                    '/' => if (i + 1 < line.len and line[i + 1] == '/') break,
                    '$' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == ',') break,
                    else => {},
                }
            }
            return std.mem.trim(u8, line[0..@min(i, line.len)], " \t");
        }

        /// True when `line` ends in `\\` and blanks [§1.6]: it continues on
        /// the next line, whatever comment sits before the backslashes.
        fn endsGlued(line: []const u8) bool {
            return std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t"), "\\\\");
        }

        /// `line` without its trailing `\\` and blanks.
        fn unglued(line: []const u8) []const u8 {
            const t = std.mem.trimEnd(u8, line, " \t");
            return t[0 .. t.len - 2];
        }

        /// The next logical line, continuations joined; null at the end.
        /// The line borrows `rest`'s text, or lives in `arena` when it joins
        /// continuations. Fails only with `OutOfMemory` while joining.
        pub fn next(self: *Lines) !?[]const u8 {
            var t: []const u8 = undefined;
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0 or isCommentLead(t[0])) continue;
                // §1.3: a line starting with `@` ends the file.
                if (t[0] == '@') {
                    self.rest = "";
                    return null;
                }
                // §1.6: a `+` line with nothing to continue is ignored.
                if (t[0] == '+') continue;
                // §1.5: a line holding only an end-of-line comment (`//x`)
                // becomes a comment line, so a `+` after it continues nothing.
                if (!endsGlued(t) and stripComment(t).len == 0) continue;
                break;
            }
            var glued = endsGlued(t);
            const head = stripComment(if (glued) unglued(t) else t);
            var joined: ?std.ArrayList(u8) = null;
            // Each pass consumes a physical line or ends the statement.
            const passes_max = self.rest.len + 1;
            var passes: usize = 0;
            while (true) : (passes += 1) {
                std.debug.assert(passes <= passes_max);
                const save = self.rest;
                const raw = nextPhysicalLine(&self.rest) orelse break;
                var u = std.mem.trim(u8, raw, " \t");
                if (glued) {
                    // §1.6: the line after a `\\` continues the statement as is.
                } else if (u.len > 0 and u[0] == '+') {
                    u = u[1..];
                } else if (u.len == 0 or u[0] == '*' or u[0] == '#' or u[0] == '$') {
                    continue;
                } else {
                    self.rest = save;
                    break;
                }
                glued = endsGlued(u);
                try join(self.arena, &joined, head, stripComment(if (glued) unglued(u) else u));
            }
            return if (joined) |j| j.items else head;
        }
    };

    /// A number literal with an ngspice scale suffix; null when `text` is not one.
    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, false);
    }
};

/// HSPICE: like ngspice, but `"` also quotes, `$` starts a comment only after
/// a separator or a number, and a trailing `\` or `\\` continues the line
/// (tests/grammar/hspice_lines.peg is the spec; rule ids L2-L6 cite
/// dev/research/hspice-syntax.md).
pub const hspice = struct {
    /// The first line is the deck title, not a card.
    pub const title_line = true;
    /// Operator bytes beyond `* /` at their level: none. The manual's
    /// operator table has no `%` or `\` (hspice-syntax.md X2, UG08
    /// pp. 279-283), and a deck that uses one is refused (#203).
    pub const remainder_ops = "";
    /// No unary `!` either: the manual's table lists `!=` only (X2), and a
    /// deck that negates with `!` is refused (#203).
    pub const unary_not = false;
    /// Cards are case-insensitive: the text is lowercased before parsing.
    pub const fold_case = true;
    /// Field splitter over one logical line. Braces are name bytes, as
    /// HSPICE's manual reads them (hspice-syntax.md T2), not an expression
    /// (#203, reversing #153's reading).
    pub const Split = Fields("'\"", false);

    /// Logical-line iterator; a joined line is allocated in `arena`.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        /// A token that ends in a `$` comment [L3]: a number with optional
        /// scale and unit letters (`1k`, `1w`, `.5e-3v`).
        fn isNumberToken(t: []const u8) bool {
            var i: usize = 0;
            if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
            const mantissa = i;
            while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
            const int_digits = i > mantissa;
            if (i < t.len and t[i] == '.') i += 1;
            const frac = i;
            while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
            if (!int_digits and i == frac) return false;
            if (i + 1 < t.len and std.ascii.toLower(t[i]) == 'e' or i + 1 < t.len and std.ascii.toLower(t[i]) == 'd') {
                var j = i + 1;
                if (t[j] == '+' or t[j] == '-') j += 1;
                const exp = j;
                while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
                if (j > exp) i = j;
            }
            while (i < t.len and std.ascii.isAlphabetic(t[i])) i += 1;
            return i == t.len;
        }

        /// A physical line's text and how it continues.
        const Part = struct { text: []const u8, brk: Break };

        /// `line` up to its inline `$` comment [L3], trimmed, and its trailing
        /// break [L6]. The comment is a `$` after a separator (blank, comma,
        /// `=`, parenthesis), after a closing quote or after a number token,
        /// outside quotes; a `$` inside a name is a name character (`a$b`).
        /// A line with a comment has no break: the backslashes are not at its
        /// end. `quote` is the quote byte open at the start of the line (0
        /// for none) and is left as the one open at its end, so a string
        /// continued by a backslash keeps its `$` signs.
        fn read(line: []const u8, quote: *u8) Part {
            const text = stripComment(line, quote);
            if (text.len < std.mem.trimEnd(u8, line, " \t").len) return .{ .text = text, .brk = .none };
            return trailingBreak(text);
        }

        fn stripComment(line: []const u8, quote: *u8) []const u8 {
            var token: usize = 0;
            for (line, 0..) |c, i| {
                if (quote.* != 0) {
                    if (c == quote.*) {
                        quote.* = 0;
                        token = i + 1;
                    }
                    continue;
                }
                switch (c) {
                    '\'', '"' => quote.* = c,
                    ' ', '\t', ',', '=', '(', ')' => token = i + 1,
                    '$' => if (token == i or isNumberToken(line[token..i])) return std.mem.trim(u8, line[0..i], " \t"),
                    else => {},
                }
            }
            return std.mem.trim(u8, line, " \t");
        }

        /// How a stripped line continues [L6]: `\\` joins the next line with
        /// nothing between, a blank and `\` with one blank.
        const Break = enum { none, glue, keep };

        fn trailingBreak(line: []const u8) Part {
            if (std.mem.endsWith(u8, line, "\\\\"))
                return .{ .text = std.mem.trimEnd(u8, line[0 .. line.len - 2], " \t"), .brk = .glue };
            if (line.len >= 2 and line[line.len - 1] == '\\' and (line[line.len - 2] == ' ' or line[line.len - 2] == '\t'))
                return .{ .text = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t"), .brk = .keep };
            return .{ .text = line, .brk = .none };
        }

        /// The next logical line, continuations joined; null at the end.
        /// The line borrows `rest`'s text, or lives in `arena` when it joins
        /// continuations. Fails only with `OutOfMemory` while joining.
        pub fn next(self: *Lines) !?[]const u8 {
            var part: Part = undefined;
            var quote: u8 = 0;
            // L2: comment lines (`*` or `$` first) and blank lines are skipped.
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0 or t[0] == '*' or t[0] == '$') continue;
                part = read(t, &quote);
                break;
            }
            const head = part.text;
            var joined: ?std.ArrayList(u8) = null;
            // Each pass consumes a physical line or ends the statement.
            const passes_max = self.rest.len + 1;
            var passes: usize = 0;
            while (true) : (passes += 1) {
                std.debug.assert(passes <= passes_max);
                if (part.brk != .none) {
                    // L6: the next physical line is text, `+` and all.
                    const raw = nextPhysicalLine(&self.rest) orelse break;
                    const brk = part.brk;
                    part = read(std.mem.trim(u8, raw, " \t"), &quote);
                    if (brk == .glue) {
                        if (joined == null) {
                            joined = .empty;
                            try joined.?.appendSlice(self.arena, head);
                        }
                        try joined.?.appendSlice(self.arena, part.text);
                    } else try join(self.arena, &joined, head, part.text);
                    continue;
                }
                // L5: a `+` line continues the statement, past comment and blank lines.
                const save = self.rest;
                const raw = nextPhysicalLine(&self.rest) orelse break;
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len > 0 and t[0] == '+') {
                    quote = 0;
                    part = read(t[1..], &quote);
                    try join(self.arena, &joined, head, part.text);
                } else if (t.len == 0 or t[0] == '*' or t[0] == '$') {
                    continue;
                } else {
                    self.rest = save;
                    break;
                }
            }
            return if (joined) |j| j.items else head;
        }
    };

    /// A number literal with an HSPICE scale suffix.
    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, true);
    }

    /// Whether `line` holds a number with both an exponent and a scale
    /// factor (`1e-6u`), which HSPICE forbids (hspice-syntax.md T3, UG08
    /// p. 49): a deck that writes one is refused (#203). A number starts
    /// after a byte that cannot continue a name, so `n1e3k` is a name.
    /// tests/grammar/lower.zig refuses the same lines.
    pub fn exponentWithScale(line: []const u8) bool {
        for (0..line.len) |i| {
            if (i > 0 and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_' or line[i - 1] == '.')) continue;
            var j = i;
            if (line[j] == '+' or line[j] == '-') j += 1;
            var digits = false;
            while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) digits = true;
            if (j < line.len and line[j] == '.') {
                j += 1;
                while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) digits = true;
            }
            if (!digits or j == line.len or std.mem.indexOfScalar(u8, "eEdD", line[j]) == null) continue;
            j += 1;
            if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
            const exponent = j;
            while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
            if (j == exponent or j == line.len) continue;
            if (std.mem.indexOfScalar(u8, "tgxkmunpfaTGXKMUNPFA", line[j]) != null) return true;
        }
        return false;
    }

    /// Whether `text`, an unquoted value after `key=`, is one HSPICE takes:
    /// a number, or an expression that starts with a letter and holds no
    /// blank (hspice-syntax.md X1, CR10 p. 238: "unless the expression
    /// begins with an alphabetic character and contains no spaces"). Any
    /// other expression needs quotes, and is refused without them (#203).
    pub fn bareValue(text: []const u8) bool {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0) return false;
        if (std.ascii.isAlphabetic(t[0])) return std.mem.indexOfAny(u8, t, " \t") == null;
        // A number: sign, mantissa, then exponent, scale and unit bytes.
        var i: usize = 0;
        if (t[0] == '+' or t[0] == '-') i = 1;
        if (i == t.len) return false;
        if (!std.ascii.isDigit(t[i]) and !(t[i] == '.' and i + 1 < t.len and std.ascii.isDigit(t[i + 1]))) return false;
        for (t[i..], i..) |c, k| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') continue;
            if ((c == '+' or c == '-') and std.mem.indexOfScalar(u8, "eEdD", t[k - 1]) != null) continue;
            return false;
        }
        return true;
    }
};

test "hspice.bareValue: a number, or a letter-led expression with no blank (#203)" {
    // Hand-listed from CR10 p. 238.
    for ([_][]const u8{ "1k", "-1", "+.5", "2.5e-3", "10pf", "a", "x*2+b", "v(1,0)*2", " cos(2)+sin(2) " }) |text|
        try std.testing.expect(hspice.bareValue(text));
    for ([_][]const u8{ "", "2*a", "6k * 2 / 3", "a + b", "(a+b)", "-a", "!a", ".", "1k-1" }) |text|
        try std.testing.expect(!hspice.bareValue(text));
}

test "hspice.exponentWithScale finds a number with an exponent and a scale (#203)" {
    // Hand-listed from T3: an exponent and a scale together, never a name.
    for ([_][]const u8{ "r1 a 0 1e-6u", "c1 a 0 c=2.5e3p", "v1 a 0 '1d3k*2'", "r1 a 0 -1e+2meg" }) |line|
        try std.testing.expect(hspice.exponentWithScale(line));
    for ([_][]const u8{ "r1 a 0 1e-6", "r1 a 0 1u", "r1 n1e3k 0 1k", "r1 a 0 1e3v", "r1 a 0 1e", "r1 a_1e3k 0 1" }) |line|
        try std.testing.expect(!hspice.exponentWithScale(line));
}

/// Spectre: the title line, case kept, `*` comment lines, `//` comments, `\`
/// or `+` continuation, and HSPICE's rules in a `simulator lang=spice`
/// region (tests/grammar/spectre_lines.peg is the spec; § cite
/// dev/research/spectre-syntax.md).
pub const spectre = struct {
    /// §1.2: line 1 of the top-level netlist is the title (UG p.29, p.50).
    pub const title_line = true;
    /// Operator bytes beyond `* /` at their level: `%`, which ESPice reads
    /// (tests/grammar/spectre.peg MulOp); `\` is no Spectre operator (#203).
    pub const remainder_ops = "%";
    /// Unary `!`, which ESPice reads (tests/grammar/spectre.peg SignOp).
    pub const unary_not = true;
    /// Cards are case-sensitive: the text is parsed as written.
    pub const fold_case = false;
    /// Field splitter over one logical line.
    pub const Split = Fields("\"", false);

    /// Logical-line iterator; a joined line is allocated in `arena`.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,
        /// Inside a `simulator lang=spice` region (§3.1).
        spice: bool = false,

        /// `line` up to its `//` comment, outside strings (a backslash
        /// escapes a quote or any byte of a name), trimmed.
        fn stripComment(line: []const u8) []const u8 {
            var i: usize = 0;
            var quoted = false;
            while (i < line.len) : (i += 1) {
                const c = line[i];
                if (c == '\\') {
                    i += 1;
                } else if (c == '"') {
                    quoted = !quoted;
                } else if (!quoted and c == '/' and i + 1 < line.len and line[i + 1] == '/') {
                    return std.mem.trim(u8, line[0..i], " \t");
                }
            }
            return std.mem.trim(u8, line, " \t");
        }

        /// A line the statement skips: blank, `*` in the first column, or
        /// only a `//` comment (§1.3).
        fn isSkip(raw: []const u8) bool {
            return (raw.len > 0 and raw[0] == '*') or stripComment(raw).len == 0;
        }

        /// A physical line's text: up to its comment, and without the
        /// backslash that continues it (§1.4) when it has one. The
        /// backslash must end the line, so a line with a comment has none.
        fn read(raw: []const u8) struct { []const u8, bool } {
            const text = stripComment(raw);
            if (text.len < std.mem.trim(u8, raw, " \t").len) return .{ text, false };
            return trailingBackslash(text);
        }

        /// `text` without the backslash that continues it, and whether it
        /// had one. A pair of backslashes is an escaped one, a name
        /// character (§2.2), so only an odd run ends in a break.
        fn trailingBackslash(text: []const u8) struct { []const u8, bool } {
            var run: usize = 0;
            while (run < text.len and text[text.len - 1 - run] == '\\') run += 1;
            if (run % 2 == 1)
                return .{ std.mem.trimEnd(u8, text[0 .. text.len - 1], " \t"), true };
            return .{ text, false };
        }

        /// True for `simulator lang=<lang>`, case-blind as a SPICE region
        /// writes it.
        fn switchesTo(line: []const u8, lang: []const u8) bool {
            var f = Fields("\"", false).init(line);
            const words = [_][]const u8{ "simulator", "lang", "=" };
            for (words) |w| if (!std.ascii.eqlIgnoreCase(f.next() orelse return false, w)) return false;
            return std.ascii.eqlIgnoreCase(f.next() orelse return false, lang);
        }

        /// The next logical line, continuations joined; null at the end.
        /// The line borrows `rest`'s text, or lives in `arena` when it joins
        /// continuations. Fails only with `OutOfMemory` while joining.
        pub fn next(self: *Lines) !?[]const u8 {
            if (self.spice) {
                // §3.2: a SPICE region reads as HSPICE does.
                var h: hspice.Lines = .{ .rest = self.rest, .arena = self.arena };
                const line = try h.next();
                self.rest = h.rest;
                if (line) |l| if (switchesTo(l, "spectre")) {
                    self.spice = false;
                };
                return line;
            }
            var raw: []const u8 = undefined;
            while (true) {
                raw = nextPhysicalLine(&self.rest) orelse return null;
                if (!isSkip(raw)) break;
            }
            var text, var cont = read(raw);
            const head = text;
            var joined: ?std.ArrayList(u8) = null;
            // Each pass consumes a physical line or ends the statement.
            const passes_max = self.rest.len + 1;
            var passes: usize = 0;
            while (true) : (passes += 1) {
                std.debug.assert(passes <= passes_max);
                const save = self.rest;
                const next_raw = nextPhysicalLine(&self.rest) orelse break;
                if (cont) {
                    text, cont = read(next_raw);
                } else {
                    const t = std.mem.trimStart(u8, next_raw, " \t");
                    if (t.len > 0 and t[0] == '+') {
                        text, cont = read(t[1..]);
                    } else if (isSkip(next_raw)) {
                        continue;
                    } else {
                        self.rest = save;
                        break;
                    }
                }
                try join(self.arena, &joined, head, text);
            }
            const line = if (joined) |j| j.items else head;
            if (switchesTo(line, "spice")) self.spice = true;
            return line;
        }
    };

    /// A number literal with a case-sensitive Spectre suffix (`M` mega, `m` milli).
    pub fn parseNum(text: []const u8) ?f64 {
        const parsed = parseNumBase(text, false) orelse return null;
        const s = parsed.suffix;
        const scale: f64 = if (s.len == 0) 1 else switch (s[0]) {
            'P' => 1e15,
            'T' => 1e12,
            'G' => 1e9,
            'M' => 1e6,
            'K', 'k' => 1e3,
            '%', 'c' => 1e-2,
            'm' => 1e-3,
            'u' => 1e-6,
            'n' => 1e-9,
            'p' => 1e-12,
            'f' => 1e-15,
            'a' => 1e-18,
            else => 1,
        };
        return parsed.base * scale;
    }
};

/// The comptime syntax a dialect selects.
pub fn Syntax(comptime d: Dialect) type {
    return switch (d) {
        .ngspice => ngspice,
        .hspice => hspice,
        .spectre => spectre,
    };
}

test Fields {
    const F = ngspice.Split;
    var f = F.init("r1 a=1 'x y' {a {b}} (c,d)");
    try std.testing.expectEqualStrings("r1", f.peek().?);
    for ([_][]const u8{ "r1", "a", "=", "1", "'x y'", "{a {b}}", "(", "c", ",", "d", ")" }) |want|
        try std.testing.expectEqualStrings(want, f.next().?);
    try std.testing.expectEqual(null, f.next());
    try std.testing.expectEqual(null, f.peek());
    // Unterminated quotes and braces run to the end of the line.
    f = F.init("'abc");
    try std.testing.expectEqualStrings("abc", F.body(f.next().?));
    f = F.init("{a {b} c");
    try std.testing.expectEqualStrings("a {b} c", F.body(f.next().?));
    try std.testing.expectEqualStrings("", F.body("'"));
    try std.testing.expectEqualStrings("", F.body("''"));
    f = F.init("k = v  ");
    try std.testing.expectEqualStrings("k", f.next().?);
    try std.testing.expect(f.takeEq());
    try std.testing.expectEqualStrings("v", f.rest());
    try std.testing.expect(!f.takeEq());
    try std.testing.expectEqual('v', f.nextByte());
    try std.testing.expect(F.isWord("abc") and !F.isWord("=") and !F.isWord("'x'") and !F.isWord("{x}"));
    // HSPICE: `"` quotes too, and braces are name bytes (#203).
    var h = hspice.Split.init("{a+b} {a b} \"b c\"");
    try std.testing.expectEqualStrings("{a+b}", h.next().?);
    try std.testing.expectEqualStrings("{a", h.next().?);
    try std.testing.expectEqualStrings("b}", h.next().?);
    try std.testing.expect(hspice.Split.isWord("{x}"));
    try std.testing.expectEqualStrings("\"b c\"", h.next().?);
    try std.testing.expect(hspice.Split.isQuote('"') and !ngspice.Split.isQuote('"'));
}

test plainNumber {
    // Hand-listed from Touchstone 2.0 rule 6: digits with an optional sign,
    // point and exponent, and nothing else parseFloat would also take.
    for ([_][]const u8{ "1", "-2.5", "+.5", "5.", "1e3", "1.5E-3", "-0e+0" }) |text|
        try std.testing.expect(plainNumber(text) != null);
    for ([_][]const u8{ "", ".", "+", "-.", ".e5", "1e", "1e+", "1k", "inf", "nan", "0x10", "1_0", " 1" }) |text|
        try std.testing.expect(plainNumber(text) == null);
    try std.testing.expectEqual(@as(?f64, -1.5e-3), plainNumber("-1.5e-3"));
}

test "number literals read as ngspice's INPevaluate" {
    const n = ngspice.parseNum;
    try std.testing.expectEqual(1e7, n("10meg").?);
    try std.testing.expectEqual(1e-10, n("0.1n").?); // not parseFloat("0.1") * 1e-9
    try std.testing.expectEqual(1e-3, n("1m").?);
    try std.testing.expectEqual(1e-3, n("1ms").?);
    try std.testing.expectEqual(1000, n("1k").?);
    try std.testing.expectEqual(1000, n("1e3").?);
    try std.testing.expectEqual(1, n("1e-3k").?);
    try std.testing.expectEqual(0.5, n("+.5").?);
    try std.testing.expectEqual(-3, n("-3").?);
    try std.testing.expectEqual(5, n("5v").?); // an unknown suffix scales by 1
    try std.testing.expectEqual(2e-18, n("2a").?); // atto (#121)
    try std.testing.expectEqual(1000, n("1d3").?); // `d` exponent (#121)
    try std.testing.expectEqual(2.5e-3, hspice.parseNum("2.5D-3").?);
    try std.testing.expectEqual(1, spectre.parseNum("1d3").?); // not a Spectre exponent
    try std.testing.expectEqual(1, n("1x").?);
    try std.testing.expectEqual(1e6, hspice.parseNum("1x").?);
    try std.testing.expectApproxEqRel(25.4e-6, n("1mil").?, 1e-15);
    try std.testing.expectEqual(1.0000000000000001e23, n("1e23").?); // glibc's pow(10, 23)
    try std.testing.expect(1.0000000000000001e23 != 1e23);
    // Past +-40 the exponent reads exactly too, as glibc's pow does (#36).
    try std.testing.expectEqual(1e-300, n("1e-300").?);
    try std.testing.expectEqual(1e300, n("1e300").?);
    try std.testing.expectEqual(@as(f64, 3) * @as(f64, 1e45), n("3e45").?); // 3 * pow(10, 45), as inpeval.c
    try std.testing.expectEqual(1.0000000000000001e210, n("1e210").?);
    try std.testing.expectEqual(0, n("1e-331").?);
    try std.testing.expectEqual(0, n("0e400").?);
    try std.testing.expect(std.math.isInf(n("1e400").?));
    for ([_][]const u8{ "", "-", ".", "abc", "e5", "1e+" }) |bad| try std.testing.expectEqual(null, n(bad));
    // Spectre suffixes are case-sensitive and read through parseFloat.
    try std.testing.expectEqual(1e6, spectre.parseNum("1M").?);
    try std.testing.expectEqual(1e-3, spectre.parseNum("1m").?);
    try std.testing.expectEqual(1e-3, spectre.parseNum("1meg").?);
    try std.testing.expectEqual(0.5, spectre.parseNum("50%").?);
    try std.testing.expectEqual(1e5, spectre.parseNum("1E5").?);
}

fn expectLines(comptime S: type, src: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var it: S.Lines = .{ .rest = src, .arena = arena.allocator() };
    for (want) |w| try std.testing.expectEqualStrings(w, (try it.next()).?);
    try std.testing.expectEqual(null, try it.next());
}

test "logical lines per dialect" {
    try expectLines(ngspice, "", &.{});
    try expectLines(ngspice, "* c\nr1 a b 1k $ tail\n+ 2 ; more\n\n* mid\n+ 3\n$ only\nc1 x y 1p\r\n", &.{ "r1 a b 1k 2 3", "c1 x y 1p" });
    // `\\` squeezes the blanks out of the join, ` \` keeps one (HSPICE User
    // Guide B-2008.09 p. 40); `$` after a number or a comma is a comment (p. 56).
    try expectLines(hspice, "r1 a b$c 1k $ tail\nr2 a \\\\\nb 2\n+ 3\n", &.{ "r1 a b$c 1k", "r2 ab 2 3" });
    try expectLines(hspice, "$ note\nr3 a b \\\n  2k$c\nr4 a b 1,$c\n", &.{ "r3 a b 2k", "r4 a b 1," });
    // No `/* */` in Spectre (spectre-syntax.md §1.3); `*` comments only in
    // the first column; a SPICE region reads as HSPICE does.
    try expectLines(spectre, "r1 (a b) resistor r=1k // c\nr2 \"x//y\" b \\\n  r=2\n// note\n+ m=1\n* gone\n", &.{ "r1 (a b) resistor r=1k", "r2 \"x//y\" b r=2 m=1" });
    try expectLines(spectre, "simulator lang=spice\nR1 a b 1k $ c\n+ tc1=1\nsimulator lang=spectre\nr2 (a b) resistor r=1 $x\n", &.{ "simulator lang=spice", "R1 a b 1k tc1=1", "simulator lang=spectre", "r2 (a b) resistor r=1 $x" });
}
