//! Device IR shared by construction and analysis. These declarations contain
//! prepared topology and evaluator bindings, without evaluation or scheduling.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract");

pub const GROUND: u32 = 0;

/// Launch width shared by the kernel export shim and analysis GPU launcher.
pub const gpu_block_size: u32 = 256;

pub const StateCtlOp = contract.StateCtlOp;
pub const SimState = contract.SimState;
pub const LimitResult = contract.LimitResult;
pub const Constant = contract.Constant;

// ===========================================================================
// Circuit-facing types
// ===========================================================================

pub const ParamRef = struct {
    /// Tagged because BOTH widths are live: VerA emits `f64` parameters, while
    /// hand-written devices (tests/testdev.zig, and any device written straight
    /// against the contract) still use `f32`. A single-width `*f32` here is what
    /// silently emptied `collectParams` for every generated device and took
    /// `.dc` sweep, Monte Carlo, sensitivity and dcmatch down with it — those
    /// four read the circuit's parameters through this and got nothing back.
    ///
    /// The accessors below are the whole interface; nothing outside should
    /// switch on the tag. Values move as `f64` because that is what the callers
    /// compute in — an `f32` field round-trips through `@floatCast`, which is
    /// exactly the precision the device declared.
    ptr: Ptr,
    device_type: []const u8,
    param_name: []const u8,
    index: u32,
    is_instance: bool,
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

    /// Low-level write; call Circuit.recompute before solving to validate topology and caches.
    pub fn set(self: ParamRef, v: f64) void {
        switch (self.ptr) {
            .f32 => |p| p.* = @floatCast(v),
            .f64 => |p| p.* = v,
        }
    }
};

/// One generator's branch and its PSD, in the contributed nature's units² per
/// Hz: `S(f) = white + flicker / f^ef`.
///
/// A DENSITY, NOT A KIND TAG, and the kind is not recoverable from one.
/// Verilog-A §4.6.4.1 states the density outright as the call's argument, so
/// `white_noise(2q|I|)` (shot) and `white_noise(4kT/R)` (thermal) are the same
/// call. ngspice agrees at the analysis boundary: `NevalSrc`
/// (nevalsrc.c:105-113) collapses SHOTNOISE and THERMNOISE into one
/// `noise = gain * <density>` the instant it is called, and its THERMNOISE
/// `param` is not even always a conductance (mos1noi.c:140-142 passes the
/// channel's `Sid`). Every 1/f source is an `N_GAIN` call (nevalsrc.c:115-117)
/// the device then multiplies by its OWN `KF·I^AF/f^EF` — dionoise.c:99-104
/// and bjtnoise.c:112-118 at EF = 1, mos1noi.c:175-181 at `pow(freq, fNexp)`.
/// Which physics produced the density is the device's business;
/// `contract.PsdTerm` is the same shape on the device side and `collectNoise`
/// copies it across.
pub const NoiseSource = struct {
    node_p: u32,
    node_n: u32,
    white: f64 = 0,
    flicker: f64 = 0,
    ef: f64 = 1,
};

pub const NoiseGenKind = enum { thermal, shot, flicker };
pub const NoiseGen = struct { row: usize, col: usize, kind: NoiseGenKind };
/// What a device's `noisePsd` returns, one per `noise_gens` row. Same type the
/// VerA-generated devices use; re-exported so a hand-written device can name it.
pub const PsdTerm = contract.PsdTerm;

/// Target value planes for one eval pass. Circuit.eval points this at its own
/// slices; parallel eval points lanes 1.. at private slabs and reduces after.
pub const Planes = struct {
    g_vals: []f64,
    c_vals: []f64,
    rhs: []f64,
    q_vec: []f64,
};

/// Per-type device batch vtable. One entry per device TYPE, created by
/// ProtoStore(D).finalize(). eval/eval_newton stamp [first..last) into `pl` —
/// the caller picks the target planes, so the same entry point serves the
/// serial path and a ParEval lane's private slab.
pub const Batch = struct {
    // -- hot --
    ctx: *anyopaque,
    eval: *const fn (*anyopaque, *const Planes, first: u32, last: u32, []const f64, f64) void,
    eval_newton: *const fn (*anyopaque, *const Planes, first: u32, last: u32, []const f64, f64) void,
    count: u32,
    n_u: u32,
    has_charge: bool,
    has_const_jacobian: bool,
    /// False when eval uses shared per-batch scratch — such a batch runs whole
    /// on one lane.
    thread_safe: bool,

    // -- cold --
    type_name: []const u8,
    hooks: *const Hooks,
};

/// Stable CPU callback status. Zig error ordinals belong to one compilation
/// unit and must never cross a separately compiled object or shared library.
pub const DeviceStatus = enum(u8) { ok = 0, out_of_memory = 1, too_many_instances = 2 };

