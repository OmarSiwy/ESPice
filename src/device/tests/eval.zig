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
    try testing.expectEqual(@as(usize, 1), store.nodes.items.len);
    try testing.expectEqual(@as(f32, 42), store.models.items[0].r);
    proto.destroy(proto.ctx, testing.allocator);
}

test "equal cards share one Model row until a parameter is collected" {
    const D = struct {
        // Marks a VerA device, the only kind whose Models are shared.
        pub const lane_masks = [_]contract.LaneUse{.{ .mask = 0b11, .uses = 1 }};
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { r: f64 = 1000, given: bool = false };
        pub const Instance = struct { temperature: f64 = 300.15, mfactor: f64 = 1 };
        pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]).scale(1 / m.r);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
    };
    comptime std.debug.assert(DeviceBatch(D).shares_models);
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    for ([_]f64{ 1000, 50, 1000 }, [_][2]u32{ .{ 1, 2 }, .{ 2, 0 }, .{ 1, 0 } }) |r, nodes|
        try proto.append(.{ .r = r }, .{}, nodes);
    const batch = try ProtoStore(D).finalize(&proto, a, .{
        .col_ptr = &.{ 0, 3, 6, 9 },
        .row_idx = &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 },
        .n = 3,
        .trash_slot = 9,
    }).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const copy = try batch.hooks.instantiate(batch.ctx, a).unwrap();
    defer copy.hooks.deinit(copy.ctx, a);
    const shared: *DeviceBatch(D) = @ptrCast(@alignCast(copy.ctx));
    try std.testing.expectEqual(@as(usize, 2), shared.models.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, shared.model_of);

    // The shared rows stamp what one row per instance stamps.
    var g: [10]f64 = undefined;
    var rhs: [4]f64 = undefined;
    const x = [_]f64{ 0, 2, 0.5 };
    const stamp = struct {
        fn run(b: Batch, gv: *[10]f64, rv: *[4]f64, xs: []const f64) void {
            @memset(gv, 0);
            @memset(rv, 0);
            var c: [10]f64 = @splat(0);
            var q: [4]f64 = @splat(0);
            b.eval(b.ctx, &.{ .g_vals = gv, .c_vals = &c, .rhs = rv, .q_vec = &q }, 0, b.count, xs, 0);
        }
    }.run;
    stamp(copy, &g, &rhs, &x);
    const g_shared = g;
    const rhs_shared = rhs;

    // Collecting parameters gives each instance its own row, so a write
    // through instance 0 leaves instance 2, which shared its card, alone.
    var params: std.ArrayList(impl.test_access.ParamRef) = .empty;
    defer params.deinit(a);
    try copy.hooks.collect_params(copy.ctx, a, &params).unwrap();
    try std.testing.expectEqual(@as(usize, 3), shared.models.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, shared.model_of);
    stamp(copy, &g, &rhs, &x);
    try std.testing.expectEqualSlices(f64, &g_shared, &g);
    try std.testing.expectEqualSlices(f64, &rhs_shared, &rhs);
    for (params.items) |ref| if (!ref.is_instance and ref.index == 0) ref.set(10);
    try std.testing.expectEqual(@as(f64, 10), shared.models[0].r);
    try std.testing.expectEqual(@as(f64, 1000), shared.models[2].r);
}

