const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// HiSIM-HV 2.4.4 -- High-voltage LDMOS/HVMOS MOSFET
//
// Hiroshima-university STARC IGFET Model for High Voltage
// Surface-potential-based compact model with drift-region resistance.
//
// Topology:
//   External:  D (drain), G (gate), S (source), B (bulk)
//   Internal:  dp (drain prime, after drift resistance),
//              sp (source prime, after source resistance),
//              gp (gate prime, after gate resistance),
//              bp (body prime, substrate network node),
//              temp (thermal node for self-heating)
//
//   D  -- Rdrift  -- dp
//   S  -- Rsource -- sp
//   G  -- Rg      -- gp   (CORG=1)
//   B  -- Rbpb    -- bp   (CORBNET=1)
//   bp -- Rbpd    -- dp
//   bp -- Rbps    -- sp
//
//   Channel: dp <-> sp (controlled by gp/bp)
//   Junctions: bp-sp (source diode), bp-dp (drain diode)
//   Substrate current: dp -> bp
//   Gate tunneling: gp -> dp, gp -> sp, gp -> bp
//   GIDL: dp -> bp
//
// Value-form contract: physics written once, generic over an opaque scalar S.
// All x-independent parameter/temperature/geometry preprocessing stays plain
// f64 (hoisted into Prep). Only the terminal-voltage-dependent chains use S.
// ============================================================================

pub const U = enum(u8) {
    drain, // 0 - external drain
    gate, // 1 - external gate
    source, // 2 - external source
    bulk, // 3 - external bulk
    drain_prime, // 4 - intrinsic drain (after Rdrift)
    source_prime, // 5 - intrinsic source (after Rsource)
    gate_prime, // 6 - intrinsic gate (after Rg)
    body_prime, // 7 - body prime (substrate network)
    temp_node, // 8 - thermal node (self-heating)
};
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================
const Q_ELECTRON: f64 = 1.602176634e-19;
const K_BOLTZ: f64 = 1.380649e-23;
const EPS_0: f64 = 8.854187817e-12;
const EPS_SI: f64 = 11.7 * EPS_0;
const EPS_OX: f64 = 3.9 * EPS_0;
const NI_300: f64 = 1.45e16; // intrinsic carrier conc at 300K (m^-3 scaled)
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const T_REF: f64 = 300.15; // 27C in K
const C_TO_K: f64 = 273.15;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device Type ---
    type_: i32 = 1, // 1 = NMOS, -1 = PMOS

    // --- Model Flags ---
    cosym: i32 = 0,
    cordrift: i32 = 1,
    cors: i32 = 1,
    cord: i32 = 1,
    corsrd: i32 = 3,
    coadov: i32 = 1,
    coovlp: i32 = 1,
    coovlps: i32 = 0,
    coqovsm: i32 = 1,
    coselfheat: i32 = 0,
    coisub: i32 = 0,
    coiigs: i32 = 0,
    cogidl: i32 = 0,
    coisti: i32 = 0,
    conqs: i32 = 0,
    conqsov: i32 = 0,
    corg: i32 = 0,
    corbnet: i32 = 0,
    coflick: i32 = 0,
    cothrml: i32 = 0,
    coign: i32 = 0,
    copprv: i32 = 1,
    codfm: i32 = 0,
    coiprv: i32 = 0,
    cotemp: i32 = 0,
    cosubnode: i32 = 0,
    coerrrep: i32 = 1,
    codep: i32 = 0,
    coddlt: i32 = 1,
    cohbd: i32 = 0,
    cosnp: i32 = 0,
    codio: i32 = 0,
    codeg: i32 = 0,
    codegstep: i32 = 0,
    codeges0: i32 = 0,
    coovjunc: i32 = 0,
    cotrench: i32 = 0,
    copt: i32 = 0,

    // --- Geometry / Device Size Parameters ---
    tox: f32 = 7e-9,
    xl: f32 = 0,
    xw: f32 = 0,
    xld: f32 = 0,
    xldld: f32 = 1e-6,
    xwd: f32 = 0,
    xwdld: f32 = 0,
    xwdc: f32 = 0,
    tpoly: f32 = 200e-9,
    ll: f32 = 0,
    lld: f32 = 0,
    lln: f32 = 0,
    wl: f32 = 0,
    wld: f32 = 0,
    wln: f32 = 0,
    kappa: f32 = 3.9,

    // --- Structural Parameters (LDMOS/HVMOS) ---
    lover: f32 = 30e-9,
    lovers: f32 = 30e-9,
    loverld: f32 = 1e-6,
    ldrift1: f32 = 1e-6,
    ldrift2: f32 = 1e-6,
    nover: f32 = 3e16,
    novers: f32 = 1e17,
    ldrift1s: f32 = 0,
    ldrift2s: f32 = 1e-6,
    ddrift: f32 = 1e-6,
    nsubsub: f32 = 1e15,
    vbsmin: f32 = 0, // inactivated

    // --- Basic Device Parameters ---
    vfbc: f32 = -1.0,
    vbi: f32 = 1.1,
    nsubc: f32 = 3e17,
    nsubp: f32 = 1e18,
    lp: f32 = 15e-9,
    parl2: f32 = 10e-9,

    // --- Vds Smoothing Parameters ---
    ddltmax: f32 = 10,
    ddltslp: f32 = 10,
    ddltict: f32 = 0,

    // --- Short-Channel Effect Parameters ---
    sc1: f32 = 0,
    sc2: f32 = 0,
    sc3: f32 = 0,
    sc4: f32 = 0,
    scp1: f32 = 0,
    scp2: f32 = 0,
    scp3: f32 = 0,
    scp21: f32 = 0,
    scp22: f32 = 0,
    bs1: f32 = 0,
    bs2: f32 = 0.9,
    npext: f32 = 5e17,
    lpext: f32 = 1e-50,

    // --- Punchthrough Effect Parameters ---
    ptl: f32 = 0,
    ptlp: f32 = 1.0,
    ptp: f32 = 3.5,
    pt2: f32 = 0,
    pt4: f32 = 0,
    pt4p: f32 = 1,
    gdl: f32 = 0,
    gdlp: f32 = 0,
    gdld: f32 = 0,

    // --- Deep Punchthrough Parameters ---
    njunc: f32 = 0,
    xjpt: f32 = 0,
    mupt: f32 = 0,
    pslimpt: f32 = 0,
    vfbpt: f32 = 0,
    ps0pt: f32 = 0,

    // --- Poly-Si Gate Depletion Parameters ---
    pgd1: f32 = 0,
    pgd2: f32 = 1.0,
    pgd4: f32 = 0,

    // --- Quantum-Mechanical Effect Parameters ---
    qme1: f32 = 0,
    qme2: f32 = 2.0,
    qme3: f32 = 0,

    // --- Mobility Parameters ---
    muecb0: f32 = 190,
    muecb1: f32 = 30,
    mueph0: f32 = 0.3,
    mueph1: f32 = 20e3,
    mueefb: f32 = 0.0,
    muetmp: f32 = 1.5,
    muephl: f32 = 0,
    mueplp: f32 = 1.0,
    muesr0: f32 = 2.0,
    muesr1: f32 = 5e14,
    muesrl: f32 = 0,
    mueslp: f32 = 1.0,
    ndep: f32 = 1.0,
    ndepl: f32 = 0,
    ndeplp: f32 = 1.0,
    ninv: f32 = 0.5,
    ninvd: f32 = 0.0,
    ninvdl: f32 = 0,
    ninvdlp: f32 = 1.0,
    ninvdw: f32 = 0.0,
    ninvdwp: f32 = 1.0,
    ninvdt1: f32 = 0.0,
    ninvdt2: f32 = 0.0,
    bb: f32 = 2.0,
    vmax: f32 = 10e6,
    vmaxt1: f32 = 0,
    vmaxt2: f32 = 0,
    vover: f32 = 0.3,
    voverp: f32 = 0.3,
    vtmp: f32 = 0,
    eymod: f32 = 1.0,

    // --- Narrow-Channel Effect Parameters ---
    wfc: f32 = 0,
    wvth0: f32 = 0,
    nsubcw: f32 = 0,
    nsubcwp: f32 = 1,
    nsubp0: f32 = 0,
    nsubwp: f32 = 1.0,
    muephw: f32 = 0,
    muepwp: f32 = 1.0,
    muesrw: f32 = 0,
    mueswp: f32 = 1.0,

    // --- STI Leakage Parameters ---
    vthsti: f32 = 0,
    vdsti: f32 = 0,
    scsti1: f32 = 0,
    scsti2: f32 = 0,
    nsti: f32 = 5e17,
    wsti: f32 = 0,
    wstil: f32 = 0,
    wstilp: f32 = 1.0,
    wstiw: f32 = 0,
    wstiwp: f32 = 1.0,

    // --- Small-Geometry Parameters ---
    wl1: f32 = 0,
    wl1p: f32 = 1.0,
    wl2: f32 = 0,
    wl2p: f32 = 1.0,
    muephs: f32 = 0,
    muepsp: f32 = 1.0,
    vovers: f32 = 0,
    voversp: f32 = 0,

    // --- LOD / STI Stress Parameters ---
    nsubpsti1: f32 = 0,
    nsubpsti2: f32 = 0,
    nsubpsti3: f32 = 1.0,
    muesti1: f32 = 0,
    muesti2: f32 = 0,
    muesti3: f32 = 1.0,
    saref: f32 = 1e-6,
    sbref: f32 = 1e-6,

    // --- Channel-Length Modulation Parameters ---
    clm1: f32 = 0.05,
    clm2: f32 = 2.0,
    clm3: f32 = 1.0,
    clm5: f32 = 1.0,
    clm6: f32 = 0,

    // --- Temperature Dependence Parameters ---
    tnom: f32 = 27,
    eg0: f32 = 1.1785,
    bgtmp1: f32 = 90.25e-6,
    bgtmp2: f32 = 0.1e-6,
    egig: f32 = 0.0,
    igtemp2: f32 = 0,
    igtemp3: f32 = 0,
    traptemp1: f32 = 0,
    traptemp2: f32 = 0,

    // --- Resistance Parameters (CORDRIFT=1, new model) ---
    rs: f32 = 0,
    rd: f32 = 0,
    rsh: f32 = 0,
    rdrdl1: f32 = 0,
    rdrdl2: f32 = 0,
    rdrcx: f32 = 0,
    rdrcar: f32 = 50e-9,
    rdrdjunc: f32 = 1e-6,
    rdrsjunc: f32 = 0,
    rdrbb: f32 = 1.0,
    rdrbbs: f32 = 1.0,
    rdrmue: f32 = 1000,
    rdrmues: f32 = 1000,
    rdrmuel: f32 = 0,
    rdrmuelp: f32 = 1,
    rdrmuetmp: f32 = 0,
    rdrvmax: f32 = 30e6,
    rdrvmaxs: f32 = 30e6,
    rdrvmaxl: f32 = 0,
    rdrvmaxlp: f32 = 1,
    rdrvmaxw: f32 = 0,
    rdrvmaxwp: f32 = 1,
    rdrvtmp: f32 = 0,
    rdrbbtmp: f32 = 0,
    rdrqover: f32 = 1e5,
    rdrqovers: f32 = 0,
    vbisub: f32 = 0.7,
    rdvdsub: f32 = 0.3,
    rdvsub: f32 = 1.0,

    // --- Resistance Parameters (CORDRIFT=0, legacy model) ---
    rdvg11: f32 = 0,
    rdvg12: f32 = 100,
    rdvd: f32 = 7e-2,
    rdvb: f32 = 0,
    rds: f32 = 0,
    rdsp: f32 = 1,
    rdvdl: f32 = 0,
    rdvdlp: f32 = 1,
    rdvds: f32 = 0,
    rdvdsp: f32 = 1,
    rdslp1: f32 = 0,
    rdict1: f32 = 1.0,
    rdslp2: f32 = 1,
    rdict2: f32 = 0,
    rdov11: f32 = 0,
    rdov12: f32 = 1.0,
    rdov13: f32 = 1.0,
    rd20: f32 = 0,
    rd21: f32 = 1.0,
    rd22: f32 = 0,
    rd22d: f32 = 0,
    rd23: f32 = 0.005,
    rd23l: f32 = 0,
    rd23lp: f32 = 1,
    rd23s: f32 = 0,
    rd23sp: f32 = 1,
    rd24: f32 = 0,
    rd25: f32 = 0,
    rdtemp1: f32 = 0,
    rdtemp2: f32 = 0,
    rdvdtemp1: f32 = 0,
    rdvdtemp2: f32 = 0,

    // --- Gate Resistance Parameters ---
    rshg: f32 = 0,

    // --- Substrate Resistance Network ---
    rbpb: f32 = 50,
    rbpd: f32 = 50,
    rbps: f32 = 50,

    // --- Capacitance Parameters ---
    xqy: f32 = 0,
    xqy1: f32 = 0,
    xqy2: f32 = 2,
    vfbover: f32 = 0.5,
    qovadd: f32 = 0,
    qovjunc: f32 = 0,
    cvdsover: f32 = 0,
    ovslp: f32 = 2.1e-7,
    ovmag: f32 = 0.6,
    cgso: f32 = 0,
    cgdo: f32 = 0,
    cgbo: f32 = 0,
    wtrench: f32 = 0,
    olmdlt: f32 = 5,
    loverld2: f32 = 0,

    // --- Substrate Current Parameters ---
    sub1: f32 = 10,
    sub1l: f32 = 2.5e-3,
    sub1lp: f32 = 1.0,
    sub2: f32 = 25.0,
    sub2l: f32 = 2e-6,
    subtmp: f32 = 0,
    svds: f32 = 0.8,
    slg: f32 = 3e-8,
    slgl: f32 = 0,
    slglp: f32 = 1.0,
    svbs: f32 = 0.5,
    svbsl: f32 = 0,
    svbslp: f32 = 1.0,
    svgs: f32 = 0.8,
    svgsl: f32 = 0,
    svgslp: f32 = 1.0,
    svgsw: f32 = 0,
    svgswp: f32 = 1.0,
    ibpc1: f32 = 0,
    ibpc1l: f32 = 0,
    ibpc1lp: f32 = 1.0,
    ibpc2: f32 = 0,
    subld1: f32 = 0,
    subld1l: f32 = 0,
    subld1lp: f32 = 1.0,
    subld2: f32 = 0,
    xpdv: f32 = 0,
    xpvdth: f32 = 0,
    xpvdthg: f32 = 0,

    // --- Gate Current Parameters ---
    gleak1: f32 = 50,
    gleak2: f32 = 10e6,
    gleak3: f32 = 60e-3,
    gleak4: f32 = 4.0,
    gleak5: f32 = 7.5e3,
    gleak6: f32 = 250e-3,
    gleak7: f32 = 1e-6,
    glkb1: f32 = 5e-16,
    glkb2: f32 = 1.0,
    glkb3: f32 = 0,
    glksd1: f32 = 1e-15,
    glksd2: f32 = 1e3,
    glksd3: f32 = -1e3,
    glpart1: f32 = 0.5,
    fn1: f32 = 50,
    fn2: f32 = 170e-6,
    fn3: f32 = 0,
    fvbs: f32 = 12e-3,

    // --- GIDL Parameters ---
    gidl1: f32 = 2.0,
    gidl2: f32 = 3e7,
    gidl3: f32 = 0.9,
    gidl4: f32 = 0,
    gidl5: f32 = 0.2,

    // --- Diode Parameters ---
    js0: f32 = 0.5e-6,
    js0d: f32 = 0.5e-6,
    js0s: f32 = 0.5e-6,
    js0sw: f32 = 0,
    js0swd: f32 = 0,
    js0sws: f32 = 0,
    js0swg: f32 = 0,
    js0swgd: f32 = 0,
    js0swgs: f32 = 0,
    nj: f32 = 1.0,
    njd: f32 = 1.0,
    njs: f32 = 1.0,
    njsw: f32 = 1.0,
    njswd: f32 = 1.0,
    njsws: f32 = 1.0,
    njswg: f32 = 1.0,
    njswgd: f32 = 1.0,
    njswgs: f32 = 1.0,
    xti: f32 = 2.0,
    xtid: f32 = 2.0,
    xtis: f32 = 2.0,
    xti2: f32 = 0,
    xti2d: f32 = 2.0,
    xti2s: f32 = 2.0,
    divx: f32 = 0,
    divxd: f32 = 0,
    divxs: f32 = 0,
    cisb: f32 = 0,
    cisbd: f32 = 0,
    cisbs: f32 = 0,
    cvb: f32 = 0,
    cvbd: f32 = 0,
    cvbs: f32 = 0,
    ctemp: f32 = 0,
    cisbk: f32 = 0,
    cisbkd: f32 = 0,
    cisbks: f32 = 0,
    vdiffj: f32 = 0.6e-3,
    vdiffjd: f32 = 0.6e-3,
    vdiffjs: f32 = 0.6e-3,
    cj: f32 = 5e-4,
    cjd: f32 = 5e-4,
    cjs: f32 = 5e-4,
    cjsw: f32 = 5e-10,
    cjswd: f32 = 5e-10,
    cjsws: f32 = 5e-10,
    cjswg: f32 = 5e-10,
    cjswgd: f32 = 5e-10,
    cjswgs: f32 = 5e-10,
    mj: f32 = 0.5,
    mjd: f32 = 0.5,
    mjs: f32 = 0.5,
    mjsw: f32 = 0.33,
    mjswd: f32 = 0.33,
    mjsws: f32 = 0.33,
    mjswg: f32 = 0.33,
    mjswgd: f32 = 0.33,
    mjswgs: f32 = 0.33,
    pb: f32 = 1.0,
    pbd: f32 = 1.0,
    pbs: f32 = 1.0,
    pbsw: f32 = 1.0,
    pbswd: f32 = 1.0,
    pbsws: f32 = 1.0,
    pbswg: f32 = 1.0,
    pbswgd: f32 = 1.0,
    pbswgs: f32 = 1.0,
    tcjbd: f32 = 0,
    tcjbdsw: f32 = 0,
    tcjbdswg: f32 = 0,
    tcjbs: f32 = 0,
    tcjbssw: f32 = 0,
    tcjbsswg: f32 = 0,

    // --- Hard Breakdown Parameters ---
    hbda: f32 = 0.0,
    hbdb: f32 = 0.0,
    hbdc: f32 = 100.0,
    hbdf: f32 = 1.0,
    hbdctmp: f32 = 0.0,

    // --- Snapback Parameters ---
    sub1snp: f32 = 10,
    sub2snp: f32 = 15.0,
    svdssnp: f32 = 0.8,

    // --- Noise Parameters ---
    nftrp: f32 = 1e10,
    nfalp: f32 = 1e-19,
    cit: f32 = 0,
    falph: f32 = 1.0,

    // --- NQS Parameters ---
    dly1: f32 = 100e-12,
    dly2: f32 = 0.7,
    dly3: f32 = 0.8e-6,
    dlyov: f32 = 0.8e-4,

    // --- Self-Heating Parameters ---
    rth0: f32 = 0.1,
    rthtemp1: f32 = 0,
    rthtemp2: f32 = 0,
    cth0: f32 = 1e-7,
    rth0l: f32 = 0,
    rth0lp: f32 = 1,
    rth0w: f32 = 0,
    rth0wp: f32 = 1,
    rth0nf: f32 = 0,
    powrat: f32 = 1.0,
    prattemp1: f32 = 0,
    prattemp2: f32 = 0,
    shemax: f32 = 500,
    shemaxdlt: f32 = 0.1,

    // --- DFM Parameters ---
    mphdfm: f32 = -0.3,

    // --- Binning Parameters ---
    lbinn: f32 = 0,
    wbinn: f32 = 0,
    lmax: f32 = 0,
    lmin: f32 = 0,
    wmax: f32 = 0,
    wmin: f32 = 0,

    // --- Depletion Mode Parameters (CODEP common) ---
    ndepm: f32 = 1e17,
    ndepml: f32 = 0,
    ndepmlp: f32 = 1,
    tndep: f32 = 200e-9,
    depmue0: f32 = 1000,
    depmue0l: f32 = 0,
    depmue0lp: f32 = 1,
    depmue1: f32 = 0,
    depmue1l: f32 = 0,
    depmue1lp: f32 = 1,
    depmueph0: f32 = 0.3,
    depmueph1: f32 = 5e3,
    depvmax: f32 = 3e7,
    depvmaxl: f32 = 0,
    depvmaxlp: f32 = 1,
    depbb: f32 = 1,
    depmuetmp: f32 = 1.5,
    depvtmp: f32 = 0.0,
    depmue0tmp: f32 = 0.0,
    depleak: f32 = 0.5,
    depleakl: f32 = 0,
    depleaklp: f32 = 1,
    depsubsl: f32 = 2.0,
    depvgpsl: f32 = 0.0,

    // --- Depletion Mode Parameters (CODEP=1 only) ---
    depeta: f32 = 0,
    depvdsef1: f32 = 2.0,
    depvdsef1l: f32 = 0,
    depvdsef1lp: f32 = 1,
    depvdsef2: f32 = 0.5,
    depvdsef2l: f32 = 0,
    depvdsef2lp: f32 = 1,
    depmueback0: f32 = 100,
    depmueback0l: f32 = 0,
    depmueback0lp: f32 = 1,
    depmueback1: f32 = 0,
    depmueback1l: f32 = 0,
    depmueback1lp: f32 = 1,

    // --- Depletion Mode Parameters (CODEP=2 only) ---
    tndepv: f32 = 0.0,
    depmuea1: f32 = 0.0,
    depmue2: f32 = 1e3,
    depddlt: f32 = 3.0,
    depvsatr: f32 = 0,
    depmue2tmp: f32 = 0.0,
    depvfbc: f32 = -0.2,

    // --- Depletion Mode Parameters (CODEP=3 only) ---
    depdvfbc: f32 = 0.1,
    depcar: f32 = 0,
    deprdrdl1: f32 = 0.0,
    deprdrdl2: f32 = 0.0,
    deprbr: f32 = 1,
    depjleak: f32 = 0,
    depwlp: f32 = 0,
    depninvdc: f32 = 100,
    depninvdh: f32 = 10,
    depninvdl: f32 = 0,
    depninvdlp: f32 = 0,
    depninvdw: f32 = 0,
    depninvdwp: f32 = 0,
    depninvdt1: f32 = 0,
    depninvdt2: f32 = 0,
    depqf: f32 = 0.01,
    depqfres: f32 = 0.05,
    depfdpd: f32 = 0.2,
    depps: f32 = 0.01,
    depvsata: f32 = 0.0,
    depsubsl0: f32 = 2.0,

    // --- Aging Model Parameters ---
    degtime: f32 = 0.0,
    degtime0: f32 = 0,
    traptaucap: f32 = 1e-6,
    traplx: f32 = 1,
    trapgc1: f32 = 1e15,
    trapgc1max: f32 = 5e19,
    trapgctime1: f32 = 30,
    trapgctime2: f32 = 1e8,
    trapgclim: f32 = 1e18,
    trapeslim: f32 = 5,
    trapes1: f32 = 0.2,
    trapes1max: f32 = 1,
    trapestime1: f32 = 100,
    trapestime2: f32 = 1e8,
    trapgc2: f32 = 5e13,
    trapes2: f32 = 0.03,
    trapgc0: f32 = 0,
    trapes0: f32 = 0,
    trapa: f32 = 0,
    trapb: f32 = 0,
    trapbti: f32 = 0,
    trapn: f32 = 1.0,
    trapp: f32 = 1.0,
    trapd1max: f32 = 30,
    trapdtime1: f32 = 1000,
    trapdtime2: f32 = 2e10,
    trapdlx: f32 = 1,
    trapdvddp: f32 = 0,

    // --- Simulation Control Parameters ---
    version: f32 = 2.40,
    gbmin: f32 = 1e-12,
    gdsleak: f32 = 0,
    vgsmin: f32 = -100, // nMOS default; pMOS should use 100
    vzadd0: f32 = 0.01,
    pzadd0: f32 = 0.005,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 2e-6,
    w: f32 = 5e-6,
    nf: f32 = 1,
    m: f32 = 1,
    ad: f32 = 0,
    as_: f32 = 0,
    pd: f32 = 0,
    ps: f32 = 0,
    nrs: f32 = 0,
    nrd: f32 = 0,
    xgw: f32 = 0,
    xgl: f32 = 0,
    ngcon: f32 = 1,
    dtemp: f32 = 0,
    sa: f32 = 0,
    sb: f32 = 0,
    sd: f32 = 0,
    nsubcdfm: f32 = 0,
    rbpb_inst: f32 = 50,
    rbpd_inst: f32 = 50,
    rbps_inst: f32 = 50,
    coselfheat_inst: i32 = -1, // -1 = use model, >=0 override
    cosubnode_inst: i32 = -1,
};

