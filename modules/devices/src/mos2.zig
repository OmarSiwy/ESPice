const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: D -- RD -- D' (intrinsic drain)
//           S -- RS -- S' (intrinsic source)
//           G (gate), B (bulk)
//           Channel D' <-> S' controlled by gate/bulk voltages
//           Bulk-drain and bulk-source junction diodes
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, drain_prime, source_prime };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC Model Parameters ---
    vto: f32 = 0,
    kp: f32 = 2.07189e-5,
    gamma: f32 = 0,
    phi: f32 = 0.6,
    lambda: f32 = 0,
    tox: f32 = 1e-7,
    nsub: f32 = 0,
    nss: f32 = 0,
    nfs: f32 = 0,
    tpg: i32 = 0,
    neff: f32 = 1,
    delta: f32 = 0,
    ld: f32 = 0,
    u0: f32 = 600,
    ucrit: f32 = 10000,
    uexp: f32 = 0,
    vmax: f32 = 0,
    xj: f32 = 0,
    type_: i32 = 1,

    // --- Parasitic Resistance Parameters ---
    rd: f32 = 0,
    rs: f32 = 0,
    rsh: f32 = 0,

    // --- Junction Parameters ---
    is: f32 = 1e-14,
    js: f32 = 0,
    pb: f32 = 0.8,
    cbd: f32 = 0,
    cbs: f32 = 0,
    cj: f32 = 0,
    mj: f32 = 0.5,
    cjsw: f32 = 0,
    mjsw: f32 = 0.33,
    fc: f32 = 0.5,

    // --- Overlap Capacitance Parameters ---
    cgso: f32 = 0,
    cgdo: f32 = 0,
    cgbo: f32 = 0,

    // --- Noise Parameters ---
    kf: f32 = 0,
    af: f32 = 1,
    nlev: i32 = 2,
    gdsnoi: f32 = 1,

    // --- Temperature Parameters ---
    tnom: f32 = 27,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 1e-6,
    l: f32 = 1e-6,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// RD branch: D -- D'
// RS branch: S -- S'
// Channel: D' -- S' (also depends on G, B through gate/bulk voltages)
// BD junction: B -- D'
// BS junction: B -- S'

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Overlap caps: G-S', G-D', G-B
// Junction caps: B-D', B-S'

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel shot noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Flicker noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
};

// ============================================================================
// Physical constants
// ============================================================================

const gmin: f64 = 1.0e-12;
const eps_si: f64 = 1.0356e-10;
const eps_ox: f64 = 3.453e-11;
const q_charge: f64 = 1.602e-19;
const eps_sd: f64 = 1.0e-12;

// ============================================================================
// DC parameter preprocessing (x-independent, pure f64)
// ============================================================================

const DcParams = struct {
    type_f: f64,
    vt: f64, // thermal voltage at tnom
    vt0: f64,
    gamma: f64,
    phi: f64,
    sqrt_phi: f64,
    lam: f64,
    tox: f64,
    cox: f64,
    nsub: f64,
    nfs: f64,
    neff: f64,
    uexp: f64,
    ucrit: f64,
    ecrit_si: f64, // V/cm -> V/m
    mu0_si: f64, // cm^2/V-s -> m^2/V-s
    vmax: f64,
    xj: f64,
    is_val: f64,
    l_eff: f64,
    f_delta: f64, // narrow-width factor
    beta0: f64,
    k_depl: f64, // NSUB depletion factor for CLM
    xn_const: f64, // 1 + q*NFS/Cox (x-independent part of xn)
    g_d_ext: f64,
    g_s_ext: f64,
};

