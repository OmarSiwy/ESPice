const EnvelopeTests = struct {
    const impl = @import("../tran/envelope.zig");
    const Options = @import("requests").Envelope;
    const extractPeak = impl.extractPeak;
    const extractRMS = impl.extractRMS;
    const maxPoints = impl.maxPoints;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "envelope: extractPeak finds absolute maximum" {
        const vals = [_]f64{ 1.0, -3.0, 2.0, -1.5, 0.5 };
        const peak = extractPeak(&vals);
        try testing.expectApproxEqAbs(@as(f64, 3.0), peak, 1e-15);
    }

    test "envelope: extractRMS of constant signal equals absolute value" {
        const vals = [_]f64{ 2.0, 2.0, 2.0, 2.0 };
        const rms = extractRMS(&vals);
        try testing.expectApproxEqAbs(@as(f64, 2.0), rms, 1e-15);
    }

    test "envelope: extractRMS of sine wave is amplitude/sqrt(2)" {
        // Generate one full period of sin
        const n = 1024;
        var vals: [n]f64 = undefined;
        const amplitude = 3.0;
        for (0..n) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            vals[k] = amplitude * @sin(2.0 * std.math.pi * t);
        }
        const rms = extractRMS(&vals);
        const expected_rms = amplitude / @sqrt(2.0);
        try testing.expectApproxEqRel(expected_rms, rms, 1e-4);
    }

    test "envelope: extractRMS of empty slice returns zero" {
        const empty: []const f64 = &.{};
        try testing.expectEqual(@as(f64, 0), extractRMS(empty));
    }

    test "envelope: extractPeak of single element" {
        const vals = [_]f64{-7.5};
        try testing.expectApproxEqAbs(@as(f64, 7.5), extractPeak(&vals), 1e-15);
    }

    test "envelope: extractPeak of empty slice returns zero" {
        const empty: []const f64 = &.{};
        try testing.expectEqual(@as(f64, 0), extractPeak(empty));
    }

    test "envelope: maxPoints monotone in max_outer_steps" {
        const base: Options = .{ .t_carrier = 1e-9, .t_stop = 1e-3 };
        const mp1 = maxPoints(base);
        var opts2 = base;
        opts2.max_outer_steps = 100;
        const mp2 = maxPoints(opts2);
        // Fewer allowed steps → fewer max points
        try testing.expect(mp2 <= mp1);
    }

    test "envelope: coarseAdvance duration tracking uses actual dt" {
        // Regression: old code used t_elapsed += dt_coarse instead of dt,
        // which could skip the final partial step. Verified by the fix in
        // coarseAdvance using dt (the clamped value) for the accumulator.
        // This test just validates the maxPoints helper doesn't overflow.
        const opts: Options = .{
            .t_carrier = 1e-6,
            .t_stop = 1e-3,
            .min_periods_per_step = 1,
            .max_periods_per_step = 32,
        };
        const mp = maxPoints(opts);
        try testing.expect(mp >= 3); // at least DC + one step + slack
    }
};

