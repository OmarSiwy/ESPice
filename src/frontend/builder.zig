//! Netlist hypergraph to frozen `device.Circuit`.
//! `NetBuilder` maps nets to rows and turns each card into device instances;
//! `Builder` accumulates them per `device.Library` type, computes the BBD
//! node permutation and freezes the pattern.
//!
//! Cites ngspice's setup, load and parameter sources (file:line at each use:
//! vsrcload.c, vsrctemp.c, resparam.c, asrcset.c, b4set.c, ...) for what a
//! card means, the HSPICE manuals ([SA], [SI]) for the HSPICE elements, and
//! the Verilog-A LRM (§) for the `$simparam`, `derive` and `$port_connected`
//! hooks the generated models expose.

const std = @import("std");
const core = @import("core");
const z = @import("stdpp");
const requests = core.query;
const numerics = @import("core").numerics;
const devices = @import("spice.zig");
const sparam = @import("sparam.zig");
const wfit = @import("wfit.zig");
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

/// The backends stdpp runs vector blocks on; elsewhere `lane_count` is null
/// and its pipelines take the scalar path.
const simd_backend = @import("builtin").zig_backend == .stage2_llvm or @import("builtin").zig_backend == .stage2_x86_64;

/// `node_instance` tag of a node shared by two subcircuit instances.
const MULTI_INSTANCE: u32 = std.math.maxInt(u32);

/// Allocator for the Builder's own growing tables, which die at the freeze.
/// Not `Builder.gpa`, usually the Problem's arena: an arena keeps every
/// abandoned capacity alive for the run, 30 MB of card and label lists on
/// the 200,000-device RC ladder.
const staging = core.gpa;

