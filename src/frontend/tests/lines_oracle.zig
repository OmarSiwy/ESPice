//! The logical-line readers as they stood before the single-scan rewrite
//! (HEAD 76627329), kept as the oracle for `tests/lines.zig`: every
//! logical line the rewrite produces must match this copy. Do not optimize it; it is the reference.
const std = @import("std");
const Fields = @import("../lines.zig").Fields;

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
                    else => {}, // else: any other byte is text
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
};

/// HSPICE: like ngspice, but `"` also quotes, `$` starts a comment only after
/// a separator or a number, and a trailing `\` or `\\` continues the line
/// (tests/grammar/hspice_lines.peg is the spec; rule ids L2-L6 cite
/// dev/research/hspice-syntax.md).
pub const hspice = struct {
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
                    else => {}, // else: any other byte is text
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
};

/// Spectre: the title line, case kept, `*` comment lines, `//` comments, `\`
/// or `+` continuation, and HSPICE's rules in a `simulator lang=spice`
/// region (tests/grammar/spectre_lines.peg is the spec; § cite
/// dev/research/spectre-syntax.md).
pub const spectre = struct {
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
};
