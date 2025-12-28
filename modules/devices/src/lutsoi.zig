const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// L-UTSOI 102.9.0 -- Ultra-thin Body SOI MOSFET (FDSOI)
//
// CEA-Leti compact model for Fully-Depleted Silicon-On-Insulator technologies
// with low-doped channel. Supports independent double-gate architectures,
// backplane depletion, asymmetric junctions, poly-depletion, edge transistors,
// NQS, self-heating, and cryogenic operation.
//
// Topology:
//   External: D (drain), G (gate), S (source), B (bulk/backplane)
//   Internal: dp (intrinsic drain, after Rd), sp (intrinsic source, after Rs),
//             gp (intrinsic gate, after Rg), tnode (thermal node for SHE)
//
//   D  -- Rd  -- dp
//   S  -- Rs  -- sp
//   G  -- Rg  -- gp
//   Channel: dp <-> sp (controlled by gp/B)
//   Self-heating: tnode (thermal RC)
// ============================================================================

pub const U = enum(u8) {
    drain, // 0 - external drain
    gate, // 1 - external gate
    source, // 2 - external source
    bulk, // 3 - external bulk/backplane
    drain_prime, // 4 - intrinsic drain (after Rd)
    source_prime, // 5 - intrinsic source (after Rs)
    gate_prime, // 6 - intrinsic gate (after Rg)
    tnode, // 7 - thermal node for self-heating
};
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================
const K_B: f64 = 1.3806488e-23;
const HBAR: f64 = 1.054571726e-34;
const Q_E: f64 = 1.602176565e-19;
const M_0: f64 = 9.10938291e-31;
const EPS_OX: f64 = 3.45313e-11;
const EPS_SI: f64 = 1.04479e-10;
const EG0_SI: f64 = 1.170;
const ALPHA_SI: f64 = 4.730e-4;
const BETA_SI: f64 = 636.0;
const EPS_GE: f64 = 1.43438e-10;
const EG0_GE: f64 = 0.744;
const ALPHA_GE: f64 = 4.774e-4;
const BETA_GE: f64 = 235.0;
const C_G: f64 = -0.4;
const NI_FACT_300: f64 = 4.05e25;
const QMN: f64 = 1.27520989;
const QMP: f64 = 1.54120870;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;

// ============================================================================
// Model Parameters
// ============================================================================
pub const Model = struct {
    // --- Device type and switches ---
    type_: i32 = 1, // +1=NMOS, -1=PMOS
    swscale: i32 = 1,
    version: f32 = 102.80,
    swsubdep: i32 = 0,
    swigate: i32 = 0,
    swgidl: i32 = 0,
    swshe: i32 = 0,
    swign: i32 = 0,
    swjunasym: i32 = 1,
    swimpact: i32 = 0,
    swpdep: i32 = 0,
    swcryo: i32 = 0,
    swqmod: i32 = 0,
    swedge: i32 = 0,
    qmc: f32 = 1.0,
    tr: f32 = 21.0,
    tmax: f32 = 150.0,
    dtemp: f32 = 0.0,

    // --- Scaling Parameters ---
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

    // --- Stress Model Parameters ---
    swstress: i32 = 1,
    saref: f32 = 1.0e-6,
    sbref: f32 = 1.0e-6,
    // SWSTRESS=1 (STI-Stress)
    wlod: f32 = 0.0,
    kuo: f32 = 0.0,
    kvsat: f32 = 0.0,
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
    // SWSTRESS=2 (Strained-SOI)
    strlambda: f32 = 1.0e-7,
    stralpha: f32 = 3.0,
    strdvfbo: f32 = 0.0,
    strwdvfbo: f32 = 0.0,
    strdcfl: f32 = 0.0,
    strruo: f32 = 0.0,
    strtruo: f32 = 0.0,
    strrvsat: f32 = 0.0,

    // --- Process Parameters ---
    toxeo: f32 = 2.0e-9,
    tsio: f32 = 1.0e-8,
    xgeo: f32 = 0.0,
    tboxo: f32 = 1.0e-7,
    ncho: f32 = 0.0,
    nsubo: f32 = 3.0e18,
    cto: f32 = 0.0,
    toxpo: f32 = 2.0e-9,
    novo: f32 = 1.0e20,
    novdo: f32 = 1.0e20,
    // VFB scaling
    vfbo: f32 = 0.0,
    vfbl: f32 = 0.0,
    vfblexp: f32 = 2.0,
    vfbl2: f32 = 0.0,
    vfblexp2: f32 = 2.0,
    vfbw: f32 = 0.0,
    vfblw: f32 = 0.0,
    // VFBB
    vfbbo: f32 = 0.0,
    vfblbo: f32 = 0.0,
    // STVFB
    stvfbo: f32 = 0.0,
    stvfbl: f32 = 0.0,
    stvfbw: f32 = 0.0,
    stvfblw: f32 = 0.0,
    // NP (poly doping)
    npo: f32 = 1.0e21,
    npl: f32 = 0.0,

    // --- Gate to Interface Coupling ---
    cicfo: f32 = 1.0,
    cico: f32 = 1.0,
    pscel: f32 = 0.0,
    pscelexp: f32 = 2.0,
    pscew: f32 = 0.0,
    pscebo: f32 = 1.0,
    nsddco: f32 = 1.0e22,
    pscedlbo: f32 = 0.0,
    pncew: f32 = 0.0,

    // --- DIBL Parameters ---
    cfl: f32 = 0.0,
    cflexp: f32 = 2.0,
    cfw: f32 = 0.0,
    cfbo: f32 = 1.0,
    stcfl: f32 = 0.0,
    cfdo: f32 = 0.2,
    cfdll: f32 = 0.0,
    cfdlw: f32 = 0.0,
    cfdlbo: f32 = 0.0,

    // --- Mobility Parameters ---
    uo: f32 = 0.05,
    fbet1: f32 = 0.0,
    fbet1w: f32 = 0.0,
    lp1: f32 = 1.0e-8,
    lp1w: f32 = 0.0,
    fbet2: f32 = 0.0,
    lp2: f32 = 1.0e-8,
    betw1: f32 = 0.0,
    betw2: f32 = 0.0,
    wbet: f32 = 0.05,
    betnbo: f32 = 1.0,
    stbeto: f32 = 1.5,
    stbetl: f32 = 0.0,
    stbetw: f32 = 0.0,
    stbetlw: f32 = 0.0,
    // Coulomb scattering
    cso: f32 = 0.0,
    csl: f32 = 0.0,
    cslexp: f32 = 1.0,
    csw: f32 = 0.0,
    cslw: f32 = 0.0,
    csfio: f32 = 0.0,
    csbio: f32 = 0.0,
    stcso: f32 = 0.0,
    stcsl: f32 = 0.0,
    stcsw: f32 = 0.0,
    stcslw: f32 = 0.0,
    thecso: f32 = 1.5,
    stthecso: f32 = 0.0,
    csthro: f32 = 2.0,
    csthrbo: f32 = 1.0,
    // High field mobility
    mueo: f32 = 0.0,
    stmueo: f32 = 0.0,
    themuo: f32 = 1.5,
    stthemuo: f32 = 0.0,
    // Non-universality
    xcoro: f32 = 0.0,
    xcorl: f32 = 0.0,
    xcorlexp: f32 = 1.0,
    xcorw: f32 = 0.0,
    xcorlw: f32 = 0.0,
    xcorbo: f32 = 1.0,
    stxcoro: f32 = 0.0,
    // Transverse field
    fetao: f32 = 1.0,

    // --- Series Resistance ---
    rsw1: f32 = 30.0,
    rsw2: f32 = 0.0,
    rsigo: f32 = 0.0,
    strso: f32 = 0.0,
    rsgo: f32 = 0.0,
    rsbo: f32 = 0.0,
    thersgo: f32 = 2.0,

    // --- Velocity Saturation ---
    thesato: f32 = 0.0,
    thesatl: f32 = 0.0,
    thesatlexp: f32 = 1.0,
    thesatw: f32 = 0.0,
    thesatlw: f32 = 0.0,
    stthesato: f32 = -0.1,
    stthesatl: f32 = 0.0,
    stthesatw: f32 = 0.0,
    stthesatlw: f32 = 0.0,
    thesatgo: f32 = 0.0,
    thesatbo: f32 = 0.0,

    // --- Saturation and CLM ---
    axo: f32 = 8.0,
    axl: f32 = 0.0,
    axlexp: f32 = 1.0,
    axl2: f32 = 0.0,
    axlexp2: f32 = 1.5,
    alpl1: f32 = 0.0,
    alplexp: f32 = 1.0,
    alpl2: f32 = 0.0,
    alplexp2: f32 = 2.0,
    alpw: f32 = 0.0,
    alp1l1: f32 = 0.0,
    alp1lexp: f32 = 0.5,
    alp1l2: f32 = 0.0,
    alp1lexp2: f32 = 1.5,
    alp1w: f32 = 0.0,
    alpbo: f32 = 0.0,
    vpo: f32 = 0.05,
    vpgo: f32 = 0.0,

    // --- Gate Current Parameters ---
    gcoo: f32 = 0.0,
    iginvlw: f32 = 0.0,
    igovinvw: f32 = 0.0,
    igovinvdw: f32 = 0.0,
    igovaccw: f32 = 0.0,
    igovaccdw: f32 = 0.0,
    stigo: f32 = 0.0,
    gc2cho: f32 = 0.375,
    gc3cho: f32 = 0.063,
    gc2ovinvo: f32 = 0.375,
    gc3ovinvo: f32 = 0.063,
    gc2ovacco: f32 = 0.375,
    gc3ovacco: f32 = 0.063,
    gcdovl: f32 = 0.0,
    gcvdovo: f32 = 1.0,
    chibo: f32 = 3.1,
    niginvo: f32 = 0.0,
    fnovinvw: f32 = 0.0,
    fnovinvdw: f32 = 0.0,
    gcovinvfno: f32 = 0.2,
    stigfno: f32 = 0.0,

    // --- GIDL/GISL Parameters ---
    agidlo: f32 = 0.0,
    agidlw: f32 = 0.0,
    agidldo: f32 = 0.0,
    agidldw: f32 = 0.0,
    bgidlo: f32 = 41.0,
    bgidldo: f32 = 41.0,
    stbgidlo: f32 = 0.0,
    stbgidldo: f32 = 0.0,
    cgidlo: f32 = 0.0,
    cgidldo: f32 = 0.0,
    dgidlo: f32 = 0.0,
    dgidll: f32 = 0.0,
    dgidldo: f32 = 0.0,
    dgidldl: f32 = 0.0,

    // --- Edge Transistor Parameters ---
    wedge: f32 = 1.0e-8,
    wedgew: f32 = 0.0,
    ctedgeo: f32 = 0.0,
    vfbedgeo: f32 = 0.0,
    vfbedgel: f32 = 0.0,
    vfbedgelexp: f32 = 2.0,
    vfbedgew: f32 = 0.0,
    vfbedgelw: f32 = 0.0,
    vfbbedgeo: f32 = 0.0,
    stvfbedgeo: f32 = 0.0,
    stvfbedgel: f32 = 0.0,
    stvfbedgew: f32 = 0.0,
    stvfbedgelw: f32 = 0.0,
    cicfedgeo: f32 = 1.0,
    cicedgeo: f32 = 1.0,
    psceedge: f32 = 0.0,
    psceedgel: f32 = 0.0,
    psceedgelexp: f32 = 2.0,
    psceedgew: f32 = 0.0,
    pscebedgeo: f32 = 1.0,
    cfedge: f32 = 0.0,
    cfedgel: f32 = 0.0,
    cfedgelexp: f32 = 2.0,
    cfedgew: f32 = 0.0,
    cfbedgeo: f32 = 1.0,
    cfdedgeo: f32 = 0.2,
    betnedge: f32 = 0.05,
    fbetedge: f32 = 0.0,
    lpedge: f32 = 1.0e-8,
    betedgew: f32 = 0.0,
    stbetedgeo: f32 = 1.5,
    stbetedgel: f32 = 0.0,
    stbetedgew: f32 = 0.0,
    stbetedgelw: f32 = 0.0,

    // --- Impact Ionization ---
    a1o: f32 = 1.0,
    a1l: f32 = 0.0,
    a1w: f32 = 0.0,
    a2o: f32 = 10.0,
    sta2o: f32 = 0.0,
    a3o: f32 = 1.0,
    a3l: f32 = 0.0,
    a3w: f32 = 0.0,

    // --- Charge Model Parameters ---
    areaq: f32 = 1.0e-12,
    cgbovo: f32 = 0.0,
    cgbovl: f32 = 0.0,
    nsdaco: f32 = 1.0e22,
    fifw: f32 = 0.0,
    fsceaco: f32 = 0.0,
    // VFBAC (for SWQMOD=1)
    vfbaco: f32 = 0.0,
    vfbacl: f32 = 0.0,
    vfbaclexp: f32 = 2.0,
    vfbacl2: f32 = 0.0,
    vfbaclexp2: f32 = 2.0,
    vfbacw: f32 = 0.0,
    vfbaclw: f32 = 0.0,
    vfbbaco: f32 = 0.0,
    vfblbaco: f32 = 0.0,
    // PSCEAC
    psceacl: f32 = 0.0,
    psceaclexp: f32 = 2.0,
    psceacw: f32 = 0.0,
    // CFAC
    cfacl: f32 = 0.0,
    cfaclexp: f32 = 2.0,
    cfacw: f32 = 0.0,
    // THESATAC
    thesataco: f32 = 0.0,
    thesatacl: f32 = 0.0,
    thesataclexp: f32 = 1.0,
    thesatacw: f32 = 0.0,
    thesataclw: f32 = 0.0,
    // AXAC
    axaco: f32 = 8.0,
    axacl: f32 = 0.0,
    axaclexp: f32 = 1.0,
    axacl2: f32 = 0.0,
    axaclexp2: f32 = 1.5,
    // ALPAC
    alpacl1: f32 = 0.0,
    alpaclexp: f32 = 1.0,
    alpacl2: f32 = 0.0,
    alpaclexp2: f32 = 2.0,
    alpacw: f32 = 0.0,
    // Overlap capacitances
    lovo: f32 = 0.0,
    lovdo: f32 = 0.0,
    covdlo: f32 = 0.0,
    covdlw: f32 = 0.0,
    covdlbo: f32 = 0.0,
    dvfbovo: f32 = 0.0,
    // Fringe capacitances
    cfro: f32 = 0.0,
    cfrw: f32 = 0.0,
    cfrdo: f32 = 0.0,
    cfrdw: f32 = 0.0,
    // Direct and substrate capacitances
    csdo: f32 = 1.0,
    csdbpo: f32 = 0.0,

    // --- Self-Heating Parameters ---
    rtho: f32 = 1.0e5,
    rthl: f32 = 1.5,
    rthw: f32 = 3.0,
    rthlw: f32 = 4.5,
    strtho: f32 = 0.0,
    ctho: f32 = 1.0e-12,
    lambtho: f32 = 1.0e-7,
    ftho: f32 = 0.0,

    // --- Noise Model Parameters ---
    fnto: f32 = 1.0,
    fntexc: f32 = 0.0,
    fntexcl: f32 = 0.0,
    fntexclexp: f32 = 2.0,
    nfalw: f32 = 8.0e22,
    nfaw: f32 = 0.0,
    nfblw: f32 = 3.0e7,
    nfclw: f32 = 0.0,
    nfeo: f32 = 0.0,
    nfebo: f32 = 0.0,
    efo: f32 = 1.0,

    // --- NQS Parameters ---
    kdrifto: f32 = 1.0,
    kdriftl: f32 = 0.0,
    kdiffo: f32 = 1.0,
    kdiffl: f32 = 0.0,
    fracinvo: f32 = 1.0,
    kfracinvo: f32 = 1.0e-15,

    // --- Cryogenic Parameters ---
    tmin: f32 = 1.0,
    atmin: f32 = 0.0,
    btmin: f32 = 1.0e-3,

    // --- Parasitic Resistance Parameters ---
    rgo: f32 = 0.0,
    rint: f32 = 0.0,
    rvpoly: f32 = 0.0,
    rshg: f32 = 0.0,
    dlsil: f32 = 0.0,
    rse: f32 = 0.0,
    rsh: f32 = 0.0,
    rde: f32 = 0.0,
    rshd: f32 = 0.0,
    rwello: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================
pub const Instance = struct {
    l: f32 = 1.0e-6,
    w: f32 = 1.0e-6,
    asource: f32 = 1.0e-12,
    adrain: f32 = 1.0e-12,
    psource: f32 = 1.0e-6,
    pdrain: f32 = 1.0e-6,
    sa: f32 = 0.0,
    sb: f32 = 0.0,
    sd: f32 = 0.0,
    nf: i32 = 1,
    mult: i32 = 1,
    mult_i: f32 = 1.0,
    mult_q: f32 = 1.0,
    mult_fn: f32 = 1.0,
    delvto: f32 = 0.0,
    factuo: f32 = 1.0,
    ngcon: i32 = 1,
    xgw: f32 = 1.0e-7,
    nrs: f32 = 0.0,
    nrd: f32 = 0.0,
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================
pub const g_pattern_override = [_]contract.Entry(n_u){
    // Rd: drain -- drain_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    // Rs: source -- source_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    // Rg: gate -- gate_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate) },
    // Channel: dp -- sp (controlled by gp, B)
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
    // Gate current: gp to dp, sp
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.bulk) },
    // Bulk interactions (impact ionization, GIDL/GISL, substrate capacitance)
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate_prime) },
    // Self-heating: tnode
    .{ .row = @intFromEnum(U.tnode), .col = @intFromEnum(U.tnode) },
    .{ .row = @intFromEnum(U.tnode), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.tnode), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.tnode), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.tnode), .col = @intFromEnum(U.bulk) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================
