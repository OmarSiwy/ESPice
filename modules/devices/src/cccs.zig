const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

/// Current-Controlled Current Source (F device).
///
/// Three-terminal device: two output ports (p, n) and one controlling
/// branch current reference (ctrl_br). Injects I_out = G * M * I_ctrl
/// into node p and extracts it from node n.
pub const U = enum(u8) {
    p = 0,
    n = 1,
    ctrl_br = 2,
};

pub const num_ports: usize = 3;

/// ctrl_br is a branch current unknown, not a voltage.
pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // p
    .voltage, // n
    .current, // ctrl_br
};

/// The CCCS has no model-card parameters; all behavior is controlled
/// by instance parameters.
pub const Model = struct {};

/// Per-instance parameters.
pub const Instance = struct {
    /// Current gain (A/A).
    gain: f32 = 1.0,
    /// Parallel multiplier — folded into gain at evaluation time.
    m: f32 = 1.0,
    /// Flag to request sensitivity analysis w.r.t. gain.
    sens_gain: bool = false,
    cached_gain: f32 = std.math.inf(f32),
};

/// The CCCS only stamps two entries in the conductance matrix:
///   dI_p   / dI_ctrl = +G*M  -> (p, ctrl_br)
///   dI_n   / dI_ctrl = -G*M  -> (n, ctrl_br)
pub const g_pattern_override = [_]contract.Entry(n_u){
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.ctrl_br) },
    .{ .row = @intFromEnum(U.n), .col = @intFromEnum(U.ctrl_br) },
};

/// Effective gain = G * M from instance params. Pure f64 — no x.
fn effectiveGain(instance: *const Instance) f64 {
    const gain: f64 = @as(f64, instance.gain);
    const m: f64 = @as(f64, instance.m);
    return gain * m;
}

pub fn precompute(instance: *Instance, model: *const Model) void {
    _ = model;
    instance.cached_gain = @floatCast(effectiveGain(instance));
}

// ============================================================================
// PrepCache: hot eval data in contiguous array (SoA over devices)
// ============================================================================

pub const PrepCache = struct { gain: f64 };

pub fn computePrep(_: *const Model, instance: *const Instance) PrepCache {
    return .{ .gain = @as(f64, instance.cached_gain) };
}

// ============================================================================
// Constant-Jacobian flag: G stamp is independent of x.
// ============================================================================

pub const constant_g = true;

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = t;

    const gm: f64 = @as(f64, instance.cached_gain);
    const i_out = x[@intFromEnum(U.ctrl_br)].scale(gm);

    return .{ i_out, i_out.neg(), S.con(0.0) };
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const i_out = x[@intFromEnum(U.ctrl_br)].scale(pc.gain);

    return .{ i_out, i_out.neg(), S.con(0.0) };
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "cccs: on-state residual, gain*m folded" {
    // gain=2, m=3 -> G*M = 6; I_ctrl = 0.5 A
    // I_p = 6 * 0.5 = 3.0 A, I_n = -3.0 A, I_ctrl_br = 0
    const model: Model = .{};
    var inst: Instance = .{ .gain = 2.0, .m = 3.0 };
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.5 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 3.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -3.0), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
}

test "cccs: default unity gain" {
    // gain=1, m=1 -> I_p = I_ctrl = -0.25 A (sign passes through)
    const model: Model = .{};
    var inst: Instance = .{};
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 0.0, 0.0, -0.25 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -0.25), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
}

test "cccs: output independent of port voltages" {
    // Same I_ctrl, different node voltages -> same residual
    const model: Model = .{};
    var inst: Instance = .{ .gain = 5.0 };
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 12.0, -7.0, 0.1 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.5), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.5), out[1], 1e-12);
}
