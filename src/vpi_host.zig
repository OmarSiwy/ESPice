//! The VPI application host behind `--vpi` and `.options vpi=`: a user
//! application `.so` (LRM 12.33.2 `vlog_startup_routines`) in -> its §12.32
//! registrations, and each `.hdl` module's `$systf` calls bound to their
//! calltf through VerA's `vpi` module (`analog_run.attach` under a stub
//! `Lib`, which hands back VerA's deviceCall/deviceOut).
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
    /// Loaded applications, never closed: their calltf pointers live in
    /// VerA's registry for the life of the process.
    apps: std.ArrayList(App) = .empty,
    /// `vpi.systf.intAnalogNames` after the latest load.
    int_names: []const []const u8 = &.{},
    names_arena: std.heap.ArenaAllocator,
    /// The one module whose design is open, by source path.
    attached: ?[]const u8 = null,
    /// That module's `systf_calls`, in its device image (never unloaded).
    calls: []const contract.Systf = &.{},
    /// VerA's deviceCall/deviceOut, which `analog_run.attach` hands to
    /// `Lib.systf`.
    call: ?vpi.analog_run.HostCall = null,
    out: ?vpi.analog_run.HostOut = null,
};

const App = struct { path: []const u8, lib: std.DynLib };

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
};

fn loadApp(_: *anyopaque, path: []const u8) VpiError!void {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    for (host.apps.items) |a| if (std.mem.eql(u8, a.path, path)) return;
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
    const owned = try host.gpa.dupe(u8, path);
    errdefer host.gpa.free(owned);
    try host.apps.append(host.gpa, .{ .path = owned, .lib = lib });
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
/// a cached `.hdl` build carries no design) and binds `calls` to it, then
/// runs the build-time callbacks (compiletf, derivtf, cbEndOfCompile,
/// cbStartOfSimulation) and refuses any §12.31.3 analog callback by name.
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
    vpi.open(host.gpa, res.lowered) catch |err| {
        std.log.err("vpi: {s}: VerA cannot build the module's design ({s})", .{ source_path, @errorName(err) });
        return error.VpiDesignFailed;
    };
    host.calls = calls;
    try vpi.analog_run.attach(stub_lib);
    vpi.systf.buildCalls();
    vpi.callback.endOfCompile();
    try refuseAnalogCallbacks();
    vpi.callback.startOfSimulation();
    try refuseAnalogCallbacks();
    host.attached = try host.gpa.dupe(u8, source_path);
    return &systf_host;
}

/// §12.31.3's analog callbacks need ESPice to drive them per accepted point
/// and to let them force or reject times (#198); refused by name until then.
// ponytail: checked after cbEndOfCompile and cbStartOfSimulation only; one a
// calltf registers later is not seen. Check in `call` once #198 runs them.
fn refuseAnalogCallbacks() VpiError!void {
    const cbs = vpi.callback.all(host.gpa, null) catch return error.OutOfMemory;
    defer host.gpa.free(cbs);
    const cb = vpi.callback;
    for (cbs) |h| {
        var d: cb.CbData = undefined;
        cb.vpi_get_cb_info(h, &d);
        if (d.reason < cb.acbInitialStep or d.reason > cb.acbAcceptedPoint) continue;
        const names = [_][]const u8{ "acbInitialStep", "acbFinalStep", "acbAbsTime", "acbElapsedTime", "acbConvergenceTest", "acbAcceptedPoint" };
        std.log.err("vpi: the application registers {s} (LRM 12.31.3), an analog callback ESPice does not run yet; see #198", .{names[@intCast(d.reason - cb.acbInitialStep)]});
        return error.VpiAnalogCallbackUnsupported;
    }
}

/// What every instance of the attached module calls through: VerA's
/// deviceCall/deviceOut under `mutex`. Supported contract: a stateless
/// calltf. Every instance shares one call object (VerA#84), so state an
/// application keeps per call handle is shared by every instance.
// ponytail: a calltf reading vpiAnalogTime gets VerA's own walk's time (0),
// until VerA's `analog_run` point setter (VerA#83) lets `call` pass the
// SimState's.
const systf_host: contract.SystfHost = .{ .ctx = undefined, .call = call, .out = out };

fn call(_: *anyopaque, k: usize, args: []const f64, partials: []f64) f64 {
    std.debug.assert(partials.len == args.len);
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return host.call.?(k, args.ptr, args.len, partials.ptr);
}

fn out(_: *anyopaque, k: usize, j: usize, args: []const f64, partials: []f64) f64 {
    std.debug.assert(partials.len == args.len);
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    return host.out.?(k, j, args.ptr, args.len, partials.ptr);
}

/// The device side of VerA's analog walk, reduced to the call table: ESPice
/// solves the circuit itself, so `analog_run` never solves through it.
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
fn bindCalls(c: ?vpi.analog_run.HostCall, o: ?vpi.analog_run.HostOut) callconv(.c) void {
    host.call = c;
    host.out = o;
}
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
