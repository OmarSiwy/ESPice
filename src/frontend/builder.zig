//! Builder: netlist hypergraph → frozen device.Circuit.
//!
//! Frontend construction owns net-to-row mapping, subcircuit tagging, BBD
//! permutation and device accumulation through the device ABI. Every device
//! type, built-in or loaded, is a `device.Library` id; `Circuit.freeze`
//! freezes the pattern; analysis owns numerical execution.

const std = @import("std");
const requests = @import("core").query;
const numerics = @import("core").numerics;
const devices = @import("spice.zig");
const device = @import("device");
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

// ---------------------------------------------------------------------------
// Builder: mutable netlist. compile() freezes it into a device.Circuit.
// ---------------------------------------------------------------------------
const MULTI_INSTANCE: u32 = std.math.maxInt(u32);

pub const Builder = struct {
    gpa: std.mem.Allocator,
    lib: *const Library,
    n: u32,
    /// Per row, the net name it came from ("" for internal unknowns).
    /// Borrowed: copied into the circuit's intern table at the freeze.
    node_labels: std.ArrayList([]const u8),
    protos: std.ArrayList(Proto),
    /// Library type of each proto, parallel to `protos`.
    proto_types: std.ArrayList(DeviceType) = .empty,
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
    /// the PARSE arena, like `NetBuilder.v` — copy before it dies.
    cards: std.ArrayList(requests.CardRef) = .empty,
    /// Per-device-type instance counter — the ordinal `ParamRef.index` carries.
    /// Kept here rather than read off a `ProtoStore` because a GENERATED device
    /// is instantiated through `vt.proto_add` into the device object's own
    /// store, which this compilation unit deliberately cannot name. Counted for
    /// EVERY add, card or not, so the ordinal stays in lockstep with the store.
    card_counts: std.ArrayList(u32) = .empty,

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

    /// Only for a Builder that was never compiled.
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
        self.node_type.deinit(self.gpa);
        self.* = undefined;
    }

    /// Tag a node as belonging to a subcircuit instance.
    /// If a node is tagged by multiple instances, it becomes a coupling node.
    fn tagNodeInstance(self: *Builder, node: u32, subckt_type: u16, subckt_instance: u32) !void {
        if (node == GROUND) return;
        if (self.node_instance.items.len <= node) {
            const grow = node + 1 - self.node_instance.items.len;
            try self.node_instance.appendNTimes(self.gpa, 0, grow);
            try self.node_type.appendNTimes(self.gpa, 0, grow);
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
                try instance_list.append(gpa, .{ .inst = inst, .typ = nt[i], .at = 0 });
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

    /// Reserve label capacity ahead of a known net count.
    pub fn reserveNodes(self: *Builder, expected: u32) !void {
        if (expected == std.math.maxInt(u32)) return error.TooManyNodes;
        try self.node_labels.ensureTotalCapacity(self.gpa, expected + 1);
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
            if (self.card.len != 0) try self.cards.append(self.gpa, .{ .type = t, .index = ordinal.*, .name = self.card });
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

    /// Find-or-create the one proto (future batch) of device type `t`.
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
        var perm: ?[]const u32 = undefined;
        return self.compilePerm(&perm);
    }

    /// Freeze into a Circuit, consuming the Builder. Protos and labels are
    /// renumbered by the BBD permutation (old id -> frozen id), which goes to
    /// `perm_out`, or null when there was none. Any row the caller recorded
    /// before the call must be mapped through it.
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
            const old_labels = try gpa.alloc([]const u8, n);
            defer gpa.free(old_labels);
            @memcpy(old_labels, self.node_labels.items);
            for (old_labels, perm) |label, new_i| self.node_labels.items[new_i] = label;
            perm_out.* = perm; // owned by the caller from here
            bbd.perm = null; // ownership moved; disarm the errdefer
        }

        // Frozen intern table: one byte blob + n+1 offsets.
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

        self.deinitStorage(); // Circuit.freeze consumed the protos

        return ckt;
    }
};

// ---------------------------------------------------------------------------
// Netlist -> Builder: device selection, card values, waveforms, HDL devices.
// ---------------------------------------------------------------------------

/// The runtime-loaded (.hdl) module a card's first positional names, directly
/// or through its `.model` card's kind (`.model psp103n psp103va ...`).
fn loadedType(lib: *const Library, dev: Device) ?DeviceType {
    const name = positionalName(dev, 0) orelse return null;
    return lib.find(name) orelse if (dev.model) |m| lib.find(m.kind) else null;
}

