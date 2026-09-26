//! The neutral device ABI shared by the host, the per-model device objects
//! and runtime-loaded `.so` devices: construction (`Proto`, `PatternBuilder`),
//! the frozen per-type `Batch` with its `Hooks`, and the `DeviceVtable`.
//! Everything that crosses a separately compiled boundary is in `layoutHash`.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");
const core = @import("core");

pub const GROUND = core.GROUND;
pub const DeviceType = core.DeviceType;

pub const bind = @import("bind.zig");
pub const Param = bind.Param;
pub const BindStatus = bind.BindStatus;

/// Threads per GPU block, shared by the kernel exports and the launcher.
pub const gpu_block_size: u32 = 256;

pub const StateCtlOp = contract.StateCtlOp;
pub const SimState = contract.SimState;

/// A handle to one scalar parameter of one instance or model, for sweeps,
/// Monte Carlo and sensitivity. Points into the batch's Model/Instance
/// storage, which must outlive it. Values move as f64 whatever the field's
/// width; use `get`/`set` rather than switching on `ptr`.
pub const ParamRef = struct {
    /// Tagged: VerA emits f64 parameters, hand-written devices may use f32.
    ptr: Ptr,
    /// Filled by the host when it collects the batch's parameters.
    type: DeviceType = .unset,
    param_name: []const u8,
    /// Instance index within the batch.
    index: u32,
    is_instance: bool,
    /// The device's principal parameter: its `mc_param`, else its first.
    primary: bool,
    pelgrom_ap: f64 = 0,
    area_wl: f64 = 0,

    pub const Ptr = union(enum) {
        f32: *f32,
        f64: *f64,
    };

    pub fn get(self: ParamRef) f64 {
        return switch (self.ptr) {
            .f32 => |p| p.*,
            .f64 => |p| p.*,
        };
    }

    /// Writes the parameter, rounding to f32 fields. The caller must run the
    /// batch's `recompute` hook before the next solve.
    pub fn set(self: ParamRef, v: f64) void {
        switch (self.ptr) {
            .f32 => |p| p.* = @floatCast(v),
            .f64 => |p| p.* = v,
        }
    }
};

/// One noise generator between two nodes, with PSD
/// `S(f) = white + flicker / f^ef` in the contributed nature's units² per Hz.
/// A density, not a kind: shot and thermal sources both arrive as a white
/// density, as in ngspice's NevalSrc (nevalsrc.c:105-113).
pub const NoiseSource = struct {
    node_p: u32,
    node_n: u32,
    white: f64 = 0,
    flicker: f64 = 0,
    ef: f64 = 1,
};

pub const NoiseGenKind = enum { thermal, shot, flicker };
/// A device's generator declaration: local rows `row`/`col` and its kind.
pub const NoiseGen = struct { row: usize, col: usize, kind: NoiseGenKind };
/// A device's `noisePsd` result, one per `noise_gens` entry.
pub const PsdTerm = contract.PsdTerm;

/// The value planes one eval pass stamps into. The serial path points them at
/// the circuit's own slices; each ParEval lane gets private slabs, reduced
/// afterwards.
pub const Planes = struct {
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,
};

/// One device type's frozen batch, made by `Proto.finalize`. `eval` and
/// `eval_newton` stamp instances `[first, last)` into the given planes, so the
/// same entry serves the serial path and a ParEval lane; `eval_newton` skips
/// a constant Jacobian half.
pub const Batch = struct {
    // hot
    ctx: *anyopaque,
    eval: *const fn (*anyopaque, *const Planes, first: u32, last: u32, []const f64, f64) void,
    eval_newton: *const fn (*anyopaque, *const Planes, first: u32, last: u32, []const f64, f64) void,
    count: u32,
    n_u: u32,
    has_charge: bool,
    has_const_jacobian: bool,

    // cold
    /// The device type's name without its namespace.
    type_name: []const u8,
    hooks: *const Hooks,
};

/// Callback status that is safe across separately compiled objects, unlike
/// Zig error values, whose numbering is per compilation.
pub const DeviceStatus = enum(u8) { ok = 0, out_of_memory = 1, too_many_instances = 2 };

/// A callback result carried by value across the object boundary. A
/// successful payload keeps its existing owner.
pub fn DeviceResult(comptime T: type) type {
    return union(DeviceStatus) {
        ok: T,
        out_of_memory: void,
        too_many_instances: void,

        pub fn fromLocal(value: error{ OutOfMemory, TooManyInstances }!T) @This() {
            return .{ .ok = value catch |err| return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.TooManyInstances => .too_many_instances,
            } };
        }

        pub fn unwrap(self: @This()) error{ OutOfMemory, TooManyInstances }!T {
            return switch (self) {
                .ok => |value| value,
                .out_of_memory => error.OutOfMemory,
                .too_many_instances => error.TooManyInstances,
            };
        }
    };
}

