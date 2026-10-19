//! Executor: one query's mutable numerical state and the worker thread that
//! runs it. Prepared topology and the deck are borrowed; an accepted OP from a
//! dependency is copied before use, or moved under `Config.final_plan`.
//! Dispatches to the analysis leaves, with the query's ParEval, GPU context
//! and device LU attached for the run. Cites VAMS LRM Table 4-22 and
//! ngspice osdiload.c (the small-signal `analysis()` kind), §9.4 display
//! tasks, #13.
const std = @import("std");
const Circuit = @import("device").Circuit;
const Deck = @import("core").Deck;
const requests = @import("core").query;
const types = @import("types.zig");
const op = @import("dc/op.zig");
const dc = @import("dc/dc.zig");
const gpu = @import("gpu.zig");
const gpu_lu = @import("gpu_lu.zig");
const ParEval = @import("par_eval.zig").ParEval;
const Controller = @import("worker.zig").Worker(QueryError, types.Result);
const Quantum = @import("worker.zig").Quantum;
const converger = @import("solver").converger;

/// Why a started query ended without a result: whatever an analysis leaf
/// or its setup in `runQuery` can return (`error.QueryCancelled` for a
/// cancel, `error.OutOfMemory`, the numerical failures such as
/// `error.TimestepTooSmall`), or `error.DeviceRefused` when a device latched
/// `$fatal`/`$error`. Names are part of the API: `c_api.zig` maps some to
/// status codes.
// Spelled from runQuery's parts, not `ErrorOf(Executor.runQuery)`: the
// executor holds its worker, whose type needs this set, so naming its own
// method's inferred set is a dependency loop. A part missing here fails
// to compile at `execute`.
pub const QueryError = types.ErrorOf(run) || types.ErrorOf(op.solve) || types.ErrorOf(ParEval.init) ||
    gpu.InitError || types.ErrorOf(gpu.GpuContext.syncHostState) || types.ErrorOf(types.Circuit.workspace) ||
    std.mem.Allocator.Error || error{ OpDidNotConverge, DeviceRefused, QueryCancelled } ||
    // `materialize`'s parts.
    types.ErrorOf(types.Circuit.fromSnapshot) || types.ErrorOf(types.Circuit.fromSnapshotMove) ||
    types.ErrorOf(types.Circuit.instantiate) || types.ErrorOf(types.Circuit.instantiateMove) ||
    types.ErrorOf(types.Circuit.recompute) || types.ErrorOf(types.Circuit.collectParams) || error{InvalidAcOverride};

/// Per-problem execution settings, shared by every query.
pub const Config = struct {
    /// The `--backend` choices: `auto`, `cpu`, `cuda`, `hip`.
    pub const Backend = gpu.Request;
    backend: gpu.Request = .cpu,
    /// The user named the GPU: bypass the work gate, and under `auto` fail
    /// rather than fall back when the machine cannot run it. `cuda` and `hip`
    /// imply it and never fall back (`gpu.fallsBack`).
    gpu_explicit: bool = false,
    solver_threads: u8 = 1,
    /// Device-stamp lanes; above 1 each query builds a ParEval.
    device_threads: u32 = 1,
    /// Print per-query setup and per-checkpoint timing to stderr.
    timing_in_depth: bool = false,
    /// The caller adds no query after the session is built (the CLI), so a
    /// completed prerequisite's device state may move into its last
    /// dependent instead of being copied. Appending callers keep copies.
    final_plan: bool = false,
    /// Developer switches the facade read from the environment.
    knobs: types.Knobs = .{},

    /// The facade's record of whether the GPU driver is up, shared by every
    /// query of the Problem; null prices the driver setup in every query.
    gpu_driver: ?*gpu.Driver = null,
    /// Where `.hdl` display-task lines go; null is the process's stdout.
    /// Each accepted point's lines arrive in one `writeAll` from the thread
    /// running the query, so concurrent queries write concurrently.
    display: ?*std.Io.Writer = null,
};

