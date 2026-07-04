// Diode CMC 3.0 -- Junction Diode Model
//
// JUNCAP2 200.5 base + Diode_CMC extensions:
//   series resistance, ideality factor, flicker noise, transit time,
//   breakdown temperature coefficients, geometry checks,
//   Hiroshima University recovery model (NQS carrier dynamics, high-injection)
//
// Three geometrical components: bottom (AB), STI-edge (LS), gate-edge (LG).
// Each component: depletion charge, ideal current, SRH, TAT, BBT, avalanche.
// Internal nodes: aik (series R), charge_a/charge_k/depl_a (NQS recovery).

const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminal enum  (external: a, k; internal: aik, charge_a, charge_k, depl_a)
// ============================================================================
pub const U = enum(u8) { a, k, aik, charge_a, charge_k, depl_a };
pub const num_ports: usize = 2;

pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // a
    .voltage, // k
    .voltage, // aik
    .flow, // charge_a  (NQS excess-carrier charge)
    .flow, // charge_k  (NQS excess-carrier charge)
    .flow, // depl_a    (NQS depletion width)
};

// ============================================================================
// Physical constants
// ============================================================================
const T0: f64 = 273.15;
const KB: f64 = 1.3806505e-23;
const QQ: f64 = 1.6021918e-19;
const HBAR: f64 = 1.05457168e-34;
const M0: f64 = 9.1093826e-31;
const EPS0: f64 = 8.8541878176e-12;
const EPSR_SI: f64 = 11.8;
const EPS_SI: f64 = EPS0 * EPSR_SI;
const NI0: f64 = 1.45e16; // m^-3
const MU_N0: f64 = 1450.0e-4; // m^2/(V s)
const MU_P0: f64 = 500.0e-4; // m^2/(V s)
const PHI_BI_CONST: f64 = 0.6; // V  (built-in potential for recovery model)

// Model constants
const TMIN: f64 = -250.0;
const VBI_LOW: f64 = 0.050;
const CAP_A: f64 = 2.0;
const EPS_CH: f64 = 0.1;
const DELTA_VBI: f64 = 0.050;
const EPS_AV: f64 = 1.0e-6;
const VBR_MAX: f64 = 1.0e6;
const VMAX_LARGE: f64 = 1.0e8;
const A_ERFC: f64 = 0.29214664;
const P_ERFC: f64 = 1.7724538509055159 * A_ERFC;
const B_ERFC: f64 = (6.0 - 5.0 * A_ERFC - 1.0 / (P_ERFC * P_ERFC)) / 3.0;
const C_ERFC: f64 = 1.0 - A_ERFC - B_ERFC;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const SQRT_PI_HALF: f64 = 0.8862269254527580; // sqrt(pi)/2

// ============================================================================
// Model parameters  (87 fields)
// ============================================================================
pub const Model = struct {
    // Version
    level: i32 = 2002,
    version: i32 = 3,
    subversion: i32 = 0,
    revision: i32 = 0,

    // General
    minr: f32 = 1.0e-3,
    imax: f32 = 1000.0,
    trj: f32 = 21.0,
    frev: f32 = 1.0e3,
    swbv: f32 = 1.0,
    swjunexp: f32 = 0.0,
    xti: f32 = 3.0,
    scale: f32 = 1.0,
    shrink: f32 = 0.0,
    expceil: f32 = 1.0e20,

    // Capacitance
    cjorbot: f32 = 1.0e-3,
    cjorsti: f32 = 1.0e-9,
    cjorgat: f32 = 1.0e-9,
    vbirbot: f32 = 1.0,
    vbirsti: f32 = 1.0,
    vbirgat: f32 = 1.0,
    pbot: f32 = 0.5,
    psti: f32 = 0.5,
    pgat: f32 = 0.5,

    // Ideal current
    phigbot: f32 = 1.16,
    phigsti: f32 = 1.16,
    phiggat: f32 = 1.16,
    idsatrbot: f32 = 1.0e-12,
    idsatrsti: f32 = 1.0e-18,
    idsatrgat: f32 = 1.0e-18,
    nfabot: f32 = 1.0,
    nfasti: f32 = 1.0,
    nfagat: f32 = 1.0,

    // SRH
    csrhbot: f32 = 1.0e2,
    csrhsti: f32 = 1.0e-4,
    csrhgat: f32 = 1.0e-4,
    xjunsti: f32 = 1.0e-7,
    xjungat: f32 = 1.0e-7,

    // TAT
    ctatbot: f32 = 1.0e2,
    ctatsti: f32 = 1.0e-4,
    ctatgat: f32 = 1.0e-4,
    mefftatbot: f32 = 0.25,
    mefftatsti: f32 = 0.25,
    mefftatgat: f32 = 0.25,

    // BBT
    cbbtbot: f32 = 1.0e-12,
    cbbtsti: f32 = 1.0e-18,
    cbbtgat: f32 = 1.0e-18,
    fbbtrbot: f32 = 1.0e9,
    fbbtrsti: f32 = 1.0e9,
    fbbtrgat: f32 = 1.0e9,
    stfbbtbot: f32 = -1.0e-3,
    stfbbtsti: f32 = -1.0e-3,
    stfbbtgat: f32 = -1.0e-3,

    // Avalanche / breakdown
    vbrbot: f32 = 10.0,
    vbrsti: f32 = 10.0,
    vbrgat: f32 = 10.0,
    pbrbot: f32 = 4.0,
    pbrsti: f32 = 4.0,
    pbrgat: f32 = 4.0,
    stvbrbot1: f32 = 0.0,
    stvbrbot2: f32 = 0.0,
    stvbrsti1: f32 = 0.0,
    stvbrsti2: f32 = 0.0,
    stvbrgat1: f32 = 0.0,
    stvbrgat2: f32 = 0.0,

    // Series resistance
    rsbot: f32 = 0.0,
    rssti: f32 = 0.0,
    rsgat: f32 = 0.0,
    rscom: f32 = 0.0,
    strs: f32 = 0.0,

    // Noise
    kf: f32 = 0.0,
    af: f32 = 1.0,

    // Transit time
    tt: f32 = 0.0,

    // Geometry checking
    abmin: f32 = 0.0,
    abmax: f32 = 1.0,
    lsmin: f32 = 0.0,
    lsmax: f32 = 1.0,
    lgmin: f32 = 0.0,
    lgmax: f32 = 1.0,
    tempmin: f32 = -55.0,
    tempmax: f32 = 155.0,
    vfmax: f32 = 0.0,
    vrmax: f32 = 0.0,

    // JUNCAP Express
    vjunref: f32 = 2.5,
    fjunq: f32 = 0.03,

    // Recovery / high-injection (Hiroshima model)
    corecovery: i32 = 0,
    tnom: f32 = 21.0, // alias for trj
    njh: f32 = 1.0,
    njdv: f32 = 0.1,
    ndibot: f32 = 1.0e16, // cm^-3 (converted to m^-3 in equations)
    ndisti: f32 = 1.0e16,
    ndigat: f32 = 1.0e16,
    inj1: f32 = 1.0,
    inj2: f32 = 10.0,
    nqs: f32 = 5.0e-9,
    tau: f32 = 2.0e-7,
    wi: f32 = 5.0e-6,
    depnqs: f32 = 0.0,
    taut: f32 = 0.0,
    injt: f32 = 0.0,
};

// ============================================================================
// Instance parameters  (4 fields)
// ============================================================================
pub const Instance = struct {
    ab: f32 = 1.0e-12,
    ls: f32 = 1.0e-6,
    lg: f32 = 0.0,
    dta: f32 = 0.0,
};

// ============================================================================
// Sparse stamp patterns
// ============================================================================
pub const g_pattern_override = [_]contract.Entry(n_u){
    // junction branch (a <-> aik)
    .{ .row = @intFromEnum(U.a), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.a), .col = @intFromEnum(U.aik) },
    .{ .row = @intFromEnum(U.aik), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.aik), .col = @intFromEnum(U.aik) },
    // resistor branch (aik <-> k)
    .{ .row = @intFromEnum(U.aik), .col = @intFromEnum(U.k) },
    .{ .row = @intFromEnum(U.k), .col = @intFromEnum(U.aik) },
    .{ .row = @intFromEnum(U.k), .col = @intFromEnum(U.k) },
    // NQS: charge_a depends on V_AK (a, aik) and itself
    .{ .row = @intFromEnum(U.charge_a), .col = @intFromEnum(U.charge_a) },
    .{ .row = @intFromEnum(U.charge_a), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.charge_a), .col = @intFromEnum(U.aik) },
    // NQS: charge_k depends on V_AK (a, aik) and itself
    .{ .row = @intFromEnum(U.charge_k), .col = @intFromEnum(U.charge_k) },
    .{ .row = @intFromEnum(U.charge_k), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.charge_k), .col = @intFromEnum(U.aik) },
    // NQS: depl_a depends on V_AK (a, aik) and itself
    .{ .row = @intFromEnum(U.depl_a), .col = @intFromEnum(U.depl_a) },
    .{ .row = @intFromEnum(U.depl_a), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.depl_a), .col = @intFromEnum(U.aik) },
};

pub const c_pattern_override = [_]contract.Entry(n_u){
    // junction charge (a <-> aik)
    .{ .row = @intFromEnum(U.a), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.a), .col = @intFromEnum(U.aik) },
    .{ .row = @intFromEnum(U.aik), .col = @intFromEnum(U.a) },
    .{ .row = @intFromEnum(U.aik), .col = @intFromEnum(U.aik) },
    // NQS capacitance (self)
    .{ .row = @intFromEnum(U.charge_a), .col = @intFromEnum(U.charge_a) },
    .{ .row = @intFromEnum(U.charge_k), .col = @intFromEnum(U.charge_k) },
    .{ .row = @intFromEnum(U.depl_a), .col = @intFromEnum(U.depl_a) },
};

// ============================================================================
// Noise generators
// ============================================================================
pub const noise_gens = [_]contract.NoiseGen(Self){
    .{ .row = @intFromEnum(U.a), .col = @intFromEnum(U.aik), .kind = .shot },
    .{ .row = @intFromEnum(U.a), .col = @intFromEnum(U.aik), .kind = .flicker },
    .{ .row = @intFromEnum(U.aik), .col = @intFromEnum(U.k), .kind = .thermal },
};

