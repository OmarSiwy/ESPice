//! Loop-gain stability (Tian probe row): augment the dense linearized G/C
//! into (n+1)² with a 0V probe source between probe_p and probe_n, then
//! sweep. The planes are the linearization — one eval() at the op.
const std = @import("std");
const root = @import("root.zig");
const GROUND = root.GROUND;
const FreqSolver = root.solvers.freq_solve.FreqSolver;
const freq = @import("freq.zig");
const dc = @import("dc.zig");

const Complex = freq.Complex;

pub const Options = struct {
    f_start: f64,
    f_stop: f64,
    points_per_decade: u16 = 10,
    dc_max_iter: u16 = 100,
    dc_abstol: f64 = 1e-12,
    /// Probe insertion nodes; probe_p null → ctx.source_node.
    probe_p: ?u32 = null,
    probe_n: u32 = GROUND,
};

pub const SolveResult = struct {
    freqs: []f64,
    loop_gain: []Complex,
    n_points: u32,
    gain_margin_db: f64,
    phase_margin_deg: f64,

    pub fn init(allocator: std.mem.Allocator, n_points: u32) !SolveResult {
        return .{
            .freqs = try allocator.alloc(f64, n_points),
            .loop_gain = try allocator.alloc(Complex, n_points),
            .n_points = n_points,
            .gain_margin_db = std.math.nan(f64),
            .phase_margin_deg = std.math.nan(f64),
        };
    }

    pub fn deinit(self: *SolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.freqs);
        allocator.free(self.loop_gain);
    }
};

pub fn solve(
    ckt: *root.Circuit,
    probe_p: u32,
    probe_n: u32,
    options: Options,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const n_aug = n + 1;
    const branch_idx = n;

    const x_op = try allocator.alloc(f64, n);
    defer allocator.free(x_op);
    const dc_result = try dc.solve(ckt, x_op, .{
        .max_iter = options.dc_max_iter,
        .abstol = options.dc_abstol,
    }, allocator);
    if (!dc_result.converged) return error.DcNotConverged;

    // Linearize at the op: one eval, the planes are G and C (ground row included).
    ckt.eval(x_op, 0);
    const lin = try allocator.alloc(f64, 2 * n * n);
    defer allocator.free(lin);
    const g_lin = lin[0 .. n * n];
    const c_lin = lin[n * n ..];
    ckt.denseG(g_lin);
    ckt.denseC(c_lin);

    // Augment with the probe branch row/column. FreqSolver.initDense takes
    // ownership of both matrices (frees them on its own failure too).
    const g_aug = try allocator.alloc(f64, n_aug * n_aug);
    const c_aug = allocator.alloc(f64, n_aug * n_aug) catch |err| {
        allocator.free(g_aug);
        return err;
    };
    @memset(g_aug, 0);
    @memset(c_aug, 0);

    for (0..n) |row| {
        for (0..n) |col| {
            g_aug[row * n_aug + col] = g_lin[row * n + col];
            c_aug[row * n_aug + col] = c_lin[row * n + col];
        }
    }

    if (probe_p != GROUND) g_aug[probe_p * n_aug + branch_idx] += 1.0;
    if (probe_n != GROUND) g_aug[probe_n * n_aug + branch_idx] -= 1.0;
    if (probe_p != GROUND) g_aug[branch_idx * n_aug + probe_p] += 1.0;
    if (probe_n != GROUND) g_aug[branch_idx * n_aug + probe_n] -= 1.0;

    var fs = try FreqSolver.initDense(allocator, @intCast(n_aug), g_aug, c_aug);
    defer fs.deinit(allocator);

    const nn = 2 * n_aug;
    const work = try allocator.alloc(f64, 2 * nn);
    defer allocator.free(work);
    const rhs = work[0..nn];
    const x_work = work[nn..];

    @memset(rhs, 0);
    rhs[branch_idx] = 1.0;

    const n_points = freq.logSweepCount(options.f_start, options.f_stop, options.points_per_decade);
    var result = try SolveResult.init(allocator, n_points);
    errdefer result.deinit(allocator);

    for (0..n_points) |k| {
        const f = freq.logSweepFreq(options.f_start, options.f_stop, n_points, @intCast(k));
        try fs.solve(2.0 * std.math.pi * f, rhs, x_work);

        result.freqs[k] = f;
        result.loop_gain[k] = .{ .re = -x_work[branch_idx], .im = -x_work[n_aug + branch_idx] };
    }

    computeMargins(&result);
    return result;
}

/// Contract entry: sweep the loop gain with the probe at
/// (opts.probe_p orelse ctx.source_node, opts.probe_n). Point-major
/// complex data: (frequency, loop_gain) per row.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    const probe_p = opts.probe_p orelse ctx.source_node;

    var res = try solve(ctx.circuit, probe_p, opts.probe_n, opts, a);
    defer res.deinit(a);

    const names = try a.dupe([]const u8, &.{ "frequency", "loop_gain" });
    const data = try a.alloc(f64, res.n_points * 4);
    for (0..res.n_points) |i| {
        data[i * 4] = res.freqs[i];
        data[i * 4 + 1] = 0;
        data[i * 4 + 2] = res.loop_gain[i].re;
        data[i * 4 + 3] = res.loop_gain[i].im;
    }
    return .{
        .plotname = "Stability Analysis",
        .varnames = names,
        .is_complex = true,
        .npoints = res.n_points,
        .data = data,
    };
}

