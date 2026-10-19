//! Origin: VerA docs/measurements/batched-lead-2026-10-02/batch_family.zig
//! (deleted in VerA 4a870ae8), plus `laneOf` on Family for contract 0.10.3.
//! A measurement-only family: `RefSparse`'s numerics with every value a
//! vector of W operating points (`V = @Vector(W, f64)`) and each derivative
//! lane a W-vector, stored lane-major in one `@Vector(P * W, f64)` (P the
//! mask's popcount: a P x W tile). Comparisons and `sel` are per point.
//! `val()` returns point 0: a device that steers on a value (not `batch_ok`)
//! follows point 0's branches in every lane. For the cost study that is the
//! coherent-branch case, an upper bound on what batching can give.
const std = @import("std");
const contract = @import("contract");
const gm = contract.gm;

/// The batch family with the lead protocol (contract.zig `batch_lead`): the
/// family the device's entry points see. `Core` is the family each run uses.
pub fn Family(comptime W: usize, comptime lane: []const u8) type {
    const C = Core(W, lane);
    return struct {
        pub const Core_ = C;
        pub const Lane = C.Lane;
        pub const lane_count = C.lane_count;
        pub const fromLanes = C.fromLanes;
        pub const laneOf = C.laneOf;
        pub const instLane = C.instLane;
        pub const V = C.V;
        pub const Of = C.Of;
        pub const con = C.con;
        pub const lift = C.lift;
        pub const probe = C.probe;
        pub const sel = C.sel;
        pub const Inner = C;
        /// Runs of the device per batched call, summed (the divergence cost).
        pub var runs: u64 = 0;
        pub fn leadBegin() void {
            C.lead.begin();
            runs += 1;
        }
        pub fn leadNext() bool {
            const more = C.lead.next();
            if (more) runs += 1;
            return more;
        }
        pub fn leadMerge(out: anytype, new: @TypeOf(out.*)) void {
            contract.leadMergeInto(out, new, C.lead.keep());
        }
    };
}

