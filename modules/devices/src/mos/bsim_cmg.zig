const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: BSIM-CMG 112.1.0 (FinFET / GAA Multi-Gate MOSFET)
//
//   G (external gate)   -- Rg -- gi (intrinsic gate)
//   D (external drain)  -- Rd -- di (intrinsic drain)
//   S (external source) -- Rs -- si (intrinsic source)
//   E (external substrate/body)
//   T (temperature node for self-heating)
//
//   Intrinsic MOSFET: gi -- di -- si -- E
//   Junction diodes: E -- di, E -- si (BULKMOD=1)
//   Self-heating: power dissipation through Rth/Cth on T node
// ============================================================================

pub const U = enum(u8) { gate, drain, source, body, di, si, gi, dt };
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================
const Q_ELEM: f64 = 1.60219e-19;
const EPS_0: f64 = 8.8542e-12;
const HBAR: f64 = 1.05457e-34;
const M_ELEC: f64 = 9.11e-31;
const K_BOLTZ: f64 = 1.3787e-23;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const PI: f64 = 3.14159265358979323846;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Polarity ---
    type_: i32 = 1, // 1 = NMOS, -1 = PMOS

    // --- Model Controllers ---
    bulkmod: i32 = 0, // 0=SOI, 1=bulk
    geomod: i32 = 1, // 0=DG, 1=TG, 2=QG, 3=cyl, 4=unified, 5=GAA, 6=SG
    geo1sw: i32 = 0,
    rdsmod: i32 = 0,
    asymmod: i32 = 0,
    igcmod: i32 = 0,
    igbmod: i32 = 0,
    gidlmod: i32 = 0,
    cvmod: i32 = 0,
    iimod: i32 = 0,
    nqsmod: i32 = 0,
    shmod: i32 = 0,
    rgatemod: i32 = 0,
    rsubmod: i32 = 0,
    rgeomod: i32 = 0,
    cgeomod: i32 = 0,
    tempmod: i32 = 0,
    cryomod: i32 = 0,
    fnmod: i32 = 0,
    tnoimod: i32 = 0,
    hvmod: i32 = 0,
    subbandmod: i32 = 0,
    mobscmod: i32 = 0,
    sh_warn: i32 = 0,
    igclamp: i32 = 1,

    // --- Geometry ---
    l: f32 = 30e-9,
    lover: f32 = 30e-9,
    d_cyl: f32 = 40e-9, // D (cylinder diameter)
    tfin: f32 = 15e-9,
    fpitch: f32 = 80e-9,
    nfin_mod: f32 = 1, // NFIN (model default)
    nfinnom: f32 = 0,
    ngcon: i32 = 1,
    hfin: f32 = 30e-9,
    tgaa: f32 = 5e-9,
    tsus: f32 = 2e-9,
    hpff: f32 = 5e-9,
    wgaa: f32 = 6e-9,
    ngaa: i32 = 1,

    // --- S/D overlap geometry ---
    aseo: f32 = 0, adeo: f32 = 0,
    pseo: f32 = 0, pdeo: f32 = 0,

    // --- Channel length/width adjustments ---
    lint: f32 = 0.0,
    ll: f32 = 0.0,
    lln: f32 = 1.0,
    dlc: f32 = 0.0,
    dlcacc: f32 = 0.0,
    llc: f32 = 0.0,
    dlbin: f32 = 0.0,
    deltaw: f32 = 0.0,
    deltawcv: f32 = 0.0,
    dwbin: f32 = 0.0,
    dwcacc: f32 = 0.0,
    fech: f32 = 1.0,
    fechcv: f32 = 1.0,
    xl: f32 = 0.0,
    xw: f32 = 0.0,
    tfin_base: f32 = 0.0,
    tfin_top: f32 = 0.0,
    dws1: f32 = 0.0,
    dws2: f32 = 0.0, // defaults to DWS1 in practice
    dws3: f32 = 0.0,
    dach1: f32 = 0.0,
    dach2: f32 = 0.0,
    dach3: f32 = 0.0,

    // --- Process / Material ---
    eot: f32 = 1.0e-9,
    toxp: f32 = 1.2e-9,
    eotbox: f32 = 140e-9,
    eotacc: f32 = 1.0e-9, // defaults to EOT
    epsrox: f32 = 3.9,
    epsrsub: f32 = 11.9,
    easub: f32 = 4.05,
    ni0sub: f32 = 1.1e16,
    bg0sub: f32 = 1.12,
    nc0sub: f32 = 2.86e25,
    nbody: f32 = 1e22,
    nsd: f32 = 2e26,
    ngate: f32 = 0,
    phig: f32 = 4.61,
    phigl: f32 = 0,
    phiglt: f32 = 0.0,
    phign1: f32 = 0,
    phign2: f32 = 1e5,
    imin: f32 = 1e-15,

    // --- Short Channel Effects ---
    cit: f32 = 0.0,
    cdsc: f32 = 7e-3,
    cdscn1: f32 = 0, cdscn2: f32 = 1e5,
    cdscd: f32 = 7e-3,
    cdscdn1: f32 = 0, cdscdn2: f32 = 1e5,
    cdscdr: f32 = 7e-3, // defaults to CDSCD
    cdscdrn1: f32 = 0, cdscdrn2: f32 = 1e5,
    dvt0: f32 = 0.0,
    dvt1: f32 = 0.60,
    dvt1ss: f32 = 0.60, // defaults to DVT1
    phin: f32 = 0.05,
    eta0: f32 = 0.60,
    eta1: f32 = 0.00,
    eta0lt: f32 = 0.0,
    eta0n1: f32 = 0, eta0n2: f32 = 0,
    eta0cv: f32 = 0.60, // defaults to ETA0
    dsub: f32 = 1.06,
    dvtp0: f32 = 0,
    dvtp1: f32 = 0,
    k1rsce: f32 = 0.0,
    lpe0: f32 = 5e-9,
    dvtshift: f32 = 0.0,

    // --- Lateral NUD / body effect ---
    k0: f32 = 0.0,
    k0si: f32 = 1.0,
    phibe: f32 = 0.7,
    k1: f32 = 0.0,
    delvfbacc: f32 = 0.0,

    // --- Quantum Mechanical ---
    qmfactor: f32 = 0.0,
    qmtcencv: f32 = 0.0,
    qmtcencva: f32 = 0.0,
    qm0: f32 = 1e-3,
    pqm: f32 = 0.66,
    pqml: f32 = 0.0,
    qm0acc: f32 = 1e-3,
    pqmacc: f32 = 0.66,

    // --- Mobility ---
    u0: f32 = 3e-2,
    u0cv: f32 = 3e-2, // defaults to U0
    u0lt: f32 = 0.0,
    u0n1: f32 = 0, u0n2: f32 = 1e5,
    u0mult: f32 = 1.0,
    etamob: f32 = 2.0,
    up: f32 = 0.0,
    lpa: f32 = 1.0,
    ua: f32 = 0.3,
    uacv: f32 = 0.3, // defaults to UA
    uc: f32 = 0.0,
    uccv: f32 = 0.0,
    eu: f32 = 2.5,
    ud: f32 = 0.0,
    udcv: f32 = 0.0,
    ucs: f32 = 1.0,
    uds: f32 = 2.0e-5,
    udd: f32 = -2.0e-5,
    muhc0: f32 = 0.0,
    muhc1: f32 = 0.0,
    chargewf: f32 = 0,

    // --- GAA Mobility Scaling (MOBSCMOD=1) ---
    etamobthin: f32 = 2.0,
    etamobtni: f32 = 7.5e-9,
    etamobir: f32 = 0.1,
    uathin: f32 = 0.3,
    uatsat: f32 = 9e-9,
    uartsc: f32 = 0.09,
    uatni: f32 = 6.4e-9,
    uair: f32 = 0.2,
    euthin: f32 = 2.5,
    euptsc: f32 = 3.5,
    eutni: f32 = 6e-9,
    euir: f32 = 0.2,
    udthin: f32 = 0.0,
    udtsat: f32 = 8.1e9,
    udptsc: f32 = 1.3,
    u0etawsc: f32 = 1.5,
    egbulk: f32 = 1.1,
    u0emsm1: f32 = 26.6,
    u0emsm2: f32 = 4,

    // --- Velocity Saturation ---
    vsat: f32 = 85000,
    vsatn1: f32 = 0, vsatn2: f32 = 1e5,
    vsat1: f32 = 85000, // defaults to VSAT
    vsat1n1: f32 = 0, vsat1n2: f32 = 1e5,
    vsat1r: f32 = 85000, // defaults to VSAT1
    vsat1rn1: f32 = 0, vsat1rn2: f32 = 1e5,
    vsatdr: f32 = 85000,
    vsatcv: f32 = 85000, // defaults to VSAT
    deltavsat: f32 = 1.0,
    deltavsatcv: f32 = 1.0, // defaults to DELTAVSAT
    psat: f32 = 2.0,
    psatcv: f32 = 2.0, // defaults to PSAT
    asat: f32 = 1,
    ksativ: f32 = 1.0,
    ksativdr: f32 = 1.0,
    ptwg: f32 = 0.0,
    ptwgr: f32 = 0.0, // defaults to PTWG
    a1: f32 = 0.0,
    a2: f32 = 0.0,
    mexp: f32 = 4,
    mexpr: f32 = 4, // defaults to MEXP
    mexpdr: f32 = 4,

    // --- Output Conductance ---
    pclm: f32 = 0.013,
    pclmg: f32 = 0,
    pclmcv: f32 = 0.013, // defaults to PCLM
    pdibl1: f32 = 1.30,
    pdibl1r: f32 = 1.30, // defaults to PDIBL1
    pdibl2: f32 = 2e-4,
    drout: f32 = 1.06,
    pvag: f32 = 1.0,

    // --- Parasitic Resistance ---
    rdswmin: f32 = 0.0,
    rdsw: f32 = 100,
    rswmin: f32 = 0.0,
    rsw: f32 = 50,
    rdwmin: f32 = 0.0,
    rdw: f32 = 50,
    wr: f32 = 1.0,
    prwgs: f32 = 0.0,
    prwgd: f32 = 0.0, // defaults to PRWGS
    rsdr: f32 = 0.0,
    rsdrr: f32 = 0.0, // defaults to RSDR
    rddr: f32 = 0.0,
    rddrr: f32 = 0.0, // defaults to RDDR
    prsdr: f32 = 1.0,
    prddr: f32 = 1.0, // defaults to PRSDR
    rshs: f32 = 0.0,
    rshd: f32 = 0.0, // defaults to RSHS

    // --- S/D Velocity Saturation Resistance (RDSMOD=1) ---
    rdlcw: f32 = 0.0,
    rslcw: f32 = 0.0,
    nvsrd: f32 = 5.0e16,
    nvsrs: f32 = 5.0e16, // defaults to NVSRD
    vsatrsd: f32 = 1.0e5,
    ptwgvsrsd: f32 = 0.0,
    ptwg1vsrsd: f32 = 0.0,
    psatxvsrsd: f32 = 60.0,
    mvsrsd: f32 = 1.0,
    vsrdfactor: f32 = 1.0e-3,
    vsrsfactor: f32 = 1.0e-3,
    rdvds: f32 = 8.0,
    gavsrd: f32 = 0.0,

    // --- Gate Resistance ---
    rgext: f32 = 0.0,
    rgint: f32 = 0.0,
    rgp: f32 = 0.0,
    rgfin: f32 = 1.0e-3,
    gbmin: f32 = 1e-12,

    // --- Substrate Network ---
    rbpb: f32 = 50,
    rbsb: f32 = 50,
    rbdb: f32 = 50,
    rbps: f32 = 50,
    rbpd: f32 = 50,

    // --- Gate Tunneling ---
    toxref: f32 = 1.2e-9,
    toxg: f32 = 1.2e-9, // defaults to TOXP
    ntox: f32 = 1.0,
    aigbinv: f32 = 1.11e-2,
    bigbinv: f32 = 9.49e-4,
    cigbinv: f32 = 6.00e-3,
    eigbinv: f32 = 1.1,
    nigbinv: f32 = 3.0,
    aigbacc: f32 = 1.36e-2,
    bigbacc: f32 = 1.71e-3,
    cigbacc: f32 = 7.5e-2,
    nigbacc: f32 = 1.0,
    aigc: f32 = 1.36e-2,
    bigc: f32 = 1.71e-3,
    cigc: f32 = 0.075,
    pigcd: f32 = 1.0,
    dlcigs: f32 = 0.0,
    dlcigd: f32 = 0.0, // defaults to DLCIGS
    aigs: f32 = 1.36e-2,
    bigs: f32 = 1.71e-3,
    cigs: f32 = 0.075,
    aigd: f32 = 1.36e-2, // defaults to AIGS
    bigd: f32 = 1.71e-3, // defaults to BIGS
    cigd: f32 = 0.075, // defaults to CIGS
    poxedge: f32 = 1,
    vfbsd: f32 = 0.0,
    vfbsdcv: f32 = 0.0, // defaults to VFBSD
    igb0mult: f32 = 1.0,
    igc0mult: f32 = 1.0,

    // --- GIDL/GISL ---
    agidl: f32 = 6.055e-12,
    bgidl: f32 = 0.3e9,
    cgidl: f32 = 0.2,
    egidl: f32 = 0.2,
    pgidl: f32 = 1.0,
    agisl: f32 = 6.055e-12, // defaults to AGIDL
    bgisl: f32 = 0.3e9,
    cgisl: f32 = 0.2,
    egisl: f32 = 0.2,
    pgisl: f32 = 1.0,
    agidlb: f32 = 6.055e-12,
    bgidlb: f32 = 0.3e9,
    cgidlb: f32 = 0.2,
    egidlb: f32 = 0.2,
    pgidlb: f32 = 1.0,
    agislb: f32 = 6.055e-12,
    bgislb: f32 = 0.3e9,
    cgislb: f32 = 0.2,
    egislb: f32 = 0.2,
    pgislb: f32 = 1.0,
    vfbdrifts: f32 = -0.2,
    vfbdriftd: f32 = -0.2,

    // --- TAT GIDL/GISL (GIDLMOD=3) ---
    atatd: f32 = 1.0e-27,
    btatd: f32 = 6.3e-5,
    ctatd: f32 = 0.215,
    dtatd: f32 = 0.382,
    atats: f32 = 1.0e-27,
    btats: f32 = 6.3e-5,
    ctats: f32 = 0.215,
    dtats: f32 = 0.382,

    // --- Impact Ionization ---
    alpha0: f32 = 0.0,
    alpha1: f32 = 0.0,
    beta0: f32 = 0.0,
    alphaii0: f32 = 0.0,
    alphaii1: f32 = 0.0,
    betaii0: f32 = 0.0,
    betaii1: f32 = 0.0,
    betaii2: f32 = 0.1,
    esatii: f32 = 1.0e7,
    lii: f32 = 0.5e-9,
    sii0: f32 = 0.5,
    sii1: f32 = 0.1,
    sii2: f32 = 0.0,
    siid: f32 = 0.0,

    // --- Parasitic Capacitance ---
    cfs: f32 = 2.5e-11,
    cfd: f32 = 2.5e-11, // defaults to CFS
    cgso: f32 = 0.0,
    cgdo: f32 = 0.0,
    cgsl: f32 = 0,
    cgdl: f32 = 0, // defaults to CGSL
    ckappas: f32 = 0.6,
    ckappad: f32 = 0.6, // defaults to CKAPPAS
    covs: f32 = 0.0,
    covd: f32 = 0.0, // defaults to COVS
    cgsp: f32 = 0.0,
    cgdp: f32 = 0.0,
    cdsp: f32 = 0,
    cgbo: f32 = 0,
    cgbn: f32 = 0,
    csdesw: f32 = 0,
    cbox: f32 = 0.0, // CBOX: buried oxide capacitance per unit area (F/m^2)

    // --- Junction Capacitance ---
    cjs: f32 = 0.0005,
    cjd: f32 = 0.0005, // defaults to CJS
    cjsws: f32 = 5.0e-10,
    cjswd: f32 = 5.0e-10, // defaults to CJSWS
    cjswgs: f32 = 0.0,
    cjswgd: f32 = 0.0,
    pbs: f32 = 1.0,
    pbd: f32 = 1.0,
    pbsws: f32 = 1.0,
    pbswd: f32 = 1.0,
    pbswgs: f32 = 1.0,
    pbswgd: f32 = 1.0,
    mjs: f32 = 0.5,
    mjd: f32 = 0.5,
    mjsws: f32 = 0.33,
    mjswd: f32 = 0.33,
    mjswgs: f32 = 0.33,
    mjswgd: f32 = 0.33,
    sjs: f32 = 0.0,
    sjd: f32 = 0.0,
    sjsws: f32 = 0.0,
    sjswd: f32 = 0.0,
    sjswgs: f32 = 0.0,
    sjswgd: f32 = 0.0,
    mjs2: f32 = 0.125,
    mjd2: f32 = 0.125,
    mjsws2: f32 = 0.083,
    mjswd2: f32 = 0.083,
    mjswgs2: f32 = 0.083,
    mjswgd2: f32 = 0.083,

    // --- Junction Current ---
    jss: f32 = 1.0e-4,
    jsd: f32 = 1.0e-4,
    jsws: f32 = 0,
    jswd: f32 = 0,
    jswgs: f32 = 0,
    jswgd: f32 = 0,
    jtss: f32 = 0,
    jtsd: f32 = 0,
    jtssws: f32 = 0,
    jtsswd: f32 = 0,
    jtsswgs: f32 = 0,
    jtsswgd: f32 = 0,
    jtweff: f32 = 0,
    njs: f32 = 1.0,
    njd: f32 = 1.0,
    njts: f32 = 20,
    njtsd: f32 = 20,
    njtssw: f32 = 20,
    njtsswd: f32 = 20,
    njtsswg: f32 = 20,
    njtsswgd: f32 = 20,
    vtss: f32 = 10,
    vtsd: f32 = 10,
    vtssws: f32 = 10,
    vtsswd: f32 = 10,
    vtsswgs: f32 = 10,
    vtsswgd: f32 = 10,
    ijthsfwd: f32 = 0.1,
    ijthdfwd: f32 = 0.1,
    ijthsrev: f32 = 0.1,
    ijthdrev: f32 = 0.1,
    bvs: f32 = 10.0,
    bvd: f32 = 10.0,
    xjbvs: f32 = 1.0,
    xjbvd: f32 = 1.0,

    // --- Generation-Recombination ---
    lintigen: f32 = 0.0,
    ntgen: f32 = 1.0,
    aigen: f32 = 0.0,
    bigen: f32 = 0.0,

    // --- Noise ---
    ef: f32 = 1.0,
    lintnoi: f32 = 0.0,
    em: f32 = 4.1e7,
    noia: f32 = 6.250e39,
    noia2: f32 = 6.250e39,
    noib: f32 = 3.125e24,
    noic: f32 = 8.750e7,
    qsref: f32 = 0.05,
    mpower: f32 = 1.2,
    smooth: f32 = 2,
    k0noi: f32 = 1,
    k1noi: f32 = 1,
    ntnoi: f32 = 1.0,
    rnoia: f32 = 0.577,
    rnoib: f32 = 0.37,
    tnoia: f32 = 1.5,
    tnoib: f32 = 3.5,
    rnoik: f32 = 0,
    tnoik: f32 = 0,
    tnoik2: f32 = 0.1,

    // --- NQS ---
    xrcrg1: f32 = 12.0,
    xrcrg2: f32 = 1.0,

    // --- Self-Heating ---
    rth0: f32 = 0.01,
    cth0: f32 = 1.0e-5,
    wth0: f32 = 0.0,
    ashexp: f32 = 1.0,
    bshexp: f32 = 1.0,
    cshexp: f32 = 1.0,
    ash: f32 = 1.0,
    csh: f32 = 1.0,

    // --- Temperature ---
    tnom: f32 = 27,
    tbgasub: f32 = 7.02e-4,
    tbgbsub: f32 = 1108.0,
    kt1: f32 = 0.0,
    kt1l: f32 = 0.0,
    kt11: f32 = 0.01,
    kt12: f32 = 0.1,
    tvth: f32 = 40.0,
    tss: f32 = 0.0,
    tlow: f32 = 50.0,
    dtlow: f32 = 1.0,
    tlow1: f32 = 0.0,
    dtlow1: f32 = 1.0e-3,
    klow1: f32 = 0.0,
    teta0: f32 = 0.0,
    teta0r: f32 = 0.0,
    ute: f32 = 0.0,
    utl: f32 = -1.5e-3,
    ute1: f32 = -0.4,
    emobt: f32 = 0.0,
    ua1: f32 = 1.032e-3,
    ua2: f32 = -0.04,
    uc1: f32 = 0.056e-9,
    ud1: f32 = 0.0,
    ud2: f32 = -0.04,
    ucste: f32 = -4.775e-3,
    ucste1: f32 = -0.04,
    uds1: f32 = -10,
    udd1: f32 = -10,
    at: f32 = -0.00156,
    at2: f32 = 2.0e-6,
    atcv: f32 = -0.00156,
    at2cv: f32 = 2.0e-6,
    atvsrsd: f32 = 0,
    ksativt1: f32 = -2.0e-4,
    ksativt2: f32 = -2.0e-7,
    pclmt: f32 = -2.0e-5,
    ptwgt: f32 = 0.004,
    tmexp: f32 = 0.0,
    tmexpr: f32 = 0.0,
    tmexp2: f32 = -4.0e-6,
    prt: f32 = 0.001,
    prtvsrsd: f32 = 0.001,
    prt1: f32 = 4.0e-4,
    tr0: f32 = 170.0,
    sprt: f32 = 0.01,
    trsdr: f32 = 0.0,
    trddr: f32 = 0.0,
    iit: f32 = -0.5,
    tii: f32 = 0.0,
    alpha01: f32 = 0.0,
    alpha11: f32 = 0.0,
    alphaii01: f32 = 0.0,
    alphaii11: f32 = 0.0,
    tgidl: f32 = -0.003,
    igt: f32 = 2.5,
    aigbinv1: f32 = 0.0,
    aigbacc1: f32 = 0.0,
    aigc1: f32 = 0.0,
    aigs1: f32 = 0.0,
    aigd1: f32 = 0.0,
    a11: f32 = 0.0,
    a21: f32 = 0.0,
    k01: f32 = 0.0,
    k0si1: f32 = 0.0,
    k11: f32 = 0.0,
    tcj: f32 = 0.0,
    tcjsw: f32 = 0.0,
    tcjswg: f32 = 0.0,
    tpb: f32 = 0.0,
    tpbsw: f32 = 0.0,
    tpbswg: f32 = 0.0,
    xtis: f32 = 3.0,
    xtid: f32 = 3.0,
    xtss: f32 = 0.02,
    xtsd: f32 = 0.02,
    xtssws: f32 = 0.02,
    xtsswd: f32 = 0.02,
    xtsswgs: f32 = 0.02,
    xtsswgd: f32 = 0.02,
    tnjts: f32 = 0.0,
    tnjtsd: f32 = 0.0,
    tnjtssw: f32 = 0.0,
    tnjtsswd: f32 = 0.0,
    tnjtsswg: f32 = 0.0,
    tnjtsswgd: f32 = 0.0,

    // --- Geometry-Dependent Parasitic (RGEOMOD=1, CGEOMOD=2) ---
    hepi: f32 = 10e-9,
    tsili: f32 = 10e-9,
    rhoc: f32 = 1e-12,
    rhorsd: f32 = 0.0,
    cratio: f32 = 0.5,
    deltaprsd: f32 = 0.0,
    sdterm: i32 = 0,
    lsp: f32 = 0.0,
    epsrsp: f32 = 3.9,
    tgate: f32 = 30e-9,
    tmask: f32 = 30e-9,
    asiliend: f32 = 0,
    arsdend: f32 = 0,
    prsdend: f32 = 0,
    nsde: f32 = 2e25,
    rgeoa: f32 = 1.0,
    rgeob: f32 = 0, rgeoc: f32 = 0,
    rgeod: f32 = 0, rgeoe: f32 = 0,
    cgeoa: f32 = 1.0,
    cgeob: f32 = 0, cgeoc: f32 = 0,
    cgeod: f32 = 0, cgeoe: f32 = 1.0,

    // --- Subband (SUBBANDMOD=1) ---
    wgaanom: f32 = 8e-9,
    wdim0: f32 = 9.5e-9,
    wdimr: f32 = 0.1,
    wssp0: f32 = 9.5e-9,
    wsspr: f32 = 0.1,
    dim1h: f32 = 3.0,
    dimension1: f32 = 2.0,
    dim2h: f32 = 3.0,
    dimension2: f32 = 2.6,
    dim3h: f32 = 3, dimension3: f32 = 2.6,
    e2nom: f32 = 0.139,
    e3nom: f32 = 2.0,
    mfe2: f32 = 1.0, mfe3: f32 = 1.0,
    wsfe2: f32 = 1.0, wsfe3: f32 = 1.0,
    tsre2: f32 = 1.8, tdwse2: f32 = 1.0,
    tsre3: f32 = 0.67, tdwse3: f32 = 0.23,
    ssp1: f32 = 14.0, ssp2: f32 = 24.0, ssp3: f32 = 24.0,
    dssp1: f32 = 2.0, dssp2: f32 = 0.0, dssp3: f32 = 0.0,
    mfq1nom: f32 = 11.2, mfq2nom: f32 = 8.02, mfq3nom: f32 = 6.18,
    mfq1: f32 = 1.0, mfq2: f32 = 1.0, mfq3: f32 = 1.0,
    wsfq1: f32 = 1.0, wsfq2: f32 = 1.0, wsfq3: f32 = 1.0,
    tsrq1: f32 = 1.1, tdwsq1: f32 = 2.4,
    tsrq2: f32 = 2.0, tdwsq2: f32 = 2.0,
    tsrq3: f32 = 6.0, tdwsq3: f32 = 2.4,

    // --- Variability ---
    delvtrand: f32 = 0.0,
    ids0mult: f32 = 1.0,

    // --- Unified Model (GEOMOD=4) ---
    ach_ufcm: f32 = 1,
    cins_ufcm: f32 = 1,
    w_ufcm: f32 = 1,
    alpha_ufcm: f32 = 1.8,

    // --- Override ---
    nvtm_ovr: f32 = 0.0, // NVTM override (0 = use computed)
    thetasce_ovr: f32 = -999.0, // sentinel for "not set"
    thetasw_ovr: f32 = -999.0,
    thetadibl_ovr: f32 = -999.0,

    // --- NRS/NRD model-level defaults ---
    nrs: f32 = 0,
    nrd: f32 = 0,

    // --- Length Scaling Auxiliary (A/B pairs) ---
    amexp: f32 = 0, bmexp: f32 = 0,
    aua: f32 = 0, bua: f32 = 0,
    ardsw: f32 = 0, brdsw: f32 = 0,
    avsat: f32 = 0, bvsat: f32 = 0,
    avsat1: f32 = 0, bvsat1: f32 = 0,
    aptwg: f32 = 0, bptwg: f32 = 0,
    apsat: f32 = 0, bpsat: f32 = 0,
    apclm: f32 = 0, bpclm: f32 = 0,
    aud: f32 = 0, bud: f32 = 0,
    arsw: f32 = 0, brsw: f32 = 0,
    ardw: f32 = 0, brdw: f32 = 0,
    avsatcv: f32 = 0, bvsatcv: f32 = 0,
    amexpr: f32 = 0, bmexpr: f32 = 0,

    // --- Dtemp (model-level) ---
    dtemp: f32 = 0.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 30e-9,
    lover: f32 = 30e-9,
    d_cyl: f32 = 40e-9,
    tfin: f32 = 15e-9,
    nfin: f32 = 1,
    nf: f32 = 1,
    hfin: f32 = 30e-9,
    tgaa: f32 = 5e-9,
    wgaa: f32 = 6e-9,
    ngaa: i32 = 1,
    aseo: f32 = 0, adeo: f32 = 0,
    pseo: f32 = 0, pdeo: f32 = 0,
    asej: f32 = 0, adej: f32 = 0,
    psej: f32 = 0, pdej: f32 = 0,
    lrsd: f32 = 30e-9, // default is L (designed gate length)
    xl: f32 = 0,
    xw: f32 = 0,
    tfin_base: f32 = 0,
    tfin_top: f32 = 0,
    dws1: f32 = 0, dws2: f32 = 0, dws3: f32 = 0,
    dach1: f32 = 0, dach2: f32 = 0, dach3: f32 = 0,
    nrs: f32 = 0,
    nrd: f32 = 0,
    dtemp: f32 = 0.0,
    m: f32 = 1.0,
    sa: f32 = 0.0,
    sb: f32 = 0.0,
    sd_: f32 = 0.0,
    ngcon: i32 = 1,
    temp: f32 = 300.15,
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: drain -- di
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.di), .kind = .thermal },
    // Source resistance thermal noise: source -- si
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.si), .kind = .thermal },
    // Gate resistance thermal noise: gate -- gi
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gi), .kind = .thermal },
    // Channel thermal noise: di -- si
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.si), .kind = .thermal },
    // Channel flicker noise: di -- si
    .{ .row = @intFromEnum(U.di), .col = @intFromEnum(U.si), .kind = .flicker },
    // Gate shot noise (Igs): gi -- si
    .{ .row = @intFromEnum(U.gi), .col = @intFromEnum(U.si), .kind = .shot },
    // Gate shot noise (Igd): gi -- di
    .{ .row = @intFromEnum(U.gi), .col = @intFromEnum(U.di), .kind = .shot },
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

