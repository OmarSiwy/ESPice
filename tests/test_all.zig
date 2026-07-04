//! Top-level integration tests: every analysis exercised through the PUBLIC
//! contract surface — builder.Builder to construct, analysis.run(&ctx, job)
//! to dispatch, uniform Result rows to check. Known-answer tests wherever the
//! physics gives one; expected values and tolerances mirror the per-analysis
//! tests in analyses.zig (ported from the old ZpiceyRE top-level suite).

const std = @import("std");
const testing = std.testing;
const analysis = @import("analysis");
const builder = @import("builder");

const Builder = builder.Builder;
const GROUND = analysis.GROUND;
const td = analysis.testdev;

const k_boltzmann = 1.380649e-23;

test {
    _ = @import("builder.zig");
    _ = @import("analyses.zig");
    _ = @import("parallel.zig");
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const Divider = struct {
    ckt: analysis.Circuit,
    n1: u32,
    n2: u32,
    vbranch: u32,
};

/// V(dc)—R1—(n2)—R2—gnd. vbranch is the source's branch-current unknown.
fn buildDivider(gpa: std.mem.Allocator, vdc: f32, r1: f32, r2: f32) !Divider {
    var b = Builder.init(gpa);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n; // branch unknown assigned by the next addDevice
    try b.addDevice(td.V, .{ .dc = vdc }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = r1 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = r2 }, .{}, .{ n2, GROUND });
    const ckt = try b.compile();
    return .{ .ckt = ckt, .n1 = n1, .n2 = n2, .vbranch = vbranch };
}

/// Operating point into arena-owned x (the fine-grained primitive engine.zig
/// warm-starts every analysis through).
fn solveOp(ckt: *analysis.Circuit, arena: std.mem.Allocator) ![]f64 {
    const x = try arena.alloc(f64, ckt.n);
    const r = try analysis.op.solve(ckt, x, .{}, arena);
    try testing.expect(r.converged);
    return x;
}

fn runCtx(ckt: *analysis.Circuit, x_op: ?[]f64, probes: []const u32, src_node: u32, src_branch: u32, arena: std.mem.Allocator) analysis.RunCtx {
    return .{
        .circuit = ckt,
        .x_op = x_op,
        .probes = probes,
        .source_node = src_node,
        .source_branch = src_branch,
        .allocator = arena,
    };
}

/// Result varname lookup: column index or fail.
fn colOf(res: analysis.Result, name: []const u8) usize {
    for (res.varnames, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// dc
// ---------------------------------------------------------------------------

test "run dc: 10V / 1k / 3k divider -> 7.5V" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 10, 1000, 3000);
    defer d.ckt.deinit();

    const probes = [_]u32{ d.n1, d.n2 };
    const ctx = runCtx(&d.ckt, null, &probes, d.n1, d.vbranch, arena);
    // Single-point "sweep" of the source's dc param at its nominal 10V.
    const res = try analysis.run(&ctx, .{ .dc = .{ .start = 10, .stop = 10, .step = 1 } });

    try testing.expectEqual(@as(usize, 1), res.npoints);
    try testing.expectEqual(@as(usize, 3), res.varnames.len); // v-sweep + 2 probes
    try testing.expectApproxEqAbs(@as(f64, 10.0), res.data[0], 1e-12); // sweep value
    // gmin=1e-12 loads the divider by ~R*gmin relative — 1e-6 abs is the floor
    try testing.expectApproxEqAbs(@as(f64, 10.0), res.data[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 7.5), res.data[2], 1e-6);
}

// ---------------------------------------------------------------------------
// op
// ---------------------------------------------------------------------------

test "run op: divider operating point at every probe" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const probes = [_]u32{ d.n1, d.n2 };
    const ctx = runCtx(&d.ckt, null, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .op = .{} });

    try testing.expectEqual(@as(usize, 1), res.npoints);
    try testing.expect(!res.is_complex);
    try testing.expectApproxEqAbs(@as(f64, 5.0), res.data[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), res.data[1], 1e-6);
}

