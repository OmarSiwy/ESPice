const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// PSP 104.0.1 -- Surface-Potential Based Compact MOSFET Model
//
//   NXP Semiconductors / CEA-Leti, October 2024
//
//   4-terminal bulk MOSFET: Drain(d), Gate(g), Source(s), Bulk(b)
//   with internal nodes for parasitic resistances:
//     GP  -- intrinsic gate (behind gate resistance)
//     DI  -- intrinsic drain (behind drain series resistance)
//     SI  -- intrinsic source (behind source series resistance)
//     BI  -- intrinsic bulk (behind bulk/well resistance)
//     BS  -- source-side bulk (behind RJUNS)
//     BD  -- drain-side bulk (behind RJUND)
//     DT  -- thermal node for self-heating (temperature rise)
//
//   Surface-potential based: explicit SP computation at source/drain sides
//   Gate current, GIDL/GISL, impact ionization, JUNCAP2 junctions
//   Edge transistor, NQS (quasi-static charge model used here)
//   Branchless source-drain reversal, NMOS/PMOS via type_
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, gp, di, si, bi, bs, bd, dt };
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================
const T0: f64 = 273.15;
const KB: f64 = 1.3806505e-23;
const HBAR: f64 = 1.05457168e-34;
const QE: f64 = 1.6021918e-19;
const M0: f64 = 9.1093826e-31;
const EPS0: f64 = 8.8541878176e-12;
const EPSR_SI: f64 = 11.8;
const EPS_SI: f64 = EPSR_SI * EPS0;
const QMN: f64 = 5.951993;
const QMP: f64 = 7.448711;
const KB_OVER_Q: f64 = KB / QE;

