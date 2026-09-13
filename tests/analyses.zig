//! Per-analysis circuit-construction tests, moved from the inline `test`
//! blocks in modules/analysis/src/*.zig. Pure-math tests stayed in-module;
//! everything here builds a circuit through builder.Builder and drives the
//! analysis primitives (solve/sweep/simulate) directly.

const std = @import("std");
const testing = std.testing;
const analysis = @import("analysis");
const builder = @import("builder");

const Builder = builder.Builder;
const GROUND = analysis.GROUND;
const td = @import("testdev.zig");
const freq = analysis.freq;
const dc = analysis.dc;

const k_boltzmann = 1.380649e-23;

pub const Series = struct {
    ckt: analysis.Circuit,
    n1: u32,
    n2: u32,
    vbranch: u32,
};

/// V(source)—R(r)—(n2)—Load—ground, preserving device and branch order.
pub inline fn buildSeries(gpa: std.mem.Allocator, comptime Load: type, source: td.V.Model, r: f32, load: Load.Model) !Series {
    var b = Builder.init(gpa);
    const n1 = b.addNode();
    const n2 = b.addNode();
    const vbranch = b.n;
    try b.addDevice(td.V, source, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = r }, .{}, .{ n1, n2 });
    try b.addDevice(Load, load, .{}, .{ n2, GROUND });
    const ckt = try b.compile();
    return .{ .ckt = ckt, .n1 = n1, .n2 = n2, .vbranch = vbranch };
}

fn findParam(refs: []const analysis.ParamRef, dtype: []const u8, pname: []const u8, index: u32) analysis.ParamRef {
    for (refs) |r| {
        if (std.mem.eql(u8, r.device_type, dtype) and
            std.mem.eql(u8, r.param_name, pname) and r.index == index)
            return r;
    }
    unreachable;
}

// ============================================================================
// dc
// ============================================================================

test "dc: resistor divider" {
    var setup = try buildSeries(testing.allocator, td.R, .{ .dc = 10 }, 1000, .{ .r = 3000 });
    defer setup.ckt.deinit();

    const x = try testing.allocator.alloc(f64, setup.ckt.n);
    defer testing.allocator.free(x);
    const r = try dc.solve(&setup.ckt, x, .{});
    try testing.expect(r.converged);
    // gmin=1e-12 loads the divider by ~R*gmin relative — 1e-6 abs is the floor
    try testing.expectApproxEqAbs(@as(f64, 10.0), x[setup.n1], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 7.5), x[setup.n2], 1e-6);
}

test "dc: diode + resistor (nonlinear, analytic Jacobian)" {
    var setup = try buildSeries(testing.allocator, td.D, .{ .dc = 5 }, 1000, .{ .is = 1e-14 });
    defer setup.ckt.deinit();

    const x = try testing.allocator.alloc(f64, setup.ckt.n);
    defer testing.allocator.free(x);
    const r = try dc.solve(&setup.ckt, x, .{ .tol = .{ .abstol = 1e-9 } });
    try testing.expect(r.converged);
    // KCL at vd: (5 - vd)/1k = is*(exp(vd/vt)-1)
    const i_r = (5.0 - x[setup.n2]) / 1000.0;
    const i_d = 1e-14 * (@exp(x[setup.n2] / 0.02585) - 1.0);
    try testing.expectApproxEqRel(i_r, i_d, 1e-3);
    try testing.expect(x[setup.n2] > 0.5 and x[setup.n2] < 0.8);
}

// ============================================================================
// op
// ============================================================================

test "op: diode bridge-ish network converges via gmin path or plain" {
    var setup = try buildSeries(testing.allocator, td.D, .{ .dc = 0.7 }, 10, .{});
    defer setup.ckt.deinit();

    const x = try testing.allocator.alloc(f64, setup.ckt.n);
    defer testing.allocator.free(x);
    const r = try analysis.op.solve(&setup.ckt, x, .{ .tol = .{ .abstol = 1e-9 } });
    try testing.expect(r.converged);
    try testing.expect(x[setup.n2] > 0.4 and x[setup.n2] < 0.7);
}

// ============================================================================
// ac
// ============================================================================

/// One V card's slice of the excitation vector src/builder.zig `acExcitation`
/// builds for a whole deck: `mag·e^{jφ}` on that source's branch row.
fn vExc(a: std.mem.Allocator, n: usize, branch: u32, mag: f64, phase_deg: f64) ![]f64 {
    const exc = try a.alloc(f64, 2 * n);
    @memset(exc, 0);
    const rad = phase_deg * (std.math.pi / 180.0);
    exc[branch] = mag * @cos(rad);
    exc[n + branch] = mag * @sin(rad);
    return exc;
}

test "AC: resistive divider has flat response of 2/3" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const n_points = freq.logSweepCount(1e3, 1e6, 5);
    const probe_list = [_]u32{setup.n2};
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const resp = try allocator.alloc(analysis.ac.Complex, n_points);
    defer allocator.free(resp);

    const exc = try vExc(allocator, setup.ckt.n, setup.vbranch, 1.0, 0.0);
    defer allocator.free(exc);
    try analysis.ac.sweep(&setup.ckt, x, exc, &probe_list, freqs, resp, .{
        .f_start = 1e3,
        .f_stop = 1e6,
        .points_per_decade = 5,
    }, allocator);

    for (0..n_points) |k| {
        try testing.expectApproxEqAbs(2.0 / 3.0, resp[k].mag(), 1e-9);
    }
}

test "AC: RC lowpass — passband gain 1, -20 dB/dec rolloff" {
    const allocator = testing.allocator;

    // V—R(1k)—C(1µ): fc = 1/(2πRC) ≈ 159 Hz
    var setup = try buildSeries(allocator, td.C, .{ .dc = 1.0 }, 1000, .{ .c = 1e-6 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const n_points = freq.logSweepCount(1e-1, 1e6, 5);
    const probe_list = [_]u32{setup.n2};
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const resp = try allocator.alloc(analysis.ac.Complex, n_points);
    defer allocator.free(resp);

    const exc = try vExc(allocator, setup.ckt.n, setup.vbranch, 1.0, 0.0);
    defer allocator.free(exc);
    try analysis.ac.sweep(&setup.ckt, x, exc, &probe_list, freqs, resp, .{
        .f_start = 1e-1,
        .f_stop = 1e6,
        .points_per_decade = 5,
    }, allocator);

    // f << fc: |H| ≈ 1
    try testing.expectApproxEqAbs(1.0, resp[0].mag(), 1e-4);

    // exact |H| everywhere + -20 dB/decade in the tail
    var db_1e4: f64 = 0;
    var db_1e5: f64 = 0;
    for (0..n_points) |k| {
        const f = freqs[k];
        const wrc = 2.0 * std.math.pi * f * 1000.0 * 1e-6;
        const expected = 1.0 / @sqrt(1.0 + wrc * wrc);
        try testing.expectApproxEqRel(expected, resp[k].mag(), 1e-6);
        if (@abs(f - 1e4) / 1e4 < 0.01) db_1e4 = resp[k].magDb();
        if (@abs(f - 1e5) / 1e5 < 0.01) db_1e5 = resp[k].magDb();
    }
    try testing.expectApproxEqAbs(-20.0, db_1e5 - db_1e4, 0.1);
}

test "AC: excitation phase rotates the response" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();

    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 0.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try allocator.alloc(f64, ckt.n);
    defer allocator.free(x);
    _ = try dc.solve(&ckt, x, .{});

    const probe_list = [_]u32{n1};
    var freqs = [_]f64{0};
    var resp = [_]analysis.ac.Complex{analysis.ac.Complex.zero};

    const exc = try vExc(allocator, ckt.n, vbranch, 2.0, 90.0);
    defer allocator.free(exc);
    try analysis.ac.sweep(&ckt, x, exc, &probe_list, &freqs, &resp, .{
        .f_start = 1e3,
        .f_stop = 1e3,
        .points_per_decade = 1,
    }, allocator);

    try testing.expectApproxEqAbs(0.0, resp[0].re, 1e-9);
    try testing.expectApproxEqAbs(2.0, resp[0].im, 1e-9);
}

// ============================================================================
// tran
// ============================================================================

test "transient: resistor divider stays at DC" {
    const allocator = testing.allocator;
    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const probes = [_]u32{ setup.n1, setup.n2 };
    var waveform = try analysis.tran.Waveform.init(allocator, 2, 1024);
    defer waveform.deinit();
    const result = try analysis.tran.simulate(&setup.ckt, x, &probes, &waveform, .{
        .t_stop = 1e-6,
        .dt_init = 1e-9,
        .dt_max = 1e-7,
    }, allocator);

    try testing.expect(result.completed);
    const v2 = waveform.probeValues(1);
    const last = v2[v2.len - 1];
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), last, 1e-6);
}

