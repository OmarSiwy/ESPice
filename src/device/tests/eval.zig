//! Tests for the evaluator: AD scalars, the bit-trick helpers, the runtime
//! vtable and binder, and batch instantiation and hooks.
const impl = @import("device_eval");
const contract = @import("contract");
const SimState = contract.SimState;
const Batch = impl.Batch;
const DeviceBatch = impl.DeviceBatch;
const Dual = impl.Dual;
const NoiseGen = impl.NoiseGen;
const NoiseSource = impl.NoiseSource;
const ProtoStore = impl.ProtoStore;
const PsdTerm = impl.PsdTerm;
const Real = impl.test_access.Real;
const deviceVtable = impl.deviceVtable;
const gpuJacFloat = impl.gpuJacFloat;
const jacFloat = impl.jacFloat;
const std = @import("std");

test "anyNonzero matches the float compare it replaces, ±0 and NaN included" {
    const specials = [_]f64{ 0.0, -0.0, std.math.nan(f64), -std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), std.math.floatTrueMin(f64), -std.math.floatTrueMin(f64), 1.0 };
    inline for (.{ 1, 2, 4, 8 }) |w| {
        const V = @Vector(w, f64);
        // Every lane drawn from the specials, lanes mostly ±0 so both answers occur.
        var prng = std.Random.DefaultPrng.init(0xc0de + w);
        for (0..4096) |_| {
            var a: [w]f64 = undefined;
            for (&a) |*x| x.* = if (prng.random().uintLessThan(u8, 4) != 0) specials[prng.random().uintLessThan(usize, 2)] else specials[prng.random().uintLessThan(usize, specials.len)];
            const v: V = a;
            try std.testing.expectEqual(@reduce(.Or, v != @as(V, @splat(0))), impl.test_access.anyNonzero(w, v));
        }
    }
}

test "Dual: expm1 and log1p retain finite range and IEEE endpoints" {
    const S = Dual(1, f64);
    for ([_]f64{ -740, -1, -1e-17, -0.0, 0, 1e-17, 0.5, 704, 709 }) |x| {
        const y = S.probe(0, x).expm1();
        try std.testing.expect(std.math.isFinite(y.v));
        try std.testing.expectApproxEqRel(std.math.expm1(x), y.v, 3e-15);
        try std.testing.expectEqual(@exp(x), y.ddxAt(0));
    }
    for ([_]f64{ -1, -0.9999999999999999, -1e-17, -0.0, 0, 1e-17, 0.5, 1e308, std.math.inf(f64) }) |x| {
        const y = S.probe(0, x).log1p();
        try std.testing.expectApproxEqRel(std.math.log1p(x), y.v, 3e-15);
        try std.testing.expectEqual(1.0 / (1.0 + x), y.ddxAt(0));
    }
    try std.testing.expectEqual(std.math.inf(f64), S.probe(0, 710).expm1().v);
    try std.testing.expectEqual(std.math.inf(f64), S.probe(0, std.math.inf(f64)).expm1().v);
    try std.testing.expectEqual(@as(f64, -1), S.probe(0, -std.math.inf(f64)).expm1().v);
    try std.testing.expect(std.math.isNan(S.probe(0, -2).log1p().v));
    try std.testing.expect(std.math.isNan(S.probe(0, std.math.nan(f64)).expm1().v));
    try std.testing.expect(std.math.isNan(S.probe(0, std.math.nan(f64)).log1p().v));
    try std.testing.expect(std.math.signbit(S.probe(0, -0.0).expm1().v));
    try std.testing.expect(std.math.signbit(S.probe(0, -0.0).log1p().v));
}

test "Dual: an f32 Jacobian leaves the residual bit-identical" {
    // `F` is the derivative width only; the residual is the same f64
    // arithmetic at either width, so values must be equal, not close.
    const core = struct {
        // A diode core: is·(exp(v/vt) − 1) + gmin·v.
        fn f(comptime S: type, bias: f64) S.Of(0b11) {
            const v = S.probe(0, bias).sub(S.probe(1, 0));
            return S.con(1e-14).mul(v.div(S.con(0.025851999786450736)).exp().addC(-1.0))
                .add(v.scale(1e-12));
        }
    }.f;
    for (0..17) |i| {
        const bias = @as(f64, @floatFromInt(i)) * 0.05;
        const a = core(Dual(2, f64), bias);
        const b = core(Dual(2, f32), bias);
        try std.testing.expectEqual(a.val(), b.val());
        // The Jacobian degrades to f32 precision and no further.
        inline for (0..2) |c| try std.testing.expectApproxEqRel(a.ddxAt(c), b.ddxAt(c), 1e-6);
    }
}

