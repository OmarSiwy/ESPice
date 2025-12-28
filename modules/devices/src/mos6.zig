const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: MOS Level 6 (Sakurai-Newton Empirical MOSFET)
//
//   D (ext) -- RD -- D' (internal drain)
//   S (ext) -- RS -- S' (internal source)
//   G (gate) -- overlap caps to D', S', B
//   B (bulk) -- junction diodes to D', S'
//   Channel current flows D' to S' modulated by G and B
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, d_prime, s_prime };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- DC Model Parameters (Sakurai-Newton) ---
    vto: f32 = 0,
    kv: f32 = 2,
    nv: f32 = 0.5,
    kc: f32 = 5e-5,
    nc: f32 = 1,
    nvth: f32 = 0.5,
    ps: f32 = 0,
    gamma: f32 = 0,
    gamma1: f32 = 0,
    sigma: f32 = 0,
    phi: f32 = 0.6,
    lambda: f32 = 0,
    lambda0: f32 = 0,
    lambda1: f32 = 0,

    // --- Parasitic Resistance Parameters ---
    rd: f32 = 0,
    rs: f32 = 0,
    rsh: f32 = 0,

    // --- Junction Diode Parameters ---
    is: f32 = 1e-14,
    js: f32 = 0,
    pb: f32 = 0.8,

    // --- Capacitance Parameters ---
    cbd: f32 = 0,
    cbs: f32 = 0,
    cgso: f32 = 0,
    cgdo: f32 = 0,
    cgbo: f32 = 0,
    cj: f32 = 0,
    mj: f32 = 0.5,
    cjsw: f32 = 0,
    mjsw: f32 = 0.5,
    fc: f32 = 0.5,

    // --- Technology Parameters ---
    tox: f32 = 0,
    u0: f32 = 0,
    tpg: i32 = 0,
    nsub: f32 = 0,
    nss: f32 = 0,
    ld: f32 = 0,
    tnom: f32 = 300.15,
    type_: i32 = 1,

    // --- Noise Parameters ---
    kf: f32 = 0,
    af: f32 = 1.0,
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
// RD branch: drain -- d_prime
// RS branch: source -- s_prime
// Channel: d_prime -- s_prime (also depends on gate and bulk)
// Junction BS: bulk -- s_prime
// Junction BD: bulk -- d_prime
// GMIN: d_prime--s_prime, gate--s_prime, gate--d_prime

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: drain -- d_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.drain) },
    // RS branch: source -- s_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.source) },
    // Gate GMIN: gate -- d_prime, gate -- s_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime) },
    // Bulk junctions: bulk -- d_prime, bulk -- s_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.s_prime) },
    // d_prime self + cross terms
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.bulk) },
    // s_prime self + cross terms
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.bulk) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Q_GS: gate -- s_prime
// Q_GD: gate -- d_prime
// Q_GB: gate -- bulk
// Q_BS: bulk -- s_prime
// Q_BD: bulk -- d_prime

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Q_GS: gate -- s_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.s_prime) },
    // Q_GD: gate -- d_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.d_prime) },
    // Q_GB: gate -- bulk
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    // Q_BS: bulk -- s_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.s_prime) },
    .{ .row = @intFromEnum(U.s_prime), .col = @intFromEnum(U.bulk) },
    // Q_BD: bulk -- d_prime
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.d_prime) },
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.bulk) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel thermal noise: D' -- S'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel flicker (1/f) noise: D' -- S'
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .flicker },
};

// ============================================================================
// DC Parameter Preprocessing (pure f64 -- no x dependence)
// ============================================================================

const DcParams = struct {
    vto: f64,
    kv: f64,
    nv: f64,
    /// kc * w_eff / l_eff -- saturation current prefactor
    kc_wl: f64,
    nc: f64,
    nvth: f64,
    gamma: f64,
    gamma1: f64,
    sigma: f64,
    phi: f64,
    sqrt_phi: f64,
    lam: f64,
    lam0: f64,
    lam1: f64,
    g_rd: f64,
    g_rs: f64,
    is_val: f64,
    vt: f64,
    type_f: f64,
};

