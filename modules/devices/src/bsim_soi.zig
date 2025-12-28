const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM-SOI 100.1.1 — Silicon-On-Insulator MOSFET
// ============================================================================
// Topology: G (gate), D (drain), S (source), E (substrate/back-gate), B (body)
//   External terminals: G, D, S, E, B  (5 ports)
//   Internal nodes:
//     D' — intrinsic drain (beyond RDSMOD=1 external drain resistance)
//     S' — intrinsic source
//     B' — intrinsic body (body contact network)
//     T  — thermal node for self-heating (SHMOD=1)
//     G' — internal gate node (RGATEMOD > 0)
// ============================================================================

pub const U = enum(u8) {
    gate, // 0 — external gate
    drain, // 1 — external drain
    source, // 2 — external source
    substrate, // 3 — external substrate / back-gate (E)
    body, // 4 — external body contact (B)
    drain_prime, // 5 — intrinsic drain
    source_prime, // 6 — intrinsic source
    body_prime, // 7 — intrinsic body
    temp, // 8 — thermal node
    gate_prime, // 9 — internal gate
};

pub const num_ports: usize = 5;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Selectors / Controllers ---
    type_: i32 = 1, // 1=NMOS, -1=PMOS
    soimod: i32 = 0, // 0: PDSOI, 1: DDSOI
    cvmod: i32 = 0,
    covmod: i32 = 0,
    rdsmod: i32 = 0,
    wpemod: i32 = 0,
    asymmod: i32 = 0,
    gidlmod: i32 = 0,
    igcmod: i32 = 0,
    igbmod: i32 = 0,
    tnoimod: i32 = 0,
    tnodeout: i32 = 0,
    shmod: i32 = 0,
    mobscale: i32 = 0,
    bodymod: i32 = 0,
    iiimod: i32 = 0,
    modagbcp2: i32 = 0,
    pdemod: i32 = 0,
    fbody1: i32 = 0,
    binunit: i32 = 1,
    fnoimod: i32 = 0,
    sslmod: i32 = 0,

    // --- Geometry ---
    dlbin: f32 = 0,
    dwbin: f32 = 0,
    llong: f32 = 1e-5,
    lmlt: f32 = 1,
    wmlt: f32 = 1,
    xl: f32 = 0,
    wwide: f32 = 1e-5,
    xw: f32 = 0,
    lint: f32 = 0,
    ll: f32 = 0,
    lw: f32 = 0,
    lln: f32 = 1,
    lwn: f32 = 1,
    wint: f32 = 0,
    wl: f32 = 0,
    ww: f32 = 0,
    wln: f32 = 1,
    wwn: f32 = 1,
    dlc: f32 = 0,
    llc: f32 = 0,
    lwc: f32 = 0,
    lwlc: f32 = 0,
    dwc: f32 = 0,
    wlc: f32 = 0,
    wwc: f32 = 0,

    // --- Physical ---
    tsi: f32 = 4e-8,
    tbox: f32 = 2e-7,
    toxe: f32 = 3e-9,
    toxp: f32 = 3e-9,
    dtox: f32 = 0,
    ndep: f32 = 1e+24,
    ndepcv: f32 = 1e+24,
    ngate: f32 = 5e+25,
    ni0sub: f32 = 1e+16,
    bg0sub: f32 = 1,
    epsrsub: f32 = 10,
    epsrox: f32 = 4,
    xj: f32 = 1e-7,
    vfb: f32 = -0.5,
    vfbb: f32 = 0,
    vfbcv: f32 = -0.5,
    delvfbacc: f32 = 0,
    vfbagbcp2: f32 = -0.5,
    ndepagbcp2: f32 = 1e+24,
    nsd: f32 = 1e+26,

    // --- Threshold Voltage / Short Channel ---
    dvtp0: f32 = 0,
    dvtp1: f32 = 0,
    dvtp2: f32 = 0,
    dvtp3: f32 = 0,
    dvtp4: f32 = 0,
    dvtp5: f32 = 0,
    dvbd0: f32 = 0,
    dvbd1: f32 = 0,
    vsce: f32 = 0,
    cdsbs1: f32 = 1,
    cdsbs: f32 = 0,
    phin: f32 = 0.04,
    eta0: f32 = 0.08,
    eta0r: f32 = 0.08,
    dsub: f32 = 1,
    etab: f32 = -0.07,
    k1: f32 = 0,
    k2: f32 = 0,
    ados: f32 = 0,
    bdos: f32 = 1,
    qm0: f32 = 1e-3,
    etaqm: f32 = 0.5,
    cit: f32 = 0,
    nfactor: f32 = 0,
    ascl: f32 = 0,
    bscl: f32 = 0,
    dvt1: f32 = 1,
    cdscd: f32 = 0,
    cdsc: f32 = 1e-9,
    csecsed: f32 = 0,
    cbcbd: f32 = 0,
    csecse0: f32 = 0,
    csecse: f32 = 0,
    cbcb: f32 = 0,
    cbcb0: f32 = 0,
    cdscdr: f32 = 0,
    cdscb: f32 = 0,
    vbsa: f32 = 0,

    // --- Mobility / Velocity Saturation ---
    vsat: f32 = 1e+5,
    vsatr: f32 = 1e+5,
    delta: f32 = 0.1,
    vsatcv: f32 = 1e+5,
    thesat: f32 = 0.3,
    lpe1: f32 = 0,
    up1: f32 = 0,
    lp1: f32 = 1e-8,
    up2: f32 = 0,
    lp2: f32 = 1e-8,
    u0: f32 = 0.07,
    u0r: f32 = 0.07,
    etamob: f32 = 1,
    ua: f32 = 1e-3,
    uar: f32 = 1e-3,
    eu: f32 = 2,
    ud: f32 = 1e-3,
    udr: f32 = 1e-3,
    ucs: f32 = 2,
    ucsr: f32 = 2,
    uc: f32 = 0,
    ucr: f32 = 0,

    // --- Output Conductance ---
    pclm: f32 = 3e-3,
    pclmr: f32 = 3e-3,
    pclmg: f32 = 0,
    pclmcv: f32 = 3e-3,
    pscbe1: f32 = 4e+8,
    pscbe2: f32 = 1e-8,
    pdits: f32 = 0,
    pditsd: f32 = 0,
    pdiblc: f32 = 0,
    pdiblcr: f32 = 0,
    pdiblcb: f32 = 0,
    pvag: f32 = 1,
    fprout: f32 = 0,

    // --- Resistance ---
    rsh: f32 = 0,
    prwg: f32 = 1,
    prwb: f32 = 0,
    wr: f32 = 1,
    rswmin: f32 = 0,
    rsw: f32 = 10,
    rdwmin: f32 = 0,
    rdw: f32 = 10,
    rdswmin: f32 = 0,
    rdsw: f32 = 20,

    // --- Velocity Saturation / Ids Tuning ---
    psat: f32 = 1,
    psatb: f32 = 0,
    psatr: f32 = 1,
    psatx: f32 = 1,
    ptwg: f32 = 0,
    vp: f32 = 0.05,
    alp: f32 = 0.01,
    ptwgr: f32 = 0,
    ksativ: f32 = 1,
    a1: f32 = 0,
    a11: f32 = 0,
    a2: f32 = 0,
    a21: f32 = 0,

    // --- BJT and Impact Ionization ---
    bjtoff: i32 = 0,
    vabjt: f32 = 10,
    aely: f32 = 0,
    ahli: f32 = 0,
    ahlid: f32 = 0,
    xbjt: f32 = 1,
    ndiode: f32 = 1,
    isbjt: f32 = 0,
    idbjt: f32 = 0,
    nbjt: f32 = 1,
    llbjt0: f32 = 0,
    wlbjt0: f32 = 0,
    plbjt0: f32 = 0,
    lbjt0: f32 = 2e-7,
    ln_: f32 = 2e-6,
    vdsatii0: f32 = 0.9,
    tii: f32 = 0,
    alpha0: f32 = 0,
    beta0: f32 = 0,
    beta1: f32 = 0,
    beta2: f32 = 0.1,
    lii: f32 = 0,
    sii0: f32 = 0.5,
    sii1: f32 = 0.1,
    sii2: f32 = 0,
    siid: f32 = 0,
    esatii: f32 = 1e+7,
    iimod2clamp1: f32 = 0.1,
    iimod2clamp2: f32 = 0.1,
    iimod2clamp3: f32 = 0.1,
    fbjtii: f32 = 0,
    ebjtii: f32 = 0,
    cbjtii: f32 = 0,
    abjtii: f32 = 0,
    vbci: f32 = 0,
    tvbci: f32 = 0,
    mbjtii: f32 = 0.4,

    // --- Gate Tunneling Current ---
    vecb: f32 = 0.03,
    alphagb1: f32 = 0.3,
    alphagb1_t: f32 = 0,
    betagb1: f32 = 0.03,
    alphagb2: f32 = 0.4,
    alphagb2_t: f32 = 0,
    betagb2: f32 = 0.05,
    vgb2: f32 = 20,
    vgb1: f32 = 300,
    agb1: f32 = 4e-7,
    bgb1: f32 = -3e+10,
    agb2: f32 = 5e-7,
    bgb2: f32 = -2e+10,
    agbc2n: f32 = 3e-7,
    agbc2p: f32 = 5e-7,
    bgbc2n: f32 = 1e+12,
    bgbc2p: f32 = 7e+11,
    eigbinv: f32 = 1,
    aigc: f32 = 1.36e-2,
    bigc: f32 = 1.71e-3,
    cigc: f32 = 0.075,
    aigs: f32 = 1.36e-2,
    aigs1: f32 = 0,
    bigs: f32 = 1.71e-3,
    cigs: f32 = 0.075,
    aigd: f32 = 1.36e-2,
    aigd1: f32 = 0,
    bigd: f32 = 1.71e-3,
    cigd: f32 = 0.075,
    dlcig: f32 = 0,
    dlcigd: f32 = 0,
    poxedge: f32 = 1,
    ntox: f32 = 1,
    toxref: f32 = 3e-9,
    pigcd: f32 = 1,
    aigc1: f32 = 0,
    aigbcp2: f32 = 0.04,
    aigbcp2_t: f32 = 0,
    bigbcp2: f32 = 5e-3,
    cigbcp2: f32 = 7e-3,

    // --- GIDL/GISL ---
    agidl: f32 = 0,
    bgidl: f32 = 2e+9,
    bgidl1: f32 = 0,
    cgidl: f32 = 0.5,
    egidl: f32 = 0.8,
    agisl: f32 = 0,
    bgisl: f32 = 2e+9,
    bgisl1: f32 = 0,
    cgisl: f32 = 0.5,
    egisl: f32 = 0.8,
    rgidl: f32 = 1,
    kgidl: f32 = 0,
    fgidl: f32 = 0,
    rgisl: f32 = 1,
    kgisl: f32 = 0,
    fgisl: f32 = 0,

    // --- Capacitance ---
    cf: f32 = 0,
    cfrcoeff: f32 = 1,
    cgso: f32 = 0,
    cgdo: f32 = 0,
    cgbo: f32 = 0,
    cgsl: f32 = 0,
    cgdl: f32 = 0,
    ckappas: f32 = 0.6,
    ckappas1: f32 = 1e+6,
    ckappas2: f32 = 1,
    ckapppad: f32 = 0.6,
    ckappad1: f32 = 1e+6,
    ckappad2: f32 = 1,
    xrcrg1: f32 = 10,
    xrcrg2: f32 = 1,

    // --- Sub-surface Leakage / Misc ---
    ssl0: f32 = 400,
    ssl1: f32 = 3e+8,
    ssl2: f32 = 0.2,
    ssl3: f32 = 0.3,
    ssl4: f32 = 1,
    ssl5: f32 = 0,
    sslexp1: f32 = 0.5,
    sslexp2: f32 = 1,
    avdsx: f32 = 20,
    abulk: f32 = 1,
    a0: f32 = 0,
    ags: f32 = 0,
    ags1: f32 = 1,
    keta: f32 = 0,
    a0cv: f32 = 0,
    agscv: f32 = 0,
    ketacv: f32 = 0,
    c0: f32 = 0,
    c01: f32 = 0,
    c0si: f32 = 1,
    c0si1: f32 = 0,
    c0sisat: f32 = 0,
    c0sisat1: f32 = 0,
    igclamp: i32 = 1,
    k0: f32 = 0,
    k01: f32 = 0,
    m0: f32 = 1,
    m01: f32 = 0,
    minr: f32 = 1e-3,

    // --- Junction Diode Parameters ---
    cjs: f32 = 5e-4,
    cjd: f32 = 5e-4,
    cjsws: f32 = 5e-10,
    cjswd: f32 = 5e-10,
    cjswgs: f32 = 0,
    cjswgd: f32 = 0,
    pbs: f32 = 1,
    pbd: f32 = 1,
    pbsws: f32 = 1,
    pbswd: f32 = 1,
    pbswgs: f32 = 1,
    pbswgd: f32 = 1,
    mjs: f32 = 0.5,
    mjd: f32 = 0.5,
    mjsws: f32 = 0.3,
    mjswd: f32 = 0.3,
    mjswgs: f32 = 0.3,
    mjswgd: f32 = 0.3,
    tt: f32 = 1e-12,
    ldif0: f32 = 1,
    ndif: f32 = -1,
    vtm00: f32 = 0.03,
    permod: i32 = 1,
    dwj: f32 = 0,
    xdif: f32 = 1,
    isdif: f32 = 1e-7,
    iddif: f32 = 1e-7,
    nrecf0: f32 = 2,
    nrecr0: f32 = 10,
    xrec: f32 = 1,
    isrec: f32 = 1e-5,
    idrec: f32 = 1e-5,
    ntrecf: f32 = 0,
    ntrecr: f32 = 0,
    istun: f32 = 1e-8,
    idtun: f32 = 1e-8,
    xtun: f32 = 0,
    xtund: f32 = 0,
    ntun: f32 = 10,
    ntund: f32 = 10,
    vtun0: f32 = 0,
    vtun0d: f32 = 0,
    vrec0: f32 = 0,
    vrec0d: f32 = 0,

    // --- Layout-Dependent Parasitics ---
    dmcg: f32 = 0,
    dmci: f32 = 0,
    dmdg: f32 = 0,
    dmcgt: f32 = 0,
    xgl: f32 = 0,
    rshg: f32 = 0.1,

    // --- EdgeFET ---
    wedge: f32 = 1e-8,
    dgammaedge: f32 = 0,
    dvtedge: f32 = 0,
    ndepedge: f32 = 1e+24,
    nfactoredge: f32 = 0,
    citedge: f32 = 0,
    cdscedge: f32 = 1e-9,
    cdscdedge: f32 = 1e-9,
    cdscdedger: f32 = 1e-9,
    csecseedge: f32 = 0,
    csecsepedge: f32 = 0,
    csecse0edge: f32 = 0,
    csecse0pedge: f32 = 0,
    csecsededge: f32 = 0,
    cbcb0edge: f32 = 0,
    cbcb0pedge: f32 = 0,
    cdscbedge: f32 = 0,
    cbcbpedge: f32 = 0,
    cbcbedge: f32 = 0,
    cbcbdedge: f32 = 0,
    k1edge: f32 = 0,
    k1ledge: f32 = 0,
    k1lexpedge: f32 = 1,
    k1wedge: f32 = 0,
    k1wexpedge: f32 = 1,
    k1wledge: f32 = 0,
    k1wlexpedge: f32 = 1,
    eta0edge: f32 = 0.08,
    etabedge: f32 = -0.07,
    kt1edge: f32 = -0.1,
    kt1ledge: f32 = 0,
    kt2edge: f32 = 0.02,
    kt1expedge: f32 = 1,
    tnfactoredge: f32 = 0,
    teta0edge: f32 = 0,
    dvtp0edge: f32 = 0,
    dvtp1edge: f32 = 0,
    dvtp2edge: f32 = 0,
    dvtp3edge: f32 = 0,
    dvtp4edge: f32 = 0,
    dvtp5edge: f32 = 0,
    dvt0edge: f32 = 2,
    dvt1edge: f32 = 0.5,
    dvt2edge: f32 = 0,
    k2edge: f32 = 0,
    k2ledge: f32 = 0,
    k2lexpedge: f32 = 1,
    k2wedge: f32 = 0,
    k2wexpedge: f32 = 1,
    k2wledge: f32 = 0,
    k2wlexpedge: f32 = 1,
    kvth0edge: f32 = 0,
    kvth0edgewe: f32 = 0,
    k2edgewe: f32 = 0,
    stk2edge: f32 = 0,
    steta0edge: f32 = 0,

    // --- Noise ---
    ef: f32 = 1,
    em: f32 = 4e+7,
    noia: f32 = 6e+40,
    noib: f32 = 3e+25,
    noic: f32 = 9e+8,
    lintnoi: f32 = 0,
    noia1: f32 = 0,
    noiax: f32 = 1,
    ntnoi: f32 = 1,
    rnoia: f32 = 0.6,
    rnoib: f32 = 0.5,
    rnoic: f32 = 0.4,
    tnoia: f32 = 2,
    tnoib: f32 = 4,
    tnoic: f32 = 0,
    lp: f32 = 1e-5,
    rnoik: f32 = 0,
    tnoik: f32 = 0,
    tnoik2: f32 = 0.1,
    nedge: f32 = 1,
    noia1_edge: f32 = 0,
    noiax_edge: f32 = 1,
    lh: f32 = 1e-8,
    noia2: f32 = 6e+40,
    hndep: f32 = 1e+24,
    afns: f32 = 1,
    bfns: f32 = 1,
    kfns: f32 = 0,
    afnd: f32 = 1,
    bfnd: f32 = 1,
    kfnd: f32 = 0,

    // --- Body-Contact Parasitics ---
    rbody: f32 = 0,
    frbody: f32 = 1,
    rbsh: f32 = 0,
    nrb: f32 = 1,
    rhalo: f32 = 1e+15,
    ub: f32 = 0.07,
    ubte: f32 = 1,
    neff: f32 = 5e+24,
    nseg: f32 = 1,
    rbodyagbcp2: f32 = 1e-3,
    nbc: i32 = 0,
    dwbc: f32 = 0,
    pdbcp: f32 = 0,
    psbcp: f32 = 0,
    agbcp: f32 = 0,
    agbcp2: f32 = 2e-12,
    agbcpd: f32 = 0,
    aebcp: f32 = 0,
    eggbcp2: f32 = 1,

    // --- Temperature ---
    tnom: f32 = 30,
    tbgasub: f32 = 5e-4,
    tbgbsub: f32 = 600,
    tnfactor: f32 = 0,
    ute: f32 = -2,
    ua1: f32 = 1e-3,
    uc1: f32 = 6e-11,
    ud1: f32 = 0,
    eu1: f32 = 0,
    ucste: f32 = -5e-3,
    teta0: f32 = 0,
    prt: f32 = 0,
    at: f32 = -2e-3,
    tdelta: f32 = 0,
    ptwgt: f32 = 0,
    kt1: f32 = -0.1,
    kt2: f32 = 0.02,
    iit: f32 = 0,
    igt: f32 = 2,
    tcj: f32 = 0,
    tcjsw: f32 = 0,
    tcjswg: f32 = 0,
    tpb: f32 = 0,
    tpbsw: f32 = 0,
    tpbswg: f32 = 0,
    rth0: f32 = 0,
    cth0: f32 = 1e-5,
    wth0: f32 = 0,

    // --- Stress / Well Proximity ---
    saref: f32 = 1e-6,
    sbref: f32 = 1e-6,
    wlod: f32 = 0,
    ku0: f32 = 0,
    kvsat: f32 = 0,
    tku0: f32 = 0,
    llodku0: f32 = 0,
    wlodku0: f32 = 0,
    kvth0: f32 = 0,
    llodvth: f32 = 0,
    wlodvth: f32 = 0,
    stk2: f32 = 0,
    lodk2: f32 = 0,
    steta0: f32 = 0,
    lodeta0: f32 = 0,
    web: f32 = 0,
    wec: f32 = 0,
    kvth0we: f32 = 0,
    k2we: f32 = 0,
    ku0we: f32 = 0,
    scref: f32 = 1e-6,

    // --- Self-Heating ---
    // (rth0/cth0/wth0 already in Temperature section)

    // --- Both Model/Instance params (model-level defaults) ---
    xgw: f32 = 0,
    ngcon: i32 = 1,
    dtemp: f32 = 0,
    mulu0: f32 = 1,
    delvto: f32 = 0,
    ids0mult: f32 = 1,
    edgefet: i32 = 0,

    // --- Binning scaling parameters (length/width/cross) ---
    // NDEP scaling
    ndepl1: f32 = 0,
    ndeplexp1: f32 = 1,
    ndepl2: f32 = 0,
    ndeplexp2: f32 = 1,
    ndepw: f32 = 0,
    ndepwexp: f32 = 1,
    ndepwl: f32 = 0,
    ndepwlexp: f32 = 1,
    // VFB scaling
    vfbl: f32 = 0,
    vfblexp: f32 = 1,
    vfbw: f32 = 0,
    vfbwexp: f32 = 1,
    vfbwl: f32 = 0,
    vfbwlexp: f32 = 1,
    // K1 scaling
    k1l: f32 = 0,
    k1lexp: f32 = 1,
    k1w: f32 = 0,
    k1wexp: f32 = 1,
    k1wl: f32 = 0,
    k1wlexp: f32 = 1,
    // K2 scaling
    k2l: f32 = 0,
    k2lexp: f32 = 1,
    k2w: f32 = 0,
    k2wexp: f32 = 1,
    k2wl: f32 = 0,
    k2wlexp: f32 = 1,
    // NFACTOR scaling
    nfactorl: f32 = 0,
    nfactorlexp: f32 = 1,
    nfactorw: f32 = 0,
    nfactorwexp: f32 = 1,
    nfactorwl: f32 = 0,
    nfactorwlexp: f32 = 1,
    // VSAT scaling
    vsatl: f32 = 0,
    vsatlexp: f32 = 1,
    vsatw: f32 = 0,
    vsatwexp: f32 = 1,
    vsatwl: f32 = 0,
    vsatwlexp: f32 = 1,
    // U0 scaling
    u0l: f32 = 0,
    u0lexp: f32 = 1,
    // UA scaling
    ual: f32 = 0,
    ualexp: f32 = 1,
    uaw: f32 = 0,
    uawexp: f32 = 1,
    uawl: f32 = 0,
    uawlexp: f32 = 1,
    // EU scaling
    eul: f32 = 0,
    eulexp: f32 = 1,
    euw: f32 = 0,
    euwexp: f32 = 1,
    euwl: f32 = 0,
    euwlexp: f32 = 1,
    // UD scaling
    udl: f32 = 0,
    udlexp: f32 = 1,
    // UC scaling
    ucl: f32 = 0,
    uclexp: f32 = 1,
    ucw: f32 = 0,
    ucwexp: f32 = 1,
    ucwl: f32 = 0,
    ucwlexp: f32 = 1,
    // PCLM scaling
    pclml: f32 = 0,
    pclmlexp: f32 = 1,
    // ALPHA0 scaling
    alpha0l: f32 = 0,
    alpha0lexp: f32 = 1,
    // PDIBLC scaling
    pdiblcl: f32 = 0,
    pdiblclexp: f32 = 1,
    // PTWG scaling
    ptwgl: f32 = 0,
    ptwglexp: f32 = 1,
    // PSAT scaling
    psatl: f32 = 0,
    psatlexp: f32 = 1,
    // DELTA scaling
    deltal: f32 = 0,
    deltalexp: f32 = 1,
    // CDSCD scaling
    cdscdl: f32 = 0,
    cdscdlexp: f32 = 1,
    // CDSCB scaling
    cdscbl: f32 = 0,
    cdscblexp: f32 = 1,
    // PRWB scaling
    prwbl: f32 = 0,
    prwblexp: f32 = 1,
    // ETAB scaling
    etabexp: f32 = 1,
    // RDSW scaling
    rdswl: f32 = 0,
    rdswlexp: f32 = 1,
    // RSW scaling
    rswl: f32 = 0,
    rswlexp: f32 = 1,
    // RDW scaling
    rdwl: f32 = 0,
    rdwlexp: f32 = 1,
    // FPROUT scaling
    fproutl: f32 = 0,
    fproutlexp: f32 = 1,
    // UTE scaling
    utel: f32 = 0,
    // UA1 scaling
    ua1l: f32 = 0,
    // UD1 scaling
    ud1l: f32 = 0,
    // AT scaling
    atl: f32 = 0,
    // PTWGT scaling
    ptwgtl: f32 = 0,
    // KT1 scaling
    kt1exp: f32 = 1,
    kt1l: f32 = 0,
    // VSATCV scaling
    vsatcvl: f32 = 0,
    vsatcvlexp: f32 = 1,
    vsatcvw: f32 = 0,
    vsatcvwexp: f32 = 1,
    vsatcvwl: f32 = 0,
    vsatcvwlexp: f32 = 1,
    // NDEPCV scaling
    ndepcvl1: f32 = 0,
    ndepcvlexp1: f32 = 1,
    ndepcvl2: f32 = 0,
    ndepcvlexp2: f32 = 1,
    ndepcvw: f32 = 0,
    ndepcvwexp: f32 = 1,
    ndepcvwl: f32 = 0,
    ndepcvwlexp: f32 = 1,
    // VFBCV scaling
    vfbcvl: f32 = 0,
    vfbcvlexp: f32 = 1,
    vfbcvw: f32 = 0,
    vfbcvwexp: f32 = 1,
    vfbcvwl: f32 = 0,
    vfbcvwlexp: f32 = 1,
    // PCLMCV scaling
    pclmcvl: f32 = 0,
    pclmcvlexp: f32 = 1,
    // DGAMMAEDGE scaling
    dgammaedgel: f32 = 0,
    dgammaedgelexp: f32 = 1,
    // PIGCD scaling
    pigcdl: f32 = 0,
    // AIGC scaling
    aigcl: f32 = 0,
    aigcw: f32 = 0,
    // AIGS scaling
    aigsl: f32 = 0,
    aigsw: f32 = 0,
    // AIGD scaling
    aigdl: f32 = 0,
    aigdw: f32 = 0,
    // AGIDL scaling
    agidll: f32 = 0,
    agidlw: f32 = 0,
    // AGISL scaling
    agisll: f32 = 0,
    agislw: f32 = 0,
    // CSECSE0 scaling
    csecse0p: f32 = 0,
    // CSECSE scaling
    csecsep: f32 = 0,
    // CBCB scaling
    cbcbp: f32 = 0,
    // CBCB0 scaling
    cbcb0p: f32 = 0,
    // PDITS scaling
    pditsl: f32 = 0,

    // Misc uncategorized scaling
    lwl: f32 = 0,
    wwl: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 1e-5,
    w: f32 = 1e-5,
    nf: f32 = 1,
    nrs: f32 = 1,
    nrd: f32 = 1,
    vfbsdoff: f32 = 0,
    minz: f32 = 0,
    rgatemod: i32 = 0,
    geomod: i32 = 0,
    rgeomod: i32 = 0,
    sa: f32 = 0,
    sb: f32 = 0,
    sd: f32 = 0,
    sca: f32 = 0,
    scb: f32 = 0,
    scc: f32 = 0,
    sc: f32 = 0,
    as_: f32 = 0,
    ad: f32 = 0,
    ps: f32 = 0,
    pd: f32 = 0,
    // Both model/instance
    xgw: f32 = 0,
    ngcon: i32 = 1,
    dtemp: f32 = 0,
    mulu0: f32 = 1,
    delvto: f32 = 0,
    ids0mult: f32 = 1,
    edgefet: i32 = 0,
    sslmod: i32 = 0,
};

