//! The GPU lane backend's device state (dev/research/plans/phase4-gpu-lanes.md
//! G6): N transient lanes resident on one device, lane-major, with the
//! model-independent kernels of `solver/lane_device.zig` and each model's
//! lane kernels (`eval.zig` `arp_l*`). Per round the host uploads each
//! lane's step scalars, the device predicts, solves Newton for every lane,
//! and computes the step-end numbers (`probe`): the state-flip query, the
//! charge tape at the solution, the LTE bounds and the probe rows. The
//! host's `tran.Sim.end` decides each lane from them through `Ops`, and
//! `apply` runs the decisions' device mutations. The CPU lane path
//! (`tran.runLanes`) is the oracle; results match it within tolerance, not
//! bitwise.
//!
//! In: N lane circuits after `tran.Sim.init`, on one pattern. Out: per lane
//! Newton results and probe numbers; the lanes' device instances copied back
//! to the host at `deinit`.

const std = @import("std");
const device_ir = @import("device").abi;
const gompute = @import("gompute");
const solver = @import("solver");
const lk = solver.lane_kernels;
const direct = solver.direct;
const converger = solver.converger;
const root = @import("types.zig");
const Circuit = root.Circuit;
const SimState = device_ir.SimState;
const StateCtlOp = device_ir.StateCtlOp;

const artifacts = @import("gompute_kernels");
const backend: ?gompute.Backend = if (artifacts.has_cuda)
    .cuda
else if (artifacts.has_hip)
    .hip
else
    null;

/// This binary carries kernel images; whether they include the lane
/// kernels is found when `init` loads them.
pub const available = backend != null;

const Raw = if (backend) |be| gompute.RawByName(be) else void;
const Buffer = if (backend != null) Raw.Buffer else void;
const Stream = if (backend != null) Raw.Stream else void;
const block: u32 = device_ir.gpu_lane_block_size;

comptime {
    std.debug.assert(@sizeOf(lk.SimState) == @sizeOf(SimState));
    std.debug.assert(@offsetOf(lk.SimState, "iteration") == @offsetOf(SimState, "iteration"));
}

/// Whether this Problem batches transients as GPU lanes: an explicit
/// `cuda`/`hip` does unless `ESPICE_LANES=0`; `auto` only on a device whose
/// FP64 rate is at least a quarter of FP32 (datacenter parts report 2; the
/// RTX 4060 Laptop 64, where E1 measured the GPU at 1.4-2x the 24-core CPU,
/// so `auto` keeps the CPU there).
pub fn policy(config: anytype) bool {
    if (config.knobs.lanes) |on| if (!on) return false;
    return switch (config.backend) {
        .cpu => false,
        .cuda, .hip => available,
        .auto => available and fp64RatioAtMost(4),
    };
}

/// The device's FP64:FP32 ratio is at most `r`. Unknown (HIP, or no
/// driver) counts as false.
fn fp64RatioAtMost(r: u32) bool {
    if (comptime @import("builtin").cpu.arch.isWasm()) return false;
    var compute = gompute.runtime.dynamic.Compute.init(null) catch return false;
    defer compute.deinit();
    const ratio = compute.fp64Ratio() catch return false;
    return ratio <= r;
}

/// `arp_l<what>_<model>` for the batch whose eval kernel is
/// `arp_eval_<model>`, into `buf`; null when the name has another shape.
fn laneName(buf: []u8, eval_kernel: []const u8, what: []const u8) ?[:0]const u8 {
    const prefix = "arp_eval_";
    if (!std.mem.startsWith(u8, eval_kernel, prefix)) return null;
    return std.fmt.bufPrintSentinel(buf, "arp_l{s}_{s}", .{ what, eval_kernel[prefix.len..] }, 0) catch null;
}

/// Why `GpuLanes.init` refused before any driver error.
pub const Error = error{
    /// No kernel image for the lane kernels, or a batch without one.
    NoLaneImage,
    /// The lead lane holds no factored sparse LU to replay.
    NoLaneTape,
};

/// One device batch over every lane: its shared tapes, its deduplicated
/// Model rows, lane-major Instance/State/lim rows, and its lane kernels.
const LaneBatch = struct {
    eval: Raw,
    lim: ?Raw,
    ctl: ?Raw,
    /// `arp_lchg_<model>`: charges into the q plane and the tape.
    chg: ?Raw,
    count: u32,
    has_lim: bool,
    /// This batch's offset into the charge tape.
    tape_off: u32,
    inst_size: usize,
    d_models: Buffer,
    d_model_of: Buffer,
    d_instances: Buffer,
    d_states: Buffer,
    d_lim: Buffer,
    d_gath: Buffer,
    d_rhs_idx: Buffer,
    d_slots: Buffer,
    /// The batch's lim-active word: 1 between the predictor's limit pass
    /// and the end of Newton (`clearLimits`).
    d_limw: Buffer,

    fn deinit(self: *LaneBatch) void {
        inline for (.{ "d_models", "d_model_of", "d_instances", "d_states", "d_lim", "d_gath", "d_rhs_idx", "d_slots", "d_limw" }) |f| @field(self, f).free();
        if (self.lim) |*k| k.deinit();
        if (self.ctl) |*k| k.deinit();
        if (self.chg) |*k| k.deinit();
        self.eval.deinit();
    }
};

/// Lane-major rows of one batch over every lane.
const Packed = struct {
    models: []u8,
    model_of: []u32,
    instances: []u8,
    states: []u8,
    lim: []f64,

    fn deinit(p: Packed, gpa: std.mem.Allocator) void {
        gpa.free(p.models);
        gpa.free(p.model_of);
        gpa.free(p.instances);
        gpa.free(p.states);
        gpa.free(p.lim);
    }
};

