const std = @import("std");
const emit = @import("emit");
const codegen = @import("codegen.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Buf = emit.Buf;

pub const Error = error{
    VerilatorFailed,
    Sv2vFailed,
    NoModule,
    NoOutputPorts,
    NoInputPorts,
    UnsupportedNode,
    MissingAssignment,
    BadConst,
};

/// Verilog source → contract.zig-compliant Zig device code.
pub fn fromVerilog(gpa: Allocator, io: Io, verilog_source: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    const v_path = "/tmp/zvf_input.v";
    const json_path = "/tmp/zvf_output.json";

    try cwd.writeFile(io, .{ .sub_path = v_path, .data = verilog_source });
    defer cwd.deleteFile(io, v_path) catch {};
    defer cwd.deleteFile(io, json_path) catch {};

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "verilator", "--json-only", "--json-only-output", json_path, v_path },
    });
    gpa.free(result.stdout);
    gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return Error.VerilatorFailed,
        else => return Error.VerilatorFailed,
    }

    const json_bytes = try cwd.readFileAlloc(io, json_path, gpa, .unlimited);
    defer gpa.free(json_bytes);

    return parseAndGenerate(gpa, json_bytes);
}

/// SystemVerilog source → sv2v → fromVerilog.
pub fn fromSystemVerilog(gpa: Allocator, io: Io, sv_source: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    const sv_path = "/tmp/zvf_input.sv";

    try cwd.writeFile(io, .{ .sub_path = sv_path, .data = sv_source });
    defer cwd.deleteFile(io, sv_path) catch {};

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "sv2v", sv_path },
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return Error.Sv2vFailed,
        else => return Error.Sv2vFailed,
    }

    return fromVerilog(gpa, io, result.stdout);
}

// ============================================================================
// DType table — maps type addr → bit width
// ============================================================================

const DTypeMap = std.StringHashMap(u16);

fn buildDTypeMap(gpa: Allocator, root: ObjectMap) !DTypeMap {
    var map = DTypeMap.init(gpa);
    errdefer map.deinit();

    const miscs = (root.get("miscsp") orelse return map).array.items;
    for (miscs) |misc_val| {
        const misc = misc_val.object;
        const misc_type = (misc.get("type") orelse continue).string;
        if (!std.mem.eql(u8, misc_type, "TYPETABLE")) continue;

        const types = (misc.get("typesp") orelse continue).array.items;
        for (types) |type_val| {
            const t = type_val.object;
            const addr = (t.get("addr") orelse continue).string;
            const t_type = (t.get("type") orelse continue).string;

            if (std.mem.eql(u8, t_type, "BASICDTYPE")) {
                if (t.get("range")) |range_val| {
                    const w = parseRange(range_val.string) catch 1;
                    try map.put(addr, w);
                } else {
                    try map.put(addr, 1);
                }
            }
        }
    }
    return map;
}

fn parseRange(range: []const u8) !u16 {
    // "7:0" → 8, "3:0" → 4, "0:0" → 1
    const colon = std.mem.indexOf(u8, range, ":") orelse return error.BadConst;
    const hi = std.fmt.parseInt(u16, range[0..colon], 10) catch return error.BadConst;
    const lo = std.fmt.parseInt(u16, range[colon + 1 ..], 10) catch return error.BadConst;
    return @max(hi, lo) - @min(hi, lo) + 1;
}

fn dtypeWidth(dtypes: *const DTypeMap, node: ObjectMap) u16 {
    const addr = (node.get("dtypep") orelse return 1).string;
    return dtypes.get(addr) orelse 1;
}

// ============================================================================
// JSON AST → DeviceSpec → codegen
// ============================================================================

