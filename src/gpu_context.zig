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
    /// This binary carries no GPU images (no GPU on the build machine, or
    /// `-Dno-gpu`).
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
    /// Resident for the life of the simulation. `models`/`instances` are the
    /// only two `repack` re-uploads; the tapes never change.
    d_models: Buffer,
    d_instances: Buffer,
    d_gath: Buffer,
    d_rhs_idx: Buffer,
    d_slots: Buffer,
    /// The batch this came from, so `repack` can re-read its parameter arrays.
    ctx: *anyopaque,
    payload: *const fn (*anyopaque) devices.batch.GpuPayload,
    count: u32,
    grid: gompute.Dim3,

    fn deinit(self: *BatchGpu) void {
        self.d_models.free();
        self.d_instances.free();
        self.d_gath.free();
        self.d_rhs_idx.free();
        self.d_slots.free();
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
            // Host-side read of the batch's own slices. No driver contact.
            const p = get(b.ctx);
            work += @as(u64, p.count) * p.n_u * p.n_u;
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

            bg.* = .{
                .kernel = kernel,
                .d_models = try uploadBytes(&kernel, p.models),
                .d_instances = try uploadBytes(&kernel, p.instances),
                .d_gath = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.gath)),
                .d_rhs_idx = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.rhs_idx)),
                .d_slots = try uploadBytes(&kernel, std.mem.sliceAsBytes(p.slots)),
                .ctx = b.ctx,
                .payload = get,
                .count = p.count,
                .grid = gompute.Dim3.linear(p.count, block_size),
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
            .d_x = try k0.alloc(x_bytes),
            .d_g = try k0.alloc(g_bytes),
            .d_c = try k0.alloc(g_bytes),
            .d_rhs = try k0.alloc(rhs_bytes),
            .d_q = try k0.alloc(rhs_bytes),
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
        for ([_][]f64{ self.pin_g, self.pin_rhs, self.pin_c, self.pin_q, self.pin_x }) |p| {
            if (p.len > 0) k0.freePinned(std.mem.sliceAsBytes(p));
        }
        self.stream.deinit();
        self.d_x.free();
        self.d_g.free();
        self.d_c.free();
        self.d_rhs.free();
        self.d_q.free();
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
    /// Always the plain `eval` form, never the constant-Jacobian baseline. That
    /// is not a shortcut: `evalRange`'s `limiting` flag is dead for a device
    /// with no `limit` decl, and `gpuEligible` excludes every device that has
    /// one — so for an eligible circuit `eval` and `eval_newton` are the same
    /// function, and the baseline is an optimization we trade for keeping the
    /// planes on the device.
    fn evalOnGpu(self: *Self, x: []const f64, t: f64) !void {
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
            // Scalars are passed by pointer-to-storage, so these must outlive
            // the launch call — hence locals in this scope, not a helper's.
            var count: u64 = bg.count;
            var time: f64 = t;
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
            .repack = repack,
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
