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

/// One `.ic V(node)=value` card, resolved to a circuit index at build time.
/// Sim-arena lifetime: the node id is only meaningful against the compiled
/// Circuit, and `b.node_names` (the only name table there is) dies inside
/// `compile()`, so the resolution has to happen before that and the result has
/// to outlive the parse arena. Sorted-ness is irrelevant — this is scanned once
/// per uic transient, and decks carry a handful of cards at most.
const Ic = struct {
    node: u32,
    value: f64,
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
    /// `.ic` cards, node-resolved. Read only by a `uic` transient.
    ic: []const Ic,
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
        // The ONE name->id lookup a directive can carry (.noise's out_node),
        // resolved here because `b.node_names` is complete before compile()
        // and dies inside it. A u32 per directive, parse-lifetime, written in
        // directive order and read once by buildJob below: an O(1) hash hit
        // now beats any lookup the frozen Circuit could offer later, and the
        // frozen struct carries no name table at all.
        const dir_nodes = try parse_arena.alloc(u32, nl.directives.len);
        for (nl.directives, dir_nodes) |dir, *id| {
            id.* = if (directiveNodeName(dir, 0)) |name|
                b.node_names.get(name) orelse NO_NODE
            else
                NO_NODE;
        }

        // `.ic` cards, resolved here for the same reason as `dir_nodes`: this is
        // the last point where `b.node_names` exists. Two passes so the result
        // is an exact sim-arena slice rather than a growable list — the count is
        // known from the arg shape (`v(node)` group followed by its value).
        var n_ic: usize = 0;
        for (nl.directives) |dir| {
            if (!std.ascii.eqlIgnoreCase(dir.kind, "ic")) continue;
            n_ic += dir.args.len / 2;
        }
        const ic_buf = try sim_arena.alloc(Ic, n_ic);
        var n_ic_used: usize = 0;
        for (nl.directives) |dir| {
            if (!std.ascii.eqlIgnoreCase(dir.kind, "ic")) continue;
            var i: usize = 0;
            while (i + 1 < dir.args.len) : (i += 2) {
                const name = icNodeName(parse_arena, dir.args[i]) orelse continue;
                const value = netlist.valueNumber(dir.args[i + 1]) orelse continue;
                // An `.ic` on a node the netlist never mentions is a typo, not a
                // constraint. Dropping it silently matches how the rest of the
                // directive path treats unresolvable names.
                const id = b.node_names.get(name) orelse continue;
                if (id == GROUND) continue;
                ic_buf[n_ic_used] = .{ .node = id, .value = value };
                n_ic_used += 1;
            }
        }
        sim.ic = ic_buf[0..n_ic_used];

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
        for (nl.directives, dir_nodes) |dir, node_id| {
            if (buildJob(dir, node_id, sources)) |job| {
                sim.jobs[sim.n_jobs] = job;
                sim.n_jobs += 1;
            }
        }

        // Results: one per job max
        sim.results = try sim_arena.alloc(Result, @max(sim.n_jobs, 1));
        sim.n_results = 0;

        // Parallel device eval. ponytail: OPT-IN via ESPICE_THREADS=N for
        // now — measured 2026-07-04, per-eval handoff + window zero/reduce
        // breaks even with eval work on the current fixture corpus, so
        // default-on would regress small/medium circuits. Auto-enable
        // (work-based threshold) is the Phase-5 tuning task.
        sim.par_eval = null;
        if (io) |io_val| enable_par: {
            const s = std.c.getenv("ESPICE_THREADS") orelse break :enable_par;
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
                        "(override with ESPICE_GPU_MIN_WORK=<n>)\n",
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
            const uic = switch (job) {
                .tran => |o| o.uic,
                else => false,
            };
            if (uic) {
                // `.tran ... uic`: no operating point at all. The starting
                // point is the `.ic` cards over a zero vector — ngspice's rule,
                // and the reason uic exists (a latch or an oscillator has no
                // useful DC solution to start from).
                //
                // Handed over on a COPY of the context: `ctx.x_op` is the
                // memoized operating point every later job reuses, and an IC
                // guess is not one. Writing it there would silently feed a
                // following .ac or .noise a linearization about a point no
                // solver ever converged.
                var uic_ctx = ctx;
                uic_ctx.x_op = try self.icVector();
                self.results[self.n_results] = try analysis.run(&uic_ctx, job);
            } else {
                ctx.x_op = try self.ensureOp(ctx.x_op);
                self.results[self.n_results] = try analysis.run(&ctx, job);
            }
            self.n_results += 1;
        }
    }

    pub fn getResults(self: *const Simulation) []const Result {
        return self.results[0..self.n_results];
    }

    /// uic starting point: zero everywhere except the `.ic` nodes.
    fn icVector(self: *Simulation) ![]f64 {
        const x = try self.arena.alloc(f64, self.circuit.n);
        @memset(x, 0);
        for (self.ic) |e| if (e.node < x.len) {
            x[e.node] = e.value;
        };
        return x;
    }

    fn ensureOp(self: *Simulation, current: ?[]f64) ![]f64 {
        if (current) |x| return x;
        const x = try self.arena.alloc(f64, self.circuit.n);
        // ngspice's TRANOP/DCOP split, at deck granularity (ONE memoized op
        // serves every job): a deck with a transient-family job biases its
        // waveform sources at t = 0, everything else at the DC value.
        // ponytail: a deck mixing .op with .tran gets the tranop flavor for
        // both; per-job op flavors the day a fixture measures the difference.
        var tran_op = false;
        for (self.jobs[0..self.n_jobs]) |job| switch (job) {
            .tran, .four, .tran_noise, .envelope, .pss, .qpss, .pnoise, .pac, .pxf => tran_op = true,
            else => {},
        };
        const result = try analysis.AnalysisId.Module(.op).solve(&self.circuit, x, .{ .tran_op = tran_op });
        if (!result.converged) return error.OpDidNotConverge;
        return x;
    }

};

