//! AST → MIR lowering. Walks the parsed module top-down: nodes/ports become
//! block params (the x[u] vector), parameters become runtime `param_ref`
//! reads, the analog block lowers to SSA, and every `<+` contribution is
//! split into its resistive and reactive (ddt) accumulator places.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buf = @import("emit").Buf;
const Ast = @import("../frontend/Ast.zig");
const Mir = @import("Mir.zig");
const SsaBuilder = @import("SsaBuilder.zig");

const Lower = @This();

const Block = Mir.Block;
const Value = Mir.Value;
const Opcode = Mir.Opcode;
const Place = SsaBuilder.Place;

pub const LowerError = std.mem.Allocator.Error || error{ParseError};

pub const NoiseKind = enum(u1) { thermal, flicker };

pub const Contribution = struct {
    kind: Ast.ContributeKind,
    nature: []const u8,
    nodes: []const []const u8,
    resist_place: Place,
    react_place: Place,
    resist_val: Value = .undef,
    react_val: Value = .undef,
    noise_kind: ?NoiseKind = null,
    noise_args: [2]?Value = .{ null, null },
};

pub const ParamInfo = struct {
    name: []const u8,
    ty: Ast.Type,
    place: Place,
    default: ?Value,
};

/// A named `branch (a[,b]) name;` declaration. Contributions to it
/// accumulate here (flow and potential separately); placement is decided at
/// finalize: plain flow branches stamp their node pair directly, while
/// probed branches / potential (switch) branches get a branch-current
/// unknown with a constraint row.
pub const BranchInfo = struct {
    name: []const u8,
    nodes: [2]?[]const u8, // [hi, lo]; lo == null → ground branch
    flow_resist: Place,
    flow_react: Place,
    pot_resist: Place,
    pot_react: Place,
    /// Runtime mode indicator: 1.0 when the last executed contribution was a
    /// potential one (switch branches flip this per LRM "last wins").
    vmode: Place,
    cur_place: ?Place = null, // branch-current unknown (x[] slot)
    cur_name: ?[]const u8 = null,
    has_flow: bool = false,
    has_pot: bool = false,
    probed: bool = false,
    noise_kind: ?NoiseKind = null,
    noise_args: [2]?Value = .{ null, null },
};

// ponytail: flat scope tracking replaces per-scope HashMaps; upgrade to
// segmented bitset if place count exceeds ~64K and memset shows on profile.
const ScopeMod = struct { place: Place, pre_val: Value };

builder: SsaBuilder,
allocator: Allocator,

stmts: []const Ast.Stmt,

// ── SoA expression storage (borrowed from the parser) ────────────────
expr_tags: []const Ast.ExprTag,
expr_lhs: []const u32,
expr_rhs: []const u32,
extra_data: []const u32,
str_refs: []const []const u8,

var_map: std.StringHashMapUnmanaged(Place) = .empty,
params: Buf(ParamInfo) = .{},
contributions: Buf(Contribution) = .{},
node_voltages: std.StringHashMapUnmanaged(Place) = .empty,
branches: std.StringHashMapUnmanaged(BranchInfo) = .empty,
builtin_funcs: std.StringHashMapUnmanaged(Mir.FuncRef) = .empty,
user_funcs: std.StringHashMapUnmanaged(Ast.FuncDecl) = .empty,

/// Module ports are registered into `node_order` first, so the port names
/// are exactly node_order[0..num_ports] — no separate list.
num_ports: u16 = 0,
node_order: Buf([]const u8) = .{},

/// Straight-line value cache per place: skips SSA hashmap lookups outside
/// loops. Generation-tagged: bump val_gen to invalidate all entries in O(1)
/// instead of memset over the entire array.
val_arr: Buf(Value) = .{},
val_gens: Buf(u32) = .{},
val_gen: u32 = 1,
scope_stack: Buf(u32) = .{},
scope_mods: Buf(ScopeMod) = .{},
scope_seen_gens: []u32 = &.{},
scope_gen: u32 = 1,
loop_depth: u32 = 0,
/// Cache for stmtHasLoop: 0=unknown, 1=no-loop, 2=has-loop.
loop_cache: []u2 = &.{},

pub fn init(
    allocator: Allocator,
    mir: *Mir,
    stmts: []const Ast.Stmt,
    expr_tags: []const Ast.ExprTag,
    expr_lhs: []const u32,
    expr_rhs: []const u32,
    extra_data: []const u32,
    str_refs: []const []const u8,
) !Lower {
    // Pre-size MIR storage: ratios tuned from bsim4 profile (38K exprs →
    // 21K insts, 26K values, 15K extra).
    const n = expr_tags.len;
    if (n > 64) {
        const ma = mir.allocator;
        try mir.insts.ensureTotalCapacity(ma, n * 2 / 3);
        try mir.values.ensureTotalCapacity(ma, @max(n, Mir.Value.first_dynamic));
        try mir.extra.ensureTotalCapacity(ma, n / 2);
    }

    const scope_seen_gens = try allocator.alloc(u32, str_refs.len);
    @memset(scope_seen_gens, 0);
    const loop_cache = try allocator.alloc(u2, stmts.len);
    @memset(loop_cache, 0);
    var self = Lower{
        .builder = SsaBuilder.init(mir),
        .allocator = allocator,
        .stmts = stmts,
        .expr_tags = expr_tags,
        .expr_lhs = expr_lhs,
        .expr_rhs = expr_rhs,
        .extra_data = extra_data,
        .str_refs = str_refs,
        .scope_seen_gens = scope_seen_gens,
        .loop_cache = loop_cache,
    };
    try self.val_arr.ensureTotalCapacity(allocator, str_refs.len);
    try self.val_gens.ensureTotalCapacity(allocator, str_refs.len);
    try self.scope_mods.ensureTotalCapacity(allocator, n / 4);
    return self;
}

pub fn deinit(self: *Lower) void {
    self.builder.deinit();
    self.var_map.deinit(self.allocator);
    self.params.deinit(self.allocator);
    self.contributions.deinit(self.allocator);
    self.node_voltages.deinit(self.allocator);
    self.branches.deinit(self.allocator);
    self.builtin_funcs.deinit(self.allocator);
    self.user_funcs.deinit(self.allocator);
    self.node_order.deinit(self.allocator);
    self.val_arr.deinit(self.allocator);
    if (self.scope_seen_gens.len > 0) self.allocator.free(self.scope_seen_gens);
    self.scope_stack.deinit(self.allocator);
    self.scope_mods.deinit(self.allocator);
    self.val_gens.deinit(self.allocator);
    if (self.loop_cache.len > 0) self.allocator.free(self.loop_cache);
}

fn allocPlace(self: *Lower) !Place {
    const p = try self.builder.newPlace();
    try self.val_arr.append(self.allocator, .undef);
    try self.val_gens.append(self.allocator, 0);
    return p;
}

/// Current value of a place: the straight-line cache when fresh, else the
/// SSA builder. A loop wipes the cache wholesale (stale-undef), so an undef
/// cache entry must NOT be taken as "the variable has no value".
fn currentVal(self: *Lower, place: Place) !Value {
    const pid = @intFromEnum(place);
    if (pid < self.val_arr.len and self.val_gens.slice()[pid] == self.val_gen) {
        const v = self.val_arr.slice()[pid];
        if (v != .undef) return v;
    }
    return self.builder.useVar(place);
}

fn writeVar(self: *Lower, place: Place, val: Value) !void {
    const pid = @intFromEnum(place);
    if (self.scope_stack.len > 0) {
        if (pid >= self.scope_seen_gens.len or self.scope_seen_gens[pid] != self.scope_gen) {
            if (pid < self.scope_seen_gens.len) self.scope_seen_gens[pid] = self.scope_gen;
            try self.scope_mods.append(self.allocator, .{
                .place = place,
                .pre_val = try self.currentVal(place),
            });
        }
    }
    if (self.loop_depth == 0) {
        if (pid < self.val_arr.len) {
            self.val_arr.slice()[pid] = val;
            self.val_gens.slice()[pid] = self.val_gen;
        }
    }
    try self.builder.defVar(place, val, self.builder.currentBlock());
}

fn readVar(self: *Lower, place: Place) !Value {
    if (self.loop_depth == 0) {
        const pid = @intFromEnum(place);
        if (pid < self.val_arr.len and self.val_gens.slice()[pid] == self.val_gen) {
            const v = self.val_arr.slice()[pid];
            if (v != .undef) return v;
        }
    }
    return self.builder.useVar(place);
}

