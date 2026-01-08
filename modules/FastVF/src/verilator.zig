const std = @import("std");
const codegen = @import("codegen.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Buf = std.ArrayList;

pub const Error = error{
    VerilatorFailed,
    Sv2vFailed,
    GhdlFailed,
    NoModule,
    NoOutputPorts,
    NoInputPorts,
    UnsupportedNode,
    MissingAssignment,
    BadConst,
};

/// Scratch-file names, keyed on a hash of the source.
///
/// `modules/devices` runs one of these per `models/*.v`, and `zig build` runs
/// those steps CONCURRENTLY — fixed `/tmp/zvf_input.v` names would have one
/// invocation overwrite another's input between the write and verilator reading
/// it. Hashing the source makes distinct sources distinct files; two runs that
/// do collide are compiling identical bytes, so the overwrite is a no-op rather
/// than a race. Also pins verilator's `--Mdir`, which otherwise drops an
/// `obj_dir/` in whatever the current directory happens to be.
const Scratch = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    fn init(source: []const u8) Scratch {
        var s: Scratch = .{};
        const tag = std.fmt.bufPrint(&s.buf, "/tmp/zvf_{x}", .{std.hash.Wyhash.hash(0, source)}) catch unreachable;
        s.len = tag.len;
        return s;
    }

    /// `<stem><suffix>` — the returned slice borrows `self`, so keep it alive.
    fn path(self: *Scratch, comptime suffix: []const u8) []const u8 {
        @memcpy(self.buf[self.len..][0..suffix.len], suffix);
        return self.buf[0 .. self.len + suffix.len];
    }
};

/// Verilog source → contract.zig-compliant Zig device code.
pub fn fromVerilog(gpa: Allocator, io: Io, verilog_source: []const u8) ![]u8 {
    const cwd = Io.Dir.cwd();
    // One Scratch per name: `path` rewrites the shared buffer in place, so two
    // live slices from the same instance would alias.
    var v_s: Scratch = .init(verilog_source);
    var json_s: Scratch = .init(verilog_source);
    var obj_s: Scratch = .init(verilog_source);
    const v_path = v_s.path(".v");
    const json_path = json_s.path(".json");
    const obj_dir = obj_s.path(".obj");

    try cwd.writeFile(io, .{ .sub_path = v_path, .data = verilog_source });
    defer cwd.deleteFile(io, v_path) catch {};
    defer cwd.deleteFile(io, json_path) catch {};
    defer cwd.deleteTree(io, obj_dir) catch {};

    // -Wno-fatal: we want the AST, not a lint verdict. Upstream converters emit
    // technically-warned but well-defined code (sv2v renders `'0` as `1'sb0`,
    // which trips WIDTHEXPAND); real syntax errors still fail the run.
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ "verilator", "--json-only", "-Wno-fatal", "--Mdir", obj_dir, "--json-only-output", json_path, v_path },
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
    const verilog = try lowerToVerilog(gpa, io, sv_source, .system_verilog);
    defer gpa.free(verilog);
    return fromVerilog(gpa, io, verilog);
}

/// VHDL source → `ghdl synth --out=verilog` → fromVerilog.
///
/// GHDL picks the top entity itself, so the caller passes source only, like the
/// other front ends. Its output leans on internal wires, which is why net
/// support matters more here than for hand-written Verilog.
pub fn fromVhdl(gpa: Allocator, io: Io, vhdl_source: []const u8) ![]u8 {
    const verilog = try lowerToVerilog(gpa, io, vhdl_source, .vhdl);
    defer gpa.free(verilog);
    return fromVerilog(gpa, io, verilog);
}

const SourceKind = enum { system_verilog, vhdl };

