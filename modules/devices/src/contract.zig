//! Device contract: the comptime interface every device (hand-written or
//! VAF/VF-generated) must satisfy. `validate(D)` checks the full surface the
//! solver (analysis/compiled.zig) actually calls, so a mismatch fails at the
//! device definition with a readable error instead of deep in a solver loop.
//!
//! Physics is VALUE-FORM: written once, generic over an opaque scalar S.
//! The analysis crate instantiates it with a derivative-carrying scalar, so
//! one pass yields residual + all analytic partials — no finite differences.
//!
//!   pub fn eval(comptime S: type, x: [n_u]S, m: *const Model, i: *const Instance, t: f64) [n_u]S;
//!   pub fn q   (comptime S: type, x, m, i, t) [n_u]S;   // optional: charges
//!
//! The scalar interface S provides (see `Value` below for the plain-f64
//! reference implementation — the analysis side must mirror this list):
//!
//!   con addC scale            — constants in / scaling
//!   add sub neg mul div       — arithmetic
//!   exp log sqrt pow          — pow(a, c): constant exponent
//!   sin cos tanh sinh cosh atan
//!   abs minC maxC min max     — piecewise; derivative flat past clamp
//!   val                       — read the value (branching, debugging)
//!
//! RULES for physics code:
//!   - Everything not depending on x (param prep, temperature, geometry)
//!     stays plain f64. Only x-dependent chains use S ops.
//!   - Never branch on an S with `if` directly; use .val() for topology-level
//!     decisions and minC/maxC/min/max for clamps (they keep the derivative
//!     consistent with the picked branch).

const std = @import("std");

pub const UpdateResult = union(enum) {
    ok,
    request_reject_at: f64,
};

pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

pub fn Entry(comptime n: usize) type {
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
    };
}

pub const HistoryReq = struct {
    max_delay: f64,
    interp_order: u8 = 1,
};

pub fn NoiseGen(comptime D: type) type {
    const n = nU(D);
    return struct {
        row: std.math.IntFittingRange(0, n - 1),
        col: std.math.IntFittingRange(0, n - 1),
        kind: enum { thermal, shot, flicker },
    };
}

pub fn nU(comptime D: type) comptime_int {
    return @typeInfo(D.U).@"enum".fields.len;
}

pub fn uKinds(comptime D: type) [nU(D)]UnknownKind {
    if (@hasDecl(D, "u_kinds")) return D.u_kinds;
    return [_]UnknownKind{.voltage} ** nU(D);
}

// ============================================================================
// Value: plain-f64 scalar satisfying the S interface. Reference
// implementation of the op list; used by device unit tests (and any consumer
// that wants residuals without derivatives).
// ============================================================================

pub const Value = struct {
    v: f64,

    const Self = @This();

    pub fn con(c: f64) Self {
        return .{ .v = c };
    }
    pub fn add(a: Self, b: Self) Self {
        return .{ .v = a.v + b.v };
    }
    pub fn sub(a: Self, b: Self) Self {
        return .{ .v = a.v - b.v };
    }
    pub fn neg(a: Self) Self {
        return .{ .v = -a.v };
    }
    pub fn mul(a: Self, b: Self) Self {
        return .{ .v = a.v * b.v };
    }
    pub fn div(a: Self, b: Self) Self {
        return .{ .v = a.v / b.v };
    }
    pub fn scale(a: Self, c: f64) Self {
        return .{ .v = a.v * c };
    }
    pub fn addC(a: Self, c: f64) Self {
        return .{ .v = a.v + c };
    }
    pub fn exp(a: Self) Self {
        return .{ .v = @exp(a.v) };
    }
    pub fn log(a: Self) Self {
        return .{ .v = @log(a.v) };
    }
    pub fn sqrt(a: Self) Self {
        return .{ .v = @sqrt(a.v) };
    }
    pub fn sin(a: Self) Self {
        return .{ .v = @sin(a.v) };
    }
    pub fn cos(a: Self) Self {
        return .{ .v = @cos(a.v) };
    }
    pub fn tanh(a: Self) Self {
        return .{ .v = std.math.tanh(a.v) };
    }
    pub fn abs(a: Self) Self {
        return .{ .v = @abs(a.v) };
    }
    pub fn minC(a: Self, c: f64) Self {
        return .{ .v = @min(a.v, c) };
    }
    pub fn maxC(a: Self, c: f64) Self {
        return .{ .v = @max(a.v, c) };
    }
    pub fn pow(a: Self, c: f64) Self {
        return .{ .v = std.math.pow(f64, a.v, c) };
    }
    pub fn atan(a: Self) Self {
        return .{ .v = std.math.atan(a.v) };
    }
    pub fn sinh(a: Self) Self {
        return .{ .v = std.math.sinh(a.v) };
    }
    pub fn cosh(a: Self) Self {
        return .{ .v = std.math.cosh(a.v) };
    }
    pub fn max(a: Self, b: Self) Self {
        return .{ .v = @max(a.v, b.v) };
    }
    pub fn min(a: Self, b: Self) Self {
        return .{ .v = @min(a.v, b.v) };
    }
    pub fn val(a: Self) f64 {
        return a.v;
    }
};

