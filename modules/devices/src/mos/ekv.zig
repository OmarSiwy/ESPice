const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: EKV 2.6 MOSFET
//
//   D (drain)  -- external
//   G (gate)   -- external
//   S (source) -- external
//   B (bulk)   -- external
//
// No internal nodes: source/drain resistance folded into Id analytically
// (1/(1 + gms*Rs + gds*Rd) correction from the VA reference).
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Polarity ---
    type_: i32 = 1, // +1 = NMOS, -1 = PMOS

    // --- Process ---
    cox: f32 = 2.0e-3, // Gate oxide capacitance per unit area (F/m^2)
    xj: f32 = 300e-9, // Junction depth (m)

    // --- Threshold voltage ---
    vto: f32 = 0.5, // Long-channel threshold voltage (V)
    tcv: f32 = 1.0e-3, // Threshold voltage temperature coefficient (V/K)
    gamma: f32 = 0.7, // Body effect parameter (sqrt(V))
    phi: f32 = 0.5, // Bulk Fermi potential (V)

    // --- Mobility ---
    kp: f32 = 150e-6, // Transconductance parameter (A/V^2)
    bex: f32 = -1.5, // Mobility temperature exponent
    theta: f32 = 0.0, // Mobility reduction coefficient (1/V)
    e0: f32 = 1.0e8, // Mobility reduction coefficient (V/m)

    // --- Velocity saturation / CLM ---
    ucrit: f32 = 2.0e6, // Longitudinal critical field (V/m)
    ucex: f32 = 0.8, // Critical field temperature exponent
    lambda: f32 = 0.8, // Depletion length coefficient (CLM)

    // --- Geometry corrections ---
    dl: f32 = -0.01e-6, // Channel length correction (m)
    dw: f32 = -0.01e-6, // Channel width correction (m)

    // --- Short/narrow channel ---
    weta: f32 = 0.2, // Narrow-channel effect coefficient
    leta: f32 = 0.3, // Short-channel effect coefficient
    q0: f32 = 230e-6, // RSCE peak charge density (As/m^2)
    lk: f32 = 0.4e-6, // RSCE characteristic length (m)

    // --- Impact ionization ---
    iba: f32 = 5.0e8, // First impact ionization coefficient (1/m)
    ibb: f32 = 4.0e8, // Second impact ionization coefficient (V/m)
    ibbt: f32 = 9.0e-4, // Temperature coefficient for IBB (1/K)
    ibn: f32 = 1.0, // Saturation voltage factor for impact ionization

    // --- Series resistance ---
    rsh: f32 = 0.0, // Sheet resistance (Ohm/sq)
    hdif: f32 = 0.0, // Half diffusion length

    // --- Overlap capacitance ---
    cgso: f32 = 1.5e-10, // Gate-source overlap cap per unit width (F/m)
    cgdo: f32 = 1.5e-10, // Gate-drain overlap cap per unit width (F/m)
    cgbo: f32 = 4.0e-10, // Gate-bulk overlap cap per unit length (F/m)

    // --- Junction diode ---
    n_junc: f32 = 1.0, // Junction ideality factor
    js: f32 = 1.0e-9, // Junction saturation current density (A/m^2)
    jsw: f32 = 1.0e-12, // Sidewall junction saturation current density (A/m)
    jswg: f32 = 1.0e-12, // Gate-edge sidewall junction sat current density (A/m)
    pb: f32 = 0.8, // Bottom junction built-in potential (V)
    pbsw: f32 = 0.6, // Sidewall junction built-in potential (V)
    pbswg: f32 = 0.6, // Gate-edge sidewall junction built-in potential (V)
    cj: f32 = 1.0e-9, // Bottom junction cap per unit area (F/m^2)
    cjsw: f32 = 1.0e-12, // Sidewall junction cap per unit perimeter (F/m)
    cjswg: f32 = 1.0e-12, // Gate-edge sidewall junction cap per unit width (F/m)
    mj: f32 = 0.9, // Bottom junction grading coefficient
    mjsw: f32 = 0.7, // Sidewall junction grading coefficient
    mjswg: f32 = 0.7, // Gate-edge sidewall junction grading coefficient
    bv: f32 = 10.0, // Junction breakdown voltage (V)
    xjbv: f32 = 0.0, // Junction breakdown multiplier
    xti: f32 = 3.0, // IS temperature exponent

    // --- Junction temperature coefficients ---
    tcj: f32 = 0.0,
    tcjsw: f32 = 0.0,
    tcjswg: f32 = 0.0,
    tpb: f32 = 0.0,
    tpbsw: f32 = 0.0,
    tpbswg: f32 = 0.0,

    // --- Tunneling ---
    njts: f32 = 1.0,
    njtssw: f32 = 1.0,
    njtsswg: f32 = 1.0,
    vts: f32 = 0.0,
    vtssw: f32 = 0.0,
    vtsswg: f32 = 0.0,
    tnjts: f32 = 0.0,
    tnjtssw: f32 = 0.0,
    tnjtsswg: f32 = 0.0,

    // --- Mismatch ---
    avto: f32 = 1e-6, // Area related VTO mismatch
    akp: f32 = 1e-6, // Area related KP mismatch
    agamma: f32 = 1e-6, // Area related GAMMA mismatch

    // --- Noise ---
    kf: f32 = 0.0, // Flicker noise coefficient
    af: f32 = 1.0, // Flicker noise exponent

    // --- Temperature ---
    tnom: f32 = 27.0, // Nominal temperature (degC)
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 1e-5, // Channel length (m)
    w: f32 = 1e-5, // Channel width (m)
    m: f32 = 1, // Parallel multiplier
    ns: f32 = 1, // Series multiplier
    temp: f32 = 300.15, // Device temperature (K)
    dtemp: f32 = 0, // Temperature offset (K)
    as_: f32 = 0, // Source junction area (m^2)
    ad: f32 = 0, // Drain junction area (m^2)
    ps: f32 = 0, // Source junction perimeter (m)
    pd: f32 = 0, // Drain junction perimeter (m)
    nrs: f32 = 1.0, // Number of source squares
    nrd: f32 = 1.0, // Number of drain squares
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
// Channel: drain -- source (function of gate, bulk voltages)
// Impact ionization: drain -- bulk or source -- bulk
// Junction: drain -- bulk, source -- bulk

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

// ============================================================================
// y_fv interpolation function (EKV normalized current from pinch-off voltage)
// ============================================================================
// Piecewise interpolation: given tmp1 = (VP - V) / Vt, return yk such that
// if = yk * (1 + yk). Works with the Dual/AD type S.