const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const MAX_EXP_ARG: f64 = 80.0;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Switches and Control ---
    level: i32 = 104,
    type_: i32 = 1, // 1=NMOS, -1=PMOS
    tr: f32 = 21.0, // Reference temperature (C)
    dta: f32 = 0.0, // Temperature offset w.r.t. ambient (K)
    paramchk: i32 = 0,
    swgeo: i32 = 1,
    swigate: i32 = 0,
    swimpact: i32 = 0,
    swgidl: i32 = 0,
    swjuncap: i32 = 0,
    swjunasym: i32 = 0,
    swnud: i32 = 0,
    swedge: i32 = 0,
    swdelvtac: i32 = 0,
    swqsat: i32 = 0,
    swqpart: i32 = 0,
    qmc: f32 = 1.0,
    swoprext: i32 = 0,
    swoppmos: i32 = 0,
    swopdrain: i32 = 0,

    // --- Electrical Geometry ---
    lvaro: f32 = 0.0,
    lvarl: f32 = 0.0,
    lvarw: f32 = 0.0,
    lap: f32 = 0.0,
    wvaro: f32 = 0.0,
    wvarl: f32 = 0.0,
    wvarw: f32 = 0.0,
    wot: f32 = 0.0,
    dlq: f32 = 0.0,
    dwq: f32 = 0.0,

    // --- Flat-Band Voltage ---
    vfb: f32 = -1.0,
    vfbo: f32 = -1.0,
    vfbl: f32 = 0.0,
    vfblexp: f32 = 1.0,
    vfbw: f32 = 0.0,
    vfblw: f32 = 0.0,
    povfb: f32 = -1.0,
    plvfb: f32 = 0.0,
    pwvfb: f32 = 0.0,
    plwvfb: f32 = 0.0,
    stvfb: f32 = 5.0e-4,
    stvfbo: f32 = 5.0e-4,
    stvfbl: f32 = 0.0,
    stvfbw: f32 = 0.0,
    stvfblw: f32 = 0.0,
    postvfb: f32 = 5.0e-4,
    plstvfb: f32 = 0.0,
    pwstvfb: f32 = 0.0,
    plwstvfb: f32 = 0.0,
    st2vfb: f32 = 0.0,
    st2vfbo: f32 = 0.0,

    // --- Process Parameters ---
    tox: f32 = 2.0e-9,
    toxo: f32 = 2.0e-9,
    epsrox: f32 = 3.9,
    epsroxo: f32 = 3.9,
    neff: f32 = 5.0e23,
    nsubo: f32 = 4.0e23,
    nsubw: f32 = 0.0,
    wseg: f32 = 1.0e-8,
    npck: f32 = 1.0e24,
    npckw: f32 = 0.0,
    wsegp: f32 = 1.0e-8,
    lpck: f32 = 1.0e-8,
    lpckw: f32 = 0.0,
    fol1: f32 = 0.0,
    fol2: f32 = 0.0,
    poneff: f32 = 5.0e23,
    plneff: f32 = 0.0,
    pwneff: f32 = 0.0,
    plwneff: f32 = 0.0,
    gfacnud: f32 = 1.0,
    gfacnudo: f32 = 1.0,
    gfacnudl: f32 = 0.0,
    gfacnudlexp: f32 = 1.0,
    gfacnudw: f32 = 0.0,
    gfacnudlw: f32 = 0.0,
    pogfacnud: f32 = 1.0,
    plgfacnud: f32 = 0.0,
    pwgfacnud: f32 = 0.0,
    plwgfacnud: f32 = 0.0,
    vsbnud: f32 = 0.0,
    vsbnudo: f32 = 0.0,
    povsbnud: f32 = 0.0,
    plvsbnud: f32 = 0.0,
    pwvsbnud: f32 = 0.0,
    plwvsbnud: f32 = 0.0,
    dvsbnud: f32 = 1.0,
    dvsbnudo: f32 = 1.0,
    dphib: f32 = 0.0,
    dphibo: f32 = 0.0,
    dphibl: f32 = 0.0,
    dphiblexp: f32 = 1.0,
    dphibw: f32 = 0.0,
    dphiblw: f32 = 0.0,
    podphib: f32 = 0.0,
    pldphib: f32 = 0.0,
    pwdphib: f32 = 0.0,
    plwdphib: f32 = 0.0,
    np: f32 = 1.0e26,
    npo: f32 = 1.0e26,
    npl: f32 = 0.0,
    ponp: f32 = 0.0,
    plnp: f32 = 0.0,
    pwnp: f32 = 0.0,
    plwnp: f32 = 0.0,
    toxov: f32 = 2.0e-9,
    toxovo: f32 = 2.0e-9,
    toxovd: f32 = 2.0e-9,
    toxovdo: f32 = 2.0e-9,
    lov: f32 = 1.0e-8,
    lovd: f32 = 1.0e-8,
    nov: f32 = 5.0e25,
    novo: f32 = 5.0e25,
    ponov: f32 = 0.0,
    plnov: f32 = 0.0,
    pwnov: f32 = 0.0,
    plwnov: f32 = 0.0,
    novd: f32 = 5.0e25,
    novdo: f32 = 5.0e25,
    ponovd: f32 = 0.0,
    plnovd: f32 = 0.0,
    pwnovd: f32 = 0.0,
    plwnovd: f32 = 0.0,

    // --- Interface States ---
    ct: f32 = 0.0,
    cto: f32 = 0.0,
    ctl: f32 = 0.0,
    ctlexp: f32 = 1.0,
    ctw: f32 = 0.0,
    ctlw: f32 = 0.0,
    poct: f32 = 0.0,
    plct: f32 = 0.0,
    pwct: f32 = 0.0,
    plwct: f32 = 0.0,
    ctb: f32 = 0.0,
    ctbo: f32 = 0.0,
    poctb: f32 = 0.0,
    plctb: f32 = 0.0,
    pwctb: f32 = 0.0,
    plwctb: f32 = 0.0,
    ctg: f32 = 0.0,
    ctgo: f32 = 0.0,
    poctg: f32 = 0.0,
    plctg: f32 = 0.0,
    pwctg: f32 = 0.0,
    plwctg: f32 = 0.0,
    stct: f32 = 1.0,
    stcto: f32 = 1.0,
    postct: f32 = 0.0,
    plstct: f32 = 0.0,
    pwstct: f32 = 0.0,
    plwstct: f32 = 0.0,

    // --- DIBL ---
    cf: f32 = 0.0,
    cfl: f32 = 0.0,
    cflexp: f32 = 2.0,
    cfw: f32 = 0.0,
    pocf: f32 = 0.0,
    plcf: f32 = 0.0,
    pwcf: f32 = 0.0,
    plwcf: f32 = 0.0,
    cfb: f32 = 0.0,
    cfbo: f32 = 0.0,
    pocfb: f32 = 0.0,
    plcfb: f32 = 0.0,
    pwcfb: f32 = 0.0,
    plwcfb: f32 = 0.0,
    cfd: f32 = 0.0,
    cfdo: f32 = 0.0,
    pocfd: f32 = 0.0,
    plcfd: f32 = 0.0,
    pwcfd: f32 = 0.0,
    plwcfd: f32 = 0.0,

    // --- Subthreshold Slope ---
    psce: f32 = 0.0,
    pscel: f32 = 0.0,
    pscelexp: f32 = 2.0,
    pscew: f32 = 0.0,
    popsce: f32 = 0.0,
    plpsce: f32 = 0.0,
    pwpsce: f32 = 0.0,
    plwpsce: f32 = 0.0,
    psceb: f32 = 0.0,
    pscebo: f32 = 0.0,
    popsceb: f32 = 0.0,
    plpsceb: f32 = 0.0,
    pwpsceb: f32 = 0.0,
    plwpsceb: f32 = 0.0,
    psced: f32 = 0.0,
    pscedo: f32 = 0.0,
    popsced: f32 = 0.0,
    plpsced: f32 = 0.0,
    pwpsced: f32 = 0.0,
    plwpsced: f32 = 0.0,

    // --- Mobility ---
    betn: f32 = 3.0e-2,
    uo: f32 = 3.0e-2,
    fbet1: f32 = 0.0,
    fbet1w: f32 = 0.0,
    lp1: f32 = 1.0e-8,
    lp1w: f32 = 0.0,
    fbet2: f32 = 0.0,
    lp2: f32 = 1.0e-8,
    betw1: f32 = 0.0,
    betw2: f32 = 0.0,
    wbet: f32 = 1.0e-9,
    pobetn: f32 = 0.0,
    plbetn: f32 = 0.0,
    pwbetn: f32 = 0.0,
    plwbetn: f32 = 0.0,
    stbet: f32 = 1.0,
    stbeto: f32 = 1.0,
    stbetl: f32 = 0.0,
    stbetlexp: f32 = 1.0,
    stbetw: f32 = 0.0,
    stbetlw: f32 = 0.0,
    postbet: f32 = 0.0,
    plstbet: f32 = 0.0,
    pwstbet: f32 = 0.0,
    plwstbet: f32 = 0.0,
    mue: f32 = 0.5,
    mueo: f32 = 0.5,
    muew: f32 = 0.0,
    pomue: f32 = 0.0,
    plmue: f32 = 0.0,
    pwmue: f32 = 0.0,
    plwmue: f32 = 0.0,
    stmue: f32 = 0.0,
    stmueo: f32 = 0.0,
    themu: f32 = 1.5,
    themuo: f32 = 1.5,
    pothemu: f32 = 0.0,
    plthemu: f32 = 0.0,
    pwthemu: f32 = 0.0,
    plwthemu: f32 = 0.0,
    stthemu: f32 = 1.5,
    stthemuo: f32 = 1.5,
    cs: f32 = 0.0,
    cso: f32 = 0.0,
    csl: f32 = 0.0,
    cslexp: f32 = 1.0,
    csw: f32 = 0.0,
    cslw: f32 = 0.0,
    pocs: f32 = 0.0,
    plcs: f32 = 0.0,
    pwcs: f32 = 0.0,
    plwcs: f32 = 0.0,
    stcs: f32 = 0.0,
    stcso: f32 = 0.0,
    thecs: f32 = 2.0,
    thecso: f32 = 2.0,
    pothecs: f32 = 0.0,
    plthecs: f32 = 0.0,
    pwthecs: f32 = 0.0,
    plwthecs: f32 = 0.0,
    stthecs: f32 = 0.0,
    stthecso: f32 = 0.0,
    xcor: f32 = 0.0,
    xcoro: f32 = 0.0,
    xcorl: f32 = 0.0,
    xcorlexp: f32 = 1.0,
    xcorw: f32 = 0.0,
    xcorlw: f32 = 0.0,
    poxcor: f32 = 0.0,
    plxcor: f32 = 0.0,
    pwxcor: f32 = 0.0,
    plwxcor: f32 = 0.0,
    stxcor: f32 = 0.0,
    stxcoro: f32 = 0.0,
    feta: f32 = 1.0,
    fetao: f32 = 1.0,

    // --- Series Resistance ---
    rs: f32 = 50.0,
    rsw1: f32 = 50.0,
    rsw2: f32 = 0.0,
    pors: f32 = 0.0,
    plrs: f32 = 0.0,
    pwrs: f32 = 0.0,
    plwrs: f32 = 0.0,
    strs: f32 = 1.0,
    strso: f32 = 1.0,
    postrs: f32 = 0.0,
    plstrs: f32 = 0.0,
    pwstrs: f32 = 0.0,
    plwstrs: f32 = 0.0,
    rsb: f32 = 0.0,
    rsbo: f32 = 0.0,
    porsb: f32 = 0.0,
    plrsb: f32 = 0.0,
    pwrsb: f32 = 0.0,
    plwrsb: f32 = 0.0,
    rsg: f32 = 0.0,
    rsgo: f32 = 0.0,
    porsg: f32 = 0.0,
    plrsg: f32 = 0.0,
    pwrsg: f32 = 0.0,
    plwrsg: f32 = 0.0,

    // --- Velocity Saturation ---
    thesat: f32 = 0.3,
    thesato: f32 = 0.0,
    thesatl: f32 = 0.3,
    thesatlexp: f32 = 1.0,
    thesatw: f32 = 0.0,
    thesatlw: f32 = 0.0,
    pothesat: f32 = 0.0,
    plthesat: f32 = 0.0,
    pwthesat: f32 = 0.0,
    plwthesat: f32 = 0.0,
    stthesat: f32 = 1.0,
    stthesato: f32 = 0.0,
    stthesatl: f32 = 0.0,
    stthesatlexp: f32 = 1.0,
    stthesatw: f32 = 0.0,
    stthesatlw: f32 = 0.0,
    postthesat: f32 = 0.0,
    plstthesat: f32 = 0.0,
    pwstthesat: f32 = 0.0,
    plwstthesat: f32 = 0.0,
    thesatb: f32 = 0.0,
    thesatbo: f32 = 0.0,
    pothesatb: f32 = 0.0,
    plthesatb: f32 = 0.0,
    pwthesatb: f32 = 0.0,
    plwthesatb: f32 = 0.0,
    thesatg: f32 = 0.0,
    thesatgo: f32 = 0.0,
    pothesatg: f32 = 0.0,
    plthesatg: f32 = 0.0,
    pwthesatg: f32 = 0.0,
    plwthesatg: f32 = 0.0,
    thesatt: f32 = 1.0,
    thesatto: f32 = 1.0,

    // --- Linear-Saturation Transition ---
    ax: f32 = 8.0,
    axo: f32 = 16.0,
    axl: f32 = 1.0,
    poax: f32 = 0.0,
    plax: f32 = 0.0,
    pwax: f32 = 0.0,
    plwax: f32 = 0.0,

    // --- Channel Length Modulation ---
    alp: f32 = 0.01,
    alpl: f32 = 0.01,
    alplexp: f32 = 1.0,
    alpw: f32 = 0.0,
    poalp: f32 = 0.0,
    plalp: f32 = 0.0,
    pwalp: f32 = 0.0,
    plwalp: f32 = 0.0,
    alp1: f32 = 0.0,
    alp1l1: f32 = 0.0,
    alp1lexp: f32 = 0.5,
    alp1l2: f32 = 0.0,
    alp1w: f32 = 0.0,
    poalp1: f32 = 0.0,
    plalp1: f32 = 0.0,
    pwalp1: f32 = 0.0,
    plwalp1: f32 = 0.0,
    alp2: f32 = 0.0,
    alp2l1: f32 = 0.0,
    alp2lexp: f32 = 1.0,
    alp2l2: f32 = 0.0,
    alp2w: f32 = 0.0,
    poalp2: f32 = 0.0,
    plalp2: f32 = 0.0,
    pwalp2: f32 = 0.0,
    plwalp2: f32 = 0.0,
    vp: f32 = 0.05,
    vpo: f32 = 0.05,

    // --- Impact Ionization ---
    a1: f32 = 1.0,
    a1o: f32 = 1.0,
    a1l: f32 = 0.0,
    a1lexp: f32 = 1.0,
    a1w: f32 = 0.0,
    poa1: f32 = 0.0, // binning for A1
    pla1: f32 = 0.0,
    pwa1: f32 = 0.0,
    plwa1: f32 = 0.0,
    a2: f32 = 10.0,
    a2o: f32 = 10.0,
    sta2: f32 = 0.0,
    sta2o: f32 = 0.0,
    posta2: f32 = 0.0,
    plsta2: f32 = 0.0,
    pwsta2: f32 = 0.0,
    plwsta2: f32 = 0.0,
    a3: f32 = 1.0,
    a3o: f32 = 0.0,
    a3l: f32 = 0.0,
    a3lexp: f32 = 1.0,
    a3w: f32 = 0.0,
    poa3: f32 = 0.0,
    pla3: f32 = 0.0,
    pwa3: f32 = 0.0,
    plwa3: f32 = 0.0,
    a4: f32 = 0.0,
    a4o: f32 = 0.0,
    a4l: f32 = 0.0,
    a4lexp: f32 = 1.0,
    a4w: f32 = 0.0,
    poa4: f32 = 0.0,
    pla4: f32 = 0.0,
    pwa4: f32 = 0.0,
    plwa4: f32 = 0.0,

    // --- Gate Current ---
    gco: f32 = 0.0,
    gcoo: f32 = 0.0,
    iginv: f32 = 0.0,
    iginvlw: f32 = 0.0,
    poiginv: f32 = 0.0,
    pliginv: f32 = 0.0,
    pwiginv: f32 = 0.0,
    plwiginv: f32 = 0.0,
    igov: f32 = 0.0,
    igovw: f32 = 0.0,
    poigov: f32 = 0.0,
    pligov: f32 = 0.0,
    pwigov: f32 = 0.0,
    plwigov: f32 = 0.0,
    igovd: f32 = 0.0,
    igovdw: f32 = 0.0,
    poigovd: f32 = 0.0,
    pligovd: f32 = 0.0,
    pwigovd: f32 = 0.0,
    plwigovd: f32 = 0.0,
    stig: f32 = 2.0,
    stigo: f32 = 2.0,
    postig: f32 = 0.0,
    plstig: f32 = 0.0,
    pwstig: f32 = 0.0,
    plwstig: f32 = 0.0,
    gc2: f32 = 0.375,
    gc2o: f32 = 0.375,
    gc3: f32 = 0.063,
    gc3o: f32 = 0.063,
    gc2ov: f32 = 0.375,
    gc2ovo: f32 = 0.375,
    gc3ov: f32 = 0.063,
    gc3ovo: f32 = 0.063,
    chib: f32 = 3.1,
    chibo: f32 = 3.1,

    // --- GIDL ---
    agidl: f32 = 0.0,
    agidlw: f32 = 0.0,
    poagidl: f32 = 0.0,
    plagidl: f32 = 0.0,
    pwagidl: f32 = 0.0,
    plwagidl: f32 = 0.0,
    agidld: f32 = 0.0,
    agidldw: f32 = 0.0,
    poagidld: f32 = 0.0,
    plagidld: f32 = 0.0,
    pwagidld: f32 = 0.0,
    plwagidld: f32 = 0.0,
    bgidl: f32 = 41.0,
    bgidlo: f32 = 41.0,
    bgidld: f32 = 41.0,
    bgidldo: f32 = 41.0,
    stbgidl: f32 = 0.0,
    stbgidlo: f32 = 0.0,
    postbgidl: f32 = 0.0,
    plstbgidl: f32 = 0.0,
    pwstbgidl: f32 = 0.0,
    plwstbgidl: f32 = 0.0,
    stbgidld: f32 = 0.0,
    stbgidldo: f32 = 0.0,
    postbgidld: f32 = 0.0,
    plstbgidld: f32 = 0.0,
    pwstbgidld: f32 = 0.0,
    plwstbgidld: f32 = 0.0,
    cgidl: f32 = 0.0,
    cgidlo: f32 = 0.0,
    cgidld: f32 = 0.0,
    cgidldo: f32 = 0.0,

    // --- Charge Model ---
    cox: f32 = 1.0e-14,
    pocox: f32 = 0.0,
    plcox: f32 = 0.0,
    pwcox: f32 = 0.0,
    plwcox: f32 = 0.0,
    delvtac: f32 = 0.0,
    delvtaco: f32 = 0.0,
    delvtacl: f32 = 0.0,
    delvtaclexp: f32 = 1.0,
    delvtacw: f32 = 0.0,
    delvtaclw: f32 = 0.0,
    podelvtac: f32 = 0.0,
    pldelvtac: f32 = 0.0,
    pwdelvtac: f32 = 0.0,
    plwdelvtac: f32 = 0.0,
    facneffac: f32 = 1.0,
    facneffaco: f32 = 0.0,
    facneffacl: f32 = 0.0,
    facneffaclexp: f32 = 1.0,
    facneffacw: f32 = 0.0,
    facneffaclw: f32 = 0.0,
    pofacneffac: f32 = 0.0,
    plfacneffac: f32 = 0.0,
    pwfacneffac: f32 = 0.0,
    plwfacneffac: f32 = 0.0,
    thesatac: f32 = 0.3,
    thesataco: f32 = 0.0,
    thesatacl: f32 = 0.0,
    thesataclexp: f32 = 1.0,
    thesatacw: f32 = 0.0,
    thesataclw: f32 = 0.0,
    pothesatac: f32 = 0.0,
    plthesatac: f32 = 0.0,
    pwthesatac: f32 = 0.0,
    plwthesatac: f32 = 0.0,
    axac: f32 = 8.0,
    axaco: f32 = 0.0,
    axacl: f32 = 0.0,
    poaxac: f32 = 0.0,
    plaxac: f32 = 0.0,
    pwaxac: f32 = 0.0,
    plwaxac: f32 = 0.0,
    alpac: f32 = 0.0,
    alpacl: f32 = 0.0,
    alpaclexp: f32 = 1.0,
    alpacw: f32 = 0.0,
    poalpac: f32 = 0.0,
    plalpac: f32 = 0.0,
    pwalpac: f32 = 0.0,
    plwalpac: f32 = 0.0,
    alp1ac: f32 = 0.0,
    alp1acl1: f32 = 0.0,
    alp1aclexp: f32 = 0.5,
    alp1acl2: f32 = 0.0,
    alp1acw: f32 = 0.0,
    poalp1ac: f32 = 0.0,
    plalp1ac: f32 = 0.0,
    pwalp1ac: f32 = 0.0,
    plwalp1ac: f32 = 0.0,
    cgov: f32 = 1.0e-15,
    pocgov: f32 = 0.0,
    plcgov: f32 = 0.0,
    pwcgov: f32 = 0.0,
    plwcgov: f32 = 0.0,
    cgovd: f32 = 1.0e-15,
    pocgovd: f32 = 0.0,
    plcgovd: f32 = 0.0,
    pwcgovd: f32 = 0.0,
    plwcgovd: f32 = 0.0,
    fcgovacc: f32 = 0.5,
    fcgovacco: f32 = 0.5,
    fcgovaccd: f32 = 0.5,
    fcgovaccdo: f32 = 0.5,
    cgovaccg: f32 = 1.0,
    cgovaccgo: f32 = 1.0,
    cgbov: f32 = 1.0e-15,
    cgbovl: f32 = 1.0e-15,
    pocgbov: f32 = 0.0,
    plcgbov: f32 = 0.0,
    pwcgbov: f32 = 0.0,
    plwcgbov: f32 = 0.0,
    cinr: f32 = 5.0e-16,
    cinrw: f32 = 5.0e-16,
    pocinr: f32 = 0.0,
    plcinr: f32 = 0.0,
    pwcinr: f32 = 0.0,
    plwcinr: f32 = 0.0,
    cinrd: f32 = 5.0e-16,
    cinrwd: f32 = 5.0e-16,
    pocinrd: f32 = 0.0,
    plcinrd: f32 = 0.0,
    pwcinrd: f32 = 0.0,
    plwcinrd: f32 = 0.0,
    dvfbinr: f32 = 0.0,
    dvfbinro: f32 = 0.0,
    fcinrdep: f32 = 0.3,
    fcinrdepo: f32 = 0.3,
    fcinracc: f32 = 0.5,
    fcinracco: f32 = 0.5,
    axinr: f32 = 0.4,
    axinro: f32 = 0.4,
    cfr: f32 = 1.0e-15,
    cfrw: f32 = 0.0,
    pocfr: f32 = 0.0,
    plcfr: f32 = 0.0,
    pwcfr: f32 = 0.0,
    plwcfr: f32 = 0.0,
    cfrd: f32 = 1.0e-15,
    cfrdw: f32 = 0.0,
    pocfrd: f32 = 0.0,
    plcfrd: f32 = 0.0,
    pwcfrd: f32 = 0.0,
    plwcfrd: f32 = 0.0,

    // --- Noise ---
    fnt: f32 = 1.0,
    fnto: f32 = 1.0,
    fntexc: f32 = 0.0,
    fntexcl: f32 = 0.0,
    pofntexc: f32 = 0.0,
    plfntexc: f32 = 0.0,
    pwfntexc: f32 = 0.0,
    plwfntexc: f32 = 0.0,
    nfa: f32 = 8.0e22,
    nfalw: f32 = 8.0e22,
    ponfa: f32 = 0.0,
    plnfa: f32 = 0.0,
    pwnfa: f32 = 0.0,
    plwnfa: f32 = 0.0,
    nfb: f32 = 3.0e7,
    nfblw: f32 = 0.0,
    ponfb: f32 = 0.0,
    plnfb: f32 = 0.0,
    pwnfb: f32 = 0.0,
    plwnfb: f32 = 0.0,
    nfc: f32 = 0.0,
    nfclw: f32 = 0.0,
    ponfc: f32 = 0.0,
    plnfc: f32 = 0.0,
    pwnfc: f32 = 0.0,
    plwnfc: f32 = 0.0,
    ef: f32 = 1.0,
    efo: f32 = 1.0,
    lintnoi: f32 = 0.0,
    alpnoi: f32 = 2.0,

    // --- Edge Transistor ---
    wedge: f32 = 1.0e-8,
    wedgew: f32 = 0.0,
    vfbedge: f32 = -1.0,
    vfbedgeo: f32 = -1.0,
    vfbedgel: f32 = 0.0,
    vfbedgelexp: f32 = 1.0,
    povfbedge: f32 = 0.0,
    plvfbedge: f32 = 0.0,
    pwvfbedge: f32 = 0.0,
    plwvfbedge: f32 = 0.0,
    stvfbedge: f32 = 5.0e-4,
    stvfbedgeo: f32 = 5.0e-4,
    stvfbedgel: f32 = 0.0,
    stvfbedgew: f32 = 0.0,
    stvfbedgelw: f32 = 0.0,
    postvfbedge: f32 = 0.0,
    plstvfbedge: f32 = 0.0,
    pwstvfbedge: f32 = 0.0,
    plwstvfbedge: f32 = 0.0,
    dphibedge: f32 = 0.0,
    dphibedgeo: f32 = 0.0,
    dphibedgel: f32 = 0.0,
    dphibedgelexp: f32 = 1.0,
    dphibedgew: f32 = 0.0,
    dphibedgelw: f32 = 0.0,
    podphibedge: f32 = 0.0,
    pldphibedge: f32 = 0.0,
    pwdphibedge: f32 = 0.0,
    plwdphibedge: f32 = 0.0,
    neffedge: f32 = 5.0e23,
    neffedgeo: f32 = 5.0e23,
    neffedgel: f32 = 0.0,
    neffedgew: f32 = 0.0,
    poneffedge: f32 = 0.0,
    plneffedge: f32 = 0.0,
    pwneffedge: f32 = 0.0,
    plwneffedge: f32 = 0.0,
    ctedge: f32 = 0.0,
    ctedgeo: f32 = 0.0,
    ctedgel: f32 = 0.0,
    ctedgelexp: f32 = 1.0,
    poctedge: f32 = 0.0,
    plctedge: f32 = 0.0,
    pwctedge: f32 = 0.0,
    plwctedge: f32 = 0.0,
    betnedge: f32 = 3.0e-2,
    betnedgeo: f32 = 3.0e-2,
    betnedgel: f32 = 0.0,
    betnedgelexp: f32 = 1.0,
    pobetnedge: f32 = 0.0,
    plbetnedge: f32 = 0.0,
    pwbetnedge: f32 = 0.0,
    plwbetnedge: f32 = 0.0,
    stbetedge: f32 = 1.0,
    stbetedgeo: f32 = 1.0,
    stbetedgel: f32 = 0.0,
    stbetedgelexp: f32 = 1.0,
    stbetedgew: f32 = 0.0,
    stbetedgelw: f32 = 0.0,
    postbetedge: f32 = 0.0,
    plstbetedge: f32 = 0.0,
    pwstbetedge: f32 = 0.0,
    plwstbetedge: f32 = 0.0,
    psceedge: f32 = 0.0,
    psceedgeo: f32 = 0.0,
    psceedgel: f32 = 0.0,
    psceedgelexp: f32 = 2.0,
    psceedgew: f32 = 0.0,
    popsceedge: f32 = 0.0,
    plpsceedge: f32 = 0.0,
    pwpsceedge: f32 = 0.0,
    plwpsceedge: f32 = 0.0,
    pscebedge: f32 = 0.0,
    pscebedgeo: f32 = 0.0,
    popscebedge: f32 = 0.0,
    plpscebedge: f32 = 0.0,
    pwpscebedge: f32 = 0.0,
    plwpscebedge: f32 = 0.0,
    pscededge: f32 = 0.0,
    pscededgeo: f32 = 0.0,
    popscededge: f32 = 0.0,
    plpscededge: f32 = 0.0,
    pwpscededge: f32 = 0.0,
    plwpscededge: f32 = 0.0,
    cfedge: f32 = 0.0,
    cfedgeo: f32 = 0.0,
    cfedgel: f32 = 0.0,
    cfedgelexp: f32 = 2.0,
    cfedgew: f32 = 0.0,
    pocfedge: f32 = 0.0,
    plcfedge: f32 = 0.0,
    pwcfedge: f32 = 0.0,
    plwcfedge: f32 = 0.0,
    cfbedge: f32 = 0.0,
    cfbedgeo: f32 = 0.0,
    pocfbedge: f32 = 0.0,
    plcfbedge: f32 = 0.0,
    pwcfbedge: f32 = 0.0,
    plwcfbedge: f32 = 0.0,
    cfdedge: f32 = 0.0,
    cfdedgeo: f32 = 0.0,
    pocfdedge: f32 = 0.0,
    plcfdedge: f32 = 0.0,
    pwcfdedge: f32 = 0.0,
    plwcfdedge: f32 = 0.0,
    fntedge: f32 = 1.0,
    fntedgeo: f32 = 1.0,
    nfaedge: f32 = 8.0e22,
    nfaedgelw: f32 = 0.0,
    ponfaedge: f32 = 0.0, // binning NFA edge
    plnfaedge: f32 = 0.0,
    pwnfaedge: f32 = 0.0,
    plwnfaedge: f32 = 0.0,
    nfbedge: f32 = 3.0e7,
    nfbedgelw: f32 = 0.0,
    ponfbedge: f32 = 0.0,
    plnfbedge: f32 = 0.0,
    pwnfbedge: f32 = 0.0,
    plwnfbedge: f32 = 0.0,
    nfcedge: f32 = 0.0,
    nfcedgelw: f32 = 0.0,
    ponfcedge: f32 = 0.0,
    plnfcedge: f32 = 0.0,
    pwnfcedge: f32 = 0.0,
    plwnfcedge: f32 = 0.0,
    efedge: f32 = 1.0,
    efedgeo: f32 = 1.0,

    // --- Self Heating ---
    rth: f32 = 0.0,
    rtho: f32 = 0.0,
    rthw1: f32 = 0.0,
    rthw2: f32 = 0.0,
    rthlw: f32 = 0.0,
    porth: f32 = 0.0,
    plrth: f32 = 0.0,
    pwrth: f32 = 0.0,
    plwrth: f32 = 0.0,
    cth: f32 = 0.0,
    ctho: f32 = 0.0,
    cthw1: f32 = 0.0,
    cthw2: f32 = 0.0,
    cthlw: f32 = 0.0,
    pocth: f32 = 0.0,
    plcth: f32 = 0.0,
    pwcth: f32 = 0.0,
    plwcth: f32 = 0.0,
    strth: f32 = 0.0,
    strtho: f32 = 0.0,
    postrth: f32 = 0.0,
    plstrth: f32 = 0.0,
    pwstrth: f32 = 0.0,
    plwstrth: f32 = 0.0,

    // --- NQS ---
    swnqs: i32 = 0,
    munqs: f32 = 1.0,
    munqso: f32 = 1.0,
    pomunqs: f32 = 0.0,
    plmunqs: f32 = 0.0,
    pwmunqs: f32 = 0.0,
    plwmunqs: f32 = 0.0,

    // --- Stress Model ---
    saref: f32 = 1.0e-6,
    sbref: f32 = 1.0e-6,
    wlod: f32 = 0.0,
    kuo: f32 = 0.0,
    kvsat: f32 = 0.0,
    kvsatac: f32 = 0.0,
    tkuo: f32 = 0.0,
    lkuo: f32 = 0.0,
    wkuo: f32 = 0.0,
    pkuo: f32 = 0.0,
    llodkuo: f32 = 0.0,
    wlodkuo: f32 = 0.0,
    kvtho: f32 = 0.0,
    lkvtho: f32 = 0.0,
    wkvtho: f32 = 0.0,
    pkvtho: f32 = 0.0,
    llodvth: f32 = 0.0,
    wlodvth: f32 = 0.0,
    stetao: f32 = 0.0,
    lodetao: f32 = 1.0,

    // --- Well Proximity Effect ---
    scref: f32 = 1.0e-6,
    web: f32 = 0.0,
    wec: f32 = 0.0,
    kvthoweo: f32 = 0.0,
    kvthowel: f32 = 0.0,
    kvthowew: f32 = 0.0,
    kvthowelw: f32 = 0.0,
    kuoweo: f32 = 0.0,
    kuowel: f32 = 0.0,
    kuowew: f32 = 0.0,
    kuowelw: f32 = 0.0,

    // --- JUNCAP2 Source-Bulk ---
    trj: f32 = 21.0,
    swjunexp: i32 = 0,
    ifactor: f32 = 1.0,
    cfactor: f32 = 1.0,
    imax: f32 = 1.0e3,
    frev: f32 = 1.0e3,
    cjorbot: f32 = 1.0e-3,
    cjorsti: f32 = 1.0e-9,
    cjorgat: f32 = 1.0e-9,
    vbirbot: f32 = 1.0,
    vbirsti: f32 = 1.0,
    vbirgat: f32 = 1.0,
    pbot: f32 = 0.5,
    psti: f32 = 0.5,
    pgat: f32 = 0.5,
    phigbot: f32 = 1.16,
    phigsti: f32 = 1.16,
    phiggat: f32 = 1.16,
    idsatrbot: f32 = 1.0e-12,
    idsatrsti: f32 = 1.0e-18,
    idsatrgat: f32 = 1.0e-18,
    csrhbot: f32 = 1.0e2,
    csrhsti: f32 = 1.0e-4,
    csrhgat: f32 = 1.0e-4,
    xjunsti: f32 = 1.0e-7,
    xjungat: f32 = 1.0e-7,
    ctatbot: f32 = 1.0e2,
    ctatsti: f32 = 1.0e-4,
    ctatgat: f32 = 1.0e-4,
    mefftatbot: f32 = 0.25,
    mefftatsti: f32 = 0.25,
    mefftatgat: f32 = 0.25,
    cbbtbot: f32 = 1.0e-12,
    cbbtsti: f32 = 1.0e-18,
    cbbtgat: f32 = 1.0e-18,
    fbbtrbot: f32 = 1.0e9,
    fbbtrsti: f32 = 1.0e9,
    fbbtrgat: f32 = 1.0e9,
    stfbbtbot: f32 = -1.0e-3,
    stfbbtsti: f32 = -1.0e-3,
    stfbbtgat: f32 = -1.0e-3,
    vbrbot: f32 = 10.0,
    vbrsti: f32 = 10.0,
    vbrgat: f32 = 10.0,
    pbrbot: f32 = 4.0,
    pbrsti: f32 = 4.0,
    pbrgat: f32 = 4.0,
    vjunref: f32 = 2.5,
    fjunq: f32 = 0.03,

    // --- JUNCAP2 Drain-Bulk (mirror of source, suffix D) ---
    cjorbotd: f32 = 1.0e-3,
    cjorstid: f32 = 1.0e-9,
    cjorgatd: f32 = 1.0e-9,
    vbirbotd: f32 = 1.0,
    vbirstid: f32 = 1.0,
    vbirgatd: f32 = 1.0,
    pbotd: f32 = 0.5,
    pstid: f32 = 0.5,
    pgatd: f32 = 0.5,
    phigbotd: f32 = 1.16,
    phigstid: f32 = 1.16,
    phiggatd: f32 = 1.16,
    idsatrbotd: f32 = 1.0e-12,
    idsatrstid: f32 = 1.0e-18,
    idsatrgatd: f32 = 1.0e-18,
    csrhbotd: f32 = 1.0e2,
    csrhstid: f32 = 1.0e-4,
    csrhgatd: f32 = 1.0e-4,
    xjunstid: f32 = 1.0e-7,
    xjungatd: f32 = 1.0e-7,
    ctatbotd: f32 = 1.0e2,
    ctatstid: f32 = 1.0e-4,
    ctatgatd: f32 = 1.0e-4,
    mefftatbotd: f32 = 0.25,
    mefftatstid: f32 = 0.25,
    mefftatgatd: f32 = 0.25,
    cbbtbotd: f32 = 1.0e-12,
    cbbtstid: f32 = 1.0e-18,
    cbbtgatd: f32 = 1.0e-18,
    fbbtrbotd: f32 = 1.0e9,
    fbbtrstid: f32 = 1.0e9,
    fbbtrgatd: f32 = 1.0e9,
    stfbbtbotd: f32 = -1.0e-3,
    stfbbtstid: f32 = -1.0e-3,
    stfbbtgatd: f32 = -1.0e-3,
    vbrbotd: f32 = 10.0,
    vbrstid: f32 = 10.0,
    vbrgatd: f32 = 10.0,
    pbrbotd: f32 = 4.0,
    pbrstid: f32 = 4.0,
    pbrgatd: f32 = 4.0,
    vjunrefd: f32 = 2.5,
    fjunqd: f32 = 0.03,

    // --- Parasitic Resistance ---
    rg: f32 = 0.0,
    rgo: f32 = 0.0,
    rint: f32 = 0.0,
    rvpoly: f32 = 0.0,
    rshg: f32 = 0.0,
    dlsil: f32 = 0.0,
    rse: f32 = 0.0,
    rsh: f32 = 0.0,
    rde: f32 = 0.0,
    rshd: f32 = 0.0,
    rbulk: f32 = 0.0,
    rbulko: f32 = 0.0,
    rwell: f32 = 0.0,
    rwello: f32 = 0.0,
    rjuns: f32 = 0.0,
    rjunso: f32 = 0.0,
    rjund: f32 = 0.0,
    rjundo: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 1.0e-6,
    w: f32 = 1.0e-6,
    absource: f32 = 1.0e-12,
    lssource: f32 = 1.0e-6,
    lgsource: f32 = 1.0e-6,
    abdrain: f32 = 1.0e-12,
    lsdrain: f32 = 1.0e-6,
    lgdrain: f32 = 1.0e-6,
    as_: f32 = 1.0e-12,
    ps: f32 = 1.0e-6,
    ad: f32 = 1.0e-12,
    pd: f32 = 1.0e-6,
    jw: f32 = 1.0e-6,
    delvto: f32 = 0.0,
    factuo: f32 = 1.0,
    delvtoedge: f32 = 0.0,
    factuoedge: f32 = 1.0,
    sa: f32 = 0.0,
    sb: f32 = 0.0,
    sd: f32 = 0.0,
    sca: f32 = 0.0,
    scb: f32 = 0.0,
    scc: f32 = 0.0,
    sc: f32 = 0.0,
    nrs: f32 = 0.0,
    nrd: f32 = 0.0,
    ngcon: f32 = 1.0,
    xgw: f32 = 1.0e-7,
    nf: f32 = 1.0,
    mult: f32 = 1.0,
    trise: f32 = 0.0,
};