test "Dual is the contract's arithmetic, dense and sparse, at both lane widths" {
    try contract.expectFamily(Dual(2, f64));
    try contract.expectFamily(Dual(2, f32));
    try contract.expectFamily(impl.test_access.Sparse);
    try contract.expectFamily(impl.test_access.SparseF32);
    contract.checkFamily(Real);
}

test "jac width: one device, two instantiations" {
    // `jac_f32` is a permission the GPU kernel takes and the host declines;
    // `jac_f32_host` makes the host take it too.
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

test "Real: every primitive is Dual's value half, bit for bit" {
    // `evalQRange` must reproduce the Dual pass exactly: its charges feed the
    // next step's residual and LTE, so one ulp shifts the timestep sequence.
    const core = struct {
        fn f(comptime S: type, a: f64, b: f64) S.Of(0b11) {
            const x = S.probe(0, a);
            const y = S.probe(1, b);
            // One chain per primitive, so a desync anywhere lands in the result.
            var r = x.add(y).sub(y).neg().mul(x).div(y.addC(3.0)).scale(-0.5);
            // §4.3.1's abs and slew clamps, as generated devices spell them.
            r = S.sel(S.con(0.0).lt(r), r, r.neg());
            r = S.sel(S.con(4.0).lt(r), S.con(4.0).to(0b11), r);
            r = S.sel(r.lt(S.con(-4.0)), S.con(-4.0).to(0b11), r);
            r = r.add(x.exp().log().expm1().log1p());
            r = r.add(y.addC(9.0).sqrt().pow(1.5));
            r = r.add(x.sin().cos().tanh().sinh().cosh().atan());
            r = r.add(S.sel(x.lt(y), S.sel(y.lt(x), x, y), S.sel(x.lt(y), x, y)));
            return r.add(S.sel(x.le(y).add(x.eq(y)), x, y));
        }
    }.f;
    for (0..13) |i| {
        for (0..13) |j| {
            // Crosses zero exactly, where `abs`, min/max ties and `sel` would
            // differ.
            const a = @as(f64, @floatFromInt(i)) * 0.25 - 1.5;
            const b = @as(f64, @floatFromInt(j)) * 0.25 - 1.5;
            try std.testing.expectEqual(
                core(Dual(2, f64), a, b).val(),
                core(Real, a, b).val(),
            );
        }
    }
}

test "dyn vtable: blob init, param set by name, proto add" {
    const R = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        // Mixed scalar widths exercise the binder's conversion bounds.
        pub const Model = struct {
            r: f32 = 1000,
            mode: i8 = 0,
            mode__given: bool = false,
            count: u64 = 0,
            wide: i64 = 0,
        };
        pub const Instance = struct { temp: f32 = 300.15 };
        pub fn eval(comptime Sc: type, xv: *const [2]Sc.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), Sc) {
            const x = contract.probes(@This(), Sc, xv);
            const i = x[0].sub(x[1]).scale(1.0 / @as(f64, m.r));
            return contract.rows(@This(), Sc, .{ i, i.neg() });
        }
    };
    const testing = std.testing;
    const vt = deviceVtable(R, "tres");
    try testing.expectEqual(@as(u32, 2), vt.n_u);
    try testing.expectEqual(@sizeOf(R.Model), vt.model_size);

    var mblob: [@sizeOf(R.Model)]u8 align(16) = undefined;
    vt.init_model(&mblob);
    const Status = @TypeOf(vt.bind_model(&mblob, &.{}));
    const one = struct {
        fn f(bind: anytype, blob: [*]u8, key: []const u8, value: f64) Status {
            return bind(blob, &.{.{ .key = key, .value = value }});
        }
    }.f;
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "r", 42));
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "bogus", 1)); // unknown keys are ignored
    const m: *R.Model = @ptrCast(@alignCast(&mblob));
    try testing.expectEqual(@as(f32, 42), m.r);

    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |invalid|
        try testing.expectEqual(.non_finite_parameter, one(vt.bind_model, &mblob, "r", invalid));
    for ([_]f64{ 1e300, -1e300 }) |invalid|
        try testing.expectEqual(.parameter_out_of_range, one(vt.bind_model, &mblob, "r", invalid));
    try testing.expectEqual(@as(f32, 42), m.r);
    for ([_]f64{ -129, 128, 127.5, -128.6 }) |invalid|
        try testing.expectEqual(.parameter_out_of_range, one(vt.bind_model, &mblob, "mode", invalid));
    try testing.expectEqual(.non_finite_parameter, one(vt.bind_model, &mblob, "mode", std.math.nan(f64)));
    try testing.expectEqual(@as(i8, 0), m.mode);
    try testing.expect(!m.mode__given);
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "mode", -128));
    try testing.expectEqual(@as(i8, -128), m.mode);
    try testing.expect(m.mode__given);
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "mode", 127));
    try testing.expectEqual(@as(i8, 127), m.mode);
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "mode", -0.5));
    try testing.expectEqual(@as(i8, 0), m.mode);
    try testing.expectEqual(.parameter_out_of_range, one(vt.bind_model, &mblob, "count", -1));
    try testing.expectEqual(.parameter_out_of_range, one(vt.bind_model, &mblob, "count", 0x1p64));
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "count", 0x1p64 - 2048));
    try testing.expectEqual(@as(u64, 18446744073709549568), m.count);
    try testing.expectEqual(.parameter_out_of_range, one(vt.bind_model, &mblob, "wide", 0x1p63));
    try testing.expectEqual(.parameter_out_of_range, one(vt.bind_model, &mblob, "wide", -0x1p63 - 2048));
    try testing.expectEqual(.ok, one(vt.bind_model, &mblob, "wide", -0x1p63));
    try testing.expectEqual(std.math.minInt(i64), m.wide);

    var iblob: [@sizeOf(R.Instance)]u8 align(16) = undefined;
    vt.init_instance(&iblob);
    try testing.expectEqual(.parameter_out_of_range, one(vt.bind_instance, &iblob, "temp", 1e300));
    const inst: *R.Instance = @ptrCast(@alignCast(&iblob));
    try testing.expectEqual(@as(f32, 300.15), inst.temp);

    const proto = try vt.proto_create(testing.allocator).unwrap();
    const nodes = [2]u32{ 1, 2 };
    try vt.proto_add(proto.ctx, testing.allocator, &mblob, &iblob, &nodes).unwrap();
    const store: *ProtoStore(R) = @ptrCast(@alignCast(proto.ctx));
    try testing.expectEqual(@as(usize, 1), store.rows.len);
    try testing.expectEqual(@as(f32, 42), store.rows.items(.model)[0].r);
    proto.destroy(proto.ctx, testing.allocator);
}