// ============================================================================
// Dual: forward-mode derivative-carrying scalar satisfying the S interface.
// Used by GENERATED (VAF/VF) devices to export analytic residual+Jacobian
// across the .so ABI (zpicey_eval_ad). Hand-written devices never name it —
// the analysis crate instantiates their physics with its own scalar.
// ============================================================================

pub fn Dual(comptime N: usize) type {
    return struct {
        v: f64,
        d: V,

        const V = @Vector(N, f64);
        const Self = @This();

        inline fn splat(c: f64) V {
            return @splat(c);
        }
        /// Seed unknown `u` (derivative 1 w.r.t. itself). `u` is comptime —
        /// a runtime-indexed vector write does not compile; every caller seeds
        /// inside an `inline for`, so the index is comptime anyway.
        pub fn seed(value: f64, comptime u: usize) Self {
            var d: V = @splat(0);
            d[u] = 1;
            return .{ .v = value, .d = d };
        }
        pub fn con(c: f64) Self {
            return .{ .v = c, .d = splat(0) };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .v = a.v + b.v, .d = a.d + b.d };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .v = a.v - b.v, .d = a.d - b.d };
        }
        pub fn neg(a: Self) Self {
            return .{ .v = -a.v, .d = -a.d };
        }
        pub fn mul(a: Self, b: Self) Self {
            return .{ .v = a.v * b.v, .d = a.d * splat(b.v) + b.d * splat(a.v) };
        }
        pub fn div(a: Self, b: Self) Self {
            const inv_b = 1.0 / b.v;
            const quot = a.v * inv_b;
            return .{ .v = quot, .d = (a.d - b.d * splat(quot)) * splat(inv_b) };
        }
        pub fn scale(a: Self, c: f64) Self {
            return .{ .v = a.v * c, .d = a.d * splat(c) };
        }
        pub fn addC(a: Self, c: f64) Self {
            return .{ .v = a.v + c, .d = a.d };
        }
        pub fn exp(a: Self) Self {
            const e = @exp(a.v);
            return .{ .v = e, .d = a.d * splat(e) };
        }
        pub fn log(a: Self) Self {
            return .{ .v = @log(a.v), .d = a.d * splat(1.0 / a.v) };
        }
        pub fn sqrt(a: Self) Self {
            const s = @sqrt(a.v);
            return .{ .v = s, .d = a.d * splat(0.5 / s) };
        }
        pub fn sin(a: Self) Self {
            return .{ .v = @sin(a.v), .d = a.d * splat(@cos(a.v)) };
        }
        pub fn cos(a: Self) Self {
            return .{ .v = @cos(a.v), .d = a.d * splat(-@sin(a.v)) };
        }
        pub fn tanh(a: Self) Self {
            const th = std.math.tanh(a.v);
            return .{ .v = th, .d = a.d * splat(1.0 - th * th) };
        }
        pub fn abs(a: Self) Self {
            return if (a.v < 0) a.neg() else a;
        }
        pub fn minC(a: Self, c: f64) Self {
            return if (a.v > c) con(c) else a;
        }
        pub fn maxC(a: Self, c: f64) Self {
            return if (a.v < c) con(c) else a;
        }
        pub fn pow(a: Self, c: f64) Self {
            const p = std.math.pow(f64, a.v, c);
            return .{ .v = p, .d = a.d * splat(c * p / a.v) };
        }
        pub fn atan(a: Self) Self {
            return .{ .v = std.math.atan(a.v), .d = a.d * splat(1.0 / (1.0 + a.v * a.v)) };
        }
        pub fn sinh(a: Self) Self {
            return .{ .v = std.math.sinh(a.v), .d = a.d * splat(std.math.cosh(a.v)) };
        }
        pub fn cosh(a: Self) Self {
            return .{ .v = std.math.cosh(a.v), .d = a.d * splat(std.math.sinh(a.v)) };
        }
        pub fn max(a: Self, b: Self) Self {
            return if (a.v >= b.v) a else b;
        }
        pub fn min(a: Self, b: Self) Self {
            return if (a.v <= b.v) a else b;
        }
        pub fn val(a: Self) f64 {
            return a.v;
        }
    };
}

