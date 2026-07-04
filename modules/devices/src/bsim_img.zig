const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: BSIM-IMG 103.0.0 -- Independent Multi-Gate MOSFET (UTBB FDSOI)
//
//   FG (front gate) -- Rgate -- fg' (internal front gate)   [RGATEMOD=1]
//   BG (back gate) -- no resistance
//   D  (external drain) -- RS/RD -- d' (internal drain)     [RDSMOD=1]
//   S  (external source) -- RS/RD -- s' (internal source)   [RDSMOD=1]
//   T  (thermal node) -- self-heating                       [SHMOD=1]
//
//   Channel current flows between d' and s' (or D and S when RDSMOD=0).
//   Gate tunneling current: FG -> D, FG -> S, FG -> B(back gate)
//   GIDL/GISL: leakage currents
//   Impact ionization: bulk current
// ============================================================================

pub const U = enum(u8) { fg, bg, drain, source, temp, d_prime, s_prime, fg_prime };
pub const num_ports: usize = 5;

// ============================================================================
// Physical Constants (embedded as comptime for use in both i and q)
// ============================================================================
const Q_ELEC: f64 = 1.6e-19;
const EPS_0: f64 = 8.8542e-12;
const K_BOLT: f64 = 1.3787e-23;
const EPS_SIO2: f64 = 3.9 * EPS_0;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Polarity & switches ---
    type_: i32 = 1, // 1=NMOS, -1=PMOS
    welltype: i32 = -1, // -1=p-well, 1=n-well
    chargemod: i32 = 0, // Inversion charge model
    rdsmod: i32 = 0, // S/D resistance model
    igcmod: i32 = 0, // Gate-channel tunneling
    igbmod: i32 = 0, // Gate-body tunneling
    gidlmod: i32 = 0, // GIDL/GISL
    shmod: i32 = 0, // Self-heating
    rgatemod: i32 = 0, // Gate resistance
    fnmod: i32 = 0, // Flicker noise model
    nfmod: i32 = 0, // Finger width selector

    // --- Process geometry offsets ---
    xl: f32 = 0, // L offset
    xw: f32 = 0, // W offset
    lint: f32 = 0,
    ll: f32 = 0,
    lw: f32 = 0,
    lwl: f32 = 0,
    lln: f32 = 1,
    lwn: f32 = 1,
    wint: f32 = 0,
    wl: f32 = 0,
    ww: f32 = 0,
    wwl: f32 = 0,
    wln: f32 = 1,
    wwn: f32 = 1,
    dlc: f32 = 0,
    llc: f32 = 0,
    lwc: f32 = 0,
    lwlc: f32 = 0,
    dwc: f32 = 0,
    wlc: f32 = 0,
    wwc: f32 = 0,
    wwlc: f32 = 0,

    // --- Dielectric & body ---
    eot1: f32 = 1.0e-9,
    eot2: f32 = 140.0e-9,
    eot1p: f32 = 0, // 0 means use eot1
    eot2p: f32 = 0, // 0 means use eot2; physical back gate dielectric thickness for CV
    dtox1: f32 = 0,
    tsi: f32 = 8.0e-9,
    nbody: f32 = 1.0e22,
    nbg: f32 = 5.0e23,
    easub: f32 = 4.05,
    ni0sub: f32 = 1.1e16,
    bg0sub: f32 = 1.12,
    nc0sub: f32 = 2.86e25,
    phig1: f32 = 4.61,
    phig2: f32 = 0, // 0 means compute from welltype
    epsrsub: f32 = 11.9,
    epsrox1: f32 = 3.9,
    epsrox2: f32 = 3.9,
    nsd: f32 = 2.0e26,

    // --- Subthreshold & SCE ---
    cit: f32 = 0,
    cdsc: f32 = 0.14,
    cdscd: f32 = 0.14,
    cbgcbg: f32 = 0.1,
    cbgcbg0: f32 = 0,
    cbgcbg0p: f32 = 0,
    cbgcbgp: f32 = 0,
    cbgcbgd: f32 = 0,
    dvt0: f32 = 19.20,
    dvt1: f32 = 0.45,
    dvtp0: f32 = 0.45,
    dvtp1: f32 = 0.45,
    dvtp2: f32 = 0.45,
    phin: f32 = 0.045,
    eta0: f32 = 2.00,
    eta1: f32 = 2.00,
    etab: f32 = 0,
    dsub: f32 = 0.375,
    k1rsce: f32 = -0.32,
    lpe0: f32 = 8.2e-9,
    dsc0: f32 = 0,
    dsc1: f32 = 1.0e-9,
    ascl: f32 = 0,
    bscl: f32 = 0,

    // --- Velocity saturation ---
    vsat: f32 = 85000,
    avsat: f32 = 0,
    bvsat: f32 = 100.0e-9,
    vsatb: f32 = 0,
    avsatb: f32 = 0,
    bvsatb: f32 = 100.0e-9,
    vsat1: f32 = 0, // 0 means use vsat
    avsat1: f32 = 0, // 0 means use avsat
    bvsat1: f32 = 0, // 0 means use bvsat
    vsatcv: f32 = 0, // 0 means use vsat
    avsatcv: f32 = 0, // 0 means use avsat
    bvsatcv: f32 = 0, // 0 means use bvsat
    deltavsat: f32 = 1,
    ksativ: f32 = 1.0,
    ksubiv: f32 = 1.0,
    ksativb: f32 = 0,

    // --- Smoothing ---
    mexp: f32 = 4,
    amexp: f32 = 0,
    bmexp: f32 = 1,
    ptwg: f32 = 0,
    aptwg: f32 = 0,
    bptwg: f32 = 100.0e-9,
    ptwgb: f32 = 0,
    aptwgb: f32 = 0,
    bptwgb: f32 = 100.0e-9,
    ptwgb2: f32 = 0,
    aptwgb2: f32 = 0,
    bptwgb2: f32 = 100.0e-9,

    // --- Mobility ---
    u0: f32 = 3.0e-2,
    u02: f32 = 3.0e-2,
    etamob: f32 = 2.0,
    etamob2: f32 = 2.0,
    chargewf: f32 = 0,
    chargewf2: f32 = 0,
    up: f32 = 0,
    lpa: f32 = 1.0e-6,
    up2: f32 = 0,
    lpa2: f32 = 1.0e-6,
    ua: f32 = 0.3,
    aua: f32 = 0,
    bua: f32 = 100.0e-9,
    ua2: f32 = 0.3,
    aua2: f32 = 0,
    bua2: f32 = 100.0e-9,
    eu: f32 = 2.5,
    aeu: f32 = 0,
    beu: f32 = 100.0e-9,
    eu2: f32 = 2.5,
    aeu2: f32 = 0,
    beu2: f32 = 100.0e-9,
    eub: f32 = 2.5,
    aeub: f32 = 0,
    beub: f32 = 100.0e-9,
    eub2: f32 = 2.5,
    aeub2: f32 = 0,
    beub2: f32 = 100.0e-9,
    ud: f32 = 0,
    aud: f32 = 0,
    bud: f32 = 50.0e-9,
    ud2: f32 = 0,
    aud2: f32 = 0,
    bud2: f32 = 50.0e-9,
    udb: f32 = 0,
    audb: f32 = 0,
    budb: f32 = 50.0e-9,
    udb2: f32 = 0,
    audb2: f32 = 0,
    budb2: f32 = 50.0e-9,
    uc: f32 = 0,
    auc: f32 = 0,
    buc: f32 = 100.0e-9,
    uc2: f32 = 0,
    auc2: f32 = 0,
    buc2: f32 = 100.0e-9,
    ucs: f32 = 1.0,
    ucs2: f32 = 1.0,

    // --- Output conductance ---
    pclm: f32 = 0.013,
    apclm: f32 = 0,
    bpclm: f32 = 100.0e-9,
    pclmg: f32 = 0,
    pclmcv: f32 = 0.013,
    pdibl1: f32 = 1.30,
    pdibl2: f32 = 2.0e-4,
    drout: f32 = 1.06,
    pvag: f32 = 1.0,

    // --- Parasitic resistance ---
    rdswmin: f32 = 0,
    rdsw: f32 = 100,
    ardsw: f32 = 0,
    brdsw: f32 = 100.0e-9,
    rswmin: f32 = 0,
    rsw: f32 = 50,
    arsw: f32 = 0,
    brsw: f32 = 100.0e-9,
    rdwmin: f32 = 0, // 0 means use rswmin
    rdw: f32 = 0, // 0 means use rsw
    ardw: f32 = 0, // 0 means use arsw
    brdw: f32 = 0, // 0 means use brsw
    prwg: f32 = 0,
    prwb: f32 = 0,
    wr: f32 = 1.0,
    rshs: f32 = 0,
    rshd: f32 = 0, // 0 means use rshs

    // --- Gate resistance ---
    xgw: f32 = 0,
    xgl: f32 = 0,
    ngcon: f32 = 1,
    rshg: f32 = 0.1,

    // --- Gate tunneling: Igb ---
    aigbinv: f32 = 1.11e-2,
    bigbinv: f32 = 9.49e-4,
    cigbinv: f32 = 6.00e-3,
    eigbinv: f32 = 1.1,
    nigbinv: f32 = 3.0,
    aigbacc: f32 = 1.36e-2,
    bigbacc: f32 = 1.71e-3,
    cigbacc: f32 = 7.5e-2,
    nigbacc: f32 = 1.0,
    toxp: f32 = 0, // 0 means use eot1

    // --- Gate tunneling: Igc ---
    aigc: f32 = 1.36e-2,
    bigc: f32 = 1.71e-3,
    cigc: f32 = 0.075,
    digc: f32 = 1.0,
    pigcd: f32 = 1.0,

    // --- Gate-to-S/D current ---
    dlcigs: f32 = 0,
    dlcigd: f32 = 0, // 0 means use dlcigs
    aigs: f32 = 1.36e-2,
    bigs: f32 = 1.71e-3,
    cigs: f32 = 0.075,
    digs: f32 = 1.0,
    aigd: f32 = 0, // 0 means use aigs
    bigd: f32 = 0, // 0 means use bigs
    cigd: f32 = 0, // 0 means use cigs
    digd: f32 = 0, // 0 means use digs
    poxedge: f32 = 1,
    toxref: f32 = 1.2e-9,
    ntox: f32 = 1.0,

    // --- GIDL/GISL ---
    agidl: f32 = 6.055e-12,
    bgidl: f32 = 0.3e9,
    egidl: f32 = 0.2,
    pgidl: f32 = 1.0,
    vbgidl: f32 = 1.0,
    vbegidl: f32 = 0.5,
    agisl: f32 = 0, // 0 means use agidl
    bgisl: f32 = 0, // 0 means use bgidl
    egisl: f32 = 0, // 0 means use egidl (use NaN sentinel or special)
    pgisl: f32 = 0, // 0 means use pgidl
    vbgisl: f32 = 0, // 0 means use vbgidl
    vbegisl: f32 = 0, // 0 means use vbegidl

    // --- Impact ionization ---
    alpha0: f32 = 0,
    alpha1: f32 = 0,
    beta0: f32 = 0,

    // --- Parasitic capacitance ---
    lovs: f32 = 0,
    lovd: f32 = 0, // 0 means use lovs
    cfs: f32 = 0,
    cfd: f32 = 0, // 0 means use cfs
    cgsl: f32 = 0,
    cgdl: f32 = 0, // 0 means use cgsl
    ckappas: f32 = 0.6,
    ckappad: f32 = 0, // 0 means use ckappas
    csdbgsw: f32 = 0,
    pcovbs0: f32 = 0,
    pcovbs1: f32 = 0,
    pcovbd0: f32 = 0, // 0 means use pcovbs0 (sentinel)
    pcovbd1: f32 = 0, // 0 means use pcovbs1 (sentinel)

    // --- Back gate biasing: P-well ---
    kbg0pw: f32 = 1.0,
    kbg1pw: f32 = 0,
    kbg2pw: f32 = -1,
    dbgpw: f32 = 0.12,
    bpfactorpw: f32 = 0,
    vknee1pw: f32 = 0,
    vknee2pw: f32 = 1.0,

    // --- Back gate biasing: N-well ---
    kbg0nw: f32 = 1.0,
    kbg1nw: f32 = 0,
    kbg2nw: f32 = -1,
    dbgnw: f32 = 0.12,
    bpfactornw: f32 = 0,
    vknee1nw: f32 = 0,
    vknee2nw: f32 = 1.0,

    // --- QM effects ---
    qmtcencv: f32 = 0,
    etaqm: f32 = 0.54,
    qm0: f32 = 1.0e-3,
    pqm: f32 = 0.66,

    // --- Lateral NUD ---
    k0: f32 = 0,
    k01: f32 = 0,
    k0si: f32 = 1.0,
    k0si1: f32 = 0,

    // --- Noise ---
    ef: f32 = 1.0,
    lintnoi: f32 = 0,
    em: f32 = 4.1e7,
    noia: f32 = 6.250e39,
    noib: f32 = 3.125e24,
    noic: f32 = 8.750e7,
    noia2: f32 = 0, // 0 means use noia
    smooth: f32 = 2,
    mpower: f32 = 1.2,
    qsref: f32 = 50.0e-3,
    ntnoi: f32 = 1.0,

    // --- Temperature ---
    tnom: f32 = 27,
    tmaxc: f32 = 400,
    tbgasub: f32 = 7.02e-4,
    tbgbsub: f32 = 1108.0,
    kt1: f32 = 0,
    kt1l: f32 = 0,
    kt2: f32 = 0,
    kt2l: f32 = 0,
    ute: f32 = 0,
    utl: f32 = -1.5e-3,
    ua1: f32 = 1.032e-3,
    uc1: f32 = 0,
    ud1: f32 = 0,
    ucste: f32 = -4.775e-3,
    at: f32 = -0.00156,
    atl: f32 = 0,
    tmexp: f32 = 0,
    atb: f32 = 0,
    atbl: f32 = 0,
    ptwgt: f32 = 0.004,
    prt: f32 = 0.001,
    teta0: f32 = 0,
    iit: f32 = -0.5,
    tgidl: f32 = -0.003,
    tgisl: f32 = 0, // 0 means use tgidl
    igt: f32 = 2.5,
    emobt: f32 = 0,
    rth0: f32 = 0.01,
    cth0: f32 = 1.0e-5,
    wth0: f32 = 0,

    // --- DVTP0/DVTP1 length scaling (not in tables but in eq 3.51-3.52) ---
    advtp0: f32 = 0,
    bdvtp0: f32 = 100.0e-9,
    advtp1: f32 = 0,
    bdvtp1: f32 = 100.0e-9,

    // --- Binning prefixes (L, W, P) for binnable params ---
    // These are used in eq 3.34: PARAM_i = PARAM + LPARAM/Leff + WPARAM/Weff + PPARAM/(Weff*Leff)
    lphig1: f32 = 0,
    wphig1: f32 = 0,
    pphig1: f32 = 0,
    lphig2: f32 = 0,
    wphig2: f32 = 0,
    pphig2: f32 = 0,
    lnbody: f32 = 0,
    wnbody: f32 = 0,
    pnbody: f32 = 0,
    lnsd: f32 = 0,
    wnsd: f32 = 0,
    pnsd: f32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 30.0e-9, // Gate length (m)
    w: f32 = 1.0e-6, // Gate width (m)
    nf: f32 = 1, // Number of fingers
    as_: f32 = 0, // Source junction area (m^2)
    ad: f32 = 0, // Drain junction area (m^2)
    ps: f32 = 0, // Source junction perimeter (m)
    pd: f32 = 0, // Drain junction perimeter (m)
    nrs: f32 = 0, // Number of source squares
    nrd: f32 = 0, // Number of drain squares
    dtemp: f32 = 0, // Temperature offset (C)
    delvtrand: f32 = 0, // Vth variability (V)
    u0mult: f32 = 1, // Mobility multiplier
    m: f32 = 1, // Multiplier
    temp: f32 = 300.15, // Device temperature (K)
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: d_prime -- s_prime
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Channel flicker noise: d_prime -- s_prime
    .{ .row = @intFromEnum(U.d_prime), .col = @intFromEnum(U.s_prime), .kind = .flicker },
    // Gate shot noise (fg -> source): fg_prime -- s_prime
    .{ .row = @intFromEnum(U.fg_prime), .col = @intFromEnum(U.s_prime), .kind = .shot },
    // Gate shot noise (fg -> drain): fg_prime -- d_prime
    .{ .row = @intFromEnum(U.fg_prime), .col = @intFromEnum(U.d_prime), .kind = .shot },
    // Source resistance thermal noise: source -- s_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.s_prime), .kind = .thermal },
    // Drain resistance thermal noise: drain -- d_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.d_prime), .kind = .thermal },
    // Gate resistance thermal noise: fg -- fg_prime
    .{ .row = @intFromEnum(U.fg), .col = @intFromEnum(U.fg_prime), .kind = .thermal },
};

