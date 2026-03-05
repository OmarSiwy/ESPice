const impl = @import("device_eval");
const Batch = impl.Batch;
const DeviceBatch = impl.DeviceBatch;
const Dual = impl.Dual;
const DualFor = impl.test_access.DualFor;
const NoiseGen = impl.NoiseGen;
const NoiseSource = impl.NoiseSource;
const ProtoStore = impl.ProtoStore;
const PsdTerm = impl.PsdTerm;
const RealFor = impl.test_access.RealFor;
const deviceVtable = impl.deviceVtable;
const gpuJacFloat = impl.gpuJacFloat;
const jacFloat = impl.jacFloat;
const std = @import("std");

test "Dual: expm1 and log1p retain finite range and IEEE endpoints" {
    const S = Dual(1, f64);
    for ([_]f64{ -740, -1, -1e-17, -0.0, 0, 1e-17, 0.5, 704, 709 }) |x| {
        const y = S.seed(x, 0).expm1();
        try std.testing.expect(std.math.isFinite(y.v));
        try std.testing.expectApproxEqRel(std.math.expm1(x), y.v, 3e-15);
        try std.testing.expectEqual(@exp(x), y.ddxAt(0));
    }
    for ([_]f64{ -1, -0.9999999999999999, -1e-17, -0.0, 0, 1e-17, 0.5, 1e308, std.math.inf(f64) }) |x| {
        const y = S.seed(x, 0).log1p();
        try std.testing.expectApproxEqRel(std.math.log1p(x), y.v, 3e-15);
        try std.testing.expectEqual(1.0 / (1.0 + x), y.ddxAt(0));
    }
    try std.testing.expectEqual(std.math.inf(f64), S.seed(710, 0).expm1().v);
    try std.testing.expectEqual(std.math.inf(f64), S.seed(std.math.inf(f64), 0).expm1().v);
    try std.testing.expectEqual(@as(f64, -1), S.seed(-std.math.inf(f64), 0).expm1().v);
    try std.testing.expect(std.math.isNan(S.seed(-2, 0).log1p().v));
    try std.testing.expect(std.math.isNan(S.seed(std.math.nan(f64), 0).expm1().v));
    try std.testing.expect(std.math.isNan(S.seed(std.math.nan(f64), 0).log1p().v));
    try std.testing.expect(std.math.signbit(S.seed(-0.0, 0).expm1().v));
    try std.testing.expect(std.math.signbit(S.seed(-0.0, 0).log1p().v));
}

test "Dual: an f32 Jacobian leaves the residual bit-identical" {
    // The one invariant the whole mixed-precision construction rests on
    // (docs/gpu-device-eval.md §9): `F` is the width of the DERIVATIVE, and the
    // residual is f64 on both instantiations. Not a tolerance — every operation
    // on `.v` is the same f64 arithmetic, so the values must be EQUAL. If this
    // ever needs a tolerance, the split has leaked into the residual.
    const core = struct {
        // The diode's own core, which is what the prototype ships:
        // is·(exp(v/vt) − 1) + gmin·v.
        fn f(comptime S: type, bias: f64) S {
            const x = [2]S{ S.seed(bias, 0), S.seed(0, 1) };
            const v = x[0].sub(x[1]);
            return S.con(1e-14).mul(v.div(S.con(0.025851999786450736)).exp().addC(-1.0))
                .add(v.scale(1e-12));
        }
    }.f;
    for (0..17) |i| {
        const bias = @as(f64, @floatFromInt(i)) * 0.05;
        const a = core(Dual(2, f64), bias);
        const b = core(Dual(2, f32), bias);
        try std.testing.expectEqual(a.val(), b.val());
        // …and the Jacobian degrades to f32 precision, and only to that.
        for (0..2) |c| try std.testing.expectApproxEqRel(a.ddxAt(c), b.ddxAt(c), 1e-6);
    }
}

