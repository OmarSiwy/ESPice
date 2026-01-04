const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminals
// ============================================================================

pub const U = enum(u8) { p, n };
pub const mc_param = "cap";
pub const num_ports: usize = 2;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    /// Flat model capacitance (F)
    cap: f32 = 0.0,
    /// Junction (area) capacitance per unit area (F/m^2)
    cj: f32 = 0.0,
    /// Sidewall capacitance per unit perimeter (F/m)
    cjsw: f32 = 0.0,
    /// Default instance width (m)
    defw: f32 = 1e-5,
    /// Default instance length (m)
    defl: f32 = 0.0,
    /// Narrowing due to side etching -- width (m)
    narrow: f32 = 0.0,
    /// Shortening due to side etching -- length (m)
    short: f32 = 0.0,
    /// Isotropic etch delta (m); sets narrow and short if not given
    del: f32 = 0.0,
    /// First-order temperature coefficient (1/K)
    tc1: f32 = 0.0,
    /// Second-order temperature coefficient (1/K^2)
    tc2: f32 = 0.0,
    /// Nominal (parameter measurement) temperature (degC)
    tnom: f32 = 27.0,
    /// Relative dielectric constant
    di: f32 = 0.0,
    /// Dielectric thickness (m)
    thick: f32 = 0.0,
    /// Maximum breakdown voltage (V) -- reserved, not used in eval
    bv_max: f32 = 1e99,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    /// Instance capacitance -- overrides model/geometry (F)
    cap: f32 = 0.0,
    /// Initial condition voltage (V)
    ic: f32 = 0.0,
    /// Instance temperature (degC); overrides circuit temp
    temp: f32 = 0.0,
    /// Temperature offset from circuit temperature (K)
    dtemp: f32 = 0.0,
    /// Instance width (m)
    w: f32 = 0.0,
    /// Instance length (m)
    l: f32 = 0.0,
    /// Multiplicity (number of parallel devices)
    m: f32 = 1.0,
    /// Instance first-order temperature coefficient (1/K); overrides model
    tc1: f32 = 0.0,
    /// Instance second-order temperature coefficient (1/K^2); overrides model
    tc2: f32 = 0.0,
    /// Instance scale factor
    scale: f32 = 1.0,
    cached_c: f32 = std.math.inf(f32),
};

// ============================================================================
// Sparse stamp patterns
// ============================================================================

/// The capacitor contributes no resistive current so the conductance stamp
/// is structurally empty.  However the solver still needs at least the
/// diagonal for the MNA formulation, so we declare the standard 2x2 pattern.

// ============================================================================
// Constants
// ============================================================================

/// Vacuum permittivity (F/m)
const eps0: f64 = 8.854187817e-12;

// ============================================================================
// Effective capacitance (pure f64 -- no x dependence)
// ============================================================================

