//! Verilog device codegen: a DeviceSpec (ports + Zig logic statements) in,
//! a contract-shaped Zig device file out. Reads top-down as the generated
//! file does: header → topology → Model/Instance → State → helpers →
//! evalBits → eval → state machine → shared dyn ABI.

const std = @import("std");
const emit = @import("emit");

const isIdentChar = emit.isIdentChar;

/// Identifiers this backend declares in the generated module; a port with one
/// of these names would shadow (not fail to parse), so they are rejected on
/// top of the shared Zig-legality check. This set is specific to the digital
/// pin namespace and does not apply to the Verilog-A backend.
const reserved_idents = std.StaticStringMap(void).initComptime(.{
    .{"U"},          .{"Model"},           .{"Instance"},        .{"State"},
    .{"Self"},       .{"contract"},        .{"n_u"},             .{"num_ports"},
    .{"u_kinds"},    .{"g_pattern_override"}, .{"initState"},    .{"updateState"},
    .{"eval"},       .{"evalBits"},        .{"threshold"},       .{"changed"},
    .{"applyDrive"}, .{"shl64"},           .{"shr64"},           .{"sar64"},
    .{"inputs"},     .{"outputs"},         .{"cur_outputs"},     .{"next_inputs"},
    .{"prev_inputs"}, .{"prev_outputs"},   .{"result"},          .{"state"},
    .{"model"},      .{"id"},              .{"x"},               .{"out"},
    .{"g"},          .{"node"},            .{"branch"},          .{"target"},
    .{"i_branch"},   .{"bit"},             .{"row"},             .{"col"},
    .{"u"},          .{"t"},               .{"v"},               .{"mid"},
    .{"res"},        .{"xs"},              .{"AD"},              .{"setParam"},
    .{"zpicey_abi_version"}, .{"zpicey_n_u"}, .{"zpicey_num_ports"},
    .{"zpicey_model_size"}, .{"zpicey_instance_size"}, .{"zpicey_init_model"},
    .{"zpicey_init_instance"}, .{"zpicey_set_model_param"}, .{"zpicey_set_instance_param"},
    .{"zpicey_eval_ad"}, .{"zpicey_state_size"}, .{"zpicey_init_state"},
    .{"zpicey_update_state"}, .{"std"}, .{"instance"}, .{"strength"},
});

/// Shared Zig legality plus this backend's reserved-name set.
pub fn validateIdent(name: []const u8) Error!void {
    emit.validateIdent(name) catch return Error.InvalidName;
    if (reserved_idents.has(name)) return Error.InvalidName;
}

pub const Error = error{
    InvalidName,
    InvalidPort,
} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub const PortDirection = enum(u1) {
    input,
    output,
};

pub const Port = struct {
    name: []const u8,
    direction: PortDirection,
    /// Bits are packed into a single u64, so 1..64.
    width: u16 = 1,
};

pub const ClockGroup = struct {
    clk_port: []const u8,
    edge: enum(u1) { pos, neg },
    /// Names of output ports driven by this clock (registered outputs).
    registered: []const []const u8,
    /// Zig statements executed on clock edge. Must set `_<name>: u64` for each registered output.
    next_state_stmts: []const u8,
};

pub const DeviceSpec = struct {
    name: []const u8,
    ports: []const Port,
    /// Zig statements that declare `_<output_name>: u64` for each output port.
    /// For combinational outputs: compute from input variables.
    /// For registered outputs: set `_<name> = prev_out_<name>;` (hold current value).
    eval_stmts: []const u8,
    clocks: []const ClockGroup = &.{},
    default_vil: f32 = 0.8,
    default_vih: f32 = 2.0,
    default_vlo: f32 = 0.0,
    default_vhi: f32 = 1.8,
    default_rout: f32 = 1.0,
};