/// Lane-major rows of batch b over every lane: Model rows deduplicated by
/// bytes (the "packed rows" of lane-batched-simulation.md §3.2),
/// model_of, instances, states and the lim plane. `ps[l]` is lane l's
/// `GpuPayload` for b; the map's keys borrow its frozen Model bytes.
fn pack(gpa: std.mem.Allocator, ps: []const device_ir.GpuPayload) !Packed {
    const p0 = ps[0];
    const n_lanes = ps.len;
    const count: usize = p0.count;
    var rows_n: u32 = 0;
    for (p0.model_of) |r| rows_n = @max(rows_n, r + 1);
    const ms = if (rows_n == 0) 0 else p0.models.len / rows_n;
    const is = if (count == 0) 0 else p0.instances.len / count;
    const ss = if (count == 0) 0 else p0.states.len / count;
    const kl = if (count == 0) 0 else p0.lim_x.len / count;
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    defer index.deinit(gpa);
    var models: std.ArrayList(u8) = .empty;
    errdefer models.deinit(gpa);
    const model_of = try gpa.alloc(u32, count * n_lanes);
    errdefer gpa.free(model_of);
    const inst = try gpa.alloc(u8, count * n_lanes * is);
    errdefer gpa.free(inst);
    const states = try gpa.alloc(u8, count * n_lanes * ss);
    errdefer gpa.free(states);
    const lim = try gpa.alloc(f64, count * kl * n_lanes);
    errdefer gpa.free(lim);
    for (ps, 0..) |p, l| {
        std.debug.assert(p.count == p0.count and std.mem.eql(u32, p.gath, p0.gath) and std.mem.eql(u32, p.slots, p0.slots));
        for (0..count) |id| {
            const row = p.models[@as(usize, p.model_of[id]) * ms ..][0..ms];
            const gop = try index.getOrPut(gpa, row);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(models.items.len / @max(ms, 1));
                try models.appendSlice(gpa, row);
            }
            model_of[id * n_lanes + l] = gop.value_ptr.*;
            @memcpy(inst[(id * n_lanes + l) * is ..][0..is], p.instances[id * is ..][0..is]);
            if (ss != 0) @memcpy(states[(id * n_lanes + l) * ss ..][0..ss], p.states[id * ss ..][0..ss]);
            for (0..kl) |a| lim[(id * kl + a) * n_lanes + l] = p.lim_x[id * kl + a];
        }
    }
    return .{ .models = try models.toOwnedSlice(gpa), .model_of = model_of, .instances = inst, .states = states, .lim = lim };
}

/// The model-independent lane kernels.
const Kernels = struct {
    refactor: Raw,
    solve: Raw,
    assemble: Raw,
    update: Raw,
    gates: Raw,
    finalize: Raw,
    tick: Raw,
    predict: Raw,
    lte: Raw,
    accept: Raw,
    rebase: Raw,
    gather: Raw,

    fn init() !Kernels {
        var k: Kernels = undefined;
        var done: usize = 0;
        errdefer inline for (@typeInfo(Kernels).@"struct".field_names, 0..) |f, i| {
            if (i < done) @field(k, f).deinit();
        };
        inline for (@typeInfo(Kernels).@"struct".field_names) |f| {
            @field(k, f) = gompute.rawKernelByName(backend.?, "arp_lane_" ++ f, 0) catch |e| return if (e == error.KernelNotFound) Error.NoLaneImage else e;
            done += 1;
        }
        return k;
    }

    fn deinit(k: *Kernels) void {
        inline for (@typeInfo(Kernels).@"struct".field_names) |f| @field(k, f).deinit();
    }
};

