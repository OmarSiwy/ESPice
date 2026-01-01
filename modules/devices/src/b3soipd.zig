const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM3SOI-PD v2.0 — Berkeley SOI Partially-Depleted MOSFET (4-terminal)
// ============================================================================
// Topology:
//   External: D, G, S, E (drain, gate, source, substrate/backgate)
//   Internal: DP (drain-prime after RD), SP (source-prime after RS),
//             B (floating body), TEMP (self-heating), P (body contact)
//
//   D -- RD -- DP (channel drain)
//   S -- RS -- SP (channel source)
//   B -- Rbody -- P (body contact)
//   TEMP node for self-heating (Rth, Cth)
//   E (backgate/substrate)
//   Channel DP <-> SP controlled by G, B, E
//   SOI body currents: BJT, diffusion, recombination, tunneling, GIDL, II
// ============================================================================

pub const U = enum(u8) { drain, gate, source, substrate, drain_prime, source_prime, body, temp, body_contact };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device Type & Model Selectors ---
    type_: i32 = 1,
    capmod: i32 = 2,
    mobmod: i32 = 1,
    noimod: i32 = 1,
    paramchk: i32 = 0,
    binunit: i32 = 1,
    shmod: i32 = 0,
    ddmod: i32 = 0,
    igmod: i32 = 0,
    version: f32 = 2.0,

    // --- Geometry & Process ---
    tox: f32 = 1.0e-8,
    toxe: f32 = 0, // B4SOI-style alias; >0 overrides tox (level 58 cards)
    dtoxcv: f32 = 0.0,
    tbox: f32 = 3.0e-7,
    tsi: f32 = 1.0e-7,
    xj: f32 = @bitCast(@as(u32, 0x7FC00000)), // NaN = use Leff
    nsub: f32 = 6.0e16,
    nch: f32 = 1.7e17,
    ngate: f32 = 0.0,
    xt: f32 = 1.55e-7,
    tnom: f32 = 27.0, // deg C (ngspice card semantics)
    toxqm: f32 = 1.0e-8,
    toxref: f32 = 2.5e-9,

    // --- Threshold Voltage ---
    vth0: f32 = 0.7,
    k1: f32 = 0.0,
    k1w1: f32 = 0.0,
    k1w2: f32 = 0.0,
    k2: f32 = 0.0,
    k3: f32 = 0.0,
    k3b: f32 = 0.0,
    gamma1: f32 = 0.0,
    gamma2: f32 = 0.0,
    vbx: f32 = 0.0,
    vbm: f32 = -3.0,
    delvt: f32 = 0.0,
    voff: f32 = -0.08,
    nfactor: f32 = 1.0,
    cit: f32 = 0.0,
    cdsc: f32 = 2.4e-4,
    cdscb: f32 = 0.0,
    cdscd: f32 = 0.0,
    ketas: f32 = 0.0,

    // --- Short-Channel & Narrow-Width Effects ---
    dvt0: f32 = 2.2,
    dvt1: f32 = 0.53,
    dvt2: f32 = -0.032,
    dvt0w: f32 = 0.0,
    dvt1w: f32 = 5.3e6,
    dvt2w: f32 = -0.032,
    nlx: f32 = 1.74e-7,
    w0: f32 = 2.5e-6,
    eta0: f32 = 0.08,
    etab: f32 = -0.07,
    dsub: f32 = 0.56,
    drout: f32 = 0.56,
    pdiblc1: f32 = 0.39,
    pdiblc2: f32 = 0.0086,
    pdiblcb: f32 = 0.0,
    pclm: f32 = 1.3,
    pvag: f32 = 0.0,

    // --- Mobility ---
    u0: f32 = 0.067,
    ua: f32 = 2.25e-9,
    ub: f32 = 5.87e-19,
    uc: f32 = -4.65e-11,
    vsat: f32 = 80000.0,
    at: f32 = 33000.0,
    a0: f32 = 1.0,
    ags: f32 = 0.0,
    a1: f32 = 0.0,
    a2: f32 = 1.0,
    b0: f32 = 0.0,
    b1: f32 = 0.0,
    keta: f32 = -0.6,
    delta: f32 = 0.01,

    // --- Temperature Coefficients ---
    kt1: f32 = -0.11,
    kt1l: f32 = 0.0,
    kt2: f32 = 0.022,
    ute: f32 = -1.5,
    ua1: f32 = 4.31e-9,
    ub1: f32 = -7.61e-18,
    uc1: f32 = -5.6e-11,
    prt: f32 = 0.0,
    tii: f32 = 0.0,

    // --- Parasitic Resistance ---
    rsh: f32 = 0.0,
    rdsw: f32 = 100.0,
    prwg: f32 = 0.0,
    prwb: f32 = 0.0,
    wr: f32 = 1.0,
    rbody: f32 = 0.0,
    rbsh: f32 = 0.0,

    // --- Self-Heating ---
    rth0: f32 = 0.0,
    cth0: f32 = 0.0,
    wth0: f32 = 0.0,

    // --- SOI Body Currents -- BJT ---
    isbjt: f32 = 1.0e-6,
    nbjt: f32 = 1.0,
    lbjt0: f32 = 2.0e-7,
    ln: f32 = 2.0e-6,
    vabjt: f32 = 10.0,
    aely: f32 = 0.0,
    ahli: f32 = 0.0,
    xbjt: f32 = 1.0,
    fbjtii: f32 = 0.0,

    // --- SOI Body Currents -- Diffusion ---
    isdif: f32 = 0.0,
    ndiode: f32 = 1.0,
    xdif: f32 = 1.0,
    ldif0: f32 = 1.0,
    ndif: f32 = -1.0,
    tt: f32 = 1.0e-12,

    // --- SOI Body Currents -- Recombination ---
    isrec: f32 = 1.0e-5,
    nrecf0: f32 = 2.0,
    nrecr0: f32 = 10.0,
    vrec0: f32 = 0.0,
    xrec: f32 = 1.0,
    ntrecf: f32 = 0.0,
    ntrecr: f32 = 0.0,

    // --- SOI Body Currents -- Tunneling ---
    istun: f32 = 0.0,
    ntun: f32 = 10.0,
    vtun0: f32 = 0.0,
    xtun: f32 = 0.0,

    // --- GIDL ---
    agidl: f32 = 0.0,
    bgidl: f32 = 0.0,
    ngidl: f32 = 1.2,

    // --- Impact Ionization ---
    alpha0: f32 = 0.0,
    beta0: f32 = 0.0,
    beta1: f32 = 0.0,
    beta2: f32 = 0.1,
    vdsatii0: f32 = 0.9,
    lii: f32 = 0.0,
    sii0: f32 = 0.5,
    sii1: f32 = 0.1,
    sii2: f32 = 0.0,
    siid: f32 = 0.0,
    esatii: f32 = 1.0e7,

    // --- Gate Current ---
    ntox: f32 = 1.0,
    ebg: f32 = 1.2,
    vevb: f32 = 0.075,
    alphagb1: f32 = 0.35,
    betagb1: f32 = 0.03,
    vgb1: f32 = 300.0,
    vecb: f32 = 0.026,
    alphagb2: f32 = 0.43,
    betagb2: f32 = 0.05,
    vgb2: f32 = 17.0,
    voxh: f32 = 5.0,
    deltavox: f32 = 0.005,
    rhalo: f32 = 1.0e15,

    // --- Overlap & Fringe Capacitances ---
    cgso: f32 = 2.07188e-10,
    cgdo: f32 = 2.07188e-10,
    cgeo: f32 = 0.0,
    cgsl: f32 = 0.0,
    cgdl: f32 = 0.0,
    ckappa: f32 = 0.6,
    cf: f32 = 8.16367e-11,
    clc: f32 = 1.0e-8,
    cle: f32 = 0.0,
    xpart: f32 = 0.0,

    // --- Junction Capacitances ---
    cjswg: f32 = 1.0e-10,
    pbswg: f32 = 0.7,
    mjswg: f32 = 0.5,
    tcjswg: f32 = 0.0,
    tpbswg: f32 = 0.0,

    // --- SOI Diffusion Capacitance ---
    vsdfb: f32 = 0.0,
    vsdth: f32 = 0.0,
    csdmin: f32 = 1.00544e-4,
    asd: f32 = 0.3,
    csdesw: f32 = 0.0,

    // --- Backgate Charge ---
    kb1: f32 = 1.0,
    dlbg: f32 = 0.0,
    fbody: f32 = 1.0,

    // --- C-V Model (CapMod=3) ---
    acde: f32 = 1.0,
    moin: f32 = 15.0,

    // --- Noise ---
    noia: f32 = 1.0e20,
    noib: f32 = 50000.0,
    noic: f32 = -1.4e-12,
    em: f32 = 4.1e7,
    ef: f32 = 1.0,
    af: f32 = 1.0,
    kf: f32 = 0.0,
    noif: f32 = 1.0,

    // --- Geometry Reduction (Length) ---
    lint: f32 = 0.0,
    ll: f32 = 0.0,
    llc: f32 = 0.0,
    lln: f32 = 1.0,
    lw: f32 = 0.0,
    lwc: f32 = 0.0,
    lwn: f32 = 1.0,
    lwl: f32 = 0.0,
    lwlc: f32 = 0.0,
    dlc: f32 = 0.0,
    dlcb: f32 = 0.0,

    // --- Geometry Reduction (Width) ---
    wint: f32 = 0.0,
    dwg: f32 = 0.0,
    dwb: f32 = 0.0,
    wl: f32 = 0.0,
    wlc: f32 = 0.0,
    wln: f32 = 1.0,
    ww: f32 = 0.0,
    wwc: f32 = 0.0,
    wwn: f32 = 1.0,
    wwl: f32 = 0.0,
    wwlc: f32 = 0.0,
    dwc: f32 = 0.0,
    dwbc: f32 = 0.0,

    // --- Length Dependence (L-prefix) ---
    lnch: f32 = 0.0,
    lnsub: f32 = 0.0,
    lngate: f32 = 0.0,
    lvth0: f32 = 0.0,
    lk1: f32 = 0.0,
    lk1w1: f32 = 0.0,
    lk1w2: f32 = 0.0,
    lk2: f32 = 0.0,
    lk3: f32 = 0.0,
    lk3b: f32 = 0.0,
    lkb1: f32 = 0.0,
    lw0: f32 = 0.0,
    lnlx: f32 = 0.0,
    ldvt0: f32 = 0.0,
    ldvt1: f32 = 0.0,
    ldvt2: f32 = 0.0,
    ldvt0w: f32 = 0.0,
    ldvt1w: f32 = 0.0,
    ldvt2w: f32 = 0.0,
    lu0: f32 = 0.0,
    lua: f32 = 0.0,
    lub: f32 = 0.0,
    luc: f32 = 0.0,
    lvsat: f32 = 0.0,
    la0: f32 = 0.0,
    lags: f32 = 0.0,
    lb0: f32 = 0.0,
    lb1: f32 = 0.0,
    lketa: f32 = 0.0,
    lketas: f32 = 0.0,
    la1: f32 = 0.0,
    la2: f32 = 0.0,
    lrdsw: f32 = 0.0,
    lprwb: f32 = 0.0,
    lprwg: f32 = 0.0,
    lwr: f32 = 0.0,
    lnfactor: f32 = 0.0,
    ldwg: f32 = 0.0,
    ldwb: f32 = 0.0,
    lvoff: f32 = 0.0,
    leta0: f32 = 0.0,
    letab: f32 = 0.0,
    ldsub: f32 = 0.0,
    lcit: f32 = 0.0,
    lcdsc: f32 = 0.0,
    lcdscb: f32 = 0.0,
    lcdscd: f32 = 0.0,
    lpclm: f32 = 0.0,
    lpdiblc1: f32 = 0.0,
    lpdiblc2: f32 = 0.0,
    lpdiblcb: f32 = 0.0,
    ldrout: f32 = 0.0,
    lpvag: f32 = 0.0,
    ldelta: f32 = 0.0,
    lalpha0: f32 = 0.0,
    lfbjtii: f32 = 0.0,
    lbeta0: f32 = 0.0,
    lbeta1: f32 = 0.0,
    lbeta2: f32 = 0.0,
    lvdsatii0: f32 = 0.0,
    llii: f32 = 0.0,
    lesatii: f32 = 0.0,
    lsii0: f32 = 0.0,
    lsii1: f32 = 0.0,
    lsii2: f32 = 0.0,
    lsiid: f32 = 0.0,
    lagidl: f32 = 0.0,
    lbgidl: f32 = 0.0,
    lngidl: f32 = 0.0,
    lntun: f32 = 0.0,
    lndiode: f32 = 0.0,
    lnrecf0: f32 = 0.0,
    lnrecr0: f32 = 0.0,
    lisbjt: f32 = 0.0,
    lisdif: f32 = 0.0,
    lisrec: f32 = 0.0,
    listun: f32 = 0.0,
    lvrec0: f32 = 0.0,
    lvtun0: f32 = 0.0,
    lnbjt: f32 = 0.0,
    llbjt0: f32 = 0.0,
    lvabjt: f32 = 0.0,
    laely: f32 = 0.0,
    lahli: f32 = 0.0,
    lvsdfb: f32 = 0.0,
    lvsdth: f32 = 0.0,
    ldelvt: f32 = 0.0,
    lacde: f32 = 0.0,
    lmoin: f32 = 0.0,

    // --- Width Dependence (W-prefix) ---
    wnch: f32 = 0.0,
    wnsub: f32 = 0.0,
    wngate: f32 = 0.0,
    wvth0: f32 = 0.0,
    wk1: f32 = 0.0,
    wk1w1: f32 = 0.0,
    wk1w2: f32 = 0.0,
    wk2: f32 = 0.0,
    wk3: f32 = 0.0,
    wk3b: f32 = 0.0,
    wkb1: f32 = 0.0,
    ww0: f32 = 0.0,
    wnlx: f32 = 0.0,
    wdvt0: f32 = 0.0,
    wdvt1: f32 = 0.0,
    wdvt2: f32 = 0.0,
    wdvt0w: f32 = 0.0,
    wdvt1w: f32 = 0.0,
    wdvt2w: f32 = 0.0,
    wu0: f32 = 0.0,
    wua: f32 = 0.0,
    wub: f32 = 0.0,
    wuc: f32 = 0.0,
    wvsat: f32 = 0.0,
    wa0: f32 = 0.0,
    wags: f32 = 0.0,
    wb0: f32 = 0.0,
    wb1: f32 = 0.0,
    wketa: f32 = 0.0,
    wketas: f32 = 0.0,
    wa1: f32 = 0.0,
    wa2: f32 = 0.0,
    wrdsw: f32 = 0.0,
    wprwb: f32 = 0.0,
    wprwg: f32 = 0.0,
    wwr: f32 = 0.0,
    wnfactor: f32 = 0.0,
    wdwg: f32 = 0.0,
    wdwb: f32 = 0.0,
    wvoff: f32 = 0.0,
    weta0: f32 = 0.0,
    wetab: f32 = 0.0,
    wdsub: f32 = 0.0,
    wcit: f32 = 0.0,
    wcdsc: f32 = 0.0,
    wcdscb: f32 = 0.0,
    wcdscd: f32 = 0.0,
    wpclm: f32 = 0.0,
    wpdiblc1: f32 = 0.0,
    wpdiblc2: f32 = 0.0,
    wpdiblcb: f32 = 0.0,
    wdrout: f32 = 0.0,
    wpvag: f32 = 0.0,
    wdelta: f32 = 0.0,
    walpha0: f32 = 0.0,
    wfbjtii: f32 = 0.0,
    wbeta0: f32 = 0.0,
    wbeta1: f32 = 0.0,
    wbeta2: f32 = 0.0,
    wvdsatii0: f32 = 0.0,
    wlii: f32 = 0.0,
    wesatii: f32 = 0.0,
    wsii0: f32 = 0.0,
    wsii1: f32 = 0.0,
    wsii2: f32 = 0.0,
    wsiid: f32 = 0.0,
    wagidl: f32 = 0.0,
    wbgidl: f32 = 0.0,
    wngidl: f32 = 0.0,
    wntun: f32 = 0.0,
    wndiode: f32 = 0.0,
    wnrecf0: f32 = 0.0,
    wnrecr0: f32 = 0.0,
    wisbjt: f32 = 0.0,
    wisdif: f32 = 0.0,
    wisrec: f32 = 0.0,
    wistun: f32 = 0.0,
    wvrec0: f32 = 0.0,
    wvtun0: f32 = 0.0,
    wnbjt: f32 = 0.0,
    wlbjt0: f32 = 0.0,
    wvabjt: f32 = 0.0,
    waely: f32 = 0.0,
    wahli: f32 = 0.0,
    wvsdfb: f32 = 0.0,
    wvsdth: f32 = 0.0,
    wdelvt: f32 = 0.0,
    wacde: f32 = 0.0,
    wmoin: f32 = 0.0,

    // --- Cross-Term Dependence (P-prefix) ---
    pnch: f32 = 0.0,
    pnsub: f32 = 0.0,
    pngate: f32 = 0.0,
    pvth0: f32 = 0.0,
    pk1: f32 = 0.0,
    pk1w1: f32 = 0.0,
    pk1w2: f32 = 0.0,
    pk2: f32 = 0.0,
    pk3: f32 = 0.0,
    pk3b: f32 = 0.0,
    pkb1: f32 = 0.0,
    pw0: f32 = 0.0,
    pnlx: f32 = 0.0,
    pdvt0: f32 = 0.0,
    pdvt1: f32 = 0.0,
    pdvt2: f32 = 0.0,
    pdvt0w: f32 = 0.0,
    pdvt1w: f32 = 0.0,
    pdvt2w: f32 = 0.0,
    pu0: f32 = 0.0,
    pua: f32 = 0.0,
    pub_: f32 = 0.0,
    puc: f32 = 0.0,
    pvsat: f32 = 0.0,
    pa0: f32 = 0.0,
    pags: f32 = 0.0,
    pb0: f32 = 0.0,
    pb1: f32 = 0.0,
    pketa: f32 = 0.0,
    pketas: f32 = 0.0,
    pa1: f32 = 0.0,
    pa2: f32 = 0.0,
    prdsw: f32 = 0.0,
    pprwb: f32 = 0.0,
    pprwg: f32 = 0.0,
    pwr: f32 = 0.0,
    pnfactor: f32 = 0.0,
    pdwg: f32 = 0.0,
    pdwb: f32 = 0.0,
    pvoff: f32 = 0.0,
    peta0: f32 = 0.0,
    petab: f32 = 0.0,
    pdsub: f32 = 0.0,
    pcit: f32 = 0.0,
    pcdsc: f32 = 0.0,
    pcdscb: f32 = 0.0,
    pcdscd: f32 = 0.0,
    ppclm: f32 = 0.0,
    ppdiblc1: f32 = 0.0,
    ppdiblc2: f32 = 0.0,
    ppdiblcb: f32 = 0.0,
    pdrout: f32 = 0.0,
    ppvag: f32 = 0.0,
    pdelta: f32 = 0.0,
    palpha0: f32 = 0.0,
    pfbjtii: f32 = 0.0,
    pbeta0: f32 = 0.0,
    pbeta1: f32 = 0.0,
    pbeta2: f32 = 0.0,
    pvdsatii0: f32 = 0.0,
    plii: f32 = 0.0,
    pesatii: f32 = 0.0,
    psii0: f32 = 0.0,
    psii1: f32 = 0.0,
    psii2: f32 = 0.0,
    psiid: f32 = 0.0,
    pagidl: f32 = 0.0,
    pbgidl: f32 = 0.0,
    pngidl: f32 = 0.0,
    pntun: f32 = 0.0,
    pndiode: f32 = 0.0,
    pnrecf0: f32 = 0.0,
    pnrecr0: f32 = 0.0,
    pisbjt: f32 = 0.0,
    pisdif: f32 = 0.0,
    pisrec: f32 = 0.0,
    pistun: f32 = 0.0,
    pvrec0: f32 = 0.0,
    pvtun0: f32 = 0.0,
    pnbjt: f32 = 0.0,
    plbjt0: f32 = 0.0,
    pvabjt: f32 = 0.0,
    paely: f32 = 0.0,
    pahli: f32 = 0.0,
    pvsdfb: f32 = 0.0,
    pvsdth: f32 = 0.0,
    pdelvt: f32 = 0.0,
    pacde: f32 = 0.0,
    pmoin: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 1e-6,
    l: f32 = 1e-6,
    temp: f64 = 300.15,
    m: f32 = 1.0,
    nrd: f32 = 1.0,
    nrs: f32 = 1.0,
};