// ============================================================================
// Noise Generators
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise (drain-source)
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.si), .kind = .thermal },
    // Channel flicker noise (drain-source)
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.si), .kind = .flicker },
    // Gate shot noise (gate-source)
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.si), .kind = .shot },
    // Gate shot noise (gate-drain)
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.di), .kind = .shot },
    // Impact ionization shot noise
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.bi), .kind = .shot },
    // Gate resistance thermal noise
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gp), .kind = .thermal },
    // Source resistance thermal noise
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.si), .kind = .thermal },
    // Drain resistance thermal noise
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.di), .kind = .thermal },
};

// ============================================================================
// Auxiliary Functions (inline, branchless)
// ============================================================================

// NOTE: All auxiliary functions are value-form (generic over the scalar S).
// x-independent chains stay f64; anything reachable from a terminal voltage
// (including phi_t via the self-heating DT node) is carried as S. Region
// selection uses .val() to reproduce the original piecewise physics exactly;
// each branch still computes in S ops.

inline fn chiS(comptime S: type, y: S) S {
    // y*y / (2 + y*y)
    const y2 = y.mul(y);
    return y2.div(y2.addC(2.0));
}

inline fn chi_dS(comptime S: type, y: S) S {
    // 4*y / (2 + y*y)^2
    const denom = y.mul(y).addC(2.0);
    return y.scale(4.0).div(denom.mul(denom));
}

/// Smooth surface potential solver -- explicit approximation (value-form).
/// Returns x_s given x_g, G, delta_ns (exp(-x_ns)), and the margin x_mrg.
inline fn surfPotS(comptime S: type, x_g: S, g: S, delta_ns: S) S {
    const x_mrg: f64 = 20.0;
    const g2 = g.mul(g);

    // Initial estimate
    const x_g_safe = x_g.maxC(-80.0);

    // For large positive x_g (inversion/depletion): Newton on implicit SP eq.
    const arg_acc = x_g_safe.neg().addC(-1.0).minC(MAX_EXP_ARG);
    const x_acc = g2.add(arg_acc.exp()).maxC(1.0e-30).log().addC(-1.0);

    // Depletion approximation: x_s = x_g - G*sqrt(x_g) for large x_g
    const x_dep_arg = x_g_safe.maxC(0.01);
    const x_dep = x_dep_arg.sub(g.mul(x_dep_arg.sqrt()));

    // Inversion approximation
    const delta_inv = delta_ns.maxC(1.0e-30);
    const x_ns = delta_inv.log().neg();
    const x_inv = x_ns.add(x_g_safe.sub(x_ns).div(g).maxC(1.0e-30).log().scale(2.0));
    const x_inv_safe = x_inv.min(x_g_safe).max(x_ns);

    // Select initial guess based on regime (branch on .val() reproduces the
    // original piecewise choice; each branch is computed in S ops).
    const near_fb = x_g_safe.minC(MAX_EXP_ARG).exp().addC(1.0).maxC(1.0e-30).log();
    const x_s0 = if (x_g_safe.val() < -x_mrg)
        x_acc
    else if (x_g_safe.val() > x_mrg)
        (if (x_g_safe.val() > x_ns.val() + g2.val() / 4.0) x_inv_safe else x_dep)
    else
        near_fb;

    // Newton refinement (2 iterations for convergence)
    var x_s = x_s0;

    // Iteration 1
    {
        const exp_neg_xs = x_s.neg().minC(MAX_EXP_ARG).exp();
        const chi_xs = chiS(S, x_s);
        const diff = x_g_safe.sub(x_s);
        // f = (x_g_safe - x_s)^2 - g2*(x_s - 1 + exp_neg_xs + delta_ns*(1/exp_neg_xs - x_s - 1 - chi_xs))
        const inner = x_s.addC(-1.0).add(exp_neg_xs).add(delta_ns.mul(S.con(1.0).div(exp_neg_xs.maxC(1.0e-30)).sub(x_s).addC(-1.0).sub(chi_xs)));
        const f_val = diff.mul(diff).sub(g2.mul(inner));

        const chi_d_xs = chi_dS(S, x_s);
        // df = -2*(x_g_safe - x_s) - g2*(1 - exp_neg_xs + delta_ns*(1/exp_neg_xs - 1 - chi_d_xs))
        const dinner = S.con(1.0).sub(exp_neg_xs).add(delta_ns.mul(S.con(1.0).div(exp_neg_xs.maxC(1.0e-30)).addC(-1.0).sub(chi_d_xs)));
        const df_val = diff.scale(-2.0).sub(g2.mul(dinner));
        // denom_safe: guard |df| > 1e-30, keep derivative of chosen branch
        const denom_safe = if (@abs(df_val.val()) > 1.0e-30) df_val else S.con(1.0e-30);
        x_s = x_s.sub(f_val.div(denom_safe));
        x_s = x_s.min(x_g_safe.addC(5.0)).maxC(-80.0);
    }

    // Iteration 2
    {
        const exp_neg_xs = x_s.neg().minC(MAX_EXP_ARG).exp();
        const chi_xs = chiS(S, x_s);
        const diff = x_g_safe.sub(x_s);
        const inner = x_s.addC(-1.0).add(exp_neg_xs).add(delta_ns.mul(S.con(1.0).div(exp_neg_xs.maxC(1.0e-30)).sub(x_s).addC(-1.0).sub(chi_xs)));
        const f_val = diff.mul(diff).sub(g2.mul(inner));

        const chi_d_xs = chi_dS(S, x_s);
        const dinner = S.con(1.0).sub(exp_neg_xs).add(delta_ns.mul(S.con(1.0).div(exp_neg_xs.maxC(1.0e-30)).addC(-1.0).sub(chi_d_xs)));
        const df_val = diff.scale(-2.0).sub(g2.mul(dinner));
        const denom_safe = if (@abs(df_val.val()) > 1.0e-30) df_val else S.con(1.0e-30);
        x_s = x_s.sub(f_val.div(denom_safe));
        x_s = x_s.min(x_g_safe.addC(5.0)).maxC(-80.0);
    }

    return x_s;
}

/// JUNCAP2 junction current for one component (bot, sti, or gat). Value-form.
/// area/isat/vbi/p/vbr/pbr are x-independent; v_j and phi_t carry x.
inline fn juncapCurrentS(comptime S: type, v_j: S, area: f64, isat: f64, vbi: f64, p: f64, vbr: f64, pbr: f64, phi_t: S) S {
    const vbi_safe: f64 = @max(vbi, 0.2);
    // Forward bias: exponential with emission coefficient from grading
    const n_emission: f64 = 1.0 + (1.0 - p) * 0.1;
    const arg_fwd = v_j.div(phi_t.scale(n_emission)).minC(MAX_EXP_ARG);
    const i_fwd = arg_fwd.exp().addC(-1.0).scale(isat * area);

    // SRH recombination current (proportional to depletion width)
    const v_dep = v_j.neg().addC(vbi_safe).maxC(0.01);
    const w_dep = v_dep.scale(1.0 / vbi_safe).sqrt();
    const i_srh = w_dep.scale(isat * area * 0.5).mul(v_j.div(phi_t.scale(2.0)).minC(MAX_EXP_ARG).exp().addC(-1.0));

    // Reverse bias: breakdown
    const v_rev = v_j.neg().addC(-vbr).maxC(0.0);
    const arg_rev = v_rev.scale(1.0 / pbr).minC(MAX_EXP_ARG);
    const i_rev = arg_rev.exp().scale(-isat * area);

    // GMIN for convergence
    const i_gmin = v_j.scale(GMIN);

    return i_fwd.add(i_srh).add(i_rev).add(i_gmin);
}

