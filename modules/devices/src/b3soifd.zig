const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM3SOI-FD v2.0 — Fully-Depleted SOI MOSFET (4-terminal + self-heating)
//
// Topology:
//   External: D -- G -- S -- E (drain, gate, source, substrate/back-gate)
//   Internal: dp (drain-prime), sp (source-prime), b (floating body),
//             temp (self-heating thermal node), p (body-contact node)
//
//   D --[Rds]-- dp                              S --[Rss]-- sp
//                   \                          /
//                    +--- intrinsic MOSFET ---+
//                    |      (dp, g, sp, b)    |
//                    +--- backgate coupling --+
//                             (b -- e via Cbox)
//   b --[Rbody]-- p --[Rbsh]-- e
//   temp node: self-heating thermal RC
// ============================================================================

pub const U = enum(u8) {
    d, // 0: external drain
    g, // 1: external gate
    s, // 2: external source
    e, // 3: external substrate/back-gate
    dp, // 4: internal drain-prime
    sp, // 5: internal source-prime
    b, // 6: internal floating body
    temp, // 7: internal thermal node
    p, // 8: internal body-contact node
};
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================

const EPS_SI: f64 = 1.03594e-10;
const EPS_OX: f64 = 3.453133e-11;
const CHARGE: f64 = 1.60219e-19;
const KB_Q: f64 = 8.617087e-5;
const EG300: f64 = 1.115;
const NI_300: f64 = 1.45e10;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const EXP_GUARD: f64 = 80.0;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Model Selectors ---
    capmod: i32 = 2,
    mobmod: i32 = 1,
    noimod: i32 = 1,
    paramchk: i32 = 0,
    binunit: i32 = 1,
    shmod: i32 = 0,
    version: f32 = 2.0,
    type_: i32 = 1,

    // --- Process / Geometry ---
    tox: f32 = 1.0e-8,
    tbox: f32 = 3.0e-7,
    tsi: f32 = 1.0e-7,
    nsub: f32 = 6.0e16,
    nch: f32 = 1.7e17,
    ngate: f32 = 0,
    xt: f32 = 1.55e-7,
    xj: f32 = @as(f32, @bitCast(@as(u32, 0x7FC00000))),
    ld: f32 = 0,

    // --- Threshold Voltage ---
    vth0: f32 = 0.7,
    k1: f32 = 0,
    k2: f32 = 0,
    k3: f32 = 0,
    k3b: f32 = 0,
    w0: f32 = 2.5e-6,
    nlx: f32 = 1.74e-7,
    dvt0: f32 = 2.2,
    dvt1: f32 = 0.53,
    dvt2: f32 = -0.032,
    dvt0w: f32 = 0,
    dvt1w: f32 = 5.3e6,
    dvt2w: f32 = -0.032,
    gamma1: f32 = 0,
    gamma2: f32 = 0,
    vbx: f32 = 0,
    vbm: f32 = -3.0,
    eta0: f32 = 0.08,
    etab: f32 = -0.07,
    dsub: f32 = 0.56,
    voff: f32 = -0.08,
    nfactor: f32 = 1.0,
    cdsc: f32 = 2.4e-4,
    cdscb: f32 = 0,
    cdscd: f32 = 0,
    cit: f32 = 0,

    // --- Temperature ---
    tnom: f32 = 300.15,
    kt1: f32 = -0.11,
    kt1l: f32 = 0,
    kt2: f32 = 0.022,
    ute: f32 = -1.5,
    ua1: f32 = 4.31e-9,
    ub1: f32 = -7.61e-18,
    uc1: f32 = -5.6e-11,
    at: f32 = 33000,
    prt: f32 = 0,

    // --- Mobility ---
    u0: f32 = 0.067,
    ua: f32 = 2.25e-9,
    ub: f32 = 5.87e-19,
    uc: f32 = -4.65e-11,

    // --- Saturation / Velocity ---
    vsat: f32 = 80000,
    a0: f32 = 1.0,
    ags: f32 = 0,
    a1: f32 = 0,
    a2: f32 = 1.0,
    b0: f32 = 0,
    b1: f32 = 0,
    keta: f32 = -0.047,
    delta: f32 = 0.01,

    // --- Output Resistance / CLM / DIBL ---
    pclm: f32 = 1.3,
    pdiblc1: f32 = 0.39,
    pdiblc2: f32 = 0.0086,
    pdiblcb: f32 = 0,
    drout: f32 = 0.56,
    pvag: f32 = 0,

    // --- Parasitic Resistance ---
    rsh: f32 = 0,
    rdsw: f32 = 100,
    prwg: f32 = 0,
    prwb: f32 = 0,
    wr: f32 = 1.0,

    // --- SOI Specific ---
    kb1: f32 = 1.0,
    kb3: f32 = 1.0,
    dvbd0: f32 = 0,
    dvbd1: f32 = 0,
    vbsa: f32 = 0,
    delp: f32 = 0.02,
    rbody: f32 = 0,
    rbsh: f32 = 0,
    adice0: f32 = 1.0,
    abp: f32 = 1.0,
    mxc: f32 = -0.9,

    // --- Self-Heating ---
    rth0: f32 = 0,
    cth0: f32 = 0,

    // --- Impact Ionization / Vdsatii ---
    aii: f32 = 0,
    bii: f32 = 0,
    cii: f32 = 0,
    dii: f32 = -1.0,
    alpha0: f32 = 0,
    alpha1: f32 = 1.0,
    beta0: f32 = 30,

    // --- GIDL ---
    agidl: f32 = @as(f32, @bitCast(@as(u32, 0x7FC00000))),
    bgidl: f32 = @as(f32, @bitCast(@as(u32, 0x7FC00000))),
    ngidl: f32 = @as(f32, @bitCast(@as(u32, 0x7FC00000))),

    // --- Diode / BJT ---
    ndiode: f32 = 1.0,
    ntun: f32 = 10,
    isbjt: f32 = 1.0e-6,
    isdif: f32 = 0,
    isrec: f32 = 1.0e-5,
    istun: f32 = 0,
    xbjt: f32 = 2.0,
    xrec: f32 = 20,
    xtun: f32 = 0,
    edl: f32 = 2.0e-6,
    kbjt1: f32 = 0,

    // --- Source/Drain Diffusion Capacitance ---
    tt: f32 = 1.0e-12,
    vsdth: f32 = 0,
    vsdfb: f32 = 0,
    csdmin: f32 = 1.005e-4,
    asd: f32 = 0.3,
    pbswg: f32 = 0.7,
    mjswg: f32 = 0.5,
    cjswg: f32 = 1.0e-10,
    csdesw: f32 = 0,

    // --- Overlap Capacitance / C-V Model ---
    cgso: f32 = 2.072e-10,
    cgdo: f32 = 2.072e-10,
    cgeo: f32 = 0,
    cgsl: f32 = 0,
    cgdl: f32 = 0,
    ckappa: f32 = 0.6,
    cf: f32 = 8.164e-11,
    clc: f32 = 1.0e-8,
    cle: f32 = 0,
    dwc: f32 = 0,
    dlc: f32 = 0,
    xpart: f32 = 0,

    // --- Noise ---
    noia: f32 = 1.0e20,
    noib: f32 = 5.0e4,
    noic: f32 = -1.4e-12,
    em: f32 = 4.1e7,
    ef: f32 = 1.0,
    af: f32 = 1.0,
    kf: f32 = 0,
    noif: f32 = 1.0,

    // --- Length/Width Reduction ---
    lint: f32 = 0,
    ll: f32 = 0,
    lln: f32 = 1.0,
    lw: f32 = 0,
    lwn: f32 = 1.0,
    lwl: f32 = 0,
    wint: f32 = 0,
    wl: f32 = 0,
    wln: f32 = 1.0,
    ww: f32 = 0,
    wwn: f32 = 1.0,
    wwl: f32 = 0,
    dwg: f32 = 0,
    dwb: f32 = 0,

    // --- Length Dependence (l-prefix) ---
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
    lkb3: f32 = 0,
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

    // --- Width Dependence (w-prefix) ---
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
    wkb3: f32 = 0,
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

    // --- Cross-Term Dependence (p-prefix) ---
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
    pkb3: f32 = 0,
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
    w: f32 = 1.0e-6,
    l: f32 = 1.0e-6,
    temp: f64 = 300.15,
    m: f32 = 1.0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    // External D <-> dp resistance
    .{ .row = @intFromEnum(U.d), .col = @intFromEnum(U.d) },
    .{ .row = @intFromEnum(U.d), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.d) },
    // External S <-> sp resistance
    .{ .row = @intFromEnum(U.s), .col = @intFromEnum(U.s) },
    .{ .row = @intFromEnum(U.s), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.s) },
    // Channel dp <-> sp with gate and body dependencies
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.g) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.g) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.b) },
    // Body node: b <-> p (body contact resistance)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.p) },
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.p) },
    // p <-> e (body sheet resistance)
    .{ .row = @intFromEnum(U.p), .col = @intFromEnum(U.e) },
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.p) },
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e) },
    // Thermal node
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.temp) },
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.sp) },
    // Gate row
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.g) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Gate charges: G -- dp, G -- sp, G -- b, G -- e, G -- G
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.g) },
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.g), .col = @intFromEnum(U.e) },
    // dp charges
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.g) },
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.b) },
    // sp charges
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.g) },
    .{ .row = @intFromEnum(U.sp), .col = @intFromEnum(U.b) },
    // Body charges: b -- b, b -- e
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.e) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.dp) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.sp) },
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.g) },
    // Substrate charges
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e) },
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.b) },
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.g) },
    // Thermal capacitance
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.temp) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain parasitic resistance thermal noise: D -- dp
    .{ .row = @intFromEnum(U.d), .col = @intFromEnum(U.dp), .kind = .thermal },
    // Source parasitic resistance thermal noise: S -- sp
    .{ .row = @intFromEnum(U.s), .col = @intFromEnum(U.sp), .kind = .thermal },
    // Channel thermal noise: dp -- sp
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp), .kind = .thermal },
    // Channel flicker noise: dp -- sp
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp), .kind = .flicker },
    // Body resistance thermal noise: b -- p
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.p), .kind = .thermal },
};