// ============================================================================
// L/W/P Parameter Extraction Helper
// ============================================================================

inline // b3soipdtemp.c: u0 > 1 is in cm^2/(V*s) -> convert to m^2/(V*s)
fn convMobilityUnits(u: f64) f64 {
    return if (u > 1.0) u / 1.0e4 else u;
}

fn lwpParam(base: f64, l_dep: f64, w_dep: f64, p_dep: f64, l_inv: f64, w_inv: f64) f64 {
    return base + l_dep * l_inv + w_dep * w_inv + p_dep * l_inv * w_inv;
}

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: D -- DP
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    // RS branch: S -- SP
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    // Channel DP -- SP (depends on G, B, E, TEMP)
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.body) },
    // Body junctions: B -- DP, B -- SP
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.source_prime) },
    // Body resistance: B -- P
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body_contact) },
    .{ .row = @intFromEnum(U.body_contact), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body_contact), .col = @intFromEnum(U.body_contact) },
    // Gate row (gmin)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source) },
    // Substrate row (gmin)
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.substrate) },
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.source) },
    // Self-heating: TEMP node
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.temp) },
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.source_prime) },
    // Source gmin entries
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.substrate) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.body_contact) },
    // Body contact gmin: P -- S
    .{ .row = @intFromEnum(U.body_contact), .col = @intFromEnum(U.source) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Gate charges: G -- SP, G -- DP, G -- B
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.body) },
    // Body charges: B -- SP, B -- DP, B -- G, B -- E
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.substrate) },
    // DP charges
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.body) },
    // SP charges
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.body) },
    // Substrate charge: E -- SP, E -- B
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.substrate) },
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.body) },
    // Thermal capacitance: TEMP -- TEMP
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.temp) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- DP
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- SP
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Body resistance thermal noise: B -- P
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body_contact), .kind = .thermal },
    // Channel shot noise: DP -- SP
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Flicker noise: DP -- SP
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
};

// ============================================================================
// Effective (x-independent) Parameters for the DC current function.
// Everything here is pure geometry / model / instance data — no terminal
// voltage — so it stays plain f64 and is computed once per eval.
// ============================================================================

const EvalParams = struct {
    type_f: f64,
    gmin: f64,
    GSHORT: f64,
    eps_si: f64,
    eps_ox: f64,
    q_e: f64,
    kb_q: f64,
    ni: f64,

    m_tox: f64,
    m_tsi: f64,
    m_tnom: f64,
    m_nch: f64,
    m_fbjtii: f64,
    m_ln: f64,

    inst_m: f64,

    l_eff: f64,
    w_eff: f64,
    l_inv: f64,
    w_inv: f64,
    xj: f64,

    // temperature coefficients (x-independent parts)
    m_kt1: f64,
    m_kt1l: f64,
    m_kt2: f64,
    m_ute: f64,
    m_at: f64,
    m_prt: f64,

    // effective LWP params
    e_vth0: f64,
    e_k2: f64,
    e_k3: f64,
    e_k3b: f64,
    e_dvt0: f64,
    e_dvt1: f64,
    e_dvt2: f64,
    e_dvt0w: f64,
    e_dvt1w: f64,
    e_dvt2w: f64,
    e_nlx: f64,
    e_w0: f64,
    e_eta0: f64,
    e_etab: f64,
    e_dsub: f64,
    e_drout: f64,
    e_pdiblc1: f64,
    e_pdiblc2: f64,
    e_pdiblcb: f64,
    e_pclm: f64,
    e_pvag: f64,
    e_u0: f64,
    e_ua: f64,
    e_ub: f64,
    e_uc: f64,
    e_vsat: f64,
    e_a0: f64,
    e_ags: f64,
    e_a2: f64,
    e_b0: f64,
    e_b1_p: f64,
    e_keta: f64,
    e_ketas: f64,
    e_delta: f64,
    e_nfactor: f64,
    e_cdsc: f64,
    e_cdscb: f64,
    e_cdscd: f64,
    e_cit: f64,
    e_voff: f64,
    e_rdsw: f64,
    e_prwg: f64,
    e_prwb: f64,
    e_wr: f64,
    k1_eff: f64,

    // SOI body current params
    e_isbjt: f64,
    e_nbjt: f64,
    e_lbjt0: f64,
    e_vabjt: f64,
    e_aely: f64,
    e_ahli: f64,
    e_isdif: f64,
    e_ndiode: f64,
    e_isrec: f64,
    e_nrecf0: f64,
    e_nrecr0: f64,
    e_vrec0: f64,
    e_istun: f64,
    e_ntun: f64,
    e_vtun0: f64,

    // impact ionization
    e_alpha0: f64,
    e_beta0: f64,
    e_beta1: f64,
    e_beta2: f64,
    e_vdsatii0: f64,
    e_lii_p: f64,
    e_sii0: f64,
    e_sii1: f64,
    e_sii2: f64,
    e_siid: f64,
    e_esatii: f64,

    // GIDL
    e_agidl: f64,
    e_bgidl: f64,
    e_ngidl: f64,
    gidl_active: bool,

    // external resistances
    g_d_ext: f64,
    g_s_ext: f64,
    g_body: f64,

    // gate current
    igmod_enabled: bool,
    m_ntox: f64,
    m_ebg: f64,
    m_vevb: f64,
    m_alphagb1: f64,
    m_betagb1: f64,
    m_vgb1: f64,
    m_vecb: f64,
    m_alphagb2: f64,
    m_betagb2: f64,
    m_vgb2: f64,
    m_voxh: f64,
    m_deltavox: f64,
    m_toxref: f64,

    // self-heating
    m_rth0: f64,
    sh_enabled: bool,
};