// ============================================================================
// Inline helpers (f64)  -- used by x-INDEPENDENT parameter/temperature prep
// and by the Express-model sample-voltage kernels (which are all f64 constants)
// ============================================================================

/// Clamped exponential -- clamps argument to [-230, +80] to prevent overflow
inline fn expc(x: f64) f64 {
    return @exp(@max(@min(x, 80.0), -230.0));
}

// Safe exponential constants for expl
const S_E05: f64 = 230.25850929940457; // ln(10^100)
const K_E05: f64 = 1.0e-100; // 10^-100

/// P3 polynomial tail: P3(u) = 1 + u*(1 + u/2*(1 + u/3))
inline fn p3(u: f64) f64 {
    return 1.0 + u * (1.0 + 0.5 * u * (1.0 + u / 3.0));
}

/// Safe exponential function (spec section 'Safe Exponential Function')
/// Three-region polynomial-tailed safe exponential:
///   x < -s_e05:  k_e05 / P3(-s_e05 - x)
///   |x| <= s_e05: exp(x)
///   x > s_e05:   (1/k_e05) * P3(x - s_e05)
inline fn expl(x: f64) f64 {
    const low = K_E05 / @max(p3(-S_E05 - x), 1.0e-300);
    const mid = @exp(@max(@min(x, S_E05), -S_E05));
    const high = p3(x - S_E05) / K_E05;
    const val_mid_or_high = if (x > S_E05) high else mid;
    return if (x < -S_E05) low else val_mid_or_high;
}

// ============================================================================
// Inline helpers (value-form: generic over scalar S)
// These take an x-dependent S argument mixed with f64 params. When the caller
// only has f64 (Express sample-voltage prep) they instantiate with
// contract.Value, which is pure f64.
// ============================================================================

/// smoothUpper (f64) -- clips x to <= xmax  (used for x-independent params)
inline fn smoothUpper(x: f64, xmax: f64, delta: f64) f64 {
    const f1 = xmax - x - delta;
    return xmax - 0.5 * (f1 + @sqrt(f1 * f1 + @abs(4.0 * xmax * delta)));
}

/// smoothLower (f64) -- clips x to >= xmin  (used for x-independent params)
inline fn smoothLower(x: f64, xmin: f64, delta: f64) f64 {
    const f1 = x - xmin - delta;
    return xmin + 0.5 * (f1 + @sqrt(f1 * f1 + @abs(4.0 * xmin * delta)));
}

/// Clamp emission coefficient to [nfa, njh] (f64) -- for x-independent
/// linearization at vmax inside the current kernels.
inline fn clampNj(raw: f64, nfa: f64, njh: f64) f64 {
    const lo = smoothLower(raw, nfa, 0.01 * nfa);
    return smoothUpper(lo, njh, 0.01 * njh);
}

/// Clamped exponential -- clamps argument to [-230, +80] to prevent overflow.
inline fn expcS(comptime S: type, x: S) S {
    return x.minC(80.0).maxC(-230.0).exp();
}

/// hyp1 -- smooth max(x, 0):  0.5*(x + sqrt(x*x + 4*eps*eps))
inline fn hyp1S(comptime S: type, x: S, eps: f64) S {
    return x.add(x.mul(x).addC(4.0 * eps * eps).sqrt()).scale(0.5);
}

/// hyp2 -- smooth min(x, x0):  x - hyp1(x - x0, eps)
inline fn hyp2S(comptime S: type, x: S, x0: f64, eps: f64) S {
    return x.sub(hyp1S(S, x.addC(-x0), eps));
}

/// hyp5 -- smooth min(x, x0) with improved derivative near x0:
///   x0 - hyp1(x0 - x - eps*eps/max(x0,1e-30), eps)
inline fn hyp5S(comptime S: type, x: S, x0: f64, eps: f64) S {
    const c = x0 - eps * eps / @max(x0, 1.0e-30); // (x0 - eps^2/max(x0)) is f64
    const arg = x.neg().addC(c); // c - x
    return hyp1S(S, arg, eps).neg().addC(x0);
}

/// smoothUpper -- clips x to <= xmax:
///   xmax - 0.5*(f1 + sqrt(f1*f1 + |4*xmax*delta|)),  f1 = xmax - x - delta
inline fn smoothUpperS(comptime S: type, x: S, xmax: f64, delta: f64) S {
    const f1 = x.neg().addC(xmax - delta); // xmax - x - delta
    const rad = f1.mul(f1).addC(@abs(4.0 * xmax * delta)).sqrt();
    return f1.add(rad).scale(0.5).neg().addC(xmax);
}

/// smoothLower -- clips x to >= xmin:
///   xmin + 0.5*(f1 + sqrt(f1*f1 + |4*xmin*delta|)),  f1 = x - xmin - delta
inline fn smoothLowerS(comptime S: type, x: S, xmin: f64, delta: f64) S {
    const f1 = x.addC(-xmin - delta); // x - xmin - delta
    const rad = f1.mul(f1).addC(@abs(4.0 * xmin * delta)).sqrt();
    return f1.add(rad).scale(0.5).addC(xmin);
}

/// calcerfcexpmtat -- combined erfc(y)*exp(m) for TAT integral
inline fn calcerfcexpmtatS(comptime S: type, y: S, m: S) S {
    const ay = y.abs();
    const t = S.con(1.0).div(ay.scale(P_ERFC).addC(1.0)); // 1/(1 + P_ERFC*|y|)
    const t2 = t.mul(t);
    const t3 = t2.mul(t);
    const poly = t.scale(A_ERFC).add(t2.scale(B_ERFC)).add(t3.scale(C_ERFC));
    const val_pos = poly.mul(expcS(S, y.mul(y).neg().add(m))); // poly*exp(-y*y + m)
    const val_neg = expcS(S, m).scale(2.0).sub(val_pos); // 2*exp(m) - val_pos
    return if (y.val() > 0.0) val_pos else val_neg;
}

/// Clamp emission coefficient to [nfa, njh] using smooth functions
inline fn clampNjS(comptime S: type, raw: S, nfa: f64, njh: f64) S {
    const lo = smoothLowerS(S, raw, nfa, 0.01 * nfa);
    return smoothUpperS(S, lo, njh, 0.01 * njh);
}

// ============================================================================
// Shared temperature / topology pre-computation
// ============================================================================

const Temps = struct {
    tkr: f64,
    tkd: f64,
    phi_tr: f64,
    phi_td: f64,
    dt: f64,
    ln_ratio: f64, // ln(tkd/tkr)
    ratio: f64, // tkd/tkr
};

inline fn computeTemps(trj: f64, dta: f64) Temps {
    const tkr = T0 + trj;
    const tkd = T0 + @max(trj + dta, TMIN);
    const phi_tr = KB * tkr / QQ;
    const phi_td = KB * tkd / QQ;
    const ratio = tkd / tkr;
    return .{
        .tkr = tkr,
        .tkd = tkd,
        .phi_tr = phi_tr,
        .phi_td = phi_td,
        .dt = tkd - tkr,
        .ln_ratio = @log(@max(ratio, 1.0e-30)),
        .ratio = ratio,
    };
}

const ComponentTemps = struct {
    ftd: f64,
    ftd2: f64,
    idsat: f64,
    vbi: f64,
    phi_gd: f64,
};

inline fn computeComponentTemps(
    t: Temps,
    xti: f64,
    phig: f64,
    vbir: f64,
    nfa: f64,
    idsatr: f64,
) ComponentTemps {
    const dphi_gr = -7.02e-4 * t.tkr * t.tkr / (1108.0 + t.tkr);
    const phi_gr = phig + dphi_gr;
    const dphi_gd = -7.02e-4 * t.tkd * t.tkd / (1108.0 + t.tkd);
    const phi_gd = phig + dphi_gd;

    const ftd = expc((xti / 2.0) * t.ln_ratio + phi_gr / (2.0 * t.phi_tr) - phi_gd / (2.0 * t.phi_td));
    const ftd2 = expc((xti / (2.0 * nfa)) * t.ln_ratio + (phi_gr / t.phi_tr - phi_gd / t.phi_td) / (2.0 * nfa));
    const idsat = idsatr * ftd2 * ftd2;

    const ubi = vbir * t.ratio - 2.0 * t.phi_td * @log(@max(ftd, 1.0e-30));
    const vbi = ubi + t.phi_td * @log(1.0 + expc((VBI_LOW - ubi) / t.phi_td));

    return .{
        .ftd = ftd,
        .ftd2 = ftd2,
        .idsat = idsat,
        .vbi = vbi,
        .phi_gd = phi_gd,
    };
}

