//! netlist.zig — netlist → Builder wiring policy: device resolution by card
//! letter / model kind, source waveforms, B-source expression extraction,
//! Verilog-A instance binding, kv/positional parsing.

const std = @import("std");
const analysis = @import("analysis");
const devices = @import("devices");
const types = @import("frontend/types.zig");
const va_devices = @import("va_devices");
const vaload = @import("vaload.zig");

const Builder = @import("builder.zig").Builder;
const GROUND = analysis.GROUND;

// ---------------------------------------------------------------------------
// Verilog-A / Verilog devices — loaded at runtime via `.hdl` cards (vaload).
// The va_devices module is a permanently-empty stub kept so the comptime
// dispatch below stays valid; its decl loops compile to nothing.
// ---------------------------------------------------------------------------

/// First positional token names a baked va_devices decl?
fn isVaDevice(dev: types.Device) bool {
    if (dev.positional.len == 0) return false;
    const model_name = switch (dev.positional[0]) {
        .name => |nm| nm,
        else => return false,
    };
    inline for (@typeInfo(va_devices).@"struct".decls) |decl| {
        if (std.mem.eql(u8, model_name, decl.name)) return true;
    }
    return false;
}

/// First positional token names a runtime-loaded (.hdl card) device?
/// Baked decls win when both exist.
fn isDynDevice(dev: types.Device) bool {
    if (vaload.isEmpty() or dev.positional.len == 0) return false;
    const model_name = switch (dev.positional[0]) {
        .name => |nm| nm,
        else => return false,
    };
    return !isBakedVaName(model_name) and vaload.get(model_name) != null;
}

fn isBakedVaName(name: []const u8) bool {
    inline for (@typeInfo(va_devices).@"struct".decls) |decl| {
        if (std.mem.eql(u8, name, decl.name)) return true;
    }
    return false;
}

/// Runtime (dlopen'd) VA/V devices — same card shape as baked ones
/// (`<name> node... <model>`), bound through the dyn vtable instead of a
/// comptime decl. Param blobs live on the arena until proto_add copies them.
pub fn addDynDevices(b: *Builder, arena: std.mem.Allocator, nl: types.Netlist) !void {
    if (vaload.isEmpty()) return;
    const dl = nl.devices;
    for (0..dl.len()) |di| {
        const pos = dl.positional[di];
        if (pos.len == 0) continue;
        const model_name = switch (pos[0]) {
            .name => |nm| nm,
            else => continue,
        };
        if (isBakedVaName(model_name)) continue;
        const vt = vaload.get(model_name) orelse continue;

        const mblob = try arena.alignedAlloc(u8, .@"16", vt.model_size);
        vt.init_model(mblob.ptr);
        if (findModel(nl.models, model_name)) |m| applyKvDyn(vt.set_model_param, mblob.ptr, m.kv);
        const iblob = try arena.alignedAlloc(u8, .@"16", vt.instance_size);
        vt.init_instance(iblob.ptr);
        applyKvDyn(vt.set_instance_param, iblob.ptr, dl.kv[di]);

        // Ports from the card, internal unknowns allocated here (node policy
        // stays app-side); collapse folds zero-parasitic internals onto their
        // port exactly like Builder.addDevice does for comptime devices.
        const nodes = try arena.alloc(u32, vt.n_u);
        const dev_nodes = dl.nodes[di];
        for (0..vt.num_ports) |p|
            nodes[p] = if (p < dev_nodes.len) try b.internNode(dev_nodes[p]) else GROUND;
        if (vt.n_u > vt.num_ports) {
            const col = try arena.alloc(i32, vt.n_u);
            @memset(col, -1);
            if (vt.collapse) |cf| cf(mblob.ptr, iblob.ptr, col.ptr);
            for (vt.num_ports..vt.n_u) |u|
                nodes[u] = if (col[u] >= 0) nodes[@intCast(col[u])] else b.addNode();
        }

        const proto = try b.dynProto(vt);
        try vt.proto_add(proto.ctx, b.gpa, mblob.ptr, iblob.ptr, nodes.ptr);
    }
}

fn applyKvDyn(set: *const fn ([*]u8, []const u8, f64) bool, dest: [*]u8, kv: []const types.Kv) void {
    for (kv) |item| {
        if (valueNumber(item.value)) |num| _ = set(dest, item.key, num);
    }
}