fn dcParams(model: *const Model, instance: *const Instance) DcParams {
    // --- Cast model parameters to f64 ---
    const vt0: f64 = @as(f64, model.vto);
    const kp: f64 = @as(f64, model.kp);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const lam: f64 = @as(f64, model.lambda);
    const tox: f64 = @as(f64, model.tox);
    const nsub: f64 = @as(f64, model.nsub);
    const nfs: f64 = @as(f64, model.nfs);
    const neff: f64 = @as(f64, model.neff);
    const delta_param: f64 = @as(f64, model.delta);
    const ld: f64 = @as(f64, model.ld);
    const mu0: f64 = @as(f64, model.u0);
    const ucrit: f64 = @as(f64, model.ucrit);
    const uexp: f64 = @as(f64, model.uexp);
    const vmax: f64 = @as(f64, model.vmax);
    const xj: f64 = @as(f64, model.xj);
    const type_f: f64 = @floatFromInt(model.type_);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const is_val: f64 = @as(f64, model.is);
    const tnom: f64 = @as(f64, model.tnom);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);

    // --- Effective dimensions ---
    const l_eff: f64 = @max(l_inst - 2.0 * ld, 1.0e-9);
    const w_eff: f64 = @max(w_inst, 1.0e-9);

    // --- Thermal voltage ---
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);

    // --- Cox ---
    const cox: f64 = eps_ox / tox;

    // --- Narrow-width effect factor ---
    const f_delta = if (delta_param > 0.0) delta_param * 3.14159265358979323846 * eps_si / (2.0 * cox * w_eff) else 0.0;

    // --- Transconductance prefactor ---
    const beta0 = kp * w_eff / l_eff;

    // --- Unit conversions for mobility model ---
    const ecrit_si = ucrit * 100.0; // V/cm -> V/m
    const mu0_si = mu0 * 1.0e-4; // cm^2/V-s -> m^2/V-s

    // --- NSUB-based CLM depletion factor ---
    const nsub_si = nsub * 1.0e6; // cm^-3 -> m^-3
    const k_depl = 2.0 * eps_si / (q_charge * @max(nsub_si, 1.0e-30));

    // --- Subthreshold slope constant part ---
    const xn_const = 1.0 + q_charge * nfs * 1.0e4 / cox;

    // --- Parasitic conductances ---
    // Collapsed prime nodes (see collapse()) carry no tie conductance:
    // a 1e12 short absorbs real conductances into its ulp (1.22e-4).
    const g_d_ext: f64 = if (rd > 0.0) 1.0 / rd else 0.0;
    const g_s_ext: f64 = if (rs > 0.0) 1.0 / rs else 0.0;

    return .{
        .type_f = type_f,
        .vt = vt,
        .vt0 = vt0,
        .gamma = gamma,
        .phi = phi,
        .sqrt_phi = @sqrt(@max(phi, 1.0e-30)),
        .lam = lam,
        .tox = tox,
        .cox = cox,
        .nsub = nsub,
        .nfs = nfs,
        .neff = neff,
        .uexp = uexp,
        .ucrit = ucrit,
        .ecrit_si = ecrit_si,
        .mu0_si = mu0_si,
        .vmax = vmax,
        .xj = xj,
        .is_val = is_val,
        .l_eff = l_eff,
        .f_delta = f_delta,
        .beta0 = beta0,
        .k_depl = k_depl,
        .xn_const = xn_const,
        .g_d_ext = g_d_ext,
        .g_s_ext = g_s_ext,
    };
}

