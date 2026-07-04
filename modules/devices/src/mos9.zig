const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// MOS Model 9 (Philips MOS9 / SPICE Level 3)
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
    type_: i32 = 1,
    vto: f32 = 0,
    kp: f32 = 2.07189e-5,
    gamma: f32 = 0,
    phi: f32 = 0.6,
    rd: f32 = 0,
    rs: f32 = 0,
    u0: f32 = 600,
    theta: f32 = 0,
    vmax: f32 = 0,
    eta: f32 = 0,
    kappa: f32 = 0.2,
    alpha: f32 = 0,
    delta: f32 = 0,
    input_delta: f32 = 0,
    nfs: f32 = 0,
    nsub: f32 = 0,
    nss: f32 = 0,
    xj: f32 = 0,
    xd: f32 = 0,
    delvto: f32 = 0,
    tpg: i32 = 0,
    fc: f32 = 0.5,

    // --- Geometry Parameters ---
    tox: f32 = 1e-7,
    ld: f32 = 0,
    xl: f32 = 0,
    wd: f32 = 0,
    xw: f32 = 0,
    rsh: f32 = 0,

    // --- Junction Parameters ---
    is_: f32 = 1e-14,
    js: f32 = 0,
    pb: f32 = 0.8,
    cbd: f32 = 0,
    cbs: f32 = 0,
    cj: f32 = 0,
    mj: f32 = 0.5,
    cjsw: f32 = 0,
    mjsw: f32 = 0.33,

    // --- Overlap Capacitance Parameters ---
    cgso: f32 = 0,
    cgdo: f32 = 0,
    cgbo: f32 = 0,

    // --- Noise Parameters ---
    kf: f32 = 0,
    af: f32 = 1,

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

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    // RS branch: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    // Channel D' -- S' (incl. gate and bulk dependencies)
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
    // BD junction: B -- D'
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    // Gate row (no DC current, but derivatives may exist)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
// Overlap caps: G-S', G-D', G-B
// Intrinsic Meyer caps: G-S', G-D', G-B
// Junction caps: B-D', B-S'

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Gate charges
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.bulk) },
    // Bulk charges
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate) },
    // D' charges
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    // S' charges
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
};

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
// x-INDEPENDENT parameter/temperature/geometry prep (pure f64, no x)
// ============================================================================
// Everything here is a function of model + instance only. Hoisted out of eval
// so the S-typed tail is purely the terminal-voltage physics.

const IParams = struct {
    type_f: f64,
    vt0: f64,
    gamma: f64,
    phi: f64,
    rd: f64,
    rs: f64,
    theta: f64,
    vmax: f64,
    kappa: f64,
    alpha_clm: f64,
    is_val: f64,
    l_eff: f64,
    w_eff: f64,
    vt: f64,
    cox: f64,
    cox_tot: f64,
    beta0: f64,
    xj: f64,
    xd: f64,
    ld: f64,
    delvto: f64,
    mu0: f64,
    eta0: f64,
    delta_param: f64,
    nfs: f64,
    eps_si: f64,
    // physical constants used in the S tail
    gmin: f64,
    q_charge: f64,
    pi: f64,
};