// ---------------------------------------------------------------------------
// tran
// ---------------------------------------------------------------------------

test "run tran: RC discharge matches exp(-t/RC), trapezoidal" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.C, .{ .c = 1e-6 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try arena.alloc(f64, ckt.n);
    @memset(x, 0);
    x[n1] = 1.0; // pre-charged capacitor

    const tau = 1e-3; // R*C
    const probes = [_]u32{n1};
    const ctx = runCtx(&ckt, x, &probes, GROUND, GROUND, arena);
    const res = try analysis.run(&ctx, .{ .tran = .{
        .t_stop = tau,
        .dt_init = 1e-7,
        .dt_max = 2e-5,
        .method = .trapezoidal,
    } });

    try testing.expect(res.npoints > 10);
    const ncols = res.varnames.len; // time + v(n1)
    const last = res.data[(res.npoints - 1) * ncols ..][0..ncols];
    try testing.expectApproxEqAbs(tau, last[0], 1e-12);
    try testing.expectApproxEqAbs(@exp(@as(f64, -1.0)), last[1], 2e-3);
}

// ---------------------------------------------------------------------------
// ac
// ---------------------------------------------------------------------------

test "run ac: RC lowpass |H| = 1/sqrt(1+(wRC)^2) across the sweep" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    // V—R(1k)—C(1µ): fc = 1/(2πRC) ≈ 159 Hz
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 1.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.C, .{ .c = 1e-6 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    const probes = [_]u32{n2};
    const ctx = runCtx(&ckt, x, &probes, n1, vbranch, arena);
    const res = try analysis.run(&ctx, .{ .ac = .{
        .f_start = 1e-1,
        .f_stop = 1e6,
        .points_per_decade = 5,
    } });

    try testing.expect(res.is_complex);
    try testing.expect(res.npoints > 0);
    const ncols = res.varnames.len; // frequency + v(n2); complex → 2 slots each
    for (0..res.npoints) |p| {
        const row = res.data[p * ncols * 2 ..][0 .. ncols * 2];
        const f = row[0];
        const wrc = 2.0 * std.math.pi * f * 1000.0 * 1e-6;
        const expected = 1.0 / @sqrt(1.0 + wrc * wrc);
        const mag = @sqrt(row[2] * row[2] + row[3] * row[3]);
        try testing.expectApproxEqRel(expected, mag, 1e-6);
    }
}

// ---------------------------------------------------------------------------
// noise
// ---------------------------------------------------------------------------

test "run noise: divider thermal density = 4kT*(R1||R2), flat" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const x = try solveOp(&d.ckt, arena);
    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, x, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .noise = .{
        .out_node = d.n2,
        .f_start = 1.0,
        .f_stop = 1e6,
        .points_per_decade = 10,
    } });

    try testing.expect(res.npoints > 0);
    // rows: (frequency, onoise_density)
    const first = res.data[1];
    const last = res.data[(res.npoints - 1) * 2 + 1];
    try testing.expectApproxEqRel(first, last, 1e-6); // flat (resistive)

    const temp_k = 27.0 + 273.15;
    const r_parallel = 1000.0 * 2000.0 / (1000.0 + 2000.0);
    const expected_density = 4.0 * k_boltzmann * temp_k * r_parallel;
    try testing.expectApproxEqRel(expected_density, first, 1e-3);
}

// ---------------------------------------------------------------------------
// sens
// ---------------------------------------------------------------------------