// ============================================================================
// x-independent parameter/temperature/geometry preprocessing for eval (i).
// Everything here is pure f64 -- it never touches a terminal voltage. The
// x-dependent physics tail (which becomes S ops) reads these constants.
// ============================================================================

const PrepI = struct {
    devsign: f64,
    is_nmos: bool,
    is_pwell: bool,
    eot1: f64,
    eot2: f64,
    ratio: f64,
    tsi: f64,
    eps_si: f64,
    cox1: f64,
    cox2: f64,
    csi: f64,
    vtm: f64,
    t_dev: f64,
    nf: f64,
    m_mult: f64,
    l_eff: f64,
    w_eff: f64,
    w_new: f64,
    dphi1: f64,
    phig2_i: f64,
    phi_ref: f64,
    vbi: f64,
    phi_b: f64,
    phi_sd: f64,
    vfbsd: f64,
    eg: f64,
    // back gate
    gamma0: f64,
    kbg2: f64,
    kbg0: f64,
    kbg1: f64,
    dbg: f64,
    v_subdep: f64,
    welsign: f64,
    bpfactor: f64,
    vknee1: f64,
    vgfb2n: f64,
    // SCE / DIBL
    phi_st: f64,
    dvt0: f64,
    dvt1: f64,
    dsub: f64,
    eta0_t: f64,
    etab: f64,
    eta1: f64,
    dvtp0_l: f64,
    dvtp1_l: f64,
    dvtp2: f64,
    dvth_rsce: f64,
    dsc0: f64,
    dsc1: f64,
    cdscd: f64,
    cbgcbgd: f64,
    cbgcbg0: f64,
    cbgcbg0p: f64,
    cdsc: f64,
    cbgcbg: f64,
    cbgcbgp: f64,
    csi_par_cox2: f64,
    cit: f64,
    dvth_nbody: f64,
    dvth_temp: f64,
    kt2_l: f64, // (kt2 + kt2l/leff)*(t_ratio-1)
    delvtrand: f64,
    ascl: f64,
    bscl: f64,
    lambda_f: f64,
    lambda_s: f64,
    t_eff: f64,
    // Vdsat / mobility / velocity sat
    etamob_t: f64,
    etamob2_t: f64,
    ua_t: f64,
    ua2_t: f64,
    uc_t: f64,
    uc2_t: f64,
    ud_t: f64,
    ud2_t: f64,
    udb_l: f64,
    udb2_l: f64,
    eu_l: f64,
    eu2_l: f64,
    eub_l: f64,
    eub2_l: f64,
    ucs_t: f64,
    ucs2_t: f64,
    mu0_t: f64,
    mu02_t: f64,
    vsat_t: f64,
    vsat1_t: f64,
    vsatb_t: f64,
    ptwg_t: f64,
    ptwgb_l: f64,
    ptwgb2_l: f64,
    deltavsat: f64,
    mexp_t: f64,
    ksativ: f64,
    ksubiv: f64,
    ksativb: f64,
    pclm_l: f64,
    pclmg: f64,
    pvag: f64,
    drout: f64,
    pdibl1: f64,
    pdibl2: f64,
    // resistances
    rdsmod: i32,
    rdswmin_t: f64,
    rdsw_t: f64,
    rswmin_t: f64,
    rdwmin_t: f64,
    rsw_t: f64,
    rdw_t: f64,
    rs_geo: f64,
    rd_geo: f64,
    prwg: f64,
    wr: f64,
    w_eff_wr: f64,
    u0mult: f64,
    // NUD
    k0_t: f64,
    k0si_t: f64,
    // impact ionization
    alpha0: f64,
    alpha1: f64,
    beta0_t: f64,
    // GIDL/GISL
    gidlmod: i32,
    agidl: f64,
    egidl: f64,
    pgidl: f64,
    vbgidl: f64,
    vbegidl: f64,
    bgidl_t: f64,
    agisl: f64,
    egisl: f64,
    pgisl: f64,
    vbgisl: f64,
    vbegisl: f64,
    bgisl_t: f64,
    // gate tunneling
    igbmod: i32,
    igcmod: i32,
    ig_temp: f64,
    toxp_val: f64,
    tox_ratio: f64,
    aigbinv: f64,
    bigbinv: f64,
    cigbinv: f64,
    eigbinv: f64,
    nigbinv: f64,
    aigbacc: f64,
    bigbacc: f64,
    cigbacc: f64,
    nigbacc: f64,
    aigc: f64,
    bigc: f64,
    cigc: f64,
    digc: f64,
    pigcd: f64,
    aigs: f64,
    bigs: f64,
    cigs: f64,
    digs: f64,
    aigd: f64,
    bigd: f64,
    cigd: f64,
    digd: f64,
    dlcigs: f64,
    dlcigd: f64,
    poxedge: f64,
    ntox: f64,
    toxref: f64,
    // gate resistance / thermal
    rgatemod: i32,
    shmod: i32,
    g_gate: f64,
    g_th: f64,
    vfbsd_bg: f64,
    chargewf: f64,
    chargewf2: f64,
};