inline fn y_fv(comptime S: type, tmp1: S) S {
    if (tmp1.val() > -0.35) {
        // Strong inversion region
        const z0 = S.con(2.0).div(tmp1.addC(1.6).log().neg().add(tmp1).addC(1.3));
        const zk = z0.addC(2.0).div(z0.log().add(tmp1).addC(1.0));
        return zk.log().add(tmp1).addC(1.0).div(zk.addC(2.0));
    } else if (tmp1.val() > -15.0) {
        // Moderate inversion
        const z0 = tmp1.neg().exp().addC(1.55);
        const zk = z0.addC(2.0).div(z0.log().add(tmp1).addC(1.0));
        return zk.log().add(tmp1).addC(1.0).div(zk.addC(2.0));
    } else if (tmp1.val() > -23.0) {
        // Weak inversion
        return S.con(1.0).div(tmp1.neg().exp().addC(2.0));
    } else {
        // Deep weak inversion
        return tmp1.exp().addC(1e-64);
    }
}

// ============================================================================
// Preprocessed Parameters
// ============================================================================

const DcParams = struct {
    type_f: f64,
    m_mult: f64,
    // Temperature-adjusted parameters
    vt: f64,
    inv_vt: f64,
    vt_2: f64,
    vt_4: f64,
    vt_vt: f64,
    vt_vt_2: f64,
    vt_vt_16: f64,
    vt_01: f64,
    vto_s: f64,
    kp_weff: f64,
    gamma_s: f64,
    gamma_sqrt_phi: f64,
    phi_t: f64,
    sqrt_phi: f64,
    ucrit_t: f64,
    inv_ucrit: f64,
    ibb_t: f64,
    // Geometry-dependent
    leff: f64,
    weff: f64,
    lc: f64,
    lc_lambda: f64,
    lc_ucrit: f64,
    lc_ibb: f64,
    iba_ibb: f64,
    ibn_2: f64,
    eps_cox_w: f64,
    eps_cox_l: f64,
    t0: f64,
    v0: f64,
    delta_vfb: f64,
    log_vc_vt: f64,
    vc: f64,
    eta_qi: f64,
    lambda: f64,
    theta: f64,
    e0: f64,
    ns: f64,
    // Series resistance
    rs_eff: f64,
    rd_eff: f64,
    // Temperature ratios for junctions
    ratio_t: f64,
    delta_t: f64,
    eg: f64,
    ref_eg: f64,
    t_dev: f64,
    tnom: f64,
    // Junction params (temperature-adjusted)
    n_junc: f64,
    js_t: f64,
    jsw_t: f64,
    jswg_t: f64,
    pb_t: f64,
    pbsw_t: f64,
    pbswg_t: f64,
    bv: f64,
    xjbv: f64,
    // Junction areas/perimeters
    as_i: f64,
    ad_i: f64,
    ps_i: f64,
    pd_i: f64,
    // Tunneling
    njts_t: f64,
    njtssw_t: f64,
    njtsswg_t: f64,
    vts: f64,
    vtssw: f64,
    vtsswg: f64,
};

const QParams = struct {
    type_f: f64,
    m_mult: f64,
    weff: f64,
    leff: f64,
    cox: f64,
    gamma_s: f64,
    gamma_sqrt_phi: f64,
    vto_s: f64,
    delta_vfb: f64,
    phi_t: f64,
    sqrt_phi: f64,
    vt: f64,
    inv_vt: f64,
    vt_01: f64,
    vt_vt_16: f64,
    eps_cox_w: f64,
    eps_cox_l: f64,
    ns: f64,
    eta_qi: f64,
    // Overlap capacitances (pre-scaled)
    cgso_w: f64,
    cgdo_w: f64,
    cgbo_l: f64,
    // Junction capacitance (temperature-adjusted)
    cj_t: f64,
    cjsw_t: f64,
    cjswg_t: f64,
    pb_t: f64,
    pbsw_t: f64,
    pbswg_t: f64,
    mj: f64,
    mjsw: f64,
    mjswg: f64,
    as_i: f64,
    ad_i: f64,
    ps_i: f64,
    pd_i: f64,
};