test "run sens: divider dVout/dR1, dVout/dR2, dVout/dV analytic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, null, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .sens = .{ .output_node = d.n2 } });

    try testing.expectEqual(@as(usize, 1), res.npoints);
    // dVout/dR2 = V*R1/(R1+R2)^2, dVout/dR1 = -V*R2/(R1+R2)^2, dVout/dV = R2/(R1+R2)
    try testing.expectApproxEqAbs(5.0 * 1000.0 / 9e6, res.data[colOf(res, "R#1.r")], 1e-6);
    try testing.expectApproxEqAbs(-5.0 * 2000.0 / 9e6, res.data[colOf(res, "R#0.r")], 1e-6);
    try testing.expectApproxEqAbs(2.0 / 3.0, res.data[colOf(res, "V#0.dc")], 1e-6);
}

// ---------------------------------------------------------------------------
// mc
// ---------------------------------------------------------------------------

test "run mc: divider — every trial converges to the divider point" {
    // td devices carry no primary instance params, so the contract-level mc
    // degenerates to n identical trials: exercised end-to-end, values exact.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, null, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .mc = .{ .n_trials = 25, .seed = 42 } });

    try testing.expectEqual(@as(usize, 25), res.npoints);
    const ncols = res.varnames.len; // run + v(n2)
    const nominal = 10.0 / 3.0;
    for (0..res.npoints) |k| {
        try testing.expectApproxEqAbs(nominal, res.data[k * ncols + 1], 1e-6);
    }
}

// ---------------------------------------------------------------------------
// temp_sweep
// ---------------------------------------------------------------------------

test "run temp: divider without tempcos is flat over the sweep" {
    // td.R has no temp field, so the contract-level sweep re-solves at each
    // temperature with unchanged params: full path, constant known answer.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, null, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .temp = .{
        .t_start = -40.0,
        .t_stop = 125.0,
        .t_step = 5.0,
    } });

    try testing.expectEqual(@as(usize, 34), res.npoints);
    const ncols = res.varnames.len; // temp + v(n2)
    for (0..res.npoints) |i| {
        const row = res.data[i * ncols ..][0..ncols];
        try testing.expectApproxEqAbs(-40.0 + 5.0 * @as(f64, @floatFromInt(i)), row[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), row[1], 1e-6);
    }
}

// ---------------------------------------------------------------------------
// tf
// ---------------------------------------------------------------------------

test "run tf: divider gain 2/3, Rin 3k, Rout R1||R2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const x = try solveOp(&d.ckt, arena);
    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, x, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .tf = .{
        .input_branch = d.vbranch,
        .output_node = d.n2,
    } });

    // data: (transfer_function, input_resistance, output_resistance)
    try testing.expectApproxEqAbs(2.0 / 3.0, res.data[0], 1e-9);
    try testing.expectApproxEqAbs(3000.0, res.data[1], 1e-6);
    try testing.expectApproxEqAbs(2000.0 / 3.0, res.data[2], 1e-6);
}

// ---------------------------------------------------------------------------
// pz
// ---------------------------------------------------------------------------

test "run pz: RC lowpass — single pole at -1/RC rad/s" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    // R=1k, C=1µ → pole at −1000 rad/s
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 5.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.C, .{ .c = 1e-6 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    const probes = [_]u32{n2};
    const ctx = runCtx(&ckt, x, &probes, n1, vbranch, arena);
    const res = try analysis.run(&ctx, .{ .pz = .{} });

    // rows: (index re, index im, pole re, pole im)
    try testing.expectEqual(@as(usize, 1), res.npoints);
    try testing.expect(res.is_complex);
    try testing.expectApproxEqRel(@as(f64, -1000.0), res.data[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), res.data[3], 1e-6);
}

// ---------------------------------------------------------------------------
// sp
// ---------------------------------------------------------------------------

test "run sp: 150R into 50R port — S11 = 0.5 at every frequency" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const vbr = b.n;
    try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 150 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    const probes = [_]u32{n1};
    const ctx = runCtx(&ckt, x, &probes, n1, vbr, arena);
    const ports = [_]analysis.sp.Port{.{ .node = n1, .branch = vbr, .z0 = 50.0 }};
    const res = try analysis.run(&ctx, .{ .sp = .{
        .f_start = 1e6,
        .f_stop = 1e9,
        .n_points = 5,
        .ports = &ports,
    } });

    // S11 = (150−50)/(150+50) = 0.5; rows: (freq, S11) complex
    try testing.expectEqual(@as(usize, 5), res.npoints);
    const ncols = res.varnames.len;
    for (0..res.npoints) |fi| {
        const row = res.data[fi * ncols * 2 ..][0 .. ncols * 2];
        try testing.expectApproxEqAbs(@as(f64, 0.5), row[2], 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0), row[3], 1e-6);
    }
}

