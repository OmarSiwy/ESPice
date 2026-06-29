//! Netlist hypergraph to frozen `device.Circuit`.
//! `NetBuilder` maps nets to rows and turns each card into device instances;
//! `Builder` accumulates them per `device.Library` type, computes the BBD
//! node permutation and freezes the pattern.

const std = @import("std");
const core = @import("core");
const z = @import("stdpp");
const requests = core.query;
const numerics = @import("core").numerics;
const devices = @import("spice.zig");
const device = @import("device");
/// SPICE letter/LEVEL dispatch, re-exported for the frontend tests.
pub const spice = devices;
const netlist = @import("netlist");
const Netlist = netlist.Netlist;
const Device = Netlist.View;
const Model = netlist.Model;
const Kv = netlist.Kv;
const Value = netlist.Value;
const Op = netlist.expr.Op;
const batch = device.abi;
const Library = device.Library;
const DeviceType = batch.DeviceType;
const castField = batch.bind.castField;
const markGiven = batch.bind.markGiven;

const GROUND = @as(u32, 0);
const Circuit = device.Circuit;
const Proto = batch.Proto;

/// `node_instance` tag of a node shared by two subcircuit instances.
const MULTI_INSTANCE: u32 = std.math.maxInt(u32);

/// Mutable circuit under construction: rows, device protos and card
/// identities. `compilePerm` consumes it into a `Circuit`.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    lib: *const Library,
    /// Row count, ground included.
    n: u32,
    /// Per row, the net name it came from ("" for internal unknowns).
    /// Borrowed: copied into the circuit's intern table at the freeze.
    node_labels: std.ArrayList([]const u8),
    /// One proto (future batch) per device type, in first-use order.
    protos: std.ArrayList(Proto),
    /// Library type of each proto, parallel to `protos`.
    proto_types: std.ArrayList(DeviceType) = .empty,
    /// Per-row subcircuit instance: 0 is top level, MULTI_INSTANCE a
    /// coupling node. Empty when the deck has no subcircuits.
    node_instance: std.ArrayList(u32) = .empty,
    /// Some node has no DC path, so the operating point needs the transient fallback.
    needs_tran_op: bool = false,
    /// `.options tnom` in degrees Celsius, ngspice's `CKTnomTemp`
    /// (cktsopt.c:71-73, default 27 degC from cktntask.c:127): the temperature
    /// a model card without its own TNOM/TREF was extracted at. `deriveModel`
    /// copies it into the models that read it.
    nom_temp_c: f64 = 27.0,
    /// `.options reltol/abstol/vntol`, for §9.15 `$simparam` in models;
    /// `deriveModel` copies them like `nom_temp_c`.
    reltol: f64 = 1e-3,
    abstol: f64 = 1e-12,
    vntol: f64 = 1e-6,

    /// (device type, instance ordinal) to card name, for `.sens` columns: a
    /// `ParamRef` only knows its ordinal (`resistor#0`). Names borrow the
    /// parse arena; copy them before it dies.
    cards: std.ArrayList(requests.CardRef) = .empty,
    /// Per-device-type instance count, the ordinal `ParamRef.index` carries.
    /// Counted here because a generated device's store lives behind its
    /// vtable. Every add counts, card or not, so it stays in step with the store.
    card_counts: std.ArrayList(u32) = .empty,

    /// An empty circuit with only the ground row. `lib` must outlive the Builder.
    pub fn init(gpa: std.mem.Allocator, lib: *const Library) !Builder {
        var labels: std.ArrayList([]const u8) = .empty;
        try labels.append(gpa, "0");
        return .{
            .gpa = gpa,
            .lib = lib,
            .n = 1,
            .node_labels = labels,
            .protos = .empty,
        };
    }

    /// Frees the protos and tables. Only for a Builder that was never compiled.
    pub fn deinit(self: *Builder) void {
        for (self.protos.items) |p| p.destroy(p.ctx, self.gpa);
        self.deinitStorage();
    }

    inline fn deinitStorage(self: *Builder) void {
        self.protos.deinit(self.gpa);
        self.proto_types.deinit(self.gpa);
        self.cards.deinit(self.gpa);
        self.card_counts.deinit(self.gpa);
        self.node_labels.deinit(self.gpa);
        self.node_instance.deinit(self.gpa);
        self.* = undefined;
    }

    /// Tags a node with a subcircuit instance; a second instance makes it a
    /// coupling node.
    fn tagNodeInstance(self: *Builder, node: u32, subckt_instance: u32) !void {
        if (node == GROUND) return;
        if (self.node_instance.items.len <= node) {
            const grow = node + 1 - self.node_instance.items.len;
            try self.node_instance.appendNTimes(self.gpa, 0, grow);
        }
        const cur = self.node_instance.items[node];
        if (cur == 0 and subckt_instance != 0) {
            self.node_instance.items[node] = subckt_instance;
        } else if (cur != 0 and subckt_instance != 0 and cur != subckt_instance) {
            self.node_instance.items[node] = MULTI_INSTANCE;
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

        // One block per instance, in first-seen node order. `at` counts the
        // block's nodes here and becomes its write cursor below.
        var instance_list: std.ArrayList(struct { inst: u32, at: u32 }) = .empty;
        defer instance_list.deinit(gpa);
        // Instance to block index.
        var index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer index.deinit(gpa);
        const tagged = @min(n, @as(u32, @intCast(ni.len)));
        for (1..tagged) |i| {
            const inst = ni[i];
            if (inst == 0 or inst == MULTI_INSTANCE) continue;
            const gop = try index.getOrPut(gpa, inst);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(instance_list.items.len);
                try instance_list.append(gpa, .{ .inst = inst, .at = 0 });
            }
            instance_list.items[gop.value_ptr.*].at += 1;
        }

        if (instance_list.items.len < 2)
            return .{ .perm = null, .info = null };

        // Internal nodes grouped by instance, then the coupling block; ground stays 0.
        const perm = try gpa.alloc(u32, n);
        errdefer gpa.free(perm);
        perm[0] = 0;
        var pos: u32 = 1;

        // Prefix-sum the counts into block starts, then scatter every tagged
        // node in one ascending pass.
        const blocks = try gpa.alloc(numerics.BbdBlock, instance_list.items.len);
        for (instance_list.items, blocks) |*entry, *blk| {
            blk.* = .{ .start = pos, .size = entry.at };
            entry.at = pos;
            pos += blk.size;
        }
        for (1..tagged) |i| {
            const bi = index.get(ni[i]) orelse continue;
            const cursor = &instance_list.items[bi].at;
            perm[i] = cursor.*;
            cursor.* += 1;
        }

        // Coupling, top-level and untagged nodes.
        const coupling_start = pos;
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

    /// Appends an unlabelled row and returns it.
    pub fn addNode(self: *Builder) !u32 {
        if (self.n == std.math.maxInt(u32)) return error.TooManyNodes;
        const id = self.n;
        try self.node_labels.append(self.gpa, "");
        self.n += 1;
        return id;
    }

    /// Reserves label capacity for `expected` rows past ground.
    pub fn reserveNodes(self: *Builder, expected: u32) !void {
        if (expected == std.math.maxInt(u32)) return error.TooManyNodes;
        try self.node_labels.ensureTotalCapacity(self.gpa, expected + 1);
    }

    /// Adds one instance of built-in `D` on `nodes` (one row per port),
    /// attributed to netlist card `card` in `cards`; "" records no card.
    /// `card` is borrowed like the card table. Instances of one type share a
    /// batch whatever the call order. Internal unknowns get fresh rows here,
    /// in `D.U` order, unless `collapse` maps them onto a port.
    pub fn addDevice(
        self: *Builder,
        comptime D: type,
        card: []const u8,
        model: D.Model,
        instance: D.Instance,
        nodes: anytype,
    ) !void {
        const n_u = comptime std.meta.fields(D.U).len;
        var all: [n_u]u32 = undefined;
        inline for (0..D.num_ports) |p| all[p] = nodes[p];

        // Reach the device through its own object's vtable: naming
        // `D.collapse` or `ProtoStore(D)` here would compile the device body
        // into the executable a second time (device/eval.zig).
        const t = comptime Library.builtin(device.modelName(D) orelse
            @compileError(@typeName(D) ++ " is not a catalog device"));
        const vt = self.lib.vtable(t);
        {
            const i = @intFromEnum(t);
            if (self.card_counts.items.len <= i)
                try self.card_counts.appendNTimes(self.gpa, 0, i + 1 - self.card_counts.items.len);
            const ordinal = &self.card_counts.items[i];
            if (card.len != 0) try self.cards.append(self.gpa, .{ .type = t, .index = ordinal.*, .name = card });
            ordinal.* += 1;
        }
        if (comptime n_u > D.num_ports) {
            var col: [n_u]i32 = @splat(-1);
            if (vt.collapse) |collapse| collapse(@ptrCast(&model), @ptrCast(&instance), &col);
            for (D.num_ports..n_u) |u|
                all[u] = if (col[u] >= 0) all[@intCast(col[u])] else try self.addNode();
        }
        const proto = try self.protoOf(t);
        try vt.proto_add(proto.ctx, self.gpa, @ptrCast(&model), @ptrCast(&instance), &all).unwrap();
    }

    /// Returns the proto of device type `t`, creating it on first use.
    pub fn protoOf(self: *Builder, t: DeviceType) !Proto {
        for (self.protos.items, self.proto_types.items) |p, pt| {
            if (pt == t) return p;
        }
        try self.protos.ensureUnusedCapacity(self.gpa, 1);
        try self.proto_types.ensureUnusedCapacity(self.gpa, 1);
        const p = try self.lib.vtable(t).proto_create(self.gpa).unwrap();
        self.protos.appendAssumeCapacity(p);
        self.proto_types.appendAssumeCapacity(t);
        return p;
    }

    /// `compilePerm` for callers that recorded no node or branch row.
    pub fn compile(self: *Builder) !Circuit {
        const gpa = self.gpa;
        var perm: ?[]const u32 = null;
        const circuit = try self.compilePerm(&perm);
        if (perm) |p| gpa.free(p);
        return circuit;
    }

    /// Freezes into a Circuit, consuming the Builder. Protos and labels are
    /// renumbered by the BBD permutation (old row to frozen row), returned in
    /// `perm_out` (allocated with the Builder's allocator), or null when there
    /// is none. Any row the caller recorded before the call must be mapped
    /// through it.
    pub fn compilePerm(self: *Builder, perm_out: *?[]const u32) !Circuit {
        const gpa = self.gpa;
        perm_out.* = null;
        const n: usize = self.n;

        var bbd = try self.computeBbd();
        errdefer if (bbd.perm) |p| gpa.free(p);
        errdefer if (bbd.info) |inf| gpa.free(inf.blocks);
        if (bbd.perm) |perm| {
            for (self.protos.items) |p| p.apply_perm(p.ctx, perm);
            const old_labels = try gpa.alloc([]const u8, n);
            defer gpa.free(old_labels);
            @memcpy(old_labels, self.node_labels.items);
            for (old_labels, perm) |label, new_i| self.node_labels.items[new_i] = label;
            perm_out.* = perm;
            bbd.perm = null; // the caller owns it now
        }

        // Frozen intern table: one byte blob and n+1 offsets.
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

        var ckt = try Circuit.freeze(gpa, self.n, intern_bytes, intern_offs, self.protos.items, self.proto_types.items, bbd.info);
        ckt.needs_tran_op = self.needs_tran_op;
        for (ckt.batches, ckt.batch_types) |*b, t| b.digital = self.lib.digital.items[@intFromEnum(t)];

        self.deinitStorage(); // Circuit.freeze consumed the protos

        return ckt;
    }
};

/// The runtime-loaded (.hdl) module a card's first positional names, directly
/// or through its `.model` card's kind (`.model psp103n psp103va ...`).
fn loadedType(lib: *const Library, dev: Device) ?DeviceType {
    const name = positionalName(dev, 0) orelse return null;
    return lib.find(name) orelse if (dev.model) |m| lib.find(m.kind) else null;
}

/// Writes a positional card value (`R1 a b 1k`, `F1 ... 2.0`) to `field` on
/// whichever of Model/Instance declares it; `applyKv` covers `name=value`.
/// Checking both keeps the binding if a model moves the parameter. Returns
/// false when neither declares it.
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

/// A model card bound once for device type `type`; `model` points at its `D.Model`.
const BoundCard = struct { type: DeviceType, model: *const anyopaque };

