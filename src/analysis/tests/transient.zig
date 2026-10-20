//! Transient-family unit tests: envelope, matex, tran and tran_noise.
//! Oracles: each vector kernel's W == 1 instantiation (bit for bit), closed
//! forms for `expmSmall` (identity, diagonal, nilpotent, rotation),
//! ngspice's `cktterr.c` coefficient tables, the theoretical convergence
//! order of every integrator on an RC discharge, and real generated
//! devices for the SimState, event and display paths.

const EnvelopeTests = struct {
    const impl = @import("../tran/envelope.zig");
    const Options = @import("core").query.Envelope;
    const maxPoints = impl.maxPoints;
    const std = @import("std");
    const testing = std.testing;

    test "envelope: maxPoints monotone in max_outer_steps" {
        const base: Options = .{ .t_carrier = 1e-9, .t_stop = 1e-3 };
        const mp1 = maxPoints(base);
        var opts2 = base;
        opts2.max_outer_steps = 100;
        const mp2 = maxPoints(opts2);
        try testing.expect(mp2 <= mp1);
    }

    test "envelope: maxPoints leaves room for DC and one step" {
        const opts: Options = .{
            .t_carrier = 1e-6,
            .t_stop = 1e-3,
            .min_periods_per_step = 1,
            .max_periods_per_step = 32,
        };
        const mp = maxPoints(opts);
        try testing.expect(mp >= 3); // at least DC + one step + slack
    }

    test "envelope: stepCount covers the window without a roundoff step" {
        const stepCount = impl.test_access.stepCount;
        // A fine window that came out of a subtraction is a carrier period
        // only to roundoff; it still takes carrier_steps_per_period steps.
        const t_carrier: f64 = 1e-6;
        const dt = t_carrier / 64.0;
        for ([_]f64{ 3, 37, 1001 }) |k| {
            const t_target = k * t_carrier;
            try testing.expectEqual(@as(u32, 64), stepCount(t_target - (t_target - t_carrier), dt));
        }
        // Ten additions of 0.1 sum to 0.9999999999999999, which made an
        // accumulating loop take an eleventh step.
        var acc: f64 = 0;
        for (0..10) |_| acc += 0.1;
        try testing.expect(acc < 1.0);
        try testing.expectEqual(@as(u32, 10), stepCount(1.0, 0.1));
        // A partial window still takes its last, overshooting step, and a
        // window shorter than one step takes exactly one.
        try testing.expectEqual(@as(u32, 3), stepCount(2.5 * dt, dt));
        try testing.expectEqual(@as(u32, 1), stepCount(1e-3 * dt, dt));
    }

    test "envelope: maxPoints bounds the rows a run can write" {
        // t_stop / (min_periods * t_carrier) outer steps, plus DC and slack.
        // Binary-exact times, so the ceil sees exactly 25.
        const opts: Options = .{ .t_carrier = 0.25, .t_stop = 25, .min_periods_per_step = 4, .max_periods_per_step = 16, .periods_per_outer_step = 4 };
        try testing.expectEqual(@as(u32, 25 + 2), maxPoints(opts));
        var capped = opts;
        capped.max_outer_steps = 3;
        try testing.expectEqual(@as(u32, 3 + 2), maxPoints(capped));
    }
};

const MatexTests = struct {
    const impl = @import("../tran/matex.zig");
    const denseMatMul = impl.test_access.denseMatMul;
    const expmSmall = impl.test_access.expmSmall;
    const std = @import("std");
    const testing = std.testing;

    test "expmSmall: an inf or NaN entry is refused, not halved forever (#125)" {
        var H = [_]f64{ std.math.inf(f64), 0, 0, 1 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined;
        var piv: [3]u32 = undefined;
        try testing.expect(!expmSmall(2, &H, &out, &scratch, &piv));
        H = .{ 1, -std.math.inf(f64), 0, 1 };
        try testing.expect(!expmSmall(2, &H, &out, &scratch, &piv));
        H = .{ 1, 0, std.math.nan(f64), 1 };
        try testing.expect(!expmSmall(2, &H, &out, &scratch, &piv));
    }

    test "expmSmall: the largest finite entry still terminates" {
        var H = [_]f64{ std.math.floatMax(f64), 0, 0, 0 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined;
        var piv: [3]u32 = undefined;
        // e^(huge) overflows to inf; the point is the bounded scaling loop.
        _ = expmSmall(2, &H, &out, &scratch, &piv);
    }

    test "expmSmall: identity" {
        // expm(0) = I
        var H = [_]f64{ 0, 0, 0, 0 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined; // 5*2*2 = 20
        var piv: [3]u32 = undefined;
        try testing.expect(expmSmall(2, &H, &out, &scratch, &piv));
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[0], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[3], 1e-12);
    }

    test "expmSmall: diagonal" {
        // expm(diag(1,2)) = diag(e, e^2)
        var H = [_]f64{ 1, 0, 0, 2 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined;
        var piv: [3]u32 = undefined;
        try testing.expect(expmSmall(2, &H, &out, &scratch, &piv));
        // Padé(6,6) + scaling-squaring: ~1e-10 on the small matrix
        try testing.expectApproxEqRel(std.math.e, out[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-10);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-10);
        try testing.expectApproxEqRel(std.math.e * std.math.e, out[3], 1e-6);
    }

    test "expmSmall: 1x1" {
        var H = [_]f64{1.0};
        var out: [1]f64 = undefined;
        var scratch: [5]f64 = undefined; // 5*1*1
        var piv: [3]u32 = undefined;
        try testing.expect(expmSmall(1, &H, &out, &scratch, &piv));
        try testing.expectApproxEqRel(std.math.e, out[0], 1e-6);
    }

    test "expmSmall: 3x3 nilpotent" {
        // H = [[0,1,0],[0,0,1],[0,0,0]] — nilpotent, expm = I + H + H²/2
        // expm = [[1,1,0.5],[0,1,1],[0,0,1]]
        var H = [_]f64{ 0, 1, 0, 0, 0, 1, 0, 0, 0 };
        var out: [9]f64 = undefined;
        var scratch: [45]f64 = undefined; // 5*3*3
        var piv: [3]u32 = undefined;
        try testing.expect(expmSmall(3, &H, &out, &scratch, &piv));
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[0], 1e-12); // [0,0]
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[1], 1e-12); // [0,1]
        try testing.expectApproxEqAbs(@as(f64, 0.5), out[2], 1e-12); // [0,2]
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-12); // [1,0]
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[4], 1e-12); // [1,1]
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[5], 1e-12); // [1,2]
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[6], 1e-12); // [2,0]
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[7], 1e-12); // [2,1]
        try testing.expectApproxEqAbs(@as(f64, 1.0), out[8], 1e-12); // [2,2]
    }

    test "expmSmall: scaled diagonal needs squaring" {
        // expm(diag(5,5)) = diag(e^5, e^5) — forces scaling-squaring
        var H = [_]f64{ 5, 0, 0, 5 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined;
        var piv: [3]u32 = undefined;
        try testing.expect(expmSmall(2, &H, &out, &scratch, &piv));
        const e5 = @exp(@as(f64, 5.0));
        try testing.expectApproxEqRel(e5, out[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-6);
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-6);
        try testing.expectApproxEqRel(e5, out[3], 1e-6);
    }

    test "expmSmall: antisymmetric (rotation)" {
        // H = [[0, -pi/4], [pi/4, 0]] => expm is rotation by pi/4
        // expm = [[cos(pi/4), -sin(pi/4)], [sin(pi/4), cos(pi/4)]]
        const angle = std.math.pi / 4.0;
        var H = [_]f64{ 0, -angle, angle, 0 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined;
        var piv: [3]u32 = undefined;
        try testing.expect(expmSmall(2, &H, &out, &scratch, &piv));
        const c = @cos(angle);
        const s_val = @sin(angle);
        try testing.expectApproxEqRel(c, out[0], 1e-6);
        try testing.expectApproxEqRel(-s_val, out[1], 1e-6);
        try testing.expectApproxEqRel(s_val, out[2], 1e-6);
        try testing.expectApproxEqRel(c, out[3], 1e-6);
    }

    test "denseMatMul: identity times A" {
        const A = [_]f64{ 1, 2, 3, 4 };
        const I = [_]f64{ 1, 0, 0, 1 };
        var C: [4]f64 = undefined;
        denseMatMul(2, &I, &A, &C);
        try testing.expectApproxEqAbs(@as(f64, 1.0), C[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 2.0), C[1], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 3.0), C[2], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 4.0), C[3], 1e-15);
    }

    test "denseMatMul: vector path is bit-identical to the scalar oracle" {
        // Covers m below W, at W, straddling W (vector body + scalar tail) and
        // several full vectors. Exact equality, not approx: lanes accumulate the
        // same k order the scalar loop does.
        const a = testing.allocator;
        for ([_]usize{ 1, 2, 3, 5, 8, 9, 16, 17, 31 }) |m| {
            const A = try a.alloc(f64, m * m);
            defer a.free(A);
            const B = try a.alloc(f64, m * m);
            defer a.free(B);
            const C = try a.alloc(f64, m * m);
            defer a.free(C);
            const want = try a.alloc(f64, m * m);
            defer a.free(want);

            var seed: u64 = 0x9E3779B97F4A7C15;
            for (A, 0..) |*v, i| {
                seed = seed *% 6364136223846793005 +% 1442695040888963407;
                v.* = @as(f64, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(seed >> 20)))))) * 1e-7 + @as(f64, @floatFromInt(i));
            }
            for (B, 0..) |*v, i| {
                seed = seed *% 6364136223846793005 +% 1442695040888963407;
                v.* = @as(f64, @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(seed >> 20)))))) * 3e-7 - @as(f64, @floatFromInt(i));
            }

            for (0..m) |i| {
                for (0..m) |j| {
                    var sum: f64 = 0;
                    for (0..m) |k| sum += A[i * m + k] * B[k * m + j];
                    want[i * m + j] = sum;
                }
            }

            denseMatMul(m, A, B, C);
            try testing.expectEqualSlices(f64, want, C);
        }
    }

    test "cscMulVec: matches the dense product, zero columns skipped" {
        // [[1 0 2], [0 3 0], [4 0 5]] in CSC.
        const col_ptr = [_]u32{ 0, 2, 3, 5 };
        const row_idx = [_]u32{ 0, 2, 1, 0, 2 };
        const vals = [_]f64{ 1, 4, 3, 2, 5 };
        const x = [_]f64{ 1, 0, -1 };
        var y: [3]f64 = @splat(std.math.nan(f64)); // overwritten, not accumulated
        impl.test_access.cscMulVec(3, &col_ptr, &row_idx, &vals, &x, &y);
        try testing.expectEqualSlices(f64, &.{ -1, 0, -1 }, &y);
    }
};