fn computeMargins(result: *SolveResult) void {
    const n: usize = result.n_points;
    if (n < 2) return;

    var pm_found = false;
    for (1..n) |k| {
        const db_prev = 20.0 * @log10(result.loop_gain[k - 1].mag());
        const db_curr = 20.0 * @log10(result.loop_gain[k].mag());

        if (db_prev >= 0 and db_curr < 0) {
            const frac = db_prev / (db_prev - db_curr);
            const phase_prev = result.loop_gain[k - 1].phaseDeg();
            const phase_curr = result.loop_gain[k].phaseDeg();
            result.phase_margin_deg = 180.0 + phase_prev + frac * (phase_curr - phase_prev);
            pm_found = true;
            break;
        }
    }

    if (!pm_found) {
        for (1..n) |k| {
            const db_prev = 20.0 * @log10(result.loop_gain[k - 1].mag());
            const db_curr = 20.0 * @log10(result.loop_gain[k].mag());

            if ((db_prev >= 0 and db_curr < 0) or (db_prev < 0 and db_curr >= 0)) {
                const frac = @abs(db_prev) / (@abs(db_prev) + @abs(db_curr));
                const phase_prev = result.loop_gain[k - 1].phaseDeg();
                const phase_curr = result.loop_gain[k].phaseDeg();
                result.phase_margin_deg = 180.0 + phase_prev + frac * (phase_curr - phase_prev);
                break;
            }
        }
    }

    // Gain margin: atan2 phase wraps to (-180, 180], so a raw comparison can
    // never see the -180 crossing — unwrap the phase and scan the continuous
    // sequence instead.
    var phase_uw = result.loop_gain[0].phaseDeg();
    for (1..n) |k| {
        const phase_prev = phase_uw;
        var delta = result.loop_gain[k].phaseDeg() - result.loop_gain[k - 1].phaseDeg();
        if (delta > 180.0) delta -= 360.0;
        if (delta < -180.0) delta += 360.0;
        phase_uw += delta;
        const phase_curr = phase_uw;

        if ((phase_prev >= -180.0 and phase_curr < -180.0) or
            (phase_prev < -180.0 and phase_curr >= -180.0))
        {
            const frac = @abs(phase_prev + 180.0) / (@abs(phase_prev + 180.0) + @abs(phase_curr + 180.0));
            const db_prev = 20.0 * @log10(result.loop_gain[k - 1].mag());
            const db_curr = 20.0 * @log10(result.loop_gain[k].mag());
            result.gain_margin_db = -(db_prev + frac * (db_curr - db_prev));
            break;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
test "STB: margin computation with synthetic data" {
    const allocator = testing.allocator;

    const k_gain: f64 = 10.0;
    const f0: f64 = 1000.0;
    const n_pts: u32 = 200;

    var result = try SolveResult.init(allocator, n_pts);
    defer result.deinit(allocator);

    for (0..n_pts) |idx| {
        const frac = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n_pts - 1));
        const f = std.math.pow(f64, 10.0, frac * 6.0);
        const ratio = f / f0;
        const denom = @sqrt(1.0 + ratio * ratio);
        const m = k_gain / denom;
        const phase_rad = -std.math.atan(ratio);

        result.freqs[idx] = f;
        result.loop_gain[idx] = .{ .re = m * @cos(phase_rad), .im = m * @sin(phase_rad) };
    }

    computeMargins(&result);

    try testing.expect(!std.math.isNan(result.phase_margin_deg));
    try testing.expectApproxEqAbs(95.7, result.phase_margin_deg, 2.0);
    try testing.expect(std.math.isNan(result.gain_margin_db));
}

test "STB: three-pole margin computation" {
    // Two poles only approach -180 deg asymptotically and never cross it
    // (gain margin is then rightly NaN); three poles give a real crossing.
    const allocator = testing.allocator;

    const k_gain: f64 = 100.0;
    const f1: f64 = 100.0;
    const f2: f64 = 1000.0;
    const f3: f64 = 10000.0;
    const n_pts: u32 = 500;

    var result = try SolveResult.init(allocator, n_pts);
    defer result.deinit(allocator);

    for (0..n_pts) |idx| {
        const frac = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n_pts - 1));
        const f = std.math.pow(f64, 10.0, frac * 7.0);
        const r1 = f / f1;
        const r2 = f / f2;
        const r3 = f / f3;
        const m = k_gain / (@sqrt(1.0 + r1 * r1) * @sqrt(1.0 + r2 * r2) * @sqrt(1.0 + r3 * r3));
        const phase_rad = -std.math.atan(r1) - std.math.atan(r2) - std.math.atan(r3);

        result.freqs[idx] = f;
        result.loop_gain[idx] = .{ .re = m * @cos(phase_rad), .im = m * @sin(phase_rad) };
    }

    computeMargins(&result);

    try testing.expect(!std.math.isNan(result.phase_margin_deg));
    try testing.expect(result.phase_margin_deg > 0);
    try testing.expect(result.phase_margin_deg < 180.0);
    try testing.expect(!std.math.isNan(result.gain_margin_db));
    try testing.expect(result.gain_margin_db > 0);
}