fn parseAndGenerate(gpa: Allocator, json_bytes: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    var dtypes = try buildDTypeMap(gpa, root);
    defer dtypes.deinit();

    const modules = (root.get("modulesp") orelse return Error.NoModule).array.items;
    if (modules.len == 0) return Error.NoModule;

    const module = modules[0].object;
    const mod_name = (module.get("origName") orelse return Error.NoModule).string;
    const stmts = (module.get("stmtsp") orelse return Error.NoModule).array.items;

    var ports: Buf(codegen.Port) = .empty;
    defer ports.deinit(gpa);
    var assigns: Buf(AssignInfo) = .empty;
    defer assigns.deinit(gpa);
    var case_stmts: Buf(CaseInfo) = .empty;
    defer case_stmts.deinit(gpa);
    var seq_blocks: Buf(SeqBlock) = .empty;
    defer seq_blocks.deinit(gpa);
    defer for (seq_blocks.slice()) |sb| gpa.free(sb.assigns);

    const TopStmt = enum { VAR, ALWAYS, INITIAL };
    const PortDir = enum { INPUT, OUTPUT };

    for (stmts) |stmt_val| {
        const stmt = stmt_val.object;
        const node_type = std.meta.stringToEnum(TopStmt, (stmt.get("type") orelse continue).string) orelse continue;

        switch (node_type) {
            .VAR => {
                const dir = std.meta.stringToEnum(PortDir, (stmt.get("direction") orelse continue).string) orelse continue;
                const name = (stmt.get("origName") orelse continue).string;
                const width = dtypeWidth(&dtypes, stmt);
                try ports.append(gpa, .{
                    .name = name,
                    .direction = if (dir == .INPUT) .input else .output,
                    .width = width,
                });
            },
            .ALWAYS, .INITIAL => try extractAssigns(gpa, stmt, &assigns, &case_stmts, &seq_blocks),
        }
    }

    var n_in: u32 = 0;
    var n_out: u32 = 0;
    for (ports.slice()) |p| switch (p.direction) {
        .input => n_in += 1,
        .output => n_out += 1,
    };
    if (n_in == 0) return Error.NoInputPorts;
    if (n_out == 0) return Error.NoOutputPorts;

    // Build eval_stmts
    var sw = Io.Writer.Allocating.init(gpa);
    errdefer sw.deinit();
    const w = &sw.writer;

    for (ports.slice()) |out_port| {
        if (out_port.direction != .output) continue;
        const mask = maskForWidth(out_port.width);
        if (isRegistered(seq_blocks.slice(), out_port.name)) {
            // Registered: hold current value in evalBits
            try w.print("    const _{s}: u64 = prev_out_{s};\n", .{ out_port.name, out_port.name });
        } else if (findAssign(assigns.slice(), out_port.name)) |assign| {
            try w.print("    const _{s}: u64 = ", .{out_port.name});
            try translateExpr(w, assign.expr, &dtypes);
            if (mask != 0) try w.print(" & 0x{x}", .{mask});
            try w.writeAll(";\n");
        } else if (findCase(case_stmts.slice(), out_port.name)) |ci| {
            try emitCaseStmts(w, ci, &dtypes, mask);
        } else {
            return Error.MissingAssignment;
        }
    }

    const eval_stmts = try sw.toOwnedSlice();
    defer gpa.free(eval_stmts);

    // Build clock groups for sequential
    var clock_groups: Buf(codegen.ClockGroup) = .empty;
    defer clock_groups.deinit(gpa);
    defer for (clock_groups.slice()) |cg| {
        gpa.free(cg.registered);
        gpa.free(cg.next_state_stmts);
    };

    for (seq_blocks.slice()) |sb| {
        // Build next-state statements
        var ns_writer = Io.Writer.Allocating.init(gpa);
        errdefer ns_writer.deinit();
        const nsw = &ns_writer.writer;

        for (sb.assigns) |ra| {
            var out_width: u16 = 1;
            for (ports.slice()) |p| {
                if (p.direction == .output and std.mem.eql(u8, p.name, ra.target)) {
                    out_width = p.width;
                    break;
                }
            }
            const mask = maskForWidth(out_width);
            try nsw.print("        const _{s}: u64 = ", .{ra.target});
            try translateExpr(nsw, ra.expr, &dtypes);
            if (mask != 0) try nsw.print(" & 0x{x}", .{mask});
            try nsw.writeAll(";\n");
        }

        const ns_stmts = try ns_writer.toOwnedSlice();
        errdefer gpa.free(ns_stmts);

        // Collect registered port names
        const reg_names = try gpa.alloc([]const u8, sb.assigns.len);
        errdefer gpa.free(reg_names);
        for (sb.assigns, 0..) |ra, i| {
            reg_names[i] = ra.target;
        }

        try clock_groups.append(gpa, .{
            .clk_port = sb.clk_port,
            .edge = if (sb.edge_pos) .pos else .neg,
            .registered = reg_names,
            .next_state_stmts = ns_stmts,
        });
    }

    // generateDevice iterates ports filtered by direction, so module
    // declaration order is passed through as-is.
    return codegen.generateDevice(gpa, .{
        .name = mod_name,
        .ports = ports.slice(),
        .eval_stmts = eval_stmts,
        .clocks = clock_groups.slice(),
    });
}