/// JUNCAP2 junction depletion charge for one component. Value-form.
inline fn juncapChargeS(comptime S: type, v_j: S, area: f64, cjo: f64, vbi: f64, p: f64, phi_t: S) S {
    const vbi_safe: f64 = @max(vbi, 0.2);
    const fc: f64 = 0.9;
    const fc_vbi: f64 = fc * vbi_safe;
    const one_minus_p: f64 = 1.0 - p;

    // Reverse / moderate forward: depletion charge (power-law)
    const ratio = v_j.scale(-1.0 / vbi_safe).addC(1.0).maxC(1.0e-30);
    // 1 - exp(one_minus_p * log(ratio)) == 1 - ratio^one_minus_p
    const q_dep = ratio.log().scale(one_minus_p).exp().neg().addC(1.0).scale(vbi_safe * cjo * area / one_minus_p);

    // Forward beyond FC: quadratic extension (all coefficients x-independent)
    const cap_at_fc: f64 = cjo * area / contract.fmath.exp(p * contract.fmath.log(@max(1.0 - fc, 1.0e-30)));
    const q_at_fc: f64 = (vbi_safe * cjo * area / one_minus_p) * (1.0 - contract.fmath.exp(one_minus_p * contract.fmath.log(@max(1.0 - fc, 1.0e-30))));
    const dv = v_j.addC(-fc_vbi);
    // Q = Q(FC) + C(FC)*dV + 0.5*C(FC)/(vbi*(1-FC)) * dV^2
    const q_fwd = dv.mul(dv).scale(0.5 * cap_at_fc / (vbi_safe * (1.0 - fc))).add(dv.scale(cap_at_fc)).addC(q_at_fc);

    // Diffusion charge (proportional to exp(V/Vt))
    const q_diff = phi_t.mul(phi_t).scale(cjo * area / vbi_safe).mul(v_j.div(phi_t).minC(MAX_EXP_ARG).exp());

    // Region selection on v_j reproduces original piecewise branch.
    const q_base = if (v_j.val() < fc_vbi) q_dep else q_fwd;
    return q_base.add(q_diff);
}

// ============================================================================
// Bias-independent (x-independent) precomputed quantities.
// Geometry scaling and temperature references that depend only on model/instance
// parameters (NOT on terminal voltages or self-heating).
// ============================================================================

