const std = @import("std");
const ir = @import("types.zig");
const Token = @import("tokenizer.zig").Token;

pub const Error = error{ OutOfMemory, ParseError };

fn simdLower(buf: []u8) void {
    const W = 32;
    const V = @Vector(W, u8);
    const a_vec: V = @splat('A');
    const z_vec: V = @splat('Z');
    const bit: V = @splat(0x20);
    const zero: V = @splat(0);
    var i: usize = 0;
    while (i + W <= buf.len) : (i += W) {
        const v: V = buf[i..][0..W].*;
        const is_upper = (v >= a_vec) & (v <= z_vec);
        buf[i..][0..W].* = v | @select(u8, is_upper, bit, zero);
    }
    for (buf[i..]) |*c| c.* = std.ascii.toLower(c.*);
}

fn countNewlines(src: []const u8) usize {
    const W = 32;
    const V = @Vector(W, u8);
    const nl: V = @splat('\n');
    const ones: V = @splat(1);
    const zeros: V = @splat(0);
    var count: usize = 0;
    var i: usize = 0;
    while (i + W <= src.len) : (i += W) {
        const v: V = src[i..][0..W].*;
        count += @reduce(.Add, @select(u8, v == nl, ones, zeros));
    }
    for (src[i..]) |c| {
        if (c == '\n') count += 1;
    }
    return count;
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
            // ponytail: always dupe before lowering (one bulk memcpy) so the
            // original bytes survive — file paths (.hdl cards) are
            // case-sensitive and must be recovered from `orig` by offset.
            const orig: []const u8 = src_in;
            const src: []const u8 = blk: {
                if (Tok.case_normalize) {
                    const buf: []u8 = try arena.dupe(u8, orig);
                    simdLower(buf);
                    break :blk buf;
                }
                break :blk orig;
            };

            const line_hint = countNewlines(src);
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
                lines.rest = if (std.mem.indexOfScalar(u8, src, '\n')) |i| src[i + 1 ..] else "";
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

            // Build subcircuit type registry before expansion.
            var subckt_type_list: std.ArrayList(ir.SubcktType) = .empty;
            // Type 0 is reserved for "top-level" (no subcircuit).
            try subckt_type_list.append(arena, .{ .name = "", .n_ports = 0, .n_internal_nodes = 0, .device_count = 0 });
            var subckt_type_map: std.StringHashMapUnmanaged(u16) = .empty;
            var subckt_iter = subckts.iterator();
            while (subckt_iter.next()) |entry| {
                const sname = entry.key_ptr.*;
                const sub = entry.value_ptr.*;
                const n_ports: u16 = @intCast(sub.ports.len);
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
                const type_id: u16 = @intCast(subckt_type_list.items.len);
                try subckt_type_list.append(arena, .{
                    .name = sname,
                    .n_ports = n_ports,
                    .n_internal_nodes = n_internal,
                    .device_count = @intCast(countExpanded(sub.devices, &subckts, 1)),
                });
                try subckt_type_map.put(arena, sname, type_id);
            }

            const expanded_hint = countExpanded(devices.items, &subckts, 0);
            var flat: std.ArrayList(ir.Device) = .empty;
            try flat.ensureTotalCapacity(arena, expanded_hint);
            // Global .param environment. ponytail: .param inside .subckt bodies
            // also lands here (leaks to global) — benign, since instance kv and
            // subckt defaults shadow globals during expansion.
            var genv: Env = .empty;
            for (params.items) |kvp| try genv.put(arena, kvp.key, kvp.value);
            var instance_counter: u32 = 1; // 0 = top-level
            for (devices.items) |d| {
                const td = if (genv.size > 0) try substDevice(arena, d, &genv) else d;
                try expandInto(arena, &flat, td, &subckts, 0, 0, 0, &subckt_type_map, &instance_counter, &genv);
            }

            var dl = try ir.DeviceList.fromUnsorted(arena, flat.items);
            dl.subckt_types = subckt_type_list.items;

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
                        var s = Subckt{ .name = undefined, .ports = undefined, .defaults = undefined, .devices = &.{} };
                        const namew = t.next() orelse return error.ParseError;
                        s.name = namew.word;
                        var ports: std.ArrayList([]const u8) = .empty;
                        var defaults: std.ArrayList(ir.Kv) = .empty;
                        while (t.next()) |tk| {
                            switch (tk) {
                                .word => |w| {
                                    var peek = t.*;
                                    if (peek.next()) |nx| {
                                        if (nx == .eq) {
                                            t.* = peek;
                                            const v = try parseValueToken(arena, t);
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
                        s.defaults = defaults.items;
                        const gop = try subckts.getOrPut(arena, s.name);
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
                                    const v = try parseValueToken(arena, t);
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
                                            const v = try parseValueToken(arena, t);
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
                if (foreignKindForPath(path)) |foreign_kind| {
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
            // Generic directive
            // ponytail: skip `=` like comma — .OPTIONS/.opt/.width use key=value
            // syntax that zpicey doesn't consume. Parse key and value as separate args.
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

        pub fn dump(gpa: std.mem.Allocator, nl: ir.Netlist) Error![]u8 {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            const w = &aw.writer;

            w.print("{s}\n", .{nl.title}) catch return error.OutOfMemory;
            for (nl.params) |p| {
                w.print(".param {s}=", .{p.key}) catch return error.OutOfMemory;
                try dumpValue(w, p.value);
                w.print("\n", .{}) catch return error.OutOfMemory;
            }
            for (0..nl.devices.len()) |di| {
                w.print("{s}", .{nl.devices.names[di]}) catch return error.OutOfMemory;
                for (nl.devices.nodes[di]) |n| w.print(" {s}", .{n}) catch return error.OutOfMemory;
                for (nl.devices.positional[di]) |v| {
                    w.print(" ", .{}) catch return error.OutOfMemory;
                    try dumpValue(w, v);
                }
                for (nl.devices.kv[di]) |p| {
                    w.print(" {s}=", .{p.key}) catch return error.OutOfMemory;
                    try dumpValue(w, p.value);
                }
                w.print("\n", .{}) catch return error.OutOfMemory;
            }
            for (nl.models) |m| {
                w.print(".model {s} {s}(", .{ m.name, m.kind }) catch return error.OutOfMemory;
                for (m.kv, 0..) |p, i| {
                    if (i > 0) w.print(" ", .{}) catch return error.OutOfMemory;
                    if (p.key.len > 0) w.print("{s}=", .{p.key}) catch return error.OutOfMemory;
                    try dumpValue(w, p.value);
                }
                w.print(")\n", .{}) catch return error.OutOfMemory;
            }
            for (nl.foreign) |f| {
                const kind: []const u8 = switch (f.kind) {
                    .osdi_include => "osdi_include",
                    .pre_osdi => "pre_osdi",
                    .verilog_a => "hdl",
                    .verilog => "verilog",
                };
                w.print(".{s} {s}\n", .{ kind, f.path }) catch return error.OutOfMemory;
            }
            for (nl.directives) |dir| {
                w.print(".{s}", .{dir.kind}) catch return error.OutOfMemory;
                for (dir.args) |v| {
                    w.print(" ", .{}) catch return error.OutOfMemory;
                    try dumpValue(w, v);
                }
                w.print("\n", .{}) catch return error.OutOfMemory;
            }
            w.print(".end\n", .{}) catch return error.OutOfMemory;
            return aw.toOwnedSlice() catch return error.OutOfMemory;
        }

        const ElementShape = struct {
            letters: []const u8,
            nodes: ?usize,
        };

        const element_shapes = [_]ElementShape{
            // w (current-controlled switch): W n+ n- Vctrl model — 2 nodes,
            // Vctrl/model are positional words, not nodes (ngspice INP2W).
            .{ .letters = "rclvidbfhw", .nodes = 2 },
            .{ .letters = "qzj", .nodes = 3 },
            .{ .letters = "egsmto", .nodes = 4 },
            .{ .letters = "k", .nodes = 0 },
            .{ .letters = "px", .nodes = null },
        };

        fn nodeCount(letter: u8) ?usize {
            for (element_shapes) |shape| {
                if (std.mem.indexOfScalar(u8, shape.letters, letter) != null) return shape.nodes;
            }
            return null;
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

            // Parse trailing kv and positional values
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
                                const v = try parseValueToken(arena, &t);
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
                        const v = try parseValueToken(arena, &t);
                        if (pos_count < pos_buf.len) {
                            pos_buf[pos_count] = v;
                            pos_count += 1;
                        } else {
                            if (pos_overflow.items.len == 0)
                                try pos_overflow.appendSlice(arena, pos_buf[0..pos_buf.len]);
                            try pos_overflow.append(arena, v);
                        }
                    },
                    else => {
                        const v = try parseValueToken(arena, &t);
                        if (pos_count < pos_buf.len) {
                            pos_buf[pos_count] = v;
                            pos_count += 1;
                        } else {
                            if (pos_overflow.items.len == 0)
                                try pos_overflow.appendSlice(arena, pos_buf[0..pos_buf.len]);
                            try pos_overflow.append(arena, v);
                        }
                    },
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
                                        if (a2 == .rparen) { t.* = p3; break; }
                                        if (a2 == .comma) { t.* = p3; continue; }
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

        fn foreignKindForPath(path: []const u8) ?ir.ForeignKind {
            const ext = std.fs.path.extension(path);
            if (std.ascii.eqlIgnoreCase(ext, ".va") or
                std.ascii.eqlIgnoreCase(ext, ".vams") or
                std.ascii.eqlIgnoreCase(ext, ".veriloga"))
            {
                return .verilog_a;
            }
            if (std.ascii.eqlIgnoreCase(ext, ".v") or std.ascii.eqlIgnoreCase(ext, ".sv"))
                return .verilog;
            return null;
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
                    const prec: u8 = switch (c) {
                        '+', '-' => 1,
                        '*', '/' => 2,
                        '^' => 3,
                        else => break,
                    };
                    if (prec < min_prec) break;
                    var op = c;
                    p.pos += 1;
                    if (c == '*' and p.pos < p.text.len and p.text[p.pos] == '*') {
                        p.pos += 1;
                        op = '^';
                        if (3 < min_prec) {}
                        const rhs = try p.parseBin(3);
                        lhs = try p.mk(.{ .binop = .{ .op = '^', .a = lhs, .b = rhs } });
                        continue;
                    }
                    const rhs = try p.parseBin(if (op == '^') prec else prec + 1);
                    lhs = try p.mk(.{ .binop = .{ .op = op, .a = lhs, .b = rhs } });
                }
                return lhs;
            }

            fn parseUnary(p: *ExprP) Error!*const ir.Expr {
                const c = p.peek() orelse return error.ParseError;
                if (c == '-') {
                    p.pos += 1;
                    return p.mk(.{ .unop = .{ .op = '-', .a = try p.parseUnary() } });
                }
                if (c == '+') {
                    p.pos += 1;
                    return p.parseUnary();
                }
                return p.parseAtom();
            }

            fn parseAtom(p: *ExprP) Error!*const ir.Expr {
                const c = p.peek() orelse return error.ParseError;
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
                            p.pos += 2;
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
                        if (p.peek() != ')') {
                            while (true) {
                                try args.append(p.arena, try p.parseBin(0));
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
            name: []const u8,
            ports: []const []const u8,
            defaults: []const ir.Kv,
            devices: []const ir.Device,
        };

        const Env = std.StringHashMapUnmanaged(ir.Value);

        fn concatDot(arena: std.mem.Allocator, a: []const u8, b: []const u8) Error![]const u8 {
            const buf = try arena.alloc(u8, a.len + 1 + b.len);
            @memcpy(buf[0..a.len], a);
            buf[a.len] = '.';
            @memcpy(buf[a.len + 1 ..], b);
            return buf;
        }

        fn portLookup(ports: []const []const u8, mappings: []const []const u8, needle: []const u8) ?[]const u8 {
            for (ports, mappings) |p, m| {
                if (std.mem.eql(u8, needle, p)) return m;
            }
            return null;
        }

        fn countExpanded(devices: []const ir.Device, subckts: *const std.StringHashMapUnmanaged(Subckt), depth: usize) usize {
            if (depth > 32) return 0;
            var count: usize = 0;
            for (devices) |d| {
                if (d.letter() != 'x') {
                    count += 1;
                    continue;
                }
                if (d.positional.len < 1) { count += 1; continue; }
                const sname = switch (d.positional[d.positional.len - 1]) {
                    .name => |nm| nm,
                    else => { count += 1; continue; },
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
            genv: *const Env,
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
            var env: Env = try genv.clone(arena);
            for (sub.defaults) |kvp| try env.put(arena, kvp.key, kvp.value);
            for (d.kv) |kvp| try env.put(arena, kvp.key, kvp.value);

            for (sub.devices) |sd| {
                var nd = try substDevice(arena, sd, &env);
                nd.name = try concatDot(arena, sd.name, d.name);
                const dev_nodes = try arena.alloc([]const u8, sd.nodes.len);
                for (sd.nodes, dev_nodes) |n, *o| {
                    // ponytail: linear scan beats HashMap for typical port counts (2-8)
                    if (portLookup(sub.ports, d.nodes, n)) |mapped| {
                        o.* = mapped;
                    } else if (n.len <= 3 and (std.mem.eql(u8, n, "0") or std.mem.eql(u8, n, "gnd"))) {
                        o.* = n;
                    } else {
                        o.* = try concatDot(arena, d.name, n);
                    }
                }
                nd.nodes = dev_nodes;
                try expandInto(arena, out, nd, subckts, depth + 1, this_type, this_instance, type_map, instance_counter, genv);
            }
        }

        /// Constant-fold a fully-substituted expression; null if any ident/call remains.
        fn foldExpr(e: *const ir.Expr) ?f64 {
            return switch (e.*) {
                .num => |n| n,
                .ident, .call => null,
                .unop => |u| switch (u.op) {
                    '-' => if (foldExpr(u.a)) |a| -a else null,
                    '+' => foldExpr(u.a),
                    else => null,
                },
                .binop => |b| blk: {
                    const a = foldExpr(b.a) orelse break :blk null;
                    const c = foldExpr(b.b) orelse break :blk null;
                    break :blk switch (b.op) {
                        '+' => a + c,
                        '-' => a - c,
                        '*' => a * c,
                        '/' => a / c,
                        '^' => std.math.pow(f64, a, c),
                        else => null,
                    };
                },
            };
        }

        /// Substitute env params into a device's positional and kv values.
        fn substDevice(arena: std.mem.Allocator, d: ir.Device, env: *const Env) Error!ir.Device {
            var nd = d;
            if (d.positional.len > 0) {
                const pos = try arena.alloc(ir.Value, d.positional.len);
                for (d.positional, pos) |v, *o| o.* = try substValue(arena, v, env);
                nd.positional = pos;
            }
            if (d.kv.len > 0) {
                const kv = try arena.alloc(ir.Kv, d.kv.len);
                for (d.kv, kv) |kvp, *o| o.* = .{ .key = kvp.key, .value = try substValue(arena, kvp.value, env) };
                nd.kv = kv;
            }
            return nd;
        }

        fn substValue(arena: std.mem.Allocator, v: ir.Value, env: *const Env) Error!ir.Value {
            return switch (v) {
                .num => v,
                .name => |nm| if (env.get(nm)) |sv| sv else v,
                .expr => |e| blk: {
                    const se = try substExpr(arena, e, env);
                    // Fold to a plain number when possible: downstream lowering
                    // (engine valueNumber) only understands .num.
                    break :blk if (foldExpr(se)) |n| ir.Value{ .num = n } else ir.Value{ .expr = se };
                },
                .group => |g| blk: {
                    const args = try arena.alloc(ir.Value, g.args.len);
                    for (g.args, args) |a, *o| o.* = try substValue(arena, a, env);
                    break :blk .{ .group = .{ .name = g.name, .args = args } };
                },
            };
        }

        fn substExpr(arena: std.mem.Allocator, e: *const ir.Expr, env: *const Env) Error!*const ir.Expr {
            switch (e.*) {
                .num => return e,
                .ident => |nm| {
                    const sv = env.get(nm) orelse return e;
                    const out = try arena.create(ir.Expr);
                    out.* = switch (sv) {
                        .num => |n| .{ .num = n },
                        .name => |n2| .{ .ident = n2 },
                        .expr => |se| return se,
                        .group => return error.ParseError,
                    };
                    return out;
                },
                .call => |c| {
                    const args = try arena.alloc(*const ir.Expr, c.args.len);
                    for (c.args, args) |a, *o| o.* = try substExpr(arena, a, env);
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .call = .{ .name = c.name, .args = args } };
                    return out;
                },
                .unop => |u| {
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .unop = .{ .op = u.op, .a = try substExpr(arena, u.a, env) } };
                    return out;
                },
                .binop => |b| {
                    const out = try arena.create(ir.Expr);
                    out.* = .{ .binop = .{ .op = b.op, .a = try substExpr(arena, b.a, env), .b = try substExpr(arena, b.b, env) } };
                    return out;
                },
            }
        }

        fn dumpValue(w: *std.Io.Writer, v: ir.Value) Error!void {
            switch (v) {
                .num => |n| w.print("{d}", .{n}) catch return error.OutOfMemory,
                .name => |s| w.print("{s}", .{s}) catch return error.OutOfMemory,
                .expr => |e| {
                    w.print("{{", .{}) catch return error.OutOfMemory;
                    try dumpExpr(w, e);
                    w.print("}}", .{}) catch return error.OutOfMemory;
                },
                .group => |g| {
                    w.print("{s}(", .{g.name}) catch return error.OutOfMemory;
                    for (g.args, 0..) |a, i| {
                        if (i > 0) w.print(" ", .{}) catch return error.OutOfMemory;
                        try dumpValue(w, a);
                    }
                    w.print(")", .{}) catch return error.OutOfMemory;
                },
            }
        }

        fn dumpExpr(w: *std.Io.Writer, e: *const ir.Expr) Error!void {
            switch (e.*) {
                .num => |n| w.print("{d}", .{n}) catch return error.OutOfMemory,
                .ident => |s| w.print("{s}", .{s}) catch return error.OutOfMemory,
                .call => |c| {
                    w.print("{s}(", .{c.name}) catch return error.OutOfMemory;
                    for (c.args, 0..) |a, i| {
                        if (i > 0) w.print(",", .{}) catch return error.OutOfMemory;
                        try dumpExpr(w, a);
                    }
                    w.print(")", .{}) catch return error.OutOfMemory;
                },
                .unop => |u| {
                    w.print("(-", .{}) catch return error.OutOfMemory;
                    try dumpExpr(w, u.a);
                    w.print(")", .{}) catch return error.OutOfMemory;
                },
                .binop => |b| {
                    w.print("(", .{}) catch return error.OutOfMemory;
                    try dumpExpr(w, b.a);
                    w.print("{c}", .{b.op}) catch return error.OutOfMemory;
                    try dumpExpr(w, b.b);
                    w.print(")", .{}) catch return error.OutOfMemory;
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
    // After subcircuit expansion, the 'nm' device should appear in the flat list.
    // It should have 4 nodes and positional[0] = "mymod" (the model name).
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