/// Per-type hooks, one static table per device type. A null entry means the
/// device lacks the feature.
pub const Hooks = struct {
    /// A fresh mutable batch from an unevaluated template. The template and
    /// its tapes must outlive every instance made from it.
    instantiate: *const fn (*const anyopaque, std.mem.Allocator) DeviceResult(Batch),
    /// A copy of an accepted batch, mutable history included.
    snapshot: *const fn (*const anyopaque, std.mem.Allocator) DeviceResult(Batch),
    /// Syncs the host limiting flag after GPU state is downloaded.
    set_limit_active: ?*const fn (*anyopaque, bool) void = null,
    /// `{slot_lo, slot_hi, row_lo, row_hi}` touched by instances
    /// `[first, last)`, the trash slot and row excluded.
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    clear_limits: ?*const fn (*anyopaque) void = null,
    begin_solve: ?*const fn (*anyopaque) void = null,
    /// Advances Newton-history state between evaluated iterates, given the
    /// previous x.
    advance_iteration: ?*const fn (*anyopaque, []const f64) void = null,
    check_convergence: ?*const fn (*anyopaque, []const f64) bool = null,
    seed: ?*const fn (*anyopaque, []f64) void = null,
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    /// Runs `updateState` at x once per converged solve; returns the earliest
    /// requested rejection time, if any. Only for state that
    /// `state_ctl(.revert)` restores when the step is rejected.
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// `update_state` for `absdelay` history, which cannot be rolled back:
    /// called once per accepted transient point instead, before
    /// `state_ctl(.commit)`. Pushing on every Newton attempt would fill the
    /// delay ring with rejected iterates.
    commit_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// `update_state` for held variables with no accepted copy to revert to:
    /// called once per accepted point, the operating point included, before
    /// `state_ctl(.commit)`. Per solve it would latch an iterate, or a solve
    /// the step then rejected.
    commit_held: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    state_ctl: ?*const fn (*anyopaque, StateCtlOp) bool = null,
    /// Sets every instance's temperature, in Celsius.
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    /// Publishes the host-owned Instance fields (`$abstime`, timestep,
    /// `analysis()`, initial/final step), which devices read and never write.
    /// Call once per solve attempt, before eval; it walks every instance.
    set_sim_state: ?*const fn (*anyopaque, SimState) void = null,
    /// The model's smallest static delay (`D.delays`).
    min_delay: ?*const fn (*anyopaque) f64 = null,
    /// The tightest LRM §9.17.2 `$bound_step` any instance requested for the
    /// next step, or `inf`. Valid after `updateState` has run for the
    /// accepted step.
    bound_step: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    /// Charge per instance and LTE site (`ddt()` sites not marked
    /// `vera_lte = 0`) from the last eval, instance-major. Lets the transient
    /// run its LTE per charge state, as ngspice's CKTterr does, instead of
    /// per summed matrix row. Null when the device has no `q`.
    q_tape: ?*const fn (*anyopaque) []const f64 = null,
    /// Restamps `q_vec` and `q_tape` for instances `[first, last)` at x,
    /// leaving the other planes alone. Null when the device has no `q`.
    eval_q: ?*const fn (*anyopaque, *const Planes, u32, u32, []const f64, f64) void = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) DeviceResult(void),
    /// Appends every declared noise generator with its PSD at x. Temperature
    /// is the instance's own, already applied by the device.
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) DeviceResult(void) = null,
    /// Reruns parameter-derived state; false means the new parameters need
    /// a different topology than the frozen one.
    recompute: ?*const fn (*anyopaque) bool = null,
    /// The batch's GPU working set, or null when the type is not
    /// GPU-eligible, in which case the launcher keeps the whole circuit on
    /// the CPU.
    gpu_payload: ?*const fn (*anyopaque) GpuPayload = null,
    apply_attempt: ?*const fn (*anyopaque, f64) void = null,
    restore_models: ?*const fn (*anyopaque) void = null,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// A device type's construction-time store. `pattern` adds its matrix
/// entries, `finalize` freezes it into a `Batch`, `destroy` frees it.
pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) DeviceResult(void),
    finalize: *const fn (*anyopaque, std.mem.Allocator, PatternView) DeviceResult(Batch),
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

/// A read-only CSC sparsity pattern. `trash_slot` (= nnz) is the slot ground
/// entries scatter into.
pub const PatternView = struct {
    col_ptr: []const u32,
    row_idx: []const u32,
    n: u32,
    trash_slot: u32,

    /// Binary search in column `col`; asserts `col < n`.
    pub fn findSlot(self: PatternView, row: u32, col: u32) ?u32 {
        var lo = self.col_ptr[col];
        var hi = self.col_ptr[col + 1];
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.row_idx[mid] < row) lo = mid + 1 else hi = mid;
        }
        if (lo < self.col_ptr[col + 1] and self.row_idx[lo] == row) return lo;
        return null;
    }
};