test "collect_noise emits a correlated source's rows contiguously, with coeff, group and table" {
    const D = struct {
        const Gen = struct { row: u8, col: u8, kind: enum { thermal, shot, flicker, table }, source: ?u16 = null, table: ?u16 = null, name: []const u8 = "" };
        pub const noise_tables = [_]contract.NoiseTable{.{ .interp = .linear, .points = &.{ .{ 1, 2 }, .{ 3, 4 } } }};
        // Generators 0 and 2 are one source; 1 is independent; 3 is a table.
        pub const noise_gens = [_]Gen{
            .{ .row = 0, .col = 1, .kind = .thermal, .source = 5, .name = "a" },
            .{ .row = 1, .col = 0, .kind = .shot, .name = "b" },
            .{ .row = 1, .col = 1, .kind = .thermal, .source = 5, .name = "c" },
            .{ .row = 0, .col = 0, .kind = .table, .table = 0, .name = "t" },
        };
        pub fn noisePsd(comptime _: type, _: [2]f64, _: *const Model, _: *const Instance, _: SimState) [4]PsdTerm {
            return .{ .{ .white = 1, .coeff = 2 }, .{ .white = 3 }, .{ .white = 1, .coeff = -2 }, .{ .white = 0, .coeff = 0.5 } };
        }
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { r: f64 = 1000 };
        pub const Instance = struct {};
        pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]).scale(1 / m.r);
            return contract.rows(@This(), S, .{ current, current.neg() });
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
    try std.testing.expectEqualDeep(&[_][]const u8{ "a", "c", "b", "t" }, batch.hooks.noise_names);
    var noise: std.ArrayList(NoiseSource) = .empty;
    defer noise.deinit(a);
    try noise.append(a, .{ .node_p = 0, .node_n = 0 }); // a row from an earlier batch
    try batch.hooks.collect_noise.?(batch.ctx, &.{ 0, 0, 0 }, a, &noise).unwrap();
    const s = noise.items[1..];
    try std.testing.expectEqual(@as(usize, 8), s.len);
    for (0..2) |id| {
        const r = s[4 * id ..][0..4];
        const base: u32 = @intCast(1 + 4 * id);
        try std.testing.expectEqualSlices(f64, &.{ 2, -2, 1, 0.5 }, &.{ r[0].coeff, r[1].coeff, r[2].coeff, r[3].coeff });
        try std.testing.expectEqualSlices(u32, &.{ base, base, base + 2, base + 3 }, &.{ r[0].group, r[1].group, r[2].group, r[3].group });
        // (u, u) is u to ground; the table row carries the device's knots.
        try std.testing.expectEqual(@as(u32, 0), r[1].node_n);
        try std.testing.expectEqual(@as(f64, 3), r[3].tableAt(2));
        try std.testing.expectEqual(@as(f64, 0), r[0].tableAt(2));
        try std.testing.expectEqual(base + 2, NoiseSource.groupEnd(noise.items, base));
    }
    try std.testing.expectEqual(@as(u32, 1), s[0].node_p);
    try std.testing.expectEqual(@as(u32, 2), s[4].node_p);
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