/// `ESPICE_GPU_STATS` wall time per round phase, printed at `deinit`.
pub const Prof = struct {
    on: bool = false,
    /// Nanoseconds: host step control, predict, Newton, probe, apply.
    ns: [5]u64 = @splat(0),
    rounds: u64 = 0,
    ticks: u64 = 0,
    peels: u64 = 0,
    last: u64 = 0,

    pub const Phase = enum(u3) { host, predict, newton, probe, apply };

    pub fn now() u64 {
        if (comptime @import("builtin").os.tag != .linux) return 0;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    /// Charges the time since the last lap to `p`.
    pub fn lap(self: *Prof, p: Phase) void {
        if (!self.on) return;
        const t = now();
        if (self.last != 0) self.ns[@intFromEnum(p)] += t - self.last;
        self.last = t;
    }
};

/// One lane's Newton outcome, as `converger.Result` and its singular flag.
pub const LaneNewton = struct { result: converger.Result, singular: bool, reject: bool };

/// Device state of N transient lanes.
pub const GpuLanes = struct {
    gpa: std.mem.Allocator,
    ckts: []const *Circuit,
    n_lanes: u32,
    n: u32,
    nnz: u32,
    n_hist: u32,
    n_qt: u32,
    n_probes: u32,
    has_charge: bool,
    /// Stateful charge (`Circuit.has_state_q`): every accepted step re-reads
    /// q at cur (`rebaseRound`).
    state_q: bool,
    d0: u32,
    batches: []LaneBatch,
    k: Kernels,
    stream: Stream,
    tab: lk.LaneTab,

    // Lane-major: n + 1 rows (x, cur, prev, rhs, q), nnz + 1 slots (g, c).
    d_x: Buffer,
    d_x_old: Buffer,
    d_dx: Buffer,
    d_cur: Buffer,
    d_prev: Buffer,
    d_g: Buffer,
    d_c: Buffer,
    d_rhs: Buffer,
    d_q: Buffer,
    d_a: Buffer,
    d_lx: Buffer,
    d_ux: Buffer,
    d_udiag: Buffer,
    d_w: Buffer,
    d_y: Buffer,
    d_ring: Buffer,
    d_ip: Buffer,
    // Lane-minor tape ring.
    d_ring_qt: Buffer,
    d_ip_qt: Buffer,
    // Per lane.
    d_sc: Buffer,
    d_sims: Buffer,
    d_active: Buffer,
    d_round: Buffer,
    d_stage: Buffer,
    d_gate: Buffer,
    d_flags: Buffer,
    d_fail: Buffer,
    d_ops: Buffer,
    d_accept: Buffer,
    d_slot0: Buffer,
    d_perm_q: Buffer,
    d_perm_qt: Buffer,
    d_lte_in: Buffer,
    d_lte_out: Buffer,
    d_probe_out: Buffer,
    // Tables.
    d_tab_idx: Buffer,
    d_cur_row: Buffer,
    d_diag: Buffer,
    d_probes: Buffer,
    // Device words.
    d_iter: Buffer,
    d_count: Buffer,
    d_fails: Buffer,

    // Host mirrors of what moves each round.
    sc: []lk.LaneScalars,
    sims: []SimState,
    lte_in: []lk.LteIn,
    lte_out: [][2]f64,
    gate: []lk.Gate,
    query: []u32,
    ops: []u8,
    accept_: []u8,
    round: []u8,
    perm_q: []u8,
    perm_qt: []u8,
    slot0: []u8,
    fail: []u8,
    probe_out: []f64,
    probes: []const u32,
    /// Lanes that left the device for a CPU rerun: `deinit` copies no
    /// state back into them.
    detached: []bool,
    /// Per lane, an n-long host vector whose probe rows hold the last
    /// probe's x (`Ops.accepted`).
    rows: []f64,
    prof: Prof = .{},

    const Self = @This();

    /// Uploads every lane after its `Sim.init`: the pattern's tapes, each
    /// batch's packed rows, x_op, the charge rings and histories. `sims[l]`
    /// is lane l's step machine (`tran.Sim`), read for its rings. Fails with
    /// `Error` or a driver or allocation error; the caller then runs the
    /// lanes on the CPU.
    pub fn init(gpa: std.mem.Allocator, ckts: []const *Circuit, sims: anytype, probes: []const u32) !*Self {
        if (comptime backend == null) return Error.NoLaneImage;
        const c0 = ckts[0];
        const n_lanes: u32 = @intCast(ckts.len);
        const N: usize = n_lanes;
        const n: usize = c0.n;
        const nnz: usize = c0.nnz;
        const s0 = sims[0];
        const n_hist: usize = s0.n_hist;
        const n_qt: usize = s0.n_qt;
        const n_probes: usize = probes.len;

        // The LU tape: lane 0's pivot order on its first step's matrix, G +
        // C/dt at x_op as `Sim.init` left the planes (G alone without charge).
        const lead = &c0.ws.?.slv;
        {
            const a0 = try gpa.alloc(f64, nnz);
            defer gpa.free(a0);
            if (c0.has_charge) c0.combineGC(1 / s0.dt, a0) else @memcpy(a0, c0.g_vals[0..nnz]);
            lead.factor(a0, c0.solver_execution) catch return Error.NoLaneTape;
        }
        const lu0 = lead.sparse() orelse return Error.NoLaneTape;
        if (!lu0.factored) return Error.NoLaneTape;
        const built = try lk.buildTab(gpa, lead.sparse().?, lead.col_ptr, lead.params.refactor_growth_limit, direct.pivot_tol);
        defer gpa.free(built.idx);
        const t = built.tab;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);
        var k = try Kernels.init();
        errdefer k.deinit();
        const k0 = &k.refactor;
        var stream = try k0.createStream();
        errdefer stream.deinit();

        // Per batch: each lane's payload, packed, uploaded.
        const n_b = c0.batches.len;
        const batches = try gpa.alloc(LaneBatch, n_b);
        errdefer gpa.free(batches);
        var n_up: usize = 0;
        errdefer for (batches[0..n_up]) |*b| b.deinit();
        const ps = try gpa.alloc(device_ir.GpuPayload, N);
        defer gpa.free(ps);
        var tape_off: u32 = 0;
        for (0..n_b) |bi| {
            const b0 = c0.batches[bi];
            for (ps, ckts) |*p, c| p.* = c.batches[bi].hooks.gpu_payload.?(c.batches[bi].ctx);
            const p0 = ps[0];
            var name: [160]u8 = undefined;
            const eval_name = laneName(&name, p0.kernel, "eval") orelse return Error.NoLaneImage;
            var eval = gompute.rawKernelByName(backend.?, eval_name, 0) catch |e| return if (e == error.KernelNotFound) Error.NoLaneImage else e;
            errdefer eval.deinit();
            var lim: ?Raw = null;
            errdefer if (lim) |*x| x.deinit();
            var ctl: ?Raw = null;
            errdefer if (ctl) |*x| x.deinit();
            var chg: ?Raw = null;
            errdefer if (chg) |*x| x.deinit();
            if (p0.lim_kernel.len > 0) lim = try gompute.rawKernelByName(backend.?, laneName(&name, p0.kernel, "lim").?, 0);
            if (p0.ctl_kernel.len > 0) ctl = try gompute.rawKernelByName(backend.?, laneName(&name, p0.kernel, "ctl").?, 0);
            const tape_len: u32 = if (b0.hooks.q_tape) |f| @intCast(f(b0.ctx).len) else 0;
            if (b0.has_charge) chg = try gompute.rawKernelByName(backend.?, laneName(&name, p0.kernel, "chg").?, 0);
            const pk = try pack(gpa, ps);
            defer pk.deinit(gpa);
            batches[bi] = .{
                .eval = eval,
                .lim = lim,
                .ctl = ctl,
                .chg = chg,
                .count = p0.count,
                .has_lim = p0.lim_x.len > 0,
                .tape_off = tape_off,
                .inst_size = if (p0.count == 0) 0 else p0.instances.len / p0.count,
                .d_models = try upload(k0, pk.models),
                .d_model_of = try upload(k0, std.mem.sliceAsBytes(pk.model_of)),
                .d_instances = try upload(k0, pk.instances),
                .d_states = try upload(k0, pk.states),
                .d_lim = try upload(k0, std.mem.sliceAsBytes(pk.lim)),
                .d_gath = try upload(k0, std.mem.sliceAsBytes(p0.gath)),
                .d_rhs_idx = try upload(k0, std.mem.sliceAsBytes(p0.rhs_idx)),
                .d_slots = try upload(k0, std.mem.sliceAsBytes(p0.slots)),
                .d_limw = try zeros(k0, 4),
            };
            tape_off += tape_len;
            n_up += 1;
        }
        std.debug.assert(tape_off == n_qt or n_qt == 0);

        self.* = .{
            .gpa = gpa,
            .ckts = ckts,
            .n_lanes = n_lanes,
            .n = @intCast(n),
            .nnz = @intCast(nnz),
            .n_hist = @intCast(n_hist),
            .n_qt = @intCast(n_qt),
            .n_probes = @intCast(n_probes),
            .has_charge = c0.has_charge,
            .state_q = c0.has_charge and c0.has_state_q,
            .d0 = c0.diag_slots[0],
            .batches = batches,
            .k = k,
            .stream = stream,
            .tab = t,
            .d_x = undefined,
            .d_x_old = undefined,
            .d_dx = undefined,
            .d_cur = undefined,
            .d_prev = undefined,
            .d_g = undefined,
            .d_c = undefined,
            .d_rhs = undefined,
            .d_q = undefined,
            .d_a = undefined,
            .d_lx = undefined,
            .d_ux = undefined,
            .d_udiag = undefined,
            .d_w = undefined,
            .d_y = undefined,
            .d_ring = undefined,
            .d_ip = undefined,
            .d_ring_qt = undefined,
            .d_ip_qt = undefined,
            .d_sc = undefined,
            .d_sims = undefined,
            .d_active = undefined,
            .d_round = undefined,
            .d_stage = undefined,
            .d_gate = undefined,
            .d_flags = undefined,
            .d_fail = undefined,
            .d_ops = undefined,
            .d_accept = undefined,
            .d_slot0 = undefined,
            .d_perm_q = undefined,
            .d_perm_qt = undefined,
            .d_lte_in = undefined,
            .d_lte_out = undefined,
            .d_probe_out = undefined,
            .d_tab_idx = undefined,
            .d_cur_row = undefined,
            .d_diag = undefined,
            .d_probes = undefined,
            .d_iter = undefined,
            .d_count = undefined,
            .d_fails = undefined,
            .sc = undefined,
            .sims = undefined,
            .lte_in = undefined,
            .lte_out = undefined,
            .gate = undefined,
            .query = undefined,
            .ops = undefined,
            .accept_ = undefined,
            .round = undefined,
            .perm_q = undefined,
            .perm_qt = undefined,
            .slot0 = undefined,
            .fail = undefined,
            .probe_out = undefined,
            .probes = probes,
            .detached = undefined,
            .rows = undefined,
        };
        // ponytail: every buffer below is freed by `deinit` only; a failure
        // part way through leaks the device buffers made so far until the
        // context goes down. Thread errdefers per buffer if that ever matters.
        const f8 = @sizeOf(f64);
        const rows_b = (n + 1) * N * f8;
        self.d_x = try zeros(k0, rows_b);
        self.d_x_old = try zeros(k0, rows_b);
        self.d_dx = try zeros(k0, rows_b);
        self.d_cur = try zeros(k0, rows_b);
        self.d_prev = try zeros(k0, rows_b);
        self.d_g = try zeros(k0, (nnz + 1) * N * f8);
        self.d_c = try zeros(k0, (nnz + 1) * N * f8);
        self.d_rhs = try zeros(k0, rows_b);
        self.d_q = try zeros(k0, rows_b);
        self.d_a = try zeros(k0, (nnz + 1) * N * f8);
        self.d_lx = try zeros(k0, @max(t.nnz_l, 1) * N * f8);
        self.d_ux = try zeros(k0, @max(t.nnz_u, 1) * N * f8);
        self.d_udiag = try zeros(k0, n * N * f8);
        self.d_w = try zeros(k0, n * N * f8);
        self.d_y = try zeros(k0, n * N * f8);
        self.d_ring = try zeros(k0, n_hist * n * N * f8);
        self.d_ip = try zeros(k0, n * N * f8);
        self.d_ring_qt = try zeros(k0, N * n_hist * n_qt * f8);
        self.d_ip_qt = try zeros(k0, N * n_qt * f8);
        self.d_sc = try zeros(k0, N * @sizeOf(lk.LaneScalars));
        self.d_sims = try zeros(k0, N * @sizeOf(SimState));
        self.d_active = try zeros(k0, N);
        self.d_round = try zeros(k0, N);
        self.d_stage = try zeros(k0, N);
        self.d_gate = try zeros(k0, N * @sizeOf(lk.Gate));
        self.d_flags = try zeros(k0, N * 4);
        self.d_fail = try zeros(k0, N);
        self.d_ops = try zeros(k0, N);
        self.d_accept = try zeros(k0, N);
        self.d_slot0 = try zeros(k0, N);
        self.d_perm_q = try zeros(k0, N * n_hist);
        self.d_perm_qt = try zeros(k0, N * n_hist);
        self.d_lte_in = try zeros(k0, N * @sizeOf(lk.LteIn));
        self.d_lte_out = try zeros(k0, N * 16);
        self.d_probe_out = try zeros(k0, N * n_probes * f8);
        self.d_tab_idx = try upload(k0, std.mem.sliceAsBytes(built.idx));
        self.d_iter = try zeros(k0, 4);
        self.d_count = try zeros(k0, 4);
        self.d_fails = try zeros(k0, 4);
        const cur_row = try gpa.alloc(u8, n);
        defer gpa.free(cur_row);
        for (cur_row, c0.current_row[0..n]) |*o, b| o.* = @intFromBool(b);
        self.d_cur_row = try upload(k0, cur_row);
        self.d_diag = try upload(k0, std.mem.sliceAsBytes(c0.diag_slots[0..n]));
        self.d_probes = try upload(k0, std.mem.sliceAsBytes(probes));

        self.sc = try gpa.alloc(lk.LaneScalars, N);
        self.sims = try gpa.alloc(SimState, N);
        self.lte_in = try gpa.alloc(lk.LteIn, N);
        self.lte_out = try gpa.alloc([2]f64, N);
        self.gate = try gpa.alloc(lk.Gate, N);
        self.query = try gpa.alloc(u32, N);
        self.ops = try gpa.alloc(u8, N);
        self.accept_ = try gpa.alloc(u8, N);
        self.round = try gpa.alloc(u8, N);
        self.perm_q = try gpa.alloc(u8, N * n_hist);
        self.perm_qt = try gpa.alloc(u8, N * n_hist);
        self.slot0 = try gpa.alloc(u8, N);
        self.fail = try gpa.alloc(u8, N);
        self.probe_out = try gpa.alloc(f64, @max(N * n_probes, 1));
        self.rows = try gpa.alloc(f64, N * n);
        self.detached = try gpa.alloc(bool, N);
        @memset(self.detached, false);
        @memset(self.sc, std.mem.zeroes(lk.LaneScalars));
        @memset(self.ops, 0);
        @memset(self.accept_, 0);
        @memset(self.round, 0);
        @memset(self.rows, 0);
        for (0..N) |l| for (0..n_hist) |s| {
            self.perm_q[l * n_hist + s] = @intCast(s);
            self.perm_qt[l * n_hist + s] = @intCast(s);
        };

        // Each lane's start, as its `Sim.init` left it: x_op in cur and
        // prev, the row ring (physical = logical), i_prev, the tape ring.
        const host = try gpa.alloc(f64, @max(n_hist * n * N, @max((n + 1) * N, N * n_hist * n_qt)));
        defer gpa.free(host);
        @memset(host[0 .. (n + 1) * N], 0);
        for (sims, 0..) |s, l| for (s.cur[0..n], 0..) |v, i| {
            host[i * N + l] = v;
        };
        try self.d_cur.upload(host.ptr, (n + 1) * N * f8);
        try self.d_prev.upload(host.ptr, (n + 1) * N * f8);
        if (self.has_charge) {
            for (sims, 0..) |s, l| for (0..n_hist) |slot| for (s.q_ring[slot][0..n], 0..) |v, i| {
                host[(slot * n + i) * N + l] = v;
            };
            try self.d_ring.upload(host.ptr, n_hist * n * N * f8);
            for (sims, 0..) |s, l| for (s.i_prev[0..n], 0..) |v, i| {
                host[i * N + l] = v;
            };
            try self.d_ip.upload(host.ptr, n * N * f8);
        }
        if (n_qt > 0) {
            for (sims, 0..) |s, l| for (0..n_hist) |slot| {
                @memcpy(host[(l * n_hist + slot) * n_qt ..][0..n_qt], s.qt_ring[slot][0..n_qt]);
            };
            try self.d_ring_qt.upload(host.ptr, N * n_hist * n_qt * f8);
            for (sims, 0..) |s, l| @memcpy(host[l * n_qt ..][0..n_qt], s.qt_i_prev[0..n_qt]);
            try self.d_ip_qt.upload(host.ptr, N * n_qt * f8);
        }
        try self.d_perm_q.upload(self.perm_q.ptr, N * n_hist);
        try self.d_perm_qt.upload(self.perm_qt.ptr, N * n_hist);
        return self;
    }

    /// Copies each lane's device Instance rows back into its host batch
    /// (the latches `refuseLatched` reads), then frees everything.
    pub fn deinit(self: *Self) void {
        if (comptime backend == null) return;
        const gpa = self.gpa;
        const N: usize = self.n_lanes;
        self.stream.synchronize() catch {};
        if (self.prof.on) {
            const p = self.prof;
            const ms = struct {
                fn f(ns: u64) f64 {
                    return @as(f64, @floatFromInt(ns)) / 1e6;
                }
            }.f;
            std.debug.print("gpu-lanes: {d} lanes, {d} rounds, {d} Newton ticks, {d} peels; ms host={d:.1} predict={d:.1} newton={d:.1} probe={d:.1} apply={d:.1}\n", .{ N, p.rounds, p.ticks, p.peels, ms(p.ns[0]), ms(p.ns[1]), ms(p.ns[2]), ms(p.ns[3]), ms(p.ns[4]) });
        }
        for (self.batches, 0..) |*b, bi| {
            const is = b.inst_size;
            if (b.count == 0 or is == 0) continue;
            const buf = gpa.alloc(u8, b.count * N * is) catch continue;
            defer gpa.free(buf);
            b.d_instances.download(buf.ptr, buf.len) catch continue;
            for (self.ckts, 0..) |c, l| {
                if (self.detached[l]) continue;
                const hb = c.batches[bi];
                const dst = @constCast(hb.hooks.gpu_payload.?(hb.ctx).instances);
                for (0..b.count) |id| @memcpy(dst[id * is ..][0..is], buf[(id * N + l) * is ..][0..is]);
            }
        }
        for (self.batches) |*b| b.deinit();
        gpa.free(self.batches);
        inline for (@typeInfo(Self).@"struct".field_names) |f| {
            if (comptime std.mem.startsWith(u8, f, "d_")) @field(self, f).free();
        }
        inline for (.{ "sc", "sims", "lte_in", "lte_out", "gate", "query", "ops", "accept_", "round", "perm_q", "perm_qt", "slot0", "fail", "probe_out", "rows", "detached" }) |f| gpa.free(@field(self, f));
        self.stream.deinit();
        self.k.deinit();
        gpa.destroy(self);
    }

    fn upload(k: *Raw, bytes: []const u8) !Buffer {
        var buf = try k.alloc(@max(bytes.len, 1));
        errdefer buf.free();
        if (bytes.len > 0) try buf.upload(bytes.ptr, bytes.len);
        return buf;
    }

    fn zeros(k: *Raw, bytes: usize) !Buffer {
        var buf = try k.alloc(@max(bytes, 1));
        errdefer buf.free();
        const z = try std.heap.page_allocator.alloc(u8, @max(bytes, 1));
        defer std.heap.page_allocator.free(z);
        @memset(z, 0);
        try buf.upload(z.ptr, z.len);
        return buf;
    }

    fn arg(p: anytype) gompute.interface.Arg {
        return gompute.interface.arg(p);
    }

    /// Launches `k` over `threads` threads at the lane block width.
    fn launch(self: *Self, k: *Raw, threads: usize, args: []const gompute.interface.Arg) !void {
        if (threads == 0) return;
        try k.launchOn(&self.stream, gompute.Dim3.linear(@intCast(threads), block), .{ .x = block }, 0, args);
    }

    /// The backend `tran.Sim` drives lane l with.
    pub fn laneOps(self: *Self, l: usize) Ops {
        return .{ .g = self, .l = @intCast(l) };
    }

    /// Starts a round: uploads the round lanes' scalars (`Ops.attempt`
    /// filled them), predicts each lane's first iterate and runs its
    /// predictor limit pass against cur. `round` marks the lanes in it.
    pub fn predictRound(self: *Self) !void {
        const N: usize = self.n_lanes;
        try self.d_sc.upload(self.sc.ptr, N * @sizeOf(lk.LaneScalars));
        try self.d_sims.upload(self.sims.ptr, N * @sizeOf(SimState));
        try self.d_lte_in.upload(self.lte_in.ptr, N * @sizeOf(lk.LteIn));
        try self.d_round.upload(self.round.ptr, N);
        var nl: u64 = N;
        var n: u64 = self.n;
        try self.launch(&self.k.predict, self.n * N, &.{ arg(&nl), arg(&n), self.d_sc.argPtr(), self.d_cur.argPtr(), self.d_prev.argPtr(), self.d_x.argPtr(), self.d_x_old.argPtr() });
        try self.limitPass(&self.d_round, &self.d_x, &self.d_x_old, device_ir.lim_pass_limit);
        // `applyLimits` leaves each limiting batch's lim plane live.
        const one: u32 = 1;
        for (self.batches) |*b| if (b.lim != null and b.has_lim) try b.d_limw.upload(&one, 4);
    }

    /// The limit or state half of every batch's lane state kernel over the
    /// lanes of `mask`, at `x` against `x_old`.
    fn limitPass(self: *Self, mask: *Buffer, x: *Buffer, x_old: *Buffer, halves_: u64) !void {
        const N: usize = self.n_lanes;
        for (self.batches) |*b| {
            const k = if (b.lim) |*k| k else continue;
            if (b.count == 0) continue;
            if (halves_ == device_ir.lim_pass_limit and !b.has_lim) continue;
            var nl: u64 = N;
            var count: u64 = b.count;
            var halves = halves_;
            try self.launch(k, b.count * N, &.{
                arg(&nl),             arg(&count),           mask.argPtr(),           x.argPtr(),        x_old.argPtr(),
                b.d_gath.argPtr(),    b.d_models.argPtr(),   b.d_model_of.argPtr(),   b.d_instances.argPtr(), b.d_lim.argPtr(),
                b.d_states.argPtr(),  b.d_limw.argPtr(),     arg(&halves),            self.d_flags.argPtr(),  self.d_sims.argPtr(),
            });
        }
    }

    /// Zeroes the planes, then every batch's lane eval at `x` for the lanes
    /// of `mask`.
    fn evalAll(self: *Self, mask: *Buffer, x: *Buffer) !void {
        const N: usize = self.n_lanes;
        const f8 = @sizeOf(f64);
        try self.d_g.fillAsync(0, (self.nnz + 1) * N * f8, &self.stream);
        try self.d_c.fillAsync(0, (self.nnz + 1) * N * f8, &self.stream);
        try self.d_rhs.fillAsync(0, (self.n + 1) * N * f8, &self.stream);
        try self.d_q.fillAsync(0, (self.n + 1) * N * f8, &self.stream);
        for (self.batches) |*b| {
            if (b.count == 0) continue;
            var nl: u64 = N;
            var count: u64 = b.count;
            try self.launch(&b.eval, N, &.{
                arg(&nl),               arg(&count),            self.d_sims.argPtr(),  mask.argPtr(),          b.d_limw.argPtr(),
                x.argPtr(),             b.d_gath.argPtr(),      b.d_rhs_idx.argPtr(),  b.d_slots.argPtr(),     b.d_models.argPtr(),
                b.d_model_of.argPtr(),  b.d_instances.argPtr(), self.d_g.argPtr(),     self.d_c.argPtr(),      self.d_rhs.argPtr(),
                self.d_q.argPtr(),      b.d_lim.argPtr(),
            });
        }
    }

    /// Newton for the round lanes, every lane its own `converger.newton`
    /// at its own t (`sims`), with `opts` (lane-uniform). Fills `out[l]`
    /// for the round lanes. `clearLimits` at the end.
    pub fn newton(self: *Self, opts: converger.Options, out: []LaneNewton) !void {
        std.debug.assert(!(opts.gmin > 0) and opts.force.len == 0 and opts.residual_tol == std.math.inf(f64) and !opts.init_fix);
        const N: usize = self.n_lanes;
        const n: usize = self.n;
        for (self.gate, self.round, self.sims) |*g, r, *s| {
            g.* = .{ .limit = 0, .scaled = 0, .iterations = opts.max_iter, .bits = r };
            // `beginSolve`.
            s.iteration = 1;
        }
        try self.d_gate.upload(self.gate.ptr, N * @sizeOf(lk.Gate));
        try self.d_sims.upload(self.sims.ptr, N * @sizeOf(SimState));
        try self.d_active.upload(self.round.ptr, N);
        try self.d_iter.fillAsync(0, 4, &self.stream);
        @memset(self.fail, 0);
        try self.d_fail.upload(self.fail.ptr, N);
        var nl: u64 = N;
        var nn: u64 = n;
        var nnz: u64 = self.nnz;
        var d0: u64 = self.d0;
        var charge: u64 = @intFromBool(self.has_charge);
        var nh: u64 = self.n_hist;
        var tab = self.tab;
        var nopts: lk.NewtonOpts = .{ .reltol = opts.reltol, .abstol = opts.abstol, .vntol = opts.vntol };
        var iter: u16 = 0;
        while (iter < opts.max_iter) : (iter += 1) {
            try self.evalAll(&self.d_active, &self.d_x);
            try self.launch(&self.k.assemble, (n + self.nnz) * N, &.{
                arg(&nl),               arg(&nn),             arg(&nnz),             arg(&d0),             arg(&charge),
                self.d_sc.argPtr(),     self.d_active.argPtr(), self.d_x.argPtr(),   self.d_rhs.argPtr(),  self.d_q.argPtr(),
                self.d_ring.argPtr(),   self.d_perm_q.argPtr(), arg(&nh),            self.d_ip.argPtr(),   self.d_g.argPtr(),
                self.d_c.argPtr(),      self.d_a.argPtr(),
            });
            try self.d_fails.fillAsync(0, 4, &self.stream);
            try self.launch(&self.k.refactor, N, &.{
                arg(&nl),               arg(&tab),             self.d_tab_idx.argPtr(), self.d_active.argPtr(), self.d_a.argPtr(),
                self.d_lx.argPtr(),     self.d_ux.argPtr(),    self.d_udiag.argPtr(),   self.d_w.argPtr(),      self.d_fail.argPtr(),
                self.d_fails.argPtr(),
            });
            try self.launch(&self.k.solve, N, &.{
                arg(&nl),               arg(&tab),             self.d_tab_idx.argPtr(), self.d_active.argPtr(), self.d_fail.argPtr(),
                self.d_lx.argPtr(),     self.d_ux.argPtr(),    self.d_udiag.argPtr(),   self.d_rhs.argPtr(),    self.d_y.argPtr(),
                self.d_dx.argPtr(),
            });
            var fails: u32 = 0;
            try self.d_fails.downloadAtAsync(&fails, 0, 4, &self.stream);
            try self.stream.synchronize();
            if (fails > 0) {
                self.prof.peels += fails;
                try self.peel();
            }

            try self.launch(&self.k.update, N, &.{
                arg(&nl),               arg(&nn),              arg(&nopts),            self.d_iter.argPtr(),   self.d_active.argPtr(),
                self.d_gate.argPtr(),   self.d_x.argPtr(),     self.d_dx.argPtr(),     self.d_x_old.argPtr(),  self.d_cur_row.argPtr(),
                self.d_rhs.argPtr(),    self.d_a.argPtr(),     self.d_diag.argPtr(),   self.d_flags.argPtr(),
            });
            try self.limitPass(&self.d_active, &self.d_x, &self.d_x_old, device_ir.lim_pass_limit);
            try self.launch(&self.k.gates, N, &.{
                arg(&nl),               arg(&nn),              self.d_iter.argPtr(),   self.d_active.argPtr(), self.d_gate.argPtr(),
                self.d_x.argPtr(),      self.d_rhs.argPtr(),   self.d_flags.argPtr(),  self.d_stage.argPtr(),
            });
            try self.limitPass(&self.d_stage, &self.d_x_old, &self.d_x_old, device_ir.lim_pass_state);
            try self.d_count.fillAsync(0, 4, &self.stream);
            try self.launch(&self.k.finalize, N, &.{
                arg(&nl),               arg(&nn),              self.d_iter.argPtr(),   self.d_active.argPtr(), self.d_stage.argPtr(),
                self.d_gate.argPtr(),   self.d_flags.argPtr(), self.d_fail.argPtr(),   self.d_x.argPtr(),      self.d_x_old.argPtr(),
                self.d_sims.argPtr(),   self.d_count.argPtr(),
            });
            try self.launch(&self.k.tick, 1, &.{self.d_iter.argPtr()});
            self.prof.ticks += 1;
            var count: u32 = 0;
            try self.d_count.downloadAtAsync(&count, 0, 4, &self.stream);
            try self.stream.synchronize();
            if (count == 0) break;
        }
        // `clearLimits`.
        for (self.batches) |*b| try b.d_limw.fillAsync(0, 4, &self.stream);
        try self.d_gate.download(self.gate.ptr, N * @sizeOf(lk.Gate));
        for (self.gate, self.round, out) |g, r, *o| {
            if (r == 0) continue;
            const singular = g.bits & 8 != 0;
            o.* = .{
                .result = if (singular) .{ .converged = false, .iterations = 0 } else .{ .converged = g.bits & 4 != 0, .iterations = @intCast(@min(g.iterations, opts.max_iter)) },
                .singular = singular,
                .reject = g.bits & 32 != 0,
            };
        }
    }

    /// The lanes whose device refactor failed this tick: each factors and
    /// solves on its own solver from its downloaded A and rhs, as
    /// `LaneSolver` peels; a singular one stays failed (`finalize` marks it).
    fn peel(self: *Self) !void {
        const gpa = self.gpa;
        const N: usize = self.n_lanes;
        const n: usize = self.n;
        const nnz: usize = self.nnz;
        try self.d_fail.download(self.fail.ptr, N);
        const a = try gpa.alloc(f64, (nnz + 1) * N);
        defer gpa.free(a);
        const rhs = try gpa.alloc(f64, (n + 1) * N);
        defer gpa.free(rhs);
        const dx = try gpa.alloc(f64, (n + 1) * N);
        defer gpa.free(dx);
        const al = try gpa.alloc(f64, nnz + 2 * n);
        defer gpa.free(al);
        try self.d_a.download(a.ptr, a.len * @sizeOf(f64));
        try self.d_rhs.download(rhs.ptr, rhs.len * @sizeOf(f64));
        try self.d_dx.download(dx.ptr, dx.len * @sizeOf(f64));
        const v_l = al[0..nnz];
        const r_l = al[nnz..][0..n];
        const x_l = al[nnz + n ..][0..n];
        for (self.fail, 0..) |*f, l| {
            if (f.* == 0) continue;
            const slv = &self.ckts[l].ws.?.slv;
            for (v_l, 0..) |*o, p| o.* = a[p * N + l];
            slv.factor(v_l, self.ckts[l].solver_execution) catch |e| switch (e) {
                error.SingularMatrix => continue,
                else => |other| return other,
            };
            for (r_l, 0..) |*o, i| o.* = rhs[i * N + l];
            slv.solveNeg(r_l, x_l);
            for (x_l, 0..) |v, i| dx[i * N + l] = v;
            f.* = 0;
        }
        try self.d_dx.upload(dx.ptr, dx.len * @sizeOf(f64));
        try self.d_fail.upload(self.fail.ptr, N);
    }

    /// The step-end numbers of the round lanes at their Newton solution:
    /// the state-flip query, the charges and their tape at x, the LTE
    /// bounds and the probe rows. One sync.
    pub fn probe(self: *Self) !void {
        const N: usize = self.n_lanes;
        // 1. The flip query, read-only.
        for (self.ops, self.round) |*o, r| o.* = if (r != 0) 1 + @as(u8, @backingInt(StateCtlOp.query)) else 0;
        try self.d_ops.upload(self.ops.ptr, N);
        try self.d_flags.fillAsync(0, N * 4, &self.stream);
        try self.ctlPass();
        @memset(self.ops, 0);
        // 2. The charges at x (`Sim.end`'s `evalQ`), and the tape into each
        // lane's logical slot 0.
        if (self.has_charge) {
            const nh: usize = self.n_hist;
            for (self.slot0, 0..) |*s, l| s.* = self.perm_qt[l * nh];
            try self.chargePass(&self.d_round, &self.d_x);
        }
        if (self.n_qt > 0) {
            // 3. The LTE bounds.
            var nl: u64 = N;
            var n_hist: u64 = self.n_hist;
            var n_qt: u64 = self.n_qt;
            try self.launch(&self.k.lte, N, &.{
                arg(&nl), self.d_sc.argPtr(), self.d_ring_qt.argPtr(), self.d_perm_qt.argPtr(), self.d_ip_qt.argPtr(), arg(&n_hist), arg(&n_qt), self.d_lte_in.argPtr(), self.d_lte_out.argPtr(),
            });
            try self.d_lte_out.downloadAtAsync(self.lte_out.ptr, 0, N * 16, &self.stream);
        }
        // 4. The probe rows.
        if (self.n_probes > 0) {
            var nl: u64 = N;
            var np: u64 = self.n_probes;
            try self.launch(&self.k.gather, self.n_probes * N, &.{ arg(&nl), self.d_sc.argPtr(), self.d_x.argPtr(), self.d_probes.argPtr(), arg(&np), self.d_probe_out.argPtr() });
            try self.d_probe_out.downloadAtAsync(self.probe_out.ptr, 0, N * self.n_probes * @sizeOf(f64), &self.stream);
        }
        try self.d_flags.downloadAtAsync(self.query.ptr, 0, N * 4, &self.stream);
        try self.stream.synchronize();
        const n: usize = self.n;
        for (self.round, 0..) |r, l| {
            if (r == 0) continue;
            const row = self.rows[l * n ..][0..n];
            for (self.probes, 0..) |p, k| row[p] = self.probe_out[l * self.n_probes + k];
        }
    }

    /// Every batch's lane ctl kernel with the per-lane `ops` on the device.
    fn ctlPass(self: *Self) !void {
        const N: usize = self.n_lanes;
        for (self.batches) |*b| {
            const k = if (b.ctl) |*k| k else continue;
            if (b.count == 0) continue;
            var nl: u64 = N;
            var count: u64 = b.count;
            try self.launch(k, b.count * N, &.{ arg(&nl), arg(&count), self.d_ops.argPtr(), b.d_models.argPtr(), b.d_model_of.argPtr(), b.d_instances.argPtr(), b.d_states.argPtr(), self.d_flags.argPtr() });
        }
    }

    /// Runs the round's decisions (`Ops`) on the device: revert or commit
    /// per lane, then each accepted lane's history update. Clears them.
    pub fn apply(self: *Self) !void {
        const N: usize = self.n_lanes;
        try self.d_ops.upload(self.ops.ptr, N);
        try self.d_flags.fillAsync(0, N * 4, &self.stream);
        try self.ctlPass();
        try self.d_sc.upload(self.sc.ptr, N * @sizeOf(lk.LaneScalars));
        try self.d_accept.upload(self.accept_.ptr, N);
        var nl: u64 = N;
        var n: u64 = self.n;
        var n_qt: u64 = self.n_qt;
        var nh: u64 = self.n_hist;
        var charge: u64 = @intFromBool(self.has_charge);
        try self.launch(&self.k.accept, (self.n + self.n_qt) * N, &.{
            arg(&nl),               arg(&n),               arg(&n_qt),             arg(&nh),               arg(&charge),
            self.d_sc.argPtr(),     self.d_accept.argPtr(), self.d_x.argPtr(),     self.d_cur.argPtr(),    self.d_prev.argPtr(),
            self.d_q.argPtr(),      self.d_ring.argPtr(),  self.d_ip.argPtr(),     self.d_ring_qt.argPtr(), self.d_ip_qt.argPtr(),
        });
        if (self.state_q) try self.rebaseRound();
        try self.d_perm_q.upload(self.perm_q.ptr, N * self.n_hist);
        try self.d_perm_qt.upload(self.perm_qt.ptr, N * self.n_hist);
        try self.stream.synchronize();
        @memset(self.ops, 0);
        @memset(self.accept_, 0);
    }

    /// `Sim.end`'s stateful-charge block for the accepted lanes, after the
    /// commits: the planes at cur, the tape into the tape's logical slot 0
    /// (`sqt[3]`), then `arp_lane_rebase`.
    fn rebaseRound(self: *Self) !void {
        const N: usize = self.n_lanes;
        for (self.slot0, self.sc) |*s, sc| s.* = sc.sqt[3];
        try self.chargePass(&self.d_accept, &self.d_cur);
        var nl: u64 = N;
        var n: u64 = self.n;
        var n_qt: u64 = self.n_qt;
        var nh: u64 = self.n_hist;
        try self.launch(&self.k.rebase, (self.n + self.n_qt) * N, &.{
            arg(&nl),             arg(&n),                arg(&n_qt),            arg(&nh),             self.d_sc.argPtr(),
            self.d_accept.argPtr(), self.d_q.argPtr(),    self.d_ring.argPtr(),  self.d_ip.argPtr(),   self.d_ring_qt.argPtr(),
            self.d_ip_qt.argPtr(),
        });
    }

    /// `Circuit.evalQ` at `x` for the lanes of `mask`: the q plane zeroed,
    /// then every charged batch's lane charge kernel, which also writes the
    /// tape into each lane's slot `slot0[l]` (uploaded here).
    fn chargePass(self: *Self, mask: *Buffer, x: *Buffer) !void {
        const N: usize = self.n_lanes;
        try self.d_slot0.upload(self.slot0.ptr, N);
        try self.d_q.fillAsync(0, (self.n + 1) * N * @sizeOf(f64), &self.stream);
        for (self.batches) |*b| {
            const k = if (b.chg) |*k| k else continue;
            if (b.count == 0) continue;
            var nl: u64 = N;
            var count: u64 = b.count;
            var n_hist: u64 = self.n_hist;
            var n_qt: u64 = self.n_qt;
            var off: u64 = b.tape_off;
            try self.launch(k, N, &.{
                arg(&nl),               arg(&count),           mask.argPtr(),           self.d_sims.argPtr(),   x.argPtr(),
                b.d_gath.argPtr(),      b.d_rhs_idx.argPtr(),  b.d_models.argPtr(),     b.d_model_of.argPtr(),  b.d_instances.argPtr(),
                self.d_q.argPtr(),      self.d_ring_qt.argPtr(), self.d_slot0.argPtr(), arg(&n_hist),           arg(&n_qt),
                arg(&off),
            });
        }
    }

    /// Records lane l's pre-rotation ring slots for `accept`'s history
    /// update (an accepted step with charge) and rotates
    /// its permutations as `std.mem.rotate` moves the host rings.
    fn queueAccept(self: *Self, l: usize) void {
        const nh: usize = self.n_hist;
        const pq = self.perm_q[l * nh ..][0..nh];
        const pqt = self.perm_qt[l * nh ..][0..nh];
        for (0..3) |k| {
            self.sc[l].sq[k] = pq[k];
            self.sc[l].sqt[k] = pqt[k];
        }
        std.mem.rotate(u8, pq, nh - 1);
        std.mem.rotate(u8, pqt, nh - 1);
    }
};