fn getStmt(self: *const Lower, id: Ast.StmtId) Ast.Stmt {
    return self.stmts[@intFromEnum(id)];
}

// ── SoA expression accessors ────────────────────────────────────────

fn exprTag(self: *const Lower, id: Ast.ExprId) Ast.ExprTag {
    return self.expr_tags[@intFromEnum(id)];
}

fn exprLhs(self: *const Lower, id: Ast.ExprId) u32 {
    return self.expr_lhs[@intFromEnum(id)];
}

fn exprRhs(self: *const Lower, id: Ast.ExprId) u32 {
    return self.expr_rhs[@intFromEnum(id)];
}

fn exprStr(self: *const Lower, str_idx: u32) []const u8 {
    return self.str_refs[str_idx];
}

fn readF64Extra(self: *const Lower, idx: u32) f64 {
    const lo: u64 = self.extra_data[idx];
    const hi: u64 = self.extra_data[idx + 1];
    return @bitCast((hi << 32) | lo);
}

fn readI64Extra(self: *const Lower, idx: u32) i64 {
    const lo: u64 = self.extra_data[idx];
    const hi: u64 = self.extra_data[idx + 1];
    return @bitCast((hi << 32) | lo);
}

/// Return a slice of ExprIds encoded in extra_data starting at `extra_idx`.
/// Layout: extra_data[extra_idx] = count, followed by count ExprId values.
fn callArgs(self: *const Lower, extra_idx: u32) []const Ast.ExprId {
    const count = self.extra_data[extra_idx];
    const raw = self.extra_data[extra_idx + 1 ..][0..count];
    return @as([*]const Ast.ExprId, @ptrCast(raw.ptr))[0..count];
}

pub fn lowerModule(self: *Lower, module: *const Ast.ModuleDecl) !void {
    const entry = try self.builder.createBlock();
    self.builder.switchToBlock(entry);
    try self.builder.sealBlock(entry);

    // Ports first: node_order[0..num_ports] are exactly the module ports.
    for (module.ports) |port| {
        try self.registerNodeVoltage(port.name);
    }
    self.num_ports = @intCast(module.ports.len);

    for (module.items) |item| {
        switch (item) {
            .port_decl => |pd| {
                for (pd.names) |name| try self.registerNodeVoltage(name);
            },
            .net_decl => |nd| {
                for (nd.names) |name| try self.registerNodeVoltage(name);
            },
            .param_decl => |pd| try self.lowerParamDecl(&pd),
            .var_decl => |vd| try self.lowerVarDecl(&vd),
            .analog_block => |ab| try self.lowerStmt(ab.stmt),
            .analog_initial => |ai| try self.lowerStmt(ai.stmt),
            .alias_param => |ap| {
                const place = if (self.var_map.get(ap.target)) |p| p else blk: {
                    const p = try self.allocPlace();
                    try self.writeVar(p, .undef);
                    break :blk p;
                };
                try self.params.append(self.allocator, .{
                    .name = ap.name,
                    .ty = .real,
                    .place = place,
                    .default = null,
                });
            },
            .branch_decl => |bd| try self.registerBranch(&bd),
            .func_decl => |fd| try self.user_funcs.put(self.allocator, fd.name, fd),
        }
    }

    const pre_exit = self.builder.currentBlock();
    const exit = try self.builder.createBlock();
    try self.builder.buildJump(exit);
    try self.builder.addPredecessor(exit, pre_exit);
    self.builder.switchToBlock(exit);
    try self.builder.sealBlock(exit);

    try self.finalizeBranches();

    for (self.contributions.slice()) |*c| {
        c.resist_val = try self.readVar(c.resist_place);
        c.react_val = try self.readVar(c.react_place);
    }
}

fn registerNodeVoltage(self: *Lower, name: []const u8) !void {
    if (!self.node_voltages.contains(name)) {
        const place = try self.allocPlace();
        try self.node_voltages.put(self.allocator, name, place);
        const idx: u16 = @intCast(self.node_order.len);
        try self.node_order.append(self.allocator, name);
        const bp_val = try self.builder.mir.addValue(.{ .block_param = .{
            .block = self.builder.currentBlock(),
            .index = idx,
        } });
        try self.writeVar(place, bp_val);
    }
}

pub fn lowerParamDecl(self: *Lower, pd: *const Ast.ParamDecl) !void {
    const place = try self.allocPlace();
    try self.var_map.put(self.allocator, pd.name, place);

    var default: ?Value = null;
    if (pd.default.valid()) {
        default = try self.lowerExpr(pd.default);
    }

    if (pd.is_local) {
        // localparam: a derived constant. Its place holds the computed
        // expression so it tracks the (runtime) parameters it depends on.
        if (default) |d| try self.writeVar(place, d);
    } else {
        // parameter: user-settable. The place holds a param_ref, so every read
        // resolves to a runtime `model.<name>` read; the lowered default only
        // becomes the Model struct field's default in codegen.
        const idx: u32 = self.params.len;
        const pref = try self.builder.mir.addValue(.{ .param_ref = idx });
        try self.writeVar(place, pref);
    }

    try self.params.append(self.allocator, .{
        .name = pd.name, .ty = pd.ty, .place = place, .default = default,
    });
}

fn lowerVarDecl(self: *Lower, vd: *const Ast.VarDecl) !void {
    for (vd.names, vd.init_values) |name, init_id| {
        const place = try self.allocPlace();
        try self.var_map.put(self.allocator, name, place);

        const init_val: Value = if (init_id.valid())
            try self.lowerExpr(init_id)
        else switch (vd.ty) {
            .real => .f_zero,
            .integer => .zero,
            .string => .undef,
        };
        try self.writeVar(place, init_val);
    }
}

fn lowerStmt(self: *Lower, id: Ast.StmtId) LowerError!void {
    if (!id.valid()) return;
    const stmt = self.getStmt(id);
    switch (stmt) {
        .empty => {},
        .expr_stmt => |eid| _ = try self.lowerExpr(eid),
        .assign => |a| {
            const val = try self.lowerExpr(a.value);
            if (a.target.valid()) {
                const target_name = self.resolveIdentName(a.target);
                if (target_name) |name| {
                    const place = self.var_map.get(name) orelse {
                        const p = try self.allocPlace();
                        try self.var_map.put(self.allocator, name, p);
                        try self.writeVar(p, val);
                        return;
                    };
                    try self.writeVar(place, val);
                }
            }
        },
        .contribute => |c| try self.lowerContribute(c.kind, c.branch, c.rhs),
        .block => |b| {
            for (b.local_vars) |vd| try self.lowerVarDecl(&vd);
            for (b.local_params) |pd| try self.lowerParamDecl(&pd);
            for (b.stmts) |sid| try self.lowerStmt(sid);
        },
        .if_stmt => |i| try self.lowerIf(i.cond, i.then_branch, i.else_branch),
        .while_stmt => |w| try self.lowerWhile(w.cond, w.body),
        .for_stmt => |f| try self.lowerFor(&f),
        .case_stmt => |cs| try self.lowerCase(cs.discriminant, cs.arms),
        .event_control => |ec| {
            // Lower event as conditional guard — the host provides the callback.
            if (ec.event.valid()) {
                try self.lowerIf(ec.event, ec.body, .none);
            } else {
                try self.lowerStmt(ec.body);
            }
        },
        .disable => {},
    }
}

fn registerBranch(self: *Lower, bd: *const Ast.BranchDecl) !void {
    if (self.branches.contains(bd.name)) return;
    try self.registerNodeVoltage(bd.node_a);
    if (bd.node_b) |b| try self.registerNodeVoltage(b);
    const info: BranchInfo = .{
        .name = bd.name,
        .nodes = .{ bd.node_a, bd.node_b },
        .flow_resist = try self.allocPlace(),
        .flow_react = try self.allocPlace(),
        .pot_resist = try self.allocPlace(),
        .pot_react = try self.allocPlace(),
        .vmode = try self.allocPlace(),
    };
    try self.writeVar(info.flow_resist, .f_zero);
    try self.writeVar(info.flow_react, .f_zero);
    try self.writeVar(info.pot_resist, .f_zero);
    try self.writeVar(info.pot_react, .f_zero);
    try self.writeVar(info.vmode, .f_zero);
    try self.branches.put(self.allocator, bd.name, info);
}

