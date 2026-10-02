//! HSPICE MOSRA level 1 aging (docs/analysis/mosra.md): per-device stress
//! integrated over a fresh transient, extrapolated to each reliability time
//! as a power law, and turned into the `delvto`/`mulu0` writes of the aged
//! runs plus the degradation table HSPICE writes as `.radeg`.
const std = @import("std");
const core = @import("core");

/// What `age` returns, allocated in its arena.
pub const Aged = struct {
    /// `reltime` then, per device, `delvto(m)`, `mulu0(m)` and with DegF
    /// `life(m)`: one row per reliability time.
    table: core.Result,
    /// The aged variant rows' values, `core.Mosra` row order.
    values: []const f64,
};

/// Ages `m`'s devices over the stress transient `res`, whose columns are
/// time and then drain, gate and source voltage of each device.
///
/// Mechanism k of a device sees A_k(t) = a0·exp(fd·v(t) - td/T) while
/// stressed. ΔVth_k(t_rel) = (t_rel·avg(A_k^(1/n_k)))^n_k, the average
/// taken over the stress window: exactly A·t^n under constant stress, and
/// the usual quasi-static sum when the stress varies.
pub fn age(arena: std.mem.Allocator, m: core.Mosra, res: core.Result) !Aged {
    const n = m.names.len;
    const width = res.varnames.len;
    std.debug.assert(width == 1 + 3 * n);
    // Integrals of A^(1/n): HCI in [0, n), BTI in [n, 2n), then the
    // integrands at the previous and current sample.
    const buf = try arena.alloc(f64, 6 * n);
    const sum = buf[0 .. 2 * n];
    const prev = buf[2 * n .. 4 * n];
    const cur = buf[4 * n ..];
    @memset(sum, 0);
    var t_first: ?f64 = null;
    var t_prev: f64 = 0;
    for (0..res.npoints) |r| {
        const row = res.data[r * width ..][0..width];
        const t = row[0];
        if (t < m.aging_start or t > m.aging_stop) continue;
        integrands(m, row[1..], cur);
        if (t_first == null) {
            t_first = t;
        } else for (sum, prev, cur) |*s, p, c| {
            s.* += 0.5 * (t - t_prev) * (p + c);
        }
        @memcpy(prev, cur);
        t_prev = t;
    }
    const span = t_prev - (t_first orelse return error.MosraEmptyWindow);
    if (!(span > 0)) return error.MosraEmptyWindow;
    for (sum) |*s| s.* /= span;

    const cols: usize = if (m.deg_f != null) 3 else 2;
    const names = try arena.alloc([]const u8, 1 + cols * n);
    names[0] = "reltime";
    for (m.names, 0..) |name, i| {
        names[1 + cols * i] = try std.fmt.allocPrint(arena, "delvto({s})", .{name});
        names[2 + cols * i] = try std.fmt.allocPrint(arena, "mulu0({s})", .{name});
        if (cols == 3) names[3 + cols * i] = try std.fmt.allocPrint(arena, "life({s})", .{name});
    }
    const data = try arena.alloc(f64, m.rel_times.len * names.len);
    var values: std.ArrayList(f64) = .empty;
    for (m.rel_times, 0..) |t_rel, k| {
        const row = data[k * names.len ..][0..names.len];
        row[0] = t_rel;
        for (0..n) |i| {
            const md = m.models[m.model[i]];
            const hci = std.math.pow(f64, sum[i] * t_rel, md.hcin);
            const bti = std.math.pow(f64, sum[n + i] * t_rel, md.tn);
            const dvth = if (m.pmos[i]) -(hci + bti) else hci + bti;
            const mulu0 = 1 / (1 + md.hcimu * hci + md.titmu * bti);
            row[1 + cols * i] = dvth;
            row[2 + cols * i] = mulu0;
            if (m.deg_f) |deg_f| row[3 + cols * i] = lifetime(.{ sum[i], sum[n + i] }, .{ md.hcin, md.tn }, deg_f);
            try values.append(arena, m.delvto_fresh[i] + dvth);
            if (m.mulu0[i] != core.Mosra.no_param) try values.append(arena, m.mulu0_fresh[i] * mulu0);
        }
    }
    return .{ .values = values.items, .table = .{
        .plotname = "MOSRA Degradation",
        .varnames = names,
        .is_complex = false,
        .npoints = m.rel_times.len,
        .data = data,
    } };
}

