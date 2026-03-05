//! One query's mutable numerical state. Prepared topology and requests are
//! borrowed for its lifetime; accepted OP products are copied before use.
const std = @import("std");
const Prepared = @import("problem_types").Prepared;
const requests = @import("requests");
const types = @import("types.zig");
const op = @import("dc/op.zig");
const gpu = @import("gpu.zig");
const ParEval = @import("device_eval").ParEval;
const Controller = @import("worker.zig").Worker(types.Result);

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
            const solved = try op.solve(&self.circuit, self.x.?, self.job.op);
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
        return run(&run_ctx, self.job);
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

fn module(comptime kind: requests.Kind) type {
    return switch (kind) {
        .op => op,
        .dc => @import("dc/dc.zig"),
        .tf => @import("dc/tf.zig"),
        .dcmatch => @import("dc/dcmatch.zig"),
        .ac => @import("ac/ac.zig"),
        .noise => @import("ac/noise.zig"),
        .sp => @import("ac/sp.zig"),
        .stb => @import("ac/stb.zig"),
        .tran => @import("tran/tran.zig"),
        .tran_noise => @import("tran/tran_noise.zig"),
        .envelope => @import("tran/envelope.zig"),
        .matex => @import("tran/matex.zig"),
        .pss => @import("pss/pss.zig"),
        .pac => @import("pss/pac.zig"),
        .pnoise => @import("pss/pnoise.zig"),
        .hb => @import("pss/hb.zig"),
        .pxf => @import("pss/pxf.zig"),
        .qpss => @import("pss/qpss.zig"),
        .four => @import("post/four.zig"),
        .disto => @import("post/disto.zig"),
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

const Tolerances = @import("numerics").Tolerances;

comptime {
    for (@typeInfo(requests.Kind).@"enum".fields) |field|
        validate(module(@field(requests.Kind, field.name)));
}

/// Comptime validation: every analysis module is one pure transformation,
///
///   run: (*const types.RunCtx, T.Options) !types.Result
///
/// Options must carry a `tol: Tolerances` field so preparation can
/// set accuracy profiles uniformly. Checked by shape so a drifted signature
/// fails here with a readable error instead of deep in query dispatch.
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