const TranTests = struct {
    const impl = @import("../tran/tran.zig");
    const W = impl.test_access.W;
    const Waveform = impl.Waveform;
    const integrator = impl.test_access.integrator;
    const root = @import("../types.zig");
    const simulate = impl.simulate;
    const Method = @import("core").query.Method;
    const std = @import("std");
    const testing = std.testing;

    test "almostEqualUlps counts representable doubles, as ngspice's does" {
        const eq = impl.test_access.almostEqualUlps;
        const x: f64 = 1.0e-9;
        try std.testing.expect(eq(x, std.math.nextAfter(f64, x, 1), 1));
        var y = x;
        for (0..3) |_| y = std.math.nextAfter(f64, y, 0);
        try std.testing.expect(eq(x, y, 3));
        try std.testing.expect(!eq(x, y, 2));
        try std.testing.expect(eq(0.0, -0.0, 1));
        try std.testing.expect(!eq(1.0, 1.0 + 1e-12, 100));
    }

    test "waveform: doubling fallback keeps the rows intact" {
        const allocator = testing.allocator;
        var waveform = try Waveform.init(allocator, 2, 2);
        defer waveform.deinit();

        const probes = [_]u32{ 0, 1 };
        for (0..10) |i| {
            const fi: f64 = @floatFromInt(i);
            const xv = [_]f64{ fi, 100.0 + fi };
            try waveform.record(fi * 1e-9, &xv, &probes);
        }

        try testing.expectEqual(@as(u32, 10), waveform.len);
        try testing.expect(waveform.capacity >= 10);
        for (0..10) |i| {
            const fi: f64 = @floatFromInt(i);
            try testing.expectApproxEqAbs(fi * 1e-9, waveform.column(0).at(i), 1e-24);
            try testing.expectApproxEqAbs(fi, waveform.column(1).at(i), 1e-15);
            try testing.expectApproxEqAbs(100.0 + fi, waveform.column(2).at(i), 1e-15);
        }
    }

    test "waveform: data is the point-major result rows, borrowed" {
        const allocator = testing.allocator;
        const n_probes = 5;
        var waveform = try Waveform.init(allocator, n_probes, 70);
        defer waveform.deinit();

        var xv: [n_probes]f64 = undefined;
        const probes = [_]u32{ 0, 1, 2, 3, 4 };
        for (0..70) |i| {
            for (&xv, 0..) |*v, k| v.* = @as(f64, @floatFromInt(i)) * 10.0 + @as(f64, @floatFromInt(k));
            try waveform.record(@as(f64, @floatFromInt(i)) * 1e-9, &xv, &probes);
        }

        const ncols = n_probes + 1;
        const rows = waveform.data();
        try testing.expectEqual(@as(usize, 70 * ncols), rows.len);
        try testing.expectEqual(@intFromPtr(waveform.rows.ptr), @intFromPtr(rows.ptr));
        for (0..70) |p| {
            try testing.expectEqual(@as(f64, @floatFromInt(p)) * 1e-9, rows[p * ncols]);
            for (0..n_probes) |k| {
                const want = @as(f64, @floatFromInt(p)) * 10.0 + @as(f64, @floatFromInt(k));
                try testing.expectEqual(want, rows[p * ncols + k + 1]);
            }
        }
    }

    test "predict: matches cur + xfact*(cur - prev) bit for bit at every length and offset" {
        var prng = std.Random.DefaultPrng.init(0x9ed1);
        const r = prng.random();
        const L = 200;
        var cur: [L + 3]f64 = undefined;
        var prev: [L + 3]f64 = undefined;
        for (&cur, &prev) |*c, *p| {
            c.* = (r.float(f64) - 0.5) * 10;
            p.* = (r.float(f64) - 0.5) * 10;
        }
        cur[5] = std.math.nan(f64);
        prev[9] = std.math.inf(f64);
        cur[17] = -0.0;
        prev[17] = 0.0;
        const xfact = 0.37;
        for (0..L) |len| for (0..4) |off| {
            const c = cur[off..][0..len];
            // `prev` may run past `cur`; only cur.len entries are read.
            const p = prev[off..][0 .. len + 3 - off];
            var got: [L]f64 = @splat(std.math.nan(f64));
            impl.test_access.predict(got[0..len], c, p, xfact);
            for (got[0..len], c, p[0..len]) |g, cv, pv| {
                const want = cv + xfact * (cv - pv);
                if (std.math.isNan(want)) {
                    try testing.expect(std.math.isNan(g));
                } else try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(g)));
            }
        };
    }

    /// R (1 kOhm) and C (1 nF) from node 1 to ground, tau = 1 us. The
    /// caller deinits it.
    fn rcCircuit(gpa: std.mem.Allocator) !root.Circuit {
        const models = @import("models");
        const evaluator = @import("device_eval");
        const RStore = evaluator.ProtoStore(models.resistor);
        const rstore = try gpa.create(RStore);
        rstore.* = .{};
        try rstore.append(&.{ .r = 1e3 }, &.{}, .{ 1, 0 });
        const CStore = evaluator.ProtoStore(models.capacitor);
        const cstore = try gpa.create(CStore);
        cstore.* = .{};
        try cstore.append(&.{ .c = 1e-9 }, &.{}, .{ 1, 0 });
        const protos = [_]evaluator.Proto{
            .{ .ctx = rstore, .type_name = @typeName(models.resistor), .pattern = RStore.addPattern, .finalize = RStore.finalize, .destroy = RStore.destroy, .apply_perm = RStore.applyPerm },
            .{ .ctx = cstore, .type_name = @typeName(models.capacitor), .pattern = CStore.addPattern, .finalize = CStore.finalize, .destroy = CStore.destroy, .apply_perm = CStore.applyPerm },
        };
        const intern_bytes = try gpa.dupe(u8, "00");
        const intern_offs = try gpa.dupe(u32, &.{ 0, 1, 2 });
        return root.freeze(gpa, 2, intern_bytes, intern_offs, &protos, &@as([protos.len]@import("device").DeviceType, @splat(.unset)), null);
    }

    /// One run of every transient-family entry over `ckt` from v(1) = 1,
    /// results on an arena over `gpa` and scratch on `gpa` itself.
    fn runFamily(gpa: std.mem.Allocator, ckt: *root.Circuit) !void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var x_op = [_]f64{ 0, 1 };
        const ctx: root.RunCtx = .{ .circuit = ckt, .x_op = &x_op, .probes = &.{1}, .source_node = 0, .source_branch = 0, .allocator = arena.allocator(), .scratch_allocator = gpa };
        _ = try impl.run(&ctx, .{ .t_stop = 2e-6, .dt_init = 2e-7 });
        _ = try impl.run(&ctx, .{ .t_stop = 2e-6, .dt_init = 2e-7, .snapshot = true });
        const noise = @import("../tran/tran_noise.zig");
        _ = try noise.run(&ctx, .{ .t_stop = 1e-6, .dt_init = 2e-7, .dt_max = 2e-7 });
        _ = try noise.run(&ctx, .{ .t_stop = 1e-6, .dt_init = 2e-7, .dt_max = 2e-7, .sde = true, .out_node = 1 });
        _ = try @import("../tran/envelope.zig").run(&ctx, .{ .t_carrier = 2e-7, .t_stop = 1e-6, .carrier_steps_per_period = 4 });
        _ = try @import("../tran/matex.zig").run(&ctx, .{ .t_stop = 2e-6, .max_points = 64 });
    }

    test "tran, trannoise, envelope and matex: every allocation failure unwinds without a leak" {
        var ckt = try rcCircuit(testing.allocator);
        defer ckt.deinit();
        try testing.checkAllAllocationFailures(testing.allocator, runFamily, .{&ckt});
    }

    test "almostEqualUlps: the ulp count runs straight across zero" {
        const eq = impl.test_access.almostEqualUlps;
        const tiny = std.math.floatTrueMin(f64);
        try testing.expect(eq(-tiny, tiny, 2));
        try testing.expect(!eq(-tiny, tiny, 1));
        try testing.expect(eq(-0.0, tiny, 1));
        // Opposite extremes are 2^64 - 2^53 - 2 apart: no i64 overflow.
        try testing.expect(!eq(-std.math.floatMax(f64), std.math.floatMax(f64), std.math.maxInt(i64)));
        // Identical NaN bits count as equal, as in ngspice: 0 ulps apart.
        try testing.expect(eq(std.math.nan(f64), std.math.nan(f64), 0));
    }

    test "column: lowerBound, from and strided reads" {
        const Column = impl.Column;
        // Rows (t, v): the t column has stride 2.
        const rows = [_]f64{ 0, 10, 1, 11, 1, 12, 3, 13 };
        const t: Column = .{ .base = &rows, .stride = 2, .len = 4 };
        try testing.expectEqual(@as(usize, 0), t.lowerBound(-1));
        try testing.expectEqual(@as(usize, 1), t.lowerBound(1)); // first of the duplicates
        try testing.expectEqual(@as(usize, 3), t.lowerBound(2));
        try testing.expectEqual(@as(usize, 4), t.lowerBound(4));
        try testing.expectEqual(@as(usize, 0), Column.of(&.{}).lowerBound(1));
        try testing.expectEqual(@as(usize, 4), t.lowerBound(std.math.nan(f64)));
        const v: Column = .{ .base = rows[1..], .stride = 2, .len = 4 };
        try testing.expectEqual(@as(f64, 13), v.from(2).at(1));
        try testing.expectEqual(@as(usize, 0), v.from(4).len);
    }

    test "initialCapacity: twice the window over dt_init, clamped to [64, 2^22]" {
        // Powers of two keep the quotient exact; the hint truncates.
        try testing.expectEqual(@as(u32, 2048), impl.initialCapacity(.{ .t_stop = 1024, .dt_init = 1 }));
        try testing.expectEqual(@as(u32, 1024), impl.initialCapacity(.{ .t_stop = 1024, .t_start = 512, .dt_init = 1 }));
        try testing.expectEqual(@as(u32, 64), impl.initialCapacity(.{ .t_stop = 1e-9, .dt_init = 1e-9 }));
        try testing.expectEqual(@as(u32, 1 << 22), impl.initialCapacity(.{ .t_stop = 1, .dt_init = 1e-12 }));
    }

    test "waveform: a failed grow appends nothing" {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
        var waveform = try Waveform.init(failing.allocator(), 1, 2);
        defer waveform.deinit();
        const probes = [_]u32{0};
        try waveform.record(0, &.{1}, &probes);
        try waveform.record(1, &.{2}, &probes);
        try testing.expectError(error.OutOfMemory, waveform.record(2, &.{3}, &probes));
        try testing.expectEqual(@as(u32, 2), waveform.len);
        try testing.expectEqualSlices(f64, &.{ 0, 1, 1, 2 }, waveform.data());
    }

    test "waveform: a stream keeps no rows" {
        var buf: [6 * @sizeOf(f64)]u8 align(@alignOf(f64)) = undefined;
        var sink: std.Io.Writer = .fixed(&buf);
        var wf = try Waveform.initStream(testing.allocator, 2, &sink);
        defer wf.deinit();
        const probes = [_]u32{ 2, 0 };
        try wf.record(0.5, &.{ 0.5, 9, 5 }, &probes);
        try wf.record(1, &.{ 2, 9, 8 }, &probes);
        try testing.expectEqual(@as(u32, 2), wf.len);
        try testing.expectEqual(@as(usize, 0), wf.data().len);
        const got: []const f64 = @alignCast(std.mem.bytesAsSlice(f64, sink.buffered()));
        try testing.expectEqualSlices(f64, &.{ 0.5, 5, 0.5 }, got[0..3]);
        try testing.expectEqualSlices(f64, &.{ 1, 8, 2 }, got[3..6]);
    }

    test "advanceCurrent: trapezoid in place over its own i_prev" {
        const cap = 3 * W + 2;
        var q0: [cap]f64 = undefined;
        var q1: [cap]f64 = undefined;
        var i_cur: [cap]f64 = undefined;
        for (0..cap) |j| {
            const fj: f64 = @floatFromInt(j);
            q0[j] = fj * 1e-12;
            q1[j] = -fj * 0.5e-12;
            i_cur[j] = fj * 1e-3;
        }
        var want = i_cur;
        const c: integrator.Coeffs = .{ .ag0 = 2e9, .ag2 = 0 };
        for (&want, q0, q1) |*w, a, b| w.* = c.ag0 * (a - b) - c.ag1 * w.*;
        integrator.advanceCurrent(.trapezoidal, &i_cur, &q0, &q1, &.{}, c);
        try testing.expectEqualSlices(u64, @ptrCast(&want), @ptrCast(&i_cur));
    }

    test "rebaseCurrent: bit-identical to the per-element formula at every length" {
        var prng = std.Random.DefaultPrng.init(0x7e1a);
        const r = prng.random();
        // Lengths straddle the vector width so every tail length runs.
        for (0..3 * W + 2) |len| {
            var q_new: [3 * W + 2]f64 = undefined;
            var q_old: [3 * W + 2]f64 = undefined;
            var vec: [3 * W + 2]f64 = undefined;
            for (0..len) |j| {
                q_new[j] = (r.float(f64) - 0.5) * 1e-12;
                q_old[j] = (r.float(f64) - 0.5) * 1e-12;
                vec[j] = (r.float(f64) - 0.5) * 1e-3;
            }
            if (len > 0) q_new[0] = -0.0; // signed zero and NaN propagate lanewise
            if (len > 1) q_old[len - 1] = std.math.nan(f64);
            var ora = vec;
            const alpha = 2.0 / (r.float(f64) * 1e-9 + 1e-12);
            integrator.rebaseCurrent(vec[0..len], q_new[0..len], q_old[0..len], alpha);
            for (ora[0..len], q_new[0..len], q_old[0..len]) |*o, a, b| o.* = o.* + alpha * (a - b);
            try testing.expectEqualSlices(u64, @ptrCast(ora[0..len]), @ptrCast(vec[0..len]));
        }
    }

    test "stepBound: vector kernel is bit-identical to its w=1 oracle" {
        var prng = std.Random.DefaultPrng.init(0x5b0d);
        const r = prng.random();
        const L = 3 * W + 2;
        var q: [4][L]f64 = undefined;
        var ip: [L]f64 = undefined;
        for (&q) |*h| for (h) |*v| {
            v.* = (r.float(f64) - 0.5) * 1e-12;
        };
        for (&ip) |*v| v.* = (r.float(f64) - 0.5) * 1e-3;
        const lte: integrator.LteIn = .{ .dt = 1.3e-9, .dt1 = 0.7e-9, .dt2 = 2.1e-9, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
        const c: integrator.Coeffs = .{ .ag0 = 1.1e9, .ag2 = 0.3e9 };
        // Lengths straddle the vector width so every tail length runs; the
        // min can land in the vector body or the tail.
        for (1..L + 1) |len| {
            const s: [4][]const f64 = .{ q[0][0..len], q[1][0..len], q[2][0..len], q[3][0..len] };
            for ([_]Method{ .backward_euler, .trapezoidal, .gear_2 }) |m| for ([_]Method{ .backward_euler, .trapezoidal, .gear_2 }) |cm| {
                const vec = integrator.stepBound(W, m, cm, s, ip[0..len], c, lte);
                const ora = integrator.stepBound(1, m, cm, s, ip[0..len], c, lte);
                try testing.expectEqual(@as(u64, @bitCast(ora)), @as(u64, @bitCast(vec)));
            };
        }
    }

    // A NaN or inf charge or current must not vanish into the min: a float
    // @min or @max drops NaN, which would accept the step at a growing dt.
    test "stepBound: a non-finite history entry gives a NaN bound" {
        const L = 2 * 8 + 3; // vector body and tail at every lane width
        const lte: integrator.LteIn = .{ .dt = 1e-9, .dt1 = 1e-9, .dt2 = 1e-9, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
        const c: integrator.Coeffs = .{ .ag0 = 1e9, .ag2 = 0.5e9 };
        const methods = [_]Method{ .backward_euler, .trapezoidal, .gear_2 };
        for (methods) |m| for (0..5) |slot| for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |bad| for ([_]usize{ 0, L - 1 }) |at| {
            // Backward Euler's divided difference never reads prev3.
            if (m == .backward_euler and slot == 3) continue;
            var h: [5][L]f64 = undefined;
            for (&h, 0..) |*col, k| for (col, 0..) |*v, j| {
                v.* = @as(f64, @floatFromInt(j + 1)) * 1e-12 / @as(f64, @floatFromInt(k + 1));
            };
            h[slot][at] = bad;
            const del = integrator.stepBound(W, m, m, .{ &h[0], &h[1], &h[2], &h[3] }, &h[4], c, lte);
            try testing.expect(std.math.isNan(del));
        };
    }

    test "companionAt: every method, both modes, matches its per-element formula bit for bit" {
        var prng = std.Random.DefaultPrng.init(0xc0a1);
        const r = prng.random();
        const cap = 3 * W + 2;
        inline for (comptime std.enums.values(Method)) |m| {
            inline for (.{ false, true }) |acc| for (0..cap) |len| {
                var q: [3][cap]f64 = undefined;
                var ip: [cap]f64 = undefined;
                var out: [cap]f64 = undefined;
                for (0..len) |j| {
                    for (&q) |*h| h[j] = (r.float(f64) - 0.5) * 1e-12;
                    ip[j] = (r.float(f64) - 0.5) * 1e-3;
                    out[j] = (r.float(f64) - 0.5) * 1e-3;
                }
                const c: integrator.Coeffs = .{ .ag0 = 2.0 / (r.float(f64) * 1e-9 + 1e-12), .ag2 = r.float(f64) * 1e9 };
                var ora = out;
                // Every element, vector body and tail alike, sums (out + d) - h.
                for (0..len) |j| {
                    const d = c.ag0 * (q[0][j] - q[1][j]);
                    const h: f64 = switch (m) {
                        .backward_euler => 0,
                        .trapezoidal => ip[j],
                        .gear_2 => c.ag2 * (q[1][j] - q[2][j]),
                        else => q[2][j], // gear-3..6: q2 is `gearHistory`'s g
                    };
                    ora[j] = if (!acc) d - h else (ora[j] + d) - h;
                }
                integrator.companionAt(m, acc, out[0..len], q[0][0..len], q[1][0..len], q[2][0..len], ip[0..len], c);
                try testing.expectEqualSlices(u64, @ptrCast(ora[0..len]), @ptrCast(out[0..len]));
            };
        }
    }

    test "coeffs: BE 1/dt, trap 2/dt, gear-2 variable-step BDF2" {
        const dt: f64 = 1e-9;
        try testing.expectApproxEqRel(@as(f64, 1e9), integrator.coeffs(.backward_euler, dt, dt, 0.5).ag0, 1e-12);
        // xmu = 0.5 is the plain trapezoid bit for bit: 2/dt and a unit
        // history weight. xmu = 0 is backward Euler.
        for ([_]f64{ 1e-9, 3.7e-13, 0.1 }) |h| {
            const t = integrator.coeffs(.trapezoidal, h, h, 0.5);
            try testing.expectEqual(2.0 / h, t.ag0);
            try testing.expectEqual(@as(f64, 1), t.ag1);
        }
        try testing.expectEqual(@as(f64, 0), integrator.coeffs(.trapezoidal, dt, dt, 0).ag1);
        // r == 1 must reproduce the uniform-step BDF2 triple.
        const u = integrator.coeffs(.gear_2, dt, dt, 0.5);
        try testing.expectApproxEqRel(@as(f64, 1.5e9), u.ag0, 1e-12);
        try testing.expectApproxEqRel(@as(f64, 0.5e9), u.ag2, 1e-12);
        // On a non-uniform grid the corrector must be exact on constants (sum of
        // coefficients zero, ag1 = -(ag0+ag2)) and on the ramp q(t) = t through
        // the node spacing 0, dt1, dt1+dt.
        for ([_]f64{ 0.25, 0.5, 1.0, 2.0, 4.0 }) |r| {
            const dt1 = dt / r;
            const c = integrator.coeffs(.gear_2, dt, dt1, 0.5);
            const ag1 = -(c.ag0 + c.ag2);
            // q0 = 0, q1 = -dt, q2 = -(dt+dt1) as offsets from t_n: dq/dt == 1.
            const dqdt = c.ag0 * 0.0 + ag1 * (-dt) + c.ag2 * (-(dt + dt1));
            try testing.expectApproxEqRel(@as(f64, 1.0), dqdt, 1e-12);
            // BDF2 is exact through degree 2, so d/dt(t^2) at t_n is 0. The
            // surviving terms are O(dt) = 1e-9, so 1e-22 is rounding noise.
            const sq = c.ag0 * 0.0 + ag1 * (dt * dt) + c.ag2 * ((dt + dt1) * (dt + dt1));
            try testing.expectApproxEqAbs(@as(f64, 0.0), sq, 1e-22);
        }
    }

    test "gearAg: exact on every polynomial of degree <= k, any step history" {
        var prng = std.Random.DefaultPrng.init(0x6ea2);
        const r = prng.random();
        for (3..7) |k| for (0..20) |_| {
            var dts: [7]f64 = undefined;
            for (&dts) |*d| d.* = 1e-9 * (0.25 + 1.75 * r.float(f64));
            const ag = integrator.gearAg(@intCast(k), &dts);
            // d/dt (t - t_n)^p at t_n is 1 for p = 1, else 0; offsets in
            // units of dt keep each term O(1).
            for (0..k + 1) |p| {
                var sum: f64 = 0;
                var mag: f64 = 0;
                var s_i: f64 = 0;
                for (0..k + 1) |i| {
                    if (i > 0) s_i += dts[i - 1];
                    const term = ag[i] * std.math.pow(f64, -s_i / dts[0], @floatFromInt(p));
                    sum += term;
                    mag += @abs(term);
                }
                const want: f64 = if (p == 1) 1 / dts[0] else 0;
                try testing.expectApproxEqAbs(want, sum, 1e-11 * mag);
            }
            for (ag[k + 1 ..]) |a| try testing.expectEqual(@as(f64, 0), a);
        };
        // Equal steps give the textbook BDF3 row: (11/6, -3, 3/2, -1/3)/h.
        const ag3 = integrator.gearAg(3, &@as([3]f64, @splat(1)));
        for (ag3[0..4], [_]f64{ 11.0 / 6.0, -3, 1.5, -1.0 / 3.0 }) |a, want| try testing.expectApproxEqAbs(want, a, 1e-14);
    }

    test "gearHistory: the per-element sum it folds" {
        var prng = std.Random.DefaultPrng.init(0x91b7);
        const r = prng.random();
        var store: [7][5]f64 = undefined;
        for (&store) |*h| for (h) |*v| {
            v.* = r.float(f64) - 0.5;
        };
        var q: [7][]f64 = undefined;
        for (&q, &store) |*v, *h| v.* = h;
        const ag: [7]f64 = .{ 9, -4, 1.5, -0.25, 0.75, -2, 0.5 };
        for (3..7) |k| {
            var g: [5]f64 = undefined;
            integrator.gearHistory(&g, q[0 .. k + 1], ag);
            for (g, 0..) |got, j| {
                var want: f64 = 0;
                for (2..k + 1) |i| want += ag[i] * (store[1][j] - store[i][j]);
                try testing.expectApproxEqAbs(want, got, 1e-15);
            }
        }
    }

    // The general cktterr loop is the oracle of the vector kernel at orders
    // 1 and 2, bit for bit: the same divisions in the same order.
    test "stepBoundGear: matches stepBound bit for bit at orders 1 and 2" {
        var prng = std.Random.DefaultPrng.init(0x3c1e);
        const r = prng.random();
        const L = 2 * W + 3;
        var q: [4][L]f64 = undefined;
        var ip: [L]f64 = undefined;
        for (&q) |*h| for (h) |*v| {
            v.* = (r.float(f64) - 0.5) * 1e-12;
        };
        for (&ip) |*v| v.* = (r.float(f64) - 0.5) * 1e-3;
        const lte: integrator.LteIn = .{ .dt = 1.3e-9, .dt1 = 0.7e-9, .dt2 = 2.1e-9, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
        const dts = [_]f64{ lte.dt, lte.dt1, lte.dt2 };
        const c: integrator.Coeffs = .{ .ag0 = 1.1e9, .ag2 = 0.3e9 };
        const s: [4][]const f64 = .{ &q[0], &q[1], &q[2], &q[3] };
        const methods = [_]Method{ .backward_euler, .trapezoidal, .gear_2 };
        for (methods) |m| for (methods) |cm| {
            const want = integrator.stepBound(1, m, cm, s, &ip, c, lte);
            const got = integrator.stepBoundGear(m, cm, &s, &ip, &.{}, c, lte, &dts);
            try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
        };
    }

    test "stepBoundGear: a non-finite entry gives a NaN bound; a smooth history its order's root" {
        const L = 5;
        var h: [9][L]f64 = undefined; // 8 charge slots, then i_prev
        const dts: [7]f64 = @splat(1e-9);
        const lte: integrator.LteIn = .{ .dt = 1e-9, .dt1 = 1e-9, .dt2 = 1e-9, .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
        const c: integrator.Coeffs = .{ .ag0 = 1e9, .ag2 = 0 };
        var g: [L]f64 = @splat(0);
        for (3..7) |k| {
            const m = integrator.gear(@intCast(k));
            for (0..k + 2) |slot| for ([_]f64{ std.math.nan(f64), std.math.inf(f64) }) |bad| {
                for (&h, 0..) |*col, i| for (col, 0..) |*v, j| {
                    v.* = @as(f64, @floatFromInt(j + 1)) * 1e-12 / @as(f64, @floatFromInt(i + 1));
                };
                h[slot][L - 1] = bad;
                var q: [8][]const f64 = undefined;
                for (&q, h[0..8]) |*v, *col| v.* = col;
                try testing.expect(std.math.isNan(integrator.stepBoundGear(m, m, q[0 .. k + 2], &h[8], &g, c, lte, &dts)));
            };
            // q = t^(k+1) on a unit grid: the (k+1)-th divided difference is
            // exactly 1 (in units of dt^-(k+1)), so del = (trtol*tol/(coeff*1))^(1/k).
            var q: [8][]const f64 = undefined;
            var col: [8][1]f64 = undefined;
            for (&col, 0..) |*v, i| v[0] = std.math.pow(f64, -@as(f64, @floatFromInt(i)) * 1e-9, @floatFromInt(k + 1));
            for (&q, &col) |*v, *cc| v.* = cc;
            const ip = [_]f64{0};
            const del = integrator.stepBoundGear(m, .backward_euler, q[0 .. k + 2], &ip, g[0..1], c, lte, &dts);
            const i_new = c.ag0 * (col[0][0] - col[1][0]);
            const tol = @max(lte.abstol + lte.reltol * @abs(i_new), lte.reltol * @max(@max(@abs(col[0][0]), @abs(col[1][0])), lte.chgtol) / 1e-9);
            const want = std.math.pow(f64, lte.trtol * tol / @max(lte.abstol, integrator.lteCoeff(m)), 1 / @as(f64, @floatFromInt(k)));
            try testing.expectApproxEqRel(want, del, 1e-6);
        }
    }

    test "maxGrowth: under each order's measured zero-stability ratio" {
        const bound = [_]f64{ 2.414, 2.414, 1.618, 1.280, 1.127, 1.044 }; // orders 1..6 (gear-2's for 1..2)
        for (std.enums.values(Method)) |m| {
            try testing.expect(integrator.maxGrowth(m) < bound[integrator.order(m) - 1]);
        }
    }

    // Matches ngspice cktterr.c:24-34. gear_2 must read gearCoeff[1] (.2222222222), not
    // trapCoeff[1] (.08333333333), which would give a 1.63x looser dt bound.
    test "lteCoeff: ngspice gearCoeff/trapCoeff tables" {
        try testing.expectEqual(@as(f64, 0.5), integrator.lteCoeff(.backward_euler));
        try testing.expectEqual(@as(f64, 0.08333333333), integrator.lteCoeff(.trapezoidal));
        try testing.expectEqual(@as(f64, 0.2222222222), integrator.lteCoeff(.gear_2));
        // gearCoeff[2..5]: the BDF-k error constants 3/22, 12/125, 10/137, 20/343.
        for ([_]f64{ 3.0 / 22.0, 12.0 / 125.0, 10.0 / 137.0, 20.0 / 343.0 }, 3..) |want, k|
            try testing.expectApproxEqRel(want, integrator.lteCoeff(integrator.gear(@intCast(k))), 1e-9);
        // The bound is trtol*tol/(coeff*|dd|) under a sqrt, so the ratio a gear
        // deck's dt moves by is sqrt(trapCoeff[1]/gearCoeff[1]) = 0.6124.
        try testing.expectApproxEqRel(
            @as(f64, 0.61237243569),
            @sqrt(integrator.lteCoeff(.trapezoidal) / integrator.lteCoeff(.gear_2)),
            1e-9,
        );
    }

    // Per-device-state LTE as a pure function. Two charges cancel exactly on
    // their shared row: each swings 2 pC over the step, the row sums to zero.
    // ngspice's CKTterr sees each state and binds; the summed q plane sees
    // nothing and steps 14 decades too far.
    test "stepBound: per-state min survives what the summed row cancels" {
        const dt: f64 = 1e-9;
        const reltol: f64 = 1e-3;
        const abstol: f64 = 1e-12;
        const chgtol: f64 = 1e-14;
        const trtol: f64 = 7.0;

        // 2*W+1: W cancelling pairs through the vector body, one dead slot so the
        // scalar tail runs too.
        const len = 2 * W + 1;
        var s_cur: [len]f64 = @splat(0);
        var s_prev: [len]f64 = @splat(0);
        const s_zero: [len]f64 = @splat(0);
        var k: usize = 0;
        while (k + 1 < len) : (k += 2) {
            s_cur[k] = 3e-12;
            s_cur[k + 1] = -3e-12;
            s_prev[k] = 1e-12;
            s_prev[k + 1] = -1e-12;
        }
        // Row view: every pair sums to zero, and so does its whole history.
        const row: [W + 1]f64 = @splat(0);

        const del_state = integrator.stepBound(
            W,
            .backward_euler,
            .backward_euler,
            .{ &s_cur, &s_prev, &s_zero, &s_zero },
            &s_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            .{ .dt = dt, .dt1 = dt, .dt2 = dt, .reltol = reltol, .abstol = abstol, .chgtol = chgtol, .trtol = trtol },
        );
        const del_row = integrator.stepBound(
            W,
            .backward_euler,
            .backward_euler,
            .{ &row, &row, &row, &row },
            &row,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            .{ .dt = dt, .dt1 = dt, .dt2 = dt, .reltol = reltol, .abstol = abstol, .chgtol = chgtol, .trtol = trtol },
        );

        // Closed form, so the CKTterr formula is pinned and not just the inequality:
        //   i_new     = (1/dt)*(3e-12 - 1e-12)            = 2e-3
        //   volttol   = abstol + reltol*i_new             = 2.000001e-6
        //   chargetol = reltol*3e-12/dt                   = 3e-6      <- binds
        //   dd  = ((3e-12-1e-12)/dt - (1e-12-0)/dt)/(2*dt) = 5e5
        //   del = trtol*3e-6 / (0.5*5e5)                  = 8.4e-11
        try testing.expectApproxEqRel(@as(f64, trtol * 3e-6 / 2.5e5), del_state, 1e-12);
        try testing.expect(del_state < dt);
        // The summed row: dd == 0, so the bound collapses to trtol*tol/abstol.
        try testing.expect(del_row > 1e6 * dt);

        // The ground-mirror entries are inert, so the tape needs no trash-row
        // mask. ngspice terrs one charge per capacitor (captrunc.c
        // `CKTterr(here->CAPqcap)`); the tape carries q on one terminal and -q
        // on the other. Every CKTterr term is even in q (|q|, |dd|, |i|), so the
        // mirror scores identically and cannot move the min.
        const one_sided = [_]f64{ 3e-12, 0 };
        const one_sided_p = [_]f64{ 1e-12, 0 };
        const mirrored = [_]f64{ 3e-12, -3e-12 };
        const mirrored_p = [_]f64{ 1e-12, -1e-12 };
        const pair_zero = [_]f64{ 0, 0 };
        const del_one = integrator.stepBound(
            W,
            .backward_euler,
            .backward_euler,
            .{ &one_sided, &one_sided_p, &pair_zero, &pair_zero },
            &pair_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            .{ .dt = dt, .dt1 = dt, .dt2 = dt, .reltol = reltol, .abstol = abstol, .chgtol = chgtol, .trtol = trtol },
        );
        const del_mirror = integrator.stepBound(
            W,
            .backward_euler,
            .backward_euler,
            .{ &mirrored, &mirrored_p, &pair_zero, &pair_zero },
            &pair_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            .{ .dt = dt, .dt1 = dt, .dt2 = dt, .reltol = reltol, .abstol = abstol, .chgtol = chgtol, .trtol = trtol },
        );
        try testing.expectEqual(del_one, del_mirror);

        // CKTterr is homogeneous of degree zero in the charge: tol and |dd| both
        // scale with |q|, so away from the abstol/chgtol floors scaling a state
        // by 1000 leaves its bound unchanged. A contribution 1000x smaller than
        // its row-mates is still a full-strength truncation candidate. This is
        // why devices/kinduc steps differently: espice gives a K card its own
        // charge states, where ngspice folds the mutual flux into the
        // inductor's single INDflux (indload.c:70-77; MUT has no MUTtrunc).
        const big: [2]f64 = .{ s_cur[0] * 1e3, 0 };
        const big_p: [2]f64 = .{ s_prev[0] * 1e3, 0 };
        const del_big = integrator.stepBound(
            W,
            .backward_euler,
            .backward_euler,
            .{ &big, &big_p, &pair_zero, &pair_zero },
            &pair_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            .{ .dt = dt, .dt1 = dt, .dt2 = dt, .reltol = reltol, .abstol = abstol, .chgtol = chgtol, .trtol = trtol },
        );
        try testing.expectApproxEqRel(del_one, del_big, 1e-9);
    }

    // Every charge site is in the tape exactly once, per instance rather than
    // merged onto the node. Catches a missing or doubled tapeQ write, a stale
    // dedup replay and a ParEval lane overlap, which are otherwise silent.
    test "q tape: one entry per device charge site" {
        const gpa = testing.allocator;
        const models = @import("models");
        const evaluator = @import("device_eval");
        const Cap = models.capacitor;
        const Proto = evaluator.Proto;

        // The txl2_3_line shape: a big load cap and a small parasitic sharing
        // node 1. Per-row LTE differences their SUM; per-state keeps them apart.
        const CStore = evaluator.ProtoStore(Cap);
        const cstore = try gpa.create(CStore);
        cstore.* = .{};
        try cstore.append(&.{ .c = 7.398e-15 }, &.{}, .{ 1, 0 }); // load cap, node 1 -> ground
        try cstore.append(&.{ .c = 5.0e-17 }, &.{}, .{ 1, 2 }); // parasitic, node 1 -> node 2

        const protos = [_]Proto{.{
            .ctx = cstore,
            .type_name = @typeName(Cap),
            .pattern = CStore.addPattern,
            .finalize = CStore.finalize,
            .destroy = CStore.destroy,
            .apply_perm = CStore.applyPerm,
        }};

        const intern_bytes = try gpa.dupe(u8, "000");
        const intern_offs = try gpa.alloc(u32, 4);
        for (intern_offs, 0..) |*o, i| o.* = @intCast(i);
        var ckt = try root.freeze(gpa, 3, intern_bytes, intern_offs, &protos, &@as([protos.len]@import("device").DeviceType, @splat(.unset)), null);
        defer ckt.deinit();

        // 2 instances * 1 ddt site each (ngspice's CAPqcap). Per NODE there
        // would be 3 rows, and node 1 carries both charges.
        try testing.expectEqual(@as(u32, 2), ckt.qTapeLen());

        const x = [_]f64{ 0.0, 1.0, 0.25 };
        ckt.eval(&x, 0);

        const tape = try gpa.alloc(f64, ckt.qTapeLen());
        defer gpa.free(tape);
        ckt.snapshotQTape(tape);

        // Indexed by instance, one site each.
        try testing.expectApproxEqRel(@as(f64, 7.398e-15 * 1.00), tape[0], 1e-9);
        try testing.expectApproxEqRel(@as(f64, 5.0e-17 * 0.75), tape[1], 1e-9);

        // Node 1's row is the sum, whose slope is neither cap's.
        try testing.expectApproxEqRel(
            @as(f64, 7.398e-15 * 1.00 + 5.0e-17 * 0.75),
            ckt.q_vec[1],
            1e-9,
        );
    }

    // A generated device reads `$abstime` (VAMS 9.10) from the `SimState` it
    // is handed; if the host never delivers it, a PULSE is a flat line at V1.
    // Real generated devices, Circuit and integrator, so a break anywhere on
    // the SimState path (hook, call site, order) fails here.
    test "transient: a PULSE vsource output actually moves with $abstime" {
        const gpa = testing.allocator;
        const models = @import("models");
        const evaluator = @import("device_eval");
        const Vsrc = models.vsource;
        const Res = models.resistor;
        const Proto = evaluator.Proto;

        // node 0 = ground, node 1 = out, node 2 = vsource branch current.
        // PULSE(0 5 2ns 1ps 1ps 4ns 20ns): flat 0 up to 2 ns, 5 V over 2..6 ns.
        const VStore = evaluator.ProtoStore(Vsrc);
        const vstore = try gpa.create(VStore);
        vstore.* = .{};
        try vstore.append(&.{
            .waveform = 1,
            .pulse_v1 = 0.0,
            .pulse_v2 = 5.0,
            .pulse_td = 2e-9,
            .pulse_tr = 1e-12,
            .pulse_tf = 1e-12,
            .pulse_pw = 4e-9,
            .pulse_per = 20e-9,
        }, &.{}, .{ 1, 0, 2 });

        const RStore = evaluator.ProtoStore(Res);
        const rstore = try gpa.create(RStore);
        rstore.* = .{};
        try rstore.append(&.{ .r = 1000.0 }, &.{}, .{ 1, 0 });

        const protos = [_]Proto{
            .{
                .ctx = vstore,
                .type_name = @typeName(Vsrc),
                .pattern = VStore.addPattern,
                .finalize = VStore.finalize,
                .destroy = VStore.destroy,
                .apply_perm = VStore.applyPerm,
            },
            .{
                .ctx = rstore,
                .type_name = @typeName(Res),
                .pattern = RStore.addPattern,
                .finalize = RStore.finalize,
                .destroy = RStore.destroy,
                .apply_perm = RStore.applyPerm,
            },
        };

        // Flat intern table: 3 nodes all labelled "0" → bytes "000", offs step 1.
        const intern_bytes = try gpa.dupe(u8, "000");
        const intern_offs = try gpa.alloc(u32, 4);
        for (intern_offs, 0..) |*o, i| o.* = @intCast(i);
        var ckt = try root.freeze(gpa, 3, intern_bytes, intern_offs, &protos, &@as([protos.len]@import("device").DeviceType, @splat(.unset)), null);
        defer ckt.deinit();

        const x = try gpa.alloc(f64, 3);
        defer gpa.free(x);
        @memset(x, 0);

        const probes = [_]u32{1};
        var wf = try Waveform.init(gpa, 1, 512);
        defer wf.deinit();

        const sim = try simulate(&ckt, x, &probes, &wf, .{
            .t_stop = 8e-9,
            .dt_init = 1e-10,
            .method = .backward_euler,
        }, gpa);
        try testing.expect(sim);

        // Both pulse levels must be reached.
        const times = wf.column(0);
        const vals = wf.column(1);
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (0..vals.len) |i| {
            const v = vals.at(i);
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        try testing.expectApproxEqAbs(@as(f64, 0.0), lo, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 5.0), hi, 1e-9);

        // At the right times: a stale or off-by-one-step time would still swing
        // 0..5.
        for (0..times.len) |i| {
            const tt = times.at(i);
            const v = vals.at(i);
            const want: f64 = if (tt < 2e-9 or tt > 6e-9) 0.0 else 5.0;
            // A sample may land mid-ramp on the 1 ps edges.
            const on_edge = @abs(tt - 2e-9) < 2e-12 or @abs(tt - 6e-9) < 2e-12;
            if (!on_edge) try testing.expectApproxEqAbs(want, v, 1e-6);
        }
    }

    const contract = @import("contract");

    /// A one-node circuit: one instance of two-terminal device D from node 1
    /// to ground. Caller deinits it.
    fn oneDevice(comptime D: type, gpa: std.mem.Allocator) !root.Circuit {
        const evaluator = @import("device_eval");
        const Store = evaluator.ProtoStore(D);
        const store = try gpa.create(Store);
        store.* = .{};
        try store.append(&.{}, &.{}, .{ 1, 0 });
        const protos = [_]evaluator.Proto{.{
            .ctx = store,
            .type_name = "one",
            .pattern = Store.addPattern,
            .finalize = Store.finalize,
            .destroy = Store.destroy,
            .apply_perm = Store.applyPerm,
        }};
        const intern_bytes = try gpa.dupe(u8, "00");
        const intern_offs = try gpa.dupe(u32, &.{ 0, 1, 2 });
        return root.freeze(gpa, 2, intern_bytes, intern_offs, &protos, &@as([protos.len]@import("device").DeviceType, @splat(.unset)), null);
    }

    /// A conductance of 1 + n siemens, where `updateState` sets n to the
    /// branch voltage: its stamp shows which state the batch holds.
    const Latch = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct { n: f64 = 0 };
        pub const State = struct {};
        pub fn initState(_: *const Model, _: *const Instance) State {
            return .{};
        }
        pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, inst: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
            const v = contract.probes(@This(), S, xv);
            const current = v[0].sub(v[1]).scale(1 + inst.n);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
        pub fn updateState(comptime _: type, _: *const Model, inst: *Instance, x: [2]f64, _: *State, _: contract.SimState) contract.UpdateResult {
            inst.n = x[0] - x[1];
            return .ok;
        }
    };

    // OPtran and the envelope's outer rollback rewind committed device state.
    test "circuit: restoreState rewinds device state in place" {
        const gpa = testing.allocator;
        var ckt = try oneDevice(Latch, gpa);
        defer ckt.deinit();
        const x = [_]f64{ 0, 2 };
        _ = ckt.updateStates(&x);
        _ = ckt.stateCtl(.commit);
        const saved = try ckt.saveState(gpa);
        defer saved.deinit(gpa);
        _ = ckt.updateStates(&.{ 0, 5 });
        _ = ckt.stateCtl(.commit);
        ckt.restoreState(saved);
        ckt.eval(&x, 0);
        try testing.expectEqual(@as(f64, 3), ckt.g_vals[ckt.diag_slots[1]]);
        // A refreshed save holds the newer state.
        _ = ckt.updateStates(&.{ 0, 5 });
        ckt.storeState(saved);
        _ = ckt.updateStates(&x);
        ckt.restoreState(saved);
        ckt.eval(&x, 0);
        try testing.expectEqual(@as(f64, 6), ckt.g_vals[ckt.diag_slots[1]]);
    }

    test "circuit: analyses that rewind time refuse a digital device type" {
        const gpa = testing.allocator;
        var ckt = try oneDevice(Latch, gpa);
        defer ckt.deinit();
        try ckt.refuseDigital("pss");
        ckt.batches[0].digital = true;
        try testing.expectError(error.DigitalDeviceUnsupported, ckt.refuseDigital("pss"));
    }

    // A device that locates an event inside a step asks for the step to end
    // there (`request_reject_at`). Taken as a flip, every step across the
    // event fails Newton and dt underflows; honoured, one retry lands on it.
    test "transient: a request_reject_at step retries ending at the requested time" {
        const gpa = testing.allocator;
        const tc: f64 = 0.375;
        const D = struct {
            pub const U = enum(u8) { p, n };
            pub const num_ports: usize = 2;
            pub const Model = struct {};
            pub const Instance = struct {};
            pub const State = struct {};
            pub fn initState(_: *const Model, _: *const Instance) State {
                return .{};
            }
            pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
                const v = contract.probes(@This(), S, xv);
                const current = v[0].sub(v[1]);
                return contract.rows(@This(), S, .{ current, current.neg() });
            }
            pub fn updateState(comptime _: type, _: *const Model, _: *Instance, _: [2]f64, _: *State, sim: contract.SimState) contract.UpdateResult {
                return if (sim.kind == .tran and sim.t > tc and sim.t - sim.dt < tc) .{ .request_reject_at = tc } else .ok;
            }
        };
        var ckt = try oneDevice(D, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, 2);
        defer gpa.free(x);
        @memset(x, 0);
        const probes = [_]u32{1};
        var wf = try Waveform.init(gpa, 1, 256);
        defer wf.deinit();
        const sim = try simulate(&ckt, x, &probes, &wf, .{ .t_stop = 1, .dt_init = 0.1, .uic = true }, gpa);
        try testing.expect(sim);
        for (0..wf.len) |i| {
            if (wf.time(i) == tc) break;
        } else return error.TestExpectedLanding;
    }

    // #102: a device's $strobe prints once per accepted point, at that
    // point, and never for an attempt the step control threw away.
    test "transient: display tasks print once per accepted step, none for a rejected attempt" {
        const gpa = testing.allocator;
        const tc: f64 = 0.375;
        const D = struct {
            pub const U = enum(u8) { p, n };
            pub const num_ports: usize = 2;
            pub const Model = struct {};
            pub const Instance = struct {};
            pub const State = struct {};
            pub fn initState(_: *const Model, _: *const Instance) State {
                return .{};
            }
            pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
                const v = contract.probes(@This(), S, xv);
                const current = v[0].sub(v[1]);
                return contract.rows(@This(), S, .{ current, current.neg() });
            }
            pub fn updateState(comptime _: type, _: *const Model, _: *Instance, _: [2]f64, _: *State, sim: contract.SimState) contract.UpdateResult {
                return if (sim.kind == .tran and sim.t > tc and sim.t - sim.dt < tc) .{ .request_reject_at = tc } else .ok;
            }
            pub const say_sites = [_]contract.SaySite{.{ .fmt = "%m t=%.17g\n", .file = "t.va", .line = 1, .nargs = 1 }};
            pub fn say(comptime S: type, _: *const [2]S.V, _: *const Model, _: *const Instance, sim: contract.SimState, out: *contract.Say) void {
                out.put(0, &.{sim.t});
            }
        };
        var ckt = try oneDevice(D, gpa);
        defer ckt.deinit();
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var display: root.Display = .{ .names = &.{&.{"n1"}}, .staged = .init(gpa), .out = &sink.writer };
        defer display.staged.deinit();
        ckt.display = &display;
        const x = try gpa.alloc(f64, 2);
        defer gpa.free(x);
        @memset(x, 0);
        const probes = [_]u32{1};
        var wf = try Waveform.init(gpa, 1, 256);
        defer wf.deinit();
        const sim = try simulate(&ckt, x, &probes, &wf, .{ .t_stop = 1, .dt_init = 0.1, .uic = true }, gpa);
        try testing.expect(sim);
        // uic commits t = 0 without a solve, so every later sample prints once,
        // in order, the step that overshot tc never.
        var lines = std.mem.splitScalar(u8, sink.written(), '\n');
        for (1..wf.len) |i| {
            const line = lines.next() orelse return error.TestMissingLine;
            try testing.expect(std.mem.startsWith(u8, line, "n1 t="));
            try testing.expectEqual(wf.time(i), try std.fmt.parseFloat(f64, line["n1 t=".len..]));
        }
        try testing.expectEqualStrings("", lines.rest());
    }
};