// ============================================================================
// Helper: cosh approximation (branchless, no std) — x-independent, f64.
// ============================================================================
inline fn cosh_approx(x: f64) f64 {
    const ex = contract.fmath.exp(@min(@abs(x), 80.0));
    return 0.5 * (ex + 1.0 / ex);
}

// ============================================================================
// Helper: junction depletion charge (two-region) — value-form.
// `v` is x-dependent (S), all other args are x-independent f64. Region select
// (v <= fc*pb) reproduces the original piecewise branch via .val().
// ============================================================================
inline fn junc_charge(comptime S: type, v: S, cj0: f64, pb: f64, mj: f64, fc: f64) S {
    if (cj0 == 0.0) return S.con(0.0);
    const one_minus_mj = 1.0 - mj;
    const fc_pb = fc * pb;
    // Reverse bias region: v <= fc*pb
    //   x_dep = max(1 - v/pb, 1e-30)
    //   q_rev = (cj0*pb/one_minus_mj) * (1 - exp(one_minus_mj*log(x_dep)))
    const x_dep = v.scale(-1.0 / pb).addC(1.0).maxC(1e-30);
    const q_rev = x_dep.log().scale(one_minus_mj).exp().neg().addC(1.0).scale(cj0 * pb / one_minus_mj);
    // Forward bias region: v > fc*pb (quadratic extension)
    const one_minus_fc = @max(1.0 - fc, 1e-30);
    const f1 = (cj0 * pb / one_minus_mj) * (1.0 - contract.fmath.exp(one_minus_mj * contract.fmath.log(one_minus_fc)));
    const f2 = contract.fmath.exp((1.0 + mj) * contract.fmath.log(one_minus_fc));
    const f3 = 1.0 - fc * (1.0 + mj);
    // q_fwd = f1 + (cj0/f2) * (f3*(v - fc_pb) + (mj/(2*pb))*(v*v - fc_pb*fc_pb))
    const term_lin = v.addC(-fc_pb).scale(f3);
    const term_quad = v.mul(v).addC(-(fc_pb * fc_pb)).scale(mj / (2.0 * pb));
    const q_fwd = term_lin.add(term_quad).scale(cj0 / f2).addC(f1);
    return if (v.val() <= fc_pb) q_rev else q_fwd;
}

// ============================================================================
// x-independent parameter/temperature/geometry prep for eval (all f64).
//
// `dt_sh` is the self-heating temperature rise (x[dt]); it enters the operating
// temperature and thus all temperature-dependent params. Matching the original
// pointer-form stamp sparsity (g_pattern only carries the dt,dt self-diagonal),
// the self-heating temperature feedback into the physics params is NOT carried
// as a Jacobian entry, so dt_sh is treated as a plain f64 here.
// ============================================================================