// ============================================================================
// Per-component current kernel (value-form: v_ak, z_inv, psi_star, vj_srh,
// v_bbt, v_av are x-dependent scalars S; all remaining args are f64 params)
// ============================================================================
inline fn componentCurrent(
    comptime S: type,
    v_ak: S,
    vmax: f64,
    phi_td: f64,
    nfa: f64,
    njh: f64,
    njdv: f64,
    idsat: f64,
    vha: f64,
    csrh: f64,
    ctat: f64,
    cbbt: f64,
    xjun: f64,
    cjor: f64,
    vbi: f64,
    vbir: f64,
    p: f64,
    ftd: f64,
    phi_gd: f64,
    mefftat: f64,
    fbbtr: f64,
    stfbbt: f64,
    vbr: f64,
    pbr: f64,
    z_inv: S,
    psi_star: S,
    vj_srh: S,
    v_bbt: S,
    v_av: S,
    alpha_av: f64,
    swbv: f64,
    dt: f64,
    phi_tr: f64,
    expceil_val: f64,
) S {
    const nfa_njh = nfa * njh;
    const ceil_log = @log(@max(expceil_val, 1.0));

    // ---- Ideal current with bias-dependent emission coefficient ----
    const nj_a = clampNjS(S, v_ak.addC(-vha).scale(njdv).addC(nfa), nfa, njh); // njdv*(v_ak-vha)+nfa
    // exp_arg = (v_ak/nj_a + vha*(nj_a-nfa)/nfa_njh) / phi_td
    const exp_arg = v_ak.div(nj_a).add(nj_a.addC(-nfa).scale(vha / @max(nfa_njh, 1.0e-30))).scale(1.0 / phi_td);

    // Linearization at vmax (eq 2b, 3) -- vmax is f64, these are all f64
    const nj_vm = clampNj(njdv * (vmax - vha) + nfa, nfa, njh);
    const exp_arg_vm = (vmax / nj_vm + vha * (nj_vm - nfa) / @max(nfa_njh, 1.0e-30)) / phi_td;
    const dv_eff = ((nj_vm - vmax * njdv) / (nj_vm * nj_vm) + vha * njdv / @max(nfa_njh, 1.0e-30)) / phi_td;

    const m_id_fwd = expcS(S, exp_arg.minC(ceil_log));
    // m_id_lin = (1 + (v_ak - vmax)*dv_eff) * exp(min(exp_arg_vm, ceil_log))
    const m_id_lin = v_ak.addC(-vmax).scale(dv_eff).addC(1.0).scale(expc(@min(exp_arg_vm, ceil_log)));
    const m_id = if (v_ak.val() < vmax) m_id_fwd else m_id_lin;
    const i_d = m_id.addC(-1.0).scale(idsat);

    // ---- SRH current (4.43-4.47) ----
    const has_srh = csrh > 0.0 or ctat > 0.0;
    // denom = max(vbi - vj_srh, 1e-30)
    const denom = vj_srh.neg().addC(vbi).maxC(1.0e-30);
    // ratio_srh = min(2*psi_star/denom, 0.9999)
    const ratio_srh = psi_star.scale(2.0).div(denom).minC(0.9999);
    // w_step = 1 - sqrt(max(1 - ratio_srh, 1e-30))
    const w_step = ratio_srh.neg().addC(1.0).maxC(1.0e-30).sqrt().neg().addC(1.0);
    const ln_w = w_step.maxC(1.0e-30).log();
    // dw = (w_step^2 * ln_w / max(1-w_step,1e-30) + w_step) * (1-2p)   [0 if p==0.5]
    const dw = if (@abs(p - 0.5) < 1.0e-10)
        S.con(0.0)
    else
        w_step.mul(w_step).mul(ln_w).div(w_step.neg().addC(1.0).maxC(1.0e-30)).add(w_step).scale(1.0 - 2.0 * p);
    const w_srh = w_step.add(dw);
    // w_dep = xjun*EPS_SI/max(cjor,1e-30) * exp(p*log(max(denom/max(vbir,1e-30),1e-30)))
    const w_dep_pref = xjun * EPS_SI / @max(cjor, 1.0e-30);
    const w_dep = expcS(S, denom.scale(1.0 / @max(vbir, 1.0e-30)).maxC(1.0e-30).log().scale(p)).scale(w_dep_pref);
    const i_srh_v = if (has_srh)
        z_inv.addC(-1.0).mul(w_srh).mul(w_dep).scale(csrh * ftd)
    else
        S.con(0.0);

    // ---- TAT current (4.48-4.62) ----
    const has_tat = ctat > 0.0;
    // f_max_tat = denom / max(w_dep*(1-p), 1e-30)
    const f_max_tat = denom.div(w_dep.scale(1.0 - p).maxC(1.0e-30));
    const m_eff = mefftat * M0;
    const delta_e = @max(phi_gd / 2.0, phi_td);
    const a_tat = delta_e / phi_td; // f64
    // b_tat = sqrt(max(32*m_eff*QQ*delta_e^3,0)) / max(3*HBAR*f_max_tat, 1e-60)
    const b_num = @sqrt(@max(32.0 * m_eff * QQ * delta_e * delta_e * delta_e, 0.0)); // f64
    const b_tat = f_max_tat.scale(3.0 * HBAR).maxC(1.0e-60).pow(-1.0).scale(b_num); // b_num / max(3*HBAR*f_max_tat,1e-60)
    // u_pr = 2*a_tat/(3*b_tat)
    const u_pr = b_tat.scale(3.0).maxC(1.0e-30).pow(-1.0).scale(2.0 * a_tat);
    const u_pr_sq = u_pr.mul(u_pr); // u'_max = (2*a_tat/(3*b_tat))^2 (eq 4.53)
    // u_max = sqrt(u_pr_sq^2 / (u_pr_sq^2 + 1))  (eq 4.54)
    const u_pr_q = u_pr_sq.mul(u_pr_sq);
    const u_max = u_pr_q.div(u_pr_q.addC(1.0)).sqrt();
    const u_1p5 = u_max.mul(u_max.maxC(1.0e-30).sqrt());
    // w_gamma = exp(p/max(p-1,-0.99) * log(max(1 + b_tat*u_1p5, 1e-30)))
    const w_gamma = expcS(S, b_tat.mul(u_1p5).addC(1.0).maxC(1.0e-30).log().scale(p / @max(p - 1.0, -0.99)));
    // w_tat = w_srh*w_gamma / max(w_srh+w_gamma, 1e-30)
    const w_tat = w_srh.mul(w_gamma).div(w_srh.add(w_gamma).maxC(1.0e-30));
    const su = u_max.maxC(1.0e-30).sqrt();
    // k_tat = sqrt(max(3*b_tat/(8*su), 1e-30))
    const k_tat = b_tat.scale(3.0).div(su.scale(8.0)).maxC(1.0e-30).sqrt();
    // l_tat = 4*a_tat/(3*b_tat)*su - u_max
    const l_tat = su.scale(4.0 * a_tat).div(b_tat.scale(3.0).maxC(1.0e-30)).sub(u_max);
    // m_tat = 2*a_tat^2/(3*b_tat)*su - a_tat*u_max + b_tat/2*u_1p5
    const m_tat = su.scale(2.0 * a_tat * a_tat).div(b_tat.scale(3.0).maxC(1.0e-30))
        .sub(u_max.scale(a_tat))
        .add(b_tat.scale(0.5).mul(u_1p5));
    // gamma_max = SQRT_PI_HALF*a_tat * calcerfcexpmtat(k_tat*(l_tat-1), m_tat) / max(k_tat,1e-30)
    const gamma_max = calcerfcexpmtatS(S, k_tat.mul(l_tat.addC(-1.0)), m_tat).scale(SQRT_PI_HALF * a_tat).div(k_tat.maxC(1.0e-30));
    const i_tat_v = if (has_tat)
        z_inv.addC(-1.0).mul(gamma_max).mul(w_tat).mul(w_dep).scale(ctat * ftd)
    else
        S.con(0.0);

    // ---- BBT current (4.65-4.68) ----
    const has_bbt = cbbt > 0.0;
    // w_dep_r = xjun*EPS_SI/max(cjor,1e-30) * exp(p*log(max((vbir - v_bbt)/max(vbir,1e-30), 1e-30)))
    const w_dep_r = expcS(S, v_bbt.neg().addC(vbir).scale(1.0 / @max(vbir, 1.0e-30)).maxC(1.0e-30).log().scale(p)).scale(w_dep_pref);
    // f_max_r = (vbir - v_bbt) / max(w_dep_r*(1-p), 1e-30)
    const f_max_r = v_bbt.neg().addC(vbir).div(w_dep_r.scale(1.0 - p).maxC(1.0e-30));
    const f_bbt = fbbtr * (1.0 + stfbbt * dt); // f64
    // i_bbt = cbbt*v_ak*f_max_r^2 * exp(-f_bbt/max(f_max_r,1e-30))
    const i_bbt_v = if (has_bbt)
        v_ak.mul(f_max_r).mul(f_max_r).scale(cbbt).mul(expcS(S, f_max_r.maxC(1.0e-30).pow(-1.0).scale(-f_bbt)))
    else
        S.con(0.0);
    _ = phi_tr;

    // ---- Avalanche / breakdown (4.69-4.72) ----
    const bv_on = swbv > 0.5 and vbr < VBR_MAX;
    const alpha_pbr = expc(pbr * @log(@max(alpha_av, 1.0e-30))); // f64
    const f_stop = 1.0 / @max(1.0 - alpha_pbr, 1.0e-30); // f64
    const alpha_pbr_m1 = expc((pbr - 1.0) * @log(@max(alpha_av, 1.0e-30))); // f64
    const s_f = -f_stop * f_stop * alpha_pbr_m1 * pbr / @max(vbr, 1.0e-30); // f64
    // ratio_av = |v_av| / max(vbr,1e-30)
    const ratio_av = v_av.abs().scale(1.0 / @max(vbr, 1.0e-30));
    // f_br_n = 1 / max(1 - exp(pbr*log(max(ratio_av,1e-30))), 1e-30)
    const f_br_n = expcS(S, ratio_av.maxC(1.0e-30).log().scale(pbr)).neg().addC(1.0).maxC(1.0e-30).pow(-1.0);
    // f_br_l = f_stop + (v_av + alpha_av*vbr)*s_f
    const f_br_l = v_av.addC(alpha_av * vbr).scale(s_f).addC(f_stop);
    const f_br = if (v_av.val() > -alpha_av * vbr) f_br_n else f_br_l;
    const f_breakdown = if (bv_on) f_br else S.con(1.0);

    return i_d.add(i_srh_v).add(i_tat_v).add(i_bbt_v).mul(f_breakdown);
}

// ============================================================================
// Per-component charge kernel (eq 4.35)  (vj, v_ak are x-dependent S)
// ============================================================================
inline fn componentCharge(comptime S: type, vj: S, v_ak: S, cjo: f64, vbi: f64, p: f64) S {
    const one_m_p = 1.0 - p;
    // ratio = max(1 - vj/max(vbi,1e-30), 1e-30)
    const ratio = vj.scale(-1.0 / @max(vbi, 1.0e-30)).addC(1.0).maxC(1.0e-30);
    // q_dep = cjo*vbi/max(one_m_p,1e-30) * (1 - exp(one_m_p*log(ratio)))
    const q_dep = expcS(S, ratio.log().scale(one_m_p)).neg().addC(1.0).scale(cjo * vbi / @max(one_m_p, 1.0e-30));
    // + CAP_A*cjo*(v_ak - vj)
    return q_dep.add(v_ak.sub(vj).scale(CAP_A * cjo));
}

