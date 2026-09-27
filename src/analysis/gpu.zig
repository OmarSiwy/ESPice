//! GPU device evaluation feeding the host solver. Every eligible batch's
//! models, instances and tapes are uploaded once and stay resident; per Newton
//! iteration the bus carries `x` up and one contiguous block of value planes
//! down, and the sparse LU, Newton update and convergence test stay on the
//! CPU. That round trip is the floor, so the GPU pays off on device work, not
//! circuit size; `init` prices both sides before `auto` commits.

const std = @import("std");
const analysis = @import("types.zig");
const device_ir = @import("device").abi;
const gompute = @import("gompute");

const Circuit = analysis.Circuit;
const GpuHook = analysis.GpuHook;
const Planes = device_ir.Planes;

/// The backend this binary carries kernel images for. Comptime, because
/// naming `gompute.RawByName(.cuda)` is a compile error in a build without
/// CUDA artifacts.
const artifacts = @import("gompute_kernels");
const backend: ?gompute.Backend = if (artifacts.has_cuda)
    .cuda
else if (artifacts.has_hip)
    .hip
else
    null;

/// What `--backend` can ask for. `auto` may decline for any reason and fall
/// back to the CPU; `cuda`/`hip` are explicit and either run there or fail
/// saying why (see `Decline`).
pub const Request = enum { cpu, auto, cuda, hip };

/// Why `init` refused, in the three kinds a caller acts on differently.
pub const Decline = enum {
    /// A performance estimate (the CPU is faster). An explicit request
    /// overrides it, so only `auto` sees one.
    policy,
    /// Nothing in this circuit has a kernel image. A reported CPU fallback,
    /// whatever the flags.
    capability,
    /// The driver, hardware or build said no (including a build with no
    /// images). An explicit request fails naming what was detected.
    machine,
};

/// Classifies an `init` error.
pub fn declineKind(e: anyerror) Decline {
    return switch (e) {
        Error.NotEnoughGpuWork => .policy,
        Error.CircuitNotEligible => .capability,
        else => .machine,
    };
}

/// Returns "cuda", "hip" or "none": the backend this binary carries.
pub fn detectedName() []const u8 {
    return if (backend) |be| @tagName(be) else "none";
}

/// False for an explicit `cuda`/`hip` this binary cannot serve, so the
/// request fails before any simulation runs. `auto` and `cpu` always pass.
pub fn requestSupported(req: Request) bool {
    return switch (req) {
        .cpu, .auto => true,
        .cuda => backend == .cuda,
        .hip => backend == .hip,
    };
}

/// `void` in a build with no device images; every use sits behind
/// `comptime backend != null`.
const Raw = if (backend) |be| gompute.RawByName(be) else void;
const Buffer = if (backend != null) Raw.Buffer else void;
const Stream = if (backend != null) Raw.Stream else void;

/// The block width the kernels were exported with. HIP bakes it into
/// `globalIdX`; NVPTX reads the launch's real width, so CUDA may launch
/// narrower blocks (`evalBlock`).
const block_size: u32 = device_ir.gpu_block_size;

pub const Error = error{
    /// The build machine had no GPU, so no kernel images were emitted.
    NoGpuArtifacts,
    /// No device in this circuit has a kernel image (see `eval.gpuEligible`).
    CircuitNotEligible,
    /// The cost model priced the CPU faster.
    NotEnoughGpuWork,
};

/// The price of the device path, measured on an RTX 4060 Laptop (sm_89,
/// PCIe 4.0 x8) against an i9-14900HX; see `Cost`.
///
/// Per eval: launches and the one host wait, with the limit pass sharing it
/// (mos1_2000 phases: 10 us upload and clear, 42 us kernels, 40 us reduce,
/// 19 us download, and ~40 us of launch and wait around them).
const cost_fixed_us: f64 = 40;
/// Pinned-memory transfer rate, bytes per microsecond (~11 GB/s).
const cost_bus_b_per_us: f64 = 11_000;
/// Staging clear and the two reduce levels, bytes of staging per
/// microsecond (mos1_2000: 4.8 MB in 50 us).
const cost_stage_b_per_us: f64 = 100_000;
/// Device-kernel time as a fraction of one host thread's eval of the same
/// batches, 2000 inverters: mos1 42 us against ~450 us, bsim4va ~700 us
/// against ~7.3 ms.
const cost_kernel_ratio: f64 = 0.12;
/// One-time driver setup (cuInit, the context, module loads) in the first
/// query of a process; later queries reuse it.
const cost_init_us: f64 = 350_000;
/// Host lanes ParEval is worth per thread past the first. Measured on 8
/// threads against 1: bsim4_2000 3.3x, psp103_2000 1.8x, bsim3_2000 and the
/// mos1 decks 1x or slower. 0.1 (1.7x on 8) keeps the heavy models, where
/// the GPU's lead is large, and does not credit the light ones with lanes
/// they do not get.
const cost_lane_gain: f64 = 0.1;
/// The GPU must beat the CPU by this factor: wall time on a shared machine
/// wanders by more than the model's error.
const cost_margin: f64 = 1.3;

/// A context came up in this process, so the driver setup is paid. Queries
/// on other threads may race on it; a stale read only overprices one query.
var driver_up = false;

/// `ESPICE_GPU_STATS`: print the cost model's inputs and the residency split,
/// and the wall-time split at teardown.
fn statsOn() bool {
    return std.c.getenv("ESPICE_GPU_STATS") != null;
}

/// Names a batch that has a GPU payload but stays on the host, where it is
/// correct but slower.
fn reportDemote(on: bool, model: []const u8, why: []const u8, count: u32) void {
    if (!on) return;
    std.debug.print("note: GPU batch '{s}' ({d} instances) stays on the CPU: {s}\n", .{ model, count, why });
}

/// Monotonic nanoseconds, for the cost probe and `Prof`.
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// `ESPICE_GPU_STATS` wall-time split of the device path, printed at deinit.
const Prof = struct {
    on: bool = false,
    last: u64 = 0,
    evals: u64 = 0,
    /// Evals served by a prefetch, with no wait of their own.
    fused: u64 = 0,
    /// Host time to enqueue an eval, the wait for the device, and the host
    /// batches stamped after it.
    enqueue: u64 = 0,
    wait: u64 = 0,
    host: u64 = 0,
    lims: u64 = 0,
    lim: u64 = 0,
    /// `ESPICE_GPU_STATS=phases`: a sync after each eval stage, so the
    /// stage times below add up to the device time (upload+clear, eval
    /// kernels, reduce, download). Serializes the pipeline; diagnosis only.
    phases: bool = false,
    phase: [5]u64 = @splat(0),
    /// Host waits on the stream, all causes.
    syncs: u64 = 0,

    fn start(self: *Prof) void {
        if (self.on) self.last = nowNs();
    }

    /// Adds the time since the previous lap to `field`.
    fn lap(self: *Prof, comptime field: []const u8) void {
        if (!self.on) return;
        const t = nowNs();
        @field(self, field) += t - self.last;
        self.last = t;
    }

    fn print(self: Prof) void {
        if (!self.on) return;
        const us = struct {
            fn f(ns: u64, n: u64) f64 {
                return if (n == 0) 0 else @as(f64, @floatFromInt(ns)) * 1e-3 / @as(f64, @floatFromInt(n));
            }
        }.f;
        std.debug.print(
            "gpu-prof: syncs={d} evals={d} fused={d} per eval us: enqueue={d:.1} wait={d:.1} host={d:.1}; limits={d} {d:.1} us each\n",
            .{ self.syncs, self.evals, self.fused, us(self.enqueue, self.evals), us(self.wait, self.evals), us(self.host, self.evals), self.lims, us(self.lim, self.lims) },
        );
        if (self.phases) std.debug.print(
            "gpu-prof: phases per eval us: upload+clear={d:.1} eval={d:.1} reduce1={d:.1} reduce2={d:.1} download={d:.1}\n",
            .{ us(self.phase[0], self.evals), us(self.phase[1], self.evals), us(self.phase[2], self.evals), us(self.phase[4], self.evals), us(self.phase[3], self.evals) },
        );
    }
};

/// Keeps the driver's JIT cache (`~/.nv/ComputeCache`) from evicting the
/// compact-model kernels, whose cold compiles take 15 s (bsim4va) to 1001 s
/// (hisimhv_va). The default cap is 256 MiB on older drivers and this
/// machine's cache already held 321 MB before they were added. 4 GiB is the
/// driver's maximum. A user's own setting wins.
fn raiseJitCache() void {
    const setenv = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    }.setenv;
    _ = setenv("CUDA_CACHE_MAXSIZE", "4294967296", 0);
}

/// Kernel images larger than this JIT for seconds to minutes on first use
/// (bsim4va 3.6 MB of PTX in 15 s, psp103 7.8 MB in 35 s, hisimhv_va
/// 29.3 MB in 1001 s), so `auto` only runs them once a `--backend cuda` run
/// has compiled them into the driver cache.
const heavy_image_bytes: usize = 1 << 20;

