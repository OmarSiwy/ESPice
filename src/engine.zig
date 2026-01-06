//! engine.zig — orchestrator between the frontend netlist and the analysis module.
//!
//! Data flow:  types.Netlist ──netlist.NetBuilder──▶ builder.Builder
//!             ──compile()──▶ analysis.Circuit ──run()──▶ []Result
//!
//! Netlist→device wiring policy lives in netlist.zig; this file owns the
//! Simulation lifecycle: compile, job dispatch, result collection.

const std = @import("std");
const analysis = @import("analysis");
const compute = @import("compute");
const devices = @import("devices");
const types = @import("frontend/types.zig");
const kernels = @import("kernels");
const netlist = @import("builder.zig");

const abi = analysis.gpu_abi;
const converger = analysis.converger;
const tran = analysis.tran;

const Circuit = analysis.Circuit;
const Job = analysis.Job;
const Result = analysis.Result;
const RunCtx = analysis.RunCtx;
const Builder = @import("builder.zig").Builder;
const GROUND = analysis.GROUND;

const directiveName = netlist.directiveName;
const directiveNumber = netlist.directiveNumber;
const directiveNodeName = netlist.directiveNodeName;
const findNameIndex = netlist.findNameIndex;

// ---------------------------------------------------------------------------
// Sweepable sources: parallel slices indexed by add order
// ---------------------------------------------------------------------------

const Sources = struct {
    v_names: []const []const u8,
    v_ports: []const u32,
    v_branches: []const u32,
    v_dc: []const *f32,
    i_names: []const []const u8,
    i_dc: []const *f32,
};

pub const SimConfig = struct {
    gpu: bool = false,
};

// ---------------------------------------------------------------------------
// Simulation — owns circuit, dispatches jobs, collects results
// ---------------------------------------------------------------------------