/// Run the appropriate external converter and return its Verilog on stdout.
/// Caller owns the result.
fn lowerToVerilog(gpa: Allocator, io: Io, source: []const u8, kind: SourceKind) ![]u8 {
    const cwd = Io.Dir.cwd();
    // Same concurrency reason as fromVerilog: these run one per models/*.sv.
    var scratch: Scratch = .init(source);
    const path = switch (kind) {
        .system_verilog => scratch.path(".sv"),
        .vhdl => scratch.path(".vhd"),
    };

    try cwd.writeFile(io, .{ .sub_path = path, .data = source });
    defer cwd.deleteFile(io, path) catch {};

    const argv: []const []const u8 = switch (kind) {
        .system_verilog => &.{ "sv2v", path },
        .vhdl => &.{ "ghdl", "synth", "--std=08", "--out=verilog", path, "-e" },
    };

    const result = try std.process.run(gpa, io, .{ .argv = argv });
    errdefer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const failure = switch (kind) {
        .system_verilog => Error.Sv2vFailed,
        .vhdl => Error.GhdlFailed,
    };
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return failure;
        },
        else => {
            gpa.free(result.stdout);
            return failure;
        },
    }

    return result.stdout;
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
    var nets: Buf([]const u8) = .empty;
    defer nets.deinit(gpa);
    var blocks: Buf(Block) = .empty;
    defer blocks.deinit(gpa);
    defer for (blocks.items) |b| {
        gpa.free(b.edges);
        gpa.free(b.targets);
    };

    const TopStmt = enum { VAR, ALWAYS, INITIAL };
    const PortDir = enum { INPUT, OUTPUT };

    for (stmts) |stmt_val| {
        const stmt = stmt_val.object;
        const node_type = std.meta.stringToEnum(TopStmt, (stmt.get("type") orelse continue).string) orelse continue;

        switch (node_type) {
            .VAR => {
                const name = (stmt.get("origName") orelse continue).string;
                const width = dtypeWidth(&dtypes, stmt);
                const dir_str = (stmt.get("direction") orelse continue).string;
                if (std.meta.stringToEnum(PortDir, dir_str)) |dir| {
                    try ports.append(gpa, .{
                        .name = name,
                        .direction = if (dir == .INPUT) .input else .output,
                        .width = width,
                    });
                } else {
                    // An internal wire/reg. It becomes a plain Zig local sharing
                    // the namespace of the packed input locals, so it has to pass
                    // the same identifier rules as a port.
                    try codegen.validateIdent(name);
                    try nets.append(gpa, name);
                }
            },
            .ALWAYS, .INITIAL => try collectBlock(gpa, stmt, &blocks),
        }
    }

    var n_in: u32 = 0;
    var n_out: u32 = 0;
    for (ports.items) |p| switch (p.direction) {
        .input => n_in += 1,
        .output => n_out += 1,
    };
    if (n_in == 0) return Error.NoInputPorts;
    if (n_out == 0) return Error.NoOutputPorts;

    // Every target must be an output port or a declared internal net; anything
    // else would emit a local nothing reads, so reject rather than miscompile.
    // A net written by a clocked block is an internal register and needs state.
    var regs: Buf(codegen.Reg) = .empty;
    defer regs.deinit(gpa);

    for (blocks.items) |b| {
        for (b.targets) |t| {
            if (findPort(ports.items, t) != null) continue;
            if (!isNet(nets.items, t)) return Error.UnsupportedNode;
            if (b.edges.len == 0) continue;
            try regs.append(gpa, .{ .name = t, .width = netWidth(&dtypes, stmts, t) });
        }
    }

    // ── eval_stmts: combinational blocks, then the hold for each register ────
    var sw = Io.Writer.Allocating.init(gpa);
    errdefer sw.deinit();
    const w = &sw.writer;

    // A net must be assigned before it is read, and verilator emits blocks in
    // declaration order, not dataflow order. Emit whichever block has all its
    // net inputs ready, repeatedly; failure to progress means a comb loop.
    const emitted = try gpa.alloc(bool, blocks.items.len);
    defer gpa.free(emitted);
    @memset(emitted, false);

    var ready_nets: Buf([]const u8) = .empty;
    defer ready_nets.deinit(gpa);

    // A registered net holds last cycle's value and is unpacked from state.regs
    // before any combinational statement runs, so it is ready from the start.
    // Without this its readers look like an unsatisfiable dependency.
    for (regs.items) |r| try ready_nets.append(gpa, r.name);

    var pending: usize = 0;
    for (blocks.items) |b| {
        if (b.edges.len == 0) pending += 1;
    }

    while (pending > 0) {
        var progressed = false;
        for (blocks.items, 0..) |b, i| {
            if (emitted[i] or b.edges.len > 0) continue;
            if (!netsReady(gpa, b, nets.items, ready_nets.items)) continue;

            try emitBlockBody(w, b, &dtypes, 1, .combinational, nets.items);
            emitted[i] = true;
            pending -= 1;
            progressed = true;
            for (b.targets) |t| {
                if (isNet(nets.items, t)) try ready_nets.append(gpa, t);
            }
        }
        if (!progressed) return Error.UnsupportedNode; // combinational cycle
    }

    for (ports.items) |out_port| {
        if (out_port.direction != .output) continue;
        if (isRegistered(blocks.items, out_port.name)) {
            // Registered: evalBits holds the current value; the clocked block
            // is what advances it.
            try w.print("    const _{s}: u64 = prev_out_{s};\n", .{ out_port.name, out_port.name });
        } else if (!isDriven(blocks.items, out_port.name)) {
            return Error.MissingAssignment;
        }
    }

    const eval_stmts = try sw.toOwnedSlice();
    defer gpa.free(eval_stmts);

    // ── Clock groups: one per clocked always block ───────────────────────────
    var clock_groups: Buf(codegen.ClockGroup) = .empty;
    defer clock_groups.deinit(gpa);
    defer for (clock_groups.items) |cg| gpa.free(cg.next_state_stmts);

    for (blocks.items) |b| {
        if (b.edges.len == 0) continue;

        var ns_writer = Io.Writer.Allocating.init(gpa);
        errdefer ns_writer.deinit();
        try emitBlockBody(&ns_writer.writer, b, &dtypes, 2, .sequential, nets.items);
        const ns_stmts = try ns_writer.toOwnedSlice();
        errdefer gpa.free(ns_stmts);

        try clock_groups.append(gpa, .{
            .edges = b.edges,
            .registered = b.targets,
            .next_state_stmts = ns_stmts,
        });
    }

    // generateDevice iterates ports filtered by direction, so module
    // declaration order is passed through as-is.
    return codegen.generateDevice(gpa, .{
        .name = mod_name,
        .ports = ports.items,
        .regs = regs.items,
        .eval_stmts = eval_stmts,
        .clocks = clock_groups.items,
    });
}

