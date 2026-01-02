const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: D -- RD -- d' (internal drain)
//           S -- RS -- s' (internal source)
//           G (gate) connects to d' and s' via gate junction diodes
//           Channel current flows between d' and s' (Shichman-Hodges)
// ============================================================================

pub const U = enum(u8) { drain, gate, source, d_prime, s_prime };
pub const num_ports: usize = 3;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC Model Parameters ---
    vto: f32 = -2.0,
    beta: f32 = 1e-4,
    lambda: f32 = 0,
    b: f32 = 1.0,
    is: f32 = 1e-14,
    n: f32 = 1.0,
    type_: i32 = 1,

    // --- Parasitic Resistance Parameters ---
    rd: f32 = 0,
    rs: f32 = 0,

    // --- Junction Capacitance Parameters ---
    cgs: f32 = 0,
    cgd: f32 = 0,
    pb: f32 = 1.0,
    fc: f32 = 0.5,

    // --- Temperature Parameters ---
    tnom: f32 = 27,
    tcv: f32 = 0,
    vtotc: f32 = 0,
    bex: f32 = 0,
    betatce: f32 = 0,
    xti: f32 = 3.0,
    eg: f32 = 1.11,

    // --- Noise Parameters ---
    kf: f32 = 0,
    af: f32 = 1.0,
    nlev: i32 = 2,
    gdsnoi: f32 = 1.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    area: f32 = 1.0,
    m: f32 = 1.0,
    temp: f32 = 300.15,
    dtemp: f32 = 0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// RD branch: drain -- d_prime
// RS branch: source -- s_prime
// Junction GS: gate -- s_prime
// Junction GD: gate -- d_prime
// Channel: d_prime -- s_prime

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: drain -- d_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.drain) },
    // RS branch: source -- s_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.source) },
    // Gate junction GD: gate -- d_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    // Gate junction GS: gate -- s_prime (gate row/col already present above)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    // Channel + junction self-terms on d_prime and s_prime
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Charge Q_GS on gate -- s_prime, Q_GD on gate -- d_prime

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Q_GD: gate -- d_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    // Q_GS: gate -- s_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- S (external)
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S' (external)
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel flicker (1/f) noise: d' -- s'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .flicker },
    // Gate-drain shot noise: G -- d'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime), .kind = .shot },
    // Gate-source shot noise: G -- s'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime), .kind = .shot },
};

// ============================================================================
// DC Parameter Prep (pure f64 -- no x dependence)
// ============================================================================

const DcParams = struct {
    vto: f64,
    beta_m: f64,
    lambda: f64,
    b_param: f64,
    is_val: f64,
    nvt: f64,
    gmin: f64,
    type_f: f64,
    scale: f64,
    g_rd: f64,
    g_rs: f64,
};

fn dcPrep(model: *const Model, instance: *const Instance) DcParams {
    // --- Cast model parameters to f64 ---
    const vto: f64 = @as(f64, model.vto);
    const beta_m: f64 = @as(f64, model.beta);
    const lambda: f64 = @as(f64, model.lambda);
    const b_param: f64 = @as(f64, model.b);
    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const tnom: f64 = @as(f64, model.tnom);

    // --- Cast instance parameters to f64 ---
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);

    // --- Type factor for NJF/PJF ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Thermal voltage ---
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const nvt = n_em * vt;

    // --- Area and multiplier scaling ---
    const scale = area * m_mult;

    // --- Series resistance conductances ---
    // Collapsed prime nodes (see collapse()) carry no tie conductance:
    // a 1e12 short absorbs real conductances into its ulp (1.22e-4).
    const g_rd: f64 = if (rd != 0.0) scale / rd else 0.0;
    const g_rs: f64 = if (rs != 0.0) scale / rs else 0.0;

    return .{
        .vto = vto,
        .beta_m = beta_m,
        .lambda = lambda,
        .b_param = b_param,
        .is_val = is_val,
        .nvt = nvt,
        .gmin = 1.0e-12,
        .type_f = type_f,
        .scale = scale,
        .g_rd = g_rd,
        .g_rs = g_rs,
    };
}