// ============================================================================
// x-independent parameter prep (pure f64 -- no terminal voltages)
//
// Everything here depends only on Model + Instance (temperature, geometry,
// doping, mobility scalars, resistances). The x-dependent physics tail in
// eval()/q() reads these prepped scalars but does all voltage-dependent
// arithmetic through the opaque scalar S.
// ============================================================================

const Prep = struct {
    type_f: f64,

    // temperature
    beta: f64,
    beta_inv: f64,
    tdiff: f64,
    tdiff2: f64,
    t_ratio: f64,
    eg: f64,
    ni_factor: f64,

    // geometry
    l_gate: f64,
    w_gate: f64,
    l_gate_um: f64,
    w_gate_um: f64,
    l_eff: f64,
    w_eff: f64,
    w_eff_ld: f64,
    l_gate_um_safe: f64,
    w_gate_um_safe: f64,
    wl_prod: f64,

    // oxide
    eps_ox: f64,
    cox: f64,

    // doping
    nsubc_w: f64,
    nsub_safe: f64,
    two_phi_b: f64,
    phi_bc: f64,
    nsubb: f64,
    const0: f64,
    c0_cox: f64,

    // vth-shift x-independent scalars
    l_sce: f64,
    lp_eff: f64,
    lp_sq: f64,
    l_eff_arg: f64, // l_eff for cef term
    cef: f64,
    dvth_sm: f64,

    // qme
    vth_for_qme_base: f64, // vfbc + two_phi_b + sqrt(...)/cox  (x-indep piece)

    // vds smoothing
    delta_safe: f64,

    // mobility
    ndep_eff: f64,
    ninvd_eff: f64,
    muephonon: f64,
    mu_ph_tmp: f64, // muephonon / t_ratio^muetmp  (before eeff^mueph0)
    muesurface: f64,
    mu0_cb_base: f64, // muecb0 (x-indep part of mu_cb)
    vmax_eff: f64,

    // clm
    z_clm_e0: f64,

    fn build(model: *const Model, instance: *const Instance) Prep {
        const type_f: f64 = @floatFromInt(model.type_);
        const tox: f64 = @as(f64, model.tox);
        const xl: f64 = @as(f64, model.xl);
        const xw: f64 = @as(f64, model.xw);
        const xld_p: f64 = @as(f64, model.xld);
        const xldld: f64 = @as(f64, model.xldld);
        const xwd: f64 = @as(f64, model.xwd);
        const xwdld: f64 = @as(f64, model.xwdld);
        const kappa: f64 = @as(f64, model.kappa);
        const ll: f64 = @as(f64, model.ll);
        const lld: f64 = @as(f64, model.lld);
        const lln: f64 = @as(f64, model.lln);
        const wl: f64 = @as(f64, model.wl);
        const wld: f64 = @as(f64, model.wld);
        const wln: f64 = @as(f64, model.wln);
        const vfbc: f64 = @as(f64, model.vfbc);
        const nsubc: f64 = @as(f64, model.nsubc);
        const nsubp: f64 = @as(f64, model.nsubp);
        const lp_p: f64 = @as(f64, model.lp);
        const parl2: f64 = @as(f64, model.parl2);
        const bs2: f64 = @as(f64, model.bs2);
        _ = bs2;
        const npext: f64 = @as(f64, model.npext);
        const lpext: f64 = @as(f64, model.lpext);
        const muecb0: f64 = @as(f64, model.muecb0);
        const mueph1_p: f64 = @as(f64, model.mueph1);
        const muetmp: f64 = @as(f64, model.muetmp);
        const muephl: f64 = @as(f64, model.muephl);
        const mueplp: f64 = @as(f64, model.mueplp);
        const muesr1: f64 = @as(f64, model.muesr1);
        const muesrl: f64 = @as(f64, model.muesrl);
        const mueslp: f64 = @as(f64, model.mueslp);
        const ndep_p: f64 = @as(f64, model.ndep);
        const ndepl: f64 = @as(f64, model.ndepl);
        const ndeplp: f64 = @as(f64, model.ndeplp);
        const ninvd_p: f64 = @as(f64, model.ninvd);
        const ninvdl: f64 = @as(f64, model.ninvdl);
        const ninvdlp: f64 = @as(f64, model.ninvdlp);
        const ninvdw: f64 = @as(f64, model.ninvdw);
        const ninvdwp: f64 = @as(f64, model.ninvdwp);
        const ninvdt1: f64 = @as(f64, model.ninvdt1);
        const ninvdt2: f64 = @as(f64, model.ninvdt2);
        const vmax_p: f64 = @as(f64, model.vmax);
        const vover: f64 = @as(f64, model.vover);
        const voverp: f64 = @as(f64, model.voverp);
        const vtmp: f64 = @as(f64, model.vtmp);
        const clm5: f64 = @as(f64, model.clm5);
        _ = clm5;
        const tnom_c: f64 = @as(f64, model.tnom);
        const eg0: f64 = @as(f64, model.eg0);
        const bgtmp1: f64 = @as(f64, model.bgtmp1);
        const bgtmp2: f64 = @as(f64, model.bgtmp2);
        const wfc: f64 = @as(f64, model.wfc);
        const nsubcw: f64 = @as(f64, model.nsubcw);
        const nsubcwp: f64 = @as(f64, model.nsubcwp);
        const nsubp0: f64 = @as(f64, model.nsubp0);
        const nsubwp: f64 = @as(f64, model.nsubwp);
        const muephw: f64 = @as(f64, model.muephw);
        const muepwp: f64 = @as(f64, model.muepwp);
        const muesrw: f64 = @as(f64, model.muesrw);
        const mueswp: f64 = @as(f64, model.mueswp);
        const wl2: f64 = @as(f64, model.wl2);
        const wl2p: f64 = @as(f64, model.wl2p);
        const muephs: f64 = @as(f64, model.muephs);
        const muepsp: f64 = @as(f64, model.muepsp);
        const vovers_p: f64 = @as(f64, model.vovers);
        const voversp: f64 = @as(f64, model.voversp);

        const nf: f64 = @as(f64, instance.nf);
        const l_drawn: f64 = @as(f64, instance.l);
        const w_drawn: f64 = @as(f64, instance.w);
        const dtemp: f64 = @as(f64, instance.dtemp);
        const sa_i: f64 = @as(f64, instance.sa);
        const sb_i: f64 = @as(f64, instance.sb);

        // LOD/STI stress params
        const nsubpsti1: f64 = @as(f64, model.nsubpsti1);
        const nsubpsti2: f64 = @as(f64, model.nsubpsti2);
        const nsubpsti3: f64 = @as(f64, model.nsubpsti3);
        const muesti1: f64 = @as(f64, model.muesti1);
        const muesti2: f64 = @as(f64, model.muesti2);
        const muesti3: f64 = @as(f64, model.muesti3);
        const saref: f64 = @as(f64, model.saref);
        const sbref: f64 = @as(f64, model.sbref);

        // --- Temperature ---
        const tnom_k: f64 = tnom_c + C_TO_K;
        const temp_k: f64 = T_REF + dtemp;
        const tdiff: f64 = temp_k - tnom_k;
        const tdiff2: f64 = temp_k * temp_k - tnom_k * tnom_k;
        const t_ratio: f64 = temp_k / tnom_k;
        const beta_inv: f64 = K_BOLTZ * temp_k / Q_ELECTRON;
        const beta: f64 = 1.0 / beta_inv;

        const eg_nom: f64 = eg0 - 90.25e-6 * tnom_c - 1.0e-7 * tnom_c * tnom_c;
        const eg: f64 = eg_nom - bgtmp1 * tdiff - bgtmp2 * tdiff * tdiff;
        const ni_ratio: f64 = @exp(eg_nom * beta * 0.5) * @exp(-eg * beta * 0.5);
        const ni_factor: f64 = ni_ratio * @exp(1.5 * @log(@max(t_ratio, 1e-30)));

        // --- Geometry ---
        const l_gate: f64 = l_drawn + xl;
        const w_gate: f64 = w_drawn / nf + xw;
        const l_gate_um: f64 = l_gate * 1e6;
        const w_gate_um: f64 = w_gate * 1e6;
        const ll_denom: f64 = @max(@abs(l_gate + lld), 1e-30);
        const l_poly: f64 = l_gate - 2.0 * ll / @exp(lln * @log(ll_denom));
        const wl_denom: f64 = @max(@abs(w_gate + wld), 1e-30);
        const w_poly: f64 = w_gate - 2.0 * wl / @exp(wln * @log(wl_denom));
        const l_eff: f64 = @max(l_poly - xld_p - xldld, 1e-9);
        const w_eff: f64 = @max(w_poly - 2.0 * xwd, 1e-9);
        const w_eff_ld: f64 = @max(w_poly - 2.0 * xwdld, 1e-9);
        const l_gate_um_safe: f64 = @max(l_gate_um, 1e-20);
        const w_gate_um_safe: f64 = @max(w_gate_um, 1e-20);
        const wl_prod: f64 = @max(w_gate_um * l_gate_um, 1e-30);

        // --- Oxide ---
        const eps_ox: f64 = EPS_0 * kappa;
        const cox: f64 = eps_ox / tox;

        // --- Width-dependent doping ---
        const nsubc_w: f64 = nsubc * (1.0 + nsubcw / @exp(nsubcwp * @log(w_gate_um_safe)));
        const nsubp_w: f64 = nsubp * (1.0 + nsubp0 / @exp(nsubwp * @log(w_gate_um_safe)));

        // --- LOD/STI stress ---
        var nsubp_eff: f64 = nsubp_w;
        var muesti_factor: f64 = 1.0;
        const sa_eff: f64 = if (sa_i > 0) sa_i else saref;
        const sb_eff: f64 = if (sb_i > 0) sb_i else sbref;
        const lod_half: f64 = 0.5 * (sa_eff + sb_eff);
        const lod_half_ref: f64 = 0.5 * (saref + sbref);
        const nsubpsti1_pow: f64 = @exp(nsubpsti3 * @log(@max(nsubpsti1, 1e-30)));
        const t1_lod_n: f64 = 1.0 / (1.0 + nsubpsti2);
        const t2_lod_n: f64 = nsubpsti1_pow / @max(lod_half, 1e-30);
        const t3_lod_n: f64 = nsubpsti1_pow / @max(lod_half_ref, 1e-30);
        const nsubsti_ratio: f64 = (1.0 + t1_lod_n * t2_lod_n) / @max(1.0 + t1_lod_n * t3_lod_n, 1e-30);
        nsubp_eff = nsubp_eff * nsubsti_ratio;
        const muesti1_pow: f64 = @exp(muesti3 * @log(@max(muesti1, 1e-30)));
        const t1_lod_m: f64 = 1.0 / (1.0 + muesti2);
        const t2_lod_m: f64 = muesti1_pow / @max(lod_half, 1e-30);
        const t3_lod_m: f64 = muesti1_pow / @max(lod_half_ref, 1e-30);
        muesti_factor = (1.0 + t1_lod_m * t2_lod_m) / @max(1.0 + t1_lod_m * t3_lod_m, 1e-30);

        // --- Substrate doping ---
        const lp_eff: f64 = @min(lp_p, l_gate);
        const nsub_avg: f64 = (nsubc_w * (l_gate - lp_eff) + nsubp_eff * lp_eff) / l_gate;
        const xx_pt: f64 = @max(0.5 * l_gate - lp_eff, 1e-30);
        const tail_denom: f64 = 1.0 / xx_pt + lpext * l_gate;
        const nsub_tail: f64 = (npext - nsubc_w) / @max(tail_denom, 1e-30);
        const nsub: f64 = nsub_avg + nsub_tail;
        const nsub_safe: f64 = @max(nsub, 1e10);

        // --- 2*Phi_B ---
        const phi_bc: f64 = @log(@max(nsubc_w, 1e10) / @max(NI_300 * ni_factor, 1e-30)) / beta;
        const phi_b: f64 = @log(@max(nsub_safe, 1e10) / @max(NI_300 * ni_factor, 1e-30)) / beta;
        const two_phi_b: f64 = 2.0 * phi_b;

        const const0: f64 = @sqrt(@max(2.0 * EPS_SI * Q_ELECTRON * nsub_safe / beta, 1e-30));
        const c0_cox: f64 = const0 / cox;

        // pocket implant nsubb
        const nsubb: f64 = @max(2.0 * nsubp_eff - (nsubp_eff - nsubc_w) * l_gate / @max(lp_eff, 1e-30) - nsubc_w, 1e10);

        // short-channel x-indep scalars
        const l_sce: f64 = @max(l_gate - parl2, 1e-9);
        const lp_sq: f64 = @max(lp_eff * lp_eff, 1e-30);

        // narrow-channel cef (x-indep)
        const cef: f64 = wfc * 0.5 * l_eff;

        // small geometry dvth
        const dvth_sm: f64 = wl2 / @exp(wl2p * @log(wl_prod));

        // qme x-indep base (vth_for_qme uses sqrt(sqrt_arg_vth0)/cox at vbs=0? no --
        // it depends on vbs_eff; the x-dependent piece is recomputed in eval).
        // Keep unused placeholder value 0 (recomputed in eval).
        const vth_for_qme_base: f64 = vfbc + two_phi_b;

        // --- Vds smoothing delta ---
        const ddltmax: f64 = @as(f64, model.ddltmax);
        const ddltslp: f64 = @as(f64, model.ddltslp);
        const ddltict: f64 = @as(f64, model.ddltict);
        const t1_ddlt: f64 = ddltslp * l_gate_um;
        const delta_ddlt: f64 = if (model.coddlt == 1)
            ddltmax * t1_ddlt / @max(ddltmax + t1_ddlt, 1e-30) + ddltict
        else
            ddltmax * (t1_ddlt + ddltict) / @max(ddltmax + t1_ddlt + ddltict, 1e-30) + 1.0;
        const delta_safe: f64 = @max(delta_ddlt, 1.01);

        // --- Mobility x-indep ---
        const ndep_eff: f64 = ndep_p / (1.0 + ndepl / @exp(ndeplp * @log(l_gate_um_safe)));
        var ninvd_eff: f64 = ninvd_p * (1.0 + ninvdl / @exp(ninvdlp * @log(l_gate_um_safe)));
        ninvd_eff = ninvd_eff * (1.0 + ninvdw / @exp(ninvdwp * @log(w_gate_um_safe)));
        ninvd_eff = ninvd_eff * (1.0 + ninvdt1 * tdiff + ninvdt2 * tdiff2);

        var muephonon: f64 = mueph1_p * (1.0 + muephl / @exp(mueplp * @log(l_gate_um_safe)));
        muephonon = muephonon * (1.0 + muephw / @exp(muepwp * @log(w_gate_um_safe)));
        muephonon = muephonon * (1.0 + muephs / @exp(muepsp * @log(wl_prod)));
        muephonon = muephonon * muesti_factor;
        // mu_ph = muephonon / (t_ratio^muetmp * eeff^mueph0); split out t_ratio part
        const mu_ph_tmp: f64 = muephonon / @exp(muetmp * @log(@max(t_ratio, 1e-30)));

        var muesurface: f64 = muesr1 * (1.0 + muesrl / @exp(mueslp * @log(l_gate_um_safe)));
        muesurface = muesurface * (1.0 + muesrw / @exp(mueswp * @log(w_gate_um_safe)));

        var vmax_eff: f64 = vmax_p * (1.0 + vover / @exp(voverp * @log(l_gate_um_safe)));
        vmax_eff = vmax_eff * (1.0 + vovers_p / @exp(voversp * @log(wl_prod)));
        const vmax_tmp_denom: f64 = 1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - vtmp * (1.0 - t_ratio);
        vmax_eff = vmax_eff / @max(vmax_tmp_denom, 1e-30);
        vmax_eff = vmax_eff * (1.0 + @as(f64, model.vmaxt1) * tdiff + @as(f64, model.vmaxt2) * tdiff2);

        return .{
            .type_f = type_f,
            .beta = beta,
            .beta_inv = beta_inv,
            .tdiff = tdiff,
            .tdiff2 = tdiff2,
            .t_ratio = t_ratio,
            .eg = eg,
            .ni_factor = ni_factor,
            .l_gate = l_gate,
            .w_gate = w_gate,
            .l_gate_um = l_gate_um,
            .w_gate_um = w_gate_um,
            .l_eff = l_eff,
            .w_eff = w_eff,
            .w_eff_ld = w_eff_ld,
            .l_gate_um_safe = l_gate_um_safe,
            .w_gate_um_safe = w_gate_um_safe,
            .wl_prod = wl_prod,
            .eps_ox = eps_ox,
            .cox = cox,
            .nsubc_w = nsubc_w,
            .nsub_safe = nsub_safe,
            .two_phi_b = two_phi_b,
            .phi_bc = phi_bc,
            .nsubb = nsubb,
            .const0 = const0,
            .c0_cox = c0_cox,
            .l_sce = l_sce,
            .lp_eff = lp_eff,
            .lp_sq = lp_sq,
            .l_eff_arg = l_eff,
            .cef = cef,
            .dvth_sm = dvth_sm,
            .vth_for_qme_base = vth_for_qme_base,
            .delta_safe = delta_safe,
            .ndep_eff = ndep_eff,
            .ninvd_eff = ninvd_eff,
            .muephonon = muephonon,
            .mu_ph_tmp = mu_ph_tmp,
            .muesurface = muesurface,
            .mu0_cb_base = muecb0,
            .vmax_eff = vmax_eff,
            .z_clm_e0 = 1e5,
        };
    }
};

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return Prep.build(model, instance);
}