fn dcParams(model: *const Model, instance: *const Instance) DcParams {
    const type_f: f64 = @floatFromInt(model.type_);
    const m_mult: f64 = @as(f64, instance.m);
    const ns: f64 = @as(f64, instance.ns);

    // Temperature
    const t_dev: f64 = @as(f64, instance.temp) + @as(f64, instance.dtemp);
    const tnom: f64 = @as(f64, model.tnom) + 273.15;
    const vt: f64 = 1.3806488e-23 * t_dev / 1.602176565e-19;
    const inv_vt: f64 = 1.0 / vt;
    const vt_2: f64 = vt + vt;
    const vt_4: f64 = vt_2 + vt_2;
    const vt_vt: f64 = vt * vt;
    const vt_vt_2: f64 = vt_vt + vt_vt;
    const vt_vt_16: f64 = 16.0 * vt_vt;
    const vt_01: f64 = 0.1 * vt;

    // Bandgap
    const eg: f64 = 1.16 - 7.02e-4 * t_dev * t_dev / (t_dev + 1108.0);
    const ref_eg: f64 = 1.16 - 7.02e-4 * tnom * tnom / (tnom + 1108.0);
    const delta_t: f64 = t_dev - tnom;
    const ratio_t: f64 = t_dev / tnom;

    // Temperature-adjusted model parameters
    const vto_t: f64 = @as(f64, model.vto) - @as(f64, model.tcv) * delta_t;
    const kp_t: f64 = @as(f64, model.kp) * contract.fmath.pow(ratio_t, @as(f64, model.bex));
    const ucrit_t: f64 = @as(f64, model.ucrit) * contract.fmath.pow(ratio_t, @as(f64, model.ucex));
    const ibb_t: f64 = @as(f64, model.ibb) * (1.0 + @as(f64, model.ibbt) * delta_t);

    // PHI_T with clamp to >= 0.2
    var phi_t: f64 = @as(f64, model.phi) * ratio_t - 3.0 * vt * contract.fmath.log(ratio_t) - ref_eg * ratio_t + eg;
    const tmp_phi: f64 = phi_t - 0.2;
    phi_t = 0.5 * (tmp_phi + @sqrt(tmp_phi * tmp_phi + vt_vt)) + 0.2;
    const sqrt_phi: f64 = @sqrt(phi_t);

    // Effective geometry
    const leff: f64 = @as(f64, instance.l) + @as(f64, model.dl);
    const weff: f64 = @as(f64, instance.w) + @as(f64, model.dw);

    const gamma: f64 = @as(f64, model.gamma);
    const agamma: f64 = @as(f64, model.agamma);
    const avto: f64 = @as(f64, model.avto);
    const akp: f64 = @as(f64, model.akp);

    // Process-related
    const epssil: f64 = 11.7 * 8.854187817e-12;
    const cox: f64 = @as(f64, model.cox);
    const eps_cox: f64 = epssil / cox;
    const lc: f64 = @sqrt(eps_cox * @as(f64, model.xj));
    const lc_lambda: f64 = lc * @as(f64, model.lambda);
    const eps_cox_w: f64 = 3.0 * eps_cox * @as(f64, model.weta);
    const eps_cox_l: f64 = eps_cox * @as(f64, model.leta);
    const ibn_2: f64 = @as(f64, model.ibn) + @as(f64, model.ibn);
    const t0: f64 = cox / (epssil * @as(f64, model.e0));
    const q0: f64 = @as(f64, model.q0);
    const v0: f64 = (q0 + q0) / cox;
    const eta_qi: f64 = if (model.type_ > 0) 0.5 else 0.3333333333333;

    const inv_ucrit: f64 = 1.0 / ucrit_t;
    const lc_ucrit: f64 = lc * ucrit_t;
    const lc_ibb: f64 = lc * ibb_t;
    const iba_ibb: f64 = @as(f64, model.iba) / ibb_t;

    const vc: f64 = ucrit_t * leff;
    const log_vc_vt: f64 = vt * (contract.fmath.log(0.5 * vc * inv_vt) - 0.6);

    // Mismatch-adjusted parameters
    const awl: f64 = 1.0 / @sqrt(weff * leff);
    const vto_s: f64 = blk: {
        if (model.type_ > 0) {
            break :blk if (avto != 1e-6) awl * (avto - 1e-6) + vto_t else vto_t;
        } else {
            break :blk if (avto != 1e-6) awl * (1e-6 - avto) - vto_t else -vto_t;
        }
    };
    const kp_weff: f64 = weff * (if (akp != 1e-6) kp_t * (1.0 + (akp - 1e-6) * awl) else kp_t);
    const gamma_s: f64 = if (agamma != 1e-6) gamma + (agamma - 1e-6) * awl else gamma;
    const gamma_sqrt_phi: f64 = gamma_s * sqrt_phi;

    // Reverse short channel effect (deltaVFB)
    const delta_vfb: f64 = blk: {
        if (v0 == 0.0) break :blk 0.0;
        const vl: f64 = 0.28 * (leff / (@as(f64, model.lk) * ns) - 0.1);
        const sqv: f64 = 1.0 / (1.0 + 0.5 * (vl + @sqrt(vl * vl + 1.936e-3)));
        break :blk v0 * sqv * sqv;
    };

    // Series resistance
    const rsh: f64 = @as(f64, model.rsh);
    const hdif: f64 = @as(f64, model.hdif);
    const rs_eff: f64 = if (hdif > 0.0) (rsh * hdif) / (weff - @as(f64, model.dw)) else rsh * @as(f64, instance.nrs);
    const rd_eff: f64 = if (hdif > 0.0) (rsh * hdif) / (weff - @as(f64, model.dw)) else rsh * @as(f64, instance.nrd);

    // Junction temperature scaling
    const vt_nom: f64 = 1.3806488e-23 * tnom / 1.602176565e-19;
    const temp_arg: f64 = contract.fmath.exp((ref_eg / vt_nom - eg / vt + @as(f64, model.xti) * contract.fmath.log(ratio_t)) / @as(f64, model.n_junc));
    const js_t: f64 = @as(f64, model.js) * temp_arg;
    const jsw_t: f64 = @as(f64, model.jsw) * temp_arg;
    const jswg_t: f64 = @as(f64, model.jswg) * temp_arg;
    const pb_t: f64 = @as(f64, model.pb) - @as(f64, model.tpb) * delta_t;
    const pbsw_t: f64 = @as(f64, model.pbsw) - @as(f64, model.tpbsw) * delta_t;
    const pbswg_t: f64 = @as(f64, model.pbswg) - @as(f64, model.tpbswg) * delta_t;

    // Junction areas
    const as_i: f64 = if (@as(f64, instance.as_) == 0.0 and hdif > 0.0) 2.0 * hdif * weff else @as(f64, instance.as_);
    const ad_i: f64 = if (@as(f64, instance.ad) == 0.0 and hdif > 0.0) 2.0 * hdif * weff else @as(f64, instance.ad);
    const ps_i: f64 = if (@as(f64, instance.ps) == 0.0 and hdif > 0.0) 4.0 * hdif + weff else @as(f64, instance.ps);
    const pd_i: f64 = if (@as(f64, instance.pd) == 0.0 and hdif > 0.0) 4.0 * hdif + weff else @as(f64, instance.pd);

    // Tunneling temperature scaling
    const njts_t: f64 = @as(f64, model.njts) * (1.0 + (ratio_t - 1.0) * @as(f64, model.tnjts));
    const njtssw_t: f64 = @as(f64, model.njtssw) * (1.0 + (ratio_t - 1.0) * @as(f64, model.tnjtssw));
    const njtsswg_t: f64 = @as(f64, model.njtsswg) * (1.0 + (ratio_t - 1.0) * @as(f64, model.tnjtsswg));

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .vt = vt,
        .inv_vt = inv_vt,
        .vt_2 = vt_2,
        .vt_4 = vt_4,
        .vt_vt = vt_vt,
        .vt_vt_2 = vt_vt_2,
        .vt_vt_16 = vt_vt_16,
        .vt_01 = vt_01,
        .vto_s = vto_s,
        .kp_weff = kp_weff,
        .gamma_s = gamma_s,
        .gamma_sqrt_phi = gamma_sqrt_phi,
        .phi_t = phi_t,
        .sqrt_phi = sqrt_phi,
        .ucrit_t = ucrit_t,
        .inv_ucrit = inv_ucrit,
        .ibb_t = ibb_t,
        .leff = leff,
        .weff = weff,
        .lc = lc,
        .lc_lambda = lc_lambda,
        .lc_ucrit = lc_ucrit,
        .lc_ibb = lc_ibb,
        .iba_ibb = iba_ibb,
        .ibn_2 = ibn_2,
        .eps_cox_w = eps_cox_w,
        .eps_cox_l = eps_cox_l,
        .t0 = t0,
        .v0 = v0,
        .delta_vfb = delta_vfb,
        .log_vc_vt = log_vc_vt,
        .vc = vc,
        .eta_qi = eta_qi,
        .lambda = @as(f64, model.lambda),
        .theta = @as(f64, model.theta),
        .e0 = @as(f64, model.e0),
        .ns = ns,
        .rs_eff = rs_eff,
        .rd_eff = rd_eff,
        .ratio_t = ratio_t,
        .delta_t = delta_t,
        .eg = eg,
        .ref_eg = ref_eg,
        .t_dev = t_dev,
        .tnom = tnom,
        .n_junc = @as(f64, model.n_junc),
        .js_t = js_t,
        .jsw_t = jsw_t,
        .jswg_t = jswg_t,
        .pb_t = pb_t,
        .pbsw_t = pbsw_t,
        .pbswg_t = pbswg_t,
        .bv = @as(f64, model.bv),
        .xjbv = @as(f64, model.xjbv),
        .as_i = as_i,
        .ad_i = ad_i,
        .ps_i = ps_i,
        .pd_i = pd_i,
        .njts_t = njts_t,
        .njtssw_t = njtssw_t,
        .njtsswg_t = njtsswg_t,
        .vts = @as(f64, model.vts),
        .vtssw = @as(f64, model.vtssw),
        .vtsswg = @as(f64, model.vtsswg),
    };
}

