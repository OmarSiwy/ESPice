//! gpu_context.zig — device evaluation on the GPU, solver on the CPU.
//!
//! The split is deliberate and it is the whole design:
//!
//!   - The CIRCUIT LIVES ON THE GPU. Every batch's models, instances and
//!     gather/scatter tapes are uploaded ONCE at construction and stay resident
//!     for the life of the simulation. They are frozen data — the tapes are
//!     pattern, and the parameter arrays only move when a sweep mutates one,
//!     which is what `repack` is for.
//!   - The SOLVER stays on the CPU. Sparse LU, the Newton update, the
//!     convergence test: all `solvers/`, unchanged, because factorization is
//!     the part a GPU is worst at and the part this tree already does well.
//!
//! So per Newton iteration the bus carries the state vector up and the value
//! planes down, and nothing else:
//!
//!     x  ──H2D──▶  [ resident models · instances · tapes ]
//!                            │ one arp_eval_<model> launch per batch
//!                            ▼
//!     g_vals, rhs  ◀──D2H──  [ atomic-scattered planes ]
//!                            │
//!                            ▼  CPU: gmin, LU, dx, convergence
//!
//! That round-trip is the floor for a CPU solver, and it is why this pays off
//! on device COUNT and not on circuit size: a fixture with four resistors moves
//! the same bytes as one with four hundred thousand, and only the second has
//! enough eval work to hide the latency. `--gpu` on a small netlist is expected
//! to LOSE to the CPU path, and the benchmark reports both rather than picking.
//!
//! Scope (this cut): whole-circuit device eval feeding a CPU Newton solve. The
//! batch and frequency-domain hooks on `GpuHook` stay null — see `hook()`.

const std = @import("std");
const analysis = @import("analysis");
const devices = @import("devices");
const solvers = @import("solvers");
const gompute = @import("gompute");

const Circuit = analysis.Circuit;
const GpuHook = analysis.GpuHook;
const converger = solvers.converger;

/// Which backend this binary actually carries images for. Decided at COMPILE
/// time because `gompute.RawByName(.cuda)` is a compile error in a build that
/// emitted no CUDA artifacts — a runtime `if` would not save us from naming it.
const artifacts = @import("gompute_kernels");
const backend: ?gompute.Backend = if (artifacts.has_cuda)
    .cuda
else if (artifacts.has_hip)
    .hip
else
    null;

/// The GPU backend this binary carries images for, or null. Public so the CLI
/// can name it when a `--backend cuda|hip` request cannot be honoured.
pub const detected: ?gompute.Backend = backend;

/// What `--backend` can ask for. `auto` is the opt-in that preserves the old
/// `--gpu` semantics: try the device, fall back to the CPU. `cuda`/`hip` are
/// strict — a request this binary cannot honour is a hard error, not a
/// silent CPU run.
pub const Request = enum { cpu, auto, cuda, hip };

/// A one-word name for what this binary detected, for the mismatch message.
pub fn detectedName() []const u8 {
    return if (backend) |be| @tagName(be) else "none";
}

/// Reject a strict `--backend cuda|hip` that this binary cannot honour, BEFORE
/// any simulation runs. `auto`/`cpu` always pass here — auto falls back at
/// run time, cpu never touches the GPU. Returns false and prints the mismatch
/// (naming what WAS detected) when a named backend is absent.
pub fn requestSupported(req: Request) bool {
    return switch (req) {
        .cpu, .auto => true,
        .cuda => backend == .cuda,
        .hip => backend == .hip,
    };
}

/// `void` in a build with no device images, so nothing below names a type that
/// does not exist. Every use is behind `comptime backend != null`.
const Raw = if (backend) |be| gompute.RawByName(be) else void;
const Buffer = if (backend != null) Raw.Buffer else void;

/// Must match `devices/kernels.zig`, which sized the launch when it exported
/// the kernels: `DeviceKernel(D, block_size)` bakes the block width into
/// `globalIdX`, so a host that launches a different one indexes wrong.
const block_size: u32 = devices.kernels.block_size;

pub const Error = error{
    /// This binary carries no GPU images — the arch probe found no device on
    /// the build machine, so `emitKernels` emitted nothing.
    NoGpuArtifacts,
    /// NO device type in this circuit has a GPU kernel, so there is nothing to
    /// move. See `engine.gpuEligible`.
    CircuitNotEligible,
    /// The circuit HAS eligible devices, but too few to pay for the round trip.
    /// See `min_work`.
    NotEnoughGpuWork,
};

