//! Numerical regressions run end to end through the Problem API.
const std = @import("std");
const api = @import("espice");
const Result = api.Result;

fn runDeck(source: []const u8) !*api.Problem {
    const problem = try api.Problem.init(std.testing.allocator, std.testing.io, .{
        .source = .{ .bytes = .{ .data = source, .origin = "legacy.cir" } },
    });
    errdefer problem.deinit();
    try problem.run_all();
    return problem;
}

fn requestedResult(problem: *const api.Problem, ordinal: usize) !Result {
    var found: usize = 0;
    for (0..problem.query_count()) |i| {
        const id: api.QueryId = @enumFromInt(i);
        const info = try problem.query_info(id);
        if (!info.requested) continue;
        if (found == ordinal) return problem.result(id);
        found += 1;
    }
    return error.MissingRequestedResult;
}

fn findNameIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

test "spectral queries cannot publish an unconverged result" {
    const jobs = [_]api.Query{
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 1, .max_iter = 1 } },
        .{ .qpss = .{ .f1 = 1e3, .f2 = 1414, .k1 = 1, .k2 = 1, .max_newton = 1 } },
    };
    for (jobs) |job| {
        const problem = try api.Problem.init(std.testing.allocator, std.testing.io, .{
            .source = .{ .bytes = .{ .origin = "unconverged.cir", .data =
            \\unconverged spectrum
            \\vin in 0 dc 0 sin(0 1 1k)
            \\r1 in out 1k
            \\c1 out 0 1u
            \\.end
            } },
        });
        defer problem.deinit();
        var ids: [1]api.QueryId = undefined;
        _ = try problem.append_queries(&.{job}, &ids);
        const expected = if (job == .hb) error.HbDidNotConverge else error.QpssDidNotConverge;
        try std.testing.expectError(expected, problem.run_all());
        try std.testing.expectEqual(api.Status.failed, (try problem.query_info(ids[0])).status);
        try std.testing.expectError(error.ResultUnavailable, problem.result(ids[0]));
    }
}

test "pz cannot publish a partial root set" {
    const problem = try api.Problem.init(std.testing.allocator, std.testing.io, .{
        .source = .{ .bytes = .{ .origin = "ladder.cir", .data =
        \\three-pole ladder
        \\v1 in 0 dc 0 ac 1
        \\r1 in 1 1k
        \\c1 1 0 1u
        \\r2 1 2 1k
        \\c2 2 0 1u
        \\r3 2 3 1k
        \\c3 3 0 1u
        \\.end
        } },
    });
    defer problem.deinit();
    var ids: [1]api.QueryId = undefined;
    _ = try problem.append_queries(&.{.{ .pz = .{ .qr_max_iter = 1 } }}, &ids);
    try std.testing.expectError(error.PzDidNotConverge, problem.run_all());
    try std.testing.expectError(error.ResultUnavailable, problem.result(ids[0]));
}

test "pz of a femtosecond RC ladder: closed-form poles, no finite zeros" {
    // RC = 1 fs puts A = −G⁻¹C near 1e-12, where the QR's shift polynomial
    // (entries squared) fell under absolute 1e-30 guards, skipped its
    // reflectors and cycled on the numerator's nilpotent block until
    // PzDidNotConverge (5 and 30 stages both did). Poles of N equal sections
    // driven by a shorted source: s_k = −4 sin²((2k−1)π / (2(2N+1))) / RC.
    const r = 100.0;
    const c = 10e-15;
    inline for (.{ 5, 30 }) |stages| {
        var deck: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer deck.deinit();
        const w = &deck.writer;
        try w.print("rc ladder\nv1 n0 0 0 ac 1\n", .{});
        for (0..stages) |i| try w.print("r{d} n{d} n{d} {e}\nc{d} n{d} 0 {e}\n", .{ i, i, i + 1, r, i, i + 1, c });
        try w.print(".pz n0 0 n{d} 0 vol pz\n.end\n", .{stages});

        const problem = try runDeck(deck.written());
        defer problem.deinit();
        const res = try requestedResult(problem, 0);
        var poles: [stages]f64 = undefined;
        var n_poles: usize = 0;
        for (res.varnames, 0..) |name, k| {
            try std.testing.expect(!std.mem.startsWith(u8, name, "zero"));
            if (!std.mem.startsWith(u8, name, "pole")) continue;
            try std.testing.expectEqual(@as(f64, 0), res.data[2 * k + 1]);
            poles[n_poles] = res.data[2 * k];
            n_poles += 1;
        }
        try std.testing.expectEqual(@as(usize, stages), n_poles);
        std.mem.sort(f64, &poles, {}, std.sort.desc(f64));
        for (poles, 1..) |p, k| {
            const kf: f64 = @floatFromInt(2 * k - 1);
            const sn = @sin(kf * std.math.pi / (2 * (2 * stages + 1)));
            try std.testing.expectApproxEqRel(-4 * sn * sn / (r * c), p, 1e-12);
        }
    }
}

