const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: GaAs MESFET (Statz/Curtice)
//
// Three-terminal device: Drain, Gate, Source
// - Voltage-controlled drain current (Curtice quadratic model)
// - Two Schottky gate-junction diodes (gate-source, gate-drain)
// - Depletion capacitances Cgs, Cgd
// - Optional series resistances Rd, Rs (noise-only in this model)
// - NMF/PMF polarity control
// ============================================================================

pub const U = enum(u8) { drain, gate, source };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Polarity ---
    nmf: bool = true, // true = N-channel (NMF), false = P-channel (PMF)

    // --- DC Model Parameters ---
    vto: f32 = -2.0, // Pinch-off (threshold) voltage [V]
    alpha: f32 = 2.0, // Saturation voltage parameter [1/V]
    beta: f32 = 2.5e-3, // Transconductance coefficient [A/V^2]
    lambda: f32 = 0.0, // Channel-length modulation [1/V]
    b: f32 = 0.3, // Doping tail extending parameter [1/V]

    // --- Parasitic Resistance ---
    rd: f32 = 0.0, // Drain ohmic resistance [Ohm]
    rs: f32 = 0.0, // Source ohmic resistance [Ohm]

    // --- Junction Capacitance ---
    cgs: f32 = 0.0, // Zero-bias gate-source junction capacitance [F]
    cgd: f32 = 0.0, // Zero-bias gate-drain junction capacitance [F]
    pb: f32 = 1.0, // Gate junction built-in potential [V]
    is: f32 = 1.0e-14, // Gate junction saturation current [A]
    fc: f32 = 0.5, // Forward-bias depletion cap linearization coefficient

    // --- Noise Parameters ---
    kf: f32 = 0.0, // Flicker noise coefficient
    af: f32 = 1.0, // Flicker noise exponent
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    area: f32 = 1.0, // Device area scaling factor
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: Drain -- Source
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .thermal },
    // Source resistance thermal noise: Source -- Drain
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.drain), .kind = .thermal },
    // Drain current shot noise: Drain -- Source
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .shot },
    // Drain current flicker noise: Drain -- Source
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .flicker },
};

// ============================================================================
// Shared f64 constants (x-independent)
// ============================================================================

// Thermal voltage at 300.15 K (~0.025865 V)
const vt: f64 = 8.617333262145e-5 * 300.15;

// GMIN
const gmin: f64 = 1.0e-12;

// Euler's number for cubic reverse-bias formula
const euler: f64 = 2.718281828459045;

// ============================================================================
// DC Current Function (eval)
// ============================================================================