fn isRegistered(seq_blocks: []const SeqBlock, name: []const u8) bool {
    for (seq_blocks) |sb| {
        for (sb.assigns) |ra| {
            if (std.mem.eql(u8, ra.target, name)) return true;
        }
    }
    return false;
}

fn maskForWidth(width: u16) u64 {
    if (width >= 64) return 0; // no mask needed
    return (@as(u64, 1) << @intCast(width)) - 1;
}

// ============================================================================
// Assignment extraction (handles ASSIGNW, ASSIGN, CASE, ASSIGNDLY)
// ============================================================================

const AssignInfo = struct {
    target: []const u8,
    expr: Value,
};

const CaseInfo = struct {
    target: []const u8,
    sel_expr: Value,
    items: []const Value,
};

const SeqBlock = struct {
    clk_port: []const u8,
    edge_pos: bool,
    assigns: []const AssignInfo,
};

fn findAssign(assigns: []const AssignInfo, name: []const u8) ?AssignInfo {
    for (assigns) |a| {
        if (std.mem.eql(u8, a.target, name)) return a;
    }
    return null;
}

fn findCase(cases: []const CaseInfo, name: []const u8) ?CaseInfo {
    for (cases) |c| {
        if (std.mem.eql(u8, c.target, name)) return c;
    }
    return null;
}

fn extractAssigns(gpa: Allocator, always: ObjectMap, assigns: *Buf(AssignInfo), cases: *Buf(CaseInfo), seq_blocks: *Buf(SeqBlock)) !void {
    // Sequential (posedge/negedge) block?
    const EdgeType = enum { POS, NEG };
    var clk_name: ?[]const u8 = null;
    var edge_pos = false;

    if (always.get("sentreep")) |sentree_val| {
        for (sentree_val.array.items) |st| {
            const senses = (st.object.get("sensesp") orelse continue).array.items;
            for (senses) |sense| {
                const edge = std.meta.stringToEnum(EdgeType, (sense.object.get("edgeType") orelse continue).string) orelse continue;
                const sensp = (sense.object.get("sensp") orelse continue).array.items;
                if (sensp.len == 0) continue;
                // A second edge sense means multi-clock or async reset — reject
                // loudly rather than silently dropping it.
                if (clk_name != null) return Error.UnsupportedNode;
                clk_name = (sensp[0].object.get("name") orelse continue).string;
                edge_pos = edge == .POS;
            }
        }
    }

    const inner_stmts = (always.get("stmtsp") orelse return).array.items;

    if (clk_name) |clk| {
        var reg_assigns: Buf(AssignInfo) = .empty;
        errdefer reg_assigns.deinit(gpa);
        try collectSeqAssigns(gpa, inner_stmts, &reg_assigns);

        if (reg_assigns.len > 0) {
            try seq_blocks.append(gpa, .{
                .clk_port = clk,
                .edge_pos = edge_pos,
                .assigns = try reg_assigns.toOwnedSlice(gpa),
            });
        } else {
            reg_assigns.deinit(gpa);
        }
        return;
    }

    // Combinational always block
    for (inner_stmts) |inner_val| {
        try extractAssignFromStmt(gpa, inner_val.object, assigns, cases);
    }
}