/// Netlist to Builder: one pass over the cards, recording the source,
/// branch and port tables the deck's queries resolve against. Rows it
/// records are pre-permutation; `prepare.build` maps them after the freeze.
pub const NetBuilder = struct {
    /// Scratch for everything recorded here; dies after `prepare.build`.
    arena: std.mem.Allocator,
    b: *Builder,
    nl: Netlist,
    /// Circuit row of each net, 0 until a device touches it (ground is 0
    /// anyway). Rows follow stamping order, not net order.
    rows: []u32,
    /// F/H/W control names, sorted case-insensitively: V cards named here are sensed.
    sensed_sources: []const []const u8,

    /// One row per V card.
    v: std.MultiArrayList(VCard) = .empty,
    /// Branch-current probes other than V and L cards. ngspice gives every
    /// MNA branch unknown an `i(<card>)` column (vcvsset.c:41-46,
    /// ccvsset.c:41-46, asrcsetup.c:78-83 for a V-mode B); F, G, S and an
    /// I-mode B have no branch.
    br: std.MultiArrayList(struct { name: []const u8, row: u32 }) = .empty,
    /// `R2 2 0 5K ac=15k`: an AC-only resistance (ngspice restemp.c:112-118),
    /// keyed by card because instance ordinals only exist after the freeze.
    ac_res: std.MultiArrayList(struct { name: []const u8, value: f64 }) = .empty,
    /// One row per I card. An I source has no branch row, so a `.tf` driven
    /// from one excites the node pair.
    i: std.MultiArrayList(struct { name: []const u8, pos: u32, neg: u32 }) = .empty,
    /// One row per source with an `AC` spec; all rows drive one rhs (ngspice
    /// CKTacLoad, acan.c:471-490). A row subtracts at `pos` and adds at `neg`
    /// under Circuit.rhs's residual sign: an I card is (n+, n-), a V card only
    /// drives its branch row (vsrcacld.c:175), so (GROUND, branch).
    ac: std.MultiArrayList(struct { pos: u32, neg: u32, re: f64, im: f64 }) = .empty,
    /// One row per L card; `value` is the inductance, for a K card's M = k*sqrt(L1*L2).
    l: std.MultiArrayList(struct { name: []const u8, branch: u32, value: f64 }) = .empty,
    /// F/H/W/K cards, added after every other card so V and L rows exist.
    deferred: std.ArrayList(Device) = .empty,
    /// Per `Netlist.models` row, the Model its card binds to (`.{}`, the
    /// card's pairs, its polarity), bound on first use and copied per
    /// instance: a BSIM4 bin card is ~270 pairs against ~1000 fields.
    bound_cards: []?BoundCard,

    /// The first `.tran` card's TSTEP and TSTOP, ngspice's TRANinit values
    /// for `resolvePulseDefaults`; 1 ns and 1e30 s without one.
    tran_step: f64 = 1e-9,
    tran_stop: f64 = 1e30,

    /// First stamped V card's positive node and branch row, the `.op` ladder's anchor.
    source_node: u32 = GROUND,
    source_branch: u32 = GROUND,

    /// Topology check (ngspice CKTsetup-class), indexed by row; only rows of
    /// netlist nets are `seen`. `dc`: some element gives the node a DC path
    /// (all but capacitors and current sources); `cur`: an I source touches
    /// it. V and L cards are DC shorts: `uf`/`pot` form a weighted union-find
    /// with `pot` = v(x) - v(parent), and a loop of shorts is an error only
    /// when its KVL sum is inconsistent (V1=5 parallel to V2=3).
    topo: std.MultiArrayList(struct { seen: bool, dc: bool, cur: bool, uf: u32, pot: f64 }) = .empty,

    /// A V card as the queries and the F/H/W cards see it.
    pub const VCard = struct {
        name: []const u8,
        /// `pos`/`neg`: the node pair, which is the control port of an F/H/W sensing it.
        pos: u32,
        neg: u32,
        /// Branch-current row; for a sensed source, the sensing model's control branch.
        branch: u32,
        /// DC value. A sensed source is not stamped; the sensing model's own
        /// `branch (cp,cn) ctrl` holds this voltage as `vsense`.
        dc: f64,
        /// `DISTOF1 [mag [phase]]`, `.disto`'s F1 drive (ngspice
        /// cktdisto.c:100-117), phase in degrees. `{0, 0}` when not given.
        distof1: [2]f64,
        /// `DISTOF2 [mag [phase]]`, the F2 drive of a two-tone `.disto`.
        distof2: [2]f64,
        /// `.sp` port index, 1-based; 0 when not a port (vsrcdefs.h:104-105).
        portnum: u16,
        /// Port reference impedance in ohms.
        z0: f64,
        /// `.hblin` band of a P card (`hblin=[h, s]`).
        band: requests.Port.Band,
    };

    /// A builder over `nl` writing into `b`; both must outlive it.
    pub fn init(arena: std.mem.Allocator, b: *Builder, nl: Netlist) !NetBuilder {
        var sensed: std.ArrayList([]const u8) = .empty;
        for ("fhw") |letter| for (nl.bucket(letter)) |e| {
            const d = nl.device(e);
            if (d.positional.len == 0 or d.positional[0] != .name) continue;
            try sensed.append(arena, d.positional[0].name);
        };
        std.mem.sort([]const u8, sensed.items, {}, struct {
            fn less(_: void, a: []const u8, b_: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b_);
            }
        }.less);
        const rows = try arena.alloc(u32, nl.graph.vertexCount());
        @memset(rows, 0);
        const cards = try arena.alloc(?BoundCard, nl.models.len);
        @memset(cards, null);
        var nb: NetBuilder = .{ .arena = arena, .b = b, .nl = nl, .rows = rows, .sensed_sources = sensed.items, .bound_cards = cards };
        for (nl.deck.analyses) |dir| {
            if (dir.kind != .tran) continue;
            const a0 = argNumber(dir.args, 0);
            const a1 = argNumber(dir.args, 1);
            if (a1 orelse a0) |ts| nb.tran_stop = ts;
            // A malformed card (`.tran xyz 1u`) keeps the default step; the
            // query check rejects it after the build.
            nb.tran_step = if (a1 != null) a0 orelse nb.tran_step else nb.tran_stop / 100.0;
            break;
        }
        return nb;
    }

    /// Row of net `v`, allocated on first touch.
    fn rowOf(self: *NetBuilder, v: netlist.VertexId) !u32 {
        const row = &self.rows[v.index()];
        if (row.* != 0 or v == netlist.ground) return row.*;
        row.* = try self.b.addNode();
        self.b.node_labels.items[row.*] = self.nl.netName(v);
        return row.*;
    }

    /// Row of net index `net`, or `netlist.none` for a net no device touched
    /// and for `netlist.none` itself.
    pub fn frozenRow(self: *const NetBuilder, net: u32) u32 {
        if (net == netlist.none) return netlist.none;
        if (net == 0) return GROUND;
        const r = self.rows[net];
        return if (r == 0) netlist.none else r;
    }

    /// Tags every row a subcircuit device touches with its instance, for the
    /// BBD permutation.
    pub fn tagSubcircuitNodes(self: *NetBuilder) !void {
        const nl = &self.nl;
        for (nl.order) |e| {
            const dev = nl.device(e);
            if (dev.subckt_instance == 0) continue;
            for (dev.pins) |pin| {
                const r = self.rows[pin.index()];
                if (r != 0) try self.b.tagNodeInstance(r, dev.subckt_instance);
            }
        }
    }

    /// Adds the runtime-loaded (.hdl) devices, cards shaped `<name> node...
    /// <model>`, through their vtables. Call after `build`, before the freeze.
    pub fn addDynDevices(self: *NetBuilder) !void {
        const b = self.b;
        const arena = self.arena;
        if (b.lib.names.items.len == Library.builtin_count) return;
        for (self.nl.order) |e| {
            const dev = self.nl.device(e);
            const t = loadedType(b.lib, dev) orelse continue;
            const vt = b.lib.vtable(t);

            const mblob = try arena.alignedAlloc(u8, .@"16", vt.model_size);
            vt.init_model(mblob.ptr);
            if (dev.model) |m| try bindKv(vt.bind_model, mblob.ptr, m.kv);
            // Card pairs override the .model card. VA parameters are Model
            // fields, so they go to the model blob too.
            try bindKv(vt.bind_model, mblob.ptr, dev.kv);
            // The §9.15 `$simparam` host fields, as `deriveModel` writes them
            // for built-in devices; a model without them ignores the keys.
            var host: [simparam_fields.len]batch.Param = undefined;
            inline for (simparam_fields, &host) |f, *h| h.* = .{ .key = f[0], .value = @field(b, f[1]) };
            try vt.bind_model(mblob.ptr, &host).unwrap();
            // LRM 6.3.4/3.4.5: derived parameters after the last write, before
            // `collapse`/`proto_add` read the blob.
            if (vt.derive) |df| df(mblob.ptr);
            const iblob = try arena.alignedAlloc(u8, .@"16", vt.instance_size);
            vt.init_instance(iblob.ptr);
            // A key neither blob declares would be dropped, and the model
            // default used in its place. The binder rejects a null value for
            // a key it knows and ignores one it does not, so a null probe
            // tells the two apart without writing either blob.
            for (dev.kv) |item| {
                const probe = [_]batch.Param{.{ .key = item.key, .value = null }};
                if (vt.bind_model(mblob.ptr, &probe) == .ok and vt.bind_instance(iblob.ptr, &probe) == .ok) {
                    if (!@import("builtin").is_test) std.log.err("{s}: module '{s}' has no parameter '{s}'", .{ dev.name, vt.name, item.key });
                    return error.UnknownParameter;
                }
            }
            try bindKv(vt.bind_instance, iblob.ptr, dev.kv);
            if (dev.pins.len != vt.num_ports) {
                if (!@import("builtin").is_test) std.log.err("{s}: module '{s}' has {d} ports, the card connects {d} nodes", .{ dev.name, vt.name, vt.num_ports, dev.pins.len });
                return error.WrongNodeCount;
            }

            // Same port/internal-node policy as Builder.addDevice.
            const nodes = try arena.alloc(u32, vt.n_u);
            for (0..vt.num_ports) |p|
                nodes[p] = try self.rowOf(dev.pins[p]);
            if (vt.n_u > vt.num_ports) {
                const col = try arena.alloc(i32, vt.n_u);
                @memset(col, -1);
                if (vt.collapse) |cf| cf(mblob.ptr, iblob.ptr, col.ptr);
                for (vt.num_ports..vt.n_u) |u|
                    nodes[u] = if (col[u] >= 0) nodes[@intCast(col[u])] else try b.addNode();
            }

            const proto = try b.protoOf(t);
            try vt.proto_add(proto.ctx, b.gpa, mblob.ptr, iblob.ptr, nodes.ptr).unwrap();
        }
    }

    /// What the deck keeps of the cards, in frozen rows.
    pub const Published = struct {
        bindings: core.QueryBindings,
        /// Branch currents first, then every named node; parallel to
        /// `probe_labels`. Mutable so `.save` can narrow them in place.
        probes: []u32,
        probe_labels: [][]const u8,
        /// `acExcitation` over the frozen rows.
        ac_drive: []const f64,
        source_node: u32,
        source_branch: u32,
        /// Row of the last net the deck introduces.
        output_node: u32,
    };

    /// Maps every row recorded so far through `perm`, the BBD permutation
    /// `Builder.compilePerm` returned (null: none), then copies the deck's
    /// tables into `arena`. Call once, after the freeze: `frozenRow` answers
    /// in frozen rows from then on. `circuit` is the frozen result.
    pub fn publish(self: *NetBuilder, arena: std.mem.Allocator, circuit: *const Circuit, perm: ?[]const u32) !Published {
        if (perm) |p| for ([_][]u32{
            self.v.items(.branch),       self.v.items(.pos),    self.v.items(.neg),  self.i.items(.pos),  self.i.items(.neg),
            self.br.items(.row),         self.l.items(.branch), self.ac.items(.pos), self.ac.items(.neg), (&self.source_node)[0..1],
            (&self.source_branch)[0..1], self.rows,
        }) |rows| for (rows) |*row| {
            if (row.* < p.len) row.* = p[row.*];
        };

        // Probes: branch currents first, then every named node. ngspice gives every
        // MNA branch-current unknown an `i(<card>)` column (V, L, E, H, V-mode B);
        // F, G, S and I-mode B stamp no branch. Branch-first, unlike ngspice.
        // Named nodes and branch rows are disjoint, so circuit.n bounds the total.
        const probe_buf = try arena.alloc(u32, circuit.n);
        const label_buf = try arena.alloc([]const u8, circuit.n);
        var n_probes: u32 = 0;
        for ([_][]const []const u8{ self.v.items(.name), self.l.items(.name), self.br.items(.name) }, [_][]const u32{ self.v.items(.branch), self.l.items(.branch), self.br.items(.row) }) |names, rows| {
            for (names, rows) |name, br| {
                probe_buf[n_probes] = br;
                label_buf[n_probes] = try std.fmt.allocPrint(arena, "i({s})", .{name});
                n_probes += 1;
            }
        }
        for (1..circuit.n) |i| {
            const label = circuit.nodeName(@intCast(i));
            if (label.len != 0) {
                probe_buf[n_probes] = @intCast(i);
                label_buf[n_probes] = try std.fmt.allocPrint(arena, "v({s})", .{label});
                n_probes += 1;
            }
        }

        // The last probe will not do for `output_node`, since the BBD
        // permutation reorders node rows.
        var last_net: u32 = 0;
        for (self.rows, 0..) |row, net| if (row != GROUND) {
            last_net = @intCast(net);
        };

        return .{
            .bindings = .{
                .v_names = try copyNames(arena, self.v.items(.name)),
                .i_names = try copyNames(arena, self.i.items(.name)),
                .v_branches = try arena.dupe(u32, self.v.items(.branch)),
                .v_pos = try arena.dupe(u32, self.v.items(.pos)),
                .v_neg = try arena.dupe(u32, self.v.items(.neg)),
                .i_pos = try arena.dupe(u32, self.i.items(.pos)),
                .i_neg = try arena.dupe(u32, self.i.items(.neg)),
                .v_distof1 = try arena.dupe([2]f64, self.v.items(.distof1)),
                .v_distof2 = try arena.dupe([2]f64, self.v.items(.distof2)),
                .sensed = try copyNames(arena, self.sensed_sources),
                .ports = try self.portList(arena),
            },
            .probes = probe_buf[0..n_probes],
            .probe_labels = label_buf[0..n_probes],
            .ac_drive = try self.acExcitation(arena, circuit.n),
            .source_node = self.source_node,
            .source_branch = self.source_branch,
            .output_node = self.frozenRow(last_net),
        };
    }

    fn addBranchProbe(self: *NetBuilder, name: []const u8, row: u32) !void {
        try self.br.append(self.arena, .{ .name = name, .row = row });
    }

    /// The AC excitation as one stacked vector `[re(0..n), im(0..n)]`,
    /// ngspice's post-CKTacLoad (CKTrhs, CKTirhs) pair. Every AC source lands
    /// in it, so the sweep is one solve per point. All zero when no card names
    /// `AC`. `ac` rows must already be post-permutation.
    fn acExcitation(self: *const NetBuilder, arena: std.mem.Allocator, n: usize) ![]f64 {
        const exc = try arena.alloc(f64, 2 * n);
        @memset(exc, 0);
        const ac = self.ac.slice();
        for (ac.items(.pos), ac.items(.neg), ac.items(.re), ac.items(.im)) |pos, neg, re, im| {
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

    /// The deck's `.sp` ports ordered by `portnum`, as ngspice sorts CKTrfPorts
    /// (vsrctemp.c:110-124). A gapped or duplicated numbering is an error
    /// (vsrctemp.c:143-160). Empty when no V card carries `portnum`, which
    /// leaves `.sp` on its one-port fallback.
    fn portList(self: *const NetBuilder, arena: std.mem.Allocator) ![]requests.Port {
        var nums = z.fromSlice(u16, self.v.items(.portnum));
        const n_ports: usize = nums.max() orelse 0;
        if (n_ports == 0) return &.{};
        const ports = try arena.alloc(requests.Port, n_ports);
        for (ports) |*p| p.branch = std.math.maxInt(u32); // unset
        const v = self.v.slice();
        for (v.items(.portnum), v.items(.pos), v.items(.neg), v.items(.branch), v.items(.z0), v.items(.band)) |num, node, neg, br, z0, band| {
            if (num == 0) continue;
            const slot = &ports[num - 1];
            if (slot.branch != std.math.maxInt(u32)) return error.DuplicatePortNumber;
            slot.* = .{ .node = node, .branch = br, .z0 = z0, .neg = neg, .band = band };
        }
        for (ports) |p| if (p.branch == std.math.maxInt(u32)) return error.MissingPortNumber;
        return ports;
    }

    /// ngspice TRANinit: PULSE TR/TF default to TSTEP and PW/PER to TSTOP,
    /// known only from the `.tran` card. Replaces the -1 sentinels the model
    /// defaults leave. A no-op on a struct without the PULSE fields, so it can
    /// run over both Model and Instance.
    fn resolvePulseDefaults(self: *const NetBuilder, target: anytype) void {
        const T = @TypeOf(target.*);
        if (comptime !@hasField(T, "pulse_tr")) return;
        const tstep = self.tran_step;
        const tstop = self.tran_stop;
        // Only a PULSE waveform gets the TRANinit fill. Any other waveform
        // parks TD past every tstop so its unused pulse fields make no breakpoint.
        if (comptime @hasField(T, "waveform")) {
            // SFFM's CKTfinalTime defaults: FM = 5/TSTOP when omitted, FC =
            // 500/TSTOP when omitted or 0 (vsrcload.c:237-243, isrcload.c:215-221).
            if (comptime @hasField(T, "sffm_fm")) if (target.waveform == @intFromEnum(Wave.sffm)) {
                if (target.sffm_fm == -1.0) target.sffm_fm = @floatCast(5.0 / tstop);
                if (target.sffm_fc == 0.0) target.sffm_fc = @floatCast(500.0 / tstop);
            };
            if (target.waveform != @intFromEnum(Wave.pulse)) {
                target.pulse_td = 1e30;
                return;
            }
        }
        if (target.pulse_tr < 0) target.pulse_tr = tstep;
        if (target.pulse_tf < 0) target.pulse_tf = tstep;
        if (target.pulse_pw < 0) target.pulse_pw = tstop;
        if (target.pulse_per < 0) target.pulse_per = tstop;
    }

    /// Adds every built-in card, then checks the topology. V and L go
    /// first; F/H/W/K wait until the end so the rows they name exist.
    pub fn build(self: *NetBuilder) !void {
        for ("vlifhwkabcdegjmnopqrstuxyz") |c| for (self.nl.bucket(c)) |e| try self.addDevice(self.nl.device(e));
        try self.resolveDeferred();
        try self.topoCheck();
    }

    fn topoEnsure(self: *NetBuilder, id: u32) !void {
        while (self.topo.len <= id) {
            const next: u32 = @intCast(self.topo.len);
            try self.topo.append(self.arena, .{ .seen = false, .dc = false, .cur = false, .uf = next, .pot = 0 });
        }
    }

    /// Root and potential-to-root of `id0` in the weighted forest.
    fn topoRoot(self: *NetBuilder, id0: u32) struct { root: u32, pot: f64 } {
        const uf = self.topo.items(.uf);
        var id = id0;
        var pot: f64 = 0;
        while (uf[id] != id) {
            pot += self.topo.items(.pot)[id];
            id = uf[id];
        }
        return .{ .root = id, .pot = pot };
    }

    /// Classifies one card's nodes. `.dc` marks a DC path, `.cap` presence
    /// only, `.cur` a current source; `.short` also joins the first two nodes
    /// as a DC short with v(node0) - v(node1) = `vshort` and rejects a loop
    /// whose KVL sum disagrees.
    fn topoMark(self: *NetBuilder, dev: Device, kind: enum { dc, cap, cur, short }, vshort: f64) !void {
        var first_two: [2]u32 = .{ GROUND, GROUND };
        for (dev.pins, 0..) |pin, i| {
            const id = try self.rowOf(pin);
            try self.topoEnsure(id);
            self.topo.items(.seen)[id] = true;
            switch (kind) {
                .cap => {},
                .cur => self.topo.items(.cur)[id] = true,
                .dc, .short => self.topo.items(.dc)[id] = true,
            }
            if (i < 2) first_two[i] = id;
        }
        if (kind == .short and dev.pins.len >= 2) {
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
                // v(b) = pot_b + pot[rb] must equal v(a) - vshort.
                self.topo.items(.uf)[b_.root] = a.root;
                self.topo.items(.pot)[b_.root] = a.pot - vshort - b_.pot;
            }
        }
    }

    /// Rejects current-source cutsets, which static KCL cannot satisfy. A
    /// capacitor-only node sets `needs_tran_op`, ngspice's OPtran fallback.
    fn topoCheck(self: *NetBuilder) !void {
        const topo = self.topo.slice();
        for (topo.items(.seen), topo.items(.dc), topo.items(.cur), 0..) |seen, dc, cur, id| {
            if (!seen or id == GROUND or dc) continue;
            if (cur) {
                std.log.err("topology: node '{s}' is a current-source cutset — KCL has no DC path to satisfy it", .{self.b.node_labels.items[id]});
                return error.CurrentSourceCutset;
            }
            self.b.needs_tran_op = true;
        }
    }

    fn addDevice(self: *NetBuilder, dev: Device) !void {
        // HDL devices are added by addDynDevices; their opaque nodes count as
        // a DC path for the topology check.
        if (loadedType(self.b.lib, dev) != null) {
            try self.topoMark(dev, .dc, 0);
            return;
        }
        const letter = dev.kind;
        // 'u' (URC) has no DeviceId behind it: the card expands into
        // resistor/capacitor/diode lumps in addUrc, like ngspice's URCsetup.
        if (letter != 'u' and devices.letter_map.get(&.{letter}) == null) {
            if (try inferDeviceFromModel(dev) == null)
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
                try self.l.append(self.arena, .{ .name = dev.name, .branch = br, .value = positionalNumber(dev, 0) orelse
                    kvNumber(dev.kv, "inductance") orelse kvNumber(dev.kv, "l") orelse 0 });
            },
            'v' => {
                if (comptime !@hasDecl(devices.vsource, "eval")) return error.UnsupportedDevice;
                const bound = try self.bindSource(devices.vsource, dev);
                const nodes = try deviceNodes(self, devices.vsource, dev);
                const br = self.b.n;
                // A source sensed by F/H/W is replaced by the sensing model's
                // own `branch (cp,cn) ctrl`; stamping both would split the
                // current between two sources on one node pair.
                const sensed = std.sort.binarySearch([]const u8, self.sensed_sources, dev.name, std.ascii.orderIgnoreCase) != null;
                if (!sensed) try self.b.addDevice(devices.vsource, dev.name, bound[0], bound[1], nodes);
                const port = if (sensed) null else try sourcePort(dev);
                try self.v.append(self.arena, .{
                    .name = dev.name,
                    .pos = nodes[0],
                    .neg = if (nodes.len > 1) nodes[1] else 0,
                    .branch = br,
                    .dc = bound[0].dc,
                    .distof1 = sourceDisto(dev, "distof1"),
                    .distof2 = sourceDisto(dev, "distof2"),
                    .portnum = if (port) |p| p.num else 0,
                    .z0 = if (port) |p| p.z0 else 0,
                    .band = if (port) |p| p.band else .{},
                });
                // A replaced source stamps nothing, so it can neither anchor
                // the .op ladder nor be driven: `br` is the next card's row.
                if (!sensed) {
                    if (self.source_branch == GROUND) {
                        self.source_node = nodes[0];
                        self.source_branch = br;
                    }
                    if (sourceAc(dev)) |ac| try self.ac.append(self.arena, .{ .pos = GROUND, .neg = br, .re = ac.re, .im = ac.im });
                }
            },
            'i' => {
                if (comptime !@hasDecl(devices.isource, "eval")) return error.UnsupportedDevice;
                const bound = try self.bindSource(devices.isource, dev);
                const nodes = try deviceNodes(self, devices.isource, dev);
                try self.b.addDevice(devices.isource, dev.name, bound[0], bound[1], nodes);
                if (sourceAc(dev)) |ac| try self.ac.append(self.arena, .{ .pos = nodes[0], .neg = nodes[1], .re = ac.re, .im = ac.im });
                try self.i.append(self.arena, .{ .name = dev.name, .pos = nodes[0], .neg = if (nodes.len > 1) nodes[1] else GROUND });
            },
            'f', 'h', 'w', 'k' => try self.deferred.append(self.arena, dev),
            // A tape that reads i() waits until every branch row exists.
            'b' => if (readsCurrent(self.nl, dev)) try self.deferred.append(self.arena, dev) else try self.addB(dev),
            'p' => try self.addCpl(dev),
            'o' => try self.addLossyLine(dev),
            'y' => try self.addTxl(dev),
            'u' => try self.addUrc(dev),
            'e', 'g' => if (kvNumber(dev.kv, "laplace") != null) {
                try addLaplace(self, dev, letter);
            } else if (kvNumber(dev.kv, "td") != null) {
                try addDelay(self, dev, letter);
            } else {
                try self.addByLetter(letter, dev);
                if (letter == 'e') try self.addBranchProbe(dev.name, internalRow(devices.vcvs, "flowZ28pZ2cnZ29", self.b.n));
            },
            else => try self.addByLetter(letter, dev),
        }
    }

    /// TXL (Y card) on the native Pade/history line. The RC case inp2y
    /// expands into 3-pi sections (r/l > 1.6e10) is refused, not approximated.
    fn addTxl(self: *NetBuilder, dev: Device) !void {
        if (dev.pins.len != 4) return error.InvalidTransmissionLinePorts;
        var r: f64 = 0;
        var l: f64 = 0;
        var g: f64 = 0;
        var c: f64 = 0;
        var len: f64 = 0;
        if (dev.model) |m| {
            r = try numericParameter(m.kv, "r") orelse 0;
            l = try numericParameter(m.kv, "l") orelse 0;
            g = try numericParameter(m.kv, "g") orelse 0;
            c = try numericParameter(m.kv, "c") orelse 0;
            len = try numericParameter(m.kv, "length") orelse 0;
        }
        if ((try numericParameter(dev.kv, "length")) orelse (try numericParameter(dev.kv, "len"))) |v| len = v;
        // numericParameter already rejected non-finite values.
        if (g < 0 or r <= 0 or l <= 0 or c <= 0 or len <= 0 or r / l > 1.6e10 or
            !std.math.isFinite(r * len) or r * len <= 0)
            return error.UnsupportedTransmissionLineParameters;
        const fit = devices.txl_native.fitLine(r, l, g, c, len);
        if (!fit.ok or fit.taul <= 0 or fit.sqtCdL <= 0 or !finiteLineCoefficients(fit))
            return error.UnsupportedTransmissionLineParameters;
        const nm: devices.txl_native.Model = .{ .r = r, .l = l, .g = g, .c = c, .len = len };
        const n1 = try self.rowOf(dev.pins[0]);
        const n2 = try self.rowOf(dev.pins[2]);
        try self.b.addDevice(devices.txl_native, dev.name, nm, .{}, [2]u32{ n1, n2 });
        // ngspice writes duplicate i(Y) names; the oracle keeps the last
        // (far-end) branch, as for CPL.
        try self.addBranchProbe(dev.name, self.b.n - 1);
    }

    /// LTRA (O card), routed as ngspice LTRAsetup does:
    /// RLC (r,l,c > 0, g = 0) and RC (r,c > 0, l = g = 0) go to the native
    /// recursive-convolution device (ltra_native: history, coefficients, chop,
    /// step limit); LC (r = g = 0) to one exact Bergeron line (tline.va); a
    /// static RG line to lossy_tline.va's exact two-port. Anything else is refused.
    fn addLossyLine(self: *NetBuilder, dev: Device) !void {
        if (dev.pins.len != 4) return error.InvalidTransmissionLinePorts;
        var model: devices.lossy_tline.Model = .{};
        if (dev.model) |m| {
            try applyKv(&model, m.kv);
            // TXL model cards spell the line length `length=`; the
            // lossy_tline field is `len`.
            if (try numericParameter(m.kv, "length")) |length| model.len = @floatCast(length);
        }
        try applyKv(&model, dev.kv);
        if (try numericParameter(dev.kv, "length")) |length| model.len = @floatCast(length);

        const len: f64 = @as(f64, model.len);
        if (len <= 0 or model.r < 0 or model.l < 0 or model.g < 0 or model.c < 0)
            return error.UnsupportedTransmissionLineParameters;
        const r_t: f64 = @as(f64, model.r) * len;
        const l_t: f64 = @as(f64, model.l) * len;
        const c_t: f64 = @as(f64, model.c) * len;
        const g_t: f64 = @as(f64, model.g) * len;
        if (!std.math.isFinite(r_t) or !std.math.isFinite(l_t) or !std.math.isFinite(c_t) or !std.math.isFinite(g_t))
            return error.NonFiniteParameter;

        if ((model.r > 0 and r_t == 0) or (model.l > 0 and l_t == 0) or
            (model.c > 0 and c_t == 0) or (model.g > 0 and g_t == 0))
            return error.UnsupportedTransmissionLineParameters;
        // Classify raw parameters: scaling underflow must not change the case.
        const wave = model.l > 0 and model.c > 0 and model.g == 0;
        const rc = model.r > 0 and model.c > 0 and model.l == 0 and model.g == 0;
        if (wave) {
            const impedance = @sqrt(model.l / model.c);
            const delay = @sqrt(model.l * model.c) * len;
            if (!finiteLineCoefficients(.{ impedance, 1.0 / impedance, delay, model.r / model.l }) or impedance <= 0 or delay <= 0)
                return error.UnsupportedTransmissionLineParameters;
        } else if (rc) {
            const cbyr = model.c / model.r;
            const rclsqr = model.r * model.c * len * len;
            if (!finiteLineCoefficients(.{ cbyr, rclsqr }) or cbyr <= 0 or rclsqr <= 0)
                return error.UnsupportedTransmissionLineParameters;
        }

        // Only the static RG branch of lossy_tline.va is exact; a dynamic line
        // must not fall into its RC/RLC approximation.
        if (!wave and !rc) {
            if (model.r > 0 and model.g > 0 and model.l == 0 and model.c == 0) {
                const rg = model.r * model.g;
                if (rg == 0) return error.UnsupportedTransmissionLineParameters;
                const gl = len * @sqrt(rg);
                const sinhc = if (gl > 1e-9) std.math.sinh(gl) / gl else 1.0 + gl * gl / 6.0;
                const zs = r_t * sinhc;
                if (gl <= 0 or !finiteLineCoefficients(.{ gl, sinhc, std.math.cosh(gl), zs, zs * (1.0 + 1e-12) }))
                    return error.UnsupportedTransmissionLineParameters;
                deriveModel(devices.lossy_tline, &model, self.b);
                return self.b.addDevice(devices.lossy_tline, dev.name, model, .{}, try deviceNodes(self, devices.lossy_tline, dev));
            }
            return error.UnsupportedTransmissionLineParameters;
        }

        var ports: [4]u32 = undefined;
        for (&ports, dev.pins) |*port, pin| port.* = try self.rowOf(pin);

        if (rc or r_t > 0) {
            const nm: devices.ltra_native.Model = .{
                .r = model.r,
                .l = model.l,
                .g = model.g,
                .c = model.c,
                .len = model.len,
                .compactrel = model.compactrel,
                .compactabs = model.compactabs,
                .rel = model.rel,
                .steplimit = if (model.nosteplimit != 0) 0 else 1,
                .truncdontcut = @floatFromInt(model.truncdontcut),
            };
            return self.b.addDevice(devices.ltra_native, dev.name, nm, .{}, ports);
        }

        // Lossless LC: one exact Bergeron ideal line.
        const t_model: devices.tline.Model = .{
            .z0 = @floatCast(@sqrt(l_t / c_t)),
            .td = @floatCast(@sqrt(l_t * c_t)),
        };
        if (!finiteLineCoefficients(.{ t_model.z0, t_model.td }) or t_model.z0 <= 0 or t_model.td <= 0)
            return error.UnsupportedTransmissionLineParameters;
        try self.b.addDevice(devices.tline, dev.name, t_model, .{}, ports);
    }

    /// URC (U card): `Uxxx n1 n2 ngnd model [l=len] [n=lumps]`. Expanded, as
    /// ngspice URCsetup does, into a ladder of R/C lumps (diodes when ISPERL
    /// is given) sized geometrically by K from both ends toward the middle, so the
    /// totals telescope to L*RPERL and L*CPERL.
    fn addUrc(self: *NetBuilder, dev: Device) !void {
        // Model defaults from urcsetup.c; a card without a .model is legal.
        var k: f64 = 1.5;
        var fmax: f64 = 1e9;
        var rperl: f64 = 1000;
        var cperl: f64 = 1e-12;
        var isperl: ?f64 = null;
        var rsperl: f64 = 0;
        if (dev.model) |m| {
            k = kvNumber(m.kv, "k") orelse k;
            fmax = kvNumber(m.kv, "fmax") orelse fmax;
            rperl = kvNumber(m.kv, "rperl") orelse rperl;
            cperl = kvNumber(m.kv, "cperl") orelse cperl;
            isperl = kvNumber(m.kv, "isperl");
            rsperl = kvNumber(m.kv, "rsperl") orelse rsperl;
        }
        // ngspice defaults the length to 0 (0-ohm lumps); a card without l=
        // means a unit line here.
        const len = kvNumber(dev.kv, "l") orelse 1.0;
        const p = k;
        const r0 = len * rperl;
        const c0 = len * cperl;
        const is0 = len * (isperl orelse 0);

        const lumps: u32 = if (try numericParameter(dev.kv, "n")) |nv|
            // The clamp keeps @intFromFloat defined on absurd cards.
            @intFromFloat(std.math.clamp(nv, 1, 1000))
        else blk: {
            // URCsetup: enough lumps that the finest one's pole clears FMAX.
            const wnorm = fmax * r0 * c0 * 2.0 * std.math.pi;
            const est = @log(wnorm * ((p - 1) / p) * ((p - 1) / p)) / @log(p);
            // `!(est > 3)` also catches the NaN a K <= 1 card produces,
            // which @intFromFloat must not see.
            break :blk if (wnorm < 35 or !(est > 3)) 3 else @intFromFloat(@min(est, 1000));
        };
        const lumps_f: f64 = @floatFromInt(lumps);

        // Geometric sizing (urcsetup.c): lump i carries r1*K^(i-1), c1*K^(i-1).
        const r1 = r0 * (p - 1) / (2 * std.math.pow(f64, p, lumps_f) - 2);
        const c1 = c0 * (p - 1) / (std.math.pow(f64, p, lumps_f - 1) * (p + 1) - 2);
        const is1 = is0 * (p - 1) / (std.math.pow(f64, p, lumps_f - 1) * (p + 1) - 2);
        const rd = len * lumps_f * rsperl;

        const pos = if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND;
        const neg = if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND;
        const gnd = if (dev.pins.len > 2) try self.rowOf(dev.pins[2]) else GROUND;

        // ngspice switches to diodes when ISPERL is merely given
        // (urcsetup.c:106), so ISPERL=0 makes is=0 diodes: gmin plus a
        // voltage-dependent depletion capacitance, not a linear capacitor.
        const use_diodes = isperl != null;
        var prop: f64 = 1; // K^(i-1)
        var lowl = pos; // low-side chain head (walks pos -> middle)
        var hir = neg; // high-side chain head (walks neg -> middle)
        for (1..lumps + 1) |i| {
            const last = i == lumps;
            const hil = try self.b.addNode();
            // The chains meet at the last hi node.
            const lowr = if (last) hil else try self.b.addNode();
            const r: f64 = prop * r1;
            try self.b.addDevice(devices.resistor, dev.name, .{ .r = @floatCast(r) }, .{}, [2]u32{ lowl, lowr });
            try self.b.addDevice(devices.resistor, dev.name, .{ .r = @floatCast(r) }, .{}, [2]u32{ hil, hir });
            if (use_diodes) {
                const Diode = devices.DeviceId.Type(.diode);
                if (comptime !@hasDecl(Diode, "eval")) return error.UnsupportedDevice;
                // ngspice shares one diode model (is=i1, cjo=c1, rs=rd) and
                // scales each lump by area=prop; diode.va has no area, so the
                // scaling goes into per-lump model values.
                var dm: Diode.Model = .{};
                // diosetup.c:216 raises IS below CKTepsmin (1e-28) to it,
                // so ISPERL=0 still conducts ~6e-12 A per unit area at 1 V.
                dm.is = @floatCast(@max(is1, 1e-28) * prop);
                dm.cjo = @floatCast(c1 * prop);
                dm.rs = @floatCast(rd / prop);
                try self.b.addDevice(Diode, dev.name, dm, .{}, [2]u32{ lowr, gnd });
                if (!last) try self.b.addDevice(Diode, dev.name, dm, .{}, [2]u32{ hil, gnd });
            } else {
                const cm: devices.capacitor.Model = .{ .c = @floatCast(prop * c1) };
                try self.b.addDevice(devices.capacitor, dev.name, cm, .{}, [2]u32{ lowr, gnd });
                if (!last) try self.b.addDevice(devices.capacitor, dev.name, cm, .{}, [2]u32{ hil, gnd });
            }
            prop *= p;
            lowl = lowr;
            hir = hil;
        }
    }

    /// R, C or L card. The value (`R1 a b 1k`) goes to parameter
    /// `value_field`; `alias` is a card spelling only (`resist=1k`), never a
    /// field. Returns the row of the device's first internal unknown.
    fn addPassive(
        self: *NetBuilder,
        comptime D: type,
        dev: Device,
        comptime value_field: []const u8,
        comptime alias: []const u8,
    ) !u32 {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        if (comptime !@hasField(D.Model, value_field) and !@hasField(D.Instance, value_field))
            @compileError(@typeName(D) ++ ": no parameter `" ++ value_field ++ "` on Model or Instance");
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        // A value that did not fold (an undefined parameter) is an error, not
        // the 1 mOhm or zero that a missing value defaults to.
        if (dev.positional.len > 0 and dev.model == null and positionalNumber(dev, 0) == null) return error.UnresolvedParameter;
        var value = positionalNumber(dev, 0) orelse try numericParameter(dev.kv, value_field) orelse try numericParameter(dev.kv, alias) orelse blk: {
            // Semiconductor resistor (ngspice restemp.c RESupdate_conduct):
            // R = RSH*(L-2*SHORT)/(W-2*NARROW), W defaulting to the model's
            // DEFW. A non-positive result reads as open, as ngspice's
            // unchecked divide leaves it.
            if (comptime D == devices.resistor) {
                if (dev.model) |m| {
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
                }
            }
            break :blk 0;
        };
        // ngspice instance factors, conduct = m/(R*scale), apply to an
        // explicit value too (`R5 6 0 10 scale=1K`, `R4 ... m=2`).
        if (comptime D == devices.resistor) {
            const scale = kvNumber(dev.kv, "scale") orelse 1;
            const mult = kvNumber(dev.kv, "m") orelse 1;
            value *= scale;
            value /= mult;
            // ngspice restemp.c: "resistance too low or not given, set to 1 mOhm"
            if (!(value > 0)) value = 1e-3;
            // `ac=` is an AC-only resistance (restemp.c:112-118) with the same
            // instance factors; Circuit.linearizeAc swaps it in.
            if (kvNumber(dev.kv, "ac")) |ac_r| {
                var ac_value = ac_r * scale / mult;
                if (!(ac_value > 0)) ac_value = 1e-3;
                try self.ac_res.append(self.arena, .{ .name = dev.name, .value = ac_value });
            }
        }
        _ = try setParam(D, &model, &instance, value_field, value);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        const nodes = try deviceNodes(self, D, dev);
        const br = self.b.n;
        try self.b.addDevice(D, dev.name, model, instance, nodes);
        return br;
    }

    /// Binds a V or I card (`V1 a b DC 5 PULSE(0 5 1n 1n 1n 1u 2u)`), all but
    /// the nodes. Each step runs over both Model and Instance behind
    /// @hasField guards, so a model that moves a parameter keeps binding.
    ///
    /// The order is fixed: `DC <v>` first, then the waveform group, then the
    /// card pairs (so `pulse_tr=2n` overrides the group), and only then
    /// `resolvePulseDefaults`, so the -1 sentinels survive every legitimate
    /// write before the `.tran` card fills them.
    fn bindSource(self: *const NetBuilder, comptime D: type, dev: Device) !struct { D.Model, D.Instance } {
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        const dc = sourceDc(dev);
        _ = try setParam(D, &model, &instance, "dc", dc orelse 0);
        applySourceWaveform(&model, dev);
        applySourceWaveform(&instance, dev);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        // The PWL suffixes `td=` and `r=` (vsrcpar.c VSRC_TD, VSRC_R).
        if (kvNumber(dev.kv, "td")) |td| _ = try setParam(D, &model, &instance, "pwl_td", td);
        if (kvNumber(dev.kv, "r")) |r| _ = try setParam(D, &model, &instance, "pwl_repeat", r);
        self.resolvePulseDefaults(&model);
        self.resolvePulseDefaults(&instance);
        // ngspice: a source with a transient spec and no DC value has the
        // t = 0 value as DC. Resolved here so the model reads `dc`
        // unconditionally and a .dc sweep can override it.
        if (dc == null) {
            dcFromWaveform(&model);
            dcFromWaveform(&instance);
        }
        return .{ model, instance };
    }

    fn addByLetter(self: *NetBuilder, letter: u8, dev: Device) !void {
        // The netlist moved a Q/M card's model name to positional[0] whatever
        // its terminal count.
        switch (try resolveDeviceId(letter, dev)) {
            inline else => |comptime_id| {
                const D = devices.DeviceId.Type(comptime_id);
                try addSingleDevice(self, D, dev);
                // ngspice's VBIC `i(q1)` is its excess-phase branch, made only
                // when TD > 0 (vbicsetup.c:510-525). Node xf2 carries only a
                // 1 ohm load, so that current equals v(xf2): alias the column.
                if (comptime_id == .vbic13_4t) {
                    const td = kvNumber(dev.kv, "td") orelse if (dev.model) |m| kvNumber(m.kv, "td") orelse 0 else 0;
                    if (td > 0) try self.addBranchProbe(dev.name, internalRow(D, "xf2", self.b.n));
                }
            },
        }
    }

    /// B card. Only a V-mode B gets an i() column: ngspice makes the branch
    /// only for ASRC_VOLTAGE (asrcset.c:81-88). Our bsource declares the
    /// unknown either way; the I-mode one stays unprobed rather than
    /// published as a column ngspice never writes.
    fn addB(self: *NetBuilder, dev: Device) !void {
        if (try addBsource(self, dev))
            try self.addBranchProbe(dev.name, internalRow(devices.bsource, "flowZ28pZ2cnZ29", self.b.n));
    }

    /// The branch-current row of card `name`: a V card's (its sensing
    /// model's control branch once an F/H/W takes it over), an L card's, or
    /// any other branch `br` lists. Null for a card without one.
    fn branchRow(self: *const NetBuilder, name: []const u8) ?u32 {
        if (netlist.nameIndex(self.v.items(.name), name)) |k| return self.v.items(.branch)[k];
        if (netlist.nameIndex(self.l.items(.name), name)) |k| return self.l.items(.branch)[k];
        if (netlist.nameIndex(self.br.items(.name), name)) |k| return self.br.items(.row)[k];
        return null;
    }

    /// Adds the F/H/W/K cards once every V and L row exists, then the B
    /// cards that read i(), once F/H/W have claimed their sensed branches.
    fn resolveDeferred(self: *NetBuilder) !void {
        if (self.deferred.items.len == 0) return;
        var source_index: std.StringHashMapUnmanaged(u32) = .empty;
        if (self.sensed_sources.len != 0) {
            try source_index.ensureTotalCapacity(self.arena, @intCast(self.v.len));
            for (self.v.items(.name), 0..) |name, i| {
                const entry = source_index.getOrPutAssumeCapacity(name);
                if (!entry.found_existing) entry.value_ptr.* = @intCast(i);
            }
        }
        for (self.deferred.items) |dev| {
            switch (dev.kind) {
                'f' => try self.addBranchRef(devices.cccs, dev, source_index, 1.0),
                'h' => try self.addBranchRef(devices.ccvs, dev, source_index, 0.0),
                'w' => try self.addBranchRef(devices.cswitch, dev, source_index, null),
                'k' => try self.addKinduc(dev),
                'b' => {},
                else => unreachable,
            }
        }
        for (self.deferred.items) |dev| if (dev.kind == 'b') try self.addB(dev);
    }

    /// CPL (P card) on the native modal-fit, accepted-step convolution line,
    /// for 2 to 4 conductors. Anything else is refused, never approximated.
    fn addCpl(self: *NetBuilder, dev: Device) !void {
        if (dev.pins.len < 6 or dev.pins.len % 2 != 0) return error.UnsupportedCoupledLineDimension;
        const n_lines = (dev.pins.len - 2) / 2;
        if (n_lines > 4) return error.UnsupportedCoupledLineDimension;
        const card = dev.model orelse return error.UnsupportedTransmissionLineParameters;
        var rr: [10]f64 = undefined;
        var ll: [10]f64 = undefined;
        var cc: [10]f64 = undefined;
        var gg: [10]f64 = @splat(0);
        const nr = try cplVector(card.kv, "r", &rr);
        const nl = try cplVector(card.kv, "l", &ll);
        const nc = try cplVector(card.kv, "c", &cc);
        const ng = try cplVector(card.kv, "g", &gg);
        const length = (try numericParameter(dev.kv, "length")) orelse (try numericParameter(card.kv, "length")) orelse 0;
        const tri = n_lines * (n_lines + 1) / 2;
        if (nr != tri or nl != tri or nc != tri or (ng != 0 and ng != tri) or !std.math.isFinite(length) or length <= 0)
            return error.UnsupportedTransmissionLineParameters;
        inline for (.{ device.models.cpl_native_2, device.models.cpl_native_3, device.models.cpl_native_4 }) |D| {
            const N = D.num_ports / 2;
            if (n_lines == N) {
                var model: D.Model = .{ .length = length };
                @memcpy(&model.rr, rr[0..tri]);
                @memcpy(&model.ll, ll[0..tri]);
                @memcpy(&model.cc, cc[0..tri]);
                @memcpy(&model.gg, gg[0..tri]);
                // Declined or nonfinite modal fits must not become DC-only lines.
                var instance: D.Instance = .{};
                D.precompute(&instance, &model);
                if (!model.ok or model.min_tau_s <= 0 or !finiteLineCoefficients(model)) return error.UnsupportedTransmissionLineParameters;
                // ngspice cplsetup binds conductor nodes and ignores references.
                var nodes: [2 * N]u32 = undefined;
                for (0..N) |i| nodes[i] = try self.rowOf(dev.pins[i]);
                for (0..N) |i| nodes[N + i] = try self.rowOf(dev.pins[N + 1 + i]);
                try self.b.addDevice(D, dev.name, model, instance, nodes);
                try self.addBranchProbe(dev.name, self.b.n - 1);
                return;
            }
        }
        unreachable;
    }

    /// F, H or W card: a device across the sensed V card's node pair that
    /// takes over that source's branch. `default_gain` null: no gain parameter.
    fn addBranchRef(self: *NetBuilder, comptime D: type, dev: Device, source_index: std.StringHashMapUnmanaged(u32), comptime default_gain: ?f64) !void {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        const ctrl_name = positionalName(dev, 0) orelse return error.MissingControlSource;
        const ctrl = source_index.get(ctrl_name) orelse return error.UnknownControlSource;

        var model: D.Model = .{};
        // W card: `W n+ n- Vctrl model`, model at positional[1] after the
        // control source. F/H put a number there, so fall back to positional[0].
        if (positionalName(dev, 1) orelse positionalName(dev, 0)) |name| {
            if (self.nl.findModel(name)) |m| try applyKv(&model, m.kv);
        }
        var instance: D.Instance = .{};
        if (comptime default_gain) |dflt|
            _ = try setParam(D, &model, &instance, "gain", positionalNumber(dev, 1) orelse kvNumber(dev.kv, "gain") orelse dflt);
        // The sensed source is not stamped (see the 'v' case); `vsense` keeps
        // its voltage on this model's stand-in branch.
        _ = try setParam(D, &model, &instance, "vsense", self.v.items(.dc)[ctrl]);
        try applyKv(&instance, dev.kv);

        // (p, n, cp, cn): the control port is the sensed source's node pair.
        // The model's `branch (cp, cn) ctl` across it carries that source's current.
        const nodes = [4]u32{
            if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND,
            if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND,
            self.v.items(.pos)[ctrl],
            self.v.items(.neg)[ctrl],
        };
        try self.b.addDevice(D, dev.name, model, instance, nodes);

        // The sensed source's current lives on this model's control branch;
        // its `i(v...)` column reads that row (ngspice cccsset.c:47).
        self.v.items(.branch)[ctrl] = internalRow(D, "flowZ28cpZ2ccnZ29", self.b.n);
        // H also carries its own output branch, and ngspice names it i(h1).
        if (comptime @hasDecl(D, "U") and D == devices.ccvs)
            try self.addBranchProbe(dev.name, internalRow(D, "flowZ28pZ2cnZ29", self.b.n));
    }

    /// K card: mutual inductance between two L cards' branches.
    fn addKinduc(self: *NetBuilder, dev: Device) !void {
        if (comptime !@hasDecl(devices.kinduc, "eval")) return error.UnsupportedDevice;
        const l1_name = positionalName(dev, 0) orelse return error.KinducMissingInductor;
        const l2_name = positionalName(dev, 1) orelse return error.KinducMissingInductor;
        const li1 = netlist.nameIndex(self.l.items(.name), l1_name) orelse return error.KinducUnknownInductor;
        const li2 = netlist.nameIndex(self.l.items(.name), l2_name) orelse return error.KinducUnknownInductor;
        const ibr1 = self.l.items(.branch)[li1];
        const ibr2 = self.l.items(.branch)[li2];
        var model: devices.kinduc.Model = .{};
        if (positionalNumber(dev, 2)) |k| model.k = try castField(f32, k);
        if (dev.model) |m| try applyKv(&model, m.kv);
        try applyKv(&model, dev.kv);
        // The card gives the coupling k; the device stamps M = k*sqrt(L1*L2)
        // (ngspice INDsetup).
        model.k = try castField(f32, @as(f64, model.k) *
            @sqrt(self.l.items(.value)[li1] * self.l.items(.value)[li2]));
        try self.b.addDevice(devices.kinduc, dev.name, model, .{}, [2]u32{ ibr1, ibr2 });
    }
};

