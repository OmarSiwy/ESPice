//! Distortion analysis via simplified Volterra series. One eval() at the
//! operating point yields the analytic G and C planes; the second-order
//! kernel is finite differences OF the analytic Jacobian (d2F = dG/dx),
//! one eval per unknown. Per-frequency solves are dense.
const std = @import("std");
const root = @import("../root.zig");
const converger = @import("../helper/converger.zig");
const dense_lu = root.solvers.dense_lu;
const freq = @import("../helper/freq.zig");

pub const Options = struct {
    tol: converger.Tolerances = .{},
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
    /// AC drive node; GROUND means "the drive source node" (ctx.source_node)
    /// when running via the contract.
    ac_source_node: u32 = root.GROUND,
    ac_magnitude: f64 = 1.0,
    /// Output node; GROUND means "the last probe" when running via the contract.
    output_node: u32 = root.GROUND,
    fd_eps: f64 = 1e-6,
};

/// Distortion analysis via simplified Volterra series.
///
/// Computes second harmonic distortion (HD2) across a frequency sweep:
///   1. Linearize at the DC operating point: one eval(), dense G and C.
///   2. Second-order kernel d2F/dxa dxb = dG[.,a]/dx_b by differencing the
///      analytic Jacobian at n perturbed points (first derivatives are
///      analytic; only the extra order is FD).
///   3. For each frequency f:
///      a. Solve first-order: (G + jwC) * V1 = excitation
///      b. Second-order nonlinear current D2(V1, V1) from the kernel
///      c. Solve second-order: (G + j*2w*C) * V2 = -D2(V1, V1)
///      d. HD2 = |V2[output]| / |V1[output]|
///
/// Caller owns the outputs, one value per frequency point:
/// freqs / hd2 / v1_mag / v2_mag, all logSweepCount(...) long.
pub fn sweep(
    ckt: *root.Circuit,
    x_op: []const f64,
    freqs: []f64,
    hd2: []f64,
    v1_mag: []f64,
    v2_mag: []f64,
    options: Options,
    allocator: std.mem.Allocator,
) !void {
    const n: usize = ckt.n;
    std.debug.assert(hd2.len == freqs.len and v1_mag.len == freqs.len and v2_mag.len == freqs.len);

    // -- Step 1: Linearize at DC operating point (analytic planes) --
    ckt.eval(x_op, 0);

    const g_dense = try allocator.alloc(f64, n * n);
    defer allocator.free(g_dense);
    ckt.denseG(g_dense);

    const c_mat = try allocator.alloc(f64, n * n);
    defer allocator.free(c_mat);
    ckt.denseC(c_mat);

    // -- Step 2: Second derivatives = FD of the analytic Jacobian --
    // d2[row][a][b] ≈ (G(x_op + eps*e_b) − G(x_op))[row][a] / eps
    const eps = options.fd_eps;
    const inv_eps = 1.0 / eps;
    const d2 = try allocator.alloc(f64, n * n * n);
    defer allocator.free(d2);

    const g_pert = try allocator.alloc(f64, n * n);
    defer allocator.free(g_pert);
    const x_pert = try allocator.alloc(f64, n);
    defer allocator.free(x_pert);

    for (0..n) |b| {
        @memcpy(x_pert, x_op);
        x_pert[b] += eps;
        ckt.eval(x_pert, 0);
        ckt.denseG(g_pert);
        for (0..n) |row| {
            for (0..n) |a| {
                d2[row * n * n + a * n + b] =
                    (g_pert[row * n + a] - g_dense[row * n + a]) * inv_eps;
            }
        }
    }
    // leave the planes consistent with the operating point
    ckt.eval(x_op, 0);

    // -- Step 3: Frequency sweep --

    const nn = 2 * n;
    const a_work = try allocator.alloc(f64, nn * nn);
    defer allocator.free(a_work);
    const rhs_work = try allocator.alloc(f64, nn);
    defer allocator.free(rhs_work);
    const x_work = try allocator.alloc(f64, nn);
    defer allocator.free(x_work);

    const a_work2 = try allocator.alloc(f64, nn * nn);
    defer allocator.free(a_work2);
    const rhs_work2 = try allocator.alloc(f64, nn);
    defer allocator.free(rhs_work2);
    const x_work2 = try allocator.alloc(f64, nn);
    defer allocator.free(x_work2);

    const v1_re = try allocator.alloc(f64, n);
    defer allocator.free(v1_re);
    const v1_im = try allocator.alloc(f64, n);
    defer allocator.free(v1_im);

    var sw = freq.logSweep(options.f_start, options.f_stop, options.points_per_decade);
    var k: usize = 0;
    while (sw.next()) |f| : (k += 1) {
        const omega = 2.0 * std.math.pi * f;

        // -- 3a: First-order solve: (G + jwC) * V1 = excitation --
        dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, omega, a_work);

        @memset(rhs_work, 0);
        rhs_work[options.ac_source_node] = options.ac_magnitude;

        try dense_lu.factorizeSolve(nn, a_work, rhs_work, x_work);

        @memcpy(v1_re, x_work[0..n]);
        @memcpy(v1_im, x_work[n..nn]);

        // -- 3b: Build second-order RHS: -D2(V1, V1) --
        @memset(rhs_work2, 0);
        for (0..n) |row| {
            var d2_re: f64 = 0;
            var d2_im: f64 = 0;
            for (0..n) |a| {
                for (0..n) |b| {
                    const coeff = d2[row * n * n + a * n + b];
                    if (coeff == 0) continue;
                    const prod_re = v1_re[a] * v1_re[b] - v1_im[a] * v1_im[b];
                    const prod_im = v1_re[a] * v1_im[b] + v1_im[a] * v1_re[b];
                    d2_re += coeff * prod_re;
                    d2_im += coeff * prod_im;
                }
            }
            rhs_work2[row] = -d2_re;
            rhs_work2[n + row] = -d2_im;
        }

        // -- 3c: Solve second-order: (G + j*2w*C) * V2 = -D2(V1,V1) --
        const omega2 = 2.0 * omega;
        dense_lu.buildComplexAdmittance(n, nn, g_dense, c_mat, omega2, a_work2);

        try dense_lu.factorizeSolve(nn, a_work2, rhs_work2, x_work2);

        // -- 3d: Compute HD2 = |V2[output]| / |V1[output]| --
        const out = options.output_node;
        const v1_out_re = v1_re[out];
        const v1_out_im = v1_im[out];
        const v1_out_mag = @sqrt(v1_out_re * v1_out_re + v1_out_im * v1_out_im);

        const v2_out_re = x_work2[out];
        const v2_out_im = x_work2[n + out];
        const v2_out_mag = @sqrt(v2_out_re * v2_out_re + v2_out_im * v2_out_im);

        const hd2_val = if (v1_out_mag > 1e-30) v2_out_mag / v1_out_mag else 0;

        freqs[k] = f;
        hd2[k] = hd2_val;
        v1_mag[k] = v1_out_mag;
        v2_mag[k] = v2_out_mag;
    }
}