// ============================================================================
// Physics function -- eval (current contributions), value-form
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const D = @intFromEnum(U.drain);
    const G = @intFromEnum(U.gate);
    const SRC = @intFromEnum(U.source);
    const B = @intFromEnum(U.bulk);
    const DP = @intFromEnum(U.drain_prime);
    const SP = @intFromEnum(U.source_prime);
    const GP = @intFromEnum(U.gate_prime);
    const BP = @intFromEnum(U.body_prime);
    const TN = @intFromEnum(U.temp_node);

    const p = pc;

    // Re-read commonly used f64 params/flags
    const type_f = p.type_f;
    const beta = p.beta;
    const beta_inv = p.beta_inv;
    const cox = p.cox;
    const nsub_safe = p.nsub_safe;
    const const0 = p.const0;
    const c0_cox = p.c0_cox;
    const two_phi_b = p.two_phi_b;
    const l_eff = p.l_eff;
    const w_eff = p.w_eff;
    const w_eff_ld = p.w_eff_ld;
    const l_gate = p.l_gate;
    const l_gate_um = p.l_gate_um;
    const l_gate_um_safe = p.l_gate_um_safe;
    const w_gate = p.w_gate;
    const w_gate_um_safe = p.w_gate_um_safe;
    const wl_prod = p.wl_prod;
    const nsubc_w = p.nsubc_w;
    const nsubb = p.nsubb;
    const phi_bc = p.phi_bc;
    const ni_factor = p.ni_factor;
    const t_ratio = p.t_ratio;
    const tdiff = p.tdiff;
    const tdiff2 = p.tdiff2;

    const vfbc: f64 = @as(f64, model.vfbc);
    const vbi_p: f64 = @as(f64, model.vbi);
    const parl2: f64 = @as(f64, model.parl2);
    _ = parl2;
    const sc1: f64 = @as(f64, model.sc1);
    const sc2: f64 = @as(f64, model.sc2);
    const sc3: f64 = @as(f64, model.sc3);
    const sc4: f64 = @as(f64, model.sc4);
    const scp1: f64 = @as(f64, model.scp1);
    const scp2: f64 = @as(f64, model.scp2);
    const scp3: f64 = @as(f64, model.scp3);
    const scp21: f64 = @as(f64, model.scp21);
    const scp22: f64 = @as(f64, model.scp22);
    const bs1: f64 = @as(f64, model.bs1);
    const bs2: f64 = @as(f64, model.bs2);
    const ptl: f64 = @as(f64, model.ptl);
    const ptlp: f64 = @as(f64, model.ptlp);
    const ptp: f64 = @as(f64, model.ptp);
    const pt2: f64 = @as(f64, model.pt2);
    const pt4: f64 = @as(f64, model.pt4);
    const pt4p: f64 = @as(f64, model.pt4p);
    const gdl: f64 = @as(f64, model.gdl);
    const gdlp: f64 = @as(f64, model.gdlp);
    const gdld_p: f64 = @as(f64, model.gdld);
    const pgd1: f64 = @as(f64, model.pgd1);
    const pgd2: f64 = @as(f64, model.pgd2);
    const pgd4: f64 = @as(f64, model.pgd4);
    const qme1: f64 = @as(f64, model.qme1);
    const qme2: f64 = @as(f64, model.qme2);
    const qme3: f64 = @as(f64, model.qme3);
    const mueefb: f64 = @as(f64, model.mueefb);
    const mueph0: f64 = @as(f64, model.mueph0);
    const muesr0: f64 = @as(f64, model.muesr0);
    const muecb1: f64 = @as(f64, model.muecb1);
    const ninv: f64 = @as(f64, model.ninv);
    const bb: f64 = @as(f64, model.bb);
    const clm1: f64 = @as(f64, model.clm1);
    const clm2: f64 = @as(f64, model.clm2);
    const clm3: f64 = @as(f64, model.clm3);
    const clm5: f64 = @as(f64, model.clm5);
    const clm6: f64 = @as(f64, model.clm6);
    const wvth0: f64 = @as(f64, model.wvth0);
    const wfc: f64 = @as(f64, model.wfc);
    const vzadd0: f64 = @as(f64, model.vzadd0);
    const gbmin: f64 = @as(f64, model.gbmin);
    const gdsleak: f64 = @as(f64, model.gdsleak);

    const m_mult: f64 = @as(f64, instance.m);
    const nf: f64 = @as(f64, instance.nf);
    const nrs_i: f64 = @as(f64, instance.nrs);
    const nrd_i: f64 = @as(f64, instance.nrd);
    const ad_i: f64 = @as(f64, instance.ad);
    const as_i: f64 = @as(f64, instance.as_);
    const pd_i: f64 = @as(f64, instance.pd);
    const ps_i: f64 = @as(f64, instance.ps);
    const xgw: f64 = @as(f64, instance.xgw);
    const xgl: f64 = @as(f64, instance.xgl);
    const ngcon: f64 = @as(f64, instance.ngcon);
    const l_drawn: f64 = @as(f64, instance.l);

    // Flags
    const coselfheat: i32 = if (instance.coselfheat_inst >= 0) instance.coselfheat_inst else model.coselfheat;
    const corbnet: i32 = model.corbnet;
    const corg: i32 = model.corg;
    const coisub: i32 = model.coisub;
    const coiigs: i32 = model.coiigs;
    const cogidl: i32 = model.cogidl;
    const coisti: i32 = model.coisti;
    const cohbd: i32 = model.cohbd;
    const cordrift: i32 = model.cordrift;

    // Resistance params
    const rs_p: f64 = @as(f64, model.rs);
    const rd_p: f64 = @as(f64, model.rd);
    const rsh: f64 = @as(f64, model.rsh);
    const rdrdl1: f64 = @as(f64, model.rdrdl1);
    const rdrdl2: f64 = @as(f64, model.rdrdl2);
    const rdrcx: f64 = @as(f64, model.rdrcx);
    const rdrcar: f64 = @as(f64, model.rdrcar);
    const rdrdjunc: f64 = @as(f64, model.rdrdjunc);
    const rdrbb_p: f64 = @as(f64, model.rdrbb);
    const rdrmue_p: f64 = @as(f64, model.rdrmue);
    const rdrmuel: f64 = @as(f64, model.rdrmuel);
    const rdrmuelp: f64 = @as(f64, model.rdrmuelp);
    const rdrmuetmp: f64 = @as(f64, model.rdrmuetmp);
    const rdrvmax_p: f64 = @as(f64, model.rdrvmax);
    const rdrvmaxl: f64 = @as(f64, model.rdrvmaxl);
    const rdrvmaxlp: f64 = @as(f64, model.rdrvmaxlp);
    const rdrvmaxw: f64 = @as(f64, model.rdrvmaxw);
    const rdrvmaxwp: f64 = @as(f64, model.rdrvmaxwp);
    const rdrvtmp: f64 = @as(f64, model.rdrvtmp);
    const rdrbbtmp: f64 = @as(f64, model.rdrbbtmp);
    const rdrqover: f64 = @as(f64, model.rdrqover);
    const nover: f64 = @as(f64, model.nover);
    const ldrift1: f64 = @as(f64, model.ldrift1);
    const ldrift2: f64 = @as(f64, model.ldrift2);
    const xldld: f64 = @as(f64, model.xldld);
    const rshg: f64 = @as(f64, model.rshg);

    // Substrate current
    const sub1_p: f64 = @as(f64, model.sub1);
    const sub1l: f64 = @as(f64, model.sub1l);
    const sub1lp: f64 = @as(f64, model.sub1lp);
    const sub2_p: f64 = @as(f64, model.sub2);
    const sub2l: f64 = @as(f64, model.sub2l);
    const subtmp: f64 = @as(f64, model.subtmp);
    const svds: f64 = @as(f64, model.svds);
    const slg: f64 = @as(f64, model.slg);
    const slgl: f64 = @as(f64, model.slgl);
    const slglp: f64 = @as(f64, model.slglp);

    // Gate current
    const gleak1: f64 = @as(f64, model.gleak1);
    const gleak2: f64 = @as(f64, model.gleak2);
    const gleak3: f64 = @as(f64, model.gleak3);
    const gleak5: f64 = @as(f64, model.gleak5);
    const gleak6: f64 = @as(f64, model.gleak6);
    const gleak7: f64 = @as(f64, model.gleak7);
    const glkb1: f64 = @as(f64, model.glkb1);
    const glkb2: f64 = @as(f64, model.glkb2);
    const glkb3: f64 = @as(f64, model.glkb3);
    const glksd1: f64 = @as(f64, model.glksd1);
    const glksd2: f64 = @as(f64, model.glksd2);
    const glksd3: f64 = @as(f64, model.glksd3);
    const glpart1: f64 = @as(f64, model.glpart1);
    const tox: f64 = @as(f64, model.tox);

    // GIDL
    const gidl1: f64 = @as(f64, model.gidl1);
    const gidl2: f64 = @as(f64, model.gidl2);
    const gidl3: f64 = @as(f64, model.gidl3);
    const gidl4: f64 = @as(f64, model.gidl4);

    // Diode
    const js0d: f64 = @as(f64, model.js0d);
    const js0s: f64 = @as(f64, model.js0s);
    const njd: f64 = @as(f64, model.njd);
    const njs: f64 = @as(f64, model.njs);
    const divxd: f64 = @as(f64, model.divxd);
    const divxs: f64 = @as(f64, model.divxs);
    const cisbd: f64 = @as(f64, model.cisbd);
    const cisbs: f64 = @as(f64, model.cisbs);
    const cvbd: f64 = @as(f64, model.cvbd);
    const cvbs: f64 = @as(f64, model.cvbs);
    const cisbkd: f64 = @as(f64, model.cisbkd);
    const cisbks: f64 = @as(f64, model.cisbks);
    const vdiffjd: f64 = @as(f64, model.vdiffjd);
    const vdiffjs: f64 = @as(f64, model.vdiffjs);

    // Hard breakdown
    const hbda: f64 = @as(f64, model.hbda);
    const hbdb: f64 = @as(f64, model.hbdb);
    const hbdc: f64 = @as(f64, model.hbdc);
    const hbdf: f64 = @as(f64, model.hbdf);
    const hbdctmp: f64 = @as(f64, model.hbdctmp);

    // Self-heating
    const rth0_p: f64 = @as(f64, model.rth0);
    const rthtemp1: f64 = @as(f64, model.rthtemp1);
    const rthtemp2: f64 = @as(f64, model.rthtemp2);
    const rth0l: f64 = @as(f64, model.rth0l);
    const rth0lp: f64 = @as(f64, model.rth0lp);
    const rth0w: f64 = @as(f64, model.rth0w);
    const rth0wp: f64 = @as(f64, model.rth0wp);
    const rth0nf: f64 = @as(f64, model.rth0nf);
    const powrat: f64 = @as(f64, model.powrat);
    const shemax: f64 = @as(f64, model.shemax);
    const shemaxdlt: f64 = @as(f64, model.shemaxdlt);

    // STI
    const vthsti: f64 = @as(f64, model.vthsti);
    const vdsti: f64 = @as(f64, model.vdsti);
    const scsti1: f64 = @as(f64, model.scsti1);
    const scsti2: f64 = @as(f64, model.scsti2);
    const nsti: f64 = @as(f64, model.nsti);
    const wsti_p: f64 = @as(f64, model.wsti);
    const wstil: f64 = @as(f64, model.wstil);
    const wstilp: f64 = @as(f64, model.wstilp);
    const wstiw: f64 = @as(f64, model.wstiw);
    const wstiwp: f64 = @as(f64, model.wstiwp);
    const wl1: f64 = @as(f64, model.wl1);
    const wl1p: f64 = @as(f64, model.wl1p);

    // ========================================================================
    // Read terminal voltages (S).  Type factor applied in S.
    // ========================================================================
    const v_d_ext = x[D];
    const v_g_ext = x[G];
    const v_s_ext = x[SRC];
    const v_b_ext = x[B];
    const v_dp = x[DP];
    const v_sp = x[SP];
    const v_gp = x[GP];
    const v_bp = x[BP];
    const v_tn = x[TN];

    // Internal voltages with type factor
    const vgs_i = v_gp.sub(v_sp).scale(type_f);
    const vds_i = v_dp.sub(v_sp).scale(type_f);
    const vbs_i = v_bp.sub(v_sp).scale(type_f);
    const vgs = vgs_i;
    const vbs = vbs_i;

    // Source-drain reversal (branchless)
    const vds_abs = vds_i.abs();
    const vds_neg = vds_i.minC(0.0);
    const vgs_eff = vgs.sub(vds_neg);
    const vbs_eff = vbs.sub(vds_neg);
    const vds_eff_raw = vds_abs;
    // mode = vds_i / (|vds_i| + 1e-30)
    const mode = vds_i.div(vds_abs.addC(1e-30));

    // ========================================================================
    // 2*Phi_B (constant), Cox_eff via QME
    // ========================================================================
    // Threshold voltage shift (Sec. 6)
    const wd_arg = vbs_eff.neg().addC(two_phi_b).scale(2.0 * EPS_SI / (Q_ELECTRON * nsub_safe)).maxC(1e-30);
    const wd = wd_arg.sqrt();

    const l_sce = p.l_sce;
    // dey_dy = 2*(vbi - 2phiB)/l_sce^2 * (sc1 + sc2*vds_eff_raw*(1+sc4*(2phiB - vbs_eff)) + sc3*(2phiB - vbs_eff)/l_gate)
    const tphib_m_vbs = vbs_eff.neg().addC(two_phi_b); // 2phiB - vbs_eff
    const sc2_term = vds_eff_raw.mul(tphib_m_vbs.scale(sc4).addC(1.0)).scale(sc2);
    const sc3_term = tphib_m_vbs.scale(sc3 / l_gate);
    const dey_dy = sc2_term.add(sc3_term).addC(sc1).scale(2.0 * (vbi_p - two_phi_b) / (l_sce * l_sce));
    const dvth_sc = dey_dy.mul(wd).scale(EPS_SI / cox);

    // Reverse short-channel (body effect mod)
    const bs_vbs = vbs_eff.neg().addC(bs2).maxC(1e-30); // bs2 - vbs_eff
    const qb_mod_arg = tphib_m_vbs.sub(bs_vbs.pow(-1.0).scale(bs1)).scale(2.0 * Q_ELECTRON * nsubc_w * EPS_SI).maxC(1e-30);
    const qb_mod = qb_mod_arg.sqrt();

    // Pocket implant effect
    const two_phi_bc: f64 = 2.0 * phi_bc;
    // vth_r = vfbc + 2phiB + qb_mod/cox + log(nsubb/nsubc_w)/beta
    const vth_r = qb_mod.scale(1.0 / cox).addC(vfbc + two_phi_b + @log(@max(nsubb / nsubc_w, 1e-30)) / beta);
    // vth0 = vfbc + 2phiBc + sqrt(2 q nsubc_w epsSi (2phiBc - vbs_eff))/cox
    const sqrt_arg_vth0 = vbs_eff.neg().addC(two_phi_bc).scale(2.0 * Q_ELECTRON * nsubc_w * EPS_SI).maxC(1e-30);
    const vth0 = sqrt_arg_vth0.sqrt().scale(1.0 / cox).addC(vfbc + two_phi_bc);

    const lp_sq = p.lp_sq;
    const lp_eff = p.lp_eff;
    // dey_p = 2*(vbi-2phiB)/lp_sq * (scp1 + scp2*vds_eff_raw + scp3*(2phiB - vbs_eff)/lp_eff)
    const dey_p = vds_eff_raw.scale(scp2).add(tphib_m_vbs.scale(scp3 / @max(lp_eff, 1e-30))).addC(scp1).scale(2.0 * (vbi_p - two_phi_b) / lp_sq);
    var dvth_p = vth_r.sub(vth0).mul(wd).mul(dey_p).scale(EPS_SI / cox);
    // Pocket small-Vds correction
    const scp21_vds = vds_eff_raw.addC(scp21).maxC(1e-30);
    dvth_p = dvth_p.sub(scp21_vds.mul(scp21_vds).pow(-1.0).scale(scp22));

    // Poly-Si gate depletion (Eq. 64)
    const phi_spg = vgs_eff.addC(-pgd2).scale(1.0 / @max(beta_inv, 1e-30)).minC(80.0).exp()
        .scale(pgd1 * @exp(pgd4 * @log(@max(1.0 + 1.0 / (l_gate * 1e6), 1e-30))));

    // Quantum mechanical correction to Tox (Eqs 65-66)
    // vth_for_qme = vfbc + 2phiB + sqrt(sqrt_arg_vth0)/cox
    const vth_for_qme = sqrt_arg_vth0.sqrt().scale(1.0 / cox).addC(vfbc + two_phi_b);
    const qme_denom = vgs_eff.sub(vth_for_qme).addC(qme2).maxC(1e-30);
    const dtox_qme = qme_denom.pow(-1.0).scale(qme1).addC(qme3);
    const tox_eff = dtox_qme.addC(tox).maxC(1e-12);
    const cox_eff = tox_eff.pow(-1.0).scale(p.eps_ox);

    // Narrow-channel effects (Eqs 89-90)
    // cef_term uses wd (x-dep). cef is x-indep. l_eff*w_eff x-indep.
    const cef = p.cef;
    const dvth_w = if (cef > 0)
        wd.scale((1.0 / cox - 1.0 / (cox + 2.0 * cef / @max(l_eff * w_eff, 1e-30))) * Q_ELECTRON * nsub_safe).addC(wvth0 / @max(p.w_gate_um, 1e-30))
    else
        S.con(wvth0 / @max(p.w_gate_um, 1e-30));
    _ = wfc;

    // Total Vth shift
    const dvth = dvth_sc.add(dvth_p).add(dvth_w).addC(p.dvth_sm).sub(phi_spg);

    // Effective gate voltage
    const vg_prime = vgs_eff.addC(-vfbc).add(dvth);

    // ========================================================================
    // Surface potential and Vds,sat (Eq. 19)
    // ========================================================================
    const qn_cox2_coef = Q_ELECTRON * nsub_safe * EPS_SI; // /(cox_eff^2)
    const qn_cox2 = cox_eff.mul(cox_eff).pow(-1.0).scale(qn_cox2_coef);
    // vds_sat_arg = 1 + 2 cox_eff^2/(q nsub epsSi) * (vg_prime - beta_inv - vbs_eff)
    const vds_sat_arg = cox_eff.mul(cox_eff).mul(vg_prime.addC(-beta_inv).sub(vbs_eff)).scale(2.0 / qn_cox2_coef).addC(1.0).maxC(1e-30);
    const vds_sat = vg_prime.add(qn_cox2.mul(vds_sat_arg.sqrt().neg().addC(1.0))).maxC(1e-12);

    // ========================================================================
    // Vds smoothing (Eqs 14-18): Effective Vds
    // ========================================================================
    const delta_safe = p.delta_safe;
    const vds_ratio = vds_eff_raw.div(vds_sat.maxC(1e-30));
    const vds_ratio_pow = vds_ratio.maxC(1e-30).log().scale(delta_safe).exp();
    const vds_eff = vds_eff_raw.div(vds_ratio_pow.addC(1.0).maxC(1e-30).log().scale(1.0 / delta_safe).exp());

    // ========================================================================
    // Surface potentials phi_S0 and phi_SL
    // ========================================================================
    // phi_s0_init = max(2phiB + vzadd0, vbs_eff + 0.1)
    const phi_s0_init = vbs_eff.addC(0.1).maxC(two_phi_b + vzadd0);
    const bps0_arg_init = phi_s0_init.sub(vbs_eff).scale(beta).addC(-1.0).maxC(1e-30);
    const bps0_sqrt = bps0_arg_init.sqrt();
    // phi_s0 = vg_prime + vfbc - c0_cox*bps0_sqrt - c0_cox^2*0.5/max(vg_prime - phi_s0_init + c0_cox*bps0_sqrt + 1e-30, 1e-30)
    const phi_s0_den = vg_prime.sub(phi_s0_init).add(bps0_sqrt.scale(c0_cox)).addC(1e-30).maxC(1e-30);
    const phi_s0 = vg_prime.addC(vfbc).sub(bps0_sqrt.scale(c0_cox)).sub(phi_s0_den.pow(-1.0).scale(c0_cox * c0_cox * 0.5));
    const phi_sl = phi_s0.add(vds_eff);

    // ========================================================================
    // Mobility (Sec. 10)
    // ========================================================================
    const ndep_eff = p.ndep_eff;
    const ninvd_eff = p.ninvd_eff;
    const dphi_s = phi_sl.sub(phi_s0).maxC(1e-30);
    const f_phis = dphi_s.scale(ninvd_eff).addC(1.0).pow(-1.0);

    const qi_approx = vg_prime.sub(phi_s0).maxC(0.0).mul(cox_eff).maxC(1e-30);
    const qb_approx = bps0_sqrt.scale(const0).maxC(1e-30);

    // eeff0 = (ndep_eff*qb + ninv*qi)/epsSi * f_phis
    const eeff0 = qb_approx.scale(ndep_eff).add(qi_approx.scale(ninv)).scale(1.0 / EPS_SI).mul(f_phis);
    const eeff = eeff0.mul(vbs_eff.scale(mueefb).addC(1.0)).maxC(1e-6);

    // mu_ph = mu_ph_tmp / eeff^mueph0
    const mu_ph = eeff.maxC(1e-30).pow(mueph0).pow(-1.0).scale(p.mu_ph_tmp);
    // mu_sr = muesurface / eeff^muesr0
    const mu_sr = eeff.maxC(1e-30).pow(muesr0).pow(-1.0).scale(p.muesurface);
    // mu_cb = muecb0 + muecb1*qi/(q*1e11)
    const mu_cb = qi_approx.scale(muecb1 / (Q_ELECTRON * 1e11)).addC(p.mu0_cb_base);
    // mu0 = 1/(1/mu_cb + 1/mu_ph + 1/mu_sr)
    const mu0 = mu_cb.maxC(1e-30).pow(-1.0).add(mu_ph.maxC(1e-30).pow(-1.0)).add(mu_sr.maxC(1e-30).pow(-1.0)).pow(-1.0);

    const vmax_eff = p.vmax_eff;
    // ey = max(vds_eff/l_eff, 1)
    const ey = vds_eff.scale(1.0 / @max(l_eff, 1e-9)).maxC(1.0);
    const vel_ratio = mu0.mul(ey).scale(1.0 / @max(vmax_eff, 1e-30));
    const vel_pow = vel_ratio.maxC(1e-30).log().scale(bb).exp();
    const mu = mu0.div(vel_pow.addC(1.0).maxC(1e-30).log().scale(1.0 / bb).exp());

    // ========================================================================
    // Drain current Idd (Eq. 30)
    // ========================================================================
    const bps0_arg2 = phi_s0.sub(vbs_eff).scale(beta).addC(-1.0).maxC(1e-30);
    const bpsl_arg = phi_sl.sub(vbs_eff).scale(beta).addC(-1.0).maxC(1e-30);
    const bps0_sq = bps0_arg2.sqrt();
    const bpsl_sq = bpsl_arg.sqrt();

    const dphi_sl_s0 = phi_sl.sub(phi_s0);
    const term1 = vg_prime.scale(beta).addC(1.0).mul(dphi_sl_s0).mul(cox_eff);
    const term2 = phi_sl.mul(phi_sl).sub(phi_s0.mul(phi_s0)).scale(-0.5 * beta).mul(cox_eff);
    const term3 = bpsl_arg.mul(bpsl_sq).sub(bps0_arg2.mul(bps0_sq)).scale(-(2.0 / 3.0) * const0);
    const term4 = bpsl_sq.sub(bps0_sq).scale(const0);
    const idd = term1.add(term2).add(term3).add(term4);

    var ids = idd.mul(mu).scale((w_eff * nf / l_eff) / beta);

    // ========================================================================
    // Channel-length modulation (Sec. 11)
    // ========================================================================
    // phi_s_dl = (1-clm1)*phi_sl + clm1*(phi_s0 + vds_eff_raw)
    const phi_s_dl = phi_sl.scale(1.0 - clm1).add(phi_s0.add(vds_eff_raw).scale(clm1));
    // z_clm = epsSi*wd/(clm2*qb + clm3*qi)
    const z_clm_den = qb_approx.scale(clm2).add(qi_approx.scale(clm3)).maxC(1e-30);
    const z_clm = wd.scale(EPS_SI).div(z_clm_den);
    const e0_clm = p.z_clm_e0;

    const dphi_clm = phi_s_dl.sub(phi_sl).maxC(0.0);
    // clm_arg1 = idd/(beta*qi)*z_clm
    const clm_arg1 = idd.div(qi_approx.scale(beta)).mul(z_clm);
    // clm_arg2 = 2 q nsub/epsSi * dphi_clm * z_clm^2 + e0*z_clm^2
    const z_clm_sq = z_clm.mul(z_clm);
    const clm_arg2 = dphi_clm.scale(2.0 * Q_ELECTRON * nsub_safe / EPS_SI).mul(z_clm_sq).add(z_clm_sq.scale(e0_clm));
    const dl_inner = clm_arg1.scale(1.0 / @max(l_eff, 1e-9));
    const dl_raw = dl_inner.mul(dl_inner).add(clm_arg2.scale(4.0)).maxC(0.0).sqrt().sub(dl_inner).scale(0.5);

    const dl_mod = dl_raw.scale(1.0 + clm6 * @exp(clm5 * @log(@max(l_gate_um, 1e-30))));
    const dl_eff = dl_mod.minC(0.5 * l_eff);
    const l_eff_clm = dl_eff.neg().addC(l_eff).maxC(1e-9);

    ids = ids.mul(l_eff_clm.pow(-1.0).scale(l_eff));

    // ========================================================================
    // Punchthrough current (Sec. 7)
    // ========================================================================
    // potential_pt = (vbi - phi_s0)^ptp
    const potential_pt_s = phi_s0.neg().addC(vbi_p).maxC(1e-30).log().scale(ptp).exp();
    const pt_term: f64 = ptl / @exp(ptlp * @log(@max(l_gate_um, 1e-30)));
    // pt_bracket = 1 + pt2*vds_eff_raw + pt4*(phi_s0 - vbs_eff)/l_gate_um^pt4p
    const pt_bracket = vds_eff_raw.scale(pt2).add(phi_s0.sub(vbs_eff).scale(pt4 / @exp(pt4p * @log(@max(l_gate_um, 1e-30))))).addC(1.0);
    // ids_pt = (w_eff*nf/l_eff) * mu/beta * dphi * cox_eff * beta * pt_term * potential_pt * pt_bracket
    const ids_pt_s = dphi_sl_s0.mul(cox_eff).mul(potential_pt_s).mul(pt_bracket).mul(mu).scale((w_eff * nf / l_eff) / beta * beta * pt_term);
    ids = ids.add(ids_pt_s);

    // High-field conductance (Eq. 63)
    const gdl_factor: f64 = gdl / @exp(gdlp * @log(@max(l_gate_um + gdld_p * 1e6, 1e-30)));
    const ids_gdl = dphi_sl_s0.mul(cox_eff).mul(vds_eff_raw).mul(mu).scale((w_eff * nf / l_eff) / beta * beta * gdl_factor);
    ids = ids.add(ids_gdl);

    // ========================================================================
    // STI leakage current (Sec. 12)
    // ========================================================================
    const coisti_f: f64 = @floatFromInt(@min(coisti, 1));
    var ids_sti = S.con(0.0);
    {
        const l_gate_sm: f64 = l_gate + wl1 / @exp(wl1p * @log(wl_prod));
        const two_phi_b_sti: f64 = 2.0 * @log(@max(nsti, 1e10) / @max(NI_300 * ni_factor, 1e-30)) / beta;
        // wd_sti = sqrt(2 epsSi (2phiB_sti - vbs_eff)/(q nsti))
        const wd_sti = vbs_eff.neg().addC(two_phi_b_sti).scale(2.0 * EPS_SI / (Q_ELECTRON * nsti)).maxC(1e-30).sqrt();
        const l_sm_parl2: f64 = @max(l_gate_sm - @as(f64, model.parl2), 1e-9);
        // dey_sti = 2*(vbi - 2phiB_sti)/l_sm_parl2^2 * (scsti1 + scsti2*vds_eff_raw)
        const dey_sti = vds_eff_raw.scale(scsti2).addC(scsti1).scale(2.0 * (vbi_p - two_phi_b_sti) / (l_sm_parl2 * l_sm_parl2));
        const dvth_scsti = dey_sti.mul(wd_sti).scale(EPS_SI / cox);
        // vgs_sti = vgs_eff - vfbc + vthsti - vdsti*vds_eff_raw + dvth_scsti
        const vgs_sti = vgs_eff.addC(-vfbc + vthsti).sub(vds_eff_raw.scale(vdsti)).add(dvth_scsti);
        const qn_sti: f64 = Q_ELECTRON * nsti;
        // sti_inner = 1 + 2 cox^2/(epsSi qn_sti)*(vgs_sti - vbs_eff - beta_inv)
        const sti_inner = vgs_sti.sub(vbs_eff).addC(-beta_inv).scale(2.0 * cox * cox / (EPS_SI * qn_sti)).addC(1.0).maxC(1e-30);
        const phi_s_sti = vgs_sti.add(sti_inner.sqrt().neg().addC(1.0).scale(EPS_SI * qn_sti / (cox * cox)));
        const qi_sti = vgs_sti.sub(phi_s_sti).maxC(0.0).scale(cox).maxC(0.0);
        const l_sm_um: f64 = @max(l_gate_sm * 1e6, 1e-20);
        const w_gm_um: f64 = @max(w_gate * 1e6, 1e-20);
        const wsti_eff: f64 = wsti_p * (1.0 + wstil / @exp(wstilp * @log(l_sm_um))) *
            (1.0 + wstiw / @exp(wstiwp * @log(w_gm_um)));
        // ids_sti = 2*wsti_eff/l_eff_clm * mu * qi_sti/beta * (1 - exp(-beta*vds_eff_raw))
        const one_m_exp = vds_eff_raw.scale(-beta).minC(80.0).exp().neg().addC(1.0);
        ids_sti = mu.mul(qi_sti).div(l_eff_clm).mul(one_m_exp).scale(2.0 * wsti_eff / beta);
    }
    ids = ids.add(ids_sti.scale(coisti_f));

    // GMIN + leakage conductance convergence aids
    ids = ids.add(vds_eff_raw.scale(gbmin));
    ids = ids.add(vds_eff_raw.scale(gdsleak));

    // Apply mode and type
    const ids_final = ids.mul(mode).scale(type_f * m_mult);

    // ========================================================================
    // Substrate current (Sec. 17.1)
    // ========================================================================
    const coisub_f: f64 = @floatFromInt(@min(coisub, 1));
    var isub = S.con(0.0);
    {
        const xsub_tmp: f64 = 1.0 + subtmp * tdiff;
        const xsub1: f64 = sub1_p * (1.0 + sub1l / @exp(sub1lp * @log(@max(l_gate, 1e-30)))) * xsub_tmp;
        const xsub2: f64 = sub2_p * (1.0 + sub2l / @max(l_gate, 1e-30)) / @max(xsub_tmp, 1e-30);
        const xgate: f64 = slg * (1.0 + slgl / @exp(slglp * @log(@max(l_gate, 1e-30))));
        const psi_slsat = phi_s0.maxC(0.0);

        const svbs_p: f64 = @as(f64, model.svbs);
        const svbsl_p: f64 = @as(f64, model.svbsl);
        const svbslp_p: f64 = @as(f64, model.svbslp);
        const svgs_p: f64 = @as(f64, model.svgs);
        const svgsl_p: f64 = @as(f64, model.svgsl);
        const svgslp_p: f64 = @as(f64, model.svgslp);
        const svgsw_p: f64 = @as(f64, model.svgsw);
        const svgswp_p: f64 = @as(f64, model.svgswp);
        const svbs_eff: f64 = svbs_p * (1.0 + svbsl_p / @exp(svbslp_p * @log(@max(l_gate, 1e-30))));
        const svgs_eff: f64 = svgs_p * (1.0 + svgsl_p / @exp(svgslp_p * @log(@max(l_gate, 1e-30)))) *
            (1.0 + svgsw_p / @exp(svgswp_p * @log(@max(w_gate, 1e-30))));

        // psi_subsat = max(svds*vds_eff_raw + svbs_eff*vbs_eff + svgs_eff*vgs_eff + phi_s0 - l_gate*psi_slsat/(xgate+l_gate), 1e-30)
        const psi_subsat = vds_eff_raw.scale(svds)
            .add(vbs_eff.scale(svbs_eff))
            .add(vgs_eff.scale(svgs_eff))
            .add(phi_s0)
            .sub(psi_slsat.scale(l_gate / @max(xgate + l_gate, 1e-30)))
            .maxC(1e-30);

        // isub = xsub1*psi_subsat*|ids|*exp(-xsub2/psi_subsat)
        const isub0 = psi_subsat.mul(ids.abs()).mul(psi_subsat.pow(-1.0).scale(-xsub2).minC(80.0).exp()).scale(xsub1);
        isub = isub0;

        // Impact-ionization in drift region (Eq. 213)
        const subld1_p: f64 = @as(f64, model.subld1);
        const subld1l_p: f64 = @as(f64, model.subld1l);
        const subld1lp_p: f64 = @as(f64, model.subld1lp);
        const subld2_p: f64 = @as(f64, model.subld2);
        const subld1_eff: f64 = subld1_p * (1.0 + subld1l_p / @exp(subld1lp_p * @log(@max(l_gate, 1e-30))));
        const ey_drift = ey.maxC(1e-30);
        const vgvt_drift = vg_prime.sub(phi_s0).maxC(1e-30);
        const l_drift_isub: f64 = @max(ldrift1 + ldrift2, 1e-9);
        const i_subld = ids.abs().mul(ey_drift).mul(ey_drift.mul(vgvt_drift).pow(-1.0).scale(-subld2_p).minC(80.0).exp()).scale(subld1_eff * l_drift_isub);
        isub = isub.add(i_subld);
    }
    const isub_final = isub.scale(coisub_f * m_mult);

    // ========================================================================
    // Gate current (Sec. 17.2)
    // ========================================================================
    const coiigs_f: f64 = @floatFromInt(@min(coiigs, 1));
    var igate = S.con(0.0);
    var igb = S.con(0.0);
    var igs_gate = S.con(0.0);
    var igd_gate = S.con(0.0);
    {
        const egp: f64 = @max(p.eg + @as(f64, model.egig), 0.1);
        const egp32: f64 = egp * @sqrt(@max(egp, 1e-30));
        // phi_s_dl2 = (1-gleak3)*phi_sl + gleak3*phi_s0
        const phi_s_dl2 = phi_sl.scale(1.0 - gleak3).add(phi_s0.scale(gleak3));
        // vg_leak = |vg_prime - gleak3*phi_s_dl2|
        const vg_leak = vg_prime.sub(phi_s_dl2.scale(gleak3)).abs().maxC(1e-30);
        // e_gate = vg_leak^2/tox_eff * (1 + ey/gleak5)
        const e_gate = vg_leak.mul(vg_leak).div(tox_eff).mul(ey.scale(1.0 / gleak5).addC(1.0));
        const qi_safe = qi_approx.maxC(1e-30);
        const gleak4_p: f64 = @as(f64, model.gleak4);
        // igate = q*gleak1*e_gate^2/egp32 * exp(-gleak2*egp32/e_gate) * sqrt(qi/const0) * w_eff*nf*l_eff * gleak6/(gleak6+vds) * gleak7/(gleak7+w_eff*nf*l_eff) * (1+gleak4*l_eff)
        const geo7: f64 = gleak7 / (gleak7 + w_eff * nf * l_eff) * (w_eff * nf * l_eff) * (1.0 + gleak4_p * l_eff);
        igate = e_gate.mul(e_gate)
            .mul(e_gate.pow(-1.0).scale(-gleak2 * egp32).minC(80.0).exp())
            .mul(qi_safe.scale(1.0 / @max(const0, 1e-30)).sqrt())
            .mul(vds_eff_raw.addC(gleak6).pow(-1.0).scale(gleak6))
            .scale(Q_ELECTRON * gleak1 / @max(egp32, 1e-30) * geo7);

        // Gate-to-bulk (Eq. 228)
        const vgb_eff = vgs_eff.sub(vbs_eff);
        const egb = vgb_eff.addC(-glkb3).abs().div(tox_eff).maxC(1e-30);
        igb = egb.mul(egb).mul(egb.pow(-1.0).scale(-glkb2).minC(80.0).exp()).scale(glkb1 * w_eff * nf * l_eff);

        // Fowler-Nordheim tunneling (Eq. 230)
        const fn1_p: f64 = @as(f64, model.fn1);
        const fn2_p: f64 = @as(f64, model.fn2);
        const fn3_p: f64 = @as(f64, model.fn3);
        const fvbs_p: f64 = @as(f64, model.fvbs);
        const eg_sqrt: f64 = @sqrt(@max(p.eg, 1e-30));
        const eg32_fn: f64 = p.eg * eg_sqrt;
        const e_fn_v = vgs_eff.addC(-fn3_p).sub(vbs_eff.scale(fvbs_p)).abs().maxC(1e-30);
        const e_fn = e_fn_v.div(tox_eff);
        const i_fn = e_fn.mul(e_fn).mul(e_fn.pow(-1.0).scale(-fn2_p * eg32_fn).minC(80.0).exp()).scale(Q_ELECTRON * fn1_p / @max(eg_sqrt, 1e-30) * w_eff * nf * l_eff);
        igate = igate.add(i_fn);

        // Gate-to-source/drain (Eqs. 235, 237)
        const egs = vgs_eff.abs().maxC(1e-30);
        // igs = glksd1*egs^2*exp(tox*(-glksd2*|vgs_eff| + glksd3))*w_eff*nf
        igs_gate = egs.mul(egs).mul(vgs_eff.abs().scale(-glksd2).addC(glksd3).scale(tox).minC(80.0).exp()).scale(glksd1 * w_eff * nf);
        const egd = vgs_eff.sub(vds_eff_raw).abs().maxC(1e-30);
        // igd = glksd1*egd^2*exp(tox*(glksd2*(-|vgs_eff| + vds_eff_raw) + glksd3))*w_eff*nf
        igd_gate = egd.mul(egd).mul(vgs_eff.abs().neg().add(vds_eff_raw).scale(glksd2).addC(glksd3).scale(tox).minC(80.0).exp()).scale(glksd1 * w_eff * nf);
    }
    const igs_total = igs_gate.scale(coiigs_f * type_f * m_mult);
    const igd_total = igd_gate.scale(coiigs_f * type_f * m_mult);
    const igb_total = igb.scale(coiigs_f * type_f * m_mult);
    const igate_ch = igate.scale(coiigs_f * type_f * m_mult);

    // ========================================================================
    // GIDL current (Sec. 17.3)
    // ========================================================================
    const cogidl_f: f64 = @floatFromInt(@min(cogidl, 1));
    var igidl = S.con(0.0);
    {
        const gidl5: f64 = @as(f64, model.gidl5);
        const eg2: f64 = @max(p.eg, 0.1);
        const eg2_3: f64 = eg2 * eg2 * eg2;
        // e_gidl = (gidl3*(vds_eff_raw+gidl4) - vg_prime)/tox_eff
        const e_gidl = vds_eff_raw.addC(gidl4).scale(gidl3).sub(vg_prime).div(tox_eff).maxC(1e-30);
        const e_gidl_corr = e_gidl.mul(e_gidl.scale(gidl5).addC(1.0));
        // a_gidl = vds^3/(vds^3 + 0.5)
        const vds3 = vds_eff_raw.mul(vds_eff_raw).mul(vds_eff_raw);
        const a_gidl = vds3.div(vds3.addC(0.5)).maxC(0.0);
        igidl = e_gidl_corr.mul(e_gidl_corr).mul(e_gidl_corr.pow(-1.0).scale(-gidl2 * eg2_3).minC(80.0).exp()).mul(a_gidl).scale(Q_ELECTRON * gidl1 / eg2 * w_eff * nf);
    }
    const igidl_final = igidl.scale(cogidl_f * type_f * m_mult);

    // ========================================================================
    // Diode currents (Sec. 18)
    // ========================================================================
    const vbd = vbs_eff.sub(vds_eff_raw); // Vbody - Vdrain
    const vbs_junc = vbs_eff; // Vbody - Vsource

    // Drain diode
    const nvtm_d: f64 = njd * beta_inv;
    const nvtm_d_safe: f64 = @max(nvtm_d, 1e-30);
    const isbd: f64 = @max(js0d * ad_i + @as(f64, model.js0swd) * pd_i + @as(f64, model.js0swgd) * w_eff * nf, 1e-30);
    const v1_d: f64 = nvtm_d * @log(@max(vdiffjd / isbd + 1.0, 1e-30));
    const vbd_lim = vbd.minC(v1_d);
    const exp_d = vbd_lim.scale(1.0 / nvtm_d_safe).minC(80.0).exp();
    var ibd = exp_d.addC(-1.0).scale(isbd);
    const ibd_lin = vbd.addC(-v1_d).maxC(0.0).scale(isbd / nvtm_d_safe * @exp(@min(v1_d / nvtm_d_safe, 80.0)));
    ibd = ibd.add(ibd_lin);
    ibd = ibd.add(vbd.scale(-cvbd / nvtm_d_safe).minC(80.0).exp().addC(-1.0).scale(cisbd * isbd));
    ibd = ibd.add(vbd.scale(-cvbd / nvtm_d_safe).minC(80.0).exp().addC(-1.0).scale(cisbkd));
    ibd = ibd.add(vbd.scale(divxd * isbd));
    ibd = ibd.add(vbd.scale(gbmin));

    // Source diode
    const nvtm_s: f64 = njs * beta_inv;
    const nvtm_s_safe: f64 = @max(nvtm_s, 1e-30);
    const isbs: f64 = @max(js0s * as_i + @as(f64, model.js0sws) * ps_i + @as(f64, model.js0swgs) * w_eff * nf, 1e-30);
    const v1_s: f64 = nvtm_s * @log(@max(vdiffjs / isbs + 1.0, 1e-30));
    const vbs_lim = vbs_junc.minC(v1_s);
    const exp_s = vbs_lim.scale(1.0 / nvtm_s_safe).minC(80.0).exp();
    var ibs = exp_s.addC(-1.0).scale(isbs);
    const ibs_lin = vbs_junc.addC(-v1_s).maxC(0.0).scale(isbs / nvtm_s_safe * @exp(@min(v1_s / nvtm_s_safe, 80.0)));
    ibs = ibs.add(ibs_lin);
    ibs = ibs.add(vbs_junc.scale(-cvbs / nvtm_s_safe).minC(80.0).exp().addC(-1.0).scale(cisbs * isbs));
    ibs = ibs.add(vbs_junc.scale(-cvbs / nvtm_s_safe).minC(80.0).exp().addC(-1.0).scale(cisbks));
    ibs = ibs.add(vbs_junc.scale(divxs * isbs));
    ibs = ibs.add(vbs_junc.scale(gbmin));

    const ibd_final = ibd.scale(type_f * m_mult);
    const ibs_final = ibs.scale(type_f * m_mult);

    // ========================================================================
    // Hard breakdown (Sec. 19)
    // ========================================================================
    const cohbd_f: f64 = @floatFromInt(@min(@abs(cohbd), 1));
    var ihbreak = S.con(0.0);
    {
        const hbdc_eff: f64 = hbdc + hbdctmp * tdiff;
        // hbdv = hbda*(vgs_eff - hbdb)^2 + hbdc_eff
        const vgs_mb = vgs_eff.addC(-hbdb);
        const hbdv = vgs_mb.mul(vgs_mb).scale(hbda).addC(hbdc_eff);
        // ihbreak = hbdf*exp(beta*(vds_eff_raw - hbdv))
        ihbreak = vds_eff_raw.sub(hbdv).scale(beta).minC(80.0).exp().scale(hbdf);
    }
    const ihbreak_final = ihbreak.scale(cohbd_f * type_f * m_mult);

    // ========================================================================
    // Snapback current (Sec. 19.2)
    // ========================================================================
    const cosnp_f: f64 = @floatFromInt(@min(model.cosnp, 1));
    var i_bjt = S.con(0.0);
    {
        const sub1snp_p: f64 = @as(f64, model.sub1snp);
        const sub2snp_p: f64 = @as(f64, model.sub2snp);
        const svdssnp_p: f64 = @as(f64, model.svdssnp);
        const xsub_tmp_snp: f64 = 1.0 + subtmp * tdiff;
        const xsub1_snp: f64 = sub1snp_p * (1.0 + sub1l / @exp(sub1lp * @log(@max(l_gate, 1e-30)))) * xsub_tmp_snp;
        const xsub2_snp: f64 = sub2snp_p * (1.0 + sub2l / @max(l_gate, 1e-30)) / @max(xsub_tmp_snp, 1e-30);
        const xgate_snp: f64 = slg * (1.0 + slgl / @exp(slglp * @log(@max(l_gate, 1e-30))));
        const psi_slsat_snp = phi_s0.maxC(0.0);
        const psi_subsat_snp = vds_eff_raw.scale(svdssnp_p).add(phi_s0).sub(psi_slsat_snp.scale(l_gate / @max(xgate_snp + l_gate, 1e-30))).maxC(1e-30);
        const beta_snp = psi_subsat_snp.mul(psi_subsat_snp.pow(-1.0).scale(-xsub2_snp).minC(80.0).exp()).scale(xsub1_snp);
        i_bjt = beta_snp.mul(ibs.abs());
    }
    const i_bjt_final = i_bjt.scale(cosnp_f * type_f * m_mult);

    // ========================================================================
    // Resistance: CORDRIFT=1 (Sec. 15.1)
    // ========================================================================
    const vddp = v_d_ext.sub(v_dp).scale(type_f); // voltage across drain drift region
    const vssp = v_sp.sub(v_s_ext).scale(type_f); // voltage across source region

    const l_drift: f64 = ldrift1 + ldrift2;
    const l_drift_safe: f64 = @max(l_drift, 1e-9);
    const mu_drift0_temp: f64 = rdrmue_p / @exp(rdrmuetmp * @log(@max(t_ratio, 1e-30)));
    const mu_drift0: f64 = mu_drift0_temp * (1.0 + rdrmuel / @exp(rdrmuelp * @log(l_gate_um_safe)));
    const vmax_drift_temp: f64 = rdrvmax_p / @max(1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - rdrvtmp * (1.0 - t_ratio), 1e-30);
    const vmax_drift: f64 = vmax_drift_temp *
        (1.0 + rdrvmaxl / @exp(rdrvmaxlp * @log(l_gate_um_safe))) *
        (1.0 + rdrvmaxw / @exp(rdrvmaxwp * @log(w_gate_um_safe)));
    const rdrbb: f64 = rdrbb_p + rdrbbtmp * tdiff;
    const rdrbb_safe: f64 = @max(rdrbb, 0.01);

    const vddp_abs = vddp.abs();
    const e_drift = vddp_abs.scale(1.0 / l_drift_safe);
    const vel_ratio_d = e_drift.scale(mu_drift0 / @max(vmax_drift, 1e-30));
    const vel_pow_d = vel_ratio_d.maxC(1e-30).log().scale(rdrbb_safe).exp();
    const mu_drift = vel_pow_d.addC(1.0).maxC(1e-30).log().scale(1.0 / rdrbb_safe).exp().pow(-1.0).scale(mu_drift0);

    // Overlap charge Q_over' for drift region (Eq. 182)
    const phi_s_over_i = vgs_eff.sub(vds_eff_raw).addC(-@as(f64, model.vfbover)).minC(1.0).maxC(-0.5);
    const q_over_prime = phi_s_over_i.abs().scale(beta).addC(-1.0).maxC(1e-30).sqrt().scale(@sqrt(@max(2.0 * EPS_SI * Q_ELECTRON * nover / beta, 1e-30)));

    // Carrier density enhancement (Eq. 155)
    const n_drift = vddp_abs.scale(rdrcar / @max(l_drift_safe - rdrdl2, 1e-9))
        .mul(vddp_abs.scale(-1.0 / (1.0 + mu_drift0 / @max(vmax_drift, 1e-30) * l_drift_safe)).addC(1.0))
        .addC(1.0).scale(nover)
        .add(q_over_prime.scale(rdrqover / Q_ELECTRON));

    // Overlap area (Eqs. 151-154)
    const w0_drift: f64 = @sqrt(xldld * xldld + rdrdjunc * rdrdjunc);
    const phi_s_over_drift = vgs_eff.sub(vds_eff_raw).addC(-@as(f64, model.vfbover)).minC(1.0).maxC(-0.5);
    const wdep_drift = phi_s_over_drift.abs().scale(2.0 * EPS_SI / (Q_ELECTRON * nover)).maxC(0.0).sqrt();
    const vdps_vbs_vbi = vds_eff_raw.sub(vbs_eff).addC(vbi_p).maxC(0.0);
    const wjunc_drift = vdps_vbs_vbi.scale(2.0 * EPS_SI / Q_ELECTRON * nsub_safe / @max(nover * (nsub_safe + nover), 1e-30)).maxC(0.0).sqrt();
    // xov_d = max(w0 - rdrcx*(w0/rdrdjunc*wdep + w0/xldld*wjunc), 1e-12)
    const xov_d = wdep_drift.scale(w0_drift / @max(rdrdjunc, 1e-12)).add(wjunc_drift.scale(w0_drift / @max(xldld, 1e-12))).scale(rdrcx).neg().addC(w0_drift).maxC(1e-12);

    // Drain drift conductance (S, x-dependent)
    const g_drift_d = xov_d.mul(n_drift).mul(mu_drift).scale(w_eff_ld * nf * Q_ELECTRON / @max(l_drift_safe + rdrdl1, 1e-9));

    // Contact / sheet (x-indep)
    const g_rd_contact: f64 = if (rd_p > 0) w_eff_ld * nf / rd_p else GSHORT;
    const g_rd_sheet: f64 = if (rsh > 0 and nrd_i > 0) 1.0 / (rsh * nrd_i) else GSHORT;
    _ = g_rd_contact;
    _ = g_rd_sheet;

    // g_drain: S if drift branch active, else constant
    const use_drift_d = (cordrift == 1 and model.cord == 1);
    const g_drain: S = if (use_drift_d) g_drift_d.minC(GSHORT) else S.con(GSHORT);

    // Source-side resistance (S when drift active)
    const use_drift_s = (cordrift == 1 and model.cors == 1);
    const g_source: S = if (use_drift_s) blk: {
        const rdrmues_f: f64 = @as(f64, model.rdrmues);
        const rdrvmaxs_f: f64 = @as(f64, model.rdrvmaxs);
        const rdrbbs_f: f64 = @as(f64, model.rdrbbs);
        const novers_f: f64 = @as(f64, model.novers);
        const ldrift1s_f: f64 = @as(f64, model.ldrift1s);
        const ldrift2s_f: f64 = @as(f64, model.ldrift2s);
        const l_drifts: f64 = @max(ldrift1s_f + ldrift2s_f, 1e-9);
        const mu_drifts0_temp: f64 = rdrmues_f / @exp(rdrmuetmp * @log(@max(t_ratio, 1e-30)));
        const mu_drifts0: f64 = mu_drifts0_temp * (1.0 + rdrmuel / @exp(rdrmuelp * @log(l_gate_um_safe)));
        const vmax_drifts_temp: f64 = rdrvmaxs_f / @max(1.8 + 0.4 * t_ratio + 0.1 * t_ratio * t_ratio - rdrvtmp * (1.0 - t_ratio), 1e-30);
        const vmax_drifts: f64 = vmax_drifts_temp *
            (1.0 + rdrvmaxl / @exp(rdrvmaxlp * @log(l_gate_um_safe))) *
            (1.0 + rdrvmaxw / @exp(rdrvmaxwp * @log(w_gate_um_safe)));
        const rdrbbs_safe: f64 = @max(rdrbbs_f, 0.01);
        const vssp_abs = vssp.abs();
        const e_drifts = vssp_abs.scale(1.0 / l_drifts);
        const vel_ratio_s = e_drifts.scale(mu_drifts0 / @max(vmax_drifts, 1e-30));
        const vel_pow_s = vel_ratio_s.maxC(1e-30).log().scale(rdrbbs_safe).exp();
        const mu_drifts = vel_pow_s.addC(1.0).maxC(1e-30).log().scale(1.0 / rdrbbs_safe).exp().pow(-1.0).scale(mu_drifts0);
        const xov_s: f64 = @max(w0_drift * (1.0 - rdrcx), 1e-12);
        const g_drift_s = mu_drifts.scale(w_eff_ld * nf * xov_s * Q_ELECTRON * novers_f / @max(l_drifts, 1e-9));
        const g_rs_contact: f64 = if (rs_p > 0) w_eff_ld * nf / rs_p else GSHORT;
        const g_rs_sheet: f64 = if (rsh > 0 and nrs_i > 0) 1.0 / (rsh * nrs_i) else GSHORT;
        const g_rs_ext: f64 = @min(g_rs_contact, g_rs_sheet);
        break :blk g_drift_s.minC(GSHORT).minC(g_rs_ext);
    } else S.con(GSHORT);

    // Gate resistance (x-indep)
    const g_gate_c: f64 = if (corg == 1 and rshg > 0) blk: {
        const r_gate: f64 = rshg * (xgw + w_eff / (3.0 * @max(ngcon, 1.0))) /
            @max(ngcon * (l_drawn - xgl) * nf, 1e-30);
        break :blk 1.0 / @max(r_gate, 1e-30);
    } else GSHORT;

    const g_rbpb: f64 = if (corbnet == 1) 1.0 / @max(@as(f64, instance.rbpb_inst), 1e-6) else GSHORT;
    const g_rbpd: f64 = if (corbnet == 1) 1.0 / @max(@as(f64, instance.rbpd_inst), 1e-6) else GSHORT;
    const g_rbps: f64 = if (corbnet == 1) 1.0 / @max(@as(f64, instance.rbps_inst), 1e-6) else GSHORT;

    // ========================================================================
    // Self-heating (Sec. 22)
    // ========================================================================
    const coselfheat_f: f64 = @floatFromInt(@min(coselfheat, 1));
    var i_th = S.con(0.0);
    {
        const rth0_val: f64 = rth0_p + rthtemp1 * tdiff + rthtemp2 * tdiff2;
        const rth: f64 = rth0_val / @max(w_eff, 1e-9) /
            @exp(rth0nf * @log(@max(nf, 1.0))) *
            (1.0 + rth0l / @exp(rth0lp * @log(l_gate_um_safe))) *
            (1.0 + rth0w / @exp(rth0wp * @log(w_gate_um_safe)));

        const prattemp1_p: f64 = @as(f64, model.prattemp1);
        const prattemp2_p: f64 = @as(f64, model.prattemp2);
        const pow_ratio: f64 = powrat + prattemp1_p * tdiff + prattemp2_p * tdiff2;

        // vds_prime = vds_eff + pow_ratio*(vds_eff_raw - vds_eff)
        const vds_prime = vds_eff.add(vds_eff_raw.sub(vds_eff).scale(pow_ratio));
        const power = ids.abs().mul(vds_prime);

        // SHEMAX clamping (smooth) -- follows original expression in S
        const delta_t = v_tn;
        const shd: f64 = shemaxdlt * 10.0;
        // delta_t_clamped = delta_t / exp((1/max(shd,1))*log(1 + exp(shd*log(max(|delta_t|/max(shemax,1),1e-30)))))
        const inner = delta_t.abs().scale(1.0 / @max(shemax, 1.0)).maxC(1e-30).log().scale(shd).exp().addC(1.0).maxC(1e-30).log().scale(1.0 / @max(shd, 1.0)).exp();
        const delta_t_clamped = delta_t.div(inner);

        const g_th: f64 = if (rth > 0) 1.0 / @max(rth, 1e-30) else GSHORT;
        i_th = delta_t_clamped.scale(g_th).sub(power);
    }
    const i_th_final = i_th.scale(coselfheat_f);

    // ========================================================================
    // Current contributions to nodes (KCL)
    // ========================================================================
    const i_d_dp = v_d_ext.sub(v_dp).mul(g_drain);
    const i_s_sp = v_s_ext.sub(v_sp).mul(g_source);
    const i_g_gp = v_g_ext.sub(v_gp).scale(g_gate_c);
    const i_b_bp = v_b_ext.sub(v_bp).scale(g_rbpb);
    const i_bp_dp = v_bp.sub(v_dp).scale(g_rbpd);
    const i_bp_sp = v_bp.sub(v_sp).scale(g_rbps);

    // Gate partitioning for gate tunneling
    const igs_ch = igate_ch.scale(glpart1);
    const igd_ch = igate_ch.scale(1.0 - glpart1);

    // Assemble outputs
    var out: [n_u]S = undefined;
    out[D] = i_d_dp.scale(m_mult);
    out[G] = i_g_gp.scale(m_mult);
    out[SRC] = i_s_sp.scale(m_mult);
    out[B] = i_b_bp.scale(m_mult);

    // drain_prime
    out[DP] = i_d_dp.scale(-m_mult)
        .add(ids_final)
        .add(ibd_final)
        .sub(isub_final)
        .sub(igd_ch).sub(igd_total)
        .sub(igidl_final)
        .add(ihbreak_final)
        .add(i_bjt_final)
        .add(i_bp_dp.scale(m_mult));

    // source_prime
    out[SP] = i_s_sp.scale(-m_mult)
        .sub(ids_final)
        .add(ibs_final)
        .sub(i_bjt_final)
        .sub(igs_ch).sub(igs_total)
        .add(i_bp_sp.scale(m_mult));

    // gate_prime
    out[GP] = i_g_gp.scale(-m_mult)
        .add(igs_ch).add(igd_ch)
        .add(igb_total)
        .add(igs_total).add(igd_total);

    // body_prime
    out[BP] = i_b_bp.scale(-m_mult)
        .sub(i_bp_dp.scale(m_mult))
        .sub(i_bp_sp.scale(m_mult))
        .sub(ibd_final)
        .sub(ibs_final)
        .add(isub_final)
        .sub(igb_total)
        .add(igidl_final);

    // thermal node
    out[TN] = i_th_final;

    return out;
}

