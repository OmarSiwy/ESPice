//! Leak checks: every analysis run with std.testing.allocator as
//! ctx.allocator (no arena mask). Internal allocations that escape their
//! analysis show up as testing.allocator leak reports with stack traces.

const std = @import("std");
const testing = std.testing;
const analysis = @import("analysis");
const builder = @import("builder");

const Builder = builder.Builder;
const GROUND = analysis.GROUND;
const td = @import("testdev.zig");

// Varname entries that are string literals (not allocated) in analysis code.
const literal_names = [_][]const u8{
    "time",     "frequency",         "v-sweep",          "run",
    "temp",     "harmonic",          "magnitude",        "phase_deg",
    "hd2",      "v1_mag",            "v2_mag",           "index",
    "pole",     "transfer_function", "input_resistance", "output_resistance",
    "onoise_density", "loop_gain",   "pnoise_density",
};

fn isLiteral(n: []const u8) bool {
    for (literal_names) |l| if (std.mem.eql(u8, n, l)) return true;
    return false;
}

fn freeResult(a: std.mem.Allocator, res: analysis.Result) void {
    for (res.varnames) |n| if (!isLiteral(n)) a.free(n);
    a.free(res.varnames);
    a.free(res.data);
}

const Divider = struct { ckt: analysis.Circuit, n1: u32, n2: u32, vbranch: u32 };

fn buildDivider(gpa: std.mem.Allocator) !Divider {
    var b = Builder.init(gpa);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 5 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 2000 }, .{}, .{ n2, GROUND });
    const ckt = try b.compile();
    return .{ .ckt = ckt, .n1 = n1, .n2 = n2, .vbranch = vbranch };
}

fn solveOp(ckt: *analysis.Circuit, a: std.mem.Allocator) ![]f64 {
    const x = try a.alloc(f64, ckt.n);
    const r = try analysis.op.solve(ckt, x, .{});
    try testing.expect(r.converged);
    return x;
}

/// Run one job on the divider with testing.allocator, free the result.
fn checkDivider(job: analysis.Job, need_op: bool) !void {
    const a = testing.allocator;
    var d = try buildDivider(a);
    defer d.ckt.deinit();
    const x: ?[]f64 = if (need_op) try solveOp(&d.ckt, a) else null;
    defer if (x) |xs| a.free(xs);
    const probes = [_]u32{d.n2};
    const ctx: analysis.RunCtx = .{
        .circuit = &d.ckt,
        .x_op = x,
        .probes = &probes,
        .source_node = d.n1,
        .source_branch = d.vbranch,
        .allocator = a,
    };
    const res = try analysis.run(&ctx, job);
    freeResult(a, res);
}

test "leak: op" {
    try checkDivider(.{ .op = .{} }, false);
}
test "leak: dc" {
    try checkDivider(.{ .dc = .{ .start = 5, .stop = 5, .step = 1 } }, false);
}
test "leak: ac" {
    try checkDivider(.{ .ac = .{ .f_start = 1e3, .f_stop = 1e6, .points_per_decade = 5 } }, true);
}
test "leak: noise" {
    try checkDivider(.{ .noise = .{ .f_start = 1e3, .f_stop = 1e6, .points_per_decade = 5, .out_node = 2 } }, true);
}
test "leak: sens" {
    try checkDivider(.{ .sens = .{ .output_node = 2 } }, false);
}
test "leak: mc" {
    try checkDivider(.{ .mc = .{ .n_trials = 5, .seed = 42 } }, false);
}
test "leak: temp" {
    try checkDivider(.{ .temp = .{ .t_start = 0, .t_stop = 50, .t_step = 25 } }, false);
}
test "leak: tf" {
    var d = try buildDivider(testing.allocator);
    defer d.ckt.deinit();
    const a = testing.allocator;
    const x = try solveOp(&d.ckt, a);
    defer a.free(x);
    const probes = [_]u32{d.n2};
    const ctx: analysis.RunCtx = .{ .circuit = &d.ckt, .x_op = x, .probes = &probes, .source_node = d.n1, .source_branch = d.vbranch, .allocator = a };
    const res = try analysis.run(&ctx, .{ .tf = .{ .input_branch = d.vbranch, .output_node = d.n2 } });
    freeResult(a, res);
}
test "leak: stb" {
    try checkDivider(.{ .stb = .{ .f_start = 1e3, .f_stop = 1e6, .points_per_decade = 5, .probe_p = 1, .probe_n = 2 } }, false);
}
test "leak: disto" {
    try checkDivider(.{ .disto = .{ .f_start = 1e3, .f_stop = 1e6, .points_per_decade = 5, .ac_source_node = 2, .ac_magnitude = 1.0, .output_node = 2 } }, true);
}
test "leak: pac" {
    try checkDivider(.{ .pac = .{ .f_lo = 1e6, .n_harmonics = 1, .f_start = 1e5, .f_stop = 1e5, .points_per_decade = 1, .n_time_samples = 16, .pss_periods = 5 } }, true);
}
test "leak: pnoise" {
    try checkDivider(.{ .pnoise = .{ .out_node = 2, .f_start = 1e3, .f_stop = 1e5, .f_fundamental = 1e6, .points_per_decade = 5, .pss_n_samples = 16, .n_sidebands = 3 } }, true);
}