/// Fails with `error.GpuBackendUnavailable` for a backend this binary has no
/// kernels for (printing the GPU hardware the probe detected) and
/// `error.InvalidThreadCount` for a zero thread count. A machine without the
/// GPU fails later, when the first query brings up the driver.
pub fn validateBackend(config: Config) !void {
    if (!gpu.requestSupported(config.backend)) {
        const name = @tagName(config.backend);
        // The library's diagnostic channel, which an embedder routes with
        // its own `std_options.logFn`; the CLI's prints to stderr (#13).
        std.log.warn("--backend {s}: this build has no {s} kernels; detected GPU hardware: {s}", .{ name, name, gpu.detectedHardware() });
        return error.GpuBackendUnavailable;
    }
    if (config.solver_threads == 0 or config.device_threads == 0) return error.InvalidThreadCount;
}

/// Lanes per batch: the CPU's f64 vector width (4 on AVX2, 8 on AVX-512).
pub const lane_width = std.simd.suggestVectorLength(f64) orelse 4;

/// One query: its own Circuit instance, work and result arenas, and worker.
/// Heap-pinned because the worker and the progress callback hold its address.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    topology: *const Circuit,
    deck: *const Deck,
    job: requests.Query,
    config: Config,
    circuit: types.Circuit,
    work: std.heap.ArenaAllocator,
    results: std.heap.ArenaAllocator,
    controller: Controller,
    x: ?[]f64 = null,
    published: ?types.Result = null,
    /// What `materialize` builds `circuit` from (`create`).
    initial: ?*Executor,
    take: bool,
    /// `circuit` holds a built circuit that `destroy` frees.
    built: bool = false,
    /// `RunCtx.stream` for this query.
    stream: ?*std.Io.Writer = null,
    /// Queries this one runs as the other lanes of its batch, on its own
    /// worker (`Session` groups them); empty for a lone query.
    peers: []const *Executor = &.{},
    /// The session row, for settling a batch's peers.
    row: u32 = 0,
    /// A peer's failure, set by its batch; `published` holds its success.
    peer_failure: ?QueryError = null,

    /// What one `wait` saw: a checkpoint, the result, an error or a cancel.
    pub const Outcome = Controller.Outcome;

    /// Builds the executor without starting it; its circuit is built on
    /// the worker thread when the first quantum starts (`materialize`), so
    /// the coordinator only books the query. `initial`, when given, must be
    /// a completed `.op` query over the same topology; its device state and
    /// operating point seed this one, and the caller keeps them unchanged
    /// until this query's first quantum stops. With `take`, this is the last
    /// query that will read `initial` (or, without one, the template), so
    /// its device state moves here instead of being copied, and `initial`'s
    /// circuit may be left empty: its result and operating point stay
    /// readable, but nothing may evaluate it again. Fails with
    /// `error.InvalidOperatingPoint` when `initial` is not such a query and
    /// with `validateBackend`'s errors. The run fails with
    /// `error.InvalidAcOverride` when an AC override names no device
    /// parameter, and with `error.TopologyChanged` when the query's variant
    /// or temperature re-wires a device. Caller frees it with `destroy`.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, topology: *const Circuit, deck: *const Deck, job: requests.Query, initial: ?*Executor, take: bool, config: Config) !*Executor {
        try validateBackend(config);
        if (initial) |source| {
            if (source.topology != topology or source.operatingPoint() == null)
                return error.InvalidOperatingPoint;
        }
        const self = try allocator.create(Executor);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .topology = topology,
            .deck = deck,
            .job = job,
            .config = config,
            .circuit = undefined,
            .work = std.heap.ArenaAllocator.init(allocator),
            .results = std.heap.ArenaAllocator.init(allocator),
            .controller = undefined,
            .initial = initial,
            .take = take,
        };
        self.controller = Controller.init(io, self, execute, .{ .report_nonlinear = job == .op });
        return self;
    }

    /// The circuit copy, variant and AC overrides `create` deferred, built
    /// on the worker thread before the analysis runs.
    fn materialize(self: *Executor) !void {
        const started = if (self.controller.options.timing_query != null) std.Io.Timestamp.now(self.io, .awake) else null;
        const topology = self.topology;
        const allocator = self.allocator;
        self.circuit = if (self.initial) |source|
            if (self.take)
                try types.Circuit.fromSnapshotMove(topology, &source.circuit, allocator)
            else
                try types.Circuit.fromSnapshot(topology, &source.circuit, allocator)
        else if (self.take)
            try types.Circuit.instantiateMove(topology, allocator)
        else
            try types.Circuit.instantiate(topology, allocator);
        self.built = true;
        // The multicore refactor follows the device threads unless the
        // solver's own count is set (ESPICE_SOLVER_THREADS).
        const config = self.config;
        const lu_threads: u8 = @intCast(@min(if (config.solver_threads > 1) config.solver_threads else config.device_threads, 16));
        self.circuit.configure(.{ .io = self.io, .threads = config.solver_threads, .lu_threads = lu_threads }, config.knobs);
        if (self.initial) |source| self.x = try self.work.allocator().dupe(f64, source.operatingPoint().?);
        // A dependent copies its prerequisite's circuit, variant included.
        if (self.initial == null) try self.installVariant();
        try self.bindAcOverrides();
        self.circuit.progress = self.controller.callback();
        if (started) |t0| {
            const elapsed = t0.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
            std.debug.print("timing: query {d} {s} setup: {d:.6}ms\n", .{
                @backingInt(self.controller.options.timing_query.?), @tagName(self.job), @as(f64, @floatFromInt(elapsed)) / 1e6,
            });
        }
    }

    /// Writes the query's variant parameters and temperature, then
    /// re-derives the devices once. A nominal query at the deck temperature
    /// touches nothing.
    fn installVariant(self: *Executor) !void {
        const variant = queryVariant(self.job);
        var dirty = false;
        if (variant) |v| {
            const refs, const values = self.deck.variants.writes(v);
            if (refs.len != 0) {
                const params = try self.circuit.collectParams();
                for (refs, values) |r, value| params[r].set(value);
                dirty = true;
            }
        }
        const variant_temp = if (variant) |v| self.deck.variants.temp_c[v] else null;
        if (queryTemp(self.job) orelse variant_temp orelse self.deck.deck_temp) |temp| {
            self.circuit.setCircuitTemp(@floatCast(temp));
            dirty = true;
        }
        if (dirty) try self.circuit.recompute();
    }

    fn bindAcOverrides(self: *Executor) !void {
        if (self.deck.ac_overrides.len == 0) return;
        const params = try self.circuit.collectParams();
        const mapped = try self.work.allocator().alloc(types.AcParam, self.deck.ac_overrides.len);
        for (self.deck.ac_overrides, mapped) |override, *target| {
            for (params) |param| {
                if (param.index == override.index and !param.is_instance and
                    param.type == override.type and
                    std.mem.eql(u8, param.param_name, override.param_name))
                {
                    target.* = .{ .ptr = param, .ac_value = override.value };
                    break;
                }
            } else return error.InvalidAcOverride;
        }
        self.circuit.ac_params = mapped;
    }

    /// Runs the query up to where `quantum` lets it stop, without waiting.
    /// `signal`, when given, is posted once when the quantum stops.
    pub fn start(self: *Executor, quantum: Quantum, signal: ?*std.Io.Semaphore) !void {
        try self.controller.start(quantum, signal);
    }

    /// Waits for the quantum `start` began and publishes a completed result.
    pub fn wait(self: *Executor) !Outcome {
        const outcome = try self.controller.wait();
        if (outcome == .complete) self.published = outcome.complete;
        return outcome;
    }

    /// Whether the started quantum has stopped, so `wait` will not block.
    pub fn stopped(self: *Executor) bool {
        return self.controller.stopped();
    }

    /// Asks the worker to stop at its next checkpoint; see `Worker.cancel`.
    pub fn cancel(self: *Executor) void {
        self.controller.cancel();
    }

    /// Returns the completed result, valid until `destroy`.
    pub fn result(self: *const Executor) ?types.Result {
        return self.published;
    }

    /// Returns the solved operating point of a completed `.op` query, null
    /// for any other query. Valid until `destroy`, even after the circuit
    /// is released.
    pub fn operatingPoint(self: *const Executor) ?[]const f64 {
        return if (self.job == .op and self.published != null) self.x else null;
    }

    /// Cancels and joins the worker, then frees everything the query owns.
    pub fn destroy(self: *Executor) void {
        self.controller.deinit();
        if (self.built) self.circuit.deinit();
        self.work.deinit();
        self.results.deinit();
        self.allocator.destroy(self);
    }

    /// Runs the query, then refuses it if any device latched a VerA
    /// `$fatal`/`$error` (`Hooks.status`), whether the analysis failed on it
    /// or not: a latched device stamps zero rows, which can still solve.
    // ponytail: checked once per query, not per eval; a refused device
    // costs the analysis's own failure path first. Check per Newton
    // iterate if that turns out slow.
    fn execute(ctx: *anyopaque) QueryError!types.Result {
        const self: *Executor = @ptrCast(@alignCast(ctx));
        if (self.peers.len != 0) return self.executeBatch();
        try self.materialize();
        const res = self.runQuery() catch |err| {
            try self.refuseLatched();
            return err;
        };
        try self.refuseLatched();
        return res;
    }

    /// Runs this query and its `peers` as one lane batch: each builds its
    /// circuit, then the operating points (`op.solveLanes`) or `.dc` sweeps
    /// (`dc.runLanes`) run as lanes and each publishes as it would alone. A
    /// batch whose devices print display tasks runs its queries one after
    /// another instead. Every peer ends with `published` or `peer_failure`;
    /// returns this query's own.
    fn executeBatch(self: *Executor) QueryError!types.Result {
        const g = 1 + self.peers.len;
        std.debug.assert(g <= lane_width and (self.job == .op or self.job == .dc));
        var members: [lane_width]*Executor = undefined;
        members[0] = self;
        @memcpy(members[1..g], self.peers);
        var outcomes: [lane_width]QueryError!types.Result = @splat(error.QueryCancelled);
        defer for (members[1..g], outcomes[1..g]) |p, o| {
            if (o) |r| p.published = r else |err| p.peer_failure = err;
        };
        // Lanes whose circuit built, as indices into `members`.
        var live: [lane_width]usize = undefined;
        var n_live: usize = 0;
        for (members[0..g], 0..) |e, k| {
            e.materialize() catch |err| {
                outcomes[k] = err;
                continue;
            };
            e.circuit.progress = self.controller.callback();
            live[n_live] = k;
            n_live += 1;
        }
        if (n_live != 0 and (try members[live[0]].sayNames()).len != 0) {
            for (live[0..n_live]) |k| outcomes[k] = members[k].finishAlone();
            return outcomes[0];
        }
        if (self.job == .dc) {
            var ctxs: [lane_width]types.RunCtx = undefined;
            for (live[0..n_live], 0..) |k, l| {
                members[k].circuit.setSimState(.{ .kind = .dc });
                ctxs[l] = members[k].runCtx();
            }
            var swept: [lane_width]dc.LaneOutcome = undefined;
            if (n_live != 0) dc.runLanes(lane_width, ctxs[0..n_live], self.job.dc, swept[0..n_live]);
            for (live[0..n_live], swept[0..n_live]) |k, o| {
                outcomes[k] = if (o) |r| members[k].label(r) else |err| err;
                members[k].refuseLatched() catch |err| {
                    outcomes[k] = err;
                };
            }
            return outcomes[0];
        }
        var ckts: [lane_width]*types.Circuit = undefined;
        var xs: [lane_width][]f64 = undefined;
        var options: op.Options = undefined;
        for (live[0..n_live], 0..) |k, l| {
            const e = members[k];
            e.circuit.setSimState(.{ .kind = if (e.job.op.tran_op) .ic else .dc });
            options = e.opStart() catch |err| {
                for (live[0..n_live]) |j| outcomes[j] = err;
                return outcomes[0];
            };
            ckts[l] = &e.circuit;
            xs[l] = e.x.?;
        }
        var solved: [lane_width]op.LaneOutcome = undefined;
        if (n_live != 0) op.solveLanes(lane_width, ckts[0..n_live], xs[0..n_live], options, self.deck.nodeset, self.deck.ic, solved[0..n_live]) catch |err| {
            for (live[0..n_live]) |k| outcomes[k] = err;
            return outcomes[0];
        };
        for (live[0..n_live], solved[0..n_live]) |k, o| {
            const e = members[k];
            outcomes[k] = blk: {
                const r = o catch |err| break :blk err;
                if (!r.converged) break :blk error.OpDidNotConverge;
                e.circuit.setSimState(.{ .kind = if (e.job.op.tran_op) .ic else .dc });
                break :blk e.finish();
            };
            e.refuseLatched() catch |err| {
                outcomes[k] = err;
            };
        }
        return outcomes[0];
    }

    /// `execute` past `materialize`, for a batch lane that runs alone.
    fn finishAlone(self: *Executor) QueryError!types.Result {
        const res = self.runQuery() catch |err| {
            try self.refuseLatched();
            return err;
        };
        try self.refuseLatched();
        return res;
    }

    /// `error.DeviceRefused` after logging `<instance>: <file>:<line>:
    /// fatal|error: <message>` for the first instance with a latched status.
    /// A warning, not `log.err`: a test runner fails any test that logs an
    /// error, and refusing is this path's expected outcome.
    fn refuseLatched(self: *const Executor) error{DeviceRefused}!void {
        var buf: [512]u8 = undefined;
        for (self.circuit.batches, self.circuit.batch_types) |b, t| {
            const status = b.hooks.status orelse continue;
            const hit = status(b.ctx, &buf) orelse continue;
            const name = self.deck.card_names.get(t, hit.index) orelse b.type_name;
            std.log.warn("{s}: {s}", .{ name, buf[0..hit.len] });
            return error.DeviceRefused;
        }
    }

    fn runQuery(self: *Executor) !types.Result {
        var par: ?ParEval = null;
        if (self.config.device_threads > 1) {
            par = try ParEval.init(self.allocator, self.io, self.circuit.batches, self.circuit.nnz, self.circuit.n, self.circuit.has_charge, self.config.device_threads);
            self.circuit.par_eval = &par.?;
        }
        defer {
            self.circuit.par_eval = null;
            if (par) |*p| p.deinit();
        }
        const gpu_context = try self.prepareGpu();
        defer if (gpu_context) |g| {
            // `refuseLatched` reads statuses off the host instances.
            g.syncStatus();
            self.circuit.detachGpu();
            g.deinit();
        };
        const lu_context = self.prepareGpuLu();
        defer {
            self.circuit.lu = null;
            if (lu_context) |l| l.deinit();
        }
        // §9.4 display tasks print to stdout by default, unbuffered, so each
        // accepted point's lines land in order with the rest of the run's output.
        var stdout: std.Io.File.Writer = .initStreaming(.stdout(), self.io, &.{});
        const out = self.config.display orelse &stdout.interface;
        var display: types.Display = .{ .names = try self.sayNames(), .staged = .init(self.allocator), .out = out };
        defer display.staged.deinit();
        if (display.names.len != 0) self.circuit.display = &display;
        defer self.circuit.display = null;
        if (self.config.timing_in_depth) (try self.circuit.workspace()).prof.io = self.io;
        defer if (self.config.timing_in_depth) printNewtonSplit(&self.circuit.ws.?, self.job);
        const transient = if (self.job == .op) self.job.op.tran_op else @as(requests.Kind, self.job).transient();
        self.circuit.setSimState(.{
            .kind = switch (self.job) {
                // Small-signal linearizations run as analysis("ac") or ("noise"),
                // LRM Table 4-22, as ngspice's MODEINITSMSIG load sets ANALYSIS_AC
                // for ac, noise, pz and disto (osdiload.c:165). It is what gives a
                // host-integrated idt its 1/(jw) instead of its DC form.
                .ac, .sp, .stb, .pz, .disto, .lstb, .acxf => .ac,
                .noise => .noise,
                else => if (transient) .ic else .dc,
            },
        });
        if (self.job == .op) {
            const options = try self.opStart();
            const solved = try op.solve(&self.circuit, self.x.?, options, self.deck.nodeset, self.deck.ic);
            if (!solved.converged) return error.OpDidNotConverge;
            if (gpu_context) |g| try g.syncHostState();
            // The OP ladder publishes its own sim state (`initial_step`);
            // restore the plain one that dependents inherit.
            self.circuit.setSimState(.{ .kind = if (transient) .ic else .dc });
        } else if (self.job.uic()) {
            self.x = try self.work.allocator().alloc(f64, self.circuit.n);
            @memset(self.x.?, 0);
            for (self.deck.ic) |ic| self.x.?[ic.node] = ic.value;
            for (self.deck.uic_ic) |ic| self.x.?[ic.node] = ic.value;
        }
        return self.finish();
    }

    /// The operating point's start: `x` from the deck's guess, the
    /// template's warm point or zero, and the options that start implies.
    fn opStart(self: *Executor) !op.Options {
        self.x = try self.work.allocator().alloc(f64, self.circuit.n);
        @memset(self.x.?, 0);
        var options = self.job.op;
        if (self.deck.op_guess.len != 0) {
            std.debug.assert(self.deck.op_guess.len == self.circuit.n);
            @memcpy(self.x.?, self.deck.op_guess);
            options.warm_start = true;
        } else if (options.warm_start and self.deck.warm_op.len != 0) {
            std.debug.assert(self.deck.warm_op.len == self.circuit.n);
            @memcpy(self.x.?, self.deck.warm_op);
        } else options.warm_start = false;
        return options;
    }

    /// The analysis proper, from `x` (the operating point, or a `uic` start).
    fn finish(self: *Executor) !types.Result {
        const run_ctx = self.runCtx();
        return self.label(try run(&run_ctx, self.job));
    }

    fn runCtx(self: *Executor) types.RunCtx {
        return .{
            .circuit = &self.circuit,
            .x_op = self.x.?,
            .probes = self.deck.probes,
            .probe_labels = self.deck.probe_labels,
            .source_node = self.deck.source_node,
            .source_branch = self.deck.source_branch,
            .nodeset = self.deck.nodeset,
            .ac_drive = self.deck.ac_drive,
            .variants = self.deck.variants,
            .allocator = self.results.allocator(),
            .scratch_allocator = self.allocator,
            .stream = self.stream,
            .measures = self.deck.measures,
        };
    }

    /// Names a finished result after the query's temperature and variant.
    fn label(self: *Executor, result_in: types.Result) !types.Result {
        var res = result_in;
        // Copies of one card at several temperatures keep apart by name.
        if (queryTemp(self.job)) |temp| res.plotname = try self.results.allocator().print("{s} (temp={d})", .{ res.plotname, temp });
        if (queryVariant(self.job)) |v| res.plotname = try self.results.allocator().print("{s} ({s})", .{ res.plotname, self.deck.variants.labels[v] });
        return res;
    }

    /// `Display.names` from the deck's cards, an unlisted instance under its
    /// type name; empty when no batch has `Hooks.say`.
    fn sayNames(self: *Executor) ![]const []const []const u8 {
        const batches = self.circuit.batches;
        for (batches) |b| {
            if (b.hooks.say != null) break;
        } else return &.{};
        const a = self.work.allocator();
        const names = try a.alloc([]const []const u8, batches.len);
        for (names, batches, self.circuit.batch_types) |*row, b, t| {
            if (b.hooks.say == null) {
                row.* = &.{};
                continue;
            }
            const own = try a.alloc([]const u8, b.count);
            for (own, 0..) |*name, i| name.* = self.deck.card_names.get(t, @intCast(i)) orelse b.type_name;
            row.* = own;
        }
        return names;
    }

    /// The device LU: `Knobs.gpu_lu` (`ESPICE_GPU_LU=1`) forces it on under a
    /// GPU backend, any other value off; otherwise it runs where the matrix is big enough to be
    /// worth asking the driver, on every pivot epoch with enough flops per
    /// column or in all (`GpuLu.admits`), whatever the card's FP64 rate. A
    /// driver that refuses leaves the host LU.
    fn prepareGpuLu(self: *Executor) ?*gpu_lu.GpuLu {
        if (self.config.backend == .cpu) return null;
        var forced = false;
        if (self.config.knobs.gpu_lu) |on| {
            if (!on) return null;
            forced = true;
        } else if (self.circuit.n < gpu_lu_min_n) return null;
        const context = gpu_lu.GpuLu.init(self.allocator, self.circuit.n, self.circuit.nnz, self.config.knobs) catch |err| {
            if (forced) std.debug.print("warning: device LU unavailable ({s})\n", .{@errorName(err)});
            return null;
        };
        context.forced = forced;
        self.circuit.lu = context;
        return context;
    }

    fn prepareGpu(self: *Executor) !?*gpu.GpuContext {
        if (self.config.backend == .cpu) return null;
        const explicit = self.config.gpu_explicit or self.config.backend != .auto;
        const c = &self.circuit;
        const host: gpu.Host = .{ .batches = c.batches, .planes = c.ownPlanes(), .n = c.n, .trash_slot = c.trash_slot, .has_charge = c.has_charge, .knobs = c.knobs };
        const context = gpu.GpuContext.init(self.allocator, host, self.config.gpu_driver, explicit, self.config.device_threads, expectedEvals(self.job)) catch |err| {
            if (!gpu.fallsBack(self.config.backend, explicit, err)) {
                std.log.warn("--backend {s}: GPU unavailable ({s}); detected GPU hardware: {s}", .{ @tagName(self.config.backend), @errorName(err), gpu.detectedHardware() });
                return err;
            }
            if (gpu.declineKind(err) != .policy)
                std.log.warn("GPU unavailable ({s}); running on the CPU", .{@errorName(err)});
            return null;
        };
        self.circuit.attachGpu(context);
        return context;
    }
};