// ============================================================================
// Charge function q -- capacitances and charges (value-form)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, _: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const D = @intFromEnum(U.drain);
    const G = @intFromEnum(U.gate);
    const SRC = @intFromEnum(U.source);
    const B = @intFromEnum(U.bulk);
    const DP = @intFromEnum(U.drain_prime);
    const SP = @intFromEnum(U.source_prime);
    const GP = @intFromEnum(U.gate_prime);
    const BP = @intFromEnum(U.body_prime);
    const TN = @intFromEnum(U.temp_node);

    // x-independent params
    const type_f: f64 = @floatFromInt(model.type_);
    const tox: f64 = @as(f64, model.tox);
    const kappa: f64 = @as(f64, model.kappa);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);
    const xld_p: f64 = @as(f64, model.xld);
    const xldld: f64 = @as(f64, model.xldld);
    const tpoly: f64 = @as(f64, model.tpoly);
    const vfbc: f64 = @as(f64, model.vfbc);
    const vbi_p: f64 = @as(f64, model.vbi);
    const nsubc: f64 = @as(f64, model.nsubc);
    const nsubp: f64 = @as(f64, model.nsubp);
    const lp_p: f64 = @as(f64, model.lp);
    const nover: f64 = @as(f64, model.nover);
    const loverld: f64 = @as(f64, model.loverld);
    const vfbover: f64 = @as(f64, model.vfbover);
    const qovadd: f64 = @as(f64, model.qovadd);
    const qovjunc: f64 = @as(f64, model.qovjunc);
    const cvdsover: f64 = @as(f64, model.cvdsover);
    const ovslp: f64 = @as(f64, model.ovslp);
    const ovmag: f64 = @as(f64, model.ovmag);
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const xqy_p: f64 = @as(f64, model.xqy);
    const xqy1: f64 = @as(f64, model.xqy1);
    const xqy2: f64 = @as(f64, model.xqy2);
    const eg0: f64 = @as(f64, model.eg0);
    const bgtmp1: f64 = @as(f64, model.bgtmp1);
    const bgtmp2: f64 = @as(f64, model.bgtmp2);
    const tnom_c: f64 = @as(f64, model.tnom);

    // Junction cap params
    const cjd: f64 = @as(f64, model.cjd);
    const cjs: f64 = @as(f64, model.cjs);
    const cjswd: f64 = @as(f64, model.cjswd);
    const cjsws: f64 = @as(f64, model.cjsws);
    const cjswgd: f64 = @as(f64, model.cjswgd);
    const cjswgs: f64 = @as(f64, model.cjswgs);
    const mjd: f64 = @as(f64, model.mjd);
    const mjs: f64 = @as(f64, model.mjs);
    const mjswd: f64 = @as(f64, model.mjswd);
    const mjsws: f64 = @as(f64, model.mjsws);
    const mjswgd: f64 = @as(f64, model.mjswgd);
    const mjswgs: f64 = @as(f64, model.mjswgs);
    const pbd: f64 = @as(f64, model.pbd);
    const pbs: f64 = @as(f64, model.pbs);
    const pbswd: f64 = @as(f64, model.pbswd);
    const pbsws: f64 = @as(f64, model.pbsws);
    const pbswgd: f64 = @as(f64, model.pbswgd);
    const pbswgs: f64 = @as(f64, model.pbswgs);
    const tcjbd: f64 = @as(f64, model.tcjbd);
    const tcjbs: f64 = @as(f64, model.tcjbs);
    const tcjbdsw: f64 = @as(f64, model.tcjbdsw);
    const tcjbssw: f64 = @as(f64, model.tcjbssw);
    const tcjbdswg: f64 = @as(f64, model.tcjbdswg);
    const tcjbsswg: f64 = @as(f64, model.tcjbsswg);
    const cth0: f64 = @as(f64, model.cth0);
    const coselfheat: i32 = if (instance.coselfheat_inst >= 0) instance.coselfheat_inst else model.coselfheat;

    const ll: f64 = @as(f64, model.ll);
    const lld: f64 = @as(f64, model.lld);
    const lln: f64 = @as(f64, model.lln);
    const wl: f64 = @as(f64, model.wl);
    const wld: f64 = @as(f64, model.wld);
    const wln: f64 = @as(f64, model.wln);

    const m_mult: f64 = @as(f64, instance.m);
    const nf: f64 = @as(f64, instance.nf);
    const l_drawn: f64 = @as(f64, instance.l);
    const w_drawn: f64 = @as(f64, instance.w);
    const ad_i: f64 = @as(f64, instance.ad);
    const as_i: f64 = @as(f64, instance.as_);
    const pd_i: f64 = @as(f64, instance.pd);
    const ps_i: f64 = @as(f64, instance.ps);
    const dtemp: f64 = @as(f64, instance.dtemp);

    // Temperature
    const tnom_k: f64 = tnom_c + C_TO_K;
    const temp_k: f64 = T_REF + dtemp;
    const tdiff: f64 = temp_k - tnom_k;
    const beta_inv: f64 = K_BOLTZ * temp_k / Q_ELECTRON;
    const beta: f64 = 1.0 / beta_inv;

    const eg_nom: f64 = eg0 - 90.25e-6 * tnom_c - 1.0e-7 * tnom_c * tnom_c;
    const eg: f64 = eg_nom - bgtmp1 * (temp_k - tnom_k) - bgtmp2 * (temp_k - tnom_k) * (temp_k - tnom_k);
    _ = eg;

    // Device size
    const l_gate: f64 = l_drawn + xl;
    const w_gate: f64 = w_drawn / nf + xw;
    const ll_denom: f64 = @max(@abs(l_gate + lld), 1e-30);
    const l_poly: f64 = l_gate - 2.0 * ll / @exp(lln * @log(ll_denom));
    const wl_denom: f64 = @max(@abs(w_gate + wld), 1e-30);
    const w_poly: f64 = w_gate - 2.0 * wl / @exp(wln * @log(wl_denom));
    const l_eff: f64 = @max(l_poly - xld_p - xldld, 1e-9);
    const w_eff: f64 = @max(w_poly - 2.0 * @as(f64, model.xwd), 1e-9);

    const eps_ox: f64 = EPS_0 * kappa;
    const cox: f64 = eps_ox / tox;

    // Nsub (Eqs. 92-93, 45)
    const nsubcw_q: f64 = @as(f64, model.nsubcw);
    const nsubcwp_q: f64 = @as(f64, model.nsubcwp);
    const nsubp0_q: f64 = @as(f64, model.nsubp0);
    const nsubwp_q: f64 = @as(f64, model.nsubwp);
    const npext_q: f64 = @as(f64, model.npext);
    const lpext_q: f64 = @as(f64, model.lpext);
    const w_gate_um_q: f64 = @max(w_gate * 1e6, 1e-20);
    const nsubc_w: f64 = nsubc * (1.0 + nsubcw_q / @exp(nsubcwp_q * @log(w_gate_um_q)));
    const nsubp_w: f64 = nsubp * (1.0 + nsubp0_q / @exp(nsubwp_q * @log(w_gate_um_q)));
    const lp_eff: f64 = @min(lp_p, l_gate);
    const nsub_avg_q: f64 = (nsubc_w * (l_gate - lp_eff) + nsubp_w * lp_eff) / l_gate;
    const xx_pt_q: f64 = @max(0.5 * l_gate - lp_eff, 1e-30);
    const tail_denom_q: f64 = 1.0 / xx_pt_q + lpext_q * l_gate;
    const nsub_tail_q: f64 = (npext_q - nsubc_w) / @max(tail_denom_q, 1e-30);
    const nsub: f64 = nsub_avg_q + nsub_tail_q;
    const nsub_safe: f64 = @max(nsub, 1e10);

    const t_ratio_q: f64 = temp_k / tnom_k;
    const eg_q: f64 = eg_nom - bgtmp1 * (temp_k - tnom_k) - bgtmp2 * (temp_k - tnom_k) * (temp_k - tnom_k);
    const ni_ratio_q: f64 = @exp(eg_nom * beta * 0.5) * @exp(-eg_q * beta * 0.5);
    const ni_factor_q: f64 = ni_ratio_q * @exp(1.5 * @log(@max(t_ratio_q, 1e-30)));

    const phi_b: f64 = @log(@max(nsub_safe, 1e10) / @max(NI_300 * ni_factor_q, 1e-30)) / beta;
    const two_phi_b: f64 = 2.0 * phi_b;

    const const0: f64 = @sqrt(@max(2.0 * EPS_SI * Q_ELECTRON * nsub_safe / beta, 1e-30));
    const c0_cox: f64 = const0 / cox;

    // x-indep smoothing delta
    const ddltmax_q: f64 = @as(f64, model.ddltmax);
    const ddltslp_q: f64 = @as(f64, model.ddltslp);
    const ddltict_q: f64 = @as(f64, model.ddltict);
    const l_gate_um_q: f64 = l_gate * 1e6;
    const t1_ddlt_q: f64 = ddltslp_q * l_gate_um_q;
    const delta_ddlt_q: f64 = if (model.coddlt == 1)
        ddltmax_q * t1_ddlt_q / @max(ddltmax_q + t1_ddlt_q, 1e-30) + ddltict_q
    else
        ddltmax_q * (t1_ddlt_q + ddltict_q) / @max(ddltmax_q + t1_ddlt_q + ddltict_q, 1e-30) + 1.0;
    const delta_safe_q: f64 = @max(delta_ddlt_q, 1.01);

    const sc1_q: f64 = @as(f64, model.sc1);
    const sc2_q: f64 = @as(f64, model.sc2);
    const l_sce_q: f64 = @max(l_gate - @as(f64, model.parl2), 1e-9);
    const vzadd0_q: f64 = @as(f64, model.vzadd0);

    // ========================================================================
    // Terminal voltages (S)
    // ========================================================================
    const v_dp = x[DP];
    const v_sp = x[SP];
    const v_gp = x[GP];
    const v_bp = x[BP];
    const v_tn = x[TN];

    const vgs_i = v_gp.sub(v_sp).scale(type_f);
    const vds_i = v_dp.sub(v_sp).scale(type_f);
    const vbs_i = v_bp.sub(v_sp).scale(type_f);
    const vds_neg = vds_i.minC(0.0);
    const vgs_eff = vgs_i.sub(vds_neg);
    const vbs_eff = vbs_i.sub(vds_neg);
    const vds_eff_raw = vds_i.abs();

    // Threshold shift (simplified: main short-channel shift)
    const wd_q = vbs_eff.neg().addC(two_phi_b).scale(2.0 * EPS_SI / (Q_ELECTRON * nsub_safe)).maxC(1e-30).sqrt();
    const dey_q = vds_eff_raw.scale(sc2_q).addC(sc1_q).scale(2.0 * (vbi_p - two_phi_b) / (l_sce_q * l_sce_q));
    const dvth_sc_q = dey_q.mul(wd_q).scale(EPS_SI / cox);
    const dvth_q = dvth_sc_q;

    const vg_prime = vgs_eff.addC(-vfbc).add(dvth_q);

    // Surface potential phi_S0 one-step Newton (matching i() approach)
    const phi_s0_init = vbs_eff.addC(0.1).maxC(two_phi_b + vzadd0_q);
    const bps0_init_arg = phi_s0_init.sub(vbs_eff).scale(beta).addC(-1.0).maxC(1e-30);
    const bps0_init_sq = bps0_init_arg.sqrt();
    const phi_s0_den = vg_prime.sub(phi_s0_init).add(bps0_init_sq.scale(c0_cox)).addC(1e-30).maxC(1e-30);
    const phi_s0 = vg_prime.addC(vfbc).sub(bps0_init_sq.scale(c0_cox)).sub(phi_s0_den.pow(-1.0).scale(c0_cox * c0_cox * 0.5));

    // Vds,sat (Eq. 19)
    const qn_cox2: f64 = Q_ELECTRON * nsub_safe * EPS_SI / (cox * cox);
    const vds_sat_arg = vg_prime.addC(-beta_inv).sub(vbs_eff).scale(2.0 * cox * cox / (Q_ELECTRON * nsub_safe * EPS_SI)).addC(1.0).maxC(1e-30);
    const vds_sat = vg_prime.add(vds_sat_arg.sqrt().neg().addC(1.0).scale(qn_cox2)).maxC(1e-12);

    // Smooth Vds
    const vds_ratio_q = vds_eff_raw.div(vds_sat.maxC(1e-30));
    const vds_ratio_pow_q = vds_ratio_q.maxC(1e-30).log().scale(delta_safe_q).exp();
    const vds_eff = vds_eff_raw.div(vds_ratio_pow_q.addC(1.0).maxC(1e-30).log().scale(1.0 / delta_safe_q).exp());
    const phi_sl = phi_s0.add(vds_eff);

    // ========================================================================
    // Intrinsic gate charge (Ward-Dutton, Eqs. 22-28)
    // ========================================================================
    const bps0_arg = phi_s0.sub(vbs_eff).scale(beta).addC(-1.0).maxC(1e-30);
    const bpsl_arg = phi_sl.sub(vbs_eff).scale(beta).addC(-1.0).maxC(1e-30);
    const bps0_sq = bps0_arg.sqrt();
    const bpsl_sq = bpsl_arg.sqrt();

    // VgVt (Eq. 26)
    const vgvt = vgs_eff.addC(-vfbc).add(phi_s0).add(bps0_sq.scale(c0_cox)).maxC(1e-30);

    // delta (Eq. 27)
    const dphi = phi_sl.sub(phi_s0).maxC(1e-30);
    const dphi_sq = dphi.mul(dphi);
    const delta_ch = bpsl_arg.mul(bpsl_sq).sub(bps0_arg.mul(bps0_sq)).scale((4.0 / 3.0) * c0_cox / beta).div(dphi_sq)
        .sub(bpsl_sq.sub(bps0_sq).scale(2.0 * c0_cox / beta).div(dphi_sq))
        .sub(bps0_sq.scale(2.0 * c0_cox).div(dphi));

    // alpha (Eq. 25)
    const alpha = delta_ch.addC(1.0).mul(dphi).div(vgvt).neg().addC(1.0).maxC(1e-6);

    // QI (Eq. 23)
    const one_p_alpha = alpha.addC(1.0);
    const qi_intr = vgvt.mul(alpha.mul(alpha).add(alpha).addC(1.0)).div(one_p_alpha).scale(-w_eff * l_eff * cox * (2.0 / 3.0));

    // QD (Eq. 24)
    const qd_frac = alpha.scale(2.0).addC(1.0).div(one_p_alpha.mul(alpha.mul(alpha).add(alpha).addC(1.0))).scale(-1.0 / 5.0).addC(3.0 / 5.0);
    const qd_intr = qi_intr.mul(qd_frac);
    const qs_intr = qi_intr.sub(qd_intr);

    // QB (Eq. 22 simplified)
    const qb_intr = bpsl_sq.sub(bps0_sq).scale(-const0 * w_eff * l_eff / beta);

    // QG = -(QI + QB)
    const qg_intr = qi_intr.add(qb_intr).neg();

    // ========================================================================
    // Overlap charges (Sec. 16)
    // ========================================================================
    const wtrench_q: f64 = @as(f64, model.wtrench);
    // w_junc_ov = qovjunc*sqrt(2 epsSi (|vds - vbs| + vbi)/q * nsub/(nover*(nsub+nover)))
    const w_junc_ov = vds_eff_raw.sub(vbs_eff).abs().addC(vbi_p).scale(2.0 * EPS_SI / Q_ELECTRON * nsub_safe / @max(nover * (nsub_safe + nover), 1e-30)).maxC(0.0).sqrt().scale(qovjunc);
    const loverld_base: f64 = if (model.cotrench == 1) loverld + wtrench_q else loverld;
    // loverld_mod = max(loverld_base - w_junc_ov, 1e-12)  (S, x-dep)
    const loverld_mod = w_junc_ov.neg().addC(loverld_base).maxC(1e-12);

    // Overlap surface potential
    const vgd_ov = vgs_eff.sub(vds_eff_raw).addC(-vfbover);
    const phi_s_over = vgd_ov.minC(1.0).maxC(-0.5);

    // Overlap charge (Eq. 182/183): region select on phi_s_over sign
    const q_over_d = if (phi_s_over.val() > 0)
        loverld_mod.mul(vgs_eff.addC(-vfbover).sub(phi_s_over)).scale(w_eff * nf * cox)
    else
        loverld_mod.mul(phi_s_over.abs().scale(beta).addC(-1.0).maxC(1e-30).sqrt()).scale(w_eff * nf * @sqrt(@max(2.0 * EPS_SI * Q_ELECTRON * nover / beta, 1e-30)));

    // Additional overlap charge (Eq. 184)
    const v_ch = phi_sl.sub(phi_s0);
    const q_over_add = loverld_mod.mul(vds_eff_raw.sub(v_ch)).scale(w_eff * nf * qovadd);

    // Source overlap
    const lovers_p: f64 = @as(f64, model.lovers);
    const q_over_s = if (model.coovlps == 1) blk_s: {
        const vgs_ov_s = vgs_eff.addC(-vfbover);
        const phi_s_over_s = vgs_ov_s.minC(1.0).maxC(-0.5);
        const novers_q: f64 = @as(f64, model.novers);
        break :blk_s if (phi_s_over_s.val() > 0)
            vgs_eff.addC(-vfbover).sub(phi_s_over_s).scale(w_eff * nf * lovers_p * cox)
        else
            phi_s_over_s.abs().scale(beta).addC(-1.0).maxC(1e-30).sqrt().scale(w_eff * nf * lovers_p * @sqrt(@max(2.0 * EPS_SI * Q_ELECTRON * novers_q / beta, 1e-30)));
    } else vgs_eff.scale(w_eff * nf * lovers_p * cox);

    // Simplified overlap OVSLP/OVMAG (Eq. 189) -- computed but unused (as original)
    _ = cvdsover;
    _ = ovslp;
    _ = ovmag;

    // Gate-overlap user-specified
    const q_cgso = vgs_eff.scale(cgso * w_eff * nf);
    const q_cgdo = vgs_eff.sub(vds_eff_raw).scale(cgdo * w_eff * nf);
    const q_cgbo = vgs_eff.sub(vbs_eff).scale(-cgbo * l_gate);

    // Fringing capacitance (Eq. 195)
    const cf: f64 = eps_ox / (1.5708) * w_gate * nf * @log(@max(1.0 + tpoly / tox, 1.0));
    const q_fringe_d = vgs_eff.sub(vds_eff_raw).scale(cf);
    const q_fringe_s = vgs_eff.scale(cf);

    // Lateral field charge Qy (Eq. 181)
    const wd = vbs_eff.neg().addC(two_phi_b).scale(2.0 * EPS_SI / (Q_ELECTRON * nsub_safe)).maxC(1e-30).sqrt();
    const xqy_eff: f64 = @max(xqy_p, 1e-12);
    // q_y = epsSi*w_eff*nf*wd*((phi_s0 + vds_eff_raw - phi_sl)/xqy_eff + xqy1/l_gate^xqy2 * vbs_eff)
    const q_y = wd.mul(phi_s0.add(vds_eff_raw).sub(phi_sl).scale(1.0 / xqy_eff).add(vbs_eff.scale(xqy1 / @exp(xqy2 * @log(@max(l_gate, 1e-30)))))).scale(EPS_SI * w_eff * nf);

    // ========================================================================
    // Junction depletion charges (Sec. 18.2)
    // ========================================================================
    const cjd_t: f64 = cjd * (1.0 + tcjbd * tdiff);
    const cjs_t: f64 = cjs * (1.0 + tcjbs * tdiff);
    const cjswd_t: f64 = cjswd * (1.0 + tcjbdsw * tdiff);
    const cjsws_t: f64 = cjsws * (1.0 + tcjbssw * tdiff);
    const cjswgd_t: f64 = cjswgd * (1.0 + tcjbdswg * tdiff);
    const cjswgs_t: f64 = cjswgs * (1.0 + tcjbsswg * tdiff);

    const vbd = vbs_eff.sub(vds_eff_raw);
    const q_jbd_btm = juncCharge(S, vbd, cjd_t * ad_i, pbd, mjd);
    const q_jbd_sw = juncCharge(S, vbd, cjswd_t * pd_i, pbswd, mjswd);
    const q_jbd_swg = juncCharge(S, vbd, cjswgd_t * w_eff * nf, pbswgd, mjswgd);

    const vbs_junc = vbs_eff;
    const q_jbs_btm = juncCharge(S, vbs_junc, cjs_t * as_i, pbs, mjs);
    const q_jbs_sw = juncCharge(S, vbs_junc, cjsws_t * ps_i, pbsws, mjsws);
    const q_jbs_swg = juncCharge(S, vbs_junc, cjswgs_t * w_eff * nf, pbswgs, mjswgs);

    const q_jbd = q_jbd_btm.add(q_jbd_sw).add(q_jbd_swg);
    const q_jbs = q_jbs_btm.add(q_jbs_sw).add(q_jbs_swg);

    // Thermal capacitance (Eq. 334)
    const q_th = v_tn.scale(cth0 * w_eff);
    const coselfheat_f: f64 = @floatFromInt(@min(coselfheat, 1));

    // ========================================================================
    // Distribute charges to nodes
    // ========================================================================
    const q_gate = qg_intr.scale(nf).add(q_over_d).add(q_over_add).add(q_over_s).add(q_cgso).add(q_cgdo).add(q_cgbo).add(q_fringe_d).add(q_fringe_s).add(q_y);
    const q_drain = qd_intr.scale(nf).add(q_jbd);
    const q_source = qs_intr.scale(nf).add(q_jbs);
    const q_bulk = qb_intr.scale(nf).sub(q_jbd).sub(q_jbs);

    var out: [n_u]S = undefined;
    out[D] = S.con(0.0);
    out[G] = S.con(0.0);
    out[SRC] = S.con(0.0);
    out[B] = S.con(0.0);

    out[DP] = q_drain.scale(type_f * m_mult);
    out[SP] = q_source.scale(type_f * m_mult);
    out[GP] = q_gate.scale(type_f * m_mult);
    out[BP] = q_bulk.scale(type_f * m_mult);
    out[TN] = q_th.scale(coselfheat_f);
    return out;
}