/// Contract entry: drive at opts.ac_source_node (or the drive source),
/// measure at opts.output_node (or the last probe). Data layout: point-major
/// (frequency, hd2, v1_mag, v2_mag).
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const x_op = ctx.x_op orelse return error.NoOperatingPoint;

    var o = opts;
    if (o.ac_source_node == root.GROUND) o.ac_source_node = ctx.source_node;
    if (o.output_node == root.GROUND) {
        if (ctx.probes.len == 0) return error.NoProbes;
        o.output_node = ctx.probes[ctx.probes.len - 1];
    }

    const n_points: usize = freq.logSweepCount(o.f_start, o.f_stop, o.points_per_decade);
    // one flat block, four columns
    const cols = try a.alloc(f64, n_points * 4);
    defer a.free(cols);
    const freqs = cols[0..n_points];
    const hd2 = cols[n_points .. 2 * n_points];
    const v1_mag = cols[2 * n_points .. 3 * n_points];
    const v2_mag = cols[3 * n_points ..];

    try sweep(ctx.circuit, x_op, freqs, hd2, v1_mag, v2_mag, o, a);

    const names = try a.dupe([]const u8, &.{ "frequency", "hd2", "v1_mag", "v2_mag" });
    const ncols = names.len;
    const data = try a.alloc(f64, n_points * ncols);
    for (0..n_points) |i| {
        const row = data[i * ncols ..][0..ncols];
        row[0] = freqs[i];
        row[1] = hd2[i];
        row[2] = v1_mag[i];
        row[3] = v2_mag[i];
    }

    return .{
        .plotname = "Distortion Analysis",
        .varnames = names,
        .is_complex = false,
        .npoints = n_points,
        .data = data,
    };
}
