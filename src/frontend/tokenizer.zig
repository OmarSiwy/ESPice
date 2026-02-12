const std = @import("std");

// ============================================================================
// Shared token types
// ============================================================================

pub const Token = union(enum) {
    word: []const u8,
    eq,
    lparen,
    rparen,
    comma,
    braced: []const u8,
    quoted: []const u8,
};

pub const NumParts = struct { base: f64, suffix: []const u8 };

pub fn GenTokens(comptime cfg: struct {
    quotes: []const u8 = "",
    braces: bool = false,
}) type {
    return struct {
        line: []const u8,
        pos: usize = 0,

        const Self = @This();

        pub fn init(line: []const u8) Self {
            return .{ .line = line };
        }

        pub fn rest(self: *const Self) []const u8 {
            return std.mem.trim(u8, self.line[self.pos..], " \t");
        }

        fn isBreak(c: u8) bool {
            if (c == ' ' or c == '\t' or c == '=' or c == '(' or c == ')' or c == ',') return true;
            inline for (cfg.quotes) |q| {
                if (c == q) return true;
            }
            return cfg.braces and c == '{';
        }

        pub fn next(self: *Self) ?Token {
            while (self.pos < self.line.len and (self.line[self.pos] == ' ' or self.line[self.pos] == '\t'))
                self.pos += 1;
            if (self.pos >= self.line.len) return null;
            const c = self.line[self.pos];
            switch (c) {
                '=' => {
                    self.pos += 1;
                    return .eq;
                },
                '(' => {
                    self.pos += 1;
                    return .lparen;
                },
                ')' => {
                    self.pos += 1;
                    return .rparen;
                },
                ',' => {
                    self.pos += 1;
                    return .comma;
                },
                else => {},
            }
            inline for (cfg.quotes) |q| {
                if (c == q) {
                    const end = std.mem.indexOfScalarPos(u8, self.line, self.pos + 1, q) orelse self.line.len;
                    const body = self.line[self.pos + 1 .. end];
                    self.pos = @min(end + 1, self.line.len);
                    return .{ .quoted = body };
                }
            }
            if (cfg.braces and c == '{') {
                var depth: usize = 0;
                var i = self.pos;
                while (i < self.line.len) : (i += 1) {
                    if (self.line[i] == '{') depth += 1;
                    if (self.line[i] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                const body = self.line[self.pos + 1 .. @min(i, self.line.len)];
                self.pos = @min(i + 1, self.line.len);
                return .{ .braced = body };
            }
            const start = self.pos;
            while (self.pos < self.line.len) : (self.pos += 1) {
                if (isBreak(self.line[self.pos])) break;
            }
            return .{ .word = self.line[start..self.pos] };
        }
    };
}

pub fn parseNumBase(text: []const u8) ?NumParts {
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

inline fn parseSpiceNum(text: []const u8, comptime hspice_suffix: bool) ?f64 {
    const parsed = parseNumBase(text) orelse return null;
    const s = parsed.suffix;
    const scale: f64 = if (s.len == 0)
        1
    else if (std.mem.startsWith(u8, s, "meg"))
        1e6
    else if (std.mem.startsWith(u8, s, "mil"))
        25.4e-6
    else switch (s[0]) {
        't' => 1e12,
        'g' => 1e9,
        'x' => if (hspice_suffix) 1e6 else 1,
        'k' => 1e3,
        'm' => 1e-3,
        'u' => 1e-6,
        'n' => 1e-9,
        'p' => 1e-12,
        'f' => 1e-15,
        else => 1,
    };
    return parsed.base * scale;
}

// ponytail: all dialects share physical lines; comment and continuation rules stay local.
fn nextPhysicalLine(rest: *[]const u8) ?[]const u8 {
    const src = rest.*;
    if (src.len == 0) return null;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const line = std.mem.trimEnd(u8, src[0..nl], "\r");
    rest.* = if (nl == src.len) src[nl..] else src[nl + 1 ..];
    return line;
}

// ============================================================================
// ngspice tokenizer
// ============================================================================

pub const ngspice = struct {
    pub const has_title_line = true;
    pub const case_normalize = true;

    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        pub fn init(arena: std.mem.Allocator, src: []const u8) Lines {
            return .{ .rest = src, .arena = arena };
        }

        fn stripComment(line: []const u8) []const u8 {
            // ponytail: reuse the first cutoff to bound the second stdlib vector scan.
            const dollar = std.mem.indexOfScalar(u8, line, '$') orelse line.len;
            const cut = std.mem.indexOfScalar(u8, line[0..dollar], ';') orelse dollar;
            return std.mem.trim(u8, line[0..cut], " \t");
        }

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
                    const cont = stripComment(t[1..]);
                    if (joined == null) {
                        joined = .empty;
                        try joined.?.appendSlice(self.arena, head);
                    }
                    try joined.?.append(self.arena, ' ');
                    try joined.?.appendSlice(self.arena, cont);
                } else if (t.len > 0 and t[0] == '*') {
                    continue;
                } else if (t.len == 0) {
                    continue;
                } else {
                    self.rest = save;
                    break;
                }
            }
            return if (joined) |j| j.items else head;
        }
    };

    pub const Tokens = GenTokens(.{ .quotes = "'", .braces = true });

    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, false);
    }
};

