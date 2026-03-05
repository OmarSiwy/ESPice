//! Builder: mutable netlist → frozen problem.Circuit.
//!
//! Frontend construction owns node interning, subcircuit tagging, BBD
//! permutation and device accumulation through the neutral device IR.
//! problem/types.zig freezes the pattern; analysis owns numerical execution.

const std = @import("std");
const problem = @import("problem_types");
const requests = @import("requests");
const numerics = @import("numerics");
const devices = @import("devices");
const types = @import("syntax").types;
const vaload = @import("devices").vaload;
const batch = @import("device_ir");

const GROUND = @as(u32, 0);
const Circuit = problem.Circuit;
const Proto = batch.Proto;

fn isGroundName(name: []const u8) bool {
    return std.mem.eql(u8, name, "0") or
        std.ascii.eqlIgnoreCase(name, "gnd") or
        std.ascii.eqlIgnoreCase(name, "ground");
}

// ---------------------------------------------------------------------------
// Builder: mutable netlist. compile() freezes it into an problem.Circuit.
// ---------------------------------------------------------------------------
const MULTI_INSTANCE: u32 = std.math.maxInt(u32);

/// `ParamRef.device_type` is `@typeName(D)` past the last dot; match it.
fn shortTypeName(comptime D: type) []const u8 {
    const full = @typeName(D);
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

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
    needs_tran_op: bool = false,
    /// `.options tnom` in DEGREES CELSIUS — ngspice's `CKTnomTemp`
    /// (`cktsopt.c:71-73` converts the card to K; `cktntask.c:127` defaults it
    /// to 300.15 K = 27 degC): the temperature a model card that gives no
    /// `TNOM`/`TREF` of its own was extracted at. ONE number per run, so it
    /// lives here rather than on every Model; `deriveModel` copies it into the
    /// models that declare they read it.
    nom_temp_c: f64 = 27.0,

    /// Netlist card currently being expanded, "" outside one. Set once per
    /// card by NetBuilder.addDevice — the single funnel every card goes
    /// through — and read by addDevice below.
    card: []const u8 = "",
    /// (device type, instance ordinal) → card name. `ParamRef` identifies a
    /// device only by its class ordinal (`resistor#0`), which is not resolvable
    /// to anything in a raw file; `.sens` needs the card. Strings point into
    /// the PARSE arena, like `NetBuilder.v_names` — copy before it dies.
    cards: std.ArrayList(requests.CardRef) = .empty,
    /// Per-device-type instance counter — the ordinal `ParamRef.index` carries.
    /// Kept here rather than read off a `ProtoStore` because a GENERATED device
    /// is instantiated through `vt.proto_add` into the device object's own
    /// store, which this compilation unit deliberately cannot name. Counted for
    /// EVERY add, card or not, so the ordinal stays in lockstep with the store.
    card_counts: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) !Builder {
        var labels: std.ArrayList([]const u8) = .empty;
        try labels.append(gpa, "0");
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
        self.deinitStorage();
    }

    inline fn deinitStorage(self: *Builder) void {
        self.protos.deinit(self.gpa);
        self.cards.deinit(self.gpa);
        self.card_counts.deinit(self.gpa);
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
        info: ?numerics.BbdInfo,
    };

    fn computeBbd(self: *Builder) !BbdResult {
        if (self.node_instance.items.len == 0)
            return .{ .perm = null, .info = null };

        const gpa = self.gpa;
        const n: u32 = self.n;
        const ni = self.node_instance.items;
        const nt = self.node_type.items;

        // Collect unique (instance_id, type_id) pairs for internal nodes in
        // first-seen node order. instance_id 0 or MULTI_INSTANCE means coupling.
        // `at` counts the block's nodes here and becomes its write cursor below.
        var instance_list: std.ArrayList(struct { inst: u32, typ: u16, at: u32 }) = .empty;
        defer instance_list.deinit(gpa);
        // inst -> block index. Replaces the linear first-seen rescan, which was
        // O(nodes * instances) on a deck with many subcircuit instances.
        var index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer index.deinit(gpa);
        const tagged = @min(n, @as(u32, @intCast(ni.len)));
        for (1..tagged) |i| {
            const inst = ni[i];
            if (inst == 0 or inst == MULTI_INSTANCE) continue;
            const gop = try index.getOrPut(gpa, inst);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(instance_list.items.len);
                try instance_list.append(gpa, .{ .inst = inst, .typ = if (i < nt.len) nt[i] else 0, .at = 0 });
            }
            instance_list.items[gop.value_ptr.*].at += 1;
        }

        if (instance_list.items.len < 2)
            return .{ .perm = null, .info = null };

        // Build permutation: internal nodes grouped by instance, then coupling.
        const perm = try gpa.alloc(u32, n);
        errdefer gpa.free(perm);
        perm[0] = 0; // ground stays at 0
        var pos: u32 = 1;

        // Prefix-sum the counts into block starts, then scatter every tagged
        // node in one ascending pass — same order the per-block rescan produced.
        const blocks = try gpa.alloc(numerics.BbdBlock, instance_list.items.len);
        for (instance_list.items, blocks) |*entry, *blk| {
            blk.* = .{
                .start = pos,
                .size = entry.at,
                .type_id = entry.typ,
                .instance_id = entry.inst,
            };
            entry.at = pos;
            pos += blk.size;
        }
        for (1..tagged) |i| {
            const bi = index.get(ni[i]) orelse continue;
            const cursor = &instance_list.items[bi].at;
            perm[i] = cursor.*;
            cursor.* += 1;
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

    pub fn addNode(self: *Builder) !u32 {
        if (self.n == std.math.maxInt(u32)) return error.TooManyNodes;
        const id = self.n;
        try self.node_labels.append(self.gpa, "");
        self.n += 1;
        return id;
    }

    /// Reserve hash-map/label capacity ahead of a known device count to
    /// avoid incremental rehashing during netlist construction.
    pub fn reserveNodes(self: *Builder, expected: u32) !void {
        if (expected == std.math.maxInt(u32)) return error.TooManyNodes;
        try self.node_names.ensureTotalCapacity(self.gpa, expected);
        try self.node_labels.ensureTotalCapacity(self.gpa, expected + 1);
    }

    pub fn internNode(self: *Builder, name: []const u8) !u32 {
        if (isGroundName(name)) return GROUND;
        const gop = try self.node_names.getOrPut(self.gpa, name);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer self.node_names.removeByPtr(gop.key_ptr);
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        const id = try self.addNode();
        gop.key_ptr.* = owned;
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
        const n_u = comptime std.meta.fields(D.U).len;
        var all: [n_u]u32 = undefined;
        inline for (0..D.num_ports) |p| all[p] = nodes[p];

        // BEFORE the generated-device branch below, which returns. Every
        // shipped device has a generated model, so a card table hung off the
        // in-process `ProtoStore` path recorded nothing at all.
        {
            const gop = try self.card_counts.getOrPut(self.gpa, comptime shortTypeName(D));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            if (self.card.len != 0) try self.cards.append(self.gpa, .{
                .type_name = comptime shortTypeName(D),
                .index = gop.value_ptr.*,
                .name = self.card,
            });
            gop.value_ptr.* += 1;
        }

        // A GENERATED device is reached through its own object's vtable: same
        // `collapse`, same `ProtoStore(D).append` behind `proto_add`, the only
        // difference being which compilation unit they were codegen'd in —
        // which is the whole point (analysis/eval.zig). Naming
        // `D.collapse` or `ProtoStore(D)` here instead drags the device body
        // back into the executable's own compilation and undoes the split.
        const vt = if (comptime devices.modelName(D)) |name|
            devices.vtable(name)
        else if (@hasDecl(D, "deviceVtable"))
            D.deviceVtable()
        else
            @compileError("custom models must provide a neutral deviceVtable binding");
        if (comptime n_u > D.num_ports) {
            var col: [n_u]i32 = @splat(-1);
            if (vt.collapse) |collapse| collapse(@ptrCast(&model), @ptrCast(&instance), &col);
            for (D.num_ports..n_u) |u|
                all[u] = if (col[u] >= 0) all[@intCast(col[u])] else try self.addNode();
        }
        const proto = try self.dynProto(vt);
        try vt.proto_add(proto.ctx, self.gpa, @ptrCast(&model), @ptrCast(&instance), &all);
    }

    /// Find-or-create the type-erased proto for a runtime (dlopen'd) device.
    /// Identity: the vtable's static name pointer — same trick as
    /// protoStore's @typeName pointer identity for comptime devices.
    pub fn dynProto(self: *Builder, vt: *const batch.DeviceVtable) !Proto {
        for (self.protos.items) |p| {
            if (p.type_name.ptr == vt.name.ptr) return p;
        }
        const proto = try vt.proto_create(self.gpa);
        try self.protos.append(self.gpa, proto);
        return proto;
    }

    /// Freeze: apply the BBD permutation, then hand the accumulated protos
    /// to problem.Circuit.init() which builds the union sparsity pattern,
    /// precomputes every slot tape. The Builder is
    /// consumed.
    /// `perm_out` receives the BBD node permutation (old id -> frozen id) this
    /// applied, or null when no subckt structure forced one. The caller MUST
    /// read it to remap any pre-compile index it recorded (source branches,
    /// .ic nodes, directive nodes) — compile() undefines `self` on return, so
    /// the permutation cannot be fetched from the Builder afterward, and the
    /// device protos were already permuted through applyPerm while these
    /// caller-side tables were not (subckt branch probes read a voltage
    /// otherwise — fourbitadder i(vin1a) carried ~5 V).
    /// Bare form for callers that never recorded a pre-compile index (tests,
    /// embeddings). Discards the permutation; a subckt-BBD deck driven through
    /// this loses nothing because there is nothing caller-side to remap.
    pub fn compile(self: *Builder) !Circuit {
        var perm: ?[]const u32 = undefined;
        return self.compilePerm(&perm);
    }

    pub fn compilePerm(self: *Builder, perm_out: *?[]const u32) !Circuit {
        const gpa = self.gpa;
        perm_out.* = null;
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
            // Arena-owned, handed to the caller (not freed): it remaps the
            // pre-compile indices compile() cannot reach after `self.* =
            // undefined` below.
            perm_out.* = perm;
            bbd.perm = null; // ownership moved; disarm the errdefer
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

        var ckt = try problem.Circuit.init(gpa, self.n, intern_bytes, intern_offs, self.protos.items, bbd.info);
        ckt.needs_tran_op = self.needs_tran_op;

        // Protos consumed by freeze(); free the Builder shell (labels + map).
        self.deinitStorage();
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
    if (vaload.isEmpty()) return false;
    const model_name = positionalName(dev, 0) orelse return false;
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
        if (model_card) |m| try applyKvDyn(vt.set_model_param, mblob.ptr, m.kv);
        // Card kv overrides .model card: VA "instance" params are Model
        // fields (the generated Instance holds only temp), so a card's
        // R=100 must land in the model blob to take effect.
        try applyKvDyn(vt.set_model_param, mblob.ptr, dl.kv[di]);
        // LRM 6.3.4 / 3.4.5, and it has to be HERE. Every write above lands in a
        // flat Model field, so a parameter declared over another one — and every
        // localparam — still holds the value it was built with. `derive` is the
        // device's own pass over those, and it must run after the LAST param write
        // and before anything reads the model: `collapse` below reads it, and
        // `proto_add` copies the blob wholesale.
        if (vt.derive) |df| df(mblob.ptr);
        const iblob = try arena.alignedAlloc(u8, .@"16", vt.instance_size);
        vt.init_instance(iblob.ptr);
        try applyKvDyn(vt.set_instance_param, iblob.ptr, dl.kv[di]);

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
                nodes[u] = if (col[u] >= 0) nodes[@intCast(col[u])] else try b.addNode();
        }

        const proto = try b.dynProto(vt);
        try vt.proto_add(proto.ctx, b.gpa, mblob.ptr, iblob.ptr, nodes.ptr);
    }
}