fn prepI(model: *const Model, instance: *const Instance) IParams {
    // --- Physical constants ---
    const gmin: f64 = 1.0e-12;
    const eps_si: f64 = 11.7 * 8.854188e-12; // 1.035940e-10
    const eps_ox: f64 = 3.9 * 8.854188e-12; // 3.453133e-11
    const q_charge: f64 = 1.602176634e-19;
    const pi: f64 = 3.14159265358979323846;

    // --- Cast model parameters to f64 ---
    const type_f: f64 = @floatFromInt(model.type_);
    const vt0: f64 = @as(f64, model.vto);
    const kp: f64 = @as(f64, model.kp);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const rd: f64 = @as(f64, model.rd);
    const rs: f64 = @as(f64, model.rs);
    const mu0: f64 = @as(f64, model.u0);
    const theta: f64 = @as(f64, model.theta);
    const vmax: f64 = @as(f64, model.vmax);
    const eta0: f64 = @as(f64, model.eta);
    const kappa: f64 = @as(f64, model.kappa);
    const alpha_clm: f64 = @as(f64, model.alpha);
    const delta_param: f64 = @as(f64, model.delta);
    const nfs: f64 = @as(f64, model.nfs);
    const xj: f64 = @as(f64, model.xj);
    const xd: f64 = @as(f64, model.xd);
    const delvto: f64 = @as(f64, model.delvto);
    const tox: f64 = @as(f64, model.tox);
    const ld: f64 = @as(f64, model.ld);
    const xl: f64 = @as(f64, model.xl);
    const wd: f64 = @as(f64, model.wd);
    const xw: f64 = @as(f64, model.xw);
    const is_val: f64 = @as(f64, model.is_);
    const tnom: f64 = @as(f64, model.tnom);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);

    // --- Effective geometry ---
    const l_eff: f64 = @max(l_inst - 2.0 * ld + xl, 1.0e-9);
    const w_eff: f64 = @max(w_inst - 2.0 * wd + xw, 1.0e-9);

    // --- Thermal voltage ---
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);

    // --- Oxide capacitance ---
    const cox: f64 = eps_ox / tox;
    const cox_tot: f64 = cox * l_eff * w_eff;

    // --- Transconductance base ---
    const beta0: f64 = kp * w_eff / l_eff;

    return .{
        .type_f = type_f,
        .vt0 = vt0,
        .gamma = gamma,
        .phi = phi,
        .rd = rd,
        .rs = rs,
        .theta = theta,
        .vmax = vmax,
        .kappa = kappa,
        .alpha_clm = alpha_clm,
        .is_val = is_val,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .vt = vt,
        .cox = cox,
        .cox_tot = cox_tot,
        .beta0 = beta0,
        .xj = xj,
        .xd = xd,
        .ld = ld,
        .delvto = delvto,
        .mu0 = mu0,
        .eta0 = eta0,
        .delta_param = delta_param,
        .nfs = nfs,
        .eps_si = eps_si,
        .gmin = gmin,
        .q_charge = q_charge,
        .pi = pi,
    };
}

pub const PrepCache = struct { dc: IParams, q: QParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = prepI(model, instance), .q = prepQ(model, instance) };
}

