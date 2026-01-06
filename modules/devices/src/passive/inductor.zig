const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: two external ports + one branch-current unknown
// ============================================================================

pub const U = enum(u8) { p, n, br };
pub const mc_param = "inductance";
pub const num_ports: usize = 2;

pub const u_kinds = [n_u]contract.UnknownKind{ .voltage, .voltage, .current };

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    ind: f32 = 0, // Model inductance (H)
    tc1: f32 = 0, // First-order temperature coefficient (1/K)
    tc2: f32 = 0, // Second-order temperature coefficient (1/K^2)
    tnom: f32 = 27, // Parameter measurement temperature (degC)
    csect: f32 = 0, // Cross-section area (m^2)
    length: f32 = 0, // Mean magnetic path length (m)
    nt: f32 = 0, // Model number of turns
    mu: f32 = 0, // Relative magnetic permeability (0 treated as 1)
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    inductance: f32 = 0, // Instance inductance override (H), 0 = use model
    ic: f64 = 0, // Initial current through inductor (A)
    m: f32 = 1.0, // Parallel multiplier
    temp: f32 = 27.0, // Instance operating temperature (degC)
    dtemp: f32 = 0, // Temperature offset from circuit temperature (K)
    tc1: f32 = 0, // Instance first-order temp coefficient (1/K)
    tc2: f32 = 0, // Instance second-order temp coefficient (1/K^2)
    scale: f32 = 1.0, // Scale factor applied to inductance
    nt: f32 = 0, // Number of turns (overrides model)
    temp_given: bool = false, // Flag: instance temp was explicitly set
    tc1_given: bool = false, // Flag: instance tc1 was explicitly set
    tc2_given: bool = false, // Flag: instance tc2 was explicitly set
    cached_l: f32 = std.math.inf(f32),
};

// ============================================================================
// Constants
// ============================================================================

const MU_0: f64 = 1.2566370614359e-6; // Permeability of free space (H/m)

// ============================================================================
// Sparse stamp patterns
// ============================================================================

// The eval function stamps:
//   out[p]  += +I_br         => depends on br          => (p, br)
//   out[n]  += -I_br         => depends on br          => (n, br)
//   out[br] = V_p - V_n      => depends on p and n     => (br, p), (br, n)

// The q function stamps:
//   q[br] = L_final * I_br   => depends on br          => (br, br)

// ============================================================================
// Effective inductance (pure f64 parameter prep — no x dependence)
// ============================================================================

fn effectiveL(model: *const Model, instance: *const Instance) f64 {
    // --- Operating temperature ---
    // T = T_inst + 273.15 if temp_given, else 300.15 + dtemp
    const t_inst: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const temp_k: f64 = if (instance.temp_given) t_inst + 273.15 else 300.15 + dtemp;

    const tnom_k: f64 = @as(f64, model.tnom) + 273.15;
    const dt_coeff: f64 = temp_k - tnom_k;

    // --- Base inductance selection (three-way priority) ---
    const l_inst: f64 = @as(f64, instance.inductance);
    const l_model: f64 = @as(f64, model.ind);
    const csect: f64 = @as(f64, model.csect);
    const length: f64 = @as(f64, model.length);
    const nt_inst: f64 = @as(f64, instance.nt);
    const nt_model: f64 = @as(f64, model.nt);
    const mu_r: f64 = @as(f64, model.mu);

    // Number of turns: instance overrides model
    const n_turns: f64 = if (nt_inst > 0) nt_inst else nt_model;

    // Effective permeability: mu_0 * (mu_r if mu_r > 0, else 1)
    const mu_eff: f64 = MU_0 * (if (mu_r > 0) mu_r else 1.0);

    // Geometry-based inductance: mu_eff * csect * N^2 / length
    const l_geom: f64 = mu_eff * csect * n_turns * n_turns / (length + 1e-30);

    // Use geometry if both csect > 0 and length > 0
    const use_geom = csect > 0 and length > 0;
    const l_from_geom: f64 = if (use_geom) l_geom else l_model;

    // Instance inductance overrides everything when non-zero
    const l_base: f64 = if (l_inst != 0) l_inst else l_from_geom;

    // --- Scale factor ---
    const scale: f64 = @as(f64, instance.scale);
    const l_scaled: f64 = l_base * scale;

    // --- Temperature coefficient ---
    const tc1_model: f64 = @as(f64, model.tc1);
    const tc2_model: f64 = @as(f64, model.tc2);
    const tc1_inst: f64 = @as(f64, instance.tc1);
    const tc2_inst: f64 = @as(f64, instance.tc2);

    const tc1_eff: f64 = if (instance.tc1_given) tc1_inst else tc1_model;
    const tc2_eff: f64 = if (instance.tc2_given) tc2_inst else tc2_model;

    const f_t: f64 = 1.0 + tc1_eff * dt_coeff + tc2_eff * dt_coeff * dt_coeff;

    // --- Effective inductance ---
    const l_eff: f64 = l_scaled * f_t;

    // --- Parallel multiplicity ---
    const m: f64 = @as(f64, instance.m);
    return l_eff / m;
}

