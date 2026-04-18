//! Query validation at the analysis boundary: every numeric option a driver
//! would otherwise trust, checked once before any allocation.
const std = @import("std");
const requests = @import("core").query;
const Deck = @import("core").Deck;

fn finite(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .float => std.math.isFinite(value),
        .@"struct" => |s| blk: {
            inline for (s.fields) |field| {
                const v = @field(value, field.name);
                if (comptime std.mem.eql(u8, field.name, "dx_clamp")) {
                    if (std.math.isNan(v) or v <= 0) break :blk false;
                } else if (!finite(v)) break :blk false;
            }
            break :blk true;
        },
        .optional => if (value) |v| finite(v) else true,
        .pointer => |p| blk: {
            if (p.size == .slice) for (value) |v| if (!finite(v)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}

fn sweep(start: f64, stop: f64, step: f64) !usize {
    const intervals = (stop - start) / step;
    if (step == 0 or intervals < 0) return error.InvalidQueryOptions;
    const count = @floor(intervals + 1e-6) + 1;
    if (!std.math.isFinite(count) or count >= @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return error.InvalidQueryOptions;
    // Repeated-addition sweeps must make representable progress at both ends.
    if (start != stop and (start + step == start or stop + step == stop)) return error.InvalidQueryOptions;
    return @intFromFloat(count);
}

fn positive(value: f64) !void {
    if (!std.math.isFinite(value) or value <= 0) return error.InvalidQueryOptions;
}

fn timeStep(value: f64) !void {
    try positive(value);
    // Trapezoidal companion stamps use 2/dt.
    try positive(2 / value);
}

fn frequency(value: f64) !void {
    try timeStep(1 / value);
    try positive(2 * std.math.pi * value);
}

// Bound derived slabs before entering algorithms with unchecked arithmetic.
// Sixty-four f64 planes leave room for each family's sums and byte counts;
// this is a representability ceiling, not an allocation or performance budget.
fn elements(factors: []const usize) !usize {
    var count: usize = 1;
    for (factors) |factor| count = std.math.mul(usize, count, factor) catch return error.InvalidQueryOptions;
    if (count > std.math.maxInt(usize) / (64 * @sizeOf(f64))) return error.InvalidQueryOptions;
    return count;
}

fn tolerance(t: @import("core").numerics.Tolerances) !void {
    inline for (.{ "reltol", "abstol", "vntol", "residual_tol", "chgtol", "trtol" }) |field|
        try positive(@field(t, field));
    if (t.gmin < 0 or t.gmin_start < 0 or t.itl1 == 0 or t.itl2 == 0 or t.itl4 == 0)
        return error.InvalidQueryOptions;
}

pub fn validate(query: requests.Query, n: u32) !void {
    @setEvalBranchQuota(10000);
    if (n == 0) return error.InvalidQueryOptions;
    switch (query) {
        inline else => |o| {
            if (!finite(o)) return error.InvalidQueryOptions;
            try tolerance(o.tol);
            inline for (.{ "out_node", "output_node", "source_node", "ac_source_node", "probe_p", "probe_n", "input_branch", "in_branch", "drive_branch" }) |field| {
                if (@hasField(@TypeOf(o), field)) {
                    const node = @field(o, field);
                    if (@typeInfo(@TypeOf(node)) == .optional) {
                        if (node) |v| if (v >= n) return error.InvalidQueryOptions;
                    } else if (node >= n) return error.InvalidQueryOptions;
                }
            }
            if (@hasField(@TypeOf(o), "sweep")) {
                // `.lin` is the one grid that may start at DC; every geometric
                // grid needs a positive first point to step from.
                if (o.sweep.f_start < 0 or o.sweep.f_stop < o.sweep.f_start) return error.InvalidQueryOptions;
                if (o.sweep.kind != .lin and o.sweep.f_start <= 0) return error.InvalidQueryOptions;
                if (o.sweep.points == 0) return error.InvalidQueryOptions;
                if (o.sweep.f_start > 0) try frequency(o.sweep.f_start);
                try frequency(o.sweep.f_stop);
                _ = try elements(&.{ o.sweep.count(), n, 2 });
            }
            inline for (.{ "n_samples", "n_time_samples", "pss_n_samples", "n_trials", "max_steps", "max_iter", "max_newton", "max_shooting_iter", "carrier_steps_per_period", "periods_per_outer_step", "min_periods_per_step", "max_periods_per_step", "max_outer_steps", "max_points", "m_max", "gmres_restart", "gmres_max_restarts", "max_newton_iter", "pss_periods", "pss_max_newton_iter", "pss_shoot_max_iter", "pss_newton_max_iter", "qr_max_iter" }) |field| {
                if (@hasField(@TypeOf(o), field)) if (@field(o, field) == 0) return error.InvalidQueryOptions;
            }
            inline for (.{ "f0", "f1", "f2", "f_lo", "f_fundamental", "period", "t_carrier", "dt_init", "dt_min", "t_stop" }) |field| {
                if (@hasField(@TypeOf(o), field) and @TypeOf(o) != requests.Temp)
                    if (@field(o, field) <= 0) return error.InvalidQueryOptions;
            }
            inline for (.{ "shooting_tol", "fd_epsilon", "newton_tol", "gmres_tol", "hb_tol", "pss_newton_tol", "pss_shoot_tol", "krylov_tol", "qr_tol", "fd_eps", "envelope_reltol" }) |field| {
                if (@hasField(@TypeOf(o), field)) try positive(@field(o, field));
            }
            inline for (.{ "f0", "f1", "f2", "f_lo", "f_fundamental" }) |field| {
                if (@hasField(@TypeOf(o), field)) try frequency(@field(o, field));
            }
            if (@hasField(@TypeOf(o), "gmres_restart")) {
                _ = try elements(&.{ @as(usize, o.gmres_restart) + 1, @as(usize, o.gmres_restart) + 1 });
                _ = try elements(&.{ @as(usize, o.gmres_restart) + 1, n });
            }
        },
    }
    switch (query) {
        .dc => |o| {
            const inner = try sweep(o.start, o.stop, o.step);
            const outer = if (o.hasOuter()) try sweep(o.start2, o.stop2, o.step2) else 1;
            _ = try elements(&.{ inner, outer, @as(usize, n) + 1 });
        },
        .temp => |o| {
            // The current temperature driver and numPoints are ascending only.
            if (o.t_step <= 0) return error.InvalidQueryOptions;
            const count = try sweep(o.t_start, o.t_stop, o.t_step);
            _ = try elements(&.{ count, @as(usize, n) + 1 });
            try validate(.{ .dc = o.dc_options }, n);
        },
        .mc => |o| {
            if (o.variation < 0) return error.InvalidQueryOptions;
            try validate(.{ .dc = o.dc_options }, n);
            _ = try elements(&.{ o.n_trials, @as(usize, n) + 1 });
        },
        .tran => |o| {
            if (o.dt_min > o.dt_init) return error.InvalidQueryOptions;
            if (o.dt_max) |max| if (max <= 0 or max < o.dt_min) return error.InvalidQueryOptions;
            try timeStep(o.dt_min);
            try timeStep(o.dt_init);
            try timeStep(o.dt_max orelse o.t_stop / 50);
            if (o.max_steps == std.math.maxInt(u32)) return error.InvalidQueryOptions;
        },
        .tran_noise => |o| {
            if (o.dt_max < o.dt_min or o.dt_min > o.dt_init or o.max_steps == std.math.maxInt(u32)) return error.InvalidQueryOptions;
            try timeStep(o.dt_min);
            try timeStep(o.dt_init);
            try timeStep(o.dt_max);
        },
        .pac, .pxf => |o| {
            if (!std.math.isPowerOfTwo(o.n_time_samples) or @as(u32, o.n_time_samples) < 2 * (2 * @as(u32, o.n_harmonics) + 1))
                return error.InvalidQueryOptions;
            try timeStep((1 / o.f_lo) / @as(f64, @floatFromInt(o.n_time_samples)));
            const bands = 2 * @as(usize, o.n_harmonics) + 1;
            _ = try elements(&.{ bands, n, bands, n });
            _ = try elements(&.{ o.n_time_samples, n, n });
            try frequency(o.sweep.f_stop + @as(f64, @floatFromInt(o.n_harmonics)) * o.f_lo);
        },
        .sp => |o| {
            for (o.ports) |port| {
                if (port.node >= n or port.branch >= n or port.z0 <= 0) return error.InvalidQueryOptions;
            }
            const ports = @max(o.ports.len, 1);
            _ = try elements(&.{ o.sweep.count(), ports, ports, 2 });
        },
        .four => |o| {
            if (o.n_harmonics == 0 or o.n_harmonics > requests.Four.max_harmonics) return error.InvalidQueryOptions;
            if (o.tran_opts) |tran| {
                try validate(.{ .tran = tran }, n);
            } else {
                try positive(5 / o.f_fundamental);
                try timeStep(1 / (200 * o.f_fundamental));
            }
        },
        .pss => |o| {
            if (o.n_samples == std.math.maxInt(u32)) return error.InvalidQueryOptions;
            try timeStep(o.period / @as(f64, @floatFromInt(o.n_samples)));
            _ = try elements(&.{ @as(usize, o.n_samples) + 1, @as(usize, n) + 1 });
        },
        .pnoise => |o| {
            try timeStep((1 / o.f_fundamental) / @as(f64, @floatFromInt(o.pss_n_samples)));
            _ = try elements(&.{ o.pss_n_samples, n, n });
            try frequency(o.sweep.f_stop + @as(f64, @floatFromInt(o.n_sidebands)) * o.f_fundamental);
        },
        .hb => |o| {
            if (o.n_harmonics == 0) return error.InvalidQueryOptions;
            const bands = 2 * @as(usize, o.n_harmonics) + 1;
            _ = try elements(&.{ bands, n, bands, n });
            _ = try elements(&.{ bands, bands });
            try frequency(o.f0 * @as(f64, @floatFromInt(o.n_harmonics)));
        },
        .qpss => |o| {
            const bands = try elements(&.{ 2 * @as(usize, o.k1) + 1, 2 * @as(usize, o.k2) + 1 });
            const width = try elements(&.{ bands, n, 2 });
            if (width > std.math.maxInt(u32)) return error.InvalidQueryOptions;
            _ = try elements(&.{ bands, bands });
            _ = try elements(&.{ bands, n, n });
            _ = try elements(&.{ width, @as(usize, o.gmres_restart) + 1 });
            try frequency(o.f1 * @as(f64, @floatFromInt(@max(o.k1, 1))) + o.f2 * @as(f64, @floatFromInt(@max(o.k2, 1))));
        },
        .disto => {
            _ = try elements(&.{ n, n, n });
            try frequency(query.disto.sweep.f_stop * 2);
        },
        .envelope => |o| {
            if (o.min_periods_per_step > o.max_periods_per_step or o.periods_per_outer_step < o.min_periods_per_step or
                o.periods_per_outer_step > o.max_periods_per_step or o.max_outer_steps > std.math.maxInt(u32) - 2)
                return error.InvalidQueryOptions;
            try timeStep(o.t_carrier / @as(f64, @floatFromInt(o.carrier_steps_per_period)));
            try positive(o.t_carrier * @as(f64, @floatFromInt(o.max_periods_per_step)));
            _ = try elements(&.{ @as(usize, o.max_outer_steps) + 2, 2 * @as(usize, n) + 1 });
        },
        .matex => |o| {
            try timeStep(o.gamma orelse o.t_stop / 1000);
            try timeStep(o.h_output_cap orelse o.t_stop / 200);
            _ = try elements(&.{ @as(usize, o.m_max) + 1, @as(usize, o.m_max) + 1 });
            _ = try elements(&.{ @as(usize, o.m_max) + 1, n });
            _ = try elements(&.{ o.max_points, @as(usize, n) + 1 });
        },
        .tf, .pz => {
            _ = try elements(&.{ n, n });
        },
        else => {},
    }
}

pub fn validateDeck(query: requests.Query, n: u32, deck: *const Deck) !void {
    try validate(query, n);
    if (query == .dc) {
        try dcTargetExists(query.dc.target, deck);
        if (query.dc.target2) |t2| try dcTargetExists(t2, deck);
    }
}

/// The swept card has to be one the circuit actually built — the card table
/// is keyed the same way `ParamRef` is, so this is the same lookup `dc.run`
/// will do, just before anything is allocated for it.
fn dcTargetExists(target: requests.Dc.SweepTarget, deck: *const Deck) !void {
    if (target.is_temp) return;
    for (deck.cards) |card| {
        if (card.index == target.index and std.mem.eql(u8, card.type_name, target.type_name)) return;
    }
    return error.DcSweepSourceNotFound;
}
