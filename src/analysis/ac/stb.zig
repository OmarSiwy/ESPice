//! Loop-gain stability (STB): drive the deck's own 0 V probe source with a
//! unit injection on its branch row and sweep T(ω) = −V(+)/V(−).
const std = @import("std");
const batch = @import("batch.zig");
const root = @import("../types.zig");
const types = @import("numerics");
const solvers = @import("solvers");
const GROUND = root.GROUND;
const FreqSolver = solvers.freq_solve.FreqSolver;

const Complex = types.Complex;

pub const Options = @import("requests").Stb;

pub const SolveResult = struct {
    freqs: []f64,
    loop_gain: []Complex,
    n_points: u32,

    pub fn init(allocator: std.mem.Allocator, n_points: u32) !SolveResult {
        const freqs = try allocator.alloc(f64, n_points);
        errdefer allocator.free(freqs);
        return .{
            .freqs = freqs,
            .loop_gain = try allocator.alloc(Complex, n_points),
            .n_points = n_points,
        };
    }

    pub fn deinit(self: *SolveResult, allocator: std.mem.Allocator) void {
        allocator.free(self.freqs);
        allocator.free(self.loop_gain);
    }
};

/// Low-level solve: linearize at `x_op`, inject at the probe, sweep T(ω).
///
/// The probe is the deck's own 0 V source (`.stb Vprobe ...`), NOT a source
/// this module adds: its branch equation is already `v_p - v_n - V = 0`, so
/// driving `rhs[branch] = 1` turns it into the 1 V loop injection and leaves
/// every other stamp alone. Augmenting to (n+1)² instead put a second 0 V
/// source across the same node pair as the deck's — two contradictory
/// constraints on one pair, and the factorization had nothing to say.
///
/// Return ratio, ngspice's orientation: the probe's `+` node is where the
/// signal ARRIVES (the driven side of the break) and `−` is where it leaves
/// into the rest of the loop, so `T = −V(+)/V(−)`.
pub fn solve(
    ckt: *root.Circuit,
    options: Options,
    x_op: []const f64,
    allocator: std.mem.Allocator,
) !SolveResult {
    const n: usize = ckt.n;
    if (options.probe_branch >= n or options.probe_p >= n or options.probe_n >= n)
        return error.InvalidProbe;
    // A probe whose `−` side is ground has no returned voltage to divide by.
    if (options.probe_n == GROUND) return error.InvalidProbe;

    // --- Linearize at the operating point ------------------------------------
    try ckt.linearizeAc(x_op);

    // --- Frequency sweep ------------------------------------------------------
    // Independent (G+jωC)x = e_branch solves: lane axis = frequency. GPU batch
    // dispatch orelse the CPU lane solveBatch.
    const nn = 2 * n;
    const n_points = options.sweep.count();

    var fs = try FreqSolver.fromCircuit(allocator, ckt, x_op);
    defer fs.deinit(allocator);

    var result = try SolveResult.init(allocator, n_points);
    errdefer result.deinit(allocator);

    const omegas = try allocator.alloc(f64, n_points);
    defer allocator.free(omegas);
    options.sweep.fill(result.freqs, omegas);

    // One shared rhs: the 1 V injection on the probe's own branch row.
    const rhs = try allocator.alloc(f64, nn);
    defer allocator.free(rhs);
    root.zeroSimd(rhs);
    rhs[options.probe_branch] = 1.0;

    const x_out = try batch.solve(ckt, &fs, allocator, omegas, rhs, false);
    defer allocator.free(x_out);

    for (0..n_points) |k| {
        const lane = x_out[k * nn ..][0..nn];
        const v_p: Complex = .{ .re = lane[options.probe_p], .im = lane[n + options.probe_p] };
        const v_n: Complex = .{ .re = lane[options.probe_n], .im = lane[n + options.probe_n] };
        result.loop_gain[k] = v_p.div(v_n).scale(-1);
    }

    return result;
}

/// Contract entry: sweep the loop gain with the probe at
/// (opts.probe_p orelse ctx.source_node, opts.probe_n). Point-major
/// complex data: (frequency, loop_gain) per row.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const a = ctx.allocator;
    // `res` is deinit-ed here, so it is scratch, and `a` is a results arena
    // whose free() is a no-op. See RunCtx.scratch_allocator.
    const scratch = ctx.scratch_allocator;
    var res = try solve(ctx.circuit, opts, ctx.x_op, scratch);
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