pub fn addVaDevices(b: *Builder, arena: std.mem.Allocator, nl: types.Netlist) !void {
    _ = arena;
    const dl = nl.devices;
    inline for (@typeInfo(va_devices).@"struct".decls) |decl| {
        const D = @field(va_devices, decl.name);
        const model_kv: []const types.Kv = if (findModel(nl.models, decl.name)) |m| m.kv else &.{};
        for (0..dl.len()) |di| {
            const pos = dl.positional[di];
            if (pos.len == 0) continue;
            const model_name = switch (pos[0]) {
                .name => |nm| nm,
                else => continue,
            };
            if (!std.mem.eql(u8, model_name, decl.name)) continue;

            var model: D.Model = .{};
            try applyKv(&model, model_kv);
            var instance: D.Instance = .{};
            try applyKv(&instance, dl.kv[di]);

            // Card shape: `<name> node... <model>` — parser puts the node
            // words in nodes[] and the trailing model name in positional[0].
            const dev_nodes = dl.nodes[di];
            var ports: [D.num_ports]u32 = undefined;
            inline for (0..D.num_ports) |p| {
                ports[p] = if (p < dev_nodes.len) try b.internNode(dev_nodes[p]) else GROUND;
            }
            try b.addDevice(D, model, instance, ports);
        }
    }
}

// ---------------------------------------------------------------------------
// NetBuilder — netlist → Builder wiring (no ArrayList, bucket-sized arrays)
// ---------------------------------------------------------------------------

fn isValueForm(comptime D: type) bool {
    return @hasDecl(D, "eval");
}

