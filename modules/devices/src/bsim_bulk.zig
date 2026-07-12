const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM-BULK 107.2.1 — UC Berkeley Bulk Planar MOSFET Compact Model
// ============================================================================
// Topology:
//   External: G (gate), D (drain), S (source), B (body/bulk)
//   Internal: dp (intrinsic drain), sp (intrinsic source), gp (gate prime),
//             bp (body prime), dbnd (drain-body network), sbnd (source-body network)
//   RDSMOD=1: dp/sp carry series resistance
//   RGATEMOD>0: gp carries gate resistance
//   RBODYMOD>0: bp/dbnd/sbnd carry substrate resistance network
// ============================================================================

pub const U = enum(u8) {
    gate, // 0
    drain, // 1
    source, // 2
    bulk, // 3
    drain_prime, // 4 — intrinsic drain (series resistance)
    source_prime, // 5 — intrinsic source (series resistance)
    gate_prime, // 6 — gate resistance node
    body_prime, // 7 — body prime node (substrate network)
    db_node, // 8 — drain-body substrate node
    sb_node, // 9 — source-body substrate node
};
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Model Controllers and Process ---
    type_: i32 = 1, // NMOS=1, PMOS=-1
    cvmod: i32 = 0,
    geomod: i32 = 0,
    rgeomod: i32 = 0,
    rgatemod: i32 = 0,
    asymmod: i32 = 0,
    mobscale: i32 = 0,
    rbodymod: i32 = 0,
    rbodyhvmod: i32 = 0,
    rdsmod: i32 = 0,
    covmod: i32 = 0,
    gidlmod: i32 = 0,
    shmod: i32 = 0,
    permod: i32 = 1,
    gadrift_flag: i32 = 0,
    tnoimod: i32 = 0,
    fnoimod: i32 = 0,
    binunit: i32 = 1,
    igcmod: i32 = 0,
    igbmod: i32 = 0,
    hvmod: i32 = 0,
    hvcap: i32 = 0,
    sslmod_model: i32 = 1,

    // --- Process Parameters ---
    xl: f32 = 0.0,
    xw: f32 = 0.0,
    lint: f32 = 0.0,
    wint: f32 = 0.0,
    dlc: f32 = 0.0,
    dwc: f32 = 0.0,
    toxe: f32 = 3.0e-9,
    toxp: f32 = 3.0e-9,
    dtox: f32 = 0.0,
    ndep: f32 = 1.0e24,
    nsd: f32 = 1.0e26,
    easub: f32 = 4.05,
    ngate: f32 = 5.0e25,
    vfb: f32 = -0.5,
    epsrox: f32 = 3.9,
    epsrsub: f32 = 11.9,
    ni0sub: f32 = 1.1e16,
    xj: f32 = 1.5e-7,
    dmcg: f32 = 0.0,
    dmci: f32 = 0.0, // defaults to DMCG
    dmdg: f32 = 0.0,
    dmcgt: f32 = 0.0,

    // --- Basic Model Parameters ---
    llong: f32 = 10.0e-6,
    wwide: f32 = 10.0e-6,
    asymp: f32 = 0.6,
    cit: f32 = 0.0,
    nfactor: f32 = 0.0,
    cdscd: f32 = 1.0e-9,
    cdscb: f32 = 1.0e-9,
    cdscbr: f32 = 1.0e-9, // defaults to CDSCD
    cdscdr: f32 = 1.0e-9,
    dvtp0: f32 = 1.0e-10,
    dvtp1: f32 = 0.0,
    dvtp2: f32 = 0.0,
    dvtp3: f32 = 0.0,
    dvtp4: f32 = 0.0,
    dvtp5: f32 = 0.0,
    phin: f32 = 0.045,
    k2: f32 = 0.0,
    k1: f32 = 0.0,
    eta0: f32 = 0.08,
    eta0r: f32 = 0.08,
    dsub: f32 = 0.375,
    etab: f32 = -0.07,
    u0: f32 = 67.0e-3,
    etamob: f32 = 1.0,
    ua: f32 = 0.001,
    eu: f32 = 1.5,
    ud: f32 = 0.001,
    ucs: f32 = 2.0,
    uc: f32 = 0.0,
    vsat: f32 = 1.0e6,
    vsatr: f32 = 1.0e6,
    delta: f32 = 0.125,
    avdsx: f32 = 0.16,
    psat: f32 = 1.0,
    ptwg: f32 = 0.0,
    ptwgr: f32 = 0.0, // defaults to PTWG
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    psatx: f32 = 1.0,
    psatb: f32 = 0.0,
    pclm: f32 = 0.0,
    pclmg: f32 = 0.0,
    pscbe1: f32 = 4.24e8,
    pscbe2: f32 = 1.0e-8,
    pdits: f32 = 0.0,
    pditsl: f32 = 0.0,
    pditsd: f32 = 0.0,

    // --- Source/Drain Resistance ---
    rswmin: f32 = 0.0,
    rsw: f32 = 10.0,
    rdwmin: f32 = 0.0,
    rdw: f32 = 10.0,
    rdswmin: f32 = 0.0,
    rdsw: f32 = 10.0,
    prwg: f32 = 1.0,
    prwb: f32 = 0.0,
    wr: f32 = 1.0,
    rsh: f32 = 0.0,
    pdiblc: f32 = 2.0e-4,
    pdiblcb: f32 = 0.0,
    pvag: f32 = 1.0,
    fprout: f32 = 0.0,

    // --- AbulkIV ---
    abulk: f32 = 1.0,
    a0: f32 = 0.0,
    ags: f32 = 0.0,
    keta: f32 = 0.0,
    ags1: f32 = 1.0,

    // --- GIDL/GISL ---
    agidl: f32 = 0.0,
    bgidl: f32 = 2.3e-9,
    cgidl: f32 = 0.5,
    egidl: f32 = 0.8,
    agisl: f32 = 0.0,
    bgisl: f32 = 2.3e-9,
    cgisl: f32 = 0.5,
    egisl: f32 = 0.8,

    // --- Impact Ionization ---
    alpha0: f32 = 0.0,
    alpha0r: f32 = 0.0, // defaults to ALPHA0
    beta0: f32 = 0.0,
    beta0r: f32 = 0.0, // defaults to BETA0

    // --- Gate Tunneling Parameters ---
    aigc: f32 = 1.36e-2,
    bigc: f32 = 1.71e-3,
    cigc: f32 = 0.075,
    aigs: f32 = 1.36e-2,
    bigs: f32 = 1.71e-3,
    cigs: f32 = 0.075,
    dlcig: f32 = 0.0, // defaults to LINT
    aigd: f32 = 1.36e-2,
    bigd: f32 = 1.71e-3,
    cigd: f32 = 0.075,
    dlcigd: f32 = 0.0, // defaults to DLCIG
    poxedge: f32 = 1.0,
    pigcd: f32 = 1.0,
    ntox: f32 = 1.0,
    toxref: f32 = 3.0e-9,
    vfbsdoff: f32 = 0.0,

    // --- CV Parameters ---
    ndepcv: f32 = 1.0e24, // defaults to NDEP
    vfbcv: f32 = -0.5, // defaults to VFB
    vsatcv: f32 = 1.0e6, // defaults to VSAT
    pclmcv: f32 = 0.0, // defaults to PCLM
    a0cv: f32 = 0.0, // defaults to A0
    agscv: f32 = 0.0, // defaults to AGS
    ketacv: f32 = 0.0, // defaults to KETA
    delvfbacc: f32 = 0.0,
    cf: f32 = 0.0,
    cfrcoeff: f32 = 1.0,
    cgso: f32 = 0.0,
    cgdo: f32 = 0.0,
    cgsl: f32 = 0.0,
    cgdl: f32 = 0.0,
    ckappas: f32 = 0.6,
    ckappas1: f32 = 1.0e6,
    ckappas2: f32 = 1.0,
    ckappad: f32 = 0.6,
    ckappad1: f32 = 1.0e6,
    ckappad2: f32 = 1.0,
    cgbo: f32 = 0.0,
    ados: f32 = 0.0,
    bdos: f32 = 1.0,

    // --- MNUD/MNUD1 ---
    k0: f32 = 0.0,
    m0: f32 = 1.0,
    c0: f32 = 0.0,
    c0si: f32 = 1.0,
    c0sisat: f32 = 1.0,
    qm0: f32 = 1.0e-3,
    etaqm: f32 = 0.0,

    // --- Binning/Geometry ---
    dlbin: f32 = 0.0,
    dwbin: f32 = 0.0,
    lmlt: f32 = 1.0,
    wmlt: f32 = 1.0,
    cvslope: f32 = 1.0,

    // --- Length/Width Scaling ---
    ll: f32 = 0.0,
    lln: f32 = 1.0,
    lw: f32 = 0.0,
    lwn: f32 = 1.0,
    lwl: f32 = 0.0,
    wl: f32 = 0.0,
    wln: f32 = 1.0,
    ww: f32 = 0.0,
    wwn: f32 = 1.0,
    wwl: f32 = 0.0,

    // --- Global Geometrical Scaling sub-parameters ---
    ndepl1: f32 = 0.0,
    ndeplexp1: f32 = 1.0,
    ndepl2: f32 = 0.0,
    ndeplexp2: f32 = 1.0,
    ndepw: f32 = 0.0,
    ndepwexp: f32 = 1.0,
    ndepwl: f32 = 0.0,
    ndepwlexp: f32 = 1.0,
    nfactorl: f32 = 0.0,
    nfactorlexp: f32 = 1.0,
    nfactorw: f32 = 0.0,
    nfactorwexp: f32 = 1.0,
    nfactorwl: f32 = 0.0,
    cdscdl: f32 = 0.0,
    cdscdlexp: f32 = 1.0,
    cdscbl: f32 = 0.0,
    cdscblexp: f32 = 1.0,
    cdscdlr: f32 = 0.0,
    lcdscdr: f32 = 0.0,
    u0l: f32 = 0.0,
    u0lexp: f32 = 1.0,
    ual: f32 = 0.0,
    ualexp: f32 = 1.0,
    uaw: f32 = 0.0,
    uawexp: f32 = 1.0,
    uawl: f32 = 0.0,
    eul: f32 = 0.0,
    eulexp: f32 = 1.0,
    euw: f32 = 0.0,
    euwexp: f32 = 1.0,
    euwl: f32 = 0.0,
    udl: f32 = 0.0,
    udlexp: f32 = 1.0,
    ucl: f32 = 0.0,
    uclexp: f32 = 1.0,
    vsatl: f32 = 0.0,
    vsatlexp: f32 = 1.0,
    vsatw: f32 = 0.0,
    vsatwexp: f32 = 1.0,
    lvsatr: f32 = 0.0,
    wvsatr: f32 = 0.0,
    pvsatr: f32 = 0.0,
    psatl: f32 = 0.0,
    psatlexp: f32 = 1.0,
    ptwgl: f32 = 0.0,
    ptwglexp: f32 = 1.0,
    ptwglr: f32 = 0.0,
    ptwglexpr: f32 = 1.0,
    deltal: f32 = 0.0,
    deltalexp: f32 = 1.0,
    pclml: f32 = 0.0,
    pclmlexp: f32 = 1.0,
    pdiblcl: f32 = 0.0,
    pdiblclexp: f32 = 1.0,
    k1l: f32 = 0.0,
    k1lexp: f32 = 1.0,
    k1w: f32 = 0.0,
    k1wl: f32 = 0.0,
    k1wexp: f32 = 1.0,
    k1wlexp: f32 = 1.0,
    k2l: f32 = 0.0,
    k2lexp: f32 = 1.0,
    k2w: f32 = 0.0,
    k2wexp: f32 = 1.0,
    prwbl: f32 = 0.0,
    prwblexp: f32 = 1.0,
    rswl: f32 = 0.0,
    rswlexp: f32 = 1.0,
    rdwl: f32 = 0.0,
    rdwlexp: f32 = 1.0,
    rdswl: f32 = 0.0,
    rdswlexp: f32 = 1.0,
    fproutl: f32 = 0.0,
    fproutlexp: f32 = 1.0,
    alpha0l: f32 = 0.0,
    alpha0lexp: f32 = 1.0,
    alpha0w: f32 = 0.0,
    alpha0wexp: f32 = 1.0,
    beta0l: f32 = 0.0,
    beta0lexp: f32 = 1.0,
    beta0w: f32 = 0.0,
    beta0wexp: f32 = 1.0,
    agidll: f32 = 0.0,
    agidlw: f32 = 0.0,
    agisll: f32 = 0.0,
    agislw: f32 = 0.0,
    aigcl: f32 = 0.0,
    aigcw: f32 = 0.0,
    aigsl: f32 = 0.0,
    aigsw: f32 = 0.0,
    aigdl: f32 = 0.0,
    aigdw: f32 = 0.0,
    pigcdl: f32 = 0.0,
    pigcdlexp: f32 = 1.0,
    etabexp: f32 = 1.0,
    ndepcvl1: f32 = 0.0,
    ndepcvlexp1: f32 = 1.0,
    ndepcvl2: f32 = 0.0,
    ndepcvlexp2: f32 = 1.0,
    ndepcvw: f32 = 0.0,
    ndepcvwexp: f32 = 1.0,
    ndepcvwl: f32 = 0.0,
    ndepcvwlexp: f32 = 1.0,
    vfbcvl: f32 = 0.0,
    vfbcvlexp: f32 = 1.0,
    vfbcvw: f32 = 0.0,
    vfbcvwexp: f32 = 1.0,
    vfbcvwl: f32 = 0.0,
    vfbcvwlexp: f32 = 1.0,
    vsatcvl: f32 = 0.0,
    vsatcvlexp: f32 = 1.0,
    vsatcvw: f32 = 0.0,
    vsatcvwexp: f32 = 1.0,
    pclmcvl: f32 = 0.0,
    pclmcvlexp: f32 = 1.0,

    // --- Both Model and Instance (defaults for model) ---
    dtemp: f32 = 0.0,
    mulu0: f32 = 1.0,
    delvto: f32 = 0.0,
    ids0mult: f32 = 1.0,
    xgw: f32 = 0.0,
    ngcon: i32 = 1,
    edgefet: i32 = 1,

    // --- RF / Body Resistance ---
    xrcrg1: f32 = 12.0,
    xrcrg2: f32 = 1.0,
    gbmin: f32 = 1.0e-12,
    rshg: f32 = 0.0,
    rbps0: f32 = 50.0,
    rbpsl: f32 = 0.0,
    rbpsw: f32 = 0.0,
    rbpsnf: f32 = 0.0,
    rbpd0: f32 = 50.0,
    rbpdl: f32 = 0.0,
    rbpdw: f32 = 0.0,
    rbpdnf: f32 = 0.0,
    rbpbx0: f32 = 100.0,
    rbpbxl: f32 = 0.0,
    rbpbxw: f32 = 0.0,
    rbpbxnf: f32 = 0.0,
    rbpby0: f32 = 100.0,
    rbpbyl: f32 = 0.0,
    rbpbyw: f32 = 0.0,
    rbpbynf: f32 = 0.0,
    rbsbx0: f32 = 100.0,
    rbsby0: f32 = 100.0,
    rbdbx0: f32 = 100.0,
    rbdby0: f32 = 100.0,
    rbsdbxl: f32 = 0.0,
    rbsdbxw: f32 = 0.0,
    rbsdbxnf: f32 = 0.0,
    rbsdbyl: f32 = 0.0,
    rbsdbyw: f32 = 0.0,
    rbsdbynf: f32 = 0.0,

    // --- Flicker Noise ---
    noia: f32 = 6.25e41,
    noib: f32 = 3.125e26,
    noic: f32 = 8.75,
    noia3: f32 = 0.0,
    mpower: f32 = 1.2,
    qsref: f32 = 50.0e-3,
    spfn: f32 = 2.0,
    noia1: f32 = 0.0,
    noiax: f32 = 1.0,
    noia2: f32 = 6.25e41, // defaults to NOIA
    lh: f32 = 10.0e-9,
    em: f32 = 4.1e7,
    ef: f32 = 1.0,
    afns: f32 = 2.0,
    bfns: f32 = 1.0,
    kfns: f32 = 0.0,
    afnd: f32 = 2.0,
    bfnd: f32 = 1.0,
    kfnd: f32 = 0.0,
    lintnoi: f32 = 0.0,

    // --- Thermal Noise ---
    ntnoi: f32 = 1.0,
    tnoia: f32 = 1.5,
    tnoib: f32 = 3.5,
    tnoic: f32 = 0.0,
    rnoia: f32 = 0.577,
    rnoib: f32 = 0.5164,
    rnoic: f32 = 0.395,
    rnoik: f32 = 0.0,
    tnoik: f32 = 0.0,
    tnoik2: f32 = 0.1,

    // --- Layout-Dependent Parasitic ---
    dwj: f32 = 0.0, // defaults to DWC
    xgl: f32 = 0.0,

    // --- Junction Diode Parameters ---
    ijthsrev: f32 = 0.1,
    ijthdrev: f32 = 0.1, // defaults to IJTHSREV
    ijthsfwd: f32 = 0.1,
    ijthdfwd: f32 = 0.1, // defaults to IJTHSFWD
    xjbvs: f32 = 1.0,
    xjbvd: f32 = 1.0, // defaults to XJBVS
    bvs: f32 = 10.0,
    bvd: f32 = 10.0, // defaults to BVS
    jss: f32 = 1.0e-4,
    jsd: f32 = 1.0e-4, // defaults to JSS
    jsws: f32 = 0.0,
    jswd: f32 = 0.0, // defaults to JSWS
    jswgs: f32 = 0.0,
    jswgd: f32 = 0.0, // defaults to JSWGS
    jtss: f32 = 0.0,
    jtsd: f32 = 0.0,
    jtssws: f32 = 0.0,
    jtsswd: f32 = 0.0,
    jtsswgs: f32 = 0.0,
    jtsswgd: f32 = 0.0,
    jtweff: f32 = 0.0,
    njs: f32 = 1.0,
    njd: f32 = 1.0,
    njts: f32 = 20.0,
    njtsd: f32 = 20.0,
    njtssw: f32 = 20.0,
    njtsswd: f32 = 20.0,
    njtsswg: f32 = 20.0,
    njtsswgd: f32 = 20.0,
    xtss: f32 = 0.02,
    xtsd: f32 = 0.02,
    xtssws: f32 = 0.02,
    xtsswd: f32 = 0.02,
    xtsswgs: f32 = 0.02,
    xtsswgd: f32 = 0.02,
    vtss: f32 = 10.0,
    vtsd: f32 = 10.0,
    vtssws: f32 = 10.0,
    vtsswd: f32 = 10.0,
    vtsswgs: f32 = 10.0,
    vtsswgd: f32 = 10.0,
    tnjts: f32 = 0.0,
    tnjtsd: f32 = 0.0,
    tnjtssw: f32 = 0.0,
    tnjtsswd: f32 = 0.0,
    tnjtsswg: f32 = 0.0,
    tnjtsswgd: f32 = 0.0,

    // --- Junction Diode CV ---
    cjs: f32 = 5.0e-4,
    cjd: f32 = 5.0e-4,
    mjs: f32 = 0.5,
    mjd: f32 = 0.5,
    mjsws: f32 = 0.33,
    mjswd: f32 = 0.33,
    cjsws: f32 = 5.0e-10,
    cjswd: f32 = 5.0e-10,
    cjswgs: f32 = 5.0e-10, // defaults to CJSWS
    cjswgd: f32 = 5.0e-10,
    mjswgs: f32 = 0.33, // defaults to MJSWS
    mjswgd: f32 = 0.33,
    pbs: f32 = 1.0,
    pbd: f32 = 1.0, // defaults to PBS
    pbsws: f32 = 1.0,
    pbswd: f32 = 1.0,
    pbswgs: f32 = 1.0, // defaults to PBSWS
    pbswgd: f32 = 1.0,

    // --- Temperature Parameters ---
    tnom: f32 = 27.0,
    ute: f32 = -1.5,
    ucste: f32 = -4.775e-3,
    tdelta: f32 = 0.0,
    tgidl: f32 = 0.0,
    iit: f32 = 0.0,
    kt1: f32 = -0.11,
    kt1exp: f32 = 1.0,
    kt1l: f32 = 0.0,
    kt2: f32 = 0.022,
    ua1: f32 = 1.0e-9,
    uc1: f32 = 0.056,
    ud1: f32 = 0.0,
    eu1: f32 = 0.0,
    at: f32 = 3.3e4,
    ptwgt: f32 = 0.0,
    prt: f32 = 0.0,
    prthv: f32 = 0.0,
    igt: f32 = 2.5,
    xtis: f32 = 3.0,
    xtid: f32 = 3.0,
    tpb: f32 = 0.0,
    tpbsw: f32 = 0.0,
    tpbswg: f32 = 0.0,
    tcj: f32 = 0.0,
    tcjsw: f32 = 0.0,
    tcjswg: f32 = 0.0,
    tvfbsdoff: f32 = 0.0,
    tnfactor: f32 = 0.0,
    teta0: f32 = 0.0,
    rth0: f32 = 0.0,
    cth0: f32 = 1.0e-5,
    wth0: f32 = 0.0,
    bg0sub: f32 = 1.17,
    tbgasub: f32 = 4.73e-4,
    tbgbsub: f32 = 636.0,
    fc: f32 = 0.5,

    // --- Gate Tunneling Supplementary ---
    aigbacc: f32 = 1.36e-2,
    bigbacc: f32 = 1.71e-3,
    cigbacc: f32 = 0.075,
    nigbacc: f32 = 1.0,
    aigbinv: f32 = 1.11e-2,
    bigbinv: f32 = 9.49e-4,
    cigbinv: f32 = 6.0e-3,
    eigbinv: f32 = 1.1,
    nigbinv: f32 = 3.0,

    // --- Mobility Scaling (MOBSCALE=1) ---
    up1: f32 = 0.0,
    up2: f32 = 0.0,
    lp1: f32 = 1.0e-6,
    lp2: f32 = 1.0e-6,

    // --- Stress Effect ---
    saref: f32 = 1.0e-6,
    sbref: f32 = 1.0e-6,
    saedge: f32 = 0.0, // defaults to SA (instance)
    sbedge: f32 = 0.0, // defaults to SB (instance)
    wlod: f32 = 0.0,
    ku0: f32 = 0.0,
    kvsat: f32 = 0.0,
    tku0: f32 = 0.0,
    lku0: f32 = 0.0,
    wku0: f32 = 0.0,
    pku0: f32 = 0.0,
    llodku0: f32 = 0.0,
    wlodku0: f32 = 0.0,
    kvth0: f32 = 0.0,
    kvth0edge: f32 = 0.0,
    lkvth0: f32 = 0.0,
    wkvth0: f32 = 0.0,
    pkvth0: f32 = 0.0,
    llodvth: f32 = 0.0,
    wlodvth: f32 = 0.0,
    stk2: f32 = 0.0,
    stk2edge: f32 = 0.0,
    lodk2: f32 = 0.0,
    steta0: f32 = 0.0,
    steta0edge: f32 = 0.0,
    lodeta0: f32 = 1.0,

    // --- Well Proximity ---
    web: f32 = 0.0,
    wec: f32 = 0.0,
    kvth0we: f32 = 0.0,
    k2we: f32 = 0.0,
    kvth0edgewe: f32 = 0.0,
    k2edgewe: f32 = 0.0,
    ku0we: f32 = 0.0,
    scref: f32 = 1.0e-6,

    // --- Edge FET / Sub-Surface Leakage ---
    ndepedge: f32 = 1.0e24,
    wedge: f32 = 10.0e-9,
    dgamma: f32 = 0.0,
    dgammal: f32 = 0.0,
    dgammalexp: f32 = 1.0,
    dvtedge: f32 = 0.0,
    nfactoredge: f32 = 0.0,
    citedge: f32 = 0.0,
    cdscdedge: f32 = 1.0e-9,
    cdscbedge: f32 = 0.0,
    eta0edge: f32 = 0.08,
    etabedge: f32 = -0.07,
    k2edge: f32 = 0.0,
    kt1edge: f32 = -0.11,
    kt1ledge: f32 = 0.0,
    kt2edge: f32 = 0.022,
    kt1expedge: f32 = 1.0,
    tnfactoredge: f32 = 0.0,
    teta0edge: f32 = 0.0,
    dvt0edge: f32 = 2.2,
    dvt1edge: f32 = 0.53,
    dvt2edge: f32 = 0.0,
    ssl0: f32 = 400.0,
    ssl1: f32 = 3.36e8,
    ssl2: f32 = 0.185,
    ssl3: f32 = 0.3,
    ssl4: f32 = 1.4,
    ssl5: f32 = 0.0,
    sslexp1: f32 = 0.490,
    sslexp2: f32 = 1.42,

    // --- HV Model Parameters ---
    rdlcw: f32 = 100.0,
    rdlcwcv: f32 = 100.0,
    rslcw: f32 = 0.0,
    ndriftd: f32 = 1.0e16,
    ndrifts: f32 = 1.0e16,
    vdrift: f32 = 2.0e5,
    ptwghv: f32 = 0.0,
    ptwghv1: f32 = 0.0,
    psatxhv: f32 = 60.0,
    pdrwb: f32 = 0.0,
    mdrift: f32 = 1.0,
    drb1: f32 = 0.0,
    drb2: f32 = 0.0,
    rdvds: f32 = 8.0,
    gadrift: f32 = 200.0,
    xpart: f32 = 0.0,
    hvfactor: f32 = 1.0e-3,
    vfbov: f32 = -1.0,
    lover: f32 = 500.0e-9,
    loveracc: f32 = 500.0e-9,
    slhv: f32 = 0.0,
    slhv1: f32 = 0.0,
    ndr: f32 = 1.0e24,
    alphadr: f32 = 0.0,
    betadr: f32 = 0.0,
    beta1: f32 = 0.0,
    beta2: f32 = 0.0,
    beta3: f32 = 1.0,
    alpha1: f32 = 0.0,
    alpha2: f32 = 0.0,
    alpha3: f32 = 0.0,
    alpha4: f32 = 0.0,
    drii1: f32 = 1.0,
    drii2: f32 = 0.0,
    drii3: f32 = 1.0,
    drii4: f32 = 0.0,
    alphadr1: f32 = 0.0,
    alphadr2: f32 = 0.0,
    alphadr3: f32 = 0.0,
    alphadr4: f32 = 0.0,
    drexp: f32 = 0.0,
    ptwghvii: f32 = 0.0,
    ptwghv1ii: f32 = 0.0,
    psatxhvii: f32 = 60.0,
    cmd1: f32 = 0.0,
    cmd2: f32 = 1.0,
    cms1: f32 = 0.0,
    cms2: f32 = 1.0,
    dsmooth: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 10.0e-6,
    w: f32 = 10.0e-6,
    nf: f32 = 1.0,
    nrs: f32 = 1.0,
    nrd: f32 = 1.0,
    vfbsdoff: f32 = 0.0,
    minz: f32 = 0.0,
    rgatemod: i32 = 0,
    rbodymod: i32 = 0,
    geomod: i32 = 0,
    rgeomod: i32 = 0,
    rbpb: f32 = 50.0,
    rbpd: f32 = 50.0,
    rbps: f32 = 50.0,
    rbdb: f32 = 50.0,
    rbsb: f32 = 50.0,
    rdb: f32 = 50.0,
    sa: f32 = 0.0,
    sb: f32 = 0.0,
    sd: f32 = 0.0,
    sca: f32 = 0.0,
    scb: f32 = 0.0,
    scc: f32 = 0.0,
    sc: f32 = 0.0,
    as_: f32 = 0.0,
    ad: f32 = 0.0,
    ps: f32 = 0.0,
    pd: f32 = 0.0,
    dtemp: f32 = 0.0,
    mulu0: f32 = 1.0,
    delvto: f32 = 0.0,
    ids0mult: f32 = 1.0,
    xgw: f32 = 0.0,
    ngcon: i32 = 1,
    edgefet: i32 = 1,
    sslmod: i32 = 1,
    m: f32 = 1.0,
};