/// The built-in device a card letter and its model's LEVEL select.
fn resolveDeviceId(letter: u8, dev: Device) !devices.DeviceId {
    const id = try deviceIdOf(letter, dev);
    // PSP 103 ships as two devices, as upstream does (psp103.va,
    // psp103_nqs.va): the NQS build carries 48 unknowns per instance where
    // the QS one carries 12, whatever SWNQS is, so only a card that asks
    // for NQS pays for it.
    if (id == .psp103) {
        const swnqs = kvNumber(dev.kv, "swnqs") orelse
            if (dev.model) |m| kvNumber(m.kv, "swnqs") orelse 0 else 0;
        if (swnqs != 0) return .psp103_nqs;
    }
    return id;
}

fn deviceIdOf(letter: u8, dev: Device) !devices.DeviceId {
    const level = try modelLevel(dev);
    return switch (letter) {
        // `.model X VDMOS(...)` has no LEVEL; the model kind selects it, as
        // in ngspice inpdomod.c.
        'm' => blk: {
            if (dev.model) |mm| {
                if (std.ascii.eqlIgnoreCase(mm.kind, "vdmos")) break :blk .vdmos;
            }
            break :blk try devices.mosfetDeviceId(level);
        },
        'q' => try devices.bjtDeviceId(level),
        'd' => try devices.diodeDeviceId(level),
        'j' => try devices.jfetDeviceId(level),
        'z' => try devices.mesDeviceId(level),
        else => devices.letter_map.get(&.{letter}) orelse
            (try inferDeviceFromModel(dev)) orelse error.UnsupportedDevice,
    };
}

