//! One query's mutable numerical state. Prepared topology and requests are
//! borrowed for its lifetime; accepted OP products are copied before use.
const std = @import("std");
const Prepared = @import("problem_types").Prepared;
const requests = @import("requests");
const types = @import("types.zig");
const dispatch = @This();
const gpu = @import("gpu.zig");
const ParEval = @import("device_eval").ParEval;
const Controller = Worker(types.Result);
const progress = @import("progress.zig");

// Inputs: a prepared circuit, query and optional accepted OP; output: progress
// and one retained Result. Cardinality: one controller per active query. All
// controller fields are cold and used together; numeric planes stay in Circuit.
// IDs remain in the scheduler; this pinned object's pointers identify callbacks.
// Work and results have separate query lifetimes. Clones share only immutable
// topology/tapes; every device history, parameter and solver plane is private.
pub const Config = struct {
    pub const Backend = gpu.Request;
    backend: gpu.Request = .cpu,
    gpu_explicit: bool = false,
    solver_threads: u8 = 1,
    device_threads: u32 = 1,
    timing_in_depth: bool = false,
};

pub fn validateBackend(config: Config) !void {
    if (!gpu.requestSupported(config.backend)) {
        std.debug.print("Error: GPU backend {s} requested; detected artifacts: {s}\n", .{ @tagName(config.backend), gpu.detectedName() });
        return error.GpuBackendUnavailable;
    }
    if (config.solver_threads == 0 or config.device_threads == 0) return error.InvalidThreadCount;
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    prepared: *const Prepared,
    job: requests.Query,
    config: Config,
    circuit: types.Circuit,
    work: std.heap.ArenaAllocator,
    results: std.heap.ArenaAllocator,
    controller: Controller,
    x: ?[]f64 = null,
    published: ?types.Result = null,

    pub const Outcome = Controller.Outcome;

    pub fn create(allocator: std.mem.Allocator, io: std.Io, prepared: *const Prepared, job: requests.Query, initial: ?*const Executor, config: Config) !*Executor {
        try validateBackend(config);
        if (initial) |source| {
            if (source.prepared != prepared or source.operatingPoint() == null)
                return error.InvalidOperatingPoint;
        }
        const self = try allocator.create(Executor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .prepared = prepared,
            .job = job,
            .config = config,
            .circuit = if (initial) |source|
                try types.Circuit.fromSnapshot(&prepared.circuit, &source.circuit, allocator)
            else
                try types.Circuit.instantiate(&prepared.circuit, allocator),
            .work = std.heap.ArenaAllocator.init(allocator),
            .results = std.heap.ArenaAllocator.init(allocator),
            .controller = undefined,
        };
        errdefer self.circuit.deinit();
        errdefer self.work.deinit();
        errdefer self.results.deinit();
        self.circuit.solver_execution = .{ .io = io, .threads = config.solver_threads };
        if (initial) |source| self.x = try self.work.allocator().dupe(f64, source.operatingPoint().?);
        if (prepared.deck_temp) |temp| if (initial == null) {
            self.circuit.setCircuitTemp(@floatCast(temp));
            try self.circuit.recompute();
        };
        try self.bindAcOverrides();
        self.controller = Controller.init(io, self, execute, .{ .report_nonlinear = job == .op });
        self.circuit.progress = self.controller.callback();
        return self;
    }

    fn bindAcOverrides(self: *Executor) !void {
        if (self.prepared.ac_overrides.len == 0) return;
        const params = try self.circuit.collectParams();
        const mapped = try self.work.allocator().alloc(types.AcParam, self.prepared.ac_overrides.len);
        for (self.prepared.ac_overrides, mapped) |override, *target| {
            for (params) |param| {
                if (param.index == override.index and !param.is_instance and
                    std.mem.eql(u8, param.device_type, override.type_name) and
                    std.mem.eql(u8, param.param_name, override.param_name))
                {
                    target.* = .{ .ptr = param, .ac_value = override.value };
                    break;
                }
            } else return error.InvalidAcOverride;
        }
        self.circuit.ac_params = mapped;
    }

    pub fn start(self: *Executor) !void {
        try self.controller.start();
    }

    pub fn wait(self: *Executor) !Outcome {
        const outcome = try self.controller.wait();
        if (outcome == .complete) self.published = outcome.complete;
        return outcome;
    }

    pub fn advance(self: *Executor) !Outcome {
        try self.start();
        return self.wait();
    }

    pub fn cancel(self: *Executor) void {
        self.controller.cancel();
    }

    pub fn result(self: *const Executor) ?types.Result {
        return self.published;
    }

    pub fn operatingPoint(self: *const Executor) ?[]const f64 {
        return if (self.job == .op and self.published != null) self.x else null;
    }

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
            self.circuit.gpu_active = false;
            if (gpu_context) |g| g.deinit();
        }
        const transient = switch (self.job) {
            .tran, .four, .tran_noise, .envelope, .pss, .qpss, .pnoise, .pac, .pxf => true,
            .op => |opts| opts.tran_op,
            else => false,
        };
        self.circuit.setSimState(.{ .kind = if (transient) .ic else .dc });
        if (self.job == .op) {
            self.x = try self.work.allocator().alloc(f64, self.circuit.n);
            @memset(self.x.?, 0);
            const solved = try dispatch.op.solve(&self.circuit, self.x.?, self.job.op);
            if (!solved.converged) return error.OpDidNotConverge;
            if (gpu_context) |g| try g.syncHostState();
            // Host simulation flags are newer than the final device launch.
            self.circuit.setSimState(.{ .kind = if (transient) .ic else .dc });
        } else if (self.job == .tran and self.job.tran.uic) {
            self.x = try self.work.allocator().alloc(f64, self.circuit.n);
            @memset(self.x.?, 0);
            for (self.prepared.ic) |ic| self.x.?[ic.node] = ic.value;
        }
        const run_ctx: types.RunCtx = .{
            .circuit = &self.circuit,
            .x_op = self.x,
            .probes = self.prepared.probes,
            .probe_labels = self.prepared.probe_labels,
            .source_node = self.prepared.source_node,
            .source_branch = self.prepared.source_branch,
            .ac_drive = self.prepared.ac_drive,
            .allocator = self.results.allocator(),
            .scratch_allocator = self.allocator,
        };
        return dispatch.run(&run_ctx, self.job);
    }

    fn prepareGpu(self: *Executor) !?*gpu.GpuContext {
        if (self.config.backend == .cpu) return null;
        const explicit = self.config.gpu_explicit or self.config.backend != .auto;
        const context = gpu.GpuContext.init(self.allocator, &self.circuit, explicit) catch |err| {
            if (explicit and gpu.declineKind(err) == .machine) {
                std.debug.print("Error: GPU requested but unavailable ({s}); detected artifacts: {s}\n", .{ @errorName(err), gpu.detectedName() });
                return err;
            }
            if (gpu.declineKind(err) != .policy)
                std.debug.print("warning: GPU unavailable ({s}); running on the CPU\n", .{@errorName(err)});
            return null;
        };
        self.circuit.gpu_hook = context.hook();
        self.circuit.gpu_active = true;
        return context;
    }
};