pub const NetBuilder = struct {
    arena: std.mem.Allocator,
    b: *Builder,
    nl: types.Netlist,

    // Pre-allocated to bucket('v').size()
    v_names: [][]const u8,
    v_ports: []u32,
    v_branches: []u32,
    n_v: u32,

    // Pre-allocated to bucket('i').size()
    i_names: [][]const u8,
    n_i: u32,

    // Pre-allocated to bucket('l').size()
    l_names: [][]const u8,
    l_branches: []u32,
    l_values: []f64, // inductance, for K-element M = k*sqrt(L1*L2)
    n_l: u32,

    // Pre-allocated to sum of f/h/w/k bucket sizes
    deferred: []Deferred,
    n_deferred: u32,

    source_node: u32,
    source_branch: u32,
    have_source: bool,

    const Deferred = struct { dev: types.Device, letter: u8 };

    pub fn init(arena: std.mem.Allocator, b: *Builder, nl: types.Netlist) !NetBuilder {
        const dl = nl.devices;
        const nv = dl.bucket('v').size();
        const ni = dl.bucket('i').size();
        const nl_ = dl.bucket('l').size();
        const n_def = dl.bucket('f').size() + dl.bucket('h').size() +
            dl.bucket('w').size() + dl.bucket('k').size();

        return .{
            .arena = arena,
            .b = b,
            .nl = nl,
            .v_names = try arena.alloc([]const u8, nv),
            .v_ports = try arena.alloc(u32, nv),
            .v_branches = try arena.alloc(u32, nv),
            .n_v = 0,
            .i_names = try arena.alloc([]const u8, ni),
            .n_i = 0,
            .l_names = try arena.alloc([]const u8, nl_),
            .l_branches = try arena.alloc(u32, nl_),
            .l_values = try arena.alloc(f64, nl_),
            .n_l = 0,
            .deferred = try arena.alloc(Deferred, n_def),
            .n_deferred = 0,
            .source_node = GROUND,
            .source_branch = GROUND,
            .have_source = false,
        };
    }

    /// ngspice TRANinit semantics: PULSE TR/TF default to TSTEP, PW/PER to
    /// TSTOP — resolvable only once the .tran directive is known. Patches the
    /// -1 sentinels left by the Model/Instance defaults.
    fn resolvePulseDefaults(self: *const NetBuilder, target: anytype) void {
        var tstep: f64 = 1e-9;
        var tstop: f64 = 1e30;
        for (self.nl.directives) |dir| {
            if (!std.ascii.eqlIgnoreCase(dir.kind, "tran")) continue;
            const a0 = directiveNumber(dir, 0);
            const a1 = directiveNumber(dir, 1);
            if (a1 orelse a0) |ts| tstop = ts;
            tstep = if (a1 != null) a0.? else tstop / 100.0;
            break;
        }
        if (target.pulse_tr < 0) target.pulse_tr = tstep;
        if (target.pulse_tf < 0) target.pulse_tf = tstep;
        if (target.pulse_pw < 0) target.pulse_pw = tstop;
        if (target.pulse_per < 0) target.pulse_per = tstop;
    }

    pub fn build(self: *NetBuilder) !void {
        const dl = self.nl.devices;
        try self.addBucket(dl.bucket('v'));
        try self.addBucket(dl.bucket('l'));
        try self.addBucket(dl.bucket('i'));
        try self.addBucket(dl.bucket('f'));
        try self.addBucket(dl.bucket('h'));
        try self.addBucket(dl.bucket('w'));
        try self.addBucket(dl.bucket('k'));
        inline for ("abcdefghijklmnopqrstuvwxyz") |c| {
            if (comptime c != 'f' and c != 'h' and c != 'i' and c != 'k' and c != 'l' and c != 'v' and c != 'w')
                try self.addBucket(dl.bucket(c));
        }
        try self.resolveDeferred();
    }

    fn addBucket(self: *NetBuilder, bkt: types.DeviceList.Bucket) !void {
        for (0..bkt.size()) |i| try self.addDevice(bkt.get(i));
    }

    fn addDevice(self: *NetBuilder, dev: types.Device) !void {
        // Baked or runtime-loaded Verilog-A/Verilog device instance: handled
        // by addVaDevices/addDynDevices after NetBuilder runs, regardless of
        // card letter.
        if (isVaDevice(dev) or isDynDevice(dev)) return;
        const letter = dev.letter();
        if (devices.letter_map.get(&.{letter}) == null) {
            if (inferDeviceFromModel(dev, self.nl.models) == null)
                return error.UnsupportedDevice;
        }

        switch (letter) {
            'r' => _ = try self.addPassive(devices.resistor, dev, "resist", "r"),
            'c' => _ = try self.addPassive(devices.capacitor, dev, "cap", "c"),
            'l' => {
                const br = try self.addPassive(devices.inductor, dev, "inductance", "l");
                self.l_names[self.n_l] = dev.name;
                self.l_branches[self.n_l] = br;
                self.l_values[self.n_l] = positionalNumber(dev, 0) orelse
                    kvNumber(dev.kv, "inductance") orelse kvNumber(dev.kv, "l") orelse 0;
                self.n_l += 1;
            },
            'v' => {
                if (comptime !isValueForm(devices.vsource)) return error.UnsupportedDevice;
                var model: devices.vsource.Model = .{};
                model.dc = @floatCast(sourceDc(dev));
                applySourceWaveform(&model, dev);
                try applyKv(&model, dev.kv);
                self.resolvePulseDefaults(&model);
                const nodes = try deviceNodes(self.b, devices.vsource, dev);
                const br = self.b.n;
                try self.b.addDevice(devices.vsource, model, .{}, nodes);
                self.v_names[self.n_v] = dev.name;
                self.v_ports[self.n_v] = nodes[0];
                self.v_branches[self.n_v] = br;
                self.n_v += 1;
                if (!self.have_source) {
                    self.have_source = true;
                    self.source_node = nodes[0];
                    self.source_branch = br;
                }
            },
            'i' => {
                if (comptime !isValueForm(devices.isource)) return error.UnsupportedDevice;
                var instance: devices.isource.Instance = .{};
                instance.dc = @floatCast(sourceDc(dev));
                applySourceWaveform(&instance, dev);
                try applyKv(&instance, dev.kv);
                self.resolvePulseDefaults(&instance);
                try self.b.addDevice(devices.isource, .{}, instance, try deviceNodes(self.b, devices.isource, dev));
                self.i_names[self.n_i] = dev.name;
                self.n_i += 1;
            },
            'f', 'h', 'w', 'k' => {
                self.deferred[self.n_deferred] = .{ .dev = dev, .letter = letter };
                self.n_deferred += 1;
            },
            'b' => try addBsource(self.b, dev, self.nl.models),
            'p' => try self.addCpl(dev),
            else => try self.addByLetter(letter, dev),
        }
    }

    fn addPassive(
        self: *NetBuilder,
        comptime D: type,
        dev: types.Device,
        comptime instance_field: []const u8,
        comptime short_field: []const u8,
    ) !u32 {
        if (comptime !isValueForm(D)) return error.UnsupportedDevice;
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        const value = positionalNumber(dev, 0) orelse kvNumber(dev.kv, instance_field) orelse kvNumber(dev.kv, short_field) orelse 0;
        @field(instance, instance_field) = castField(@TypeOf(@field(instance, instance_field)), value);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        const nodes = try deviceNodes(self.b, D, dev);
        const br = self.b.n;
        try self.b.addDevice(D, model, instance, nodes);
        return br;
    }

    fn addByLetter(self: *NetBuilder, letter: u8, dev: types.Device) !void {
        switch (resolveDeviceId(letter, dev, self.nl.models)) {
            inline else => |comptime_id| {
                const D = devices.DeviceId.Type(comptime_id);
                try addSingleDevice(self.b, D, dev, self.nl.models);
            },
        }
    }

    fn resolveDeferred(self: *NetBuilder) !void {
        for (self.deferred[0..self.n_deferred]) |def| {
            switch (def.letter) {
                'f' => try self.addBranchRef(devices.cccs, def.dev, 1.0),
                'h' => try self.addBranchRef(devices.ccvs, def.dev, 0.0),
                'w' => try self.addBranchRef(devices.cswitch, def.dev, null),
                'k' => try self.addKinduc(def.dev),
                else => unreachable,
            }
        }
    }

    // ponytail: linear scan over v_names/l_names — O(n_v) per lookup,
    // fine for typical SPICE circuits (< 100 sources). HashMap if profiled.
    fn findVBranch(self: *const NetBuilder, name: []const u8) ?u32 {
        for (self.v_names[0..self.n_v], self.v_branches[0..self.n_v]) |n, br| {
            if (std.mem.eql(u8, n, name)) return br;
        }
        return null;
    }

    /// CPL coupled lines: `P a1 a2 0 b1 b2 0 model` with vector model params
    /// `R=r11 r12 r22` — the parser stores the first number under the key and
    /// the rest ""-keyed. Two-conductor symmetric: self = [0], mutual = [1].
    fn addCpl(self: *NetBuilder, dev: types.Device) !void {
        const D = devices.coupled_tlines;
        if (comptime !isValueForm(D)) return error.UnsupportedDevice;
        var model: D.Model = .{};
        if (modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| applyCplKv(&model, m.kv);
        }
        applyCplKv(&model, dev.kv);
        try self.b.addDevice(D, model, .{}, try deviceNodes(self.b, D, dev));
    }

    fn findLIndex(self: *const NetBuilder, name: []const u8) ?usize {
        for (self.l_names[0..self.n_l], 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }

    fn addBranchRef(self: *NetBuilder, comptime D: type, dev: types.Device, comptime default_gain: ?f64) !void {
        if (comptime !isValueForm(D)) return error.UnsupportedDevice;
        const ctrl_name = positionalName(dev, 0) orelse return error.MissingControlSource;
        const ctrl_br = self.findVBranch(ctrl_name) orelse return error.UnknownControlSource;

        var model: D.Model = .{};
        // W card: `W n+ n- Vctrl model` — model is positional[1] (positional[0]
        // is the control source). F/H put a number there, so the orelse falls
        // back to the plain model-name slot.
        if (positionalName(dev, 1) orelse modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        var instance: D.Instance = .{};
        if (comptime default_gain) |dflt|
            instance.gain = castField(@TypeOf(instance.gain), positionalNumber(dev, 1) orelse kvNumber(dev.kv, "gain") orelse dflt);
        try applyKv(&instance, dev.kv);

        const nodes = [3]u32{
            if (dev.nodes.len > 0) try self.b.internNode(dev.nodes[0]) else GROUND,
            if (dev.nodes.len > 1) try self.b.internNode(dev.nodes[1]) else GROUND,
            ctrl_br,
        };
        try self.b.addDevice(D, model, instance, nodes);
    }

    fn addKinduc(self: *NetBuilder, dev: types.Device) !void {
        if (comptime !isValueForm(devices.kinduc)) return error.UnsupportedDevice;
        const l1_name = positionalName(dev, 0) orelse return error.KinducMissingInductor;
        const l2_name = positionalName(dev, 1) orelse return error.KinducMissingInductor;
        const li1 = self.findLIndex(l1_name) orelse return error.KinducUnknownInductor;
        const li2 = self.findLIndex(l2_name) orelse return error.KinducUnknownInductor;
        const ibr1 = self.l_branches[li1];
        const ibr2 = self.l_branches[li2];
        var model: devices.kinduc.Model = .{};
        if (positionalNumber(dev, 2)) |k| model.k = castField(f32, k);
        if (modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        try applyKv(&model, dev.kv);
        // K card carries the coupling coefficient k; the device stamps mutual
        // inductance M = k*sqrt(L1*L2) (ngspice INDsetup).
        model.k = castField(f32, @as(f64, model.k) *
            @sqrt(self.l_values[li1] * self.l_values[li2]));
        try self.b.addDevice(devices.kinduc, model, .{}, [2]u32{ ibr1, ibr2 });
    }
};

// ---------------------------------------------------------------------------
// Subcircuit BBD tagging
// ---------------------------------------------------------------------------

pub fn tagSubcircuitNodes(b: *Builder, dl: types.DeviceList) !void {
    for (0..dl.len()) |i| {
        const dev = dl.get(i);
        if (dev.subckt_instance == 0) continue;
        for (dev.nodes) |node_name| {
            if (b.node_names.get(node_name)) |node_id|
                try b.tagNodeInstance(node_id, dev.subckt_type, dev.subckt_instance);
        }
    }
}

// ---------------------------------------------------------------------------
// Device resolution
// ---------------------------------------------------------------------------

fn resolveDeviceId(letter: u8, dev: types.Device, spice_models: []const types.Model) devices.DeviceId {
    const level = modelLevel(dev, spice_models);
    return switch (letter) {
        'm' => devices.mosfetDeviceId(level),
        'q' => devices.bjtDeviceId(level),
        'd' => devices.diodeDeviceId(level),
        'j' => devices.jfetDeviceId(level),
        else => devices.letter_map.get(&.{letter}) orelse
            inferDeviceFromModel(dev, spice_models) orelse .resistor,
    };
}

fn inferDeviceFromModel(dev: types.Device, spice_models: []const types.Model) ?devices.DeviceId {
    const name = modelName(dev) orelse return null;
    const m = findModel(spice_models, name) orelse return null;
    const level = kvNumber(m.kv, "level");
    const l: u16 = if (level) |lv| @intFromFloat(lv) else 1;
    if (eqlAny(m.kind, &.{ "nmos", "pmos" }))
        return devices.mosfetDeviceId(l);
    if (eqlAny(m.kind, &.{ "npn", "pnp" }))
        return devices.bjtDeviceId(l);
    if (std.ascii.eqlIgnoreCase(m.kind, "d"))
        return devices.diodeDeviceId(l);
    if (eqlAny(m.kind, &.{ "njf", "pjf" }))
        return devices.jfetDeviceId(l);
    return null;
}

fn eqlAny(a: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (std.ascii.eqlIgnoreCase(a, c)) return true;
    return false;
}

fn addSingleDevice(b: *Builder, comptime D: type, dev: types.Device, spice_models: []const types.Model) !void {
    if (comptime !isValueForm(D)) return error.UnsupportedDevice;
    var model: D.Model = .{};
    var instance: D.Instance = .{};
    if (modelName(dev)) |name| {
        if (findModel(spice_models, name)) |m| {
            try applyKv(&model, m.kv);
            // TXL (y-card) model cards spell the line length `length=`;
            // the lossy_tline field is `len`.
            if (comptime D == devices.lossy_tline) {
                if (kvNumber(m.kv, "length")) |length| model.len = @floatCast(length);
            }
            // Polarity comes from the model KIND (pmos/pnp/pjf/pmf), not a
            // model card parameter — applyKv never sees it. Without this,
            // every P-type device runs with N-type polarity.
            if (comptime @hasField(D.Model, "type_")) {
                if (eqlAny(m.kind, &.{ "pmos", "pnp", "pjf", "pmf" }))
                    model.type_ = -1;
            }
        }
    }
    if (comptime @hasField(D.Instance, "gain"))
        instance.gain = castField(@TypeOf(instance.gain), positionalNumber(dev, 0) orelse 0);
    try applyKv(&instance, dev.kv);
    try b.addDevice(D, model, instance, try deviceNodes(b, D, dev));
}

// ---------------------------------------------------------------------------
// B-source expression extraction
// ---------------------------------------------------------------------------

fn addBsource(b: *Builder, dev: types.Device, spice_models: []const types.Model) !void {
    if (comptime !isValueForm(devices.bsource)) return error.UnsupportedDevice;
    var model: devices.bsource.Model = .{};
    var instance: devices.bsource.Instance = .{};
    if (modelName(dev)) |name| {
        if (findModel(spice_models, name)) |m| try applyKv(&model, m.kv);
    }
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);

    var ctrl_node_name: ?[]const u8 = null;
    for (dev.kv) |item| switch (item.value) {
        .expr => |expr| {
            // Key selects output mode: i={...} = current source, v={...} = voltage source.
            if (item.key.len > 0 and item.key[0] == 'i') model.imode = 1;
            ctrl_node_name = extractSingleVoltageProbe(expr);
            extractPolyCoeffs(expr, &model);
        },
        else => {},
    };

    const nodes = [4]u32{
        if (dev.nodes.len > 0) try b.internNode(dev.nodes[0]) else GROUND,
        if (dev.nodes.len > 1) try b.internNode(dev.nodes[1]) else GROUND,
        if (ctrl_node_name) |cn| try b.internNode(cn) else GROUND,
        GROUND,
    };
    try b.addDevice(devices.bsource, model, instance, nodes);
}

fn extractSingleVoltageProbe(expr: *const types.Expr) ?[]const u8 {
    switch (expr.*) {
        .call => |c| {
            if (std.mem.eql(u8, c.name, "v") and c.args.len >= 1)
                return switch (c.args[0].*) {
                    .ident => |id| id,
                    else => null,
                };
            for (c.args) |arg| if (extractSingleVoltageProbe(arg)) |name| return name;
            return null;
        },
        .binop => |b| return extractSingleVoltageProbe(b.a) orelse extractSingleVoltageProbe(b.b),
        .unop => |u| return extractSingleVoltageProbe(u.a),
        .num, .ident => return null,
    }
}

fn extractPolyCoeffs(expr: *const types.Expr, model: *devices.bsource.Model) void {
    var c: [3]f64 = .{ 0, 0, 0 };
    if (collectTerms(expr, 1.0, &c)) {
        model.c0 = @floatCast(c[0]);
        model.c1 = @floatCast(c[1]);
        model.c2 = @floatCast(c[2]);
    }
}

fn collectTerms(expr: *const types.Expr, scale: f64, c: *[3]f64) bool {
    switch (expr.*) {
        .num => |n| {
            c[0] += scale * n;
            return true;
        },
        .call => |call| {
            if (std.mem.eql(u8, call.name, "v") and call.args.len >= 1) {
                c[1] += scale;
                return true;
            }
            return false;
        },
        .binop => |b| switch (b.op) {
            '+' => return collectTerms(b.a, scale, c) and collectTerms(b.b, scale, c),
            '-' => return collectTerms(b.a, scale, c) and collectTerms(b.b, -scale, c),
            '*' => {
                const da = vDegree(b.a) orelse return false;
                const db = vDegree(b.b) orelse return false;
                if (da + db > 2) return false;
                c[da + db] += scale * numericCoeff(b.a) * numericCoeff(b.b);
                return true;
            },
            else => return false,
        },
        .unop => |u| switch (u.op) {
            '-' => return collectTerms(u.a, -scale, c),
            '+' => return collectTerms(u.a, scale, c),
            else => return false,
        },
        .ident => return false,
    }
}

fn vDegree(expr: *const types.Expr) ?u8 {
    switch (expr.*) {
        .num => return 0,
        .call => |c| return if (std.mem.eql(u8, c.name, "v")) 1 else null,
        .binop => |b| {
            if (b.op != '*') return null;
            const da = vDegree(b.a) orelse return null;
            const db = vDegree(b.b) orelse return null;
            return da + db;
        },
        .unop => |u| return if (u.op == '-' or u.op == '+') vDegree(u.a) else null,
        .ident => return null,
    }
}

fn numericCoeff(expr: *const types.Expr) f64 {
    switch (expr.*) {
        .num => |n| return n,
        .call => return 1.0,
        .binop => |b| return if (b.op == '*') numericCoeff(b.a) * numericCoeff(b.b) else 1.0,
        .unop => |u| return if (u.op == '-') -numericCoeff(u.a) else numericCoeff(u.a),
        .ident => return 1.0,
    }
}

// ---------------------------------------------------------------------------
// Waveform tables
// ---------------------------------------------------------------------------

const Wave = enum(u8) { pulse = 1, sin = 2, exp = 3, pwl = 4, sffm = 5, am = 6 };

const wave_map = std.StaticStringMap(Wave).initComptime(.{
    .{ "pulse", .pulse }, .{ "sin", .sin },   .{ "exp", .exp },
    .{ "pwl", .pwl },     .{ "sffm", .sffm }, .{ "am", .am },
});

fn applySourceWaveform(target: anytype, dev: types.Device) void {
    const T = @TypeOf(target.*);
    for (dev.positional) |pos| {
        const group = switch (pos) {
            .group => |g| g,
            else => continue,
        };
        var buf: [8]u8 = undefined;
        if (group.name.len > buf.len) continue;
        const kind = wave_map.get(std.ascii.lowerString(&buf, group.name)) orelse continue;
        target.waveform = @intFromEnum(kind);
        switch (kind) {
            .pwl => if (comptime @hasField(T, "pwl_times")) {
                var k: usize = 0;
                var i: usize = 0;
                while (i + 1 < group.args.len and k < target.pwl_times.len) : ({
                    i += 2;
                    k += 1;
                }) {
                    if (valueNumber(group.args[i])) |t| target.pwl_times[k] = @floatCast(t);
                    if (valueNumber(group.args[i + 1])) |v| target.pwl_values[k] = @floatCast(v);
                }
                target.pwl_len = @intCast(k);
            },
            inline else => |cw| applyGroupArgs(T, target, group.args, comptime fieldPairs(cw)),
        }
    }
}

fn applyGroupArgs(comptime T: type, target: anytype, args: []const types.Value, comptime field_pairs: []const []const u8) void {
    comptime var i: usize = 0;
    inline while (i < field_pairs.len) : (i += 2) {
        const arg_idx = i / 2;
        if (arg_idx < args.len) {
            if (valueNumber(args[arg_idx])) |v| {
                if (comptime @hasField(T, field_pairs[i])) @field(target.*, field_pairs[i]) = @floatCast(v) else if (comptime @hasField(T, field_pairs[i + 1])) @field(target.*, field_pairs[i + 1]) = @floatCast(v);
            }
        }
    }
}

// ponytail: fieldPairs lives on Wave — same table, moved inline
fn fieldPairs(comptime w: Wave) []const []const u8 {
    return switch (w) {
        .pulse => &.{ "pulse_v1", "pulse_i1", "pulse_v2", "pulse_i2", "pulse_td", "pulse_td", "pulse_tr", "pulse_tr", "pulse_tf", "pulse_tf", "pulse_pw", "pulse_pw", "pulse_per", "pulse_per", "pulse_phase", "pulse_phase" },
        .sin => &.{ "sin_vo", "sin_ioff", "sin_va", "sin_iamp", "sin_freq", "sin_freq", "sin_td", "sin_td", "sin_theta", "sin_theta", "sin_phase", "sin_phase" },
        .exp => &.{ "exp_v1", "exp_i1", "exp_v2", "exp_i2", "exp_td1", "exp_td1", "exp_tau1", "exp_tau1", "exp_td2", "exp_td2", "exp_tau2", "exp_tau2" },
        .pwl => &.{},
        .sffm => &.{ "sffm_vo", "sffm_vo", "sffm_va", "sffm_va", "sffm_fc", "sffm_fc", "sffm_mdi", "sffm_mdi", "sffm_fs", "sffm_fs", "sffm_phasec", "sffm_phasec", "sffm_phases", "sffm_phases" },
        .am => &.{ "am_va", "am_va", "am_vo", "am_vo", "am_mf", "am_mf", "am_fc", "am_fc", "am_td", "am_td", "am_phasec", "am_phasec", "am_phases", "am_phases" },
    };
}

// ---------------------------------------------------------------------------
// Kv / positional utilities
// ---------------------------------------------------------------------------

fn deviceNodes(b: *Builder, comptime D: type, dev: types.Device) ![D.num_ports]u32 {
    var out: [D.num_ports]u32 = undefined;
    inline for (0..D.num_ports) |idx| {
        out[idx] = if (idx < dev.nodes.len) try b.internNode(dev.nodes[idx]) else GROUND;
    }
    return out;
}

fn modelLevel(dev: types.Device, spice_models: []const types.Model) u16 {
    if (modelName(dev)) |name| {
        if (findModel(spice_models, name)) |m| {
            if (kvNumber(m.kv, "level")) |l| return @intFromFloat(l);
        }
    }
    return 1;
}

pub fn findNameIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, target)) return i;
    return null;
}