/// Mutable circuit under construction: rows, device protos and card
/// identities. `compilePerm` consumes it into a `Circuit`.
pub const Builder = struct {
    /// Allocates the protos, the BBD permutation and the frozen Circuit.
    gpa: std.mem.Allocator,
    /// Device types and their vtables; outlives the Builder.
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
    /// `.options abstol`, A; copied like `reltol`.
    abstol: f64 = 1e-12,
    /// `.options vntol`, V; copied like `reltol`.
    vntol: f64 = 1e-6,
    /// `.options gmin`, S: the `$simparam("gmin")` a model reads outside the
    /// operating point's gmin-stepping rung, which writes its own.
    gmin: f64 = 1e-12,

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
        try labels.append(staging, "0");
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
        self.protos.deinit(staging);
        self.proto_types.deinit(staging);
        self.cards.deinit(staging);
        self.card_counts.deinit(staging);
        self.node_labels.deinit(staging);
        self.node_instance.deinit(staging);
        self.* = undefined;
    }

    /// Tags a node with a subcircuit instance; a second instance makes it a
    /// coupling node.
    fn tagNodeInstance(self: *Builder, node: u32, subckt_instance: u32) !void {
        if (node == GROUND) return;
        if (self.node_instance.items.len <= node) {
            const grow = node + 1 - self.node_instance.items.len;
            try self.node_instance.appendNTimes(staging, 0, grow);
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
        defer instance_list.deinit(staging);
        // Instance to block index.
        var index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer index.deinit(staging);
        const tagged = @min(n, @as(u32, @intCast(ni.len)));
        for (1..tagged) |i| {
            const inst = ni[i];
            if (inst == 0 or inst == MULTI_INSTANCE) continue;
            const gop = try index.getOrPut(staging, inst);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(instance_list.items.len);
                try instance_list.append(staging, .{ .inst = inst, .at = 0 });
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

    /// Appends an unlabelled row and returns it; TooManyNodes past the
    /// u32 row space.
    pub fn addNode(self: *Builder) !u32 {
        if (self.n == std.math.maxInt(u32)) return error.TooManyNodes;
        const id = self.n;
        try self.node_labels.append(staging, "");
        self.n += 1;
        return id;
    }

    /// Reserves label capacity for `expected` rows past ground.
    pub fn reserveNodes(self: *Builder, expected: u32) !void {
        if (expected == std.math.maxInt(u32)) return error.TooManyNodes;
        try self.node_labels.ensureTotalCapacity(staging, expected + 1);
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
        const n_u = comptime @typeInfo(D.U).@"enum".field_names.len;
        var all: [n_u]u32 = undefined;
        inline for (0..D.num_ports) |p| all[p] = nodes[p];

        // Reach the device through its own object's vtable: naming
        // `D.collapse` or `ProtoStore(D)` here would compile the device body
        // into the executable a second time (device/eval.zig).
        const t = comptime Library.builtin(device.modelName(D) orelse
            @compileError(@typeName(D) ++ " is not a catalog device"));
        const vt = self.lib.vtable(t);
        try self.countCard(t, card);
        if (comptime n_u > D.num_ports) {
            var col: [n_u]i32 = @splat(-1);
            if (vt.collapse) |collapse| collapse(@ptrCast(&model), @ptrCast(&instance), &col);
            for (D.num_ports..n_u) |u|
                all[u] = if (col[u] >= 0) all[@intCast(col[u])] else try self.addNode();
        }
        const proto = try self.protoOf(t);
        try vt.proto_add(proto.ctx, self.gpa, @ptrCast(&model), @ptrCast(&instance), &all).unwrap();
    }

    /// Counts one instance of `t` and records its card name, if any.
    fn countCard(self: *Builder, t: DeviceType, card: []const u8) !void {
        const i = @backingInt(t);
        if (self.card_counts.items.len <= i)
            try self.card_counts.appendNTimes(staging, 0, i + 1 - self.card_counts.items.len);
        const ordinal = &self.card_counts.items[i];
        if (card.len != 0) try self.cards.append(staging, .{ .type = t, .index = ordinal.*, .name = card });
        ordinal.* += 1;
    }

    /// Returns the proto of device type `t`, creating it on first use.
    pub fn protoOf(self: *Builder, t: DeviceType) !Proto {
        for (self.protos.items, self.proto_types.items) |p, pt| {
            if (pt == t) return p;
        }
        try self.protos.ensureUnusedCapacity(staging, 1);
        try self.proto_types.ensureUnusedCapacity(staging, 1);
        const p = try self.lib.vtable(t).proto_create(self.gpa).unwrap();
        self.protos.appendAssumeCapacity(p);
        self.proto_types.appendAssumeCapacity(t);
        return p;
    }

    /// `compilePerm` for callers that recorded no node or branch row; the
    /// permutation is freed here. Consumes the Builder on success.
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
    /// is none, and on failure. Any row the caller recorded before the call
    /// must be mapped through it.
    pub fn compilePerm(self: *Builder, perm_out: *?[]const u32) !Circuit {
        const gpa = self.gpa;
        perm_out.* = null;
        const n: usize = self.n;

        const bbd = try self.computeBbd();
        errdefer if (bbd.perm) |p| gpa.free(p);
        errdefer if (bbd.info) |inf| gpa.free(inf.blocks);
        if (bbd.perm) |perm| {
            for (self.protos.items) |p| p.apply_perm(p.ctx, perm);
            const old_labels = try staging.alloc([]const u8, n);
            defer staging.free(old_labels);
            @memcpy(old_labels, self.node_labels.items);
            for (old_labels, perm) |label, new_i| self.node_labels.items[new_i] = label;
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

        const ckt = try Circuit.freeze(gpa, self.n, intern_bytes, intern_offs, self.protos.items, self.proto_types.items, bbd.info, .{
            .needs_tran_op = self.needs_tran_op,
            .digital = self.lib.digital.items,
        });

        self.deinitStorage(); // Circuit.freeze consumed the protos
        // Handed over only now, so the errdefer above frees it on any failure.
        perm_out.* = bbd.perm;
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
    /// The circuit under construction; every row recorded here is one of its.
    b: *Builder,
    /// The parsed deck. Names recorded here borrow its arena.
    nl: Netlist,
    /// Circuit row of each net, 0 until a device touches it (ground is 0
    /// anyway). Rows follow stamping order, not net order.
    rows: []u32,
    /// Per control name, how many F/H/W cards sense it. The first V card of
    /// that name takes the count, as `resolveDeferred` binds the first.
    sensors: std.StringHashMapUnmanaged(u32),

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
    /// C and L `ic=` (ngspice CAPinitCond, INDinitCond) as rows for a `uic`
    /// start: a C's n+ row (n- negated when n+ is ground), an L's branch row.
    dev_ic: std.ArrayList(core.Ic) = .empty,
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
    /// netlist nets are `seen`. `comp` is a union-find over the DC paths
    /// (every element but capacitors and current sources joins its pins), so
    /// a node whose component lacks ground has no DC path, however many
    /// elements touch it (#90). V and L cards are DC shorts: `uf`/`pot` form
    /// a weighted union-find with `pot` = v(x) - v(parent), and a loop of
    /// shorts is an error when its KVL sum is inconsistent (V1=5 parallel to
    /// V2=3) or when V sources alone close it (#70).
    topo: std.MultiArrayList(struct { seen: bool, comp: u32, uf: u32, pot: f64 }) = .empty,
    /// I cards as rows and DC value, for the current balance of each
    /// component without a DC path.
    topo_isrc: std.ArrayList(struct { pos: u32, neg: u32, dc: f64 }) = .empty,

    /// A V card as the queries and the F/H/W cards see it.
    pub const VCard = struct {
        name: []const u8,
        /// `pos`/`neg`: the node pair, which is the control port of an F/H/W sensing it.
        pos: u32,
        neg: u32,
        /// Branch-current row.
        branch: u32,
        /// A sensed source drives `pos` to `tap`, and its sensors' 0 V
        /// control branches chain from `tap` to `neg`, so each carries the
        /// source's whole current (ngspice cccsset.c reads that branch).
        /// `tap` is the next sensor's cp; `sensors` how many are still to come.
        tap: u32,
        sensors: u32,
        /// `DISTOF1 [mag [phase]]`, `.disto`'s F1 drive (ngspice
        /// cktdisto.c:100-117), phase in degrees. `{0, 0}` when not given.
        distof1: [2]f64,
        /// `DISTOF2 [mag [phase]]`, the F2 drive of a two-tone `.disto`.
        distof2: [2]f64,
        /// `.sp` port index, 1-based; 0 when not a port (vsrcdefs.h:104-105).
        portnum: u16,
        /// The port the card is, valid when `portnum` is nonzero. A P card's
        /// port node is n+ in front of its z0, and a mixed-mode one's
        /// branch is its + leg's.
        port: requests.Port,
    };

    /// A builder over `nl` writing into `b`; both must outlive it.
    pub fn init(arena: std.mem.Allocator, b: *Builder, nl: Netlist) !NetBuilder {
        // The cards `resolveDeferred` hands to addBranchRef, and no others:
        // a sensor counted here and never added would leave its chain open.
        var sensors: std.StringHashMapUnmanaged(u32) = .empty;
        for ("fhw") |letter| for (nl.bucket(letter)) |e| {
            const d = nl.device(e);
            // An HSPICE W card is a transmission line, and an HDL card is not deferred.
            if (letter == 'w' and nl.deck.dialect == .hspice) continue;
            if (loadedType(b.lib, d) != null) continue;
            const name = positionalName(d, 0) orelse continue;
            const entry = try sensors.getOrPut(arena, name);
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + 1 else 1;
        };
        const rows = try arena.alloc(u32, nl.graph.vertexCount());
        @memset(rows, 0);
        const cards = try arena.alloc(?BoundCard, nl.models.len);
        @memset(cards, null);
        var nb: NetBuilder = .{ .arena = arena, .b = b, .nl = nl, .rows = rows, .sensors = sensors, .bound_cards = cards };
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

    /// The application an instance of type `t` calls its LRM 12.32 `$name`s
    /// through: the loaded one (`Library.systfHost`), or `no_vpi_app` when
    /// every call no application registered is a task, whose value nothing
    /// reads (`Library.loadWith` warned for each). A call whose value is used
    /// and that nothing registered is refused by name, `UnregisteredSystf`:
    /// the LRM fixes no value for it. While VerA's `contract.Systf` does not
    /// mark tasks (VerA#83), every unregistered call is refused.
    fn systfHostFor(lib: *const Library, t: DeviceType, instance: []const u8, vt: *const batch.DeviceVtable) error{UnregisteredSystf}!*const batch.SystfHost {
        for (vt.systf_calls) |c| {
            if (lib.systfRegistered(c.name) or Library.isSystfTask(c)) continue;
            if (!@import("builtin").is_test) std.log.err("{s}: module '{s}' calls `{s}`: no VPI application registered (LRM 12.32), so its value is unknown; see #198", .{ instance, vt.name, c.name });
            return error.UnregisteredSystf;
        }
        return lib.systfHost(t) orelse &Library.no_vpi_app;
    }

    /// Adds the runtime-loaded (.hdl) devices, cards shaped `<name> node...
    /// <model>`, through their vtables. Call after `build`, before the freeze.
    /// UnknownParameter for a card key neither blob declares, WrongNodeCount
    /// for a node count other than the module's ports.
    pub fn addDynDevices(self: *NetBuilder) !void {
        const b = self.b;
        const arena = self.arena;
        if (b.lib.names.items.len == Library.builtin_count) return;
        for (self.nl.order) |e| {
            const dev = self.nl.device(e);
            const t = loadedType(b.lib, dev) orelse continue;
            const vt = b.lib.vtable(t);
            const systf_host = if (vt.systf_calls.len != 0) try systfHostFor(b.lib, t, dev.name, vt) else null;

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
                for (vt.num_ports..vt.n_u) |u| {
                    if (col[u] >= 0) {
                        nodes[u] = nodes[@intCast(col[u])];
                        continue;
                    }
                    nodes[u] = try b.addNode();
                    // An internal net publishes as ngspice names an OSDI
                    // device's: `v(<instance>#<net>)`. Branch flows are not
                    // node voltages.
                    if (u < vt.unknown_names.len and !std.mem.startsWith(u8, vt.unknown_names[u], "flowZ28"))
                        b.node_labels.items[nodes[u]] = try std.fmt.allocPrint(arena, "{s}#{s}", .{ dev.name, vt.unknown_names[u] });
                }
            }

            if (systf_host) |h| vt.bind_systf.?(iblob.ptr, h);
            const proto = try b.protoOf(t);
            try vt.proto_add(proto.ctx, b.gpa, mblob.ptr, iblob.ptr, nodes.ptr).unwrap();
            // `%m` in a display task and a `$fatal` refusal name the
            // instance by its card, as for a built-in device.
            try b.countCard(t, dev.name);
        }
    }

    /// What the deck keeps of the cards, in frozen rows.
    pub const Published = struct {
        /// Source and `.sp` port tables, copied into the
        /// publish arena.
        bindings: core.QueryBindings,
        /// Branch currents first, then every named node; parallel to
        /// `probe_labels`. Mutable so `.save` can narrow them in place.
        probes: []u32,
        /// `i(card)` and `v(net)` names, parallel to `probes`.
        probe_labels: [][]const u8,
        /// `acExcitation` over the frozen rows: `[re(0..n), im(0..n)]`.
        ac_drive: []const f64,
        /// The first stamped V card's positive node, the `.op` ladder's anchor.
        source_node: u32,
        /// That card's branch row; GROUND when the deck stamps no V card.
        source_branch: u32,
        /// Row of the last net the deck introduces.
        output_node: u32,
        /// `dev_ic` over the frozen rows.
        uic_ic: []const core.Ic,
    };

    /// Maps every row recorded so far through `perm`, the BBD permutation
    /// `Builder.compilePerm` returned (null: none), then copies the deck's
    /// tables into `arena`. Call once, after the freeze: `frozenRow` answers
    /// in frozen rows from then on. `circuit` is the frozen result.
    /// DuplicatePortNumber or MissingPortNumber for a gapped `.sp` port set.
    pub fn publish(self: *NetBuilder, arena: std.mem.Allocator, circuit: *const Circuit, perm: ?[]const u32) !Published {
        if (perm) |p| for ([_][]u32{
            self.v.items(.branch),       self.v.items(.pos),    self.v.items(.neg),  self.i.items(.pos),  self.i.items(.neg),
            self.br.items(.row),         self.l.items(.branch), self.ac.items(.pos), self.ac.items(.neg), (&self.source_node)[0..1],
            (&self.source_branch)[0..1], self.rows,
        }) |rows| for (rows) |*row| {
            if (row.* < p.len) row.* = p[row.*];
        };
        if (perm) |p| for (self.dev_ic.items) |*ic| {
            if (ic.node < p.len) ic.node = p[ic.node];
        };
        // A port carries its own copy of the card's rows.
        if (perm) |p| for (self.v.items(.port)) |*port| {
            for ([_]*u32{ &port.node, &port.neg, &port.branch }) |row| {
                if (row.* < p.len) row.* = p[row.*];
            }
            if (port.balanced) |*leg| for ([_]*u32{ &leg.node, &leg.branch }) |row| {
                if (row.* < p.len) row.* = p[row.*];
            };
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
                .ports = try self.portList(arena),
            },
            .probes = probe_buf[0..n_probes],
            .probe_labels = label_buf[0..n_probes],
            .ac_drive = try self.acExcitation(arena, circuit.n),
            .source_node = self.source_node,
            .source_branch = self.source_branch,
            .output_node = self.frozenRow(last_net),
            .uic_ic = try arena.dupe(core.Ic, self.dev_ic.items),
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
        if (comptime simd_backend) comptime std.debug.assert(@TypeOf(nums).lane_count != null);
        const n_ports: usize = nums.max() orelse 0;
        if (n_ports == 0) return &.{};
        const ports = try arena.alloc(requests.Port, n_ports);
        for (ports) |*p| p.branch = std.math.maxInt(u32); // unset
        const v = self.v.slice();
        for (v.items(.portnum), v.items(.port)) |num, port| {
            if (num == 0) continue;
            const slot = &ports[num - 1];
            if (slot.branch != std.math.maxInt(u32)) return error.DuplicatePortNumber;
            slot.* = port;
        }
        for (ports) |p| if (p.branch == std.math.maxInt(u32)) return error.MissingPortNumber;
        return ports;
    }

    /// ngspice's `.tran`-card defaults (vsrcload.c:102-215): PULSE TR/TF are
    /// TSTEP and PW/PER TSTOP when omitted or 0 (the model's -1 sentinel is
    /// omitted), SIN's frequency 1/TSTOP, and EXP's TD1, TAU1 and TAU2 TSTEP
    /// and TD2 TD1 + TSTEP (applyWaveArgs zeroes the EXP time constants
    /// first). A no-op on a struct without the PULSE fields, so it can run
    /// over both Model and Instance.
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
            if (comptime @hasField(T, "sffm_fm")) if (target.waveform == @backingInt(Wave.sffm)) {
                if (target.sffm_fm == -1.0) target.sffm_fm = @floatCast(5.0 / tstop);
                if (target.sffm_fc == 0.0) target.sffm_fc = @floatCast(500.0 / tstop);
            };
            if (comptime @hasField(T, "sin_freq")) if (target.waveform == @backingInt(Wave.sin)) {
                if (target.sin_freq == 0) target.sin_freq = @floatCast(1.0 / tstop);
            };
            if (comptime @hasField(T, "exp_td1")) if (target.waveform == @backingInt(Wave.exp)) {
                if (target.exp_td1 == 0) target.exp_td1 = @floatCast(tstep);
                if (target.exp_tau1 == 0) target.exp_tau1 = @floatCast(tstep);
                if (target.exp_td2 == 0) target.exp_td2 = @floatCast(target.exp_td1 + tstep);
                if (target.exp_tau2 == 0) target.exp_tau2 = @floatCast(tstep);
            };
            if (target.waveform != @backingInt(Wave.pulse)) {
                target.pulse_td = 1e30;
                return;
            }
        }
        if (target.pulse_tr <= 0) target.pulse_tr = tstep;
        if (target.pulse_tf <= 0) target.pulse_tf = tstep;
        if (target.pulse_pw <= 0) target.pulse_pw = tstop;
        if (target.pulse_per <= 0) target.pulse_per = tstop;
    }

    /// Adds every built-in card, then checks the topology. V and L go
    /// first; F/H/W/K wait until the end so the rows they name exist.
    /// Refuses a card it cannot bind, a loop of V/L shorts whose KVL sum
    /// disagrees (VoltageSourceLoop) and a node only current sources reach
    /// (CurrentSourceCutset); a capacitor-only node sets `needs_tran_op`.
    pub fn build(self: *NetBuilder) !void {
        for ("vlifhwkabcdegjmnopqrstuxyz") |c| for (self.nl.bucket(c)) |e| try self.addDevice(self.nl.device(e));
        try self.resolveDeferred();
        try self.topoCheck();
    }

    fn topoEnsure(self: *NetBuilder, id: u32) !void {
        while (self.topo.len <= id) {
            const next: u32 = @intCast(self.topo.len);
            try self.topo.append(self.arena, .{ .seen = false, .comp = next, .uf = next, .pot = 0 });
        }
    }

    /// Root and potential-to-root of `id0` in the weighted forest. Points
    /// the whole path at the root, so a chain of shorts listed against its
    /// order cannot make every later lookup walk it again.
    fn topoRoot(self: *NetBuilder, id0: u32) struct { root: u32, pot: f64 } {
        const uf = self.topo.items(.uf);
        const pots = self.topo.items(.pot);
        var root = id0;
        var total: f64 = 0;
        while (uf[root] != root) {
            total += pots[root];
            root = uf[root];
        }
        // Second pass: each node's potential to the root is the total less
        // what lies between id0 and it.
        var id = id0;
        var walked: f64 = 0;
        while (uf[id] != root) {
            const next = uf[id];
            const step = pots[id];
            uf[id] = root;
            pots[id] = total - walked;
            walked += step;
            id = next;
        }
        return .{ .root = root, .pot = total };
    }

    /// Root of `id` in the DC-path forest, halving the path as it walks.
    fn compRoot(self: *NetBuilder, id0: u32) u32 {
        const comp = self.topo.items(.comp);
        var id = id0;
        while (comp[id] != id) {
            comp[id] = comp[comp[id]];
            id = comp[id];
        }
        return id;
    }

    /// Classifies one card's nodes. `.dc` and `.short` join the pins into one
    /// DC-path component, `.cap` and `.cur` mark presence only; `.short` also
    /// joins the first two nodes as a DC short with v(node0) - v(node1) =
    /// `vshort` and rejects a loop whose KVL sum disagrees, or which V
    /// sources alone close: V cards are marked before any L, so a V that
    /// finds its pins already shorted closes a loop of V sources, whose
    /// current no equation fixes (ngspice: singular matrix).
    fn topoMark(self: *NetBuilder, dev: Device, kind: enum { dc, cap, cur, short }, vshort: f64) !void {
        var first_two: [2]u32 = .{ GROUND, GROUND };
        for (dev.pins, 0..) |pin, i| {
            const id = try self.rowOf(pin);
            try self.topoEnsure(id);
            self.topo.items(.seen)[id] = true;
            if (i < 2) first_two[i] = id;
            if (i > 0 and (kind == .dc or kind == .short))
                self.topo.items(.comp)[self.compRoot(id)] = self.compRoot(first_two[0]);
        }
        if (kind == .short and dev.pins.len >= 2) {
            const a = self.topoRoot(first_two[0]);
            const b_ = self.topoRoot(first_two[1]);
            if (a.root == b_.root) {
                const gap = (a.pot - b_.pot) - vshort;
                // The test runner fails any test that logs an error.
                if (@abs(gap) > 1e-9 * @max(1.0, @abs(vshort))) {
                    if (!@import("builtin").is_test) std.log.err(
                        "topology: '{s}' closes an inconsistent voltage-source/inductor loop ({d} V of KVL violation)",
                        .{ dev.name, gap },
                    );
                    return error.VoltageSourceLoop;
                }
                if (dev.kind == 'v') {
                    if (!@import("builtin").is_test) std.log.err(
                        "topology: '{s}' closes a loop of voltage sources — the loop current is not unique",
                        .{dev.name},
                    );
                    return error.NonuniqueOperatingPoint;
                }
            } else {
                // Attach so every member's potential stays consistent:
                // v(b) = pot_b + pot[rb] must equal v(a) - vshort.
                self.topo.items(.uf)[b_.root] = a.root;
                self.topo.items(.pot)[b_.root] = a.pot - vshort - b_.pot;
            }
        }
    }

    /// Rejects a net no element touches (one only an expression reads, #92)
    /// and a component without a DC path to ground whose current sources do
    /// not balance, which static KCL cannot satisfy. A component that
    /// balances (capacitors only, or equal sources in and out, #70) sets
    /// `needs_tran_op`, ngspice's OPtran fallback.
    fn topoCheck(self: *NetBuilder) !void {
        const quiet = @import("builtin").is_test; // the test runner fails any test that logs an error
        for (self.rows) |row| {
            if (row == 0 or (row < self.topo.len and self.topo.items(.seen)[row])) continue;
            if (!quiet) std.log.err("topology: node '{s}' is read but no element connects to it", .{self.b.node_labels.items[row]});
            return error.FloatingNode;
        }
        try self.topoEnsure(GROUND);
        // Net current into, and the magnitude through, each component root.
        const net = try self.arena.alloc(f64, 2 * self.topo.len);
        @memset(net, 0);
        const mag = net[self.topo.len..];
        for (self.topo_isrc.items) |src| {
            // n+ to n- through the source: out of n+, into n-.
            for ([2]u32{ src.pos, src.neg }, [2]f64{ -src.dc, src.dc }) |node, i| {
                const r = self.compRoot(node);
                net[r] += i;
                mag[r] += @abs(i);
            }
        }
        const ground = self.compRoot(GROUND);
        for (0..self.topo.len) |id| {
            if (!self.topo.items(.seen)[id]) continue;
            const r = self.compRoot(@intCast(id));
            if (r == ground) continue;
            if (!(@abs(net[r]) <= 1e-9 * mag[r])) {
                if (!quiet) std.log.err("topology: node '{s}' is a current-source cutset — its current sources do not balance and KCL has no DC path to satisfy it", .{self.b.node_labels.items[id]});
                return error.CurrentSourceCutset;
            }
            self.b.needs_tran_op = true;
        }
    }

    fn addDevice(self: *NetBuilder, card: Device) !void {
        // A source's waveform in the model's argument order (ngspiceWaveform).
        const dev = if (card.kind == 'v' or card.kind == 'i') try self.ngspiceWaveform(card) else card;
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
                return named(dev, error.UnsupportedDevice);
        }

        switch (letter) {
            'c' => try self.topoMark(dev, .cap, 0),
            'i' => try self.topoMark(dev, .cur, 0),
            // A V source shorts its pair at its DC value; an inductor at 0 V.
            // A P card's series z0 keeps n+ off the short.
            'v' => if (isPortCard(dev)) try self.topoMark(dev, .dc, 0) else try self.topoMark(dev, .short, sourceDc(dev) orelse 0),
            'l' => try self.topoMark(dev, .short, 0),
            else => try self.topoMark(dev, .dc, 0),
        }

        switch (letter) {
            'r' => _ = try self.addPassive(devices.resistor, dev, "r", "resist"),
            'c' => {
                _ = try self.addPassive(devices.capacitor, dev, "c", "cap");
                // ponytail: a floating C sets its n+ node, not only its own
                // charge as ngspice's CAPload under MODEUIC does, so another
                // charge on that node starts charged too. Exact for a grounded
                // C; a per-device charge seed in the uic start is the upgrade.
                if (try numericParameter(dev.kv, "ic")) |ic| {
                    const p = try self.rowOf(dev.pins[0]);
                    try self.dev_ic.append(self.arena, if (p != GROUND) .{ .node = p, .value = ic } else .{ .node = try self.rowOf(dev.pins[1]), .value = -ic });
                }
            },
            'l' => {
                const br = try self.addPassive(devices.inductor, dev, "l", "inductance");
                if (try numericParameter(dev.kv, "ic")) |ic| try self.dev_ic.append(self.arena, .{ .node = br, .value = ic });
                try self.l.append(self.arena, .{ .name = dev.name, .branch = br, .value = positionalNumber(dev, 0) orelse
                    kvNumber(dev.kv, "inductance") orelse kvNumber(dev.kv, "l") orelse 0 });
            },
            'v' => {
                if (comptime !@hasDecl(devices.vsource, "eval")) return error.UnsupportedDevice;
                const bound = try self.bindSource(devices.vsource, dev);
                var nodes = try deviceNodes(self, devices.vsource, dev);
                const pos = nodes[0];
                const sensors: u32 = if (self.sensors.fetchRemove(dev.name)) |kv| kv.value else 0;
                const port = if (sensors != 0) null else try sourcePort(dev);
                // An HSPICE P card keeps its z0 in series in every analysis
                // [SA Ch.17]: a noiseless resistor from n+ to a hidden node the
                // source drives. ngspice's portnum V stays ideal.
                const series = port != null and isPortCard(dev);
                const neg = nodes[1];
                var port_branch: u32 = undefined;
                var balanced: ?requests.Port.Leg = null;
                if (series and dev.pins.len == 3) {
                    // Mixed mode [SA Ch.17]: the card's value V drives a hidden
                    // node m against ref, and each leg is V/2 or -V/2 against
                    // ref (a VCVS on m) behind its own z0.
                    const ref = try self.rowOf(dev.pins[2]);
                    nodes = .{ try self.b.addNode(), ref };
                    var legs: [2]requests.Port.Leg = undefined;
                    for (&legs, [2]u32{ pos, neg }, [2]f64{ 0.5, -0.5 }) |*leg, pin, gain| {
                        const h = try self.b.addNode();
                        try self.b.addDevice(devices.resistor, dev.name, .{ .r = port.?.z0, .noisy = 0 }, .{}, [2]u32{ pin, h });
                        try self.b.addDevice(devices.vcvs, dev.name, .{ .gain = gain }, .{}, [4]u32{ h, ref, nodes[0], ref });
                        leg.* = .{ .node = pin, .branch = internalRow(devices.vcvs, "flowZ28pZ2cnZ29", self.b.n) };
                    }
                    port_branch = legs[0].branch;
                    balanced = legs[1];
                } else if (series) {
                    nodes[0] = try self.b.addNode();
                    try self.b.addDevice(devices.resistor, dev.name, .{ .r = port.?.z0, .noisy = 0 }, .{}, [2]u32{ pos, nodes[0] });
                }
                // A PWL past the table's capacity continues in sources of its
                // later segments, in series between the card's source and n-.
                const tail = try pwlTail(devices.vsource, self.arena, dev);
                if (tail.len != 0 and series) {
                    if (!@import("builtin").is_test) std.log.err("{s}: a PWL past {d} points on a port source", .{ dev.name, comptime pwlCapacity(devices.vsource.Model) });
                    return error.UnsupportedCard;
                }
                // A sensed source ends at a hidden tap; addBranchRef chains
                // its sensors from there to n- (see `VCard.tap`).
                if (sensors != 0) nodes[1] = try self.b.addNode();
                const chain_end = nodes[1];
                if (tail.len != 0) nodes[1] = try self.b.addNode();
                const br = self.b.n;
                if (balanced == null) port_branch = br;
                try self.b.addDevice(devices.vsource, dev.name, bound[0], bound[1], nodes);
                var from = nodes[1];
                for (tail, 0..) |seg, k| {
                    const to = if (k + 1 == tail.len) chain_end else try self.b.addNode();
                    try self.b.addDevice(devices.vsource, dev.name, seg, .{}, [2]u32{ from, to });
                    from = to;
                }
                try self.v.append(self.arena, .{
                    .name = dev.name,
                    .pos = pos,
                    .neg = neg,
                    .branch = br,
                    .tap = chain_end,
                    .sensors = sensors,
                    .distof1 = sourceDisto(dev, "distof1"),
                    .distof2 = sourceDisto(dev, "distof2"),
                    .portnum = if (port) |p| p.num else 0,
                    .port = if (port) |p| .{
                        .node = pos,
                        .neg = chain_end,
                        .branch = port_branch,
                        .z0 = p.z0,
                        .band = p.band,
                        .series_z0 = series,
                        .balanced = balanced,
                    } else .{ .node = GROUND, .branch = GROUND },
                });
                if (self.source_branch == GROUND) {
                    self.source_node = if (series) pos else nodes[0];
                    self.source_branch = br;
                }
                if (sourceAc(dev)) |ac| try self.ac.append(self.arena, .{ .pos = GROUND, .neg = br, .re = ac.re, .im = ac.im });
            },
            'i' => {
                if (comptime !@hasDecl(devices.isource, "eval")) return error.UnsupportedDevice;
                var bound = try self.bindSource(devices.isource, dev);
                // isrcload.c/isrcacld.c scale every value by `m=`.
                const m = kvNumber(dev.kv, "m") orelse 1;
                bound[1].mfactor = m;
                const nodes = try deviceNodes(self, devices.isource, dev);
                try self.b.addDevice(devices.isource, dev.name, bound[0], bound[1], nodes);
                // A PWL past the table's capacity: its later segments in parallel.
                for (try pwlTail(devices.isource, self.arena, dev)) |seg| try self.b.addDevice(devices.isource, dev.name, seg, .{ .mfactor = m }, nodes);
                if (sourceAc(dev)) |ac| try self.ac.append(self.arena, .{ .pos = nodes[0], .neg = nodes[1], .re = m * ac.re, .im = m * ac.im });
                try self.i.append(self.arena, .{ .name = dev.name, .pos = nodes[0], .neg = if (nodes.len > 1) nodes[1] else GROUND });
                try self.topo_isrc.append(self.arena, .{ .pos = nodes[0], .neg = if (nodes.len > 1) nodes[1] else GROUND, .dc = bound[0].dc });
            },
            'w' => if (self.nl.deck.dialect == .hspice) try self.addWline(dev) else try self.deferred.append(self.arena, dev),
            's' => if (self.nl.deck.dialect == .hspice) try self.addSparam(dev) else try self.addByLetter(letter, dev),
            'f', 'h', 'k' => try self.deferred.append(self.arena, dev),
            // A tape that reads i() waits until every branch row exists.
            'b' => if (readsCurrent(self.nl, dev)) try self.deferred.append(self.arena, dev) else try self.addB(dev),
            'p' => try self.addCpl(dev),
            'o' => try self.addLossyLine(dev),
            'y' => try self.addTxl(dev),
            'u' => try self.addUrc(dev),
            'e', 'g' => if (kvNumber(dev.kv, "laplace") != null) {
                try addLaplace(self, dev, letter);
            } else if (kvNumber(dev.kv, "pole") != null) {
                try addPole(self, dev, letter);
            } else if (kvNumber(dev.kv, "td") != null) {
                try addDelay(self, dev, letter);
            } else {
                try self.addByLetter(letter, dev);
                if (letter == 'e') try self.addBranchProbe(dev.name, internalRow(devices.vcvs, "flowZ28pZ2cnZ29", self.b.n));
            },
            else => try self.addByLetter(letter, dev),
        }
    }

    /// TXL (Y card) on txl.va's Pade/history line. The RC case inp2y
    /// expands into 3-pi sections (r/l > 1.6e10) is refused, not approximated;
    /// a failed fit refuses the run (txl.va $fatal).
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
        var nm: devices.txl.Model = .{ .r = r, .l = l, .g = g, .c = c, .len = len };
        deriveModel(devices.txl, &nm, self.b, dev.pins.len);
        // ngspice's inp2y binds the signal nodes and ignores the references.
        const n1 = try self.rowOf(dev.pins[0]);
        const n2 = try self.rowOf(dev.pins[2]);
        try self.b.addDevice(devices.txl, dev.name, nm, .{}, [4]u32{ n1, GROUND, n2, GROUND });
        // ngspice writes duplicate i(Y) names; the oracle keeps the last
        // (far-end) branch, as for CPL.
        try self.addBranchProbe(dev.name, self.b.n - 1);
    }

    /// LTRA (O card), routed as ngspice LTRAsetup does:
    /// RLC (r,l,c > 0, g = 0) and RC (r,c > 0, l = g = 0) go to the
    /// recursive-convolution device (ltra.va: history, coefficients, chop,
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
                deriveModel(devices.lossy_tline, &model, self.b, dev.pins.len);
                return self.b.addDevice(devices.lossy_tline, dev.name, model, .{}, try deviceNodes(self, devices.lossy_tline, dev));
            }
            return error.UnsupportedTransmissionLineParameters;
        }

        var ports: [4]u32 = undefined;
        for (&ports, dev.pins) |*port, pin| port.* = try self.rowOf(pin);

        if (rc or r_t > 0) {
            var nm: devices.ltra.Model = .{
                .r = model.r,
                .l = model.l,
                .g = model.g,
                .c = model.c,
                .len = model.len,
                .compactrel = model.compactrel,
                .compactabs = model.compactabs,
                .rel = model.rel,
                .steplimit = if (model.nosteplimit != 0) 0 else 1,
                .truncdontcut = model.truncdontcut,
            };
            deriveModel(devices.ltra, &nm, self.b, dev.pins.len);
            return self.b.addDevice(devices.ltra, dev.name, nm, .{}, ports);
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
        // K = 1 makes the geometric sizing below 0/0, and K <= 0 sizes no
        // ladder at all: refused rather than stamped as NaN resistors.
        if (!(k > 0) or k == 1) return error.InvalidParameterValue;
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
        const given = positionalNumber(dev, 0) orelse try numericParameter(dev.kv, value_field) orelse try numericParameter(dev.kv, alias);
        var value = if (given) |v| (if (D == devices.resistor) resistanceFloor(v) else v) else blk: {
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
                // restemp.c: "resistance too low or not given, set to 1 mOhm".
                break :blk 1e-3;
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
            // `ac=` is an AC-only resistance (restemp.c:112-118) with the same
            // instance factors; Circuit.linearizeAc swaps it in.
            if (kvNumber(dev.kv, "ac")) |ac_r|
                try self.ac_res.append(self.arena, .{ .name = dev.name, .value = resistanceFloor(ac_r) * scale / mult });
        }
        // The model card first (`.model rm R(TC1=2e-3 TNOM=25)`), so the card
        // value and instance pairs win over it, as in ngspice's RESmodel.
        if (dev.model) |m| try applyKv(&model, m.kv);
        _ = try setParam(D, &model, &instance, value_field, value);
        try applyKv(&model, dev.kv);
        try applyKv(&instance, dev.kv);
        // `$simparam` defaults after the last write: `tnom` is ngspice's
        // CKTnomTemp for R's tc1/tc2 (restemp.c), a card TNOM still wins.
        deriveModel(D, &model, self.b, dev.pins.len);
        const nodes = try deviceNodes(self, D, dev);
        const br = self.b.n;
        try self.b.addDevice(D, dev.name, model, instance, nodes);
        return br;
    }

    /// `dev` with its waveform in the source models' argument order. PULSE's
    /// eighth argument is ngspice's pulse count (vsrcload.c:120-135), which
    /// becomes a PWL of that many pulses, and the ngspice dialect's
    /// `AM(VO VMO VMA FM FC TD PHASEM PHASEC)` (vsrcload.c:283-315) maps onto
    /// the models' HSPICE-order AM. Any other card comes back as it is.
    fn ngspiceWaveform(self: *const NetBuilder, dev: Device) !Device {
        const w = waveAt(dev) orelse return dev;
        const args: []const Value = switch (w.kind) {
            .pulse => if (w.args.len < 8) return dev else try self.pulseTrain(dev.name, w.args),
            .am => if (self.nl.deck.dialect == .hspice or w.args.len < 2) return dev else try self.amArgs(dev.name, w.args),
            else => return dev, // else: only PULSE and AM have an order to fix
        };
        const kind: []const u8 = if (w.kind == .am or args.len == 7) @tagName(w.kind) else "pwl";
        const positional = try self.arena.alloc(Value, dev.positional.len - (w.end - w.start) + 1);
        @memcpy(positional[0..w.start], dev.positional[0..w.start]);
        positional[w.start] = .{ .group = .{ .name = kind, .args = args } };
        @memcpy(positional[w.start + 1 ..], dev.positional[w.end..]);
        var out = dev;
        out.positional = positional;
        return out;
    }

    /// PULSE arguments with ngspice's pulse count NP (the eighth) applied:
    /// the first seven when the count never ends the train before TSTOP,
    /// else PWL points for NP pulses and then V1.
    /// ponytail: a PWL, not a model parameter; the models carry no count, and
    /// past 4096 pulses the card is refused.
    fn pulseTrain(self: *const NetBuilder, name: []const u8, args: []const Value) ![]const Value {
        var a: [8]f64 = undefined;
        for (&a, args[0..8]) |*x, v| x.* = valueNumber(v) orelse return error.UnresolvedParameter;
        const v1, const v2, const td = .{ a[0], a[1], a[2] };
        const tr = if (a[3] != 0) a[3] else self.tran_step;
        const tf = if (a[4] != 0) a[4] else self.tran_step;
        const pw = if (a[5] != 0) a[5] else self.tran_stop;
        const per = @max(if (a[6] != 0) a[6] else self.tran_stop, tr + pw + tf);
        const end = td + a[7] * per;
        if (!(a[7] > 0) or end >= self.tran_stop) return args[0..7];
        const pulses = @ceil(a[7]);
        if (pulses > 4096) {
            if (!@import("builtin").is_test) std.log.err("{s}: a PULSE count past 4096 pulses", .{name});
            return error.UnsupportedCard;
        }
        var pts: std.ArrayList(Value) = .empty;
        try pts.appendSlice(self.arena, &.{ .{ .num = td }, .{ .num = v1 } });
        var t_prev = td;
        var v_prev = v1;
        var k: f64 = 0;
        corners: while (k < pulses) : (k += 1) {
            const base = td + k * per;
            const corners = [_][2]f64{ .{ base + tr, v2 }, .{ base + tr + pw, v2 }, .{ base + tr + pw + tf, v1 }, .{ base + per, v1 } };
            for (corners) |c| {
                if (c[0] == t_prev) continue;
                if (c[0] > end) {
                    // ngspice holds V1 past NP*PER: cut the pulse there.
                    const v_end = v_prev + (c[1] - v_prev) * (end - t_prev) / (c[0] - t_prev);
                    try pts.appendSlice(self.arena, &.{ .{ .num = end }, .{ .num = v_end }, .{ .num = end }, .{ .num = v1 } });
                    break :corners;
                }
                try pts.appendSlice(self.arena, &.{ .{ .num = c[0] }, .{ .num = c[1] } });
                t_prev, v_prev = c;
            }
        }
        return pts.items;
    }

    /// The ngspice dialect's `AM(VO VMO VMA FM FC TD PHASEM PHASEC)`, value
    /// VO + (VMO + VMA sin(2 pi FM t' + PHASEM)) sin(2 pi FC t' + PHASEC) on
    /// t' = t - TD, as the models' `AM(VA VO MF FC TD PHASEC PHASES)`, value
    /// VA (VO + sin(2 pi MF t + PHASES)) sin(2 pi FC t + PHASEC): the delay
    /// moves into the phases, and VMA = 0 holds the envelope at sin(90).
    /// ponytail: a nonzero VO offset is refused; the models have no slot for it.
    fn amArgs(self: *const NetBuilder, name: []const u8, args: []const Value) ![]const Value {
        var a = [8]f64{ 0, 0, 1, 5 / self.tran_stop, 500 / self.tran_stop, 0, 0, 0 };
        for (a[0..@min(args.len, 8)], args[0..@min(args.len, 8)]) |*x, v| x.* = valueNumber(v) orelse return error.UnresolvedParameter;
        const vo, const vmo, const vma, const fm, const fc, const td, const phasem, const phasec = a;
        if (vo != 0) {
            if (!@import("builtin").is_test) std.log.err("{s}: AM with a nonzero VO offset", .{name});
            return error.UnsupportedCard;
        }
        const out = try self.arena.alloc(Value, 7);
        const ours = if (vma != 0)
            [7]f64{ vma, vmo / vma, fm, fc, td, phasec - 360 * fc * td, phasem - 360 * fm * td }
        else
            [7]f64{ vmo, 0, 0, fc, td, phasec - 360 * fc * td, 90 };
        for (out, ours) |*o, x| o.* = .{ .num = x };
        return out;
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
        try refuseUnknownWave(dev);
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
        if (kvNumber(dev.kv, "r")) |r| if (pwlArgs(dev)) |pts| {
            // vsrcpar.c:160-176: the repeat start is one of the table's
            // times and before its last.
            var on_point = false;
            var k: usize = 0;
            while (k + 1 < pts.len) : (k += 2) on_point = on_point or valueNumber(pts[k]) == r;
            const last = if (pts.len >= 2) valueNumber(pts[pts.len - pts.len % 2 - 2]) orelse r else r;
            if (!on_point or r >= last) {
                if (!@import("builtin").is_test) std.log.err("{s}: PWL r={e} is not a time point before the last", .{ dev.name, r });
                return error.InvalidParameterValue;
            }
            _ = try setParam(D, &model, &instance, "pwl_repeat", r);
        };
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
        switch (resolveDeviceId(letter, dev) catch |err| return named(dev, err)) {
            inline else => |comptime_id| {
                const D = devices.DeviceId.Type(comptime_id);
                addSingleDevice(self, D, dev) catch |err| return named(dev, err);
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
        try source_index.ensureTotalCapacity(self.arena, @intCast(self.v.len));
        for (self.v.items(.name), 0..) |name, i| {
            const entry = source_index.getOrPutAssumeCapacity(name);
            if (!entry.found_existing) entry.value_ptr.* = @intCast(i);
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

    /// CPL (P card) on coupled_ltra.va's modal-fit, accepted-step convolution
    /// line, for 2 to 4 conductors. Anything else is refused, never
    /// approximated; a failed modal fit refuses the run ($fatal).
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
        inline for (.{ devices.coupled_ltra, devices.coupled_ltra3, devices.coupled_ltra4 }) |D| {
            const N = (D.num_ports - 2) / 2;
            if (n_lines == N) {
                var model: D.Model = .{ .length = length };
                inline for (0..10) |k| if (k < tri) {
                    @field(model, pwlSlot("r", k)) = rr[k];
                    @field(model, pwlSlot("l", k)) = ll[k];
                    @field(model, pwlSlot("c", k)) = cc[k];
                    @field(model, pwlSlot("g", k)) = gg[k];
                };
                deriveModel(D, &model, self.b, dev.pins.len);
                // ngspice cplsetup binds conductor nodes and ignores references.
                var nodes: [2 * N + 2]u32 = @splat(GROUND);
                for (0..N) |i| nodes[i] = try self.rowOf(dev.pins[i]);
                for (0..N) |i| nodes[N + 1 + i] = try self.rowOf(dev.pins[N + 1 + i]);
                try self.b.addDevice(D, dev.name, model, .{}, nodes);
                try self.addBranchProbe(dev.name, self.b.n - 1);
                return;
            }
        }
        unreachable;
    }

    /// HSPICE W element [SI Ch.3]: `Wx i1..iN iR o1..oN oR N= L=` with
    /// `RLGCMODEL=` (a `.model m W MODELTYPE=RLGC`) or `RLGCFILE=`, on
    /// models/wline_N.va: the modal rational fit of wfit.zig run by the
    /// method of characteristics. Refused: other model forms and N > 4.
    fn addWline(self: *NetBuilder, dev: Device) !void {
        var m: WMatrices = .{};
        var n: usize = 0;
        if (kvName(dev.kv, "rlgcmodel")) |name| {
            const card = self.nl.findModel(name) orelse return refuseW(dev, "no .model named by RLGCMODEL");
            if (!std.mem.eql(u8, card.kind, "w")) return refuseW(dev, "RLGCMODEL names a model that is not type W");
            if (kvName(card.kv, "modeltype")) |t| if (!std.mem.eql(u8, t, "rlgc")) return refuseW(dev, "only MODELTYPE=RLGC is supported");
            // Clamped first: @intFromFloat of N=1e30 is illegal behaviour.
            n = @intFromFloat(std.math.clamp((try numericParameter(card.kv, "n")) orelse 0, 0, wfit.max_n + 1));
            if (n == 0 or n > wfit.max_n) return refuseW(dev, "N must be 1 to 4");
            const tri = n * (n + 1) / 2;
            const keys = [_][2][]const u8{ .{ "lo", "l" }, .{ "co", "c" }, .{ "ro", "r" }, .{ "go", "g" }, .{ "rs", "" }, .{ "gd", "" } };
            for (keys, 0..) |k, which| {
                var got = try cplVector(card.kv, k[0], m.tri[which][0..tri]);
                if (got == 0 and k[1].len != 0) got = try cplVector(card.kv, k[1], m.tri[which][0..tri]);
                if (got != 0 and got != tri) return refuseW(dev, "a matrix does not hold N(N+1)/2 lower-triangle entries");
                if (got == 0 and which < 2) return refuseW(dev, "Lo and Co are required");
            }
        } else if (kvName(dev.kv, "rlgcfile")) |path| {
            const bytes = self.nl.dataFile(path) orelse return refuseW(dev, "RLGCFILE was not read");
            const file = wfit.readRlgcFile(bytes) catch |err| return refuseW(dev, switch (err) {
                error.TooManyConductors => "N must be 1 to 4",
                error.InvalidRlgcFile => "malformed RLGC file",
            });
            n = file.n;
            for (file.tri[0..file.mats], m.tri[0..file.mats]) |src, *dst| @memcpy(dst[0..src.len], &src);
        } else return refuseW(dev, "only RLGCMODEL= and RLGCFILE= are supported (TABLEMODEL, UMODEL, FSMODEL and SMODEL are not)");
        if (try numericParameter(dev.kv, "n")) |nn| if (nn != @as(f64, @floatFromInt(n))) return refuseW(dev, "N differs from the model's");
        if (dev.pins.len != 2 * n + 2) return refuseW(dev, "the node count is not 2N+2");
        const length = (try numericParameter(dev.kv, "l")) orelse return refuseW(dev, "L= (length) is required");
        if (!(length > 0)) return refuseW(dev, "L must be positive");
        var p: wfit.Rlgc = .{
            .n = n,
            .length = length,
            .fgd = (try numericParameter(dev.kv, "fgd")) orelse 0,
            .rs_imag = if (kvName(dev.kv, "includersimag")) |v| !std.mem.eql(u8, v, "no") else (kvNumber(dev.kv, "includersimag") orelse 1) != 0,
        };
        for ([_]*[wfit.max_n][wfit.max_n]f64{ &p.l, &p.c, &p.r, &p.g, &p.rs, &p.gd }, m.tri) |dst, tri| {
            var idx: usize = 0;
            for (0..n) |i| for (0..i + 1) |j| {
                dst[i][j] = tri[idx];
                dst[j][i] = tri[idx];
                idx += 1;
            };
        }
        var nodes: [2 * wfit.max_n + 2]u32 = undefined;
        for (dev.pins, nodes[0..dev.pins.len]) |pin, *row| row.* = try self.rowOf(pin);
        inline for (.{ devices.wline_1, devices.wline_2, devices.wline_3, devices.wline_4 }, 1..) |D, N| if (n == N) {
            if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
            const k = comptime slotCount(D.Model, "ycp") / (3 * N);
            const line = wfit.fitLine(self.arena, p, k) catch |err| return refuseW(dev, @errorName(err));
            var model: D.Model = .{};
            var tv: [N * N]f64 = undefined;
            var ti: [N * N]f64 = undefined;
            var rdc: [N * N]f64 = undefined;
            var gdc: [N * N]f64 = undefined;
            for (0..N) |i| for (0..N) |j| {
                tv[i * N + j] = line.tv[i][j];
                ti[i * N + j] = line.ti[i][j];
                rdc[i * N + j] = p.r[i][j] * length;
                gdc[i * N + j] = p.g[i][j] * length / 2;
            };
            var z0: [N]f64 = undefined;
            var td: [N]f64 = undefined;
            var ycd: [N]f64 = undefined;
            var hd: [N]f64 = undefined;
            var ycn: [2 * N * k]f64 = @splat(0);
            var hn: [2 * N * k]f64 = @splat(0);
            var ycp: [3 * N * k]f64 = undefined;
            var hp: [3 * N * k]f64 = undefined;
            for (0..N * k) |s| {
                ycp[3 * s ..][0..3].* = .{ 1, 0, 0 };
                hp[3 * s ..][0..3].* = .{ 1, 0, 0 };
            }
            for (line.modes[0..N], 0..) |md, mi| {
                z0[mi] = md.z0;
                td[mi] = md.tau;
                ycd[mi] = md.yc.d;
                hd[mi] = md.h.d;
                for (md.yc.num, md.yc.den, 0..) |nm, dn, s| {
                    ycn[2 * (mi * k + s) ..][0..2].* = nm;
                    ycp[3 * (mi * k + s) ..][0..3].* = dn;
                }
                for (md.h.num, md.h.den, 0..) |nm, dn, s| {
                    hn[2 * (mi * k + s) ..][0..2].* = nm;
                    hp[3 * (mi * k + s) ..][0..3].* = dn;
                }
                const err = @max(md.yc.rel_err, md.h.rel_err);
                if (err > 1e-2 and !@import("builtin").is_test)
                    std.log.warn("W element '{s}': mode {d} rational fit error {e:.2}", .{ dev.name, mi, err });
            }
            inline for (.{ "tv", "ti", "rdc", "gdc", "z0", "td", "ycd", "hd", "ycn", "hn", "ycp", "hp" }, .{ &tv, &ti, &rdc, &gdc, &z0, &td, &ycd, &hd, &ycn, &hn, &ycp, &hp }) |base, values|
                setArray(D.Model, &model, base, values);
            return self.b.addDevice(D, dev.name, model, .{}, nodes[0 .. 2 * N + 2].*);
        };
        unreachable;
    }

    /// HSPICE S element [SI Ch.2]: `Sx nd1..ndN [ndR] MNAME=m`, `.model m S
    /// TSTONEFILE=f.sNp`, on models/sparam_N.va: the file's admittance
    /// vector fitted with common poles and made passive (sparam.zig), every
    /// entry a sum of second-order sections. Refused: FQMODEL/CITIFILE/
    /// RFMFILE data, mixed mode, N > 4, and a fit that cannot be made
    /// passive.
    fn addSparam(self: *NetBuilder, dev: Device) !void {
        const model_name = kvName(dev.kv, "mname") orelse return refuseS(dev, "MNAME= is required (FQMODEL is not supported)");
        const card = self.nl.findModel(model_name) orelse return refuseS(dev, "no .model named by MNAME");
        if (!std.mem.eql(u8, card.kind, "s")) return refuseS(dev, "MNAME names a model that is not type S");
        for ([_][]const u8{ "fqmodel", "citifile", "rfmfile" }) |k| if (kvName(card.kv, k) != null or kvName(dev.kv, k) != null)
            return refuseS(dev, "only TSTONEFILE data is supported");
        if ((kvNumber(card.kv, "mixedmode") orelse 0) != 0 or (kvNumber(dev.kv, "mixedmode") orelse 0) != 0)
            return refuseS(dev, "mixed-mode data is not supported");
        const path = kvName(card.kv, "tstonefile") orelse return refuseS(dev, "TSTONEFILE= is required");
        const ext = std.fs.path.extension(path);
        const from_ext: ?usize = if (ext.len >= 4 and std.ascii.toLower(ext[1]) == 's' and std.ascii.toLower(ext[ext.len - 1]) == 'p')
            std.fmt.parseInt(usize, ext[2 .. ext.len - 1], 10) catch null
        else
            null;
        const p: usize = if (try numericParameter(card.kv, "n")) |n| @intFromFloat(std.math.clamp(n, 0, 5)) else from_ext orelse return refuseS(dev, "the port count is neither N= nor a .sNp extension");
        if (p == 0 or p > 4) return refuseS(dev, "1 to 4 ports are supported");
        if (dev.pins.len != p and dev.pins.len != p + 1) return refuseS(dev, "the node count is not N or N+1");
        const bytes = self.nl.dataFile(path) orelse return refuseS(dev, "TSTONEFILE was not read");
        const net = sparam.parseTouchstone(self.arena, bytes, p) catch |err| return refuseS(dev, @errorName(err));
        var nodes: [5]u32 = @splat(GROUND);
        for (dev.pins, nodes[0..dev.pins.len]) |pin, *row| row.* = try self.rowOf(pin);
        inline for (.{ devices.sparam_1, devices.sparam_2, devices.sparam_3, devices.sparam_4 }, 1..) |D, N| if (p == N) {
            if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
            const k = comptime slotCount(D.Model, "den") / 3;
            var fit = try sparam.fit(self.arena, net, .{ .max_order = 2 * k });
            if (!try sparam.enforcePassivity(self.arena, net, &fit)) return refuseS(dev, "the rational fit could not be made passive");
            if (fit.rel_err > 1e-3 and !@import("builtin").is_test)
                std.log.warn("S element '{s}': rational fit error {e:.2} of max |Y|", .{ dev.name, fit.rel_err });
            const sec = try sparam.sections(self.arena, fit);
            var model: D.Model = .{};
            var d: [N * N]f64 = undefined;
            @memcpy(&d, fit.d);
            var den: [3 * k]f64 = undefined;
            var num: [2 * N * N * k]f64 = @splat(0);
            for (0..k) |s| den[3 * s ..][0..3].* = if (s < sec.den.len) sec.den[s] else .{ 1, 0, 0 };
            for (0..N * N) |e| for (sec.num[e * sec.den.len ..][0..sec.den.len], 0..) |nm, s| {
                num[2 * (e * k + s) ..][0..2].* = nm;
            };
            inline for (.{ "d", "den", "num" }, .{ &d, &den, &num }) |base, values| setArray(D.Model, &model, base, values);
            return self.b.addDevice(D, dev.name, model, .{}, nodes[0 .. N + 1].*);
        };
        unreachable;
    }

    /// F, H or W card: a device whose 0 V control branch is the next link of
    /// the sensed V card's chain (`VCard.tap`). `default_gain` null: no gain parameter.
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
        try applyKv(&instance, dev.kv);

        // (p, n, cp, cn): the model's `branch (cp, cn) ctrl` at `vsense` = 0
        // is an ammeter in series with the sensed source.
        const left = &self.v.items(.sensors)[ctrl];
        std.debug.assert(left.* != 0); // init counted this card
        left.* -= 1;
        const tap = &self.v.items(.tap)[ctrl];
        const cp = tap.*;
        tap.* = if (left.* == 0) self.v.items(.neg)[ctrl] else try self.b.addNode();
        const nodes = [4]u32{
            if (dev.pins.len > 0) try self.rowOf(dev.pins[0]) else GROUND,
            if (dev.pins.len > 1) try self.rowOf(dev.pins[1]) else GROUND,
            cp,
            tap.*,
        };
        try self.b.addDevice(D, dev.name, model, instance, nodes);
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
        if (positionalNumber(dev, 2)) |k| model.k = try castField(@TypeOf(model.k), k);
        if (dev.model) |m| try applyKv(&model, m.kv);
        try applyKv(&model, dev.kv);
        // The card gives the coupling k; the device stamps M = k*sqrt(L1*L2)
        // (ngspice INDsetup).
        model.k = try castField(@TypeOf(model.k), model.k *
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

/// `err`, logged with the card and its model when it is `UnsupportedDevice`,
/// so the refusal names what to fix (#75).
fn named(dev: Device, err: anyerror) anyerror {
    if (err == error.UnsupportedDevice and !@import("builtin").is_test) {
        const m = dev.model orelse return err;
        std.log.err("{s}: model '{s}' ({s}) is not a device this card can use", .{ dev.name, m.name, m.kind });
    }
    return err;
}

/// The built-in model kinds of each semiconductor letter. A card whose model
/// is another letter's kind is refused, as ngspice's "incorrect model type"
/// (#75); a kind outside these (an HDL module) is not checked.
const letter_kinds = std.StaticStringMap(u8).initComptime(.{
    .{ "nmos", 'm' }, .{ "pmos", 'm' },  .{ "vdmos", 'm' },
    .{ "npn", 'q' },  .{ "pnp", 'q' },   .{ "d", 'd' },
    .{ "njf", 'j' },  .{ "pjf", 'j' },   .{ "nmf", 'z' },
    .{ "pmf", 'z' },  .{ "nhfet", 'z' }, .{ "phfet", 'z' },
});

fn deviceIdOf(letter: u8, dev: Device) !devices.DeviceId {
    if (dev.model) |m| if (std.mem.indexOfScalar(u8, "mqdjz", letter) != null) {
        var buf: [8]u8 = undefined;
        const owner = if (m.kind.len <= buf.len) letter_kinds.get(std.ascii.lowerString(&buf, m.kind)) else null;
        if (owner != null and owner.? != letter) return error.UnsupportedDevice;
        // ponytail: vdmos.va has no polarity parameter, so a P-channel
        // VDMOS is refused rather than run N-channel; add `type` to the .va.
        if (owner == 'm' and std.ascii.eqlIgnoreCase(m.kind, "vdmos")) for (m.kv) |kv| {
            if (kv.key.len == 0 and kv.value == .name and std.ascii.eqlIgnoreCase(kv.value.name, "pchan")) return error.UnsupportedDevice;
        };
    };
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
    // The Verilog-A module name an OSDI deck loads the model under.
    var lower: [32]u8 = undefined;
    if (m.kind.len <= lower.len) {
        if (devices.module_map.get(std.ascii.lowerString(&lower, m.kind))) |id| return id;
    }
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
    } else if (comptime @hasField(D.Model, "jtype")) {
        model.jtype = -1; // jfet/jfet2: PJF (#75)
        markGiven(model, "jtype");
    } else if (comptime @hasField(D.Model, "ztype")) {
        model.ztype = -1; // mes: PMF
        markGiven(model, "ztype");
    } else if (comptime @hasField(D.Model, "type_nfet")) {
        model.type_nfet = -1; // hfet2: PHFET
        markGiven(model, "type_nfet");
    } else {
        // ponytail: mesa and vdmos have no polarity parameter, so
        // a P-type card on them is refused rather than run N-type (silent
        // NaN). Upgrade path: a `type` parameter in the .va, as mos1 has.
        return error.UnsupportedDevice;
    }
}

/// VerA's reserved Model fields for §9.15 `$simparam`, each with the Builder
/// field it is copied from: tnom (degC), reltol, abstol (A), vntol (V), gmin
/// (S). `source_scale__` keeps its default 1 until source stepping. See
/// VerA's `Lower.simparamHostField`.
const simparam_fields = .{
    .{ "nom_temp__", "nom_temp_c" },
    .{ "reltol__", "reltol" },
    .{ "abstol__", "abstol" },
    .{ "vntol__", "vntol" },
    .{ "gmin__", "gmin" },
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
///
/// A card with `pins` nodes leaves the module's later ports unconnected:
/// §9.19 `$port_connected` reads `Model.port_connected__` (bit p = port p,
/// all ones by default), written here because `derive` may read it. A
/// 4-terminal card on HiSIM_HV's 6-port module clears `sub` and `temp`, as
/// its 4-node path expects.
fn deriveModel(comptime D: type, model: *D.Model, b: *const Builder, pins: usize) void {
    inline for (simparam_fields) |f| {
        if (comptime @hasField(D.Model, f[0])) @field(model, f[0]) = @field(b, f[1]);
    }
    if (comptime @hasField(D.Model, "port_connected__")) {
        if (pins < 64) model.port_connected__ &= (@as(u64, 1) << @intCast(pins)) - 1;
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
    // INP2Q/D/J/Z: a bare number after the model name is the area; area=
    // below still wins.
    switch (dev.kind) {
        'q', 'd', 'j', 'z' => if (positionalNumber(dev, 1)) |a| {
            _ = try setParam(D, &model, &instance, "area", a);
        },
        else => {},
    }
    // Card pairs go to both structs: VerA puts every Verilog-A `parameter`
    // (W and L included) on Model. `model` is a per-device copy, so this
    // overrides the model card for this instance only.
    // LRM §6.3.6: `m=` on the instance card is the multiplier. A model
    // without an `m` of its own (bsim4va, hicum, hisim, bsimsoi), or whose
    // `m` is a shape (diode grading, hfet/mesa knee), takes it as the
    // instance's $mfactor (#48); the shape keeps the model card's value.
    const shape_m = comptime D == devices.DeviceId.Type(.diode) or D == devices.DeviceId.Type(.hfet1) or
        D == devices.DeviceId.Type(.hfet2) or D == devices.DeviceId.Type(.mesa);
    const to_mfactor = comptime (!@hasField(D.Model, "m") or shape_m) and @hasField(D.Instance, "mfactor");
    var kv = dev.kv;
    if (to_mfactor) if (kvNumber(dev.kv, "m")) |mv| {
        instance.mfactor = mv;
        const rest = try self.arena.alloc(Kv, dev.kv.len);
        var n: usize = 0;
        for (dev.kv) |item| if (!std.mem.eql(u8, item.key, "m")) {
            rest[n] = item;
            n += 1;
        };
        kv = rest[0..n];
    };
    try applyKv(&model, kv);
    try applyKv(&instance, kv);
    try refuseUnknownKeys(self.arena, D, dev.name, kv);
    // §6.3.4/§3.4.5: derived parameters after the last write; explicit card
    // values win through `__given`.
    deriveModel(D, &model, b, dev.pins.len);
    try b.addDevice(D, dev.name, model, instance, try deviceNodes(self, D, dev));
}

/// Refuses a card pair that neither `D.Model` nor `D.Instance` binds, as
/// ngspice refuses an unknown instance parameter: `ww=10u` for `w=10u`
/// would otherwise run with the default width (#35).
fn refuseUnknownKeys(arena: std.mem.Allocator, comptime D: type, name: []const u8, kv: []const Kv) !void {
    const params = try arena.alloc(batch.Param, kv.len);
    for (kv, params) |item, *p| p.* = .{ .key = item.key, .value = null };
    const known = try arena.alloc(bool, kv.len);
    @memset(known, false);
    batch.bind.markKnown(D.Model, params, known);
    batch.bind.markKnown(D.Instance, params, known);
    for (kv, known) |item, hit| if (!hit) {
        if (!@import("builtin").is_test) std.log.err("{s}: unknown instance parameter '{s}'", .{ name, item.key });
        return error.UnknownParameter;
    };
}

/// A card's resistance as ngspice resparam.c keeps it: the sign stays and
/// |R| is at least 1e-12 (0 is +1e-12), so `R1 a 0 -2k` is a negative
/// resistor, not the 1 mOhm restemp.c gives a missing value.
fn resistanceFloor(r: f64) f64 {
    return if (@abs(r) < 1e-12) std.math.copysign(@as(f64, 1e-12), r) else r;
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
                const folded = try foldConstants(self.arena, self.nl.exprOps(span), self.nl.consts);
                compileTape(self, folded.ops, folded.consts, &t, &nodes) catch |err| switch (err) {
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

/// E/G POLE card: H(s) = a (s - z1)...(s - zn) / (b (s - p1)...(s - pm)),
/// each root written `alpha, f` for s = -alpha + j 2 pi f [SA E-element
/// Pole-Zero Function], on models/vcvs_pole.va or vccs_pole.va
/// (`laplace_zp`). A complex root without its conjugate on the same side
/// is refused (UnpairedPoleRoot), as are more zeros than poles and more
/// than 8 roots a side.
fn addPole(self: *NetBuilder, dev: Device, letter: u8) !void {
    for (dev.kv) |item| {
        const known = std.StaticStringMap(void).initComptime(.{ .{"pole"}, .{"scale"}, .{"m"} });
        if (!known.has(item.key)) return error.UnsupportedLaplaceParameter;
    }
    // The parser checked both sides: a constant, then (alpha, f) pairs.
    const nk: usize = @intFromFloat(kvNumber(dev.kv, "pole").?);
    var v: [2 * (1 + 2 * 8)]f64 = undefined;
    if (dev.positional.len > v.len) return error.UnsupportedLaplaceOrder;
    for (dev.positional, v[0..dev.positional.len]) |p, *x| x.* = valueNumber(p) orelse return error.UnresolvedParameter;
    const zeros = v[1..nk];
    const poles = v[nk + 1 .. dev.positional.len];
    if (zeros.len > poles.len or poles.len > 2 * 8) return error.UnsupportedLaplaceOrder;
    // The roots as laplace_zp takes them, s = -alpha + j 2 pi f, padded with
    // inf, whose (1 - s/inf) term is exactly 1.
    var zr: [2 * 8]f64 = @splat(0);
    var pr: [2 * 8]f64 = @splat(0);
    inline for (.{ zeros, poles }, .{ &zr, &pr }) |side, r| {
        for (0..8) |k| r[2 * k] = std.math.inf(f64);
        for (0..side.len / 2) |k| r[2 * k ..][0..2].* = .{ -side[2 * k], 2 * std.math.pi * side[2 * k + 1] };
    }
    // laplace_zp is prod(1 - s/r), and s - r = -r (1 - s/r) for r != 0.
    const gain = cardScale(dev, letter) * v[0] / v[nk] * try rootProduct(zr[0..zeros.len]) / try rootProduct(pr[0..poles.len]);
    inline for (.{ devices.vcvs_pole, devices.vccs_pole }, "eg") |D, l| if (letter == l) {
        if (comptime !@hasDecl(D, "eval")) return error.UnsupportedDevice;
        comptime std.debug.assert(slotCount(D.Model, "poles") == 2 * 8);
        var model: D.Model = .{};
        var instance: D.Instance = .{};
        _ = try setParam(D, &model, &instance, "gain", gain);
        inline for (0..2 * 8) |k| {
            @field(model, pwlSlot("zeros", k)) = zr[k];
            @field(model, pwlSlot("poles", k)) = pr[k];
        }
        try self.b.addDevice(D, dev.name, model, instance, try controlledNodes(self, dev));
        if (l == 'e') try self.addBranchProbe(dev.name, internalRow(D, "flowZ28pZ2cnZ29", self.b.n));
    };
}

/// prod(-r) over the nonzero roots `r` of one side, (re, im) pairs. Pairs
/// complex roots as VerA's zRootSecs does (the first unused root within 1e-9
/// relative of the conjugate), so a root it would turn into NaN is refused.
fn rootProduct(r: []const f64) error{UnpairedPoleRoot}!f64 {
    var used: [8]bool = @splat(false);
    var prod: f64 = 1;
    for (0..r.len / 2) |i| {
        if (used[i]) continue;
        used[i] = true;
        const a = r[2 * i];
        const b = r[2 * i + 1];
        if (b == 0) {
            if (a != 0) prod *= -a;
            continue;
        }
        const tol = 1e-9 * @sqrt(a * a + b * b);
        const j = for (0..r.len / 2) |c| {
            if (!used[c] and @abs(r[2 * c] - a) <= tol and @abs(r[2 * c + 1] + b) <= tol) break c;
        } else return error.UnpairedPoleRoot;
        used[j] = true;
        prod *= a * a + b * b;
    }
    return prod;
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
        num,
        v,
        vd,
        neg,
        not,
        add,
        sub,
        mul,
        div,
        powi,
        powc,
        pow,
        lt,
        gt,
        le,
        ge,
        eq,
        ne,
        @"and",
        @"or",
        sel,
        sqrt,
        abs,
        min,
        max,
        exp,
        ln,
        log10,
        sin,
        cos,
        tan,
        atan,
        tanh,
        floor,
        ceil,
        time,
        temper,
        pwl,
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
            @field(model, pwlSlot("op_code", k)) = @backingInt(t.op_code[k]);
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

/// `ops` with every constant subtree folded to one `.num`, the consts it
/// reads renumbered into a fresh pool. A parameter spliced into a B
/// expression arrives as its own postfix (sky130's `rbody` carries
/// `mc_mm_switch*agauss(...)`), so without this the tape would hold
/// distribution calls and spend its op budget on arithmetic of constants.
/// Distributions fold to their nominal, as `expr.fold` does.
fn foldConstants(arena: std.mem.Allocator, ops: []const Op, consts: []const f64) !struct { ops: []const Op, consts: []const f64 } {
    var out: std.ArrayList(Op) = .empty;
    var pool: std.ArrayList(f64) = .empty;
    var stack: std.ArrayList(netlist.expr.Val) = .empty;
    for (ops) |op| {
        if (op.code == .num) {
            try out.append(arena, .{ .code = .num, .a = @intCast(pool.items.len) });
            try pool.append(arena, consts[op.a]);
            continue;
        }
        const k = netlist.expr.arity(op);
        const table = op.code == .call and @as(netlist.expr.Fn, @fromBackingInt(@intCast(op.a))) == .table;
        const foldable = k > 0 and k <= out.items.len and !table and op.code != .live and
            for (out.items[out.items.len - k ..]) |o| {
                if (o.code != .num) break false;
            } else true;
        if (!foldable) {
            try out.append(arena, op);
            continue;
        }
        // The operands are the last k consts, in order.
        var mini: [9]Op = undefined;
        if (k + 1 > mini.len) {
            try out.append(arena, op);
            continue;
        }
        for (0..k) |i| mini[i] = .{ .code = .num, .a = @intCast(i) };
        mini[k] = op;
        const args = pool.items[pool.items.len - k ..];
        const v = try netlist.expr.eval(arena, &stack, mini[0 .. k + 1], args, &.{}, null);
        if (std.math.isNan(v)) {
            try out.append(arena, op);
            continue;
        }
        out.shrinkRetainingCapacity(out.items.len - k);
        pool.shrinkRetainingCapacity(pool.items.len - k);
        try out.append(arena, .{ .code = .num, .a = @intCast(pool.items.len) });
        try pool.append(arena, v);
    }
    return .{ .ops = out.items, .consts = pool.items };
}

/// Translates a postfix card expression into the bsource tape, giving each
/// distinct probed row (a net, or the branch an i() reads) a control port in
/// `nodes`. Fails on anything the tape cannot express or hold.
fn compileTape(self: *NetBuilder, ops: []const Op, consts: []const f64, model: *Tape, nodes: []u32) !void {
    var rows: [tape.max_probes]u32 = undefined;
    var n_rows: usize = 0;
    var n_consts: usize = 0;
    var n: usize = 0;
    for (ops) |op| {
        if (n == tape.max_ops) return error.TooManyOps;
        const code: tape.Code = switch (op.code) {
            .num => blk: {
                if (n_consts == tape.max_consts) return error.TooManyConstants;
                model.consts[n_consts] = consts[op.a];
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
                        self.branchRow(self.nl.pool.str(@fromBackingInt(@intCast(id)))) orelse return error.UnknownCurrentProbe;
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
                if (@as(netlist.expr.Fn, @fromBackingInt(@intCast(op.a))) != .table) break :blk try callCode(@fromBackingInt(@intCast(op.a)), op.b);
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
            // The tape has no opcode for numparam's `%` and `\`; they fold
            // when their operands are constant.
            .live, .mod, .idiv => return error.UnsupportedOperand,
            // `subst` resolves every one; none reaches a tape.
            .ucall => return error.UnsupportedFunction,
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
                // ngspice's pow() function is |x|^y whatever y is (ptfuncs.c
                // PTpower); only the `^`/`**` operator keeps the sign of x
                // for an integer exponent (PTpowerH). sky130's poly
                // resistors cube a negative min(...) with pow().
                if (op.code == .call and self.nl.deck.dialect == .ngspice) {
                    if (n + 1 == tape.max_ops) return error.TooManyOps;
                    model.op_code[n] = .abs;
                    n += 1;
                }
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
        .min, .max, .pow, .pwr => 2,
        .ternary => 3,
        else => 1,
    };
    if (argc != want) return error.WrongArity;
    return switch (f) {
        .ternary => .sel,
        .ln, .log => .ln,
        // ponytail: pwr folds when its arguments are constant (sky130's
        // pwr(l,0.5)); a tape opcode is needed only if one reads a probe.
        .pwr, .agauss, .gauss, .unif, .aunif, .limit, .table, .other => error.UnsupportedFunction,
        // numparam built-ins with no tape opcode: they fold when their
        // arguments are constant, and a B source reading a probe refuses them.
        .sqr, .int, .nint, .sgn, .sinh, .cosh, .asin, .acos, .asinh, .acosh, .atanh => error.UnsupportedFunction,
        // ponytail: HSPICE's signed sqrt/log and integer-exponent pow fold
        // on constants; a tape opcode is needed only if one reads a probe.
        .hsqrt, .hlog, .hlog10, .hpow => error.UnsupportedFunction,
        inline else => |g| @field(tape.Code, @tagName(g)),
    };
}

/// Source waveform shapes; the tag is the model's `waveform` code (0 is DC only).
const Wave = enum(u8) { pulse = 1, sin = 2, exp = 3, pwl = 4, sffm = 5, am = 6 };

/// Source waveforms ngspice or HSPICE define that the source models do not
/// draw. A card naming one is refused rather than run as its DC value
/// (#72), and so is HSPICE's `PWL FILE=`.
/// ponytail: refused, not drawn; TRNOISE/TRRANDOM need ngspice's noise
/// generator per source and breakpoints at each sample.
fn refuseUnknownWave(dev: Device) error{UnsupportedCard}!void {
    const unknown = std.StaticStringMap(void).initComptime(.{ .{"trnoise"}, .{"trrandom"}, .{"lfsr"}, .{"hb"} });
    var buf: [8]u8 = undefined;
    for (dev.positional) |v| {
        const name = switch (v) {
            .group => |g| g.name,
            .name => |n| n,
            else => continue, // else: numbers and expressions name no waveform
        };
        if (name.len > buf.len or !unknown.has(std.ascii.lowerString(&buf, name))) continue;
        if (!@import("builtin").is_test) std.log.err("{s}: the {s} source waveform is not supported", .{ dev.name, name });
        return error.UnsupportedCard;
    }
    for (dev.kv) |item| if (std.ascii.eqlIgnoreCase(item.key, "file")) {
        if (!@import("builtin").is_test) std.log.err("{s}: a PWL FILE= source is not supported", .{dev.name});
        return error.UnsupportedCard;
    };
}

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

/// Field name of slot `k` of a flattened Verilog-A array. VerA turns
/// `parameter real pwl_times[0:63]` into 64 scalar Model fields named with
/// the escaped subscript (`[` is `Z5b`, `]` is `Z5d`; see VerA
/// lib/backend/naming.zig), so the slot is picked at comptime.
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
    // The S and W templates hold arrays of a few hundred slots.
    @setEvalBranchQuota(10_000_000);
    comptime var n: usize = 0;
    inline while (@hasField(T, pwlSlot(base, n))) : (n += 1) {}
    return n;
}

/// Writes `values` over VerA array parameter `base` (fields `base[k]`),
/// whose slot count must equal `values.len`.
fn setArray(comptime T: type, model: *T, comptime base: []const u8, values: anytype) void {
    comptime std.debug.assert(slotCount(T, base) == values.len);
    @setEvalBranchQuota(10_000_000);
    inline for (0..values.len) |k| @field(model, pwlSlot(base, k)) = values[k];
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
    target.waveform = @backingInt(kind);
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
        // ngspice's omitted EXP time constants are TSTEP, which
        // resolvePulseDefaults fills over 0.
        .exp => {
            if (comptime @hasField(T, "exp_tau1")) {
                target.exp_tau1 = 0;
                target.exp_tau2 = 0;
            }
            applyGroupArgs(T, target, args, comptime fieldPairs(.exp));
        },
        inline else => |cw| applyGroupArgs(T, target, args, comptime fieldPairs(cw)),
    }
}

/// A card's waveform: its kind, its arguments, and the positional range
/// `[start, end)` that spells it (one group, or a keyword and its numbers).
const WaveAt = struct { kind: Wave, args: []const Value, start: usize, end: usize };

/// The first waveform of `dev`, or null when it has none.
fn waveAt(dev: Device) ?WaveAt {
    for (dev.positional, 0..) |v, i| switch (v) {
        .group => |g| if (waveKind(g.name)) |kind| return .{ .kind = kind, .args = g.args, .start = i, .end = i + 1 },
        .name => |nm| if (waveKind(nm)) |kind| {
            var end = i + 1;
            while (end < dev.positional.len and dev.positional[end] == .num) end += 1;
            return .{ .kind = kind, .args = dev.positional[i + 1 .. end], .start = i, .end = end };
        },
        else => {},
    };
    return null;
}

/// The PWL points of `dev`'s `PWL(...)` group, or null when it has none.
fn pwlArgs(dev: Device) ?[]const Value {
    const w = waveAt(dev) orelse return null;
    return if (w.kind == .pwl) w.args else null;
}

/// Models for the segments of a PWL past `D`'s table capacity: segment k
/// starts on the last point of the one before it and holds the change from
/// there, so the card's source (the first `capacity` points) plus every
/// segment is the whole waveform: in series for a V source, in parallel for
/// an I source. Empty when the PWL fits. ngspice reads any length; a
/// truncated table would end the waveform early without a word.
fn pwlTail(comptime D: type, arena: std.mem.Allocator, dev: Device) ![]const D.Model {
    if (comptime !@hasField(D.Model, pwlSlot("pwl_times", 0))) return &.{};
    const cap = comptime pwlCapacity(D.Model);
    const args = pwlArgs(dev) orelse return &.{};
    const n = args.len / 2;
    if (n <= cap) return &.{};
    if (kvNumber(dev.kv, "r") != null) {
        if (!@import("builtin").is_test) std.log.err("{s}: a PWL with r= holds at most {d} points", .{ dev.name, cap });
        return error.UnsupportedCard;
    }
    const td = kvNumber(dev.kv, "td") orelse 0;
    var out: std.ArrayList(D.Model) = .empty;
    var start: usize = cap - 1;
    while (start + 1 < n) : (start += cap - 1) {
        const t0 = valueNumber(args[2 * start]) orelse return error.UnresolvedParameter;
        const v0 = valueNumber(args[2 * start + 1]) orelse return error.UnresolvedParameter;
        var m: D.Model = .{};
        m.waveform = @backingInt(Wave.pwl);
        m.pwl_td = td;
        const len = @min(cap, n - start);
        inline for (0..cap) |k| if (k < len) {
            const j = start + k;
            @field(m, pwlSlot("pwl_times", k)) = valueNumber(args[2 * j]) orelse t0;
            @field(m, pwlSlot("pwl_values", k)) = (valueNumber(args[2 * j + 1]) orelse v0) - v0;
        };
        m.pwl_len = @intCast(len);
        try out.append(arena, m);
    }
    return out.items;
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
        @backingInt(Wave.pulse) => rd(target.*, "pulse_v1", "pulse_i1"),
        @backingInt(Wave.sin) => rd(target.*, "sin_vo", "sin_ioff") +
            rd(target.*, "sin_va", "sin_iamp") *
                @sin(2.0 * std.math.pi * rd(target.*, "sin_phase", "sin_phase") / 360.0),
        @backingInt(Wave.exp) => rd(target.*, "exp_v1", "exp_i1"),
        @backingInt(Wave.pwl) => rd(target.*, pwlSlot("pwl_values", 0), pwlSlot("pwl_values", 0)),
        // ngspice's DCOP evaluates SFFM at time 0: the V source is 0 there
        // (vsrcload.c:271-274), the I source has no delay and reads its phases
        // one slot early (isrcload.c:222-252, see isource.va).
        @backingInt(Wave.sffm) => if (comptime !@hasField(T, "sffm_fm") or T == devices.vsource.Model or T == devices.vsource.Instance) 0 else blk: {
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
        const names = @typeInfo(D.U).@"enum".field_names;
        for (names, 0..) |name, i| {
            if (std.mem.eql(u8, name, tag)) {
                if (i < D.num_ports) @compileError(@typeName(D) ++ ": `" ++ tag ++ "` is a port, not an internal unknown");
                break :blk names.len - i;
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

/// An HSPICE P card, which the reader turns into a V card (netlist.zig
/// readDevice): kind `v` under a leaf name that starts with `p`.
fn isPortCard(dev: Device) bool {
    const leaf = dev.name[if (std.mem.lastIndexOfScalar(u8, dev.name, '.')) |i| i + 1 else 0..];
    return dev.kind == 'v' and leaf.len > 0 and std.ascii.toLower(leaf[0]) == 'p';
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
        .@"struct" => |info| inline for (info.field_names) |name| {
            if (!finiteLineCoefficients(@field(value, name))) return false;
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

/// A W element's lower-triangle matrices in RLGC-file order: L, C, R, G, Rs, Gd.
const WMatrices = struct { tri: [6][10]f64 = @splat(@splat(0)) };

fn refuseW(dev: Device, why: []const u8) error{UnsupportedCard} {
    if (!@import("builtin").is_test) std.log.err("W element '{s}': {s}", .{ dev.name, why });
    return error.UnsupportedCard;
}

fn refuseS(dev: Device, why: []const u8) error{UnsupportedCard} {
    if (!@import("builtin").is_test) std.log.err("S element '{s}': {s}", .{ dev.name, why });
    return error.UnsupportedCard;
}

fn kvName(kv: []const Kv, key: []const u8) ?[]const u8 {
    for (kv) |item| if (std.mem.eql(u8, item.key, key)) return switch (item.value) {
        .name => |n| n,
        else => null,
    };
    return null;
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
    var buf: [4096]u8 align(@alignOf(batch.Param)) = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&buf, core.gpa);
    const a = fallback.allocator();
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
    .waveKind = waveKind,
    .sourceDc = sourceDc,
    .sourceAc = sourceAc,
    .sourceDisto = sourceDisto,
    .sourcePort = sourcePort,
    .isPortCard = isPortCard,
    .rootProduct = rootProduct,
    .cplVector = cplVector,
} else {};