pub const c_pattern_override = [_]contract.Entry(n_u){
    // Intrinsic charges: gp, dp, sp, B
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    // Thermal capacitance
    .{ .row = @intFromEnum(U.tnode), .col = @intFromEnum(U.tnode) },
};

// ============================================================================
// Noise Sources
// ============================================================================
pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: dp -- sp
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel flicker noise: dp -- sp
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Gate shot noise: gp -- sp
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Gate shot noise: gp -- dp
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime), .kind = .shot },
    // GIDL/GISL shot noise: dp -- sp
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Avalanche noise (Eq 4.558): dp -- sp
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Source resistance thermal: source -- source_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Drain resistance thermal: drain -- drain_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Gate resistance thermal: gate -- gate_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime), .kind = .thermal },
};

// ============================================================================
// Branchless helpers
// ============================================================================
inline fn safe_exp(x: f64) f64 {
    return contract.fmath.exp(@min(x, 80.0));
}

inline fn safe_log(x: f64) f64 {
    return contract.fmath.log(@max(x, 1e-38));
}

/// Smooth minimum: 0.5*(x+y-sqrt((x-y)^2+a))
inline fn min_func(x: f64, y: f64, a: f64) f64 {
    const diff = x - y;
    return 0.5 * (x + y - @sqrt(diff * diff + a));
}

/// Smooth maximum: 0.5*(x+y+sqrt((x-y)^2+a))
inline fn max_func(x: f64, y: f64, a: f64) f64 {
    const diff = x - y;
    return 0.5 * (x + y + @sqrt(diff * diff + a));
}

/// Lambert W0 approximation (Eq C.8)
inline fn lambertW0(x: f64) f64 {
    const ln1px = safe_log(1.0 + x);
    const ln_ln1px = safe_log(1.0 + ln1px);
    return ln1px * (1.0 - ln_ln1px / (2.0 + ln1px));
}

/// CHARGE_DENSITY: Compute front gate charge density q1 for given
/// normalized gate voltages xg1, xg2 and quasi-Fermi level delta_n.
/// This is the surface potential solver (Appendix A).
inline fn chargeDensity(
    xg1: f64,
    xg2: f64,
    delta_n: f64,
    k1: f64,
    k2: f64,
    a0: f64,
) f64 {
    // Initial guess: smooth between weak and strong inversion
    const x_sat = @max(xg1, 0.0);
    const x_weak = safe_log(1.0 + safe_exp(@min(xg1, 40.0)));

    // Use xg2 contribution through coupling
    const xg2_eff = @max(xg2, -40.0);
    const q2_est = safe_log(1.0 + safe_exp(@min(xg2_eff, 40.0)));

    // Blended initial guess
    const qi_init = @sqrt(x_weak * x_weak + 0.01);
    var q1 = if (xg1 > 10.0) x_sat else qi_init;

    // Compute q2 from xg2 coupling
    const q2 = q2_est;
    _ = q2;

    // Newton-Halley iterations (4 global corrections per spec)
    var iter: u32 = 0;
    while (iter < 5) : (iter += 1) {
        // f(q1) = qi_int * f_en - A0 * exp(xg1 - q1 - delta_n)
        const qi_int = k1 * q1 + k2 * q2_est;
        const f_en = @max(qi_int, 1e-30);
        const exp_term = a0 * safe_exp(xg1 - q1 - delta_n);
        const f_zero = f_en - exp_term;

        // First derivative
        const d1 = k1 + exp_term;
        // Second derivative
        const d2 = -exp_term;

        // Halley update: eps = -f * d1 * d_temp / (d_temp^2 + 1e-200)
        const d_temp = d1 * d1 - 0.5 * f_zero * d2;
        const eps = -f_zero * d1 * d_temp / (d_temp * d_temp + 1e-200);
        q1 = q1 + @min(@max(eps, -2.0), 2.0);
        q1 = @max(q1, 0.0);
    }

    return q1;
}

// ============================================================================
// Value-form (S) helpers -- mirror the f64 branchless helpers above but keep
// the derivative flowing. Used only on x-dependent chains.
// ============================================================================
/// safe_exp on S: contract.fmath.exp(@min(x, 80)). minC clamps the argument (derivative
/// goes flat past 80, matching the f64 saturation).
inline fn sExp(comptime S: type, x: S) S {
    return x.minC(80.0).exp();
}

/// safe_log on S: contract.fmath.log(@max(x, 1e-38)).
inline fn sLog(comptime S: type, x: S) S {
    return x.maxC(1e-38).log();
}

/// Smooth minimum: 0.5*(x+y-sqrt((x-y)^2+a)). y is a plain-f64 bound here.
inline fn sMinF(comptime S: type, x: S, y: f64, a: f64) S {
    const diff = x.addC(-y);
    const root = diff.mul(diff).addC(a).sqrt();
    return x.addC(y).sub(root).scale(0.5);
}

/// Smooth maximum: 0.5*(x+y+sqrt((x-y)^2+a)). y is a plain-f64 bound here.
inline fn sMaxF(comptime S: type, x: S, y: f64, a: f64) S {
    const diff = x.addC(-y);
    const root = diff.mul(diff).addC(a).sqrt();
    return x.addC(y).add(root).scale(0.5);
}

/// CHARGE_DENSITY on S: surface-potential Newton-Halley solver (Appendix A).
/// xg1, xg2 are S (x-dependent); k1, k2, a0, delta_n are plain f64.
/// Mirrors chargeDensity() exactly, in S ops.  The initial-guess region
/// select branches on xg1.val() (matches the f64 `if (xg1 > 10.0)`), then
/// each branch is computed in S so the picked path carries derivatives.
inline fn sChargeDensity(
    comptime S: type,
    xg1: S,
    xg2: S,
    delta_n: f64,
    k1: f64,
    k2: f64,
    a0: f64,
) S {
    // x_weak = safe_log(1 + safe_exp(min(xg1, 40)))
    const x_weak = sLog(S, sExp(S, xg1.minC(40.0)).addC(1.0));
    // xg2_eff = max(xg2, -40); q2_est = safe_log(1 + safe_exp(min(xg2_eff, 40)))
    const xg2_eff = xg2.maxC(-40.0);
    const q2_est = sLog(S, sExp(S, xg2_eff.minC(40.0)).addC(1.0));

    // qi_init = sqrt(x_weak^2 + 0.01)
    const qi_init = x_weak.mul(x_weak).addC(0.01).sqrt();
    // x_sat = max(xg1, 0)
    const x_sat = xg1.maxC(0.0);
    var q1: S = if (xg1.val() > 10.0) x_sat else qi_init;

    const q2 = q2_est;

    var iter: u32 = 0;
    while (iter < 5) : (iter += 1) {
        // qi_int = k1*q1 + k2*q2_est ; f_en = max(qi_int, 1e-30)
        const qi_int = q1.scale(k1).add(q2.scale(k2));
        const f_en = qi_int.maxC(1e-30);
        // exp_term = a0 * safe_exp(xg1 - q1 - delta_n)
        const exp_arg = xg1.sub(q1).addC(-delta_n);
        const exp_term = sExp(S, exp_arg).scale(a0);
        const f_zero = f_en.sub(exp_term);

        // d1 = k1 + exp_term ; d2 = -exp_term
        const d1 = exp_term.addC(k1);
        const d2 = exp_term.neg();

        // d_temp = d1*d1 - 0.5*f_zero*d2
        const d_temp = d1.mul(d1).sub(f_zero.mul(d2).scale(0.5));
        // eps = -f_zero*d1*d_temp / (d_temp^2 + 1e-200)
        const eps_num = f_zero.mul(d1).mul(d_temp).neg();
        const eps_den = d_temp.mul(d_temp).addC(1e-200);
        const eps = eps_num.div(eps_den);
        // q1 = q1 + clamp(eps, -2, 2) ; q1 = max(q1, 0)
        q1 = q1.add(eps.maxC(-2.0).minC(2.0)).maxC(0.0);
    }

    return q1;
}

// ============================================================================
// Prep: x-independent derived values cached across eval/q calls
// ============================================================================

const DcPrep = struct {
    // Fundamental
    type_f: f64,
    multf: f64,
    mult_i: f64,
    // Geometry
    l_e: f64,
    w_e: f64,
    le_ratio: f64,
    we_ratio: f64,
    // VFB
    vfb_val: f64,
    vfbb_val: f64,
    stvfb_val: f64,
    vfbl_term: f64,
    vfbl2_denom: f64,
    // Coupling
    cicf: f64,
    cic: f64,
    eps_ch: f64,
    lambda_2d: f64,
    psce: f64,
    psceb: f64,
    pscedlb: f64,
    // DIBL
    cf_val: f64,
    cfb_val: f64,
    cfd_val: f64,
    stcf_val: f64,
    cfdl_val: f64,
    cfdlb: f64,
    // Mobility
    betn: f64,
    ge_val: f64,
    stbet: f64,
    // Velocity saturation
    thesat_val: f64,
    stthesat: f64,
    // CLM
    ax_clamped: f64,
    gamma_ax: f64,
    alp_clamped: f64,
    alp1_val: f64,
    // Misc
    vp_val: f64,
    vpg_val: f64,
    alpb_val: f64,
    rs_val: f64,
    strso: f64,
    cs_val: f64,
    stcs_val: f64,
    xcor_val: f64,
    stxcor: f64,
    feta: f64,
    csfi: f64,
    csbi: f64,
    csthr: f64,
    csthrb: f64,
    xcorb: f64,
    thesatg: f64,
    thesatb: f64,
    pnce_body_factor: f64,
    // Gate current
    b_ch: f64,
    // Temperature base
    t_kr: f64,
    t_kd: f64,
};

