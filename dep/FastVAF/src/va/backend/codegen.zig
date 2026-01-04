//! MIR → contract-shaped Zig device source. Reads top-down as the generated
//! file does: header + S-generic math helpers → U enum → Model → stamp
//! patterns → noise → eval (→ q) → shared dyn ABI.

const std = @import("std");
const emit = @import("emit");
const Buf = emit.Buf;
const Mir = @import("../ir/Mir.zig");
const Lower = @import("../ir/Lower.zig");

const Opcode = Mir.Opcode;
const Value = Mir.Value;
const Block = Mir.Block;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{UnsupportedCall};

pub fn generate(allocator: std.mem.Allocator, mir: *const Mir, lower: *const Lower) Error![]const u8 {
    const n_blocks = mir.numBlocks();

    // Per-block flags: emitted marker + loop-header marker (from .br_loop).
    const block_emitted = try allocator.alloc(bool, n_blocks);
    defer allocator.free(block_emitted);
    const loop_headers = try allocator.alloc(bool, n_blocks);
    defer allocator.free(loop_headers);
    @memset(loop_headers, false);

    const pred_count = try allocator.alloc(u8, n_blocks);
    defer allocator.free(pred_count);
    @memset(pred_count, 0);
    const bump = struct {
        fn f(counts: []u8, b: Block) void {
            if (counts[b.id()] != 255) counts[b.id()] += 1;
        }
    }.f;

    var block_it = mir.blockIter();
    while (block_it.next()) |block| {
        var inst_it = mir.blockInsts(block);
        while (inst_it.next()) |inst| {
            switch (mir.instData(inst)) {
                .branch => |br| {
                    if (br.loop_entry) loop_headers[block.id()] = true;
                    bump(pred_count, br.then_dst);
                    bump(pred_count, br.else_dst);
                },
                .jump => |j| bump(pred_count, j.destination),
                else => {},
            }
        }
    }

    var cg = Codegen{
        .mir = mir,
        .lower = lower,
        .out = .init(allocator),
        .allocator = allocator,
        .block_emitted = block_emitted,
        .loop_headers = loop_headers,
        .pred_count = pred_count,
    };
    defer cg.out.deinit();
    defer cg.top_vals.deinit(allocator);
    defer cg.scope_starts.deinit(allocator);

    try cg.emitModule();
    return cg.out.toOwnedSlice();
}