fn dcParams(model: *const Model, instance: *const Instance) DcParams {
    // --- Cast model parameters to f64 ---
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const tnom: f64 = @as(f64, model.tnom);
    const ld: f64 = @as(f64, model.ld);
    const kc: f64 = @as(f64, model.kc);
    const phi: f64 = @as(f64, model.phi);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);

    // --- Effective geometry ---
    const l_eff = @max(l_inst - 2.0 * ld, 1.0e-9);
    const w_eff = @max(w_inst, 1.0e-9);

    return .{
        .vto = @as(f64, model.vto),
        .kv = @as(f64, model.kv),
        .nv = @as(f64, model.nv),
        .kc_wl = kc * w_eff / l_eff,
        .nc = @as(f64, model.nc),
        .nvth = @as(f64, model.nvth),
        .gamma = @as(f64, model.gamma),
        .gamma1 = @as(f64, model.gamma1),
        .sigma = @as(f64, model.sigma),
        .phi = phi,
        .sqrt_phi = @sqrt(@max(phi, 1.0e-30)),
        .lam = @as(f64, model.lambda),
        .lam0 = @as(f64, model.lambda0),
        .lam1 = @as(f64, model.lambda1),
        .g_rd = if (rd != 0.0) 1.0 / rd else 1.0e12,
        .g_rs = if (rs != 0.0) 1.0 / rs else 1.0e12,
        .is_val = @as(f64, model.is),
        // --- Thermal voltage ---
        .vt = 8.617333262145e-5 * tnom,
        // --- Type factor for NMOS/PMOS ---
        .type_f = @floatFromInt(model.type_),
    };
}