// ============================================================================
// Per-component ideal current only (for diffusion charge)  (v_ak is S)
// ============================================================================
inline fn componentIdealCurrent(
    comptime S: type,
    v_ak: S,
    vmax: f64,
    phi_td: f64,
    nfa: f64,
    njh: f64,
    njdv: f64,
    idsat: f64,
    vha: f64,
    expceil_val: f64,
) S {
    const nfa_njh = nfa * njh;
    const ceil_log = @log(@max(expceil_val, 1.0));

    const nj = clampNjS(S, v_ak.addC(-vha).scale(njdv).addC(nfa), nfa, njh);
    const exp_arg = v_ak.div(nj).add(nj.addC(-nfa).scale(vha / @max(nfa_njh, 1.0e-30))).scale(1.0 / phi_td);

    const nj_vm = clampNj(njdv * (vmax - vha) + nfa, nfa, njh);
    const exp_arg_vm = (vmax / nj_vm + vha * (nj_vm - nfa) / @max(nfa_njh, 1.0e-30)) / phi_td;
    const dv = ((nj_vm - vmax * njdv) / (nj_vm * nj_vm) + vha * njdv / @max(nfa_njh, 1.0e-30)) / phi_td;

    const m_fwd = expcS(S, exp_arg.minC(ceil_log));
    const m_lin = v_ak.addC(-vmax).scale(dv).addC(1.0).scale(expc(@min(exp_arg_vm, ceil_log)));
    const m_id = if (v_ak.val() < vmax) m_fwd else m_lin;
    return m_id.addC(-1.0).scale(idsat);
}

/// Compute V_HA for a component (eq 7-9)  (pure f64, no x)
inline fn computeVHA(phi_td: f64, nfa: f64, ndi: f64, ftd2: f64) f64 {
    const n_in = NI0 * ftd2;
    const pn0 = n_in * n_in / @max(ndi, 1.0e-30);
    return phi_td * nfa * @log(@max(ndi / @max(pn0, 1.0e-30), 1.0));
}

// ============================================================================
// JUNCAP Express model helpers (eqs 4.84-4.122)
// ============================================================================

/// Safe exponential with linear extrapolation beyond x_high for Express model (f64)
inline fn expll(arg: f64, x_high: f64) f64 {
    const e_high = expc(x_high);
    const lin = e_high * (1.0 + arg - x_high);
    return if (arg > x_high) lin else expc(arg);
}

/// Express exponential fit: g(V, I0, m) = I0 * [exp(V*m/phi_td) - 1]  (eq 4.90, f64)
inline fn gExpFit(v: f64, isat: f64, m: f64, phi_td: f64) f64 {
    return isat * (expll(v * m / phi_td, 80.0) - 1.0);
}

/// Value-form Express exp with linear extrapolation beyond x_high (v is S).
inline fn expllS(comptime S: type, arg: S, x_high: f64) S {
    const e_high = expc(x_high); // f64
    // lin = e_high*(1 + arg - x_high)
    const lin = arg.addC(1.0 - x_high).scale(e_high);
    return if (arg.val() > x_high) lin else expcS(S, arg);
}

/// Value-form Express exp fit (v is S).
inline fn gExpFitS(comptime S: type, v: S, isat: f64, m: f64, phi_td: f64) S {
    return expllS(S, v.scale(m / phi_td), 80.0).addC(-1.0).scale(isat);
}

/// Pre-computed Express parameters
const ExpressParams = struct {
    i_satfor1: f64,
    m_for1: f64,
    i_satfor2: f64,
    m_for2: f64,
    i_satrev: f64,
    m_rev: f64,
};

/// Compute Express initialization parameters (eqs 4.84-4.105)
/// This evaluates the full model at five sample voltages and extracts exponential fit parameters.
/// Entirely x-INDEPENDENT (sample voltages are constants), so stays f64: the
/// component kernels are instantiated with contract.Value (plain-f64 scalar).
inline fn computeExpressParams(
    phi_td: f64,
    phi_tr: f64,
    vjunref: f64,
    AB: f64,
    LS: f64,
    LG: f64,
    vmax: f64,
    nfabot: f64,
    nfasti: f64,
    nfagat: f64,
    njh: f64,
    njdv: f64,
    ct_bot: ComponentTemps,
    ct_sti: ComponentTemps,
    ct_gat: ComponentTemps,
    vha_bot: f64,
    vha_sti: f64,
    vha_gat: f64,
    csrhbot: f64,
    csrhsti: f64,
    csrhgat: f64,
    ctatbot: f64,
    ctatsti: f64,
    ctatgat: f64,
    cbbtbot: f64,
    cbbtsti: f64,
    cbbtgat: f64,
    xjunsti: f64,
    xjungat: f64,
    cjorbot: f64,
    cjorsti: f64,
    cjorgat: f64,
    vbirbot: f64,
    vbirsti: f64,
    vbirgat: f64,
    pbot: f64,
    psti: f64,
    pgat: f64,
    mefftatbot: f64,
    mefftatsti: f64,
    mefftatgat: f64,
    fbbtrbot: f64,
    fbbtrsti: f64,
    fbbtrgat: f64,
    stfbbtbot: f64,
    stfbbtsti: f64,
    stfbbtgat: f64,
    vbr_bot: f64,
    vbr_sti: f64,
    vbr_gat: f64,
    pbrbot: f64,
    pbrsti: f64,
    pbrgat: f64,
    alpha_av: f64,
    swbv: f64,
    dt: f64,
    vbi_min: f64,
    expceil_val: f64,
) ExpressParams {
    const V = contract.Value; // plain-f64 scalar: keeps this whole block f64

    // Initialization voltages (4.84-4.88)
    const v1 = -0.4 * vjunref;
    const v2 = -0.65 * vjunref;
    const v3 = -0.8 * vjunref;
    const v4: f64 = 0.1;
    const v5: f64 = 0.2;

    // Evaluate full model at each sample voltage (4.89)
    const voltages = [5]f64{ v1, v2, v3, v4, v5 };
    var currents: [5]f64 = undefined;

    inline for (0..5) |vi| {
        const vv = voltages[vi];
        const ha = @min(vv / (2.0 * phi_td), 40.0);
        const zi = @exp(ha);
        const zz = @exp(-ha);
        const pp = phi_td * @log(@max(zz + 2.0 + @sqrt(@max((zz + 1.0) * (zz + 3.0), 1.0e-30)), 1.0e-30));
        const pn = -vv + phi_td * @log(@max(1.0 + 2.0 * zi + @sqrt(@max((1.0 + zi) * (1.0 + 3.0 * zi), 1.0e-30)), 1.0e-30));
        const ps = if (vv > 0.0) pp else pn;
        const vjl = vbi_min - 2.0 * ps;
        const vjs = hyp2S(V, V.con(vv), vjl, phi_td).val();
        const vbl = @min(vbirbot, @min(vbirsti, vbirgat)) - DELTA_VBI;
        const vbb = hyp2S(V, V.con(vv), vbl, phi_tr).val();
        const vav = hyp2S(V, V.con(vv), 0.0, EPS_AV).val();

        const ib = componentCurrent(V, V.con(vv), vmax, phi_td, nfabot, njh, njdv, ct_bot.idsat, vha_bot, csrhbot, ctatbot, cbbtbot, 1.0, cjorbot, ct_bot.vbi, vbirbot, pbot, ct_bot.ftd, ct_bot.phi_gd, mefftatbot, fbbtrbot, stfbbtbot, vbr_bot, pbrbot, V.con(zi), V.con(ps), V.con(vjs), V.con(vbb), V.con(vav), alpha_av, swbv, dt, phi_tr, expceil_val).val();
        const is = componentCurrent(V, V.con(vv), vmax, phi_td, nfasti, njh, njdv, ct_sti.idsat, vha_sti, csrhsti, ctatsti, cbbtsti, xjunsti, cjorsti, ct_sti.vbi, vbirsti, psti, ct_sti.ftd, ct_sti.phi_gd, mefftatsti, fbbtrsti, stfbbtsti, vbr_sti, pbrsti, V.con(zi), V.con(ps), V.con(vjs), V.con(vbb), V.con(vav), alpha_av, swbv, dt, phi_tr, expceil_val).val();
        const ig = componentCurrent(V, V.con(vv), vmax, phi_td, nfagat, njh, njdv, ct_gat.idsat, vha_gat, csrhgat, ctatgat, cbbtgat, xjungat, cjorgat, ct_gat.vbi, vbirgat, pgat, ct_gat.ftd, ct_gat.phi_gd, mefftatgat, fbbtrgat, stfbbtgat, vbr_gat, pbrgat, V.con(zi), V.con(ps), V.con(vjs), V.con(vbb), V.con(vav), alpha_av, swbv, dt, phi_tr, expceil_val).val();

        currents[vi] = AB * ib + LS * is + LG * ig;
    }

    // Ideal forward current parameters (4.91-4.92)
    const i_satfor1 = AB * ct_bot.idsat + LS * ct_sti.idsat + LG * ct_gat.idsat;
    const m_for1 = nfabot; // eq 4.92: must be same for all active components in Express

    // Non-ideal forward current parameters (4.93-4.97)
    const i4_cor = currents[3] - gExpFit(v4, i_satfor1, m_for1, phi_td);
    const i5_cor = currents[4] - gExpFit(v5, i_satfor1, m_for1, phi_td);
    const alpha_for = i4_cor / @max(@abs(i5_cor), 1.0e-300) * (if (i5_cor < 0.0) @as(f64, -1.0) else 1.0);
    const m_for2 = phi_td * @log(@max(@abs(alpha_for), 1.0e-300)) / (v4 - v5);
    const i_satfor2 = i4_cor / @max(expll(v4 * m_for2 / phi_td, 80.0) - 1.0, 1.0e-300);

    // Reverse current parameters (4.98-4.105)
    const i1_cor = currents[0] - gExpFit(v1, i_satfor1, m_for1, phi_td) - gExpFit(v1, i_satfor2, m_for2, phi_td);
    const i2_cor = currents[1] - gExpFit(v2, i_satfor1, m_for1, phi_td) - gExpFit(v2, i_satfor2, m_for2, phi_td);
    const i3_cor = currents[2] - gExpFit(v3, i_satfor1, m_for1, phi_td) - gExpFit(v3, i_satfor2, m_for2, phi_td);

    const alpha_rev = i1_cor / @max(@abs(i2_cor), 1.0e-300) * (if (i2_cor < 0.0) @as(f64, -1.0) else 1.0);
    const m0_rev = phi_td * @log(@max(@abs(alpha_rev), 1.0e-300)) / (v2 - v1); // eq 4.102
    // Delta m (eq 4.103)
    const ar_v2 = expc(v2 / (v2 - v1) * @log(@max(@abs(alpha_rev), 1.0e-300)));
    const ar_v1_inv = expc(v1 / (v1 - v2) * @log(@max(@abs(alpha_rev), 1.0e-300)));
    const delta_m = phi_td * (alpha_rev - 1.0) * (ar_v2 - 1.0) / @max(@abs(ar_v1_inv * (v2 - v1) + alpha_rev * v1 - v2), 1.0e-300) * (if ((ar_v1_inv * (v2 - v1) + alpha_rev * v1 - v2) < 0.0) @as(f64, -1.0) else 1.0);
    const m_rev = m0_rev + delta_m;
    const i_satrev = -i3_cor / @max(expll(-v3 * m_rev / phi_td, 80.0) - 1.0, 1.0e-300);

    return .{
        .i_satfor1 = i_satfor1,
        .m_for1 = m_for1,
        .i_satfor2 = i_satfor2,
        .m_for2 = m_for2,
        .i_satrev = i_satrev,
        .m_rev = m_rev,
    };
}

