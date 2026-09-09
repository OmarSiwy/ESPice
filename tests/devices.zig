const std = @import("std");
const testing = std.testing;
const devices = @import("devices");
const Builder = @import("builder").Builder;
const Bjt = devices.byName("bjt");
const n_u = @typeInfo(Bjt.U).@"enum".fields.len;
const S = devices.engine.Dual(n_u, f64);

test "BJT: zero excess phase removes both filter nodes at setup" {
    for ([_]i32{ -1, 1 }) |polarity| for ([_]i32{ -1, 1 }) |subs| {
        for ([_]f64{ 0, 2e-9 }) |tf| for ([_]f64{ -30, 0, 30 }) |ptf| {
            const model: Bjt.Model = .{ .typeZ = polarity, .subs = subs, .rb = 100, .tf = tf, .ptf = ptf };
            const aliases = Bjt.collapse(&model, &.{});
            const enabled = tf * ptf != 0;
            inline for (.{ Bjt.U.xf1, Bjt.U.xf2 }) |u| {
                try testing.expectEqual(if (enabled) @as(?u8, null) else @intFromEnum(Bjt.U.s), aliases[@intFromEnum(u)]);
            }
            var b = Builder.init(testing.allocator);
            defer b.deinit();
            const c = b.addNode();
            const base = b.addNode();
            const e = b.addNode();
            const substrate = b.addNode();
            const before = b.n;
            try b.addDevice(Bjt, model, .{}, .{ c, base, e, substrate });
            // RB keeps bi; only a live filter needs xf1/xf2.
            try testing.expectEqual(@as(u32, if (enabled) 3 else 1), b.n - before);
        };
    };
}

test "BJT: zero phase is algebraic, nonzero phase retains the Weil equations" {
    for ([_]i32{ -1, 1 }) |polarity| for ([_]i32{ -1, 1 }) |subs| {
        for ([_]f64{ -30, 0, 30 }) |ptf| {
            const model: Bjt.Model = .{ .typeZ = polarity, .subs = subs, .tf = 2e-9, .ptf = ptf, .gmin = 0 };
            var inst: Bjt.Instance = .{};
            Bjt.precompute(&inst, &model);
            var x: [n_u]S = undefined;
            inline for (0..n_u) |i| x[i] = S.seed(0, i);
            const sign: f64 = @floatFromInt(polarity);
            x[@intFromEnum(Bjt.U.bi)].v = sign * 0.55;
            x[@intFromEnum(Bjt.U.ci)].v = sign * 1.5;
            x[@intFromEnum(Bjt.U.s)].v = sign * 0.2;
            x[@intFromEnum(Bjt.U.xf1)].v = 0.013;
            x[@intFromEnum(Bjt.U.xf2)].v = 0.021;
            const out = Bjt.evalQ(S, x, &model, &inst, 0);
            const vt = 1.380649e-23 * inst.temperature / 1.602176634e-19;
            const cbe = model.is * (@exp(0.55 / vt) - 1);
            const rev = 3 * vt / (std.math.e * (0.55 - 1.5));
            const cbc = -model.is * (1 + rev * rev * rev);
            const td = ptf * 0.017453292519943295 * model.tf;
            const xf1 = @intFromEnum(Bjt.U.xf1);
            const xf2 = @intFromEnum(Bjt.U.xf2);
            const transport = if (td == 0) cbe - cbc else 0.021 - cbc;
            try testing.expectApproxEqAbs(sign * (transport - cbc), out.res[@intFromEnum(Bjt.U.ci)].v, 1e-12);
            try testing.expectApproxEqAbs(if (td == 0) @as(f64, 0) else 0.021 - cbe, out.res[xf1].v, 1e-12);
            try testing.expectApproxEqAbs(if (td == 0) @as(f64, 0) else 0.008, out.res[xf2].v, 1e-12);
            try testing.expectApproxEqAbs(td * 0.013, out.q[xf1].v, 1e-24);
            try testing.expectApproxEqAbs(td * 0.021 / 3, out.q[xf2].v, 1e-24);
            try testing.expectApproxEqAbs(td, out.q[xf1].d[xf1], 1e-24);
            try testing.expectApproxEqAbs(td / 3, out.q[xf2].d[xf2], 1e-24);
        }
    };
}

test "BJT: collapsed phase shorts preserve weak substrate stamps" {
    for ([_]i32{ -1, 1 }) |polarity| for ([_]i32{ -1, 1 }) |subs| {
        for ([_]f64{ 1e-18, 1e-15, 1e-12 }) |g| {
            var b = Builder.init(testing.allocator);
            const c = b.addNode();
            const base = b.addNode();
            const e = b.addNode();
            const substrate = b.addNode();
            try b.addDevice(Bjt, .{ .typeZ = polarity, .subs = subs, .gmin = g }, .{}, .{ c, base, e, substrate });
            var ckt = try b.compile();
            defer ckt.deinit();
            for (ckt.current_row) |is_current| try testing.expect(!is_current);
            const x = try testing.allocator.alloc(f64, ckt.n);
            defer testing.allocator.free(x);
            @memset(x, 0);
            const sign: f64 = @floatFromInt(polarity);
            x[c] = sign * 1.5;
            x[base] = sign * 0.55;
            x[substrate] = sign * 0.2;
            ckt.eval(x, 0);
            const reference = if (subs > 0) c else base;
            const tol = g * 1e-12;
            try testing.expectApproxEqAbs(g * (x[substrate] - x[reference]), ckt.rhs[substrate], tol);
            for ([_]u32{ c, base, e, substrate }) |col| {
                const expected: f64 = if (col == substrate) g else if (col == reference) -g else 0;
                try testing.expectApproxEqAbs(expected, ckt.g_vals[ckt.findSlot(substrate, col).?], tol);
            }
        }
    };
}

