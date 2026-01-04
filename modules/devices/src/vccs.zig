const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminal enumeration — all external, no internal nodes
// ============================================================================

pub const U = enum(u8) {
    p_out = 0,
    n_out = 1,
    p_ctrl = 2,
    n_ctrl = 3,
};

pub const num_ports: usize = 4;

// ============================================================================
// Model parameters — none for VCCS (all parameters are instance-level)
// ============================================================================

pub const Model = struct {};

// ============================================================================
// Instance parameters
// ============================================================================

pub const Instance = struct {
    gain: f32 = 0.0,
    m: f32 = 1.0,
    ic: f32 = 0.0,
    sens_trans: bool = false,
    cached_g: f32 = std.math.inf(f32),
};

// ============================================================================
// Sparse conductance stamp pattern
//
// Jacobian has exactly 4 non-zero entries (transconductance cross-terms):
//   dI(p_out)/dV(p_ctrl)  = +g_eff
//   dI(p_out)/dV(n_ctrl)  = -g_eff
//   dI(n_out)/dV(p_ctrl)  = -g_eff
//   dI(n_out)/dV(n_ctrl)  = +g_eff
// ============================================================================

// ============================================================================
// Physics function — linear voltage-controlled current source
//
//   V_ctrl = V(p_ctrl) - V(n_ctrl)
//   g_eff  = gain * m
//   I_out  = g_eff * V_ctrl
//
//   I(p_out)  = +I_out    (current flows into p_out)
//   I(n_out)  = -I_out    (current flows out of n_out)
//   I(p_ctrl) = 0         (infinite input impedance)
//   I(n_ctrl) = 0         (infinite input impedance)
// ============================================================================

/// Effective transconductance from instance params. Pure f64 — no x.
fn effectiveG(instance: *const Instance) f64 {
    const gain: f64 = @as(f64, instance.gain);
    const m: f64 = @as(f64, instance.m);
    return gain * m;
}

pub fn precompute(instance: *Instance, model: *const Model) void {
    _ = model;
    instance.cached_g = @floatCast(effectiveG(instance));
}

// ============================================================================
// PrepCache: hot eval data in contiguous array (SoA over devices)
// ============================================================================

pub const PrepCache = struct { g: f64 };

pub fn computePrep(_: *const Model, instance: *const Instance) PrepCache {
    return .{ .g = @as(f64, instance.cached_g) };
}

// ============================================================================
// Constant-Jacobian flag: G stamp is independent of x.
// ============================================================================

pub const constant_g = true;

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = t;

    const g_eff: f64 = @as(f64, instance.cached_g);
    const v_ctrl = x[@intFromEnum(U.p_ctrl)].sub(x[@intFromEnum(U.n_ctrl)]);
    const i_out = v_ctrl.scale(g_eff);

    return .{ i_out, i_out.neg(), S.con(0.0), S.con(0.0) };
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const v_ctrl = x[@intFromEnum(U.p_ctrl)].sub(x[@intFromEnum(U.n_ctrl)]);
    const i_out = v_ctrl.scale(pc.g);

    return .{ i_out, i_out.neg(), S.con(0.0), S.con(0.0) };
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "vccs: gain 2mS, 1V control -> 2mA output, zero control current" {
    // Old formula: i_out = gain * m * (V(p_ctrl) - V(n_ctrl))
    //            = 2e-3 * 1.0 * (1.5 - 0.5) = 2e-3
    const model: Model = .{};
    var inst: Instance = .{ .gain = 2e-3 };
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 0.0, 0.0, 1.5, 0.5 }, &model, &inst, 0);
    // (tolerance accounts for f32 param storage)
    try testing.expectApproxEqAbs(@as(f64, 2e-3), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-12);
}

test "vccs: parallel multiplier m scales transconductance" {
    // i_out = gain * m * v_ctrl = 1e-3 * 4.0 * (-2.0 - 0.0) = -8e-3
    const model: Model = .{};
    var inst: Instance = .{ .gain = 1e-3, .m = 4.0 };
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 0.0, 0.0, -2.0, 0.0 }, &model, &inst, 0);
    // (tolerance accounts for f32 param storage)
    try testing.expectApproxEqAbs(@as(f64, -8e-3), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8e-3), out[1], 1e-9);
}

test "vccs: zero gain default -> zero output" {
    const model: Model = .{};
    var inst: Instance = .{};
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 5.0, -5.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-12);
}