/// Final capacitance from model + instance params: geometry/dielectric
/// selection, etch deltas, instance override, scale, temperature and
/// multiplicity. Pure f64 -- no x.
fn effectiveC(model: *const Model, instance: *const Instance) f64 {
    // ------------------------------------------------------------------
    // Cast model fields to f64
    // ------------------------------------------------------------------
    const m_cap: f64 = @as(f64, model.cap);
    const m_cj: f64 = @as(f64, model.cj);
    const m_cjsw: f64 = @as(f64, model.cjsw);
    const m_defw: f64 = @as(f64, model.defw);
    const m_defl: f64 = @as(f64, model.defl);
    const m_narrow: f64 = @as(f64, model.narrow);
    const m_short: f64 = @as(f64, model.short);
    const m_del: f64 = @as(f64, model.del);
    const m_tc1: f64 = @as(f64, model.tc1);
    const m_tc2: f64 = @as(f64, model.tc2);
    const m_tnom: f64 = @as(f64, model.tnom);
    const m_di: f64 = @as(f64, model.di);
    const m_thick: f64 = @as(f64, model.thick);

    // Cast instance fields to f64
    const i_cap: f64 = @as(f64, instance.cap);
    const i_temp: f64 = @as(f64, instance.temp);
    const i_dtemp: f64 = @as(f64, instance.dtemp);
    const i_w: f64 = @as(f64, instance.w);
    const i_l: f64 = @as(f64, instance.l);
    const i_m: f64 = @as(f64, instance.m);
    const i_tc1: f64 = @as(f64, instance.tc1);
    const i_tc2: f64 = @as(f64, instance.tc2);
    const i_scale: f64 = @as(f64, instance.scale);

    // ------------------------------------------------------------------
    // Dielectric-based junction capacitance override
    // When both di > 0 and thick > 0, compute Cj from dielectric params
    // ------------------------------------------------------------------
    const di_valid = m_di > 0.0 and m_thick > 0.0;
    const cj_diel = eps0 * m_di / (m_thick + 1e-30);
    const cj_eff: f64 = if (di_valid) cj_diel else m_cj;

    // ------------------------------------------------------------------
    // Etch delta propagation
    // narrow and short override del; if narrow==0, use 2*del
    // ------------------------------------------------------------------
    const delta_w: f64 = if (m_narrow != 0.0) m_narrow else 2.0 * m_del;
    const delta_l: f64 = if (m_short != 0.0) m_short else 2.0 * m_del;

    // ------------------------------------------------------------------
    // Base capacitance selection (priority order)
    // ------------------------------------------------------------------

    // Priority 2: Geometry-based (cj_eff > 0)
    const w_inst: f64 = if (i_w > 0.0) i_w else m_defw;
    const l_inst: f64 = if (i_l > 0.0) i_l else m_defl;
    const w_eff = w_inst - delta_w;
    const l_eff = l_inst - delta_l;
    const c_geom_raw = cj_eff * w_eff * l_eff + m_cjsw * 2.0 * (w_eff + l_eff);
    const c_geom = @max(c_geom_raw, 0.0);

    // Priority 3: Flat model capacitance
    const c_flat = m_cap;

    // Select: instance cap > geometry > flat model
    const geom_valid = cj_eff > 0.0;
    const c_base_geo_or_flat: f64 = if (geom_valid) c_geom else c_flat;
    const c_base: f64 = if (i_cap != 0.0) i_cap else c_base_geo_or_flat;

    // ------------------------------------------------------------------
    // Instance scale
    // ------------------------------------------------------------------
    const c_scaled = c_base * i_scale;

    // ------------------------------------------------------------------
    // Temperature scaling
    // ------------------------------------------------------------------
    // T_op: use instance temp if given, otherwise 27 + dtemp
    const t_op: f64 = if (i_temp != 0.0) i_temp else (27.0 + i_dtemp);
    const delta_t = t_op - m_tnom;

    // TC selection: instance overrides model
    const tc1_sel: f64 = if (i_tc1 != 0.0) i_tc1 else m_tc1;
    const tc2_sel: f64 = if (i_tc2 != 0.0) i_tc2 else m_tc2;

    const f_temp = 1.0 + tc1_sel * delta_t + tc2_sel * delta_t * delta_t;
    const c_eff = c_scaled * f_temp;

    // ------------------------------------------------------------------
    // Multiplicity
    // ------------------------------------------------------------------
    return c_eff * i_m;
}

pub fn precompute(instance: *Instance, model: *const Model) void {
    instance.cached_c = @floatCast(effectiveC(model, instance));
}

// ============================================================================
// PrepCache: hot eval data in contiguous array (SoA over devices)
// ============================================================================

pub const PrepCache = struct { c: f64 };

pub fn computePrep(_: *const Model, instance: *const Instance) PrepCache {
    return .{ .c = @as(f64, instance.cached_c) };
}

// ============================================================================
// Constant-Jacobian flag: G and C stamps are independent of x.
// The framework stamps them once at finalize and skips them during Newton.
// ============================================================================

pub const constant_g = true;
pub const constant_c = true;