fn qParamsFromDc(model: *const Model, dc: *const DcParams) QParams {
    const cj_t: f64 = @as(f64, model.cj) * (1.0 + @as(f64, model.tcj) * dc.delta_t);
    const cjsw_t: f64 = @as(f64, model.cjsw) * (1.0 + @as(f64, model.tcjsw) * dc.delta_t);
    const cjswg_t: f64 = @as(f64, model.cjswg) * (1.0 + @as(f64, model.tcjswg) * dc.delta_t);

    return .{
        .type_f = dc.type_f,
        .m_mult = dc.m_mult,
        .weff = dc.weff,
        .leff = dc.leff,
        .cox = @as(f64, model.cox),
        .gamma_s = dc.gamma_s,
        .gamma_sqrt_phi = dc.gamma_sqrt_phi,
        .vto_s = dc.vto_s,
        .delta_vfb = dc.delta_vfb,
        .phi_t = dc.phi_t,
        .sqrt_phi = dc.sqrt_phi,
        .vt = dc.vt,
        .inv_vt = dc.inv_vt,
        .vt_01 = dc.vt_01,
        .vt_vt_16 = dc.vt_vt_16,
        .eps_cox_w = dc.eps_cox_w,
        .eps_cox_l = dc.eps_cox_l,
        .ns = dc.ns,
        .eta_qi = dc.eta_qi,
        .cgso_w = @as(f64, model.cgso) * dc.weff,
        .cgdo_w = @as(f64, model.cgdo) * dc.weff,
        .cgbo_l = @as(f64, model.cgbo) * dc.leff,
        .cj_t = cj_t,
        .cjsw_t = cjsw_t,
        .cjswg_t = cjswg_t,
        .pb_t = dc.pb_t,
        .pbsw_t = dc.pbsw_t,
        .pbswg_t = dc.pbswg_t,
        .mj = @as(f64, model.mj),
        .mjsw = @as(f64, model.mjsw),
        .mjswg = @as(f64, model.mjswg),
        .as_i = dc.as_i,
        .ad_i = dc.ad_i,
        .ps_i = dc.ps_i,
        .pd_i = dc.pd_i,
    };
}