test "pz of a bridged RC ladder: one zero per bridge, at -1/(R·Cb)" {
    // A capacitor across a series resistor blocks transmission where that
    // section's admittance 1/R + s·Cb vanishes, and nowhere else: every other
    // root of the numerator is at infinity. The old A = −M⁻¹C route found 8
    // zeros for this kind of deck where there are 2, or none.
    const problem = try runDeck(
        \\bridged ladder
        \\v1 n0 0 0 ac 1
        \\r0 n0 n1 1k
        \\c0 n1 0 1n
        \\r1 n1 n2 2.2k
        \\cb1 n1 n2 10p
        \\c1 n2 0 1n
        \\r2 n2 n3 1k
        \\c2 n3 0 1n
        \\r3 n3 n4 4.7k
        \\c3 n4 0 1n
        \\r4 n4 n5 3.3k
        \\cb4 n4 n5 22p
        \\c4 n5 0 1n
        \\r5 n5 n6 1k
        \\c5 n6 0 1n
        \\.pz n0 0 n6 0 vol pz
        \\.end
    );
    defer problem.deinit();
    const res = try requestedResult(problem, 0);
    var zeros: [2]f64 = undefined;
    var n_zeros: usize = 0;
    var n_poles: usize = 0;
    for (res.varnames, 0..) |name, k| {
        if (std.mem.startsWith(u8, name, "pole")) n_poles += 1;
        if (!std.mem.startsWith(u8, name, "zero")) continue;
        try std.testing.expect(n_zeros < zeros.len);
        try std.testing.expectEqual(@as(f64, 0), res.data[2 * k + 1]);
        zeros[n_zeros] = res.data[2 * k];
        n_zeros += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), n_poles);
    try std.testing.expectEqual(@as(usize, 2), n_zeros);
    std.mem.sort(f64, &zeros, {}, std.sort.asc(f64));
    try std.testing.expectApproxEqRel(-1.0 / (2.2e3 * 10e-12), zeros[0], 1e-12);
    try std.testing.expectApproxEqRel(-1.0 / (3.3e3 * 22e-12), zeros[1], 1e-12);
}

test "hbnoise and shooting pnoise agree about a diode mixer's orbit" {
    // The two orbit providers feed one linearization and sideband fold, so
    // what is left between them is the shooting orbit's trapezoid error
    // (64 steps a period), about 2e-4 here. The flicker term puts a
    // sideband exactly at DC for f = 1 kHz.
    const sim = try runDeck(
        \\diode mixer
        \\vlo lo 0 dc 0 sin(0.5 0.3 1k)
        \\r1 lo a 1k
        \\d1 a out dmod
        \\r2 out 0 10k
        \\c1 out 0 10n
        \\.model dmod d is=1e-14 cjo=1p kf=1e-16
        \\.pnoise v(out) vlo dec 2 10 10k 1k 3
        \\.hbnoise v(out) vlo dec 2 10 10k 1k 16 3
        \\.end
    );
    defer sim.deinit();
    const shooting = try requestedResult(sim, 0);
    const hb = try requestedResult(sim, 1);
    try std.testing.expectEqual(@as(usize, 7), hb.npoints);
    for (0..hb.npoints) |i| {
        try std.testing.expectEqual(shooting.data[2 * i], hb.data[2 * i]);
        try std.testing.expectApproxEqRel(shooting.data[2 * i + 1], hb.data[2 * i + 1], 1e-3);
    }
}

