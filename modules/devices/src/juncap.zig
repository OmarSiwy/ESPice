// JUNCAP2 200.6 -- Junction Diode Model (NXP/CEA-Leti)
//
// Two-terminal junction diode for source/drain junctions in MOSFETs.
// Three geometrical components: bottom (AB), STI-edge (LS), gate-edge (LG).
// Each component models: depletion capacitance, ideal (Shockley) current,
// SRH generation/recombination, trap-assisted tunneling, band-to-band tunneling,
// and avalanche breakdown. Shot noise on terminal current.

const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminal enum -- external ports only (no internal nodes)
// ============================================================================

pub const U = enum(u8) { A, K };
pub const num_ports: usize = 2;

// ============================================================================
// Physical constants
// ============================================================================

const T0: f64 = 273.15;
const KB: f64 = 1.3806505e-23;
const QQ: f64 = 1.6021918e-19;
const HBAR: f64 = 1.05457168e-34;
const M0: f64 = 9.1093826e-31;
const EPS0: f64 = 8.85418782e-12;
const EPSR_SI: f64 = 11.8;
const EPS_SI: f64 = EPS0 * EPSR_SI;

// Other constants
const T_MIN: f64 = -250.0;
const VBI_LOW: f64 = 0.050;
const CAP_A: f64 = 2.0; // upper-limit factor for forward capacitance
const EPS_CH: f64 = 0.1;
const DELTA_VBI: f64 = 0.050;
const EPS_AV: f64 = 1.0e-6;
const VBR_MAX: f64 = 1.0e3;
const VMAX_LARGE: f64 = 1.0e8;
const A_ERFC: f64 = 0.29214664;
const P_ERFC: f64 = 1.7724538509055159 * A_ERFC; // sqrt(pi) * a_erfc
const B_ERFC: f64 = (6.0 - 5.0 * A_ERFC - 1.0 / (P_ERFC * P_ERFC)) / 3.0;
const C_ERFC: f64 = 1.0 - A_ERFC - B_ERFC;
const GMIN: f64 = 1.0e-12;

// ============================================================================
// Model parameters (52 parameters)
// ============================================================================

pub const Model = struct {
    // General
    level: i32 = 200,
    type_: i32 = 1, // polarity: 1 or -1
    ifactor: f32 = 1.0,
    cfactor: f32 = 1.0,
    trj: f32 = 21.0,
    swjunexp: i32 = 0, // 0 = full, 1 = express
    dta: f32 = 0.0,
    imax: f32 = 1000.0,

    // Capacitance parameters
    cjorbot: f32 = 1.0e-3,
    cjorsti: f32 = 1.0e-9,
    cjorgat: f32 = 1.0e-9,
    vbirbot: f32 = 1.0,
    vbirsti: f32 = 1.0,
    vbirgat: f32 = 1.0,
    pbot: f32 = 0.5,
    psti: f32 = 0.5,
    pgat: f32 = 0.5,

    // Ideal-current parameters
    phigbot: f32 = 1.16,
    phigsti: f32 = 1.16,
    phiggat: f32 = 1.16,
    idsatrbot: f32 = 1.0e-12,
    idsatrsti: f32 = 1.0e-18,
    idsatrgat: f32 = 1.0e-18,

    // SRH parameters
    csrhbot: f32 = 1.0e2,
    csrhsti: f32 = 1.0e-4,
    csrhgat: f32 = 1.0e-4,
    xjunsti: f32 = 1.0e-7,
    xjungat: f32 = 1.0e-7,

    // TAT parameters
    ctatbot: f32 = 1.0e2,
    ctatsti: f32 = 1.0e-4,
    ctatgat: f32 = 1.0e-4,
    mefftatbot: f32 = 0.25,
    mefftatsti: f32 = 0.25,
    mefftatgat: f32 = 0.25,

    // BBT parameters
    cbbtbot: f32 = 1.0e-12,
    cbbtsti: f32 = 1.0e-18,
    cbbtgat: f32 = 1.0e-18,
    fbbtrbot: f32 = 1.0e9,
    fbbtrsti: f32 = 1.0e9,
    fbbtrgat: f32 = 1.0e9,
    stfbbtbot: f32 = -1.0e-3,
    stfbbtsti: f32 = -1.0e-3,
    stfbbtgat: f32 = -1.0e-3,

    // Avalanche and breakdown parameters
    vbrbot: f32 = 10.0,
    vbrsti: f32 = 10.0,
    vbrgat: f32 = 10.0,
    pbrbot: f32 = 4.0,
    pbrsti: f32 = 4.0,
    pbrgat: f32 = 4.0,
    frev: f32 = 1.0e3,

    // JUNCAP Express parameters
    vjunref: f32 = 2.5,
    fjunq: f32 = 0.03,
};

// ============================================================================
// Instance parameters (5 parameters)
// ============================================================================

pub const Instance = struct {
    ab: f64 = 1.0e-12,
    ls: f64 = 1.0e-6,
    lg: f64 = 1.0e-6,
    mult: f64 = 1.0,
    trise: f64 = 0.0,
};

// ============================================================================
// Noise sources: shot noise across junction
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    .{ .row = 0, .col = 1, .kind = .shot },
};

// ============================================================================
// Sparse stamp patterns -- 2x2 dense (A-K junction)
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    .{ .row = 0, .col = 0 },
    .{ .row = 0, .col = 1 },
    .{ .row = 1, .col = 0 },
    .{ .row = 1, .col = 1 },
};

pub const c_pattern_override = [_]contract.Entry(n_u){
    .{ .row = 0, .col = 0 },
    .{ .row = 0, .col = 1 },
    .{ .row = 1, .col = 0 },
    .{ .row = 1, .col = 1 },
};

// ============================================================================
// Auxiliary functions (hyp-functions) -- value-form (generic over S)
// ============================================================================

// hyp1(x, eps) = 0.5 * (x + sqrt(x^2 + 4*eps^2))  -- smooth max(x, 0)
inline fn hyp1(comptime S: type, x: S, eps: f64) S {
    return x.mul(x).addC(4.0 * eps * eps).sqrt().add(x).scale(0.5);
}

// hyp2(x, x0, eps) = x - hyp1(x - x0, eps)  -- smooth clamp from above at x0
inline fn hyp2(comptime S: type, x: S, x0: f64, eps: f64) S {
    return x.sub(hyp1(S, x.addC(-x0), eps));
}

// hyp5(x, x0, eps) = x0 - hyp1(x0 - x - eps^2/x0, eps)
inline fn hyp5(comptime S: type, x: S, x0: f64, eps: f64) S {
    // x0 - x - eps^2/x0 = (-x) + (x0 - eps^2/x0)
    const inner = x.neg().addC(x0 - eps * eps / x0);
    return S.con(x0).sub(hyp1(S, inner, eps));
}