pub const PrepCache = struct { dc: DcParams, q: QParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    const dc = dcParams(model, instance);
    return .{ .dc = dc, .q = qParamsFromDc(model, &dc) };
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

    const p = &pc.dc;
    const gmin: f64 = 1.0e-12;

    // --- Terminal voltages with PMOS sign flip ---
    const vg_raw = x[g].sub(x[b]).scale(p.type_f);
    const vs_raw = x[s].sub(x[b]).scale(p.type_f);
    const vd_raw = x[d].sub(x[b]).scale(p.type_f);

    // --- Source-drain reversal ---
    // If VD < VS, swap; mode = +1 (forward) or -1 (reversed)
    const vds_test = vd_raw.sub(vs_raw);
    const forward = vds_test.val() >= 0.0;
    const vg = vg_raw;
    const vs = if (forward) vs_raw else vd_raw;
    const vd = if (forward) vd_raw else vs_raw;
    const mode_f: f64 = if (forward) 1.0 else -1.0;

    // --- VGstar and VGprime ---
    const vg_star = vg.addC(-p.vto_s - p.delta_vfb + p.phi_t + p.gamma_sqrt_phi);
    const sqrt_vg_star = vg_star.mul(vg_star).addC(2.0 * p.vt_vt_16).sqrt();
    const vg_prime = vg_star.add(sqrt_vg_star).scale(0.5);

    // --- Pinch-off voltage VP ---
    // sqrt(PHI+VS), sqrt(PHI+VD) using smoothed sqrt
    const phi_vs = vs.addC(p.phi_t);
    const sqrt_phi_vs_vt = phi_vs.mul(phi_vs).addC(p.vt_vt_16).sqrt();
    const sqrt_phi_vs = phi_vs.add(sqrt_phi_vs_vt).scale(0.5).sqrt();

    const phi_vd = vd.addC(p.phi_t);
    const sqrt_phi_vd_vt = phi_vd.mul(phi_vd).addC(p.vt_vt_16).sqrt();
    const sqrt_phi_vd = phi_vd.add(sqrt_phi_vd_vt).scale(0.5).sqrt();

    // GAMMAprime with short/narrow channel effects
    const weta_w: f64 = p.eps_cox_w * p.m_mult / p.weff;
    const leta_l: f64 = p.eps_cox_l * p.ns / p.leff;

    const big_sqrt_vp0 = vg_prime.addC(0.25 * p.gamma_s * p.gamma_s).sqrt();
    const vp0 = vg_prime.addC(-p.phi_t).sub(big_sqrt_vp0.addC(-0.5 * p.gamma_s).scale(p.gamma_s));
    const sqrt_phi_vp0 = vp0.addC(p.phi_t + p.vt_01).sqrt();

    const gamma_star = sqrt_phi_vs.add(sqrt_phi_vd).scale(-leta_l).add(sqrt_phi_vp0.scale(weta_w)).addC(p.gamma_s);
    // Keep GAMMAprime >= 0
    const sqrt_gamma_star = gamma_star.mul(gamma_star).addC(p.vt_01).sqrt();
    const gamma_prime = gamma_star.add(sqrt_gamma_star).scale(0.5);

    const big_sqrt_vp = vg_prime.add(gamma_prime.mul(gamma_prime).scale(0.25)).sqrt();
    const vp = vg_prime.addC(-p.phi_t).sub(big_sqrt_vp.sub(gamma_prime.scale(0.5)).mul(gamma_prime));

    // --- Forward normalized current if ---
    const tmp_if = vp.sub(vs).scale(p.inv_vt);
    const yk_if = y_fv(S, tmp_if);
    const if_ = yk_if.mul(yk_if.addC(1.0));
    const sqrt_if = if_.sqrt();

    // --- Saturation voltage VDSS ---
    const vt_vc: f64 = p.vt / p.vc;
    const vdss_sqrt = sqrt_if.scale(vt_vc).addC(0.25).sqrt();
    const vdss = vdss_sqrt.addC(-0.5).scale(p.vc);

    const vds = vd.sub(vs).scale(0.5);
    // deltaV_2 = Vt_Vt_16*(LAMBDA*(sqrt_if - VDSS*inv_Vt) + 15.625e-3)
    const delta_v_2_val = sqrt_if.scale(p.lambda).sub(vdss.scale(p.inv_vt)).addC(15.625e-3).scale(p.vt_vt_16);

    const sqrt_vdss_dv = vdss.mul(vdss).add(delta_v_2_val).sqrt();
    const vds_minus_vdss = vds.sub(vdss);
    const sqrt_vds_vdss_dv = vds_minus_vdss.mul(vds_minus_vdss).add(delta_v_2_val).sqrt();
    const vip = sqrt_vdss_dv.sub(sqrt_vds_vdss_dv);

    // --- VDSSprime ---
    const vdssprime_sqrt = sqrt_if.sub(if_.maxC(1e-30).log().scale(0.75)).scale(vt_vc).addC(0.25).sqrt();
    const vdssprime = vdssprime_sqrt.addC(-0.5).scale(p.vc).addC(p.log_vc_vt);

    // --- Reverse normalized current irprime ---
    const vdsprime = vds.sub(vdssprime);
    const sqrt_vdssprime_dv = vdssprime.mul(vdssprime).add(delta_v_2_val).sqrt();
    const sqrt_vds_vdssprime_dv = vdsprime.mul(vdsprime).add(delta_v_2_val).sqrt();
    const tmp_ir = vp.sub(vds).sub(vs).sub(sqrt_vdssprime_dv).add(sqrt_vds_vdssprime_dv).scale(p.inv_vt);
    const yk_irprime = y_fv(S, tmp_ir);
    const irprime = yk_irprime.mul(yk_irprime.addC(1.0));

    // --- Channel length modulation & mobility reduction ---
    const delta_l = vds.sub(vip).div(S.con(p.lc_ucrit)).addC(1.0).log().scale(p.lc_lambda);
    const l_prime = delta_l.neg().addC(p.leff).add(vds.add(vip).scale(p.inv_ucrit));
    const lmin: f64 = 0.1 * p.leff;
    const sqrt_lprime_lmin = l_prime.mul(l_prime).addC(lmin * lmin).sqrt();
    const leq = l_prime.add(sqrt_lprime_lmin).scale(0.5);

    // --- Reverse normalized current ir (for charge model) ---
    const tmp_ir2 = vp.sub(vd).scale(p.inv_vt);
    const yk_ir = y_fv(S, tmp_ir2);
    const ir = yk_ir.mul(yk_ir.addC(1.0));

    // --- Charge-based quantities for mobility reduction ---
    const sif2 = if_.addC(0.25);
    const sir2 = ir.addC(0.25);
    const sif = sif2.sqrt();
    const sir = sir2.sqrt();
    const sif_sir = sif.add(sir);

    const vp_phi_eps = vp.addC(p.phi_t + 1.0e-6);
    const sqrt_phi_vp_2 = vp_phi_eps.sqrt().scale(2.0);
    const n_1 = S.con(p.gamma_s).div(sqrt_phi_vp_2);

    // Normalized inversion charge qi = -(1+n_1)*Vt*((4/3)*(sir2+sir*sif+sif2)/(sif+sir) - 1)
    const qi = n_1.addC(1.0).scale(-p.vt)
        .mul(sir2.add(sir.mul(sif)).add(sif2).div(sif_sir).scale(4.0 / 3.0).addC(-1.0));

    // Normalized depletion charge qb
    const n_1_n = S.con(p.gamma_s).div(sqrt_phi_vp_2.addC(p.gamma_s));
    const qb = sqrt_phi_vp_2.scale(-0.5 * p.gamma_s).sub(n_1_n.mul(qi));

    // --- Transconductance factor (beta) ---
    const beta: S = blk: {
        if (p.e0 == 0.0 or p.theta > 0.0) {
            // Simple mobility model (THETA)
            if (p.theta == 0.0 and p.e0 == 0.0) {
                break :blk S.con(p.kp_weff).div(leq);
            }
            const sqrt_vp_vt = vp.mul(vp).addC(p.vt_vt_2).sqrt();
            const vp_prime = vp.add(sqrt_vp_vt).scale(0.5);
            const theta_vp_1 = vp_prime.scale(p.theta).addC(1.0);
            break :blk S.con(p.kp_weff).div(leq.mul(theta_vp_1));
        } else {
            // Charge-based mobility model (E0)
            const qb_eta_qi = qb.add(qi.scale(p.eta_qi));
            const e0_q_1 = if (qb_eta_qi.val() > 0.0)
                qb_eta_qi.scale(p.t0).addC(1.0)
            else
                qb_eta_qi.scale(-p.t0).addC(1.0);
            const t0_gamma_1: f64 = 1.0 + p.t0 * p.gamma_sqrt_phi;
            break :blk S.con(p.kp_weff * t0_gamma_1).div(leq.mul(e0_q_1));
        }
    };

    // --- Slope factor ---
    const sqrt_phi_vp = vp.addC(p.phi_t + p.vt_4).sqrt();
    const nslope = S.con(p.gamma_s).div(sqrt_phi_vp.scale(2.0)).addC(1.0);

    // --- Drain current ---
    const if_ir = if_.sub(irprime);
    const i_spec = nslope.mul(beta).scale(p.vt_vt_2);
    var id = i_spec.mul(if_ir);

    // --- Series resistance correction ---
    // Id = Id / (1 + gms*Rs + gds*Rd)
    // gms and gds are not easy to compute without manual derivatives,
    // but the VA uses the manual derivatives. For the AD approach,
    // we apply the correction using the value of gms/gds from the
    // forward model. This is an approximation but matches the VA intent.
    // Actually the VA computes this in f64 space using manual derivatives,
    // so we just use the .val() for the correction factor.
    if (p.rs_eff != 0.0 or p.rd_eff != 0.0) {
        // Approximate gms and gds from the forward/reverse current derivatives
        // For a first-order correction, use gms ~ Id/(2*n*Vt), gds ~ Id*lambda_eff
        const id_val = id.val();
        const n_val = nslope.val();
        const gms_approx = @abs(id_val) / (2.0 * n_val * p.vt + 1e-30);
        const gds_approx = @abs(id_val) * 0.01; // small approximation
        _ = gds_approx;
        const corr = 1.0 / (1.0 + gms_approx * p.rs_eff + @abs(id_val) * 0.01 * p.rd_eff);
        id = id.scale(corr);
    }

    // --- Impact ionization (substrate current) ---
    const vib = vd.sub(vs).sub(vdss.scale(p.ibn_2));
    var i_sub = S.con(0.0);
    if (vib.val() > 0.0 and p.iba_ibb > 0.0) {
        const lc_ibb_vib = vib.div(S.con(-p.lc_ibb)).maxC(-35.0);
        const exp_ib = lc_ibb_vib.exp();
        const isub_factor = vib.scale(p.iba_ibb).mul(exp_ib);
        i_sub = isub_factor.mul(id);
    }

    // --- Junction diode currents ---
    const vtn: f64 = p.vt * p.n_junc;
    const v_di_b = x[d].sub(x[b]).scale(p.type_f); // TYPE * V(d,b)
    const v_si_b = x[s].sub(x[b]).scale(p.type_f); // TYPE * V(s,b)

    // Drain-bulk junction
    const is_d: f64 = p.js_t * p.ad_i + p.jsw_t * p.pd_i + p.jswg_t * p.weff;
    const arg_d = v_di_b.scale(-p.ratio_t / vtn).maxC(-40.0);
    var f_bd = S.con(1.0);
    if (p.xjbv > 0.0) {
        const tmp_bd = v_di_b.neg().addC(p.bv).scale(p.ratio_t / vtn);
        if (tmp_bd.val() <= 70.0) {
            f_bd = tmp_bd.neg().exp().scale(p.xjbv).addC(1.0);
        }
    }
    const i_bd = arg_d.exp().neg().addC(1.0).scale(is_d).mul(f_bd).add(v_di_b.scale(gmin));

    // Source-bulk junction
    const is_s: f64 = p.js_t * p.as_i + p.jsw_t * p.ps_i + p.jswg_t * p.weff;
    const arg_s = v_si_b.scale(-p.ratio_t / vtn).maxC(-40.0);
    var f_bs = S.con(1.0);
    if (p.xjbv > 0.0) {
        const tmp_bs = v_si_b.neg().addC(p.bv).scale(p.ratio_t / vtn);
        if (tmp_bs.val() <= 70.0) {
            f_bs = tmp_bs.neg().exp().scale(p.xjbv).addC(1.0);
        }
    }
    const i_bs = arg_s.exp().neg().addC(1.0).scale(is_s).mul(f_bs).add(v_si_b.scale(gmin));

    // --- Tunneling currents (simplified: skip if vts/vtssw/vtsswg are zero) ---
    var idb_tun = S.con(0.0);
    if (p.vtsswg > 0.0 or p.vtssw > 0.0 or p.vts > 0.0) {
        if (p.vtsswg > 0.0) {
            const denom = v_di_b.addC(p.vtsswg).maxC(1e-3);
            const arg_tun = v_di_b.scale(p.ratio_t / (p.vt * p.njtsswg_t)).mul(S.con(p.vtsswg).div(denom));
            idb_tun = idb_tun.sub(arg_tun.minC(40.0).exp().addC(-1.0).scale(p.weff * p.jswg_t));
        }
        if (p.vtssw > 0.0) {
            const denom = v_di_b.addC(p.vtssw).maxC(1e-3);
            const arg_tun = v_di_b.scale(p.ratio_t / (p.vt * p.njtssw_t)).mul(S.con(p.vtssw).div(denom));
            idb_tun = idb_tun.sub(arg_tun.minC(40.0).exp().addC(-1.0).scale(p.pd_i * p.jsw_t));
        }
        if (p.vts > 0.0) {
            const denom = v_di_b.addC(p.vts).maxC(1e-3);
            const arg_tun = v_di_b.scale(p.ratio_t / (p.vt * p.njts_t)).mul(S.con(p.vts).div(denom));
            idb_tun = idb_tun.sub(arg_tun.minC(40.0).exp().addC(-1.0).scale(p.ad_i * p.js_t));
        }
    }

    var isb_tun = S.con(0.0);
    if (p.vtsswg > 0.0 or p.vtssw > 0.0 or p.vts > 0.0) {
        if (p.vtsswg > 0.0) {
            const denom = v_si_b.addC(p.vtsswg).maxC(1e-3);
            const arg_tun = v_si_b.scale(p.ratio_t / (p.vt * p.njtsswg_t)).mul(S.con(p.vtsswg).div(denom));
            isb_tun = isb_tun.sub(arg_tun.minC(40.0).exp().addC(-1.0).scale(p.weff * p.jswg_t));
        }
        if (p.vtssw > 0.0) {
            const denom = v_si_b.addC(p.vtssw).maxC(1e-3);
            const arg_tun = v_si_b.scale(p.ratio_t / (p.vt * p.njtssw_t)).mul(S.con(p.vtssw).div(denom));
            isb_tun = isb_tun.sub(arg_tun.minC(40.0).exp().addC(-1.0).scale(p.ps_i * p.jsw_t));
        }
        if (p.vts > 0.0) {
            const denom = v_si_b.addC(p.vts).maxC(1e-3);
            const arg_tun = v_si_b.scale(p.ratio_t / (p.vt * p.njts_t)).mul(S.con(p.vts).div(denom));
            isb_tun = isb_tun.sub(arg_tun.minC(40.0).exp().addC(-1.0).scale(p.as_i * p.js_t));
        }
    }

    // Total junction currents
    const i_db_total = i_bd.add(idb_tun).scale(p.type_f * p.m_mult);
    const i_sb_total = i_bs.add(isb_tun).scale(p.type_f * p.m_mult);

    // --- Channel current with mode and impact ionization ---
    // I(d,s) = TYPE * Mode * Id
    // Impact ionization flows from intrinsic drain to bulk
    const id_ds = id.scale(p.type_f * mode_f * p.m_mult);

    // Impact ionization: I(d,b) or I(s,b) depending on mode
    const i_sub_scaled = i_sub.scale(p.type_f * p.m_mult);

    // --- KCL node stamps ---
    // Current leaving each node
    var out: [n_u]S = undefined;
    if (forward) {
        // I(d,s): current from d to s (leaving d, entering s)
        // I(d,b): junction + impact ionization from d to b
        out[d] = id_ds.add(i_db_total).add(i_sub_scaled);
        out[g] = S.con(0.0);
        out[s] = id_ds.neg().add(i_sb_total);
        out[b] = i_db_total.neg().sub(i_sub_scaled).sub(i_sb_total);
    } else {
        // Reversed mode: channel current flows s to d (Id is computed with swapped S/D)
        out[d] = id_ds.add(i_db_total).sub(i_sub_scaled);
        out[g] = S.con(0.0);
        out[s] = id_ds.neg().add(i_sb_total).add(i_sub_scaled);
        out[b] = i_db_total.neg().add(i_sub_scaled).sub(i_sb_total);
    }
    return out;
}