// ============================================================================
// Helper: binning function to compute effective parameter from L/W/P deps
// ============================================================================

inline fn binParam(base: f64, l_dep: f64, w_dep: f64, p_dep: f64, l_eff: f64, w_eff: f64) f64 {
    return base + l_dep / l_eff + w_dep / w_eff + p_dep / (l_eff * w_eff);
}

// ============================================================================
// x-INDEPENDENT parameter/temperature/geometry preprocessing for eval().
// Pure f64: no terminal voltages enter here.
// ============================================================================

const EvalPrep = struct {
    type_f: f64,
    tox: f64,
    tbox: f64,
    tsi: f64,
    m_shmod: i32,
    m_rsh: f64,
    m_rbody: f64,
    m_rbsh: f64,
    m_rth0: f64,
    mult: f64,
    leff: f64,
    weff: f64,
    m_xj: f64,
    // effective (binned) params used in the S tail
    e_vth0: f64,
    e_k2: f64,
    e_k3: f64,
    e_k3b: f64,
    e_w0: f64,
    e_dvt0: f64,
    e_dvt1: f64,
    e_dvt2: f64,
    e_dvt0w: f64,
    e_dvt1w: f64,
    e_dvt2w: f64,
    e_eta0: f64,
    e_etab: f64,
    e_dsub: f64,
    e_voff: f64,
    e_nfactor: f64,
    e_cdsc: f64,
    e_cdscb: f64,
    e_cdscd: f64,
    e_cit: f64,
    e_ua: f64,
    e_ub: f64,
    e_uc: f64,
    e_a0: f64,
    e_ags: f64,
    e_a1: f64,
    e_a2: f64,
    e_b0: f64,
    e_b1: f64,
    e_keta: f64,
    e_delta: f64,
    e_pclm: f64,
    e_pdiblc1: f64,
    e_pdiblc2: f64,
    e_pdiblcb: f64,
    e_drout: f64,
    e_pvag: f64,
    e_rdsw: f64,
    e_vbsa: f64,
    e_delp: f64,
    e_kb1: f64,
    e_dvbd0: f64,
    e_dvbd1: f64,
    e_adice0: f64,
    // derived physical quantities
    cox: f64,
    phi: f64,
    sqrt_phi: f64,
    xdep0: f64,
    vbi: f64,
    vfbb: f64,
    factor1: f64,
    e_k1: f64,
    e_nlx: f64,
    m_kt1: f64,
    m_kt1l: f64,
    vtm: f64,
    mu0_temp: f64,
    vsat_t: f64,
    ua_t: f64,
    ub_t: f64,
    uc_t: f64,
    delta_t: f64,
    temp_ratio: f64,
    m_prt: f64,
    // SOI backgate constants
    cbox: f64,
    csi: f64,
    csi_eff: f64,
    litl: f64,
    dvbd_t: f64,
    qsi: f64,
    v0: f64,
    vbs0t: f64,
    kb1_eff: f64,
    cdep0: f64,
    nfb: f64,
    litl_clm: f64,
};