test "transient: RC discharge matches exp(-t/RC) with trapezoidal" {
    // Catches the wrong trap companion (missing -i_prev term), which decays
    // with twice the time constant: v(tau) = e^-0.5 instead of e^-1.
    const allocator = testing.allocator;
    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.C, .{ .c = 1e-6 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try allocator.alloc(f64, ckt.n);
    defer allocator.free(x);
    @memset(x, 0);
    x[n1] = 1.0; // pre-charged capacitor

    const tau = 1e-3; // R*C
    const probes = [_]u32{n1};
    var waveform = try analysis.tran.Waveform.init(allocator, 1, 1024);
    defer waveform.deinit();
    const result = try analysis.tran.simulate(&ckt, x, &probes, &waveform, .{
        .t_stop = tau,
        .dt_init = 1e-7,
        .dt_max = 2e-5,
        .method = .trapezoidal,
    }, allocator);

    try testing.expect(result.completed);
    try testing.expectApproxEqAbs(@exp(@as(f64, -1.0)), x[n1], 2e-3);
}

test "transient: step_fn hook fires per accepted step" {
    const allocator = testing.allocator;
    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.V, .{ .dc = 1.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try allocator.alloc(f64, ckt.n);
    defer allocator.free(x);
    _ = try dc.solve(&ckt, x, .{});

    const Counter = struct {
        fn hook(ctx: ?*anyopaque, _: f64, _: []const f64) void {
            const count: *u32 = @ptrCast(@alignCast(ctx.?));
            count.* += 1;
        }
    };
    var count: u32 = 0;

    const probes = [_]u32{n1};
    var waveform = try analysis.tran.Waveform.init(allocator, 1, 1024);
    defer waveform.deinit();
    const result = try analysis.tran.simulate(&ckt, x, &probes, &waveform, .{
        .t_stop = 1e-7,
        .dt_init = 1e-9,
        .dt_max = 1e-8,
        .step_fn = Counter.hook,
        .step_ctx = &count,
    }, allocator);

    try testing.expect(result.completed);
    try testing.expectEqual(result.steps, count);
}

// ============================================================================
// written-row predicate — engine.zig `writtenRows` / VerA `jac_rows`/`q_rows`
//
// The engine deletes a residual row the device never writes. The ONE way that
// can be wrong is inferring "never written" from `jac_pattern`/`q_pattern`,
// which answer for the DERIVATIVE: a term depending on no unknown writes its
// row with an empty column mask. Both devices below are exactly that shape and
// both failures are silent — no error, no NaN, just a missing term.
// ============================================================================

test "written rows: an empty jac_pattern does not delete the current source" {
    // td.I is `isource.va` in miniature: jac_pattern = {0,0}, both rows written.
    const allocator = testing.allocator;
    const i_dc: f32 = 1e-3;
    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.I, .{ .dc = i_dc }, .{}, .{ GROUND, n1 });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try allocator.alloc(f64, ckt.n);
    defer allocator.free(x);
    @memset(x, 0);

    // The stamp itself. At x = 0 the resistor contributes nothing, so row n1 is
    // the source's alone — and a dropped row would still "converge" here, at 0 V.
    ckt.eval(x, 0);
    try testing.expectEqual(-@as(f64, i_dc), ckt.rhs[n1]);

    const r = try dc.solve(&ckt, x, .{});
    try testing.expect(r.converged);
    try testing.expectApproxEqAbs(@as(f64, 1.0), x[n1], 1e-5);
}

test "written rows: a ddt of time alone keeps its charge row and its q_tape" {
    // td.Qt is q(x, t) = k*t^2 with dq/dx == 0: q_pattern empty, both rows live.
    const allocator = testing.allocator;
    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.Qt, .{ .k = 1.0 }, .{}, .{ GROUND, n1 });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try allocator.alloc(f64, ckt.n);
    defer allocator.free(x);
    @memset(x, 0);

    // Two consumers, both of which a dropped row silently starves: the summed q
    // plane (the companion current) and the per-state tape stepBound reduces
    // over. The tape is the quiet one — a frozen 0 there costs an LTE bound
    // with no diagnostic at all.
    ckt.eval(x, 2.0);
    try testing.expectEqual(@as(f64, -4.0), ckt.q_vec[n1]);
    const tape = try allocator.alloc(f64, ckt.qTapeLen());
    defer allocator.free(tape);
    ckt.snapshotQTape(tape);
    try testing.expectEqualSlices(f64, &.{ 4.0, -4.0 }, tape);

    // End to end: i = d/dt(k*t^2) = 2*k*t into n1, so v = 2*k*t*R — 2 V at
    // t = 1 ms. Skip the row and it is 0 V for the whole run.
    const probes = [_]u32{n1};
    var waveform = try analysis.tran.Waveform.init(allocator, 1, 1024);
    defer waveform.deinit();
    const result = try analysis.tran.simulate(&ckt, x, &probes, &waveform, .{
        .t_stop = 1e-3,
        .dt_init = 1e-6,
        .dt_max = 1e-5,
    }, allocator);
    try testing.expect(result.completed);
    try testing.expectApproxEqRel(@as(f64, 2.0), x[n1], 1e-4);
}

// ============================================================================
// four
// ============================================================================

test "four: voltage divider DC produces zero THD" {
    // A DC circuit has zero fundamental and zero THD
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);

    // DC operating point: V(n2) = 5 * 2000/3000 = 10/3
    const dc_result = try dc.solve(&setup.ckt, x, .{});
    try testing.expect(dc_result.converged);
    // gmin=1e-12 loads the divider by ~R*gmin relative — 1e-6 abs is the floor
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), x[setup.n2], 1e-6);

    // Build a synthetic constant waveform from the DC solution
    const n_samples: usize = 256;
    var waveform = try analysis.tran.Waveform.init(allocator, 1, n_samples);
    defer waveform.deinit();

    const f_fund = 1000.0;
    const probes = [_]u32{setup.n2};
    for (0..n_samples) |k| {
        const t = 2.0 / f_fund * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n_samples));
        try waveform.record(t, x, &probes);
    }

    const result = try analysis.four.analyze(&waveform, 0, f_fund, allocator);

    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), result.dc, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.fundamental, 1e-10);
}

// ============================================================================
// noise
// ============================================================================

test "noise: thermal noise of resistor divider = 4kT*(R1||R2)" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), x[setup.n2], 1e-6);

    // sources off the analytic Jacobian — both resistors declare gens
    const sources = try setup.ckt.collectNoiseSources(x, allocator);
    defer allocator.free(sources);
    try testing.expectEqual(@as(usize, 2), sources.len);

    const n_points = freq.logSweepCount(1.0, 1e6, 10);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);
    const inoise = try allocator.alloc(f64, n_points);
    defer allocator.free(inoise);

    const totals = try analysis.noise.sweep(&setup.ckt, x, sources, freqs, density, inoise, .{
        .out_node = setup.n2,
        .f_start = 1.0,
        .f_stop = 1e6,
        .points_per_decade = 10,
    }, allocator);

    // flat (resistive) spectrum
    const first = density[0];
    const last = density[n_points - 1];
    try testing.expectApproxEqRel(first, last, 1e-6);

    const temp_k = 27.0 + 273.15;
    const r_parallel = 1000.0 * 2000.0 / (1000.0 + 2000.0);
    const expected_density = 4.0 * k_boltzmann * temp_k * r_parallel;
    try testing.expectApproxEqRel(expected_density, first, 1e-3);
    // `sweep` is squared throughout, like ngspice's Ndata; `run` takes the
    // sqrt (cktnoise.c:110-113). No .noise input branch here, so inoise is
    // onoise at unit gain.
    try testing.expect(totals.onoise > 0);
    try testing.expectApproxEqRel(totals.onoise, totals.inoise, 1e-12);
    try testing.expectApproxEqRel(density[0], inoise[0], 1e-12);
    // Flat band: the integral is exactly S * (f_stop - f_start) --
    // Nintegrate's |slope| < N_INTFTHRESH branch (ninteg.c:33-34).
    try testing.expectApproxEqRel(expected_density * (freqs[n_points - 1] - freqs[0]), totals.onoise, 1e-3);
}

test "noise: zero sources produce zero noise" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.V, .{ .dc = 1.0 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const sources = [_]analysis.NoiseSource{};
    const n_points = freq.logSweepCount(100.0, 1e6, 5);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);
    const inoise = try allocator.alloc(f64, n_points);
    defer allocator.free(inoise);

    const totals = try analysis.noise.sweep(&ckt, x, &sources, freqs, density, inoise, .{
        .out_node = n1,
        .f_start = 100.0,
        .f_stop = 1e6,
        .points_per_decade = 5,
    }, allocator);

    try testing.expectApproxEqAbs(@as(f64, 0), totals.onoise, 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 0), totals.inoise, 1e-30);
    for (density[0..n_points]) |d| {
        try testing.expectApproxEqAbs(@as(f64, 0), d, 1e-30);
    }
}

// ============================================================================
// tf
// ============================================================================

test "TF: voltage divider gain, Rin, Rout" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);
    // gmin=1e-12 loads the divider by ~R*gmin relative — 1e-6 abs is the floor
    try testing.expectApproxEqAbs(10.0 / 3.0, x[setup.n2], 1e-6);

    const result = try analysis.tf.solve(&setup.ckt, x, setup.vbranch, setup.n2, allocator);

    try testing.expectApproxEqAbs(2.0 / 3.0, result.gain, 1e-9);
    try testing.expectApproxEqAbs(3000.0, result.input_resistance, 1e-6);
    try testing.expectApproxEqAbs(2000.0 / 3.0, result.output_resistance, 1e-6);
}

test "TF: source directly across output — gain 1, Rout 0" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();

    const vbranch = b.n;
    try b.addDevice(td.V, .{ .dc = 3.3 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const result = try analysis.tf.solve(&ckt, x, vbranch, n1, allocator);
    try testing.expectApproxEqAbs(1.0, result.gain, 1e-12);
    try testing.expectApproxEqAbs(1000.0, result.input_resistance, 1e-6);
    // Output node is clamped by the source: Rout = 0
    try testing.expectApproxEqAbs(0.0, result.output_resistance, 1e-9);
}

// ============================================================================
// sens
// ============================================================================

test "sens: voltage divider dVout/dR2 analytical check" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const params = [_]analysis.sens.SensParam{
        .{ .ptr = findParam(refs, "R", "r", 1), .device_name = "R2", .param_name = "r" },
        .{ .ptr = findParam(refs, "R", "r", 0), .device_name = "R1", .param_name = "r" },
        .{ .ptr = findParam(refs, "V", "dc", 0), .device_name = "V1", .param_name = "dc" },
    };

    var result = try analysis.sens.solve(&setup.ckt, &params, setup.n2, .{}, allocator);
    defer result.deinit(allocator);

    // Vout = V * R2 / (R1 + R2)
    // V=5, R1=1000, R2=2000 => Vout = 10/3
    // gmin loads the divider by ~R*gmin relative — 1e-6 abs is the floor
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), result.op_value, 1e-6);

    // dVout/dR2 = V * R1 / (R1 + R2)^2 = 5 * 1000 / 9e6 = 5/9000
    const expected_dR2 = 5.0 * 1000.0 / (3000.0 * 3000.0);
    try testing.expectApproxEqAbs(expected_dR2, result.entries[0].sensitivity, 1e-6);

    // dVout/dR1 = -V * R2 / (R1 + R2)^2 = -10/9000
    const expected_dR1 = -5.0 * 2000.0 / (3000.0 * 3000.0);
    try testing.expectApproxEqAbs(expected_dR1, result.entries[1].sensitivity, 1e-6);

    // dVout/dV = R2 / (R1 + R2) = 2/3
    const expected_dV = 2000.0 / 3000.0;
    try testing.expectApproxEqAbs(expected_dV, result.entries[2].sensitivity, 1e-6);

    try testing.expectEqual(@as(usize, 3), result.entries.len);
    try testing.expectEqualStrings("R2", result.entries[0].device_name);
    try testing.expectEqualStrings("r", result.entries[0].param_name);
}