fn evalParams(model: *const Model, instance: *const Instance) EvalParams {
    const eps_si: f64 = 1.03594e-10;
    const eps_ox: f64 = 3.453133e-11;
    const q_e: f64 = 1.60219e-19;
    const kb_q: f64 = 8.617087e-5;
    const ni: f64 = 1.45e10;
    const GSHORT: f64 = 1.0e3;

    const type_f: f64 = @floatFromInt(model.type_);
    const m_tox: f64 = if (model.toxe > 0.0) @as(f64, model.toxe) else @as(f64, model.tox);
    const m_tsi: f64 = @as(f64, model.tsi);
    const m_tnom: f64 = @as(f64, model.tnom) + 273.15; // card TNOM is Celsius
    const m_nch: f64 = @as(f64, model.nch);
    const m_rsh: f64 = @as(f64, model.rsh);
    const m_rbody: f64 = @as(f64, model.rbody);
    const m_rth0: f64 = @as(f64, model.rth0);
    const m_shmod: f64 = @floatFromInt(model.shmod);
    const m_lint: f64 = @as(f64, model.lint);
    const m_wint: f64 = @as(f64, model.wint);
    const m_fbjtii: f64 = @as(f64, model.fbjtii);
    const m_ln: f64 = @as(f64, model.ln);
    const m_agidl: f64 = @as(f64, model.agidl);
    const m_bgidl: f64 = @as(f64, model.bgidl);
    const m_ngidl: f64 = @as(f64, model.ngidl);

    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_m: f64 = @as(f64, instance.m);
    const inst_nrd: f64 = @as(f64, instance.nrd);
    const inst_nrs: f64 = @as(f64, instance.nrs);

    const l_eff = @max(inst_l - 2.0 * m_lint, 1.0e-9);
    const w_eff = @max(inst_w - 2.0 * m_wint, 1.0e-9);
    const l_inv = 1.0 / l_eff;
    const w_inv = 1.0 / w_eff;

    const m_xj_raw: f64 = @as(f64, model.xj);
    const xj_is_nan = m_xj_raw != m_xj_raw;
    const xj = if (xj_is_nan) l_eff else m_xj_raw;

    const e_agidl = lwpParam(m_agidl, @as(f64, model.lagidl), @as(f64, model.wagidl), @as(f64, model.pagidl), l_inv, w_inv);
    const e_bgidl = lwpParam(m_bgidl, @as(f64, model.lbgidl), @as(f64, model.wbgidl), @as(f64, model.pbgidl), l_inv, w_inv);

    return .{
        .type_f = type_f,
        .gmin = 1.0e-12,
        .GSHORT = GSHORT,
        .eps_si = eps_si,
        .eps_ox = eps_ox,
        .q_e = q_e,
        .kb_q = kb_q,
        .ni = ni,
        .m_tox = m_tox,
        .m_tsi = m_tsi,
        .m_tnom = m_tnom,
        .m_nch = m_nch,
        .m_fbjtii = m_fbjtii,
        .m_ln = m_ln,
        .inst_m = inst_m,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .l_inv = l_inv,
        .w_inv = w_inv,
        .xj = xj,
        .m_kt1 = @as(f64, model.kt1),
        .m_kt1l = @as(f64, model.kt1l),
        .m_kt2 = @as(f64, model.kt2),
        .m_ute = @as(f64, model.ute),
        .m_at = @as(f64, model.at),
        .m_prt = @as(f64, model.prt),
        .e_vth0 = lwpParam(@as(f64, model.vth0), @as(f64, model.lvth0), @as(f64, model.wvth0), @as(f64, model.pvth0), l_inv, w_inv),
        .e_k2 = lwpParam(@as(f64, model.k2), @as(f64, model.lk2), @as(f64, model.wk2), @as(f64, model.pk2), l_inv, w_inv),
        .e_k3 = lwpParam(@as(f64, model.k3), @as(f64, model.lk3), @as(f64, model.wk3), @as(f64, model.pk3), l_inv, w_inv),
        .e_k3b = lwpParam(@as(f64, model.k3b), @as(f64, model.lk3b), @as(f64, model.wk3b), @as(f64, model.pk3b), l_inv, w_inv),
        .e_dvt0 = lwpParam(@as(f64, model.dvt0), @as(f64, model.ldvt0), @as(f64, model.wdvt0), @as(f64, model.pdvt0), l_inv, w_inv),
        .e_dvt1 = lwpParam(@as(f64, model.dvt1), @as(f64, model.ldvt1), @as(f64, model.wdvt1), @as(f64, model.pdvt1), l_inv, w_inv),
        .e_dvt2 = lwpParam(@as(f64, model.dvt2), @as(f64, model.ldvt2), @as(f64, model.wdvt2), @as(f64, model.pdvt2), l_inv, w_inv),
        .e_dvt0w = lwpParam(@as(f64, model.dvt0w), @as(f64, model.ldvt0w), @as(f64, model.wdvt0w), @as(f64, model.pdvt0w), l_inv, w_inv),
        .e_dvt1w = lwpParam(@as(f64, model.dvt1w), @as(f64, model.ldvt1w), @as(f64, model.wdvt1w), @as(f64, model.pdvt1w), l_inv, w_inv),
        .e_dvt2w = lwpParam(@as(f64, model.dvt2w), @as(f64, model.ldvt2w), @as(f64, model.wdvt2w), @as(f64, model.pdvt2w), l_inv, w_inv),
        .e_nlx = lwpParam(@as(f64, model.nlx), @as(f64, model.lnlx), @as(f64, model.wnlx), @as(f64, model.pnlx), l_inv, w_inv),
        .e_w0 = lwpParam(@as(f64, model.w0), @as(f64, model.lw0), @as(f64, model.ww0), @as(f64, model.pw0), l_inv, w_inv),
        .e_eta0 = lwpParam(@as(f64, model.eta0), @as(f64, model.leta0), @as(f64, model.weta0), @as(f64, model.peta0), l_inv, w_inv),
        .e_etab = lwpParam(@as(f64, model.etab), @as(f64, model.letab), @as(f64, model.wetab), @as(f64, model.petab), l_inv, w_inv),
        .e_dsub = lwpParam(@as(f64, model.dsub), @as(f64, model.ldsub), @as(f64, model.wdsub), @as(f64, model.pdsub), l_inv, w_inv),
        .e_drout = lwpParam(@as(f64, model.drout), @as(f64, model.ldrout), @as(f64, model.wdrout), @as(f64, model.pdrout), l_inv, w_inv),
        .e_pdiblc1 = lwpParam(@as(f64, model.pdiblc1), @as(f64, model.lpdiblc1), @as(f64, model.wpdiblc1), @as(f64, model.ppdiblc1), l_inv, w_inv),
        .e_pdiblc2 = lwpParam(@as(f64, model.pdiblc2), @as(f64, model.lpdiblc2), @as(f64, model.wpdiblc2), @as(f64, model.ppdiblc2), l_inv, w_inv),
        .e_pdiblcb = lwpParam(@as(f64, model.pdiblcb), @as(f64, model.lpdiblcb), @as(f64, model.wpdiblcb), @as(f64, model.ppdiblcb), l_inv, w_inv),
        .e_pclm = lwpParam(@as(f64, model.pclm), @as(f64, model.lpclm), @as(f64, model.wpclm), @as(f64, model.ppclm), l_inv, w_inv),
        .e_pvag = lwpParam(@as(f64, model.pvag), @as(f64, model.lpvag), @as(f64, model.wpvag), @as(f64, model.ppvag), l_inv, w_inv),
        .e_u0 = convMobilityUnits(lwpParam(@as(f64, model.u0), @as(f64, model.lu0), @as(f64, model.wu0), @as(f64, model.pu0), l_inv, w_inv)),
        .e_ua = lwpParam(@as(f64, model.ua), @as(f64, model.lua), @as(f64, model.wua), @as(f64, model.pua), l_inv, w_inv),
        .e_ub = lwpParam(@as(f64, model.ub), @as(f64, model.lub), @as(f64, model.wub), @as(f64, model.pub_), l_inv, w_inv),
        .e_uc = lwpParam(@as(f64, model.uc), @as(f64, model.luc), @as(f64, model.wuc), @as(f64, model.puc), l_inv, w_inv),
        .e_vsat = lwpParam(@as(f64, model.vsat), @as(f64, model.lvsat), @as(f64, model.wvsat), @as(f64, model.pvsat), l_inv, w_inv),
        .e_a0 = lwpParam(@as(f64, model.a0), @as(f64, model.la0), @as(f64, model.wa0), @as(f64, model.pa0), l_inv, w_inv),
        .e_ags = lwpParam(@as(f64, model.ags), @as(f64, model.lags), @as(f64, model.wags), @as(f64, model.pags), l_inv, w_inv),
        .e_a2 = lwpParam(@as(f64, model.a2), @as(f64, model.la2), @as(f64, model.wa2), @as(f64, model.pa2), l_inv, w_inv),
        .e_b0 = lwpParam(@as(f64, model.b0), @as(f64, model.lb0), @as(f64, model.wb0), @as(f64, model.pb0), l_inv, w_inv),
        .e_b1_p = lwpParam(@as(f64, model.b1), @as(f64, model.lb1), @as(f64, model.wb1), @as(f64, model.pb1), l_inv, w_inv),
        .e_keta = lwpParam(@as(f64, model.keta), @as(f64, model.lketa), @as(f64, model.wketa), @as(f64, model.pketa), l_inv, w_inv),
        .e_ketas = lwpParam(@as(f64, model.ketas), @as(f64, model.lketas), @as(f64, model.wketas), @as(f64, model.pketas), l_inv, w_inv),
        .e_delta = lwpParam(@as(f64, model.delta), @as(f64, model.ldelta), @as(f64, model.wdelta), @as(f64, model.pdelta), l_inv, w_inv),
        .e_nfactor = lwpParam(@as(f64, model.nfactor), @as(f64, model.lnfactor), @as(f64, model.wnfactor), @as(f64, model.pnfactor), l_inv, w_inv),
        .e_cdsc = lwpParam(@as(f64, model.cdsc), @as(f64, model.lcdsc), @as(f64, model.wcdsc), @as(f64, model.pcdsc), l_inv, w_inv),
        .e_cdscb = lwpParam(@as(f64, model.cdscb), @as(f64, model.lcdscb), @as(f64, model.wcdscb), @as(f64, model.pcdscb), l_inv, w_inv),
        .e_cdscd = lwpParam(@as(f64, model.cdscd), @as(f64, model.lcdscd), @as(f64, model.wcdscd), @as(f64, model.pcdscd), l_inv, w_inv),
        .e_cit = lwpParam(@as(f64, model.cit), @as(f64, model.lcit), @as(f64, model.wcit), @as(f64, model.pcit), l_inv, w_inv),
        .e_voff = lwpParam(@as(f64, model.voff), @as(f64, model.lvoff), @as(f64, model.wvoff), @as(f64, model.pvoff), l_inv, w_inv),
        .e_rdsw = lwpParam(@as(f64, model.rdsw), @as(f64, model.lrdsw), @as(f64, model.wrdsw), @as(f64, model.prdsw), l_inv, w_inv),
        .e_prwg = lwpParam(@as(f64, model.prwg), @as(f64, model.lprwg), @as(f64, model.wprwg), @as(f64, model.pprwg), l_inv, w_inv),
        .e_prwb = lwpParam(@as(f64, model.prwb), @as(f64, model.lprwb), @as(f64, model.wprwb), @as(f64, model.pprwb), l_inv, w_inv),
        .e_wr = lwpParam(@as(f64, model.wr), @as(f64, model.lwr), @as(f64, model.wwr), @as(f64, model.pwr), l_inv, w_inv),
        .k1_eff = blk: {
            const e_k1 = lwpParam(@as(f64, model.k1), @as(f64, model.lk1), @as(f64, model.wk1), @as(f64, model.pk1), l_inv, w_inv);
            const e_k1w1 = lwpParam(@as(f64, model.k1w1), @as(f64, model.lk1w1), @as(f64, model.wk1w1), @as(f64, model.pk1w1), l_inv, w_inv);
            const e_k1w2 = lwpParam(@as(f64, model.k1w2), @as(f64, model.lk1w2), @as(f64, model.wk1w2), @as(f64, model.pk1w2), l_inv, w_inv);
            const k1_denom = @max(w_eff + e_k1w2, 1.0e-8);
            break :blk e_k1 * (1.0 + e_k1w1 / k1_denom);
        },
        .e_isbjt = lwpParam(@as(f64, model.isbjt), @as(f64, model.lisbjt), @as(f64, model.wisbjt), @as(f64, model.pisbjt), l_inv, w_inv),
        .e_nbjt = lwpParam(@as(f64, model.nbjt), @as(f64, model.lnbjt), @as(f64, model.wnbjt), @as(f64, model.pnbjt), l_inv, w_inv),
        .e_lbjt0 = lwpParam(@as(f64, model.lbjt0), @as(f64, model.llbjt0), @as(f64, model.wlbjt0), @as(f64, model.plbjt0), l_inv, w_inv),
        .e_vabjt = lwpParam(@as(f64, model.vabjt), @as(f64, model.lvabjt), @as(f64, model.wvabjt), @as(f64, model.pvabjt), l_inv, w_inv),
        .e_aely = lwpParam(@as(f64, model.aely), @as(f64, model.laely), @as(f64, model.waely), @as(f64, model.paely), l_inv, w_inv),
        .e_ahli = lwpParam(@as(f64, model.ahli), @as(f64, model.lahli), @as(f64, model.wahli), @as(f64, model.pahli), l_inv, w_inv),
        .e_isdif = lwpParam(@as(f64, model.isdif), @as(f64, model.lisdif), @as(f64, model.wisdif), @as(f64, model.pisdif), l_inv, w_inv),
        .e_ndiode = lwpParam(@as(f64, model.ndiode), @as(f64, model.lndiode), @as(f64, model.wndiode), @as(f64, model.pndiode), l_inv, w_inv),
        .e_isrec = lwpParam(@as(f64, model.isrec), @as(f64, model.lisrec), @as(f64, model.wisrec), @as(f64, model.pisrec), l_inv, w_inv),
        .e_nrecf0 = lwpParam(@as(f64, model.nrecf0), @as(f64, model.lnrecf0), @as(f64, model.wnrecf0), @as(f64, model.pnrecf0), l_inv, w_inv),
        .e_nrecr0 = lwpParam(@as(f64, model.nrecr0), @as(f64, model.lnrecr0), @as(f64, model.wnrecr0), @as(f64, model.pnrecr0), l_inv, w_inv),
        .e_vrec0 = lwpParam(@as(f64, model.vrec0), @as(f64, model.lvrec0), @as(f64, model.wvrec0), @as(f64, model.pvrec0), l_inv, w_inv),
        .e_istun = lwpParam(@as(f64, model.istun), @as(f64, model.listun), @as(f64, model.wistun), @as(f64, model.pistun), l_inv, w_inv),
        .e_ntun = lwpParam(@as(f64, model.ntun), @as(f64, model.lntun), @as(f64, model.wntun), @as(f64, model.pntun), l_inv, w_inv),
        .e_vtun0 = lwpParam(@as(f64, model.vtun0), @as(f64, model.lvtun0), @as(f64, model.wvtun0), @as(f64, model.pvtun0), l_inv, w_inv),
        .e_alpha0 = lwpParam(@as(f64, model.alpha0), @as(f64, model.lalpha0), @as(f64, model.walpha0), @as(f64, model.palpha0), l_inv, w_inv),
        .e_beta0 = lwpParam(@as(f64, model.beta0), @as(f64, model.lbeta0), @as(f64, model.wbeta0), @as(f64, model.pbeta0), l_inv, w_inv),
        .e_beta1 = lwpParam(@as(f64, model.beta1), @as(f64, model.lbeta1), @as(f64, model.wbeta1), @as(f64, model.pbeta1), l_inv, w_inv),
        .e_beta2 = lwpParam(@as(f64, model.beta2), @as(f64, model.lbeta2), @as(f64, model.wbeta2), @as(f64, model.pbeta2), l_inv, w_inv),
        .e_vdsatii0 = lwpParam(@as(f64, model.vdsatii0), @as(f64, model.lvdsatii0), @as(f64, model.wvdsatii0), @as(f64, model.pvdsatii0), l_inv, w_inv),
        .e_lii_p = lwpParam(@as(f64, model.lii), @as(f64, model.llii), @as(f64, model.wlii), @as(f64, model.plii), l_inv, w_inv),
        .e_sii0 = lwpParam(@as(f64, model.sii0), @as(f64, model.lsii0), @as(f64, model.wsii0), @as(f64, model.psii0), l_inv, w_inv),
        .e_sii1 = lwpParam(@as(f64, model.sii1), @as(f64, model.lsii1), @as(f64, model.wsii1), @as(f64, model.psii1), l_inv, w_inv),
        .e_sii2 = lwpParam(@as(f64, model.sii2), @as(f64, model.lsii2), @as(f64, model.wsii2), @as(f64, model.psii2), l_inv, w_inv),
        .e_siid = lwpParam(@as(f64, model.siid), @as(f64, model.lsiid), @as(f64, model.wsiid), @as(f64, model.psiid), l_inv, w_inv),
        .e_esatii = lwpParam(@as(f64, model.esatii), @as(f64, model.lesatii), @as(f64, model.wesatii), @as(f64, model.pesatii), l_inv, w_inv),
        .e_agidl = e_agidl,
        .e_bgidl = e_bgidl,
        .e_ngidl = lwpParam(m_ngidl, @as(f64, model.lngidl), @as(f64, model.wngidl), @as(f64, model.pngidl), l_inv, w_inv),
        .gidl_active = (e_agidl > 0.0 and e_bgidl > 0.0),
        .g_d_ext = if (m_rsh > 0.0) inst_w * inst_m / (m_rsh * inst_nrd) else GSHORT,
        .g_s_ext = if (m_rsh > 0.0) inst_w * inst_m / (m_rsh * inst_nrs) else GSHORT,
        .g_body = if (m_rbody > 0.0) 1.0 / m_rbody else GSHORT,
        .igmod_enabled = (model.igmod > 0),
        .m_ntox = @as(f64, model.ntox),
        .m_ebg = @as(f64, model.ebg),
        .m_vevb = @as(f64, model.vevb),
        .m_alphagb1 = @as(f64, model.alphagb1),
        .m_betagb1 = @as(f64, model.betagb1),
        .m_vgb1 = @as(f64, model.vgb1),
        .m_vecb = @as(f64, model.vecb),
        .m_alphagb2 = @as(f64, model.alphagb2),
        .m_betagb2 = @as(f64, model.betagb2),
        .m_vgb2 = @as(f64, model.vgb2),
        .m_voxh = @as(f64, model.voxh),
        .m_deltavox = @as(f64, model.deltavox),
        .m_toxref = @as(f64, model.toxref),
        .m_rth0 = m_rth0,
        .sh_enabled = (m_shmod > 0.5 and m_rth0 > 0.0),
    };
}

