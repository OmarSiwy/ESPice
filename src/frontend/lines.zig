//! Bytes to logical lines to fields, per dialect, plus SPICE numbers.
//!
//! A field is a slice of the line. `=`, `(`, `)` and `,` are one-byte
//! fields; a `{...}` or quoted field keeps its delimiters, so its kind is
//! its first byte. Every other field is a word.
const std = @import("std");

pub const Dialect = enum { ngspice, hspice, spectre };

/// Split `line` into fields. `quotes` are the quote bytes, `braces` keeps
/// `{...}` whole.
pub fn Fields(comptime quotes: []const u8, comptime braces: bool) type {
    return struct {
        line: []const u8,
        pos: usize = 0,

        const Self = @This();

        pub fn init(line: []const u8) Self {
            return .{ .line = line };
        }

        /// The unread part of the line, blank-trimmed.
        pub fn rest(self: Self) []const u8 {
            return std.mem.trim(u8, self.line[self.pos..], " \t");
        }

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

        pub fn isQuote(c: u8) bool {
            inline for (quotes) |q| if (c == q) return true;
            return false;
        }

        /// A `{...}` or quoted field without its delimiters.
        pub fn body(f: []const u8) []const u8 {
            const close: u8 = if (f[0] == '{') '}' else f[0];
            return if (f.len >= 2 and f[f.len - 1] == close) f[1 .. f.len - 1] else f[1..];
        }

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

pub const NumParts = struct { base: f64, suffix: []const u8 };

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

/// Copy `src` lowercased into `dst` and count its newlines in one pass.
/// W=1 is the scalar oracle and tail; byte lanes are independent.
pub fn normalize(comptime W: comptime_int, dst: []u8, src: []const u8) usize {
    const V = @Vector(W, u8);
    var lines: usize = 0;
    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: V = src[i..][0..W].*;
        const upper = (v >= @as(V, @splat('A'))) & (v <= @as(V, @splat('Z')));
        dst[i..][0..W].* = v | @select(u8, upper, @as(V, @splat(0x20)), @as(V, @splat(0)));
        const newlines: std.meta.Int(.unsigned, W) = @bitCast(v == @as(V, @splat('\n')));
        lines += @popCount(newlines);
    }
    if (W > 1) lines += normalize(1, dst[i..], src[i..]);
    return lines;
}

/// Append a continuation piece to a logical line, copying `head` on first use.
fn join(arena: std.mem.Allocator, joined: *?std.ArrayList(u8), head: []const u8, piece: []const u8) !void {
    if (joined.* == null) {
        joined.* = .empty;
        try joined.*.?.appendSlice(arena, head);
    }
    try joined.*.?.append(arena, ' ');
    try joined.*.?.appendSlice(arena, piece);
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

pub const ngspice = struct {
    pub const title_line = true;
    pub const fold_case = true;
    pub const Split = Fields("'", true);

    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        /// Cut at the first `$` or `;`. One scalar pass: cards are short, and
        /// two stdlib vector scans cost more in setup than they save.
        fn stripComment(line: []const u8) []const u8 {
            const cut = for (line, 0..) |c, i| {
                if (c == '$' or c == ';') break i;
            } else line.len;
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

    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, false);
    }
};

pub const hspice = struct {
    pub const title_line = true;
    pub const fold_case = true;
    pub const Split = Fields("'\"", false);

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

    pub fn parseNum(text: []const u8) ?f64 {
        return parseSpiceNum(text, true);
    }
};

pub const spectre = struct {
    pub const title_line = false;
    pub const fold_case = false;
    pub const Split = Fields("\"", false);

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

        /// Copies the spans between comments, not byte by byte. An unterminated
        /// `/*` still discards the rest of the line.
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