test "sens: single resistor sensitivity is zero" {
    // Vout = Vdc regardless of R when there is only a vsource and one resistor
    // dVout/dR should be zero (or near-zero)
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.V, .{ .dc = 3.3 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 4700 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const refs = try ckt.collectParams();

    const params = [_]analysis.sens.SensParam{
        .{ .ptr = findParam(refs, "R", "r", 0), .device_name = "R1", .param_name = "r" },
    };

    var result = try analysis.sens.solve(&ckt, &params, n1, .{}, allocator);
    defer result.deinit(allocator);

    try testing.expectApproxEqAbs(@as(f64, 3.3), result.op_value, 1e-6);
    // Source fixes voltage at n1 regardless of R1, so sensitivity ~ 0
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.entries[0].sensitivity, 1e-6);
}

test "sens: result metadata" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 10 }, 1000, .{ .r = 1000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const params = [_]analysis.sens.SensParam{
        .{ .ptr = findParam(refs, "R", "r", 0), .device_name = "R1", .param_name = "r" },
        .{ .ptr = findParam(refs, "R", "r", 1), .device_name = "R2", .param_name = "r" },
    };

    var result = try analysis.sens.solve(&setup.ckt, &params, setup.n2, .{}, allocator);
    defer result.deinit(allocator);

    // Equal resistors: Vout = V/2 = 5.0
    try testing.expectApproxEqAbs(@as(f64, 5.0), result.op_value, 1e-6);

    // dVout/dR1 = -V*R2/(R1+R2)^2 = -10*1000/4e6 = -2.5e-3
    // dVout/dR2 =  V*R1/(R1+R2)^2 =  10*1000/4e6 =  2.5e-3
    // Symmetry: magnitudes equal, signs opposite
    try testing.expectApproxEqAbs(
        @abs(result.entries[0].sensitivity),
        @abs(result.entries[1].sensitivity),
        1e-6,
    );
    try testing.expect(result.entries[0].sensitivity < 0);
    try testing.expect(result.entries[1].sensitivity > 0);
}

// ============================================================================
// pz
// ============================================================================

test "pz: RC lowpass pole at -1/(RC) rad/s" {
    const allocator = testing.allocator;

    // R=1k, C=1µ → pole at −1000 rad/s
    var setup = try buildSeries(allocator, td.C, .{ .dc = 5.0 }, 1000, .{ .c = 1e-6 });
    defer setup.ckt.deinit();

    const x_op = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x_op);

    var result = try analysis.pz.solve(&setup.ckt, x_op, .{}, allocator);
    defer result.deinit();

    try testing.expect(result.qr_converged);
    try testing.expectEqual(@as(usize, 1), result.poles.len);
    try testing.expectApproxEqRel(@as(f64, -1000.0), result.poles[0].re, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.poles[0].im, 1e-6);
    try testing.expectEqual(@as(u32, 1), result.n_stable);
}

test "pz: voltage divider (no capacitors) has no poles" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x_op = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x_op);
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), x_op[setup.n2], 1e-6);

    var result = try analysis.pz.solve(&setup.ckt, x_op, .{}, allocator);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.poles.len);
}

// ============================================================================
// tf/stb
// ============================================================================

test "STB: resistive voltage divider has flat loop gain of zero" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    var stb_result = try analysis.stb.solve(&setup.ckt, setup.n1, setup.n2, .{ .f_start = 1e3, .f_stop = 1e6, .points_per_decade = 5 }, null, allocator);
    defer stb_result.deinit(allocator);

    try testing.expect(stb_result.n_points > 0);
    for (stb_result.loop_gain[0..stb_result.n_points]) |t| {
        try testing.expect(20.0 * @log10(@max(t.mag(), 1e-30)) < 10.0);
    }
}

// ============================================================================
// sp
// ============================================================================

// ponytail: share default DC setup; custom-tolerance cases keep their direct solves.
fn solveOp(ckt: *analysis.Circuit, allocator: std.mem.Allocator) ![]f64 {
    const x = try allocator.alloc(f64, ckt.n);
    errdefer allocator.free(x);
    const r = try dc.solve(ckt, x, .{});
    try testing.expect(r.converged);
    return x;
}

fn sGet(s: []const analysis.sp.Complex, n_ports: usize, fi: usize, row: usize, col: usize) analysis.sp.Complex {
    return s[fi * n_ports * n_ports + row * n_ports + col];
}

test "SP: 1-port resistor reflection" {
    const allocator = testing.allocator;

    // Matched 50Ω: S11 = 0
    {
        var b = Builder.init(allocator);
        const n1 = b.addNode();
        const vbr = b.n; // branch unknown assigned by the next addDevice
        try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
        try b.addDevice(td.R, .{ .r = 50 }, .{}, .{ n1, GROUND });
        var ckt = try b.compile();
        defer ckt.deinit();

        const x = try solveOp(&ckt, allocator);
        defer allocator.free(x);

        const port_list = [_]analysis.sp.Port{.{ .node = n1, .branch = vbr, .z0 = 50.0 }};
        const freqs = try allocator.alloc(f64, 5);
        defer allocator.free(freqs);
        const s = try allocator.alloc(analysis.sp.Complex, 5);
        defer allocator.free(s);
        try analysis.sp.sweep(&ckt, x, &port_list, freqs, s, .{ .f_start = 1e6, .f_stop = 1e9, .n_points = 5 }, allocator);

        for (0..5) |fi| {
            try testing.expectApproxEqAbs(@as(f64, 0), sGet(s, 1, fi, 0, 0).mag(), 1e-6);
        }
    }

    // 150Ω into 50Ω: S11 = (150−50)/(150+50) = 0.5
    {
        var b = Builder.init(allocator);
        const n1 = b.addNode();
        const vbr = b.n;
        try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
        try b.addDevice(td.R, .{ .r = 150 }, .{}, .{ n1, GROUND });
        var ckt = try b.compile();
        defer ckt.deinit();

        const x = try solveOp(&ckt, allocator);
        defer allocator.free(x);

        const port_list = [_]analysis.sp.Port{.{ .node = n1, .branch = vbr, .z0 = 50.0 }};
        const freqs = try allocator.alloc(f64, 3);
        defer allocator.free(freqs);
        const s = try allocator.alloc(analysis.sp.Complex, 3);
        defer allocator.free(s);
        try analysis.sp.sweep(&ckt, x, &port_list, freqs, s, .{ .f_start = 1e6, .f_stop = 1e9, .n_points = 3 }, allocator);

        for (0..3) |fi| {
            try testing.expectApproxEqAbs(@as(f64, 0.5), sGet(s, 1, fi, 0, 0).re, 1e-6);
            try testing.expectApproxEqAbs(@as(f64, 0), sGet(s, 1, fi, 0, 0).im, 1e-6);
        }
    }
}

test "SP: 100Ω series two-port between 50Ω ports — S11=S21=0.5" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();

    const vbr1 = b.n;
    try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
    const vbr2 = b.n;
    try b.addDevice(td.V, .{}, .{}, .{ n2, GROUND });
    try b.addDevice(td.R, .{ .r = 100 }, .{}, .{ n1, n2 });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const port_list = [_]analysis.sp.Port{
        .{ .node = n1, .branch = vbr1, .z0 = 50.0 },
        .{ .node = n2, .branch = vbr2, .z0 = 50.0 },
    };
    const freqs = try allocator.alloc(f64, 5);
    defer allocator.free(freqs);
    const s = try allocator.alloc(analysis.sp.Complex, 5 * 4);
    defer allocator.free(s);
    try analysis.sp.sweep(&ckt, x, &port_list, freqs, s, .{ .f_start = 1e6, .f_stop = 1e9, .n_points = 5 }, allocator);

    // Z=100 series: S11 = Z/(Z+2Z0) = 0.5, S21 = 2Z0/(Z+2Z0) = 0.5
    for (0..5) |fi| {
        try testing.expectApproxEqAbs(@as(f64, 0.5), sGet(s, 2, fi, 0, 0).re, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0.5), sGet(s, 2, fi, 1, 1).re, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0.5), sGet(s, 2, fi, 1, 0).re, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0.5), sGet(s, 2, fi, 0, 1).re, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0), sGet(s, 2, fi, 0, 0).im, 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0), sGet(s, 2, fi, 1, 0).im, 1e-6);
    }
}

test "SP: 1-port RC — frequency-dependent reflection" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();

    const r_val = 50.0;
    const c_val = 1e-9;
    const vbr = b.n;
    try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = r_val }, .{}, .{ n1, GROUND });
    try b.addDevice(td.C, .{ .c = c_val }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const z0 = 50.0;
    const port_list = [_]analysis.sp.Port{.{ .node = n1, .branch = vbr, .z0 = z0 }};
    const freqs = try allocator.alloc(f64, 20);
    defer allocator.free(freqs);
    const s = try allocator.alloc(analysis.sp.Complex, 20);
    defer allocator.free(s);
    try analysis.sp.sweep(&ckt, x, &port_list, freqs, s, .{ .f_start = 1e3, .f_stop = 1e10, .n_points = 20 }, allocator);

    try testing.expect(sGet(s, 1, 0, 0, 0).mag() < 0.01);
    try testing.expect(sGet(s, 1, 19, 0, 0).mag() > 0.8);

    for (0..20) |fi| {
        const f_val = freqs[fi];
        const wrc = 2.0 * std.math.pi * f_val * r_val * c_val;
        const denom = 1.0 + wrc * wrc;
        const zl = analysis.sp.Complex{ .re = r_val / denom, .im = -r_val * wrc / denom };
        const s11_expected = analysis.sp.Complex.div(
            analysis.sp.Complex{ .re = zl.re - z0, .im = zl.im },
            analysis.sp.Complex{ .re = zl.re + z0, .im = zl.im },
        );
        const s11_got = sGet(s, 1, fi, 0, 0);
        try testing.expectApproxEqAbs(s11_expected.re, s11_got.re, 1e-4);
        try testing.expectApproxEqAbs(s11_expected.im, s11_got.im, 1e-4);
    }
}