test "leak: tran" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.C, .{ .c = 1e-6 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try a.alloc(f64, ckt.n);
    defer a.free(x);
    @memset(x, 0);
    x[n1] = 1.0;
    const probes = [_]u32{n1};
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = GROUND, .source_branch = GROUND, .allocator = a };
    const res = try analysis.run(&ctx, .{ .tran = .{ .t_stop = 1e-3, .dt_init = 1e-7, .dt_max = 2e-5, .method = .trapezoidal } });
    freeResult(a, res);
}

test "leak: pz" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 5.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.C, .{ .c = 1e-6 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try solveOp(&ckt, a);
    defer a.free(x);
    const probes = [_]u32{n2};
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = n1, .source_branch = vbranch, .allocator = a };
    const res = try analysis.run(&ctx, .{ .pz = .{} });
    freeResult(a, res);
}

test "leak: sp" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const vbr = b.n;
    try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 150 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try solveOp(&ckt, a);
    defer a.free(x);
    const probes = [_]u32{n1};
    const ports = [_]analysis.sp.Port{.{ .node = n1, .branch = vbr, .z0 = 50.0 }};
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = n1, .source_branch = vbr, .allocator = a };
    const res = try analysis.run(&ctx, .{ .sp = .{ .f_start = 1e6, .f_stop = 1e9, .n_points = 5, .ports = &ports } });
    freeResult(a, res);
}

test "leak: four" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0, .amp = 1.0, .freq = 1e3 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 2000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try solveOp(&ckt, a);
    defer a.free(x);
    const probes = [_]u32{n2};
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = n1, .source_branch = vbranch, .allocator = a };
    const res = try analysis.run(&ctx, .{ .four = .{ .f_fundamental = 1e3, .output_node = n2, .tran_opts = .{ .t_stop = 3e-3, .dt_init = 1e-7, .dt_max = 1e-5 } } });
    a.free(res.plotname); // four's plotname is allocPrint'd (embeds THD)
    freeResult(a, res);
}

test "leak: hb" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const n2 = b.addNode();
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 2000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const probes = [_]u32{ n1, n2 };
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = null, .probes = &probes, .source_node = n1, .source_branch = GROUND, .allocator = a };
    const res = try analysis.run(&ctx, .{ .hb = .{ .f0 = 500.0, .n_harmonics = 4, .max_iter = 100, .hb_tol = 1e-12 } });
    freeResult(a, res);
}

test "leak: pss" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 5.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.C, .{ .c = 1e-7 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try solveOp(&ckt, a);
    defer a.free(x);
    const probes = [_]u32{ n1, n2 };
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = n1, .source_branch = vbranch, .allocator = a };
    const res = try analysis.run(&ctx, .{ .pss = .{ .period = 1e-3, .max_shooting_iter = 20, .shooting_tol = 1e-4, .fd_epsilon = 1e-6, .newton_tol = 1e-9, .max_newton_iter = 50, .n_samples = 200 } });
    freeResult(a, res);
}

test "leak: envelope" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0.0, .amp = 2.0, .freq = 1e6 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try solveOp(&ckt, a);
    defer a.free(x);
    const probes = [_]u32{n2};
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = n1, .source_branch = vbranch, .allocator = a };
    const res = try analysis.run(&ctx, .{ .envelope = .{ .t_carrier = 1e-6, .t_stop = 8e-6, .carrier_steps_per_period = 64, .periods_per_outer_step = 1, .max_periods_per_step = 4 } });
    freeResult(a, res);
}

test "leak: tran_noise" {
    const a = testing.allocator;
    var b = Builder.init(a);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    const x = try solveOp(&ckt, a);
    defer a.free(x);
    const dt: f64 = 0x1p-30;
    const probes = [_]u32{n2};
    const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &probes, .source_node = n1, .source_branch = vbranch, .allocator = a };
    const res = try analysis.run(&ctx, .{ .tran_noise = .{ .t_stop = dt * 100, .dt_init = dt, .dt_min = dt, .dt_max = dt, .max_steps = 110, .temp_k = 300.15, .seed = 12345 } });
    freeResult(a, res);
}
