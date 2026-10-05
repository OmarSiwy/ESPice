//! The neutral device ABI shared by the host, the per-model device objects
//! and runtime-loaded `.so` devices: construction (`Proto`, `PatternBuilder`),
//! the frozen per-type `Batch` with its `Hooks`, and the `DeviceVtable`.
//! Everything that crosses a separately compiled boundary is in `layoutHash`.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");
const core = @import("core");

/// The ground node id, re-exported because device code imports this module
/// and not core.
pub const GROUND = core.GROUND;
/// A dense device-type id (`Library`), re-exported like `GROUND`.
pub const DeviceType = core.DeviceType;

/// The parameter binder, here so eval.zig compiles it into every device object.
pub const bind = @import("bind.zig");
/// One card `name=value` pair, as `DeviceVtable.bind_model` takes it.
pub const Param = bind.Param;
/// The binder's result, an enum because it crosses the object boundary.
pub const BindStatus = bind.BindStatus;

/// Threads per GPU block, shared by the kernel exports and the launcher.
pub const gpu_block_size: u32 = 256;

/// VerA's accepted-step control operation (`Hooks.state_ctl`).
pub const StateCtlOp = contract.StateCtlOp;
/// VerA's analysis state, passed by value to every device call; in
/// `layoutHash` because GPU kernels take it too.
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

    /// The field's address, tagged by its width.
    pub const Ptr = union(enum) {
        f32: *f32,
        f64: *f64,
    };

    /// Reads the parameter, widened to f64.
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

/// One noise generator row between two nodes. Its unit-coefficient shape is
/// `S(f) = white + flicker / f^ef + T(f)` in the contributed nature's units²
/// per Hz, `T` the tabulated PSD (`tableAt`, zero for a parametric row), and
/// the row injects `coeff` times that generator. A density, not a kind:
/// shot and thermal sources both arrive as a white density, as in ngspice's
/// NevalSrc (nevalsrc.c:105-113).
///
/// Rows of one correlated generator (LRM §4.6.4.6, contract
/// `NoiseGen.source`) are contiguous in a collected list and share `group`,
/// the list index of their first row, so a consumer sums their transfers
/// `Σ coeff·(y[node_p] − y[node_n])` as phasors before squaring and prices
/// the sum with the first row's shape (`groupEnd`). An independent row is a
/// group of one. Within a group only the first row's shape counts.
pub const NoiseSource = struct {
    node_p: u32,
    node_n: u32,
    white: f64 = 0,
    flicker: f64 = 0,
    ef: f64 = 1,
    /// The signed factor the contribution applies (contract `PsdTerm.coeff`).
    coeff: f64 = 1,
    /// List index of this row's group's first row; `maxInt` reads as the row
    /// itself, so a hand-built list of independent rows can leave it.
    group: u32 = std.math.maxInt(u32),
    /// The §4.6.4.3/.4 table of a table row; empty `points` otherwise. The
    /// slice is the device's static data and outlives every list.
    table: contract.NoiseTable = .{ .interp = .linear, .points = &.{} },

    /// Returns the tabulated PSD at `f` (contract `noiseTableAt`), or 0 for
    /// a parametric row.
    pub fn tableAt(self: NoiseSource, f: f64) f64 {
        return if (self.table.points.len == 0) 0 else contract.noiseTableAt(self.table, f);
    }

    /// Returns the end of the group starting at `srcs[lead]`: rows
    /// `[lead, end)` are one correlated generator. Asserts that `lead` starts
    /// a group.
    pub fn groupEnd(srcs: []const NoiseSource, lead: usize) usize {
        std.debug.assert(srcs[lead].group == lead or srcs[lead].group == std.math.maxInt(u32));
        var end = lead + 1;
        while (end < srcs.len and srcs[end].group == lead) end += 1;
        return end;
    }
};