pub const PrepCache = DcParams;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return dcParams(model, instance);
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
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const p = pc;

    // ========================================================================
    // PMOS handling and source/drain reversal
    // ========================================================================
    const vgs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(p.type_f);
    const vbs_raw = x[b].sub(x[sp]).scale(p.type_f);

    // Smooth absolute value for source/drain reversal
    const vds_abs = vds_raw.mul(vds_raw).addC(eps_sd).sqrt();

    // Smooth sign function
    const mode = vds_raw.div(vds_abs);

    // Effective terminal voltages after reversal
    const vds = vds_abs;
    const half_one_minus_mode = mode.neg().addC(1.0).scale(0.5);
    const vgs = vgs_raw.sub(half_one_minus_mode.mul(vds_raw));
    const vbs = vbs_raw.sub(half_one_minus_mode.mul(vds_raw));

    // ========================================================================
    // Body effect
    // ========================================================================
    // Region branch preserved from the original (vbs <= 0 reverse / forward)
    const sarg = if (vbs.val() <= 0.0)
        vbs.neg().addC(p.phi).maxC(1.0e-30).sqrt() // sqrt(max(phi - vbs, 1e-30))
    else
        vbs.scale(-1.0 / (2.0 * p.phi)).addC(1.0).scale(p.sqrt_phi); // sqrt_phi*(1 - vbs/(2*phi))

    // ========================================================================
    // Threshold voltage
    // ========================================================================
    const vth_base = sarg.addC(-p.sqrt_phi).scale(p.gamma).addC(p.vt0);

    // --- Narrow-width effect ---
    const dvth_narrow = sarg.scale(2.0 * p.f_delta);
    const vth_eff = vth_base.add(dvth_narrow);

    // Gate overdrive
    const vgst = vgs.sub(vth_eff);

    // Smooth positive gate overdrive
    const vgst_pos = vgst.add(vgst.mul(vgst).addC(eps_sd).sqrt()).scale(0.5);

    // ========================================================================
    // Field-dependent mobility (UCRIT, UEXP)
    // ========================================================================
    const e_eff = vgst_pos.scale(1.0 / p.tox).addC(1.0);
    const r_eff = e_eff.scale(1.0 / p.ecrit_si).maxC(1.0e-30);
    const mu_ratio_mob = r_eff.log().scale(-p.uexp).minC(80.0).exp();
    const mu_ratio = if (p.uexp > 0.0 and p.ucrit > 0.0) mu_ratio_mob else S.con(1.0);

    // ========================================================================
    // Transconductance
    // ========================================================================
    const beta = mu_ratio.scale(p.beta0);

    // ========================================================================
    // Saturation voltage (VMAX)
    // ========================================================================
    const mu_eff_si = mu_ratio.scale(p.mu0_si);
    const vdsat_vmax = S.con(p.vmax * p.l_eff).div(mu_eff_si.maxC(1.0e-30));

    // Smooth minimum with NEFF correction
    const neff_vdsat_vmax = vdsat_vmax.scale(p.neff);
    const diff_vdsat = vgst_pos.sub(neff_vdsat_vmax);
    const vdsat_with_vmax = vgst_pos.add(neff_vdsat_vmax).sub(diff_vdsat.mul(diff_vdsat).addC(eps_sd).sqrt()).scale(0.5);
    const vdsat = if (p.vmax > 0.0) vdsat_with_vmax else vgst_pos;

    // ========================================================================
    // Subthreshold conduction (NFS)
    // ========================================================================
    const cd_over_cox = S.con(eps_si * p.gamma).div(sarg.scale(2.0 * p.cox).maxC(1.0e-30));
    const xn = cd_over_cox.addC(p.xn_const);
    const von = vth_eff.add(xn.scale(p.vt));
    const alpha_sub = vgs.sub(von).div(xn.scale(p.vt)).minC(80.0);
    const exp_alpha = alpha_sub.exp();
    const exp_alpha_m1 = exp_alpha.addC(-1.0);
    const f_sub_nfs = exp_alpha.addC(1.0).sub(exp_alpha_m1.mul(exp_alpha_m1).addC(eps_sd).sqrt()).scale(0.5);
    const f_sub = if (p.nfs > 0.0) f_sub_nfs else S.con(1.0);

    // ========================================================================
    // Effective drain-source voltage (saturation clamp)
    // ========================================================================
    const diff_vds_vdsat = vds.sub(vdsat);
    const vds_eff = vds.add(vdsat).sub(diff_vds_vdsat.mul(diff_vds_vdsat).addC(eps_sd).sqrt()).scale(0.5);

    // ========================================================================
    // Core drain current
    // ========================================================================
    const id_core = beta.mul(vgst_pos.mul(vds_eff).sub(vds_eff.mul(vds_eff).scale(0.5)));

    // ========================================================================
    // Channel-length modulation
    // ========================================================================
    // NSUB-based CLM
    const vds_excess = vds.sub(vdsat).maxC(0.0);
    const delta_l_raw = vds_excess.scale(p.k_depl).maxC(1.0e-30).sqrt();

    // Junction-depth correction (XJ > 0)
    const delta_l = if (p.xj > 0.0)
        delta_l_raw.scale(2.0 / p.xj).addC(1.0).sqrt().addC(-1.0).scale(p.xj) // xj*(sqrt(1+2*dl/xj)-1)
    else
        delta_l_raw;

    // Ratio clamped to 0.5 (punch-through protection)
    const r_clm = delta_l.scale(1.0 / p.l_eff);
    const r_m_half = r_clm.addC(-0.5);
    const r_clamp = r_clm.addC(0.5).sub(r_m_half.mul(r_m_half).addC(eps_sd).sqrt()).scale(0.5);
    const f_clm_nsub = S.con(1.0).div(r_clamp.neg().addC(1.0));

    // Lambda fallback
    const f_clm_lam = vds.scale(p.lam).addC(1.0);

    const f_clm = if (p.nsub > 0.0) f_clm_nsub else f_clm_lam;

    // ========================================================================
    // Final drain current
    // ========================================================================
    const ids_internal = id_core.mul(f_clm).mul(f_sub);
    const i_ds = ids_internal.mul(mode).scale(p.type_f);

    // ========================================================================
    // Parasitic resistance currents
    // ========================================================================
    const i_rd = x[d].sub(x[dp]).scale(p.g_d_ext);
    const i_rs = x[s].sub(x[sp]).scale(p.g_s_ext);

    // ========================================================================
    // Bulk junction diode currents
    // ========================================================================
    const vbs_jct = x[b].sub(x[sp]);
    const vbd_jct = x[b].sub(x[dp]);

    const arg_bs = vbs_jct.scale(1.0 / p.vt).minC(80.0);
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.is_val).add(vbs_jct.scale(gmin));

    const arg_bd = vbd_jct.scale(1.0 / p.vt).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.is_val).add(vbd_jct.scale(gmin));

    // ========================================================================
    // KCL node assembly
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d] = i_rd.neg();
    out[g] = S.con(0.0);
    out[s] = i_rs.neg();
    out[b] = i_bs.add(i_bd).neg();
    out[dp] = i_rd.sub(i_ds).add(i_bd);
    out[sp] = i_rs.add(i_ds).add(i_bs);
    return out;
}

