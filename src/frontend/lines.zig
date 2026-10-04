//! Bytes to logical lines to fields, per dialect, plus SPICE number literals.
//! A field is a slice of the line: `=`, `(`, `)` and `,` are one-byte fields,
//! a `{...}` or quoted field keeps its delimiters (its kind is its first
//! byte), and anything else is a word.
const std = @import("std");

/// Input syntax.
pub const Dialect = enum { ngspice, hspice, spectre };

/// Split `line` into fields. `quotes` are the quote bytes, `braces` keeps
/// `{...}` whole.
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

        /// First byte of the next field.
        pub fn nextByte(self: *Self) ?u8 {
            while (self.pos < self.line.len and (self.line[self.pos] == ' ' or self.line[self.pos] == '\t')) self.pos += 1;
            return if (self.pos < self.line.len) self.line[self.pos] else null;
        }

        /// Consume a `=` field if one is next: the word just read is a key.
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

const NumParts = struct { base: f64, suffix: []const u8 };

/// The leading decimal literal of `text` and the suffix after it.
fn parseNumBase(text: []const u8) ?NumParts {
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
        } else if ((c == 'e' or c == 'E') and !seen_exp and seen_digit and end + 1 < text.len and
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
    const base = std.fmt.parseFloat(f64, text[0..end]) catch return null;
    return .{ .base = base, .suffix = text[end..] };
}

/// A number with a SPICE scale suffix (`10meg`, `2.5u`); HSPICE also reads
/// `x` as 1e6. An unknown suffix scales by 1.
inline fn parseSpiceNum(text: []const u8, comptime hspice_suffix: bool) ?f64 {
    const parsed = parseNumBase(text) orelse return null;
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

/// 10^e as glibc's pow(10.0, e) returns it, which is the correctly rounded
/// power for every e in [-40, 40] but 23.
fn pow10(e: i32) f64 {
    const table = comptime blk: {
        @setEvalBranchQuota(200_000);
        var t: [81]f64 = undefined;
        for (&t, 0..) |*p, k| p.* = std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{@as(i32, k) - 40})) catch unreachable;
        t[40 + 23] = 1.0000000000000001e23; // glibc rounds this one up
        break :blk t;
    };
    if (e < -40 or e > 40) return std.math.pow(f64, 10, @floatFromInt(e));
    return table[@intCast(e + 40)];
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
    /// Cards are case-insensitive: the text is lowercased before parsing.
    pub const fold_case = true;
    /// Field splitter over one logical line.
    pub const Split = Fields("'", true);

    /// Logical-line iterator; a joined line is allocated in `arena`.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        /// Cuts at the first `$` or `;`. One scalar pass: cards are short, and
        /// two stdlib vector scans cost more in setup than they save.
        fn stripComment(line: []const u8) []const u8 {
            const cut = for (line, 0..) |c, i| {
                if (c == '$' or c == ';') break i;
            } else line.len;
            return std.mem.trim(u8, line[0..cut], " \t");
        }

        /// The next logical line, continuations joined; null at the end.
        pub fn next(self: *Lines) !?[]const u8 {
            var head: []const u8 = undefined;
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0 or t[0] == '*') continue;
                head = stripComment(t);
                if (head.len == 0) continue;
                break;
            }
            var joined: ?std.ArrayList(u8) = null;
            while (true) {
                const save = self.rest;
                const raw = nextPhysicalLine(&self.rest) orelse break;
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len > 0 and t[0] == '+') {
                    try join(self.arena, &joined, head, stripComment(t[1..]));
                } else if (t.len == 0 or t[0] == '*') {
                    continue;
                } else {
                    self.rest = save;
                    break;
                }
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
/// a blank, and a trailing `\\` continues the line.
pub const hspice = struct {
    /// The first line is the deck title, not a card.
    pub const title_line = true;
    /// Cards are case-insensitive: the text is lowercased before parsing.
    pub const fold_case = true;
    /// Field splitter over one logical line.
    pub const Split = Fields("'\"", false);

    /// Logical-line iterator; a joined line is allocated in `arena`.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        fn stripComment(line: []const u8) []const u8 {
            var cut = line.len;
            var i: usize = 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '$' and (line[i - 1] == ' ' or line[i - 1] == '\t')) {
                    cut = i;
                    break;
                }
            }
            return std.mem.trim(u8, line[0..cut], " \t");
        }

        fn stripTrailingBackslash(line: []const u8) struct { text: []const u8, continues: bool } {
            if (line.len >= 2 and line[line.len - 2] == '\\' and line[line.len - 1] == '\\') {
                return .{ .text = std.mem.trimEnd(u8, line[0 .. line.len - 2], " \t"), .continues = true };
            }
            return .{ .text = line, .continues = false };
        }

        /// The next logical line, continuations joined; null at the end.
        pub fn next(self: *Lines) !?[]const u8 {
            var head: []const u8 = undefined;
            var trailing_cont = false;
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                const t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0 or t[0] == '*') continue;
                const stripped = stripComment(t);
                if (stripped.len == 0) continue;
                const bs = stripTrailingBackslash(stripped);
                head = bs.text;
                trailing_cont = bs.continues;
                break;
            }
            var joined: ?std.ArrayList(u8) = null;
            while (true) {
                if (!trailing_cont) {
                    const save = self.rest;
                    const raw = nextPhysicalLine(&self.rest) orelse break;
                    const t = std.mem.trim(u8, raw, " \t");
                    if (t.len > 0 and t[0] == '+') {
                        try join(self.arena, &joined, head, stripComment(t[1..]));
                        const bs = stripTrailingBackslash(joined.?.items);
                        trailing_cont = bs.continues;
                        if (trailing_cont) joined.?.shrinkRetainingCapacity(bs.text.len);
                    } else if (t.len == 0 or t[0] == '*') {
                        continue;
                    } else {
                        self.rest = save;
                        break;
                    }
                } else {
                    const raw = nextPhysicalLine(&self.rest) orelse break;
                    const bs = stripTrailingBackslash(stripComment(std.mem.trim(u8, raw, " \t")));
                    try join(self.arena, &joined, head, bs.text);
                    trailing_cont = bs.continues;
                }
            }
            return if (joined) |j| j.items else head;
        }
    };

    /// A number literal with an HSPICE scale suffix.
    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, true);
    }
};