// ============================================================================
// Noise generators
// ============================================================================
// Channel thermal, channel flicker, gate shot (gs, gd, gb), S/D resistance flicker
pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: drain_prime to source_prime
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel flicker noise: drain_prime to source_prime
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Gate shot noise (gs): gate_prime to source_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Gate shot noise (gd): gate_prime to drain_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime), .kind = .shot },
    // Gate shot noise (gb): gate_prime to body_prime
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.body_prime), .kind = .shot },
};


// ============================================================================
// Physics function: eval (value-form, generic over scalar S)
// ============================================================================
// Strategy: everything that does NOT depend on terminal voltages (parameter
// prep, temperature updates, geometry) is precomputed once in f64 (`Prep`).
// Only the x-dependent current chains use S ops so the analytic Jacobian
// stays exact.

/// x-independent parameter/temperature/geometry preprocessing (pure f64).
const Prep = struct {
    type_f: f64,
    vt: f64,
    // constants
    q_e: f64,
    eps_sub: f64,
    eps_ox: f64,
    eps_ratio: f64,
    cox: f64,
    toxe: f64,
    // geometry
    nf_f: f64,
    m_mult: f64,
    leff: f64,
    weff: f64,
    l_drawn: f64,
    // NDEP / mobility
    ndep_i: f64,
    ni: f64,
    mob0_t: f64,
    ua_t: f64,
    uc_t: f64,
    ud_t: f64,
    eu_t: f64,
    ucs_t: f64,
    vsat_t: f64,
    // SCE
    eta0_t: f64,
    nfactor_t: f64,
    delta_param: f64,
    rdsw_t: f64,
    // Vth temp
    kt1_i: f64,
    kt2: f64,
    kt1exp: f64,
    vfb_t: f64,
    t_ratio: f64,
    // pinch-off
    gamma: f64,
    delta_pd: f64,
    phi_b: f64,
    // depletion
    phin: f64,
    psi_st: f64,
    xj_val: f64,
    xdep: f64,
    // temp / eg
    eg_nom: f64,
    eg: f64,
    vt_nom: f64,
    temp_k: f64,
    // misc params
    avdsx: f64,
    cit: f64,
    cdscd: f64,
    cdscb: f64,
    etamob: f64,
    etab: f64,
    k1_i: f64,
    k2_i: f64,
    // DITS
    dvtp0: f64,
    dvtp1: f64,
    dvtp2: f64,
    dvtp3: f64,
    dvtp4: f64,
    dvtp5: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    // --- Physical constants ---
    const q_e: f64 = 1.6e-19;
    const eps0: f64 = 8.8542e-12;
    const k_b: f64 = 1.380649e-23;

    const type_f: f64 = @floatFromInt(model.type_);
    const toxe: f64 = @as(f64, model.toxe);
    const epsrox: f64 = @as(f64, model.epsrox);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const eps_sub: f64 = epsrsub * eps0;
    const eps_ox: f64 = epsrox * eps0;
    const eps_ratio: f64 = epsrsub / 3.9;
    const cox: f64 = 3.9 * eps0 / toxe;
    const ni0sub: f64 = @as(f64, model.ni0sub);

    // --- Temperature ---
    const tnom_c: f64 = @as(f64, model.tnom);
    const tnom_k: f64 = tnom_c + 273.15;
    const dtemp_inst: f64 = @as(f64, instance.dtemp);
    const dtemp_mod: f64 = @as(f64, model.dtemp);
    const temp_k: f64 = tnom_k + dtemp_inst + dtemp_mod;
    const vt: f64 = k_b * temp_k / q_e;
    const vt_nom: f64 = k_b * tnom_k / q_e;
    const t_ratio: f64 = temp_k / tnom_k;

    // --- Energy gap ---
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);
    const eg_nom: f64 = bg0sub - tbgasub * tnom_k * tnom_k / (tnom_k + tbgbsub);
    const eg: f64 = bg0sub - tbgasub * temp_k * temp_k / (temp_k + tbgbsub);

    // --- Intrinsic carrier concentration ---
    const ni: f64 = ni0sub * contract.fmath.exp(1.5 * contract.fmath.log(t_ratio)) * contract.fmath.exp(eg_nom / (2.0 * vt_nom) - eg / (2.0 * vt));

    // --- Instance geometry ---
    const nf_f: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const lmlt: f64 = @as(f64, model.lmlt);
    const wmlt: f64 = @as(f64, model.wmlt);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);

    const l_drawn: f64 = @as(f64, instance.l);
    const w_drawn: f64 = @as(f64, instance.w);
    const l_new: f64 = l_drawn * lmlt + xl;
    const w_new: f64 = w_drawn / nf_f * wmlt + xw;

    // --- Effective channel dimensions ---
    const lint: f64 = @as(f64, model.lint);
    const wint: f64 = @as(f64, model.wint);
    const delta_l: f64 = lint;
    const delta_w: f64 = wint;
    const leff: f64 = @max(l_new - 2.0 * delta_l, 1.0e-9);
    const weff: f64 = @max(w_new - 2.0 * delta_w, 1.0e-9);

    // NDEP scaling
    const ndep_nom: f64 = @as(f64, model.ndep);
    const ndep_i: f64 = ndep_nom * (1.0 + @as(f64, model.ndepl1) * contract.fmath.exp(-@as(f64, model.ndeplexp1) * contract.fmath.log(@max(leff, 1.0e-30))) + @as(f64, model.ndepl2) * contract.fmath.exp(-@as(f64, model.ndeplexp2) * contract.fmath.log(@max(leff, 1.0e-30))) + @as(f64, model.ndepw) * contract.fmath.exp(-@as(f64, model.ndepwexp) * contract.fmath.log(@max(weff, 1.0e-30))) + @as(f64, model.ndepwl) * contract.fmath.exp(-@as(f64, model.ndepwlexp) * contract.fmath.log(@max(leff * weff, 1.0e-30))));

    // U0 scaling
    const mob0_nom: f64 = @as(f64, model.u0) * @as(f64, model.mulu0) * @as(f64, instance.mulu0);
    const mob_lexp: f64 = @as(f64, model.u0lexp);
    const mob0_i: f64 = if (@as(f64, model.mobscale) < 0.5)
        (if (mob_lexp > 0.0)
            mob0_nom * (1.0 - @as(f64, model.u0l) * contract.fmath.exp(-mob_lexp * contract.fmath.log(@max(leff, 1.0e-30))))
        else
            mob0_nom * (1.0 - @as(f64, model.u0l)))
    else
        mob0_nom * (1.0 - @as(f64, model.up1) * contract.fmath.exp(-leff / @max(@as(f64, model.lp1), 1.0e-30)) - @as(f64, model.up2) * contract.fmath.exp(-leff / @max(@as(f64, model.lp2), 1.0e-30)));

    const ute: f64 = @as(f64, model.ute);
    const mob0_t: f64 = mob0_i * contract.fmath.exp(ute * contract.fmath.log(t_ratio));

    const ua_nom: f64 = @as(f64, model.ua);
    const ua1: f64 = @as(f64, model.ua1);
    const ua_t: f64 = ua_nom * (1.0 + ua1 * (temp_k - tnom_k));

    const uc_nom: f64 = @as(f64, model.uc);
    const uc1: f64 = @as(f64, model.uc1);
    const uc_t: f64 = uc_nom * (1.0 + uc1 * (temp_k - tnom_k));

    const ud_nom: f64 = @as(f64, model.ud);
    const ud1: f64 = @as(f64, model.ud1);
    const ud_t: f64 = ud_nom * contract.fmath.exp(ud1 * contract.fmath.log(t_ratio));

    const eu_nom: f64 = @as(f64, model.eu);
    const eu1: f64 = @as(f64, model.eu1);
    const eu_t: f64 = eu_nom * (1.0 + eu1 * (t_ratio - 1.0));

    const ucs_nom: f64 = @as(f64, model.ucs);
    const ucste: f64 = @as(f64, model.ucste);
    const ucs_t: f64 = ucs_nom * contract.fmath.exp(ucste * contract.fmath.log(t_ratio));

    const vsat_nom: f64 = @as(f64, model.vsat);
    const at: f64 = @as(f64, model.at);
    const vsat_t: f64 = vsat_nom * contract.fmath.exp(-at * contract.fmath.log(t_ratio));

    const dsub: f64 = @as(f64, model.dsub);
    const eta0_nom: f64 = @as(f64, model.eta0);
    const eta0_i: f64 = eta0_nom * contract.fmath.exp(-dsub * contract.fmath.log(@max(leff, 1.0e-30)));
    const teta0: f64 = @as(f64, model.teta0);
    const eta0_t: f64 = eta0_i + teta0 * (t_ratio - 1.0);

    const nfactor_nom: f64 = @as(f64, model.nfactor);
    const tnfactor: f64 = @as(f64, model.tnfactor);
    const nfactor_t: f64 = nfactor_nom + tnfactor * (t_ratio - 1.0);

    const delta_param: f64 = @as(f64, model.delta);

    const rdsw_nom: f64 = @as(f64, model.rdsw);
    const prt: f64 = @as(f64, model.prt);
    const rdsw_t: f64 = rdsw_nom * contract.fmath.exp(prt * contract.fmath.log(t_ratio));

    const kt1: f64 = @as(f64, model.kt1);
    const kt1l: f64 = @as(f64, model.kt1l);
    const kt2: f64 = @as(f64, model.kt2);
    const kt1exp: f64 = @as(f64, model.kt1exp);
    const kt1_i: f64 = kt1 + kt1l / @max(leff, 1.0e-30);

    const vfb_nom: f64 = @as(f64, model.vfb);
    const delvto_m: f64 = @as(f64, model.delvto);
    const delvto_i: f64 = @as(f64, instance.delvto);
    // NOTE: original folded the (kt1+kt2*vbs_eff) temperature shift into vfb_t;
    // the kt2*vbs_eff part is x-dependent and is re-added in the S tail.
    const vfb_t: f64 = vfb_nom + delvto_m + delvto_i + kt1_i * (contract.fmath.exp(kt1exp * contract.fmath.log(t_ratio)) - 1.0);

    // --- Surface potential (phi_b) ---
    const phi_b: f64 = contract.fmath.log(@max(ndep_i / ni, 1.0));

    // --- Pinch-off potential ---
    const ngate: f64 = @as(f64, model.ngate);
    const gamma0_sq: f64 = 2.0 * q_e * eps_sub * ndep_i / (cox * cox);
    const gamma0: f64 = @sqrt(@max(gamma0_sq, 1.0e-30));
    const delta_pd: f64 = if (ngate > 0.0) ndep_i / ngate else 0.0;
    const gamma: f64 = gamma0 / (1.0 + delta_pd);

    // --- Depletion width ---
    const phin: f64 = @as(f64, model.phin);
    const psi_st: f64 = 0.4 + phin + vt * contract.fmath.log(@max(ndep_i / ni, 1.0));
    const xj_val: f64 = @as(f64, model.xj);
    const xdep: f64 = @sqrt(@max(2.0 * eps_sub * psi_st / (q_e * ndep_i), 1.0e-30));

    return .{
        .type_f = type_f,
        .vt = vt,
        .q_e = q_e,
        .eps_sub = eps_sub,
        .eps_ox = eps_ox,
        .eps_ratio = eps_ratio,
        .cox = cox,
        .toxe = toxe,
        .nf_f = nf_f,
        .m_mult = m_mult,
        .leff = leff,
        .weff = weff,
        .l_drawn = l_drawn,
        .ndep_i = ndep_i,
        .ni = ni,
        .mob0_t = mob0_t,
        .ua_t = ua_t,
        .uc_t = uc_t,
        .ud_t = ud_t,
        .eu_t = eu_t,
        .ucs_t = ucs_t,
        .vsat_t = vsat_t,
        .eta0_t = eta0_t,
        .nfactor_t = nfactor_t,
        .delta_param = delta_param,
        .rdsw_t = rdsw_t,
        .kt1_i = kt1_i,
        .kt2 = kt2,
        .kt1exp = kt1exp,
        .vfb_t = vfb_t,
        .t_ratio = t_ratio,
        .gamma = gamma,
        .delta_pd = delta_pd,
        .phi_b = phi_b,
        .phin = phin,
        .psi_st = psi_st,
        .xj_val = xj_val,
        .xdep = xdep,
        .eg_nom = eg_nom,
        .eg = eg,
        .vt_nom = vt_nom,
        .temp_k = temp_k,
        .avdsx = @as(f64, model.avdsx),
        .cit = @as(f64, model.cit),
        .cdscd = @as(f64, model.cdscd),
        .cdscb = @as(f64, model.cdscb),
        .etamob = @as(f64, model.etamob),
        .etab = @as(f64, model.etab),
        .k1_i = @as(f64, model.k1),
        .k2_i = @as(f64, model.k2),
        .dvtp0 = @as(f64, model.dvtp0),
        .dvtp1 = @as(f64, model.dvtp1),
        .dvtp2 = @as(f64, model.dvtp2),
        .dvtp3 = @as(f64, model.dvtp3),
        .dvtp4 = @as(f64, model.dvtp4),
        .dvtp5 = @as(f64, model.dvtp5),
    };
}