fn dcPrep(model: *const Model, instance: *const Instance) DcPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const nf_f: f64 = @floatFromInt(instance.nf);
    const mult_f: f64 = @floatFromInt(instance.mult);
    const mult_i: f64 = @as(f64, instance.mult_i);
    const multf = mult_f * nf_f;
    const l_draw: f64 = @as(f64, instance.l);
    const w_draw: f64 = @as(f64, instance.w);
    const wf = w_draw / nf_f;

    const l_en: f64 = 1.0e-6;
    const w_en: f64 = 1.0e-6;

    // Effective dimensions
    const lvaro: f64 = @as(f64, model.lvaro);
    const lvarl: f64 = @as(f64, model.lvarl);
    const lvarw: f64 = @as(f64, model.lvarw);
    const delta_lps = lvaro * (1.0 + lvarl * l_en / l_draw) * (1.0 + lvarw * w_en / wf);

    const wvaro: f64 = @as(f64, model.wvaro);
    const wvarl: f64 = @as(f64, model.wvarl);
    const wvarw: f64 = @as(f64, model.wvarw);
    const delta_wod = wvaro * (1.0 + wvarl * l_en / l_draw) * (1.0 + wvarw * w_en / wf);

    const lap: f64 = @as(f64, model.lap);
    const wot: f64 = @as(f64, model.wot);
    const l_e = @max(l_draw + delta_lps - 2.0 * lap, 1.0e-9);
    const w_e = @max(wf + delta_wod - 2.0 * wot, 1.0e-9);
    const le_ratio = l_en / l_e;
    const we_ratio = w_en / w_e;

    // Process parameters
    const toxe: f64 = @as(f64, model.toxeo);
    const tsi: f64 = @as(f64, model.tsio);
    const xge: f64 = @as(f64, model.xgeo);
    const tbox: f64 = @as(f64, model.tboxo);
    const toxp: f64 = @as(f64, model.toxpo);

    // VFB scaling
    const vfbl: f64 = @as(f64, model.vfbl);
    const vfblexp: f64 = @as(f64, model.vfblexp);
    const vfbl2: f64 = @as(f64, model.vfbl2);
    const vfblexp2: f64 = @as(f64, model.vfblexp2);
    const vfbl_term = vfbl * contract.fmath.exp(vfblexp * safe_log(le_ratio));
    const vfbl2_denom = 1.0 + vfbl2 * contract.fmath.exp(vfblexp2 * safe_log(le_ratio));
    const vfb_val = @as(f64, model.vfbo) + vfbl_term / @max(vfbl2_denom, 1e-30) + @as(f64, model.vfbw) * we_ratio + @as(f64, model.vfblw) * le_ratio * we_ratio + @as(f64, instance.delvto);

    const vfbb_val = @as(f64, model.vfbbo) + @as(f64, model.vfblbo) * (tbox / toxe) * vfbl_term / @max(vfbl2_denom, 1e-30);

    const stvfb_val = @as(f64, model.stvfbo) * (1.0 + @as(f64, model.stvfbl) * le_ratio) * (1.0 + @as(f64, model.stvfbw) * we_ratio) * (1.0 + @as(f64, model.stvfblw) * le_ratio * we_ratio);

    // Coupling
    const cicf: f64 = @as(f64, model.cicfo);
    const cic: f64 = @as(f64, model.cico);
    const eps_ch = EPS_SI * (1.0 - xge) + EPS_GE * xge;
    const lambda_2d = @sqrt(eps_ch / EPS_OX * tsi * (toxe + 4.0e-10));

    // PSCE
    const pscel: f64 = @as(f64, model.pscel);
    const pscelexp: f64 = @as(f64, model.pscelexp);
    const pscew: f64 = @as(f64, model.pscew);
    const psce = 2.0 * pscel * contract.fmath.exp(pscelexp * safe_log(lambda_2d / l_e)) * (1.0 + pscew * we_ratio);
    const psceb: f64 = @as(f64, model.pscebo);
    const pscedlb: f64 = @as(f64, model.pscedlbo);

    // DIBL
    const cfl_val: f64 = @as(f64, model.cfl);
    const cflexp_val: f64 = @as(f64, model.cflexp);
    const cfw_val: f64 = @as(f64, model.cfw);
    const cf_val = cfl_val * contract.fmath.exp(cflexp_val * safe_log(lambda_2d / l_e)) * (1.0 + cfw_val * we_ratio);
    const cfb_val: f64 = @as(f64, model.cfbo);
    const cfd_val: f64 = @as(f64, model.cfdo);
    const stcfl: f64 = @as(f64, model.stcfl);
    const stcf_val = stcfl * contract.fmath.exp(cflexp_val * safe_log(lambda_2d / l_e)) * (1.0 + cfw_val * we_ratio);
    const cfdll: f64 = @as(f64, model.cfdll);
    const cfdlw: f64 = @as(f64, model.cfdlw);
    const cfdl_val = cfdll * le_ratio * (1.0 + cfdlw * we_ratio);
    const cfdlb: f64 = @as(f64, model.cfdlbo);

    // Mobility scaling
    const uo: f64 = @as(f64, model.uo);
    const fbet1: f64 = @as(f64, model.fbet1);
    const fbet1w: f64 = @as(f64, model.fbet1w);
    const lp1_raw: f64 = @as(f64, model.lp1);
    const lp1w: f64 = @as(f64, model.lp1w);
    const fbet2: f64 = @as(f64, model.fbet2);
    const lp2: f64 = @as(f64, model.lp2);
    const betw1: f64 = @as(f64, model.betw1);
    const betw2: f64 = @as(f64, model.betw2);
    const wbet: f64 = @as(f64, model.wbet);

    const lp1_eff = lp1_raw * @max(1.0 + lp1w * we_ratio, 1.0e-3);
    const le_lp1 = l_e / lp1_eff;
    const le_lp2 = l_e / lp2;
    const fbet1_eff = fbet1 * (1.0 + fbet1w * we_ratio);
    const gpe_term1 = if (le_lp1 > 1e-20) fbet1_eff * (1.0 - safe_exp(-le_lp1)) / le_lp1 else fbet1_eff;
    const gpe_term2 = if (le_lp2 > 1e-20) fbet2 * (1.0 - safe_exp(-le_lp2)) / le_lp2 else fbet2;
    const gpe = @max(1.0 + gpe_term1 + gpe_term2, 1.0e-6);
    const gwe = @max(1.0 + betw1 * we_ratio + betw2 * we_ratio * safe_log(1.0 + w_e / wbet), 1.0e-6);
    const ge_val = uo * gwe / gpe;
    const betn = ge_val * w_e / l_e;

    const stbeto: f64 = @as(f64, model.stbeto);
    const stbetl: f64 = @as(f64, model.stbetl);
    const stbetw: f64 = @as(f64, model.stbetw);
    const stbetlw: f64 = @as(f64, model.stbetlw);
    const stbet = stbeto * (1.0 + stbetl * le_ratio) * (1.0 + stbetw * we_ratio) * (1.0 + stbetlw * le_ratio * we_ratio);

    // Velocity saturation
    const thesato: f64 = @as(f64, model.thesato);
    const thesatl: f64 = @as(f64, model.thesatl);
    const thesatlexp: f64 = @as(f64, model.thesatlexp);
    const thesatw: f64 = @as(f64, model.thesatw);
    const thesatlw: f64 = @as(f64, model.thesatlw);
    const thesat_val = ge_val * (thesato + thesatl * contract.fmath.exp(thesatlexp * safe_log(le_ratio))) * (1.0 + thesatw * we_ratio) * (1.0 + thesatlw * le_ratio * we_ratio);

    const stthesato: f64 = @as(f64, model.stthesato);
    const stthesatl: f64 = @as(f64, model.stthesatl);
    const stthesatw: f64 = @as(f64, model.stthesatw);
    const stthesatlw: f64 = @as(f64, model.stthesatlw);
    const stthesat = stthesato * (1.0 + stthesatl * le_ratio) * (1.0 + stthesatw * we_ratio) * (1.0 + stthesatlw * le_ratio * we_ratio);

    // CLM
    const axo: f64 = @as(f64, model.axo);
    const axl: f64 = @as(f64, model.axl);
    const axlexp: f64 = @as(f64, model.axlexp);
    const axl2: f64 = @as(f64, model.axl2);
    const axlexp2: f64 = @as(f64, model.axlexp2);
    const ax_val = axo / ((1.0 + axl * contract.fmath.exp(axlexp * safe_log(le_ratio))) * (1.0 + axl2 * contract.fmath.exp(axlexp2 * safe_log(le_ratio))));
    const ax_clamped = @max(@min(ax_val, 16.0), 1.0);

    const alpl1: f64 = @as(f64, model.alpl1);
    const alplexp: f64 = @as(f64, model.alplexp);
    const alpl2: f64 = @as(f64, model.alpl2);
    const alplexp2: f64 = @as(f64, model.alplexp2);
    const alpw: f64 = @as(f64, model.alpw);
    const alp_val = (alpl1 * contract.fmath.exp(alplexp * safe_log(le_ratio)) + alpl2 * contract.fmath.exp(alplexp2 * safe_log(le_ratio))) * (1.0 + alpw * we_ratio);
    const alp_clamped = @max(alp_val, 0.0);

    const alp1l1: f64 = @as(f64, model.alp1l1);
    const alp1lexp: f64 = @as(f64, model.alp1lexp);
    const alp1l2: f64 = @as(f64, model.alp1l2);
    const alp1lexp2: f64 = @as(f64, model.alp1lexp2);
    const alp1w: f64 = @as(f64, model.alp1w);
    const alp1_val = @max((alp1l1 * contract.fmath.exp(alp1lexp * safe_log(le_ratio)) + alp1l2 * contract.fmath.exp(alp1lexp2 * safe_log(le_ratio))) * (1.0 + alp1w * we_ratio), 0.0);

    const vp_val: f64 = @as(f64, model.vpo);
    const vpg_val: f64 = @as(f64, model.vpgo);
    const alpb_val: f64 = @as(f64, model.alpbo);

    // Series resistance
    const rsw1: f64 = @as(f64, model.rsw1);
    const rsw2: f64 = @as(f64, model.rsw2);
    const rs_val = rsw1 / @max(w_e, 1e-9) * (1.0 + rsw2 * w_en / @max(w_e, 1e-9));
    const strso: f64 = @as(f64, model.strso);

    // Coulomb scattering
    const cso: f64 = @as(f64, model.cso);
    const csl: f64 = @as(f64, model.csl);
    const cslexp: f64 = @as(f64, model.cslexp);
    const csw: f64 = @as(f64, model.csw);
    const cslw: f64 = @as(f64, model.cslw);
    const cs_val = cso * (1.0 + csl * contract.fmath.exp(cslexp * safe_log(le_ratio))) * (1.0 + csw * we_ratio) * (1.0 + cslw * le_ratio * we_ratio);

    const stcso: f64 = @as(f64, model.stcso);
    const stcsl: f64 = @as(f64, model.stcsl);
    const stcsw: f64 = @as(f64, model.stcsw);
    const stcslw: f64 = @as(f64, model.stcslw);
    const stcs_val = stcso * (1.0 + stcsl * le_ratio) * (1.0 + stcsw * we_ratio) * (1.0 + stcslw * le_ratio * we_ratio);

    const xcoro: f64 = @as(f64, model.xcoro);
    const xcorl: f64 = @as(f64, model.xcorl);
    const xcorlexp: f64 = @as(f64, model.xcorlexp);
    const xcorw: f64 = @as(f64, model.xcorw);
    const xcorlw: f64 = @as(f64, model.xcorlw);
    const xcor_val = xcoro * (1.0 + xcorl * contract.fmath.exp(xcorlexp * safe_log(le_ratio))) * (1.0 + xcorw * we_ratio) * (1.0 + xcorlw * le_ratio * we_ratio);

    const stxcor: f64 = @as(f64, model.stxcoro);
    const feta: f64 = @as(f64, model.fetao);
    const csfi: f64 = @as(f64, model.csfio);
    const csbi: f64 = @as(f64, model.csbio);
    const csthr: f64 = @as(f64, model.csthro);
    const csthrb: f64 = @as(f64, model.csthrbo);
    const xcorb: f64 = @as(f64, model.xcorbo);
    const thesatg: f64 = @as(f64, model.thesatgo);
    const thesatb: f64 = @as(f64, model.thesatbo);

    // PNCE narrow channel
    const pncew_val: f64 = @as(f64, model.pncew);
    const pnce_body_factor = 1.0 + pncew_val * we_ratio;

    // CLM gamma
    const ax_eff = @max(ax_clamped, 1.001);
    const gamma_ax_base = contract.fmath.exp(0.375 * safe_log(216.0 / ax_eff - 1.0));
    const gamma_ax = gamma_ax_base - 1.0;

    // Gate current
    const chib: f64 = @as(f64, model.chibo);
    const b_ch = (4.0 / 3.0) * @sqrt(2.0 * Q_E * M_0 * chib) / HBAR * toxp;

    // Temperature base
    const tr: f64 = @as(f64, model.tr);
    const dtemp: f64 = @as(f64, model.dtemp);
    const t_kr = 273.15 + tr;
    const t_kd_raw = 273.15 + 27.0 + dtemp;
    const tmin: f64 = @as(f64, model.tmin);
    const atmin: f64 = @as(f64, model.atmin);
    const btmin: f64 = @as(f64, model.btmin);
    const t_kd = if (model.swcryo == 1) max_func(t_kd_raw, tmin + atmin * t_kd_raw, btmin) else max_func(t_kd_raw, 1.0, 1.0e-3);

    return .{
        .type_f = type_f, .multf = multf, .mult_i = mult_i,
        .l_e = l_e, .w_e = w_e, .le_ratio = le_ratio, .we_ratio = we_ratio,
        .vfb_val = vfb_val, .vfbb_val = vfbb_val, .stvfb_val = stvfb_val,
        .vfbl_term = vfbl_term, .vfbl2_denom = vfbl2_denom,
        .cicf = cicf, .cic = cic, .eps_ch = eps_ch, .lambda_2d = lambda_2d,
        .psce = psce, .psceb = psceb, .pscedlb = pscedlb,
        .cf_val = cf_val, .cfb_val = cfb_val, .cfd_val = cfd_val,
        .stcf_val = stcf_val, .cfdl_val = cfdl_val, .cfdlb = cfdlb,
        .betn = betn, .ge_val = ge_val, .stbet = stbet,
        .thesat_val = thesat_val, .stthesat = stthesat,
        .ax_clamped = ax_clamped, .gamma_ax = gamma_ax,
        .alp_clamped = alp_clamped, .alp1_val = alp1_val,
        .vp_val = vp_val, .vpg_val = vpg_val, .alpb_val = alpb_val,
        .rs_val = rs_val, .strso = strso,
        .cs_val = cs_val, .stcs_val = stcs_val,
        .xcor_val = xcor_val, .stxcor = stxcor,
        .feta = feta, .csfi = csfi, .csbi = csbi,
        .csthr = csthr, .csthrb = csthrb, .xcorb = xcorb,
        .thesatg = thesatg, .thesatb = thesatb,
        .pnce_body_factor = pnce_body_factor,
        .b_ch = b_ch,
        .t_kr = t_kr, .t_kd = t_kd,
    };
}

pub const PrepCache = DcPrep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return dcPrep(model, instance);
}