/// Below this many unknowns `auto` never asks the driver about the device
/// LU. ponytail: the E2 decks start at 17k; measure a data-center card
/// before trusting the bar.
const gpu_lu_min_n = 10_000;

/// The temperature `job` runs at when it overrides the deck's.
fn queryTemp(job: requests.Query) ?f64 {
    return switch (job) {
        inline else => |o| o.tol.temp_c,
    };
}

fn queryVariant(job: requests.Query) ?u32 {
    return switch (job) {
        inline else => |o| o.tol.variant,
    };
}

/// `--timing-in-depth`: where the query's Newton time went.
/// The matrix size and the flat LU's fill (L + U + diagonal) close the line.
fn printNewtonSplit(ws: *const converger.Workspace, job: requests.Query) void {
    const p = ws.prof;
    const ms = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1e6;
        }
    }.f;
    std.debug.print("timing: {s} newton: iterations={d} factors={d} eval={d:.3}ms load={d:.3}ms factor={d:.3}ms solve={d:.3}ms update={d:.3}ms n={d} lu_nnz={d}\n", .{
        @tagName(job), p.counts[0], p.counts[1], ms(p.ns[0]), ms(p.ns[1]), ms(p.ns[2]), ms(p.ns[3]), ms(p.ns[4]), ws.dx.len,
        switch (ws.slv.engine) {
            .lu => |lu| lu.li.items.len + lu.ui.items.len + lu.n,
            .tri, .bbd => 0,
        },
    });
}