test "a status-latch-only device stays GPU-eligible and reports its latched status" {
    const D = struct {
        pub const mutable_eval = true;
        pub const contract_abi: u32 = 6;
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct { limit: f64 = 4 };
        pub const Instance = struct {
            vera_status__: u32 = 0,
            vera_status_args__: [4]f64 = @splat(0.0),
        };
        pub const status_sites = [_]contract.StatusSite{.{ .severity = .@"error", .fmt = "v = %g", .file = "m.va", .line = 7 }};
        pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, inst: *Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const v = x[0].sub(x[1]);
            if (inst.vera_status__ == 0 and v.val() > m.limit) {
                inst.vera_status__ = contract.statusCode(.@"error", 0);
                inst.vera_status_args__[0] = v.val();
            }
            return contract.rows(@This(), S, .{ v, v.neg() });
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
    // The latch is its only eval write, so the device may be resident.
    try std.testing.expect(batch.hooks.gpu_payload != null);
    var msg: [64]u8 = undefined;
    try std.testing.expectEqual(null, batch.hooks.status.?(batch.ctx, &msg));
    var g: [10]f64 = @splat(0);
    var c: [10]f64 = @splat(0);
    var rhs: [4]f64 = @splat(0);
    var q: [4]f64 = @splat(0);
    const planes: impl.Planes = .{ .g_vals = &g, .c_vals = &c, .rhs = &rhs, .q_vec = &q };
    // v(1) - v(2) = -5 for instance 0 and +5 for instance 1.
    batch.eval(batch.ctx, &planes, 0, 2, &.{ 0, 0, 5 }, 0);
    const hit = batch.hooks.status.?(batch.ctx, &msg).?;
    try std.testing.expectEqual(@as(u32, 1), hit.index);
    try std.testing.expectEqualStrings("m.va:7: error: v = 5", msg[0..hit.len]);
}

test "mutable evaluation captures per-instance data without GPU residency" {
    const D = struct {
        pub const mutable_eval = true;
        pub const contract_abi: u32 = 6;
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

test "permuteInPlace: moves every row to dst[k], cycles and fixed points alike" {
    var prng = std.Random.DefaultPrng.init(0x9e37);
    const r = prng.random();
    for (1..40) |len| {
        var dst: [40]u32 = undefined;
        for (dst[0..len], 0..) |*d, i| d.* = @intCast(i);
        r.shuffle(u32, dst[0..len]);
        var items: [40]u64 = undefined;
        for (items[0..len], 0..) |*v, i| v.* = i * 7 + 1;
        var want: [40]u64 = undefined;
        for (0..len) |k| want[dst[k]] = items[k];
        var seen: [40]bool = undefined;
        impl.permuteInPlace(u64, items[0..len], dst[0..len], seen[0..len]);
        try std.testing.expectEqualSlices(u64, want[0..len], items[0..len]);
    }
}

test "analog initial reruns after a revert rolls its held results back" {
    // Stands in for a VerA device: `updateState` holds what the §5.2.1 block
    // computes, `stateCtl` commits and reverts it like any held value.
    const D = struct {
        pub const U = enum(u8) { p, n };
        pub const num_ports: usize = 2;
        pub const Model = struct {};
        pub const Instance = struct { held: f64 = 0 };
        pub const State = struct { committed: f64 = 0 };
        pub fn initState(_: *const Model, _: *const Instance) State {
            return .{};
        }
        pub fn eval(comptime S: type, xv: *const [2]S.V, _: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const current = x[0].sub(x[1]);
            return contract.rows(@This(), S, .{ current, current.neg() });
        }
        pub fn updateState(comptime _: type, _: *const Model, inst: *Instance, _: [2]f64, _: *State, sim: SimState) contract.UpdateResult {
            if (sim.analog_initial) inst.held = 5;
            return .ok;
        }
        pub fn stateCtl(_: *const Model, inst: *Instance, st: *State, op: contract.StateCtlOp) bool {
            switch (op) {
                .commit => st.committed = inst.held,
                .revert => inst.held = st.committed,
                .query => {},
            }
            return false;
        }
    };
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    const template = try ProtoStore(D).finalize(&proto, a, .{
        .col_ptr = &.{ 0, 3, 6, 9 },
        .row_idx = &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 },
        .n = 3,
        .trash_slot = 9,
    }).unwrap();
    defer template.hooks.deinit(template.ctx, a);
    const batch = try template.hooks.instantiate(template.ctx, a).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const typed: *DeviceBatch(D) = @ptrCast(@alignCast(batch.ctx));
    const x = [_]f64{ 0, 1, 0 };
    const ctl = batch.hooks.state_ctl.?;
    const update = batch.hooks.update_state.?;

    _ = update(batch.ctx, &x);
    try std.testing.expectEqual(@as(f64, 5), typed.instances[0].held);
    try std.testing.expect(!typed.sim.analog_initial);
    // Back to the birth commit: the held result is gone, so the block reruns.
    _ = ctl(batch.ctx, .revert);
    try std.testing.expectEqual(@as(f64, 0), typed.instances[0].held);
    try std.testing.expect(typed.sim.analog_initial);
    batch.hooks.set_sim_state(batch.ctx, .{});
    try std.testing.expect(typed.sim.analog_initial);
    _ = update(batch.ctx, &x);
    try std.testing.expectEqual(@as(f64, 5), typed.instances[0].held);
    // Committed, a revert keeps the result and the block stays skipped.
    _ = ctl(batch.ctx, .commit);
    _ = ctl(batch.ctx, .revert);
    try std.testing.expectEqual(@as(f64, 5), typed.instances[0].held);
    try std.testing.expect(!typed.sim.analog_initial);
    batch.hooks.set_sim_state(batch.ctx, .{});
    try std.testing.expect(!typed.sim.analog_initial);
    // A fresh instance starts over; copy_state carries the flag with the values.
    const fresh = try template.hooks.instantiate(template.ctx, a).unwrap();
    defer fresh.hooks.deinit(fresh.ctx, a);
    const fresh_typed: *DeviceBatch(D) = @ptrCast(@alignCast(fresh.ctx));
    try std.testing.expect(fresh_typed.sim.analog_initial);
    fresh.hooks.copy_state(fresh.ctx, batch.ctx);
    try std.testing.expect(!fresh_typed.sim.analog_initial);
}

test "spicePwlBreak rounds from the request time as ngspice does" {
    const spicePwlBreak = impl.test_access.spicePwlBreak;
    const M = struct {
        waveform: i64 = 4,
        pwl_len: i64 = 3,
        pwl_repeat: f64 = -1,
        pwl_td: f64 = 0,
        pwl_timesZ5b0Z5d: f64 = 0,
        pwl_timesZ5b1Z5d: f64 = 1.0e-9,
        pwl_timesZ5b2Z5d: f64 = 3.1e-9,
        pwl_timesZ5b3Z5d: f64 = 0,
    };
    const mb = 1e-20;
    var m: M = .{};
    try std.testing.expectEqual(@as(?f64, 1.0e-9), spicePwlBreak(&m, 0, mb));
    // `t_acc + (t_k - t_acc)`, not the table time itself.
    const t_acc = 0.7e-9;
    try std.testing.expectEqual(@as(?f64, t_acc + (3.1e-9 - t_acc)), spicePwlBreak(&m, t_acc, 1.0e-9 + mb));
    try std.testing.expectEqual(@as(?f64, std.math.inf(f64)), spicePwlBreak(&m, 3.1e-9, 3.1e-9 + mb));
    // TD delays every corner; the accepted time rounds it.
    m.pwl_td = 0.3e-9;
    try std.testing.expectEqual(@as(?f64, 0.3e-9), spicePwlBreak(&m, 0, mb));
    try std.testing.expectEqual(@as(?f64, 0.3e-9 + 1.0e-9), spicePwlBreak(&m, 0.3e-9, 0.3e-9 + mb));
    // `r=1n`: past the end the table replays [1n, 3.1n], period 2.1n.
    m = .{ .pwl_repeat = 1.0e-9 };
    const bp = spicePwlBreak(&m, 3.1e-9, 3.1e-9 + mb).?;
    try std.testing.expectApproxEqRel(@as(f64, 5.2e-9), bp, 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 7.3e-9), spicePwlBreak(&m, bp, bp + mb).?, 1e-12);
    // `r=0` repeats the whole table (period 3.1n); a negative `r` is no repeat.
    m = .{ .pwl_repeat = 0 };
    try std.testing.expectApproxEqRel(@as(f64, 4.1e-9), spicePwlBreak(&m, 3.1e-9, 3.1e-9 + mb).?, 1e-12);
    // An empty table or another waveform: the caller falls back.
    m = .{ .pwl_len = 0 };
    try std.testing.expectEqual(@as(?f64, null), spicePwlBreak(&m, 0, mb));
    m = .{ .waveform = 1 };
    try std.testing.expectEqual(@as(?f64, null), spicePwlBreak(&m, 0, mb));
}

test "spicePulseBreak rounds from the request time as ngspice does" {
    const spicePulseBreak = impl.test_access.spicePulseBreak;
    // tran/bench_tline_txl1_1_line's VS: PULSE(0 5 15.9n 0.2n 0.2n 15.8n 32n).
    // Typed f64 fields, as on vsource's Model: comptime_float fields would
    // fold the corner sums at f128 and round them once.
    const P = struct {
        waveform: i64 = 1,
        pulse_phase: f64 = 0,
        pulse_td: f64 = 15.9e-9,
        pulse_tr: f64 = 0.2e-9,
        pulse_tf: f64 = 0.2e-9,
        pulse_pw: f64 = 15.8e-9,
        pulse_per: f64 = 32e-9,
    };
    var m: P = .{};
    const mb = 1e-20;
    try std.testing.expectEqual(@as(?f64, 15.9e-9), spicePulseBreak(m, 0, mb));
    try std.testing.expectEqual(@as(?f64, 1.61e-8), spicePulseBreak(m, 15.9e-9, 15.9e-9 + mb));
    // The fall's end: ngspice lands one ulp below td+tr+pw+tf = 3.21e-8,
    // at 32099.999... ps, which txlload.c truncates to 32099.
    try std.testing.expectEqual(@as(?f64, 3.2099999999999996e-08), spicePulseBreak(m, 3.19e-8, 3.19e-8 + mb));
    try std.testing.expectEqual(@as(?f64, 4.79e-8), spicePulseBreak(m, 3.2099999999999996e-08, 3.2099999999999996e-08 + mb));
    // An anchor ngspice would not ask at yields nothing (caller falls back).
    try std.testing.expectEqual(@as(?f64, null), spicePulseBreak(m, 0, 60e-9));
    // A nonzero PHASE and any other waveform are left to the timers.
    m.pulse_phase = 90;
    try std.testing.expectEqual(@as(?f64, null), spicePulseBreak(m, 0, mb));
    m = .{ .waveform = 4 };
    try std.testing.expectEqual(@as(?f64, null), spicePulseBreak(m, 0, mb));
}

test "Dual: every partial matches a central difference of the value" {
    // Independent of the contract's reference family: a wrong lane rule
    // there and here would still disagree with the difference quotient.
    const S = Dual(2, f64);
    const core = struct {
        fn f(a: f64, b: f64) S.Of(0b11) {
            const x = S.probe(0, a);
            const y = S.probe(1, b);
            return x.mul(y).add(x.exp().scale(0.3)).sub(y.div(x.addC(2.5)))
                .add(y.mul(y).addC(1.0).sqrt().pow(1.5))
                .add(x.sin().mul(y.cos())).add(x.tanh().atan())
                .add(x.mul(x).addC(1.0).log()).add(y.sinh().scale(0.1))
                .add(x.cosh().scale(0.05)).add(x.expm1().scale(0.2))
                .add(y.mul(y).log1p()).neg();
        }
    }.f;
    for (0..9) |i| for (0..9) |j| {
        const a = @as(f64, @floatFromInt(i)) * 0.3 - 1.2;
        const b = @as(f64, @floatFromInt(j)) * 0.3 - 1.2;
        const r = core(a, b);
        const h = 1e-6;
        const fd = [2]f64{
            (core(a + h, b).val() - core(a - h, b).val()) / (2 * h),
            (core(a, b + h).val() - core(a, b - h).val()) / (2 * h),
        };
        inline for (0..2) |u| {
            const d = r.ddxAt(u);
            try std.testing.expect(@abs(d - fd[u]) <= 1e-6 * @max(1.0, @abs(d)));
        }
    };
}

test "Dual: the padded sparse layout computes the dense layout's numbers" {
    // Three lanes pad to four, and the operands below carry {0,2}, {1,2}
    // and their join, so every spread shuffle and the pad lane are crossed.
    const chain = struct {
        fn f(comptime S: type, a: f64, b: f64, c: f64) S.Of(0b111) {
            const x = S.probe(0, a);
            const y = S.probe(1, b);
            const z = S.probe(2, c);
            const xz = x.mul(z).add(x.exp());
            const yz = y.div(z.addC(3.0)).sub(y.pow(2.0));
            const s = S.sel(x.lt(y), xz, yz);
            return s.mul(xz).add(yz.mul(yz).addC(1.0).sqrt()).add(x.mul(S.con(2.5))).to(0b111);
        }
    }.f;
    const Sparse3 = impl.test_access.Sparse3;
    const grid = [_]f64{ -1.0, -0.5, 0.0, 0.5, 1.0 };
    for (grid) |a| for (grid) |b| for (grid) |c| {
        const dense = chain(Dual(3, f64), a, b, c);
        const sparse = chain(Sparse3, a, b, c);
        try std.testing.expectEqual(dense.val(), sparse.val());
        inline for (0..3) |u| try std.testing.expectEqual(dense.ddxAt(u), sparse.ddxAt(u));
    };
}

test "segmentSum: the eight-wide loads keep the plain loop's order, bit for bit" {
    var prng = std.Random.DefaultPrng.init(0x5e65);
    const r = prng.random();
    var stage: [64]f64 = undefined;
    // Mixed signs and magnitudes, so any reassociation changes the bits.
    for (&stage) |*v| v.* = (r.float(f64) - 0.5) * std.math.pow(f64, 10, @floatFromInt(r.intRangeAtMost(i32, -8, 8)));
    for (0..4) |off| for (0..3 * 8 + 2) |n| {
        const first: u32 = @intCast(off);
        const end: u32 = @intCast(off + n);
        var want: f64 = 0;
        for (stage[first..end]) |v| want += v;
        const got = impl.test_access.segmentSum(&stage, first, end);
        try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(got)));
    };
}