/// Write a POSITIONAL card value (`R1 a b 1k`, `F1 … 2.0`) to the named
/// parameter on whichever of Model/Instance declares it (`applyKv` covers
/// `name=value`). VerA puts every Verilog-A `parameter` on Model; resolving
/// both keeps binding if a model moves one. False when neither declares it.
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
    nl: Netlist,
    /// Circuit row of each net, 0 until a device touches it (ground is 0
    /// anyway). Rows follow stamping order, not net order.
    rows: []u32,
    /// Borrowed F/H/W control names, sorted case-insensitively for V sensing.
    sensed_sources: []const []const u8,

    /// One row per V card.
    v: std.MultiArrayList(VCard) = .empty,
    /// Branch-current probes that are neither a V card nor an inductor. ngspice
    /// gives every MNA branch unknown an `i(<card>)` column (vcvsset.c:41-46,
    /// ccvsset.c:41-46, asrcsetup.c:78-83 for a V-mode B); F, G, S and an
    /// I-mode B stamp no branch and have none.
    br: std.MultiArrayList(struct { name: []const u8, row: u32 }) = .empty,
    /// `R2 2 0 5K ac=15k`: an AC-only resistance (ngspice restemp.c:112-118),
    /// keyed by card because instance ordinals only exist after the freeze.
    ac_res: std.MultiArrayList(struct { name: []const u8, value: f64 }) = .empty,
    /// One row per I card, nodes `+` then `−`. An I source has no branch row,
    /// so a `.tf` driven from one excites the node pair.
    i: std.MultiArrayList(struct { name: []const u8, pos: u32, neg: u32 }) = .empty,
    /// One row per source carrying an `AC` spec; every row drives the same rhs
    /// (ngspice CKTacLoad, acan.c:471-490). A card without `AC` has no row.
    /// An entry subtracts from `pos` and adds to `neg` under Circuit.rhs's
    /// residual sign. An I card is (n+, n−); a V card drives its branch row
    /// only (vsrcacld.c:175), so it is (GROUND, branch). GROUND rows are skipped.
    ac: std.MultiArrayList(struct { pos: u32, neg: u32, re: f64, im: f64 }) = .empty,
    /// One row per L card; `value` is the inductance, for K cards' M = k·√(L1·L2).
    l: std.MultiArrayList(struct { name: []const u8, branch: u32, value: f64 }) = .empty,
    /// F/H/W/K cards, added after every other card so V and L rows exist.
    deferred: std.ArrayList(Device) = .empty,

    source_node: u32 = GROUND,
    source_branch: u32 = GROUND,

    /// Topology diagnosis (ngspice CKTsetup-class checks), one row per
    /// netlist-named node; internal expansion nodes never enter. `dc`: an
    /// element stamps a DC path there (all but capacitors and current sources);
    /// `cur`: an I source touches it. V/L cards are DC shorts: `uf`/`pot` form a
    /// weighted union-find with `pot` = v(x) − v(parent). A cycle of shorts is an
    /// error only when its KVL sum is inconsistent (V1=5 ∥ V2=3).
    topo: std.MultiArrayList(struct { seen: bool, dc: bool, cur: bool, uf: u32, pot: f64 }) = .empty,

    pub const VCard = struct {
        name: []const u8,
        pos: u32,
        /// F/H/W models take the sensed source's node pair `(cp, cn)`.
        neg: u32,
        branch: u32,
        /// A source sensed by F/H/W is not stamped; the sensing model's own
        /// `branch (cp,cn) ctrl` drives `vsense` = this value.
        dc: f64,
        /// `DISTOF1 [mag [phase]]`, `.disto`'s F1 drive (ngspice
        /// cktdisto.c:100-117). `{0, 0}` = not named. Degrees.
        distof1: [2]f64,
        /// `.sp` port index, 1-based; 0 = not a port (vsrcdefs.h:104-105).
        portnum: u16,
        z0: f64,
    };

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
        return .{ .arena = arena, .b = b, .nl = nl, .rows = rows, .sensed_sources = sensed.items };
    }

    /// The row of net `v`, allocated on first touch.
    fn rowOf(self: *NetBuilder, v: netlist.VertexId) !u32 {
        const row = &self.rows[v.index()];
        if (row.* != 0 or v == netlist.ground) return row.*;
        row.* = try self.b.addNode();
        self.b.node_labels.items[row.*] = self.nl.netName(v);
        return row.*;
    }

    /// The row of net index `net` after the freeze; NO row for a net no
    /// device touched, or for `netlist.none`.
    pub fn frozenRow(self: *const NetBuilder, net: u32) u32 {
        if (net == netlist.none) return netlist.none;
        if (net == 0) return GROUND;
        const r = self.rows[net];
        return if (r == 0) netlist.none else r;
    }

    /// Tag every net a subcircuit device touches with its instance, for the
    /// BBD permutation.
    pub fn tagSubcircuitNodes(self: *NetBuilder) !void {
        const nl = &self.nl;
        for (nl.order) |e| {
            const dev = nl.device(e);
            if (dev.subckt_instance == 0) continue;
            for (dev.pins) |pin| {
                const r = self.rows[pin.index()];
                if (r != 0) try self.b.tagNodeInstance(r, dev.subckt_type, dev.subckt_instance);
            }
        }
    }

    /// Runtime (dlopen'd) VA/V devices — card shape `<name> node... <model>`,
    /// bound through the dyn vtable. Param blobs live on the arena until
    /// proto_add copies them.
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
            // Card kv overrides the .model card. VA parameters are Model fields,
            // so card values go to the model blob too.
            try bindKv(vt.bind_model, mblob.ptr, dev.kv);
            // LRM 6.3.4/3.4.5: recompute dependent parameters and localparams after
            // the last write and before `collapse`/`proto_add` read the blob.
            if (vt.derive) |df| df(mblob.ptr);
            const iblob = try arena.alignedAlloc(u8, .@"16", vt.instance_size);
            vt.init_instance(iblob.ptr);
            try bindKv(vt.bind_instance, iblob.ptr, dev.kv);

            // Same port/internal-node policy as Builder.addDevice.
            const nodes = try arena.alloc(u32, vt.n_u);
            for (0..vt.num_ports) |p|
                nodes[p] = if (p < dev.pins.len) try self.rowOf(dev.pins[p]) else GROUND;
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

    fn addBranchProbe(self: *NetBuilder, name: []const u8, row: u32) !void {
        try self.br.append(self.arena, .{ .name = name, .row = row });
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

    /// The deck's `.sp` ports, ordered by `portnum` — ngspice sorts
    /// `CKTrfPorts` the same way (vsrctemp.c:110-124) and rejects a gapped or
    /// duplicated numbering as "incorrect port ordering" (vsrctemp.c:143-160).
    /// Empty when no V card carries `portnum`, which leaves `.sp` on its
    /// one-port fallback.
    pub fn portList(self: *const NetBuilder, gpa: std.mem.Allocator) ![]requests.Port {
        var n_ports: usize = 0;
        for (self.v.items(.portnum)) |num| n_ports = @max(n_ports, num);
        if (n_ports == 0) return &.{};
        const ports = try gpa.alloc(requests.Port, n_ports);
        for (ports) |*p| p.branch = std.math.maxInt(u32); // "unset" marker
        const v = self.v.slice();
        for (v.items(.portnum), v.items(.pos), v.items(.branch), v.items(.z0)) |num, node, br, z0| {
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
        const T = @TypeOf(target.*);
        if (comptime !@hasField(T, "pulse_tr")) return;
        var tstep: f64 = 1e-9;
        var tstop: f64 = 1e30;
        for (self.nl.deck.analyses) |dir| {
            if (dir.kind != .tran) continue;
            const a0 = argNumber(dir.args, 0);
            const a1 = argNumber(dir.args, 1);
            if (a1 orelse a0) |ts| tstop = ts;
            // A malformed card (`.tran xyz 1u`) keeps the default step; the
            // query check rejects it after the build.
            tstep = if (a1 != null) a0 orelse tstep else tstop / 100.0;
            break;
        }
        // Only a PULSE waveform gets the TRANinit fill (ngspice runs it per
        // PULSE function). Any other waveform parks TD past every tstop so its
        // unused pulse fields mint no breakpoint.
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

    /// V and L first so F/H/W/K (deferred until the end) can find them.
    pub fn build(self: *NetBuilder) !void {
        for ("vlifhwkabcdegjmnopqrstuxyz") |c| for (self.nl.bucket(c)) |e| try self.addDevice(self.nl.device(e));
        try self.resolveDeferred();
        try self.topoCheck();
    }

    // -- Topology diagnosis helpers ---------------------------------------

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

    /// Classify one card's nodes. `kind`: .dc marks a DC path, .cap marks
    /// presence only, .cur marks a current source, .short additionally
    /// unions the first two nodes as a DC short of value `vshort`
    /// (v(node0) − v(node1) = vshort) and rejects an INCONSISTENT cycle.
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
                // v(b) = pot_b + pot[rb] must equal v(a) − vshort.
                self.topo.items(.uf)[b_.root] = a.root;
                self.topo.items(.pot)[b_.root] = a.pot - vshort - b_.pot;
            }
        }
    }

    /// Current-source cutsets cannot satisfy static KCL. Capacitor-only nodes
    /// reach the operating-point transient fallback, as in ngspice OPtran.
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
        // Attributes every instance this card expands into (URC, CPL) to it.
        self.b.card = dev.name;
        defer self.b.card = "";
        // HDL devices are added by addDynDevices after the freeze-order pass.
        // An opaque model's nodes count as a DC path for the topology check.
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
                // current between two sources across one node pair.
                const sensed = std.sort.binarySearch([]const u8, self.sensed_sources, dev.name, std.ascii.orderIgnoreCase) != null;
                if (!sensed) try self.b.addDevice(devices.vsource, bound[0], bound[1], nodes);
                const port = if (sensed) null else try sourcePort(dev);
                try self.v.append(self.arena, .{
                    .name = dev.name,
                    .pos = nodes[0],
                    .neg = if (nodes.len > 1) nodes[1] else 0,
                    .branch = br,
                    .dc = bound[0].dc,
                    .distof1 = sourceDistoF1(dev),
                    .portnum = if (port) |p| p.num else 0,
                    .z0 = if (port) |p| p.z0 else 0,
                });
                // A replaced source stamps nothing, so it cannot be the
                // reference the .op ladder anchors on — nor can it be driven:
                // `br` is the row the NEXT card got, not one this source owns.
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
                try self.b.addDevice(devices.isource, bound[0], bound[1], nodes);
                if (sourceAc(dev)) |ac| try self.ac.append(self.arena, .{ .pos = nodes[0], .neg = nodes[1], .re = ac.re, .im = ac.im });
                try self.i.append(self.arena, .{ .name = dev.name, .pos = nodes[0], .neg = if (nodes.len > 1) nodes[1] else GROUND });
            },
            'f', 'h', 'w', 'k' => try self.deferred.append(self.arena, dev),
            'b' => {
                const first = self.b.n;
                // Only the V-mode B gets a branch: ngspice guards its
                // `CKTmkCur` on `ASRCtype == ASRC_VOLTAGE` (asrcset.c:81-88),
                // so an `i=` B card has no branch unknown and no i() column.
                // espice's 4-port bsource declares the unknown either way; the
                // I-mode one is left unprobed rather than published as a
                // permanent zero ngspice never writes.
                if (try addBsource(self, dev))
                    try self.addBranchProbe(dev.name, internalRow(devices.bsource, "flowZ28pZ2cnZ29", first));
            },
            'p' => try self.addCpl(dev),
            'o' => try self.addLossyLine(dev),
            'y' => try self.addTxl(dev),
            'u' => try self.addUrc(dev),
            'e' => {
                const first = self.b.n;
                try self.addByLetter(letter, dev);
                try self.addBranchProbe(dev.name, internalRow(devices.vcvs, "flowZ28pZ2cnZ29", first));
            },
            else => try self.addByLetter(letter, dev),
        }
    }

    fn addTxl(self: *NetBuilder, dev: Device) !void {
        route: {
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
            if (!std.math.isFinite(r) or !std.math.isFinite(l) or !std.math.isFinite(g) or !std.math.isFinite(c) or !std.math.isFinite(len) or g < 0) break :route;
            if (r <= 0 or l <= 0 or c <= 0 or len <= 0) break :route;
            if (r / l > 1.6e10) break :route; // inp2y's 3-pi RC expansion case
            if (!std.math.isFinite(r * len) or r * len <= 0) break :route;
            const fit = devices.txl_native.fitLine(r, l, g, c, len);
            if (!fit.ok or fit.taul <= 0 or fit.sqtCdL <= 0 or !finiteLineCoefficients(fit)) break :route;
            const nm: devices.txl_native.Model = .{ .r = r, .l = l, .g = g, .c = c, .len = len };
            const n1 = try self.rowOf(dev.pins[0]);
            const n2 = try self.rowOf(dev.pins[2]);
            try self.b.addDevice(devices.txl_native, nm, .{}, [2]u32{ n1, n2 });
            // ngspice writes duplicate i(Y) names; the named oracle retains
            // the final (far-end) branch, as it does for CPL below.
            try self.addBranchProbe(dev.name, self.b.n - 1);
            return;
        }
        return error.UnsupportedTransmissionLineParameters;
    }

    /// LTRA (O card). Routing per ngspice LTRAsetup §1.1:
    ///   RLC (r,l,c > 0, g = 0) and RC (r,c > 0, l = g = 0) → the native
    ///     recursive-convolution device (devices.ltra_native, ngspice's real
    ///     h1'/h2/h3' method — history, coefficients, chop, step limit);
    ///   LC (r = g = 0) → one exact Bergeron ideal line (tline.va);
    ///   RG and rejects → lossy_tline.va (exact hyperbolic two-port / $error).
    fn addLossyLine(self: *NetBuilder, dev: Device) !void {
        if (dev.pins.len != 4) return error.InvalidTransmissionLinePorts;
        var model: devices.lossy_tline.Model = .{};
        if (dev.model) |m| {
            try applyKv(&model, m.kv);
            // TXL model cards spell the line length `length=`; the
            // lossy_tline field is `len` (same alias addSingleDevice has).
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

        // Only the static RG branch of lossy_tline.va is equivalent. Never
        // let an unsupported dynamic line silently use its RC/RLC approximation.
        if (!wave and !rc) {
            if (model.r > 0 and model.g > 0 and model.l == 0 and model.c == 0) {
                const rg = model.r * model.g;
                if (rg == 0) return error.UnsupportedTransmissionLineParameters;
                const gl = len * @sqrt(rg);
                const sinhc = if (gl > 1e-9) std.math.sinh(gl) / gl else 1.0 + gl * gl / 6.0;
                const zs = r_t * sinhc;
                if (gl <= 0 or !finiteLineCoefficients(.{ gl, sinhc, std.math.cosh(gl), zs, zs * (1.0 + 1e-12) }))
                    return error.UnsupportedTransmissionLineParameters;
                deriveModel(devices.lossy_tline, &model, self.b.nom_temp_c);
                return self.b.addDevice(devices.lossy_tline, model, .{}, try deviceNodes(self, devices.lossy_tline, dev));
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
            return self.b.addDevice(devices.ltra_native, nm, .{}, ports);
        }

        // Lossless LC: one exact Bergeron ideal line.
        const t_model: devices.tline.Model = .{
            .z0 = @floatCast(@sqrt(l_t / c_t)),
            .td = @floatCast(@sqrt(l_t * c_t)),
        };
        if (!finiteLineCoefficients(.{ t_model.z0, t_model.td }) or t_model.z0 <= 0 or t_model.td <= 0)
            return error.UnsupportedTransmissionLineParameters;
        try self.b.addDevice(devices.tline, t_model, .{}, ports);
    }

    /// URC (U card): `Uxxx n1 n2 ngnd model [l=len] [n=lumps]`. ngspice has no
    /// URC kernel either — URCsetup expands the card at setup into a ladder of
    /// ordinary R/C lumps (diodes when ISPERL is set), sized geometrically by
    /// K from both ends toward the middle so the totals telescope to exactly
    /// L*RPERL and L*CPERL. Same expansion here, at build time, into the
    /// existing resistor/capacitor/diode batches.
    fn addUrc(self: *NetBuilder, dev: Device) !void {
        // URC model params + defaults (urcsetup.c). A missing .model card is
        // legal in ngspice (default U model) — all defaults apply.
        var k: f64 = 1.5;
        var fmax: f64 = 1e9;
        var rperl: f64 = 1000;
        var cperl: f64 = 1e-12;
        var isperl: f64 = 0;
        var rsperl: f64 = 0;
        if (dev.model) |m| {
            k = kvNumber(m.kv, "k") orelse k;
            fmax = kvNumber(m.kv, "fmax") orelse fmax;
            rperl = kvNumber(m.kv, "rperl") orelse rperl;
            cperl = kvNumber(m.kv, "cperl") orelse cperl;
            isperl = kvNumber(m.kv, "isperl") orelse isperl;
            rsperl = kvNumber(m.kv, "rsperl") orelse rsperl;
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

        const pos = if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND;
        const neg = if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND;
        const gnd = if (dev.pins.len > 2) try self.rowOf(dev.pins[2]) else GROUND;

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

    /// `R1 a b 1k`: the positional value goes to the Verilog-A parameter
    /// `value_field` (`r`, `c`, `l`). `alias` is a card spelling only
    /// (`R1 a b resist=1k`), never a field.
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
        var value = positionalNumber(dev, 0) orelse kvNumber(dev.kv, value_field) orelse kvNumber(dev.kv, alias) orelse blk: {
            // Semiconductor resistor model card (ngspice restemp.c
            // RESupdate_conduct): R = RSH·(L−2·SHORT)/(W−2·NARROW), W
            // defaulting to the model's DEFW. A zero/negative effective
            // width is ngspice's silent divide — the device reads as open.
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
                try self.ac_res.append(self.arena, .{ .name = dev.name, .value = ac_value });
            }
        }
        _ = try setParam(D, &model, &instance, value_field, value);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        const nodes = try deviceNodes(self, D, dev);
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
    fn bindSource(self: *const NetBuilder, comptime D: type, dev: Device) !struct { D.Model, D.Instance } {
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
        // but no DC value is the transient value at t = 0". Resolved here so
        // the model reads `dc` unconditionally and a .dc sweep can override it.
        if (dc == null) {
            dcFromWaveform(&model);
            dcFromWaveform(&instance);
        }
        return .{ model, instance };
    }

    fn addByLetter(self: *NetBuilder, letter: u8, dev: Device) !void {
        // Q cards arrive already normalized (addDevice), so the model name is
        // positional[0] here for every terminal count.
        switch (try resolveDeviceId(letter, dev)) {
            inline else => |comptime_id| {
                const D = devices.DeviceId.Type(comptime_id);
                const first = self.b.n;
                try addSingleDevice(self, D, dev);
                // ngspice's VBIC `i(q1)` is its excess-phase branch, made only
                // when TD > 0 (vbicsetup.c:510-525). Node xf2 carries only a
                // 1 ohm load, so that current IS v(xf2): alias the column.
                if (comptime_id == .vbic13_4t) {
                    const td = kvNumber(dev.kv, "td") orelse if (dev.model) |m| kvNumber(m.kv, "td") orelse 0 else 0;
                    if (td > 0) try self.addBranchProbe(dev.name, internalRow(D, "xf2", first));
                }
            },
        }
    }

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
            self.b.card = dev.name;
            defer self.b.card = "";
            switch (dev.kind) {
                'f' => try self.addBranchRef(devices.cccs, dev, source_index, 1.0),
                'h' => try self.addBranchRef(devices.ccvs, dev, source_index, 0.0),
                'w' => try self.addBranchRef(devices.cswitch, dev, source_index, null),
                'k' => try self.addKinduc(dev),
                else => unreachable,
            }
        }
    }

    /// CPL keeps ngspice's modal fit and accepted-step convolution for the
    /// supported dimensions. The two-conductor VA approximation is not a fallback.
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
                try self.b.addDevice(D, model, instance, nodes);
                try self.addBranchProbe(dev.name, self.b.n - 1);
                return;
            }
        }
        unreachable;
    }

    fn addBranchRef(self: *NetBuilder, comptime D: type, dev: Device, source_index: std.StringHashMapUnmanaged(u32), comptime default_gain: ?f64) !void {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        const ctrl_name = positionalName(dev, 0) orelse return error.MissingControlSource;
        const ctrl = source_index.get(ctrl_name) orelse return error.UnknownControlSource;

        var model: D.Model = .{};
        // W card: `W n+ n- Vctrl model` — model is positional[1] (positional[0]
        // is the control source). F/H put a number there, so the orelse falls
        // back to the plain model-name slot.
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

        // (p, n, cp, cn): the control port is the sensed source's own node
        // pair. The model puts a `branch (cp, cn) ctl` across it and reads
        // I(ctl), which IS the current through that source.
        const nodes = [4]u32{
            if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND,
            if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND,
            self.v.items(.pos)[ctrl],
            self.v.items(.neg)[ctrl],
        };
        const first = self.b.n;
        try self.b.addDevice(D, model, instance, nodes);

        // The sensed source's current lives on this model's control branch;
        // its `i(v...)` column reads that row (ngspice cccsset.c:47).
        self.v.items(.branch)[ctrl] = internalRow(D, "flowZ28cpZ2ccnZ29", first);
        // H also carries its own output branch, and ngspice names it i(h1).
        if (comptime @hasDecl(D, "U") and D == devices.ccvs)
            try self.addBranchProbe(dev.name, internalRow(D, "flowZ28pZ2cnZ29", first));
    }

    fn addKinduc(self: *NetBuilder, dev: Device) !void {
        if (comptime !@hasDecl(devices.kinduc, "eval")) return error.UnsupportedDevice;
        const l1_name = positionalName(dev, 0) orelse return error.KinducMissingInductor;
        const l2_name = positionalName(dev, 1) orelse return error.KinducMissingInductor;
        const li1 = findNameIndex(self.l.items(.name), l1_name) orelse return error.KinducUnknownInductor;
        const li2 = findNameIndex(self.l.items(.name), l2_name) orelse return error.KinducUnknownInductor;
        const ibr1 = self.l.items(.branch)[li1];
        const ibr2 = self.l.items(.branch)[li2];
        var model: devices.kinduc.Model = .{};
        if (positionalNumber(dev, 2)) |k| model.k = try castField(f32, k);
        if (dev.model) |m| try applyKv(&model, m.kv);
        try applyKv(&model, dev.kv);
        // K card carries the coupling coefficient k; the device stamps mutual
        // inductance M = k*sqrt(L1*L2) (ngspice INDsetup).
        model.k = try castField(f32, @as(f64, model.k) *
            @sqrt(self.l.items(.value)[li1] * self.l.items(.value)[li2]));
        try self.b.addDevice(devices.kinduc, model, .{}, [2]u32{ ibr1, ibr2 });
    }
};