test "SP: linear sweep frequencies" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    const vbr = b.n;
    try b.addDevice(td.V, .{}, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 50 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const port_list = [_]analysis.sp.Port{.{ .node = n1, .branch = vbr, .z0 = 50.0 }};
    const freqs = try allocator.alloc(f64, 5);
    defer allocator.free(freqs);
    const s = try allocator.alloc(analysis.sp.Complex, 5);
    defer allocator.free(s);
    try analysis.sp.sweep(&ckt, x, &port_list, freqs, s, .{ .f_start = 1e6, .f_stop = 5e6, .n_points = 5, .sweep_type = .linear }, allocator);

    for (0..5) |fi| {
        try testing.expectApproxEqAbs(@as(f64, 1e6) * @as(f64, @floatFromInt(fi + 1)), freqs[fi], 1.0);
    }
}

// ============================================================================
// disto
// ============================================================================

/// Test scratch: one block holding the four output columns.
const Cols = struct {
    buf: []f64,
    n: usize,

    fn init(allocator: std.mem.Allocator, n_points: u32) !Cols {
        return .{ .buf = try allocator.alloc(f64, @as(usize, n_points) * 4), .n = n_points };
    }
    fn freqs(self: *const Cols) []f64 {
        return self.buf[0..self.n];
    }
    fn hd2(self: *const Cols) []f64 {
        return self.buf[self.n .. 2 * self.n];
    }
    fn v1Mag(self: *const Cols) []f64 {
        return self.buf[2 * self.n .. 3 * self.n];
    }
    fn v2Mag(self: *const Cols) []f64 {
        return self.buf[3 * self.n ..];
    }
};

test "disto: linear resistor divider has zero HD2" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const cols = try Cols.init(allocator, freq.logSweepCount(1e3, 1e6, 5));
    defer allocator.free(cols.buf);

    try analysis.disto.sweep(&setup.ckt, x, cols.freqs(), cols.hd2(), cols.v1Mag(), cols.v2Mag(), .{
        .f_start = 1e3,
        .f_stop = 1e6,
        .points_per_decade = 5,
        .ac_source_node = setup.n2,
        .ac_magnitude = 1.0,
        .output_node = setup.n2,
    }, allocator);

    try testing.expect(cols.freqs().len > 0);
    for (cols.hd2()) |h| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), h, 1e-6);
    }
}

test "disto: diode circuit produces nonzero HD2" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.D, .{ .dc = 0.7 }, 1000, .{ .is = 1e-14 });
    defer setup.ckt.deinit();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);
    try testing.expect((try dc.solve(&setup.ckt, x, .{ .tol = .{ .abstol = 1e-9 } })).converged);

    const cols = try Cols.init(allocator, freq.logSweepCount(1e3, 1e6, 5));
    defer allocator.free(cols.buf);

    try analysis.disto.sweep(&setup.ckt, x, cols.freqs(), cols.hd2(), cols.v1Mag(), cols.v2Mag(), .{
        .f_start = 1e3,
        .f_stop = 1e6,
        .points_per_decade = 5,
        .ac_source_node = setup.n2,
        .ac_magnitude = 0.001,
        .output_node = setup.n2,
    }, allocator);

    try testing.expect(cols.freqs().len > 0);

    var max_hd2: f64 = 0;
    for (cols.hd2()) |h| {
        max_hd2 = @max(max_hd2, h);
    }
    try testing.expect(max_hd2 > 1e-10);
}

test "disto: HD2 increases with signal level" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.D, .{ .dc = 0.7 }, 1000, .{ .is = 1e-14 });
    defer setup.ckt.deinit();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);
    try testing.expect((try dc.solve(&setup.ckt, x, .{ .tol = .{ .abstol = 1e-9 } })).converged);

    const cols_small = try Cols.init(allocator, freq.logSweepCount(1e3, 1e5, 3));
    defer allocator.free(cols_small.buf);
    try analysis.disto.sweep(&setup.ckt, x, cols_small.freqs(), cols_small.hd2(), cols_small.v1Mag(), cols_small.v2Mag(), .{
        .f_start = 1e3,
        .f_stop = 1e5,
        .points_per_decade = 3,
        .ac_source_node = setup.n2,
        .ac_magnitude = 0.001,
        .output_node = setup.n2,
    }, allocator);

    const cols_large = try Cols.init(allocator, freq.logSweepCount(1e3, 1e5, 3));
    defer allocator.free(cols_large.buf);
    try analysis.disto.sweep(&setup.ckt, x, cols_large.freqs(), cols_large.hd2(), cols_large.v1Mag(), cols_large.v2Mag(), .{
        .f_start = 1e3,
        .f_stop = 1e5,
        .points_per_decade = 3,
        .ac_source_node = setup.n2,
        .ac_magnitude = 0.01,
        .output_node = setup.n2,
    }, allocator);

    try testing.expect(cols_small.hd2().len > 0);
    try testing.expect(cols_large.hd2().len == cols_small.hd2().len);

    for (cols_small.hd2(), cols_large.hd2()) |hd2_s, hd2_l| {
        if (hd2_s > 1e-15) {
            try testing.expect(hd2_l > hd2_s);
        }
    }
}

test "disto: HD2 scales linearly with amplitude (Volterra property)" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.D, .{ .dc = 0.7 }, 1000, .{ .is = 1e-14 });
    defer setup.ckt.deinit();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);
    try testing.expect((try dc.solve(&setup.ckt, x, .{ .tol = .{ .abstol = 1e-9 } })).converged);

    const amp1: f64 = 0.0005;
    const amp2: f64 = 0.001;

    const c1 = try Cols.init(allocator, freq.logSweepCount(1e4, 1e4, 1));
    defer allocator.free(c1.buf);
    try analysis.disto.sweep(&setup.ckt, x, c1.freqs(), c1.hd2(), c1.v1Mag(), c1.v2Mag(), .{
        .f_start = 1e4,
        .f_stop = 1e4,
        .points_per_decade = 1,
        .ac_source_node = setup.n2,
        .ac_magnitude = amp1,
        .output_node = setup.n2,
    }, allocator);

    const c2 = try Cols.init(allocator, freq.logSweepCount(1e4, 1e4, 1));
    defer allocator.free(c2.buf);
    try analysis.disto.sweep(&setup.ckt, x, c2.freqs(), c2.hd2(), c2.v1Mag(), c2.v2Mag(), .{
        .f_start = 1e4,
        .f_stop = 1e4,
        .points_per_decade = 1,
        .ac_source_node = setup.n2,
        .ac_magnitude = amp2,
        .output_node = setup.n2,
    }, allocator);

    try testing.expect(c1.hd2().len >= 1);
    try testing.expect(c2.hd2().len >= 1);

    const hd2_1 = c1.hd2()[0];
    const hd2_2 = c2.hd2()[0];

    try testing.expect(hd2_1 > 1e-15);
    const ratio = hd2_2 / hd2_1;
    try testing.expectApproxEqRel(@as(f64, 2.0), ratio, 0.1);
}

// ============================================================================
// mc
// ============================================================================

// mc.analyze is the shipped numeric route: mc.run is analyze() with the
// param_vars collected off the netlist, and analyze's trials are
// sweep/lanes.solveLanes lanes drawn by LaneCtx.apply. So these assertions
// cover what production runs. (Driving mc.run directly here would vary
// nothing — it collects `primary` params, which are instance-field-0, and
// testdev's r/dc are Model fields.)
test "mc: same seed reproduces identical samples" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const param_vars = [_]analysis.mc.ParamVar{
        .{ .param_ptr = findParam(refs, "R", "r", 0), .nominal = 1000.0, .rel_tol = 0.05, .dist = .gaussian },
    };
    const probes = [_]u32{setup.n2};
    const opts: analysis.mc.Options = .{ .n_trials = 50, .seed = 12345 };

    const samples1 = try allocator.alloc(f64, opts.n_trials);
    defer allocator.free(samples1);
    const samples2 = try allocator.alloc(f64, opts.n_trials);
    defer allocator.free(samples2);
    var stats1: [1]analysis.mc.Stats = undefined;
    var stats2: [1]analysis.mc.Stats = undefined;

    const n1c = try analysis.mc.analyze(&setup.ckt, &param_vars, &probes, samples1, &stats1, &.{}, opts, allocator);
    const n2c = try analysis.mc.analyze(&setup.ckt, &param_vars, &probes, samples2, &stats2, &.{}, opts, allocator);

    try testing.expectEqual(n1c, n2c);
    try testing.expectEqual(@as(u32, opts.n_trials), n1c);
    try testing.expectEqualSlices(f64, samples1[0..n1c], samples2[0..n2c]);

    // ...and the draws are live: a lane-apply that stopped perturbing would
    // still pass the equality above.
    try testing.expect(samples1[0] != samples1[1]);
    try testing.expect(stats1[0].std_dev > 0);
}

test "mc: voltage divider with 5% R tolerance" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const param_vars = [_]analysis.mc.ParamVar{
        .{ .param_ptr = findParam(refs, "R", "r", 0), .nominal = 1000.0, .rel_tol = 0.05, .dist = .uniform },
        .{ .param_ptr = findParam(refs, "R", "r", 1), .nominal = 2000.0, .rel_tol = 0.05, .dist = .uniform },
    };

    const probes = [_]u32{setup.n2};
    const n_trials: u16 = 200;
    const samples = try allocator.alloc(f64, n_trials);
    defer allocator.free(samples);
    var stats: [1]analysis.mc.Stats = undefined;

    // Yield: nominal is 10/3 ~= 3.333; allow +/- 10% window
    const yield_specs = [_]analysis.mc.YieldSpec{
        .{ .probe_idx = 0, .lo = 3.0, .hi = 3.7 },
    };

    const n_conv = try analysis.mc.analyze(
        &setup.ckt,
        &param_vars,
        &probes,
        samples,
        &stats,
        &yield_specs,
        .{ .n_trials = n_trials, .seed = 42 },
        allocator,
    );

    // All runs should converge (linear circuit)
    try testing.expectEqual(@as(u32, 200), n_conv);

    const nominal = 10.0 / 3.0;
    try testing.expectApproxEqAbs(nominal, stats[0].mean, 0.15);

    try testing.expect(stats[0].std_dev > 0.001);
    try testing.expect(stats[0].std_dev < 0.5);

    try testing.expect(stats[0].min < nominal);
    try testing.expect(stats[0].max > nominal);

    // Spread should be roughly in the 5% range (output spread is a function
    // of both R1 and R2 tolerance, so it will be somewhat larger than 5%
    // of the output but bounded)
    const spread = stats[0].max - stats[0].min;
    try testing.expect(spread > 0.01);
    try testing.expect(spread < 1.0);

    try testing.expect(stats[0].yield_pct > 90.0);

    try testing.expectEqual(@as(u32, 200), stats[0].n_converged);
}