const modules = @This();
const RunCtx = @import("types.zig").RunCtx;
const Result = @import("types.zig").Result;

// -- DC / Operating Point --
pub const op = @import("dc/op.zig");
pub const dc = @import("dc/dc.zig");
pub const tf = @import("dc/tf.zig");
pub const dcmatch = @import("dc/dcmatch.zig");

// -- Frequency-domain (small-signal AC) --
pub const ac = @import("ac/ac.zig");
pub const noise = @import("ac/noise.zig");
pub const sp = @import("ac/sp.zig");
pub const stb = @import("ac/stb.zig");

// -- Time-domain --
pub const tran = @import("tran/tran.zig");
pub const tran_noise = @import("tran/tran_noise.zig");
pub const envelope = @import("tran/envelope.zig");
pub const matex = @import("tran/matex.zig");

// -- Periodic steady-state / LPTV --
pub const pss = @import("pss/pss.zig");
pub const pac = @import("pss/pac.zig");
pub const pnoise = @import("pss/pnoise.zig");
pub const hb = @import("pss/hb.zig");
pub const pxf = @import("pss/pxf.zig");
pub const qpss = @import("pss/qpss.zig");

// -- Time→Frequency post-processing --
pub const four = @import("post/four.zig");
pub const disto = @import("post/disto.zig");

