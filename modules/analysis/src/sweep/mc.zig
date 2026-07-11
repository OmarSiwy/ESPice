//! Monte Carlo: perturb device parameters through raw ParamRef-style f32
//! pointers, re-solve DC per trial, accumulate probe statistics. One
//! Workspace serves every trial — the pattern is frozen. The RNG is a
//! deterministic std.Random.DefaultPrng seeded from Options.seed.
const std = @import("std");
const root = @import("../root.zig");
const dc = @import("../dc/dc.zig");
const converger = @import("../helper/converger.zig");

// ============================================================================
// Parameter variation specification
// ============================================================================

pub const Distribution = enum {
    uniform,
    gaussian,
};

/// Describes how a single device parameter should be varied.
/// `param_ptr` points to the f32 field in the device Model/Instance struct
/// (take it from a root.ParamRef — batch arrays are stable after
/// compile()). The nominal value is captured at setup; each MC run perturbs it.
pub const ParamVar = struct {
    /// Pointer to the model parameter field to vary.
    param_ptr: *f32,
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

    var prng = std.Random.DefaultPrng.init(options.seed);
    const rng = prng.random();

    const x = try allocator.alloc(f64, ckt.n);
    defer allocator.free(x);

    const ws = try ckt.workspace();
    const nopts = options.dc_options.tol.newtonOpts(options.dc_options.tol.itl2);

    // Track yield counts per spec
    const yield_counts = try allocator.alloc(u32, yield_specs.len);
    defer allocator.free(yield_counts);
    @memset(yield_counts, 0);

    @memset(stats, .{
        .mean = 0,
        .std_dev = 0,
        .min = std.math.inf(f64),
        .max = -std.math.inf(f64),
        .yield_pct = 0,
        .n_converged = 0,
    });

    var n_conv: u32 = 0;
    for (0..options.n_trials) |_| {
        // Perturb parameters
        for (param_vars) |pv| {
            const varied = switch (pv.dist) {
                .uniform => blk: {
                    const lo = pv.nominal * (1.0 - pv.rel_tol);
                    const hi = pv.nominal * (1.0 + pv.rel_tol);
                    break :blk lo + (hi - lo) * rng.float(f64);
                },
                .gaussian => pv.nominal + pv.nominal * pv.rel_tol * rng.floatNorm(f64),
            };
            pv.param_ptr.* = @floatCast(varied);
        }
        ckt.recompute();

        // Re-solve the DC operating point for this trial
        @memset(x, 0);
        const converged = if (converger.run(ckt, ws, x, 0, nopts, converger.EvalHook{})) |r|
            r.converged
        else |_|
            false;

        if (converged) {
            for (probes, 0..) |node, p| {
                const val = x[node];
                samples[p * stride + n_conv] = val;

                // Running min/max
                stats[p].min = @min(stats[p].min, val);
                stats[p].max = @max(stats[p].max, val);
            }

            // Yield checking
            for (yield_specs, yield_counts) |ys, *count| {
                const val = x[probes[ys.probe_idx]];
                if (val >= ys.lo and val <= ys.hi) count.* += 1;
            }

            n_conv += 1;
        }

        // Restore nominal parameters for next iteration's perturbation base
        for (param_vars) |pv| {
            pv.param_ptr.* = @floatCast(pv.nominal);
        }
    }
    ckt.recompute();

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

        // Mean
        var sum: f64 = 0;
        for (vals) |v| sum += v;
        const mean = sum / @as(f64, @floatFromInt(n_conv));
        st.mean = mean;

        // Standard deviation
        var sum_sq: f64 = 0;
        for (vals) |v| {
            const d = v - mean;
            sum_sq += d * d;
        }
        st.std_dev = if (n_conv > 1)
            @sqrt(sum_sq / @as(f64, @floatFromInt(n_conv - 1)))
        else
            0;
    }

    // Yield percentage
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
        if (ref.primary and ref.ptr.* != 0) n_vars += 1;
    }
    const param_vars = try a.alloc(ParamVar, n_vars);
    defer a.free(param_vars);
    var i: usize = 0;
    for (refs) |ref| {
        if (!ref.primary or ref.ptr.* == 0) continue;
        param_vars[i] = .{ .param_ptr = ref.ptr, .nominal = ref.ptr.*, .rel_tol = opts.variation, .dist = .gaussian };
        i += 1;
    }
    defer {
        // analyze() restores on success; this covers early-error paths too.
        for (param_vars) |pv| pv.param_ptr.* = @floatCast(pv.nominal);
        ckt.recompute();
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
        for (names[1..]) |s| a.free(s); // names[0] is the "run" literal
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