/// By-value callback result; a successful payload retains its existing owner.
/// The closed error set makes adding a producer error an explicit ABI decision.
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

/// Cold per-device-type vtable. Null entry ⇒ device type lacks the hook.
pub const Hooks = struct {
    /// Fresh mutable evaluator state from an unevaluated prepared template.
    /// The template and its frozen tapes must outlive every instance.
    instantiate: *const fn (*const anyopaque, std.mem.Allocator) DeviceResult(Batch),
    /// Copy an accepted dependency state, preserving all mutable POD histories.
    snapshot: *const fn (*const anyopaque, std.mem.Allocator) DeviceResult(Batch),
    /// Synchronize the host limiting flag after downloading GPU state.
    set_limit_active: ?*const fn (*anyopaque, bool) void = null,
    scatter_bounds: *const fn (*anyopaque, first: u32, last: u32, trash_slot: u32, trash_row: u32) [4]u32,
    apply_limits: ?*const fn (*anyopaque, []f64, []const f64) bool = null,
    clear_limits: ?*const fn (*anyopaque) void = null,
    begin_solve: ?*const fn (*anyopaque) void = null,
    /// Advance only between evaluated Newton iterates, using the previous x.
    advance_iteration: ?*const fn (*anyopaque, []const f64) void = null,
    check_convergence: ?*const fn (*anyopaque, []const f64) bool = null,
    seed: ?*const fn (*anyopaque, []f64) void = null,
    mark_current_rows: ?*const fn (*anyopaque, []bool) void = null,
    update_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    /// `updateState` for a device that declares NO `stateCtl` — one whose
    /// accepted-step state cannot be rolled back. Called once per ACCEPTED
    /// step instead of once per Newton iteration.
    ///
    /// §4.5.2 calls this "accepted-step bookkeeping" and it has to be taken
    /// literally. VerA lowers `absdelay` to a `zHistPush` into a fixed
    /// 32-entry ring INSIDE `updateState`. Driven per Newton iteration —
    /// rejected attempts included — a transmission line took ~10 pushes per
    /// timestep, so the ring spanned a fraction of one timestep instead of
    /// 32 of them; every delay lookup fell off the end, `zHistAt` returned
    /// the NEWEST sample, and the line behaved as if it had no delay.
    ///
    /// That fed back into the solver: the bogus residual stopped Newton
    /// converging, dt halved, and more attempts meant more pushes.
    /// devices/lossy_tline ran 51,847 step attempts — 25,624 rejected, mean
    /// 9.9 iterations against a cap of 10 — to emit 600 requested points.
    ///
    /// Only HISTORY devices defer. Everything else keeps the per-iteration
    /// call: either `stateCtl` makes its updates undoable, or its
    /// `request_reject_at` is a breakpoint that must be seen per attempt for
    /// a source edge to land sharply.
    commit_state: ?*const fn (*anyopaque, []const f64) ?f64 = null,
    state_ctl: ?*const fn (*anyopaque, StateCtlOp) bool = null,
    set_temp: ?*const fn (*anyopaque, f32) void = null,
    /// Host-owned Instance fields (`$abstime`, timestep, `analysis()`,
    /// `initial_step`/`final_step`). A generated device READS these and never
    /// writes them, so nothing else in the engine can supply them — without
    /// this hook `$abstime` is pinned at its default 0 and every SPICE
    /// waveform degenerates to its t=0 value.
    ///
    /// Contract with the analyses: call it once per SOLVE ATTEMPT (before
    /// eval/updateState run for that attempt), never per Newton iteration —
    /// it walks every instance, so it is O(count) per timepoint by design.
    set_sim_state: ?*const fn (*anyopaque, SimState) void = null,
    record_history: ?*const fn (*anyopaque, []const f64, f64) void = null,
    inject_history: ?*const fn (*anyopaque, f64, []f64) void = null,
    min_delay: ?*const fn (*anyopaque) f64 = null,
    /// §9.17.2 `$bound_step`: the tightest NEXT-step bound any instance of
    /// this device type asked for, or `inf`. Written by the device's
    /// `updateState`, so it is only meaningful after one has run — the
    /// transient reads it per accepted step, which is what §9.17.2 says.
    ///
    /// Distinct from `min_delay`, which is a static property of the MODEL
    /// (`D.delays`). A generated device has no `delays` decl at all, so
    /// `min_delay` is null for every VerA model and the transmission lines
    /// were running completely unbounded: tline's `$bound_step(0.25*td)` was
    /// computed, stored, and read by nothing.
    bound_step: ?*const fn (*anyopaque) f64 = null,
    next_breakpoint: ?*const fn (*anyopaque, f64) ?f64 = null,
    /// Per-device-STATE charge tape: `q_tape()[id * n_u + ru]` is the charge
    /// THIS instance put on row `rhs_idx[id * n_u + ru]` at the last eval —
    /// the same index space `gath`/`rhs_idx`/`slots` already use, so it adds
    /// no new handle type. Null when the device declares no `q`.
    ///
    /// Exists because ngspice runs CKTterr once per device charge STATE and
    /// mins over states, then over devices (ckttrunc.c -> DEVtrunc ->
    /// cktterr.c), where this engine ran it once per matrix ROW off the summed
    /// q plane. Summing co-moving charges first adds their divided differences
    /// and loses the binding state (docs/analysis/transient-integration.md).
    /// Host-only and additive: the four `[]f64` planes, the u32 tapes, the CSC
    /// pattern, the Model/Instance PODs and `DeviceKernel.run`'s parameter
    /// list are all unchanged.
    q_tape: ?*const fn (*anyopaque) []const f64 = null,
    /// Charges only, instances `[first, last)`: restamp `q_vec` + `q_tape` at
    /// `x` and leave g/c/rhs alone. Null when the device declares no `q`. See
    /// `evalQRange` — this is the transient's post-accept re-read, not a second
    /// eval path. Ranged for the same reason `eval` is: ParEval's `.charge`
    /// mode hands each lane the same instance range it gets in `.full`.
    eval_q: ?*const fn (*anyopaque, *const Planes, u32, u32, []const f64, f64) void = null,
    collect_params: *const fn (*anyopaque, std.mem.Allocator, *std.ArrayList(ParamRef)) DeviceResult(void),
    /// Every generator this batch declares, with its PSD, at a state vector the
    /// caller hands in. No temperature argument: `$temperature` is the
    /// INSTANCE's, and the device already applied it inside `noisePsd`.
    collect_noise: ?*const fn (*anyopaque, []const f64, std.mem.Allocator, *std.ArrayList(NoiseSource)) DeviceResult(void) = null,
    /// False means parameter changes invalidate the frozen topology.
    recompute: ?*const fn (*anyopaque) bool = null,
    /// This batch's device-resident working set, or null when the device type
    /// is not `gpuEligible` — the launcher reads a null here as "this batch
    /// stays on the CPU" and declines the whole circuit rather than splitting a
    /// solve across both, which would cost a plane round-trip per iteration to
    /// merge.
    gpu_payload: ?*const fn (*anyopaque) GpuPayload = null,
    apply_attempt: ?*const fn (*anyopaque, f64) void = null,
    restore_models: ?*const fn (*anyopaque) void = null,
    deinit: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const Proto = struct {
    ctx: *anyopaque,
    type_name: []const u8,
    pattern: *const fn (*anyopaque, std.mem.Allocator, *PatternBuilder) DeviceResult(void),
    finalize: *const fn (*anyopaque, std.mem.Allocator, PatternView) DeviceResult(Batch),
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    apply_perm: *const fn (*anyopaque, []const u32) void,
};

pub const PatternView = struct {
    col_ptr: []const u32,
    row_idx: []const u32,
    n: u32,
    trash_slot: u32,

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

/// Union sparsity accumulator: one `(col << 32 | row)` key per stamp site
/// BEFORE dedup, sorted and uniqued into CSC by `toCsc`.
///
/// The `gpa` its methods take is build-time SCRATCH, not the circuit's owner:
/// `keys` and the radix ping-pong buffer die inside `Circuit.init`, and only
/// `col_ptr`/`row_idx` — which `toCsc` takes a separate allocator for —
/// outlive it. Passing the sim arena here left the pre-dedup key array and the
/// sort scratch resident for the whole run (measured 14.6 MB on
/// `sweep/opamp_wl_5000`, where 650,017 keys dedup to 115,017 nonzeros),
/// because `ArenaAllocator.free` is a no-op for anything but its most recent
/// allocation.
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

    /// LSD radix sort (16-bit digits): O(n) on the bounded (col,row) keys.
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
            // Packed u32 node ids leave zero digits between row and column
            // when n < 65536. The OR also bounds every occupied bucket.
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

    /// `gpa` owns the returned CSC; `scratch` owns the radix ping-pong buffer
    /// and dies with the caller's frame.
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

/// One batch's device-resident working set, type-erased.
///
/// Everything here is written by the builder and then FROZEN for the life of
/// the solve, which is what lets the launcher upload it once and leave it on
/// the GPU: the tapes are pattern, and `models`/`instances` only change when a
/// sweep mutates a parameter (see the `repack` hook). Per Newton iteration the
/// launcher moves `x` in and the value planes out, and nothing else.
pub const GpuPayload = struct {
    /// `arp_eval_<model>`, from `kernelName`.
    kernel: []const u8,
    /// Instances in this batch — one GPU thread each.
    count: u32,
    /// Unknowns per instance. Fixes the tape strides below.
    n_u: u32,
    /// `[]D.Model` / `[]D.Instance` as bytes. POD by contract (§5 rule 3), so a
    /// byte copy is the whole upload.
    models: []const u8,
    instances: []const u8,
    /// count * n_u — global row each local unknown gathers x from.
    gath: []const u32,
    /// count * n_u — residual row each local unknown scatters to.
    rhs_idx: []const u32,
    /// count * n_u * n_u — CSC slot each Jacobian entry scatters to.
    slots: []const u32,
    /// `arp_lim_<model>` when the device pairs a `StateKernel` with its eval
    /// kernel (`hasStateKernel`), else "".
    lim_kernel: []const u8,
    /// `arp_ctl_<model>` when the device latches accepted-step state
    /// (`hasCtlKernel`), else "".
    ctl_kernel: []const u8,
    /// `arp_reduce_<model>` — the segmented sum that turns this pass's staging
    /// cells back into plane values. Device-independent body; see
    /// `reduceKernelName` for why it carries a per-device symbol anyway.
    reduce_kernel: []const u8,
    /// Host lim plane (count * n_u), for the seed-era upload; empty when the
    /// device has no `limit`. Once the device StateKernel runs, the resident
    /// copy is authoritative and this is stale by design.
    lim_x: []const f64,
    /// `[]D.State` as bytes (POD), uploaded once; empty when no `State`.
    states: []const u8,
    /// Host-side lim_active at call time — only consulted until the device
    /// takes the lim plane over (seed → first eval).
    lim_active: bool,
};

// Version 10 replaces compilation-local Zig errors in CPU callbacks with
// explicit statuses, including the topology check. Old callbacks are incompatible.
// GPU planes, Model/Instance PODs and scatter tapes are unchanged.
pub const abi_version: u32 = 10;

pub const DeviceVtable = struct {
    name: []const u8,
    n_u: u32,
    num_ports: u32,
    model_size: usize,
    instance_size: usize,
    init_model: *const fn ([*]u8) void,
    init_instance: *const fn ([*]u8) void,
    set_model_param: *const fn ([*]u8, []const u8, f64) bool,
    set_instance_param: *const fn ([*]u8, []const u8, f64) bool,
    /// LRM 6.3.4 / 3.4.5: a parameter whose value is an expression over OTHER
    /// parameters, plus every localparam. The Model is a flat struct, so a host
    /// write to a base parameter cannot reach what was declared over it — the
    /// device closes that gap here, and the contract requires the host to call it
    /// once after the last `set_model_param` and before anything READS the model.
    /// Null when the module has no such parameter, which is the common case.
    derive: ?*const fn (model: [*]u8) void,
    collapse: ?*const fn (model: [*]const u8, instance: [*]const u8, out: [*]i32) void,
    proto_create: *const fn (std.mem.Allocator) DeviceResult(Proto),
    proto_add: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, model: [*]const u8, instance: [*]const u8, nodes: [*]const u32) DeviceResult(void),

    // GPU eval kernel this device emitted from `engine.DeviceKernel` at
    // `.so`-build-time (empty ⇒ CPU-only). The `.so` compiles the SAME template
    // the builtins use, so the format matches; the app links it into its gompute
    // context by `gpu_kernel_name`. Populated by the compileGenerated shim
    // (dynamic devices); empty for the in-process vtable (builtins bake their
    // kernels via kernels.zig instead).
    gpu_kernel_name: []const u8 = "",
    gpu_ptx: []const u8 = "", // NVIDIA cubin/PTX image
    gpu_amdgcn: []const u8 = "", // AMD code object
};

/// Layout guard over every type that crosses the boundary + the compiler
/// version. Both sides compile this same source; equal hashes ⇒ compatible.
pub fn layoutHash() u64 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var h: u64 = 0xcbf29ce484222325;
        for (builtin.zig_version_string) |c| h = mix(h, c);
        h = mix(h, @intFromEnum(builtin.zig_backend));
        h = mix(h, @intFromEnum(builtin.mode));
        for ([_]type{
            DeviceVtable,        Proto,               Batch,
            Hooks,               Planes,              PatternView,
            PatternBuilder,      ParamRef,            NoiseSource,
            std.mem.Allocator,   DeviceStatus,        DeviceResult(void),
            DeviceResult(Batch), DeviceResult(Proto),
        }) |T| h = hashType(h, T);
        // Not a type: the SEMANTICS of the slot tape. A `.so` built before
        // `jac_pattern` reserves every (ru, cu) in the matrix and fills every
        // one; this host reserves only the device's structural pattern. Same
        // struct layouts, incompatible tapes — so the hash has to move.
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