/// Get-or-create the implicit branch for a plain node pair (potential
/// contributions only; flow contributions on pairs stamp directly).
fn implicitBranch(self: *Lower, nodes: []const []const u8) !*BranchInfo {
    const name = if (nodes.len > 1)
        try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ nodes[0], nodes[1] })
    else
        try self.allocator.dupe(u8, nodes[0]);
    // '#' keeps implicit keys out of the named-branch namespace.
    const key = try std.fmt.allocPrint(self.allocator, "{s}#v", .{name});
    const gop = try self.branches.getOrPut(self.allocator, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .name = name,
            .nodes = .{ nodes[0], if (nodes.len > 1) nodes[1] else null },
            .flow_resist = try self.allocPlace(),
            .flow_react = try self.allocPlace(),
            .pot_resist = try self.allocPlace(),
            .pot_react = try self.allocPlace(),
            .vmode = try self.allocPlace(),
        };
        try self.writeVar(gop.value_ptr.flow_resist, .f_zero);
        try self.writeVar(gop.value_ptr.flow_react, .f_zero);
        try self.writeVar(gop.value_ptr.pot_resist, .f_zero);
        try self.writeVar(gop.value_ptr.pot_react, .f_zero);
        try self.writeVar(gop.value_ptr.vmode, .f_zero);
    }
    return gop.value_ptr;
}

/// Value of node `name` (registering it on first sight, like resolveNodeArg).
fn nodeValue(self: *Lower, name: []const u8) !Value {
    if (self.node_voltages.get(name)) |place| return self.readVar(place);
    try self.registerNodeVoltage(name);
    return self.readVar(self.node_voltages.get(name).?);
}

/// Give a branch its own current unknown (an extra internal x[] slot).
fn ensureBranchCurrent(self: *Lower, bi: *BranchInfo) !void {
    if (bi.cur_place != null) return;
    const uname = try std.fmt.allocPrint(self.allocator, "{s}_ibr", .{bi.name});
    try self.registerNodeVoltage(uname);
    bi.cur_place = self.node_voltages.get(uname).?;
    bi.cur_name = uname;
}

/// Access-function read of a named branch: V(br)/Temp(br) is the potential
/// across its node pair; I(br)/Pwr(br) is the branch current, which forces
/// the branch-current unknown into existence.
fn branchProbe(self: *Lower, nature: []const u8, bi: *BranchInfo) !Value {
    const is_flow = std.mem.eql(u8, nature, "I") or
        std.mem.eql(u8, nature, "Ip") or std.mem.eql(u8, nature, "Pwr");
    if (is_flow) {
        try self.ensureBranchCurrent(bi);
        bi.probed = true;
        return self.readVar(bi.cur_place.?);
    }
    const hi = try self.nodeValue(bi.nodes[0].?);
    if (bi.nodes[1]) |lo_name| {
        const lo = try self.nodeValue(lo_name);
        return self.builder.buildBinary(.fsub, hi, lo);
    }
    return hi;
}

/// Contribution to a named branch: accumulate into the branch's flow or
/// potential places; stamping is deferred to finalizeBranches.
fn lowerBranchContribute(self: *Lower, bi: *BranchInfo, nature: []const u8, kind: Ast.ContributeKind, rhs_id: Ast.ExprId) !void {
    const is_pot = kind == .potential or std.mem.eql(u8, nature, "Temp");
    if (is_pot) {
        bi.has_pot = true;
        try self.writeVar(bi.vmode, .f_one);
        try self.splitContribution(rhs_id, bi.pot_resist, bi.pot_react, false);
    } else {
        bi.has_flow = true;
        try self.writeVar(bi.vmode, .f_zero);
        if (self.detectNoiseKind(rhs_id)) |nk| {
            bi.noise_kind = nk;
            bi.noise_args = self.extractNoiseArgs(rhs_id);
        }
        try self.splitContribution(rhs_id, bi.flow_resist, bi.flow_react, false);
    }
}

/// Turn every used branch into contributions (runs in the exit block):
///  - plain flow branch: stamp the accumulated flow on its node pair;
///  - probed / potential / switch branch: KCL rows carry the branch-current
///    unknown j, and j's own row carries the constraint
///    flow mode:      flow_acc - j            (+ d/dt of flow reactive)
///    potential mode: pot_acc  - (V(hi)-V(lo)) (+ d/dt of pot reactive)
///    switch branch:  select on the runtime mode indicator.
fn finalizeBranches(self: *Lower) !void {
    var it = self.branches.valueIterator();
    while (it.next()) |bi| {
        if (!bi.has_flow and !bi.has_pot and bi.cur_place == null) continue;

        var nodes_buf: [2][]const u8 = undefined;
        nodes_buf[0] = bi.nodes[0].?;
        var n_nodes: usize = 1;
        if (bi.nodes[1]) |lo| {
            nodes_buf[1] = lo;
            n_nodes = 2;
        }

        const needs_unknown = bi.probed or bi.has_pot or bi.cur_place != null;
        if (!needs_unknown) {
            try self.contributions.append(self.allocator, .{
                .kind = .flow,
                .nature = "I",
                .nodes = try self.allocator.dupe([]const u8, nodes_buf[0..n_nodes]),
                .resist_place = bi.flow_resist,
                .react_place = bi.flow_react,
                .noise_kind = bi.noise_kind,
                .noise_args = bi.noise_args,
            });
            continue;
        }

        try self.ensureBranchCurrent(bi);
        const j = try self.readVar(bi.cur_place.?);

        // KCL rows: j flows hi -> lo.
        const kcl_r = try self.allocPlace();
        try self.writeVar(kcl_r, j);
        const kcl_q = try self.allocPlace();
        try self.writeVar(kcl_q, .f_zero);
        try self.contributions.append(self.allocator, .{
            .kind = .flow,
            .nature = "I",
            .nodes = try self.allocator.dupe([]const u8, nodes_buf[0..n_nodes]),
            .resist_place = kcl_r,
            .react_place = kcl_q,
            .noise_kind = bi.noise_kind,
            .noise_args = bi.noise_args,
        });

        // Constraint row.
        const hi = try self.nodeValue(nodes_buf[0]);
        const vdiff = if (n_nodes == 2)
            try self.builder.buildBinary(.fsub, hi, try self.nodeValue(nodes_buf[1]))
        else
            hi;
        const flow_r = try self.readVar(bi.flow_resist);
        const flow_q = try self.readVar(bi.flow_react);
        const pot_r = try self.readVar(bi.pot_resist);
        const pot_q = try self.readVar(bi.pot_react);
        const flow_c = try self.builder.buildBinary(.fsub, flow_r, j);
        const pot_c = try self.builder.buildBinary(.fsub, pot_r, vdiff);

        var res_c: Value = undefined;
        var q_c: Value = undefined;
        if (bi.has_pot) {
            // The potential contribution may be conditional (switch branch,
            // CollapsableR): decide the mode at runtime. vmode is 1.0 iff a
            // potential contribution executed last; unconditional V folds to
            // the potential arm, and when nothing executed the branch is an
            // open flow branch with j = 0.
            const vm = try self.readVar(bi.vmode);
            res_c = try self.builder.buildSelect(vm, pot_c, flow_c);
            q_c = try self.builder.buildSelect(vm, pot_q, flow_q);
        } else {
            res_c = flow_c;
            q_c = flow_q;
        }

        const con_r = try self.allocPlace();
        try self.writeVar(con_r, res_c);
        const con_q = try self.allocPlace();
        try self.writeVar(con_q, q_c);
        try self.contributions.append(self.allocator, .{
            .kind = .flow,
            .nature = "I",
            .nodes = try self.allocator.dupe([]const u8, &.{bi.cur_name.?}),
            .resist_place = con_r,
            .react_place = con_q,
        });
    }
}