pub const PrepCache = EvalParams;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return evalParams(model, instance);
}

// ============================================================================
// DC Current Function (value-form)
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
    const e = @intFromEnum(U.substrate);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const b = @intFromEnum(U.body);
    const tmp = @intFromEnum(U.temp);
    const p = @intFromEnum(U.body_contact);

    const P = pc;

    // --- Physical constants ---
    const gmin: f64 = P.gmin;
    const eps_si: f64 = P.eps_si;
    const eps_ox: f64 = P.eps_ox;
    const q_e: f64 = P.q_e;
    const kb_q: f64 = P.kb_q;
    const ni: f64 = P.ni;

    const type_f = P.type_f;
    const m_tox = P.m_tox;
    const m_tsi = P.m_tsi;
    const m_tnom = P.m_tnom;
    const m_nch = P.m_nch;
    const m_fbjtii = P.m_fbjtii;
    const m_ln = P.m_ln;
    const inst_m = P.inst_m;

    const l_eff = P.l_eff;
    const w_eff = P.w_eff;
    const l_inv = P.l_inv;
    const xj = P.xj;

    // ========================================================================
    // Terminal Voltages (x reads — everything downstream is S)
    // ========================================================================
    const v_D = x[d];
    const v_G = x[g];
    const v_S = x[s];
    const v_E = x[e];
    const v_DP = x[dp];
    const v_SP = x[sp];
    const v_B = x[b];
    const v_TEMP = x[tmp];
    const v_P = x[p];

    // Resistance branch currents
    const i_d_dp = v_D.sub(v_DP).scale(P.g_d_ext);
    const i_s_sp = v_S.sub(v_SP).scale(P.g_s_ext);

    // Body contact resistance current
    const i_bp = v_B.sub(v_P).scale(P.g_body);

    // ========================================================================
    // Intrinsic Terminal Voltages with Type Factor
    // ========================================================================
    const v_gs_raw = v_G.sub(v_SP).scale(type_f);
    const v_ds_raw = v_DP.sub(v_SP).scale(type_f);
    const v_bs_raw = v_B.sub(v_SP).scale(type_f);

    // Source-drain reversal (smooth)
    const vds_smooth = v_ds_raw.mul(v_ds_raw).addC(1.0e-30).sqrt();
    const mode = v_ds_raw.div(vds_smooth);
    const w_fwd = mode.addC(1.0).scale(0.5);
    const w_rev = mode.neg().addC(1.0).scale(0.5);

    const v_ds = vds_smooth;
    const v_gs = w_fwd.mul(v_gs_raw).add(w_rev.mul(v_gs_raw.sub(v_ds_raw)));
    const v_bs = w_fwd.mul(v_bs_raw).add(w_rev.mul(v_bs_raw.sub(v_ds_raw)));
    const v_bd = v_bs.sub(v_ds);

    // ========================================================================
    // Temperature (self-heating rise is an unknown -> S)
    // ========================================================================
    const delta_t = v_TEMP; // self-heating temperature rise
    const vtm = delta_t.addC(m_tnom).scale(kb_q); // kb_q * t_dev
    const temp_ratio_m1 = delta_t.scale(1.0 / m_tnom);

    // ========================================================================
    // Oxide Capacitance
    // ========================================================================
    const cox = eps_ox / m_tox;

    // ========================================================================
    // Surface Potential and Depletion Width (x-independent)
    // ========================================================================
    const phi_s_raw = 2.0 * kb_q * m_tnom * contract.fmath.log(@max(m_nch / ni, 1.0));
    const phi_s = if (phi_s_raw >= 0.1) phi_s_raw else 0.6;
    const sqrt_phi_s = @sqrt(phi_s);

    const v_bi = kb_q * m_tnom * contract.fmath.log(@max(1.0e20 * m_nch / (ni * ni), 1.0));
    const v0 = v_bi - phi_s;

    const x_dep0 = @sqrt(2.0 * eps_si / (q_e * m_nch * 1.0e6)) * sqrt_phi_s;

    // ========================================================================
    // Vbseff -- Smooth Body-Bias Clamping
    // ========================================================================
    // Stage 1: lower limit at -5V
    const t0_s1 = v_bs.addC(4.999);
    const t1_s1 = t0_s1.mul(t0_s1).addC(0.02).sqrt();
    const vbs_low = t0_s1.add(t1_s1).scale(0.5).addC(-5.0);

    // Stage 2: upper limit at 1.5V
    const t0_s2 = vbs_low.neg().addC(1.5 - 0.002);
    const t3_s2 = t0_s2.mul(t0_s2).addC(0.012).sqrt();
    const vbsh = t0_s2.add(t3_s2).scale(-0.5).addC(1.5);

    // Stage 3: upper limit at 0.95*phi_s
    const t1_s3 = vbsh.neg().addC(0.95 * phi_s - 0.002);
    const t2_s3 = t1_s3.mul(t1_s3).addC(0.0076 * phi_s).sqrt();
    const v_bseff = t1_s3.add(t2_s3).scale(-0.5).addC(0.95 * phi_s);

    // ========================================================================
    // Depletion Width (bias-dependent)
    // ========================================================================
    const phi_is = v_bseff.neg().addC(phi_s);
    const sqrt_phi_is = phi_is.maxC(1.0e-30).sqrt();
    const x_dep = sqrt_phi_is.scale(x_dep0 / sqrt_phi_s);

    // ========================================================================
    // Threshold Voltage
    // ========================================================================
    const factor1 = @sqrt(eps_si / cox);

    // Short-channel effect (SCE)
    const lt1_arg = v_bseff.scale(P.e_dvt2).addC(1.0).maxC(0.2);
    const lt1 = x_dep.sqrt().scale(factor1).mul(lt1_arg).addC(1.0e-20);
    const dvt1_half = lt1.pow(-1.0).scale(P.e_dvt1 * l_eff / 2.0); // e_dvt1*l_eff/(2*lt1)
    const exp_dvt1 = dvt1_half.neg().maxC(-80.0).minC(80.0).exp();
    const theta_0 = exp_dvt1.mul(exp_dvt1.scale(2.0).addC(1.0));
    const dvth_sce = theta_0.scale(P.e_dvt0 * v0);

    // Narrow-width effect (NWE)
    const tmp2 = m_tox * phi_s / (w_eff + P.e_w0);
    const lt_w = factor1 * @sqrt(x_dep0);
    const lt_w_dvt2 = v_bseff.scale(P.e_dvt2w).addC(1.0).maxC(0.2);
    const lt_w_adj = lt_w_dvt2.scale(lt_w).addC(1.0e-20);
    const dvt1w_arg = lt_w_adj.pow(-1.0).scale(P.e_dvt1w * w_eff * l_eff / 2.0);
    const exp_dvt1w = dvt1w_arg.neg().maxC(-80.0).minC(80.0).exp();
    const theta_0w = exp_dvt1w.mul(exp_dvt1w.scale(2.0).addC(1.0));
    const dvth_nw = theta_0w.scale(P.e_dvt0w * v0);

    // DIBL
    const t1_dibl = @sqrt((eps_si / eps_ox) * m_tox * x_dep0);
    const dsub_half = P.e_dsub * l_eff / (2.0 * t1_dibl + 1.0e-20);
    const exp_dsub = contract.fmath.exp(@min(@max(-dsub_half, -80.0), 80.0));
    const theta_0_vb0 = exp_dsub * (1.0 + 2.0 * exp_dsub);
    const eta_eff = v_bseff.scale(P.e_etab).addC(P.e_eta0).maxC(1.0e-4);
    const dibl_sft = eta_eff.mul(v_ds).scale(theta_0_vb0);

    const k1_eff = P.k1_eff;

    // Temperature effect on Vth
    // dvth_t = k1_eff*(sqrt(1+nlx/leff)-1)*sqrt_phi_s + (kt1 + kt1l/leff + kt2*vbseff)*temp_ratio_m1
    const dvth_t_const = k1_eff * (@sqrt(1.0 + P.e_nlx / l_eff) - 1.0) * sqrt_phi_s;
    const dvth_t = v_bseff.scale(P.m_kt2).addC(P.m_kt1 + P.m_kt1l * l_inv).mul(temp_ratio_m1).addC(dvth_t_const);

    // Final Vth
    const vth = sqrt_phi_is.addC(-sqrt_phi_s).scale(k1_eff)
        .sub(v_bseff.scale(P.e_k2))
        .sub(dvth_sce)
        .sub(dvth_nw)
        .add(v_bseff.scale(P.e_k3b).addC(P.e_k3).scale(tmp2))
        .add(dvth_t)
        .sub(dibl_sft)
        .addC(P.e_vth0);

    // ========================================================================
    // Subthreshold Swing Factor
    // ========================================================================
    const t3_n = v_ds.scale(P.e_cdscd).add(v_bseff.scale(P.e_cdscb)).addC(P.e_cdsc);
    // t4_n = (t2_n + t3_n*theta_0 + e_cit) / cox, t2_n = e_nfactor*eps_si/(x_dep+1e-30)
    const t2_n = x_dep.addC(1.0e-20).pow(-1.0).scale(P.e_nfactor * eps_si);
    const t4_n = t2_n.add(t3_n.mul(theta_0)).addC(P.e_cit).scale(1.0 / cox);
    const n_sub = t4_n.addC(1.0).maxC(0.5);

    // ========================================================================
    // Effective Gate Overdrive (Vgsteff)
    // ========================================================================
    const v_gst_raw = v_gs.sub(vth);
    const v_gst = v_gst_raw.addC(P.e_voff);
    // exp_arg = min(v_gst/(2*n_sub*vtm), 80)
    const two_nsub_vtm = n_sub.mul(vtm).scale(2.0);
    const exp_arg = v_gst.div(two_nsub_vtm).minC(80.0);
    const vgsteff = exp_arg.exp().addC(1.0).log().mul(two_nsub_vtm);
    const vgst2vtm = vgsteff.add(vtm.scale(2.0));

    // ========================================================================
    // Mobility
    // ========================================================================
    // mu0_t = max(u0,1e-20) * exp(ute * log(max(1+temp_ratio_m1, 0.01)))
    const mu0_t = temp_ratio_m1.addC(1.0).maxC(0.01).log().scale(P.m_ute).exp().scale(@max(P.e_u0, 1.0e-20));

    // e_eff = (vgsteff + 2*vth)/tox
    const e_eff = vgsteff.add(vth.scale(2.0)).scale(1.0 / m_tox);

    // mob_denom = max(1 + ua*e_eff + ub*e_eff^2 + uc*vbseff, 0.2)
    const mob_denom = e_eff.scale(P.e_ua).add(e_eff.mul(e_eff).scale(P.e_ub)).add(v_bseff.scale(P.e_uc)).addC(1.0).maxC(0.2);
    const mu_eff = mu0_t.div(mob_denom);

    // ========================================================================
    // Saturation Velocity
    // ========================================================================
    const vsat_t = temp_ratio_m1.scale(-P.m_at).addC(P.e_vsat).maxC(1.0e3);
    const e_sat = vsat_t.scale(2.0).div(mu_eff.addC(1.0e-30));
    const esat_l = e_sat.scale(l_eff);
    const wv_cox = vsat_t.scale(w_eff * cox);

    // ========================================================================
    // Bulk Charge Effect (Abulk)
    // ========================================================================
    const t10_keta = v_bseff.scale(P.e_keta);
    const t11_keta = t10_keta.addC(1.0).maxC(0.1).pow(-1.0);
    const t13_keta = v_bseff.mul(t11_keta).scale(1.0 / (phi_s + P.e_ketas + 1.0e-30));
    const t14_keta = t13_keta.neg().addC(1.0).maxC(0.04).sqrt().pow(-1.0).minC(6.0);
    const t1_abulk = t14_keta.scale(0.5 * k1_eff / @sqrt(phi_s + P.e_ketas + 1.0e-30));

    const t9_abulk = @sqrt(xj) * x_dep.sqrt().val(); // used only for f64 t5 below
    _ = t9_abulk;
    const t9_abulk_S = x_dep.scale(xj).sqrt(); // sqrt(xj*x_dep)
    // t5_abulk = l_eff / (l_eff + 2*t9 + 1e-30)
    const t5_abulk = t9_abulk_S.scale(2.0).addC(l_eff + 1.0e-30).pow(-1.0).scale(l_eff);
    // t2_abulk = a0*t5 + b0/(w_eff+b1+1e-30)
    const t2_abulk = t5_abulk.scale(P.e_a0).addC(P.e_b0 / (w_eff + P.e_b1_p + 1.0e-30));
    const abulk0 = t1_abulk.mul(t2_abulk).addC(1.0);

    // t8_abulk = ags*a0*t5^3
    const t8_abulk = t5_abulk.mul(t5_abulk).mul(t5_abulk).scale(P.e_ags * P.e_a0);
    const abulk = abulk0.sub(t1_abulk.mul(t8_abulk).mul(vgsteff)).maxC(0.01);

    // ========================================================================
    // Source-Drain Resistance (Rds)
    // ========================================================================
    const rds0denom = contract.fmath.exp(P.e_wr * contract.fmath.log(@max(w_eff * 1.0e6, 1.0e-6)));
    // rdsw_t = e_rdsw + prt*temp_ratio_m1  (S)
    const rdsw_t = temp_ratio_m1.scale(P.m_prt).addC(P.e_rdsw);
    const rds0 = rdsw_t.scale(1.0 / (rds0denom + 1.0e-30));
    // rds = rds0 * (1 + prwg*vgsteff + prwb*(sqrt_phi_is - sqrt_phi_s))
    const rds_factor = vgsteff.scale(P.e_prwg).add(sqrt_phi_is.addC(-sqrt_phi_s).scale(P.e_prwb)).addC(1.0);
    const rds = rds0.mul(rds_factor);
    const rds_val = rds.val();

    // ========================================================================
    // Saturation Voltage (Vdsat)
    // ========================================================================
    const wvcox_rds = wv_cox.mul(rds);
    const aa = abulk.mul(wvcox_rds);
    // bb = -(vgst2vtm + abulk*esat_l*(1 + wvcox_rds))
    const bb = vgst2vtm.add(abulk.mul(esat_l).mul(wvcox_rds.addC(1.0))).neg();
    const cc = vgst2vtm.mul(esat_l);
    const disc = bb.mul(bb).sub(aa.mul(cc).scale(4.0)).maxC(1.0e-30);
    const vdsat_rds = bb.neg().sub(disc.sqrt()).div(aa.scale(2.0).addC(1.0e-30));
    // vdsat_no_rds = esat_l*vgst2vtm/(abulk*esat_l + vgst2vtm + 1e-30)
    const vdsat_no_rds = esat_l.mul(vgst2vtm).div(abulk.mul(esat_l).add(vgst2vtm).addC(1.0e-30));
    const vdsat = if (rds_val > 1.0e-20) vdsat_rds else vdsat_no_rds;

    // ========================================================================
    // Effective Drain-Source Voltage (Vdseff)
    // ========================================================================
    const t1_vdseff = vdsat.sub(v_ds).addC(-P.e_delta);
    const t2_vdseff = t1_vdseff.mul(t1_vdseff).add(vdsat.scale(4.0 * P.e_delta)).sqrt();
    var vdseff = vdsat.sub(t1_vdseff.add(t2_vdseff).scale(0.5));
    vdseff = vdseff.add(v_ds.sub(vdseff).minC(0.0));
    const delta_vds = v_ds.sub(vdseff);

    // ========================================================================
    // Channel Current (Ids)
    // ========================================================================
    const beta = mu_eff.scale(cox * w_eff / l_eff);
    // fgche1 = vgsteff*(1 - abulk*vdseff/(2*vgst2vtm))
    const fgche1 = vgsteff.mul(abulk.mul(vdseff).div(vgst2vtm.scale(2.0)).neg().addC(1.0));
    const fgche2 = vdseff.div(esat_l.addC(1.0e-30)).addC(1.0);
    const gche = beta.mul(fgche1).div(fgche2.addC(1.0e-30));
    const i_dl = gche.mul(vdseff).div(gche.mul(rds).addC(1.0 + 1.0e-30));

    // ========================================================================
    // Channel Length Modulation (VACLM)
    // ========================================================================
    const litl = @sqrt(@max(3.0 * xj * m_tox * eps_si / eps_ox, 1.0e-30));
    // vaclm branch matches original: only when e_pclm in (0, 1e10)
    const vaclm = if (P.e_pclm > 0.0 and P.e_pclm < 1.0e10) blk: {
        // (1/(pclm*litl*abulk + 1e-30)) * l_eff * (abulk + vgsteff/(esat_l+1e-30)) * (delta_vds + 1e-10)
        const inv = abulk.scale(P.e_pclm * litl).addC(1.0e-30).pow(-1.0);
        const term = abulk.add(vgsteff.div(esat_l.addC(1.0e-30)));
        break :blk inv.mul(term).mul(delta_vds.addC(1.0e-10)).scale(l_eff);
    } else S.con(1.0e30);

    // ========================================================================
    // DIBL Output Resistance (VADIBL)
    // ========================================================================
    const lt1_rout = factor1 * @sqrt(x_dep0);
    const drout_arg = P.e_drout * l_eff / (2.0 * lt1_rout + 1.0e-20);
    const exp_drout = contract.fmath.exp(@min(@max(-drout_arg, -80.0), 80.0));
    const theta_rout = P.e_pdiblc1 * (exp_drout + 2.0 * contract.fmath.exp(@min(@max(-2.0 * drout_arg, -80.0), 80.0))) + P.e_pdiblc2;

    const t8_va = abulk.mul(vdsat);
    // va_dibl_num = vgst2vtm - (vgst2vtm*t8_va/(vgst2vtm+t8_va+1e-30))
    const va_dibl_num = vgst2vtm.sub(vgst2vtm.mul(t8_va).div(vgst2vtm.add(t8_va).addC(1.0e-30)));
    const pdibl_body = v_bseff.scale(P.e_pdiblcb).addC(1.0).maxC(0.1).pow(-1.0);
    const vadibl = if (theta_rout > 0.0)
        va_dibl_num.scale(1.0 / (theta_rout + 1.0e-30)).mul(pdibl_body)
    else
        S.con(1.0e30);

    // ========================================================================
    // Vasat
    // ========================================================================
    const tmp4_va = abulk.mul(vdsat).div(vgst2vtm.scale(2.0).addC(1.0e-30)).neg().addC(1.0);
    const t9_va = wvcox_rds.mul(vgsteff);
    const t0_va = esat_l.add(vdsat).add(t9_va.mul(tmp4_va).scale(2.0));
    const lambda_a2 = @max(P.e_a2, 0.01);
    // t1_va = 2/lambda_a2 - 1 + wvcox_rds*abulk
    const t1_va = wvcox_rds.mul(abulk).addC(2.0 / lambda_a2 - 1.0);
    const vasat = t0_va.div(t1_va.addC(1.0e-30));

    // ========================================================================
    // Output Resistance -- Final Early Voltage
    // ========================================================================
    const pvag_factor = vgsteff.scale(P.e_pvag / (esat_l.val() + 1.0e-30)); // placeholder, recompute below
    _ = pvag_factor;
    const pvag_factor_S = vgsteff.mul(esat_l.addC(1.0e-30).pow(-1.0)).scale(P.e_pvag).addC(1.0);
    const va_clm_dibl = vaclm.mul(vadibl).div(vaclm.add(vadibl).addC(1.0e-30));
    const va_total = vasat.add(pvag_factor_S.mul(va_clm_dibl));

    // ========================================================================
    // Total Drain Current
    // ========================================================================
    const ids_pre_m = i_dl.mul(delta_vds.div(va_total.addC(1.0e-30)).addC(1.0));
    const ids = ids_pre_m.scale(inst_m);

    // ========================================================================
    // GIDL Current
    // ========================================================================
    const t0_gidl = 3.0 * m_tox;

    // Drain side
    const t1_gidl_d = v_ds.sub(v_gs).addC(-P.e_ngidl).scale(1.0 / (t0_gidl + 1.0e-30)).maxC(1.0e-20);
    const gidl_arg_d = t1_gidl_d.addC(1.0e-30).pow(-1.0).scale(-P.e_bgidl).maxC(-80.0);
    const i_gidl_raw = t1_gidl_d.mul(gidl_arg_d.exp()).scale(P.e_agidl * w_eff);
    const i_gidl = if (P.gidl_active) i_gidl_raw else S.con(0.0);

    // Source side (GISL)
    const t1_gisl = v_gs.neg().addC(-P.e_ngidl).scale(1.0 / (t0_gidl + 1.0e-30)).maxC(1.0e-20);
    const gisl_arg = t1_gisl.addC(1.0e-30).pow(-1.0).scale(-P.e_bgidl).maxC(-80.0);
    const i_gisl_raw = t1_gisl.mul(gisl_arg.exp()).scale(P.e_agidl * w_eff);
    const i_gisl = if (P.gidl_active) i_gisl_raw else S.con(0.0);

    // ========================================================================
    // Junction Diode Currents
    // ========================================================================
    const nVtm = vtm.scale(@max(P.e_ndiode, 0.01));

    // Diffusion current (Ibs1/Ibd1)
    const isd_coeff = w_eff * m_tsi * @max(P.e_isdif, 0.0);
    const i_bs1 = v_bs.div(nVtm).minC(80.0).exp().addC(-1.0).scale(isd_coeff);
    const i_bd1 = v_bd.div(nVtm).minC(80.0).exp().addC(-1.0).scale(isd_coeff);

    // Recombination current (Ibs2/Ibd2)
    const nrecf_vtm = 0.026 * @max(P.e_nrecf0, 0.01);
    const nrecr_vtm = 0.026 * @max(P.e_nrecr0, 0.01);
    const irec_coeff = w_eff * m_tsi * @max(P.e_isrec, 0.0);

    const t10_rec_bs = v_bs.scale(1.0 / nrecf_vtm).minC(80.0).exp();
    const t11_rec_bs = if (P.e_vrec0 > 0.0)
        // -exp(min(-v_bs/nrecr_vtm * vrec0/max(vrec0-v_bs,1e-3), 80))
        v_bs.scale(-1.0 / nrecr_vtm).mul(v_bs.neg().addC(P.e_vrec0).maxC(1.0e-3).pow(-1.0).scale(P.e_vrec0)).minC(80.0).exp().neg()
    else
        S.con(0.0);
    const i_bs2 = t10_rec_bs.add(t11_rec_bs).scale(irec_coeff);

    const t10_rec_bd = v_bd.scale(1.0 / nrecf_vtm).minC(80.0).exp();
    const t11_rec_bd = if (P.e_vrec0 > 0.0)
        v_bd.scale(-1.0 / nrecr_vtm).mul(v_bd.neg().addC(P.e_vrec0).maxC(1.0e-3).pow(-1.0).scale(P.e_vrec0)).minC(80.0).exp().neg()
    else
        S.con(0.0);
    const i_bd2 = t10_rec_bd.add(t11_rec_bd).scale(irec_coeff);

    // BJT current (Ibs3/Ibd3/Ic)  -- lratio/alpha are x-independent
    const lratio = contract.fmath.exp(P.e_nbjt * contract.fmath.log(@max(P.e_lbjt0 * (l_inv + 1.0 / m_ln), 1.0e-30)));
    const alpha_bjt = contract.fmath.exp(-l_eff * l_eff / (2.0 * m_ln * m_ln));
    const i_en = w_eff * m_tsi * @max(P.e_isbjt, 0.0) * lratio;
    const one_minus_alpha = 1.0 - alpha_bjt;

    const exp_bs_bjt = v_bs.div(nVtm).minC(80.0).exp();
    const exp_bd_bjt = v_bd.div(nVtm).minC(80.0).exp();
    const i_bs3 = exp_bs_bjt.addC(-1.0).scale(one_minus_alpha * i_en);
    const i_bd3 = exp_bd_bjt.addC(-1.0).scale(one_minus_alpha * i_en);

    // Collector current with Early voltage and high-level injection
    const va_bjt_eff = @max(P.e_vabjt + P.e_aely * l_eff, 0.1);
    const early_factor = v_ds.scale(1.0 / va_bjt_eff).addC(1.0);
    // hli_factor = 1/(1 + ahli*max(exp_bs-1,0))
    const hli_factor = exp_bs_bjt.addC(-1.0).maxC(0.0).scale(P.e_ahli).addC(1.0).pow(-1.0);
    const i_c_raw = exp_bs_bjt.sub(exp_bd_bjt).scale(alpha_bjt * i_en).mul(early_factor).mul(hli_factor);
    const i_c = if (alpha_bjt >= 0.01) i_c_raw else S.con(0.0);

    // Tunneling current (Ibs4/Ibd4)
    const tun_active = (P.e_istun > 0.0 and P.e_vtun0 > 0.0);
    const nVtm_tun = 0.026 * @max(P.e_ntun, 0.01);
    // t0_tun_bs = -v_bs/nVtm_tun * vtun0/max(vtun0-v_bs,1e-3)
    const t0_tun_bs = v_bs.scale(-1.0 / nVtm_tun).mul(v_bs.neg().addC(P.e_vtun0).maxC(1.0e-3).pow(-1.0).scale(P.e_vtun0));
    const i_bs4_raw = t0_tun_bs.minC(80.0).exp().neg().addC(1.0).scale(w_eff * m_tsi * P.e_istun);
    const i_bs4 = if (tun_active) i_bs4_raw else S.con(0.0);

    const t0_tun_bd = v_bd.scale(-1.0 / nVtm_tun).mul(v_bd.neg().addC(P.e_vtun0).maxC(1.0e-3).pow(-1.0).scale(P.e_vtun0));
    const i_bd4_raw = t0_tun_bd.minC(80.0).exp().neg().addC(1.0).scale(w_eff * m_tsi * P.e_istun);
    const i_bd4 = if (tun_active) i_bd4_raw else S.con(0.0);

    // Total junction currents with gmin
    const i_bs = i_bs1.add(i_bs2).add(i_bs3).add(i_bs4).add(v_bs.scale(gmin));
    const i_bd = i_bd1.add(i_bd2).add(i_bd3).add(i_bd4).add(v_bd.scale(gmin));

    // ========================================================================
    // Impact Ionization Current
    // ========================================================================
    const ii_active = (P.e_alpha0 > 0.0);

    const t1_sii = P.e_sii0 * P.e_esatii * l_eff / (1.0 + P.e_esatii * l_eff);
    // vgs_step = t1_sii*v_gst_raw*(1/(1+sii1*vgsteff+1e-30) + sii2)/(1+siid*v_ds+1e-30)
    const vgs_step_num = v_gst_raw.scale(t1_sii).mul(vgsteff.scale(P.e_sii1).addC(1.0 + 1.0e-30).pow(-1.0).addC(P.e_sii2));
    const vgs_step = vgs_step_num.div(v_ds.scale(P.e_siid).addC(1.0 + 1.0e-30));
    const vdsatii = vgs_step.addC(P.e_vdsatii0 - P.e_lii_p * l_inv);
    const v_diff = v_ds.sub(vdsatii);

    // t0_ii = max(beta2 + beta1*v_diff + beta0*v_diff^2, 1e-5)
    const t0_ii = v_diff.scale(P.e_beta1).add(v_diff.mul(v_diff).scale(P.e_beta0)).addC(P.e_beta2).maxC(1.0e-5);
    const ratio_arg = v_diff.div(t0_ii).maxC(-80.0).minC(80.0);
    const ratio_ii = ratio_arg.exp().scale(P.e_alpha0).minC(10.0);
    // i_ii_raw = ratio_ii * (ids + fbjtii*i_c*inst_m)
    const i_ii_raw = ratio_ii.mul(ids.add(i_c.scale(m_fbjtii * inst_m)));
    const i_ii = if (ii_active) i_ii_raw else S.con(0.0);

    // ========================================================================
    // Gate Current (Igb) -- Gate oxide tunneling model
    // ========================================================================
    const m_ntox = P.m_ntox;
    const m_ebg = P.m_ebg;
    const m_vevb = P.m_vevb;
    const m_voxh = P.m_voxh;
    const m_deltavox = P.m_deltavox;
    const m_toxref = P.m_toxref;

    const tox_ratio = contract.fmath.exp(m_ntox * contract.fmath.log(@max(m_tox / m_toxref, 1.0e-30)));

    // Vgb = Vgs - Vbs
    const v_gb = v_gs.sub(v_bs);

    // Inversion-side Vox (smooth clamp to voxh)
    const vox_inv_raw = v_gb.sub(vth);
    const t_vox_inv = vox_inv_raw.addC(-m_voxh + m_deltavox);
    const vox_inv = t_vox_inv.add(t_vox_inv.mul(t_vox_inv).addC(4.0 * m_deltavox * m_voxh).sqrt()).scale(-0.5).addC(m_voxh + m_deltavox);

    // Vaux for valence-band tunneling (inversion side)
    const vaux_evb = v_gb.sub(vth).scale(1.0 / m_vevb).minC(80.0).exp();
    const vaux_inv = vaux_evb.addC(1.0).log().scale(m_vevb);

    // Inversion-side tunneling current
    const vox_eff_inv = vox_inv.scale(P.m_alphagb1).addC(P.m_betagb1).maxC(1.0e-20);
    const igb_inv_raw = vaux_inv.mul(vox_eff_inv).mul(vox_eff_inv.addC(1.0e-30).pow(-1.0).scale(-m_ebg).minC(80.0).exp()).scale(w_eff * l_eff * P.m_vgb1 * tox_ratio);

    // Accumulation-side Vox (smooth clamp)
    const vox_acc_raw = v_gb.neg().addC(-phi_s);
    const t_vox_acc = vox_acc_raw.addC(-m_voxh + m_deltavox);
    const vox_acc = t_vox_acc.add(t_vox_acc.mul(t_vox_acc).addC(4.0 * m_deltavox * m_voxh).sqrt()).scale(-0.5).addC(m_voxh + m_deltavox);

    // Vaux for conduction-band electron tunneling (accumulation side)
    const vaux_ecb = v_gb.neg().addC(-phi_s).scale(1.0 / P.m_vecb).minC(80.0).exp();
    const vaux_acc = vaux_ecb.addC(1.0).log().scale(P.m_vecb);

    // Accumulation-side tunneling current
    const vox_eff_acc = vox_acc.scale(P.m_alphagb2).addC(P.m_betagb2).maxC(1.0e-20);
    const igb_acc_raw = vaux_acc.mul(vox_eff_acc).mul(vox_eff_acc.addC(1.0e-30).pow(-1.0).scale(-m_ebg).minC(80.0).exp()).scale(w_eff * l_eff * P.m_vgb2 * tox_ratio);

    const i_gb = if (P.igmod_enabled) igb_inv_raw.add(igb_acc_raw).scale(inst_m) else S.con(0.0);

    // ========================================================================
    // Self-Heating (Thermal Node)
    // ========================================================================
    const p_diss = ids.mul(v_ds).scale(1.0 / inst_m); // per-instance power
    const i_temp = if (P.sh_enabled) delta_t.scale(1.0 / P.m_rth0).sub(p_diss) else delta_t.scale(P.GSHORT);

    // ========================================================================
    // KCL Node Assembly
    // ========================================================================
    const gmin_gs = v_G.sub(v_S).scale(gmin);
    const gmin_es = v_E.sub(v_S).scale(gmin);
    const gmin_eb = v_E.sub(v_B).scale(gmin);
    const gmin_dp_sp = v_DP.sub(v_SP).scale(gmin);
    const gmin_b_sp = v_B.sub(v_SP).scale(gmin);
    const gmin_p_s = v_P.sub(v_S).scale(gmin);

    // Mode-signed channel current
    const ids_mode = ids.mul(mode).scale(type_f);
    const i_c_mode = i_c.scale(type_f);
    const i_bd_mode = i_bd.scale(type_f);
    const i_bs_mode = i_bs.scale(type_f);
    const i_ii_mode = i_ii.scale(type_f);
    const i_gidl_mode = i_gidl.scale(type_f);
    const i_gisl_mode = i_gisl.scale(type_f);

    var out: [n_u]S = undefined;

    // I_D = I_{D->DP}
    out[d] = i_d_dp;

    // I_G = I_gb + gmin*(V_G - V_S)
    out[g] = i_gb.add(gmin_gs);

    // I_S = I_{S->SP} - gmin*(V_G - V_S) - gmin*(V_E - V_S) - gmin*(V_P - V_S)
    out[s] = i_s_sp.sub(gmin_gs).sub(gmin_es).sub(gmin_p_s);

    // I_E = gmin*(V_E - V_B) + gmin*(V_E - V_S)
    out[e] = gmin_eb.add(gmin_es);

    // I_DP = -I_{D->DP} + Ids*mode + Ic - Ibd - Iii + Igidl + gmin*(V_DP - V_SP)
    out[dp] = i_d_dp.neg().add(ids_mode).add(i_c_mode).sub(i_bd_mode).sub(i_ii_mode).add(i_gidl_mode).add(gmin_dp_sp);

    // I_SP = -I_{S->SP} - Ids*mode - Ic - Ibs + Igisl - gmin*(V_DP - V_SP) - gmin*(V_B - V_SP)
    out[sp] = i_s_sp.neg().sub(ids_mode).sub(i_c_mode).sub(i_bs_mode).add(i_gisl_mode).sub(gmin_dp_sp).sub(gmin_b_sp);

    // I_B = Ibs + Ibd + Ibp + Iii - Igidl - Igisl - Igb + gmin*(V_B - V_SP) - gmin*(V_E - V_B)
    out[b] = i_bs_mode.add(i_bd_mode).add(i_bp).add(i_ii_mode).sub(i_gidl_mode).sub(i_gisl_mode).sub(i_gb).add(gmin_b_sp).sub(gmin_eb);

    // I_TEMP
    out[tmp] = i_temp;

    // I_P = -Ibp + gmin*(V_P - V_S)
    out[p] = i_bp.neg().add(gmin_p_s);

    return out;
}