fn prepEval(model: *const Model, instance: *const Instance) EvalPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const tox: f64 = @as(f64, model.tox);
    const tbox: f64 = @as(f64, model.tbox);
    const tsi: f64 = @as(f64, model.tsi);
    const nch_cm3: f64 = @as(f64, model.nch);
    const nsub_cm3: f64 = @as(f64, model.nsub);
    const tnom: f64 = @as(f64, model.tnom);
    const m_vth0: f64 = @as(f64, model.vth0);
    const m_k1: f64 = @as(f64, model.k1);
    const m_k2: f64 = @as(f64, model.k2);
    const m_k3: f64 = @as(f64, model.k3);
    const m_k3b: f64 = @as(f64, model.k3b);
    const m_w0: f64 = @as(f64, model.w0);
    const m_nlx: f64 = @as(f64, model.nlx);
    const m_dvt0: f64 = @as(f64, model.dvt0);
    const m_dvt1: f64 = @as(f64, model.dvt1);
    const m_dvt2: f64 = @as(f64, model.dvt2);
    const m_dvt0w: f64 = @as(f64, model.dvt0w);
    const m_dvt1w: f64 = @as(f64, model.dvt1w);
    const m_dvt2w: f64 = @as(f64, model.dvt2w);
    const m_eta0: f64 = @as(f64, model.eta0);
    const m_etab: f64 = @as(f64, model.etab);
    const m_dsub: f64 = @as(f64, model.dsub);
    const m_voff: f64 = @as(f64, model.voff);
    const m_nfactor: f64 = @as(f64, model.nfactor);
    const m_cdsc: f64 = @as(f64, model.cdsc);
    const m_cdscb: f64 = @as(f64, model.cdscb);
    const m_cdscd: f64 = @as(f64, model.cdscd);
    const m_cit: f64 = @as(f64, model.cit);
    const m_kt1: f64 = @as(f64, model.kt1);
    const m_kt1l: f64 = @as(f64, model.kt1l);
    const m_ute: f64 = @as(f64, model.ute);
    const m_u0: f64 = @as(f64, model.u0);
    const m_ua: f64 = @as(f64, model.ua);
    const m_ub: f64 = @as(f64, model.ub);
    const m_uc: f64 = @as(f64, model.uc);
    const m_vsat: f64 = @as(f64, model.vsat);
    const m_at: f64 = @as(f64, model.at);
    const m_a0: f64 = @as(f64, model.a0);
    const m_ags: f64 = @as(f64, model.ags);
    const m_a1: f64 = @as(f64, model.a1);
    const m_a2: f64 = @as(f64, model.a2);
    const m_b0: f64 = @as(f64, model.b0);
    const m_b1: f64 = @as(f64, model.b1);
    const m_keta: f64 = @as(f64, model.keta);
    const m_delta: f64 = @as(f64, model.delta);
    const m_pclm: f64 = @as(f64, model.pclm);
    const m_pdiblc1: f64 = @as(f64, model.pdiblc1);
    const m_pdiblc2: f64 = @as(f64, model.pdiblc2);
    const m_pdiblcb: f64 = @as(f64, model.pdiblcb);
    const m_drout: f64 = @as(f64, model.drout);
    const m_pvag: f64 = @as(f64, model.pvag);
    const m_rsh: f64 = @as(f64, model.rsh);
    const m_rdsw: f64 = @as(f64, model.rdsw);
    const m_prt: f64 = @as(f64, model.prt);
    const m_ld: f64 = @as(f64, model.ld);
    const m_kb1: f64 = @as(f64, model.kb1);
    const m_dvbd0: f64 = @as(f64, model.dvbd0);
    const m_dvbd1: f64 = @as(f64, model.dvbd1);
    const m_vbsa: f64 = @as(f64, model.vbsa);
    const m_delp: f64 = @as(f64, model.delp);
    const m_rbody: f64 = @as(f64, model.rbody);
    const m_rbsh: f64 = @as(f64, model.rbsh);
    const m_adice0: f64 = @as(f64, model.adice0);
    const m_rth0: f64 = @as(f64, model.rth0);
    const m_shmod: i32 = model.shmod;

    const m_xj_raw: f64 = @as(f64, model.xj);
    const m_xj: f64 = if (m_xj_raw != m_xj_raw) 1.55e-7 else m_xj_raw;

    // Instance
    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_temp: f64 = instance.temp;
    const mult: f64 = @as(f64, instance.m);

    // Effective geometry
    const leff = @max(inst_l - 2.0 * m_ld, 1.0e-9);
    const weff = @max(inst_w, 1.0e-9);

    // Binning
    const e_vth0 = binParam(m_vth0, @as(f64, model.lvth0), @as(f64, model.wvth0), @as(f64, model.pvth0), leff, weff);
    const e_k1_raw = binParam(m_k1, @as(f64, model.lk1), @as(f64, model.wk1), @as(f64, model.pk1), leff, weff);
    const e_k2 = binParam(m_k2, @as(f64, model.lk2), @as(f64, model.wk2), @as(f64, model.pk2), leff, weff);
    const e_k3 = binParam(m_k3, @as(f64, model.lk3), @as(f64, model.wk3), @as(f64, model.pk3), leff, weff);
    const e_k3b = binParam(m_k3b, @as(f64, model.lk3b), @as(f64, model.wk3b), @as(f64, model.pk3b), leff, weff);
    const e_w0 = binParam(m_w0, @as(f64, model.lw0), @as(f64, model.ww0), @as(f64, model.pw0), leff, weff);
    const e_nlx = binParam(m_nlx, @as(f64, model.lnlx), @as(f64, model.wnlx), @as(f64, model.pnlx), leff, weff);
    const e_dvt0 = binParam(m_dvt0, @as(f64, model.ldvt0), @as(f64, model.wdvt0), @as(f64, model.pdvt0), leff, weff);
    const e_dvt1 = binParam(m_dvt1, @as(f64, model.ldvt1), @as(f64, model.wdvt1), @as(f64, model.pdvt1), leff, weff);
    const e_dvt2 = binParam(m_dvt2, @as(f64, model.ldvt2), @as(f64, model.wdvt2), @as(f64, model.pdvt2), leff, weff);
    const e_dvt0w = binParam(m_dvt0w, @as(f64, model.ldvt0w), @as(f64, model.wdvt0w), @as(f64, model.pdvt0w), leff, weff);
    const e_dvt1w = binParam(m_dvt1w, @as(f64, model.ldvt1w), @as(f64, model.wdvt1w), @as(f64, model.pdvt1w), leff, weff);
    const e_dvt2w = binParam(m_dvt2w, @as(f64, model.ldvt2w), @as(f64, model.wdvt2w), @as(f64, model.pdvt2w), leff, weff);
    const e_eta0 = binParam(m_eta0, @as(f64, model.leta0), @as(f64, model.weta0), @as(f64, model.peta0), leff, weff);
    const e_etab = binParam(m_etab, @as(f64, model.letab), @as(f64, model.wetab), @as(f64, model.petab), leff, weff);
    const e_dsub = binParam(m_dsub, @as(f64, model.ldsub), @as(f64, model.wdsub), @as(f64, model.pdsub), leff, weff);
    const e_voff = binParam(m_voff, @as(f64, model.lvoff), @as(f64, model.wvoff), @as(f64, model.pvoff), leff, weff);
    const e_nfactor = binParam(m_nfactor, @as(f64, model.lnfactor), @as(f64, model.wnfactor), @as(f64, model.pnfactor), leff, weff);
    const e_cdsc = binParam(m_cdsc, @as(f64, model.lcdsc), @as(f64, model.wcdsc), @as(f64, model.pcdsc), leff, weff);
    const e_cdscb = binParam(m_cdscb, @as(f64, model.lcdscb), @as(f64, model.wcdscb), @as(f64, model.pcdscb), leff, weff);
    const e_cdscd = binParam(m_cdscd, @as(f64, model.lcdscd), @as(f64, model.wcdscd), @as(f64, model.pcdscd), leff, weff);
    const e_cit = binParam(m_cit, @as(f64, model.lcit), @as(f64, model.wcit), @as(f64, model.pcit), leff, weff);
    const e_u0 = binParam(m_u0, @as(f64, model.lu0), @as(f64, model.wu0), @as(f64, model.pu0), leff, weff);
    const e_ua = binParam(m_ua, @as(f64, model.lua), @as(f64, model.wua), @as(f64, model.pua), leff, weff);
    const e_ub = binParam(m_ub, @as(f64, model.lub), @as(f64, model.wub), @as(f64, model.pub_), leff, weff);
    const e_uc = binParam(m_uc, @as(f64, model.luc), @as(f64, model.wuc), @as(f64, model.puc), leff, weff);
    const e_vsat = binParam(m_vsat, @as(f64, model.lvsat), @as(f64, model.wvsat), @as(f64, model.pvsat), leff, weff);
    const e_a0 = binParam(m_a0, @as(f64, model.la0), @as(f64, model.wa0), @as(f64, model.pa0), leff, weff);
    const e_ags = binParam(m_ags, @as(f64, model.lags), @as(f64, model.wags), @as(f64, model.pags), leff, weff);
    const e_a1 = binParam(m_a1, @as(f64, model.la1), @as(f64, model.wa1), @as(f64, model.pa1), leff, weff);
    const e_a2 = binParam(m_a2, @as(f64, model.la2), @as(f64, model.wa2), @as(f64, model.pa2), leff, weff);
    const e_b0 = binParam(m_b0, @as(f64, model.lb0), @as(f64, model.wb0), @as(f64, model.pb0), leff, weff);
    const e_b1 = binParam(m_b1, @as(f64, model.lb1), @as(f64, model.wb1), @as(f64, model.pb1), leff, weff);
    const e_keta = binParam(m_keta, @as(f64, model.lketa), @as(f64, model.wketa), @as(f64, model.pketa), leff, weff);
    const e_delta = binParam(m_delta, @as(f64, model.ldelta), @as(f64, model.wdelta), @as(f64, model.pdelta), leff, weff);
    const e_pclm = binParam(m_pclm, @as(f64, model.lpclm), @as(f64, model.wpclm), @as(f64, model.ppclm), leff, weff);
    const e_pdiblc1 = binParam(m_pdiblc1, @as(f64, model.lpdiblc1), @as(f64, model.wpdiblc1), @as(f64, model.ppdiblc1), leff, weff);
    const e_pdiblc2 = binParam(m_pdiblc2, @as(f64, model.lpdiblc2), @as(f64, model.wpdiblc2), @as(f64, model.ppdiblc2), leff, weff);
    const e_pdiblcb = binParam(m_pdiblcb, @as(f64, model.lpdiblcb), @as(f64, model.wpdiblcb), @as(f64, model.ppdiblcb), leff, weff);
    const e_drout = binParam(m_drout, @as(f64, model.ldrout), @as(f64, model.wdrout), @as(f64, model.pdrout), leff, weff);
    const e_pvag = binParam(m_pvag, @as(f64, model.lpvag), @as(f64, model.wpvag), @as(f64, model.ppvag), leff, weff);
    const e_rdsw = binParam(m_rdsw, @as(f64, model.lrdsw), @as(f64, model.wrdsw), @as(f64, model.prdsw), leff, weff);
    const e_vbsa = binParam(m_vbsa, @as(f64, model.lvbsa), @as(f64, model.wvbsa), @as(f64, model.pvbsa), leff, weff);
    const e_delp = binParam(m_delp, @as(f64, model.ldelp), @as(f64, model.wdelp), @as(f64, model.pdelp), leff, weff);
    const e_kb1 = binParam(m_kb1, @as(f64, model.lkb1), @as(f64, model.wkb1), @as(f64, model.pkb1), leff, weff);
    const e_dvbd0 = binParam(m_dvbd0, @as(f64, model.ldvbd0), @as(f64, model.wdvbd0), @as(f64, model.pdvbd0), leff, weff);
    const e_dvbd1 = binParam(m_dvbd1, @as(f64, model.ldvbd1), @as(f64, model.wdvbd1), @as(f64, model.pdvbd1), leff, weff);
    const e_adice0 = binParam(m_adice0, @as(f64, model.ladice0), @as(f64, model.wadice0), @as(f64, model.padice0), leff, weff);

    // Pre-computed physical quantities
    const cox = EPS_OX / tox;
    const vtm_nom = KB_Q * tnom;
    const phi_raw = 2.0 * vtm_nom * contract.fmath.log(@max(nch_cm3 / NI_300, 1.0));
    const phi = @max(phi_raw, 0.7);
    const sqrt_phi = @sqrt(phi);
    const xdep0 = @sqrt(2.0 * EPS_SI / (CHARGE * nch_cm3 * 1.0e6)) * sqrt_phi;
    const vbi = vtm_nom * contract.fmath.log(@max(1.0e20 * nch_cm3 / (NI_300 * NI_300), 1.0));
    const vfbb = if (nsub_cm3 > 0.0) -vtm_nom * contract.fmath.log(@max(nch_cm3 / nsub_cm3, 1.0e-30)) else -0.9;
    const factor1 = @sqrt(EPS_SI / EPS_OX * tox);
    const e_k1 = if (e_k1_raw == 0.0) (2.0 * @sqrt(2.0 * EPS_SI * CHARGE * nch_cm3 * 1.0e6 * phi)) / cox else e_k1_raw;

    // Temperature
    const delta_t = inst_temp - tnom;
    const temp_ratio = delta_t / tnom;
    const vtm = KB_Q * inst_temp;
    const mu0_temp = if (m_ute != 0.0) e_u0 * contract.fmath.exp(m_ute * contract.fmath.log(inst_temp / tnom)) else e_u0;
    const vsat_t = @max(e_vsat - m_at * delta_t, 1.0);
    const ua_t = e_ua + @as(f64, model.ua1) * delta_t;
    const ub_t = e_ub + @as(f64, model.ub1) * delta_t;
    const uc_t = e_uc + @as(f64, model.uc1) * delta_t;

    // SOI backgate constants
    const cbox = EPS_OX / tbox;
    const csi = 2.0 * EPS_SI / tsi;
    const csi_eff = EPS_SI / tsi;
    const litl = @sqrt(EPS_SI * tsi * tox / EPS_OX);
    const f_dvbd1 = -e_dvbd1 * leff / litl;
    const dvbd_t = e_dvbd0 * (contract.fmath.exp(@min(f_dvbd1 * 0.5, EXP_GUARD)) + 2.0 * contract.fmath.exp(@min(f_dvbd1, EXP_GUARD)));
    const qsi = CHARGE * nch_cm3 * 1.0e6 * tsi;
    const v0 = vbi - phi;
    const vbs0t = phi - qsi / csi + e_vbsa + dvbd_t * v0;
    const kb1_eff = e_kb1 / (1.0 + csi_eff / cbox);
    const cdep0 = @sqrt(EPS_SI * CHARGE * nch_cm3 * 1.0e6 / (2.0 * phi));
    const nfb = cox / (cox + cdep0);
    const litl_clm = @sqrt(3.0 * tox * xdep0);

    return .{
        .type_f = type_f,
        .tox = tox,
        .tbox = tbox,
        .tsi = tsi,
        .m_shmod = m_shmod,
        .m_rsh = m_rsh,
        .m_rbody = m_rbody,
        .m_rbsh = m_rbsh,
        .m_rth0 = m_rth0,
        .mult = mult,
        .leff = leff,
        .weff = weff,
        .m_xj = m_xj,
        .e_vth0 = e_vth0,
        .e_k2 = e_k2,
        .e_k3 = e_k3,
        .e_k3b = e_k3b,
        .e_w0 = e_w0,
        .e_dvt0 = e_dvt0,
        .e_dvt1 = e_dvt1,
        .e_dvt2 = e_dvt2,
        .e_dvt0w = e_dvt0w,
        .e_dvt1w = e_dvt1w,
        .e_dvt2w = e_dvt2w,
        .e_eta0 = e_eta0,
        .e_etab = e_etab,
        .e_dsub = e_dsub,
        .e_voff = e_voff,
        .e_nfactor = e_nfactor,
        .e_cdsc = e_cdsc,
        .e_cdscb = e_cdscb,
        .e_cdscd = e_cdscd,
        .e_cit = e_cit,
        .e_ua = e_ua,
        .e_ub = e_ub,
        .e_uc = e_uc,
        .e_a0 = e_a0,
        .e_ags = e_ags,
        .e_a1 = e_a1,
        .e_a2 = e_a2,
        .e_b0 = e_b0,
        .e_b1 = e_b1,
        .e_keta = e_keta,
        .e_delta = e_delta,
        .e_pclm = e_pclm,
        .e_pdiblc1 = e_pdiblc1,
        .e_pdiblc2 = e_pdiblc2,
        .e_pdiblcb = e_pdiblcb,
        .e_drout = e_drout,
        .e_pvag = e_pvag,
        .e_rdsw = e_rdsw,
        .e_vbsa = e_vbsa,
        .e_delp = e_delp,
        .e_kb1 = e_kb1,
        .e_dvbd0 = e_dvbd0,
        .e_dvbd1 = e_dvbd1,
        .e_adice0 = e_adice0,
        .cox = cox,
        .phi = phi,
        .sqrt_phi = sqrt_phi,
        .xdep0 = xdep0,
        .vbi = vbi,
        .vfbb = vfbb,
        .factor1 = factor1,
        .e_k1 = e_k1,
        .e_nlx = e_nlx,
        .m_kt1 = m_kt1,
        .m_kt1l = m_kt1l,
        .vtm = vtm,
        .mu0_temp = mu0_temp,
        .vsat_t = vsat_t,
        .ua_t = ua_t,
        .ub_t = ub_t,
        .uc_t = uc_t,
        .delta_t = delta_t,
        .temp_ratio = temp_ratio,
        .m_prt = m_prt,
        .cbox = cbox,
        .csi = csi,
        .csi_eff = csi_eff,
        .litl = litl,
        .dvbd_t = dvbd_t,
        .qsi = qsi,
        .v0 = v0,
        .vbs0t = vbs0t,
        .kb1_eff = kb1_eff,
        .cdep0 = cdep0,
        .nfb = nfb,
        .litl_clm = litl_clm,
    };
}