fn lowerContribute(self: *Lower, kind: Ast.ContributeKind, branch_id: Ast.ExprId, rhs_id: Ast.ExprId) !void {
    var nature_name: []const u8 = "I";
    var node_names_buf: [4][]const u8 = undefined;
    var node_count: usize = 0;

    if (branch_id.valid()) {
        if (self.exprTag(branch_id) == .nature_access) {
            nature_name = self.exprStr(self.exprLhs(branch_id));
            const args = self.callArgs(self.exprRhs(branch_id));
            for (args) |arg_id| {
                if (arg_id.valid()) {
                    const name = self.resolveIdentName(arg_id);
                    if (node_count < node_names_buf.len) {
                        node_names_buf[node_count] = name orelse "?";
                        node_count += 1;
                    }
                }
            }
        }
    }

    // Named-branch target: `I(br) <+ …` / `V(br) <+ …`.
    if (node_count == 1) {
        if (self.branches.getPtr(node_names_buf[0])) |bi| {
            return self.lowerBranchContribute(bi, nature_name, kind, rhs_id);
        }
    }

    // Potential contribution to a plain node pair (`V(N1,N2) <+ 0.0`):
    // an implicit switch branch — PSP103's CollapsableR collapses zero-ohm
    // internal nodes this way. Stamping a potential as a current silently
    // leaves the pair floating.
    if ((kind == .potential or std.mem.eql(u8, nature_name, "Temp")) and node_count >= 1) {
        const bi = try self.implicitBranch(node_names_buf[0..node_count]);
        return self.lowerBranchContribute(bi, nature_name, kind, rhs_id);
    }

    const node_names = node_names_buf[0..node_count];

    var found: ?*Contribution = null;
    for (self.contributions.slice()) |*contrib| {
        if (std.mem.eql(u8, contrib.nature, nature_name) and contrib.nodes.len == node_names.len) {
            var match = true;
            for (contrib.nodes, node_names) |a, b| {
                if (!std.mem.eql(u8, a, b)) { match = false; break; }
            }
            if (match) { found = contrib; break; }
        }
    }

    if (found == null) {
        const resist_place = try self.allocPlace();
        const react_place = try self.allocPlace();
        try self.writeVar(resist_place, .f_zero);
        try self.writeVar(react_place, .f_zero);
        try self.contributions.append(self.allocator, .{
            .kind = kind,
            .nature = nature_name,
            .nodes = try self.allocator.dupe([]const u8, node_names),
            .resist_place = resist_place,
            .react_place = react_place,
        });
        found = &self.contributions.slice()[self.contributions.len - 1];
    }

    const contrib = found.?;
    if (self.detectNoiseKind(rhs_id)) |noise_kind| {
        contrib.noise_kind = noise_kind;
        const nargs = self.extractNoiseArgs(rhs_id);
        contrib.noise_args = nargs;
    }
    try self.splitContribution(rhs_id, contrib.resist_place, contrib.react_place, false);
}

fn detectNoiseKind(self: *const Lower, expr_id: Ast.ExprId) ?NoiseKind {
    if (!expr_id.valid()) return null;

    const tag = self.exprTag(expr_id);
    const data_lhs = self.exprLhs(expr_id);
    const data_rhs = self.exprRhs(expr_id);
    switch (tag) {
        .func_call => {
            const name = self.exprStr(data_lhs);
            if (std.mem.eql(u8, name, "flicker_noise")) return .flicker;
            if (std.mem.eql(u8, name, "white_noise") or
                std.mem.eql(u8, name, "noise_table") or
                std.mem.eql(u8, name, "noise_table_log"))
            {
                return .thermal;
            }
            for (self.callArgs(data_rhs)) |arg| {
                if (self.detectNoiseKind(arg)) |kind| return kind;
            }
        },
        .system_call => {
            for (self.callArgs(data_rhs)) |arg| {
                if (self.detectNoiseKind(arg)) |kind| return kind;
            }
        },
        .paren => return self.detectNoiseKind(@enumFromInt(data_lhs)),
        .negate, .bit_not, .logic_not, .u_plus => return self.detectNoiseKind(@enumFromInt(data_lhs)),
        .ternary => {
            const cond_id: Ast.ExprId = @enumFromInt(self.extra_data[data_lhs]);
            const then_id: Ast.ExprId = @enumFromInt(self.extra_data[data_lhs + 1]);
            const else_id: Ast.ExprId = @enumFromInt(self.extra_data[data_lhs + 2]);
            if (self.detectNoiseKind(cond_id)) |kind| return kind;
            if (self.detectNoiseKind(then_id)) |kind| return kind;
            if (self.detectNoiseKind(else_id)) |kind| return kind;
        },
        else => {
            if (tag.isBinary()) {
                if (self.detectNoiseKind(@enumFromInt(data_lhs))) |kind| return kind;
                if (self.detectNoiseKind(@enumFromInt(data_rhs))) |kind| return kind;
            }
        },
    }
    return null;
}

fn extractNoiseArgs(self: *Lower, expr_id: Ast.ExprId) [2]?Value {
    if (!expr_id.valid()) return .{ null, null };

    const tag = self.exprTag(expr_id);
    const data_lhs = self.exprLhs(expr_id);
    const data_rhs = self.exprRhs(expr_id);
    switch (tag) {
        .func_call => {
            const name = self.exprStr(data_lhs);
            if (std.mem.eql(u8, name, "white_noise") or
                std.mem.eql(u8, name, "flicker_noise") or
                std.mem.eql(u8, name, "noise_table") or
                std.mem.eql(u8, name, "noise_table_log"))
            {
                var result: [2]?Value = .{ null, null };
                const args = self.callArgs(data_rhs);
                for (args, 0..) |arg, i| {
                    if (i >= 2) break;
                    result[i] = self.lowerExpr(arg) catch null;
                }
                return result;
            }
            for (self.callArgs(data_rhs)) |arg| {
                const r = self.extractNoiseArgs(arg);
                if (r[0] != null) return r;
            }
        },
        .paren => return self.extractNoiseArgs(@enumFromInt(data_lhs)),
        .negate, .bit_not, .logic_not, .u_plus => return self.extractNoiseArgs(@enumFromInt(data_lhs)),
        else => {
            if (tag.isBinary()) {
                const r = self.extractNoiseArgs(@enumFromInt(data_lhs));
                if (r[0] != null) return r;
                return self.extractNoiseArgs(@enumFromInt(data_rhs));
            }
        },
    }
    return .{ null, null };
}

fn splitContribution(self: *Lower, expr_id: Ast.ExprId, resist_place: Place, react_place: Place, is_negated: bool) LowerError!void {
    if (!expr_id.valid()) return;

    const tag = self.exprTag(expr_id);
    const data_lhs = self.exprLhs(expr_id);
    const data_rhs = self.exprRhs(expr_id);
    switch (tag) {
        .add => {
            try self.splitContribution(@enumFromInt(data_lhs), resist_place, react_place, is_negated);
            try self.splitContribution(@enumFromInt(data_rhs), resist_place, react_place, is_negated);
            return;
        },
        .sub => {
            try self.splitContribution(@enumFromInt(data_lhs), resist_place, react_place, is_negated);
            try self.splitContribution(@enumFromInt(data_rhs), resist_place, react_place, !is_negated);
            return;
        },
        .mul => {
            const lhs_id: Ast.ExprId = @enumFromInt(data_lhs);
            const rhs_id: Ast.ExprId = @enumFromInt(data_rhs);
            if (self.isDdt(rhs_id)) |inner| {
                const k = try self.lowerExpr(lhs_id);
                const q = try self.lowerExpr(inner);
                const term = try self.builder.buildBinary(.fmul, k, q);
                try self.accumulate(react_place, term, is_negated);
                return;
            }
            if (self.isDdt(lhs_id)) |inner| {
                const q = try self.lowerExpr(inner);
                const k = try self.lowerExpr(rhs_id);
                const term = try self.builder.buildBinary(.fmul, q, k);
                try self.accumulate(react_place, term, is_negated);
                return;
            }
        },
        .func_call => {
            const name = self.exprStr(data_lhs);
            const args = self.callArgs(data_rhs);
            if (std.mem.eql(u8, name, "ddt") and args.len >= 1) {
                const inner_val = try self.lowerExpr(args[0]);
                try self.accumulate(react_place, inner_val, is_negated);
                return;
            }
            if (std.mem.eql(u8, name, "idt") and args.len >= 1) {
                const val = try self.lowerExpr(expr_id);
                try self.accumulate(resist_place, val, is_negated);
                return;
            }
        },
        .negate => {
            try self.splitContribution(@enumFromInt(data_lhs), resist_place, react_place, !is_negated);
            return;
        },
        .paren => {
            try self.splitContribution(@enumFromInt(data_lhs), resist_place, react_place, is_negated);
            return;
        },
        else => {},
    }

    const val = try self.lowerExpr(expr_id);
    try self.accumulate(resist_place, val, is_negated);
}

