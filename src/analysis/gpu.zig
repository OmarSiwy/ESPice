//! GPU device evaluation feeding the host solver. Every eligible batch's
//! models, instances and tapes are uploaded once and stay resident; per Newton
//! iteration the bus carries `x` up and the value planes down, and the sparse
//! LU, Newton update and convergence test stay on the CPU. That round trip is
//! the floor, so the GPU pays off on device count, not circuit size.

const std = @import("std");
const analysis = @import("types.zig");
const device_ir = @import("device").abi;
const gompute = @import("gompute");

const Circuit = analysis.Circuit;
const GpuHook = analysis.GpuHook;
const addSimd = @import("par_eval.zig").addSimd;

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
    /// A performance guess (too little work). An explicit request overrides
    /// it, so only `auto` sees one.
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

/// The kernels bake this block width into `globalIdX` when they are exported,
/// so every launch must use it.
const block_size: u32 = device_ir.gpu_block_size;

pub const Error = error{
    /// The build machine had no GPU, so no kernel images were emitted.
    NoGpuArtifacts,
    /// No device in this circuit has a kernel image (see `eval.gpuEligible`).
    CircuitNotEligible,
    /// Eligible devices exist but do too little work for the round trip.
    NotEnoughGpuWork,
};

/// Weighted scatter work (see `init`) below which `auto` declines before
/// touching the driver. 200_000 raw `count * n_u^2` atomics, times the x16
/// nonlinear weight. The per-iteration round trip is ~100 us and 6 atomics x
/// 200 K instances take 76 us (RTX 4060 Laptop), so fewer atomics cannot win.
///
/// Not a break-even: no corpus deck currently wins on the GPU, and fixed
/// driver setup (~340 ms: cuInit, context retain, module JIT) sinks any deck
/// whose whole CPU run is shorter. Measured, ReleaseFast, whole process:
///
///   fixture                          work    cpu     gpu
///   devices/mos6_inverter            82 K    0.02 s  0.38 s
///   scaling/parallel_inverters_100   205 K   0.05 s  0.50 s
///   tran/fourbitadder                592 K   0.04 s  0.36 s
///   scaling/parallel_inverters_2000  4.1 M   0.55 s  0.66 s
///   sweep/opamp_wl_5000              25.6 M  0.66 s  0.90 s
///
/// `ESPICE_GPU_MIN_WORK` overrides it; an explicit request skips it.
///
/// ponytail: an atomic-count proxy, right for the linear and algebraic parts
/// `gpuEligible` admits today. It understates a compact-model kernel with
/// thousands of f64 ops per instance; a per-device cost weight from the
/// emitted PTX size is the upgrade path when one becomes eligible.
const default_min_work: u64 = 3_200_000;

fn minWork() u64 {
    const s = std.c.getenv("ESPICE_GPU_MIN_WORK") orelse return default_min_work;
    return std.fmt.parseInt(u64, std.mem.span(s), 10) catch default_min_work;
}

/// `ESPICE_GPU_STATS`: print the gate's work figure and the residency split.
fn statsOn() bool {
    return std.c.getenv("ESPICE_GPU_STATS") != null;
}

/// Names a batch that has a GPU payload but no kernel image in this build and
/// so stays on the host, where it is correct but much slower.
fn reportDemote(on: bool, model: []const u8, which: []const u8, count: u32) void {
    if (!on) return;
    std.debug.print(
        "note: GPU batch '{s}' ({d} instances) stays on the CPU: no {s} kernel image " ++
            "in this build (model over gpu_max_model_bytes, or a stale image)\n",
        .{ model, count, which },
    );
}

