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
    defer cg.analog_ops.deinit(allocator);
    cg.fold_cache = try allocator.alloc(?f64, lower.params.len);
    defer allocator.free(cg.fold_cache);
    @memset(cg.fold_cache, null);
    defer cg.phi_vals.deinit(allocator);

    try cg.emitModule();
    return cg.out.toOwnedSlice();
}

// ponytail: analog operator kinds that need codegen beyond a bare S.con(0.0) stub.
const AnalogOpKind = enum {
    transition, slew, absdelay, cross, above, timer, last_crossing, idtmod,
    laplace_nd, laplace_np, laplace_zd, laplace_zp,
    zi_nd, zi_np, zi_zd, zi_zp,
};

const AnalogOpInfo = struct {
    kind: AnalogOpKind,
    inst: Mir.Inst,
    index: u32,
    args_start: u32,
    args_len: u16,
    // Filter coefficients extracted at scan time (laplace/zi ops only).
    // Layout: num[0..num_len], den[0..den_len], sample_period (zi only).
    num_coeffs: [8]f64 = .{0} ** 8,
    den_coeffs: [8]f64 = .{0} ** 8,
    num_len: u8 = 0,
    den_len: u8 = 0,
    sample_period: f64 = 0,
};

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
    // ponytail: memoization for constFold — avoids re-evaluating param default subgraphs
    fold_cache: []?f64 = &.{},
    // ponytail: pre-computed surviving (un-aliased) phi values, shared across eval/q calls
    phi_vals: Buf(Value) = .{},
    // ponytail: tracked analog operator instances for Instance/State codegen
    analog_ops: Buf(AnalogOpInfo) = .{},
    // per-kind counters for assigning sequential indices
    op_kind_counts: [@typeInfo(AnalogOpKind).@"enum".fields.len]u32 =
        .{0} ** @typeInfo(AnalogOpKind).@"enum".fields.len,
    // current instruction being emitted (for analog op lookup in emitCall)
    current_emit_inst: Mir.Inst = .none,

    fn w(self: *Codegen) *std.Io.Writer {
        return &self.out.writer;
    }

    fn writeIndent(self: *Codegen) !void {
        for (0..self.indent) |_| try self.w().writeAll("    ");
    }

    fn classifyAnalogOp(name: []const u8) ?AnalogOpKind {
        const map = std.StaticStringMap(AnalogOpKind).initComptime(.{
            .{ "transition", .transition },
            .{ "slew", .slew },
            .{ "absdelay", .absdelay },
            .{ "cross", .cross },
            .{ "above", .above },
            .{ "timer", .timer },
            .{ "last_crossing", .last_crossing },
            .{ "idtmod", .idtmod },
            .{ "laplace_nd", .laplace_nd },
            .{ "laplace_np", .laplace_np },
            .{ "laplace_zd", .laplace_zd },
            .{ "laplace_zp", .laplace_zp },
            .{ "zi_nd", .zi_nd },
            .{ "zi_np", .zi_np },
            .{ "zi_zd", .zi_zd },
            .{ "zi_zp", .zi_zp },
        });
        return map.get(name);
    }

    /// Pre-scan MIR for analog operator calls, assigning each a per-kind index.
    fn scanAnalogOps(self: *Codegen) !void {
        var block_it = self.mir.blockIter();
        while (block_it.next()) |block| {
            var inst_it = self.mir.blockInsts(block);
            while (inst_it.next()) |inst| {
                switch (self.mir.instData(inst)) {
                    .call => |c| {
                        const call_name = self.mir.callName(c.func_ref);
                        if (classifyAnalogOp(call_name)) |kind| {
                            const ki = @intFromEnum(kind);
                            const idx = self.op_kind_counts[ki];
                            self.op_kind_counts[ki] += 1;
                            var info = AnalogOpInfo{
                                .kind = kind,
                                .inst = inst,
                                .index = idx,
                                .args_start = c.args_start,
                                .args_len = c.args_len,
                            };
                            // Extract filter coefficients from flattened MIR args.
                            if (isFilterKind(kind)) {
                                self.extractFilterCoeffs(&info, c.args_start, c.args_len);
                            }
                            try self.analog_ops.append(self.allocator, info);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn isFilterKind(kind: AnalogOpKind) bool {
        return switch (kind) {
            .laplace_nd, .laplace_np, .laplace_zd, .laplace_zp,
            .zi_nd, .zi_np, .zi_zd, .zi_zp,
            => true,
            else => false,
        };
    }

    /// Extract numerator/denominator coefficients from the flattened MIR args
    /// produced by Lower.emitFilterCall. Format:
    ///   [input, n_len, n0, n1, ..., d_len, d0, d1, ..., (T for zi)]
    fn extractFilterCoeffs(self: *const Codegen, info: *AnalogOpInfo, args_start: u32, args_len: u16) void {
        const args = self.mir.getExtraValues(args_start, args_len);
        if (args.len < 2) return;

        var pos: usize = 1; // skip args[0] = input

        // Numerator: args[1] = n_len, followed by n_len coefficients
        if (pos < args.len) {
            const n_len_f = self.constFold(args[pos], 0) orelse return;
            const n_len: usize = @intFromFloat(@max(0, @min(8, n_len_f)));
            info.num_len = @intCast(n_len);
            pos += 1;
            for (0..n_len) |i| {
                if (pos < args.len) {
                    info.num_coeffs[i] = self.constFold(args[pos], 0) orelse 0;
                    pos += 1;
                }
            }
        }

        // Denominator: args[pos] = d_len, followed by d_len coefficients
        if (pos < args.len) {
            const d_len_f = self.constFold(args[pos], 0) orelse return;
            const d_len: usize = @intFromFloat(@max(0, @min(8, d_len_f)));
            info.den_len = @intCast(d_len);
            pos += 1;
            for (0..d_len) |i| {
                if (pos < args.len) {
                    info.den_coeffs[i] = self.constFold(args[pos], 0) orelse 0;
                    pos += 1;
                }
            }
        }

        // Sample period T (zi_* only)
        if (pos < args.len) {
            info.sample_period = self.constFold(args[pos], 0) orelse 0;
        }
    }

    fn findAnalogOp(self: *const Codegen, inst: Mir.Inst) ?AnalogOpInfo {
        for (self.analog_ops.slice()) |op| {
            if (op.inst == inst) return op;
        }
        return null;
    }

    fn opNeedsInstance(kind: AnalogOpKind) bool {
        return switch (kind) {
            .transition, .slew, .last_crossing, .idtmod, .absdelay,
            .laplace_nd, .laplace_np, .laplace_zd, .laplace_zp,
            .zi_nd, .zi_np, .zi_zd, .zi_zp,
            => true,
            // Events: need Instance fields for firing detection + input tracking
            .cross, .above, .timer => true,
        };
    }

    fn opMaxArgs(kind: AnalogOpKind) u8 {
        return switch (kind) {
            .transition => 4, // expr, td, tr, tf
            .slew => 3, // expr, max_pos_rate, max_neg_rate
            .idtmod => 4, // expr, ic, modulus, offset
            .absdelay => 2, // expr, td
            .last_crossing => 2, // expr, dir
            .timer => 2, // start, period
            .cross, .above => 3, // expr, dir, timestep
            .laplace_nd, .laplace_np, .laplace_zd, .laplace_zp => 3, // expr, num/zeros, den/poles
            .zi_nd, .zi_np, .zi_zd, .zi_zp => 4, // expr, num/zeros, den/poles, T
        };
    }

    fn hasAnyStatefulOps(self: *const Codegen) bool {
        for (self.analog_ops.slice()) |op| {
            if (opNeedsInstance(op.kind)) return true;
        }
        return false;
    }

    fn emitModule(self: *Codegen) !void {
        // Pre-scan MIR for analog operator calls before emitting anything.
        try self.scanAnalogOps();
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

        // Instance: temp + per-operator state fields.
        try self.w().writeAll("pub const Instance = struct {\n");
        try self.w().writeAll("    temp: f32 = 300.15,\n");
        if (self.hasAnyStatefulOps()) {
            try self.w().writeAll("    _sim_t: f64 = 0,\n");
            try self.w().writeAll("    _sim_t_prev: f64 = 0,\n");
        }
        for (self.analog_ops.slice()) |op| {
            if (!opNeedsInstance(op.kind)) continue;
            const tag = @tagName(op.kind);
            const nargs = opMaxArgs(op.kind);
            // _args: eval stashes all operator arguments here each iteration
            try self.w().print("    _{s}_{d}_args: [{d}]f64 = .{{0}} ** {d},\n", .{ tag, op.index, nargs, nargs });
            switch (op.kind) {
                .transition => {
                    try self.w().print("    _{s}_{d}_val: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_origin: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_target_prev: f64 = 0,\n", .{ tag, op.index });
                },
                .slew => {
                    try self.w().print("    _{s}_{d}_val: f64 = 0,\n", .{ tag, op.index });
                },
                .last_crossing => {
                    try self.w().print("    _{s}_{d}_time: f64 = -1,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_prev: f64 = 0,\n", .{ tag, op.index });
                },
                .idtmod => {
                    try self.w().print("    _{s}_{d}_val: f64 = 0,\n", .{ tag, op.index });
                },
                .absdelay => {
                    try self.w().print("    _{s}_{d}_val: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_buf: [64]f64 = .{{0}} ** 64,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_buf_idx: u32 = 0,\n", .{ tag, op.index });
                },
                .laplace_nd, .laplace_np, .laplace_zd, .laplace_zp,
                .zi_nd, .zi_np, .zi_zd, .zi_zp,
                => {
                    try self.w().print("    _{s}_{d}_val: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_x: [4]f64 = .{{0}} ** 4,\n", .{ tag, op.index });
                },
                .cross => {
                    try self.w().print("    _{s}_{d}_prev: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_fired: f64 = 0,\n", .{ tag, op.index });
                },
                .above => {
                    try self.w().print("    _{s}_{d}_prev: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_fired: f64 = 0,\n", .{ tag, op.index });
                },
                .timer => {
                    try self.w().print("    _{s}_{d}_next: f64 = 0,\n", .{ tag, op.index });
                    try self.w().print("    _{s}_{d}_fired: f64 = 0,\n", .{ tag, op.index });
                },
            }
        }
        try self.w().writeAll("};\n\n");

        try self.w().writeAll("const n_u = contract.nU(Self);\n\n");

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

        // Pre-compute surviving (un-aliased) phis once; reused by both eval and q.
        var block_it_phi = self.mir.blockIter();
        while (block_it_phi.next()) |block| {
            var inst_it = self.mir.blockInsts(block);
            while (inst_it.next()) |inst| {
                switch (self.mir.instData(inst)) {
                    .phi => {
                        const result = self.mir.instResult(inst);
                        if (self.mir.resolveAlias(result) == result) {
                            try self.phi_vals.append(self.allocator, result);
                        }
                    },
                    else => {},
                }
            }
        }

        try self.emitEvalFn("eval", contribs, false);

        var has_reactive = false;
        for (contribs) |c| {
            if (c.react_val != .f_zero and c.react_val != .undef) {
                has_reactive = true;
                break;
            }
        }
        if (has_reactive) {
            try self.w().writeByte('\n');
            try self.emitEvalFn("q", contribs, true);
        }

        // State machine for analog operators that advance per Newton step.
        if (self.hasAnyStatefulOps()) {
            try self.emitStateMachine();
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
                    if (idx < self.fold_cache.len) {
                        if (self.fold_cache[idx]) |cached| return cached;
                    }
                    const p = self.lower.params.slice()[idx];
                    const result = self.constFold(p.default orelse return null, depth + 1);
                    if (idx < self.fold_cache.len) {
                        // ponytail: constFold is *const; cache is interior-mutable optimization state
                        @as([*]?f64, @constCast(self.fold_cache.ptr))[idx] = result;
                    }
                    return result;
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
            \\
        , .{fn_name});

        self.indent = 1;

        // Stash simulation time into Instance for updateState's dt computation.
        if (self.hasAnyStatefulOps()) {
            try self.w().writeAll("    @constCast(inst)._sim_t = t;\n");
        } else {
            try self.w().writeAll("    _ = &t;\n");
        }
        try self.w().writeAll("    _ = &inst;\n");

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
    /// Uses the pre-computed phi_vals list instead of re-walking all blocks.
    fn scanPhis(self: *Codegen) !void {
        for (self.phi_vals.slice()) |result| {
            try self.writeIndent();
            try self.w().writeAll("var ");
            try self.emitValueRef(result);
            try self.w().writeAll(": S = undefined;\n");
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
                self.current_emit_inst = inst;
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
        // Analog operators: read from Instance state when stateful, or DC passthrough.
        if (classifyAnalogOp(call_name)) |_| {
            if (self.findAnalogOp(self.current_emit_inst)) |op| {
                if (opNeedsInstance(op.kind)) {
                    const tag = @tagName(op.kind);
                    const nargs = opMaxArgs(op.kind);
                    // For filter ops, only stash args[0] (input signal); coefficients
                    // are const-folded at scan time and stored in AnalogOpInfo.
                    const stash_count: usize = if (isFilterKind(op.kind)) 1 else @min(args.len, nargs);
                    // Stash arguments into inst._args for updateState.
                    // blk: pattern avoids polluting the S expression namespace.
                    try self.w().writeAll("blk_op: {\n");
                    self.indent += 1;
                    for (0..stash_count) |ai| {
                        try self.writeIndent();
                        try self.w().print("@constCast(inst)._{s}_{d}_args[{d}] = (", .{ tag, op.index, ai });
                        try self.emitValueRef(args[ai]);
                        try self.w().writeAll(").val();\n");
                    }
                    try self.writeIndent();
                    switch (op.kind) {
                        .last_crossing => try self.w().print(
                            "break :blk_op S.con(inst._{s}_{d}_time);\n", .{ tag, op.index }),
                        .cross, .above => try self.w().print(
                            "break :blk_op S.con(inst._{s}_{d}_fired);\n", .{ tag, op.index }),
                        .timer => try self.w().print(
                            "break :blk_op S.con(inst._{s}_{d}_fired);\n", .{ tag, op.index }),
                        else => try self.w().print(
                            "break :blk_op S.con(inst._{s}_{d}_val);\n", .{ tag, op.index }),
                    }
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.w().writeByte('}');
                    return;
                }
            }
            // Fallback: DC passthrough for filter ops, 0 for events.
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
            try self.w().writeAll("S.con(0.0)");
            return;
        }
        try self.w().print("@compileError(\"unknown call: {s}\")", .{call_name});
    }

    fn emitStateMachine(self: *Codegen) !void {
        try self.w().writeAll(
            \\
            \\pub const State = struct {
            \\    step: u32 = 0,
            \\};
            \\
            \\pub fn initState(_: *const Model, inst: *Instance) State {
            \\
        );
        // Initialize operator output values to their DC-correct initial state.
        for (self.analog_ops.slice()) |op| {
            if (!opNeedsInstance(op.kind)) continue;
            const tag = @tagName(op.kind);
            switch (op.kind) {
                // DC passthrough: output = input at init
                .transition, .slew, .absdelay,
                .laplace_nd, .laplace_np, .laplace_zd, .laplace_zp,
                .zi_nd, .zi_np, .zi_zd, .zi_zp,
                => try self.w().print(
                    "    inst._{s}_{d}_val = inst._{s}_{d}_args[0];\n", .{ tag, op.index, tag, op.index }),
                .last_crossing => {},
                .idtmod => {},
                .cross, .above, .timer => {},
            }
        }
        try self.w().writeAll(
            \\    return .{};
            \\}
            \\
            \\pub fn updateState(_: *const Model, inst: *Instance, _: [n_u]f64, state: *State) contract.UpdateResult {
            \\    state.step += 1;
            \\    const _dt = inst._sim_t - inst._sim_t_prev;
            \\    inst._sim_t_prev = inst._sim_t;
            \\
        );
        for (self.analog_ops.slice()) |op| {
            if (!opNeedsInstance(op.kind)) continue;
            const tag = @tagName(op.kind);
            switch (op.kind) {
                .transition => {
                    // Piecewise-linear ramp: tracks origin/target_prev to compute
                    // constant slope = |target - origin| / rise_or_fall_time.
                    try self.w().print(
                        \\    {{
                        \\        const _target = inst._{s}_{d}_args[0];
                        \\        const _tr = @max(inst._{s}_{d}_args[2], 1e-15);
                        \\        const _tf = @max(inst._{s}_{d}_args[3], 1e-15);
                        \\        const _cur = inst._{s}_{d}_val;
                        \\        if (_target != inst._{s}_{d}_target_prev) {{
                        \\            inst._{s}_{d}_origin = _cur;
                        \\            inst._{s}_{d}_target_prev = _target;
                        \\        }}
                        \\        const _amp = _target - inst._{s}_{d}_origin;
                        \\        const _delta = _target - _cur;
                        \\        if (_delta > 0.0) {{
                        \\            const _rate = @abs(_amp) / _tr;
                        \\            inst._{s}_{d}_val = @min(_cur + _rate * _dt, _target);
                        \\        }} else if (_delta < 0.0) {{
                        \\            const _rate = @abs(_amp) / _tf;
                        \\            inst._{s}_{d}_val = @max(_cur - _rate * _dt, _target);
                        \\        }}
                        \\    }}
                        \\
                    , .{
                        // 10 pairs for transition template
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index,
                    });
                },
                .slew => {
                    // Rate-limited tracking: clamp rate of change to pos/neg limits.
                    try self.w().print(
                        \\    {{
                        \\        const _input = inst._{s}_{d}_args[0];
                        \\        const _pos_rate = inst._{s}_{d}_args[1];
                        \\        const _neg_rate = inst._{s}_{d}_args[2];
                        \\        const _delta = _input - inst._{s}_{d}_val;
                        \\        const _max_up = _pos_rate * _dt;
                        \\        const _max_dn = _neg_rate * _dt;
                        \\        inst._{s}_{d}_val += @min(@max(_delta, _max_dn), _max_up);
                        \\    }}
                        \\
                    , .{
                        // 5 pairs for slew template
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index,
                    });
                },
                .last_crossing => {
                    // Linear interpolation for zero-crossing time.
                    try self.w().print(
                        \\    {{
                        \\        const _cur = inst._{s}_{d}_args[0];
                        \\        const _prev = inst._{s}_{d}_prev;
                        \\        if (_prev * _cur < 0.0) {{
                        \\            const _frac = _prev / (_prev - _cur);
                        \\            inst._{s}_{d}_time = inst._sim_t_prev + _frac * _dt;
                        \\        }}
                        \\        inst._{s}_{d}_prev = _cur;
                        \\    }}
                        \\
                    , .{
                        tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index,
                    });
                },
                .idtmod => {
                    // Circular integrator: integrate input * dt, wrap by modulus.
                    try self.w().print(
                        \\    {{
                        \\        const _input = inst._{s}_{d}_args[0];
                        \\        const _modulus = inst._{s}_{d}_args[2];
                        \\        const _offset = inst._{s}_{d}_args[3];
                        \\        inst._{s}_{d}_val += _input * _dt;
                        \\        if (_modulus > 0.0) {{
                        \\            inst._{s}_{d}_val = @mod(inst._{s}_{d}_val - _offset, _modulus) + _offset;
                        \\        }}
                        \\    }}
                        \\
                    , .{
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index, tag, op.index,
                    });
                },
                .absdelay => {
                    // Ring-buffer delay line: write input, read delayed sample.
                    try self.w().print(
                        \\    {{
                        \\        const _td = inst._{s}_{d}_args[1];
                        \\        const _widx = inst._{s}_{d}_buf_idx % 64;
                        \\        inst._{s}_{d}_buf[_widx] = inst._{s}_{d}_args[0];
                        \\        inst._{s}_{d}_buf_idx +%= 1;
                        \\        const _delay_samples: u32 = @intFromFloat(@max(1.0, @min(63.0, _td / @max(_dt, 1e-30))));
                        \\        const _ridx = (inst._{s}_{d}_buf_idx -% _delay_samples) % 64;
                        \\        inst._{s}_{d}_val = inst._{s}_{d}_buf[_ridx];
                        \\    }}
                        \\
                    , .{
                        // 8 pairs for absdelay template
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index,
                    });
                },
                .laplace_nd, .laplace_np, .laplace_zd, .laplace_zp,
                .zi_nd, .zi_np, .zi_zd, .zi_zp,
                => {
                    try self.emitFilterUpdateState(op);
                },
                .cross => {
                    // Detect zero crossing by sign change.
                    try self.w().print(
                        \\    {{
                        \\        const _cur = inst._{s}_{d}_args[0];
                        \\        const _prev = inst._{s}_{d}_prev;
                        \\        inst._{s}_{d}_fired = if (_prev * _cur < 0.0 or (_prev == 0.0 and _cur != 0.0)) 1.0 else 0.0;
                        \\        inst._{s}_{d}_prev = _cur;
                        \\    }}
                        \\
                    , .{ tag, op.index, tag, op.index, tag, op.index, tag, op.index });
                },
                .above => {
                    // Fire when expression crosses zero from below, or is positive at init.
                    try self.w().print(
                        \\    {{
                        \\        const _cur = inst._{s}_{d}_args[0];
                        \\        const _prev = inst._{s}_{d}_prev;
                        \\        inst._{s}_{d}_fired = if ((_prev <= 0.0 and _cur > 0.0) or (state.step == 0 and _cur > 0.0)) 1.0 else 0.0;
                        \\        inst._{s}_{d}_prev = _cur;
                        \\    }}
                        \\
                    , .{ tag, op.index, tag, op.index, tag, op.index, tag, op.index });
                },
                .timer => {
                    // Fire at start_time and every period thereafter using sim time.
                    try self.w().print(
                        \\    {{
                        \\        const _t_now = inst._sim_t;
                        \\        const _start = inst._{s}_{d}_args[0];
                        \\        const _period = inst._{s}_{d}_args[1];
                        \\        if (_period > 0.0 and inst._{s}_{d}_next > 0.0 and _t_now >= inst._{s}_{d}_next) {{
                        \\            inst._{s}_{d}_fired = 1.0;
                        \\            inst._{s}_{d}_next = inst._{s}_{d}_next + _period;
                        \\        }} else if (_t_now >= _start and inst._{s}_{d}_next == 0.0) {{
                        \\            inst._{s}_{d}_fired = 1.0;
                        \\            inst._{s}_{d}_next = _start + _period;
                        \\        }} else {{
                        \\            inst._{s}_{d}_fired = 0.0;
                        \\        }}
                        \\    }}
                        \\
                    , .{
                        // 11 pairs for timer template
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index, tag, op.index,
                        tag, op.index, tag, op.index,
                    });
                },
            }
        }
        try self.w().writeAll(
            \\    return .ok;
            \\}
            \\
            \\pub fn stateCtl(_: *const Model, _: *Instance, _: *State, _: contract.StateCtlOp) bool {
            \\    return true;
            \\}
            \\
        );
    }

    /// Emit state-space update equations for Laplace/Z-transform filter operators.
    /// Uses coefficients extracted at scan time from AnalogOpInfo.
    fn emitFilterUpdateState(self: *Codegen, op: AnalogOpInfo) !void {
        const tag = @tagName(op.kind);
        const is_zi = switch (op.kind) {
            .zi_nd, .zi_np, .zi_zd, .zi_zp => true,
            else => false,
        };

        // If no coefficients were extracted (non-constant arrays), DC passthrough.
        if (op.den_len == 0) {
            try self.w().print(
                "    inst._{s}_{d}_val = inst._{s}_{d}_args[0];\n",
                .{ tag, op.index, tag, op.index },
            );
            return;
        }

        try self.w().print("    {{\n", .{});
        try self.w().print("        const _u = inst._{s}_{d}_args[0];\n", .{ tag, op.index });

        if (is_zi) {
            // Z-transform: direct difference equation
            // H(z) = N(z)/D(z) = (n0 + n1*z^-1 + ...) / (d0 + d1*z^-1 + ...)
            // d0*y[k] = n0*u[k] + n1*u[k-1] + ... - d1*y[k-1] - d2*y[k-2] - ...
            // State _x stores past values: x[0]=u[k-1], x[1]=u[k-2], x[2]=y[k-1], x[3]=y[k-2]
            const d0 = op.den_coeffs[0];
            if (d0 == 0) {
                try self.w().print("        inst._{s}_{d}_val = _u;\n", .{ tag, op.index });
            } else {
                try self.w().writeAll("        var _acc: f64 = ");
                // Numerator terms
                if (op.num_len > 0) {
                    try self.w().print("{e} * _u", .{op.num_coeffs[0]});
                } else {
                    try self.w().writeAll("_u");
                }
                if (op.num_len > 1) {
                    try self.w().print(" + {e} * inst._{s}_{d}_x[0]", .{ op.num_coeffs[1], tag, op.index });
                }
                if (op.num_len > 2) {
                    try self.w().print(" + {e} * inst._{s}_{d}_x[1]", .{ op.num_coeffs[2], tag, op.index });
                }
                // Denominator feedback terms
                if (op.den_len > 1) {
                    try self.w().print(" - {e} * inst._{s}_{d}_x[2]", .{ op.den_coeffs[1], tag, op.index });
                }
                if (op.den_len > 2) {
                    try self.w().print(" - {e} * inst._{s}_{d}_x[3]", .{ op.den_coeffs[2], tag, op.index });
                }
                try self.w().writeAll(";\n");
                try self.w().print("        _acc /= {e};\n", .{d0});
                // Shift state: x[1]=x[0], x[0]=u, x[3]=x[2], x[2]=y
                try self.w().print("        inst._{s}_{d}_x[1] = inst._{s}_{d}_x[0];\n", .{ tag, op.index, tag, op.index });
                try self.w().print("        inst._{s}_{d}_x[0] = _u;\n", .{ tag, op.index });
                try self.w().print("        inst._{s}_{d}_x[3] = inst._{s}_{d}_x[2];\n", .{ tag, op.index, tag, op.index });
                try self.w().print("        inst._{s}_{d}_x[2] = _acc;\n", .{ tag, op.index });
                try self.w().print("        inst._{s}_{d}_val = _acc;\n", .{ tag, op.index });
            }
        } else {
            // Laplace s-domain: backward Euler discretization
            // H(s) = N(s)/D(s)
            // First-order: H(s) = (n0 + n1*s) / (d0 + d1*s)
            //   Backward Euler s ≈ (1 - z^-1)/dt:
            //   y[k] = (n0*dt*u[k] + n1*u[k] + (d1 - n1)*y[k-1] / dt) / (d0*dt + d1) ... nah
            // Simpler: state-space x' = A*x + B*u, y = C*x + D*u
            //   1st order: A=-d0/d1, B=1/d1, C=n0-n1*d0/d1, D=n1/d1
            //   Backward Euler: x[k] = (x[k-1] + dt*B*u) / (1 - dt*A)
            if (op.den_len == 1) {
                // Zero-order: H(s) = n0/d0, pure gain
                const gain = if (op.num_len > 0) op.num_coeffs[0] / op.den_coeffs[0] else 1.0;
                try self.w().print("        inst._{s}_{d}_val = {e} * _u;\n", .{ tag, op.index, gain });
            } else if (op.den_len >= 2) {
                // First-order (or higher — approximate as first-order using d0, d1 only)
                const d0 = op.den_coeffs[0];
                const d1 = op.den_coeffs[1];
                const n0 = if (op.num_len > 0) op.num_coeffs[0] else 1.0;
                const n1 = if (op.num_len > 1) op.num_coeffs[1] else 0.0;
                // State-space: A = -d0/d1, B = 1/d1
                // C = n0 - n1*d0/d1, D = n1/d1
                const A = -d0 / d1;
                const B = 1.0 / d1;
                const C = n0 - n1 * d0 / d1;
                const D = n1 / d1;
                // Backward Euler: x[k] = (x[k-1] + dt*B*u) / (1 - dt*A)
                // y[k] = C*x[k] + D*u
                try self.w().print("        const _x_prev = inst._{s}_{d}_x[0];\n", .{ tag, op.index });
                try self.w().print("        const _x_new = (_x_prev + _dt * {e} * _u) / (1.0 - _dt * {e});\n", .{ B, A });
                try self.w().print("        inst._{s}_{d}_x[0] = _x_new;\n", .{ tag, op.index });
                try self.w().print("        inst._{s}_{d}_val = {e} * _x_new + {e} * _u;\n", .{ tag, op.index, C, D });
            } else {
                try self.w().print("        inst._{s}_{d}_val = _u;\n", .{ tag, op.index });
            }
        }
        try self.w().print("    }}\n", .{});
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