/// The embedded image that exports `kernel`, or null.
fn imageOf(kernel: []const u8) ?[:0]const u8 {
    if (comptime backend == null) return null;
    const idx = if (comptime backend == .cuda) artifacts.cuda_index else artifacts.hip_index;
    const images = if (comptime backend == .cuda) artifacts.cuda_images else artifacts.hip_images;
    const e = idx.get(kernel) orelse return null;
    return images[e.blob];
}

/// The marker file that records `image` as compiled into the driver cache:
/// `$XDG_CACHE_HOME/espice/gpu-jit/<hash>` or `$HOME/.cache/...`. The hash
/// covers the image bytes, so a rebuild that changes the kernel starts cold.
/// ponytail: the driver cache also keys on the driver version, so an upgrade
/// leaves stale markers and `auto` pays one cold JIT; key on the version too
/// if that ever matters.
fn markerPath(buf: []u8, image: []const u8) ?[:0]const u8 {
    const hash = std.hash.Wyhash.hash(0, image);
    if (std.c.getenv("XDG_CACHE_HOME")) |x|
        return std.fmt.bufPrintZ(buf, "{s}/espice/gpu-jit/{x:0>16}", .{ std.mem.span(x), hash }) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.cache/espice/gpu-jit/{x:0>16}", .{ std.mem.span(home), hash }) catch null;
}

fn imageWarm(image: []const u8) bool {
    var buf: [512]u8 = undefined;
    const path = markerPath(&buf, image) orelse return false;
    return std.c.access(path, 0) == 0;
}

/// Records `image` as compiled. Best effort: a missing marker only means the
/// next `auto` run keeps that batch on the CPU.
fn markWarm(image: []const u8) void {
    var buf: [512]u8 = undefined;
    const path = markerPath(&buf, image) orelse return;
    // mkdir -p for `espice/` and `gpu-jit/`; EEXIST is the common case.
    const jit_dir = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const app_dir = std.mem.lastIndexOfScalar(u8, path[0..jit_dir], '/') orelse return;
    for ([_]usize{ app_dir, jit_dir }) |end| {
        buf[end] = 0;
        _ = std.c.mkdir(@ptrCast(&buf), 0o755);
        buf[end] = '/';
    }
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
    if (fd >= 0) _ = std.c.close(fd);
}

/// One batch's resident working set and the kernels that consume it.
const BatchGpu = struct {
    kernel: Raw,
    /// `arp_lim_<model>`: the fused limit/state pass, when the device has one.
    /// Launched per converged solve, or per accepted point when `held`.
    lim_kernel: ?Raw,
    /// `arp_ctl_<model>`: the accepted-step latch pass, when the device
    /// declares `stateCtl`.
    ctl_kernel: ?Raw,
    /// `arp_qtp_<model>`: the LTE charge tape, when the host batch has one.
    qtp_kernel: ?Raw,
    /// Resident for the simulation. `repack` re-uploads only models and
    /// instances; the tapes never change.
    d_models: Buffer,
    d_instances: Buffer,
    d_gath: Buffer,
    d_rhs_idx: Buffer,
    d_slots: Buffer,
    /// Lim plane (`count * n_u` f64), `[]D.State` and the charge tape;
    /// 1-byte dummies when absent, so every kernel signature is uniform.
    d_lim: Buffer,
    d_states: Buffer,
    d_tape: Buffer,
    /// The host batch's `q_tape`, which `syncTape` fills.
    tape: []f64,
    /// The host batch, so `repack` can re-read its parameter arrays.
    ctx: *anyopaque,
    payload: *const fn (*anyopaque) device_ir.GpuPayload,
    set_limit_active: ?*const fn (*anyopaque, bool) void,
    count: u32,
    grid: gompute.Dim3,
    block: u32,
    has_lim: bool,
    /// The host batch has `commit_held`: its `updateState` writes held
    /// variables no revert restores, so `lim_kernel` runs only from
    /// `commitHeldOnGpu`. `gpuEligible` admits such a device only without
    /// `limit`, so skipping the per-solve launch skips no clamp.
    held: bool,
    /// The device lim plane holds live clamp state (after a seed upload or a
    /// limit launch). Mirrors the host batch's `lim_active`.
    lim_active: bool = false,
    /// Host `seedJunctions` wrote the host lim plane; upload it before the
    /// next launch that reads it.
    lim_dirty: bool = false,

    fn deinit(self: *BatchGpu) void {
        self.d_models.free();
        self.d_instances.free();
        self.d_gath.free();
        self.d_rhs_idx.free();
        self.d_slots.free();
        self.d_lim.free();
        self.d_states.free();
        self.d_tape.free();
        if (self.lim_kernel) |*k| k.deinit();
        if (self.ctl_kernel) |*k| k.deinit();
        if (self.qtp_kernel) |*k| k.deinit();
        self.kernel.deinit();
    }

    /// `launchOn` with this batch's grid.
    fn launch(self: *BatchGpu, k: *Raw, stream: *Stream, args: []const gompute.interface.Arg) !void {
        try k.launchOn(stream, self.grid, .{ .x = self.block }, 0, args);
    }
};

/// The CUDA block width for a batch's per-instance kernels. Compact models
/// take ~255 registers a thread, so one 256-wide block fills an SM's register
/// file; 2000 instances were then 8 blocks on 24 SMs. 64 spreads any batch
/// over every SM: per eval against 256, bsim4va 679 us against 866, psp103
/// 1071 against 1284; 32 measured the same as 64. HIP keeps the exported
/// width, which its `globalIdX` bakes in. `ESPICE_GPU_BLOCK` overrides it.
fn evalBlock() u32 {
    if (comptime backend != .cuda) return block_size;
    const s = std.c.getenv("ESPICE_GPU_BLOCK") orelse return 64;
    return std.fmt.parseInt(u32, std.mem.span(s), 10) catch 64;
}

/// The planes as the device and the pinned landing area lay them out: g, rhs,
/// c, q back to back. c and q exist on the device only when a resident batch
/// has charge.
const Layout = struct {
    ng: usize,
    nr: usize,

    fn off(self: Layout, comptime plane: enum { g, rhs, c, q }) usize {
        return switch (plane) {
            .g => 0,
            .rhs => self.ng,
            .c => self.ng + self.nr,
            .q => 2 * self.ng + self.nr,
        };
    }

    /// Cells in the first `n_planes` planes.
    fn cells(self: Layout, n_planes: usize) usize {
        return if (n_planes == 2) self.off(.c) else 2 * self.off(.c);
    }
};