test "jac width: one device, two instantiations" {
    // The whole of docs/perf/jac-width-2026-09-10.md in four lines. `jac_f32`
    // is a permission the GPU kernel takes and the host declines; `jac_f32_host`
    // is the separate order that makes the host take it too. If these two ever
    // collapse back into one predicate, the GPU loses its 1.21x or the CPU
    // inherits `ngspice/mosmem`'s gmin ladder — and this is where it shows.
    const Plain = struct {};
    const Permitted = struct {
        pub const jac_f32 = true;
    };
    const Ordered = struct {
        pub const jac_f32 = true;
        pub const jac_f32_host = true;
    };
    try std.testing.expectEqual(f64, jacFloat(Plain));
    try std.testing.expectEqual(f64, gpuJacFloat(Plain));
    try std.testing.expectEqual(f64, jacFloat(Permitted));
    try std.testing.expectEqual(f32, gpuJacFloat(Permitted));
    try std.testing.expectEqual(f32, jacFloat(Ordered));
    try std.testing.expectEqual(f32, gpuJacFloat(Ordered));
}

test "RealFor: every primitive is Dual's value half, bit for bit" {
    // The invariant `evalQRange` rests on. Not a tolerance: the post-accept
    // charge re-read must reproduce the Dual pass EXACTLY, because `q_hist`/
    // `i_prev`/`q_tape` feed the next step's residual and `stepBound`'s LTE, so
    // one ulp here walks the timestep sequence off. If a `Dual` value expression
    // is ever changed (`div`'s reciprocal-multiply and `abs`'s sign test are the
    // two that do not read as the obvious thing), this fails instead of silently
    // perturbing every transient.
    const core = struct {
        fn f(comptime S: type, a: f64, b: f64) S {
            const x = S.seed(a, 0);
            const y = S.seed(b, 1);
            // One chain per primitive, so a desync anywhere lands in the result.
            var r = x.add(y).sub(y).neg().mul(x).div(y.addC(3.0)).scale(-0.5);
            r = r.abs().minC(4.0).maxC(-4.0);
            r = r.add(x.exp().log().expm1().log1p());
            r = r.add(y.addC(9.0).sqrt().pow(1.5));
            r = r.add(x.sin().cos().tanh().sinh().cosh().atan());
            r = r.add(S.sel(x.lt(y), x.max(y), x.min(y)));
            return r.add(S.sel(x.le(y).add(x.eq(y)), x, y));
        }
    }.f;
    for (0..13) |i| {
        for (0..13) |j| {
            // Spans both signs and crosses zero exactly, which is where `abs`,
            // `min`/`max` ties and `sel`'s 0/1 mask differ if they differ.
            const a = @as(f64, @floatFromInt(i)) * 0.25 - 1.5;
            const b = @as(f64, @floatFromInt(j)) * 0.25 - 1.5;
            try std.testing.expectEqual(
                core(DualFor(2, f64, false), a, b).val(),
                core(RealFor(false), a, b).val(),
            );
        }
    }
}