// ============================================================================
// Charge Function (value-form)
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
    const e_idx = @intFromEnum(U.substrate);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const b = @intFromEnum(U.body);
    const tmp = @intFromEnum(U.temp);
    const p_idx = @intFromEnum(U.body_contact);

    // --- Physical constants ---
    const eps_si: f64 = 1.03594e-10;
    const eps_ox: f64 = 3.453133e-11;
    const q_e: f64 = 1.60219e-19;
    const kb_q: f64 = 8.617087e-5;
    const ni: f64 = 1.45e10;

    // --- Cast model parameters (x-independent) ---
    const type_f: f64 = @floatFromInt(model.type_);
    const m_tox: f64 = if (model.toxe > 0.0) @as(f64, model.toxe) else @as(f64, model.tox);
    const m_tbox: f64 = @as(f64, model.tbox);
    const m_tsi: f64 = @as(f64, model.tsi);
    const m_tnom: f64 = @as(f64, model.tnom) + 273.15; // card TNOM is Celsius
    const m_nch: f64 = @as(f64, model.nch);
    const m_nsub: f64 = @as(f64, model.nsub);
    const m_lint: f64 = @as(f64, model.lint);
    const m_wint: f64 = @as(f64, model.wint);
    const m_cth0: f64 = @as(f64, model.cth0);
    const m_cgso: f64 = @as(f64, model.cgso);
    const m_cgdo: f64 = @as(f64, model.cgdo);
    const m_cjswg: f64 = @as(f64, model.cjswg);
    const m_pbswg: f64 = @as(f64, model.pbswg);
    const m_mjswg: f64 = @as(f64, model.mjswg);
    const m_tt: f64 = @as(f64, model.tt);
    const m_ndiode: f64 = @as(f64, model.ndiode);
    const m_isdif: f64 = @as(f64, model.isdif);
    const m_kb1: f64 = @as(f64, model.kb1);
    const m_fbody: f64 = @as(f64, model.fbody);

    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_m: f64 = @as(f64, instance.m);

    // Effective geometry
    const l_eff = @max(inst_l - 2.0 * m_lint, 1.0e-9);
    const w_eff = @max(inst_w - 2.0 * m_wint, 1.0e-9);
    const l_inv = 1.0 / l_eff;
    const w_inv = 1.0 / w_eff;

    // Oxide capacitance
    const cox = eps_ox / m_tox;

    // Surface potential
    const phi_s_raw = 2.0 * kb_q * m_tnom * contract.fmath.log(@max(m_nch / ni, 1.0));
    const phi_s = if (phi_s_raw >= 0.1) phi_s_raw else 0.6;
    const sqrt_phi_s = @sqrt(phi_s);

    // Depletion width
    const x_dep0 = @sqrt(2.0 * eps_si / (q_e * m_nch * 1.0e6)) * sqrt_phi_s;

    // xj
    const m_xj_raw: f64 = @as(f64, model.xj);
    const xj_is_nan = m_xj_raw != m_xj_raw;
    const xj = if (xj_is_nan) l_eff else m_xj_raw;

    // L/W/P effective params (x-independent)
    const e_vth0 = lwpParam(@as(f64, model.vth0), @as(f64, model.lvth0), @as(f64, model.wvth0), @as(f64, model.pvth0), l_inv, w_inv);
    const e_k2 = lwpParam(@as(f64, model.k2), @as(f64, model.lk2), @as(f64, model.wk2), @as(f64, model.pk2), l_inv, w_inv);
    const e_keta = lwpParam(@as(f64, model.keta), @as(f64, model.lketa), @as(f64, model.wketa), @as(f64, model.pketa), l_inv, w_inv);
    const e_cdsc = lwpParam(@as(f64, model.cdsc), @as(f64, model.lcdsc), @as(f64, model.wcdsc), @as(f64, model.pcdsc), l_inv, w_inv);
    const e_cdscd = lwpParam(@as(f64, model.cdscd), @as(f64, model.lcdscd), @as(f64, model.wcdscd), @as(f64, model.pcdscd), l_inv, w_inv);
    const e_cdscb = lwpParam(@as(f64, model.cdscb), @as(f64, model.lcdscb), @as(f64, model.wcdscb), @as(f64, model.pcdscb), l_inv, w_inv);
    const e_cit = lwpParam(@as(f64, model.cit), @as(f64, model.lcit), @as(f64, model.wcit), @as(f64, model.pcit), l_inv, w_inv);
    const e_w0 = lwpParam(@as(f64, model.w0), @as(f64, model.lw0), @as(f64, model.ww0), @as(f64, model.pw0), l_inv, w_inv);
    const e_k3 = lwpParam(@as(f64, model.k3), @as(f64, model.lk3), @as(f64, model.wk3), @as(f64, model.pk3), l_inv, w_inv);
    const e_k3b = lwpParam(@as(f64, model.k3b), @as(f64, model.lk3b), @as(f64, model.wk3b), @as(f64, model.pk3b), l_inv, w_inv);
    const e_eta0 = lwpParam(@as(f64, model.eta0), @as(f64, model.leta0), @as(f64, model.weta0), @as(f64, model.peta0), l_inv, w_inv);
    const e_etab = lwpParam(@as(f64, model.etab), @as(f64, model.letab), @as(f64, model.wetab), @as(f64, model.petab), l_inv, w_inv);
    const e_dsub = lwpParam(@as(f64, model.dsub), @as(f64, model.ldsub), @as(f64, model.wdsub), @as(f64, model.pdsub), l_inv, w_inv);

    const k1_eff = blk: {
        const e_k1 = lwpParam(@as(f64, model.k1), @as(f64, model.lk1), @as(f64, model.wk1), @as(f64, model.pk1), l_inv, w_inv);
        const e_k1w1 = lwpParam(@as(f64, model.k1w1), @as(f64, model.lk1w1), @as(f64, model.wk1w1), @as(f64, model.pk1w1), l_inv, w_inv);
        const e_k1w2 = lwpParam(@as(f64, model.k1w2), @as(f64, model.lk1w2), @as(f64, model.wk1w2), @as(f64, model.pk1w2), l_inv, w_inv);
        const k1_denom = @max(w_eff + e_k1w2, 1.0e-8);
        break :blk e_k1 * (1.0 + e_k1w1 / k1_denom);
    };

    // x-independent Vth pieces
    const factor1 = @sqrt(eps_si / cox);
    const v_bi = kb_q * m_tnom * contract.fmath.log(@max(1.0e20 * m_nch / (ni * ni), 1.0));
    const v0 = v_bi - phi_s;
    const tmp2 = m_tox * phi_s / (w_eff + e_w0);
    const t1_dibl = @sqrt((eps_si / eps_ox) * m_tox * x_dep0);
    const dsub_half = e_dsub * l_eff / (2.0 * t1_dibl + 1.0e-20);
    const exp_dsub = contract.fmath.exp(@min(@max(-dsub_half, -80.0), 80.0));
    const theta_0_vb0 = exp_dsub * (1.0 + 2.0 * exp_dsub);

    const m_dvt2: f64 = @as(f64, model.dvt2);
    const m_dvt1: f64 = @as(f64, model.dvt1);
    const m_dvt0: f64 = @as(f64, model.dvt0);

    const cdep0 = @sqrt(q_e * eps_si * m_nch * 1.0e6);
    const c_box = eps_ox / m_tbox;
    const vfbb = if (m_nsub > 0.0)
        -kb_q * m_tnom * contract.fmath.log(@max(m_nch / m_nsub, 1.0e-30))
    else
        -kb_q * m_tnom * contract.fmath.log(@max(-m_nch * m_nsub / (ni * ni), 1.0e-30));

    const jcap_active = (m_cjswg > 0.0 and m_pbswg > 0.0 and (1.0 - m_mjswg) > 0.01);
    const mjswg_exp = 1.0 - m_mjswg;
    const cj_coeff = m_cjswg * w_eff * m_pbswg / mjswg_exp;

    const ndiode_eff = @max(m_ndiode, 0.01);
    const isd_coeff = w_eff * m_tsi * @max(m_isdif, 0.0);

    // ========================================================================
    // Terminal voltages (x reads -> S downstream)
    // ========================================================================
    const v_G = x[g];
    const v_SP = x[sp];
    const v_DP = x[dp];
    const v_B = x[b];
    const v_E = x[e_idx];
    const v_S = x[s];
    const v_TEMP = x[tmp];

    const v_gs_raw = v_G.sub(v_SP).scale(type_f);
    const v_ds_raw = v_DP.sub(v_SP).scale(type_f);
    const v_bs_raw = v_B.sub(v_SP).scale(type_f);

    // Source-drain reversal
    const vds_smooth = v_ds_raw.mul(v_ds_raw).addC(1.0e-30).sqrt();
    const mode = v_ds_raw.div(vds_smooth);
    const w_fwd = mode.addC(1.0).scale(0.5);
    const w_rev = mode.neg().addC(1.0).scale(0.5);

    const v_ds = vds_smooth;
    const v_gs = w_fwd.mul(v_gs_raw).add(w_rev.mul(v_gs_raw.sub(v_ds_raw)));
    const v_bs = w_fwd.mul(v_bs_raw).add(w_rev.mul(v_bs_raw.sub(v_ds_raw)));
    const v_bd = v_bs.sub(v_ds);

    const delta_t = v_TEMP;
    const vtm = delta_t.addC(m_tnom).scale(kb_q);

    // ========================================================================
    // Vbseff clamping (same as DC)
    // ========================================================================
    const t0_s1 = v_bs.addC(4.999);
    const t1_s1 = t0_s1.mul(t0_s1).addC(0.02).sqrt();
    const vbs_low = t0_s1.add(t1_s1).scale(0.5).addC(-5.0);
    const t0_s2 = vbs_low.neg().addC(1.5 - 0.002);
    const t3_s2 = t0_s2.mul(t0_s2).addC(0.012).sqrt();
    const vbsh = t0_s2.add(t3_s2).scale(-0.5).addC(1.5);
    const t1_s3 = vbsh.neg().addC(0.95 * phi_s - 0.002);
    const t2_s3 = t1_s3.mul(t1_s3).addC(0.0076 * phi_s).sqrt();
    const v_bseff = t1_s3.add(t2_s3).scale(-0.5).addC(0.95 * phi_s);

    const phi_is = v_bseff.neg().addC(phi_s);
    const sqrt_phi_is = phi_is.maxC(1.0e-30).sqrt();
    const x_dep = sqrt_phi_is.scale(x_dep0 / sqrt_phi_s);

    // ========================================================================
    // Vth for CV
    // ========================================================================
    const lt1_arg = v_bseff.scale(m_dvt2).addC(1.0).maxC(0.2);
    const lt1 = x_dep.sqrt().scale(factor1).mul(lt1_arg).addC(1.0e-20);
    const dvt1_half = lt1.pow(-1.0).scale(m_dvt1 * l_eff / 2.0);
    const exp_dvt1 = dvt1_half.neg().maxC(-80.0).minC(80.0).exp();
    const theta_0 = exp_dvt1.mul(exp_dvt1.scale(2.0).addC(1.0));
    const dvth_sce = theta_0.scale(m_dvt0 * v0);

    const eta_eff = v_bseff.scale(e_etab).addC(e_eta0).maxC(1.0e-4);
    const dibl_sft = eta_eff.mul(v_ds).scale(theta_0_vb0);

    const vth_cv = sqrt_phi_is.addC(-sqrt_phi_s).scale(k1_eff)
        .sub(v_bseff.scale(e_k2))
        .sub(dvth_sce)
        .add(v_bseff.scale(e_k3b).addC(e_k3).scale(tmp2))
        .sub(dibl_sft)
        .addC(e_vth0);

    // ========================================================================
    // CV Subthreshold Swing Factor
    // ========================================================================
    const cdep = sqrt_phi_is.addC(1.0e-30).pow(-1.0).scale(cdep0);
    // n_cv = max(1 + cdep/cox + cdsc + cdscd*v_ds + cdscb*v_bseff + cit/cox, 1)
    const n_cv = cdep.scale(1.0 / cox).add(v_ds.scale(e_cdscd)).add(v_bseff.scale(e_cdscb)).addC(1.0 + e_cdsc + e_cit / cox).maxC(1.0);

    // ========================================================================
    // Vgsteff for CV
    // ========================================================================
    const v_gst_cv = v_gs.sub(vth_cv);
    const ncv_vtm = n_cv.mul(vtm);
    const exp_arg_cv = v_gst_cv.div(ncv_vtm).minC(80.0);
    const vgsteff_cv = exp_arg_cv.exp().addC(1.0).log().mul(ncv_vtm);

    // ========================================================================
    // Abulk for CV (simplified)
    // ========================================================================
    const keta_denom = v_bseff.scale(e_keta).addC(1.0).maxC(0.1);
    // abulk_cv_num = 1 + 0.5*k1_eff/(sqrt_phi_is+1e-30)*(1 - xj/(x_dep+xj+1e-30))
    const abulk_cv_num = sqrt_phi_is.addC(1.0e-30).pow(-1.0).scale(0.5 * k1_eff)
        .mul(x_dep.addC(xj + 1.0e-30).pow(-1.0).scale(-xj).addC(1.0))
        .addC(1.0);
    const abulk_cv = abulk_cv_num.div(keta_denom).maxC(0.1);

    // ========================================================================
    // VdsatCV and VdseffCV
    // ========================================================================
    const vdsat_cv = vgsteff_cv.div(abulk_cv.addC(1.0e-30));
    const t_vdseff_cv = vdsat_cv.sub(v_ds).addC(-0.02);
    const vdseff_cv = vdsat_cv.sub(t_vdseff_cv.add(t_vdseff_cv.mul(t_vdseff_cv).add(vdsat_cv.scale(0.08)).sqrt()).scale(0.5));

    // ========================================================================
    // Flat-band voltage for CV (x-independent)
    // ========================================================================
    const vfb_cv = e_vth0 - phi_s - k1_eff * sqrt_phi_s;

    // ========================================================================
    // Vfbeff (smooth clamp)
    // ========================================================================
    // t_vfb = vfb_cv - v_gs + v_bseff - 0.08
    const t_vfb = v_gs.neg().add(v_bseff).addC(vfb_cv - 0.08);
    const vfbeff = t_vfb.add(t_vfb.mul(t_vfb).addC(0.32 * @abs(vfb_cv)).sqrt()).scale(-0.5).addC(vfb_cv);

    // ========================================================================
    // Accumulation Charge
    // ========================================================================
    const q_ac0 = vfbeff.addC(-vfb_cv).scale(m_fbody * cox * w_eff * l_eff);

    // ========================================================================
    // Depletion/Subthreshold Charge
    // ========================================================================
    // t3_sub = v_gs - vfbeff - v_bseff - vgsteff_cv
    const t3_sub = v_gs.sub(vfbeff).sub(v_bseff).sub(vgsteff_cv);
    const k1_half = k1_eff * 0.5;
    // q_sub0 = fbody*cox*w*l*k1_eff*(sqrt(k1_half^2 + max(t3_sub,0)) - k1_half)
    const q_sub0 = t3_sub.maxC(0.0).addC(k1_half * k1_half).sqrt().addC(-k1_half).scale(m_fbody * cox * w_eff * l_eff * k1_eff);

    // ========================================================================
    // Inversion Charge
    // ========================================================================
    const t0_inv = abulk_cv.mul(vdseff_cv);
    // t1_inv = 12*(vgsteff_cv - t0_inv*0.5 + 1e-20)
    const t1_inv = vgsteff_cv.sub(t0_inv.scale(0.5)).addC(1.0e-20).scale(12.0);
    const t2_inv = vdseff_cv.div(t1_inv.addC(1.0e-30));
    const t3_inv = t0_inv.mul(t2_inv);
    const q_inv = vgsteff_cv.sub(vdseff_cv.scale(0.5)).add(t3_inv).scale(cox * w_eff * l_eff);

    // ========================================================================
    // Bulk Charge
    // ========================================================================
    // q_bulk = fbody*cox*w*l*(1-abulk_cv)*(vdseff_cv*0.5 - t3_inv)
    const q_bulk = abulk_cv.neg().addC(1.0).mul(vdseff_cv.scale(0.5).sub(t3_inv)).scale(m_fbody * cox * w_eff * l_eff);

    // ========================================================================
    // Source Charge (50/50 partitioning)
    // ========================================================================
    const q_src = q_inv.add(q_bulk).scale(-0.5);

    // ========================================================================
    // Drain Charge
    // ========================================================================
    const q_gate_total = q_inv.add(q_ac0).add(q_sub0);
    const q_body_total = q_bulk.sub(q_ac0).sub(q_sub0);
    const q_drn = q_gate_total.add(q_src).add(q_body_total).neg();

    // ========================================================================
    // Overlap Capacitance Charges
    // ========================================================================
    const v_gs_ov = v_G.sub(v_SP).scale(type_f);
    const v_gd_ov = v_G.sub(v_DP).scale(type_f);
    const q_gs_ov = v_gs_ov.scale(m_cgso * w_eff);
    const q_gd_ov = v_gd_ov.scale(m_cgdo * w_eff);

    // ========================================================================
    // Backgate (Substrate) Charge
    // ========================================================================
    const c_box_wl = m_kb1 * m_fbody * c_box * w_eff * l_eff;
    const v_es = v_E.sub(v_S).scale(type_f);
    // q_e1 = c_box_wl*(v_es - vfbb - v_bs)
    const q_e1 = v_es.addC(-vfbb).sub(v_bs).scale(c_box_wl);

    // ========================================================================
    // Junction Depletion Charges
    // ========================================================================
    // arg_js = max(1 - v_bs/pbswg, 0.01); q_js = cj_coeff*(1 - exp(mjswg_exp*log(arg_js)))
    const arg_js = v_bs.scale(-1.0 / m_pbswg).addC(1.0).maxC(0.01);
    const q_js_raw = arg_js.log().scale(mjswg_exp).exp().neg().addC(1.0).scale(cj_coeff);
    const q_js = if (jcap_active) q_js_raw else S.con(0.0);

    const arg_jd = v_bd.scale(-1.0 / m_pbswg).addC(1.0).maxC(0.01);
    const q_jd_raw = arg_jd.log().scale(mjswg_exp).exp().neg().addC(1.0).scale(cj_coeff);
    const q_jd = if (jcap_active) q_jd_raw else S.con(0.0);

    // ========================================================================
    // Transit Time (Diffusion) Charges
    // ========================================================================
    const nVtm = vtm.scale(ndiode_eff);
    const q_tt_s = v_bs.div(nVtm).minC(80.0).exp().addC(-1.0).scale(m_tt * isd_coeff);
    const q_tt_d = v_bd.div(nVtm).minC(80.0).exp().addC(-1.0).scale(m_tt * isd_coeff);

    // ========================================================================
    // Thermal Capacitance Charge
    // ========================================================================
    const q_th = delta_t.scale(m_cth0);

    // ========================================================================
    // Charge Node Assembly (scaled by M)
    // ========================================================================
    const m_scale = inst_m;

    var out: [n_u]S = undefined;

    // Q_D = 0
    out[d] = S.con(0.0);

    // Q_G = Q_inv + Q_ac0 + Q_sub0 + Q_gs_ov + Q_gd_ov
    out[g] = q_gate_total.add(q_gs_ov).add(q_gd_ov).scale(m_scale);

    // Q_S = 0
    out[s] = S.con(0.0);

    // Q_E = Q_e1
    out[e_idx] = q_e1.scale(m_scale);

    // Q_DP = Q_drn - Q_gd_ov + Q_jd + Q_tt_d
    out[dp] = q_drn.sub(q_gd_ov).add(q_jd).add(q_tt_d).scale(m_scale);

    // Q_SP = Q_src - Q_gs_ov + Q_js + Q_tt_s
    out[sp] = q_src.sub(q_gs_ov).add(q_js).add(q_tt_s).scale(m_scale);

    // Q_B = Q_bulk - Q_ac0 - Q_sub0
    out[b] = q_body_total.scale(m_scale);

    // Q_TEMP = Cth0 * delta_T
    out[tmp] = q_th.scale(m_scale);

    // Q_P = 0
    out[p_idx] = S.con(0.0);

    return out;
}