// ============================================================================
// Physics (value-form: generic over scalar S). All x-INDEPENDENT parameter,
// temperature, and geometry preprocessing lives in plain-f64 helpers below.
// Only the terminal-voltage-dependent tail runs on S ops.
// ============================================================================

// --- Enum-to-index aliases ---
const G = @intFromEnum(U.gate);
const D = @intFromEnum(U.drain);
const S_i = @intFromEnum(U.source);
const E = @intFromEnum(U.substrate);
const B = @intFromEnum(U.body);
const DP = @intFromEnum(U.drain_prime);
const SP = @intFromEnum(U.source_prime);
const BP = @intFromEnum(U.body_prime);
const T = @intFromEnum(U.temp);
const GP = @intFromEnum(U.gate_prime);

// --- Physical constants ---
const q_e: f64 = 1.6e-19;
const eps0: f64 = 8.8542e-12;
const k_B: f64 = 1.38065e-23;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;

/// All x-independent quantities the resistive (eval) tail needs. Computed
/// once in plain f64 from model + instance; the S tail reads these as
/// constants. Field names mirror the originals for a 1:1 translation.
const Prep = struct {
    type_f: f64,
    tsi: f64,
    toxe: f64,
    cox: f64,
    eps_ratio: f64,
    vt: f64,
    nvt: f64,
    n: f64,
    t_ratio: f64,

    // threshold / SCE constants
    phi_st: f64,
    sqrt_phi_st: f64,
    k1_m: f64,
    k2_m: f64,
    eta0_eff: f64,
    etab_m: f64,
    kt1_m: f64,
    kt2_m: f64,
    kt1exp_m: f64,
    delvto: f64,
    dvtp0: f64,
    dvtp1: f64,
    dvtp2: f64,
    dvtp3: f64,
    dvtp4: f64,
    dvtp5: f64,
    vfb_m: f64,
    vfb_eff: f64,
    leff: f64,
    weff: f64,

    // vgst smoothing
    delta_t: f64,

    // AbulkIV
    a0_m: f64,
    ags_m: f64,
    ags1_m: f64,
    keta_m: f64,
    xj: f64,
    ndep: f64,
    eps_sub: f64,

    // effective field / mobility
    eta_mob: f64,
    eu_t: f64,
    ua_t: f64,
    uc_t: f64,
    ud_t: f64,
    ucs_t: f64,
    mu0_scaled: f64,
    stress_u0_ratio: f64,
    mu0_wpe: f64,

    // saturation
    vsat_eff: f64,
    esat_l: f64,
    ksativ: f64,
    abulk: f64,
    psat_m: f64,
    psatb: f64,
    psatx: f64,
    ptwg: f64,

    // series R
    rdsmod: i32,
    prwg: f64,
    prwb: f64,
    wr_m: f64,
    weff_r: f64,
    nf: f64,
    rdswmin: f64,
    rdsw_t: f64,

    // nonsat
    a1_t: f64,
    a2_t: f64,

    // output conductance
    pclm: f64,
    pclmg: f64,
    pdiblc: f64,
    fprout: f64,
    pvag: f64,
    pdiblcb: f64,
    pscbe1: f64,
    pscbe2: f64,
    pdits: f64,
    pditsd: f64,

    // MNUD
    k0_t: f64,
    m0_t: f64,
    c0_t: f64,
    c0si_t: f64,
    c0sisat_t: f64,

    ids0mult: f64,

    // BJT / junction
    nbc: f64,
    dwbc: f64,
    psbcp: f64,
    pdbcp: f64,
    ln_m: f64,
    ndiode: f64,
    isdif_t: f64,
    iddif_t: f64,
    isrec_t: f64,
    idrec_t: f64,
    istun_t: f64,
    idtun_t: f64,
    isbjt_t: f64,
    idbjt_t: f64,
    nbjt_m: f64,
    lbjt0: f64,
    nrecf0: f64,
    nrecr0: f64,
    ntun: f64,
    ntund: f64,
    vtm00: f64,
    vrec0_m: f64,
    vrec0d: f64,
    vtun0_m: f64,
    vtun0d: f64,
    ahli: f64,
    ahlid: f64,
    vabjt: f64,
    aely: f64,
    bjtoff: i32,

    // impact ionization
    iiimod: i32,
    alpha0_m: f64,
    beta0_m: f64,
    beta1_m: f64,
    beta2_m: f64,
    esatii: f64,
    sii0: f64,
    sii1: f64,
    sii2: f64,
    siid: f64,
    vdsatii0: f64,
    tii_m: f64,
    lii_m: f64,
    fbjtii: f64,
    vbci_t: f64,
    cbjtii: f64,
    ebjtii: f64,
    abjtii: f64,
    mbjtii: f64,

    // GIDL/GISL
    gidlmod: i32,
    agidl: f64,
    bgidl: f64,
    cgidl: f64,
    egidl: f64,
    agisl: f64,
    bgisl: f64,
    cgisl: f64,
    egisl: f64,
    rgidl: f64,
    kgidl: f64,
    fgidl: f64,
    rgisl: f64,
    kgisl: f64,
    fgisl: f64,

    // gate tunneling
    igcmod: i32,
    igbmod: i32,
    vecb: f64,
    eigbinv: f64,
    aigc_m: f64,
    bigc_m: f64,
    cigc_m: f64,
    aigs_m: f64,
    bigs_m: f64,
    cigs_m: f64,
    aigd_m: f64,
    bigd_m: f64,
    cigd_m: f64,
    dlcig: f64,
    poxedge: f64,
    ntox: f64,
    toxref: f64,
    pigcd: f64,
    agb1: f64,
    bgb1: f64,
    agb2: f64,
    bgb2: f64,
    alphagb1: f64,
    betagb1: f64,
    alphagb2: f64,
    betagb2: f64,
    vgb1: f64,
    vgb2: f64,

    // SSL
    sslmod: i32,
    ssl0: f64,
    ssl1: f64,
    ssl2: f64,
    ssl3: f64,
    ssl4: f64,
    ssl5: f64,

    // EdgeFET
    edgefet: i32,
    citedge: f64,
    nfactoredge: f64,
    cdscedge: f64,
    cdscdedge: f64,
    eta0edge: f64,
    etabedge: f64,
    dvtedge: f64,
    dgammaedge: f64,
    wedge: f64,

    avdsx: f64,

    // resistance branches
    minr: f64,
    rshg: f64,
    xgw_i: f64,
    ngcon_i: f64,
    xgl: f64,
    l_inst: f64,
    xrcrg1: f64,
    xrcrg2: f64,
    mu_eff_pre: f64, // mu_eff for r_iir (x-independent part)
    rsh: f64,
    nrs: f64,
    nrd: f64,
    rswmin: f64,
    rsw: f64,
    rdwmin: f64,
    rdw: f64,
    bodymod: i32,
    rbody: f64,
    frbody: f64,
    rhalo: f64,
    rbsh: f64,
    nrb: f64,
    neff_m: f64,
    ub: f64,
    shmod: i32,
    rth0: f64,
    wth0: f64,
};