// ---------------------------------------------------------------------------
// Job builder — directive → analysis.Job (no ArrayList)
// ---------------------------------------------------------------------------

/// No node named in the directive, or a name no node answers to.
const NO_NODE: u32 = std.math.maxInt(u32);

/// `node_id` is the directive's resolved node (NO_NODE when it names none),
/// looked up in fromNetlist while the Builder's map was still alive.
/// The node inside an `.ic v(<node>)=<value>` group. `v(2)` tokenizes the node
/// as a NUMBER while `node_names` is keyed by the string the device cards used,
/// so an integral node has to be spelled back out before the lookup.
fn icNodeName(arena: std.mem.Allocator, value: types.Value) ?[]const u8 {
    const g = switch (value) {
        .group => |g| g,
        else => return null,
    };
    if (!std.ascii.eqlIgnoreCase(g.name, "v") or g.args.len == 0) return null;
    return switch (g.args[0]) {
        .name => |n| n,
        .num => |n| if (n == @trunc(n) and @abs(n) < 1e9)
            std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))}) catch null
        else
            null,
        else => null,
    };
}

/// `uic` is a trailing KEYWORD, not a positional: `.tran 1n 100n uic` and
/// `.tran 1n 100n 0 1n uic` are both legal, so scan rather than index.
fn hasUic(dir: types.Directive) bool {
    for (dir.args) |a| switch (a) {
        .name => |n| if (std.ascii.eqlIgnoreCase(n, "uic")) return true,
        else => {},
    };
    return false;
}