// erfcapprox(y) -- approximation to erfc(y) used in TAT model. Value-form.
// The y>0 branch reproduces the original piecewise definition (branch on
// value; each side computed in S ops).
inline fn erfcapprox(comptime S: type, y: S) S {
    const abs_y = y.abs();
    const t_pos = S.con(1.0).div(abs_y.scale(P_ERFC).addC(1.0));
    const t2 = t_pos.mul(t_pos);
    const t3 = t2.mul(t_pos);
    const poly = t_pos.scale(A_ERFC).add(t2.scale(B_ERFC)).add(t3.scale(C_ERFC));
    const erfc_pos = poly.mul(y.mul(y).neg().exp());
    // y > 0 ? erfc_pos : 2 - erfc_pos
    return if (y.val() > 0.0) erfc_pos else erfc_pos.neg().addC(2.0);
}

// ============================================================================
// Per-component juncap function: current and charge per unit area/length
//
// This is the core computational kernel shared by bottom, STI-edge, and
// gate-edge components. It returns (I_j_prime, Q_j_prime). Generic over the
// scalar S: v_ak carries the x-dependence, every other argument is plain f64
// (temperature / geometry / parameter preprocessing).
// ============================================================================

inline fn juncapComponent(
    comptime S: type,
    v_ak: S,
    // Component-specific model parameters (already cast to f64)
    cjor: f64,
    vbir: f64,
    p: f64,
    phig_unused: f64,
    idsatr_unused: f64,
    csrh: f64,
    xjun: f64,
    ctat: f64,
    mefftat: f64,
    cbbt: f64,
    fbbtr: f64,
    stfbbt: f64,
    vbr: f64,
    pbr: f64,
    // Shared model parameters
    ifactor: f64,
    cfactor: f64,
    frev_unused: f64,
    imax_unused: f64,
    // Temperature-derived quantities
    phi_tr: f64,
    phi_td: f64,
    tkr: f64,
    tkd: f64,
    // Per-component temperature-derived quantities
    ftd: f64,
    idsat: f64,
    vbi: f64,
    phi_gd: f64,
    // Shared derived quantities
    vf_min: f64,
    v_ch: f64,
    vbi_min: f64,
    alpha_av: f64,
    v_max: f64,
    // BBT shared
    vbbt_lim: f64,
) struct { i_j: S, q_j: S } {
    _ = phig_unused;
    _ = idsatr_unused;
    _ = frev_unused;
    _ = imax_unused;
    // ---- Junction charge (Eq. 4.33-4.35) ----
    const cjo = cjor * contract.fmath.exp(p * contract.fmath.log(@max(vbir / @max(vbi, 1.0e-30), 1.0e-30)));
    const vj = hyp5(S, v_ak, vf_min, v_ch);
    const one_minus_p = 1.0 - p;
    // vj_over_vbi = vj / max(vbi, 1e-30)
    const vj_over_vbi = vj.scale(1.0 / @max(vbi, 1.0e-30));
    // base = max(1 - vj_over_vbi, 1e-30)
    const base = vj_over_vbi.neg().addC(1.0).maxC(1.0e-30);
    // depletion = cjo*vbi/(1-p) * (1 - base^(1-p))
    const depletion = base.log().scale(one_minus_p).exp().neg().addC(1.0).scale(cjo * vbi / one_minus_p);
    // overlap = CAP_A * cjo * (v_ak - vj)
    const overlap = v_ak.sub(vj).scale(CAP_A * cjo);
    const q_j = depletion.add(overlap).scale(cfactor);

    // ---- Ideal current (Eq. 4.36-4.37) ----
    // arg_id = v_ak / phi_td
    const arg_id = v_ak.scale(1.0 / phi_td);
    const m_id_fwd = arg_id.minC(80.0).exp();
    // m_id_lin = (1 + (v_ak - v_max)/phi_td) * exp(min(v_max/phi_td, 80))
    const m_id_lin = v_ak.addC(-v_max).scale(1.0 / phi_td).addC(1.0).scale(contract.fmath.exp(@min(v_max / phi_td, 80.0)));
    const m_id = if (v_ak.val() < v_max) m_id_fwd else m_id_lin;
    // i_d = (m_id - 1) * idsat
    const i_d = m_id.addC(-1.0).scale(idsat);

    // ---- SRH current (Eq. 4.38-4.47) ----
    const do_srh = (csrh != 0.0) or (ctat != 0.0);

    // z_inv = sqrt(max(m_id, 1e-30)); z = 1/max(z_inv, 1e-30)
    const z_inv_raw = m_id.maxC(1.0e-30).sqrt();
    const z_raw = S.con(1.0).div(z_inv_raw.maxC(1.0e-30));

    // psi_star (Eq. 4.40) -- two branches for v_ak > 0 and v_ak <= 0
    // fwd = phi_td * log(max(z + sqrt(max((z+1)(z+3), 1e-30)), 1e-30))
    const fwd_inner = z_raw.addC(1.0).mul(z_raw.addC(3.0)).maxC(1.0e-30).sqrt().add(z_raw).maxC(1.0e-30);
    const fwd_psi = fwd_inner.log().scale(phi_td);
    // rev = -v_ak + phi_td * log(max(1 + 2*z_inv + sqrt(max((1+z_inv)(1+3*z_inv), 1e-30)), 1e-30))
    const rev_inner = z_inv_raw.addC(1.0).mul(z_inv_raw.scale(3.0).addC(1.0)).maxC(1.0e-30).sqrt().add(z_inv_raw.scale(2.0)).addC(1.0).maxC(1.0e-30);
    const rev_psi = v_ak.neg().add(rev_inner.log().scale(phi_td));
    const psi_star = if (v_ak.val() > 0.0) fwd_psi else rev_psi;

    // vj_lim, vj_srh (Eq. 4.41-4.42)
    // vj_lim = vbi_min - 2*psi_star
    const vj_lim = psi_star.scale(-2.0).addC(vbi_min);
    // vj_srh = hyp2(v_ak, vj_lim, phi_td) = v_ak - hyp1(v_ak - vj_lim, phi_td)
    const vj_srh = v_ak.sub(hyp1(S, v_ak.sub(vj_lim), phi_td));

    // w_srh (Eq. 4.43-4.45)
    // denom_w = vbi - vj_srh
    const denom_w = vj_srh.neg().addC(vbi);
    // ratio_w = 2*psi_star / max(denom_w, 1e-30)
    const ratio_w = psi_star.scale(2.0).div(denom_w.maxC(1.0e-30));
    // w_srh_step_inner = max(1 - ratio_w, 1e-30)
    const w_srh_step_inner = ratio_w.neg().addC(1.0).maxC(1.0e-30);
    // w_srh_step = 1 - sqrt(inner)
    const w_srh_step = w_srh_step_inner.sqrt().neg().addC(1.0);
    const w_srh_step_safe = w_srh_step.maxC(1.0e-30);
    const one_minus_w = w_srh_step.neg().addC(1.0).maxC(1.0e-30);
    // delta_w = (w_step^2 * log(w_step_safe)/one_minus_w + w_step) * (1 - 2*p)
    const delta_w = w_srh_step.mul(w_srh_step).mul(w_srh_step_safe.log()).div(one_minus_w).add(w_srh_step).scale(1.0 - 2.0 * p);
    const w_srh = w_srh_step.add(delta_w);

    // W_dep (Eq. 4.46)
    // w_dep_base = max((vbi - vj_srh)/max(vbir,1e-30), 1e-30)
    const w_dep_base = vj_srh.neg().addC(vbi).scale(1.0 / @max(vbir, 1.0e-30)).maxC(1.0e-30);
    // w_dep = xjun*EPS_SI/max(cjor,1e-30) * base^p
    const w_dep = w_dep_base.log().scale(p).exp().scale(xjun * EPS_SI / @max(cjor, 1.0e-30));

    // I_SRH (Eq. 4.47)
    // i_srh = csrh*ftd*(z_inv - 1)*w_srh*w_dep
    const i_srh_raw = z_inv_raw.addC(-1.0).scale(csrh * ftd).mul(w_srh).mul(w_dep);
    const i_srh = if (do_srh) i_srh_raw else S.con(0.0);

    // ---- TAT current (Eq. 4.48-4.62) ----
    const do_tat = ctat != 0.0;

    // F_max (Eq. 4.48) = (vbi - vj_srh) / max(w_dep*(1-p), 1e-30)
    const f_max = vj_srh.neg().addC(vbi).div(w_dep.scale(1.0 - p).maxC(1.0e-30));

    // m_eff (Eq. 4.49) -- f64
    const m_eff = mefftat * M0;

    // delta_E (Eq. 4.50) -- f64
    const delta_e = @max(phi_gd / 2.0, phi_td);

    // a_tat (Eq. 4.51) -- f64
    const a_tat = delta_e / phi_td;
    // b_tat (Eq. 4.52) = b_tat_num / max(3*HBAR*f_max, 1e-60)   (f_max is S)
    const b_tat_num = @sqrt(@max(32.0 * m_eff * QQ * delta_e * delta_e * delta_e, 0.0));
    const b_tat = S.con(b_tat_num).div(f_max.scale(3.0 * HBAR).maxC(1.0e-60));

    // u_max (Eq. 4.53-4.54)
    // u_max_prime = 2*a_tat^2 / max(3*b_tat, 1e-30)
    const u_max_prime = S.con(2.0 * a_tat * a_tat).div(b_tat.scale(3.0).maxC(1.0e-30));
    // u_max = sqrt(u_max_prime^2 / (u_max_prime^2 + 1))
    const u_max_p2 = u_max_prime.mul(u_max_prime);
    const u_max = u_max_p2.div(u_max_p2.addC(1.0)).sqrt();

    // w_gamma (Eq. 4.55)
    // u_max^(3/2) = u_max * sqrt(u_max)
    const u_max_3_2 = u_max.mul(u_max.maxC(1.0e-30).sqrt());
    // w_gamma = 1 + b_tat * u_max^(3/2) * p/(p-1)
    const w_gamma = b_tat.mul(u_max_3_2).scale(p / (p - 1.0)).addC(1.0);

    // w_tat (Eq. 4.56) = w_srh*w_gamma / max(w_srh + w_gamma, 1e-30)
    const w_tat = w_srh.mul(w_gamma).div(w_srh.add(w_gamma).maxC(1.0e-30));

    // k_tat, l_tat, m_tat (Eq. 4.57-4.59)
    const sqrt_u_max = u_max.maxC(1.0e-30).sqrt();
    // k_tat = sqrt(max(3*b_tat/(8*sqrt_u_max), 1e-30))
    const k_tat = b_tat.scale(3.0).div(sqrt_u_max.scale(8.0)).maxC(1.0e-30).sqrt();
    // l_tat = 4*a_tat/max(3*b_tat,1e-30) * sqrt_u_max - u_max
    const l_tat = S.con(4.0 * a_tat).div(b_tat.scale(3.0).maxC(1.0e-30)).mul(sqrt_u_max).sub(u_max);
    // m_tat = 2*a_tat^2/max(3*b_tat,1e-30)*sqrt_u_max - a_tat*u_max + b_tat/2*u_max^(3/2)
    const m_tat = S.con(2.0 * a_tat * a_tat).div(b_tat.scale(3.0).maxC(1.0e-30)).mul(sqrt_u_max).sub(u_max.scale(a_tat)).add(b_tat.scale(0.5).mul(u_max_3_2));

    // Gamma_max (Eq. 4.61)
    // erfc_arg = k_tat*(l_tat - 1)
    const erfc_arg = k_tat.mul(l_tat.addC(-1.0));
    const erfc_val = erfcapprox(S, erfc_arg);
    // gamma_max = a_tat * exp(min(m_tat, 80)) * erfc_val * sqrt(pi) / max(2*k_tat, 1e-30)
    const gamma_max = m_tat.minC(80.0).exp().scale(a_tat).mul(erfc_val).scale(1.7724538509055159).div(k_tat.scale(2.0).maxC(1.0e-30));

    // I_TAT (Eq. 4.62) = ctat*ftd*(z_inv - 1)*gamma_max*w_tat*w_dep
    const i_tat_raw = z_inv_raw.addC(-1.0).scale(ctat * ftd).mul(gamma_max).mul(w_tat).mul(w_dep);
    const i_tat = if (do_tat) i_tat_raw else S.con(0.0);

    // ---- BBT current (Eq. 4.63-4.68) ----
    const do_bbt = cbbt != 0.0;

    // V_BBT (Eq. 4.64) = hyp2(v_ak, vbbt_lim, phi_tr)
    const v_bbt = hyp2(S, v_ak, vbbt_lim, phi_tr);

    // W_dep_r (Eq. 4.65)
    // w_dep_r_base = max((vbir - v_bbt)/max(vbir,1e-30), 1e-30)
    const w_dep_r_base = v_bbt.neg().addC(vbir).scale(1.0 / @max(vbir, 1.0e-30)).maxC(1.0e-30);
    // w_dep_r = xjun*EPS_SI/max(cjor,1e-30) * base^p
    const w_dep_r = w_dep_r_base.log().scale(p).exp().scale(xjun * EPS_SI / @max(cjor, 1.0e-30));

    // F_max_r (Eq. 4.66) = (vbir - v_bbt)/max(w_dep_r*(1-p), 1e-30)
    const f_max_r = v_bbt.neg().addC(vbir).div(w_dep_r.scale(1.0 - p).maxC(1.0e-30));

    // F_BBT (Eq. 4.67) -- f64
    const f_bbt = fbbtr * (1.0 + stfbbt * (tkd - tkr));

    // I_BBT (Eq. 4.68)
    // i_bbt = cbbt*v_ak*f_max_r^2 * exp(min(-f_bbt/max(f_max_r,1e-30), 80))
    const exp_arg = S.con(-f_bbt).div(f_max_r.maxC(1.0e-30)); // = -f_bbt / max(f_max_r,1e-30)
    const i_bbt_raw = v_ak.scale(cbbt).mul(f_max_r).mul(f_max_r).mul(exp_arg.minC(80.0).exp());
    const i_bbt = if (do_bbt) i_bbt_raw else S.con(0.0);

    // ---- Avalanche and breakdown (Eq. 4.69-4.72) ----
    const do_av = vbr <= VBR_MAX;

    // V_av (Eq. 4.69) = hyp2(v_ak, 0, EPS_AV)
    const v_av = hyp2(S, v_ak, 0.0, EPS_AV);

    // f_stop, s_f (Eq. 4.70-4.71) -- alpha_av is f64, so these are f64
    const alpha_av_pbr = contract.fmath.exp(@min(pbr * contract.fmath.log(@max(@abs(alpha_av), 1.0e-30)), 80.0));
    const f_stop = 1.0 / @max(1.0 - alpha_av_pbr, 1.0e-30);
    const alpha_av_pbr_m1 = contract.fmath.exp(@min((pbr - 1.0) * contract.fmath.log(@max(@abs(alpha_av), 1.0e-30)), 80.0));
    const s_f = -f_stop * f_stop * alpha_av_pbr_m1 * pbr / @max(vbr, 1.0e-30);

    // f_breakdown (Eq. 4.72)
    // neg_v_av = -v_av; ratio_av = neg_v_av / max(vbr,1e-30)
    const ratio_av = v_av.scale(-1.0 / @max(vbr, 1.0e-30));
    // f_br_normal = exp(min(-pbr*log(max(1 - ratio_av, 1e-30)), 80))
    const f_br_normal = ratio_av.neg().addC(1.0).maxC(1.0e-30).log().scale(-pbr).minC(80.0).exp();
    const thresh_av = alpha_av * vbr;
    // f_br_linear = f_stop + (v_av + thresh_av)*s_f
    const f_br_linear = v_av.addC(thresh_av).scale(s_f).addC(f_stop);
    // v_av > -thresh_av ? normal : linear
    const f_br_computed = if (v_av.val() > -thresh_av) f_br_normal else f_br_linear;
    const f_breakdown = if (do_av) f_br_computed else S.con(1.0);

    // ---- Total current per unit area/length (Eq. 4.73) ----
    // i_j = ifactor*(i_d + i_srh + i_tat + i_bbt)*f_breakdown
    const i_sum = i_d.add(i_srh).add(i_tat).add(i_bbt).scale(ifactor);
    const i_j = i_sum.mul(f_breakdown);

    return .{ .i_j = i_j, .q_j = q_j };
}