/// The device a card with no built-in letter gets from its `.model` kind
/// (`N1 d g s b nmos_model`); null when the kind names none.
fn inferDeviceFromModel(dev: Device) !?devices.DeviceId {
    const m = dev.model orelse return null;
    const l = try modelLevel(dev);
    if (std.ascii.eqlIgnoreCase(m.kind, "vdmos"))
        return .vdmos;
    // The OSDI module name ngspice loads PSP 103 under (IHP SG13G2 cards).
    if (std.ascii.eqlIgnoreCase(m.kind, "psp103va"))
        return .psp103;
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

/// Sets P-type polarity under whichever name the model spells it. The names
/// are VerA output: Verilog-A `type` becomes `typeZ` (a Zig keyword), a
/// declared `type_` becomes `typeZ5f`. A misspelled `@hasField` is silently
/// false and runs a P-type card as N-type, so do not rename them.
fn setPolarity(comptime D: type, model: *D.Model) !void {
    if (comptime @hasField(D.Model, "typeZ")) {
        model.typeZ = -1; // i64 on most, f64 on mos1/mos2; `-1` coerces to both
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
        // ponytail: jfet/jfet2/mes/mesa/vdmos have no polarity parameter, so
        // a P-type card on them is refused rather than run N-type (silent
        // NaN). Upgrade path: a `type` parameter in the .va, as mos1 has.
        return error.UnsupportedDevice;
    }
}

/// VerA's reserved Model fields for §9.15 `$simparam`, each with the Builder
/// field it is copied from: tnom (degC), reltol, abstol (A), vntol (V). See
/// VerA's `Lower.simparamHostField`.
const simparam_fields = .{
    .{ "nom_temp__", "nom_temp_c" },
    .{ "reltol__", "reltol" },
    .{ "abstol__", "abstol" },
    .{ "vntol__", "vntol" },
};

/// Runs §6.3.4/§3.4.5 `derive` through the device's own object: calling
/// `D.derive` directly would compile the generated body (thousands of lines
/// for bsim4) into the executable a second time.
///
/// `.options tnom` is written immediately before `derive`: VerA lowers
/// `parameter real tnom = $simparam("tnom")` to `if (!model.tnom__given)
/// model.tnom = model.nom_temp__`, ngspice's `if (!BSIM4tnomGiven)
/// BSIM4tnom = ckt->CKTnomTemp` (b4set.c:1950). A card TNOM/TREF set
/// `__given` in `applyKv`, so it still wins.
fn deriveModel(comptime D: type, model: *D.Model, b: *const Builder) void {
    inline for (simparam_fields) |f| {
        if (comptime @hasField(D.Model, f[0])) @field(model, f[0]) = @field(b, f[1]);
    }
    if (comptime device.modelName(D)) |name| {
        if (device.vtable(name).derive) |f| f(@ptrCast(model));
    } else if (comptime @hasDecl(D, "derive")) D.derive(model);
}

/// `base` with model card `m` (netlist row `row`) and its polarity bound.
/// Cached per row when `base` is `.{}`, which holds for every device but
/// VBIC's `sw_et` pre-set.
fn boundCard(self: *NetBuilder, comptime D: type, base: D.Model, m: Model, row: u32) !D.Model {
    const t = comptime Library.builtin(device.modelName(D).?);
    const cacheable = comptime !@hasField(D.Model, "sw_et");
    if (cacheable and row != netlist.none) if (self.bound_cards[row]) |c| if (c.type == t)
        return @as(*const D.Model, @ptrCast(@alignCast(c.model))).*;
    var model = base;
    try applyKv(&model, m.kv);
    // Polarity comes from the model card kind, outside applyKv.
    if (eqlAny(m.kind, &.{ "pmos", "pnp", "pjf", "pmf", "phfet" })) try setPolarity(D, &model);
    if (cacheable and row != netlist.none and self.bound_cards[row] == null) {
        const slot = try self.arena.create(D.Model);
        slot.* = model;
        self.bound_cards[row] = .{ .type = t, .model = slot };
    }
    return model;
}

/// Binds one card onto built-in `D`: model card, polarity, card pairs, derive.
fn addSingleDevice(self: *NetBuilder, comptime D: type, dev: Device) !void {
    const b = self.b;
    if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
    var model: D.Model = .{};
    var instance: D.Instance = .{};
    // VBIC: a card without the fifth (thermal) node has it tied to ground in
    // ngspice (inp2q.c:85-87), so dT = 0 whatever RTH says. Our `dt` is an
    // internal node, so self-heating is off unless the card names it; an
    // explicit SW_ET on the card still wins through applyKv below.
    if (comptime @hasField(D.Model, "sw_et")) {
        if (dev.pins.len < 5) model.sw_et = 0;
    }
    if (dev.model) |m| model = try boundCard(self, D, model, m, dev.model_row);
    _ = try setParam(D, &model, &instance, "gain", positionalNumber(dev, 0) orelse 0);
    // Card pairs go to both structs: VerA puts every Verilog-A `parameter`
    // (W and L included) on Model. `model` is a per-device copy, so this
    // overrides the model card for this instance only.
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);
    // §6.3.4/§3.4.5: derived parameters after the last write; explicit card
    // values win through `__given`.
    deriveModel(D, &model, b);
    try b.addDevice(D, dev.name, model, instance, try deviceNodes(self, D, dev));
}