pub fn precompute(instance: *Instance, model: *const Model) void {
    instance.cached_l = @floatCast(effectiveL(model, instance));
}

// ============================================================================
// PrepCache: hot eval data in contiguous array (SoA over devices)
// ============================================================================

pub const PrepCache = struct { l: f64 };

pub fn computePrep(_: *const Model, instance: *const Instance) PrepCache {
    return .{ .l = @as(f64, instance.cached_l) };
}

// ============================================================================
// Constant-Jacobian flags: G and C stamps are independent of x.
// ============================================================================

pub const constant_g = true;
pub const constant_c = true;

// ============================================================================
// KCL / KVL contributions (resistive stamp)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const p = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const br = @intFromEnum(U.br);

    const i_br = x[br];

    var out: [n_u]S = undefined;
    out[p] = i_br;
    out[n_] = i_br.neg();
    out[br] = x[p].sub(x[n_]);
    return out;
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, _: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const br = @intFromEnum(U.br);

    const i_br = x[br];

    var out: [n_u]S = undefined;
    out[p] = i_br;
    out[n_] = i_br.neg();
    out[br] = x[p].sub(x[n_]);
    return out;
}

// ============================================================================
// Flux / Charge contributions
// ============================================================================

// The solver forms F = eval + dq/dt, so the branch KVL row
//   V(p) − V(n) − L·dI/dt = 0   (ngspice INDload companion)
// requires q_br = −L·I_br. A positive flux here flips the inductor into an
// anti-damped negative inductance (unstable RL poles, conjugate AC phase).
pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    _ = model;
    const l_final: f64 = @as(f64, instance.cached_l);

    const p = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const br = @intFromEnum(U.br);

    var out: [n_u]S = undefined;
    out[p] = S.con(0.0);
    out[n_] = S.con(0.0);
    out[br] = x[br].scale(-l_final);
    return out;
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p = @intFromEnum(U.p);
    const n_ = @intFromEnum(U.n);
    const br = @intFromEnum(U.br);

    var out: [n_u]S = undefined;
    out[p] = S.con(0.0);
    out[n_] = S.con(0.0);
    out[br] = x[br].scale(-pc.l);
    return out;
}

// ============================================================================
// Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "inductor: residual (KCL/KVL stamp)" {
    // x = { V_p = 2.0, V_n = 0.5, I_br = 1e-3 }
    // out[p] = I_br = 1e-3, out[n] = -1e-3, out[br] = V_p - V_n = 1.5
    const model: Model = .{};
    const inst: Instance = .{ .inductance = 1e-3 };
    const out = contract.evalValues(Self, .{ 2.0, 0.5, 1e-3 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-3), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1e-3), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.5), out[2], 1e-12);
}

test "inductor: flux from instance inductance" {
    // L = 1e-3 H, I_br = 2 A, defaults: temp_given=false -> T = 300.15 K,
    // tnom = 27 degC -> 300.15 K, dt = 0 -> f_t = 1; scale = 1, m = 1
    // q_br = -L * I = -1e-3 * 2 = -2e-3 Wb
    // (1e-9 tolerance: f32 storage of inductance)
    const model: Model = .{};
    var inst: Instance = .{ .inductance = 1e-3 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 0.0, 0.0, 2.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[2], 1e-9);
}

test "inductor: geometry-derived inductance" {
    // csect = 1e-4 m^2, length = 0.1 m, nt = 100 turns, mu = 0 -> mu_eff = MU_0
    // L = MU_0 * 1e-4 * 100^2 / (0.1 + 1e-30)
    //   = 1.2566370614359e-6 * 1e-4 * 1e4 / 0.1 = 1.2566370614359e-5 H
    // I_br = 1 A -> q_br = -1.2566370614359e-5 Wb
    // (1e-9 tolerance: f32 storage of csect/length/nt)
    const model: Model = .{ .csect = 1e-4, .length = 0.1, .nt = 100 };
    var inst: Instance = .{};
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 0.0, 0.0, 1.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -1.2566370614359e-5), out[2], 1e-9);
}

test "inductor: temperature coefficient and parallel multiplier" {
    // L = 1e-3 H, model tc1 = 0.01, tnom = 27 degC, instance temp = 127 degC
    // (temp_given) -> dt = (127+273.15) - (27+273.15) = 100 K
    // f_t = 1 + 0.01*100 = 2; m = 4 -> L_final = 1e-3 * 2 / 4 = 5e-4 H
    // I_br = 1 A -> q_br = -5e-4 Wb
    // (1e-9 tolerance: f32 param storage)
    const model: Model = .{ .tc1 = 0.01, .tnom = 27 };
    var inst: Instance = .{ .inductance = 1e-3, .temp = 127, .temp_given = true, .m = 4 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 0.0, 0.0, 1.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -5e-4), out[2], 1e-9);
}