/// Scatter work — `count * n_u^2` summed over the eligible batches — below which
/// `init` declines before touching the driver.
///
/// `n_u^2` is the number of `atom.global.add.f64` a batch issues per iteration,
/// and for the simple devices that are eligible today the atomics ARE the
/// kernel: measured on an RTX 4060 Laptop, 6 atomics x 20 K instances is 9.5 us
/// and x 200 K is 76 us, against a ~100 us per-iteration round trip (pageable
/// upload + 4 plane copies + full-device sync + two downloads). So the GPU does
/// not start winning until the atomic count clears a few hundred thousand.
///
/// ponytail: an atomic-count proxy, not a cost model. It is exactly right for
/// the devices `gpuEligible` admits today (linear and algebraic two- and
/// three-terminal parts, tens of f64 ops each) and it UNDERSTATES a future
/// nonlinear kernel, which does thousands of f64 ops per instance and would
/// break even far sooner. Revisit when a compact model becomes eligible; a
/// per-device cost weight from the emitted PTX size is the upgrade path.
///
/// Tunable because the break-even moves with the per-iteration overhead: P1
/// (pinned async copies, device-side baseline) drops it by roughly 5x.
const default_min_work: u64 = 200_000;

fn minWork() u64 {
    const s = std.c.getenv("ESPICE_GPU_MIN_WORK") orelse return default_min_work;
    return std.fmt.parseInt(u64, std.mem.span(s), 10) catch default_min_work;
}