// ============================================================================
// Current function: no resistive (DC) current contribution
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = x;
    _ = model;
    _ = instance;
    _ = t;
    return .{ S.con(0.0), S.con(0.0) };
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, _: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = x;
    return .{ S.con(0.0), S.con(0.0) };
}

// ============================================================================
// Charge function: q(v) = C_final * v
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    _ = model;
    const c_final: f64 = @as(f64, instance.cached_c);
    const v = x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]);
    const q_val = v.scale(c_final);
    return .{ q_val, q_val.neg() };
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    const v = x[@intFromEnum(U.p)].sub(x[@intFromEnum(U.n)]);
    const q_val = v.scale(pc.c);
    return .{ q_val, q_val.neg() };
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

test "capacitor: no resistive current" {
    const model: Model = .{};
    const inst: Instance = .{ .cap = 1e-6 };
    const out = contract.evalValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-18);
}

test "capacitor: flat instance cap charge" {
    // q = C*v = 1e-6 * 1.0 = 1e-6 C on p, -1e-6 C on n
    // (tolerance accounts for f32 param storage)
    const model: Model = .{};
    var inst: Instance = .{ .cap = 1e-6 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1e-6), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -1e-6), out[1], 1e-12);
}

test "capacitor: geometry-derived capacitance" {
    // cj = 1e-3 F/m^2, w = l = 1e-4 m, cjsw = 0
    // C = cj*w*l = 1e-3 * 1e-4 * 1e-4 = 1e-11 F
    // v = 2 -> q = 2e-11 C
    const model: Model = .{ .cj = 1e-3 };
    var inst: Instance = .{ .w = 1e-4, .l = 1e-4 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 2e-11), out[0], 1e-16);
    try testing.expectApproxEqAbs(@as(f64, -2e-11), out[1], 1e-16);
}

test "capacitor: sidewall capacitance contribution" {
    // cjsw = 1e-9 F/m, cj = 1e-3 F/m^2, w = l = 1e-4 m
    // C = 1e-3*1e-8 + 1e-9*2*(2e-4) = 1e-11 + 4e-13 = 1.04e-11 F
    // v = 1 -> q = 1.04e-11 C
    const model: Model = .{ .cj = 1e-3, .cjsw = 1e-9 };
    var inst: Instance = .{ .w = 1e-4, .l = 1e-4 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.04e-11), out[0], 1e-16);
}

test "capacitor: temperature coefficient" {
    // tc1 = 0.001, tnom = 27, temp = 127 -> delta_t = 100
    // f_temp = 1 + 0.001*100 = 1.1 -> C = 1.1e-6 -> q = 1.1e-6 at 1V
    // (tolerance accounts for f32 param storage)
    const model: Model = .{ .tc1 = 0.001, .tnom = 27 };
    var inst: Instance = .{ .cap = 1e-6, .temp = 127 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.1e-6), out[0], 1e-12);
}

test "capacitor: multiplicity m" {
    // m = 3, C = 1e-6 -> q = 3e-6 at 1V
    // (tolerance accounts for f32 param storage)
    const model: Model = .{};
    var inst: Instance = .{ .cap = 1e-6, .m = 3 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 3e-6), out[0], 1e-12);
}

test "capacitor: dielectric override" {
    // di = 3.9, thick = 1e-8 -> cj = eps0*3.9/(1e-8 + 1e-30)
    //   = 8.854187817e-12 * 3.9 / 1e-8 = 3.4531332486e-3 F/m^2
    // w = l = 1e-5 -> C = 3.4531332486e-3 * 1e-10 = 3.4531332486e-13 F
    // v = 1 -> q = 3.4531332486e-13 C (f32 param storage tolerance)
    const model: Model = .{ .di = 3.9, .thick = 1e-8, .cj = 999.0 };
    var inst: Instance = .{ .w = 1e-5, .l = 1e-5 };
    precompute(&inst, &model);
    const out = contract.qValues(Self, .{ 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 3.4531332486e-13), out[0], 1e-19);
}