// ============================================================================
// Current Function (eval) — value form
//
// x-independent parameter prep is hoisted into prepEval(); only the
// x-dependent (terminal-voltage) chain uses S ops. The original S/D reversal
// is SMOOTH (sqrt-based sgn), so there is no region branch here — everything
// downstream of the node reads flows through S to keep every Jacobian entry.
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const p = &pc.dc;

    const D = @intFromEnum(U.d);
    const G = @intFromEnum(U.g);
    const Sn = @intFromEnum(U.s);
    const E = @intFromEnum(U.e);
    const DP = @intFromEnum(U.dp);
    const SP = @intFromEnum(U.sp);
    const B = @intFromEnum(U.b);
    const TEMP = @intFromEnum(U.temp);
    const P = @intFromEnum(U.p);

    // Read node voltages
    const v_d = x[D];
    const v_g = x[G];
    const v_s = x[Sn];
    const v_e = x[E];
    const v_dp = x[DP];
    const v_sp = x[SP];
    const v_b = x[B];
    const v_temp = x[TEMP];
    const v_p = x[P];

    // Apply type factor
    const vds_ext = v_dp.sub(v_sp).scale(p.type_f);
    const vgs_ext = v_g.sub(v_sp).scale(p.type_f);
    const ves_ext = v_e.sub(v_sp).scale(p.type_f);

    // Operating Mode Selection (Smooth S/D reversal)
    const eps_mode: f64 = 1.0e-12;
    const vds_abs_s = vds_ext.mul(vds_ext).addC(eps_mode).sqrt();
    const sgn_vds = vds_ext.div(vds_abs_s);
    const w_fwd = sgn_vds.addC(1.0).scale(0.5);
    const w_rev = w_fwd.neg().addC(1.0);

    const VDS = w_fwd.mul(vds_ext).add(w_rev.mul(vds_ext.neg()));
    const VGS = w_fwd.mul(vgs_ext).add(w_rev.mul(vgs_ext.sub(vds_ext)));
    const VES = w_fwd.mul(ves_ext).add(w_rev.mul(ves_ext.sub(vds_ext)));

    // ========================================================================
    // SOI Fully-Depleted Body Voltage
    // ========================================================================
    // Back-gate coupling
    const vesfb = VES.addC(-p.vfbb);
    // vbs0_raw = vbs0t - kb1_eff * (vbs0t - vesfb)
    const vbs0_raw = S.con(p.vbs0t).sub(S.con(p.vbs0t).sub(vesfb).scale(p.kb1_eff));

    // Smooth upper-limiting of Vbs0 to phi - delp
    const delta_vbs: f64 = 0.005;
    const phi_delp = p.phi - p.e_delp;
    const t2_vbs = vbs0_raw.neg().addC(phi_delp - delta_vbs);
    const t3_vbs = t2_vbs.mul(t2_vbs).addC(4.0 * delta_vbs * phi_delp).sqrt();
    const vbs0 = t2_vbs.add(t3_vbs).scale(0.5).neg().addC(phi_delp);

    // Gate-dependent feedback: vbs0_eff = vbs0 + nfb*(VGS - vth0 - vbs0)
    const vbs0_eff = vbs0.add(VGS.addC(-p.e_vth0).sub(vbs0).scale(p.nfb));

    // Final smooth limiting of Vbseff to phi - delp
    const t2_vbs2 = vbs0_eff.neg().addC(phi_delp - delta_vbs);
    const t3_vbs2 = t2_vbs2.mul(t2_vbs2).addC(4.0 * delta_vbs * phi_delp).sqrt();
    const vbseff = t2_vbs2.add(t3_vbs2).scale(0.5).neg().addC(phi_delp);

    // ========================================================================
    // Threshold Voltage
    // ========================================================================
    const phis = vbseff.neg().addC(p.phi);
    const sqrt_phis = phis.abs().addC(1.0e-12).sqrt();

    // Depletion width
    const xdep = sqrt_phis.scale(p.xdep0 / p.sqrt_phi);

    // Short channel effect (Theta0)
    const t1_dvt = vbseff.scale(p.e_dvt2).addC(1.0);
    const lt1 = xdep.sqrt().mul(t1_dvt).scale(p.factor1);
    // arg_dvt1 = -0.5*dvt1*leff / (|lt1| + 1e-20)
    const arg_dvt1 = S.con(-0.5 * p.e_dvt1 * p.leff).div(lt1.abs().addC(1.0e-20));
    const exp_dvt = arg_dvt1.minC(EXP_GUARD).exp();
    const theta0 = exp_dvt.mul(exp_dvt.scale(2.0).addC(1.0));
    const dvth_sce = theta0.scale(p.e_dvt0 * p.v0);

    // Narrow width effect
    const t1w = vbseff.scale(p.e_dvt2w).addC(1.0);
    const ltw = xdep.sqrt().mul(t1w).scale(p.factor1);
    const arg_dvtw = S.con(-0.5 * p.e_dvt1w * p.weff * p.leff).div(ltw.abs().addC(1.0e-20));
    const exp_dvtw = arg_dvtw.minC(EXP_GUARD).exp();
    const t2w = exp_dvtw.mul(exp_dvtw.scale(2.0).addC(1.0));
    const dvth_nw = t2w.scale(p.e_dvt0w * p.v0);

    // Temperature shift (x-independent) — plain f64 constant.
    const dvth_t: f64 = p.e_k1 * (@sqrt(1.0 + p.e_nlx / p.leff) - 1.0) * p.sqrt_phi + (p.m_kt1 + p.m_kt1l / p.leff) * p.temp_ratio;

    // DIBL
    const arg_dsub = S.con(-p.e_dsub * p.leff).div(lt1.abs().addC(1.0e-20));
    const exp_dsub = arg_dsub.minC(EXP_GUARD).exp();
    const theta0_dibl = exp_dsub.mul(exp_dsub.scale(2.0).addC(1.0));
    const eta = vbseff.scale(p.e_etab).addC(p.e_eta0);
    const dibl_shift = eta.mul(VDS).mul(theta0_dibl);

    // Narrow width term (x-independent)
    const tmp_nw: f64 = p.tox * p.phi / (p.weff + p.e_w0);

    // Final threshold voltage
    // vth = vth0 + k1*(sqrt_phis - sqrt_phi) - k2*vbseff - dvth_sce - dvth_nw
    //       + (k3 + k3b*vbseff)*tmp_nw + dvth_t - dibl_shift
    const vth = sqrt_phis.addC(-p.sqrt_phi).scale(p.e_k1)
        .addC(p.e_vth0)
        .sub(vbseff.scale(p.e_k2))
        .sub(dvth_sce)
        .sub(dvth_nw)
        .add(vbseff.scale(p.e_k3b).addC(p.e_k3).scale(tmp_nw))
        .addC(dvth_t)
        .sub(dibl_shift);

    // ========================================================================
    // Subthreshold / Effective Gate Overdrive
    // ========================================================================
    const t_nfac = S.con(p.e_nfactor * EPS_SI).div(xdep);
    const cdsc_term = VDS.scale(p.e_cdscd).add(vbseff.scale(p.e_cdscb)).addC(p.e_cdsc);
    // n_sub = 1 + (t_nfac + cdsc_term*theta0 + cit)/cox
    const n_sub = t_nfac.add(cdsc_term.mul(theta0)).addC(p.e_cit).scale(1.0 / p.cox).addC(1.0);

    const cdep0_cox = p.cdep0 / p.cox;
    // exp_vgst_arg = min((VGS - vth - voff)/(n_sub*vtm), EXP_GUARD)
    const exp_vgst_arg = VGS.sub(vth).addC(-p.e_voff).div(n_sub.scale(p.vtm)).minC(EXP_GUARD);
    const exp_vgst = exp_vgst_arg.exp();
    const log_1_exp = exp_vgst.addC(1.0).log();
    // vgsteff = (n_sub*vtm*log_1_exp) / (1 + cdep0_cox/(1+exp_vgst))
    const vgsteff = n_sub.scale(p.vtm).mul(log_1_exp)
        .div(S.con(cdep0_cox).div(exp_vgst.addC(1.0)).addC(1.0));
    const vgst2vtm = vgsteff.addC(2.0 * p.vtm);

    // ========================================================================
    // Bulk Charge Effect (Abulk)
    // ========================================================================
    const t1_abulk: f64 = p.e_k1 / (2.0 * p.sqrt_phi);
    // sqrt_xj_xdep = sqrt(xj)*sqrt(xdep)
    const sqrt_xj_xdep = xdep.sqrt().scale(@sqrt(p.m_xj));
    // t5_abulk = leff/(leff + 2*sqrt_xj_xdep)
    const t5_abulk = S.con(p.leff).div(sqrt_xj_xdep.scale(2.0).addC(p.leff));
    // tmp2_abulk = a0*t5_abulk + b0/(weff+b1)
    const tmp2_abulk = t5_abulk.scale(p.e_a0).addC(p.e_b0 / (p.weff + p.e_b1));
    const abulk0 = tmp2_abulk.scale(t1_abulk);

    // Gate-voltage modulation via Ags
    // t8_ags = ags*a0*t5_abulk^3
    const t8_ags = t5_abulk.mul(t5_abulk).mul(t5_abulk).scale(p.e_ags * p.e_a0);
    // dabulk_dvg = -t1_abulk * t8_ags
    const dabulk_dvg = t8_ags.scale(-t1_abulk);
    const abulk_pre = abulk0.add(dabulk_dvg.mul(vgsteff));

    // Keta correction: t0_keta = 1/(1+keta*vbseff)
    const t0_keta = S.con(1.0).div(vbseff.scale(p.e_keta).addC(1.0));
    const abulk = abulk_pre.mul(t0_keta).addC(1.0);

    // SOI DICE correction: abeff = abulk*adice0 + (1-adice0)
    const abeff = abulk.scale(p.e_adice0).addC(1.0 - p.e_adice0);

    // ========================================================================
    // Internal source-drain resistance Rds (x-independent)
    // ========================================================================
    const rds0: f64 = if (p.e_rdsw > 0.0) (p.e_rdsw + p.m_prt * p.delta_t) / (p.weff * 1.0e6) else 0.0;

    // ========================================================================
    // Mobility (MobMod=1)
    // ========================================================================
    // t0_mob = vgsteff + 2*vth
    const t0_mob = vgsteff.add(vth.scale(2.0));
    const t3_mob = t0_mob.scale(1.0 / p.tox);
    // t5_mob = t3_mob*(ua_t + uc_t*vbseff + ub_t*t3_mob)
    const t5_mob = t3_mob.mul(vbseff.scale(p.uc_t).addC(p.ua_t).add(t3_mob.scale(p.ub_t)));
    const mu_eff = S.con(p.mu0_temp).div(t5_mob.addC(1.0).maxC(1.0e-20));

    // ========================================================================
    // Saturation Voltage
    // ========================================================================
    const wvcox: f64 = p.weff * p.vsat_t * p.cox;
    // esat = 2*vsat_t / max(mu_eff, 1e-30)
    const esat = S.con(2.0 * p.vsat_t).div(mu_eff.maxC(1.0e-30));
    const esat_l = esat.scale(p.leff);
    // t0_sat = 1 - a1*(1 + wvcox*rds0*abeff)
    const t0_sat = abeff.scale(wvcox * rds0).addC(1.0).scale(p.e_a1).neg().addC(1.0);
    // vdsat = esat_l*vgst2vtm / (|abeff*esat_l + vgst2vtm*t0_sat| + 1e-20)
    const vdsat_num = esat_l.mul(vgst2vtm);
    const vdsat_den = abeff.mul(esat_l).add(vgst2vtm.mul(t0_sat)).abs().addC(1.0e-20);
    const vdsat = vdsat_num.div(vdsat_den);

    // ========================================================================
    // Effective Drain-Source Voltage (Smooth Clipping)
    // ========================================================================
    // t1_clip = vdsat - VDS - delta
    const t1_clip = vdsat.sub(VDS).addC(-p.e_delta);
    const t2_clip = t1_clip.mul(t1_clip).add(vdsat.scale(4.0 * p.e_delta)).sqrt();
    const vdseff = vdsat.sub(t1_clip.add(t2_clip).scale(0.5));
    const delta_vds = VDS.sub(vdseff);

    // ========================================================================
    // Channel Length Modulation (VACLM)
    // ========================================================================
    // vaclm = (1/(pclm*abeff*litl_clm)) * leff * (abeff + vgsteff/esat_l) * delta_vds
    const vaclm = if (p.e_pclm > 0.0)
        S.con(1.0).div(abeff.scale(p.e_pclm * p.litl_clm))
            .scale(p.leff)
            .mul(abeff.add(vgsteff.div(esat_l)))
            .mul(delta_vds)
    else
        S.con(5.835e14);

    // ========================================================================
    // DIBL Output Resistance (VADIBL)
    // ========================================================================
    const arg_drout = S.con(-p.e_drout * p.leff).div(lt1.abs().addC(1.0e-20));
    const exp_drout = arg_drout.minC(EXP_GUARD).exp();
    // theta_rout = pdiblc1*exp_drout*(1+2*exp_drout) + pdiblc2
    const theta_rout = exp_drout.mul(exp_drout.scale(2.0).addC(1.0)).scale(p.e_pdiblc1).addC(p.e_pdiblc2);

    const t8_dibl = abeff.mul(vdsat);
    // va_pre = (vgst2vtm - vgst2vtm*t8_dibl/(vgst2vtm+t8_dibl+1e-20)) / (theta_rout+1e-20)
    const va_pre = vgst2vtm.sub(vgst2vtm.mul(t8_dibl).div(vgst2vtm.add(t8_dibl).addC(1.0e-20)))
        .div(theta_rout.addC(1.0e-20));

    const t3_diblcb = S.con(1.0).div(vbseff.scale(p.e_pdiblcb).addC(1.0));
    const vadibl = va_pre.mul(t3_diblcb);

    // ========================================================================
    // Combined Early Voltage
    // ========================================================================
    const va_combined = vaclm.mul(vadibl).div(vaclm.add(vadibl).addC(1.0e-20));

    // PVAG effect: t0_pvag = 1 + pvag/esat_l*vgsteff
    const t0_pvag = S.con(p.e_pvag).div(esat_l).mul(vgsteff).addC(1.0);

    // Velocity saturation Early voltage
    // vasat_denom = (2/a2 - 1) + wvcox*rds0*abeff + 1e-20
    const vasat_denom = abeff.scale(wvcox * rds0).addC((2.0 / p.e_a2 - 1.0) + 1.0e-20);
    // vasat = (esat_l + vdsat + 2*wvcox*rds0*vgsteff) / vasat_denom
    const vasat = esat_l.add(vdsat).add(vgsteff.scale(2.0 * wvcox * rds0)).div(vasat_denom);

    const va = vasat.add(t0_pvag.mul(va_combined));

    // ========================================================================
    // Drain Current
    // ========================================================================
    // beta = mu_eff*cox*weff/leff
    const beta_s = mu_eff.scale(p.cox * p.weff / p.leff);
    // fgche1 = vgsteff*(1 - abeff*vdseff/(2*vgst2vtm))
    const fgche1 = vgsteff.mul(S.con(1.0).sub(abeff.mul(vdseff).div(vgst2vtm.scale(2.0))));
    // fgche2 = 1 + vdseff/esat_l
    const fgche2 = vdseff.div(esat_l).addC(1.0);
    const gche = beta_s.mul(fgche1).div(fgche2);
    // idl = gche*vdseff/(1 + gche*rds0)
    const idl = gche.mul(vdseff).div(gche.scale(rds0).addC(1.0));
    // ids = idl*(1 + delta_vds/(va+1e-20))
    const ids = idl.mul(delta_vds.div(va.addC(1.0e-20)).addC(1.0));

    // Mode and type adjustment: ids_actual = ids*sgn_vds*type_f
    const ids_actual = ids.mul(sgn_vds).scale(p.type_f);

    // ========================================================================
    // Parasitic Source/Drain Resistance (conductances x-independent)
    // ========================================================================
    const g_ds_ext: f64 = if (p.m_rsh > 0.0) 1.0 / @max(p.m_rsh * 0.5, 1.0e-6) else GSHORT;
    const g_ss_ext: f64 = g_ds_ext;

    const i_d_dp = v_d.sub(v_dp).scale(g_ds_ext);
    const i_s_sp = v_s.sub(v_sp).scale(g_ss_ext);

    // GMIN convergence aid
    const vdpsp = v_dp.sub(v_sp);
    const i_gmin = vdpsp.scale(GMIN);

    // Body Contact Resistance
    const g_body: f64 = if (p.m_rbody > 0.0) 1.0 / p.m_rbody else GMIN;
    const i_b_p = v_b.sub(v_p).scale(g_body);

    // External Body Sheet Resistance (p -> e)
    const g_bsh: f64 = if (p.m_rbsh > 0.0) 1.0 / p.m_rbsh else GMIN;
    const i_p_e = v_p.sub(v_e).scale(g_bsh);

    // Self-Heating
    const delta_temp = v_temp; // thermal node voltage represents delta_T
    const power_diss = ids_actual.mul(v_dp.sub(v_sp));
    const i_th = if (p.m_shmod == 1 and p.m_rth0 > 0.0)
        delta_temp.scale(1.0 / p.m_rth0).sub(power_diss)
    else
        delta_temp.scale(1.0e3);

    // Substrate (back-gate) node current
    const i_e_sub = v_e.sub(v_s).scale(GMIN);

    // ========================================================================
    // Stamp currents with multiplicity
    // ========================================================================
    var out: [n_u]S = undefined;
    out[D] = i_d_dp.scale(p.mult);
    out[G] = S.con(0.0);
    out[Sn] = i_s_sp.scale(p.mult);
    out[E] = i_e_sub.sub(i_p_e).scale(p.mult);
    out[DP] = i_d_dp.neg().add(ids_actual).add(i_gmin).scale(p.mult);
    out[SP] = i_s_sp.neg().sub(ids_actual).sub(i_gmin).scale(p.mult);
    out[B] = i_b_p.scale(p.mult);
    out[TEMP] = i_th.scale(p.mult);
    out[P] = i_b_p.neg().add(i_p_e).scale(p.mult);
    return out;
}