pub const PrepCache = DcParams;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return dcPrep(model, instance);
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = pc;

    // --- Terminal voltages (at internal nodes) ---
    const vgs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const vgd_raw = x[g].sub(x[dp]).scale(p.type_f);
    const vds_raw = vgs_raw.sub(vgd_raw);

    // --- Source-drain reversal (region selection on voltage, as original) ---
    const reversed = vds_raw.val() < 0.0;
    const vgs_eff = if (reversed) vgd_raw else vgs_raw;
    const vgd_eff = if (reversed) vgs_raw else vgd_raw;
    const vds_eff = vgs_eff.sub(vgd_eff); // always >= 0

    // --- Gate junction diode currents ---
    // igs = IS * (exp(min(vgs/nvt, 80)) - 1) + GMIN * vgs
    const arg_gs = vgs_raw.scale(1.0 / p.nvt).minC(80.0);
    const igs_raw = arg_gs.exp().addC(-1.0).scale(p.is_val).add(vgs_raw.scale(p.gmin));

    const arg_gd = vgd_raw.scale(1.0 / p.nvt).minC(80.0);
    const igd_raw = arg_gd.exp().addC(-1.0).scale(p.is_val).add(vgd_raw.scale(p.gmin));

    // --- Shichman-Hodges channel current ---
    const vgst = vgs_eff.addC(-p.vto);
    const vgst_pos = vgst.maxC(0.0);
    const vdsat = vgst_pos.scale(1.0 / p.b_param);
    const beta_prime = vds_eff.scale(p.lambda).addC(1.0).scale(p.beta_m);

    // Saturation: V_DS >= V_DSAT
    const id_sat = beta_prime.mul(vgst_pos.mul(vgst_pos)).scale(1.0 / (2.0 * p.b_param));

    // Linear: V_DS < V_DSAT
    const id_lin = beta_prime.mul(vds_eff).mul(vgst_pos.sub(vds_eff.scale(p.b_param / 2.0)));

    // Select region (cutoff when vgst_pos == 0 gives id = 0 from either formula)
    const id_ch_raw = if (vds_eff.val() >= vdsat.val()) id_sat else id_lin;

    // --- Area and multiplier scaling ---
    const id_ch = id_ch_raw.scale(p.scale);
    const igs = igs_raw.scale(p.scale);
    const igd = igd_raw.scale(p.scale);

    // --- Terminal current assembly with reversal handling ---
    // Normal mode (vds_raw >= 0):
    //   I_drain_int  =  (I_D - I_GD) * polarity
    //   I_source_int = (-I_D - I_GS) * polarity
    // Reversed mode (vds_raw < 0):
    //   I_drain_int  = (-I_D - I_GD) * polarity
    //   I_source_int =  (I_D - I_GS) * polarity
    const id_sign = if (reversed) id_ch.neg() else id_ch;

    const i_dp = id_sign.sub(igd).scale(p.type_f);
    const i_sp = id_sign.neg().sub(igs).scale(p.type_f);
    const i_gate = igs.add(igd).scale(p.type_f);

    // --- Series resistances ---
    // RD: drain -- d_prime
    const i_rd = x[d].sub(x[dp]).scale(p.g_rd);

    // RS: source -- s_prime
    const i_rs = x[s].sub(x[sp]).scale(p.g_rs);

    // --- KCL node stamps ---
    var out: [n_u]S = undefined;
    out[d] = i_rd;
    out[g] = i_gate;
    out[s] = i_rs;
    out[dp] = i_dp.sub(i_rd);
    out[sp] = i_sp.sub(i_rs);
    return out;
}