// -- Parameter sweep / statistical --
pub const sens = @import("sweep/sens.zig");
pub const mc = @import("sweep/mc.zig");
pub const temp_sweep = @import("sweep/temp_sweep.zig");

// -- Eigenvalue --
pub const pz = @import("eigen/pz.zig");

// ---------------------------------------------------------------------------
// Analysis dispatch: SPICE keyword → AnalysisId → module.run()
// ---------------------------------------------------------------------------

pub const AnalysisId = @import("requests").Kind;

pub fn Module(comptime id: AnalysisId) type {
    return @field(modules, if (id == .temp) "temp_sweep" else @tagName(id));
}

pub const Analysis = @import("requests").Keywords;

// ---------------------------------------------------------------------------
// Job — tagged union, each variant is that module's Options
// ---------------------------------------------------------------------------

pub const Job = @import("requests").Query;

// ---------------------------------------------------------------------------
// Dispatch — n lines, one switch, pure function per analysis
// ---------------------------------------------------------------------------

pub fn run(ctx: *const RunCtx, job: Job) !Result {
    switch (job) {
        inline else => |opts, tag| return Module(tag).run(ctx, opts),
    }
}

const root = @import("types.zig");
const Tolerances = @import("numerics").Tolerances;

comptime {
    for (@typeInfo(AnalysisId).@"enum".fields) |field|
        validate(Module(@field(AnalysisId, field.name)));
}

/// Comptime validation: every analysis module is one pure transformation,
///
///   run: (*const root.RunCtx, T.Options) !root.Result
///
/// Options must carry a `tol: Tolerances` field so preparation can
/// set accuracy profiles uniformly. Checked by shape so a drifted signature
/// fails here with a readable error instead of deep in root.zig's dispatch.
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
        @compileError(name ++ ": contract requires `pub fn run(*const root.RunCtx, T.Options) !root.Result`");

    const info = @typeInfo(@TypeOf(T.run));
    if (info != .@"fn")
        @compileError(name ++ ".run must be a function");
    const f = info.@"fn";
    if (f.params.len != 2 or
        f.params[0].type != *const root.RunCtx or
        f.params[1].type != T.Options)
        @compileError(name ++ ".run: expected params (*const root.RunCtx, " ++ name ++ ".Options)");

    const ret = @typeInfo(f.return_type.?);
    if (ret != .error_union or ret.error_union.payload != root.Result)
        @compileError(name ++ ".run must return !root.Result");
}

const WorkerOptions = struct {
    stack_size: usize = 512 * 1024 * 1024,
    /// OP can expose Newton iterations; other queries publish outer boundaries.
    report_nonlinear: bool = false,
    timing_query: ?requests.QueryId = null,
};