// ============================================================================
// Voltage Limiting (limit function)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;

    const type_f: f64 = @floatFromInt(model.type_);

    const g = @intFromEnum(U.gate);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const b = @intFromEnum(U.body);
    const tmp = @intFromEnum(U.temp);

    // ========================================================================
    // Gate voltage limiting (DEVfetlim) -- applied to Vgs
    // ========================================================================
    const vgs_new = (x_new[g] - x_new[sp]) * type_f;
    const vgs_old = (x_old[g] - x_old[sp]) * type_f;
    const vto: f64 = 0.5;

    const vgs_lim = fetlim(vgs_new, vgs_old, vto);
    const vgs_corr = (vgs_lim - vgs_new) * type_f;
    result[g] = result[g] + vgs_corr;

    // ========================================================================
    // Drain-source limiting (DEVlimvds) -- applied to Vds
    // ========================================================================
    const vds_new = (x_new[dp] - x_new[sp]) * type_f;
    const vds_old = (x_old[dp] - x_old[sp]) * type_f;

    const vds_lim = limvds(vds_new, vds_old);
    const vds_corr = (vds_lim - vds_new) * type_f;
    result[dp] = result[dp] + vds_corr;

    // ========================================================================
    // PN junction limiting (DEVpnjlim) -- Vbs
    // ========================================================================
    const vbs_new = (x_new[b] - x_new[sp]) * type_f;
    const vbs_old = (x_old[b] - x_old[sp]) * type_f;
    const vbs_lim = pnjlim(vbs_new, vbs_old);
    const vbs_corr = (vbs_lim - vbs_new) * type_f;
    result[b] = result[b] + vbs_corr;

    // ========================================================================
    // PN junction limiting -- Vbd
    // ========================================================================
    const vbd_new = (x_new[b] - x_new[dp]) * type_f;
    const vbd_old = (x_old[b] - x_old[dp]) * type_f;
    const vbd_lim = pnjlim(vbd_new, vbd_old);
    const vbd_corr = (vbd_lim - vbd_new) * type_f;
    // Adjust body node for Vbd limiting as well
    result[b] = result[b] + vbd_corr;

    // ========================================================================
    // Temperature limiting -- |delta_T_new - delta_T_old| <= 5 K
    // ========================================================================
    const dt_diff = result[tmp] - x_old[tmp];
    const dt_clamped = @max(@min(dt_diff, 5.0), -5.0);
    result[tmp] = x_old[tmp] + dt_clamped;

    return result;
}