// ---------------------------------------------------------------------------
// Device resolution
// ---------------------------------------------------------------------------

fn resolveDeviceId(letter: u8, dev: Device) !devices.DeviceId {
    const level = try modelLevel(dev);
    return switch (letter) {
        // `.model X VDMOS(...)` carries no LEVEL — the model KIND is the
        // dispatch (ngspice inpdomod.c does the same for VDMOS).
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

fn inferDeviceFromModel(dev: Device) !?devices.DeviceId {
    const m = dev.model orelse return null;
    const l = try modelLevel(dev);
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

/// The polarity field, under each name the models spell it. These are VerA
/// codegen output: Verilog-A `type` is a Zig primitive and becomes `typeZ`, a
/// declared `type_` becomes `typeZ5f`. A misspelled `@hasField` is silently
/// false and runs a P-type card as N-type, so do not rename them.
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
const nom_temp_field = "nom_temp__";

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
    if (comptime device.modelName(D)) |name| {
        if (device.vtable(name).derive) |f| f(@ptrCast(model));
    } else if (comptime @hasDecl(D, "derive")) D.derive(model);
}

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
    if (dev.model) |m| {
        try applyKv(&model, m.kv);
        // TXL (y-card) model cards spell the line length `length=`;
        // the lossy_tline field is `len`.
        if (comptime D == devices.lossy_tline) {
            if (kvNumber(m.kv, "length")) |length| model.len = @floatCast(length);
        }
        // Polarity comes from the model card kind, outside applyKv.
        if (eqlAny(m.kind, &.{ "pmos", "pnp", "pjf", "pmf", "phfet" })) try setPolarity(D, &model);
    }
    _ = try setParam(D, &model, &instance, "gain", positionalNumber(dev, 0) orelse 0);
    // Card `name=value` goes to both structs: VerA puts every Verilog-A
    // `parameter` (W, L included) on Model. `model` is a per-device copy, so
    // this overrides the model card for this instance only.
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);
    // §6.3.4/§3.4.5: recompute dependent parameters and localparams after the
    // last card write; explicit card values win through `__given`.
    deriveModel(D, &model, b.nom_temp_c);
    try b.addDevice(D, model, instance, try deviceNodes(self, D, dev));
}