// ---------------------------------------------------------------------------
// stb
// ---------------------------------------------------------------------------

test "run stb: resistive divider probe — loop gain stays below 10 dB" {
    // No feedback loop: loop gain never crosses 0 dB and the trace is small.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, null, &probes, d.n1, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .stb = .{
        .f_start = 1e3,
        .f_stop = 1e6,
        .points_per_decade = 5,
        .probe_p = d.n1,
        .probe_n = d.n2,
    } });

    try testing.expect(res.npoints > 0);
    // rows: (freq re, freq im, loop_gain re, loop_gain im)
    for (0..res.npoints) |i| {
        const row = res.data[i * 4 ..][0..4];
        const mag = @sqrt(row[2] * row[2] + row[3] * row[3]);
        try testing.expect(20.0 * @log10(@max(mag, 1e-30)) < 10.0);
    }
}

// ---------------------------------------------------------------------------
// disto
// ---------------------------------------------------------------------------

test "run disto: linear divider has zero HD2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const x = try solveOp(&d.ckt, arena);
    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, x, &probes, d.n2, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{ .disto = .{
        .f_start = 1e3,
        .f_stop = 1e6,
        .points_per_decade = 5,
        .ac_source_node = d.n2,
        .ac_magnitude = 1.0,
        .output_node = d.n2,
    } });

    try testing.expect(res.npoints > 0);
    // rows: (frequency, hd2, v1_mag, v2_mag)
    for (0..res.npoints) |i| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), res.data[i * 4 + 1], 1e-6);
    }
}

// ---------------------------------------------------------------------------
// four
// ---------------------------------------------------------------------------

test "run four: tran of sine through divider — fundamental 2/3, DC 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    // 1 kHz, 1V-amplitude sine into a 1k/2k divider: v(n2) = (2/3)sin(2*pi*f*t)
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0, .amp = 1.0, .freq = 1e3 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 2000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    const probes = [_]u32{n2};
    const ctx = runCtx(&ckt, x, &probes, n1, vbranch, arena);
    const res = try analysis.run(&ctx, .{
        .four = .{
            .f_fundamental = 1e3,
            .output_node = n2,
            .tran_opts = .{
                .t_stop = 3e-3, // 3 fundamental periods
                .dt_init = 1e-7,
                .dt_max = 1e-5, // 100 samples per period
            },
        },
    });

    // rows: (harmonic, frequency, magnitude, phase_deg); row 0 is DC.
    try testing.expect(res.npoints >= 2);
    try testing.expectApproxEqAbs(@as(f64, 0.0), res.data[2], 1e-2); // DC
    const h1 = res.data[4..8];
    try testing.expectApproxEqAbs(@as(f64, 1e3), h1[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), h1[2], 1e-2);
}

// ---------------------------------------------------------------------------
// hb
// ---------------------------------------------------------------------------

test "run hb: resistive divider driven at f0 — fundamental = I*R" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 2000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const probes = [_]u32{ n1, n2 };
    const ctx = runCtx(&ckt, null, &probes, n1, GROUND, arena);
    // Contract drive: 1A at ctx.source_node.
    const res = try analysis.run(&ctx, .{ .hb = .{
        .f0 = 500.0,
        .n_harmonics = 4,
        .max_iter = 100,
        .tol = 1e-12,
    } });

    // rows: (frequency, |v(n1)|, |v(n2)|), one row per harmonic incl. DC.
    try testing.expectEqual(@as(usize, 5), res.npoints);
    const ncols = res.varnames.len;
    const dc_row = res.data[0..ncols];
    const h1_row = res.data[ncols..][0..ncols];
    // V(n1) = I*(R1+R2) = 3000V, V(n2) = I*R2 = 2000V at the fundamental
    try testing.expectApproxEqAbs(@as(f64, 0.0), dc_row[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 500.0), h1_row[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3000.0), h1_row[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 2000.0), h1_row[2], 1e-6);
}

