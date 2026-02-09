//! Monte Carlo: perturb device parameters through raw ParamRef-style f32
//! pointers, re-solve DC per trial, accumulate probe statistics. One trial
//! per structural sweep lane (`lanes.solveLanes`, GPU batch orelse serial) —
//! the pattern is frozen, so one Workspace serves every trial. The RNG is a
//! deterministic std.Random.DefaultPrng seeded from Options.seed; `run` is
//! `analyze` with param_vars collected from the netlist, so there is exactly
//! one numeric path.
const std = @import("std");
const root = @import("../types.zig");
const dc = @import("../dc/dc.zig");
const lanes = @import("lanes.zig");
const converger = @import("solvers").converger;

const W = std.simd.suggestVectorLength(f64) orelse 8;

// ============================================================================
// Parameter variation specification
// ============================================================================

pub const Distribution = enum {
    uniform,
    gaussian,
};

/// Describes how a single device parameter should be varied.
/// `param_ptr` refers to the numeric field in the device Model/Instance struct
/// (take it from a root.ParamRef — batch arrays are stable after
/// compile()). The nominal value is captured at setup; each MC run perturbs it.
pub const ParamVar = struct {
    /// Pointer to the model parameter field to vary.
    param_ptr: root.ParamRef,
    /// Nominal (original) value of the parameter.
    nominal: f64,
    /// Relative tolerance (fraction of nominal). E.g. 0.05 for 5%.
    rel_tol: f64,
    /// Distribution to sample from.
    dist: Distribution,
};

// ============================================================================
// Options
// ============================================================================

pub const Options = struct {
    tol: converger.Tolerances = .{},
    /// Number of Monte Carlo trials.
    n_trials: u16 = 100,
    /// Seed for the PRNG (deterministic).
    seed: u64 = 42,
    /// Relative tolerance applied to every primary instance value in run().
    variation: f64 = 0.05,
    /// DC solver options forwarded to each trial's solve.
    dc_options: dc.Options = .{},
};

// ============================================================================
// Statistics for a single probe
// ============================================================================

pub const Stats = struct {
    mean: f64,
    std_dev: f64,
    min: f64,
    max: f64,
    yield_pct: f64,
    n_converged: u32,
};

// ============================================================================
// Yield specification (optional)
// ============================================================================

pub const YieldSpec = struct {
    probe_idx: u32,
    lo: f64,
    hi: f64,
};

// ============================================================================
// Per-lane parameter draw — the ONE place the distributions are sampled
// ============================================================================

/// solveLanes apply/restore state: the perturbable params, plus a PRNG that
/// reseeds on lane 0 so a GPU→serial fallthrough resamples the same draws.
const LaneCtx = struct {
    param_vars: []const ParamVar,
    seed: u64,
    prng: std.Random.DefaultPrng,

    fn apply(ptr: *anyopaque, k: usize) void {
        const self: *LaneCtx = @ptrCast(@alignCast(ptr));
        if (k == 0) self.prng = std.Random.DefaultPrng.init(self.seed);
        const rng = self.prng.random();
        for (self.param_vars) |pv| {
            const varied = switch (pv.dist) {
                .uniform => blk: {
                    const lo = pv.nominal * (1.0 - pv.rel_tol);
                    const hi = pv.nominal * (1.0 + pv.rel_tol);
                    break :blk lo + (hi - lo) * rng.float(f64);
                },
                .gaussian => pv.nominal + pv.nominal * pv.rel_tol * rng.floatNorm(f64),
            };
            pv.param_ptr.set(varied);
        }
    }

    fn restore(ptr: *anyopaque) void {
        const self: *LaneCtx = @ptrCast(@alignCast(ptr));
        for (self.param_vars) |pv| pv.param_ptr.set(pv.nominal);
    }
};

// ============================================================================
// Monte Carlo analysis entry point
// ============================================================================