const TranNoiseTests = struct {
    const impl = @import("../tran/tran_noise.zig");
    const Xorshift64 = impl.test_access.Xorshift64;
    const std = @import("std");
    const testing = std.testing;

    test "tran_noise: xorshift64 produces deterministic sequence" {
        var rng1 = Xorshift64.init(42);
        var rng2 = Xorshift64.init(42);

        for (0..100) |_| {
            try testing.expectEqual(rng1.next(), rng2.next());
        }
    }

    test "tran_noise: randn distribution has zero mean and unit variance" {
        var rng = Xorshift64.init(0xCAFE_BABE);
        const n_samples: usize = 100_000;

        var sum: f64 = 0;
        var sum_sq: f64 = 0;
        for (0..n_samples) |_| {
            const v = rng.randn();
            sum += v;
            sum_sq += v * v;
        }
        const mean = sum / @as(f64, @floatFromInt(n_samples));
        const variance = sum_sq / @as(f64, @floatFromInt(n_samples)) - mean * mean;

        try testing.expectApproxEqAbs(@as(f64, 0.0), mean, 0.02);
        try testing.expectApproxEqAbs(@as(f64, 1.0), variance, 0.02);
    }

    test "flicker: poles sum to K ln(f_max / f_min) for 1/f, skip the rest" {
        const NoiseSource = @import("../types.zig").NoiseSource;
        const Flicker = impl.test_access.Flicker;
        const gpa = testing.allocator;
        const sources = [_]NoiseSource{
            .{ .node_p = 1, .node_n = 0, .white = 1e-20 }, // white only
            .{ .node_p = 1, .node_n = 2, .flicker = 2e-14, .ef = 1 },
            .{ .node_p = 2, .node_n = 0, .flicker = 1e-14, .ef = 2 }, // no finite sum
        };
        // f_max = 0.5 / dt_max = 500 Hz, f_min = 1 / t_stop = 1 Hz.
        var f = try Flicker.init(gpa, &sources, .{ .t_stop = 1, .dt_max = 1e-3 });
        defer f.deinit(gpa);
        try testing.expectEqual(@as(usize, 9), f.source.len); // ceil(3 * log10(500))
        var total: f64 = 0;
        for (f.source, f.variance) |s, v| {
            try testing.expectEqual(@as(u32, 1), s);
            total += v;
        }
        try testing.expectApproxEqRel(2e-14 * @log(500.0), total, 1e-12);
        // An empty band has no poles.
        var none = try Flicker.init(gpa, &sources, .{ .t_stop = 1, .dt_max = 1, .f_min = 10 });
        defer none.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), none.source.len);
        // Every partial init frees what it took.
        const initFree = struct {
            fn run(a: std.mem.Allocator, srcs: []const NoiseSource) !void {
                var fl = try Flicker.init(a, srcs, .{ .t_stop = 1, .dt_max = 1e-3 });
                fl.deinit(a);
            }
        }.run;
        try testing.checkAllAllocationFailures(@import("core").testing.fixed_growth, initFree, .{@as([]const NoiseSource, &sources)});
    }

    test "covariance: stampVec stamps v j j^T, transpose is an involution" {
        const Cov = impl.test_access.Covariance;
        var m: [9]f64 = @splat(0);
        Cov.stampVec(&m, 3, &.{1}, &.{1}, 2);
        Cov.stampVec(&m, 3, &.{ 1, 2 }, &.{ 1, -1 }, 1);
        try testing.expectEqualSlices(f64, &.{ 0, 0, 0, 0, 3, -1, 0, -1, 1 }, &m);
        // A correlated group of weight 2 on node 0 and -1 on node 2.
        @memset(&m, 0);
        Cov.stampVec(&m, 3, &.{ 0, 2 }, &.{ 2, -1 }, 1);
        try testing.expectEqualSlices(f64, &.{ 4, 0, -2, 0, 0, 0, -2, 0, 1 }, &m);
        var a = [_]f64{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
        Cov.transpose(&a, 3);
        try testing.expectEqualSlices(f64, &.{ 1, 4, 7, 2, 5, 8, 3, 6, 9 }, &a);
        Cov.transpose(&a, 3);
        try testing.expectEqualSlices(f64, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &a);
    }
};