fn collectSeqAssigns(gpa: Allocator, stmts: []const Value, out: *Buf(AssignInfo)) !void {
    for (stmts) |stmt_val| {
        const stmt = stmt_val.object;
        const stmt_type = (stmt.get("type") orelse continue).string;
        if (std.mem.eql(u8, stmt_type, "BEGIN")) {
            const nested = (stmt.get("stmtsp") orelse continue).array.items;
            try collectSeqAssigns(gpa, nested, out);
        } else if (std.mem.eql(u8, stmt_type, "ASSIGNDLY")) {
            const lhs = try child(stmt, "lhsp");
            const rhs = try child(stmt, "rhsp");
            const target = (lhs.object.get("name") orelse return Error.UnsupportedNode).string;
            try out.append(gpa, .{ .target = target, .expr = rhs });
        } else {
            // if/reset logic inside a clocked block is not modeled — fail loudly.
            return Error.UnsupportedNode;
        }
    }
}

fn extractAssignFromStmt(gpa: Allocator, stmt: ObjectMap, assigns: *Buf(AssignInfo), cases: *Buf(CaseInfo)) !void {
    const StmtKind = enum { ASSIGNW, ASSIGN, BEGIN, CASE };
    const kind = std.meta.stringToEnum(StmtKind, (stmt.get("type") orelse return).string) orelse return;

    switch (kind) {
        .ASSIGNW, .ASSIGN => {
            const lhs = try child(stmt, "lhsp");
            const rhs = try child(stmt, "rhsp");
            const lhs_name = (lhs.object.get("name") orelse return).string;
            try assigns.append(gpa, .{ .target = lhs_name, .expr = rhs });
        },
        .BEGIN => {
            for ((stmt.get("stmtsp") orelse return).array.items) |child_val| {
                try extractAssignFromStmt(gpa, child_val.object, assigns, cases);
            }
        },
        .CASE => {
            const expr = try child(stmt, "exprp");
            const items_arr = (stmt.get("itemsp") orelse return).array.items;
            if (items_arr.len == 0) return;

            const first_item = items_arr[0].object;
            const first_stmt = try child(first_item, "stmtsp");
            const first_lhs = try child(first_stmt.object, "lhsp");
            const target_name = (first_lhs.object.get("name") orelse return).string;

            try cases.append(gpa, .{
                .target = target_name,
                .sel_expr = expr,
                .items = items_arr,
            });
        },
    }
}

/// Emit CASE as if-else chain: var _target: u64 = 0; if (...) ... else if (...) ...
fn emitCaseStmts(w: anytype, ci: CaseInfo, dtypes: *const DTypeMap, mask: u64) !void {
    try w.print("    var _{s}: u64 = 0;\n", .{ci.target});

    var first = true;
    var default_expr: ?Value = null;

    for (ci.items) |item_val| {
        const item = item_val.object;
        const conds = (item.get("condsp") orelse continue).array.items;
        const item_stmts = (item.get("stmtsp") orelse continue).array.items;
        if (item_stmts.len == 0) continue;
        const rhs_arr = (item_stmts[0].object.get("rhsp") orelse continue).array.items;
        if (rhs_arr.len == 0) continue;

        if (conds.len == 0) {
            // default
            default_expr = rhs_arr[0];
            continue;
        }

        // Branches of one Zig if-else statement: no ';' until the chain ends.
        if (first) {
            try w.writeAll("    if (");
            first = false;
        } else {
            try w.writeAll(" else if (");
        }
        try translateExpr(w, ci.sel_expr, dtypes);
        try w.writeAll(" == ");
        try translateExpr(w, conds[0], dtypes);
        try w.print(") _{s} = ", .{ci.target});
        try translateExpr(w, rhs_arr[0], dtypes);
        if (mask != 0) try w.print(" & 0x{x}", .{mask});
    }

    if (default_expr) |dexpr| {
        if (first) {
            try w.print("    _{s} = ", .{ci.target});
        } else {
            try w.print(" else _{s} = ", .{ci.target});
        }
        try translateExpr(w, dexpr, dtypes);
        if (mask != 0) try w.print(" & 0x{x}", .{mask});
    }
    if (!first or default_expr != null) try w.writeAll(";");
    try w.writeAll("\n");
}