/// Spectre: no title line, case kept, `//` and `/* */` comments, `\` or `+`
/// continuation.
pub const spectre = struct {
    /// No title line: the first line is already a card.
    pub const title_line = false;
    /// Cards are case-sensitive: the text is parsed as written.
    pub const fold_case = false;
    /// Field splitter over one logical line.
    pub const Split = Fields("\"", false);

    /// Logical-line iterator; a joined or comment-stripped line is
    /// allocated in `arena`.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        fn stripComment(line: []const u8) []const u8 {
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                    return std.mem.trim(u8, line[0..i], " \t");
                }
                if (line[i] == '"') {
                    i += 1;
                    while (i < line.len and line[i] != '"') : (i += 1) {}
                }
            }
            if (line.len > 0 and line[0] == '*') return "";
            return std.mem.trim(u8, line, " \t");
        }

        /// Removes `/* */` comments, copying the spans between them. An
        /// unterminated `/*` discards the rest of the line.
        pub fn stripBlockComments(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
            var open = std.mem.indexOf(u8, line, "/*") orelse return line;
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendSlice(arena, line[0..open]);
            while (std.mem.indexOfPos(u8, line, open + 2, "*/")) |close| {
                const keep = close + 2;
                open = std.mem.indexOfPos(u8, line, keep, "/*") orelse line.len;
                try buf.appendSlice(arena, line[keep..open]);
                if (open == line.len) break;
            }
            return std.mem.trim(u8, buf.items, " \t");
        }

        // Both helpers receive trimmed output from stripBlockComments.
        fn hasContinuation(line: []const u8) bool {
            return line.len > 0 and line[line.len - 1] == '\\';
        }

        fn trimContinuation(line: []const u8) []const u8 {
            if (hasContinuation(line)) return std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
            return line;
        }

        /// The next logical line, continuations joined; null at the end.
        pub fn next(self: *Lines) !?[]const u8 {
            var head: []const u8 = undefined;
            var trailing_cont = false;
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                const clean = try stripBlockComments(self.arena, stripComment(raw));
                if (clean.len == 0) continue;
                trailing_cont = hasContinuation(clean);
                head = trimContinuation(clean);
                if (head.len == 0) continue;
                break;
            }
            var joined: ?std.ArrayList(u8) = null;
            while (true) {
                const line = if (trailing_cont)
                    nextPhysicalLine(&self.rest) orelse break
                else blk: {
                    const save = self.rest;
                    const raw = nextPhysicalLine(&self.rest) orelse break;
                    const t = std.mem.trim(u8, raw, " \t");
                    if (t.len > 0 and t[0] == '+') break :blk t[1..];
                    if (t.len == 0 or t[0] == '*') continue;
                    self.rest = save;
                    break;
                };
                const clean = try stripBlockComments(self.arena, stripComment(line));
                trailing_cont = hasContinuation(clean);
                try join(self.arena, &joined, head, trimContinuation(clean));
            }
            return if (joined) |j| j.items else head;
        }
    };

    /// A number literal with a case-sensitive Spectre suffix (`M` mega, `m` milli).
    pub fn parseNum(text: []const u8) ?f64 {
        const parsed = parseNumBase(text) orelse return null;
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
    // HSPICE: `"` quotes too, and braces are plain word bytes.
    var h = hspice.Split.init("{a} \"b c\"");
    try std.testing.expectEqualStrings("{a}", h.next().?);
    try std.testing.expectEqualStrings("\"b c\"", h.next().?);
    try std.testing.expect(hspice.Split.isQuote('"') and !ngspice.Split.isQuote('"'));
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
    try std.testing.expectEqual(1, n("1x").?);
    try std.testing.expectEqual(1e6, hspice.parseNum("1x").?);
    try std.testing.expectApproxEqRel(25.4e-6, n("1mil").?, 1e-15);
    try std.testing.expectEqual(1.0000000000000001e23, n("1e23").?); // glibc's pow(10, 23)
    try std.testing.expect(1.0000000000000001e23 != 1e23);
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
    try expectLines(hspice, "r1 a b$c 1k $ tail\nr2 a \\\\\nb 2\n+ 3\n", &.{ "r1 a b$c 1k", "r2 a b 2 3" });
    try expectLines(spectre, "r1 (a b) resistor r=1k // c\nr2 \"x//y\" b \\\n  r=2\n+ m=1\n/* gone */\n", &.{ "r1 (a b) resistor r=1k", "r2 \"x//y\" b r=2 m=1" });
}