const Prep = struct {
    wf: f64,
    delta_l_ps: f64,
    delta_w_od: f64,
    l_e: f64,
    w_e: f64,
    t_kr: f64,
    t_ka: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    const inst_l: f64 = @as(f64, instance.l);
    const inst_w: f64 = @as(f64, instance.w);
    const inst_nf: f64 = @as(f64, instance.nf);
    const inst_trise: f64 = @as(f64, instance.trise);
    const p_tr: f64 = @as(f64, model.tr);
    const p_dta: f64 = @as(f64, model.dta);

    const l_en: f64 = 1.0e-6;
    const w_en: f64 = 1.0e-6;

    const wf = inst_w / inst_nf;

    const p_lvaro: f64 = @as(f64, model.lvaro);
    const p_lvarl: f64 = @as(f64, model.lvarl);
    const p_lvarw: f64 = @as(f64, model.lvarw);
    const p_lap: f64 = @as(f64, model.lap);
    const p_wvaro: f64 = @as(f64, model.wvaro);
    const p_wvarl: f64 = @as(f64, model.wvarl);
    const p_wvarw: f64 = @as(f64, model.wvarw);
    const p_wot: f64 = @as(f64, model.wot);

    const delta_l_ps = p_lvaro * (1.0 + p_lvarl * l_en / inst_l) * (1.0 + p_lvarw * w_en / wf);
    const delta_w_od = p_wvaro * (1.0 + p_wvarl * l_en / inst_l) * (1.0 + p_wvarw * w_en / wf);

    const l_e = @max(inst_l + delta_l_ps - 2.0 * p_lap, 1.0e-9);
    const w_e = @max(wf + delta_w_od - 2.0 * p_wot, 1.0e-9);

    const t_kr = T0 + p_tr;
    const t_ka = T0 + p_tr + p_dta + inst_trise;

    return .{
        .wf = wf,
        .delta_l_ps = delta_l_ps,
        .delta_w_od = delta_w_od,
        .l_e = l_e,
        .w_e = w_e,
        .t_kr = t_kr,
        .t_ka = t_ka,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// Current Function (i) -- Main PSP Channel + All Effects
// ============================================================================

/// PSP channel + all effects, value-form. Physics generic over scalar S.
/// x-independent param prep stays f64; every chain reachable from a terminal
/// voltage (including phi_t through the self-heating DT node) is carried as S.
pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const gp = @intFromEnum(U.gp);
    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);
    const bi = @intFromEnum(U.bi);
    const bs = @intFromEnum(U.bs);
    const bd = @intFromEnum(U.bd);
    const dt = @intFromEnum(U.dt);

    // ========================================================================
    // Cast model parameters to f64 (x-independent)
    // ========================================================================
    const type_f: f64 = @floatFromInt(model.type_);
    const p_tox: f64 = @as(f64, model.tox);
    const p_epsrox: f64 = @as(f64, model.epsrox);
    const p_neff: f64 = @as(f64, model.neff);
    const p_np: f64 = @as(f64, model.np);
    const p_vfb: f64 = @as(f64, model.vfb);
    const p_stvfb: f64 = @as(f64, model.stvfb);
    const p_st2vfb: f64 = @as(f64, model.st2vfb);
    const p_dphib: f64 = @as(f64, model.dphib);
    const p_betn: f64 = @as(f64, model.betn);
    const p_stbet: f64 = @as(f64, model.stbet);
    const p_mue: f64 = @as(f64, model.mue);
    const p_stmue: f64 = @as(f64, model.stmue);
    const p_themu: f64 = @as(f64, model.themu);
    const p_stthemu: f64 = @as(f64, model.stthemu);
    const p_cs_param: f64 = @as(f64, model.cs);
    const p_stcs: f64 = @as(f64, model.stcs);
    const p_thecs: f64 = @as(f64, model.thecs);
    const p_stthecs: f64 = @as(f64, model.stthecs);
    const p_xcor: f64 = @as(f64, model.xcor);
    const p_stxcor: f64 = @as(f64, model.stxcor);
    const p_feta: f64 = @as(f64, model.feta);
    const p_rs: f64 = @as(f64, model.rs);
    const p_strs: f64 = @as(f64, model.strs);
    const p_rsb: f64 = @as(f64, model.rsb);
    const p_rsg: f64 = @as(f64, model.rsg);
    const p_thesat: f64 = @as(f64, model.thesat);
    const p_stthesat: f64 = @as(f64, model.stthesat);
    const p_thesatb: f64 = @as(f64, model.thesatb);
    const p_thesatg: f64 = @as(f64, model.thesatg);
    const p_thesatt: f64 = @as(f64, model.thesatt);
    const p_ax: f64 = @as(f64, model.ax);
    const p_alp: f64 = @as(f64, model.alp);
    const p_alp1: f64 = @as(f64, model.alp1);
    const p_alp2: f64 = @as(f64, model.alp2);
    const p_vp: f64 = @as(f64, model.vp);
    const p_ct: f64 = @as(f64, model.ct);
    const p_ctg: f64 = @as(f64, model.ctg);
    const p_ctb: f64 = @as(f64, model.ctb);
    const p_cf: f64 = @as(f64, model.cf);
    const p_cfb: f64 = @as(f64, model.cfb);
    const p_cfd: f64 = @as(f64, model.cfd);
    const p_psce: f64 = @as(f64, model.psce);
    const p_psced: f64 = @as(f64, model.psced);
    const p_psceb: f64 = @as(f64, model.psceb);
    const p_qmc: f64 = @as(f64, model.qmc);
    const p_a1: f64 = @as(f64, model.a1);
    const p_a2: f64 = @as(f64, model.a2);
    const p_sta2: f64 = @as(f64, model.sta2);
    const p_a3: f64 = @as(f64, model.a3);
    const p_a4: f64 = @as(f64, model.a4);
    const p_iginv: f64 = @as(f64, model.iginv);
    const p_igov: f64 = @as(f64, model.igov);
    const p_igovd: f64 = @as(f64, model.igovd);
    const p_gc2: f64 = @as(f64, model.gc2);
    const p_gc3: f64 = @as(f64, model.gc3);
    const p_gc2ov: f64 = @as(f64, model.gc2ov);
    const p_gc3ov: f64 = @as(f64, model.gc3ov);
    const p_chib: f64 = @as(f64, model.chib);
    const p_toxov: f64 = @as(f64, model.toxov);
    const p_toxovd: f64 = @as(f64, model.toxovd);
    const p_agidl: f64 = @as(f64, model.agidl);
    const p_agidld: f64 = @as(f64, model.agidld);
    const p_bgidl: f64 = @as(f64, model.bgidl);
    const p_bgidld: f64 = @as(f64, model.bgidld);
    const p_cgidl: f64 = @as(f64, model.cgidl);
    const p_cgidld: f64 = @as(f64, model.cgidld);
    const p_stig: f64 = @as(f64, model.stig);
    const p_rg: f64 = @as(f64, model.rg);
    const p_rse: f64 = @as(f64, model.rse);
    const p_rde: f64 = @as(f64, model.rde);
    const p_rbulk: f64 = @as(f64, model.rbulk);
    const p_rwell: f64 = @as(f64, model.rwell);
    const p_rjuns: f64 = @as(f64, model.rjuns);
    const p_rjund: f64 = @as(f64, model.rjund);
    const p_rth: f64 = @as(f64, model.rth);
    const p_npck: f64 = @as(f64, model.npck);
    const p_lpck: f64 = @as(f64, model.lpck);
    const p_fol1: f64 = @as(f64, model.fol1);
    const p_fol2: f64 = @as(f64, model.fol2);
    const p_betnedge: f64 = @as(f64, model.betnedge);
    const p_stbetedge: f64 = @as(f64, model.stbetedge);
    const p_vfbedge: f64 = @as(f64, model.vfbedge);
    const p_stvfbedge: f64 = @as(f64, model.stvfbedge);
    const p_dphibedge: f64 = @as(f64, model.dphibedge);
    const p_neffedge: f64 = @as(f64, model.neffedge);
    const p_ctedge: f64 = @as(f64, model.ctedge);
    const p_psceedge: f64 = @as(f64, model.psceedge);
    const p_cfedge: f64 = @as(f64, model.cfedge);
    const p_cfbedge: f64 = @as(f64, model.cfbedge);
    const p_cfdedge: f64 = @as(f64, model.cfdedge);
    const p_pscebedge: f64 = @as(f64, model.pscebedge);
    const p_pscededge: f64 = @as(f64, model.pscededge);

    // JUNCAP2 source parameters
    const p_vbirbot: f64 = @as(f64, model.vbirbot);
    const p_vbirsti: f64 = @as(f64, model.vbirsti);
    const p_vbirgat: f64 = @as(f64, model.vbirgat);
    const p_idsatrbot: f64 = @as(f64, model.idsatrbot);
    const p_idsatrsti: f64 = @as(f64, model.idsatrsti);
    const p_idsatrgat: f64 = @as(f64, model.idsatrgat);
    const p_vbrbot: f64 = @as(f64, model.vbrbot);
    const p_vbrsti: f64 = @as(f64, model.vbrsti);
    const p_vbrgat: f64 = @as(f64, model.vbrgat);
    const p_pbrbot: f64 = @as(f64, model.pbrbot);
    const p_pbrsti: f64 = @as(f64, model.pbrsti);
    const p_pbrgat: f64 = @as(f64, model.pbrgat);
    const p_ifactor: f64 = @as(f64, model.ifactor);

    // Cast instance parameters (x-independent)
    const inst_nf: f64 = @as(f64, instance.nf);
    const inst_mult: f64 = @as(f64, instance.mult);
    const inst_delvto: f64 = @as(f64, instance.delvto);
    const inst_factuo: f64 = @as(f64, instance.factuo);
    const inst_absource: f64 = @as(f64, instance.absource);
    const inst_lssource: f64 = @as(f64, instance.lssource);
    const inst_lgsource: f64 = @as(f64, instance.lgsource);
    const inst_abdrain: f64 = @as(f64, instance.abdrain);
    const inst_lsdrain: f64 = @as(f64, instance.lsdrain);
    const inst_lgdrain: f64 = @as(f64, instance.lgdrain);

    // ========================================================================
    // Effective Geometry (from PrepCache)
    // ========================================================================
    const l_en: f64 = 1.0e-6;
    const w_en: f64 = 1.0e-6;
    const l_e = pc.l_e;
    const w_e = pc.w_e;

    // ========================================================================
    // Temperature (x-dependent via self-heating thermal node DT)
    // ========================================================================
    const t_kr = pc.t_kr; // f64
    const t_ka = pc.t_ka; // f64

    // Self-heating: thermal node voltage is temperature rise
    const v_dt = x[dt];
    const t_kd = v_dt.addC(t_ka); // S
    const delta_t = t_kd.addC(-t_kr); // S
    const r_t = t_kd.scale(1.0 / t_kr); // S

    const phi_t = t_kd.scale(KB_OVER_Q); // S

    // ========================================================================
    // Bandgap and Intrinsic Concentration
    // ========================================================================
    const eg_q = t_kd.mul(t_kd).scale(-3.05e-7).add(t_kd.scale(-9.025e-5)).addC(1.179); // S
    // ni = 2.5e25 * r_t^0.75 * (t_kd/300)^1.5 * exp(-eg_q/(2*phi_t))
    const ni = r_t.log().scale(0.75).exp()
        .mul(t_kd.scale(1.0 / 300.0).log().scale(1.5).exp())
        .mul(eg_q.neg().div(phi_t.scale(2.0)).minC(MAX_EXP_ARG).exp())
        .scale(2.5e25); // S

    // ========================================================================
    // Flat-Band Voltage with Temperature
    // ========================================================================
    // vfb_t = p_vfb + p_stvfb*delta_t*(1 + p_st2vfb*delta_t) + inst_delvto
    const vfb_t = delta_t.mul(delta_t.scale(p_st2vfb).addC(1.0)).scale(p_stvfb).addC(p_vfb + inst_delvto); // S

    // ========================================================================
    // Oxide Capacitance per Unit Area (x-independent)
    // ========================================================================
    const eps_ox = p_epsrox * EPS0;
    const c_ox = eps_ox / p_tox;

    // ========================================================================
    // Surface Potential phi_B
    // ========================================================================
    // phi_b_cl = max(p_dphib + 2*phi_t*log(max(p_neff/ni, 1)), 0.05)
    const phi_b_cl = phi_t.scale(2.0).mul(S.con(p_neff).div(ni).maxC(1.0).log()).addC(p_dphib).maxC(0.05); // S

    // Body-effect coefficient gamma (gamma_0 x-independent)
    const gamma_0 = @sqrt(2.0 * QE * EPS_SI * p_neff) / c_ox; // f64
    const g_0 = S.con(gamma_0).div(phi_t.sqrt()); // gamma_0/sqrt(phi_t)

    // Quantum-mechanical corrections (x-independent)
    const qm_const = if (model.type_ == 1) QMN else QMP;
    const q_q = 0.4 * p_qmc * qm_const * contract.fmath.exp((2.0 / 3.0) * contract.fmath.log(@max(c_ox, 1.0e-30))); // f64

    // Approximate bulk charge at threshold for QM
    // q_b0 = sqrt(max(2*QE*EPS_SI*p_neff*phi_b_cl, 1e-30)) / c_ox
    const q_b0 = phi_b_cl.scale(2.0 * QE * EPS_SI * p_neff).maxC(1.0e-30).sqrt().scale(1.0 / c_ox); // S
    // phi_b = phi_b_cl + 0.75*q_q*q_b0^(2/3)
    const phi_b = q_b0.maxC(1.0e-30).log().scale(2.0 / 3.0).exp().scale(0.75 * q_q).add(phi_b_cl); // S

    // g_0_qm = g_0 * (1 + q_q * q_b0^(-1/3))
    const g_0_qm = g_0.mul(q_b0.maxC(1.0e-30).log().scale(-1.0 / 3.0).exp().scale(q_q).addC(1.0)); // S

    // Polysilicon depletion parameter (x-dependent through phi_t)
    const np2 = @max(p_np, 1.0e20); // f64
    // k_p = if np>0 then 2*phi_t*c_ox^2/(QE*EPS_SI*np2) else 0
    const k_p = if (p_np > 0.0) phi_t.scale(2.0 * c_ox * c_ox / (QE * EPS_SI * np2)) else S.con(0.0); // S

    // ========================================================================
    // Mobility and Velocity Saturation with Temperature
    // ========================================================================
    const r_t_inv = S.con(t_kr).div(t_kd); // t_kr/t_kd
    const rti = r_t_inv.maxC(1.0e-30);
    const beta = rti.log().scale(p_stbet).exp().scale(inst_factuo * p_betn * c_ox); // S
    const theta_mu = rti.log().scale(p_stthemu).exp().scale(p_themu); // S
    const mu_e = rti.log().scale(p_stmue).exp().scale(p_mue); // S
    const xcor_t = rti.log().scale(p_stxcor).exp().scale(p_xcor); // S
    const cs_t = rti.log().scale(p_stcs).exp().scale(p_cs_param); // S
    const thecs_t = rti.log().scale(p_stthecs).exp().scale(p_thecs); // S

    // Series resistance with temperature
    const rs_t = rti.log().scale(p_strs).exp().scale(p_rs); // S

    // Velocity saturation with temperature
    const thesat_t = rti.log().scale(p_stthesat).exp().scale(p_thesat); // S

    // Impact ionization A2 with temperature
    const a2_t = delta_t.scale(p_sta2).addC(p_a2); // S

    // Linear-saturation transition parameter (x-independent)
    const ax_safe = @max(p_ax, 2.01);
    const two_pow = contract.fmath.exp((-2.0 / ax_safe + 1.0) * contract.fmath.log(2.0));
    const a_r = (two_pow - 2.0) / @max(4.0 * two_pow - 1.0, 1.0e-4);

    // Gate tunneling parameters (x-independent)
    const b_tun = 6.830909e9 * p_tox * @sqrt(@max(p_chib, 0.1));
    const b_tun_ov_s = 6.830909e9 * p_toxov * @sqrt(@max(p_chib, 0.1));
    const b_tun_ov_d = 6.830909e9 * p_toxovd * @sqrt(@max(p_chib, 0.1));

    // ========================================================================
    // Terminal Voltages (Intrinsic Nodes)
    // ========================================================================
    const v_gp_bi = x[gp].sub(x[bi]).scale(type_f);
    const v_di_si = x[di].sub(x[si]).scale(type_f);
    const v_si_bi = x[si].sub(x[bi]).scale(type_f);
    const v_di_bi = x[di].sub(x[bi]).scale(type_f);
    const v_gp_si = x[gp].sub(x[si]).scale(type_f);
    const v_gp_di = x[gp].sub(x[di]).scale(type_f);

    // Source-drain reversal (branchless)
    const vds_abs = v_di_si.abs();
    const vds_sign = v_di_si.div(vds_abs.addC(1.0e-30));
    const vds_neg = v_di_si.minC(0.0);

    // Effective voltages after swap
    const v_gb_star = v_gp_bi.sub(vfb_t);
    const vsb_eff = v_si_bi.sub(vds_neg);

    // ========================================================================
    // Vdsx -- smooth abs(Vds)
    // ========================================================================
    const vds_sq = v_di_si.mul(v_di_si);
    const v_dsx = vds_sq.div(vds_sq.addC(0.01).sqrt().addC(0.1));

    // ========================================================================
    // Effective bulk voltage
    // ========================================================================
    const v_sbx = vsb_eff.maxC(0.0);

    // ========================================================================
    // Interface States
    // ========================================================================
    const x_ct = v_gb_star.div(phi_t);
    const x_ct_max = x_ct.abs().maxC(1.0);
    const ct_eff = x_ct.div(x_ct_max).scale(p_ctg).addC(1.0).minC(MAX_EXP_ARG).exp().scale(p_ct);
    const ct_b = v_sbx.scale(p_ctb).addC(1.0);
    const phi_t_ct = phi_t.mul(ct_eff.mul(ct_b).addC(1.0));

    // ========================================================================
    // Short Channel Effects
    // ========================================================================
    const delta_phi_t_star = v_dsx.scale(p_psced).addC(1.0).mul(v_sbx.scale(p_psceb).addC(1.0)).scale(p_psce);
    const phi_t_star = phi_t_ct.mul(delta_phi_t_star.addC(1.0));
    const g_eff = g_0_qm.mul(phi_t.div(phi_t_star));

    // DIBL
    const v_ds_star_denom = v_dsx.scale(p_cfd).addC(1.0).maxC(0.01).sqrt().addC(1.0);
    const v_ds_star = v_dsx.scale(2.0).div(v_ds_star_denom);
    const delta_phi_b = v_ds_star.mul(v_sbx.scale(p_cfb).addC(1.0)).scale(p_cf);

    // ========================================================================
    // Normalized voltages
    // ========================================================================
    const x_ns = phi_b.add(v_sbx).div(phi_t_star);
    const delta_ns = x_ns.neg().minC(MAX_EXP_ARG).exp();

    // Pocket doping effect (x-independent)
    const lpck_eff = @max(p_lpck, 1.0e-10);
    const pocket_factor = 1.0 + p_npck / @max(p_neff, 1.0e20) * contract.fmath.exp(-l_e / (2.0 * lpck_eff));

    // Short channel body effect (x-independent)
    const fol_eff = 1.0 + p_fol1 * l_en / l_e + p_fol2 * l_en * l_en / (l_e * l_e);

    // Polysilicon depletion correction to gate voltage
    const v_gb_poly = v_gb_star.add(delta_phi_b);
    const poly_corr = if (k_p.val() > 0.0)
        S.con(1.0).div(k_p.mul(v_gb_poly.div(phi_t_star).maxC(0.0)).addC(1.0))
    else
        S.con(1.0);
    // Body factor correction for pocket doping and short channel
    const g_eff_corr = g_eff.scale(fol_eff * @sqrt(pocket_factor));
    // Width-dependent body factor for NUD (x-independent)
    const nud_factor = 1.0 + @as(f64, model.nsubw) * w_en / (w_e + @as(f64, model.wseg));
    const g_eff_final = g_eff_corr.scale(@sqrt(nud_factor));
    const x_g = v_gb_poly.mul(poly_corr).div(phi_t_star);

    // ========================================================================
    // Surface Potential at Source Side
    // ========================================================================
    const x_s = surfPotS(S, x_g, g_eff_final, delta_ns);

    // ========================================================================
    // Inversion charge at source
    // ========================================================================
    const exp_neg_xs = x_s.neg().minC(MAX_EXP_ARG).exp();
    const p_s = x_s.addC(-1.0).add(exp_neg_xs);
    const d_s = p_s.maxC(1.0e-30);
    const q_is = g_eff_final.mul(g_eff_final).mul(phi_t_star).mul(d_s)
        .div(x_g.sub(x_s).add(g_eff_final.mul(p_s.maxC(1.0e-30).sqrt())).addC(1.0e-30));
    const q_bs = g_eff_final.mul(p_s.maxC(1.0e-30).sqrt()).mul(phi_t_star);

    // ========================================================================
    // Mobility Reduction
    // ========================================================================
    const e_eff_s = q_is.add(q_bs.scale(p_feta)).scale(1.0 / (EPS_SI + 1.0e-30));
    const mu_e_eeff = mu_e.mul(e_eff_s.abs());
    const mu_e_pow = theta_mu.mul(mu_e_eeff.maxC(1.0e-30).log()).exp();

    const cs_ratio = q_bs.div(q_is.add(q_bs).addC(1.0e-30));
    const cs_factor = cs_t.mul(thecs_t.mul(cs_ratio.maxC(1.0e-30).log()).exp());

    // Non-universality correction (Xcor effect on mobility)
    const rho_s = xcor_t.mul(x_g.sub(x_s)).mul(phi_t_star);

    const mu_x: f64 = 1.0;
    const g_mob_s = mu_e_pow.add(cs_factor).add(rho_s).addC(1.0).scale(1.0 / mu_x);

    // ========================================================================
    // Saturation Voltage
    // ========================================================================
    const xgphi = x_g.mul(phi_t_star).maxC(0.0);
    const thesat_eff = thesat_t.mul(v_sbx.scale(p_thesatb).addC(1.0))
        .mul(xgphi.scale(p_thesatg).div(xgphi.addC(p_thesatt + 1.0e-30)).addC(1.0));
    const thesat_star = thesat_eff.mul(g_mob_s);

    const x_inf = q_is.div(phi_t_star.addC(1.0e-30)).maxC(1.0e-10);
    const y_sat_arg = phi_t_star.mul(thesat_star).mul(x_inf).scale(1.0 / @sqrt(2.0));

    // NMOS/PMOS saturation voltage computation
    const y_sat = if (model.type_ == 1)
        y_sat_arg.div(y_sat_arg.addC(1.0).sqrt())
    else
        y_sat_arg.div(y_sat_arg.addC(1.0).sqrt().addC(1.0));

    // x_sat incorporates velocity saturation effect via y_sat
    const x_sat = x_inf.mul(y_sat.addC(1.0)).div(y_sat.addC(1.0 + 1.0e-30)).maxC(1.0e-10);
    const a_sat = g_eff_final.mul(d_s.maxC(1.0e-30).sqrt()).scale(0.5);
    // v_dsat_inner = x_sat - log(max(1 + x_sat*(x_sat - 2*a_sat)/(g^2*d_s + 1e-30), 1e-30))
    const v_dsat_inner = x_sat.sub(x_sat.mul(x_sat.sub(a_sat.scale(2.0))).div(g_eff_final.mul(g_eff_final).mul(d_s).addC(1.0e-30)).addC(1.0).maxC(1.0e-30).log());
    const v_dsat = phi_t_star.mul(v_dsat_inner).maxC(0.001);

    // ========================================================================
    // Effective Drain Voltage -- Smooth Clipping
    // ========================================================================
    const sqrt_1par = @sqrt(1.0 + a_r); // f64
    const sqrt_ar = @sqrt(a_r); // f64
    const vds_ratio = vds_abs.div(v_dsat.addC(1.0e-30));
    const term1 = vds_ratio.scale(sqrt_1par).addC(-1.0 + sqrt_ar);
    const term2 = vds_ratio.scale(sqrt_1par).addC(1.0 + sqrt_ar);
    const v_dse = vds_abs.scale(2.0 * sqrt_1par).div(term1.mul(term1).addC(a_r).sqrt().add(term2.mul(term2).addC(a_r).sqrt()));
    const v_dse_eff = v_dse.min(vds_abs);

    // ========================================================================
    // Surface Potential at Drain Side
    // ========================================================================
    const k_ds = v_dse_eff.neg().div(phi_t_star).minC(MAX_EXP_ARG).exp();

    const x_g_d = x_g;
    const x_d = surfPotS(S, x_g_d, g_eff_final, delta_ns.mul(k_ds));

    // Drain side charges
    const exp_neg_xd = x_d.neg().minC(MAX_EXP_ARG).exp();
    const p_d = x_d.addC(-1.0).add(exp_neg_xd);
    const q_id = g_eff_final.mul(g_eff_final).mul(phi_t_star).mul(p_d.maxC(1.0e-30))
        .div(x_g_d.sub(x_d).add(g_eff_final.mul(p_d.maxC(1.0e-30).sqrt())).addC(1.0e-30));
    const q_bd = g_eff_final.mul(p_d.maxC(1.0e-30).sqrt()).mul(phi_t_star);

    // ========================================================================
    // Mean quantities
    // ========================================================================
    const q_im = q_is.add(q_id).scale(0.5);
    const q_bm = q_bs.add(q_bd).scale(0.5);
    const delta_psi = x_s.sub(x_d).maxC(0.0).mul(phi_t_star);

    // ========================================================================
    // Channel Length Modulation
    // ========================================================================
    const vp_safe = @max(p_vp, 1.0e-10); // f64
    const s1_num = vds_abs.sub(delta_psi).scale(1.0 / vp_safe).addC(1.0);
    const s1_den = v_dse_eff.sub(delta_psi).scale(1.0 / vp_safe).addC(1.0);
    const s1 = s1_num.maxC(1.0e-30).log().sub(s1_den.maxC(1.0e-30).log());

    const q_im_star = q_im.maxC(1.0e-30);

    // ALP2 term
    const alpha_m_phi_t = phi_t_star;
    const alpha_m_ratio_sq = alpha_m_phi_t.mul(alpha_m_phi_t).div(q_im_star.mul(q_im_star).addC(1.0e-30));
    const delta_l_over_l = S.con(p_alp).add(S.con(p_alp1).div(q_im_star)).mul(q_im.div(q_im_star)).mul(s1)
        .add(q_bm.scale(p_alp2).mul(alpha_m_ratio_sq).mul(s1));
    const g_delta_l = S.con(1.0).div(delta_l_over_l.add(delta_l_over_l.mul(delta_l_over_l)).addC(1.0));

    // ========================================================================
    // Mobility reduction - mean
    // ========================================================================
    const e_eff_m = q_im.add(q_bm.scale(p_feta)).scale(1.0 / (EPS_SI + 1.0e-30));
    const mu_e_eeff_m = mu_e.mul(e_eff_m.abs());
    const mu_e_pow_m = theta_mu.mul(mu_e_eeff_m.maxC(1.0e-30).log()).exp();
    const cs_ratio_m = q_bm.div(q_im.add(q_bm).addC(1.0e-30));
    const cs_factor_m = cs_t.mul(thecs_t.mul(cs_ratio_m.maxC(1.0e-30).log()).exp());
    const g_mob = mu_e_pow_m.add(cs_factor_m).addC(1.0).scale(1.0 / mu_x);

    // ========================================================================
    // Velocity Saturation
    // ========================================================================
    const thesat_star_clm = thesat_star.div(g_delta_l);
    const z_sat_nmos = thesat_star_clm.mul(thesat_star_clm).mul(delta_psi).mul(delta_psi);
    const z_sat_pmos = thesat_star_clm.mul(thesat_star_clm).mul(delta_psi).mul(delta_psi).div(thesat_star_clm.mul(delta_psi).addC(1.0 + 1.0e-30));
    const z_sat = if (model.type_ == 1) z_sat_nmos else z_sat_pmos;

    const g_vsat = g_mob.mul(g_delta_l).scale(0.5).mul(z_sat.scale(2.0).addC(1.0).sqrt().addC(1.0));

    // ========================================================================
    // Drain-Source Channel Current with bias-dependent series resistance
    // ========================================================================
    const rs_bias = rs_t.mul(v_sbx.scale(p_rsb).addC(1.0)).mul(v_gb_star.maxC(0.0).scale(p_rsg).addC(1.0));
    const theta_r = beta.mul(rs_bias).scale(2.0);
    const ids_no_rs = beta.mul(q_im_star).div(g_vsat).mul(delta_psi);
    const ids_raw = ids_no_rs.div(theta_r.mul(ids_no_rs).div(delta_psi.addC(1.0e-30)).addC(1.0));

    // ========================================================================
    // Edge Transistor Current (SWEDGE)
    // ========================================================================
    const ids_edge_raw = if (model.swedge != 0) blk: {
        const vfb_edge_t = delta_t.scale(p_stvfbedge).addC(p_vfbedge + inst_delvto);
        const c_ox_edge = c_ox; // f64
        const neff_edge = p_neffedge; // f64
        const phi_b_edge_cl = phi_t.scale(2.0).mul(S.con(neff_edge).div(ni).maxC(1.0).log()).addC(p_dphibedge).maxC(0.05);
        const gamma_edge = @sqrt(2.0 * QE * EPS_SI * neff_edge) / c_ox_edge; // f64
        const g_edge = S.con(gamma_edge).div(phi_t.sqrt());

        const v_gb_edge_star = v_gp_bi.sub(vfb_edge_t);
        const x_ct_e = v_gb_edge_star.div(phi_t);
        const x_ct_max_e = x_ct_e.abs().maxC(1.0);
        const ct_eff_e = x_ct_e.div(x_ct_max_e).scale(p_ctg).addC(1.0).minC(MAX_EXP_ARG).exp().scale(p_ctedge);
        const phi_t_ct_e = phi_t.mul(ct_eff_e.mul(v_sbx.scale(p_ctb).addC(1.0)).addC(1.0));

        const delta_phi_t_e = v_dsx.scale(p_pscededge).addC(1.0).mul(v_sbx.scale(p_pscebedge).addC(1.0)).scale(p_psceedge);
        const phi_t_star_e = phi_t_ct_e.mul(delta_phi_t_e.addC(1.0));
        const g_edge_eff = g_edge.mul(phi_t.div(phi_t_star_e));

        const v_ds_star_e = v_dsx.scale(2.0).div(v_dsx.scale(p_cfdedge).addC(1.0).maxC(0.01).sqrt().addC(1.0));
        const delta_phi_b_e = v_ds_star_e.mul(v_sbx.scale(p_cfbedge).addC(1.0)).scale(p_cfedge);

        const x_g_e = v_gb_edge_star.add(delta_phi_b_e).div(phi_t_star_e);
        const x_ns_e = phi_b_edge_cl.add(v_sbx).div(phi_t_star_e);
        const delta_ns_e = x_ns_e.neg().minC(MAX_EXP_ARG).exp();

        const x_s_e = surfPotS(S, x_g_e, g_edge_eff, delta_ns_e);
        const exp_neg_xs_e = x_s_e.neg().minC(MAX_EXP_ARG).exp();
        const p_s_e = x_s_e.addC(-1.0).add(exp_neg_xs_e);
        const q_is_e = g_edge_eff.mul(g_edge_eff).mul(phi_t_star_e).mul(p_s_e.maxC(1.0e-30))
            .div(x_g_e.sub(x_s_e).add(g_edge_eff.mul(p_s_e.maxC(1.0e-30).sqrt())).addC(1.0e-30));
        const k_ds_e = v_dse_eff.neg().div(phi_t_star_e).minC(MAX_EXP_ARG).exp();
        const x_d_e = surfPotS(S, x_g_e, g_edge_eff, delta_ns_e.mul(k_ds_e));
        const exp_neg_xd_e = x_d_e.neg().minC(MAX_EXP_ARG).exp();
        const p_d_e = x_d_e.addC(-1.0).add(exp_neg_xd_e);
        const q_id_e = g_edge_eff.mul(g_edge_eff).mul(phi_t_star_e).mul(p_d_e.maxC(1.0e-30))
            .div(x_g_e.sub(x_d_e).add(g_edge_eff.mul(p_d_e.maxC(1.0e-30).sqrt())).addC(1.0e-30));
        const q_im_e = q_is_e.add(q_id_e).scale(0.5);
        const delta_psi_e = x_s_e.sub(x_d_e).maxC(0.0).mul(phi_t_star_e);
        // beta_edge = factuoedge * p_betnedge * c_ox_edge * r_t_inv^p_stbetedge
        const beta_edge = rti.log().scale(p_stbetedge).exp().scale(@as(f64, instance.factuoedge) * p_betnedge * c_ox_edge);
        break :blk beta_edge.mul(q_im_e).div(g_mob).mul(delta_psi_e);
    } else S.con(0.0);

    // ========================================================================
    // Impact Ionization
    // ========================================================================
    const delta_vsat = vds_abs.sub(delta_psi.scale(p_a3));
    const delta_vsat_safe = delta_vsat.maxC(1.0e-30);
    const a2_safe = a2_t.maxC(0.1);
    const m_avl_raw = delta_vsat_safe.scale(p_a1).mul(a2_safe.neg().div(delta_vsat_safe).minC(MAX_EXP_ARG).exp());
    const m_avl = if (model.swimpact != 0 and delta_vsat.val() > 0.0)
        m_avl_raw.mul(v_sbx.maxC(0.0).sqrt().scale(p_a4).addC(1.0))
    else
        S.con(0.0);
    const i_avl = m_avl.mul(ids_raw.add(ids_edge_raw));

    // ========================================================================
    // Gate Current -- branchless: swigate is loop-invariant
    // ========================================================================
    const ig_gate_en: f64 = if (model.swigate != 0) 1.0 else 0.0;

    // Gate-channel tunneling
    const v_ox = v_gb_star.sub(phi_t_star.mul(x_s));
    const v_ox_safe = v_ox.abs().maxC(1.0e-6);
    const z_g_tun = v_ox.div(v_ox_safe);
    const fs_gate = v_ox.mul(v_ox_safe);
    const ig_c_raw = fs_gate.scale(p_iginv).mul(z_g_tun.mul(z_g_tun.scale(p_gc3).addC(p_gc2)).addC(-1.5).scale(b_tun).minC(MAX_EXP_ARG).exp());
    const ig_temp = rti.log().scale(p_stig).exp();
    const ig_c = ig_c_raw.mul(ig_temp).scale(ig_gate_en);

    // Source-side overlap current
    const v_gs_ov_ig = v_gp_si;
    const v_gs_ov_safe = v_gs_ov_ig.abs().maxC(1.0e-6);
    const z_gs = v_gs_ov_ig.div(v_gs_ov_safe);
    const fs_sov = v_gs_ov_ig.mul(v_gs_ov_safe);
    const ig_sov = fs_sov.scale(p_igov).mul(z_gs.mul(z_gs.scale(p_gc3ov).addC(p_gc2ov)).addC(-1.5).scale(b_tun_ov_s).minC(MAX_EXP_ARG).exp()).mul(ig_temp).scale(ig_gate_en);

    // Drain-side overlap current
    const v_gd_ov_ig = v_gp_di;
    const v_gd_ov_safe = v_gd_ov_ig.abs().maxC(1.0e-6);
    const z_gd = v_gd_ov_ig.div(v_gd_ov_safe);
    const fs_dov = v_gd_ov_ig.mul(v_gd_ov_safe);
    const ig_dov = fs_dov.scale(p_igovd).mul(z_gd.mul(z_gd.scale(p_gc3ov).addC(p_gc2ov)).addC(-1.5).scale(b_tun_ov_d).minC(MAX_EXP_ARG).exp()).mul(ig_temp).scale(ig_gate_en);

    // ========================================================================
    // GIDL/GISL Current -- branchless: swgidl is loop-invariant
    // ========================================================================
    const gidl_en: f64 = if (model.swgidl != 0) 1.0 else 0.0;

    // GIDL (drain side)
    const v_gd_gidl = v_gp_di;
    const v_db_gidl = v_di_bi;
    const v_ov_d = v_gd_gidl.neg();
    const v_xb_d = v_db_gidl.maxC(0.01);
    const p_stbgidld: f64 = @as(f64, model.stbgidld);
    const bgidld_t = delta_t.scale(p_stbgidld).addC(p_bgidld);
    const v_tov_d = v_ov_d.mul(v_ov_d).add(v_xb_d.mul(v_xb_d).scale(p_cgidld * p_cgidld)).addC(1.0e-6).sqrt();
    const t_gidl = v_xb_d.mul(v_tov_d).mul(v_ov_d);
    const i_gidl_raw = if (v_ov_d.val() < 0.0)
        t_gidl.scale(-p_agidld).mul(bgidld_t.neg().div(v_tov_d.addC(1.0e-30)).minC(MAX_EXP_ARG).exp())
    else
        S.con(0.0);
    const i_gidl = i_gidl_raw.scale(gidl_en);

    // GISL (source side)
    const v_gs_gisl = v_gp_si;
    const v_sb_gisl = v_si_bi;
    const v_ov_s = v_gs_gisl.neg();
    const v_xb_s = v_sb_gisl.maxC(0.01);
    const p_stbgidl: f64 = @as(f64, model.stbgidl);
    const bgidl_t = delta_t.scale(p_stbgidl).addC(p_bgidl);
    const v_tov_s = v_ov_s.mul(v_ov_s).add(v_xb_s.mul(v_xb_s).scale(p_cgidl * p_cgidl)).addC(1.0e-6).sqrt();
    const t_gisl = v_xb_s.mul(v_tov_s).mul(v_ov_s);
    const i_gisl_raw = if (v_ov_s.val() < 0.0)
        t_gisl.scale(-p_agidl).mul(bgidl_t.neg().div(v_tov_s.addC(1.0e-30)).minC(MAX_EXP_ARG).exp())
    else
        S.con(0.0);
    const i_gisl = i_gisl_raw.scale(gidl_en);

    // ========================================================================
    // JUNCAP2 Junction Diode Currents -- branchless
    // ========================================================================
    const juncap_en: f64 = if (model.swjuncap != 0) 1.0 else 0.0;

    // Source-bulk junction
    const v_bs_j = x[bs].sub(x[si]).scale(type_f);
    const p_pbot_i: f64 = @as(f64, model.pbot);
    const p_psti_i: f64 = @as(f64, model.psti);
    const p_pgat_i: f64 = @as(f64, model.pgat);
    const i_junc_bs_bot = juncapCurrentS(S, v_bs_j, inst_absource, p_idsatrbot, p_vbirbot, p_pbot_i, p_vbrbot, p_pbrbot, phi_t);
    const i_junc_bs_sti = juncapCurrentS(S, v_bs_j, inst_lssource, p_idsatrsti, p_vbirsti, p_psti_i, p_vbrsti, p_pbrsti, phi_t);
    const i_junc_bs_gat = juncapCurrentS(S, v_bs_j, inst_lgsource, p_idsatrgat, p_vbirgat, p_pgat_i, p_vbrgat, p_pbrgat, phi_t);
    const i_junc_bs = i_junc_bs_bot.add(i_junc_bs_sti).add(i_junc_bs_gat).scale(p_ifactor * juncap_en);

    // Drain-bulk junction
    const v_bd_j = x[bd].sub(x[di]).scale(type_f);

    const idsatrbot_d = if (model.swjunasym != 0) @as(f64, model.idsatrbotd) else p_idsatrbot;
    const vbirbot_d = if (model.swjunasym != 0) @as(f64, model.vbirbotd) else p_vbirbot;
    const vbrbot_d = if (model.swjunasym != 0) @as(f64, model.vbrbotd) else p_vbrbot;
    const pbrbot_d = if (model.swjunasym != 0) @as(f64, model.pbrbotd) else p_pbrbot;
    const pbot_d = if (model.swjunasym != 0) @as(f64, model.pbotd) else p_pbot_i;
    const i_junc_bd_bot = juncapCurrentS(S, v_bd_j, inst_abdrain, idsatrbot_d, vbirbot_d, pbot_d, vbrbot_d, pbrbot_d, phi_t);

    const idsatrsti_d = if (model.swjunasym != 0) @as(f64, model.idsatrstid) else p_idsatrsti;
    const vbirsti_d = if (model.swjunasym != 0) @as(f64, model.vbirstid) else p_vbirsti;
    const vbrsti_d = if (model.swjunasym != 0) @as(f64, model.vbrstid) else p_vbrsti;
    const pbrsti_d = if (model.swjunasym != 0) @as(f64, model.pbrstid) else p_pbrsti;
    const psti_d = if (model.swjunasym != 0) @as(f64, model.pstid) else p_psti_i;
    const i_junc_bd_sti = juncapCurrentS(S, v_bd_j, inst_lsdrain, idsatrsti_d, vbirsti_d, psti_d, vbrsti_d, pbrsti_d, phi_t);

    const idsatrgat_d = if (model.swjunasym != 0) @as(f64, model.idsatrgatd) else p_idsatrgat;
    const vbirgat_d = if (model.swjunasym != 0) @as(f64, model.vbirgatd) else p_vbirgat;
    const vbrgat_d = if (model.swjunasym != 0) @as(f64, model.vbrgatd) else p_vbrgat;
    const pbrgat_d = if (model.swjunasym != 0) @as(f64, model.pbrgatd) else p_pbrgat;
    const pgat_d = if (model.swjunasym != 0) @as(f64, model.pgatd) else p_pgat_i;
    const i_junc_bd_gat = juncapCurrentS(S, v_bd_j, inst_lgdrain, idsatrgat_d, vbirgat_d, pgat_d, vbrgat_d, pbrgat_d, phi_t);

    const i_junc_bd = i_junc_bd_bot.add(i_junc_bd_sti).add(i_junc_bd_gat).scale(p_ifactor * juncap_en);

    // ========================================================================
    // Total channel current (mode-aware)
    // ========================================================================
    const ids_total = ids_raw.add(ids_edge_raw).mul(vds_sign);

    // ========================================================================
    // Parasitic Resistances (conductances) -- x-independent
    // ========================================================================
    const g_rg = if (p_rg != 0.0) 1.0 / p_rg else GSHORT;
    const inst_nrs: f64 = @as(f64, instance.nrs);
    const inst_nrd: f64 = @as(f64, instance.nrd);
    const p_rsh: f64 = @as(f64, model.rsh);
    const p_rshd: f64 = @as(f64, model.rshd);
    const rse_eff = if (p_rse != 0.0) p_rse else inst_nrs * p_rsh;
    const rde_eff = if (p_rde != 0.0) p_rde else inst_nrd * p_rshd;
    const g_rse = if (rse_eff != 0.0) 1.0 / rse_eff else GSHORT;
    const g_rde = if (rde_eff != 0.0) 1.0 / rde_eff else GSHORT;
    const r_bulk_well = p_rbulk + p_rwell;
    const g_bulk_well = if (r_bulk_well != 0.0) 1.0 / r_bulk_well else GSHORT;
    const g_rjuns = if (p_rjuns != 0.0) 1.0 / p_rjuns else GSHORT;
    const g_rjund = if (p_rjund != 0.0) 1.0 / p_rjund else GSHORT;

    // Parasitic resistance currents (x-dependent)
    const i_rg = x[g].sub(x[gp]).scale(g_rg);
    const i_rse = x[s].sub(x[si]).scale(g_rse);
    const i_rde = x[d].sub(x[di]).scale(g_rde);
    const i_rbulk = x[bi].sub(x[b]).scale(g_bulk_well);
    const i_rjuns = x[bs].sub(x[bi]).scale(g_rjuns);
    const i_rjund = x[bd].sub(x[bi]).scale(g_rjund);

    // Self-heating: thermal resistance
    const g_rth = if (p_rth != 0.0) 1.0 / p_rth else GSHORT;

    // ========================================================================
    // Terminal Current Assembly
    // ========================================================================
    const m = inst_mult * inst_nf; // f64

    // Intrinsic drain current contribution
    const i_di_int = ids_total.add(i_avl.mul(vds_sign)).sub(ig_dov).sub(ig_c.scale(0.5)).add(i_gidl).scale(type_f * m);
    const i_si_int = ids_total.neg().sub(ig_sov).sub(ig_c.scale(0.5)).add(i_gisl).scale(type_f * m);
    const i_gp_int = ig_c.add(ig_sov).add(ig_dov).scale(type_f * m);
    const i_bi_int = i_avl.mul(vds_sign).neg().sub(i_gidl).sub(i_gisl).scale(type_f * m);

    // Self-heating power dissipation injection
    const v_sis = x[s].sub(x[si]);
    const v_did = x[d].sub(x[di]);
    const p_diss_ch = ids_raw.mul(vds_abs).abs();
    const p_diss_avl = i_avl.abs().mul(vds_abs.add(v_sbx));
    const p_diss_rs = v_sis.mul(v_sis).scale(g_rse);
    const p_diss_rd = v_did.mul(v_did).scale(g_rde);
    const p_diss = p_diss_ch.add(p_diss_avl).add(p_diss_rs).add(p_diss_rd).scale(m);
    const i_dt = x[dt].scale(g_rth).sub(p_diss);

    // GMIN conductances on intrinsic nodes
    const gmin_ds = x[di].sub(x[si]).scale(GMIN);
    const gmin_gs = x[gp].sub(x[si]).scale(GMIN);
    const gmin_bs = x[bi].sub(x[si]).scale(GMIN);

    // ========================================================================
    // Final KCL Stamps
    // ========================================================================
    var out: [n_u]S = undefined;
    // External drain
    out[d] = i_rde;
    // External gate
    out[g] = i_rg;
    // External source
    out[s] = i_rse;
    // External bulk
    out[b] = i_rbulk.neg();

    // Internal gate (GP)
    out[gp] = i_gp_int.sub(i_rg).add(gmin_gs);
    // Internal drain (DI)
    out[di] = i_di_int.sub(i_rde).add(i_junc_bd.scale(type_f * m)).add(gmin_ds);
    // Internal source (SI)
    out[si] = i_si_int.sub(i_rse).sub(i_junc_bs.scale(type_f * m)).sub(gmin_ds).sub(gmin_gs).sub(gmin_bs);
    // Internal bulk (BI)
    out[bi] = i_bi_int.add(i_rbulk).sub(i_rjuns).sub(i_rjund).add(gmin_bs);
    // Bulk-source junction node (BS)
    out[bs] = i_rjuns.sub(i_junc_bs.scale(type_f * m));
    // Bulk-drain junction node (BD)
    out[bd] = i_rjund.sub(i_junc_bd.scale(type_f * m));
    // Thermal node (DT)
    out[dt] = i_dt;

    return out;
}