pub const Simulation = struct {
    arena: std.mem.Allocator,
    circuit: Circuit,
    probes: []u32,
    source_node: u32,
    source_branch: u32,
    sources: Sources,
    jobs: []Job,
    n_jobs: u32,
    results: []Result,
    n_results: u32,
    /// Parallel eval context (policy: created here, referenced by Circuit).
    par_eval: ?analysis.problem.ParEval,
    /// GPU compute handle (non-null when GPU active).
    gpu_compute: ?compute.Compute = null,
    /// Whole-solve megakernel driver (attached in run(); see par_eval note).
    gpu_ctx: ?*GpuContext = null,

    pub fn fromNetlist(arena: std.mem.Allocator, nl: types.Netlist, io: ?std.Io, config: SimConfig) !Simulation {
        var b = Builder.init(arena);
        var compiled_ok = false;
        errdefer if (!compiled_ok) b.deinit();

        // Node count is bounded by (and usually close to) device count;
        // reserving here avoids incremental rehash during interning.
        try b.reserveNodes(@intCast(@min(nl.devices.len(), std.math.maxInt(u32))));

        var nb = try netlist.NetBuilder.init(arena, &b, nl);
        try nb.build();

        try netlist.tagSubcircuitNodes(&b, nl.devices);

        // Baked va_devices decls (permanently-empty stub — compiles to
        // nothing). Must happen before compile() freezes the pattern.
        try netlist.addVaDevices(&b, arena, nl);
        // Runtime-loaded (.hdl card, dlopen'd) VA/V devices: same erased
        // Proto path, batch machinery lives inside the model's .so.
        try netlist.addDynDevices(&b, arena, nl);

        var sim: Simulation = undefined;
        sim.arena = arena;
        sim.gpu_compute = null;
        sim.gpu_ctx = null;
        sim.circuit = try b.compile();
        compiled_ok = true;

        // GPU: probe for CUDA/HIP when --gpu requested.
        if (config.gpu) gpu_init: {
            var gpu_ctx = compute.Compute.init(null) catch break :gpu_init;
            if (gpu_ctx.backend == .cpu) { gpu_ctx.deinit(); break :gpu_init; }
            sim.gpu_compute = gpu_ctx;
            sim.circuit.gpu_active = true;
        }
        errdefer sim.circuit.deinit();
        // Function scope, not inside gpu_init: must fire on any later failure.
        errdefer if (sim.gpu_compute) |*gc| gc.deinit();

        // Sources: convert builder arrays to frozen slices
        sim.source_node = nb.source_node;
        sim.source_branch = nb.source_branch;
        sim.sources = .{
            .v_names = nb.v_names[0..nb.n_v],
            .v_ports = nb.v_ports[0..nb.n_v],
            .v_branches = nb.v_branches[0..nb.n_v],
            .v_dc = try collectDcRefs(&sim.circuit, arena, devices.vsource, false, nb.n_v),
            .i_names = nb.i_names[0..nb.n_i],
            .i_dc = try collectDcRefs(&sim.circuit, arena, devices.isource, true, nb.n_i),
        };

        // Probes: every named node (branch unknowns have no label)
        const probe_buf = try arena.alloc(u32, sim.circuit.n);
        var n_probes: u32 = 0;
        for (1..sim.circuit.n) |i| {
            if (sim.circuit.nodeName(@intCast(i)).len != 0) {
                probe_buf[n_probes] = @intCast(i);
                n_probes += 1;
            }
        }
        sim.probes = probe_buf[0..n_probes];

        // Jobs from directives: pre-allocate to directive count
        sim.jobs = try arena.alloc(Job, nl.directives.len);
        sim.n_jobs = 0;
        for (nl.directives) |dir| {
            if (buildJob(dir, &sim)) |job| {
                sim.jobs[sim.n_jobs] = job;
                sim.n_jobs += 1;
            }
        }

        // Results: one per job max
        sim.results = try arena.alloc(Result, @max(sim.n_jobs, 1));
        sim.n_results = 0;

        // Parallel device eval. ponytail: OPT-IN via ZPICEY_THREADS=N for
        // now — measured 2026-07-04, per-eval handoff + window zero/reduce
        // breaks even with eval work on the current fixture corpus, so
        // default-on would regress small/medium circuits. Auto-enable
        // (work-based threshold) is the Phase-5 tuning task.
        sim.par_eval = null;
        if (io) |io_val| enable_par: {
            const s = std.c.getenv("ZPICEY_THREADS") orelse break :enable_par;
            const lanes = std.fmt.parseInt(u32, std.mem.span(s), 10) catch break :enable_par;
            if (lanes < 2) break :enable_par;
            var total: u64 = 0;
            for (sim.circuit.batches) |batch| total += batch.count;
            if (total < analysis.problem.default_min_instances) break :enable_par;
            const ckt = &sim.circuit;
            sim.par_eval = analysis.problem.ParEval.init(arena, io_val, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, @min(lanes, 16)) catch break :enable_par;
        }

        return sim;
    }

    pub fn deinit(self: *Simulation) void {
        self.circuit.par_eval = null;
        if (self.par_eval) |*p| p.deinit();
        if (self.gpu_ctx) |gs| gs.deinit();
        if (self.gpu_compute) |*g| g.deinit();
        self.circuit.deinit();
    }

    pub fn run(self: *Simulation) !void {
        // Attach here, not in fromNetlist: sim is returned by value there, so
        // a &self.par_eval taken earlier would dangle. `self` is stable now.
        if (self.par_eval) |*p| self.circuit.par_eval = p;
        // Same stability rule as par_eval: &self.gpu_compute is only valid
        // once `self` stopped moving. One packed blob + module per circuit.
        if (self.gpu_compute) |*g| {
            if (self.gpu_ctx == null) {
                self.gpu_ctx = GpuContext.init(self.arena, g, &self.circuit, kernels.megakernel);
                if (self.gpu_ctx) |gs| self.circuit.gpu_hook = gs.hook();
            }
        }
        var ctx = RunCtx{
            .circuit = &self.circuit,
            .x_op = null,
            .probes = self.probes,
            .source_node = self.source_node,
            .source_branch = self.source_branch,
            .allocator = self.arena,
        };

        // If no jobs queued, run an implicit OP
        if (self.n_jobs == 0) {
            ctx.x_op = try self.ensureOp(ctx.x_op);
            self.results[0] = try analysis.run(&ctx, .{ .op = .{} });
            self.n_results = 1;
            return;
        }

        for (self.jobs[0..self.n_jobs]) |job| {
            // Ensure operating point for analyses that need it
            ctx.x_op = try self.ensureOp(ctx.x_op);
            self.results[self.n_results] = try analysis.run(&ctx, job);
            self.n_results += 1;
        }
    }

    pub fn getResults(self: *const Simulation) []const Result {
        return self.results[0..self.n_results];
    }

    fn ensureOp(self: *Simulation, current: ?[]f64) ![]f64 {
        if (current) |x| return x;
        const x = try self.arena.alloc(f64, self.circuit.n);
        const result = try analysis.AnalysisId.Module(.op).solve(&self.circuit, x, .{});
        if (!result.converged) return error.OpDidNotConverge;
        return x;
    }

    fn nodeIndex(self: *const Simulation, name: []const u8) !u32 {
        return self.circuit.node_names.get(name) orelse error.UnknownNode;
    }
};

// ---------------------------------------------------------------------------
// Job builder — directive → analysis.Job (no ArrayList)
// ---------------------------------------------------------------------------