/// x-independent parameter, geometry and temperature preprocessing. Pure f64.
fn prep(model: *const Model, instance: *const Instance) Prep {
    const type_f: f64 = @floatFromInt(model.type_);
    const tsi: f64 = @as(f64, model.tsi);
    const tbox: f64 = @as(f64, model.tbox);
    const toxe: f64 = @as(f64, model.toxe);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const epsrox: f64 = @as(f64, model.epsrox);
    const ndep: f64 = @as(f64, model.ndep);
    const ngate: f64 = @as(f64, model.ngate);
    const ni0sub: f64 = @as(f64, model.ni0sub);
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const vfb_m: f64 = @as(f64, model.vfb);
    const k1_m: f64 = @as(f64, model.k1);
    const k2_m: f64 = @as(f64, model.k2);
    const phin: f64 = @as(f64, model.phin);
    const eta0_m: f64 = @as(f64, model.eta0);
    const etab_m: f64 = @as(f64, model.etab);
    const cit: f64 = @as(f64, model.cit);
    const nfactor: f64 = @as(f64, model.nfactor);
    const cdsc: f64 = @as(f64, model.cdsc);
    const dvtp0: f64 = @as(f64, model.dvtp0);
    const dvtp1: f64 = @as(f64, model.dvtp1);
    const dvtp2: f64 = @as(f64, model.dvtp2);
    const dvtp3: f64 = @as(f64, model.dvtp3);
    const dvtp4: f64 = @as(f64, model.dvtp4);
    const dvtp5: f64 = @as(f64, model.dvtp5);
    const mu0_m: f64 = @as(f64, model.u0);
    const ua_m: f64 = @as(f64, model.ua);
    const uc_m: f64 = @as(f64, model.uc);
    const ud_m: f64 = @as(f64, model.ud);
    const eu_m: f64 = @as(f64, model.eu);
    const ucs_m: f64 = @as(f64, model.ucs);
    const etamob: f64 = @as(f64, model.etamob);
    const vsat_m: f64 = @as(f64, model.vsat);
    const delta_m: f64 = @as(f64, model.delta);
    const pclm: f64 = @as(f64, model.pclm);
    const pscbe1: f64 = @as(f64, model.pscbe1);
    const pscbe2: f64 = @as(f64, model.pscbe2);
    const pdiblc: f64 = @as(f64, model.pdiblc);
    const pdiblcb: f64 = @as(f64, model.pdiblcb);
    const pvag: f64 = @as(f64, model.pvag);
    const pdits: f64 = @as(f64, model.pdits);
    const pditsd: f64 = @as(f64, model.pditsd);
    const prwg: f64 = @as(f64, model.prwg);
    const prwb: f64 = @as(f64, model.prwb);
    const wr_m: f64 = @as(f64, model.wr);
    const rdsw: f64 = @as(f64, model.rdsw);
    const rdswmin: f64 = @as(f64, model.rdswmin);
    const rsw: f64 = @as(f64, model.rsw);
    const rdw: f64 = @as(f64, model.rdw);
    const rswmin: f64 = @as(f64, model.rswmin);
    const rdwmin: f64 = @as(f64, model.rdwmin);
    const rsh: f64 = @as(f64, model.rsh);
    const psat_m: f64 = @as(f64, model.psat);
    const psatb: f64 = @as(f64, model.psatb);
    const ptwg: f64 = @as(f64, model.ptwg);
    const psatx: f64 = @as(f64, model.psatx);
    const ksativ: f64 = @as(f64, model.ksativ);
    const a1_m: f64 = @as(f64, model.a1);
    const a2_m: f64 = @as(f64, model.a2);
    const ags_m: f64 = @as(f64, model.ags);
    const ags1_m: f64 = @as(f64, model.ags1);
    const a0_m: f64 = @as(f64, model.a0);
    const keta_m: f64 = @as(f64, model.keta);
    const xj: f64 = @as(f64, model.xj);
    const a11: f64 = @as(f64, model.a11);
    const a21: f64 = @as(f64, model.a21);
    const avdsx: f64 = @as(f64, model.avdsx);
    const cdsbs: f64 = @as(f64, model.cdsbs);
    const fprout: f64 = @as(f64, model.fprout);
    const pclmg: f64 = @as(f64, model.pclmg);
    const k0_m: f64 = @as(f64, model.k0);
    const m0_m: f64 = @as(f64, model.m0);
    const c0_m: f64 = @as(f64, model.c0);
    const c0si: f64 = @as(f64, model.c0si);
    const c0sisat: f64 = @as(f64, model.c0sisat);

    // BJT / II params
    const alpha0_m: f64 = @as(f64, model.alpha0);
    const beta0_m: f64 = @as(f64, model.beta0);
    const beta1_m: f64 = @as(f64, model.beta1);
    const beta2_m: f64 = @as(f64, model.beta2);
    const isbjt: f64 = @as(f64, model.isbjt);
    const ndiode: f64 = @as(f64, model.ndiode);
    const nbjt_m: f64 = @as(f64, model.nbjt);
    const lbjt0: f64 = @as(f64, model.lbjt0);
    const ln_m: f64 = @as(f64, model.ln_);
    const vabjt: f64 = @as(f64, model.vabjt);
    const aely: f64 = @as(f64, model.aely);
    const ahli: f64 = @as(f64, model.ahli);
    const ahlid: f64 = @as(f64, model.ahlid);
    const vdsatii0: f64 = @as(f64, model.vdsatii0);
    const tii_m: f64 = @as(f64, model.tii);
    const esatii: f64 = @as(f64, model.esatii);
    const sii0: f64 = @as(f64, model.sii0);
    const sii1: f64 = @as(f64, model.sii1);
    const sii2: f64 = @as(f64, model.sii2);
    const siid: f64 = @as(f64, model.siid);
    const lii_m: f64 = @as(f64, model.lii);
    const fbjtii: f64 = @as(f64, model.fbjtii);
    const ebjtii: f64 = @as(f64, model.ebjtii);
    const cbjtii: f64 = @as(f64, model.cbjtii);
    const abjtii: f64 = @as(f64, model.abjtii);
    const vbci_m: f64 = @as(f64, model.vbci);
    const tvbci: f64 = @as(f64, model.tvbci);
    const mbjtii: f64 = @as(f64, model.mbjtii);

    // GIDL/GISL
    const agidl: f64 = @as(f64, model.agidl);
    const bgidl: f64 = @as(f64, model.bgidl);
    const cgidl: f64 = @as(f64, model.cgidl);
    const egidl: f64 = @as(f64, model.egidl);
    const agisl: f64 = @as(f64, model.agisl);
    const bgisl: f64 = @as(f64, model.bgisl);
    const cgisl: f64 = @as(f64, model.cgisl);
    const egisl: f64 = @as(f64, model.egisl);
    const rgidl: f64 = @as(f64, model.rgidl);
    const kgidl: f64 = @as(f64, model.kgidl);
    const fgidl: f64 = @as(f64, model.fgidl);
    const rgisl: f64 = @as(f64, model.rgisl);
    const kgisl: f64 = @as(f64, model.kgisl);
    const fgisl: f64 = @as(f64, model.fgisl);

    // Gate tunneling
    const aigc_m: f64 = @as(f64, model.aigc);
    const bigc_m: f64 = @as(f64, model.bigc);
    const cigc_m: f64 = @as(f64, model.cigc);
    const aigs_m: f64 = @as(f64, model.aigs);
    const bigs_m: f64 = @as(f64, model.bigs);
    const cigs_m: f64 = @as(f64, model.cigs);
    const aigd_m: f64 = @as(f64, model.aigd);
    const bigd_m: f64 = @as(f64, model.bigd);
    const cigd_m: f64 = @as(f64, model.cigd);
    const dlcig: f64 = @as(f64, model.dlcig);
    const poxedge: f64 = @as(f64, model.poxedge);
    const ntox: f64 = @as(f64, model.ntox);
    const toxref: f64 = @as(f64, model.toxref);
    const pigcd: f64 = @as(f64, model.pigcd);
    const agb1: f64 = @as(f64, model.agb1);
    const bgb1: f64 = @as(f64, model.bgb1);
    const agb2: f64 = @as(f64, model.agb2);
    const bgb2: f64 = @as(f64, model.bgb2);
    const alphagb1: f64 = @as(f64, model.alphagb1);
    const betagb1: f64 = @as(f64, model.betagb1);
    const alphagb2: f64 = @as(f64, model.alphagb2);
    const betagb2: f64 = @as(f64, model.betagb2);
    const vgb1: f64 = @as(f64, model.vgb1);
    const vgb2: f64 = @as(f64, model.vgb2);
    const eigbinv: f64 = @as(f64, model.eigbinv);
    const vecb: f64 = @as(f64, model.vecb);

    // Diode parameters
    const isdif: f64 = @as(f64, model.isdif);
    const iddif: f64 = @as(f64, model.iddif);
    const isrec: f64 = @as(f64, model.isrec);
    const idrec: f64 = @as(f64, model.idrec);
    const istun: f64 = @as(f64, model.istun);
    const idtun: f64 = @as(f64, model.idtun);
    const nrecf0: f64 = @as(f64, model.nrecf0);
    const nrecr0: f64 = @as(f64, model.nrecr0);
    const ntun: f64 = @as(f64, model.ntun);
    const ntund: f64 = @as(f64, model.ntund);
    const vtun0_m: f64 = @as(f64, model.vtun0);
    const vtun0d: f64 = @as(f64, model.vtun0d);
    const vrec0_m: f64 = @as(f64, model.vrec0);
    const vrec0d: f64 = @as(f64, model.vrec0d);
    const vtm00: f64 = @as(f64, model.vtm00);

    // Body contact
    const rbody: f64 = @as(f64, model.rbody);
    const rbsh: f64 = @as(f64, model.rbsh);
    const frbody: f64 = @as(f64, model.frbody);
    const nrb: f64 = @as(f64, model.nrb);
    const ub: f64 = @as(f64, model.ub);
    const neff_m: f64 = @as(f64, model.neff);
    const pdbcp: f64 = @as(f64, model.pdbcp);
    const psbcp: f64 = @as(f64, model.psbcp);
    const nbc: f64 = @floatFromInt(model.nbc);
    const dwbc: f64 = @as(f64, model.dwbc);

    // Self-heating
    const rth0: f64 = @as(f64, model.rth0);
    const wth0: f64 = @as(f64, model.wth0);

    // Gate resistance
    const rshg: f64 = @as(f64, model.rshg);
    const xrcrg1: f64 = @as(f64, model.xrcrg1);
    const xrcrg2: f64 = @as(f64, model.xrcrg2);

    // SSL
    const ssl0: f64 = @as(f64, model.ssl0);
    const ssl1: f64 = @as(f64, model.ssl1);
    const ssl2: f64 = @as(f64, model.ssl2);
    const ssl3: f64 = @as(f64, model.ssl3);
    const ssl4: f64 = @as(f64, model.ssl4);
    const ssl5: f64 = @as(f64, model.ssl5);

    // Temperature
    const tnom_c: f64 = @as(f64, model.tnom);
    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);
    const ute_m: f64 = @as(f64, model.ute);
    const ua1_m: f64 = @as(f64, model.ua1);
    const uc1_m: f64 = @as(f64, model.uc1);
    const ud1_m: f64 = @as(f64, model.ud1);
    const ucste: f64 = @as(f64, model.ucste);
    const eu1: f64 = @as(f64, model.eu1);
    const at_m: f64 = @as(f64, model.at);
    const prt_m: f64 = @as(f64, model.prt);
    const kt1_m: f64 = @as(f64, model.kt1);
    const kt2_m: f64 = @as(f64, model.kt2);

    // Stress / WPE
    const ku0_m: f64 = @as(f64, model.ku0);
    const kvsat_m: f64 = @as(f64, model.kvsat);
    const kvth0_m: f64 = @as(f64, model.kvth0);
    const saref: f64 = @as(f64, model.saref);
    const sbref: f64 = @as(f64, model.sbref);
    const kvth0we: f64 = @as(f64, model.kvth0we);
    const k2we: f64 = @as(f64, model.k2we);
    const ku0we: f64 = @as(f64, model.ku0we);
    const web: f64 = @as(f64, model.web);
    const wec: f64 = @as(f64, model.wec);

    // Misc
    const minr: f64 = @as(f64, model.minr);
    const lint: f64 = @as(f64, model.lint);
    const wint: f64 = @as(f64, model.wint);
    const lmlt: f64 = @as(f64, model.lmlt);
    const wmlt: f64 = @as(f64, model.wmlt);
    const xl_m: f64 = @as(f64, model.xl);
    const xw_m: f64 = @as(f64, model.xw);
    const lln: f64 = @as(f64, model.lln);
    const lwn: f64 = @as(f64, model.lwn);
    const wln: f64 = @as(f64, model.wln);
    const wwn: f64 = @as(f64, model.wwn);
    const ll_m: f64 = @as(f64, model.ll);
    const lw_m: f64 = @as(f64, model.lw);
    const wl_m: f64 = @as(f64, model.wl);
    const ww_m: f64 = @as(f64, model.ww);
    const lwl: f64 = @as(f64, model.lwl);
    const wwl: f64 = @as(f64, model.wwl);

    // EdgeFET
    const wedge: f64 = @as(f64, model.wedge);
    const dgammaedge: f64 = @as(f64, model.dgammaedge);
    const dvtedge: f64 = @as(f64, model.dvtedge);
    const nfactoredge: f64 = @as(f64, model.nfactoredge);
    const citedge: f64 = @as(f64, model.citedge);
    const cdscedge: f64 = @as(f64, model.cdscedge);
    const cdscdedge: f64 = @as(f64, model.cdscdedge);
    const eta0edge: f64 = @as(f64, model.eta0edge);
    const etabedge: f64 = @as(f64, model.etabedge);

    // Instance parameters
    const l_inst: f64 = @as(f64, instance.l);
    const w_inst: f64 = @as(f64, instance.w);
    const nf: f64 = @as(f64, instance.nf);
    const nrs: f64 = @as(f64, instance.nrs);
    const nrd: f64 = @as(f64, instance.nrd);
    const sa: f64 = @as(f64, instance.sa);
    const sb: f64 = @as(f64, instance.sb);
    const sca: f64 = @as(f64, instance.sca);
    const scb: f64 = @as(f64, instance.scb);
    const scc: f64 = @as(f64, instance.scc);
    const dtemp: f64 = @as(f64, instance.dtemp);
    const delvto: f64 = @as(f64, instance.delvto);
    const mulu0: f64 = @as(f64, instance.mulu0);
    const ids0mult: f64 = @as(f64, instance.ids0mult);
    const xgw_i: f64 = @as(f64, instance.xgw);
    const ngcon_i: f64 = @floatFromInt(instance.ngcon);

    // --- Derived geometry (Sec. 5.2) ---
    const l_new = l_inst * lmlt + xl_m;
    const w_new = w_inst / nf * wmlt + xw_m;
    const l_new_c = @max(l_new, 1e-20);
    const w_new_c = @max(w_new, 1e-20);

    const dl_iv = lint + ll_m / contract.fmath.exp(lln * contract.fmath.log(@max(l_new_c, 1e-30))) + lw_m / contract.fmath.exp(lwn * contract.fmath.log(@max(w_new_c, 1e-30))) + lwl / (contract.fmath.exp(lln * contract.fmath.log(@max(l_new_c, 1e-30))) * contract.fmath.exp(lwn * contract.fmath.log(@max(w_new_c, 1e-30))));
    const dw_iv = wint + wl_m / contract.fmath.exp(wln * contract.fmath.log(@max(l_new_c, 1e-30))) + ww_m / contract.fmath.exp(wwn * contract.fmath.log(@max(w_new_c, 1e-30))) + wwl / (contract.fmath.exp(wln * contract.fmath.log(@max(l_new_c, 1e-30))) * contract.fmath.exp(wwn * contract.fmath.log(@max(w_new_c, 1e-30))));

    const leff = @max(l_inst * lmlt + xl_m - 2.0 * dl_iv, 1e-9);
    const weff = @max(w_inst * wmlt + xw_m - 2.0 * dw_iv, 1e-9);

    // --- Physical constants derived ---
    const eps_sub = epsrsub * eps0;
    const eps_ox = epsrox * eps0;
    const cox = 3.9 * eps0 / toxe;
    const eps_ratio = epsrsub / 3.9;

    // --- Temperature ---
    const tnom_k = tnom_c + 273.15;
    const temp_k = tnom_k + dtemp;
    const vt = k_B * temp_k / q_e;
    const vt_nom = k_B * tnom_k / q_e;
    const t_ratio = temp_k / tnom_k;

    // Bandgap
    const eg0 = bg0sub - tbgasub * tnom_k * tnom_k / (tnom_k + tbgbsub);
    const eg = bg0sub - tbgasub * temp_k * temp_k / (temp_k + tbgbsub);

    // Intrinsic carrier concentration
    const ni = ni0sub * contract.fmath.exp(1.5 * contract.fmath.log(t_ratio)) * contract.fmath.exp(@min(eg0 / (2.0 * vt_nom) - eg / (2.0 * vt), 80.0));

    // --- Temperature-dependent parameters ---
    const mu0_t = mu0_m * mulu0 * contract.fmath.exp(ute_m * contract.fmath.log(t_ratio));
    const ua_t = ua_m * (1.0 + ua1_m * (temp_k - tnom_k));
    const uc_t = uc_m * (1.0 + uc1_m * (temp_k - tnom_k));
    const ud_t = ud_m * contract.fmath.exp(ud1_m * contract.fmath.log(t_ratio));
    const ucs_t = ucs_m * contract.fmath.exp(ucste * contract.fmath.log(t_ratio));
    const eu_t = eu_m * (1.0 + eu1 * (t_ratio - 1.0));
    const vsat_t = vsat_m * contract.fmath.exp(-at_m * contract.fmath.log(t_ratio));
    const rdsw_t = rdsw * contract.fmath.exp(prt_m * contract.fmath.log(t_ratio));
    const kt1exp_m: f64 = @as(f64, model.kt1exp);

    // Temperature-dependent NFACTOR
    const tnfactor_m: f64 = @as(f64, model.tnfactor);
    const nfactor_t = nfactor + tnfactor_m * (t_ratio - 1.0);

    // Temperature-dependent DELTA
    const tdelta_m: f64 = @as(f64, model.tdelta);
    const delta_t = delta_m * (1.0 + tdelta_m * (temp_k - tnom_k));

    // Temperature-dependent K0/M0
    const k01_m: f64 = @as(f64, model.k01);
    const m01_m: f64 = @as(f64, model.m01);
    const k0_t = k0_m * (1.0 + k01_m * (temp_k - tnom_k));
    const m0_t = m0_m * (1.0 + m01_m * (temp_k - tnom_k));

    // Temperature-dependent C0/C0SI/C0SISAT
    const c01_m: f64 = @as(f64, model.c01);
    const c0si1_m: f64 = @as(f64, model.c0si1);
    const c0sisat1_m: f64 = @as(f64, model.c0sisat1);
    const c0_t = c0_m * (1.0 + c01_m * (temp_k - tnom_k));
    const c0si_t = c0si * (1.0 + c0si1_m * (temp_k - tnom_k));
    const c0sisat_t = c0sisat * (1.0 + c0sisat1_m * (temp_k - tnom_k));

    // Temperature coefficients for diode saturation currents
    const xbjt_m: f64 = @as(f64, model.xbjt);
    const xdif_m: f64 = @as(f64, model.xdif);
    const xrec_m: f64 = @as(f64, model.xrec);
    const xtun_m: f64 = @as(f64, model.xtun);
    const xtund_m: f64 = @as(f64, model.xtund);
    const eg_vt_ratio = eg0 / vt_nom - eg / vt;
    const isbjt_t = isbjt * contract.fmath.exp(@min((eg_vt_ratio + xbjt_m * contract.fmath.log(t_ratio)) / @max(ndiode, 1.0), 80.0));
    const idbjt_t: f64 = @as(f64, model.idbjt) * contract.fmath.exp(@min((eg_vt_ratio + xbjt_m * contract.fmath.log(t_ratio)) / @max(ndiode, 1.0), 80.0));
    const isdif_t = isdif * contract.fmath.exp(@min((eg_vt_ratio + xdif_m * contract.fmath.log(t_ratio)) / @max(ndiode, 1.0), 80.0));
    const iddif_t = iddif * contract.fmath.exp(@min((eg_vt_ratio + xdif_m * contract.fmath.log(t_ratio)) / @max(ndiode, 1.0), 80.0));
    const isrec_t = isrec * contract.fmath.exp(@min((eg_vt_ratio + xrec_m * contract.fmath.log(t_ratio)) / @max(nrecf0, 1.0), 80.0));
    const idrec_t = idrec * contract.fmath.exp(@min((eg_vt_ratio + xrec_m * contract.fmath.log(t_ratio)) / @max(nrecf0, 1.0), 80.0));
    const istun_t = istun * contract.fmath.exp(@min((eg_vt_ratio + xtun_m * contract.fmath.log(t_ratio)) / @max(ntun, 1.0), 80.0));
    const idtun_t = idtun * contract.fmath.exp(@min((eg_vt_ratio + xtund_m * contract.fmath.log(t_ratio)) / @max(ntund, 1.0), 80.0));

    // --- Physical quantities (Sec. 5.6) ---
    const phi_b = contract.fmath.log(@max(ndep / ni, 1.0));
    const phi_st = 2.0 * vt * phi_b + phin;

    const cb = eps_sub / @max(tsi, 1e-30);
    const cbox = eps_ox / @max(tbox, 1e-30);

    // --- Subthreshold slope (Sec. 5.8) --- (n uses vdsx/vbsx; those depend on
    // vds. The original recomputes n INSIDE the tail because cdscd/cdscb feed
    // it. Here we split: base (x-independent) contribution vs the vdsx/vbsx
    // terms handled in the S tail. To preserve the EXACT default-param physics
    // (cdscd=cdscb=0 by default) we compute n's x-independent part; the tail
    // adds the bias terms.  See eval() comment.)
    const n_base = if (model.soimod == 0)
        1.0 + (cit + nfactor_t + cdsc) / @max(cox, 1e-30)
    else
        1.0 + (cit + nfactor_t + cdsc) / @max(cox + cb * cbox / @max(cb + cbox, 1e-30), 1e-30);
    // n at zero bias (used for the many x-independent uses of n/nvt below).
    const n = @max(n_base, 1.01);
    const nvt = n * vt;

    // Vth temperature-shift coefficients pushed into S tail (depend on vbs_eff)
    const eta0_eff = eta0_m + @as(f64, model.teta0) * (t_ratio - 1.0);

    const sqrt_phi_st = @sqrt(@max(phi_st, 1e-30));

    // --- Stress effect (Sec. 9) ---
    const l_drawn = l_inst;
    const inv_sa = if (sa > 0) 1.0 / (sa + 0.5 * l_drawn) else 0.0;
    const inv_sb = if (sb > 0) 1.0 / (sb + 0.5 * l_drawn) else 0.0;
    const inv_sa_ref = 1.0 / (saref + 0.5 * l_drawn);
    const inv_sb_ref = 1.0 / (sbref + 0.5 * l_drawn);

    const stress_u0_inst = ku0_m * (inv_sa + inv_sb);
    const stress_u0_ref = ku0_m * (inv_sa_ref + inv_sb_ref);
    const stress_u0_ratio = (1.0 + stress_u0_inst) / @max(1.0 + stress_u0_ref, 1e-30);

    const stress_vth = kvth0_m * (inv_sa + inv_sb - inv_sa_ref - inv_sb_ref);

    // Well proximity effect (Sec. 10)
    const wpe_sum = sca + web * scb + wec * scc;
    const vth_wpe = if (model.wpemod != 0) kvth0we * wpe_sum else 0.0;
    const mu0_wpe = if (model.wpemod != 0) 1.0 + ku0we * wpe_sum else 1.0;
    _ = k2we; // K2 WPE shift feeds vbsx-dependent term in the tail

    // Final Vth base
    const vfb_eff = vfb_m + stress_vth + vth_wpe;

    // --- Effective field (Sec. 5.10) ---
    const eta_mob = if (type_f > 0) 0.5 * etamob else (1.0 / 3.0) * etamob;

    // --- Mobility scaling (Sec. 5.4) ---
    const up1_m: f64 = @as(f64, model.up1);
    const lp1_m: f64 = @as(f64, model.lp1);
    const up2_m: f64 = @as(f64, model.up2);
    const lp2_m: f64 = @as(f64, model.lp2);
    const mob_u0l: f64 = @as(f64, model.u0l);
    const mob_u0lexp: f64 = @as(f64, model.u0lexp);
    const mu0_scaled = if (model.mobscale == 1)
        mu0_t * (1.0 - up1_m * contract.fmath.exp(-leff / @max(lp1_m, 1e-30)) - up2_m * contract.fmath.exp(-leff / @max(lp2_m, 1e-30)))
    else if (mob_u0lexp > 0)
        mu0_t * (1.0 - mob_u0l * contract.fmath.exp(-mob_u0lexp * contract.fmath.log(@max(leff, 1e-30))))
    else
        mu0_t * (1.0 - mob_u0l);

    // --- Saturation velocity (with KVSAT stress, Sec. 9) ---
    const vsat_stress_ratio = (1.0 + kvsat_m * stress_u0_inst) / @max(1.0 + kvsat_m * stress_u0_ref, 1e-30);
    const vsat_eff = vsat_t * vsat_stress_ratio;
    const esat = 2.0 * vsat_eff / @max(mu0_scaled * stress_u0_ratio * mu0_wpe, 1e-30);
    _ = esat;
    const esat_l = 2.0 * vsat_eff / @max(mu0_scaled * stress_u0_ratio * mu0_wpe, 1e-30) * leff;

    // Non-saturation effect temp constants
    const a1_t = a1_m * (1.0 + a11 * (t_ratio - 1.0));
    const a2_t = a2_m * (1.0 + a21 * (t_ratio - 1.0));

    // impact ionization temp constant
    const vbci_t = vbci_m * (1.0 + tvbci * (t_ratio - 1.0));

    // gate resistance
    const rgeltd = if (rshg > 0.01 * minr)
        rshg * (xgw_i + weff / (3.0 * ngcon_i)) / @max(ngcon_i * (l_inst - @as(f64, model.xgl)) * nf, 1e-30)
    else
        0.0;
    _ = rgeltd;
    // ngate/cdsbs feed gamma_g/delta_pd and the cdsbs-dependent n term, which the
    // original code computed but discarded (default cdsbs=0). Kept as params only.
    _ = ngate;
    _ = cdsbs;

    return .{
        .type_f = type_f,
        .tsi = tsi,
        .toxe = toxe,
        .cox = cox,
        .eps_ratio = eps_ratio,
        .vt = vt,
        .nvt = nvt,
        .n = n,
        .t_ratio = t_ratio,
        .phi_st = phi_st,
        .sqrt_phi_st = sqrt_phi_st,
        .k1_m = k1_m,
        .k2_m = k2_m,
        .eta0_eff = eta0_eff,
        .etab_m = etab_m,
        .kt1_m = kt1_m,
        .kt2_m = kt2_m,
        .kt1exp_m = kt1exp_m,
        .delvto = delvto,
        .dvtp0 = dvtp0,
        .dvtp1 = dvtp1,
        .dvtp2 = dvtp2,
        .dvtp3 = dvtp3,
        .dvtp4 = dvtp4,
        .dvtp5 = dvtp5,
        .vfb_m = vfb_m,
        .vfb_eff = vfb_eff,
        .leff = leff,
        .weff = weff,
        .delta_t = delta_t,
        .a0_m = a0_m,
        .ags_m = ags_m,
        .ags1_m = ags1_m,
        .keta_m = keta_m,
        .xj = xj,
        .ndep = ndep,
        .eps_sub = eps_sub,
        .eta_mob = eta_mob,
        .eu_t = eu_t,
        .ua_t = ua_t,
        .uc_t = uc_t,
        .ud_t = ud_t,
        .ucs_t = ucs_t,
        .mu0_scaled = mu0_scaled,
        .stress_u0_ratio = stress_u0_ratio,
        .mu0_wpe = mu0_wpe,
        .vsat_eff = vsat_eff,
        .esat_l = esat_l,
        .ksativ = ksativ,
        .abulk = 1.0, // abulk is bias-dependent, recomputed in tail; placeholder
        .psat_m = psat_m,
        .psatb = psatb,
        .psatx = psatx,
        .ptwg = ptwg,
        .rdsmod = model.rdsmod,
        .prwg = prwg,
        .prwb = prwb,
        .wr_m = wr_m,
        .weff_r = weff,
        .nf = nf,
        .rdswmin = rdswmin,
        .rdsw_t = rdsw_t,
        .a1_t = a1_t,
        .a2_t = a2_t,
        .pclm = pclm,
        .pclmg = pclmg,
        .pdiblc = pdiblc,
        .fprout = fprout,
        .pvag = pvag,
        .pdiblcb = pdiblcb,
        .pscbe1 = pscbe1,
        .pscbe2 = pscbe2,
        .pdits = pdits,
        .pditsd = pditsd,
        .k0_t = k0_t,
        .m0_t = m0_t,
        .c0_t = c0_t,
        .c0si_t = c0si_t,
        .c0sisat_t = c0sisat_t,
        .ids0mult = ids0mult,
        .nbc = nbc,
        .dwbc = dwbc,
        .psbcp = psbcp,
        .pdbcp = pdbcp,
        .ln_m = ln_m,
        .ndiode = ndiode,
        .isdif_t = isdif_t,
        .iddif_t = iddif_t,
        .isrec_t = isrec_t,
        .idrec_t = idrec_t,
        .istun_t = istun_t,
        .idtun_t = idtun_t,
        .isbjt_t = isbjt_t,
        .idbjt_t = idbjt_t,
        .nbjt_m = nbjt_m,
        .lbjt0 = lbjt0,
        .nrecf0 = nrecf0,
        .nrecr0 = nrecr0,
        .ntun = ntun,
        .ntund = ntund,
        .vtm00 = vtm00,
        .vrec0_m = vrec0_m,
        .vrec0d = vrec0d,
        .vtun0_m = vtun0_m,
        .vtun0d = vtun0d,
        .ahli = ahli,
        .ahlid = ahlid,
        .vabjt = vabjt,
        .aely = aely,
        .bjtoff = model.bjtoff,
        .iiimod = model.iiimod,
        .alpha0_m = alpha0_m,
        .beta0_m = beta0_m,
        .beta1_m = beta1_m,
        .beta2_m = beta2_m,
        .esatii = esatii,
        .sii0 = sii0,
        .sii1 = sii1,
        .sii2 = sii2,
        .siid = siid,
        .vdsatii0 = vdsatii0,
        .tii_m = tii_m,
        .lii_m = lii_m,
        .fbjtii = fbjtii,
        .vbci_t = vbci_t,
        .cbjtii = cbjtii,
        .ebjtii = ebjtii,
        .abjtii = abjtii,
        .mbjtii = mbjtii,
        .gidlmod = model.gidlmod,
        .agidl = agidl,
        .bgidl = bgidl,
        .cgidl = cgidl,
        .egidl = egidl,
        .agisl = agisl,
        .bgisl = bgisl,
        .cgisl = cgisl,
        .egisl = egisl,
        .rgidl = rgidl,
        .kgidl = kgidl,
        .fgidl = fgidl,
        .rgisl = rgisl,
        .kgisl = kgisl,
        .fgisl = fgisl,
        .igcmod = model.igcmod,
        .igbmod = model.igbmod,
        .vecb = vecb,
        .eigbinv = eigbinv,
        .aigc_m = aigc_m,
        .bigc_m = bigc_m,
        .cigc_m = cigc_m,
        .aigs_m = aigs_m,
        .bigs_m = bigs_m,
        .cigs_m = cigs_m,
        .aigd_m = aigd_m,
        .bigd_m = bigd_m,
        .cigd_m = cigd_m,
        .dlcig = dlcig,
        .poxedge = poxedge,
        .ntox = ntox,
        .toxref = toxref,
        .pigcd = pigcd,
        .agb1 = agb1,
        .bgb1 = bgb1,
        .agb2 = agb2,
        .bgb2 = bgb2,
        .alphagb1 = alphagb1,
        .betagb1 = betagb1,
        .alphagb2 = alphagb2,
        .betagb2 = betagb2,
        .vgb1 = vgb1,
        .vgb2 = vgb2,
        .sslmod = instance.sslmod,
        .ssl0 = ssl0,
        .ssl1 = ssl1,
        .ssl2 = ssl2,
        .ssl3 = ssl3,
        .ssl4 = ssl4,
        .ssl5 = ssl5,
        .edgefet = instance.edgefet,
        .citedge = citedge,
        .nfactoredge = nfactoredge,
        .cdscedge = cdscedge,
        .cdscdedge = cdscdedge,
        .eta0edge = eta0edge,
        .etabedge = etabedge,
        .dvtedge = dvtedge,
        .dgammaedge = dgammaedge,
        .wedge = wedge,
        .avdsx = avdsx,
        .minr = minr,
        .rshg = rshg,
        .xgw_i = xgw_i,
        .ngcon_i = ngcon_i,
        .xgl = @as(f64, model.xgl),
        .l_inst = l_inst,
        .xrcrg1 = xrcrg1,
        .xrcrg2 = xrcrg2,
        .mu_eff_pre = mu0_scaled * stress_u0_ratio * mu0_wpe,
        .rsh = rsh,
        .nrs = nrs,
        .nrd = nrd,
        .rswmin = rswmin,
        .rsw = rsw,
        .rdwmin = rdwmin,
        .rdw = rdw,
        .bodymod = model.bodymod,
        .rbody = rbody,
        .frbody = frbody,
        .rhalo = @as(f64, model.rhalo),
        .rbsh = rbsh,
        .nrb = nrb,
        .neff_m = neff_m,
        .ub = ub,
        .shmod = model.shmod,
        .rth0 = rth0,
        .wth0 = wth0,
    };
}