fn positionalNumber(dev: types.Device, index: usize) ?f64 {
    if (index >= dev.positional.len) return null;
    return valueNumber(dev.positional[index]);
}

fn positionalName(dev: types.Device, index: usize) ?[]const u8 {
    if (index >= dev.positional.len) return null;
    return switch (dev.positional[index]) {
        .name => |n| n,
        else => null,
    };
}

pub fn directiveName(dir: types.Directive, index: usize) ?[]const u8 {
    if (index >= dir.args.len) return null;
    return switch (dir.args[index]) {
        .name => |n| n,
        else => null,
    };
}

pub fn directiveNumber(dir: types.Directive, index: usize) ?f64 {
    if (index >= dir.args.len) return null;
    return valueNumber(dir.args[index]);
}

pub fn directiveNodeName(dir: types.Directive, index: usize) ?[]const u8 {
    if (index >= dir.args.len) return null;
    return switch (dir.args[index]) {
        .name => |n| n,
        .group => |g| if (std.mem.eql(u8, g.name, "v") and g.args.len > 0)
            switch (g.args[0]) {
                .name => |n| n,
                else => null,
            }
        else
            null,
        else => null,
    };
}

fn kvNumber(kv: []const types.Kv, key: []const u8) ?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return valueNumber(item.value);
    return null;
}