/// Integrator order by a manufactured solution, through `Session`. Two
/// circuits with closed forms, each started by `.ic` under uic:
///   RC: v(0) = 1 discharging through 1 kOhm into 1 uF, v = exp(-t/tau);
///   series RLC (10 Ohm, 1 mH, 1 uF): v_C(0) = 1, i(0) = 0, underdamped,
///   v = e^(-a t) (cos(wd t) + (a/wd) sin(wd t)), a = R/2L, wd^2 = 1/LC - a^2.
/// The LTE bound is switched off (trtol huge), so the grid is the start-up
/// ramp from h/100 doubling to dt_max = h, and every grid is the same grid
/// scaled by h. The max error over the accepted points then scales as h^p,
/// and the observed p over three steps h, h/2, h/4 must sit within `band` of
/// the method's order. The next error term pulls p low by O(h/tau) or
/// O(wd h). RC measured 0.984 and 0.992 for backward Euler, 1.986 and 1.993
/// for trapezoidal and Gear-2, so its band is three times the worst gap. The
/// RLC's gap, from a 2x2 reference march of the same grid, is 0.04 for
/// backward Euler (0.962, 0.981) and 0.006 for the others; its band is 0.1.
/// A wrong order (off by 1) passes neither.
const OrderTests = struct {
    const std = @import("std");
    const t = std.testing;
    const core = @import("core");
    const requests = core.query;
    const Session = @import("../session.zig").Session;
    const Builder = @import("builder").Builder;
    const Library = @import("device").Library;
    const models = @import("models");
    const GROUND = @import("../types.zig").GROUND;

    const Kind = enum { rc, rlc };

    fn exact(kind: Kind, time: f64) f64 {
        return switch (kind) {
            .rc => @exp(-time / 1e-3),
            .rlc => blk: {
                const a: f64 = 10.0 / (2 * 1e-3);
                const wd = @sqrt(1.0 / (1e-3 * 1e-6) - a * a);
                break :blk @exp(-a * time) * (@cos(wd * time) + a / wd * @sin(wd * time));
            },
        };
    }

    /// Max |v - exact| over the accepted points of one run to `t_stop` at
    /// step `h` (dt_init and dt_max) and LTE scale `trtol`.
    fn maxError(lib: *const Library, kind: Kind, method: requests.Method, t_stop: f64, h: f64, trtol: f64) !f64 {
        var b = try Builder.init(t.allocator, lib);
        const out = try b.addNode();
        switch (kind) {
            .rc => try b.addDevice(models.resistor, "", &.{ .r = 1e3 }, &.{}, .{ out, GROUND }),
            .rlc => {
                const mid = try b.addNode();
                try b.addDevice(models.resistor, "", &.{ .r = 10 }, &.{}, .{ out, mid });
                try b.addDevice(models.inductor, "", &.{ .l = 1e-3 }, &.{}, .{ mid, GROUND });
            },
        }
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-6 }, &.{}, .{ out, GROUND });
        var prepared = try b.compile();
        defer prepared.deinit();
        const deck: core.Deck = .{
            .probes = &.{out},
            .probe_labels = &.{"v(out)"},
            .source_node = 0,
            .source_branch = 0,
            .output_node = 0,
            .ac_drive = &.{},
            .title = "",
            .n_devices = if (kind == .rc) 2 else 3,
            .ic = &.{.{ .node = out, .value = 1 }},
            .deck_tol = .{},
            .deck_temp = null,
            .deck_method = null,
            .queries = &.{},
            .bindings = .{ .v_names = &.{}, .i_names = &.{}, .v_branches = &.{}, .v_pos = &.{}, .v_neg = &.{}, .i_pos = &.{}, .i_neg = &.{}, .v_distof1 = &.{}, .ports = &.{} },
            .cards = &.{},
            .ac_overrides = &.{},
        };
        var s = Session.init(t.allocator, t.io, &prepared, &deck, .{});
        defer s.deinit();
        const query: requests.Query = .{ .tran = .{
            .t_stop = t_stop,
            .dt_init = h,
            .dt_max = h,
            .method = method,
            .uic = true,
            .tol = .{ .trtol = trtol },
        } };
        var ids: [1]requests.QueryId = undefined;
        _ = try s.append(&.{query}, &ids);
        var advances: u32 = 0;
        while (!(try s.info(ids[0])).status.terminal()) : (advances += 1) {
            try t.expect(advances < 1_000_000);
            _ = try s.advance(ids[0]);
        }
        const res = try s.result(ids[0]);
        try t.expectEqual(@as(usize, 2), res.varnames.len);
        // h/100 doubling to h, then h steps: about t_stop / h points.
        if (trtol > 1e29) try t.expect(res.npoints >= @as(usize, @intFromFloat(t_stop / h)));
        var worst: f64 = 0;
        for (0..res.npoints) |i| {
            const time = res.data[2 * i];
            worst = @max(worst, @abs(res.data[2 * i + 1] - exact(kind, time)));
        }
        try t.expect(worst > 0);
        return worst;
    }

    test "integrators converge at their theoretical order on RC and RLC" {
        var lib = try Library.init(t.allocator);
        defer lib.deinit();
        const cases = [_]struct { Kind, f64, f64 }{
            .{ .rc, 2e-3, 0.05 }, // two time constants
            .{ .rlc, 2e-4, 0.1 }, // about one ringing period, 2 pi / wd
        };
        const methods = [_]struct { requests.Method, f64 }{
            .{ .backward_euler, 1 },
            .{ .trapezoidal, 2 },
            .{ .gear_2, 2 },
        };
        for (cases) |case| for (methods) |m| {
            const kind, const t_stop, const band = case;
            const method, const order = m;
            const h0 = t_stop / if (kind == .rc) @as(f64, 100) else 200;
            var errs: [3]f64 = undefined;
            for (&errs, 0..) |*e, k| e.* = try maxError(&lib, kind, method, t_stop, h0 / std.math.pow(f64, 2, @floatFromInt(k)), 1e30);
            for (0..2) |k| {
                const observed = std.math.log2(errs[k] / errs[k + 1]);
                if (!(@abs(observed - order) <= band)) {
                    std.debug.print("order: {t} {t} observed {d:.4}, want {d} +- {d}\n", .{ kind, method, observed, order, band });
                    return error.TestUnexpectedOrder;
                }
            }
        };
    }

    // The step loop's order control under the ngspice LTE (trtol 7) on the
    // default dt_max = t_stop/50 grid: every gear-k climbs past order 2
    // (ZP_TRAN_STATS by_order, e.g. RLC gear-6 {3, 11, 5, 5, 14, 24}) on
    // the same 62 accepted points as gear-2, and its error drops 7x (RC,
    // 1.78e-4 to 2.52e-5, the BE start-up's floor) to 10x (RLC, 1.12e-2 to
    // 8.43e-4 at k >= 4). A loop stuck at order 2 gives gear-2's error.
    test "gear-3..6 through the step loop beat gear-2 at equal steps" {
        var lib = try Library.init(t.allocator);
        defer lib.deinit();
        for ([_]struct { Kind, f64 }{ .{ .rc, 2e-3 }, .{ .rlc, 2e-4 } }) |case| {
            const kind, const t_stop = case;
            const e2 = try maxError(&lib, kind, .gear_2, t_stop, t_stop / 50, 7);
            for ([_]requests.Method{ .gear_3, .gear_4, .gear_5, .gear_6 }) |m| {
                const e = try maxError(&lib, kind, m, t_stop, t_stop / 50, 7);
                if (!(e < e2 / 4)) {
                    std.debug.print("{t} {t}: error {e:.3}, gear-2 {e:.3}\n", .{ kind, m, e, e2 });
                    return error.TestUnexpectedError;
                }
            }
        }
    }
};