/// Schottky gate-junction diode current (forward exp with cubic deep-reverse
/// extension). x-dependent: computed in S ops. `v` is the junction voltage.
fn junctionCurrent(comptime S: type, v: S, is_val: f64) S {
    // Region select on voltage (original code branched on vj/vt >= -3)
    const v_over_vt = v.scale(1.0 / vt);
    if (v_over_vt.val() >= -3.0) {
        // Forward/mild reverse path: Is * (exp(min(v/vt, 80)) - 1) + gmin*v
        const arg_fwd = v_over_vt.minC(80.0);
        return arg_fwd.exp().addC(-1.0).scale(is_val).add(v.scale(gmin));
    } else {
        // Deep reverse path: arg = (3*VT / (Vj * e))^3
        // I = -Is * (1 + arg) + gmin*Vj
        const deep_ratio = S.con(3.0 * vt).div(v.scale(euler).addC(1.0e-300));
        const deep_arg = deep_ratio.mul(deep_ratio).mul(deep_ratio);
        return deep_arg.addC(1.0).scale(-is_val).add(v.scale(gmin));
    }
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);

    // --- Cast model parameters to f64 (x-independent) ---
    const vto: f64 = @as(f64, model.vto);
    const alpha: f64 = @as(f64, model.alpha);
    const beta_m: f64 = @as(f64, model.beta);
    const lambda: f64 = @as(f64, model.lambda);
    const b_param: f64 = @as(f64, model.b);
    const is_val: f64 = @as(f64, model.is);

    // --- Cast instance parameters to f64 ---
    const area: f64 = @as(f64, instance.area);

    // --- Polarity factor: +1 for NMF, -1 for PMF ---
    const type_f: f64 = if (model.nmf) 1.0 else -1.0;

    // --- Terminal voltages with polarity ---
    const vgs_raw = x[g].sub(x[s]).scale(type_f);
    const vgd_raw = x[g].sub(x[d]).scale(type_f);
    const vds_raw = vgs_raw.sub(vgd_raw);

    // ========================================================================
    // Source-Drain Reversal
    // ========================================================================
    const reversed = vds_raw.val() < 0.0;
    const vgs_eff = if (reversed) vgd_raw else vgs_raw;
    const vds_eff = vds_raw.abs();

    // ========================================================================
    // Gate-Source Junction Diode Current (Schottky with cubic reverse)
    // ========================================================================
    const igs = junctionCurrent(S, vgs_raw, is_val);

    // ========================================================================
    // Gate-Drain Junction Diode Current (Schottky with cubic reverse)
    // ========================================================================
    const igd = junctionCurrent(S, vgd_raw, is_val);

    // ========================================================================
    // Drain Current (Curtice Model)
    // ========================================================================
    // Vgst = Vgs_eff - VTO
    const vgst = vgs_eff.addC(-vto);
    const vgst_pos = vgst.maxC(0.0);

    // Beta' = beta * (1 + lambda * Vds_eff)
    const beta_prime = vds_eff.scale(lambda).addC(1.0).scale(beta_m);

    // Denominator: 1 + B * Vgst+
    const denom = vgst_pos.scale(b_param).addC(1.0);

    // Common quadratic term: beta' * (Vgst+)^2 / denom
    const id_base = beta_prime.mul(vgst_pos.mul(vgst_pos)).div(denom);

    // Saturation threshold: 3/alpha
    // Guard against alpha == 0: if alpha is 0, treat as always saturated
    const sat_threshold: f64 = if (alpha != 0.0) 3.0 / alpha else 0.0;
    const in_saturation = vds_eff.val() >= sat_threshold;

    // Saturation region: Id_sat = beta' * (Vgst+)^2 / denom
    // Linear region: a_fact = 1 - alpha * Vds_eff / 3
    //                l_fact = 1 - a_fact^3
    //                Id_lin = id_base * l_fact
    const id_raw = if (in_saturation) id_base else blk: {
        const a_fact = vds_eff.scale(-alpha / 3.0).addC(1.0);
        const l_fact = a_fact.mul(a_fact).mul(a_fact).neg().addC(1.0);
        break :blk id_base.mul(l_fact);
    };

    // Reversal correction: negate if Vds_raw < 0
    const id_signed = if (reversed) id_raw.neg() else id_raw;

    // ========================================================================
    // Area Scaling
    // ========================================================================
    const id_scaled = id_signed.scale(area);
    const igs_scaled = igs.scale(area);
    const igd_scaled = igd.scale(area);

    // ========================================================================
    // KCL Terminal Currents
    // ========================================================================
    // I_Drain  = s * (I_d - I_gd)
    // I_Gate   = s * (I_gs + I_gd)
    // I_Source = s * (-I_d - I_gs)
    return .{
        id_scaled.sub(igd_scaled).scale(type_f),
        igs_scaled.add(igd_scaled).scale(type_f),
        id_scaled.neg().sub(igs_scaled).scale(type_f),
    };
}

// ============================================================================
// Charge Function (q) -- Junction Depletion Capacitance
// ============================================================================

