//! engine.zig — orchestrator between the frontend netlist and the analysis module.
//!
//! Data flow:  types.Netlist ──netlist.NetBuilder──▶ builder.Builder
//!             ──compile()──▶ analysis.Circuit ──run()──▶ []Result
//!
//! Netlist→device wiring policy lives in netlist.zig; this file owns the
//! Simulation lifecycle: compile, job dispatch, result collection.

const std = @import("std");
const analysis = @import("analysis");
const devices = @import("devices");
const types = @import("frontend/types.zig");
const netlist = @import("builder.zig");
const gpu_context = @import("gpu_context.zig");

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
// Sweepable sources: parse-arena scratch, consumed only by buildJob during
// fromNetlist. Never held on the run-time Simulation (would alias dev.name in
// the parse arena). The .dc job resolves source name → index eagerly here.
// ---------------------------------------------------------------------------

const Sources = struct {
    v_names: []const []const u8,
    i_names: []const []const u8,
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
    /// Duped into sim_arena: read at output time, after the parse arena is gone.
    title: []const u8,
    n_devices: u32,
    n_directives: u32,
    jobs: []Job,
    n_jobs: u32,
    results: []Result,
    n_results: u32,
    /// Output-lifetime memory: every Result's data/varnames/plotname is
    /// allocated here (RunCtx.allocator). Lives until the writers finish;
    /// main resets it per deck. Attached in run() for the same by-value
    /// stability reason as par_eval — `.allocator()` captures `&self`.
    results_arena: std.heap.ArenaAllocator,
    /// Parallel eval context (policy: created here, referenced by Circuit).
    par_eval: ?devices.par.ParEval,
    /// `--gpu`. Acted on in `run()`, not here: `fromNetlist` returns by value,
    /// so a context holding `&sim.circuit` taken now would dangle — the same
    /// reason `par_eval` is attached late.
    gpu_requested: bool,
    gpu_ctx: ?*gpu_context.GpuContext,

    /// `sim_arena` owns everything that outlives fromNetlist: Circuit,
    /// Workspace, jobs, probes, par_eval, the duped title. `parse_arena` owns
    /// the transient wiring — NetBuilder scratch and the dyn-device blobs
    /// (proto_add copies them into sim_arena storage) — and may be reset by the
    /// caller the moment this returns. The Builder runs on sim_arena so the
    /// frozen intern table is never a slice into parse memory.
    pub fn fromNetlist(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, nl: types.Netlist, io: ?std.Io, config: SimConfig) !Simulation {
        var b = Builder.init(sim_arena);
        var compiled_ok = false;
        errdefer if (!compiled_ok) b.deinit();

        // Node count is bounded by (and usually close to) device count;
        // reserving here avoids incremental rehash during interning.
        try b.reserveNodes(@intCast(@min(nl.devices.len(), std.math.maxInt(u32))));

        var nb = try netlist.NetBuilder.init(parse_arena, &b, nl);
        try nb.build();

        try netlist.tagSubcircuitNodes(&b, nl.devices);

        // Runtime-loaded (.hdl card, dlopen'd) VA/V devices: erased Proto
        // path, batch machinery lives inside the model's .so. Must happen
        // before compile() freezes the pattern.
        try netlist.addDynDevices(&b, parse_arena, nl);

        var sim: Simulation = undefined;
        sim.arena = sim_arena;
        // Backed by sim_arena: reset(retain_capacity) reclaims result memory
        // between decks without tearing down the circuit. Only its .allocator()
        // is deferred to run() (captures &self); the value itself is stable.
        sim.results_arena = std.heap.ArenaAllocator.init(sim_arena);
        sim.circuit = try b.compile();
        compiled_ok = true;

        errdefer sim.circuit.deinit();
        sim.gpu_requested = config.gpu;
        sim.gpu_ctx = null;

        // Escapes into run-time lifetime: title read at output time, counts in
        // the summary. Dupe/copy off the parse arena so it can be reset now.
        sim.title = try sim_arena.dupe(u8, nl.title);
        sim.n_devices = @intCast(nl.devices.len());
        sim.n_directives = @intCast(nl.directives.len);

        sim.source_node = nb.source_node;
        sim.source_branch = nb.source_branch;

        // Sources are parse-arena scratch; resolved into job indices below and
        // never stored on `sim`.
        const sources: Sources = .{
            .v_names = nb.v_names[0..nb.n_v],
            .i_names = nb.i_names[0..nb.n_i],
        };

        // Probes: every named node (branch unknowns have no label)
        const probe_buf = try sim_arena.alloc(u32, sim.circuit.n);
        var n_probes: u32 = 0;
        for (1..sim.circuit.n) |i| {
            if (sim.circuit.nodeName(@intCast(i)).len != 0) {
                probe_buf[n_probes] = @intCast(i);
                n_probes += 1;
            }
        }
        sim.probes = probe_buf[0..n_probes];

        // Jobs from directives: pre-allocate to directive count
        sim.jobs = try sim_arena.alloc(Job, nl.directives.len);
        sim.n_jobs = 0;
        for (nl.directives) |dir| {
            if (buildJob(dir, &sim, sources)) |job| {
                sim.jobs[sim.n_jobs] = job;
                sim.n_jobs += 1;
            }
        }

        // Results: one per job max
        sim.results = try sim_arena.alloc(Result, @max(sim.n_jobs, 1));
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
            sim.par_eval = devices.par.ParEval.init(sim_arena, io_val, ckt.batches, ckt.nnz, ckt.n, ckt.has_charge, ckt.trash_slot, @min(lanes, 16)) catch break :enable_par;
        }

        return sim;
    }

    pub fn deinit(self: *Simulation) void {
        self.circuit.par_eval = null;
        self.circuit.gpu_hook = null;
        if (self.gpu_ctx) |g| g.deinit();
        if (self.par_eval) |*p| p.deinit();
        self.results_arena.deinit();
        self.circuit.deinit();
    }

    pub fn run(self: *Simulation) !void {
        // Attach here, not in fromNetlist: sim is returned by value there, so
        // a &self.par_eval taken earlier would dangle. `self` is stable now.
        if (self.par_eval) |*p| self.circuit.par_eval = p;

        // Same stability rule for the GPU context, which holds `&self.circuit`
        // and uploads the whole circuit to the device at init.
        //
        // A failure here is NOT fatal — every analysis has a CPU path and
        // `converger.run` falls back on its own. It is printed rather than
        // swallowed so `--gpu` never silently means "ran on the CPU": that is
        // exactly how the benchmark came to report CPU timings in its GPU
        // column.
        if (self.gpu_requested) {
            if (gpu_context.GpuContext.init(self.arena, &self.circuit)) |g| {
                self.gpu_ctx = g;
                self.circuit.gpu_hook = g.hook();
                self.circuit.gpu_active = true;
            } else |e| if (e == gpu_context.Error.NotEnoughGpuWork) {
                // A DECISION, not a failure: the circuit has kernels, there is
                // just not enough of it to beat the round trip. Worth saying
                // out loud (and worth naming the override) so a small `--gpu`
                // run does not look like a broken driver.
                std.debug.print(
                    "note: --gpu declined; too little device work to beat the PCIe round trip " ++
                        "(override with ZPICEY_GPU_MIN_WORK=<n>)\n",
                    .{},
                );
            } else {
                std.debug.print("warning: --gpu unavailable ({s}); running on the CPU\n", .{@errorName(e)});
            }
        }
        var ctx = RunCtx{
            .circuit = &self.circuit,
            .x_op = null,
            .probes = self.probes,
            .source_node = self.source_node,
            .source_branch = self.source_branch,
            // Results land in the output-lifetime arena. Stable now (self is
            // pinned), so taking .allocator() no longer dangles.
            .allocator = self.results_arena.allocator(),
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
        return self.circuit.nodeIndex(name) orelse error.UnknownNode;
    }
};

// ---------------------------------------------------------------------------
// Job builder — directive → analysis.Job (no ArrayList)
// ---------------------------------------------------------------------------

fn buildJob(dir: types.Directive, sim: *const Simulation, sources: Sources) ?Job {
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
            const src_idx: u32 = if (findNameIndex(sources.v_names, name1)) |i|
                @intCast(i)
            else if (findNameIndex(sources.i_names, name1)) |i|
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