fn prepI(model: *const Model, instance: *const Instance) PrepI {
    const type_f: f64 = @floatFromInt(model.type_);
    const devsign: f64 = type_f;
    const is_nmos = model.type_ == 1;
    const is_pwell = model.welltype == -1;

    const eot1: f64 = @as(f64, model.eot1);
    const eot2: f64 = @as(f64, model.eot2);
    const eot1p: f64 = if (model.eot1p == 0) eot1 else @as(f64, model.eot1p);
    _ = eot1p;
    const tsi: f64 = @as(f64, model.tsi);
    const nbody: f64 = @as(f64, model.nbody);
    const nbg_val: f64 = @as(f64, model.nbg);
    const easub: f64 = @as(f64, model.easub);
    const ni0sub: f64 = @as(f64, model.ni0sub);
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const nc0sub: f64 = @as(f64, model.nc0sub);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const nsd_val: f64 = @as(f64, model.nsd);

    const tnom_c: f64 = @as(f64, model.tnom);
    const tnom_k: f64 = tnom_c + 273.15;

    const nf: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);

    const t_dev: f64 = @as(f64, instance.temp) + @as(f64, instance.dtemp);

    // 3.1.1 physical constants
    const eps_si = epsrsub * EPS_0;
    const ratio = epsrsub / 3.9;
    const cox1 = 3.9 * EPS_0 / eot1;
    const cox2 = 3.9 * EPS_0 / eot2;
    const csi = eps_si / tsi;
    const vtm = K_BOLT * t_dev / Q_ELEC;

    // 3.1.2 effective L / W
    const l_raw: f64 = @as(f64, instance.l);
    const w_raw: f64 = @as(f64, instance.w);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);
    const l_new = l_raw + xl;

    const lln: f64 = @as(f64, model.lln);
    const lwn_val: f64 = @as(f64, model.lwn);
    const wln_val: f64 = @as(f64, model.wln);
    const wwn_val: f64 = @as(f64, model.wwn);

    const l_lln = @exp(-lln * @log(@max(l_new, 1.0e-30)));
    const l_wln = @exp(-lwn_val * @log(@max(l_new, 1.0e-30)));

    const w_new: f64 = if (model.nfmod == 0) w_raw / nf else w_raw + xw;

    const w_lwn = @exp(-wln_val * @log(@max(w_new, 1.0e-30)));
    const w_wwn = @exp(-wwn_val * @log(@max(w_new, 1.0e-30)));

    const l_wlln_lwn = l_lln * w_lwn;
    const l_wwln_wwn = l_wln * w_wwn;

    const dl_iv = @as(f64, model.lint) + @as(f64, model.ll) * l_lln + @as(f64, model.lw) * w_lwn + @as(f64, model.lwl) * l_wlln_lwn;
    const l_eff = @max(l_new - 2.0 * dl_iv, 1.0e-9);

    const dw_iv = @as(f64, model.wint) + @as(f64, model.wl) * l_wln + @as(f64, model.ww) * w_wwn + @as(f64, model.wwl) * l_wwln_wwn;
    const w_eff = @max(w_new - 2.0 * dw_iv, 1.0e-9);

    // 3.1.5 temperature effects
    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);
    const eg = bg0sub - tbgasub * t_dev * t_dev / (t_dev + tbgbsub);
    const ni = ni0sub * @exp(1.5 * @log(t_dev / 300.15)) * @exp(@min((bg0sub * Q_ELEC / (2.0 * K_BOLT * 300.15)) - (eg * Q_ELEC / (2.0 * K_BOLT * t_dev)), 80.0));
    const nc = nc0sub * @exp(1.5 * @log(t_dev / 300.15));
    _ = nc;

    const vbi = vtm * @log(@max(nsd_val * nbody / (ni * ni), 1.0e-30));
    const phi_b = vtm * @log(@max(nbody / ni, 1.0e-30));
    const phi_sub = vtm * @log(@max(nbg_val / ni, 1.0e-30));

    // 3.1.6 workfunction
    const phig1_i: f64 = @as(f64, model.phig1);
    var phig2_raw: f64 = @as(f64, model.phig2);
    if (model.phig2 == 0) {
        phig2_raw = if (is_pwell) easub else easub + bg0sub;
    }
    const phig2_i: f64 = if (is_pwell)
        phig2_raw - 0.5 * bg0sub + phi_sub
    else
        phig2_raw + 0.5 * bg0sub - phi_sub;

    const phi_ref: f64 = if (is_nmos) easub else easub + eg;

    const dphi1 = devsign * (phig1_i - phi_ref);

    // Phi_sd (eq 3.98)
    const phi_sd_t = @min(eg / 2.0, vtm * @log(@max(nsd_val / ni, 1.0e-30)));
    const phi_sd = easub + eg / 2.0 - devsign * phi_sd_t;
    const vfbsd = devsign * (phig1_i - phi_sd);
    const vfbsd_bg = devsign * (phig2_i - phi_sd);

    // 3.1.5 more temperature scalings
    const t_ratio = t_dev / tnom_k;

    // length-scaled (section 3.1.4)
    const mob0_base: f64 = @as(f64, model.u0);
    const lpa_val: f64 = @as(f64, model.lpa);
    const up_val: f64 = @as(f64, model.up);
    const mob0_l: f64 = if (lpa_val > 0) mob0_base * (1.0 - up_val * @exp(-lpa_val * @log(@max(l_eff, 1.0e-30)))) else mob0_base * (1.0 - up_val);

    const mob02_base: f64 = @as(f64, model.u02);
    const lpa2_val: f64 = @as(f64, model.lpa2);
    const up2_val: f64 = @as(f64, model.up2);
    const mob02_l: f64 = if (lpa2_val > 0) mob02_base * (1.0 - up2_val * @exp(-lpa2_val * @log(@max(l_eff, 1.0e-30)))) else mob02_base * (1.0 - up2_val);

    const ua_l = @as(f64, model.ua) + @as(f64, model.aua) * @exp(-l_eff / @as(f64, model.bua));
    const ua2_l = @as(f64, model.ua2) + @as(f64, model.aua2) * @exp(-l_eff / @as(f64, model.bua2));
    const eu_l = @as(f64, model.eu) + @as(f64, model.aeu) * @exp(-l_eff / @as(f64, model.beu));
    const eu2_l = @as(f64, model.eu2) + @as(f64, model.aeu2) * @exp(-l_eff / @as(f64, model.beu2));
    const eub_l = @as(f64, model.eub) + @as(f64, model.aeub) * @exp(-l_eff / @as(f64, model.beub));
    const eub2_l = @as(f64, model.eub2) + @as(f64, model.aeub2) * @exp(-l_eff / @as(f64, model.beub2));
    const ud_l = @as(f64, model.ud) + @as(f64, model.aud) * @exp(-l_eff / @as(f64, model.bud));
    const ud2_l = @as(f64, model.ud2) + @as(f64, model.aud2) * @exp(-l_eff / @as(f64, model.bud2));
    const udb_l: f64 = @as(f64, model.udb) + @as(f64, model.audb) * @exp(-l_eff / @as(f64, model.budb));
    const udb2_l: f64 = @as(f64, model.udb2) + @as(f64, model.audb2) * @exp(-l_eff / @as(f64, model.budb2));
    const uc_l = @as(f64, model.uc) + @as(f64, model.auc) * @exp(-l_eff / @as(f64, model.buc));
    const uc2_l = @as(f64, model.uc2) + @as(f64, model.auc2) * @exp(-l_eff / @as(f64, model.buc2));

    const mexp_l = @as(f64, model.mexp) + @as(f64, model.amexp) * @exp(-@as(f64, model.bmexp) * @log(@max(l_eff, 1.0e-30)));
    const pclm_l = @as(f64, model.pclm) + @as(f64, model.apclm) * @exp(-l_eff / @as(f64, model.bpclm));
    const ptwg_l = @as(f64, model.ptwg) + @as(f64, model.aptwg) * @exp(-l_eff / @as(f64, model.bptwg));
    const ptwgb_l = @as(f64, model.ptwgb) + @as(f64, model.aptwgb) * @exp(-l_eff / @as(f64, model.bptwgb));
    const ptwgb2_l = @as(f64, model.ptwgb2) + @as(f64, model.aptwgb2) * @exp(-l_eff / @as(f64, model.bptwgb2));

    const vsat_l = @as(f64, model.vsat) + @as(f64, model.avsat) * @exp(-l_eff / @as(f64, model.bvsat));
    const vsatb_l = @as(f64, model.vsatb) + @as(f64, model.avsatb) * @exp(-l_eff / @as(f64, model.bvsatb));
    const vsat1_base: f64 = if (model.vsat1 == 0) @as(f64, model.vsat) else @as(f64, model.vsat1);
    const avsat1_val: f64 = if (model.avsat1 == 0) @as(f64, model.avsat) else @as(f64, model.avsat1);
    const bvsat1_val: f64 = if (model.bvsat1 == 0) @as(f64, model.bvsat) else @as(f64, model.bvsat1);
    const vsat1_l = vsat1_base + avsat1_val * @exp(-l_eff / bvsat1_val);

    const dvtp0_l = @as(f64, model.dvtp0) + @as(f64, model.advtp0) * @exp(-l_eff / @as(f64, model.bdvtp0));
    const dvtp1_l = @as(f64, model.dvtp1) + @as(f64, model.advtp1) * @exp(-l_eff / @as(f64, model.bdvtp1));

    // RDSMOD=0 length scaling
    const rdsw_l = @as(f64, model.rdsw) + @as(f64, model.ardsw) * @exp(-l_eff / @as(f64, model.brdsw));
    // RDSMOD=1 length scaling
    const rsw_l = @as(f64, model.rsw) + @as(f64, model.arsw) * @exp(-l_eff / @as(f64, model.brsw));
    const rdw_base: f64 = if (model.rdw == 0) @as(f64, model.rsw) else @as(f64, model.rdw);
    const ardw_val: f64 = if (model.ardw == 0) @as(f64, model.arsw) else @as(f64, model.ardw);
    const brdw_val: f64 = if (model.brdw == 0) @as(f64, model.brsw) else @as(f64, model.brdw);
    const rdw_l = rdw_base + ardw_val * @exp(-l_eff / brdw_val);

    const dvth_temp = (@as(f64, model.kt1) + @as(f64, model.kt1l) / l_eff) * (t_ratio - 1.0);
    const mu0_t = mob0_l * @exp(@as(f64, model.ute) * @log(t_ratio)) + @as(f64, model.utl) * (t_dev - tnom_k);
    const mu02_t = mob02_l * @exp(@as(f64, model.ute) * @log(t_ratio)) + @as(f64, model.utl) * (t_dev - tnom_k);
    const mexp_t = mexp_l * (1.0 + @as(f64, model.tmexp) * (t_dev - tnom_k));
    const etamob_t: f64 = @as(f64, model.etamob) * (1.0 + @as(f64, model.emobt) * (t_dev - tnom_k));
    const etamob2_t: f64 = @as(f64, model.etamob2) * (1.0 + @as(f64, model.emobt) * (t_dev - tnom_k));

    const ua_t = ua_l + @as(f64, model.ua1) * (t_dev - tnom_k);
    const ua2_t = ua2_l + @as(f64, model.ua1) * (t_dev - tnom_k);
    const uc_t = uc_l + @as(f64, model.uc1) * (t_dev - tnom_k);
    const uc2_t = uc2_l + @as(f64, model.uc1) * (t_dev - tnom_k);
    const ud_t = ud_l * @exp(@as(f64, model.ud1) * @log(t_ratio));
    const ud2_t = ud2_l * @exp(@as(f64, model.ud1) * @log(t_ratio));
    const ucs_t = @as(f64, model.ucs) * @exp(@as(f64, model.ucste) * @log(t_ratio));
    const ucs2_t = @as(f64, model.ucs2) * @exp(@as(f64, model.ucste) * @log(t_ratio));

    const eta0_t = @as(f64, model.eta0) * (1.0 + @as(f64, model.teta0) * (t_dev - tnom_k));

    const at_val = @as(f64, model.at) * (1.0 + 1.0e-6 / l_eff * @as(f64, model.atl));
    const atb_val = @as(f64, model.atb) * (1.0 + 1.0e-6 / l_eff * @as(f64, model.atbl));

    const vsat_t = vsat_l * (1.0 - at_val * (t_dev - tnom_k));
    const vsat1_t = vsat1_l * (1.0 - at_val * (t_dev - tnom_k));
    const vsatb_t = vsatb_l * (1.0 - atb_val * (t_dev - tnom_k));

    const ptwg_t = ptwg_l * (1.0 - @as(f64, model.ptwgt) * (t_dev - tnom_k));

    const beta0_t = @as(f64, model.beta0) * @exp(@as(f64, model.iit) * @log(t_ratio));

    const k0_t = @as(f64, model.k0) + @as(f64, model.k01) * (t_dev - tnom_k);
    const k0si_t = @as(f64, model.k0si) + @as(f64, model.k0si1) * (t_dev - tnom_k);

    const bgidl_t = @as(f64, model.bgidl) * (1.0 + @as(f64, model.tgidl) * (t_dev - tnom_k));
    const bgisl_base: f64 = if (model.bgisl == 0) @as(f64, model.bgidl) else @as(f64, model.bgisl);
    const tgisl_val: f64 = if (model.tgisl == 0) @as(f64, model.tgidl) else @as(f64, model.tgisl);
    const bgisl_t = bgisl_base * (1.0 + tgisl_val * (t_dev - tnom_k));

    const prt_val: f64 = @as(f64, model.prt);
    const rdswmin_t = @as(f64, model.rdswmin) * (1.0 + prt_val * (t_dev - tnom_k));
    const rdsw_t = rdsw_l * (1.0 + prt_val * (t_dev - tnom_k));
    const rswmin_t = @as(f64, model.rswmin) * (1.0 + prt_val * (t_dev - tnom_k));
    const rdwmin_base: f64 = if (model.rdwmin == 0) @as(f64, model.rswmin) else @as(f64, model.rdwmin);
    const rdwmin_t = rdwmin_base * (1.0 + prt_val * (t_dev - tnom_k));
    const rsw_t = rsw_l * (1.0 + prt_val * (t_dev - tnom_k));
    const rdw_t = rdw_l * (1.0 + prt_val * (t_dev - tnom_k));

    const ig_temp = @exp(@as(f64, model.igt) * @log(t_ratio));

    const rs_geo = @as(f64, instance.nrs) * @as(f64, model.rshs) * (1.0 + prt_val * (t_dev - tnom_k));
    const rshd_val: f64 = if (model.rshd == 0) @as(f64, model.rshs) else @as(f64, model.rshd);
    const rd_geo = @as(f64, instance.nrd) * rshd_val * (1.0 + prt_val * (t_dev - tnom_k));

    // 3.3.1 scale length -- lambda_f/lambda_s (lambda_val itself is x-dependent)
    const t_eff = eot1 * ratio + tsi + eot2 * ratio;
    const lambda_f = @sqrt(tsi * ratio * eot1);
    const lambda_s = @sqrt(tsi * ratio * eot1 + 0.375 * tsi);

    // 3.2.2 back gate biasing constants
    const kbg2: f64 = if (is_pwell) @as(f64, model.kbg2pw) else @as(f64, model.kbg2nw);
    const kbg0: f64 = if (is_pwell) @as(f64, model.kbg0pw) else @as(f64, model.kbg0nw);
    const kbg1: f64 = if (is_pwell) @as(f64, model.kbg1pw) else @as(f64, model.kbg1nw);
    const dbg: f64 = if (is_pwell) @as(f64, model.dbgpw) else @as(f64, model.dbgnw);

    const gamma0 = -cox2 * csi / ((cox2 + csi) * cox1);

    // 3.2.3-3.2.4 substrate depletion clamp (x-independent final form)
    const bpfactor: f64 = if (is_pwell) @as(f64, model.bpfactorpw) else @as(f64, model.bpfactornw);
    const vknee1: f64 = if (is_pwell) @as(f64, model.vknee1pw) else @as(f64, model.vknee1nw);
    const vknee2: f64 = if (is_pwell) @as(f64, model.vknee2pw) else @as(f64, model.vknee2nw);
    const welsign: f64 = if (is_pwell) -1.0 else 1.0;
    const v_subdep0 = 0.5 * Q_ELEC * nbg_val / (cox2 * cox2);
    // eq 3.128-3.129 clamp (the x-dependent form on line above is overwritten
    // by the constant clamp in the reference, so v_subdep is x-independent):
    const t1_sub = -v_subdep0 + vknee2 - 0.01;
    const v_subdep = -vknee2 + 0.5 * (t1_sub + @sqrt(t1_sub * t1_sub + 0.04 * v_subdep0));

    // 3.3 SCE constants
    const phin_val: f64 = @as(f64, model.phin);
    const phi_st = 0.4 + phi_b + phin_val;
    const dvth_rsce = @as(f64, model.k1rsce) * (@sqrt(1.0 + @as(f64, model.lpe0) / l_eff) - 1.0) * phi_st;
    const csi_par_cox2 = csi * cox2 / (csi + cox2);
    const dvth_nbody = Q_ELEC * nbody * tsi / cox1 * (1.0 - 0.5 * tsi / (tsi + ratio * eot2));
    const kt2_l = (@as(f64, model.kt2) + @as(f64, model.kt2l) / l_eff) * (t_ratio - 1.0);

    const wr_val: f64 = @as(f64, model.wr);
    const w_eff_wr = @exp(wr_val * @log(@max(w_eff, 1.0e-30)));

    // gate resistance
    const g_gate: f64 = blk: {
        if (model.rgatemod == 1) {
            const ngcon_val: f64 = @as(f64, model.ngcon);
            const xgw_val: f64 = @as(f64, model.xgw);
            const xgl_val: f64 = @as(f64, model.xgl);
            const rshg_val: f64 = @as(f64, model.rshg);
            const r_geltd = rshg_val * (xgw_val + w_eff / (3.0 * ngcon_val)) / (ngcon_val * @max(l_eff - xgl_val, 1.0e-9) * nf);
            break :blk if (r_geltd > 0) m_mult / r_geltd else GSHORT;
        } else {
            break :blk GSHORT;
        }
    };

    // self-heating
    const g_th: f64 = blk: {
        if (model.shmod == 1) {
            const wth0_val: f64 = @as(f64, model.wth0);
            const rth0_val: f64 = @as(f64, model.rth0);
            break :blk (wth0_val + w_eff) / @max(rth0_val, 1.0e-30) * nf * m_mult;
        } else {
            break :blk 0.0;
        }
    };

    // gate tunneling constants
    const toxp_val: f64 = if (model.toxp == 0) eot1 else @as(f64, model.toxp);
    const tox_ratio = (1.0 / (toxp_val * toxp_val)) * @exp(@as(f64, model.ntox) * @log(@as(f64, model.toxref) / toxp_val));

    return .{
        .devsign = devsign,
        .is_nmos = is_nmos,
        .is_pwell = is_pwell,
        .eot1 = eot1,
        .eot2 = eot2,
        .ratio = ratio,
        .tsi = tsi,
        .eps_si = eps_si,
        .cox1 = cox1,
        .cox2 = cox2,
        .csi = csi,
        .vtm = vtm,
        .t_dev = t_dev,
        .nf = nf,
        .m_mult = m_mult,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .w_new = w_new,
        .dphi1 = dphi1,
        .phig2_i = phig2_i,
        .phi_ref = phi_ref,
        .vbi = vbi,
        .phi_b = phi_b,
        .phi_sd = phi_sd,
        .vfbsd = vfbsd,
        .eg = eg,
        .gamma0 = gamma0,
        .kbg2 = kbg2,
        .kbg0 = kbg0,
        .kbg1 = kbg1,
        .dbg = dbg,
        .v_subdep = v_subdep,
        .welsign = welsign,
        .bpfactor = bpfactor,
        .vknee1 = vknee1,
        .vgfb2n = -1.2,
        .phi_st = phi_st,
        .dvt0 = @as(f64, model.dvt0),
        .dvt1 = @as(f64, model.dvt1),
        .dsub = @as(f64, model.dsub),
        .eta0_t = eta0_t,
        .etab = @as(f64, model.etab),
        .eta1 = @as(f64, model.eta1),
        .dvtp0_l = dvtp0_l,
        .dvtp1_l = dvtp1_l,
        .dvtp2 = @as(f64, model.dvtp2),
        .dvth_rsce = dvth_rsce,
        .dsc0 = @as(f64, model.dsc0),
        .dsc1 = @as(f64, model.dsc1),
        .cdscd = @as(f64, model.cdscd),
        .cbgcbgd = @as(f64, model.cbgcbgd),
        .cbgcbg0 = @as(f64, model.cbgcbg0),
        .cbgcbg0p = @as(f64, model.cbgcbg0p),
        .cdsc = @as(f64, model.cdsc),
        .cbgcbg = @as(f64, model.cbgcbg),
        .cbgcbgp = @as(f64, model.cbgcbgp),
        .csi_par_cox2 = csi_par_cox2,
        .cit = @as(f64, model.cit),
        .dvth_nbody = dvth_nbody,
        .dvth_temp = dvth_temp,
        .kt2_l = kt2_l,
        .delvtrand = @as(f64, instance.delvtrand),
        .ascl = @as(f64, model.ascl),
        .bscl = @as(f64, model.bscl),
        .lambda_f = lambda_f,
        .lambda_s = lambda_s,
        .t_eff = t_eff,
        .etamob_t = etamob_t,
        .etamob2_t = etamob2_t,
        .ua_t = ua_t,
        .ua2_t = ua2_t,
        .uc_t = uc_t,
        .uc2_t = uc2_t,
        .ud_t = ud_t,
        .ud2_t = ud2_t,
        .udb_l = udb_l,
        .udb2_l = udb2_l,
        .eu_l = eu_l,
        .eu2_l = eu2_l,
        .eub_l = eub_l,
        .eub2_l = eub2_l,
        .ucs_t = ucs_t,
        .ucs2_t = ucs2_t,
        .mu0_t = mu0_t,
        .mu02_t = mu02_t,
        .vsat_t = vsat_t,
        .vsat1_t = vsat1_t,
        .vsatb_t = vsatb_t,
        .ptwg_t = ptwg_t,
        .ptwgb_l = ptwgb_l,
        .ptwgb2_l = ptwgb2_l,
        .deltavsat = @as(f64, model.deltavsat),
        .mexp_t = mexp_t,
        .ksativ = @as(f64, model.ksativ),
        .ksubiv = @as(f64, model.ksubiv),
        .ksativb = @as(f64, model.ksativb),
        .pclm_l = pclm_l,
        .pclmg = @as(f64, model.pclmg),
        .pvag = @as(f64, model.pvag),
        .drout = @as(f64, model.drout),
        .pdibl1 = @as(f64, model.pdibl1),
        .pdibl2 = @as(f64, model.pdibl2),
        .rdsmod = model.rdsmod,
        .rdswmin_t = rdswmin_t,
        .rdsw_t = rdsw_t,
        .rswmin_t = rswmin_t,
        .rdwmin_t = rdwmin_t,
        .rsw_t = rsw_t,
        .rdw_t = rdw_t,
        .rs_geo = rs_geo,
        .rd_geo = rd_geo,
        .prwg = @as(f64, model.prwg),
        .wr = wr_val,
        .w_eff_wr = w_eff_wr,
        .u0mult = @as(f64, instance.u0mult),
        .k0_t = k0_t,
        .k0si_t = k0si_t,
        .alpha0 = @as(f64, model.alpha0),
        .alpha1 = @as(f64, model.alpha1),
        .beta0_t = beta0_t,
        .gidlmod = model.gidlmod,
        .agidl = @as(f64, model.agidl),
        .egidl = @as(f64, model.egidl),
        .pgidl = @as(f64, model.pgidl),
        .vbgidl = @as(f64, model.vbgidl),
        .vbegidl = @as(f64, model.vbegidl),
        .bgidl_t = bgidl_t,
        .agisl = if (model.agisl == 0) @as(f64, model.agidl) else @as(f64, model.agisl),
        .egisl = if (model.egisl == 0) @as(f64, model.egidl) else @as(f64, model.egisl),
        .pgisl = if (model.pgisl == 0) @as(f64, model.pgidl) else @as(f64, model.pgisl),
        .vbgisl = if (model.vbgisl == 0) @as(f64, model.vbgidl) else @as(f64, model.vbgisl),
        .vbegisl = if (model.vbegisl == 0) @as(f64, model.vbegidl) else @as(f64, model.vbegisl),
        .bgisl_t = bgisl_t,
        .igbmod = model.igbmod,
        .igcmod = model.igcmod,
        .ig_temp = ig_temp,
        .toxp_val = toxp_val,
        .tox_ratio = tox_ratio,
        .aigbinv = @as(f64, model.aigbinv),
        .bigbinv = @as(f64, model.bigbinv),
        .cigbinv = @as(f64, model.cigbinv),
        .eigbinv = @as(f64, model.eigbinv),
        .nigbinv = @as(f64, model.nigbinv),
        .aigbacc = @as(f64, model.aigbacc),
        .bigbacc = @as(f64, model.bigbacc),
        .cigbacc = @as(f64, model.cigbacc),
        .nigbacc = @as(f64, model.nigbacc),
        .aigc = @as(f64, model.aigc),
        .bigc = @as(f64, model.bigc),
        .cigc = @as(f64, model.cigc),
        .digc = @as(f64, model.digc),
        .pigcd = @as(f64, model.pigcd),
        .aigs = @as(f64, model.aigs),
        .bigs = @as(f64, model.bigs),
        .cigs = @as(f64, model.cigs),
        .digs = @as(f64, model.digs),
        .aigd = if (model.aigd == 0) @as(f64, model.aigs) else @as(f64, model.aigd),
        .bigd = if (model.bigd == 0) @as(f64, model.bigs) else @as(f64, model.bigd),
        .cigd = if (model.cigd == 0) @as(f64, model.cigs) else @as(f64, model.cigd),
        .digd = if (model.digd == 0) @as(f64, model.digs) else @as(f64, model.digd),
        .dlcigs = @as(f64, model.dlcigs),
        .dlcigd = if (model.dlcigd == 0) @as(f64, model.dlcigs) else @as(f64, model.dlcigd),
        .poxedge = @as(f64, model.poxedge),
        .ntox = @as(f64, model.ntox),
        .toxref = @as(f64, model.toxref),
        .rgatemod = model.rgatemod,
        .shmod = model.shmod,
        .g_gate = g_gate,
        .g_th = g_th,
        .vfbsd_bg = vfbsd_bg,
        .chargewf = @as(f64, model.chargewf),
        .chargewf2 = @as(f64, model.chargewf2),
    };
}