// ============================================================================
// DC Current Function (eval)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = &pc.dc;

    // --- GMIN ---
    const gmin: f64 = 1.0e-12;

    // --- Terminal voltages at internal nodes with type polarity ---
    const v_gs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const v_ds_raw = x[dp].sub(x[sp]).scale(p.type_f);
    const v_bs_raw = x[b].sub(x[sp]).scale(p.type_f);

    // --- Source-drain reversal (branchless smooth step) ---
    const vds_abs = v_ds_raw.abs();
    const eps_mode: f64 = 1.0e-30;
    const alpha_fwd = v_ds_raw.add(vds_abs).div(vds_abs.addC(eps_mode).scale(2.0));
    const one_minus_alpha = alpha_fwd.neg().addC(1.0);

    const vgs_use = alpha_fwd.mul(v_gs_raw).add(one_minus_alpha.mul(v_gs_raw.sub(v_ds_raw)));
    const vbs_use = alpha_fwd.mul(v_bs_raw).add(one_minus_alpha.mul(v_bs_raw.sub(v_ds_raw)));
    const vds_eff = vds_abs;
    const v_bd = vbs_use.sub(vds_eff);

    // --- Threshold voltage ---
    // Base threshold with body effect
    const sarg = vbs_use.neg().addC(p.phi).maxC(1.0e-30).sqrt();
    var vth = sarg.addC(-p.sqrt_phi).scale(p.gamma).addC(p.vto);

    // Secondary body effect
    vth = vth.add(vbs_use.scale(p.gamma1));

    // DIBL / static feedback
    vth = vth.add(vds_eff.scale(p.sigma));

    // Threshold voltage Vds dependence
    const nvth_factor = vds_eff.scale(p.nvth).addC(1.0);
    vth = vth.mul(nvth_factor);

    // --- Gate overdrive ---
    const vgst = vgs_use.sub(vth);
    // Clamped positive overdrive (branchless half-wave rectifier)
    const vgst_pos = vgst.add(vgst.abs()).scale(0.5).addC(1.0e-30);

    // --- Saturation voltage (Sakurai-Newton) ---
    const v_dsat = vgst_pos.log().scale(p.nv).exp().scale(p.kv);

    // --- Drain current (Sakurai-Newton) ---
    // Saturation current
    const i_sat = vgst_pos.log().scale(p.nc).exp().scale(p.kc_wl);

    // Smooth linear/saturation transition
    const eps_s: f64 = 1.0e-4;
    const r_ratio = vds_eff.div(v_dsat.addC(1.0e-20));
    const r_minus_1 = r_ratio.addC(-1.0);
    const r_clamped = r_ratio.addC(1.0).sub(r_minus_1.mul(r_minus_1).addC(eps_s * eps_s).sqrt()).scale(0.5);
    const f_lin = r_clamped.scale(2.0).sub(r_clamped.mul(r_clamped));

    var ids = i_sat.mul(f_lin);

    // --- Channel-length modulation ---
    const vds_minus_vdsat = vds_eff.sub(v_dsat).maxC(0.0);

    // lam0 != 0: use lam0 + lam1 * vbs_use
    // lam0 == 0 but lam != 0: use lam
    // Both zero: factor = 1.0
    const lam_eff_0 = vbs_use.scale(p.lam1).addC(p.lam0);
    const lam_factor = if (p.lam0 != 0.0)
        lam_eff_0.mul(vds_minus_vdsat).addC(1.0)
    else
        vds_minus_vdsat.scale(p.lam).addC(1.0);
    ids = ids.mul(lam_factor);

    // --- Current sign and polarity ---
    const mode = alpha_fwd.scale(2.0).addC(-1.0);
    ids = ids.mul(mode);

    // --- Bulk junction diode currents ---
    const arg_bs = vbs_use.div(S.con(p.vt)).minC(80.0);
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.is_val);

    const arg_bd = v_bd.div(S.con(p.vt)).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.is_val);

    // --- Parasitic resistance currents ---
    const i_rd = x[d].sub(x[dp]).scale(p.g_rd);
    const i_rs = x[s].sub(x[sp]).scale(p.g_rs);

    // --- GMIN stabilization currents ---
    const i_gmin_ds = x[dp].sub(x[sp]).scale(gmin);
    const i_gmin_gs = x[g].sub(x[sp]).scale(gmin);
    const i_gmin_gd = x[g].sub(x[dp]).scale(gmin);

    // --- Apply type factor to junction and channel currents ---
    const ids_out = ids.scale(p.type_f);
    const i_bs_out = i_bs.scale(p.type_f);
    const i_bd_out = i_bd.scale(p.type_f);

    // --- KCL node stamps ---
    var out: [n_u]S = undefined;
    // D (ext): -I_RD
    out[d] = i_rd.neg();
    // G: -I_GMIN_GS - I_GMIN_GD
    out[g] = i_gmin_gs.neg().sub(i_gmin_gd);
    // S (ext): -I_RS
    out[s] = i_rs.neg();
    // B: -I_BS - I_BD
    out[b] = i_bs_out.neg().sub(i_bd_out);
    // D' (int): I_RD + I_DS + I_BD + I_GMIN_GD - I_GMIN_DS
    out[dp] = i_rd.add(ids_out).add(i_bd_out).add(i_gmin_gd).sub(i_gmin_ds);
    // S' (int): I_RS - I_DS + I_BS + I_GMIN_GS + I_GMIN_DS
    out[sp] = i_rs.sub(ids_out).add(i_bs_out).add(i_gmin_gs).add(i_gmin_ds);
    return out;
}

// ============================================================================
// Charge Parameter Preprocessing (pure f64 -- no x dependence)
// ============================================================================

const QParams = struct {
    /// cgso * w_eff
    cgso_w: f64,
    /// cgdo * w_eff
    cgdo_w: f64,
    /// cgbo * l_eff
    cgbo_l: f64,
    /// cbs * pb / (1 - mj)
    cbs_coef: f64,
    /// cbd * pb / (1 - mj)
    cbd_coef: f64,
    pb: f64,
    one_minus_mj: f64,
    type_f: f64,
};

fn qParams(model: *const Model, instance: *const Instance) QParams {
    // --- Cast model parameters to f64 ---
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cbs0: f64 = @as(f64, model.cbs);
    const cbd0: f64 = @as(f64, model.cbd);
    const pb: f64 = @as(f64, model.pb);
    const mj: f64 = @as(f64, model.mj);
    const ld: f64 = @as(f64, model.ld);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);

    // --- Effective geometry ---
    const l_eff = @max(l_inst - 2.0 * ld, 1.0e-9);
    const w_eff = @max(w_inst, 1.0e-9);

    const one_minus_mj = 1.0 - mj;

    return .{
        .cgso_w = cgso * w_eff,
        .cgdo_w = cgdo * w_eff,
        .cgbo_l = cgbo * l_eff,
        .cbs_coef = cbs0 * pb / one_minus_mj,
        .cbd_coef = cbd0 * pb / one_minus_mj,
        .pb = pb,
        .one_minus_mj = one_minus_mj,
        // --- Type factor for NMOS/PMOS ---
        .type_f = @floatFromInt(model.type_),
    };
}

