//! Executor: one query's mutable numerical state and the worker thread that
//! runs it. Prepared topology and the deck are borrowed; an accepted OP from a
//! dependency is copied before use. Dispatches to the analysis leaves.
const std = @import("std");
const Circuit = @import("device").Circuit;
const Deck = @import("core").Deck;
const requests = @import("core").query;
const types = @import("types.zig");
const op = @import("dc/op.zig");
const gpu = @import("gpu.zig");
const gpu_lu = @import("gpu_lu.zig");
const ParEval = @import("par_eval.zig").ParEval;
const Controller = @import("worker.zig").Worker(types.Result);
const Quantum = @import("worker.zig").Quantum;
const converger = @import("solver").converger;

/// Per-problem execution settings, shared by every query.
pub const Config = struct {
    pub const Backend = gpu.Request;
    backend: gpu.Request = .cpu,
    /// The user named the GPU: bypass the work gate, and fail rather than fall
    /// back when the machine cannot run it.
    gpu_explicit: bool = false,
    solver_threads: u8 = 1,
    /// Device-stamp lanes; above 1 each query builds a ParEval.
    device_threads: u32 = 1,
    /// Print per-query setup and per-checkpoint timing to stderr.
    timing_in_depth: bool = false,
    /// `direct.Params.fast_mode` for every Newton solve (`--lu-fast`).
    lu_fast: bool = false,
};