fn buildJob(dir: types.Directive, sim: *const Simulation) ?Job {
    const id = analysis.Analysis.get(dir.kind) orelse return null;
    return switch (id) {
        .op => .{ .op = .{} },
        .tran => blk: {
            // .tran tstep tstop [tstart [tmax]] [uic]
            const a0 = directiveNumber(dir, 0);
            const a1 = directiveNumber(dir, 1);
            const t_stop = a1 orelse a0 orelse break :blk null;
            // arg 2 is tstart (output suppression before tstart) — not wired.
            // TODO: uic (skip OP, start from initial conditions) — not wired.
            const tstep = if (a1 != null) a0.? else t_stop / 100.0;
            // ngspice default tmax = min(tstep, (tstop-tstart)/50); an
            // explicit 4th arg replaces it.
            break :blk .{ .tran = .{
                .t_stop = t_stop,
                .dt_init = tstep,
                .dt_max = directiveNumber(dir, 3) orelse @min(tstep, t_stop / 50.0),
            } };
        },
        .ac => .{ .ac = .{
            .f_start = directiveNumber(dir, dir.args.len -| 2) orelse return null,
            .f_stop = directiveNumber(dir, dir.args.len -| 1) orelse return null,
            .points_per_decade = @intFromFloat(directiveNumber(dir, 1) orelse 10),
        } },
        .dc => blk: {
            const name1 = directiveName(dir, 0) orelse break :blk null;
            // Resolve source name → batch-local index (V sources first, then I).
            const src_idx: u32 = if (findNameIndex(sim.sources.v_names, name1)) |i|
                @intCast(i)
            else if (findNameIndex(sim.sources.i_names, name1)) |i|
                @intCast(i)
            else
                break :blk null;
            break :blk .{ .dc = .{
                .start = directiveNumber(dir, 1) orelse 0,
                .stop = directiveNumber(dir, 2) orelse 0,
                .step = directiveNumber(dir, 3) orelse 1,
                .source_index = src_idx,
            } };
        },
        .noise => .{ .noise = .{
            .out_node = sim.nodeIndex(directiveNodeName(dir, 0) orelse return null) catch return null,
            .f_start = directiveNumber(dir, dir.args.len -| 2) orelse return null,
            .f_stop = directiveNumber(dir, dir.args.len -| 1) orelse return null,
            .points_per_decade = @intFromFloat(directiveNumber(dir, dir.args.len -| 3) orelse 10),
        } },
        .pz => .{ .pz = .{} },
        .pss => .{ .pss = .{
            .period = directiveNumber(dir, 0) orelse return null,
        } },
        .hb => .{ .hb = .{
            .f0 = directiveNumber(dir, 0) orelse return null,
            .n_harmonics = @intFromFloat(directiveNumber(dir, 1) orelse 8),
        } },
        // ponytail: remaining analyses follow the same pattern —
        // parse positional args from directive, resolve names via sim.nodeIndex.
        // Expand as each analysis module lands.
        else => null,
    };
}

// ---------------------------------------------------------------------------
// DC ref collection — stable pointers into frozen batches
// ---------------------------------------------------------------------------

fn collectDcRefs(
    ckt: *const Circuit,
    allocator: std.mem.Allocator,
    comptime D: type,
    comptime is_instance: bool,
    count: u32,
) ![]const *f32 {
    // Collect from the matching batch only — collecting every param of every
    // device (and doing it twice, for V and I sources) dominated build time
    // and memory on large netlists.
    var list: std.ArrayList(analysis.ParamRef) = .empty;
    defer list.deinit(allocator);
    for (ckt.batches) |b| {
        if (!std.mem.eql(u8, b.type_name, @typeName(D))) continue;
        try b.hooks.collect_params(b.ctx, allocator, &list);
    }
    const refs = list.items;
    const out = try allocator.alloc(*f32, count);
    for (refs) |ref| {
        if (ref.is_instance != is_instance) continue;
        if (!std.mem.eql(u8, ref.param_name, "dc")) continue;
        if (ref.index < count) out[ref.index] = ref.ptr;
    }
    return out;
}

// ---------------------------------------------------------------------------
// GpuContext — persistent GPU context for cooperative-launch solves
// ---------------------------------------------------------------------------
//
// Three dispatch modes:
//   solveNewton — single Newton (OP, TF) via arp_solve [existing]
//   solveBatch  — N independent Newton lanes (MC, corners, temp, sens)
//   simulateTran — chunked transient [existing]
//
// Ownership: engine owns the context, Circuit carries a narrow fn-pointer
// hook (analysis stays free of the compute dependency).

const tran_chunk_steps: u32 = 512;