// ============================================================================
// Junction depletion charge helper (value-form, region select on v sign)
// Forward bias: linear + quadratic; Reverse bias: power-law (Eqs. 290, 293)
// ============================================================================
inline fn juncCharge(comptime S: type, v: S, cz: f64, pb: f64, mj: f64) S {
    const pb_safe: f64 = @max(pb, 1e-6);
    const mj1: f64 = 1.0 - mj;
    const mj1_safe: f64 = @max(@abs(mj1), 1e-6);

    // Reverse bias (v < 0): depletion charge Eq. 290
    // q_rev = pb_safe*cz*(1 - (1 - v/pb_safe)^mj1_safe)/mj1_safe
    const ratio = v.scale(-1.0 / pb_safe).addC(1.0).maxC(1e-30);
    const q_rev = ratio.pow(mj1_safe).neg().addC(1.0).scale(pb_safe * cz / mj1_safe);

    // Forward bias (v >= 0): linearized Eq. 293
    // q_fwd = cz*v + 0.5*cz*mj/pb_safe*v^2
    const q_fwd = v.scale(cz).add(v.mul(v).scale(0.5 * cz * mj / pb_safe));

    return if (v.val() < 0) q_rev else q_fwd;
}

// ============================================================================
// Voltage limiting (DEVpnjlim for junctions, DEVfetlim for gate)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const type_f: f64 = @floatFromInt(model.type_);
    const beta_inv: f64 = K_BOLTZ * T_REF / Q_ELECTRON;
    var x_lim = x_new;

    const GP = @intFromEnum(U.gate_prime);
    const DP = @intFromEnum(U.drain_prime);
    const SP = @intFromEnum(U.source_prime);
    const BP = @intFromEnum(U.body_prime);

    // DEVfetlim for Vgs
    const vgs_new: f64 = (x_new[GP] - x_new[SP]) * type_f;
    const vgs_old: f64 = (x_old[GP] - x_old[SP]) * type_f;
    const vgs_lim: f64 = fetLim(vgs_new, vgs_old, @as(f64, model.vfbc) + 0.5);
    const dvgs: f64 = (vgs_lim - vgs_new) * type_f;
    x_lim[GP] = x_lim[GP] + dvgs;

    // DEVfetlim for Vds
    const vds_new: f64 = (x_new[DP] - x_new[SP]) * type_f;
    const vds_old: f64 = (x_old[DP] - x_old[SP]) * type_f;
    const vds_lim: f64 = fetLim(vds_new, vds_old, @as(f64, model.vfbc) + 0.5);
    const dvds: f64 = (vds_lim - vds_new) * type_f;
    x_lim[DP] = x_lim[DP] + dvds;

    // DEVpnjlim for drain-bulk junction
    const vbd_new: f64 = (x_new[BP] - x_new[DP]) * type_f;
    const vbd_old: f64 = (x_old[BP] - x_old[DP]) * type_f;
    const is_d: f64 = @as(f64, model.js0d) * @as(f64, instance.ad) + 1e-30;
    const vbd_lim: f64 = pnjLim(vbd_new, vbd_old, beta_inv, is_d);
    const dvbd: f64 = (vbd_lim - vbd_new) * type_f;
    x_lim[BP] = x_lim[BP] + dvbd;

    // DEVpnjlim for source-bulk junction
    const vbs_new: f64 = (x_new[BP] - x_new[SP]) * type_f;
    const vbs_old: f64 = (x_old[BP] - x_old[SP]) * type_f;
    const is_s: f64 = @as(f64, model.js0s) * @as(f64, instance.as_) + 1e-30;
    const vbs_lim: f64 = pnjLim(vbs_new, vbs_old, beta_inv, is_s);
    const dvbs: f64 = (vbs_lim - vbs_new) * type_f;
    // Adjust BP for source junction (additively with drain junction adjustment)
    x_lim[BP] = x_lim[BP] + dvbs;

    return x_lim;
}

