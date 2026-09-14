const std = @import("std");
const testing = std.testing;
const devices = @import("devices");
const Builder = @import("builder").Builder;
const Bjt = devices.byName("bjt");
const n_u = @typeInfo(Bjt.U).@"enum".fields.len;
const S = devices.engine.Dual(n_u, f64);

// The two BJT collapse tests below assert VerA's `collapse_applied` contract
// (VerA tools/contract.zig:75-79): "the host has applied this device's
// collapse() aliases to its gather and scatter maps. Generated physics then
// OMITS the short's cancelling stamps, preserving arbitrarily small
// conductances already in the same matrix slot."
//
// They FAIL against the current VerA, which no longer emits that omission —
// codegen.zig emitSwitchRow now states "the matrix STRUCTURE stays constant:
// the branch always carries its flow unknown I_b", so every switch branch
// keeps its flow unknown and its unconditional +-I_b KCL stamps, and
// emitCollapse guards `out[flow] = root` behind the short's own flag.
// A generated mos1.zig still in .zig-cache from 2026-09-07 emits the
// contract-honouring form (the `if (comptime !(@hasDecl(S,
// "collapse_applied") and S.collapse_applied))` split plus an unconditional
// `out[flow] = root`); today's does not. Nothing on this side changed:
// Builder.addDevice must allocate a matrix node for every unknown collapse()
// did not alias, because the generated eval reads x[flow] and writes
// res[flow] whenever the alias is absent.
//
// Consequences these two tests measure, in order:
//   1. one extra unknown + row per retained (non-shorted) parasitic;
//   2. when the short IS taken, res[hi] += ib and res[lo] -= ib both land on
//      the collapsed root row with ib = x[root] (a VOLTAGE, ~1e-1), so a
//      conductance already in that accumulator is rounded away before the
//      cancellation completes: 3.5e-19 + (-0.2) + (-0.2) + 0.2 + 0.2 == 0.
// Fix belongs in VerA codegen, not here. Do not weaken these to green.
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
            // RB keeps bi; only a live filter needs xf1/xf2. The retained
            // branch's flow unknown is NOT one of them: with the potential arm
            // statically dead, `I(b,bi) <+ V(b,bi)/rbb` is a conductance and
            // wants no current row. Current VerA yields 2 and 6 (one surplus
            // flow unknown each) — see the note above this test.
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
            // Tolerance is relative to g, deliberately: the substrate leak is
            // the ONLY thing this row should carry. Anything the collapsed
            // shorts add and subtract on the way past must not cost it digits.
            const tol = g * 1e-12;
            try testing.expectApproxEqAbs(g * (x[substrate] - x[reference]), ckt.rhs[substrate], tol);
            for ([_]u32{ c, base, e, substrate }) |col| {
                const expected: f64 = if (col == substrate) g else if (col == reference) -g else 0;
                try testing.expectApproxEqAbs(expected, ckt.g_vals[ckt.findSlot(substrate, col).?], tol);
            }
        }
    };
}

test "scatter: grounded limiting derivatives survive evaluation" {
    const td = @import("testdev.zig");
    // Same nonlinear function on current and charge: both limiting corrections
    // must retain the grounded derivative.
    const D = struct {
        pub const U = td.D.U;
        pub const num_ports = td.D.num_ports;
        pub const Model = td.D.Model;
        pub const Instance = td.D.Instance;
        pub const limit = td.D.limit;
        pub const eval = td.D.eval;
        pub const q = td.D.eval;
    };
    for ([_]usize{ 1, 2 }) |copies| {
        var b = Builder.init(testing.allocator);
        const p = b.addNode();
        const n = b.addNode();
        // Same local voltages, different ground maps: the grounded anode row is
        // the one whose derivative the limiting correction must still carry.
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
        const inv_vt = 1.0 / 0.02585;
        const is: f64 = (D.Model{}).is;
        const exp = @exp(0.6 * inv_vt);
        const g = is * exp * inv_vt;
        const current = is * (exp - 1) + 0.4 * g;
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
            // Both instantiations round identically now, and the device arm no
            // longer accumulates into the plane at all: the deterministic
            // scatter writes ONE staging cell per contribution, touched by
            // exactly one thread, and a separate ordered reduce sums them. The
            // `@atomicRmw` this used to compare against was the oracle for a
            // sink that no longer exists. The `inline for (.{false, true})`
            // still earns its keep — it now pins that the two sinks agree
            // bit-for-bit on signed zero, subnormals and NaN quieting.
            expected[0] += v;
            var sink: Sk = undefined;
            sink.rhs = &actual;
            sink.scatterRes(0, v);
            try std.testing.expectEqual(@as(u64, @bitCast(expected[0])), @as(u64, @bitCast(actual[0])));
        };
    }
}

// The reduced derivative basis (docs/perf/rank4-2026-09-10.md). With
// RD = RS = 0 mos1's node collapse makes `di ≡ d` and `si ≡ s`, so the true
// rank is 4 and `evalRange` runs at `@Vector(4, f64)`. With RD/RS live it is
// not, and `benchmark/fixtures/convergence/mos_series_r` is the deck-level
// guard. This is the unit-level one, and it pins the part the deck cannot:
// that a MIXED batch still sorts each instance under its own basis.
test "collapse rank: a mixed batch narrows only the collapsed instances" {
    const M = devices.byName("mos1");
    const card: M.Model = .{ .vto = 0.7, .kp = 110e-6, .gamma = 0.4, .phi = 0.65, .w = 20e-6, .l = 1e-6 };
    var live = card;
    live.rd = 12;
    live.rs = 9;
    const inst: M.Instance = .{};

    // Same device, same node numbers, same bias — once alone, once behind a
    // collapsed instance that forces the batch through the partition. The
    // stamps must be bit-for-bit equal: a partition that mis-sorts, or a
    // narrow basis leaking onto a device whose internal nodes are live, moves
    // them (the settled table measured 3150 bit mismatches at rd=12/rs=9).
    var out: [2][4]f64 = undefined;
    var n: [2]u32 = undefined;
    for ([_]bool{ false, true }, 0..) |crowded, run| {
        var b = Builder.init(testing.allocator);
        // The collapsed instance goes FIRST in add order and on its own nodes,
        // so it shares no matrix slot with the device under test.
        if (crowded) {
            const nodes = [_]u32{ b.addNode(), b.addNode(), b.addNode(), b.addNode() };
            try b.addDevice(M, card, inst, nodes);
        }
        const d = b.addNode();
        const g = b.addNode();
        const s = b.addNode();
        try b.addDevice(M, live, inst, [4]u32{ d, g, s, 0 });
        var ckt = try b.compile();
        defer ckt.deinit();

        const x = try testing.allocator.alloc(f64, ckt.n);
        defer testing.allocator.free(x);
        @memset(x, 0);
        x[d] = 3.0;
        x[g] = 2.0;
        ckt.evalNewton(x, 0);
        out[run] = .{
            ckt.rhs[d],
            ckt.rhs[s],
            ckt.g_vals[ckt.findSlot(d, d).?],
            ckt.g_vals[ckt.findSlot(d, g).?],
        };
        n[run] = ckt.n;
    }
    // The collapsed instance really is collapsed: it added its four ports and
    // NO internal node, which is the precondition for the narrow basis.
    try testing.expectEqual(n[0] + 4, n[1]);
    // Nonzero, so the comparison is not two zeros agreeing.
    try testing.expect(out[0][2] != 0);
    for (out[0], out[1]) |a, c|
        try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(c)));
}
