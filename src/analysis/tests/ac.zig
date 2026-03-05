const BatchTests = struct {
    const impl = @import("../ac/batch.zig");
    const FreqSolver = @import("solvers").freq_solve.FreqSolver;
    const quantum = impl.quantum;
    const root = @import("../types.zig");
    const solve = impl.solve;
    const std = @import("std");

    test "frequency quanta preserve full-grid answers and unwind cancellation" {
        const a = std.testing.allocator;
        const g = try a.dupe(f64, &.{ 2, 1, 0, 3 });
        const c = try a.dupe(f64, &.{ 0.1, 0, 0.02, 0.3 });
        var fs = try FreqSolver.initDense(a, 2, g, c);
        defer fs.deinit(a);
        var frequencies: [2 * quantum + 3]f64 = undefined;
        for (&frequencies, 0..) |*f, i| f.* = @floatFromInt(i);
        const rhs = [_]f64{ 1, 2, 0, 0 };

        // One cold callback record: events update two counters; no numerical data
        // is stored here. u16 covers this 131-frequency fixture's whole lifetime.
        const Probe = struct {
            calls: u16 = 0,
            completed: u16 = 0,
            cancel: bool = false,

            fn checkpoint(ctx: *anyopaque, event: @import("../progress.zig").Event) error{QueryCancelled}!void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.calls += 1;
                self.completed = @intCast(event.completed);
                if (self.cancel) return error.QueryCancelled;
            }
        };
        var probe: Probe = .{};
        // solve reads only the dispatch hook and checkpoint callback from Circuit.
        var ckt: root.Circuit = undefined;
        ckt.gpu_hook = null;
        for ([_]bool{ false, true }) |adjoint| {
            ckt.progress = null;
            const whole = try solve(&ckt, &fs, a, g, c, &frequencies, &rhs, adjoint);
            defer a.free(whole);
            probe = .{};
            ckt.progress = .{ .ctx = &probe, .yield_fn = Probe.checkpoint };
            const stepped = try solve(&ckt, &fs, a, g, c, &frequencies, &rhs, adjoint);
            defer a.free(stepped);
            try std.testing.expectEqualSlices(f64, whole, stepped);
            try std.testing.expectEqual(@as(u16, 3), probe.calls);
            try std.testing.expectEqual(@as(u16, frequencies.len), probe.completed);
            probe = .{ .cancel = true };
            try std.testing.expectError(error.QueryCancelled, solve(&ckt, &fs, a, g, c, &frequencies, &rhs, adjoint));
            try std.testing.expectEqual(@as(u16, quantum), probe.completed);
        }
    }
};

const NoiseTests = struct {
    const impl = @import("../ac/noise.zig");
    const Band = impl.test_access.Band;
    const NoiseSource = impl.NoiseSource;
    const nintegrate = impl.test_access.nintegrate;
    const sourcePsd = impl.test_access.sourcePsd;
    const std = @import("std");

    const k_boltzmann = 1.380649e-23;

    const q_electron = 1.602176634e-19;

    // ── Tests ──────────────────────────────────────────────────────────────

    test "sourcePsd white is flat" {
        // Thermal, 100 ohm: the device would have handed us 4kT*g.
        const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 4.0 * k_boltzmann * 300.15 * 0.01 };
        try std.testing.expectApproxEqRel(src.white, sourcePsd(src, 1e6), 1e-12);
        try std.testing.expectApproxEqRel(sourcePsd(src, 1e6), sourcePsd(src, 1e9), 1e-12);
    }

    test "sourcePsd shot is 2q|I|, not 4kT*g" {
        // THE 2x THIS BRANCH EXISTS TO FIX. A junction at I has g = dI/dV = I/Vt,
        // so the old Jacobian read gave 4kT*I/Vt = 4q*I -- exactly twice 2q*I.
        const i_bias = 1e-3;
        const vt = k_boltzmann * 300.15 / q_electron;
        const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 2.0 * q_electron * i_bias };
        try std.testing.expectApproxEqRel(2.0 * q_electron * i_bias, sourcePsd(src, 1e6), 1e-12);
        try std.testing.expectApproxEqRel(2.0, (4.0 * k_boltzmann * 300.15 * (i_bias / vt)) / src.white, 1e-12);
    }

    test "sourcePsd flicker rolls off as 1/f^ef" {
        // ngspice dionoise.c:99-104: KF*|I|^AF / f, EF = 1.
        const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .flicker = 1e-24 * 1e-3 };
        try std.testing.expectApproxEqRel(1e-27 / 1e3, sourcePsd(src, 1e3), 1e-12);
        try std.testing.expectApproxEqRel(sourcePsd(src, 1e3) / 10.0, sourcePsd(src, 1e4), 1e-12);
        // f = 0 cannot divide; the white half is still the answer.
        try std.testing.expectEqual(@as(f64, 0), sourcePsd(src, 0));

        // mos1noi.c:175-181 / BSIM4's `ef`: the exponent is not always 1.
        const ef2: NoiseSource = .{ .node_p = 0, .node_n = 1, .flicker = 4e-30, .ef = 1.4 };
        try std.testing.expectApproxEqRel(4e-30 / std.math.pow(f64, 1e3, 1.4), sourcePsd(ef2, 1e3), 1e-12);
    }

    test "sourcePsd sums both halves on one generator" {
        // §4.6.4: two `<+` lines on one branch are two generators, but one device
        // may also hand back a term with both halves set.
        const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 3e-17, .flicker = 1e-14 };
        try std.testing.expectApproxEqRel(3e-17 + 1e-14 / 1e3, sourcePsd(src, 1e3), 1e-12);
    }

    test "nintegrate reproduces ngspice's three branches analytically" {
        const f0: f64 = 1e3;
        const f1: f64 = 1e4;
        const b: Band = .{
            .del_freq = f1 - f0,
            .ln_freq = @log(f1),
            .ln_last_freq = @log(f0),
            .del_ln_freq = @log(f1) - @log(f0),
        };

        // Flat spectrum -> |exponent| < N_INTFTHRESH -> the rectangle rule.
        const s: f64 = 3e-17;
        try std.testing.expectApproxEqRel(s * (f1 - f0), nintegrate(s, @log(s), @log(s), b), 1e-12);

        // S = a/f (exponent -1) -> the logarithmic branch, integral a*ln(f1/f0).
        const a: f64 = 1e-14;
        try std.testing.expectApproxEqRel(
            a * @log(f1 / f0),
            nintegrate(a / f1, @log(a / f1), @log(a / f0), b),
            1e-9,
        );

        // S = c*f^2 -> the general branch, integral c*(f1^3 - f0^3)/3.
        const c: f64 = 2e-24;
        try std.testing.expectApproxEqRel(
            c * (f1 * f1 * f1 - f0 * f0 * f0) / 3.0,
            nintegrate(c * f1 * f1, @log(c * f1 * f1), @log(c * f0 * f0), b),
            1e-9,
        );
    }
};

