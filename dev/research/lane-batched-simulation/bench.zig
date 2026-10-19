//! Throwaway: bsimcmg (asap7 nmos_rvt) evalQ, scalar vs W-point batch
//! family with the lead protocol. Bias sets: coherent (W copies), lanes
//! (one inverter trajectory point, output shifted per lane as sizing
//! shifts delay), mixed (W unrelated points). Checks batch == scalar bits.
const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const BF = @import("batch_family.zig");
const W = @import("cfg").W;
const card = @import("params.zig").card;

const n = contract.nU(D);
const lanes = blk: {
    var a: [n]u8 = undefined;
    for (&a, 0..) |*v, i| v.* = @intCast(i);
    break :blk a;
};
const S = contract.RefFamily(f64, &lanes, .{ .dense = false });
const B = BF.Family(W, &lanes);
const no_lanes: [n]u8 = @splat(contract.no_lane);
const Vv = contract.RefFamily(f64, &no_lanes, .{ .dense = true });
const per = 2 * n * (n + 1);

var g_model: D.Model = .{};
var g_insts: [W]D.Instance = undefined;
var g_sim: contract.SimState = .{ .kind = .tran, .t = 1e-9, .dt = 1e-12, .analog_initial = false, .iteration = 3 };
var g_out: [W][per]f64 = undefined;
var sink: f64 = 0;

fn setParam(name: []const u8, v: f64) bool {
    @setEvalBranchQuota(10_000_000);
    const info = @typeInfo(D.Model).@"struct";
    inline for (info.field_names, info.field_types) |fname, FT| {
        if (std.ascii.eqlIgnoreCase(fname, name)) {
            switch (@typeInfo(FT)) {
                .float => @field(g_model, fname) = v,
                .int => @field(g_model, fname) = std.math.lossyCast(FT, @round(v)),
                else => return false,
            }
            if (@hasField(D.Model, fname ++ "__given")) @field(g_model, fname ++ "__given") = true;
            return true;
        }
    }
    return false;
}

fn writeS(rows: anytype, out: *[per]f64, comptime first: usize) void {
    inline for (rows, 0..) |v, row| {
        out[(first + row) * (n + 1)] = v.val();
        inline for (0..n) |col| out[(first + row) * (n + 1) + 1 + col] = v.ddxAt(col);
    }
}
fn writeB(rows: anytype, comptime first: usize) void {
    @setEvalBranchQuota(10_000_000);
    inline for (rows, 0..) |v, row| {
        inline for (0..W) |w| {
            g_out[w][(first + row) * (n + 1)] = v.v[w];
            inline for (0..n) |col| g_out[w][(first + row) * (n + 1) + 1 + col] = v.ddxAtPoint(col, w);
        }
    }
}
noinline fn evalScalar(x: *const [n]f64, inst: *D.Instance, out: *[per]f64) void {
    const both = @call(.always_inline, D.evalQ, .{ S, x, &g_model, inst, g_sim });
    writeS(both.res, out, 0);
    writeS(both.q, out, n);
}
noinline fn evalBatch(pts: *const [W][n]f64) void {
    var x: [n]B.V = undefined;
    inline for (0..n) |u| inline for (0..W) |w| {
        x[u][w] = pts[w][u];
    };
    inline for (0..W) |w| B.Core_.insts[w] = &g_insts[w];
    const both = @call(.always_inline, D.evalQ, .{ B, &x, &g_model, &g_insts[0], g_sim });
    writeB(both.res, 0);
    writeB(both.q, n);
}