test "mc: gaussian distribution variation" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 10 }, 1000, .{ .r = 1000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const param_vars = [_]analysis.mc.ParamVar{
        .{ .param_ptr = findParam(refs, "R", "r", 0), .nominal = 1000.0, .rel_tol = 0.03, .dist = .gaussian },
    };

    const probes = [_]u32{setup.n2};
    const n_trials: u16 = 500;
    const samples = try allocator.alloc(f64, n_trials);
    defer allocator.free(samples);
    var stats: [1]analysis.mc.Stats = undefined;

    const n_conv = try analysis.mc.analyze(
        &setup.ckt,
        &param_vars,
        &probes,
        samples,
        &stats,
        &.{},
        .{ .n_trials = n_trials, .seed = 7 },
        allocator,
    );

    // Nominal: V = 10 * 1000/(1000+1000) = 5.0
    try testing.expectEqual(@as(u32, 500), n_conv);
    try testing.expectApproxEqAbs(@as(f64, 5.0), stats[0].mean, 0.1);
    try testing.expect(stats[0].std_dev > 0.0);
    try testing.expect(stats[0].std_dev < 0.3);
}

test "mc: zero tolerance yields identical results" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const param_vars = [_]analysis.mc.ParamVar{
        .{ .param_ptr = findParam(refs, "R", "r", 0), .nominal = 1000.0, .rel_tol = 0.0, .dist = .uniform },
        .{ .param_ptr = findParam(refs, "R", "r", 1), .nominal = 2000.0, .rel_tol = 0.0, .dist = .uniform },
    };

    const probes = [_]u32{setup.n2};
    const n_trials: u16 = 10;
    const samples = try allocator.alloc(f64, n_trials);
    defer allocator.free(samples);
    var stats: [1]analysis.mc.Stats = undefined;

    const n_conv = try analysis.mc.analyze(
        &setup.ckt,
        &param_vars,
        &probes,
        samples,
        &stats,
        &.{},
        .{ .n_trials = n_trials, .seed = 1 },
        allocator,
    );

    const nominal = 10.0 / 3.0;
    try testing.expectEqual(@as(u32, 10), n_conv);
    // gmin loads the divider by ~R*gmin relative — 1e-6 abs is the floor
    try testing.expectApproxEqAbs(nominal, stats[0].mean, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), stats[0].std_dev, 1e-9);
    try testing.expectApproxEqAbs(nominal, stats[0].min, 1e-6);
    try testing.expectApproxEqAbs(nominal, stats[0].max, 1e-6);
}

// ============================================================================
// temp_sweep
// ============================================================================

test "temp_sweep: resistor divider with tc1 — output drifts linearly" {
    const allocator = testing.allocator;

    // R1 = 1k with tc1 = 1e-3 /degC; R2 = 2k, no temperature coefficient
    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);

    const tc1: f64 = 1e-3;
    const tnom: f64 = 27.0;
    var temp_coeffs = [_]analysis.temp_sweep.TempCoeff{
        .{
            .param = findParam(refs, "R", "r", 0),
            .base_value = 1000.0,
            .tc1 = tc1,
            .tc2 = 0,
            .tnom = tnom,
        },
    };

    const probe_list = [_]u32{setup.n2};
    const temps = try allocator.alloc(f64, 34);
    defer allocator.free(temps);
    const values = try allocator.alloc(f64, 34);
    defer allocator.free(values);

    const res = try analysis.temp_sweep.sweep(&setup.ckt, x, &probe_list, &temp_coeffs, temps, values, .{
        .t_start = -40.0,
        .t_stop = 125.0,
        .t_step = 5.0,
        .t_nom = tnom,
    });

    try testing.expect(res.completed);
    try testing.expect(res.points > 0);
    try testing.expectEqual(@as(u32, 0), res.failed_temps);

    // Verify analytical result at each temperature point:
    // R1(T) = 1000 * (1 + 1e-3 * (T - 27))
    // R2 = 2000 (constant)
    // Vout = 5 * R2 / (R1(T) + R2)
    // R1(T) is rounded through f32 and gmin loads ~R*gmin relative,
    // so 1e-4 abs is the check floor here.
    for (temps[0..res.points], values[0..res.points]) |temp, actual_vout| {
        const dt = temp - tnom;
        const r1_at_t = 1000.0 * (1.0 + tc1 * dt);
        const expected_vout = 5.0 * 2000.0 / (r1_at_t + 2000.0);
        try testing.expectApproxEqAbs(expected_vout, actual_vout, 1e-4);
    }

    const first = values[0];
    const last = values[res.points - 1];
    // At T=-40, R1 = 1000*(1 + 1e-3*(-67)) = 933 -> Vout = 5*2000/2933 = 3.409
    // At T=125, R1 = 1000*(1 + 1e-3*(98))  = 1098 -> Vout = 5*2000/3098 = 3.228
    // So Vout should decrease with temperature (R1 grows, so R2/(R1+R2) shrinks)
    try testing.expect(first > last);
}

test "temp_sweep: resistor divider with tc2 — quadratic drift" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 10 }, 500, .{ .r = 500 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);

    // Both resistors have tc2 (quadratic), symmetrically applied
    const tc2_val: f64 = 5e-6;
    const tnom: f64 = 27.0;
    var temp_coeffs = [_]analysis.temp_sweep.TempCoeff{
        .{
            .param = findParam(refs, "R", "r", 0),
            .base_value = 500.0,
            .tc1 = 0,
            .tc2 = tc2_val,
            .tnom = tnom,
        },
        .{
            .param = findParam(refs, "R", "r", 1),
            .base_value = 500.0,
            .tc1 = 0,
            .tc2 = tc2_val,
            .tnom = tnom,
        },
    };

    const probe_list = [_]u32{setup.n2};
    const temps = try allocator.alloc(f64, 34);
    defer allocator.free(temps);
    const values = try allocator.alloc(f64, 34);
    defer allocator.free(values);

    const res = try analysis.temp_sweep.sweep(&setup.ckt, x, &probe_list, &temp_coeffs, temps, values, .{
        .t_start = 0.0,
        .t_stop = 100.0,
        .t_step = 10.0,
        .t_nom = tnom,
    });

    try testing.expect(res.completed);

    // Both resistors scale identically -> divider ratio stays 0.5 -> Vout = 5.0
    for (values[0..res.points]) |v| {
        try testing.expectApproxEqAbs(@as(f64, 5.0), v, 1e-6);
    }
}

test "temp_sweep: single temperature point at nominal" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 3.3 }, 1000, .{ .r = 1000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);

    var temp_coeffs = [_]analysis.temp_sweep.TempCoeff{
        .{
            .param = findParam(refs, "R", "r", 0),
            .base_value = 1000.0,
            .tc1 = 1e-3,
            .tc2 = 0,
            .tnom = 27.0,
        },
    };

    const probe_list = [_]u32{setup.n2};
    const temps = try allocator.alloc(f64, 34);
    defer allocator.free(temps);
    const values = try allocator.alloc(f64, 34);
    defer allocator.free(values);

    // Sweep at exactly tnom: R1 should be unchanged (dT=0)
    const res = try analysis.temp_sweep.sweep(&setup.ckt, x, &probe_list, &temp_coeffs, temps, values, .{
        .t_start = 27.0,
        .t_stop = 27.0,
        .t_step = 1.0,
        .t_nom = 27.0,
    });

    try testing.expect(res.completed);
    try testing.expectEqual(@as(u32, 1), res.points);
    // At tnom: R1 = R2 = 1k -> Vout = 3.3 * 0.5 = 1.65
    try testing.expectApproxEqAbs(@as(f64, 1.65), values[0], 1e-6);
}

test "temp_sweep: parameters restored after sweep" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const refs = try setup.ckt.collectParams();

    const x = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x);

    const r1_ptr = findParam(refs, "R", "r", 0);
    var temp_coeffs = [_]analysis.temp_sweep.TempCoeff{
        .{
            .param = r1_ptr,
            .base_value = 1000.0,
            .tc1 = 1e-3,
            .tc2 = 0,
            .tnom = 27.0,
        },
    };

    const probe_list = [_]u32{setup.n2};
    const temps = try allocator.alloc(f64, 34);
    defer allocator.free(temps);
    const values = try allocator.alloc(f64, 34);
    defer allocator.free(values);

    _ = try analysis.temp_sweep.sweep(&setup.ckt, x, &probe_list, &temp_coeffs, temps, values, .{
        .t_start = -40.0,
        .t_stop = 125.0,
        .t_step = 50.0,
        .t_nom = 27.0,
    });

    try testing.expectApproxEqAbs(@as(f64, 1000.0), r1_ptr.get(), 1e-15);
}

// ============================================================================
// hb
// ============================================================================