fn buildJob(dir: types.Directive, node_id: u32, sources: Sources) ?Job {
    const id = analysis.Analysis.get(dir.kind) orelse return null;
    return switch (id) {
        .op => .{ .op = .{} },
        .tran => blk: {
            // .tran tstep tstop [tstart [tmax]] [uic]
            const a0 = directiveNumber(dir, 0);
            const a1 = directiveNumber(dir, 1);
            const t_stop = a1 orelse a0 orelse break :blk null;
            // arg 2 is tstart (output suppression before tstart) — not wired.
            const tstep = if (a1 != null) a0.? else t_stop / 100.0;
            // ngspice default tmax = min(tstep, (tstop-tstart)/50); an
            // explicit 4th arg replaces it.
            break :blk .{ .tran = .{
                .t_stop = t_stop,
                .dt_init = tstep,
                .dt_max = directiveNumber(dir, 3) orelse @min(tstep, t_stop / 50.0),
                .uic = hasUic(dir),
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
            .out_node = if (node_id != NO_NODE) node_id else return null,
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
        // ponytail: remaining analyses follow the same pattern — parse
        // positional args from the directive; a node name arrives pre-resolved
        // as `node_id` (extend dir_nodes to a small column if one ever needs
        // more than one name).
        // Expand as each analysis module lands.
        else => null,
    };
}



// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Parser = @import("frontend/parser.zig").Parser;
const ngspice = @import("frontend/tokenizer.zig").ngspice;

/// Parse `src`, build a Simulation, run it. Both arenas are the caller's.
fn runDeck(sim_arena: std.mem.Allocator, parse_arena: std.mem.Allocator, src: []const u8) !Simulation {
    const nl = try Parser(ngspice).parse(parse_arena, src);
    var sim = try Simulation.fromNetlist(sim_arena, parse_arena, nl, null, .{});
    try sim.run();
    return sim;
}

test "uic: .ic seeds the transient and the OP is skipped" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    // An RC with the source at 0 V: the operating point is v(2) = 0, so a
    // transient that ran the OP starts flat at zero. With `uic` the cap starts
    // charged at 1 V and decays — the two are unmistakable.
    var sim = try runDeck(sa.allocator(), pa.allocator(),
        \\uic rc
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=1.0
        \\.tran 1u 2m uic
        \\.end
    );
    defer sim.deinit();

    try std.testing.expectEqual(@as(usize, 1), sim.ic.len);
    try std.testing.expectEqual(@as(f64, 1.0), sim.ic[0].value);

    const res = sim.getResults();
    try std.testing.expectEqual(@as(usize, 1), res.len);
    // v(2) at t=0 must be the IC, not the OP's zero.
    const v2_first = probeFirst(res[0], "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v2_first, 1e-9);

    // ...and it must decay: one RC is 1 ms, so by 2 ms it is well under half.
    const v2_last = probeLast(res[0], "2") orelse return error.NoProbe;
    try std.testing.expect(v2_last < 0.5);
}

test "uic: without the keyword the transient starts from the operating point" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    // Same deck, same .ic card, no `uic`: the OP wins and v(2) starts at 0.
    var sim = try runDeck(sa.allocator(), pa.allocator(),
        \\op rc
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=1.0
        \\.tran 1u 2m
        \\.end
    );
    defer sim.deinit();

    const v2_first = probeFirst(sim.getResults()[0], "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v2_first, 1e-9);
}

test "uic: keyword is positional-independent and .ic on an unknown node is dropped" {
    var sa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer sa.deinit();
    var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pa.deinit();

    var sim = try runDeck(sa.allocator(), pa.allocator(),
        \\uic forms
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=0.25 v(nosuchnode)=9.0
        \\.tran 1u 2m 0 1u uic
        \\.end
    );
    defer sim.deinit();

    // The bogus card is dropped, the real one survives.
    try std.testing.expectEqual(@as(usize, 1), sim.ic.len);
    const v2_first = probeFirst(sim.getResults()[0], "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), v2_first, 1e-9);
}

/// Probe columns are named `v(<node>)` (Circuit.probeNames) and a transient's
/// column 0 is "time". Result.data is ROW-major: data[point * ncols + col].
fn probeColumn(r: Result, node: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "v({s})", .{node}) catch return null;
    for (r.varnames, 0..) |v, i| {
        if (std.mem.eql(u8, v, want)) return i;
    }
    return null;
}

fn probeAt(r: Result, node: []const u8, point: usize) ?f64 {
    const c = probeColumn(r, node) orelse return null;
    if (point >= r.npoints) return null;
    return r.data[point * r.varnames.len + c];
}

fn probeFirst(r: Result, node: []const u8) ?f64 {
    return probeAt(r, node, 0);
}

fn probeLast(r: Result, node: []const u8) ?f64 {
    if (r.npoints == 0) return null;
    return probeAt(r, node, r.npoints - 1);
}