test "prepared device instances share tapes and isolate parameters and accepted history" {
    const D = struct {
        pub const noise_gens = [_]NoiseGen{
            .{ .row = 0, .col = 1, .kind = .shot },
            .{ .row = 1, .col = 0, .kind = .thermal },
        };
        pub fn noisePsd(comptime _: type, x: [2]f64, _: *const Model, _: *const Instance, _: SimState) [2]PsdTerm {
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
        pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]).scale(1 / m.r);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
    };
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    // A dense 3x3 pattern; row 3 and slot 9 take the ground writes.
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
    // `copy_state` rewinds in place, so storage a ParamRef points into stays.
    one.states[0].bias = 42;
    const storage = one.instances.ptr;
    first.hooks.copy_state(first.ctx, accepted.ctx);
    try std.testing.expectEqual(@as(f64, 2), one.instances[0].history[0]);
    try std.testing.expectEqual(@as(f64, 3), one.states[0].bias);
    try std.testing.expectEqual(storage, one.instances.ptr);
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator, prepared: Batch) !void {
            const instance = try prepared.hooks.instantiate(prepared.ctx, allocator).unwrap();
            defer instance.hooks.deinit(instance.ctx, allocator);
        }
    }.run, .{batch});
}

test "a live timer schedule reaches next_breakpoint" {
    const D = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct { next: f64 = std.math.inf(f64) };
        pub const State = struct {};
        pub fn initState(_: *const Model, _: *const Instance) State {
            return .{};
        }
        pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
        pub fn updateState(comptime _: type, _: *const Model, inst: *Instance, _: [2]f64, _: *State, sim: SimState) contract.UpdateResult {
            // A timer re-armed during the solve: fires 1 ns after each update.
            inst.next = sim.t + 1e-9;
            return .ok;
        }
        pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {
            return if (inst.next > t) inst.next else null;
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
    const next = batch.hooks.next_breakpoint.?;
    try std.testing.expectEqual(@as(?f64, null), next(batch.ctx, 0));
    const self: *DeviceBatch(D) = @ptrCast(@alignCast(batch.ctx));
    self.sim.t = 2e-9;
    _ = batch.hooks.update_state.?(batch.ctx, &.{ 0, 0, 0 });
    const fire = self.sim.t + 1e-9;
    try std.testing.expectEqual(@as(?f64, fire), next(batch.ctx, 2e-9));
    try std.testing.expectEqual(@as(?f64, null), next(batch.ctx, fire));
}

test "a field that only names absdelay keeps updateState on every solve" {
    const D = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        // Named like a delay ring, but outside VerA's operator namespace
        // (`__analog_op__absdelay__`): routed to `commit_state`, the
        // operating point would never run updateState.
        pub const Instance = struct { sig__absdelay__x: f64 = 0 };
        pub const State = struct {};
        pub fn initState(_: *const Model, _: *const Instance) State {
            return .{};
        }
        pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
        pub fn updateState(comptime _: type, _: *const Model, _: *Instance, _: [2]f64, _: *State, _: SimState) contract.UpdateResult {
            return .ok;
        }
    };
    try std.testing.expect(DeviceBatch(D).hooks.update_state != null);
    try std.testing.expect(DeviceBatch(D).hooks.commit_state == null);
}