// ============================================================================
// Temperature / geometry / parameter preprocessing (x-INDEPENDENT).
//
// Everything here is a pure function of model+instance; none of it depends on
// terminal voltages, so it stays plain f64 and is hoisted out of eval/q. The
// value-form physics reads these as constants.
// ============================================================================

const Prep = struct {
    type_f: f64,
    ifactor: f64,
    cfactor: f64,
    imax: f64,
    swjunexp: i32,
    frev: f64,

    // component params (f64)
    cjorbot: f64,
    cjorsti: f64,
    cjorgat: f64,
    vbirbot: f64,
    vbirsti: f64,
    vbirgat: f64,
    pbot: f64,
    psti: f64,
    pgat: f64,
    phigbot: f64,
    phigsti: f64,
    phiggat: f64,
    idsatrbot: f64,
    idsatrsti: f64,
    idsatrgat: f64,
    csrhbot: f64,
    csrhsti: f64,
    csrhgat: f64,
    xjunsti: f64,
    xjungat: f64,
    ctatbot: f64,
    ctatsti: f64,
    ctatgat: f64,
    mefftatbot: f64,
    mefftatsti: f64,
    mefftatgat: f64,
    cbbtbot: f64,
    cbbtsti: f64,
    cbbtgat: f64,
    fbbtrbot: f64,
    fbbtrsti: f64,
    fbbtrgat: f64,
    stfbbtbot: f64,
    stfbbtsti: f64,
    stfbbtgat: f64,
    vbrbot: f64,
    vbrsti: f64,
    vbrgat: f64,
    pbrbot: f64,
    pbrsti: f64,
    pbrgat: f64,
    vjunref: f64,

    // instance
    ab: f64,
    ls: f64,
    lg: f64,
    mult: f64,

    // temperature-derived
    tkr: f64,
    tkd: f64,
    phi_tr: f64,
    phi_td: f64,
    phi_gd_bot: f64,
    phi_gd_sti: f64,
    phi_gd_gat: f64,
    ftd_bot: f64,
    ftd_sti: f64,
    ftd_gat: f64,
    idsat_bot: f64,
    idsat_sti: f64,
    idsat_gat: f64,
    v_max: f64,
    vbi_bot: f64,
    vbi_sti: f64,
    vbi_gat: f64,
    vbi_min: f64,
    vf_min: f64,
    v_ch: f64,
    alpha_av: f64,
    vbbt_lim: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    // ---- Cast model parameters to f64 ----
    const type_f: f64 = @floatFromInt(model.type_);
    const ifactor: f64 = @as(f64, model.ifactor);
    const cfactor: f64 = @as(f64, model.cfactor);
    const trj: f64 = @as(f64, model.trj);
    const dta: f64 = @as(f64, model.dta);
    const imax: f64 = @as(f64, model.imax);
    const swjunexp: i32 = model.swjunexp;
    const frev: f64 = @as(f64, model.frev);

    const cjorbot: f64 = @as(f64, model.cjorbot);
    const cjorsti: f64 = @as(f64, model.cjorsti);
    const cjorgat: f64 = @as(f64, model.cjorgat);
    const vbirbot: f64 = @as(f64, model.vbirbot);
    const vbirsti: f64 = @as(f64, model.vbirsti);
    const vbirgat: f64 = @as(f64, model.vbirgat);
    const pbot: f64 = @as(f64, model.pbot);
    const psti: f64 = @as(f64, model.psti);
    const pgat: f64 = @as(f64, model.pgat);

    const phigbot: f64 = @as(f64, model.phigbot);
    const phigsti: f64 = @as(f64, model.phigsti);
    const phiggat: f64 = @as(f64, model.phiggat);
    const idsatrbot: f64 = @as(f64, model.idsatrbot);
    const idsatrsti: f64 = @as(f64, model.idsatrsti);
    const idsatrgat: f64 = @as(f64, model.idsatrgat);

    const csrhbot: f64 = @as(f64, model.csrhbot);
    const csrhsti: f64 = @as(f64, model.csrhsti);
    const csrhgat: f64 = @as(f64, model.csrhgat);
    const xjunsti: f64 = @as(f64, model.xjunsti);
    const xjungat: f64 = @as(f64, model.xjungat);

    const ctatbot: f64 = @as(f64, model.ctatbot);
    const ctatsti: f64 = @as(f64, model.ctatsti);
    const ctatgat: f64 = @as(f64, model.ctatgat);
    const mefftatbot: f64 = @as(f64, model.mefftatbot);
    const mefftatsti: f64 = @as(f64, model.mefftatsti);
    const mefftatgat: f64 = @as(f64, model.mefftatgat);

    const cbbtbot: f64 = @as(f64, model.cbbtbot);
    const cbbtsti: f64 = @as(f64, model.cbbtsti);
    const cbbtgat: f64 = @as(f64, model.cbbtgat);
    const fbbtrbot: f64 = @as(f64, model.fbbtrbot);
    const fbbtrsti: f64 = @as(f64, model.fbbtrsti);
    const fbbtrgat: f64 = @as(f64, model.fbbtrgat);
    const stfbbtbot: f64 = @as(f64, model.stfbbtbot);
    const stfbbtsti: f64 = @as(f64, model.stfbbtsti);
    const stfbbtgat: f64 = @as(f64, model.stfbbtgat);

    const vbrbot: f64 = @as(f64, model.vbrbot);
    const vbrsti: f64 = @as(f64, model.vbrsti);
    const vbrgat: f64 = @as(f64, model.vbrgat);
    const pbrbot: f64 = @as(f64, model.pbrbot);
    const pbrsti: f64 = @as(f64, model.pbrsti);
    const pbrgat: f64 = @as(f64, model.pbrgat);

    const vjunref: f64 = @as(f64, model.vjunref);

    const ab: f64 = instance.ab;
    const ls: f64 = instance.ls;
    const lg: f64 = instance.lg;
    const mult: f64 = instance.mult;
    const trise: f64 = instance.trise;

    // ---- Temperature calculations (Eq. 4.1-4.4) ----
    const tkr = T0 + trj;
    const t_a: f64 = 27.0; // default ambient
    const tkd = T0 + @max(t_a + dta + trise, T_MIN);
    const phi_tr = KB * tkr / QQ;
    const phi_td = KB * tkd / QQ;

    // ---- Band gap (Eq. 4.5-4.12) ----
    const delta_phi_gr = -7.02e-4 * tkr * tkr / (1108.0 + tkr);
    const phi_gr_bot = phigbot + delta_phi_gr;
    const phi_gr_sti = phigsti + delta_phi_gr;
    const phi_gr_gat = phiggat + delta_phi_gr;

    const delta_phi_gd = -7.02e-4 * tkd * tkd / (1108.0 + tkd);
    const phi_gd_bot = phigbot + delta_phi_gd;
    const phi_gd_sti = phigsti + delta_phi_gd;
    const phi_gd_gat = phiggat + delta_phi_gd;

    // ---- Intrinsic carrier concentration ratio (Eq. 4.13-4.15) ----
    const t_ratio = tkd / tkr;
    const t_ratio_1_5 = t_ratio * @sqrt(@max(t_ratio, 1.0e-30));

    const ftd_bot = t_ratio_1_5 * contract.fmath.exp(@min(phi_gr_bot / (2.0 * phi_tr) - phi_gd_bot / (2.0 * phi_td), 80.0));
    const ftd_sti = t_ratio_1_5 * contract.fmath.exp(@min(phi_gr_sti / (2.0 * phi_tr) - phi_gd_sti / (2.0 * phi_td), 80.0));
    const ftd_gat = t_ratio_1_5 * contract.fmath.exp(@min(phi_gr_gat / (2.0 * phi_tr) - phi_gd_gat / (2.0 * phi_td), 80.0));

    // ---- Saturation current density at device temperature (Eq. 4.16-4.18) ----
    const idsat_bot = idsatrbot * ftd_bot * ftd_bot;
    const idsat_sti = idsatrsti * ftd_sti * ftd_sti;
    const idsat_gat = idsatrgat * ftd_gat * ftd_gat;

    // ---- V_max (Eq. 4.19-4.22) ----
    const vmax_bot = if (idsat_bot * ab == 0.0) VMAX_LARGE else phi_td * contract.fmath.log(imax / (idsat_bot * ab) + 1.0);
    const vmax_sti = if (idsat_sti * ls == 0.0) VMAX_LARGE else phi_td * contract.fmath.log(imax / (idsat_sti * ls) + 1.0);
    const vmax_gat = if (idsat_gat * lg == 0.0) VMAX_LARGE else phi_td * contract.fmath.log(imax / (idsat_gat * lg) + 1.0);
    const v_max = @min(vmax_bot, @min(vmax_sti, vmax_gat));

    // ---- Built-in voltages (Eq. 4.23-4.28) ----
    const ubi_bot = vbirbot * t_ratio - 2.0 * phi_td * contract.fmath.log(@max(ftd_bot, 1.0e-30));
    const vbi_bot = ubi_bot + phi_td * contract.fmath.log(1.0 + contract.fmath.exp(@min((VBI_LOW - ubi_bot) / phi_td, 80.0)));

    const ubi_sti = vbirsti * t_ratio - 2.0 * phi_td * contract.fmath.log(@max(ftd_sti, 1.0e-30));
    const vbi_sti = ubi_sti + phi_td * contract.fmath.log(1.0 + contract.fmath.exp(@min((VBI_LOW - ubi_sti) / phi_td, 80.0)));

    const ubi_gat = vbirgat * t_ratio - 2.0 * phi_td * contract.fmath.log(@max(ftd_gat, 1.0e-30));
    const vbi_gat = ubi_gat + phi_td * contract.fmath.log(1.0 + contract.fmath.exp(@min((VBI_LOW - ubi_gat) / phi_td, 80.0)));

    // ---- V_F,min and V_ch (Eq. 4.29-4.31) ----
    const vbi_bot_eff = if (ab > 0.0) vbi_bot else 1.0e30;
    const vbi_sti_eff = if (ls > 0.0) vbi_sti else 1.0e30;
    const vbi_gat_eff = if (lg > 0.0) vbi_gat else 1.0e30;
    const vbi_min_raw = @min(vbi_bot_eff, @min(vbi_sti_eff, vbi_gat_eff));
    const vbi_min = if (vbi_min_raw > 1.0e29) vbi_bot else vbi_min_raw;

    const p_for_vfmin = if (ab > 0.0 and vbi_min == vbi_bot) pbot else if (ls > 0.0 and vbi_min == vbi_sti) psti else pgat;
    const vf_min = vbi_min * (1.0 - contract.fmath.exp(-1.0 / p_for_vfmin * contract.fmath.log(CAP_A)));
    const v_ch = EPS_CH * vbi_min;

    // ---- alpha_av (Eq. 4.32) ----
    const alpha_av = 1.0 - 1.0 / frev;

    // ---- V_BBT,lim (Eq. 4.63) ----
    const vbbt_lim = @min(vbirbot, @min(vbirsti, vbirgat)) - DELTA_VBI;

    return .{
        .type_f = type_f,
        .ifactor = ifactor,
        .cfactor = cfactor,
        .imax = imax,
        .swjunexp = swjunexp,
        .frev = frev,
        .cjorbot = cjorbot,
        .cjorsti = cjorsti,
        .cjorgat = cjorgat,
        .vbirbot = vbirbot,
        .vbirsti = vbirsti,
        .vbirgat = vbirgat,
        .pbot = pbot,
        .psti = psti,
        .pgat = pgat,
        .phigbot = phigbot,
        .phigsti = phigsti,
        .phiggat = phiggat,
        .idsatrbot = idsatrbot,
        .idsatrsti = idsatrsti,
        .idsatrgat = idsatrgat,
        .csrhbot = csrhbot,
        .csrhsti = csrhsti,
        .csrhgat = csrhgat,
        .xjunsti = xjunsti,
        .xjungat = xjungat,
        .ctatbot = ctatbot,
        .ctatsti = ctatsti,
        .ctatgat = ctatgat,
        .mefftatbot = mefftatbot,
        .mefftatsti = mefftatsti,
        .mefftatgat = mefftatgat,
        .cbbtbot = cbbtbot,
        .cbbtsti = cbbtsti,
        .cbbtgat = cbbtgat,
        .fbbtrbot = fbbtrbot,
        .fbbtrsti = fbbtrsti,
        .fbbtrgat = fbbtrgat,
        .stfbbtbot = stfbbtbot,
        .stfbbtsti = stfbbtsti,
        .stfbbtgat = stfbbtgat,
        .vbrbot = vbrbot,
        .vbrsti = vbrsti,
        .vbrgat = vbrgat,
        .pbrbot = pbrbot,
        .pbrsti = pbrsti,
        .pbrgat = pbrgat,
        .vjunref = vjunref,
        .ab = ab,
        .ls = ls,
        .lg = lg,
        .mult = mult,
        .tkr = tkr,
        .tkd = tkd,
        .phi_tr = phi_tr,
        .phi_td = phi_td,
        .phi_gd_bot = phi_gd_bot,
        .phi_gd_sti = phi_gd_sti,
        .phi_gd_gat = phi_gd_gat,
        .ftd_bot = ftd_bot,
        .ftd_sti = ftd_sti,
        .ftd_gat = ftd_gat,
        .idsat_bot = idsat_bot,
        .idsat_sti = idsat_sti,
        .idsat_gat = idsat_gat,
        .v_max = v_max,
        .vbi_bot = vbi_bot,
        .vbi_sti = vbi_sti,
        .vbi_gat = vbi_gat,
        .vbi_min = vbi_min,
        .vf_min = vf_min,
        .v_ch = v_ch,
        .alpha_av = alpha_av,
        .vbbt_lim = vbbt_lim,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

/// Sum of the three component currents at anode-cathode voltage v_ak (S).
/// Wraps the three juncapComponent calls (bottom/STI/gate) weighted by area
/// and length. Returns the geometry-weighted current I' (before type/mult).
inline fn currentSum(comptime S: type, v_ak: S, pp: *const Prep) S {
    const bot = juncapComponent(
        S,
        v_ak,
        pp.cjorbot, pp.vbirbot, pp.pbot, pp.phigbot, pp.idsatrbot,
        pp.csrhbot, 1.0, pp.ctatbot, pp.mefftatbot,
        pp.cbbtbot, pp.fbbtrbot, pp.stfbbtbot, pp.vbrbot, pp.pbrbot,
        pp.ifactor, pp.cfactor, pp.frev, pp.imax,
        pp.phi_tr, pp.phi_td, pp.tkr, pp.tkd,
        pp.ftd_bot, pp.idsat_bot, pp.vbi_bot, pp.phi_gd_bot,
        pp.vf_min, pp.v_ch, pp.vbi_min, pp.alpha_av, pp.v_max,
        pp.vbbt_lim,
    );
    const sti = juncapComponent(
        S,
        v_ak,
        pp.cjorsti, pp.vbirsti, pp.psti, pp.phigsti, pp.idsatrsti,
        pp.csrhsti, pp.xjunsti, pp.ctatsti, pp.mefftatsti,
        pp.cbbtsti, pp.fbbtrsti, pp.stfbbtsti, pp.vbrsti, pp.pbrsti,
        pp.ifactor, pp.cfactor, pp.frev, pp.imax,
        pp.phi_tr, pp.phi_td, pp.tkr, pp.tkd,
        pp.ftd_sti, pp.idsat_sti, pp.vbi_sti, pp.phi_gd_sti,
        pp.vf_min, pp.v_ch, pp.vbi_min, pp.alpha_av, pp.v_max,
        pp.vbbt_lim,
    );
    const gat = juncapComponent(
        S,
        v_ak,
        pp.cjorgat, pp.vbirgat, pp.pgat, pp.phiggat, pp.idsatrgat,
        pp.csrhgat, pp.xjungat, pp.ctatgat, pp.mefftatgat,
        pp.cbbtgat, pp.fbbtrgat, pp.stfbbtgat, pp.vbrgat, pp.pbrgat,
        pp.ifactor, pp.cfactor, pp.frev, pp.imax,
        pp.phi_tr, pp.phi_td, pp.tkr, pp.tkd,
        pp.ftd_gat, pp.idsat_gat, pp.vbi_gat, pp.phi_gd_gat,
        pp.vf_min, pp.v_ch, pp.vbi_min, pp.alpha_av, pp.v_max,
        pp.vbbt_lim,
    );
    // ab*bot + ls*sti + lg*gat
    return bot.i_j.scale(pp.ab).add(sti.i_j.scale(pp.ls)).add(gat.i_j.scale(pp.lg));
}

// ============================================================================
// Physics function: eval (value-form; stateless, non-history)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, 0.0);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const pp = pc.*;

    // ---- Anode-cathode voltage (Eq. 4.74) ----
    const v_ext = x[@intFromEnum(U.A)].sub(x[@intFromEnum(U.K)]);
    const v_ak = v_ext.scale(pp.type_f);

    // ---- Branch: full JUNCAP2 vs Express ----
    const ij_val = blk: {
        if (pp.swjunexp == 0) {
            // ---- Full JUNCAP2 (Section 4.3) ----
            // Total current (Eq. 4.82) = type * mult * (ab*bot + ls*sti + lg*gat)
            break :blk currentSum(S, v_ak, &pp).scale(pp.type_f * pp.mult);
        } else {
            // ---- JUNCAP Express (Section 4.4) ----
            // Initialization: evaluate the full model at 5 FIXED bias points
            // (these voltages do not depend on x, so their currents are plain
            // f64 -- extract via .val() and do the fitting in f64).
            const v1 = -0.4 * pp.vjunref;
            const v2 = -0.65 * pp.vjunref;
            const v3 = -0.8 * pp.vjunref;
            const v4: f64 = 0.1;
            const v5: f64 = 0.2;
            const phi_td = pp.phi_td;

            const curr1 = currentSum(S, S.con(v1), &pp).val();
            const curr2 = currentSum(S, S.con(v2), &pp).val();
            const curr3 = currentSum(S, S.con(v3), &pp).val();
            const curr4 = currentSum(S, S.con(v4), &pp).val();
            const curr5 = currentSum(S, S.con(v5), &pp).val();

            // --- Express fitting (Eq. 4.91-4.105) -- all x-independent f64 ---
            // Ideal forward current (Eq. 4.91-4.92)
            const i_satfor1 = pp.ab * pp.idsat_bot + pp.ls * pp.idsat_sti + pp.lg * pp.idsat_gat;
            const m_for1: f64 = 1.0;

            // g(V, I0, m) = I0 * (exp(V*m/phi_td) - 1)
            // Non-ideal forward (Eq. 4.93-4.97)
            const g_v4_for1 = i_satfor1 * (contract.fmath.exp(@min(v4 * m_for1 / phi_td, 80.0)) - 1.0);
            const g_v5_for1 = i_satfor1 * (contract.fmath.exp(@min(v5 * m_for1 / phi_td, 80.0)) - 1.0);
            const i4_cor = curr4 - g_v4_for1;
            const i5_cor = curr5 - g_v5_for1;
            const alpha_for = i4_cor / @max(@abs(i5_cor), 1.0e-30) * (if (i5_cor >= 0.0) @as(f64, 1.0) else @as(f64, -1.0));
            const m_for2 = phi_td * contract.fmath.log(@max(@abs(alpha_for), 1.0e-30)) / (v4 - v5);
            const i_satfor2 = i4_cor / @max(@abs(contract.fmath.exp(@min(v4 * m_for2 / phi_td, 80.0)) - 1.0), 1.0e-30);

            // Reverse current (Eq. 4.98-4.105)
            const g_v1_for1 = i_satfor1 * (contract.fmath.exp(@min(v1 * m_for1 / phi_td, 80.0)) - 1.0);
            const g_v1_for2 = i_satfor2 * (contract.fmath.exp(@min(v1 * m_for2 / phi_td, 80.0)) - 1.0);
            const g_v2_for1 = i_satfor1 * (contract.fmath.exp(@min(v2 * m_for1 / phi_td, 80.0)) - 1.0);
            const g_v2_for2 = i_satfor2 * (contract.fmath.exp(@min(v2 * m_for2 / phi_td, 80.0)) - 1.0);
            const g_v3_for1 = i_satfor1 * (contract.fmath.exp(@min(v3 * m_for1 / phi_td, 80.0)) - 1.0);
            const g_v3_for2 = i_satfor2 * (contract.fmath.exp(@min(v3 * m_for2 / phi_td, 80.0)) - 1.0);

            const i1_cor = curr1 - g_v1_for1 - g_v1_for2;
            const i2_cor = curr2 - g_v2_for1 - g_v2_for2;
            const i3_cor = curr3 - g_v3_for1 - g_v3_for2;

            const alpha_rev = i1_cor / @max(@abs(i2_cor), 1.0e-30) * (if (i2_cor >= 0.0) @as(f64, 1.0) else @as(f64, -1.0));
            const m0_rev = phi_td * contract.fmath.log(@max(@abs(alpha_rev), 1.0e-30)) / (v2 - v1);

            // delta_m (Eq. 4.103)
            const alpha_rev_abs = @max(@abs(alpha_rev), 1.0e-30);
            const alpha_rev_v2_dv = contract.fmath.exp(@min(v2 / (v2 - v1) * contract.fmath.log(alpha_rev_abs), 80.0));
            const alpha_rev_v1_dv = contract.fmath.exp(@min(v1 / (v1 - v2) * contract.fmath.log(alpha_rev_abs), 80.0));
            const delta_m_num = (alpha_rev - 1.0) * alpha_rev_v2_dv - 1.0;
            const delta_m_den = alpha_rev * v1 - v2 + (v2 - v1) * alpha_rev_v1_dv;
            const delta_m = phi_td * delta_m_num / @max(@abs(delta_m_den), 1.0e-30) * (if (delta_m_den >= 0.0) @as(f64, 1.0) else @as(f64, -1.0));

            const m_rev = m0_rev + delta_m;
            const i_satrev = -i3_cor / @max(@abs(contract.fmath.exp(@min(-v3 * m_rev / phi_td, 80.0)) - 1.0), 1.0e-30);

            // --- Express bias-dependent (Eq. 4.113-4.116) -- uses v_ak (S) ---
            // i_for1 = i_satfor1 * (exp(min(v_ak*m_for1/phi_td, 80)) - 1)
            const i_for1 = v_ak.scale(m_for1 / phi_td).minC(80.0).exp().addC(-1.0).scale(i_satfor1);
            // i_for2 = i_satfor2 * (exp(min(v_ak*m_for2/phi_td, 80)) - 1)
            const i_for2 = v_ak.scale(m_for2 / phi_td).minC(80.0).exp().addC(-1.0).scale(i_satfor2);
            // i_rev = -i_satrev * (exp(min(-v_ak*m_rev/phi_td, 80)) - 1)
            const i_rev = v_ak.scale(-m_rev / phi_td).minC(80.0).exp().addC(-1.0).scale(-i_satrev);

            break :blk i_for1.add(i_for2).add(i_rev).scale(pp.type_f * pp.mult);
        }
    };

    // Add GMIN for convergence: i_gmin = GMIN * v_ext
    const i_total = ij_val.add(v_ext.scale(GMIN));

    return .{ i_total, i_total.neg() };
}

// ============================================================================
// Charge function: q (value-form)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, 0.0);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = instance;

    const pp = pc.*;
    const fjunq: f64 = @as(f64, model.fjunq);

    // ---- Anode-cathode voltage ----
    const v_ak = x[@intFromEnum(U.A)].sub(x[@intFromEnum(U.K)]).scale(pp.type_f);

    // ---- Cjo per component (Eq. 4.33) -- x-independent f64 ----
    const cjo_bot = pp.cjorbot * contract.fmath.exp(pp.pbot * contract.fmath.log(@max(pp.vbirbot / @max(pp.vbi_bot, 1.0e-30), 1.0e-30)));
    const cjo_sti = pp.cjorsti * contract.fmath.exp(pp.psti * contract.fmath.log(@max(pp.vbirsti / @max(pp.vbi_sti, 1.0e-30), 1.0e-30)));
    const cjo_gat = pp.cjorgat * contract.fmath.exp(pp.pgat * contract.fmath.log(@max(pp.vbirgat / @max(pp.vbi_gat, 1.0e-30), 1.0e-30)));

    // ---- Vj (Eq. 4.34) ----
    const vj = hyp5(S, v_ak, pp.vf_min, pp.v_ch);

    // Per-component charge Q'j (Eq. 4.35): value-form helper.
    const qj = blk: {
        if (pp.swjunexp == 0) {
            // ---- Full model charge (Eq. 4.35 for each component) ----
            const qj_bot = componentCharge(S, v_ak, vj, cjo_bot, pp.vbi_bot, pp.pbot).scale(pp.cfactor);
            const qj_sti = componentCharge(S, v_ak, vj, cjo_sti, pp.vbi_sti, pp.psti).scale(pp.cfactor);
            const qj_gat = componentCharge(S, v_ak, vj, cjo_gat, pp.vbi_gat, pp.pgat).scale(pp.cfactor);

            break :blk qj_bot.scale(pp.ab).add(qj_sti.scale(pp.ls)).add(qj_gat.scale(pp.lg)).scale(pp.type_f * pp.mult);
        } else {
            // ---- Express charge model (Eq. 4.106-4.121) ----
            // Z values (Eq. 4.109-4.112) -- x-independent f64
            const z_bot = pp.ab * cjo_bot;
            const z_sti = pp.ls * cjo_sti;
            const z_gat = pp.lg * cjo_gat;
            const z_tot = z_bot + z_sti + z_gat;
            const z_thresh = fjunq * z_tot;

            // Bottom (Eq. 4.118) -- gated on Z threshold (x-independent)
            const qj_bot_full = componentCharge(S, v_ak, vj, cjo_bot, pp.vbi_bot, pp.pbot);
            const qj_bot = if (z_bot > z_thresh) qj_bot_full else S.con(0.0);

            // STI (Eq. 4.119)
            const qj_sti_full = componentCharge(S, v_ak, vj, cjo_sti, pp.vbi_sti, pp.psti);
            const qj_sti = if (z_sti > z_thresh) qj_sti_full else S.con(0.0);

            // Gate (Eq. 4.120)
            const qj_gat_full = componentCharge(S, v_ak, vj, cjo_gat, pp.vbi_gat, pp.pgat);
            const qj_gat = if (z_gat > z_thresh) qj_gat_full else S.con(0.0);

            break :blk qj_bot.scale(pp.ab).add(qj_sti.scale(pp.ls)).add(qj_gat.scale(pp.lg)).scale(pp.type_f * pp.mult);
        }
    };

    return .{ qj, qj.neg() };
}