const EvalPrep = struct {
    type_f: f64,
    m_mult: f64,
    nf_total: f64,
    nfin_f: f64,
    nf_f: f64,
    tfin_i: f64,
    hfin_i: f64,
    vt: f64,
    // geometry / oxide
    c_ox: f64,
    eot: f64,
    eps_ratio: f64,
    w_eff0: f64,
    l_eff: f64,
    q_dep: f64,
    // subthreshold
    n_ss: f64,
    nvtm: f64,
    t5: f64,
    dphi: f64,
    dvth_all_base: f64, // dvth_sce + dvth_rsce + dvth_temp + delvtrand (Vds-independent part)
    theta_dibl: f64,
    eta0: f64,
    eta1: f64,
    dvtp0: f64,
    dvtp1: f64,
    cdsc_slope: f64, // theta_sw * cdscd  (n_ss recomputed with Vds inside S? no: kept f64, see note)
    dvtshift: f64,
    phin: f64,
    dvt_qm: f64,
    qmfactor: f64,
    // mobility
    mu0_t: f64,
    ua_t: f64,
    eu_m: f64,
    ud_t: f64,
    ucs_t: f64,
    uc_t: f64,
    etamob: f64,
    mu0mult: f64,
    muhc0: f64,
    muhc1: f64,
    bulkmod_on: bool,
    // NUD
    k0: f64,
    k0si: f64,
    k1: f64,
    phibe: f64,
    // vsat / vdsat
    vsat_t: f64,
    vsat1_t: f64,
    ksativ: f64,
    esat_l_over_dmob: f64, // = 2*vsat_t*l_eff/mu0_t (esat_l without d_mob; d_mob is x-dep)
    deltavsat: f64,
    psat_l: f64,
    ptwg_t: f64,
    a1_m: f64,
    a2_m: f64,
    mexp_t: f64,
    rds_val: f64,
    rdsmod: i32,
    // output conductance
    pclm_t: f64,
    pclmg: f64,
    theta_rout: f64,
    pdibl2: f64,
    pvag: f64,
    ids0mult: f64,
    // gidl
    gidlmod: i32,
    agidl: f64,
    bgidl_t: f64,
    cgidl: f64,
    egidl: f64,
    pgidl: f64,
    agisl: f64,
    bgisl_t: f64,
    cgisl: f64,
    egisl: f64,
    pgisl: f64,
    vfbsd: f64,
    // impact ionization
    iimod: i32,
    alpha0_t: f64,
    alpha1_t: f64,
    beta0_ii: f64,
    ii_temp: f64,
    alphaii0_t: f64,
    alphaii1_t: f64,
    betaii0: f64,
    betaii1: f64,
    betaii2: f64,
    sii0: f64,
    sii1: f64,
    sii2: f64,
    siid: f64,
    esatii: f64,
    lii: f64,
    ii_temp2: f64,
    // gate tunneling
    igcmod: i32,
    igbmod: i32,
    tox_ratio: f64,
    ig_temp: f64,
    aigc_t: f64,
    bigc: f64,
    cigc: f64,
    igc0mult: f64,
    toxg: f64,
    aigbinv_t: f64,
    bigbinv: f64,
    cigbinv: f64,
    aigbacc_t: f64,
    bigbacc: f64,
    cigbacc: f64,
    igb0mult: f64,
    // gen-recomb
    gen_on: bool,
    gen_coeff: f64, // hfin*tfin*l_gen*gen_temp*nf_total
    aigen: f64,
    bigen: f64,
    // junction
    nvtms: f64,
    nvtmd: f64,
    isbs: f64,
    isbd: f64,
    xexpbvs: f64,
    xexpbvd: f64,
    bvs: f64,
    bvd: f64,
    xjbvs: f64,
    xjbvd: f64,
    // series R
    g_rd: f64,
    g_rs: f64,
    g_rg: f64,
    gbmin: f64,
    // self-heating
    shmod: i32,
    gth: f64,
    dt_sh: f64,
};

