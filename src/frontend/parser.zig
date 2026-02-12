const std = @import("std");
const ir = @import("types.zig");

pub const Error = error{ OutOfMemory, ParseError, ModelBinNotFound };

/// Copy and lower in the same pass: `dst` is written once, not memcpy'd and
/// then rewritten. std.ascii.allocLowerString is the stdlib equivalent but its
/// scalar loop measured +7.6% parse Ir on a 4.2 MB deck, so the vector stays.
fn simdLower(dst: []u8, src: []const u8) void {
    const W = 32;
    const V = @Vector(W, u8);
    const a_vec: V = @splat('A');
    const z_vec: V = @splat('Z');
    const bit: V = @splat(0x20);
    const zero: V = @splat(0);
    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: V = src[i..][0..W].*;
        const is_upper = (v >= a_vec) & (v <= z_vec);
        dst[i..][0..W].* = v | @select(u8, is_upper, bit, zero);
    }
    for (src[i..], dst[i..]) |c, *o| o.* = std.ascii.toLower(c);
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
        pub fn parse(arena: std.mem.Allocator, src_in: anytype) Error!ir.Netlist {
            // ponytail: always lower into a fresh buffer so the original bytes
            // survive — file paths (.hdl cards) are case-sensitive and must be
            // recovered from `orig` by offset.
            const orig: []const u8 = src_in;
            const src: []const u8 = blk: {
                if (Tok.case_normalize) {
                    const buf: []u8 = try arena.alloc(u8, orig.len);
                    simdLower(buf, orig);
                    break :blk buf;
                }
                break :blk orig;
            };

            // ponytail: stdlib countScalar already supplies the vector scan and tail.
            const line_hint = std.mem.countScalar(u8, src, '\n');
            var devices: std.ArrayList(ir.Device) = .empty;
            try devices.ensureTotalCapacity(arena, line_hint);
            var models: std.ArrayList(ir.Model) = .empty;
            var directives: std.ArrayList(ir.Directive) = .empty;
            var params: std.ArrayList(ir.Kv) = .empty;
            var foreign: std.ArrayList(ir.Foreign) = .empty;
            var subckts: std.StringHashMapUnmanaged(Subckt) = .empty;

            var lines = Tok.Lines.init(arena, src);

            const title: []const u8 = if (Tok.has_title_line) blk: {
                const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
                const t = std.mem.trim(u8, src[0..nl], " \t\r");
                lines.rest = if (nl < src.len) src[nl + 1 ..] else "";
                break :blk t;
            } else "";

            var cur_subckt: ?*Subckt = null;
            var sub_devices: std.ArrayList(ir.Device) = .empty;
            var pool: SlicePool = .{ .arena = arena };

            while (try lines.next()) |line| {
                if (line[0] == '.') {
                    var t = Tok.Tokens.init(line);
                    const head = t.next().?.word;
                    const kind = head[1..];
                    if (try parseDirective(arena, kind, &t, &models, &directives, &params, &foreign, &subckts, &cur_subckt, &sub_devices))
                        continue;
                    break; // .end
                }

                const dev = try parseElement(arena, &pool, line);
                if (cur_subckt != null) {
                    try sub_devices.append(arena, dev);
                } else {
                    try devices.append(arena, dev);
                }
            }
            if (cur_subckt != null) return error.ParseError;

            var subckt_type_map: std.StringHashMapUnmanaged(u16) = .empty;
            var subckt_iter = subckts.iterator();
            while (subckt_iter.next()) |entry| {
                const sname = entry.key_ptr.*;
                const sub = entry.value_ptr.*;
                // Preserve checked count limits formerly enforced by unused metadata.
                _ = @as(u16, @intCast(sub.ports.len));
                // Count unique internal node names (not ports, not ground).
                var n_internal: u16 = 0;
                var seen_nodes: std.StringHashMapUnmanaged(void) = .empty;
                for (sub.devices) |sd| {
                    for (sd.nodes) |node| {
                        if (portLookup(sub.ports, sub.ports, node) != null) continue;
                        if (node.len <= 3 and (std.mem.eql(u8, node, "0") or std.mem.eql(u8, node, "gnd"))) continue;
                        if (seen_nodes.get(node) == null) {
                            try seen_nodes.put(arena, node, {});
                            n_internal += 1;
                        }
                    }
                }
                const type_id: u16 = @intCast(subckt_type_map.size + 1); // 0 = top-level
                _ = @as(u16, @intCast(countExpanded(sub.devices, &subckts, 1)));
                try subckt_type_map.put(arena, sname, type_id);
            }

            const expanded_hint = countExpanded(devices.items, &subckts, 0);
            var flat: std.ArrayList(ir.Device) = .empty;
            try flat.ensureTotalCapacity(arena, expanded_hint);
            // Global parameters are shared; subcircuit scopes hold only local overrides.
            var genv: Env = .empty;
            for (params.items) |kvp| try genv.put(arena, kvp.key, kvp.value);
            for (models.items) |model| {
                for (@constCast(model.kv)) |*kv| kv.value = try substValue(arena, kv.value, &.{genv}, true);
            }
            for (directives.items) |dir| for (@constCast(dir.args)) |*arg| {
                if (arg.* == .expr) arg.* = try substValue(arena, arg.*, &.{genv}, false);
            };
            var instance_counter: u32 = 1; // 0 = top-level
            for (devices.items) |d| {
                const td = if (genv.size > 0) try substDevice(arena, d, &.{genv}) else d;
                try expandInto(arena, &flat, td, &subckts, 0, 0, 0, &subckt_type_map, &instance_counter, &.{genv});
            }
            try resolveModelBins(arena, flat.items, models.items, directives.items);

            const dl = try ir.DeviceList.fromUnsorted(arena, flat.items);

            // Foreign (.hdl) paths are case-sensitive; token slices point into
            // the lowered buffer. Recover the original bytes by offset.
            if (Tok.case_normalize) {
                for (foreign.items) |*f| {
                    const off = @intFromPtr(f.path.ptr) - @intFromPtr(src.ptr);
                    if (off < orig.len) f.path = orig[off..][0..f.path.len];
                }
            }

            return .{
                .title = title,
                .devices = dl,
                .models = models.items,
                .directives = directives.items,
                .params = params.items,
                .foreign = foreign.items,
            };
        }

        /// Returns true = continue parsing, false = hit .end
        fn parseDirective(
            arena: std.mem.Allocator,
            kind: []const u8,
            t: *Tok.Tokens,
            models: *std.ArrayList(ir.Model),
            directives: *std.ArrayList(ir.Directive),
            params: *std.ArrayList(ir.Kv),
            foreign: *std.ArrayList(ir.Foreign),
            subckts: *std.StringHashMapUnmanaged(Subckt),
            cur_subckt: *?*Subckt,
            sub_devices: *std.ArrayList(ir.Device),
        ) Error!bool {
            if (kind.len == 0) return error.ParseError;
            switch (kind[0]) {
                'e' => {
                    if (std.mem.eql(u8, kind, "end")) return false;
                    if (std.mem.eql(u8, kind, "ends")) {
                        const s = cur_subckt.* orelse return error.ParseError;
                        s.devices = sub_devices.items;
                        cur_subckt.* = null;
                        return true;
                    }
                },
                's' => {
                    if (std.mem.eql(u8, kind, "subckt")) {
                        if (cur_subckt.* != null) return error.ParseError;
                        var s = Subckt{ .ports = undefined, .defaults = undefined, .devices = &.{} };
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
                        s.ports = ports.items;
                        s.defaults = defaults;
                        const gop = try subckts.getOrPut(arena, namew.word);
                        gop.value_ptr.* = s;
                        cur_subckt.* = gop.value_ptr;
                        sub_devices.* = .empty;
                        return true;
                    }
                },
                'p' => {
                    if (std.mem.eql(u8, kind, "param")) {
                        while (t.next()) |tk| {
                            switch (tk) {
                                .word => |w| {
                                    const nx = t.next() orelse return error.ParseError;
                                    if (nx != .eq) return error.ParseError;
                                    const v = try parseParamValue(arena, t);
                                    if (cur_subckt.*) |s|
                                        try s.defaults.append(arena, .{ .key = w, .value = v })
                                    else
                                        try params.append(arena, .{ .key = w, .value = v });
                                },
                                else => return error.ParseError,
                            }
                        }
                        return true;
                    }
                    if (std.mem.eql(u8, kind, "pre_osdi")) {
                        try foreign.append(arena, .{ .kind = .pre_osdi, .path = try parsePathToken(t) });
                        return true;
                    }
                },
                'm' => {
                    if (std.mem.eql(u8, kind, "model")) {
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
                        try models.append(arena, .{ .name = name, .kind = mkind, .kv = kv.items });
                        return true;
                    }
                },
                'o' => {
                    if (std.mem.eql(u8, kind, "osdi_include")) {
                        try foreign.append(arena, .{ .kind = .osdi_include, .path = try parsePathToken(t) });
                        return true;
                    }
                },
                'v' => {
                    if (std.mem.eql(u8, kind, "verilog")) {
                        try foreign.append(arena, .{ .kind = .verilog, .path = try parsePathToken(t) });
                        return true;
                    }
                },
                else => {},
            }
            // .hdl / .include: check for foreign (VA/Verilog) or fall through to generic directive
            if (std.mem.eql(u8, kind, "hdl") or std.mem.eql(u8, kind, "include")) {
                var peek = t.*;
                const path = try parsePathToken(&peek);
                if (ir.foreignKindForPath(path)) |foreign_kind| {
                    t.* = peek;
                    try foreign.append(arena, .{ .kind = foreign_kind, .path = path });
                    return true;
                }
                const args = try arena.alloc(ir.Value, 1);
                args[0] = .{ .name = path };
                t.* = peek;
                try directives.append(arena, .{ .kind = kind, .args = args });
                return true;
            }
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
            try directives.append(arena, .{ .kind = kind, .args = args.items });
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

        fn parseElement(arena: std.mem.Allocator, pool: *SlicePool, line: []const u8) Error!ir.Device {
            var t = Tok.Tokens.init(line);
            const name = (t.next() orelse return error.ParseError).word;
            if (name.len == 0) return error.ParseError;
            const letter = std.ascii.toLower(name[0]);

            // Stack buffers for the common path (avoids per-device heap alloc)
            var node_buf: [8][]const u8 = undefined;
            var node_count: usize = 0;
            var pos_buf: [4]ir.Value = undefined;
            var pos_count: usize = 0;
            var kv_buf: [16]ir.Kv = undefined;
            var kv_count: usize = 0;
            // Overflow lists for rare large devices
            var nodes_overflow: std.ArrayList([]const u8) = .empty;
            var pos_overflow: std.ArrayList(ir.Value) = .empty;
            var kv_overflow: std.ArrayList(ir.Kv) = .empty;

            // Spectre-style parenthesized nodes: R0 (a b) resistor r=1k
            var peek_paren = t;
            if ((peek_paren.next() orelse return error.ParseError) == .lparen) {
                t = peek_paren;
                while (true) {
                    const tk = t.next() orelse return error.ParseError;
                    switch (tk) {
                        .rparen => break,
                        .word => |w| {
                            if (node_count < node_buf.len) {
                                node_buf[node_count] = w;
                                node_count += 1;
                            } else {
                                if (nodes_overflow.items.len == 0) {
                                    try nodes_overflow.appendSlice(arena, node_buf[0..node_buf.len]);
                                }
                                try nodes_overflow.append(arena, w);
                            }
                        },
                        .comma => {},
                        else => return error.ParseError,
                    }
                }
                const dt = t.next() orelse return error.ParseError;
                if (dt == .word) {
                    pos_buf[0] = .{ .name = dt.word };
                    pos_count = 1;
                }
            } else if (nodeCount(letter)) |nn| {
                for (0..nn) |i| {
                    const tk = t.next() orelse return error.ParseError;
                    if (tk != .word) return error.ParseError;
                    node_buf[i] = tk.word;
                }
                node_count = nn;
                if (letter == 'b') {
                    const out = (t.next() orelse return error.ParseError).word;
                    const eq = t.next() orelse return error.ParseError;
                    if (eq != .eq) return error.ParseError;
                    var peek = t;
                    const e = switch (peek.next() orelse return error.ParseError) {
                        .braced => |b| try parseExpr(arena, b),
                        .quoted => |q| try parseExpr(arena, q),
                        else => try parseExpr(arena, t.rest()),
                    };
                    kv_buf[0] = .{ .key = out, .value = .{ .expr = e } };
                    kv_count = 1;
                    return .{
                        .name = name,
                        .nodes = try pool.dupe([]const u8, node_buf[0..node_count]),
                        .positional = try pool.dupe(ir.Value, pos_buf[0..pos_count]),
                        .kv = try pool.dupe(ir.Kv, kv_buf[0..kv_count]),
                    };
                }
            } else {
                // Unknown node count: collect words until we hit kv or end
                var word_buf: [32][]const u8 = undefined;
                var word_count: usize = 0;
                while (true) {
                    var peek = t;
                    const tk = peek.next() orelse break;
                    if (tk != .word) break;
                    var peek2 = peek;
                    if (peek2.next()) |nx| {
                        if (nx == .eq) break;
                    }
                    t = peek;
                    if (word_count < word_buf.len) {
                        word_buf[word_count] = tk.word;
                        word_count += 1;
                    } else {
                        if (nodes_overflow.items.len == 0) {
                            try nodes_overflow.appendSlice(arena, word_buf[0..word_buf.len]);
                        }
                        try nodes_overflow.append(arena, tk.word);
                    }
                }
                const total = if (nodes_overflow.items.len > 0) nodes_overflow.items.len else word_count;
                if (total < 1) return error.ParseError;
                // Last word is the device/subckt name; the rest are nodes.
                const words = if (nodes_overflow.items.len > 0) nodes_overflow.items else word_buf[0..word_count];
                pos_buf[0] = .{ .name = words[total - 1] };
                pos_count = 1;
                if (total - 1 <= node_buf.len) {
                    @memcpy(node_buf[0 .. total - 1], words[0 .. total - 1]);
                    node_count = total - 1;
                    nodes_overflow.clearRetainingCapacity();
                } else if (nodes_overflow.items.len > 0) {
                    nodes_overflow.shrinkRetainingCapacity(total - 1);
                } else {
                    try nodes_overflow.appendSlice(arena, word_buf[0 .. total - 1]);
                }
            }

            while (true) {
                var peek = t;
                const tk = peek.next() orelse break;
                switch (tk) {
                    .comma => {
                        t = peek;
                        continue;
                    },
                    .word => |w| {
                        var peek2 = peek;
                        if (peek2.next()) |nx| {
                            if (nx == .eq) {
                                t = peek2;
                                const v = try parseParamValue(arena, &t);
                                if (kv_count < kv_buf.len) {
                                    kv_buf[kv_count] = .{ .key = w, .value = v };
                                    kv_count += 1;
                                } else {
                                    if (kv_overflow.items.len == 0)
                                        try kv_overflow.appendSlice(arena, kv_buf[0..kv_buf.len]);
                                    try kv_overflow.append(arena, .{ .key = w, .value = v });
                                }
                                continue;
                            }
                        }
                    },
                    else => {},
                }
                const v = try parseValueToken(arena, &t);
                if (pos_count < pos_buf.len) {
                    pos_buf[pos_count] = v;
                    pos_count += 1;
                } else {
                    if (pos_overflow.items.len == 0)
                        try pos_overflow.appendSlice(arena, pos_buf[0..pos_buf.len]);
                    try pos_overflow.append(arena, v);
                }
            }

            const nodes_slice = if (nodes_overflow.items.len > 0)
                nodes_overflow.items
            else
                try pool.dupe([]const u8, node_buf[0..node_count]);
            const pos_slice = if (pos_overflow.items.len > 0)
                pos_overflow.items
            else
                try pool.dupe(ir.Value, pos_buf[0..pos_count]);
            const kv_slice = if (kv_overflow.items.len > 0)
                kv_overflow.items
            else
                try pool.dupe(ir.Kv, kv_buf[0..kv_count]);

            return .{ .name = name, .nodes = nodes_slice, .positional = pos_slice, .kv = kv_slice };
        }

        fn parseParamValue(arena: std.mem.Allocator, t: *Tok.Tokens) Error!ir.Value {
            const rest = t.rest();
            if (rest.len == 0) return error.ParseError;
            if (rest[0] == '{' or rest[0] == '\'') return parseValueToken(arena, t);
            var p: ExprP = .{ .text = t.line, .pos = t.pos, .arena = arena };
            const e = try p.parseBin(0);
            t.pos = p.pos;
            return if (foldExpr(e, false)) |n| .{ .num = n } else if (e.* == .ident) .{ .name = e.ident } else .{ .expr = e };
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
            return e;
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

            fn parseBin(p: *ExprP, min_prec: u8) Error!*const ir.Expr {
                var lhs = try p.parseUnary();
                while (true) {
                    const c = p.peek() orelse break;
                    if (c == '?' and min_prec == 0) {
                        p.pos += 1;
                        const yes = try p.parseBin(0);
                        if (p.peek() != ':') return error.ParseError;
                        p.pos += 1;
                        const no = try p.parseBin(0);
                        const args = try p.arena.dupe(*const ir.Expr, &.{ lhs, yes, no });
                        lhs = try p.mk(.{ .call = .{ .name = "ternary", .args = args } });
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
                    lhs = try p.mk(.{ .binop = .{ .op = op, .a = lhs, .b = rhs } });
                }
                return lhs;
            }

            fn parseUnary(p: *ExprP) Error!*const ir.Expr {
                const c = p.peek() orelse return error.ParseError;
                if (c == '-') {
                    p.pos += 1;
                    return p.mk(.{ .unop = .{ .op = '-', .a = try p.parseBin(6) } });
                }
                if (c == '+') {
                    p.pos += 1;
                    return p.parseBin(6);
                }
                if (c == '!') {
                    p.pos += 1;
                    return p.mk(.{ .unop = .{ .op = '!', .a = try p.parseUnary() } });
                }
                return p.parseAtom();
            }

            /// A probe argument: everything up to `,` / `)` / whitespace,
            /// kept verbatim as an ident (node or device name).
            fn parseNodeArg(p: *ExprP) Error!*const ir.Expr {
                p.skipWs();
                const start = p.pos;
                while (p.pos < p.text.len) : (p.pos += 1) {
                    const ch = p.text[p.pos];
                    if (ch == ',' or ch == ')' or ch == ' ' or ch == '\t') break;
                }
                if (p.pos == start) return error.ParseError;
                return p.mk(.{ .ident = p.text[start..p.pos] });
            }

            fn parseAtom(p: *ExprP) Error!*const ir.Expr {
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
                    return p.mk(.{ .num = n });
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
                                try args.append(p.arena, if (is_probe)
                                    try p.parseNodeArg()
                                else
                                    try p.parseBin(0));
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
                        return p.mk(.{ .call = .{ .name = ident_name, .args = args.items } });
                    }
                    return p.mk(.{ .ident = ident_name });
                }
                return error.ParseError;
            }
        };

        const Subckt = struct {
            ports: []const []const u8,
            defaults: std.ArrayList(ir.Kv),
            devices: []const ir.Device,
        };

        const Env = std.StringHashMapUnmanaged(ir.Value);

        fn number(kv: []const ir.Kv, key: []const u8) ?f64 {
            for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
                .num => |n| n,
                else => null,
            };
            return null;
        }

        fn resolveModelBins(arena: std.mem.Allocator, devs: []ir.Device, models: []const ir.Model, dirs: []const ir.Directive) Error!void {
            var scale: f64 = 1;
            var wnflag = Tok == @import("tokenizer.zig").hspice or Tok == @import("tokenizer.zig").spectre;
            const option_names = std.StaticStringMap(void).initComptime(.{
                .{ "option", {} }, .{ "options", {} }, .{ "opt", {} }, .{ "opts", {} },
            });
            for (dirs) |dir| {
                if (!option_names.has(dir.kind)) continue;
                for (dir.args, 0..) |arg, i| {
                    if (arg != .name) continue;
                    const is_scale = std.mem.eql(u8, arg.name, "scale");
                    const is_wnflag = std.mem.eql(u8, arg.name, "wnflag");
                    if (!is_scale and !is_wnflag) continue;
                    if (i + 1 == dir.args.len or dir.args[i + 1] != .num) return error.ParseError;
                    const value = dir.args[i + 1].num;
                    if (is_scale) scale = value;
                    if (is_wnflag) wnflag = value != 0;
                }
            }
            if (!(scale > 0) or !std.math.isFinite(scale)) return error.ParseError;
            var names: std.StringHashMapUnmanaged(u32) = .empty;
            const none = std.math.maxInt(u32);
            const next = try arena.alloc(u32, models.len);
            @memset(next, none);
            const bounds = try arena.alloc([4]f64, models.len);
            // ngspice prepends model cards: the last matching bin wins at shared bounds.
            for (models, 0..) |model, i| try names.put(arena, model.name, @intCast(i));
            for (models, 0..) |model, mi| {
                const dot = std.mem.lastIndexOfScalar(u8, model.name, '.') orelse continue;
                _ = std.fmt.parseInt(u32, model.name[dot + 1 ..], 10) catch continue;
                bounds[mi] = .{
                    number(model.kv, "lmin") orelse continue, number(model.kv, "lmax") orelse continue,
                    number(model.kv, "wmin") orelse continue, number(model.kv, "wmax") orelse continue,
                };
                const entry = try names.getOrPut(arena, model.name[0..dot]);
                if (entry.found_existing) {
                    if (std.mem.eql(u8, models[entry.value_ptr.*].name, model.name[0..dot])) continue;
                    next[mi] = entry.value_ptr.*;
                }
                entry.value_ptr.* = @intCast(mi);
            }
            const lengths = std.StaticStringMap(u2).initComptime(.{
                .{ "l", 1 },  .{ "w", 1 },  .{ "pd", 1 }, .{ "ps", 1 }, .{ "sa", 1 }, .{ "sb", 1 }, .{ "sd", 1 },
                .{ "ad", 2 }, .{ "as", 2 },
            });
            for (devs) |dev| {
                if (dev.letter() != 'm') continue;
                for (@constCast(dev.kv)) |*kv| {
                    const power = lengths.get(kv.key) orelse continue;
                    if (kv.value != .num) return error.ParseError;
                    kv.value.num *= if (power == 2) scale * scale else scale;
                }
                if (dev.positional.len == 0 or dev.positional[0] != .name) continue;
                const name = dev.positional[0].name;
                var bin = names.get(name) orelse continue;
                if (std.mem.eql(u8, name, models[bin].name)) continue;
                const l = number(dev.kv, "l") orelse return error.ParseError;
                const use_nf = if (number(dev.kv, "wnflag")) |flag| flag != 0 else wnflag;
                const nf = if (use_nf) number(dev.kv, "nf") orelse 1 else 1;
                const w = (number(dev.kv, "w") orelse return error.ParseError) / nf;
                while (bin != none) : (bin = next[bin]) {
                    const b = bounds[bin];
                    // ngspice INPgetModBin includes endpoints within 1 nm.
                    if ((@abs(l - b[0]) < 1e-9 or @abs(l - b[1]) < 1e-9 or (l > b[0] and l < b[1])) and
                        (@abs(w - b[2]) < 1e-9 or @abs(w - b[3]) < 1e-9 or (w > b[2] and w < b[3])))
                    {
                        @constCast(dev.positional)[0] = .{ .name = models[bin].name };
                        break;
                    }
                }
                if (bin == none) return error.ModelBinNotFound;
            }
        }

        fn portLookup(ports: []const []const u8, mappings: []const []const u8, needle: []const u8) ?[]const u8 {
            for (ports, mappings) |p, m| {
                if (std.mem.eql(u8, needle, p)) return m;
            }
            return null;
        }

        /// One subckt-expansion node rename: port -> parent node, ground
        /// stays, anything else becomes `<instance>.<node>`.
        fn mapNode(arena: std.mem.Allocator, ports: []const []const u8, mappings: []const []const u8, iname: []const u8, n: []const u8) Error![]const u8 {
            // ponytail: linear scan beats HashMap for typical port counts (2-8)
            if (portLookup(ports, mappings, n)) |mapped| return mapped;
            if (n.len <= 3 and (std.mem.eql(u8, n, "0") or std.mem.eql(u8, n, "gnd"))) return n;
            // ponytail: stdlib concatenation keeps one exact-size arena allocation.
            return std.mem.concat(arena, u8, &.{ iname, ".", n });
        }

        /// Clone `e` with the args of every V() probe renamed via mapNode.
        /// I() probe args name devices, whose <device>.<instance> rename
        /// happens on the device card itself; leave them alone.
        fn mapProbeNodes(arena: std.mem.Allocator, e: *const ir.Expr, ports: []const []const u8, mappings: []const []const u8, iname: []const u8) Error!*const ir.Expr {
            switch (e.*) {
                .num, .ident => return e,
                .call => |c| {
                    const is_v = c.name.len == 1 and (c.name[0] == 'v' or c.name[0] == 'V');
                    const args = try arena.alloc(*const ir.Expr, c.args.len);
                    for (c.args, args) |a, *o| {
                        if (is_v and a.* == .ident) {
                            const out = try arena.create(ir.Expr);
                            out.* = .{ .ident = try mapNode(arena, ports, mappings, iname, a.ident) };
                            o.* = out;
                        } else {
                            o.* = try mapProbeNodes(arena, a, ports, mappings, iname);
                        }
                    }
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .call = .{ .name = c.name, .args = args } };
                    return out;
                },
                .unop => |u| {
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .unop = .{ .op = u.op, .a = try mapProbeNodes(arena, u.a, ports, mappings, iname) } };
                    return out;
                },
                .binop => |b| {
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .binop = .{
                        .op = b.op,
                        .a = try mapProbeNodes(arena, b.a, ports, mappings, iname),
                        .b = try mapProbeNodes(arena, b.b, ports, mappings, iname),
                    } };
                    return out;
                },
            }
        }

        fn countExpanded(devices: []const ir.Device, subckts: *const std.StringHashMapUnmanaged(Subckt), depth: usize) usize {
            if (depth > 32) return 0;
            var count: usize = 0;
            for (devices) |d| {
                if (d.letter() != 'x') {
                    count += 1;
                    continue;
                }
                if (d.positional.len < 1) {
                    count += 1;
                    continue;
                }
                const sname = switch (d.positional[d.positional.len - 1]) {
                    .name => |nm| nm,
                    else => {
                        count += 1;
                        continue;
                    },
                };
                if (subckts.get(sname)) |sub| {
                    count += countExpanded(sub.devices, subckts, depth + 1);
                } else {
                    count += 1;
                }
            }
            return count;
        }

        fn expandInto(
            arena: std.mem.Allocator,
            out: *std.ArrayList(ir.Device),
            d: ir.Device,
            subckts: *const std.StringHashMapUnmanaged(Subckt),
            depth: usize,
            subckt_type_id: u16,
            instance_id: u32,
            type_map: *const std.StringHashMapUnmanaged(u16),
            instance_counter: *u32,
            genv: []const Env,
        ) Error!void {
            if (d.letter() != 'x') {
                var tagged = d;
                tagged.subckt_type = subckt_type_id;
                tagged.subckt_instance = instance_id;
                try out.append(arena, tagged);
                return;
            }
            if (depth > 32) return error.ParseError;
            if (d.positional.len < 1) return error.ParseError;
            const sname = switch (d.positional[d.positional.len - 1]) {
                .name => |nm| nm,
                else => return error.ParseError,
            };
            const sub = subckts.get(sname) orelse return error.ParseError;
            if (d.nodes.len != sub.ports.len) return error.ParseError;

            const this_type = type_map.get(sname) orelse 0;
            const this_instance = instance_counter.*;
            instance_counter.* += 1;

            // Shadow order: instance kv > subckt defaults > global .param.
            var env: Env = .empty;
            for (sub.defaults.items) |kvp| try env.put(arena, kvp.key, kvp.value);
            for (d.kv) |kvp| try env.put(arena, kvp.key, kvp.value);

            var scopes: [34]Env = undefined;
            @memcpy(scopes[0..genv.len], genv);
            scopes[genv.len] = env;
            const nested = scopes[0 .. genv.len + 1];
            for (sub.devices) |sd| {
                var nd = try substDevice(arena, sd, nested);
                nd.name = try std.mem.concat(arena, u8, &.{ sd.name, ".", d.name });
                const dev_nodes = try arena.alloc([]const u8, sd.nodes.len);
                for (sd.nodes, dev_nodes) |n, *o| {
                    o.* = try mapNode(arena, sub.ports, d.nodes, d.name, n);
                }
                nd.nodes = dev_nodes;
                // V(node) probes inside behavioral expressions name subckt
                // nodes too; rename them with the same map the device nodes
                // just went through.
                for (nd.kv) |kvp| {
                    if (kvp.value != .expr) continue;
                    const kv2 = try arena.alloc(ir.Kv, nd.kv.len);
                    for (nd.kv, kv2) |src_kv, *o| {
                        o.* = src_kv;
                        if (src_kv.value == .expr)
                            o.value = .{ .expr = try mapProbeNodes(arena, src_kv.value.expr, sub.ports, d.nodes, d.name) };
                    }
                    nd.kv = kv2;
                    break;
                }
                try expandInto(arena, out, nd, subckts, depth + 1, this_type, this_instance, type_map, instance_counter, nested);
            }
        }

        const math_calls = std.StaticStringMap(enum(u8) { sqrt, abs, min, max, pow, exp, ln, log, log10, sin, cos, tan, atan, floor, ceil, ternary }).initComptime(.{
            .{ "sqrt", .sqrt },       .{ "abs", .abs }, .{ "min", .min },   .{ "max", .max },     .{ "pow", .pow },
            .{ "exp", .exp },         .{ "ln", .ln },   .{ "log", .log },   .{ "log10", .log10 }, .{ "sin", .sin },
            .{ "cos", .cos },         .{ "tan", .tan }, .{ "atan", .atan }, .{ "floor", .floor }, .{ "ceil", .ceil },
            .{ "ternary", .ternary },
        });

        // Only declared model geometry and valid stochastic calls may disappear
        // behind a zero nominal-corner switch. Unknown symbols remain errors downstream.
        fn nominalFactor(e: *const ir.Expr, geometry: bool) bool {
            if (foldExpr(e, false)) |n| return std.math.isFinite(n);
            return switch (e.*) {
                .num => false,
                .ident => |name| geometry and std.StaticStringMap(void).initComptime(.{
                    .{ "l", {} }, .{ "w", {} }, .{ "mult", {} },
                }).has(name),
                .call => |c| blk: {
                    const random = std.mem.eql(u8, c.name, "agauss") or std.mem.eql(u8, c.name, "gauss");
                    if (random) {
                        if (c.args.len != 3) break :blk false;
                        for (c.args) |arg| if (foldExpr(arg, false) == null) break :blk false;
                    } else if (!math_calls.has(c.name)) break :blk false;
                    for (c.args) |arg| if (!nominalFactor(arg, geometry)) break :blk false;
                    break :blk true;
                },
                .unop => |u| nominalFactor(u.a, geometry),
                .binop => |b| nominalFactor(b.a, geometry) and nominalFactor(b.b, geometry),
            };
        }

        /// Constant expressions and disabled symbolic terms; unresolved probes remain expressions.
        fn foldExpr(e: *const ir.Expr, model_geometry: bool) ?f64 {
            return switch (e.*) {
                .num => |n| n,
                .ident => null,
                .call => |c| blk: {
                    const kind = math_calls.get(c.name) orelse break :blk null;
                    const arity: usize = switch (kind) {
                        .ternary => 3,
                        .pow, .min, .max => 2,
                        else => 1,
                    };
                    if (c.args.len != arity) break :blk null;
                    const a = foldExpr(c.args[0], model_geometry) orelse break :blk null;
                    if (kind == .ternary) break :blk foldExpr(c.args[if (a != 0) @as(usize, 1) else 2], model_geometry);
                    const b = if (arity == 2) foldExpr(c.args[1], model_geometry) orelse break :blk null else 0;
                    break :blk switch (kind) {
                        .sqrt => @sqrt(a),
                        .abs => @abs(a),
                        .min => @min(a, b),
                        .max => @max(a, b),
                        .pow => std.math.pow(f64, a, b),
                        .exp => @exp(a),
                        .ln, .log => @log(a),
                        .log10 => @log10(a),
                        .sin => @sin(a),
                        .cos => @cos(a),
                        .tan => @tan(a),
                        .atan => std.math.atan(a),
                        .floor => @floor(a),
                        .ceil => @ceil(a),
                        .ternary => unreachable,
                    };
                },
                .unop => |u| switch (u.op) {
                    '-' => if (foldExpr(u.a, model_geometry)) |a| -a else null,
                    '+' => foldExpr(u.a, model_geometry),
                    '!' => if (foldExpr(u.a, model_geometry)) |a| @floatFromInt(@intFromBool(a == 0)) else null,
                    else => null,
                },
                .binop => |b| blk: {
                    const lhs = foldExpr(b.a, model_geometry);
                    const rhs = foldExpr(b.b, model_geometry);
                    // Nominal PDK corners disable stochastic/geometry terms with a zero switch.
                    if (b.op == '*' and ((lhs == 0 and rhs == null and nominalFactor(b.b, model_geometry)) or
                        (rhs == 0 and lhs == null and nominalFactor(b.a, model_geometry)))) break :blk 0;
                    const a = lhs orelse break :blk null;
                    const c = rhs orelse break :blk null;
                    break :blk switch (b.op) {
                        '+' => a + c,
                        '-' => a - c,
                        '*' => a * c,
                        '/' => a / c,
                        '^' => std.math.pow(f64, a, c),
                        '<' => @floatFromInt(@intFromBool(a < c)),
                        '>' => @floatFromInt(@intFromBool(a > c)),
                        'L' => @floatFromInt(@intFromBool(a <= c)),
                        'G' => @floatFromInt(@intFromBool(a >= c)),
                        '=' => @floatFromInt(@intFromBool(a == c)),
                        '!' => @floatFromInt(@intFromBool(a != c)),
                        '&' => @floatFromInt(@intFromBool(a != 0 and c != 0)),
                        '|' => @floatFromInt(@intFromBool(a != 0 or c != 0)),
                        else => null,
                    };
                },
            };
        }

        /// Substitute env params into a device's positional and kv values.
        fn substDevice(arena: std.mem.Allocator, d: ir.Device, env: []const Env) Error!ir.Device {
            var nd = d;
            if (d.positional.len > 0) {
                const pos = try arena.alloc(ir.Value, d.positional.len);
                for (d.positional, pos) |v, *o| o.* = try substValue(arena, v, env, false);
                nd.positional = pos;
            }
            if (d.kv.len > 0) {
                const kv = try arena.alloc(ir.Kv, d.kv.len);
                for (d.kv, kv) |kvp, *o| o.* = .{ .key = kvp.key, .value = try substValue(arena, kvp.value, env, false) };
                nd.kv = kv;
            }
            return nd;
        }

        fn substValue(arena: std.mem.Allocator, v: ir.Value, env: []const Env, model_geometry: bool) Error!ir.Value {
            return switch (v) {
                .num => v,
                .name => |nm| blk: {
                    if (findScope(env, nm) == null) break :blk v;
                    const ident: ir.Expr = .{ .ident = nm };
                    const se = try substExprDepth(arena, &ident, env, 0);
                    break :blk if (foldExpr(se, model_geometry)) |n| .{ .num = n } else .{ .expr = se };
                },
                .expr => |e| blk: {
                    const se = try substExprDepth(arena, e, env, 0);
                    // Fold to a plain number when possible: downstream lowering
                    // (engine valueNumber) only understands .num.
                    break :blk if (foldExpr(se, model_geometry)) |n| ir.Value{ .num = n } else ir.Value{ .expr = se };
                },
                .group => |g| blk: {
                    const args = try arena.alloc(ir.Value, g.args.len);
                    for (g.args, args) |a, *o| o.* = try substValue(arena, a, env, model_geometry);
                    break :blk .{ .group = .{ .name = g.name, .args = args } };
                },
            };
        }

        fn findScope(scopes: []const Env, name: []const u8) ?usize {
            var i = scopes.len;
            while (i > 0) {
                i -= 1;
                if (scopes[i].contains(name)) return i;
            }
            return null;
        }

        fn substExprDepth(arena: std.mem.Allocator, e: *const ir.Expr, env: []const Env, depth: u8) Error!*const ir.Expr {
            if (depth == 64) return error.ParseError;
            switch (e.*) {
                .num => return e,
                .ident => |nm| {
                    const scope = findScope(env, nm) orelse return e;
                    const defining = env[0 .. scope + 1];
                    // Allocate only for the arms that keep the node: an .expr
                    // alias recurses into the definition and never uses one.
                    const sub: ir.Expr = switch (env[scope].get(nm).?) {
                        .num => |n| .{ .num = n },
                        .name => |n2| .{ .ident = n2 },
                        .expr => |se| return substExprDepth(arena, se, defining, depth + 1),
                        .group => return error.ParseError,
                    };
                    const out = try arena.create(ir.Expr);
                    out.* = sub;
                    return if (sub == .ident) substExprDepth(arena, out, defining, depth + 1) else out;
                },
                .call => |c| {
                    if (std.mem.eql(u8, c.name, "v") or std.mem.eql(u8, c.name, "i")) return e;
                    const args = try arena.alloc(*const ir.Expr, c.args.len);
                    for (c.args, args) |a, *o| o.* = try substExprDepth(arena, a, env, depth);
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .call = .{ .name = c.name, .args = args } };
                    return out;
                },
                .unop => |u| {
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .unop = .{ .op = u.op, .a = try substExprDepth(arena, u.a, env, depth) } };
                    return out;
                },
                .binop => |b| {
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .binop = .{ .op = b.op, .a = try substExprDepth(arena, b.a, env, depth), .b = try substExprDepth(arena, b.b, env, depth) } };
                    return out;
                },
            }
        }

    };
}