test "HB: single resistor with current source — DC and fundamental" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.R, .{ .r = 500.0 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const f0: f64 = 1000.0;
    const i_mag: f64 = 0.01; // 10 mA

    const nf: usize = 2 * 4 + 1;
    const probe_list = [_]u32{n1};
    const spectra = try allocator.alloc(f64, probe_list.len * nf);
    defer allocator.free(spectra);

    const res = try analysis.hb.solve(
        &ckt,
        n1,
        i_mag,
        &probe_list,
        spectra,
        .{
            .f0 = f0,
            .n_harmonics = 4,
            .max_iter = 100,
            .hb_tol = 1e-12,
        },
        allocator,
    );

    try testing.expect(res.converged);

    try testing.expectApproxEqAbs(@as(f64, 0.0), spectra[0], 1e-9);

    // Fundamental: V = R * I = 500 * 0.01 = 5V
    const expected_v = 500.0 * 0.01;
    const mag1 = analysis.hb.magnitude(spectra[0..nf], 1);
    try testing.expectApproxEqAbs(expected_v, mag1, 1e-6);

    // Higher harmonics should be zero (linear device)
    try testing.expectApproxEqAbs(@as(f64, 0.0), analysis.hb.magnitude(spectra[0..nf], 2), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), analysis.hb.magnitude(spectra[0..nf], 3), 1e-9);
}

test "HB: resistive divider with current source" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    const n2 = b.addNode();

    const r1: f32 = 1000.0;
    const r2: f32 = 2000.0;
    const i_mag: f64 = 0.01;

    try b.addDevice(td.R, .{ .r = r1 }, .{}, .{ n1, n2 });
    try b.addDevice(td.R, .{ .r = r2 }, .{}, .{ n2, GROUND });

    var ckt = try b.compile();
    defer ckt.deinit();

    const nf: usize = 2 * 4 + 1;
    const probe_list = [_]u32{ n1, n2 };
    const spectra = try allocator.alloc(f64, probe_list.len * nf);
    defer allocator.free(spectra);

    const res = try analysis.hb.solve(
        &ckt,
        n1,
        i_mag,
        &probe_list,
        spectra,
        .{
            .f0 = 500.0,
            .n_harmonics = 4,
            .max_iter = 100,
            .hb_tol = 1e-12,
        },
        allocator,
    );

    try testing.expect(res.converged);

    // V(n1) = I*(R1+R2) = 0.01 * 3000 = 30V at fundamental
    try testing.expectApproxEqAbs(30.0, analysis.hb.magnitude(spectra[0..nf], 1), 1e-6);
    // V(n2) = I*R2 = 0.01 * 2000 = 20V at fundamental
    try testing.expectApproxEqAbs(20.0, analysis.hb.magnitude(spectra[nf .. 2 * nf], 1), 1e-6);

    try testing.expectApproxEqAbs(@as(f64, 0.0), spectra[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), spectra[nf], 1e-9);
}

// ============================================================================
// pss
// ============================================================================

test "PSS: RC circuit with DC source converges to steady state" {
    const allocator = testing.allocator;

    const r_val: f32 = 1000.0;
    const c_val: f32 = 1.0e-7; // tau = RC = 0.1 ms
    var setup = try buildSeries(allocator, td.C, .{ .dc = 5.0 }, r_val, .{ .c = c_val });
    defer setup.ckt.deinit();

    const x_op = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x_op);

    // Use a period much longer than the RC time constant so transient settles.
    // tau = 0.1 ms, T = 1 ms = 10 * tau
    const T: f64 = 1e-3;
    const probes = [_]u32{ setup.n1, setup.n2 };
    const n_samples: u32 = 200;
    const ncols = 1 + probes.len;
    const wave = try allocator.alloc(f64, (n_samples + 1) * ncols);
    defer allocator.free(wave);

    const pss_result = try analysis.pss.solve(&setup.ckt, x_op, &probes, wave, .{
        .period = T,
        .max_shooting_iter = 20,
        .shooting_tol = 1e-4,
        .fd_epsilon = 1e-6,
        .newton_tol = 1e-9,
        .max_newton_iter = 50,
        .n_samples = n_samples,
    }, allocator);

    try testing.expect(pss_result.converged);
    // Rows span [0, T]: first row t=0, last row t=T.
    try testing.expectApproxEqAbs(T, wave[n_samples * ncols], 1e-12);

    // The periodic steady state of a DC-driven RC circuit is the DC operating point.
    // R feeds the cap with no load, so the capacitor charges to the full source
    // voltage in steady state.
    const v_out = wave[n_samples * ncols + 2]; // v(n2) of the last row
    try testing.expectApproxEqAbs(@as(f64, 5.0), v_out, 1e-2);
}

test "PSS: pure resistive circuit converges in one iteration" {
    const allocator = testing.allocator;

    // DC voltage source (no time dependence) — the "periodic" solution is constant
    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x_op = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x_op);

    const probes = [_]u32{ setup.n1, setup.n2 };
    const n_samples: u32 = 64;
    const ncols = 1 + probes.len;
    const wave = try allocator.alloc(f64, (n_samples + 1) * ncols);
    defer allocator.free(wave);

    const pss_result = try analysis.pss.solve(&setup.ckt, x_op, &probes, wave, .{
        .period = 1e-3,
        .max_shooting_iter = 10,
        .shooting_tol = 1e-6,
        .n_samples = n_samples,
    }, allocator);

    try testing.expect(pss_result.converged);
    // For a pure DC circuit, phi(x0) = x(T) - x0 = 0 on the first try
    // so it should converge in 0 or 1 shooting iterations.
    try testing.expect(pss_result.iterations <= 1);

    const v_out = wave[n_samples * ncols + 2]; // v(n2) of the last row
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), v_out, 1e-4);
}

// ============================================================================
// pnoise
// ============================================================================

test "pnoise: resistor thermal noise is flat regardless of periodicity" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), x[setup.n2], 1e-6);

    // Noise sources off the analytic Jacobian: thermal noise from R1 and R2.
    const sources = try setup.ckt.collectNoiseSources(x, allocator);
    defer allocator.free(sources);
    try testing.expectEqual(@as(usize, 2), sources.len);

    // f_stop < f_fundamental so no folded sideband lands exactly at DC
    // (a zero-frequency sideband would be skipped and break the 7x count).
    const n_points = freq.logSweepCount(1e3, 1e5, 5);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);

    const st = try analysis.pnoise.sweep(&setup.ckt, x, sources, freqs, density, .{
        .out_node = setup.n2,
        .f_start = 1e3,
        .f_stop = 1e5,
        .f_fundamental = 1e6, // arbitrary fundamental for LTI
        .points_per_decade = 5,
        .pss_n_samples = 16,
        .n_sidebands = 3,
    }, allocator);

    try testing.expect(st.pss_converged);
    try testing.expect(n_points > 0);

    // Analytical: for voltage divider with ideal source,
    // S_out = 4kT * R_parallel where R_parallel = R1*R2/(R1+R2)
    const temp_k = 27.0 + 273.15;
    const r_parallel = 1000.0 * 2000.0 / (1000.0 + 2000.0);
    const expected_density_per_sideband = 4.0 * k_boltzmann * temp_k * r_parallel;
    // With n_sidebands=3, we have 2*3+1=7 sidebands. For an LTI circuit,
    // all sidebands produce identical transfer functions, so the total density
    // is 7x the single-frequency density.
    const n_total_sidebands: f64 = 2.0 * 3.0 + 1.0;
    const expected_density = expected_density_per_sideband * n_total_sidebands;

    const first = density[0];
    const last = density[n_points - 1];
    try testing.expectApproxEqRel(first, last, 1e-3);

    try testing.expectApproxEqRel(expected_density, first, 1e-2);
}

test "pnoise: zero noise sources produce zero noise" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const sources = [_]analysis.NoiseSource{};
    const n_points = freq.logSweepCount(1e3, 1e5, 5);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);

    const st = try analysis.pnoise.sweep(&setup.ckt, x, &sources, freqs, density, .{
        .out_node = setup.n2,
        .f_start = 1e3,
        .f_stop = 1e5,
        .f_fundamental = 1e6,
        .points_per_decade = 5,
        .pss_n_samples = 8,
        .n_sidebands = 1,
    }, allocator);

    try testing.expect(st.pss_converged);
    try testing.expectApproxEqAbs(@as(f64, 0), st.total_noise, 1e-30);
    for (density[0..n_points]) |d| {
        try testing.expectApproxEqAbs(@as(f64, 0), d, 1e-30);
    }
}

test "pnoise: single resistor noise density matches 4kTR" {
    // Two equal resistors from a stiff source; only R2's thermal noise is
    // injected so the density is 4kT * G_R2 * |R1||R2|^2.
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 3.3 }, 500, .{ .r = 500 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    // Only R2 as noise source
    const sources = [_]analysis.NoiseSource{
        .{ .node_p = setup.n2, .node_n = GROUND, .conductance = 1.0 / 500.0 },
    };

    const n_points = freq.logSweepCount(1e3, 1e5, 5);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);

    // Use n_sidebands=0 to get a single sideband (no folding),
    // which should match the standard noise result exactly.
    const st = try analysis.pnoise.sweep(&setup.ckt, x, &sources, freqs, density, .{
        .out_node = setup.n2,
        .f_start = 1e3,
        .f_stop = 1e5,
        .f_fundamental = 1e6,
        .points_per_decade = 5,
        .pss_n_samples = 8,
        .n_sidebands = 0,
    }, allocator);

    try testing.expect(st.pss_converged);

    // With 1 sideband (m=0 only) and equal resistors:
    // Injecting 1A at n2: Z_n2 = R1||R2 = 250 ohm (with source pinning n1)
    // S_v = 4kT * G_R2 * |Z_n2|^2 = 4kT/R2 * (R1*R2/(R1+R2))^2
    const temp_k = 27.0 + 273.15;
    const r_par = 500.0 * 500.0 / (500.0 + 500.0); // 250
    const expected = 4.0 * k_boltzmann * temp_k * (1.0 / 500.0) * r_par * r_par;

    const first = density[0];
    try testing.expectApproxEqRel(expected, first, 1e-2);

    // Flat across frequency for resistive circuit
    const last = density[n_points - 1];
    try testing.expectApproxEqRel(first, last, 1e-3);
}

test "pnoise: PSS converges for resistive divider" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const sources = [_]analysis.NoiseSource{
        .{ .node_p = setup.n1, .node_n = setup.n2, .conductance = 1.0 / 1000.0 },
    };

    const n_points = freq.logSweepCount(1e3, 1e4, 3);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);

    const st = try analysis.pnoise.sweep(&setup.ckt, x, &sources, freqs, density, .{
        .out_node = setup.n2,
        .f_start = 1e3,
        .f_stop = 1e4,
        .f_fundamental = 1e6,
        .points_per_decade = 3,
        .pss_n_samples = 4,
        .pss_shoot_max_iter = 10,
        .n_sidebands = 0,
    }, allocator);

    try testing.expect(st.pss_converged);
    try testing.expect(n_points > 0);
    // freqs and density are parallel per-point columns filled by the sweep
    try testing.expect(freqs[n_points - 1] > freqs[0]);
    try testing.expect(density[n_points - 1] >= 0);
}