fn findPort(ports: []const codegen.Port, name: []const u8) ?codegen.Port {
    for (ports) |p| {
        if (p.direction == .output and std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// Width of an internal net, read back off its VAR declaration.
fn netWidth(dtypes: *const DTypeMap, module_stmts: []const Value, name: []const u8) u16 {
    for (module_stmts) |stmt_val| {
        const stmt = stmt_val.object;
        const t = stmt.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "VAR")) continue;
        const n = stmt.get("origName") orelse continue;
        if (n == .string and std.mem.eql(u8, n.string, name)) return dtypeWidth(dtypes, stmt);
    }
    return 1;
}

fn isNet(nets: []const []const u8, name: []const u8) bool {
    for (nets) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// True if every internal net this block reads has already been emitted.
/// Reads of ports are always satisfied: inputs are packed by codegen before the
/// statements run, and a registered output is read through `prev_out_`.
fn netsReady(gpa: Allocator, block: Block, nets: []const []const u8, ready: []const []const u8) bool {
    var reads: Buf([]const u8) = .empty;
    defer reads.deinit(gpa);
    collectReads(gpa, block.stmts, &reads) catch return false;

    for (reads.items) |r| {
        if (!isNet(nets, r)) continue;
        // A block may read a net it also drives (e.g. `n = n & a`); that is a
        // self-loop, not a dependency on another block.
        if (isNet(block.targets, r)) continue;
        if (!isNet(ready, r)) return false;
    }
    return true;
}

/// Names read by a statement tree: assignment right-hand sides, branch
/// conditions and case selectors, but never assignment targets.
fn collectReads(gpa: Allocator, stmts: []const Value, out: *Buf([]const u8)) (TranslateError || Allocator.Error)!void {
    for (stmts) |stmt_val| {
        const stmt = stmt_val.object;
        const kind = std.meta.stringToEnum(ProcStmt, (stmt.get("type") orelse continue).string) orelse continue;
        switch (kind) {
            .ASSIGN, .ASSIGNW, .ASSIGNDLY => for (listOf(stmt, "rhsp")) |e| try collectVarRefs(gpa, e, out),
            .BEGIN => try collectReads(gpa, listOf(stmt, "stmtsp"), out),
            .IF => {
                for (listOf(stmt, "condp")) |e| try collectVarRefs(gpa, e, out);
                try collectReads(gpa, listOf(stmt, "thensp"), out);
                try collectReads(gpa, listOf(stmt, "elsesp"), out);
            },
            .CASE => {
                for (listOf(stmt, "exprp")) |e| try collectVarRefs(gpa, e, out);
                for (listOf(stmt, "itemsp")) |item| {
                    for (listOf(item.object, "condsp")) |e| try collectVarRefs(gpa, e, out);
                    try collectReads(gpa, listOf(item.object, "stmtsp"), out);
                }
            },
        }
    }
}

/// Every VARREF name inside one expression tree.
fn collectVarRefs(gpa: Allocator, node: Value, out: *Buf([]const u8)) Allocator.Error!void {
    if (node != .object) return;
    const obj = node.object;
    if (obj.get("type")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "VARREF")) {
            if (obj.get("name")) |n| {
                if (n == .string) try out.append(gpa, n.string);
            }
            return;
        }
    }
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .array) continue;
        for (entry.value_ptr.array.items) |c| try collectVarRefs(gpa, c, out);
    }
}