// ---------------------------------------------------------------------------
// B-source expression extraction
// ---------------------------------------------------------------------------

/// Returns true when the card is a VOLTAGE-mode B — the only kind that owns a
/// branch-current unknown worth probing (ngspice asrcset.c:81-88).
fn addBsource(self: *NetBuilder, dev: Device) !bool {
    if (comptime !@hasDecl(devices.bsource, "eval")) return error.UnsupportedDevice;
    var model: devices.bsource.Model = .{};
    var instance: devices.bsource.Instance = .{};
    if (dev.model) |m| try applyKv(&model, m.kv);
    try applyKv(&model, dev.kv);
    try applyKv(&instance, dev.kv);

    var ctrl_probe: ?Probe = null;
    const modes = std.StaticStringMap(u1).initComptime(.{ .{ "v", 0 }, .{ "i", 1 } });
    for (dev.kv) |item| {
        model.imode = modes.get(item.key) orelse continue;
        switch (item.value) {
            .num => |value| model.c0 = try castField(@TypeOf(model.c0), value),
            .expr => |span| {
                const ops = self.nl.exprOps(span);
                ctrl_probe = extractVoltageProbe(ops);
                // Trust boundary: an expression outside the subset used to
                // compile to all-zero coefficients, a silent open circuit.
                if (!extractPolyCoeffs(ops, self.nl.consts, &model)) {
                    // (The test runner fails any test that logs an error.)
                    if (!@import("builtin").is_test) std.log.err("B-source '{s}': the {s}= expression is outside the supported subset (a polynomial of degree <= 3 in one V(p[,n]) pair, integer powers via ^, ** or pow(), times at most one tanh(k*V) factor)", .{ dev.name, item.key });
                    return error.UnsupportedBsourceExpression;
                }
            },
            else => return error.UnresolvedParameter,
        }
    }

    const nodes = [4]u32{
        if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND,
        if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND,
        if (ctrl_probe) |pr| try self.rowOf(.from(pr.p)) else GROUND,
        if (ctrl_probe) |pr| (if (pr.n != netlist.none) try self.rowOf(.from(pr.n)) else GROUND) else GROUND,
    };
    try self.b.addDevice(devices.bsource, model, instance, nodes);
    return model.imode == 0;
}