// ============================================================================
// DC Current Function (eval) — value-form, generic over scalar S
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

    const p = &pc.dc;

    // ========================================================================
    // PMOS handling: type_f flips all terminal voltages
    // ========================================================================
    const vgs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(p.type_f);
    const vbs_raw = x[b].sub(x[sp]).scale(p.type_f);

    // ========================================================================
    // Source-drain reversal (branchless in original)
    // ========================================================================
    const vds_neg = vds_raw.minC(0.0); // @min(vds_raw, 0.0)
    const vgs_eff = vgs_raw.sub(vds_neg);
    const vbs_eff = vbs_raw.sub(vds_neg);
    const vds_abs = vds_raw.abs(); // @abs(vds_raw)

    // Smooth sign function for reversal: vds_raw / (|vds_raw| + 1e-30)
    const mode = vds_raw.div(vds_abs.addC(1.0e-30));

    // ========================================================================
    // Short-channel effect (fshort)
    // ========================================================================
    const phi_bs = vbs_eff.neg().addC(p.phi).maxC(0.001); // @max(phi - vbs_eff, 0.001)

    // wps = xd*sqrt(phi_bs) ; wp_over_xj = wps/xj  (guarded on params xj,xd)
    const sc_active = p.xj > 0.0 and p.xd > 0.0;
    // wp_over_xj as an S value (only used when sc_active)
    const wp_over_xj = if (sc_active)
        phi_bs.sqrt().scale(p.xd).scale(1.0 / p.xj)
    else
        S.con(0.0);

    // Polynomial fit coefficients
    const c0: f64 = 0.0631353;
    const c1: f64 = 0.8013292;
    const c2: f64 = -0.01110777;

    // wc_over_xj = c0 + c1*wp + c2*wp^2
    const wc_over_xj = wp_over_xj.scale(c1).add(wp_over_xj.mul(wp_over_xj).scale(c2)).addC(c0);
    const xj_guard: f64 = @max(p.xj, 1.0e-30);
    // arg_a = wc_over_xj + ld/xj
    const arg_a = wc_over_xj.addC(p.ld / xj_guard);
    // arg_c = wp/(1+wp)
    const arg_c = wp_over_xj.div(wp_over_xj.addC(1.0));
    // arg_b = sqrt(max(1 - arg_c^2, 1e-20))
    const arg_b = arg_c.mul(arg_c).neg().addC(1.0).maxC(1.0e-20).sqrt();

    // fshort = 1 - (xj/l_eff)*(arg_a*arg_b - ld/xj)
    const fshort_calc = arg_a.mul(arg_b).addC(-(p.ld / xj_guard)).scale(p.xj / p.l_eff).neg().addC(1.0);
    const fshort = if (sc_active) fshort_calc else S.con(1.0);

    // ========================================================================
    // Body effect
    // ========================================================================
    // gamma_s = gamma * fshort
    const gamma_s = fshort.scale(p.gamma);
    const sqrt_phi_bs = phi_bs.sqrt();
    // fbody_s = gamma_s / (2*sqrt_phi_bs)
    const fbody_s = gamma_s.div(sqrt_phi_bs.scale(2.0));

    // Narrow-channel factor (x-independent)
    const fnarrow: f64 = p.delta_param * p.pi * p.eps_si / (2.0 * p.cox * p.w_eff);

    // fbody = fbody_s + fnarrow
    const fbody = fbody_s.addC(fnarrow);
    // onfbdy = 1/(1+fbody)
    const onfbdy = S.con(1.0).div(fbody.addC(1.0));

    // Charge term: qb_over_cox = gamma_s*sqrt_phi_bs + fnarrow*phi_bs
    const qb_over_cox = gamma_s.mul(sqrt_phi_bs).add(phi_bs.scale(fnarrow));

    // ========================================================================
    // Threshold voltage
    // ========================================================================
    const sqrt_phi: f64 = @sqrt(@max(p.phi, 1.0e-30));
    const vbi: f64 = p.vt0 + p.delvto - p.gamma * sqrt_phi;

    // DIBL eta factor (x-independent)
    const eta_eff: f64 = p.eta0 * 8.15e-22 / (p.cox * p.l_eff * p.l_eff * p.l_eff);
    // vbix = vbi - eta_eff*vds_abs
    const vbix = vds_abs.scale(-eta_eff).addC(vbi);

    // vth = vbix + qb_over_cox
    const vth = vbix.add(qb_over_cox);

    // ========================================================================
    // Weak inversion (subthreshold)
    // ========================================================================
    // cs_over_cox_val is x-independent
    const cs_over_cox_val: f64 = p.q_charge * p.nfs * 1.0e4 * p.l_eff * p.w_eff / p.cox_tot;
    // cd_over_cox = qb_over_cox / (2*phi_bs)
    const cd_over_cox = qb_over_cox.div(phi_bs.scale(2.0));
    // xn = 1 + cs_over_cox + cd_over_cox   (only if nfs>0)
    const xn_nfs = cd_over_cox.addC(1.0 + cs_over_cox_val);
    const xn = if (p.nfs > 0.0) xn_nfs else S.con(1.0);

    // von = vth + vt*xn (if nfs>0) else vth
    const von_nfs = vth.add(xn.scale(p.vt));
    const von = if (p.nfs > 0.0) von_nfs else vth;

    // ========================================================================
    // Effective gate voltage: vgs_x = max(vgs_eff, von)
    // ========================================================================
    const vgs_x = vgs_eff.max(von);

    // ========================================================================
    // Mobility degradation: fgate = 1/(1 + theta*(vgs_x - vth))
    // ========================================================================
    const fgate = vgs_x.sub(vth).scale(p.theta).addC(1.0);
    const fgate_inv = S.con(1.0).div(fgate);
    // mu_s = mu0*1e-4*fgate_inv  (mu_s only feeds vdsc)
    const mu_s = fgate_inv.scale(p.mu0 * 1.0e-4);

    // ========================================================================
    // Saturation voltage
    // ========================================================================
    // vdsat_0 = (vgs_x - vth)*onfbdy
    const vdsat_0 = vgs_x.sub(vth).mul(onfbdy);

    // vdsc = (l_eff*vmax) / max(mu_s, 1e-30)
    const mu_s_clamped = mu_s.maxC(1.0e-30);
    const vdsc = S.con(p.l_eff * p.vmax).div(mu_s_clamped);

    // vdsat_vmax = vdsat_0 + vdsc - sqrt(vdsat_0^2 + vdsc^2)
    const vdsat_vmax = vdsat_0.add(vdsc).sub(
        vdsat_0.mul(vdsat_0).add(vdsc.mul(vdsc)).sqrt(),
    );
    const vdsat = if (p.vmax > 0.0) vdsat_vmax else vdsat_0;

    // ========================================================================
    // Effective drain-source voltage: vds_x = min(vds_abs, vdsat)
    // ========================================================================
    const vds_x = vds_abs.min(vdsat);

    // ========================================================================
    // Drain current (linear/saturation unified)
    // ========================================================================
    // ids_norm = (vgs_x - vth - 0.5*(1+fbody)*vds_x)*vds_x
    const half_term = fbody.addC(1.0).scale(0.5).mul(vds_x);
    const ids_norm = vgs_x.sub(vth).sub(half_term).mul(vds_x);
    // beta_eff = beta0*fgate  (old fgate = 1/(1+theta*(vgs_x-vth)) = fgate_inv)
    const beta_eff = fgate_inv.scale(p.beta0);
    var ids = beta_eff.mul(ids_norm);

    // ========================================================================
    // Velocity saturation correction: fdrain = 1/(1 + vds_x/vdsc)
    // ========================================================================
    const fdrain_vmax = S.con(1.0).div(vds_x.div(vdsc).addC(1.0));
    const fdrain = if (p.vmax > 0.0) fdrain_vmax else S.con(1.0);
    ids = ids.mul(fdrain);

    // ========================================================================
    // Channel-length modulation (CLM)
    // ========================================================================
    // vds_over = max(vds_abs - vdsat, 0)
    const vds_over = vds_abs.sub(vdsat).maxC(0.0);
    // delta_l = sqrt(max(kappa*alpha*vds_over, 0))
    const delta_l = vds_over.scale(p.kappa * p.alpha_clm).maxC(0.0).sqrt();
    // dl_over_leff = min(delta_l/l_eff, 0.499)
    const dl_over_leff = delta_l.scale(1.0 / p.l_eff).minC(0.499);
    // fclm = 1/(1 - dl_over_leff)
    const fclm_calc = S.con(1.0).div(dl_over_leff.neg().addC(1.0));
    const fclm = if (p.alpha_clm > 0.0 and p.kappa > 0.0) fclm_calc else S.con(1.0);
    ids = ids.mul(fclm);

    // ========================================================================
    // Weak-inversion current correction
    // ========================================================================
    // w_arg = (vgs_eff - von)/(vt/xn)  = (vgs_eff - von)*xn/vt
    // clamp to [-40, 40]; w_fact = min(exp(w_arg), 1)   (only if nfs>0)
    const w_arg_raw = vgs_eff.sub(von).mul(xn).scale(1.0 / p.vt);
    const w_arg = w_arg_raw.minC(40.0).maxC(-40.0);
    const w_fact_nfs = w_arg.exp().minC(1.0);
    const w_fact = if (p.nfs > 0.0) w_fact_nfs else S.con(1.0);
    ids = ids.mul(w_fact);

    // ========================================================================
    // External channel current (with reversal and PMOS sign)
    // ========================================================================
    const i_ds_ext = ids.mul(mode).scale(p.type_f);

    // ========================================================================
    // Parasitic resistance currents (x-dependent through node voltages)
    // ========================================================================
    const g_d: f64 = if (p.rd > 0.0) 1.0 / p.rd else 1.0e12;
    const g_s: f64 = if (p.rs > 0.0) 1.0 / p.rs else 1.0e12;

    const i_rd = x[d].sub(x[dp]).scale(g_d);
    const i_rs = x[s].sub(x[sp]).scale(g_s);

    // ========================================================================
    // Bulk junction diode currents (NOT type-flipped; direct node voltages)
    // ========================================================================
    const vbs_jct = x[b].sub(x[sp]);
    const vbd_jct = x[b].sub(x[dp]);

    // arg_bs = min(vbs_jct/vt, 80)
    const arg_bs = vbs_jct.scale(1.0 / p.vt).minC(80.0);
    // i_bs = is*(exp(arg_bs)-1) + gmin*vbs_jct
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.is_val).add(vbs_jct.scale(p.gmin));

    const arg_bd = vbd_jct.scale(1.0 / p.vt).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.is_val).add(vbd_jct.scale(p.gmin));

    // ========================================================================
    // KCL node assembly
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d] = i_rd.neg();
    out[dp] = i_rd.sub(i_ds_ext).add(i_bd);
    out[g] = S.con(0.0);
    out[s] = i_rs.neg();
    out[sp] = i_rs.add(i_ds_ext).add(i_bs);
    out[b] = i_bs.neg().sub(i_bd);
    return out;
}

