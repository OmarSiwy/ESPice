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

pub fn init(allocator: Allocator) Preprocessor {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Preprocessor) void {
    self.clearDefines();
    self.output.deinit(self.allocator);
}

pub fn process(allocator: Allocator, source: []const u8) ![]const u8 {
    var pp = init(allocator);
    defer pp.deinit();
    try pp.processSource(source);
    return try pp.output.toOwnedSlice(allocator);
}

const PpError = Allocator.Error || error{ UndefinedMacro, IfdefTooDeep };

fn processSource(self: *Preprocessor, source: []const u8) PpError!void {
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
                    try full_line.appendSlice(self.allocator, trimmed);
                    var scan = newline_pos;
                    while (full_line.len > 0 and full_line.slice()[full_line.len - 1] == '\\') {
                        full_line.len -= 1;
                        if (scan < source.len and source[scan] == '\n') scan += 1;
                        const cont_start = scan;
                        while (scan < source.len and source[scan] != '\n') : (scan += 1) {}
                        try full_line.appendSlice(self.allocator, source[cont_start..scan]);
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
            try self.expandAndAppend(line);
            try self.output.append(self.allocator, '\n');
        } else {
            try self.output.append(self.allocator, '\n');
        }
        pos = line_end;
    }
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
            try self.output.appendSlice(self.allocator, line[i..]);
            return;
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
                        arg_start += 1;
                        var args: Buf([]const u8) = .empty;
                        defer args.deinit(self.allocator);
                        var depth: u32 = 1;
                        var current_start = arg_start;
                        var k = arg_start;
                        while (k < line.len and depth > 0) {
                            if (line[k] == '(') {
                                depth += 1;
                            } else if (line[k] == ')') {
                                depth -= 1;
                                if (depth == 0) {
                                    const arg = std.mem.trim(u8, line[current_start..k], " \t");
                                    try args.append(self.allocator, arg);
                                    break;
                                }
                            } else if (line[k] == ',' and depth == 1) {
                                const arg = std.mem.trim(u8, line[current_start..k], " \t");
                                try args.append(self.allocator, arg);
                                current_start = k + 1;
                            }
                            k += 1;
                        }
                        i = k + 1;
                        try self.substituteAndExpand(macro.body, params, args.slice());
                        continue;
                    }
                }
                i = name_end;
                try self.expandAndAppend(macro.body);
                continue;
            }

            return error.UndefinedMacro;
        }

        try self.output.append(self.allocator, line[i]);
        i += 1;
    }
}

fn substituteAndExpand(self: *Preprocessor, body: []const u8, params: []const []const u8, args: []const []const u8) PpError!void {
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
                        try self.output.appendSlice(self.allocator, args[idx]);
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.output.appendSlice(self.allocator, ident);
            }
            i = end;
        } else if (body[i] == '`') {
            const name_start = i + 1;
            var name_end = name_start;
            while (name_end < body.len and isIdentChar(body[name_end])) : (name_end += 1) {}
            const name = body[name_start..name_end];

            if (self.defines.get(name)) |nested| {
                if (nested.params == null) {
                    try self.expandAndAppend(nested.body);
                    i = name_end;
                    continue;
                }
                var arg_start = name_end;
                while (arg_start < body.len and (body[arg_start] == ' ' or body[arg_start] == '\t')) : (arg_start += 1) {}
                if (arg_start < body.len and body[arg_start] == '(') {
                    arg_start += 1;
                    var nested_args: Buf([]const u8) = .empty;
                    defer nested_args.deinit(self.allocator);
                    var depth: u32 = 1;
                    var current_start = arg_start;
                    var j = arg_start;
                    while (j < body.len and depth > 0) {
                        if (body[j] == '(') {
                            depth += 1;
                        } else if (body[j] == ')') {
                            depth -= 1;
                            if (depth == 0) {
                                const arg = std.mem.trim(u8, body[current_start..j], " \t");
                                try nested_args.append(self.allocator, arg);
                                break;
                            }
                        } else if (body[j] == ',' and depth == 1) {
                            const arg = std.mem.trim(u8, body[current_start..j], " \t");
                            try nested_args.append(self.allocator, arg);
                            current_start = j + 1;
                        }
                        j += 1;
                    }
                    try self.substituteAndExpand(nested.body, nested.params.?, nested_args.slice());
                    i = j + 1;
                    continue;
                }
            }
            return error.UndefinedMacro;
        } else {
            // ponytail: bulk copy non-ident, non-backtick spans
            var end = i;
            while (end < body.len and !isIdentStart(body[end]) and body[end] != '`') : (end += 1) {}
            try self.output.appendSlice(self.allocator, body[i..end]);
            i = end;
        }
    }
}

fn handleInclude(self: *Preprocessor, text: []const u8) !void {
    if (self.include_depth > 10) return;

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
    try self.output.appendSlice(self.allocator, "// [zvaf] skipped include: ");
    try self.output.appendSlice(self.allocator, trimmed);
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
