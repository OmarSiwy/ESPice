//! Monte Carlo (`.mc`): gaussian variation of every device's primary
//! parameter, one cold DC solve per trial. Each trial is a structural sweep
//! lane (`lanes.solveLanes`) sharing one Newton workspace. Each draw is
//! keyed by (Options.seed, trial, variable), so a run is reproducible and
//! any trial can be computed alone. With `Options.variants` the lanes are
//! deck variants instead, each warm from the nominal OP.
//! Cites dev/analysis/ensemble-sweeps.md and dev/analysis/variants.md.
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
const LaneCtx = struct {
    param_vars: []const ParamVar,
    variation: f64,
    seed: u64,

    pub fn apply(self: *LaneCtx, k: usize) void {
        for (self.param_vars, 0..) |pv, v| pv.ref.set(pv.nominal + pv.nominal * self.variation * draw(self.seed, k, v));
    }

    pub fn restore(self: *LaneCtx) void {
        for (self.param_vars) |pv| pv.ref.set(pv.nominal);
    }
};

/// N(0,1) for variable `variable` of trial `trial`: a counter-based draw,
/// a fresh generator seeded by the hash of the three, so it depends on no
/// other draw.
pub fn draw(seed: u64, trial: usize, variable: usize) f64 {
    const key = [2]u64{ trial, variable };
    var prng = std.Random.DefaultPrng.init(std.hash.Wyhash.hash(seed, std.mem.asBytes(&key)));
    return prng.random().floatNorm(f64);
}

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
/// those deck variants, each warm-started from the nominal OP (`ctx.x_op`),
/// the first column their axis value. With `opts.lane` only that trial or
/// variant runs (a row the session split off), its run column 0.
/// Parameters are back at their nominals afterwards so later jobs see the
/// netlist's circuit.
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

    var lane_ctx: LaneCtx = .{ .param_vars = param_vars, .variation = opts.variation, .seed = opts.seed };
    return solve(ctx, opts, &lane_ctx, .of(opts.lane, opts.n_trials), null, "Monte Carlo", "run", null);
}

fn runVariants(ctx: *const root.RunCtx, opts: Options) !root.Result {
    const scratch = ctx.scratch_allocator;
    const range = opts.variants;
    var widest: usize = 0;
    for (range.first..range.first + range.count) |v| widest = @max(widest, ctx.variants.writes(@intCast(v))[0].len);
    const saved = try scratch.alloc(f64, widest);
    defer scratch.free(saved);
    var lane_ctx: VariantCtx = .{ .params = try ctx.circuit.collectParams(), .variants = ctx.variants, .first = range.first, .saved = saved };
    const axis = ctx.variants.axis[range.first..][0..range.count];
    return solve(ctx, opts, &lane_ctx, .of(opts.lane, range.count), ctx.x_op, if (opts.dc_plot) "DC transfer characteristic" else "Monte Carlo", opts.axis, axis);
}

/// Solves `lanes` and publishes one row per converged lane: its axis value
/// (the converged ordinal when `axis` is null), then the probes.
fn solve(ctx: *const root.RunCtx, opts: Options, setup: anytype, range: lanes.Range, warm: ?[]const f64, plotname: []const u8, first: []const u8, axis: ?[]const f64) !root.Result {
    const scratch = ctx.scratch_allocator;
    const np = ctx.probes.len;
    const probe_rows = try scratch.alloc(f64, range.count * np);
    defer scratch.free(probe_rows);
    const results = try scratch.alloc(converger.Result, range.count);
    defer scratch.free(results);
    const nopts = converger.optionsFromTolerances(opts.dc_options.tol, opts.dc_options.tol.itl2);
    try lanes.solveLanes(ctx.circuit, setup, range.first, ctx.probes, probe_rows, results, nopts, warm, scratch);

    var n_conv: usize = 0;
    if (np > 0) {
        for (results) |r| n_conv += @intFromBool(r.converged);
    }
    const names = try root.probeNames(ctx, first);
    const ncols = names.len;
    const data = try ctx.allocator.alloc(f64, n_conv * ncols);
    if (n_conv > 0) {
        var k: usize = 0;
        for (results, 0..) |r, t| {
            if (!r.converged) continue;
            const row = data[k * ncols ..][0..ncols];
            row[0] = if (axis) |values| values[range.first + t] else @floatFromInt(k);
            @memcpy(row[1..], probe_rows[t * np ..][0..np]);
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