// ponytail: retain one thread stack per started query; use explicit phase
// storage if retained stacks become the limiting resource.
fn Worker(comptime Product: type) type {
    return struct {
        io: std.Io,
        ctx: *anyopaque,
        run: *const fn (*anyopaque) anyerror!Product,
        options: WorkerOptions,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        state: State = .created,
        cancel_requested: std.atomic.Value(bool) = .init(false),
        timed_from: ?std.Io.Timestamp = null,
        active_ns: i96 = 0,

        const Self = @This();
        const State = union(enum(u8)) {
            created,
            running,
            paused: progress.Event,
            finished: anyerror!Product,
        };

        pub const Outcome = union(enum(u8)) {
            progress: progress.Event,
            complete: Product,
            failed: anyerror,
            cancelled,
        };

        pub fn init(io: std.Io, ctx: *anyopaque, execute_fn: *const fn (*anyopaque) anyerror!Product, options: WorkerOptions) Self {
            return .{ .io = io, .ctx = ctx, .run = execute_fn, .options = options };
        }

        pub fn callback(self: *Self) progress.Callback {
            return .{ .ctx = self, .yield_fn = checkpoint };
        }

        /// Start one quantum without waiting, so the coordinator can start a batch.
        /// A failed thread spawn leaves the query unstarted and retryable.
        pub fn start(self: *Self) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            switch (self.state) {
                .created => {
                    self.state = .running;
                    self.thread = std.Thread.spawn(.{ .stack_size = self.options.stack_size }, main, .{self}) catch |err| {
                        self.state = .created;
                        return err;
                    };
                },
                .paused => {
                    self.state = .running;
                    self.changed.broadcast(self.io);
                },
                .running => return error.AlreadyRunning,
                .finished => {},
            }
        }

        /// Wait for the quantum started by start(), or read an existing terminal result.
        pub fn wait(self: *Self) !Outcome {
            const outcome = try self.waitOutcome();
            if (outcome != .progress) if (self.thread) |thread| {
                thread.join();
                self.thread = null;
            };
            return outcome;
        }

        fn waitOutcome(self: *Self) !Outcome {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (true) switch (self.state) {
                .created => return error.NotStarted,
                .running => self.changed.waitUncancelable(self.io, &self.mutex),
                .paused => |event| {
                    if (self.cancel_requested.load(.monotonic)) {
                        self.changed.waitUncancelable(self.io, &self.mutex);
                    } else return .{ .progress = event };
                },
                .finished => |result| {
                    const value = result catch |err| return if (err == error.QueryCancelled)
                        .cancelled
                    else
                        .{ .failed = err };
                    return .{ .complete = value };
                },
            };
        }

        pub fn advance(self: *Self) !Outcome {
            try self.start();
            return self.wait();
        }

        /// Request cancellation. A running query observes it at its next checkpoint.
        pub fn cancel(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.state == .finished) return;
            self.cancel_requested.store(true, .monotonic);
            if (self.state == .created) self.state = .{ .finished = error.QueryCancelled };
            self.changed.broadcast(self.io);
        }

        /// Joins before releasing the controller; run's defers finish before return.
        pub fn deinit(self: *Self) void {
            self.cancel();
            if (self.thread) |thread| thread.join();
        }

        fn checkpoint(ctx: *anyopaque, event: progress.Event) error{QueryCancelled}!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Suppressed inner iterations only poll cancellation; scheduler
            // state is touched at the outer query boundary under the mutex.
            if (event.phase == .nonlinear and !self.options.report_nonlinear) {
                if (self.cancel_requested.load(.monotonic)) return error.QueryCancelled;
                return;
            }
            if (self.options.timing_query) |id| {
                const elapsed = self.timeQuantum();
                if (event.simulation_time) |t| {
                    std.debug.print("timing: query {d} {s} attempt={d} accepted={?d} t={e:.6}s dt={?e:.6}s next_dt={?e:.6}s: {d:.6}ms\n", .{
                        @intFromEnum(id), @tagName(event.phase), event.completed, event.accepted, t, event.step_size, event.next_step, milliseconds(elapsed),
                    });
                } else {
                    std.debug.print("timing: query {d} {s} checkpoint={d}/{d}: {d:.6}ms\n", .{
                        @intFromEnum(id), @tagName(event.phase), event.completed, event.total, milliseconds(elapsed),
                    });
                }
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.cancel_requested.load(.monotonic)) return error.QueryCancelled;

            self.state = .{ .paused = event };
            self.changed.broadcast(self.io);
            while (self.state == .paused and !self.cancel_requested.load(.monotonic))
                self.changed.waitUncancelable(self.io, &self.mutex);
            if (self.cancel_requested.load(.monotonic)) return error.QueryCancelled;
            if (self.options.timing_query != null) self.timed_from = std.Io.Timestamp.now(self.io, .awake);
        }

        fn timeQuantum(self: *Self) i96 {
            const before = self.timed_from orelse return 0;
            const elapsed = before.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
            self.timed_from = null;
            self.active_ns += elapsed;
            return elapsed;
        }

        fn main(self: *Self) void {
            if (self.options.timing_query != null) self.timed_from = std.Io.Timestamp.now(self.io, .awake);
            const result = self.run(self.ctx);
            if (self.options.timing_query) |id| {
                const tail = self.timeQuantum();
                const status = if (result) |_| "complete" else |err| @errorName(err);
                std.debug.print("timing: query {d} {s}: final={d:.6}ms active_total={d:.6}ms\n", .{
                    @intFromEnum(id), status, milliseconds(tail), milliseconds(self.active_ns),
                });
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state = .{ .finished = if (self.cancel_requested.load(.monotonic)) error.QueryCancelled else result };
            self.changed.broadcast(self.io);
        }
    };
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .Worker = Worker,
} else {};

fn milliseconds(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}
