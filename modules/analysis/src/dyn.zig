//! Dyn (dlopen'd) generated devices: the ABI, plus the runtime-n_u
//! proto/batch pair that mirrors batch.zig's comptime machinery.

const std = @import("std");
const root = @import("root.zig");
const batch = @import("batch.zig");

const GROUND = root.GROUND;
const Batch = root.Batch;
const Circuit = root.Circuit;
const Planes = root.Planes;
const PatternBuilder = batch.PatternBuilder;

/// One key=value parameter for a dyn (dlopen'd) device.
pub const DynKv = struct { key: []const u8, value: f64 };

/// A generated (VAF/VF) device loaded from a shared object. ABI v3: the .so
/// computes residual + ANALYTIC Jacobian itself (its physics instantiated
/// with a dual scalar at its own compile time) — no finite differences cross
/// this boundary. Model/Instance are opaque byte blobs owned by the loader;
/// params are set by name through the ABI.
pub const DynDevice = struct {
    /// Null for in-process devices (tests); set by open().
    lib: ?std.DynLib = null,
    n_u: u32,
    num_ports: u32,
    model_size: usize,
    instance_size: usize,
    init_model: InitFn,
    init_instance: InitFn,
    set_model_param: SetParamFn,
    set_instance_param: SetParamFn,
    eval_ad: EvalAdFn,
    q_ad: ?EvalAdFn,
    // Optional state machine (VF digital devices): update mutates instance
    // (drive targets) + state, returns reject-at time or +inf for ok.
    state_size: usize = 0,
    init_state: ?InitStateFn = null,
    update_state: ?UpdateStateFn = null,

    pub const abi_version: u32 = 3;
    pub const InitFn = *const fn ([*]u8) callconv(.c) void;
    pub const SetParamFn = *const fn ([*]u8, [*]const u8, usize, f64) callconv(.c) bool;
    /// (x[n_u], model, instance, t, out_res[n_u], out_jac[n_u*n_u] row-major)
    pub const EvalAdFn = *const fn ([*]const f64, [*]const u8, [*]const u8, f64, [*]f64, [*]f64) callconv(.c) void;
    /// (model, instance, state)
    pub const InitStateFn = *const fn ([*]const u8, [*]u8, [*]u8) callconv(.c) void;
    /// (x[n_u], model, instance, state) -> reject time, +inf = ok
    pub const UpdateStateFn = *const fn ([*]const f64, [*]const u8, [*]u8, [*]u8) callconv(.c) f64;

    pub fn open(path: []const u8) !DynDevice {
        var lib = try std.DynLib.open(path);
        errdefer lib.close();

        const ver_fn = lib.lookup(*const fn () callconv(.c) u32, "zpicey_abi_version") orelse return error.NotZpiceyDevice;
        if (ver_fn() != abi_version) return error.WrongAbiVersion;

        const usize_fn = *const fn () callconv(.c) usize;
        const n_u: u32 = @intCast((lib.lookup(usize_fn, "zpicey_n_u") orelse return error.MissingSymbol)());
        const num_ports: u32 = @intCast((lib.lookup(usize_fn, "zpicey_num_ports") orelse return error.MissingSymbol)());
        if (n_u == 0 or num_ports == 0 or num_ports > n_u) return error.BadDeviceShape;

        return .{
            .lib = lib,
            .n_u = n_u,
            .num_ports = num_ports,
            .model_size = (lib.lookup(usize_fn, "zpicey_model_size") orelse return error.MissingSymbol)(),
            .instance_size = (lib.lookup(usize_fn, "zpicey_instance_size") orelse return error.MissingSymbol)(),
            .init_model = lib.lookup(InitFn, "zpicey_init_model") orelse return error.MissingSymbol,
            .init_instance = lib.lookup(InitFn, "zpicey_init_instance") orelse return error.MissingSymbol,
            .set_model_param = lib.lookup(SetParamFn, "zpicey_set_model_param") orelse return error.MissingSymbol,
            .set_instance_param = lib.lookup(SetParamFn, "zpicey_set_instance_param") orelse return error.MissingSymbol,
            .eval_ad = lib.lookup(EvalAdFn, "zpicey_eval_ad") orelse return error.MissingSymbol,
            .q_ad = lib.lookup(EvalAdFn, "zpicey_q_ad"),
            .state_size = if (lib.lookup(usize_fn, "zpicey_state_size")) |f| f() else 0,
            .init_state = lib.lookup(InitStateFn, "zpicey_init_state"),
            .update_state = lib.lookup(UpdateStateFn, "zpicey_update_state"),
        };
    }

    pub fn close(self: *DynDevice) void {
        if (self.lib) |*lib| lib.close();
        self.lib = null;
    }
};