pub const PrepCache = struct { dc: Prep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = prep(model, instance), .q = qprep(model, instance) };
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, 0.0);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    // --- Enum indices ---
    const G = @intFromEnum(U.gate);
    const D = @intFromEnum(U.drain);
    const Ssrc = @intFromEnum(U.source);
    const B = @intFromEnum(U.bulk);
    const DP = @intFromEnum(U.drain_prime);
    const SP = @intFromEnum(U.source_prime);
    const GP = @intFromEnum(U.gate_prime);
    const BP = @intFromEnum(U.body_prime);
    const DBN = @intFromEnum(U.db_node);
    const SBN = @intFromEnum(U.sb_node);

    const GMIN: f64 = 1.0e-12;
    const GSHORT: f64 = 1.0e12;

    const p = &pc.dc;
    const type_f = p.type_f;
    const vt = p.vt;
    const nvt = vt;
    const leff = p.leff;
    const weff = p.weff;
    const nf_f = p.nf_f;
    const cox = p.cox;
    const toxe = p.toxe;
    const eps_ratio = p.eps_ratio;
    const eps_sub = p.eps_sub;
    const eps_ox = p.eps_ox;
    const l_drawn = p.l_drawn;

    // Small S constructors from f64
    const con = struct {
        fn f(comptime T: type, c: f64) T {
            return T.con(c);
        }
    }.f;

    // --- Read terminal voltages (S) ---
    const vdp = x[DP];
    const vsp = x[SP];
    const vgp = x[GP];
    const vbp = x[BP];

    // Intrinsic terminal voltages referenced to source prime (scaled by type)
    const vgs_i = vgp.sub(vsp).scale(type_f);
    const vds_i = vdp.sub(vsp).scale(type_f);
    const vbs_i = vbp.sub(vsp).scale(type_f);
    const vgd_i = vgs_i.sub(vds_i);

    // --- Source-drain reversal (region select on vds sign; each branch in S) ---
    const vds_abs = vds_i.abs();
    const vds_sign: f64 = if (vds_i.val() >= 0.0) 1.0 else -1.0;
    const vds_neg = vds_i.minC(0.0);
    const vgs_eff = vgs_i.sub(vds_neg);
    const vbs_eff = vbs_i.sub(vds_neg);
    const vds_eff_use = vds_abs;

    // Smooth |Vds|
    const avdsx = p.avdsx;
    const vdsx = vds_eff_use.scale(avdsx / 2.0).minC(80.0).exp().addC(1.0).log().scale(2.0 / avdsx).sub(vds_eff_use).addC(-2.0 / avdsx * contract.fmath.log(2.0));
    const vbsx = vbs_eff.sub(vds_eff_use.sub(vdsx).scale(0.5));

    const phi_b = p.phi_b;

    // Threshold voltage x-dependent temperature part (kt2*vbs_eff term)
    const vth_temp_shift_x = vbs_eff.scale(p.kt2).scale(contract.fmath.exp(p.kt1exp * contract.fmath.log(p.t_ratio)) - 1.0);
    const vfb_t_s = vth_temp_shift_x.addC(p.vfb_t);

    // Normalized gate voltage
    const vg_norm = vgs_eff.scale(1.0 / nvt);
    // vfb_norm is x-dependent (vfb_t_s depends on vbs_eff)
    const vfb_norm = vfb_t_s.scale(1.0 / nvt);

    // Simplified pinch-off potential calculation
    const vgfb_raw = vg_norm.sub(vfb_norm);
    const psi_p0 = vgfb_raw.addC(-1.0).maxC(0.01);

    const gamma = p.gamma;
    const delta_pd = p.delta_pd;
    const gamma_half: f64 = gamma / 2.0;
    // t_sqrt = sqrt( (vgfb_raw - 1 + exp(-psi_p0)) / (1+delta_pd) + gamma_half^2 )
    const t_sqrt = vgfb_raw.addC(-1.0).add(psi_p0.neg().minC(80.0).exp()).scale(1.0 / (1.0 + delta_pd)).addC(gamma_half * gamma_half).maxC(1.0e-30).sqrt();
    const psi_p_raw = t_sqrt.addC(-gamma_half).mul(t_sqrt.addC(-gamma_half)).addC(1.0).sub(psi_p0.neg().minC(80.0).exp());
    const psi_p = psi_p_raw.maxC(0.01);

    // --- Normalized charge density ---
    const nq0 = psi_p.maxC(1.0e-30).sqrt().scale(2.0).pow(-1.0).scale(gamma).addC(1.0);
    const nq = nq0.maxC(1.001);

    // --- Short Channel Effects ---
    const cit = p.cit;
    const cdscd = p.cdscd;
    const cdscb = p.cdscb;
    const nfactor_t = p.nfactor_t;

    // n_sub = 1 + (cit + nfactor_t + cdscd*vdsx - cdscb*vbsx)/cox
    const n_sub = vdsx.scale(cdscd).sub(vbsx.scale(cdscb)).addC(cit + nfactor_t).scale(1.0 / cox).addC(1.0);
    const n_eff = n_sub.maxC(1.0);

    // Depletion width (x-independent psi_st used; vbs part is x-dependent below)
    const psi_st = p.psi_st;

    // VNUD threshold shift
    const k1_i = p.k1_i;
    const k2_i = p.k2_i;
    const phi_st: f64 = @max(psi_st, 0.4);
    // dvth_vnud = k1*(sqrt(phi_st - vbs_eff*vt) - sqrt(phi_st)) - k2*vbsx
    const dvth_vnud = vbs_eff.scale(vt).neg().addC(phi_st).maxC(1.0e-30).sqrt().addC(-@sqrt(phi_st)).scale(k1_i).sub(vbsx.scale(k2_i));

    // DIBL shift: -(eta0_t + etab*vbsx)*vdsx
    const etab = p.etab;
    const eta0_t = p.eta0_t;
    const dvth_dibl = vbsx.scale(etab).addC(eta0_t).mul(vdsx).neg();

    // DITS shift
    const dvtp0 = p.dvtp0;
    const dvtp1 = p.dvtp1;
    const dvtp2 = p.dvtp2;
    const dvtp3 = p.dvtp3;
    const dvtp4 = p.dvtp4;
    const dvtp5 = p.dvtp5;
    // dvtp_log_arg = leff / (leff + dvtp0*(1 + exp(-dvtp1*vds_eff_use)))
    const dvtp_log_arg = vds_eff_use.scale(-dvtp1).minC(80.0).exp().addC(1.0).scale(dvtp0).addC(leff).maxC(1.0e-30).pow(-1.0).scale(leff);
    // dvtp4_tanh = tanh(dvtp4*vdsx) via (e^2x-1)/(e^2x+1)
    const dvtp4_vdsx = vdsx.scale(dvtp4);
    const dvtp4_exp2 = dvtp4_vdsx.scale(2.0).minC(80.0).exp();
    const dvtp4_tanh = dvtp4_exp2.addC(-1.0).div(dvtp4_exp2.addC(1.0).maxC(1.0e-30));
    // dvth_dits = -n_eff*vt*log(dvtp_log_arg) - dvtp5 + dvtp2/leff*dvtp3*dvtp4_tanh
    const dvth_dits = n_eff.scale(vt).mul(dvtp_log_arg.maxC(1.0e-30).log()).neg().addC(-dvtp5).add(dvtp4_tanh.scale(dvtp2 / @max(leff, 1.0e-30) * dvtp3));

    const dvth_all = dvth_vnud.add(dvth_dibl).add(dvth_dits);

    // Effective gate voltage with SCE
    const vgfb = vgs_eff.sub(vfb_t_s).sub(dvth_all);

    // --- Source-side charge ---
    const v_qs = psi_p.addC(-2.0 * phi_b); // vch_s = 0
    const ln_q0_s = v_qs.addC(-0.201491).sub(v_qs.mul(v_qs.addC(0.402982)).addC(2.446562).maxC(1.0e-30).sqrt()).scale(0.5);
    const q_s_raw = ln_q0_s.minC(40.0).exp();
    // Newton correction: q_s = max(q_s_raw * max(1 + vgfb/(nvt*max(nq,1.001))*0.5, 0.01), 1e-30)
    const q_s = q_s_raw.mul(vgfb.div(nq.maxC(1.001).scale(nvt)).scale(0.5).addC(1.0).maxC(0.01)).maxC(1.0e-30);

    // --- Drain-side charge ---
    const v_qd = psi_p.addC(-2.0 * phi_b).sub(vds_eff_use); // vch_d = vds_eff_use
    const ln_q0_d = v_qd.addC(-0.201491).sub(v_qd.mul(v_qd.addC(0.402982)).addC(2.446562).maxC(1.0e-30).sqrt()).scale(0.5);
    const q_d_raw = ln_q0_d.minC(40.0).exp();
    const q_d = q_d_raw.maxC(1.0e-30);

    // --- Drain Saturation Voltage ---
    const etamob = p.etamob;
    const eta_field: f64 = if (type_f > 0.0) 0.5 * etamob else etamob / 3.0;
    const q_bs = psi_p.sub(q_s).maxC(0.0);
    const e_eff_s = q_bs.add(q_s.scale(eta_field)).scale(1.0e-8 / (eps_ratio * toxe));

    const eu_eff: f64 = @max(p.eu_t, 0.1);
    const ua_t = p.ua_t;
    const uc_t = p.uc_t;
    const ud_t = p.ud_t;
    const ucs_t = p.ucs_t;
    // sqrt_ratio = max(0.5*sqrt(max(1 + q_bs/q_s, 1e-30)), 1e-30)
    const sqrt_ratio = q_bs.div(q_s.maxC(1.0e-30)).addC(1.0).maxC(1.0e-30).sqrt().scale(0.5).maxC(1.0e-30);
    // d_mob_s = 1 + (ua_t + uc_t*vbsx)*exp(eu_eff*log(e_eff_s)) + ud_t/exp(ucs_t*log(sqrt_ratio))
    const d_mob_s = vbsx.scale(uc_t).addC(ua_t).mul(e_eff_s.maxC(1.0e-30).log().scale(eu_eff).exp()).addC(1.0).add(sqrt_ratio.log().scale(ucs_t).exp().pow(-1.0).scale(ud_t));

    // PSATB smoothing
    const psatb: f64 = @as(f64, model.psatb);
    const t11 = vbsx.scale(psatb);
    const t12 = t11.neg().addC(1.0).mul(t11.neg().addC(1.0)).maxC(1.0e-30);
    const psat_smooth = t11.neg().addC(1.0).add(t12.addC(0.04).sqrt()).scale(0.5);

    // Velocity saturation parameter (lambda_C)
    const psat: f64 = @max(@as(f64, model.psat), 0.25);
    const ptwg: f64 = @as(f64, model.ptwg);
    const psatx: f64 = @as(f64, model.psatx);
    const mob0_t = p.mob0_t;
    const vsat_t = p.vsat_t;
    // lambda_c = 2*mob0_t*n_eff*vt / (exp(log(d_mob_s)/psat)*vsat_t*leff) * (1 + ptwg*10*psatx*q_s*psat_smooth/(10*psatx + q_s*psat_smooth))
    const lc_pre = n_eff.scale(2.0 * mob0_t * vt).div(d_mob_s.maxC(1.0e-30).log().scale(1.0 / psat).exp().scale(vsat_t * leff));
    const lc_ptwg_num = q_s.mul(psat_smooth).scale(ptwg * 10.0 * psatx);
    const lc_ptwg_den = q_s.mul(psat_smooth).addC(10.0 * psatx).maxC(1.0e-30);
    const lambda_c = lc_pre.mul(lc_ptwg_num.div(lc_ptwg_den).addC(1.0));

    // q_dsat = lambda_c/2*(q_s^2+q_s)/(1 + (lambda_c/2)^2*(1+q_s))
    const lc_half = lambda_c.scale(0.5);
    const q_dsat_num = q_s.mul(q_s).add(q_s).mul(lc_half);
    const q_dsat_den = lc_half.mul(lc_half).mul(q_s.addC(1.0)).addC(1.0);
    const q_dsat = q_dsat_num.div(q_dsat_den);

    // --- Mobility degradation at average ---
    const q_ia = q_s.add(q_d).scale(0.5);
    const q_ba = psi_p.sub(q_ia).maxC(0.0);
    const e_eff_m = q_ba.add(q_ia.scale(eta_field)).scale(1.0e-8 / (eps_ratio * toxe));
    const sqrt_ratio_m = q_ba.div(q_ia.maxC(1.0e-30)).addC(1.0).maxC(1.0e-30).sqrt().scale(0.5).maxC(1.0e-30);
    const d_mob = vbsx.scale(uc_t).addC(ua_t).mul(e_eff_m.maxC(1.0e-30).log().scale(eu_eff).exp()).addC(1.0).add(sqrt_ratio_m.log().scale(ucs_t).exp().pow(-1.0).scale(ud_t));

    // --- AbulkIV ---
    const a0_p: f64 = @as(f64, model.a0);
    const ags_p: f64 = @as(f64, model.ags);
    const ags1_p: f64 = @as(f64, model.ags1);
    const keta_p: f64 = @as(f64, model.keta);
    const xj_val = p.xj_val;
    const xdep = p.xdep;
    const t1_abulk: f64 = leff / @max(leff + @sqrt(@max(xj_val * xdep, 1.0e-30)), 1.0e-30);
    // abulk_iv = 1 + (a0*t1 - ags*exp(ags1*log(q_s))*vt*t1)/(1+keta*vbsx)
    const abulk_num = q_s.maxC(1.0e-30).log().scale(ags1_p).exp().scale(ags_p * vt * t1_abulk).neg().addC(a0_p * t1_abulk);
    const abulk_iv = abulk_num.div(vbsx.scale(keta_p).addC(1.0).maxC(1.0e-30)).addC(1.0);
    const abulk_eff = abulk_iv.maxC(0.1);

    // --- Vdsat and Vdseff ---
    // vdsat_raw = 2*n_eff*vt*q_dsat/abulk_eff  (n_eff is S)
    const vdsat_s = n_eff.scale(2.0 * vt).mul(q_dsat).div(abulk_eff);
    const vdsat = vdsat_s.maxC(1.0e-6);

    const delta_sm: f64 = @max(p.delta_param, 0.001);
    const vds_over_vdsat = vds_eff_use.div(vdsat.maxC(1.0e-30));
    const t7 = vds_over_vdsat.maxC(1.0e-30).log().scale(1.0 / delta_sm).exp();
    const vdseff = vds_eff_use.div(t7.addC(1.0).maxC(1.0).log().scale(delta_sm).exp());

    // --- Velocity saturation (d_vsat) ---
    const q_deff = q_d;
    const t1_vs = q_s.sub(q_deff).mul(lambda_c).scale(2.0);
    const t1_sq = t1_vs.mul(t1_vs).addC(1.0).maxC(1.0).sqrt();
    // d_vsat = max(0.5*(t1_sq + log(t1_vs + t1_sq)/t1_vs), 0.5)
    const d_vsat = t1_sq.add(t1_vs.add(t1_sq).log().div(t1_vs.maxC(1.0e-30))).scale(0.5).maxC(0.5);

    // --- Parasitic Series Resistance ---
    const rdsmod: i32 = model.rdsmod;
    const wr: f64 = @as(f64, model.wr);
    const prwg_p: f64 = @as(f64, model.prwg);
    const prwb_p: f64 = @as(f64, model.prwb);
    const rdswmin: f64 = @as(f64, model.rdswmin);
    const rdsw_t = p.rdsw_t;

    const weff_wr: f64 = contract.fmath.exp(wr * contract.fmath.log(@max(nf_f * weff, 1.0e-30)));

    // t0_rds = max(1 + prwg*q_ia, 0.01)
    const t0_rds = q_ia.scale(prwg_p).addC(1.0).maxC(0.01);
    // t1_rds = prwb*(sqrt(phi_st - vbs_eff*vt) - sqrt(phi_st))
    const t1_rds = vbs_eff.scale(vt).neg().addC(phi_st).maxC(1.0e-30).sqrt().addC(-@sqrt(phi_st)).scale(prwb_p);
    const t2_rds = t0_rds.pow(-1.0).add(t1_rds);
    const t3_rds = t2_rds.add(t2_rds.mul(t2_rds).addC(0.01).sqrt()).scale(0.5);
    const rds_int = if (rdsmod == 0)
        t3_rds.scale(rdsw_t).addC(rdswmin).scale(weff_wr)
    else
        con(S, 0.0);

    // Dr factor
    const d_r_s = if (rdsmod == 0)
        // 1 + mob0_t/(d_mob*d_vsat)*cox*weff/leff*q_ia*rds_int
        q_ia.mul(rds_int).mul(con(S, mob0_t * cox * weff / leff)).div(d_mob.mul(d_vsat)).addC(1.0)
    else
        con(S, 1.0);

    const d_tot = d_mob.mul(d_vsat).mul(d_r_s);

    // --- Output Conductance ---
    const pclm: f64 = @as(f64, model.pclm);
    const pclmg: f64 = @as(f64, model.pclmg);
    const fprout: f64 = @as(f64, model.fprout);
    // e_sat = 2*vsat_t / max(mob0_t/d_mob, 1e-30)   (d_mob is S).
    // Clamp the RATIO mob0_t/d_mob (not mob0_t alone) exactly as the old code,
    // so the clamp semantics are identical when the ratio underflows.
    const e_sat = con(S, 2.0 * vsat_t).div(con(S, mob0_t).div(d_mob).maxC(1.0e-30));
    const f_fprout: f64 = if (fprout > 0.0) 1.0 / (1.0 + fprout * @sqrt(leff)) else 1.0;
    const c_clm = if (pclmg > 0.0)
        // pclm*(1 + pclmg*(q_ia + 2*n_eff*vt)/(e_sat*leff))*f_fprout
        q_ia.add(n_eff.scale(2.0 * vt)).div(e_sat.scale(leff).maxC(1.0e-30)).scale(pclmg).addC(1.0).scale(pclm * f_fprout)
    else if (pclmg < 0.0)
        // pclm/max(1 - pclmg*q_ia/(e_sat*leff), 0.01)*f_fprout
        con(S, pclm * f_fprout).div(q_ia.div(e_sat.scale(leff).maxC(1.0e-30)).scale(-pclmg).addC(1.0).maxC(0.01))
    else
        e_sat.scale(0.0).addC(@max(pclm, 1.0e-30) * f_fprout); // constant, but keep S type

    // vasat = vdsat + e_sat*leff
    const vasat = vdsat.add(e_sat.scale(leff));
    const vds_minus_vdseff = vds_eff_use.sub(vdseff).maxC(0.0);
    const m_clm = vds_minus_vdseff.div(vasat.maxC(1.0e-30)).addC(1.0).log().mul(c_clm).addC(1.0);

    // DIBL
    const pdiblc: f64 = @max(@as(f64, model.pdiblc), 1.0e-30);
    const pdiblcb: f64 = @as(f64, model.pdiblcb);
    const pvag_p: f64 = @as(f64, model.pvag);
    const q_im = q_ia;
    const pvag_factor = if (pvag_p > 0.0)
        q_im.div(e_sat.scale(leff).maxC(1.0e-30)).scale(pvag_p).addC(1.0)
    else if (pvag_p < 0.0)
        con(S, 1.0).div(q_im.div(e_sat.scale(leff).maxC(1.0e-30)).scale(-pvag_p).addC(1.0).maxC(0.01))
    else
        con(S, 1.0);
    // va_dibl = (q_ia + 2*vt)/pdiblc*(1 - vdsat/(vdsat+q_ia+2*vt))*pvag_factor/(1+pdiblcb*vbsx)
    const va_dibl = q_ia.addC(2.0 * vt).scale(1.0 / pdiblc).mul(vdsat.div(vdsat.add(q_ia).addC(2.0 * vt).maxC(1.0e-30)).neg().addC(1.0)).mul(pvag_factor).div(vbsx.scale(pdiblcb).addC(1.0).maxC(0.01));
    const m_dibl = vds_minus_vdseff.div(va_dibl.maxC(1.0e-30)).addC(1.0);

    // DITS
    const pdits: f64 = @as(f64, model.pdits);
    const pditsl: f64 = @as(f64, model.pditsl);
    const pditsd: f64 = @as(f64, model.pditsd);
    const va_dits = if (pdits > 0.0)
        vds_eff_use.scale(pditsd).minC(80.0).exp().scale(1.0 + pditsl * leff).addC(1.0).scale(1.0 / @max(pdits, 1.0e-30) * f_fprout)
    else
        con(S, 1.0e30);
    const m_dits = vds_minus_vdseff.div(va_dits.maxC(1.0e-30)).addC(1.0);

    // SCBE
    const pscbe1: f64 = @as(f64, model.pscbe1);
    const pscbe2: f64 = @as(f64, model.pscbe2);
    const litl: f64 = @sqrt(eps_sub / eps_ox * toxe * xj_val);
    // va_scbe = leff/pscbe2*exp(pscbe1*litl/vds_minus_vdseff)
    const va_scbe = vds_minus_vdseff.maxC(1.0e-6).pow(-1.0).scale(pscbe1 * litl).minC(80.0).exp().scale(leff / @max(pscbe2, 1.0e-30));
    const m_scbe = vds_minus_vdseff.div(va_scbe.maxC(1.0e-30)).addC(1.0);

    const m_oc = m_dibl.mul(m_clm).mul(m_dits).mul(m_scbe);

    // --- Drain Current ---
    const mu_eff = con(S, mob0_t).div(d_tot.maxC(1.0e-30));
    // ids_base = 2*nq*mu_eff*weff/leff*cox*(n_eff*vt)^2*(q_s-q_deff)*(q_s+q_deff+1)*m_oc
    const nevt = n_eff.scale(vt);
    const ids_base = nq.scale(2.0).mul(mu_eff).scale(weff / leff * cox).mul(nevt).mul(nevt).mul(q_s.sub(q_deff)).mul(q_s.add(q_deff).addC(1.0)).mul(m_oc);

    // --- MNUD ---
    const k0_p: f64 = @as(f64, model.k0);
    const m0_p: f64 = @as(f64, model.m0);
    const qs_minus_qd = q_s.sub(q_deff);
    const qs_plus_qd = q_s.add(q_deff);
    const mnud_ratio = qs_minus_qd.div(qs_plus_qd.addC(m0_p).maxC(1.0e-30));
    const mnud = mnud_ratio.mul(mnud_ratio).scale(k0_p).addC(1.0);

    // --- MNUD1 ---
    const c0_p: f64 = @as(f64, model.c0);
    const c0si: f64 = @as(f64, model.c0si);
    const c0sisat: f64 = @as(f64, model.c0sisat);
    // mnud1_arg = -c0/((c0si + c0sisat*(qs-qd)^2)*(qs+qd) + 2*n_eff*vt)
    const mnud1_den = qs_minus_qd.mul(qs_minus_qd).scale(c0sisat).addC(c0si).mul(qs_plus_qd).add(n_eff.scale(2.0 * vt)).maxC(1.0e-30);
    const mnud1_arg = mnud1_den.pow(-1.0).scale(-c0_p);
    const mnud1 = mnud1_arg.minC(0.0).maxC(-80.0).exp();

    const ids_mnud = ids_base.div(mnud.mul(mnud1).maxC(1.0e-30));

    // --- Non-saturation effect ---
    const a1_p: f64 = @as(f64, model.a1);
    const a2_p: f64 = @as(f64, model.a2);
    // t0_nsat = a1 + a2/(q_ia + 2*n_eff*vt)
    const t0_nsat = q_ia.add(n_eff.scale(2.0 * vt)).maxC(1.0e-30).pow(-1.0).scale(a2_p).addC(a1_p);
    const t0v = t0_nsat.mul(vds_eff_use);
    const t3_nsat = t0v.scale(0.5).add(t0v.mul(t0v).addC(0.004).sqrt().scale(0.5)).addC(-1.0).maxC(0.0);
    const n_sat = t3_nsat.addC(1.0).sqrt().addC(1.0).scale(0.5);

    const ids_nsat = ids_mnud.div(n_sat.maxC(1.0));

    // Apply IDS0MULT
    const ids0mult: f64 = @as(f64, model.ids0mult) * @as(f64, instance.ids0mult);
    var ids_final = ids_nsat.scale(ids0mult * nf_f);

    // --- Edge FET ---
    const edgefet: i32 = instance.edgefet;
    const wedge: f64 = @as(f64, model.wedge);
    if (edgefet != 0) {
        // 2*nf*nq*mu_eff*wedge/leff*cox*n_eff*vt*(q_s-q_deff)*(1+q_s+q_deff)*m_oc
        const ids_edge = nq.scale(2.0 * nf_f).mul(mu_eff).scale(wedge / leff * cox).mul(nevt).mul(q_s.sub(q_deff)).mul(q_s.add(q_deff).addC(1.0)).mul(m_oc);
        ids_final = ids_final.add(ids_edge);
    }

    // --- Sub-surface leakage ---
    const sslmod: i32 = instance.sslmod;
    if (sslmod != 0) {
        const ssl0: f64 = @as(f64, model.ssl0);
        const ssl1: f64 = @as(f64, model.ssl1);
        const ssl2: f64 = @as(f64, model.ssl2);
        const ssl3: f64 = @as(f64, model.ssl3);
        const ssl4: f64 = @as(f64, model.ssl4);
        const ssl5: f64 = @as(f64, model.ssl5);
        const t3_ssl = vbs_i.scale(type_f * ssl5 / vt);
        const vgb_i = vgs_i.sub(vbs_i);
        const vth_approx = dvth_all.addC(0.0).add(vfb_t_s); // vfb_t + dvth_all
        // ssl4_exp_arg = exp(type*ssl4*(vgb_i - vth_approx - vbs_i))
        const ssl4_exp_arg = vgb_i.sub(vth_approx).sub(vbs_i).scale(type_f * ssl4).minC(80.0).exp();
        const ssl4_exp2 = ssl4_exp_arg.scale(2.0).minC(80.0).exp();
        const ssl4_tanh = ssl4_exp2.addC(-1.0).div(ssl4_exp2.addC(1.0).maxC(1.0e-30));
        const t5_ssl = ssl4_tanh.scale(ssl3);
        // i_ssl = vds_sign*nf*weff*ssl0*exp(t3_ssl)*exp(-ssl1*l_drawn + t5_ssl/vt)*(exp(ssl2*vdsx/vt)-1)
        const i_ssl = t3_ssl.minC(80.0).exp().scale(vds_sign * nf_f * weff * ssl0).mul(t5_ssl.scale(1.0 / vt).addC(-ssl1 * l_drawn).minC(80.0).exp()).mul(vdsx.scale(ssl2 / vt).minC(80.0).exp().addC(-1.0));
        ids_final = ids_final.add(i_ssl);
    }

    // --- Impact Ionization ---
    const alpha0_p: f64 = @as(f64, model.alpha0);
    const beta0_p: f64 = @as(f64, model.beta0);
    const i_ii = if (alpha0_p > 0.0 and vds_minus_vdseff.val() > 0.001)
        // alpha0*vds_minus_vdseff*exp(-beta0/vds_minus_vdseff)*ids_final/m_scbe
        vds_minus_vdseff.scale(alpha0_p).mul(vds_minus_vdseff.maxC(1.0e-6).pow(-1.0).scale(-beta0_p).minC(80.0).exp()).mul(ids_final).div(m_scbe.maxC(1.0e-30))
    else
        con(S, 0.0);

    // --- GIDL/GISL ---
    const agidl: f64 = @as(f64, model.agidl);
    const bgidl: f64 = @as(f64, model.bgidl);
    const cgidl: f64 = @as(f64, model.cgidl);
    const egidl: f64 = @as(f64, model.egidl);
    const agisl: f64 = @as(f64, model.agisl);
    const bgisl: f64 = @as(f64, model.bgisl);
    const cgisl: f64 = @as(f64, model.cgisl);
    const egisl: f64 = @as(f64, model.egisl);
    const gidlmod: i32 = model.gidlmod;
    const toxe3: f64 = 3.0 * toxe;
    const vds_gse = vds_eff_use.sub(vgs_eff).addC(-egidl);
    const vdb_gidl = vds_eff_use.sub(vbs_eff);
    const vdb_gidl3 = vdb_gidl.mul(vdb_gidl).mul(vdb_gidl);
    const i_gidl = if (gidlmod != 0 and agidl > 0.0 and vds_gse.val() > 0.001)
        vds_gse.scale(agidl * weff * nf_f / toxe3).mul(vds_gse.maxC(1.0e-6).pow(-1.0).scale(-toxe3 * bgidl).minC(80.0).exp()).mul(vdb_gidl3).div(vdb_gidl3.addC(cgidl).maxC(1.0e-30))
    else
        con(S, 0.0);
    const neg_vds_gde = vds_eff_use.neg().sub(vgd_i).addC(-egisl);
    const vsb_gisl = vbs_eff.neg();
    const vsb_gisl3 = vsb_gisl.mul(vsb_gisl).mul(vsb_gisl);
    const i_gisl = if (gidlmod != 0 and agisl > 0.0 and neg_vds_gde.val() > 0.001)
        neg_vds_gde.scale(agisl * weff * nf_f / toxe3).mul(neg_vds_gde.maxC(1.0e-6).pow(-1.0).scale(-toxe3 * bgisl).minC(80.0).exp()).mul(vsb_gisl3).div(vsb_gisl3.addC(cgisl).maxC(1.0e-30))
    else
        con(S, 0.0);

    // --- Gate Tunneling Current ---
    const igcmod: i32 = model.igcmod;
    const igbmod: i32 = model.igbmod;
    const toxref: f64 = @as(f64, model.toxref);
    const ntox: f64 = @as(f64, model.ntox);
    const tox_ratio: f64 = contract.fmath.exp(ntox * contract.fmath.log(@max(toxref / toxe, 1.0e-30))) / (toxe * toxe);
    const igt_p: f64 = @as(f64, model.igt);
    const igtemp: f64 = contract.fmath.exp(igt_p * contract.fmath.log(p.t_ratio));

    // Vox = n_eff*vt*(vg_norm - vfb_norm - psi_p + q_s + q_deff)
    const vox = n_eff.scale(vt).mul(vg_norm.sub(vfb_norm).sub(psi_p).add(q_s).add(q_deff));
    const vox_acc = vox.neg().add(vox.mul(vox).addC(1.0e-4).sqrt()).scale(0.5);
    const vox_depinv = vox.add(vox.mul(vox).addC(1.0e-4).sqrt()).scale(0.5);

    const vgb_i = vgs_i.sub(vbs_i);

    // Igbacc
    const aigbacc: f64 = @as(f64, model.aigbacc);
    const bigbacc: f64 = @as(f64, model.bigbacc);
    const cigbacc: f64 = @as(f64, model.cigbacc);
    const nigbacc: f64 = @as(f64, model.nigbacc);
    const vaux_acc = vox.scale(-1.0 / @max(nigbacc * vt, 1.0e-30)).minC(80.0).exp().addC(1.0).log().scale(nigbacc * vt);
    const igb_acc = if (igbmod != 0)
        vgb_i.scale(nf_f * weff * leff * tox_ratio).mul(vaux_acc).scale(igtemp).mul(vox_acc.scale(bigbacc).addC(-aigbacc).mul(vox_acc.scale(cigbacc).addC(1.0)).scale(toxe).minC(80.0).exp())
    else
        con(S, 0.0);

    // Igbinv
    const aigbinv: f64 = @as(f64, model.aigbinv);
    const bigbinv: f64 = @as(f64, model.bigbinv);
    const cigbinv: f64 = @as(f64, model.cigbinv);
    const nigbinv: f64 = @as(f64, model.nigbinv);
    const vaux_inv = vox.scale(1.0 / @max(nigbinv * vt, 1.0e-30)).minC(80.0).exp().addC(1.0).log().scale(nigbinv * vt);
    const igb_inv = if (igbmod != 0)
        vgb_i.scale(nf_f * weff * leff * tox_ratio).mul(vaux_inv.maxC(1.0e-30)).scale(igtemp).mul(vox_depinv.scale(bigbinv).addC(-aigbinv).mul(vox_depinv.scale(cigbinv).addC(1.0)).scale(toxe).minC(80.0).exp())
    else
        con(S, 0.0);

    const igb = igb_acc.add(igb_inv);

    // Igc (gate to channel)
    const aigc_p: f64 = @as(f64, model.aigc);
    const bigc_p: f64 = @as(f64, model.bigc);
    const cigc_p: f64 = @as(f64, model.cigc);
    const pigcd: f64 = @as(f64, model.pigcd);
    const vaux_gc = nq.mul(n_eff).scale(vt).mul(q_s.add(q_deff));
    const igc0 = if (igcmod != 0)
        vgs_eff.scale(nf_f * weff * leff * tox_ratio).mul(vaux_gc.maxC(1.0e-30)).scale(igtemp).mul(vox_depinv.scale(bigc_p).addC(-aigc_p).mul(vox_depinv.scale(cigc_p).addC(1.0)).scale(toxe).minC(80.0).exp())
    else
        con(S, 0.0);

    // Partition Igcs/Igcd
    const pigcd_vds = vdseff.scale(pigcd);
    const pigcd_vds_sq = pigcd_vds.mul(pigcd_vds).addC(2.0e-4);
    const igcs = igc0.mul(pigcd_vds.add(pigcd_vds.neg().minC(80.0).exp()).addC(-1.0 + 1.0e-4)).div(pigcd_vds_sq.maxC(1.0e-30));
    const igcd = igc0.mul(pigcd_vds.addC(1.0).mul(pigcd_vds.neg().minC(80.0).exp()).neg().addC(1.0 + 1.0e-4)).div(pigcd_vds_sq.maxC(1.0e-30));

    // Igs/Igd
    const aigs_p: f64 = @as(f64, model.aigs);
    const bigs_p: f64 = @as(f64, model.bigs);
    const cigs_p: f64 = @as(f64, model.cigs);
    const aigd_p: f64 = @as(f64, model.aigd);
    const bigd_p: f64 = @as(f64, model.bigd);
    const cigd_p: f64 = @as(f64, model.cigd);
    const dlcig: f64 = @as(f64, model.dlcig);
    const dlcigd: f64 = @as(f64, model.dlcigd);
    const poxedge: f64 = @as(f64, model.poxedge);
    const vfbsdoff: f64 = @as(f64, model.vfbsdoff) + @as(f64, instance.vfbsdoff);

    const vgs_vfbsd = vgs_i.addC(-vfbsdoff);
    const vgs_prime = vgs_vfbsd.mul(vgs_vfbsd).addC(1.0e-4).sqrt();
    const igs = if (igcmod != 0 and dlcig > 0.0)
        vgs_i.scale(nf_f * weff * dlcig * tox_ratio).mul(vgs_prime).scale(igtemp).mul(vgs_prime.scale(bigs_p).addC(-aigs_p).mul(vgs_prime.scale(cigs_p).addC(1.0)).scale(toxe * poxedge).minC(80.0).exp())
    else
        con(S, 0.0);

    const vgd_vfbsd = vgd_i.addC(-vfbsdoff);
    const vgd_prime = vgd_vfbsd.mul(vgd_vfbsd).addC(1.0e-4).sqrt();
    const igd = if (igcmod != 0 and dlcigd > 0.0)
        vgd_i.scale(nf_f * weff * dlcigd * tox_ratio).mul(vgd_prime).scale(igtemp).mul(vgd_prime.scale(bigd_p).addC(-aigd_p).mul(vgd_prime.scale(cigd_p).addC(1.0)).scale(toxe * poxedge).minC(80.0).exp())
    else
        con(S, 0.0);

    // --- Junction Diode IV ---
    const vbs_junc = vbp.sub(vsp);
    const vbd_junc = vbp.sub(vdp);

    const eg_nom = p.eg_nom;
    const eg = p.eg;
    const vt_nom = p.vt_nom;
    const t_ratio = p.t_ratio;

    // Source junction
    const jss: f64 = @as(f64, model.jss);
    const jsws: f64 = @as(f64, model.jsws);
    const jswgs: f64 = @as(f64, model.jswgs);
    const njs: f64 = @as(f64, model.njs);
    const bvs: f64 = @as(f64, model.bvs);
    const xjbvs: f64 = @as(f64, model.xjbvs);
    const xtis: f64 = @as(f64, model.xtis);
    const j_temp_s: f64 = contract.fmath.exp((eg_nom / vt_nom - eg / vt + xtis * contract.fmath.log(t_ratio)) / njs);
    const jss_t: f64 = jss * j_temp_s;
    const jsws_t: f64 = jsws * j_temp_s;
    const jswgs_t: f64 = jswgs * j_temp_s;

    const as_eff: f64 = @as(f64, instance.as_);
    const ps_eff: f64 = @as(f64, instance.ps);
    const ad_eff: f64 = @as(f64, instance.ad);
    const pd_eff: f64 = @as(f64, instance.pd);
    const weff_cj: f64 = weff;

    const isbs: f64 = as_eff * jss_t + ps_eff * jsws_t + weff_cj * nf_f * jswgs_t;

    const vbs_nvt = vbs_junc.scale(1.0 / @max(njs * vt, 1.0e-30));
    // f_breakdown_s = 1 + xjbvs*exp(-(bvs+vbs_junc)/(njs*vt))
    const f_breakdown_s = vbs_junc.addC(bvs).scale(-1.0 / @max(njs * vt, 1.0e-30)).minC(80.0).exp().scale(xjbvs).addC(1.0);
    const ibs = vbs_nvt.minC(80.0).exp().addC(-1.0).scale(isbs).mul(f_breakdown_s).add(vbs_junc.scale(GMIN));

    // Drain junction
    const jsd: f64 = @as(f64, model.jsd);
    const jswd: f64 = @as(f64, model.jswd);
    const jswgd: f64 = @as(f64, model.jswgd);
    const njd: f64 = @as(f64, model.njd);
    const bvd: f64 = @as(f64, model.bvd);
    const xjbvd: f64 = @as(f64, model.xjbvd);
    const xtid: f64 = @as(f64, model.xtid);
    const j_temp_d: f64 = contract.fmath.exp((eg_nom / vt_nom - eg / vt + xtid * contract.fmath.log(t_ratio)) / njd);
    const jsd_t: f64 = jsd * j_temp_d;
    const jswd_t: f64 = jswd * j_temp_d;
    const jswgd_t: f64 = jswgd * j_temp_d;

    const isbd: f64 = ad_eff * jsd_t + pd_eff * jswd_t + weff_cj * nf_f * jswgd_t;

    const vbd_nvt = vbd_junc.scale(1.0 / @max(njd * vt, 1.0e-30));
    const f_breakdown_d = vbd_junc.addC(bvd).scale(-1.0 / @max(njd * vt, 1.0e-30)).minC(80.0).exp().scale(xjbvd).addC(1.0);
    const ibd = vbd_nvt.minC(80.0).exp().addC(-1.0).scale(isbd).mul(f_breakdown_d).add(vbd_junc.scale(GMIN));

    // --- Tunneling component of junction current ---
    const jtss_p: f64 = @as(f64, model.jtss);
    const njts_p: f64 = @as(f64, model.njts);
    const vtss_p: f64 = @as(f64, model.vtss);
    const jtsd_p: f64 = @as(f64, model.jtsd);
    const njtsd_p: f64 = @as(f64, model.njtsd);
    const vtsd_p: f64 = @as(f64, model.vtsd);
    const ibs_tun = if (jtss_p > 0.0)
        // -as*jtss*(exp(-vbs_junc/(njts*vt))*vtss/(vtss-vbs_junc) - 1)
        vbs_junc.scale(-1.0 / @max(njts_p * vt, 1.0e-30)).minC(80.0).exp().scale(vtss_p).div(vbs_junc.neg().addC(vtss_p).maxC(1.0e-30)).addC(-1.0).scale(-as_eff * jtss_p)
    else
        con(S, 0.0);
    const ibd_tun = if (jtsd_p > 0.0)
        vbd_junc.scale(-1.0 / @max(njtsd_p * vt, 1.0e-30)).minC(80.0).exp().scale(vtsd_p).div(vbd_junc.neg().addC(vtsd_p).maxC(1.0e-30)).addC(-1.0).scale(-ad_eff * jtsd_p)
    else
        con(S, 0.0);

    const ibs_total = ibs.add(ibs_tun);
    const ibd_total = ibd.add(ibd_tun);

    // --- Series Resistance Branches ---
    const rsw_p: f64 = @as(f64, model.rsw);
    const rdw_p: f64 = @as(f64, model.rdw);
    const rswmin_p: f64 = @as(f64, model.rswmin);
    const rdwmin_p: f64 = @as(f64, model.rdwmin);
    const rsh_p: f64 = @as(f64, model.rsh);
    const nrs_p: f64 = @as(f64, instance.nrs);
    const nrd_p: f64 = @as(f64, instance.nrd);

    const rs_geo: f64 = nrs_p * rsh_p;
    const rd_geo: f64 = nrd_p * rsh_p;

    const g_rs: f64 = if (rdsmod == 1)
        (if ((rswmin_p + rsw_p) > 0.0)
            weff_wr * nf_f / @max(rswmin_p + rsw_p + rs_geo * weff_wr * nf_f, 1.0e-30)
        else if (rs_geo > 0.0)
            1.0 / rs_geo
        else
            GSHORT)
    else if (rsh_p > 0.0 and nrs_p > 0.0)
        1.0 / rs_geo
    else
        GSHORT;

    const g_rd: f64 = if (rdsmod == 1)
        (if ((rdwmin_p + rdw_p) > 0.0)
            weff_wr * nf_f / @max(rdwmin_p + rdw_p + rd_geo * weff_wr * nf_f, 1.0e-30)
        else if (rd_geo > 0.0)
            1.0 / rd_geo
        else
            GSHORT)
    else if (rsh_p > 0.0 and nrd_p > 0.0)
        1.0 / rd_geo
    else
        GSHORT;

    const i_rs = x[Ssrc].sub(x[SP]).scale(g_rs);
    const i_rd = x[D].sub(x[DP]).scale(g_rd);

    // --- Gate Resistance ---
    const rgatemod: i32 = model.rgatemod;
    const rshg: f64 = @as(f64, model.rshg);
    const xgw_p: f64 = @as(f64, model.xgw) + @as(f64, instance.xgw);
    const ngcon_i: f64 = @floatFromInt(@as(i32, if (instance.ngcon > 0) instance.ngcon else model.ngcon));
    const xgl: f64 = @as(f64, model.xgl);
    const weff_ci: f64 = weff;
    const l_gate: f64 = @max(l_drawn - xgl, 1.0e-9);
    const r_gate: f64 = if (rgatemod > 0 and rshg > 0.0)
        rshg * (xgw_p + weff_ci / (3.0 * ngcon_i)) / @max(ngcon_i * l_gate * nf_f, 1.0e-30)
    else
        0.0;
    const g_gate: f64 = if (r_gate > 0.0) 1.0 / r_gate else GSHORT;
    const i_gate = x[G].sub(x[GP]).scale(g_gate);

    // --- Substrate Resistance Network ---
    const rbodymod_i: i32 = model.rbodymod;
    const gbmin: f64 = @as(f64, model.gbmin);
    const rbpb_p: f64 = @as(f64, instance.rbpb);
    const rbpd_p: f64 = @as(f64, instance.rbpd);
    const rbps_p: f64 = @as(f64, instance.rbps);
    const rbdb_p: f64 = @as(f64, instance.rbdb);
    const rbsb_p: f64 = @as(f64, instance.rbsb);

    const g_rbpb: f64 = if (rbodymod_i > 0) @max(1.0 / @max(rbpb_p, 1.0e-3), gbmin) else GSHORT;
    const g_rbpd: f64 = if (rbodymod_i > 0) @max(1.0 / @max(rbpd_p, 1.0e-3), gbmin) else GSHORT;
    const g_rbps: f64 = if (rbodymod_i > 0) @max(1.0 / @max(rbps_p, 1.0e-3), gbmin) else GSHORT;
    const g_rbdb: f64 = if (rbodymod_i > 0) @max(1.0 / @max(rbdb_p, 1.0e-3), gbmin) else GSHORT;
    const g_rbsb: f64 = if (rbodymod_i > 0) @max(1.0 / @max(rbsb_p, 1.0e-3), gbmin) else GSHORT;

    const i_rbpb = x[BP].sub(x[B]).scale(g_rbpb);
    const i_rbpd = x[BP].sub(x[DBN]).scale(g_rbpd);
    const i_rbps = x[BP].sub(x[SBN]).scale(g_rbps);
    const i_rbdb = x[DBN].sub(x[B]).scale(g_rbdb);
    const i_rbsb = x[SBN].sub(x[B]).scale(g_rbsb);

    // --- Assemble current contributions ---
    const ids_ch = ids_final.scale(type_f * vds_sign);
    const mf: f64 = p.m_mult;

    var out: [n_u]S = undefined;
    // gate
    out[G] = i_gate.scale(mf);
    // drain
    out[D] = i_rd.scale(mf);
    // source
    out[Ssrc] = i_rs.scale(mf);
    // bulk
    out[B] = i_rbpb.neg().sub(i_rbdb).sub(i_rbsb).scale(mf);
    // drain_prime
    out[DP] = ids_ch.sub(i_rd).add(ibd_total.scale(type_f)).add(igcd.add(igd).scale(type_f)).add(i_gidl.scale(type_f)).add(i_ii.scale(type_f)).scale(mf);
    // source_prime
    out[SP] = ids_ch.neg().sub(i_rs).add(ibs_total.scale(type_f)).add(igcs.add(igs).scale(type_f)).add(i_gisl.scale(type_f)).scale(mf);
    // gate_prime
    out[GP] = i_gate.neg().add(igcs.add(igcd).add(igs).add(igd).add(igb).scale(type_f)).scale(mf);
    // body_prime
    out[BP] = i_rbpb.add(i_rbpd).add(i_rbps).sub(ibs_total.scale(type_f)).sub(ibd_total.scale(type_f)).sub(igb.scale(type_f)).sub(i_gidl.scale(type_f)).sub(i_gisl.scale(type_f)).sub(i_ii.scale(type_f)).scale(mf);
    // db_node
    out[DBN] = i_rbpd.neg().add(i_rbdb).scale(mf);
    // sb_node
    out[SBN] = i_rbps.neg().add(i_rbsb).scale(mf);

    return out;
}