test "iteration hooks gather each instance and preserve accepted-time state" {
    const D = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct {
            previous: f64 = 0,
            accepted_time: f64 = 17,
        };
        pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
        pub fn advanceIteration(comptime _: type, _: *const Model, inst: *Instance, x: [2]f64, _: SimState) void {
            inst.previous = x[0] - x[1];
        }
        pub fn checkConvergence(comptime _: type, _: *const Model, inst: *const Instance, x: [2]f64, sim: SimState) bool {
            return sim.iteration > 1 and inst.previous == x[0] - x[1];
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
    // The host counts iterations into the SimState it publishes.
    batch.hooks.set_sim_state(batch.ctx, .{ .iteration = 1 });
    try std.testing.expect(!batch.hooks.check_convergence.?(batch.ctx, &x));
    batch.hooks.advance_iteration.?(batch.ctx, &x);
    batch.hooks.set_sim_state(batch.ctx, .{ .iteration = 2 });
    try std.testing.expect(batch.hooks.check_convergence.?(batch.ctx, &x));
    try std.testing.expectEqual(@as(f64, 3), typed.instances[0].previous);
    try std.testing.expectEqual(@as(f64, -3), typed.instances[1].previous);
    for (typed.instances) |inst| try std.testing.expectEqual(@as(f64, 17), inst.accepted_time);
    batch.hooks.set_sim_state(batch.ctx, .{ .iteration = 1 });
    try std.testing.expect(!batch.hooks.check_convergence.?(batch.ctx, &x));
    try std.testing.expectEqual(@as(f64, 3), typed.instances[0].previous);
}

test "mutable evaluation captures per-instance data without GPU residency" {
    const D = struct {
        pub const mutable_eval = true;
        pub const contract_abi: u32 = 5;
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct {
            ready: bool = false,
            first_value: f64 = 0,
        };
        pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, inst: *Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const v = x[0].sub(x[1]);
            if (!inst.ready) {
                inst.first_value = v.val();
                inst.ready = true;
            }
            const current = v.sub(S.con(inst.first_value));
            return contract.rows(@This(), S, .{ current, current.neg() });
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