/// ngspice IOPR alternate parameter spellings — card keys accepted for a model
/// field of the canonical name. Comptime: drives applyKv's fallback probe.
/// A field may carry SEVERAL keys (dio.c answers to `cjo`, `cj0` and `cj`), so
/// this returns every match, not the first.
///
/// The table is GLOBAL across every comptime device, so a pair is only safe
/// when no other model declares the alias as a parameter in its own right.
/// That is why dio.c's `js`->`is` is NOT here: mos1/mos2/mos3/mos6/mos9 declare
/// both `is` (bulk junction current) and `js` (its area density), and the pair
/// would smear a MOS card's JS into IS as well.
fn aliasesOf(comptime field: []const u8) []const []const u8 {
    const pairs = [_][2][]const u8{
        .{ "vt0", "vto" }, .{ "vto", "vt0" },
        .{ "vaf", "va" },  .{ "VAR", "vb" },
        .{ "ikf", "ik" },  .{ "cjs", "ccs" },
        // BJT depletion-cap alternates (bjt.c IOPR): the schmitt canon deck
        // spells cje/PE/ME, cjc/PC/MC — dropped aliases meant default
        // junction potentials and wrong switching instants.
        .{ "vje", "pe" },  .{ "mje", "me" },
        .{ "vjc", "pc" },  .{ "mjc", "mc" },
        .{ "vjs", "ps" },  .{ "mjs", "ms" },
        // mesa.va channel depth: ngspice's card key is `d`, which Verilog-A
        // cannot use as a parameter name (drain port).
        .{ "dch", "d" },
        // `u0`/`u1`/`u10` are Zig primitive type names, so VerA's naming.zig
        // emits the Model fields as `u0Z`/`u1Z`/`u10Z` (its escape marker) —
        // the card keys stay unescaped. Without these aliases every such card
        // silently kept the default (bsim3 fixtures drew 2x current; mos1's
        // U0 was equally dead when TOX was given; bsim1's U1 velocity
        // saturation vanished, +8% at the bsim1_a probe).
          .{ "u0Z", "u0" },
        .{ "u1Z", "u1" },  .{ "u10Z", "u10" },
        .{ "pubZ", "pub" }, // BSIM mobility bin coefficient; pub is a Zig keyword.
        // Diode alternates (dio.c IOPR). Only diode.va/vdmos.va declare `cjo`
        // and `vj`, and nothing declares `trs`/`cta`/`tpb` but diode.va, so
        // none of these can collide with another model's own parameter.
        .{ "tnom", "tref" },
        .{ "cjo", "cj0" },
        .{ "cjo", "cj" },
        .{ "vj", "pb" },
        .{ "trs", "trs1" },
        .{ "cta", "ctc" },
        .{ "tpb", "tvj" },
    };
    comptime {
        var out: [pairs.len][]const u8 = undefined;
        var n: usize = 0;
        for (pairs) |p| {
            if (std.mem.eql(u8, field, p[0])) {
                out[n] = p[1];
                n += 1;
            }
        }
        const frozen = out;
        return frozen[0..n];
    }
}

fn applyKvDyn(set: *const fn ([*]u8, []const u8, f64) bool, dest: [*]u8, kv: []const types.Kv) !void {
    for (kv) |item| {
        if (valueNumber(item.value)) |num| {
            if (set(dest, item.key, num)) continue;
        }
        // The bool ABI distinguishes success from unknown/invalid together.
        // Zero probes field existence only on a failed write. A recognized
        // invalid value immediately discards this construction blob, so the
        // probe's mutation never reaches a prepared circuit.
        if (set(dest, item.key, 0)) return error.InvalidParameterValue;
    }
}

