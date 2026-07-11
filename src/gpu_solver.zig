//! Engine-side driver for the analysis megakernel: one whole Newton solve
//! per cooperative launch. Per solve: patch header (t, tolerances) + x in
//! the staged prefix, ONE HtoD of the prefix, ONE launch, ONE DtoH of the
//! contiguous [off_x, off_ws) window (x + ResultHeader).
//!
//! Transient (arp_tran): the whole integration runs on-device in chunks of
//! max_steps_chunk accepted timesteps per cooperative launch (watchdog-safe).
//! Integration state lives in the device workspace between launches; per
//! chunk the host uploads only the header and drains ResultHeader + the
//! waveform buffer.
//!
//! Ownership mirrors ParEval: engine owns the driver, Circuit carries a
//! narrow fn-pointer hook (analysis stays free of the compute dependency).

const std = @import("std");
const analysis = @import("analysis");
const compute = @import("compute");

const abi = analysis.gpu_abi;
const converger = analysis.converger;
const tran = analysis.tran;

/// Accepted timesteps per cooperative launch. Bounds kernel runtime under
/// display watchdogs and sizes the per-chunk waveform buffer.
const tran_chunk_steps: u32 = 512;

pub const GpuSolver = struct {
    gpa: std.mem.Allocator,
    comp: *compute.Compute,
    ckt: *analysis.Circuit,
    module: compute.Module,
    k_solve: compute.Kernel,
    k_tran: ?compute.Kernel,
    blob: compute.Buffer,
    prob: analysis.problem.GpuProblem,
    n_blocks: u32,
    block_dim: u32,

    /// Null (not error) when the GPU path can't run: no CUDA device, no
    /// cooperative launch, circuit not fully packable. Caller stays on CPU.
    pub fn init(gpa: std.mem.Allocator, comp: *compute.Compute, ckt: *analysis.Circuit, ptx: []const u8) ?*GpuSolver {
        if ((comp.backend != .cuda and comp.backend != .hip) or ptx.len == 0) return null;
        if (!analysis.problem.gpuEligible(ckt)) {
            // Loud, not silent: runtime-loaded (.hdl) devices are not baked
            // into the megakernel — the whole solve stays on CPU.
            for (ckt.batches) |b| if (b.hooks.gpu_pack == null)
                std.debug.print("GPU declined: batch '{s}' not in the megakernel (runtime-loaded or stateful); CPU solve.\n", .{b.type_name});
            return null;
        }

        var module = comp.loadModule(ptx) catch return null;
        errdefer module.deinit();
        const k = module.getKernel("arp_solve") catch {
            module.deinit();
            return null;
        };
        var k_tran: ?compute.Kernel = module.getKernel("arp_tran") catch null;

        const block_dim: u32 = 256;
        var max_blocks = comp.maxCoopBlocks(k, block_dim, 0) catch 0;
        if (max_blocks == 0) {
            module.deinit();
            return null;
        }
        // One n_blocks is baked into the packed header for BOTH kernels —
        // clamp to the smaller cooperative capacity.
        if (k_tran) |kt| {
            const mb = comp.maxCoopBlocks(kt, block_dim, 0) catch 0;
            if (mb == 0) k_tran = null else max_blocks = @min(max_blocks, mb);
        }
        const want = (ckt.n + block_dim - 1) / block_dim;
        const n_blocks: u32 = @max(1, @min(@min(max_blocks, abi.max_blocks), want));

        // gmres_m/max_iter placeholders — patched per solve from Options.
        const tol: abi.Tol = .{
            .reltol = 1e-3,
            .abstol = 1e-12,
            .vntol = 1e-6,
            .residual_tol = 1e-9,
            .gmin = 0,
            .dx_clamp = 10.0,
            .max_iter = 100,
            .gmres_m = 30,
        };
        var prob = analysis.problem.packGpuProblem(gpa, ckt, tol, n_blocks, .{}) catch {
            module.deinit();
            return null;
        };
        errdefer prob.deinit(gpa);

        var blob = comp.alloc(prob.hdr.total_bytes) catch {
            module.deinit();
            prob.deinit(gpa);
            return null;
        };
        errdefer blob.free();
        zeroDeviceWs(&blob, prob.hdr);

        const self = gpa.create(GpuSolver) catch {
            module.deinit();
            prob.deinit(gpa);
            blob.free();
            return null;
        };
        self.* = .{
            .gpa = gpa,
            .comp = comp,
            .ckt = ckt,
            .module = module,
            .k_solve = k,
            .k_tran = k_tran,
            .blob = blob,
            .prob = prob,
            .n_blocks = n_blocks,
            .block_dim = block_dim,
        };
        return self;
    }

    /// Device-only workspace is never uploaded — but the grid-barrier
    /// counters and control scalars at its tail MUST start zeroed (blocks
    /// hit the first barrier before thread 0 could initialize anything).
    fn zeroDeviceWs(blob: *compute.Buffer, hdr: abi.Header) void {
        const ws_bytes = hdr.total_bytes - hdr.off_ws;
        const zero_chunk = [_]u8{0} ** 4096;
        var off: usize = hdr.off_ws;
        var left: usize = ws_bytes;
        while (left > 0) {
            const nb: usize = @min(left, zero_chunk.len);
            blob.uploadAt(&zero_chunk, off, nb) catch break;
            off += nb;
            left -= nb;
        }
    }

    pub fn deinit(self: *GpuSolver) void {
        self.blob.free();
        self.module.deinit();
        self.prob.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn hook(self: *GpuSolver) analysis.GpuHook {
        return .{
            .ctx = self,
            .solve_newton = solveNewton,
            .simulate_tran = if (self.k_tran != null) simulateTran else null,
        };
    }

    fn solveNewton(ctx: *anyopaque, x: []f64, t: f64, opts: converger.Options) anyerror!converger.Result {
        const self: *GpuSolver = @ptrCast(@alignCast(ctx));
        const hdr_ptr: *abi.Header = @ptrCast(@alignCast(self.prob.stage.ptr));
        hdr_ptr.t = t;
        hdr_ptr.tol = .{
            .reltol = opts.reltol,
            .abstol = opts.abstol,
            .vntol = opts.vntol,
            .residual_tol = opts.residual_tol,
            .gmin = opts.gmin,
            .dx_clamp = opts.dx_clamp,
            .max_iter = opts.max_iter,
            .gmres_m = 30,
        };
        self.prob.hdr = hdr_ptr.*;
        // Sweeps (dc/mc/temp) mutate device params through ParamRef pointers
        // after packing — refresh the staged payload bytes every solve.
        self.prob.repack(self.ckt);
        @memcpy(self.prob.xBytes(), std.mem.sliceAsBytes(x));
        // Result region sits between x and ws inside the prefix — zero it.
        const res_off = hdr_ptr.off_result;
        @memset(self.prob.stage[res_off..][0..@sizeOf(abi.ResultHeader)], 0);

        // ponytail: whole prefix re-uploaded per solve (few MB, sub-ms) —
        // dirty-window tracking when a profile says it matters.
        try self.blob.upload(self.prob.stage.ptr, self.prob.stage.len);
        try self.k_solve.launchCooperative(
            .{ .x = self.n_blocks },
            .{ .x = self.block_dim },
            0,
            &.{self.blob.argPtr()},
        );
        try self.comp.synchronize();

        // One contiguous readback: x .. ResultHeader.
        const dl_off = hdr_ptr.off_x;
        const dl_len = hdr_ptr.off_ws - dl_off;
        try self.blob.downloadAt(self.prob.stage.ptr + dl_off, dl_off, dl_len);
        // A failed solve can leave NaN/inf in the last iterate; copying that
        // back would poison the CPU fallback's warm start. Only finite
        // iterates come home.
        const xr: []align(1) const f64 = std.mem.bytesAsSlice(f64, self.prob.xBytes());
        const finite = for (xr) |v| {
            if (!std.math.isFinite(v)) break false;
        } else true;
        if (finite) @memcpy(std.mem.sliceAsBytes(x), self.prob.xBytes());
        const res: *const abi.ResultHeader = @ptrCast(@alignCast(self.prob.stage.ptr + res_off));
        return .{
            .converged = res.status == 1,
            .iterations = @intCast(@min(res.iterations, std.math.maxInt(u16))),
            .max_dx = res.max_dx,
        };
    }

    // -----------------------------------------------------------------------
    // Transient
    // -----------------------------------------------------------------------

    /// Repack the blob with the transient sections (probes, breakpoint
    /// schedule, waveform buffer) and swap the device allocation. The solve
    /// path keeps working against the new layout (tran sections are inert
    /// for arp_solve).
    fn repackForTran(self: *GpuSolver, probes: []const u32, t_stop: f64) !void {
        // Breakpoint schedule over (0, t_stop) — the device kernel scans a
        // flat sorted array instead of calling device vtables.
        var bps: std.ArrayList(f64) = .empty;
        defer bps.deinit(self.gpa);
        var tb: f64 = 0;
        while (self.ckt.nextBreakpoint(tb)) |bp| {
            if (bp >= t_stop or bp <= tb or bps.items.len >= 4096) break;
            try bps.append(self.gpa, bp);
            tb = bp;
        }

        const hdr_old: *const abi.Header = @ptrCast(@alignCast(self.prob.stage.ptr));
        var prob = try analysis.problem.packGpuProblem(self.gpa, self.ckt, hdr_old.tol, self.n_blocks, .{
            .probes = probes,
            .breakpoints = bps.items,
            .wave_capacity = tran_chunk_steps + 1,
        });
        errdefer prob.deinit(self.gpa);
        var blob = try self.comp.alloc(prob.hdr.total_bytes);
        zeroDeviceWs(&blob, prob.hdr);
        self.blob.free();
        self.prob.deinit(self.gpa);
        self.blob = blob;
        self.prob = prob;
    }

    /// Whole transient analysis on-device, chunked cooperative launches.
    /// Appends accepted points into `waveform` (same shape tran.simulate
    /// produces); any error means "fall back to CPU" for the caller.
    fn simulateTran(ctx: *anyopaque, x: []f64, probes: []const u32, waveform: *tran.Waveform, options: tran.Options) anyerror!tran.SimResult {
        const self: *GpuSolver = @ptrCast(@alignCast(ctx));
        if (options.step_fn != null) return error.GpuTranUnsupported;

        try self.repackForTran(probes, options.t_stop);
        const hdr: *abi.Header = @ptrCast(@alignCast(self.prob.stage.ptr));

        // Same Newton controls as tran.simulate(): itl4 iterations, clamp off.
        const nr = options.tol.newtonOpts(options.tol.itl4);
        hdr.tol = .{
            .reltol = nr.reltol,
            .abstol = nr.abstol,
            .vntol = nr.vntol,
            .residual_tol = nr.residual_tol,
            .gmin = nr.gmin,
            .dx_clamp = std.math.inf(f64),
            .max_iter = nr.max_iter,
            .gmres_m = 30,
        };
        hdr.method = @intFromEnum(options.method);
        hdr.t_stop = options.t_stop;
        hdr.dt_init = options.dt_init;
        hdr.dt_min = options.dt_min;
        // ngspice tmax default: (tstop-tstart)/50; explicit tmax replaces it
        // (no history devices on the GPU path, so no min-delay clamp).
        hdr.dt_max = options.dt_max orelse options.t_stop / 50.0;
        hdr.chgtol = options.tol.chgtol;
        hdr.trtol = options.tol.trtol;

        const k = self.k_tran orelse return error.GpuTranUnsupported;
        const wrow: usize = 1 + probes.len;
        var total_steps: u32 = 0;
        var first = true;
        while (true) {
            hdr.tran_reset = @intFromBool(first);
            hdr.max_steps_chunk = @min(tran_chunk_steps, options.max_steps - total_steps);
            self.prob.hdr = hdr.*;
            if (first) {
                self.prob.repack(self.ckt);
                @memcpy(self.prob.xBytes(), std.mem.sliceAsBytes(x));
                try self.blob.upload(self.prob.stage.ptr, self.prob.stage.len);
            } else {
                // State persists on-device; only the header changes.
                try self.blob.uploadAt(self.prob.stage.ptr, 0, @sizeOf(abi.Header));
            }
            try k.launchCooperative(
                .{ .x = self.n_blocks },
                .{ .x = self.block_dim },
                0,
                &.{self.blob.argPtr()},
            );
            try self.comp.synchronize();

            // One contiguous readback: ResultHeader + waveform buffer.
            const dl_off = hdr.off_result;
            try self.blob.downloadAt(self.prob.stage.ptr + dl_off, dl_off, hdr.off_ws - dl_off);
            const res: *const abi.ResultHeader = @ptrCast(@alignCast(self.prob.stage.ptr + hdr.off_result));
            const wave: [*]const f64 = @ptrCast(@alignCast(self.prob.stage.ptr + hdr.off_wave));
            const npts: usize = @min(res.wave_len, hdr.wave_capacity);
            for (0..npts) |p| {
                const row = wave + p * wrow;
                try waveform.recordValues(row[0], (row + 1)[0..probes.len]);
            }
            total_steps += res.steps;

            const done = res.status == abi.status_done;
            const dead = res.status == abi.status_dt_underflow;
            if (done or dead or total_steps >= options.max_steps) {
                // Final (last-accepted) x back to the host.
                try self.blob.downloadAt(self.prob.stage.ptr + hdr.off_x, hdr.off_x, @as(usize, hdr.n) * 8);
                @memcpy(std.mem.sliceAsBytes(x), self.prob.xBytes());
                return .{ .completed = done, .steps = total_steps, .t_final = res.t_final };
            }
            // No progress and not done ⇒ something is wrong; bail to CPU.
            if (res.steps == 0) return error.GpuTranStalled;
            first = false;
        }
    }
};