// ============================================================================
// Charge Function (q) -- Intrinsic + Overlap + Junction Depletion + Fringe
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const gp = @intFromEnum(U.gp);
    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);
    const bi = @intFromEnum(U.bi);
    const bs = @intFromEnum(U.bs);
    const bd = @intFromEnum(U.bd);
    const dt_idx = @intFromEnum(U.dt);

    const type_f: f64 = @floatFromInt(model.type_);
    const p_tox: f64 = @as(f64, model.tox);
    const p_epsrox: f64 = @as(f64, model.epsrox);
    const p_neff: f64 = @as(f64, model.neff);
    const p_vfb: f64 = @as(f64, model.vfb);
    const p_stvfb: f64 = @as(f64, model.stvfb);
    const p_st2vfb: f64 = @as(f64, model.st2vfb);
    const p_dphib: f64 = @as(f64, model.dphib);
    const p_qmc: f64 = @as(f64, model.qmc);
    const p_dlq: f64 = @as(f64, model.dlq);
    const p_dwq: f64 = @as(f64, model.dwq);
    const p_cgov: f64 = @as(f64, model.cgov);
    const p_cgovd: f64 = @as(f64, model.cgovd);
    const p_cgbov: f64 = @as(f64, model.cgbov);
    const p_cfr: f64 = @as(f64, model.cfr);
    const p_cfrd: f64 = @as(f64, model.cfrd);
    const p_cinr: f64 = @as(f64, model.cinr);
    const p_cinrd: f64 = @as(f64, model.cinrd);
    const p_cf_param: f64 = @as(f64, model.cf);
    const p_cfb: f64 = @as(f64, model.cfb);
    const p_cfd: f64 = @as(f64, model.cfd);
    const p_psce: f64 = @as(f64, model.psce);
    const p_psced: f64 = @as(f64, model.psced);
    const p_psceb: f64 = @as(f64, model.psceb);
    const p_ct: f64 = @as(f64, model.ct);
    const p_ctg: f64 = @as(f64, model.ctg);
    const p_ctb: f64 = @as(f64, model.ctb);
    const p_fcgovacc: f64 = @as(f64, model.fcgovacc);
    const p_fcgovaccd: f64 = @as(f64, model.fcgovaccd);
    const p_cgovaccg: f64 = @as(f64, model.cgovaccg);
    const p_cth: f64 = @as(f64, model.cth);
    const p_fcinrdep: f64 = @as(f64, model.fcinrdep);
    const p_fcinracc: f64 = @as(f64, model.fcinracc);
    const p_dvfbinr: f64 = @as(f64, model.dvfbinr);
    const p_axinr: f64 = @as(f64, model.axinr);

    // JUNCAP2 capacitance parameters
    const p_cjorbot: f64 = @as(f64, model.cjorbot);
    const p_cjorsti: f64 = @as(f64, model.cjorsti);
    const p_cjorgat: f64 = @as(f64, model.cjorgat);
    const p_vbirbot: f64 = @as(f64, model.vbirbot);
    const p_vbirsti: f64 = @as(f64, model.vbirsti);
    const p_vbirgat: f64 = @as(f64, model.vbirgat);
    const p_pbot: f64 = @as(f64, model.pbot);
    const p_psti: f64 = @as(f64, model.psti);
    const p_pgat: f64 = @as(f64, model.pgat);

    const inst_nf: f64 = @as(f64, instance.nf);
    const inst_mult: f64 = @as(f64, instance.mult);
    const inst_delvto: f64 = @as(f64, instance.delvto);
    const inst_absource: f64 = @as(f64, instance.absource);
    const inst_lssource: f64 = @as(f64, instance.lssource);
    const inst_lgsource: f64 = @as(f64, instance.lgsource);
    const inst_abdrain: f64 = @as(f64, instance.abdrain);
    const inst_lsdrain: f64 = @as(f64, instance.lsdrain);
    const inst_lgdrain: f64 = @as(f64, instance.lgdrain);

    // ========================================================================
    // Effective Geometry (from PrepCache)
    // ========================================================================
    const l_e = pc.l_e;
    const w_e = pc.w_e;
    const l_e_cv = @max(l_e + p_dlq, 1.0e-9);
    const w_e_cv = @max(w_e + p_dwq, 1.0e-9);

    // ========================================================================
    // Temperature (x-dependent via DT node)
    // ========================================================================
    const t_kr = pc.t_kr; // f64
    const t_ka = pc.t_ka; // f64
    const v_dt = x[dt_idx];
    const t_kd = v_dt.addC(t_ka); // S
    const delta_t = t_kd.addC(-t_kr); // S
    const r_t = t_kd.scale(1.0 / t_kr); // S

    const phi_t = t_kd.scale(KB_OVER_Q); // S

    // Bandgap
    const eg_q = t_kd.mul(t_kd).scale(-3.05e-7).add(t_kd.scale(-9.025e-5)).addC(1.179);
    const ni = r_t.log().scale(0.75).exp()
        .mul(t_kd.scale(1.0 / 300.0).log().scale(1.5).exp())
        .mul(eg_q.neg().div(phi_t.scale(2.0)).minC(MAX_EXP_ARG).exp())
        .scale(2.5e25);

    // VFB
    const vfb_t = delta_t.mul(delta_t.scale(p_st2vfb).addC(1.0)).scale(p_stvfb).addC(p_vfb + inst_delvto);

    // Oxide capacitance (x-independent)
    const eps_ox = p_epsrox * EPS0;
    const c_ox = eps_ox / p_tox;

    // Cox for charge model (uses CV geometry, x-independent)
    const cox_qm = c_ox * w_e_cv * l_e_cv;

    // Phi_B
    const phi_b_cl = phi_t.scale(2.0).mul(S.con(p_neff).div(ni).maxC(1.0).log()).addC(p_dphib).maxC(0.05);
    const gamma_0 = @sqrt(2.0 * QE * EPS_SI * p_neff) / c_ox; // f64
    const g_0 = S.con(gamma_0).div(phi_t.sqrt());

    // QM corrections
    const qm_const = if (model.type_ == 1) QMN else QMP;
    const q_q = 0.4 * p_qmc * qm_const * contract.fmath.exp((2.0 / 3.0) * contract.fmath.log(@max(c_ox, 1.0e-30))); // f64
    const q_b0 = phi_b_cl.scale(2.0 * QE * EPS_SI * p_neff).maxC(1.0e-30).sqrt().scale(1.0 / c_ox);
    const phi_b = q_b0.maxC(1.0e-30).log().scale(2.0 / 3.0).exp().scale(0.75 * q_q).add(phi_b_cl);
    const g_0_qm = g_0.mul(q_b0.maxC(1.0e-30).log().scale(-1.0 / 3.0).exp().scale(q_q).addC(1.0));

    // ========================================================================
    // Terminal Voltages
    // ========================================================================
    const v_gp_bi = x[gp].sub(x[bi]).scale(type_f);
    const v_di_si = x[di].sub(x[si]).scale(type_f);
    const v_si_bi = x[si].sub(x[bi]).scale(type_f);

    const vds_abs = v_di_si.abs();
    const vds_neg = v_di_si.minC(0.0);
    const vds_sign = v_di_si.div(vds_abs.addC(1.0e-30));

    const v_gb_star = v_gp_bi.sub(vfb_t);
    const vsb_eff = v_si_bi.sub(vds_neg);
    const v_sbx = vsb_eff.maxC(0.0);
    const vds_sq = v_di_si.mul(v_di_si);
    const v_dsx = vds_sq.div(vds_sq.addC(0.01).sqrt().addC(0.1));

    // Interface states
    const x_ct = v_gb_star.div(phi_t);
    const x_ct_max = x_ct.abs().maxC(1.0);
    const ct_eff = x_ct.div(x_ct_max).scale(p_ctg).addC(1.0).minC(MAX_EXP_ARG).exp().scale(p_ct);
    const ct_b = v_sbx.scale(p_ctb).addC(1.0);
    const phi_t_ct = phi_t.mul(ct_eff.mul(ct_b).addC(1.0));

    // Short channel effects
    const delta_phi_t_star = v_dsx.scale(p_psced).addC(1.0).mul(v_sbx.scale(p_psceb).addC(1.0)).scale(p_psce);
    const phi_t_star = phi_t_ct.mul(delta_phi_t_star.addC(1.0));
    const g_eff = g_0_qm.mul(phi_t.div(phi_t_star));

    // DIBL
    const v_ds_star_denom = v_dsx.scale(p_cfd).addC(1.0).maxC(0.01).sqrt().addC(1.0);
    const v_ds_star = v_dsx.scale(2.0).div(v_ds_star_denom);
    const delta_phi_b = v_ds_star.mul(v_sbx.scale(p_cfb).addC(1.0)).scale(p_cf_param);

    const x_ns_q = phi_b.add(v_sbx).div(phi_t_star);
    const delta_ns_q = x_ns_q.neg().minC(MAX_EXP_ARG).exp();
    const x_g_q = v_gb_star.add(delta_phi_b).div(phi_t_star);

    // Surface potential source side
    const x_s_q = surfPotS(S, x_g_q, g_eff, delta_ns_q);
    const exp_neg_xs_q = x_s_q.neg().minC(MAX_EXP_ARG).exp();
    const p_s_q = x_s_q.addC(-1.0).add(exp_neg_xs_q);
    const q_is_q = g_eff.mul(g_eff).mul(phi_t_star).mul(p_s_q.maxC(1.0e-30))
        .div(x_g_q.sub(x_s_q).add(g_eff.mul(p_s_q.maxC(1.0e-30).sqrt())).addC(1.0e-30));

    // Drain side (uses charge-model transition params AXAC)
    const p_ax_ac: f64 = @as(f64, model.axac);
    const ax_safe_ac = @max(p_ax_ac, 2.01);
    const two_pow_ac = contract.fmath.exp((-2.0 / ax_safe_ac + 1.0) * contract.fmath.log(2.0));
    const a_r_ac = (two_pow_ac - 2.0) / @max(4.0 * two_pow_ac - 1.0, 1.0e-4);

    const v_dsat_q = phi_t_star.mul(q_is_q.div(phi_t_star.addC(1.0e-30)).maxC(1.0e-10)).maxC(0.001);
    const sqrt_1par_ac = @sqrt(1.0 + a_r_ac); // f64
    const sqrt_ar_ac = @sqrt(a_r_ac); // f64
    const vds_ratio_ac = vds_abs.div(v_dsat_q.addC(1.0e-30));
    const term1_ac = vds_ratio_ac.scale(sqrt_1par_ac).addC(-1.0 + sqrt_ar_ac);
    const term2_ac = vds_ratio_ac.scale(sqrt_1par_ac).addC(1.0 + sqrt_ar_ac);
    const v_dse_ac = vds_abs.scale(2.0 * sqrt_1par_ac).div(term1_ac.mul(term1_ac).addC(a_r_ac).sqrt().add(term2_ac.mul(term2_ac).addC(a_r_ac).sqrt()));
    const v_dse_eff_ac = v_dse_ac.min(vds_abs);

    const k_ds_q = v_dse_eff_ac.neg().div(phi_t_star).minC(MAX_EXP_ARG).exp();
    const x_d_q = surfPotS(S, x_g_q, g_eff, delta_ns_q.mul(k_ds_q));
    const exp_neg_xd_q = x_d_q.neg().minC(MAX_EXP_ARG).exp();
    const p_d_q = x_d_q.addC(-1.0).add(exp_neg_xd_q);
    const q_id_q = g_eff.mul(g_eff).mul(phi_t_star).mul(p_d_q.maxC(1.0e-30))
        .div(x_g_q.sub(x_d_q).add(g_eff.mul(p_d_q.maxC(1.0e-30).sqrt())).addC(1.0e-30));

    // Mean charges
    const q_im_q = q_is_q.add(q_id_q).scale(0.5);
    const delta_psi_q = x_s_q.sub(x_d_q).maxC(0.0).mul(phi_t_star);

    // ========================================================================
    // CLM for charge model
    // ========================================================================
    const p_alpac: f64 = @as(f64, model.alpac);
    const p_alp1ac: f64 = @as(f64, model.alp1ac);
    const vp_safe = @max(@as(f64, model.vp), 1.0e-10); // f64
    const s1_q_num = vds_abs.sub(delta_psi_q).scale(1.0 / vp_safe).addC(1.0);
    const s1_q_den = v_dse_eff_ac.sub(delta_psi_q).scale(1.0 / vp_safe).addC(1.0);
    const s1_q = s1_q_num.maxC(1.0e-30).log().sub(s1_q_den.maxC(1.0e-30).log());
    const q_im_star_q = q_im_q.maxC(1.0e-30);
    const delta_l_q = S.con(p_alpac).add(S.con(p_alp1ac).div(q_im_star_q)).mul(q_im_q.div(q_im_star_q)).mul(s1_q);
    const g_delta_l_q = S.con(1.0).div(delta_l_q.add(delta_l_q.mul(delta_l_q)).addC(1.0));

    // ========================================================================
    // Intrinsic Gate Charge
    // ========================================================================
    const v_oxm = x_g_q.sub(x_s_q).mul(phi_t_star);

    // Charge partitioning (eta_p x-independent)
    const eta_p: f64 = if (model.swqpart != 0) 1.0 else 0.5;
    const f_j_num = q_is_q.mul(q_is_q).add(q_is_q.mul(q_id_q)).add(q_id_q.mul(q_id_q));
    const f_j_denom = q_is_q.add(q_id_q).mul(q_is_q.add(q_id_q)).addC(1.0e-30);
    const f_j = f_j_num.div(f_j_denom);

    // q_gate_intr = cox_qm * (v_oxm + eta_p*delta_psi_q/2 * g_delta_l_q/3 * f_j + g_delta_l_q - 1)
    const q_gate_intr = v_oxm.add(delta_psi_q.scale(eta_p / 2.0).mul(g_delta_l_q.scale(1.0 / 3.0)).mul(f_j)).add(g_delta_l_q).addC(-1.0).scale(cox_qm);

    // Inversion charge: q_inv = -cox_qm * g_delta_l_q * (q_im_q + delta_psi_q/6 * f_j)
    const q_inv = g_delta_l_q.mul(q_im_q.add(delta_psi_q.scale(1.0 / 6.0).mul(f_j))).scale(-cox_qm);

    // Source/drain partition
    const q_src_intr = if (model.swqpart != 0)
        q_inv
    else
        q_inv.scale(0.5);

    const q_drn_intr = q_inv.sub(q_src_intr);

    // Bulk charge (charge conservation)
    const q_bulk_intr = q_gate_intr.add(q_inv).neg();

    // ========================================================================
    // Overlap Charges
    // ========================================================================
    const v_gs_ov = x[gp].sub(x[si]).scale(type_f);
    const v_gd_ov = x[gp].sub(x[di]).scale(type_f);
    const v_gb_ov = x[gp].sub(x[bi]).scale(type_f);

    const v_gs_ov_acc = v_gs_ov.minC(0.0);
    const q_sov = v_gs_ov.scale(p_cgov).add(v_gs_ov_acc.scale(p_cgov * p_fcgovacc * p_cgovaccg));

    const v_gd_ov_acc = v_gd_ov.minC(0.0);
    const q_dov = v_gd_ov.scale(p_cgovd).add(v_gd_ov_acc.scale(p_cgovd * p_fcgovaccd * p_cgovaccg));

    const q_bov = v_gb_ov.scale(p_cgbov);

    // ========================================================================
    // Outer Fringe Capacitance
    // ========================================================================
    const q_cfr_s = v_gs_ov.scale(p_cfr);
    const q_cfr_d = v_gd_ov.scale(p_cfrd);

    // ========================================================================
    // Inner Fringe Capacitance (bias-dependent)
    // ========================================================================
    const v_gb_inr = v_gb_star.addC(-p_dvfbinr);
    const cinr_dep_factor = v_gb_inr.maxC(0.0).scale(p_fcinrdep).div(v_gb_inr.maxC(0.0).addC(p_axinr + 1.0e-30)).neg().addC(1.0);
    const cinr_acc_factor = v_gb_inr.neg().maxC(0.0).scale(p_fcinracc).div(v_gb_inr.neg().maxC(0.0).addC(p_axinr + 1.0e-30)).addC(1.0);
    const cinr_eff = cinr_dep_factor.mul(cinr_acc_factor).scale(p_cinr);
    const cinrd_eff = cinr_dep_factor.mul(cinr_acc_factor).scale(p_cinrd);

    const q_cinr_s = cinr_eff.mul(v_gs_ov);
    const q_cinr_d = cinrd_eff.mul(v_gd_ov);

    // ========================================================================
    // JUNCAP2 Junction Depletion Charges -- branchless
    // ========================================================================
    const juncap_en_q: f64 = if (model.swjuncap != 0) 1.0 else 0.0;
    const p_cfactor: f64 = @as(f64, model.cfactor);

    const v_bs_j_q = x[bs].sub(x[si]).scale(type_f);
    const q_junc_bs_bot = juncapChargeS(S, v_bs_j_q, inst_absource, p_cjorbot, p_vbirbot, p_pbot, phi_t);
    const q_junc_bs_sti = juncapChargeS(S, v_bs_j_q, inst_lssource, p_cjorsti, p_vbirsti, p_psti, phi_t);
    const q_junc_bs_gat = juncapChargeS(S, v_bs_j_q, inst_lgsource, p_cjorgat, p_vbirgat, p_pgat, phi_t);
    const q_junc_bs = q_junc_bs_bot.add(q_junc_bs_sti).add(q_junc_bs_gat).scale(p_cfactor * juncap_en_q);

    const v_bd_j_q = x[bd].sub(x[di]).scale(type_f);
    const cjorbot_d = if (model.swjunasym != 0) @as(f64, model.cjorbotd) else p_cjorbot;
    const vbirbot_d_q = if (model.swjunasym != 0) @as(f64, model.vbirbotd) else p_vbirbot;
    const pbot_d_q = if (model.swjunasym != 0) @as(f64, model.pbotd) else p_pbot;
    const q_junc_bd_bot = juncapChargeS(S, v_bd_j_q, inst_abdrain, cjorbot_d, vbirbot_d_q, pbot_d_q, phi_t);

    const cjorsti_d = if (model.swjunasym != 0) @as(f64, model.cjorstid) else p_cjorsti;
    const vbirsti_d_q = if (model.swjunasym != 0) @as(f64, model.vbirstid) else p_vbirsti;
    const psti_d_q = if (model.swjunasym != 0) @as(f64, model.pstid) else p_psti;
    const q_junc_bd_sti = juncapChargeS(S, v_bd_j_q, inst_lsdrain, cjorsti_d, vbirsti_d_q, psti_d_q, phi_t);

    const cjorgat_d = if (model.swjunasym != 0) @as(f64, model.cjorgatd) else p_cjorgat;
    const vbirgat_d_q = if (model.swjunasym != 0) @as(f64, model.vbirgatd) else p_vbirgat;
    const pgat_d_q = if (model.swjunasym != 0) @as(f64, model.pgatd) else p_pgat;
    const q_junc_bd_gat = juncapChargeS(S, v_bd_j_q, inst_lgdrain, cjorgat_d, vbirgat_d_q, pgat_d_q, phi_t);

    const q_junc_bd = q_junc_bd_bot.add(q_junc_bd_sti).add(q_junc_bd_gat).scale(p_cfactor * juncap_en_q);

    // ========================================================================
    // Total Terminal Charges
    // ========================================================================
    const m = inst_mult * inst_nf; // f64

    // Mode-aware intrinsic charge mapping (source-drain swap, branch on vds sign)
    const q_drn_mapped = if (vds_sign.val() >= 0.0) q_drn_intr else q_src_intr;
    const q_src_mapped = if (vds_sign.val() >= 0.0) q_src_intr else q_drn_intr;

    const q_gp_total = q_gate_intr.add(q_sov).add(q_dov).add(q_bov).add(q_cfr_s).add(q_cfr_d).add(q_cinr_s).add(q_cinr_d).scale(m);
    const q_di_total = q_drn_mapped.sub(q_dov).sub(q_cfr_d).sub(q_cinr_d).add(q_junc_bd).scale(m);
    const q_si_total = q_src_mapped.sub(q_sov).sub(q_cfr_s).sub(q_cinr_s).add(q_junc_bs).scale(m);
    const q_bi_total = q_bulk_intr.sub(q_bov).sub(q_junc_bs).sub(q_junc_bd).scale(m);

    // Thermal capacitance charge
    const q_dt = x[dt_idx].scale(p_cth);

    // ========================================================================
    // Output Charges
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d] = S.con(0.0);
    out[g] = S.con(0.0);
    out[s] = S.con(0.0);
    out[b] = S.con(0.0);
    out[gp] = q_gp_total;
    out[di] = q_di_total;
    out[si] = q_si_total;
    out[bi] = q_bi_total;
    out[bs] = q_junc_bs.scale(-m);
    out[bd] = q_junc_bd.scale(-m);
    out[dt_idx] = q_dt;
    return out;
}