// ============================================================================
// Charge Function (q) — value-form, generic over scalar S
// ============================================================================

const QParams = struct {
    cgso: f64,
    cgdo: f64,
    cgbo: f64,
    cbd_param: f64,
    cbs_param: f64,
    pb: f64,
    mj: f64,
    gamma: f64,
    phi: f64,
    vt0: f64,
    delvto: f64,
    l_eff: f64,
    w_eff: f64,
    cox_tot: f64,
};

fn prepQ(model: *const Model, instance: *const Instance) QParams {
    // --- Physical constants ---
    const eps_ox: f64 = 3.9 * 8.854188e-12;

    // --- Cast model parameters to f64 ---
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cbd_param: f64 = @as(f64, model.cbd);
    const cbs_param: f64 = @as(f64, model.cbs);
    const pb: f64 = @as(f64, model.pb);
    const mj: f64 = @as(f64, model.mj);
    const gamma: f64 = @as(f64, model.gamma);
    const phi: f64 = @as(f64, model.phi);
    const vt0: f64 = @as(f64, model.vto);
    const delvto: f64 = @as(f64, model.delvto);
    const tox: f64 = @as(f64, model.tox);
    const ld: f64 = @as(f64, model.ld);
    const xl: f64 = @as(f64, model.xl);
    const wd: f64 = @as(f64, model.wd);
    const xw: f64 = @as(f64, model.xw);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);

    // --- Effective geometry ---
    const l_eff: f64 = @max(l_inst - 2.0 * ld + xl, 1.0e-9);
    const w_eff: f64 = @max(w_inst - 2.0 * wd + xw, 1.0e-9);

    // --- Oxide capacitance ---
    const cox: f64 = eps_ox / tox;
    const cox_tot: f64 = cox * l_eff * w_eff;

    return .{
        .cgso = cgso,
        .cgdo = cgdo,
        .cgbo = cgbo,
        .cbd_param = cbd_param,
        .cbs_param = cbs_param,
        .pb = pb,
        .mj = mj,
        .gamma = gamma,
        .phi = phi,
        .vt0 = vt0,
        .delvto = delvto,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .cox_tot = cox_tot,
    };
}

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);

    const p = &pc.q;

    // ========================================================================
    // Terminal voltages (direct, not type-flipped)
    // ========================================================================
    const v_gs = x[g].sub(x[sp]);
    const v_gd = x[g].sub(x[dp]);
    const v_gb = x[g].sub(x[b]);
    const v_bs = x[b].sub(x[sp]);
    const v_bd = x[b].sub(x[dp]);
    const v_ds = x[dp].sub(x[sp]);

    // ========================================================================
    // Gate overlap charges
    // ========================================================================
    const q_gs_ov = v_gs.scale(p.cgso * p.w_eff);
    const q_gd_ov = v_gd.scale(p.cgdo * p.w_eff);
    const q_gb_ov = v_gb.scale(p.cgbo * p.l_eff);

    // ========================================================================
    // Intrinsic gate charges (Smooth Meyer Model)
    // ========================================================================
    // Simplified threshold for charge model (without short-channel effects)
    const sqrt_phi: f64 = @sqrt(@max(p.phi, 1.0e-30));
    const vbi: f64 = p.vt0 + p.delvto - p.gamma * sqrt_phi;

    // phi_bs_q = max(phi - v_bs, 0.001)
    const phi_bs_q = v_bs.neg().addC(p.phi).maxC(0.001);
    const sqrt_phi_bs_q = phi_bs_q.sqrt();
    // vth_q = vbi + gamma*sqrt_phi_bs_q
    const vth_q = sqrt_phi_bs_q.scale(p.gamma).addC(vbi);

    // v_gst = v_gs - vth_q
    const v_gst = v_gs.sub(vth_q);
    // vdsat_q = max(v_gst, 0.01)
    const vdsat_q = v_gst.maxC(0.01);

    // Smooth inversion transition function
    // v_gst_pos = max(v_gst, 0); f_inv = v_gst_pos/(v_gst_pos+0.1)
    const v_gst_pos = v_gst.maxC(0.0);
    const f_inv = v_gst_pos.div(v_gst_pos.addC(0.1));

    // Smooth saturation factor
    // vds_abs_q = |v_ds| + 1e-20; f_sat = vds_abs_q/(vdsat_q + vds_abs_q)
    const vds_abs_q = v_ds.abs().addC(1.0e-20);
    const f_sat = vds_abs_q.div(vdsat_q.add(vds_abs_q));

    // Intrinsic capacitances
    // cgs_intr = (2/3)*cox_tot*f_inv
    const cgs_intr = f_inv.scale((2.0 / 3.0) * p.cox_tot);
    // cgd_intr = (2/3)*cox_tot*f_inv*(1 - f_sat)
    const cgd_intr = f_inv.scale((2.0 / 3.0) * p.cox_tot).mul(f_sat.neg().addC(1.0));
    // cgb_intr = cox_tot*(1 - f_inv)
    const cgb_intr = f_inv.neg().addC(1.0).scale(p.cox_tot);

    // Intrinsic charges
    const q_gs_intr = cgs_intr.mul(v_gs);
    const q_gd_intr = cgd_intr.mul(v_gd);
    const q_gb_intr = cgb_intr.mul(v_gb);

    // ========================================================================
    // Total gate charges
    // ========================================================================
    const q_gs = q_gs_ov.add(q_gs_intr);
    const q_gd = q_gd_ov.add(q_gd_intr);
    const q_gb = q_gb_ov.add(q_gb_intr);

    // ========================================================================
    // Bulk-junction depletion charges
    // ========================================================================
    // Standard SPICE junction charge model
    const one_minus_mj: f64 = 1.0 - p.mj;

    // arg_bs = max(1 - v_bs/pb, 0.001)
    const arg_bs = v_bs.scale(-1.0 / p.pb).addC(1.0).maxC(0.001);
    // pow_bs = exp(one_minus_mj*log(arg_bs)) = arg_bs^one_minus_mj
    const pow_bs = arg_bs.log().scale(one_minus_mj).exp();
    // q_bs = (cbs*pb/one_minus_mj)*(1 - pow_bs)
    const q_bs_calc = pow_bs.neg().addC(1.0).scale(p.cbs_param * p.pb / one_minus_mj);
    const q_bs = if (p.cbs_param > 0.0) q_bs_calc else S.con(0.0);

    const arg_bd = v_bd.scale(-1.0 / p.pb).addC(1.0).maxC(0.001);
    const pow_bd = arg_bd.log().scale(one_minus_mj).exp();
    const q_bd_calc = pow_bd.neg().addC(1.0).scale(p.cbd_param * p.pb / one_minus_mj);
    const q_bd = if (p.cbd_param > 0.0) q_bd_calc else S.con(0.0);

    // ========================================================================
    // KCL charge stamp
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d] = S.con(0.0);
    out[dp] = q_gd.neg().sub(q_bd);
    out[g] = q_gs.add(q_gd).add(q_gb);
    out[s] = S.con(0.0);
    out[sp] = q_gs.neg().sub(q_bs);
    out[b] = q_gb.neg().add(q_bs).add(q_bd);
    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const vt0: f64 = @as(f64, model.vto);
    const tnom: f64 = @as(f64, model.tnom);
    const vt: f64 = 8.617333e-5 * (tnom + 273.15);
    const v_crit: f64 = 0.6166;

    var result = x_new;

    // ========================================================================
    // 1. FET Gate Voltage Limiting (fetLimit) for V_GS
    // ========================================================================
    {
        const vgs_new = result[g] - result[sp];
        const vgs_old = x_old[g] - x_old[sp];
        const dv = vgs_new - vgs_old;
        const vtsthi = @abs(2.0 * (vgs_old - vt0)) + 2.0;
        const vtstlo = vtsthi * 0.5 + 2.0;
        const vtox = vt0 + 3.5;
        var vgs_limited = vgs_new;

        if (vgs_old >= vtox) {
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vgs_old - vtstlo);
            } else {
                vgs_limited = @min(vgs_new, vgs_old + vtsthi);
            }
        } else if (vgs_old >= vt0) {
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vt0 - 0.5);
            } else {
                vgs_limited = @min(vgs_new, vgs_old + vtsthi);
            }
        } else {
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vgs_old - vtstlo);
            } else {
                vgs_limited = @min(vgs_new, vt0 + 0.5);
            }
        }

        const delta_gs = vgs_limited - vgs_new;
        result[g] = result[g] + delta_gs;
    }

    // ========================================================================
    // 2. Drain-Source Voltage Limiting (limvds)
    // ========================================================================
    {
        const vds_new = result[dp] - result[sp];
        const vds_old = x_old[dp] - x_old[sp];
        const dv = vds_new - vds_old;
        var vds_limited = vds_new;

        if (vds_old >= 3.5) {
            if (dv <= 0.0) {
                vds_limited = @max(vds_new, -0.5 * vds_old);
            } else {
                vds_limited = @min(vds_new, 2.0 * vds_old);
            }
        } else {
            if (vds_new > 4.0) {
                vds_limited = 4.0;
            }
        }

        const delta_ds = vds_limited - vds_new;
        result[dp] = result[dp] + delta_ds;
    }

    // ========================================================================
    // 3. PN Junction Limiting (pnLimit) for V_BS
    // ========================================================================
    {
        const vbs_new = result[b] - result[sp];
        const vbs_old = x_old[b] - x_old[sp];
        var vbs_limited = vbs_new;

        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = 1.0 + (vbs_new - vbs_old) / vt;
                vbs_limited = if (arg > 0.0) vbs_old + vt * @log(arg) else v_crit;
            } else {
                vbs_limited = vt * @log(vbs_new / vt);
            }
        }

        const delta_bs = vbs_limited - vbs_new;
        result[b] = result[b] + delta_bs;
    }

    // ========================================================================
    // 4. PN Junction Limiting (pnLimit) for V_BD
    //    (re-adjusts D' node after B was adjusted above)
    // ========================================================================
    {
        const vbd_new = result[b] - result[dp];
        const vbd_old = x_old[b] - x_old[dp];
        var vbd_limited = vbd_new;

        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = 1.0 + (vbd_new - vbd_old) / vt;
                vbd_limited = if (arg > 0.0) vbd_old + vt * @log(arg) else v_crit;
            } else {
                vbd_limited = vt * @log(vbd_new / vt);
            }
        }

        const delta_bd = vbd_limited - vbd_new;
        result[dp] = result[dp] - delta_bd;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const is_orig: f64 = @as(f64, model.is_);
    const is_stepped = is_orig + gmin_step * (1.0 - lambda);
    m.is_ = @floatCast(is_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const std_testing = std.testing;

test "mos9: NMOS on-state drain current (saturation region)" {
    // Simple long-channel NMOS: kp default, vto=1, gamma=0, no vmax/theta/clm/nfs.
    // W=L=1u so beta0 = kp*w_eff/l_eff = kp (w_eff=l_eff=1e-6).
    // Bias: VG=3, VD'=3, VS'=0, VB=0, VD=3, VS=0.  (rd=rs=0 -> huge g, but
    // D=D' and S=S' so i_rd=i_rs=0.)
    //
    // Hand computation (NMOS, type_f=1):
    //   vgs_raw=3, vds_raw=3, vbs_raw=0
    //   vds_neg=min(3,0)=0 -> vgs_eff=3, vbs_eff=0, vds_abs=3, mode=+1
    //   phi_bs=max(0.6-0,0.001)=0.6
    //   fshort=1 (xj=xd=0); gamma_s=0; fbody_s=0; fnarrow: delta=0 ->0
    //     -> fbody=0, onfbdy=1, qb_over_cox=0
    //   vbi = vto+delvto - gamma*sqrt(phi) = 1
    //   eta_eff=0 -> vbix=1 ; vth=1
    //   nfs=0 -> xn=1, von=vth=1
    //   vgs_x=max(3,1)=3
    //   theta=0 -> fgate=1, mu_s=mu0*1e-4 (unused since vmax=0)
    //   vmax=0 -> vdsat=vdsat_0=(vgs_x-vth)*onfbdy=(3-1)*1=2
    //   vds_x=min(3,2)=2
    //   ids_norm=(3-1-0.5*(1)*2)*2=(2-1)*2=2
    //   beta_eff=beta0*fgate=kp*1=2.07189e-5
    //   ids=beta_eff*2=4.14378e-5 ; fdrain=1 ; fclm=1 ; w_fact=1
    //   i_ds_ext = ids*mode*type_f = 4.14378e-5
    //   junctions: vbs_jct=0-0=0 -> i_bs=0 ; vbd_jct=0-3=-3 -> i_bd~=is*(exp(-3/vt)-1)+gmin*(-3)
    //     vt=8.617333e-5*300.15=0.025864... -> exp(-116)~0 -> i_bd ~= -is - gmin*3 ~= -1e-14 -3e-12 ~= -3.01e-12
    //   out[sp] = i_rs + i_ds_ext + i_bs = 0 + 4.14378e-5 + 0
    const model: Model = .{ .vto = 1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3, 3, 0, 0, 3, 0 }, &model, &inst, 0);
    const sp = @intFromEnum(U.source_prime);
    const dp = @intFromEnum(U.drain_prime);
    // Channel current flows into source_prime, out of drain_prime (approx,
    // ignoring the tiny bulk diode leakage on dp).
    try std_testing.expectApproxEqAbs(@as(f64, 4.14378e-5), out[sp], 1e-9);
    // out[dp] = i_rd - i_ds_ext + i_bd = 0 - 4.14378e-5 + (~-3.01e-12)
    try std_testing.expectApproxEqAbs(@as(f64, -4.14378e-5), out[dp], 1e-9);
}