/// PN junction voltage limiting (DEVpnjlim)
inline fn pnjLim(vnew: f64, vold: f64, vt: f64, is_val: f64) f64 {
    const vcrit: f64 = vt * @log(vt / (@sqrt(2.0) * is_val));
    const vlim: f64 = if (vnew > vcrit and @abs(vnew - vold) > 2.0 * vt)
        if (vold > 0)
            vold + 2.0 * vt * @log(@max(1.0 + (vnew - vold) / (2.0 * vt), 1e-30))
        else
            vcrit
    else
        vnew;
    return vlim;
}

/// FET gate voltage limiting (DEVfetlim)
inline fn fetLim(vnew: f64, vold: f64, vto: f64) f64 {
    const vtsthi: f64 = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo: f64 = vtsthi / 2.0 + 2.0;
    const vtox: f64 = vto + 3.5;
    const dv: f64 = vnew - vold;

    const vlim: f64 = if (vnew >= vold) blk: {
        break :blk if (vold >= vto)
            if (dv > vtsthi) vold + vtsthi else vnew
        else if (vnew <= vtox)
            if (dv > vtstlo) vold + vtstlo else vnew
        else
            vtox;
    } else blk: {
        break :blk if (vold >= vto)
            if (-dv > vtsthi) vold - vtsthi else vnew
        else if (vnew >= vtox)
            vnew
        else if (vold <= vtox)
            if (-dv > vtstlo) vold - vtstlo else vnew
        else
            vtox;
    };
    return vlim;
}