/// A rough count of the device evals `job` runs, for the GPU cost model:
/// four per transient step (measured 4.3 on mos1_2000 and 5.2 on
/// vacask_ring) at the step the deck asks for, three per dc point, and a
/// Newton solve's worth for an operating point. Small-signal analyses
/// linearize once.
/// ponytail: a static guess; count evals as the query runs and move to the
/// GPU mid-run if a guess ever misprices a deck.
fn expectedEvals(job: requests.Query) f64 {
    return switch (job) {
        .op => 30,
        .dc => |d| blk: {
            const inner = @abs(d.stop - d.start) / @max(@abs(d.step), 1e-300) + 1;
            const outer = if (d.target2 != null) @abs(d.stop2 - d.start2) / @max(@abs(d.step2), 1e-300) + 1 else 1;
            break :blk 3 * inner * outer;
        },
        .tran => |t| 4 * t.t_stop / @min(t.dt_init, t.dt_max orelse t.t_stop / 50.0),
        .ac, .noise, .sp, .stb, .tf, .pz, .disto, .four, .dcmatch, .sens, .lstb, .acxf, .dcxf, .dcinc, .acmatch, .dcsens => 1,
        else => 200,
    };
}

fn module(comptime kind: requests.Kind) type {
    return switch (kind) {
        .op => op,
        .dc => @import("dc/dc.zig"),
        .tf => @import("dc/tf.zig"),
        .dcmatch => @import("dc/dcmatch.zig"),
        .dcsens => @import("dc/dcmatch.zig").Sens,
        .acmatch => @import("ac/acmatch.zig"),
        .ac => @import("ac/ac.zig"),
        .noise => @import("ac/noise.zig"),
        .sp => @import("ac/sp.zig"),
        .stb => @import("ac/stb.zig"),
        .lstb => @import("ac/lstb.zig"),
        .acxf => @import("ac/xf.zig"),
        .dcxf => @import("dc/xf.zig"),
        .dcinc => @import("dc/xf.zig").Inc,
        .tran => @import("tran/tran.zig"),
        .tran_noise => @import("tran/tran_noise.zig"),
        .envelope => @import("tran/envelope.zig"),
        .matex => @import("tran/matex.zig"),
        .pss => @import("pss/pss.zig"),
        .pac => @import("pss/pac.zig"),
        .pnoise => @import("pss/pnoise.zig"),
        .hb => @import("pss/hb.zig"),
        .pxf => @import("pss/pxf.zig"),
        .hbac => @import("pss/hb_lptv.zig").Ac,
        .hbxf => @import("pss/hb_lptv.zig").Xf,
        .hbnoise => @import("pss/hb_lptv.zig").Noise,
        .hblin => @import("pss/hb_lptv.zig").Lin,
        .phasenoise => @import("pss/phasenoise.zig"),
        .qpss => @import("pss/qpss.zig"),
        .four => @import("post/four.zig"),
        .disto => @import("post/disto.zig"),
        .fft => @import("post/fft.zig"),
        .sens => @import("sweep/sens.zig"),
        .mc => @import("sweep/mc.zig"),
        .temp => @import("sweep/temp_sweep.zig"),
        .pz => @import("eigen/pz.zig"),
    };
}

fn run(ctx: *const types.RunCtx, job: requests.Query) !types.Result {
    switch (job) {
        inline else => |opts, tag| return module(tag).run(ctx, opts),
    }
}