/// Evaluate D's residual at plain-f64 terminal values. Test helper.
pub fn evalValues(comptime D: type, x: [nU(D)]f64, m: *const D.Model, inst: *const D.Instance, t: f64) [nU(D)]f64 {
    var xs: [nU(D)]Value = undefined;
    inline for (0..nU(D)) |u| xs[u] = Value.con(x[u]);
    const out = D.eval(Value, xs, m, inst, t);
    var res: [nU(D)]f64 = undefined;
    inline for (0..nU(D)) |u| res[u] = out[u].val();
    return res;
}

/// Same for the charge function.
pub fn qValues(comptime D: type, x: [nU(D)]f64, m: *const D.Model, inst: *const D.Instance, t: f64) [nU(D)]f64 {
    var xs: [nU(D)]Value = undefined;
    inline for (0..nU(D)) |u| xs[u] = Value.con(x[u]);
    const out = D.q(Value, xs, m, inst, t);
    var res: [nU(D)]f64 = undefined;
    inline for (0..nU(D)) |u| res[u] = out[u].val();
    return res;
}

// ============================================================================
// Validation
// ============================================================================

pub fn validate(comptime D: type) void {
    const name = @typeName(D);

    // Required decls first, so a missing one reads as a contract violation
    // rather than a raw "no member named ..." error.
    for (.{ "U", "num_ports", "Model", "Instance", "eval" }) |decl| {
        if (!@hasDecl(D, decl))
            @compileError(name ++ ": contract requires `pub " ++ decl ++ "`");
    }

    if (@typeInfo(D.U) != .@"enum" or !isDenseEnum(D.U))
        @compileError(name ++ ".U must be a dense enum(u8) with values 0..n-1");
    const n = nU(D);

    const np: usize = D.num_ports;
    if (np == 0 or np > n)
        @compileError(name ++ ".num_ports must be in 1..|U|");

    validateDefaultedStruct(D, "Model");
    validateDefaultedStruct(D, "Instance");

    // Physics: generic over S, so only shape-checkable. eval/q take
    // (comptime S, [n]S, *const Model, *const Instance, f64).
    validatePhysicsFn(D, "eval");
    if (@hasDecl(D, "q")) validatePhysicsFn(D, "q");

    // State machine: eval reads Instance, so updateState gets a MUTABLE
    // Instance — switch position etc. must live in Instance fields.
    if (@hasDecl(D, "initState") or @hasDecl(D, "updateState")) {
        if (!@hasDecl(D, "State"))
            @compileError(name ++ ": initState/updateState require pub const State");
        expectFn(D, "initState", fn (*const D.Model, *const D.Instance) D.State);
        expectFn(D, "updateState", fn (*const D.Model, *D.Instance, [n]f64, *D.State) UpdateResult);
    }

    // History (delay-line devices): histInject is generic over the lookup
    // (it cannot name the analysis crate's HistLookup), so shape-check only.
    if (@hasDecl(D, "histInject")) {
        if (!@hasDecl(D, "n_hist_signals"))
            @compileError(name ++ ": histInject requires pub const n_hist_signals");
        const nh: u32 = D.n_hist_signals;
        expectFn(D, "gatherHistSignals", fn ([n]f64) [nh]f64);
        validateDelaysFn(D);
        const info = @typeInfo(@TypeOf(D.histInject));
        if (info != .@"fn" or info.@"fn".params.len != 3)
            @compileError(name ++ ".histInject: expected fn (*const Model, lookup: anytype, t: f64) [n_u]f64");
    }

    // Convergence aids.
    if (@hasDecl(D, "attempt")) {
        const T = @TypeOf(D.attempt);
        if (T != fn (D.Model, f64) D.Model and T != fn (D.Model, D.Instance, f64) D.Model)
            @compileError(name ++ ".attempt: expected fn (Model, f64) Model or fn (Model, Instance, f64) Model");
    }
    if (@hasDecl(D, "limit"))
        expectFn(D, "limit", fn (*const D.Model, *const D.Instance, [n]f64, [n]f64) [n]f64);

    // Optional metadata.
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]UnknownKind)
        @compileError(name ++ ".u_kinds must be [|U|]UnknownKind");
    if (@hasDecl(D, "g_pattern_override")) validateEntryArray(D, "g_pattern_override", n);
    if (@hasDecl(D, "c_pattern_override")) validateEntryArray(D, "c_pattern_override", n);
    if (@hasDecl(D, "noise_gens")) {
        const info = @typeInfo(@TypeOf(D.noise_gens));
        if (info != .array or info.array.child != NoiseGen(D))
            @compileError(name ++ ".noise_gens must be [k]NoiseGen(Self)");
    }
    validateMcParam(D);

    // PrepCache: if declared, device must also export computePrep and evalFromPrep.
    // qFromPrep is required when the device also declares q.
    if (@hasDecl(D, "PrepCache")) {
        if (!@hasDecl(D, "computePrep"))
            @compileError(name ++ ": PrepCache requires pub fn computePrep");
        if (!@hasDecl(D, "evalFromPrep"))
            @compileError(name ++ ": PrepCache requires pub fn evalFromPrep");
        if (@hasDecl(D, "q") and !@hasDecl(D, "qFromPrep"))
            @compileError(name ++ ": PrepCache + q requires pub fn qFromPrep");
    }
}