test "scatter: grounded limiting derivatives survive cached and uncached evaluation" {
    const td = @import("testdev.zig");
    // Same nonlinear function on current and charge: both limiting corrections
    // must retain the grounded derivative, including on a cache hit.
    const D = struct {
        pub const U = td.Dp.U;
        pub const num_ports = td.Dp.num_ports;
        pub const Model = td.Dp.Model;
        pub const Instance = td.Dp.Instance;
        pub const PrepCache = td.Dp.PrepCache;
        pub const computePrep = td.Dp.computePrep;
        pub const evalFromPrep = td.Dp.evalFromPrep;
        pub const qFromPrep = evalFromPrep;
        pub const limit = td.Dp.limit;
        pub const q = eval;
        pub fn eval(comptime F: type, x: [2]F, m: *const Model, inst: *const Instance, t: f64) [2]F {
            return evalFromPrep(F, x, &computePrep(m, inst), m, inst, t);
        }
    };
    for ([_]usize{ 1, 2 }) |copies| {
        var b = Builder.init(testing.allocator);
        const p = b.addNode();
        const n = b.addNode();
        // Same local voltages, different ground maps. Four diodes enable dedup.
        for (0..copies) |_| for ([_]u32{ 0, p }) |anode| {
            try b.addDevice(D, .{}, .{}, .{ anode, n });
        };
        var ckt = try b.compile();
        defer ckt.deinit();
        const x = try testing.allocator.alloc(f64, ckt.n);
        defer testing.allocator.free(x);
        @memset(x, 0);
        const old = try testing.allocator.dupe(f64, x);
        defer testing.allocator.free(old);
        x[n] = -1;
        try testing.expect(ckt.applyLimits(x, old));
        ckt.evalNewton(x, 0);

        // pnjlim moves the local anode from 0 to -0.4, even when grounded.
        // Its derivative must still contribute +0.4*g to the active cathode.
        const pc = td.Dp.computePrep(&.{}, &.{});
        const exp = @exp(0.6 * pc.inv_vt);
        const g = pc.is * exp * pc.inv_vt;
        const current = pc.is * (exp - 1) + 0.4 * g;
        const count: f64 = @floatFromInt(copies);
        for ([_][]const f64{ ckt.rhs, ckt.q_vec }) |plane| {
            try testing.expectApproxEqRel(count * current, plane[p], 1e-12);
            try testing.expectApproxEqRel(-2 * count * current, plane[n], 1e-12);
        }
        // Every local row is recorded, including ground and cache hits.
        for (ckt.batches) |batch| {
            const tape = batch.hooks.q_tape.?(batch.ctx);
            try testing.expectEqual(4 * copies, tape.len);
            for (tape) |charge| try testing.expectApproxEqRel(current, @abs(charge), 1e-12);
        }
        for ([_][]const f64{ ckt.g_vals, ckt.c_vals }) |plane| {
            try testing.expectApproxEqRel(count * g, plane[ckt.findSlot(p, p).?], 1e-12);
            try testing.expectApproxEqRel(-count * g, plane[ckt.findSlot(p, n).?], 1e-12);
            try testing.expectApproxEqRel(2 * count * g, plane[ckt.findSlot(n, n).?], 1e-12);
        }
    }
}

test "zero scatter preserves signed zero, subnormals and NaN quieting" {
    const D = struct {
        pub const U = enum(u8) { p };
        pub const Model = struct {};
        pub const Instance = struct {};
    };
    const bits = [_]u64{
        0,                  0x8000000000000000, 1,                  0x8000000000000001,
        0x3ff0000000000000, 0xbff0000000000000, 0x7ff0000000000000, 0xfff0000000000000,
        0x7ff8000000000001, 0x7ff0000000000001,
    };
    inline for (.{ false, true }) |device| {
        const Sk = devices.engine.Sink(D, device, false);
        for (bits) |initial| for (bits) |stamp| {
            var actual = [_]f64{@bitCast(initial)};
            const v: f64 = @bitCast(stamp);
            var expected = actual;
            if (comptime device) {
                _ = @atomicRmw(f64, &expected[0], .Add, v, .monotonic);
            } else expected[0] += v;
            var sink: Sk = undefined;
            sink.rhs = &actual;
            sink.scatterRes(0, v);
            try std.testing.expectEqual(@as(u64, @bitCast(expected[0])), @as(u64, @bitCast(actual[0])));
        };
    }
}