/// The physical origin a device declares for a noise generator.
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
    /// The type runs a digital engine (a Verilog `.v` module) whose time
    /// only moves forward, so analyses that rewind time refuse it
    /// (`Circuit.refuseDigital`). The frontend copies it from
    /// `Library.digital` at the freeze.
    digital: bool = false,
};

/// Where `Hooks.status` found a latched status: the instance index within
/// the batch and the length of the message it wrote.
pub const StatusHit = struct { index: u32, len: u32 };

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

        /// Encodes this compilation's error union for the trip across the
        /// object boundary.
        pub fn fromLocal(value: error{ OutOfMemory, TooManyInstances }!T) @This() {
            return .{ .ok = value catch |err| return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.TooManyInstances => .too_many_instances,
            } };
        }

        /// Decodes into the caller's own error values, whatever numbering the
        /// compilation that produced it used.
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
    /// Overwrites the first batch's mutable state (models, instances,
    /// history, limiting state) with the second's. Both must be this type
    /// and one a `snapshot` of the other, or of a common batch. Allocates
    /// nothing, so `ParamRef`s into the first stay valid.
    copy_state: *const fn (*anyopaque, *const anyopaque) void,
    /// Syncs the host limiting flag after GPU state is downloaded.
    set_limit_active: ?*const fn (*anyopaque, bool) void = null,
    /// `{slot_lo, slot_hi, row_lo, row_hi}` touched by instances
    /// `[first, last)`, the trash slot and row excluded.
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    clear_limits: ?*const fn (*anyopaque) void = null,
    /// Advances Newton-history state between evaluated iterates, given the
    /// previous x.
    advance_iteration: ?*const fn (*anyopaque, []const f64) void = null,
    check_convergence: ?*const fn (*anyopaque, []const f64) bool = null,
    /// Overwrites the batch's internal voltage unknowns in `trial`, the
    /// transient's first Newton iterate, with `cur + xfact * (cur - prev)`:
    /// the last two accepted points extrapolated at the device's own ratio.
    /// Only models whose load predicts over another step than the host's
    /// dt/dt_prev have it (`predictsOverDeltaOld2` in eval.zig).
    predict_first_iterate: ?*const fn (*anyopaque, trial: []f64, cur: []const f64, prev: []const f64, xfact: f64) void = null,
    /// Sets `mask[row]` for each internal node voltage of a model whose
    /// ngspice load keeps its own current convergence test (the host's
    /// `Circuit.loadCheck`); every device current into those rows is the
    /// model's own.
    mark_load_check_rows: ?*const fn (*anyopaque, mask: []bool) void = null,
    seed: ?*const fn (*anyopaque, []f64) void = null,
    /// Writes each LRM §4.5.4 `idt` initial condition into its operator
    /// unknown in `x`, for a transient that skips the operating point
    /// (`uic`), which would otherwise have solved it. Reads the device's
    /// static form, so the host sets a static sim state (dt = 0) first. An
    /// idt without ic keeps its value.
    seed_ic: ?*const fn (*anyopaque, []f64) void = null,
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    /// Runs `updateState` at x once per converged solve; returns the earliest
    /// requested rejection time, if any. `state_ctl(.revert)` takes it back
    /// exactly only when it is the one `updateState` since the last commit
    /// or revert.
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// `update_state` for delay-line history (`absdelay`, the native lines):
    /// called once per accepted transient point instead, before
    /// `state_ctl(.commit)`, so no static solve pushes the ring.
    commit_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// VerA `stateCtl`: `.commit` at every accepted point, the operating
    /// point included, `.revert` after a rejected attempt, `.query` for a
    /// cross/above flip since the last commit. Commit runs once at
    /// instantiation too, so a revert is always defined.
    state_ctl: ?*const fn (*anyopaque, StateCtlOp) bool = null,
    /// Sets every instance's temperature, in Celsius.
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    /// Sets §9.15 `$simparam("gmin")` (S) and `("sourceScaleFactor")` on
    /// every Model row, for the operating point's stepping rungs. Null when
    /// the model reads neither.
    set_homotopy: ?*const fn (*anyopaque, gmin: f64, source_scale: f64) void = null,
    /// Stores the analysis state (`$abstime`, timestep, `analysis()`,
    /// initial/final step, Newton iteration) that every later device call
    /// of this batch receives. One store per batch, so it is cheap enough
    /// to call per Newton iteration.
    set_sim_state: *const fn (*anyopaque, SimState) void,
    /// The model's smallest static delay (`D.delays`).
    min_delay: ?*const fn (*anyopaque) f64 = null,
    /// The tightest LRM §9.17.2 `$bound_step` any instance requested for the
    /// next step, or `inf`. Valid after `updateState` has run for the
    /// accepted step.
    bound_step: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    /// The first instance with a latched VerA `$fatal`/`$error`
    /// (`vera_status__`): writes its `contract.formatStatus` text into `msg`,
    /// truncated to fit. Null when the type has no status sites; those types
    /// are `mutable_eval`, so their instances live on the host.
    status: ?*const fn (*anyopaque, msg: []u8) ?StatusHit = null,
    /// Charge per instance and LTE site (`ddt()` sites not marked
    /// `vera_lte = 0`) from the last eval, instance-major. Lets the transient
    /// run its LTE per charge state, as ngspice's CKTterr does, instead of
    /// per summed matrix row. Null when the device has no `q`.
    q_tape: ?*const fn (*anyopaque) []const f64 = null,
    /// Restamps `q_vec` and `q_tape` for instances `[first, last)` at x,
    /// leaving the other planes alone. Null when the device has no `q`.
    eval_q: ?*const fn (*anyopaque, *const Planes, u32, u32, []const f64, f64) void = null,
    /// `eval_q` and `update_state` at a converged point from one model-core
    /// run per instance (VerA's `acceptQ`), over instances `[first, last)`.
    /// The time is the published sim state's. Null when the device has no
    /// `acceptQ`: no charge, or it calls `$vera_reject_step`, whose request
    /// a charge return cannot carry. The host then calls the two hooks.
    accept_q: ?*const fn (*anyopaque, *const Planes, u32, u32, []const f64) void = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) DeviceResult(void),
    /// Appends every declared noise generator with its PSD at x. Temperature
    /// is the instance's own, already applied by the device.
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) DeviceResult(void) = null,
    /// The model's name for each generator `collect_noise` appends per
    /// instance, in that order (LRM §4.6.4 `name` argument; "" when absent).
    /// Its length is the per-instance generator count.
    noise_names: []const []const u8 = &.{},
    /// Appends the global CSC slot of every frequency-dependent small-signal
    /// entry (VerA `ac_dyn_slots`: §4.5.7 absdelay, §4.5.11 laplace, §4.5.12
    /// zi), instance-major. A ground entry reads as the trash slot. Under
    /// kind `.ac`/`.noise` the G and C planes leave these partials out, and
    /// `ac_dyn` supplies them. Null when the device has none.
    collect_ac_dyn: ?*const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(u32)) DeviceResult(void) = null,
    /// Writes the small-signal term of each `collect_ac_dyn` entry e at x and
    /// at every ω in `omegas`: `re[e * omegas.len + k]` and `im[...]`, so
    /// A(ω_k) = G + jω_kC + (re + j·im) per entry. Reads the stored sim state
    /// (`set_sim_state`), its t included. Returns the number of entries
    /// written; `re`/`im` must hold at least that many times `omegas.len`.
    ac_dyn: ?*const fn (*anyopaque, x: []const f64, omegas: []const f64, re: []f64, im: []f64) usize = null,
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
    /// Adds every staged instance's matrix entries; the allocator is the
    /// builder's.
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) DeviceResult(void),
    /// Builds the frozen batch, allocated with the given allocator, against
    /// the final pattern. The proto still needs `destroy` afterwards.
    finalize: *const fn (*anyopaque, std.mem.Allocator, PatternView) DeviceResult(Batch),
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    /// Renumbers staged nodes through `perm` (old id to new); ids at or past
    /// `perm.len`, ground among them, stay as they are.
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