// ============================================================================
// Physics: Current Contributions (value-form eval)
// ============================================================================
pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const p = pc;

    // Read precomputed x-independent values from DcPrep
    const type_f = p.type_f;
    const multf = p.multf;
    const mult_i = p.mult_i;
    const l_e = p.l_e;
    const w_e = p.w_e;
    const le_ratio = p.le_ratio;
    const we_ratio = p.we_ratio;
    const vfb_val = p.vfb_val;
    const vfbb_val = p.vfbb_val;
    const stvfb_val = p.stvfb_val;
    const cicf = p.cicf;
    const cic = p.cic;
    const eps_ch_val = p.eps_ch;
    const lambda_2d = p.lambda_2d;
    const psce = p.psce;
    const psceb = p.psceb;
    const pscedlb = p.pscedlb;
    const cf_val = p.cf_val;
    const cfb_val = p.cfb_val;
    const cfd_val = p.cfd_val;
    const stcf_val = p.stcf_val;
    const cfdl_val = p.cfdl_val;
    const cfdlb = p.cfdlb;
    const betn = p.betn;
    const ge_val = p.ge_val;
    _ = ge_val;
    const stbet = p.stbet;
    const thesat_val = p.thesat_val;
    const stthesat = p.stthesat;
    const ax_clamped = p.ax_clamped;
    _ = ax_clamped;
    const gamma_ax = p.gamma_ax;
    const alp_clamped = p.alp_clamped;
    const alp1_val = p.alp1_val;
    const vp_val = p.vp_val;
    const vpg_val = p.vpg_val;
    const alpb_val = p.alpb_val;
    const rs_val = p.rs_val;
    const strso = p.strso;
    const cs_val = p.cs_val;
    const stcs_val = p.stcs_val;
    const xcor_val = p.xcor_val;
    const stxcor = p.stxcor;
    const feta = p.feta;
    const csfi = p.csfi;
    const csbi = p.csbi;
    const csthr = p.csthr;
    const csthrb = p.csthrb;
    const xcorb = p.xcorb;
    const thesatg = p.thesatg;
    const thesatb = p.thesatb;
    const pnce_body_factor = p.pnce_body_factor;
    const b_ch = p.b_ch;
    const t_kr = p.t_kr;
    const t_kd = p.t_kd;

    // Cast remaining model params used in temperature-dependent section
    const toxe: f64 = @as(f64, model.toxeo);
    const tsi: f64 = @as(f64, model.tsio);
    const xge: f64 = @as(f64, model.xgeo);
    const tbox: f64 = @as(f64, model.tboxo);
    const ct: f64 = @as(f64, model.cto);
    const factuo: f64 = @as(f64, instance.factuo);
    const betnb: f64 = @as(f64, model.betnbo);

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);
    const b = @intFromEnum(U.bulk);
    const d_ext = @intFromEnum(U.drain);
    const s_ext = @intFromEnum(U.source);
    const g_ext = @intFromEnum(U.gate);
    const tn = @intFromEnum(U.tnode);

        // Self-heating: delta_T from thermal node.
    // NOTE: the temperature-dependent parameter prep below stays f64, so the
    // self-heating temperature is read as a plain value here (its derivative
    // w.r.t. the tnode unknown is not propagated into the param prep). The
    // thermal-node residual itself is still built in S below so its diagonal
    // and the dp/sp power-dissipation coupling carry their Jacobian entries.
    const delta_tc = if (model.swshe == 1) @min(x[tn].val(), @as(f64, model.tmax)) else 0.0;
    const t_kc = t_kd + delta_tc;
    const delta_t = t_kc - t_kr;

    // Thermal voltage (Eq 4.6)
    const phi_t0 = K_B * t_kc / Q_E;

    // ========================================================================
    // 4.1.2 Local Process Parameters
    // ========================================================================
    // Bandgap (Eqs 4.9-4.12)
    const eg_si = EG0_SI - ALPHA_SI * t_kc * t_kc / (BETA_SI + t_kc);
    const eg_ge = EG0_GE - ALPHA_GE * t_kc * t_kc / (BETA_GE + t_kc);
    const delta_eg = (eg_ge - eg_si + C_G * (1.0 - xge)) * xge;
    const eg = eg_si + delta_eg;

    // Intrinsic concentration (Eq 4.13)
    const n_eff = NI_FACT_300 / @sqrt(1.0 + 10.0 * xge) * contract.fmath.exp(1.5 * safe_log(t_kc / 300.0));
    _ = n_eff;

    // ========================================================================
    // 4.1.3 Interface Coupling Internal Parameters
    // ========================================================================
    const cox1 = EPS_OX / toxe;
    const cox2 = EPS_OX / tbox;
    const csi0 = eps_ch_val / tsi;

    // phi_T (Eq 4.20)
    const phi_t = phi_t0 * (1.0 + ct * t_kr / t_kc);

    // Coupling coefficients (Eqs 4.21-4.23)
    const k1_1d = cox1 / csi0;
    const k2_1d = cox2 / csi0;
    const k_eq_1d = 1.0 / (1.0 + 1.0 / k1_1d + 1.0 / k2_1d);
    _ = k_eq_1d;

    // Apply CICF / CIC to k1, k2 with PNCE narrow channel correction
    const k1 = k1_1d * cicf * pnce_body_factor;
    const k2 = k2_1d * cic * pnce_body_factor;
    const a0 = contract.fmath.exp(-eg / (2.0 * phi_t0));

    // ========================================================================
    // 4.1.4 DIBL Internal Parameters (Eqs 4.29-4.31)
    // ========================================================================
    const cf1 = cf_val + stcf_val * delta_t;
    const cf2 = cf_val * cfb_val * (tbox / toxe) + stcf_val * delta_t;
    const x_d0 = cfd_val / phi_t;

    // ========================================================================
    // 4.1.8 Mobility Internal Parameters (Eqs 4.47-4.49)
    // ========================================================================
    const t_ratio = t_kr / t_kc;
    const beta_n1 = betn * contract.fmath.exp(stbet * safe_log(t_ratio));
    const beta_n2 = betn * betnb * contract.fmath.exp(stbet * safe_log(t_ratio));

    // MUE temperature (Eq 4.49)
    const mue: f64 = @as(f64, model.mueo);
    const stmue: f64 = @as(f64, model.stmueo);
    const mu_e = mue * contract.fmath.exp(stmue * safe_log(t_ratio));

    // THEMU temperature
    const themu: f64 = @as(f64, model.themuo);
    const stthemu: f64 = @as(f64, model.stthemuo);
    const the_mu = themu * contract.fmath.exp(stthemu * safe_log(t_ratio));

    // THECS temperature
    const thecs: f64 = @as(f64, model.thecso);
    const stthecs: f64 = @as(f64, model.stthecso);
    const the_cs = thecs * contract.fmath.exp(stthecs * safe_log(t_ratio));

    // CS temperature
    const cs_temp = cs_val * contract.fmath.exp(stcs_val * safe_log(t_ratio));

    // XCOR temperature
    const xcor_temp = xcor_val * contract.fmath.exp(stxcor * safe_log(t_ratio));

    // ========================================================================
    // 4.1.10 Velocity Saturation Internal Parameters (Eqs 4.60-4.61)
    // ========================================================================
    const theta_sat = factuo * thesat_val * contract.fmath.exp((stthesat + stbet) * safe_log(t_ratio));
    const f_vsat = phi_t * theta_sat;

    // ========================================================================
    // 4.1.12 Gate Current Internal Parameters
    // ========================================================================
    // alpha_b (Eq 4.76) -- half-bandgap used in gate current energy normalization
    const alpha_b = eg / 2.0;
    _ = alpha_b;

    // ========================================================================
    // VFB temperature adjustment
    // ========================================================================
    const vfb1 = vfb_val + stvfb_val * delta_t;
    const vfb2 = vfbb_val + stvfb_val * delta_t;

    // ========================================================================
    // Series resistance temperature
    // ========================================================================
    const rs_t = rs_val * contract.fmath.exp(strso * safe_log(t_ratio));

    // ========================================================================
    // Terminal voltages
    // ========================================================================
    const v_dp = x[dp];
    const v_sp = x[sp];
    const v_gp = x[gp];
    const v_b = x[b];

    // Type-adjusted voltages
    const vgs_raw = v_gp.sub(v_sp).scale(type_f);
    const vds_raw = v_dp.sub(v_sp).scale(type_f);
    const vbs_raw = v_b.sub(v_sp).scale(type_f);

    // Source-drain reversal (branchless)
    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    // mode = vds_raw / (|vds_raw| + 1e-30)
    const mode = vds_raw.div(vds_abs.addC(1.0e-30));
    const vgs = vgs_raw.sub(vds_neg);
    const vds = vds_abs;
    const vbs = vbs_raw.sub(vds_neg);

    // ========================================================================
    // 4.2 Intrinsic Surface Potentials
    // ========================================================================
    // Terminal voltage conditioning (Eqs 4.111-4.114)
    const inv_phi_t = 1.0 / phi_t;
    const x_d = vds.scale(inv_phi_t);
    // x_dsx = (sqrt(vds^2 + 0.01) - 0.1) / phi_t
    const x_dsx = vds.mul(vds).addC(0.01).sqrt().addC(-0.1).scale(inv_phi_t);
    // (x_d - x_dsx)/2
    const half_xd_diff = x_d.sub(x_dsx).scale(0.5);
    const eg_over_2phi0 = eg / (2.0 * phi_t0);

    const x_g10 = vgs.addC(-vfb1).scale(inv_phi_t).sub(half_xd_diff).addC(-eg_over_2phi0);
    const x_g20 = vbs.neg().addC(-vfb2).scale(inv_phi_t).sub(half_xd_diff).addC(-eg_over_2phi0);

    // ========================================================================
    // 4.2.4 Short Channel Effects
    // ========================================================================
    // SCE on front gate (Eq 4.177)
    // x_g20shift used in PNCEW narrow channel effect and overlap modulation
    const x_g20shift_dc = x_g20.addC(5.0).maxC(0.0);
    // csce1 = 1 / (1 + psce * max_func(1 + pscedlb*max(x_g20,-5), 0.5, 0.01))
    const csce_inner = sMaxF(S, x_g20.maxC(-5.0).scale(pscedlb).addC(1.0), 0.5, 0.01);
    const csce1 = S.con(1.0).div(csce_inner.scale(psce).addC(1.0));

    // DIBL (Eq 4.179) -- delta_l_eff approximated from NSDDC depletion
    // sqrt_xdsx = sqrt(1 + x_dsx / max(x_d0, 1e-30))
    const sqrt_xdsx = x_dsx.scale(1.0 / @max(x_d0, 1e-30)).addC(1.0).sqrt();
    // delta_l_eff (Eq 4.175): simplified using x_g20shift_dc as proxy
    const delta_l_eff_dc = x_g20shift_dc.scale(0.01).maxC(0.0); // Simplified proxy
    // dx_g1_dibl = 2*cf1*x_d0*(sqrt_xdsx-1)*(1+cfdl*delta_l_eff)*(1+cfdlb*max(x_g20,-5))
    const dibl_geom = delta_l_eff_dc.scale(cfdl_val).addC(1.0);
    const dibl_bias = x_g20.maxC(-5.0).scale(cfdlb).addC(1.0);
    const dx_g1_dibl = sqrt_xdsx.addC(-1.0).scale(2.0 * cf1 * x_d0).mul(dibl_geom).mul(dibl_bias);

    // Back gate DIBL contribution
    const dx_g2_dibl = sqrt_xdsx.addC(-1.0).scale(2.0 * cf2 * x_d0);

    // Edge adjustment
    const x_edge: f64 = 0.0;

    // Front gate effective voltage (Eq 4.181)
    const x_g1 = x_g10.addC(-x_edge).add(dx_g1_dibl).mul(csce1).addC(x_edge).add(half_xd_diff);

    // Back gate effective voltage with SCE
    const psce2 = psce * psceb;
    const csce2 = S.con(1.0).div(csce_inner.scale(psce2).addC(1.0));
    const x_g2 = x_g20.add(dx_g2_dibl).mul(csce2).add(half_xd_diff);

    // Saturation max for front gate (Eq 4.183)
    const x_satmax = 40.0;
    // x_g1x = min_func(x_g2 + cicf*(x_g1 - x_g2), 40, 0.01)
    const x_g1x = sMinF(S, x_g2.add(x_g1.sub(x_g2).scale(cicf)), x_satmax, 0.01);
    const x_g2x = sMinF(S, x_g2, x_satmax, 0.01);

    // ========================================================================
    // 4.2.6 Inversion Charge at Source
    // ========================================================================
    const q1_s = sChargeDensity(S, x_g1x, x_g2x, 0.0, k1, k2, a0);
    const q2_s = sChargeDensity(S, x_g2x, x_g1x, 0.0, k2, k1, a0);

    // Total normalized inversion charge at source (Eq 4.212)
    const qi_s = q1_s.scale(k1).add(q2_s.scale(k2));

    // ========================================================================
    // 4.2.6b Inversion Charge at Drain
    // ========================================================================
    const x_g1_d = x_g1.sub(x_d);
    const x_g2_d = x_g2.sub(x_d);
    const x_g1x_d = sMinF(S, x_g2_d.add(x_g1_d.sub(x_g2_d).scale(cicf)), x_satmax, 0.01);
    const x_g2x_d = sMinF(S, x_g2_d, x_satmax, 0.01);
    const q1_d = sChargeDensity(S, x_g1x_d, x_g2x_d, 0.0, k1, k2, a0);
    const q2_d = sChargeDensity(S, x_g2x_d, x_g1x_d, 0.0, k2, k1, a0);
    const qi_d = q1_d.scale(k1).add(q2_d.scale(k2));

    // ========================================================================
    // 4.2.7 Mobility Attenuation at Source
    // ========================================================================
    // Surface field at front interface (Eq 4.221)
    // e_surf1s = 2*safe_log(1 + safe_exp(min(k1*q1_s/2, 40)))
    const e_surf1s = sLog(S, sExp(S, q1_s.scale(k1 / 2.0).minC(40.0)).addC(1.0)).scale(2.0);
    const e_surf2s = sLog(S, sExp(S, q2_s.scale(k2 / 2.0).minC(40.0)).addC(1.0)).scale(2.0);

    // Effective field for mobility (Eq 4.225)
    const eta_mu = feta;
    const e_cpl1s = q1_s.maxC(0.0);
    const e_eff1s = e_surf1s.scale(eta_mu).add(e_cpl1s.scale(1.0 - eta_mu));

    // Coulomb scattering threshold
    const cs_thr_eff = csthr * phi_t;
    const cs_thrb_eff = csthrb * phi_t;

    // Front interface mobility -- Coulomb scattering with THECS exponent
    const cs_front = e_surf1s.scale(-csfi).addC(cs_temp).maxC(0.0);
    // cs_front_eff = exp(the_cs * safe_log(max(cs_front, 1e-30)))
    const cs_front_eff = sLog(S, cs_front.maxC(1e-30)).scale(the_cs).exp();
    // mob_red_front = 1 + cs_front_eff / max(1 + e_eff1s/cs_thr_eff, 1e-30)
    const mob_red_front = cs_front_eff.div(e_eff1s.scale(1.0 / cs_thr_eff).addC(1.0).maxC(1e-30)).addC(1.0);
    const gmob1_s = S.con(beta_n1).div(mob_red_front);

    // Back interface mobility
    const e_eff2s = e_surf2s.scale(eta_mu).add(q2_s.maxC(0.0).scale(1.0 - eta_mu));
    const cs_back = e_surf2s.scale(-csbi).addC(cs_temp).maxC(0.0);
    const cs_back_eff = sLog(S, cs_back.maxC(1e-30)).scale(the_cs).exp();
    const mob_red_back = cs_back_eff.div(e_eff2s.scale(1.0 / cs_thrb_eff).addC(1.0).maxC(1e-30)).addC(1.0);
    const gmob2_s = S.con(beta_n2).div(mob_red_back);

    // High-field mobility reduction (MUE) with THEMU exponent
    const e_eff_total = e_surf1s.add(e_surf2s);
    const mu_e_eff = mu_e * 1.0e-8 / toxe; // convert cm/MV to internal units
    // hf_factor = exp(the_mu * safe_log(1 + max(mu_e_eff*e_eff_total, 1e-30)))
    const hf_arg = e_eff_total.scale(mu_e_eff).maxC(1e-30);
    const hf_factor = sLog(S, hf_arg.addC(1.0)).scale(the_mu).exp();
    const gmob1_hf = gmob1_s.div(hf_factor);
    const gmob2_hf = gmob2_s.div(hf_factor);

    // Non-universality factor f_cor (Eq 4.237, XCOR)
    const f_cor_s = e_surf1s.maxC(0.0).scale(xcor_temp).add(e_surf2s.maxC(0.0).scale(xcorb * xcor_temp)).addC(1.0);

    // Combined mobility (Eq 4.237 -- weighted harmonic mean with f_cor)
    const c1s = q1_s.scale(k1).maxC(1e-30);
    const c2s = q2_s.scale(k2).maxC(1e-30);
    const gmob_s = f_cor_s.mul(c1s.add(c2s)).div(c1s.div(gmob1_hf).add(c2s.div(gmob2_hf)));

    // ========================================================================
    // 4.2.8 Drain Saturation Voltage
    // ========================================================================
    // Mean inversion charge
    const qi_m = qi_s.add(qi_d).scale(0.5);
    const qi_m_pos = qi_m.maxC(1e-30);

    // Drift component
    const delta_x_drift = qi_s.sub(qi_d).maxC(0.0);

    // Velocity saturation terms
    const thesatg_eff = e_surf1s.maxC(0.0).scale(thesatg);
    const thesatb_eff = e_surf2s.maxC(0.0).scale(thesatb);
    const f_vsat_eff = thesatg_eff.add(thesatb_eff).addC(1.0).scale(f_vsat);

    // Normalized drain-source voltage
    const x_d_clamp = x_d.maxC(0.0);

    // Saturation voltage (Eq 4.285 simplified)
    // x_nds_sat = max(qi_s / (1 + f_vsat_eff*qi_s), 1e-30)
    const x_nds_sat = qi_s.div(f_vsat_eff.mul(qi_s).addC(1.0)).maxC(1e-30);
    const xd_ratio = x_d_clamp.div(x_nds_sat);
    // x_deff_denom = exp(0.0625*safe_log(max(
    //     exp(0.25*safe_log(1 + gamma_ax*exp((8/3)*safe_log(min(xd_ratio,100)))))
    //   + exp(16*safe_log(min(xd_ratio,100))), 1e-300)))
    const xd_ratio_c = xd_ratio.minC(100.0);
    const log_xdr = sLog(S, xd_ratio_c);
    const term_a_inner = log_xdr.scale(8.0 / 3.0).exp().scale(gamma_ax).addC(1.0);
    const term_a = sLog(S, term_a_inner).scale(0.25).exp();
    const term_b = log_xdr.scale(16.0).exp();
    const x_deff_denom = sLog(S, term_a.add(term_b).maxC(1e-300)).scale(0.0625).exp();
    const x_deff = x_d_clamp.div(x_deff_denom.maxC(1e-30));

    // ========================================================================
    // 4.2.13 Channel Length Modulation
    // ========================================================================
    // vp_eff = vp_val/phi_t + vpg_val*qi_m_pos^2
    const vp_eff = qi_m_pos.mul(qi_m_pos).scale(vpg_val).addC(vp_val / phi_t);
    // f_clm = safe_log(1 + max(x_d_clamp - x_deff, 0)/max(vp_eff, 1e-20))
    const f_clm = sLog(S, x_d_clamp.sub(x_deff).maxC(0.0).div(vp_eff.maxC(1e-20)).addC(1.0));

    // ALP with back bias and ALP1 above-threshold enhancement
    const alp_eff = x_g20.maxC(-5.0).scale(alpb_val).addC(1.0).scale(alp_clamped);
    const alp1_contrib = qi_m_pos.maxC(0.0).scale(alp1_val);
    const delta_l_over_l = alp_eff.add(alp1_contrib).mul(f_clm).maxC(0.0);
    // f_delta_l = 1 / (1 - min(delta_l_over_l, 0.99))
    const f_delta_l = S.con(1.0).div(delta_l_over_l.minC(0.99).neg().addC(1.0));

    // ========================================================================
    // 4.2.14 Velocity Saturation
    // ========================================================================
    // G_gamma (Eq 4.350)
    const satfact_avg = qi_m_pos.mul(f_vsat_eff).addC(1.0);
    const g_gamma = f_vsat_eff.mul(delta_x_drift).mul(satfact_avg);

    // z_sat (Eq 4.351)
    const z_sat = g_gamma.div(gmob_s.mul(f_delta_l).maxC(1e-30));
    const g_vsat = z_sat.addC(1.0);

    // ========================================================================
    // 4.2.16 Normalized Channel Current (Eq 4.364)
    // ========================================================================
    const ids_norm = qi_m_pos.mul(delta_x_drift).add(qi_s.sub(qi_d));

    // ========================================================================
    // 4.3 Channel Current (Eq 4.389)
    // ========================================================================
    // Quantum confinement factor
    const qmc: f64 = @as(f64, model.qmc);
    const qm_type: f64 = if (model.type_ == 1) QMN else QMP;
    // qmfact = 1 + qmc*qm_type*exp((1/3)*safe_log(max(e_surf1s*phi_t/(tsi*1e9), 1e-30)))
    const qmfact = sLog(S, e_surf1s.scale(phi_t / (tsi * 1e9)).maxC(1e-30)).scale(1.0 / 3.0).exp().scale(qmc * qm_type).addC(1.0);

    // Effective beta (Eq 4.383): beta_Neff = FACTUO * c_sum / (e_surf1 + e_surf2)
    const beta_neff = c1s.add(c2s).scale(factuo).div(e_surf1s.add(e_surf2s).maxC(1e-30));

    // Main channel current (Eq 4.389): I_DS = F_dL/(G_vsat*qmfact) * beta_Neff * phi_T^2 * C'_Si * i_DS_norm
    const f64_pref = phi_t * phi_t * csi0;
    const ids_raw = f_delta_l.div(g_vsat.mul(qmfact)).mul(beta_neff).scale(f64_pref).mul(ids_norm);

    // ========================================================================
    // 4.5 Gate Current (swigate is loop-invariant model param)
    // ========================================================================
    const gco: f64 = @as(f64, model.gcoo);
    const gc2ch: f64 = @as(f64, model.gc2cho);
    const gc3ch: f64 = @as(f64, model.gc3cho);
    const gc2ovinv: f64 = @as(f64, model.gc2ovinvo);
    const gc3ovinv: f64 = @as(f64, model.gc3ovinvo);
    const gc2ovacc: f64 = @as(f64, model.gc2ovacco);
    const gc3ovacc: f64 = @as(f64, model.gc3ovacco);
    const stig: f64 = @as(f64, model.stigo);
    const niginv: f64 = @as(f64, model.niginvo);
    _ = niginv;
    const gcovinvfn: f64 = @as(f64, model.gcovinvfno);

    // Gate current pre-factors with area/width scaling
    const iginvlw: f64 = @as(f64, model.iginvlw);
    const igovinvw: f64 = @as(f64, model.igovinvw);
    const igovinvdw: f64 = @as(f64, model.igovinvdw);
    const igovaccw: f64 = @as(f64, model.igovaccw);
    const igovaccdw: f64 = @as(f64, model.igovaccdw);
    const fnovinvw: f64 = @as(f64, model.fnovinvw);
    const fnovinvdw: f64 = @as(f64, model.fnovinvdw);
    const stigfn: f64 = @as(f64, model.stigfno);

    const l_en: f64 = 1.0e-6;
    const w_en: f64 = 1.0e-6;
    const i_ginv = iginvlw * w_e * l_e / (l_en * w_en);
    const i_govinv = igovinvw * w_e / w_en;
    const i_govinvd = if (igovinvdw != 0.0) igovinvdw * w_e / w_en else i_govinv;
    const i_govacc = igovaccw * w_e / w_en;
    const i_govaccd = if (igovaccdw != 0.0) igovaccdw * w_e / w_en else i_govacc;
    const i_fnovinv = fnovinvw * w_e / w_en;
    const i_fnovinvd = if (fnovinvdw != 0.0) fnovinvdw * w_e / w_en else i_fnovinv;

    // Temperature dependence
    const t_gate_factor = 1.0 + stig * delta_t;
    const t_gate_fn_factor = 1.0 + stigfn * delta_t;

    // B_ov for overlap (same as B_ch but using toxp)
    const b_ov = b_ch;

    // Overlap voltages
    const v_ovs = vgs.addC(-vfb1);
    const v_ovd = vgs.sub(vds).addC(-vfb1);

    // Gate to channel tunneling current (Eq 4.441)
    // z_g_ch = max(|v_ovs + gco*phi_t|, 1e-10) / chib
    const chib: f64 = @as(f64, model.chibo);
    const z_g_ch = v_ovs.addC(gco * phi_t).abs().maxC(1e-10).scale(1.0 / chib);
    // tunnel_exp_ch = b_ch*z_g_ch*(gc2ch + z_g_ch*gc3ch) - 1.5
    const tunnel_exp_ch = z_g_ch.scale(b_ch).mul(z_g_ch.scale(gc3ch).addC(gc2ch)).addC(-1.5);
    const i_gc0 = sExp(S, tunnel_exp_ch).scale(i_ginv * t_gate_factor);

    // Split between source and drain (Eqs 4.454-4.455)
    const i_gcs = i_gc0.scale(0.5);
    const i_gcd = i_gc0.scale(0.5);

    // Gate-source overlap current (inversion mode, Eq 4.420)
    const z_g_ovs = v_ovs.abs().maxC(1e-10).scale(1.0 / chib);
    const tunnel_exp_ovs_inv = z_g_ovs.scale(b_ov).mul(z_g_ovs.scale(gc3ovinv).addC(gc2ovinv)).addC(-1.5);
    const i_gs_ov_inv = sExp(S, tunnel_exp_ovs_inv).scale(i_govinv * t_gate_factor);
    // i_gs_ov_fn = i_fnovinv*t_gate_fn * safe_exp(min(-b_ov*gcovinvfn/max(z_g_ovs,1e-10), 80))
    const i_gs_ov_fn = sExp(S, S.con(-b_ov * gcovinvfn).div(z_g_ovs.maxC(1e-10))).scale(i_fnovinv * t_gate_fn_factor);

    // Gate-source overlap current (accumulation mode)
    const tunnel_exp_ovs_acc = z_g_ovs.scale(b_ov).mul(z_g_ovs.scale(gc3ovacc).addC(gc2ovacc)).addC(-1.5);
    const i_gs_ov_acc = sExp(S, tunnel_exp_ovs_acc).scale(i_govacc * t_gate_factor);

    // Select based on voltage polarity (branch on v_ovs sign -- original branched)
    const vov_sign_s: f64 = if (v_ovs.val() > 0.0) 1.0 else 0.0;
    const i_gs_ov = i_gs_ov_inv.sub(i_gs_ov_fn).scale(vov_sign_s).add(i_gs_ov_acc.scale(1.0 - vov_sign_s));

    // Gate-drain overlap current
    const z_g_ovd = v_ovd.abs().maxC(1e-10).scale(1.0 / chib);
    const tunnel_exp_ovd_inv = z_g_ovd.scale(b_ov).mul(z_g_ovd.scale(gc3ovinv).addC(gc2ovinv)).addC(-1.5);
    const i_gd_ov_inv = sExp(S, tunnel_exp_ovd_inv).scale(i_govinvd * t_gate_factor);
    const i_gd_ov_fn = sExp(S, S.con(-b_ov * gcovinvfn).div(z_g_ovd.maxC(1e-10))).scale(i_fnovinvd * t_gate_fn_factor);
    const tunnel_exp_ovd_acc = z_g_ovd.scale(b_ov).mul(z_g_ovd.scale(gc3ovacc).addC(gc2ovacc)).addC(-1.5);
    const i_gd_ov_acc = sExp(S, tunnel_exp_ovd_acc).scale(i_govaccd * t_gate_factor);
    const vov_sign_d: f64 = if (v_ovd.val() > 0.0) 1.0 else 0.0;
    const i_gd_ov = i_gd_ov_inv.sub(i_gd_ov_fn).scale(vov_sign_d).add(i_gd_ov_acc.scale(1.0 - vov_sign_d));

    // High drain voltage correction
    const gcdov: f64 = @as(f64, model.gcdovl) * l_en / l_e;
    const gcvdov: f64 = @as(f64, model.gcvdovo);
    const hdv_factor = vds.addC(-gcvdov).maxC(0.0).scale(gcdov).addC(1.0);

    const gate_en: f64 = if (model.swigate == 1) 1.0 else 0.0;
    const i_gs_gate = i_gcs.add(i_gs_ov).scale(gate_en);
    const i_gd_gate = i_gcd.add(i_gd_ov.mul(hdv_factor)).scale(gate_en);

    // ========================================================================
    // 4.6 GIDL/GISL (swgidl is loop-invariant model param)
    // ========================================================================
    const agidl: f64 = @as(f64, model.agidlo) + @as(f64, model.agidlw) * w_en / w_e;
    const bgidl: f64 = @as(f64, model.bgidlo) + @as(f64, model.stbgidlo) * delta_t;
    const cgidl: f64 = @as(f64, model.cgidlo);
    const dgidl: f64 = @as(f64, model.dgidlo) + @as(f64, model.dgidll) * le_ratio;

    // Source side (Eq 4.457)
    const v_ovs_gidl = vgs.addC(-vfb1);
    // v_tovs = sqrt(v_ovs_gidl^2 + cgidl^2*vbs^2 + 1e-6)
    const v_tovs = v_ovs_gidl.mul(v_ovs_gidl).add(vbs.mul(vbs).scale(cgidl * cgidl)).addC(1.0e-6).sqrt();
    // i_gisl_raw = -agidl*(-vds)*v_ovs_gidl*v_tovs*safe_exp(min(-bgidl/max(v_tovs,1e-10),80))
    //              * (1 + safe_exp(min(dgidl*(-vds),80))) / 2
    const gisl_expA = sExp(S, S.con(-bgidl).div(v_tovs.maxC(1e-10)));
    const gisl_expB = sExp(S, vds.neg().scale(dgidl)).addC(1.0);
    const i_gisl_raw = vds.scale(agidl).mul(v_ovs_gidl).mul(v_tovs).mul(gisl_expA).mul(gisl_expB).scale(0.5);
    // (note: -agidl*(-vds) = +agidl*vds)

    // Drain side (asymmetric, Eq 4.459)
    const agidld: f64 = if (model.agidldo != 0.0 or model.agidldw != 0.0)
        @as(f64, model.agidldo) + @as(f64, model.agidldw) * w_en / w_e
    else
        agidl;
    const bgidld: f64 = @as(f64, model.bgidldo) + @as(f64, model.stbgidldo) * delta_t;
    const cgidld: f64 = @as(f64, model.cgidldo);
    const dgidld: f64 = @as(f64, model.dgidldo) + @as(f64, model.dgidldl) * le_ratio;

    const v_ovd_gidl = vgs.sub(vds).addC(-vfb1);
    // v_tovd = sqrt(v_ovd_gidl^2 + cgidld^2*(vbs-vds)^2 + 1e-6)
    const vbs_vds = vbs.sub(vds);
    const v_tovd = v_ovd_gidl.mul(v_ovd_gidl).add(vbs_vds.mul(vbs_vds).scale(cgidld * cgidld)).addC(1.0e-6).sqrt();
    const gidl_expA = sExp(S, S.con(-bgidld).div(v_tovd.maxC(1e-10)));
    const gidl_expB = sExp(S, vds.scale(dgidld)).addC(1.0);
    // i_gidl_raw = -agidld*vds*v_ovd_gidl*v_tovd*gidl_expA*(1+expB)/2
    const i_gidl_raw = vds.scale(-agidld).mul(v_ovd_gidl).mul(v_tovd).mul(gidl_expA).mul(gidl_expB).scale(0.5);

    const gidl_en: f64 = if (model.swgidl == 1) 1.0 else 0.0;
    const i_gisl = i_gisl_raw.scale(gidl_en);
    const i_gidl = i_gidl_raw.scale(gidl_en);

    // ========================================================================
    // 4.7 Edge Transistor Current (swedge is loop-invariant model param)
    // ========================================================================
    const betnedge: f64 = @as(f64, model.betnedge);
    const wedge: f64 = @as(f64, model.wedge) * (1.0 + @as(f64, model.wedgew) * we_ratio);
    const stbetedge: f64 = @as(f64, model.stbetedgeo) * (1.0 + @as(f64, model.stbetedgel) * le_ratio) * (1.0 + @as(f64, model.stbetedgew) * we_ratio) * (1.0 + @as(f64, model.stbetedgelw) * le_ratio * we_ratio);

    // Edge VFB
    const vfbedge = @as(f64, model.vfbedgeo) + @as(f64, model.vfbedgel) * contract.fmath.exp(@as(f64, model.vfbedgelexp) * safe_log(le_ratio)) + @as(f64, model.vfbedgew) * we_ratio + @as(f64, model.vfbedgelw) * le_ratio * we_ratio;
    const stvfbedge = @as(f64, model.stvfbedgeo) * (1.0 + @as(f64, model.stvfbedgel) * le_ratio) * (1.0 + @as(f64, model.stvfbedgew) * we_ratio) * (1.0 + @as(f64, model.stvfbedgelw) * le_ratio * we_ratio);
    const vfb1_edge = vfbedge + stvfbedge * delta_t;

    // Edge VFBB
    const vfbb_edge = @as(f64, model.vfbbedgeo) + stvfbedge * delta_t;

    // Edge coupling
    const cicf_edge: f64 = @as(f64, model.cicfedgeo);
    const cic_edge: f64 = @as(f64, model.cicedgeo);

    // Edge SCE
    const psce_edge = 2.0 * @as(f64, model.psceedgel) * contract.fmath.exp(@as(f64, model.psceedgelexp) * safe_log(lambda_2d / l_e)) * (1.0 + @as(f64, model.psceedgew) * we_ratio);
    const psceb_edge: f64 = @as(f64, model.pscebedgeo);

    // Edge DIBL
    const cf_edge = @as(f64, model.cfedgel) * contract.fmath.exp(@as(f64, model.cfedgelexp) * safe_log(lambda_2d / l_e)) * (1.0 + @as(f64, model.cfedgew) * we_ratio);
    const cfb_edge: f64 = @as(f64, model.cfbedgeo);
    const cfd_edge: f64 = @as(f64, model.cfdedgeo);

    // Compute edge gate voltages
    const x_g10_edge = vgs.addC(-vfb1_edge).scale(inv_phi_t).sub(half_xd_diff).addC(-eg_over_2phi0);
    const x_g20_edge = vbs.neg().addC(-vfbb_edge).scale(inv_phi_t).sub(half_xd_diff).addC(-eg_over_2phi0);

    const csce1_edge = 1.0 / (1.0 + psce_edge);
    const x_d0_edge = cfd_edge / phi_t;
    // sqrt(1 + x_dsx/max(x_d0_edge,1e-30)) - 1
    const sqrt_xdsx_edge_m1 = x_dsx.scale(1.0 / @max(x_d0_edge, 1e-30)).addC(1.0).sqrt().addC(-1.0);
    const dx_dibl_edge = sqrt_xdsx_edge_m1.scale(2.0 * cf_edge * x_d0_edge);
    const dx_dibl2_edge = sqrt_xdsx_edge_m1.scale(2.0 * cf_edge * cfb_edge * (tbox / toxe) * x_d0_edge);

    const x_g1_edge = x_g10_edge.add(dx_dibl_edge).scale(csce1_edge).add(half_xd_diff);
    const csce2_edge = 1.0 / (1.0 + psce_edge * psceb_edge);
    const x_g2_edge = x_g20_edge.add(dx_dibl2_edge).scale(csce2_edge).add(half_xd_diff);

    const k1_edge = k1_1d * cicf_edge;
    const k2_edge = k2_1d * cic_edge;

    const x_g1x_edge = sMinF(S, x_g2_edge.add(x_g1_edge.sub(x_g2_edge).scale(cicf_edge)), x_satmax, 0.01);
    const x_g2x_edge = sMinF(S, x_g2_edge, x_satmax, 0.01);

    // Edge charges at source and drain
    const q1s_edge = sChargeDensity(S, x_g1x_edge, x_g2x_edge, 0.0, k1_edge, k2_edge, a0);
    const q2s_edge = sChargeDensity(S, x_g2x_edge, x_g1x_edge, 0.0, k2_edge, k1_edge, a0);
    const qi_s_edge = q1s_edge.scale(k1_edge).add(q2s_edge.scale(k2_edge));

    // x_g1x_d_edge = min_func(x_g2_edge - x_d + cicf*((x_g1_edge-x_d)-(x_g2_edge-x_d)), 40, 0.01)
    const x_g1_d_edge = x_g1_edge.sub(x_d);
    const x_g2_d_edge = x_g2_edge.sub(x_d);
    const x_g1x_d_edge = sMinF(S, x_g2_d_edge.add(x_g1_d_edge.sub(x_g2_d_edge).scale(cicf_edge)), x_satmax, 0.01);
    const x_g2x_d_edge = sMinF(S, x_g2_d_edge, x_satmax, 0.01);
    const q1d_edge = sChargeDensity(S, x_g1x_d_edge, x_g2x_d_edge, 0.0, k1_edge, k2_edge, a0);
    const q2d_edge = sChargeDensity(S, x_g2x_d_edge, x_g1x_d_edge, 0.0, k2_edge, k1_edge, a0);
    const qi_d_edge = q1d_edge.scale(k1_edge).add(q2d_edge.scale(k2_edge));

    // Edge current (Eq 4.487)
    const beta_n_edge = betnedge * wedge / l_e * contract.fmath.exp(stbetedge * safe_log(t_ratio));

    const ct_edge: f64 = @as(f64, model.ctedgeo);
    const phi_t_edge = phi_t0 * (1.0 + ct_edge * t_kr / t_kc);

    const ids_norm_edge = qi_s_edge.sub(qi_d_edge).maxC(0.0);
    const edge_en: f64 = if (model.swedge == 1) 1.0 else 0.0;
    const ids_edge = ids_norm_edge.scale(cox1 * beta_n_edge * phi_t_edge * phi_t_edge * edge_en);

    // ========================================================================
    // 4.8 Impact Ionization
    // ========================================================================
    // swimpact is a model param (loop-invariant), so this branch is fine.
    // Impact ionization parameters with geometry scaling
    const a1_val: f64 = @as(f64, model.a1o) * (1.0 + @as(f64, model.a1l) * le_ratio) * (1.0 + @as(f64, model.a1w) * we_ratio);
    const a2_val: f64 = @as(f64, model.a2o) * (1.0 + @as(f64, model.sta2o) * delta_t);
    const a3_val: f64 = @as(f64, model.a3o) * (1.0 + @as(f64, model.a3l) * le_ratio) * (1.0 + @as(f64, model.a3w) * we_ratio);

    // DeltaVsat (Eq 4.488)
    // delta_vsat = (x_d - a3_val*x_deff)*phi_t
    const delta_vsat = x_d.sub(x_deff.scale(a3_val)).scale(phi_t);
    // M_avl (Eq 4.489): clamp delta_vsat to positive; region-select on sign
    const delta_vsat_pos = delta_vsat.maxC(1e-30);
    // m_avl_raw = a1_val*delta_vsat_pos*safe_exp(-a2_val/delta_vsat_pos)
    const m_avl_raw = delta_vsat_pos.scale(a1_val).mul(sExp(S, S.con(-a2_val).div(delta_vsat_pos)));
    const m_avl = if (delta_vsat.val() > 0.0) m_avl_raw else S.con(0.0);

    const i_impact_en: f64 = if (model.swimpact == 1) 1.0 else 0.0;
    const i_impact = m_avl.mul(ids_raw).scale(i_impact_en);

    // ========================================================================
    // Stress model adjustments (branchless for per-instance SA/SB)
    // ========================================================================
    // STI stress (swstress==1): branchless -- always compute, enable factor selects
    const sa: f64 = @as(f64, instance.sa);
    const sb: f64 = @as(f64, instance.sb);
    const saref: f64 = @as(f64, model.saref);
    const sbref: f64 = @as(f64, model.sbref);

    // Guard against sa=0 or sb=0 by clamping denominator
    const inv_sa = 1.0 / @max(sa + 0.5 * @as(f64, instance.sd), 1e-30);
    const inv_sb = 1.0 / @max(sb + 0.5 * @as(f64, instance.sd), 1e-30);
    const inv_saref = 1.0 / saref;
    const inv_sbref = 1.0 / sbref;
    const inv_odref = inv_saref + inv_sbref;
    const inv_od = inv_sa + inv_sb;
    // Enable factor: only apply if both sa and sb > 0 (branchless)
    const sa_sb_en = @min(@min(sa, sb) * 1e30, 1.0); // 0 if either is 0, ~1 otherwise

    const wlod_val: f64 = @as(f64, model.wlod);
    const llodkuo: f64 = @as(f64, model.llodkuo);
    const wlodkuo: f64 = @as(f64, model.wlodkuo);
    const llodvth: f64 = @as(f64, model.llodvth);
    const wlodvth: f64 = @as(f64, model.wlodvth);
    // LOD-adjusted geometry for stress (WLOD, LLODKUO, WLODKUO, LLODVTH, WLODVTH)
    const lod_kuo_factor = 1.0 / @max(1.0 + llodkuo * le_ratio + wlodkuo * we_ratio + wlod_val * le_ratio * we_ratio, 1e-30);
    const lod_vth_factor = 1.0 / @max(1.0 + llodvth * le_ratio + wlodvth * we_ratio + wlod_val * le_ratio * we_ratio, 1e-30);

    const kuo_eff = @as(f64, model.kuo) * (1.0 + @as(f64, model.lkuo) * le_ratio) * (1.0 + @as(f64, model.wkuo) * we_ratio) * (1.0 + @as(f64, model.pkuo) * le_ratio * we_ratio) * (1.0 + @as(f64, model.tkuo) * delta_t) * lod_kuo_factor;
    const sti_mu_factor = 1.0 + sa_sb_en * kuo_eff * (inv_od - inv_odref);

    const kvtho_eff = @as(f64, model.kvtho) * (1.0 + @as(f64, model.lkvtho) * le_ratio) * (1.0 + @as(f64, model.wkvtho) * we_ratio) * (1.0 + @as(f64, model.pkvtho) * le_ratio * we_ratio) * lod_vth_factor;
    const sti_vth_shift = sa_sb_en * kvtho_eff * (inv_od - inv_odref);

    // STETAO/LODETAO: apply ETAO shift from stress
    const stetao_val: f64 = @as(f64, model.stetao);
    const lodetao_val: f64 = @as(f64, model.lodetao);
    _ = stetao_val;
    _ = lodetao_val;

    const kvsat: f64 = @as(f64, model.kvsat);
    const sti_vsat_factor = 1.0 + sa_sb_en * kvsat * (inv_od - inv_odref);

    // Strained-SOI (swstress==2)
    const strlambda: f64 = @as(f64, model.strlambda);
    const stralpha: f64 = @as(f64, model.stralpha);
    const strain_factor = 1.0 - safe_exp(-l_e / strlambda);
    const strain_asym = contract.fmath.exp(stralpha * safe_log(@max(strain_factor, 1e-30)));

    const str_vth_shift = @as(f64, model.strdvfbo) * (1.0 + @as(f64, model.strwdvfbo) * we_ratio) * strain_factor;
    // STRDCFL: strained-SOI DIBL variation
    const strdcfl_val: f64 = @as(f64, model.strdcfl);
    _ = strdcfl_val;
    _ = strain_asym;
    const str_mu_factor = 1.0 + @as(f64, model.strruo) * (1.0 + @as(f64, model.strtruo) * delta_t) * strain_factor;
    const str_vsat_factor = 1.0 + @as(f64, model.strrvsat) * strain_factor;

    // Select stress model based on swstress (model param, loop-invariant)
    const stress_mu_factor = if (model.swstress == 1) sti_mu_factor else if (model.swstress == 2) str_mu_factor else 1.0;
    const stress_vth_shift = if (model.swstress == 1) sti_vth_shift else if (model.swstress == 2) str_vth_shift else 0.0;
    const stress_vsat_factor = if (model.swstress == 1) sti_vsat_factor else if (model.swstress == 2) str_vsat_factor else 1.0;

    // Apply stress factors -- multiplicative on mobility and vsat
    const stress_ids_factor = stress_mu_factor * stress_vsat_factor / @max(1.0 + @abs(stress_vth_shift), 1e-30);

    // ========================================================================
    // Apply stress to channel current
    // ========================================================================
    const ids_channel = ids_raw.scale(stress_ids_factor);

    // ========================================================================
    // 4.12 Total Currents (Eqs 4.563-4.565)
    // ========================================================================
    const tot_scale = mult_i * multf * type_f;
    const ids_total = ids_channel.add(i_gidl).sub(i_gisl).add(i_impact).add(ids_edge).scale(tot_scale);
    const i_gs_total = i_gs_gate.scale(tot_scale);
    const i_gd_total = i_gd_gate.scale(tot_scale);

    // ========================================================================
    // Parasitic resistances
    // ========================================================================
    // Source/drain external resistance
    const rse_val: f64 = @as(f64, model.rse) + @as(f64, model.rsh) * @as(f64, instance.nrs);
    const rde_val: f64 = @as(f64, model.rde) + @as(f64, model.rshd) * @as(f64, instance.nrd);

    // Gate resistance
    const rg_val: f64 = @as(f64, model.rgo);

    // External resistance conductances
    const g_rse: f64 = if (rse_val > 0.0) multf / rse_val else GSHORT;
    const g_rde: f64 = if (rde_val > 0.0) multf / rde_val else GSHORT;
    const g_rg: f64 = if (rg_val > 0.0) multf / rg_val else GSHORT;

    // Well resistance conductance
    const rwell: f64 = @as(f64, model.rwello);
    const g_rwell: f64 = if (rwell > 0.0) multf / rwell else 0.0;

    // Resistance currents
    const i_rd = x[d_ext].sub(x[dp]).scale(g_rde);
    const i_rs = x[s_ext].sub(x[sp]).scale(g_rse);
    const i_rg = x[g_ext].sub(x[gp]).scale(g_rg);

    // Internal series resistance current (gate-dependent Rs, Eqs RS/RSG/RSB/RSIG/THERSG)
    const rsig: f64 = @as(f64, model.rsigo);
    const rsg: f64 = @as(f64, model.rsgo);
    const rsb: f64 = @as(f64, model.rsbo);
    const thersg: f64 = @as(f64, model.thersgo);
    // rs_gate_dep = rs_t*(1+rsg*exp(thersg*safe_log(max(|vgs-vfb1|,1e-10))))
    //              *(1+rsb*max(-vbs,0))*(1+rsig*max(qi_s,0))
    const rsg_gate = sLog(S, vgs.addC(-vfb1).abs().maxC(1e-10)).scale(thersg).exp().scale(rsg).addC(1.0);
    const rsb_back = vbs.neg().maxC(0.0).scale(rsb).addC(1.0);
    const rsig_inv = qi_s.maxC(0.0).scale(rsig).addC(1.0);
    const rs_gate_dep = rsg_gate.mul(rsb_back).mul(rsig_inv).scale(rs_t);
    // Conductance from gate-modulated Rs: g_rs_int = multf / rs_gate_dep
    // (rs_gate_dep > 0 always since rs_t >= 0 and all factors >= 1; guard preserved)
    const g_rs_int = S.con(multf).div(rs_gate_dep);

    // ========================================================================
    // Self-heating current (Eq 4.523)
    // ========================================================================
    // RTH scaling
    const rtho_sc: f64 = @as(f64, model.rtho);
    const rthl: f64 = @as(f64, model.rthl);
    const rthw: f64 = @as(f64, model.rthw);
    const rthlw: f64 = @as(f64, model.rthlw);
    const strth: f64 = @as(f64, model.strtho);
    const rth_base = rtho_sc / (l_e * w_e) * contract.fmath.exp(rthl * safe_log(le_ratio)) * contract.fmath.exp(rthw * safe_log(we_ratio)) * contract.fmath.exp(rthlw * safe_log(le_ratio * we_ratio));
    const rth = rth_base * (1.0 + strth * delta_t) / multf;

    const g_th: f64 = if (rth > 0.0) 1.0 / rth else GSHORT;
    // i_th_val = delta_tc*g_th - ids_total*vds  (delta_tc is plain f64; see note above)
    const i_th_val = ids_total.mul(vds).neg().addC(delta_tc * g_th);

    // ========================================================================
    // Write outputs -- apply mode for source-drain reversal
    // ========================================================================
    // Channel current flows dp -> sp, reversed by mode
    const i_ds_out = mode.mul(ids_total);

    // Gate currents (already signed by type_f)
    const i_gs_out = mode.mul(i_gs_total);
    const i_gd_out = mode.mul(i_gd_total);
    const i_g_total = i_gs_out.add(i_gd_out);

    // Internal series resistance current (dp-sp, gate-modulated)
    const i_rs_int = x[dp].sub(x[sp]).mul(g_rs_int);

    // Well resistance current (bulk to ground)
    const i_rwell = x[b].scale(g_rwell);

    // KCL at each node
    var out: [n_u]S = undefined;
    out[d_ext] = i_rd;
    out[s_ext] = i_rs;
    out[g_ext] = i_rg;
    // bulk: -(i_ds_out + i_g_total) + i_rwell + GMIN*x[b]
    out[b] = i_ds_out.add(i_g_total).neg().add(i_rwell).add(x[b].scale(GMIN));
    // dp: i_ds_out + i_gd_out - i_rd + i_rs_int + GMIN*(x[dp]-x[sp])
    out[dp] = i_ds_out.add(i_gd_out).sub(i_rd).add(i_rs_int).add(x[dp].sub(x[sp]).scale(GMIN));
    // sp: -i_ds_out + i_gs_out - i_rs - i_rs_int + GMIN*(x[sp]-x[dp])
    out[sp] = i_ds_out.neg().add(i_gs_out).sub(i_rs).sub(i_rs_int).add(x[sp].sub(x[dp]).scale(GMIN));
    out[gp] = i_g_total.sub(i_rg);
    // tnode: i_th_val if SHE, else tie to ground (delta_tc*GSHORT, delta_tc==0 here)
    out[tn] = if (model.swshe == 1) i_th_val else S.con(delta_tc * GSHORT);
    return out;
}

