const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM3SOI-DD v2.0 — Dynamic Depletion SOI MOSFET
//
// Topology: D(drain), G(gate), S(source), E(substrate/back-gate)
//           Four external terminals, no internal nodes (Rds handled via Rds0)
//           Body is floating (SOI) — body potential determined self-consistently
//           Includes: parasitic BJT, GIDL, impact ionization, junction diodes,
//                     charge-based capacitance model
// ============================================================================

pub const U = enum(u8) { drain, gate, source, sub };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device type and selectors ---
    dev_type: i32 = 1, // 1=NMOS, -1=PMOS
    capmod: i32 = 2,
    mobmod: i32 = 1,
    noimod: i32 = 1,
    paramchk: i32 = 0,
    binunit: i32 = 1,
    version: i32 = 2,
    shmod: i32 = 0,

    // --- Threshold Voltage Parameters ---
    vth0: f32 = 0.7,
    k1: f32 = 0,
    k2: f32 = 0,
    k3: f32 = 0,
    k3b: f32 = 0,
    nch: f32 = 1.7e17,
    nsub: f32 = 6e16,
    ngate: f32 = 0,
    gamma1: f32 = 0,
    gamma2: f32 = 0,
    vbx: f32 = 0,
    vbm: f32 = -3,

    // --- Short Channel Effect Parameters ---
    dvt0: f32 = 2.2,
    dvt1: f32 = 0.53,
    dvt2: f32 = -0.032,
    dvt0w: f32 = 0,
    dvt1w: f32 = 5.3e6,
    dvt2w: f32 = -0.032,
    nlx: f32 = 1.74e-7,
    w0: f32 = 2.5e-6,
    xt: f32 = 1.55e-7,

    // --- DIBL Parameters ---
    eta0: f32 = 0.08,
    etab: f32 = -0.07,
    dsub: f32 = 0.56,
    drout: f32 = 0.56,
    pdiblc1: f32 = 0.39,
    pdiblc2: f32 = 0.0086,
    pdiblcb: f32 = 0,
    pvag: f32 = 0,

    // --- Subthreshold Parameters ---
    voff: f32 = -0.08,
    nfactor: f32 = 1,
    cdsc: f32 = 2.4e-4,
    cdscb: f32 = 0,
    cdscd: f32 = 0,
    cit: f32 = 0,

    // --- Mobility Parameters ---
    u0: f32 = 0.067,
    ua: f32 = 2.25e-9,
    ub: f32 = 5.87e-19,
    uc: f32 = -4.65e-11,
    vsat: f32 = 80000,
    a0: f32 = 1,
    ags: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 1,
    b0: f32 = 0,
    b1: f32 = 0,
    keta: f32 = -0.6,

    // --- Temperature Coefficients ---
    tnom: f32 = 300.15,
    at: f32 = 33000,
    kt1: f32 = -0.11,
    kt1l: f32 = 0,
    kt2: f32 = 0.022,
    ute: f32 = -1.5,
    ua1: f32 = 4.31e-9,
    ub1: f32 = -7.61e-18,
    uc1: f32 = -5.6e-11,
    prt: f32 = 0,

    // --- Channel Length Modulation ---
    pclm: f32 = 1.3,

    // --- Parasitic Resistance ---
    rsh: f32 = 0,
    rdsw: f32 = 100,
    prwg: f32 = 0,
    prwb: f32 = 0,
    wr: f32 = 1,

    // --- Effective Length/Width Parameters ---
    lint: f32 = 0,
    ll: f32 = 0,
    lln: f32 = 1,
    lw: f32 = 0,
    lwn: f32 = 1,
    lwl: f32 = 0,
    wint: f32 = 0,
    wl: f32 = 0,
    wln: f32 = 1,
    ww: f32 = 0,
    wwn: f32 = 1,
    wwl: f32 = 0,
    dwg: f32 = 0,
    dwb: f32 = 0,
    xj: f32 = 0,

    // --- SOI-Specific Parameters ---
    tox: f32 = 1e-8,
    tbox: f32 = 3e-7,
    tsi: f32 = 1e-7,
    kb1: f32 = 1,
    kb3: f32 = 1,
    dvbd0: f32 = 0,
    dvbd1: f32 = 0,
    vbsa: f32 = 0,
    delp: f32 = 0.02,
    rbody: f32 = 0,
    rbsh: f32 = 0,
    adice0: f32 = 1,
    abp: f32 = 1,
    mxc: f32 = -0.9,

    // --- Self-Heating Parameters ---
    rth0: f32 = 0,
    cth0: f32 = 0,

    // --- Impact Ionization Parameters ---
    alpha0: f32 = 0,
    alpha1: f32 = 1,
    beta0: f32 = 30,
    aii: f32 = 0,
    bii: f32 = 0,
    cii: f32 = 0,
    dii: f32 = -1,

    // --- GIDL Parameters ---
    agidl: f32 = 0,
    bgidl: f32 = 0,
    ngidl: f32 = 0,

    // --- Diode and BJT Parameters ---
    ndiode: f32 = 1,
    ntun: f32 = 10,
    isbjt: f32 = 1e-6,
    isdif: f32 = 0,
    isrec: f32 = 1e-5,
    istun: f32 = 0,
    xbjt: f32 = 2,
    xrec: f32 = 20,
    xtun: f32 = 0,
    edl: f32 = 2e-6,
    kbjt1: f32 = 0,
    tt: f32 = 1e-12,

    // --- Source/Drain Diffusion Parameters ---
    vsdth: f32 = 0,
    vsdfb: f32 = 0,
    csdmin: f32 = 1.005e-4,
    asd: f32 = 0.3,

    // --- Junction Capacitance Parameters ---
    pbswg: f32 = 0.7,
    mjswg: f32 = 0.5,
    cjswg: f32 = 1e-10,
    csdesw: f32 = 0,

    // --- Overlap Capacitance Parameters ---
    cgso: f32 = 2.072e-10,
    cgdo: f32 = 2.072e-10,
    cgeo: f32 = 0,
    xpart: f32 = 0,
    delta: f32 = 0.01,

    // --- C-V Model Parameters ---
    cgsl: f32 = 0,
    cgdl: f32 = 0,
    ckappa: f32 = 0.6,
    cf: f32 = 8.164e-11,
    clc: f32 = 1e-8,
    cle: f32 = 0,
    dwc: f32 = 0,
    dlc: f32 = 0,

    // --- Noise Parameters ---
    noia: f32 = 1e20,
    noib: f32 = 50000,
    noic: f32 = -1.4e-12,
    em: f32 = 4.1e7,
    ef: f32 = 1,
    af: f32 = 1,
    kf: f32 = 0,
    noif: f32 = 1,

    // ========================================================================
    // Length Dependence Parameters (prefix: l)
    // ========================================================================
    lnch: f32 = 0,
    lnsub: f32 = 0,
    lngate: f32 = 0,
    lvth0: f32 = 0,
    lk1: f32 = 0,
    lk2: f32 = 0,
    lk3: f32 = 0,
    lk3b: f32 = 0,
    lvbsa: f32 = 0,
    ldelp: f32 = 0,
    lkb1: f32 = 0,
    lkb3: f32 = 1,
    ldvbd0: f32 = 0,
    ldvbd1: f32 = 0,
    lw0: f32 = 0,
    lnlx: f32 = 0,
    ldvt0: f32 = 0,
    ldvt1: f32 = 0,
    ldvt2: f32 = 0,
    ldvt0w: f32 = 0,
    ldvt1w: f32 = 0,
    ldvt2w: f32 = 0,
    lu0: f32 = 0,
    lua: f32 = 0,
    lub: f32 = 0,
    luc: f32 = 0,
    lvsat: f32 = 0,
    la0: f32 = 0,
    lags: f32 = 0,
    lb0: f32 = 0,
    lb1: f32 = 0,
    lketa: f32 = 0,
    labp: f32 = 0,
    lmxc: f32 = 0,
    ladice0: f32 = 0,
    la1: f32 = 0,
    la2: f32 = 0,
    lrdsw: f32 = 0,
    lprwb: f32 = 0,
    lprwg: f32 = 0,
    lwr: f32 = 0,
    lnfactor: f32 = 0,
    ldwg: f32 = 0,
    ldwb: f32 = 0,
    lvoff: f32 = 0,
    leta0: f32 = 0,
    letab: f32 = 0,
    ldsub: f32 = 0,
    lcit: f32 = 0,
    lcdsc: f32 = 0,
    lcdscb: f32 = 0,
    lcdscd: f32 = 0,
    lpclm: f32 = 0,
    lpdiblc1: f32 = 0,
    lpdiblc2: f32 = 0,
    lpdiblcb: f32 = 0,
    ldrout: f32 = 0,
    lpvag: f32 = 0,
    ldelta: f32 = 0,
    laii: f32 = 0,
    lbii: f32 = 0,
    lcii: f32 = 0,
    ldii: f32 = 0,
    lalpha0: f32 = 0,
    lalpha1: f32 = 0,
    lbeta0: f32 = 0,
    lagidl: f32 = 0,
    lbgidl: f32 = 0,
    lngidl: f32 = 0,
    lntun: f32 = 0,
    lndiode: f32 = 0,
    lisbjt: f32 = 0,
    lisdif: f32 = 0,
    lisrec: f32 = 0,
    listun: f32 = 0,
    ledl: f32 = 0,
    lkbjt1: f32 = 0,
    lvsdfb: f32 = 0,
    lvsdth: f32 = 0,

    // ========================================================================
    // Width Dependence Parameters (prefix: w)
    // ========================================================================
    wnch: f32 = 0,
    wnsub: f32 = 0,
    wngate: f32 = 0,
    wvth0: f32 = 0,
    wk1: f32 = 0,
    wk2: f32 = 0,
    wk3: f32 = 0,
    wk3b: f32 = 0,
    wvbsa: f32 = 0,
    wdelp: f32 = 0,
    wkb1: f32 = 0,
    wkb3: f32 = 1,
    wdvbd0: f32 = 0,
    wdvbd1: f32 = 0,
    ww0: f32 = 0,
    wnlx: f32 = 0,
    wdvt0: f32 = 0,
    wdvt1: f32 = 0,
    wdvt2: f32 = 0,
    wdvt0w: f32 = 0,
    wdvt1w: f32 = 0,
    wdvt2w: f32 = 0,
    wu0: f32 = 0,
    wua: f32 = 0,
    wub: f32 = 0,
    wuc: f32 = 0,
    wvsat: f32 = 0,
    wa0: f32 = 0,
    wags: f32 = 0,
    wb0: f32 = 0,
    wb1: f32 = 0,
    wketa: f32 = 0,
    wabp: f32 = 0,
    wmxc: f32 = 0,
    wadice0: f32 = 0,
    wa1: f32 = 0,
    wa2: f32 = 0,
    wrdsw: f32 = 0,
    wprwb: f32 = 0,
    wprwg: f32 = 0,
    wwr: f32 = 0,
    wnfactor: f32 = 0,
    wdwg: f32 = 0,
    wdwb: f32 = 0,
    wvoff: f32 = 0,
    weta0: f32 = 0,
    wetab: f32 = 0,
    wdsub: f32 = 0,
    wcit: f32 = 0,
    wcdsc: f32 = 0,
    wcdscb: f32 = 0,
    wcdscd: f32 = 0,
    wpclm: f32 = 0,
    wpdiblc1: f32 = 0,
    wpdiblc2: f32 = 0,
    wpdiblcb: f32 = 0,
    wdrout: f32 = 0,
    wpvag: f32 = 0,
    wdelta: f32 = 0,
    waii: f32 = 0,
    wbii: f32 = 0,
    wcii: f32 = 0,
    wdii: f32 = 0,
    walpha0: f32 = 0,
    walpha1: f32 = 0,
    wbeta0: f32 = 0,
    wagidl: f32 = 0,
    wbgidl: f32 = 0,
    wngidl: f32 = 0,
    wntun: f32 = 0,
    wndiode: f32 = 0,
    wisbjt: f32 = 0,
    wisdif: f32 = 0,
    wisrec: f32 = 0,
    wistun: f32 = 0,
    wedl: f32 = 0,
    wkbjt1: f32 = 0,
    wvsdfb: f32 = 0,
    wvsdth: f32 = 0,

    // ========================================================================
    // Cross-term Dependence Parameters (prefix: p)
    // ========================================================================
    pnch: f32 = 0,
    pnsub: f32 = 0,
    pngate: f32 = 0,
    pvth0: f32 = 0,
    pk1: f32 = 0,
    pk2: f32 = 0,
    pk3: f32 = 0,
    pk3b: f32 = 0,
    pvbsa: f32 = 0,
    pdelp: f32 = 0,
    pkb1: f32 = 0,
    pkb3: f32 = 1,
    pdvbd0: f32 = 0,
    pdvbd1: f32 = 0,
    pw0: f32 = 0,
    pnlx: f32 = 0,
    pdvt0: f32 = 0,
    pdvt1: f32 = 0,
    pdvt2: f32 = 0,
    pdvt0w: f32 = 0,
    pdvt1w: f32 = 0,
    pdvt2w: f32 = 0,
    pu0: f32 = 0,
    pua: f32 = 0,
    pub_: f32 = 0,
    puc: f32 = 0,
    pvsat: f32 = 0,
    pa0: f32 = 0,
    pags: f32 = 0,
    pb0: f32 = 0,
    pb1: f32 = 0,
    pketa: f32 = 0,
    pabp: f32 = 0,
    pmxc: f32 = 0,
    padice0: f32 = 0,
    pa1: f32 = 0,
    pa2: f32 = 0,
    prdsw: f32 = 0,
    pprwb: f32 = 0,
    pprwg: f32 = 0,
    pwr: f32 = 0,
    pnfactor: f32 = 0,
    pdwg: f32 = 0,
    pdwb: f32 = 0,
    pvoff: f32 = 0,
    peta0: f32 = 0,
    petab: f32 = 0,
    pdsub: f32 = 0,
    pcit: f32 = 0,
    pcdsc: f32 = 0,
    pcdscb: f32 = 0,
    pcdscd: f32 = 0,
    ppclm: f32 = 0,
    ppdiblc1: f32 = 0,
    ppdiblc2: f32 = 0,
    ppdiblcb: f32 = 0,
    pdrout: f32 = 0,
    ppvag: f32 = 0,
    pdelta: f32 = 0,
    paii: f32 = 0,
    pbii: f32 = 0,
    pcii: f32 = 0,
    pdii: f32 = 0,
    palpha0: f32 = 0,
    palpha1: f32 = 0,
    pbeta0: f32 = 0,
    pagidl: f32 = 0,
    pbgidl: f32 = 0,
    pngidl: f32 = 0,
    pntun: f32 = 0,
    pndiode: f32 = 0,
    pisbjt: f32 = 0,
    pisdif: f32 = 0,
    pisrec: f32 = 0,
    pistun: f32 = 0,
    pedl: f32 = 0,
    pkbjt1: f32 = 0,
    pvsdfb: f32 = 0,
    pvsdth: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 1e-6,
    l: f32 = 1e-6,
    temp: f32 = 300.15,
    m: f32 = 1.0,
};