/// The resident device state of one query and the `GpuHook` it installs.
/// Heap-allocated; the hook and `ckt` hold its address until `deinit`.
pub const GpuContext = struct {
    gpa: std.mem.Allocator,
    ckt: *Circuit,
    /// The eligible batches, resident on the device.
    batches: []BatchGpu,
    /// Everything else: whatever `eval.gpuEligible` turns down, plus eligible
    /// batches demoted for a missing or cold image. They stamp on the host.
    cpu_batches: []const device_ir.Batch,
    /// Full-length allocations behind `batches` and `cpu_batches`. Demotions
    /// are only known after loading, so both are sized for the worst case and
    /// narrowed; `deinit` frees these, not the narrowed views.
    batches_owned: []BatchGpu,
    cpu_owned: []device_ir.Batch,

    /// The circuit's own plane allocations, swapped out for `pin_planes` while
    /// the context lives and restored (with the last values) by `deinit`.
    host_planes: Planes,
    /// Two page-locked landing areas in `Layout` order, back to back. The
    /// circuit's planes point into buffer `cur`, so the one download per eval
    /// is the whole plane update and the host batches stamp on top after it
    /// lands: no host clear, no host add. A prefetched eval (`pre`) lands
    /// in the other buffer, because the converger still reads this one's
    /// residual after the limit pass that launched it.
    pin_planes: []f64,
    cur: u1 = 0,
    layout: Layout,
    /// Page-locked staging for the eval's `x` (one per plane buffer: buffer
    /// `cur`'s holds the x of the last eval served, the other a prefetch's
    /// key), the limit pass's iterate and `x_old`, the flag word and the
    /// concatenated charge tapes.
    pin_x: [2][]f64,
    pin_x2: []f64,
    pin_xold: []f64,
    pin_flags: []u8,
    pin_tape: []f64,

    /// The eval's x, paired with `pin_x`: `d_x[cur]` holds the x of the last
    /// eval served, which the lazy tape pass reuses. The limit pass takes its
    /// iterate in `d_x2` and `x_old` in `d_xold`.
    d_x: [2]Buffer,
    d_xold: Buffer,
    d_x2: Buffer,
    /// The flag word the state kernels OR into: bit 0 limited, bit 1 reject
    /// requested.
    d_flags: Buffer,
    d_planes: Buffer,

    /// Deterministic scatter. Kernels write each contribution to its own
    /// staging cell, and `reduce` sums each plane cell's run of cells in the
    /// order the serial CPU stamp visits them.
    ///
    /// Atomic accumulation reorders the sum from pass to pass. On
    /// parallel_inverters_2000 the Vdd row takes 8000 contributions that
    /// cancel to 3.6e-9; two replays at the same x differed by 2.1e-10, the
    /// converger rejected every iterate and dt underflowed. In tape order each
    /// instance's +1.8 meets its own -1.8 two entries later and the sum is
    /// exact.
    ///
    /// Built beside the frozen tapes, not through them: `d_slots` and
    /// `d_rhs_idx` keep their `[id][ru][cu]` u32 layout and length; only their
    /// values change from plane index to staging index.
    reduce: Raw,
    /// Staging for all planes back to back (`Order`), and views of it at each
    /// plane's base, which the eval kernels take as their plane pointers.
    d_stage: Buffer,
    v_stage: [4]Buffer,
    d_seg1: Buffer,
    d_seg2: Buffer,
    d_mid: Buffer,
    n_stage: usize,
    n_pieces: usize,
    n_cells: usize,

    /// `pin_tape` holds the tape for plane buffer `tape_buf`'s eval; null
    /// when it holds nothing current. Host tapes then match with a copy.
    tape_buf: ?u1 = null,
    /// The host tapes match `d_x[cur]`; cleared by every eval.
    tape_fresh: bool = false,
    /// Set by `eval_follows`, consumed by the next limit pass or state query,
    /// and dropped by every other hook.
    follow: ?Follow = null,
    /// A prefetched eval at `pin_x[cur ^ 1]` sits in plane buffer `cur ^ 1`.
    /// Any hook that changes device state drops it.
    pre: ?Pre = null,
    /// Every resident batch with a host `q_tape` has a tape kernel, so the
    /// transient can keep its per-device LTE (`Circuit.qTapeLen`).
    tape_ok: bool,
    last_t: f64 = 0,

    /// A resident device requested a step reject, which the GPU path cannot
    /// deliver. Every later call takes the host path.
    poisoned: bool = false,
    /// Host parameters changed; re-upload models and instances before the
    /// next launch. Lazy, so an applyAttempt/restoreModels pair costs one.
    params_dirty: bool = false,

    /// Every copy and launch goes on this stream, never the NULL stream,
    /// which would synchronize with the copies this overlaps. One stream is
    /// enough: an iteration is a strict chain.
    stream: Stream,

    /// One-shot fallback warnings, one per failure kind so neither silences
    /// the other.
    warned_eval: bool = false,
    warned_state: bool = false,

    /// `evalCheck` scratch (a copy of the device planes); non-empty only
    /// under `ESPICE_GPU_EVAL_CHECK`.
    chk: []f64 = &.{},
    /// Worst reproducibility gap printed so far.
    chk_worst: f64 = 0,

    /// Some resident batch produces charge. When none does, the device c/q
    /// planes would only carry zeros, so they are neither reduced nor
    /// downloaded; the host batches stamp them alone.
    resident_charge: bool,

    prof: Prof = .{},

    const Self = @This();

    const Follow = struct { x: []const f64, t: f64, charge: bool };
    const Pre = struct { t: f64, charge: bool };

    /// Uploads every eligible batch and keeps it resident. The caller
    /// classifies a failure with `declineKind`.
    ///
    /// `explicit` (the user named the GPU) skips the cost model and loads
    /// cold images; otherwise `init` prices the query both ways (`Cost`,
    /// from `evals`, the caller's estimate of its device evals, and
    /// `threads` host lanes) and declines before the first driver call when
    /// the CPU wins.
    pub fn init(gpa: std.mem.Allocator, ckt: *Circuit, explicit: bool, threads: u32, evals: f64) !*Self {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        const report = explicit or statsOn();

        var n_gpu: usize = 0;
        for (ckt.batches) |b| {
            if (b.hooks.gpu_payload != null) n_gpu += 1;
        }
        if (n_gpu == 0) return Error.CircuitNotEligible;
        if (!explicit) try Cost.admit(gpa, ckt, threads, evals);
        raiseJitCache();

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        const batches = try gpa.alloc(BatchGpu, n_gpu);
        errdefer gpa.free(batches);
        // Sized for every batch: an eligible model with no image, or a cold
        // one under `auto`, demotes into this array below.
        const cpu_batches = try gpa.alloc(device_ir.Batch, ckt.batches.len);
        errdefer gpa.free(cpu_batches);

        var n_up: usize = 0;
        var n_cpu: usize = 0;
        var resident_charge = false;
        var tape_ok = true;
        var tape_len: usize = 0;
        errdefer for (batches[0..n_up]) |*bg| bg.deinit();

        for (ckt.batches) |b| {
            const bg = &batches[n_up];
            const up = try loadBatch(bg, b, explicit, report);
            if (!up) {
                cpu_batches[n_cpu] = b;
                n_cpu += 1;
                continue;
            }
            resident_charge = resident_charge or b.has_charge;
            if (b.hooks.q_tape != null and bg.qtp_kernel == null) tape_ok = false;
            tape_len += bg.tape.len;
            n_up += 1;
        }

        // Every eligible batch demoted; `batches[0]` below needs one.
        if (n_up == 0) return Error.CircuitNotEligible;
        if (statsOn()) std.debug.print(
            "gpu-stats: resident batches={d} host batches={d} charge planes={s} lte tape={s}\n",
            .{ n_up, n_cpu, if (resident_charge) "device" else "host-only", if (tape_ok) "device" else "row-plane" },
        );

        // Every handle allocates from the same primary context, so buffers
        // made through batch 0 are valid in every launch.
        const k0 = &batches[0].kernel;
        const layout: Layout = .{ .ng = ckt.g_vals.len, .nr = ckt.rhs.len };
        const n_planes: usize = if (resident_charge) 4 else 2;
        const x_bytes = (ckt.n + 1) * @sizeOf(f64);

        const order = try Order.build(gpa, batches[0..n_up], ckt, layout, n_planes);
        defer order.deinit(gpa);
        // Same image as the eval kernels, so a miss is a stale build: fatal.
        var reduce = try gompute.rawKernelByName(backend.?, batches[0].payload(batches[0].ctx).reduce_kernel, 0);
        errdefer reduce.deinit();
        try order.upload(batches[0..n_up]);

        // One errdefer per resource, so a failure part way through releases
        // exactly what was made. Pinned memory goes through batch 0's handle,
        // which the batch errdefer above releases after these run.
        const pin_planes = try pinnedF64(k0, 2 * layout.cells(4));
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_planes));
        const pin_x0 = try pinnedF64(k0, ckt.n + 1);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_x0));
        const pin_x1 = try pinnedF64(k0, ckt.n + 1);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_x1));
        const pin_xold = try pinnedF64(k0, ckt.n + 1);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_xold));
        const pin_x2 = try pinnedF64(k0, ckt.n + 1);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_x2));
        const pin_flags = try k0.allocPinned(4);
        errdefer k0.freePinned(pin_flags);
        const pin_tape: []f64 = if (tape_len > 0) try pinnedF64(k0, tape_len) else &.{};
        errdefer if (pin_tape.len > 0) k0.freePinned(std.mem.sliceAsBytes(pin_tape));
        var d_x0 = try k0.alloc(x_bytes);
        errdefer d_x0.free();
        var d_x1 = try k0.alloc(x_bytes);
        errdefer d_x1.free();
        var d_xold = try k0.alloc(x_bytes);
        errdefer d_xold.free();
        var d_x2 = try k0.alloc(x_bytes);
        errdefer d_x2.free();
        var d_flags = try k0.alloc(4);
        errdefer d_flags.free();
        var d_planes = try k0.alloc(layout.cells(n_planes) * @sizeOf(f64));
        errdefer d_planes.free();
        var d_stage = try k0.alloc(@max(order.n_stage, 1) * @sizeOf(f64));
        errdefer d_stage.free();
        var d_seg1 = try uploadBytes(k0, std.mem.sliceAsBytes(order.seg1));
        errdefer d_seg1.free();
        var d_seg2 = try uploadBytes(k0, std.mem.sliceAsBytes(order.seg2));
        errdefer d_seg2.free();
        var d_mid = try k0.alloc(@max(order.n_pieces, 1) * @sizeOf(f64));
        errdefer d_mid.free();
        var stream = try k0.createStream();
        errdefer stream.deinit();
        const chk: []f64 = if (std.c.getenv("ESPICE_GPU_EVAL_CHECK") != null)
            try gpa.alloc(f64, layout.cells(n_planes))
        else
            &.{};

        if (statsOn()) std.debug.print("gpu-stats: stage={d} pieces={d} cells={d}\n", .{ order.n_stage, order.n_pieces, layout.cells(n_planes) });
        // Charge-free planes read zero until a host batch stamps them.
        @memset(pin_planes, 0);
        var v_stage: [4]Buffer = undefined;
        for (&v_stage, order.stage_base) |*v, base| v.* = view(d_stage, base * @sizeOf(f64));

        self.* = .{
            .gpa = gpa,
            .ckt = ckt,
            .batches = batches[0..n_up],
            .cpu_batches = cpu_batches[0..n_cpu],
            .batches_owned = batches,
            .cpu_owned = cpu_batches,
            .host_planes = ckt.ownPlanes(),
            .pin_planes = pin_planes,
            .layout = layout,
            .pin_x = .{ pin_x0, pin_x1 },
            .pin_xold = pin_xold,
            .pin_x2 = pin_x2,
            .pin_flags = pin_flags,
            .pin_tape = pin_tape,
            .d_x = .{ d_x0, d_x1 },
            .d_xold = d_xold,
            .d_x2 = d_x2,
            .d_flags = d_flags,
            .d_planes = d_planes,
            .reduce = reduce,
            .d_stage = d_stage,
            .v_stage = v_stage,
            .d_seg1 = d_seg1,
            .d_seg2 = d_seg2,
            .d_mid = d_mid,
            .n_stage = order.n_stage,
            .n_pieces = order.n_pieces,
            .n_cells = layout.cells(n_planes),
            .tape_ok = tape_ok,
            .stream = stream,
            .resident_charge = resident_charge,
            .chk = chk,
            .prof = .{ .on = statsOn(), .phases = if (std.c.getenv("ESPICE_GPU_STATS")) |v| std.mem.eql(u8, std.mem.span(v), "phases") else false },
        };
        driver_up = true;
        // Swap the circuit onto the pinned planes, carrying their contents.
        copyPlanes(self.pinnedPlanes(0), ckt.ownPlanes());
        self.bindPlanes(0);
        return self;
    }

    /// Loads batch `b`'s kernels and uploads its working set into `bg`.
    /// False when it stays on the host: no GPU payload, no image in this
    /// build, or (`auto`) an image the driver has not compiled yet.
    fn loadBatch(bg: *BatchGpu, b: device_ir.Batch, explicit: bool, report: bool) !bool {
        const get = b.hooks.gpu_payload orelse return false;
        const p = get(b.ctx);
        const image = imageOf(p.kernel) orelse {
            reportDemote(report, b.type_name, "no kernel image in this build", p.count);
            return false;
        };
        const heavy = image.len >= heavy_image_bytes;
        if (heavy and !explicit and !imageWarm(image)) {
            std.debug.print(
                "note: GPU kernel for '{s}' is not compiled yet ({d} MB of PTX); `--backend cuda` compiles it once per build\n",
                .{ b.type_name, image.len >> 20 },
            );
            return false;
        }
        if (heavy and report and !imageWarm(image)) std.debug.print(
            "note: compiling the GPU kernel for '{s}' ({d} MB of PTX); the driver caches it for later runs\n",
            .{ b.type_name, image.len >> 20 },
        );

        var kernel = try gompute.rawKernelByName(backend.?, p.kernel, 0);
        errdefer kernel.deinit();
        if (heavy) markWarm(image);
        // The other entry points share the eval kernel's image, so a missing
        // one means a stale image: fail rather than run half-resident.
        var lim_kernel: ?Raw = if (p.lim_kernel.len > 0) try gompute.rawKernelByName(backend.?, p.lim_kernel, 0) else null;
        errdefer if (lim_kernel) |*k| k.deinit();
        var ctl_kernel: ?Raw = if (p.ctl_kernel.len > 0) try gompute.rawKernelByName(backend.?, p.ctl_kernel, 0) else null;
        errdefer if (ctl_kernel) |*k| k.deinit();
        // `arp_qtp_<model>` is named after the eval kernel, not carried in
        // the frozen payload; an older image without it keeps the row LTE.
        var qtp_name: [128]u8 = undefined;
        const eval_prefix = "arp_eval_";
        var qtp_kernel: ?Raw = null;
        if (b.hooks.q_tape != null and std.mem.startsWith(u8, p.kernel, eval_prefix)) {
            const name = std.fmt.bufPrint(&qtp_name, "arp_qtp_{s}", .{p.kernel[eval_prefix.len..]}) catch unreachable;
            qtp_kernel = gompute.rawKernelByName(backend.?, name, 0) catch |e| switch (e) {
                error.KernelNotFound => null,
                else => return e,
            };
        }
        errdefer if (qtp_kernel) |*k| k.deinit();
        const tape: []f64 = if (qtp_kernel != null) @constCast(b.hooks.q_tape.?(b.ctx)) else &.{};

        // One errdefer per buffer: `bg` counts only once it is whole, so a
        // failure part way through frees what this batch already holds.
        var d_models = try uploadBytes(&kernel, p.models);
        errdefer d_models.free();
        var d_instances = try uploadBytes(&kernel, p.instances);
        errdefer d_instances.free();
        var d_gath = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.gath));
        errdefer d_gath.free();
        var d_rhs_idx = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.rhs_idx));
        errdefer d_rhs_idx.free();
        var d_slots = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.slots));
        errdefer d_slots.free();
        // Left unwritten: reads are gated by `lim_active`, like the host's
        // `lim_x`.
        var d_lim = try kernel.alloc(if (p.lim_x.len > 0) @as(usize, p.count) * p.n_u * @sizeOf(f64) else 1);
        errdefer d_lim.free();
        var d_states = try uploadBytes(&kernel, p.states);
        errdefer d_states.free();
        const d_tape = try kernel.alloc(@max(tape.len * @sizeOf(f64), 1));

        const block = evalBlock();
        bg.* = .{
            .kernel = kernel,
            .lim_kernel = lim_kernel,
            .ctl_kernel = ctl_kernel,
            .qtp_kernel = qtp_kernel,
            .d_models = d_models,
            .d_instances = d_instances,
            .d_gath = d_gath,
            .d_rhs_idx = d_rhs_idx,
            .d_slots = d_slots,
            .d_lim = d_lim,
            .d_states = d_states,
            .d_tape = d_tape,
            .tape = tape,
            .ctx = b.ctx,
            .payload = get,
            .set_limit_active = b.hooks.set_limit_active,
            .count = p.count,
            .grid = gompute.Dim3.linear(p.count, block),
            .block = block,
            .has_lim = p.lim_x.len > 0,
            .held = b.hooks.commit_held != null,
        };
        return true;
    }

    /// Prices a query both ways before `auto` touches the driver.
    ///
    /// The host side is measured: the best of three serial evals of every
    /// eligible batch into scratch planes, divided over the ParEval lanes.
    /// The probe also writes those batches' host `q_tape`, which every reader
    /// refills first (the transient evals at its start). The device side is
    /// modelled per eval (`cost_*`: launch and wait, bus, staging, kernels
    /// at `cost_kernel_ratio` of the host time) plus the driver setup once
    /// per process. Both are multiplied by the caller's eval estimate. A
    /// query with too few evals is declined before the probe.
    const Cost = struct {
        fn admit(gpa: std.mem.Allocator, ckt: *const Circuit, threads: u32, evals: f64) !void {
            const init_us: f64 = if (driver_up) 0 else cost_init_us;
            // The probe costs three host evals; a query with few more than
            // that cannot repay the setup.
            if (evals < 20) return decline(0, 0, "too few evals");
            var slots: u64 = 0;
            for (ckt.batches) |b| {
                const get = b.hooks.gpu_payload orelse continue;
                const p = get(b.ctx);
                slots += @as(u64, p.count) * p.n_u * p.n_u;
            }
            // Scratch planes: the probe must not disturb a linearization a
            // prerequisite query left behind.
            const g = try gpa.alloc(f64, 2 * ckt.g_vals.len + 2 * ckt.rhs.len);
            defer gpa.free(g);
            @memset(g, 0);
            const pl: Planes = .{
                .g_vals = g[0..ckt.g_vals.len],
                .c_vals = g[ckt.g_vals.len..][0..ckt.g_vals.len],
                .rhs = g[2 * ckt.g_vals.len ..][0..ckt.rhs.len],
                .q_vec = g[2 * ckt.g_vals.len + ckt.rhs.len ..][0..ckt.rhs.len],
            };
            // Spread, not zero: at x = 0 every MOSFET sits in cutoff, which
            // evaluates in half the time of the operating mix (mos1: 197 us
            // against ~400 us per eval on parallel_inverters_2000).
            const x = try gpa.alloc(f64, ckt.n + 1);
            defer gpa.free(x);
            for (x, 0..) |*xi, i| xi.* = @as(f64, @floatFromInt(i % 7)) * 0.3;
            var host_ns: u64 = std.math.maxInt(u64);
            for (0..3) |_| {
                const t0 = nowNs();
                for (ckt.batches) |b| {
                    if (b.hooks.gpu_payload != null) b.eval(b.ctx, &pl, 0, b.count, x, 0);
                }
                host_ns = @min(host_ns, nowNs() - t0);
            }
            const host_us = @as(f64, @floatFromInt(host_ns)) * 1e-3;

            const n_planes: usize = if (ckt.has_charge) 4 else 2;
            const bus_bytes: f64 = @floatFromInt((n_planes * (ckt.g_vals.len + ckt.rhs.len) / 2 + 2 * ckt.n) * @sizeOf(f64));
            const stage_bytes: f64 = @floatFromInt(slots * n_planes / 2 * @sizeOf(f64));
            const gpu_us = cost_fixed_us + bus_bytes / cost_bus_b_per_us +
                stage_bytes / cost_stage_b_per_us + host_us * cost_kernel_ratio;
            const lanes = 1.0 + cost_lane_gain * @as(f64, @floatFromInt(@max(1, threads) - 1));
            const cpu_us = host_us / lanes;
            if (cost_margin * (init_us + evals * gpu_us) >= evals * cpu_us)
                return decline(cpu_us, gpu_us, "the CPU is priced faster");
            if (statsOn()) std.debug.print(
                "gpu-stats: cost per eval cpu={d:.0} us gpu={d:.0} us, {d:.0} evals, setup {d:.0} ms: GPU\n",
                .{ cpu_us, gpu_us, evals, init_us * 1e-3 },
            );
        }

        fn decline(cpu_us: f64, gpu_us: f64, why: []const u8) Error {
            if (statsOn()) std.debug.print("gpu-stats: cost per eval cpu={d:.0} us gpu={d:.0} us: CPU ({s})\n", .{ cpu_us, gpu_us, why });
            return Error.NotEnoughGpuWork;
        }
    };

    /// The permutation and segment tables behind the deterministic scatter,
    /// fused over every device plane so an eval costs one clear, two reduce
    /// launches and one download.
    ///
    /// A contribution is one tape entry, `(batch, id, ru, cu)` for g/c and
    /// `(batch, id, ru)` for rhs/q, numbered in the order the serial CPU stamp
    /// visits them and counting-sorted stably by destination cell. `perm[k]` is
    /// k's staging cell within its plane's stage; g and c share the slot
    /// permutation, rhs and q the row permutation.
    ///
    /// Stages sit back to back (`stage_base`), each a run per plane cell and
    /// then a trash tail (ground and structural-zero contributions) that no
    /// range covers. Level 1 sums `chunk`-sized pieces of each cell's run,
    /// level 2 each cell's pieces, both with the same kernel over `[start,
    /// end)` pairs. A run of at most `chunk` is one piece and sums exactly as
    /// the CPU does.
    ///
    /// Summing the trash tails instead (one pad cell per plane) cost 104 us of
    /// a 170 us mos1_2000 eval: level 2 walked the pad's 1,600 pieces on one
    /// thread.
    const Order = struct {
        perm_slot: []u32,
        perm_row: []u32,
        /// Piece `j` is stage `[seg1[2j], seg1[2j+1])`.
        seg1: []u32,
        /// Device plane cell `i` is pieces `[seg2[2i], seg2[2i+1])`.
        seg2: []u32,
        stage_base: [4]usize,
        n_stage: usize,
        n_pieces: usize,

        /// Contributions per level-1 piece: an 8000-deep row becomes 125
        /// threads of 64, then one thread of 125.
        const chunk: u32 = 64;

        fn deinit(self: Order, gpa: std.mem.Allocator) void {
            gpa.free(self.perm_slot);
            gpa.free(self.perm_row);
            gpa.free(self.seg1);
            gpa.free(self.seg2);
        }

        /// Overwrites each batch's resident slot and row tapes with its slice
        /// of the permutation, keeping their length and layout.
        fn upload(self: Order, batches: []BatchGpu) !void {
            var off_s: usize = 0;
            var off_r: usize = 0;
            for (batches) |*bg| {
                const p = bg.payload(bg.ctx);
                if (p.slots.len > 0)
                    try bg.d_slots.upload(self.perm_slot[off_s..].ptr, p.slots.len * @sizeOf(u32));
                if (p.rhs_idx.len > 0)
                    try bg.d_rhs_idx.upload(self.perm_row[off_r..].ptr, p.rhs_idx.len * @sizeOf(u32));
                off_s += p.slots.len;
                off_r += p.rhs_idx.len;
            }
        }

        fn build(gpa: std.mem.Allocator, batches: []BatchGpu, ckt: *const Circuit, layout: Layout, n_planes: usize) !Order {
            var n_slot: usize = 0;
            var n_row: usize = 0;
            for (batches) |*bg| {
                const p = bg.payload(bg.ctx);
                n_slot += p.slots.len;
                n_row += p.rhs_idx.len;
            }
            const n_stage = if (n_planes == 2) n_slot + n_row else 2 * (n_slot + n_row);
            // The u32 tapes and seg tables index the stage. Past u32 fall back
            // to the CPU, never truncate.
            if (n_stage > std.math.maxInt(u32)) return Error.CircuitNotEligible;

            const perm_slot = try gpa.alloc(u32, n_slot);
            errdefer gpa.free(perm_slot);
            const perm_row = try gpa.alloc(u32, n_row);
            errdefer gpa.free(perm_row);
            // Cell -> start of its run within the space's stage.
            const seg_slot = try gpa.alloc(u32, layout.ng + 1);
            defer gpa.free(seg_slot);
            const seg_row = try gpa.alloc(u32, layout.nr + 1);
            defer gpa.free(seg_row);
            try permute(gpa, batches, true, ckt.trash_slot, seg_slot, perm_slot);
            try permute(gpa, batches, false, ckt.n, seg_row, perm_row);
            const spaces = [2][]const u32{ seg_slot, seg_row };

            // g, rhs, c, q: slot, row, slot, row.
            var stage_base: [4]usize = .{ 0, n_slot, n_slot + n_row, 2 * n_slot + n_row };
            if (n_planes == 2) stage_base[2..].* = .{ 0, 0 };
            var seg1: std.ArrayList(u32) = .empty;
            errdefer seg1.deinit(gpa);
            const n_cells = layout.cells(n_planes);
            const seg2 = try gpa.alloc(u32, 2 * n_cells);
            errdefer gpa.free(seg2);
            var cell: usize = 0;
            for (0..n_planes) |plane| {
                const seg = spaces[plane % 2];
                const base: u32 = @intCast(stage_base[plane]);
                for (0..seg.len - 1) |i| {
                    seg2[2 * cell] = @intCast(seg1.items.len / 2);
                    var at = seg[i];
                    while (at < seg[i + 1]) : (at += chunk)
                        try seg1.appendSlice(gpa, &.{ base + at, base + @min(at + chunk, seg[i + 1]) });
                    seg2[2 * cell + 1] = @intCast(seg1.items.len / 2);
                    cell += 1;
                }
            }
            std.debug.assert(cell == n_cells);
            const n_pieces = seg1.items.len / 2;
            return .{
                .perm_slot = perm_slot,
                .perm_row = perm_row,
                .seg1 = try seg1.toOwnedSlice(gpa),
                .seg2 = seg2,
                .stage_base = stage_base,
                .n_stage = n_stage,
                .n_pieces = n_pieces,
            };
        }

        /// Counting-sorts one space's contributions by destination cell into
        /// `perm` and fills `seg` (cell -> run start, `seg[n_cells]` = run
        /// end). Trash contributions go to the tail after the runs, each on
        /// its own cell: the kernel stores through the tape unconditionally,
        /// and a shared cell would be a contended write.
        fn permute(gpa: std.mem.Allocator, batches: []BatchGpu, slots_pass: bool, trash: u32, seg: []u32, perm: []u32) !void {
            @memset(seg, 0);
            for (batches) |*bg| {
                const p = bg.payload(bg.ctx);
                for (if (slots_pass) p.slots else p.rhs_idx) |dest| {
                    if (dest != trash) seg[dest + 1] += 1;
                }
            }
            var run: u32 = 0;
            for (seg) |*s| {
                run += s.*;
                s.* = run;
            }
            const cursor = try gpa.dupe(u32, seg);
            defer gpa.free(cursor);
            var tail: u32 = run;
            var k: usize = 0;
            for (batches) |*bg| {
                const p = bg.payload(bg.ctx);
                for (if (slots_pass) p.slots else p.rhs_idx) |dest| {
                    if (dest == trash) {
                        perm[k] = tail;
                        tail += 1;
                    } else {
                        perm[k] = cursor[dest];
                        cursor[dest] += 1;
                    }
                    k += 1;
                }
            }
        }
    };

    /// Page-locked `[]f64` from the driver; release with `freePinned`.
    fn pinnedF64(kernel: *Raw, n: usize) ![]f64 {
        const bytes = try kernel.allocPinned(n * @sizeOf(f64));
        return @alignCast(std.mem.bytesAsSlice(f64, bytes));
    }

    /// A non-owning buffer `byte_off` bytes into `base`, for kernel arguments.
    /// Never `free` it.
    fn view(base: Buffer, byte_off: usize) Buffer {
        var v = base;
        v.bytes -= byte_off;
        v.handle = switch (@typeInfo(@TypeOf(base.handle))) {
            .int => base.handle + byte_off,
            else => @ptrFromInt(@intFromPtr(base.handle) + byte_off),
        };
        return v;
    }

    /// Plane buffer `buf` (all four planes) within `pin_planes`.
    fn pinnedBuf(self: *const Self, buf: u1) []f64 {
        const n = self.layout.cells(4);
        return self.pin_planes[@as(usize, buf) * n ..][0..n];
    }

    /// The four planes as slices of plane buffer `buf`.
    fn pinnedPlanes(self: *const Self, buf: u1) Planes {
        const l = self.layout;
        const b = self.pinnedBuf(buf);
        return .{
            .g_vals = b[l.off(.g)..][0..l.ng],
            .rhs = b[l.off(.rhs)..][0..l.nr],
            .c_vals = b[l.off(.c)..][0..l.ng],
            .q_vec = b[l.off(.q)..][0..l.nr],
        };
    }

    /// Points the circuit's planes at buffer `buf`.
    fn bindPlanes(self: *Self, buf: u1) void {
        self.cur = buf;
        const pp = self.pinnedPlanes(buf);
        self.ckt.g_vals = pp.g_vals;
        self.ckt.c_vals = pp.c_vals;
        self.ckt.rhs = pp.rhs;
        self.ckt.q_vec = pp.q_vec;
    }

    fn copyPlanes(dst: Planes, src: Planes) void {
        @memcpy(dst.g_vals, src.g_vals);
        @memcpy(dst.c_vals, src.c_vals);
        @memcpy(dst.rhs, src.rhs);
        @memcpy(dst.q_vec, src.q_vec);
    }

    /// Restores the circuit's own planes (with the last values), then frees
    /// every device and pinned buffer and `self`.
    pub fn deinit(self: *Self) void {
        if (comptime backend == null) return;
        self.prof.print();
        const ckt = self.ckt;
        const hp = self.host_planes;
        copyPlanes(hp, ckt.ownPlanes());
        ckt.g_vals = hp.g_vals;
        ckt.c_vals = hp.c_vals;
        ckt.rhs = hp.rhs;
        ckt.q_vec = hp.q_vec;
        // Pinned memory first, while batch 0's handle that owns it is alive.
        const k0 = &self.batches[0].kernel;
        for ([_][]f64{ self.pin_planes, self.pin_x[0], self.pin_x[1], self.pin_x2, self.pin_xold, self.pin_tape }) |p| {
            if (p.len > 0) k0.freePinned(std.mem.sliceAsBytes(p));
        }
        k0.freePinned(self.pin_flags);
        self.stream.deinit();
        for ([_]*Buffer{ &self.d_x[0], &self.d_x[1], &self.d_xold, &self.d_x2, &self.d_flags, &self.d_planes, &self.d_stage, &self.d_seg1, &self.d_seg2, &self.d_mid }) |b| b.free();
        self.reduce.deinit();
        for (self.batches) |*bg| bg.deinit();
        if (self.chk.len > 0) self.gpa.free(self.chk);
        self.gpa.free(self.batches_owned);
        self.gpa.free(self.cpu_owned);
        self.gpa.destroy(self);
    }

    fn uploadBytes(kernel: *Raw, bytes: []const u8) !Buffer {
        // Empty arrays still need a valid kernel-argument pointer, and
        // drivers reject zero-byte allocations.
        var buf = try kernel.alloc(@max(bytes.len, 1));
        errdefer buf.free();
        if (bytes.len > 0) try buf.upload(bytes.ptr, bytes.len);
        return buf;
    }

    /// Stamps all four planes: the resident batches on the device, whose one
    /// download lands straight in the circuit's planes, then the host batches
    /// on top and the ground pin. Always zero and restamp, never the
    /// constant-Jacobian baseline. Limit devices read their resident lim
    /// plane while `lim_active`, like the host eval.
    ///
    /// ponytail: the host batches wait for the download instead of stamping
    /// beside it, which costs their eval time per iteration (sources: a few
    /// microseconds). A heavy ineligible batch next to resident ones would
    /// want private host planes and an add over its footprint again.
    fn evalOnGpu(self: *Self, x: []const f64, t: f64, charge: bool) !void {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        self.follow = null;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        const ckt = self.ckt;
        self.prof.start();
        self.prof.evals += 1;

        const pre = self.pre;
        self.pre = null;
        // The prefetch ran on the same device state with the same launches,
        // so its planes are bitwise what this eval would produce. Bytes, not
        // `==`: -0.0 and +0.0 compare equal but may stamp differently.
        if (pre != null and pre.?.t == t and
            std.mem.eql(u8, std.mem.sliceAsBytes(x), std.mem.sliceAsBytes(self.pin_x[self.cur ^ 1][0..x.len])))
        {
            self.bindPlanes(self.cur ^ 1);
            self.tape_buf = if (pre.?.charge) self.cur else null;
            self.prof.fused += 1;
        } else {
            try self.enqueueEval(x, t, self.cur, charge);
            self.prof.lap("enqueue");
            try self.sync();
            self.prof.lap("wait");
        }
        // The device writes neither c nor q when no resident batch has
        // charge; the host batches stamp them from zero.
        if (!self.resident_charge and ckt.has_charge) {
            @memset(ckt.c_vals, 0);
            @memset(ckt.q_vec, 0);
        }
        self.tape_fresh = false;
        self.last_t = t;

        if (self.chk.len > 0) try self.evalCheck(x, t);

        const pl = ckt.ownPlanes();
        for (self.cpu_batches) |b| b.eval(b.ctx, &pl, 0, b.count, x, t);
        ckt.groundStamp(x);
        self.prof.lap("host");
    }

    /// Enqueues the device half without waiting: upload x, clear the stage,
    /// launch every resident batch, reduce, download into the pinned planes.
    /// Separate so `evalCheck` can replay the same pass.
    fn enqueueEval(self: *Self, x: []const f64, t: f64, buf: u1, charge: bool) !void {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        @memcpy(self.pin_x[buf][0..x.len], x);
        try self.d_x[buf].uploadAtAsync(self.pin_x[buf].ptr, 0, x.len * @sizeOf(f64), &self.stream);
        // Staging, not the planes: the reduction writes every plane cell, but
        // a contribution the pattern or ground mask skips is never stored and
        // must read back as 0.
        try self.d_stage.fillAsync(0, self.n_stage * @sizeOf(f64), &self.stream);
        try self.phaseLap(0);

        for (self.batches) |*bg| {
            if (bg.count == 0) continue;
            try syncSeededLim(bg);
            // Scalars are passed by pointer and must outlive the launch call.
            var count: u64 = bg.count;
            var time: f64 = t;
            var limiting: u64 = @intFromBool(bg.lim_active);
            try bg.launch(&bg.kernel, &self.stream, &.{
                gompute.interface.arg(&count),
                gompute.interface.arg(&time),
                self.d_x[buf].argPtr(),
                bg.d_gath.argPtr(),
                bg.d_rhs_idx.argPtr(),
                bg.d_slots.argPtr(),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                self.v_stage[0].argPtr(),
                self.v_stage[2].argPtr(),
                self.v_stage[1].argPtr(),
                self.v_stage[3].argPtr(),
                bg.d_lim.argPtr(),
                gompute.interface.arg(&limiting),
            });
        }

        try self.phaseLap(1);
        try self.launchReduce(&self.d_seg1, &self.d_stage, &self.d_mid, self.n_pieces);
        try self.phaseLap(2);
        try self.launchReduce(&self.d_seg2, &self.d_mid, &self.d_planes, self.n_cells);
        try self.phaseLap(4);
        try self.d_planes.downloadAtAsync(self.pinnedBuf(buf).ptr, 0, self.n_cells * @sizeOf(f64), &self.stream);
        try self.phaseLap(3);
        // `pin_tape` is about to hold buffer `buf`'s tape, or stale bytes.
        self.tape_buf = null;
        if (charge) try self.enqueueTape(buf, t);
    }

    /// Waits for this stream only: a context-wide sync would also wait on
    /// work this process does not own. Counted for `ESPICE_GPU_STATS`.
    fn sync(self: *Self) !void {
        self.prof.syncs += 1;
        try self.stream.synchronize();
    }

    /// Under `Prof.phases`, waits for the stream and books the time since
    /// the last lap to stage `i`.
    fn phaseLap(self: *Self, comptime i: usize) !void {
        if (!self.prof.phases) return;
        if (i == 0) self.prof.last = nowNs();
        try self.stream.synchronize();
        const t = nowNs();
        self.prof.phase[i] += t - self.prof.last;
        self.prof.last = t;
    }

    /// One `arp_reduce_*` launch: `out[i] = sum(in[seg[i]..seg[i+1]])`.
    fn launchReduce(self: *Self, seg: *Buffer, in: *Buffer, out: *Buffer, cells: usize) !void {
        if (cells == 0) return;
        var n_cells: u64 = cells;
        try self.reduce.launchOn(
            &self.stream,
            gompute.Dim3.linear(cells, block_size),
            .{ .x = block_size },
            0,
            &.{ gompute.interface.arg(&n_cells), seg.argPtr(), in.argPtr(), out.argPtr() },
        );
    }

    /// `ESPICE_GPU_EVAL_CHECK`: replays the device pass at the same x and
    /// prints the worst device plane cell that moved, when it beats the last
    /// record. Newton cannot converge on a stamp that is not a function of x,
    /// so any output here means the deterministic scatter regressed. Restores
    /// the first pass, so a checked run stamps what an unchecked one would.
    fn evalCheck(self: *Self, x: []const f64, t: f64) !void {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        const first = self.pinnedBuf(self.cur)[0..self.n_cells];
        @memcpy(self.chk, first);
        try self.enqueueEval(x, t, self.cur, false);
        try self.sync();
        var worst: f64 = 0;
        var where: usize = 0;
        for (self.chk, first, 0..) |a, b, i| {
            const d = @abs(a - b);
            if (d > worst) {
                worst = d;
                where = i;
            }
        }
        if (worst > self.chk_worst) {
            self.chk_worst = worst;
            std.debug.print(
                "gpu-check: eval is not reproducible at t={e:.6}: |Δ plane cell {d}|={e:.3} (was {e:.16}, now {e:.16})\n",
                .{ t, where, worst, self.chk[where], first[where] },
            );
        }
        @memcpy(first, self.chk);
    }

    /// The `eval_planes` hook. No analysis can unwind from a driver fault
    /// mid-solve, so a failure restamps on the CPU and warns once.
    fn evalPlanes(ctx: *anyopaque, x: []const f64, t: f64) void {
        evalHook(ctx, x, t, false);
    }

    fn evalChargeHook(ctx: *anyopaque, x: []const f64, t: f64) void {
        evalHook(ctx, x, t, true);
    }

    fn evalHook(ctx: *anyopaque, x: []const f64, t: f64, charge: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.evalOnGpu(x, t, charge) catch |e| {
            if (!self.warned_eval) {
                self.warned_eval = true;
                std.debug.print(
                    "warning: GPU device eval failed ({s}); falling back to the CPU stamp\n",
                    .{@errorName(e)},
                );
            }
            self.ckt.evalNewtonCpu(x, t);
        };
    }

    /// Fills every resident batch's host `q_tape` with the LTE charges at the
    /// last eval's x, which `d_x[cur]` still holds. Lazy: the transient reads the
    /// tape once per step, and Newton evals many times in between.
    fn syncTape(self: *Self) !void {
        if (comptime backend == null) return;
        if (self.tape_fresh or self.pin_tape.len == 0) return;
        if (self.poisoned) return error.GpuStateReject;
        if (self.tape_buf != self.cur) {
            try self.enqueueTape(self.cur, self.last_t);
            try self.sync();
        }
        var off: usize = 0;
        for (self.batches) |*bg| {
            @memcpy(bg.tape, self.pin_tape[off..][0..bg.tape.len]);
            off += bg.tape.len;
        }
        self.tape_fresh = true;
    }

    /// Queues every tape kernel at `d_x[buf]` and the download into
    /// `pin_tape`, which then holds buffer `buf`'s tape once the stream
    /// drains.
    fn enqueueTape(self: *Self, buf: u1, t: f64) !void {
        var off: usize = 0;
        for (self.batches) |*bg| {
            const k = if (bg.qtp_kernel) |*k| k else continue;
            if (bg.tape.len == 0) continue;
            var count: u64 = bg.count;
            var time: f64 = t;
            try bg.launch(k, &self.stream, &.{
                gompute.interface.arg(&count),
                gompute.interface.arg(&time),
                self.d_x[buf].argPtr(),
                bg.d_gath.argPtr(),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                bg.d_tape.argPtr(),
            });
            try bg.d_tape.downloadAtAsync(self.pin_tape[off..].ptr, 0, bg.tape.len * @sizeOf(f64), &self.stream);
            off += bg.tape.len;
        }
        self.tape_buf = buf;
    }

    /// The `sync_q_tape` hook. A fault leaves the resident tapes at their
    /// last value for this step, warns once, and poisons the context so every
    /// later step runs on the host.
    fn syncTapeHook(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.syncTape() catch {
            self.warnStateFallback();
            self.poisoned = true;
        };
    }

    /// Uploads seed voltages a host `seedJunctions` left in the batch's lim
    /// plane and arms device limiting. Synchronous, so it lands before the
    /// launch that reads it.
    fn syncSeededLim(bg: *BatchGpu) !void {
        if (!bg.lim_dirty) return;
        bg.lim_dirty = false;
        if (!bg.has_lim) return;
        const p = bg.payload(bg.ctx);
        if (!p.lim_active) return;
        try bg.d_lim.upload(std.mem.sliceAsBytes(p.lim_x).ptr, p.lim_x.len * @sizeOf(f64));
        bg.lim_active = true;
    }

    /// Limits and state-latches the resident batches in one fused launch (the
    /// converger calls `applyLimits` and `updateStates` back to back at the
    /// same x), walking the host batches meanwhile. Synchronous, because the
    /// converger reads the answer at once.
    ///
    /// After `eval_follows`, the eval at the limited x goes on the stream
    /// behind the limit pass, once the host limiters have finished with x,
    /// and one wait covers both (`evalOnGpu` picks it up). The device runs
    /// the same launches in the same order as the two-wait sequence, so the
    /// planes are bitwise the same. mos1_2000: 2 waits per Newton iteration
    /// become 1.
    fn applyLimitsOnGpu(self: *Self, x: []f64, x_old: []const f64) !bool {
        if (comptime backend == null) return false;
        const follow = self.follow;
        self.follow = null;
        self.pre = null;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        const n = self.ckt.n;
        self.prof.start();
        self.prof.lims += 1;
        defer self.prof.lap("lim");

        var launched = false;
        for (self.batches) |*bg| {
            const lk = if (bg.lim_kernel) |*k| k else continue;
            if (bg.count == 0 or bg.held) continue;
            if (!launched) {
                // `x_old` explicitly: under JFNK the last eval was a
                // finite-difference probe.
                @memcpy(self.pin_x2[0..n], x[0..n]);
                try self.d_x2.uploadAtAsync(self.pin_x2.ptr, 0, n * @sizeOf(f64), &self.stream);
                @memcpy(self.pin_xold[0..n], x_old[0..n]);
                try self.d_xold.uploadAtAsync(self.pin_xold.ptr, 0, n * @sizeOf(f64), &self.stream);
                try self.d_flags.fillAsync(0, 4, &self.stream);
            }
            try syncSeededLim(bg);
            var count: u64 = bg.count;
            var lim_active: u64 = @intFromBool(bg.lim_active);
            try bg.launch(lk, &self.stream, &.{
                gompute.interface.arg(&count),
                self.d_x2.argPtr(),
                self.d_xold.argPtr(),
                bg.d_gath.argPtr(),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                bg.d_lim.argPtr(),
                bg.d_states.argPtr(),
                gompute.interface.arg(&lim_active),
                self.d_flags.argPtr(),
            });
            bg.lim_active = bg.lim_active or bg.has_lim;
            launched = true;
        }
        if (launched)
            try self.d_flags.downloadAtAsync(self.pin_flags.ptr, 0, 4, &self.stream);

        var any = Circuit.limitBatches(self.cpu_batches, x, x_old);

        if (launched) {
            // Without a limit launch there is no wait to share.
            if (follow) |f| try self.prefetch(f);
            try self.sync();
            const flags = std.mem.readInt(u32, self.pin_flags[0..4], .little);
            if (flags & 2 != 0) {
                // A step reject the GPU path cannot deliver: `gpuEligible`
                // admitted a device it should not have.
                self.poisoned = true;
                self.pre = null;
                return error.GpuStateReject;
            }
            if (flags & 1 != 0) any = true;
        }
        return any;
    }

    fn evalFollowsHook(ctx: *anyopaque, x: []const f64, t: f64, charge: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // `ESPICE_GPU_NOFUSE`: the unfused sequence, for A/B runs.
        if (std.c.getenv("ESPICE_GPU_NOFUSE") != null) return;
        self.follow = .{ .x = x, .t = t, .charge = charge };
    }

    /// Enqueues the eval `f` announced into the other plane buffer, behind
    /// whatever the stream holds; the caller's wait covers it.
    fn prefetch(self: *Self, f: Follow) !void {
        try self.enqueueEval(f.x, f.t, self.cur ^ 1, f.charge);
        self.pre = .{ .t = f.t, .charge = f.charge };
    }

    /// The `apply_limits` hook. A fault falls back to the host walk over every
    /// batch; the resident batches' stale host lim/state self-heal, since
    /// limiting restarts from x_old and the latches recompute from x alone.
    fn applyLimitsHook(ctx: *anyopaque, x: []f64, x_old: []const f64) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.applyLimitsOnGpu(x, x_old) catch {
            self.warnStateFallback();
            return Circuit.limitBatches(self.ckt.batches, x, x_old);
        };
    }

    /// The `update_states` hook. The resident half already ran in the fused
    /// limit launch and never returns a reject time, so only the host batches
    /// walk (all of them once poisoned).
    fn updateStatesHook(ctx: *anyopaque, x: []const f64) ?f64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return Circuit.updateBatches(if (self.poisoned) self.ckt.batches else self.cpu_batches, x);
    }

    /// Runs the held batches' state kernel at the accepted `x` and the host
    /// walk on the rest. A resident batch cannot ask for a step reject: the
    /// kernel flags any non-`.ok` `updateState` as a fault instead.
    fn commitHeldOnGpu(self: *Self, x: []const f64) !?f64 {
        if (comptime backend == null) return null;
        self.pre = null;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        const n = self.ckt.n;
        var launched = false;
        for (self.batches) |*bg| {
            const lk = if (bg.lim_kernel) |*k| k else continue;
            if (bg.count == 0 or !bg.held) continue;
            if (!launched) {
                @memcpy(self.pin_x2[0..n], x[0..n]);
                try self.d_x2.uploadAtAsync(self.pin_x2.ptr, 0, n * @sizeOf(f64), &self.stream);
                try self.d_flags.fillAsync(0, 4, &self.stream);
            }
            var count: u64 = bg.count;
            var lim_active: u64 = 0;
            try bg.launch(lk, &self.stream, &.{
                gompute.interface.arg(&count),
                self.d_x2.argPtr(),
                self.d_x2.argPtr(),
                bg.d_gath.argPtr(),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                bg.d_lim.argPtr(),
                bg.d_states.argPtr(),
                gompute.interface.arg(&lim_active),
                self.d_flags.argPtr(),
            });
            launched = true;
        }
        // The host walk waits for the verdict: a second `updateState` reads
        // the held values the first one wrote, so the fallback's walk over
        // every batch must be the only one.
        if (launched) {
            try self.d_flags.downloadAtAsync(self.pin_flags.ptr, 0, 4, &self.stream);
            try self.sync();
            if (std.mem.readInt(u32, self.pin_flags[0..4], .little) & 2 != 0) {
                self.poisoned = true;
                return error.GpuStateReject;
            }
        }
        return Circuit.commitHeldBatches(self.cpu_batches, x);
    }

    fn commitHeldHook(ctx: *anyopaque, x: []const f64) ?f64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.commitHeldOnGpu(x) catch {
            self.warnStateFallback();
            return Circuit.commitHeldBatches(self.ckt.batches, x);
        };
    }

    fn clearLimitsHook(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.pre = null;
        for (self.batches) |*bg| {
            bg.lim_active = false;
            bg.lim_dirty = false;
        }
        Circuit.clearLimitBatches(if (self.poisoned) self.ckt.batches else self.cpu_batches);
    }

    /// Runs the accepted-step latch (path commit `pb <- wb, pq += wq`) on the
    /// resident instance blobs and the host walk on the rest. The kernels OR
    /// each instance's verdict into `d_flags`, so `.query` costs one launch
    /// and a 4-byte sync.
    ///
    /// ponytail: a `repack` for a parameter write resets device pb/pq to the
    /// host's stale copies. Harmless today (parameter writes happen only
    /// before a transient or in static sweeps); a mid-transient write would
    /// need `pullInstances` first.
    fn stateCtlOnGpu(self: *Self, op: device_ir.StateCtlOp) !bool {
        if (comptime backend == null) return false;
        const follow = self.follow;
        self.follow = null;
        self.pre = null;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        var launched = false;
        for (self.batches) |*bg| {
            const ck = if (bg.ctl_kernel) |*k| k else continue;
            if (bg.count == 0) continue;
            if (!launched) try self.d_flags.fillAsync(0, 4, &self.stream);
            var count: u64 = bg.count;
            var opv: u64 = @intFromEnum(op);
            try bg.launch(ck, &self.stream, &.{
                gompute.interface.arg(&count),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                bg.d_states.argPtr(),
                gompute.interface.arg(&opv),
                self.d_flags.argPtr(),
            });
            launched = true;
        }
        // Every caller discards what `.commit` and `.revert` return, so they
        // stay on the stream unwaited; the next wait surfaces a fault. Only a
        // `.query` reads the flag, and it shares its wait with the charge
        // eval the transient announced.
        const wait = launched and op == .query;
        // Queued before the host walk so it drains meanwhile, and so a failed
        // enqueue happens before the walk: the fallback re-walks every batch,
        // and the path commit `pq += wq` is not idempotent.
        if (wait) {
            try self.d_flags.downloadAtAsync(self.pin_flags.ptr, 0, 4, &self.stream);
            if (follow) |f| try self.prefetch(f);
        }

        var dirty = Circuit.stateCtlBatches(self.cpu_batches, op);
        if (wait) {
            try self.sync();
            if (std.mem.readInt(u32, self.pin_flags[0..4], .little) != 0) dirty = true;
        }
        return dirty;
    }

    fn stateCtlHook(ctx: *anyopaque, op: device_ir.StateCtlOp) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.stateCtlOnGpu(op) catch {
            self.warnStateFallback();
            return Circuit.stateCtlBatches(self.ckt.batches, op);
        };
    }

    /// The `seed_junctions` hook: every batch seeds the host `x`, then each
    /// resident lim plane is marked for upload before its next launch.
    fn seedJunctionsHook(ctx: *anyopaque, x: []f64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.pre = null;
        Circuit.seedBatches(self.ckt.batches, x);
        for (self.batches) |*bg| {
            if (bg.has_lim) bg.lim_dirty = true;
        }
    }

    /// Downloads every resident batch's instances into the host batch.
    fn pullInstances(self: *Self) !void {
        if (comptime backend == null) return;
        try self.sync();
        for (self.batches) |*bg| {
            const p = bg.payload(bg.ctx);
            if (p.instances.len != 0)
                try bg.d_instances.download(@constCast(p.instances.ptr), p.instances.len);
        }
    }

    fn warnStateFallback(self: *Self) void {
        if (self.warned_state) return;
        self.warned_state = true;
        std.debug.print(
            "warning: GPU limit/state pass failed; falling back to the CPU walk\n",
            .{},
        );
    }

    /// Downloads the resident instance, state and lim data into the host
    /// batches, so dependents copy an OP that matches the device. Fails with
    /// `error.GpuStateUnavailable` after any fallback, which can leave the two
    /// sides at different accepted points.
    pub fn syncHostState(self: *Self) !void {
        if (comptime backend == null) return;
        if (self.poisoned or self.warned_eval or self.warned_state)
            return error.GpuStateUnavailable;
        try self.pullInstances();
        for (self.batches) |*batch| {
            const payload = batch.payload(batch.ctx);
            if (payload.states.len != 0)
                try batch.d_states.download(@constCast(payload.states.ptr), payload.states.len);
            if (batch.has_lim and !batch.lim_dirty) {
                if (batch.lim_active)
                    try batch.d_lim.download(@constCast(payload.lim_x.ptr), payload.lim_x.len * @sizeOf(f64));
                if (batch.set_limit_active) |set| set(batch.ctx, batch.lim_active);
            }
        }
    }

    /// Re-uploads models and instances after a host parameter change. The
    /// tapes never change.
    fn repack(self: *Self) !void {
        if (comptime backend == null) return;
        for (self.batches) |*bg| {
            const p = bg.payload(bg.ctx);
            if (p.models.len > 0) try bg.d_models.upload(p.models.ptr, p.models.len);
            if (p.instances.len > 0) try bg.d_instances.upload(p.instances.ptr, p.instances.len);
        }
        self.params_dirty = false;
    }

    fn markDirty(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.pre = null;
        self.params_dirty = true;
    }

    /// Returns the dispatch table to install as `Circuit.gpu_hook`.
    pub fn hook(self: *Self) GpuHook {
        return .{
            .ctx = self,
            .q_tape = self.tape_ok,
            .eval_planes = evalPlanes,
            .sync_q_tape = syncTapeHook,
            .eval_follows = evalFollowsHook,
            .eval_charge = evalChargeHook,
            .apply_limits = applyLimitsHook,
            .update_states = updateStatesHook,
            .commit_held = commitHeldHook,
            .clear_limits = clearLimitsHook,
            .seed_junctions = seedJunctionsHook,
            .state_ctl = stateCtlHook,
            .mark_dirty = markDirty,
        };
    }
};

/// Private access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .backend = backend,
} else {};