/// B card as an expression tape, run by models/bsource.va (V output),
/// bsource_i.va (I output) or bsource_q.va (the `q=` charge of a behavioural
/// VCCAP). Returns true for a voltage-mode B, the only kind with a branch
/// current worth probing (ngspice asrcset.c:81-88).
fn addBsource(self: *NetBuilder, dev: Device) !bool {
    // The last v=/i=/q= wins, as ngspice reads the card.
    var mode: BMode = .v;
    for (dev.kv) |item| mode = b_modes.get(item.key) orelse mode;
    switch (mode) {
        .v => try addTape(self, devices.bsource, dev),
        .i => try addTape(self, devices.bsource_i, dev),
        .q => try addTape(self, devices.bsource_q, dev),
    }
    return mode == .v;
}

/// A B card's output: V(p,n), I(p,n), or the charge whose ddt is I(p,n).
const BMode = enum { v, i, q };
const b_modes = std.StaticStringMap(BMode).initComptime(.{ .{ "v", .v }, .{ "i", .i }, .{ "q", .q } });

fn addTape(self: *NetBuilder, comptime B: type, dev: Device) !void {
    if (comptime !@hasDecl(B, "eval")) return error.UnsupportedDevice;
    var model: B.Model = .{};
    var instance: B.Instance = .{};
    if (dev.model) |m| try applyKv(&model, m.kv);
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);

    // Output rows before control rows, so node numbering follows the card.
    var nodes: [B.num_ports]u32 = @splat(GROUND);
    for (dev.pins[0..@min(dev.pins.len, 2)], 0..) |pin, k| nodes[k] = try self.rowOf(pin);
    var t: Tape = .{};
    for (dev.kv) |item| {
        _ = b_modes.get(item.key) orelse continue;
        t = .{};
        switch (item.value) {
            .num => |value| {
                t.consts[0] = value;
                t.n_ops = 1;
            },
            .expr => |span| {
                const ops = self.nl.exprOps(span);
                compileTape(self, ops, &t, &nodes) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        // The test runner fails any test that logs an error.
                        if (!@import("builtin").is_test) std.log.err("B-source '{s}': the {s}= expression is not supported ({s}); the limits are i() of branch cards only, no unknown names, known functions only, {d} probed nets and currents, {d} ops, {d} constants, stack depth {d}", .{ dev.name, item.key, @errorName(err), tape.max_probes, tape.max_ops, tape.max_consts, tape.max_depth });
                        return error.UnsupportedBsourceExpression;
                    },
                };
            },
            else => return error.UnresolvedParameter,
        }
    }
    t.store(B.Model, &model);
    try self.b.addDevice(B, dev.name, model, instance, nodes);
}