// ============================================================================
// Prep struct: x-independent derived values shared by eval and q
// ============================================================================

const CmcPrep = struct {
    // Geometry
    AB: f64,
    LS: f64,
    LG: f64,
    // Temperature
    t: Temps,
    // Component temps
    ct_bot: ComponentTemps,
    ct_sti: ComponentTemps,
    ct_gat: ComponentTemps,
    // Derived eval constants
    vmax: f64,
    vbi_min: f64,
    alpha_av: f64,
    vbr_bot: f64,
    vbr_sti: f64,
    vbr_gat: f64,
    g_rs: f64,
    vha_bot: f64,
    vha_sti: f64,
    vha_gat: f64,
    pn0_bot: f64,
    // Express params
    ep: ExpressParams,
    use_express: bool,
    // Model params passed through (eval needs)
    nfabot: f64,
    nfasti: f64,
    nfagat: f64,
    njh: f64,
    njdv: f64,
    expceil_val: f64,
    csrhbot: f64,
    csrhsti: f64,
    csrhgat: f64,
    ctatbot: f64,
    ctatsti: f64,
    ctatgat: f64,
    cbbtbot: f64,
    cbbtsti: f64,
    cbbtgat: f64,
    xjunsti: f64,
    xjungat: f64,
    cjorbot: f64,
    cjorsti: f64,
    cjorgat: f64,
    vbirbot: f64,
    vbirsti: f64,
    vbirgat: f64,
    pbot: f64,
    psti: f64,
    pgat: f64,
    mefftatbot: f64,
    mefftatsti: f64,
    mefftatgat: f64,
    fbbtrbot: f64,
    fbbtrsti: f64,
    fbbtrgat: f64,
    stfbbtbot: f64,
    stfbbtsti: f64,
    stfbbtgat: f64,
    pbrbot: f64,
    pbrsti: f64,
    pbrgat: f64,
    swbv: f64,
    ndibot: f64,
    inj1: f64,
    inj2: f64,
    nqs_tau: f64,
    wi: f64,
    depnqs: f64,
    corecovery: i32,
    // Recovery pre-computed constants
    q_scale: f64,
    w_scale: f64,
    la: f64,
    vhk: f64,
    tkr_tkd_injt: f64,
    // Charge-specific
    imax: f64,
    tt: f64,
    fjunq: f64,
    // Charge: cjo at device temp (4.33)
    cjo_bot: f64,
    cjo_sti: f64,
    cjo_gat: f64,
    // Charge: forward voltage limits
    vf_min: f64,
    vch: f64,
    // Charge: Express filtering
    bot_active: bool,
    sti_active: bool,
    gat_active: bool,
    // Charge: diffusion
    tt_eff: f64,
    ndisti_m3: f64,
    ndigat_m3: f64,
};