test "multi-tone hb in a box is qpss's two-sided spectrum folded onto one side" {
    // One square-law mixer through both solvers. QPSS keeps both lines of
    // each conjugate pair, so every positive line is twice its |X_kl| and
    // DC is DC. The tones are incommensurate: neither grid has a period.
    const sim = try runDeck(
        \\square-law mixer
        \\v1 a 0 sin(0 1 1000)
        \\v2 b 0 sin(0 0.5 1414.213562373095)
        \\bout out 0 v=(v(a)+v(b))^2
        \\rload out 0 1k
        \\.hb tones=1000 1414.213562373095 nharms=2 2 intmodmax=4
        \\.qpss 1000 1414.213562373095 2 2
        \\.end
    );
    defer sim.deinit();
    const hb = try requestedResult(sim, 0);
    const qpss = try requestedResult(sim, 1);
    const col = findNameIndex(hb.varnames, "v(out)").?;
    try std.testing.expectEqual(@as(usize, 13), hb.npoints);
    try std.testing.expectEqual(@as(usize, 25), qpss.npoints);
    // `.hb TONES=` rows are complex phasors; QPSS's are magnitudes.
    try std.testing.expect(hb.is_complex);
    const w = hb.varnames.len;
    for (0..hb.npoints) |i| {
        const f = hb.data[i * 2 * w];
        const q = for (0..qpss.npoints) |k| {
            if (@abs(qpss.data[k * w] - f) < 1e-6) break qpss.data[k * w + col];
        } else return error.TestUnexpectedResult;
        const want = if (f == 0) q else 2 * q;
        const x = hb.data[(i * w + col) * 2 ..][0..2];
        try std.testing.expectApproxEqAbs(want, if (f == 0) x[0] else std.math.hypot(x[0], x[1]), 1e-8);
    }
}

test "a failed query does not prevent an independent query from completing" {
    const p = try api.Problem.init(std.testing.allocator, std.testing.io, .{
        .source = .{ .bytes = .{ .data = "failure isolation\nV1 in 0 dc 1 ac 1 sin(0 1 1k)\nR1 in out 1k\nC1 out 0 1u\n.end\n", .origin = "failure.cir" } },
        .max_parallel = 2,
    });
    defer p.deinit();
    var ids: [2]api.QueryId = undefined;
    _ = try p.append_queries(&.{
        .{ .hb = .{ .f0 = 1e3, .n_harmonics = 1, .max_iter = 1 } },
        .{ .ac = .{ .sweep = .{ .f_start = 1, .f_stop = 10, .points = 2 } } },
    }, &ids);
    try std.testing.expectError(error.HbDidNotConverge, p.run_all());
    try std.testing.expectEqual(api.Status.failed, (try p.query_info(ids[0])).status);
    try std.testing.expectError(error.ResultUnavailable, p.result(ids[0]));
    try std.testing.expectEqual(api.Status.complete, (try p.query_info(ids[1])).status);
    const result = try p.result(ids[1]);
    try std.testing.expectEqual(@as(usize, 3), result.npoints);
    try std.testing.expectEqual(error.HbDidNotConverge, (try p.advance(ids[0])).failure.?);
    try std.testing.expectError(error.HbDidNotConverge, p.run_all());
    try std.testing.expectEqual(result.data.ptr, (try p.result(ids[1])).data.ptr);
}