/// Four rows: the output pair, then the control pair.
fn controlledNodes(self: *NetBuilder, dev: Device) ![4]u32 {
    if (dev.pins.len != 4) return error.InvalidControlledSourceNodes;
    var nodes: [4]u32 = undefined;
    for (dev.pins, &nodes) |pin, *row| row.* = try self.rowOf(pin);
    return nodes;
}

/// HSPICE `SCALE` times, for a G card, `M`; both default to 1.
fn cardScale(dev: Device, letter: u8) f64 {
    const m = if (letter == 'g') kvNumber(dev.kv, "m") orelse 1 else 1;
    return (kvNumber(dev.kv, "scale") orelse 1) * m;
}

/// E/G LAPLACE card: H(s) = Σ k_i s^i / Σ d_i s^i, ascending coefficients
/// with `laplace=` of them in the numerator [SA E-element Laplace
/// Transform], on models/vcvs_laplace.va or vccs_laplace.va (`laplace_nd`).
/// Improper H, a zero denominator and orders past the arrays are refused.
fn addLaplace(self: *NetBuilder, dev: Device, letter: u8) !void {
    for (dev.kv) |item| {
        const known = std.StaticStringMap(void).initComptime(.{ .{"laplace"}, .{"scale"}, .{"m"} });
        if (!known.has(item.key)) return error.UnsupportedLaplaceParameter;
    }
    const nk_f = kvNumber(dev.kv, "laplace").?;
    if (!(nk_f >= 1) or nk_f != @round(nk_f) or nk_f >= @as(f64, @floatFromInt(dev.positional.len))) return error.UnsupportedLaplaceOrder;
    const nk: usize = @intFromFloat(nk_f);
    var coef: [2 * 32]f64 = undefined;
    if (dev.positional.len > coef.len) return error.UnsupportedLaplaceOrder;
    for (dev.positional, coef[0..dev.positional.len]) |v, *c| c.* = valueNumber(v) orelse return error.UnresolvedParameter;
    var num = coef[0..nk];
    var den = coef[nk..dev.positional.len];
    while (den.len > 0 and den[den.len - 1] == 0) den.len -= 1;
    while (num.len > 0 and num[num.len - 1] == 0) num.len -= 1;
    inline for (.{ devices.vcvs_laplace, devices.vccs_laplace }, "eg") |D, l| if (letter == l) {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        const slots = comptime slotCount(D.Model, "den");
        if (den.len == 0 or den.len > slots or num.len > den.len) return error.UnsupportedLaplaceOrder;
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        _ = try setParam(D, &model, &instance, "gain", cardScale(dev, letter));
        inline for (0..slots) |k| {
            @field(model, pwlSlot("num", k)) = if (k < num.len) num[k] else 0;
            @field(model, pwlSlot("den", k)) = if (k < den.len) den[k] else 0;
        }
        try self.b.addDevice(D, dev.name, model, instance, try controlledNodes(self, dev));
        if (l == 'e') try self.addBranchProbe(dev.name, internalRow(D, "flowZ28pZ2cnZ29", self.b.n));
    };
}