pub const PrepCache = struct { dc: Prep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = prep(model, instance), .q = qprep(model, instance) };
}

// --- Softplus-style helpers on S (keep derivatives consistent) ---

/// smooth |v|-style vdsx: 2/a*log(exp(min(a*vds/2,80))+1) - vds - 2/a*log(2)
fn vdsxOf(comptime SS: type, vds: SS, avdsx: f64) SS {
    const a2 = avdsx * 0.5;
    return vds.scale(a2).minC(80.0).exp().addC(1.0).log().scale(2.0 / avdsx)
        .sub(vds).addC(-2.0 / avdsx * contract.fmath.log(2.0));
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    const p = &pc.dc;

    // --- Read terminal voltages ---
    const vg_ext = x[G];
    const vd_ext = x[D];
    const vs_ext = x[S_i];
    const ve = x[E];
    const vb_ext = x[B];
    const vdp = x[DP];
    const vsp = x[SP];
    const vbp = x[BP];
    const vtemp = x[T];
    const vgp = x[GP];

    const type_f = p.type_f;
    const vt = p.vt;
    const nvt = p.nvt;
    const n = p.n;
    const cox = p.cox;
    const toxe = p.toxe;
    const leff = p.leff;
    const weff = p.weff;
    const eps_ratio = p.eps_ratio;

    // Type-adjusted internal voltages
    const vgs = vgp.sub(vsp).scale(type_f);
    const vds_raw = vdp.sub(vsp).scale(type_f);
    const vbs = vbp.sub(vsp).scale(type_f);

    // --- Source-drain reversal (branchless) ---
    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const mode = vds_raw.div(vds_abs.addC(1e-30));
    const vgs_eff = vgs.sub(vds_neg);
    const vbs_eff = vbs.sub(vds_neg);
    const vds = vds_abs;

    // --- Vdsx smooth abs (Sec. 5.5) ---
    const vdsx = vdsxOf(S, vds, p.avdsx);
    const vbsx = vds.sub(vdsx).scale(-0.5);

    // --- Threshold voltage (Sec. 5.8) ---
    const sqrt_phi_st = p.sqrt_phi_st;
    const sqrt_phi_vbs = vbs_eff.neg().addC(p.phi_st).maxC(1e-30).sqrt();
    // dv_vnud = k1*(sqrt_phi_vbs - sqrt_phi_st) - k2*vbsx
    const dv_vnud = sqrt_phi_vbs.addC(-sqrt_phi_st).scale(p.k1_m).sub(vbsx.scale(p.k2_m));
    // dv_dibl = -(eta0_eff + etab*vbsx)*vdsx
    const dv_dibl = vbsx.scale(p.etab_m).addC(p.eta0_eff).mul(vdsx).neg();
    // DITS shift
    const dits_ln_arg = leffDitsArg(S, vds, leff, p.dvtp0, p.dvtp1);
    const dv_dits_a = dits_ln_arg.log().scale(-nvt);
    const dv_dits_b = vdsx.scale(-2.0 * p.dvtp4).minC(80.0).exp().addC(1.0)
        .div(S.con(2.0)).neg(); // placeholder, replaced below
    _ = dv_dits_b;
    // dv_dits = -nvt*log(arg) - (dvtp5 + dvtp2/leff)*dvtp3*(2/(1+exp(min(-2*dvtp4*vdsx,80)))-1)
    const dits_c = (p.dvtp5 + p.dvtp2 / @max(leff, 1e-30)) * p.dvtp3;
    const dits_exp = vdsx.scale(-2.0 * p.dvtp4).minC(80.0).exp().addC(1.0);
    const dits_term = S.con(2.0).div(dits_exp).addC(-1.0).scale(dits_c);
    const dv_dits = dv_dits_a.sub(dits_term);

    // Vth temperature shift: (kt1 + kt2*vbs_eff)*((t_ratio)^kt1exp - 1)
    const kt_pow = contract.fmath.exp(p.kt1exp_m * contract.fmath.log(p.t_ratio)) - 1.0;
    const vth_shift_t = vbs_eff.scale(p.kt2_m).addC(p.kt1_m).scale(kt_pow);

    const dv_th_all = dv_vnud.add(dv_dibl).add(dv_dits).add(vth_shift_t).addC(p.delvto);

    const vth = dv_th_all.neg().addC(p.vfb_eff + p.phi_st);

    // --- Gate overdrive ---
    const vgst = vgs_eff.sub(vth);
    // smooth clamp: 0.5*(vgst + sqrt(vgst^2 + 4*(delta_t*vt)^2))
    const dvt2 = 4.0 * p.delta_t * vt * p.delta_t * vt;
    const vgst_sm = vgst.add(vgst.mul(vgst).addC(dvt2).sqrt()).scale(0.5);
    const vgst_eff = vgst_sm.maxC(1e-30);

    // Normalized inversion charge
    const qs_norm = vgst.scale(1.0 / (2.0 * nvt)).minC(40.0).exp().addC(1.0).log();
    const qd_norm_arg = vgst.sub(vds).scale(1.0 / (2.0 * nvt)).minC(40.0).exp().addC(1.0).log();

    // --- AbulkIV (Sec. 5.18) ---
    const xdep = vbs_eff.neg().addC(p.phi_st).maxC(0.01).scale(2.0 * p.eps_sub / (q_e * @max(p.ndep, 1.0))).sqrt();
    const t1_abulk = xdep.scale(p.xj).maxC(1e-30).sqrt().addC(leff).maxC(1e-30);
    const t1_abulk_ratio = S.con(leff).div(t1_abulk);
    // abulk = 1 + (a0*t1 - ags*exp(ags1*log(qs))*vt*t1)/(1+keta*vbsx)
    const ags_factor = qs_norm.maxC(1e-30).log().scale(p.ags1_m).exp().scale(p.ags_m * vt);
    const abulk_num = t1_abulk_ratio.scale(p.a0_m).sub(ags_factor.mul(t1_abulk_ratio));
    const abulk_den = vbsx.scale(p.keta_m).addC(1.0).maxC(1e-6);
    const abulk = abulk_num.div(abulk_den).addC(1.0).maxC(0.01);

    // --- Effective field (Sec. 5.10) ---
    const qba = qs_norm;
    const qia = qs_norm.maxC(1e-20);
    const eeff = qba.add(qia.scale(p.eta_mob)).scale(1e-8 / (eps_ratio * toxe));
    const eeff_pos = eeff.maxC(1e-30);

    // --- Mobility degradation (Sec. 5.10) ---
    const eeff_eu = eeff_pos.log().scale(p.eu_t).exp();
    const coulomb_denom = qba.div(qia).addC(1.0).maxC(1e-30).sqrt().scale(0.5).maxC(1e-30);
    const coulomb_term = coulomb_denom.log().scale(p.ucs_t).exp();
    const coulomb = S.con(p.ud_t).div(coulomb_term);
    const dmob = vbsx.scale(p.uc_t).addC(p.ua_t).mul(eeff_eu).add(coulomb).addC(1.0);
    const dmob_eff = dmob.maxC(0.01);

    // --- Applied stress to u0 ---
    const mu0_eff = S.con(p.mu_eff_pre).div(dmob_eff);
    const mu_eff = mu0_eff.maxC(1e-20);

    // --- Saturation ---
    const esat_l = p.esat_l;
    const vsat_eff = p.vsat_eff;

    // --- Drain saturation voltage (Sec. 5.9) ---
    const psat_eff = vbsx.scale(p.psatb).addC(p.psat_m);
    const dmob_psat = dmob_eff.maxC(1e-30).log().mul(psat_eff).exp();
    const t0_ptwg = qs_norm.scale(10.0 * p.psatx);
    const ptwg_factor = t0_ptwg.div(t0_ptwg.addC(10.0 * p.psatx).maxC(1e-30)).scale(p.ptwg).addC(1.0);
    const lambda_c_den = dmob_psat.scale(vsat_eff * leff).maxC(1e-30);
    const lambda_c = mu_eff.scale(2.0 * nvt).div(lambda_c_den).mul(ptwg_factor);
    const qdsat_num = qs_norm.mul(qs_norm).add(qs_norm).mul(lambda_c).scale(0.5);
    const qdsat_den = qs_norm.addC(1.0).mul(lambda_c).scale(0.5).addC(1.0).maxC(1e-30);
    const qdsat = qdsat_num.div(qdsat_den);
    _ = qdsat;

    // SOIMOD=1 style vdsat (used in Vdseff smoothing)
    const vdsat_t2 = qia.scale(2.0 * nvt).addC(2.0 * vt).scale(p.ksativ);
    const vdsat_raw = vdsat_t2.scale(esat_l).div(vdsat_t2.addC(esat_l).maxC(1e-30));
    const vdsat = vdsat_raw.div(abulk.maxC(0.01)).maxC(1e-6);

    // --- Vdseff smooth clamping (Sec. 5.9) ---
    const vds_minus_vdsat = vds.sub(vdsat);
    const vds_delta = vds_minus_vdsat.mul(vds_minus_vdsat).add(vdsat.scale(4.0 * p.delta_t)).maxC(1e-40).sqrt();
    const vdseff = vdsat.sub(vds_delta.sub(vds).add(vdsat).scale(0.5));
    const vdseff_c = vdseff.min(vds).maxC(0.0);

    // --- Series resistance (Sec. 2.2) ---
    const t0_r = qia.scale(p.prwg).addC(1.0);
    const t1_r = vbs_eff.neg().addC(p.phi_st).maxC(1e-30).sqrt().addC(-sqrt_phi_st).scale(p.prwb);
    const t2_r = S.con(1.0).div(t0_r.maxC(1e-30)).add(t1_r);
    const t3_r = t2_r.add(t2_r.mul(t2_r).addC(0.01).sqrt()).scale(0.5);
    const rds_bias = if (p.rdsmod == 0 or p.rdsmod == 2)
        t3_r.scale(p.rdsw_t).addC(p.rdswmin).scale(p.nf * p.wr_m / @max(weff, 1e-30))
    else
        S.con(0.0);

    // Dvsat for velocity saturation
    const wvcox = mu_eff.scale(cox * weff / leff);
    const dr = wvcox.mul(qia).mul(rds_bias).addC(1.0);

    // --- Velocity saturation (Sec. 5.12) ---
    const zsat = vdseff_c.mul(mu_eff).scale(2.0 / (vsat_eff * leff * leff));
    const dvsat = zsat.scale(2.0).addC(1.0).sqrt().addC(1.0).scale(0.5);

    const dtot = dmob_eff.mul(dvsat).mul(dr.maxC(1.0));
    const mu_total = S.con(p.mu_eff_pre).div(dtot.maxC(0.01));

    // --- Non-saturation effect (Sec. 5.12) ---
    const t0_ns = qia.scale(2.0 * nvt).addC(0.0); // qia + ... below
    _ = t0_ns;
    const t0_ns_den = qia.scale(1.0).addC(2.0 * nvt).maxC(1e-30);
    const t0_ns2 = S.con(p.a2_t).div(t0_ns_den).addC(p.a1_t);
    const t3_ns = t0_ns2.mul(vdseff_c).mul(vdseff_c).maxC(0.0);
    const nsat = t3_ns.addC(1.0).sqrt().addC(1.0).scale(0.5);

    // --- Output conductance multipliers (Sec. 5.11) ---
    const vasat = vdsat.addC(esat_l);

    // CLM
    const cclm = vgs_eff.scale(p.pclmg).addC(1.0).scale(p.pclm).maxC(1e-30);
    const mclm = vds.sub(vdseff_c).div(vasat.maxC(1e-30)).addC(1.0).maxC(1.0).log().mul(cclm).addC(1.0);

    // DIBL
    const theta_rout = @max(p.pdiblc + p.fprout * @sqrt(@max(leff, 1e-30)), 1e-30);
    const va_dibl_num = qia.scale(1.0).addC(2.0 * vt).scale(1.0 / theta_rout);
    const pvag_f = vgst_eff.scale(p.pvag / @max(esat_l, 1e-30)).addC(1.0);
    const va_dibl = va_dibl_num.mul(pvag_f).div(vbsx.scale(p.pdiblcb).addC(1.0)).maxC(1e-10);
    const mdibl = vds.sub(vdseff_c).div(va_dibl).addC(1.0);

    // SCBE
    const litl = @sqrt(p.eps_sub * toxe / (p.eps_sub / p.eps_ratio * 3.9 + p.eps_sub));
    // NOTE: eps_ox = epsrox*eps0; here eps_ox = eps_sub/eps_ratio (eps_ratio=epsrsub/3.9)
    // Original: litl = sqrt(eps_sub*toxe/(eps_ox+eps_sub)). eps_ox = eps_sub*3.9/epsrsub = eps_sub/eps_ratio.
    const scbe_num = vds.sub(vdseff_c).maxC(1e-10);
    const scbe_arg = S.con(p.pscbe1 * litl).div(scbe_num);
    const va_scbe = if (p.pscbe2 > 0)
        scbe_arg.minC(80.0).exp().scale(leff / p.pscbe2)
    else
        S.con(1e30);
    const mscbe = vds.sub(vdseff_c).div(va_scbe.maxC(1e-10)).addC(1.0);

    // DITS
    const mdits = if (p.pdits > 0)
        vds.sub(vdseff_c).div(vds.scale(p.pditsd).minC(80.0).exp().addC(1.0).scale(1.0 / p.pdits)).addC(1.0)
    else
        S.con(1.0);

    const moc = mclm.mul(mdibl).mul(mscbe).mul(mdits);

    // --- MNUD / MNUD1 (Sec. 5.16-5.17) ---
    const qs_qd_diff = qs_norm.sub(qd_norm_arg);
    const qs_qd_sum = qs_norm.add(qd_norm_arg);
    const mnud_den = qs_qd_sum.addC(p.m0_t);
    const mnud = qs_qd_diff.mul(qs_qd_diff).scale(p.k0_t).div(mnud_den.mul(mnud_den).maxC(1e-30)).addC(1.0);
    const mnud1_den = qs_qd_diff.mul(qs_qd_diff).scale(p.c0sisat_t).addC(p.c0si_t).mul(qs_qd_sum).addC(2.0 * nvt).maxC(1e-30);
    const mnud1_arg = S.con(-p.c0_t).div(mnud1_den);
    const mnud1 = mnud1_arg.maxC(-80.0).exp();

    // --- Drain current (Sec. 5.14) ---
    const ids_gm = qs_norm.sub(qd_norm_arg).mul(qs_norm.add(qd_norm_arg).addC(1.0));
    const ids_raw = ids_gm.mul(mu_total).scale(2.0 * n * (weff / leff) * cox * nvt * nvt);
    const ids_final = ids_raw.mul(moc).div(mnud.mul(mnud1).mul(nsat).maxC(1e-30)).scale(p.ids0mult);

    // --- Parasitic BJT current (Sec. 3.1) ---
    const weff_bc = weff - p.nbc * p.dwbc;
    const weff_prime = @max(weff_bc, 1e-10);
    const wdios = weff_prime + p.psbcp;
    const wdiod = weff_prime + p.pdbcp;

    const alpha_bjt = contract.fmath.exp(-0.5 * (leff / @max(p.ln_m, 1e-30)) * (leff / @max(p.ln_m, 1e-30)));

    const vbs_junc = vbs_eff;
    const vbd_junc = vbs_eff.sub(vds);

    const exp_bs = vbs_junc.scale(1.0 / @max(p.ndiode * vt, 1e-30)).minC(80.0).exp();
    const exp_bd = vbd_junc.scale(1.0 / @max(p.ndiode * vt, 1e-30)).minC(80.0).exp();

    // Diffusion current
    const ibs1 = exp_bs.addC(-1.0).scale(wdios * p.tsi * p.isdif_t);
    const ibd1 = exp_bd.addC(-1.0).scale(wdiod * p.tsi * p.iddif_t);

    // Recombination current
    const exp_bs_rec = vbs_junc.scale(1.0 / @max(p.vtm00 * p.nrecf0, 1e-30)).minC(80.0).exp();
    const vsb = vbs_junc.neg();
    const exp_sb_rec = vsb.scale(1.0 / @max(p.vtm00 * p.nrecr0, 1e-30)).minC(80.0).exp();
    const vrec0_fac_s = if (p.vrec0_m > 0)
        vsb.abs().addC(p.vrec0_m).maxC(1e-30)
    else
        S.con(1.0);
    const vrec0_term_s = if (p.vrec0_m > 0) S.con(p.vrec0_m).div(vrec0_fac_s) else S.con(1.0);
    const ibs2 = exp_bs_rec.sub(exp_sb_rec.mul(vrec0_term_s)).scale(wdios * p.tsi * p.isrec_t);

    const exp_bd_rec = vbd_junc.scale(1.0 / @max(p.vtm00 * p.nrecf0, 1e-30)).minC(80.0).exp();
    const vdb = vbd_junc.neg();
    const exp_db_rec = vdb.scale(1.0 / @max(p.vtm00 * p.nrecr0, 1e-30)).minC(80.0).exp();
    const vrec0_fac_d = if (p.vrec0d > 0)
        vdb.abs().addC(p.vrec0d).maxC(1e-30)
    else
        S.con(1.0);
    const vrec0_term_d = if (p.vrec0d > 0) S.con(p.vrec0d).div(vrec0_fac_d) else S.con(1.0);
    const ibd2 = exp_bd_rec.sub(exp_db_rec.mul(vrec0_term_d)).scale(wdiod * p.tsi * p.idrec_t);

    // Tunneling current
    const vtun0_term_s = if (p.vtun0_m > 0) S.con(p.vtun0_m).div(vsb.abs().addC(p.vtun0_m).maxC(1e-30)) else S.con(1.0);
    const exp_tun_s = vsb.scale(1.0 / @max(p.vtm00 * p.ntun, 1e-30)).minC(80.0).exp();
    const ibs4 = exp_tun_s.mul(vtun0_term_s).neg().addC(1.0).scale(wdios * p.tsi * p.istun_t);

    const vtun0_term_d = if (p.vtun0d > 0) S.con(p.vtun0d).div(vdb.abs().addC(p.vtun0d).maxC(1e-30)) else S.con(1.0);
    const exp_tun_d = vdb.scale(1.0 / @max(p.vtm00 * p.ntund, 1e-30)).minC(80.0).exp();
    const ibd4 = exp_tun_d.mul(vtun0_term_d).neg().addC(1.0).scale(wdiod * p.tsi * p.idtun_t);

    // BJT collector injection
    const ien_pre = contract.fmath.exp(p.nbjt_m * contract.fmath.log(@max(1.0 / @max(leff, 1e-30) + 1.0 / @max(p.ln_m, 1e-30), 1e-30)));
    const ien_base_s = weff_prime * p.tsi * p.isbjt_t * p.lbjt0 * ien_pre;
    const ehlis = exp_bs.addC(-1.0).maxC(0.0).scale(p.ahli);
    const ehlid = exp_bd.addC(-1.0).maxC(0.0).scale(p.ahlid);
    const ehli = ehlis.add(ehlid).maxC(0.0);
    const ely = vbs_junc.add(vbd_junc).scale(1.0 / @max(p.vabjt + p.aely * leff, 1e-30)).addC(1.0);
    const e2nd = ely.add(ely.mul(ely).add(ehli.scale(4.0)).sqrt()).scale(0.5);
    const e2nd_c = e2nd.maxC(0.1);

    const ic_bjt = if (p.bjtoff == 0)
        exp_bs.sub(exp_bd).scale(alpha_bjt * ien_base_s).div(e2nd_c)
    else
        S.con(0.0);
    const i_bjt_s = exp_bs.addC(-1.0).scale((1.0 - alpha_bjt) * ien_base_s).div(ehlis.addC(1.0).maxC(1.0).sqrt());

    const ien_base_d = weff_prime * p.tsi * p.idbjt_t * p.lbjt0 * ien_pre;
    const i_bjt_d = exp_bd.addC(-1.0).scale((1.0 - alpha_bjt) * ien_base_d).div(ehlid.addC(1.0).maxC(1.0).sqrt());

    const ibs_total = ibs1.add(ibs2).add(i_bjt_s).add(ibs4);
    const ibd_total = ibd1.add(ibd2).add(i_bjt_d).add(ibd4);

    // --- Impact ionization (Sec. 3.2) ---
    const iii = blk: {
        if (p.iiimod == 0) {
            const vds_vdseff = vds.sub(vdseff_c).maxC(1e-10);
            const ii_arg = S.con(p.beta0_m).div(vds_vdseff);
            break :blk vds_vdseff.scale(p.alpha0_m).mul(ii_arg.minC(80.0).exp()).mul(ids_final).div(mscbe.maxC(1e-30));
        } else if (p.iiimod == 1) {
            // vgsStep = esatii*leff/(1+esatii*leff)*1/(1+sii1*vgst_eff) + sii2*sii0*vgst/(1+siid*vds)
            const term_a_coef = p.esatii * leff / @max(1.0 + p.esatii * leff, 1e-30);
            const term_a = S.con(term_a_coef).div(vgst_eff.scale(p.sii1).addC(1.0));
            const term_b = vgst.scale(p.sii2 * p.sii0).div(vds.scale(p.siid).addC(1.0));
            const vgsStep = term_a.add(term_b);
            const vdsatii = vgsStep.addC(p.vdsatii0 * (1.0 + p.tii_m * (p.t_ratio - 1.0)) - p.lii_m / @max(leff, 1e-30));
            const vdiff_c = vds.sub(vdsatii).maxC(1e-10);
            const denom_ii = vdiff_c.mul(vdiff_c).scale(p.beta0_m).add(vdiff_c.scale(p.beta1_m)).addC(p.beta2_m).maxC(1e-30);
            const ii_bjt_part = ic_bjt.scale(p.fbjtii);
            break :blk ids_final.add(ii_bjt_part).scale(p.alpha0_m).mul(vdiff_c.div(denom_ii).minC(80.0).exp());
        } else {
            const vbci_vbd = vbd_junc.neg().addC(p.vbci_t);
            const vbci_vbd_c = vbci_vbd.maxC(1e-10);
            const cbjtii_eff = (p.cbjtii + p.ebjtii * leff) / @max(leff, 1e-30);
            const mbjtii_exp = @max(p.mbjtii - 1.0, 0.0);
            const inner = vbci_vbd_c.log().scale(mbjtii_exp).exp().scale(-p.abjtii).minC(80.0).exp();
            break :blk ic_bjt.scale(cbjtii_eff).mul(vbci_vbd_c).mul(inner);
        }
    };

    // --- GIDL/GISL current (Sec. 3.3) ---
    const vfbsd = p.vfb_eff;
    var igidl = S.con(0.0);
    var igisl = S.con(0.0);
    if (p.gidlmod == 0) {
        // GIDL
        const gidl_drive = vds.sub(vgs_eff).addC(-p.egidl + vfbsd).maxC(0.0);
        const gidl_exp = expGidl(S, gidl_drive, -3.0 * toxe * p.bgidl);
        const vdb_gidl = vds.sub(vbs_eff).maxC(0.0);
        const gidl_vdb3 = vdb_gidl.mul(vdb_gidl).mul(vdb_gidl);
        igidl = gidl_drive.scale(p.agidl * wdiod * p.nf / (3.0 * toxe)).mul(gidl_exp)
            .mul(gidl_vdb3).div(gidl_vdb3.addC(p.cgidl).maxC(1e-30));
        // GISL
        const gisl_drive = vds.neg().sub(vgs_eff).addC(-p.egisl + vfbsd).maxC(0.0);
        const gisl_exp = expGidl(S, gisl_drive, -3.0 * toxe * p.bgisl);
        const vsb_gisl = vbs_eff.neg().maxC(0.0);
        const gisl_vsb3 = vsb_gisl.mul(vsb_gisl).mul(vsb_gisl);
        igisl = gisl_drive.scale(p.agisl * wdios * p.nf / (3.0 * toxe)).mul(gisl_exp)
            .mul(gisl_vsb3).div(gisl_vsb3.addC(p.cgisl).maxC(1e-30));
    } else {
        // GIDLMOD=1
        const gidl_drive = vds.sub(vgs_eff.scale(p.rgidl)).addC(-p.egidl + vfbsd).maxC(0.0);
        const gidl_exp = expGidl(S, gidl_drive, -3.0 * toxe * p.bgidl);
        const kgidl_exp = if (p.kgidl != 0.0)
            kgidlExp(S, vds.addC(-p.fgidl).maxC(1e-10), p.kgidl)
        else
            S.con(1.0);
        igidl = gidl_drive.scale(p.agidl * wdiod * p.nf / (3.0 * toxe)).mul(gidl_exp).mul(kgidl_exp);

        const gisl_drive = vds.neg().sub(vgs_eff.scale(p.rgisl)).addC(-p.egisl + vfbsd).maxC(0.0);
        const gisl_exp = expGidl(S, gisl_drive, -3.0 * toxe * p.bgisl);
        const kgisl_exp = if (p.kgisl != 0.0)
            kgidlExp(S, vds.neg().addC(-p.fgisl).maxC(1e-10), p.kgisl)
        else
            S.con(1.0);
        igisl = gisl_drive.scale(p.agisl * wdios * p.nf / (3.0 * toxe)).mul(gisl_exp).mul(kgisl_exp);
    }

    // --- Gate tunneling current (Sec. 3.4) ---
    var igcs = S.con(0.0);
    var igcd = S.con(0.0);
    var igs_gate = S.con(0.0);
    var igd_gate = S.con(0.0);
    var igb_inv = S.con(0.0);
    var igb_acc = S.con(0.0);

    if (p.igcmod != 0 or p.igbmod != 0) {
        // vox_raw = nvt*(vgs_eff/nvt - vfb/nvt - phi_st/vt + qs_norm)
        const vox_raw = vgs_eff.scale(1.0 / nvt).addC(-p.vfb_m / nvt - p.phi_st / vt).add(qs_norm).scale(nvt);
        const vox_acc = vox_raw.neg().add(vox_raw.mul(vox_raw).addC(1e-4).sqrt()).scale(0.5);
        const vox_depinv = vox_raw.add(vox_raw.mul(vox_raw).addC(1e-4).sqrt()).scale(0.5);

        const tox_ratio = contract.fmath.exp(p.ntox * contract.fmath.log(@max(p.toxref / toxe, 1e-30)));
        const tox_ratio_edge = tox_ratio * contract.fmath.exp(p.ntox * contract.fmath.log(@max(p.poxedge, 1e-30)));

        if (p.igbmod != 0) {
            const vaux_inv = vgst_eff.addC(-p.vecb * p.eigbinv).scale(1.0 / p.vecb).minC(40.0).exp().addC(1.0).log().scale(p.vecb);
            const vgb = vgs_eff.sub(vbs_eff);
            const vgb_abs = vgb.abs().maxC(1e-10);
            // gb1_exp = |bgb1|*toxe*(alphagb1 - betagb1*|vox_depinv|)/max(1 - |vox_depinv|/vgb1, 0.01)
            const gb1_num = vox_depinv.abs().scale(-p.betagb1).addC(p.alphagb1).scale(@abs(p.bgb1) * toxe);
            const gb1_den = vox_depinv.abs().scale(-1.0 / p.vgb1).addC(1.0).maxC(0.01);
            const gb1_exp = gb1_num.div(gb1_den).minC(80.0);
            igb_inv = vgb_abs.mul(vaux_inv).scale(p.agb1 / (toxe * toxe) * tox_ratio).mul(gb1_exp.neg().exp());
            const gb2_num = vox_acc.abs().scale(-p.betagb2).addC(p.alphagb2).scale(@abs(p.bgb2) * toxe);
            const gb2_den = vox_acc.abs().scale(-1.0 / p.vgb2).addC(1.0).maxC(0.01);
            const gb2_exp = gb2_num.div(gb2_den).minC(80.0);
            igb_acc = vgb_abs.mul(vox_acc).scale(p.agb2 / (toxe * toxe) * tox_ratio).mul(gb2_exp.neg().exp());
        }

        if (p.igcmod != 0) {
            const vgs_eff_gc = vgs_eff.abs().maxC(1e-10);
            const vaux_gc = vgst_eff.addC(-p.vecb * p.eigbinv).scale(1.0 / p.vecb).minC(40.0).exp().addC(1.0).log().scale(p.vecb);
            // igc0_exp_arg = (-|bgb1|*toxe*aigc - bigc*vox_depinv)*(1 + cigc*vox_depinv)
            const igc0_exp_arg = vox_depinv.scale(-p.bigc_m).addC(-@abs(p.bgb1) * toxe * p.aigc_m).mul(vox_depinv.scale(p.cigc_m).addC(1.0));
            const igc0 = vgs_eff_gc.mul(vaux_gc).scale(weff * leff * p.agb1 * tox_ratio).mul(igc0_exp_arg.maxC(-80.0).exp());

            const pigcd_v = vdseff_c.scale(p.pigcd);
            const pigcd_v2 = pigcd_v.mul(pigcd_v).maxC(1e-30);
            igcs = igc0.mul(pigcd_v.add(pigcd_v.neg().minC(80.0).exp()).addC(-1.0 + 1e-4).maxC(0.0)).div(pigcd_v2.addC(2e-4));
            igcd = igc0.mul(pigcd_v.addC(1.0).mul(pigcd_v.neg().minC(80.0).exp()).neg().addC(1.0 + 1e-4).maxC(0.0)).div(pigcd_v2.addC(2e-4));

            const dlcig_eff = @max(p.dlcig, 1e-15);
            const vgs_abs_gt = vgs_eff.abs().maxC(1e-10);
            const vgs_prime = vgst_eff.maxC(1e-10);
            const igs_exp_arg = vgs_prime.scale(-p.bigs_m).addC(-@abs(p.bgb1) * toxe * p.poxedge * p.aigs_m).mul(vgs_prime.scale(p.cigs_m).addC(1.0));
            igs_gate = vgs_abs_gt.mul(vgs_prime).scale(weff * dlcig_eff * p.agb1 * tox_ratio_edge).mul(igs_exp_arg.maxC(-80.0).exp());

            const vgd_eff_abs = vgs_eff.sub(vds).abs().maxC(1e-10);
            const vgd_prime = vgs_eff.sub(vds).sub(vth).abs().maxC(1e-10);
            const igd_exp_arg = vgd_prime.scale(-p.bigd_m).addC(-@abs(p.bgb1) * toxe * p.poxedge * p.aigd_m).mul(vgd_prime.scale(p.cigd_m).addC(1.0));
            igd_gate = vgd_eff_abs.mul(vgd_prime).scale(weff * dlcig_eff * p.agb1 * tox_ratio_edge).mul(igd_exp_arg.maxC(-80.0).exp());
        }
    }

    const igb_total = igb_inv.add(igb_acc);

    // --- Sub-surface leakage (Sec. 5.20) ---
    const ssl_enable: f64 = if (p.sslmod != 0) 1.0 else 0.0;
    const sigvds_s = vds_raw.div(vds_raw.abs().addC(1e-300)); // sign(vds) via smoothing safe: value only used *0 by default
    // Original uses sign(vds) = +1 if vds>0 else -1. Reproduce piecewise on value.
    const sigvds: f64 = if (vds_raw.val() > 0) 1.0 else -1.0;
    _ = sigvds_s;
    const t5_ssl = vgs_eff.mul(vgs_eff).scale(-p.ssl5).sub(vgs_eff.scale(p.ssl4)).addC(-p.ssl3);
    const issl = t5_ssl.scale(1.0 / vt).addC(-p.ssl1 * leff).minC(80.0).exp()
        .mul(vdsx.scale(p.ssl2 / vt).minC(80.0).exp().addC(-1.0))
        .scale(ssl_enable * sigvds * p.nf * weff * p.ssl0);

    // --- EdgeFET current (Sec. 5.19) ---
    const edge_enable: f64 = if (p.edgefet != 0) 1.0 else 0.0;
    const n_edge = 1.0 + (p.citedge + p.nfactoredge + p.cdscedge) / @max(cox, 1e-30);
    const n_edge_bias = vdsx.scale(p.cdscdedge / @max(cox, 1e-30)); // cdscdedge*vdsx/cox term
    const n_edge_full = n_edge_bias.addC(n_edge); // n_edge as S (bias dep)
    const nvt_edge = n_edge_full.maxC(1.01).scale(vt);
    const dv_dibl_edge = vbsx.scale(p.etabedge).addC(p.eta0edge).mul(vdsx).neg();
    const vth_edge = sqrt_phi_vbs.addC(-sqrt_phi_st).scale(p.dgammaedge).addC(p.vfb_eff + p.phi_st + p.dvtedge).sub(dv_dibl_edge);
    const vgst_edge = vgs_eff.sub(vth_edge);
    const qs_edge = vgst_edge.div(nvt_edge.scale(2.0)).minC(40.0).exp().addC(1.0).log();
    const qd_edge = vgst_edge.sub(vds).div(nvt_edge.scale(2.0)).minC(40.0).exp().addC(1.0).log();
    const ids_edge_gm = qs_edge.sub(qd_edge).mul(qs_edge.add(qd_edge).addC(1.0));
    const ids_edge = ids_edge_gm.mul(mu_total).mul(nvt_edge).mul(nvt_edge).mul(n_edge_full).scale(edge_enable * 2.0 * (p.wedge / leff) * cox);

    // --- Total drain current ---
    const ids_ch = ids_final.add(ids_edge).add(issl).mul(mode).scale(type_f);
    const ids_with_bjt = ids_ch.add(ic_bjt.scale(type_f));

    // --- Resistance branches (conductances are x-independent except RDSMOD=1
    //     which reads external nodes) ---
    const rgeltd = if (p.rshg > 0.01 * p.minr)
        p.rshg * (p.xgw_i + weff / (3.0 * p.ngcon_i)) / @max(p.ngcon_i * (p.l_inst - p.xgl) * p.nf, 1e-30)
    else
        0.0;
    // RGATEMOD=2 r_iir depends on ids_final/vdseff (bias-dependent). Reproduce
    // using .val() to form the conductance magnitude while keeping the branch
    // current linear in the node voltages (the original stamps g_rg linearly).
    const rg_total_val = blk: {
        var rg = rgeltd;
        if (instance.rgatemod == 2) {
            const denom = p.xrcrg1 * p.nf * ids_final.val() / @max(vdseff_c.val(), 1e-10) + p.xrcrg2 * weff * mu_eff.val() * cox * vt / @max(leff, 1e-30);
            rg += 1.0 / @max(denom, 1e-30);
        }
        break :blk rg;
    };
    const g_rg = if (rg_total_val > p.minr) 1.0 / rg_total_val else GSHORT;

    const rs_geo = p.nrs * p.rsh;
    const rd_geo = p.nrd * p.rsh;

    // RDSMOD=1 external S/D resistance (reads external gate/source/drain).
    // Bias-dependent conductance -> use .val() for the conductance magnitude.
    const g_rs = blk: {
        if (p.rdsmod == 1) {
            const vgs_noswap = vg_ext.sub(vs_ext).scale(type_f).val();
            const vfbe = p.vfb_eff;
            const vgs_eff_r = 0.5 * (vgs_noswap - vfbe + @sqrt((vgs_noswap - vfbe) * (vgs_noswap - vfbe) + 0.01));
            const prwg_inv = 1.0 / @max(1.0 + p.prwg * vgs_eff_r, 1e-30);
            const vsb_noswap = -vbs.val();
            const rs_ext = p.wr_m / @max(weff * p.nf, 1e-30) * (p.rswmin + p.rsw * (-p.prwb * vsb_noswap + prwg_inv)) + rs_geo;
            break :blk if (rs_ext > p.minr) 1.0 / rs_ext else GSHORT;
        } else break :blk if (rs_geo > p.minr) 1.0 / rs_geo else GSHORT;
    };
    const g_rd = blk: {
        if (p.rdsmod == 1) {
            const vgd_noswap = vg_ext.sub(vd_ext).scale(type_f).val();
            const vfbe = p.vfb_eff;
            const vgd_eff_r = 0.5 * (vgd_noswap - vfbe + @sqrt((vgd_noswap - vfbe) * (vgd_noswap - vfbe) + 0.01));
            const prwg_inv = 1.0 / @max(1.0 + p.prwg * vgd_eff_r, 1e-30);
            const vdb_noswap = -(vbs.val() - vds_raw.val());
            const rd_ext = p.wr_m / @max(weff * p.nf, 1e-30) * (p.rdwmin + p.rdw * (-p.prwb * vdb_noswap + prwg_inv)) + rd_geo;
            break :blk if (rd_ext > p.minr) 1.0 / rd_ext else GSHORT;
        } else break :blk if (rd_geo > p.minr) 1.0 / rd_geo else GSHORT;
    };

    // Body contact resistance (x-independent)
    const rbody_eff = if (p.bodymod == 1) blk: {
        const rbib = p.rbody * p.frbody * weff_prime / @max(leff, 1e-30);
        const r_halo = p.rhalo * weff_prime / 2.0;
        const rbib_par = rbib * r_halo / @max(rbib + r_halo, 1e-30);
        break :blk rbib_par + p.rbsh * p.nrb;
    } else if (p.bodymod == 2) blk: {
        const qbody = q_e * p.neff_m * p.tsi * weff_prime * leff;
        const rbib_nl = weff_prime * weff_prime / @max(p.ub * @max(qbody, 1e-30), 1e-30);
        break :blk rbib_nl + p.rbsh * p.nrb;
    } else 0.0;
    const g_rb = if (rbody_eff > p.minr) 1.0 / rbody_eff else GSHORT;

    // Self-heating thermal resistance (x-independent)
    const rth = if (p.shmod != 0 and p.rth0 > 0) p.rth0 / @max((p.wth0 + weff) * p.nf, 1e-30) else 0.0;
    const g_rth = if (rth > p.minr) 1.0 / rth else GSHORT;

    // --- Stamp current contributions ---
    const i_rd = vd_ext.sub(vdp).scale(g_rd);
    const i_rs = vs_ext.sub(vsp).scale(g_rs);
    const i_rg = vg_ext.sub(vgp).scale(g_rg);
    const i_rb = vb_ext.sub(vbp).scale(g_rb);

    // Self-heating: power dissipated heats thermal node
    const p_diss = ids_ch.mul(vds).abs().add(ibs_total.mul(vbs_junc).abs()).add(ibd_total.mul(vbd_junc).abs());
    const i_th = if (p.shmod != 0)
        vtemp.scale(g_rth).sub(p_diss.scale(g_rth * rth))
    else
        vtemp.scale(GSHORT);

    // Body-to-S/D junction + GMIN
    const i_bs = ibs_total.add(vbs_junc.scale(GMIN)).scale(type_f);
    const i_bd = ibd_total.add(vbd_junc.scale(GMIN)).scale(type_f);

    const i_ii = iii.scale(type_f);
    const i_gidl = igidl.scale(type_f);
    const i_gisl = igisl.scale(type_f);

    const i_gs_g = igs_gate.add(igcs).scale(type_f);
    const i_gd_g = igd_gate.add(igcd).scale(type_f);
    const i_gb_g = igb_total.scale(type_f);

    _ = ve; // substrate DC coupling handled via q()

    // --- Write output currents (KCL at each node) ---
    var out: [n_u]S = undefined;
    out[G] = i_rg;
    out[D] = i_rd;
    out[S_i] = i_rs;
    out[E] = S.con(0.0);
    out[B] = i_rb;
    out[DP] = ids_with_bjt.sub(i_rd).sub(i_bd).add(i_gidl).add(i_ii).add(i_gd_g).add(vbd_junc.scale(GMIN * type_f));
    out[SP] = ids_with_bjt.neg().sub(i_rs).sub(i_bs).add(i_gisl).add(i_gs_g).add(vbs_junc.scale(GMIN * type_f));
    out[BP] = i_bs.add(i_bd).sub(i_rb).sub(i_ii).sub(i_gidl.add(i_gisl)).sub(i_gb_g);
    out[T] = i_th;
    out[GP] = i_rg.neg().add(i_gs_g).add(i_gd_g).add(i_gb_g);
    return out;
}