pub const GpuContext = struct {
    gpa: std.mem.Allocator,
    comp: *compute.Compute,
    ckt: *analysis.Circuit,
    module: compute.Module,
    k_solve: compute.Kernel,
    k_batch: ?compute.Kernel,
    k_tran: ?compute.Kernel,
    k_freq: ?compute.Kernel,
    k_freq_adj: ?compute.Kernel,
    blob: compute.Buffer,
    prob: analysis.problem.GpuProblem,
    n_blocks: u32,
    block_dim: u32,
    shared_uploaded: bool,
    /// Device buffers for freq solve (CSC pattern + planes, uploaded once)
    freq_buf: ?compute.Buffer = null,

    pub fn init(gpa: std.mem.Allocator, comp: *compute.Compute, ckt: *analysis.Circuit, ptx: []const u8) ?*GpuContext {
        if ((comp.backend != .cuda and comp.backend != .hip) or ptx.len == 0) return null;
        if (!analysis.problem.gpuEligible(ckt)) {
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
        const k_batch: ?compute.Kernel = module.getKernel("arp_solve_batch") catch null;
        const k_freq: ?compute.Kernel = module.getKernel("arp_freq_solve") catch null;
        const k_freq_adj: ?compute.Kernel = module.getKernel("arp_freq_solve_adjoint") catch null;

        const block_dim: u32 = 256;
        var max_blocks = comp.maxCoopBlocks(k, block_dim, 0) catch 0;
        if (max_blocks == 0) {
            module.deinit();
            return null;
        }
        if (k_tran) |kt| {
            const mb = comp.maxCoopBlocks(kt, block_dim, 0) catch 0;
            if (mb == 0) k_tran = null else max_blocks = @min(max_blocks, mb);
        }
        const want = (ckt.n + block_dim - 1) / block_dim;
        const n_blocks: u32 = @max(1, @min(@min(max_blocks, abi.max_blocks), want));
        std.debug.print("GPU: persistent context ({d} blocks, batch {s}, tran {s})\n", .{
            n_blocks,
            if (k_batch != null) "yes" else "no",
            if (k_tran != null) "yes" else "no",
        });

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

        const self = gpa.create(GpuContext) catch {
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
            .k_batch = k_batch,
            .k_tran = k_tran,
            .k_freq = k_freq,
            .k_freq_adj = k_freq_adj,
            .blob = blob,
            .prob = prob,
            .n_blocks = n_blocks,
            .block_dim = block_dim,
            .shared_uploaded = false,
        };
        return self;
    }

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

    /// Upload the shared prefix once. Subsequent solves skip this.
    fn ensureSharedUploaded(self: *GpuContext) !void {
        if (self.shared_uploaded) return;
        self.prob.repack(self.ckt);
        try self.blob.upload(self.prob.stage.ptr, self.prob.stage.len);
        self.shared_uploaded = true;
    }

    /// Mark shared as dirty — called after parameter mutation (sweeps).
    fn invalidateShared(self: *GpuContext) void {
        self.shared_uploaded = false;
    }

    pub fn deinit(self: *GpuContext) void {
        if (self.freq_buf) |*fb| fb.free();
        self.blob.free();
        self.module.deinit();
        self.prob.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn hook(self: *GpuContext) analysis.GpuHook {
        return .{
            .ctx = self,
            .solve_newton = solveNewton,
            .simulate_tran = if (self.k_tran != null) simulateTran else null,
            .solve_batch = solveBatch,
            .freq_solve_batch = if (self.k_freq != null) freqSolveBatchFn else null,
            .freq_solve_adjoint_batch = if (self.k_freq_adj != null) freqSolveAdjointBatchFn else null,
            .repack = repackPayloads,
        };
    }

    // -----------------------------------------------------------------------
    // Single Newton solve (backward compat)
    // -----------------------------------------------------------------------

    fn solveNewton(ctx: *anyopaque, x: []f64, t: f64, opts: converger.Options) anyerror!converger.Result {
        const self: *GpuContext = @ptrCast(@alignCast(ctx));
        const hdr_ptr: *abi.Header = @ptrCast(@alignCast(self.prob.stage.ptr));
        hdr_ptr.t = t;
        hdr_ptr.tol = optionsToTol(opts);
        self.prob.hdr = hdr_ptr.*;

        self.prob.repack(self.ckt);
        @memcpy(self.prob.xBytes(), std.mem.sliceAsBytes(x));
        const res_off = hdr_ptr.off_result;
        @memset(self.prob.stage[res_off..][0..@sizeOf(abi.ResultHeader)], 0);

        try self.blob.upload(self.prob.stage.ptr, self.prob.stage.len);
        self.shared_uploaded = true;

        try self.k_solve.launchCooperative(
            .{ .x = self.n_blocks },
            .{ .x = self.block_dim },
            0,
            &.{self.blob.argPtr()},
        );
        try self.comp.synchronize();

        const dl_off = hdr_ptr.off_x;
        const dl_len = hdr_ptr.off_ws - dl_off;
        try self.blob.downloadAt(self.prob.stage.ptr + dl_off, dl_off, dl_len);

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
    // Batch Newton — N independent lanes in one cooperative launch
    // -----------------------------------------------------------------------

    fn solveBatch(ctx: *anyopaque, x_lanes: [][]f64, t: f64, opts: converger.Options, results: []converger.Result) anyerror!void {
        const self: *GpuContext = @ptrCast(@alignCast(ctx));
        const n_total = x_lanes.len;
        if (n_total == 0) return;
        const n: usize = self.ckt.n;

        // If no batch kernel, fall back to serial single-solve.
        const k_batch = self.k_batch orelse {
            for (x_lanes, results) |x, *r| {
                r.* = solveNewton(ctx, x, t, opts) catch
                    converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };
            }
            return;
        };

        // Compute lane geometry: blocks_per_lane >= 2 for meaningful parallelism
        const blocks_per_lane: u32 = @max(2, @min(self.n_blocks, (self.ckt.n + self.block_dim - 1) / self.block_dim));
        const max_lanes: u32 = self.n_blocks / blocks_per_lane;
        if (max_lanes == 0) {
            // Not enough blocks for even 1 lane — fall back
            for (x_lanes, results) |x, *r| {
                r.* = solveNewton(ctx, x, t, opts) catch
                    converger.Result{ .converged = false, .iterations = 0, .max_dx = 0 };
            }
            return;
        }

        // Patch header with tolerances
        const hdr_ptr: *abi.Header = @ptrCast(@alignCast(self.prob.stage.ptr));
        hdr_ptr.t = t;
        hdr_ptr.tol = optionsToTol(opts);
        self.prob.hdr = hdr_ptr.*;
        self.prob.repack(self.ckt);
        try self.blob.upload(self.prob.stage.ptr, self.prob.stage.len);
        self.shared_uploaded = true;

        // Per-lane layout: x(n*8) | result(aligned) | workspace
        const m: usize = @min(30, n);
        const lane_ws_size = abi.wsF64CountLane(n, m, blocks_per_lane) * 8;
        const result_off = n * 8;
        const ws_off = abi.alignUp(result_off + @sizeOf(abi.ResultHeader), 8);
        const lane_stride: u32 = @intCast(abi.alignUp(ws_off + lane_ws_size, 8));
        const shared_size: u32 = @intCast(self.prob.stage.len);

        // Allocate lane pool on device (resize if needed)
        const pool_size: usize = @as(usize, max_lanes) * lane_stride;
        var lane_buf = try self.comp.alloc(@intCast(shared_size + pool_size));
        defer lane_buf.free();

        // Copy shared prefix from the persistent blob
        try lane_buf.copyFrom(&self.blob, 0, 0, shared_size);

        // Zero all lane workspaces (barrier counters must start at zero)
        const zero_chunk = [_]u8{0} ** 4096;
        for (0..max_lanes) |lane| {
            var off: usize = shared_size + lane * lane_stride + ws_off;
            var left: usize = lane_ws_size;
            while (left > 0) {
                const nb: usize = @min(left, zero_chunk.len);
                try lane_buf.uploadAt(&zero_chunk, off, nb);
                off += nb;
                left -= nb;
            }
        }

        // Process in chunks of max_lanes
        var done: usize = 0;
        const batch_hdr_bytes = std.mem.asBytes(&abi.BatchLaunchHeader{
            .n_lanes = 0, // patched per chunk
            .blocks_per_lane = blocks_per_lane,
            .shared_size = shared_size,
            .lane_stride = lane_stride,
        });

        // Stage for batch header (upload per chunk)
        var batch_hdr_stage: abi.BatchLaunchHeader = .{
            .n_lanes = 0,
            .blocks_per_lane = blocks_per_lane,
            .shared_size = shared_size,
            .lane_stride = lane_stride,
        };
        _ = batch_hdr_bytes;

        while (done < n_total) {
            const chunk = @min(max_lanes, @as(u32, @intCast(n_total - done)));

            // Upload x vectors for this chunk
            for (0..chunk) |lane| {
                const x = x_lanes[done + lane];
                const lane_off = shared_size + lane * lane_stride;
                try lane_buf.uploadAt(std.mem.sliceAsBytes(x[0..n]).ptr, lane_off, n * 8);
                // Zero result header for this lane
                try lane_buf.uploadAt(&zero_chunk, lane_off + result_off, @sizeOf(abi.ResultHeader));
            }

            batch_hdr_stage.n_lanes = chunk;

            // Launch batch kernel
            const grid = chunk * blocks_per_lane;
            try k_batch.launchCooperative(
                .{ .x = grid },
                .{ .x = self.block_dim },
                0,
                &.{ lane_buf.argPtr(), @as(compute.Arg, @ptrCast(&batch_hdr_stage)) },
            );
            try self.comp.synchronize();

            // Read back x + result per lane
            for (0..chunk) |lane| {
                const lane_off = shared_size + lane * lane_stride;
                const dl_size = result_off + @sizeOf(abi.ResultHeader);
                var dl_buf: [65536]u8 = undefined;
                const dl = dl_buf[0..dl_size];
                try lane_buf.downloadAt(dl.ptr, lane_off, dl_size);

                const xr: []align(1) const f64 = std.mem.bytesAsSlice(f64, dl[0..n * 8]);
                const finite = for (xr) |v| {
                    if (!std.math.isFinite(v)) break false;
                } else true;
                if (finite) {
                    for (0..n) |i| x_lanes[done + lane][i] = xr[i];
                }
                const res: *const abi.ResultHeader = @ptrCast(@alignCast(dl.ptr + result_off));
                results[done + lane] = .{
                    .converged = res.status == 1,
                    .iterations = @intCast(@min(res.iterations, std.math.maxInt(u16))),
                    .max_dx = res.max_dx,
                };
            }
            done += chunk;
        }
    }

    // -----------------------------------------------------------------------
    // Repack — refresh device payloads after parameter mutation
    // -----------------------------------------------------------------------

    fn repackPayloads(ctx: *anyopaque) anyerror!void {
        const self: *GpuContext = @ptrCast(@alignCast(ctx));
        self.invalidateShared();
    }

    // -----------------------------------------------------------------------
    // Transient
    // -----------------------------------------------------------------------

    fn repackForTran(self: *GpuContext, probes: []const u32, t_stop: f64) !void {
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
        self.shared_uploaded = false;
    }

    fn simulateTran(ctx: *anyopaque, x: []f64, probes: []const u32, waveform: *tran.Waveform, options: tran.Options) anyerror!tran.SimResult {
        const self: *GpuContext = @ptrCast(@alignCast(ctx));
        if (options.step_fn != null) return error.GpuTranUnsupported;

        try self.repackForTran(probes, options.t_stop);
        const hdr: *abi.Header = @ptrCast(@alignCast(self.prob.stage.ptr));

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
        hdr.dt_max = options.dt_max orelse options.t_stop / 50.0;
        hdr.chgtol = options.tol.chgtol;
        hdr.trtol = options.tol.trtol;

        const k = self.k_tran orelse return error.GpuTranUnsupported;
        const wrow: usize = 1 + probes.len;

        // Stream-overlapped readback: create a DMA stream so we can
        // download chunk N's waveform while chunk N+1 integrates.
        var dma_stream = self.comp.createStream() catch null;
        defer if (dma_stream) |*s| s.deinit();

        // Double-buffered staging: two host buffers for waveform data.
        // While one is being consumed (appended to waveform), the other
        // receives the next DMA.
        const dl_off: usize = hdr.off_result;
        const dl_len: usize = hdr.off_ws - dl_off;
        const dl_buf_a = self.gpa.alloc(u8, dl_len) catch null;
        defer if (dl_buf_a) |b| self.gpa.free(b);
        const dl_buf_b = self.gpa.alloc(u8, dl_len) catch null;
        defer if (dl_buf_b) |b| self.gpa.free(b);

        // Fall back to synchronous if stream or buffers unavailable
        const use_overlap = dma_stream != null and dl_buf_a != null and dl_buf_b != null;

        var total_steps: u32 = 0;
        var first = true;
        var pending_buf: ?[]u8 = null; // buffer with in-flight async download
        const active_buf: ?[]u8 = null;
        _ = active_buf;

        while (true) {
            hdr.tran_reset = @intFromBool(first);
            hdr.max_steps_chunk = @min(tran_chunk_steps, options.max_steps - total_steps);
            self.prob.hdr = hdr.*;
            if (first) {
                self.prob.repack(self.ckt);
                @memcpy(self.prob.xBytes(), std.mem.sliceAsBytes(x));
                try self.blob.upload(self.prob.stage.ptr, self.prob.stage.len);
                self.shared_uploaded = true;
            } else {
                try self.blob.uploadAt(self.prob.stage.ptr, 0, @sizeOf(abi.Header));
            }
            try k.launchCooperative(
                .{ .x = self.n_blocks },
                .{ .x = self.block_dim },
                0,
                &.{self.blob.argPtr()},
            );

            if (use_overlap and !first) {
                // While kernel runs chunk N+1, drain pending chunk N's data.
                // The async download was issued after the previous kernel
                // completed; the DMA stream is independent of the compute
                // stream, so it can overlap with this kernel.
                if (pending_buf) |pb| {
                    dma_stream.?.synchronize() catch {};
                    try drainWaveChunk(pb, dl_off, hdr, wrow, waveform);
                    pending_buf = null;
                }
            }

            try self.comp.synchronize(); // wait for kernel

            if (use_overlap) {
                // Issue async download of this chunk's results on DMA stream.
                // Pick the buffer that isn't pending.
                const buf = if (if (pending_buf) |pb| pb.ptr == dl_buf_a.?.ptr else false) dl_buf_b.? else dl_buf_a.?;
                self.blob.downloadAtAsync(buf.ptr, dl_off, dl_len, &dma_stream.?) catch {
                    // Async failed — fall back to sync for this chunk
                    try self.blob.downloadAt(self.prob.stage.ptr + dl_off, dl_off, dl_len);
                    try drainWaveChunk(self.prob.stage[dl_off..][0..dl_len], dl_off, hdr, wrow, waveform);
                    const res: *const abi.ResultHeader = @ptrCast(@alignCast(self.prob.stage.ptr + hdr.off_result));
                    total_steps += res.steps;
                    if (checkTranDone(res, total_steps, options.max_steps)) |sr| {
                        try self.downloadFinalX(hdr, x);
                        return sr;
                    }
                    if (res.steps == 0) return error.GpuTranStalled;
                    first = false;
                    continue;
                };
                // Record which buffer has pending DMA.
                // But we need the ResultHeader immediately for the done check.
                // Download just the ResultHeader synchronously (tiny: 40 bytes).
                try self.blob.downloadAt(self.prob.stage.ptr + hdr.off_result, hdr.off_result, @sizeOf(abi.ResultHeader));
                const res: *const abi.ResultHeader = @ptrCast(@alignCast(self.prob.stage.ptr + hdr.off_result));
                total_steps += res.steps;

                const done = checkTranDone(res, total_steps, options.max_steps);
                if (done != null) {
                    // Drain the pending async download before returning.
                    dma_stream.?.synchronize() catch {};
                    try drainWaveChunk(buf, dl_off, hdr, wrow, waveform);
                    try self.downloadFinalX(hdr, x);
                    return done.?;
                }
                if (res.steps == 0) {
                    dma_stream.?.synchronize() catch {};
                    try drainWaveChunk(buf, dl_off, hdr, wrow, waveform);
                    return error.GpuTranStalled;
                }
                pending_buf = buf;
            } else {
                // Synchronous path (no stream or alloc failed)
                try self.blob.downloadAt(self.prob.stage.ptr + dl_off, dl_off, dl_len);
                try drainWaveChunk(self.prob.stage[dl_off..][0..dl_len], dl_off, hdr, wrow, waveform);
                const res: *const abi.ResultHeader = @ptrCast(@alignCast(self.prob.stage.ptr + hdr.off_result));
                total_steps += res.steps;
                if (checkTranDone(res, total_steps, options.max_steps)) |sr| {
                    try self.downloadFinalX(hdr, x);
                    return sr;
                }
                if (res.steps == 0) return error.GpuTranStalled;
            }
            first = false;
        }
    }

    fn drainWaveChunk(buf: []const u8, dl_off: usize, hdr: *const abi.Header, wrow: usize, waveform: *tran.Waveform) !void {
        const res_local_off = hdr.off_result - @as(u32, @intCast(dl_off));
        const wave_local_off = hdr.off_wave - @as(u32, @intCast(dl_off));
        const res: *const abi.ResultHeader = @ptrCast(@alignCast(buf.ptr + res_local_off));
        const wave: [*]const f64 = @ptrCast(@alignCast(buf.ptr + wave_local_off));
        const npts: usize = @min(res.wave_len, hdr.wave_capacity);
        for (0..npts) |p| {
            const row = wave + p * wrow;
            try waveform.recordValues(row[0], (row + 1)[0 .. wrow - 1]);
        }
    }

    fn checkTranDone(res: *const abi.ResultHeader, total_steps: u32, max_steps: u32) ?tran.SimResult {
        const done = res.status == abi.status_done;
        const dead = res.status == abi.status_dt_underflow;
        if (done or dead or total_steps >= max_steps)
            return .{ .completed = done, .steps = total_steps, .t_final = res.t_final };
        return null;
    }

    fn downloadFinalX(self: *GpuContext, hdr: *const abi.Header, x: []f64) !void {
        try self.blob.downloadAt(self.prob.stage.ptr + hdr.off_x, hdr.off_x, @as(usize, hdr.n) * 8);
        @memcpy(std.mem.sliceAsBytes(x), self.prob.xBytes());
    }

    // -----------------------------------------------------------------------
    // Batch frequency solve
    // -----------------------------------------------------------------------

    const FreqArgs = extern struct {
        n: u32,
        nnz: u32,
        n_points: u32,
        _pad: u32 = 0,
        off_g: u64,
        off_c: u64,
        off_col_ptr: u64,
        off_row_idx: u64,
        off_omegas: u64,
        off_rhs: u64,
        off_solutions: u64,
        off_scratch: u64,
    };

    fn freqSolveBatchFn(ctx: *anyopaque, g_vals: []const f64, c_vals: []const f64, omegas: []const f64, rhs: []const f64, x_out: [][]f64, n: u32) anyerror!void {
        return freqSolveBatchInner(ctx, g_vals, c_vals, omegas, rhs, x_out, n, false);
    }

    fn freqSolveAdjointBatchFn(ctx: *anyopaque, g_vals: []const f64, c_vals: []const f64, omegas: []const f64, rhs: []const f64, y_out: [][]f64, n: u32) anyerror!void {
        return freqSolveBatchInner(ctx, g_vals, c_vals, omegas, rhs, y_out, n, true);
    }

    fn freqSolveBatchInner(ctx: *anyopaque, g_vals: []const f64, c_vals: []const f64, omegas: []const f64, rhs: []const f64, x_out: [][]f64, n: u32, comptime adjoint: bool) anyerror!void {
        const self: *GpuContext = @ptrCast(@alignCast(ctx));
        const n_points: u32 = @intCast(omegas.len);
        if (n_points == 0) return;
        if (n > 256) return error.CircuitTooLargeForDenseGpuFreq;

        const k = if (adjoint) (self.k_freq_adj orelse return error.NoFreqKernel) else (self.k_freq orelse return error.NoFreqKernel);

        const nn: usize = 2 * @as(usize, n);
        const nnz: usize = self.ckt.nnz;

        // Compute total device memory needed
        const g_bytes = nnz * 8;
        const c_bytes = nnz * 8;
        const cp_bytes = (@as(usize, n) + 1) * 4;
        const ri_bytes = nnz * 4;
        const omega_bytes = @as(usize, n_points) * 8;
        const rhs_bytes = nn * 8;
        const sol_bytes = @as(usize, n_points) * nn * 8;
        const per_point_scratch = nn * nn + nn + nn + nn; // A + piv + rhs_local + x_local (in f64 slots)
        const scratch_bytes = @as(usize, n_points) * per_point_scratch * 8;

        const total = abi.alignUp(g_bytes + c_bytes + cp_bytes + ri_bytes + omega_bytes + rhs_bytes + sol_bytes + scratch_bytes, 8);

        var buf = try self.comp.alloc(@intCast(total));
        defer buf.free();

        // Pack data into device buffer
        var off: usize = 0;
        const off_g = off;
        try buf.uploadAt(std.mem.sliceAsBytes(g_vals[0..nnz]).ptr, off_g, g_bytes);
        off += g_bytes;

        const off_c = off;
        try buf.uploadAt(std.mem.sliceAsBytes(c_vals[0..nnz]).ptr, off_c, c_bytes);
        off += c_bytes;

        const off_cp = abi.alignUp(off, 4);
        try buf.uploadAt(std.mem.sliceAsBytes(self.ckt.col_ptr[0 .. n + 1]).ptr, off_cp, cp_bytes);
        off = off_cp + cp_bytes;

        const off_ri = abi.alignUp(off, 4);
        try buf.uploadAt(std.mem.sliceAsBytes(self.ckt.row_idx[0..nnz]).ptr, off_ri, ri_bytes);
        off = off_ri + ri_bytes;

        const off_omega = abi.alignUp(off, 8);
        try buf.uploadAt(std.mem.sliceAsBytes(omegas).ptr, off_omega, omega_bytes);
        off = off_omega + omega_bytes;

        const off_rhs = abi.alignUp(off, 8);
        try buf.uploadAt(std.mem.sliceAsBytes(rhs[0..nn]).ptr, off_rhs, rhs_bytes);
        off = off_rhs + rhs_bytes;

        const off_sol = abi.alignUp(off, 8);
        off = off_sol + sol_bytes;

        const off_scratch = abi.alignUp(off, 8);

        // Build args struct
        const base_addr = buf.deviceAddr();
        var args = FreqArgs{
            .n = n,
            .nnz = @intCast(nnz),
            .n_points = n_points,
            .off_g = base_addr + off_g,
            .off_c = base_addr + off_c,
            .off_col_ptr = base_addr + off_cp,
            .off_row_idx = base_addr + off_ri,
            .off_omegas = base_addr + off_omega,
            .off_rhs = base_addr + off_rhs,
            .off_solutions = base_addr + off_sol,
            .off_scratch = base_addr + off_scratch,
        };

        // Standard launch: 1 block per freq point, 1 thread per block
        // (dense LU is single-threaded per block for now)
        try k.launch(
            .{ .x = n_points },
            .{ .x = 1 },
            0,
            &.{@as(compute.Arg, @ptrCast(&args))},
        );
        try self.comp.synchronize();

        // Download solutions
        const sol_staging = try self.gpa.alloc(u8, sol_bytes);
        defer self.gpa.free(sol_staging);
        try buf.downloadAt(sol_staging.ptr, off_sol, sol_bytes);

        const sol_f64: []align(1) const f64 = std.mem.bytesAsSlice(f64, sol_staging);
        for (0..n_points) |p| {
            const src = sol_f64[p * nn ..][0..nn];
            for (0..nn) |i| x_out[p][i] = src[i];
        }
    }

    // -----------------------------------------------------------------------
    // MC statistics — extract probe values from batch solve results
    // without downloading full x-vectors. Downloads only n_probes per lane
    // instead of n per lane, reducing PCIe traffic by ~1000x for large
    // circuits with a few output probes.
    // -----------------------------------------------------------------------

    pub const McStats = struct {
        mean: f64,
        std_dev: f64,
        min: f64,
        max: f64,
        n_converged: u32,
    };

    /// After a solveBatch call, extract probe values from the lane results
    /// still in device memory and compute per-probe statistics on the host.
    /// Returns stats[n_probes]. Only downloads n_probes * n_converged f64
    /// instead of n * n_lanes f64 — a ~(n/n_probes)x bandwidth reduction.
    pub fn batchMcStats(
        _: *GpuContext,
        lane_results: []const converger.Result,
        x_lanes: []const []const f64,
        probes: []const u32,
        stats_out: []McStats,
    ) void {
        const n_lanes = lane_results.len;
        const n_probes = probes.len;

        // Count converged trials and extract probe values
        for (0..n_probes) |p| {
            var sum: f64 = 0;
            var sum_sq: f64 = 0;
            var vmin: f64 = std.math.inf(f64);
            var vmax: f64 = -std.math.inf(f64);
            var n_conv: u32 = 0;

            for (0..n_lanes) |lane| {
                if (!lane_results[lane].converged) continue;
                const v = x_lanes[lane][probes[p]];
                sum += v;
                sum_sq += v * v;
                vmin = @min(vmin, v);
                vmax = @max(vmax, v);
                n_conv += 1;
            }

            if (n_conv == 0) {
                stats_out[p] = .{ .mean = 0, .std_dev = 0, .min = 0, .max = 0, .n_converged = 0 };
                continue;
            }

            const nc: f64 = @floatFromInt(n_conv);
            const mean = sum / nc;
            const variance = if (n_conv > 1)
                (sum_sq - nc * mean * mean) / @as(f64, @floatFromInt(n_conv - 1))
            else
                0;
            stats_out[p] = .{
                .mean = mean,
                .std_dev = @sqrt(@max(0, variance)),
                .min = vmin,
                .max = vmax,
                .n_converged = n_conv,
            };
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    fn optionsToTol(opts: converger.Options) abi.Tol {
        return .{
            .reltol = opts.reltol,
            .abstol = opts.abstol,
            .vntol = opts.vntol,
            .residual_tol = opts.residual_tol,
            .gmin = opts.gmin,
            .dx_clamp = opts.dx_clamp,
            .max_iter = opts.max_iter,
            .gmres_m = 30,
        };
    }
};