pub fn generateDevice(allocator: std.mem.Allocator, spec: DeviceSpec) Error![]u8 {
    // ── Validate + measure — no port lists are built, the spec is iterated
    // filtered by direction wherever inputs or outputs are needed ──────────
    try validateIdent(spec.name);
    var total_in: usize = 0;
    var total_out: usize = 0;
    for (spec.ports) |port| {
        try validateIdent(port.name);
        if (port.width == 0 or port.width > 64) return Error.InvalidPort;
        switch (port.direction) {
            .input => total_in += port.width,
            .output => total_out += port.width,
        }
    }
    if (total_in == 0 or total_out == 0) return Error.InvalidPort;
    // contract requires U to be a dense enum(u8): one unknown per input bit,
    // output bit, and output branch.
    if (total_in + 2 * total_out > 256) return Error.InvalidPort;

    const sequential = spec.clocks.len > 0;

    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    const w = &writer.writer;

    // ── Header ─────────────────────────────────────────────────────────────
    try w.writeAll(
        \\const std = @import("std");
        \\const contract = @import("contract");
        \\const Self = @This();
        \\const n_u = contract.nU(Self);
        \\
        \\inline fn changed(a: anytype, b: @TypeOf(a)) bool {
        \\    inline for (a, b) |av, bv| {
        \\        if (av != bv) return true;
        \\    }
        \\    return false;
        \\}
        \\
        \\
    );

    // ── Topology: U enum (input bits, output bits, output branches) ───────
    try w.writeAll("pub const U = enum(u8) {\n");
    for (spec.ports) |p| {
        if (p.direction != .input) continue;
        for (0..p.width) |bit| {
            try w.writeAll("    ");
            try emitPinName(w, p.name, p.width, @intCast(bit));
            try w.writeAll(",\n");
        }
    }
    for (spec.ports) |p| {
        if (p.direction != .output) continue;
        for (0..p.width) |bit| {
            try w.writeAll("    ");
            try emitPinName(w, p.name, p.width, @intCast(bit));
            try w.writeAll(",\n");
        }
    }
    for (spec.ports) |p| {
        if (p.direction != .output) continue;
        for (0..p.width) |bit| {
            try w.writeAll("    ");
            try emitPinName(w, p.name, p.width, @intCast(bit));
            try w.writeAll("_branch,\n");
        }
    }
    try w.writeAll("};\n\n");

    try w.print("pub const num_ports: usize = {d};\n\n", .{total_in + total_out});

    try w.writeAll("pub const u_kinds = [n_u]contract.UnknownKind{\n");
    for (0..total_in + total_out) |_| try w.writeAll("    .voltage,\n");
    for (0..total_out) |_| try w.writeAll("    .current,\n");
    try w.writeAll("};\n\n");

    try w.writeAll("pub const g_pattern_override = [_]contract.Entry(n_u){\n");
    for (spec.ports) |p| {
        if (p.direction != .output) continue;
        for (0..p.width) |bit| {
            const pairs = [_][2][]const u8{
                .{ "", "_branch" },
                .{ "_branch", "" },
                .{ "_branch", "_branch" },
            };
            for (pairs) |pair| {
                try w.writeAll("    .{ .row = @intFromEnum(U.");
                try emitPinName(w, p.name, p.width, @intCast(bit));
                try w.writeAll(pair[0]);
                try w.writeAll("), .col = @intFromEnum(U.");
                try emitPinName(w, p.name, p.width, @intCast(bit));
                try w.writeAll(pair[1]);
                try w.writeAll(") },\n");
            }
        }
    }
    try w.writeAll("};\n\n");

    // ── Model + Instance ───────────────────────────────────────────────────
    try w.print(
        \\pub const Model = struct {{
        \\    vil: f32 = {d},
        \\    vih: f32 = {d},
        \\    vlo: f32 = {d},
        \\    vhi: f32 = {d},
        \\    rout: f32 = {d},
        \\}};
        \\
        \\pub const Instance = struct {{
        \\    /// Per-gate drive strength multiplier: effective Rout = rout / strength.
        \\    strength: f32 = 1.0,
        \\    /// Per-output-bit drive target voltage, written by updateState so
        \\    /// eval sources current toward it. Array field: skipped by the
        \\    /// by-name f32 param setter (which only walks scalar f32 fields).
        \\    drive: [{d}]f32 = [_]f32{{{d}}} ** {d},
        \\}};
        \\
        \\
    , .{ spec.default_vil, spec.default_vih, spec.default_vlo, spec.default_vhi, spec.default_rout, total_out, spec.default_vlo, total_out });

    // ── State ──────────────────────────────────────────────────────────────
    try w.writeAll("pub const State = struct {\n");
    try w.print("    inputs: [{d}]bool = [_]bool{{false}} ** {d},\n", .{ total_in, total_in });
    try w.print("    outputs: [{d}]bool = [_]bool{{false}} ** {d},\n", .{ total_out, total_out });
    for (spec.clocks) |cg| {
        try w.print("    prev_clk_{s}: bool = false,\n", .{cg.clk_port});
    }
    try w.writeAll("};\n\n");

    // ── Helpers: threshold always (updateState), shifts only if referenced ─
    try w.writeAll(
        \\fn threshold(model: Model, v: f64) bool {
        \\    const mid = 0.5 * (@as(f64, model.vil) + @as(f64, model.vih));
        \\    return v >= mid;
        \\}
        \\
        \\
    );
    const needs_sar = specUses(spec, "sar64");
    if (specUses(spec, "shl64")) {
        try w.writeAll(
            \\fn shl64(a: u64, b: u64) u64 {
            \\    return if (b >= 64) 0 else a << @intCast(b);
            \\}
            \\
            \\
        );
    }
    if (specUses(spec, "shr64") or needs_sar) {
        try w.writeAll(
            \\fn shr64(a: u64, b: u64) u64 {
            \\    return if (b >= 64) 0 else a >> @intCast(b);
            \\}
            \\
            \\
        );
    }
    if (needs_sar) {
        try w.writeAll(
            \\/// Arithmetic shift right of an unsigned value that is `w` bits wide.
            \\fn sar64(a: u64, b: u64, w: u64) u64 {
            \\    const mask: u64 = if (w >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w)) - 1;
            \\    const shifted = shr64(a, b) & mask;
            \\    if ((a >> @intCast(w - 1)) & 1 == 0) return shifted;
            \\    return shifted | (mask ^ shr64(mask, @min(b, w)));
            \\}
            \\
            \\
        );
    }

    // ── evalBits: pack read inputs → user statements → unpack results ─────
    if (sequential) {
        try w.print("fn evalBits(inputs: [{d}]bool, cur_outputs: [{d}]bool) [{d}]bool {{\n", .{ total_in, total_out, total_out });
    } else {
        try w.print("fn evalBits(inputs: [{d}]bool) [{d}]bool {{\n", .{ total_in, total_out });
    }

    var any_input_read = false;
    var bit_offset: usize = 0;
    for (spec.ports) |p| {
        if (p.direction != .input) continue;
        if (usesIdent(spec.eval_stmts, "", p.name)) {
            try emitPack(w, "    ", "", p.name, "inputs", bit_offset, p.width);
            any_input_read = true;
        }
        bit_offset += p.width;
    }
    if (!any_input_read) try w.writeAll("    _ = inputs;\n");

    if (sequential) {
        var any_prev_read = false;
        var prev_off: usize = 0;
        for (spec.ports) |p| {
            if (p.direction != .output) continue;
            if (usesIdent(spec.eval_stmts, "prev_out_", p.name)) {
                try emitPack(w, "    ", "prev_out_", p.name, "cur_outputs", prev_off, p.width);
                any_prev_read = true;
            }
            prev_off += p.width;
        }
        if (!any_prev_read) try w.writeAll("    _ = cur_outputs;\n");
    }

    try w.writeAll(spec.eval_stmts);
    if (!std.mem.endsWith(u8, spec.eval_stmts, "\n")) try w.writeByte('\n');

    try w.print("    var result: [{d}]bool = undefined;\n", .{total_out});
    var out_offset: usize = 0;
    for (spec.ports) |p| {
        if (p.direction != .output) continue;
        if (p.width == 1) {
            try w.print("    result[{d}] = _{s} != 0;\n", .{ out_offset, p.name });
        } else {
            try w.print("    for (0..{d}) |bit| {{\n", .{p.width});
            try w.print("        result[{d} + bit] = (_{s} >> @intCast(bit)) & 1 != 0;\n", .{ out_offset, p.name });
            try w.writeAll("    }\n");
        }
        out_offset += p.width;
    }
    try w.writeAll("    return result;\n}\n\n");

    // ── eval: value-form residual. The logic state machine (updateState) has
    // already written each output bit's target voltage into instance.drive[o];
    // here we only source analog current toward it. Inputs are high-Z
    // (residual 0). Per output bit:
    //   res[node]   = i_branch                       (= x[branch])
    //   res[branch] = x[node] - target + i_branch/g
    // where g = strength/rout (x-independent) and target = instance.drive[o].
    try w.writeAll(
        \\pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
        \\    @setFloatMode(.optimized);
        \\    _ = t;
        \\
        \\    var res: [n_u]S = undefined;
        \\    inline for (0..n_u) |row| res[row] = S.con(0.0);
        \\
        \\    const g = @max(@as(f64, instance.strength), 1.0e-12) / @max(@as(f64, model.rout), 1.0e-12);
        \\
    );
    out_offset = 0;
    for (spec.ports) |p| {
        if (p.direction != .output) continue;
        for (0..p.width) |bit| {
            try w.writeAll("    {\n");
            try w.writeAll("        const node = @intFromEnum(U.");
            try emitPinName(w, p.name, p.width, @intCast(bit));
            try w.writeAll(");\n");
            try w.writeAll("        const branch = @intFromEnum(U.");
            try emitPinName(w, p.name, p.width, @intCast(bit));
            try w.writeAll("_branch);\n");
            try w.print("        const target: f64 = @as(f64, instance.drive[{d}]);\n", .{out_offset});
            try w.writeAll(
                \\        const i_branch = x[branch];
                \\        res[node] = i_branch;
                \\        res[branch] = x[node].sub(S.con(target)).add(i_branch.scale(1.0 / g));
                \\    }
                \\
            );
            out_offset += 1;
        }
    }
    try w.writeAll("    return res;\n}\n\n");

    // ── State machine: applyDrive + initState + updateState ───────────────
    try w.print(
        \\fn applyDrive(model: *const Model, inst: *Instance, outputs: [{d}]bool) void {{
        \\    for (0..{d}) |o| {{
        \\        inst.drive[o] = if (outputs[o]) model.vhi else model.vlo;
        \\    }}
        \\}}
        \\
        \\
    , .{ total_out, total_out });

    try w.writeAll(
        \\pub fn initState(_: *const Model, _: *const Instance) State {
        \\    var state = State{};
        \\
    );
    if (sequential) {
        try w.writeAll("    state.outputs = evalBits(state.inputs, state.outputs);\n");
    } else {
        try w.writeAll("    state.outputs = evalBits(state.inputs);\n");
    }
    try w.writeAll(
        \\    return state;
        \\}
        \\
        \\pub fn updateState(model: *const Model, inst: *Instance, x: [n_u]f64, state: *State) contract.UpdateResult {
        \\
    );

    try w.print("    var next_inputs: [{d}]bool = undefined;\n", .{total_in});
    bit_offset = 0;
    for (spec.ports) |p| {
        if (p.direction != .input) continue;
        for (0..p.width) |bit| {
            try w.print("    next_inputs[{d}] = threshold(model.*, x[@intFromEnum(U.", .{bit_offset});
            try emitPinName(w, p.name, p.width, @intCast(bit));
            try w.writeAll(")]);\n");
            bit_offset += 1;
        }
    }

    // Edge detection + registered next-state per clock group.
    for (spec.clocks) |cg| {
        try w.print(
            \\
            \\    const clk_{s} = threshold(model.*, x[@intFromEnum(U.{s})]);
            \\
        , .{ cg.clk_port, cg.clk_port });

        switch (cg.edge) {
            .pos => try w.print("    const edge_{s} = clk_{s} and !state.prev_clk_{s};\n", .{ cg.clk_port, cg.clk_port, cg.clk_port }),
            .neg => try w.print("    const edge_{s} = !clk_{s} and state.prev_clk_{s};\n", .{ cg.clk_port, cg.clk_port, cg.clk_port }),
        }
        try w.print("    state.prev_clk_{s} = clk_{s};\n", .{ cg.clk_port, cg.clk_port });

        try w.print("    if (edge_{s}) {{\n", .{cg.clk_port});

        // Pack the input and current-output values the next-state statements read.
        var in_off: usize = 0;
        for (spec.ports) |p| {
            if (p.direction != .input) continue;
            if (usesIdent(cg.next_state_stmts, "", p.name)) {
                try emitPack(w, "        ", "", p.name, "next_inputs", in_off, p.width);
            }
            in_off += p.width;
        }
        var reg_off: usize = 0;
        for (spec.ports) |p| {
            if (p.direction != .output) continue;
            // Feedback registers (q <= q + 1) read the pre-edge output value.
            if (usesIdent(cg.next_state_stmts, "", p.name)) {
                try emitPack(w, "        ", "", p.name, "state.outputs", reg_off, p.width);
            }
            reg_off += p.width;
        }

        try w.writeAll(cg.next_state_stmts);

        // Write the registered results back into state.outputs.
        for (cg.registered) |reg_name| {
            var out_off: usize = 0;
            for (spec.ports) |p| {
                if (p.direction != .output) continue;
                if (std.mem.eql(u8, p.name, reg_name)) {
                    if (p.width == 1) {
                        try w.print("        state.outputs[{d}] = _{s} != 0;\n", .{ out_off, reg_name });
                    } else {
                        try w.print("        for (0..{d}) |bit| {{\n", .{p.width});
                        try w.print("            state.outputs[{d} + bit] = (_{s} >> @intCast(bit)) & 1 != 0;\n", .{ out_off, reg_name });
                        try w.writeAll("        }\n");
                    }
                    break;
                }
                out_off += p.width;
            }
        }
        try w.writeAll("    }\n");
    }

    try w.writeAll(
        \\
        \\    const prev_inputs = state.inputs;
        \\    const prev_outputs = state.outputs;
        \\    state.inputs = next_inputs;
        \\
    );
    if (sequential) {
        try w.writeAll("    state.outputs = evalBits(next_inputs, state.outputs);\n");
    } else {
        try w.writeAll("    state.outputs = evalBits(next_inputs);\n");
    }
    try w.writeAll(
        \\
        \\    // Push logic outputs into the analog drive targets eval reads.
        \\    applyDrive(model, inst, state.outputs);
        \\
        \\    if (changed(prev_inputs, state.inputs) or changed(prev_outputs, state.outputs))
        \\        return .{ .request_reject_at = 0.0 };
        \\    return .ok;
        \\}
        \\
        \\
    );

    // ── Shared dyn ABI v3 + contract.validate footer ───────────────────────
    try emit.emitDynAbi(w, .{
        .has_state = true,
        // Push the initial logic outputs into the analog drive targets so
        // eval sources current correctly before the first update_state.
        .state_init_extra = "    applyDrive(&m, &inst, s.outputs);\n",
    });

    return try writer.toOwnedSlice();
}