/// One batch's resident working set and the kernels that consume it.
const BatchGpu = struct {
    kernel: Raw,
    /// `arp_lim_<model>`: the fused limit/state pass, when the device has one.
    lim_kernel: ?Raw,
    /// `arp_ctl_<model>`: the accepted-step latch pass, when the device
    /// declares `stateCtl`.
    ctl_kernel: ?Raw,
    /// Resident for the simulation. `repack` re-uploads only models and
    /// instances; the tapes never change.
    d_models: Buffer,
    d_instances: Buffer,
    d_gath: Buffer,
    d_rhs_idx: Buffer,
    d_slots: Buffer,
    /// Lim plane (`count * n_u` f64) and `[]D.State`; 1-byte dummies when the
    /// device has neither, so every kernel signature is uniform.
    d_lim: Buffer,
    d_states: Buffer,
    /// The host batch, so `repack` can re-read its parameter arrays.
    ctx: *anyopaque,
    payload: *const fn (*anyopaque) device_ir.GpuPayload,
    set_limit_active: ?*const fn (*anyopaque, bool) void,
    count: u32,
    grid: gompute.Dim3,
    has_lim: bool,
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
        if (self.lim_kernel) |*lk| lk.deinit();
        if (self.ctl_kernel) |*ck| ck.deinit();
        self.kernel.deinit();
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
    /// batches whose model has no image in this build. They stamp the host
    /// planes and the two sides are summed there. Mixed circuits are the
    /// normal case (`vsource` declares `State`), and the split costs one
    /// vector add per plane and no extra bus traffic.
    cpu_batches: []const device_ir.Batch,
    /// Full-length allocations behind `batches` and `cpu_batches`. Demotions
    /// are only known after loading, so both are sized for the worst case and
    /// narrowed; `deinit` frees these, not the narrowed views.
    batches_owned: []BatchGpu,
    cpu_owned: []device_ir.Batch,
    /// Page-locked landing area for the device planes. Separate from the host
    /// planes so the download cannot clobber the CPU batches' stamps, and
    /// pinned so the copies really are asynchronous and drain while the host
    /// stamps (~58 us of a ~100 us iteration on the 100x100 grid). c/q are
    /// empty without `resident_charge`.
    pin_g: []f64,
    pin_rhs: []f64,
    pin_c: []f64,
    pin_q: []f64,
    /// Pinned staging for the `x` upload: a ~2 us memcpy instead of a ~13 us
    /// blocking pageable upload.
    pin_x: []f64,

    d_x: Buffer,
    d_g: Buffer,
    d_c: Buffer,
    d_rhs: Buffer,
    d_q: Buffer,

    /// Deterministic scatter. Kernels write each contribution to its own
    /// staging cell (`d_stage_*`), and `arp_reduce_*` sums each plane cell's
    /// run of cells in the order the serial CPU stamp visits them.
    ///
    /// Atomic accumulation reorders the sum from pass to pass. On
    /// parallel_inverters_2000 the Vdd row takes 8000 contributions that
    /// cancel to 3.6e-9; two replays at the same x differed by 2.1e-10, the
    /// converger rejected every iterate and dt underflowed. In tape order each
    /// instance's +1.8 meets its own -1.8 two entries later and the sum is
    /// exact. With this order the GPU transient matches the CPU one to
    /// 6.0e-16 max over that deck.
    ///
    /// Built beside the frozen tapes, not through them: `d_slots` and
    /// `d_rhs_idx` keep their `[id][ru][cu]` u32 layout and length; only their
    /// values change from plane index to staging index.
    reduce: Raw,
    d_seg1_slot: Buffer,
    d_seg1_row: Buffer,
    d_seg2_slot: Buffer,
    d_seg2_row: Buffer,
    d_stage_g: Buffer,
    d_stage_c: Buffer,
    d_stage_rhs: Buffer,
    d_stage_q: Buffer,
    /// Level-1 reduction output, shared by g and c (and by rhs and q): on one
    /// stream each pair's level 2 consumes it before the next level 1 writes.
    d_mid_slot: Buffer,
    d_mid_row: Buffer,
    /// Contribution counts over the resident batches (g/c index the slots
    /// tape, rhs/q the rhs_idx tape) and the level-1 piece counts.
    n_slot: usize,
    n_row: usize,
    n_vslot: usize,
    n_vrow: usize,
    /// Limit-pass inputs: the new iterate goes to `d_x2`, the previous one to
    /// `d_x`, uploaded explicitly because under JFNK the last eval was a
    /// finite-difference probe. `d_flags` is the word the kernels OR into:
    /// bit 0 limited, bit 1 reject requested.
    d_x2: Buffer,
    d_flags: Buffer,
    pin_x2: []f64,
    pin_flags: []u8,
    /// A resident device requested a step reject, which the GPU path cannot
    /// deliver. Every later call takes the host path.
    poisoned: bool = false,
    /// Host parameters changed; re-upload models and instances before the
    /// next launch. Lazy, so an applyAttempt/restoreModels pair costs one.
    params_dirty: bool = false,

    /// Every copy and launch goes on this stream, never the NULL stream,
    /// which would synchronize with the copies this overlaps. One stream is
    /// enough: an iteration is a strict chain and only the host runs beside it.
    stream: Stream,

    /// One-shot fallback warnings, one per failure kind so neither silences
    /// the other.
    warned_eval: bool = false,
    warned_state: bool = false,

    /// `evalCheck` scratch (g then rhs); non-empty only under
    /// `ESPICE_GPU_EVAL_CHECK`.
    chk: []f64 = &.{},
    /// Worst reproducibility gap printed so far.
    chk_worst: f64 = 0,

    /// Some resident batch produces charge. When none does, the device c/q
    /// planes would only carry zeros, so they are skipped; the host c/q
    /// planes still follow `Circuit.has_charge`.
    resident_charge: bool,

    const Self = @This();

    /// Uploads every eligible batch and keeps it resident. The caller
    /// classifies a failure with `declineKind`.
    ///
    /// `explicit` (the user named the GPU) skips the work gate and reports
    /// every demotion. The gate runs before the first driver call, so a
    /// declined deck never pays for cuInit (~114 ms) or the context retain.
    pub fn init(gpa: std.mem.Allocator, ckt: *Circuit, explicit: bool) !*Self {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        const report = explicit or statsOn();

        var n_gpu: usize = 0;
        var work: u64 = 0;
        for (ckt.batches) |b| {
            const get = b.hooks.gpu_payload orelse continue;
            n_gpu += 1;
            // Only nonlinear (`limit`/`State`) batches count toward the gate.
            // A linear stamp is a vectorized host loop that the GPU only
            // matches (rc_ladder_100k: GPU 3276 ms vs CPU 2698 ms); linear
            // batches still ride along once the context is up. The x16 weight
            // is the eval cost of a dual-number model core against the ~n_u^2
            // scatters the proxy counts.
            if (b.hooks.apply_limits == null and b.hooks.update_state == null) continue;
            const p = get(b.ctx);
            work += @as(u64, p.count) * p.n_u * p.n_u * 16;
        }
        if (n_gpu == 0) return Error.CircuitNotEligible;
        if (!explicit and work < minWork()) return Error.NotEnoughGpuWork;
        if (statsOn()) std.debug.print(
            "gpu-stats: eligible batches={d} nonlinear work={d} (gate {d}{s})\n",
            .{ n_gpu, work, minWork(), if (explicit) ", bypassed: explicit request" else "" },
        );

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        const batches = try gpa.alloc(BatchGpu, n_gpu);
        errdefer gpa.free(batches);
        // Sized for every batch: an eligible model past `gpu_max_model_bytes`
        // has no image and demotes into this array below.
        const cpu_batches = try gpa.alloc(device_ir.Batch, ckt.batches.len);
        errdefer gpa.free(cpu_batches);

        var n_up: usize = 0;
        var n_cpu: usize = 0;
        var resident_charge = false;
        errdefer for (batches[0..n_up]) |*bg| bg.deinit();

        for (ckt.batches) |b| {
            const get = b.hooks.gpu_payload orelse {
                cpu_batches[n_cpu] = b;
                n_cpu += 1;
                continue;
            };
            const bg = &batches[n_up];
            const p = get(b.ctx);
            // A missing image demotes only this batch, so one BSIM4 does not
            // pull ten thousand resistors back to the CPU. Any other driver
            // error is a real fault and fails the context.
            var kernel = gompute.rawKernelByName(backend.?, p.kernel, 0) catch |e| switch (e) {
                error.KernelNotFound => {
                    reportDemote(report, b.type_name, "eval", p.count);
                    cpu_batches[n_cpu] = b;
                    n_cpu += 1;
                    continue;
                },
                else => return e,
            };
            errdefer kernel.deinit();

            // The limit and latch entry points share the eval kernel's image, so
            // one missing means a stale image: demote the whole batch rather
            // than run it half-resident.
            var lim_kernel: ?Raw = null;
            if (p.lim_kernel.len > 0) {
                lim_kernel = gompute.rawKernelByName(backend.?, p.lim_kernel, 0) catch |e| switch (e) {
                    error.KernelNotFound => {
                        reportDemote(report, b.type_name, "limit/state", p.count);
                        kernel.deinit();
                        cpu_batches[n_cpu] = b;
                        n_cpu += 1;
                        continue;
                    },
                    else => return e,
                };
            }
            errdefer if (lim_kernel) |*lk| lk.deinit();

            var ctl_kernel: ?Raw = null;
            if (p.ctl_kernel.len > 0) {
                ctl_kernel = gompute.rawKernelByName(backend.?, p.ctl_kernel, 0) catch |e| switch (e) {
                    error.KernelNotFound => {
                        reportDemote(report, b.type_name, "state-latch", p.count);
                        kernel.deinit();
                        if (lim_kernel) |*lk| lk.deinit();
                        cpu_batches[n_cpu] = b;
                        n_cpu += 1;
                        continue;
                    },
                    else => return e,
                };
            }
            errdefer if (ctl_kernel) |*ck| ck.deinit();

            // One errdefer per buffer: `bg` counts only once it is whole, so
            // a failure part way through frees what this batch already holds.
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
            const d_states = try uploadBytes(&kernel, p.states);

            bg.* = .{
                .kernel = kernel,
                .lim_kernel = lim_kernel,
                .ctl_kernel = ctl_kernel,
                .d_models = d_models,
                .d_instances = d_instances,
                .d_gath = d_gath,
                .d_rhs_idx = d_rhs_idx,
                .d_slots = d_slots,
                .d_lim = d_lim,
                .d_states = d_states,
                .ctx = b.ctx,
                .payload = get,
                .set_limit_active = b.hooks.set_limit_active,
                .count = p.count,
                .grid = gompute.Dim3.linear(p.count, block_size),
                .has_lim = p.lim_x.len > 0,
            };
            resident_charge = resident_charge or b.has_charge;
            n_up += 1;
        }

        // Every eligible batch demoted; `batches[0]` below needs one.
        if (n_up == 0) return Error.CircuitNotEligible;
        if (statsOn()) std.debug.print(
            "gpu-stats: resident batches={d} host batches={d} charge planes={s}\n",
            .{ n_up, n_cpu, if (resident_charge) "device" else "host-only" },
        );

        // Every handle allocates from the same primary context, so buffers
        // made through batch 0 are valid in every launch.
        const k0 = &batches[0].kernel;
        const g_bytes = ckt.g_vals.len * @sizeOf(f64);
        const rhs_bytes = ckt.rhs.len * @sizeOf(f64);
        const x_bytes = (ckt.n + 1) * @sizeOf(f64);

        const order = try scatterOrder(gpa, batches[0..n_up], ckt);
        defer order.deinit(gpa);
        // Same image as the eval kernels, so a miss is a stale build: fatal.
        var reduce = try gompute.rawKernelByName(backend.?, batches[0].payload(batches[0].ctx).reduce_kernel, 0);
        errdefer reduce.deinit();
        try order.upload(batches[0..n_up]);

        // One errdefer per resource, so a failure part way through releases
        // exactly what was made. Pinned memory goes through batch 0's handle,
        // which the batch errdefer above releases after these run.
        const pin_g = try pinnedF64(k0, ckt.g_vals.len);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_g));
        const pin_rhs = try pinnedF64(k0, ckt.rhs.len);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_rhs));
        const pin_c: []f64 = if (resident_charge) try pinnedF64(k0, ckt.c_vals.len) else &.{};
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_c));
        const pin_q: []f64 = if (resident_charge) try pinnedF64(k0, ckt.q_vec.len) else &.{};
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_q));
        const pin_x = try pinnedF64(k0, ckt.n + 1);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_x));
        const pin_x2 = try pinnedF64(k0, ckt.n + 1);
        errdefer k0.freePinned(std.mem.sliceAsBytes(pin_x2));
        const pin_flags = try k0.allocPinned(4);
        errdefer k0.freePinned(pin_flags);
        var d_x = try k0.alloc(x_bytes);
        errdefer d_x.free();
        var d_g = try k0.alloc(g_bytes);
        errdefer d_g.free();
        var d_c = try k0.alloc(g_bytes);
        errdefer d_c.free();
        var d_rhs = try k0.alloc(rhs_bytes);
        errdefer d_rhs.free();
        var d_q = try k0.alloc(rhs_bytes);
        errdefer d_q.free();
        var d_x2 = try k0.alloc(x_bytes);
        errdefer d_x2.free();
        var d_flags = try k0.alloc(4);
        errdefer d_flags.free();
        var d_seg1_slot = try uploadBytes(k0, std.mem.sliceAsBytes(order.seg1_slot));
        errdefer d_seg1_slot.free();
        var d_seg1_row = try uploadBytes(k0, std.mem.sliceAsBytes(order.seg1_row));
        errdefer d_seg1_row.free();
        var d_seg2_slot = try uploadBytes(k0, std.mem.sliceAsBytes(order.seg2_slot));
        errdefer d_seg2_slot.free();
        var d_seg2_row = try uploadBytes(k0, std.mem.sliceAsBytes(order.seg2_row));
        errdefer d_seg2_row.free();
        var d_stage_g = try k0.alloc(@max(order.n_slot, 1) * @sizeOf(f64));
        errdefer d_stage_g.free();
        var d_stage_c = try k0.alloc(@max(order.n_slot, 1) * @sizeOf(f64));
        errdefer d_stage_c.free();
        var d_stage_rhs = try k0.alloc(@max(order.n_row, 1) * @sizeOf(f64));
        errdefer d_stage_rhs.free();
        var d_stage_q = try k0.alloc(@max(order.n_row, 1) * @sizeOf(f64));
        errdefer d_stage_q.free();
        var d_mid_slot = try k0.alloc(@max(order.n_vslot, 1) * @sizeOf(f64));
        errdefer d_mid_slot.free();
        var d_mid_row = try k0.alloc(@max(order.n_vrow, 1) * @sizeOf(f64));
        errdefer d_mid_row.free();
        var stream = try k0.createStream();
        errdefer stream.deinit();
        const chk: []f64 = if (std.c.getenv("ESPICE_GPU_EVAL_CHECK") != null)
            try gpa.alloc(f64, ckt.g_vals.len + ckt.rhs.len)
        else
            &.{};

        self.* = .{
            .gpa = gpa,
            .ckt = ckt,
            .batches = batches[0..n_up],
            .cpu_batches = cpu_batches[0..n_cpu],
            .batches_owned = batches,
            .cpu_owned = cpu_batches,
            .pin_g = pin_g,
            .pin_rhs = pin_rhs,
            .pin_c = pin_c,
            .pin_q = pin_q,
            .pin_x = pin_x,
            .pin_x2 = pin_x2,
            .pin_flags = pin_flags,
            .d_x = d_x,
            .d_g = d_g,
            .d_c = d_c,
            .d_rhs = d_rhs,
            .d_q = d_q,
            .d_x2 = d_x2,
            .d_flags = d_flags,
            .reduce = reduce,
            .d_seg1_slot = d_seg1_slot,
            .d_seg1_row = d_seg1_row,
            .d_seg2_slot = d_seg2_slot,
            .d_seg2_row = d_seg2_row,
            .d_stage_g = d_stage_g,
            .d_stage_c = d_stage_c,
            .d_stage_rhs = d_stage_rhs,
            .d_stage_q = d_stage_q,
            .d_mid_slot = d_mid_slot,
            .d_mid_row = d_mid_row,
            .n_slot = order.n_slot,
            .n_row = order.n_row,
            .n_vslot = order.n_vslot,
            .n_vrow = order.n_vrow,
            .stream = stream,
            .resident_charge = resident_charge,
            .chk = chk,
        };
        return self;
    }

    /// The permutation and segment tables behind the deterministic scatter.
    ///
    /// A contribution is one tape entry, `(batch, id, ru, cu)` for g/c and
    /// `(batch, id, ru)` for rhs/q, numbered in the order the serial CPU stamp
    /// visits them and counting-sorted stably by destination cell. `perm[k]` is
    /// k's staging cell. g and c share the slots tables, rhs and q the row
    /// tables.
    ///
    /// Two levels, because one thread per cell put the whole Vdd row on one
    /// lane (parallel_inverters_500: 0.61 s to 1.38 s, all in the reduction).
    /// Level 1 sums `chunk`-sized pieces of each run, level 2 sums a cell's
    /// pieces, with the same kernel. A run of at most `chunk` is one piece and
    /// sums exactly as the CPU does.
    const Order = struct {
        perm_slot: []u32,
        perm_row: []u32,
        /// Piece -> staging range. Length `n_vslot + 1` / `n_vrow + 1`.
        seg1_slot: []u32,
        seg1_row: []u32,
        /// Plane cell -> piece range. Length `g_vals.len + 1` / `rhs.len + 1`.
        seg2_slot: []u32,
        seg2_row: []u32,
        n_slot: usize,
        n_row: usize,
        n_vslot: usize,
        n_vrow: usize,

        /// Contributions per level-1 piece: an 8000-deep row becomes 125
        /// threads of 64, then one thread of 125.
        const chunk: u32 = 64;

        fn deinit(self: Order, gpa: std.mem.Allocator) void {
            gpa.free(self.perm_slot);
            gpa.free(self.perm_row);
            gpa.free(self.seg1_slot);
            gpa.free(self.seg1_row);
            gpa.free(self.seg2_slot);
            gpa.free(self.seg2_row);
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
    };

    fn scatterOrder(gpa: std.mem.Allocator, batches: []BatchGpu, ckt: *const Circuit) !Order {
        const n_g = ckt.g_vals.len;
        const n_rhs = ckt.rhs.len;
        var n_slot: usize = 0;
        var n_row: usize = 0;
        for (batches) |*bg| {
            const p = bg.payload(bg.ctx);
            n_slot += p.slots.len;
            n_row += p.rhs_idx.len;
        }
        // The u32 tapes now index staging, which is longer than the planes.
        // Past u32 (~32 GB of staging) fall back to the CPU, never truncate.
        if (n_slot > std.math.maxInt(u32) or n_row > std.math.maxInt(u32))
            return Error.CircuitNotEligible;

        var out: Order = .{
            .perm_slot = try gpa.alloc(u32, n_slot),
            .perm_row = try gpa.alloc(u32, n_row),
            .seg1_slot = &.{},
            .seg1_row = &.{},
            .seg2_slot = try gpa.alloc(u32, n_g + 1),
            .seg2_row = try gpa.alloc(u32, n_rhs + 1),
            .n_slot = n_slot,
            .n_row = n_row,
            .n_vslot = 0,
            .n_vrow = 0,
        };
        errdefer out.deinit(gpa);

        // Cell -> staging range before the level-1 cut, and the counting
        // sort's per-cell write cursor.
        const seg_all = try gpa.alloc(u32, @max(n_g, n_rhs) + 1);
        defer gpa.free(seg_all);
        const cursor = try gpa.alloc(u32, @max(n_g, n_rhs) + 1);
        defer gpa.free(cursor);

        for ([_]bool{ true, false }) |slots_pass| {
            const n_cells = if (slots_pass) n_g else n_rhs;
            const seg = seg_all[0 .. n_cells + 1];
            const perm = if (slots_pass) out.perm_slot else out.perm_row;
            // The trash cell gets an empty run, so the reduction writes it 0
            // without walking it. It collects every ground and structurally
            // dead entry (~40k of 64k slots on a 4000-instance mos1 batch), and
            // nothing reads it.
            const trash: u32 = if (slots_pass) ckt.trash_slot else ckt.n;
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
            @memcpy(cursor[0..seg.len], seg);
            // The kernel stores through the tape unconditionally, so trash
            // contributions still get distinct cells: the staging tail, which
            // no segment covers.
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

            // Cut each run into pieces of at most `chunk`. `seg2[i]` is cell
            // i's first piece, `seg1[j]` piece j's first staging cell; both
            // ascend, so both sums keep a fixed order.
            var n_v: usize = 0;
            for (0..n_cells) |i| n_v += (seg[i + 1] - seg[i] + Order.chunk - 1) / Order.chunk;
            const seg1 = try gpa.alloc(u32, n_v + 1);
            const seg2 = if (slots_pass) out.seg2_slot else out.seg2_row;
            var j: usize = 0;
            for (0..n_cells) |i| {
                seg2[i] = @intCast(j);
                var at = seg[i];
                while (at < seg[i + 1]) : (at += Order.chunk) {
                    seg1[j] = at;
                    j += 1;
                }
            }
            seg2[n_cells] = @intCast(j);
            seg1[n_v] = seg[n_cells];
            if (slots_pass) {
                out.seg1_slot = seg1;
                out.n_vslot = n_v;
            } else {
                out.seg1_row = seg1;
                out.n_vrow = n_v;
            }
        }
        return out;
    }

    /// Page-locked `[]f64` from the driver; release with `freePinned`.
    fn pinnedF64(kernel: *Raw, n: usize) ![]f64 {
        const bytes = try kernel.allocPinned(n * @sizeOf(f64));
        return @alignCast(std.mem.bytesAsSlice(f64, bytes));
    }

    /// Frees every device and pinned buffer and `self`.
    pub fn deinit(self: *Self) void {
        if (comptime backend == null) return;
        // Pinned memory first, while batch 0's handle that owns it is alive.
        const k0 = &self.batches[0].kernel;
        for ([_][]f64{ self.pin_g, self.pin_rhs, self.pin_c, self.pin_q, self.pin_x, self.pin_x2 }) |p| {
            if (p.len > 0) k0.freePinned(std.mem.sliceAsBytes(p));
        }
        k0.freePinned(self.pin_flags);
        self.stream.deinit();
        self.d_x.free();
        self.d_g.free();
        self.d_c.free();
        self.d_rhs.free();
        self.d_q.free();
        self.d_x2.free();
        self.d_flags.free();
        self.d_seg1_slot.free();
        self.d_seg1_row.free();
        self.d_seg2_slot.free();
        self.d_seg2_row.free();
        self.d_stage_g.free();
        self.d_stage_c.free();
        self.d_stage_rhs.free();
        self.d_stage_q.free();
        self.d_mid_slot.free();
        self.d_mid_row.free();
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

    /// Stamps all four planes: the resident batches on the device, the rest on
    /// the host meanwhile, then sums them and adds the ground pin. Always zero
    /// and restamp, never the constant-Jacobian baseline. Limit devices read
    /// their resident lim plane while `lim_active`, like the host eval.
    fn evalOnGpu(self: *Self, x: []const f64, t: f64) !void {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        const ckt = self.ckt;

        try self.enqueueEval(x, t);

        ckt.clearPlanes(.full);
        const pl = ckt.ownPlanes();
        for (self.cpu_batches) |b| b.eval(b.ctx, &pl, 0, b.count, x, t);

        // This stream only: a context-wide sync would also wait on work this
        // process does not own.
        try self.stream.synchronize();

        if (self.chk.len > 0) try self.evalCheck(x, t);

        addSimd(ckt.g_vals, self.pin_g);
        addSimd(ckt.rhs, self.pin_rhs);
        if (self.resident_charge) {
            addSimd(ckt.c_vals, self.pin_c);
            addSimd(ckt.q_vec, self.pin_q);
        }

        ckt.groundStamp(x);
    }

    /// Enqueues the device half without waiting: upload x, clear staging,
    /// launch every resident batch, reduce, download into the pinned planes.
    /// The downloads are queued before the caller's host work so they drain
    /// during it. Separate so `evalCheck` can replay the same pass.
    fn enqueueEval(self: *Self, x: []const f64, t: f64) !void {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        const ckt = self.ckt;
        const g_bytes = ckt.g_vals.len * @sizeOf(f64);
        const rhs_bytes = ckt.rhs.len * @sizeOf(f64);

        @memcpy(self.pin_x[0..x.len], x);
        try self.d_x.uploadAtAsync(self.pin_x.ptr, 0, x.len * @sizeOf(f64), &self.stream);

        // Staging, not the planes: the reduction writes every plane cell, but
        // a contribution the pattern or ground mask skips is never stored and
        // must read back as 0.
        try self.d_stage_g.fillAsync(0, self.n_slot * @sizeOf(f64), &self.stream);
        try self.d_stage_rhs.fillAsync(0, self.n_row * @sizeOf(f64), &self.stream);
        if (self.resident_charge) {
            try self.d_stage_c.fillAsync(0, self.n_slot * @sizeOf(f64), &self.stream);
            try self.d_stage_q.fillAsync(0, self.n_row * @sizeOf(f64), &self.stream);
        }

        for (self.batches) |*bg| {
            if (bg.count == 0) continue;
            try syncSeededLim(bg);
            // Scalars are passed by pointer and must outlive the launch call.
            var count: u64 = bg.count;
            var time: f64 = t;
            var limiting: u64 = @intFromBool(bg.lim_active);
            try bg.kernel.launchOn(&self.stream, bg.grid, .{ .x = block_size }, 0, &.{
                gompute.interface.arg(&count),
                gompute.interface.arg(&time),
                self.d_x.argPtr(),
                bg.d_gath.argPtr(),
                bg.d_rhs_idx.argPtr(),
                bg.d_slots.argPtr(),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                self.d_stage_g.argPtr(),
                self.d_stage_c.argPtr(),
                self.d_stage_rhs.argPtr(),
                self.d_stage_q.argPtr(),
                bg.d_lim.argPtr(),
                gompute.interface.arg(&limiting),
            });
        }

        try self.reducePlane(true, &self.d_stage_g, &self.d_g, ckt.g_vals.len);
        try self.reducePlane(false, &self.d_stage_rhs, &self.d_rhs, ckt.rhs.len);
        if (self.resident_charge) {
            try self.reducePlane(true, &self.d_stage_c, &self.d_c, ckt.c_vals.len);
            try self.reducePlane(false, &self.d_stage_q, &self.d_q, ckt.q_vec.len);
        }

        try self.d_g.downloadAtAsync(self.pin_g.ptr, 0, g_bytes, &self.stream);
        try self.d_rhs.downloadAtAsync(self.pin_rhs.ptr, 0, rhs_bytes, &self.stream);
        if (self.resident_charge) {
            try self.d_c.downloadAtAsync(self.pin_c.ptr, 0, g_bytes, &self.stream);
            try self.d_q.downloadAtAsync(self.pin_q.ptr, 0, rhs_bytes, &self.stream);
        }
    }

    /// Reduces one plane's staging into the plane: pieces first, then each
    /// cell's pieces. `slot_space` selects the slots tables (g/c) over the
    /// row tables (rhs/q).
    fn reducePlane(self: *Self, slot_space: bool, stage: *Buffer, plane: *Buffer, cells: usize) !void {
        const mid = if (slot_space) &self.d_mid_slot else &self.d_mid_row;
        const seg1 = if (slot_space) &self.d_seg1_slot else &self.d_seg1_row;
        const seg2 = if (slot_space) &self.d_seg2_slot else &self.d_seg2_row;
        const n_v = if (slot_space) self.n_vslot else self.n_vrow;
        try self.launchReduce(seg1, stage, mid, n_v);
        try self.launchReduce(seg2, mid, plane, cells);
    }

    /// One `arp_reduce_*` launch: `plane[i] = sum(stage[seg[i]..seg[i+1]])`.
    fn launchReduce(self: *Self, seg: *Buffer, stage: *Buffer, plane: *Buffer, cells: usize) !void {
        if (cells == 0) return;
        var n_cells: u64 = cells;
        try self.reduce.launchOn(
            &self.stream,
            gompute.Dim3.linear(cells, block_size),
            .{ .x = block_size },
            0,
            &.{ gompute.interface.arg(&n_cells), seg.argPtr(), stage.argPtr(), plane.argPtr() },
        );
    }

    /// `ESPICE_GPU_EVAL_CHECK`: replays the device pass at the same x and
    /// prints the worst g/rhs entry that moved, when it beats the last record.
    /// Newton cannot converge on a stamp that is not a function of x, so any
    /// output here means the deterministic scatter regressed. Restores the
    /// first pass, so a checked run stamps what an unchecked one would.
    fn evalCheck(self: *Self, x: []const f64, t: f64) !void {
        if (comptime backend == null) return Error.NoGpuArtifacts;
        const ng = self.pin_g.len;
        const chk_g = self.chk[0..ng];
        const chk_rhs = self.chk[ng..];
        @memcpy(chk_g, self.pin_g);
        @memcpy(chk_rhs, self.pin_rhs);

        try self.enqueueEval(x, t);
        try self.stream.synchronize();

        var worst: f64 = 0;
        var where: usize = 0;
        var plane: []const u8 = "g";
        for (chk_g, self.pin_g, 0..) |a, b, i| {
            const d = @abs(a - b);
            if (d > worst) {
                worst = d;
                where = i;
                plane = "g";
            }
        }
        for (chk_rhs, self.pin_rhs, 0..) |a, b, i| {
            const d = @abs(a - b);
            if (d > worst) {
                worst = d;
                where = i;
                plane = "rhs";
            }
        }
        if (worst > self.chk_worst) {
            self.chk_worst = worst;
            std.debug.print(
                "gpu-check: eval is not reproducible at t={e:.6}: |Δ{s}[{d}]|={e:.3} (was {e:.16}, now {e:.16})\n",
                .{ t, plane, where, worst, if (std.mem.eql(u8, plane, "g")) chk_g[where] else chk_rhs[where], if (std.mem.eql(u8, plane, "g")) self.pin_g[where] else self.pin_rhs[where] },
            );
        }

        @memcpy(self.pin_g, chk_g);
        @memcpy(self.pin_rhs, chk_rhs);
    }

    /// The `eval_planes` hook. No analysis can unwind from a driver fault
    /// mid-solve, so a failure restamps on the CPU and warns once.
    fn evalPlanes(ctx: *anyopaque, x: []const f64, t: f64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.evalOnGpu(x, t) catch |e| {
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
    fn applyLimitsOnGpu(self: *Self, x: []f64, x_old: []const f64) !bool {
        if (comptime backend == null) return false;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        const n = self.ckt.n;

        @memcpy(self.pin_x2[0..n], x[0..n]);
        try self.d_x2.uploadAtAsync(self.pin_x2.ptr, 0, n * @sizeOf(f64), &self.stream);
        @memcpy(self.pin_x[0..n], x_old[0..n]);
        try self.d_x.uploadAtAsync(self.pin_x.ptr, 0, n * @sizeOf(f64), &self.stream);
        try self.d_flags.fillAsync(0, 4, &self.stream);

        var launched = false;
        for (self.batches) |*bg| {
            const lk = if (bg.lim_kernel) |*k| k else continue;
            if (bg.count == 0) continue;
            try syncSeededLim(bg);
            var count: u64 = bg.count;
            var lim_active: u64 = @intFromBool(bg.lim_active);
            try lk.launchOn(&self.stream, bg.grid, .{ .x = block_size }, 0, &.{
                gompute.interface.arg(&count),
                self.d_x2.argPtr(),
                self.d_x.argPtr(),
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
            try self.stream.synchronize();
            const flags = std.mem.readInt(u32, self.pin_flags[0..4], .little);
            if (flags & 2 != 0) {
                // A step reject the GPU path cannot deliver: `gpuEligible`
                // admitted a device it should not have.
                self.poisoned = true;
                return error.GpuStateReject;
            }
            if (flags & 1 != 0) any = true;
        }
        return any;
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

    fn clearLimitsHook(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
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
    /// ponytail: a later `repack` resets device pb/pq to the host's stale
    /// copies. Harmless today (repacks happen only before a transient or in
    /// static sweeps); a mid-transient repack would need the instances
    /// downloaded first.
    fn stateCtlOnGpu(self: *Self, op: device_ir.StateCtlOp) !bool {
        if (comptime backend == null) return false;
        if (self.poisoned) return error.GpuStateReject;
        if (self.params_dirty) try self.repack();
        var launched = false;
        for (self.batches) |*bg| {
            const ck = if (bg.ctl_kernel) |*k| k else continue;
            if (bg.count == 0) continue;
            if (!launched) try self.d_flags.fillAsync(0, 4, &self.stream);
            var count: u64 = bg.count;
            var opv: u64 = @intFromEnum(op);
            try ck.launchOn(&self.stream, bg.grid, .{ .x = block_size }, 0, &.{
                gompute.interface.arg(&count),
                bg.d_models.argPtr(),
                bg.d_instances.argPtr(),
                bg.d_states.argPtr(),
                gompute.interface.arg(&opv),
                self.d_flags.argPtr(),
            });
            launched = true;
        }
        // Queued before the host walk so it drains meanwhile, and so a failed
        // enqueue happens before the walk: the fallback re-walks every batch,
        // and the path commit `pq += wq` is not idempotent.
        if (launched)
            try self.d_flags.downloadAtAsync(self.pin_flags.ptr, 0, 4, &self.stream);

        var dirty = Circuit.stateCtlBatches(self.cpu_batches, op);
        if (launched) {
            try self.stream.synchronize();
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
        Circuit.seedBatches(self.ckt.batches, x);
        for (self.batches) |*bg| {
            if (bg.has_lim) bg.lim_dirty = true;
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
        try self.stream.synchronize();
        for (self.batches) |*batch| {
            const payload = batch.payload(batch.ctx);
            if (payload.instances.len != 0)
                try batch.d_instances.download(@constCast(payload.instances.ptr), payload.instances.len);
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
        self.params_dirty = true;
    }

    /// Returns the dispatch table to install as `Circuit.gpu_hook`.
    pub fn hook(self: *Self) GpuHook {
        return .{
            .ctx = self,
            .eval_planes = evalPlanes,
            .apply_limits = applyLimitsHook,
            .update_states = updateStatesHook,
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