/// Junction charge for one gate junction (depletion + forward-bias
/// linearization, grading coefficient m = 0.5). `v` is x-dependent (S);
/// everything else is plain f64 parameter prep.
fn junctionCharge(comptime S: type, v: S, c0: f64, pb: f64, fc: f64) S {
    // --- Fixed grading coefficient m = 0.5, so (1-m) = 0.5 ---
    const one_minus_m: f64 = 0.5;

    // --- FC * PB threshold ---
    const fc_pb = fc * pb;

    // --- Forward-bias extension coefficients ---
    const one_minus_fc = 1.0 - fc;

    if (v.val() < fc_pb) {
        // Depletion region (V < FC * PB):
        //   Q_dep = C0 * PB / (1-m) * [1 - (1 - V/PB)^(1-m)]
        //   With m=0.5: (1-m) = 0.5, so Q_dep = 2*C0*PB*(1 - sqrt(1 - V/PB))
        const x_dep = v.scale(-1.0 / pb).addC(1.0).maxC(1.0e-30);
        return x_dep.sqrt().neg().addC(1.0).scale(c0 * pb / one_minus_m);
    } else {
        // Forward-bias linearization (V >= FC * PB):
        //   Q = C0 * [Q_dep(FC*PB) + (V - FC*PB) / (1-FC)^m]
        //   Q_dep(FC*PB) = PB/(1-m) * [1 - (1-FC)^(1-m)]
        const q_dep_at_fc = (pb / one_minus_m) * (1.0 - @sqrt(one_minus_fc));
        const one_minus_fc_pow_m = @sqrt(one_minus_fc); // (1-FC)^0.5
        return v.addC(-fc_pb).scale(1.0 / one_minus_fc_pow_m).addC(q_dep_at_fc).scale(c0);
    }
}

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);

    // --- Cast model parameters to f64 (x-independent) ---
    const cgs0: f64 = @as(f64, model.cgs);
    const cgd0: f64 = @as(f64, model.cgd);
    const pb: f64 = @as(f64, model.pb);
    const fc: f64 = @as(f64, model.fc);

    // --- Cast instance parameters to f64 ---
    const area: f64 = @as(f64, instance.area);

    // --- Polarity factor ---
    const type_f: f64 = if (model.nmf) 1.0 else -1.0;

    // --- Raw junction voltages (charge uses raw voltages, not reversed) ---
    const vgs = x[g].sub(x[s]).scale(type_f);
    const vgd = x[g].sub(x[d]).scale(type_f);

    // ========================================================================
    // Gate-Source Junction Charge
    // ========================================================================
    const q_gs = junctionCharge(S, vgs, cgs0, pb, fc).scale(area);

    // ========================================================================
    // Gate-Drain Junction Charge
    // ========================================================================
    const q_gd = junctionCharge(S, vgd, cgd0, pb, fc).scale(area);

    // ========================================================================
    // Charge KCL Contributions
    // ========================================================================
    // Q_Drain  = -Q_gd
    // Q_Gate   =  Q_gs + Q_gd
    // Q_Source = -Q_gs
    return .{
        q_gd.neg(),
        q_gs.add(q_gd),
        q_gs.neg(),
    };
}

// ============================================================================
// Voltage Limiting (pnjlim on gate junctions)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);

    const is_val: f64 = @as(f64, model.is);
    const type_f: f64 = if (model.nmf) 1.0 else -1.0;

    // Critical voltage: Vcrit = VT * ln(VT / (sqrt(2) * IS))
    // (thermal voltage at 300.15 K, no emission coefficient for MESFET)
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // ========================================================================
    // PN Junction Limiting on V_GS (gate -- source)
    // ========================================================================
    {
        const vgs_new = (x_new[g] - x_new[s]) * type_f;
        const vgs_old = (x_old[g] - x_old[s]) * type_f;

        var vgs_limited = vgs_new;
        if (vgs_new > v_crit and @abs(vgs_new - vgs_old) > 2.0 * vt) {
            if (vgs_old > 0.0) {
                const arg = 1.0 + (vgs_new - vgs_old) / vt;
                if (arg > 0.0) {
                    // Case 1: arg > 0 => logarithmic damping
                    vgs_limited = vgs_old + vt * (2.0 + contract.fmath.log(arg));
                } else {
                    // Case 2: arg <= 0
                    vgs_limited = v_crit;
                }
            } else {
                // Case 3: V_old <= 0
                vgs_limited = vt * contract.fmath.log(vgs_new / vt);
            }
        }

        // Adjust gate node in physical voltage space
        const delta_gs = (vgs_limited - vgs_new) * type_f;
        result[g] += delta_gs;
    }

    // ========================================================================
    // PN Junction Limiting on V_GD (gate -- drain)
    // ========================================================================
    {
        // Recompute with updated gate voltage
        const vgd_new = (result[g] - x_new[d]) * type_f;
        const vgd_old = (x_old[g] - x_old[d]) * type_f;

        var vgd_limited = vgd_new;
        if (vgd_new > v_crit and @abs(vgd_new - vgd_old) > 2.0 * vt) {
            if (vgd_old > 0.0) {
                const arg = 1.0 + (vgd_new - vgd_old) / vt;
                if (arg > 0.0) {
                    vgd_limited = vgd_old + vt * (2.0 + contract.fmath.log(arg));
                } else {
                    vgd_limited = v_crit;
                }
            } else {
                vgd_limited = vt * contract.fmath.log(vgd_new / vt);
            }
        }

        // Adjust drain node in physical voltage space
        const delta_gd = (vgd_limited - vgd_new) * type_f;
        result[d] -= delta_gd;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid -- Gmin Stepping)