/// Caller owns the outputs: samples[probes.len * n_trials], probe-major with
/// stride n_trials — converged trials packed at the front of each probe row
/// (samples[p * n_trials + k], k < n_converged) — and stats[probes.len].
/// Returns the number of converged trials. Parameters are restored to their
/// nominals afterwards.
pub fn analyze(
    ckt: *root.Circuit,
    param_vars: []const ParamVar,
    probes: []const u32,
    samples: []f64,
    stats: []Stats,
    yield_specs: []const YieldSpec,
    options: Options,
    allocator: std.mem.Allocator,
) !u32 {
    const stride: usize = options.n_trials;
    std.debug.assert(samples.len == probes.len * stride);
    std.debug.assert(stats.len == probes.len);

    // Structural sweep lanes: one trial per lane, batched on GPU or serial.
    // The per-lane apply reseeds on lane 0 so a GPU→serial fallthrough resamples
    // identically (see lanes.LaneSetup contract).
    const n: usize = ckt.n;
    const x_lanes = try allocator.alloc(f64, stride * n);
    defer allocator.free(x_lanes);
    const results = try allocator.alloc(converger.Result, stride);
    defer allocator.free(results);

    var lane_ctx: LaneCtx = .{ .param_vars = param_vars, .seed = options.seed, .prng = undefined };
    const setup: lanes.LaneSetup = .{ .ctx = &lane_ctx, .apply = LaneCtx.apply, .restore = LaneCtx.restore };
    const nopts = options.dc_options.tol.newtonOpts(options.dc_options.tol.itl2);
    try lanes.solveLanes(ckt, setup, x_lanes, results, nopts);

    // Track yield counts per spec
    const yield_counts = try allocator.alloc(u32, yield_specs.len);
    defer allocator.free(yield_counts);
    for (yield_counts) |*v| v.* = 0;

    // Initialize stats
    for (stats) |*st| {
        st.* = .{
            .mean = 0,
            .std_dev = 0,
            .min = std.math.inf(f64),
            .max = -std.math.inf(f64),
            .yield_pct = 0,
            .n_converged = 0,
        };
    }

    // Pack converged trials contiguously at the front of each probe row.
    var n_conv: u32 = 0;
    for (results, 0..) |r, t| {
        if (!r.converged) continue;
        const xl = x_lanes[t * n ..][0..n];
        for (probes, 0..) |node, p| {
            const val = xl[node];
            samples[p * stride + n_conv] = val;
            stats[p].min = @min(stats[p].min, val);
            stats[p].max = @max(stats[p].max, val);
        }
        for (yield_specs, yield_counts) |ys, *count| {
            const val = xl[probes[ys.probe_idx]];
            if (val >= ys.lo and val <= ys.hi) count.* += 1;
        }
        n_conv += 1;
    }

    // Compute final statistics
    for (stats, 0..) |*st, p| {
        st.n_converged = n_conv;

        if (n_conv == 0) {
            st.mean = 0;
            st.std_dev = 0;
            st.min = 0;
            st.max = 0;
            continue;
        }

        const vals = samples[p * stride ..][0..n_conv];
        const nc_f: f64 = @floatFromInt(n_conv);

        // Mean — SIMD accumulate
        var sum: f64 = 0;
        {
            const V = @Vector(W, f64);
            var acc: V = @splat(0.0);
            var i: usize = 0;
            while (i + W <= n_conv) : (i += W) {
                const v: V = vals[i..][0..W].*;
                acc += v;
            }
            sum = @reduce(.Add, acc);
            while (i < n_conv) : (i += 1) sum += vals[i];
        }
        const mean = sum / nc_f;
        st.mean = mean;

        // Bessel-corrected standard deviation — SIMD accumulate
        var sum_sq: f64 = 0;
        {
            const V = @Vector(W, f64);
            var acc: V = @splat(0.0);
            const mv: V = @splat(mean);
            var i: usize = 0;
            while (i + W <= n_conv) : (i += W) {
                const v: V = vals[i..][0..W].*;
                const d = v - mv;
                acc += d * d;
            }
            sum_sq = @reduce(.Add, acc);
            while (i < n_conv) : (i += 1) {
                const d = vals[i] - mean;
                sum_sq += d * d;
            }
        }
        st.std_dev = if (n_conv > 1)
            @sqrt(sum_sq / @as(f64, @floatFromInt(n_conv - 1)))
        else
            0;
    }

    // Yield percentage (conditional on convergence)
    for (yield_specs, yield_counts) |ys, count| {
        if (n_conv > 0) {
            stats[ys.probe_idx].yield_pct =
                @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(n_conv)) * 100.0;
        }
    }

    return n_conv;
}

/// Contract entry: gaussian variation on each device's primary instance
/// value (skipping unset zeros), per-trial DC re-solve. Data layout:
/// point-major (run, probes...), one row per converged trial. Parameters are
/// restored so later jobs see the netlist-declared circuit.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;

    // Monte Carlo variables: each device's principal instance value,
    // skipping unset (0) ones.
    const refs = try ckt.collectParams();
    var n_vars: usize = 0;
    for (refs) |ref| {
        if (ref.primary and ref.get() != 0) n_vars += 1;
    }
    const param_vars = try a.alloc(ParamVar, n_vars);
    defer a.free(param_vars);
    var i: usize = 0;
    for (refs) |ref| {
        if (!ref.primary or ref.get() == 0) continue;
        param_vars[i] = .{ .param_ptr = ref, .nominal = ref.get(), .rel_tol = opts.variation, .dist = .gaussian };
        i += 1;
    }
    defer {
        // analyze() restores on success; this covers early-error paths too.
        for (param_vars) |pv| pv.param_ptr.set(pv.nominal);
        ckt.recompute() catch unreachable; // nominals were read from the checked circuit
    }

    const stride: usize = opts.n_trials;
    const samples = try a.alloc(f64, ctx.probes.len * stride);
    defer a.free(samples);
    const stats = try a.alloc(Stats, ctx.probes.len);
    defer a.free(stats);
    const n_conv = try analyze(ckt, param_vars, ctx.probes, samples, stats, &.{}, opts, a);

    const npoints: usize = if (ctx.probes.len > 0) n_conv else 0;
    const names = try root.probeNames(ctx, "run");
    errdefer {
        for (names[1..]) |s| a.free(s);
        a.free(names);
    }
    const ncols = names.len;
    const data = try a.alloc(f64, npoints * ncols);
    for (0..npoints) |k| {
        const row = data[k * ncols ..][0..ncols];
        row[0] = @floatFromInt(k);
        for (0..ctx.probes.len) |p| row[1 + p] = samples[p * stride + k];
    }

    return .{
        .plotname = "Monte Carlo",
        .varnames = names,
        .is_complex = false,
        .npoints = npoints,
        .data = data,
    };
}