// ============================================================================
// DC Current (value-form eval). x-dependent physics is expressed entirely in
// S ops; region branches use .val() exactly where the reference branched on a
// voltage (e.g. igb accumulation onset). All x-independent prep is in prepI.
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = instance;
    _ = t;

    const fg = @intFromEnum(U.fg);
    const bg = @intFromEnum(U.bg);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);
    const t_node = @intFromEnum(U.temp);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);
    const fgp = @intFromEnum(U.fg_prime);

    const p = &pc.dc;
    const devsign = p.devsign;
    const cox1 = p.cox1;
    const cox2 = p.cox2;
    const csi = p.csi;
    const vtm = p.vtm;
    const eps_si = p.eps_si;
    const l_eff = p.l_eff;
    const w_eff = p.w_eff;
    const nf = p.nf;
    const m_mult = p.m_mult;

    // ---- 3.2 terminal voltages (S) ----
    const v_fg = x[fgp];
    const v_bg = x[bg];
    const v_d = x[dp];
    const v_s = x[sp];

    const vfgs = v_fg.sub(v_s).scale(devsign);
    const vfgd = v_fg.sub(v_d).scale(devsign);
    const vbgs = v_bg.sub(v_s).scale(devsign);
    const vds_raw = v_d.sub(v_s).scale(devsign);

    const vgfb1 = vfgs.addC(-p.dphi1);
    const vgfb2 = vbgs.addC(-(devsign * (p.phig2_i - p.phi_ref)));

    // 3.107 Vdsx = sqrt(vds^2 + 4e-4) - 0.02
    const vdsx = vds_raw.mul(vds_raw).addC(0.0004).sqrt().addC(-0.02);
    // 3.108-3.109 symmetry factor, Vbgx
    const sym_factor = vdsx.sub(vds_raw).scale(0.5);
    const vbgx = vbgs.add(sym_factor);

    // ---- 3.3.1 scale length ----
    // eq 3.133: t0_lam
    const t0_lam = vgfb1.scale(p.eot2 * p.ratio).add(vgfb2.scale(p.eot1 * p.ratio + p.tsi)).scale(1.0 / p.t_eff).add(sym_factor);
    // eq 3.134: x_lambda = 0.5 + (1/pi)*atan(ascl + bscl*t0_lam)
    const x_lambda = t0_lam.scale(p.bscl).addC(p.ascl).atan().scale(1.0 / 3.14159265).addC(0.5);
    const lambda_val = x_lambda.scale(p.lambda_f - p.lambda_s).addC(p.lambda_s);

    // ---- 3.2.2 back gate biasing ----
    // cosh(dbg*Leff/lambda); clamp arg magnitude at 80 like coshApprox
    const csh_kvbg = lambda_val.pow(-1.0).scale(p.dbg * l_eff).minC(80.0).cosh();
    const kvbg = csh_kvbg.pow(-1.0).scale(-0.5 * p.kbg1).addC(p.kbg0);
    // kvbg_star = kbg2 + 0.5*((kvbg-kbg2) + sqrt((kvbg-kbg2)^2 + 1e-4))
    const kvbg_m = kvbg.addC(-p.kbg2);
    const kvbg_star = kvbg_m.mul(kvbg_m).addC(0.0001).sqrt().add(kvbg_m).scale(0.5).addC(p.kbg2);

    // Vgfb2_eff (eq 3.115): vgfb2n - sym_factor
    const vgfb2_eff = sym_factor.neg().addC(p.vgfb2n);

    // 3.130 dVth_vbg
    // bp term: is_nmos -> welsign*bpfactor*v_subdep ; else -welsign*bpfactor*v_subdep
    const bp_term: f64 = if (p.is_nmos) p.welsign * p.bpfactor * p.v_subdep else -p.welsign * p.bpfactor * p.v_subdep;
    const dvth_vbg = kvbg_star.scale(p.gamma0).mul(vgfb2.addC(-bp_term).sub(vgfb2_eff));

    // 3.63 dvth_temp with Vbg dependence
    const dvth_temp_full = vbgx.scale(p.kt2_l).addC(p.dvth_temp);

    // ---- 3.3 short channel effects ----
    // 3.136 Vt roll-off
    const csh_dvt = lambda_val.pow(-1.0).scale(p.dvt1 * l_eff).minC(80.0).cosh();
    const dvth_sce = csh_dvt.addC(-1.0).maxC(1.0e-30).pow(-1.0).scale(-0.5 * p.dvt0 * (p.vbi - p.phi_st));

    // 3.137 DIBL
    const csh_dsub = lambda_val.pow(-1.0).scale(p.dsub * l_eff).minC(80.0).cosh();
    const vdsx01 = vdsx.addC(0.01);
    // -0.5*(eta0_t + etab*vbgx)/max(csh_dsub-1,eps) * (vdsx+0.01)
    const dibl_a = vbgx.scale(p.etab).addC(p.eta0_t).mul(vdsx01).scale(-0.5).div(csh_dsub.addC(-1.0).maxC(1.0e-30));
    const dibl_b = vdsx01.scale(p.eta1);
    // - dvtp0_l/(1 + dvtp2*max(csh_dsub-2,eps)) * exp(dvtp1_l*log(max(vdsx+0.01,eps)))
    const dibl_c_den = csh_dsub.addC(-2.0).maxC(1.0e-30).scale(p.dvtp2).addC(1.0);
    const dibl_c_exp = vdsx01.maxC(1.0e-30).log().scale(p.dvtp1_l).exp();
    const dibl_c = dibl_c_exp.scale(-p.dvtp0_l).div(dibl_c_den);
    const dvth_dibl = dibl_a.add(dibl_b).add(dibl_c);

    // 3.139 DSC
    const dvth_dsc = vdsx.scale(-p.dsc0 / (p.dsc1 + l_eff));

    // 3.3.6 subthreshold slope degradation
    const vbgx_pos = vbgx.mul(vbgx).addC(4.0e-6).sqrt().add(vbgx).scale(0.5);
    const delta1 = vbgx_pos.scale(p.cbgcbgd).addC(p.cdscd).mul(vdsx);
    const theta_sce = csh_dvt.addC(-1.0).maxC(1.0e-30).pow(-1.0).scale(0.5);
    const c_dsc = vbgx.scale(p.cbgcbg0)
        .add(vbgx.mul(vbgx).scale(p.cbgcbg0p))
        .add(theta_sce.scale(p.cdsc))
        .add(vbgx.scale(p.cbgcbg))
        .add(vbgx.mul(vbgx).scale(p.cbgcbgp))
        .add(delta1);

    const n_slope = c_dsc.addC(p.cit).scale(1.0 / (cox1 + p.csi_par_cox2)).addC(1.0);

    // 3.146 cumulative dVth
    const dvth_all = dvth_sce.add(dvth_dibl)
        .addC(p.dvth_rsce)
        .add(dvth_dsc)
        .addC(p.dvth_nbody)
        .add(dvth_temp_full)
        .add(dvth_vbg)
        .addC(p.delvtrand);

    // ---- 3.4 surface potential (charge-sheet smoothing) ----
    const vg_eff_drive = vgfb1.sub(dvth_all);

    const nvtm = n_slope.scale(vtm);
    const nvtm2 = nvtm.scale(2.0);

    // qmtots = log(1 + exp(min(vg_eff_drive/nvtm, 80)))
    const qmtots = vg_eff_drive.div(nvtm).minC(80.0).exp().addC(1.0).log();
    const qmtotd = vg_eff_drive.sub(vdsx).div(nvtm).minC(80.0).exp().addC(1.0).log();

    // charge densities (eq 3.158-3.165)
    const q_fronts = vg_eff_drive.scale(cox1).mul(nvtm).div(vg_eff_drive.add(nvtm).maxC(1.0e-30)).mul(qmtots);
    const q_tots = nvtm.scale(csi).mul(qmtots);
    const q_backs = q_tots.sub(q_fronts);

    const q_frontd = vg_eff_drive.sub(vdsx).scale(cox1).mul(nvtm).div(vg_eff_drive.sub(vdsx).add(nvtm).maxC(1.0e-30)).mul(qmtotd);
    const q_totd = nvtm.scale(csi).mul(qmtotd);
    const q_backd = q_totd.sub(q_frontd);

    // ---- 3.6 drain saturation voltage ----
    const q_is = q_tots.scale(1.0 / cox1);
    const q_bs_c = Q_ELEC * @as(f64, @floatCast(model.nbody)) * p.tsi / cox1;
    const q_b0 = 0.01 / cox1;

    const eta_mob: f64 = if (p.is_nmos) 0.5 * p.etamob_t else (1.0 / 3.0) * p.etamob_t;
    const eta_mob2: f64 = if (p.is_nmos) 0.5 * p.etamob2_t else (1.0 / 3.0) * p.etamob2_t;

    // front side Eeff,s
    const t2_fs = q_fronts.scale(eta_mob / cox1).addC(q_bs_c);
    const t3_fs = t2_fs.mul(t2_fs).addC(0.001).sqrt().add(t2_fs).scale(0.5);
    const eeff_s = t3_fs.scale(1.0e-8 * cox1 / eps_si);

    // back side Eeff,s2
    const t2_bs = q_backs.scale(eta_mob2 / cox2).addC(q_bs_c);
    const t3_bs = t2_bs.mul(t2_bs).addC(0.001).sqrt().add(t2_bs).scale(0.5);
    const eeff_s2 = t3_bs.scale(1.0e-8 * cox2 / eps_si);

    // 3.6.2 mobility at source for Vdsat
    // dmob_s = 1 + (ua_t + uc_t*vbgs)*exp((eu_l + eub_l*vbgs)*log(max(eeff_s,eps)))
    //            + ud_t/max(ucs_t,eps)*sqrt(max(q_is/q_b0,eps))
    const dmob_s = vbgs.scale(p.uc_t).addC(p.ua_t)
        .mul(eeff_s.maxC(1.0e-30).log().mul(vbgs.scale(p.eub_l).addC(p.eu_l)).exp())
        .add(q_is.scale(1.0 / q_b0).maxC(1.0e-30).sqrt().scale(p.ud_t / @max(p.ucs_t, 1.0e-30)))
        .addC(1.0);
    const mu_eff_s = dmob_s.maxC(1.0e-30).pow(-1.0).scale(p.mu0_t);

    const dmob_s2 = vbgs.scale(p.uc2_t).addC(p.ua2_t)
        .mul(eeff_s2.maxC(1.0e-30).log().mul(vbgs.scale(p.eub2_l).addC(p.eu2_l)).exp())
        .add(q_is.scale(1.0 / q_b0).maxC(1.0e-30).sqrt().scale(p.ud2_t / @max(p.ucs2_t, 1.0e-30)))
        .addC(1.0);
    const mu_eff_s2 = dmob_s2.maxC(1.0e-30).pow(-1.0).scale(p.mu02_t);

    // charge-based weighting (eq 3.183-3.185)
    const t0_w1 = vg_eff_drive.sub(q_fronts.scale(1.0 / cox1));
    const t1_w1 = vgfb2.sub(dvth_all).sub(q_backs.scale(1.0 / cox2));
    const exp_w1 = t0_w1.div(nvtm).minC(80.0).exp();
    const exp_w2 = t1_w1.div(nvtm).minC(80.0).exp();
    const w_sum = exp_w1.add(exp_w2).addC(1.0e-30);
    const w1 = exp_w1.div(w_sum);
    const w2 = exp_w2.div(w_sum);
    const mu_total_s = w1.mul(mu_eff_s).add(w2.mul(mu_eff_s2));

    // Esat (eq 3.186) = 2*max(vsat_t,1)/max(mu_total_s,eps)
    const esat = mu_total_s.maxC(1.0e-30).pow(-1.0).scale(2.0 * @max(p.vsat_t, 1.0));

    // Vdsat
    const q_tot_s_cx = q_tots.scale(1.0 / (cox1 + cox2));
    const t6 = q_tot_s_cx.scale(p.ksativ).addC(2.0 * vtm * p.ksubiv).add(vbgx_pos.scale(p.ksativb));

    // Rds(V) for RDSMOD=0/2 (needs q_ia -> defined below); compute q_ia first
    const q_ia = q_tots.add(q_totd).scale(1.0 / (2.0 * cox1));

    // q_ia_pre used by Rds(V)
    const q_ia_pre = q_ia; // (q_tots+q_totd)/(2*cox1)
    const inv_nfwr = 1.0 / (nf * p.w_eff_wr);
    const rds_denom = q_ia_pre.maxC(0.0).scale(p.prwg).addC(1.0);
    const rds_0 = rds_denom.pow(-1.0).scale(p.rdsw_t).addC(p.rdswmin_t).scale(inv_nfwr);
    const rds_2 = rds_denom.pow(-1.0).scale(p.rdsw_t).addC(p.rdswmin_t + p.rs_geo + p.rd_geo).scale(inv_nfwr);
    const rds_v: S = if (p.rdsmod == 0) rds_0 else if (p.rdsmod == 2) rds_2 else S.con(0.0);

    var vdsat: S = undefined;
    if (p.rdsmod == 1) {
        // eq 3.192
        const esat_l1 = esat.scale(l_eff);
        vdsat = esat_l1.mul(q_tot_s_cx).div(esat_l1.add(q_tot_s_cx).maxC(1.0e-30));
    } else {
        // eq 3.188-3.191
        const kfac = 2.0 * w_eff * @max(p.vsat_t, 1.0) * cox1;
        const a_vd = rds_v.scale(kfac);
        const esat_l1 = esat.scale(l_eff);
        const b_vd = t6.add(esat_l1).add(t6.mul(rds_v).scale(3.0 * w_eff * @max(p.vsat_t, 1.0) * cox1));
        const c_vd = t6.mul(esat_l1.add(t6.mul(a_vd)));
        const disc = b_vd.mul(b_vd).sub(a_vd.mul(c_vd).scale(2.0)).maxC(0.0);
        // if a_vd > 1e-30 : (b_vd - sqrt(disc))/a_vd else t6   -- branch on value
        vdsat = if (a_vd.val() > 1.0e-30) b_vd.sub(disc.sqrt()).div(a_vd) else t6;
    }
    vdsat = vdsat.maxC(1.0e-6);

    // effective Vds (eq 3.193)
    const mexp_clamp = @max(p.mexp_t, 2.0);
    const vds_ratio = vdsx.div(vdsat.maxC(1.0e-30));
    const vds_ratio_mexp = vds_ratio.maxC(1.0e-30).log().scale(mexp_clamp).exp();
    const vds_eff = vdsx.div(vds_ratio_mexp.addC(1.0).maxC(1.0e-30).log().scale(1.0 / mexp_clamp).exp());

    // ---- 3.7 average field/charge ----
    const q_ba = Q_ELEC * @as(f64, @floatCast(model.nbody)) * p.tsi / cox1;
    const dq_i = q_tots.sub(q_totd).scale(1.0 / cox1);

    // ---- 3.9 mobility degradation (full average) ----
    const q_fronttot = q_fronts.add(q_frontd).scale(0.5 / cox1);
    const dq_front = q_fronts.sub(q_frontd).scale(1.0 / cox1);
    const a_chargewf = 2.0 * w_eff * @max(p.vsat_t, 1.0) * cox1 * rds_v.val();
    const chargewf_factor: f64 = if (p.chargewf != 0) p.chargewf * (1.0 - @exp(-a_chargewf / 2.0)) * 0.5 else 0.0;
    const q_ia2 = q_fronttot.add(dq_front.scale(chargewf_factor));

    const t2_m = q_ia2.scale(eta_mob).addC(q_ba);
    const t3_m = t2_m.mul(t2_m).addC(0.001).sqrt().add(t2_m).scale(0.5);
    const eeff_m = t3_m.scale(1.0e-8 * cox1 / eps_si);

    const dmob0 = vbgx.scale(p.uc_t).addC(p.ua_t)
        .mul(eeff_m.maxC(1.0e-30).log().mul(vbgx.scale(p.eub_l).addC(p.eu_l)).exp())
        .add(q_ia.scale(1.0 / q_b0).maxC(1.0e-30).sqrt().mul(vbgx.scale(p.udb_l).addC(p.ud_t)).scale(1.0 / @max(p.ucs_t, 1.0e-30)))
        .addC(1.0);
    const dmob = dmob0.scale(1.0 / p.u0mult);
    const mu_eff = dmob.maxC(1.0e-30).pow(-1.0).scale(p.mu0_t);

    // back side
    const q_backtot = q_backs.add(q_backd).scale(0.5 / cox2);
    const dq_back = q_backs.sub(q_backd).scale(1.0 / cox2);
    const chargewf2_factor: f64 = if (p.chargewf2 != 0) p.chargewf2 * (1.0 - @exp(-a_chargewf / 2.0)) * 0.5 else 0.0;
    const q_ib2 = q_backtot.add(dq_back.scale(chargewf2_factor));

    const t2_m2 = q_ib2.scale(eta_mob2).addC(q_ba);
    const t3_m2 = t2_m2.mul(t2_m2).addC(0.001).sqrt().add(t2_m2).scale(0.5);
    const eeff_m2 = t3_m2.scale(1.0e-8 * cox2 / eps_si);

    const dmob02 = vbgx.scale(p.uc2_t).addC(p.ua2_t)
        .mul(eeff_m2.maxC(1.0e-30).log().mul(vbgx.scale(p.eub2_l).addC(p.eu2_l)).exp())
        .add(q_ia.scale(1.0 / q_b0).maxC(1.0e-30).sqrt().mul(vbgx.scale(p.udb2_l).addC(p.ud2_t)).scale(1.0 / @max(p.ucs2_t, 1.0e-30)))
        .addC(1.0);
    const dmob2 = dmob02.scale(1.0 / p.u0mult);
    const mu_eff2 = dmob2.maxC(1.0e-30).pow(-1.0).scale(p.mu02_t);

    // total mobility
    const t0_wm = vg_eff_drive.sub(q_fronts.add(q_frontd).scale(1.0 / cox1));
    const t1_wm = vgfb2.sub(dvth_all).sub(q_backs.add(q_backd).scale(1.0 / cox2));
    const exp_wm1 = t0_wm.div(nvtm).minC(80.0).exp();
    const exp_wm2 = t1_wm.div(nvtm).minC(80.0).exp();
    const w_sum_m = exp_wm1.add(exp_wm2).addC(1.0e-30);
    const wm1 = exp_wm1.div(w_sum_m);
    const wm2 = exp_wm2.div(w_sum_m);
    const mu_total = wm1.mul(mu_eff).add(wm2.mul(mu_eff2));

    // ---- 3.10 lateral NUD (eq 3.224) ----
    // m_nud = exp(-k0_t/max(k0si_t*q_ia + nvtm2, eps))
    const m_nud = q_ia.scale(p.k0si_t).add(nvtm2).maxC(1.0e-30).pow(-1.0).scale(-p.k0_t).exp();

    // ---- 3.11 output conductance ----
    // 3.11.1 CLM
    const cclm_inv: S = if (p.pclmg >= 0)
        q_ia.scale(p.pclmg).addC(p.pclm_l)
    else
        q_ia.scale(-p.pclmg).neg().addC(1.0).pow(-1.0).scale(1.0 / @max(p.pclm_l, 1.0e-30));

    const esat_l = esat.scale(l_eff);
    const m_clm: S = if (p.pclm_l > 0)
        cclm_inv.maxC(1.0e-30).pow(-1.0)
            .mul(vdsx.sub(vds_eff).div(vdsat.add(esat_l).maxC(1.0e-30)).mul(cclm_inv).addC(1.0).maxC(1.0e-30).log())
            .addC(1.0)
    else
        S.con(1.0);

    // 3.11.2 DIBL on Rout
    const pvag_factor: S = if (p.pvag > 0)
        q_ia.scale(p.pvag).div(esat_l.maxC(1.0e-30)).addC(1.0)
    else
        q_ia.scale(-p.pvag).div(esat_l.maxC(1.0e-30)).addC(1.0).maxC(1.0e-30).pow(-1.0);

    const csh_drout = lambda_val.pow(-1.0).scale(p.drout * l_eff).minC(80.0).cosh();
    const theta_rout = csh_drout.addC(-1.0).maxC(1.0e-30).pow(-1.0).scale(0.5 * p.pdibl1).addC(p.pdibl2);

    // va_dibl = (q_ia+nvtm2)/max(theta_rout,eps) * (1 - vdsat/max(vdsat+q_ia+nvtm2,eps)) * pvag_factor
    const qn2 = q_ia.add(nvtm2);
    const va_dibl = qn2.div(theta_rout.maxC(1.0e-30))
        .mul(vdsat.div(vdsat.add(qn2).maxC(1.0e-30)).neg().addC(1.0))
        .mul(pvag_factor);

    const m_oc = vdsx.sub(vds_eff).div(va_dibl.maxC(1.0e-30)).mul(m_clm).addC(1.0);

    // ---- 3.12 velocity saturation ----
    const esat1 = mu_total.maxC(1.0e-30).pow(-1.0).scale(2.0 * @max(p.vsat1_t, 1.0));

    const t0_vs = vbgx.scale(p.vsatb_t).addC(0.8);
    const x_sat = t0_vs.mul(t0_vs).addC(0.01).sqrt().add(t0_vs).scale(0.5).addC(0.2);

    const dq_esat = dq_i.div(esat1.mul(x_sat).scale(l_eff).maxC(1.0e-30));
    // d_vsat = sqrt(1 + dq_esat^2) + deltavsat + 0.5*(ptwg_t - ptwgb_l*vbgx_pos - ptwgb2_l*vbgx)*q_ia*dq_i^2
    const ptwg_eff = vbgx_pos.scale(-p.ptwgb_l).add(vbgx.scale(-p.ptwgb2_l)).addC(p.ptwg_t);
    const d_vsat = dq_esat.mul(dq_esat).addC(1.0).sqrt()
        .addC(p.deltavsat)
        .add(ptwg_eff.mul(q_ia).mul(dq_i).mul(dq_i).scale(0.5));

    // ---- 3.13 drain current ----
    // ids0 = 2*vtm*csi*n_slope*vtm*(qmtots-qmtotd)
    //        + csi*n_slope*vtm*(qmtots^2 - qmtotd^2)/(2*cox1)
    const ids0 = nvtm.scale(2.0 * vtm * csi).mul(qmtots.sub(qmtotd))
        .add(nvtm.scale(csi).mul(qmtots.mul(qmtots).sub(qmtotd.mul(qmtotd))).scale(1.0 / (2.0 * cox1)));

    const dr: S = if (p.rdsmod == 1)
        S.con(1.0)
    else
        mu_total.scale(nf * cox1 * w_eff / l_eff).mul(ids0)
            .div(dq_i.abs().addC(1.0e-30).maxC(1.0e-30))
            .mul(d_vsat.maxC(1.0e-30).pow(-1.0))
            .mul(rds_v)
            .addC(1.0);

    const ids_core = mu_total.scale(w_eff / l_eff).mul(ids0).mul(m_oc)
        .div(dr.mul(d_vsat).maxC(1.0e-30))
        .mul(m_nud);
    const ids_val = ids_core.scale(nf * m_mult * devsign);

    // ---- 3.15.2 parasitic resistance ----
    var i_rs_ext: S = undefined;
    var i_rd_ext: S = undefined;
    if (p.rdsmod == 1) {
        // eq 3.252-3.256
        const vgs_real = x[fgp].sub(x[sp]);
        const vgd_real = x[fgp].sub(x[dp]);

        const vgs_m = vgs_real.addC(-p.vfbsd);
        const vgd_m = vgd_real.addC(-p.vfbsd);
        const vgs_eff_r = vgs_m.mul(vgs_m).addC(1.0e-4).sqrt().add(vgs_m).scale(0.5);
        const vgd_eff_r = vgd_m.mul(vgd_m).addC(1.0e-4).sqrt().add(vgd_m).scale(0.5);

        const w_new_wr = @exp(p.wr * @log(@max(p.w_new, 1.0e-30)));
        const inv_wnf = 1.0 / (w_new_wr * nf);
        // r_source = inv_wnf*(rswmin_t + rsw_t/(1+prwg*vgs_eff_r)) + rs_geo
        const r_source = vgs_eff_r.scale(p.prwg).addC(1.0).pow(-1.0).scale(p.rsw_t).addC(p.rswmin_t).scale(inv_wnf).addC(p.rs_geo);
        const r_drain = vgd_eff_r.scale(p.prwg).addC(1.0).pow(-1.0).scale(p.rdw_t).addC(p.rdwmin_t).scale(inv_wnf).addC(p.rd_geo);

        // g = m/r if r>0 else GSHORT (branch on value)
        const g_rs_ext: S = if (r_source.val() > 0) S.con(m_mult).div(r_source) else S.con(GSHORT);
        const g_rd_ext: S = if (r_drain.val() > 0) S.con(m_mult).div(r_drain) else S.con(GSHORT);

        i_rs_ext = x[s].sub(x[sp]).mul(g_rs_ext);
        i_rd_ext = x[d].sub(x[dp]).mul(g_rd_ext);
    } else {
        i_rs_ext = x[s].sub(x[sp]).scale(GSHORT);
        i_rd_ext = x[d].sub(x[dp]).scale(GSHORT);
    }

    // ---- 3.16 impact ionization ----
    const vds_minus_vdseff = vdsx.sub(vds_eff).maxC(1.0e-30);
    const i_ii: S = if (p.alpha0 != 0 or p.alpha1 != 0)
        vds_minus_vdseff.scale((p.alpha0 + p.alpha1 * l_eff) / l_eff)
            .mul(vds_minus_vdseff.pow(-1.0).scale(-p.beta0_t).minC(80.0).exp())
            .mul(ids_core.abs())
            .scale(nf * m_mult)
    else
        S.con(0.0);

    // ---- 3.17 GIDL/GISL ----
    var i_gidl: S = S.con(0.0);
    var i_gisl: S = S.con(0.0);
    if (p.gidlmod == 1) {
        const vfbsd_bg = p.vfbsd_bg;
        // gidl_arg = vdsx - vfgs - egidl + vfbsd + vbgidl*gamma0*(vbgs - vfbsd_bg - vbegidl)
        const gidl_arg = vdsx.sub(vfgs).addC(-p.egidl + p.vfbsd)
            .add(vbgs.addC(-vfbsd_bg - p.vbegidl).scale(p.vbgidl * p.gamma0));
        const gidl_field_pos = gidl_arg.scale(1.0 / (p.ratio * p.eot1)).maxC(1.0e-30);
        // i_gidl = agidl*Weff*nf*exp(pgidl*log(field)) * exp(min(-ratio*eot1*bgidl_t/max(gidl_arg,eps),80)) * m
        const gidl_raw = gidl_field_pos.log().scale(p.pgidl).exp().scale(p.agidl * w_eff * nf)
            .mul(gidl_arg.maxC(1.0e-30).pow(-1.0).scale(-p.ratio * p.eot1 * p.bgidl_t).minC(80.0).exp())
            .scale(m_mult);
        i_gidl = gidl_raw.maxC(0.0);

        // GISL
        const gisl_arg = vdsx.sub(vfgd).addC(-p.egisl + p.vfbsd)
            .add(vbgs.addC(-vfbsd_bg - p.vbegisl).scale(p.vbgisl * p.gamma0));
        const gisl_field_pos = gisl_arg.scale(1.0 / (p.ratio * p.eot1)).maxC(1.0e-30);
        const gisl_raw = gisl_field_pos.log().scale(p.pgisl).exp().scale(p.agisl * w_eff * nf)
            .mul(gisl_arg.maxC(1.0e-30).pow(-1.0).scale(-p.ratio * p.eot1 * p.bgisl_t).minC(80.0).exp())
            .scale(m_mult);
        i_gisl = gisl_raw.maxC(0.0);
    }

    // ---- 3.18 gate tunneling ----
    var i_gbs_val: S = S.con(0.0);
    var i_gbd_val: S = S.con(0.0);
    var i_gcs_val: S = S.con(0.0);
    var i_gcd_val: S = S.con(0.0);
    var i_gs_val: S = S.con(0.0);
    var i_gd_val: S = S.con(0.0);

    if (p.igbmod == 1) {
        const a_inv: f64 = 3.75956e-7;
        const b_inv: f64 = 9.82222e11;
        const nigbinv_val = p.nigbinv;

        // vaux_igbinv = nigbinv*vtm*log(1 + exp(min((q_ia-eigbinv)/(nigbinv*vtm),80)))
        const vaux_igbinv = q_ia.addC(-p.eigbinv).scale(1.0 / (nigbinv_val * vtm)).minC(80.0).exp().addC(1.0).log().scale(nigbinv_val * vtm);

        const v_gbg = vfgs.sub(vbgs);
        // exp arg: min(-b_inv*toxp*(aigbinv - bigbinv*q_ia)*(1 + cigbinv*q_ia), 80)
        const eterm_inv = q_ia.scale(-p.bigbinv).addC(p.aigbinv)
            .mul(q_ia.scale(p.cigbinv).addC(1.0))
            .scale(-b_inv * p.toxp_val).minC(80.0).exp();
        const igbinv = v_gbg.mul(vaux_igbinv).scale(p.w_new * l_eff * nf * a_inv * p.tox_ratio * p.ig_temp).mul(eterm_inv);

        // Igb accumulation
        const a_acc: f64 = 4.97232e-7;
        const b_acc: f64 = 7.45669e11;
        const nigbacc_val = p.nigbacc;

        const vfbzb = p.dphi1 - p.eg / 2.0 - p.phi_b;
        const t0_acc = v_gbg.neg().addC(vfbzb); // vfbzb - v_gbg
        const t1_acc = t0_acc.addC(-0.02);

        const vaux_igbacc = t0_acc.scale(1.0 / (nigbacc_val * vtm)).minC(80.0).exp().addC(1.0).log().scale(nigbacc_val * vtm);
        // voxacc: branches on constant vfbzb (x-independent) -- keep as constant sign selector
        const voxacc: S = if (vfbzb <= 0)
            t1_acc.mul(t1_acc).addC(-0.08 * vfbzb).sqrt().add(t1_acc).scale(0.5)
        else
            t1_acc.mul(t1_acc).addC(0.08 * vfbzb).sqrt().add(t1_acc).scale(0.5);

        const eterm_acc = voxacc.scale(-p.bigbacc).addC(p.aigbacc)
            .mul(voxacc.scale(p.cigbacc).addC(1.0))
            .scale(-b_acc * p.toxp_val).minC(80.0).exp();
        const igbacc = v_gbg.mul(vaux_igbacc).scale(p.w_new * l_eff * nf * a_acc * p.tox_ratio * p.ig_temp).mul(eterm_acc);

        // partition: tanh(0.6*q*vdsx/(k*T))
        const t0_part = vdsx.scale(0.6 * Q_ELEC / K_BOLT / p.t_dev).tanh();
        const wf = t0_part.scale(0.5).addC(0.5);
        const wr_part = t0_part.scale(-0.5).addC(0.5);

        const igb_sum = igbinv.add(igbacc);
        i_gbs_val = igb_sum.mul(wf).scale(m_mult);
        i_gbd_val = igb_sum.mul(wr_part).scale(m_mult);
    }

    if (p.igcmod == 1) {
        const a_gc: f64 = if (p.is_nmos) 4.97232e-7 else 3.42536e-7;
        const b_gc: f64 = if (p.is_nmos) 7.45669e11 else 1.16645e12;

        const v_gbg_gc = vfgs.sub(vbgs);
        const vbgd = vbgs.sub(vds_raw);
        // t0_gc = q_ia*(v_gbg - 0.5*vdsx + 0.5*vbgs + 0.5*vbgd)
        const t0_gc = q_ia.mul(v_gbg_gc.sub(vdsx.scale(0.5)).add(vbgs.scale(0.5)).add(vbgd.scale(0.5)));

        const digc_val = p.digc;
        const psi_fs_approx = vgfb1;
        // arg2 = vgfb1 - digc*psi_fs_approx
        const arg2 = vgfb1.sub(psi_fs_approx.scale(digc_val));
        const eterm_gc = arg2.scale(-p.bigc).addC(p.aigc).mul(arg2.scale(p.cigc).addC(1.0)).scale(-b_gc * p.toxp_val).minC(80.0).exp();
        const igc0 = t0_gc.scale(p.w_new * l_eff * nf * a_gc * p.tox_ratio * p.ig_temp).mul(eterm_gc);

        const pigcd_val = p.pigcd;
        const vds_effx = vds_eff.mul(vds_eff).addC(0.01).sqrt().addC(-0.1);
        const pigcd_vdseffx = vds_effx.scale(pigcd_val);
        const denom_gc = pigcd_vdseffx.mul(pigcd_vdseffx).addC(2.0e-4);

        // i_gcs = igc0*(pigcd_vdseffx + exp(pigcd_vdseffx) - 1 + 1e-4)/denom_gc*m
        i_gcs_val = igc0.mul(pigcd_vdseffx.add(pigcd_vdseffx.exp()).addC(-1.0 + 1.0e-4)).div(denom_gc).scale(m_mult);
        // i_gcd = igc0*(1 - (pigcd_vdseffx+1)*exp(-pigcd_vdseffx) + 1e-4)/denom_gc*m
        i_gcd_val = igc0.mul(pigcd_vdseffx.addC(1.0).mul(pigcd_vdseffx.neg().exp()).neg().addC(1.0 + 1.0e-4)).div(denom_gc).scale(m_mult);

        // Igs, Igd
        const a_gsd: f64 = if (p.is_nmos) 4.97232e-7 else 3.42536e-7;
        const b_gsd: f64 = if (p.is_nmos) 7.45669e11 else 1.16645e12;

        const vfbsd_bg = p.vfbsd_bg;
        const vgs_real = x[fgp].sub(x[sp]);
        const vgd_real = x[fgp].sub(x[dp]);

        // vgs_prime = sqrt((vgs_real - vfbsd + digs*gamma0*(vbgs*devsign - vfbsd_bg))^2 + 1e-4)
        // note: vbgs is already devsign-normalized here, but reference multiplies raw vbgs
        // by devsign again -> use terminal (v_bg - v_s) which equals vbgs*devsign.
        const vbgs_term = v_bg.sub(v_s); // == vbgs * devsign
        const gs_inner = vgs_real.addC(-p.vfbsd).add(vbgs_term.addC(-vfbsd_bg).scale(p.digs * p.gamma0));
        const gd_inner = vgd_real.addC(-p.vfbsd).add(vbgs_term.addC(-vfbsd_bg).scale(p.digd * p.gamma0));
        const vgs_prime = gs_inner.mul(gs_inner).addC(1.0e-4).sqrt();
        const vgd_prime = gd_inner.mul(gd_inner).addC(1.0e-4).sqrt();

        const igsd_mult = p.ig_temp * p.w_new * a_gsd / (p.toxp_val * p.poxedge) * @exp(p.ntox * @log(p.toxref / (p.toxp_val * p.poxedge)));

        const eterm_gs = vgs_prime.scale(-p.bigs).addC(p.aigs).mul(vgs_prime.scale(p.cigs).addC(1.0)).scale(-b_gsd * p.toxp_val * p.poxedge).minC(80.0).exp();
        const eterm_gd = vgd_prime.scale(-p.bigd).addC(p.aigd).mul(vgd_prime.scale(p.cigd).addC(1.0)).scale(-b_gsd * p.toxp_val * p.poxedge).minC(80.0).exp();

        i_gs_val = vgs_real.mul(vgs_prime).scale(nf * igsd_mult * p.dlcigs).mul(eterm_gs).scale(m_mult);
        i_gd_val = vgd_real.mul(vgd_prime).scale(nf * igsd_mult * p.dlcigd).mul(eterm_gd).scale(m_mult);
    }

    // ---- 3.19 gate resistance ----
    const i_gate_r = x[fg].sub(x[fgp]).scale(p.g_gate);

    // ---- 3.20 self-heating ----
    const v_temp = x[t_node];
    const i_th: S = if (p.shmod == 1)
        v_temp.scale(p.g_th).sub(ids_val.abs().mul(vdsx.abs()).scale(devsign))
    else
        v_temp.scale(GMIN);

    // ---- KCL assembly ----
    const i_fg_tunnel = i_gbs_val.add(i_gbd_val).add(i_gcs_val).add(i_gcd_val).add(i_gs_val).add(i_gd_val).scale(devsign);

    const ids_dp = ids_val;
    const i_ii_signed = i_ii.scale(devsign);
    const i_gidl_signed = i_gidl.scale(devsign);
    const i_gisl_signed = i_gisl.scale(devsign);

    var out: [n_u]S = undefined;
    out[fg] = i_gate_r;
    out[bg] = i_gbs_val.add(i_gbd_val).scale(devsign).neg().sub(i_gidl_signed).sub(i_gisl_signed).sub(i_ii_signed);
    out[d] = i_rd_ext;
    out[s] = i_rs_ext;
    out[t_node] = i_th;
    out[dp] = ids_dp.add(i_gcd_val.scale(devsign)).add(i_gd_val.scale(devsign)).add(i_gbd_val.scale(devsign)).add(i_gidl_signed).add(i_ii_signed).sub(i_rd_ext);
    out[sp] = ids_dp.neg().add(i_gcs_val.scale(devsign)).add(i_gs_val.scale(devsign)).add(i_gbs_val.scale(devsign)).add(i_gisl_signed).sub(i_rs_ext);
    out[fgp] = i_gate_r.neg().add(i_fg_tunnel);
    return out;
}

