//! The KCL certificate (analysis/certify.zig, #53) on a real generated device:
//! a converged point passes the converger's own gate, a moved one fails it,
//! and measuring leaves the circuit as it found it.
const std = @import("std");
const analysis = @import("../types.zig");
const certify = @import("../certify.zig");
const Builder = @import("builder").Builder;
const Library = @import("device").Library;
const eval = @import("device_eval");
const converger = @import("solver").converger;
const D = @import("limiter_device");
const t = std.testing;

test "KCL certificate: a converged OP passes its gate, a moved x does not, and the planes survive" {
    var lib = try Library.init(t.allocator);
    defer lib.deinit();
    var b = try Builder.init(t.allocator, &lib);
    const out = try b.addNode();
    const vt = eval.deviceVtable(D, "va_limit_state");
    const proto = try b.protoOf(try lib.register("va_limit_state", vt, false));
    const model: D.Model = .{};
    const instance: D.Instance = .{};
    const nodes = [_]u32{ out, analysis.GROUND };
    try vt.proto_add(proto.ctx, t.allocator, @ptrCast(&model), @ptrCast(&instance), &nodes).unwrap();
    var prepared = try b.compile();
    defer prepared.deinit();
    var ckt = try analysis.Circuit.instantiate(&prepared, t.allocator);
    defer ckt.deinit();
    try ckt.computeBaseline();
    var ws = try converger.Workspace.init(t.allocator, ckt.n, ckt.col_ptr, ckt.row_idx, ckt.bbd, .{}, .{});
    defer ws.deinit(t.allocator);
    const x = try t.allocator.alloc(f64, ckt.n);
    defer t.allocator.free(x);
    @memset(x, 0);
    ckt.setSimState(.{ .t = 0, .dt = 1, .kind = .dc });
    const opts: converger.Options = .{ .gmin = 0, .max_iter = 100, .init_fix = true };
    const r = try converger.run(&ckt, &ws, x, 0, opts, analysis.EvalHook{});
    try t.expect(r.converged);

    const scratch = try t.allocator.alloc(f64, certify.scratchLen(&ckt));
    defer t.allocator.free(scratch);
    const before = try t.allocator.alloc(f64, scratch.len);
    defer t.allocator.free(before);
    const snap = struct {
        fn f(c: *const analysis.Circuit, dst: []f64) void {
            var off: usize = 0;
            inline for (.{ "g_vals", "c_vals", "rhs", "q_vec" }) |p| {
                @memcpy(dst[off..][0..@field(c, p).len], @field(c, p));
                off += @field(c, p).len;
            }
        }
    }.f;
    snap(&ckt, before);

    const pass = certify.measure(&ckt, analysis.EvalHook{}, x, 0, opts, scratch);
    try t.expectEqual(@as(?u32, null), pass.gate_row);
    try t.expect(std.math.isFinite(pass.ratio));
    const after = try t.allocator.alloc(f64, scratch.len);
    defer t.allocator.free(after);
    snap(&ckt, after);
    try t.expectEqualSlices(u64, @ptrCast(before), @ptrCast(after));

    // 0.3 V off the root, |F| = e^2.3 - e^2 = 2.6 A against a gate of
    // 10 * e^2.3 * (reltol * 2.3 + vntol) = 0.23 A.
    for (x) |*xi| if (@abs(xi.* - 2.0) <= 1e-6) {
        xi.* += 0.3;
    };
    const fail = certify.measure(&ckt, analysis.EvalHook{}, x, 0, opts, scratch);
    try t.expect(fail.gate_row != null);
    try t.expect(fail.gate_f > fail.gate_tol);
    try t.expect(fail.ratio > pass.ratio);
}