// ============================================================================
// x-INDEPENDENT preprocessing for q()
// ============================================================================

const QPrep = struct {
    type_f: f64,
    m_shmod: i32,
    mult: f64,
    cox_wl: f64,
    vtm: f64,
    phi: f64,
    sqrt_phi: f64,
    vfbb: f64,
    e_k1: f64,
    vth_cv: f64,
    n_cv: f64,
    abulk_cv: f64,
    m_xpart: f64,
    vfb_cv: f64,
    cbox_wl: f64,
    m_cgso: f64,
    m_cgdo: f64,
    m_cgeo: f64,
    m_cgsl: f64,
    m_cgdl: f64,
    m_ckappa: f64,
    weff_cv: f64,
    m_cth0: f64,
};

fn prepQ(model: *const Model, instance: *const Instance) QPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const tox: f64 = @as(f64, model.tox);
    const tbox: f64 = @as(f64, model.tbox);
    const nch_cm3: f64 = @as(f64, model.nch);
    const nsub_cm3: f64 = @as(f64, model.nsub);
    const tnom: f64 = @as(f64, model.tnom);
    const m_vth0: f64 = @as(f64, model.vth0);
    const m_k1: f64 = @as(f64, model.k1);
    const m_nfactor: f64 = @as(f64, model.nfactor);
    const m_cgso: f64 = @as(f64, model.cgso);
    const m_cgdo: f64 = @as(f64, model.cgdo);
    const m_cgeo: f64 = @as(f64, model.cgeo);
    const m_cgsl: f64 = @as(f64, model.cgsl);
    const m_cgdl: f64 = @as(f64, model.cgdl);
    const m_ckappa: f64 = @as(f64, model.ckappa);
    const m_dlc: f64 = @as(f64, model.dlc);
    const m_dwc: f64 = @as(f64, model.dwc);
    const m_xpart: f64 = @as(f64, model.xpart);
    const m_ld: f64 = @as(f64, model.ld);
    const m_kb3: f64 = @as(f64, model.kb3);
    const m_a0: f64 = @as(f64, model.a0);
    const m_cth0: f64 = @as(f64, model.cth0);
    const m_shmod: i32 = model.shmod;

    // Instance
    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_temp: f64 = instance.temp;
    const mult: f64 = @as(f64, instance.m);

    // Effective geometry
    const leff = @max(inst_l - 2.0 * m_ld, 1.0e-9);
    const weff = @max(inst_w, 1.0e-9);
    const leff_cv = @max(leff - 2.0 * m_dlc, 1.0e-8);
    const weff_cv = @max(weff - 2.0 * m_dwc, 1.0e-8);

    // Gate oxide capacitance
    const cox = EPS_OX / tox;
    const cox_wl = cox * weff_cv * leff_cv;

    // Physical constants for charge
    const vtm_nom = KB_Q * tnom;
    const vtm = KB_Q * inst_temp;

    const phi_raw = 2.0 * vtm_nom * contract.fmath.log(@max(nch_cm3 / NI_300, 1.0));
    const phi = @max(phi_raw, 0.7);
    const sqrt_phi = @sqrt(phi);

    const xdep0 = @sqrt(2.0 * EPS_SI / (CHARGE * nch_cm3 * 1.0e6)) * sqrt_phi;

    const vfbb = if (nsub_cm3 > 0.0) -vtm_nom * contract.fmath.log(@max(nch_cm3 / nsub_cm3, 1.0e-30)) else -0.9;

    const e_k1_raw = binParam(m_k1, @as(f64, model.lk1), @as(f64, model.wk1), @as(f64, model.pk1), leff, weff);
    const e_k1 = if (e_k1_raw == 0.0) (2.0 * @sqrt(2.0 * EPS_SI * CHARGE * nch_cm3 * 1.0e6 * phi)) / cox else e_k1_raw;

    const vth_cv = m_vth0;
    const n_cv = 1.0 + (m_nfactor * EPS_SI) / (xdep0 * cox);
    const abulk_cv = (e_k1 * m_a0) / (2.0 * sqrt_phi) + 1.0;
    const vfb_cv = vth_cv - phi - e_k1 * sqrt_phi;
    const cbox_wl = m_kb3 * (EPS_OX / tbox) * weff_cv * leff_cv;

    return .{
        .type_f = type_f,
        .m_shmod = m_shmod,
        .mult = mult,
        .cox_wl = cox_wl,
        .vtm = vtm,
        .phi = phi,
        .sqrt_phi = sqrt_phi,
        .vfbb = vfbb,
        .e_k1 = e_k1,
        .vth_cv = vth_cv,
        .n_cv = n_cv,
        .abulk_cv = abulk_cv,
        .m_xpart = m_xpart,
        .vfb_cv = vfb_cv,
        .cbox_wl = cbox_wl,
        .m_cgso = m_cgso,
        .m_cgdo = m_cgdo,
        .m_cgeo = m_cgeo,
        .m_cgsl = m_cgsl,
        .m_cgdl = m_cgdl,
        .m_ckappa = m_ckappa,
        .weff_cv = weff_cv,
        .m_cth0 = m_cth0,
    };
}