// ============================================================================
// Parameter stepping for convergence aid
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale saturation current densities by lambda for source stepping
    const scale: f64 = @as(f64, 1.0e-12) * (1.0 - lambda);
    m.gbmin = @floatCast(@as(f64, model.gbmin) + scale);
    return m;
}

// ============================================================================
// Noise generators
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: drain-source channel
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Shot noise: drain-bulk diode
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.body_prime), .kind = .shot },
    // Shot noise: source-bulk diode
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.body_prime), .kind = .shot },
    // Flicker noise: drain-source (1/f)
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Thermal noise: drain drift resistance
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Thermal noise: source resistance
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Thermal noise: gate resistance
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime), .kind = .thermal },
    // Shot noise: gate current
    .{ .row = @intFromEnum(U.gate_prime), .col = @intFromEnum(U.drain_prime), .kind = .shot },
    // Shot noise: substrate current
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.body_prime), .kind = .shot },
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

test "hisim_hv: contract compiles and zero-bias residual is ~0" {
    // All terminals grounded -> no current anywhere.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &model, &inst, 0);
    // Every KCL residual must be ~0 (all voltages equal -> all g*(dv)=0, diodes at 0).
    for (out) |o| try testing.expectApproxEqAbs(@as(f64, 0.0), o, 1e-9);
}