/// A read-only CSC sparsity pattern. `trash_slot` (= nnz) is the slot ground
/// entries scatter into.
pub const PatternView = struct {
    col_ptr: []const u32,
    row_idx: []const u32,
    n: u32,
    trash_slot: u32,

    /// The slot of (`row`, `col`), or null when the pattern lacks it. Binary
    /// search, O(log) in the column's length.
    /// Asserts that `col < n`.
    pub fn findSlot(self: PatternView, row: u32, col: u32) ?u32 {
        std.debug.assert(col < self.n);
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

    /// Records entry (`row`, `col`); duplicates merge in `toCsc`.
    pub fn add(self: *PatternBuilder, gpa: std.mem.Allocator, row: u32, col: u32) !void {
        try self.keys.append(gpa, (@as(u64, col) << 32) | row); // col-major sort order
    }

    /// Makes room for `extra` more `add`s.
    pub fn reserve(self: *PatternBuilder, gpa: std.mem.Allocator, extra: usize) !void {
        try self.keys.ensureUnusedCapacity(gpa, extra);
    }

    /// Frees the keys; `gpa` must be the allocator every `add` used.
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
    /// nnz. Rows come out ascending within each column. O(keys).
    /// Caller owns `col_ptr_out` (n + 1 entries) and `row_idx_out` (nnz) and
    /// must free them with `gpa`; `scratch` is only used during the call.
    /// Reorders `keys` in place.
    /// Asserts that every column is below `n`.
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
        // Sorted, so the last key holds the largest column.
        std.debug.assert(m == 0 or all[m - 1] >> 32 < n);

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
    /// copy is the whole upload. `models` holds one row per distinct Model,
    /// fewer than `count` when instances share one.
    models: []const u8,
    /// count: instance i's row of `models`. Every kernel reads its Model
    /// through it.
    model_of: []const u32,
    instances: []const u8,
    /// count * n_u: the global row each local unknown gathers x from.
    gath: []const u32,
    /// count * n_u: the residual row each local unknown scatters to.
    rhs_idx: []const u32,
    /// The CSC slot each local Jacobian entry the device's jac/q pattern sets
    /// scatters to, row-major, the same number per instance.
    slots: []const u32,
    /// `arp_lim_<model>`, or "" when the device has no state kernel.
    lim_kernel: []const u8,
    /// `arp_ctl_<model>`, or "" when the device has no accepted-step latch.
    ctl_kernel: []const u8,
    /// `arp_reduce_<model>`, the segmented sum from staging cells to planes.
    reduce_kernel: []const u8,
    /// Host lim plane for the initial upload, one value per instance and
    /// unknown `limit` writes, empty without `limit`. Stale once the
    /// device-side state kernel has run.
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
// 14: VerA contract ABI 5. `SimState` (hashed) reaches every device call and
//    GPU kernel by value; `Hooks.begin_solve` is gone and `set_sim_state` is
//    required.
// 15: `Hooks.collect_ac_dyn`/`ac_dyn`, VerA's frequency-dependent entries.
// 16: `Hooks.copy_state`, `Batch.digital`.
// 17: `Hooks.predict_first_iterate`, `Hooks.mark_load_check_rows`.
// 18: `Hooks.accept_q`.
// GPU planes, Model/Instance PODs and scatter tapes are unchanged by 10 to 18.
// 19: instances share bit-identical Models: `GpuPayload.model_of`, and every
//    kernel takes `model_of` after `models`.
// 20: the slot tape holds only the device's pattern entries, not n_u^2.
// 21: the lim plane holds only the unknowns `limit` writes, not n_u.
// 22: `Hooks.status`, VerA's `$fatal`/`$error` channel.
// 23: `Hooks.set_homotopy`, VerA's host-written `gmin__`/`source_scale__`.
// 24: `NoiseSource.coeff` (no longer folded into white/flicker), `.group`
//    (correlated rows contiguous) and `.table`.
// 25: `DeviceVtable.unknown_names`.
pub const abi_version: u32 = 25;

/// A device type's construction entry points, exported by each device object
/// and by runtime-loaded `.so` devices.
/// Every blob pointer it takes must be 16-byte aligned: the host aligns every
/// Model and Instance blob to 16, and no device field needs more.
pub const DeviceVtable = struct {
    name: []const u8,
    /// Unknowns per instance: the ports, then the internal nodes.
    n_u: u32,
    num_ports: u32,
    /// Bytes of the Model blob the model callbacks read and write.
    model_size: usize,
    /// Bytes of the Instance blob.
    instance_size: usize,
    /// Writes the declared defaults into a `model_size` blob.
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
    /// Stages one instance into a `proto_create` store, copying both blobs;
    /// `nodes` holds `n_u` global unknowns.
    proto_add: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) DeviceResult(void),
    /// Name of each unknown in `[0, n_u)`, VerA's `U`: the ports, the
    /// internal nets, then the branch flows (`flowZ28...`, mangled `flow(`).
    /// Empty when the device does not say.
    unknown_names: []const []const u8 = &.{},
};

/// Hash of every type that crosses the object boundary, the compiler
/// version, backend and mode, and `abi_version`. Both sides compile this same
/// source, so equal hashes mean compatible layouts.
pub fn layoutHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h: u64 = 0xcbf29ce484222325;
        for (builtin.zig_version_string) |c| h = mix(h, c);
        h = mix(h, @backingInt(builtin.zig_backend));
        h = mix(h, @backingInt(builtin.mode));
        // Error tracing adds a hidden argument to every callconv(.auto) call.
        h = mix(h, @intFromBool(builtin.have_error_return_tracing));
        for ([_]type{
            DeviceVtable,        Proto,               Batch,
            Hooks,               Planes,              PatternView,
            PatternBuilder,      ParamRef,            NoiseSource,
            std.mem.Allocator,   DeviceStatus,        DeviceResult(void),
            DeviceResult(Batch), DeviceResult(Proto), Param,
            SimState,            StatusHit,
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
        .@"struct" => |si| inline for (si.field_names, si.field_types, si.field_attrs) |name, FT, attrs| {
            if (!attrs.@"comptime" and @sizeOf(FT) > 0) h = mix(h, @offsetOf(T, name));
        },
        else => {},
    }
    return h;
}

test {
    _ = bind;
}

test DeviceResult {
    const R = DeviceResult(u32);
    try std.testing.expectEqual(@as(u32, 7), try R.fromLocal(7).unwrap());
    try std.testing.expectError(error.OutOfMemory, R.fromLocal(error.OutOfMemory).unwrap());
    try std.testing.expectError(error.TooManyInstances, R.fromLocal(error.TooManyInstances).unwrap());
}

test ParamRef {
    var narrow: f32 = 0;
    var wide: f64 = 0;
    const a: ParamRef = .{ .ptr = .{ .f32 = &narrow }, .param_name = "w", .index = 0, .is_instance = true, .primary = false };
    const b: ParamRef = .{ .ptr = .{ .f64 = &wide }, .param_name = "l", .index = 0, .is_instance = true, .primary = true };
    a.set(0.1);
    b.set(0.1);
    try std.testing.expectEqual(@as(f64, @as(f32, 0.1)), a.get());
    try std.testing.expectEqual(@as(f64, 0.1), b.get());
}

test "PatternView.findSlot: hits, misses and an empty column" {
    // Column 0 holds rows {0, 2}, column 1 nothing, column 2 row {1}.
    const v: PatternView = .{ .col_ptr = &.{ 0, 2, 2, 3 }, .row_idx = &.{ 0, 2, 1 }, .n = 3, .trash_slot = 3 };
    const expectSlot = struct {
        fn f(want: ?u32, got: ?u32) !void {
            try std.testing.expectEqual(want, got);
        }
    }.f;
    try expectSlot(0, v.findSlot(0, 0));
    try expectSlot(1, v.findSlot(2, 0));
    try expectSlot(null, v.findSlot(1, 0));
    try expectSlot(null, v.findSlot(3, 0));
    try expectSlot(null, v.findSlot(0, 1));
    try expectSlot(2, v.findSlot(1, 2));
    try expectSlot(null, v.findSlot(0, 2));
    try expectSlot(null, v.findSlot(std.math.maxInt(u32), 2));
}

test "PatternBuilder.radixSort matches a comparison sort at every length and digit mix" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    // Which 16-bit digits vary: none, one (an odd pass count, so the result
    // lands in the temporary), rows and columns below 65536 (the middle
    // digits skipped), rows and columns past it (three passes), all four.
    const masks = [_]u64{ 0, 0xff, 0x0000_ffff_0000_ffff, 0x0003_0000_0003_ffff, std.math.maxInt(u64) };
    // Around the 64-key cutoff to the comparison sort, and past it.
    const lens = [_]usize{ 0, 1, 2, 63, 64, 65, 200, 1000 };
    for (masks) |mask| {
        for (lens) |len| {
            const keys = try gpa.alloc(u64, len);
            defer gpa.free(keys);
            for (keys) |*k| k.* = r.int(u64) & mask;
            const want = try gpa.dupe(u64, keys);
            defer gpa.free(want);
            std.mem.sortUnstable(u64, want, {}, std.sort.asc(u64));
            try PatternBuilder.radixSort(gpa, keys);
            try std.testing.expectEqualSlices(u64, want, keys);
        }
    }
}