test "repMask: one column per lane, an alias before its root, unlaned columns dropped" {
    const repMask = impl.test_access.repMask;
    const nl = contract.no_lane;
    // Columns 0 and 1 share lane 0; column 1 is the alias, so it stamps.
    try std.testing.expectEqual([3]u64{ 0b110, 0b010, 0 }, comptime repMask(3, .{ 0, 0, 1 }, .{ false, true, false }, .{ 0b111, 0b011, 0 }));
    // No alias: the first column of the lane wins (the identity on the wide basis).
    try std.testing.expectEqual([3]u64{ 0b101, 0b001, 0 }, comptime repMask(3, .{ 0, 0, 1 }, .{ false, false, false }, .{ 0b111, 0b011, 0 }));
    // A column without a lane takes its partial from `jac_const`, not a stamp.
    try std.testing.expectEqual([3]u64{ 0b101, 0b100, 0 }, comptime repMask(3, .{ 0, nl, 1 }, .{ false, false, false }, .{ 0b111, 0b110, 0 }));
}

/// A two-terminal conductance, the smallest device a batch accepts.
const Conductance = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    pub const Model = struct { g: f64 = 1e-3 };
    pub const Instance = struct {};
    pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
        const x = contract.probes(@This(), S, xv);
        const i = x[0].sub(x[1]).scale(m.g);
        return contract.rows(@This(), S, .{ i, i.neg() });
    }
};

