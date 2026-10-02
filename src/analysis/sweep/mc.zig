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

/// Lane k installs deck variant `first + k`, after putting back the
/// parameters the previous lane wrote.
const VariantCtx = struct {
    params: []const root.ParamRef,
    variants: @import("core").Variants,
    first: u32,
    /// The refs the installed lane wrote and their values before it.
    written: []const u32 = &.{},
    saved: []f64,

    pub fn apply(self: *VariantCtx, k: usize) void {
        self.restore();
        const refs, const values = self.variants.writes(self.first + @as(u32, @intCast(k)));
        for (refs, values, self.saved[0..refs.len]) |r, v, *old| {
            old.* = self.params[r].get();
            self.params[r].set(v);
        }
        self.written = refs;
    }

    pub fn restore(self: *VariantCtx) void {
        // Newest first, so a ref written twice ends at its nominal.
        var i = self.written.len;
        while (i > 0) {
            i -= 1;
            self.params[self.written[i]].set(self.saved[i]);
        }
        self.written = &.{};
    }
};

/// Contract entry: real, point-major (run, probes...), one row per converged
/// trial and no rows when there are no probes. Varies each device's primary
/// parameter, skipping those that are zero, or with `opts.variants` solves
/// those deck variants warm-started in order, the first column their axis
/// value. Parameters are back at their nominals afterwards so later jobs see
/// the netlist's circuit.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    if (opts.variants.count != 0) return runVariants(ctx, opts);
    const ckt = ctx.circuit;
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
    try lanes.solveLanes(ckt, &lane_ctx, x_lanes, results, nopts, false);

    return publish(ctx, "Monte Carlo", "run", x_lanes, results, null);
}

fn runVariants(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const ckt = ctx.circuit;
    const scratch = ctx.scratch_allocator;
    const range = opts.variants;
    var widest: usize = 0;
    for (range.first..range.first + range.count) |v| widest = @max(widest, ctx.variants.writes(@intCast(v))[0].len);
    const saved = try scratch.alloc(f64, widest);
    defer scratch.free(saved);
    var lane_ctx: VariantCtx = .{ .params = try ckt.collectParams(), .variants = ctx.variants, .first = range.first, .saved = saved };
    const n: usize = ckt.n;
    const x_lanes = try scratch.alloc(f64, range.count * n);
    defer scratch.free(x_lanes);
    const results = try scratch.alloc(converger.Result, range.count);
    defer scratch.free(results);
    const nopts = converger.optionsFromTolerances(opts.dc_options.tol, opts.dc_options.tol.itl2);
    try lanes.solveLanes(ckt, &lane_ctx, x_lanes, results, nopts, true);
    const axis = ctx.variants.axis[range.first..][0..range.count];
    return publish(ctx, if (opts.dc_plot) "DC transfer characteristic" else "Monte Carlo", opts.axis, x_lanes, results, axis);
}

/// One row per converged lane: its axis value (the converged ordinal when
/// `axis` is null), then the probes.
fn publish(ctx: *const root.RunCtx, plotname: []const u8, first: []const u8, x_lanes: []const f64, results: []const converger.Result, axis: ?[]const f64) !root.Result {
    const a = ctx.allocator;
    const n: usize = ctx.circuit.n;
    var n_conv: usize = 0;
    if (ctx.probes.len > 0) {
        for (results) |r| n_conv += @intFromBool(r.converged);
    }
    const names = try root.probeNames(ctx, first);
    const ncols = names.len;
    const data = try a.alloc(f64, n_conv * ncols);
    if (n_conv > 0) {
        var k: usize = 0;
        for (results, 0..) |r, t| {
            if (!r.converged) continue;
            const row = data[k * ncols ..][0..ncols];
            row[0] = if (axis) |values| values[t] else @floatFromInt(k);
            const xl = x_lanes[t * n ..][0..n];
            for (ctx.probes, row[1..]) |node, *out| out.* = xl[node];
            k += 1;
        }
    }

    return .{
        .plotname = plotname,
        .varnames = names,
        .is_complex = false,
        .npoints = n_conv,
        .data = data,
    };
}