test "pnoise: total noise integrates correctly over bandwidth" {
    // For flat noise density S_v, total noise = sqrt(S_v * bandwidth).
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const sources = try setup.ckt.collectNoiseSources(x, allocator);
    defer allocator.free(sources);
    try testing.expectEqual(@as(usize, 2), sources.len);

    const f_start = 1.0;
    const f_stop = 1e6;
    const n_points = freq.logSweepCount(f_start, f_stop, 50);
    const freqs = try allocator.alloc(f64, n_points);
    defer allocator.free(freqs);
    const density = try allocator.alloc(f64, n_points);
    defer allocator.free(density);

    const st = try analysis.pnoise.sweep(&setup.ckt, x, sources, freqs, density, .{
        .out_node = setup.n2,
        .f_start = f_start,
        .f_stop = f_stop,
        .f_fundamental = 1e6,
        .points_per_decade = 50,
        .pss_n_samples = 8,
        .n_sidebands = 0, // single sideband for comparison with standard noise
    }, allocator);

    try testing.expect(st.pss_converged);

    // Analytical: total = sqrt(S_v * BW)
    const temp_k = 27.0 + 273.15;
    const r_parallel = 1000.0 * 2000.0 / (1000.0 + 2000.0);
    const flat_density = 4.0 * k_boltzmann * temp_k * r_parallel;
    const bandwidth = f_stop - f_start;
    const expected_total = @sqrt(flat_density * bandwidth);

    // With 50 points/decade trapezoidal integration, expect ~2% accuracy
    try testing.expectApproxEqRel(expected_total, st.total_noise, 0.02);
}

// ============================================================================
// envelope
// ============================================================================

test "envelope: DC circuit envelope is constant" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const expected_v2 = 10.0 / 3.0;
    try testing.expectApproxEqAbs(expected_v2, x[setup.n2], 1e-6);

    const probe_list = [_]u32{setup.n2};
    const opts = analysis.envelope.Options{
        .t_carrier = 1e-6, // 1 MHz carrier
        .t_stop = 10e-6, // 10 carrier periods
        .carrier_steps_per_period = 16,
        .periods_per_outer_step = 1,
        .max_periods_per_step = 4,
    };
    const ncols = 1 + 2 * probe_list.len;
    const rows = try allocator.alloc(f64, analysis.envelope.maxPoints(opts) * ncols);
    defer allocator.free(rows);

    const sim_result = try analysis.envelope.simulate(&setup.ckt, x, &probe_list, rows, opts, allocator);

    try testing.expect(sim_result.completed);
    try testing.expect(sim_result.n_points > 1);

    // For a DC circuit, the envelope should be constant at the divider voltage
    for (0..sim_result.n_points) |i| {
        try testing.expectApproxEqAbs(expected_v2, rows[i * ncols + 1], 1e-3);
    }
}

test "envelope: result tracks multiple probes" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 10.0 }, 1000, .{ .r = 1000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const probe_list = [_]u32{ setup.n1, setup.n2 };
    const opts = analysis.envelope.Options{
        .t_carrier = 1e-6,
        .t_stop = 5e-6,
        .carrier_steps_per_period = 16,
    };
    const ncols = 1 + 2 * probe_list.len;
    const rows = try allocator.alloc(f64, analysis.envelope.maxPoints(opts) * ncols);
    defer allocator.free(rows);

    const sim_result = try analysis.envelope.simulate(&setup.ckt, x, &probe_list, rows, opts, allocator);

    try testing.expect(sim_result.completed);
    try testing.expect(sim_result.n_points > 1);

    // n1 should be at 10V, n2 at 5V (equal divider) — row-major rows hold
    // both probes at every recorded point by construction.
    const last = rows[(sim_result.n_points - 1) * ncols ..][0..ncols];
    try testing.expectApproxEqAbs(@as(f64, 10.0), last[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 5.0), last[3], 1e-3);
}

test "envelope: adaptive stepping increases step size for steady envelope" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const probe_list = [_]u32{setup.n2};

    // With a DC circuit, the envelope is perfectly steady, so the adaptive
    // stepping should take progressively larger outer steps.
    const opts = analysis.envelope.Options{
        .t_carrier = 1e-6,
        .t_stop = 100e-6, // 100 carrier periods
        .carrier_steps_per_period = 8,
        .periods_per_outer_step = 1,
        .max_periods_per_step = 16,
    };
    const ncols = 1 + 2 * probe_list.len;
    const rows = try allocator.alloc(f64, analysis.envelope.maxPoints(opts) * ncols);
    defer allocator.free(rows);

    const sim_result = try analysis.envelope.simulate(&setup.ckt, x, &probe_list, rows, opts, allocator);

    try testing.expect(sim_result.completed);
    // Adaptive stepping should complete in fewer steps than 100 (one per period)
    // because the step size grows when the envelope is constant.
    try testing.expect(sim_result.outer_steps < 100);
}

test "envelope: sinusoidal carrier envelope tracks amplitude" {
    // 1 MHz sine through an equal divider: the quasi-static inner sweep
    // samples the carrier, so peak ~ amp/2 and rms ~ peak/sqrt(2).
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 0.0, .amp = 2.0, .freq = 1e6 }, 1000, .{ .r = 1000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const probe_list = [_]u32{setup.n2};
    const opts = analysis.envelope.Options{
        .t_carrier = 1e-6,
        .t_stop = 8e-6,
        .carrier_steps_per_period = 64,
        .periods_per_outer_step = 1,
        .max_periods_per_step = 4,
    };
    const ncols = 1 + 2 * probe_list.len;
    const rows = try allocator.alloc(f64, analysis.envelope.maxPoints(opts) * ncols);
    defer allocator.free(rows);

    const sim_result = try analysis.envelope.simulate(&setup.ckt, x, &probe_list, rows, opts, allocator);

    try testing.expect(sim_result.completed);
    try testing.expect(sim_result.n_points > 1);

    // Skip the initial DC point; every sampled period should see the full swing.
    for (1..sim_result.n_points) |i| {
        try testing.expectApproxEqAbs(@as(f64, 1.0), rows[i * ncols + 1], 2e-2);
        try testing.expectApproxEqAbs(@as(f64, 1.0 / @sqrt(2.0)), rows[i * ncols + 2], 5e-2);
    }
}

test "envelope: simulate with zero probes records times only" {
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.V, .{ .dc = 1.0 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const opts = analysis.envelope.Options{
        .t_carrier = 1e-6,
        .t_stop = 3e-6,
        .carrier_steps_per_period = 8,
    };
    const rows = try allocator.alloc(f64, analysis.envelope.maxPoints(opts)); // ncols == 1
    defer allocator.free(rows);

    const sim_result = try analysis.envelope.simulate(&ckt, x, &.{}, rows, opts, allocator);
    try testing.expect(sim_result.completed);
    try testing.expect(sim_result.n_points > 1);
    try testing.expectApproxEqAbs(@as(f64, 0.0), rows[0], 1e-15);
}

// ============================================================================
// tran_noise
// ============================================================================

test "tran_noise: resistor thermal noise power matches 4kTR*BW" {
    const allocator = testing.allocator;

    // Circuit: voltage source V1(n1, GND) = 0V, resistor R(n1, n2),
    // resistor R_load(n2, GND). We measure noise at n2.
    //
    // With V1 = 0V, the DC operating point is all zeros.
    // The noise source on R injects current noise between n1 and n2; the
    // n1 injection lands on the pinned node and vanishes. At n2 the
    // impedance is R || R_load (n1 is an AC ground through the source), so
    // V_noise(n2) = i_noise * (R || R_load).
    //
    // Expected noise power: <v^2> = 4kT*G_R * (R || R_load)^2 * BW
    //   where BW = 1/(2*dt) and G_R = 1/R.

    const r_val: f64 = 1000.0;
    const r_load_val: f64 = 1000.0;
    var setup = try buildSeries(allocator, td.R, .{ .dc = 0.0 }, @floatCast(r_val), .{ .r = @floatCast(r_load_val) });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    // Fixed timestep transient noise simulation. dt is a power of two so the
    // time accumulation is exact and no shrunken (huge-bandwidth) final step
    // sneaks in.
    const temp_k: f64 = 27.0 + 273.15;
    const dt: f64 = 0x1p-30; // ~0.93 ns
    const n_steps: u32 = 50_000;
    const t_stop = dt * @as(f64, @floatFromInt(n_steps));
    const bandwidth = 1.0 / (2.0 * dt);

    // Single noise source on R (between n1 and n2)
    const noise_sources = [_]analysis.NoiseSource{
        .{ .node_p = setup.n1, .node_n = setup.n2, .conductance = 1.0 / r_val },
    };

    const probes = [_]u32{setup.n2};
    const result = try analysis.tran_noise.simulate(&setup.ckt, x, &probes, &noise_sources, .{
        .t_stop = t_stop,
        .dt_init = dt,
        .dt_min = dt,
        .dt_max = dt,
        .max_steps = n_steps + 10,
        .temp_k = temp_k,
        .seed = 12345,
    }, allocator);
    defer allocator.free(result.rows);

    try testing.expect(result.completed);

    // Compute noise power: mean of v^2 (DC is zero, so variance = mean(v^2))
    // Rows are (time, v(n2)); skip first sample (DC initial condition).
    var sum_sq: f64 = 0;
    for (1..result.npoints) |i| {
        const v = result.rows[i * 2 + 1];
        sum_sq += v * v;
    }
    const measured_power = sum_sq / @as(f64, @floatFromInt(result.npoints - 1));

    // Expected noise power at n2:
    // The noise current source on R has PSD: S_i = 4kT/R.
    // It drives into the impedance at n2: Z_n2 = R || R_load.
    // So voltage noise power: <v^2> = 4kT/R * (R || R_load)^2 * BW.
    const z_n2 = r_val * r_load_val / (r_val + r_load_val);
    const expected_power = 4.0 * k_boltzmann * temp_k * (1.0 / r_val) * z_n2 * z_n2 * bandwidth;

    // Statistical test: with 50k samples, expect ~5% relative tolerance
    const ratio = measured_power / expected_power;
    try testing.expect(ratio > 0.85);
    try testing.expect(ratio < 1.15);
}

test "tran_noise: zero noise sources produces clean transient" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5.0 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);

    const probes = [_]u32{setup.n2};
    const noise_sources = [_]analysis.NoiseSource{};
    const result = try analysis.tran_noise.simulate(&setup.ckt, x, &probes, &noise_sources, .{
        .t_stop = 1e-6,
        .dt_init = 1e-9,
        .dt_max = 1e-7,
    }, allocator);
    defer allocator.free(result.rows);

    try testing.expect(result.completed);
    try testing.expect(result.npoints > 1);

    // With zero noise sources, the voltage divider output should stay at DC
    // (~gmin*R loading -> 1e-6 abs floor).
    const expected_v = 10.0 / 3.0;
    for (0..result.npoints) |i| {
        try testing.expectApproxEqAbs(expected_v, result.rows[i * 2 + 1], 1e-6);
    }
}

