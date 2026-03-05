//! Numerical regressions through the owning Problem API.
const std = @import("std");
const api = @import("problem");
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
    // An RC with the source at 0 V: the operating point is v(2) = 0, so a
    // transient that ran the OP starts flat at zero. With `uic` the cap starts
    // charged at 1 V and decays — the two are unmistakable.
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

    // ...and it must decay: one RC is 1 ms, so by 2 ms it is well under half.
    const v2_last = probeLast(res, "2") orelse return error.NoProbe;
    try std.testing.expect(v2_last < 0.5);
}

test "uic: without the keyword the transient starts from the operating point" {

    // Same deck, same .ic card, no `uic`: the OP wins and v(2) starts at 0.
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
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), v2_first, 1e-9);
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

    // ngspice 44.2 on this deck: i(v1) = -1e-3 (current INTO the + terminal),
    // i(l1) = +1e-3 (p->n through the inductor). Signs must match exactly.
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
    // Branch probes go FIRST: tf/sens/dcmatch/pxf/pac/disto default their
    // output to probes[len-1], which must remain the last named node.
    try std.testing.expect(std.mem.startsWith(u8, res.varnames[res.varnames.len - 1], "v("));
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

/// Probe columns are named `v(<node>)`/`i(<card>)` (probeNames) and a
/// transient's column 0 is "time". Result.data is ROW-major:
/// data[point * ncols + col].
fn probeColumn(r: Result, node: []const u8) ?usize {
    var buf: [64]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "v({s})", .{node}) catch return null;
    // ponytail: reuse the exact, first-match lookup already used for source names.
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
        \\.end
    );
    defer sim.deinit();
    for (0..2) |ordinal| {
        const result = try requestedResult(sim, ordinal);
        for (result.varnames, 0..) |name, i| {
            for (result.varnames[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, name, previous));
        }
        // `.sens` names columns after the CARD, ngspice-style (v(r1));
        // `.dcmatch` still keys by device-class ordinal.
        const sens_cols = std.mem.eql(u8, result.plotname, "Sensitivity Analysis");
        const r1 = findNameIndex(result.varnames, if (sens_cols) "v(r1)" else "resistor#0.r") orelse return error.MissingSensitivity;
        const r2 = findNameIndex(result.varnames, if (sens_cols) "v(r2)" else "resistor#1.r") orelse return error.MissingSensitivity;
        try std.testing.expectApproxEqAbs(@as(f64, -0.001875), result.data[r1], 1e-8);
        try std.testing.expectApproxEqAbs(@as(f64, 0.000625), result.data[r2], 1e-8);
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