fn prepEval(model: *const Model, instance: *const Instance, dt_sh: f64) EvalPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const eot: f64 = @as(f64, model.eot);
    const epsrox: f64 = @as(f64, model.epsrox);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const nbody: f64 = @as(f64, model.nbody);
    const nsd: f64 = @as(f64, model.nsd);
    const phig_m: f64 = @as(f64, model.phig);
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const ni0sub: f64 = @as(f64, model.ni0sub);
    const easub: f64 = @as(f64, model.easub);
    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);

    const l_drawn: f64 = @as(f64, instance.l);
    const tfin_i: f64 = @as(f64, instance.tfin);
    const hfin_i: f64 = @as(f64, instance.hfin);
    const nfin_f: f64 = @as(f64, instance.nfin);
    const nf_f: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const xl_v: f64 = @as(f64, instance.xl);

    const dvt0: f64 = @as(f64, model.dvt0);
    const dvt1: f64 = @as(f64, model.dvt1);
    const dvt1ss: f64 = @as(f64, model.dvt1ss);
    const dsub: f64 = @as(f64, model.dsub);
    const eta0: f64 = @as(f64, model.eta0);
    const eta1: f64 = @as(f64, model.eta1);
    const dvtp0: f64 = @as(f64, model.dvtp0);
    const dvtp1: f64 = @as(f64, model.dvtp1);
    const k1rsce: f64 = @as(f64, model.k1rsce);
    const lpe0: f64 = @as(f64, model.lpe0);
    const dvtshift: f64 = @as(f64, model.dvtshift);
    const phin: f64 = @as(f64, model.phin);
    const cit: f64 = @as(f64, model.cit);
    const cdsc_m: f64 = @as(f64, model.cdsc);
    const cdscd_m: f64 = @as(f64, model.cdscd);
    const delvtrand: f64 = @as(f64, model.delvtrand);

    const mu0_base: f64 = @as(f64, model.u0);
    const ua_m: f64 = @as(f64, model.ua);
    const uc_m: f64 = @as(f64, model.uc);
    const eu_m: f64 = @as(f64, model.eu);
    const ud_m: f64 = @as(f64, model.ud);
    const ucs_m: f64 = @as(f64, model.ucs);
    const etamob: f64 = @as(f64, model.etamob);
    const up_m: f64 = @as(f64, model.up);
    const lpa: f64 = @as(f64, model.lpa);
    const mu0mult: f64 = @as(f64, model.u0mult);
    const muhc0: f64 = @as(f64, model.muhc0);
    const muhc1: f64 = @as(f64, model.muhc1);

    const vsat_m: f64 = @as(f64, model.vsat);
    const vsat1_m: f64 = @as(f64, model.vsat1);
    const deltavsat: f64 = @as(f64, model.deltavsat);
    const psat_m: f64 = @as(f64, model.psat);
    const ksativ: f64 = @as(f64, model.ksativ);
    const ptwg_m: f64 = @as(f64, model.ptwg);
    const mexp_m: f64 = @as(f64, model.mexp);
    const a1_m: f64 = @as(f64, model.a1);
    const a2_m: f64 = @as(f64, model.a2);

    const pclm: f64 = @as(f64, model.pclm);
    const pclmg: f64 = @as(f64, model.pclmg);
    const pdibl1: f64 = @as(f64, model.pdibl1);
    const pdibl2: f64 = @as(f64, model.pdibl2);
    const drout: f64 = @as(f64, model.drout);
    const pvag: f64 = @as(f64, model.pvag);

    const rdsw: f64 = @as(f64, model.rdsw);
    const rdswmin: f64 = @as(f64, model.rdswmin);
    const wr: f64 = @as(f64, model.wr);
    const rshs: f64 = @as(f64, model.rshs);
    const rshd: f64 = @as(f64, model.rshd);

    const k0: f64 = @as(f64, model.k0);
    const k0si: f64 = @as(f64, model.k0si);
    const k1: f64 = @as(f64, model.k1);
    const phibe: f64 = @as(f64, model.phibe);

    const qmfactor: f64 = @as(f64, model.qmfactor);

    const agidl: f64 = @as(f64, model.agidl);
    const bgidl: f64 = @as(f64, model.bgidl);
    const cgidl: f64 = @as(f64, model.cgidl);
    const egidl: f64 = @as(f64, model.egidl);
    const pgidl: f64 = @as(f64, model.pgidl);
    const agisl: f64 = @as(f64, model.agisl);
    const bgisl: f64 = @as(f64, model.bgisl);
    const cgisl: f64 = @as(f64, model.cgisl);
    const egisl: f64 = @as(f64, model.egisl);
    const pgisl: f64 = @as(f64, model.pgisl);

    const alpha0: f64 = @as(f64, model.alpha0);
    const alpha1: f64 = @as(f64, model.alpha1);
    const beta0_ii: f64 = @as(f64, model.beta0);
    const alphaii0: f64 = @as(f64, model.alphaii0);
    const alphaii1: f64 = @as(f64, model.alphaii1);
    const betaii0: f64 = @as(f64, model.betaii0);
    const betaii1: f64 = @as(f64, model.betaii1);
    const betaii2: f64 = @as(f64, model.betaii2);
    const esatii: f64 = @as(f64, model.esatii);
    const lii: f64 = @as(f64, model.lii);
    const sii0: f64 = @as(f64, model.sii0);
    const sii1: f64 = @as(f64, model.sii1);
    const sii2: f64 = @as(f64, model.sii2);
    const siid: f64 = @as(f64, model.siid);

    const toxref: f64 = @as(f64, model.toxref);
    const toxg: f64 = @as(f64, model.toxg);
    const ntox: f64 = @as(f64, model.ntox);
    const aigbinv: f64 = @as(f64, model.aigbinv);
    const bigbinv: f64 = @as(f64, model.bigbinv);
    const cigbinv: f64 = @as(f64, model.cigbinv);
    const aigbacc: f64 = @as(f64, model.aigbacc);
    const bigbacc: f64 = @as(f64, model.bigbacc);
    const cigbacc: f64 = @as(f64, model.cigbacc);
    const aigc: f64 = @as(f64, model.aigc);
    const bigc: f64 = @as(f64, model.bigc);
    const cigc: f64 = @as(f64, model.cigc);
    const igb0mult: f64 = @as(f64, model.igb0mult);
    const igc0mult: f64 = @as(f64, model.igc0mult);
    const vfbsd: f64 = @as(f64, model.vfbsd);

    const aigen: f64 = @as(f64, model.aigen);
    const bigen: f64 = @as(f64, model.bigen);
    const ntgen: f64 = @as(f64, model.ntgen);
    const lintigen: f64 = @as(f64, model.lintigen);

    const jss: f64 = @as(f64, model.jss);
    const jsd: f64 = @as(f64, model.jsd);
    const jsws: f64 = @as(f64, model.jsws);
    const jswd: f64 = @as(f64, model.jswd);
    const jswgs: f64 = @as(f64, model.jswgs);
    const jswgd: f64 = @as(f64, model.jswgd);
    const njs_m: f64 = @as(f64, model.njs);
    const njd_m: f64 = @as(f64, model.njd);
    const bvs: f64 = @as(f64, model.bvs);
    const bvd: f64 = @as(f64, model.bvd);
    const xjbvs: f64 = @as(f64, model.xjbvs);
    const xjbvd: f64 = @as(f64, model.xjbvd);

    const asej: f64 = @as(f64, instance.asej);
    const adej: f64 = @as(f64, instance.adej);
    const psej: f64 = @as(f64, instance.psej);
    const pdej: f64 = @as(f64, instance.pdej);

    const rgext: f64 = @as(f64, model.rgext);
    const rgint: f64 = @as(f64, model.rgint);
    const rgfin: f64 = @as(f64, model.rgfin);
    const rth0: f64 = @as(f64, model.rth0);
    const gbmin: f64 = @as(f64, model.gbmin);

    const tnom_c: f64 = @as(f64, model.tnom);
    const dtemp_m: f64 = @as(f64, model.dtemp);
    const dtemp_i: f64 = @as(f64, instance.dtemp);
    const kt1: f64 = @as(f64, model.kt1);
    const kt1l: f64 = @as(f64, model.kt1l);
    const ute: f64 = @as(f64, model.ute);
    const utl: f64 = @as(f64, model.utl);
    const ua1: f64 = @as(f64, model.ua1);
    const uc1: f64 = @as(f64, model.uc1);
    const ud1: f64 = @as(f64, model.ud1);
    const ucste: f64 = @as(f64, model.ucste);
    const at: f64 = @as(f64, model.at);
    const prt: f64 = @as(f64, model.prt);
    const ptwgt: f64 = @as(f64, model.ptwgt);
    const pclmt: f64 = @as(f64, model.pclmt);
    const tmexp_m: f64 = @as(f64, model.tmexp);
    const tgidl: f64 = @as(f64, model.tgidl);
    const igt: f64 = @as(f64, model.igt);
    const iit: f64 = @as(f64, model.iit);

    const ids0mult: f64 = @as(f64, model.ids0mult);

    const lint: f64 = @as(f64, model.lint);
    const ll: f64 = @as(f64, model.ll);
    const lln: f64 = @as(f64, model.lln);
    const deltaw: f64 = @as(f64, model.deltaw);

    const amexp: f64 = @as(f64, model.amexp);
    const bmexp: f64 = @as(f64, model.bmexp);
    const aua: f64 = @as(f64, model.aua);
    const bua: f64 = @as(f64, model.bua);
    const avsat: f64 = @as(f64, model.avsat);
    const bvsat: f64 = @as(f64, model.bvsat);
    const apclm: f64 = @as(f64, model.apclm);
    const bpclm: f64 = @as(f64, model.bpclm);
    const apsat: f64 = @as(f64, model.apsat);
    const bpsat: f64 = @as(f64, model.bpsat);
    const ardsw: f64 = @as(f64, model.ardsw);
    const brdsw: f64 = @as(f64, model.brdsw);

    const fpitch: f64 = @as(f64, model.fpitch);
    const ashexp: f64 = @as(f64, model.ashexp);
    const bshexp: f64 = @as(f64, model.bshexp);
    const ash: f64 = @as(f64, model.ash);

    // Physical Constants & Derived
    const eps_sub = epsrsub * EPS_0;
    const eps_ox = epsrox * EPS_0;
    const c_ox = 3.9 * EPS_0 / eot;
    const eps_ratio = epsrsub / 3.9;

    // Temperature
    const tnom_k = tnom_c + 273.15;
    const t_dev = @as(f64, instance.temp) + dtemp_m + dtemp_i;
    const t_eff = t_dev + dt_sh;
    const vt = K_BOLTZ * t_eff / Q_ELEM;
    const dt_temp = t_eff - tnom_k;

    const eg_tnom = bg0sub - tbgasub * tnom_k * tnom_k / (tnom_k + tbgbsub);
    const eg = bg0sub - tbgasub * t_eff * t_eff / (t_eff + tbgbsub);

    const ni = ni0sub * contract.fmath.exp(0.5 * contract.fmath.log(@max(t_eff / 300.15, 1e-30)) * 3.0) *
        contract.fmath.exp(@min(bg0sub * Q_ELEM / (2.0 * K_BOLTZ * 300.15) - eg * Q_ELEM / (2.0 * K_BOLTZ * t_eff), 80.0));

    const vbi = vt * contract.fmath.log(@max(nsd * nbody / (ni * ni), 1.0));
    const psi_st = phibe;

    // Effective channel length
    const l_xl = l_drawn + xl_v;
    const dl = lint + ll / @max(contract.fmath.exp(lln * contract.fmath.log(@max(l_xl, 1e-30))), 1e-30);
    const l_eff = @max(l_xl - 2.0 * dl, 1e-9);

    // Effective width (GEOMOD-dependent)
    const w_eff_ufcm: f64 = switch (model.geomod) {
        0 => 2.0 * hfin_i,
        1 => 2.0 * hfin_i + tfin_i,
        2 => 2.0 * hfin_i + 2.0 * tfin_i,
        3 => PI * @as(f64, instance.d_cyl),
        6 => hfin_i,
        else => 2.0 * hfin_i + tfin_i,
    };
    const w_eff0 = @max(w_eff_ufcm - deltaw, 1e-12);

    const a_ch: f64 = switch (model.geomod) {
        3 => PI * @as(f64, instance.d_cyl) * @as(f64, instance.d_cyl) / 4.0,
        else => hfin_i * tfin_i,
    };
    const c_ins: f64 = switch (model.geomod) {
        3 => 2.0 * PI * eps_ox / contract.fmath.log(@max(1.0 + 2.0 * eot / @as(f64, instance.d_cyl), 1.001)),
        else => w_eff_ufcm * eps_ox / eot,
    };

    const q_dep = -Q_ELEM * nbody * a_ch / c_ins;
    const c_si = eps_sub / tfin_i;
    const nf_total = nfin_f * nf_f;

    // Length scaling
    const mu0_l: f64 = if (lpa > 0.0 and up_m != 0.0) mu0_base * (1.0 - up_m * contract.fmath.exp(-lpa * contract.fmath.log(@max(l_eff * 1e6, 1e-30)))) else mu0_base;
    const mexp_l: f64 = if (bmexp != 0.0) mexp_m + amexp * contract.fmath.exp(-bmexp * contract.fmath.log(@max(l_eff, 1e-30))) else mexp_m;
    const pclm_l: f64 = if (bpclm != 0.0) pclm + apclm * contract.fmath.exp(-l_eff / @max(bpclm, 1e-30)) else pclm;
    const ua_l: f64 = if (bua != 0.0) ua_m + aua * contract.fmath.exp(-l_eff / @max(bua, 1e-30)) else ua_m;
    const vsat_l: f64 = if (bvsat != 0.0) vsat_m + avsat * contract.fmath.exp(-l_eff / @max(bvsat, 1e-30)) else vsat_m;
    const psat_l: f64 = if (bpsat != 0.0) psat_m + apsat * contract.fmath.exp(-l_eff / @max(bpsat, 1e-30)) else psat_m;
    const rdsw_l: f64 = if (brdsw != 0.0) rdsw + ardsw * contract.fmath.exp(-l_eff / @max(brdsw, 1e-30)) else rdsw;

    // Temperature-dependent parameters
    const dvth_temp = (kt1 + kt1l / l_eff) * (t_eff / tnom_k - 1.0);
    const mu0_t: f64 = mu0_l * contract.fmath.exp(ute * contract.fmath.log(@max(t_eff / tnom_k, 1e-30))) + utl * dt_temp;
    const ua_t = ua_l + ua1 * dt_temp;
    const uc_t = uc_m + uc1 * dt_temp;
    const ud_t = ud_m + ud1 * dt_temp;
    const ucs_t = ucs_m * (1.0 + ucste * dt_temp);
    const vsat_t = vsat_l * (1.0 - at * dt_temp);
    const vsat1_t = vsat1_m * (1.0 - at * dt_temp);
    const pclm_t = @max(pclm_l * (1.0 + pclmt * dt_temp), 1e-15);
    const ptwg_t = ptwg_m * (1.0 + ptwgt * dt_temp);
    const mexp_t = @max(mexp_l * (1.0 + tmexp_m * dt_temp), 2.0);
    const rdsw_t = rdsw_l * (1.0 + prt * dt_temp);
    const bgidl_t = bgidl * (1.0 + tgidl * dt_temp);
    const bgisl_t = bgisl * (1.0 + tgidl * dt_temp);
    const ig_temp = contract.fmath.exp(igt * contract.fmath.log(@max(t_eff / tnom_k, 1e-30)));

    const alpha0_t = alpha0 * (1.0 + @as(f64, model.alpha01) * dt_temp);
    const alpha1_t = alpha1 * (1.0 + @as(f64, model.alpha11) * dt_temp);
    const ii_temp = contract.fmath.exp(iit * contract.fmath.log(@max(t_eff / tnom_k, 1e-30)));
    const alphaii0_t = alphaii0 * (1.0 + @as(f64, model.alphaii01) * dt_temp);
    const alphaii1_t = alphaii1 * (1.0 + @as(f64, model.alphaii11) * dt_temp);
    const tii_m: f64 = @as(f64, model.tii);
    const ii_temp2 = contract.fmath.exp(tii_m * contract.fmath.log(@max(t_eff / tnom_k, 1e-30)));

    const t3s = contract.fmath.exp(@min(Q_ELEM * eg_tnom / (K_BOLTZ * tnom_k) - Q_ELEM * eg / (K_BOLTZ * t_eff) +
        @as(f64, model.xtis) * contract.fmath.log(@max(t_eff / tnom_k, 1e-30)), 80.0));
    const t3d = contract.fmath.exp(@min(Q_ELEM * eg_tnom / (K_BOLTZ * tnom_k) - Q_ELEM * eg / (K_BOLTZ * t_eff) +
        @as(f64, model.xtid) * contract.fmath.log(@max(t_eff / tnom_k, 1e-30)), 80.0));

    const jss_t = jss * contract.fmath.exp(@min(njs_m * contract.fmath.log(@max(t3s, 1e-30)), 80.0));
    const jsd_t = jsd * contract.fmath.exp(@min(njd_m * contract.fmath.log(@max(t3d, 1e-30)), 80.0));
    const jsws_t = jsws * contract.fmath.exp(@min(njs_m * contract.fmath.log(@max(t3s, 1e-30)), 80.0));
    const jswd_t = jswd * contract.fmath.exp(@min(njd_m * contract.fmath.log(@max(t3d, 1e-30)), 80.0));
    const jswgs_t = jswgs * contract.fmath.exp(@min(njs_m * contract.fmath.log(@max(t3s, 1e-30)), 80.0));
    const jswgd_t = jswgd * contract.fmath.exp(@min(njd_m * contract.fmath.log(@max(t3d, 1e-30)), 80.0));

    // Short channel effects (Vds-independent parts)
    const scl_arg = eps_sub * a_ch / c_ins;
    const scl_corr = 1.0 + a_ch * c_ins / (2.0 * eps_sub * w_eff_ufcm * w_eff_ufcm);
    const scl = @sqrt(@max(scl_arg * scl_corr, 1e-30));

    const theta_sce = if (model.thetasce_ovr != -999.0)
        @as(f64, model.thetasce_ovr)
    else
        -0.5 / @max(cosh_approx(dvt1 * l_eff / scl) - 1.0, 1e-10);
    const theta_sw = if (model.thetasw_ovr != -999.0)
        @as(f64, model.thetasw_ovr)
    else
        0.5 / @max(cosh_approx(dvt1ss * l_eff / scl) - 1.0, 1e-10);
    const theta_dibl = if (model.thetadibl_ovr != -999.0)
        @as(f64, model.thetadibl_ovr)
    else
        -0.5 / @max(cosh_approx(dsub * l_eff / scl) - 1.0, 1e-10);

    // NOTE: n_ss uses cdsc_eff = theta_sw*(cdsc + cdscd*vdsx) which is Vds-dep.
    // The original code recomputed nvtm per bias. We capture the Vds-independent
    // base (cdsc_m) and slope (theta_sw*cdscd_m); the S tail recomputes nvtm.
    const cox_csi = (2.0 * c_si * c_ox) / @max(2.0 * c_si + c_ox, 1e-30);
    const n_ss_base = @max(1.0 + (cit + theta_sw * cdsc_m) / cox_csi, 1.0);
    const cdsc_slope = theta_sw * cdscd_m / cox_csi;

    const dvth_sce = theta_sce * dvt0 * (vbi - psi_st);
    const dvth_rsce = k1rsce * (@sqrt(@max(1.0 + lpe0 / l_eff, 0.0)) - 1.0) * psi_st;
    const dvth_all_base = dvth_sce + dvth_rsce + dvth_temp + delvtrand;

    const phi_sub = easub + eg / 2.0 + vt * contract.fmath.log(@max(nbody / ni, 1.0));
    const dphi = phig_m - phi_sub;

    const dvt_qm: f64 = if (qmfactor != 0.0)
        qmfactor * HBAR * HBAR * PI * PI / (2.0 * M_ELEC * tfin_i * tfin_i * Q_ELEM)
    else
        0.0;

    // t5 uses nvtm = n_ss * vt. n_ss is Vds-dependent, but t5 = c_ox/(Q*ni*eps_sub)
    // is independent of nvtm (nvtm cancels). Keep as f64.
    const t5_const = c_ox / (Q_ELEM * ni * eps_sub);

    // esat_l without d_mob (d_mob is x-dependent): esat_l = 2*vsat_t*d_mob/mu0_t * l_eff.
    // We store the d_mob-free factor and multiply by d_mob in S.
    const esat_l_over_dmob = 2.0 * vsat_t * l_eff / @max(mu0_t, 1e-30);

    // Series resistance base (RDSMOD=0)
    const weff_wr = contract.fmath.exp(wr * contract.fmath.log(@max(w_eff0 * 1e6, 1e-30)));
    const rds_val: f64 = if (model.rdsmod == 0) @max(rdsw_t / weff_wr, rdswmin / weff_wr) else 0.0;

    // DIBL on Rout
    const theta_rout = 0.5 * pdibl1 / @max(cosh_approx(drout * l_eff / scl) - 1.0, 1e-10) + pdibl2;

    // Gate tunneling constants
    const tox_ratio = (1.0 / (toxg * toxg)) * contract.fmath.exp(ntox * contract.fmath.log(@max(toxref / toxg, 1e-30)));
    const aigc_t = aigc * (1.0 + @as(f64, model.aigc1) * dt_temp);
    const aigbinv_t = aigbinv * (1.0 + @as(f64, model.aigbinv1) * dt_temp);
    const aigbacc_t = aigbacc * (1.0 + @as(f64, model.aigbacc1) * dt_temp);

    // Gen-recomb prep
    const gen_on = (aigen != 0.0 or bigen != 0.0);
    const l_gen = @max(l_eff - lintigen, 1e-12);
    const gen_temp = contract.fmath.exp(@min(Q_ELEM * eg / (ntgen * K_BOLTZ * t_eff) * (t_eff / tnom_k - 1.0), 80.0));
    const gen_coeff = hfin_i * tfin_i * l_gen * gen_temp * nf_total;

    // Junction prep
    const nvtms = njs_m * vt;
    const nvtmd = njd_m * vt;
    const isbs = asej * jss_t + psej * jsws_t + tfin_i * nf_total * jswgs_t;
    const isbd = adej * jsd_t + pdej * jswd_t + tfin_i * nf_total * jswgd_t;
    const xexpbvs: f64 = if (bvs > 0.0) contract.fmath.exp(@min(-bvs / nvtms, 80.0)) else 0.0;
    const xexpbvd: f64 = if (bvd > 0.0) contract.fmath.exp(@min(-bvd / nvtmd, 80.0)) else 0.0;

    // Series resistances
    const rd_eff: f64 = if (model.rdsmod == 1) @as(f64, model.rdw) / @max(weff_wr, 1e-30) + rshd * @as(f64, instance.nrd) else rshd * @as(f64, instance.nrd);
    const g_rd: f64 = if (rd_eff > 0.0) m_mult * nf_total / rd_eff else GSHORT;
    const rs_eff: f64 = if (model.rdsmod == 1) @as(f64, model.rsw) / @max(weff_wr, 1e-30) + rshs * @as(f64, instance.nrs) else rshs * @as(f64, instance.nrs);
    const g_rs: f64 = if (rs_eff > 0.0) m_mult * nf_total / rs_eff else GSHORT;
    const rg_eff: f64 = rgext + rgint + rgfin / @max(nfin_f * nf_f, 1.0);
    const g_rg: f64 = if (model.rgatemod != 0 and rg_eff > 0.0) 1.0 / rg_eff else GSHORT;

    // Self-heating conductance
    const gth_numer = @as(f64, model.wth0) * contract.fmath.exp(bshexp * contract.fmath.log(@max(nf_f, 1.0))) + ash * fpitch * contract.fmath.exp(ashexp * contract.fmath.log(@max(nf_total, 1.0)));
    const gth = gth_numer / @max(rth0, 1e-30);

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .nf_total = nf_total,
        .nfin_f = nfin_f,
        .nf_f = nf_f,
        .tfin_i = tfin_i,
        .hfin_i = hfin_i,
        .vt = vt,
        .c_ox = c_ox,
        .eot = eot,
        .eps_ratio = eps_ratio,
        .w_eff0 = w_eff0,
        .l_eff = l_eff,
        .q_dep = q_dep,
        .n_ss = n_ss_base,
        .nvtm = n_ss_base * vt,
        .t5 = t5_const,
        .dphi = dphi,
        .dvth_all_base = dvth_all_base,
        .theta_dibl = theta_dibl,
        .eta0 = eta0,
        .eta1 = eta1,
        .dvtp0 = dvtp0,
        .dvtp1 = dvtp1,
        .cdsc_slope = cdsc_slope,
        .dvtshift = dvtshift,
        .phin = phin,
        .dvt_qm = dvt_qm,
        .qmfactor = qmfactor,
        .mu0_t = mu0_t,
        .ua_t = ua_t,
        .eu_m = eu_m,
        .ud_t = ud_t,
        .ucs_t = ucs_t,
        .uc_t = uc_t,
        .etamob = etamob,
        .mu0mult = mu0mult,
        .muhc0 = muhc0,
        .muhc1 = muhc1,
        .bulkmod_on = model.bulkmod != 0,
        .k0 = k0,
        .k0si = k0si,
        .k1 = k1,
        .phibe = phibe,
        .vsat_t = vsat_t,
        .vsat1_t = vsat1_t,
        .ksativ = ksativ,
        .esat_l_over_dmob = esat_l_over_dmob,
        .deltavsat = deltavsat,
        .psat_l = psat_l,
        .ptwg_t = ptwg_t,
        .a1_m = a1_m,
        .a2_m = a2_m,
        .mexp_t = mexp_t,
        .rds_val = rds_val,
        .rdsmod = model.rdsmod,
        .pclm_t = pclm_t,
        .pclmg = pclmg,
        .theta_rout = theta_rout,
        .pdibl2 = pdibl2,
        .pvag = pvag,
        .ids0mult = ids0mult,
        .gidlmod = model.gidlmod,
        .agidl = agidl,
        .bgidl_t = bgidl_t,
        .cgidl = cgidl,
        .egidl = egidl,
        .pgidl = pgidl,
        .agisl = agisl,
        .bgisl_t = bgisl_t,
        .cgisl = cgisl,
        .egisl = egisl,
        .pgisl = pgisl,
        .vfbsd = vfbsd,
        .iimod = model.iimod,
        .alpha0_t = alpha0_t,
        .alpha1_t = alpha1_t,
        .beta0_ii = beta0_ii,
        .ii_temp = ii_temp,
        .alphaii0_t = alphaii0_t,
        .alphaii1_t = alphaii1_t,
        .betaii0 = betaii0,
        .betaii1 = betaii1,
        .betaii2 = betaii2,
        .sii0 = sii0,
        .sii1 = sii1,
        .sii2 = sii2,
        .siid = siid,
        .esatii = esatii,
        .lii = lii,
        .ii_temp2 = ii_temp2,
        .igcmod = model.igcmod,
        .igbmod = model.igbmod,
        .tox_ratio = tox_ratio,
        .ig_temp = ig_temp,
        .aigc_t = aigc_t,
        .bigc = bigc,
        .cigc = cigc,
        .igc0mult = igc0mult,
        .toxg = toxg,
        .aigbinv_t = aigbinv_t,
        .bigbinv = bigbinv,
        .cigbinv = cigbinv,
        .aigbacc_t = aigbacc_t,
        .bigbacc = bigbacc,
        .cigbacc = cigbacc,
        .igb0mult = igb0mult,
        .gen_on = gen_on,
        .gen_coeff = gen_coeff,
        .aigen = aigen,
        .bigen = bigen,
        .nvtms = nvtms,
        .nvtmd = nvtmd,
        .isbs = isbs,
        .isbd = isbd,
        .xexpbvs = xexpbvs,
        .xexpbvd = xexpbvd,
        .bvs = bvs,
        .bvd = bvd,
        .xjbvs = xjbvs,
        .xjbvd = xjbvd,
        .g_rd = g_rd,
        .g_rs = g_rs,
        .g_rg = g_rg,
        .gbmin = gbmin,
        .shmod = model.shmod,
        .gth = gth,
        .dt_sh = dt_sh,
    };
}