/// The first V() probe in the expression: V(p) or differential V(p,n), as
/// nets. The poly model assumes every probe names the same pair (§1.6 ceiling).
const Probe = struct { p: u32, n: u32 };

fn extractVoltageProbe(ops: []const Op) ?Probe {
    // Leaves keep their left-to-right order in postfix, so the first probe op
    // is the first probe a pre-order walk meets.
    for (ops) |op| if (op.code == .vprobe and op.a != netlist.none) return .{ .p = op.a, .n = op.b };
    return null;
}

const expr = netlist.expr;

fn isCall(op: Op, f: expr.Fn) bool {
    return op.code == .call and op.a == @intFromEnum(f);
}

/// Last op of operand `i` of the op at `end`.
fn operand(ops: []const Op, end: usize, i: usize) usize {
    var buf: [3]usize = undefined;
    return expr.operands(ops, end, &buf)[i];
}

fn extractPolyCoeffs(ops: []const Op, consts: []const f64, model: *devices.bsource.Model) bool {
    // Every V() probe must name the one control pair the model reads.
    const pair = extractVoltageProbe(ops) orelse Probe{ .p = netlist.none, .n = netlist.none };
    for (ops) |op| switch (op.code) {
        .vprobe => if (op.a == netlist.none or op.a != pair.p or op.b != pair.n) return false,
        .ident, .iprobe => return false,
        else => {},
    };
    const c = poly(ops, consts, ops.len - 1) orelse return false;
    // A single multiplicative tanh(k*vc) factor rides along as model.th
    // (the MESFET "ungated load" idiom, Is*tanh(v/Is/R)*(1+lambda*v)).
    // poly() treated it as the constant 1, so it must be a factor of the
    // whole expression, exactly once, with a linear argument.
    var n_tanh: u32 = 0;
    for (ops) |op| n_tanh += @intFromBool(isCall(op, .tanh));
    if (n_tanh > 1) return false;
    if (n_tanh == 1) {
        const arg = tanhFactorArg(ops, ops.len - 1) orelse return false;
        if ((vDegree(ops, arg) orelse return false) != 1) return false;
        model.th = @floatCast(numericCoeff(ops, consts, arg));
    }
    model.c0 = @floatCast(c[0]);
    model.c1 = @floatCast(c[1]);
    model.c2 = @floatCast(c[2]);
    model.c3 = @floatCast(c[3]);
    return true;
}