// --- DEVfetlim ---
inline fn fetlim(vnew: f64, vold: f64, vto: f64) f64 {
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;

    // Above threshold and rising
    const above_thresh = (vnew > vold and vold >= vto);
    const delta_above = vnew - vold;
    const lim_above = vold + @min(delta_above, vtsthi);

    // Below threshold
    const below_thresh = (vnew > vold and vold < vto);
    const lim_below_rise = if (vnew > vtox) vtox else vold + @min(vnew - vold, vtstlo);

    // Falling
    const falling = (vnew <= vold);
    const delta_fall = vold - vnew;
    const lim_fall = vold - @min(delta_fall, vtstlo);

    const result = if (above_thresh) lim_above else if (below_thresh) lim_below_rise else if (falling) lim_fall else vnew;
    return result;
}

// --- DEVlimvds ---
inline fn limvds(vnew: f64, vold: f64) f64 {
    const rising_high = (vold >= 3.5 and vnew > vold);
    const limit_rise = vold + @min(vnew - vold, (vold - 3.5) * 0.5 + 4.0);
    const limit_other = vold + @max(@min(vnew - vold, 4.0), -4.0);
    return if (rising_high) limit_rise else limit_other;
}

// --- DEVpnjlim ---
inline fn pnjlim(vnew: f64, vold: f64) f64 {
    const vt: f64 = 0.026;
    const vcrit: f64 = 0.6;

    const needs_lim = (vnew > vcrit and @abs(vnew - vold) > 2.0 * vt);
    const arg = (vnew - vold) / vt;

    // vold > 0 path
    const lim_pos_rise = vold + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
    const lim_pos_fall = vold - vt * (2.0 + contract.fmath.log(@max(2.0 - arg, 1.0e-30)));
    const lim_pos = if (arg > 0.0) lim_pos_rise else lim_pos_fall;

    // vold <= 0 path
    const lim_neg = vt * contract.fmath.log(@max(vnew / vt, 1.0e-30));

    const lim_val = if (vold > 0.0) lim_pos else lim_neg;

    return if (needs_lim) lim_val else vnew;
}