// ============================================================================
// Charge Function (q)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, _: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);

    // --- Cast model parameters to f64 ---
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cbd: f64 = @as(f64, model.cbd);
    const cbs: f64 = @as(f64, model.cbs);
    const ld: f64 = @as(f64, model.ld);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);
    const w_eff: f64 = @max(w_inst, 1.0e-9);
    const l_eff: f64 = @max(l_inst - 2.0 * ld, 1.0e-9);

    // ========================================================================
    // Voltages for charge computation
    // ========================================================================
    const v_gs_prime = x[g].sub(x[sp]); // V_G - V_S'
    const v_gd_prime = x[g].sub(x[dp]); // V_G - V_D'
    const v_gb = x[g].sub(x[b]); // V_G - V_B
    const v_bd_prime = x[b].sub(x[dp]); // V_B - V_D'
    const v_bs_prime = x[b].sub(x[sp]); // V_B - V_S'

    // ========================================================================
    // Gate overlap charges
    // ========================================================================
    const q_cgso = v_gs_prime.scale(cgso * w_eff);
    const q_cgdo = v_gd_prime.scale(cgdo * w_eff);
    const q_cgbo = v_gb.scale(cgbo * l_eff);

    // ========================================================================
    // Bulk junction charges (linear approximation)
    // ========================================================================
    const q_bd = if (cbd > 0.0) v_bd_prime.scale(cbd) else S.con(0.0);
    const q_bs = if (cbs > 0.0) v_bs_prime.scale(cbs) else S.con(0.0);

    // ========================================================================
    // Node charge assembly
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d] = S.con(0.0);
    out[g] = q_cgso.add(q_cgdo).add(q_cgbo);
    out[s] = S.con(0.0);
    out[b] = q_bs.add(q_bd).sub(q_cgbo);
    out[dp] = q_cgdo.neg().sub(q_bd);
    out[sp] = q_cgso.neg().sub(q_bs);
    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub const limit_flag_unknowns = [_]U{.bulk};

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const is_val: f64 = @as(f64, model.is);
    const type_f: f64 = @floatFromInt(model.type_);
    // fetlim compares type-corrected vgs; the threshold must be too.
    const vto: f64 = type_f * @as(f64, model.vto);
    const tnom: f64 = @as(f64, model.tnom);
    const vt: f64 = 8.617333262145e-5 * (tnom + 273.15);
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));

    // Type-corrected junction voltages (ngspice MOSload layout).
    const vgs_new = (x_new[g] - x_new[sp]) * type_f;
    const vds_new = (x_new[dp] - x_new[sp]) * type_f;
    const vbs_new = (x_new[b] - x_new[sp]) * type_f;
    const vgs_old = (x_old[g] - x_old[sp]) * type_f;
    const vds_old = (x_old[dp] - x_old[sp]) * type_f;
    const vbs_old = (x_old[b] - x_old[sp]) * type_f;
    const vgd_new = vgs_new - vds_new;
    const vgd_old = vgs_old - vds_old;
    const vbd_new = vbs_new - vds_new;
    const vbd_old = vbs_old - vds_old;

    // ngspice limiting sequence: normal mode limits vgs and vds; inverted
    // mode (previous vds < 0) limits vgd and -vds.
    var vgs = vgs_new;
    var vds = vds_new;
    if (vds_old >= 0) {
        vgs = contract.limits.fetlim(vgs_new, vgs_old, vto);
        vds = vgs - vgd_new;
        vds = contract.limits.limvds(vds, vds_old);
    } else {
        const vgd = contract.limits.fetlim(vgd_new, vgd_old, vto);
        vds = vgs_new - vgd;
        vds = -contract.limits.limvds(-vds, -vds_old);
        vgs = vgd + vds;
    }
    var vbs = vbs_new;
    if (vds >= 0) {
        vbs = contract.limits.pnjlim(vbs_new, vbs_old, vt, v_crit);
    } else {
        const vbd = contract.limits.pnjlim(vbd_new, vbd_old, vt, v_crit);
        vbs = vbd + vds;
    }

    // Reconstruct the local eval point anchored at s_prime.
    var result = x_new;
    result[g] = x_new[sp] + type_f * vgs;
    result[dp] = x_new[sp] + type_f * vds;
    result[b] = x_new[sp] + type_f * vbs;
    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    const is_stepped = is_orig + (gmin_step - is_orig) * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

