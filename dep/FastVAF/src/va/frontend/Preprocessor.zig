const std = @import("std");
const Allocator = std.mem.Allocator;
const Buf = @import("emit").Buf;

const Preprocessor = @This();

const Macro = struct {
    params: ?[]const []const u8,
    body: []const u8,
};

const IfState = struct {
    active: bool,
    seen_true: bool,
    parent_active: bool,
};

/// `ifdef nesting deeper than this is rejected loudly (real models nest < 10).
const max_ifdef_depth = 64;

allocator: Allocator,
defines: std.StringHashMapUnmanaged(Macro) = .empty,
ifdef_stack: [max_ifdef_depth]IfState = undefined,
ifdef_depth: u8 = 0,
output: Buf(u8) = .empty,
include_depth: u32 = 0,
/// Non-standard `` `include `` files resolve against these (netlist-relative
/// dirs, threaded from compileSource). Requires `io`.
include_dirs: []const []const u8 = &.{},
io: ?std.Io = null,
expand_depth: u32 = 0,

pub fn init(allocator: Allocator) Preprocessor {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Preprocessor) void {
    self.clearDefines();
    self.output.deinit(self.allocator);
}

pub fn process(allocator: Allocator, source: []const u8) ![]const u8 {
    return processWithIncludes(allocator, source, null, &.{});
}

pub fn processWithIncludes(
    allocator: Allocator,
    source: []const u8,
    io: ?std.Io,
    include_dirs: []const []const u8,
) ![]const u8 {
    var pp = init(allocator);
    defer pp.deinit();
    pp.io = io;
    pp.include_dirs = include_dirs;
    try pp.processSource(source);
    return try pp.output.toOwnedSlice(allocator);
}

const PpError = Allocator.Error || error{ UndefinedMacro, IfdefTooDeep, IncludeNotFound, MacroRecursion };

fn processSource(self: *Preprocessor, source: []const u8) PpError!void {
    // Comments die before directives: EKV keeps dead `include lines inside
    // /* */ blocks, and `//` in macro text must never poison expansion.
    const stripped = try stripComments(self.allocator, source);
    defer self.allocator.free(stripped);
    try self.processStripped(stripped);
}

/// Blank out `//` and `/* */` comments (quote-aware), preserving newlines so
/// diagnostics keep their line numbers.
fn stripComments(allocator: Allocator, source: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, source);
    var i: usize = 0;
    while (i < out.len) {
        switch (out[i]) {
            '"' => {
                i += 1;
                while (i < out.len and out[i] != '"' and out[i] != '\n') {
                    i += if (out[i] == '\\' and i + 1 < out.len) @as(usize, 2) else 1;
                }
                if (i < out.len and out[i] == '"') i += 1;
            },
            '/' => {
                if (i + 1 < out.len and out[i + 1] == '/') {
                    while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
                } else if (i + 1 < out.len and out[i + 1] == '*') {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                    while (i < out.len and !(out[i] == '*' and i + 1 < out.len and out[i + 1] == '/')) : (i += 1) {
                        if (out[i] != '\n') out[i] = ' ';
                    }
                    if (i + 1 < out.len) {
                        out[i] = ' ';
                        out[i + 1] = ' ';
                        i += 2;
                    } else i = out.len;
                } else i += 1;
            },
            else => i += 1,
        }
    }
    return out;
}