// ============================================================================
// IS(lambda) = IS + (1e-12 - IS) * (1 - lambda)
// At lambda=0: IS = 1e-12 (easy convergence)
// At lambda=1: IS = model.is (original)

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const is_orig: f64 = @as(f64, model.is);
    const is_stepped = is_orig + (1.0e-12 - is_orig) * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "mesfet: saturation region drain current (Vgs=0, Vds=2)" {
    // Defaults: vto=-2, alpha=2, beta=2.5e-3, lambda=0, b=0.3, is=1e-14
    // x = { Vd=2, Vg=0, Vs=0 }, NMF (type_f = +1):
    //   Vgs = 0, Vgd = -2, Vds = 2 >= 0 (not reversed)
    //   Vgst = 0 - (-2) = 2, denom = 1 + 0.3*2 = 1.6
    //   beta' = 2.5e-3 * (1 + 0) = 2.5e-3
    //   id_base = 2.5e-3 * 2^2 / 1.6 = 0.00625
    //   sat_threshold = 3/2 = 1.5; Vds=2 >= 1.5 -> saturation: Id = 0.00625
    //   Igs: Vgs/vt = 0 >= -3 -> Is*(exp(0)-1) + gmin*0 = 0
    //   Igd: Vgd/vt = -2/0.02586... = -77.3 < -3 -> deep reverse:
    //     ratio = 3*vt/(-2*e) = 0.0775947774/(-5.4365636569) = -0.0142728...
    //     arg = ratio^3 = -2.9078e-6
    //     Igd = -1e-14*(1 - 2.9078e-6) + 1e-12*(-2) = -2.01e-12 (to ~3e-20)
    //   out[d] = Id - Igd = 0.00625 + 2.01e-12
    //   out[g] = Igs + Igd = -2.01e-12
    //   out[s] = -Id - Igs = -0.00625
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 2.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.00625), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2.01e-12), out[1], 1e-16);
    try testing.expectApproxEqAbs(@as(f64, -0.00625), out[2], 1e-9);
}

test "mesfet: linear region drain current (Vgs=0, Vds=1)" {
    // x = { Vd=1, Vg=0, Vs=0 }:
    //   Vgst = 2, id_base = 2.5e-3*4/1.6 = 0.00625 (lambda = 0)
    //   Vds = 1 < sat_threshold 1.5 -> linear:
    //     a_fact = 1 - 2*1/3 = 1/3
    //     l_fact = 1 - (1/3)^3 = 26/27
    //     Id = 0.00625 * 26/27 = 0.0060185185185185185...
    //   Igd (Vgd=-1, deep reverse) ~ -1.01e-12, negligible at 1e-9
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.00625 * 26.0 / 27.0), out[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -0.00625 * 26.0 / 27.0), out[2], 1e-9);
}

