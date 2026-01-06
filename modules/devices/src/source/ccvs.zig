const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

pub const U = enum(u8) {
    p = 0,
    n = 1,
    ctrl_br = 2,
    br = 3,
};

pub const num_ports: usize = 3;

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // p
    .voltage, // n
    .current, // ctrl_br
    .current, // br
};

pub const Model = struct {};

pub const Instance = struct {
    gain: f32 = 0.0,
};

/// Conductance stamp pattern — only the 5 non-zero Jacobian entries.
///
///   G[p,    br]      = +1
///   G[n,    br]      = -1
///   G[br,   p]       = +1
///   G[br,   n]       = -1
///   G[br,   ctrl_br] = -H
///

// ---------------------------------------------------------------------------
// PrepCache: hot eval data in contiguous array (SoA over devices)
// ---------------------------------------------------------------------------

pub const PrepCache = struct { gain: f64 };

pub fn computePrep(_: *const Model, instance: *const Instance) PrepCache {
    return .{ .gain = @as(f64, instance.gain) };
}

// ---------------------------------------------------------------------------
// Constant-Jacobian flag: G stamp is independent of x.
// ---------------------------------------------------------------------------

pub const constant_g = true;

pub fn eval(comptime S: type, x: [n_u]S, _: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const gain: f64 = @as(f64, instance.gain);

    return .{
        x[@intFromEnum(U.br)],
        x[@intFromEnum(U.br)].neg(),
        S.con(0.0),
        x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]).sub(x[@intFromEnum(U.ctrl_br)].scale(gain)),
    };
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    return .{
        x[@intFromEnum(U.br)],
        x[@intFromEnum(U.br)].neg(),
        S.con(0.0),
        x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]).sub(x[@intFromEnum(U.ctrl_br)].scale(pc.gain)),
    };
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ccvs: on-state residual (H=50, I_ctrl=2mA, I_br=10mA)" {
    // Old formula by hand:
    //   f[p]       =  I_br                     =  0.01
    //   f[n]       = -I_br                     = -0.01
    //   f[ctrl_br] =  0
    //   f[br]      =  V_p - V_n - H * I_ctrl   = 1.5 - 0.4 - 50*0.002 = 1.0
    const model: Model = .{};
    const inst: Instance = .{ .gain = 50.0 };
    const out = contract.evalValues(Self, .{ 1.5, 0.4, 0.002, 0.01 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.01), out[@intFromEnum(U.p)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.01), out[@intFromEnum(U.n)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.ctrl_br)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[@intFromEnum(U.br)], 1e-12);
}

test "ccvs: satisfied branch equation is zero residual" {
    // H=1000, I_ctrl=1mA -> V_p - V_n must be 1V for f[br]=0.
    //   f[br] = 1.0 - 0.0 - 1000*0.001 = 0
    //   f[p]  =  I_br = -0.25 (branch current is an independent unknown)
    const model: Model = .{};
    const inst: Instance = .{ .gain = 1000.0 };
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.001, -0.25 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -0.25), out[@intFromEnum(U.p)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), out[@intFromEnum(U.n)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.ctrl_br)], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.br)], 1e-12);
}
