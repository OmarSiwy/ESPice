//! Frequency-domain unit tests: the frequency stream, noise PSD/integration
//! and the `.lstb` double-injection formulas. Oracles: the chunked stream
//! against one whole-grid `FreqSolver` batch; the PSD shapes and ngspice's
//! three `nintegrate` branches against their closed forms; `.lstb` against
//! A·β through an ideal voltage break. Then metamorphic relations and
//! certificates on built circuits: reciprocity Z12 = Z21 and impedance
//! scaling on a passive RLC network (each solution checked by its
//! residual), AC at ω = 0 against the finite difference of two operating
//! points, and the diode operating point against hand KCL. Also pulls in
//! the in-file tests of acmatch, lstb and sp.

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
        defer fs.deinit();
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
        defer fs.deinit();
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
    const sourcePsd = impl.sourcePsd;
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

const CircuitTests = struct {
    const std = @import("std");
    const t = std.testing;
    const analysis = @import("../types.zig");
    const Builder = @import("builder").Builder;
    const Library = @import("device").Library;
    const FreqSolver = @import("solver").freq_solve.FreqSolver;
    const models = @import("models");
    const op = @import("../dc/op.zig");
    const tf = @import("../dc/tf.zig");
    const sp = @import("../ac/sp.zig");
    const GROUND = analysis.GROUND;
    const gpa = t.allocator;

    /// A non-symmetric passive RLC network on nodes 1..3 with R, L and C
    /// scaled for impedance level `k`: R·k, L·k, C/k.
    fn rlc(lib: *const Library, k: f64) !@import("device").Circuit {
        var b = try Builder.init(gpa, lib);
        const n1 = try b.addNode();
        const n2 = try b.addNode();
        const n3 = try b.addNode();
        try b.addDevice(models.resistor, "", &.{ .r = 100 * k }, &.{}, .{ n1, GROUND });
        try b.addDevice(models.inductor, "", &.{ .l = 1e-3 * k }, &.{}, .{ n1, n2 });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 / k }, &.{}, .{ n2, GROUND });
        try b.addDevice(models.resistor, "", &.{ .r = 50 * k }, &.{}, .{ n2, n3 });
        try b.addDevice(models.capacitor, "", &.{ .c = 2e-9 / k }, &.{}, .{ n3, GROUND });
        try b.addDevice(models.resistor, "", &.{ .r = 300 * k }, &.{}, .{ n3, n1 });
        try b.addDevice(models.inductor, "", &.{ .l = 1e-5 * k }, &.{}, .{ n3, GROUND });
        return b.compile();
    }

    const omegas = [_]f64{ 2 * std.math.pi * 1e3, 2 * std.math.pi * 1e5, 2 * std.math.pi * 1e6, 2 * std.math.pi * 1e7 };
    const port_a: u32 = 1;
    const port_b: u32 = 3;

    /// Unit current injections into `port_a` then `port_b`, solved at every
    /// `omegas` point into `x` (point-major, two stacked 2n blocks each).
    /// Each solution is certified by its scaled residual
    /// ‖(G + jωC)x − b‖∞ ≤ 64·eps·(‖A‖∞‖x‖∞ + ‖b‖∞) on the circuit's planes.
    fn injections(ckt: *analysis.Circuit, x: []f64) !void {
        const n = ckt.n;
        const x_op = try gpa.alloc(f64, n);
        defer gpa.free(x_op);
        @memset(x_op, 0);
        var fs = try FreqSolver.fromCircuit(gpa, ckt, x_op);
        defer fs.deinit();
        const rhs = try gpa.alloc(f64, 4 * n);
        defer gpa.free(rhs);
        @memset(rhs, 0);
        rhs[port_a] = 1;
        rhs[2 * n + port_b] = 1;
        try fs.solveBatch(&omegas, .{}, rhs, x, false);

        const r = try gpa.alloc(f64, 2 * n);
        defer gpa.free(r);
        const row_abs = try gpa.alloc(f64, n);
        defer gpa.free(row_abs);
        for (omegas, 0..) |w, k| for (0..2) |j| {
            const xs = x[(2 * k + j) * 2 * n ..][0 .. 2 * n];
            const b = rhs[j * 2 * n ..][0 .. 2 * n];
            @memcpy(r, b);
            for (r) |*v| v.* = -v.*;
            @memset(row_abs, 0);
            for (0..n) |col| for (ckt.col_ptr[col]..ckt.col_ptr[col + 1]) |p| {
                const row = ckt.row_idx[p];
                const g = ckt.g_vals[p];
                const c = w * ckt.c_vals[p];
                r[row] += g * xs[col] - c * xs[n + col];
                r[n + row] += g * xs[n + col] + c * xs[col];
                row_abs[row] += @abs(g) + @abs(c);
            };
            var a_norm: f64 = 0;
            var x_norm: f64 = 0;
            for (row_abs) |v| a_norm = @max(a_norm, v);
            for (xs) |v| x_norm = @max(x_norm, @abs(v));
            const bound = 64 * std.math.floatEps(f64) * (a_norm * x_norm + 1);
            // `!(|r| <= bound)` fails a NaN too, which `@max` would drop.
            for (r) |v| if (!(@abs(v) <= bound)) return error.TestUnexpectedResult;
        };
    }

    fn z(x: []const f64, n: usize, k: usize, drive: usize, node: u32) [2]f64 {
        const xs = x[(2 * k + drive) * 2 * n ..][0 .. 2 * n];
        return .{ xs[node], xs[n + node] };
    }

    test "passive RLC: reciprocity Z12 = Z21, and R·k, L·k, C/k scales every Z by k" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var zs: [2][omegas.len][3][2]f64 = undefined; // per k: Z11, Z12, Z21
        for ([_]f64{ 1, 7 }, &zs) |k, *zk| {
            var prepared = try rlc(&lib, k);
            defer prepared.deinit();
            var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
            defer ckt.deinit();
            const n = ckt.n;
            const x = try gpa.alloc(f64, omegas.len * 4 * n);
            defer gpa.free(x);
            try injections(&ckt, x);
            for (zk, 0..) |*zp, p| {
                zp.* = .{ z(x, n, p, 0, port_a), z(x, n, p, 0, port_b), z(x, n, p, 1, port_a) };
                // Z21 (drive a, read b) = Z12 (drive b, read a).
                const mag = @abs(zp[1][0]) + @abs(zp[1][1]);
                try t.expect(mag > 0);
                for (0..2) |c| try t.expectApproxEqAbs(zp[1][c], zp[2][c], 1e-12 * mag);
            }
        }
        for (zs[0], zs[1]) |z1, z7| for (z1, z7) |a, b| for (a, b) |va, vb| {
            try t.expectApproxEqAbs(7 * va, vb, 1e-10 * (@abs(a[0]) + @abs(a[1])) * 7);
        };
    }

    /// 5 V through 1 kOhm into a diode (IS = 1e-14, N = 1) at 27 °C.
    fn diodeBias(lib: *const Library) !@import("device").Circuit {
        var b = try Builder.init(gpa, lib);
        const n_in = try b.addNode();
        const n_mid = try b.addNode();
        try t.expectEqual(mid, n_mid);
        try b.addDevice(models.vsource, "", &.{ .dc = 5 }, &.{}, .{ n_in, GROUND });
        try b.addDevice(models.resistor, "", &.{ .r = 1000 }, &.{}, .{ n_in, n_mid });
        try b.addDevice(models.diode, "", &.{ .is = 1e-14 }, &.{}, .{ n_mid, GROUND });
        try b.addDevice(models.capacitor, "", &.{ .c = 1e-9 }, &.{}, .{ n_mid, GROUND });
        return b.compile();
    }
    const mid: u32 = 2;
    /// Tight enough that Newton's own stopping error is far below the FD
    /// and KCL tolerances below.
    const tight: op.Options = .{ .tol = .{ .reltol = 1e-10, .vntol = 1e-12, .abstol = 1e-15 } };

    test "diode op: KCL at the solved point by hand; AC at ω = 0 and .tf equal the FD of two operating points" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try diodeBias(&lib);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const n = ckt.n;
        const x = try gpa.alloc(f64, 3 * n);
        defer gpa.free(x);
        const x_op = x[0..n];
        try t.expect((try op.solve(&ckt, x_op, tight, &.{}, &.{})).converged);

        // Certificate: (5 − v)/R = IS·(exp(v/Vt) − 1), with the diode
        // model's own k/q (ngspice's) at 300.15 K. Its junction gmin
        // (1e-12 S, 0.7 pA here) sits below the bound.
        const v = x_op[mid];
        const vt = 1.38064852e-23 / 1.6021766208e-19 * 300.15;
        const i_r = (5 - v) / 1000;
        try t.expectApproxEqAbs(i_r, 1e-14 * (@exp(v / vt) - 1), 1e-9 * i_r);

        var br: u32 = 0;
        for (ckt.current_row, 0..) |is_branch, i| if (is_branch) {
            br = @intCast(i);
        };
        // AC at ω = 0: the unit drive on the source's branch row.
        const ac = blk: {
            var fs = try FreqSolver.fromCircuit(gpa, &ckt, x_op);
            defer fs.deinit();
            const rhs = try gpa.alloc(f64, 2 * n);
            defer gpa.free(rhs);
            @memset(rhs, 0);
            rhs[br] = 1;
            const xs = try gpa.alloc(f64, 2 * n);
            defer gpa.free(xs);
            try fs.solveBatch(&.{0}, .{}, rhs, xs, false);
            try t.expectEqual(@as(f64, 0), xs[n + mid]);
            break :blk xs[mid];
        };
        const gain = (try tf.solve(&ckt, x_op, .{ .output_node = mid }, br, gpa)).gain;

        // dv/dVin by a central difference of two tight operating points;
        // h = 10 mV moves the diode current 0.2 %, so truncation is ~1e-6.
        const refs = try ckt.collectParams();
        const dc = for (refs) |r| {
            if (std.mem.eql(u8, r.param_name, "dc") and r.get() == 5) break r;
        } else return error.TestUnexpectedResult;
        const h = 1e-2;
        for ([_]f64{ 5 + h, 5 - h }, [_][]f64{ x[n..][0..n], x[2 * n ..][0..n] }) |vin, xs| {
            dc.set(vin);
            try ckt.recompute();
            try t.expect((try op.solve(&ckt, xs, tight, &.{}, &.{})).converged);
        }
        dc.set(5);
        try ckt.recompute();
        const fd = (x[n + mid] - x[2 * n + mid]) / (2 * h);
        try t.expect(fd > 0 and fd < 0.01);
        try t.expectApproxEqRel(fd, ac, 1e-5);
        try t.expectApproxEqRel(ac, gain, 1e-12);
    }

    test "sp: a .net query refuses more than two legs, a balanced port counting twice" {
        var lib = try Library.init(gpa);
        defer lib.deinit();
        var prepared = try rlc(&lib, 1);
        defer prepared.deinit();
        var ckt = try analysis.Circuit.instantiate(&prepared, gpa);
        defer ckt.deinit();
        const x = try gpa.alloc(f64, ckt.n);
        defer gpa.free(x);
        @memset(x, 0);
        const Port = @import("core").query.Port;
        const ports = [_]Port{
            .{ .node = 1, .branch = Port.no_branch, .balanced = .{ .node = 2, .branch = Port.no_branch } },
            .{ .node = 3, .branch = Port.no_branch },
        };
        const ctx: analysis.RunCtx = .{ .circuit = &ckt, .x_op = x, .probes = &.{}, .source_node = 1, .source_branch = 0, .allocator = gpa, .scratch_allocator = gpa };
        try t.expectError(error.InvalidQueryOptions, sp.run(&ctx, .{ .sweep = .{ .f_start = 1, .f_stop = 1 }, .net = true, .ports = &ports }));
    }
};

test {
    _ = StreamTests;
    _ = NoiseTests;
    _ = LstbTests;
    _ = CircuitTests;
    // The in-file tests of the frequency-domain drivers.
    _ = @import("../ac/acmatch.zig");
    _ = @import("../ac/lstb.zig");
    _ = @import("../ac/sp.zig");
}