/// eval/q: fn (comptime S: type, [n]S, *const Model, *const Instance, f64) [n]S.
/// Generic over S, so the concrete signature is checked by instantiation:
/// here only arity + comptime-type first param.
fn validatePhysicsFn(comptime D: type, comptime fn_name: []const u8) void {
    const info = @typeInfo(@TypeOf(@field(D, fn_name)));
    if (info != .@"fn" or info.@"fn".params.len != 5 or info.@"fn".params[0].type != type)
        @compileError(@typeName(D) ++ "." ++ fn_name ++
            ": expected fn (comptime S: type, [n_u]S, *const Model, *const Instance, f64) [n_u]S");
}

fn expectFn(comptime D: type, comptime fn_name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(D, fn_name))
        @compileError(@typeName(D) ++ ": missing " ++ fn_name);
    if (@TypeOf(@field(D, fn_name)) != Expected)
        @compileError(@typeName(D) ++ "." ++ fn_name ++ ": expected " ++ @typeName(Expected));
}

fn validateDefaultedStruct(comptime D: type, comptime decl: []const u8) void {
    const T = @field(D, decl);
    if (@typeInfo(T) != .@"struct")
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be a struct");
    for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null)
            @compileError(@typeName(D) ++ "." ++ decl ++ "." ++ f.name ++ " must have a default value");
    }
}

fn validateDelaysFn(comptime D: type) void {
    const err = @typeName(D) ++ ".delays: expected fn (*const Model) [k]f64, k >= 1";
    if (!@hasDecl(D, "delays")) @compileError(err);
    const info = @typeInfo(@TypeOf(D.delays));
    if (info != .@"fn" or info.@"fn".params.len != 1 or
        info.@"fn".params[0].type != *const D.Model)
        @compileError(err);
    const ret = @typeInfo(info.@"fn".return_type.?);
    if (ret != .array or ret.array.child != f64 or ret.array.len == 0)
        @compileError(err);
}

fn validateEntryArray(comptime D: type, comptime decl: []const u8, comptime n: comptime_int) void {
    const info = @typeInfo(@TypeOf(@field(D, decl)));
    if (info != .array or info.array.child != Entry(n))
        @compileError(@typeName(D) ++ "." ++ decl ++ " must be [k]Entry(n_u)");
}

fn isDenseEnum(comptime E: type) bool {
    const info = @typeInfo(E).@"enum";
    if (info.tag_type != u8) return false;
    for (info.fields, 0..) |f, idx| {
        if (f.value != idx) return false;
    }
    return true;
}

/// Optional per-device declaration: `pub const mc_param = "resist";`
/// Names the principal value parameter (Instance or Model f32 field) that
/// Monte Carlo varies. Validated here so a typo fails at compile time.
pub fn validateMcParam(comptime D: type) void {
    if (!@hasDecl(D, "mc_param")) return;
    const name: []const u8 = D.mc_param;
    var found = false;
    for (@typeInfo(D.Instance).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and f.type == f32) found = true;
    }
    for (@typeInfo(D.Model).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name) and f.type == f32) found = true;
    }
    if (!found) @compileError(@typeName(D) ++ ".mc_param '" ++ D.mc_param ++ "' is not an f32 field of Model or Instance");
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const MockR = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    pub const Model = struct {
        g: f64 = 1e-3,
    };

    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const ir = x[0].sub(x[1]).scale(model.g);
        return .{ ir, ir.neg() };
    }
};