// ============================================================================
// Charge function: q (Section 9 — C-V Model)
// ============================================================================

/// Body-prime intrinsic charge = -(q_g + q_s + q_d), a charge-conservation
/// cancellation residual. Evaluated in strict float mode so the compiler does
/// NOT reassociate the three-term add: this pins the sub-epsilon residual to
/// the same left-to-right association `-((q_g + q_s) + q_d)` used by the old
/// flat f64 reference expression, making it deterministic and bit-for-bit
/// reproducible instead of depending on .optimized reassociation. Still pure
/// S ops, so the Jacobian entry is preserved.
fn qbPhys(comptime S: type, q_g: S, q_s: S, q_d: S) S {
    @setFloatMode(.strict);
    return q_g.add(q_s).add(q_d).neg();
}

/// x-independent CV parameter/geometry preprocessing (pure f64).
const QPrep = struct {
    type_f: f64,
    vt: f64,
    cox_cv: f64,
    nf_f: f64,
    m_mult: f64,
    weff_cv: f64,
    leff_cv: f64,
    temp_k: f64,
    tnom_k: f64,
};

fn qprep(model: *const Model, instance: *const Instance) QPrep {
    const q_e: f64 = 1.6e-19;
    const eps0: f64 = 8.8542e-12;
    const k_b: f64 = 1.380649e-23;

    const type_f: f64 = @floatFromInt(model.type_);
    const toxe: f64 = @as(f64, model.toxe);

    const tnom_k: f64 = @as(f64, model.tnom) + 273.15;
    const temp_k: f64 = tnom_k + @as(f64, instance.dtemp) + @as(f64, model.dtemp);
    const vt: f64 = k_b * temp_k / q_e;

    const nf_f: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const lmlt: f64 = @as(f64, model.lmlt);
    const wmlt: f64 = @as(f64, model.wmlt);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);
    const l_new: f64 = @as(f64, instance.l) * lmlt + xl;
    const w_new: f64 = @as(f64, instance.w) / nf_f * wmlt + xw;
    const dlc: f64 = @as(f64, model.dlc);
    const dwc: f64 = @as(f64, model.dwc);
    const leff_cv: f64 = @max(l_new - 2.0 * dlc, 1.0e-9);
    const weff_cv: f64 = @max(w_new - 2.0 * dwc, 1.0e-9);

    const cox_cv: f64 = 3.9 * eps0 / toxe;

    return .{
        .type_f = type_f,
        .vt = vt,
        .cox_cv = cox_cv,
        .nf_f = nf_f,
        .m_mult = m_mult,
        .weff_cv = weff_cv,
        .leff_cv = leff_cv,
        .temp_k = temp_k,
        .tnom_k = tnom_k,
    };
}

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, 0.0);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const G = @intFromEnum(U.gate);
    const D = @intFromEnum(U.drain);
    const Ssrc = @intFromEnum(U.source);
    const B = @intFromEnum(U.bulk);
    const DP = @intFromEnum(U.drain_prime);
    const SP = @intFromEnum(U.source_prime);
    const GP = @intFromEnum(U.gate_prime);
    const BP = @intFromEnum(U.body_prime);
    const DBN = @intFromEnum(U.db_node);
    const SBN = @intFromEnum(U.sb_node);

    const con = struct {
        fn f(comptime T: type, c: f64) T {
            return T.con(c);
        }
    }.f;

    const p = &pc.q;
    const type_f = p.type_f;
    const vt = p.vt;
    const nf_f = p.nf_f;
    const cox_cv = p.cox_cv;
    const weff_cv = p.weff_cv;
    const leff_cv = p.leff_cv;
    const temp_k = p.temp_k;
    const tnom_k = p.tnom_k;

    // Terminal voltages
    const vgp = x[GP];
    const vdp = x[DP];
    const vsp = x[SP];
    const vbp = x[BP];

    const vgs_i = vgp.sub(vsp).scale(type_f);
    const vds_i = vdp.sub(vsp).scale(type_f);
    const vbs_i = vbp.sub(vsp).scale(type_f);

    // Source-drain reversal
    const vds_abs = vds_i.abs();
    const vds_neg = vds_i.minC(0.0);
    const vgs_eff = vgs_i.sub(vds_neg);
    const vds_eff_use = vds_abs;

    // Simplified charge computation using Ward-Dutton partitioning
    const vfb_cv: f64 = @as(f64, model.vfbcv);
    const vgfb_cv = vgs_eff.addC(-vfb_cv);

    // Rough charge estimate (normalized)
    const q_s_cv = vgfb_cv.scale(1.0 / (2.0 * vt)).minC(40.0).exp().scale(0.01).maxC(1.0e-30);
    const q_d_cv = vgfb_cv.sub(vds_eff_use).scale(1.0 / (2.0 * vt)).minC(40.0).exp().scale(0.01).maxC(1.0e-30);

    const nq_cv: f64 = 1.5;
    const qs_minus_qd = q_s_cv.sub(q_d_cv);
    const qs_plus_qd = q_s_cv.add(q_d_cv);

    // Source/Drain charge partition
    // q_source = nq/3*(2*qs + qd + 0.5*(1 + 1.2*qs + 0.8*qd)*(qs-qd)^2/(1+qs+qd))
    const denom = qs_plus_qd.addC(1.0).maxC(1.0e-30);
    const qsd_sq = qs_minus_qd.mul(qs_minus_qd);
    const q_source = q_s_cv.scale(2.0).add(q_d_cv).add(q_s_cv.scale(1.2).add(q_d_cv.scale(0.8)).addC(1.0).mul(qsd_sq).div(denom).scale(0.5)).scale(nq_cv / 3.0);
    const q_drain = q_s_cv.add(q_d_cv.scale(2.0)).add(q_s_cv.scale(0.8).add(q_d_cv.scale(1.2)).addC(1.0).mul(qsd_sq).div(denom).scale(0.5)).scale(nq_cv / 3.0);

    // Scale to physical charge
    const q_scale: f64 = cox_cv * weff_cv * leff_cv * nf_f * vt;
    const q_s_phys = q_source.scale(-q_scale);
    const q_d_phys = q_drain.scale(-q_scale);
    const q_g_phys = q_s_phys.add(q_d_phys).neg();

    // --- Overlap capacitances ---
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cgsl_p: f64 = @as(f64, model.cgsl);
    const cgdl_p: f64 = @as(f64, model.cgdl);

    const q_gs_ov = vgs_i.scale(cgso * weff_cv * nf_f);
    const q_gd_ov = vgs_i.sub(vds_eff_use).scale(cgdo * weff_cv * nf_f);
    const q_gb_ov = vgs_i.sub(vbs_i).scale(cgbo * leff_cv * nf_f);

    const q_gs_ov_dep = vgs_i.scale(cgsl_p * weff_cv * nf_f);
    const q_gd_ov_dep = vgs_i.sub(vds_eff_use).scale(cgdl_p * weff_cv * nf_f);

    // Outer fringe
    const cf_p: f64 = @as(f64, model.cf);
    const q_cf_s = vgs_i.scale(cf_p * nf_f);
    const q_cf_d = vgs_i.sub(vds_eff_use).scale(cf_p * nf_f);

    // --- Junction Depletion Charges ---
    const cjs_p: f64 = @as(f64, model.cjs);
    const mjs_p: f64 = @as(f64, model.mjs);
    const pbs_p: f64 = @as(f64, model.pbs);
    const cjsws_p: f64 = @as(f64, model.cjsws);
    const mjsws_p: f64 = @as(f64, model.mjsws);
    const pbsws_p: f64 = @as(f64, model.pbsws);
    const cjswgs_p: f64 = @as(f64, model.cjswgs);
    const mjswgs_p: f64 = @as(f64, model.mjswgs);
    const pbswgs_p: f64 = @as(f64, model.pbswgs);
    const fc_p: f64 = @as(f64, model.fc);

    const tcj: f64 = @as(f64, model.tcj);
    const tpb: f64 = @as(f64, model.tpb);
    const tcjsw: f64 = @as(f64, model.tcjsw);
    const tpbsw: f64 = @as(f64, model.tpbsw);
    const tcjswg: f64 = @as(f64, model.tcjswg);
    const tpbswg: f64 = @as(f64, model.tpbswg);
    const dt: f64 = temp_k - tnom_k;

    const cjs_t: f64 = cjs_p + tcj * dt;
    const pbs_t: f64 = @max(pbs_p - tpb * dt, 0.01);
    const cjsws_t: f64 = cjsws_p + tcjsw * dt;
    const pbsws_t: f64 = @max(pbsws_p - tpbsw * dt, 0.01);
    const cjswgs_t: f64 = cjswgs_p + tcjswg * dt;
    const pbswgs_t: f64 = @max(pbswgs_p - tpbswg * dt, 0.01);

    const vbs_junc = vbp.sub(vsp);
    const vbd_junc = vbp.sub(vdp);

    // Depletion charge helper: region branch on vratio<=fc (voltage-dependent),
    // each branch in S ops (reproduces original piecewise physics).
    const jcap = struct {
        fn f(comptime T: type, vj: T, cj: f64, mj: f64, pb: f64, fc: f64) T {
            const vratio = vj.scale(1.0 / pb);
            if (vratio.val() <= fc) {
                // pb*cj/(1-mj)*(1 - (1 - vj/pb)^(1-mj))
                return vratio.neg().addC(1.0).maxC(1.0e-30).pow(1.0 - mj).neg().addC(1.0).scale(pb * cj / (1.0 - mj));
            } else {
                const base = pb * cj / (1.0 - mj) * (1.0 - contract.fmath.pow(@max(1.0 - fc, 1.0e-30), 1.0 - mj));
                const slope = cj / contract.fmath.pow(@max(1.0 - fc, 1.0e-30), mj);
                return vj.addC(-fc * pb).scale(slope).addC(base);
            }
        }
    }.f;

    const q_jbs_bot = jcap(S, vbs_junc, cjs_t, mjs_p, pbs_t, fc_p);
    const q_jbs_sw = jcap(S, vbs_junc, cjsws_t, mjsws_p, pbsws_t, fc_p);
    const q_jbs_swg = jcap(S, vbs_junc, cjswgs_t, mjswgs_p, pbswgs_t, fc_p);

    const as_eff: f64 = @as(f64, instance.as_);
    const ps_eff: f64 = @as(f64, instance.ps);
    const ad_eff: f64 = @as(f64, instance.ad);
    const pd_eff: f64 = @as(f64, instance.pd);
    const weff_cj: f64 = weff_cv;

    const q_bs_junc = q_jbs_bot.scale(as_eff).add(q_jbs_sw.scale(ps_eff)).add(q_jbs_swg.scale(weff_cj * nf_f));

    // Drain junction charge
    const cjd_p: f64 = @as(f64, model.cjd);
    const mjd_p: f64 = @as(f64, model.mjd);
    const pbd_p: f64 = @as(f64, model.pbd);
    const cjswd_p: f64 = @as(f64, model.cjswd);
    const mjswd_p: f64 = @as(f64, model.mjswd);
    const pbswd_p: f64 = @as(f64, model.pbswd);
    const cjswgd_p: f64 = @as(f64, model.cjswgd);
    const mjswgd_p: f64 = @as(f64, model.mjswgd);
    const pbswgd_p: f64 = @as(f64, model.pbswgd);

    const cjd_t: f64 = cjd_p + tcj * dt;
    const pbd_t: f64 = @max(pbd_p - tpb * dt, 0.01);
    const cjswd_t: f64 = cjswd_p + tcjsw * dt;
    const pbswd_t: f64 = @max(pbswd_p - tpbsw * dt, 0.01);
    const cjswgd_t: f64 = cjswgd_p + tcjswg * dt;
    const pbswgd_t: f64 = @max(pbswgd_p - tpbswg * dt, 0.01);

    const q_jbd_bot = jcap(S, vbd_junc, cjd_t, mjd_p, pbd_t, fc_p);
    const q_jbd_sw = jcap(S, vbd_junc, cjswd_t, mjswd_p, pbswd_t, fc_p);
    const q_jbd_swg = jcap(S, vbd_junc, cjswgd_t, mjswgd_p, pbswgd_t, fc_p);

    const q_bd_junc = q_jbd_bot.scale(ad_eff).add(q_jbd_sw.scale(pd_eff)).add(q_jbd_swg.scale(weff_cj * nf_f));

    // --- Write charge outputs ---
    const mf: f64 = p.m_mult;

    var out: [n_u]S = undefined;
    // Gate charge = intrinsic gate charge + overlap charges
    out[GP] = q_g_phys.add(q_gs_ov).add(q_gd_ov).add(q_gb_ov).add(q_gs_ov_dep).add(q_gd_ov_dep).add(q_cf_s).add(q_cf_d).scale(mf * type_f);
    // Drain charge
    out[DP] = q_d_phys.sub(q_gd_ov).sub(q_gd_ov_dep).sub(q_cf_d).add(q_bd_junc).scale(mf * type_f);
    // Source charge
    out[SP] = q_s_phys.sub(q_gs_ov).sub(q_gs_ov_dep).sub(q_cf_s).add(q_bs_junc).scale(mf * type_f);
    // Bulk charge (body-prime).
    // q_b_phys = -(q_g_phys + q_s_phys + q_d_phys) is a charge-conservation
    // cancellation residual (physically ~0: q_g_phys == -(q_s_phys+q_d_phys)).
    // Under @setFloatMode(.optimized) the compiler is free to reassociate this
    // three-term add, which makes the sub-epsilon residual sign/magnitude
    // depend on association order and diverge from the old flat f64 expression
    // `-(q_g_phys + q_s_phys + q_d_phys)`. Force strict left-to-right
    // association (matching the old parenthesization exactly) so the residual
    // is deterministic and bit-for-bit with the reference. S ops are still
    // used, so the Jacobian entry is preserved.
    const q_b_phys = qbPhys(S, q_g_phys, q_s_phys, q_d_phys);
    out[BP] = q_b_phys.sub(q_gb_ov).sub(q_bs_junc).sub(q_bd_junc).scale(mf * type_f);

    // External nodes — no charge
    out[G] = con(S, 0.0);
    out[D] = con(S, 0.0);
    out[Ssrc] = con(S, 0.0);
    out[B] = con(S, 0.0);
    out[DBN] = con(S, 0.0);
    out[SBN] = con(S, 0.0);

    return out;
}