test "tran_noise: deterministic with same seed" {
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 0.0 }, 1000, .{ .r = 1000 });
    defer setup.ckt.deinit();

    const x1 = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x1);
    const x2 = try allocator.alloc(f64, setup.ckt.n);
    defer allocator.free(x2);

    try testing.expect((try dc.solve(&setup.ckt, x1, .{})).converged);

    const noise_sources = [_]analysis.NoiseSource{
        .{ .node_p = setup.n1, .node_n = setup.n2, .conductance = 1e-3 },
    };
    const probes = [_]u32{setup.n2};

    const sim_opts = analysis.tran_noise.Options{
        .t_stop = 1e-7,
        .dt_init = 1e-9,
        .dt_max = 1e-9,
        .seed = 0xABCD_1234,
    };

    const r1 = try analysis.tran_noise.simulate(&setup.ckt, x1, &probes, &noise_sources, sim_opts, allocator);
    defer allocator.free(r1.rows);

    // Second run from a fresh DC operating point, same seed
    try testing.expect((try dc.solve(&setup.ckt, x2, .{})).converged);
    const r2 = try analysis.tran_noise.simulate(&setup.ckt, x2, &probes, &noise_sources, sim_opts, allocator);
    defer allocator.free(r2.rows);

    try testing.expectEqual(r1.npoints, r2.npoints);
    for (r1.rows[0 .. r1.npoints * 2], r2.rows[0 .. r2.npoints * 2]) |a, b2| {
        try testing.expectEqual(a, b2);
    }
}

test "tran_noise: RC circuit filters injected noise below open-loop level" {
    // Charge path coverage: R || C driven by a noise current. The BE
    // companion must engage (has_charge), and the capacitor shunts noise, so
    // the measured power at the node is below the resistor-only level.
    const allocator = testing.allocator;

    var b = Builder.init(allocator);
    const n1 = b.addNode();
    try b.addDevice(td.R, .{ .r = 1000 }, .{}, .{ n1, GROUND });
    try b.addDevice(td.C, .{ .c = 1e-9 }, .{}, .{ n1, GROUND });
    var ckt = try b.compile();
    defer ckt.deinit();
    try testing.expect(ckt.has_charge);

    const x = try solveOp(&ckt, allocator);
    defer allocator.free(x);

    const dt: f64 = 0x1p-30;
    const n_steps: u32 = 20_000;
    const noise_sources = [_]analysis.NoiseSource{
        .{ .node_p = n1, .node_n = GROUND, .conductance = 1e-3 },
    };
    const probes = [_]u32{n1};

    const result = try analysis.tran_noise.simulate(&ckt, x, &probes, &noise_sources, .{
        .t_stop = dt * @as(f64, @floatFromInt(n_steps)),
        .dt_init = dt,
        .dt_min = dt,
        .dt_max = dt,
        .max_steps = n_steps + 10,
        .seed = 777,
    }, allocator);
    defer allocator.free(result.rows);
    try testing.expect(result.completed);

    var sum_sq: f64 = 0;
    for (1..result.npoints) |i| {
        const v = result.rows[i * 2 + 1];
        sum_sq += v * v;
    }
    const measured = sum_sq / @as(f64, @floatFromInt(result.npoints - 1));

    // Resistor-only power would be 4kT*G*R^2*BW; tau/dt ~ 1000 so the C
    // filters hard — expect well under half the unfiltered level, non-zero.
    const bw = 1.0 / (2.0 * dt);
    const unfiltered = 4.0 * k_boltzmann * (27.0 + 273.15) * 1e-3 * 1000.0 * 1000.0 * bw;
    try testing.expect(measured > 0);
    try testing.expect(measured < 0.5 * unfiltered);
}

// ============================================================================
// pac
// ============================================================================

test "PAC: full circuit integration — resistive divider (flat, no mixing)" {
    // A resistive divider has no time-varying components, so the PAC result
    // should show all energy at sideband m=0 (direct path) with zero
    // conversion to other sidebands.
    const allocator = testing.allocator;

    var setup = try buildSeries(allocator, td.R, .{ .dc = 5 }, 1000, .{ .r = 2000 });
    defer setup.ckt.deinit();

    const x = try solveOp(&setup.ckt, allocator);
    defer allocator.free(x);
    try testing.expectApproxEqAbs(@as(f64, 10.0 / 3.0), x[setup.n2], 1e-6);

    const opts = analysis.pac.Options{
        .f_lo = 1e6,
        .n_harmonics = 1,
        .f_start = 1e5,
        .f_stop = 1e5, // single point
        .points_per_decade = 1,
        .n_time_samples = 16,
        .pss_periods = 5,
    };
    const n_harm: usize = opts.n_harmonics;
    const n_sb: usize = 2 * n_harm + 1;
    const n_freqs: usize = freq.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);
    const freqs = try allocator.alloc(f64, n_freqs);
    defer allocator.free(freqs);
    const transfer = try allocator.alloc(analysis.pac.Complex, n_freqs * n_sb);
    defer allocator.free(transfer);

    try analysis.pac.analyze(&setup.ckt, x, setup.n2, 1.0, setup.n2, freqs, transfer, opts, allocator);

    try testing.expect(n_freqs > 0);
    try testing.expectApproxEqRel(@as(f64, 1e5), freqs[0], 1e-12);

    // For a linear time-invariant circuit, sideband m=0 should dominate.
    // Sidebands m=+/-1 should be negligible.
    const direct = transfer[n_harm]; // m=0 sideband of the first point
    const direct_mag = direct.mag();
    try testing.expect(direct_mag > 0);

    const up = transfer[n_harm + 1]; // m=+1
    const down = transfer[n_harm - 1]; // m=-1
    // Sideband conversion should be much smaller than direct path.
    try testing.expect(up.mag() < direct_mag * 0.01);
    try testing.expect(down.mag() < direct_mag * 0.01);
}

// ============================================================================
// converger: JFNK vs Newton
// ============================================================================

const converger = @import("analysis").converger;

test "jfnk vs newton: divider OP agrees to 1e-9" {
    var setup = try buildSeries(testing.allocator, td.R, .{ .dc = 10 }, 1000, .{ .r = 3000 });
    defer setup.ckt.deinit();

    try setup.ckt.computeBaseline();

    // Newton (direct)
    var ws_n = try converger.Workspace.init(testing.allocator, setup.ckt.n, setup.ckt.col_ptr, setup.ckt.row_idx, setup.ckt.bbd);
    defer ws_n.deinit(testing.allocator);
    const x_n = try testing.allocator.alloc(f64, setup.ckt.n);
    defer testing.allocator.free(x_n);
    @memset(x_n, 0);
    const nr = try converger.newton(&setup.ckt, &ws_n, x_n, 0, .{}, analysis.EvalHook{});
    try testing.expect(nr.converged);

    // JFNK
    var ws_j = try converger.Workspace.init(testing.allocator, setup.ckt.n, setup.ckt.col_ptr, setup.ckt.row_idx, setup.ckt.bbd);
    defer ws_j.deinit(testing.allocator);
    const x_j = try testing.allocator.alloc(f64, setup.ckt.n);
    defer testing.allocator.free(x_j);
    @memset(x_j, 0);
    const jr = try converger.jfnk(&setup.ckt, &ws_j, x_j, 0, .{}, analysis.EvalHook{});
    try testing.expect(jr.converged);

    for (0..setup.ckt.n) |i| {
        try testing.expectApproxEqAbs(x_n[i], x_j[i], 1e-9);
    }
}

test "jfnk: 100-diode ladder converges" {
    const n_diodes: usize = 100;
    var b = Builder.init(testing.allocator);
    const vin = b.addNode();
    try b.addDevice(td.V, .{ .dc = 5 }, .{}, .{ vin, GROUND });

    // Chain: R—D—R—D—...—GND
    var prev: u32 = vin;
    for (0..n_diodes) |_| {
        const mid = b.addNode();
        try b.addDevice(td.R, .{ .r = 100 }, .{}, .{ prev, mid });
        try b.addDevice(td.D, .{ .is = 1e-14 }, .{}, .{ mid, GROUND });
        prev = mid;
    }
    // Final resistor to ground
    try b.addDevice(td.R, .{ .r = 100 }, .{}, .{ prev, GROUND });

    var ckt = try b.compile();
    defer ckt.deinit();
    try ckt.computeBaseline();

    var ws = try converger.Workspace.init(testing.allocator, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer ws.deinit(testing.allocator);
    const x = try testing.allocator.alloc(f64, ckt.n);
    defer testing.allocator.free(x);
    @memset(x, 0);

    const r = try converger.jfnk(&ckt, &ws, x, 0, .{
        .max_iter = 200,
        .abstol = 1e-9,
    }, analysis.EvalHook{});
    try testing.expect(r.converged);

    // Sanity: first node should be near 5V (source), diode nodes between 0 and 1V
    try testing.expectApproxEqAbs(@as(f64, 5.0), x[vin], 1e-3);
}
