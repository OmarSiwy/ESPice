const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ---------------------------------------------------------------------------
// Unknowns — four external voltage ports, one internal branch current
// ---------------------------------------------------------------------------

pub const U = enum(u8) {
    p_out = 0,
    n_out = 1,
    p_ctrl = 2,
    n_ctrl = 3,
    ibr = 4,
};

pub const num_ports: usize = 4;

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // p_out
    .voltage, // n_out
    .voltage, // p_ctrl
    .voltage, // n_ctrl
    .current, // ibr
};

// ---------------------------------------------------------------------------
// Model — empty per spec (all behavior from instance parameters)
// ---------------------------------------------------------------------------

pub const Model = struct {};

// ---------------------------------------------------------------------------
// Instance parameters
// ---------------------------------------------------------------------------

pub const Instance = struct {
    gain: f32 = 0.0,
    ic: f32 = 0.0,
};

// ---------------------------------------------------------------------------
// Sparse conductance stamp pattern (Jacobian non-zeros)
//
//   dI(p_out)/d(ibr)   = +1         row=p_out,  col=ibr
//   dI(n_out)/d(ibr)   = -1         row=n_out,  col=ibr
//   dF(ibr)/d(p_out)   = +1         row=ibr,    col=p_out
//   dF(ibr)/d(n_out)   = -1         row=ibr,    col=n_out
//   dF(ibr)/d(p_ctrl)  = -E         row=ibr,    col=p_ctrl
//   dF(ibr)/d(n_ctrl)  = +E         row=ibr,    col=n_ctrl
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Physics: current contributions (MNA formulation)
// ---------------------------------------------------------------------------

pub fn eval(comptime S: type, x: [n_u]S, _: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p_out = @intFromEnum(U.p_out);
    const n_out = @intFromEnum(U.n_out);
    const p_ctrl = @intFromEnum(U.p_ctrl);
    const n_ctrl = @intFromEnum(U.n_ctrl);
    const ibr = @intFromEnum(U.ibr);

    const gain: f64 = @as(f64, instance.gain);

    const i_br = x[ibr];
    const v_out = x[p_out].sub(x[n_out]);
    const v_ctrl = x[p_ctrl].sub(x[n_ctrl]);
    const f_ibr = v_out.sub(v_ctrl.scale(gain));

    return .{ i_br, i_br.neg(), S.con(0.0), S.con(0.0), f_ibr };
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p_out = @intFromEnum(U.p_out);
    const n_out = @intFromEnum(U.n_out);
    const p_ctrl = @intFromEnum(U.p_ctrl);
    const n_ctrl = @intFromEnum(U.n_ctrl);
    const ibr = @intFromEnum(U.ibr);

    const i_br = x[ibr];
    const v_out = x[p_out].sub(x[n_out]);
    const v_ctrl = x[p_ctrl].sub(x[n_ctrl]);
    const f_ibr = v_out.sub(v_ctrl.scale(pc.gain));

    return .{ i_br, i_br.neg(), S.con(0.0), S.con(0.0), f_ibr };
}

// ---------------------------------------------------------------------------
// Compile-time contract validation
// ---------------------------------------------------------------------------

comptime {
    contract.validate(Self);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "vcvs: gain 10, satisfied constraint" {
    // gain E = 10, V(p_ctrl)-V(n_ctrl) = 0.5 V -> V_out must be 5 V.
    // x = { p_out=5, n_out=0, p_ctrl=0.5, n_ctrl=0, ibr=2e-3 }
    // Old formula by hand:
    //   out[p_out]  = i_br           =  2e-3
    //   out[n_out]  = -i_br          = -2e-3
    //   out[p_ctrl] = 0
    //   out[n_ctrl] = 0
    //   out[ibr]    = (5-0) - 10*(0.5-0) = 0
    const model: Model = .{};
    const inst: Instance = .{ .gain = 10.0 };
    const out = contract.evalValues(Self, .{ 5.0, 0.0, 0.5, 0.0, 2e-3 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 2e-3), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[4], 1e-15);
}

test "vcvs: nonzero constraint residual" {
    // gain E = 2, x = { p_out=1, n_out=-1, p_ctrl=3, n_ctrl=1, ibr=-0.25 }
    // Old formula by hand:
    //   v_out  = 1 - (-1) = 2
    //   v_ctrl = 3 - 1    = 2
    //   out[p_out]  = -0.25
    //   out[n_out]  =  0.25
    //   out[ibr]    = 2 - 2*2 = -2
    const model: Model = .{};
    const inst: Instance = .{ .gain = 2.0 };
    const out = contract.evalValues(Self, .{ 1.0, -1.0, 3.0, 1.0, -0.25 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -0.25), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.25), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -2.0), out[4], 1e-15);
}