/// A dense 3x3 pattern over nodes 0..2; slot 9 and row 3 take ground writes.
const dense3: impl.test_access.PatternView = .{
    .col_ptr = &.{ 0, 3, 6, 9 },
    .row_idx = &.{ 0, 1, 2, 0, 1, 2, 0, 1, 2 },
    .n = 3,
    .trash_slot = 9,
};

test "scatter_bounds: the slot and row ranges a slice touches, ground excluded" {
    const a = std.testing.allocator;
    var proto: ProtoStore(Conductance) = .{};
    // Floating, half grounded, fully grounded.
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 0 } }) |nodes| try proto.append(.{}, .{}, nodes);
    const batch = try ProtoStore(Conductance).finalize(&proto, a, dense3).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const bounds = batch.hooks.scatter_bounds;
    // Slot of (r, c) in the dense pattern is 3c + r.
    try std.testing.expectEqual([4]u32{ 4, 9, 1, 3 }, bounds(batch.ctx, 0, 1, 9, 3));
    try std.testing.expectEqual([4]u32{ 8, 9, 2, 3 }, bounds(batch.ctx, 1, 2, 9, 3));
    try std.testing.expectEqual([4]u32{ 4, 9, 1, 3 }, bounds(batch.ctx, 0, 3, 9, 3));
    // Only trash, or nothing at all: empty ranges.
    try std.testing.expectEqual([4]u32{ 0, 0, 0, 0 }, bounds(batch.ctx, 2, 3, 9, 3));
    try std.testing.expectEqual([4]u32{ 0, 0, 0, 0 }, bounds(batch.ctx, 1, 1, 9, 3));
}