// ---------------------------------------------------------------------------
// Dyn (dlopen'd) device proto/batch: runtime n_u, physics + analytic
// Jacobian behind the ABI. One store per addDynDevice call.
// ---------------------------------------------------------------------------
pub const DynProtoStore = struct {
    dyn: DynDevice,
    name: []const u8,
    count: u32,
    /// [id * n_u + u] -> unknown index (ports then internal)
    nodes: []u32,
    /// count * model_size / instance_size opaque param blobs
    models: []align(16) u8,
    instances: []align(16) u8,

    pub fn addPattern(ctx: *anyopaque, gpa: std.mem.Allocator, pb: *PatternBuilder) anyerror!void {
        const self: *DynProtoStore = @ptrCast(@alignCast(ctx));
        const n_u: usize = self.dyn.n_u;
        for (0..self.count) |id| {
            const nd = self.nodes[id * n_u ..][0..n_u];
            for (nd) |r| for (nd) |c| {
                if (r != GROUND and c != GROUND) try pb.add(gpa, r, c);
            };
        }
    }

    pub fn finalize(ctx: *anyopaque, gpa: std.mem.Allocator, ckt: *const Circuit) anyerror!Batch {
        const self: *DynProtoStore = @ptrCast(@alignCast(ctx));
        const n_u: usize = self.dyn.n_u;
        const count: usize = self.count;

        const dyn_batch = try gpa.create(DynBatch);
        errdefer gpa.destroy(dyn_batch);
        dyn_batch.* = .{
            .dyn = self.dyn,
            .name = self.name,
            .count = count,
            .models = self.models,
            .instances = self.instances,
            .gath = try gpa.alloc(u32, count * n_u),
            .rhs_idx = try gpa.alloc(u32, count * n_u),
            .slots = try gpa.alloc(u32, count * n_u * n_u),
            .x_scratch = try gpa.alloc(f64, n_u),
            .res = try gpa.alloc(f64, n_u),
            .jac = try gpa.alloc(f64, n_u * n_u),
            .states = try gpa.alignedAlloc(u8, .@"16", count * self.dyn.state_size),
        };
        if (self.dyn.init_state) |init_state| {
            for (0..count) |id| init_state(
                dyn_batch.models.ptr + id * self.dyn.model_size,
                dyn_batch.instances.ptr + id * self.dyn.instance_size,
                dyn_batch.states.ptr + id * self.dyn.state_size,
            );
        }
        for (0..count) |id| {
            const nd = self.nodes[id * n_u ..][0..n_u];
            for (nd, 0..) |node, u| {
                dyn_batch.gath[id * n_u + u] = node;
                dyn_batch.rhs_idx[id * n_u + u] = if (node == GROUND) ckt.n else node;
            }
            for (nd, 0..) |r, ru| for (nd, 0..) |c, cu| {
                dyn_batch.slots[(id * n_u + ru) * n_u + cu] =
                    if (r == GROUND or c == GROUND) ckt.trash_slot else ckt.findSlot(r, c).?;
            };
        }
        // Ownership moved into the batch; leave the shell empty for destroy().
        gpa.free(self.nodes);
        self.nodes = &.{};
        self.models = &.{};
        self.instances = &.{};
        self.name = &.{};

        return .{
            .ctx = dyn_batch,
            .type_name = dyn_batch.name,
            .count = @intCast(count),
            .n_u = @intCast(n_u),
            .has_charge = self.dyn.q_ad != null,
            .has_const_jacobian = false,
            // Shared x_scratch/res/jac ⇒ whole batch must stay on one lane.
            .thread_safe = false,
            .eval = DynBatch.eval,
            .eval_newton = DynBatch.eval,
            .set_lanes = null,
            .scatter_bounds = DynBatch.scatterBounds,
            .apply_limits = null,
            .update_state = if (self.dyn.update_state != null) DynBatch.updateState else null,
            .set_temp = null,
            .record_history = null,
            .inject_history = null,
            .min_delay = null,
            .collect_params = DynBatch.collectParams,
            .collect_noise = null,
            .recompute = null,
            .apply_attempt = null,
            .restore_models = null,
            .deinit = DynBatch.destroy,
        };
    }

    pub fn applyPerm(ctx: *anyopaque, perm: []const u32) void {
        const self: *DynProtoStore = @ptrCast(@alignCast(ctx));
        for (self.nodes) |*nd| {
            if (nd.* < perm.len) nd.* = perm[nd.*];
        }
    }

    pub fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
        const self: *DynProtoStore = @ptrCast(@alignCast(ctx));
        // Only owns anything if finalize never ran (Builder deinit path).
        if (self.nodes.len > 0) {
            gpa.free(self.nodes);
            gpa.free(self.models);
            gpa.free(self.instances);
            gpa.free(self.name);
            self.dyn.close();
        }
        gpa.destroy(self);
    }
};