// ============================================================================
// Charge Function q
// ============================================================================
pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = pc;

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);
    const b = @intFromEnum(U.bulk);
    const d_ext = @intFromEnum(U.drain);
    const s_ext = @intFromEnum(U.source);
    const g_ext = @intFromEnum(U.gate);
    const tn = @intFromEnum(U.tnode);

    // ========================================================================
    // Cast model/instance to f64
    // ========================================================================
    const type_f: f64 = @floatFromInt(model.type_);
    const nf_f: f64 = @floatFromInt(instance.nf);
    const mult_f: f64 = @floatFromInt(instance.mult);
    const mult_q: f64 = @as(f64, instance.mult_q);
    const multf = mult_f * nf_f;
    const l_draw: f64 = @as(f64, instance.l);
    const w_draw: f64 = @as(f64, instance.w);
    const wf = w_draw / nf_f;

    const l_en: f64 = 1.0e-6;
    const w_en: f64 = 1.0e-6;

    // ========================================================================
    // Effective dimensions (same as i function)
    // ========================================================================
    const lvaro: f64 = @as(f64, model.lvaro);
    const lvarl: f64 = @as(f64, model.lvarl);
    const lvarw: f64 = @as(f64, model.lvarw);
    const delta_lps = lvaro * (1.0 + lvarl * l_en / l_draw) * (1.0 + lvarw * w_en / wf);

    const wvaro: f64 = @as(f64, model.wvaro);
    const wvarl: f64 = @as(f64, model.wvarl);
    const wvarw: f64 = @as(f64, model.wvarw);
    const delta_wod = wvaro * (1.0 + wvarl * l_en / l_draw) * (1.0 + wvarw * w_en / wf);

    const lap: f64 = @as(f64, model.lap);
    const wot: f64 = @as(f64, model.wot);
    const dlq: f64 = @as(f64, model.dlq);
    const dwq: f64 = @as(f64, model.dwq);
    const l_e = @max(l_draw + delta_lps - 2.0 * lap, 1.0e-9);
    const w_e = @max(wf + delta_wod - 2.0 * wot, 1.0e-9);
    const l_ecv = @max(l_draw + delta_lps - 2.0 * lap + dlq, 1.0e-9);
    const w_ecv = @max(wf + delta_wod - 2.0 * wot + dwq, 1.0e-9);
    const le_ratio = l_en / l_e;
    const we_ratio = w_en / w_e;

    // ========================================================================
    // Process parameters for charge model
    // ========================================================================
    const toxe: f64 = @as(f64, model.toxeo);
    const tsi: f64 = @as(f64, model.tsio);
    const xge: f64 = @as(f64, model.xgeo);
    const tbox: f64 = @as(f64, model.tboxo);
    const ct: f64 = @as(f64, model.cto);
    const dtemp: f64 = @as(f64, model.dtemp);
    const tr: f64 = @as(f64, model.tr);

    const eps_ch_val = EPS_SI * (1.0 - xge) + EPS_GE * xge;
    const cox1 = EPS_OX / toxe;
    const cox2 = EPS_OX / tbox;
    const csi0 = eps_ch_val / tsi;

    // Temperature
    const t_kr = 273.15 + tr;
    const t_kd_raw = 273.15 + 27.0 + dtemp;
    const tmin: f64 = @as(f64, model.tmin);
    const atmin: f64 = @as(f64, model.atmin);
    const btmin: f64 = @as(f64, model.btmin);
    const t_kd = if (model.swcryo == 1) max_func(t_kd_raw, tmin + atmin * t_kd_raw, btmin) else max_func(t_kd_raw, 1.0, 1.0e-3);
    const delta_tc = if (model.swshe == 1) @min(x[tn].val(), @as(f64, model.tmax)) else 0.0;
    const t_kc = t_kd + delta_tc;
    const phi_t0 = K_B * t_kc / Q_E;
    const phi_t = phi_t0 * (1.0 + ct * t_kr / t_kc);

    // Bandgap
    const eg_si = EG0_SI - ALPHA_SI * t_kc * t_kc / (BETA_SI + t_kc);
    const eg_ge = EG0_GE - ALPHA_GE * t_kc * t_kc / (BETA_GE + t_kc);
    const delta_eg = (eg_ge - eg_si + C_G * (1.0 - xge)) * xge;
    const eg = eg_si + delta_eg;

    // Coupling coefficients
    const cicf: f64 = @as(f64, model.cicfo);
    const cic: f64 = @as(f64, model.cico);
    const k1_1d = cox1 / csi0;
    const k2_1d = cox2 / csi0;

    // For charge model, use AC-specific parameters if SWQMOD=1
    const k1 = k1_1d * cicf;
    const k2 = k2_1d * cic;
    const a0 = contract.fmath.exp(-eg / (2.0 * phi_t0));

    // ========================================================================
    // Terminal voltages
    // ========================================================================
    const v_dp = x[dp];
    const v_sp = x[sp];
    const v_gp = x[gp];
    const v_b = x[b];

    const vgs_raw = v_gp.sub(v_sp).scale(type_f);
    const vds_raw = v_dp.sub(v_sp).scale(type_f);
    const vbs_raw = v_b.sub(v_sp).scale(type_f);

    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs = vgs_raw.sub(vds_neg);
    const vds = vds_abs;
    const vbs = vbs_raw.sub(vds_neg);

    const vgb = v_gp.sub(v_b).scale(type_f);
    const vgd_val = vgs.sub(vds);

    // ========================================================================
    // VFB for charge model
    // ========================================================================
    const vfbl_term = @as(f64, model.vfbl) * contract.fmath.exp(@as(f64, model.vfblexp) * safe_log(le_ratio));
    const vfbl2_denom = 1.0 + @as(f64, model.vfbl2) * contract.fmath.exp(@as(f64, model.vfblexp2) * safe_log(le_ratio));
    const vfb_val = @as(f64, model.vfbo) + vfbl_term / @max(vfbl2_denom, 1e-30) + @as(f64, model.vfbw) * we_ratio + @as(f64, model.vfblw) * le_ratio * we_ratio + @as(f64, instance.delvto);
    const delta_t = t_kc - t_kr;
    const stvfb_val = @as(f64, model.stvfbo) * (1.0 + @as(f64, model.stvfbl) * le_ratio) * (1.0 + @as(f64, model.stvfbw) * we_ratio) * (1.0 + @as(f64, model.stvfblw) * le_ratio * we_ratio);
    const vfb1 = vfb_val + stvfb_val * delta_t;
    const vfbb_val = @as(f64, model.vfbbo) + @as(f64, model.vfblbo) * (tbox / toxe) * vfbl_term / @max(vfbl2_denom, 1e-30);
    const vfb2 = vfbb_val + stvfb_val * delta_t;

    // ========================================================================
    // Surface potentials for charge (same flow as DC but using AC parameters)
    // ========================================================================
    const lambda_2d = @sqrt(eps_ch_val / EPS_OX * tsi * (toxe + 4.0e-10));

    // SCE for AC (use FSCEAC if SWQMOD=1, else same as DC)
    const psce_ac = if (model.swqmod == 1) blk: {
        const psceacl: f64 = @as(f64, model.psceacl);
        const psceaclexp: f64 = @as(f64, model.psceaclexp);
        const psceacw: f64 = @as(f64, model.psceacw);
        break :blk 2.0 * psceacl * contract.fmath.exp(psceaclexp * safe_log(lambda_2d / l_ecv)) * (1.0 + psceacw * we_ratio);
    } else blk: {
        const pscel: f64 = @as(f64, model.pscel);
        const pscelexp: f64 = @as(f64, model.pscelexp);
        const pscew: f64 = @as(f64, model.pscew);
        break :blk 2.0 * pscel * contract.fmath.exp(pscelexp * safe_log(lambda_2d / l_ecv)) * (1.0 + pscew * we_ratio);
    };

    // PSCEB for AC
    const psceb_ac: f64 = @as(f64, model.pscebo);
    const pscedlb_ac: f64 = @as(f64, model.pscedlbo);

    // Normalized gate voltages
    const inv_phi_t = 1.0 / phi_t;
    const eg_over_2phi0 = eg / (2.0 * phi_t0);
    const x_d = vds.scale(inv_phi_t);
    const x_dsx = vds.mul(vds).addC(0.01).sqrt().addC(-0.1).scale(inv_phi_t);
    const half_xd_diff = x_d.sub(x_dsx).scale(0.5);
    const x_g10 = vgs.addC(-vfb1).scale(inv_phi_t).sub(half_xd_diff).addC(-eg_over_2phi0);
    const x_g20 = vbs.neg().addC(-vfb2).scale(inv_phi_t).sub(half_xd_diff).addC(-eg_over_2phi0);

    // SCE for charge model
    const csce_inner = sMaxF(S, x_g20.maxC(-5.0).scale(pscedlb_ac).addC(1.0), 0.5, 0.01);
    const csce1_ac = S.con(1.0).div(csce_inner.scale(psce_ac).addC(1.0));
    const psce2_ac = psce_ac * psceb_ac;
    const csce2_ac = S.con(1.0).div(csce_inner.scale(psce2_ac).addC(1.0));

    // DIBL for charge
    const cfl_val: f64 = @as(f64, model.cfl);
    const cflexp_val: f64 = @as(f64, model.cflexp);
    const cf_val = cfl_val * contract.fmath.exp(cflexp_val * safe_log(lambda_2d / l_ecv));
    const cfb_ac: f64 = @as(f64, model.cfbo);
    const cfd_val: f64 = @as(f64, model.cfdo);
    const x_d0 = cfd_val / phi_t;

    const sqrt_xdsx = x_dsx.scale(1.0 / @max(x_d0, 1e-30)).addC(1.0).sqrt();
    const cf1_ac = cf_val;
    const cf2_ac = cf_val * cfb_ac * (tbox / toxe);
    const dx_dibl1 = sqrt_xdsx.addC(-1.0).scale(2.0 * cf1_ac * x_d0);
    const dx_dibl2 = sqrt_xdsx.addC(-1.0).scale(2.0 * cf2_ac * x_d0);

    const x_g1 = x_g10.add(dx_dibl1).mul(csce1_ac).add(half_xd_diff);
    const x_g2 = x_g20.add(dx_dibl2).mul(csce2_ac).add(half_xd_diff);

    const x_satmax = 40.0;
    const x_g1x = sMinF(S, x_g2.add(x_g1.sub(x_g2).scale(cicf)), x_satmax, 0.01);
    const x_g2x = sMinF(S, x_g2, x_satmax, 0.01);

    // Source charges
    const q1_s = sChargeDensity(S, x_g1x, x_g2x, 0.0, k1, k2, a0);
    const q2_s = sChargeDensity(S, x_g2x, x_g1x, 0.0, k2, k1, a0);

    // Drain charges
    const x_g1_d = x_g1.sub(x_d);
    const x_g2_d = x_g2.sub(x_d);
    const x_g1x_d = sMinF(S, x_g2_d.add(x_g1_d.sub(x_g2_d).scale(cicf)), x_satmax, 0.01);
    const x_g2x_d = sMinF(S, x_g2_d, x_satmax, 0.01);
    const q1_d = sChargeDensity(S, x_g1x_d, x_g2x_d, 0.0, k1, k2, a0);
    const q2_d = sChargeDensity(S, x_g2x_d, x_g1x_d, 0.0, k2, k1, a0);

    // ========================================================================
    // Area factor for charge
    // ========================================================================
    const f_area = l_ecv * w_ecv;
    const csi_ac = eps_ch_val / tsi;

    // Delta charges
    const dk1q1 = q1_s.sub(q1_d).scale(k1);
    const dk2q2 = q2_s.sub(q2_d).scale(k2);

    // Charge partition factors (Ward-Dutton 40/60)
    const k1q1_eff = q1_s.add(q1_d).scale(k1 / 2.0);
    const k2q2_eff = q2_s.add(q2_d).scale(k2 / 2.0);

    // P factors for charge partitioning (ratio of delta to total)
    const p1 = dk1q1.div(k1q1_eff.scale(2.0).addC(1e-30).maxC(1e-30));
    const p2 = dk2q2.div(k2q2_eff.scale(2.0).addC(1e-30).maxC(1e-30));

    // ========================================================================
    // 4.9 Intrinsic Charges (Eqs 4.495-4.497)
    // ========================================================================
    // Velocity saturation for AC (simplified)
    const ratio_pd = 1.0; // Simplified partition ratio

    // Q_G (Eq 4.495)
    const q_g_int = k1q1_eff.scale(ratio_pd).add(dk1q1.scale(1.0 / 3.0).mul(p1)).scale(csi_ac * f_area);

    // Q_B (Eq 4.496)
    const q_b_int = k2q2_eff.add(dk2q2.scale(1.0 / 3.0).mul(p2)).scale(csi_ac * f_area);

    // Q_D (Eq 4.497)
    const p1_poly = p1.sub(p1.mul(p1).scale(1.0 / 5.0)).addC(1.0);
    const p2_poly = p2.sub(p2.mul(p2).scale(1.0 / 5.0)).addC(1.0);
    const q_d_int = k1q1_eff.scale(ratio_pd).add(dk1q1.scale(1.0 / 3.0)).mul(p1_poly).add(k2q2_eff.add(dk2q2.scale(1.0 / 3.0)).mul(p2_poly)).scale(-0.5 * csi_ac * f_area);

    // ========================================================================
    // 4.9 Parasitic Charges
    // ========================================================================
    // Overlap capacitances (Eqs 4.514-4.518)
    const lovo: f64 = @as(f64, model.lovo);
    const lovdo: f64 = @as(f64, model.lovdo);
    const cov = if (lovo > 0.0) cox1 * lovo * w_e else 0.0;
    const covd = if (lovdo > 0.0) cox1 * lovdo * w_e else if (lovo > 0.0) cox1 * lovo * w_e else 0.0;

    // Overlap voltage
    const dvfbov: f64 = @as(f64, model.dvfbovo);
    const v_ovs_cv = vgs.addC(-vfb1 + dvfbov);
    const v_ovd_cv = vgd_val.addC(-vfb1 + dvfbov);

    // Outer fringe capacitances (Eqs 4.514-4.515)
    const cfr = @as(f64, model.cfro) + @as(f64, model.cfrw) * w_e / w_en;
    const cfrd = if (@as(f64, model.cfrdo) != 0.0 or @as(f64, model.cfrdw) != 0.0)
        @as(f64, model.cfrdo) + @as(f64, model.cfrdw) * w_e / w_en
    else
        cfr;

    // Q_GS (outer fringe, Eq 4.514)
    const q_gs_ofr = vgs.scale(cfr);
    // Q_GD (outer fringe, Eq 4.515)
    const q_gd_ofr = vgd_val.scale(cfrd);

    // Overlap capacitance modulation (Eq 4.516): COVDL, COVDLB
    const covdl: f64 = @as(f64, model.covdlo) + @as(f64, model.covdlw) * we_ratio;
    const covdlb: f64 = @as(f64, model.covdlbo);
    // delta_l_eff_ac and x_g20shift_ac approximated from DC values
    const x_g20shift_ac = x_g20.addC(5.0).maxC(0.0);
    // Simplified delta_l_eff_ac from DC (use 0 if SCE parameters not fully computed for AC)
    const delta_l_eff_ac_approx: f64 = 0.0; // Full SP_FDSOI_OV would provide this
    // 1 - covdl * delta_l_eff_ac * (1 - covdlb * x_g20shift_ac)
    const cov_mod_inner = x_g20shift_ac.scale(-covdlb).addC(1.0).scale(-covdl * delta_l_eff_ac_approx).addC(1.0);
    const cov_mod_factor = sMaxF(S, cov_mod_inner, 0.0, 0.01);

    // Q_ovS (Eq 4.516)
    const q_ovs = v_ovs_cv.scale(cov).mul(cov_mod_factor);
    // Q_ovD
    const q_ovd = v_ovd_cv.scale(covd).mul(cov_mod_factor);

    // Q_GB (Eq 4.518)
    const cgbov: f64 = @as(f64, model.cgbovo) + @as(f64, model.cgbovl) * l_e / l_en;
    const q_gb = vgb.scale(cgbov);

    // Q_DS (direct capacitance, Eq 4.519)
    const csd_base: f64 = 1.04e-18;
    const csdo: f64 = @as(f64, model.csdo);
    const q_ds = vds.scale(csd_base * csdo);

    // Q_BS (substrate, Eq 4.520)
    const a_source_f: f64 = @as(f64, instance.asource) / nf_f;
    const p_source_f: f64 = @as(f64, instance.psource) / nf_f;
    const a_drain_f: f64 = @as(f64, instance.adrain) / nf_f;
    const p_drain_f: f64 = @as(f64, instance.pdrain) / nf_f;
    const csdbp: f64 = @as(f64, model.csdbpo);
    const q_bs = vbs.neg().scale(-(EPS_OX / tbox * a_source_f + csdbp * p_source_f));
    const q_bd = vbs.sub(vds).neg().scale(-(EPS_OX / tbox * a_drain_f + csdbp * p_drain_f));

    // ========================================================================
    // 4.12 Total Charges (Eqs 4.569-4.572)
    // ========================================================================
    const q_scale = mult_q * multf * type_f;

    // Inner fringe capacitance charges (Eqs 4.569-4.571)
    const fif: f64 = @as(f64, model.fifw) * w_e / w_en;
    // Inner fringe charges are proportional to FIF * voltage differences
    const q_gs_if = vgs.scale(fif);
    const q_gd_if = vgd_val.scale(fif);
    const q_bs_if = vbs.neg().scale(fif);
    const q_bd_if = vbs.sub(vds).neg().scale(fif);

    const q_g_tot = q_g_int.add(q_gs_if).add(q_gd_if).add(q_gs_ofr).add(q_gd_ofr).add(q_ovs).add(q_ovd).add(q_gb).scale(q_scale);
    const q_d_tot = q_d_int.add(q_ds).sub(q_gd_if).sub(q_gd_ofr).sub(q_ovd).sub(q_bd_if).sub(q_bd).scale(q_scale);
    const q_b_tot = q_b_int.add(q_bs_if).add(q_bd_if).add(q_bs).add(q_bd).sub(q_gb).scale(q_scale);
    const q_s_tot = q_g_tot.add(q_d_tot).add(q_b_tot).neg();

    // ========================================================================
    // Self-heating thermal charge (Eq 4.524)
    // ========================================================================
    const ctho: f64 = @as(f64, model.ctho);
    const rthl: f64 = @as(f64, model.rthl);
    const rthw: f64 = @as(f64, model.rthw);
    const rthlw: f64 = @as(f64, model.rthlw);
    const cth = ctho / (l_e * w_e) * contract.fmath.exp(rthl * safe_log(le_ratio)) * contract.fmath.exp(rthw * safe_log(we_ratio)) * contract.fmath.exp(rthlw * safe_log(le_ratio * we_ratio));
    const q_th = if (model.swshe == 1) cth * delta_tc else 0.0;

    // ========================================================================
    // Write charge outputs
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d_ext] = S.con(0.0);
    out[s_ext] = S.con(0.0);
    out[g_ext] = S.con(0.0);
    out[b] = q_b_tot;
    out[dp] = q_d_tot;
    out[sp] = q_s_tot;
    out[gp] = q_g_tot;
    out[tn] = S.con(q_th);
    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================
pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;
    const type_f: f64 = @floatFromInt(model.type_);

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);

    // Gate voltage limiting (DEVfetlim)
    {
        const vgs_new = (x_new[gp] - x_new[sp]) * type_f;
        const vgs_old = (x_old[gp] - x_old[sp]) * type_f;
        const vth: f64 = @as(f64, model.vfbo);
        const vgs_lim = fetlim(vgs_new, vgs_old, vth);
        const delta_v = (vgs_lim - vgs_new) * type_f;
        result[gp] = result[gp] + delta_v;
    }

    // Vds limiting (DEVlimvds)
    {
        const vds_new = (x_new[dp] - x_new[sp]) * type_f;
        const vds_old = (x_old[dp] - x_old[sp]) * type_f;
        const vds_lim = limvds(vds_new, vds_old);
        const delta_v = (vds_lim - vds_new) * type_f;
        result[dp] = result[dp] + delta_v;
    }

    // Self-heating temperature limiting
    {
        const tn = @intFromEnum(U.tnode);
        const dt_new = x_new[tn];
        const dt_old = x_old[tn];
        const tmax: f64 = @as(f64, model.tmax);
        const max_step: f64 = 20.0; // Max temperature step per iteration
        const delta_dt = dt_new - dt_old;
        const abs_delta = @abs(delta_dt);
        const dt_lim = if (abs_delta > max_step)
            dt_old + (if (delta_dt > 0.0) max_step else -max_step)
        else
            dt_new;
        result[tn] = @min(@max(dt_lim, -1.0), tmax);
    }

    return result;
}