// ============================================================================
// DC Current Function (value-form)
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    const g = @intFromEnum(U.gate);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);
    const e = @intFromEnum(U.body);
    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);
    const gi = @intFromEnum(U.gi);
    const dt = @intFromEnum(U.dt);

    // Self-heating temperature rise: treated as f64 (outside stamp sparsity).
    const dt_sh: f64 = if (model.shmod != 0) x[dt].val() else 0.0;
    const p = prepEval(model, instance, dt_sh);

    const vt = p.vt;
    const c_ox = p.c_ox;
    const nvtm = p.nvtm;
    const q_dep = p.q_dep;
    const qmfactor = p.qmfactor;
    const w_eff0 = p.w_eff0;
    const l_eff = p.l_eff;
    const nf_total = p.nf_total;
    const type_f = p.type_f;

    // ---- Raw terminal voltages (S) ----
    const vgs_raw = x[gi].sub(x[si]).scale(type_f);
    const vds_raw = x[di].sub(x[si]).scale(type_f);
    const vbs_raw = x[e].sub(x[si]).scale(type_f);
    const vge_raw = x[gi].sub(x[e]).scale(type_f);

    // ---- Source-drain reversal ----
    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs_eff = vgs_raw.sub(vds_neg);
    const vbs_eff = vbs_raw.sub(vds_neg);
    // mode = vds_raw / (|vds| + 1e-30)  (sign, f64 via .val() region select)
    const mode: f64 = vds_raw.val() / (vds_abs.val() + 1e-30);
    const vdsx = vds_abs; // effective |Vds| (S)

    // ---- Subthreshold slope factor n (Vds-dependent) ----
    // n_ss = n_ss_base + cdsc_slope * vdsx ; nvtm_bias = n_ss * vt
    const n_ss = vdsx.scale(p.cdsc_slope).addC(p.n_ss).maxC(1.0);
    const nvtm_bias = n_ss.scale(vt);

    // ---- Vth shifts (Vds-dependent parts) ----
    // dvth_dibl_base = theta_dibl * (eta0*(vdsx + eta1*sqrt(vdsx+0.01)))
    const dvth_dibl_base = vdsx.addC(0.01).maxC(0.0).sqrt().scale(p.eta1).add(vdsx).scale(p.eta0).scale(p.theta_dibl);
    // dvth_dits = theta_dibl * dvtp0 * exp(dvtp1 * log(vdsx+0.01))
    const dvth_dits = if (p.dvtp0 != 0.0)
        vdsx.addC(0.01).maxC(1e-30).log().scale(p.dvtp1).exp().scale(p.theta_dibl * p.dvtp0)
    else
        S.con(0.0);
    const dvth_dibl = dvth_dibl_base.add(dvth_dits);
    // dvth_all = base + dvth_dibl
    const dvth_all = dvth_dibl.addC(p.dvth_all_base);

    // ---- Flatband / gate voltage ----
    // vgsfb = vgs_eff - dphi - dvth_all - dvtshift - phin
    const vgsfb = vgs_eff.sub(dvth_all).addC(-(p.dphi + p.dvtshift + p.phin));
    const vgsfbeff = vgsfb.addC(-p.dvt_qm);

    // ---- Surface potential / inversion charge (source side) ----
    // Note: original used nvtm (=n_ss*vt at this bias). Use nvtm_bias.
    // t5 = c_ox * nvtm / (Q*ni*eps_sub*nvtm) = t5_const (nvtm cancels). f64.
    const t5 = p.t5;
    _ = nvtm;
    const vov = vgsfbeff.div(nvtm_bias);
    var qm_norm = solveQmSource(S, vov, t5, q_dep, qmfactor);

    const qis = qm_norm.neg().mul(nvtm_bias);
    const psi_s = vgsfbeff.sub(qis);

    // ---- Drain-side charge ----
    const vov_d = vgsfbeff.sub(vdsx).div(nvtm_bias);
    var qm_d = solveQmDrain(S, vov_d, t5, q_dep, qmfactor);
    const qid = qm_d.neg().mul(nvtm_bias);
    const dqi = qis.sub(qid);
    const qia = qis.add(qid).scale(0.5);

    // ---- Mobility degradation ----
    const q_ba = @abs(q_dep) * c_ox * nvtm_bias.val(); // q_ba folded below in S
    // Reconstruct q_ba as S so its (weak) nvtm dependence is captured:
    const q_ba_s = nvtm_bias.scale(@abs(q_dep) * c_ox);
    _ = q_ba;
    const qia2 = qia.maxC(1e-30);
    // e_effa = 1e-8*(q_ba + etamob*qia2)/(eps_ratio*eot)
    const e_effa = q_ba_s.add(qia2.scale(p.etamob)).scale(1e-8 / (p.eps_ratio * p.eot));

    // ua_term = ua_t * exp(eu*log(e_effa))
    const ua_term = e_effa.maxC(1e-30).log().scale(p.eu_m).exp().scale(p.ua_t);
    // ud_term = 0.5*exp(ucs*log(ud_t/(1+qia2/(1e-2/c_ox))))  (if ud_t != 0)
    const ud_term = if (p.ud_t != 0.0)
        qia2.scale(1.0 / (1e-2 / c_ox)).addC(1.0).pow(-1.0).scale(p.ud_t).maxC(1e-30).log().scale(p.ucs_t).exp().scale(0.5)
    else
        S.con(0.0);
    const uc_term = if (p.bulkmod_on) vbs_eff.scale(p.uc_t) else S.con(0.0);

    var d_mob = ua_term.add(uc_term).add(ud_term).addC(1.0);
    // Hot-carrier: mu0multv = mu0mult*(1 - muhc0*exp(-muhc1*vdsx))
    const mu0multv = vdsx.scale(-p.muhc1).minC(80.0).exp().scale(-p.muhc0).addC(1.0).scale(p.mu0mult);
    d_mob = d_mob.div(mu0multv);

    // ---- Lateral non-uniform doping ----
    const m_nud = if (p.k0 != 0.0)
        // exp(-k0 / max(max(k0si,1e-10)*qia + 2*nvtm, 1e-15))
        qia.scale(@max(p.k0si, 1e-10)).add(nvtm_bias.scale(2.0)).maxC(1e-15).pow(-1.0).scale(-p.k0).exp()
    else
        S.con(1.0);

    // ---- Drain saturation voltage ----
    // esat_l = esat_l_over_dmob * d_mob
    const esat_l = d_mob.scale(p.esat_l_over_dmob);
    // vgs_minus_psi = max(vgsfbeff - psi_s + 2*vt, 1e-15)
    const vgs_minus_psi = vgsfbeff.sub(psi_s).addC(2.0 * vt).maxC(1e-15);
    const vdsat = computeVdsat(S, p, esat_l, vgs_minus_psi, w_eff0, vt);

    // ---- Effective Vds (smooth) ----
    // vds_vdsat = vdsx / max(vdsat, 1e-15)
    const vds_vdsat = vdsx.div(vdsat.maxC(1e-15));
    const mexp_inv = 1.0 / p.mexp_t;
    // vds_ratio_m = exp(mexp_t * log(vds_vdsat))
    const vds_ratio_m = vds_vdsat.maxC(1e-30).log().scale(p.mexp_t).exp();
    // vdseff = vdsx / exp(mexp_inv * log(max(1 + vds_ratio_m, 1.0)))
    const vdseff = vdsx.div(vds_ratio_m.addC(1.0).maxC(1.0).log().scale(mexp_inv).exp());

    // ---- Velocity saturation ----
    // esat1 = 2*vsat1_t*d_mob/mu0_t
    const esat1 = d_mob.scale(2.0 * p.vsat1_t / @max(p.mu0_t, 1e-30));
    // delta_qi_esat = dqi / max(esat1*l_eff, 1e-15)
    const delta_qi_esat = dqi.div(esat1.scale(l_eff).maxC(1e-15));
    // dvsat_num = 1 + exp(psat_l*log(deltavsat + delta_qi_esat))
    const dvsat_num = delta_qi_esat.addC(p.deltavsat).maxC(1e-30).log().scale(p.psat_l).exp().addC(1.0);
    const dvsat_den = 1.0 + contract.fmath.exp(p.psat_l * contract.fmath.log(@max(p.deltavsat, 1e-30)));
    // d_vsat = dvsat_num/dvsat_den + 0.5*ptwg_t*qia*dqi*dqi
    var d_vsat = dvsat_num.scale(1.0 / dvsat_den).add(qia.mul(dqi).mul(dqi).scale(0.5 * p.ptwg_t));
    // Non-saturation effect
    const vdsat_g = vdsat.addC(1e-15).maxC(1e-15);
    const vd_over_vdsat = vdsx.div(vdsat_g);
    // t0_nsat = 1 + a1*vdsx/vdsat + a2*sqrt(vdsx/vdsat)
    const t0_nsat = vd_over_vdsat.maxC(0.0).sqrt().scale(p.a2_m).add(vd_over_vdsat.scale(p.a1_m)).addC(1.0);
    const n_sat = t0_nsat.addC(1.0).scale(0.5);
    d_vsat = d_vsat.mul(n_sat);

    // ---- Output conductance (CLM, DIBL) ----
    // c_clm = max(pclm_t*(1 + pclmg*(vgsfbeff - psi_s)), 1e-15)
    const vgsfb_minus_psi = vgsfbeff.sub(psi_s);
    const c_clm = vgsfb_minus_psi.scale(p.pclmg).addC(1.0).scale(p.pclm_t).maxC(1e-15);
    const vds_minus_vdseff = vdsx.sub(vdseff).maxC(0.0);
    // m_clm = 1 + (1/c_clm)*log(max(1 + vds_minus_vdseff/(vdsat+esat_l)*c_clm, 1.0))
    const clm_inner = vds_minus_vdseff.div(vdsat.add(esat_l).maxC(1e-15)).mul(c_clm).addC(1.0).maxC(1.0);
    const m_clm = clm_inner.log().div(c_clm).addC(1.0);

    // DIBL on Rout
    // pvag_factor = 1 + pvag*max(vgsfbeff-psi_s,0)/esat_l
    const pvag_factor = vgsfb_minus_psi.maxC(0.0).div(esat_l.maxC(1e-15)).scale(p.pvag).addC(1.0);
    // va_dibl = (vdsat/theta_rout)*(1 - (qis+2vt)/(vdsat+qis+2vt))*pvag_factor  (if theta_rout>1e-15)
    const va_dibl = if (p.theta_rout > 1e-15) blk: {
        const qs2 = qis.addC(2.0 * vt);
        const frac = qs2.div(vdsat.add(qs2).maxC(1e-15));
        break :blk vdsat.scale(1.0 / p.theta_rout).mul(frac.neg().addC(1.0)).mul(pvag_factor);
    } else S.con(1e15);
    // m_oc = 1 + vds_minus_vdseff/va_dibl * m_clm
    const m_oc = vds_minus_vdseff.div(va_dibl.maxC(1e-15)).mul(m_clm).addC(1.0);

    // ---- Drain current ----
    // m_ob body effect
    const m_ob = if (p.bulkmod_on)
        // 1 + k1*(sqrt(phibe-vbs_eff) - sqrt(phibe))/(2*vt)
        vbs_eff.neg().addC(p.phibe).maxC(1e-30).sqrt().addC(-@sqrt(@max(p.phibe, 1e-30))).scale(p.k1 / (2.0 * vt)).addC(1.0)
    else
        S.con(1.0);

    // eta_iv = q_dep / max(q_dep + qia, 1e-30)
    const eta_iv = qia.addC(q_dep).maxC(1e-30).pow(-1.0).scale(q_dep);
    // t2_ids = (2 - eta_iv)*nvtm
    const t2_ids = eta_iv.neg().addC(2.0).mul(nvtm_bias);
    // ids0_dqi = max(qis + t2_ids, 0)
    const ids0_dqi = qis.add(t2_ids).maxC(0.0);
    // ids_raw = ids0mult*mu0_t*c_ox*w_eff0/l_eff * ids0_dqi * dqi * m_oc * m_ob * m_nud / max(d_mob*d_vsat,1e-30) * nf_total
    const ids_pref = p.ids0mult * p.mu0_t * c_ox * w_eff0 / l_eff * nf_total;
    const ids_raw = ids0_dqi.mul(dqi).scale(ids_pref).mul(m_oc).mul(m_ob).mul(m_nud).div(d_mob.mul(d_vsat).maxC(1e-30));

    // ---- GIDL / GISL ----
    var i_gidl = S.con(0.0);
    var i_gisl = S.con(0.0);
    if (p.gidlmod != 0) {
        // GIDL (drain side)
        // vdg_gidl = vdsx - vgs_eff + vfbsd ; vdg_eff = vdg_gidl - egidl
        const vdg_eff = vdsx.sub(vgs_eff).addC(p.vfbsd - p.egidl);
        const t0_gidl = p.agidl * w_eff0;
        i_gidl = if (vdg_eff.val() > 0.0)
            // t0*exp(pgidl*log(vdg_eff/(eps_ratio*eot)))*exp(min(-eps_ratio*eot*bgidl_t/vdg_eff,80))*nf_total
            vdg_eff.scale(1.0 / (p.eps_ratio * p.eot)).maxC(1e-30).log().scale(p.pgidl).exp()
                .mul(vdg_eff.maxC(1e-30).pow(-1.0).scale(-p.eps_ratio * p.eot * p.bgidl_t).minC(80.0).exp())
                .scale(t0_gidl * nf_total)
        else
            S.con(0.0);
        // body factor
        const vde = vdsx.maxC(0.0);
        if (p.bulkmod_on) {
            const vde3 = vde.mul(vde).mul(vde);
            const body_factor = vde3.div(vde3.addC(p.cgidl).maxC(1e-30));
            i_gidl = i_gidl.mul(body_factor);
        }

        // GISL (source side)
        // vsg_gisl = -vgs_eff + vfbsd ; vsg_eff = vsg_gisl - egisl
        const vsg_eff = vgs_eff.neg().addC(p.vfbsd - p.egisl);
        const t0_gisl = p.agisl * w_eff0;
        i_gisl = if (vsg_eff.val() > 0.0)
            vsg_eff.scale(1.0 / (p.eps_ratio * p.eot)).maxC(1e-30).log().scale(p.pgisl).exp()
                .mul(vsg_eff.maxC(1e-30).pow(-1.0).scale(-p.eps_ratio * p.eot * p.bgisl_t).minC(80.0).exp())
                .scale(t0_gisl * nf_total)
        else
            S.con(0.0);
        if (p.bulkmod_on) {
            const vse = vbs_eff.abs();
            const vse3 = vse.mul(vse).mul(vse);
            const body_factor_s = vse3.div(vse3.addC(p.cgisl).maxC(1e-30));
            i_gisl = i_gisl.mul(body_factor_s);
        }
    }

    // ---- Impact ionization ----
    var i_ii = S.con(0.0);
    const vds_minus_vdseff_ii = vdsx.sub(vdseff).maxC(1e-15);
    if (p.iimod == 1) {
        const alpha_t = (p.alpha0_t + p.alpha1_t * l_eff) / l_eff;
        // i_ii = alpha_t*vds*exp(min(-beta0/vds,80))*ids_raw*ii_temp
        i_ii = vds_minus_vdseff_ii.scale(alpha_t)
            .mul(vds_minus_vdseff_ii.maxC(1e-15).pow(-1.0).scale(-p.beta0_ii).minC(80.0).exp())
            .mul(ids_raw).scale(p.ii_temp);
    } else if (p.iimod == 2) {
        const alpha_ii_t = (p.alphaii0_t + p.alphaii1_t * l_eff) / l_eff;
        const vdiff = vds_minus_vdseff_ii;
        // beta_denom = betaii2 + betaii1*vdiff + betaii0*vdiff^2
        const beta_denom = vdiff.mul(vdiff).scale(p.betaii0).add(vdiff.scale(p.betaii1)).addC(p.betaii2);
        // sii_factor = sii0 + sii1*vgs_eff + sii2*vdsx + siid*vdiff
        const sii_factor = vgs_eff.scale(p.sii1).add(vdsx.scale(p.sii2)).add(vdiff.scale(p.siid)).addC(p.sii0);
        // esat_ii_factor = 1 + lii/l_eff*exp(min(-vdiff*esatii,80))
        const esat_ii_factor = vdiff.scale(-p.esatii).minC(80.0).exp().scale(p.lii / @max(l_eff, 1e-15)).addC(1.0);
        // i_ii = alpha_ii_t*ids_raw*sii_factor*esat_ii_factor*ii_temp2*exp(min(vdiff/beta_denom,80))
        i_ii = ids_raw.scale(alpha_ii_t).mul(sii_factor).mul(esat_ii_factor).scale(p.ii_temp2)
            .mul(vdiff.div(beta_denom.maxC(1e-15)).minC(80.0).exp());
    }

    // ---- Gate tunneling ----
    var i_gs_gate = S.con(0.0);
    var i_gd_gate = S.con(0.0);
    var i_gb_gate = S.con(0.0);
    if (p.igcmod != 0) {
        const b_gate = 2.69e10;
        // t1_gc = vgsfbeff - psi_s
        const t1_gc = vgsfb_minus_psi;
        // t_exp_gc = -b_gate*toxg*(aigc_t - bigc*t1_gc)*(1 + cigc*t1_gc)
        const t_exp_gc = t1_gc.scale(-p.bigc).addC(p.aigc_t).mul(t1_gc.scale(p.cigc).addC(1.0)).scale(-b_gate * p.toxg);
        // igc0 = igc0mult*w_eff0*l_eff*4.97232*tox_ratio*ig_temp*t1_gc*exp(min(t_exp_gc,80))*nf_total
        const igc0 = t1_gc.mul(t_exp_gc.minC(80.0).exp())
            .scale(p.igc0mult * w_eff0 * l_eff * 4.97232 * p.tox_ratio * p.ig_temp * nf_total);
        i_gs_gate = igc0.scale(0.5);
        i_gd_gate = igc0.scale(0.5);
    }
    if (p.igbmod != 0) {
        const b_gate = 2.69e10;
        // Gate-to-body inversion
        const vge_eff = vge_raw;
        const t1_gb = vge_eff;
        const vaux_inv = vge_eff.maxC(0.0);
        // t_exp_inv = -b_gate*toxg*(aigbinv_t - bigbinv*t1_gb)*(1 + cigbinv*t1_gb)
        const t_exp_inv = t1_gb.scale(-p.bigbinv).addC(p.aigbinv_t).mul(t1_gb.scale(p.cigbinv).addC(1.0)).scale(-b_gate * p.toxg);
        const igb_inv = vge_eff.mul(vaux_inv).mul(t_exp_inv.minC(80.0).exp())
            .scale(p.igb0mult * w_eff0 * l_eff * 4.97232 * p.tox_ratio * p.ig_temp * nf_total);
        // Gate-to-body accumulation
        const vaux_acc = vge_eff.neg().maxC(0.0);
        const t_exp_acc = vaux_acc.scale(p.bigbacc).addC(p.aigbacc_t).mul(vaux_acc.scale(p.cigbacc).addC(1.0)).scale(-b_gate * p.toxg);
        const igb_acc = vge_eff.neg().mul(vaux_acc).mul(t_exp_acc.minC(80.0).exp())
            .scale(p.igb0mult * w_eff0 * l_eff * 4.97232 * p.tox_ratio * p.ig_temp * nf_total);
        i_gb_gate = igb_inv.add(igb_acc);
    }

    // ---- Generation-recombination ----
    var i_gen = S.con(0.0);
    if (p.gen_on) {
        // i_gen = gen_coeff * (aigen*vdsx + bigen*vdsx^3)
        i_gen = vdsx.scale(p.aigen).add(vdsx.mul(vdsx).mul(vdsx).scale(p.bigen)).scale(p.gen_coeff);
    }

    // ---- Junction diode currents (BULKMOD=1) ----
    var i_es = S.con(0.0);
    var i_ed = S.con(0.0);
    if (p.bulkmod_on) {
        const ves = x[e].sub(x[si]).scale(type_f);
        const ved = x[e].sub(x[di]).scale(type_f);
        // i_es = isbs*(exp(arg_s) + xexpbvs - 1 - xjbvs*exp(min((-bvs+ves)/nvtms,80))) + GMIN*ves
        const arg_s = ves.scale(1.0 / p.nvtms).minC(80.0);
        const brk_s = ves.addC(-p.bvs).scale(1.0 / p.nvtms).minC(80.0).exp().scale(-p.xjbvs);
        i_es = arg_s.exp().add(brk_s).addC(p.xexpbvs - 1.0).scale(p.isbs).add(ves.scale(GMIN));
        const arg_d = ved.scale(1.0 / p.nvtmd).minC(80.0);
        const brk_d = ved.addC(-p.bvd).scale(1.0 / p.nvtmd).minC(80.0).exp().scale(-p.xjbvd);
        i_ed = arg_d.exp().add(brk_d).addC(p.xexpbvd - 1.0).scale(p.isbd).add(ved.scale(GMIN));
    }

    // ---- Series resistances ----
    const i_rd = x[d].sub(x[di]).scale(p.g_rd);
    const i_rs = x[s].sub(x[si]).scale(p.g_rs);
    const i_rg = x[g].sub(x[gi]).scale(p.g_rg);

    // ---- Self-heating ----
    var i_sh = S.con(0.0);
    if (p.shmod != 0) {
        // p_diss = ids_raw*vdsx*m_mult ; i_sh = gth*dt_sh - p_diss
        const p_diss = ids_raw.mul(vdsx).scale(p.m_mult);
        i_sh = x[dt].scale(p.gth).sub(p_diss);
    }

    // ---- KCL node stamps ----
    const mm_tf = p.m_mult * type_f;
    const ids_m = ids_raw.scale(mm_tf);
    const i_gidl_m = i_gidl.scale(mm_tf);
    const i_gisl_m = i_gisl.scale(mm_tf);
    const i_ii_m = i_ii.scale(mm_tf);
    const i_gen_m = i_gen.scale(mm_tf);
    const i_es_m = i_es.scale(mm_tf);
    const i_ed_m = i_ed.scale(mm_tf);
    const i_gs_m = i_gs_gate.scale(mm_tf);
    const i_gd_m = i_gd_gate.scale(mm_tf);
    const i_gb_m = i_gb_gate.scale(mm_tf);

    var out: [n_u]S = undefined;

    // Gate external: Rg branch
    out[g] = i_rg;
    // Drain external: Rd branch
    out[d] = i_rd;
    // Source external: Rs branch
    out[s] = i_rs;
    // Body: junctions + GIDL/GISL body contributions + impact ionization body + gate-body
    out[e] = i_es_m.add(i_ed_m).sub(i_ii_m).sub(i_gidl_m).sub(i_gisl_m).sub(i_gb_m)
        .add(x[e].sub(x[si]).scale(p.gbmin));
    // Internal drain
    out[di] = ids_m.scale(mode).add(i_gidl_m).add(i_ii_m).add(i_gen_m).add(i_ed_m).add(i_gd_m).sub(i_rd);
    // Internal source
    out[si] = ids_m.scale(-mode).add(i_gisl_m).add(i_es_m).add(i_gs_m).sub(i_rs);
    // Internal gate
    out[gi] = i_gs_m.add(i_gd_m).add(i_gb_m).neg().sub(i_rg);
    // Temperature node
    out[dt] = i_sh;

    return out;
}