// componentCharge -- depletion + overlap per unit area/length (Eq. 4.35),
// BEFORE the cfactor factor. Value-form.
//   depletion = cjo*vbi/(1-p) * (1 - (max(1 - vj/vbi, 1e-30))^(1-p))
//   overlap   = CAP_A * cjo * (v_ak - vj)
inline fn componentCharge(comptime S: type, v_ak: S, vj: S, cjo: f64, vbi: f64, p: f64) S {
    const one_m_p = 1.0 - p;
    const base = vj.scale(1.0 / @max(vbi, 1.0e-30)).neg().addC(1.0).maxC(1.0e-30);
    const dep = base.log().scale(one_m_p).exp().neg().addC(1.0).scale(cjo * vbi / one_m_p);
    const ovl = v_ak.sub(vj).scale(CAP_A * cjo);
    return dep.add(ovl);
}

// ============================================================================
// Voltage limiting: PN junction limiting (DEVpnjlim)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const type_f: f64 = @floatFromInt(model.type_);
    const dta: f64 = @as(f64, model.dta);
    const trise: f64 = instance.trise;

    const tkd = T0 + @max(27.0 + dta + trise, T_MIN);
    const phi_td = KB * tkd / QQ;

    // Compute V_AK old and new
    const va_new = x_new[@intFromEnum(U.A)];
    const vk_new = x_new[@intFromEnum(U.K)];
    const va_old = x_old[@intFromEnum(U.A)];
    const vk_old = x_old[@intFromEnum(U.K)];

    const vak_new = type_f * (va_new - vk_new);
    const vak_old = type_f * (va_old - vk_old);

    // PN junction voltage limiting (DEVpnjlim)
    // V_crit = phi_td * ln(phi_td / (sqrt(2) * IS))
    // Using IS ~ 1e-14 as representative saturation current
    const is_eff: f64 = 1.0e-14;
    const v_crit = phi_td * contract.fmath.log(phi_td / (1.4142135623730951 * is_eff));

    var vak_limited = vak_new;

    // Apply logarithmic damping if voltage exceeds critical
    if (vak_new > v_crit) {
        if (vak_old > 0.0) {
            const dv = vak_new - vak_old;
            if (dv > 0.0) {
                // Limit positive step
                const max_step = 2.0 * phi_td;
                if (dv > max_step) {
                    vak_limited = vak_old + phi_td * (1.0 + contract.fmath.log(@max(dv / phi_td, 1.0e-30)));
                }
            }
        } else {
            // Previous was reverse-biased, limit to v_crit
            vak_limited = v_crit;
        }
    }

    // Also limit large reverse steps to prevent avalanche overshoot
    if (vak_new < -5.0 and (vak_new - vak_old) < -2.0 * phi_td) {
        vak_limited = vak_old - phi_td * (1.0 + contract.fmath.log(@max(@abs(vak_new - vak_old) / phi_td, 1.0e-30)));
    }

    // Reconstruct voltages from limited vak
    const delta = vak_limited - vak_new;
    var result = x_new;
    result[@intFromEnum(U.A)] = va_new + type_f * delta * 0.5;
    result[@intFromEnum(U.K)] = vk_new - type_f * delta * 0.5;

    return result;
}