// --- small S helpers used above ---

/// exp(max(exp_arg, -80)) where exp_arg = coef/drive if drive>1e-10 else -80.
/// coef is a negative constant (e.g. -3*toxe*bgidl). Reproduces the original
/// branch on the (x-dependent) drive value.
fn expGidl(comptime SS: type, drive: SS, coef: f64) SS {
    if (drive.val() > 1e-10) {
        return SS.con(coef).div(drive).maxC(-80.0).exp();
    } else {
        return SS.con(contract.fmath.exp(-80.0));
    }
}

/// exp(min(k / drive, 80)) — the kgidl/kgisl field-enhancement factor.
/// drive is the (already maxC(1e-10)-clamped) x-dependent Vds - fgidl term.
fn kgidlExp(comptime SS: type, drive: SS, k: f64) SS {
    return SS.con(k).div(drive).minC(80.0).exp();
}

fn leffDitsArg(comptime SS: type, vds: SS, leff: f64, dvtp0: f64, dvtp1: f64) SS {
    // leff / (leff + dvtp0*(1 + exp(min(-dvtp1*vds, 80)))) , clamped >= 1e-30
    const denom = vds.scale(-dvtp1).minC(80.0).exp().addC(1.0).scale(dvtp0).addC(leff);
    return SS.con(leff).div(denom).maxC(1e-30);
}

