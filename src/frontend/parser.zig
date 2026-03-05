const std = @import("std");
const ir = @import("types.zig");

pub const Error = error{ OutOfMemory, ParseError, CircuitTooLarge };

/// Copy normalized bytes and count physical lines in one pass. W=1 is the
/// scalar oracle and tail; byte lanes are independent.
fn normalize(comptime W: comptime_int, dst: []u8, src: []const u8) usize {
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

/// Bump-slab wrapper over the arena: per-device slice copies (nodes,
/// positional, kv) come out of large chunks so the hot parse loop does a
/// handful of arena allocations instead of three per device.
const SlicePool = struct {
    arena: std.mem.Allocator,
    buf: []align(16) u8 = &.{},
    off: usize = 0,

    const chunk_size = 64 * 1024;

    fn dupe(self: *SlicePool, comptime T: type, src: []const T) Error![]T {
        if (src.len == 0) return &.{};
        const size = @sizeOf(T) * src.len;
        comptime std.debug.assert(@alignOf(T) <= 16);
        var off = std.mem.alignForward(usize, self.off, @alignOf(T));
        if (off + size > self.buf.len) {
            self.buf = try self.arena.alignedAlloc(u8, .@"16", @max(size, chunk_size));
            off = 0;
        }
        self.off = off + size;
        const out: []T = @alignCast(std.mem.bytesAsSlice(T, self.buf[off..self.off]));
        @memcpy(out, src);
        return out;
    }
};

pub fn Parser(comptime Tok: type) type {
    return struct {
        const Self = @This();
        arena: std.mem.Allocator,
        models: std.ArrayList(ir.Model) = .empty,
        directives: std.ArrayList(ir.Directive) = .empty,
        params: std.ArrayList(ir.Kv) = .empty,
        foreign: std.ArrayList(ir.Foreign) = .empty,
        subckts: std.ArrayList(ir.Subcircuit) = .empty,
        cur_subckt: ?u16 = null,
        sub_defaults: std.ArrayList(ir.Kv) = .empty,
        sub_devices: std.ArrayList(ir.Device) = .empty,
        nodes: std.ArrayList([]const u8) = .empty,
        positional: std.ArrayList(ir.Value) = .empty,
        kv: std.ArrayList(ir.Kv) = .empty,
        pool: SlicePool,

        pub fn parse(arena: std.mem.Allocator, src_in: []const u8) Error!ir.Ast {
            // ponytail: always lower into a fresh buffer so the original bytes
            // survive — file paths (.hdl cards) are case-sensitive and must be
            // recovered from `orig` by offset.
            const orig: []const u8 = src_in;
            var line_hint: usize = undefined;
            const src: []const u8 = blk: {
                if (Tok.case_normalize) {
                    const buf: []u8 = try arena.alloc(u8, orig.len);
                    line_hint = normalize(std.simd.suggestVectorLength(u8) orelse 1, buf, orig);
                    break :blk buf;
                }
                line_hint = std.mem.countScalar(u8, orig, '\n');
                break :blk orig;
            };

            var devices: std.ArrayList(ir.Device) = .empty;
            try devices.ensureTotalCapacity(arena, line_hint);

            var lines = Tok.Lines.init(arena, src);

            const title: []const u8 = if (Tok.has_title_line) blk: {
                const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
                const t = std.mem.trim(u8, src[0..nl], " \t\r");
                lines.rest = if (nl < src.len) src[nl + 1 ..] else "";
                break :blk t;
            } else "";

            var parser: Self = .{ .arena = arena, .pool = .{ .arena = arena } };

            while (try lines.next()) |line| {
                if (line[0] == '.') {
                    var t = Tok.Tokens.init(line);
                    const head = t.next().?.word;
                    const kind = head[1..];
                    if (try parser.parseDirective(kind, &t))
                        continue;
                    break; // .end
                }

                const dev = try parser.parseElement(line);
                if (parser.cur_subckt != null) {
                    try parser.sub_devices.append(arena, dev);
                } else {
                    try devices.append(arena, dev);
                }
            }
            if (parser.cur_subckt != null) return error.ParseError;

            // Foreign (.hdl) paths are case-sensitive; token slices point into
            // the lowered buffer. Recover the original bytes by offset.
            if (Tok.case_normalize) {
                for (parser.foreign.items) |*f| {
                    const off = @intFromPtr(f.path.ptr) - @intFromPtr(src.ptr);
                    if (off < orig.len) f.path = orig[off..][0..f.path.len];
                }
            }

            return .{
                .title = title,
                .dialect = if (Tok == @import("tokenizer.zig").hspice) .hspice else if (Tok == @import("tokenizer.zig").spectre) .spectre else .ngspice,
                .devices = devices.items,
                .subcircuits = parser.subckts.items,
                .models = parser.models.items,
                .directives = parser.directives.items,
                .params = parser.params.items,
                .foreign = parser.foreign.items,
            };
        }

        /// Returns true = continue parsing, false = hit .end
        fn parseDirective(self: *Self, kind: []const u8, t: *Tok.Tokens) Error!bool {
            const arena = self.arena;
            if (kind.len == 0) return error.ParseError;
            const kinds = std.StaticStringMap(enum { end, ends, subckt, param, pre_osdi, model, osdi_include, verilog, hdl, include }).initComptime(.{
                .{ "end", .end },           .{ "ends", .ends },       .{ "subckt", .subckt },             .{ "param", .param },
                .{ "pre_osdi", .pre_osdi }, .{ "model", .model },     .{ "osdi_include", .osdi_include }, .{ "verilog", .verilog },
                .{ "hdl", .hdl },           .{ "include", .include },
            });
            if (kinds.get(kind)) |directive| switch (directive) {
                .end => return false,
                .ends => {
                    const id = self.cur_subckt orelse return error.ParseError;
                    self.subckts.items[id].devices = self.sub_devices.items;
                    self.subckts.items[id].defaults = self.sub_defaults.items;
                    self.cur_subckt = null;
                    return true;
                },
                .subckt => {
                    if (self.cur_subckt != null) return error.ParseError;
                    const namew = t.next() orelse return error.ParseError;
                    var ports: std.ArrayList([]const u8) = .empty;
                    var defaults: std.ArrayList(ir.Kv) = .empty;
                    while (t.next()) |tk| {
                        switch (tk) {
                            .word => |w| {
                                if (std.mem.eql(u8, w, "params:")) continue;
                                var peek = t.*;
                                if (peek.next()) |nx| {
                                    if (nx == .eq) {
                                        t.* = peek;
                                        const v = try parseParamValue(arena, t);
                                        try defaults.append(arena, .{ .key = w, .value = v });
                                        continue;
                                    }
                                }
                                try ports.append(arena, w);
                            },
                            .lparen, .rparen => {},
                            else => return error.ParseError,
                        }
                    }
                    if (namew != .word) return error.ParseError;
                    if (self.subckts.items.len == std.math.maxInt(u16)) return error.CircuitTooLarge;
                    self.cur_subckt = @intCast(self.subckts.items.len);
                    try self.subckts.append(arena, .{ .name = namew.word, .ports = ports.items, .defaults = &.{}, .devices = &.{} });
                    self.sub_defaults = defaults;
                    self.sub_devices = .empty;
                    return true;
                },
                .param => {
                    while (t.next()) |tk| {
                        switch (tk) {
                            .word => |w| {
                                const nx = t.next() orelse return error.ParseError;
                                if (nx != .eq) return error.ParseError;
                                const v = try parseParamValue(arena, t);
                                if (self.cur_subckt != null)
                                    try self.sub_defaults.append(arena, .{ .key = w, .value = v })
                                else
                                    try self.params.append(arena, .{ .key = w, .value = v });
                            },
                            else => return error.ParseError,
                        }
                    }
                    return true;
                },
                .pre_osdi => {
                    try self.foreign.append(arena, .{ .kind = .pre_osdi, .path = try parsePathToken(t) });
                    return true;
                },
                .model => {
                    const name = (t.next() orelse return error.ParseError).word;
                    const mkind = (t.next() orelse return error.ParseError).word;
                    var kv: std.ArrayList(ir.Kv) = .empty;
                    while (t.next()) |tk| {
                        switch (tk) {
                            .lparen, .rparen, .comma => {},
                            .word => |w| {
                                var peek = t.*;
                                if (peek.next()) |nx| {
                                    if (nx == .eq) {
                                        t.* = peek;
                                        const v = try parseParamValue(arena, t);
                                        try kv.append(arena, .{ .key = w, .value = v });
                                        continue;
                                    }
                                }
                                const v: ir.Value = if (Tok.parseNum(w)) |n| .{ .num = n } else .{ .name = w };
                                try kv.append(arena, .{ .key = "", .value = v });
                            },
                            else => return error.ParseError,
                        }
                    }
                    try self.models.append(arena, .{ .name = name, .kind = mkind, .kv = kv.items });
                    return true;
                },
                .osdi_include => {
                    try self.foreign.append(arena, .{ .kind = .osdi_include, .path = try parsePathToken(t) });
                    return true;
                },
                .verilog => {
                    try self.foreign.append(arena, .{ .kind = .verilog, .path = try parsePathToken(t) });
                    return true;
                },
                .hdl, .include => {
                    var peek = t.*;
                    const path = try parsePathToken(&peek);
                    if (ir.foreignKindForPath(path)) |foreign_kind| {
                        t.* = peek;
                        try self.foreign.append(arena, .{ .kind = foreign_kind, .path = path });
                        return true;
                    }
                    const args = try arena.alloc(ir.Value, 1);
                    args[0] = .{ .name = path };
                    t.* = peek;
                    try self.directives.append(arena, .{ .kind = kind, .args = args });
                    return true;
                },
            };
            // ponytail: skip `=` like comma — .OPTIONS/.opt/.width use key=value
            // syntax that espice doesn't consume. Parse key and value as separate args.
            var args: std.ArrayList(ir.Value) = .empty;
            while (true) {
                var peek = t.*;
                const tk = peek.next() orelse break;
                if (tk == .comma or tk == .eq) {
                    t.* = peek;
                    continue;
                }
                try args.append(arena, try parseValueToken(arena, t));
            }
            try self.directives.append(arena, .{ .kind = kind, .args = args.items });
            return true;
        }

        fn nodeCount(letter: u8) ?usize {
            return switch (letter) {
                // W n+ n- Vctrl model: Vctrl/model are positional words (ngspice INP2W).
                'r', 'c', 'l', 'v', 'i', 'd', 'b', 'f', 'h', 'w' => 2,
                'q', 'z', 'j' => 3,
                'e', 'g', 's', 'm', 't', 'o' => 4,
                'k' => 0,
                else => null,
            };
        }

        fn parseElement(self: *Self, line: []const u8) Error!ir.Device {
            const arena = self.arena;
            self.nodes.clearRetainingCapacity();
            self.positional.clearRetainingCapacity();
            self.kv.clearRetainingCapacity();
            var t = Tok.Tokens.init(line);
            const head = t.next() orelse return error.ParseError;
            if (head != .word or head.word.len == 0 or !std.ascii.isAlphabetic(head.word[0])) return error.ParseError;
            const name = head.word;
            const letter = std.ascii.toLower(name[0]);

            var peek = t;
            if ((peek.next() orelse return error.ParseError) == .lparen) {
                t = peek;
                while (true) switch (t.next() orelse return error.ParseError) {
                    .rparen => break,
                    .word => |w| try self.nodes.append(arena, w),
                    .comma => {},
                    else => return error.ParseError,
                };
                const model = t.next() orelse return error.ParseError;
                if (model != .word) return error.ParseError;
                try self.positional.append(arena, .{ .name = model.word });
            } else if (nodeCount(letter)) |count| {
                for (0..count) |_| {
                    const token = t.next() orelse return error.ParseError;
                    if (token != .word) return error.ParseError;
                    try self.nodes.append(arena, token.word);
                }
                if (letter == 'b') {
                    const out = t.next() orelse return error.ParseError;
                    if (out != .word or (t.next() orelse return error.ParseError) != .eq) return error.ParseError;
                    peek = t;
                    const expr = switch (peek.next() orelse return error.ParseError) {
                        .braced, .quoted => |text| try parseExpr(arena, text),
                        else => try parseExpr(arena, t.rest()),
                    };
                    try self.kv.append(arena, .{ .key = out.word, .value = .{ .expr = expr } });
                    t.pos = t.line.len;
                }
            } else {
                // Variable-terminal cards end their word list with the model/subcircuit name.
                while (true) {
                    peek = t;
                    const token = peek.next() orelse break;
                    if (token != .word) break;
                    var after = peek;
                    if (after.next()) |next| if (next == .eq) break;
                    t = peek;
                    try self.nodes.append(arena, token.word);
                }
                const model = self.nodes.pop() orelse return error.ParseError;
                try self.positional.append(arena, .{ .name = model });
            }

            while (true) {
                peek = t;
                const token = peek.next() orelse break;
                if (token == .comma) {
                    t = peek;
                    continue;
                }
                if (token == .word) if (peek.next()) |next| {
                    if (next == .eq) {
                        t = peek;
                        try self.kv.append(arena, .{ .key = token.word, .value = try parseParamValue(arena, &t) });
                        continue;
                    }
                };
                try self.positional.append(arena, try parseValueToken(arena, &t));
            }
            return .{
                .name = name,
                .nodes = try self.pool.dupe([]const u8, self.nodes.items),
                .positional = try self.pool.dupe(ir.Value, self.positional.items),
                .kv = try self.pool.dupe(ir.Kv, self.kv.items),
            };
        }

        fn parseParamValue(arena: std.mem.Allocator, t: *Tok.Tokens) Error!ir.Value {
            const rest = t.rest();
            if (rest.len == 0) return error.ParseError;
            if (rest[0] == '{' or rest[0] == '\'') return parseValueToken(arena, t);
            var p: ExprP = .{ .text = t.line, .pos = t.pos, .arena = arena };
            const e = try p.parseBin(0);
            t.pos = p.pos;
            return switch (e) {
                .num => |n| .{ .num = n },
                .ident => |name| .{ .name = name },
                else => .{ .expr = try p.mk(e) },
            };
        }

        fn parseValueToken(arena: std.mem.Allocator, t: *Tok.Tokens) Error!ir.Value {
            const tk = t.next() orelse return error.ParseError;
            switch (tk) {
                .word => |w| {
                    var peek = t.*;
                    if (peek.next()) |nx| {
                        if (nx == .lparen) {
                            t.* = peek;
                            var buf: [8]ir.Value = undefined;
                            var count: usize = 0;
                            while (true) {
                                var peek2 = t.*;
                                const a = peek2.next() orelse return error.ParseError;
                                if (a == .rparen) {
                                    t.* = peek2;
                                    break;
                                }
                                if (a == .comma) {
                                    t.* = peek2;
                                    continue;
                                }
                                if (count < buf.len) {
                                    buf[count] = try parseValueToken(arena, t);
                                    count += 1;
                                } else {
                                    // Rare: >8 args in a group — fall back
                                    var overflow: std.ArrayList(ir.Value) = .empty;
                                    try overflow.appendSlice(arena, buf[0..buf.len]);
                                    try overflow.append(arena, try parseValueToken(arena, t));
                                    while (true) {
                                        var p3 = t.*;
                                        const a2 = p3.next() orelse return error.ParseError;
                                        if (a2 == .rparen) {
                                            t.* = p3;
                                            break;
                                        }
                                        if (a2 == .comma) {
                                            t.* = p3;
                                            continue;
                                        }
                                        try overflow.append(arena, try parseValueToken(arena, t));
                                    }
                                    return .{ .group = .{ .name = w, .args = overflow.items } };
                                }
                            }
                            return .{ .group = .{ .name = w, .args = try arena.dupe(ir.Value, buf[0..count]) } };
                        }
                    }
                    if (Tok.parseNum(w)) |n| return .{ .num = n };
                    return .{ .name = w };
                },
                .braced => |b| return .{ .expr = try parseExpr(arena, b) },
                .quoted => |q| return .{ .expr = try parseExpr(arena, q) },
                else => return error.ParseError,
            }
        }

        fn parsePathToken(t: *Tok.Tokens) Error![]const u8 {
            return switch (t.next() orelse return error.ParseError) {
                .word => |path| trimPathQuotes(path),
                .quoted => |path| path,
                else => error.ParseError,
            };
        }

        fn trimPathQuotes(path: []const u8) []const u8 {
            if (path.len >= 2 and
                ((path[0] == '"' and path[path.len - 1] == '"') or
                    (path[0] == '\'' and path[path.len - 1] == '\'')))
            {
                return path[1 .. path.len - 1];
            }
            return path;
        }

        fn parseExpr(arena: std.mem.Allocator, text: []const u8) Error!*const ir.Expr {
            var p = ExprP{ .text = text, .arena = arena };
            const e = try p.parseBin(0);
            if (p.peek() != null) return error.ParseError;
            return p.mk(e);
        }

        const ExprP = struct {
            text: []const u8,
            pos: usize = 0,
            arena: std.mem.Allocator,

            fn skipWs(p: *ExprP) void {
                while (p.pos < p.text.len and (p.text[p.pos] == ' ' or p.text[p.pos] == '\t')) p.pos += 1;
            }

            fn peek(p: *ExprP) ?u8 {
                p.skipWs();
                return if (p.pos < p.text.len) p.text[p.pos] else null;
            }

            fn mk(p: *ExprP, e: ir.Expr) Error!*const ir.Expr {
                const out = try p.arena.create(ir.Expr);
                out.* = e;
                return out;
            }

            fn parseBin(p: *ExprP, min_prec: u8) Error!ir.Expr {
                var lhs = try p.parseUnary();
                while (true) {
                    const c = p.peek() orelse break;
                    if (c == '?' and min_prec == 0) {
                        p.pos += 1;
                        const yes = try p.parseBin(0);
                        if (p.peek() != ':') return error.ParseError;
                        p.pos += 1;
                        const no = try p.parseBin(0);
                        const args = try p.arena.dupe(*const ir.Expr, &.{ try p.mk(lhs), try p.mk(yes), try p.mk(no) });
                        lhs = .{ .call = .{ .name = "ternary", .args = args } };
                        continue;
                    }
                    const prec: u8 = switch (c) {
                        '|' => 1,
                        '&' => 2,
                        '<', '>', '=', '!' => 3,
                        '+', '-' => 4,
                        '*', '/' => if (c == '*' and p.pos + 1 < p.text.len and p.text[p.pos + 1] == '*') 6 else 5,
                        '^' => 6,
                        else => break,
                    };
                    if (prec < min_prec) break;
                    var op = c;
                    p.pos += 1;
                    if (p.pos < p.text.len) {
                        const next = p.text[p.pos];
                        if (c == '*' and next == '*') {
                            op = '^';
                            p.pos += 1;
                        }
                        if (next == '=' and (c == '<' or c == '>' or c == '=' or c == '!')) {
                            op = switch (c) {
                                '<' => 'L',
                                '>' => 'G',
                                else => c,
                            };
                            p.pos += 1;
                        } else if (c == '=' or c == '!') return error.ParseError;
                        if (c == '&' or c == '|') {
                            if (next != c) return error.ParseError;
                            p.pos += 1;
                        }
                    }
                    const rhs = try p.parseBin(prec + 1);
                    const left = try p.mk(lhs);
                    const right = try p.mk(rhs);
                    lhs = .{ .binop = .{ .op = op, .a = left, .b = right } };
                }
                return lhs;
            }

            fn parseUnary(p: *ExprP) Error!ir.Expr {
                const c = p.peek() orelse return error.ParseError;
                if (c == '-') {
                    p.pos += 1;
                    return .{ .unop = .{ .op = '-', .a = try p.mk(try p.parseBin(6)) } };
                }
                if (c == '+') {
                    p.pos += 1;
                    return p.parseBin(6);
                }
                if (c == '!') {
                    p.pos += 1;
                    return .{ .unop = .{ .op = '!', .a = try p.mk(try p.parseUnary()) } };
                }
                return p.parseAtom();
            }

            /// A probe argument: everything up to `,` / `)` / whitespace,
            /// kept verbatim as an ident (node or device name).
            fn parseNodeArg(p: *ExprP) Error!ir.Expr {
                p.skipWs();
                const start = p.pos;
                while (p.pos < p.text.len) : (p.pos += 1) {
                    const ch = p.text[p.pos];
                    if (ch == ',' or ch == ')' or ch == ' ' or ch == '\t') break;
                }
                if (p.pos == start) return error.ParseError;
                return .{ .ident = p.text[start..p.pos] };
            }

            fn parseAtom(p: *ExprP) Error!ir.Expr {
                const c = p.peek() orelse return error.ParseError;
                if (c == '"' or c == '\'') {
                    p.pos += 1;
                    const e = try p.parseBin(0);
                    if (p.peek() != c) return error.ParseError;
                    p.pos += 1;
                    return e;
                }
                if (c == '(') {
                    p.pos += 1;
                    const e = try p.parseBin(0);
                    if (p.peek() != ')') return error.ParseError;
                    p.pos += 1;
                    return e;
                }
                if (std.ascii.isDigit(c) or c == '.') {
                    const start = p.pos;
                    while (p.pos < p.text.len) : (p.pos += 1) {
                        const ch = p.text[p.pos];
                        if (std.ascii.isDigit(ch) or ch == '.') continue;
                        if ((ch == 'e') and p.pos + 1 < p.text.len and
                            (std.ascii.isDigit(p.text[p.pos + 1]) or
                                ((p.text[p.pos + 1] == '-' or p.text[p.pos + 1] == '+') and
                                    p.pos + 2 < p.text.len and std.ascii.isDigit(p.text[p.pos + 2]))))
                        {
                            p.pos += 1;
                            if (p.text[p.pos] == '+' or p.text[p.pos] == '-') p.pos += 1;
                            continue;
                        }
                        break;
                    }
                    while (p.pos < p.text.len and std.ascii.isAlphabetic(p.text[p.pos])) p.pos += 1;
                    const n = Tok.parseNum(p.text[start..p.pos]) orelse return error.ParseError;
                    return .{ .num = n };
                }
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    const start = p.pos;
                    while (p.pos < p.text.len) : (p.pos += 1) {
                        const ch = p.text[p.pos];
                        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.')) break;
                    }
                    const ident_name = p.text[start..p.pos];
                    if (p.peek() == '(') {
                        p.pos += 1;
                        var args: std.ArrayList(*const ir.Expr) = .empty;
                        // v(a[,b]) / i(vname) name nodes and devices, not
                        // sub-expressions: "10" is the node called 10, and a
                        // node called 1n must not lex as 1e-9.  Keep the raw
                        // token as an ident so probe extraction and subckt
                        // node renaming both see the name.
                        const is_probe = ident_name.len == 1 and
                            (ident_name[0] == 'v' or ident_name[0] == 'V' or
                                ident_name[0] == 'i' or ident_name[0] == 'I');
                        if (p.peek() != ')') {
                            while (true) {
                                try args.append(p.arena, try p.mk(if (is_probe)
                                    try p.parseNodeArg()
                                else
                                    try p.parseBin(0)));
                                const nx = p.peek() orelse return error.ParseError;
                                if (nx == ',') {
                                    p.pos += 1;
                                    continue;
                                }
                                break;
                            }
                        }
                        if (p.peek() != ')') return error.ParseError;
                        p.pos += 1;
                        return .{ .call = .{ .name = ident_name, .args = args.items } };
                    }
                    return .{ .ident = ident_name };
                }
                return error.ParseError;
            }
        };
    };
}

// Private implementation access for the frontend test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .normalize = normalize,
} else {};