fn cmcPrep(model: *const Model, instance: *const Instance) CmcPrep {
    // ---- Cast model parameters ----
    const trj: f64 = @as(f64, model.trj);
    const imax: f64 = @as(f64, model.imax);
    const frev: f64 = @as(f64, model.frev);
    const swbv: f64 = @as(f64, model.swbv);
    const xti: f64 = @as(f64, model.xti);
    const scale_p: f64 = @as(f64, model.scale);
    const shrink_pct: f64 = @as(f64, model.shrink);
    const expceil_val: f64 = @as(f64, model.expceil);
    const minr: f64 = @as(f64, model.minr);

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
    const nfabot: f64 = @as(f64, model.nfabot);
    const nfasti: f64 = @as(f64, model.nfasti);
    const nfagat: f64 = @as(f64, model.nfagat);

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

    const vbrbot_r: f64 = @as(f64, model.vbrbot);
    const vbrsti_r: f64 = @as(f64, model.vbrsti);
    const vbrgat_r: f64 = @as(f64, model.vbrgat);
    const pbrbot: f64 = @as(f64, model.pbrbot);
    const pbrsti: f64 = @as(f64, model.pbrsti);
    const pbrgat: f64 = @as(f64, model.pbrgat);
    const stvbrbot1: f64 = @as(f64, model.stvbrbot1);
    const stvbrbot2: f64 = @as(f64, model.stvbrbot2);
    const stvbrsti1: f64 = @as(f64, model.stvbrsti1);
    const stvbrsti2: f64 = @as(f64, model.stvbrsti2);
    const stvbrgat1: f64 = @as(f64, model.stvbrgat1);
    const stvbrgat2: f64 = @as(f64, model.stvbrgat2);

    const rsbot: f64 = @as(f64, model.rsbot);
    const rssti: f64 = @as(f64, model.rssti);
    const rsgat: f64 = @as(f64, model.rsgat);
    const rscom: f64 = @as(f64, model.rscom);
    const strs: f64 = @as(f64, model.strs);

    const njh: f64 = @as(f64, model.njh);
    const njdv: f64 = @as(f64, model.njdv);
    const ndibot: f64 = @as(f64, model.ndibot) * 1.0e6;
    const inj1: f64 = @as(f64, model.inj1);
    const inj2: f64 = @as(f64, model.inj2);
    const nqs_tau: f64 = @as(f64, model.nqs);
    const tau_val: f64 = @as(f64, model.tau);
    const wi: f64 = @as(f64, model.wi);
    const depnqs: f64 = @as(f64, model.depnqs);
    const taut: f64 = @as(f64, model.taut);
    const injt: f64 = @as(f64, model.injt);
    const corecovery: i32 = model.corecovery;
    const tt: f64 = @as(f64, model.tt);

    const dta: f64 = @as(f64, instance.dta);

    // ---- Geometry scaling ----
    const lsh = 1.0 - 0.01 * shrink_pct;
    const AB: f64 = @as(f64, instance.ab) * scale_p * scale_p * lsh * lsh;
    const LS: f64 = @as(f64, instance.ls) * scale_p * lsh;
    const LG: f64 = @as(f64, instance.lg) * scale_p * lsh;

    // ---- Temperature ----
    const t_val = computeTemps(trj, dta);

    // ---- Per-component temperature-dependent quantities ----
    const ct_bot = computeComponentTemps(t_val, xti, phigbot, vbirbot, nfabot, idsatrbot);
    const ct_sti = computeComponentTemps(t_val, xti, phigsti, vbirsti, nfasti, idsatrsti);
    const ct_gat = computeComponentTemps(t_val, xti, phiggat, vbirgat, nfagat, idsatrgat);

    // ---- Vmax (4.19-4.22) ----
    const ig_bot = ct_bot.idsat * AB;
    const ig_sti = ct_sti.idsat * LS;
    const ig_gat = ct_gat.idsat * LG;
    const vmax_bot = if (ig_bot == 0.0) VMAX_LARGE else t_val.phi_td * nfabot * @log(imax / ig_bot + 1.0);
    const vmax_sti = if (ig_sti == 0.0) VMAX_LARGE else t_val.phi_td * nfasti * @log(imax / ig_sti + 1.0);
    const vmax_gat = if (ig_gat == 0.0) VMAX_LARGE else t_val.phi_td * nfagat * @log(imax / ig_gat + 1.0);
    const vmax = @min(vmax_bot, @min(vmax_sti, vmax_gat));

    // ---- Forward voltage limits (4.29-4.31) ----
    const vbi_min_raw = @min(
        if (AB > 0.0) ct_bot.vbi else 1.0e30,
        @min(if (LS > 0.0) ct_sti.vbi else 1.0e30, if (LG > 0.0) ct_gat.vbi else 1.0e30),
    );
    const vbi_min = if (vbi_min_raw > 1.0e29) ct_bot.vbi else vbi_min_raw;

    // ---- Alpha_av (4.32) ----
    const alpha_av = (frev - 1.0) / frev;

    // ---- Breakdown voltage temp scaling ----
    const vbr_bot = vbrbot_r * (1.0 + t_val.dt * (stvbrbot1 + t_val.dt * stvbrbot2));
    const vbr_sti = vbrsti_r * (1.0 + t_val.dt * (stvbrsti1 + t_val.dt * stvbrsti2));
    const vbr_gat = vbrgat_r * (1.0 + t_val.dt * (stvbrgat1 + t_val.dt * stvbrgat2));

    // ---- Series resistance ----
    const rs_scale = expc(strs * t_val.ln_ratio);
    const g_bot_r = if (rsbot > 0.0 and AB > 0.0) AB / (rsbot * rs_scale) else 0.0;
    const g_sti_r = if (rssti > 0.0 and LS > 0.0) LS / (rssti * rs_scale) else 0.0;
    const g_gat_r = if (rsgat > 0.0 and LG > 0.0) LG / (rsgat * rs_scale) else 0.0;
    const g_sum = g_bot_r + g_sti_r + g_gat_r;
    const r_total = if (g_sum > 0.0) 1.0 / g_sum + rscom else rscom;
    const g_rs = if (r_total > 0.0 and r_total >= minr) 1.0 / r_total else GSHORT;

    // ---- High-injection V_HA (eq 7-9) ----
    const n_in = NI0 * ct_bot.ftd2;
    const pn0_bot = n_in * n_in / @max(ndibot, 1.0e-30);
    const vha_bot = computeVHA(t_val.phi_td, nfabot, ndibot, ct_bot.ftd2);
    const ndisti_m3 = @as(f64, model.ndisti) * 1.0e6;
    const ndigat_m3 = @as(f64, model.ndigat) * 1.0e6;
    const vha_sti = computeVHA(t_val.phi_td, nfasti, ndisti_m3, ct_sti.ftd2);
    const vha_gat = computeVHA(t_val.phi_td, nfagat, ndigat_m3, ct_gat.ftd2);

    // ---- Express model ----
    const swjunexp: f64 = @as(f64, model.swjunexp);
    const use_express = swjunexp > 0.5;
    const vjunref: f64 = @as(f64, model.vjunref);
    const ep = computeExpressParams(t_val.phi_td, t_val.phi_tr, vjunref, AB, LS, LG, vmax, nfabot, nfasti, nfagat, njh, njdv, ct_bot, ct_sti, ct_gat, vha_bot, vha_sti, vha_gat, csrhbot, csrhsti, csrhgat, ctatbot, ctatsti, ctatgat, cbbtbot, cbbtsti, cbbtgat, xjunsti, xjungat, cjorbot, cjorsti, cjorgat, vbirbot, vbirsti, vbirgat, pbot, psti, pgat, mefftatbot, mefftatsti, mefftatgat, fbbtrbot, fbbtrsti, fbbtrgat, stfbbtbot, stfbbtsti, stfbbtgat, vbr_bot, vbr_sti, vbr_gat, pbrbot, pbrsti, pbrgat, alpha_av, swbv, t_val.dt, vbi_min, expceil_val);

    // ---- Recovery pre-computation (f64) ----
    var q_scale: f64 = 0.0;
    var w_scale: f64 = 0.0;
    var la: f64 = 0.0;
    var vhk: f64 = 0.0;
    var tkr_tkd_injt: f64 = 0.0;

    if (corecovery != 0) {
        const qpex0 = @max(QQ * AB, 1.0e-30);
        const wdep0 = @min(@sqrt(@max(2.0 * EPS_SI / (QQ * @max(ndibot, 1.0e-30)), 0.0)), wi);
        q_scale = 1.0e-23 / qpex0;
        w_scale = 1.0 / @max(wdep0, 1.0e-30);

        const t1ph = expc(-1.5 * t_val.ln_ratio);
        const dn = t_val.phi_td * MU_N0 * t1ph;
        const dp = t_val.phi_td * MU_P0 * t1ph;
        const da = 2.0 * dn * dp / @max(dn + dp, 1.0e-30);
        const tau_hl = tau_val * expc(taut * t_val.ln_ratio);
        la = @sqrt(@max(tau_hl * da, 1.0e-30));
        vhk = t_val.phi_td * nfabot * (@log(@max(ndibot / @max(pn0_bot, 1.0e-30), 1.0)) + wi / la);
        tkr_tkd_injt = expc(-injt * t_val.ln_ratio);
    }

    // ---- Charge: cjo at device temp (4.33) ----
    const cjo_bot = cjorbot * expc(pbot * @log(@max(vbirbot / @max(ct_bot.vbi, 1.0e-30), 1.0e-30)));
    const cjo_sti = cjorsti * expc(psti * @log(@max(vbirsti / @max(ct_sti.vbi, 1.0e-30), 1.0e-30)));
    const cjo_gat = cjorgat * expc(pgat * @log(@max(vbirgat / @max(ct_gat.vbi, 1.0e-30), 1.0e-30)));

    // ---- Charge: forward voltage limits ----
    const p_max = if (@abs(vbi_min - ct_bot.vbi) < 1.0e-20) pbot else if (@abs(vbi_min - ct_sti.vbi) < 1.0e-20) psti else pgat;
    const vf_min = vbi_min * (1.0 - expc(-@log(CAP_A) / p_max));
    const vch = EPS_CH * vbi_min;

    // ---- Charge: Express filtering ----
    const fjunq: f64 = @as(f64, model.fjunq);
    const z_bot_cap = AB * cjo_bot;
    const z_sti_cap = LS * cjo_sti;
    const z_gat_cap = LG * cjo_gat;
    const z_tot = z_bot_cap + z_sti_cap + z_gat_cap;
    const z_thresh = fjunq * z_tot;
    const bot_active = if (use_express) (z_bot_cap > z_thresh) else true;
    const sti_active = if (use_express) (z_sti_cap > z_thresh) else true;
    const gat_active = if (use_express) (z_gat_cap > z_thresh) else true;

    // ---- Charge: diffusion ----
    const tt_eff = if (corecovery != 0) 0.0 else tt;

    return .{
        .AB = AB,
        .LS = LS,
        .LG = LG,
        .t = t_val,
        .ct_bot = ct_bot,
        .ct_sti = ct_sti,
        .ct_gat = ct_gat,
        .vmax = vmax,
        .vbi_min = vbi_min,
        .alpha_av = alpha_av,
        .vbr_bot = vbr_bot,
        .vbr_sti = vbr_sti,
        .vbr_gat = vbr_gat,
        .g_rs = g_rs,
        .vha_bot = vha_bot,
        .vha_sti = vha_sti,
        .vha_gat = vha_gat,
        .pn0_bot = pn0_bot,
        .ep = ep,
        .use_express = use_express,
        .nfabot = nfabot,
        .nfasti = nfasti,
        .nfagat = nfagat,
        .njh = njh,
        .njdv = njdv,
        .expceil_val = expceil_val,
        .csrhbot = csrhbot,
        .csrhsti = csrhsti,
        .csrhgat = csrhgat,
        .ctatbot = ctatbot,
        .ctatsti = ctatsti,
        .ctatgat = ctatgat,
        .cbbtbot = cbbtbot,
        .cbbtsti = cbbtsti,
        .cbbtgat = cbbtgat,
        .xjunsti = xjunsti,
        .xjungat = xjungat,
        .cjorbot = cjorbot,
        .cjorsti = cjorsti,
        .cjorgat = cjorgat,
        .vbirbot = vbirbot,
        .vbirsti = vbirsti,
        .vbirgat = vbirgat,
        .pbot = pbot,
        .psti = psti,
        .pgat = pgat,
        .mefftatbot = mefftatbot,
        .mefftatsti = mefftatsti,
        .mefftatgat = mefftatgat,
        .fbbtrbot = fbbtrbot,
        .fbbtrsti = fbbtrsti,
        .fbbtrgat = fbbtrgat,
        .stfbbtbot = stfbbtbot,
        .stfbbtsti = stfbbtsti,
        .stfbbtgat = stfbbtgat,
        .pbrbot = pbrbot,
        .pbrsti = pbrsti,
        .pbrgat = pbrgat,
        .swbv = swbv,
        .ndibot = ndibot,
        .inj1 = inj1,
        .inj2 = inj2,
        .nqs_tau = nqs_tau,
        .wi = wi,
        .depnqs = depnqs,
        .corecovery = corecovery,
        .q_scale = q_scale,
        .w_scale = w_scale,
        .la = la,
        .vhk = vhk,
        .tkr_tkd_injt = tkr_tkd_injt,
        .imax = imax,
        .tt = tt,
        .fjunq = fjunq,
        .cjo_bot = cjo_bot,
        .cjo_sti = cjo_sti,
        .cjo_gat = cjo_gat,
        .vf_min = vf_min,
        .vch = vch,
        .bot_active = bot_active,
        .sti_active = sti_active,
        .gat_active = gat_active,
        .tt_eff = tt_eff,
        .ndisti_m3 = ndisti_m3,
        .ndigat_m3 = ndigat_m3,
    };
}

// ============================================================================
// PrepCache
// ============================================================================

pub const PrepCache = CmcPrep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return cmcPrep(model, instance);
}