test "mesfet: forward-biased gate-source junction (Vgs=0.5, Vds=0)" {
    // x = { Vd=0, Vg=0.5, Vs=0 }:
    //   Vgs = 0.5, Vgd = 0.5, Vds = 0 (not reversed)
    //   Drain current: a_fact = 1 -> l_fact = 0 -> Id = 0
    //   Both junctions forward: Ij = Is*(exp(0.5/vt) - 1) + gmin*0.5
    //   (expected computed with the OLD formula, using the f32-rounded Is)
    const model: Model = .{};
    const inst: Instance = .{};
    const is_val: f64 = @as(f64, model.is);
    const ij = is_val * (contract.fmath.exp(0.5 / vt) - 1.0) + 1.0e-12 * 0.5;
    const out = contract.evalValues(Self, .{ 0.0, 0.5, 0.0 }, &model, &inst, 0);
    // out[d] = Id - Igd = -ij ; out[g] = Igs + Igd = 2*ij ; out[s] = -Id - Igs = -ij
    try testing.expectApproxEqAbs(-ij, out[0], 1e-18);
    try testing.expectApproxEqAbs(2.0 * ij, out[1], 1e-18);
    try testing.expectApproxEqAbs(-ij, out[2], 1e-18);
}

test "mesfet: source-drain reversal negates drain current" {
    // x = { Vd=-2, Vg=0, Vs=0 }: Vgs = 0, Vgd = 0-(-2) = 2, Vds = -2 < 0
    // -> reversed: Vgs_eff = Vgd = 2, Vds_eff = |Vds| = 2 >= 1.5 -> saturation
    //   Vgst = 2 - (-2) = 4, denom = 1 + 0.3*4 = 2.2
    //   id_base = 2.5e-3 * 16 / 2.2 = 0.0181818...; Id (signed) = -0.0181818...
    //   Igd is a large forward diode current (Vgd = 2), so out[d]/out[g] are
    //   exp-dominated; check out[s] = -Id - Igs where Igs(Vgs=0) = 0:
    //     out[s] = +0.0181818...
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -2.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0025 * 16.0 / 2.2), out[2], 1e-9);
}

test "mesfet: depletion junction charge" {
    // cgs=1e-12, cgd=2e-13, pb=1, fc=0.5, area=1
    // x = { Vd=2, Vg=0.3, Vs=0 }: Vgs = 0.3, Vgd = -1.7; fc*pb = 0.5
    // Both junctions in depletion (V < 0.5):
    //   Q_gs = 2*cgs*pb*(1 - sqrt(1 - 0.3)) = 2e-12*(1 - 0.8366600265340756)
    //        = 3.266799469318488e-13
    //   Q_gd = 2*cgd*pb*(1 - sqrt(1 + 1.7)) = 4e-13*(1 - 1.6431676725154984)
    //        = -2.5726706900619936e-13
    //   out[d] = -Q_gd =  2.5726706900619936e-13
    //   out[g] = Q_gs + Q_gd = 6.941287792564944e-14
    //   out[s] = -Q_gs = -3.266799469318488e-13
    const model: Model = .{ .cgs = 1e-12, .cgd = 2e-13 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 2.0, 0.3, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 2.5726706900619936e-13), out[0], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 6.941287792564944e-14), out[1], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -3.266799469318488e-13), out[2], 1e-18);
}

test "mesfet: forward-bias linearized junction charge" {
    // cgs=1e-12, pb=1, fc=0.5; x = { Vd=0.8, Vg=0.8, Vs=0 }:
    //   Vgs = 0.8 >= fc*pb = 0.5 -> forward-bias extension:
    //     Q_dep(fc*pb) = (1/0.5)*(1 - sqrt(0.5)) = 2*(1 - 0.7071067811865476)
    //                  = 0.5857864376269049
    //     Q_gs = cgs*(0.5857864376269049 + (0.8-0.5)/sqrt(0.5))
    //          = 1e-12*(0.5857864376269049 + 0.4242640687119285)
    //          = 1.0100505063388334e-12
    //   Vgd = 0.8 - 0.8 = 0 < 0.5 -> depletion with cgd=0 -> Q_gd = 0
    //   out[s] = -Q_gs = -1.0100505063388334e-12
    const model: Model = .{ .cgs = 1e-12 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.8, 0.8, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30);
    try testing.expectApproxEqAbs(@as(f64, 1.0100505063388334e-12), out[1], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -1.0100505063388334e-12), out[2], 1e-18);
}