fn isRegistered(blocks: []const Block, name: []const u8) bool {
    for (blocks) |b| {
        if (b.edges.len == 0) continue;
        for (b.targets) |t| if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

fn isDriven(blocks: []const Block, name: []const u8) bool {
    for (blocks) |b| {
        for (b.targets) |t| if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

fn maskForWidth(width: u16) u64 {
    if (width >= 64) return 0; // no mask needed
    return (@as(u64, 1) << @intCast(width)) - 1;
}

// ============================================================================
// Always-block collection
//
// Every behavior in the module arrives as an ALWAYS node: a continuous
// `assign` is an ALWAYS holding one ASSIGNW, a combinational block has no
// sensitivity tree, and a clocked block carries one SENITEM per edge. Rather
// than pattern-matching a fixed handful of shapes, each block keeps its raw
// statement list and is emitted structurally by `emitBlockBody`.
// ============================================================================

/// One always block. `edges` is empty for combinational blocks; a clocked
/// block lists every edge in its sensitivity list, so `posedge clk or posedge
/// rst` (asynchronous reset) is two entries firing the same body.
const Block = struct {
    edges: []const codegen.ClockEdge,
    stmts: []const Value,
    /// Distinct assignment targets, in first-assignment order.
    targets: []const []const u8,
};

fn collectBlock(gpa: Allocator, always: ObjectMap, blocks: *Buf(Block)) !void {
    const EdgeType = enum { POS, NEG };

    var edges: Buf(codegen.ClockEdge) = .empty;
    errdefer edges.deinit(gpa);

    if (always.get("sentreep")) |sentree_val| {
        for (sentree_val.array.items) |st| {
            const senses = (st.object.get("sensesp") orelse continue).array.items;
            for (senses) |sense| {
                const edge = std.meta.stringToEnum(EdgeType, (sense.object.get("edgeType") orelse continue).string) orelse continue;
                const sensp = (sense.object.get("sensp") orelse continue).array.items;
                if (sensp.len == 0) continue;
                try edges.append(gpa, .{
                    .port = (sensp[0].object.get("name") orelse continue).string,
                    .edge = if (edge == .POS) .pos else .neg,
                });
            }
        }
    }

    const stmts = if (always.get("stmtsp")) |s| s.array.items else &[_]Value{};

    var targets: Buf([]const u8) = .empty;
    errdefer targets.deinit(gpa);
    try collectTargets(gpa, stmts, &targets);

    if (targets.items.len == 0) {
        edges.deinit(gpa);
        targets.deinit(gpa);
        return;
    }

    try blocks.append(gpa, .{
        .edges = try edges.toOwnedSlice(gpa),
        .stmts = stmts,
        .targets = try targets.toOwnedSlice(gpa),
    });
}

/// Walk a statement tree gathering the distinct names it assigns to.
fn collectTargets(gpa: Allocator, stmts: []const Value, out: *Buf([]const u8)) (TranslateError || Allocator.Error)!void {
    for (stmts) |stmt_val| {
        const stmt = stmt_val.object;
        const kind = std.meta.stringToEnum(ProcStmt, (stmt.get("type") orelse continue).string) orelse
            return Error.UnsupportedNode;

        switch (kind) {
            .ASSIGN, .ASSIGNW, .ASSIGNDLY => {
                const lhs = try child(stmt, "lhsp");
                const name = (lhs.object.get("name") orelse return Error.UnsupportedNode).string;
                for (out.items) |seen| {
                    if (std.mem.eql(u8, seen, name)) break;
                } else try out.append(gpa, name);
            },
            .BEGIN => try collectTargets(gpa, listOf(stmt, "stmtsp"), out),
            .IF => {
                try collectTargets(gpa, listOf(stmt, "thensp"), out);
                try collectTargets(gpa, listOf(stmt, "elsesp"), out);
            },
            .CASE => {
                for (listOf(stmt, "itemsp")) |item| {
                    try collectTargets(gpa, listOf(item.object, "stmtsp"), out);
                }
            },
        }
    }
}

fn listOf(obj: ObjectMap, key: []const u8) []const Value {
    const val = obj.get(key) orelse return &.{};
    if (val != .array) return &.{};
    return val.array.items;
}

// ============================================================================
// Procedural statement → Zig
// ============================================================================

const ProcStmt = enum { ASSIGN, ASSIGNW, ASSIGNDLY, BEGIN, IF, CASE };

const BlockKind = enum { combinational, sequential };

fn writeIndent(w: *Io.Writer, depth: u8) Io.Writer.Error!void {
    for (0..depth) |_| try w.writeAll("    ");
}

/// Emit one always block's body.
///
/// A block that is just a single unconditional assignment keeps the tight
/// `const _y = expr;` form. Anything with control flow declares a mutable
/// `_target` per assigned signal and then mirrors the Verilog statement
/// structure, which is what gives if/else-if priority and "no branch taken =
/// hold" their correct semantics for free.
fn emitBlockBody(
    w: *Io.Writer,
    block: Block,
    dtypes: *const DTypeMap,
    depth: u8,
    kind: BlockKind,
    nets: []const []const u8,
) TranslateError!void {
    // In a clocked block every target is written back by codegen from `_name`,
    // registers included — so no target takes the bare net spelling there.
    const target_nets: []const []const u8 = switch (kind) {
        .sequential => &.{},
        .combinational => nets,
    };

    if (singleAssign(block.stmts)) |sa| {
        const mask = maskForWidth(dtypeWidth(dtypes, sa.lhs.object));
        try writeIndent(w, depth);
        try w.print("const {s}{s}: u64 = ", .{ localPrefix(target_nets, sa.target), sa.target });
        try translateExpr(w, sa.rhs, dtypes);
        if (mask != 0) try w.print(" & 0x{x}", .{mask});
        try w.writeAll(";\n");
        return;
    }

    for (block.targets) |t| {
        const p = localPrefix(target_nets, t);
        try writeIndent(w, depth);
        switch (kind) {
            // A register not written on this edge keeps its value, so seed the
            // local from the current output; codegen packs `t` from state.outputs.
            .sequential => try w.print("var _{s}: u64 = {s};\n", .{ t, t }),
            // Seed from the previous output value. A block that assigns on every
            // path overwrites this immediately; one that does not is exactly
            // Verilog's inferred latch, and holding is the defined behavior.
            // Internal nets have no state to hold, so they start at 0 — a latched
            // net would need register storage, and is rejected below.
            .combinational => if (p.len == 0)
                try w.print("var {s}: u64 = 0;\n", .{t})
            else
                try w.print("var _{s}: u64 = prev_out_{s};\n", .{ t, t }),
        }
    }
    for (block.stmts) |s| try emitStmt(w, s, dtypes, depth, target_nets);
}

/// Output ports are emitted as `_name` (codegen reads those to pack results);
/// internal nets keep their bare name so that a VARREF to them, which
/// `translateExpr` writes verbatim, resolves to the same local.
fn localPrefix(nets: []const []const u8, name: []const u8) []const u8 {
    return if (isNet(nets, name)) "" else "_";
}

const SingleAssign = struct {
    target: []const u8,
    lhs: Value,
    rhs: Value,
};

/// Unwrap nested BEGINs; if the block is exactly one unconditional assignment,
/// return it so the caller can emit the compact `const` form.
fn singleAssign(stmts: []const Value) ?SingleAssign {
    if (stmts.len != 1) return null;
    const stmt = stmts[0].object;
    const kind = std.meta.stringToEnum(ProcStmt, (stmt.get("type") orelse return null).string) orelse return null;
    switch (kind) {
        .BEGIN => return singleAssign(listOf(stmt, "stmtsp")),
        .ASSIGN, .ASSIGNW, .ASSIGNDLY => {
            const lhs_arr = listOf(stmt, "lhsp");
            const rhs_arr = listOf(stmt, "rhsp");
            if (lhs_arr.len == 0 or rhs_arr.len == 0) return null;
            const name = (lhs_arr[0].object.get("name") orelse return null).string;
            return .{ .target = name, .lhs = lhs_arr[0], .rhs = rhs_arr[0] };
        },
        else => return null,
    }
}

fn emitStmt(w: *Io.Writer, node: Value, dtypes: *const DTypeMap, depth: u8, nets: []const []const u8) TranslateError!void {
    const stmt = node.object;
    const kind = std.meta.stringToEnum(ProcStmt, (stmt.get("type") orelse return Error.UnsupportedNode).string) orelse
        return Error.UnsupportedNode;

    switch (kind) {
        .ASSIGN, .ASSIGNW, .ASSIGNDLY => {
            const lhs = try child(stmt, "lhsp");
            const rhs = try child(stmt, "rhsp");
            const target = (lhs.object.get("name") orelse return Error.UnsupportedNode).string;
            const mask = maskForWidth(dtypeWidth(dtypes, lhs.object));
            try writeIndent(w, depth);
            try w.print("{s}{s} = ", .{ localPrefix(nets, target), target });
            try translateExpr(w, rhs, dtypes);
            if (mask != 0) try w.print(" & 0x{x}", .{mask});
            try w.writeAll(";\n");
        },

        .BEGIN => for (listOf(stmt, "stmtsp")) |s| try emitStmt(w, s, dtypes, depth, nets),

        .IF => {
            try writeIndent(w, depth);
            try w.writeAll("if (");
            try translateExpr(w, try child(stmt, "condp"), dtypes);
            try w.writeAll(" != 0) {\n");
            for (listOf(stmt, "thensp")) |s| try emitStmt(w, s, dtypes, depth + 1, nets);
            const else_stmts = listOf(stmt, "elsesp");
            if (else_stmts.len > 0) {
                try writeIndent(w, depth);
                try w.writeAll("} else {\n");
                for (else_stmts) |s| try emitStmt(w, s, dtypes, depth + 1, nets);
            }
            try writeIndent(w, depth);
            try w.writeAll("}\n");
        },

        .CASE => {
            const sel = try child(stmt, "exprp");
            var first = true;
            var default_stmts: []const Value = &.{};

            for (listOf(stmt, "itemsp")) |item_val| {
                const item = item_val.object;
                const conds = listOf(item, "condsp");
                if (conds.len == 0) {
                    default_stmts = listOf(item, "stmtsp");
                    continue;
                }
                if (first) {
                    try writeIndent(w, depth);
                    try w.writeAll("if (");
                    first = false;
                } else {
                    try w.writeAll(" else if (");
                }
                // `2'b00, 2'b01: ...` — one branch, several matching values.
                for (conds, 0..) |c, i| {
                    if (i > 0) try w.writeAll(" or ");
                    try translateExpr(w, sel, dtypes);
                    try w.writeAll(" == ");
                    try translateExpr(w, c, dtypes);
                }
                try w.writeAll(") {\n");
                for (listOf(item, "stmtsp")) |s| try emitStmt(w, s, dtypes, depth + 1, nets);
                try writeIndent(w, depth);
                try w.writeAll("}");
            }

            if (default_stmts.len > 0) {
                if (first) {
                    try writeIndent(w, depth);
                    try w.writeAll("{\n");
                } else {
                    try w.writeAll(" else {\n");
                }
                for (default_stmts) |s| try emitStmt(w, s, dtypes, depth + 1, nets);
                try writeIndent(w, depth);
                try w.writeAll("}");
            }
            if (!first or default_stmts.len > 0) try w.writeAll("\n");
        },
    }
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
    VARREF,
    CONST,
    AND,
    OR,
    XOR,
    ADD,
    SUB,
    MUL,
    DIV,
    MODDIV,
    EQ,
    NEQ,
    EQCASE,
    NEQCASE,
    GT,
    GTE,
    LT,
    LTE,
    SHIFTL,
    SHIFTR,
    SHIFTRS,
    NOT,
    NEGATE,
    EXTEND,
    REDOR,
    REDAND,
    REDXOR,
    COND,
    SEL,
    CONCAT,
    REPLICATE,
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