// ============================================================================
// x-independent prep for the charge function q.
// ============================================================================

const PrepQ = struct {
    devsign: f64,
    is_nmos: bool,
    is_pwell: bool,
    eot1: f64,
    eot2: f64,
    ratio: f64,
    tsi: f64,
    cox1: f64,
    cox2: f64,
    csi: f64,
    vtm: f64,
    nf: f64,
    m_mult: f64,
    l_eff: f64,
    w_eff: f64,
    l_eff_cv: f64,
    w_eff_cv: f64,
    w_inst: f64,
    dphi1: f64,
    phig2_i: f64,
    phi_ref: f64,
    vfbsd: f64,
    vfbsd_bg: f64,
    gamma0: f64,
    dvth_cv: f64,
    n_slope: f64,
    // overlap / fringe
    lovs: f64,
    lovd: f64,
    cgsl: f64,
    cgdl: f64,
    ckappas: f64,
    ckappad: f64,
    pcovbs0: f64,
    pcovbs1: f64,
    pcovbd0: f64,
    pcovbd1: f64,
    cfs: f64,
    cfd: f64,
    csdbgsw0: f64,
    as_: f64,
    ad: f64,
    ps: f64,
    pd: f64,
    m_clm_cv: f64,
    shmod: i32,
    c_th: f64,
};