// ============================================================================
// Verilator AST expression → Zig integer expression
//
// Invariant: every translated expression is "clean" — its value fits its
// declared width with no garbage in higher bits. Inputs are packed from
// bools, and every width-overflowing operator (+, -, *, <<, ~, unary -)
// is masked to its result width. Comparisons and reductions rely on this.
// ============================================================================

const ExprKind = enum {
    VARREF, CONST,
    AND, OR, XOR, ADD, SUB, MUL, DIV, MODDIV,
    EQ, NEQ, EQCASE, NEQCASE, GT, GTE, LT, LTE,
    SHIFTL, SHIFTR, SHIFTRS,
    NOT, NEGATE, EXTEND,
    REDOR, REDAND, REDXOR,
    COND, SEL, CONCAT, REPLICATE,
};

const TranslateError = Error || std.Io.Writer.Error;

fn child(obj: ObjectMap, key: []const u8) TranslateError!Value {
    const val = obj.get(key) orelse return Error.UnsupportedNode;
    if (val != .array or val.array.items.len == 0) return Error.UnsupportedNode;
    return val.array.items[0];
}

fn translateExpr(w: anytype, node: Value, dtypes: *const DTypeMap) TranslateError!void {
    const obj = node.object;
    const kind = std.meta.stringToEnum(ExprKind, (obj.get("type") orelse return Error.UnsupportedNode).string) orelse
        return Error.UnsupportedNode;

    // Values are carried in a single u64.
    if (dtypeWidth(dtypes, obj) > 64) return Error.UnsupportedNode;

    switch (kind) {
        .VARREF => try w.writeAll((obj.get("name") orelse return Error.UnsupportedNode).string),

        .CONST => {
            const val = try parseConst((obj.get("name") orelse return Error.UnsupportedNode).string);
            try w.print("0x{x}", .{val});
        },

        .AND => try emitBinOp(w, obj, " & ", dtypes),
        .OR => try emitBinOp(w, obj, " | ", dtypes),
        .XOR => try emitBinOp(w, obj, " ^ ", dtypes),
        .DIV => try emitBinOp(w, obj, " / ", dtypes),
        .MODDIV => try emitBinOp(w, obj, " % ", dtypes),

        // Wrapping ops can overflow the result width — mask to keep the
        // clean-value invariant.
        .ADD => try emitWrapOp(w, obj, " +% ", dtypes),
        .SUB => try emitWrapOp(w, obj, " -% ", dtypes),
        .MUL => try emitWrapOp(w, obj, " *% ", dtypes),

        .EQ, .EQCASE => try emitCmpOp(w, obj, " == ", dtypes),
        .NEQ, .NEQCASE => try emitCmpOp(w, obj, " != ", dtypes),
        .GT => try emitCmpOp(w, obj, " > ", dtypes),
        .GTE => try emitCmpOp(w, obj, " >= ", dtypes),
        .LT => try emitCmpOp(w, obj, " < ", dtypes),
        .LTE => try emitCmpOp(w, obj, " <= ", dtypes),

        .SHIFTL => {
            const mask = maskForWidth(dtypeWidth(dtypes, obj));
            if (mask != 0) try w.writeByte('(');
            try emitShift(w, obj, "shl64", dtypes);
            if (mask != 0) try w.print(" & 0x{x})", .{mask});
        },
        .SHIFTR => try emitShift(w, obj, "shr64", dtypes),

        .SHIFTRS => {
            // Arithmetic shift: sign-extend from the lhs width.
            const lhs = try child(obj, "lhsp");
            try w.writeAll("sar64(");
            try translateExpr(w, lhs, dtypes);
            try w.writeAll(", ");
            try translateExpr(w, try child(obj, "rhsp"), dtypes);
            try w.print(", {d})", .{dtypeWidth(dtypes, lhs.object)});
        },

        .NOT => {
            const mask = maskForWidth(dtypeWidth(dtypes, obj));
            try w.writeAll("((~");
            try translateExpr(w, try child(obj, "lhsp"), dtypes);
            try w.writeByte(')');
            if (mask != 0) try w.print(" & 0x{x}", .{mask});
            try w.writeByte(')');
        },

        .NEGATE => {
            const mask = maskForWidth(dtypeWidth(dtypes, obj));
            try w.writeAll("((0 -% ");
            try translateExpr(w, try child(obj, "lhsp"), dtypes);
            try w.writeByte(')');
            if (mask != 0) try w.print(" & 0x{x}", .{mask});
            try w.writeByte(')');
        },

        .EXTEND => try translateExpr(w, try child(obj, "lhsp"), dtypes),

        .REDOR => {
            try w.writeAll("@intFromBool(");
            try translateExpr(w, try child(obj, "lhsp"), dtypes);
            try w.writeAll(" != 0)");
        },

        .REDAND => {
            const operand = try child(obj, "lhsp");
            const mask = maskForWidth(dtypeWidth(dtypes, operand.object));
            try w.writeAll("@intFromBool(");
            try translateExpr(w, operand, dtypes);
            if (mask != 0) try w.print(" == 0x{x}", .{mask}) else try w.writeAll(" == 0xffffffffffffffff");
            try w.writeByte(')');
        },

        .REDXOR => {
            try w.writeAll("(@popCount(");
            try translateExpr(w, try child(obj, "lhsp"), dtypes);
            try w.writeAll(") & 1)");
        },

        .COND => {
            try w.writeAll("(if (");
            try translateExpr(w, try child(obj, "condp"), dtypes);
            try w.writeAll(" != 0) ");
            try translateExpr(w, try child(obj, "thenp"), dtypes);
            try w.writeAll(" else ");
            try translateExpr(w, try child(obj, "elsep"), dtypes);
            try w.writeByte(')');
        },

        .SEL => {
            const sel_mask = maskForWidth(if (obj.get("widthConst")) |wc| @as(u16, @intCast(wc.integer)) else 1);
            try w.writeAll("(shr64(");
            try translateExpr(w, try child(obj, "fromp"), dtypes);
            try w.writeAll(", ");
            try translateExpr(w, try child(obj, "lsbp"), dtypes);
            try w.writeByte(')');
            if (sel_mask != 0) try w.print(" & 0x{x}", .{sel_mask});
            try w.writeByte(')');
        },

        .CONCAT => {
            const rhs = try child(obj, "rhsp");
            try w.writeAll("(shl64(");
            try translateExpr(w, try child(obj, "lhsp"), dtypes);
            try w.print(", {d}) | ", .{dtypeWidth(dtypes, rhs.object)});
            try translateExpr(w, rhs, dtypes);
            try w.writeByte(')');
        },

        .REPLICATE => {
            const src = try child(obj, "srcp");
            const count_node = try child(obj, "countp");
            const src_width = dtypeWidth(dtypes, src.object);
            const count = try parseConst((count_node.object.get("name") orelse return Error.UnsupportedNode).string);
            if (count * src_width > 64) return Error.UnsupportedNode;

            if (count <= 1) {
                try translateExpr(w, src, dtypes);
                return;
            }

            try w.writeByte('(');
            for (0..@intCast(count)) |rep| {
                if (rep > 0) try w.writeAll(" | ");
                if (rep == 0) {
                    try translateExpr(w, src, dtypes);
                } else {
                    try w.writeAll("shl64(");
                    try translateExpr(w, src, dtypes);
                    try w.print(", {d})", .{rep * src_width});
                }
            }
            try w.writeByte(')');
        },
    }
}

