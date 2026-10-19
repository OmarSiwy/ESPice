//! The lane surface of every lane-generic analysis: one value per lane, one
//! mask bit per lane, and seven functions over them. `Lanes(1)` maps each
//! function to the scalar operation it replaces, which the `gen_lanes_*`
//! probes in tests/codegen.zig hold to IDENTICAL. Lanes are independent
//! points: nothing here reduces across lanes, so no decision couples them.
//! dev/research/lane-batched-simulation.md §3.1.

const std = @import("std");
const assert = std.debug.assert;

/// W lanes, 1 <= W <= 64 (`LaneLu`'s failure mask width).
pub fn Lanes(comptime W: usize) type {
    comptime {
        assert(W >= 1);
        assert(W <= 64);
    }
    return struct {
        pub const width = W;
        /// One value per lane; f64 itself at W = 1.
        pub const V = if (W == 1) f64 else @Vector(W, f64);
        /// One flag per lane, bit l for lane l. A u1 rather than a bool at
        /// W = 1, so `&`, `|` and `~` combine masks at every width.
        pub const Mask = @Int(.unsigned, W);
        pub const none: Mask = 0;
        pub const every: Mask = std.math.maxInt(Mask);

        pub inline fn splat(x: f64) V {
            return if (W == 1) x else @splat(x);
        }

        pub inline fn any(m: Mask) bool {
            return m != none;
        }

        pub inline fn all(m: Mask) bool {
            return m == every;
        }

        /// Per lane: `a` where the bit is set, else `b`.
        pub inline fn select(m: Mask, a: V, b: V) V {
            if (W == 1) return if (m != 0) a else b;
            return @select(f64, @as(@Vector(W, bool), @bitCast(m)), a, b);
        }

        /// Per lane `a op b`, NaN comparing as IEEE does (false except `.neq`).
        pub inline fn cmp(comptime op: std.math.CompareOperator, a: V, b: V) Mask {
            if (W == 1) return @intFromBool(std.math.compare(a, op, b));
            const r: @Vector(W, bool) = switch (op) {
                .lt => a < b,
                .lte => a <= b,
                .eq => a == b,
                .gte => a >= b,
                .gt => a > b,
                .neq => a != b,
            };
            return @bitCast(r);
        }

        /// Lane l of `v`. Asserts l < W.
        pub inline fn lane(v: V, l: usize) f64 {
            assert(l < W);
            if (W == 1) return v;
            return @as([W]f64, v)[l];
        }

        /// The set lanes of `m`, ascending.
        pub inline fn each(m: Mask) Iter {
            return .{ .bits = m };
        }

        pub const Iter = struct {
            bits: Mask,

            pub inline fn next(it: *Iter) ?usize {
                if (it.bits == 0) return null;
                const l: usize = @ctz(it.bits);
                it.bits &= it.bits - 1;
                return l;
            }
        };
    };
}

const testing = std.testing;

test "Lanes(W) primitives agree with the scalar operation in every lane, NaN included" {
    inline for (.{ 1, 4, 8 }) |W| {
        const L = Lanes(W);
        const nan = std.math.nan(f64);
        const pool = [_]f64{ -1, 0, -0.0, 2, nan, std.math.inf(f64) };
        var a: [W]f64 = undefined;
        var b: [W]f64 = undefined;
        for (0..pool.len * pool.len) |k| {
            for (&a, &b, 0..) |*x, *y, l| {
                x.* = pool[(k + l) % pool.len];
                y.* = pool[(k / pool.len + 2 * l) % pool.len];
            }
            const va: L.V = if (W == 1) a[0] else a;
            const vb: L.V = if (W == 1) b[0] else b;
            inline for (.{ .lt, .lte, .eq, .gte, .gt, .neq }) |op| {
                const m = L.cmp(op, va, vb);
                const sel = L.select(m, va, vb);
                var seen: L.Mask = 0;
                var it = L.each(m);
                var prev: ?usize = null;
                while (it.next()) |l| {
                    if (prev) |p| try testing.expect(l > p);
                    prev = l;
                    seen |= @as(L.Mask, 1) << @intCast(l);
                }
                try testing.expectEqual(m, seen);
                var count: usize = 0;
                for (0..W) |l| {
                    const want = std.math.compare(a[l], op, b[l]);
                    try testing.expectEqual(want, (m >> @intCast(l)) & 1 != 0);
                    const pick = if (want) a[l] else b[l];
                    try testing.expectEqual(@as(u64, @bitCast(pick)), @as(u64, @bitCast(L.lane(sel, l))));
                    count += @intFromBool(want);
                }
                try testing.expectEqual(count != 0, L.any(m));
                try testing.expectEqual(count == W, L.all(m));
            }
        }
        try testing.expectEqual(@as(f64, 3), L.lane(L.splat(3), W - 1));
        try testing.expect(!L.any(L.none) and L.all(L.every));
    }
}