/// One batch's resident working set plus the kernel that consumes it.
const BatchGpu = struct {
    kernel: Raw,
    /// `arp_lim_<model>` — the fused limit/state pass (`engine.StateKernel`),
    /// present iff the device pairs one with its eval kernel.
    lim_kernel: ?Raw,
    /// `arp_ctl_<model>` — the accepted-step latch pass (`engine.CtlKernel`),
    /// present iff the device declares `stateCtl`.
    ctl_kernel: ?Raw,
    /// Resident for the life of the simulation. `models`/`instances` are the
    /// only two `repack` re-uploads; the tapes never change.
    d_models: Buffer,
    d_instances: Buffer,
    d_gath: Buffer,
    d_rhs_idx: Buffer,
    d_slots: Buffer,
    /// Device lim plane (count * n_u f64) and `[]D.State`. 1-byte dummies
    /// when the device carries neither — every kernel signature is uniform.
    d_lim: Buffer,
    d_states: Buffer,
    /// The batch this came from, so `repack` can re-read its parameter arrays.
    ctx: *anyopaque,
    payload: *const fn (*anyopaque) devices.batch.GpuPayload,
    count: u32,
    n_u: u32,
    grid: gompute.Dim3,
    has_lim: bool,
    has_state: bool,
    /// Device-era limiting flag: true once the device lim plane holds live
    /// clamp state (seed upload or first StateKernel launch). Cleared by
    /// `clearLimits`, mirroring the host batch's `lim_active`.
    lim_active: bool = false,
    /// A host-side `seedJunctions` wrote fresh seed voltages into the batch's
    /// host lim plane; upload it before the next launch that reads it.
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

pub const GpuContext = struct {
    gpa: std.mem.Allocator,
    ckt: *Circuit,
    /// The eligible batches, resident on the device.
    batches: []BatchGpu,
    /// The rest — anything with `limit`, `State`, history or a `PrepCache`,
    /// plus anything eligible whose model the build declined to emit a kernel
    /// for (`gpu_max_model_bytes`).
    /// They keep stamping the host planes, and the two sets are summed.
    ///
    /// A mixed circuit is the NORMAL case, not a corner: `vsource` declares
    /// `State`, so an all-or-nothing rule would decline every netlist with a
    /// voltage source in it — which is all of them. Splitting costs one vector
    /// add over `nnz` per iteration and no extra bus traffic, because the two
    /// sides scatter into different planes and only meet on the host.
    cpu_batches: []const devices.batch.Batch,
    /// The two allocations `batches` and `cpu_batches` are sub-slices of.
    ///
    /// A batch demoted at load time (no image for its model) moves from one set
    /// to the other, so neither final length is known when the arrays are sized
    /// — they are allocated for the worst case and then narrowed. `deinit` frees
    /// THESE, because an allocator sizes a free by the slice it is handed and
    /// the narrowed views would under-report.
    batches_owned: []BatchGpu,
    cpu_owned: []devices.batch.Batch,
    /// Landing area for the device planes, so the download does not clobber
    /// what the CPU batches stamped — and PAGE-LOCKED, which is what lets the
    /// download be issued before the CPU batches run instead of after them.
    ///
    /// `cuMemcpyDtoHAsync` on pageable memory is asynchronous in name only: the
    /// driver stages it through an internal pinned buffer and blocks. Pinned,
    /// the four downloads are queued behind the launches and drain while the
    /// host is busy, so their latency leaves the critical path entirely. On the
    /// 100x100 grid that is ~58 us of the ~100 us iteration.
    ///
    /// One allocation per plane rather than one block with offsets: pinning is
    /// an init-time cost either way, and the sizes differ (g/c are `nnz`, rhs/q
    /// are `n`).
    pin_g: []f64,
    pin_rhs: []f64,
    pin_c: []f64,
    pin_q: []f64,
    /// Staging for the one upload. `x` arrives as ordinary pageable memory from
    /// the converger, so it is copied here first — a ~2 us `memcpy` against the
    /// ~13 us the blocking pageable upload used to cost.
    pin_x: []f64,

    /// Per-iteration traffic, allocated once.
    d_x: Buffer,
    d_g: Buffer,
    d_c: Buffer,
    d_rhs: Buffer,
    d_q: Buffer,
    /// `applyLimits`-time state vectors: the NEW iterate goes to `d_x2`, the
    /// previous one to `d_x` (uploaded explicitly — under JFNK the last eval
    /// was an FD probe, so `d_x`'s residue is NOT x_old). Plus the 4-byte
    /// limited/reject flag word the StateKernels OR into.
    d_x2: Buffer,
    d_flags: Buffer,
    pin_x2: []f64,
    pin_flags: []u8,
    /// A StateKernel reported a `request_reject_at` the GPU path cannot
    /// honour (`flags` bit 1) — the class assumption behind `gpuEligible`
    /// broke. Every later call takes the CPU path, loudly.
    poisoned: bool = false,
    /// Host params mutated (`Circuit.markGpuDirty`); re-upload models and
    /// instances before the next launch. Lazy so an applyAttempt/restore
    /// pair costs one repack, not two.
    params_dirty: bool = false,

    /// Every copy and every launch is ordered here, and NOTHING uses the NULL
    /// stream.
    ///
    /// That is not a style preference: the NULL stream implicitly synchronizes
    /// with every other blocking stream, so leaving the launches on it would
    /// serialize them against the very copies this is trying to overlap. One
    /// stream is enough — the work within an iteration is a strict chain
    /// (upload -> zero -> launch -> download) and the only thing that needs to
    /// run alongside it is the HOST, which is not on a stream at all.
    stream: Raw.Stream,

    /// The CPU half. Its own workspace because `solve_newton` is reached
    /// through `GpuHook`, which carries no allocator and no analysis state —
    /// the caller's own `Workspace` is not on the path.
    ws: converger.Workspace,

    /// Set by `assemble`, which cannot fail in the converger's hook shape.
    /// Checked after the loop so a driver fault falls back to the CPU instead
    /// of returning a converged-looking answer built on a failed launch.
    launch_err: ?anyerror = null,
    /// One-shot latch for the `evalPlanes` CPU-fallback warning.
    warned_fallback: bool = false,

    has_charge: bool,

    const Self = @This();

    /// Upload every eligible batch and keep it resident. Fails (and the caller
    /// falls back to the CPU) when NOTHING in the circuit has a kernel, or when
    /// what does have one is too small to pay for the bus.
    ///
    /// Both refusals happen BEFORE the first `gompute` call, which is what makes
    /// `cuInit` lazy: on this machine the driver charges 113.7 ms for `cuInit`
    /// and 80.7 ms to retain the primary context, and a netlist that was never
    /// going to the GPU used to pay all of it just for passing `--gpu`.
    pub fn init(gpa: std.mem.Allocator, ckt: *Circuit) !*Self {
        if (comptime backend == null) return Error.NoGpuArtifacts;

        var n_gpu: usize = 0;
        var work: u64 = 0;
        for (ckt.batches) |b| {
            const get = b.hooks.gpu_payload orelse continue;
            n_gpu += 1;
            // Only NONLINEAR batches (a `limit`/`State` device: junction
            // FETs, BJTs, diodes) count toward the gate. A linear stamp is
            // ~10 f64 ops on the CPU, so offloading it trades a vectorized
            // host loop for the same atomics plus the bus — measured on
            // rc_ladder_100k, the largest all-linear fixture in the corpus
            // (200k devices, 800k atomic-work): GPU 3276 ms vs CPU 2698 ms.
            // Bigger only makes the planes' D2H larger. Linear batches still
            // RIDE ALONG once nonlinear work engages the context; only the
            // go/no-go decision ignores them.
            //
            // The x16 weight is the eval-cost ratio: a limit-class eval runs
            // its model core in 8-16 wide dual arithmetic (hundreds of f64
            // ops) against the ~n_u^2 atomics the proxy counts.
            if (b.hooks.apply_limits == null and b.hooks.update_state == null) continue;
            // Host-side read of the batch's own slices. No driver contact.
            const p = get(b.ctx);
            work += @as(u64, p.count) * p.n_u * p.n_u * 16;
        }
        if (n_gpu == 0) return Error.CircuitNotEligible;
        if (work < minWork()) return Error.NotEnoughGpuWork;

        const self = try gpa.create(Self);
        errdefer gpa.destroy(self);

        const batches = try gpa.alloc(BatchGpu, n_gpu);
        errdefer gpa.free(batches);
        // Sized for EVERY batch, not `len - n_gpu`: a device can be eligible by
        // `gpuEligible` and still have no image, because the build declines to
        // emit a kernel for a model past `gpu_max_model_bytes`. Those demote
        // into this array below, so its final length is not known up front.
        const cpu_batches = try gpa.alloc(devices.batch.Batch, ckt.batches.len);
        errdefer gpa.free(cpu_batches);

        var n_up: usize = 0;
        var n_cpu: usize = 0;
        errdefer for (batches[0..n_up]) |*bg| bg.deinit();

        for (ckt.batches) |b| {
            const get = b.hooks.gpu_payload orelse {
                cpu_batches[n_cpu] = b;
                n_cpu += 1;
                continue;
            };
            const bg = &batches[n_up];
            const p = get(b.ctx);
            // A MISSING kernel demotes this batch; it does not fail the context.
            // The compact models are excluded from GPU emission at build time
            // (see `gpu_max_model_bytes`), and an all-or-nothing rule here would
            // mean one BSIM4 in a netlist also pulled its ten thousand resistors
            // back onto the CPU. Any other driver error is still fatal — that is
            // a real fault, not a device the build chose to skip.
            var kernel = gompute.rawKernelByName(backend.?, p.kernel, 0) catch |e| switch (e) {
                error.KernelNotFound => {
                    cpu_batches[n_cpu] = b;
                    n_cpu += 1;
                    continue;
                },
                else => return e,
            };
            errdefer kernel.deinit();

            // The paired limit/state/ctl entry points live in the SAME image,
            // so "eval found, one missing" can only mean a stale image —
            // demote the batch whole rather than run it half-resident.
            var lim_kernel: ?Raw = null;
            if (p.lim_kernel.len > 0) {
                lim_kernel = gompute.rawKernelByName(backend.?, p.lim_kernel, 0) catch |e| switch (e) {
                    error.KernelNotFound => {
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

            bg.* = .{
                .kernel = kernel,
                .lim_kernel = lim_kernel,
                .ctl_kernel = ctl_kernel,
                .d_models = try uploadBytes(&kernel, p.models),
                .d_instances = try uploadBytes(&kernel, p.instances),
                .d_gath = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.gath)),
                .d_rhs_idx = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.rhs_idx)),
                .d_slots = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.slots)),
                // The lim plane starts UNWRITTEN on purpose — reads are gated
                // by `lim_active`, exactly like the host's `lim_x`. 1-byte
                // dummy for limit-less devices (uniform kernel signature).
                .d_lim = try kernel.alloc(if (p.lim_x.len > 0) @as(usize, p.count) * p.n_u * @sizeOf(f64) else 1),
                .d_states = try uploadBytes(&kernel, p.states),
                .ctx = b.ctx,
                .payload = get,
                .count = p.count,
                .n_u = p.n_u,
                .grid = gompute.Dim3.linear(p.count, block_size),
                .has_lim = p.lim_x.len > 0,
                .has_state = p.states.len > 0,
            };
            n_up += 1;
        }

        // Every eligible batch demoted for want of an image, so there is nothing
        // left to launch. Ordered before `batches[0]` below, which would
        // otherwise index an empty array.
        if (n_up == 0) return Error.CircuitNotEligible;

        // Any handle allocates from the same primary context, so the planes may
        // hang off batch 0 and still be valid in every other batch's launch.
        const k0 = &batches[0].kernel;
        const g_bytes = ckt.g_vals.len * @sizeOf(f64);
        const rhs_bytes = ckt.rhs.len * @sizeOf(f64);
        const x_bytes = (ckt.n + 1) * @sizeOf(f64);

        self.* = .{
            .gpa = gpa,
            .ckt = ckt,
            .batches = batches[0..n_up],
            .cpu_batches = cpu_batches[0..n_cpu],
            .batches_owned = batches,
            .cpu_owned = cpu_batches,
            .pin_g = try pinnedF64(k0, ckt.g_vals.len),
            .pin_rhs = try pinnedF64(k0, ckt.rhs.len),
            .pin_c = if (ckt.has_charge) try pinnedF64(k0, ckt.c_vals.len) else &.{},
            .pin_q = if (ckt.has_charge) try pinnedF64(k0, ckt.q_vec.len) else &.{},
            .pin_x = try pinnedF64(k0, ckt.n + 1),
            .pin_x2 = try pinnedF64(k0, ckt.n + 1),
            .pin_flags = try k0.allocPinned(4),
            .d_x = try k0.alloc(x_bytes),
            .d_g = try k0.alloc(g_bytes),
            .d_c = try k0.alloc(g_bytes),
            .d_rhs = try k0.alloc(rhs_bytes),
            .d_q = try k0.alloc(rhs_bytes),
            .d_x2 = try k0.alloc(x_bytes),
            .d_flags = try k0.alloc(4),
            .stream = try k0.createStream(),
            .ws = try converger.Workspace.init(gpa, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd),
            .has_charge = ckt.has_charge,
        };

        return self;
    }

    /// Page-locked `[]f64` from the driver. Not the Zig allocator's memory, so
    /// it is released with `freePinned` and not `gpa.free`.
    fn pinnedF64(kernel: *Raw, n: usize) ![]f64 {
        const bytes = try kernel.allocPinned(n * @sizeOf(f64));
        return @alignCast(std.mem.bytesAsSlice(f64, bytes));
    }

    pub fn deinit(self: *Self) void {
        if (comptime backend == null) return;
        // Pinned memory first, while batch 0's context handle is still alive —
        // it is what the driver frees these against.
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
        for (self.batches) |*bg| bg.deinit();
        self.gpa.free(self.batches_owned);
        self.gpa.free(self.cpu_owned);
        self.ws.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn uploadBytes(kernel: *Raw, bytes: []const u8) !Buffer {
        // A device type with no parameters, or a zero-instance batch, still
        // needs a valid pointer to pass as a kernel argument; drivers reject a
        // zero-byte allocation.
        var buf = try kernel.alloc(@max(bytes.len, 1));
        errdefer buf.free();
        if (bytes.len > 0) try buf.upload(bytes.ptr, bytes.len);
        return buf;
    }

    /// One full device-eval pass: the GPU half of `Circuit.evalNewton`.
    ///
    /// Always the zero-and-restamp form, never the constant-Jacobian baseline
    /// (an optimization traded for keeping the planes on the device). Limit
    /// devices eval against their device-resident lim plane exactly like the
    /// host's `evalInner`: `limiting` mirrors the batch's `lim_active`, which
    /// `StateKernel` launches arm and `clearLimits` disarms — so outside a
    /// Newton solve this is the plain eval both ways.
    fn evalOnGpu(self: *Self, x: []const f64, t: f64) !void {
        if (self.poisoned) return error.GpuStateReject;
        try self.flushDirtyParams();
        const ckt = self.ckt;
        const g_bytes = ckt.g_vals.len * @sizeOf(f64);
        const rhs_bytes = ckt.rhs.len * @sizeOf(f64);

        // Everything below is enqueued on one stream and nothing is waited on
        // until the single `synchronize` at the bottom. The ORDER of the calls
        // is the whole optimization: the downloads are issued BEFORE the host
        // does its own work, so they drain during it instead of after it.

        @memcpy(self.pin_x[0..x.len], x);
        try self.d_x.uploadAtAsync(self.pin_x.ptr, 0, x.len * @sizeOf(f64), &self.stream);

        // Zeroed by the memory controller, not by moving a resident block of
        // zeros across it. The old D2D copy cost real device bandwidth (~3.8 us
        // for a 400 KB `g` plane, ~1.9 us for `rhs`) and blocked besides.
        try self.d_g.fillAsync(0, g_bytes, &self.stream);
        try self.d_rhs.fillAsync(0, rhs_bytes, &self.stream);
        if (self.has_charge) {
            try self.d_c.fillAsync(0, g_bytes, &self.stream);
            try self.d_q.fillAsync(0, rhs_bytes, &self.stream);
        }

        for (self.batches) |*bg| {
            if (bg.count == 0) continue;
            try syncSeededLim(bg);
            // Scalars are passed by pointer-to-storage, so these must outlive
            // the launch call — hence locals in this scope, not a helper's.
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
                self.d_g.argPtr(),
                self.d_c.argPtr(),
                self.d_rhs.argPtr(),
                self.d_q.argPtr(),
                bg.d_lim.argPtr(),
                gompute.interface.arg(&limiting),
            });
        }

        // Queued behind the launches and ahead of the host work below. Into
        // pinned staging, not the planes: the CPU batches are about to stamp
        // those, and a download would overwrite them.
        try self.d_g.downloadAtAsync(self.pin_g.ptr, 0, g_bytes, &self.stream);
        try self.d_rhs.downloadAtAsync(self.pin_rhs.ptr, 0, rhs_bytes, &self.stream);
        if (self.has_charge) {
            try self.d_c.downloadAtAsync(self.pin_c.ptr, 0, g_bytes, &self.stream);
            try self.d_q.downloadAtAsync(self.pin_q.ptr, 0, rhs_bytes, &self.stream);
        }

        // The ineligible devices stamp the host planes while the GPU is still
        // working and the D2H copies are still in flight.
        @memset(ckt.g_vals, 0);
        @memset(ckt.rhs, 0);
        if (self.has_charge) {
            @memset(ckt.c_vals, 0);
            @memset(ckt.q_vec, 0);
        }
        const pl = ckt.ownPlanes();
        for (self.cpu_batches) |b| b.eval(b.ctx, &pl, 0, 0, b.count, x, t);

        // One wait, and only on this stream — `cuCtxSynchronize` would stall on
        // every context on the device, including work this process does not own.
        try self.stream.synchronize();

        addInto(ckt.g_vals, self.pin_g);
        addInto(ckt.rhs, self.pin_rhs);
        if (self.has_charge) {
            addInto(ckt.c_vals, self.pin_c);
            addInto(ckt.q_vec, self.pin_q);
        }

        // The ground pin, which `Circuit.evalNewton` applies after every batch
        // has stamped. It is not a device, so no kernel emits it.
        ckt.g_vals[ckt.diag_slots[0]] += 1.0;
        ckt.rhs[0] += x[0];
    }

    inline fn addInto(dst: []f64, src: []const f64) void {
        for (dst, src) |*d, s| d.* += s;
    }

    /// `Circuit.eval` / `Circuit.evalNewton` on the device — the `eval_planes`
    /// hook, and the single point at which any analysis reaches the GPU.
    ///
    /// Swallows the error on purpose. A stamp sits underneath every analysis in
    /// the tree and none are shaped to unwind from a driver fault mid-solve, so
    /// a failure re-runs THIS stamp on the CPU and the solve continues with a
    /// correct answer. Warned once rather than per iteration: a fault that
    /// repeats would otherwise print thousands of times.
    fn evalPlanes(ctx: *anyopaque, x: []const f64, t: f64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.evalOnGpu(x, t) catch |e| {
            if (!self.warned_fallback) {
                self.warned_fallback = true;
                std.debug.print(
                    "warning: GPU device eval failed ({s}); falling back to the CPU stamp\n",
                    .{@errorName(e)},
                );
            }
            self.ckt.evalNewtonCpu(x, t);
        };
    }

    /// Host `seedJunctions` left fresh seed voltages in this batch's host lim
    /// plane — upload them (synchronous, so ordered ahead of whatever launch
    /// reads them) and arm device-era limiting.
    fn syncSeededLim(bg: *BatchGpu) !void {
        if (!bg.lim_dirty) return;
        bg.lim_dirty = false;
        if (!bg.has_lim) return;
        const p = bg.payload(bg.ctx);
        if (!p.lim_active) return;
        try bg.d_lim.upload(std.mem.sliceAsBytes(p.lim_x).ptr, p.lim_x.len * @sizeOf(f64));
        bg.lim_active = true;
    }

    /// The GPU half of `Circuit.applyLimits`, fused with the `updateStates`
    /// half (`StateKernel` does both; the converger always calls the two
    /// back-to-back at the same x). Synchronous: `finalizeStep` consumes the
    /// `limited` answer immediately.
    fn applyLimitsOnGpu(self: *Self, x: []f64, x_old: []const f64) !bool {
        if (self.poisoned) return error.GpuStateReject;
        try self.flushDirtyParams();
        const n = self.ckt.n;

        // x -> d_x2, x_old -> d_x. Explicit x_old upload rather than trusting
        // d_x's residue: under JFNK the last eval was an FD probe.
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

        // The CPU-side batches run their host walk while the device works.
        var any = false;
        for (self.cpu_batches) |b| if (b.hooks.apply_limits) |f| {
            if (f(b.ctx, x, x_old)) any = true;
        };

        if (launched) {
            try self.stream.synchronize();
            const flags = std.mem.readInt(u32, self.pin_flags[0..4], .little);
            if (flags & 2 != 0) {
                // A resident device asked for a step reject the GPU path
                // cannot deliver — the gpuEligible class assumption broke.
                self.poisoned = true;
                return error.GpuStateReject;
            }
            if (flags & 1 != 0) any = true;
        }
        return any;
    }

    /// `Circuit.applyLimits` hook. A fault falls back to the full HOST walk —
    /// including the resident batches, whose host lim/state go stale during
    /// the device era but self-heal: `limitRange` restarts from x_old and
    /// `updateState` recomputes its latches from the current x alone.
    fn applyLimitsHook(ctx: *anyopaque, x: []f64, x_old: []const f64) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.applyLimitsOnGpu(x, x_old) catch {
            self.warnStateFallback();
            var any = false;
            for (self.ckt.batches) |b| if (b.hooks.apply_limits) |f| {
                if (f(b.ctx, x, x_old)) any = true;
            };
            return any;
        };
    }

    /// `Circuit.updateStates` hook: the device half already ran inside
    /// `applyLimitsHook`'s fused launch, so only the CPU-side batches walk.
    /// The admitted device class never returns a reject time (see
    /// `StateKernel`), so the GPU half contributes null by construction.
    fn updateStatesHook(ctx: *anyopaque, x: []const f64) ?f64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const walk = if (self.poisoned) self.ckt.batches else self.cpu_batches;
        var min_reject: ?f64 = null;
        for (walk) |b| {
            if (b.hooks.update_state) |f| if (f(b.ctx, x)) |tr| {
                min_reject = if (min_reject) |cur| @min(cur, tr) else tr;
            };
        }
        return min_reject;
    }

    fn clearLimitsHook(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        for (self.batches) |*bg| {
            bg.lim_active = false;
            bg.lim_dirty = false;
        }
        const walk = if (self.poisoned) self.ckt.batches else self.cpu_batches;
        for (walk) |b| if (b.hooks.clear_limits) |f| f(b.ctx);
    }

    /// The GPU half of `Circuit.stateCtl`: the accepted-step latch (path
    /// commit `pb <- wb, pq += wq`) mutates the device-resident Instance
    /// blobs, so a host walk cannot stand in for a resident batch. All three
    /// ops route here; the kernel ORs the real per-instance verdict into
    /// `d_flags`, so `query` costs one launch + a 4-byte sync per accepted
    /// step rather than a class assumption.
    ///
    /// Known gauge: a later `repack` (sweep/homotopy param mutation) resets
    /// device pb__/pq__ to the host's stale copies. That is harmless where
    /// repacks happen today — pre-tran op ladder and static sweeps, where the
    /// path integral is either re-seeded or unused — and a mid-TRAN repack
    /// does not exist (tran mutates no params). ponytail: if one ever does,
    /// the fix is an instance download-back before repack.
    fn stateCtlOnGpu(self: *Self, op: devices.batch.StateCtlOp) !bool {
        if (self.poisoned) return error.GpuStateReject;
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
        var dirty = false;
        for (self.cpu_batches) |b| if (b.hooks.state_ctl) |f| {
            if (f(b.ctx, op)) dirty = true;
        };
        if (launched) {
            try self.d_flags.downloadAtAsync(self.pin_flags.ptr, 0, 4, &self.stream);
            try self.stream.synchronize();
            if (std.mem.readInt(u32, self.pin_flags[0..4], .little) != 0) dirty = true;
        }
        return dirty;
    }

    fn stateCtlHook(ctx: *anyopaque, op: devices.batch.StateCtlOp) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.stateCtlOnGpu(op) catch {
            self.warnStateFallback();
            var dirty = false;
            for (self.ckt.batches) |b| if (b.hooks.state_ctl) |f| {
                if (f(b.ctx, op)) dirty = true;
            };
            return dirty;
        };
    }

    /// `Circuit.seedJunctions` hook: the host walk runs for EVERY batch (the
    /// seed writes x, which lives on the host), then each resident lim plane
    /// is marked for upload at its next launch.
    fn seedJunctionsHook(ctx: *anyopaque, x: []f64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        for (self.ckt.batches) |b| if (b.hooks.seed) |f| f(b.ctx, x);
        for (self.batches) |*bg| {
            if (bg.has_lim) bg.lim_dirty = true;
        }
    }

    fn warnStateFallback(self: *Self) void {
        if (self.warned_fallback) return;
        self.warned_fallback = true;
        std.debug.print(
            "warning: GPU limit/state pass failed; falling back to the CPU walk\n",
            .{},
        );
    }

    /// The converger's hook shape, with the GPU pass in place of `ckt.eval`.
    /// `assemble` cannot report failure, so a fault is parked on the context
    /// and re-raised by `solveNewton` once the loop is done.
    const AssembleHook = struct {
        self: *Self,

        pub fn assemble(h: AssembleHook, _: *Circuit, x: []const f64, t: f64) void {
            if (h.self.launch_err != null) return; // already failed; stop touching the driver
            h.self.evalOnGpu(x, t) catch |e| {
                h.self.launch_err = e;
            };
        }
        pub fn vals(_: AssembleHook, ckt: *Circuit) []f64 {
            return ckt.g_vals;
        }
        pub fn diagAt(_: AssembleHook, ckt: *Circuit, slot: u32) f64 {
            return ckt.g_vals[slot];
        }
    };

    fn solveNewton(ctx: *anyopaque, x: []f64, t: f64, opts: converger.Options) anyerror!converger.Result {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.launch_err = null;
        const r = try converger.newton(self.ckt, &self.ws, x, t, opts, AssembleHook{ .self = self });
        // Ordered after the solve: a launch that failed mid-loop leaves `x`
        // holding an update computed from a stale plane, so the result is not
        // "unconverged", it is meaningless. Returning the error is what makes
        // `converger.run` fall back to the CPU path.
        if (self.launch_err) |e| return e;
        return r;
    }

    /// Re-upload the parameter arrays after a sweep mutated them. The tapes are
    /// pattern and stay put — only `models`/`instances` can have changed.
    fn repack(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        for (self.batches) |*bg| {
            const p = bg.payload(bg.ctx);
            if (p.models.len > 0) try bg.d_models.upload(p.models.ptr, p.models.len);
            if (p.instances.len > 0) try bg.d_instances.upload(p.instances.ptr, p.instances.len);
        }
        self.params_dirty = false;
    }

    /// `Circuit.markGpuDirty` lands here: host params changed under us.
    fn markDirty(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.params_dirty = true;
    }

    fn flushDirtyParams(self: *Self) !void {
        if (!self.params_dirty) return;
        try repack(self);
    }

    /// What `Circuit.gpu_hook` gets.
    ///
    /// `solve_batch` / `freq_solve_batch` / `simulate_tran` stay null: each is a
    /// SOLVER on the GPU, not a device eval, and this cut moved only the eval.
    /// Their consumers (`dc.zig`, `ac.zig`, `mc.zig`, `temp_sweep.zig`) all
    /// probe for null and take their CPU path, so declining is a supported
    /// answer and not a hole.
    pub fn hook(self: *Self) GpuHook {
        return .{
            .ctx = self,
            .solve_newton = solveNewton,
            .eval_planes = evalPlanes,
            .apply_limits = applyLimitsHook,
            .update_states = updateStatesHook,
            .clear_limits = clearLimitsHook,
            .seed_junctions = seedJunctionsHook,
            .state_ctl = stateCtlHook,
            .repack = repack,
            .mark_dirty = markDirty,
        };
    }
};

test "backend selection matches the artifacts this binary carries" {
    // The one thing that is worth pinning without a GPU: a build with no images
    // must resolve `backend` to null, because every other declaration in this
    // file is guarded on that and would otherwise name a type gompute refuses
    // to instantiate.
    try std.testing.expectEqual(artifacts.has_cuda or artifacts.has_hip, backend != null);
}