inline fn emitBinOp(w: anytype, obj: ObjectMap, op: []const u8, dtypes: *const DTypeMap) TranslateError!void {
    try w.writeByte('(');
    try translateExpr(w, try child(obj, "lhsp"), dtypes);
    try w.writeAll(op);
    try translateExpr(w, try child(obj, "rhsp"), dtypes);
    try w.writeByte(')');
}

inline fn emitWrapOp(w: anytype, obj: ObjectMap, op: []const u8, dtypes: *const DTypeMap) TranslateError!void {
    const mask = maskForWidth(dtypeWidth(dtypes, obj));
    if (mask != 0) try w.writeByte('(');
    try emitBinOp(w, obj, op, dtypes);
    if (mask != 0) try w.print(" & 0x{x})", .{mask});
}

inline fn emitCmpOp(w: anytype, obj: ObjectMap, op: []const u8, dtypes: *const DTypeMap) TranslateError!void {
    try w.writeAll("@intFromBool(");
    try translateExpr(w, try child(obj, "lhsp"), dtypes);
    try w.writeAll(op);
    try translateExpr(w, try child(obj, "rhsp"), dtypes);
    try w.writeByte(')');
}

inline fn emitShift(w: anytype, obj: ObjectMap, fn_name: []const u8, dtypes: *const DTypeMap) TranslateError!void {
    try w.writeAll(fn_name);
    try w.writeByte('(');
    try translateExpr(w, try child(obj, "lhsp"), dtypes);
    try w.writeAll(", ");
    try translateExpr(w, try child(obj, "rhsp"), dtypes);
    try w.writeByte(')');
}

