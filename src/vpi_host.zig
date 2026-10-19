//! The VPI application host behind `--vpi` and `.options vpi=`: a user
//! application `.so` (LRM 12.33.2 `vlog_startup_routines`) in -> its §12.32
//! registrations, each `.hdl` module's `$systf` calls bound to their calltf
//! through VerA's `vpi` module (an `analog_run.Binding` over a calls-only
//! `Lib`), and the §12.31.3 analog callbacks driven by `.op` and `.tran`.
//! Lives in the executable, so the `vpi_*` symbols an application resolves
//! are exported from it alone (`rdynamic`), never from libespice.
//! The sequence is VerA's tests/vpi_host.zig `analogHost`; #197, #198.

const std = @import("std");
const contract = @import("contract");
const vera = @import("fastvaf");
const vpi = @import("vera_vpi");
const espice = @import("espice");

const VpiError = espice.VpiError;

/// VerA's VPI is process-global (one design, one call table, C callbacks
/// with no context; VerA#84), so this host is too: one per process, set up
/// by `init`, and every entry into VerA holds `mutex`. Device evaluations
/// reach `call` from several worker threads.
const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    /// Paths of the loaded applications. Each library stays open for the
    /// life of the process: its calltf pointers live in VerA's registry.
    apps: std.ArrayList([]const u8) = .empty,
    /// `vpi.systf.intAnalogNames` after the latest load.
    int_names: []const []const u8 = &.{},
    names_arena: std.heap.ArenaAllocator,
    /// The one module whose design is open, by source path.
    attached: ?[]const u8 = null,
    /// That module's `systf_calls`, in its device image (never unloaded).
    calls: []const contract.Systf = &.{},
    /// The attached module's calls, over VerA's installed design.
    binding: vpi.analog_run.Binding = .{},
};

var host: Host = undefined;

/// Sets up the process's VPI host and returns its interface for
/// `espice.Options.vpi`. Call once, before any Problem.
pub fn init(gpa: std.mem.Allocator, io: std.Io) *const espice.Vpi {
    host = .{ .gpa = gpa, .io = io, .names_arena = .init(gpa) };
    return &interface;
}

const interface: espice.Vpi = .{
    .ctx = undefined,
    .load_app = loadApp,
    .int_systfs = intSystfs,
    .registered = registered,
    .attach = attach,
    .point = point,
    .verdict = verdict,
    .accept = accept,
    .next_forced = nextForced,
};

fn loadApp(_: *anyopaque, path: []const u8) VpiError!void {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    for (host.apps.items) |a| if (std.mem.eql(u8, a, path)) return;
    var lib = std.DynLib.open(path) catch |err| {
        std.log.err("vpi: {s}: cannot open the application ({s})", .{ path, @errorName(err) });
        return error.VpiApplicationUnloadable;
    };
    // The symbol is the array itself, so its address is its first entry's.
    const table = lib.lookup([*]const ?vpi.StartupFn, "vlog_startup_routines") orelse {
        lib.close();
        std.log.err("vpi: {s} exports no vlog_startup_routines (LRM 12.33.2), so it registers nothing", .{path});
        return error.VpiNoStartupRoutines;
    };
    {
        errdefer lib.close();
        try host.apps.ensureUnusedCapacity(host.gpa, 1);
        host.apps.appendAssumeCapacity(try host.gpa.dupe(u8, path));
    }
    // From here the library stays open and listed: its calltfs enter
    // VerA's registry, even if the name list below fails.
    vpi.runStartupTable(table);
    host.int_names = try vpi.systf.intAnalogNames(host.names_arena.allocator());
}

fn intSystfs(_: *anyopaque) []const []const u8 {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return host.int_names;
}

fn registered(_: *anyopaque, name: []const u8) bool {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return vpi.systf.find(name, .analog) != null;
}

/// Opens VerA's design of the module at `source_path` (compiled again here:
/// a cached `.hdl` build carries no design), binds `calls` to it and runs
/// the build-time callbacks (compiletf, derivtf, cbEndOfCompile,
/// cbStartOfSimulation).
fn attach(_: *anyopaque, source_path: []const u8, calls: []const contract.Systf) VpiError!*const contract.SystfHost {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    if (host.attached) |p| {
        if (std.mem.eql(u8, p, source_path)) return &systf_host;
        std.log.err("vpi: {s} calls a $systf, and so does {s}: VerA's VPI holds one design (VerA#84), so one module per run may call one", .{ source_path, p });
        return error.VpiSecondSystfModule;
    }
    const source = std.Io.Dir.cwd().readFileAlloc(host.io, source_path, host.gpa, .limited(64 * 1024 * 1024)) catch |err| {
        std.log.err("vpi: {s}: cannot read the module for its design ({s})", .{ source_path, @errorName(err) });
        return error.VpiDesignFailed;
    };
    defer host.gpa.free(source);
    const dir = std.fs.path.dirname(source_path) orelse ".";
    var res = vera.compileSourceOpts(host.gpa, source, .lint, .{ .file_name = source_path, .include_dirs = &.{dir}, .int_systfs = host.int_names }) catch |err| {
        std.log.err("vpi: {s}: VerA cannot build the module's design ({s})", .{ source_path, @errorName(err) });
        return error.VpiDesignFailed;
    };
    defer res.deinit();
    vpi.open(host.gpa, &res) catch |err| {
        std.log.err("vpi: {s}: VerA cannot build the module's design ({s})", .{ source_path, @errorName(err) });
        return error.VpiDesignFailed;
    };
    host.calls = calls;
    try host.binding.attach(stub_lib, null);
    vpi.callback.endOfCompile();
    vpi.callback.startOfSimulation();
    host.attached = try host.gpa.dupe(u8, source_path);
    return &systf_host;
}