const MockSw = struct {
    pub const U = enum(u8) { p, n };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    // Switch position lives in Instance so eval can read it.
    pub const State = struct { flips: u32 = 0 };

    pub const Model = struct {
        gon: f64 = 1.0,
        goff: f64 = 1e-12,
    };

    pub const Instance = struct {
        closed: bool = false,
    };

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, inst: *const Instance, _: f64) [n_u]S {
        const g = if (inst.closed) model.gon else model.goff;
        const ir = x[0].sub(x[1]).scale(g);
        return .{ ir, ir.neg() };
    }

    pub fn initState(_: *const Model, _: *const Instance) State {
        return .{};
    }

    pub fn updateState(_: *const Model, inst: *Instance, x: [n_u]f64, s: *State) UpdateResult {
        const want = (x[0] - x[1]) > 0.5;
        if (want != inst.closed) {
            inst.closed = want;
            s.flips += 1;
        }
        return .ok;
    }

    pub fn attempt(model: Model, lambda: f64) Model {
        var m = model;
        m.gon *= lambda;
        return m;
    }

    pub fn limit(_: *const Model, _: *const Instance, x_new: [n_u]f64, _: [n_u]f64) [n_u]f64 {
        return x_new;
    }
};

const MockTline = struct {
    pub const U = enum(u8) { p1, p2 };
    pub const num_ports: usize = 2;
    const n_u = nU(@This());

    pub const Model = struct {
        z0: f32 = 50,
        td: f32 = 1e-9,
    };

    pub const Instance = struct {};

    pub const mc_param = "z0";
    pub const u_kinds = [n_u]UnknownKind{ .voltage, .voltage };
    pub const g_pattern_override = [_]Entry(n_u){.{ .row = 0, .col = 0 }};
    pub const c_pattern_override = [0]Entry(n_u){};
    pub const noise_gens = [_]NoiseGen(@This()){.{ .row = 0, .col = 1, .kind = .thermal }};

    pub const n_hist_signals: u32 = 2;

    pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, _: *const Instance, _: f64) [n_u]S {
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ x[0].scale(y0), x[1].scale(y0) };
    }

    pub fn delays(model: *const Model) [1]f64 {
        return .{@as(f64, model.td)};
    }

    pub fn gatherHistSignals(x: [n_u]f64) [n_hist_signals]f64 {
        return .{ x[0], x[1] };
    }

    pub fn histInject(model: *const Model, lookup: anytype, t: f64) [n_u]f64 {
        const td = @as(f64, model.td);
        const y0 = 1.0 / @as(f64, model.z0);
        return .{ lookup.at(t - td, 1) * y0, lookup.at(t - td, 0) * y0 };
    }
};

test "validate: minimal resistor" {
    comptime validate(MockR);
}

test "validate: switch (state in Instance + attempt + limit)" {
    comptime validate(MockSw);
}

test "validate: tline (histInject + metadata)" {
    comptime validate(MockTline);
}

test "evalValues: MockR residual" {
    const m: MockR.Model = .{ .g = 2e-3 };
    const out = evalValues(MockR, .{ 1.0, 0.0 }, &m, &.{}, 0);
    try testing.expectApproxEqAbs(@as(f64, 2e-3), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[1], 1e-15);
}

test "updateState mutates Instance" {
    var inst: MockSw.Instance = .{};
    var s: MockSw.State = .{};
    const m: MockSw.Model = .{};
    _ = MockSw.updateState(&m, &inst, .{ 1.0, 0.0 }, &s);
    try testing.expect(inst.closed);
    try testing.expectEqual(@as(u32, 1), s.flips);
}

test "uKinds default: all voltage" {
    const k = comptime uKinds(MockR);
    try testing.expectEqual(UnknownKind.voltage, k[0]);
    try testing.expectEqual(UnknownKind.voltage, k[1]);
}

test "uKinds override" {
    const k = comptime uKinds(MockTline);
    try testing.expectEqual(UnknownKind.voltage, k[1]);
}

test "nU" {
    try testing.expectEqual(@as(comptime_int, 2), comptime nU(MockR));
}