/// Terminal bias -> all unknowns (internal nodes at their terminal).
fn bias(vd: f64, vg: f64) [n]f64 {
    var x: [n]f64 = @splat(0);
    const U = D.U;
    x[@intFromEnum(U.d)] = vd;
    x[@intFromEnum(U.g)] = vg;
    inline for (.{ U.di, U.di1, U.di2 }) |u| x[@intFromEnum(u)] = vd;
    inline for (.{ U.ge, U.gi, U.gint, U.gints, U.gintd }) |u| x[@intFromEnum(u)] = vg;
    return x;
}
/// Inverter trajectory: input ramps 0 -> 0.7 V, output falls.
fn vout(vin: f64) f64 {
    return 0.35 * (1 - std.math.tanh((vin - 0.35) / 0.04));
}

const NP = 256;
pub fn main() !void {
    var unknown: usize = 0;
    for (card) |kv| if (!setParam(kv[0], kv[1])) {
        unknown += 1;
    };
    _ = setParam("l", 20e-9);
    _ = setParam("nfin", 3);
    if (@hasDecl(D, "derive")) D.derive(Vv, &g_model);
    if (@hasDecl(D, "setup")) D.setup(Vv, &g_model);
    var inst0: D.Instance = .{};
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&g_model, &inst0);
    for (&g_insts) |*gi| gi.* = inst0;

    // Bias sets, [NP/W][W] points each.
    var coherent: [NP][n]f64 = undefined;
    var lanepts: [NP][n]f64 = undefined;
    var mixed: [NP][n]f64 = undefined;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    for (0..NP / W) |b| {
        const vin = 0.7 * @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(NP / W - 1));
        for (0..W) |w| {
            const k = b * W + w;
            coherent[k] = bias(vout(vin), vin);
            // lane w's delay differs: its output sits where vin +- 30 mV puts it.
            const shift = 0.03 * (2 * r.float(f64) - 1);
            lanepts[k] = bias(vout(vin + shift), vin);
            const vi = 0.7 * r.float(f64);
            mixed[k] = bias(vout(vi), vi);
        }
    }

    // Exactness: points whose batched outputs differ from their scalar call
    // (no lead protocol in this device: such a point followed the leader).
    const sets = [_]struct { []const u8, *const [NP][n]f64 }{ .{ "coherent", &coherent }, .{ "lanes", &lanepts }, .{ "mixed", &mixed } };
    for (sets) |c| {
        var bad_pts: usize = 0;
        for (0..NP / W) |b| {
            const pts: *const [W][n]f64 = @ptrCast(&c[1][b * W]);
            evalBatch(pts);
            for (0..W) |w| {
                var so: [per]f64 = undefined;
                evalScalar(&pts[w], &g_insts[w], &so);
                for (so, g_out[w]) |a, x| {
                    if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(x))) {
                        bad_pts += 1;
                        break;
                    }
                }
            }
        }
        std.debug.print("{s:<9}: {d}/{d} points off the leader's path\n", .{ c[0], bad_pts, NP });
    }
    std.debug.print("bsimcmg n_u={d} W={d} card params unmatched={d}\n", .{ n, W, unknown });

    const reps = 200;
    var best: [4]f64 = @splat(std.math.inf(f64));
    for (0..7) |_| {
        var t0 = rdtsc();
        for (0..reps) |_| for (0..NP) |k| evalScalar(&lanepts[k], &g_insts[k % W], &g_out[k % W]);
        best[0] = @min(best[0], @as(f64, @floatFromInt(rdtsc() - t0)) / (reps * NP));
        for (sets, 1..) |c, j| {
            t0 = rdtsc();
            for (0..reps) |_| for (0..NP / W) |b| evalBatch(@ptrCast(&c[1][b * W]));
            best[j] = @min(best[j], @as(f64, @floatFromInt(rdtsc() - t0)) / (reps * NP));
        }
    }
    std.debug.print("scalar evalQ: {d:.0} tsc/instance (best of 7)\n", .{best[0]});
    for (sets, 1..) |c, j| std.debug.print("batch {s:<9}: {d:.0} tsc/instance  speedup {d:.2}x\n", .{ c[0], best[j], best[0] / best[j] });
    sink += g_out[0][0];
}

inline fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}