// ============================================================================
// Parameter Stepping (attempt)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    // Scale junction saturation currents by adding gmin*(1-lambda)
    // At lambda=0 (start): maximum gmin added for convergence
    // At lambda=1 (final): no gmin added, original parameters
    var m = model;
    const gmin_scale: f32 = @floatCast(1.0e-12 * (1.0 - lambda));

    // Add gmin to junction saturation currents
    m.isbjt = model.isbjt + gmin_scale;
    m.isdif = model.isdif + gmin_scale;
    m.isrec = model.isrec + gmin_scale;
    m.istun = model.istun + gmin_scale;

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

test "b3soipd: resistance branch currents (RD/RS) with rsh set" {
    // With rsh>0, g_d_ext = w*m/(rsh*nrd). Defaults: w=1e-6, m=1, nrd=1, rsh=10.
    //   g_d_ext = 1e-6/(10*1) = 1e-7 S.
    // Drain node current I_D = (v_D - v_DP)*g_d_ext.
    // Set v_D=1, v_DP=0 -> I_D = 1e-7. All other nodes zero-biased.
    var model: Model = .{ .rsh = 10.0 };
    const inst: Instance = .{};

    var x = [_]f64{0} ** n_u;
    x[@intFromEnum(U.drain)] = 1.0;
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // I_D = 1e-7
    try testing.expectApproxEqAbs(@as(f64, 1e-7), out[@intFromEnum(U.drain)], 1e-15);
    // I_DP has -I_{D->DP} term = -1e-7 plus channel/junction terms; at these
    // small biases channel current is negligible, so verify the branch shows up
    // in the DP row with the expected sign to at least 1e-7 magnitude:
    try testing.expect(out[@intFromEnum(U.drain_prime)] < 0.0);
}

test "b3soipd: forward-bias body-source junction diffusion residual" {
    // Enable a simple diffusion diode: isdif>0, rsh=0 (GSHORT branches), others default.
    // Ibs1 = w_eff*tsi*isdif*(exp(v_bs/(ndiode*vtm)) - 1), ndiode=1.
    //   w_eff = w - 2*wint = 1e-6 (wint=0)
    //   tsi   = 1e-7
    //   isdif = 1e-6  -> isd_coeff = 1e-6 * 1e-7 * 1e-6 = 1e-19
    //   vtm   = kb_q * (tnom + delta_T); delta_T = v_TEMP = 0 -> vtm = 8.617087e-5*300.15
    //          = 0.025864... ; nVtm = 1*vtm.
    // Put a body-source bias by raising v_B with v_SP=0.  type_=1.
    //   v_bs_raw = (v_B - v_SP) = 0.5 (with v_ds=0 so no reversal effect on v_bs).
    // Ibs1 = 1e-19*(exp(0.5/0.0258635) - 1). exp(19.3327) ~ 2.4885e8.
    //   -> Ibs1 ~ 1e-19 * 2.4885e8 = 2.4885e-11.
    // The body node (I_B) collects +Ibs (times type_f=1) among other terms;
    // recombination/BJT default isrec=1e-5, isbjt=1e-6 also contribute, so we
    // check the SOURCE-PRIME node sign (it drains -Ibs) is negative and the
    // full residual is finite.  Focus assertion: I_B is strongly positive.
    var model: Model = .{ .isdif = 1.0e-6, .isrec = 0.0, .isbjt = 0.0 };
    const inst: Instance = .{};

    var x = [_]f64{0} ** n_u;
    x[@intFromEnum(U.body)] = 0.5;
    const out = contract.evalValues(Self, x, &model, &inst, 0);

    // Hand value for Ibs1 (only diffusion enabled, gmin adds 1e-12*0.5=5e-13):
    // I_B ~ Ibs1 + gmin*v_bs ~ 2.4885e-11 + 5e-13.  Also i_bp = (v_B - v_P)*g_body,
    // g_body = GSHORT = 1e3 (rbody=0) -> i_bp = 0.5*1e3 = 500 dominates I_B!
    // So I_B is dominated by the body-contact resistor.  Check it:
    //   I_B contains + i_bp = 500.0.  I_P contains -i_bp = -500.0.
    try testing.expectApproxEqAbs(@as(f64, 500.0), out[@intFromEnum(U.body_contact)] * -1.0, 1e-6);
    // And source-prime should be negative (drains junction + gmin currents).
    try testing.expect(out[@intFromEnum(U.source_prime)] < 0.0);
}

test "b3soipd: charge - gate overlap charge dominates at zero body bias" {
    // With capmod defaults, at zero intrinsic bias the overlap charges are
    // linear: q_gs_ov = cgso*w_eff*(v_G - v_SP), q_gd_ov = cgdo*w_eff*(v_G - v_DP).
    // Set v_G = 1, all else 0. w_eff = 1e-6, cgso = cgdo = 2.07188e-10.
    //   q_gs_ov = 2.07188e-10 * 1e-6 * 1 = 2.07188e-16
    //   q_gd_ov = 2.07188e-10 * 1e-6 * 1 = 2.07188e-16
    // Q_G = (q_gate_total + q_gs_ov + q_gd_ov) * m.  q_gate_total involves the
    // inversion/accumulation charge; with v_G=1 and vth ~ 0.7 there is some
    // channel charge, so we assert Q_G is positive and at least the overlap sum.
    var model: Model = .{};
    const inst: Instance = .{};

    var x = [_]f64{0} ** n_u;
    x[@intFromEnum(U.gate)] = 1.0;
    const out = contract.qValues(Self, x, &model, &inst, 0);

    // Overlap alone contributes 2*2.07188e-16 = 4.14376e-16 to Q_G.
    try testing.expect(out[@intFromEnum(U.gate)] >= 4.14376e-16);
    // Q_D and Q_S and Q_P are hard zeros.
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.drain)]);
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.source)]);
    try testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.body_contact)]);
}

test "b3soipd: thermal node charge is Cth0*delta_T" {
    // Q_TEMP = cth0 * v_TEMP * m.  Set cth0 = 1e-9, v_TEMP = 2.0, m = 1.
    //   Q_TEMP = 1e-9 * 2.0 = 2e-9.
    var model: Model = .{ .cth0 = 1.0e-9 };
    const inst: Instance = .{};

    var x = [_]f64{0} ** n_u;
    x[@intFromEnum(U.temp)] = 2.0;
    const out = contract.qValues(Self, x, &model, &inst, 0);
    // tolerance loosened from 1e-18: Cth0 is an f32 param, so 2.0*Cth0 rounds
    // at the f32 ULP (~1e-16 here), not f64.
    try testing.expectApproxEqAbs(@as(f64, 2.0e-9), out[@intFromEnum(U.temp)], 1e-16);
}