// ============================================================================
// Charge Function (q) -- Junction Depletion Capacitance
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, _: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    // --- Cast model parameters to f64 ---
    const cgs0: f64 = @as(f64, model.cgs);
    const cgd0: f64 = @as(f64, model.cgd);
    const pb: f64 = @as(f64, model.pb);
    const fc: f64 = @as(f64, model.fc);

    // --- Cast instance parameters to f64 ---
    const area: f64 = @as(f64, instance.area);
    const m_mult: f64 = @as(f64, instance.m);
    const scale = area * m_mult;

    // --- Type factor for NJF/PJF ---
    const type_f: f64 = @floatFromInt(model.type_);

    // --- Raw terminal voltages (NOT reversed -- charge uses raw voltages) ---
    const vgs = x[g].sub(x[sp]).scale(type_f);
    const vgd = x[g].sub(x[dp]).scale(type_f);

    // --- Fixed grading coefficient for JFET ---
    const m_grad: f64 = 0.5;
    const one_minus_m = 1.0 - m_grad; // = 0.5

    // --- FC * PB threshold ---
    const fc_pb = fc * pb;

    // --- Forward-bias extension coefficients ---
    const one_minus_fc = 1.0 - fc;
    // f1 = (Cj0 * PB / (1-m)) * (1 - (1-FC)^(1-m))
    // f2 = (1-FC)^(1+m)
    // f3 = 1 - FC*(1+m)
    // These are computed per-junction below since Cj0 differs.

    // ========================================================================
    // Gate-Source Junction Charge
    // ========================================================================
    const x_dep_gs = vgs.scale(-1.0 / pb).addC(1.0).maxC(1e-30);
    // Q_dep = 2 * CGS0 * PB * (1 - sqrt(1 - V/PB))
    // Since m=0.5: (1-m)=0.5, so (Cj0*PB/0.5)*(1 - x^0.5) = 2*Cj0*PB*(1-sqrt(x))
    const q_dep_gs = x_dep_gs.sqrt().neg().addC(1.0).scale(2.0 * cgs0 * pb);

    // Forward-bias extension
    const f1_gs = (cgs0 * pb / one_minus_m) * (1.0 - @sqrt(one_minus_fc));
    const f2_gs = contract.fmath.exp((1.0 + m_grad) * contract.fmath.log(one_minus_fc)); // (1-FC)^1.5
    const f3_gs = 1.0 - fc * (1.0 + m_grad);
    const q_fwd_gs = vgs.addC(-fc_pb).scale(f3_gs)
        .add(vgs.mul(vgs).addC(-(fc_pb * fc_pb)).scale(m_grad / (2.0 * pb)))
        .scale(cgs0 / f2_gs).addC(f1_gs);

    const q_gs_raw = if (vgs.val() < fc_pb) q_dep_gs else q_fwd_gs;
    const q_gs = q_gs_raw.scale(scale);

    // ========================================================================
    // Gate-Drain Junction Charge
    // ========================================================================
    const x_dep_gd = vgd.scale(-1.0 / pb).addC(1.0).maxC(1e-30);
    const q_dep_gd = x_dep_gd.sqrt().neg().addC(1.0).scale(2.0 * cgd0 * pb);

    // Forward-bias extension
    const f1_gd = (cgd0 * pb / one_minus_m) * (1.0 - @sqrt(one_minus_fc));
    const f2_gd = contract.fmath.exp((1.0 + m_grad) * contract.fmath.log(one_minus_fc));
    const f3_gd = 1.0 - fc * (1.0 + m_grad);
    const q_fwd_gd = vgd.addC(-fc_pb).scale(f3_gd)
        .add(vgd.mul(vgd).addC(-(fc_pb * fc_pb)).scale(m_grad / (2.0 * pb)))
        .scale(cgd0 / f2_gd).addC(f1_gd);

    const q_gd_raw = if (vgd.val() < fc_pb) q_dep_gd else q_fwd_gd;
    const q_gd = q_gd_raw.scale(scale);

    // ========================================================================
    // Charge-to-Terminal Mapping
    // ========================================================================
    // Q_drain = -Q_GD
    // Q_gate  =  Q_GS + Q_GD
    // Q_source = -Q_GS
    // External drain/source terminals have no charge (resistors are memoryless)

    var out: [n_u]S = undefined;
    out[d] = S.con(0.0);
    out[g] = q_gs.add(q_gd);
    out[s] = S.con(0.0);
    out[dp] = q_gd.neg();
    out[sp] = q_gs.neg();
    return out;
}