// ============================================================================
// Parameter stepping for convergence (GMIN stepping)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    // Scale saturation currents by adding gmin*(1-lambda) effect
    // At lambda=0: simplified model with larger leakage
    // At lambda=1: original model
    var m = model;
    const scale: f32 = @floatCast(1.0 + (1.0 - lambda) * 1.0e3);
    m.idsatrbot = model.idsatrbot * scale;
    m.idsatrsti = model.idsatrsti * scale;
    m.idsatrgat = model.idsatrgat * scale;
    return m;
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

test "juncap: zero bias -> zero current (only GMIN)" {
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 0.0 }, &model, &inst, 0);
    // v_ext = 0 -> i_d ~ 0, GMIN*0 = 0. Anode and cathode currents cancel.
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[1], 1e-12);
    // Charge at zero bias is 0 (v_ak = 0, vj = hyp5(0,...) small, depletion~0).
}

test "juncap: forward-bias current regression (exact old-formula value)" {
    // Default model, forward bias V_AK = 0.6 V. The expected value below is the
    // number the ORIGINAL pointer-form i() produces at this bias (verified by
    // running the old i() head-to-head against this eval): with the default
    // (extreme) SRH/TAT/avalanche params the anode current is large & negative.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.6, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, -8.159708719856691e34), out[0], 1e-12);
    // Anode/cathode currents are exactly opposite (KCL).
    try testing.expectApproxEqRel(out[0], -out[1], 1e-15);
}