// ============================================================================
// Voltage Limiting (DEVfetlim + DEVpnjlim)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;

    const type_f: f64 = @floatFromInt(model.type_);
    _ = instance;

    // PN junction limiting (DEVpnjlim) for source and drain junctions
    const k_b: f64 = 1.380649e-23;
    const q_e: f64 = 1.6e-19;
    const tnom_k: f64 = @as(f64, model.tnom) + 273.15;
    const vt: f64 = k_b * tnom_k / q_e;

    const BP = @intFromEnum(U.body_prime);
    const DP = @intFromEnum(U.drain_prime);
    const SP = @intFromEnum(U.source_prime);
    const GP = @intFromEnum(U.gate_prime);

    // V_critical for PN junction
    const jss: f64 = @as(f64, model.jss);
    const is_val: f64 = @max(jss * 1.0e-12, 1.0e-30); // approximate Is
    const njs: f64 = @as(f64, model.njs);
    const nvt: f64 = njs * vt;
    const v_crit: f64 = nvt * contract.fmath.log(nvt / (1.4142135 * is_val));

    // Source junction: V(bp) - V(sp)
    const vbs_new: f64 = (x_new[BP] - x_new[SP]) * type_f;
    const vbs_old: f64 = (x_old[BP] - x_old[SP]) * type_f;
    const vbs_lim: f64 = pnjlim(vbs_new, vbs_old, vt, v_crit);
    const vbs_delta: f64 = (vbs_lim - vbs_new) * type_f;
    result[BP] = result[BP] + vbs_delta * 0.5;
    result[SP] = result[SP] - vbs_delta * 0.5;

    // Drain junction: V(bp) - V(dp)
    const vbd_new: f64 = (x_new[BP] - x_new[DP]) * type_f;
    const vbd_old: f64 = (x_old[BP] - x_old[DP]) * type_f;
    const vbd_lim: f64 = pnjlim(vbd_new, vbd_old, vt, v_crit);
    const vbd_delta: f64 = (vbd_lim - vbd_new) * type_f;
    result[BP] = result[BP] + vbd_delta * 0.5;
    result[DP] = result[DP] - vbd_delta * 0.5;

    // FET gate voltage limiting (DEVfetlim)
    const vgs_new: f64 = (x_new[GP] - x_new[SP]) * type_f;
    const vgs_old: f64 = (x_old[GP] - x_old[SP]) * type_f;
    const vto: f64 = @as(f64, model.vfb) + 0.6; // approximate Vth
    const vgs_lim: f64 = fetlim(vgs_new, vgs_old, vto);
    const vgs_delta: f64 = (vgs_lim - vgs_new) * type_f;
    result[GP] = result[GP] + vgs_delta * 0.5;
    result[SP] = result[SP] - vgs_delta * 0.5;

    // VDS limiting
    const vds_new: f64 = (x_new[DP] - x_new[SP]) * type_f;
    const vds_old: f64 = (x_old[DP] - x_old[SP]) * type_f;
    const vds_lim: f64 = limvds(vds_new, vds_old);
    const vds_delta: f64 = (vds_lim - vds_new) * type_f;
    result[DP] = result[DP] + vds_delta * 0.5;
    result[SP] = result[SP] - vds_delta * 0.5;

    return result;
}