// ============================================================================
// Voltage Limiting (pnjlim + fetlim)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const is_val: f64 = @as(f64, model.is);
    const n_em: f64 = @as(f64, model.n);
    const tnom: f64 = @as(f64, model.tnom);
    const vto: f64 = @as(f64, model.vto);
    const type_f: f64 = @floatFromInt(model.type_);

    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const nvt = n_em * vt;

    // Critical voltage for pnjlim
    const v_crit = nvt * contract.fmath.log(nvt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // ========================================================================
    // PN Junction Limiting on V_GS (gate -- s_prime)
    // ========================================================================
    {
        const vgs_new = (x_new[g] - x_new[sp]) * type_f;
        const vgs_old = (x_old[g] - x_old[sp]) * type_f;

        var vgs_limited = vgs_new;
        if (vgs_new > v_crit and @abs(vgs_new - vgs_old) > 2.0 * nvt) {
            if (vgs_old > 0.0) {
                const arg = 1.0 + (vgs_new - vgs_old) / nvt;
                if (arg > 0.0) {
                    vgs_limited = vgs_old + nvt * (2.0 + contract.fmath.log(arg));
                } else {
                    vgs_limited = v_crit;
                }
            } else if (vgs_new > 0.0) {
                vgs_limited = nvt * contract.fmath.log(vgs_new / nvt);
            } else {
                vgs_limited = v_crit;
            }
        }

        // Apply delta to gate node (in physical voltage space)
        const delta_gs = (vgs_limited - vgs_new) * type_f;
        result[g] += delta_gs;
    }

    // ========================================================================
    // PN Junction Limiting on V_GD (gate -- d_prime)
    // ========================================================================
    {
        // Recompute with updated gate voltage
        const vgd_new = (result[g] - x_new[dp]) * type_f;
        const vgd_old = (x_old[g] - x_old[dp]) * type_f;

        var vgd_limited = vgd_new;
        if (vgd_new > v_crit and @abs(vgd_new - vgd_old) > 2.0 * nvt) {
            if (vgd_old > 0.0) {
                const arg = 1.0 + (vgd_new - vgd_old) / nvt;
                if (arg > 0.0) {
                    vgd_limited = vgd_old + nvt * (2.0 + contract.fmath.log(arg));
                } else {
                    vgd_limited = v_crit;
                }
            } else if (vgd_new > 0.0) {
                vgd_limited = nvt * contract.fmath.log(vgd_new / nvt);
            } else {
                vgd_limited = v_crit;
            }
        }

        // Apply delta to d_prime node (in physical voltage space)
        const delta_gd = (vgd_limited - vgd_new) * type_f;
        // Adjust d_prime (gate was already adjusted for GS)
        result[dp] -= delta_gd;
    }

    // ========================================================================
    // FET Gate Overdrive Limiting (fetlim) on V_GS
    // ========================================================================
    {
        const vgs_new = (result[g] - result[sp]) * type_f;
        const vgs_old = (x_old[g] - x_old[sp]) * type_f;

        const vtsthi = @abs(2.0 * (vgs_old - vto)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const vtox = vto + 3.5;

        var vgs_fet = vgs_new;

        if (vgs_old >= vtox) {
            // Region 1: V_old >= V_tox
            if (vgs_new > vgs_old) {
                // Upward step: clamp to vtsthi
                vgs_fet = @min(vgs_new, vgs_old + vtsthi);
            } else {
                // Downward step: clamp to vtstlo, floor at VT0+2
                vgs_fet = @max(vgs_new, vgs_old - vtstlo);
                vgs_fet = @max(vgs_fet, vto + 2.0);
            }
        } else if (vgs_old >= vto) {
            // Region 2: V_T0 <= V_old < V_tox
            if (vgs_new > vgs_old) {
                // Upward step: clamp to vtsthi
                vgs_fet = @min(vgs_new, vgs_old + vtsthi);
            } else {
                // Downward step: floor at VT0-0.5
                vgs_fet = @max(vgs_new, vto - 0.5);
            }
        } else {
            // Region 3: V_old < V_T0
            if (vgs_new < vgs_old) {
                // Downward step: clamp to vtsthi
                vgs_fet = @max(vgs_new, vgs_old - vtsthi);
            } else {
                // Upward step: clamp to vtstlo, ceiling at VT0+0.5
                vgs_fet = @min(vgs_new, vgs_old + vtstlo);
                vgs_fet = @min(vgs_fet, vto + 0.5);
            }
        }

        const delta_fet = (vgs_fet - vgs_new) * type_f;
        result[g] += delta_fet;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// Gmin stepping: ramp IS from 1e-12 (easy) to model value (real).
// At lambda=0: IS = 1e-12; at lambda=1: IS = model.is

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_is: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    // I_S(lambda) = I_S + (1e-12 - I_S)(1 - lambda)
    // At lambda=0: I_S = 1e-12 (easy to converge)
    // At lambda=1: I_S = model.is (original)
    const is_stepped = is_orig + (gmin_is - is_orig) * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

/// ngspice JFETsetup: prime nodes collapse onto ports when parasitic R = 0.
pub fn collapse(model: *const Model, _: *const Instance) [n_u]?u8 {
    var out: [n_u]?u8 = @splat(null);
    if (@as(f64, model.rd) == 0.0) out[@intFromEnum(U.d_prime)] = @intFromEnum(U.drain);
    if (@as(f64, model.rs) == 0.0) out[@intFromEnum(U.s_prime)] = @intFromEnum(U.source);
    return out;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "jfet: linear region residual (default model, vds=1 < vdsat=2)" {
    // Defaults: vto=-2, beta=1e-4, lambda=0, b=1, is=1e-14, n=1, rd=rs=0.
    // Node order: { drain, gate, source, d_prime, s_prime }.
    // x = { 1, 0, 0, 1, 0 }: d==dp and s==sp so series-R currents are 0.
    //   vgs = 0, vgd = -1, vds = 1 (not reversed)
    //   vgst = 0 - (-2) = 2, vgst_pos = 2, vdsat = 2/1 = 2
    //   vds = 1 < vdsat -> linear:
    //   id_lin = 1e-4 * (1+0) * 1 * (2 - 1*1/2) = 1e-4 * 1.5 = 1.5e-4
    //   igs = 1e-14*(exp(0)-1) + 1e-12*0 = 0
    //   igd = 1e-14*(exp(-1/0.025864925)-1) + 1e-12*(-1)
    //       = 1e-14*(1.6e-17 - 1) - 1e-12 ~= -1.01e-12
    //   out[drain]  = 0
    //   out[gate]   = igs + igd            ~= -1.01e-12
    //   out[source] = 0
    //   out[dp]     = id - igd             ~= 1.5e-4 + 1.01e-12
    //   out[sp]     = -id - igs            = -1.5e-4
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1.01e-12), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1.5e-4), out[3], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1.5e-4), out[4], 1e-9);
}