const StbTests = struct {
    const impl = @import("../ac/stb.zig");
    const SolveResult = impl.SolveResult;
    const computeMargins = impl.test_access.computeMargins;
    const std = @import("std");

    // ============================================================================
    // Tests
    // ============================================================================

    const testing = std.testing;

    test "STB: margin computation with synthetic data" {
        const allocator = testing.allocator;

        const k_gain: f64 = 10.0;
        const f0: f64 = 1000.0;
        const n_pts: u32 = 200;

        var result = try SolveResult.init(allocator, n_pts);
        defer result.deinit(allocator);

        for (0..n_pts) |idx| {
            const frac = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n_pts - 1));
            const f = std.math.pow(f64, 10.0, frac * 6.0);
            const ratio = f / f0;
            const denom = @sqrt(1.0 + ratio * ratio);
            const m = k_gain / denom;
            const phase_rad = -std.math.atan(ratio);

            result.freqs[idx] = f;
            result.loop_gain[idx] = .{ .re = m * @cos(phase_rad), .im = m * @sin(phase_rad) };
        }

        computeMargins(&result);

        try testing.expect(!std.math.isNan(result.phase_margin_deg));
        try testing.expectApproxEqAbs(95.7, result.phase_margin_deg, 2.0);
        // Single-pole: phase never reaches −180° → gain margin is NaN (correct).
        try testing.expect(std.math.isNan(result.gain_margin_db));
    }

    test "STB: three-pole margin computation" {
        // Two poles only approach −180° asymptotically and never cross it
        // (gain margin is then rightly NaN); three poles give a real crossing.
        const allocator = testing.allocator;

        const k_gain: f64 = 100.0;
        const f1: f64 = 100.0;
        const f2: f64 = 1000.0;
        const f3: f64 = 10000.0;
        const n_pts: u32 = 500;

        var result = try SolveResult.init(allocator, n_pts);
        defer result.deinit(allocator);

        for (0..n_pts) |idx| {
            const frac = @as(f64, @floatFromInt(idx)) / @as(f64, @floatFromInt(n_pts - 1));
            const f = std.math.pow(f64, 10.0, frac * 7.0);
            const r1 = f / f1;
            const r2 = f / f2;
            const r3 = f / f3;
            const m = k_gain / (@sqrt(1.0 + r1 * r1) * @sqrt(1.0 + r2 * r2) * @sqrt(1.0 + r3 * r3));
            const phase_rad = -std.math.atan(r1) - std.math.atan(r2) - std.math.atan(r3);

            result.freqs[idx] = f;
            result.loop_gain[idx] = .{ .re = m * @cos(phase_rad), .im = m * @sin(phase_rad) };
        }

        computeMargins(&result);

        try testing.expect(!std.math.isNan(result.phase_margin_deg));
        try testing.expect(result.phase_margin_deg > 0);
        try testing.expect(result.phase_margin_deg < 180.0);
        try testing.expect(!std.math.isNan(result.gain_margin_db));
        try testing.expect(result.gain_margin_db > 0);
    }
};

test {
    _ = BatchTests;
    _ = NoiseTests;
    _ = StbTests;
}
