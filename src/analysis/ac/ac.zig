//! AC small-signal sweep: one eval() linearizes (the planes are G and C),
//! then every frequency point is a fill + factor + solve. No circuit
//! contact inside the sweep.
const std = @import("std");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("solvers").types;
const FreqSolver = root.solvers.freq_solve.FreqSolver;

pub const Complex = types.Complex;


pub const Options = struct {
    tol: converger.Tolerances = .{},
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
};

/// AC small-signal sweep. Excitation goes on the source vsource's BRANCH row
/// (its branch equation is v_p - v_n - V = 0, so rhs[branch] = V_ac); driving
/// the clamped node row instead yields identically zero response.
///
/// Caller owns the output: freqs[n_points], resp[probes.len * n_points]
/// flat, probe-major (resp[p * n_points + k]). No per-point allocation.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    ac_branch: u32,
    ac_mag: f64,
    ac_phase_deg: f64,
    probes: []const u32,
    freqs: []f64,
    resp: []Complex,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    const nn = 2 * n;
    const n_points = freqs.len;
    std.debug.assert(resp.len == probes.len * n_points);

    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    const rhs = try allocator.alloc(f64, nn);
    defer allocator.free(rhs);
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);

    root.zeroSimd(rhs);
    const phase_rad = ac_phase_deg * (std.math.pi / 180.0);
    rhs[ac_branch] = ac_mag * @cos(phase_rad);
    rhs[n + ac_branch] = ac_mag * @sin(phase_rad);

    // ponytail: GPU batch path — all freq points are independent (G+jωC) solves.
    // Falls through to serial on error or when hook is absent.
    if (ckt.gpu_hook != null) gpu: {
        const omegas = allocator.alloc(f64, n_points) catch break :gpu;
        defer allocator.free(omegas);
        types.fillLogSweep(options.f_start, options.f_stop, options.points_per_decade, freqs, omegas);

        const x_out = ckt.gpuFreqBatch(allocator, ckt.g_vals, ckt.c_vals, omegas, rhs, @intCast(n), false) orelse break :gpu;
        defer allocator.free(x_out);

        for (0..n_points) |k| {
            const lane = x_out[k * nn ..][0..nn];
            for (probes, 0..) |node, p| {
                resp[p * n_points + k] = .{
                    .re = lane[node],
                    .im = lane[n + node],
                };
            }
        }
        return;
    }

    // Serial fallback
    var sw = types.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var k: usize = 0;
    while (sw.next()) |f| : (k += 1) {
        try fs.solve(2.0 * std.math.pi * f, rhs, x_work);

        freqs[k] = f;
        for (probes, 0..) |node, p| {
            resp[p * n_points + k] = .{
                .re = x_work[node],
                .im = x_work[n + node],
            };
        }
    }
}

/// Contract entry: unit excitation on the first source branch, complex
/// response at every probe. Data layout: point-major (freq, probes...) with
/// (re, im) per variable.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;
    const n_points = types.logSweepCount(opts.f_start, opts.f_stop, opts.points_per_decade);

    const freqs = try a.alloc(f64, n_points);
    defer a.free(freqs);
    const resp = try a.alloc(Complex, ctx.probes.len * n_points);
    defer a.free(resp);

    try sweep(ctx.circuit, x_op, ctx.source_branch, 1.0, 0.0, ctx.probes, freqs, resp, opts, a);

    const names = try root.probeNames(ctx, "frequency");
    errdefer {
        for (names[1..]) |s| a.free(s); // names[0] is the "frequency" literal
        a.free(names);
    }
    const ncols = names.len;
    const data = try a.alloc(f64, n_points * ncols * 2);
    for (0..n_points) |p| {
        const row = data[p * ncols * 2 ..][0 .. ncols * 2];
        row[0] = freqs[p];
        row[1] = 0;
        for (0..ctx.probes.len) |idx| {
            const c = resp[idx * n_points + p];
            row[(idx + 1) * 2] = c.re;
            row[(idx + 1) * 2 + 1] = c.im;
        }
    }

    return .{
        .plotname = "AC Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = n_points,
        .data = data,
    };
}
