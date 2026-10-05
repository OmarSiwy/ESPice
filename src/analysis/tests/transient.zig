//! Transient-family unit tests: envelope, matex, tran and tran_noise.

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

    test "expmSmall: identity" {
        // expm(0) = I
        var H = [_]f64{ 0, 0, 0, 0 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined; // 5*2*2 = 20
        var piv: [3]u32 = undefined;
        expmSmall(2, &H, &out, &scratch, &piv);
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
        expmSmall(2, &H, &out, &scratch, &piv);
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
        expmSmall(1, &H, &out, &scratch, &piv);
        try testing.expectApproxEqRel(std.math.e, out[0], 1e-6);
    }

    test "expmSmall: 3x3 nilpotent" {
        // H = [[0,1,0],[0,0,1],[0,0,0]] — nilpotent, expm = I + H + H²/2
        // expm = [[1,1,0.5],[0,1,1],[0,0,1]]
        var H = [_]f64{ 0, 1, 0, 0, 0, 1, 0, 0, 0 };
        var out: [9]f64 = undefined;
        var scratch: [45]f64 = undefined; // 5*3*3
        var piv: [3]u32 = undefined;
        expmSmall(3, &H, &out, &scratch, &piv);
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
        expmSmall(2, &H, &out, &scratch, &piv);
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
        expmSmall(2, &H, &out, &scratch, &piv);
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

    test "predict: the stdpp pipeline matches its .byRef() pull oracle" {
        const z = @import("stdpp");
        const Predict = impl.test_access.Predict;
        var prng = std.Random.DefaultPrng.init(0x9ed1);
        const r = prng.random();
        const L = 200; // past 3x the widest lane count, so every tail runs
        var cur: [L + 3]f64 = undefined;
        var prev: [L + 3]f64 = undefined;
        for (&cur, &prev) |*c, *p| {
            c.* = (r.float(f64) - 0.5) * 10;
            p.* = (r.float(f64) - 0.5) * 10;
        }
        cur[5] = std.math.nan(f64);
        prev[9] = std.math.inf(f64);
        const xfact = 0.37;
        for (0..L) |len| for (0..4) |off| {
            const c = cur[off..][0..len];
            const p = prev[off..][0..len];
            var fast: [L]f64 = undefined;
            var slow: [L]f64 = undefined;
            impl.test_access.predict(fast[0..len], c, p, xfact);
            var src = z.fromSlice(f64, c);
            var it = src.byRef().zip(z.fromSlice(f64, p)).map(Predict{ .xfact = xfact });
            try testing.expectEqual(len, it.writeInto(slow[0..len]));
            // Bit for bit; NaN payloads may differ between the paths.
            for (slow[0..len], fast[0..len]) |a, b| {
                if (std.math.isNan(a) and std.math.isNan(b)) continue;
                try testing.expectEqual(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)));
            }
        };
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

    test "waveform: recordLerp interpolates per probe; a stream keeps no rows" {
        var buf: [6 * @sizeOf(f64)]u8 align(@alignOf(f64)) = undefined;
        var sink: std.Io.Writer = .fixed(&buf);
        var wf = try Waveform.initStream(testing.allocator, 2, &sink);
        defer wf.deinit();
        const probes = [_]u32{ 2, 0 };
        try wf.recordLerp(0.5, &.{ 0, 9, 4 }, &.{ 2, 9, 8 }, 0.25, &probes);
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

    test "rebaseCurrent: vector kernel is bit-identical to its w=1 oracle" {
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
            integrator.rebaseCurrent(W, vec[0..len], q_new[0..len], q_old[0..len], alpha);
            integrator.rebaseCurrent(1, ora[0..len], q_new[0..len], q_old[0..len], alpha);
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
            for ([_]impl.Method{ .backward_euler, .trapezoidal, .gear_2 }) |m| for ([_]impl.Method{ .backward_euler, .trapezoidal, .gear_2 }) |cm| {
                const vec = integrator.stepBound(W, m, cm, s, ip[0..len], c, lte);
                const ora = integrator.stepBound(1, m, cm, s, ip[0..len], c, lte);
                try testing.expectEqual(@as(u64, @bitCast(ora)), @as(u64, @bitCast(vec)));
            };
        }
    }

    test "companionAt: every method, both modes, matches its per-element formula bit for bit" {
        var prng = std.Random.DefaultPrng.init(0xc0a1);
        const r = prng.random();
        const cap = 3 * W + 2;
        inline for ([_]impl.Method{ .backward_euler, .trapezoidal, .gear_2 }) |m| {
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
                        .trapezoidal => ip[j],
                        .gear_2 => c.ag2 * (q[1][j] - q[2][j]),
                        else => 0,
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

    // Matches ngspice cktterr.c:24-34. gear_2 must read gearCoeff[1] (.2222222222), not
    // trapCoeff[1] (.08333333333), which would give a 1.63x looser dt bound.
    test "lteCoeff: ngspice gearCoeff/trapCoeff tables" {
        try testing.expectEqual(@as(f64, 0.5), integrator.lteCoeff(.backward_euler));
        try testing.expectEqual(@as(f64, 0.08333333333), integrator.lteCoeff(.trapezoidal));
        try testing.expectEqual(@as(f64, 0.2222222222), integrator.lteCoeff(.gear_2));
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
        try cstore.append(.{ .c = 7.398e-15 }, .{}, .{ 1, 0 }); // load cap, node 1 -> ground
        try cstore.append(.{ .c = 5.0e-17 }, .{}, .{ 1, 2 }); // parasitic, node 1 -> node 2

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
        try vstore.append(.{
            .waveform = 1,
            .pulse_v1 = 0.0,
            .pulse_v2 = 5.0,
            .pulse_td = 2e-9,
            .pulse_tr = 1e-12,
            .pulse_tf = 1e-12,
            .pulse_pw = 4e-9,
            .pulse_per = 20e-9,
        }, .{}, .{ 1, 0, 2 });

        const RStore = evaluator.ProtoStore(Res);
        const rstore = try gpa.create(RStore);
        rstore.* = .{};
        try rstore.append(.{ .r = 1000.0 }, .{}, .{ 1, 0 });

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
        root.zeroSimd(x);

        const probes = [_]u32{1};
        var wf = try Waveform.init(gpa, 1, 512);
        defer wf.deinit();

        const sim = try simulate(&ckt, x, &probes, &wf, .{
            .t_stop = 8e-9,
            .dt_init = 1e-10,
            .method = .backward_euler,
        }, gpa);
        try testing.expect(sim.completed);

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
        try store.append(.{}, .{}, .{ 1, 0 });
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
        root.zeroSimd(x);
        const probes = [_]u32{1};
        var wf = try Waveform.init(gpa, 1, 256);
        defer wf.deinit();
        const sim = try simulate(&ckt, x, &probes, &wf, .{ .t_stop = 1, .dt_init = 0.1, .uic = true }, gpa);
        try testing.expect(sim.completed);
        for (0..wf.len) |i| {
            if (wf.time(i) == tc) break;
        } else return error.TestExpectedLanding;
    }
};

const TranNoiseTests = struct {
    const impl = @import("../tran/tran_noise.zig");
    const Xorshift64 = impl.test_access.Xorshift64;
    const simdCopy = impl.test_access.simdCopy;
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
        try testing.checkAllAllocationFailures(gpa, initFree, .{@as([]const NoiseSource, &sources)});
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

    test "tran_noise: simdCopy matches element-wise" {
        const src = [_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0 };
        var dst: [11]f64 = undefined;
        simdCopy(&dst, &src);
        for (src, dst) |s, d| try testing.expectEqual(s, d);
    }
};

test {
    _ = EnvelopeTests;
    _ = MatexTests;
    _ = TranTests;
    _ = TranNoiseTests;
}