test "jfet: saturation region residual (vds=3 >= vdsat=2)" {
    // x = { 3, 0, 0, 3, 0 }:
    //   vgs = 0, vgd = -3, vds = 3 >= vdsat = 2 -> saturation:
    //   id_sat = 1e-4 * (1+0) * 2^2 / (2*1) = 2e-4
    //   igs = 0
    //   igd = 1e-14*(exp(-3/nvt)-1) + 1e-12*(-3) ~= -1e-14 - 3e-12 = -3.01e-12
    //   out[gate] = -3.01e-12
    //   out[dp]   = 2e-4 + 3.01e-12
    //   out[sp]   = -2e-4
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3.0, 0.0, 0.0, 3.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -3.01e-12), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2e-4), out[3], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2e-4), out[4], 1e-9);
}

test "jfet: reversed channel (vds < 0) swaps drain/source roles" {
    // x = { 0, 0, 1, 0, 1 }: dp=0, sp=1 -> vgs_raw = -1, vgd_raw = 0,
    // vds_raw = -1 < 0 -> reversed. Effective vgs = 0, vgd = -1, vds = 1.
    // Same channel magnitude as the linear test (id = 1.5e-4) but sign flips:
    //   id_sign = -1.5e-4
    //   igs (on vgs_eff=0) = 0, igd (on vgd_eff=-1) ~= -1.01e-12
    //   out[dp] = id_sign - igd = -1.5e-4 + 1.01e-12
    //   out[sp] = -id_sign - igs = 1.5e-4
    //   out[gate] ~= -1.01e-12
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 0.0, 1.0, 0.0, 1.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -1.01e-12), out[1], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1.5e-4), out[3], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5e-4), out[4], 1e-9);
}