fn toCscCase(gpa: std.mem.Allocator) !void {
    var pb: PatternBuilder = .{};
    defer pb.deinit(gpa);
    // Column 1 stays empty; (2, 0) arrives twice and out of order.
    for ([_][2]u32{ .{ 2, 0 }, .{ 0, 0 }, .{ 2, 2 }, .{ 2, 0 }, .{ 1, 2 } }) |rc| try pb.add(gpa, rc[0], rc[1]);
    var col_ptr: []u32 = undefined;
    var row_idx: []u32 = undefined;
    const nnz = try pb.toCsc(gpa, gpa, 3, &col_ptr, &row_idx);
    defer gpa.free(col_ptr);
    defer gpa.free(row_idx);
    try std.testing.expectEqual(@as(u32, 4), nnz);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 2, 4 }, col_ptr);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 1, 2 }, row_idx);
}

test "PatternBuilder.toCsc dedups, sorts rows and keeps empty columns" {
    try toCscCase(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, toCscCase, .{});
}

test "PatternBuilder.toCsc of no keys is all-empty columns" {
    const gpa = std.testing.allocator;
    var pb: PatternBuilder = .{};
    defer pb.deinit(gpa);
    var col_ptr: []u32 = undefined;
    var row_idx: []u32 = undefined;
    try std.testing.expectEqual(@as(u32, 0), try pb.toCsc(gpa, gpa, 2, &col_ptr, &row_idx));
    defer gpa.free(col_ptr);
    defer gpa.free(row_idx);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, col_ptr);
    try std.testing.expectEqual(@as(usize, 0), row_idx.len);
}

test "hashType sees a field's width" {
    const A = extern struct { a: u32, b: u32 };
    const B = extern struct { a: u32, b: u64 };
    try std.testing.expect(hashType(0, A) != hashType(0, B));
}
