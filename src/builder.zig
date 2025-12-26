//! Builder: mutable netlist → frozen analysis.Circuit.
//!
//! Construction policy lives here with the app: node interning, subcircuit
//! tagging + BBD permutation, device accumulation. The batch mechanism
//! (ProtoStore/DeviceBatch, pattern freeze) is analysis-owned — see
//! modules/analysis/src/batch.zig; dlopen'd devices live in dyn.zig there.

const std = @import("std");
const analysis = @import("analysis");
const batch = analysis.batch;
const dyn = analysis.dyn;

const GROUND = analysis.GROUND;
const Circuit = analysis.Circuit;
const Proto = batch.Proto;
const DynDevice = dyn.DynDevice;
const DynKv = dyn.DynKv;

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
        inline for (D.num_ports..n_u) |u| all[u] = self.addNode();

        const store = try self.protoStore(D);
        try store.models.append(self.gpa, model);
        try store.instances.append(self.gpa, instance);
        try store.nodes.append(self.gpa, all);
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

    /// Add all instances of one dlopen'd generated device. Takes ownership
    /// of `dyn_dev` (closed at circuit deinit; closed here on error). Internal
    /// unknowns (n_u - num_ports per instance) are assigned like addDevice.
    pub fn addDynDevice(
        self: *Builder,
        dyn_dev: DynDevice,
        name: []const u8,
        node_sets: []const []const u32,
        model_kvs: []const []const DynKv,
        instance_kvs: []const []const DynKv,
    ) !void {
        var dyn_owned = dyn_dev;
        errdefer dyn_owned.close();
        const gpa = self.gpa;
        const n_u: usize = dyn_dev.n_u;
        const count = node_sets.len;
        std.debug.assert(model_kvs.len == count and instance_kvs.len == count);

        const store = try gpa.create(dyn.DynProtoStore);
        errdefer gpa.destroy(store);
        store.* = .{
            .dyn = dyn_owned,
            .name = try gpa.dupe(u8, name),
            .count = @intCast(count),
            .nodes = try gpa.alloc(u32, count * n_u),
            .models = try gpa.alignedAlloc(u8, .@"16", count * dyn_dev.model_size),
            .instances = try gpa.alignedAlloc(u8, .@"16", count * dyn_dev.instance_size),
        };

        for (node_sets, 0..) |ports, id| {
            for (0..n_u) |u| {
                store.nodes[id * n_u + u] = if (u < dyn_dev.num_ports)
                    (if (u < ports.len) ports[u] else GROUND)
                else
                    self.addNode();
            }
            const m_ptr = store.models.ptr + id * dyn_dev.model_size;
            const i_ptr = store.instances.ptr + id * dyn_dev.instance_size;
            dyn_dev.init_model(m_ptr);
            dyn_dev.init_instance(i_ptr);
            // Unknown keys are ignored (bool result), matching kv handling
            // for static devices.
            for (model_kvs[id]) |kv| _ = dyn_dev.set_model_param(m_ptr, kv.key.ptr, kv.key.len, kv.value);
            for (instance_kvs[id]) |kv| _ = dyn_dev.set_instance_param(i_ptr, kv.key.ptr, kv.key.len, kv.value);
        }

        try self.protos.append(gpa, .{
            .ctx = store,
            .type_name = store.name,
            .pattern = dyn.DynProtoStore.addPattern,
            .finalize = dyn.DynProtoStore.finalize,
            .destroy = dyn.DynProtoStore.destroy,
            .apply_perm = dyn.DynProtoStore.applyPerm,
        });
    }

    /// Freeze: apply the BBD permutation, then hand the accumulated protos
    /// to analysis.batch.freeze() which builds the union sparsity pattern,
    /// allocates planes and precomputes every slot tape. The Builder is
    /// consumed.
    pub fn compile(self: *Builder) !Circuit {
        const gpa = self.gpa;
        const n: usize = self.n;

        // BBD permutation: reorder nodes so subcircuit-internal nodes are
        // contiguous per instance, coupling nodes at the end.
        const bbd = try self.computeBbd();
        if (bbd.perm) |perm| {
            for (self.protos.items) |p| p.apply_perm(p.ctx, perm);
            // Remap node_names
            var iter = self.node_names.iterator();
            while (iter.next()) |entry| {
                const old_id = entry.value_ptr.*;
                if (old_id < perm.len) entry.value_ptr.* = perm[old_id];
            }
            // Remap node_labels
            const old_labels = try gpa.alloc([]const u8, n);
            defer gpa.free(old_labels);
            @memcpy(old_labels, self.node_labels.items);
            for (old_labels, 0..) |label, i| {
                const new_i = if (i < perm.len) perm[i] else @as(u32, @intCast(i));
                self.node_labels.items[new_i] = label;
            }
            gpa.free(perm);
        }

        const labels = try self.node_labels.toOwnedSlice(gpa);
        const ckt = try batch.freeze(gpa, self.n, self.node_names, labels, self.protos.items, bbd.info);

        // Protos consumed by freeze(); free the Builder shell.
        self.protos.deinit(gpa);
        self.node_instance.deinit(gpa);
        self.node_type.deinit(gpa);
        self.* = undefined; // names/labels now owned by ckt
        return ckt;
    }
};