pub const PrepCache = struct { dc: DcParams, q: QParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = dcParams(model, instance),
        .q = qParams(model, instance),
    };
}

// ============================================================================
// Charge Function (q) -- Gate Overlap + Bulk Junction Depletion
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const p = &pc.q;

    // --- Terminal voltages (raw, for charge computation) ---
    // Gate overlap charges use voltages between gate and internal nodes
    const v_gs = x[g].sub(x[sp]).scale(p.type_f);
    const v_gd = x[g].sub(x[dp]).scale(p.type_f);
    const v_gb = x[g].sub(x[b]).scale(p.type_f);

    // Junction voltages (bulk to internal nodes, type-adjusted)
    const v_bs = x[b].sub(x[sp]).scale(p.type_f);
    const v_bd = x[b].sub(x[dp]).scale(p.type_f);

    // ========================================================================
    // Gate Overlap Charges (Meyer Model -- linear overlap only)
    // ========================================================================
    // Overlap caps are scaled by width (length for cgbo) in qParams
    const q_gs_ovl = v_gs.scale(p.cgso_w);
    const q_gd_ovl = v_gd.scale(p.cgdo_w);
    const q_gb_ovl = v_gb.scale(p.cgbo_l);

    // ========================================================================
    // Bulk-Source Junction Depletion Charge
    // ========================================================================
    // Reverse bias: Q = (C*PB/(1-MJ)) * [1 - (1-V/PB)^(1-MJ)]
    const x_bs = v_bs.div(S.con(p.pb)).neg().addC(1.0).maxC(1.0e-30);
    const q_bs_dep = x_bs.log().scale(p.one_minus_mj).exp().neg().addC(1.0).scale(p.cbs_coef);

    // ========================================================================
    // Bulk-Drain Junction Depletion Charge
    // ========================================================================
    const x_bd = v_bd.div(S.con(p.pb)).neg().addC(1.0).maxC(1.0e-30);
    const q_bd_dep = x_bd.log().scale(p.one_minus_mj).exp().neg().addC(1.0).scale(p.cbd_coef);

    // ========================================================================
    // Charge-to-Terminal Mapping (node stamps)
    // ========================================================================
    // G:  +Q_GS + Q_GD + Q_GB
    // B:  -Q_GB + Q_BS + Q_BD
    // D': -Q_GD - Q_BD
    // S': -Q_GS - Q_BS

    var out: [n_u]S = undefined;
    // External drain and source have no charge (resistors are memoryless)
    out[@intFromEnum(U.drain)] = S.con(0.0);
    out[g] = q_gs_ovl.add(q_gd_ovl).add(q_gb_ovl).scale(p.type_f);
    out[@intFromEnum(U.source)] = S.con(0.0);
    out[b] = q_gb_ovl.neg().add(q_bs_dep).add(q_bd_dep).scale(p.type_f);
    out[dp] = q_gd_ovl.neg().sub(q_bd_dep).scale(p.type_f);
    out[sp] = q_gs_ovl.neg().sub(q_bs_dep).scale(p.type_f);
    return out;
}