test "ac_dyn: every frequency once, ragged tails included" {
    const D = struct {
        pub const U = Conductance.U;
        pub const num_ports = Conductance.num_ports;
        pub const Model = Conductance.Model;
        pub const Instance = Conductance.Instance;
        pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const i = x[0].sub(x[1]).scale(m.g);
            return contract.rows(@This(), S, .{ i, i.neg() });
        }
        pub const ac_dyn_slots = [_]usize{0};
        pub fn acDyn(comptime V: type, _: *const Model, _: *const Instance, lx: *const [2]f64, _: SimState, ow: anytype, out: anytype) void {
            const w: V = ow;
            out[0] = .{ .re = w + @as(V, @splat(lx[0])), .im = -w };
        }
    };
    const a = std.testing.allocator;
    var proto: ProtoStore(D) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    try proto.append(.{}, .{}, .{ 2, 1 });
    const batch = try ProtoStore(D).finalize(&proto, a, dense3).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const lw = std.simd.suggestVectorLength(f64) orelse 1;
    const x = [_]f64{ 0, 10, 20 };
    var omegas: [3 * lw + 1]f64 = undefined;
    for (&omegas, 0..) |*w, i| w.* = @floatFromInt(i + 1);
    var re: [2 * omegas.len]f64 = undefined;
    var im: [2 * omegas.len]f64 = undefined;
    for (0..omegas.len + 1) |nw| {
        @memset(&re, std.math.nan(f64));
        @memset(&im, std.math.nan(f64));
        try std.testing.expectEqual(@as(usize, 2), batch.hooks.ac_dyn.?(batch.ctx, &x, omegas[0..nw], re[0 .. 2 * nw], im[0 .. 2 * nw]));
        for (0..2) |id| for (0..nw) |i| {
            try std.testing.expectEqual(omegas[i] + x[1 + id], re[id * nw + i]);
            try std.testing.expectEqual(-omegas[i], im[id * nw + i]);
        };
        // Nothing past the entries asked for.
        for (re[2 * nw ..]) |v| try std.testing.expect(std.math.isNan(v));
    }
}