/// ngspice MOS2setup: prime nodes collapse onto ports when parasitic R = 0.
pub fn collapse(model: *const Model, _: *const Instance) [n_u]?u8 {
    var out: [n_u]?u8 = @splat(null);
    if (!(@as(f64, model.rd) > 0.0)) out[@intFromEnum(U.drain_prime)] = @intFromEnum(U.drain);
    if (!(@as(f64, model.rs) > 0.0)) out[@intFromEnum(U.source_prime)] = @intFromEnum(U.source);
    return out;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// Unknown order: { drain, gate, source, bulk, drain_prime, source_prime }

test "mos2: saturation on-state drain current" {
    // Hand computation from the OLD formula:
    //   kp = 3.0517578125e-5 (= 2^-15, exact in f32), w = 8e-6, l = 1e-6
    //   (8e-6 and 1e-6 round to the same f32 mantissa, so w_eff/l_eff = 8 exactly)
    //   beta0 = kp * w/l = 3.0517578125e-5 * 8 = 2.44140625e-4
    //   vto = 1, gamma = 0, so vth = 1
    //   x: vd = vdp = 2, vg = 2, vs = vsp = 0, vb = 0
    //   vgs = 2, vds = 2, vgst = 1, vdsat = vgst = 1 (vmax = 0)
    //   vds > vdsat -> vds_eff -> vdsat = 1 (smooth clamp, eps_sd = 1e-12)
    //   id = beta0 * (vgst*vds_eff - 0.5*vds_eff^2) = 2.44140625e-4 * 0.5
    //      = 1.220703125e-4
    //   junction BS: vbs_jct = 0 -> i_bs = 0 exactly
    //   junction BD: vbd_jct = -2 -> i_bd = is*(exp(-2/vt)-1) + gmin*(-2)
    //      ~= -1e-14 - 2e-12 = -2.01e-12   (exp(-77.3) negligible)
    //   out[sp] = i_ds = 1.220703125e-4
    //   out[dp] = -i_ds + i_bd = -1.220703125e-4 - 2.01e-12
    //   out[b]  = -(i_bs + i_bd) = 2.01e-12
    // Smoothing (eps_sd) perturbs id by O(1e-16); tolerance 1e-15 covers it.
    const model: Model = .{ .vto = 1.0, .kp = 3.0517578125e-5 };
    const inst: Instance = .{ .w = 8e-6, .l = 1e-6 };
    const out = contract.evalValues(Self, .{ 2.0, 2.0, 0.0, 0.0, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.220703125e-4), out[@intFromEnum(U.source_prime)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1.220703125e-4 - 2.01e-12), out[@intFromEnum(U.drain_prime)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 2.01e-12), out[@intFromEnum(U.bulk)], 1e-16);
    // rd = rs = 0 with vd = vdp, vs = vsp -> zero parasitic current; gate carries no DC current
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.drain)], 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.gate)], 1e-18);
}