/// Accumulates `(col << 32 | row)` keys, duplicates included, and turns them
/// into CSC with `toCsc`. Pass a scratch allocator, not the circuit's arena:
/// the keys and sort buffers die in `Circuit.freeze`, and an arena would keep
/// them (measured 14.6 MB on a 25,000-MOSFET deck).
pub const PatternBuilder = struct {
    keys: std.ArrayList(u64) = .empty,

    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.keys.append(gpa, (@as(u64, col) << 32) | row); // col-major sort order
    }

    pub fn reserve(self: *PatternBuilder, gpa: std.mem.Allocator, extra: usize) !void {
        try self.keys.ensureUnusedCapacity(gpa, extra);
    }

    pub fn deinit(self: *PatternBuilder, gpa: std.mem.Allocator) void {
        self.keys.deinit(gpa);
    }

    /// LSD radix sort on 16-bit digits, O(n), skipping digits no key uses.
    fn radixSort(gpa: std.mem.Allocator, sort_keys: []u64) !void {
        if (sort_keys.len < 64) {
            std.mem.sortUnstable(u64, sort_keys, {}, std.sort.asc(u64));
            return;
        }
        var used_bits: u64 = 0;
        for (sort_keys) |k| used_bits |= k;

        const tmp = try gpa.alloc(u64, sort_keys.len);
        defer gpa.free(tmp);
        const counts = try gpa.alloc(u32, 1 << 16);
        defer gpa.free(counts);

        var src: []u64 = sort_keys;
        var dst: []u64 = tmp;
        var shift: u6 = 0;
        while (true) {
            const digit_bound: u16 = @truncate(used_bits >> shift);
            // With n < 65536 the digits between row and column are all zero.
            // The OR of all keys also bounds every occupied bucket.
            if (digit_bound != 0) {
                const buckets = counts[0 .. @as(usize, digit_bound) + 1];
                @memset(buckets, 0);
                for (src) |k| buckets[@as(u16, @truncate(k >> shift))] += 1;
                var sum: u32 = 0;
                for (buckets) |*c| {
                    const c0 = c.*;
                    c.* = sum;
                    sum += c0;
                }
                for (src) |k| {
                    const d: u16 = @truncate(k >> shift);
                    dst[buckets[d]] = k;
                    buckets[d] += 1;
                }
                const t = src;
                src = dst;
                dst = t;
            }
            if (shift >= 48 or (used_bits >> shift) >> 16 == 0) break;
            shift += 16;
        }
        if (src.ptr != sort_keys.ptr) @memcpy(sort_keys, src);
    }

    /// Sorts and dedups the keys into an `n`-column CSC pattern and returns
    /// nnz. `gpa` owns `col_ptr_out`/`row_idx_out`; `scratch` is only used
    /// during the call. Reorders `keys` in place.
    pub fn toCsc(self: *PatternBuilder, gpa: std.mem.Allocator, scratch: std.mem.Allocator, n: u32, col_ptr_out: *[]u32, row_idx_out: *[]u32) !u32 {
        const all = self.keys.items;
        try radixSort(scratch, all);
        var m: usize = 0;
        for (all) |k| {
            if (m == 0 or all[m - 1] != k) {
                all[m] = k;
                m += 1;
            }
        }
        const nnz: u32 = @intCast(m);

        const col_ptr = try gpa.alloc(u32, n + 1);
        errdefer gpa.free(col_ptr);
        const row_idx = try gpa.alloc(u32, nnz);
        @memset(col_ptr, 0);
        for (all[0..m], 0..) |k, p| {
            row_idx[p] = @truncate(k);
            col_ptr[(k >> 32) + 1] += 1;
        }
        for (0..n) |j| col_ptr[j + 1] += col_ptr[j];
        col_ptr_out.* = col_ptr;
        row_idx_out.* = row_idx;
        return nnz;
    }
};