fn processStripped(self: *Preprocessor, source: []const u8) PpError!void {
    try self.output.ensureTotalCapacity(self.allocator, self.output.len + source.len + source.len / 64);
    var pos: usize = 0;
    while (pos < source.len) {
        const line_start = pos;
        var line_end = pos;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        const newline_pos = line_end;
        if (line_end < source.len) line_end += 1;

        const line = source[line_start..newline_pos];
        const trimmed = std.mem.trimStart(u8, line, " \t");

        if (trimmed.len > 0 and trimmed[0] == '`') {
            const directive_text = trimmed[1..];

            if (startsWith(directive_text, "define ") or startsWith(directive_text, "define\t")) {
                if (self.isActive()) {
                    var full_line: Buf(u8) = .empty;
                    defer full_line.deinit(self.allocator);
                    // Per LRM, `//` comments are not part of the macro text:
                    // strip each physical line (quote-aware) BEFORE checking
                    // for `\` continuation, or the comment poisons every
                    // expansion site (and a commented-out `\` must not join).
                    try full_line.appendSlice(self.allocator, stripLineComment(trimmed));
                    var scan = newline_pos;
                    while (blk: {
                        const s = std.mem.trimEnd(u8, full_line.slice(), " \t\r");
                        full_line.len = @intCast(s.len);
                        break :blk s.len > 0 and s[s.len - 1] == '\\';
                    }) {
                        full_line.len -= 1;
                        if (scan < source.len and source[scan] == '\n') scan += 1;
                        const cont_start = scan;
                        while (scan < source.len and source[scan] != '\n') : (scan += 1) {}
                        try full_line.appendSlice(self.allocator, stripLineComment(source[cont_start..scan]));
                    }
                    line_end = scan;
                    if (line_end < source.len and source[line_end] == '\n') line_end += 1;
                    try self.handleDefine(full_line.slice()["`define ".len..]);
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "undef ")) {
                if (self.isActive()) {
                    const name = std.mem.trim(u8, directive_text["undef ".len..], " \t\r");
                    self.removeDefine(name);
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "ifdef ") or startsWith(directive_text, "ifdef\t")) {
                const name = std.mem.trim(u8, directive_text["ifdef ".len..], " \t\r");
                const defined = self.defines.contains(name);
                const parent_active = self.isActive();
                if (self.ifdef_depth == max_ifdef_depth) return error.IfdefTooDeep;
                self.ifdef_stack[self.ifdef_depth] = .{
                    .active = parent_active and defined,
                    .seen_true = defined,
                    .parent_active = parent_active,
                };
                self.ifdef_depth += 1;
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "ifndef ") or startsWith(directive_text, "ifndef\t")) {
                const name = std.mem.trim(u8, directive_text["ifndef ".len..], " \t\r");
                const defined = self.defines.contains(name);
                const parent_active = self.isActive();
                if (self.ifdef_depth == max_ifdef_depth) return error.IfdefTooDeep;
                self.ifdef_stack[self.ifdef_depth] = .{
                    .active = parent_active and !defined,
                    .seen_true = !defined,
                    .parent_active = parent_active,
                };
                self.ifdef_depth += 1;
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "elsif ") or startsWith(directive_text, "elsif\t")) {
                if (self.ifdef_depth > 0) {
                    const name = std.mem.trim(u8, directive_text["elsif ".len..], " \t\r");
                    const defined = self.defines.contains(name);
                    const top = &self.ifdef_stack[self.ifdef_depth - 1];
                    top.active = top.parent_active and !top.seen_true and defined;
                    top.seen_true = top.seen_true or defined;
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "else")) {
                if (self.ifdef_depth > 0) {
                    const top = &self.ifdef_stack[self.ifdef_depth - 1];
                    top.active = top.parent_active and !top.seen_true;
                    top.seen_true = true;
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "endif")) {
                if (self.ifdef_depth > 0) {
                    self.ifdef_depth -= 1;
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "include ") or startsWith(directive_text, "include\t")) {
                if (self.isActive()) {
                    try self.handleInclude(directive_text["include ".len..]);
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (startsWith(directive_text, "resetall")) {
                if (self.isActive()) {
                    self.clearDefines();
                }
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            } else if (isIgnoredDirective(directive_text)) {
                try self.output.append(self.allocator, '\n');
                pos = line_end;
                continue;
            }
        }

        if (self.isActive()) {
            // Expand a CHUNK of consecutive active non-directive lines as one
            // unit so macro invocations with arg lists spanning lines work;
            // the arg scanner treats '\n' like any other whitespace char.
            var chunk_end = line_end;
            while (chunk_end < source.len) {
                var le = chunk_end;
                while (le < source.len and source[le] != '\n') : (le += 1) {}
                const t = std.mem.trimStart(u8, source[chunk_end..le], " \t");
                if (t.len > 1 and t[0] == '`' and isDirectiveText(t[1..])) break;
                chunk_end = if (le < source.len) le + 1 else le;
            }
            try self.expandAndAppend(source[line_start..chunk_end]);
            if (chunk_end == source.len and source[chunk_end - 1] != '\n')
                try self.output.append(self.allocator, '\n');
            pos = chunk_end;
        } else {
            try self.output.append(self.allocator, '\n');
            pos = line_end;
        }
    }
}