test "envelope exhaustion and failed minimum step terminate without publishing" {
    for ([_]bool{ false, true }) |fail_newton| {
        const problem = try api.Problem.init(std.testing.allocator, std.testing.io, .{
            .source = .{ .bytes = .{ .origin = "envelope.cir", .data =
            \\envelope termination
            \\vin in 0 pulse(0 1 1n 1p 1p 1m 2m)
            \\r1 in out 1k
            \\r2 out 0 1k
            \\.end
            } },
        });
        defer problem.deinit();
        var ids: [1]api.QueryId = undefined;
        _ = try problem.append_queries(&.{.{ .envelope = .{
            .t_carrier = 1e-6,
            .t_stop = 1e-5,
            .max_outer_steps = if (fail_newton) 100 else 1,
            .tol = .{ .itl4 = if (fail_newton) 1 else 10 },
        } }}, &ids);
        // A failed minimum step must become terminal in this quantum, rather
        // than pausing forever at the same rejected outer-step boundary.
        var calls: usize = 0;
        while (!(try problem.query_info(ids[0])).status.terminal() and calls < 8) : (calls += 1)
            _ = try problem.advance(ids[0]);
        const info = try problem.query_info(ids[0]);
        try std.testing.expectEqual(api.Status.failed, info.status);
        try std.testing.expectEqual(error.EnvelopeDidNotConverge, info.failure.?);
        try std.testing.expectError(error.ResultUnavailable, problem.result(ids[0]));
    }
}

test "uic: .ic seeds the transient and the OP is skipped" {
    // RC with the source at 0 V: the OP gives v(2) = 0, while `uic` starts the
    // cap at the 1 V IC and lets it decay.
    const sim = try runDeck(
        \\uic rc
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=1.0
        \\.tran 1u 2m uic
        \\.end
    );
    defer sim.deinit();

    const res = try requestedResult(sim, 0);
    try std.testing.expectEqual(@as(u32, 1), sim.query_count());
    // v(2) at t=0 must be the IC, not the OP's zero.
    const v2_first = probeFirst(res, "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v2_first, 1e-9);

    // One RC is 1 ms, so by 2 ms it has decayed well under half.
    const v2_last = probeLast(res, "2") orelse return error.NoProbe;
    try std.testing.expect(v2_last < 0.5);
}

test "uic: without the keyword the operating point holds the .ic nodes" {
    // Same deck, same .ic card, no `uic`: the transient's OP holds v(2) at
    // its .ic (ngspice MODETRANOP, cktload.c), so v(2) starts at 1, not 0.
    const sim = try runDeck(
        \\op rc
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=1.0
        \\.tran 1u 2m
        \\.end
    );
    defer sim.deinit();

    const v2_first = probeFirst(try requestedResult(sim, 0), "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), v2_first, 1e-9);
}

test "uic: keyword is positional-independent and .ic on an unknown node is dropped" {
    const sim = try runDeck(
        \\uic forms
        \\v1 1 0 dc 0
        \\r1 1 2 1k
        \\c1 2 0 1u
        \\.ic v(2)=0.25 v(nosuchnode)=9.0
        \\.tran 1u 2m 0 1u uic
        \\.end
    );
    defer sim.deinit();

    // The unknown IC node does not affect the surviving node.
    const v2_first = probeFirst(try requestedResult(sim, 0), "2") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), v2_first, 1e-9);
}

test "branch currents: op emits i(<card>) with ngspice's sign, last probe stays a node" {
    // ngspice 44.2 on this deck: i(v1) = -2e-3 (current into the + terminal),
    // i(l1) = +2e-3 (p->n through the inductor).
    const sim = try runDeck(
        \\divider
        \\v1 1 0 dc 1
        \\r1 1 2 500
        \\l1 2 0 1m
        \\.op
        \\.end
    );
    defer sim.deinit();

    const res = try requestedResult(sim, 0);
    const iv = findNameIndex(res.varnames, "i(v1)") orelse return error.NoBranchColumn;
    const il = findNameIndex(res.varnames, "i(l1)") orelse return error.NoBranchColumn;
    try std.testing.expectApproxEqAbs(@as(f64, -2e-3), res.data[iv], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2e-3), res.data[il], 1e-9);
    // Branch probes come first, so the last probe is a named node.
    try std.testing.expect(std.mem.startsWith(u8, res.varnames[res.varnames.len - 1], "v("));
}

