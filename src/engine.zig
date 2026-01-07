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

const GpuContext = @import("gpu.zig").GpuContext;

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
    par_eval: ?devices.par.ParEval,
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

        // Runtime-loaded (.hdl card, dlopen'd) VA/V devices: erased Proto
        // path, batch machinery lives inside the model's .so. Must happen
        // before compile() freezes the pattern.
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
            if (total < devices.par.default_min_instances) break :enable_par;
            const ckt = &sim.circuit;
            sim.par_eval = devices.par.ParEval.init(arena, io_val, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, @min(lanes, 16)) catch break :enable_par;
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