// ---- Householder charge solvers (value-form) ----
// Source side: two Householder iterations with QM correction. Region select on
// vov (as the original: `if (vov > 40) -vov else -log(exp(-vov)+1)`).
inline fn solveQmSource(comptime S: type, vov: S, t5: f64, q_dep: f64, qmfactor: f64) S {
    var qm_norm = if (vov.val() > 40.0) vov.neg() else vov.neg().exp().addC(1.0).maxC(1e-30).log().neg();
    inline for (0..2) |_| {
        // e0 = -vov + qm - log(-qm) - log(t5) - qmfactor*exp((2/3)*log(-(qm+q_dep)))
        const neg_qm = qm_norm.neg().maxC(1e-30);
        const neg_qmq = qm_norm.addC(q_dep).neg().maxC(1e-30);
        const e0 = vov.neg().add(qm_norm).sub(neg_qm.log()).addC(-contract.fmath.log(@max(t5, 1e-30)))
            .sub(neg_qmq.log().scale(2.0 / 3.0).exp().scale(qmfactor));
        // e1 = -1 + 1/min(qm,-1e-30) - (2/3)*qmfactor*exp((-1/3)*log(-(qm+q_dep)))
        const e1 = qm_norm.minC(-1e-30).pow(-1.0).addC(-1.0)
            .sub(neg_qmq.log().scale(-1.0 / 3.0).exp().scale((2.0 / 3.0) * qmfactor));
        // e2 = -1/max(qm^2,1e-30) + (2/9)*qmfactor*exp((-4/3)*log(-(qm+q_dep)))
        const e2 = qm_norm.mul(qm_norm).maxC(1e-30).pow(-1.0).neg()
            .add(neg_qmq.log().scale(-4.0 / 3.0).exp().scale((2.0 / 9.0) * qmfactor));
        // correction = e0/max(|e1|,1e-15) * (1 + e2*e0/(2*e1*e1))
        const correction = e0.div(e1.abs().maxC(1e-15)).mul(e2.mul(e0).div(e1.mul(e1).scale(2.0)).addC(1.0));
        qm_norm = if (e1.val() > 0) qm_norm.sub(correction) else qm_norm.add(correction);
    }
    return qm_norm;
}

// Drain side: single Householder iteration (no e2), matching original.
inline fn solveQmDrain(comptime S: type, vov_d: S, t5: f64, q_dep: f64, qmfactor: f64) S {
    var qm_d = if (vov_d.val() > 40.0) vov_d.neg() else vov_d.neg().exp().addC(1.0).maxC(1e-30).log().neg();
    {
        const neg_qm = qm_d.neg().maxC(1e-30);
        const neg_qmq = qm_d.addC(q_dep).neg().maxC(1e-30);
        const e0 = vov_d.neg().add(qm_d).sub(neg_qm.log()).addC(-contract.fmath.log(@max(t5, 1e-30)))
            .sub(neg_qmq.log().scale(2.0 / 3.0).exp().scale(qmfactor));
        const e1 = qm_d.minC(-1e-30).pow(-1.0).addC(-1.0)
            .sub(neg_qmq.log().scale(-1.0 / 3.0).exp().scale((2.0 / 3.0) * qmfactor));
        const correction = e0.div(e1.abs().maxC(1e-15));
        qm_d = if (e1.val() > 0) qm_d.sub(correction) else qm_d.add(correction);
    }
    return qm_d;
}

// Vdsat: reproduces the original rds_val==0 vs rds_val!=0 branch (a topology-
// level, x-independent choice on rds_val, so plain `if`).
inline fn computeVdsat(comptime S: type, p: EvalPrep, esat_l: S, vgs_minus_psi: S, w_eff0: f64, vt: f64) S {
    _ = vt;
    if (p.rds_val == 0.0) {
        // esat_l*ksativ*vgs_minus_psi / max(esat_l + ksativ*vgs_minus_psi, 1e-15)
        const num = esat_l.mul(vgs_minus_psi).scale(p.ksativ);
        const den = esat_l.add(vgs_minus_psi.scale(p.ksativ)).maxC(1e-15);
        return num.div(den);
    } else {
        // t_a = 2*w_eff0*vsat_t*c_ox*rds_val (f64)
        const t_a = 2.0 * w_eff0 * p.vsat_t * p.c_ox * p.rds_val;
        // t_b = esat_l + vgs_minus_psi*ksativ + t_a*vgs_minus_psi (S)
        const t_b = esat_l.add(vgs_minus_psi.scale(p.ksativ)).add(vgs_minus_psi.scale(t_a));
        // t_c = esat_l*vgs_minus_psi*ksativ (S)
        const t_c = esat_l.mul(vgs_minus_psi).scale(p.ksativ);
        // disc = max(t_b^2 - 2*t_a*t_c, 0)
        const disc = t_b.mul(t_b).sub(t_c.scale(2.0 * t_a)).maxC(0.0);
        if (t_a > 1e-30) {
            return t_b.sub(disc.sqrt()).scale(1.0 / t_a);
        } else {
            const num = esat_l.mul(vgs_minus_psi).scale(p.ksativ);
            const den = esat_l.add(vgs_minus_psi.scale(p.ksativ)).maxC(1e-15);
            return num.div(den);
        }
    }
}

// ============================================================================
// x-independent charge prep (all f64).
// ============================================================================

const QPrep = struct {
    type_f: f64,
    m_mult: f64,
    nf_total: f64,
    tfin_i: f64,
    c_ox: f64,
    vt: f64,
    nvtm: f64,
    n_ss_base: f64,
    cdsc_slope: f64,
    t5: f64,
    dphi: f64,
    dvth_all_base: f64,
    theta_dibl: f64,
    eta0cv: f64,
    eta1: f64,
    dvtp0: f64,
    dvtp1: f64,
    dvtshift: f64,
    phin: f64,
    dvt_qm: f64,
    qmfactor: f64,
    l_eff_cv: f64,
    w_eff_cv0: f64,
    esat_cv: f64,
    deltavsatcv: f64,
    psatcv: f64,
    pclmcv: f64,
    bulkmod_on: bool,
    // overlap caps
    cgso: f64, cgdo: f64, cgsl: f64, cgdl: f64,
    ckappas: f64, ckappad: f64, cgbo: f64,
    cfs: f64, cfd: f64, cdsp: f64,
    vfbsdcv: f64,
    w_eff0: f64,
    // junction caps
    cjs_t: f64, cjd_t: f64, cjsws_t: f64, cjswd_t: f64, cjswgs_t: f64, cjswgd_t: f64,
    pbs_t: f64, pbd_t: f64, pbsws_t: f64, pbswd_t: f64, pbswgs_t: f64, pbswgd_t: f64,
    mjs: f64, mjd: f64, mjsws: f64, mjswd: f64, mjswgs: f64, mjswgd: f64,
    asej: f64, adej: f64, psej: f64, pdej: f64,
    // self-heating
    shmod: i32,
    cth: f64,
};