// ============================================================================
// HSPICE tokenizer
// ============================================================================

pub const hspice = struct {
    pub const has_title_line = true;
    pub const case_normalize = true;

    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        pub fn init(arena: std.mem.Allocator, src: []const u8) Lines {
            return .{ .rest = src, .arena = arena };
        }

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
                        const cont = stripComment(t[1..]);
                        if (joined == null) {
                            joined = .empty;
                            try joined.?.appendSlice(self.arena, head);
                        }
                        try joined.?.append(self.arena, ' ');
                        try joined.?.appendSlice(self.arena, cont);
                        // ponytail: the appends above already require an initialized list.
                        const bs = stripTrailingBackslash(joined.?.items);
                        trailing_cont = bs.continues;
                        if (trailing_cont) {
                            joined.?.shrinkRetainingCapacity(bs.text.len);
                        }
                    } else if (t.len > 0 and t[0] == '*') {
                        continue;
                    } else if (t.len == 0) {
                        continue;
                    } else {
                        self.rest = save;
                        break;
                    }
                } else {
                    const raw = nextPhysicalLine(&self.rest) orelse break;
                    const t = std.mem.trim(u8, raw, " \t");
                    if (joined == null) {
                        joined = .empty;
                        try joined.?.appendSlice(self.arena, head);
                    }
                    try joined.?.append(self.arena, ' ');
                    const stripped = stripComment(t);
                    const bs = stripTrailingBackslash(stripped);
                    try joined.?.appendSlice(self.arena, bs.text);
                    trailing_cont = bs.continues;
                }
            }
            return if (joined) |j| j.items else head;
        }
    };

    pub const Tokens = GenTokens(.{ .quotes = "'\"" });

    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, true);
    }
};

// ============================================================================
// Spectre tokenizer
// ============================================================================

pub const spectre = struct {
    pub const has_title_line = false;
    pub const case_normalize = false;

    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        pub fn init(arena: std.mem.Allocator, src: []const u8) Lines {
            return .{ .rest = src, .arena = arena };
        }

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
            if (line.len > 0 and line[0] == '*') {
                return "";
            }
            return std.mem.trim(u8, line, " \t");
        }

        /// Copies the spans between comments, not byte by byte. An unterminated
        /// `/*` still discards the rest of the line.
        fn stripBlockComments(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
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
            if (line.len > 0 and line[line.len - 1] == '\\') {
                return std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
            }
            return line;
        }

        pub fn next(self: *Lines) !?[]const u8 {
            var head: []const u8 = undefined;
            var trailing_cont = false;
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                const stripped = stripComment(raw);
                const clean = try stripBlockComments(self.arena, stripped);
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
                    if (t.len > 0 and t[0] == '+') {
                        break :blk t[1..];
                    } else if (t.len == 0 or (t.len > 0 and t[0] == '*')) {
                        continue;
                    } else {
                        self.rest = save;
                        break;
                    }
                };
                const stripped = stripComment(line);
                const clean = try stripBlockComments(self.arena, stripped);
                if (joined == null) {
                    joined = .empty;
                    try joined.?.appendSlice(self.arena, head);
                }
                try joined.?.append(self.arena, ' ');
                trailing_cont = hasContinuation(clean);
                try joined.?.appendSlice(self.arena, trimContinuation(clean));
            }
            return if (joined) |j| j.items else head;
        }
    };

    pub const Tokens = GenTokens(.{ .quotes = "\"" });

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

test "spectre: block comments are stripped span-wise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const strip = spectre.Lines.stripBlockComments;
    // No marker: the input slice is returned untouched.
    try std.testing.expectEqualStrings("r1 a b 1k", try strip(a, "r1 a b 1k"));
    // Only the ends are trimmed; the spaces that flanked a comment survive.
    try std.testing.expectEqualStrings("r1  a b  1k", try strip(a, "r1 /*x*/ a b /*y*/ 1k"));
    try std.testing.expectEqualStrings("ad", try strip(a, "a/**//*c*/d")); // adjacent markers
    try std.testing.expectEqualStrings("", try strip(a, "/**/"));
    // Unterminated: the rest of the line goes with the comment.
    try std.testing.expectEqualStrings("a", try strip(a, "a /*b c"));
    try std.testing.expectEqualStrings("", try strip(a, "/*"));
}