test "mos9: mobility degradation (theta != 0) exercises fgate reciprocal" {
    // Regression for the beta_eff sign/reciprocal bug: OLD physics is
    //   fgate = 1/(1 + theta*(vgs_x - vth)) ; beta_eff = beta0*fgate.
    // A buggy migration multiplies beta0 by the DENOMINATOR instead, inflating
    // ids by fgate^-2. This test uses theta=0.05 so fgate != 1 and the two
    // forms diverge by ~21%.
    //
    // Same long-channel NMOS as the saturation test but theta=0.05:
    //   vto=1, gamma=0, vmax=0, W=L=1u -> beta0 = kp = 2.07189e-5
    //   Bias VG=3, VD'=3, VS'=0, VB=0 -> vgs_x=3, vth=1, vds_abs=3
    //   vdsat=vdsat_0=(vgs_x-vth)*onfbdy=(3-1)*1=2 ; vds_x=min(3,2)=2
    //   ids_norm=(3-1-0.5*1*2)*2=(2-1)*2=2
    //   fgate = 1/(1+0.05*(3-1)) = 1/1.1 = 0.9090909091
    //   beta_eff = beta0*fgate = 2.07189e-5*0.9090909091 = 1.8835363636e-5
    //   ids = beta_eff*ids_norm = 1.8835363636e-5*2 = 3.7670727273e-5
    //   fdrain=1 (vmax=0), fclm=1, w_fact=1 -> i_ds_ext = 3.7670727e-5
    //   (buggy form would give beta0*1.1*2 = 4.558158e-5 -> fails)
    const model: Model = .{ .vto = 1, .theta = 0.05 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3, 3, 0, 0, 3, 0 }, &model, &inst, 0);
    const sp = @intFromEnum(U.source_prime);
    const dp = @intFromEnum(U.drain_prime);
    try std_testing.expectApproxEqAbs(@as(f64, 3.7670727e-5), out[sp], 1e-9);
    // out[dp] = -i_ds_ext + tiny bulk-diode leakage (~-3e-12)
    try std_testing.expectApproxEqAbs(@as(f64, -3.7670727e-5), out[dp], 1e-9);
}