test "jfet: reverse-bias depletion charge" {
    // cgs=1e-12, cgd=2e-12, pb=1, fc=0.5. x = { 0, -1, 0, 0, 0 }:
    //   vgs = vgd = -1
    //   x_dep = 1 - (-1)/1 = 2
    //   q_gs = 2*1e-12*1*(1-sqrt(2)) = 2e-12*(-0.41421356237309515)
    //        = -8.284271247461903e-13
    //   q_gd = 2*2e-12*(1-sqrt(2)) = -1.6568542494923806e-12
    //   out[gate] = q_gs + q_gd = -2.485281374238571e-12
    //   out[dp] = -q_gd = 1.6568542494923806e-12
    //   out[sp] = -q_gs = 8.284271247461903e-13
    const model: Model = .{ .cgs = 1e-12, .cgd = 2e-12, .pb = 1.0, .fc = 0.5 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.0, -1.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -2.485281374238571e-12), out[1], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 1.6568542494923806e-12), out[3], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 8.284271247461903e-13), out[4], 1e-18);
}

test "jfet: forward-bias charge extension (vgs > fc*pb)" {
    // cgs=1e-12, cgd=2e-12, pb=1, fc=0.5, fc_pb=0.5. x = { 0.8, 0.8, 0, 0.8, 0 }:
    //   vgs = 0.8 >= 0.5 -> forward extension; vgd = 0 < 0.5 -> depletion.
    //   f1 = (1e-12*1/0.5)*(1-sqrt(0.5)) = 2e-12*0.2928932188134524
    //      = 5.857864376269049e-13
    //   f2 = 0.5^1.5 = 0.3535533905932738 -> cgs0/f2 = 2.8284271247461903e-12
    //   f3 = 1 - 0.5*1.5 = 0.25
    //   inner = 0.25*(0.8-0.5) + 0.25*(0.8^2 - 0.5^2) = 0.075 + 0.25*0.39 = 0.1725
    //   q_gs = f1 + 2.8284271247461903e-12*0.1725
    //        = 5.857864376269049e-13 + 4.879036790187178e-13
    //        = 1.0736901166456227e-12
    //   q_gd: x_dep = 1 - 0/1 = 1 -> q_gd = 2*2e-12*(1-1) = 0
    //   out[gate] = 1.0736901166456227e-12, out[dp] = 0,
    //   out[sp] = -1.0736901166456227e-12
    const model: Model = .{ .cgs = 1e-12, .cgd = 2e-12, .pb = 1.0, .fc = 0.5 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.8, 0.8, 0.0, 0.8, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.0736901166456227e-12), out[1], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[3], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, -1.0736901166456227e-12), out[4], 1e-18);
}