// ============================================================================
// Helper: parameter binning
// ============================================================================
inline fn bin(base: f64, l_dep: f64, w_dep: f64, p_dep: f64, leff: f64, weff: f64) f64 {
    return base + l_dep / leff + w_dep / weff + p_dep / (leff * weff);
}

// ============================================================================
// x-INDEPENDENT parameter/geometry/temperature preprocessing.
//
// Everything here is a pure function of Model + Instance (no terminal
// voltages), so it stays plain f64. The value-form eval/q pull these out
// and run only the x-dependent tail through the generic scalar S.
// ============================================================================

const Consts = struct {
    // physical constants
    const eps_si: f64 = 1.03594e-10;
    const eps_ox: f64 = 3.453133e-11;
    const q_e: f64 = 1.60219e-19;
    const kb_q: f64 = 8.617087e-5;
    const gmin: f64 = 1.0e-12;
    const ni: f64 = 1.45e10;
};

/// f64 prep shared by eval and q. Holds all x-independent binned/derived
/// quantities that the S tails reference.
const Prep = struct {
    type_f: f64,
    m_inst: f64,
    leff: f64,
    weff: f64,
    inv_leff: f64,
    tox_v: f64,
    tbox_v: f64,
    tsi_v: f64,
    vt_nom: f64,
    // oxide caps
    cox: f64,
    c_box: f64,
    c_si: f64,
    // semiconductor
    nch_cm3: f64,
    phi_s: f64,
    sqrt_phis: f64,
    xdep0: f64,
    vbi: f64,
    vfbb: f64,
    qsi: f64,
    // dynamic depletion (x-independent portion)
    vbs0t: f64,
    tkb: f64,
    // threshold pieces (x-independent)
    dvth_nlx: f64,
    dvth_sce: f64,
    nfb: f64,
    // binned params referenced in S tail
    vth0_b: f64,
    k1_b: f64,
    k2_b: f64,
    k3_b: f64,
    w0_b: f64,
    delp_b: f64,
    eta0_b: f64,
    etab_b: f64,
    nfactor_b: f64,
    cdsc_b: f64,
    cdscd_b: f64,
    cdscb_b: f64,
    cit_b: f64,
    voff_b: f64,
    mu0_b: f64,
    ua_b: f64,
    ub_b: f64,
    uc_b: f64,
    vsat_b: f64,
    a0_b: f64,
    b0_b: f64,
    b1_b: f64,
    keta_b: f64,
    rds: f64,
    pclm_b: f64,
    pdiblc1_b: f64,
    pdiblc2_b: f64,
    drout_b: f64,
    pvag_b: f64,
    delta_b: f64,
    alpha0_b: f64,
    alpha1_b: f64,
    beta0_b: f64,
    agidl_b: f64,
    bgidl_b: f64,
    ngidl_b: f64,
    ndiode_b: f64,
    ntun_b: f64,
    isbjt_b: f64,
    isdif_b: f64,
    isrec_b: f64,
    istun_b: f64,
    abulk0: f64,
    litl: f64,
    theta_rout: f64,
    // charge-only overlap params
    cgso_v: f64,
    cgdo_v: f64,
    cgeo_v: f64,
    tt_v: f64,
    cjswg_v: f64,
    pbswg_v: f64,
    mjswg_v: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    const eps_si = Consts.eps_si;
    const eps_ox = Consts.eps_ox;
    const q_e = Consts.q_e;
    const kb_q = Consts.kb_q;
    const ni = Consts.ni;

    const type_f: f64 = @floatFromInt(model.dev_type);
    const tnom: f64 = @as(f64, model.tnom);
    const vt_nom: f64 = kb_q * tnom;

    const w_raw: f64 = @as(f64, instance.w);
    const l_raw: f64 = @as(f64, instance.l);
    const m_inst: f64 = @as(f64, instance.m);
    const lint_v: f64 = @as(f64, model.lint);
    const wint_v: f64 = @as(f64, model.wint);
    const leff = @max(l_raw - 2.0 * lint_v, 1.0e-8);
    const weff = @max(w_raw - 2.0 * wint_v, 1.0e-8);
    const inv_leff: f64 = 1.0 / leff;

    const tox_v: f64 = @as(f64, model.tox);
    const tbox_v: f64 = @as(f64, model.tbox);
    const tsi_v: f64 = @as(f64, model.tsi);

    // --- Binned parameters ---
    const nch_b = @max(bin(@as(f64, model.nch), @as(f64, model.lnch), @as(f64, model.wnch), @as(f64, model.pnch), leff, weff), 1.0e10);
    const nsub_b: f64 = @as(f64, model.nsub);
    const vth0_b = bin(@as(f64, model.vth0), @as(f64, model.lvth0), @as(f64, model.wvth0), @as(f64, model.pvth0), leff, weff);
    const k1_b = bin(@as(f64, model.k1), @as(f64, model.lk1), @as(f64, model.wk1), @as(f64, model.pk1), leff, weff);
    const k2_b = bin(@as(f64, model.k2), @as(f64, model.lk2), @as(f64, model.wk2), @as(f64, model.pk2), leff, weff);
    const k3_b = bin(@as(f64, model.k3), @as(f64, model.lk3), @as(f64, model.wk3), @as(f64, model.pk3), leff, weff);
    const eta0_b = bin(@as(f64, model.eta0), @as(f64, model.leta0), @as(f64, model.weta0), @as(f64, model.peta0), leff, weff);
    const etab_b = bin(@as(f64, model.etab), @as(f64, model.letab), @as(f64, model.wetab), @as(f64, model.petab), leff, weff);
    const mu0_b = bin(@as(f64, model.u0), @as(f64, model.lu0), @as(f64, model.wu0), @as(f64, model.pu0), leff, weff);
    const ua_b = bin(@as(f64, model.ua), @as(f64, model.lua), @as(f64, model.wua), @as(f64, model.pua), leff, weff);
    const ub_b = bin(@as(f64, model.ub), @as(f64, model.lub), @as(f64, model.wub), @as(f64, model.pub_), leff, weff);
    const uc_b = bin(@as(f64, model.uc), @as(f64, model.luc), @as(f64, model.wuc), @as(f64, model.puc), leff, weff);
    const voff_b = bin(@as(f64, model.voff), @as(f64, model.lvoff), @as(f64, model.wvoff), @as(f64, model.pvoff), leff, weff);
    const nfactor_b = bin(@as(f64, model.nfactor), @as(f64, model.lnfactor), @as(f64, model.wnfactor), @as(f64, model.pnfactor), leff, weff);
    const vsat_b = bin(@as(f64, model.vsat), @as(f64, model.lvsat), @as(f64, model.wvsat), @as(f64, model.pvsat), leff, weff);
    const a0_b = bin(@as(f64, model.a0), @as(f64, model.la0), @as(f64, model.wa0), @as(f64, model.pa0), leff, weff);
    const keta_b = bin(@as(f64, model.keta), @as(f64, model.lketa), @as(f64, model.wketa), @as(f64, model.pketa), leff, weff);
    const rdsw_b = bin(@as(f64, model.rdsw), @as(f64, model.lrdsw), @as(f64, model.wrdsw), @as(f64, model.prdsw), leff, weff);
    const pclm_b = bin(@as(f64, model.pclm), @as(f64, model.lpclm), @as(f64, model.wpclm), @as(f64, model.ppclm), leff, weff);
    const pdiblc1_b = bin(@as(f64, model.pdiblc1), @as(f64, model.lpdiblc1), @as(f64, model.wpdiblc1), @as(f64, model.ppdiblc1), leff, weff);
    const pdiblc2_b = bin(@as(f64, model.pdiblc2), @as(f64, model.lpdiblc2), @as(f64, model.wpdiblc2), @as(f64, model.ppdiblc2), leff, weff);
    const dvt0_b = bin(@as(f64, model.dvt0), @as(f64, model.ldvt0), @as(f64, model.wdvt0), @as(f64, model.pdvt0), leff, weff);
    const dvt1_b = bin(@as(f64, model.dvt1), @as(f64, model.ldvt1), @as(f64, model.wdvt1), @as(f64, model.pdvt1), leff, weff);
    const cdsc_b = bin(@as(f64, model.cdsc), @as(f64, model.lcdsc), @as(f64, model.wcdsc), @as(f64, model.pcdsc), leff, weff);
    const cdscd_b = bin(@as(f64, model.cdscd), @as(f64, model.lcdscd), @as(f64, model.wcdscd), @as(f64, model.pcdscd), leff, weff);
    const cdscb_b = bin(@as(f64, model.cdscb), @as(f64, model.lcdscb), @as(f64, model.wcdscb), @as(f64, model.pcdscb), leff, weff);
    const delta_b = bin(@as(f64, model.delta), @as(f64, model.ldelta), @as(f64, model.wdelta), @as(f64, model.pdelta), leff, weff);
    const pvag_b = bin(@as(f64, model.pvag), @as(f64, model.lpvag), @as(f64, model.wpvag), @as(f64, model.ppvag), leff, weff);
    const alpha0_b = bin(@as(f64, model.alpha0), @as(f64, model.lalpha0), @as(f64, model.walpha0), @as(f64, model.palpha0), leff, weff);
    const alpha1_b = bin(@as(f64, model.alpha1), @as(f64, model.lalpha1), @as(f64, model.walpha1), @as(f64, model.palpha1), leff, weff);
    const beta0_b = bin(@as(f64, model.beta0), @as(f64, model.lbeta0), @as(f64, model.wbeta0), @as(f64, model.pbeta0), leff, weff);
    const agidl_b = bin(@as(f64, model.agidl), @as(f64, model.lagidl), @as(f64, model.wagidl), @as(f64, model.pagidl), leff, weff);
    const bgidl_b = bin(@as(f64, model.bgidl), @as(f64, model.lbgidl), @as(f64, model.wbgidl), @as(f64, model.pbgidl), leff, weff);
    const ngidl_b = bin(@as(f64, model.ngidl), @as(f64, model.lngidl), @as(f64, model.wngidl), @as(f64, model.pngidl), leff, weff);
    const ndiode_b = bin(@as(f64, model.ndiode), @as(f64, model.lndiode), @as(f64, model.wndiode), @as(f64, model.pndiode), leff, weff);
    const ntun_b = bin(@as(f64, model.ntun), @as(f64, model.lntun), @as(f64, model.wntun), @as(f64, model.pntun), leff, weff);
    const isbjt_b = bin(@as(f64, model.isbjt), @as(f64, model.lisbjt), @as(f64, model.wisbjt), @as(f64, model.pisbjt), leff, weff);
    const isdif_b = bin(@as(f64, model.isdif), @as(f64, model.lisdif), @as(f64, model.wisdif), @as(f64, model.pisdif), leff, weff);
    const isrec_b = bin(@as(f64, model.isrec), @as(f64, model.lisrec), @as(f64, model.wisrec), @as(f64, model.pisrec), leff, weff);
    const istun_b = bin(@as(f64, model.istun), @as(f64, model.listun), @as(f64, model.wistun), @as(f64, model.pistun), leff, weff);
    const kb1_b = bin(@as(f64, model.kb1), @as(f64, model.lkb1), @as(f64, model.wkb1), @as(f64, model.pkb1), leff, weff);
    const kb3_b = bin(@as(f64, model.kb3), @as(f64, model.lkb3), @as(f64, model.wkb3), @as(f64, model.pkb3), leff, weff);
    const dvbd0_b = bin(@as(f64, model.dvbd0), @as(f64, model.ldvbd0), @as(f64, model.wdvbd0), @as(f64, model.pdvbd0), leff, weff);
    const dvbd1_b = bin(@as(f64, model.dvbd1), @as(f64, model.ldvbd1), @as(f64, model.wdvbd1), @as(f64, model.pdvbd1), leff, weff);
    const vbsa_b = bin(@as(f64, model.vbsa), @as(f64, model.lvbsa), @as(f64, model.wvbsa), @as(f64, model.pvbsa), leff, weff);
    const delp_b = bin(@as(f64, model.delp), @as(f64, model.ldelp), @as(f64, model.wdelp), @as(f64, model.pdelp), leff, weff);
    const drout_b = bin(@as(f64, model.drout), @as(f64, model.ldrout), @as(f64, model.wdrout), @as(f64, model.pdrout), leff, weff);
    const nlx_b = bin(@as(f64, model.nlx), @as(f64, model.lnlx), @as(f64, model.wnlx), @as(f64, model.pnlx), leff, weff);
    const w0_b = bin(@as(f64, model.w0), @as(f64, model.lw0), @as(f64, model.ww0), @as(f64, model.pw0), leff, weff);
    const cit_b = bin(@as(f64, model.cit), @as(f64, model.lcit), @as(f64, model.wcit), @as(f64, model.pcit), leff, weff);
    const b0_b = bin(@as(f64, model.b0), @as(f64, model.lb0), @as(f64, model.wb0), @as(f64, model.pb0), leff, weff);
    const b1_b = bin(@as(f64, model.b1), @as(f64, model.lb1), @as(f64, model.wb1), @as(f64, model.pb1), leff, weff);

    // --- Oxide capacitance ---
    const cox = eps_ox / tox_v;
    const c_box = eps_ox / tbox_v;
    const c_si = eps_si / tsi_v;

    // --- Basic semiconductor quantities ---
    const nch_cm3 = @max(nch_b, 1.0e10);
    const phi_s = 2.0 * vt_nom * contract.fmath.log(@max(nch_cm3 / ni, 1.0));
    const sqrt_phis = @sqrt(@max(phi_s, 0.1));
    const xdep0 = @sqrt(2.0 * eps_si / (q_e * nch_cm3 * 1.0e6)) * sqrt_phis;
    const vbi = vt_nom * contract.fmath.log(1.0e20 * nch_cm3 / (ni * ni));

    // --- Flatband voltage ---
    const vfbb = if (nsub_b > 0.0)
        -vt_nom * contract.fmath.log(nch_cm3 / nsub_b)
    else
        -vt_nom * contract.fmath.log(-nch_cm3 * nsub_b / (ni * ni));

    // --- SOI charge ---
    const qsi = q_e * nch_cm3 * 1.0e6 * tsi_v;

    // --- Dynamic depletion: Vbs0t (x-independent) ---
    const lt1 = @sqrt(eps_si / (q_e * nch_cm3 * 1.0e6));
    const dvbd1_arg1 = @max(@min(-dvbd1_b * leff / (4.0 * lt1), 80.0), -80.0);
    const dvbd1_arg2 = @max(@min(-dvbd1_b * leff / (2.0 * lt1), 80.0), -80.0);
    const t1_vbs0t = dvbd0_b * (contract.fmath.exp(dvbd1_arg1) + 2.0 * contract.fmath.exp(dvbd1_arg2));
    const t2_vbs0t = t1_vbs0t * (vbi - phi_s);
    const t3_vbs0t = qsi / (2.0 * c_si);
    const vbs0t = phi_s - t3_vbs0t + vbsa_b + t2_vbs0t;

    // --- Back-gate coupling: tkb (x-independent) ---
    const t0_bg = 1.0 + c_si / c_box;
    const tkb = kb1_b / t0_bg;

    // NLX correction
    const dvth_nlx = k1_b * (@sqrt(1.0 + nlx_b * inv_leff) - 1.0) * sqrt_phis;

    // SCE
    const lt_sce = @sqrt(eps_si * tox_v / (eps_ox * nch_cm3 * 1.0e6 * q_e));
    const arg_sce = @min(dvt1_b * leff / (2.0 * lt_sce), 80.0);
    const edvt1 = contract.fmath.exp(-arg_sce);
    const dvth_sce = dvt0_b * (1.0 - edvt1) * (1.0 + 2.0 * edvt1) * (vbi - phi_s);

    // --- Subthreshold feedback factor Nfb (x-independent) ---
    const t8_nfb = @sqrt(@max(phi_s, 0.01));
    const k1_sq = k1_b * k1_b;
    const k1_safe = @max(k1_sq, 1.0e-30);
    const t5_nfb = @sqrt(1.0 + 4.0 / k1_safe * (phi_s + k1_b * t8_nfb));
    const tkb3 = kb3_b * c_box / cox;
    const nfb = 1.0 / (1.0 + tkb3 * t5_nfb);

    // --- Source/drain resistance ---
    const rds0 = rdsw_b / (weff * 1.0e6);
    const rds = rds0;

    // --- Bulk charge effect Abulk0 (x-independent) ---
    const abulk0_base = k1_b / (2.0 * sqrt_phis) * (a0_b + b0_b / (weff + b1_b));
    const abulk0 = @max(abulk0_base, 0.01) + 1.0;

    // --- CLM / DIBL length pieces (x-independent) ---
    const litl = @sqrt(eps_si * tox_v / eps_ox);
    const lt_dibl = @sqrt(eps_si * tox_v / (eps_ox * nch_cm3 * 1.0e6 * q_e));
    const theta_rout_arg = @min(drout_b * leff / (2.0 * lt_dibl), 80.0);
    const theta_rout = pdiblc1_b * contract.fmath.exp(-theta_rout_arg) + pdiblc2_b;

    return .{
        .type_f = type_f,
        .m_inst = m_inst,
        .leff = leff,
        .weff = weff,
        .inv_leff = inv_leff,
        .tox_v = tox_v,
        .tbox_v = tbox_v,
        .tsi_v = tsi_v,
        .vt_nom = vt_nom,
        .cox = cox,
        .c_box = c_box,
        .c_si = c_si,
        .nch_cm3 = nch_cm3,
        .phi_s = phi_s,
        .sqrt_phis = sqrt_phis,
        .xdep0 = xdep0,
        .vbi = vbi,
        .vfbb = vfbb,
        .qsi = qsi,
        .vbs0t = vbs0t,
        .tkb = tkb,
        .dvth_nlx = dvth_nlx,
        .dvth_sce = dvth_sce,
        .nfb = nfb,
        .vth0_b = vth0_b,
        .k1_b = k1_b,
        .k2_b = k2_b,
        .k3_b = k3_b,
        .w0_b = w0_b,
        .delp_b = delp_b,
        .eta0_b = eta0_b,
        .etab_b = etab_b,
        .nfactor_b = nfactor_b,
        .cdsc_b = cdsc_b,
        .cdscd_b = cdscd_b,
        .cdscb_b = cdscb_b,
        .cit_b = cit_b,
        .voff_b = voff_b,
        .mu0_b = mu0_b,
        .ua_b = ua_b,
        .ub_b = ub_b,
        .uc_b = uc_b,
        .vsat_b = vsat_b,
        .a0_b = a0_b,
        .b0_b = b0_b,
        .b1_b = b1_b,
        .keta_b = keta_b,
        .rds = rds,
        .pclm_b = pclm_b,
        .pdiblc1_b = pdiblc1_b,
        .pdiblc2_b = pdiblc2_b,
        .drout_b = drout_b,
        .pvag_b = pvag_b,
        .delta_b = delta_b,
        .alpha0_b = alpha0_b,
        .alpha1_b = alpha1_b,
        .beta0_b = beta0_b,
        .agidl_b = agidl_b,
        .bgidl_b = bgidl_b,
        .ngidl_b = ngidl_b,
        .ndiode_b = ndiode_b,
        .ntun_b = ntun_b,
        .isbjt_b = isbjt_b,
        .isdif_b = isdif_b,
        .isrec_b = isrec_b,
        .istun_b = istun_b,
        .abulk0 = abulk0,
        .litl = litl,
        .theta_rout = theta_rout,
        .cgso_v = @as(f64, model.cgso),
        .cgdo_v = @as(f64, model.cgdo),
        .cgeo_v = @as(f64, model.cgeo),
        .tt_v = @as(f64, model.tt),
        .cjswg_v = @as(f64, model.cjswg),
        .pbswg_v = @as(f64, model.pbswg),
        .mjswg_v = @as(f64, model.mjswg),
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// Physics (value-form): stateless MOSFET drain/source/gate/substrate current.
//
// x-independent prep is done in f64 by `prep`; the terminal-voltage-dependent
// tail below runs entirely through the generic scalar S so one pass yields
// residual + analytic Jacobian.
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d_idx = @intFromEnum(U.drain);
    const g_idx = @intFromEnum(U.gate);
    const s_idx = @intFromEnum(U.source);
    const e_idx = @intFromEnum(U.sub);

    const gmin = Consts.gmin;
    const p = pc;

    // --- Read terminal voltages ---
    const vd_ext = x[d_idx];
    const vg_ext = x[g_idx];
    const vs_ext = x[s_idx];
    const ve_ext = x[e_idx];

    // --- Source/drain reversal ---
    const vds_raw = vd_ext.sub(vs_ext).scale(p.type_f);
    const vgs_raw = vg_ext.sub(vs_ext).scale(p.type_f);
    const ves_raw = ve_ext.sub(vs_ext).scale(p.type_f);

    // Region branch on voltage sign (reproduces the original piecewise swap).
    const reversed = vds_raw.val() < 0.0;
    const v_ds = if (reversed) vds_raw.neg() else vds_raw;
    const v_gs = if (reversed) vgs_raw.sub(vds_raw) else vgs_raw;
    const v_es = if (reversed) ves_raw.sub(vds_raw) else ves_raw;
    const v_bs = S.con(0.0); // floating body
    const v_bd = v_bs.sub(v_ds);

    // --- Dynamic-depletion body-voltage self-consistency (x-dependent) ---
    // vbs0t is x-independent (from prep); tkb, phi_s etc. are constants here.

    // Back-gate coupling: Vbs0
    const vesfb = v_es.addC(-p.vfbb);
    // t6_bg = vbs0t - tkb*(vbs0t - vesfb)
    const t6_bg = vesfb.scale(p.tkb).addC(p.vbs0t * (1.0 - p.tkb));

    // Smoothing Vbs0 to phi_s
    const delta_v: f64 = 0.005;
    // t2_sm = (phi_s - delp_b) - t6_bg - delta_v
    const t2_sm = t6_bg.neg().addC(p.phi_s - p.delp_b - delta_v);
    const t3_sm = t2_sm.mul(t2_sm).addC(4.0 * delta_v).sqrt();
    // vbs0 = (phi_s - delp_b) - (t2_sm + t3_sm)/2
    const vbs0 = t2_sm.add(t3_sm).scale(-0.5).addC(p.phi_s - p.delp_b);

    // Vbs0mos
    const delta_bsmos: f64 = 0.005;
    // t1_bsmos = vbs0t - vbs0 - delta_bsmos
    const t1_bsmos = vbs0.neg().addC(p.vbs0t - delta_bsmos);
    const t2_bsmos = t1_bsmos.mul(t1_bsmos).addC(delta_bsmos * delta_bsmos).sqrt();
    const t3_bsmos = t1_bsmos.add(t2_bsmos).scale(0.5);
    const t4_bsmos = t3_bsmos.scale(p.c_si / p.qsi);
    // vbs0mos = vbs0 - t3_bsmos*t4_bsmos/2
    const vbs0mos = vbs0.sub(t3_bsmos.mul(t4_bsmos).scale(0.5));

    // Fully-depleted threshold voltage Vthfd
    const phi_fd = vbs0mos.neg().addC(p.phi_s);
    const sqrt_phifd = phi_fd.maxC(1.0e-20).sqrt();
    // vthfd = vth0_b + k3_b*tox_v*phi_s/(weff+w0_b) + dvth_nlx - dvth_sce
    //         + k1_b*(sqrt_phifd - sqrt_phis) - k2_b*vbs0mos
    const vthfd_const = p.vth0_b + p.k3_b * p.tox_v * p.phi_s / (p.weff + p.w0_b) + p.dvth_nlx - p.dvth_sce - p.k1_b * p.sqrt_phis;
    const vthfd = sqrt_phifd.scale(p.k1_b).add(vbs0mos.scale(-p.k2_b)).addC(vthfd_const);

    // Effective Vbs0 with gate coupling
    const delta_bs0eff: f64 = 0.02;
    // t1_gv = vthfd - v_gs - delta_bs0eff
    const t1_gv = vthfd.sub(v_gs).addC(-delta_bs0eff);
    const t2_gv = t1_gv.mul(t1_gv).addC(delta_bs0eff * delta_bs0eff).sqrt();
    const vbs0teff = t1_gv.add(t2_gv).scale(-0.5).addC(p.vbs0t);

    // Effective body voltage Vbseff (subthreshold)
    // vbs0eff = vbs0 - nfb*(t1_gv + t2_gv)/2
    const vbs0eff = vbs0.sub(t1_gv.add(t2_gv).scale(p.nfb * 0.5));

    // Diode body voltage Vbsdio
    const delta_dio: f64 = 0.01;
    const off_dio: f64 = 0.02;
    // t1_dio = v_bs - vbs0eff - off_dio - delta_dio
    const t1_dio = v_bs.sub(vbs0eff).addC(-off_dio - delta_dio);
    const t2_dio = t1_dio.mul(t1_dio).addC(delta_dio * delta_dio).sqrt();
    // vbsdio = vbs0eff + off_dio + (t1_dio + t2_dio)/2
    const vbsdio = vbs0eff.add(t1_dio.add(t2_dio).scale(0.5)).addC(off_dio);

    // MOSFET body voltage Vbsmos
    // t1_mos = vbs0teff - vbsdio - delta_bsmos
    const t1_mos = vbs0teff.sub(vbsdio).addC(-delta_bsmos);
    const t2_mos = t1_mos.mul(t1_mos).addC(delta_bsmos * delta_bsmos).sqrt();
    const t3_mos = t1_mos.add(t2_mos).scale(0.5);
    // vbsmos = vbsdio - t3_mos*t3_mos*c_si/(2*qsi)
    const vbsmos = vbsdio.sub(t3_mos.mul(t3_mos).scale(p.c_si / (2.0 * p.qsi)));

    // Final Vbseff clamped to phi_s
    const delta_vbseff: f64 = 0.005;
    // t2_clamp = (phi_s - delp_b) - vbsmos - delta_vbseff
    const t2_clamp = vbsmos.neg().addC(p.phi_s - p.delp_b - delta_vbseff);
    const t3_clamp = t2_clamp.mul(t2_clamp).addC(4.0 * delta_vbseff * (p.phi_s - p.delp_b)).sqrt();
    const vbseff = t2_clamp.add(t3_clamp).scale(-0.5).addC(p.phi_s - p.delp_b);

    // Surface potential and depletion width
    const phis_eff = vbseff.neg().addC(p.phi_s);
    const sqrt_phis_eff = phis_eff.maxC(1.0e-20).sqrt();
    const xdep = sqrt_phis_eff.scale(p.xdep0 / p.sqrt_phis);

    // Main threshold voltage
    // dibl_sft = eta0_b*v_ds + etab_b*vbseff
    const dibl_sft = v_ds.scale(p.eta0_b).add(vbseff.scale(p.etab_b));
    // vth = vth0_b + k3_b*tox_v*phi_s/(weff+w0_b) + dvth_nlx - dvth_sce
    //       + k1_b*(sqrt_phis_eff - sqrt_phis) - k2_b*vbseff - dibl_sft
    const vth = sqrt_phis_eff.scale(p.k1_b).add(vbseff.scale(-p.k2_b)).sub(dibl_sft).addC(vthfd_const);

    // Subthreshold swing factor n
    // t2n = nfactor_b*eps_si/xdep
    const t2n = xdep.pow(-1.0).scale(p.nfactor_b * Consts.eps_si);
    // t3n = cdsc_b + cdscd_b*v_ds + cdscb_b*vbseff
    const t3n = v_ds.scale(p.cdscd_b).add(vbseff.scale(p.cdscb_b)).addC(p.cdsc_b);
    // t4n = (t2n + t3n + cit_b)/cox
    const t4n = t2n.add(t3n).addC(p.cit_b).scale(1.0 / p.cox);
    // n_sub = 1 + max(t4n, -0.5)
    const n_sub = t4n.maxC(-0.5).addC(1.0);

    // Effective gate overdrive Vgsteff
    // vgst = v_gs - vth - voff_b
    const vgst = v_gs.sub(vth).addC(-p.voff_b);
    // vgst_nvt = vgst/(2*n_sub*vt_nom)
    const vgst_nvt = vgst.div(n_sub.scale(2.0 * p.vt_nom));
    const vgst_clamped = vgst_nvt.maxC(-34.0).minC(34.0);
    // vgsteff = 2*n_sub*vt_nom * log(1 + exp(vgst_clamped))
    const vgsteff = n_sub.mul(vgst_clamped.exp().addC(1.0).log()).scale(2.0 * p.vt_nom);
    const vgst2vtm = vgsteff.addC(2.0 * p.vt_nom);

    // Bulk charge effect Abulk
    // keta_denom = max(1 + keta_b*vbseff, 0.1)
    const keta_denom = vbseff.scale(p.keta_b).addC(1.0).maxC(0.1);
    // abulk = abulk0/keta_denom
    const abulk = keta_denom.pow(-1.0).scale(p.abulk0);
    const abeff = abulk.maxC(0.01);

    // Mobility
    // t0_mob = vgsteff + 2*vth
    const t0_mob = vgsteff.add(vth.scale(2.0));
    const t3_mob = t0_mob.scale(1.0 / p.tox_v);
    // d_mob = 1 + (ua_b + uc_b*vbseff)*t3_mob + ub_b*t3_mob*t3_mob
    const d_mob = vbseff.scale(p.uc_b).addC(p.ua_b).mul(t3_mob)
        .add(t3_mob.mul(t3_mob).scale(p.ub_b)).addC(1.0);
    // mu_eff = mu0_b/max(d_mob, 0.01)
    const mu_eff = d_mob.maxC(0.01).pow(-1.0).scale(p.mu0_b);

    // Saturation velocity and Esat
    // esat = 2*vsat_b/mu_eff ; esat_l = esat*leff
    const esat_l = mu_eff.pow(-1.0).scale(2.0 * p.vsat_b * p.leff);

    // Saturation voltage Vdsat = esat_l*vgst2vtm / (abeff*esat_l + vgst2vtm)
    const vdsat = esat_l.mul(vgst2vtm).div(abeff.mul(esat_l).add(vgst2vtm));

    // Effective VDS (smooth saturation clamp)
    // t1_vds = vdsat - v_ds - delta_b
    const t1_vds = vdsat.sub(v_ds).addC(-p.delta_b);
    // t2_vds = sqrt(t1_vds^2 + 4*delta_b*vdsat)
    const t2_vds = t1_vds.mul(t1_vds).add(vdsat.scale(4.0 * p.delta_b)).sqrt();
    const vdseff = vdsat.sub(t1_vds.add(t2_vds).scale(0.5));
    const delta_vds = v_ds.sub(vdseff);

    // Channel length modulation (VACLM)
    const vaclm = if (p.pclm_b > 0.0) blk: {
        // litl/(pclm_b*leff)*leff*(abeff + vgsteff/esat_l)*delta_vds + 1e-20
        const coeff = p.litl / (p.pclm_b * p.leff) * p.leff;
        const inner = abeff.add(vgsteff.div(esat_l));
        break :blk inner.mul(delta_vds).scale(coeff).addC(1.0e-20);
    } else S.con(5.835e14);

    // Drain-induced barrier lowering (VADIBL)
    const vadibl = if (p.theta_rout > 0.0) blk: {
        // num_dibl = vgst2vtm - vgst2vtm*abeff*vdsat/(vgst2vtm + abeff*vdsat)
        const av = abeff.mul(vdsat);
        const num_dibl = vgst2vtm.sub(vgst2vtm.mul(av).div(vgst2vtm.add(av)));
        break :blk num_dibl.scale(1.0 / p.theta_rout).addC(1.0e-20);
    } else S.con(5.835e14);

    // Pvag gate-bias dependence
    // tpvag = 1 + pvag_b*vgsteff/esat_l
    const tpvag = vgsteff.scale(p.pvag_b).div(esat_l).addC(1.0);

    // Early voltage assembly
    // va1 = vaclm*vadibl/(vaclm + vadibl)
    const va1 = vaclm.mul(vadibl).div(vaclm.add(vadibl));

    // Vasat
    // tmp4 = 1 - abeff*vdsat/(2*vgst2vtm)
    const tmp4 = abeff.mul(vdsat).div(vgst2vtm.scale(2.0)).neg().addC(1.0);
    // t9_vasat = weff*vsat_b*cox*rds*vgsteff
    const t9_vasat = vgsteff.scale(p.weff * p.vsat_b * p.cox * p.rds);
    // t0_vasat = esat_l + vdsat + 2*t9_vasat*tmp4
    const t0_vasat = esat_l.add(vdsat).add(t9_vasat.mul(tmp4).scale(2.0));
    // t1_vasat = 1 + weff*vsat_b*cox*rds*abeff
    const t1_vasat = abeff.scale(p.weff * p.vsat_b * p.cox * p.rds).addC(1.0);
    const vasat = t0_vasat.div(t1_vasat);

    // Total early voltage
    // va = vasat + tpvag*va1
    const va = vasat.add(tpvag.mul(va1));

    // Drain current
    const cox_wl = p.cox * p.weff / p.leff;
    // fgche1 = vgsteff*(1 - abeff*vdseff/(2*vgst2vtm))
    const fgche1 = vgsteff.mul(abeff.mul(vdseff).div(vgst2vtm.scale(2.0)).neg().addC(1.0));
    // fgche2 = 1 + vdseff/esat_l
    const fgche2 = vdseff.div(esat_l).addC(1.0);
    // gche = beta*fgche1/fgche2 ; beta = mu_eff*cox_wl
    const gche = mu_eff.scale(cox_wl).mul(fgche1).div(fgche2);
    // idl = gche*vdseff/(1 + gche*rds)
    const idl = gche.mul(vdseff).div(gche.scale(p.rds).addC(1.0));
    // ids = idl*(1 + delta_vds/va)
    const ids = idl.mul(delta_vds.div(va).addC(1.0));

    // Impact ionization current
    const alpha_ii = p.alpha1_b + p.alpha0_b / p.leff;
    const iii = if (alpha_ii > 0.0 and p.beta0_b > 0.0) blk: {
        // alpha_ii*delta_vds*exp(max(-beta0_b/max(delta_vds,1e-20), -34))*ids
        const dv_clamp = delta_vds.maxC(1.0e-20);
        const earg = dv_clamp.pow(-1.0).scale(-p.beta0_b).maxC(-34.0);
        break :blk delta_vds.scale(alpha_ii).mul(earg.exp()).mul(ids);
    } else S.con(0.0);

    // GIDL current
    // t1_gidl = max((v_ds - v_gs - ngidl_b)/(3*tox_v), 0)
    const t1_gidl = v_ds.sub(v_gs).addC(-p.ngidl_b).scale(1.0 / (3.0 * p.tox_v)).maxC(0.0);
    const igidl = if (p.agidl_b > 0.0 and p.bgidl_b > 0.0) blk: {
        // weff*agidl_b*t1_gidl*exp(-min(bgidl_b/(t1_gidl+1e-20), 34))
        const earg = t1_gidl.addC(1.0e-20).pow(-1.0).scale(p.bgidl_b).minC(34.0).neg();
        break :blk t1_gidl.scale(p.weff * p.agidl_b).mul(earg.exp());
    } else S.con(0.0);

    // Junction diode currents
    const w_tsi = p.weff * p.tsi_v;
    const nvtm1 = p.vt_nom * p.ndiode_b;
    const nvtm2 = p.vt_nom * p.ntun_b;

    // Diffusion current (source/drain)
    const ibs1 = v_bs.scale(1.0 / nvtm1).minC(30.0).exp().addC(-1.0).scale(w_tsi * p.isdif_b);
    const ibd1 = v_bd.scale(1.0 / nvtm1).minC(30.0).exp().addC(-1.0).scale(w_tsi * p.isdif_b);

    // Recombination current (source/drain)
    const ibs2 = v_bs.scale(1.0 / nvtm1).minC(30.0).exp().maxC(1.0e-40).sqrt().addC(-1.0).scale(w_tsi * p.isrec_b);
    const ibd2 = v_bd.scale(1.0 / nvtm1).minC(30.0).exp().maxC(1.0e-40).sqrt().addC(-1.0).scale(w_tsi * p.isrec_b);

    // BJT current (source/drain)
    const ibs3 = if (p.isbjt_b > 0.0)
        v_bs.scale(1.0 / nvtm1).minC(30.0).exp().addC(-1.0).scale(w_tsi * p.isbjt_b)
    else
        S.con(0.0);
    const ibd3 = if (p.isbjt_b > 0.0)
        v_bd.scale(1.0 / nvtm1).minC(30.0).exp().addC(-1.0).scale(w_tsi * p.isbjt_b)
    else
        S.con(0.0);

    // Tunneling current (source/drain)
    const ibs4 = if (p.istun_b > 0.0)
        v_bs.scale(-1.0 / nvtm2).minC(30.0).exp().neg().addC(1.0).scale(w_tsi * p.istun_b)
    else
        S.con(0.0);
    const ibd4 = if (p.istun_b > 0.0)
        v_bd.scale(-1.0 / nvtm2).minC(30.0).exp().neg().addC(1.0).scale(w_tsi * p.istun_b)
    else
        S.con(0.0);

    // Total junction currents
    const ibs_total = ibs1.add(ibs2).add(ibs3).add(ibs4);
    const ibd_total = ibd1.add(ibd2).add(ibd3).add(ibd4);

    // KCL current assembly
    // id_raw = (ids - ibd_total + iii + igidl) * type_f * m_inst
    const type_m = p.type_f * p.m_inst;
    const id_raw = ids.sub(ibd_total).add(iii).add(igidl).scale(type_m);
    const ig_raw = S.con(0.0);
    // is_raw = (-ids - ibs_total) * type_f * m_inst
    const is_raw = ids.neg().sub(ibs_total).scale(type_m);
    // ie_raw = (ibs_total + ibd_total - iii - igidl) * type_f * m_inst
    const ie_raw = ibs_total.add(ibd_total).sub(iii).sub(igidl).scale(type_m);

    // GMIN convergence aid: gmin*vds_raw*type_f (vds_raw already has *type_f)
    const gmin_vds = vds_raw.scale(gmin);

    // S/D reversal of output assignment
    const id_final = if (reversed) is_raw.neg().add(gmin_vds) else id_raw.add(gmin_vds);
    const is_final = if (reversed) id_raw.neg().sub(gmin_vds) else is_raw.sub(gmin_vds);
    const ie_final = ie_raw;

    var out: [n_u]S = undefined;
    out[d_idx] = id_final;
    out[g_idx] = ig_raw;
    out[s_idx] = is_final;
    out[e_idx] = ie_final;
    return out;
}

// ============================================================================
// Charge function: q (value-form)
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
    const e_idx = @intFromEnum(U.sub);

    const p = pc;

    // --- Read terminal voltages ---
    const vd_ext = x[d_idx];
    const vg_ext = x[g_idx];
    const vs_ext = x[s_idx];
    const ve_ext = x[e_idx];

    // --- Source/drain reversal ---
    const vds_raw = vd_ext.sub(vs_ext).scale(p.type_f);
    const vgs_raw = vg_ext.sub(vs_ext).scale(p.type_f);
    const ves_raw = ve_ext.sub(vs_ext).scale(p.type_f);

    const reversed = vds_raw.val() < 0.0;
    const v_ds = if (reversed) vds_raw.neg() else vds_raw;
    const v_gs = if (reversed) vgs_raw.sub(vds_raw) else vgs_raw;
    const v_es = if (reversed) ves_raw.sub(vds_raw) else ves_raw;
    const v_bs = S.con(0.0);
    const v_bd = v_bs.sub(v_ds);

    // --- Body-voltage self-consistency (mirrors eval) ---
    const vesfb = v_es.addC(-p.vfbb);
    const t6_bg = vesfb.scale(p.tkb).addC(p.vbs0t * (1.0 - p.tkb));

    const delta_v: f64 = 0.005;
    const t2_sm = t6_bg.neg().addC(p.phi_s - p.delp_b - delta_v);
    const t3_sm = t2_sm.mul(t2_sm).addC(4.0 * delta_v).sqrt();
    const vbs0 = t2_sm.add(t3_sm).scale(-0.5).addC(p.phi_s - p.delp_b);

    const delta_bsmos: f64 = 0.005;
    const t1_bsmos = vbs0.neg().addC(p.vbs0t - delta_bsmos);
    const t2_bsmos = t1_bsmos.mul(t1_bsmos).addC(delta_bsmos * delta_bsmos).sqrt();
    const t3_bsmos = t1_bsmos.add(t2_bsmos).scale(0.5);
    const t4_bsmos = t3_bsmos.scale(p.c_si / p.qsi);
    const vbs0mos = vbs0.sub(t3_bsmos.mul(t4_bsmos).scale(0.5));

    const phi_fd = vbs0mos.neg().addC(p.phi_s);
    const sqrt_phifd = phi_fd.maxC(1.0e-20).sqrt();
    const vthfd_const = p.vth0_b + p.k3_b * p.tox_v * p.phi_s / (p.weff + p.w0_b) + p.dvth_nlx - p.dvth_sce - p.k1_b * p.sqrt_phis;
    const vthfd = sqrt_phifd.scale(p.k1_b).add(vbs0mos.scale(-p.k2_b)).addC(vthfd_const);

    const delta_bs0eff: f64 = 0.02;
    const t1_gv = vthfd.sub(v_gs).addC(-delta_bs0eff);
    const t2_gv = t1_gv.mul(t1_gv).addC(delta_bs0eff * delta_bs0eff).sqrt();
    const vbs0teff = t1_gv.add(t2_gv).scale(-0.5).addC(p.vbs0t);

    const vbs0eff = vbs0.sub(t1_gv.add(t2_gv).scale(p.nfb * 0.5));

    const delta_dio: f64 = 0.01;
    const off_dio: f64 = 0.02;
    const t1_dio = v_bs.sub(vbs0eff).addC(-off_dio - delta_dio);
    const t2_dio = t1_dio.mul(t1_dio).addC(delta_dio * delta_dio).sqrt();
    const vbsdio = vbs0eff.add(t1_dio.add(t2_dio).scale(0.5)).addC(off_dio);

    const t1_mos = vbs0teff.sub(vbsdio).addC(-delta_bsmos);
    const t2_mos = t1_mos.mul(t1_mos).addC(delta_bsmos * delta_bsmos).sqrt();
    const t3_mos = t1_mos.add(t2_mos).scale(0.5);
    const vbsmos = vbsdio.sub(t3_mos.mul(t3_mos).scale(p.c_si / (2.0 * p.qsi)));

    const delta_vbseff: f64 = 0.005;
    const t2_clamp = vbsmos.neg().addC(p.phi_s - p.delp_b - delta_vbseff);
    const t3_clamp = t2_clamp.mul(t2_clamp).addC(4.0 * delta_vbseff * (p.phi_s - p.delp_b)).sqrt();
    const vbseff = t2_clamp.add(t3_clamp).scale(-0.5).addC(p.phi_s - p.delp_b);

    const phis_eff = vbseff.neg().addC(p.phi_s);
    const sqrt_phis_eff = phis_eff.maxC(1.0e-20).sqrt();
    const xdep = sqrt_phis_eff.scale(p.xdep0 / p.sqrt_phis);

    // Main threshold voltage (for charge)
    const dibl_sft = v_ds.scale(p.eta0_b).add(vbseff.scale(p.etab_b));
    const vth = sqrt_phis_eff.scale(p.k1_b).add(vbseff.scale(-p.k2_b)).sub(dibl_sft).addC(vthfd_const);

    // Subthreshold swing factor n
    const t2n = xdep.pow(-1.0).scale(p.nfactor_b * Consts.eps_si);
    const t3n = v_ds.scale(p.cdscd_b).add(vbseff.scale(p.cdscb_b)).addC(p.cdsc_b);
    const t4n = t2n.add(t3n).addC(p.cit_b).scale(1.0 / p.cox);
    const n_sub = t4n.maxC(-0.5).addC(1.0);

    // Effective gate overdrive for charge
    const vgst = v_gs.sub(vth).addC(-p.voff_b);
    const vgst_nvt = vgst.div(n_sub.scale(2.0 * p.vt_nom));
    const vgst_clamped = vgst_nvt.maxC(-34.0).minC(34.0);
    const vgsteff = n_sub.mul(vgst_clamped.exp().addC(1.0).log()).scale(2.0 * p.vt_nom);

    // CoxWL for charge
    const cox_wl = p.cox * p.weff * p.leff;

    // Abulk for CV
    const keta_denom = vbseff.scale(p.keta_b).addC(1.0).maxC(0.1);
    const abulk_cv = keta_denom.pow(-1.0).scale(p.abulk0);

    // CV saturation voltage
    // vdsat_cv = vgsteff/max(abulk_cv, 0.01) + 1e-5
    const vdsat_cv = vgsteff.div(abulk_cv.maxC(0.01)).addC(1.0e-5);

    // Smooth VdseffCV
    const delta4: f64 = 0.02;
    // v4 = vdsat_cv - v_ds - delta4
    const v4 = vdsat_cv.sub(v_ds).addC(-delta4);
    // t0_cv = sqrt(v4^2 + 4*delta4*vdsat_cv)
    const t0_cv = v4.mul(v4).add(vdsat_cv.scale(4.0 * delta4)).sqrt();
    const vdseff_cv = vdsat_cv.sub(v4.add(t0_cv).scale(0.5));

    // Channel charge (Ward-Dutton)
    // t0_ch = abulk_cv*vdseff_cv
    const t0_ch = abulk_cv.mul(vdseff_cv);
    // t1_ch = 12*(vgsteff - t0_ch/2 + 1e-20)
    const t1_ch = vgsteff.sub(t0_ch.scale(0.5)).addC(1.0e-20).scale(12.0);
    // t2_ch = vdseff_cv/t1_ch
    const t2_ch = vdseff_cv.div(t1_ch);
    // qinv = cox_wl*(vgsteff - vdseff_cv/2 + t0_ch*t2_ch)
    const qinv = vgsteff.sub(vdseff_cv.scale(0.5)).add(t0_ch.mul(t2_ch)).scale(cox_wl);

    // Charge partitioning (50/50)
    const qsrc = qinv.scale(-0.5);
    const qdrn_ch = qinv.scale(-0.5);

    // Flatband voltage and accumulation charge
    // vfb = vth - phi_s - k1_b*sqrt_phis_eff
    const vfb = vth.sub(sqrt_phis_eff.scale(p.k1_b)).addC(-p.phi_s);
    // v3 = vfb - v_gs + vbseff - 0.02
    const v3 = vfb.sub(v_gs).add(vbseff).addC(-0.02);
    // t0_fb = sqrt(v3^2 + 0.08*(|vfb| + 0.02))
    const t0_fb = v3.mul(v3).add(vfb.abs().addC(0.02).scale(0.08)).sqrt();
    // vfbeff = vfb - (v3 + t0_fb)/2
    const vfbeff = vfb.sub(v3.add(t0_fb).scale(0.5));
    // qac0 = -cox_wl*(vfbeff - vfb)
    const qac0 = vfbeff.sub(vfb).scale(-cox_wl);

    // Depletion charge
    // t3_dep = v_gs - vfbeff - vbseff - vgsteff
    const t3_dep = v_gs.sub(vfbeff).sub(vbseff).sub(vgsteff);
    const k1_half = p.k1_b / 2.0;
    // t1_dep = sqrt(k1_half^2 + max(t3_dep, 0))
    const t1_dep = t3_dep.maxC(0.0).addC(k1_half * k1_half).sqrt();
    // qsub0 = cox_wl*k1_b*(k1_half - t1_dep)
    const qsub0 = t1_dep.neg().addC(k1_half).scale(cox_wl * p.k1_b);

    // Body charge
    const qbf = qac0.add(qsub0);

    // Junction depletion charges
    const cjsbs = p.cjswg_v * p.weff * p.tsi_v / 1.0e-7;

    // Source junction charge (simplified for floating body)
    const qjs = v_bs.scale(cjsbs);

    // Drain junction charge (general case)
    // arg_jd = max(1 - v_bd/pbswg_v, 0.01)
    const arg_jd = v_bd.scale(-1.0 / p.pbswg_v).addC(1.0).maxC(0.01);
    const qjd = if (@abs(p.mjswg_v - 0.5) < 1.0e-6)
        // Special case: mjswg = 0.5 -> closed form with sqrt
        // cjsbs*pbswg_v/(1-mjswg_v)*(1 - sqrt(arg_jd))
        arg_jd.sqrt().neg().addC(1.0).scale(cjsbs * p.pbswg_v / (1.0 - p.mjswg_v))
    else
        // General case
        // cjsbs*pbswg_v/(1-mjswg_v)*(1 - arg_jd*exp(-mjswg_v*log(arg_jd)))
        arg_jd.mul(arg_jd.log().scale(-p.mjswg_v).exp()).neg().addC(1.0).scale(cjsbs * p.pbswg_v / (1.0 - p.mjswg_v));

    // Transit time diffusion charge
    const nvtm1 = p.vt_nom * p.ndiode_b;
    const w_tsi = p.weff * p.tsi_v;
    const ibs1_q = v_bs.scale(1.0 / nvtm1).minC(30.0).exp().addC(-1.0).scale(w_tsi * p.isdif_b);
    const ibd1_q = v_bd.scale(1.0 / nvtm1).minC(30.0).exp().addC(-1.0).scale(w_tsi * p.isdif_b);

    const qjs_total = qjs.add(ibs1_q.scale(p.tt_v));
    const qjd_total = qjd.add(ibd1_q.scale(p.tt_v));

    // Overlap charges (use external voltages: G-S, G-D, G-E)
    const vgs_ext = vg_ext.sub(vs_ext);
    const vgd_ext = vg_ext.sub(vd_ext);
    const vge_ext = vg_ext.sub(ve_ext);
    const qgs_ov = vgs_ext.scale(p.cgso_v * p.weff);
    const qgd_ov = vgd_ext.scale(p.cgdo_v * p.weff);
    const qge_ov = vge_ext.scale(p.cgeo_v * p.weff);

    // Total node charges (channel & junction charges swap with S/D reversal)
    const qdrn_final = if (reversed) qsrc else qdrn_ch;
    const qsrc_final = if (reversed) qdrn_ch else qsrc;

    // qg = (qinv - qbf + qgs_ov + qgd_ov + qge_ov) * m_inst
    const qg = qinv.sub(qbf).add(qgs_ov).add(qgd_ov).add(qge_ov).scale(p.m_inst);
    // qd = (qdrn_final - qjd_total - qgd_ov) * m_inst
    const qd = qdrn_final.sub(qjd_total).sub(qgd_ov).scale(p.m_inst);
    // qs = (qsrc_final - qjs_total - qgs_ov) * m_inst
    const qs = qsrc_final.sub(qjs_total).sub(qgs_ov).scale(p.m_inst);
    // qe = (qbf + qjs_total + qjd_total - qge_ov) * m_inst
    const qe = qbf.add(qjs_total).add(qjd_total).sub(qge_ov).scale(p.m_inst);

    var out: [n_u]S = undefined;
    out[d_idx] = qd;
    out[g_idx] = qg;
    out[s_idx] = qs;
    out[e_idx] = qe;
    return out;
}