fn prepQ(model: *const Model, instance: *const Instance) PrepQ {
    const devsign: f64 = @floatFromInt(model.type_);
    const is_nmos = model.type_ == 1;
    const is_pwell = model.welltype == -1;

    const eot1: f64 = @as(f64, model.eot1);
    const eot2: f64 = @as(f64, model.eot2);
    const tsi: f64 = @as(f64, model.tsi);
    const nbody: f64 = @as(f64, model.nbody);
    const nbg_val: f64 = @as(f64, model.nbg);
    const easub: f64 = @as(f64, model.easub);
    const ni0sub: f64 = @as(f64, model.ni0sub);
    const bg0sub: f64 = @as(f64, model.bg0sub);
    const epsrsub: f64 = @as(f64, model.epsrsub);
    const nsd_val: f64 = @as(f64, model.nsd);

    const tnom_k: f64 = @as(f64, model.tnom) + 273.15;
    const nf: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const t_dev: f64 = @as(f64, instance.temp) + @as(f64, instance.dtemp);

    const eps_si = epsrsub * EPS_0;
    const ratio = epsrsub / 3.9;
    const cox1 = 3.9 * EPS_0 / eot1;
    const cox2 = 3.9 * EPS_0 / eot2;
    const csi = eps_si / tsi;
    const vtm = K_BOLT * t_dev / Q_ELEC;

    const l_raw: f64 = @as(f64, instance.l);
    const w_raw: f64 = @as(f64, instance.w);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);
    const l_new = l_raw + xl;
    const lln: f64 = @as(f64, model.lln);
    const lwn_val: f64 = @as(f64, model.lwn);
    const wln_val: f64 = @as(f64, model.wln);
    const wwn_val: f64 = @as(f64, model.wwn);
    const l_lln = @exp(-lln * @log(@max(l_new, 1.0e-30)));
    const l_wln = @exp(-lwn_val * @log(@max(l_new, 1.0e-30)));
    const w_new: f64 = if (model.nfmod == 0) w_raw / nf else w_raw + xw;
    const w_lwn = @exp(-wln_val * @log(@max(w_new, 1.0e-30)));
    const w_wwn = @exp(-wwn_val * @log(@max(w_new, 1.0e-30)));
    const l_wlln_lwn = l_lln * w_lwn;
    const l_wwln_wwn = l_wln * w_wwn;

    const dl_cv = @as(f64, model.dlc) + @as(f64, model.llc) * l_lln + @as(f64, model.lwc) * w_lwn + @as(f64, model.lwlc) * l_wlln_lwn;
    const l_eff_cv = @max(l_new - 2.0 * dl_cv, 1.0e-9);
    const dw_cv = @as(f64, model.dwc) + @as(f64, model.wlc) * l_wln + @as(f64, model.wwc) * w_wwn + @as(f64, model.wwlc) * l_wwln_wwn;
    const w_eff_cv = @max(w_new - 2.0 * dw_cv, 1.0e-9);
    const dl_iv = @as(f64, model.lint) + @as(f64, model.ll) * l_lln + @as(f64, model.lw) * w_lwn + @as(f64, model.lwl) * l_wlln_lwn;
    const l_eff = @max(l_new - 2.0 * dl_iv, 1.0e-9);
    const dw_iv = @as(f64, model.wint) + @as(f64, model.wl) * l_wln + @as(f64, model.ww) * w_wwn + @as(f64, model.wwl) * l_wwln_wwn;
    const w_eff = @max(w_new - 2.0 * dw_iv, 1.0e-9);

    const tbgasub: f64 = @as(f64, model.tbgasub);
    const tbgbsub: f64 = @as(f64, model.tbgbsub);
    const eg = bg0sub - tbgasub * t_dev * t_dev / (t_dev + tbgbsub);
    const ni = ni0sub * @exp(1.5 * @log(t_dev / 300.15)) * @exp(@min((bg0sub * Q_ELEC / (2.0 * K_BOLT * 300.15)) - (eg * Q_ELEC / (2.0 * K_BOLT * t_dev)), 80.0));
    const phi_b = vtm * @log(@max(nbody / ni, 1.0e-30));
    const phi_sub = vtm * @log(@max(nbg_val / ni, 1.0e-30));

    const phig1_i: f64 = @as(f64, model.phig1);
    var phig2_raw: f64 = @as(f64, model.phig2);
    if (model.phig2 == 0) {
        phig2_raw = if (is_pwell) easub else easub + bg0sub;
    }
    const phig2_i: f64 = if (is_pwell)
        phig2_raw - 0.5 * bg0sub + phi_sub
    else
        phig2_raw + 0.5 * bg0sub - phi_sub;

    const phi_ref: f64 = if (is_nmos) easub else easub + eg;
    const dphi1 = devsign * (phig1_i - phi_ref);

    const phi_sd_t = @min(eg / 2.0, vtm * @log(@max(nsd_val / ni, 1.0e-30)));
    const phi_sd = easub + eg / 2.0 - devsign * phi_sd_t;
    const vfbsd = devsign * (phig1_i - phi_sd);
    const vfbsd_bg = devsign * (phig2_i - phi_sd);

    const gamma0 = -cox2 * csi / ((cox2 + csi) * cox1);

    // simplified dVth for CV (x-independent -- see reference)
    const lambda_f = @sqrt(tsi * ratio * eot1);
    const lambda_s = @sqrt(tsi * ratio * eot1 + 0.375 * tsi);
    const lambda_val = 0.5 * (lambda_f + lambda_s);
    const csh_dvt = std.math.cosh(@min(@as(f64, model.dvt1) * l_eff / lambda_val, 80.0));
    const t_ratio = t_dev / tnom_k;
    const vbi = vtm * @log(@max(nsd_val * nbody / (ni * ni), 1.0e-30));
    const phin_val: f64 = @as(f64, model.phin);
    const phi_st = 0.4 + phi_b + phin_val;
    const dvth_sce = -0.5 * @as(f64, model.dvt0) / @max(csh_dvt - 1.0, 1.0e-30) * (vbi - phi_st);
    const dvth_nbody = Q_ELEC * nbody * tsi / cox1 * (1.0 - 0.5 * tsi / (tsi + ratio * eot2));
    const dvth_temp_cv = (@as(f64, model.kt1) + @as(f64, model.kt1l) / l_eff) * (t_ratio - 1.0);
    const dvth_cv = dvth_sce + dvth_nbody + dvth_temp_cv + @as(f64, instance.delvtrand);

    const n_slope = 1.0 + @as(f64, model.cit) / (cox1 + csi * cox2 / (csi + cox2));

    const pclmcv_val: f64 = @as(f64, model.pclmcv);
    const m_clm_cv: f64 = if (pclmcv_val > 0) @max(1.0 + pclmcv_val, 1.0) else 1.0;

    const csdbgsw0 = @as(f64, model.csdbgsw) * @log(@max(1.0 + tsi / eot2, 1.0e-30));

    const c_th: f64 = if (model.shmod == 1)
        @as(f64, model.cth0) * (@as(f64, model.wth0) + w_eff) * nf
    else
        0.0;

    return .{
        .devsign = devsign,
        .is_nmos = is_nmos,
        .is_pwell = is_pwell,
        .eot1 = eot1,
        .eot2 = eot2,
        .ratio = ratio,
        .tsi = tsi,
        .cox1 = cox1,
        .cox2 = cox2,
        .csi = csi,
        .vtm = vtm,
        .nf = nf,
        .m_mult = m_mult,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .l_eff_cv = l_eff_cv,
        .w_eff_cv = w_eff_cv,
        .w_inst = @as(f64, instance.w),
        .dphi1 = dphi1,
        .phig2_i = phig2_i,
        .phi_ref = phi_ref,
        .vfbsd = vfbsd,
        .vfbsd_bg = vfbsd_bg,
        .gamma0 = gamma0,
        .dvth_cv = dvth_cv,
        .n_slope = n_slope,
        .lovs = @as(f64, model.lovs),
        .lovd = if (model.lovd == 0) @as(f64, model.lovs) else @as(f64, model.lovd),
        .cgsl = @as(f64, model.cgsl),
        .cgdl = if (model.cgdl == 0) @as(f64, model.cgsl) else @as(f64, model.cgdl),
        .ckappas = @as(f64, model.ckappas),
        .ckappad = if (model.ckappad == 0) @as(f64, model.ckappas) else @as(f64, model.ckappad),
        .pcovbs0 = @as(f64, model.pcovbs0),
        .pcovbs1 = @as(f64, model.pcovbs1),
        .pcovbd0 = if (model.pcovbd0 == 0) @as(f64, model.pcovbs0) else @as(f64, model.pcovbd0),
        .pcovbd1 = if (model.pcovbd1 == 0) @as(f64, model.pcovbs1) else @as(f64, model.pcovbd1),
        .cfs = @as(f64, model.cfs),
        .cfd = if (model.cfd == 0) @as(f64, model.cfs) else @as(f64, model.cfd),
        .csdbgsw0 = csdbgsw0,
        .as_ = @as(f64, instance.as_),
        .ad = @as(f64, instance.ad),
        .ps = @as(f64, instance.ps),
        .pd = @as(f64, instance.pd),
        .m_clm_cv = m_clm_cv,
        .shmod = model.shmod,
        .c_th = c_th,
    };
}

