//! Generated-device integration across the real batch, Circuit and solver seams.
const std = @import("std");
const analysis = @import("../types.zig");
const Builder = @import("builder").Builder;
const eval = @import("device_eval");
const converger = @import("solvers").converger;
const D = @import("limiter_device");
const t = std.testing;

test "generated limiter: failed trial rollback and retry match an untried circuit" {
    inline for (.{ converger.newton, converger.jfnk }) |solve| {
        var b = try Builder.init(t.allocator);
        const out = try b.addNode();
        const vt = eval.deviceVtable(D, "va_limit_state");
        const proto = try b.dynProto(vt);
        const model: D.Model = .{};
        const instance: D.Instance = .{};
        const nodes = [_]u32{ out, analysis.GROUND };
        try vt.proto_add(proto.ctx, t.allocator, @ptrCast(&model), @ptrCast(&instance), &nodes).unwrap();
        var prepared = try b.compile();
        defer prepared.deinit();
        var tried = try analysis.Circuit.instantiate(&prepared, t.allocator);
        defer tried.deinit();
        var clean = try analysis.Circuit.instantiate(&prepared, t.allocator);
        defer clean.deinit();
        try tried.computeBaseline();
        try clean.computeBaseline();
        var ws = try converger.Workspace.init(t.allocator, tried.n, tried.col_ptr, tried.row_idx, tried.bbd);
        defer ws.deinit(t.allocator);
        const xs = try t.allocator.alloc(f64, tried.n);
        defer t.allocator.free(xs);
        const xc = try t.allocator.alloc(f64, clean.n);
        defer t.allocator.free(xc);
        @memset(xs, 0);
        @memset(xc, 0);
        const options: converger.Options = .{ .gmin = 0, .max_iter = 100 };
        for ([_]*analysis.Circuit{ &tried, &clean }, [_][]f64{ xs, xc }) |ckt, x| {
            ckt.setSimState(.{ .t = 0, .dt = 1, .kind = .dc });
            try t.expect((try solve(ckt, &ws, x, 0, options, analysis.EvalHook{})).converged);
            _ = ckt.stateCtl(.commit);
        }
        // Simulate the Newton-failure rejection path at a later trial time.
        tried.setSimState(.{ .t = 1, .dt = 1, .kind = .tran });
        try t.expect(!(try solve(&tried, &ws, xs, 1, .{ .gmin = 0, .max_iter = 2 }, analysis.EvalHook{})).converged);
        _ = tried.stateCtl(.revert);
        @memcpy(xs, xc);
        for ([_]*analysis.Circuit{ &tried, &clean }) |ckt|
            ckt.setSimState(.{ .t = 0.5, .dt = 0.5, .kind = .tran });
        tried.eval(xs, 0.5);
        clean.eval(xc, 0.5);
        try t.expectEqualSlices(f64, clean.rhs, tried.rhs);
        try t.expectEqualSlices(f64, clean.q_vec, tried.q_vec);
        const retried = try solve(&tried, &ws, xs, 0.5, options, analysis.EvalHook{});
        const direct = try solve(&clean, &ws, xc, 0.5, options, analysis.EvalHook{});
        try t.expect(retried.converged and direct.converged);
        try t.expectEqual(direct.iterations, retried.iterations);
        try t.expectEqualSlices(f64, xc, xs);
        _ = tried.stateCtl(.commit);
        _ = clean.stateCtl(.commit);
        tried.eval(xs, 0.5);
        clean.eval(xc, 0.5);
        try t.expectEqualSlices(f64, clean.rhs, tried.rhs);
        try t.expectEqualSlices(f64, clean.q_vec, tried.q_vec);
    }
}

const testing = std.testing;
const GROUND = analysis.GROUND;

test "jfnk vs newton: divider OP agrees to 1e-9" {
    var b = try Builder.init(testing.allocator);
    const vin = try b.addNode();
    const out = try b.addNode();
    try b.addDevice(@import("models").vsource, .{ .dc = 10 }, .{}, .{ vin, GROUND });
    try b.addDevice(@import("models").resistor, .{ .r = 1000 }, .{}, .{ vin, out });
    try b.addDevice(@import("models").resistor, .{ .r = 3000 }, .{}, .{ out, GROUND });
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try analysis.Circuit.instantiate(&prepared, testing.allocator);
    defer ckt.deinit();

    try ckt.computeBaseline();

    // Newton (direct)
    var ws_n = try converger.Workspace.init(testing.allocator, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer ws_n.deinit(testing.allocator);
    const x_n = try testing.allocator.alloc(f64, ckt.n);
    defer testing.allocator.free(x_n);
    @memset(x_n, 0);
    const nr = try converger.newton(&ckt, &ws_n, x_n, 0, .{}, analysis.EvalHook{});
    try testing.expect(nr.converged);

    // JFNK
    var ws_j = try converger.Workspace.init(testing.allocator, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer ws_j.deinit(testing.allocator);
    const x_j = try testing.allocator.alloc(f64, ckt.n);
    defer testing.allocator.free(x_j);
    @memset(x_j, 0);
    const jr = try converger.jfnk(&ckt, &ws_j, x_j, 0, .{}, analysis.EvalHook{});
    try testing.expect(jr.converged);

    for (0..ckt.n) |i| {
        try testing.expectApproxEqAbs(x_n[i], x_j[i], 1e-9);
    }
}

test "jfnk: 100-diode ladder converges" {
    const n_diodes: usize = 100;
    var b = try Builder.init(testing.allocator);
    const vin = try b.addNode();
    try b.addDevice(@import("models").vsource, .{ .dc = 5 }, .{}, .{ vin, GROUND });

    // Chain: R—D—R—D—...—GND
    var prev: u32 = vin;
    for (0..n_diodes) |_| {
        const mid = try b.addNode();
        try b.addDevice(@import("models").resistor, .{ .r = 100 }, .{}, .{ prev, mid });
        try b.addDevice(@import("models").diode, .{ .is = 1e-14 }, .{}, .{ mid, GROUND });
        prev = mid;
    }
    // Final resistor to ground
    try b.addDevice(@import("models").resistor, .{ .r = 100 }, .{}, .{ prev, GROUND });

    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try analysis.Circuit.instantiate(&prepared, testing.allocator);
    defer ckt.deinit();
    try ckt.computeBaseline();

    var ws = try converger.Workspace.init(testing.allocator, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd);
    defer ws.deinit(testing.allocator);
    const x = try testing.allocator.alloc(f64, ckt.n);
    defer testing.allocator.free(x);
    @memset(x, 0);

    const r = try converger.jfnk(&ckt, &ws, x, 0, .{
        .max_iter = 200,
        .abstol = 1e-9,
    }, analysis.EvalHook{});
    try testing.expect(r.converged);

    // Sanity: first node should be near 5V (source), diode nodes between 0 and 1V
    try testing.expectApproxEqAbs(@as(f64, 5.0), x[vin], 1e-3);
}