// ---------------------------------------------------------------------------
// NetBuilder — netlist → Builder wiring (no ArrayList, bucket-sized arrays)
// ---------------------------------------------------------------------------

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
fn setParam(comptime D: type, model: *D.Model, instance: *D.Instance, comptime field: []const u8, value: f64) !bool {
    if (comptime @hasField(D.Model, field)) {
        @field(model.*, field) = try castField(@TypeOf(@field(model.*, field)), value);
        markGiven(model, field);
    } else if (comptime @hasField(D.Instance, field)) {
        @field(instance.*, field) = try castField(@TypeOf(@field(instance.*, field)), value);
        markGiven(instance, field);
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
    /// DC value of each V card, and whether an F/H/W card sensed it. A sensed
    /// source is NOT stamped: the 4-port model carries its own `branch (cp,cn)
    /// ctrl` and drives `V(ctrl) <+ vsense`, so leaving the original in place
    /// put two sources across one node pair and the control current split
    /// between them (`I/(1+N)` for N consumers). `v_dc` is what `vsense` gets.
    v_dc: []f64,
    v_sensed: []bool,
    /// `DISTOF1 [mag [phase]]` off each V card — `.disto`'s F1 drive, and the
    /// ONLY thing that selects which source it lands on (ngspice
    /// cktdisto.c:100-117). `{0, 0}` means the card never named it, which is
    /// also ngspice's no-op. Degrees, like the AC phase.
    v_distof1: [][2]f64,
    /// `.sp` port index of each V card, 1-based; 0 = not a port. ngspice keeps
    /// the same thing as `VSRCportNum`/`VSRCportZ0` on the source instance
    /// (vsrcdefs.h:104-105) and sorts `CKTrfPorts` by it (vsrctemp.c:110-124).
    v_portnum: []u16,
    v_z0: []f64,
    n_v: u32,

    // -- Branch-current probes that are neither a V card nor an inductor -----
    // ngspice gives EVERY MNA branch-current unknown a `CKTmkCur` row
    // (vcvsset.c:41-46, ccvsset.c:41-46, asrcsetup.c:78-83 for a V-mode B),
    // and `CKTnames` turns every such row into an `i(<card>)` column. E, H and
    // a V-mode B therefore have currents in ngspice's raw exactly as V and L
    // do; only F, G, S and an I-mode B do not, because they stamp no branch.
    br_names: [][]const u8,
    br_rows: []u32,
    n_br: u32,

    // -- Frequency-domain parameter overrides (`R2 2 0 5K ac=15k`) ----------
    // ngspice res.c:16 declares `ac` as an IOPAA on the resistor; restemp.c
    // :112-118 turns it into RESacConduct with the SAME m/scale/tempco factors
    // as the DC conductance, and resload.c:60-62 stamps it in place of
    // RESconduct for every AC load. Recorded by CARD here because instance
    // ordinals (and the ParamRef pointers they key) only exist after freeze.
    ac_res_names: [][]const u8,
    ac_res_values: []f64,
    n_ac_res: u32,

    // Pre-allocated to bucket('i').size()
    i_names: [][]const u8,
    n_i: u32,

    // -- AC excitation table: one row per source carrying an `AC` spec -------
    // ngspice `CKTacLoad` (analysis/acan.c:471-490) runs EVERY device's acLoad
    // into ONE rhs, so an .ac run drives every V and I card that named `AC` at
    // once, each at its own magnitude and phase. A card with no `AC` is simply
    // ABSENT here (existence-based, no `has_ac` flag): vsrcacld.c:171 and
    // isrcacld.c:36 load acReal = acImag = 0 for it, leaving a V source an AC
    // short and an I source an AC open while both still stamp the matrix.
    //
    // `ac_pos`/`ac_neg` are the two rows an entry subtracts from / adds to
    // under Circuit.rhs's residual sign (the AC solve's rhs is −F). An I card
    // gives (n+, n−), matching isrcacld.c's two node stamps. A V card drives
    // its BRANCH row only (vsrcacld.c:175 stamps rhs[branch]), so it lands as
    // (GROUND, branch) and one untagged two-row loop covers both kinds. GROUND
    // rows are skipped — row 0 is the ground clamp, not an unknown.
    ac_pos: []u32,
    ac_neg: []u32,
    ac_re: []f64,
    ac_im: []f64,
    n_ac: u32,

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

    // -- Topology diagnosis (ngspice CKTsetup-class checks) --------------
    // Per netlist-NAMED node: what touched it. Internal expansion nodes
    // (URC lumps, device primes) never enter these — only nodes a card
    // listed, so the post-build check cannot false-positive on machinery.
    // `.seen` gates the check; `.dc` = any element that stamps a DC path
    // (everything except capacitors and current sources); `.cur` = an I
    // source touched it. V/L cards are DC SHORTS for loop detection: a
    // union-find over their node pairs — closing a cycle of shorts is
    // ngspice's "voltage source/inductor loop".
    topo_seen: std.ArrayList(bool) = .empty,
    topo_dc: std.ArrayList(bool) = .empty,
    topo_cur: std.ArrayList(bool) = .empty,
    /// Weighted union-find over V/L short edges: `topo_pot[x]` is v(x) minus
    /// v(parent). A cycle of shorts is only an ERROR when its KVL sum is
    /// inconsistent (V1=5 ∥ V2=3); a consistent cycle (two 0 V .sp ports
    /// closed by an inductor, parallel equal sources) is legal — its loop
    /// current is indeterminate at DC and the solver's regularization owns it.
    topo_uf: std.ArrayList(u32) = .empty,
    topo_pot: std.ArrayList(f64) = .empty,

    const Deferred = struct { dev: types.Device, letter: u8 };

    pub fn init(arena: std.mem.Allocator, b: *Builder, nl: types.Netlist) !NetBuilder {
        const dl = nl.devices;
        const nv = dl.bucket('v').size();
        const ni = dl.bucket('i').size();
        const nl_ = dl.bucket('l').size();
        const n_def = dl.bucket('f').size() + dl.bucket('h').size() +
            dl.bucket('w').size() + dl.bucket('k').size();
        const n_br = dl.bucket('e').size() + dl.bucket('h').size() + dl.bucket('b').size();
        const nr = dl.bucket('r').size();

        return .{
            .arena = arena,
            .b = b,
            .nl = nl,
            .v_names = try arena.alloc([]const u8, nv),
            .v_ports = try arena.alloc(u32, nv),
            .v_nports = try arena.alloc(u32, nv),
            .v_branches = try arena.alloc(u32, nv),
            .v_dc = try arena.alloc(f64, nv),
            .v_sensed = try arena.alloc(bool, nv),
            .v_distof1 = try arena.alloc([2]f64, nv),
            .v_portnum = try arena.alloc(u16, nv),
            .v_z0 = try arena.alloc(f64, nv),
            .n_v = 0,
            .br_names = try arena.alloc([]const u8, n_br),
            .br_rows = try arena.alloc(u32, n_br),
            .n_br = 0,
            .ac_res_names = try arena.alloc([]const u8, nr),
            .ac_res_values = try arena.alloc(f64, nr),
            .n_ac_res = 0,
            .i_names = try arena.alloc([]const u8, ni),
            .n_i = 0,
            .ac_pos = try arena.alloc(u32, nv + ni),
            .ac_neg = try arena.alloc(u32, nv + ni),
            .ac_re = try arena.alloc(f64, nv + ni),
            .ac_im = try arena.alloc(f64, nv + ni),
            .n_ac = 0,
            .l_names = try arena.alloc([]const u8, nl_),
            .l_branches = try arena.alloc(u32, nl_),
            .l_values = try arena.alloc(f64, nl_),
            .n_l = 0,
            .deferred = try arena.alloc(Deferred, n_def),
            .n_deferred = 0,
            .source_node = GROUND,
            .source_branch = GROUND,
        };
    }

    fn addBranchProbe(self: *NetBuilder, name: []const u8, row: u32) void {
        self.br_names[self.n_br] = name;
        self.br_rows[self.n_br] = row;
        self.n_br += 1;
    }

    /// Record one AC-driving source. See the `ac_pos`/`ac_neg` note on the
    /// struct for why a V card arrives as (GROUND, branch).
    fn addAcDrive(self: *NetBuilder, pos: u32, neg: u32, re: f64, im: f64) void {
        self.ac_pos[self.n_ac] = pos;
        self.ac_neg[self.n_ac] = neg;
        self.ac_re[self.n_ac] = re;
        self.ac_im[self.n_ac] = im;
        self.n_ac += 1;
    }

    /// Collapse the AC table into the composite excitation the frequency
    /// solves take: one stacked-real vector `[re(0..n), im(0..n)]` over the
    /// circuit unknowns, which is ngspice's post-`CKTacLoad` (CKTrhs, CKTirhs)
    /// pair. Every source lands in the SAME vector, so a deck with two driven
    /// V cards and an I card is one solve per frequency, not a special case.
    /// All-zero when no card named `AC` — the correct zero response.
    ///
    /// Rows must already be in post-permutation coordinates (see frontend/prepare.zig).
    pub fn acExcitation(self: *const NetBuilder, gpa: std.mem.Allocator, n: usize) ![]f64 {
        const exc = try gpa.alloc(f64, 2 * n);
        @memset(exc, 0);
        for (self.ac_pos[0..self.n_ac], self.ac_neg[0..self.n_ac], self.ac_re[0..self.n_ac], self.ac_im[0..self.n_ac]) |pos, neg, re, im| {
            if (pos != GROUND) {
                exc[pos] -= re;
                exc[n + pos] -= im;
            }
            if (neg != GROUND) {
                exc[neg] += re;
                exc[n + neg] += im;
            }
        }
        return exc;
    }

    /// The deck's `.sp` ports, ordered by `portnum` — ngspice sorts
    /// `CKTrfPorts` the same way (vsrctemp.c:110-124) and rejects a gapped or
    /// duplicated numbering as "incorrect port ordering" (vsrctemp.c:143-160).
    /// Empty when no V card carries `portnum`, which leaves `.sp` on its
    /// one-port fallback.
    pub fn portList(self: *const NetBuilder, gpa: std.mem.Allocator) ![]requests.Port {
        var n_ports: usize = 0;
        for (self.v_portnum[0..self.n_v]) |num| n_ports = @max(n_ports, num);
        if (n_ports == 0) return &.{};
        const ports = try gpa.alloc(requests.Port, n_ports);
        for (ports) |*p| p.branch = std.math.maxInt(u32); // "unset" marker
        for (self.v_portnum[0..self.n_v], self.v_ports[0..self.n_v], self.v_branches[0..self.n_v], self.v_z0[0..self.n_v]) |num, node, br, z0| {
            if (num == 0) continue;
            const slot = &ports[num - 1];
            if (slot.branch != std.math.maxInt(u32)) return error.DuplicatePortNumber;
            slot.* = .{ .node = node, .branch = br, .z0 = z0 };
        }
        for (ports) |p| if (p.branch == std.math.maxInt(u32)) return error.MissingPortNumber;
        return ports;
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
        // Only a real PULSE waveform gets the TRANinit fill (ngspice runs it
        // per PULSE function, not per source). Filling a DC/SIN/PWL source's
        // sentinels minted a phantom breakpoint at t = TSTEP (default TR)
        // whose landing cut dt to 0.1·saveDelta and desynced the step ladder
        // from ngspice's (digital/clamp). Pushing TD past any tstop parks
        // every timer corner where it can never fire — the pulse branch of
        // the .va only reads these fields when waveform == pulse.
        if (comptime @hasField(@TypeOf(target.*), "waveform")) {
            if (target.waveform != @intFromEnum(Wave.pulse)) {
                target.pulse_td = 1e30;
                return;
            }
        }
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
        try self.topoCheck();
    }

    fn addBucket(self: *NetBuilder, bkt: types.DeviceList.Bucket) !void {
        for (0..bkt.size()) |i| try self.addDevice(bkt.get(i));
    }

    // -- Topology diagnosis helpers ---------------------------------------

    fn topoEnsure(self: *NetBuilder, id: u32) !void {
        while (self.topo_seen.items.len <= id) {
            const next: u32 = @intCast(self.topo_uf.items.len);
            try self.topo_seen.append(self.arena, false);
            try self.topo_dc.append(self.arena, false);
            try self.topo_cur.append(self.arena, false);
            try self.topo_uf.append(self.arena, next);
            try self.topo_pot.append(self.arena, 0);
        }
    }

    /// Root and potential-to-root of `id0` in the weighted forest.
    fn topoRoot(self: *NetBuilder, id0: u32) struct { root: u32, pot: f64 } {
        var id = id0;
        var pot: f64 = 0;
        while (self.topo_uf.items[id] != id) {
            pot += self.topo_pot.items[id];
            id = self.topo_uf.items[id];
        }
        return .{ .root = id, .pot = pot };
    }

    /// Classify one card's nodes. `kind`: .dc marks a DC path, .cap marks
    /// presence only, .cur marks a current source, .short additionally
    /// unions the first two nodes as a DC short of value `vshort`
    /// (v(node0) − v(node1) = vshort) and rejects an INCONSISTENT cycle.
    fn topoMark(self: *NetBuilder, dev: types.Device, kind: enum { dc, cap, cur, short }, vshort: f64) !void {
        var first_two: [2]u32 = .{ GROUND, GROUND };
        for (dev.nodes, 0..) |name, i| {
            const id = try self.b.internNode(name);
            try self.topoEnsure(id);
            self.topo_seen.items[id] = true;
            switch (kind) {
                .cap => {},
                .cur => self.topo_cur.items[id] = true,
                .dc, .short => self.topo_dc.items[id] = true,
            }
            if (i < 2) first_two[i] = id;
        }
        if (kind == .short and dev.nodes.len >= 2) {
            const a = self.topoRoot(first_two[0]);
            const b_ = self.topoRoot(first_two[1]);
            if (a.root == b_.root) {
                const gap = (a.pot - b_.pot) - vshort;
                if (@abs(gap) > 1e-9 * @max(1.0, @abs(vshort))) {
                    std.log.err(
                        "topology: '{s}' closes an inconsistent voltage-source/inductor loop ({d} V of KVL violation)",
                        .{ dev.name, gap },
                    );
                    return error.VoltageSourceLoop;
                }
            } else {
                // Attach so every member's potential stays consistent:
                // v(b) = pot_b + topo_pot[rb] must equal v(a) − vshort.
                self.topo_uf.items[b_.root] = a.root;
                self.topo_pot.items[b_.root] = a.pot - vshort - b_.pot;
            }
        }
    }

    /// Current-source cutsets cannot satisfy static KCL. Capacitor-only nodes
    /// reach the operating-point transient fallback, as in ngspice OPtran.
    fn topoCheck(self: *NetBuilder) !void {
        for (self.topo_seen.items, 0..) |seen, id| {
            if (!seen or id == GROUND) continue;
            if (self.topo_dc.items[id]) continue;
            const label = self.b.node_labels.items[id];
            if (self.topo_cur.items[id]) {
                std.log.err("topology: node '{s}' is a current-source cutset — KCL has no DC path to satisfy it", .{label});
                return error.CurrentSourceCutset;
            }
            self.b.needs_tran_op = true;
        }
    }

    fn addDevice(self: *NetBuilder, dev_in: types.Device) !void {
        // Every card routes through here, including the ones that expand into
        // several instances (URC, CPL), so stamping the open card once is all
        // it takes for Builder.addDevice to attribute every instance it makes.
        self.b.card = dev_in.name;
        defer self.b.card = "";
        // Runtime-loaded Verilog-A/Verilog device instance: handled
        // by addDynDevices after NetBuilder runs, regardless of card letter.
        // Its nodes still get a DC mark — a foreign model is opaque, and an
        // unfounded topology error is worse than a missed one.
        if (isDynDevice(dev_in, self.nl.models)) {
            try self.topoMark(dev_in, .dc, 0);
            return;
        }
        const letter = dev_in.letter();
        // Q cards carry 3-5 nodes against the parser's fixed 3, M cards 3-7
        // against its fixed 4, so the model name lands on the wrong side of
        // the node/positional split in both directions. Normalize BEFORE
        // anything reads positionals — the guard below used to look up the
        // substrate node as a model and reject every 4T vbic/hicum instance,
        // and ate a 3-terminal VDMOS's model name as its bulk node.
        var norm: BjtNormBufs = undefined;
        const dev = if (letter == 'q' or letter == 'm') normalizeBjt(dev_in, self.nl.models, &norm) else dev_in;
        // 'u' (URC) has no DeviceId behind it: the card expands into
        // resistor/capacitor/diode lumps in addUrc, like ngspice's URCsetup.
        if (letter != 'u' and devices.letter_map.get(&.{letter}) == null) {
            if (try inferDeviceFromModel(dev, self.nl.models) == null)
                return error.UnsupportedDevice;
        }

        switch (letter) {
            'c' => try self.topoMark(dev, .cap, 0),
            'i' => try self.topoMark(dev, .cur, 0),
            // A V source shorts its pair at its DC value; an inductor at 0 V.
            'v' => try self.topoMark(dev, .short, sourceDc(dev) orelse 0),
            'l' => try self.topoMark(dev, .short, 0),
            else => try self.topoMark(dev, .dc, 0),
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
                if (comptime !@hasDecl(devices.vsource, "eval")) return error.UnsupportedDevice;
                const bound = try self.bindSource(devices.vsource, dev);
                const nodes = try deviceNodes(self.b, devices.vsource, dev);
                const br = self.b.n;
                // An F/H/W card SENSES this source's branch current, and the
                // 4-port model does that by carrying its own `branch (cp,cn)
                // ctrl` driven to `vsense`. Stamping the original alongside it
                // put two voltage sources across one node pair, so the current
                // divided between them — exactly `I/(1+N)` for N consumers,
                // which is why cccs/ccvs read 0.5 and cswitch never tripped.
                // The model header says it plainly: the netlist layer wires the
                // sense branch IN PLACE OF that source.
                const sensed = self.isSensedSource(dev.name);
                if (!sensed) try self.b.addDevice(devices.vsource, bound[0], bound[1], nodes);
                self.v_names[self.n_v] = dev.name;
                self.v_ports[self.n_v] = nodes[0];
                self.v_nports[self.n_v] = if (nodes.len > 1) nodes[1] else 0;
                self.v_branches[self.n_v] = br;
                self.v_dc[self.n_v] = bound[0].dc;
                self.v_sensed[self.n_v] = sensed;
                self.v_distof1[self.n_v] = sourceDistoF1(dev);
                const port = if (sensed) null else sourcePort(dev);
                self.v_portnum[self.n_v] = if (port) |p| p.num else 0;
                self.v_z0[self.n_v] = if (port) |p| p.z0 else 0;
                self.n_v += 1;
                // A replaced source stamps nothing, so it cannot be the
                // reference the .op ladder anchors on — nor can it be driven:
                // `br` is the row the NEXT card got, not one this source owns.
                if (!sensed) {
                    if (self.source_branch == GROUND) {
                        self.source_node = nodes[0];
                        self.source_branch = br;
                    }
                    if (sourceAc(dev)) |ac| self.addAcDrive(GROUND, br, ac.re, ac.im);
                }
            },
            'i' => {
                if (comptime !@hasDecl(devices.isource, "eval")) return error.UnsupportedDevice;
                const bound = try self.bindSource(devices.isource, dev);
                const nodes = try deviceNodes(self.b, devices.isource, dev);
                try self.b.addDevice(devices.isource, bound[0], bound[1], nodes);
                if (sourceAc(dev)) |ac| self.addAcDrive(nodes[0], nodes[1], ac.re, ac.im);
                self.i_names[self.n_i] = dev.name;
                self.n_i += 1;
            },
            'f', 'h', 'w', 'k' => {
                self.deferred[self.n_deferred] = .{ .dev = dev, .letter = letter };
                self.n_deferred += 1;
            },
            'b' => {
                const first = self.b.n;
                // Only the V-mode B gets a branch: ngspice guards its
                // `CKTmkCur` on `ASRCtype == ASRC_VOLTAGE` (asrcset.c:81-88),
                // so an `i=` B card has no branch unknown and no i() column.
                // espice's 4-port bsource declares the unknown either way; the
                // I-mode one is left unprobed rather than published as a
                // permanent zero ngspice never writes.
                if (try addBsource(self.b, dev, self.nl.models))
                    self.addBranchProbe(dev.name, internalRow(devices.bsource, "flowZ28pZ2cnZ29", first));
            },
            'p' => try self.addCpl(dev),
            'u' => try self.addUrc(dev),
            'e' => {
                const first = self.b.n;
                try self.addByLetter(letter, dev);
                self.addBranchProbe(dev.name, internalRow(devices.vcvs, "flowZ28pZ2cnZ29", first));
            },
            else => try self.addByLetter(letter, dev),
        }
    }

    /// URC (U card): `Uxxx n1 n2 ngnd model [l=len] [n=lumps]`. ngspice has no
    /// URC kernel either — URCsetup expands the card at setup into a ladder of
    /// ordinary R/C lumps (diodes when ISPERL is set), sized geometrically by
    /// K from both ends toward the middle so the totals telescope to exactly
    /// L*RPERL and L*CPERL. Same expansion here, at build time, into the
    /// existing resistor/capacitor/diode batches.
    fn addUrc(self: *NetBuilder, dev: types.Device) !void {
        // URC model params + defaults (urcsetup.c). A missing .model card is
        // legal in ngspice (default U model) — all defaults apply.
        var k: f64 = 1.5;
        var fmax: f64 = 1e9;
        var rperl: f64 = 1000;
        var cperl: f64 = 1e-12;
        var isperl: f64 = 0;
        var rsperl: f64 = 0;
        if (positionalName(dev, 0)) |name| {
            if (findModel(self.nl.models, name)) |m| {
                k = kvNumber(m.kv, "k") orelse k;
                fmax = kvNumber(m.kv, "fmax") orelse fmax;
                rperl = kvNumber(m.kv, "rperl") orelse rperl;
                cperl = kvNumber(m.kv, "cperl") orelse cperl;
                isperl = kvNumber(m.kv, "isperl") orelse isperl;
                rsperl = kvNumber(m.kv, "rsperl") orelse rsperl;
            }
        }
        // ngspice's URClength default is a calloc'd 0.0, which degenerates to
        // 0-ohm lumps; 1 m is the sane "unit line" a card without l= means.
        const len = kvNumber(dev.kv, "l") orelse 1.0;
        const p = k;
        const r0 = len * rperl;
        const c0 = len * cperl;
        const is0 = len * isperl;

        const lumps: u32 = if (try numericParameter(dev.kv, "n")) |nv|
            // clamp guards @intFromFloat UB on absurd cards; ngspice's own
            // comment says "may want to limit lumps to <= 100 or so".
            @intFromFloat(std.math.clamp(nv, 1, 1000))
        else blk: {
            // URCsetup: lump count from FMAX so the finest lump's pole clears
            // the highest frequency of interest.
            const wnorm = fmax * r0 * c0 * 2.0 * std.math.pi;
            const est = @log(wnorm * ((p - 1) / p) * ((p - 1) / p)) / @log(p);
            // `!(est > 3)` also catches the NaN/inf a K<=1 card produces
            // (@intFromFloat on those is UB; ngspice leaves that hole open).
            break :blk if (wnorm < 35 or !(est > 3)) 3 else @intFromFloat(@min(est, 1000));
        };
        const lumps_f: f64 = @floatFromInt(lumps);

        // Geometric sizing (urcsetup.c): lump i carries r1*K^(i-1), c1*K^(i-1).
        const r1 = r0 * (p - 1) / (2 * std.math.pow(f64, p, lumps_f) - 2);
        const c1 = c0 * (p - 1) / (std.math.pow(f64, p, lumps_f - 1) * (p + 1) - 2);
        const is1 = is0 * (p - 1) / (std.math.pow(f64, p, lumps_f - 1) * (p + 1) - 2);
        const rd = len * lumps_f * rsperl;

        const pos = if (dev.nodes.len > 0) try self.b.internNode(dev.nodes[0]) else GROUND;
        const neg = if (dev.nodes.len > 1) try self.b.internNode(dev.nodes[1]) else GROUND;
        const gnd = if (dev.nodes.len > 2) try self.b.internNode(dev.nodes[2]) else GROUND;

        // ngspice keys the diode form off "ISPERL given" — even ISPERL=0 —
        // turning every lump into an is=0 diode whose only effect is its
        // depletion capacitance. ISPERL > 0 is the intended trigger; the
        // linear capacitor IS the zero-current limit of that diode.
        const use_diodes = isperl > 0;
        var prop: f64 = 1; // K^(i-1)
        var lowl = pos; // low-side chain head (walks pos -> middle)
        var hir = neg; // high-side chain head (walks neg -> middle)
        for (1..lumps + 1) |i| {
            const last = i == lumps;
            const hil = try self.b.addNode();
            // The chains meet at the last hi node.
            const lowr = if (last) hil else try self.b.addNode();
            const r: f64 = prop * r1;
            try self.b.addDevice(devices.resistor, .{ .r = @floatCast(r) }, .{}, [2]u32{ lowl, lowr });
            try self.b.addDevice(devices.resistor, .{ .r = @floatCast(r) }, .{}, [2]u32{ hil, hir });
            if (use_diodes) {
                const Diode = devices.DeviceId.Type(.diode);
                if (comptime !@hasDecl(Diode, "eval")) return error.UnsupportedDevice;
                // ngspice shares one diode model (is=i1, cjo=c1, rs=rd) and
                // scales per lump with area=prop; diode.va has no area, so
                // the area scaling is folded into per-lump model values.
                var dm: Diode.Model = .{};
                dm.is = @floatCast(is1 * prop);
                dm.cjo = @floatCast(c1 * prop);
                dm.rs = @floatCast(rd / prop);
                try self.b.addDevice(Diode, dm, .{}, [2]u32{ lowr, gnd });
                if (!last) try self.b.addDevice(Diode, dm, .{}, [2]u32{ hil, gnd });
            } else {
                const cm: devices.capacitor.Model = .{ .c = @floatCast(prop * c1) };
                try self.b.addDevice(devices.capacitor, cm, .{}, [2]u32{ lowr, gnd });
                if (!last) try self.b.addDevice(devices.capacitor, cm, .{}, [2]u32{ hil, gnd });
            }
            prop *= p;
            lowl = lowr;
            hir = hil;
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
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        if (comptime !@hasField(D.Model, value_field) and !@hasField(D.Instance, value_field))
            @compileError(@typeName(D) ++ ": no parameter `" ++ value_field ++ "` on Model or Instance");
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        var value = positionalNumber(dev, 0) orelse kvNumber(dev.kv, value_field) orelse kvNumber(dev.kv, alias) orelse blk: {
            // Semiconductor resistor model card (ngspice restemp.c
            // RESupdate_conduct): R = RSH·(L−2·SHORT)/(W−2·NARROW), W
            // defaulting to the model's DEFW. A zero/negative effective
            // width is ngspice's silent divide — the device reads as open.
            if (comptime D == devices.resistor) {
                if (positionalName(dev, 0)) |mn| if (findModel(self.nl.models, mn)) |m| {
                    const rsh = kvNumber(m.kv, "rsh") orelse 0;
                    const l = kvNumber(dev.kv, "l") orelse 0;
                    const w = kvNumber(dev.kv, "w") orelse kvNumber(m.kv, "defw") orelse 10e-6;
                    if (l * w * rsh > 0) {
                        const narrow = kvNumber(m.kv, "narrow") orelse 0;
                        const rshort = kvNumber(m.kv, "short") orelse 0;
                        const rr = (l - 2 * rshort) / (w - 2 * narrow) * rsh;
                        break :blk if (std.math.isFinite(rr) and rr > 0) rr else 1e30;
                    }
                    if (kvNumber(m.kv, "r")) |mr| break :blk mr;
                };
            }
            break :blk 0;
        };
        // ngspice instance factors: conduct = m/(R·scale) — applies to the
        // explicit-value spelling too (`R5 6 0 10 scale=1K`, `R4 ... m=2`).
        if (comptime D == devices.resistor) {
            const scale = kvNumber(dev.kv, "scale") orelse 1;
            const mult = kvNumber(dev.kv, "m") orelse 1;
            value *= scale;
            value /= mult;
            // ngspice restemp.c: "resistance too low or not given, set to 1 mOhm"
            if (!(value > 0)) value = 1e-3;
            // `ac=` is an AC-ONLY resistance (restemp.c:112-118) and takes the
            // same instance factors as the DC one; the frequency-domain
            // linearization swaps it in (Circuit.linearizeAc).
            if (kvNumber(dev.kv, "ac")) |ac_r| {
                var ac_value = ac_r * scale / mult;
                if (!(ac_value > 0)) ac_value = 1e-3;
                self.ac_res_names[self.n_ac_res] = dev.name;
                self.ac_res_values[self.n_ac_res] = ac_value;
                self.n_ac_res += 1;
            }
        }
        _ = try setParam(D, &model, &instance, value_field, value);
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
        const dc = sourceDc(dev);
        _ = try setParam(D, &model, &instance, "dc", dc orelse 0);
        applySourceWaveform(&model, dev);
        applySourceWaveform(&instance, dev);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        self.resolvePulseDefaults(&model);
        self.resolvePulseDefaults(&instance);
        // ngspice: "the DC value of a source with a transient specification
        // but no DC value is the transient value at t = 0" — resolved at BIND
        // so the model's static branch reads `dc` unconditionally and a .dc
        // sweep's override WINS (rtlinv sweeps a PULSE source with no DC
        // card; the sweep used to be a no-op against the waveform).
        if (dc == null) {
            dcFromWaveform(&model);
            dcFromWaveform(&instance);
        }
        return .{ model, instance };
    }

    fn addByLetter(self: *NetBuilder, letter: u8, dev: types.Device) !void {
        // Q cards arrive already normalized (addDevice), so the model name is
        // positional[0] here for every terminal count.
        switch (try resolveDeviceId(letter, dev, self.nl.models)) {
            inline else => |comptime_id| {
                const D = devices.DeviceId.Type(comptime_id);
                try addSingleDevice(self.b, D, dev, self.nl.models);
            },
        }
    }

    fn resolveDeferred(self: *NetBuilder) !void {
        for (self.deferred[0..self.n_deferred]) |def| {
            self.b.card = def.dev.name;
            defer self.b.card = "";
            switch (def.letter) {
                'f' => try self.addBranchRef(devices.cccs, def.dev, 1.0),
                'h' => try self.addBranchRef(devices.ccvs, def.dev, 0.0),
                'w' => try self.addBranchRef(devices.cswitch, def.dev, null),
                'k' => try self.addKinduc(def.dev),
                else => unreachable,
            }
        }
    }

    /// Does any F/H/W card sense this V card? Runs during the 'v' bucket, so
    /// it reads the f/h/w buckets directly rather than any state built later.
    fn isSensedSource(self: *const NetBuilder, name: []const u8) bool {
        for ([_]u8{ 'f', 'h', 'w' }) |c| {
            const bkt = self.nl.devices.bucket(c);
            for (0..bkt.size()) |i| {
                const ref = positionalName(bkt.get(i), 0) orelse continue;
                if (std.ascii.eqlIgnoreCase(ref, name)) return true;
            }
        }
        return false;
    }

    /// The generated CPL model has exactly two conductors per port.
    fn addCpl(self: *NetBuilder, dev: types.Device) !void {
        if (dev.nodes.len != 6) return error.UnsupportedCoupledLineDimension;
        const D = devices.coupled_tlines;
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        var model: D.Model = .{};
        if (positionalName(dev, 0)) |name| {
            if (findModel(self.nl.models, name)) |m| applyCplKv(&model, m.kv);
        }
        applyCplKv(&model, dev.kv);
        try self.b.addDevice(D, model, .{}, try deviceNodes(self.b, D, dev));
    }

    fn addBranchRef(self: *NetBuilder, comptime D: type, dev: types.Device, comptime default_gain: ?f64) !void {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        const ctrl_name = positionalName(dev, 0) orelse return error.MissingControlSource;
        // ponytail: one O(n_v) name lookup for all control fields; index names if profiled.
        const ctrl = findNameIndex(self.v_names[0..self.n_v], ctrl_name) orelse return error.UnknownControlSource;

        var model: D.Model = .{};
        // W card: `W n+ n- Vctrl model` — model is positional[1] (positional[0]
        // is the control source). F/H put a number there, so the orelse falls
        // back to the plain model-name slot.
        if (positionalName(dev, 1) orelse positionalName(dev, 0)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        var instance: D.Instance = .{};
        if (comptime default_gain) |dflt|
            _ = try setParam(D, &model, &instance, "gain", positionalNumber(dev, 1) orelse kvNumber(dev.kv, "gain") orelse dflt);
        // The sensed source is not stamped (see the 'v' case); this model's
        // own `branch (cp,cn) ctrl` stands in for it, and `vsense` is what
        // keeps its voltage. Without this the replaced source read as 0 V.
        _ = try setParam(D, &model, &instance, "vsense", self.v_dc[ctrl]);
        try applyKv(&instance, dev.kv);

        // (p, n, cp, cn): the control port is the sensed source's own node
        // pair. The model puts a `branch (cp, cn) ctl` across it and reads
        // I(ctl), which IS the current through that source.
        const nodes = [4]u32{
            if (dev.nodes.len > 0) try self.b.internNode(dev.nodes[0]) else GROUND,
            if (dev.nodes.len > 1) try self.b.internNode(dev.nodes[1]) else GROUND,
            self.v_ports[ctrl],
            self.v_nports[ctrl],
        };
        const first = self.b.n;
        try self.b.addDevice(D, model, instance, nodes);

        // The sensed V card's branch row was recorded as `self.b.n` taken
        // before an addDevice that never ran (see the 'v' case), so it pointed
        // at whatever row the NEXT card got. Its current lives HERE, on this
        // model's `ctrl`/`sense` branch — the one standing in for the source —
        // which is why `i(vam)` came out missing while `i(vzero)` on the same
        // unreferenced card came out fine. ngspice keeps the source's own
        // CKTmkCur row and emits i(vam) either way (cccsset.c:47 looks the
        // branch up rather than replacing it).
        self.v_branches[ctrl] = internalRow(D, "flowZ28cpZ2ccnZ29", first);
        // H also carries its own output branch, and ngspice names it i(h1).
        if (comptime @hasDecl(D, "U") and D == devices.ccvs)
            self.addBranchProbe(dev.name, internalRow(D, "flowZ28pZ2cnZ29", first));
    }

    fn addKinduc(self: *NetBuilder, dev: types.Device) !void {
        if (comptime !@hasDecl(devices.kinduc, "eval")) return error.UnsupportedDevice;
        const l1_name = positionalName(dev, 0) orelse return error.KinducMissingInductor;
        const l2_name = positionalName(dev, 1) orelse return error.KinducMissingInductor;
        const li1 = findNameIndex(self.l_names[0..self.n_l], l1_name) orelse return error.KinducUnknownInductor;
        const li2 = findNameIndex(self.l_names[0..self.n_l], l2_name) orelse return error.KinducUnknownInductor;
        const ibr1 = self.l_branches[li1];
        const ibr2 = self.l_branches[li2];
        var model: devices.kinduc.Model = .{};
        if (positionalNumber(dev, 2)) |k| model.k = try castField(f32, k);
        if (positionalName(dev, 0)) |name| {
            if (findModel(self.nl.models, name)) |m| try applyKv(&model, m.kv);
        }
        try applyKv(&model, dev.kv);
        // K card carries the coupling coefficient k; the device stamps mutual
        // inductance M = k*sqrt(L1*L2) (ngspice INDsetup).
        model.k = try castField(f32, @as(f64, model.k) *
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

fn resolveDeviceId(letter: u8, dev: types.Device, spice_models: []const types.Model) !devices.DeviceId {
    const level = try modelLevel(dev, spice_models);
    return switch (letter) {
        // `.model X VDMOS(...)` carries no LEVEL — the model KIND is the
        // dispatch (ngspice inpdomod.c does the same for VDMOS).
        'm' => blk: {
            if (positionalName(dev, 0)) |name| if (findModel(spice_models, name)) |mm| {
                if (std.ascii.eqlIgnoreCase(mm.kind, "vdmos")) break :blk .vdmos;
            };
            break :blk try devices.mosfetDeviceId(level);
        },
        'q' => try devices.bjtDeviceId(level),
        'd' => try devices.diodeDeviceId(level),
        'j' => try devices.jfetDeviceId(level),
        'z' => try devices.mesDeviceId(level),
        else => devices.letter_map.get(&.{letter}) orelse
            (try inferDeviceFromModel(dev, spice_models)) orelse error.UnsupportedDevice,
    };
}

fn inferDeviceFromModel(dev: types.Device, spice_models: []const types.Model) !?devices.DeviceId {
    const name = positionalName(dev, 0) orelse return null;
    const m = findModel(spice_models, name) orelse return null;
    const level = try numericParameter(m.kv, "level");
    const l = if (level) |lv| try castField(u16, lv) else 1;
    if (std.ascii.eqlIgnoreCase(m.kind, "vdmos"))
        return .vdmos;
    if (eqlAny(m.kind, &.{ "nmos", "pmos" }))
        return devices.mosfetDeviceId(l) catch null;
    if (eqlAny(m.kind, &.{ "npn", "pnp" }))
        return devices.bjtDeviceId(l) catch null;
    if (std.ascii.eqlIgnoreCase(m.kind, "d"))
        return devices.diodeDeviceId(l) catch null;
    if (eqlAny(m.kind, &.{ "njf", "pjf" }))
        return devices.jfetDeviceId(l) catch null;
    if (eqlAny(m.kind, &.{ "nmf", "pmf", "nhfet", "phfet" }))
        return devices.mesDeviceId(l) catch null;
    return null;
}

fn eqlAny(a: []const u8, candidates: []const []const u8) bool {
    for (candidates) |c| if (std.ascii.eqlIgnoreCase(a, c)) return true;
    return false;
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
        markGiven(model, "typeZ"); // bsim4va: `if (!$param_given(type)) type = NMOS`
    } else if (comptime @hasField(D.Model, "typeZ5f")) {
        model.typeZ5f = -1; // bsim2 declares `type_`
        markGiven(model, "typeZ5f");
    } else if (comptime @hasField(D.Model, "dev_type")) {
        model.dev_type = -1; // mos3
        markGiven(model, "dev_type");
    } else if (comptime @hasField(D.Model, "mtype")) {
        model.mtype = -1; // mos6/mos9 spell polarity `mtype`
        markGiven(model, "mtype");
    } else if (comptime @hasField(D.Model, "TYPE")) {
        model.TYPE = -1; // bsimsoi/hisim2/hisimhv: `TYPE` +1=NMOS, -1=PMOS
        markGiven(model, "TYPE");
    } else {
        // ponytail: jfet/jfet2/mes/mesa/vdmos have no polarity
        // parameter at ALL, so a P-type card on them cannot be honoured.
        // Refusing is the point: running it N-type is what produced silent NaN.
        // Upgrade path is model-side — give the .va a `type` parameter the way
        // mos1 has one — not another branch here.
        return error.UnsupportedDevice;
    }
}

/// VerA's reserved Model field for §9.15 `$simparam("tnom")` — the circuit's
/// nominal temperature in degC. See `Lower.simparamHostField`.
pub const nom_temp_field = "nom_temp__";

/// §6.3.4/§3.4.5 `derive`, through the device's own object when it has one.
/// Same function either way — calling `D.derive` directly would codegen the
/// generated body (bsim4's runs to thousands of lines) a second time, inside
/// the executable, for every model.
///
/// `.options tnom` is published here, immediately before `derive`, because
/// that is where the two halves meet: VerA turns a `parameter real tnom =
/// $simparam("tnom")` into `if (!model.tnom__given) model.tnom =
/// model.nom_temp__`, which is ngspice's `if (!BSIM4tnomGiven) BSIM4tnom =
/// ckt->CKTnomTemp` (b4set.c:1950). Writing it before the card would let
/// `derive` overwrite it; after `derive`, nothing would read it. A card
/// `TNOM`/`TREF` raised `__given` in `applyKv`, so it still wins.
fn deriveModel(comptime D: type, model: *D.Model, nom_temp_c: f64) void {
    if (comptime @hasField(D.Model, nom_temp_field))
        @field(model, nom_temp_field) = nom_temp_c;
    if (comptime devices.modelName(D)) |name| {
        if (devices.vtable(name).derive) |f| f(@ptrCast(model));
    } else if (comptime @hasDecl(D, "derive")) D.derive(model);
}

fn addSingleDevice(b: *Builder, comptime D: type, dev: types.Device, spice_models: []const types.Model) !void {
    if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
    var model: D.Model = .{};
    var instance: D.Instance = .{};
    if (positionalName(dev, 0)) |name| {
        if (findModel(spice_models, name)) |m| {
            try applyKv(&model, m.kv);
            // TXL (y-card) model cards spell the line length `length=`;
            // the lossy_tline field is `len`.
            if (comptime D == devices.lossy_tline) {
                if (kvNumber(m.kv, "length")) |length| model.len = @floatCast(length);
            }
            // Polarity comes from the model card kind, outside applyKv.
            if (eqlAny(m.kind, &.{ "pmos", "pnp", "pjf", "pmf", "phfet" })) try setPolarity(D, &model);
        }
    }
    _ = try setParam(D, &model, &instance, "gain", positionalNumber(dev, 0) orelse 0);
    // Device-card `name=value` goes to BOTH structs, because which one holds a
    // given parameter is VerA's choice, not a semantic distinction: it puts
    // every Verilog-A `parameter` on Model, and mos1's Instance has no user
    // fields at all. Routing the card only to Instance therefore dropped
    // per-instance geometry outright — `M1 d g s b NMOS W=10u L=1u` produced
    // byte-identical output for W=1u, W=10u and W=100u.
    //
    // This was gated on `positionalName(dev, 0) == null` for the model-less form
    // (`T1 a 0 b 0 Z0=50 TD=2n`); that case is now just the one where there
    // was no model card to override in the first place.
    //
    // Overriding Model per card is not shared state: `model` is a fresh
    // `D.Model` per device and `addDevice` appends its own copy, so one
    // instance's W/L cannot reach another. Order is model card, then device
    // card — SPICE precedence.
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);
    // §6.3.4/§3.4.5: recompute parameters declared over other parameters
    // (BSIMSOI `TOXM = TOX`, tline `td = nl/f`) and localparams, now that the
    // last card value is written. Guarded per-field on `__given` inside, so an
    // explicit card value always wins. The dlopen path (vt.derive) already
    // did this; the comptime path silently never did.
    deriveModel(D, &model, b.nom_temp_c);
    try b.addDevice(D, model, instance, try deviceNodes(b, D, dev));
}

// ---------------------------------------------------------------------------
// B-source expression extraction
// ---------------------------------------------------------------------------

/// Returns true when the card is a VOLTAGE-mode B — the only kind that owns a
/// branch-current unknown worth probing (ngspice asrcset.c:81-88).
fn addBsource(b: *Builder, dev: types.Device, spice_models: []const types.Model) !bool {
    if (comptime !@hasDecl(devices.bsource, "eval")) return error.UnsupportedDevice;
    var model: devices.bsource.Model = .{};
    var instance: devices.bsource.Instance = .{};
    if (positionalName(dev, 0)) |name| {
        if (findModel(spice_models, name)) |m| try applyKv(&model, m.kv);
    }
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);

    var ctrl_probe: ?Probe = null;
    const modes = std.StaticStringMap(u1).initComptime(.{ .{ "v", 0 }, .{ "i", 1 } });
    for (dev.kv) |item| {
        model.imode = modes.get(item.key) orelse continue;
        switch (item.value) {
            .num => |value| model.c0 = try castField(@TypeOf(model.c0), value),
            .expr => |expr| {
                ctrl_probe = extractVoltageProbe(expr);
                extractPolyCoeffs(expr, &model);
            },
            else => return error.UnresolvedParameter,
        }
    }

    const nodes = [4]u32{
        if (dev.nodes.len > 0) try b.internNode(dev.nodes[0]) else GROUND,
        if (dev.nodes.len > 1) try b.internNode(dev.nodes[1]) else GROUND,
        if (ctrl_probe) |pr| try b.internNode(pr.p) else GROUND,
        if (ctrl_probe) |pr| (if (pr.n) |n| try b.internNode(n) else GROUND) else GROUND,
    };
    try b.addDevice(devices.bsource, model, instance, nodes);
    return model.imode == 0;
}

/// The first V() probe in the expression: V(p) or differential V(p,n).
/// The poly model assumes every probe names the same pair (§1.6 ceiling).
const Probe = struct { p: []const u8, n: ?[]const u8 };

fn extractVoltageProbe(expr: *const types.Expr) ?Probe {
    switch (expr.*) {
        .call => |c| {
            if (std.mem.eql(u8, c.name, "v") and c.args.len >= 1) {
                const p = switch (c.args[0].*) {
                    .ident => |id| id,
                    else => return null,
                };
                const n: ?[]const u8 = if (c.args.len >= 2) switch (c.args[1].*) {
                    .ident => |id| id,
                    else => null,
                } else null;
                return .{ .p = p, .n = n };
            }
            for (c.args) |arg| if (extractVoltageProbe(arg)) |pr| return pr;
            return null;
        },
        .binop => |b| return extractVoltageProbe(b.a) orelse extractVoltageProbe(b.b),
        .unop => |u| return extractVoltageProbe(u.a),
        .num, .ident => return null,
    }
}

fn extractPolyCoeffs(expr: *const types.Expr, model: *devices.bsource.Model) void {
    var c: [3]f64 = .{ 0, 0, 0 };
    if (!collectTerms(expr, 1.0, &c)) return;
    // A single multiplicative tanh(k*vc) factor rides along as model.th
    // (the MESFET "ungated load" idiom, Is*tanh(v/Is/R)*(1+lambda*v)).
    // collectTerms treated it as the constant 1, so it must be a factor of
    // the whole expression, exactly once, with a linear argument — anything
    // else stays outside the subset (all-zero coeffs = open circuit).
    const n_tanh = countTanh(expr);
    if (n_tanh > 1) return;
    if (n_tanh == 1) {
        const arg = tanhFactorArg(expr) orelse return;
        if ((vDegree(arg) orelse return) != 1) return;
        model.th = @floatCast(numericCoeff(arg));
    }
    model.c0 = @floatCast(c[0]);
    model.c1 = @floatCast(c[1]);
    model.c2 = @floatCast(c[2]);
}

fn countTanh(expr: *const types.Expr) u32 {
    switch (expr.*) {
        .call => |c| {
            var n: u32 = if (std.mem.eql(u8, c.name, "tanh")) 1 else 0;
            for (c.args) |arg| n += countTanh(arg);
            return n;
        },
        .binop => |b| return countTanh(b.a) + countTanh(b.b),
        .unop => |u| return countTanh(u.a),
        .num, .ident => return 0,
    }
}

/// The argument of a tanh() that is a multiplicative factor of the whole
/// expression: descend only through products, constant divisors and unary
/// signs. null if the (sole) tanh sits anywhere else, e.g. additively.
fn tanhFactorArg(expr: *const types.Expr) ?*const types.Expr {
    switch (expr.*) {
        .call => |c| return if (std.mem.eql(u8, c.name, "tanh") and c.args.len == 1) c.args[0] else null,
        .binop => |b| return switch (b.op) {
            '*' => tanhFactorArg(b.a) orelse tanhFactorArg(b.b),
            '/' => tanhFactorArg(b.a),
            else => null,
        },
        .unop => |u| return tanhFactorArg(u.a),
        .num, .ident => return null,
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
            if (std.mem.eql(u8, call.name, "tanh")) {
                // Placeholder constant 1; extractPolyCoeffs pulls the factor
                // out into model.th and rejects non-multiplicative tanh.
                c[0] += scale;
                return true;
            }
            return false;
        },
        .binop => |b| switch (b.op) {
            '+' => return collectTerms(b.a, scale, c) and collectTerms(b.b, scale, c),
            '-' => return collectTerms(b.a, scale, c) and collectTerms(b.b, -scale, c),
            '*' => {
                if (vDegree(b.a)) |da| {
                    if (vDegree(b.b)) |db| {
                        if (da + db > 2) return false;
                        c[da + db] += scale * numericCoeff(b.a) * numericCoeff(b.b);
                        return true;
                    }
                    // constant factor times a non-monomial: distribute
                    if (da == 0) return collectTerms(b.b, scale * numericCoeff(b.a), c);
                } else if (vDegree(b.b)) |db| {
                    if (db == 0) return collectTerms(b.a, scale * numericCoeff(b.b), c);
                }
                return false;
            },
            '/' => {
                const db = vDegree(b.b) orelse return false;
                if (db != 0) return false;
                return collectTerms(b.a, scale / numericCoeff(b.b), c);
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
        // tanh factors count as degree-0 (extracted separately into th)
        .call => |c| return if (std.mem.eql(u8, c.name, "v"))
            1
        else if (std.mem.eql(u8, c.name, "tanh"))
            0
        else
            null,
        .binop => |b| {
            const da = vDegree(b.a) orelse return null;
            const db = vDegree(b.b) orelse return null;
            switch (b.op) {
                '*' => return da + db,
                '/' => return if (db == 0) da else null,
                else => return null,
            }
        },
        .unop => |u| return if (u.op == '-' or u.op == '+') vDegree(u.a) else null,
        .ident => return null,
    }
}

fn numericCoeff(expr: *const types.Expr) f64 {
    switch (expr.*) {
        .num => |n| return n,
        .call => return 1.0,
        .binop => |b| return switch (b.op) {
            '*' => numericCoeff(b.a) * numericCoeff(b.b),
            '/' => numericCoeff(b.a) / numericCoeff(b.b),
            else => 1.0,
        },
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
    var i: usize = 0;
    while (i < dev.positional.len) : (i += 1) {
        switch (dev.positional[i]) {
            .group => |group| {
                var buf: [8]u8 = undefined;
                if (group.name.len > buf.len) continue;
                const kind = wave_map.get(std.ascii.lowerString(&buf, group.name)) orelse continue;
                applyWaveArgs(T, target, kind, group.args);
            },
            // Parenless spelling (`vs a 0 dc=0 sin 0 50 100k`): the keyword is
            // a bare positional name and its args are the numeric positionals
            // that follow. Same table as the group form.
            .name => |nm| {
                var buf: [8]u8 = undefined;
                if (nm.len > buf.len) continue;
                const kind = wave_map.get(std.ascii.lowerString(&buf, nm)) orelse continue;
                const start = i + 1;
                var end = start;
                while (end < dev.positional.len and dev.positional[end] == .num) end += 1;
                applyWaveArgs(T, target, kind, dev.positional[start..end]);
                i = end - 1;
            },
            else => {},
        }
    }
}

fn applyWaveArgs(comptime T: type, target: anytype, kind: Wave, args: []const types.Value) void {
    target.waveform = @intFromEnum(kind);
    switch (kind) {
        // `PWL(T1 V1 T2 V2 ...)`: (time, value) pairs into the flattened
        // table. Non-numeric args (ngspice's `r=` / `td=` suffixes) leave
        // their slot at the default; those two are card kv and land through
        // applyKv on `pwl_repeat` / `pwl_td`.
        .pwl => if (comptime @hasField(T, pwlSlot("pwl_times", 0))) {
            const n_pts = @min(args.len / 2, comptime pwlCapacity(T));
            inline for (0..comptime pwlCapacity(T)) |k| {
                if (k < n_pts) {
                    if (valueNumber(args[2 * k])) |t|
                        @field(target.*, pwlSlot("pwl_times", k)) = @floatCast(t);
                    if (valueNumber(args[2 * k + 1])) |v|
                        @field(target.*, pwlSlot("pwl_values", k)) = @floatCast(v);
                }
            }
            target.pwl_len = @intCast(n_pts);
        },
        inline else => |cw| applyGroupArgs(T, target, args, comptime fieldPairs(cw)),
    }
}

/// The waveform's t = 0 value, per shape (each pre-TD branch of
/// vsource.va/isource.va): PULSE/EXP hold their first level, SIN emits
/// VO + VA*sin(2*pi*phase/360), PWL holds its first point, SFFM its offset,
/// AM starts at 0 (the `dc` default already).
fn dcFromWaveform(target: anytype) void {
    const T = @TypeOf(target.*);
    if (comptime !@hasField(T, "waveform") or !@hasField(T, "dc")) return;
    const rd = struct {
        fn f(t: anytype, comptime a: []const u8, comptime b: []const u8) f64 {
            if (comptime @hasField(T, a)) return @field(t, a);
            if (comptime @hasField(T, b)) return @field(t, b);
            return 0;
        }
    }.f;
    const v: f64 = switch (target.waveform) {
        1 => rd(target.*, "pulse_v1", "pulse_i1"),
        2 => rd(target.*, "sin_vo", "sin_ioff") +
            rd(target.*, "sin_va", "sin_iamp") *
                @sin(2.0 * std.math.pi * rd(target.*, "sin_phase", "sin_phase") / 360.0),
        3 => rd(target.*, "exp_v1", "exp_i1"),
        4 => rd(target.*, pwlSlot("pwl_values", 0), pwlSlot("pwl_values", 0)),
        5 => rd(target.*, "sffm_vo", "sffm_io"),
        else => return,
    };
    target.dc = @floatCast(v);
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

fn modelLevel(dev: types.Device, spice_models: []const types.Model) !u16 {
    if (positionalName(dev, 0)) |name| {
        if (findModel(spice_models, name)) |m| {
            if (try numericParameter(m.kv, "level")) |l| return try castField(u16, l);
        }
    }
    return 1;
}

/// Row `Builder.addDevice` allocated for D's internal unknown `tag`, given the
/// first internal row (`b.n` sampled before the call — addDevice walks U past
/// num_ports allocating one row each, in declaration order).
///
/// VerA mangles a Verilog-A `branch (a, b)` into the U member
/// `flowZ28aZ2cbZ29` (`(` = Z28, `,` = Z2c, `)` = Z29). Naming the member here
/// rather than hardcoding `first + 1` makes a wrong branch a COMPILE error
/// instead of a silently mislabelled current column — ccvs declares two
/// branches and the sense one comes first.
fn internalRow(comptime D: type, comptime tag: []const u8, first: u32) u32 {
    const off = comptime blk: {
        for (@typeInfo(D.U).@"enum".fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, tag)) {
                if (i < D.num_ports) @compileError(@typeName(D) ++ ": `" ++ tag ++ "` is a port, not an internal unknown");
                break :blk i - D.num_ports;
            }
        }
        @compileError(@typeName(D) ++ ": no unknown named `" ++ tag ++ "`");
    };
    return first + @as(u32, @intCast(off));
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

fn sourceDc(dev: types.Device) ?f64 {
    if (kvNumber(dev.kv, "dc")) |dc| return dc;
    // numbers owed to a preceding AC/DISTOF keyword (mag [phase])
    var skip: usize = 0;
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
            } else if (std.mem.eql(u8, name, "ac") or
                std.mem.eql(u8, name, "distof1") or std.mem.eql(u8, name, "distof2"))
            {
                // "AC mag [phase]" / "DISTOF1 mag [phase]": not the DC value.
                skip = 2;
            }
        },
        else => {},
    };
    return null;
}

/// The `AC` spec of a source card, as the complex excitation it becomes:
/// `mag · e^{j·phase·π/180}`. Null when the card names no `AC` — that source
/// is NOT driven by an .ac run (ngspice `vsrcacld.c:171` / `isrcacld.c:36`).
///
/// Defaults follow ngspice `vsrcpar.c:59-72` (which numbers were given) plus
/// `vsrctemp.c:38-43` (what a missing one becomes): bare `AC` is mag 1 phase 0,
/// `AC mag` is phase 0, `AC mag phase` is both. Phase is DEGREES —
/// `vsrctemp.c:68` is `radians = acPhase * M_PI / 180.0`.
/// `VP1 in 0 DC 0 AC 1 portnum 1 z0 50` — the RF-port spelling of a V card.
/// ngspice `vsrctemp.c:74-82`: a V source is a port when `portnum` is GIVEN;
/// `z0` then defaults to 50, and the card counts as a port only while
/// `z0 > 0 && portnum > 0`. Both spellings are accepted — `portnum 1` (the
/// positional pair every ngspice IOP is written as on a card) and `portnum=1`.
fn sourcePort(dev: types.Device) ?struct { num: u16, z0: f64 } {
    const num_f = blk: {
        if (kvNumber(dev.kv, "portnum")) |v| break :blk v;
        for (dev.positional, 0..) |pos, idx| {
            if (pos != .name or !std.mem.eql(u8, pos.name, "portnum")) continue;
            break :blk positionalNumber(dev, idx + 1) orelse return null;
        }
        return null;
    };
    const z0 = blk: {
        if (kvNumber(dev.kv, "z0")) |v| break :blk v;
        for (dev.positional, 0..) |pos, idx| {
            if (pos != .name or !std.mem.eql(u8, pos.name, "z0")) continue;
            break :blk positionalNumber(dev, idx + 1) orelse 50.0;
        }
        break :blk 50.0;
    };
    if (!(num_f >= 1) or !(z0 > 0) or num_f > 1024) return null;
    return .{ .num = @intFromFloat(num_f), .z0 = z0 };
}

fn sourceAc(dev: types.Device) ?struct { re: f64, im: f64 } {
    var mag: f64 = 1;
    var phase: f64 = 0;
    var given = false;
    for (dev.positional, 0..) |pos, idx| {
        switch (pos) {
            // `AC 1 SIN 0 1 1k`: positionalNumber returns null on the next
            // keyword, so the trailing waveform never reads as a phase.
            .name => |name| {
                if (!std.mem.eql(u8, name, "ac")) continue;
                if (positionalNumber(dev, idx + 1)) |m| {
                    mag = m;
                    if (positionalNumber(dev, idx + 2)) |p| phase = p;
                }
            },
            .group => |group| {
                if (!std.mem.eql(u8, group.name, "ac")) continue;
                if (group.args.len > 0) mag = valueNumber(group.args[0]) orelse mag;
                if (group.args.len > 1) phase = valueNumber(group.args[1]) orelse phase;
            },
            else => continue,
        }
        given = true;
        break;
    }
    if (!given) return null;
    const rad = phase * (std.math.pi / 180.0);
    return .{ .re = mag * @cos(rad), .im = mag * @sin(rad) };
}

/// `DISTOF1 [mag [phase]]` on a source card, ngspice vsrcpar.c:180-193: the
/// bare keyword is mag 1 / phase 0, one number sets the magnitude, two set
/// both. `{0, 0}` = the card never named it — no F1 drive, ngspice's own
/// `VSRCdF1given` false.
fn sourceDistoF1(dev: types.Device) [2]f64 {
    if (kvNumber(dev.kv, "distof1")) |mag| return .{ mag, 0 };
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .name => |name| if (std.mem.eql(u8, name, "distof1")) return .{
            positionalNumber(dev, idx + 1) orelse 1.0,
            positionalNumber(dev, idx + 2) orelse 0.0,
        },
        else => {},
    };
    return .{ 0, 0 };
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
    // DEFICIT direction first: a card with FEWER terminals than the parser's
    // fixed count ate the model name as its last node (`M1 d g 0 VMOD` on the
    // 4-node M slot). Shift it back to positional[0].
    if (dev.nodes.len > 0 and (dev.positional.len == 0 or switch (dev.positional[0]) {
        .name => |n| findModel(spice_models, n) == null,
        else => true,
    })) {
        const last = dev.nodes[dev.nodes.len - 1];
        if (findModel(spice_models, last) != null) {
            var out = dev;
            out.nodes = dev.nodes[0 .. dev.nodes.len - 1];
            bufs.pos[0] = .{ .name = last };
            const tail_len = @min(dev.positional.len, bufs.pos.len - 1);
            @memcpy(bufs.pos[1 .. 1 + tail_len], dev.positional[0..tail_len]);
            out.positional = bufs.pos[0 .. 1 + tail_len];
            return out;
        }
    }
    // SURPLUS direction: extra terminals spilled into positional and hide the
    // model name. Locate it among the positionals.
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

    var out = dev;
    out.nodes = bufs.nodes[0..n_nodes];
    out.positional = tail;
    return out;
}