// ============================================================================
// Voltage Limiting (DEVfetlim + DEVlimvds + DEVpnjlim)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const gp = @intFromEnum(U.gp);
    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);
    const bs = @intFromEnum(U.bs);
    const bd = @intFromEnum(U.bd);

    const type_f: f64 = @floatFromInt(model.type_);
    const p_vfb: f64 = @as(f64, model.vfb);
    const p_idsatrbot: f64 = @as(f64, model.idsatrbot);

    const temp: f64 = T0 + @as(f64, model.tr) + @as(f64, model.dta) + @as(f64, instance.trise);
    const vt: f64 = KB_OVER_Q * temp;

    // Critical voltage for PN junction limiting
    const is_jct = p_idsatrbot * @as(f64, instance.absource) + 1.0e-14;
    const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_jct));

    var result = x_new;

    // ========================================================================
    // DEVfetlim -- Gate-Source Voltage Limiting
    // ========================================================================
    {
        const vgs_new = (x_new[gp] - x_new[si]) * type_f;
        const vgs_old = (x_old[gp] - x_old[si]) * type_f;

        const vth0 = p_vfb + 0.6; // Approximate threshold
        const vtox = vth0 + 3.5;
        const vtsthi = @abs(2.0 * (vgs_old - vth0)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const delta_v = vgs_new - vgs_old;

        var vgs_lim = vgs_new;

        if (vgs_old >= vth0) {
            if (vgs_old >= vtox) {
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vgs_old - vtsthi);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            } else {
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vgs_old - vtstlo);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtstlo);
                }
            }
        } else {
            if (delta_v > 0.0 and vgs_new > vth0 + 0.5) {
                vgs_lim = vth0 + 0.5;
            } else if (delta_v <= 0.0) {
                vgs_lim = @max(vgs_new, vgs_old - vtstlo);
            } else {
                vgs_lim = @min(vgs_new, vgs_old + vtstlo);
            }
        }

        const delta_gs = (vgs_lim - vgs_new) * type_f;
        result[gp] += delta_gs;
    }

    // ========================================================================
    // DEVlimvds -- Drain-Source Voltage Limiting
    // ========================================================================
    {
        const vds_new = (result[di] - result[si]) * type_f;
        const vds_old = (x_old[di] - x_old[si]) * type_f;

        var vds_lim = vds_new;

        if (vds_old >= 3.5) {
            if (vds_new > vds_old) {
                vds_lim = @min(vds_new, 3.0 * vds_old + 2.0);
            } else if (vds_new < 3.5) {
                vds_lim = @max(vds_new, 2.0);
            }
        } else {
            if (vds_new > 4.0) {
                vds_lim = 4.0;
            } else if (vds_new < -0.5) {
                vds_lim = -0.5;
            }
        }

        const delta_ds = (vds_lim - vds_new) * type_f;
        result[di] += delta_ds;
    }

    // ========================================================================
    // DEVpnjlim -- Source-Bulk Junction Voltage Limiting
    // ========================================================================
    {
        const vbs_new = (x_new[bs] - result[si]) * type_f;
        const vbs_old = (x_old[bs] - x_old[si]) * type_f;

        var vbs_limited = vbs_new;
        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
                } else {
                    vbs_limited = vbs_old - vt * (2.0 + contract.fmath.log(@max(2.0 - arg, 1.0e-30)));
                }
            } else {
                vbs_limited = vt * contract.fmath.log(@max(vbs_new / vt, 1.0e-30));
            }
        }

        const delta_bs = (vbs_limited - vbs_new) * type_f;
        result[bs] += delta_bs;
    }

    // ========================================================================
    // DEVpnjlim -- Drain-Bulk Junction Voltage Limiting
    // ========================================================================
    {
        const vbd_new = (result[bd] - result[di]) * type_f;
        const vbd_old = (x_old[bd] - x_old[di]) * type_f;

        var vbd_limited = vbd_new;
        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
                } else {
                    vbd_limited = vbd_old - vt * (2.0 + contract.fmath.log(@max(2.0 - arg, 1.0e-30)));
                }
            } else {
                vbd_limited = vt * contract.fmath.log(@max(vbd_new / vt, 1.0e-30));
            }
        }

        const delta_bd = (vbd_limited - vbd_new) * type_f;
        result[di] -= delta_bd;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================