fn isDdt(self: *const Lower, expr_id: Ast.ExprId) ?Ast.ExprId {
    if (!expr_id.valid()) return null;

    const tag = self.exprTag(expr_id);
    const data_lhs = self.exprLhs(expr_id);
    const data_rhs = self.exprRhs(expr_id);
    switch (tag) {
        .func_call => {
            const name = self.exprStr(data_lhs);
            const args = self.callArgs(data_rhs);
            if (std.mem.eql(u8, name, "ddt") and args.len >= 1)
                return args[0];
        },
        .paren => return self.isDdt(@enumFromInt(data_lhs)),
        else => {},
    }
    return null;
}

fn accumulate(self: *Lower, place: Place, val: Value, negate: bool) !void {
    const effective = if (negate) try self.builder.buildUnary(.fneg, val) else val;
    const current = try self.readVar(place);
    const result = try self.builder.buildBinary(.fadd, current, effective);
    try self.writeVar(place, result);
}

/// Does this statement subtree contain a loop? Loop-containing conditionals
/// must lower to real SSA blocks: the select-based path snapshots values in
/// the straight-line cache, which loops invalidate wholesale.
fn stmtHasLoop(self: *const Lower, id: Ast.StmtId) bool {
    if (!id.valid()) return false;
    const idx = @intFromEnum(id);
    if (idx < self.loop_cache.len) {
        if (self.loop_cache[idx] != 0) return self.loop_cache[idx] == 2;
    }
    const result = switch (self.getStmt(id)) {
        .while_stmt, .for_stmt => true,
        .block => |b| blk: {
            for (b.stmts) |sid| {
                if (self.stmtHasLoop(sid)) break :blk true;
            }
            break :blk false;
        },
        .if_stmt => |i| self.stmtHasLoop(i.then_branch) or self.stmtHasLoop(i.else_branch),
        .case_stmt => |cs| blk: {
            for (cs.arms) |arm| {
                if (self.stmtHasLoop(arm.body)) break :blk true;
            }
            break :blk false;
        },
        .event_control => |ec| self.stmtHasLoop(ec.body),
        else => false,
    };
    if (idx < self.loop_cache.len) {
        // ponytail: transparent memoization — constCast safe for pure cache
        const cache = @constCast(self.loop_cache.ptr);
        cache[idx] = if (result) 2 else 1;
    }
    return result;
}

fn lowerIf(self: *Lower, cond_id: Ast.ExprId, then_id: Ast.StmtId, else_id: Ast.StmtId) !void {
    if (self.loop_depth > 0) {
        return self.lowerIfWithBlocks(cond_id, then_id, else_id);
    }
    if (self.stmtHasLoop(then_id) or self.stmtHasLoop(else_id)) {
        return self.lowerIfWithBlocks(cond_id, then_id, else_id);
    }

    const cond = try self.lowerExpr(cond_id);
    const Body = struct {
        id: Ast.StmtId,
        pub fn run(b: @This(), l: *Lower) LowerError!void {
            try l.lowerStmt(b.id);
        }
    };
    try self.lowerGuarded(cond, Body{ .id = then_id }, Body{ .id = else_id });
}

/// Straight-line conditional lowering shared by if and case (outside loops):
/// run both bodies with modification tracking, restore between them, merge
/// every modified place with a select on `cond`. Bodies are any type with
/// `run(self, *Lower) LowerError!void`.
fn lowerGuarded(self: *Lower, cond: Value, then_body: anytype, else_body: anytype) LowerError!void {
    const block = self.builder.currentBlock();

    // ── then branch ────────────────────────────────────────────────────
    try self.scope_stack.append(self.allocator, @intCast(self.scope_mods.len));
    self.scope_gen +%= 1;
    try then_body.run(self);
    const then_mark = self.scope_stack.pop().?;
    const then_end: u32 = @intCast(self.scope_mods.len);

    // Capture then-modified places, restore pre-values
    const ModInfo = struct { place: Place, then_val: Value, pre_val: Value };
    var then_info: Buf(ModInfo) = .{};
    defer then_info.deinit(self.allocator);

    for (self.scope_mods.slice()[then_mark..then_end]) |m| {
        const pid = @intFromEnum(m.place);
        const then_val = try self.currentVal(m.place);
        try then_info.append(self.allocator, .{ .place = m.place, .then_val = then_val, .pre_val = m.pre_val });
        if (pid < self.val_arr.len) self.val_arr.slice()[pid] = m.pre_val;
        try self.builder.defVar(m.place, m.pre_val, block);
    }
    self.scope_mods.len = then_mark;

    // ── else branch ────────────────────────────────────────────────────
    // Rebuild scope_seen for this (now-current) scope level before push
    self.rebuildScopeSeen();
    try self.scope_stack.append(self.allocator, @intCast(self.scope_mods.len));
    self.scope_gen +%= 1;
    try else_body.run(self);
    const else_mark = self.scope_stack.pop().?;
    const else_end: u32 = @intCast(self.scope_mods.len);

    // Snapshot else mods before trimming (needed for else-only merge below)
    const else_mods = self.scope_mods.slice()[else_mark..else_end];
    var else_saved: Buf(ScopeMod) = .{};
    defer else_saved.deinit(self.allocator);
    try else_saved.ensureTotalCapacity(self.allocator, else_mods.len);
    for (else_mods) |m| try else_saved.append(self.allocator, m);
    self.scope_mods.len = else_mark;

    // Rebuild scope_seen for parent scope before merge (writeVar uses it)
    self.rebuildScopeSeen();

    // ── merge: places modified in then branch ──────────────────────────
    for (then_info.slice()) |info| {
        const else_val = blk: {
            const v = try self.currentVal(info.place);
            break :blk if (v == .undef) info.pre_val else v;
        };
        if (info.then_val == else_val) {
            try self.writeVar(info.place, info.then_val);
        } else {
            const sel = try self.builder.buildSelect(cond, info.then_val, else_val);
            try self.writeVar(info.place, sel);
        }
    }

    // ── merge: places modified ONLY in else branch ─────────────────────
    // ponytail: linear scan for then-contains; then_info is small per scope
    for (else_saved.slice()) |m| {
        const in_then = for (then_info.slice()) |info| {
            if (info.place == m.place) break true;
        } else false;
        if (in_then) continue;
        const else_val = blk: {
            const v = try self.currentVal(m.place);
            break :blk if (v == .undef) m.pre_val else v;
        };
        if (m.pre_val == else_val) continue;
        const sel = try self.builder.buildSelect(cond, m.pre_val, else_val);
        try self.writeVar(m.place, sel);
    }
}

/// Rebuild scope seen state from the current top scope's modifications.
fn rebuildScopeSeen(self: *Lower) void {
    self.scope_gen +%= 1;
    if (self.scope_stack.len > 0) {
        const parent_mark = self.scope_stack.slice()[self.scope_stack.len - 1];
        for (self.scope_mods.slice()[parent_mark..]) |m| {
            const pid = @intFromEnum(m.place);
            if (pid < self.scope_seen_gens.len) self.scope_seen_gens[pid] = self.scope_gen;
        }
    }
}

fn lowerIfWithBlocks(self: *Lower, cond_id: Ast.ExprId, then_id: Ast.StmtId, else_id: Ast.StmtId) !void {
    const cond = try self.lowerExpr(cond_id);

    const then_block = try self.builder.createBlock();
    const else_block = try self.builder.createBlock();
    const merge_block = try self.builder.createBlock();
    const current = self.builder.currentBlock();

    try self.builder.buildBranch(cond, then_block, else_block);

    self.val_gen +%= 1;
    try self.builder.addPredecessor(then_block, current);
    self.builder.switchToBlock(then_block);
    try self.builder.sealBlock(then_block);
    try self.lowerStmt(then_id);
    try self.builder.buildJump(merge_block);
    const then_exit = self.builder.currentBlock();
    try self.builder.addPredecessor(merge_block, then_exit);

    self.val_gen +%= 1;
    try self.builder.addPredecessor(else_block, current);
    self.builder.switchToBlock(else_block);
    try self.builder.sealBlock(else_block);
    if (else_id.valid()) try self.lowerStmt(else_id);
    try self.builder.buildJump(merge_block);
    const else_exit = self.builder.currentBlock();
    try self.builder.addPredecessor(merge_block, else_exit);

    self.val_gen +%= 1;
    self.builder.switchToBlock(merge_block);
    try self.builder.sealBlock(merge_block);
}