/// True when `text` (the part after a leading backtick) names a preprocessor
/// directive — chunk gathering must stop so the line dispatcher sees it.
fn isDirectiveText(text: []const u8) bool {
    var name_end: usize = 0;
    while (name_end < text.len and isIdentChar(text[name_end])) : (name_end += 1) {}
    const name = text[0..name_end];
    const directives = [_][]const u8{
        "define", "undef", "ifdef", "ifndef", "elsif", "else",
        "endif",  "include", "resetall",
    };
    for (directives) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return isIgnoredDirective(text);
}

/// Slice off a trailing `//` comment (quote-aware).
fn stripLineComment(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) {
        switch (line[i]) {
            '"' => {
                i += 1;
                while (i < line.len and line[i] != '"') {
                    i += if (line[i] == '\\' and i + 1 < line.len) @as(usize, 2) else 1;
                }
                if (i < line.len) i += 1;
            },
            '/' => {
                if (i + 1 < line.len and line[i + 1] == '/') return line[0..i];
                i += 1;
            },
            else => i += 1,
        }
    }
    return line;
}

fn isActive(self: *const Preprocessor) bool {
    if (self.ifdef_depth == 0) return true;
    return self.ifdef_stack[self.ifdef_depth - 1].active;
}

fn handleDefine(self: *Preprocessor, text: []const u8) !void {
    const trimmed = std.mem.trimStart(u8, text, " \t");
    if (trimmed.len == 0) return;

    var name_end: usize = 0;
    while (name_end < trimmed.len and (isIdentChar(trimmed[name_end]))) : (name_end += 1) {}
    if (name_end == 0) return;
    self.removeDefine(trimmed[0..name_end]);
    const name = try self.allocator.dupe(u8, trimmed[0..name_end]);

    if (name_end < trimmed.len and trimmed[name_end] == '(') {
        var paren_end = name_end + 1;
        while (paren_end < trimmed.len and trimmed[paren_end] != ')') : (paren_end += 1) {}
        if (paren_end < trimmed.len) {
            const params_str = trimmed[name_end + 1 .. paren_end];
            var params: Buf([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, params_str, ',');
            while (it.next()) |param| {
                const p = std.mem.trim(u8, param, " \t");
                if (p.len > 0) try params.append(self.allocator, try self.allocator.dupe(u8, p));
            }
            const body_start = paren_end + 1;
            const body_raw = if (body_start < trimmed.len) std.mem.trimStart(u8, trimmed[body_start..], " \t") else "";
            const body = try self.allocator.dupe(u8, body_raw);
            try self.defines.put(self.allocator, name, .{
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
            });
            return;
        }
    }

    const body_raw = if (name_end < trimmed.len) std.mem.trimStart(u8, trimmed[name_end..], " \t") else "";
    const body = try self.allocator.dupe(u8, body_raw);
    try self.defines.put(self.allocator, name, .{ .params = null, .body = body });
}

fn freeMacro(self: *Preprocessor, key: []const u8, macro: Macro) void {
    self.allocator.free(key);
    if (macro.params) |params| {
        for (params) |param| self.allocator.free(param);
        self.allocator.free(params);
    }
    self.allocator.free(macro.body);
}

fn removeDefine(self: *Preprocessor, name: []const u8) void {
    if (self.defines.fetchRemove(name)) |kv| {
        self.freeMacro(kv.key, kv.value);
    }
}

fn clearDefines(self: *Preprocessor) void {
    var it = self.defines.iterator();
    while (it.next()) |entry| {
        self.freeMacro(entry.key_ptr.*, entry.value_ptr.*);
    }
    self.defines.clearRetainingCapacity();
    self.defines.deinit(self.allocator);
    self.defines = .empty;
}

fn expandAndAppend(self: *Preprocessor, line: []const u8) PpError!void {
    var i: usize = 0;
    while (i < line.len) {
        // ponytail: bulk copy until next interesting char — avoids byte-by-byte append
        var j = i;
        while (j < line.len) {
            switch (line[j]) {
                '"', '`' => break,
                '/' => {
                    if (j + 1 < line.len and line[j + 1] == '/') break;
                    j += 1;
                },
                else => j += 1,
            }
        }
        if (j > i) {
            try self.output.appendSlice(self.allocator, line[i..j]);
            i = j;
            if (i >= line.len) return;
        }

        if (line[i] == '"') {
            const str_start = i;
            i += 1;
            while (i < line.len and line[i] != '"') {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (i < line.len) i += 1;
            try self.output.appendSlice(self.allocator, line[str_start..i]);
            continue;
        }

        if (line[i] == '/' and i + 1 < line.len and line[i + 1] == '/') {
            // Copy the comment up to end-of-line only — the chunk may hold
            // more lines that still need expansion.
            var ce = i;
            while (ce < line.len and line[ce] != '\n') : (ce += 1) {}
            try self.output.appendSlice(self.allocator, line[i..ce]);
            i = ce;
            continue;
        }

        if (line[i] == '`') {
            const name_start = i + 1;
            var name_end = name_start;
            while (name_end < line.len and isIdentChar(line[name_end])) : (name_end += 1) {}
            const name = line[name_start..name_end];

            if (self.defines.get(name)) |macro| {
                if (macro.params) |params| {
                    var arg_start = name_end;
                    while (arg_start < line.len and (line[arg_start] == ' ' or line[arg_start] == '\t')) : (arg_start += 1) {}
                    if (arg_start < line.len and line[arg_start] == '(') {
                        var args: Buf([]const u8) = .empty;
                        defer args.deinit(self.allocator);
                        const close = try self.scanArgs(line, arg_start + 1, &args);
                        const after = @min(close + 1, line.len);
                        // Keep the line count intact: newlines swallowed by a
                        // multi-line invocation are re-emitted after it.
                        const consumed_nl = std.mem.count(u8, line[i..after], "\n");
                        i = after;
                        try self.substituteAndExpand(macro.body, params, args.slice());
                        for (0..consumed_nl) |_| try self.output.append(self.allocator, '\n');
                        continue;
                    }
                }
                i = name_end;
                if (self.expand_depth >= 64) return error.MacroRecursion;
                self.expand_depth += 1;
                defer self.expand_depth -= 1;
                try self.expandAndAppend(macro.body);
                continue;
            }

            return error.UndefinedMacro;
        }

        try self.output.append(self.allocator, line[i]);
        i += 1;
    }
}

/// Scan a macro invocation's argument list starting just past the '('.
/// Paren-depth aware, string-aware (commas/parens inside quotes do not
/// split), and newline-transparent (multi-line invocations). Appends the
/// trimmed arg slices; returns the index of the closing ')' (or text.len).
fn scanArgs(self: *Preprocessor, text: []const u8, start: usize, args: *Buf([]const u8)) !usize {
    var depth: u32 = 1;
    var cur = start;
    var k = start;
    while (k < text.len) {
        switch (text[k]) {
            '"' => {
                k += 1;
                while (k < text.len and text[k] != '"') {
                    k += if (text[k] == '\\' and k + 1 < text.len) @as(usize, 2) else 1;
                }
                if (k < text.len) k += 1;
                continue;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    try args.append(self.allocator, std.mem.trim(u8, text[cur..k], " \t\r\n"));
                    return k;
                }
            },
            ',' => if (depth == 1) {
                try args.append(self.allocator, std.mem.trim(u8, text[cur..k], " \t\r\n"));
                cur = k + 1;
            },
            else => {},
        }
        k += 1;
    }
    return k;
}

/// Two-phase function-macro expansion: textually substitute params → args
/// into a scratch buffer (strings untouched), then run the normal expander
/// over the result. This makes nested macro calls in the body see fully
/// substituted argument text (`` `Inner(outer_param, …) `` works), and lets
/// macro uses inside arguments expand for free.
fn substituteAndExpand(self: *Preprocessor, body: []const u8, params: []const []const u8, args: []const []const u8) PpError!void {
    var tmp: Buf(u8) = .empty;
    defer tmp.deinit(self.allocator);
    try tmp.ensureTotalCapacity(self.allocator, body.len + body.len / 4);

    var i: usize = 0;
    while (i < body.len) {
        if (isIdentStart(body[i])) {
            var end = i;
            while (end < body.len and isIdentChar(body[end])) : (end += 1) {}
            const ident = body[i..end];

            var found = false;
            for (params, 0..) |param, idx| {
                if (std.mem.eql(u8, ident, param)) {
                    if (idx < args.len) {
                        try tmp.appendSlice(self.allocator, args[idx]);
                    }
                    found = true;
                    break;
                }
            }
            if (!found) try tmp.appendSlice(self.allocator, ident);
            i = end;
        } else if (body[i] == '"') {
            // No substitution inside string literals.
            var end = i + 1;
            while (end < body.len and body[end] != '"') {
                end += if (body[end] == '\\' and end + 1 < body.len) @as(usize, 2) else 1;
            }
            if (end < body.len) end += 1;
            try tmp.appendSlice(self.allocator, body[i..end]);
            i = end;
        } else {
            var end = i + 1;
            while (end < body.len and !isIdentStart(body[end]) and body[end] != '"') : (end += 1) {}
            try tmp.appendSlice(self.allocator, body[i..end]);
            i = end;
        }
    }

    if (self.expand_depth >= 64) return error.MacroRecursion;
    self.expand_depth += 1;
    defer self.expand_depth -= 1;
    try self.expandAndAppend(tmp.slice());
}

fn handleInclude(self: *Preprocessor, text: []const u8) PpError!void {
    if (self.include_depth > 10) {
        std.debug.print("zvaf: `include nesting deeper than 10 — cycle? ({s})\n", .{text});
        return error.IncludeNotFound;
    }

    const trimmed = std.mem.trim(u8, text, " \t\r\"<>");
    if (trimmed.len == 0) return;

    if (std.mem.eql(u8, trimmed, "constants.vams") or std.mem.eql(u8, trimmed, "constants.h")) {
        self.include_depth += 1;
        defer self.include_depth -= 1;
        try self.processSource(constants_vams);
        return;
    }
    if (std.mem.eql(u8, trimmed, "disciplines.vams") or std.mem.eql(u8, trimmed, "discipline.h") or std.mem.eql(u8, trimmed, "discipline.vams")) {
        self.include_depth += 1;
        defer self.include_depth -= 1;
        try self.processSource(disciplines_vams);
        return;
    }

    // Local include: resolve against the caller-provided include dirs.
    // Anything unresolvable is a LOUD error — a silently skipped include
    // compiles to an empty device.
    if (self.io) |io| {
        const basename = std.fs.path.basename(trimmed);
        for (self.include_dirs) |dir| {
            // Try the path as written, then its basename (flat model dirs).
            for ([_][]const u8{ trimmed, basename }) |rel| {
                const full = std.fs.path.join(self.allocator, &.{ dir, rel }) catch return error.OutOfMemory;
                defer self.allocator.free(full);
                const content = std.Io.Dir.cwd().readFileAlloc(io, full, self.allocator, .limited(64 * 1024 * 1024)) catch continue;
                defer self.allocator.free(content);
                self.include_depth += 1;
                defer self.include_depth -= 1;
                try self.processSource(content);
                return;
            }
        }
    }
    std.debug.print("zvaf: cannot resolve `include \"{s}\" (searched {d} dir(s))\n", .{ trimmed, self.include_dirs.len });
    return error.IncludeNotFound;
}

const constants_vams =
    \\// constants.vams — IEEE Std 1364 / Verilog-AMS standard constants
    \\`define P_Q         1.6021766208e-19
    \\`define P_K         1.38064852e-23
    \\`define P_EPS0      8.854187817e-12
    \\`define P_MU0       1.2566370614e-6
    \\`define P_CELSIUS0  273.15
    \\`define P_C         2.99792458e8
    \\`define P_H         6.62607004e-34
    \\`define M_E         2.7182818284590452354
    \\`define M_PI        3.14159265358979323846
    \\`define M_SQRT2     1.41421356237309504880
    \\`define M_LN2       0.693147180559945309417
    \\`define M_LN10      2.30258509299404568402
    \\`define M_LOG2E     1.44269504088896340736
    \\`define M_LOG10E    0.434294481903251827651
    \\`define M_TWO_PI    6.28318530717958647692
    \\`define M_1_PI      0.318309886183790671538
    \\`define M_SQRT1_2   0.707106781186547524401
;

const disciplines_vams =
    \\// disciplines.vams — standard discipline definitions
    \\// (nature/discipline declarations parsed by the frontend)
;

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.mem.eql(u8, haystack[0..prefix.len], prefix);
}

fn isIgnoredDirective(directive_text: []const u8) bool {
    const name_end = std.mem.indexOfAny(u8, directive_text, " \t\r") orelse directive_text.len;
    const name = directive_text[0..name_end];
    return std.mem.eql(u8, name, "default_discipline") or
        std.mem.eql(u8, name, "default_transition") or
        std.mem.eql(u8, name, "default_nettype") or
        std.mem.eql(u8, name, "begin_keywords") or
        std.mem.eql(u8, name, "end_keywords") or
        std.mem.eql(u8, name, "timescale") or
        std.mem.eql(u8, name, "pragma") or
        std.mem.eql(u8, name, "line") or
        std.mem.eql(u8, name, "unconnected_drive") or
        std.mem.eql(u8, name, "nounconnected_drive") or
        std.mem.eql(u8, name, "celldefine") or
        std.mem.eql(u8, name, "endcelldefine");
}

test "preprocessor supports elsif" {
    const source =
        \\`define USE_ALT
        \\`ifdef USE_MAIN
        \\one
        \\`elsif USE_ALT
        \\two
        \\`else
        \\three
        \\`endif
    ;
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "three") == null);
}