pub fn valueNumber(value: types.Value) ?f64 {
    return switch (value) {
        .num => |n| n,
        else => null,
    };
}

/// A recognized numeric field cannot silently fall back to a model default.
fn numericParameter(kv: []const types.Kv, key: []const u8) !?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) {
        const value = valueNumber(item.value) orelse return error.UnresolvedParameter;
        if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        return value;
    };
    return null;
}

fn applyKv(target: anytype, kv: []const types.Kv) !void {
    const T = @TypeOf(target.*);
    // BSIMSOI's Model has ~1600 fields and each now runs a comptime
    // char-lowering loop on top of the aliasesOf scan.
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime isScalarAssignable(field.type)) {
            // The whole netlist is lowercased at parse (parser.zig toLowerBuf),
            // but VA models keep their spec spelling — BSIMSOI/HiSIM declare
            // `VTH0`, `TOX`, `W` in caps. Exact-name lookup dropped EVERY such
            // parameter silently (b4soi ran 100% baked defaults). Match on the
            // comptime-lowercased field name instead; keys are already lower.
            const key = comptime blk: {
                var buf: [field.name.len]u8 = undefined;
                for (field.name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const frozen = buf;
                break :blk frozen;
            };
            if (try numericParameter(kv, &key)) |num| {
                @field(target.*, field.name) = try castField(field.type, num);
                markGiven(target, field.name);
            } else {
                // ngspice IOPR alternate spellings: vt0|vto, vaf|va, var|vb,
                // ikf|ik, cjs|ccs (bjt.c iopr table), cjo|cj0|cj (dio.c).
                inline for (comptime aliasesOf(field.name)) |alias| {
                    if (try numericParameter(kv, alias)) |num| {
                        @field(target.*, field.name) = try castField(field.type, num);
                        markGiven(target, field.name);
                    }
                }
            }
        }
    }
}