/// One batch's GPU-resident working set, type-erased. Frozen for the solve:
/// the launcher uploads it once and afterwards moves only x in and the value
/// planes out per Newton iteration. `models`/`instances` change only when a
/// sweep writes a parameter.
pub const GpuPayload = struct {
    /// `arp_eval_<model>`.
    kernel: []const u8,
    /// Instances in the batch, one GPU thread each.
    count: u32,
    /// Unknowns per instance; the tape stride.
    n_u: u32,
    /// `[]D.Model` and `[]D.Instance` as bytes. POD by contract, so a byte
    /// copy is the whole upload.
    models: []const u8,
    instances: []const u8,
    /// count * n_u: the global row each local unknown gathers x from.
    gath: []const u32,
    /// count * n_u: the residual row each local unknown scatters to.
    rhs_idx: []const u32,
    /// count * n_u * n_u: the CSC slot each local Jacobian entry scatters to.
    slots: []const u32,
    /// `arp_lim_<model>`, or "" when the device has no state kernel.
    lim_kernel: []const u8,
    /// `arp_ctl_<model>`, or "" when the device has no accepted-step latch.
    ctl_kernel: []const u8,
    /// `arp_reduce_<model>`, the segmented sum from staging cells to planes.
    reduce_kernel: []const u8,
    /// Host lim plane (count * n_u) for the initial upload, empty without
    /// `limit`. Stale once the device-side state kernel has run.
    lim_x: []const f64,
    /// `[]D.State` as bytes, uploaded once; empty without `State`.
    states: []const u8,
    /// Host `lim_active`, used only until the device owns the lim plane.
    lim_active: bool,
};

/// Runtime ABI version, mixed into `layoutHash`. `hashType` sees only sizes,
/// alignments and offsets, so a change that moves none of them (a tape's
/// meaning, a function signature) must bump this.
// 7: the slot tape's cleared entries are the device's structural Jacobian
//    zeros, not just ground; `addPattern` no longer reserves them.
// 8: `Hooks.eval_q` takes an instance range.
// 10: CPU callbacks return `DeviceResult`/`DeviceStatus` instead of Zig error
//    unions.
// 11: dropped `Batch.thread_safe`, `Hooks.record_history`/`inject_history`,
//    `DeviceVtable.gpu_kernel_name`/`gpu_ptx`/`gpu_amdgcn`; `Batch.type_name`
//    is the short type name.
// 12: `set_model_param`/`set_instance_param` became `bind_model`/
//    `bind_instance`; `ParamRef.type`.
// 13: dropped `ParamRef.device_type`.
// GPU planes, Model/Instance PODs and scatter tapes are unchanged by 10 to 13.
pub const abi_version: u32 = 13;

/// A device type's construction entry points, exported by each device object
/// and by runtime-loaded `.so` devices.
pub const DeviceVtable = struct {
    name: []const u8,
    n_u: u32,
    num_ports: u32,
    model_size: usize,
    instance_size: usize,
    init_model: *const fn ([*]u8) void,
    init_instance: *const fn ([*]u8) void,
    /// Binds card pairs onto a Model / Instance blob (bind.zig).
    bind_model: *const fn ([*]u8, []const Param) BindStatus,
    bind_instance: *const fn ([*]u8, []const Param) BindStatus,
    /// Recomputes parameters declared as expressions of other parameters, and
    /// localparams (LRM 6.3.4, 3.4.5). The host must call it after the last
    /// `bind_model` and before anything reads the model. Null when the module
    /// has none.
    derive: ?*const fn (model: [*]u8) void,
    /// Writes, for each internal unknown in `[num_ports, n_u)`, the unknown
    /// it aliases, or -1.
    collapse: ?*const fn (model: [*]const u8, instance: [*]const u8, out: [*]i32) void,
    proto_create: *const fn (std.mem.Allocator) DeviceResult(Proto),
    proto_add: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) DeviceResult(void),
};

/// Hash of every type that crosses the object boundary, the compiler
/// version, backend and mode, and `abi_version`. Both sides compile this same
/// source, so equal hashes mean compatible layouts.
pub fn layoutHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h: u64 = 0xcbf29ce484222325;
        for (builtin.zig_version_string) |c| h = mix(h, c);
        h = mix(h, @intFromEnum(builtin.zig_backend));
        h = mix(h, @intFromEnum(builtin.mode));
        // Error tracing adds a hidden argument to every callconv(.auto) call.
        h = mix(h, @intFromBool(builtin.have_error_return_tracing));
        for ([_]type{
            DeviceVtable,        Proto,               Batch,
            Hooks,               Planes,              PatternView,
            PatternBuilder,      ParamRef,            NoiseSource,
            std.mem.Allocator,   DeviceStatus,        DeviceResult(void),
            DeviceResult(Batch), DeviceResult(Proto), Param,
        }) |T| h = hashType(h, T);
        h = mix(h, abi_version);
        break :blk h;
    };
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v) *% 0x100000001b3;
}

fn hashType(h0: u64, comptime T: type) u64 {
    var h = mix(mix(h0, @sizeOf(T)), @alignOf(T));
    switch (@typeInfo(T)) {
        .@"struct" => |si| inline for (si.fields) |f| {
            if (!f.is_comptime and @sizeOf(f.type) > 0) h = mix(h, @offsetOf(T, f.name));
        },
        else => {},
    }
    return h;
}

test {
    _ = bind;
}
