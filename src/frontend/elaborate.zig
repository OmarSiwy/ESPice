//! Builder support: resolve parameters, expand subcircuits, and select model bins.
//! The input AST is immutable; every transformed value belongs to scratch.
const std = @import("std");
const ir = @import("types.zig");
pub const Error = error{ OutOfMemory, ParseError, ModelBinNotFound, CircuitTooLarge };

pub fn elaborate(arena: std.mem.Allocator, ast: ir.Ast) Error!ir.Netlist {
    if (ast.subcircuits.len > std.math.maxInt(u16)) return error.CircuitTooLarge;
    var subckts: std.StringHashMapUnmanaged(u16) = .empty;
    for (ast.subcircuits, 0..) |sub, i| try subckts.put(arena, sub.name, @intCast(i));

    var env: Env = .empty;
    for (ast.params) |kv| try env.put(arena, kv.key, kv.value);
    const models = try arena.dupe(ir.Model, ast.models);
    for (models) |*model| {
        const kv = try arena.dupe(ir.Kv, model.kv);
        for (kv) |*item| item.value = try substValue(arena, item.value, &.{env}, true);
        model.kv = kv;
    }
    const directives = try arena.dupe(ir.Directive, ast.directives);
    for (directives) |*dir| {
        const args = try arena.dupe(ir.Value, dir.args);
        for (args) |*arg| if (arg.* == .expr) {
            arg.* = try substValue(arena, arg.*, &.{env}, false);
        };
        dir.args = args;
    }

    var flat: std.ArrayList(ir.Device) = .empty;
    try flat.ensureTotalCapacity(arena, countExpanded(ast.devices, &subckts, ast.subcircuits, 0));
    var instance_counter: u32 = 1; // Zero denotes the top level.
    for (ast.devices) |device| {
        const resolved = try substDevice(arena, device, &.{env});
        try expandInto(arena, &flat, resolved, &subckts, ast.subcircuits, 0, 0, 0, &instance_counter, &.{env});
    }
    try resolveModelBins(arena, flat.items, models, directives, ast.dialect);
    if (flat.items.len > std.math.maxInt(u32)) return error.CircuitTooLarge;
    return .{
        .title = ast.title,
        .devices = try ir.DeviceList.fromUnsorted(arena, flat.items),
        .models = models,
        .directives = directives,
        .params = ast.params,
    };
}

const Env = std.StringHashMapUnmanaged(ir.Value);

fn number(kv: []const ir.Kv, key: []const u8) ?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
        .num => |n| n,
        else => null,
    };
    return null;
}

fn resolveModelBins(arena: std.mem.Allocator, devs: []ir.Device, models: []const ir.Model, dirs: []const ir.Directive, dialect: ir.Dialect) Error!void {
    var scale: f64 = 1;
    var wnflag = dialect != .ngspice;
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
    for (devs) |*dev| {
        if (dev.letter() != 'm') continue;
        const scaled = if (scale != 1) try arena.dupe(ir.Kv, dev.kv) else null;
        for (dev.kv, 0..) |kv, i| {
            const power = lengths.get(kv.key) orelse continue;
            if (kv.value != .num) return error.ParseError;
            if (scaled) |values| values[i].value.num *= if (power == 2) scale * scale else scale;
        }
        if (scaled) |values| dev.kv = values;
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
                const positional = try arena.dupe(ir.Value, dev.positional);
                positional[0] = .{ .name = models[bin].name };
                dev.positional = positional;
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

fn countExpanded(devices: []const ir.Device, subckts: *const std.StringHashMapUnmanaged(u16), declarations: []const ir.Subcircuit, depth: u8) usize {
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
        if (subckts.get(sname)) |id| {
            count += countExpanded(declarations[id].devices, subckts, declarations, depth + 1);
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
    subckts: *const std.StringHashMapUnmanaged(u16),
    declarations: []const ir.Subcircuit,
    depth: u8,
    subckt_type_id: u16,
    instance_id: u32,
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
    const id = subckts.get(sname) orelse return error.ParseError;
    const sub = declarations[id];
    if (d.nodes.len != sub.ports.len) return error.ParseError;

    const this_type = id + 1;
    const this_instance = instance_counter.*;
    if (instance_counter.* == std.math.maxInt(u32)) return error.CircuitTooLarge;
    instance_counter.* += 1;

    // Shadow order: instance kv > subckt defaults > global .param.
    var env: Env = .empty;
    for (sub.defaults) |kvp| try env.put(arena, kvp.key, kvp.value);
    for (d.kv) |kvp| try env.put(arena, kvp.key, kvp.value);

    var scopes: [34]Env = undefined;
    @memcpy(scopes[0..genv.len], genv);
    scopes[genv.len] = env;
    const nested = scopes[0 .. genv.len + 1];
    for (sub.devices) |sd| {
        var nd = try substDevice(arena, sd, nested);
        // SPICE names a flattened device OUTER-first. ngspice
        // subckt.c:1159-1173 `translate_inst_name` writes
        // `<letter>.<scname>.<name>` for a non-X card and
        // `<scname>.<name>` for a nested X, with scname = the instance
        // being expanded; each enclosing level prepends in turn, so a
        // V inside x1 inside x2 comes out `v.x2.x1.v1` and the nested
        // X as `x2.x1`. Nodes take the same path without the letter
        // (subckt.c:1135-1155 `translate_node_name`) — mapNode below
        // builds them off this very string. The leading letter is not
        // decoration: `Device.letter()` reads name[0] to dispatch, so
        // an outer-first path without it would type every flattened
        // device as an X card.
        nd.name = if (sd.letter() == 'x')
            try std.mem.concat(arena, u8, &.{ d.name, ".", sd.name })
        else
            try std.mem.concat(arena, u8, &.{ &.{sd.letter()}, ".", d.name, ".", sd.name });
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
        try expandInto(arena, out, nd, subckts, declarations, depth + 1, this_type, this_instance, instance_counter, nested);
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
    for (d.positional) |value| if (needsResolution(value, env)) {
        const pos = try arena.alloc(ir.Value, d.positional.len);
        for (d.positional, pos) |v, *o| o.* = try substValue(arena, v, env, false);
        nd.positional = pos;
        break;
    };
    for (d.kv) |item| if (needsResolution(item.value, env)) {
        const kv = try arena.alloc(ir.Kv, d.kv.len);
        for (d.kv, kv) |kvp, *o| o.* = .{ .key = kvp.key, .value = try substValue(arena, kvp.value, env, false) };
        nd.kv = kv;
        break;
    };
    return nd;
}

fn needsResolution(value: ir.Value, env: []const Env) bool {
    return switch (value) {
        .num => false,
        .name => |name| findScope(env, name) != null,
        .expr => true,
        .group => |g| blk: {
            for (g.args) |arg| if (needsResolution(arg, env)) break :blk true;
            break :blk false;
        },
    };
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