// ── Leaf helpers (called in loops; inlining them would only add noise) ────

/// True if `name` appears in `text` as a standalone identifier, optionally
/// prefixed (e.g. prefix "prev_out_" + name "q" matches "prev_out_q").
/// Used to avoid declaring locals the emitted statements never read —
/// Zig rejects unused locals, so over-declaring makes the output uncompilable.
fn usesIdent(text: []const u8, prefix: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, prefix)) |idx| {
        pos = idx + 1;
        const name_start = idx + prefix.len;
        if (name_start + name.len > text.len) return false;
        if (!std.mem.eql(u8, text[name_start .. name_start + name.len], name)) continue;
        const before_ok = idx == 0 or !isIdentChar(text[idx - 1]);
        const end = name_start + name.len;
        const after_ok = end >= text.len or !isIdentChar(text[end]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn specUses(spec: DeviceSpec, name: []const u8) bool {
    if (usesIdent(spec.eval_stmts, "", name)) return true;
    for (spec.clocks) |cg| {
        if (usesIdent(cg.next_state_stmts, "", name)) return true;
    }
    return false;
}

fn emitPinName(w: anytype, name: []const u8, width: u16, bit: u16) !void {
    if (width == 1) {
        try w.writeAll(name);
    } else {
        try w.print("{s}_{d}", .{ name, bit });
    }
}

/// Pack the bits of a port into a u64 local named `<prefix><name>`.
fn emitPack(w: anytype, indent: []const u8, prefix: []const u8, name: []const u8, array: []const u8, offset: usize, width: u16) !void {
    if (width == 1) {
        try w.print("{s}const {s}{s}: u64 = @intFromBool({s}[{d}]);\n", .{ indent, prefix, name, array, offset });
    } else {
        try w.print("{s}var {s}{s}: u64 = 0;\n", .{ indent, prefix, name });
        try w.print("{s}for (0..{d}) |bit| {{\n", .{ indent, width });
        try w.print("{s}    if ({s}[{d} + bit]) {s}{s} |= (@as(u64, 1) << @intCast(bit));\n", .{ indent, array, offset, prefix, name });
        try w.print("{s}}}\n", .{indent});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "generateDevice multi-bit adder" {
    const source = try generateDevice(std.testing.allocator, .{
        .name = "adder4",
        .ports = &.{
            .{ .name = "a", .direction = .input, .width = 4 },
            .{ .name = "b", .direction = .input, .width = 4 },
            .{ .name = "y", .direction = .output, .width = 5 },
        },
        .eval_stmts = "    const _y: u64 = (a +% b) & 0x1f;\n",
    });
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "a_0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "a_3,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "y_4_branch,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "num_ports: usize = 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn eval(comptime S: type") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "zpicey_eval_ad") != null);
}

test "generateDevice scalar ports" {
    const source = try generateDevice(std.testing.allocator, .{
        .name = "inv",
        .ports = &.{
            .{ .name = "a", .direction = .input },
            .{ .name = "y", .direction = .output },
        },
        .eval_stmts = "    const _y: u64 = (~a) & 0x1;\n",
    });
    defer std.testing.allocator.free(source);

    // Scalar ports: no _0 suffix
    try std.testing.expect(std.mem.indexOf(u8, source, "    a,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "    y,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "y_branch,") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "num_ports: usize = 2") != null);
}

test "unused input is not declared in evalBits" {
    const source = try generateDevice(std.testing.allocator, .{
        .name = "const_out",
        .ports = &.{
            .{ .name = "a", .direction = .input },
            .{ .name = "y", .direction = .output },
        },
        .eval_stmts = "    const _y: u64 = 0x1;\n",
    });
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "const a: u64") == null);
}

test "shift helpers only emitted when referenced" {
    const source = try generateDevice(std.testing.allocator, .{
        .name = "and2",
        .ports = &.{
            .{ .name = "a", .direction = .input },
            .{ .name = "b", .direction = .input },
            .{ .name = "y", .direction = .output },
        },
        .eval_stmts = "    const _y: u64 = a & b;\n",
    });
    defer std.testing.allocator.free(source);

    try std.testing.expect(std.mem.indexOf(u8, source, "fn shl64") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn shr64") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "fn sar64") == null);
}

test "port limits rejected" {
    const wide = codegenErr(.{
        .name = "wide",
        .ports = &.{
            .{ .name = "a", .direction = .input, .width = 65 },
            .{ .name = "y", .direction = .output },
        },
        .eval_stmts = "    const _y: u64 = 0;\n",
    });
    try std.testing.expectError(Error.InvalidPort, wide);

    const too_many = codegenErr(.{
        .name = "big",
        .ports = &.{
            .{ .name = "a", .direction = .input, .width = 64 },
            .{ .name = "b", .direction = .input, .width = 64 },
            .{ .name = "c", .direction = .input, .width = 64 },
            .{ .name = "y", .direction = .output, .width = 33 },
        },
        .eval_stmts = "    const _y: u64 = 0;\n",
    });
    try std.testing.expectError(Error.InvalidPort, too_many);
}

fn codegenErr(spec: DeviceSpec) Error![]u8 {
    return generateDevice(std.testing.allocator, spec);
}