fn prepQ(model: *const Model, instance: *const Instance, dt_sh: f64) QPrep {
    const type_f: f64 = @floatFromInt(model.type_);
    const eot: f64 = @as(f64, model.eot);
    const epsrox: f64 = @as(f64, model.epsrox);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const nbody: f64 = @as(f64, model.nbody);
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const ni0sub: f64 = @as(f64, model.ni0sub);
    const easub: f64 = @as(f64, model.easub);
    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);
    const phig_m: f64 = @as(f64, model.phig);
    const deltaw: f64 = @as(f64, model.deltaw);
    const deltawcv: f64 = @as(f64, model.deltawcv);
    const qmfactor: f64 = @as(f64, model.qmfactor);
    const phin: f64 = @as(f64, model.phin);
    const dvtshift: f64 = @as(f64, model.dvtshift);
    const delvtrand: f64 = @as(f64, model.delvtrand);

    const l_drawn: f64 = @as(f64, instance.l);
    const xl_v: f64 = @as(f64, instance.xl);
    const tfin_i: f64 = @as(f64, instance.tfin);
    const hfin_i: f64 = @as(f64, instance.hfin);
    const nfin_f: f64 = @as(f64, instance.nfin);
    const nf_f: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const nf_total = nfin_f * nf_f;

    const c_ox = 3.9 * EPS_0 / eot;

    const l_xl = l_drawn + xl_v;
    const dlcv = @as(f64, model.dlc) + @as(f64, model.llc) / @max(contract.fmath.exp(@as(f64, model.lln) * contract.fmath.log(@max(l_xl, 1e-30))), 1e-30);
    const l_eff_cv = @max(l_xl - 2.0 * dlcv, 1e-9);

    const w_eff_ufcm: f64 = switch (model.geomod) {
        0 => 2.0 * hfin_i,
        1 => 2.0 * hfin_i + tfin_i,
        2 => 2.0 * hfin_i + 2.0 * tfin_i,
        3 => PI * @as(f64, instance.d_cyl),
        6 => hfin_i,
        else => 2.0 * hfin_i + tfin_i,
    };
    const w_eff_cv0 = @max(w_eff_ufcm - deltawcv, 1e-12);
    const w_eff0 = @max(w_eff_ufcm - deltaw, 1e-12);

    const tnom_k = @as(f64, model.tnom) + 273.15;
    const t_dev = @as(f64, instance.temp) + @as(f64, model.dtemp) + @as(f64, instance.dtemp);
    const t_eff = t_dev + dt_sh;
    const vt = K_BOLTZ * t_eff / Q_ELEM;
    const dt_temp = t_eff - tnom_k;

    const eg = bg0sub - tbgasub * t_eff * t_eff / (t_eff + tbgbsub);
    const ni = ni0sub * contract.fmath.exp(0.5 * contract.fmath.log(@max(t_eff / 300.15, 1e-30)) * 3.0) *
        contract.fmath.exp(@min(bg0sub * Q_ELEM / (2.0 * K_BOLTZ * 300.15) - eg * Q_ELEM / (2.0 * K_BOLTZ * t_eff), 80.0));

    const lint: f64 = @as(f64, model.lint);
    const ll: f64 = @as(f64, model.ll);
    const lln: f64 = @as(f64, model.lln);
    const dl = lint + ll / @max(contract.fmath.exp(lln * contract.fmath.log(@max(l_xl, 1e-30))), 1e-30);
    const l_eff = @max(l_xl - 2.0 * dl, 1e-9);

    const phi_sub = easub + eg / 2.0 + vt * contract.fmath.log(@max(nbody / ni, 1.0));
    const dphi = phig_m - phi_sub;

    const a_ch: f64 = switch (model.geomod) {
        3 => PI * @as(f64, instance.d_cyl) * @as(f64, instance.d_cyl) / 4.0,
        else => hfin_i * tfin_i,
    };
    const c_ins: f64 = switch (model.geomod) {
        3 => 2.0 * PI * epsrox * EPS_0 / contract.fmath.log(@max(1.0 + 2.0 * eot / @as(f64, instance.d_cyl), 1.001)),
        else => w_eff_ufcm * epsrox * EPS_0 / eot,
    };
    const scl = @sqrt(@max(epsrsub * EPS_0 * a_ch / c_ins * (1.0 + a_ch * c_ins / (2.0 * epsrsub * EPS_0 * w_eff_ufcm * w_eff_ufcm)), 1e-30));

    const dvt0: f64 = @as(f64, model.dvt0);
    const dvt1: f64 = @as(f64, model.dvt1);
    const dvt1ss: f64 = @as(f64, model.dvt1ss);
    const dsub: f64 = @as(f64, model.dsub);
    const eta0cv: f64 = @as(f64, model.eta0cv);
    const eta1: f64 = @as(f64, model.eta1);
    const dvtp0: f64 = @as(f64, model.dvtp0);
    const dvtp1: f64 = @as(f64, model.dvtp1);
    const k1rsce: f64 = @as(f64, model.k1rsce);
    const lpe0: f64 = @as(f64, model.lpe0);
    const phibe: f64 = @as(f64, model.phibe);
    const cit: f64 = @as(f64, model.cit);
    const cdsc_m: f64 = @as(f64, model.cdsc);
    const cdscd_m: f64 = @as(f64, model.cdscd);
    const kt1: f64 = @as(f64, model.kt1);
    const kt1l: f64 = @as(f64, model.kt1l);

    const vbi = vt * contract.fmath.log(@max(@as(f64, model.nsd) * nbody / (ni * ni), 1.0));
    const psi_st = phibe;

    const theta_sce = -0.5 / @max(cosh_approx(dvt1 * l_eff / scl) - 1.0, 1e-10);
    const theta_sw = 0.5 / @max(cosh_approx(dvt1ss * l_eff / scl) - 1.0, 1e-10);
    const theta_dibl = -0.5 / @max(cosh_approx(dsub * l_eff / scl) - 1.0, 1e-10);

    const c_si = epsrsub * EPS_0 / tfin_i;
    const cox_csi = (2.0 * c_si * c_ox) / @max(2.0 * c_si + c_ox, 1e-30);
    const n_ss_base = @max(1.0 + (cit + theta_sw * cdsc_m) / cox_csi, 1.0);
    const cdsc_slope = theta_sw * cdscd_m / cox_csi;

    const dvth_sce = theta_sce * dvt0 * (vbi - psi_st);
    const dvth_rsce = k1rsce * (@sqrt(@max(1.0 + lpe0 / l_eff, 0.0)) - 1.0) * psi_st;
    const dvth_temp = (kt1 + kt1l / l_eff) * (t_eff / tnom_k - 1.0);
    const dvth_all_base = dvth_sce + dvth_rsce + dvth_temp + delvtrand;

    const dvt_qm: f64 = if (qmfactor != 0.0 and @as(f64, model.qmtcencv) != 0.0)
        @as(f64, model.qmtcencv) * HBAR * HBAR * PI * PI / (2.0 * M_ELEC * tfin_i * tfin_i * Q_ELEM)
    else if (qmfactor != 0.0)
        qmfactor * HBAR * HBAR * PI * PI / (2.0 * M_ELEC * tfin_i * tfin_i * Q_ELEM)
    else
        0.0;

    // t5 = c_ox*nvtm/(Q*ni*eps_sub*nvtm) = c_ox/(Q*ni*eps_sub). f64.
    const t5_const = c_ox / (Q_ELEM * ni * epsrsub * EPS_0);

    // VSATCV
    const vsatcv: f64 = @as(f64, model.vsatcv) * (1.0 - @as(f64, model.atcv) * dt_temp);
    const mu0cv: f64 = @as(f64, model.u0cv);
    const esat_cv = 2.0 * vsatcv / @max(mu0cv, 1e-30);
    const deltavsatcv: f64 = @as(f64, model.deltavsatcv);
    const psatcv: f64 = @as(f64, model.psatcv);
    const pclmcv: f64 = @as(f64, model.pclmcv);

    // Junction cap temp-adjusted
    const cjs: f64 = @as(f64, model.cjs);
    const cjd: f64 = @as(f64, model.cjd);
    const cjsws: f64 = @as(f64, model.cjsws);
    const cjswd: f64 = @as(f64, model.cjswd);
    const cjswgs: f64 = @as(f64, model.cjswgs);
    const cjswgd: f64 = @as(f64, model.cjswgd);
    const cjs_t = cjs * (1.0 + @as(f64, model.tcj) * dt_temp);
    const cjd_t = cjd * (1.0 + @as(f64, model.tcj) * dt_temp);
    const cjsws_t = cjsws * (1.0 + @as(f64, model.tcjsw) * dt_temp);
    const cjswd_t = cjswd * (1.0 + @as(f64, model.tcjsw) * dt_temp);
    const cjswgs_t = cjswgs * (1.0 + @as(f64, model.tcjswg) * dt_temp);
    const cjswgd_t = cjswgd * (1.0 + @as(f64, model.tcjswg) * dt_temp);
    const pbs_t = @as(f64, model.pbs) - @as(f64, model.tpb) * dt_temp;
    const pbd_t = @as(f64, model.pbd) - @as(f64, model.tpb) * dt_temp;
    const pbsws_t = @as(f64, model.pbsws) - @as(f64, model.tpbsw) * dt_temp;
    const pbswd_t = @as(f64, model.pbswd) - @as(f64, model.tpbsw) * dt_temp;
    const pbswgs_t = @as(f64, model.pbswgs) - @as(f64, model.tpbswg) * dt_temp;
    const pbswgd_t = @as(f64, model.pbswgd) - @as(f64, model.tpbswg) * dt_temp;

    const asej: f64 = @as(f64, instance.asej);
    const adej: f64 = @as(f64, instance.adej);
    const psej: f64 = @as(f64, instance.psej);
    const pdej: f64 = @as(f64, instance.pdej);

    // Self-heating thermal capacitance
    var cth: f64 = 0.0;
    if (model.shmod != 0) {
        const fpitch: f64 = @as(f64, model.fpitch);
        const cth0: f64 = @as(f64, model.cth0);
        const wth0: f64 = @as(f64, model.wth0);
        const bshexp: f64 = @as(f64, model.bshexp);
        const ashexp: f64 = @as(f64, model.ashexp);
        const ash: f64 = @as(f64, model.ash);
        cth = cth0 * (wth0 * contract.fmath.exp(bshexp * contract.fmath.log(@max(nf_f, 1.0))) + ash * fpitch * contract.fmath.exp(ashexp * contract.fmath.log(@max(nf_total, 1.0))));
    }

    return .{
        .type_f = type_f,
        .m_mult = m_mult,
        .nf_total = nf_total,
        .tfin_i = tfin_i,
        .c_ox = c_ox,
        .vt = vt,
        .nvtm = n_ss_base * vt,
        .n_ss_base = n_ss_base,
        .cdsc_slope = cdsc_slope,
        .t5 = t5_const,
        .dphi = dphi,
        .dvth_all_base = dvth_all_base,
        .theta_dibl = theta_dibl,
        .eta0cv = eta0cv,
        .eta1 = eta1,
        .dvtp0 = dvtp0,
        .dvtp1 = dvtp1,
        .dvtshift = dvtshift,
        .phin = phin,
        .dvt_qm = dvt_qm,
        .qmfactor = qmfactor,
        .l_eff_cv = l_eff_cv,
        .w_eff_cv0 = w_eff_cv0,
        .esat_cv = esat_cv,
        .deltavsatcv = deltavsatcv,
        .psatcv = psatcv,
        .pclmcv = pclmcv,
        .bulkmod_on = model.bulkmod != 0,
        .cgso = @as(f64, model.cgso),
        .cgdo = @as(f64, model.cgdo),
        .cgsl = @as(f64, model.cgsl),
        .cgdl = @as(f64, model.cgdl),
        .ckappas = @as(f64, model.ckappas),
        .ckappad = @as(f64, model.ckappad),
        .cgbo = @as(f64, model.cgbo),
        .cfs = @as(f64, model.cfs),
        .cfd = @as(f64, model.cfd),
        .cdsp = @as(f64, model.cdsp),
        .vfbsdcv = @as(f64, model.vfbsdcv),
        .w_eff0 = w_eff0,
        .cjs_t = cjs_t, .cjd_t = cjd_t, .cjsws_t = cjsws_t, .cjswd_t = cjswd_t, .cjswgs_t = cjswgs_t, .cjswgd_t = cjswgd_t,
        .pbs_t = pbs_t, .pbd_t = pbd_t, .pbsws_t = pbsws_t, .pbswd_t = pbswd_t, .pbswgs_t = pbswgs_t, .pbswgd_t = pbswgd_t,
        .mjs = @as(f64, model.mjs), .mjd = @as(f64, model.mjd),
        .mjsws = @as(f64, model.mjsws), .mjswd = @as(f64, model.mjswd),
        .mjswgs = @as(f64, model.mjswgs), .mjswgd = @as(f64, model.mjswgd),
        .asej = asej, .adej = adej, .psej = psej, .pdej = pdej,
        .shmod = model.shmod,
        .cth = cth,
    };
}

// Single Householder iteration for CV surface potential (no QM correction),
// matching the original q() code.
inline fn solveQmCV(comptime S: type, vov: S, t5: f64) S {
    var qm = if (vov.val() > 40.0) vov.neg() else vov.neg().exp().addC(1.0).maxC(1e-30).log().neg();
    {
        const e0 = vov.neg().add(qm).sub(qm.neg().maxC(1e-30).log()).addC(-contract.fmath.log(@max(t5, 1e-30)));
        const e1 = qm.minC(-1e-30).pow(-1.0).addC(-1.0);
        const correction = e0.div(e1.abs().maxC(1e-15));
        qm = if (e1.val() > 0) qm.sub(correction) else qm.add(correction);
    }
    return qm;
}