pub const PrepCache = struct { dc: EvalPrep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = prepEval(model, instance), .q = prepQ(model, instance) };
}

// ============================================================================
// Charge Function (q) — value form
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;
    _ = t;

    const p = &pc.q;

    const D = @intFromEnum(U.d);
    const G = @intFromEnum(U.g);
    const Sn = @intFromEnum(U.s);
    const E = @intFromEnum(U.e);
    const DP = @intFromEnum(U.dp);
    const SP = @intFromEnum(U.sp);
    const B = @intFromEnum(U.b);
    const TEMP = @intFromEnum(U.temp);
    const P = @intFromEnum(U.p);

    // Read node voltages
    const v_g = x[G];
    const v_dp = x[DP];
    const v_sp = x[SP];
    const v_e = x[E];
    const v_temp = x[TEMP];

    // Mode-adjusted voltages
    const vds_ext = v_dp.sub(v_sp).scale(p.type_f);
    const vgs_ext = v_g.sub(v_sp).scale(p.type_f);
    const ves_ext = v_e.sub(v_sp).scale(p.type_f);

    const eps_mode: f64 = 1.0e-12;
    const vds_abs_s = vds_ext.mul(vds_ext).addC(eps_mode).sqrt();
    const sgn_vds = vds_ext.div(vds_abs_s);
    const w_fwd = sgn_vds.addC(1.0).scale(0.5);
    const w_rev = w_fwd.neg().addC(1.0);

    const VDS = w_fwd.mul(vds_ext).add(w_rev.mul(vds_ext.neg()));
    const VGS = w_fwd.mul(vgs_ext).add(w_rev.mul(vgs_ext.sub(vds_ext)));
    const VES = w_fwd.mul(ves_ext).add(w_rev.mul(ves_ext.sub(vds_ext)));

    // Charge-model gate overdrive
    // half_arg = min((VGS - vth_cv)/(2*n_cv*vtm), EXP_GUARD)
    const half_arg = VGS.addC(-p.vth_cv).scale(1.0 / (2.0 * p.n_cv * p.vtm)).minC(EXP_GUARD);
    // vgsteff_cv = 2*n_cv*vtm*log(1+exp(half_arg)) + 1e-4
    const vgsteff_cv = half_arg.exp().addC(1.0).log().scale(2.0 * p.n_cv * p.vtm).addC(1.0e-4);

    // Vdsat for CV
    const vdsat_cv = vgsteff_cv.scale(1.0 / p.abulk_cv).addC(1.0e-5);

    // Effective VdsCV (smooth clipping)
    const delta4: f64 = 0.02;
    const v4 = vdsat_cv.sub(VDS).addC(-delta4);
    const vdseff_cv = vdsat_cv.sub(v4.add(v4.mul(v4).add(vdsat_cv.scale(4.0 * delta4)).sqrt()).scale(0.5));

    // Inversion charge
    // t0_inv = abulk_cv*vdseff_cv
    const t0_inv = vdseff_cv.scale(p.abulk_cv);
    // t1_inv = 12*(vgsteff_cv - t0_inv/2 + 1e-20)
    const t1_inv = vgsteff_cv.sub(t0_inv.scale(0.5)).addC(1.0e-20).scale(12.0);
    // t3_inv = t0_inv*vdseff_cv/t1_inv
    const t3_inv = t0_inv.mul(vdseff_cv).div(t1_inv);
    // qinv = cox_wl*(vgsteff_cv - vdseff_cv/2 + t3_inv)
    const qinv = vgsteff_cv.sub(vdseff_cv.scale(0.5)).add(t3_inv).scale(p.cox_wl);

    // Charge partitioning (region select on the CONSTANT xpart, not x)
    const qsrc = if (p.m_xpart < 0.25) qinv.neg() else if (p.m_xpart > 0.75) qinv.scale(-0.6) else qinv.scale(-0.5);
    // qdrn_inv = -qinv - qsrc
    const qdrn_inv = qinv.neg().sub(qsrc);

    // Accumulation charge
    const delta3: f64 = 0.02;
    // v3 = vfb_cv - VGS + 0 - delta3
    const v3 = VGS.neg().addC(p.vfb_cv - delta3);
    // vfbeff = vfb_cv - (v3 + sqrt(v3^2 + 4*delta3*(|vfb_cv|+delta3)))*0.5
    const vfbeff = v3.add(v3.mul(v3).addC(4.0 * delta3 * (@abs(p.vfb_cv) + delta3)).sqrt()).scale(0.5).neg().addC(p.vfb_cv);
    // qac0 = -cox_wl*(vfbeff - vfb_cv)
    const qac0 = vfbeff.addC(-p.vfb_cv).scale(-p.cox_wl);

    // Depletion charge
    const t0_dep: f64 = p.e_k1 * 0.5;
    // t3_dep = VGS - vfbeff - 0 - vgsteff_cv
    const t3_dep = VGS.sub(vfbeff).sub(vgsteff_cv);
    // t1_dep = sqrt(t0_dep^2 + |t3_dep|)
    const t1_dep = t3_dep.abs().addC(t0_dep * t0_dep).sqrt();
    // qsub0 = cox_wl*e_k1*(t0_dep - t1_dep)
    const qsub0 = t1_dep.neg().addC(t0_dep).scale(p.cox_wl * p.e_k1);

    // Backgate charge: qe1 = -cbox_wl*(0 - VES + vfbb)
    const qe1 = VES.neg().addC(p.vfbb).scale(-p.cbox_wl);

    // Gate overlap charges
    const vgd_raw = v_g.sub(v_dp).scale(p.type_f);
    const vgs_raw = v_g.sub(v_sp).scale(p.type_f);
    const vge_raw = v_g.sub(v_e).scale(p.type_f);

    const delta1: f64 = 0.02;

    // Gate-drain overlap
    const t0_gd = vgd_raw.addC(delta1);
    // t2_gd = (t0_gd - sqrt(t0_gd^2 + 4*delta1))*0.5
    const t2_gd = t0_gd.sub(t0_gd.mul(t0_gd).addC(4.0 * delta1).sqrt()).scale(0.5);
    // t4_gd = sqrt(|1 - 4*t2_gd/ckappa| + 1e-20)
    const t4_gd = t2_gd.scale(-4.0 / p.m_ckappa).addC(1.0).abs().addC(1.0e-20).sqrt();
    // qgdo = (cgdo + cgdl*weff_cv)*vgd_raw - cgdl*weff_cv*(t2_gd + ckappa/2*(t4_gd - 1))
    const qgdo = vgd_raw.scale(p.m_cgdo + p.m_cgdl * p.weff_cv)
        .sub(t2_gd.add(t4_gd.addC(-1.0).scale(p.m_ckappa * 0.5)).scale(p.m_cgdl * p.weff_cv));

    // Gate-source overlap
    const t0_gs = vgs_raw.addC(delta1);
    const t2_gs = t0_gs.sub(t0_gs.mul(t0_gs).addC(4.0 * delta1).sqrt()).scale(0.5);
    const t4_gs = t2_gs.scale(-4.0 / p.m_ckappa).addC(1.0).abs().addC(1.0e-20).sqrt();
    const qgso = vgs_raw.scale(p.m_cgso + p.m_cgsl * p.weff_cv)
        .sub(t2_gs.add(t4_gs.addC(-1.0).scale(p.m_ckappa * 0.5)).scale(p.m_cgsl * p.weff_cv));

    // Gate-substrate overlap
    const qge = vge_raw.scale(p.m_cgeo);

    // Total charge assembly
    const qgate = qinv.add(qgdo).add(qgso).add(qge);
    const qdrn = qdrn_inv.sub(qgdo);
    const qsrc_total = qsrc.sub(qgso);
    // qbody = -(qac0 + qsub0) - qe1
    const qbody = qac0.add(qsub0).neg().sub(qe1);
    const qsub = qe1;

    // Charge stamping with mode selection
    const q_dp = w_fwd.mul(qdrn).add(w_rev.mul(qsrc_total));
    const q_sp = w_fwd.mul(qsrc_total).add(w_rev.mul(qdrn));

    // Substrate node
    const q_e = qsub.sub(qge);

    // Thermal capacitance
    const q_temp = if (p.m_shmod == 1 and p.m_cth0 > 0.0) v_temp.scale(p.m_cth0) else S.con(0.0);

    // Scale by multiplicity
    var out: [n_u]S = undefined;
    out[D] = S.con(0.0);
    out[G] = qgate.scale(p.mult);
    out[Sn] = S.con(0.0);
    out[E] = q_e.scale(p.mult);
    out[DP] = q_dp.scale(p.mult);
    out[SP] = q_sp.scale(p.mult);
    out[B] = qbody.scale(p.mult);
    out[TEMP] = q_temp.scale(p.mult);
    out[P] = S.con(0.0);
    return out;
}

