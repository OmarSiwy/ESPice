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

/// The lanes' installer: random trials, or deck variants.
pub const Setup = union(enum) {
    trials: LaneCtx,
    variants: VariantCtx,

    pub fn apply(self: *Setup, k: usize) void {
        switch (self.*) {
            inline else => |*s| s.apply(k),
        }
    }

    pub fn restore(self: *Setup) void {
        switch (self.*) {
            inline else => |*s| s.restore(),
        }
    }

    pub fn deinit(self: *Setup, scratch: std.mem.Allocator) void {
        switch (self.*) {
            .trials => |s| scratch.free(s.param_vars),
            .variants => |s| scratch.free(s.saved),
        }
    }
};

/// The installer for `ctx`'s circuit: each device's nonzero primary
/// parameter at its nominal, or the variants' widest write's save slots.
pub fn setup(ctx: *const root.RunCtx, opts: Options) !Setup {
    const scratch = ctx.scratch_allocator;
    const refs = try ctx.circuit.collectParams();
    if (opts.variants.count != 0) {
        const rows = opts.variants;
        var widest: usize = 0;
        for (rows.first..rows.first + rows.count) |v| widest = @max(widest, ctx.variants.writes(@intCast(v))[0].len);
        return .{ .variants = .{ .params = refs, .variants = ctx.variants, .first = rows.first, .saved = try scratch.alloc(f64, widest) } };
    }
    var n_vars: usize = 0;
    for (refs) |ref| n_vars += @intFromBool(ref.primary and ref.get() != 0);
    const param_vars = try scratch.alloc(ParamVar, n_vars);
    var i: usize = 0;
    for (refs) |ref| {
        if (!ref.primary or ref.get() == 0) continue;
        param_vars[i] = .{ .ref = ref, .nominal = ref.get() };
        i += 1;
    }
    return .{ .trials = .{ .param_vars = param_vars, .variation = opts.variation, .seed = opts.seed } };
}

/// The trials or variants `opts` solves.
pub fn range(opts: Options) lanes.Range {
    return .of(opts.lane, if (opts.variants.count != 0) opts.variants.count else opts.n_trials);
}

/// Variants warm-start from the nominal OP; trials start cold.
pub fn warm(ctx: *const root.RunCtx, opts: Options) ?[]const f64 {
    return if (opts.variants.count != 0) ctx.x_op else null;
}

/// Contract entry: real, point-major (run, probes...), one row per converged
/// trial and no rows when there are no probes. Varies each device's primary
/// parameter, skipping those that are zero, or with `opts.variants` solves
/// those deck variants, each warm-started from the nominal OP (`ctx.x_op`),
/// the first column their axis value. With `opts.lane` only that trial or
/// variant runs (a row the session split off), its run column 0.
/// Parameters are back at their nominals afterwards so later jobs see the
/// netlist's circuit.
pub fn run(ctx: *const root.RunCtx, opts: Options) !root.Result {
    return lanes.run(@This(), ctx, opts);
}

/// One row per converged lane of those from `first` (`rows` holds each
/// lane's probe values): its axis value, the variant's or the converged
/// ordinal, then the probes.
pub fn publish(ctx: *const root.RunCtx, opts: Options, first: usize, probe_rows: []const f64, results: []const converger.Result) !root.Result {
    const np = ctx.probes.len;
    var n_conv: usize = 0;
    if (np > 0) {
        for (results) |r| n_conv += @intFromBool(r.converged);
    }
    const variants = opts.variants.count != 0;
    const names = try root.probeNames(ctx, if (variants) opts.axis else "run");
    const ncols = names.len;
    const data = try ctx.allocator.alloc(f64, n_conv * ncols);
    if (n_conv > 0) {
        var k: usize = 0;
        for (results, 0..) |r, t| {
            if (!r.converged) continue;
            const row = data[k * ncols ..][0..ncols];
            row[0] = if (variants) ctx.variants.axis[opts.variants.first + first + t] else @floatFromInt(k);
            @memcpy(row[1..], probe_rows[t * np ..][0..np]);
            k += 1;
        }
    }

    return .{
        .plotname = if (variants and opts.dc_plot) "DC transfer characteristic" else "Monte Carlo",
        .varnames = names,
        .is_complex = false,
        .npoints = n_conv,
        .data = data,
    };
}