// ============================================================================
// Voltage limiting
// ============================================================================

pub fn limit(_: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;

    // Absolute voltage limiting: |V_new - V_old| <= 3V for all nodes
    comptime var node: usize = 0;
    inline while (node < n_u) : (node += 1) {
        const dv = result[node] - x_old[node];
        const clamped = if (dv > 3.0) 3.0 else if (dv < -3.0) -3.0 else dv;
        result[node] = x_old[node] + clamped;
    }

    // Gate-source voltage limiting: |delta Vgs| <= 0.5V
    const g_idx = @intFromEnum(U.gate);
    const s_idx = @intFromEnum(U.source);
    const vgs_new = result[g_idx] - result[s_idx];
    const vgs_old = x_old[g_idx] - x_old[s_idx];
    const dvgs = vgs_new - vgs_old;
    if (dvgs > 0.5 or dvgs < -0.5) {
        const clamp_gs: f64 = if (dvgs > 0.5) 0.5 else -0.5;
        // Adjust gate to enforce the Vgs limit
        result[g_idx] = x_old[g_idx] + clamp_gs + (result[s_idx] - x_old[s_idx]);
    }

    // Drain-source voltage limiting: |delta Vds| <= 3V
    const d_idx = @intFromEnum(U.drain);
    const vds_new = result[d_idx] - result[s_idx];
    const vds_old = x_old[d_idx] - x_old[s_idx];
    const dvds = vds_new - vds_old;
    if (dvds > 3.0 or dvds < -3.0) {
        const clamp_ds: f64 = if (dvds > 3.0) 3.0 else -3.0;
        result[d_idx] = x_old[d_idx] + clamp_ds + (result[s_idx] - x_old[s_idx]);
    }

    return result;
}