test "macro args: commas inside string literals do not split (P1)" {
    const source =
        \\`define MPI(nam,dsc) parameter real nam = 0 (* desc = dsc *);
        \\`MPI(noisemod, "Flag, 0=off, 1=on")
    ;
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "parameter real noisemod = 0 (* desc = \"Flag, 0=off, 1=on\" *);") != null);
}

test "macro invocation args spanning lines (P2)" {
    const source =
        \\`define PA(a, b, c) T0 = a + b + c;
        \\`PA(DMCG,
        \\    DMCI, DMDG)
        \\x = 1;
    ;
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "T0 = DMCG + DMCI + DMDG;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x = 1;") != null);
    // Line count preserved despite the invocation spanning two lines.
    try std.testing.expectEqual(std.mem.count(u8, source, "\n"), std.mem.count(u8, out, "\n") - 1);
}

test "trailing // comment stripped from define body (P3)" {
    const source =
        \\`define REFTEMP 300.15 // 27 deg C
        \\x = `REFTEMP - 273.15;
    ;
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x = 300.15 - 273.15;") != null);
}

test "multi-line define with per-line // comments (P3)" {
    const source =
        \\`define GMIN 1e-12 // comment \
        \\x = `GMIN*2;
    ;
    // The comment swallows the continuation backslash: body is just 1e-12.
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x = 1e-12*2;") != null);
}