fn sourceDc(dev: types.Device) f64 {
    if (kvNumber(dev.kv, "dc")) |dc| return dc;
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .num => |n| return n,
        .group => |group| {
            if (std.mem.eql(u8, group.name, "dc") and group.args.len > 0)
                return valueNumber(group.args[0]) orelse 0;
        },
        .name => |name| {
            if (std.mem.eql(u8, name, "dc"))
                if (positionalNumber(dev, idx + 1)) |dc| return dc;
        },
        else => {},
    };
    return 0;
}

fn modelName(dev: types.Device) ?[]const u8 {
    if (dev.positional.len == 0) return null;
    return switch (dev.positional[0]) {
        .name => |name| name,
        else => null,
    };
}

fn findModel(spice_models: []const types.Model, name: []const u8) ?types.Model {
    for (spice_models) |model| if (std.mem.eql(u8, model.name, name)) return model;
    return null;
}

fn applyCplKv(model: *devices.coupled_tlines.Model, kv: []const types.Kv) void {
    var i: usize = 0;
    while (i < kv.len) : (i += 1) {
        const key = kv[i].key;
        const v0 = valueNumber(kv[i].value) orelse continue;
        // Gather the ""-keyed tail: [self, mutual, self2, ...]
        var mutual: ?f64 = null;
        var tail: usize = 0;
        while (i + 1 < kv.len and kv[i + 1].key.len == 0) : (i += 1) {
            if (valueNumber(kv[i + 1].value)) |v| {
                if (tail == 0) mutual = v;
                tail += 1;
            }
        }
        inline for (.{ "r", "l", "c", "g" }, .{ "rm", "lm", "cm", "gm" }) |sf, mf| {
            if (std.mem.eql(u8, key, sf)) {
                @field(model, sf) = @floatCast(v0);
                if (mutual) |mv| @field(model, mf) = @floatCast(mv);
            }
        }
        if (std.mem.eql(u8, key, "length")) model.length = @floatCast(v0);
    }
}

pub fn valueNumber(value: types.Value) ?f64 {
    return switch (value) {
        .num => |n| n,
        else => null,
    };
}

fn applyKv(target: anytype, kv: []const types.Kv) !void {
    const T = @TypeOf(target.*);
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isScalarAssignable(field.type)) {
            if (kvNumber(kv, field.name)) |num|
                @field(target.*, field.name) = castField(field.type, num);
        }
    }
}

fn isScalarAssignable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        else => false,
    };
}

fn castField(comptime T: type, value: f64) T {
    return switch (@typeInfo(T)) {
        .float => @floatCast(value),
        .int => @intFromFloat(value),
        .bool => value != 0,
        else => @compileError("unsupported numeric field type"),
    };
}
