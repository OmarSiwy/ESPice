//! Monte Carlo (`.mc`): gaussian variation of every device's primary
//! parameter, one cold DC solve per trial. Each trial is a structural sweep
//! lane (`lanes.solveLanes`) sharing one Newton workspace. The draws come
//! from a std.Random.DefaultPrng seeded with Options.seed, so a run is
//! reproducible.
const std = @import("std");
const root = @import("../types.zig");
const lanes = @import("lanes.zig");
const converger = @import("solver").converger;

/// Query options, defined in core/query.zig.
pub const Options = @import("core").query.Mc;

/// One varied parameter and the nominal value its trials perturb.
const ParamVar = struct {
    ref: root.ParamRef,
    nominal: f64,
};

/// Trial k draws `nominal · (1 + variation · N(0,1))` for every parameter.
/// The PRNG reseeds on trial 0, so every sweep draws the same sequence.
const LaneCtx = struct {
    param_vars: []const ParamVar,
    variation: f64,
    seed: u64,
    prng: std.Random.DefaultPrng,

    pub fn apply(self: *LaneCtx, k: usize) void {
        if (k == 0) self.prng = std.Random.DefaultPrng.init(self.seed);
        const rng = self.prng.random();
        for (self.param_vars) |pv| pv.ref.set(pv.nominal + pv.nominal * self.variation * rng.floatNorm(f64));
    }

    pub fn restore(self: *LaneCtx) void {
        for (self.param_vars) |pv| pv.ref.set(pv.nominal);
    }
};

/// Contract entry: real, point-major (run, probes...), one row per converged
/// trial and no rows when there are no probes. Varies each device's primary
/// parameter, skipping those that are zero. Parameters are back at their
/// nominals afterwards so later jobs see the netlist's circuit.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const a = ctx.allocator;
    const scratch = ctx.scratch_allocator;

    const refs = try ckt.collectParams();
    var n_vars: usize = 0;
    for (refs) |ref| n_vars += @intFromBool(ref.primary and ref.get() != 0);
    const param_vars = try scratch.alloc(ParamVar, n_vars);
    defer scratch.free(param_vars);
    var i: usize = 0;
    for (refs) |ref| {
        if (!ref.primary or ref.get() == 0) continue;
        param_vars[i] = .{ .ref = ref, .nominal = ref.get() };
        i += 1;
    }

    const n: usize = ckt.n;
    const n_trials: usize = opts.n_trials;
    const x_lanes = try scratch.alloc(f64, n_trials * n);
    defer scratch.free(x_lanes);
    const results = try scratch.alloc(converger.Result, n_trials);
    defer scratch.free(results);

    var lane_ctx: LaneCtx = .{ .param_vars = param_vars, .variation = opts.variation, .seed = opts.seed, .prng = undefined };
    const nopts = converger.optionsFromTolerances(opts.dc_options.tol, opts.dc_options.tol.itl2);
    try lanes.solveLanes(ckt, &lane_ctx, x_lanes, results, nopts);

    var n_conv: usize = 0;
    if (ctx.probes.len > 0) {
        for (results) |r| n_conv += @intFromBool(r.converged);
    }
    const names = try root.probeNames(ctx, "run");
    errdefer {
        for (names[1..]) |s| a.free(s);
        a.free(names);
    }
    const ncols = names.len;
    const data = try a.alloc(f64, n_conv * ncols);
    if (n_conv > 0) {
        var k: usize = 0;
        for (results, 0..) |r, t| {
            if (!r.converged) continue;
            const row = data[k * ncols ..][0..ncols];
            row[0] = @floatFromInt(k);
            const xl = x_lanes[t * n ..][0..n];
            for (ctx.probes, row[1..]) |node, *out| out.* = xl[node];
            k += 1;
        }
    }

    return .{
        .plotname = "Monte Carlo",
        .varnames = names,
        .is_complex = false,
        .npoints = n_conv,
        .data = data,
    };
}