test "mos9: cutoff (VGS below threshold) -> negligible channel current" {
    // VG=0 => vgs_eff=0, von=vth=1 => vgs_x=max(0,1)=1 => (vgs_x-vth)=0 =>
    // vdsat=0 => vds_x=0 => ids_norm=0 => ids=0. Only bulk diode leakage.
    const model: Model = .{ .vto = 1 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3, 0, 0, 0, 3, 0 }, &model, &inst, 0);
    const sp = @intFromEnum(U.source_prime);
    // out[sp] = i_bs (vbs=0 -> 0). Channel off.
    try std_testing.expectApproxEqAbs(@as(f64, 0.0), out[sp], 1e-12);
}

test "mos9: gate charge in strong inversion" {
    // cgso=cgdo=cgbo=0 (no overlap). Meyer intrinsic only.
    // W=L=1u, tox=1e-7 default => cox = eps_ox/tox = 3.453133e-11/1e-7? no:
    //   eps_ox=3.9*8.854188e-12=3.453133e-11 ; cox=eps_ox/tox=3.453133e-11/1e-7
    //     =3.453133e-4 ; cox_tot=cox*l_eff*w_eff=3.453133e-4*1e-6*1e-6=3.453133e-16
    // Bias VG=3, VS'=0, VD'=0, VB=0:
    //   v_gs=3, v_gd=3, v_gb=3, v_bs=0, v_bd=0, v_ds=0
    //   vbi = vto+delvto-gamma*sqrt(phi)=1 (vto=1,gamma=0)
    //   phi_bs_q=max(0.6-0,0.001)=0.6 ; vth_q=vbi+gamma*sqrt(..)=1
    //   v_gst=3-1=2 ; v_gst_pos=2 ; f_inv=2/(2+0.1)=0.952380952...
    //   vds_abs_q=0+1e-20 ; vdsat_q=max(2,0.01)=2 ; f_sat=1e-20/(2+1e-20)~=0
    //   cgs_intr=(2/3)*cox_tot*f_inv=(0.66667)*3.453133e-16*0.95238=2.19246e-16
    //   q_gs_intr=cgs_intr*v_gs=2.19246e-16*3=6.5774e-16
    //   q_gd_intr=(2/3)*cox_tot*f_inv*(1-f_sat)*v_gd ~= same as q_gs_intr = 6.5774e-16
    //   cgb_intr=cox_tot*(1-f_inv)=3.453133e-16*0.047619=1.64435e-17
    //   q_gb_intr=cgb_intr*3=4.93304e-17
    //   q_bs=0, q_bd=0 (cbs=cbd=0)
    //   out[g]=q_gs+q_gd+q_gb = 6.5774e-16+6.5774e-16+4.93304e-17 = 1.36481e-15
    const model: Model = .{ .vto = 1 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0, 3, 0, 0, 0, 0 }, &model, &inst, 0);
    const g = @intFromEnum(U.gate);
    try std_testing.expectApproxEqAbs(@as(f64, 1.36481e-15), out[g], 1e-9);
}