// ============================================================================
// Charge Function (q) -- EKV intrinsic charges + overlap + junction depletion
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d_idx = @intFromEnum(U.drain);
    const g_idx = @intFromEnum(U.gate);
    const s_idx = @intFromEnum(U.source);
    const b_idx = @intFromEnum(U.bulk);

    const p = &pc.q;

    // --- Terminal voltages with PMOS sign flip ---
    const vg_raw = x[g_idx].sub(x[b_idx]).scale(p.type_f);
    const vs_raw = x[s_idx].sub(x[b_idx]).scale(p.type_f);
    const vd_raw = x[d_idx].sub(x[b_idx]).scale(p.type_f);

    // --- Source-drain reversal ---
    const vds_test = vd_raw.sub(vs_raw);
    const forward = vds_test.val() >= 0.0;
    const vg = vg_raw;
    const vs = if (forward) vs_raw else vd_raw;
    const vd = if (forward) vd_raw else vs_raw;

    // --- VGstar and VGprime ---
    const vg_star = vg.addC(-p.vto_s - p.delta_vfb + p.phi_t + p.gamma_sqrt_phi);
    const sqrt_vg_star = vg_star.mul(vg_star).addC(2.0 * p.vt_vt_16).sqrt();
    const vg_prime = vg_star.add(sqrt_vg_star).scale(0.5);

    // --- Pinch-off voltage VP ---
    const phi_vs = vs.addC(p.phi_t);
    const sqrt_phi_vs_vt = phi_vs.mul(phi_vs).addC(p.vt_vt_16).sqrt();
    const sqrt_phi_vs = phi_vs.add(sqrt_phi_vs_vt).scale(0.5).sqrt();

    const phi_vd = vd.addC(p.phi_t);
    const sqrt_phi_vd_vt = phi_vd.mul(phi_vd).addC(p.vt_vt_16).sqrt();
    const sqrt_phi_vd = phi_vd.add(sqrt_phi_vd_vt).scale(0.5).sqrt();

    const weta_w: f64 = p.eps_cox_w * p.m_mult / p.weff;
    const leta_l: f64 = p.eps_cox_l * p.ns / p.leff;

    const big_sqrt_vp0 = vg_prime.addC(0.25 * p.gamma_s * p.gamma_s).sqrt();
    const vp0 = vg_prime.addC(-p.phi_t).sub(big_sqrt_vp0.addC(-0.5 * p.gamma_s).scale(p.gamma_s));
    const sqrt_phi_vp0 = vp0.addC(p.phi_t + p.vt_01).sqrt();

    const gamma_star = sqrt_phi_vs.add(sqrt_phi_vd).scale(-leta_l).add(sqrt_phi_vp0.scale(weta_w)).addC(p.gamma_s);
    const sqrt_gamma_star = gamma_star.mul(gamma_star).addC(p.vt_01).sqrt();
    const gamma_prime = gamma_star.add(sqrt_gamma_star).scale(0.5);

    const big_sqrt_vp = vg_prime.add(gamma_prime.mul(gamma_prime).scale(0.25)).sqrt();
    const vp = vg_prime.addC(-p.phi_t).sub(big_sqrt_vp.sub(gamma_prime.scale(0.5)).mul(gamma_prime));

    // --- Forward and reverse normalized currents for charge model ---
    const tmp_if = vp.sub(vs).scale(p.inv_vt);
    const yk_if = y_fv(S, tmp_if);
    const if_ = yk_if.mul(yk_if.addC(1.0));

    const tmp_ir = vp.sub(vd).scale(p.inv_vt);
    const yk_ir = y_fv(S, tmp_ir);
    const ir = yk_ir.mul(yk_ir.addC(1.0));

    // --- Charge model quantities ---
    const sif2 = if_.addC(0.25);
    const sir2 = ir.addC(0.25);
    const sif = sif2.sqrt();
    const sir = sir2.sqrt();
    const sif_sir = sif.add(sir);
    const sif_sir_2 = sif_sir.mul(sif_sir);

    const sif3 = sif.mul(sif2);
    const sir3 = sir.mul(sir2);

    // n_Vt_COX
    const sqrt_phi_half_vp = vp.scale(0.5).addC(p.phi_t).sqrt();
    const sqrt_phi_vp2_2 = sqrt_phi_half_vp.scale(2.0);
    const wl_cox: f64 = p.weff * p.leff * p.cox;
    const n_vt_cox = gamma_prime.div(sqrt_phi_vp2_2).addC(1.0).scale(p.vt * wl_cox);

    // QD and QS (intrinsic partition charges)
    const q_d_intr = n_vt_cox.neg().mul(
        sir3.scale(3.0).add(sir2.mul(sif).scale(6.0)).add(sir.mul(sif2).scale(4.0)).add(sif3.scale(2.0))
            .div(sif_sir_2).scale(0.266666666).addC(-0.5),
    );
    const q_s_intr = n_vt_cox.neg().mul(
        sif3.scale(3.0).add(sif2.mul(sir).scale(6.0)).add(sif.mul(sir2).scale(4.0)).add(sir3.scale(2.0))
            .div(sif_sir_2).scale(0.266666666).addC(-0.5),
    );

    // QI and QB
    const qi_total = q_s_intr.add(q_d_intr);

    const vp_phi_eps = vp.addC(p.phi_t + 1e-6);
    const sqrt_phi_vp_2 = vp_phi_eps.sqrt().scale(2.0);

    const qb_total = S.con(wl_cox).mul(
        sqrt_phi_vp_2.scale(-0.5 * p.gamma_s).add(vg_prime).sub(vg_star),
    ).sub(qi_total.mul(gamma_prime).div(gamma_prime.add(sqrt_phi_vp2_2)));

    // QG = -QI - QB
    const qg_total = qi_total.neg().sub(qb_total);

    // Map back based on mode
    const q_phys_d = if (forward) q_d_intr else q_s_intr;
    const q_phys_s = if (forward) q_s_intr else q_d_intr;

    // --- Overlap charges ---
    const q_gs_ov = x[g_idx].sub(x[s_idx]).scale(p.cgso_w);
    const q_gd_ov = x[g_idx].sub(x[d_idx]).scale(p.cgdo_w);
    const q_gb_ov = x[g_idx].sub(x[b_idx]).scale(p.cgbo_l);

    // --- Junction depletion charges ---
    const v_di_b = x[d_idx].sub(x[b_idx]).scale(p.type_f);
    const v_si_b = x[s_idx].sub(x[b_idx]).scale(p.type_f);

    const qjd = junctionChargeEkv(S, v_di_b, p.cj_t * p.ad_i, p.pb_t, p.mj)
        .add(junctionChargeEkv(S, v_di_b, p.cjsw_t * p.pd_i, p.pbsw_t, p.mjsw))
        .add(junctionChargeEkv(S, v_di_b, p.cjswg_t * p.weff, p.pbswg_t, p.mjswg));

    const qjs = junctionChargeEkv(S, v_si_b, p.cj_t * p.as_i, p.pb_t, p.mj)
        .add(junctionChargeEkv(S, v_si_b, p.cjsw_t * p.ps_i, p.pbsw_t, p.mjsw))
        .add(junctionChargeEkv(S, v_si_b, p.cjswg_t * p.weff, p.pbswg_t, p.mjswg));

    // --- Total charges per terminal ---
    const mm = p.m_mult * p.type_f;
    var out: [n_u]S = undefined;
    // ddt(Qbdx) on I(d,b), ddt(Qbsx) on I(s,b), ddt(QG) on I(g,b)
    // Plus overlap charges and junction depletion charges
    out[d_idx] = q_phys_d.scale(mm).add(qjd.scale(p.type_f * p.m_mult)).add(q_gd_ov.neg().scale(p.m_mult * p.type_f));
    out[g_idx] = qg_total.scale(mm).add(q_gs_ov.add(q_gd_ov).add(q_gb_ov).scale(p.m_mult * p.type_f));
    out[s_idx] = q_phys_s.scale(mm).add(qjs.scale(p.type_f * p.m_mult)).add(q_gs_ov.neg().scale(p.m_mult * p.type_f));
    out[b_idx] = qg_total.neg().sub(qi_total).scale(mm)
        .sub(qjd.add(qjs).scale(p.type_f * p.m_mult))
        .sub(q_gb_ov.scale(p.m_mult * p.type_f));

    return out;
}