test "parser: non-standard instance name in subcircuit expands correctly" {
    // OSDI-era netlists (e.g. VACASK) name MOSFET instances like 'nm' (letter 'n')
    // inside subcircuits. After expansion, the device must still be usable:
    // nodes and model name must be parsed correctly via variable-node-count path.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\wrapper
        \\.model mymod NMOS(level=1 VTO=0.7)
        \\.subckt wrap d g s b
        \\  nm d g s b mymod w=1u l=0.2u
        \\.ends
        \\xm1 out in vdd 0 wrap
        \\vdd vdd 0 1.0
        \\.op
        \\.end
        \\
    ;
    const nl = try Parser(@import("tokenizer.zig").ngspice).parse(arena_state.allocator(), src);
    const dl = nl.devices;
    var found = false;
    for (0..dl.len()) |i| {
        const d = dl.get(i);
        if (std.mem.indexOf(u8, d.name, "nm") != null) {
            try std.testing.expectEqual(@as(usize, 4), d.nodes.len);
            try std.testing.expectEqual(@as(usize, 1), d.positional.len);
            switch (d.positional[0]) {
                .name => |n| try std.testing.expectEqualStrings("mymod", n),
                else => return error.TestUnexpectedResult,
            }
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "parser: recognizes Verilog-A HDL includes as foreign devices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\test
        \\.hdl "models/resistor.va"
        \\.include 'models/diode.vams'
        \\.end
        \\
    ;
    const nl = try Parser(@import("tokenizer.zig").ngspice).parse(arena_state.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), nl.foreign.len);
    try std.testing.expectEqual(ir.ForeignKind.verilog_a, nl.foreign[0].kind);
    try std.testing.expectEqualStrings("models/resistor.va", nl.foreign[0].path);
    try std.testing.expectEqual(ir.ForeignKind.verilog_a, nl.foreign[1].kind);
    try std.testing.expectEqualStrings("models/diode.vams", nl.foreign[1].path);
}

test "parser: leaves ordinary includes as directives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\test
        \\.include "models/common.inc"
        \\.end
        \\
    ;
    const nl = try Parser(@import("tokenizer.zig").ngspice).parse(arena_state.allocator(), src);
    try std.testing.expectEqual(@as(usize, 0), nl.foreign.len);
    try std.testing.expectEqual(@as(usize, 1), nl.directives.len);
    try std.testing.expectEqualStrings("include", nl.directives[0].kind);
}