fn lowerWhile(self: *Lower, cond_id: Ast.ExprId, body_id: Ast.StmtId) !void {
    self.loop_depth += 1;
    defer {
        self.loop_depth -= 1;
        if (self.loop_depth == 0) self.val_gen +%= 1;
    }

    const header = try self.builder.createBlock();
    const body_block = try self.builder.createBlock();
    const exit = try self.builder.createBlock();
    const current = self.builder.currentBlock();

    try self.builder.buildJump(header);
    try self.builder.addPredecessor(header, current);

    self.builder.switchToBlock(header);
    const cond = try self.lowerExpr(cond_id);
    try self.builder.buildLoopBranch(cond, body_block, exit);
    try self.builder.addPredecessor(body_block, header);
    try self.builder.addPredecessor(exit, header);

    self.builder.switchToBlock(body_block);
    try self.builder.sealBlock(body_block);
    try self.lowerStmt(body_id);
    try self.builder.buildJump(header);
    try self.builder.addPredecessor(header, self.builder.currentBlock());
    try self.builder.sealBlock(header);

    self.builder.switchToBlock(exit);
    try self.builder.sealBlock(exit);
}

fn lowerFor(self: *Lower, f: *const Ast.ForStmt) !void {
    if (f.init_target.valid()) {
        const init_val = try self.lowerExpr(f.init_value);
        const name = self.resolveIdentName(f.init_target);
        if (name) |n| {
            const place = self.var_map.get(n) orelse blk: {
                const p = try self.allocPlace();
                try self.var_map.put(self.allocator, n, p);
                break :blk p;
            };
            try self.writeVar(place, init_val);
        }
    }

    self.loop_depth += 1;
    defer {
        self.loop_depth -= 1;
        if (self.loop_depth == 0) self.val_gen +%= 1;
    }

    const header = try self.builder.createBlock();
    const body_block = try self.builder.createBlock();
    const incr_block = try self.builder.createBlock();
    const exit = try self.builder.createBlock();
    const current = self.builder.currentBlock();

    try self.builder.buildJump(header);
    try self.builder.addPredecessor(header, current);

    self.builder.switchToBlock(header);
    const cond = try self.lowerExpr(f.cond);
    try self.builder.buildLoopBranch(cond, body_block, exit);
    try self.builder.addPredecessor(body_block, header);
    try self.builder.addPredecessor(exit, header);

    self.builder.switchToBlock(body_block);
    try self.builder.sealBlock(body_block);
    try self.lowerStmt(f.body);
    try self.builder.buildJump(incr_block);
    try self.builder.addPredecessor(incr_block, self.builder.currentBlock());

    self.builder.switchToBlock(incr_block);
    try self.builder.sealBlock(incr_block);
    if (f.incr_target.valid()) {
        const incr_val = try self.lowerExpr(f.incr_value);
        const incr_name = self.resolveIdentName(f.incr_target);
        if (incr_name) |n| {
            if (self.var_map.get(n)) |place| {
                try self.writeVar(place, incr_val);
            }
        }
    }
    try self.builder.buildJump(header);
    try self.builder.addPredecessor(header, incr_block);
    try self.builder.sealBlock(header);

    self.builder.switchToBlock(exit);
    try self.builder.sealBlock(exit);
}

fn lowerCase(self: *Lower, discr_id: Ast.ExprId, arms: []const Ast.CaseArm) !void {
    const discr = try self.lowerExpr(discr_id);
    var has_loop = false;
    for (arms) |arm| has_loop = has_loop or self.stmtHasLoop(arm.body);
    if (self.loop_depth == 0 and !has_loop) {
        var default_arm: Ast.StmtId = .none;
        for (arms) |arm| {
            if (arm.values.len == 0) {
                default_arm = arm.body;
                break;
            }
        }
        return self.lowerCaseChain(discr, arms, default_arm);
    }
    if (self.loop_depth > 0) {
        self.loop_depth += 1;
        defer {
            self.loop_depth -= 1;
            if (self.loop_depth == 0) self.val_gen +%= 1;
        }
        return self.lowerCaseWithBlocks(discr, arms);
    }
    try self.lowerCaseWithBlocks(discr, arms);
}

fn lowerCaseChain(self: *Lower, discr: Value, arms: []const Ast.CaseArm, default_arm: Ast.StmtId) LowerError!void {
    var idx: usize = 0;
    while (idx < arms.len and arms[idx].values.len == 0) idx += 1;
    if (idx == arms.len) return self.lowerStmt(default_arm);

    const arm = arms[idx];
    var cond: Value = .false_;
    for (arm.values) |val_id| {
        const val = try self.lowerExpr(val_id);
        const eq_val = try self.builder.buildBinary(.feq, discr, val);
        if (cond == .false_) {
            cond = eq_val;
        } else {
            const prev_b = try self.builder.buildUnary(.bi_cast, cond);
            const eq_b = try self.builder.buildUnary(.bi_cast, eq_val);
            const or_val = try self.builder.buildBinary(.ior, prev_b, eq_b);
            cond = try self.builder.buildUnary(.ib_cast, or_val);
        }
    }

    const Then = struct {
        id: Ast.StmtId,
        pub fn run(b: @This(), l: *Lower) LowerError!void {
            try l.lowerStmt(b.id);
        }
    };
    const Rest = struct {
        discr: Value,
        arms: []const Ast.CaseArm,
        default_arm: Ast.StmtId,
        pub fn run(b: @This(), l: *Lower) LowerError!void {
            try l.lowerCaseChain(b.discr, b.arms, b.default_arm);
        }
    };
    try self.lowerGuarded(cond, Then{ .id = arm.body }, Rest{
        .discr = discr,
        .arms = arms[idx + 1 ..],
        .default_arm = default_arm,
    });
}

fn lowerCaseWithBlocks(self: *Lower, discr: Value, arms: []const Ast.CaseArm) !void {
    const merge_block = try self.builder.createBlock();

    for (arms) |arm| {
        if (arm.values.len > 0) {
            var cond: Value = .false_;
            for (arm.values) |val_id| {
                const val = try self.lowerExpr(val_id);
                const eq_val = try self.builder.buildBinary(.feq, discr, val);
                if (cond == .false_) {
                    cond = eq_val;
                } else {
                    const prev_b = try self.builder.buildUnary(.bi_cast, cond);
                    const eq_b = try self.builder.buildUnary(.bi_cast, eq_val);
                    const or_val = try self.builder.buildBinary(.ior, prev_b, eq_b);
                    cond = try self.builder.buildUnary(.ib_cast, or_val);
                }
            }

            const then_block = try self.builder.createBlock();
            const else_block = try self.builder.createBlock();
            const current = self.builder.currentBlock();

            try self.builder.buildBranch(cond, then_block, else_block);
            try self.builder.addPredecessor(then_block, current);
            try self.builder.addPredecessor(else_block, current);

            self.val_gen +%= 1;
            self.builder.switchToBlock(then_block);
            try self.builder.sealBlock(then_block);
            try self.lowerStmt(arm.body);
            try self.builder.buildJump(merge_block);
            try self.builder.addPredecessor(merge_block, self.builder.currentBlock());

            self.val_gen +%= 1;
            self.builder.switchToBlock(else_block);
            try self.builder.sealBlock(else_block);
        } else {
            try self.lowerStmt(arm.body);
            try self.builder.buildJump(merge_block);
            try self.builder.addPredecessor(merge_block, self.builder.currentBlock());
        }
    }

    self.val_gen +%= 1;
    self.builder.switchToBlock(merge_block);
    try self.builder.sealBlock(merge_block);
}