/// Rejects a backend this binary cannot serve (printing what it detected)
/// and zero thread counts.
pub fn validateBackend(config: Config) !void {
    if (!gpu.requestSupported(config.backend)) {
        std.debug.print("Error: GPU backend {s} requested; detected artifacts: {s}\n", .{ @tagName(config.backend), gpu.detectedName() });
        return error.GpuBackendUnavailable;
    }
    if (config.solver_threads == 0 or config.device_threads == 0) return error.InvalidThreadCount;
}

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

    pub const Outcome = Controller.Outcome;

    /// Builds the executor without starting it. `initial`, when given, must be
    /// a completed `.op` query over the same topology; its device state and
    /// operating point seed this one.
    pub fn create(allocator: std.mem.Allocator, io: std.Io, topology: *const Circuit, deck: *const Deck, job: requests.Query, initial: ?*const Executor, config: Config) !*Executor {
        try validateBackend(config);
        if (initial) |source| {
            if (source.topology != topology or source.operatingPoint() == null)
                return error.InvalidOperatingPoint;
        }
        const self = try allocator.create(Executor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .topology = topology,
            .deck = deck,
            .job = job,
            .config = config,
            .circuit = if (initial) |source|
                try types.Circuit.fromSnapshot(topology, &source.circuit, allocator)
            else
                try types.Circuit.instantiate(topology, allocator),
            .work = std.heap.ArenaAllocator.init(allocator),
            .results = std.heap.ArenaAllocator.init(allocator),
            .controller = undefined,
        };
        errdefer self.circuit.deinit();
        errdefer self.work.deinit();
        errdefer self.results.deinit();
        // The multicore refactor follows the device threads unless the
        // solver's own count is set (ESPICE_SOLVER_THREADS).
        const lu_threads: u8 = @intCast(@min(if (config.solver_threads > 1) config.solver_threads else config.device_threads, 16));
        self.circuit.solver_execution = .{ .io = io, .threads = config.solver_threads, .lu_threads = lu_threads };
        self.circuit.lu_fast = config.lu_fast;
        if (initial) |source| self.x = try self.work.allocator().dupe(f64, source.operatingPoint().?);
        // A dependent copies its prerequisite's circuit, variant included.
        if (initial == null) try self.installVariant();
        try self.bindAcOverrides();
        self.controller = Controller.init(io, self, execute, .{ .report_nonlinear = job == .op });
        self.circuit.progress = self.controller.callback();
        return self;
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
    pub fn start(self: *Executor, quantum: Quantum) !void {
        try self.controller.start(quantum);
    }

    /// Waits for the quantum `start` began and publishes a completed result.
    pub fn wait(self: *Executor) !Outcome {
        const outcome = try self.controller.wait();
        if (outcome == .complete) self.published = outcome.complete;
        return outcome;
    }

    pub fn cancel(self: *Executor) void {
        self.controller.cancel();
    }

    /// Returns the completed result, valid until `destroy`.
    pub fn result(self: *const Executor) ?types.Result {
        return self.published;
    }

    /// Returns the solved operating point of a completed `.op` query.
    pub fn operatingPoint(self: *const Executor) ?[]const f64 {
        return if (self.job == .op and self.published != null) self.x else null;
    }

    /// Cancels and joins the worker, then frees everything the query owns.
    pub fn destroy(self: *Executor) void {
        self.controller.deinit();
        self.circuit.deinit();
        self.work.deinit();
        self.results.deinit();
        self.allocator.destroy(self);
    }

    fn execute(ctx: *anyopaque) !types.Result {
        const self: *Executor = @ptrCast(@alignCast(ctx));
        var par: ?ParEval = null;
        if (self.config.device_threads > 1) {
            par = try ParEval.init(self.allocator, self.io, self.circuit.batches, self.circuit.nnz, self.circuit.n, self.circuit.has_charge, self.circuit.trash_slot, self.config.device_threads);
            self.circuit.par_eval = &par.?;
        }
        defer {
            self.circuit.par_eval = null;
            if (par) |*p| p.deinit();
        }
        const gpu_context = try self.prepareGpu();
        defer {
            self.circuit.gpu_hook = null;
            if (gpu_context) |g| g.deinit();
        }
        const lu_context = self.prepareGpuLu();
        defer {
            self.circuit.lu_hook = null;
            if (lu_context) |l| l.deinit();
        }
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
            self.x = try self.work.allocator().alloc(f64, self.circuit.n);
            @memset(self.x.?, 0);
            const solved = try op.solve(&self.circuit, self.x.?, self.job.op, self.deck.nodeset, self.deck.ic);
            if (!solved.converged) return error.OpDidNotConverge;
            if (gpu_context) |g| try g.syncHostState();
            // The OP ladder publishes its own sim state (`initial_step`);
            // restore the plain one that dependents inherit.
            self.circuit.setSimState(.{ .kind = if (transient) .ic else .dc });
        } else if (self.job == .tran and self.job.tran.uic) {
            self.x = try self.work.allocator().alloc(f64, self.circuit.n);
            @memset(self.x.?, 0);
            for (self.deck.ic) |ic| self.x.?[ic.node] = ic.value;
        }
        const run_ctx: types.RunCtx = .{
            .circuit = &self.circuit,
            .x_op = self.x.?,
            .probes = self.deck.probes,
            .probe_labels = self.deck.probe_labels,
            .source_node = self.deck.source_node,
            .source_branch = self.deck.source_branch,
            .ac_drive = self.deck.ac_drive,
            .variants = self.deck.variants,
            .allocator = self.results.allocator(),
            .scratch_allocator = self.allocator,
        };
        var res = try run(&run_ctx, self.job);
        // Copies of one card at several temperatures keep apart by name.
        if (queryTemp(self.job)) |temp| res.plotname = try std.fmt.allocPrint(self.results.allocator(), "{s} (temp={d})", .{ res.plotname, temp });
        if (queryVariant(self.job)) |v| res.plotname = try std.fmt.allocPrint(self.results.allocator(), "{s} ({s})", .{ res.plotname, self.deck.variants.labels[v] });
        return res;
    }

    /// The device LU: `ESPICE_GPU_LU=1` forces it on under a GPU backend,
    /// `=0` off; otherwise it runs only where the card's FP64 is fast
    /// (`GpuLu.fp64Fast`) and the matrix is big enough to be worth asking
    /// the driver. On a consumer card it lost to 8 host threads on every
    /// E2 deck (docs/solvers/gpu-lu.md). A driver that refuses leaves the
    /// host LU.
    fn prepareGpuLu(self: *Executor) ?*gpu_lu.GpuLu {
        if (self.config.backend == .cpu) return null;
        var forced = false;
        if (std.c.getenv("ESPICE_GPU_LU")) |env| {
            if (!std.mem.eql(u8, std.mem.span(env), "1")) return null;
            forced = true;
        } else if (self.circuit.n < gpu_lu_min_n) return null;
        const context = gpu_lu.GpuLu.init(self.allocator, self.circuit.n, self.circuit.nnz) catch |err| {
            if (forced) std.debug.print("warning: device LU unavailable ({s})\n", .{@errorName(err)});
            return null;
        };
        if (!forced and !context.fp64Fast()) {
            context.deinit();
            return null;
        }
        self.circuit.lu_hook = .{ .ctx = context, .solve = gpu_lu.GpuLu.solve };
        return context;
    }

    fn prepareGpu(self: *Executor) !?*gpu.GpuContext {
        if (self.config.backend == .cpu) return null;
        const explicit = self.config.gpu_explicit or self.config.backend != .auto;
        const context = gpu.GpuContext.init(self.allocator, &self.circuit, explicit, self.config.device_threads, expectedEvals(self.job)) catch |err| {
            if (explicit and gpu.declineKind(err) == .machine) {
                std.debug.print("Error: GPU requested but unavailable ({s}); detected artifacts: {s}\n", .{ @errorName(err), gpu.detectedName() });
                return err;
            }
            if (gpu.declineKind(err) != .policy)
                std.debug.print("warning: GPU unavailable ({s}); running on the CPU\n", .{@errorName(err)});
            return null;
        };
        self.circuit.gpu_hook = context.hook();
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
        @tagName(job),                                                       p.counts[0], p.counts[1], ms(p.ns[0]), ms(p.ns[1]), ms(p.ns[2]), ms(p.ns[3]), ms(p.ns[4]), ws.dx.len,
        if (ws.slv.lu) |lu| lu.li.items.len + lu.ui.items.len + lu.n else 0,
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

const Tolerances = @import("core").numerics.Tolerances;

comptime {
    for (@typeInfo(requests.Kind).@"enum".fields) |field|
        validate(module(@field(requests.Kind, field.name)));
}

/// Checks at comptime that analysis module `T` exposes
/// `run(*const types.RunCtx, T.Options) !types.Result` and that `Options`
/// carries `tol: Tolerances`, so a drifted signature fails here with a
/// readable error instead of deep in dispatch.
fn validate(comptime T: type) void {
    const name = @typeName(T);

    if (!@hasDecl(T, "Options"))
        @compileError(name ++ ": contract requires `pub const Options`");
    if (@typeInfo(T.Options) != .@"struct")
        @compileError(name ++ ".Options must be a struct");

    if (!@hasField(T.Options, "tol"))
        @compileError(name ++ ".Options must have field `tol: Tolerances`");
    if (@FieldType(T.Options, "tol") != Tolerances)
        @compileError(name ++ ".Options.tol must be Tolerances");

    if (!@hasDecl(T, "run"))
        @compileError(name ++ ": contract requires `pub fn run(*const types.RunCtx, T.Options) !types.Result`");

    const info = @typeInfo(@TypeOf(T.run));
    if (info != .@"fn")
        @compileError(name ++ ".run must be a function");
    const f = info.@"fn";
    if (f.params.len != 2 or
        f.params[0].type != *const types.RunCtx or
        f.params[1].type != T.Options)
        @compileError(name ++ ".run: expected params (*const types.RunCtx, " ++ name ++ ".Options)");

    const ret = @typeInfo(f.return_type.?);
    if (ret != .error_union or ret.error_union.payload != types.Result)
        @compileError(name ++ ".run must return !types.Result");
}