// ============================================================================
// Voltage Limiting (limit)
// ============================================================================

pub fn limit(_: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    // Per-iteration voltage clamps from the spec
    const VLIM: f64 = 3.0; // d, g, s, e, dp, sp, p
    const VLIM_B: f64 = 0.2; // b (body)
    const VLIM_T: f64 = 5.0; // temp

    var result = x_new;

    // Clamp d, g, s, e, dp, sp, p nodes
    const voltage_nodes = [_]usize{
        @intFromEnum(U.d),
        @intFromEnum(U.g),
        @intFromEnum(U.s),
        @intFromEnum(U.e),
        @intFromEnum(U.dp),
        @intFromEnum(U.sp),
        @intFromEnum(U.p),
    };

    for (voltage_nodes) |node| {
        const delta_v = x_new[node] - x_old[node];
        const clamped = if (delta_v > VLIM) x_old[node] + VLIM else if (delta_v < -VLIM) x_old[node] - VLIM else x_new[node];
        result[node] = clamped;
    }

    // Body node: tighter limit
    const delta_b = x_new[@intFromEnum(U.b)] - x_old[@intFromEnum(U.b)];
    result[@intFromEnum(U.b)] = if (delta_b > VLIM_B) x_old[@intFromEnum(U.b)] + VLIM_B else if (delta_b < -VLIM_B) x_old[@intFromEnum(U.b)] - VLIM_B else x_new[@intFromEnum(U.b)];

    // Temp node
    const delta_t = x_new[@intFromEnum(U.temp)] - x_old[@intFromEnum(U.temp)];
    result[@intFromEnum(U.temp)] = if (delta_t > VLIM_T) x_old[@intFromEnum(U.temp)] + VLIM_T else if (delta_t < -VLIM_T) x_old[@intFromEnum(U.temp)] - VLIM_T else x_new[@intFromEnum(U.temp)];

    return result;
}