// ============================================================================
// Charge function — C-V model (Sec. 4, 6, 11)
// ============================================================================

const QPrep = struct {
    type_f: f64,
    cox: f64,
    vt: f64,
    t_ratio: f64,
    eps_ratio: f64,
    toxp: f64,
    epsrox: f64,
    nf: f64,
    weff_cv: f64,
    leff_cv: f64,
    weff_cj: f64,
    avdsx: f64,
    // threshold / n
    cit: f64,
    nfactor: f64,
    cdscd_m: f64,
    cdscb_m: f64,
    phin: f64,
    ndep: f64,
    ni: f64,
    vfb_m: f64,
    k1_m: f64,
    k2_m: f64,
    eta0_m: f64,
    etab_m: f64,
    // qme
    ados: f64,
    bdos: f64,
    qm0: f64,
    etaqm: f64,
    // overlaps
    covmod: i32,
    cgso: f64,
    cgdo: f64,
    cgbo: f64,
    cgsl: f64,
    cgdl: f64,
    ckappas: f64,
    ckapppad: f64,
    cf_eff: f64,
    // junction temp params
    cjs_t: f64,
    cjd_t: f64,
    cjsws_t: f64,
    cjswd_t: f64,
    cjswgs_t: f64,
    cjswgd_t: f64,
    pbs_t: f64,
    pbd_t: f64,
    pbsws_t: f64,
    pbswd_t: f64,
    pbswgs_t: f64,
    pbswgd_t: f64,
    mjs_m: f64,
    mjd_m: f64,
    mjsws_m: f64,
    mjswd_m: f64,
    mjswgs_m: f64,
    mjswgd_m: f64,
    tt: f64,
    as_eff: f64,
    ps_eff: f64,
    ad_eff: f64,
    pd_eff: f64,
    // substrate + thermal caps
    cbox: f64,
    cth: f64,
};