/// The argument of a tanh() that is a multiplicative factor of the whole
/// expression: descend only through products, constant divisors and unary
/// signs. null if the (sole) tanh sits anywhere else, e.g. additively.
fn tanhFactorArg(ops: []const Op, end: usize) ?usize {
    const op = ops[end];
    return switch (op.code) {
        .call => if (isCall(op, .tanh) and op.b == 1) end - 1 else null,
        .mul => tanhFactorArg(ops, operand(ops, end, 0)) orelse tanhFactorArg(ops, end - 1),
        .div => tanhFactorArg(ops, operand(ops, end, 0)),
        .neg, .not => tanhFactorArg(ops, end - 1),
        else => null,
    };
}

/// Coefficients of vc^0..vc^3; null outside the subset (degree > 3, a
/// non-constant divisor or exponent, any other function).
const Poly = [4]f64;

fn poly(ops: []const Op, consts: []const f64, end: usize) ?Poly {
    const op = ops[end];
    return switch (op.code) {
        .num => .{ consts[op.a], 0, 0, 0 },
        .vprobe => .{ 0, 1, 0, 0 },
        // Placeholder constant 1; extractPolyCoeffs pulls the factor out into
        // model.th and rejects a tanh that is not a multiplicative factor.
        .call => if (isCall(op, .tanh) and op.b == 1)
            .{ 1, 0, 0, 0 }
        else if (isCall(op, .pow) and op.b == 2)
            powPoly(ops, consts, operand(ops, end, 0), end - 1)
        else
            null,
        .neg => blk: {
            var r = poly(ops, consts, end - 1) orelse return null;
            for (&r) |*v| v.* = -v.*;
            break :blk r;
        },
        .add, .sub => blk: {
            var r = poly(ops, consts, operand(ops, end, 0)) orelse return null;
            const b = poly(ops, consts, end - 1) orelse return null;
            for (&r, b) |*v, w| v.* = if (op.code == .sub) v.* - w else v.* + w;
            break :blk r;
        },
        .mul => mulPoly(poly(ops, consts, operand(ops, end, 0)) orelse return null, poly(ops, consts, end - 1) orelse return null),
        .div => blk: {
            var r = poly(ops, consts, operand(ops, end, 0)) orelse return null;
            const d = poly(ops, consts, end - 1) orelse return null;
            if (d[1] != 0 or d[2] != 0 or d[3] != 0 or d[0] == 0) return null;
            for (&r) |*v| v.* /= d[0];
            break :blk r;
        },
        .pow => powPoly(ops, consts, operand(ops, end, 0), end - 1),
        else => null,
    };
}