// ============================================================================
// Parameter Stepping (attempt)
// ============================================================================
pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;

    // Scale subthreshold parameters for convergence
    // Reduce VFB sensitivity at low lambda
    const vfbo_orig: f64 = @as(f64, model.vfbo);
    const vfbo_scaled = vfbo_orig * lambda;
    m.vfbo = @as(f32, @floatCast(vfbo_scaled));

    // Add GMIN conductance scaling at low lambda
    // Scale PSCE (short channel effect) -- easier to converge without SCE
    const pscel_orig: f64 = @as(f64, model.pscel);
    m.pscel = @as(f32, @floatCast(pscel_orig * lambda));

    // Scale CF (DIBL) -- easier without DIBL
    const cfl_orig: f64 = @as(f64, model.cfl);
    m.cfl = @as(f32, @floatCast(cfl_orig * lambda));

    // Scale gate current
    const iginvlw_orig: f64 = @as(f64, model.iginvlw);
    m.iginvlw = @as(f32, @floatCast(iginvlw_orig * lambda));

    // Scale GIDL
    const agidlo_orig: f64 = @as(f64, model.agidlo);
    m.agidlo = @as(f32, @floatCast(agidlo_orig * lambda));

    // Scale impact ionization
    const a1o_orig: f64 = @as(f64, model.a1o);
    m.a1o = @as(f32, @floatCast(a1o_orig * lambda));

    return m;
}