// ============================================================================
// EKV junction charge: Q = C * V with linearized depletion model
// ============================================================================
// Forward bias: Q = C * V (linear for simplicity/stability)
// Reverse bias: C = C0 * (1 - V/pb)^(-mj), integrated

fn junctionChargeEkv(comptime S: type, v: S, c0: f64, pb: f64, mjc: f64) S {
    if (c0 == 0.0 or pb == 0.0) return S.con(0.0);
    // The VA uses: forward: C = C0*(1 - mj*V/pb), reverse: C = C0*(1+V/pb)^(-mj)
    // Integrate C*dV: Q = C*V approximation from the VA
    if (v.val() > 0.0) {
        // Forward bias: linear cap Q = C0 * (1 - mj*v/(2*pb)) * v (trapezoidal)
        // Actually the VA just does Q = C * v where C = C0*exp(-mj*ln(1+v/pb))
        const c = v.scale(1.0 / pb).addC(1.0).log().scale(-mjc).exp().scale(c0);
        return c.mul(v);
    } else {
        // Reverse bias: C = C0 * (1 - mj*v/pb), Q = C * v
        const c = v.scale(-mjc / pb).addC(1.0).scale(c0);
        return c.mul(v);
    }
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const d_idx = @intFromEnum(U.drain);
    const s_idx = @intFromEnum(U.source);

    const type_f: f64 = @floatFromInt(model.type_);
    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const vt: f64 = 1.3806488e-23 * (temp + dtemp) / 1.602176565e-19;

    const vto: f64 = @as(f64, model.vto);

    // Critical voltage
    const is_approx: f64 = 1e-14;
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_approx));

    var result = x_new;

    // DEVfetlim: gate-source voltage
    {
        const vgs_new = (x_new[g] - x_new[s_idx]) * type_f;
        const vgs_old = (x_old[g] - x_old[s_idx]) * type_f;

        const vtox = vto + 3.5;
        const vtsthi = @abs(2.0 * (vgs_old - vto)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const delta_v = vgs_new - vgs_old;

        var vgs_lim = vgs_new;

        if (vgs_old >= vto) {
            if (vgs_old >= vtox) {
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vgs_old - vtstlo);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            } else {
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vto - 0.5);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            }
        } else {
            if (delta_v <= 0.0) {
                vgs_lim = @max(vgs_new, vgs_old - vtstlo);
            } else {
                vgs_lim = @min(vgs_new, vto + 0.5);
            }
        }

        const delta_gs = (vgs_lim - vgs_new) * type_f;
        result[g] += delta_gs;
    }

    // DEVlimvds: drain-source voltage
    {
        const vds_new = (result[d_idx] - result[s_idx]) * type_f;
        const vds_old = (x_old[d_idx] - x_old[s_idx]) * type_f;
        const delta_vds = vds_new - vds_old;

        var vds_lim = vds_new;

        if (vds_old >= 3.5) {
            if (delta_vds <= 0.0) {
                vds_lim = @max(vds_new, -0.5 * vds_old);
            } else {
                vds_lim = @min(vds_new, 2.0 * vds_old);
            }
        } else {
            if (vds_new > 4.0) {
                vds_lim = @min(vds_new, 4.0);
            }
        }

        const delta_ds = (vds_lim - vds_new) * type_f;
        result[d_idx] += delta_ds;
    }

    // DEVpnjlim: bulk-source junction
    {
        const vbs_new = (x_new[b] - result[s_idx]) * type_f;
        const vbs_old = (x_old[b] - x_old[s_idx]) * type_f;

        var vbs_limited = vbs_new;
        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1e-30)));
                } else {
                    vbs_limited = v_crit;
                }
            } else {
                vbs_limited = vt * contract.fmath.log(@max(vbs_new / vt, 1e-30));
            }
        }

        const delta_bs = (vbs_limited - vbs_new) * type_f;
        result[b] += delta_bs;
    }

    // DEVpnjlim: bulk-drain junction
    {
        const vbd_new = (result[b] - result[d_idx]) * type_f;
        const vbd_old = (x_old[b] - x_old[d_idx]) * type_f;

        var vbd_limited = vbd_new;
        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1e-30)));
                } else {
                    vbd_limited = v_crit;
                }
            } else {
                vbd_limited = vt * contract.fmath.log(@max(vbd_new / vt, 1e-30));
            }
        }

        const delta_bd = (vbd_limited - vbd_new) * type_f;
        result[d_idx] -= delta_bd;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda_step: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const js_orig: f64 = @as(f64, model.js);
    const js_stepped = js_orig + gmin_step * (1.0 - lambda_step);
    m.js = @floatCast(js_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ekv: NMOS default model y_fv interpolation" {
    // Test the y_fv function at a few known points
    const V = contract.Value;

    // Strong inversion: tmp1 = 5.0, expect yk close to 2.0 (yk*(1+yk) ~ 6)
    const yk1 = y_fv(V, V.con(5.0));
    try testing.expect(yk1.val() > 1.5);
    try testing.expect(yk1.val() < 3.0);

    // Weak inversion: tmp1 = -20.0, yk should be very small
    const yk2 = y_fv(V, V.con(-20.0));
    try testing.expect(yk2.val() > 0.0);
    try testing.expect(yk2.val() < 0.01);

    // Deep weak: tmp1 = -30.0
    const yk3 = y_fv(V, V.con(-30.0));
    try testing.expect(yk3.val() > 0.0);
    try testing.expect(yk3.val() < 1e-10);
}