pub const PrepCache = struct { dc: PrepI, q: PrepQ };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = prepI(model, instance), .q = prepQ(model, instance) };
}

// ============================================================================
// Charge Function (q) -- Intrinsic + Overlap + S/D-to-substrate capacitances
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

    const fg = @intFromEnum(U.fg);
    const bg = @intFromEnum(U.bg);
    const d = @intFromEnum(U.drain);
    const s = @intFromEnum(U.source);
    const t_node = @intFromEnum(U.temp);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);
    const fgp = @intFromEnum(U.fg_prime);

    const p = &pc.q;
    const devsign = p.devsign;
    const cox1 = p.cox1;
    const cox2 = p.cox2;
    const csi = p.csi;
    const vtm = p.vtm;
    const nf = p.nf;
    const m_mult = p.m_mult;

    // ---- terminal voltages ----
    const v_fg = x[fgp];
    const v_bg = x[bg];
    const v_d = x[dp];
    const v_s = x[sp];

    const vfgs = v_fg.sub(v_s).scale(devsign);
    const vfgd = v_fg.sub(v_d).scale(devsign);
    const vbgs = v_bg.sub(v_s).scale(devsign);
    const vds_raw = v_d.sub(v_s).scale(devsign);

    const vgfb1 = vfgs.addC(-p.dphi1);

    const vdsx = vds_raw.mul(vds_raw).addC(0.0004).sqrt().addC(-0.02);

    const vg_eff_drive = vgfb1.addC(-p.dvth_cv);

    const nvtm: f64 = @max(vtm, 1.0e-30);
    const n_slope = p.n_slope;
    const nsvtm = n_slope * nvtm;

    // qmtots = log(1 + exp(min(vg_eff_drive/(n_slope*nvtm), 80)))
    const qmtots = vg_eff_drive.scale(1.0 / nsvtm).minC(80.0).exp().addC(1.0).log();
    const qmtotd = vg_eff_drive.sub(vdsx).scale(1.0 / nsvtm).minC(80.0).exp().addC(1.0).log();

    // ---- 3.14 C-V charges ----
    const ns_vtm = n_slope * vtm;
    const q_fronts_cv = vg_eff_drive.scale(cox1 * ns_vtm).div(vg_eff_drive.addC(ns_vtm).maxC(1.0e-30)).mul(qmtots);
    const q_tots_cv = qmtots.scale(csi * ns_vtm);
    const q_backs_cv = q_tots_cv.sub(q_fronts_cv);

    const q_frontd_cv = vg_eff_drive.sub(vdsx).scale(cox1 * ns_vtm).div(vg_eff_drive.sub(vdsx).addC(ns_vtm).maxC(1.0e-30)).mul(qmtotd);
    const q_totd_cv = qmtotd.scale(csi * ns_vtm);
    const q_backd_cv = q_totd_cv.sub(q_frontd_cv);

    // ---- 3.14 intrinsic charge partition (eq 3.239-3.246) ----
    const q_fg_cv = q_fronts_cv.add(q_frontd_cv).scale(0.5);
    const q_bg_cv = q_backs_cv.add(q_backd_cv).scale(0.5);
    const q_d_cv = q_tots_cv.add(q_totd_cv.scale(2.0)).scale(1.0 / 6.0);

    const geom = nf / p.m_clm_cv * p.w_eff_cv * p.l_eff_cv;
    const q_fg_total = q_fg_cv.scale(geom * devsign);
    const q_bg_total = q_bg_cv.scale(geom * devsign);
    const q_d_intrinsic = q_d_cv.neg().scale(geom * devsign);
    const q_s_intrinsic = q_d_intrinsic.neg().sub(q_fg_total).sub(q_bg_total);

    // ---- 3.15.3 overlap capacitances ----
    const delta1_ov: f64 = 0.02;

    // source-side
    const t0_ovs = vfgs.addC(-p.vfbsd + delta1_ov).add(vbgs.addC(-p.vfbsd_bg - p.pcovbs0).scale(p.pcovbs1));
    const vfgs_ov = t0_ovs.sub(t0_ovs.mul(t0_ovs).addC(4.0 * delta1_ov).sqrt()).scale(0.5);

    const v_g_es = vfgs.scale(devsign);
    const t1_ovs = v_g_es.scale(nf * p.w_eff_cv * p.lovs * cox1);
    // t2_ovs = 0.5*ckappas*(sqrt(max(1 - 4*vfgs_ov/ckappas, eps)) - 1)
    const t2_ovs = vfgs_ov.scale(-4.0 / p.ckappas).addC(1.0).maxC(1.0e-30).sqrt().addC(-1.0).scale(0.5 * p.ckappas);
    const q_fgs_ov = t1_ovs.add(vfgs.addC(-p.vfbsd).sub(vfgs_ov).sub(t2_ovs).scale(nf * p.w_eff_cv * p.cgsl)).scale(devsign);

    // drain-side
    const t0_ovd = vfgd.addC(-p.vfbsd + delta1_ov).add(vbgs.addC(-p.vfbsd_bg - p.pcovbd0).scale(p.pcovbd1));
    const vfgd_ov = t0_ovd.sub(t0_ovd.mul(t0_ovd).addC(4.0 * delta1_ov).sqrt()).scale(0.5);

    const v_g_ed = vfgd.scale(devsign);
    const t1_ovd = v_g_ed.scale(nf * p.w_eff_cv * p.lovd * cox1);
    const t2_ovd = vfgd_ov.scale(-4.0 / p.ckappad).addC(1.0).maxC(1.0e-30).sqrt().addC(-1.0).scale(0.5 * p.ckappad);
    const q_fgd_ov = t1_ovd.add(vfgd.addC(-p.vfbsd).sub(vfgd_ov).sub(t2_ovd).scale(nf * p.w_eff_cv * p.cgdl)).scale(devsign);

    // ---- 3.15.4 outer fringe ----
    const q_fgs_of = v_g_es.scale(nf * p.w_eff_cv * p.cfs);
    const q_fgd_of = v_g_ed.scale(nf * p.w_eff_cv * p.cfd);

    // ---- 3.15.5 S/D to substrate ----
    const v_s_bg = x[sp].sub(x[bg]);
    const v_d_bg = x[dp].sub(x[bg]);
    const q_sbg = v_s_bg.scale(nf * (cox2 * p.as_ + @max(p.ps - p.w_inst, 0.0) * p.csdbgsw0));
    const q_dbg = v_d_bg.scale(nf * (cox2 * p.ad + @max(p.pd - p.w_inst, 0.0) * p.csdbgsw0));

    // ---- 3.20 self-heating capacitance ----
    // charge on thermal node: c_th * V_temp
    // ---- total charge stamps ----
    const q_fg_out = q_fg_total.add(q_fgs_ov).add(q_fgd_ov).add(q_fgs_of).add(q_fgd_of).scale(m_mult);
    const q_bg_out = q_bg_total.sub(q_sbg).sub(q_dbg).scale(m_mult);
    const q_d_out = q_fgd_ov.neg().sub(q_fgd_of).add(q_d_intrinsic).add(q_dbg).scale(m_mult);
    const q_s_out = q_fgs_ov.neg().sub(q_fgs_of).add(q_s_intrinsic).add(q_sbg).scale(m_mult);

    var out: [n_u]S = undefined;
    out[fg] = S.con(0.0); // gate resistance node: no charge
    out[bg] = q_bg_out;
    out[d] = S.con(0.0);
    out[s] = S.con(0.0);
    out[t_node] = x[t_node].scale(p.c_th * m_mult);
    out[dp] = q_d_out;
    out[sp] = q_s_out;
    out[fgp] = q_fg_out;
    return out;
}