fn Core(comptime W: usize, comptime lane: []const u8) type {
    return struct {
        pub var lead: contract.LeadState(W, @import("cfg").SIG) = .{};
        /// Point w's `Instance` (contract.zig `batch_inst`), set by the host.
        pub var insts: [W]*const anyopaque = undefined;
        pub fn instLane(comptime T: type, comptime w: usize) *const T {
            return @ptrCast(@alignCast(insts[w]));
        }
        pub const Lane = contract.RefFamily(f64, lane, .{ .dense = false });
        pub const lane_count = W;
        pub fn laneOf(a: anytype, comptime w: usize) Lane.Of(@TypeOf(a).mask) {
            const m = @TypeOf(a).mask;
            const P = @popCount(m);
            var d: @Vector(P, f64) = undefined;
            inline for (0..P) |p| d[p] = a.d[p * W + w];
            return .{ .v = a.v[w], .d = d };
        }
        pub fn fromLanes(comptime m: u64, ls: [W]Lane.Of(m)) Of(m) {
            const P = @popCount(m);
            var r: Of(m) = undefined;
            inline for (0..W) |w| {
                r.v[w] = ls[w].v;
                inline for (0..P) |p| r.d[p * W + w] = ls[w].d[p];
            }
            return r;
        }
        pub fn decide(comptime op: std.math.CompareOperator, a: anytype, b: anytype) bool {
            const c: @Vector(W, bool) = switch (op) {
                .lt => a.v < b.v,
                .lte => a.v <= b.v,
                .gt => a.v > b.v,
                .gte => a.v >= b.v,
                .eq => a.v == b.v,
                .neq => a.v != b.v,
            };
            return lead.mark(c);
        }
        pub fn decideI(a: anytype) i64 {
            var r: [W]i64 = undefined;
            inline for (0..W) |w| r[w] = std.math.lossyCast(i64, @round(a.v[w]));
            return lead.markI(r);
        }
        pub fn strip(a: anytype) Of(0) {
            return .{ .v = a.v, .d = .{} };
        }
        pub const V = @Vector(W, f64);
        const VW = V;

        pub fn con(c: f64) Of(0) {
            return .{ .v = @splat(c), .d = .{} };
        }
        pub fn lift(v: VW) Of(0) {
            return .{ .v = v, .d = .{} };
        }
        pub fn probe(comptime u: usize, v: VW) Of(@as(u64, 1) << u) {
            return .{ .v = v, .d = @splat(1.0) };
        }
        pub fn sel(c: anytype, a: anytype, b: anytype) Of(@TypeOf(a).mask | @TypeOf(b).mask) {
            const r = @TypeOf(a).mask | @TypeOf(b).mask;
            const R = Of(r);
            const ar = a.to(r);
            const br = b.to(r);
            const p = c.v != @as(VW, @splat(0.0));
            return .{ .v = @select(f64, p, ar.v, br.v), .d = @select(f64, R.tile(p), ar.d, br.d) };
        }

        const carried: u64 = blk: {
            var c: u64 = 0;
            for (lane, 0..) |l, u| if (u < 64 and l != contract.no_lane) {
                c |= @as(u64, 1) << @intCast(u);
            };
            break :blk c;
        };

        pub fn Of(comptime m: u64) type {
            if (m & ~carried != 0) @compileError("mask names an uncarried unknown");
            return struct {
                v: VW,
                d: Lanes,
                pub const mask = m;
                const P = @popCount(m);
                const Lanes = @Vector(P * W, f64);
                const T = @This();

                /// `x` repeated over the P lanes: point i of every lane.
                inline fn tileOf(comptime Q: usize, x: anytype) @Vector(Q * W, @typeInfo(@TypeOf(x)).vector.child) {
                    const idx = comptime blk: {
                        var a: [Q * W]i32 = undefined;
                        for (&a, 0..) |*e, j| e.* = @intCast(j % W);
                        break :blk a;
                    };
                    return @shuffle(@typeInfo(@TypeOf(x)).vector.child, x, undefined, idx);
                }
                inline fn tile(x: anytype) @Vector(P * W, @typeInfo(@TypeOf(x)).vector.child) {
                    return tileOf(P, x);
                }
                inline fn kv(x: VW) Lanes {
                    return tile(x);
                }
                fn map(a: T, v: VW, c: VW) T {
                    return .{ .v = v, .d = a.d * kv(c) };
                }
                fn Join(comptime B: type) type {
                    return Of(m | B.mask);
                }
                inline fn kj(comptime B: type, x: VW) @Vector(@popCount(m | B.mask) * W, f64) {
                    return tileOf(@popCount(m | B.mask), x);
                }

                inline fn spread(a: T, comptime to_m: u64) @Vector(@popCount(to_m) * W, f64) {
                    if (m & ~to_m != 0) @compileError("does not widen");
                    if (m == to_m) return a.d;
                    if (m == 0) return @splat(0.0);
                    const idx = comptime blk: {
                        @setEvalBranchQuota(1_000_000);
                        var idx: [@popCount(to_m) * W]i32 = undefined;
                        var j: usize = 0;
                        for (0..64) |u| if ((to_m >> u) & 1 != 0) {
                            const src: i32 = if ((m >> u) & 1 != 0) @popCount(m & ((@as(u64, 1) << u) - 1)) else -1;
                            for (0..W) |w| idx[j * W + w] = if (src < 0) -1 else src * @as(i32, W) + @as(i32, @intCast(w));
                            j += 1;
                        };
                        break :blk idx;
                    };
                    const z: @Vector(1, f64) = @splat(0.0);
                    return @shuffle(f64, a.d, z, idx);
                }

                pub fn to(a: T, comptime to_m: u64) Of(to_m) {
                    return .{ .v = a.v, .d = a.spread(to_m) };
                }
                pub fn val(a: T) f64 {
                    const arr: [W]f64 = a.v;
                    return arr[lead.leader];
                }
                pub fn leadKeep(a: *T, n: T, keep: @Vector(W, bool)) void {
                    a.v = @select(f64, keep, n.v, a.v);
                    a.d = @select(f64, tile(keep), n.d, a.d);
                }
                pub fn ddxAt(a: T, comptime u: usize) f64 {
                    if ((m >> u) & 1 == 0) return 0.0;
                    return a.d[@popCount(m & ((@as(u64, 1) << u) - 1)) * W];
                }
                /// Point `w`'s ddx: the batch host's scatter.
                pub fn ddxAtPoint(a: T, comptime u: usize, comptime w: usize) f64 {
                    if ((m >> u) & 1 == 0) return 0.0;
                    return a.d[@popCount(m & ((@as(u64, 1) << u) - 1)) * W + w];
                }

                pub fn add(a: T, b: anytype) Join(@TypeOf(b)) {
                    const r = m | @TypeOf(b).mask;
                    return .{ .v = a.v + b.v, .d = a.spread(r) + b.spread(r) };
                }
                pub fn sub(a: T, b: anytype) Join(@TypeOf(b)) {
                    const r = m | @TypeOf(b).mask;
                    return .{ .v = a.v - b.v, .d = a.spread(r) - b.spread(r) };
                }
                pub fn neg(a: T) T {
                    return .{ .v = -a.v, .d = -a.d };
                }
                pub fn mul(a: T, b: anytype) Join(@TypeOf(b)) {
                    const B = @TypeOf(b);
                    const r = m | B.mask;
                    if (B.mask == 0) return .{ .v = a.v * b.v, .d = a.spread(r) * kj(B, b.v) };
                    if (m == 0) return .{ .v = a.v * b.v, .d = b.spread(r) * kj(B, a.v) };
                    return .{ .v = a.v * b.v, .d = fma(b.spread(r), kj(B, a.v), a.spread(r) * kj(B, b.v)) };
                }
                pub fn div(a: T, b: anytype) Join(@TypeOf(b)) {
                    const B = @TypeOf(b);
                    const r = m | B.mask;
                    const one: VW = @splat(1.0);
                    const inv = one / b.v;
                    const q = a.v / b.v;
                    if (B.mask == 0) return .{ .v = q, .d = a.spread(r) * kj(B, inv) };
                    return .{ .v = q, .d = fma(b.spread(r), kj(B, -q), a.spread(r)) * kj(B, inv) };
                }
                pub fn scale(a: T, c: f64) T {
                    const cv: VW = @splat(c);
                    return map(a, a.v * cv, cv);
                }
                pub fn addC(a: T, c: f64) T {
                    const cv: VW = @splat(c);
                    return .{ .v = a.v + cv, .d = a.d };
                }
                pub fn exp(a: T) T {
                    const e = gm.exp(a.v);
                    return map(a, e, e);
                }
                pub fn log(a: T) T {
                    const one: VW = @splat(1.0);
                    return map(a, gm.log(a.v), one / a.v);
                }
                pub fn expm1(a: T) T {
                    return map(a, perPoint(a.v, gm.expm1), gm.exp(a.v));
                }
                pub fn log1p(a: T) T {
                    const one: VW = @splat(1.0);
                    return map(a, perPoint(a.v, std.math.log1p), one / (one + a.v));
                }
                pub fn sqrt(a: T) T {
                    const s = @sqrt(a.v);
                    const z: VW = @splat(0.0);
                    const h: VW = @splat(0.5);
                    return map(a, s, @select(f64, s > z, h / s, z));
                }
                pub fn sin(a: T) T {
                    return map(a, perPoint(a.v, gm.sin), perPoint(a.v, gm.cos));
                }
                pub fn cos(a: T) T {
                    return map(a, perPoint(a.v, gm.cos), -perPoint(a.v, gm.sin));
                }
                pub fn tanh(a: T) T {
                    const th = perPoint(a.v, gm.tanh);
                    const one: VW = @splat(1.0);
                    return map(a, th, one - th * th);
                }
                pub fn sinh(a: T) T {
                    return map(a, perPoint(a.v, gm.sinh), perPoint(a.v, gm.cosh));
                }
                pub fn cosh(a: T) T {
                    return map(a, perPoint(a.v, gm.cosh), perPoint(a.v, gm.sinh));
                }
                pub fn atan(a: T) T {
                    const one: VW = @splat(1.0);
                    return map(a, perPoint(a.v, gm.atan), one / (one + a.v * a.v));
                }
                pub fn pow(a: T, c: f64) T {
                    const p = gm.powV(a.v, c);
                    var s: VW = undefined;
                    inline for (0..W) |w| {
                        const x = a.v[w];
                        const sl = if (x != 0.0) c * p[w] / x else c * gm.pow(x, c - 1.0);
                        s[w] = if (std.math.isFinite(sl)) sl else 0.0;
                    }
                    return map(a, p, s);
                }
                pub fn lt(a: T, b: anytype) Of(0) {
                    return .{ .v = @select(f64, a.v < b.v, @as(VW, @splat(1.0)), @as(VW, @splat(0.0))), .d = .{} };
                }
                pub fn le(a: T, b: anytype) Of(0) {
                    return .{ .v = @select(f64, a.v <= b.v, @as(VW, @splat(1.0)), @as(VW, @splat(0.0))), .d = .{} };
                }
                pub fn eq(a: T, b: anytype) Of(0) {
                    return .{ .v = @select(f64, a.v == b.v, @as(VW, @splat(1.0)), @as(VW, @splat(0.0))), .d = .{} };
                }
            };
        }

        inline fn fma(a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
            return if (fma_lanes) @mulAdd(@TypeOf(a), a, b, c) else a * b + c;
        }
        inline fn perPoint(x: VW, comptime f: anytype) VW {
            var o: VW = undefined;
            inline for (0..W) |w| o[w] = f(x[w]);
            return o;
        }
    };
}

const fma_lanes = switch (@import("builtin").cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(@import("builtin").cpu.features, .fma),
    .aarch64, .nvptx64, .amdgcn => true,
    else => false,
};