fn lowerExpr(self: *Lower, id: Ast.ExprId) LowerError!Value {
    if (!id.valid()) return .undef;

    const tag = self.exprTag(id);
    const data_lhs = self.exprLhs(id);
    const data_rhs = self.exprRhs(id);

    switch (tag) {
        // ── literals ────────────────────────────────────────────────
        .literal_int_small => {
            const val: i64 = @as(i32, @bitCast(data_lhs));
            return switch (val) {
                0 => .zero,
                1 => .one,
                -1 => .neg_one,
                else => try self.builder.mir.addIConst(@intCast(val)),
            };
        },
        .literal_int_large => {
            const val = self.readI64Extra(data_lhs);
            return switch (val) {
                0 => .zero,
                1 => .one,
                -1 => .neg_one,
                else => if (val >= std.math.minInt(i32) and val <= std.math.maxInt(i32))
                    try self.builder.mir.addIConst(@intCast(val))
                else
                    try self.builder.mir.addFConst(@floatFromInt(val)),
            };
        },
        .literal_real => {
            const val = self.readF64Extra(data_lhs);
            return try self.builder.fconst(val);
        },
        .literal_string => {
            const str = self.exprStr(data_lhs);
            const idx = try self.builder.mir.internString(str);
            return try self.builder.mir.addValue(.{ .s_const = idx });
        },
        .literal_inf => return .f_inf,

        // ── references ──────────────────────────────────────────────
        .ident => {
            const name = self.exprStr(data_lhs);
            return self.resolveIdent(name);
        },
        .port_flow => {
            const name = self.exprStr(data_lhs);
            const place = self.var_map.get(name) orelse {
                const p = try self.allocPlace();
                try self.var_map.put(self.allocator, name, p);
                try self.writeVar(p, .undef);
                return .undef;
            };
            return self.readVar(place);
        },

        // ── grouping ────────────────────────────────────────────────
        .paren => return self.lowerExpr(@enumFromInt(data_lhs)),

        // ── unary ops ───────────────────────────────────────────────
        .negate => {
            const val = try self.lowerExpr(@enumFromInt(data_lhs));
            return self.builder.buildUnary(.fneg, val);
        },
        .bit_not => {
            const val = try self.lowerExpr(@enumFromInt(data_lhs));
            return self.builder.buildUnary(.inot, val);
        },
        .logic_not => {
            const val = try self.lowerExpr(@enumFromInt(data_lhs));
            return self.builder.buildUnary(.bnot, val);
        },
        .u_plus => return self.lowerExpr(@enumFromInt(data_lhs)),

        // ── binary ops ──────────────────────────────────────────────
        .logic_and => return self.lowerLogicAnd(@enumFromInt(data_lhs), @enumFromInt(data_rhs)),
        .logic_or => return self.lowerLogicOr(@enumFromInt(data_lhs), @enumFromInt(data_rhs)),

        .add, .sub, .mul, .div, .modulo, .power,
        .eq, .neq, .lt, .gt, .lte, .gte,
        .bit_and, .bit_or, .bit_xor, .bit_nxor,
        .shl, .shr, .ashl, .ashr,
        => {
            const lhs_id: Ast.ExprId = @enumFromInt(data_lhs);
            const rhs_id: Ast.ExprId = @enumFromInt(data_rhs);
            const l = try self.lowerExpr(lhs_id);
            const r = try self.lowerExpr(rhs_id);
            const opc: Opcode = switch (tag) {
                .add => .fadd, .sub => .fsub, .mul => .fmul, .div => .fdiv,
                .modulo => .frem, .power => .pow,
                .eq => .feq, .neq => .fne,
                .lt => .flt, .gt => .fgt, .lte => .fle, .gte => .fge,
                .bit_and => .iand, .bit_or => .ior, .bit_xor => .ixor,
                .bit_nxor => return self.lowerNxor(l, r),
                .shl, .ashl => .ishl,
                .shr, .ashr => .ishr,
                else => unreachable,
            };
            return self.builder.buildBinary(opc, l, r);
        },

        // ── ternary ─────────────────────────────────────────────────
        .ternary => {
            const cond_id: Ast.ExprId = @enumFromInt(self.extra_data[data_lhs]);
            const then_id: Ast.ExprId = @enumFromInt(self.extra_data[data_lhs + 1]);
            const else_id: Ast.ExprId = @enumFromInt(self.extra_data[data_lhs + 2]);
            const cond_val = try self.lowerExpr(cond_id);
            const then_val = try self.lowerExpr(then_id);
            const else_val = try self.lowerExpr(else_id);
            return self.builder.buildSelect(cond_val, then_val, else_val);
        },

        // ── calls ───────────────────────────────────────────────────
        .func_call => {
            const name = self.exprStr(data_lhs);
            const args = self.callArgs(data_rhs);
            return self.lowerFuncCall(name, args);
        },
        .system_call => {
            const name = self.exprStr(data_lhs);
            const args = self.callArgs(data_rhs);
            return self.lowerSystemCall(name, args);
        },
        .nature_access => {
            const nature = self.exprStr(data_lhs);
            const args = self.callArgs(data_rhs);
            return self.lowerNatureAccess(nature, args);
        },

        // ── array ───────────────────────────────────────────────────
        .array => return .undef,
    }
}

fn resolveIdent(self: *Lower, name: []const u8) !Value {
    if (self.var_map.get(name)) |place| return self.readVar(place);
    if (self.node_voltages.get(name)) |place| return self.readVar(place);
    const place = try self.allocPlace();
    try self.var_map.put(self.allocator, name, place);
    try self.writeVar(place, .undef);
    return .undef;
}

/// Resolve an ExprId to an identifier name.
fn resolveIdentName(self: *const Lower, id: Ast.ExprId) ?[]const u8 {
    if (!id.valid()) return null;
    return if (self.exprTag(id) == .ident) self.exprStr(self.exprLhs(id)) else null;
}

fn lowerNxor(self: *Lower, a: Value, b: Value) !Value {
    const xor_val = try self.builder.buildBinary(.ixor, a, b);
    return self.builder.buildUnary(.inot, xor_val);
}

fn lowerLogicAnd(self: *Lower, lhs_id: Ast.ExprId, rhs_id: Ast.ExprId) !Value {
    const l = try self.lowerExpr(lhs_id);
    const l_bool = try self.builder.buildUnary(.fb_cast, l);
    const r = try self.lowerExpr(rhs_id);
    const r_bool = try self.builder.buildUnary(.fb_cast, r);
    return self.builder.buildSelect(l_bool, r_bool, .false_);
}

fn lowerLogicOr(self: *Lower, lhs_id: Ast.ExprId, rhs_id: Ast.ExprId) !Value {
    const l = try self.lowerExpr(lhs_id);
    const l_bool = try self.builder.buildUnary(.fb_cast, l);
    const r = try self.lowerExpr(rhs_id);
    const r_bool = try self.builder.buildUnary(.fb_cast, r);
    return self.builder.buildSelect(l_bool, .true_, r_bool);
}

fn lowerFuncCall(self: *Lower, name: []const u8, args: []const Ast.ExprId) !Value {
    if (args.len == 1) {
        if (getUnaryMathOp(name)) |op| {
            const arg = try self.lowerExpr(args[0]);
            return self.builder.buildUnary(op, arg);
        }
    }
    if (args.len == 2) {
        if (getBinaryMathOp(name)) |op| {
            const a = try self.lowerExpr(args[0]);
            const b = try self.lowerExpr(args[1]);
            return self.builder.buildBinary(op, a, b);
        }
    }

    if (std.mem.eql(u8, name, "ddt") and args.len >= 1) {
        const arg = try self.lowerExpr(args[0]);
        const func_ref = try self.getOrCreateFuncRef("$ddt");
        return self.builder.buildCall(func_ref, &.{arg});
    }
    if (std.mem.eql(u8, name, "idt") and args.len >= 1) {
        return self.emitGenericCall("$idt", args);
    }
    if (std.mem.eql(u8, name, "ddx") and args.len >= 1) {
        return self.emitGenericCall("$ddx", args);
    }
    if (std.mem.eql(u8, name, "abs") and args.len >= 1) {
        const arg = try self.lowerExpr(args[0]);
        return self.lowerAbs(arg);
    }
    if (std.mem.eql(u8, name, "limexp") and args.len >= 1) {
        const arg = try self.lowerExpr(args[0]);
        return self.lowerLimexp(arg);
    }
    if (std.mem.eql(u8, name, "min") and args.len == 2) {
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        return self.lowerMinMax(a, b, false);
    }
    if (std.mem.eql(u8, name, "max") and args.len == 2) {
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        return self.lowerMinMax(a, b, true);
    }

    // Inline user-defined functions — bind args, lower body, return result.
    if (self.user_funcs.get(name)) |fd| {
        return self.inlineUserFunc(fd, args);
    }

    return self.emitGenericCall(name, args);
}