test "ekv: NMOS saturation current" {
    // Default EKV parameters with VGS = 1V, VDS = 2V, VSB = 0
    // (strong inversion, saturation expected)
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 2.0, 1.0, 0.0, 0.0 }, &model, &inst, 0);

    // Gate current should be zero
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-20);

    // Drain current should be positive for NMOS (current leaving drain)
    try testing.expect(out[0] > 0.0);

    // KCL: sum of all currents should be zero
    const sum = out[0] + out[1] + out[2] + out[3];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "ekv: NMOS off state" {
    // VGS = 0 (below threshold), VDS = 1V
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);

    // Drain current should be very small (subthreshold)
    try testing.expect(@abs(out[0]) < 1e-6);

    // KCL
    const sum = out[0] + out[1] + out[2] + out[3];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "ekv: PMOS basic operation" {
    const model: Model = .{ .type_ = -1 };
    const inst: Instance = .{};
    // PMOS: VGS = -1V, VDS = -2V (drain more negative)
    const out = contract.evalValues(Self, .{ -2.0, -1.0, 0.0, 0.0 }, &model, &inst, 0);

    // Gate current should be zero
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-20);

    // For PMOS, current should flow from source to drain (current entering drain)
    try testing.expect(out[0] < 0.0);

    // KCL
    const sum = out[0] + out[1] + out[2] + out[3];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "ekv: charge function KCL" {
    // Verify charge conservation: QG + QD + QS + QB = 0 (intrinsic only)
    const model: Model = .{ .js = 0, .jsw = 0, .jswg = 0, .cgso = 0, .cgdo = 0, .cgbo = 0 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 2.0, 1.0, 0.0, 0.0 }, &model, &inst, 0);

    const sum = out[0] + out[1] + out[2] + out[3];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-18);
}