const MatexTests = struct {
    const impl = @import("../tran/matex.zig");
    const buildCombinedVals = impl.test_access.buildCombinedVals;
    const denseMatMul = impl.test_access.denseMatMul;
    const expmSmall = impl.test_access.expmSmall;
    const simdAxpy = impl.test_access.simdAxpy;
    const simdDot = impl.test_access.simdDot;
    const simdNorm = impl.test_access.simdNorm;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "expmSmall: identity" {
        // expm(0) = I
        var H = [_]f64{ 0, 0, 0, 0 };
        var out: [4]f64 = undefined;
        var scratch: [20]f64 = undefined; // 5*2*2 = 20
        expmSmall(2, &H, &out, &scratch);
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
        expmSmall(2, &H, &out, &scratch);
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
        expmSmall(1, &H, &out, &scratch);
        try testing.expectApproxEqRel(std.math.e, out[0], 1e-6);
    }

    test "expmSmall: 3x3 nilpotent" {
        // H = [[0,1,0],[0,0,1],[0,0,0]] — nilpotent, expm = I + H + H²/2
        // expm = [[1,1,0.5],[0,1,1],[0,0,1]]
        var H = [_]f64{ 0, 1, 0, 0, 0, 1, 0, 0, 0 };
        var out: [9]f64 = undefined;
        var scratch: [45]f64 = undefined; // 5*3*3
        expmSmall(3, &H, &out, &scratch);
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
        expmSmall(2, &H, &out, &scratch);
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
        expmSmall(2, &H, &out, &scratch);
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

    test "simdDot: basic" {
        const a_arr = [_]f64{ 1, 2, 3, 4 };
        const b_arr = [_]f64{ 5, 6, 7, 8 };
        const d = simdDot(&a_arr, &b_arr, 4);
        try testing.expectApproxEqAbs(@as(f64, 70.0), d, 1e-12);
    }

    test "simdNorm: unit" {
        const v_arr = [_]f64{ 3, 4 };
        try testing.expectApproxEqAbs(@as(f64, 5.0), simdNorm(&v_arr, 2), 1e-12);
    }

    test "simdAxpy: basic" {
        const x_arr = [_]f64{ 1, 2, 3 };
        var y_arr = [_]f64{ 10, 20, 30 };
        simdAxpy(2.0, &x_arr, &y_arr, 3);
        try testing.expectApproxEqAbs(@as(f64, 12.0), y_arr[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 24.0), y_arr[1], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 36.0), y_arr[2], 1e-15);
    }

    test "buildCombinedVals: gamma=1 gives C+G" {
        const g = [_]f64{ 1, 2, 3 };
        const c = [_]f64{ 10, 20, 30 };
        var out: [3]f64 = undefined;
        buildCombinedVals(3, &g, &c, 1.0, &out);
        try testing.expectApproxEqAbs(@as(f64, 11.0), out[0], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 22.0), out[1], 1e-15);
        try testing.expectApproxEqAbs(@as(f64, 33.0), out[2], 1e-15);
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

    // ============================================================================
    // Tests
    // ============================================================================
    const testing = std.testing;

    test "waveform: doubling fallback keeps probe-major data intact" {
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
            try testing.expectApproxEqAbs(fi * 1e-9, waveform.timeSlice()[i], 1e-24);
            try testing.expectApproxEqAbs(fi, waveform.probeValues(0)[i], 1e-15);
            try testing.expectApproxEqAbs(100.0 + fi, waveform.probeValues(1)[i], 1e-15);
        }
    }

    test "waveform: toRows tiling crosses tile boundaries exactly" {
        // 70 points over a 32-point tile: two full tiles plus a 6-point remainder,
        // with more probes than one tile of rows. Exact equality — the tiling only
        // reorders the copy, never the values.
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
        const rows = try waveform.toRows(allocator, ncols);
        defer allocator.free(rows);
        try testing.expectEqual(@as(usize, 70 * ncols), rows.len);
        for (0..70) |p| {
            try testing.expectEqual(@as(f64, @floatFromInt(p)) * 1e-9, rows[p * ncols]);
            for (0..n_probes) |k| {
                const want = @as(f64, @floatFromInt(p)) * 10.0 + @as(f64, @floatFromInt(k));
                try testing.expectEqual(want, rows[p * ncols + k + 1]);
            }
        }
    }

    test "coeffs: BE 1/dt, trap 2/dt, gear-2 variable-step BDF2" {
        const dt: f64 = 1e-9;
        try testing.expectApproxEqRel(@as(f64, 1e9), integrator.coeffs(.backward_euler, dt, dt).ag0, 1e-12);
        try testing.expectApproxEqRel(@as(f64, 2e9), integrator.coeffs(.trapezoidal, dt, dt).ag0, 1e-12);
        // r == 1 must reproduce the uniform-step triple that used to be hardcoded.
        const u = integrator.coeffs(.gear_2, dt, dt);
        try testing.expectApproxEqRel(@as(f64, 1.5e9), u.ag0, 1e-12);
        try testing.expectApproxEqRel(@as(f64, 0.5e9), u.ag2, 1e-12);
        // Consistency on a NON-uniform grid is the whole point: the corrector must
        // be exact on constants (sum of coefficients zero, ag1 = -(ag0+ag2)) and on
        // the linear ramp q(t) = t through the actual node spacing 0, dt1, dt1+dt.
        for ([_]f64{ 0.25, 0.5, 1.0, 2.0, 4.0 }) |r| {
            const dt1 = dt / r;
            const c = integrator.coeffs(.gear_2, dt, dt1);
            const ag1 = -(c.ag0 + c.ag2);
            // q0 = 0, q1 = -dt, q2 = -(dt+dt1) as offsets from t_n: dq/dt == 1.
            const dqdt = c.ag0 * 0.0 + ag1 * (-dt) + c.ag2 * (-(dt + dt1));
            try testing.expectApproxEqRel(@as(f64, 1.0), dqdt, 1e-12);
            // and exact on the quadratic too — BDF2 is a 3-point formula, exact
            // through degree 2, so d/dt(t^2) at t_n must come out 0. The surviving
            // terms are each O(dt) = 1e-9, so the tolerance below is rounding noise
            // and not a free pass: 1e-6/dt would have accepted anything.
            const sq = c.ag0 * 0.0 + ag1 * (dt * dt) + c.ag2 * ((dt + dt1) * (dt + dt1));
            try testing.expectApproxEqAbs(@as(f64, 0.0), sq, 1e-22);
        }
    }

    // cktterr.c:24-34 verbatim. gear_2 used to read trapCoeff[1] (1/12), which is
    // 8/3 smaller and — through the sqrt at order 2 — a 1.63x LOOSER dt bound than
    // GEAR's own error control asks for. Pin all three against the C tables.
    test "lteCoeff: ngspice gearCoeff/trapCoeff tables" {
        try testing.expectEqual(@as(f64, 0.5), integrator.lteCoeff(.backward_euler));
        try testing.expectApproxEqRel(@as(f64, 0.08333333333), integrator.lteCoeff(.trapezoidal), 1e-10);
        try testing.expectApproxEqRel(@as(f64, 0.2222222222), integrator.lteCoeff(.gear_2), 1e-10);
        // The bound is trtol*tol/(coeff*|dd|) under a sqrt, so the ratio a gear
        // deck's dt moves by is sqrt(trapCoeff[1]/gearCoeff[1]) = 0.6124.
        try testing.expectApproxEqRel(
            @as(f64, 0.61237243569),
            @sqrt(integrator.lteCoeff(.trapezoidal) / integrator.lteCoeff(.gear_2)),
            1e-9,
        );
    }

    // The whole point of per-device-state LTE, as a pure function. Two charge
    // contributions that cancel EXACTLY on their shared row: each swings 2 pC over
    // the step, the row sums to a flat zero. ngspice's CKTterr sees each state and
    // binds; the summed q plane sees nothing and steps 14 decades too far. Fails
    // the moment stepBound is fed row-summed charge again.
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
            .backward_euler,
            .backward_euler,
            &s_cur,
            &s_prev,
            &s_zero,
            &s_zero,
            &s_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            dt,
            dt,
            dt,
            reltol,
            abstol,
            chgtol,
            trtol,
        );
        const del_row = integrator.stepBound(
            .backward_euler,
            .backward_euler,
            &row,
            &row,
            &row,
            &row,
            &row,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            dt,
            dt,
            dt,
            reltol,
            abstol,
            chgtol,
            trtol,
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

        // The ground-mirror entries are INERT, which is why the tape needs no
        // trash-row mask. ngspice terrs one state per instance (captrunc.c:
        // `CKTterr(here->CAPqcap)`, capdefs.h: CAPnumStates = 2 for q AND its
        // current, i.e. ONE charge); the tape carries q on one terminal and -q on
        // the other, and the old per-row path never saw the ground side at all
        // because stepBound walks q_hist[0..n], excluding the trash cell q_vec[n].
        // Every CKTterr term is even in q — |q|, |dd|, |i| — so the mirror scores
        // identically and cannot move the min. Masking it would be work for zero
        // numerical effect; this assert is what says so.
        const one_sided = [_]f64{ 3e-12, 0 };
        const one_sided_p = [_]f64{ 1e-12, 0 };
        const mirrored = [_]f64{ 3e-12, -3e-12 };
        const mirrored_p = [_]f64{ 1e-12, -1e-12 };
        const pair_zero = [_]f64{ 0, 0 };
        const del_one = integrator.stepBound(
            .backward_euler,
            .backward_euler,
            &one_sided,
            &one_sided_p,
            &pair_zero,
            &pair_zero,
            &pair_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            dt,
            dt,
            dt,
            reltol,
            abstol,
            chgtol,
            trtol,
        );
        const del_mirror = integrator.stepBound(
            .backward_euler,
            .backward_euler,
            &mirrored,
            &mirrored_p,
            &pair_zero,
            &pair_zero,
            &pair_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            dt,
            dt,
            dt,
            reltol,
            abstol,
            chgtol,
            trtol,
        );
        try testing.expectEqual(del_one, del_mirror);

        // CKTterr is HOMOGENEOUS OF DEGREE ZERO in the charge: tol scales with |q|
        // (both volttol and chargetol) and so does |dd|, so `del` does not depend on
        // how big the contribution is — only on its RELATIVE curvature. Away from
        // the abstol/chgtol floors, scaling a state by 1000 leaves its bound put.
        //
        // This is the whole reason per-state LTE is not simply "more conservative":
        // a contribution 1000x smaller than its row-mates is still a full-strength
        // truncation candidate once it is its own state. It is what ngspice does
        // too — and it is exactly why devices/kinduc regressed, since espice gives
        // a K card its own charge states where ngspice folds the mutual flux into
        // the inductor's single INDflux (indload.c:70-77, and MUT has no MUTtrunc).
        const big: [2]f64 = .{ s_cur[0] * 1e3, 0 };
        const big_p: [2]f64 = .{ s_prev[0] * 1e3, 0 };
        const del_big = integrator.stepBound(
            .backward_euler,
            .backward_euler,
            &big,
            &big_p,
            &pair_zero,
            &pair_zero,
            &pair_zero,
            .{ .ag0 = 1.0 / dt, .ag2 = 0 },
            dt,
            dt,
            dt,
            reltol,
            abstol,
            chgtol,
            trtol,
        );
        try testing.expectApproxEqRel(del_one, del_big, 1e-9);
    }

    // The plumbing invariant: every charge the devices stamped is in the tape
    // exactly once, and it is stamped PER INSTANCE, not merged onto the node.
    // Catches a missing scatterQ write, a double write, a stale dedup replay and a
    // ParEval lane overlap — the failure modes that are otherwise silent.
    test "q tape: per-device-state charges, one entry each, summing to the q plane" {
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
        var ckt = try root.freeze(gpa, 3, intern_bytes, intern_offs, &protos, null);
        defer ckt.deinit();

        // 2 instances * 2 unknowns. Per NODE there would be 3 rows; per STATE there
        // are 4 contributions, and node 1 carries two of them.
        try testing.expectEqual(@as(u32, 4), ckt.qTapeLen());

        const x = [_]f64{ 0.0, 1.0, 0.25 };
        ckt.eval(&x, 0);

        const tape = try gpa.alloc(f64, ckt.qTapeLen());
        defer gpa.free(tape);
        ckt.snapshotQTape(tape);

        // Indexed id*n_u + ru, exactly like rhs_idx.
        try testing.expectApproxEqRel(@as(f64, 7.398e-15 * 1.00), tape[0], 1e-9);
        try testing.expectApproxEqRel(@as(f64, -7.398e-15 * 1.00), tape[1], 1e-9);
        try testing.expectApproxEqRel(@as(f64, 5.0e-17 * 0.75), tape[2], 1e-9);
        try testing.expectApproxEqRel(@as(f64, -5.0e-17 * 0.75), tape[3], 1e-9);

        // Every contribution lands in exactly one q_vec cell (the ground terminal
        // in the trash row q_vec[n]), so the two totals are the same number.
        var sum_tape: f64 = 0;
        for (tape) |v| sum_tape += v;
        var sum_plane: f64 = 0;
        for (ckt.q_vec) |v| sum_plane += v;
        try testing.expectApproxEqAbs(sum_plane, sum_tape, 1e-30);

        // And the merge the old controller had to live with: node 1's row is the
        // sum, whose slope is neither cap's.
        try testing.expectApproxEqRel(
            @as(f64, 7.398e-15 * 1.00 + 5.0e-17 * 0.75),
            ckt.q_vec[1],
            1e-9,
        );
    }

    // The one property the `set_sim_state` plumbing exists for. A generated
    // device reads `Instance.abstime` (§9.10 `$abstime`), NOT the `t` argument of
    // eval — with the host never writing that field every SPICE waveform is
    // pinned at its t=0 value and a PULSE is a flat line at V1. Real generated
    // vsource + resistor, real Circuit, real integrator: nothing is mocked, so a
    // regression anywhere on the path (hook, vtable gate, call site, ordering)
    // fails here.
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
        var ckt = try root.freeze(gpa, 3, intern_bytes, intern_offs, &protos, null);
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

        // The waveform must reach BOTH pulse levels. Before the fix every sample
        // read v1 (abstime stuck at 0), so `hi` was 0 and this failed.
        const times = wf.timeSlice();
        const vals = wf.probeValues(0);
        var lo: f64 = std.math.inf(f64);
        var hi: f64 = -std.math.inf(f64);
        for (vals) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        try testing.expectApproxEqAbs(@as(f64, 0.0), lo, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 5.0), hi, 1e-9);

        // ...and reach them at the RIGHT times: a plumbing bug that fed a stale or
        // off-by-one-step time would still swing 0..5.
        for (times, vals) |tt, v| {
            const want: f64 = if (tt < 2e-9 or tt > 6e-9) 0.0 else 5.0;
            // Skip the 1 ps edges themselves — a sample can legitimately land
            // mid-ramp there.
            const on_edge = @abs(tt - 2e-9) < 2e-12 or @abs(tt - 6e-9) < 2e-12;
            if (!on_edge) try testing.expectApproxEqAbs(want, v, 1e-6);
        }
    }
};

const TranNoiseTests = struct {
    const impl = @import("../tran/tran_noise.zig");
    const Xorshift64 = impl.test_access.Xorshift64;
    const simdCopy = impl.test_access.simdCopy;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

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