/// Each device's A^(1/n) at one sample, HCI into `out[0..n]` and BTI into
/// `out[n..]`. `v` holds three terminal voltages per device.
fn integrands(m: core.Mosra, v: []const f64, out: []f64) void {
    const n = m.names.len;
    for (0..n) |i| {
        const md = m.models[m.model[i]];
        const pol: f64 = if (m.pmos[i]) -1 else 1;
        const d, const g, const s = v[3 * i ..][0..3].*;
        // The lower terminal (for a PMOS, the higher) acts as the source.
        var vds = pol * (d - s);
        var vgs = pol * (g - s);
        if (vds < 0) {
            vds = -vds;
            vgs = pol * (g - d);
        }
        out[i] = if (m.hci and vgs > m.hci_threshold and vds > 0)
            std.math.pow(f64, md.hci0 * @exp(md.hcifd * vds - md.hcitd / m.temp_k), 1 / md.hcin)
        else
            0;
        out[n + i] = if (m.bti and vgs > m.bti_threshold)
            std.math.pow(f64, md.tit0 * @exp(md.titfd * vgs - md.tittd / m.temp_k), 1 / md.tn)
        else
            0;
    }
}

/// The reliability time at which Σ (rate_k·t)^n_k reaches `deg_f`, by
/// bisection on log10 t over [1e-30, 1e30] s; inf when it never does.
fn lifetime(rate: [2]f64, exponent: [2]f64, deg_f: f64) f64 {
    const deg = struct {
        fn at(r: [2]f64, e: [2]f64, t: f64) f64 {
            return std.math.pow(f64, r[0] * t, e[0]) + std.math.pow(f64, r[1] * t, e[1]);
        }
    }.at;
    var lo: f64 = -30;
    var hi: f64 = 30;
    if (deg(rate, exponent, std.math.pow(f64, 10, hi)) < deg_f) return std.math.inf(f64);
    for (0..100) |_| {
        const mid = 0.5 * (lo + hi);
        if (deg(rate, exponent, std.math.pow(f64, 10, mid)) < deg_f) lo = mid else hi = mid;
    }
    return std.math.pow(f64, 10, hi);
}

test "age: constant stress is A t^n, and DegF inverts it" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const md: core.MosraModel = .{ .tit0 = 1e-3, .titfd = 0.5, .tn = 0.25, .hci0 = 2e-4, .hcin = 0.5, .hcimu = 0.1 };
    const m: core.Mosra = .{
        .tran = .{ .t_stop = 1e-6 },
        .rel_times = &.{ 1e6, 1e8 },
        .aged_runs = true,
        .deg_f = 0.05,
        .temp_k = 300,
        .models = &.{md},
        .names = &.{"m1"},
        .terminals = &.{.{ 1, 2, 0 }},
        .pmos = &.{false},
        .model = &.{0},
        .delvto = &.{7},
        .mulu0 = &.{8},
        .delvto_fresh = &.{0.02},
        .mulu0_fresh = &.{0.5},
    };
    // vd = 1.5, vg = 1.2, constant over three samples.
    const data = [_]f64{ 0, 1.5, 1.2, 0, 0.5e-6, 1.5, 1.2, 0, 1e-6, 1.5, 1.2, 0 };
    const res: core.Result = .{ .plotname = "", .varnames = &.{ "time", "d", "g", "s" }, .is_complex = false, .npoints = 3, .data = &data };
    const aged = try age(arena.allocator(), m, res);
    for (m.rel_times, 0..) |t, k| {
        const bti = 1e-3 * @exp(0.5 * 1.2) * std.math.pow(f64, t, 0.25);
        const hci = 2e-4 * std.math.pow(f64, t, 0.5);
        try std.testing.expectApproxEqRel(0.02 + hci + bti, aged.values[2 * k], 1e-12);
        try std.testing.expectApproxEqRel(0.5 / (1 + 0.1 * hci), aged.values[2 * k + 1], 1e-12);
        try std.testing.expectApproxEqRel(hci + bti, aged.table.data[4 * k + 1], 1e-12);
        try std.testing.expectApproxEqRel(t, aged.table.data[4 * k], 0);
    }
    const life = aged.table.data[3];
    const at_life = 1e-3 * @exp(0.5 * 1.2) * std.math.pow(f64, life, 0.25) + 2e-4 * std.math.pow(f64, life, 0.5);
    try std.testing.expectApproxEqRel(0.05, at_life, 1e-9);
}