// ---------------------------------------------------------------------------
// pss
// ---------------------------------------------------------------------------

test "run pss: DC-driven RC converges — period solution matches settle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    // tau = RC = 0.1 ms, period T = 1 ms = 10*tau
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 5.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.C, .{ .c = 1e-7 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    const T: f64 = 1e-3;
    const probes = [_]u32{ n1, n2 };
    const ctx = runCtx(&ckt, x, &probes, n1, vbranch, arena);
    const res = try analysis.run(&ctx, .{ .pss = .{
        .period = T,
        .max_shooting_iter = 20,
        .shooting_tol = 1e-4,
        .fd_epsilon = 1e-6,
        .newton_tol = 1e-9,
        .max_newton_iter = 50,
        .n_samples = 200,
    } });

    // rows: (time, v(n1), v(n2)); n_samples+1 rows spanning [0, T].
    try testing.expectEqual(@as(usize, 201), res.npoints);
    const ncols = res.varnames.len;
    const last = res.data[(res.npoints - 1) * ncols ..][0..ncols];
    try testing.expectApproxEqAbs(T, last[0], 1e-12);
    // Periodic steady state of a DC-driven RC is the settled DC point: 5V.
    try testing.expectApproxEqAbs(@as(f64, 5.0), last[2], 1e-2);
}

// ---------------------------------------------------------------------------
// pac
// ---------------------------------------------------------------------------

test "run pac: LTI divider — direct sideband dominates, no conversion" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const x = try solveOp(&d.ckt, arena);
    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, x, &probes, d.n2, d.vbranch, arena);
    const res = try analysis.run(&ctx, .{
        .pac = .{
            .f_lo = 1e6,
            .n_harmonics = 1,
            .f_start = 1e5,
            .f_stop = 1e5, // single point
            .points_per_decade = 1,
            .n_time_samples = 16,
            .pss_periods = 5,
        },
    });

    try testing.expect(res.npoints > 0);
    try testing.expect(res.is_complex);
    // row: (freq, tf_h-1, tf_h0, tf_h+1), each complex (re, im)
    const row = res.data[0 .. res.varnames.len * 2];
    const down_mag = @sqrt(row[2] * row[2] + row[3] * row[3]);
    const direct_mag = @sqrt(row[4] * row[4] + row[5] * row[5]);
    const up_mag = @sqrt(row[6] * row[6] + row[7] * row[7]);

    try testing.expect(direct_mag > 0);
    // LTI: sideband conversion must be far below the direct path.
    try testing.expect(up_mag < direct_mag * 0.01);
    try testing.expect(down_mag < direct_mag * 0.01);
}

// ---------------------------------------------------------------------------
// pnoise
// ---------------------------------------------------------------------------