// ============================================================================
// Voltage Limiting (pnjlim for junctions + MOS gate/drain limiting)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const is_val: f64 = @as(f64, model.is);
    const tnom: f64 = @as(f64, model.tnom);
    const type_f: f64 = @floatFromInt(model.type_);

    const vt: f64 = 8.617333262145e-5 * tnom;

    // Critical voltage for PN junction limiting
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));

    var result = x_new;

    // ========================================================================
    // PN Junction Limiting on V_BS (bulk -- s_prime)
    // ========================================================================
    {
        const vbs_new = (x_new[b] - x_new[sp]) * type_f;
        const vbs_old = (x_old[b] - x_old[sp]) * type_f;

        var vbs_limited = vbs_new;
        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = 1.0 + (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * contract.fmath.log(arg);
                } else {
                    vbs_limited = v_crit;
                }
            } else {
                vbs_limited = vt * contract.fmath.log(vbs_new / vt);
            }
        }

        const delta_bs = (vbs_limited - vbs_new) * type_f;
        // Adjust bulk node
        result[b] += delta_bs;
    }

    // ========================================================================
    // PN Junction Limiting on V_BD (bulk -- d_prime)
    // ========================================================================
    {
        const vbd_new = (result[b] - x_new[dp]) * type_f;
        const vbd_old = (x_old[b] - x_old[dp]) * type_f;

        var vbd_limited = vbd_new;
        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = 1.0 + (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * contract.fmath.log(arg);
                } else {
                    vbd_limited = v_crit;
                }
            } else {
                vbd_limited = vt * contract.fmath.log(vbd_new / vt);
            }
        }

        const delta_bd = (vbd_limited - vbd_new) * type_f;
        // Adjust d_prime node
        result[dp] -= delta_bd;
    }

    // ========================================================================
    // MOS Gate Voltage Limiting on V_GS (gate -- s_prime)
    // ========================================================================
    {
        const vgs_new = (result[g] - result[sp]) * type_f;
        const vgs_old = (x_old[g] - x_old[sp]) * type_f;

        var vgs_limited = vgs_new;
        if (vgs_new - vgs_old > 2.0 * vt) {
            vgs_limited = vgs_old + 2.0 * vt;
        } else if (vgs_old - vgs_new > 2.0 * vt) {
            vgs_limited = vgs_old - 2.0 * vt;
        }

        const delta_gs = (vgs_limited - vgs_new) * type_f;
        result[g] += delta_gs;
    }

    // ========================================================================
    // MOS Drain-Source Voltage Limiting on V_DS (d_prime -- s_prime)
    // ========================================================================
    {
        const vds_new = (result[dp] - result[sp]) * type_f;
        const vds_old = (x_old[dp] - x_old[sp]) * type_f;

        var vds_limited = vds_new;
        if (vds_new - vds_old > 2.0 * vt) {
            vds_limited = vds_old + 2.0 * vt;
        } else if (vds_old - vds_new > 2.0 * vt) {
            vds_limited = vds_old - 2.0 * vt;
        }

        const delta_ds = (vds_limited - vds_new) * type_f;
        result[dp] += delta_ds;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is);
    const is_stepped = is_orig + gmin * (1.0 - lambda);
    m.is = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================
// Expected values below are computed from the OLD pointer-form i()/q()
// implementation (verbatim f64 arithmetic, f32 parameter storage) and serve
// as the physics regression for the value-form migration.

const testing = std.testing;

test "mos6: on-state forward, linear region (defaults, vgs=2 vds=1)" {
    // Defaults: vto=0, kv=2, nv=0.5, kc=5e-5, nc=1, nvth=0.5, type=1, w=l=1u.
    // x = {d=1, g=2, s=0, b=0, dp=1, sp=0}: alpha_fwd=1, vgs_use=2, vds_eff=1.
    //   vth  = 0 * (1 + 0.5*1) = 0; vgst_pos = 2
    //   vdsat = 2*2^0.5 = 2.8284271; i_sat = 5e-5(f32)*(1e-6/1e-6)*2 ~ 1e-4
    //   r_ratio = 1/2.8284271 = 0.35355339; smooth clamp r_c ~ 0.35355339
    //   f_lin = 2*r_c - r_c^2 ~ 0.58210676 -> ids ~ 5.8210676e-5
    //   v_bd = -1 -> i_bd = 1e-14*(exp(-1/vt)-1) ~ -1e-14
    //   out[b]  = -(i_bs + i_bd) = ~ +1e-14
    //   out[dp] = ids + i_bd + gmin*(2-1) - gmin*(1-0) ~ 5.82106761e-5
    //   out[sp] = -ids + i_bs + gmin*2 + gmin*1 ~ -5.82106731e-5
    //   out[g]  = -gmin*(2-0) - gmin*(2-1) = -3e-12
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 2.0, 0.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -3.0e-12), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-30);
    try testing.expectApproxEqRel(@as(f64, 9.9999998245167e-15), out[3], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 5.8210676138129345e-5), out[4], 1e-12);
    try testing.expectApproxEqRel(@as(f64, -5.821067314812934e-5), out[5], 1e-12);
}