test "mos2: linear region drain current" {
    // Same device, x: vd = vdp = 0.1, vg = 2, vs = vsp = vb = 0
    //   vgst = 1, vdsat = 1, vds = 0.1 < vdsat -> vds_eff -> vds = 0.1
    //   id = beta0 * (1*0.1 - 0.5*0.01) = 2.44140625e-4 * 0.095
    //      = 2.3193359375e-5
    // Smooth-clamp wiggle is O(5e-15); tolerance 1e-13.
    const model: Model = .{ .vto = 1.0, .kp = 3.0517578125e-5 };
    const inst: Instance = .{ .w = 8e-6, .l = 1e-6 };
    const out = contract.evalValues(Self, .{ 0.1, 2.0, 0.0, 0.0, 0.1, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 2.3193359375e-5), out[@intFromEnum(U.source_prime)], 1e-13);
}

test "mos2: cutoff -> negligible drain current" {
    // vgs = 0 < vto = 1: vgst = -1, smooth-positive overdrive ~ eps_sd/4/|vgst|
    // -> id ~ 1e-29, i.e. zero to solver precision.
    const model: Model = .{ .vto = 1.0, .kp = 3.0517578125e-5 };
    const inst: Instance = .{ .w = 8e-6, .l = 1e-6 };
    const out = contract.evalValues(Self, .{ 2.0, 0.0, 0.0, 0.0, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.source_prime)], 1e-15);
}

test "mos2: overlap and junction charges" {
    // Hand computation from the OLD formula:
    //   cgso = 1e-10, cgdo = 2e-10, cgbo = 3e-10, cbd = 1e-12, cbs = 2e-12
    //   w = 10e-6 -> w_eff = 1e-5; l = 2e-6, ld = 0 -> l_eff = 2e-6
    //   x: vd = vdp = 2, vg = 1.5, vs = vsp = 0, vb = -0.5
    //   v_gs' = 1.5, v_gd' = -0.5, v_gb = 2.0, v_bd' = -2.5, v_bs' = -0.5
    //   q_cgso = 1e-10 * 1e-5 * 1.5   =  1.5e-15
    //   q_cgdo = 2e-10 * 1e-5 * (-0.5) = -1e-15
    //   q_cgbo = 3e-10 * 2e-6 * 2.0    =  1.2e-15
    //   q_bd   = 1e-12 * (-2.5)        = -2.5e-12
    //   q_bs   = 2e-12 * (-0.5)        = -1e-12
    //   out[g]  = 1.5e-15 - 1e-15 + 1.2e-15   =  1.7e-15
    //   out[b]  = -1e-12 - 2.5e-12 - 1.2e-15  = -3.5012e-12
    //   out[dp] = 1e-15 + 2.5e-12             =  2.501e-12
    //   out[sp] = -1.5e-15 + 1e-12            =  9.985e-13
    // (tolerance 1e-17 accounts for f32 parameter storage)
    const model: Model = .{ .cgso = 1e-10, .cgdo = 2e-10, .cgbo = 3e-10, .cbd = 1e-12, .cbs = 2e-12 };
    const inst: Instance = .{ .w = 10e-6, .l = 2e-6 };
    const out = contract.qValues(Self, .{ 2.0, 1.5, 0.0, -0.5, 2.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 1.7e-15), out[@intFromEnum(U.gate)], 1e-17);
    try testing.expectApproxEqAbs(@as(f64, -3.5012e-12), out[@intFromEnum(U.bulk)], 1e-17);
    try testing.expectApproxEqAbs(@as(f64, 2.501e-12), out[@intFromEnum(U.drain_prime)], 1e-17);
    try testing.expectApproxEqAbs(@as(f64, 9.985e-13), out[@intFromEnum(U.source_prime)], 1e-17);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.drain)], 1e-20);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.source)], 1e-20);
}