const Codegen = struct {
    mir: *const Mir,
    lower: *const Lower,
    out: std.Io.Writer.Allocating,
    allocator: std.mem.Allocator,
    block_emitted: []bool,
    loop_headers: []const bool,
    pred_count: []const u8,
    // Instruction results emitted in the current function, segmented into
    // lexical scopes (function body, each if/else body, loop body). Some are
    // dead in a given eval/q variant or only used in another scope's phi
    // update, so each scope discards its values before closing to satisfy
    // the unused-local check.
    top_vals: Buf(Value) = .{},
    scope_starts: Buf(u32) = .{},
    indent: u8 = 0,
    current_block: ?Block = null,

    fn w(self: *Codegen) *std.Io.Writer {
        return &self.out.writer;
    }

    fn writeIndent(self: *Codegen) !void {
        for (0..self.indent) |_| try self.w().writeAll("    ");
    }

    fn emitModule(self: *Codegen) !void {
        const contribs = self.lower.contributions.slice();
        const params = self.lower.params.slice();
        const node_order = self.lower.node_order.slice();

        try self.w().writeAll(
            \\const std = @import("std");
            \\const contract = @import("contract");
            \\const Self = @This();
            \\
            \\const inf_: f64 = @as(f64, @bitCast(@as(u64, 0x7ff0000000000000)));
            \\
            \\// Value-form math helpers: generic over the device scalar S. Functions
            \\// not in the S primitive set are expressed via S composition so their
            \\// derivative propagates analytically.
            \\inline fn zpow(comptime S: type, base: S, e: S) S {
            \\    return e.mul(base.log()).exp();
            \\}
            \\inline fn zsinh(comptime S: type, x: S) S {
            \\    return x.sinh();
            \\}
            \\inline fn zcosh(comptime S: type, x: S) S {
            \\    return x.cosh();
            \\}
            \\inline fn ztanh(comptime S: type, x: S) S {
            \\    return x.tanh();
            \\}
            \\inline fn zasinh(comptime S: type, x: S) S {
            \\    return x.add(x.mul(x).addC(1.0).sqrt()).log();
            \\}
            \\inline fn zacosh(comptime S: type, x: S) S {
            \\    return x.add(x.mul(x).addC(-1.0).sqrt()).log();
            \\}
            \\inline fn zatanh(comptime S: type, x: S) S {
            \\    return x.addC(1.0).div(x.neg().addC(1.0)).log().scale(0.5);
            \\}
            \\inline fn zatan2(comptime S: type, y: S, x: S) S {
            \\    const pi: f64 = 3.14159265358979323846;
            \\    const yv = y.val();
            \\    const xv = x.val();
            \\    // Base angle atan(y/x); quadrant fix-ups picked on values (topology),
            \\    // each branch carrying the exact derivative of its expression.
            \\    if (xv > 0.0) {
            \\        return y.div(x).atan();
            \\    } else if (xv < 0.0) {
            \\        if (yv >= 0.0) return y.div(x).atan().addC(pi);
            \\        return y.div(x).atan().addC(-pi);
            \\    } else {
            \\        if (yv > 0.0) return S.con(pi * 0.5);
            \\        if (yv < 0.0) return S.con(-pi * 0.5);
            \\        return S.con(0.0);
            \\    }
            \\}
            \\inline fn zasin(comptime S: type, x: S) S {
            \\    return zatan2(S, x, x.mul(x).neg().addC(1.0).sqrt());
            \\}
            \\inline fn zacos(comptime S: type, x: S) S {
            \\    return zatan2(S, x.mul(x).neg().addC(1.0).sqrt(), x);
            \\}
            \\inline fn zatan(comptime S: type, x: S) S {
            \\    return x.atan();
            \\}
            \\
        );

        // U enum from Lower's node_order (ports first, then internals).
        // Indices match the block_param indices assigned during lowering,
        // so x[i] in eval is exactly node_order[i].
        try self.w().writeAll("\npub const U = enum(u8) {\n");
        for (node_order) |n| {
            try self.w().writeAll("    ");
            try emit.writeIdent(self.w(), n);
            try self.w().writeAll(",\n");
        }
        try self.w().writeAll("};\n\n");

        const num_ports: usize = if (self.lower.num_ports > 0) self.lower.num_ports else node_order.len;
        try self.w().print("pub const num_ports: usize = {d};\n\n", .{num_ports});

        // Model struct
        try self.w().writeAll("pub const Model = struct {\n");
        for (params) |p| {
            const zig_type = switch (p.ty) {
                .real => "f32",
                .integer => "i32",
                .string => "[]const u8",
            };
            try self.w().writeAll("    ");
            try emit.writeIdent(self.w(), p.name);
            try self.w().print(": {s} = ", .{zig_type});
            try self.emitDefault(p);
            try self.w().writeAll(",\n");
        }
        try self.w().writeAll("};\n\n");

        // temp: analysis-owned device temperature in Kelvin (default 27°C).
        // The batch setTemp hook keys on this field (K because default > 200);
        // $temperature reads it — NOT the eval `t` param, which is time.
        try self.w().writeAll("pub const Instance = struct { temp: f32 = 300.15 };\n\n");

        try self.w().writeAll("const n_u = contract.nU(Self);\n\n");

        try self.emitPattern("g_pattern_override", contribs, false);

        var has_reactive = false;
        for (contribs) |c| {
            if (c.react_val != .f_zero and c.react_val != .undef) {
                has_reactive = true;
                break;
            }
        }
        if (has_reactive) {
            try self.emitPattern("c_pattern_override", contribs, true);
        }

        // Noise generators (row/col from the contribution's node pair).
        try self.w().writeAll("pub const noise_gens = [_]contract.NoiseGen(Self){\n");
        for (contribs) |c| {
            const kind = c.noise_kind orelse continue;
            if (c.nodes.len == 0) continue;
            const hi = self.nodeIndex(c.nodes[0]) orelse continue;
            const lo = if (c.nodes.len >= 2) self.nodeIndex(c.nodes[1]) orelse continue else hi;
            try self.w().print("    .{{ .row = {d}, .col = {d}, .kind = .{s} }},\n", .{ hi, lo, @tagName(kind) });
        }
        try self.w().writeAll("};\n\n");

        try self.emitEvalFn("eval", contribs, false);

        if (has_reactive) {
            try self.w().writeByte('\n');
            try self.emitEvalFn("q", contribs, true);
        }

        try self.w().writeAll(
            \\
            \\comptime {
            \\    contract.validate(Self);
            \\}
            \\
        );
    }

    /// U-enum index of a node name: linear scan of node_order (≤256 entries,
    /// emitted once per contribution — not a hot path).
    fn nodeIndex(self: *const Codegen, node_name: []const u8) ?u8 {
        for (self.lower.node_order.slice(), 0..) |n, i| {
            if (std.mem.eql(u8, n, node_name)) return @intCast(i);
        }
        return null;
    }

    fn emitPattern(
        self: *Codegen,
        pattern_name: []const u8,
        contribs: []const Lower.Contribution,
        reactive: bool,
    ) !void {
        // Collect unique (row, col) entries
        var seen: std.AutoHashMapUnmanaged(u16, void) = .empty;
        defer seen.deinit(self.allocator);

        try self.w().print("pub const {s} = [_]contract.Entry(n_u){{\n", .{pattern_name});
        for (contribs) |c| {
            const val = if (reactive) c.react_val else c.resist_val;
            if (val == .f_zero or val == .undef or c.nodes.len == 0) continue;
            const hi = self.nodeIndex(c.nodes[0]) orelse continue;
            if (c.nodes.len >= 2) {
                const lo = self.nodeIndex(c.nodes[1]) orelse continue;
                const pairs = [_][2]u8{ .{ hi, hi }, .{ hi, lo }, .{ lo, hi }, .{ lo, lo } };
                for (pairs) |p| {
                    const key: u16 = @as(u16, p[0]) << 8 | p[1];
                    const r = try seen.getOrPut(self.allocator, key);
                    if (!r.found_existing) {
                        try self.w().print("    .{{ .row = {d}, .col = {d} }},\n", .{ p[0], p[1] });
                    }
                }
            } else {
                const key: u16 = @as(u16, hi) << 8 | hi;
                const r = try seen.getOrPut(self.allocator, key);
                if (!r.found_existing) {
                    try self.w().print("    .{{ .row = {d}, .col = {d} }},\n", .{ hi, hi });
                }
            }
        }
        try self.w().writeAll("};\n\n");
    }

    fn emitDefault(self: *Codegen, p: Lower.ParamInfo) !void {
        // String defaults are not preserved in the IR (Lower stores .undef);
        // always emit "" so the generated field stays type-correct.
        if (p.ty == .string) return self.w().writeAll("\"\"");
        if (p.default) |val| {
            // Defaults are expressions (`-2.0`, `2*PI/3`, `TNOM+273.15`);
            // fold them, or negative/derived defaults silently become 0.
            if (self.constFold(val, 0)) |f| {
                switch (p.ty) {
                    .real => if (std.math.isInf(f))
                        try self.w().writeAll(if (f > 0) "inf_" else "-inf_")
                    else
                        try self.w().print("{e}", .{f}),
                    .integer => try self.w().print("{d}", .{std.math.lossyCast(i32, f)}),
                    .string => unreachable,
                }
                return;
            }
            try self.emitConstValue(val);
        } else {
            switch (p.ty) {
                .real => try self.w().writeAll("0"),
                .integer => try self.w().writeAll("0"),
                .string => try self.w().writeAll("\"\""),
            }
        }
    }

    /// Best-effort compile-time evaluation over the value graph. Parameter
    /// defaults may reference other parameters (their defaults), literals and
    /// pure math; anything touching runtime state returns null.
    fn constFold(self: *const Codegen, val: Value, depth: u32) ?f64 {
        if (depth > 64) return null;
        const v = self.mir.resolveAlias(val);
        switch (v) {
            .undef => return null,
            .f_zero, .zero, .false_ => return 0,
            .one, .f_one, .true_ => return 1,
            .f_neg_one, .neg_one => return -1,
            .f_two => return 2,
            .f_ten => return 10,
            .f_inf => return std.math.inf(f64),
            _ => switch (self.mir.valueDef(v)) {
                .f_const => |c| return c,
                .i_const => |c| return @floatFromInt(c),
                .param_ref => |idx| {
                    const p = self.lower.params.slice()[idx];
                    return self.constFold(p.default orelse return null, depth + 1);
                },
                .inst_result => |inst| switch (self.mir.instData(inst)) {
                    .unary => |u| {
                        const a = self.constFold(u.arg, depth + 1) orelse return null;
                        return switch (u.opcode) {
                            .fneg, .ineg => -a,
                            .sqrt => @sqrt(a),
                            .exp => @exp(a),
                            .ln => @log(a),
                            .log => @log10(a),
                            .floor => @floor(a),
                            .ceil => @ceil(a),
                            .fi_cast, .if_cast, .opt_barrier, .bi_cast, .ib_cast, .fb_cast, .bf_cast => a,
                            .inot, .bnot => if (a == 0) 1.0 else 0.0,
                            else => null,
                        };
                    },
                    .binary => |b| {
                        const a = self.constFold(b.args[0], depth + 1) orelse return null;
                        const c = self.constFold(b.args[1], depth + 1) orelse return null;
                        return switch (b.opcode) {
                            .fadd, .iadd => a + c,
                            .fsub, .isub => a - c,
                            .fmul, .imul => a * c,
                            .fdiv => a / c,
                            .pow => std.math.pow(f64, a, c),
                            .flt, .ilt => if (a < c) 1.0 else 0.0,
                            .fgt, .igt => if (a > c) 1.0 else 0.0,
                            .fle, .ile => if (a <= c) 1.0 else 0.0,
                            .fge, .ige => if (a >= c) 1.0 else 0.0,
                            .feq, .ieq => if (a == c) 1.0 else 0.0,
                            .fne, .ine => if (a != c) 1.0 else 0.0,
                            else => null,
                        };
                    },
                    .ternary => |t| {
                        const c = self.constFold(t.args[0], depth + 1) orelse return null;
                        return self.constFold(t.args[if (c != 0.0) @as(usize, 1) else 2], depth + 1);
                    },
                    else => return null,
                },
                else => return null,
            },
        }
    }

    fn emitEvalFn(
        self: *Codegen,
        fn_name: []const u8,
        contribs: []const Lower.Contribution,
        reactive: bool,
    ) !void {
        // Reset per-function block/phi state so eval and q each get a full walk.
        @memset(self.block_emitted, false);
        self.top_vals.clearRetainingCapacity();
        self.scope_starts.clearRetainingCapacity();
        try self.pushScope();

        try self.w().print(
            \\pub fn {s}(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, t: f64) [n_u]S {{
            \\    _ = &t;
            \\    _ = &inst;
            \\
        , .{fn_name});

        self.indent = 1;

        // Parameter reads lower to `model.<name>` (see emitValueRef .param_ref),
        // so physics honors the .model card. `_ = &model;` keeps the parameter
        // valid whether or not this particular function reads any param.
        try self.w().writeAll("    _ = &model;\n\n");

        try self.scanPhis();

        // Walk blocks
        var block_it = self.mir.blockIter();
        while (block_it.next()) |block| {
            try self.emitBlock(block);
        }

        // Accumulate contributions into an S result vector, then return it.
        try self.w().writeAll("\n    var res = [_]S{S.con(0.0)} ** n_u;\n");
        // A model can end up with no live contributions in one variant; keep
        // `var` legal either way.
        try self.w().writeAll("    _ = &res;\n");
        for (contribs) |c| {
            const val = if (reactive) c.react_val else c.resist_val;
            if (val == .f_zero or val == .undef) continue;
            if (c.nodes.len == 0) continue;
            const hi = self.nodeIndex(c.nodes[0]) orelse continue;
            try self.writeIndent();
            try self.w().print("res[{d}] = res[{d}].add(", .{ hi, hi });
            try self.emitValueRef(val);
            try self.w().writeAll(");\n");
            if (c.nodes.len >= 2) {
                const lo = self.nodeIndex(c.nodes[1]) orelse continue;
                try self.writeIndent();
                try self.w().print("res[{d}] = res[{d}].sub(", .{ lo, lo });
                try self.emitValueRef(val);
                try self.w().writeAll(");\n");
            }
        }

        // Discard any function-scope results that are dead in this variant
        // (e.g. the resistive chain when emitting q, or vice versa).
        try self.popScope();

        try self.w().writeAll("    return res;\n}\n");
        self.indent = 0;
    }

    /// Declare a mutable local for every surviving (un-aliased) phi.
    fn scanPhis(self: *Codegen) !void {
        var block_it = self.mir.blockIter();
        while (block_it.next()) |block| {
            var inst_it = self.mir.blockInsts(block);
            while (inst_it.next()) |inst| {
                switch (self.mir.instData(inst)) {
                    .phi => {
                        const result = self.mir.instResult(inst);
                        const resolved = self.mir.resolveAlias(result);
                        if (resolved != result) continue;
                        try self.writeIndent();
                        try self.w().writeAll("var ");
                        try self.emitValueRef(result);
                        try self.w().writeAll(": S = undefined;\n");
                    },
                    else => {},
                }
            }
        }
    }

    fn emitBlock(self: *Codegen, block: Block) Error!void {
        if (self.block_emitted[block.id()]) return;

        if (self.loop_headers[block.id()]) {
            _ = try self.emitWhileLoop(block);
            return;
        }

        // Walk the chain from here: handles branch diamonds, join blocks and
        // their phi assignments uniformly (there are no back-edges outside
        // loops, so passing `block` as the never-matching header is safe).
        var cont: ?Block = block;
        while (cont) |c| cont = try self.emitChain(c, block);
    }

    /// Emit a loop rooted at `header` (its br_loop picks body/exit).
    /// Returns the exit block so a caller mid-chain can continue after it.
    fn emitWhileLoop(self: *Codegen, header: Block) Error!Block {
        self.block_emitted[header.id()] = true;

        // Loop-carried values enter through header phis. Assign the entry
        // edge's value BEFORE the loop: the pre-header block was created
        // before the header, back-edge sources after, so the entry pair is
        // the one with the smaller block id.
        var phi_it = self.mir.blockInsts(header);
        while (phi_it.next()) |inst| {
            switch (self.mir.instData(inst)) {
                .phi => |p| {
                    const result = self.mir.instResult(inst);
                    if (self.mir.resolveAlias(result) != result) continue;
                    for (0..p.len) |i| {
                        const pair = self.mir.phiPair(p.pairs_start, @intCast(i));
                        if (pair.block.id() < header.id()) {
                            try self.writeIndent();
                            try self.emitValueRef(result);
                            try self.w().writeAll(" = ");
                            try self.emitValueRef(pair.value);
                            try self.w().writeAll(";\n");
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        try self.writeIndent();
        try self.w().writeAll("while (true) {\n");
        self.indent += 1;
        try self.pushScope();

        const prev = self.current_block;
        self.current_block = header;

        var exit: Block = header; // overwritten by the br_loop below
        var inst_it = self.mir.blockInsts(header);
        while (inst_it.next()) |inst| {
            switch (self.mir.instData(inst)) {
                .branch => |br| {
                    // Break when condition is false (else_dst = exit)
                    try self.writeIndent();
                    try self.w().writeAll("if (");
                    try self.emitValueRef(br.cond);
                    try self.w().writeAll(".val() == 0.0) break;\n");
                    exit = br.else_dst;

                    // Body: a chain of blocks ending at the back-edge. Joins
                    // the chain does not own bubble up; at this level we own
                    // everything, so keep emitting until the back-edge.
                    var cont: ?Block = br.then_dst;
                    while (cont) |c| cont = try self.emitChain(c, header);
                },
                .phi => {},
                else => try self.emitInst(inst),
            }
        }

        self.current_block = prev;
        try self.popScope();
        self.indent -= 1;
        try self.writeIndent();
        try self.w().writeAll("}\n");
        return exit;
    }

    /// Emit the chain of blocks starting at (and owning) `start`, inside the
    /// loop rooted at `header`. Stops at:
    ///  - the back-edge jump to `header`: phi updates, returns null;
    ///  - a jump to a join block (pred_count >= 2): returns it UNEMITTED so
    ///    the branch level that owns it emits it exactly once;
    ///  - a block with no terminator: returns null.
    /// if/else diamonds recurse: each arm is its own chain; the join the
    /// arms report back is owned (continued) at this level. Nested loops are
    /// emitted whole and the chain continues at their exit block.
    fn emitChain(self: *Codegen, start: Block, header: Block) Error!?Block {
        const prev = self.current_block;
        defer self.current_block = prev;

        var current = start;
        while (true) {
            self.block_emitted[current.id()] = true;
            self.current_block = current;

            var inst_it = self.mir.blockInsts(current);
            var next_block: ?Block = null;
            while (inst_it.next()) |inst| {
                switch (self.mir.instData(inst)) {
                    .phi => {},
                    .jump => |j| {
                        if (j.destination == header) {
                            try self.emitPhiUpdates(header, current);
                            return null;
                        }
                        try self.emitPhiAssigns(j.destination);
                        if (self.loop_headers[j.destination.id()]) {
                            // Nested loop: emit it whole, continue at exit.
                            next_block = try self.emitWhileLoop(j.destination);
                        } else if (self.pred_count[j.destination.id()] >= 2) {
                            return j.destination;
                        } else {
                            next_block = j.destination;
                        }
                    },
                    .branch => |br| {
                        try self.writeIndent();
                        try self.w().writeAll("if (");
                        try self.emitValueRef(br.cond);
                        try self.w().writeAll(".val() != 0.0) {\n");
                        self.indent += 1;
                        try self.pushScope();
                        try self.emitPhiAssigns(br.then_dst);
                        const jt = try self.emitChain(br.then_dst, header);
                        try self.popScope();
                        self.indent -= 1;
                        try self.writeIndent();
                        try self.w().writeAll("} else {\n");
                        self.indent += 1;
                        try self.pushScope();
                        self.current_block = current;
                        try self.emitPhiAssigns(br.else_dst);
                        const je = try self.emitChain(br.else_dst, header);
                        try self.popScope();
                        self.indent -= 1;
                        try self.writeIndent();
                        try self.w().writeAll("}\n");
                        const join = jt orelse je orelse return null;
                        // Own the join: keep emitting at this level.
                        next_block = join;
                    },
                    else => try self.emitInst(inst),
                }
            }

            current = next_block orelse return null;
        }
    }

    /// Assign each of `target`'s phis the value flowing in from the current
    /// block (falling back to the first operand for unknown edges).
    fn emitPhiAssigns(self: *Codegen, target: Block) !void {
        const source = self.current_block orelse .entry;
        var inst_it = self.mir.blockInsts(target);
        while (inst_it.next()) |inst| {
            switch (self.mir.instData(inst)) {
                .phi => |p| {
                    const result = self.mir.instResult(inst);
                    // Aliased phis were folded away (trivial-phi removal):
                    // no `var` was declared for them, and emitting the alias
                    // target as an assignment LHS is invalid (it may be a
                    // constant). Their value flows through the alias.
                    if (self.mir.resolveAlias(result) != result) continue;
                    var matched: ?Value = null;
                    for (0..p.len) |i| {
                        const pair = self.mir.phiPair(p.pairs_start, @intCast(i));
                        if (pair.block == source) {
                            matched = pair.value;
                            break;
                        }
                    }
                    const val = matched orelse if (p.len > 0) self.mir.phiPair(p.pairs_start, 0).value else null;
                    if (val) |v| {
                        try self.writeIndent();
                        try self.emitValueRef(result);
                        try self.w().writeAll(" = ");
                        try self.emitValueRef(v);
                        try self.w().writeAll(";\n");
                    }
                },
                else => {},
            }
        }
    }

    /// Back-edge phi updates: only exact-edge matches are written.
    fn emitPhiUpdates(self: *Codegen, header: Block, source: Block) !void {
        var inst_it = self.mir.blockInsts(header);
        while (inst_it.next()) |inst| {
            switch (self.mir.instData(inst)) {
                .phi => |p| {
                    const result = self.mir.instResult(inst);
                    // Same aliased-phi skip as emitPhiAssigns (see there).
                    if (self.mir.resolveAlias(result) != result) continue;
                    var matched: ?Value = null;
                    for (0..p.len) |i| {
                        const pair = self.mir.phiPair(p.pairs_start, @intCast(i));
                        if (pair.block == source) {
                            matched = pair.value;
                            break;
                        }
                    }
                    if (matched) |v| {
                        try self.writeIndent();
                        try self.emitValueRef(result);
                        try self.w().writeAll(" = ");
                        try self.emitValueRef(v);
                        try self.w().writeAll(";\n");
                    }
                },
                else => {},
            }
        }
    }

    /// Record a result in the current lexical scope so the scope can discard
    /// it on close if it turns out dead (unused values are hard errors).
    fn recordTop(self: *Codegen, result: Value) !void {
        try self.top_vals.append(self.allocator, result);
    }

    fn pushScope(self: *Codegen) !void {
        try self.scope_starts.append(self.allocator, self.top_vals.len);
    }

    /// Close a scope: discard every value it declared (a discard is a use;
    /// discarding live values is harmless), then forget them.
    fn popScope(self: *Codegen) !void {
        const start = self.scope_starts.pop().?;
        if (self.top_vals.len > start) {
            try self.writeIndent();
            try self.w().writeAll("_ = .{ ");
            for (self.top_vals.slice()[start..], 0..) |v, k| {
                if (k != 0) try self.w().writeAll(", ");
                try self.emitValueRef(v);
            }
            try self.w().writeAll(" };\n");
            self.top_vals.len = start;
        }
    }

    fn emitInst(self: *Codegen, inst: Mir.Inst) Error!void {
        const data = self.mir.instData(inst);
        const result = self.mir.instResult(inst);

        switch (data) {
            .unary => |u| {
                try self.recordTop(result);
                try self.writeIndent();
                try self.w().writeAll("const ");
                try self.emitValueRef(result);
                try self.w().writeAll(" = ");
                try self.emitUnary(u.opcode, u.arg);
                try self.w().writeAll(";\n");
            },
            .binary => |b| {
                try self.recordTop(result);
                try self.writeIndent();
                try self.w().writeAll("const ");
                try self.emitValueRef(result);
                try self.w().writeAll(" = ");
                try self.emitBinary(b.opcode, b.args[0], b.args[1]);
                try self.w().writeAll(";\n");
            },
            .ternary => |t| {
                try self.recordTop(result);
                try self.writeIndent();
                try self.w().writeAll("const ");
                try self.emitValueRef(result);
                try self.w().writeAll(" = if (");
                try self.emitValueRef(t.args[0]);
                try self.w().writeAll(".val() != 0.0) ");
                try self.emitValueRef(t.args[1]);
                try self.w().writeAll(" else ");
                try self.emitValueRef(t.args[2]);
                try self.w().writeAll(";\n");
            },
            .branch => |br| {
                try self.writeIndent();
                try self.w().writeAll("if (");
                try self.emitValueRef(br.cond);
                try self.w().writeAll(".val() != 0.0) {\n");
                self.indent += 1;
                try self.pushScope();
                try self.emitBranchBody(br.then_dst);
                try self.popScope();
                self.indent -= 1;
                try self.writeIndent();
                try self.w().writeAll("} else {\n");
                self.indent += 1;
                try self.pushScope();
                try self.emitBranchBody(br.else_dst);
                try self.popScope();
                self.indent -= 1;
                try self.writeIndent();
                try self.w().writeAll("}\n");
            },
            .jump => {},
            .call => |c| {
                const call_name = self.mir.callName(c.func_ref);
                const args = self.mir.getExtraValues(c.args_start, c.args_len);
                if (isVoidCall(call_name)) {
                    // Side-effect-only calls: $display, $warning, etc.
                    return;
                }
                try self.recordTop(result);
                try self.writeIndent();
                try self.w().writeAll("const ");
                try self.emitValueRef(result);
                try self.w().writeAll(" = ");
                try self.emitCall(call_name, args);
                try self.w().writeAll(";\n");
            },
            .phi => {},
        }
    }

    fn isVoidCall(call_name: []const u8) bool {
        const void_calls = [_][]const u8{
            "$strobe", "$display", "$write", "$monitor", "$debug",
            "$warning", "$error", "$fatal", "$info", "$finish", "$stop",
        };
        for (void_calls) |vc| {
            if (std.mem.eql(u8, call_name, vc)) return true;
        }
        return false;
    }

    fn emitBranchBody(self: *Codegen, target: Block) !void {
        try self.emitPhiAssigns(target);
        self.block_emitted[target.id()] = true;

        const prev = self.current_block;
        self.current_block = target;
        defer self.current_block = prev;

        var inst_it = self.mir.blockInsts(target);
        while (inst_it.next()) |inst| {
            switch (self.mir.instData(inst)) {
                .phi => {},
                else => try self.emitInst(inst),
            }
        }
    }

    /// Emit a comparison as an S: S.con(1.0) when true, S.con(0.0) otherwise.
    /// Topology decided on values; result stays S so it can feed S arithmetic
    /// or a branch/ternary condition (both read .val()).
    fn emitCmpS(self: *Codegen, a: Value, op: []const u8, b: Value, intcmp: bool) !void {
        // Comparisons resolve on values: float compares read .val() (f64),
        // integer compares round-trip through i64.
        try self.w().writeAll("S.con(if (");
        if (intcmp) try self.w().writeAll("@as(i64, @intFromFloat(");
        try self.emitValueRef(a);
        try self.w().writeAll(if (intcmp) ".val()))" else ".val()");
        try self.w().writeAll(op);
        if (intcmp) try self.w().writeAll("@as(i64, @intFromFloat(");
        try self.emitValueRef(b);
        try self.w().writeAll(if (intcmp) ".val()))" else ".val()");
        try self.w().writeAll(") 1.0 else 0.0)");
    }

    /// Emit an integer bit/round op via .val() round-trip. Integer arithmetic
    /// is topology (loop counters, indices); derivative through it is zero, so
    /// wrapping the f64 result back in S.con is correct.
    fn emitIntBinS(self: *Codegen, a: Value, op: []const u8, b: Value, shift: bool) !void {
        try self.w().writeAll("S.con(@floatFromInt(@as(i64, @intFromFloat(");
        try self.emitValueRef(a);
        try self.w().print(".val())){s}", .{op});
        if (shift) {
            try self.w().writeAll("@as(u6, @intFromFloat(");
            try self.emitValueRef(b);
            try self.w().writeAll(".val()))))");
        } else {
            try self.w().writeAll("@as(i64, @intFromFloat(");
            try self.emitValueRef(b);
            try self.w().writeAll(".val()))))");
        }
    }

    fn emitUnary(self: *Codegen, op: Opcode, arg: Value) !void {
        switch (op) {
            .fneg, .ineg => {
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".neg()");
            },
            .sqrt => {
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".sqrt()");
            },
            .exp => {
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".exp()");
            },
            .ln, .log => {
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".log()");
            },
            .sin => {
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".sin()");
            },
            .cos => {
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".cos()");
            },
            .tan => {
                // tan = sin/cos, keeps the analytic derivative.
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".sin().div(");
                try self.emitGroupedValue(arg);
                try self.w().writeAll(".cos())");
            },
            .asin, .acos, .atan, .sinh, .cosh, .tanh, .asinh, .acosh, .atanh => {
                try self.w().print("z{s}(S, ", .{op.name()});
                try self.emitValueRef(arg);
                try self.w().writeByte(')');
            },
            .floor => {
                try self.w().writeAll("S.con(@floor(");
                try self.emitValueRef(arg);
                try self.w().writeAll(".val()))");
            },
            .ceil => {
                try self.w().writeAll("S.con(@ceil(");
                try self.emitValueRef(arg);
                try self.w().writeAll(".val()))");
            },
            .clog2 => {
                try self.w().writeAll("S.con(@ceil(@log2(");
                try self.emitValueRef(arg);
                try self.w().writeAll(".val())))");
            },
            .fi_cast, .if_cast, .opt_barrier,
            .bi_cast, .ib_cast, .fb_cast, .bf_cast,
            => {
                try self.emitValueRef(arg);
            },
            .inot, .bnot => {
                try self.w().writeAll("S.con(if (");
                try self.emitValueRef(arg);
                try self.w().writeAll(".val() == 0.0) 1.0 else 0.0)");
            },
            else => {
                try self.w().print("@compileError(\"unsupported unary: {s}\")", .{op.name()});
            },
        }
    }

    fn emitGroupedValue(self: *Codegen, val: Value) !void {
        try self.w().writeByte('(');
        try self.emitValueRef(val);
        try self.w().writeByte(')');
    }

    fn emitMethod(self: *Codegen, a: Value, method: []const u8, b: Value) !void {
        try self.emitGroupedValue(a);
        try self.w().print(".{s}(", .{method});
        try self.emitValueRef(b);
        try self.w().writeByte(')');
    }

    fn emitBinary(self: *Codegen, op: Opcode, a: Value, b: Value) !void {
        switch (op) {
            .fadd => try self.emitMethod(a, "add", b),
            .fsub => try self.emitMethod(a, "sub", b),
            .fmul => try self.emitMethod(a, "mul", b),
            .fdiv => try self.emitMethod(a, "div", b),
            .pow => {
                try self.w().writeAll("zpow(S, ");
                try self.emitValueRef(a);
                try self.w().writeAll(", ");
                try self.emitValueRef(b);
                try self.w().writeByte(')');
            },
            .hypot => {
                // sqrt(a*a + b*b), fully in S.
                try self.emitGroupedValue(a);
                try self.w().writeAll(".mul(");
                try self.emitValueRef(a);
                try self.w().writeAll(").add(");
                try self.emitGroupedValue(b);
                try self.w().writeAll(".mul(");
                try self.emitValueRef(b);
                try self.w().writeAll(")).sqrt()");
            },
            .atan2 => {
                try self.w().writeAll("zatan2(S, ");
                try self.emitValueRef(a);
                try self.w().writeAll(", ");
                try self.emitValueRef(b);
                try self.w().writeByte(')');
            },
            .flt => try self.emitCmpS(a, " < ", b, false),
            .fgt => try self.emitCmpS(a, " > ", b, false),
            .fge => try self.emitCmpS(a, " >= ", b, false),
            .fle => try self.emitCmpS(a, " <= ", b, false),
            .feq => try self.emitCmpS(a, " == ", b, false),
            .fne => try self.emitCmpS(a, " != ", b, false),
            .ilt => try self.emitCmpS(a, " < ", b, true),
            .igt => try self.emitCmpS(a, " > ", b, true),
            .ige => try self.emitCmpS(a, " >= ", b, true),
            .ile => try self.emitCmpS(a, " <= ", b, true),
            .ieq => try self.emitCmpS(a, " == ", b, true),
            .ine => try self.emitCmpS(a, " != ", b, true),
            .iadd => try self.emitMethod(a, "add", b),
            .isub => try self.emitMethod(a, "sub", b),
            .imul => try self.emitMethod(a, "mul", b),
            .idiv => try self.emitIntBinS(a, " / ", b, false),
            .irem => try self.emitIntBinS(a, " % ", b, false),
            .ishl => try self.emitIntBinS(a, " << ", b, true),
            .ishr => try self.emitIntBinS(a, " >> ", b, true),
            .iand => try self.emitIntBinS(a, " & ", b, false),
            .ior => try self.emitIntBinS(a, " | ", b, false),
            .ixor => try self.emitIntBinS(a, " ^ ", b, false),
            .frem => {
                try self.w().writeAll("S.con(@mod(");
                try self.emitValueRef(a);
                try self.w().writeAll(".val(), ");
                try self.emitValueRef(b);
                try self.w().writeAll(".val()))");
            },
            else => {
                try self.w().print("@compileError(\"unsupported binary: {s}\")", .{op.name()});
            },
        }
    }

    fn emitCall(self: *Codegen, call_name: []const u8, args: []const Value) !void {
        if (std.mem.eql(u8, call_name, "$limexp") or std.mem.eql(u8, call_name, "limexp")) {
            // Linearized exp past a critical voltage (aids convergence). Value
            // decides the branch; each branch carries its own S derivative.
            try self.w().writeAll("blk: { const _arg = ");
            try self.emitValueRef(args[0]);
            try self.w().writeAll(
                \\; const _vcrit: f64 = 34.0;
                \\break :blk if (_arg.val() > _vcrit) _arg.addC(-_vcrit).addC(1.0).scale(@exp(_vcrit)) else _arg.exp(); }
            );
            return;
        }
        if (std.mem.eql(u8, call_name, "$ddt") or std.mem.eql(u8, call_name, "ddt")) {
            try self.emitValueRef(args[0]);
            return;
        }
        if (std.mem.eql(u8, call_name, "$temperature")) {
            // Device temperature (Kelvin) from the instance; `t` is TIME.
            try self.w().writeAll("S.con(inst.temp)");
            return;
        }
        if (std.mem.eql(u8, call_name, "$abstime")) {
            // Same param slot as $temperature; split when the analysis driver
            // passes separate time vs temp.
            try self.w().writeAll("S.con(t)");
            return;
        }
        if (std.mem.eql(u8, call_name, "$param_given")) {
            // Always 1.0: all params are "given" via defaults.
            try self.w().writeAll("S.con(1.0)");
            return;
        }
        if (std.mem.eql(u8, call_name, "$limit")) {
            if (args.len >= 1) {
                try self.emitValueRef(args[0]);
                return;
            }
            try self.w().writeAll("S.con(0.0)");
            return;
        }
        if (std.mem.eql(u8, call_name, "analysis") or
            std.mem.eql(u8, call_name, "initial_step") or
            std.mem.eql(u8, call_name, "final_step") or
            std.mem.eql(u8, call_name, "white_noise") or
            std.mem.eql(u8, call_name, "flicker_noise") or
            std.mem.eql(u8, call_name, "noise_table") or
            std.mem.eql(u8, call_name, "noise_table_log") or
            std.mem.startsWith(u8, call_name, "$"))
        {
            // Solver hints, analysis-phase probes and noise sources have no
            // static-eval contribution.
            try self.w().writeAll("S.con(0.0)");
            return;
        }
        try self.w().print("@compileError(\"unknown call: {s}\")", .{call_name});
    }

    fn emitValueRef(self: *Codegen, val: Value) !void {
        const resolved = self.mir.resolveAlias(val);
        switch (resolved) {
            .undef => try self.w().writeAll("S.con(0.0)"),
            .f_zero, .zero, .false_ => try self.w().writeAll("S.con(0.0)"),
            .one, .f_one, .true_ => try self.w().writeAll("S.con(1.0)"),
            .f_neg_one, .neg_one => try self.w().writeAll("S.con(-1.0)"),
            .f_two => try self.w().writeAll("S.con(2.0)"),
            .f_ten => try self.w().writeAll("S.con(10.0)"),
            .f_inf => try self.w().writeAll("S.con(inf_)"),
            _ => {
                switch (self.mir.valueDef(resolved)) {
                    .f_const => |c| try self.w().print("S.con({e})", .{c}),
                    .i_const => |c| try self.w().print("S.con(@as(f64, {d}))", .{c}),
                    // Terminal read: index into node_order = the x[u] vector,
                    // already the incoming S.
                    .block_param => |bp| {
                        try self.w().print("x[{d}]", .{bp.index});
                    },
                    // Runtime parameter read: model.<name>, lifted to S. Honors
                    // the .model card instead of inlining the default.
                    .param_ref => |idx| {
                        const p = self.lower.params.slice()[idx];
                        switch (p.ty) {
                            .real => {
                                try self.w().writeAll("S.con(@as(f64, model.");
                                try emit.writeIdent(self.w(), p.name);
                                try self.w().writeAll("))");
                            },
                            .integer => {
                                try self.w().writeAll("S.con(@as(f64, @floatFromInt(model.");
                                try emit.writeIdent(self.w(), p.name);
                                try self.w().writeAll(")))");
                            },
                            .string => try self.w().writeAll("S.con(0.0)"),
                        }
                    },
                    else => try self.w().print("v{d}", .{@intFromEnum(resolved)}),
                }
            },
        }
    }

    fn emitConstValue(self: *Codegen, val: Value) !void {
        switch (val) {
            .undef => try self.w().writeAll("0"),
            .f_zero, .zero => try self.w().writeAll("0"),
            .one => try self.w().writeAll("1"),
            .f_one => try self.w().writeAll("1.0"),
            .f_neg_one => try self.w().writeAll("-1.0"),
            .f_two => try self.w().writeAll("2.0"),
            .f_ten => try self.w().writeAll("10.0"),
            .neg_one => try self.w().writeAll("-1"),
            .f_inf => try self.w().writeAll("inf_"),
            .false_ => try self.w().writeAll("0"),
            .true_ => try self.w().writeAll("1"),
            _ => {
                switch (self.mir.valueDef(val)) {
                    .f_const => |c| try self.w().print("{e}", .{c}),
                    .i_const => |c| try self.w().print("{d}", .{c}),
                    // A comptime context (loop bound / array size) can't read a
                    // runtime model field; fall back to the param's default.
                    .param_ref => |idx| try self.emitConstValue(self.lower.params.slice()[idx].default orelse .f_zero),
                    else => try self.w().writeAll("0"),
                }
            },
        }
    }
};