test "bsource: expressions of several probes match ngspice at the operating point" {
    // ngspice 45 on this deck (numdgt=12), except v(c): ngspice's default
    // `^` is |x|^3 = +0.421875; an integer power keeps the sign here.
    const sim = try runDeck(
        \\bsource multi-probe op
        \\va a 0 1.5
        \\vb b 0 -0.75
        \\bm m 0 v=v(a)*v(b)
        \\bs s 0 v=(v(a)+v(b))^2
        \\bc c 0 v=v(b)^3
        \\bd d 0 v=v(a,b)/v(a) + sqrt(v(a)+1) - exp(v(b)) + log10(v(a)+1) + ln(v(a)+2)
        \\bt t 0 v=v(a) > 0 ? tanh(v(b)) : 0
        \\bx x 0 v=min(v(a),v(b)) + max(v(a),v(b))*atan(v(b)) + abs(v(b)) + (v(a)+1)^0.5
        \\bi 0 ni i=v(a)*v(b)*1m + v(ni)*v(ni)*1m
        \\rm m 0 1k
        \\rs s 0 1k
        \\rc c 0 1k
        \\rd d 0 1k
        \\rt t 0 1k
        \\rx x 0 1k
        \\rni ni 0 1k
        \\.op
        \\.end
    );
    defer sim.deinit();

    const res = try requestedResult(sim, 0);
    const want = [_]struct { []const u8, f64 }{
        .{ "v(m)", -1.125 },           .{ "v(s)", 0.5625 },
        .{ "v(c)", -0.421875 },        .{ "v(d)", 4.259475254511 },
        .{ "v(t)", -0.635148952387 },  .{ "v(x)", 0.6158871668943 },
        .{ "v(ni)", -0.672603939956 }, .{ "i(bm)", 1.125e-3 },
    };
    for (want) |w| {
        const k = findNameIndex(res.varnames, w[0]) orelse return error.MissingColumn;
        try std.testing.expectApproxEqRel(w[1], res.data[k], 1e-9);
    }
}

test "urc: U card expands into a lump ladder whose series R telescopes to L*RPERL" {
    // r0 = L*RPERL = 1k against a 1k load: v(out) is 0.5 iff the geometric
    // lump sizing (r1*K^i from both ends) sums back to exactly r0 and the
    // two half-chains actually meet in the middle.
    const sim = try runDeck(
        \\urc ladder
        \\v1 in 0 dc 1
        \\u1 in out 0 umod l=1 n=4
        \\rl out 0 1k
        \\.model umod urc(rperl=1000 cperl=1u)
        \\.op
        \\.end
    );
    defer sim.deinit();

    const vout = probeLast(try requestedResult(sim, 0), "out") orelse return error.NoProbe;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), vout, 1e-6);
}

/// The column of `v(<node>)`. Result.data is row-major:
/// data[point * varnames.len + col].
fn probeColumn(r: Result, node: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "v({s})", .{node}) catch return null;
    // ponytail: exact first match, no SPICE name aliasing; add it when a probe needs it.
    return findNameIndex(r.varnames, want);
}

fn probeAt(r: Result, node: []const u8, point: usize) ?f64 {
    const c = probeColumn(r, node) orelse return null;
    if (point >= r.npoints) return null;
    return r.data[point * r.varnames.len + c];
}

fn probeFirst(r: Result, node: []const u8) ?f64 {
    return probeAt(r, node, 0);
}

fn probeLast(r: Result, node: []const u8) ?f64 {
    if (r.npoints == 0) return null;
    return probeAt(r, node, r.npoints - 1);
}

test "tf resolves numeric output and named second input before parse arena dies" {
    const sim = try runDeck(
        \\two independent inputs
        \\va ignored 0 dc 2
        \\vb in 0 dc 10
        \\r1 in 2 1k
        \\r2 2 0 3k
        \\.tf v(2) vb
        \\.end
    );
    defer sim.deinit();
    const result = try requestedResult(sim, 0);
    try std.testing.expectEqualStrings("Transfer Function", result.plotname);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), result.data[0], 1e-9);
}