// DEVpnjlim: PN junction voltage limiting
fn pnjlim(vnew: f64, vold: f64, vt_val: f64, vcrit: f64) f64 {
    const dv: f64 = vnew - vold;
    const abs_dv: f64 = @abs(dv);
    // If voltage is above critical and step is large, apply logarithmic damping
    const result: f64 = if (vnew > vcrit and abs_dv > 2.0 * vt_val)
        (if (vold > 0.0)
            vold + vt_val * contract.fmath.log(@max(1.0 + dv / vt_val, 1.0e-30))
        else
            vt_val * contract.fmath.log(@max(vnew / vt_val, 1.0e-30)))
    else
        vnew;
    return result;
}

// DEVfetlim: FET gate voltage limiting
fn fetlim(vnew: f64, vold: f64, vto: f64) f64 {
    const vtsthi: f64 = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo: f64 = @max(vtsthi / 2.0 + 2.0, 4.0);
    const vtox: f64 = vto + 3.5;
    const dv: f64 = vnew - vold;

    const result: f64 = if (vnew > vold) blk: {
        break :blk if (vold >= vto)
            (if (dv >= vtsthi) vold + vtsthi * (1.0 + (dv - vtsthi) / (dv - vtsthi + vtsthi)) else vnew)
        else if (vnew >= vtox)
            vto + vtstlo
        else
            vnew;
    } else blk: {
        break :blk if (vold >= vto)
            (if (-dv >= vtsthi) vold - vtsthi * (1.0 + (-dv - vtsthi) / (-dv - vtsthi + vtsthi)) else vnew)
        else
            vnew;
    };
    return result;
}