// ============================================================================
// Charge Function (value-form) -- Intrinsic + Overlap + Junction + Self-Heating
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = t;

    const g = @intFromEnum(U.gate);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);
    const e = @intFromEnum(U.body);
    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);
    const gi = @intFromEnum(U.gi);
    const dt = @intFromEnum(U.dt);

    const dt_sh: f64 = if (model.shmod != 0) x[dt].val() else 0.0;
    const p = prepQ(model, instance, dt_sh);

    const type_f = p.type_f;
    const vt = p.vt;
    const c_ox = p.c_ox;

    // Terminal voltages
    const vgs_raw = x[gi].sub(x[si]).scale(type_f);
    const vds_raw = x[di].sub(x[si]).scale(type_f);
    const vbs_raw = x[e].sub(x[si]).scale(type_f);
    _ = vbs_raw;

    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs_eff = vgs_raw.sub(vds_neg);
    const vdsx = vds_abs;
    const mode_q: f64 = vds_raw.val() / (vds_abs.val() + 1e-30);

    // Subthreshold slope (Vds-dependent)
    const n_ss = vdsx.scale(p.cdsc_slope).addC(p.n_ss_base).maxC(1.0);
    const nvtm = n_ss.scale(vt);

    // Vth shifts
    const dvth_dibl = vdsx.addC(0.01).maxC(0.0).sqrt().scale(p.eta1).add(vdsx).scale(p.eta0cv).scale(p.theta_dibl);
    const dvth_dits = if (p.dvtp0 != 0.0)
        vdsx.addC(0.01).maxC(1e-30).log().scale(p.dvtp1).exp().scale(p.theta_dibl * p.dvtp0)
    else
        S.con(0.0);
    const dvth_all = dvth_dibl.add(dvth_dits).addC(p.dvth_all_base);

    const vgsfb = vgs_eff.sub(dvth_all).addC(-(p.dphi + p.dvtshift + p.phin));
    const vgsfbeff = vgsfb.addC(-p.dvt_qm);

    // Surface potential source side
    const t5 = p.t5;
    const vov = vgsfbeff.div(nvtm);
    const qm_norm = solveQmCV(S, vov, t5);
    const qis = qm_norm.neg().mul(nvtm);

    // Drain side
    const vov_d = vgsfbeff.sub(vdsx).div(nvtm);
    const qm_d = solveQmCV(S, vov_d, t5);
    const qid = qm_d.neg().mul(nvtm);
    const dqi_cv = qis.sub(qid);
    const qia_cv = qis.add(qid).scale(0.5);

    // d_vsat_cv
    // num = 1 + exp(psatcv*log(deltavsatcv + dqi_cv/(esat_cv*l_eff_cv)))
    const d_vsat_cv_num = dqi_cv.div(S.con(@max(p.esat_cv * p.l_eff_cv, 1e-15))).addC(p.deltavsatcv).maxC(1e-30)
        .log().scale(p.psatcv).exp().addC(1.0);
    const d_vsat_cv_den = 1.0 + contract.fmath.exp(p.psatcv * contract.fmath.log(@max(p.deltavsatcv, 1e-30)));
    const d_vsat_cv = d_vsat_cv_num.scale(1.0 / d_vsat_cv_den);

    // Terminal charges (Ward-Dutton partition)
    // t11 = (2*qia_cv + nvtm)/d_vsat_cv
    const t11 = qia_cv.scale(2.0).add(nvtm).div(d_vsat_cv);
    // q_g_norm = qia_cv + dqi_cv^2/(6*t11)
    const q_g_norm = qia_cv.add(dqi_cv.mul(dqi_cv).div(t11.scale(6.0).maxC(1e-30)));
    // q_d_norm = 0.5*(qia_cv - dqi_cv/6*(1 - dqi_cv/t11*(1 + dqi_cv/(5*t11))))
    const inner = dqi_cv.div(t11.scale(5.0).maxC(1e-30)).addC(1.0);
    const mid = dqi_cv.div(t11.maxC(1e-30)).mul(inner).neg().addC(1.0);
    const q_d_norm = qia_cv.sub(dqi_cv.scale(1.0 / 6.0).mul(mid)).scale(0.5);

    // CLM correction for CV
    const c_clm_cv = @max(p.pclmcv, 1e-15);
    // m_clm_cv = 1 + (1/c_clm_cv)*log(max(1 + max(vdsx-dqi_cv,0)/max(qia_cv+esat_cv*l_eff_cv,1e-15)*c_clm_cv, 1.0))
    const clm_num = vdsx.sub(dqi_cv).maxC(0.0);
    const clm_den = qia_cv.addC(p.esat_cv * p.l_eff_cv).maxC(1e-15);
    const m_clm_cv = clm_num.div(clm_den).scale(c_clm_cv).addC(1.0).maxC(1.0).log().scale(1.0 / c_clm_cv).addC(1.0);

    // q_g_corr = q_g_norm/m_clm_cv + (m_clm_cv - 1)*qid
    const q_g_corr = q_g_norm.div(m_clm_cv).add(m_clm_cv.addC(-1.0).mul(qid));
    const q_s_norm = q_g_corr.neg().sub(q_d_norm);

    // Scale to physical charges
    const q_scale = p.nf_total * c_ox * p.w_eff_cv0 * p.l_eff_cv * p.m_mult;
    const q_gi = q_g_corr.scale(q_scale);
    const q_di_intrinsic = q_d_norm.scale(q_scale);
    const q_si_intrinsic = q_s_norm.scale(q_scale);

    // Mode-aware mapping (region select on mode_q, f64)
    const q_di_mapped = if (mode_q >= 0.0) q_di_intrinsic else q_si_intrinsic;
    const q_si_mapped = if (mode_q >= 0.0) q_si_intrinsic else q_di_intrinsic;

    // ---- Overlap capacitance charges ----
    const vgs_ov = x[g].sub(x[s]);
    const vgd_ov = x[g].sub(x[d]);
    const vgb_ov = x[g].sub(x[e]);

    const delta1: f64 = 0.02;
    // Source overlap
    const vgs_vfb_s = vgs_ov.addC(-p.vfbsdcv);
    const vgs_ov_sq = vgs_vfb_s.addC(delta1);
    // vgs_overlap = 0.5*(vgs_vfb_s + delta1 - sqrt(vgs_ov_sq^2 + 4*delta1))
    const vgs_overlap = vgs_vfb_s.addC(delta1).sub(vgs_ov_sq.mul(vgs_ov_sq).addC(4.0 * delta1).maxC(0.0).sqrt()).scale(0.5);
    // ckap_s_term = if ckappas>1e-15: -ckappas*0.5*(sqrt(1 - 4*vgs_overlap/ckappas) - 1)
    const ckap_s_term = if (p.ckappas > 1e-15)
        vgs_overlap.scale(-4.0 / p.ckappas).addC(1.0).maxC(1e-30).sqrt().addC(-1.0).scale(-p.ckappas * 0.5)
    else
        S.con(0.0);
    // q_gs_ov = (cgso*vgs_ov + cgsl*(vgs_ov - vfbsdcv - vgs_overlap + ckap_s_term))*w_eff_cv0*nf_total*m_mult
    const q_gs_ov = vgs_ov.scale(p.cgso)
        .add(vgs_ov.addC(-p.vfbsdcv).sub(vgs_overlap).add(ckap_s_term).scale(p.cgsl))
        .scale(p.w_eff_cv0 * p.nf_total * p.m_mult);
    const q_gs_fringe = vgs_ov.scale(p.cfs * p.w_eff0 * p.nf_total * p.m_mult);

    // Drain overlap
    const vgd_vfb_d = vgd_ov.addC(-p.vfbsdcv);
    const vgd_ov_sq = vgd_vfb_d.addC(delta1);
    const vgd_overlap = vgd_vfb_d.addC(delta1).sub(vgd_ov_sq.mul(vgd_ov_sq).addC(4.0 * delta1).maxC(0.0).sqrt()).scale(0.5);
    const ckap_d_term = if (p.ckappad > 1e-15)
        vgd_overlap.scale(-4.0 / p.ckappad).addC(1.0).maxC(1e-30).sqrt().addC(-1.0).scale(-p.ckappad * 0.5)
    else
        S.con(0.0);
    const q_gd_ov = vgd_ov.scale(p.cgdo)
        .add(vgd_ov.addC(-p.vfbsdcv).sub(vgd_overlap).add(ckap_d_term).scale(p.cgdl))
        .scale(p.w_eff_cv0 * p.nf_total * p.m_mult);
    const q_gd_fringe = vgd_ov.scale(p.cfd * p.w_eff0 * p.nf_total * p.m_mult);

    // Gate-body overlap
    const q_gb_ov = vgb_ov.scale(p.cgbo * 2.0 * p.l_eff_cv * p.nf_total * p.m_mult);

    // Drain-source fringe
    const q_ds_fringe = x[d].sub(x[s]).scale(p.cdsp * p.nf_total * p.m_mult);

    // ---- Junction depletion charges (BULKMOD=1) ----
    var q_es_junc = S.con(0.0);
    var q_ed_junc = S.con(0.0);
    if (p.bulkmod_on) {
        const ves = x[e].sub(x[si]).scale(type_f);
        const ved = x[e].sub(x[di]).scale(type_f);
        const fc_junc: f64 = 0.5;

        const czbs = p.cjs_t * p.asej;
        const czbs_sw = p.cjsws_t * p.psej;
        const czbs_swg = p.cjswgs_t * p.tfin_i * p.nf_total;
        q_es_junc = junc_charge(S, ves, czbs, p.pbs_t, p.mjs, fc_junc)
            .add(junc_charge(S, ves, czbs_sw, p.pbsws_t, p.mjsws, fc_junc))
            .add(junc_charge(S, ves, czbs_swg, p.pbswgs_t, p.mjswgs, fc_junc));

        const czbd = p.cjd_t * p.adej;
        const czbd_sw = p.cjswd_t * p.pdej;
        const czbd_swg = p.cjswgd_t * p.tfin_i * p.nf_total;
        q_ed_junc = junc_charge(S, ved, czbd, p.pbd_t, p.mjd, fc_junc)
            .add(junc_charge(S, ved, czbd_sw, p.pbswd_t, p.mjswd, fc_junc))
            .add(junc_charge(S, ved, czbd_swg, p.pbswgd_t, p.mjswgd, fc_junc));
    }

    // ---- Self-heating thermal capacitance ----
    var q_th = S.con(0.0);
    if (p.shmod != 0) {
        q_th = x[dt].scale(p.cth);
    }

    // ---- Charge node stamps ----
    const q_es_m = q_es_junc.scale(p.m_mult);
    const q_ed_m = q_ed_junc.scale(p.m_mult);

    var out: [n_u]S = undefined;
    out[g] = q_gs_ov.add(q_gd_ov).add(q_gb_ov).add(q_gs_fringe).add(q_gd_fringe).scale(type_f);
    out[d] = q_gd_ov.neg().sub(q_gd_fringe).add(q_ds_fringe).scale(type_f);
    out[s] = q_gs_ov.neg().sub(q_gs_fringe).sub(q_ds_fringe).scale(type_f);
    out[e] = q_gb_ov.neg().add(q_es_m).add(q_ed_m).scale(type_f);
    out[di] = q_di_mapped.sub(q_ed_m).scale(type_f);
    out[si] = q_si_mapped.sub(q_es_m).scale(type_f);
    out[gi] = q_gi.scale(type_f);
    out[dt] = q_th;

    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const gi = @intFromEnum(U.gi);
    const e = @intFromEnum(U.body);
    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);

    const type_f: f64 = @floatFromInt(model.type_);

    const temp: f64 = @as(f64, instance.temp);
    const dtemp: f64 = @as(f64, instance.dtemp) + @as(f64, model.dtemp);
    const vt: f64 = K_BOLTZ * (temp + dtemp) / Q_ELEM;

    var result = x_new;

    // ====================================================================
    // DEVfetlim -- Gate-Source Voltage Limiting
    // ====================================================================
    {
        const vto: f64 = @as(f64, model.phig) - @as(f64, model.easub) - @as(f64, model.bg0sub) / 2.0;
        const vgs_new = (x_new[gi] - x_new[si]) * type_f;
        const vgs_old = (x_old[gi] - x_old[si]) * type_f;

        const vtox = vto + 3.5;
        const vtsthi = @abs(2.0 * (vgs_old - vto)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const delta_v = vgs_new - vgs_old;

        var vgs_lim = vgs_new;

        if (vgs_old >= vto) {
            if (vgs_old >= vtox) {
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vgs_old - vtstlo);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            } else {
                if (delta_v <= 0.0) {
                    vgs_lim = @max(vgs_new, vto - 0.5);
                } else {
                    vgs_lim = @min(vgs_new, vgs_old + vtsthi);
                }
            }
        } else {
            if (delta_v <= 0.0) {
                vgs_lim = @max(vgs_new, vgs_old - vtstlo);
            } else {
                vgs_lim = @min(vgs_new, vto + 0.5);
            }
        }

        const delta_gs = (vgs_lim - vgs_new) * type_f;
        result[gi] += delta_gs;
    }

    // ====================================================================
    // DEVlimvds -- Drain-Source Voltage Limiting
    // ====================================================================
    {
        const vds_new = (result[di] - result[si]) * type_f;
        const vds_old = (x_old[di] - x_old[si]) * type_f;
        const delta_vds = vds_new - vds_old;

        var vds_lim = vds_new;

        if (vds_old >= 3.5) {
            if (delta_vds <= 0.0) {
                vds_lim = @max(vds_new, -0.5 * vds_old);
            } else {
                vds_lim = @min(vds_new, 2.0 * vds_old);
            }
        } else {
            if (vds_new > 4.0) {
                vds_lim = @min(vds_new, 4.0);
            }
        }

        const delta_ds = (vds_lim - vds_new) * type_f;
        result[di] += delta_ds;
    }

    // ====================================================================
    // DEVpnjlim -- Body-Source Junction Voltage Limiting (BULKMOD=1)
    // ====================================================================
    if (model.bulkmod != 0) {
        const is_val: f64 = @as(f64, model.jss) * @as(f64, instance.asej) + 1e-30;
        const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * is_val));

        {
            const vbs_new = (x_new[e] - result[si]) * type_f;
            const vbs_old = (x_old[e] - x_old[si]) * type_f;

            var vbs_limited = vbs_new;
            if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
                if (vbs_old > 0.0) {
                    const arg = (vbs_new - vbs_old) / vt;
                    if (arg > 0.0) {
                        vbs_limited = vbs_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1e-30)));
                    } else {
                        vbs_limited = v_crit;
                    }
                } else {
                    vbs_limited = vt * contract.fmath.log(@max(vbs_new / vt, 1e-30));
                }
            }

            const delta_bs = (vbs_limited - vbs_new) * type_f;
            result[e] += delta_bs;
        }

        // DEVpnjlim -- Body-Drain Junction
        {
            const vbd_new = (result[e] - result[di]) * type_f;
            const vbd_old = (x_old[e] - x_old[di]) * type_f;

            var vbd_limited = vbd_new;
            if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
                if (vbd_old > 0.0) {
                    const arg = (vbd_new - vbd_old) / vt;
                    if (arg > 0.0) {
                        vbd_limited = vbd_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1e-30)));
                    } else {
                        vbd_limited = v_crit;
                    }
                } else {
                    vbd_limited = vt * contract.fmath.log(@max(vbd_new / vt, 1e-30));
                }
            }

            const delta_bd = (vbd_limited - vbd_new) * type_f;
            result[di] -= delta_bd;
        }
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Ramp junction saturation currents from boosted to original
    const gmin_step: f64 = 1.0e-12;
    const jss_orig: f64 = @as(f64, model.jss);
    const jsd_orig: f64 = @as(f64, model.jsd);
    m.jss = @floatCast(jss_orig + gmin_step * (1.0 - lambda));
    m.jsd = @floatCast(jsd_orig + gmin_step * (1.0 - lambda));
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

// Terminal-voltage helper: build x[n_u] with the intrinsic nodes driven and
// externals shorted to their internal counterparts (Rg/Rd/Rs branch currents
// then vanish, isolating the intrinsic physics).
fn xWith(vg: f64, vd: f64, vs: f64, vb: f64) [n_u]f64 {
    var x = [_]f64{0} ** n_u;
    x[@intFromEnum(U.gate)] = vg;
    x[@intFromEnum(U.gi)] = vg;
    x[@intFromEnum(U.drain)] = vd;
    x[@intFromEnum(U.di)] = vd;
    x[@intFromEnum(U.source)] = vs;
    x[@intFromEnum(U.si)] = vs;
    x[@intFromEnum(U.body)] = vb;
    x[@intFromEnum(U.dt)] = 0;
    return x;
}

test "bsim_cmg: on-state drain current is finite, positive, and sunk from drain into source" {
    // Default NMOS (SOI, bulkmod=0), Vg=1, Vd=1, Vs=0, Vb=0.
    // Vgs=1 > threshold-ish, Vds=1 > 0 -> forward saturation.
    const model: Model = .{};
    const inst: Instance = .{};
    const x = xWith(1.0, 1.0, 0.0, 0.0);
    const out = contract.evalValues(Self, x, &model, &inst, 0);

    const di = @intFromEnum(U.di);
    const si = @intFromEnum(U.si);
    // Channel current dominates internal drain/source. With externals shorted to
    // internals the Rd/Rs branch currents are zero, so out[di] == +Ids_channel
    // and out[si] == -Ids_channel (KCL). Ids > 0 for NMOS in forward mode.
    try testing.expect(std.math.isFinite(out[di]));
    try testing.expect(std.math.isFinite(out[si]));
    try testing.expect(out[di] > 0.0); // current flows into di node (sunk from drain)
    // KCL: internal drain and source channel contributions are equal and opposite.
    try testing.expectApproxEqAbs(out[di], -out[si], @abs(out[di]) * 1e-9 + 1e-15);
}

test "bsim_cmg: zero Vds gives (near) zero net terminal currents" {
    // Vd=Vs=Vg=Vb=0: no bias anywhere. Every current term is 0 (dqi=0, junction
    // args=0 -> exp(0)-1=0, gate current args 0, gidl off). All stamps ~ 0.
    const model: Model = .{};
    const inst: Instance = .{};
    const x = xWith(0.0, 0.0, 0.0, 0.0);
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    inline for (0..n_u) |u| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[u], 1e-12);
    }
}

test "bsim_cmg: PMOS mirrors NMOS drain current sign" {
    // type_=-1 flips terminal voltages internally. Apply the NMOS-equivalent
    // bias (Vg=-1,Vd=-1) so the internal (typed) voltages match the NMOS case;
    // the external channel current at di should then be negative (PMOS sources
    // current out of di), i.e. opposite sign to the NMOS test.
    const nm: Model = .{};
    const pm: Model = .{ .type_ = -1 };
    const inst: Instance = .{};
    const xn = xWith(1.0, 1.0, 0.0, 0.0);
    const xp = xWith(-1.0, -1.0, 0.0, 0.0);
    const outn = contract.evalValues(Self, xn, &nm, &inst, 0);
    const outp = contract.evalValues(Self, xp, &pm, &inst, 0);
    const di = @intFromEnum(U.di);
    // Same internal physics, opposite external polarity: magnitudes match, signs flip.
    try testing.expectApproxEqAbs(outn[di], -outp[di], @abs(outn[di]) * 1e-9 + 1e-15);
    try testing.expect(outp[di] < 0.0);
}

test "bsim_cmg: charge — Vgs>0 accumulates positive gate charge, KCL sums to zero at intrinsic" {
    // With CV overlap caps zero by default and Vgs=1, the intrinsic gate charge
    // q_gi = q_g_corr * (nf_total*c_ox*w_eff_cv0*l_eff_cv). It must be positive
    // (electrons attracted -> positive gate charge for NMOS) and finite.
    const model: Model = .{};
    const inst: Instance = .{};
    const x = xWith(1.0, 0.5, 0.0, 0.0);
    const out = contract.qValues(Self, x, &model, &inst, 0);
    const gi = @intFromEnum(U.gi);
    try testing.expect(std.math.isFinite(out[gi]));
    try testing.expect(out[gi] > 0.0);

    // Total charge over all nodes must be conserved (sum ~ 0) since every charge
    // term is a difference distributed across node pairs.
    var sum: f64 = 0;
    inline for (0..n_u) |u| sum += out[u];
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "bsim_cmg: junction diode forward current (BULKMOD=1)" {
    // bulkmod=1, apply forward body-source bias. i_es = isbs*(exp(ves/nvtms)-1)+GMIN*ves.
    // With default jss=1e-4 and asej set, current must be strongly positive at ves>0.
    // Hand check (T=300.15, njs=1): nvtms = k*T/q = 1.3787e-23*300.15/1.60219e-19
    //   = 0.025829 V. ves=0.5 -> exp(0.5/0.025829)=exp(19.36)=2.56e8. Huge -> i_es large>0.
    const model: Model = .{ .bulkmod = 1 };
    const inst: Instance = .{ .asej = 1e-12 }; // small area so isbs modest
    // Body at +0.5 relative to source; keep gate/drain at source to suppress channel.
    const x = xWith(0.0, 0.0, 0.0, 0.5);
    const out = contract.evalValues(Self, x, &model, &inst, 0);
    const eidx = @intFromEnum(U.body);
    // Body node sources the forward junction current: i_body = i_es + i_ed + ... > 0.
    try testing.expect(std.math.isFinite(out[eidx]));
    try testing.expect(out[eidx] > 0.0);
}