fn lowerSystemCall(self: *Lower, name: []const u8, args: []const Ast.ExprId) !Value {
    if (std.mem.eql(u8, name, "$temperature")) {
        return self.emitGenericCall("$temperature", &.{});
    }
    if (std.mem.eql(u8, name, "$vt")) {
        const temp = if (args.len > 0)
            try self.lowerExpr(args[0])
        else
            try self.emitGenericCall("$temperature", &.{});
        const kb_over_q = try self.builder.fconst(8.6173303e-5);
        return self.builder.buildBinary(.fmul, kb_over_q, temp);
    }
    if (std.mem.eql(u8, name, "$abstime")) {
        return self.emitGenericCall("$abstime", &.{});
    }
    if (std.mem.eql(u8, name, "$limit")) return self.emitGenericCall("$limit", args);
    if (std.mem.eql(u8, name, "$limexp") and args.len >= 1) {
        const arg = try self.lowerExpr(args[0]);
        return self.lowerLimexp(arg);
    }
    if (std.mem.eql(u8, name, "$param_given")) {
        if (args.len >= 1) return self.emitGenericCall("$param_given", args);
        return .zero;
    }
    if (std.mem.eql(u8, name, "$simparam")) return self.emitGenericCall("$simparam", args);
    if (std.mem.eql(u8, name, "$bound_step")) {
        if (args.len >= 1) return self.emitGenericCall("$bound_step", args);
        return .undef;
    }

    if (std.mem.eql(u8, name, "$strobe") or std.mem.eql(u8, name, "$display") or
        std.mem.eql(u8, name, "$write") or std.mem.eql(u8, name, "$monitor") or
        std.mem.eql(u8, name, "$debug") or std.mem.eql(u8, name, "$warning") or
        std.mem.eql(u8, name, "$error") or std.mem.eql(u8, name, "$fatal") or
        std.mem.eql(u8, name, "$info") or std.mem.eql(u8, name, "$finish") or
        std.mem.eql(u8, name, "$stop"))
    {
        _ = try self.emitGenericCall(name, args);
        return .undef;
    }

    if (args.len == 1) {
        const arg = try self.lowerExpr(args[0]);
        const unary_map = std.StaticStringMap(Opcode).initComptime(.{
            .{ "$ln", .ln },      .{ "$log10", .log },  .{ "$sqrt", .sqrt },
            .{ "$exp", .exp },    .{ "$floor", .floor }, .{ "$ceil", .ceil },
            .{ "$sin", .sin },    .{ "$cos", .cos },     .{ "$tan", .tan },
            .{ "$asin", .asin },  .{ "$acos", .acos },   .{ "$atan", .atan },
            .{ "$sinh", .sinh },  .{ "$cosh", .cosh },   .{ "$tanh", .tanh },
            .{ "$asinh", .asinh }, .{ "$acosh", .acosh }, .{ "$atanh", .atanh },
        });
        if (unary_map.get(name)) |op| return self.builder.buildUnary(op, arg);
        if (std.mem.eql(u8, name, "$abs")) return self.lowerAbs(arg);
        if (std.mem.eql(u8, name, "$clog2")) return self.builder.buildUnary(.clog2, arg);
    }
    if (args.len == 2) {
        const a = try self.lowerExpr(args[0]);
        const b = try self.lowerExpr(args[1]);
        const binary_map = std.StaticStringMap(Opcode).initComptime(.{
            .{ "$pow", .pow }, .{ "$hypot", .hypot }, .{ "$atan2", .atan2 },
        });
        if (binary_map.get(name)) |op| return self.builder.buildBinary(op, a, b);
        if (std.mem.eql(u8, name, "$min")) return self.lowerMinMax(a, b, false);
        if (std.mem.eql(u8, name, "$max")) return self.lowerMinMax(a, b, true);
    }

    return self.emitGenericCall(name, args);
}

fn emitGenericCall(self: *Lower, name: []const u8, args: []const Ast.ExprId) !Value {
    // Stack space covers every real call; $display-style calls can exceed it,
    // so spill to the heap rather than truncating arguments.
    var stack_buf: [16]Value = undefined;
    const vals = if (args.len <= stack_buf.len)
        stack_buf[0..args.len]
    else
        try self.allocator.alloc(Value, args.len);
    defer if (args.len > stack_buf.len) self.allocator.free(vals);

    for (args, 0..) |aid, i| vals[i] = try self.lowerExpr(aid);
    const func_ref = try self.getOrCreateFuncRef(name);
    return self.builder.buildCall(func_ref, vals);
}

fn lowerNatureAccess(self: *Lower, nature: []const u8, args: []const Ast.ExprId) !Value {
    if (args.len == 1) {
        if (self.resolveIdentName(args[0])) |nm| {
            if (self.branches.getPtr(nm)) |bi| return self.branchProbe(nature, bi);
        }
    }
    if (std.mem.eql(u8, nature, "V") or std.mem.eql(u8, nature, "Vp")) {
        if (args.len >= 1) {
            const hi = try self.resolveNodeArg(args[0]);
            if (args.len >= 2) {
                const lo = try self.resolveNodeArg(args[1]);
                return self.builder.buildBinary(.fsub, hi, lo);
            }
            return hi;
        }
        return .undef;
    }
    if (std.mem.eql(u8, nature, "I") or std.mem.eql(u8, nature, "Ip")) {
        if (args.len >= 1) return self.resolveNodeArg(args[0]);
        return .undef;
    }
    if (std.mem.eql(u8, nature, "Pwr")) {
        if (args.len >= 2) {
            const v = try self.resolveNodeArg(args[0]);
            const i = try self.resolveNodeArg(args[1]);
            return self.builder.buildBinary(.fmul, v, i);
        }
        return .undef;
    }
    if (args.len >= 1) return self.resolveNodeArg(args[0]);
    return .undef;
}

fn resolveNodeArg(self: *Lower, arg_id: Ast.ExprId) !Value {
    if (!arg_id.valid()) return .undef;
    if (self.resolveIdentName(arg_id)) |name| {
        if (self.node_voltages.get(name)) |place| return self.readVar(place);
        try self.registerNodeVoltage(name);
        return self.readVar(self.node_voltages.get(name).?);
    }
    return self.lowerExpr(arg_id);
}

fn getUnaryMathOp(name: []const u8) ?Opcode {
    return std.StaticStringMap(Opcode).initComptime(.{
        .{ "sqrt", .sqrt },   .{ "exp", .exp },     .{ "ln", .ln },
        .{ "log", .log },     .{ "floor", .floor },  .{ "ceil", .ceil },
        .{ "sin", .sin },     .{ "cos", .cos },      .{ "tan", .tan },
        .{ "asin", .asin },   .{ "acos", .acos },    .{ "atan", .atan },
        .{ "sinh", .sinh },   .{ "cosh", .cosh },    .{ "tanh", .tanh },
        .{ "asinh", .asinh }, .{ "acosh", .acosh },  .{ "atanh", .atanh },
    }).get(name);
}

fn getBinaryMathOp(name: []const u8) ?Opcode {
    return std.StaticStringMap(Opcode).initComptime(.{
        .{ "pow", .pow }, .{ "hypot", .hypot }, .{ "atan2", .atan2 },
    }).get(name);
}

fn lowerAbs(self: *Lower, val: Value) !Value {
    const neg = try self.builder.buildUnary(.fneg, val);
    const cond = try self.builder.buildBinary(.fge, val, .f_zero);
    return self.builder.buildSelect(cond, val, neg);
}

fn lowerLimexp(self: *Lower, arg: Value) !Value {
    const func_ref = try self.getOrCreateFuncRef("$limexp");
    return self.builder.buildCall(func_ref, &.{arg});
}

fn lowerMinMax(self: *Lower, a: Value, b: Value, is_max: bool) !Value {
    const cond = if (is_max)
        try self.builder.buildBinary(.fgt, a, b)
    else
        try self.builder.buildBinary(.flt, a, b);
    return self.builder.buildSelect(cond, a, b);
}

fn inlineUserFunc(self: *Lower, fd: Ast.FuncDecl, call_args: []const Ast.ExprId) !Value {
    for (fd.args, 0..) |arg, i| {
        if (i < call_args.len) {
            const val = try self.lowerExpr(call_args[i]);
            const place = try self.allocPlace();
            try self.var_map.put(self.allocator, arg.name, place);
            try self.writeVar(place, val);
        }
    }

    const ret_place = try self.allocPlace();
    try self.var_map.put(self.allocator, fd.name, ret_place);
    try self.writeVar(ret_place, .f_zero);

    try self.lowerStmt(fd.body);

    return self.readVar(ret_place);
}

fn getOrCreateFuncRef(self: *Lower, name: []const u8) !Mir.FuncRef {
    if (self.builtin_funcs.get(name)) |ref| return ref;
    const ref = try self.builder.mir.addFuncName(name);
    try self.builtin_funcs.put(self.allocator, name, ref);
    return ref;
}