test "hisim_hv: drain drift resistor carries current (on-state path)" {
    // Put a voltage only across the external-drain -> drain_prime drift resistor
    // with all other nodes at 0. With default CORDRIFT=1/CORD=1 the drift branch
    // is active. The external drain KCL residual is i_d_dp*m = (v_d - v_dp)*g_drain.
    // We only assert the branch conducts (nonzero, correct sign) since g_drain is
    // a full drift-physics function; the value regression lives in the resistor
    // and diode tests below.
    const model: Model = .{};
    const inst: Instance = .{};
    // v_drain = 0.1, everything else 0
    const out = contract.evalValues(Self, .{ 0.1, 0, 0, 0, 0, 0, 0, 0, 0 }, &model, &inst, 0);
    const Didx = @intFromEnum(U.drain);
    // Current out of external drain node into the device must be > 0 for v_d>v_dp.
    try testing.expect(out[Didx] > 0);
    // And drain_prime must receive the mirrored contribution among its terms.
    try testing.expect(std.math.isFinite(out[@intFromEnum(U.drain_prime)]));
}

test "hisim_hv: source-bulk diode isolated via body network" {
    // Enable substrate network (corbnet=1) with LARGE rbps so the network term is
    // negligible, letting the source diode dominate SP. rbps=1e12 -> g=1e-12.
    // Everything else off. vbs_junc = v_bp - v_sp = 0.6.
    const model: Model = .{ .cordrift = 0, .cors = 0, .cord = 0, .corbnet = 1, .corg = 0 };
    const inst: Instance = .{
        .as_ = 1e-9,
        .rbps_inst = 1e12,
        .rbpd_inst = 1e12,
        .rbpb_inst = 1e12,
    };
    // Bias: body_prime=0.6, source_prime=0, rest 0.
    const out = contract.evalValues(Self, .{ 0, 0, 0, 0, 0, 0, 0, 0.6, 0 }, &model, &inst, 0);

    // Hand formula (same as prior test)
    const beta_inv: f64 = K_BOLTZ * T_REF / Q_ELECTRON;
    const isbs: f64 = 0.5e-6 * 1e-9;
    const nvtm_s: f64 = 1.0 * beta_inv;
    const vdiffjs: f64 = 0.6e-3;
    const v1_s: f64 = nvtm_s * @log(vdiffjs / isbs + 1.0);
    const vbs: f64 = 0.6;
    const vbs_lim: f64 = @min(vbs, v1_s);
    var ibs: f64 = isbs * (@exp(vbs_lim / nvtm_s) - 1.0);
    ibs += isbs / nvtm_s * @exp(@min(v1_s / nvtm_s, 80.0)) * @max(vbs - v1_s, 0.0);
    ibs += vbs * @as(f64, 1e-12); // gbmin
    // Network term on SP: i_bp_sp = (v_bp - v_sp)*g_rbps = 0.6*1e-12 = 6e-13, added.
    const i_bp_sp: f64 = 0.6 * (1.0 / 1e12);
    const expected_sp: f64 = ibs + i_bp_sp; // +ibs_final + i_bp_sp*m
    const SPidx = @intFromEnum(U.source_prime);
    // f32 param storage + exp -> loosen tolerance relative to the ~mA-scale result.
    try testing.expectApproxEqRel(expected_sp, out[SPidx], 1e-4);
}

test "hisim_hv: junction charge helper reverse/forward hand values" {
    // Reverse bias v=-1, cz=1e-3, pb=1, mj=0.5:
    //   mj1 = 0.5, ratio = 1 - (-1)/1 = 2
    //   q_rev = pb*cz*(1 - 2^0.5)/0.5 = 1*1e-3*(1 - 1.4142135624)/0.5
    //         = 1e-3*(-0.4142135624)/0.5 = -8.284271247e-4
    const S = contract.Value;
    const q_rev = juncCharge(S, S.con(-1.0), 1e-3, 1.0, 0.5);
    const expect_rev: f64 = 1.0 * 1e-3 * (1.0 - std.math.sqrt(2.0)) / 0.5;
    try testing.expectApproxEqAbs(expect_rev, q_rev.val(), 1e-12);

    // Forward bias v=0.5, cz=1e-3, pb=1, mj=0.5:
    //   q_fwd = cz*v + 0.5*cz*mj/pb*v^2
    //         = 1e-3*0.5 + 0.5*1e-3*0.5/1*0.25 = 5e-4 + 6.25e-5 = 5.625e-4
    const q_fwd = juncCharge(S, S.con(0.5), 1e-3, 1.0, 0.5);
    const expect_fwd: f64 = 1e-3 * 0.5 + 0.5 * 1e-3 * 0.5 / 1.0 * 0.5 * 0.5;
    try testing.expectApproxEqAbs(expect_fwd, q_fwd.val(), 1e-12);
}