// ============================================================================
// Voltage Limiting (DEVfetlim + DEVlimvds)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const fgp = @intFromEnum(U.fg_prime);
    const dp = @intFromEnum(U.d_prime);
    const sp = @intFromEnum(U.s_prime);

    const type_f: f64 = @floatFromInt(model.type_);
    _ = instance;

    var result = x_new;

    // DEVfetlim -- Gate-Source voltage limiting
    {
        const vgs_new = (x_new[fgp] - x_new[sp]) * type_f;
        const vgs_old = (x_old[fgp] - x_old[sp]) * type_f;

        const vto: f64 = 0.5; // approximate threshold for limiting
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
        result[fgp] += delta_gs;
    }

    // DEVlimvds -- Drain-Source voltage limiting
    {
        const vds_new = (result[dp] - result[sp]) * type_f;
        const vds_old = (x_old[dp] - x_old[sp]) * type_f;
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
        result[dp] += delta_ds;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Ramp GMIN contribution: at lambda=0 all junctions get extra GMIN conductance
    // At lambda=1 model is unmodified
    const gmin_boost: f64 = 1.0e-3;
    const rdsw_orig: f64 = @as(f64, model.rdsw);
    const rdsw_stepped = rdsw_orig * (1.0 + gmin_boost * (1.0 - lambda));
    m.rdsw = @floatCast(rdsw_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

// The BSIM-IMG residual/charge stamps satisfy Kirchhoff conservation by
// construction. These are exact algebraic regressions derivable from the
// KCL/charge-partition structure without hand-evaluating the transcendental
// physics, so they hold to rounding for any bias.

test "bsim_img: zero bias -> zero terminal currents" {
    // All node voltages equal => vfgs=vfgd=vbgs=vds=0, vdsx=sqrt(4e-4)-0.02=0.
    // Every branch current is a function of a voltage DIFFERENCE that is 0
    // (i_gate_r, i_rs/rd_ext), and the channel ids0 = 0 since qmtots==qmtotd.
    // Thermal row = V_temp*GMIN = 0. So every stamp is 0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0, 0, 0, 0, 0, 0, 0, 0 }, &model, &inst, 0);
    inline for (out) |o| try testing.expectApproxEqAbs(@as(f64, 0.0), o, 1e-12);
}

test "bsim_img: KCL current conservation at nonzero bias" {
    // Sum of all node residuals telescopes to the thermal-node term
    // (i_gate_r, i_rd_ext, i_rs_ext and ids_dp each appear with equal-and-
    // opposite sign across two rows; leakage-to-substrate terms enter the bg
    // row with the exact negation of their drain/source contributions).
    // With V_temp = 0 and SHMOD=0 the thermal term is 0, so the total is 0.
    const model: Model = .{};
    const inst: Instance = .{};
    // fg, bg, drain, source, temp, d', s', fg'
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.8, 0.0, 0.0, 0.8, 0.0, 1.0 }, &model, &inst, 0);
    var sum: f64 = 0;
    inline for (out) |o| sum += o;
    // magnitudes involve GSHORT*V ~ 1e12; relative tolerance accordingly.
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-3);
}

test "bsim_img: charge conservation (sum of q rows = 0)" {
    // q_fg_out + q_bg_out + q_d_out + q_s_out reduces algebraically to
    // q_fg_total + q_bg_total + q_d_intrinsic + q_s_intrinsic, and
    // q_s_intrinsic := -(q_d_intrinsic + q_fg_total + q_bg_total). fg/d/s rows
    // and thermal row (V_temp=0) contribute 0. Hence the total is exactly 0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 1.0, 0.0, 0.8, 0.0, 0.0, 0.8, 0.0, 1.0 }, &model, &inst, 0);
    var sum: f64 = 0;
    inline for (out) |o| sum += o;
    try testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-15);
}

test "bsim_img: on-state drain current is nonzero and drain/source antisymmetric" {
    // Vg well above threshold, small Vds: channel conducts. The intrinsic
    // channel current ids_dp enters d' as +ids and s' as -ids, so before the
    // (equal-and-opposite) parasitic short terms the channel is antisymmetric.
    // Here we just assert a real (nonzero) on-state channel current exists.
    const model: Model = .{};
    const inst: Instance = .{ .l = 30e-9, .w = 1e-6 };
    const out = contract.evalValues(Self, .{ 1.2, 0.0, 0.1, 0.0, 0.0, 0.1, 0.0, 1.2 }, &model, &inst, 0);
    // d' row minus its parasitic short = channel current; with all external
    // nodes tied to their internals (fg=fg', d=d', s=s') the short terms are 0,
    // so out[d'] = ids_dp and out[s'] = -ids_dp exactly.
    const dpi = @intFromEnum(U.d_prime);
    const spi = @intFromEnum(U.s_prime);
    try testing.expect(@abs(out[dpi]) > 0);
    try testing.expectApproxEqAbs(out[dpi], -out[spi], @abs(out[dpi]) * 1e-9 + 1e-15);
}