test "dyn vtable: blob init, param set by name, proto add" {
    const R = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        // One cold construction blob, initialized/set by name and consumed by
        // the vtable. Fixed scalar widths exercise the ABI conversion bounds;
        // no per-instance table, cross-reference or independent lane is added.
        pub const Model = struct {
            r: f32 = 1000,
            mode: i8 = 0,
            mode__given: bool = false,
            count: u64 = 0,
            wide: i64 = 0,
        };
        pub const Instance = struct { temp: f32 = 300.15 };
        pub fn eval(comptime Sc: type, x: [2]Sc, m: *const Model, _: *const Instance, _: f64) [2]Sc {
            const i = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
            return .{ i, i.neg() };
        }
    };
    const testing = std.testing;
    const vt = deviceVtable(R, "tres");
    try testing.expectEqual(@as(u32, 2), vt.n_u);
    try testing.expectEqual(@sizeOf(R.Model), vt.model_size);

    var mblob: [@sizeOf(R.Model)]u8 align(16) = undefined;
    vt.init_model(&mblob);
    try testing.expect(vt.set_model_param(&mblob, "r", 42));
    try testing.expect(!vt.set_model_param(&mblob, "bogus", 1));
    const m: *R.Model = @ptrCast(@alignCast(&mblob));
    try testing.expectEqual(@as(f32, 42), m.r);

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e300, -1e300 }) |invalid|
        try testing.expect(!vt.set_model_param(&mblob, "r", invalid));
    try testing.expectEqual(@as(f32, 42), m.r);
    for ([_]f64{ -129, 128, 0.5, -0.5, std.math.nan(f64), std.math.inf(f64) }) |invalid|
        try testing.expect(!vt.set_model_param(&mblob, "mode", invalid));
    try testing.expectEqual(@as(i8, 0), m.mode);
    try testing.expect(!m.mode__given);
    try testing.expect(vt.set_model_param(&mblob, "mode", -128));
    try testing.expectEqual(@as(i8, -128), m.mode);
    try testing.expect(m.mode__given);
    try testing.expect(vt.set_model_param(&mblob, "mode", 127));
    try testing.expectEqual(@as(i8, 127), m.mode);
    try testing.expect(!vt.set_model_param(&mblob, "count", -1));
    try testing.expect(!vt.set_model_param(&mblob, "count", 0x1p64));
    try testing.expect(vt.set_model_param(&mblob, "count", 0x1p64 - 2048));
    try testing.expectEqual(@as(u64, 18446744073709549568), m.count);
    try testing.expect(!vt.set_model_param(&mblob, "wide", 0x1p63));
    try testing.expect(!vt.set_model_param(&mblob, "wide", -0x1p63 - 2048));
    try testing.expect(vt.set_model_param(&mblob, "wide", -0x1p63));
    try testing.expectEqual(std.math.minInt(i64), m.wide);
    try testing.expect(!vt.set_model_param(&mblob, "mode__given", std.math.nan(f64)));

    var iblob: [@sizeOf(R.Instance)]u8 align(16) = undefined;
    vt.init_instance(&iblob);
    try testing.expect(!vt.set_instance_param(&iblob, "temp", 1e300));
    const inst: *R.Instance = @ptrCast(@alignCast(&iblob));
    try testing.expectEqual(@as(f32, 300.15), inst.temp);

    const proto = try vt.proto_create(testing.allocator).unwrap();
    const nodes = [2]u32{ 1, 2 };
    try vt.proto_add(proto.ctx, testing.allocator, &mblob, &iblob, &nodes).unwrap();
    const store: *ProtoStore(R) = @ptrCast(@alignCast(proto.ctx));
    try testing.expectEqual(@as(usize, 1), store.models.items.len);
    try testing.expectEqual(@as(f32, 42), store.models.items[0].r);
    proto.destroy(proto.ctx, testing.allocator);
}