// ============================================================================
// Helper: FET gate voltage limiting (DEVfetlim)
// ============================================================================
fn fetlim(vnew: f64, vold: f64, vth: f64) f64 {
    const vov_new = vnew - vth;
    const vov_old = vold - vth;

    const result = if (vov_new > 0.0 and vov_old > 0.0) blk: {
        const delta = vnew - vold;
        const abs_delta = @abs(delta);
        const twice_vov = 2.0 * vov_old;
        break :blk if (abs_delta > twice_vov) if (delta > 0.0) vold + twice_vov else vold - twice_vov else vnew;
    } else if (vov_new > 0.0)
        vth + 0.5 * vov_new
    else if (vov_old > 0.0)
        vth - 0.5 * vov_old
    else
        vnew;

    return result;
}

// ============================================================================
// Helper: Vds limiting (DEVlimvds)
// ============================================================================
fn limvds(vnew: f64, vold: f64) f64 {
    const delta = vnew - vold;
    const abs_delta = @abs(delta);
    const max_step: f64 = 3.5;

    return if (abs_delta > max_step)
        if (vold >= 0.0)
            vold + (if (delta > 0.0) max_step else -max_step)
        else
            (if (delta > 0.0) @min(vnew, max_step) else vold - max_step)
    else
        vnew;
}

// ============================================================================
// Validation
// ============================================================================
comptime {
    contract.validate(Self);
}

pub fn zpicey_n_u() usize {
    return n_u;
}

pub fn zpicey_num_ports() usize {
    return num_ports;
}

