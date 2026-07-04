// Coupled Inductors (K Element)
//
// Mutual inductance coupling element linking two inductor branch currents via
// coupling coefficient k. The K element has no external port voltages; its two
// unknowns (ibr1, ibr2) are the branch currents of the coupled inductors.
//
// DC contribution: zero (purely reactive).
// Mutual flux (q function): q_ibr1 = k * I_br2, q_ibr2 = k * I_br1.
// The solver time-differentiates these to produce k * dI_br2/dt and
// k * dI_br1/dt voltage terms in each inductor's KVL equation.
//
// The raw coupling coefficient k is stored here. Resolution to physical mutual
// inductance M = k * sqrt(L1 * L2) occurs at a higher level in the simulator.

const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

/// Unknowns: branch currents of the two coupled inductors.
/// Both are current-type unknowns (not voltages).
pub const U = enum(u8) { ibr1, ibr2 };
pub const num_ports: usize = 2;

/// Both unknowns are branch currents, not voltages.
pub const u_kinds = [n_u]contract.UnknownKind{ .current, .current };

/// Model parameters.
pub const Model = struct {
    /// Mutual inductance coupling coefficient. Range: (-1, 1).
    k: f32 = 0.00099,
};

/// Instance parameters. The K element has no instance parameters.
pub const Instance = struct {};

/// DC current contribution.
///
/// The K element contributes zero resistive (DC) current. All coupling is
/// purely through mutual flux in the charge function q.
pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = x;
    _ = model;
    _ = instance;
    _ = t;

    return .{ S.con(0.0), S.con(0.0) };
}

/// Mutual flux contribution (charge function).
///
/// q_ibr1 = k * I_br2   (cross-coupling: inductor 1's flux from inductor 2's current)
/// q_ibr2 = k * I_br1   (cross-coupling: inductor 2's flux from inductor 1's current)
///
/// The solver time-differentiates these to produce k * dI_br2/dt and
/// k * dI_br1/dt mutual voltage terms.
pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = instance;
    _ = t;

    const k: f64 = @as(f64, model.k);

    const i_br1 = x[@intFromEnum(U.ibr1)];
    const i_br2 = x[@intFromEnum(U.ibr2)];

    // Cross-coupling flux: each inductor's charge contribution is proportional
    // to the OTHER inductor's branch current.
    return .{ i_br2.scale(k), i_br1.scale(k) };
}

/// Sparse conductance stamp pattern.
/// The eval function returns all zeros -- no conductance entries needed.
pub const g_pattern_override = [0]contract.Entry(n_u){};

/// Sparse capacitance stamp pattern.
/// The q function has only off-diagonal coupling: q_ibr1 depends on ibr2,
/// q_ibr2 depends on ibr1.
pub const c_pattern_override = [_]contract.Entry(n_u){
    .{ .row = @intFromEnum(U.ibr1), .col = @intFromEnum(U.ibr2) },
    .{ .row = @intFromEnum(U.ibr2), .col = @intFromEnum(U.ibr1) },
};

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "kinduc: DC residual is zero" {
    const model: Model = .{ .k = 0.5 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 2.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-15);
}

test "kinduc: mutual flux cross-coupling" {
    // Old formula: q_ibr1 = k * i_br2, q_ibr2 = k * i_br1.
    // k = 0.5, i_br1 = 2 A, i_br2 = 3 A:
    //   q_ibr1 = 0.5 * 3 = 1.5
    //   q_ibr2 = 0.5 * 2 = 1.0
    const model: Model = .{ .k = 0.5 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 2.0, 3.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.5), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[1], 1e-12);
}

test "kinduc: default coupling coefficient" {
    // Default k = 0.00099 (stored as f32). i_br1 = 1, i_br2 = -1:
    //   q_ibr1 = 0.00099 * -1 = -0.00099
    //   q_ibr2 = 0.00099 *  1 =  0.00099
    // (tolerance accounts for f32 param storage)
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, -1.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -0.00099), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.00099), out[1], 1e-9);
}