test "juncap: reverse-bias current regression (exact old-formula value)" {
    // Reverse bias V_AK = -1 V. Expected value matches the original i().
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqRel(@as(f64, 9.354962592517517e20), out[0], 1e-12);
    try testing.expectApproxEqRel(out[0], -out[1], 1e-15);
}

test "juncap: charge is antisymmetric and grows under forward bias" {
    const model: Model = .{};
    const inst: Instance = .{};
    const q0 = contract.qValues(Self, .{ 0.0, 0.0 }, &model, &inst, 0);
    const qf = contract.qValues(Self, .{ 0.5, 0.0 }, &model, &inst, 0);
    // Antisymmetry (anode charge == -cathode charge).
    try testing.expectApproxEqAbs(q0[0], -q0[1], 1e-20);
    try testing.expectApproxEqAbs(qf[0], -qf[1], 1e-20);
    // Exact charge value at V_AK=0.5 (matches original pointer-form q()).
    try testing.expectApproxEqRel(@as(f64, 1.8065134498425745e-15), qf[0], 1e-12);
    // Forward bias increases the stored junction charge.
    try testing.expect(qf[0] > q0[0]);
}

test "juncap: type=-1 flips current sign" {
    // With type_ = -1, the diode conducts for negative external voltage.
    // At V_ext = -0.6, v_ak = +0.6 (forward), so out[0] < 0 (current into anode
    // node in external frame): compare against the type=+1 forward result.
    const mp: Model = .{ .type_ = 1 };
    const mn: Model = .{ .type_ = -1 };
    const inst: Instance = .{};
    const op = contract.evalValues(Self, .{ 0.6, 0.0 }, &mp, &inst, 0);
    const on = contract.evalValues(Self, .{ -0.6, 0.0 }, &mn, &inst, 0);
    // Physics magnitude identical; sign flipped by type and by v_ext sign.
    try testing.expectApproxEqAbs(op[0], -on[0], @abs(op[0]) * 1e-9 + 1e-15);
}
