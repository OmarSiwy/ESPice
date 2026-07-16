//! Frequency-domain unit tests: the frequency stream, noise PSD/integration
//! and the `.lstb` double-injection formulas.

const StreamTests = struct {
    const freq = @import("../ac/freq.zig");
    const FreqSolver = @import("solver").freq_solve.FreqSolver;
    const quantum = freq.quantum;
    const root = @import("../types.zig");
    const std = @import("std");

    test "frequency stream matches one whole-grid batch and unwinds cancellation" {
        const a = std.testing.allocator;
        const g = try a.dupe(f64, &.{ 2, 1, 0, 3 });
        const c = try a.dupe(f64, &.{ 0.1, 0, 0.02, 0.3 });
        var fs = try FreqSolver.initDense(a, 2, g, c);
        defer fs.deinit(a);
        var frequencies: [2 * quantum + 3]f64 = undefined;
        for (&frequencies, 0..) |*f, i| f.* = @floatFromInt(i);
        const rhs = [_]f64{ 1, 2, 0, 0 };

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
        // The stream reads only the checkpoint callback and the (empty)
        // frequency-dependent table from Circuit.
        var ckt: root.Circuit = undefined;
        ckt.progress = .{ .ctx = &probe, .yield_fn = Probe.checkpoint };
        ckt.ac_dyn_slots = &.{};
        for ([_]bool{ false, true }) |adjoint| {
            const whole = try a.alloc(f64, frequencies.len * 4);
            defer a.free(whole);
            try fs.solveBatch(&frequencies, .{}, &rhs, whole, adjoint);

            probe = .{};
            var stream = try freq.Stream.init(a, &fs, &ckt, &.{}, &frequencies, &rhs, adjoint);
            defer stream.deinit(a);
            var seen: usize = 0;
            while (try stream.next(&ckt)) |pt| : (seen += 1) {
                try std.testing.expectEqual(seen, pt.k);
                try std.testing.expectEqualSlices(f64, whole[pt.k * 4 ..][0..4], pt.x);
            }
            try std.testing.expectEqual(frequencies.len, seen);
            try std.testing.expectEqual(@as(u16, 3), probe.calls);
            try std.testing.expectEqual(@as(u16, frequencies.len), probe.completed);

            probe = .{ .cancel = true };
            var cancelled = try freq.Stream.init(a, &fs, &ckt, &.{}, &frequencies, &rhs, adjoint);
            defer cancelled.deinit(a);
            // The first checkpoint, after `quantum` points, cancels.
            const stopped = while (true) {
                const pt = cancelled.next(&ckt) catch |err| break err;
                if (pt == null) break error.NeverCancelled;
            };
            try std.testing.expectEqual(error.QueryCancelled, stopped);
            try std.testing.expectEqual(@as(u16, quantum), probe.completed);
        }
    }

    test "frequency stream: every chunk boundary, two right-hand sides" {
        // Lengths 0..3W+1 put the last chunk at every fill; each point's
        // slice is both of its rhs blocks, as one whole-grid batch lays out.
        const a = std.testing.allocator;
        const g = try a.dupe(f64, &.{ 2, 1, 0, 3 });
        const c = try a.dupe(f64, &.{ 0.1, 0, 0.02, 0.3 });
        var fs = try FreqSolver.initDense(a, 2, g, c);
        defer fs.deinit(a);
        const W = FreqSolver.W;
        var omegas: [3 * W + 1]f64 = undefined;
        for (&omegas, 0..) |*w, i| w.* = 1e3 * @as(f64, @floatFromInt(i + 1));
        const rhs = [_]f64{ 1, 0, 0, 0, 0, 1, 0, 0.5 };
        var whole: [omegas.len * rhs.len]f64 = undefined;
        var ckt: root.Circuit = undefined;
        ckt.progress = null;
        ckt.ac_dyn_slots = &.{};
        for (0..omegas.len + 1) |len| {
            try fs.solveBatch(omegas[0..len], .{}, &rhs, whole[0 .. len * rhs.len], true);
            var stream = try freq.Stream.init(a, &fs, &ckt, &.{}, omegas[0..len], &rhs, true);
            defer stream.deinit(a);
            var seen: usize = 0;
            while (try stream.next(&ckt)) |pt| : (seen += 1) {
                try std.testing.expectEqual(seen, pt.k);
                try std.testing.expectEqualSlices(f64, whole[pt.k * rhs.len ..][0..rhs.len], pt.x);
            }
            try std.testing.expectEqual(len, seen);
            try std.testing.expectEqual(null, try stream.next(&ckt));
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

    test "sourcePsd white is flat" {
        // Thermal, 100 ohm: the device hands over 4kT*g.
        const src: NoiseSource = .{ .node_p = 0, .node_n = 1, .white = 4.0 * k_boltzmann * 300.15 * 0.01 };
        try std.testing.expectApproxEqRel(src.white, sourcePsd(src, 1e6), 1e-12);
        try std.testing.expectApproxEqRel(sourcePsd(src, 1e6), sourcePsd(src, 1e9), 1e-12);
    }

    test "sourcePsd shot is 2q|I|, not 4kT*g" {
        // A junction at I has g = dI/dV = I/Vt, so reading shot noise off the
        // Jacobian as 4kT*g gives 4q*I, exactly twice 2q*I.
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

const LstbTests = struct {
    const lstb = @import("../ac/lstb.zig");
    const std = @import("std");

    test "double injection reads A·β through an ideal voltage break" {
        // Probe between an ideal inverting amplifier's output (gain a) and a
        // resistive feedback network (β): the injected current all enters
        // the amplifier (A = 1, C = 0) and the voltage injection splits as
        // D = 1/(1 + aβ). W = aβ whatever the probe current B.
        const a_gain: f64 = 1e3;
        const beta: f64 = 0.1;
        const d = 1 / (1 + a_gain * beta);
        const g = lstb.Gains.of(.{
            .a = .{ .re = 1, .im = 0 },
            .b = .{ .re = -1.1e-3 * d, .im = 0 },
            .c = .zero,
            .d = .{ .re = d, .im = 0 },
        });
        try std.testing.expectApproxEqRel(a_gain * beta, g.w.re, 1e-12);
        try std.testing.expectApproxEqAbs(0, g.w.im, 1e-12);
        try std.testing.expectApproxEqAbs(0, g.wr.re, 1e-12);
    }
};

test {
    _ = StreamTests;
    _ = NoiseTests;
    _ = LstbTests;
    // The in-file tests of the frequency-domain drivers.
    _ = @import("../ac/acmatch.zig");
    _ = @import("../ac/lstb.zig");
    _ = @import("../ac/sp.zig");
}
