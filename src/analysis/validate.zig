//! Query validation at the analysis boundary: every numeric option a driver
//! would otherwise trust, checked once before any allocation.
const std = @import("std");
const requests = @import("core").query;
const Deck = @import("core").Deck;

/// True when every float reachable from `value` is finite.
fn finite(value: anytype) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .float => std.math.isFinite(value),
        .@"struct" => |s| blk: {
            inline for (s.field_names) |name| if (!finite(@field(value, name))) break :blk false;
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

/// Returns the point count of an ascending or descending linear sweep.
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

/// Returns the product of `factors`, rejecting any slab too large for 64 f64
/// planes of it to be byte-addressable. A representability ceiling for the
/// unchecked arithmetic downstream, not a memory budget.
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

/// Checks `query` against a circuit of `n` unknowns: finite options, valid
/// tolerances, in-range node and branch indices, positive steps and counts,
/// and representable derived sizes. Fails with `error.InvalidQueryOptions`.
pub fn validate(query: requests.Query, n: u32) !void {
    @setEvalBranchQuota(10000);
    if (n == 0) return error.InvalidQueryOptions;
    switch (query) {
        inline else => |o| {
            if (!finite(o)) return error.InvalidQueryOptions;
            try tolerance(o.tol);
            inline for (.{ "out_node", "out_neg", "osc_node", "output_node", "source_node", "ac_source_node", "probe_p", "probe_n", "input_branch", "in_branch", "drive_branch", "drive2_branch" }) |field| {
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
            const inner = if (o.points.len > 0) o.points.len else try sweep(o.start, o.stop, o.step);
            const outer = if (!o.hasOuter()) 1 else if (o.points2.len > 0) o.points2.len else try sweep(o.start2, o.stop2, o.step2);
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
            if (o.out_node >= n or o.out_neg >= n) return error.InvalidQueryOptions;
            if (o.sde) _ = try elements(&.{ n, n });
            try timeStep(o.dt_min);
            try timeStep(o.dt_init);
            try timeStep(o.dt_max);
        },
        .pac, .pxf => |o| {
            if (!std.math.isPowerOfTwo(o.n_time_samples) or @as(u32, o.n_time_samples) < 2 * (2 * @as(u32, o.n_harmonics) + 1))
                return error.InvalidQueryOptions;
            if (o.out_node >= n) return error.InvalidQueryOptions;
            try timeStep((1 / o.f_lo) / @as(f64, @floatFromInt(o.n_time_samples)));
            const bands = 2 * @as(usize, o.n_harmonics) + 1;
            _ = try elements(&.{ bands, n, bands, n });
            _ = try elements(&.{ o.n_time_samples, n, n });
            try frequency(o.sweep.f_stop + @as(f64, @floatFromInt(o.n_harmonics)) * o.f_lo);
        },
        .sp => |o| {
            for (o.ports) |port| {
                const branch_ok = port.branch < n or (o.net and port.branch == requests.Port.no_branch);
                if (port.node >= n or port.neg >= n or !branch_ok or port.z0 <= 0) return error.InvalidQueryOptions;
                if (port.balanced) |leg| if (leg.node >= n or leg.branch >= n or o.net) return error.InvalidQueryOptions;
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
        .phasenoise => |o| {
            if (o.osc_node == 0 or o.carrier == 0 or o.carrier > o.n_harmonics) return error.InvalidQueryOptions;
            try validate(.{ .hb = o.hb() }, n);
            const bands = 2 * @as(usize, o.n_harmonics) + 1;
            if (o.method != .nlp) _ = try elements(&.{ bands, n, bands, n, 4 });
        },
        .hbac, .hbxf, .hbnoise => |o| {
            try validate(.{ .hb = o.hb() }, n);
            const bands = 2 * @as(usize, o.n_sidebands) + 1;
            _ = try elements(&.{ bands, n, bands, n, 4 });
            try frequency(o.sweep.f_stop + @as(f64, @floatFromInt(o.n_sidebands)) * o.f0);
        },
        .pnoise => |o| {
            try timeStep((1 / o.f_fundamental) / @as(f64, @floatFromInt(o.pss_n_samples)));
            _ = try elements(&.{ o.pss_n_samples, n, n });
            try frequency(o.sweep.f_stop + @as(f64, @floatFromInt(o.n_sidebands)) * o.f_fundamental);
        },
        .hb => |o| {
            if (o.n_harmonics == 0 or o.subharms == 0) return error.InvalidQueryOptions;
            if (o.extra_tones.len != 0) {
                const mhb = @import("pss/mhb.zig");
                if (o.osc_node != 0 or o.extra_harmonics.len != o.extra_tones.len or o.extra_tones.len >= mhb.max_tones)
                    return error.InvalidQueryOptions;
                var box: usize = 2 * @as(usize, o.n_harmonics) + 1;
                var top = o.f0 * @as(f64, @floatFromInt(o.n_harmonics));
                for (o.extra_tones, o.extra_harmonics) |f, h| {
                    try positive(f);
                    if (h == 0 or h > std.math.maxInt(i16)) return error.InvalidQueryOptions;
                    box = try elements(&.{ box, 2 * @as(usize, h) + 1 });
                    top += f * @as(f64, @floatFromInt(h));
                }
                if (box > mhb.max_box) return error.InvalidQueryOptions;
                _ = try elements(&.{ box, box, 2 * n });
                try frequency(top);
                return;
            }
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
        .disto => |o| {
            _ = try elements(&.{ n, n, n });
            try frequency(o.sweep.f_stop * 2);
            const im = o.plot == .f1pf2 or o.plot == .f1mf2 or o.plot == .twof1mf2;
            if (o.f2_ratio < 0 or (im and o.f2_ratio == 0)) return error.InvalidQueryOptions;
            if (o.f2_ratio != 0) try frequency(o.sweep.f_stop * 2 + o.f2_ratio * o.sweep.f_start);
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
        .lstb => |o| {
            for (o.probes[0..if (o.mode == .single) 1 else 2]) |p|
                if (p.p >= n or p.n >= n or p.branch >= n) return error.InvalidQueryOptions;
            _ = try elements(&.{ o.sweep.count(), n, 4 });
        },
        inline .dcxf, .acxf => |o| {
            if (o.output_neg >= n) return error.InvalidQueryOptions;
            if (o.output_branch) |br| if (br >= n) return error.InvalidQueryOptions;
            for (o.sources) |s| {
                if (s.branch) |br| if (br >= n) return error.InvalidQueryOptions;
                if (s.nodes[0] >= n or s.nodes[1] >= n) return error.InvalidQueryOptions;
            }
            if (query == .acxf) _ = try elements(&.{ @min(o.sources.len, 64), o.sources.len + 1, n, 2 });
        },
        // HSPICE's bounds [CR .FFT]: 4 <= NP <= 2^27, a window inside the run.
        .fft => |o| {
            // Bounds first: `isPowerOfTwo` asserts a positive argument.
            if (o.np < 4 or o.np > 1 << 27 or !std.math.isPowerOfTwo(o.np)) return error.InvalidQueryOptions;
            if (!(o.start >= 0) or !(o.stop > o.start) or o.stop > o.tran.t_stop) return error.InvalidQueryOptions;
            if (o.out_pos >= n or o.out_neg >= n) return error.InvalidQueryOptions;
            try validate(.{ .tran = o.tran }, n);
        },
        else => {},
    }
}

/// `validate`, plus `error.DcSweepSourceNotFound` when a `.dc` sweep names a
/// card the deck does not have.
pub fn validateDeck(query: requests.Query, n: u32, deck: *const Deck) !void {
    try validate(query, n);
    const variant = switch (query) {
        inline else => |o| o.tol.variant,
    };
    if (variant) |v| if (v >= deck.variants.count()) return error.InvalidQueryOptions;
    if (query == .mc) {
        const r = query.mc.variants;
        if (@as(u64, r.first) + r.count > deck.variants.count()) return error.InvalidQueryOptions;
    }
    if (query == .dc) {
        try dcTargetExists(query.dc.target, deck);
        if (query.dc.target2) |t2| try dcTargetExists(t2, deck);
    }
}

/// The same (type, ordinal) lookup `dc.run` does, made before anything is
/// allocated for the sweep.
fn dcTargetExists(target: requests.Dc.SweepTarget, deck: *const Deck) !void {
    const d = switch (target) {
        .temp => return,
        .device => |d| d,
    };
    for (deck.cards) |card| {
        if (card.index == d.index and card.type == d.type) return;
    }
    return error.DcSweepSourceNotFound;
}