// ============================================================================
// Current contribution function  (eval)
// ============================================================================
pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const A = @intFromEnum(U.a);
    const K = @intFromEnum(U.k);
    const AIK = @intFromEnum(U.aik);
    const CHA = @intFromEnum(U.charge_a);
    const CHK = @intFromEnum(U.charge_k);
    const DPA = @intFromEnum(U.depl_a);

    const p = pc;

    // ---- Terminal voltages (x-dependent: S) ----
    const v_a = x[A];
    const v_k = x[K];
    const v_aik = x[AIK];
    const v_ak = v_a.sub(v_aik);
    const v_rs = v_aik.sub(v_k);

    // ---- SRH/TAT/BBT shared pre-computation (x-dependent: S) ----
    // half_arg = min(v_ak/(2*phi_td), 40)
    const half_arg = v_ak.scale(1.0 / (2.0 * p.t.phi_td)).minC(40.0);
    const z_inv = half_arg.exp();

    // psi_star (4.40)
    const z = half_arg.neg().exp();
    // psi_pos = phi_td*log(max(z + 2 + sqrt(max((z+1)*(z+3),1e-30)), 1e-30))
    const psi_pos = z.addC(1.0).mul(z.addC(3.0)).maxC(1.0e-30).sqrt().add(z).addC(2.0).maxC(1.0e-30).log().scale(p.t.phi_td);
    // psi_neg = -v_ak + phi_td*log(max(1 + 2*z_inv + sqrt(max((1+z_inv)*(1+3*z_inv),1e-30)), 1e-30))
    const psi_neg = z_inv.addC(1.0).mul(z_inv.scale(3.0).addC(1.0)).maxC(1.0e-30).sqrt().add(z_inv.scale(2.0)).addC(1.0).maxC(1.0e-30).log().scale(p.t.phi_td).sub(v_ak);
    const psi_star = if (v_ak.val() > 0.0) psi_pos else psi_neg;

    // vj_lim = vbi_min - 2*psi_star  (S because psi_star is S)
    const vj_lim = psi_star.scale(-2.0).addC(p.vbi_min);
    // vj_srh = hyp2(v_ak, vj_lim, phi_td) with vj_lim as S:
    //   x - hyp1(x - x0, eps); here x0 is S -> compute directly.
    const vj_srh = v_ak.sub(hyp1S(S, v_ak.sub(vj_lim), p.t.phi_td));
    const vbbt_lim = @min(p.vbirbot, @min(p.vbirsti, p.vbirgat)) - DELTA_VBI;
    const v_bbt = hyp2S(S, v_ak, vbbt_lim, p.t.phi_tr);
    const v_av = hyp2S(S, v_ak, 0.0, EPS_AV);

    // ---- Per-component current (full model or Express) ----

    // Full model path
    const i_bot_full = componentCurrent(S, v_ak, p.vmax, p.t.phi_td, p.nfabot, p.njh, p.njdv, p.ct_bot.idsat, p.vha_bot, p.csrhbot, p.ctatbot, p.cbbtbot, 1.0, p.cjorbot, p.ct_bot.vbi, p.vbirbot, p.pbot, p.ct_bot.ftd, p.ct_bot.phi_gd, p.mefftatbot, p.fbbtrbot, p.stfbbtbot, p.vbr_bot, p.pbrbot, z_inv, psi_star, vj_srh, v_bbt, v_av, p.alpha_av, p.swbv, p.t.dt, p.t.phi_tr, p.expceil_val);
    const i_sti_full = componentCurrent(S, v_ak, p.vmax, p.t.phi_td, p.nfasti, p.njh, p.njdv, p.ct_sti.idsat, p.vha_sti, p.csrhsti, p.ctatsti, p.cbbtsti, p.xjunsti, p.cjorsti, p.ct_sti.vbi, p.vbirsti, p.psti, p.ct_sti.ftd, p.ct_sti.phi_gd, p.mefftatsti, p.fbbtrsti, p.stfbbtsti, p.vbr_sti, p.pbrsti, z_inv, psi_star, vj_srh, v_bbt, v_av, p.alpha_av, p.swbv, p.t.dt, p.t.phi_tr, p.expceil_val);
    const i_gat_full = componentCurrent(S, v_ak, p.vmax, p.t.phi_td, p.nfagat, p.njh, p.njdv, p.ct_gat.idsat, p.vha_gat, p.csrhgat, p.ctatgat, p.cbbtgat, p.xjungat, p.cjorgat, p.ct_gat.vbi, p.vbirgat, p.pgat, p.ct_gat.ftd, p.ct_gat.phi_gd, p.mefftatgat, p.fbbtrgat, p.stfbbtgat, p.vbr_gat, p.pbrgat, z_inv, psi_star, vj_srh, v_bbt, v_av, p.alpha_av, p.swbv, p.t.dt, p.t.phi_tr, p.expceil_val);
    const i_jun_full = i_bot_full.scale(p.AB).add(i_sti_full.scale(p.LS)).add(i_gat_full.scale(p.LG));

    // Express model path (eqs 4.113-4.116)
    const i_for1 = gExpFitS(S, v_ak, p.ep.i_satfor1, p.ep.m_for1, p.t.phi_td);
    const i_for2 = gExpFitS(S, v_ak, p.ep.i_satfor2, p.ep.m_for2, p.t.phi_td);
    const i_rev = gExpFitS(S, v_ak.neg(), p.ep.i_satrev, p.ep.m_rev, p.t.phi_td).neg();
    const i_jun_express = i_for1.add(i_for2).add(i_rev);

    // ---- Total junction current (4.82 / 4.116) ----
    const i_jun = (if (p.use_express) i_jun_express else i_jun_full).add(v_ak.scale(GMIN));
    const i_rs_val = v_rs.scale(p.g_rs);

    // ---- NQS recovery currents ----
    var i_cha: S = S.con(0.0);
    var i_chk: S = S.con(0.0);
    var i_dpa: S = S.con(0.0);

    if (p.corecovery != 0) {
        const qc_scale: f64 = 1.0e-12;
        const wc_scale: f64 = 1.0e-13;

        // exp_A (recompute M_ID_bot)  -- S
        const nj_a = clampNjS(S, v_ak.addC(-p.vha_bot).scale(p.njdv).addC(p.nfabot), p.nfabot, p.njh);
        const exp_a_arg = v_ak.div(nj_a).add(nj_a.addC(-p.nfabot).scale(p.vha_bot / @max(p.nfabot * p.njh, 1.0e-30))).scale(1.0 / p.t.phi_td);
        const exp_a = expcS(S, exp_a_arg.minC(@log(@max(p.expceil_val, 1.0))));

        // exp_K (23)  -- S
        const nj_k = clampNjS(S, v_ak.addC(-p.vhk).scale(p.njdv).addC(p.nfabot), p.nfabot, p.njh);
        // exp_k_arg = (v_ak/nj_k - (vhk-vha_bot)/nj_k + vhk*(nj_k-nfabot)/nfa_njh) / phi_td
        const exp_k_arg = v_ak.div(nj_k)
            .sub(nj_k.pow(-1.0).scale(p.vhk - p.vha_bot))
            .add(nj_k.addC(-p.nfabot).scale(p.vhk / @max(p.nfabot * p.njh, 1.0e-30)))
            .scale(1.0 / p.t.phi_td);
        const exp_k = expcS(S, exp_k_arg.minC(@log(@max(p.expceil_val, 1.0))));

        // Injected carrier densities (20-21)  -- S
        const dvha = v_ak.addC(-p.vha_bot);
        // inj2_a = if (inj2>0 and v_ak>vha_bot) exp(min(-inj2*dvha^2*tkr_tkd_injt, 80)) else 1
        const inj2_a = if (p.inj2 > 0.0 and v_ak.val() > p.vha_bot)
            expcS(S, dvha.mul(dvha).scale(-p.inj2 * p.tkr_tkd_injt).minC(80.0))
        else
            S.con(1.0);
        // qpex_a = QQ*AB*(pn0*min(exp_a*inj1*inj2_a, expceil) - pn0)
        const qpex_a = exp_a.scale(p.inj1).mul(inj2_a).minC(p.expceil_val).scale(p.pn0_bot).addC(-p.pn0_bot).scale(QQ * p.AB);

        const dvhk = v_ak.addC(-p.vhk);
        const inj2_k = if (p.inj2 > 0.0 and v_ak.val() > p.vhk)
            expcS(S, dvhk.mul(dvhk).scale(-p.inj2 * p.tkr_tkd_injt).minC(80.0))
        else
            S.con(1.0);
        const qpex_k = exp_k.scale(p.inj1).mul(inj2_k).minC(p.expceil_val).scale(p.pn0_bot).addC(-p.pn0_bot).scale(QQ * p.AB);

        // Depletion width (31)  -- S
        // wdep_raw = sqrt(max(2*EPS_SI*max(vbi - v_ak, 0)/(QQ*max(ndibot,1e-30)), 0))
        const wdep_raw = v_ak.neg().addC(p.ct_bot.vbi).maxC(0.0).scale(2.0 * EPS_SI / (QQ * @max(p.ndibot, 1.0e-30))).maxC(0.0).sqrt();
        const wdep = smoothUpperS(S, wdep_raw, p.wi, 1.0e-7);

        // Scaled target values for NQS nodes
        const qpex_a_sc = qpex_a.scale(p.q_scale);
        const qpex_k_sc = qpex_k.scale(p.q_scale);
        const wdep_sc = wdep.scale(p.w_scale);

        // NQS resistive currents (35, 39, 43)
        if (p.nqs_tau > 0.0) {
            i_cha = x[CHA].sub(qpex_a_sc).scale(1.0 / (p.nqs_tau * qc_scale));
            i_chk = x[CHK].sub(qpex_k_sc).scale(1.0 / (p.nqs_tau * qc_scale));
        }
        if (p.depnqs > 0.0) {
            i_dpa = x[DPA].sub(wdep_sc).scale(1.0 / (p.depnqs * wc_scale));
        }
    }

    // ---- KCL outputs ----
    return .{
        i_jun, // a
        i_rs_val.neg(), // k
        i_jun.neg().add(i_rs_val), // aik
        i_cha, // charge_a
        i_chk, // charge_k
        i_dpa, // depl_a
    };
}