/// E/G DELAY card: the control voltage delayed by `td=`, times SCALE
/// [SA E-element Delay Element], on models/vcvs_delay.va or vccs_delay.va.
fn addDelay(self: *NetBuilder, dev: Device, letter: u8) !void {
    const td = kvNumber(dev.kv, "td") orelse return error.UnresolvedParameter;
    if (!(td > 0)) return error.InvalidDelay;
    inline for (.{ devices.vcvs_delay, devices.vccs_delay }, "eg") |D, l| if (letter == l) {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        _ = try setParam(D, &model, &instance, "gain", cardScale(dev, letter));
        _ = try setParam(D, &model, &instance, "td", td);
        try self.b.addDevice(D, dev.name, model, instance, try controlledNodes(self, dev));
        if (l == 'e') try self.addBranchProbe(dev.name, internalRow(D, "flowZ28pZ2cnZ29", self.b.n));
    };
}

/// The tape's opcodes and capacities. The opcode numbers and capacities are
/// the ones models/bsource.va interprets; `Tape.store` checks the capacities
/// against the generated Model at compile time.
const tape = struct {
    /// The interpreter's stack, `st[0:15]` in models/bsource.va: zeroed on
    /// every evaluation (vera_scratch), so it is kept short.
    const max_depth = 16;
    const max_ops = 64;
    const max_consts = 32;
    const max_probes = 8;
    const Code = enum(u8) {
        num, v, vd, neg, not, add, sub, mul, div, powi, powc, pow, lt, gt, le, ge, eq, ne,
        @"and", @"or", sel, sqrt, abs, min, max, exp, ln, log10, sin, cos, tan, atan, tanh,
        floor, ceil, time, temper, pwl,
    };
};

/// A compiled expression: postfix opcodes with two u8 operands each, and a
/// constant pool. Built here, then copied into the device's parameter arrays.
const Tape = struct {
    n_ops: u8 = 0,
    op_code: [tape.max_ops]tape.Code = @splat(.num),
    op_a: [tape.max_ops]u8 = @splat(0),
    op_b: [tape.max_ops]u8 = @splat(0),
    consts: [tape.max_consts]f64 = @splat(0.0),

    /// Writes the tape into a bsource Model, whose arrays VerA flattens into
    /// one field per slot (see `pwlSlot`).
    fn store(t: Tape, comptime M: type, model: *M) void {
        comptime std.debug.assert(slotCount(M, "op_code") == tape.max_ops and slotCount(M, "consts") == tape.max_consts);
        model.n_ops = t.n_ops;
        inline for (0..tape.max_ops) |k| {
            @field(model, pwlSlot("op_code", k)) = @intFromEnum(t.op_code[k]);
            @field(model, pwlSlot("op_a", k)) = t.op_a[k];
            @field(model, pwlSlot("op_b", k)) = t.op_b[k];
        }
        inline for (0..tape.max_consts) |k| @field(model, pwlSlot("consts", k)) = t.consts[k];
    }
};

/// True when a B card's expression reads a branch current.
fn readsCurrent(nl: Netlist, dev: Device) bool {
    for (dev.kv) |item| switch (item.value) {
        .expr => |span| for (nl.exprOps(span)) |op| {
            if (op.code == .iprobe) return true;
        },
        else => {},
    };
    return false;
}

/// Translates a postfix card expression into the bsource tape, giving each
/// distinct probed row (a net, or the branch an i() reads) a control port in
/// `nodes`. Fails on anything the tape cannot express or hold.
fn compileTape(self: *NetBuilder, ops: []const Op, model: *Tape, nodes: []u32) !void {
    var rows: [tape.max_probes]u32 = undefined;
    var n_rows: usize = 0;
    var n_consts: usize = 0;
    var n: usize = 0;
    for (ops) |op| {
        if (n == tape.max_ops) return error.TooManyOps;
        const code: tape.Code = switch (op.code) {
            .num => blk: {
                if (n_consts == tape.max_consts) return error.TooManyConstants;
                model.consts[n_consts] = self.nl.consts[op.a];
                model.op_a[n] = @intCast(n_consts);
                n_consts += 1;
                break :blk .num;
            },
            .vprobe, .iprobe => blk: {
                if (op.a == netlist.none) return error.EmptyProbe;
                var port: [2]u8 = .{ 0, 0 };
                for ([2]u32{ op.a, op.b }, &port) |id, *slot| {
                    if (id == netlist.none) break;
                    const row = if (op.code == .vprobe)
                        try self.rowOf(.from(id))
                    else
                        self.branchRow(self.nl.pool.str(@enumFromInt(id))) orelse return error.UnknownCurrentProbe;
                    const k = std.mem.indexOfScalar(u32, rows[0..n_rows], row) orelse k: {
                        if (n_rows == tape.max_probes) return error.TooManyProbes;
                        rows[n_rows] = row;
                        nodes[2 + n_rows] = row;
                        n_rows += 1;
                        break :k n_rows - 1;
                    };
                    slot.* = @intCast(k);
                }
                model.op_a[n] = port[0];
                model.op_b[n] = port[1];
                break :blk if (op.b == netlist.none) .v else .vd;
            },
            .ident => switch (op.a) {
                2 => .time,
                3 => .temper,
                else => return error.UnsupportedOperand,
            },
            .call => blk: {
                if (@as(netlist.expr.Fn, @enumFromInt(op.a)) != .table) break :blk try callCode(@enumFromInt(op.a), op.b);
                // table(x, d, x1, y1, ...): the constants after x become the
                // op's table, already consecutive in the pool.
                const k = op.b - 1;
                if (op.b < 6 or k % 2 != 1 or n < k) return error.WrongArity;
                for (model.op_code[n - k .. n]) |c| if (c != .num) return error.NonConstantTable;
                n -= k;
                const at = model.op_a[n];
                const pts = model.consts[at + 1 .. at + k];
                var i: usize = 2;
                while (i < pts.len) : (i += 2) if (!(pts[i] > pts[i - 2])) return error.TableNotAscending;
                model.op_b[n] = @intCast(k / 2);
                break :blk .pwl;
            },
            .live => return error.UnsupportedOperand,
            inline else => |c| @field(tape.Code, @tagName(c)),
        };
        model.op_code[n] = code;
        // A constant exponent folds into the power op: that constant is the
        // previous op and the last pool entry (`powc` keeps its index).
        if (code == .pow and model.op_code[n - 1] == .num) {
            const e = model.consts[n_consts - 1];
            n -= 1;
            if (e >= 0 and e <= 255 and e == @round(e)) {
                n_consts -= 1;
                model.op_code[n] = .powi;
                model.op_a[n] = @intFromFloat(e);
            } else model.op_code[n] = .powc;
        }
        n += 1;
    }
    model.n_ops = @intCast(n);
    if (stackDepth(model.*) > tape.max_depth) return error.TooDeep;
}

/// The deepest the interpreter's stack gets running `t`.
fn stackDepth(t: Tape) usize {
    var sp: isize = 0;
    var deepest: isize = 0;
    for (t.op_code[0..t.n_ops]) |code| {
        sp += switch (code) {
            .num, .v, .vd, .time, .temper => 1,
            .sel => -2,
            .add, .sub, .mul, .div, .pow, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or", .min, .max => -1,
            else => 0,
        };
        deepest = @max(deepest, sp);
    }
    return @intCast(deepest);
}

/// The tape op for a call of `f` with `argc` arguments.
fn callCode(f: netlist.expr.Fn, argc: u32) !tape.Code {
    const want: u32 = switch (f) {
        .min, .max, .pow => 2,
        .ternary => 3,
        else => 1,
    };
    if (argc != want) return error.WrongArity;
    return switch (f) {
        .ternary => .sel,
        .ln, .log => .ln,
        .agauss, .gauss, .unif, .aunif, .limit, .table, .other => error.UnsupportedFunction,
        inline else => |g| @field(tape.Code, @tagName(g)),
    };
}

/// Source waveform shapes; the tag is the model's `waveform` code (0 is DC only).
const Wave = enum(u8) { pulse = 1, sin = 2, exp = 3, pwl = 4, sffm = 5, am = 6 };

/// The waveform a source keyword names, case-insensitively.
fn waveKind(name: []const u8) ?Wave {
    const map = std.StaticStringMap(Wave).initComptime(.{
        .{ "pulse", .pulse }, .{ "sin", .sin },   .{ "exp", .exp },
        .{ "pwl", .pwl },     .{ "sffm", .sffm }, .{ "am", .am },
    });
    var buf: [8]u8 = undefined;
    if (name.len > buf.len) return null;
    return map.get(std.ascii.lowerString(&buf, name));
}

/// Field name of slot `k` of a flattened Verilog-A array. FastVAF turns
/// `parameter real pwl_times[0:63]` into 64 scalar Model fields named with
/// the escaped subscript (`[` is `Z5b`, `]` is `Z5d`; see
/// modules/FastVAF/src/naming.zig), so the slot is picked at comptime.
fn pwlSlot(comptime base: []const u8, comptime k: usize) []const u8 {
    // 2 arrays x 64 slots of comptime std.fmt exceed the default quota.
    @setEvalBranchQuota(200_000);
    return std.fmt.comptimePrint("{s}Z5b{d}Z5d", .{ base, k });
}

/// PWL table capacity, read off the struct so it follows `max_pwl` in the .va.
fn pwlCapacity(comptime T: type) usize {
    return slotCount(T, "pwl_times");
}

/// Slots of the flattened Verilog-A array `base` in `T`.
fn slotCount(comptime T: type, comptime base: []const u8) usize {
    comptime var n: usize = 0;
    inline while (@hasField(T, pwlSlot(base, n))) : (n += 1) {}
    return n;
}