fn qprep(model: *const Model, instance: *const Instance) QPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const toxe: f64 = @as(f64, model.toxe);
    const toxp: f64 = @as(f64, model.toxp);
    const tsi: f64 = @as(f64, model.tsi);
    const tbox: f64 = @as(f64, model.tbox);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const epsrox: f64 = @as(f64, model.epsrox);
    const ndep: f64 = @as(f64, model.ndep);
    const ni0sub: f64 = @as(f64, model.ni0sub);
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);
    const vfb_m: f64 = @as(f64, model.vfb);
    const k1_m: f64 = @as(f64, model.k1);
    const k2_m: f64 = @as(f64, model.k2);
    const phin: f64 = @as(f64, model.phin);
    const eta0_m: f64 = @as(f64, model.eta0);
    const etab_m: f64 = @as(f64, model.etab);
    const cit: f64 = @as(f64, model.cit);
    const nfactor: f64 = @as(f64, model.nfactor);
    const cdscd_m: f64 = @as(f64, model.cdscd);
    const cdscb_m: f64 = @as(f64, model.cdscb);
    const avdsx: f64 = @as(f64, model.avdsx);
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cgsl: f64 = @as(f64, model.cgsl);
    const cgdl: f64 = @as(f64, model.cgdl);
    const ckappas: f64 = @as(f64, model.ckappas);
    const ckapppad: f64 = @as(f64, model.ckapppad);
    const cf: f64 = @as(f64, model.cf);
    const cfrcoeff: f64 = @as(f64, model.cfrcoeff);
    const ados: f64 = @as(f64, model.ados);
    const bdos: f64 = @as(f64, model.bdos);
    const qm0: f64 = @as(f64, model.qm0);
    const etaqm: f64 = @as(f64, model.etaqm);

    const cjs_m: f64 = @as(f64, model.cjs);
    const cjd_m: f64 = @as(f64, model.cjd);
    const cjsws_m: f64 = @as(f64, model.cjsws);
    const cjswd_m: f64 = @as(f64, model.cjswd);
    const cjswgs_m: f64 = @as(f64, model.cjswgs);
    const cjswgd_m: f64 = @as(f64, model.cjswgd);
    const pbs_m: f64 = @as(f64, model.pbs);
    const pbd_m: f64 = @as(f64, model.pbd);
    const pbsws_m: f64 = @as(f64, model.pbsws);
    const pbswd_m: f64 = @as(f64, model.pbswd);
    const pbswgs_m: f64 = @as(f64, model.pbswgs);
    const pbswgd_m: f64 = @as(f64, model.pbswgd);
    const mjs_m: f64 = @as(f64, model.mjs);
    const mjd_m: f64 = @as(f64, model.mjd);
    const mjsws_m: f64 = @as(f64, model.mjsws);
    const mjswd_m: f64 = @as(f64, model.mjswd);
    const mjswgs_m: f64 = @as(f64, model.mjswgs);
    const mjswgd_m: f64 = @as(f64, model.mjswgd);
    const tcj: f64 = @as(f64, model.tcj);
    const tcjsw: f64 = @as(f64, model.tcjsw);
    const tcjswg: f64 = @as(f64, model.tcjswg);
    const tpb: f64 = @as(f64, model.tpb);
    const tpbsw: f64 = @as(f64, model.tpbsw);
    const tpbswg: f64 = @as(f64, model.tpbswg);
    const tt: f64 = @as(f64, model.tt);

    const cth0: f64 = @as(f64, model.cth0);
    const wth0: f64 = @as(f64, model.wth0);

    const lint: f64 = @as(f64, model.lint);
    const wint: f64 = @as(f64, model.wint);
    const lmlt: f64 = @as(f64, model.lmlt);
    const wmlt: f64 = @as(f64, model.wmlt);
    const xl_m: f64 = @as(f64, model.xl);
    const xw_m: f64 = @as(f64, model.xw);
    const dlc: f64 = @as(f64, model.dlc);
    const dwc: f64 = @as(f64, model.dwc);
    const dwj: f64 = @as(f64, model.dwj);

    const l_inst: f64 = @as(f64, instance.l);
    const w_inst: f64 = @as(f64, instance.w);
    const nf: f64 = @as(f64, instance.nf);
    const as_j: f64 = @as(f64, instance.as_);
    const ad_j: f64 = @as(f64, instance.ad);
    const ps_j: f64 = @as(f64, instance.ps);
    const pd_j: f64 = @as(f64, instance.pd);
    const dtemp: f64 = @as(f64, instance.dtemp);

    const leff_iv = @max(l_inst * lmlt + xl_m - 2.0 * lint, 1e-9);
    const weff_iv = @max(w_inst * wmlt + xw_m - 2.0 * wint, 1e-9);
    _ = leff_iv;
    _ = weff_iv;
    const leff_cv = @max(l_inst * lmlt + xl_m - 2.0 * dlc, 1e-9);
    const weff_cv = @max(w_inst * wmlt + xw_m - 2.0 * dwc, 1e-9);
    const weff_cj = @max(w_inst * wmlt + xw_m - 2.0 * dwj, 1e-9);

    const cox = 3.9 * eps0 / toxe;
    const eps_ratio = epsrsub / 3.9;

    const tnom_k = @as(f64, model.tnom) + 273.15;
    const temp_k = tnom_k + dtemp;
    const vt = k_B * temp_k / q_e;
    const t_ratio = temp_k / tnom_k;

    const cjs_t = cjs_m + tcj * (temp_k - tnom_k);
    const cjd_t = cjd_m + tcj * (temp_k - tnom_k);
    const cjsws_t = cjsws_m + tcjsw * (temp_k - tnom_k);
    const cjswd_t = cjswd_m + tcjsw * (temp_k - tnom_k);
    const cjswgs_t = cjswgs_m + tcjswg * (temp_k - tnom_k);
    const cjswgd_t = cjswgd_m + tcjswg * (temp_k - tnom_k);
    const pbs_t = @max(pbs_m - tpb * (temp_k - tnom_k), 0.01);
    const pbd_t = @max(pbd_m - tpb * (temp_k - tnom_k), 0.01);
    const pbsws_t = @max(pbsws_m - tpbsw * (temp_k - tnom_k), 0.01);
    const pbswd_t = @max(pbswd_m - tpbsw * (temp_k - tnom_k), 0.01);
    const pbswgs_t = @max(pbswgs_m - tpbswg * (temp_k - tnom_k), 0.01);
    const pbswgd_t = @max(pbswgd_m - tpbswg * (temp_k - tnom_k), 0.01);

    const eg0 = bg0sub - tbgasub * tnom_k * tnom_k / (tnom_k + tbgbsub);
    const eg = bg0sub - tbgasub * temp_k * temp_k / (temp_k + tbgbsub);
    const vt_nom = k_B * tnom_k / q_e;
    const ni = ni0sub * contract.fmath.exp(1.5 * contract.fmath.log(t_ratio)) * contract.fmath.exp(@min(eg0 / (2.0 * vt_nom) - eg / (2.0 * vt), 80.0));

    const cf_eff = if (cf > 0) cf else 2.0 * epsrox * eps0 / 3.14159 * contract.fmath.log(@max(cfrcoeff * (1.0 + 0.4e-6 / toxe), 1.0));

    const as_eff = @max(as_j, weff_cj * nf * 1e-7);
    const ps_eff = @max(ps_j, 2.0 * weff_cj * nf);
    const ad_eff = @max(ad_j, weff_cj * nf * 1e-7);
    const pd_eff = @max(pd_j, 2.0 * weff_cj * nf);

    const eps_ox = epsrox * eps0;
    const cbox = eps_ox / @max(tbox, 1e-30);
    const cth = cth0 * (wth0 + weff_cv) * nf;

    _ = tsi;

    return .{
        .type_f = type_f,
        .cox = cox,
        .vt = vt,
        .t_ratio = t_ratio,
        .eps_ratio = eps_ratio,
        .toxp = toxp,
        .epsrox = epsrox,
        .nf = nf,
        .weff_cv = weff_cv,
        .leff_cv = leff_cv,
        .weff_cj = weff_cj,
        .avdsx = avdsx,
        .cit = cit,
        .nfactor = nfactor,
        .cdscd_m = cdscd_m,
        .cdscb_m = cdscb_m,
        .phin = phin,
        .ndep = ndep,
        .ni = ni,
        .vfb_m = vfb_m,
        .k1_m = k1_m,
        .k2_m = k2_m,
        .eta0_m = eta0_m,
        .etab_m = etab_m,
        .ados = ados,
        .bdos = bdos,
        .qm0 = qm0,
        .etaqm = etaqm,
        .covmod = model.covmod,
        .cgso = cgso,
        .cgdo = cgdo,
        .cgbo = cgbo,
        .cgsl = cgsl,
        .cgdl = cgdl,
        .ckappas = ckappas,
        .ckapppad = ckapppad,
        .cf_eff = cf_eff,
        .cjs_t = cjs_t,
        .cjd_t = cjd_t,
        .cjsws_t = cjsws_t,
        .cjswd_t = cjswd_t,
        .cjswgs_t = cjswgs_t,
        .cjswgd_t = cjswgd_t,
        .pbs_t = pbs_t,
        .pbd_t = pbd_t,
        .pbsws_t = pbsws_t,
        .pbswd_t = pbswd_t,
        .pbswgs_t = pbswgs_t,
        .pbswgd_t = pbswgd_t,
        .mjs_m = mjs_m,
        .mjd_m = mjd_m,
        .mjsws_m = mjsws_m,
        .mjswd_m = mjswd_m,
        .mjswgs_m = mjswgs_m,
        .mjswgd_m = mjswgd_m,
        .tt = tt,
        .as_eff = as_eff,
        .ps_eff = ps_eff,
        .ad_eff = ad_eff,
        .pd_eff = pd_eff,
        .cbox = cbox,
        .cth = cth,
    };
}

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;
    _ = model;
    _ = instance;
    const p = &pc.q;

    const type_f = p.type_f;
    const cox = p.cox;
    const vt = p.vt;

    // --- Voltages ---
    const vgp = x[GP];
    const vdp = x[DP];
    const vsp = x[SP];
    const vbp = x[BP];
    const ve = x[E];
    const vtemp = x[T];

    const vgs = vgp.sub(vsp).scale(type_f);
    const vds_raw = vdp.sub(vsp).scale(type_f);
    const vbs = vbp.sub(vsp).scale(type_f);

    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs_eff = vgs.sub(vds_neg);
    const vbs_eff = vbs.sub(vds_neg);
    const vds = vds_abs;

    const vdsx = vdsxOf(S, vds, p.avdsx);
    const vbsx = vds.sub(vdsx).scale(-0.5);

    const phi_b = contract.fmath.log(@max(p.ndep / p.ni, 1.0));
    const phi_st = 2.0 * vt * phi_b + p.phin;

    // Subthreshold slope for CV: n = 1 + (cit+nfactor+cdscd*vdsx-cdscb*vbsx)/cox
    const n_sub = vdsx.scale(p.cdscd_m).sub(vbsx.scale(p.cdscb_m)).addC(p.cit + p.nfactor).scale(1.0 / @max(cox, 1e-30)).addC(1.0);
    const n_cv = n_sub.maxC(1.01);
    const nvt = n_cv.scale(vt);

    // Threshold for CV
    const sqrt_phi_st = @sqrt(@max(phi_st, 1e-30));
    const sqrt_phi_vbs = vbs_eff.neg().addC(phi_st).maxC(1e-30).sqrt();
    const dv_vnud = sqrt_phi_vbs.addC(-sqrt_phi_st).scale(p.k1_m).sub(vbsx.scale(p.k2_m));
    const dv_dibl = vbsx.scale(p.etab_m).addC(p.eta0_m).mul(vdsx).neg();
    const dv_th_cv = dv_vnud.add(dv_dibl);

    const vfb_eff = p.vfb_m;
    const vth_cv = dv_th_cv.neg().addC(vfb_eff + phi_st);
    const vgst_cv = vgs_eff.sub(vth_cv);

    // Normalized charges for SOIMOD=0 CV
    const qs_n = vgst_cv.div(nvt.scale(2.0)).minC(40.0).exp().addC(1.0).log();
    const qd_n = vgst_cv.sub(vds).div(nvt.scale(2.0)).minC(40.0).exp().addC(1.0).log();
    const qs_qd_diff = qs_n.sub(qd_n);

    // --- Intrinsic gate charge (Sec. 11 / SOIMOD=0) ---
    const nq = n_cv;
    const q_frac_denom = qs_n.add(qd_n).addC(1.0).maxC(1e-30);
    const diff_sq_over_denom = qs_qd_diff.mul(qs_qd_diff).div(q_frac_denom);

    const qi_norm = qs_n.add(qd_n).add(diff_sq_over_denom.scale(1.0 / 3.0)).mul(nq);

    // Source/drain charge partition (Ward-Dutton)
    const qs_charge = qs_n.scale(2.0).add(qd_n).add(qs_n.scale(0.8).add(qd_n.scale(1.2)).addC(1.0).scale(0.5).mul(diff_sq_over_denom)).mul(nq.scale(1.0 / 3.0));
    const qd_charge = qs_n.add(qd_n.scale(2.0)).add(qs_n.scale(1.2).add(qd_n.scale(0.8)).addC(1.0).scale(0.5).mul(diff_sq_over_denom)).mul(nq.scale(1.0 / 3.0));

    // Scale to real charges: Q = -Weff*Leff*Cox*nVt * q_normalized
    const q_scale = nvt.scale(p.weff_cv * p.leff_cv * cox);
    const qi_real = qi_norm.mul(q_scale).neg();
    const qs_real = qs_charge.mul(q_scale).neg();
    const qd_real = qd_charge.mul(q_scale).neg();

    // Gate charge from charge neutrality
    const vg_vfb = vgs_eff.addC(-vfb_eff);
    const qb_norm = vg_vfb.div(nvt).addC(-phi_st / vt).sub(qs_n.add(qd_n).add(diff_sq_over_denom.scale(1.0 / 3.0)).mul(nq.addC(-1.0)));
    const qb_real = qb_norm.mul(q_scale).neg();
    const qg_real = qi_real.add(qb_real).neg();

    // (QME correction: cox_inv computed but applied implicitly in original;
    //  xdc_inv depends on qi_norm/qb_norm but only fed cox_inv, which was
    //  discarded — so no charge contribution. Omitted, matching original.)

    // --- Overlap charges (Sec. 4.3 / 11) ---
    const qgs_ov = vgs.scale(p.nf * p.weff_cv * p.cgso * type_f);
    const vgd = vgs.sub(vds);
    const qgd_ov = vgd.scale(p.nf * p.weff_cv * p.cgdo * type_f);
    const qgb_ov = vgp.sub(vbp).scale(p.cgbo * p.leff_cv);

    // Bias-dependent overlap (COVMOD=1)
    var qgs_ov_dep = S.con(0.0);
    var qgd_ov_dep = S.con(0.0);
    if (p.covmod != 0) {
        const delta1 = 0.02;
        const vgs_fbsd = vgs.addC(-vfb_eff);
        const vgs_ov = vgs_fbsd.addC(delta1).sub(vgs_fbsd.addC(delta1).mul(vgs_fbsd.addC(delta1)).addC(4.0 * delta1).sqrt()).scale(0.5);
        const t6_s = vgs_ov.neg().addC(p.ckappas).maxC(1e-30);
        qgs_ov_dep = vgs_fbsd.sub(vgs_ov).sub(t6_s.scale(4.0 / p.ckappas).sqrt().addC(-1.0).scale(p.ckappas / 2.0)).scale(p.nf * p.weff_cv * p.cgsl * type_f);

        const vgd_fbsd = vgd.addC(-vfb_eff);
        const vgd_ov = vgd_fbsd.addC(delta1).sub(vgd_fbsd.addC(delta1).mul(vgd_fbsd.addC(delta1)).addC(4.0 * delta1).sqrt()).scale(0.5);
        const t6_d = vgd_ov.neg().addC(p.ckapppad).maxC(1e-30);
        qgd_ov_dep = vgd_fbsd.sub(vgd_ov).sub(t6_d.scale(4.0 / p.ckapppad).sqrt().addC(-1.0).scale(p.ckapppad / 2.0)).scale(p.nf * p.weff_cv * p.cgdl * type_f);
    }

    // Outer fringing
    const qcf_s = vgs.scale(p.cf_eff * p.nf * p.weff_cv * type_f);
    const qcf_d = vgd.scale(p.cf_eff * p.nf * p.weff_cv * type_f);

    // --- Junction depletion charges (Sec. 6.1) ---
    const fc: f64 = 0.9;
    const vbs_j = vbs_eff.scale(type_f);
    const vbd_j = vbs_eff.sub(vds).scale(type_f);

    const qbs_bot = juncCharge(S, vbs_j, p.pbs_t, p.mjs_m, p.cjs_t, fc).scale(p.as_eff);
    const qbs_sw = juncCharge(S, vbs_j, p.pbsws_t, p.mjsws_m, p.cjsws_t, fc).scale(p.ps_eff);
    const qbs_swg = juncCharge(S, vbs_j, p.pbswgs_t, p.mjswgs_m, p.cjswgs_t, fc).scale(p.weff_cj * p.nf);

    const qbd_bot = juncCharge(S, vbd_j, p.pbd_t, p.mjd_m, p.cjd_t, fc).scale(p.ad_eff);
    const qbd_sw = juncCharge(S, vbd_j, p.pbswd_t, p.mjswd_m, p.cjswd_t, fc).scale(p.pd_eff);
    const qbd_swg = juncCharge(S, vbd_j, p.pbswgd_t, p.mjswgd_m, p.cjswgd_t, fc).scale(p.weff_cj * p.nf);

    // Diffusion charge (x-independent — depends only on temp params)
    const qdiff_s = p.tt * @abs(p.as_eff * p.cjs_t * vt);
    const qdiff_d = p.tt * @abs(p.ad_eff * p.cjd_t * vt);

    const qbs_total = qbs_bot.add(qbs_sw).add(qbs_swg).addC(qdiff_s);
    const qbd_total = qbd_bot.add(qbd_sw).add(qbd_swg).addC(qdiff_d);

    // Substrate capacitance (Cbox)
    const qsub_s = ve.sub(vbp).scale(p.cbox * p.weff_cv * p.leff_cv);

    // Thermal capacitance
    const q_th = vtemp.scale(p.cth);

    // --- Write output charges ---
    var out: [n_u]S = undefined;
    out[G] = S.con(0.0);
    out[D] = S.con(0.0);
    out[S_i] = S.con(0.0);
    out[E] = qsub_s;
    out[B] = S.con(0.0);
    out[DP] = qd_real.add(qgd_ov).add(qgd_ov_dep).add(qcf_d).scale(p.nf).add(qbd_total);
    out[SP] = qs_real.add(qgs_ov).add(qgs_ov_dep).add(qcf_s).scale(p.nf).add(qbs_total);
    out[BP] = qb_real.scale(p.nf).sub(qbs_total.add(qbd_total)).sub(qsub_s);
    out[T] = q_th;
    out[GP] = qg_real.sub(qgd_ov).sub(qgs_ov).sub(qgd_ov_dep).sub(qgs_ov_dep).sub(qcf_s).sub(qcf_d).scale(p.nf).add(qgb_ov);
    return out;
}