// ============================================================================
// Verilog constant parser: "3'h4" → 4, "32'sh1f" → 31, "1'h1" → 1
// ============================================================================

fn parseConst(name: []const u8) TranslateError!u64 {
    const tick = std.mem.indexOf(u8, name, "'") orelse {
        // Plain decimal
        return std.fmt.parseInt(u64, name, 10) catch return Error.BadConst;
    };
    var rest = name[tick + 1 ..];

    // Skip optional 's' (signed)
    if (rest.len > 0 and rest[0] == 's') rest = rest[1..];

    if (rest.len == 0) return Error.BadConst;
    const base_char = rest[0];
    const digits = rest[1..];

    return switch (base_char) {
        'h' => std.fmt.parseInt(u64, digits, 16) catch return Error.BadConst,
        'b' => std.fmt.parseInt(u64, digits, 2) catch return Error.BadConst,
        'd' => std.fmt.parseInt(u64, digits, 10) catch return Error.BadConst,
        'o' => std.fmt.parseInt(u64, digits, 8) catch return Error.BadConst,
        else => Error.BadConst,
    };
}

// ============================================================================
// Unit tests
// ============================================================================

const testing = std.testing;

fn testTranslateExpr(json: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, json, .{});
    defer parsed.deinit();

    var dtypes = DTypeMap.init(testing.allocator);
    defer dtypes.deinit();
    // Add a 1-bit type for (G) and a 4-bit type for (I)
    try dtypes.put("(G)", 1);
    try dtypes.put("(I)", 4);

    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try translateExpr(&aw.writer, parsed.value, &dtypes);
    return try aw.toOwnedSlice();
}