fn mulPoly(a: Poly, b: Poly) ?Poly {
    var r: Poly = .{ 0, 0, 0, 0 };
    for (a, 0..) |x, i| for (b, 0..) |y, j| {
        if (x == 0 or y == 0) continue;
        if (i + j > 3) return null;
        r[i + j] += x * y;
    };
    return r;
}

/// base^k for a constant integer k in [0, 3].
fn powPoly(ops: []const Op, consts: []const f64, base: usize, exponent: usize) ?Poly {
    const e = poly(ops, consts, exponent) orelse return null;
    if (e[1] != 0 or e[2] != 0 or e[3] != 0) return null;
    if (e[0] != @round(e[0]) or e[0] < 0 or e[0] > 3) return null;
    const b = poly(ops, consts, base) orelse return null;
    var r: Poly = .{ 1, 0, 0, 0 };
    for (0..@as(usize, @intFromFloat(e[0]))) |_| r = mulPoly(r, b) orelse return null;
    return r;
}

fn vDegree(ops: []const Op, end: usize) ?u8 {
    const op = ops[end];
    switch (op.code) {
        .num => return 0,
        // tanh factors count as degree-0 (extracted separately into th)
        .vprobe => return 1,
        .call => return if (isCall(op, .tanh)) 0 else null,
        .mul, .div => {
            const da = vDegree(ops, operand(ops, end, 0)) orelse return null;
            const db = vDegree(ops, end - 1) orelse return null;
            return if (op.code == .mul) da + db else if (db == 0) da else null;
        },
        .neg => return vDegree(ops, end - 1),
        else => return null,
    }
}