/// §9.19 `$param_given`: VerA emits a `<name>__given: bool = false` companion
/// for every parameter the model queries. Binding a card value without raising
/// the flag leaves the model in its "defaulted" branch — bsim3's b3temp-style
/// derived defaults (k1/k2/vth0/vfb interdependence) mis-fire, and mos1's
/// NSUB-driven overrides never ran. No-op for fields without a companion.
fn markGiven(target: anytype, comptime field: []const u8) void {
    const T = @TypeOf(target.*);
    if (comptime @hasField(T, field ++ "__given"))
        @field(target.*, field ++ "__given") = true;
}

fn isScalarAssignable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float, .int, .bool => true,
        else => false,
    };
}

fn castField(comptime T: type, value: f64) !T {
    if (!std.math.isFinite(value)) return error.NonFiniteParameter;
    return switch (@typeInfo(T)) {
        .float => blk: {
            const converted: T = @floatCast(value);
            if (!std.math.isFinite(converted)) return error.ParameterOutOfRange;
            break :blk converted;
        },
        .int => |info| blk: {
            // An exclusive power-of-two bound stays exact when maxInt(i64)
            // would round upward in f64.
            const upper: f64 = comptime std.math.pow(f64, 2, info.bits - @intFromBool(info.signedness == .signed));
            const lower: f64 = if (info.signedness == .signed) -upper else 0;
            const truncated = @trunc(value);
            if (truncated != value or truncated < lower or truncated >= upper) return error.ParameterOutOfRange;
            break :blk @intFromFloat(value);
        },
        .bool => value != 0,
        else => @compileError("unsupported numeric field type"),
    };
}

// Private implementation access for the frontend test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .applySourceWaveform = applySourceWaveform,
    .pwlSlot = pwlSlot,
    .pwlCapacity = pwlCapacity,
    .Wave = Wave,
    .castField = castField,
    .applyKvDyn = applyKvDyn,
} else {};
