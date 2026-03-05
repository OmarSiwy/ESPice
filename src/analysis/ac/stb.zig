//! Loop-gain stability (STB): augment the dense linearized G/C with a 0 V
//! probe source between probe_p and probe_n to form (n+1)², then sweep.
//! T(ω) = −i_br(ω). Phase unwrap mandatory for gain-margin extraction.
const std = @import("std");
const batch = @import("batch.zig");
const root = @import("../types.zig");
const converger = @import("solvers").converger;
const types = @import("solvers").types;
const solvers = @import("solvers");
const GROUND = root.GROUND;
const FreqSolver = solvers.freq_solve.FreqSolver;
const dc = @import("../dc/dc.zig");

const Complex = types.Complex;

pub const Options = @import("requests").Stb;

pub const SolveResult = struct {
    freqs: []f64,
    loop_gain: []Complex,
    n_points: u32,
    gain_margin_db: f64,
    phase_margin_deg: f64,

    pub fn init(allocator: std.mem.Allocator, n_points: u32) !SolveResult {
        const freqs = try allocator.alloc(f64, n_points);
        errdefer allocator.free(freqs);
        return .{
            .freqs = freqs,
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

/// Low-level solve: DC bias → linearize → augment → sweep → margins.
/// `x_op_in` reuses an operating point the engine already solved; pass null
/// (standalone callers) to run the DC solve here.
pub fn solve(
    ckt: *root.Circuit,
    probe_p: u32,
    probe_n: u32,
    options: Options,
    x_op_in: ?[]const f64,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    const n_aug = n + 1;
    const branch_idx = n;

    // --- Bias point: reuse the engine's op if given, else DC solve here ------
    var owned_x_op: ?[]f64 = null;
    defer if (owned_x_op) |x| allocator.free(x);
    // run() always passes ctx.x_op (engine.ensureOp guarantees it); this
    // fallback fires only for standalone/direct solve() callers.
    const x_op = x_op_in orelse blk: {
        const x = try allocator.alloc(f64, n);
        owned_x_op = x;
        const dc_result = try dc.solve(ckt, x, .{ .tol = options.tol });
        if (!dc_result.converged) return error.DcNotConverged;
        break :blk x;
    };

    // --- Linearize at the operating point ------------------------------------
    try ckt.linearizeAc(x_op);

    // --- Augment to (n+1)² with probe branch ---------------------------------
    // FreqSolver.initDense takes ownership of both arrays.
    const g_aug = try allocator.alloc(f64, n_aug * n_aug);
    const c_aug = allocator.alloc(f64, n_aug * n_aug) catch |err| {
        allocator.free(g_aug);
        return err;
    };
    root.zeroSimd(g_aug);
    root.zeroSimd(c_aug);

    for (0..n) |col| {
        for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |slot| {
            const dst = @as(usize, ckt.row_idx[slot]) * n_aug + col;
            g_aug[dst] = ckt.g_vals[slot];
            c_aug[dst] = ckt.c_vals[slot];
        }
    }

    // Stamp 0 V probe source: ±1 couplings, zero diagonal.
    if (probe_p != GROUND) {
        g_aug[probe_p * n_aug + branch_idx] += 1.0;
        g_aug[branch_idx * n_aug + probe_p] += 1.0;
    }
    if (probe_n != GROUND) {
        g_aug[probe_n * n_aug + branch_idx] -= 1.0;
        g_aug[branch_idx * n_aug + probe_n] -= 1.0;
    }

    // --- Frequency sweep ------------------------------------------------------
    // All freq points are independent (G+jωC)x=rhs solves over one shared rhs
    // (unit voltage on the probe branch): lane axis = frequency. GPU batch
    // dispatch orelse the CPU lane solveBatch (dense strategy peels to the
    // per-omega serial ladder inside solveBatch — same numeric path).
    const n_points = types.logSweepCount(options.f_start, options.f_stop, options.points_per_decade);
    const nn = 2 * n_aug;

    // FreqSolver.initDense takes ownership of g_aug, c_aug; gpuFreqBatch only
    // borrows them (read-only) so fs owning them is fine for both paths.
    var fs = try FreqSolver.initDense(allocator, @intCast(n_aug), g_aug, c_aug);
    defer fs.deinit(allocator);

    var result = try SolveResult.init(allocator, n_points);
    errdefer result.deinit(allocator);

    const omegas = try allocator.alloc(f64, n_points);
    defer allocator.free(omegas);
    types.fillLogSweep(options.f_start, options.f_stop, options.points_per_decade, result.freqs, omegas);

    // One shared rhs: unit excitation on the probe branch (stacked-real 2n).
    const rhs = try allocator.alloc(f64, nn);
    defer allocator.free(rhs);
    root.zeroSimd(rhs);
    rhs[branch_idx] = 1.0;

    const x_out = try batch.solve(ckt, &fs, allocator, g_aug, c_aug, omegas, rhs, false);
    defer allocator.free(x_out);

    for (0..n_points) |k| {
        // T(f) = −(x_re[branch] + j·x_im[branch])
        result.loop_gain[k] = .{
            .re = -x_out[k * nn + branch_idx],
            .im = -x_out[k * nn + n_aug + branch_idx],
        };
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

    // `res` is deinit-ed here, so it is scratch, and `a` is a results arena
    // whose free() is a no-op. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator orelse a;
    var res = try solve(ctx.circuit, probe_p, opts.probe_n, opts, ctx.x_op, scratch);
    defer res.deinit(scratch);

    const names = try a.dupe([]const u8, &.{ "frequency", "loop_gain" });
    errdefer a.free(names); // entries are literals
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

// ============================================================================
// Margin extraction
// ============================================================================

/// Phase margin: interpolated phase at the first 0 dB down-crossing of |T|.
/// Gain margin: interpolated magnitude at the −180° crossing of the unwrapped
/// phase. NaN when the crossing doesn't exist in-band.
fn computeMargins(result: *SolveResult) void {
    const n: usize = result.n_points;
    if (n < 2) return;

    // --- Phase margin: find |T| = 0 dB crossing -----------------------------
    // Prefer first strict down-crossing (gain going below 0 dB).
    var pm_found = false;
    for (1..n) |k| {
        const db_prev = result.loop_gain[k - 1].magDb();
        const db_curr = result.loop_gain[k].magDb();

        if (db_prev >= 0 and db_curr < 0) {
            const frac = db_prev / (db_prev - db_curr);
            const phase_prev = result.loop_gain[k - 1].phaseDeg();
            const phase_curr = result.loop_gain[k].phaseDeg();
            result.phase_margin_deg = 180.0 + phase_prev + frac * (phase_curr - phase_prev);
            pm_found = true;
            break;
        }
    }

    // Fallback: any crossing direction.
    if (!pm_found) {
        for (1..n) |k| {
            const db_prev = result.loop_gain[k - 1].magDb();
            const db_curr = result.loop_gain[k].magDb();

            if ((db_prev >= 0 and db_curr < 0) or (db_prev < 0 and db_curr >= 0)) {
                const frac = @abs(db_prev) / (@abs(db_prev) + @abs(db_curr));
                const phase_prev = result.loop_gain[k - 1].phaseDeg();
                const phase_curr = result.loop_gain[k].phaseDeg();
                result.phase_margin_deg = 180.0 + phase_prev + frac * (phase_curr - phase_prev);
                break;
            }
        }
    }

    // --- Gain margin: unwrapped phase, find −180° crossing -------------------
    // atan2 wraps to (−180°, 180°] so a raw comparison misses the −180°
    // crossing; unwrap the phase sequence first.
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
            const db_prev = result.loop_gain[k - 1].magDb();
            const db_curr = result.loop_gain[k].magDb();
            result.gain_margin_db = -(db_prev + frac * (db_curr - db_prev));
            break;
        }
    }
}

// Private implementation access for the analysis test suite.
pub const test_access = if (@import("builtin").is_test) .{
    .computeMargins = computeMargins,
} else {};