/// `tran.Sim`'s numerics backend for lane l of a `GpuLanes` round (the
/// phase 4 G1 surface): the device did the numerics for every lane at once
/// (`GpuLanes.probe`); this answers `Sim.end`'s calls from those numbers
/// and queues lane l's mutations for `GpuLanes.apply`.
pub const Ops = struct {
    g: *GpuLanes,
    l: u32,

    fn methodCode(m: anytype) u32 {
        return switch (m) {
            .backward_euler => 0,
            .trapezoidal => 1,
            .gear_2 => 2,
            else => unreachable, // gear-3..6 are not lane-eligible
        };
    }

    pub fn attempt(o: Ops, s: anytype, a: anytype) void {
        const g = o.g;
        const promote = methodCode(s.promoteMethod());
        g.sc[o.l] = .{
            .t_dev = a.t_dev,
            .dt = s.dt,
            .xfact = s.dt / s.dt_old[0],
            .ag0 = a.c.ag0,
            .ag1 = a.c.ag1,
            .ag2 = a.c.ag2,
            .method = methodCode(a.method),
            .flags = 1 | (promote << 4),
            .sq = @splat(0),
            .sqt = @splat(0),
        };
        g.sims[o.l] = s.ckt.sim;
        g.lte_in[o.l] = .{ .dt = s.dt, .dt1 = s.dt_old[0], .dt2 = s.dt_old[1], .reltol = s.options.tol.reltol, .abstol = s.options.tol.abstol, .chgtol = s.options.tol.chgtol, .trtol = s.options.tol.trtol, .ag0 = a.c.ag0, .ag1 = a.c.ag1, .ag2 = a.c.ag2 };
        g.round[o.l] = 1;
    }
    pub fn revert(o: Ops, _: anytype) void {
        o.g.ops[o.l] = 1 + @as(u8, @backingInt(StateCtlOp.revert));
    }
    pub fn rejectAt(_: Ops, _: anytype) ?f64 {
        return null; // a reject request fails the lane instead (`tran.runGpuLanes`)
    }
    pub fn flipped(o: Ops, _: anytype, _: anytype, ask: bool) bool {
        return ask and o.g.query[o.l] & 1 != 0;
    }
    pub fn boundStep(_: Ops, _: anytype) ?f64 {
        return null; // a finite one hands the lane back (`LaneNewton.reject`)
    }
    pub fn charges(_: Ops, _: anytype, _: anytype) void {} // `probe` did it for the round
    pub fn bound(o: Ops, _: anytype, a: anytype, method: anytype, _: anytype) f64 {
        const out = o.g.lte_out[o.l];
        // `end` asks for the step's own method, or the order-2 promotion
        // probe (the only other order <= 2 call).
        return if (method == a.method) out[0] else out[1];
    }
    pub fn boundGear(_: Ops, _: anytype, _: anytype, _: anytype, _: anytype) f64 {
        unreachable; // gear-3..6 are not lane-eligible
    }
    pub fn advance(o: Ops, _: anytype, _: anytype) void {
        o.g.queueAccept(o.l);
    }
    /// Every accepted step: the commit, and `accept`'s `prev <- cur <- x`.
    pub fn commit(o: Ops, _: anytype) void {
        o.g.ops[o.l] = 1 + @as(u8, @backingInt(StateCtlOp.commit));
        o.g.accept_[o.l] = 1;
    }
    /// Records the tape's logical slot 0 for `rebaseRound` and swaps the
    /// tape's slots 0 and 1, as `std.mem.swap` moves the host ring.
    pub fn rebase(o: Ops, s: anytype, _: anytype) void {
        if (!(s.has_charge and s.ckt.has_state_q)) return;
        const nh: usize = o.g.n_hist;
        const p = o.g.perm_qt[@as(usize, o.l) * nh ..][0..2];
        o.g.sc[o.l].sqt[3] = p[0];
        std.mem.swap(u8, &p[0], &p[1]);
    }
    pub fn accepted(o: Ops, _: anytype) []const f64 {
        const n: usize = o.g.n;
        return o.g.rows[@as(usize, o.l) * n ..][0..n];
    }
};