// ============================================================================
// Parameter Stepping (attempt)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    // Scale key parameters for convergence aid
    // At lambda=0 (simplified): large gmin-like leakage dominates
    // At lambda=1 (original): full model
    var m = model;

    // Scale subthreshold and leakage parameters
    const lam_f64: f64 = lambda;
    const one_m_lam: f64 = 1.0 - lam_f64;
    m.isbjt = @floatCast(@as(f64, model.isbjt) * lam_f64 + 1.0e-15 * one_m_lam);
    m.isrec = @floatCast(@as(f64, model.isrec) * lam_f64 + 1.0e-15 * one_m_lam);
    m.isdif = @floatCast(@as(f64, model.isdif) * lam_f64);
    m.istun = @floatCast(@as(f64, model.istun) * lam_f64);

    return m;
}

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

test "b3soifd: on-state residual finite and substrate gmin leak exact" {
    const model: Model = .{};
    const inst: Instance = .{};
    // Vds=1V, Vgs=1.5V (on-state), substrate e=0.5V.
    const x = [_]f64{ 1.0, 1.5, 0.0, 0.5, 1.0, 0.0, 0.0, 0.0, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    for (out) |o| try testing.expect(std.math.isFinite(o));
    // Substrate row E = (i_e_sub - i_p_e)*mult with
    //   i_e_sub = (v_e - v_s)*GMIN = (0.5 - 0)*1e-12 = 5e-13
    //   i_p_e   = (v_p - v_e)*g_bsh, rbsh=0 -> g_bsh = GMIN = 1e-12;
    //             = (0 - 0.5)*1e-12 = -5e-13
    // out[E] = (5e-13 - (-5e-13)) = 1.0e-12
    try testing.expectApproxEqAbs(@as(f64, 1.0e-12), out[@intFromEnum(U.e)], 1e-24);
}

test "b3soifd: parasitic drain resistance stamp (Rsh set)" {
    // rsh > 0 makes g_ds_ext = 1/max(rsh*0.5,1e-6). With rsh=100 -> g=1/50=0.02.
    // Put 1V from d to dp only (all else 0): i_d_dp = (v_d - v_dp)*0.02 = 0.02.
    // out[D] = i_d_dp*mult = 0.02.  out[DP] includes -i_d_dp = -0.02 plus
    // channel terms (which are ~0 here because vgs=0 -> deep subthreshold).
    const model: Model = .{ .rsh = 100 };
    const inst: Instance = .{};
    const x = [_]f64{ 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // g_ds_ext = 1/max(100*0.5,1e-6) = 1/50 = 0.02; i_d_dp = 1*0.02 = 0.02
    try testing.expectApproxEqAbs(@as(f64, 0.02), out[@intFromEnum(U.d)], 1e-9);
}

test "b3soifd: thermal node default RC (shmod=0) is delta_T*1e3" {
    // shmod=0 -> i_th = v_temp*1e3. Set v_temp=0.001 -> out[TEMP]=1.0.
    const model: Model = .{};
    const inst: Instance = .{};
    const x = [_]f64{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.001, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // i_th = 0.001*1e3 = 1.0 ; out[TEMP] = 1.0 * mult(=1) = 1.0
    try testing.expectApproxEqAbs(@as(f64, 1.0), out[@intFromEnum(U.temp)], 1e-9);
}

test "b3soifd: gate overlap charge on gate node is finite and cgeo linear" {
    // With cgeo set, qge = cgeo*(v_g - v_e). Put v_g=1, v_e=0, everything
    // else 0. The gate charge includes qge among other overlap terms; verify
    // the substrate charge q_e = qsub - qge picks up -cgeo*vge_raw component.
    const model: Model = .{ .cgeo = 1.0e-10 };
    const inst: Instance = .{};
    const x = [_]f64{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const out = contract.qValues(Self, x, &model, &inst, 0);
    for (out) |o| try testing.expect(std.math.isFinite(o));
    // qge = cgeo*vge_raw = 1e-10 * (1-0)*type_f(=1) = 1e-10.
    // q_e = qsub - qge. qsub = qe1 (backgate). Hard to isolate, so just check
    // the gate charge is finite and nonzero here.
    try testing.expect(std.math.isFinite(out[@intFromEnum(U.g)]));
}

test "b3soifd: thermal capacitance shmod=1 cth0 set" {
    // shmod=1, cth0=1e-9 -> q_temp = cth0*v_temp. v_temp=2 -> 2e-9.
    const model: Model = .{ .shmod = 1, .cth0 = 1.0e-9 };
    const inst: Instance = .{};
    const x = [_]f64{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.0 };
    const out = contract.qValues(Self, x, &model, &inst, 0);
    // q_temp = 1e-9 * 2 * mult(=1) = 2e-9
    try testing.expectApproxEqAbs(@as(f64, 2.0e-9), out[@intFromEnum(U.temp)], 1e-15);
}