test "prepared device instances share tapes and isolate parameters and accepted history" {
    const D = struct {
        pub const noise_gens = [_]NoiseGen{
            .{ .row = 0, .col = 1, .kind = .shot },
            .{ .row = 1, .col = 0, .kind = .thermal },
        };
        pub fn noisePsd(x: [2]f64, _: *const Model, _: *const Instance) [2]PsdTerm {
            return .{ .{ .white = @abs(x[0] - x[1]) }, .{ .white = 7 } };
        }
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { r: f64 = 1000 };
        pub const Instance = struct {
            accepted: u8 = 0,
            history: [4]f64 = @splat(0),
        };
        pub const State = struct { bias: f64 = 0 };
        pub fn initState(_: *const Model, _: *const Instance) State {
            return .{};
        }
        pub fn eval(comptime S: type, x: [2]S, m: *const Model, _: *const Instance, _: f64) [2]S {
            const current = x[0].sub(x[1]).scale(1 / m.r);
            return .{ current, current.neg() };
        }
    };
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    // The normal freeze provides a union pattern. A dense 3-row pattern is
    // sufficient here; the fourth row/last slot are the ground-write sinks.
    const batch = try ProtoStore(D).finalize(&proto, a, .{
        .col_ptr = &.{ 0, 3, 6, 9 },
        .row_idx = &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 },
        .n = 3,
        .trash_slot = 9,
    }).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    var noise: std.ArrayList(NoiseSource) = .empty;
    defer noise.deinit(a);
    for ([_]f64{ 0, 3, 0 }) |bias| {
        noise.clearRetainingCapacity();
        try batch.hooks.collect_noise.?(batch.ctx, &.{ 0, bias, 0 }, a, &noise).unwrap();
        try std.testing.expectEqual(@as(usize, 2), noise.items.len);
        try std.testing.expectEqual(bias, noise.items[0].white);
        try std.testing.expectEqual(@as(f64, 7), noise.items[1].white);
        try std.testing.expectEqual(@as(u32, 1), noise.items[0].node_p);
        try std.testing.expectEqual(@as(u32, 2), noise.items[1].node_p);
    }
    const first = try batch.hooks.instantiate(batch.ctx, a).unwrap();
    defer first.hooks.deinit(first.ctx, a);
    const second = try batch.hooks.instantiate(batch.ctx, a).unwrap();
    defer second.hooks.deinit(second.ctx, a);
    const template: *DeviceBatch(D) = @ptrCast(@alignCast(batch.ctx));
    const one: *DeviceBatch(D) = @ptrCast(@alignCast(first.ctx));
    const two: *DeviceBatch(D) = @ptrCast(@alignCast(second.ctx));
    one.models[0].r = 25;
    one.instances[0].accepted = 1;
    one.instances[0].history[0] = 2;
    one.states[0].bias = 3;
    try std.testing.expectEqual(@as(f64, 1000), two.models[0].r);
    try std.testing.expectEqual(@as(u8, 0), two.instances[0].accepted);
    try std.testing.expectEqual(@as(f64, 0), two.instances[0].history[0]);
    try std.testing.expectEqual(@as(f64, 0), two.states[0].bias);
    try std.testing.expectEqual(@as(u8, 0), template.instances[0].accepted);
    try std.testing.expectEqual(template.slots.ptr, one.slots.ptr);
    try std.testing.expectEqual(template.gath.ptr, two.gath.ptr);
    const accepted = try first.hooks.snapshot(first.ctx, a).unwrap();
    defer accepted.hooks.deinit(accepted.ctx, a);
    const captured: *DeviceBatch(D) = @ptrCast(@alignCast(accepted.ctx));
    try std.testing.expectEqual(@as(f64, 25), captured.models[0].r);
    try std.testing.expectEqual(@as(u8, 1), captured.instances[0].accepted);
    try std.testing.expectEqual(@as(f64, 2), captured.instances[0].history[0]);
    try std.testing.expectEqual(@as(f64, 3), captured.states[0].bias);
    one.instances[0].history[0] = 99;
    try std.testing.expectEqual(@as(f64, 2), captured.instances[0].history[0]);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator, prepared: Batch) !void {
            const instance = try prepared.hooks.instantiate(prepared.ctx, allocator).unwrap();
            defer instance.hooks.deinit(instance.ctx, allocator);
        }
    }.run, .{batch});
}