test "sensitivity and mismatch keep separate resistor parameters and analytical derivatives" {
    const sim = try runDeck(
        \\parameter derivatives
        \\vin in 0 dc 10
        \\r1 in out 1k
        \\r2 out 0 3k
        \\.sens v(out)
        \\.dcmatch v(out)
        \\.sens v(in, out)
        \\.dcmatch v(in, out)
        \\.end
    );
    defer sim.deinit();
    for (0..4) |ordinal| {
        // v(in) is pinned, so v(in, out) moves exactly opposite to v(out).
        const sign: f64 = if (ordinal < 2) 1 else -1;
        const result = try requestedResult(sim, ordinal);
        for (result.varnames, 0..) |name, i| {
            for (result.varnames[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, name, previous));
        }
        // `.sens` names columns after the CARD, ngspice-style (v(r1));
        // `.dcmatch` still keys by device-class ordinal.
        const sens_cols = std.mem.eql(u8, result.plotname, "Sensitivity Analysis");
        const r1 = findNameIndex(result.varnames, if (sens_cols) "v(r1)" else "resistor#0.r") orelse return error.MissingSensitivity;
        const r2 = findNameIndex(result.varnames, if (sens_cols) "v(r2)" else "resistor#1.r") orelse return error.MissingSensitivity;
        try std.testing.expectApproxEqAbs(sign * -0.001875, result.data[r1], 1e-8);
        try std.testing.expectApproxEqAbs(sign * 0.000625, result.data[r2], 1e-8);
    }
}

test "Monte Carlo varies model values through the Problem API" {
    const sim = try runDeck(
        \\statistical model parameters
        \\vin in 0 dc 10
        \\r1 in out 1k
        \\r2 out 0 3k
        \\.mc 16 0.05
        \\.end
    );
    defer sim.deinit();
    const result = try requestedResult(sim, 0);
    try std.testing.expectEqual(@as(usize, 16), result.npoints);
    const out = findNameIndex(result.varnames, "v(out)") orelse return error.NoProbe;
    var varied = false;
    for (0..result.npoints) |i| {
        const value = result.data[i * result.varnames.len + out];
        try std.testing.expect(std.math.isFinite(value));
        varied = varied or @abs(value - result.data[out]) > 1e-6;
    }
    try std.testing.expect(varied);
}

test "BSIM4 tnoimod1 retains DC conduction with zero source and drain squares" {
    var currents: [2][2]f64 = undefined;
    for (&currents, 0..) |*row, mode| {
        var pa = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer pa.deinit();
        const src = try std.fmt.allocPrint(pa.allocator(),
            \\noise topology DC regression
            \\vdn dn 0 1
            \\vgn gn 0 1.2
            \\vdp dp 0 -1
            \\vgp gp 0 -1.2
            \\mn dn gn 0 0 nm l=1u w=10u nrd=0 nrs=0
            \\mp dp gp 0 0 pm l=1u w=10u nrd=0 nrs=0
            \\.model nm nmos(level=54 tnoimod={d} rdsmod=0)
            \\.model pm pmos(level=54 tnoimod={d} rdsmod=0)
            \\.op
            \\.end
        , .{ mode, mode });
        const sim = try runDeck(src);
        defer sim.deinit();
        const result = try requestedResult(sim, 0);
        for ([_][]const u8{ "i(vdn)", "i(vdp)" }, row) |name, *current| {
            const col = findNameIndex(result.varnames, name) orelse return error.NoProbe;
            current.* = result.data[col];
            try std.testing.expect(std.math.isFinite(current.*) and @abs(current.*) > 1e-6);
        }
    }
    // Noise mode must preserve DC conduction. The regression fixture checks
    // absolute ngspice accuracy separately; its existing model gap stays visible.
    for (currents[0], currents[1]) |direct, internal| try std.testing.expectApproxEqRel(direct, internal, 1e-5);
}