test "mos6: reversed vds (source/drain swap path)" {
    // x = {d=-1, g=2, s=0, b=0, dp=-1, sp=0}: v_ds_raw=-1 -> alpha_fwd=0,
    // vgs_use = 2-(-1) = 3, vbs_use = 0-(-1) = 1 (forward-biases the BS
    // junction: i_bs = 1e-14*(exp(1/vt)-1) ~ 6.178e2), mode = -1 flips ids.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.0, 2.0, 0.0, 0.0, -1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -5.000000000000005e-12), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -6.178250585647664e2), out[3], 1e-12);
    try testing.expectApproxEqRel(@as(f64, -7.410253375645625e-5), out[4], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 6.178251326673052e2), out[5], 1e-12);
}

test "mos6: forward-biased bulk junctions (vbs=vbd=0.6)" {
    // x = {0,0,0, b=0.6, 0,0}: vbs_use = v_bd = 0.6.
    //   i_bs = i_bd = 1e-14*(exp(0.6/vt)-1), vt = 8.617333262145e-5*tnom(f32)
    //        ~ 1e-14*(exp(23.196)-1) ~ 1.1871875e-4
    //   out[b] = -2*i_bs, out[dp] = out[sp] = +i_bs (ids=0: vgst<0).
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 0.0, 0.0, 0.6, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, -2.3743749622067648e-4), out[3], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.1871874811033824e-4), out[4], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.1871874811033824e-4), out[5], 1e-12);
}

test "mos6: body effect + channel-length modulation, saturation" {
    // gamma=0.5, lambda=0.02, vto=0.7, nvth=0; x = {3, 2, 0, -0.5, 3, 0}.
    //   vth = 0.7 + 0.5*(sqrt(0.6+0.5)-sqrt(0.6)) ~ 0.83714; vgst ~ 1.16286
    //   vdsat = 2*sqrt(1.16286) ~ 2.15672; vds=3 > vdsat (saturation)
    //   ids ~ kc*vgst*f_lin*(1 + 0.02*(3-vdsat)) ~ 5.9125e-5
    const model: Model = .{ .gamma = 0.5, .lambda = 0.02, .vto = 0.7, .nvth = 0 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3.0, 2.0, 0.0, -0.5, 3.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, -1.0e-12), out[1], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.999999960880181e-14), out[3], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 5.9125299615215105e-5), out[4], 1e-12);
    try testing.expectApproxEqRel(@as(f64, -5.912529863521511e-5), out[5], 1e-12);
}

test "mos6: overlap + junction depletion charges" {
    // cgso=cgdo=1e-10, cgbo=2e-10, cbs=cbd=1e-12; x = {1, 2, 0, -0.5, 1, 0}.
    //   q_gs = 1e-10*1e-6*2   = 2e-16;  q_gd = 1e-10*1e-6*1 = 1e-16
    //   q_gb = 2e-10*1e-6*2.5 = 5e-16 -> out[g] = 8e-16
    //   q_bs = (1e-12*0.8/0.5)*(1-(1+0.5/0.8)^0.5) ~ -4.3960e-13
    //   q_bd = (1e-12*0.8/0.5)*(1-(1+1.5/0.8)^0.5) ~ -1.1129e-12
    //   out[b]  = -q_gb + q_bs + q_bd ~ -1.55304e-12
    //   out[dp] = -q_gd - q_bd ~ 1.11283e-12; out[sp] = -q_gs - q_bs ~ 4.394e-13
    const model: Model = .{ .cgso = 1e-10, .cgdo = 1e-10, .cgbo = 2e-10, .cbs = 1e-12, .cbd = 1e-12 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, 2.0, 0.0, -0.5, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-30);
    try testing.expectApproxEqRel(@as(f64, 8.000000086613397e-16), out[1], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-30);
    try testing.expectApproxEqRel(@as(f64, -1.5530397965965826e-12), out[3], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.1128319922036086e-12), out[4], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 4.394078043843127e-13), out[5], 1e-12);
}