test "iteration hooks gather each instance and preserve accepted-time state" {
    const D = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct {
            iteration: u8 = 9,
            previous: f64 = 0,
            accepted_time: f64 = 17,
        };
        pub fn eval(comptime S: type, x: [2]S, _: *const Model, _: *const Instance, _: f64) [2]S {
            const current = x[0].sub(x[1]);
            return .{ current, current.neg() };
        }
        pub fn beginSolve(inst: *Instance) void {
            inst.iteration = 1;
        }
        pub fn advanceIteration(_: *const Model, inst: *Instance, x: [2]f64) void {
            inst.previous = x[0] - x[1];
            inst.iteration += 1;
        }
        pub fn checkConvergence(_: *const Model, inst: *const Instance, x: [2]f64) bool {
            return inst.iteration > 1 and inst.previous == x[0] - x[1];
        }
    };
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    try proto.append(.{}, .{}, .{ 2, 1 });
    const batch = try ProtoStore(D).finalize(&proto, a, .{
        .col_ptr = &.{ 0, 3, 6, 9 },
        .row_idx = &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 },
        .n = 3,
        .trash_slot = 9,
    }).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const typed: *DeviceBatch(D) = @ptrCast(@alignCast(batch.ctx));
    try std.testing.expect(batch.hooks.gpu_payload == null);
    const x = [_]f64{ 0, 5, 2 };
    batch.hooks.begin_solve.?(batch.ctx);
    try std.testing.expect(!batch.hooks.check_convergence.?(batch.ctx, &x));
    batch.hooks.advance_iteration.?(batch.ctx, &x);
    try std.testing.expect(batch.hooks.check_convergence.?(batch.ctx, &x));
    try std.testing.expectEqual(@as(f64, 3), typed.instances[0].previous);
    try std.testing.expectEqual(@as(f64, -3), typed.instances[1].previous);
    for (typed.instances) |inst| {
        try std.testing.expectEqual(@as(u8, 2), inst.iteration);
        try std.testing.expectEqual(@as(f64, 17), inst.accepted_time);
    }
    batch.hooks.begin_solve.?(batch.ctx);
    try std.testing.expect(!batch.hooks.check_convergence.?(batch.ctx, &x));
    try std.testing.expectEqual(@as(f64, 3), typed.instances[0].previous);
}

test "mutable evaluation captures per-instance data without GPU residency" {
    const D = struct {
        pub const mutable_eval = true;
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct {
            ready: bool = false,
            first_value: f64 = 0,
        };
        pub fn eval(comptime S: type, x: [2]S, _: *const Model, inst: *Instance, _: f64) [2]S {
            const v = x[0].sub(x[1]);
            if (!inst.ready) {
                inst.first_value = v.val();
                inst.ready = true;
            }
            const current = v.sub(S.con(inst.first_value));
            return .{ current, current.neg() };
        }
    };
    comptime impl.checkHost(D);
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    try proto.append(.{}, .{}, .{ 2, 1 });
    const batch = try ProtoStore(D).finalize(&proto, a, .{
        .col_ptr = &.{ 0, 3, 6, 9 },
        .row_idx = &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 },
        .n = 3,
        .trash_slot = 9,
    }).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const typed: *DeviceBatch(D) = @ptrCast(@alignCast(batch.ctx));
    try std.testing.expect(batch.hooks.gpu_payload == null);
    for (typed.instances) |inst| try std.testing.expect(!inst.ready);
    var g: [10]f64 = @splat(0);
    var c: [10]f64 = @splat(0);
    var rhs: [4]f64 = @splat(0);
    var q: [4]f64 = @splat(0);
    const planes: impl.Planes = .{ .g_vals = &g, .c_vals = &c, .rhs = &rhs, .q_vec = &q };
    batch.eval(batch.ctx, &planes, 0, 2, &.{ 0, 5, 2 }, 0);
    try std.testing.expectEqual(@as(f64, 3), typed.instances[0].first_value);
    try std.testing.expectEqual(@as(f64, -3), typed.instances[1].first_value);
    batch.eval(batch.ctx, &planes, 0, 2, &.{ 0, 9, 1 }, 1);
    try std.testing.expectEqual(@as(f64, 3), typed.instances[0].first_value);
    try std.testing.expectEqual(@as(f64, -3), typed.instances[1].first_value);
}