test "nested macro call in body sees substituted outer params" {
    const source =
        \\`define INNER(p, q) p * q
        \\`define OUTER(nf, m) y = `INNER(nf, m) + nf;
        \\`OUTER(3, 4)
    ;
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "y = 3 * 4 + 3;") != null);
}

test "macro use inside argument expands" {
    const source =
        \\`define TWO 2
        \\`define SQ(x) (x)*(x)
        \\z = `SQ(`TWO);
    ;
    const out = try process(std.testing.allocator, source);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "z = (2)*(2);") != null);
}

test "self-recursive macro is a loud error, not a hang" {
    const source =
        \\`define A `B
        \\`define B `A
        \\x = `A;
    ;
    try std.testing.expectError(error.MacroRecursion, process(std.testing.allocator, source));
}

test "unresolvable local include is a loud error (P0)" {
    const source =
        \\`include "not_there.inc"
        \\module m; endmodule
    ;
    try std.testing.expectError(error.IncludeNotFound, process(std.testing.allocator, source));
}

test "preprocessor rejects undefined macro use" {
    const source =
        \\`define VALUE 1
        \\`undef VALUE
        \\x = `VALUE;
    ;
    try std.testing.expectError(error.UndefinedMacro, process(std.testing.allocator, source));
}

test "preprocessor resetall clears macros" {
    const source =
        \\`define VALUE 1
        \\`resetall
        \\x = `VALUE;
    ;
    try std.testing.expectError(error.UndefinedMacro, process(std.testing.allocator, source));
}