// ============================================================================
// Charge function  (q)
// ============================================================================
pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const A = @intFromEnum(U.a);
    const AIK = @intFromEnum(U.aik);
    const CHA = @intFromEnum(U.charge_a);
    const CHK = @intFromEnum(U.charge_k);
    const DPA = @intFromEnum(U.depl_a);

    const p = pc;

    // ---- Terminal voltages (x-dependent: S) ----
    const v_ak = x[A].sub(x[AIK]);

    // ---- Junction voltage for charge (4.34)  (x-dependent: S) ----
    const vj = hyp5S(S, v_ak, p.vf_min, p.vch);

    // ---- Junction charge per component (4.35 / 4.118-4.120) ----
    const q_bot = if (p.bot_active) componentCharge(S, vj, v_ak, p.cjo_bot, p.ct_bot.vbi, p.pbot) else S.con(0.0);
    const q_sti = if (p.sti_active) componentCharge(S, vj, v_ak, p.cjo_sti, p.ct_sti.vbi, p.psti) else S.con(0.0);
    const q_gat = if (p.gat_active) componentCharge(S, vj, v_ak, p.cjo_gat, p.ct_gat.vbi, p.pgat) else S.con(0.0);
    var q_juncap = q_bot.scale(p.AB).add(q_sti.scale(p.LS)).add(q_gat.scale(p.LG));

    // ---- Diffusion charge (transit time, when corecovery=0) ----
    if (p.tt_eff > 0.0) {
        // vmax is already computed in prep and shared with eval
        const id_bot = componentIdealCurrent(S, v_ak, p.vmax, p.t.phi_td, p.nfabot, p.njh, p.njdv, p.ct_bot.idsat, p.vha_bot, p.expceil_val);
        const id_sti = componentIdealCurrent(S, v_ak, p.vmax, p.t.phi_td, p.nfasti, p.njh, p.njdv, p.ct_sti.idsat, p.vha_sti, p.expceil_val);
        const id_gat = componentIdealCurrent(S, v_ak, p.vmax, p.t.phi_td, p.nfagat, p.njh, p.njdv, p.ct_gat.idsat, p.vha_gat, p.expceil_val);

        // q_juncap += tt_eff*(AB*id_bot + LS*id_sti + LG*id_gat)
        q_juncap = q_juncap.add(id_bot.scale(p.AB).add(id_sti.scale(p.LS)).add(id_gat.scale(p.LG)).scale(p.tt_eff));
    }

    // ---- Recovery charge (when corecovery=1) ----
    var q_rr: S = S.con(0.0);
    var q_nqs_a: S = S.con(0.0);
    var q_nqs_k: S = S.con(0.0);
    var q_nqs_d: S = S.con(0.0);

    if (p.corecovery != 0) {
        // NQS values: quasi-static fallback when NQS tau = 0
        const qpex_a_nqs = if (p.nqs_tau > 0.0) x[CHA].scale(1.0 / p.q_scale) else blk: {
            const nj_a = clampNjS(S, v_ak.addC(-p.vha_bot).scale(p.njdv).addC(p.nfabot), p.nfabot, p.njh);
            const ea_arg = v_ak.div(nj_a).add(nj_a.addC(-p.nfabot).scale(p.vha_bot / @max(p.nfabot * p.njh, 1.0e-30))).scale(1.0 / p.t.phi_td);
            const ea = expcS(S, ea_arg.minC(@log(@max(p.expceil_val, 1.0))));
            // QQ*AB*(pn0*min(ea, expceil) - pn0)
            break :blk ea.minC(p.expceil_val).scale(p.pn0_bot).addC(-p.pn0_bot).scale(QQ * p.AB);
        };
        const qpex_k_nqs = if (p.nqs_tau > 0.0) x[CHK].scale(1.0 / p.q_scale) else S.con(0.0);

        const wdep_a_nqs = if (p.depnqs > 0.0) x[DPA].scale(1.0 / p.w_scale) else blk: {
            const wr = v_ak.neg().addC(p.ct_bot.vbi).maxC(0.0).scale(2.0 * EPS_SI / (QQ * @max(p.ndibot, 1.0e-30))).maxC(0.0).sqrt();
            break :blk smoothUpperS(S, wr, p.wi, 1.0e-7);
        };

        // Recovery charge components (17-19, 16)
        const q_n0 = -p.AB * QQ * p.ndibot * p.wi; // f64
        // q_nex_a = -la*qpex_a*(exp(min(-wdep_a/la,80)) - exp(min(-wi/la,80)))
        const exp_wi = expc(@min(-p.wi / p.la, 80.0)); // f64
        const q_nex_a = qpex_a_nqs.mul(expcS(S, wdep_a_nqs.scale(-1.0 / p.la).minC(80.0)).addC(-exp_wi)).scale(-p.la);
        // q_nex_k = -la*qpex_k*(exp(min(-(wi - wdep_a)/la, 80)) - 1)
        const q_nex_k = qpex_k_nqs.mul(expcS(S, wdep_a_nqs.addC(-p.wi).scale(1.0 / p.la).minC(80.0)).addC(-1.0)).scale(-p.la);
        // q_rr = -(q_n0 + q_nex_a + q_nex_k)
        q_rr = q_nex_a.add(q_nex_k).addC(q_n0).neg();

        // NQS charge (d/dt terms): charge on NQS node = node_voltage
        if (p.nqs_tau > 0.0) {
            q_nqs_a = x[CHA];
            q_nqs_k = x[CHK];
        }
        if (p.depnqs > 0.0) {
            q_nqs_d = x[DPA];
        }
    }

    // ---- Total charge (eq 15) ----
    const q_total = q_juncap.add(q_rr);

    // ---- Write outputs ----
    return .{
        q_total, // a
        S.con(0.0), // k
        q_total.neg(), // aik
        q_nqs_a, // charge_a
        q_nqs_k, // charge_k
        q_nqs_d, // depl_a
    };
}

// ============================================================================
// Voltage limiting  (DEVpnjlim on junction a-aik)
// ============================================================================
pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const trj: f64 = @as(f64, model.trj);
    const dta: f64 = @as(f64, instance.dta);
    const nfabot: f64 = @as(f64, model.nfabot);
    const idsatrbot: f64 = @as(f64, model.idsatrbot);

    const tkd = T0 + @max(trj + dta, TMIN);
    const phi_td = KB * tkd / QQ;
    const vt = phi_td * nfabot;
    const v_crit = vt * @log(vt / (1.4142135623730951 * @max(idsatrbot, 1.0e-30)));

    const ai = @intFromEnum(U.a);
    const aiki = @intFromEnum(U.aik);

    const v_new = x_new[ai] - x_new[aiki];
    const v_old = x_old[ai] - x_old[aiki];

    var v_lim = v_new;

    if (v_new > v_crit) {
        if (v_old > 0.0) {
            const dv = v_new - v_old;
            if (dv > 0.0) {
                const arg = @min(dv / vt, 80.0);
                v_lim = v_old + vt * @log(@max(1.0 + arg, 1.0e-30));
            }
        } else {
            v_lim = v_crit;
        }
    }

    if (v_new < -5.0 * vt) {
        const step = v_new - v_old;
        if (step < -5.0 * vt) {
            v_lim = v_old - 5.0 * vt;
        }
    }

    var result = x_new;
    result[ai] = x_new[ai] + (v_lim - v_new);
    return result;
}

// ============================================================================
// Parameter stepping  (convergence aid)
// ============================================================================
pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const s: f32 = @floatCast(lambda + (1.0 - lambda) * 1.0e-6);
    m.idsatrbot = model.idsatrbot * s;
    m.idsatrsti = model.idsatrsti * s;
    m.idsatrgat = model.idsatrgat * s;
    m.csrhbot = model.csrhbot * s;
    m.csrhsti = model.csrhsti * s;
    m.csrhgat = model.csrhgat * s;
    m.ctatbot = model.ctatbot * s;
    m.ctatsti = model.ctatsti * s;
    m.ctatgat = model.ctatgat * s;
    m.cbbtbot = model.cbbtbot * s;
    m.cbbtsti = model.cbbtsti * s;
    m.cbbtgat = model.cbbtgat * s;
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

test "diode_cmc: reverse bias (V_AK = 0) -> junction current ~ 0" {
    // At v_ak = 0 the ideal current (m_id - 1)*idsat is exactly 0 for every
    // component (exp(0)=1), SRH/TAT/BBT all vanish, and only GMIN*v_ak = 0
    // remains. So out[a] must be ~0 with the default model.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-15);
    // KCL consistency: a + k + aik currents sum to 0 (only external branch).
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0] + out[1] + out[2], 1e-15);
}

test "diode_cmc: forward-bias ideal current dominates" {
    // Suppress SRH/TAT/BBT/breakdown so only the ideal diode term is exercised,
    // giving a hand-checkable expectation.
    //   idsatrbot = 1e-9, nfabot = 1, AB = 1e-6, njdv = 0 (constant emission).
    //   phi_td = KB*(273.15+21)/QQ.  vha_bot: with default ndibot=1e22 m^-3 and
    //   ftd2 at trj (dt=0) => ftd2=1 => n_in=NI0=1.45e16, pn0=NI0^2/1e22 ~ 2.1e10,
    //   ratio ndibot/pn0 ~ 4.76e11, log ~ 26.9 => vha_bot ~ phi_td*26.9 ~ 0.68 V.
    //   With v_ak below vha_bot and njdv=0, nj=nfabot=1, exp_arg=v_ak/phi_td.
    //   i_d_bot = (exp(v_ak/phi_td) - 1) * idsatrbot.  i_jun = AB*i_d_bot + GMIN*v_ak.
    // We just assert forward current is positive and >> reverse-leakage.
    const model: Model = .{
        .csrhbot = 0.0, .csrhsti = 0.0, .csrhgat = 0.0,
        .ctatbot = 0.0, .ctatsti = 0.0, .ctatgat = 0.0,
        .cbbtbot = 0.0, .cbbtsti = 0.0, .cbbtgat = 0.0,
        .swbv = 0.0,
        .idsatrbot = 1.0e-9, .idsatrsti = 0.0, .idsatrgat = 0.0,
        .njdv = 0.0,
        .rsbot = 0.0, .rssti = 0.0, .rsgat = 0.0, .rscom = 0.0,
    };
    const inst: Instance = .{ .ab = 1.0e-6, .ls = 0.0, .lg = 0.0 };
    const out_fwd = contract.evalValues(Self, .{ 0.5, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    const out_rev = contract.evalValues(Self, .{ -0.5, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    // forward current out[a] strongly positive
    try testing.expect(out_fwd[0] > 1e-9);
    // magnitude(forward) >> magnitude(reverse)
    try testing.expect(out_fwd[0] > @abs(out_rev[0]) * 100.0);
}

test "diode_cmc: junction charge is negative under reverse bias, monotone" {
    // Depletion charge q_dep(vj) = cjo*vbi/(1-p)*(1 - (1 - vj/vbi)^(1-p))
    // is <= 0 for vj < 0, and more negative as reverse bias increases.
    const model: Model = .{ .tt = 0.0, .corecovery = 0 };
    const inst: Instance = .{};
    const q0 = contract.qValues(Self, .{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    const qr = contract.qValues(Self, .{ -1.0, 0.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    // charge conservation between a and aik ports
    try testing.expectApproxEqAbs(q0[0], -q0[2], 1e-30);
    try testing.expectApproxEqAbs(qr[0], -qr[2], 1e-30);
    // reverse-biased charge more negative than at zero bias
    try testing.expect(qr[0] < q0[0]);
}