fn numericCoeff(ops: []const Op, consts: []const f64, end: usize) f64 {
    const op = ops[end];
    return switch (op.code) {
        .num => consts[op.a],
        .mul => numericCoeff(ops, consts, operand(ops, end, 0)) * numericCoeff(ops, consts, end - 1),
        .div => numericCoeff(ops, consts, operand(ops, end, 0)) / numericCoeff(ops, consts, end - 1),
        .neg => -numericCoeff(ops, consts, end - 1),
        .not => numericCoeff(ops, consts, end - 1),
        else => 1.0,
    };
}

// ---------------------------------------------------------------------------
// Waveform tables
// ---------------------------------------------------------------------------

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

fn applySourceWaveform(target: anytype, dev: Device) void {
    const T = @TypeOf(target.*);
    // Runs over both Model and Instance (see bindSource); the one that does not
    // declare the waveform set has nothing to do.
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

// ---------------------------------------------------------------------------
// Kv / positional utilities
// ---------------------------------------------------------------------------

fn deviceNodes(nb: *NetBuilder, comptime D: type, dev: Device) ![D.num_ports]u32 {
    var out: [D.num_ports]u32 = undefined;
    inline for (0..D.num_ports) |idx| {
        out[idx] = if (idx < dev.pins.len) try nb.rowOf(dev.pins[idx]) else GROUND;
    }
    return out;
}

fn modelLevel(dev: Device) !u16 {
    if (dev.model) |m| {
        if (try numericParameter(m.kv, "level")) |l| return try castField(u16, l);
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

fn findNameIndex(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, target)) return i;
    return null;
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

fn sourceDc(dev: Device) ?f64 {
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
fn sourcePort(dev: Device) !?struct { num: u16, z0: f64 } {
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
    // `portnum` was GIVEN, so the card claims to be a port: a reference
    // impedance that is not positive, or a port number outside the table, is
    // a bad deck. Returning null here instead demoted the card to a plain V
    // source and `sp/zero_impedance` ran a one-port S-parameter sweep on it.
    if (!(num_f >= 1) or num_f > 1024 or !(z0 > 0)) return error.InvalidAnalysisArguments;
    return .{ .num = @intFromFloat(num_f), .z0 = z0 };
}

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

/// `DISTOF1 [mag [phase]]` on a source card, ngspice vsrcpar.c:180-193: the
/// bare keyword is mag 1 / phase 0, one number sets the magnitude, two set
/// both. `{0, 0}` = the card never named it — no F1 drive, ngspice's own
/// `VSRCdF1given` false.
fn sourceDistoF1(dev: Device) [2]f64 {
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

/// Cold native-line setup validation, including every nested fitted coefficient.
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

/// Packed upper-triangular matrix entries follow the first named value.
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

/// A recognized numeric field cannot silently fall back to a model default.
fn numericParameter(kv: []const Kv, key: []const u8) !?f64 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) {
        const value = valueNumber(item.value) orelse return error.UnresolvedParameter;
        if (!std.math.isFinite(value)) return error.NonFiniteParameter;
        return value;
    };
    return null;
}

/// Card pairs onto a built-in's Model or Instance, through the device's own
/// binder (`DeviceVtable.bind_model`), the one every loaded device uses too.
fn applyKv(target: anytype, kv: []const Kv) !void {
    const name, const is_model = comptime ownerOf(@TypeOf(target.*));
    const vt = device.vtable(name);
    try bindKv(if (is_model) vt.bind_model else vt.bind_instance, @ptrCast(target), kv);
}

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

// Private implementation access for the frontend test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .applySourceWaveform = applySourceWaveform,
    .pwlSlot = pwlSlot,
    .pwlCapacity = pwlCapacity,
    .Wave = Wave,
    .castField = castField,
    .bindKv = bindKv,
} else {};
