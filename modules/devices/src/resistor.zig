const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology
// ============================================================================

pub const U = enum(u8) { p, n };
pub const mc_param = "resist";
pub const num_ports: usize = 2;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    /// Default resistance value (Ohm)
    r: f32 = 0,
    /// Sheet resistance (Ohm/square)
    rsh: f32 = 0,
    /// Narrowing due to side etching (m)
    narrow: f32 = 0,
    /// Shortening due to side etching (m)
    short: f32 = 0,
    /// Default width (m)
    defw: f32 = 10e-6,
    /// Default length (m)
    defl: f32 = 10e-6,
    /// First-order temperature coefficient (1/degC)
    tc1: f32 = 0,
    /// Second-order temperature coefficient (1/degC^2)
    tc2: f32 = 0,
    /// Parameter measurement temperature (degC)
    tnom: f32 = 27,
    /// Flicker noise coefficient
    kf: f32 = 0,
    /// Flicker noise exponent
    af: f32 = 1.0,
    /// Maximum breakdown voltage (V)
    bv_max: f32 = 1e99,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    /// Instance resistance value (Ohm). 0 means "not set".
    resist: f32 = 0,
    /// Resistor width (m). 0 means "use model default".
    w: f32 = 0,
    /// Resistor length (m). 0 means "use model default".
    l: f32 = 0,
    /// Instance temperature (degC). Sentinel -1e99 means "not set".
    temp: f32 = -1e99,
    /// Temperature offset from circuit temperature (degC)
    dtemp: f32 = 0,
    /// Parallel multiplier
    m: f32 = 1.0,
    /// Instance scale factor
    scale: f32 = 1.0,
    /// Instance first-order temp coefficient. Sentinel -1e99 means "not set".
    tc1: f32 = -1e99,
    /// Instance second-order temp coefficient. Sentinel -1e99 means "not set".
    tc2: f32 = -1e99,
    /// Instance maximum breakdown voltage. Sentinel -1e99 means "not set".
    bv_max: f32 = -1e99,
    cached_g: f32 = std.math.inf(f32),
};

// ============================================================================
// Sparse conductance stamp pattern
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    .{ .row = 0, .col = 0 },
    .{ .row = 0, .col = 1 },
    .{ .row = 1, .col = 0 },
    .{ .row = 1, .col = 1 },
};

// ============================================================================
// Noise sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    .{ .row = 0, .col = 1, .kind = .thermal },
};

// ============================================================================
// Physics (value-form: generic over scalar S; x-independent param prep
// stays f64, only the x-dependent tail uses S ops)
// ============================================================================

/// Effective conductance from model + instance params. Pure f64 — no x.
fn effectiveG(model: *const Model, instance: *const Instance) f64 {
    const r_model: f64 = @as(f64, model.r);
    const rsh: f64 = @as(f64, model.rsh);
    const narrow: f64 = @as(f64, model.narrow);
    const short: f64 = @as(f64, model.short);
    const defw: f64 = @as(f64, model.defw);
    const defl: f64 = @as(f64, model.defl);
    const tc1_model: f64 = @as(f64, model.tc1);
    const tc2_model: f64 = @as(f64, model.tc2);
    const tnom: f64 = @as(f64, model.tnom);

    const resist: f64 = @as(f64, instance.resist);
    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const m: f64 = @as(f64, instance.m);
    const scale: f64 = @as(f64, instance.scale);
    const tc1_inst: f64 = @as(f64, instance.tc1);
    const tc2_inst: f64 = @as(f64, instance.tc2);

    // -- Operating temperature --
    // Circuit temperature default = 300.15 K (27 degC)
    const t_circuit: f64 = 300.15;
    // If instance temp is set (sentinel is -1e99), use it; otherwise use circuit + dtemp
    const temp_set = inst_temp > -1e98;
    const t_k = if (temp_set) inst_temp + 273.15 else t_circuit + dtemp;
    const t_nom_k = tnom + 273.15;
    const dt_coeff = t_k - t_nom_k;

    // -- Effective geometry --
    const w_used = if (inst_w > 0.0) inst_w else defw;
    const l_used = if (inst_l > 0.0) inst_l else defl;
    const l_eff = l_used - short;
    const w_eff = w_used - narrow;

    // -- Base resistance (priority: instance > geometry > model default) --
    const geom_valid = rsh > 0.0 and l_eff > 0.0 and w_eff > 0.0;
    const r_geom = if (geom_valid) rsh * l_eff / w_eff else r_model;
    const r_base = if (resist > 0.0) resist else r_geom;

    // -- Scale factor --
    const r_base_scaled = r_base * scale;

    // -- Temperature dependence --
    // Instance tc overrides model tc (sentinel -1e99 = not set)
    const tc1_eff = if (tc1_inst > -1e98) tc1_inst else tc1_model;
    const tc2_eff = if (tc2_inst > -1e98) tc2_inst else tc2_model;
    const f_temp = 1.0 + tc1_eff * dt_coeff + tc2_eff * dt_coeff * dt_coeff;

    // -- Effective resistance with temperature --
    const r_eff_raw = r_base_scaled * f_temp;

    // -- Resistance clamping: minimum 1 milliohm --
    const r_eff = @max(r_eff_raw, 1e-3);

    return m / r_eff;
}

pub fn precompute(instance: *Instance, model: *const Model) void {
    instance.cached_g = @floatCast(effectiveG(model, instance));
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

// ============================================================================
// Current function
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    _ = model;
    const g_eff: f64 = @as(f64, instance.cached_g);
    const ir = x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]).scale(g_eff);
    return .{ ir, ir.neg() };
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    const ir = x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]).scale(pc.g);
    return .{ ir, ir.neg() };
}

// ============================================================================
// Contract validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "resistor: 1k ohm, 1V across -> 1mA" {
    const model: Model = .{};
    var inst: Instance = .{ .resist = 1000 };
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-3), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1e-3), out[1], 1e-12);
}

test "resistor: geometry-derived resistance" {
    // rsh=100, l=20u, w=10u -> R = 100 * 20u/10u = 200 ohm
    const model: Model = .{ .rsh = 100, .defw = 10e-6, .defl = 20e-6 };
    var inst: Instance = .{};
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.01), out[0], 1e-12);
}

test "resistor: temperature coefficient" {
    // tc1 raises R with instance temp above tnom
    const model: Model = .{ .tc1 = 0.01, .tnom = 27 };
    var inst: Instance = .{ .resist = 1000, .temp = 127 };
    precompute(&inst, &model);
    // f_temp = 1 + 0.01*100 = 2 -> R = 2000 -> I = 0.5mA at 1V
    // (tolerance accounts for f32 param storage)
    const out = contract.evalValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.5e-3), out[0], 1e-9);
}

test "resistor: parallel multiplier m" {
    const model: Model = .{};
    var inst: Instance = .{ .resist = 1000, .m = 4 };
    precompute(&inst, &model);
    const out = contract.evalValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 4e-3), out[0], 1e-12);
}