test "run pnoise: LTI divider — flat 4kT*(R1||R2) per sideband" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = try buildDivider(testing.allocator, 5, 1000, 2000);
    defer d.ckt.deinit();

    const x = try solveOp(&d.ckt, arena);
    const probes = [_]u32{d.n2};
    const ctx = runCtx(&d.ckt, x, &probes, d.n1, d.vbranch, arena);
    // f_stop < f_fundamental so no folded sideband lands exactly at DC.
    const res = try analysis.run(&ctx, .{ .pnoise = .{
        .out_node = d.n2,
        .f_start = 1e3,
        .f_stop = 1e5,
        .f_fundamental = 1e6,
        .points_per_decade = 5,
        .pss_n_samples = 16,
        .n_sidebands = 3,
    } });

    try testing.expect(res.npoints > 0);
    // rows: (frequency, pnoise_density). LTI: all 2*3+1 = 7 sidebands see the
    // identical transfer, so density is 7x the single-frequency 4kT*(R1||R2).
    const temp_k = 27.0 + 273.15;
    const r_parallel = 1000.0 * 2000.0 / (1000.0 + 2000.0);
    const expected = 4.0 * k_boltzmann * temp_k * r_parallel * 7.0;

    const first = res.data[1];
    const last = res.data[(res.npoints - 1) * 2 + 1];
    try testing.expectApproxEqRel(first, last, 1e-3); // flat
    try testing.expectApproxEqRel(expected, first, 1e-2);
}

// ---------------------------------------------------------------------------
// envelope
// ---------------------------------------------------------------------------

test "run envelope: sine carrier through equal divider — peak amp/2, rms peak/sqrt2" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0.0, .amp = 2.0, .freq = 1e6 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    const probes = [_]u32{n2};
    const ctx = runCtx(&ckt, x, &probes, n1, vbranch, arena);
    const res = try analysis.run(&ctx, .{ .envelope = .{
        .t_carrier = 1e-6,
        .t_stop = 8e-6,
        .carrier_steps_per_period = 64,
        .periods_per_outer_step = 1,
        .max_periods_per_step = 4,
    } });

    try testing.expect(res.npoints > 1);
    // rows: (time, peak(v(n2)), rms(v(n2))). Skip the initial DC point;
    // every sampled period sees the full swing.
    const ncols = res.varnames.len;
    for (1..res.npoints) |i| {
        const row = res.data[i * ncols ..][0..ncols];
        try testing.expectApproxEqAbs(@as(f64, 1.0), row[1], 2e-2);
        try testing.expectApproxEqAbs(@as(f64, 1.0 / @sqrt(2.0)), row[2], 5e-2);
    }
}

// ---------------------------------------------------------------------------
// tran_noise
// ---------------------------------------------------------------------------

test "run trannoise: divider thermal noise power matches 4kT*(R||R)*BW" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = Builder.init(testing.allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const r_val: f64 = 1000.0;
    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n2, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, arena);
    // Power-of-two dt: exact time accumulation, no shrunken final step.
    const temp_k: f64 = 27.0 + 273.15;
    const dt: f64 = 0x1p-30; // ~0.93 ns
    const n_steps: u32 = 20_000;
    const bandwidth = 1.0 / (2.0 * dt);

    const probes = [_]u32{n2};
    const ctx = runCtx(&ckt, x, &probes, n1, vbranch, arena);
    // The contract collects BOTH resistor generators off the Jacobian.
    const res = try analysis.run(&ctx, .{ .tran_noise = .{
        .t_stop = dt * @as(f64, @floatFromInt(n_steps)),
        .dt_init = dt,
        .dt_min = dt,
        .dt_max = dt,
        .max_steps = n_steps + 10,
        .temp_k = temp_k,
        .seed = 12345,
    } });

    try testing.expect(res.npoints > 1);
    // rows: (time, v(n2)); skip the DC initial condition.
    var sum_sq: f64 = 0;
    for (1..res.npoints) |i| sum_sq += res.data[i * 2 + 1] * res.data[i * 2 + 1];
    const measured_power = sum_sq / @as(f64, @floatFromInt(res.npoints - 1));

    // Both 1k resistors inject 4kT/R through Z = R||R = 500:
    // <v^2> = 2 * 4kT/R * (R||R)^2 * BW = 4kT * (R||R) * BW.
    const z_n2 = r_val * r_val / (r_val + r_val);
    const expected_power = 4.0 * k_boltzmann * temp_k * z_n2 * bandwidth;
    const ratio = measured_power / expected_power;
    try testing.expect(ratio > 0.85);
    try testing.expect(ratio < 1.15);
}
