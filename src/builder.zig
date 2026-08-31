//! Builder: mutable netlist → frozen analysis.Circuit.
//!
//! Construction policy lives here with the app: node interning, subcircuit
//! tagging + BBD permutation, device accumulation. The batch mechanism
//! (ProtoStore/DeviceBatch) lives in devices/batch.zig; the pattern freeze
//! (analysis.freeze) in analysis/Circuit.zig.

const std = @import("std");
const analysis = @import("analysis");
const devices = @import("devices");
const types = @import("frontend/types.zig");
const vaload = @import("devices").vaload;
const batch = devices.batch;

const GROUND = analysis.GROUND;
const Circuit = analysis.Circuit;
const Proto = batch.Proto;

fn uCount(comptime D: type) usize {
    return @typeInfo(D.U).@"enum".fields.len;
}

fn isGroundName(name: []const u8) bool {
    return std.mem.eql(u8, name, "0") or
        std.ascii.eqlIgnoreCase(name, "gnd") or
        std.ascii.eqlIgnoreCase(name, "ground");
}

// ---------------------------------------------------------------------------
// Builder: mutable netlist. compile() freezes it into an analysis.Circuit.
// ---------------------------------------------------------------------------
const MULTI_INSTANCE: u32 = std.math.maxInt(u32);