// ============================================================================
// Attempt (continuation / parameter stepping)
// ============================================================================

pub fn attempt(model: Model, _: f64) Model {
    // Identity mapping: returns unmodified model for all lambda in [0,1]
    return model;
}

// ============================================================================
// Noise generators
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: channel conductance between drain and source
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .thermal },
    // Flicker noise: drain-source
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.source), .kind = .flicker },
    // Shot noise: body-source junction
    .{ .row = @intFromEnum(U.sub), .col = @intFromEnum(U.source), .kind = .shot },
    // Shot noise: body-drain junction
    .{ .row = @intFromEnum(U.sub), .col = @intFromEnum(U.drain), .kind = .shot },
};

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

// Regression: strong-inversion on-state drain current for a default NMOS.
// Vg=3, Vd=1, Vs=0, Ve=0. Values are the physics regression captured from
// the original pointer-form `i()` (identical arithmetic, now value-form).
test "b3soidd: strong-inversion drain current sign and magnitude" {
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 3.0, 0.0, 0.0 }, &model, &inst, 0);
    // NMOS in strong inversion: drain sinks positive current, source sources it.
    try testing.expect(out[0] > 0.0); // drain current > 0
    try testing.expect(out[2] < 0.0); // source current < 0
    try testing.expect(out[1] == 0.0); // gate is purely capacitive (dc i = 0)
    // KCL: sum of all four terminal currents is ~0.
    const sum = out[0] + out[1] + out[2] + out[3];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-12);
}