/// Writes the card's waveform (group or parenless spelling) into `target`,
/// a source Model or Instance; a no-op on a struct without `waveform`.
fn applySourceWaveform(target: anytype, dev: Device) void {
    const T = @TypeOf(target.*);
    if (comptime !@hasField(T, "waveform")) return;
    var i: usize = 0;
    while (i < dev.positional.len) : (i += 1) {
        switch (dev.positional[i]) {
            .group => |group| {
                const kind = waveKind(group.name) orelse continue;
                applyWaveArgs(T, target, kind, group.args);
            },
            // Parenless spelling (`vs a 0 dc=0 sin 0 50 100k`): the keyword is
            // a bare positional name and its args are the numeric positionals
            // that follow.
            .name => |nm| {
                const kind = waveKind(nm) orelse continue;
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

fn applyWaveArgs(comptime T: type, target: anytype, kind: Wave, args: []const Value) void {
    target.waveform = @intFromEnum(kind);
    switch (kind) {
        // `PWL(T1 V1 T2 V2 ...)`: (time, value) pairs into the flattened
        // table. A non-numeric arg leaves its slot at the default; ngspice's
        // `r=`/`td=` suffixes are card pairs that bindSource maps onto
        // `pwl_repeat`/`pwl_td`.
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

/// Sets `dc` to the waveform's t = 0 value (each pre-TD branch of
/// vsource.va/isource.va): PULSE/EXP hold their first level, SIN is
/// VO + VA*sin(2*pi*phase/360), PWL its first point. AM starts at 0, the
/// `dc` default already.
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
        @intFromEnum(Wave.pulse) => rd(target.*, "pulse_v1", "pulse_i1"),
        @intFromEnum(Wave.sin) => rd(target.*, "sin_vo", "sin_ioff") +
            rd(target.*, "sin_va", "sin_iamp") *
                @sin(2.0 * std.math.pi * rd(target.*, "sin_phase", "sin_phase") / 360.0),
        @intFromEnum(Wave.exp) => rd(target.*, "exp_v1", "exp_i1"),
        @intFromEnum(Wave.pwl) => rd(target.*, pwlSlot("pwl_values", 0), pwlSlot("pwl_values", 0)),
        // ngspice's DCOP evaluates SFFM at time 0: the V source is 0 there
        // (vsrcload.c:271-274), the I source has no delay and reads its phases
        // one slot early (isrcload.c:222-252, see isource.va).
        @intFromEnum(Wave.sffm) => if (comptime !@hasField(T, "sffm_fm") or T == devices.vsource.Model or T == devices.vsource.Instance) 0 else blk: {
            const mdi = if (target.sffm_mdi > target.sffm_fc / target.sffm_fm)
                target.sffm_fc / target.sffm_fm
            else
                @max(target.sffm_mdi, 0);
            break :blk target.sffm_vo + target.sffm_va *
                @sin(target.sffm_phasem * std.math.pi / 180.0 + mdi * @sin(target.sffm_td * std.math.pi / 180.0));
        },
        else => return,
    };
    target.dc = @floatCast(v);
}

/// Positional waveform args onto fields; arg k goes to `field_pairs[2k]`,
/// the V-source name, or else `field_pairs[2k + 1]`, the I-source name.
fn applyGroupArgs(comptime T: type, target: anytype, args: []const Value, comptime field_pairs: []const []const u8) void {
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

/// (V-source field, I-source field) per positional arg of waveform `w`.
fn fieldPairs(comptime w: Wave) []const []const u8 {
    return switch (w) {
        .pulse => &.{ "pulse_v1", "pulse_i1", "pulse_v2", "pulse_i2", "pulse_td", "pulse_td", "pulse_tr", "pulse_tr", "pulse_tf", "pulse_tf", "pulse_pw", "pulse_pw", "pulse_per", "pulse_per", "pulse_phase", "pulse_phase" },
        .sin => &.{ "sin_vo", "sin_ioff", "sin_va", "sin_iamp", "sin_freq", "sin_freq", "sin_td", "sin_td", "sin_theta", "sin_theta", "sin_phase", "sin_phase" },
        .exp => &.{ "exp_v1", "exp_i1", "exp_v2", "exp_i2", "exp_td1", "exp_td1", "exp_tau1", "exp_tau1", "exp_td2", "exp_td2", "exp_tau2", "exp_tau2" },
        .pwl => &.{},
        // ngspice 44 order (vsrcload.c:235-249): FM third, FC fifth.
        .sffm => &.{ "sffm_vo", "sffm_vo", "sffm_va", "sffm_va", "sffm_fm", "sffm_fm", "sffm_mdi", "sffm_mdi", "sffm_fc", "sffm_fc", "sffm_td", "sffm_td", "sffm_phasem", "sffm_phasem", "sffm_phasec", "sffm_phasec" },
        .am => &.{ "am_va", "am_va", "am_vo", "am_vo", "am_mf", "am_mf", "am_fc", "am_fc", "am_td", "am_td", "am_phasec", "am_phasec", "am_phases", "am_phases" },
    };
}

/// Rows of `D`'s ports from the card's pins; missing pins are ground.
fn deviceNodes(nb: *NetBuilder, comptime D: type, dev: Device) ![D.num_ports]u32 {
    var out: [D.num_ports]u32 = undefined;
    inline for (0..D.num_ports) |idx| {
        out[idx] = if (idx < dev.pins.len) try nb.rowOf(dev.pins[idx]) else GROUND;
    }
    return out;
}

/// The model card's LEVEL, 1 when absent.
fn modelLevel(dev: Device) !u16 {
    if (dev.model) |m| {
        if (try numericParameter(m.kv, "level")) |l| return try castField(u16, l);
    }
    return 1;
}

/// Row `Builder.addDevice` gave `D`'s internal unknown `tag`, where `end`
/// is `b.n` sampled right after the call. Internal rows follow `D.U` order
/// and end at `end`, so the precondition is that no internal after `tag`
/// collapsed onto another node. Counting from the end, not from `b.n`
/// before the call, keeps it right when the card's own pins or probed nets
/// take fresh rows inside the call, and when an earlier internal collapses.
///
/// VerA names a Verilog-A `branch (a, b)` as the U member `flowZ28aZ2cbZ29`
/// (`(` = Z28, `,` = Z2c, `)` = Z29). Naming the member rather than writing
/// `first + 1` makes a wrong branch a compile error instead of a mislabelled
/// current column: ccvs declares two branches, the sense one first.
fn internalRow(comptime D: type, comptime tag: []const u8, end: u32) u32 {
    const off = comptime blk: {
        for (@typeInfo(D.U).@"enum".fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, tag)) {
                if (i < D.num_ports) @compileError(@typeName(D) ++ ": `" ++ tag ++ "` is a port, not an internal unknown");
                break :blk @typeInfo(D.U).@"enum".fields.len - i;
            }
        }
        @compileError(@typeName(D) ++ ": no unknown named `" ++ tag ++ "`");
    };
    return end - @as(u32, @intCast(off));
}

fn copyNames(arena: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copied = try arena.alloc([]const u8, names.len);
    for (names, copied) |name, *copy| copy.* = try arena.dupe(u8, name);
    return copied;
}

fn positionalNumber(dev: Device, index: usize) ?f64 {
    return argNumber(dev.positional, index);
}

fn positionalName(dev: Device, index: usize) ?[]const u8 {
    if (index >= dev.positional.len) return null;
    return switch (dev.positional[index]) {
        .name => |n| n,
        else => null,
    };
}

fn argNumber(args: []const Value, index: usize) ?f64 {
    if (index >= args.len) return null;
    return valueNumber(args[index]);
}

fn kvNumber(kv: []const Kv, key: []const u8) ?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return valueNumber(item.value);
    return null;
}

/// A source card's DC value: `dc=`, `DC v`, `DC(v)` or the first bare
/// number not owed to AC/DISTOF. Null when the card gives none.
fn sourceDc(dev: Device) ?f64 {
    if (kvNumber(dev.kv, "dc")) |dc| return dc;
    // Numbers still owed to a preceding AC/DISTOF keyword (mag [phase]).
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
                skip = 2;
            }
        },
        else => {},
    };
    return null;
}

/// The RF port of a V card (`VP1 in 0 DC 0 AC 1 portnum 1 z0 50`, or an
/// HSPICE P card's `port=1`), null when `portnum` is not given (ngspice
/// vsrctemp.c:74-82). `z0` defaults to 50 ohm.
/// Both `portnum 1` and `portnum=1` are accepted. A given `portnum` outside
/// 1..1024 or a non-positive `z0` is an error, not a plain source.
fn sourcePort(dev: Device) !?struct { num: u16, z0: f64, band: requests.Port.Band } {
    const num_f = blk: {
        if (kvNumber(dev.kv, "portnum") orelse kvNumber(dev.kv, "port")) |v| break :blk v;
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
    if (!(num_f >= 1) or num_f > 1024 or !(z0 > 0)) return error.InvalidAnalysisArguments;
    const h = kvNumber(dev.kv, "hblin_h") orelse 0;
    const s = kvNumber(dev.kv, "hblin_s") orelse 1;
    if (h != @trunc(h) or @abs(h) > 1024 or @abs(s) != 1) return error.InvalidAnalysisArguments;
    return .{ .num = @intFromFloat(num_f), .z0 = z0, .band = .{ .harmonic = @intFromFloat(h), .sign = @intFromFloat(s) } };
}

/// The `AC` spec of a source card as its complex excitation
/// mag * e^(j*phase*pi/180); null when the card names no `AC`, so an .ac run
/// does not drive it (ngspice vsrcacld.c:171, isrcacld.c:36). Bare `AC` is
/// mag 1 phase 0 and `AC mag` is phase 0 (vsrcpar.c:59-72, vsrctemp.c:38-43).
/// Phase is in degrees.
fn sourceAc(dev: Device) ?struct { re: f64, im: f64 } {
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

/// `DISTOF1 [mag [phase]]` or `DISTOF2 ...` (`key`) on a source card
/// (ngspice vsrcpar.c:180-205): the bare keyword is mag 1 phase 0, one
/// number sets the magnitude, two set both. `{0, 0}` when the card never
/// names it, so it is no drive.
fn sourceDisto(dev: Device, key: []const u8) [2]f64 {
    if (kvNumber(dev.kv, key)) |mag| return .{ mag, 0 };
    for (dev.positional, 0..) |pos, idx| switch (pos) {
        .name => |name| if (std.mem.eql(u8, name, key)) return .{
            positionalNumber(dev, idx + 1) orelse 1.0,
            positionalNumber(dev, idx + 2) orelse 0.0,
        },
        else => {},
    };
    return .{ 0, 0 };
}

/// True when every float in `value`, nested arrays and structs included, is
/// finite. Setup-time only.
fn finiteLineCoefficients(value: anytype) bool {
    switch (@typeInfo(@TypeOf(value))) {
        .float => return std.math.isFinite(value),
        .bool => {},
        .array => for (value) |item| {
            if (!finiteLineCoefficients(item)) return false;
        },
        .@"struct" => inline for (std.meta.fields(@TypeOf(value))) |field| {
            if (!finiteLineCoefficients(@field(value, field.name))) return false;
        },
        else => @compileError("unexpected native line coefficient type"),
    }
    return true;
}

/// Reads the CPL matrix `key` into `out` and returns its entry count: the
/// packed upper triangle is the `key=` value and the unnamed values after it.
/// 0 when the card has no `key`.
fn cplVector(kv: []const Kv, key: []const u8, out: []f64) !usize {
    for (kv, 0..) |entry, start| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        var i = start;
        var n: usize = 0;
        while (i < kv.len and (i == start or kv[i].key.len == 0)) : (i += 1) {
            const value = valueNumber(kv[i].value) orelse return error.InvalidParameterValue;
            if (!std.math.isFinite(value)) return error.NonFiniteParameter;
            if (n == out.len) return error.UnsupportedTransmissionLineParameters;
            out[n] = value;
            n += 1;
        }
        return n;
    }
    return 0;
}

fn valueNumber(value: Value) ?f64 {
    return switch (value) {
        .num => |n| n,
        else => null,
    };
}

/// The number `key=` gives, null when absent. A present key that is not a
/// finite number is an error, never a silent fall back to the default.
fn numericParameter(kv: []const Kv, key: []const u8) !?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) {
        const value = valueNumber(item.value) orelse return error.UnresolvedParameter;
        if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        return value;
    };
    return null;
}

/// Binds card pairs onto a built-in's Model or Instance through the
/// device's own binder, the one every loaded device uses too.
fn applyKv(target: anytype, kv: []const Kv) !void {
    const name, const is_model = comptime ownerOf(@TypeOf(target.*));
    const vt = device.vtable(name);
    try bindKv(if (is_model) vt.bind_model else vt.bind_instance, @ptrCast(target), kv);
}

/// Binds `kv` onto a param blob. A non-numeric value reaches the binder as
/// null, which it rejects for a key it knows.
fn bindKv(bind: *const fn ([*]u8, []const batch.Param) batch.BindStatus, blob: [*]u8, kv: []const Kv) !void {
    var fallback = std.heap.stackFallback(4096, std.heap.smp_allocator);
    const a = fallback.get();
    const params = try a.alloc(batch.Param, kv.len);
    defer a.free(params);
    for (kv, params) |item, *p| p.* = .{ .key = item.key, .value = valueNumber(item.value) };
    try bind(blob, params).unwrap();
}

/// The catalog device whose Model (true) or Instance (false) `T` is.
fn ownerOf(comptime T: type) struct { []const u8, bool } {
    for (device.catalog) |e| {
        if (@hasDecl(e.type, "Model") and e.type.Model == T) return .{ e.name, true };
        if (@hasDecl(e.type, "Instance") and e.type.Instance == T) return .{ e.name, false };
    }
    @compileError(@typeName(T) ++ " is no catalog device's Model or Instance");
}

/// Private helpers the frontend tests reach; empty outside tests.
pub const test_access = if (@import("builtin").is_test) .{
    .applySourceWaveform = applySourceWaveform,
    .pwlSlot = pwlSlot,
    .pwlCapacity = pwlCapacity,
    .Wave = Wave,
    .castField = castField,
    .bindKv = bindKv,
} else {};