/// Gear-3..6 order by the same two closed forms, marched with the
/// integrator's own kernels (`gearAg`, `gearHistory`) at one fixed order:
/// a `Session` run starts at BE on a h/100 ramp, whose O(h^2) start-up error
/// buries an O(h^k) one, so this march seeds the k history points from the
/// closed form instead. RC: q' = -v/R with q = Cv. RLC: q = (Cv, Li),
/// (Cv)' = -i and (Li)' = v - Ri, solved per step as a 2x2. A Python replica
/// of the march, and this test, measure every observed order on h =
/// t_stop/40, /80, /160 within 0.11 of k (2.953 to 5.979), so the band is 0.2.
const GearOrderTests = struct {
    const std = @import("std");
    const t = std.testing;
    const integrator = @import("../tran/tran.zig").test_access.integrator;
    const Kind = OrderTests.Kind;
    // OrderTests' element values.
    const r_rc: f64 = 1e3;
    const R = 10.0;
    const L = 1e-3;
    const C = 1e-6;

    /// The closed form's charges at `time`: [Cv, Li] (Li for the RLC only).
    fn charges(kind: Kind, time: f64) [2]f64 {
        const v = OrderTests.exact(kind, time);
        if (kind == .rc) return .{ C * v, 0 };
        const a: f64 = R / (2 * L);
        const wd = @sqrt(1.0 / (L * C) - a * a);
        // i = -C dv/dt = e^(-a t) sin(wd t) / (wd L).
        return .{ C * v, @exp(-a * time) * @sin(wd * time) / wd };
    }

    /// Max |v - exact| of an order-k march to `t_stop`; step i is
    /// h * w[i >> level], or h when `w` is empty, so level j refines level 0
    /// by halving every step of it.
    fn maxError(kind: Kind, k: u8, t_stop: f64, h: f64, w: []const f64, level: u5) f64 {
        const step = struct {
            fn f(hh: f64, ww: []const f64, lv: u5, i: usize) f64 {
                return if (ww.len == 0) hh else hh * ww[i >> lv];
            }
        }.f;
        // Slot i holds q_{n-i}; slot 0 is the point being solved.
        var store: [7][2]f64 = undefined;
        var time: f64 = 0;
        for (0..k) |j| {
            if (j > 0) time += step(h, w, level, j - 1);
            store[k - j] = charges(kind, time);
        }
        const m: usize = if (kind == .rc) 1 else 2;
        var worst: f64 = 0;
        var s: usize = k - 1;
        while (time < t_stop * (1 - 1e-12)) : (s += 1) {
            var dts: [7]f64 = undefined;
            for (dts[0..k], 0..) |*d, i| d.* = step(h, w, level, s - i);
            const ag = integrator.gearAg(k, &dts);
            var g: [2]f64 = undefined;
            var q: [7][]f64 = undefined;
            for (q[0 .. k + 1], store[0 .. k + 1]) |*v, *col| v.* = col[0..m];
            integrator.gearHistory(g[0..m], q[0 .. k + 1], ag);
            // ag0*(q - q1) - g is the charge's derivative.
            const b0 = ag[0] * store[1][0] + g[0];
            const v = if (kind == .rc) b0 / (ag[0] * C + 1 / r_rc) else blk: {
                const b1 = ag[0] * store[1][1] + g[1];
                // [ag0 C, 1; -1, ag0 L + R] [v; i] = [b0; b1]
                const d22 = ag[0] * L + R;
                const v = (b0 * d22 - b1) / (ag[0] * C * d22 + 1);
                store[0][1] = L * (b1 + v) / d22;
                break :blk v;
            };
            store[0][0] = C * v;
            time += dts[0];
            worst = @max(worst, @abs(v - OrderTests.exact(kind, time)));
            std.mem.copyBackwards([2]f64, store[1..], store[0..6]);
        }
        return worst;
    }

    fn observed(kind: Kind, k: u8, t_stop: f64, w: []const f64) [2]f64 {
        var errs: [3]f64 = undefined;
        for (&errs, 0..) |*e, j| e.* = maxError(kind, k, t_stop, t_stop / 40 / std.math.pow(f64, 2, @floatFromInt(j)), w, @intCast(j));
        return .{ std.math.log2(errs[0] / errs[1]), std.math.log2(errs[1] / errs[2]) };
    }

    const cases = [_]struct { Kind, f64 }{ .{ .rc, 2e-3 }, .{ .rlc, 2e-4 } };

    test "Gear-3..6 converge at their order at a fixed order and step" {
        for (cases) |case| for (3..7) |k| {
            for (observed(case[0], @intCast(k), case[1], &.{})) |p| {
                if (!(@abs(p - @as(f64, @floatFromInt(k))) <= 0.2)) {
                    std.debug.print("gear-{d} {t}: observed order {d:.4}\n", .{ k, case[0], p });
                    return error.TestUnexpectedOrder;
                }
            }
        };
    }

    // Steps drawn as a random walk whose ratios stay within the order's
    // `maxGrowth` both ways (clamped to [h/2, 2h]); refinement halves each
    // step, so the ratios stay inside the bound at every level. This seed
    // measures k - 0.15 to k - 0.003; a Python replica on other seeds went
    // down to k - 0.49, as the grid is only piecewise uniform, so the band is
    // 0.5 low and 0.2 high.
    test "Gear-3..6 converge to the closed form under random step ratios within maxGrowth" {
        var prng = std.Random.DefaultPrng.init(0x9ea6);
        const r = prng.random();
        for (cases) |case| for (3..7) |k| {
            const rho = integrator.maxGrowth(integrator.gear(@intCast(k)));
            var w: [200]f64 = undefined;
            w[0] = 1;
            for (w[1..], w[0 .. w.len - 1]) |*x, prev| x.* = std.math.clamp(prev * (1 / rho + (rho - 1 / rho) * r.float(f64)), 0.5, 2);
            for (observed(case[0], @intCast(k), case[1], &w)) |p| {
                const kf: f64 = @floatFromInt(k);
                if (!(p >= kf - 0.5 and p <= kf + 0.2)) {
                    std.debug.print("gear-{d} {t} variable: observed order {d:.4}\n", .{ k, case[0], p });
                    return error.TestUnexpectedOrder;
                }
            }
        };
    }
};