/// What every instance of the attached module calls through: VerA's
/// `Binding.call`/`output` under `mutex`. Every instance shares one call
/// object (VerA#84), so state an application keeps per call handle is
/// shared by every instance.
const systf_host: contract.SystfHost = .{ .ctx = undefined, .call = call, .out = out };

fn call(_: *anyopaque, k: usize, args: []const f64, partials: []f64) f64 {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return host.binding.call(0, k, args, partials);
}

fn out(_: *anyopaque, k: usize, j: usize, args: []const f64, partials: []f64) f64 {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return host.binding.output(0, k, j, args, partials);
}

/// §12.9/§12.18 answer for `p` from here on, calltf included, and the
/// solution is open to §12.36 vpiTransientFailConverge and, past the first,
/// vpiRejectTransientStep.
fn point(_: *anyopaque, p: espice.VpiAnalogPoint) void {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    const kind: vpi.analog_run.Kind = switch (p.kind) {
        .op => .op,
        .tran => .tran,
    };
    vpi.analog_run.setPoint(.{ .kind = kind, .start = p.start, .stop = p.stop, .max_step = p.max_step }, p.t, p.dt, 0);
    const b = &host.binding;
    b.have_solution = true;
    b.open_step = p.dt > 0;
    b.awaiting = true;
    b.reject_step = false;
    b.fail_converge = false;
}

/// acbConvergenceTest on the published solution: every callback runs, and
/// any non-zero return rejects it (VerA's reading).
fn verdict(_: *anyopaque) espice.VpiVerdict {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    const b = &host.binding;
    if (vpi.callback.convergenceRejected() or b.reject_step) return .reject;
    return if (b.fail_converge) .again else .accept;
}

/// VerA's `Binding.accept` order: acbInitialStep, the due timed callbacks,
/// acbAcceptedPoint (not on the first solution), acbFinalStep.
fn accept(_: *anyopaque, first: bool, last: bool) void {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    const b = &host.binding;
    const cb = vpi.callback;
    b.open_step = false;
    b.awaiting = false;
    b.t_accepted = vpi.analog_run.time();
    if (first) cb.fireAnalog(cb.acbInitialStep);
    cb.fireTimed(b.t_accepted);
    if (!first) cb.fireAnalog(cb.acbAcceptedPoint);
    if (last) {
        cb.fireAnalog(cb.acbFinalStep);
        vpi.analog_run.setPoint(null, b.t_accepted, 0, 0);
    }
}

fn nextForced(_: *anyopaque, after: f64) ?f64 {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return vpi.callback.nextForced(after, std.math.inf(f64));
}

/// The device side of VerA's analog walk, reduced to the call table: ESPice
/// solves and walks the circuit itself, so `analog_run` never solves through
/// it.
const stub_lib: vpi.analog_run.Lib = .{
    .open = stubOpen,
    .solve = stubSolve,
    .accept = stubAccept,
    .x = stubX,
    .n_u = zero,
    .n_rows = zero,
    .row = stubRow,
    .rows = stubValues,
    .n_shares = zero,
    .shares = stubValues,
    .systf = bindCalls,
    .n_systf = nSystf,
    .systf_name = systfName,
    .systf_tok = systfTok,
    .systf_outs = systfOuts,
    .ac = stubAc,
};

/// What VerA reads for an unknown outside a call's arguments. NaN, so a
/// calltf that reads one shows it rather than a plausible number.
// ponytail: NaN until VerA refuses that read by name without a solution
// (VerA#83, V5); bounded by the unknowns a module can have.
const no_solution: [4096]f64 = @splat(std.math.nan(f64));

fn stubOpen(_: u8) callconv(.c) void {}
fn stubSolve(_: f64, _: f64, _: bool, _: bool) callconv(.c) bool {
    return false;
}
fn stubAccept() callconv(.c) void {}
fn stubX() callconv(.c) [*]const f64 {
    return &no_solution;
}
fn zero() callconv(.c) usize {
    return 0;
}
fn stubRow(_: usize, _: *[4]i32) callconv(.c) void {}
fn stubValues(_: [*]f64) callconv(.c) void {}
fn stubAc(_: f64, _: [*]f64, _: [*]f64) callconv(.c) bool {
    return false;
}
fn bindCalls(_: ?*anyopaque, _: ?vpi.analog_run.HostCall, _: ?vpi.analog_run.HostOut) callconv(.c) void {}
fn nSystf() callconv(.c) usize {
    return host.calls.len;
}
fn systfName(k: usize, len: *usize) callconv(.c) [*]const u8 {
    len.* = host.calls[k].name.len;
    return host.calls[k].name.ptr;
}
fn systfTok(k: usize) callconv(.c) u32 {
    return host.calls[k].tok;
}
fn systfOuts(k: usize) callconv(.c) u64 {
    return host.calls[k].outs;
}