// GMIN stepping: at lambda=0 junction saturation currents are boosted;
// at lambda=1 they return to original values.

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;

    // Boost junction saturation currents
    const idsatrbot_orig: f64 = @as(f64, model.idsatrbot);
    m.idsatrbot = @floatCast(idsatrbot_orig + gmin_step * (1.0 - lambda));

    const idsatrsti_orig: f64 = @as(f64, model.idsatrsti);
    m.idsatrsti = @floatCast(idsatrsti_orig + gmin_step * (1.0 - lambda));

    const idsatrgat_orig: f64 = @as(f64, model.idsatrgat);
    m.idsatrgat = @floatCast(idsatrgat_orig + gmin_step * (1.0 - lambda));

    // Drain-side junction
    const idsatrbotd_orig: f64 = @as(f64, model.idsatrbotd);
    m.idsatrbotd = @floatCast(idsatrbotd_orig + gmin_step * (1.0 - lambda));

    const idsatrstid_orig: f64 = @as(f64, model.idsatrstid);
    m.idsatrstid = @floatCast(idsatrstid_orig + gmin_step * (1.0 - lambda));

    const idsatrgatd_orig: f64 = @as(f64, model.idsatrgatd);
    m.idsatrgatd = @floatCast(idsatrgatd_orig + gmin_step * (1.0 - lambda));

    return m;
}

// ============================================================================
// Sparse Conductance Pattern
// ============================================================================
// PSP touches: external-to-internal resistance paths + intrinsic MOSFET
// on {GP, DI, SI, BI} + junction nodes {BS, BD} + thermal {DT}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "psp: gate-resistance row is exact (value-form arithmetic)" {
    // With RG set, out[gate] = i_rg = (x[gate] - x[gp]) * (1/RG), independent
    // of the channel physics. RG = 100 -> g_rg = 0.01.
    const model: Model = .{ .rg = 100.0 };
    const inst: Instance = .{};
    var x: [n_u]f64 = [_]f64{0.0} ** n_u;
    x[@intFromEnum(U.gate)] = 2.0;
    x[@intFromEnum(U.gp)] = 0.5;
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // i_rg = (2.0 - 0.5) * 0.01 = 0.015
    try testing.expectApproxEqAbs(@as(f64, 0.015), out[@intFromEnum(U.gate)], 1e-9);
}

test "psp: bulk/well series-resistance row is exact" {
    // RBULK + RWELL = 200 + 300 = 500 -> g = 1/500 = 2e-3.
    // out[bulk] = -i_rbulk = -(x[bi]-x[b])*g.
    const model: Model = .{ .rbulk = 200.0, .rwell = 300.0 };
    const inst: Instance = .{};
    var x: [n_u]f64 = [_]f64{0.0} ** n_u;
    x[@intFromEnum(U.bi)] = 1.0;
    x[@intFromEnum(U.bulk)] = 0.0;
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // i_rbulk = (1.0 - 0.0) * 2e-3 = 2e-3 ; out[bulk] = -i_rbulk = -2e-3
    try testing.expectApproxEqAbs(@as(f64, -2e-3), out[@intFromEnum(U.bulk)], 1e-9);
}

test "psp: thermal capacitance charge is exact" {
    // q_dt = CTH * x[dt]. CTH = 1e-9, x[dt] = 3 -> 3e-9.
    const model: Model = .{ .cth = 1.0e-9 };
    const inst: Instance = .{};
    var x: [n_u]f64 = [_]f64{0.0} ** n_u;
    x[@intFromEnum(U.dt)] = 3.0;
    const out = contract.qValues(Self, x, &model, &inst, 0);
    // CTH is f32, so 1e-9 stores as ~9.9999999e-10; use a relative tolerance.
    try testing.expectApproxEqRel(@as(f64, 3.0e-9), out[@intFromEnum(U.dt)], 1e-6);
}

test "psp: JUNCAP source-junction forward current (on-state, from OLD formula)" {
    // Enable JUNCAP; forward-bias the source-bulk junction (v_bs_j = 0.5) with
    // the intrinsic bulk pinned to the same node so the RJUNS series current
    // i_rjuns = (x[bs]-x[bi])*g_rjuns = 0 and the BS row is exactly
    //   out[bs] = -i_junc_bs*type_f*m.
    // Only the 'bot' component contributes meaningfully (idsatrbot = 1e-6,
    // area = absource = 1e-12); sti/gat keep their tiny defaults.
    //
    // Expected value reproduced from the OLD juncapCurrent f64 formula at the
    // default operating temperature (t_kd = 273.15 + 21 = 294.15 K,
    // phi_t = KB/Q * t_kd = 0.02534767...), summing bot+sti+gat:
    //   bot = 1.446558330e-10, sti = gat = 5.00144156e-13
    //   i_junc_bs = (bot+sti+gat)*ifactor = 1.4565612132e-10
    //   out[bs] = -i_junc_bs = -1.4565612132e-10
    const model: Model = .{ .swjuncap = 1, .idsatrbot = 1.0e-6 };
    const inst: Instance = .{};
    var x: [n_u]f64 = [_]f64{0.0} ** n_u;
    x[@intFromEnum(U.bs)] = 0.5;
    x[@intFromEnum(U.bi)] = 0.5; // kill i_rjuns
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    // f32 param storage limits achievable precision; relative tol.
    try testing.expectApproxEqRel(@as(f64, -1.4565612132e-10), out[@intFromEnum(U.bs)], 1e-4);
}