const LaneKernelTests = struct {
    const impl = @import("../tran/tran.zig");
    const W = impl.test_access.W;
    const integrator = impl.test_access.integrator;
    const lk = @import("solver").lane_kernels;
    const Method = @import("core").query.Method;
    const std = @import("std");
    const testing = std.testing;
    const methods = [_]Method{ .backward_euler, .trapezoidal, .gear_2 };

    fn code(m: Method) u8 {
        return switch (m) {
            .backward_euler => 0,
            .trapezoidal => 1,
            else => 2,
        };
    }

    fn draw(r: std.Random) f64 {
        return switch (r.uintLessThan(u8, 64)) {
            0 => std.math.nan(f64),
            1 => std.math.inf(f64),
            2 => 0,
            else => (2 * r.float(f64) - 1) * 1e-12,
        };
    }

    test "lane_kernels.stepBound is bitwise integrator.stepBound on random rings, NaN where it is NaN" {
        const gpa = testing.allocator;
        var prng = std.Random.DefaultPrng.init(0x207);
        const r = prng.random();
        var finite: usize = 0;
        for (0..200) |_| {
            const len = 1 + r.uintLessThan(usize, 300);
            const buf = try gpa.alloc(f64, 5 * len);
            defer gpa.free(buf);
            for (buf) |*v| v.* = draw(r);
            const q: [4][]const f64 = .{ buf[0..len], buf[len..][0..len], buf[2 * len ..][0..len], buf[3 * len ..][0..len] };
            const ip = buf[4 * len ..][0..len];
            const dt = 1e-12 * (0.01 + r.float(f64));
            const lte: integrator.LteIn = .{ .dt = dt, .dt1 = dt * (0.1 + 4 * r.float(f64)), .dt2 = dt * (0.1 + 4 * r.float(f64)), .reltol = 1e-3, .abstol = 1e-12, .chgtol = 1e-14, .trtol = 7 };
            const c: integrator.Coeffs = .{ .ag0 = 1 / dt, .ag2 = 0.5 / dt, .ag1 = 1 };
            const lin: lk.LteIn = .{ .dt = lte.dt, .dt1 = lte.dt1, .dt2 = lte.dt2, .reltol = lte.reltol, .abstol = lte.abstol, .chgtol = lte.chgtol, .trtol = lte.trtol, .ag0 = c.ag0, .ag1 = c.ag1, .ag2 = c.ag2 };
            for (methods) |m| for (methods) |cm| {
                const want = integrator.stepBound(W, m, cm, q, ip, c, lte);
                const got = lk.stepBound(code(m), code(cm), q[0], q[1], q[2], q[3], ip, len, lin);
                if (std.math.isNan(want)) {
                    try testing.expect(std.math.isNan(got));
                } else {
                    finite += 1;
                    try testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
                }
            };
        }
        try testing.expect(finite > 0);
    }

    test "lane_kernels.companionRow equals integrator.companionAt(m, true, ...) per row" {
        var prng = std.Random.DefaultPrng.init(0x208);
        const r = prng.random();
        const n = 37;
        const n_hist = 4;
        var q: [n]f64 = undefined;
        var ring: [n_hist * n]f64 = undefined;
        var ip: [n]f64 = undefined;
        var rhs0: [n]f64 = undefined;
        for (&q, &ip, &rhs0) |*a, *b, *c| {
            a.* = r.float(f64) - 0.5;
            b.* = r.float(f64) - 0.5;
            c.* = r.float(f64) - 0.5;
        }
        for (&ring) |*v| v.* = r.float(f64) - 0.5;
        const perm = [n_hist]u8{ 0, 1, 2, 3 };
        const c: integrator.Coeffs = .{ .ag0 = 3.7e11, .ag2 = 1.1e11, .ag1 = 0.9 };
        inline for (methods) |m| {
            var want = rhs0;
            integrator.companionAt(m, true, &want, &q, ring[n..][0..n], ring[2 * n ..][0..n], &ip, c);
            var got = rhs0;
            for (0..n) |i| lk.Bodies(lk.HostP).companionRow(i, code(m), c.ag0, c.ag1, c.ag2, &got, &q, &ring, @constCast(&perm), n_hist, n, &ip, 1, 0);
            for (want, got) |a, b| try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
        }
    }
};

test {
    _ = LaneKernelTests;
    _ = GearOrderTests;
    _ = EnvelopeTests;
    _ = MatexTests;
    _ = OrderTests;
    _ = TranTests;
    _ = TranNoiseTests;
}