const DynBatch = struct {
    dyn: DynDevice,
    name: []const u8,
    count: usize,
    models: []align(16) u8,
    instances: []align(16) u8,
    gath: []u32,
    rhs_idx: []u32,
    slots: []u32,
    states: []align(16) u8,
    // scratch: gathered x, ABI residual + row-major Jacobian
    x_scratch: []f64,
    res: []f64,
    jac: []f64,

    fn eval(ctx: *anyopaque, pl: *const Planes, lane: u32, first: u32, last: u32, x: []const f64, t: f64) void {
        _ = lane; // no dedup cache; thread_safe=false pins the whole batch to one lane
        const self: *DynBatch = @ptrCast(@alignCast(ctx));
        const n_u: usize = self.dyn.n_u;
        for (first..last) |id| {
            for (0..n_u) |u| self.x_scratch[u] = x[self.gath[id * n_u + u]];
            const m_ptr = self.models.ptr + id * self.dyn.model_size;
            const i_ptr = self.instances.ptr + id * self.dyn.instance_size;

            self.dyn.eval_ad(self.x_scratch.ptr, m_ptr, i_ptr, t, self.res.ptr, self.jac.ptr);
            self.scatter(pl.rhs, pl.g_vals, id, n_u);

            if (self.dyn.q_ad) |qf| {
                qf(self.x_scratch.ptr, m_ptr, i_ptr, t, self.res.ptr, self.jac.ptr);
                self.scatter(pl.q_vec, pl.c_vals, id, n_u);
            }
        }
    }

    fn scatterBounds(ctx: *anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32 {
        const self: *DynBatch = @ptrCast(@alignCast(ctx));
        const n_u: usize = self.dyn.n_u;
        var slot_lo: u32 = std.math.maxInt(u32);
        var slot_hi: u32 = 0;
        var row_lo: u32 = std.math.maxInt(u32);
        var row_hi: u32 = 0;
        for (self.slots[first * n_u * n_u .. last * n_u * n_u]) |s| {
            if (s == trash_slot) continue;
            slot_lo = @min(slot_lo, s);
            slot_hi = @max(slot_hi, s + 1);
        }
        for (self.rhs_idx[first * n_u .. last * n_u]) |r| {
            if (r == trash_row) continue;
            row_lo = @min(row_lo, r);
            row_hi = @max(row_hi, r + 1);
        }
        if (slot_lo > slot_hi) slot_lo = slot_hi;
        if (row_lo > row_hi) row_lo = row_hi;
        return .{ slot_lo, slot_hi, row_lo, row_hi };
    }

    fn scatter(self: *DynBatch, vec: []f64, vals: []f64, id: usize, n_u: usize) void {
        for (0..n_u) |r| {
            vec[self.rhs_idx[id * n_u + r]] += self.res[r];
            for (0..n_u) |c|
                vals[self.slots[(id * n_u + r) * n_u + c]] += self.jac[r * n_u + c];
        }
    }

    fn updateState(ctx: *anyopaque, x: []const f64) ?f64 {
        const self: *DynBatch = @ptrCast(@alignCast(ctx));
        const usf = self.dyn.update_state orelse return null;
        const n_u: usize = self.dyn.n_u;
        var min_reject: ?f64 = null;
        for (0..self.count) |id| {
            for (0..n_u) |u| self.x_scratch[u] = x[self.gath[id * n_u + u]];
            const tr = usf(
                self.x_scratch.ptr,
                self.models.ptr + id * self.dyn.model_size,
                self.instances.ptr + id * self.dyn.instance_size,
                self.states.ptr + id * self.dyn.state_size,
            );
            if (std.math.isFinite(tr))
                min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
        }
        return min_reject;
    }

    /// Params live behind the ABI as opaque blobs — nothing to expose to
    /// sens/mc. Named params were applied at addDynDevice time.
    fn collectParams(_: *anyopaque, _: std.mem.Allocator, _: *std.ArrayList(root.ParamRef)) anyerror!void {}

    fn destroy(ctx: *anyopaque, gpa: std.mem.Allocator) void {
        const self: *DynBatch = @ptrCast(@alignCast(ctx));
        gpa.free(self.gath);
        gpa.free(self.rhs_idx);
        gpa.free(self.slots);
        gpa.free(self.x_scratch);
        gpa.free(self.res);
        gpa.free(self.jac);
        gpa.free(self.states);
        gpa.free(self.models);
        gpa.free(self.instances);
        gpa.free(self.name);
        self.dyn.close();
        gpa.destroy(self);
    }
};