test "translate VARREF" {
    const out = try testTranslateExpr(
        \\{"type":"VARREF","name":"a","addr":"(X)","dtypep":"(G)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a", out);
}

test "translate AND" {
    const out = try testTranslateExpr(
        \\{"type":"AND","name":"","addr":"(L)","dtypep":"(G)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(G)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"rhsp":[{"type":"VARREF","name":"b","addr":"(N)","dtypep":"(G)","access":"RD","varp":"(H)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(a & b)", out);
}

test "translate NOT" {
    const out = try testTranslateExpr(
        \\{"type":"NOT","name":"","addr":"(K)","dtypep":"(G)","lhsp":[{"type":"VARREF","name":"a","addr":"(L)","dtypep":"(G)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("((~a) & 0x1)", out);
}

test "translate COND" {
    const out = try testTranslateExpr(
        \\{"type":"COND","name":"","addr":"(M)","dtypep":"(G)","condp":[{"type":"VARREF","name":"sel","addr":"(N)","dtypep":"(G)","access":"RD","varp":"(I)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"thenp":[{"type":"VARREF","name":"a","addr":"(O)","dtypep":"(G)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"elsep":[{"type":"VARREF","name":"b","addr":"(P)","dtypep":"(G)","access":"RD","varp":"(H)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(if (sel != 0) a else b)", out);
}

test "translate EQ" {
    const out = try testTranslateExpr(
        \\{"type":"EQ","name":"","addr":"(X)","dtypep":"(G)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"rhsp":[{"type":"VARREF","name":"b","addr":"(N)","dtypep":"(I)","access":"RD","varp":"(H)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("@intFromBool(a == b)", out);
}

test "translate ADD masks to node width" {
    const out = try testTranslateExpr(
        \\{"type":"ADD","name":"","addr":"(X)","dtypep":"(I)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"rhsp":[{"type":"VARREF","name":"b","addr":"(N)","dtypep":"(I)","access":"RD","varp":"(H)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("((a +% b) & 0xf)", out);
}

test "translate SHIFTL masks to node width" {
    const out = try testTranslateExpr(
        \\{"type":"SHIFTL","name":"","addr":"(X)","dtypep":"(I)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"rhsp":[{"type":"VARREF","name":"b","addr":"(N)","dtypep":"(G)","access":"RD","varp":"(H)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(shl64(a, b) & 0xf)", out);
}

test "translate SHIFTRS sign-extends from lhs width" {
    const out = try testTranslateExpr(
        \\{"type":"SHIFTRS","name":"","addr":"(X)","dtypep":"(I)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}],"rhsp":[{"type":"VARREF","name":"b","addr":"(N)","dtypep":"(G)","access":"RD","varp":"(H)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("sar64(a, b, 4)", out);
}

test "translate CONST hex" {
    const out = try testTranslateExpr(
        \\{"type":"CONST","name":"8'hff","addr":"(X)","dtypep":"(I)"}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("0xff", out);
}

test "translate REDOR" {
    const out = try testTranslateExpr(
        \\{"type":"REDOR","name":"","addr":"(X)","dtypep":"(G)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("@intFromBool(a != 0)", out);
}

test "translate REDXOR" {
    const out = try testTranslateExpr(
        \\{"type":"REDXOR","name":"","addr":"(X)","dtypep":"(G)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("(@popCount(a) & 1)", out);
}

test "translate NEGATE" {
    const out = try testTranslateExpr(
        \\{"type":"NEGATE","name":"","addr":"(X)","dtypep":"(I)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(I)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("((0 -% a) & 0xf)", out);
}

test "translate EXTEND passthrough" {
    const out = try testTranslateExpr(
        \\{"type":"EXTEND","name":"","addr":"(X)","dtypep":"(I)","lhsp":[{"type":"VARREF","name":"a","addr":"(M)","dtypep":"(G)","access":"RD","varp":"(F)","varScopep":"UNLINKED","classOrPackagep":"UNLINKED"}]}
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a", out);
}

test "translate rejects malformed node without panic" {
    try testing.expectError(Error.UnsupportedNode, testTranslateExpr(
        \\{"type":"AND","name":"","addr":"(L)","dtypep":"(G)","rhsp":[{"type":"VARREF","name":"b","addr":"(N)","dtypep":"(G)"}]}
    ));
}

test "parseConst" {
    try testing.expectEqual(@as(u64, 4), try parseConst("3'h4"));
    try testing.expectEqual(@as(u64, 255), try parseConst("8'hff"));
    try testing.expectEqual(@as(u64, 1), try parseConst("1'h1"));
    try testing.expectEqual(@as(u64, 0), try parseConst("1'h0"));
    try testing.expectEqual(@as(u64, 4), try parseConst("32'sh4"));
    try testing.expectEqual(@as(u64, 5), try parseConst("3'b101"));
    try testing.expectEqual(@as(u64, 42), try parseConst("8'd42"));
    try testing.expectError(Error.BadConst, parseConst("2'b1x"));
}