pub const Builder = struct {
    gpa: std.mem.Allocator,
    n: u32,
    node_names: std.StringHashMapUnmanaged(u32),
    node_labels: std.ArrayList([]const u8),
    protos: std.ArrayList(Proto),
    // Per-node subcircuit instance (0 = top-level, MULTI_INSTANCE = coupling).
    // Populated by tagNodeInstance(); empty if no subcircuit structure.
    node_instance: std.ArrayList(u32) = .empty,
    node_type: std.ArrayList(u16) = .empty,

    pub fn init(gpa: std.mem.Allocator) Builder {
        var labels: std.ArrayList([]const u8) = .empty;
        // OOM is fatal here: a silent failure desyncs node_labels from n.
        labels.append(gpa, "0") catch @panic("OOM: node label");
        return .{
            .gpa = gpa,
            .n = 1,
            .node_names = .empty,
            .node_labels = labels,
            .protos = .empty,
        };
    }

    /// Only for a Builder that was never compiled.
    pub fn deinit(self: *Builder) void {
        for (self.protos.items) |p| p.destroy(p.ctx, self.gpa);
        self.protos.deinit(self.gpa);
        for (self.node_labels.items) |label| {
            if (!std.mem.eql(u8, label, "0")) self.gpa.free(label);
        }
        self.node_labels.deinit(self.gpa);
        self.node_names.deinit(self.gpa);
        self.node_instance.deinit(self.gpa);
        self.node_type.deinit(self.gpa);
        self.* = undefined;
    }

    /// Tag a node as belonging to a subcircuit instance. Call after internNode().
    /// If a node is tagged by multiple instances, it becomes a coupling node.
    pub fn tagNodeInstance(self: *Builder, node: u32, subckt_type: u16, subckt_instance: u32) !void {
        if (node == GROUND) return;
        // Grow to cover the node id.
        while (self.node_instance.items.len <= node) {
            try self.node_instance.append(self.gpa, 0);
            try self.node_type.append(self.gpa, 0);
        }
        const cur = self.node_instance.items[node];
        if (cur == 0 and subckt_instance != 0) {
            self.node_instance.items[node] = subckt_instance;
            self.node_type.items[node] = subckt_type;
        } else if (cur != 0 and subckt_instance != 0 and cur != subckt_instance) {
            self.node_instance.items[node] = MULTI_INSTANCE;
            self.node_type.items[node] = 0;
        }
    }

    const BbdResult = struct {
        perm: ?[]u32,
        info: ?analysis.BbdInfo,
    };

    fn computeBbd(self: *Builder) !BbdResult {
        if (self.node_instance.items.len == 0)
            return .{ .perm = null, .info = null };

        const gpa = self.gpa;
        const n: u32 = self.n;
        const ni = self.node_instance.items;
        const nt = self.node_type.items;

        // Collect unique (instance_id, type_id) pairs for internal nodes.
        // instance_id 0 or MULTI_INSTANCE means coupling.
        var instance_list: std.ArrayList(struct { inst: u32, typ: u16 }) = .empty;
        defer instance_list.deinit(gpa);
        for (1..@min(n, @as(u32, @intCast(ni.len)))) |i| {
            const inst = ni[i];
            if (inst == 0 or inst == MULTI_INSTANCE) continue;
            var found = false;
            for (instance_list.items) |e| {
                if (e.inst == inst) {
                    found = true;
                    break;
                }
            }
            if (!found) try instance_list.append(gpa, .{ .inst = inst, .typ = if (i < nt.len) nt[i] else 0 });
        }

        if (instance_list.items.len < 2)
            return .{ .perm = null, .info = null };

        // Build permutation: internal nodes grouped by instance, then coupling.
        const perm = try gpa.alloc(u32, n);
        errdefer gpa.free(perm);
        perm[0] = 0; // ground stays at 0
        var pos: u32 = 1;

        const blocks = try gpa.alloc(analysis.BbdBlock, instance_list.items.len);
        for (instance_list.items, 0..) |entry, bi| {
            const start = pos;
            for (1..@min(n, @as(u32, @intCast(ni.len)))) |i| {
                if (ni[i] == entry.inst) {
                    perm[i] = pos;
                    pos += 1;
                }
            }
            blocks[bi] = .{
                .start = start,
                .size = pos - start,
                .type_id = entry.typ,
                .instance_id = entry.inst,
            };
        }

        const coupling_start = pos;
        // Coupling + top-level + untagged nodes
        for (1..n) |i| {
            if (i >= ni.len or ni[i] == 0 or ni[i] == MULTI_INSTANCE) {
                perm[i] = pos;
                pos += 1;
            }
        }

        return .{
            .perm = perm,
            .info = .{
                .blocks = blocks,
                .coupling_start = coupling_start,
                .coupling_size = pos - coupling_start,
            },
        };
    }

    pub fn addNode(self: *Builder) u32 {
        const id = self.n;
        self.n += 1;
        self.node_labels.append(self.gpa, "") catch @panic("OOM: node label");
        return id;
    }

    /// Reserve hash-map/label capacity ahead of a known device count to
    /// avoid incremental rehashing during netlist construction.
    pub fn reserveNodes(self: *Builder, expected: u32) !void {
        try self.node_names.ensureTotalCapacity(self.gpa, expected);
        try self.node_labels.ensureTotalCapacity(self.gpa, expected + 1);
    }

    pub fn internNode(self: *Builder, name: []const u8) !u32 {
        if (isGroundName(name)) return GROUND;
        const gop = try self.node_names.getOrPut(self.gpa, name);
        if (gop.found_existing) return gop.value_ptr.*;
        const owned = self.gpa.dupe(u8, name) catch |err| {
            self.node_names.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.key_ptr.* = owned;
        const id = self.addNode();
        self.node_labels.items[id] = owned;
        gop.value_ptr.* = id;
        return id;
    }

    /// Add one device. Instances of the same type merge into one batch
    /// (archetype) regardless of call order. Branch unknowns are assigned
    /// here, so numbering is stable across interleaved adds.
    pub fn addDevice(
        self: *Builder,
        comptime D: type,
        model: D.Model,
        instance: D.Instance,
        nodes: anytype,
    ) !void {
        const n_u = comptime uCount(D);
        var all: [n_u]u32 = undefined;
        inline for (0..D.num_ports) |p| all[p] = nodes[p];
        // Zero-parasitic internal nodes collapse onto their port (ngspice
        // DIOsetup: posPrimeNode = posNode when RS=0). Keeping them separate
        // behind a 1e12 short makes elimination cancel catastrophically
        // (1e12 − 1e12·(1−ε) = float noise) and the Newton dx explodes.
        // The g_short stamps of a collapsed pair land on one slot and cancel
        // exactly, so device evals need no change.
        if (comptime @hasDecl(D, "collapse")) {
            const col = D.collapse(&model, &instance);
            inline for (D.num_ports..n_u) |u|
                all[u] = if (col[u]) |p| all[p] else self.addNode();
        } else {
            inline for (D.num_ports..n_u) |u| all[u] = self.addNode();
        }

        const store = try self.protoStore(D);
        try store.models.append(self.gpa, model);
        try store.instances.append(self.gpa, instance);
        try store.nodes.append(self.gpa, all);
    }

    /// Find-or-create the type-erased proto for a runtime (dlopen'd) device.
    /// Identity: the vtable's static name pointer — same trick as
    /// protoStore's @typeName pointer identity for comptime devices.
    pub fn dynProto(self: *Builder, vt: *const devices.dyn.DeviceVtable) !Proto {
        for (self.protos.items) |p| {
            if (p.type_name.ptr == vt.name.ptr) return p;
        }
        const proto = try vt.proto_create(self.gpa);
        try self.protos.append(self.gpa, proto);
        return proto;
    }

    fn protoStore(self: *Builder, comptime D: type) !*batch.ProtoStore(D) {
        const tn = @typeName(D);
        for (self.protos.items) |p| {
            if (p.type_name.ptr == tn.ptr) return @ptrCast(@alignCast(p.ctx));
        }
        const store = try self.gpa.create(batch.ProtoStore(D));
        store.* = .{};
        try self.protos.append(self.gpa, .{
            .ctx = store,
            .type_name = tn,
            .pattern = batch.ProtoStore(D).addPattern,
            .finalize = batch.ProtoStore(D).finalize,
            .destroy = batch.ProtoStore(D).destroy,
            .apply_perm = batch.ProtoStore(D).applyPerm,
        });
        return store;
    }

    /// Freeze: apply the BBD permutation, then hand the accumulated protos
    /// to analysis.freeze() which builds the union sparsity pattern,
    /// allocates planes and precomputes every slot tape. The Builder is
    /// consumed.
    pub fn compile(self: *Builder) !Circuit {
        const gpa = self.gpa;
        const n: usize = self.n;

        // BBD permutation: reorder nodes so subcircuit-internal nodes are
        // contiguous per instance, coupling nodes at the end.
        var bbd = try self.computeBbd();
        errdefer if (bbd.perm) |p| gpa.free(p);
        errdefer if (bbd.info) |inf| gpa.free(inf.blocks);
        if (bbd.perm) |perm| {
            for (self.protos.items) |p| p.apply_perm(p.ctx, perm);
            // Remap node_labels (node_names is not read past this point — the
            // reverse lookup now lives on the frozen Circuit as a scan).
            const old_labels = try gpa.alloc([]const u8, n);
            defer gpa.free(old_labels);
            @memcpy(old_labels, self.node_labels.items);
            for (old_labels, 0..) |label, i| {
                const new_i = if (i < perm.len) perm[i] else @as(u32, @intCast(i));
                self.node_labels.items[new_i] = label;
            }
            gpa.free(perm);
            bbd.perm = null; // freed; disarm the errdefer
        }

        // Flatten node_labels into the frozen intern table: one byte blob +
        // n+1 offsets. Evicts the per-node dupe and the name→id hashmap from
        // the Circuit — both stay Builder-local and die here.
        const labels = self.node_labels.items;
        var total: usize = 0;
        for (labels) |label| total += label.len;
        const intern_bytes = try gpa.alloc(u8, total);
        errdefer gpa.free(intern_bytes);
        const intern_offs = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(intern_offs);
        var off: u32 = 0;
        for (labels, 0..) |label, i| {
            intern_offs[i] = off;
            @memcpy(intern_bytes[off..][0..label.len], label);
            off += @intCast(label.len);
        }
        intern_offs[n] = off;

        const ckt = try analysis.freeze(gpa, self.n, intern_bytes, intern_offs, self.protos.items, bbd.info);

        // Protos consumed by freeze(); free the Builder shell (labels + map).
        self.protos.deinit(gpa);
        for (self.node_labels.items) |label| {
            if (!std.mem.eql(u8, label, "0")) gpa.free(label);
        }
        self.node_labels.deinit(gpa);
        self.node_names.deinit(gpa);
        self.node_instance.deinit(gpa);
        self.node_type.deinit(gpa);
        self.* = undefined;
        return ckt;
    }
};

// ===========================================================================
// netlist → Builder wiring policy: device resolution by card letter / model
// kind, source waveforms, B-source expression extraction, Verilog-A instance
// binding, kv/positional parsing.
// ===========================================================================

// ---------------------------------------------------------------------------
// Verilog-A / Verilog devices — loaded at runtime via `.hdl` cards (vaload).
// ---------------------------------------------------------------------------

/// First positional token names a runtime-loaded (.hdl card) device?
/// A .model card whose kind is a loaded module counts too
/// (`.model psp103n psp103va ...`).
fn isDynDevice(dev: types.Device, models: []const types.Model) bool {
    if (vaload.isEmpty() or dev.positional.len == 0) return false;
    const model_name = switch (dev.positional[0]) {
        .name => |nm| nm,
        else => return false,
    };
    if (vaload.get(model_name) != null) return true;
    if (findModel(models, model_name)) |m| return vaload.get(m.kind) != null;
    return false;
}

/// Runtime (dlopen'd) VA/V devices — card shape `<name> node... <model>`,
/// bound through the dyn vtable. Param blobs live on the arena until
/// proto_add copies them.
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
        // Either the card names the VA module directly, or it names a .model
        // card whose kind is the VA module (`.model psp103n psp103va ...`).
        const model_card = findModel(nl.models, model_name);
        const vt = vaload.get(model_name) orelse
            (if (model_card) |m| vaload.get(m.kind) else null) orelse continue;

        const mblob = try arena.alignedAlloc(u8, .@"16", vt.model_size);
        vt.init_model(mblob.ptr);
        if (model_card) |m| applyKvDyn(vt.set_model_param, mblob.ptr, m.kv);
        // Card kv overrides .model card: VA "instance" params are Model
        // fields (the generated Instance holds only temp), so a card's
        // R=100 must land in the model blob to take effect.
        applyKvDyn(vt.set_model_param, mblob.ptr, dl.kv[di]);
        // LRM 6.3.4 / 3.4.5, and it has to be HERE. Every write above lands in a
        // flat Model field, so a parameter declared over another one — and every
        // localparam — still holds the value it was built with. `derive` is the
        // device's own pass over those, and it must run after the LAST param write
        // and before anything reads the model: `collapse` below reads it, and
        // `proto_add` copies the blob wholesale.
        if (vt.derive) |df| df(mblob.ptr);
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

// ---------------------------------------------------------------------------
// NetBuilder — netlist → Builder wiring (no ArrayList, bucket-sized arrays)
// ---------------------------------------------------------------------------

fn isValueForm(comptime D: type) bool {
    return @hasDecl(D, "eval");
}

/// Write a POSITIONAL card value (`R1 a b 1k`, `F1 … 2.0`) to the named
/// parameter on whichever of Model/Instance declares it. `applyKv` covers the
/// `name=value` spellings; this covers the ones that arrive by position and so
/// have to be named in Zig.
///
/// The Model/Instance resolution is not decoration: FastVAF puts every
/// Verilog-A `parameter` on **Model**, while the hand-written Zig devices these
/// replaced put per-device values on Instance. Naming one struct means every
/// call site breaks (loudly, or — worse — silently under a `@hasField` guard)
/// the day a model moves a parameter across that line. Returns false when
/// neither declares it, so a caller that must not silently drop the value can
/// say so; the ones here are all @compileError-guarded or optional.
fn setParam(comptime D: type, model: *D.Model, instance: *D.Instance, comptime field: []const u8, value: f64) bool {
    if (comptime @hasField(D.Model, field)) {
        @field(model.*, field) = castField(@TypeOf(@field(model.*, field)), value);
    } else if (comptime @hasField(D.Instance, field)) {
        @field(instance.*, field) = castField(@TypeOf(@field(instance.*, field)), value);
    } else return false;
    return true;
}

pub const NetBuilder = struct {
    arena: std.mem.Allocator,
    b: *Builder,
    nl: types.Netlist,

    // Pre-allocated to bucket('v').size()
    v_names: [][]const u8,
    v_ports: []u32,
    /// Negative node of each V card. F/H/W name a source and control on the
    /// current through it; the 4-port `(p, n, cp, cn)` models take that
    /// source's NODE PAIR and derive the branch current themselves, so the
    /// binder has to carry both ends, not just the branch index.
    v_nports: []u32,
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
            .v_nports = try arena.alloc(u32, nv),
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
    ///
    /// Guarded by @hasField so it can be run over BOTH Model and Instance and
    /// no-op on the one that does not declare the PULSE block — see
    /// `bindSource`.
    fn resolvePulseDefaults(self: *const NetBuilder, target: anytype) void {
        if (comptime !@hasField(@TypeOf(target.*), "pulse_tr")) return;
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
        // Runtime-loaded Verilog-A/Verilog device instance: handled
        // by addDynDevices after NetBuilder runs, regardless of card letter.
        if (isDynDevice(dev, self.nl.models)) return;
        const letter = dev.letter();
        if (devices.letter_map.get(&.{letter}) == null) {
            if (inferDeviceFromModel(dev, self.nl.models) == null)
                return error.UnsupportedDevice;
        }

        switch (letter) {
            'r' => _ = try self.addPassive(devices.resistor, dev, "r", "resist"),
            'c' => _ = try self.addPassive(devices.capacitor, dev, "c", "cap"),
            'l' => {
                const br = try self.addPassive(devices.inductor, dev, "l", "inductance");
                self.l_names[self.n_l] = dev.name;
                self.l_branches[self.n_l] = br;
                self.l_values[self.n_l] = positionalNumber(dev, 0) orelse
                    kvNumber(dev.kv, "inductance") orelse kvNumber(dev.kv, "l") orelse 0;
                self.n_l += 1;
            },
            'v' => {
                if (comptime !isValueForm(devices.vsource)) return error.UnsupportedDevice;
                const bound = try self.bindSource(devices.vsource, dev);
                const nodes = try deviceNodes(self.b, devices.vsource, dev);
                const br = self.b.n;
                try self.b.addDevice(devices.vsource, bound[0], bound[1], nodes);
                self.v_names[self.n_v] = dev.name;
                self.v_ports[self.n_v] = nodes[0];
                self.v_nports[self.n_v] = if (nodes.len > 1) nodes[1] else 0;
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
                const bound = try self.bindSource(devices.isource, dev);
                try self.b.addDevice(devices.isource, bound[0], bound[1], try deviceNodes(self.b, devices.isource, dev));
                self.i_names[self.n_i] = dev.name;
                self.n_i += 1;
            },
            'f', 'h', 'w', 'k' => {
                self.deferred[self.n_deferred] = .{ .dev = dev, .letter = letter };
                self.n_deferred += 1;
            },
            'b' => try addBsource(self.b, dev, self.nl.models),
            'p' => try self.addCpl(dev),
            'o' => try self.addLossyLine(dev),
            else => try self.addByLetter(letter, dev),
        }
    }

    /// LTRA (O card). ngspice solves RLC lines by convolution with the exact
    /// impulse response; our lossy_tline device is a single lumped pi that
    /// cannot delay. For LC lines (G = 0) expand into N cascaded Bergeron
    /// sections [R/2N — ideal T(z0, td/N) — R/2N]: delay is exact, and the
    /// lumped-loss error falls as R_total/(2*Z0*N). N is picked for ~3e-4
    /// rms vs ngspice, capped at 48 (beyond that the residual difference is
    /// ngspice's own history compaction, not segmentation).
    /// RC / degenerate lines keep the single-pi lossy_tline device.
    fn addLossyLine(self: *NetBuilder, dev: types.Device) !void {
        var model: devices.lossy_tline.Model = .{};
        if (modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        try applyKv(&model, dev.kv);

        const len: f64 = @as(f64, model.len);
        const r_t: f64 = @as(f64, model.r) * len;
        const l_t: f64 = @as(f64, model.l) * len;
        const c_t: f64 = @as(f64, model.c) * len;
        const g_t: f64 = @as(f64, model.g) * len;

        if (l_t <= 0 or c_t <= 0 or g_t != 0) return self.addByLetter('o', dev);

        const z0 = @sqrt(l_t / c_t);
        const td = @sqrt(l_t * c_t);
        const n_sec: u32 = @intFromFloat(std.math.clamp(@ceil(r_t / (z0 * 0.005)), 1, 48));
        const r_half = r_t / (2.0 * @as(f64, @floatFromInt(n_sec)));

        const pos1 = if (dev.nodes.len > 0) try self.b.internNode(dev.nodes[0]) else GROUND;
        const neg1 = if (dev.nodes.len > 1) try self.b.internNode(dev.nodes[1]) else GROUND;
        const pos2 = if (dev.nodes.len > 2) try self.b.internNode(dev.nodes[2]) else GROUND;
        const neg2 = if (dev.nodes.len > 3) try self.b.internNode(dev.nodes[3]) else GROUND;

        const t_model: devices.tline.Model = .{
            .z0 = @floatCast(z0),
            .td = @floatCast(td / @as(f64, @floatFromInt(n_sec))),
        };
        var prev: u32 = pos1;
        for (0..n_sec) |i| {
            const last = i == n_sec - 1;
            // Series R/2N lump on the near side (skip for lossless lines).
            const t_in = if (r_half > 0) blk: {
                const nn = self.b.addNode();
                try self.b.addDevice(devices.resistor, .{ .r = @floatCast(r_half) }, .{}, [2]u32{ prev, nn });
                break :blk nn;
            } else prev;
            const t_out = if (r_half > 0 or !last) self.b.addNode() else pos2;
            // Intermediate sections reference neg1; only the last section's
            // far port sits on neg2 (identical when both are ground).
            try self.b.addDevice(devices.tline, t_model, .{}, [4]u32{ t_in, neg1, t_out, if (last) neg2 else neg1 });
            if (r_half > 0) {
                const nxt = if (last) pos2 else self.b.addNode();
                try self.b.addDevice(devices.resistor, .{ .r = @floatCast(r_half) }, .{}, [2]u32{ t_out, nxt });
                prev = nxt;
            } else {
                prev = t_out;
            }
        }
    }

    /// `R1 a b 1k` — the principal value arrives POSITIONALLY, so it cannot go
    /// through `applyKv`; it has to be written to a named field directly.
    ///
    /// `value_field` is the Verilog-A parameter name (`r`, `c`, `l`), and the
    /// generated devices put `parameter real r` on **Model**, not Instance —
    /// this used to name hand-written Zig fields (`Instance.resist`) that the
    /// VA models replaced. Resolved against whichever struct declares it so a
    /// model that makes its value an instance parameter still binds.
    ///
    /// `alias` is netlist spelling only (`R1 a b resist=1k`), never a field.
    fn addPassive(
        self: *NetBuilder,
        comptime D: type,
        dev: types.Device,
        comptime value_field: []const u8,
        comptime alias: []const u8,
    ) !u32 {
        if (comptime !isValueForm(D)) return error.UnsupportedDevice;
        if (comptime !@hasField(D.Model, value_field) and !@hasField(D.Instance, value_field))
            @compileError(@typeName(D) ++ ": no parameter `" ++ value_field ++ "` on Model or Instance");
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        const value = positionalNumber(dev, 0) orelse kvNumber(dev.kv, value_field) orelse kvNumber(dev.kv, alias) orelse 0;
        _ = setParam(D, &model, &instance, value_field, value);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        const nodes = try deviceNodes(self.b, D, dev);
        const br = self.b.n;
        try self.b.addDevice(D, model, instance, nodes);
        return br;
    }

    /// `V1 a b DC 5 PULSE(0 5 1n 1n 1n 1u 2u)` / the `I` card equivalent —
    /// everything except the nodes. `V` and `I` differ only in what the caller
    /// records afterwards, so the binding itself is one function.
    ///
    /// Every step runs over BOTH Model and Instance and is @hasField-guarded
    /// (`setParam`, and the guards inside `applySourceWaveform` /
    /// `resolvePulseDefaults`), so a model that moves a parameter across the
    /// Model/Instance line keeps binding. vsource.va / isource.va declare the
    /// whole waveform set on Model; the hand-written Zig sources they replaced
    /// had it on Instance.
    ///
    /// ORDER MATTERS. Positional `DC <v>` first, then the waveform group (a
    /// `PULSE(...)` may not carry a DC value), then card `kv` so an explicit
    /// `pulse_tr=2n` overrides the group, and only then `resolvePulseDefaults`
    /// — the -1 sentinels must survive everything that could legitimately set
    /// them before the `.tran` card gets to fill them in.
    fn bindSource(self: *const NetBuilder, comptime D: type, dev: types.Device) !struct { D.Model, D.Instance } {
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        _ = setParam(D, &model, &instance, "dc", sourceDc(dev));
        applySourceWaveform(&model, dev);
        applySourceWaveform(&instance, dev);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        self.resolvePulseDefaults(&model);
        self.resolvePulseDefaults(&instance);
        return .{ model, instance };
    }

    fn addByLetter(self: *NetBuilder, letter: u8, dev_in: types.Device) !void {
        // BJT lines have 3-5 nodes: Qname c b e [s] [dt] model [area]. The
        // parser fixes Q at 3 nodes, so extra nodes spill into positional and
        // hide the model name. Rebuild nodes/positionals using the model table.
        var norm: BjtNormBufs = undefined;
        const dev = if (letter == 'q') normalizeBjt(dev_in, self.nl.models, &norm) else dev_in;
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

    /// Node pair of a named V card — what a 4-port F/H/W control port binds to.
    fn findVNodes(self: *const NetBuilder, name: []const u8) ?[2]u32 {
        for (self.v_names[0..self.n_v], self.v_ports[0..self.n_v], self.v_nports[0..self.n_v]) |n, p, m| {
            if (std.mem.eql(u8, n, name)) return .{ p, m };
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
        const ctrl_nodes = self.findVNodes(ctrl_name) orelse return error.UnknownControlSource;

        var model: D.Model = .{};
        // W card: `W n+ n- Vctrl model` — model is positional[1] (positional[0]
        // is the control source). F/H put a number there, so the orelse falls
        // back to the plain model-name slot.
        if (positionalName(dev, 1) orelse modelName(dev)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        var instance: D.Instance = .{};
        if (comptime default_gain) |dflt|
            _ = setParam(D, &model, &instance, "gain", positionalNumber(dev, 1) orelse kvNumber(dev.kv, "gain") orelse dflt);
        try applyKv(&instance, dev.kv);

        // (p, n, cp, cn): the control port is the sensed source's own node
        // pair. The model puts a `branch (cp, cn) ctl` across it and reads
        // I(ctl), which IS the current through that source.
        const nodes = [4]u32{
            if (dev.nodes.len > 0) try self.b.internNode(dev.nodes[0]) else GROUND,
            if (dev.nodes.len > 1) try self.b.internNode(dev.nodes[1]) else GROUND,
            ctrl_nodes[0],
            ctrl_nodes[1],
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
        'z' => devices.mesDeviceId(level),
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
    if (eqlAny(m.kind, &.{ "nmf", "pmf", "nhfet", "phfet" }))
        return devices.mesDeviceId(l);
    return null;
}

fn eqlAny(a: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (std.ascii.eqlIgnoreCase(a, c)) return true;
    return false;
}

/// Polarity comes from the model card KIND (`.model qp PNP`), not from a
/// parameter, so `applyKv` never sees it and it has to be applied here.
fn isPType(kind: []const u8) bool {
    return eqlAny(kind, &.{ "pmos", "pnp", "pjf", "pmf", "phfet" });
}

/// The polarity field, under each of the three names the models spell it.
///
/// This used to test `@hasField(D.Model, "type_")` — a name NO device has.
/// Verilog-A `type` is a Zig primitive, so VerA's naming.zig marks it with a
/// trailing `Z` (its escape marker, which keeps the encoding injective) and
/// emits `typeZ`; a model that literally declares `type_` gets `typeZ5f`
/// (`_` = 0x5f); mos3 calls its own parameter `dev_type`. `@hasField` on the
/// wrong name is comptime-FALSE, which compiles clean and drops the branch —
/// so every PMOS/PNP/PJF silently ran as its N-type twin, and a lone PMOS
/// `.op` had no solution and returned NaN with exit 0. Do not "tidy" these
/// names to something that reads better; they are codegen output.
fn setPolarity(comptime D: type, model: *D.Model) !void {
    if (comptime @hasField(D.Model, "typeZ")) {
        model.typeZ = -1; // i64 on most, f64 on mos1/mos2 — `-1` coerces to both
    } else if (comptime @hasField(D.Model, "typeZ5f")) {
        model.typeZ5f = -1; // bsim2 declares `type_`
    } else if (comptime @hasField(D.Model, "dev_type")) {
        model.dev_type = -1; // mos3
    } else {
        // ponytail: mos6/mos9/jfet/jfet2/mes/mesa/vdmos/bsimsoi/hisim have no
        // polarity parameter at ALL, so a P-type card on them cannot be honoured.
        // Refusing is the point: running it N-type is what produced silent NaN.
        // Upgrade path is model-side — give the .va a `type` parameter the way
        // mos1 has one — not another branch here.
        return error.UnsupportedDevice;
    }
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
            if (isPType(m.kind)) try setPolarity(D, &model);
        }
    }
    _ = setParam(D, &model, &instance, "gain", positionalNumber(dev, 0) orelse 0);
    // Model-less cards (T line: "T1 a 0 b 0 Z0=50 TD=2n") carry their model
    // parameters inline on the device card — route kv to the model too.
    if (modelName(dev) == null) try applyKv(&model, dev.kv);
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

/// FastVAF flattens `parameter real pwl_times[0:63]` into 63+1 SCALAR Model
/// fields — there is no array to index — each named with the `naming.sanitize`
/// escape of its subscript: `[` is `Z5b`, `]` is `Z5d` (`Z` is the escape
/// marker precisely so a sanitized leaf can never collide, see
/// modules/FastVAF/src/naming.zig). So the slot has to be picked at comptime.
fn pwlSlot(comptime base: []const u8, comptime k: usize) []const u8 {
    // 2 arrays x 64 slots, each a comptime std.fmt run — well past the default
    // 12000 backwards branches on its own.
    @setEvalBranchQuota(200_000);
    return std.fmt.comptimePrint("{s}Z5b{d}Z5d", .{ base, k });
}

/// Table capacity read off the struct, not hardcoded: `max_pwl` lives in the
/// .va and this follows it.
fn pwlCapacity(comptime T: type) usize {
    comptime var n: usize = 0;
    inline while (@hasField(T, pwlSlot("pwl_times", n))) : (n += 1) {}
    return n;
}

fn applySourceWaveform(target: anytype, dev: types.Device) void {
    const T = @TypeOf(target.*);
    // Runs over both Model and Instance (see bindSource); the one that does not
    // declare the waveform set has nothing to do.
    if (comptime !@hasField(T, "waveform")) return;
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
            // `PWL(T1 V1 T2 V2 ...)`: (time, value) pairs into the flattened
            // table. Non-numeric args (ngspice's `r=` / `td=` suffixes) leave
            // their slot at the default; those two are card kv and land through
            // applyKv on `pwl_repeat` / `pwl_td`.
            .pwl => if (comptime @hasField(T, pwlSlot("pwl_times", 0))) {
                const n_pts = @min(group.args.len / 2, comptime pwlCapacity(T));
                inline for (0..comptime pwlCapacity(T)) |k| {
                    if (k < n_pts) {
                        if (valueNumber(group.args[2 * k])) |t|
                            @field(target.*, pwlSlot("pwl_times", k)) = @floatCast(t);
                        if (valueNumber(group.args[2 * k + 1])) |v|
                            @field(target.*, pwlSlot("pwl_values", k)) = @floatCast(v);
                    }
                }
                target.pwl_len = @intCast(n_pts);
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
    var skip: usize = 0; // numbers owed to a preceding AC keyword (mag [phase])
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .num => |n| {
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            return n;
        },
        .group => |group| {
            if (std.mem.eql(u8, group.name, "dc") and group.args.len > 0)
                return valueNumber(group.args[0]) orelse 0;
        },
        .name => |name| {
            if (std.mem.eql(u8, name, "dc")) {
                if (positionalNumber(dev, idx + 1)) |dc| return dc;
            } else if (std.mem.eql(u8, name, "ac")) {
                // "AC mag [phase]": those numbers are not the DC value.
                skip = 2;
            }
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

/// Backing storage for normalizeBjt; must outlive the returned Device
/// (internNode/applyKv copy what they need, so a caller-frame buffer is fine).
const BjtNormBufs = struct {
    nodes: [8][]const u8,
    num_text: [4][24]u8,
    pos: [4]types.Value,
};

/// Rebuild a Q device so positional[0] is the model name and all preceding
/// words (4th/5th nodes that the 3-node parser shape pushed into positional)
/// become nodes. The model name is the last positional matching a .model card;
/// numeric positionals before it are node names (e.g. substrate "0").
fn normalizeBjt(dev: types.Device, spice_models: []const types.Model, bufs: *BjtNormBufs) types.Device {
    // Locate the model name among the positionals.
    var model_idx: ?usize = null;
    for (dev.positional, 0..) |p, i| switch (p) {
        .name => |n| if (findModel(spice_models, n) != null) {
            model_idx = i;
        },
        else => {},
    };
    const mi = model_idx orelse return dev; // no match: keep old behavior
    if (mi == 0) return dev; // already normalized (3-node form)

    // nodes = dev.nodes ++ positional[0..mi]
    var n_nodes: usize = 0;
    for (dev.nodes) |n| {
        if (n_nodes >= bufs.nodes.len) return dev;
        bufs.nodes[n_nodes] = n;
        n_nodes += 1;
    }
    for (dev.positional[0..mi], 0..) |p, i| {
        if (n_nodes >= bufs.nodes.len) return dev;
        bufs.nodes[n_nodes] = switch (p) {
            .name => |n| n,
            // Numeric node name (e.g. ground "0"): recover its text.
            .num => |v| std.fmt.bufPrint(&bufs.num_text[i], "{d}", .{v}) catch return dev,
            else => return dev,
        };
        n_nodes += 1;
    }

    // positional = positional[mi..] (model name first, then e.g. area)
    const tail = dev.positional[mi..];
    if (tail.len > bufs.pos.len) return dev;
    @memcpy(bufs.pos[0..tail.len], tail);

    var out = dev;
    out.nodes = bufs.nodes[0..n_nodes];
    out.positional = bufs.pos[0..tail.len];
    return out;
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
                @field(target.*, field.name) = castField(field.type, num)
            else if (comptime std.mem.eql(u8, field.name, "vt0")) {
                // ngspice accepts both "vt0" and "vto" spellings (IOPR).
                if (kvNumber(kv, "vto")) |num|
                    @field(target.*, field.name) = castField(field.type, num);
            } else if (comptime std.mem.eql(u8, field.name, "vto")) {
                if (kvNumber(kv, "vt0")) |num|
                    @field(target.*, field.name) = castField(field.type, num);
            }
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

// ---------------------------------------------------------------------------
// Source binding regression check
//
// The two things that break silently when the .va and the binder drift apart:
// the flattened PWL table (`applySourceWaveform` writes mangled field names
// that no compiler will catch a typo in — @hasField just skips) and the -1
// PULSE sentinels (an unspecified PULSE has to stay a step; if a default ever
// stops being -1 the .tran resolution turns into a 2 ns square wave).
// ---------------------------------------------------------------------------

test "V card: PWL table lands in the flattened Model slots" {
    const args = [_]types.Value{
        .{ .num = 0.0 },   .{ .num = 0.0 },
        .{ .num = 10e-3 }, .{ .num = 5.0 },
        .{ .num = 20e-3 }, .{ .num = 0.0 },
    };
    const positional = [_]types.Value{.{ .group = .{ .name = "PWL", .args = &args } }};
    const dev: types.Device = .{
        .name = "Vc",
        .nodes = &.{ "ctl", "0" },
        .positional = &positional,
        .kv = &.{},
    };

    var model: devices.vsource.Model = .{};
    applySourceWaveform(&model, dev);

    try std.testing.expectEqual(@as(i64, @intFromEnum(Wave.pwl)), @as(i64, model.waveform));
    try std.testing.expectEqual(@as(i64, 3), @as(i64, model.pwl_len));
    try std.testing.expectEqual(@as(f64, 0.0), @field(model, pwlSlot("pwl_times", 0)));
    try std.testing.expectEqual(@as(f64, 10e-3), @field(model, pwlSlot("pwl_times", 1)));
    try std.testing.expectEqual(@as(f64, 5.0), @field(model, pwlSlot("pwl_values", 1)));
    try std.testing.expectEqual(@as(f64, 20e-3), @field(model, pwlSlot("pwl_times", 2)));
    // Slot 3 is past the table and must stay at its default, or the model's
    // `pwl_len`-bounded loops would walk into stale data.
    try std.testing.expectEqual(@as(f64, 0.0), @field(model, pwlSlot("pwl_times", 3)));
    try std.testing.expect(pwlCapacity(devices.vsource.Model) >= 3);
}

test "V/I cards: unspecified PULSE edges stay at the -1 sentinel" {
    // PULSE(0 5) — no TR/TF/PW/PER. resolvePulseDefaults fills these from the
    // .tran card; until it runs they must still read as "unset".
    const args = [_]types.Value{ .{ .num = 0.0 }, .{ .num = 5.0 } };
    const positional = [_]types.Value{.{ .group = .{ .name = "PULSE", .args = &args } }};
    const dev: types.Device = .{
        .name = "V1",
        .nodes = &.{ "a", "0" },
        .positional = &positional,
        .kv = &.{},
    };

    inline for (.{ devices.vsource, devices.isource }) |D| {
        var model: D.Model = .{};
        applySourceWaveform(&model, dev);
        try std.testing.expectEqual(@as(f64, 5.0), model.pulse_v2);
        try std.testing.expect(model.pulse_tr < 0);
        try std.testing.expect(model.pulse_tf < 0);
        try std.testing.expect(model.pulse_pw < 0);
        try std.testing.expect(model.pulse_per < 0);
    }
}