test "finalize leaves nothing of its allocator behind when an allocation fails" {
    const D = struct {
        pub const U = Conductance.U;
        pub const num_ports = Conductance.num_ports;
        pub const Model = Conductance.Model;
        pub const Instance = Conductance.Instance;
        pub fn eval(comptime S: type, xv: *const [2]S.V, m: *const Model, _: *const Instance, _: SimState) contract.Rows(@This(), S) {
            const x = contract.probes(@This(), S, xv);
            const i = x[0].sub(x[1]).scale(m.g);
            return contract.rows(@This(), S, .{ i, i.neg() });
        }
        pub const State = struct { seen: f64 = 0 };
        pub fn initState(_: *const Model, _: *const Instance) State {
            return .{};
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            const proto = try gpa.create(ProtoStore(D));
            proto.* = .{};
            defer ProtoStore(D).destroy(proto, gpa);
            try proto.append(.{}, .{}, .{ 1, 2 });
            try proto.append(.{}, .{}, .{ 2, 0 });
            const batch = try ProtoStore(D).finalize(proto, gpa, dense3).unwrap();
            batch.hooks.deinit(batch.ctx, gpa);
        }
    }.run, .{});
}

test "finalize starts a batch before its analog initial block, whatever the allocator held" {
    // A fixed buffer of set bits stands in for reused memory: `create` hands
    // out the bytes as they are, so a field finalize skips reads as true.
    var buf: [16 * 1024]u8 align(16) = @splat(0xff);
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var proto: ProtoStore(Conductance) = .{};
    try proto.append(.{}, .{}, .{ 1, 2 });
    const batch = try ProtoStore(Conductance).finalize(&proto, a, dense3).unwrap();
    defer batch.hooks.deinit(batch.ctx, a);
    const typed: *DeviceBatch(Conductance) = @ptrCast(@alignCast(batch.ctx));
    batch.hooks.set_sim_state(batch.ctx, .{});
    try std.testing.expect(typed.sim.analog_initial);
    try std.testing.expect(!typed.held_initial);
    try std.testing.expect(!typed.committed_initial);
}