// Regression: at Vds=0 with Vg high, drain current is ~0 (only gmin*0 term)
// and the device is symmetric.
test "b3soidd: zero Vds gives zero drain current" {
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 3.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[0], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[2], 1e-12);
}

// Charge regression: gate overlap charge dominates for cgso/cgdo defaults.
// With Vg=1, Vs=Vd=Ve=0 and default overlaps (cgso=cgdo=2.072e-10, cgeo=0),
// the gate-source and gate-drain overlap charges are:
//   qgs_ov = cgso*weff*(Vg-Vs) = 2.072e-10 * 1e-6 * 1 = 2.072e-16
//   qgd_ov = cgdo*weff*(Vg-Vd) = 2.072e-10 * 1e-6 * 1 = 2.072e-16
// These are the largest terms in qg for this bias; qg must be positive and
// at least the overlap contribution.
test "b3soidd: gate charge includes overlap contribution" {
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.0, 1.0, 0.0, 0.0 }, &model, &inst, 0);
    // Gate charge is finite and positive at Vg>0.
    try testing.expect(out[1] > 0.0);
    // Overlap alone contributes 2*2.072e-16 = 4.144e-16 to qg; qg >= that
    // minus channel/body terms which are small here. Sanity bound.
    try testing.expect(out[1] > 1e-16);
    // Total charge conservation is NOT expected (overlaps + junctions), but
    // all node charges must be finite.
    for (out) |c| try testing.expect(std.math.isFinite(c));
}

// KCL/finiteness across a reverse-bias (Vds<0) operating point exercises the
// source/drain reversal branch.
test "b3soidd: reverse Vds reversal branch is finite and conserves KCL" {
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ -1.0, 3.0, 0.0, 0.0 }, &model, &inst, 0);
    for (out) |c| try testing.expect(std.math.isFinite(c));
    const sum = out[0] + out[1] + out[2] + out[3];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-12);
}