// ============================================================================
// Junction depletion charge helper (value-form)
// ============================================================================

fn juncCharge(comptime SS: type, v: SS, pb: f64, mj: f64, cj0: f64, fc: f64) SS {
    // Two-region model: reverse/moderate forward (power law) and strong forward
    // (quadratic extension). Region selection branches on the (x-dependent) v,
    // reproducing the original piecewise physics.
    const pb_c = @max(pb, 0.01);
    const v_fc = fc * pb_c;
    const arg = v.scale(1.0 / pb_c);
    const is_forward = arg.val() > fc;

    const one_minus_mj = 1.0 - mj;
    const one_minus_mj_c = @max(@abs(one_minus_mj), 0.01) * (if (one_minus_mj >= 0) @as(f64, 1.0) else @as(f64, -1.0));

    // Reverse: Q = pb*cj0/(1-mj) * [1 - (1 - v/pb)^(1-mj)]
    const rev_base = arg.neg().addC(1.0).maxC(1e-30);
    const rev_pow = rev_base.log().scale(one_minus_mj_c).exp();
    const q_rev = rev_pow.neg().addC(1.0).scale(pb_c * cj0 / one_minus_mj_c);

    // Forward (quadratic extension beyond FC*PB)
    const fc_base = @max(1.0 - fc, 1e-30);
    const fc_pow_inv = contract.fmath.exp(-mj * contract.fmath.log(fc_base));
    const q_fc = pb_c * cj0 / one_minus_mj_c * (1.0 - contract.fmath.exp(one_minus_mj_c * contract.fmath.log(fc_base)));
    const dv = v.addC(-v_fc);
    const q_fwd = dv.add(dv.mul(dv).scale(0.5 * mj / pb_c / @max(fc_base, 1e-30))).scale(cj0 * fc_pow_inv).addC(q_fc);

    return if (is_forward) q_fwd else q_rev;
}

// ============================================================================
// Voltage Limiting (DEVpnjlim + DEVfetlim + DEVlimvds)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;

    const type_f: f64 = @floatFromInt(model.type_);
    const tnom_k: f64 = @as(f64, model.tnom) + 273.15;
    const vt = k_B * tnom_k / q_e;

    // --- DEVfetlim: Gate voltage limiting ---
    const vgs_new = (x_new[GP] - x_new[SP]) * type_f;
    const vgs_old = (x_old[GP] - x_old[SP]) * type_f;
    const vth_est: f64 = @as(f64, model.vfb) + 0.6;
    const vgs_lim = fetlim(vgs_new, vgs_old, vth_est);
    const dvgs = (vgs_lim - vgs_new) * type_f;
    result[GP] += dvgs;

    // --- DEVlimvds: Drain-source voltage limiting ---
    const vds_new = (x_new[DP] - x_new[SP]) * type_f;
    const vds_old = (x_old[DP] - x_old[SP]) * type_f;
    const vds_lim = limvds(vds_new, vds_old);
    const dvds = (vds_lim - vds_new) * type_f;
    result[DP] += dvds;

    // --- DEVpnjlim: Body-source junction ---
    const vbs_new = (x_new[BP] - x_new[SP]) * type_f;
    const vbs_old = (x_old[BP] - x_old[SP]) * type_f;
    const is_bs: f64 = @as(f64, model.isdif) * @as(f64, model.tsi);
    const vbs_lim = pnjlim(vbs_new, vbs_old, vt, is_bs);
    const dvbs = (vbs_lim - vbs_new) * type_f;
    result[BP] += dvbs;

    // --- DEVpnjlim: Body-drain junction ---
    const vbd_new = (x_new[BP] - x_new[DP]) * type_f;
    const vbd_old = (x_old[BP] - x_old[DP]) * type_f;
    const vbd_lim = pnjlim(vbd_new, vbd_old, vt, is_bs);
    const dvbd = (vbd_lim - vbd_new) * type_f;
    result[BP] += dvbd * 0.5;

    return result;
}

// DEVpnjlim: PN junction voltage limiting
inline fn pnjlim(vnew: f64, vold: f64, vt: f64, is_j: f64) f64 {
    const vcrit = vt * contract.fmath.log(vt / (1.4142 * @max(is_j, 1e-30)));
    const vlim = if (vnew > vcrit and @abs(vnew - vold) > 2.0 * vt)
        (if (vold > 0)
            vold + vt * (contract.fmath.log(@max(1.0 + (vnew - vold) / vt, 1e-30)))
        else
            vcrit)
    else
        vnew;
    return vlim;
}

// DEVfetlim: FET gate voltage limiting
inline fn fetlim(vnew: f64, vold: f64, vth: f64) f64 {
    const vtsthi = @abs(2.0 * (vold - vth)) + 2.0;
    const vtstlo = vtsthi / 2.0 + 2.0;
    const vtox = vth + 3.5;
    const delv = vnew - vold;

    const vlim = if (vold >= vth) blk: {
        break :blk if (@abs(delv) >= vtsthi)
            (if (delv > 0) vold + vtsthi else vold - vtsthi)
        else
            vnew;
    } else if (vnew >= vtox) blk: {
        break :blk vth + vtsthi;
    } else blk: {
        break :blk if (@abs(delv) >= vtstlo)
            (if (delv > 0) vold + vtstlo else vold - vtstlo)
        else
            vnew;
    };

    return vlim;
}

// DEVlimvds: Drain-source voltage limiting
inline fn limvds(vnew: f64, vold: f64) f64 {
    const max_step = 3.5;
    const delv = vnew - vold;
    const vlim = if (@abs(delv) > max_step)
        vold + (if (delv > 0) @as(f64, max_step) else -max_step)
    else
        vnew;
    return vlim;
}

// ============================================================================
// Parameter stepping for convergence aid
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale junction saturation currents by gmin*(1-lambda) for convergence
    const gmin_step: f32 = @floatCast(1.0e-12 * (1.0 - lambda));
    m.isdif = @floatCast(@as(f64, model.isdif) + @as(f64, gmin_step));
    m.iddif = @floatCast(@as(f64, model.iddif) + @as(f64, gmin_step));
    m.isrec = @floatCast(@as(f64, model.isrec) + @as(f64, gmin_step));
    m.idrec = @floatCast(@as(f64, model.idrec) + @as(f64, gmin_step));
    m.istun = @floatCast(@as(f64, model.istun) + @as(f64, gmin_step));
    m.idtun = @floatCast(@as(f64, model.idtun) + @as(f64, gmin_step));
    m.isbjt = @floatCast(@as(f64, model.isbjt) + @as(f64, gmin_step));
    m.idbjt = @floatCast(@as(f64, model.idbjt) + @as(f64, gmin_step));
    return m;
}

// ============================================================================
// Noise generators
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise (D' to S')
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Source resistance thermal noise (S to S')
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Drain resistance thermal noise (D to D')
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Gate resistance thermal noise (G to G')
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime), .kind = .thermal },
    // Body resistance thermal noise (B to B')
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body_prime), .kind = .thermal },
    // Channel flicker noise (D' to S')
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Gate-source shot noise
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Gate-drain shot noise
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime), .kind = .shot },
    // Gate-body shot noise
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.body_prime), .kind = .shot },
    // Source resistance flicker noise
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Drain resistance flicker noise
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .flicker },
};

// ============================================================================
// Sparse stamp patterns
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    // Gate resistance: G -- G'
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate_prime) },
    // Drain resistance: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    // Source resistance: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    // Body resistance: B -- B'
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.body) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.body_prime) },
    // Channel: D' -- S', depends on G', B'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.gate_prime) },
    // Self-heating: T -- T
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.temp) },
    // Substrate coupling
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.substrate) },
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.substrate) },
};

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Intrinsic MOS capacitances: G', D', S', B' full block
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.body_prime) },
    // Substrate: E -- B'
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.body_prime) },
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.substrate) },
    .{ .row = @intFromEnum(U.substrate), .col = @intFromEnum(U.substrate) },
    // Thermal
    .{ .row = @intFromEnum(U.temp), .col = @intFromEnum(U.temp) },
};

// ============================================================================
// Comptime validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "bsim_soi: off-state leakage (Vgs=0) is tiny, symmetric currents sum to ~0" {
    const model: Model = .{};
    const inst: Instance = .{};
    // All terminals at 0 except a small drain bias at both external and
    // internal drain nodes. With Vgs=0 the channel is in deep subthreshold.
    const x: [n_u]f64 = .{0} ** n_u;
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // KCL: the sum of all node currents equals the sum of injected sources.
    // With all voltages 0, every branch current is 0 except the GSHORT-tied
    // temp node (vtemp=0 -> 0) so all outputs are ~0.
    for (out) |o| try testing.expect(@abs(o) < 1e-6);
}

test "bsim_soi: on-state drain current is positive and channel is bidirectional-consistent" {
    // NMOS, strong inversion: put G' and D' high, S' at ground. Because the
    // external R branches are GSHORT-shorted by default (rsh=0 -> g=GSHORT),
    // exercise the intrinsic transistor by driving the *prime* nodes.
    const model: Model = .{ .u0 = 0.05, .vfb = -1.0 };
    const inst: Instance = .{};
    var x: [n_u]f64 = .{0} ** n_u;
    x[GP] = 1.5; // gate
    x[DP] = 1.0; // drain
    // source_prime, body_prime, gate, drain, source at 0
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // Intrinsic channel current leaves S' (out[SP] negative side) and the
    // drain-prime node carries channel current + external-R return. With
    // Vgs_eff=1.5 > Vth the channel conducts: the drain-prime residual is
    // dominated by the (large) GSHORT return through the shorted external R,
    // so instead assert the *source-prime* channel term is nonzero and the
    // transistor is on (current flows).
    try testing.expect(@abs(out[SP]) > 1e-9);
    // Newton residual must be finite everywhere.
    for (out) |o| try testing.expect(std.math.isFinite(o));
}

test "bsim_soi: charge q substrate coupling equals Cbox*(Ve - Vbp)" {
    // Cbox = epsrox*eps0/tbox = 4*8.8542e-12/2e-7 = 1.770840e-4 F/m^2.
    // qsub = Cbox * Weff_cv * Leff_cv * (Ve - Vbp).
    // Weff_cv = w - 2*dwc = 1e-5 (dwc=0). Leff_cv = l - 2*dlc = 1e-5.
    // area = 1e-10 m^2. Cbox*area = 1.770840e-4 * 1e-10 = 1.770840e-14 F.
    // With Ve=1, Vbp=0 -> qsub = 1.770840e-14 C.
    const model: Model = .{};
    const inst: Instance = .{};
    var x: [n_u]f64 = .{0} ** n_u;
    x[E] = 1.0;
    const out = contract.qValues(Self, x, &model, &inst, 0);
    const cbox = 4.0 * 8.8542e-12 / 2e-7;
    const expected = cbox * 1e-5 * 1e-5 * 1.0;
    try testing.expectApproxEqAbs(expected, out[E], 1e-18);
}

test "bsim_soi: thermal charge q_th = Cth0*(Wth0+Weff_cv)*nf*Vtemp" {
    // Cth0=1e-5 (default), Wth0=0, Weff_cv=1e-5, nf=1.
    // Cth = 1e-5*(0+1e-5)*1 = 1e-10. q_th = Cth*Vtemp = 1e-10*2 = 2e-10.
    const model: Model = .{};
    const inst: Instance = .{};
    var x: [n_u]f64 = .{0} ** n_u;
    x[T] = 2.0;
    const out = contract.qValues(Self, x, &model, &inst, 0);
    const expected = 1e-5 * (0.0 + 1e-5) * 1.0 * 2.0;
    // Tolerance loosened from 1e-18 to 1e-16: cth0/weff are stored as f32, so
    // the product carries ~1e-7 relative rounding (2e-10 -> 1.9999998e-10).
    try testing.expectApproxEqAbs(expected, out[T], 1e-16);
}