// DEVlimvds: Drain-source voltage limiting
fn limvds(vnew: f64, vold: f64) f64 {
    const dv: f64 = vnew - vold;
    const abs_dv: f64 = @abs(dv);
    const result: f64 = if (abs_dv > 3.5) vold + 3.5 * dv / abs_dv else vnew;
    return result;
}

// ============================================================================
// Parameter stepping for convergence aid
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale junction saturation currents by adding gmin*(1-lambda)
    const gmin_scale: f32 = @floatCast(1.0e-12 * (1.0 - lambda));
    m.jss = model.jss + gmin_scale;
    m.jsd = model.jsd + gmin_scale;
    m.jsws = model.jsws + gmin_scale;
    m.jswd = model.jswd + gmin_scale;
    m.jswgs = model.jswgs + gmin_scale;
    m.jswgd = model.jswgd + gmin_scale;
    return m;
}

// ============================================================================
// Sparse conductance stamp pattern
// ============================================================================
// The BSIM-BULK touches:
// - Channel: DP <-> SP (depends on GP, BP)
// - S/D resistance: D <-> DP, S <-> SP
// - Gate resistance: G <-> GP
// - Body network: B <-> BP, BP <-> DBN, BP <-> SBN, DBN <-> B, SBN <-> B
// - Junction: BP <-> DP, BP <-> SP
// - Gate tunneling: GP <-> DP, GP <-> SP, GP <-> BP
// - GIDL/GISL: DP <-> BP, SP <-> BP
// - Impact ionization: DP <-> BP

// ============================================================================
// Comptime validation
// ============================================================================

comptime {
    contract.validate(Self);
}

const testing = std.testing;

// Enum index shortcuts for tests
const T_DP = @intFromEnum(U.drain_prime);
const T_SP = @intFromEnum(U.source_prime);
const T_GP = @intFromEnum(U.gate_prime);
const T_BP = @intFromEnum(U.body_prime);

// Expected values below were produced by running the ORIGINAL pointer-form
// i()/q() (git HEAD) at the same bias and captured verbatim — they are the
// physics regression. The value-form port reproduces them bit-for-bit.

test "bsim_bulk: on-state channel residual (Vgs=Vds=1V, default NMOS)" {
    const model: Model = .{};
    const inst: Instance = .{};
    // node order: G, D, S, B, DP, SP, GP, BP, DBN, SBN
    const x = [_]f64{ 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // Channel current flows SP -> DP; old i(): DP=-2.157502e-6, SP=+2.157501e-6
    try testing.expectApproxEqAbs(@as(f64, -2.157502e-6), out[T_DP], 1e-11);
    try testing.expectApproxEqAbs(@as(f64, 2.157501e-6), out[T_SP], 1e-11);
    // KCL: total current out of the device sums to zero (stamp conservation)
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "bsim_bulk: second bias residual (Vg=1.5,Vd=0.5,Vb=-0.2)" {
    const model: Model = .{};
    const inst: Instance = .{};
    const x = [_]f64{ 1.5, 0.5, 0.0, -0.2, 0.5, 0.0, 1.5, -0.2, -0.2, -0.2 };
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // old i(): SP=-5.19283947e-5, DP=5.19283938e-5, BP=9e-13
    try testing.expectApproxEqAbs(@as(f64, 5.19283938e-5), out[T_DP], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -5.19283947e-5), out[T_SP], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 9.0e-13), out[T_BP], 1e-16);
    var sum: f64 = 0;
    for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "bsim_bulk: charge partition (Vgs=Vds=1V)" {
    const model: Model = .{};
    const inst: Instance = .{};
    const x = [_]f64{ 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0 };
    const qo = contract.qValues(Self, x, &model, &inst, 0);
    // old q(): DP=-8.462628e6, SP=-1.269394e7, GP=2.115657e7
    try testing.expectApproxEqAbs(@as(f64, -8.462628e6), qo[T_DP], 5.0);
    try testing.expectApproxEqAbs(@as(f64, -1.269394e7), qo[T_SP], 5.0);
    try testing.expectApproxEqAbs(@as(f64, 2.115657e7), qo[T_GP], 5.0);
    // Intrinsic gate/drain/source/bulk-prime charge conserves to ~0
    var sum: f64 = 0;
    for (qo) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-6);
    // Body-prime intrinsic charge is a charge-conservation cancellation
    // residual: q_b_phys = -(q_g+q_s+q_d) with q_g == -(q_s+q_d), so the
    // physical value is ~0. With strict-mode association (qbPhys) it is
    // deterministic and sub-epsilon relative to the ~1e7 intrinsic charges.
    try testing.expect(@abs(qo[T_BP]) < 1e-9);
}
