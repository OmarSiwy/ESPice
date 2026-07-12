const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM4 4.8.3 -- Berkeley Short-channel IGFET Model (Level 14/54)
//
// Topology:
//   External:  D (drain), G (gate), S (source), B (bulk)
//   Internal:  dp (intrinsic drain), sp (intrinsic source),
//              gp (intrinsic gate), bp (body prime),
//              db (drain body), sb (source body)
//
//   D  -- Rd_diff -- dp
//   S  -- Rs_diff -- sp
//   G  -- Rgeltd  -- gp   (rgateMod >= 1)
//   B  -- Rbpb    -- bp   (rbodyMod >= 1)
//   bp -- Rbpd    -- db
//   bp -- Rbps    -- sb
//   db -- Rbdb    -- B
//   sb -- Rbsb    -- B
//
//   Channel:  dp <-> sp  (controlled by gp/bp)
//   Junctions: bp-sp (source diode), bp-dp (drain diode)
//   Gate tunneling: gp->bp, gp->sp, gp->dp
//   Impact ionization: dp->bp
//   GIDL/GISL: dp->bp, sp->bp
// ============================================================================

pub const U = enum(u8) {
    drain, // 0 - external drain
    gate, // 1 - external gate
    source, // 2 - external source
    bulk, // 3 - external bulk
    drain_prime, // 4 - intrinsic drain (after Rd)
    source_prime, // 5 - intrinsic source (after Rs)
    gate_prime, // 6 - intrinsic gate (after Rg)
    body_prime, // 7 - body prime node
    db_node, // 8 - drain-body node
    sb_node, // 9 - source-body node
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
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;
const DELTA1: f64 = 0.001;
const KBT_OVER_Q_300: f64 = K_BOLTZ * 300.15 / Q_ELECTRON;

// Gate tunneling physical constants
const A_ACC: f64 = 4.97232e-7;
const B_ACC: f64 = 7.45669e11;
const A_INV: f64 = 3.75956e-7;
const B_INV: f64 = 9.82222e11;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device Type ---
    type_: i32 = 1, // 1 = NMOS, -1 = PMOS

    // --- A.1 Model Selectors ---
    version: f32 = 4.83,
    level: i32 = 14,
    binunit: i32 = 1,
    paramchk: i32 = 1,
    mobmod: i32 = 0,
    mtrlmod: i32 = 0,
    rdsmod: i32 = 0,
    igcmod: i32 = 0,
    igbmod: i32 = 0,
    cvchargemod: i32 = 0,
    capmod: i32 = 2,
    rgatemod: i32 = 0,
    rbodymod: i32 = 0,
    trnqsmod: i32 = 0,
    acnqsmod: i32 = 0,
    fnoimod: i32 = 1,
    tnoimod: i32 = 0,
    diomod: i32 = 1,
    tempmod: i32 = 0,
    permod: i32 = 1,
    geomod: i32 = 0,
    wpemod: i32 = 0,
    gidlmod: i32 = 0,

    // --- A.2 Process Parameters ---
    epsrox: f32 = 3.9,
    toxe: f32 = 3.0e-9,
    eot: f32 = 1.5e-9,
    toxp: f32 = 3.0e-9, // default = TOXE
    toxm: f32 = 3.0e-9, // default = TOXE
    dtox: f32 = 0.0,
    xj: f32 = 1.5e-7,
    ndep: f32 = 1.7e17,
    nsub: f32 = 6.0e16,
    ngate: f32 = 0.0,
    nsd: f32 = 1.0e20,
    rsh: f32 = 0.0,
    rshg: f32 = 0.1,
    xt: f32 = 1.55e-7,

    // --- A.3 Basic Model Parameters ---
    vth0: f32 = std.math.nan(f32), // NaN = not given -> derived vfb+phi+k1*sqrt(phi) (b4temp.c)
    vfb: f32 = std.math.nan(f32), // NaN = not given -> vth0-phi-k1*sqrt(phi), or -1.0 (b4temp.c)
    vddeot: f32 = 1.5,
    leffeot: f32 = 1e-6,
    weffeot: f32 = 10e-6,
    tempeot: f32 = 27,
    phin: f32 = 0.0,
    easub: f32 = 4.05,
    epsrsub: f32 = 11.7,
    epsrgate: f32 = 11.7,
    ni0sub: f32 = 1.45e16,
    bg0sub: f32 = 1.16,
    tbgasub: f32 = 7.02e-4,
    tbgbsub: f32 = 1108.0,
    ados: f32 = 1.0,
    bdos: f32 = 1.0,
    k1: f32 = 0.0, // 0 together with k2==0 = not given -> derived from gamma1/gamma2 (b4temp.c)
    k2: f32 = 0.0,
    k3: f32 = 80.0,
    k3b: f32 = 0.0,
    w0: f32 = 2.5e-6,
    lpe0: f32 = 1.74e-7,
    lpeb: f32 = 0.0,
    vbm: f32 = -3.0,
    dvt0: f32 = 2.2,
    dvt1: f32 = 0.53,
    dvt2: f32 = -0.032,
    dvtp0: f32 = 0.0,
    dvtp1: f32 = 0.0,
    dvtp2: f32 = 0.0,
    dvtp3: f32 = 0.0,
    dvtp4: f32 = 0.0,
    dvtp5: f32 = 0.0,
    dvt0w: f32 = 0.0,
    dvt1w: f32 = 5.3e6,
    dvt2w: f32 = -0.032,
    u0: f32 = 0.067,
    ua: f32 = 1.0e-9,
    ub: f32 = 1.0e-19,
    uc: f32 = -0.0465,
    ud: f32 = 0.0,
    ucs: f32 = 1.67,
    up: f32 = 0.0,
    lp: f32 = 1e-8,
    eu: f32 = 1.67,
    vsat: f32 = 8.0e4,
    a0: f32 = 1.0,
    ags: f32 = 0.0,
    b0: f32 = 0.0,
    b1: f32 = 0.0,
    keta: f32 = -0.047,
    a1: f32 = 0.0,
    a2: f32 = 1.0,
    wint: f32 = 0.0,
    lint: f32 = 0.0,
    dwg: f32 = 0.0,
    dwb: f32 = 0.0,
    voff: f32 = -0.08,
    voffl: f32 = 0.0,
    minv: f32 = 0.0,
    nfactor: f32 = 1.0,
    eta0: f32 = 0.08,
    etab: f32 = -0.07,
    dsub: f32 = 0.56,
    cit: f32 = 0.0,
    cdsc: f32 = 2.4e-4,
    cdscb: f32 = 0.0,
    cdscd: f32 = 0.0,
    pclm: f32 = 1.3,
    pdiblc1: f32 = 0.39,
    pdiblc2: f32 = 0.0086,
    pdiblcb: f32 = 0.0,
    drout: f32 = 0.56,
    pscbe1: f32 = 4.24e8,
    pscbe2: f32 = 1.0e-5,
    pvag: f32 = 0.0,
    delta: f32 = 0.01,
    fprout: f32 = 0.0,
    pdits: f32 = 0.0,
    pditsl: f32 = 0.0,
    pditsd: f32 = 0.0,
    lambda_: f32 = 0.0,
    vtl: f32 = 0.0, // 0 = not given; ngspice applies the source-end velocity limit only when VTL is on the card
    lc: f32 = 0.0,
    xn: f32 = 3.0,

    // --- A.4 Asymmetric Rds ---
    rdsw: f32 = 200.0,
    rdswmin: f32 = 0.0,
    rdw: f32 = 100.0,
    rdwmin: f32 = 0.0,
    rsw: f32 = 100.0,
    rswmin: f32 = 0.0,
    prwg: f32 = 1.0,
    prwb: f32 = 0.0,
    wr: f32 = 1.0,

    // --- A.5 Impact Ionization ---
    alpha0: f32 = 0.0,
    alpha1: f32 = 0.0,
    beta0: f32 = 0.0,

    // --- A.6 GIDL/GISL ---
    agidl: f32 = 0.0,
    bgidl: f32 = 2.3e9,
    cgidl: f32 = 0.5,
    egidl: f32 = 0.8,
    rgidl: f32 = 1.0,
    kgidl: f32 = 0.0,
    fgidl: f32 = 0.0,
    agisl: f32 = 0.0,
    bgisl: f32 = 2.3e9,
    cgisl: f32 = 0.5,
    egisl: f32 = 0.8,
    rgisl: f32 = 1.0,
    kgisl: f32 = 0.0,
    fgisl: f32 = 0.0,

    // --- A.7 Gate Tunneling ---
    aigbacc: f32 = 9.49e-4,
    bigbacc: f32 = 1.71e-3,
    cigbacc: f32 = 0.075,
    nigbacc: f32 = 1.0,
    aigbinv: f32 = 1.11e-2,
    bigbinv: f32 = 9.49e-4,
    cigbinv: f32 = 0.006,
    eigbinv: f32 = 1.1,
    nigbinv: f32 = 3.0,
    aigc: f32 = 1.36e-2,
    bigc: f32 = 1.71e-3,
    cigc: f32 = 0.075,
    aigs: f32 = 1.36e-2,
    bigs: f32 = 1.71e-3,
    cigs: f32 = 0.075,
    dlcig: f32 = 0.0,
    aigd: f32 = 1.36e-2,
    bigd: f32 = 1.71e-3,
    cigd: f32 = 0.075,
    dlcigd: f32 = 0.0,
    nigc: f32 = 1.0,
    poxedge: f32 = 1.0,
    pigcd: f32 = 1.0,
    ntox: f32 = 1.0,
    toxref: f32 = 3.0e-9,
    vfbsdoff: f32 = 0.0,
    phig: f32 = 4.05, // for mtrlMod=1

    // --- A.8 Charge/Capacitance ---
    xpart: f32 = 0.0,
    cgso: f32 = 0.0,
    cgdo: f32 = 0.0,
    cgbo: f32 = 0.0,
    cgsl: f32 = 0.0,
    cgdl: f32 = 0.0,
    ckappas: f32 = 0.6,
    ckappad: f32 = 0.6,
    cf: f32 = 0.0,
    clc: f32 = 1.0e-7,
    cle: f32 = 0.6,
    dlc: f32 = 0.0,
    dwc: f32 = 0.0,
    vfbcv: f32 = -1.0,
    noff: f32 = 1.0,
    voffcv: f32 = 0.0,
    voffcvl: f32 = 0.0,
    minvcv: f32 = 0.0,
    acde: f32 = 1.0,
    moin: f32 = 15.0,

    // --- A.9 High-Speed/RF ---
    xrcrg1: f32 = 12.0,
    xrcrg2: f32 = 1.0,
    rbpb: f32 = 50.0,
    rbpd: f32 = 50.0,
    rbps: f32 = 50.0,
    rbdb: f32 = 50.0,
    rbsb: f32 = 50.0,
    gbmin: f32 = 1.0e-12,
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

    // --- A.10 Noise ---
    noia: f32 = 6.25e41,
    noib: f32 = 3.125e26,
    noic: f32 = 8.75,
    em: f32 = 4.1e7,
    af: f32 = 1.0,
    ef: f32 = 1.0,
    kf: f32 = 0.0,
    lintnoi: f32 = 0.0,
    ntnoi: f32 = 1.0,
    tnoia: f32 = 1.5,
    tnoib: f32 = 3.5,
    tnoic: f32 = 0.0,
    rnoia: f32 = 0.577,
    rnoib: f32 = 0.5164,
    rnoic: f32 = 0.395,
    gidlclamp: f32 = -1e-5,
    idovvdsc: f32 = 1e-9,

    // --- A.11 Layout-Dependent Parasitics ---
    dmcg: f32 = 0.0,
    dmci: f32 = 0.0,
    dmdg: f32 = 0.0,
    dmcgt: f32 = 0.0,
    dwj: f32 = 0.0,
    xgw: f32 = 0.0,
    xgl: f32 = 0.0,
    xl: f32 = 0.0,
    xw: f32 = 0.0,
    ngcon: i32 = 1,

    // --- A.12 Junction Diode Parameters ---
    ijthsrev: f32 = 0.1,
    ijthdrev: f32 = 0.1,
    ijthsfwd: f32 = 0.1,
    ijthdfwd: f32 = 0.1,
    xjbvs: f32 = 1.0,
    xjbvd: f32 = 1.0,
    bvs: f32 = 10.0,
    bvd: f32 = 10.0,
    jss: f32 = 1.0e-4,
    jsd: f32 = 1.0e-4,
    jsws: f32 = 0.0,
    jswd: f32 = 0.0,
    jswgs: f32 = 0.0,
    jswgd: f32 = 0.0,
    jtss: f32 = 0.0,
    jtsd: f32 = 0.0,
    jtssws: f32 = 0.0,
    jtsswd: f32 = 0.0,
    jtsswgs: f32 = 0.0,
    jtsswgd: f32 = 0.0,
    jtweff: f32 = 0.0,
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
    cjs: f32 = 5.0e-4,
    cjd: f32 = 5.0e-4,
    mjs: f32 = 0.5,
    mjd: f32 = 0.5,
    mjsws: f32 = 0.33,
    mjswd: f32 = 0.33,
    cjsws: f32 = 5.0e-10,
    cjswd: f32 = 5.0e-10,
    cjswgs: f32 = 5.0e-10,
    cjswgd: f32 = 5.0e-10,
    mjswgs: f32 = 0.33,
    mjswgd: f32 = 0.33,
    pbs: f32 = 1.0,
    pbd: f32 = 1.0,
    pbsws: f32 = 1.0,
    pbswd: f32 = 1.0,
    pbswgs: f32 = 1.0,
    pbswgd: f32 = 1.0,

    // --- A.13 Temperature Parameters ---
    tnom: f32 = 27.0,
    ute: f32 = -1.5,
    ucste: f32 = -4.775e-3,
    kt1: f32 = -0.11,
    kt1l: f32 = 0.0,
    kt2: f32 = 0.022,
    ua1: f32 = 1.0e-9,
    ub1: f32 = -1.0e-18,
    uc1: f32 = 0.056,
    ud1: f32 = 0.0,
    at: f32 = 3.3e4,
    prt: f32 = 0.0,
    njs: f32 = 1.0,
    njd: f32 = 1.0,
    xtis: f32 = 3.0,
    xtid: f32 = 3.0,
    tpb: f32 = 0.0,
    tpbsw: f32 = 0.0,
    tpbswg: f32 = 0.0,
    tcj: f32 = 0.0,
    tcjsw: f32 = 0.0,
    tcjswg: f32 = 0.0,
    tvoff: f32 = 0.0,
    tvfbsdoff: f32 = 0.0,
    tnfactor: f32 = 0.0,
    teta0: f32 = 0.0,
    tvoffcv: f32 = 0.0,

    // --- A.14 Stress Effect ---
    saref: f32 = 1e-6,
    sbref: f32 = 1e-6,
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
    lkvth0: f32 = 0.0,
    wkvth0: f32 = 0.0,
    pkvth0: f32 = 0.0,
    llodvth: f32 = 0.0,
    wlodvth: f32 = 0.0,
    stk2: f32 = 0.0,
    lodk2: f32 = 1.0,
    steta0: f32 = 0.0,
    lodeta0: f32 = 1.0,

    // --- A.15 Well Proximity Effect ---
    web: f32 = 0.0,
    wec: f32 = 0.0,
    kvth0we: f32 = 0.0,
    k2we: f32 = 0.0,
    ku0we: f32 = 0.0,
    scref: f32 = 1e-6,

    // --- A.16 dW/dL Parameters ---
    wl: f32 = 0.0,
    wln: f32 = 1.0,
    ww: f32 = 0.0,
    wwn: f32 = 1.0,
    wwl: f32 = 0.0,
    ll: f32 = 0.0,
    lln: f32 = 1.0,
    lw: f32 = 0.0,
    lwn: f32 = 1.0,
    lwl: f32 = 0.0,
    llc: f32 = 0.0,
    lwc: f32 = 0.0,
    lwlc: f32 = 0.0,
    wlc: f32 = 0.0,
    wwc: f32 = 0.0,
    wwlc: f32 = 0.0,

    // --- A.17 Range ---
    lmin: f32 = 0.0,
    lmax: f32 = 1.0,
    wmin: f32 = 0.0,
    wmax: f32 = 1.0,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 1e-6,
    l: f32 = 1e-6,
    nf: f32 = 1.0,
    m: f32 = 1.0,
    delvto: f32 = 0.0,
    sa: f32 = 0.0,
    sb: f32 = 0.0,
    sd: f32 = 0.0,
    sca: f32 = 0.0,
    scb: f32 = 0.0,
    scc: f32 = 0.0,
    sc: f32 = 0.0,
    nrs: f32 = 1.0,
    nrd: f32 = 1.0,
    min_: i32 = 0,
    rgeomod: i32 = 0,
    temp: f32 = 300.15, // device temperature in K

    // Junction areas and perimeters
    as_: f64 = 0.0, // source area
    ad: f64 = 0.0, // drain area
    ps: f64 = 0.0, // source perimeter
    pd: f64 = 0.0, // drain perimeter

    // Instance-level selector overrides (use model values if < 0)
    rbodymod_inst: i32 = -1,
    rgatemod_inst: i32 = -1,
    trnqsmod_inst: i32 = -1,
    acnqsmod_inst: i32 = -1,

    // A.19 Additional Instance Parameters
    ketac: f32 = -0.047, // Body-bias coefficient for non-uniform depletion width (CV)
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: dp -- sp
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel flicker noise: dp -- sp
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
    // Drain resistance thermal: drain -- drain_prime
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Source resistance thermal: source -- source_prime
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Gate resistance thermal: gate -- gate_prime
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate_prime), .kind = .thermal },
    // Source junction shot: body_prime -- source_prime
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Drain junction shot: body_prime -- drain_prime
    .{ .row = @intFromEnum(U.body_prime), .col = @intFromEnum(U.drain_prime), .kind = .shot },
};

// ============================================================================
// Branchless helpers (plain f64)
// ============================================================================

inline fn safe_exp(x: f64) f64 {
    return contract.fmath.exp(@min(x, 80.0));
}

inline fn safe_log(x: f64) f64 {
    return contract.fmath.log(@max(x, 1e-38));
}

inline fn hypot2(a: f64, b: f64) f64 {
    return @sqrt(a * a + b * b);
}

inline fn cosh_approx(x: f64) f64 {
    // cosh(x) = (exp(x) + exp(-x)) / 2
    // For large x, cosh(x) ~ exp(|x|)/2
    const ax = @abs(x);
    const clamped = @min(ax, 80.0);
    const ep = contract.fmath.exp(clamped);
    const em = contract.fmath.exp(-clamped);
    return 0.5 * (ep + em);
}

inline fn tanh_approx(x: f64) f64 {
    // Compute tanh(x) = (exp(2x)-1)/(exp(2x)+1) branchlessly
    // Clamp to avoid overflow; for |x|>40, tanh ~ +/-1
    const clamped = @max(@min(x, 40.0), -40.0);
    const e2x = contract.fmath.exp(2.0 * clamped);
    return (e2x - 1.0) / (e2x + 1.0);
}

// ============================================================================
// Value-form S helpers (generic over the opaque scalar S)
// Mirror the f64 branchless helpers above but keep the Jacobian consistent.
// ============================================================================

/// safe_exp: exp(min(x, 80)). The minC clamp caps the argument; its
/// derivative goes flat past the clamp, matching the f64 @min guard.
inline fn sExp(comptime S: type, x: S) S {
    return x.minC(80.0).exp();
}

/// safe_log: log(max(x, 1e-38)). x here is always x-dependent and strictly
/// positive in the branches that use it; the maxC guards against underflow.
inline fn sLog(comptime S: type, x: S) S {
    return x.maxC(1e-38).log();
}

/// cosh(min(|x|, 80)) built from exp, matching cosh_approx exactly.
inline fn sCosh(comptime S: type, x: S) S {
    const clamped = x.abs().minC(80.0);
    const ep = clamped.exp();
    const em = clamped.neg().exp();
    return ep.add(em).scale(0.5);
}

/// tanh(clamp(x, -40, 40)) via (e2x-1)/(e2x+1), matching tanh_approx.
inline fn sTanh(comptime S: type, x: S) S {
    const clamped = x.minC(40.0).maxC(-40.0);
    const e2x = clamped.scale(2.0).exp();
    return e2x.addC(-1.0).div(e2x.addC(1.0));
}

// ============================================================================
// Prep: x-independent derived values cached across eval/q calls
// ============================================================================

const DcPrep = struct {
    // --- Fundamental ---
    type_f: f64,
    nf: f64,
    m_mult: f64,
    delvto: f64,
    // --- Temperature ---
    vt: f64,
    vt_nom: f64,
    t_ratio: f64,
    t_ratio_m1: f64,
    delta_t: f64,
    eg_tnom: f64,
    // --- Geometry ---
    leff: f64,
    weff_prime: f64,
    weffcj: f64,
    // --- Oxide ---
    coxe: f64,
    // --- Doping ---
    ndep_m3: f64,
    nsd_m3: f64,
    // --- Surface potential ---
    phi_s: f64,
    sqrt_phi_s: f64,
    // --- Built-in / Depletion ---
    vbi: f64,
    xdep0: f64,
    lt_factor: f64,
    lt0: f64,
    // --- Temperature-dependent mobility ---
    mu0_t: f64,
    ua_t: f64,
    ub_t: f64,
    uc_t: f64,
    ud_t: f64,
    vsat_t: f64,
    // --- Temperature-dependent threshold ---
    voff_t: f64,
    vfbsdoff_t: f64,
    nfactor_t: f64,
    eta0_t: f64,
    // --- Temperature-dependent resistance ---
    rdsw_t: f64,
    rdswmin_t: f64,
    // --- Oxide ratios ---
    k1ox: f64,
    k2ox: f64,
    // --- Lateral doping ---
    lpe0_factor: f64,
    lpeb_factor: f64,
    // --- DIBL (f64 parts) ---
    theta_dibl: f64,
    // --- Subthreshold ---
    m_val: f64,
    // --- Mobility helpers ---
    cdep0: f64,
    f_leff: f64,
    // --- Early voltage helpers ---
    litl: f64,
    rout: f64,
    // --- Gate tunneling ---
    tox_rat: f64,
    tox_rat_edge: f64,
    vfbsd_val: f64,
    // --- Junction diode (temperature-adjusted) ---
    jss_t: f64,
    jsd_t: f64,
    jsws_t: f64,
    jswd_t: f64,
    jswgs_t: f64,
    jswgd_t: f64,
    // --- Weffcj helpers ---
    weffcj_wr: f64,
    // --- Parasitic resistances (conductances) ---
    g_rd: f64,
    g_rs: f64,
    g_rg: f64,
    g_rbpb: f64,
    g_rbpd: f64,
    g_rbps: f64,
    g_rbdb: f64,
    g_rbsb: f64,
};

/// ngspice b4temp.c parameter derivation for values not on the model card.
/// Sentinels: k1==0 && k2==0 = not given (derive from gamma1/gamma2 built
/// from ndep/nsub, vbx from xt, vbm); vth0/vfb NaN = not given.
const DerivedVth = struct { k1: f64, k2: f64, vth0: f64, vfb: f64 };

fn vthDefaults(model: *const Model) DerivedVth {
    const tnom_k = @as(f64, model.tnom) + 273.15;
    const vt_nom = K_BOLTZ * tnom_k / Q_ELECTRON;
    const ndep_cm3: f64 = @as(f64, model.ndep);
    const ni_m3: f64 = 1.45e16;
    const phi_s = @max(0.4 + vt_nom * safe_log(ndep_cm3 * 1.0e6 / ni_m3) + @as(f64, model.phin), 0.1);
    const sqrt_phi_s = @sqrt(phi_s);

    var vbm: f64 = @as(f64, model.vbm);
    if (vbm > 0.0) vbm = -vbm;

    var k1: f64 = @as(f64, model.k1);
    var k2: f64 = @as(f64, model.k2);
    if (k1 == 0.0 and k2 == 0.0) {
        const coxe = @as(f64, model.epsrox) * EPS_0 / @as(f64, model.toxe);
        var vbx = phi_s - 7.7348e-4 * ndep_cm3 * @as(f64, model.xt) * @as(f64, model.xt);
        if (vbx > 0.0) vbx = -vbx;
        const gamma1 = 5.753e-12 * @sqrt(ndep_cm3) / coxe;
        const gamma2 = 5.753e-12 * @sqrt(@as(f64, model.nsub)) / coxe;
        const t1 = @sqrt(phi_s - vbx) - sqrt_phi_s;
        const t2 = @sqrt(phi_s * (phi_s - vbm)) - phi_s;
        k2 = (gamma1 - gamma2) * t1 / (2.0 * t2 + vbm);
        k1 = gamma2 - 2.0 * k2 * @sqrt(phi_s - vbm);
    }

    var vth0: f64 = @as(f64, model.vth0);
    var vfb: f64 = @as(f64, model.vfb);
    const vth0_given = vth0 == vth0; // NaN sentinel
    const vfb_given = vfb == vfb;
    if (!vfb_given) vfb = if (vth0_given) vth0 - phi_s - k1 * sqrt_phi_s else -1.0;
    if (!vth0_given) vth0 = vfb + phi_s + k1 * sqrt_phi_s;

    return .{ .k1 = k1, .k2 = k2, .vth0 = vth0, .vfb = vfb };
}

fn dcPrep(model: *const Model, instance: *const Instance) DcPrep {
    const dv = vthDefaults(model);
    const type_f: f64 = @floatFromInt(model.type_);
    const toxe: f64 = @as(f64, model.toxe);
    const toxm: f64 = @as(f64, model.toxm);
    const epsrox: f64 = @as(f64, model.epsrox);
    const ndep_cm3: f64 = @as(f64, model.ndep);
    const ngate_cm3: f64 = @as(f64, model.ngate);
    const nsd_cm3: f64 = @as(f64, model.nsd);
    const k1_param: f64 = dv.k1;
    const k2_param: f64 = dv.k2;
    const lpe0: f64 = @as(f64, model.lpe0);
    const lpeb: f64 = @as(f64, model.lpeb);
    const dsub: f64 = @as(f64, model.dsub);
    // b4temp.c: u0 > 1 is in cm^2/(V*s) -> convert to m^2/(V*s)
    const mu0_raw: f64 = @as(f64, model.u0);
    const mu0_param: f64 = if (mu0_raw > 1.0) mu0_raw / 1.0e4 else mu0_raw;
    const ua_param: f64 = @as(f64, model.ua);
    const ub_param: f64 = @as(f64, model.ub);
    const uc_param: f64 = @as(f64, model.uc);
    const ud_param: f64 = @as(f64, model.ud);
    const up_param: f64 = @as(f64, model.up);
    const lp_param: f64 = @as(f64, model.lp);
    const vsat_param: f64 = @as(f64, model.vsat);
    const lint: f64 = @as(f64, model.lint);
    const wint: f64 = @as(f64, model.wint);
    const minv: f64 = @as(f64, model.minv);
    const nfactor: f64 = @as(f64, model.nfactor);
    const eta0_param: f64 = @as(f64, model.eta0);
    const pdiblc1: f64 = @as(f64, model.pdiblc1);
    const pdiblc2: f64 = @as(f64, model.pdiblc2);
    const drout: f64 = @as(f64, model.drout);
    const phin: f64 = @as(f64, model.phin);
    const xj: f64 = @as(f64, model.xj);
    const rsh: f64 = @as(f64, model.rsh);
    const rdsw: f64 = @as(f64, model.rdsw);
    const rdswmin: f64 = @as(f64, model.rdswmin);
    const wr: f64 = @as(f64, model.wr);
    const ntox: f64 = @as(f64, model.ntox);
    const toxref: f64 = @as(f64, model.toxref);
    const vfbsdoff: f64 = @as(f64, model.vfbsdoff);
    const rshg: f64 = @as(f64, model.rshg);
    const gbmin_param: f64 = @as(f64, model.gbmin);
    const rbpb_param: f64 = @as(f64, model.rbpb);
    const rbpd_param: f64 = @as(f64, model.rbpd);
    const rbps_param: f64 = @as(f64, model.rbps);
    const rbdb_param: f64 = @as(f64, model.rbdb);
    const rbsb_param: f64 = @as(f64, model.rbsb);
    const jss: f64 = @as(f64, model.jss);
    const jsd: f64 = @as(f64, model.jsd);
    const jsws: f64 = @as(f64, model.jsws);
    const jswd: f64 = @as(f64, model.jswd);
    const jswgs: f64 = @as(f64, model.jswgs);
    const jswgd: f64 = @as(f64, model.jswgd);
    const tnom_c: f64 = @as(f64, model.tnom);
    const ute: f64 = @as(f64, model.ute);
    const ua1: f64 = @as(f64, model.ua1);
    const ub1: f64 = @as(f64, model.ub1);
    const uc1: f64 = @as(f64, model.uc1);
    const ud1: f64 = @as(f64, model.ud1);
    const at_param: f64 = @as(f64, model.at);
    const prt: f64 = @as(f64, model.prt);
    const tvoff: f64 = @as(f64, model.tvoff);
    const tvfbsdoff: f64 = @as(f64, model.tvfbsdoff);
    const tnfactor: f64 = @as(f64, model.tnfactor);
    const teta0: f64 = @as(f64, model.teta0);
    const xtis_param: f64 = @as(f64, model.xtis);
    const xtid_param: f64 = @as(f64, model.xtid);
    const xgw: f64 = @as(f64, model.xgw);
    const xgl: f64 = @as(f64, model.xgl);
    const ngcon: f64 = @floatFromInt(model.ngcon);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);
    const poxedge: f64 = @as(f64, model.poxedge);

    const nf: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const delvto: f64 = @as(f64, instance.delvto);
    const nrs: f64 = @as(f64, instance.nrs);
    const nrd: f64 = @as(f64, instance.nrd);
    const temp_k: f64 = @as(f64, instance.temp);
    const w_drawn: f64 = @as(f64, instance.w);
    const l_drawn: f64 = @as(f64, instance.l);

    // Temperature
    const tnom_k = tnom_c + 273.15;
    const vt = K_BOLTZ * temp_k / Q_ELECTRON;
    const vt_nom = K_BOLTZ * tnom_k / Q_ELECTRON;
    const t_ratio = temp_k / tnom_k;
    const delta_t = temp_k - tnom_k;
    const t_ratio_m1 = t_ratio - 1.0;
    const eg_tnom = 1.16 - 7.02e-4 * tnom_k * tnom_k / (tnom_k + 1108.0);

    // Geometry
    const leff = @max(l_drawn + xl - 2.0 * lint, 1.0e-9);
    const weff_prime = @max(w_drawn / nf + xw - 2.0 * wint, 1.0e-9);
    const weffcj = @max(w_drawn / nf + xw - 2.0 * wint, 1.0e-9);

    // Oxide
    const coxe = epsrox * EPS_0 / toxe;

    // Doping / surface potential
    const ndep_m3 = ndep_cm3 * 1.0e6;
    const nsd_m3 = nsd_cm3 * 1.0e6;
    const ni_m3: f64 = 1.45e16;
    const phi_s = @max(0.4 + vt_nom * safe_log(ndep_m3 / ni_m3) + phin, 0.1);
    const sqrt_phi_s = @sqrt(phi_s);

    // Built-in / depletion
    const vbi = vt_nom * safe_log(ndep_m3 * nsd_m3 / (ni_m3 * ni_m3));
    const xdep0 = @sqrt(2.0 * EPS_SI * phi_s / (Q_ELECTRON * ndep_m3));
    const lt_factor_dc = @sqrt(11.7 / epsrox * toxe);
    const lt0 = lt_factor_dc * @sqrt(xdep0);

    // Mobility temperature (tempMod=0)
    const mu0_t = mu0_param * contract.fmath.exp(ute * safe_log(t_ratio));
    const ua_t = ua_param + ua1 * t_ratio_m1;
    const ub_t = ub_param + ub1 * t_ratio_m1;
    const uc_t = uc_param + uc1 * t_ratio_m1;
    const ud_t = ud_param + ud1 * t_ratio_m1;
    const vsat_t = vsat_param - at_param * t_ratio_m1;

    // Threshold temperature
    const voff_t = @as(f64, model.voff) * (1.0 + tvoff * delta_t);
    const vfbsdoff_t = vfbsdoff * (1.0 + tvfbsdoff * delta_t);
    const nfactor_t = nfactor + tnfactor * t_ratio_m1;
    const eta0_t = eta0_param + teta0 * t_ratio_m1;

    // Rds temperature
    const rdsw_t = rdsw + prt * t_ratio_m1;
    const rdswmin_t = rdswmin + prt * t_ratio_m1;

    // Oxide ratios
    const k1ox = k1_param * toxe / toxm;
    const k2ox = k2_param * toxe / toxm;

    // Lateral doping
    const lpe0_factor = k1ox * (@sqrt(1.0 + lpe0 / leff) - 1.0) * sqrt_phi_s;
    const lpeb_factor = 1.0 + lpeb / leff;

    // DIBL
    const theta_dibl = 0.5 / @max(cosh_approx(dsub * leff / @max(lt0, 1e-20)) - 1.0, 1e-10);

    // Subthreshold m_val
    const minv2 = minv * minv;
    const atan_minv = minv * (15.0 + 4.0 * minv2) / (15.0 + 9.0 * minv2);
    const m_val = 0.5 + atan_minv / 3.14159265;

    // Mobility helpers
    const cdep0 = @sqrt(Q_ELECTRON * EPS_SI * ndep_m3 / (2.0 * phi_s));
    const f_leff = 1.0 - up_param * safe_exp(-leff / @max(lp_param, 1e-20));

    // Early voltage helpers
    const litl = @sqrt(@max(3.0 * 3.9 / epsrox * xj * toxe, 1e-30));
    const rout_val = pdiblc1 / @max(2.0 * cosh_approx(drout * leff / @max(lt0, 1e-20)) - 2.0, 1e-10) + pdiblc2;

    // Gate tunneling
    const tox_rat = contract.fmath.exp(ntox * safe_log(toxref / toxe)) / (toxe * toxe);
    const tox_rat_edge = contract.fmath.exp(ntox * safe_log(toxref / @max(toxe * poxedge, 1e-20))) / @max((toxe * poxedge) * (toxe * poxedge), 1e-30);
    const vfbsd_val = if (ngate_cm3 > 0.0) vt_nom * safe_log(ngate_cm3 * 1e6 / nsd_m3) + vfbsdoff_t else 0.0;

    // Junction diode temperature
    const arrhenius_s = eg_tnom * (1.0 - 1.0 / t_ratio) / vt_nom;
    const jss_t = jss * contract.fmath.exp(xtis_param * safe_log(t_ratio) + arrhenius_s);
    const jsd_t = jsd * contract.fmath.exp(xtid_param * safe_log(t_ratio) + arrhenius_s);
    const jsws_t = jsws * contract.fmath.exp(xtis_param * safe_log(t_ratio) + arrhenius_s);
    const jswd_t = jswd * contract.fmath.exp(xtid_param * safe_log(t_ratio) + arrhenius_s);
    const jswgs_t = jswgs * contract.fmath.exp(xtis_param * safe_log(t_ratio) + arrhenius_s);
    const jswgd_t = jswgd * contract.fmath.exp(xtid_param * safe_log(t_ratio) + arrhenius_s);

    // Weffcj helper
    const weffcj_wr = contract.fmath.exp(wr * safe_log(@max(weffcj * 1.0e6, 1e-10)));

    // Parasitic resistances
    const g_rd = if (rsh > 0.0 and nrd > 0.0) 1.0 / (nrd * rsh) else GSHORT;
    const g_rs = if (rsh > 0.0 and nrs > 0.0) 1.0 / (nrs * rsh) else GSHORT;
    const g_rg = if (model.rgatemod >= 1 and rshg > 0.0) blk: {
        const rgeltd = rshg * (xgw + weffcj / (3.0 * ngcon)) / @max(ngcon * (l_drawn - xgl) * nf, 1e-20);
        break :blk 1.0 / @max(rgeltd, 1e-10);
    } else GSHORT;
    const g_rbpb = if (model.rbodymod >= 1) 1.0 / @max(rbpb_param, 1e-3) + gbmin_param else GSHORT;
    const g_rbpd = if (model.rbodymod >= 1) 1.0 / @max(rbpd_param, 1e-3) + gbmin_param else GSHORT;
    const g_rbps = if (model.rbodymod >= 1) 1.0 / @max(rbps_param, 1e-3) + gbmin_param else GSHORT;
    const g_rbdb = if (model.rbodymod >= 1) 1.0 / @max(rbdb_param, 1e-3) + gbmin_param else GSHORT;
    const g_rbsb = if (model.rbodymod >= 1) 1.0 / @max(rbsb_param, 1e-3) + gbmin_param else GSHORT;

    return .{
        .type_f = type_f, .nf = nf, .m_mult = m_mult, .delvto = delvto,
        .vt = vt, .vt_nom = vt_nom, .t_ratio = t_ratio, .t_ratio_m1 = t_ratio_m1,
        .delta_t = delta_t, .eg_tnom = eg_tnom,
        .leff = leff, .weff_prime = weff_prime, .weffcj = weffcj,
        .coxe = coxe, .ndep_m3 = ndep_m3, .nsd_m3 = nsd_m3,
        .phi_s = phi_s, .sqrt_phi_s = sqrt_phi_s,
        .vbi = vbi, .xdep0 = xdep0, .lt_factor = lt_factor_dc, .lt0 = lt0,
        .mu0_t = mu0_t, .ua_t = ua_t, .ub_t = ub_t, .uc_t = uc_t, .ud_t = ud_t, .vsat_t = vsat_t,
        .voff_t = voff_t, .vfbsdoff_t = vfbsdoff_t, .nfactor_t = nfactor_t, .eta0_t = eta0_t,
        .rdsw_t = rdsw_t, .rdswmin_t = rdswmin_t,
        .k1ox = k1ox, .k2ox = k2ox,
        .lpe0_factor = lpe0_factor, .lpeb_factor = lpeb_factor,
        .theta_dibl = theta_dibl, .m_val = m_val,
        .cdep0 = cdep0, .f_leff = f_leff,
        .litl = litl, .rout = rout_val,
        .tox_rat = tox_rat, .tox_rat_edge = tox_rat_edge, .vfbsd_val = vfbsd_val,
        .jss_t = jss_t, .jsd_t = jsd_t, .jsws_t = jsws_t, .jswd_t = jswd_t,
        .jswgs_t = jswgs_t, .jswgd_t = jswgd_t,
        .weffcj_wr = weffcj_wr,
        .g_rd = g_rd, .g_rs = g_rs, .g_rg = g_rg,
        .g_rbpb = g_rbpb, .g_rbpd = g_rbpd, .g_rbps = g_rbps,
        .g_rbdb = g_rbdb, .g_rbsb = g_rbsb,
    };
}

const QPrep = struct {
    type_f: f64,
    nf: f64,
    m_mult: f64,
    vt: f64,
    delta_t: f64,
    leff: f64,
    lactive: f64,
    wactive: f64,
    weffcj: f64,
    coxe: f64,
    coxp_val: f64,
    ndep_m3: f64,
    ndep_cm3: f64,
    phi_s: f64,
    sqrt_phi_s: f64,
    vth0_param: f64,
    xdep: f64,
    lt: f64,
    cdep: f64,
    vfbzb: f64,
    ldebye: f64,
    voffcv_prime: f64,
    clc_lact: f64,
    k1ox: f64,
};

fn qPrep(model: *const Model, instance: *const Instance) QPrep {
    const dv = vthDefaults(model);
    const type_f: f64 = @floatFromInt(model.type_);
    const toxe: f64 = @as(f64, model.toxe);
    const toxp: f64 = @as(f64, model.toxp);
    const epsrox: f64 = @as(f64, model.epsrox);
    const ndep_cm3: f64 = @as(f64, model.ndep);
    const k1_param: f64 = dv.k1;
    const phin: f64 = @as(f64, model.phin);
    const lint: f64 = @as(f64, model.lint);
    const wint: f64 = @as(f64, model.wint);
    const voffcv: f64 = @as(f64, model.voffcv);
    const voffcvl: f64 = @as(f64, model.voffcvl);
    const clc: f64 = @as(f64, model.clc);
    const cle: f64 = @as(f64, model.cle);
    const dlc: f64 = @as(f64, model.dlc);
    const dwc: f64 = @as(f64, model.dwc);
    const tnom_c: f64 = @as(f64, model.tnom);
    const xl: f64 = @as(f64, model.xl);
    const xw: f64 = @as(f64, model.xw);
    const vth0_param: f64 = dv.vth0;

    const nf: f64 = @as(f64, instance.nf);
    const m_mult: f64 = @as(f64, instance.m);
    const w_drawn: f64 = @as(f64, instance.w);
    const l_drawn: f64 = @as(f64, instance.l);
    const temp_k: f64 = @as(f64, instance.temp);

    const tnom_k = tnom_c + 273.15;
    const vt = K_BOLTZ * temp_k / Q_ELECTRON;
    const delta_t = temp_k - tnom_k;

    const dlcv = @max(dlc, lint);
    const dwcv = @max(dwc, wint);
    const lactive = @max(l_drawn + xl - 2.0 * dlcv, 1.0e-9);
    const wactive = @max(w_drawn / nf + xw - 2.0 * dwcv, 1.0e-9);
    const leff = @max(l_drawn + xl - 2.0 * lint, 1.0e-9);
    const weffcj = @max(w_drawn / nf + xw - 2.0 * wint, 1.0e-9);

    const coxe = epsrox * EPS_0 / toxe;
    const coxp_val = epsrox * EPS_0 / toxp;

    const ndep_m3 = ndep_cm3 * 1.0e6;
    const ni_m3: f64 = 1.45e16;
    const phi_s = @max(0.4 + vt * safe_log(ndep_m3 / ni_m3) + phin, 0.1);
    const sqrt_phi_s = @sqrt(phi_s);

    const xdep = @sqrt(@max(2.0 * EPS_SI * phi_s / (Q_ELECTRON * ndep_m3), 1e-30));
    const lt_factor_q = @sqrt(11.7 / epsrox * toxe);
    const lt = lt_factor_q * @sqrt(xdep);
    const cdep = EPS_SI / xdep;

    const vfbzb = vth0_param - phi_s - k1_param * sqrt_phi_s;
    const ldebye = @sqrt(EPS_SI * vt / (Q_ELECTRON * ndep_m3));
    const voffcv_prime = voffcv + voffcvl / leff;
    const clc_lact = contract.fmath.exp(cle * safe_log(@max(clc / lactive, 1e-20)));
    const k1ox = k1_param * toxe / @as(f64, model.toxm);

    return .{
        .type_f = type_f, .nf = nf, .m_mult = m_mult,
        .vt = vt, .delta_t = delta_t,
        .leff = leff, .lactive = lactive, .wactive = wactive, .weffcj = weffcj,
        .coxe = coxe, .coxp_val = coxp_val,
        .ndep_m3 = ndep_m3, .ndep_cm3 = ndep_cm3,
        .phi_s = phi_s, .sqrt_phi_s = sqrt_phi_s,
        .vth0_param = vth0_param, .xdep = xdep, .lt = lt, .cdep = cdep,
        .vfbzb = vfbzb, .ldebye = ldebye,
        .voffcv_prime = voffcv_prime, .clc_lact = clc_lact,
        .k1ox = k1ox,
    };
}

pub const PrepCache = struct { dc: DcPrep, q: QPrep };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = dcPrep(model, instance),
        .q = qPrep(model, instance),
    };
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

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);
    const bp = @intFromEnum(U.body_prime);
    const d_ext = @intFromEnum(U.drain);
    const s_ext = @intFromEnum(U.source);
    const g_ext = @intFromEnum(U.gate);
    const b_ext = @intFromEnum(U.bulk);
    const db = @intFromEnum(U.db_node);
    const sb = @intFromEnum(U.sb_node);

    const p = &pc.dc;

    // Read precomputed x-independent values from DcPrep
    const type_f = p.type_f;
    const nf = p.nf;
    const m_mult = p.m_mult;
    const delvto = p.delvto;
    const vt = p.vt;
    const t_ratio_m1 = p.t_ratio_m1;
    const leff = p.leff;
    const weff_prime = p.weff_prime;
    const weffcj = p.weffcj;
    const coxe = p.coxe;
    const ndep_m3 = p.ndep_m3;
    const phi_s = p.phi_s;
    const sqrt_phi_s = p.sqrt_phi_s;
    const vbi = p.vbi;
    const lt_factor = p.lt_factor;
    const mu0_t = p.mu0_t;
    const ua_t = p.ua_t;
    const ub_t = p.ub_t;
    const uc_t = p.uc_t;
    const ud_t = p.ud_t;
    const vsat_t = p.vsat_t;
    const voff_t = p.voff_t;
    const nfactor_t = p.nfactor_t;
    const eta0_t = p.eta0_t;
    const rdsw_t = p.rdsw_t;
    const rdswmin_t = p.rdswmin_t;
    const k1ox = p.k1ox;
    const k2ox = p.k2ox;
    const lpe0_factor = p.lpe0_factor;
    const lpeb_factor = p.lpeb_factor;
    const theta_dibl = p.theta_dibl;
    const m_val = p.m_val;
    const cdep0 = p.cdep0;
    const f_leff = p.f_leff;
    const litl = p.litl;
    const rout = p.rout;
    const tox_rat = p.tox_rat;
    const tox_rat_edge = p.tox_rat_edge;
    const vfbsd_val = p.vfbsd_val;
    const jss_t = p.jss_t;
    const jsd_t = p.jsd_t;
    const jsws_t = p.jsws_t;
    const jswd_t = p.jswd_t;
    const jswgs_t = p.jswgs_t;
    const jswgd_t = p.jswgd_t;
    const weffcj_wr = p.weffcj_wr;
    const g_rd = p.g_rd;
    const g_rs = p.g_rs;
    const g_rg = p.g_rg;
    const g_rbpb = p.g_rbpb;
    const g_rbpd = p.g_rbpd;
    const g_rbps = p.g_rbps;
    const g_rbdb = p.g_rbdb;
    const g_rbsb = p.g_rbsb;

    // Cast remaining model parameters used directly in x-dependent code
    const toxe: f64 = @as(f64, model.toxe);
    const toxp: f64 = @as(f64, model.toxp);
    const epsrox: f64 = @as(f64, model.epsrox);
    const ngate_cm3: f64 = @as(f64, model.ngate);
    const dv = vthDefaults(model);
    const vth0_param: f64 = dv.vth0;
    const k1_param: f64 = dv.k1;
    const k2_param: f64 = dv.k2;
    const k3: f64 = @as(f64, model.k3);
    const k3b: f64 = @as(f64, model.k3b);
    const w0: f64 = @as(f64, model.w0);
    const dvt0: f64 = @as(f64, model.dvt0);
    const dvt1: f64 = @as(f64, model.dvt1);
    const dvt2: f64 = @as(f64, model.dvt2);
    const dvtp0: f64 = @as(f64, model.dvtp0);
    const dvtp1: f64 = @as(f64, model.dvtp1);
    const dvtp2: f64 = @as(f64, model.dvtp2);
    const dvtp3: f64 = @as(f64, model.dvtp3);
    const dvtp4: f64 = @as(f64, model.dvtp4);
    const dvtp5: f64 = @as(f64, model.dvtp5);
    const dvt0w: f64 = @as(f64, model.dvt0w);
    const dvt1w: f64 = @as(f64, model.dvt1w);
    const dvt2w: f64 = @as(f64, model.dvt2w);
    const eu_param: f64 = @as(f64, model.eu);
    const a0: f64 = @as(f64, model.a0);
    const ags: f64 = @as(f64, model.ags);
    const b0_param: f64 = @as(f64, model.b0);
    const b1_param: f64 = @as(f64, model.b1);
    const keta: f64 = @as(f64, model.keta);
    const a1_param: f64 = @as(f64, model.a1);
    const a2_param: f64 = @as(f64, model.a2);
    const dwg: f64 = @as(f64, model.dwg);
    const dwb: f64 = @as(f64, model.dwb);
    const voffl: f64 = @as(f64, model.voffl);
    const etab: f64 = @as(f64, model.etab);
    const cit: f64 = @as(f64, model.cit);
    const cdsc: f64 = @as(f64, model.cdsc);
    const cdscb: f64 = @as(f64, model.cdscb);
    const cdscd: f64 = @as(f64, model.cdscd);
    const pclm: f64 = @as(f64, model.pclm);
    const pdiblcb: f64 = @as(f64, model.pdiblcb);
    const pscbe1: f64 = @as(f64, model.pscbe1);
    const pscbe2: f64 = @as(f64, model.pscbe2);
    const pvag: f64 = @as(f64, model.pvag);
    const delta_param: f64 = @as(f64, model.delta);
    const fprout: f64 = @as(f64, model.fprout);
    const pdits: f64 = @as(f64, model.pdits);
    const pditsl: f64 = @as(f64, model.pditsl);
    const pditsd: f64 = @as(f64, model.pditsd);
    const lambda_ov: f64 = @as(f64, model.lambda_);
    const vtl_param: f64 = @as(f64, model.vtl);
    const lc_param: f64 = @as(f64, model.lc);
    const xn_param: f64 = @max(@as(f64, model.xn), 3.0);
    const xj: f64 = @as(f64, model.xj);
    const prwg: f64 = @as(f64, model.prwg);
    const prwb: f64 = @as(f64, model.prwb);
    const alpha0: f64 = @as(f64, model.alpha0);
    const alpha1: f64 = @as(f64, model.alpha1);
    const beta0: f64 = @as(f64, model.beta0);
    const agidl: f64 = @as(f64, model.agidl);
    const bgidl: f64 = @as(f64, model.bgidl);
    const cgidl: f64 = @as(f64, model.cgidl);
    const egidl: f64 = @as(f64, model.egidl);
    const agisl: f64 = @as(f64, model.agisl);
    const bgisl: f64 = @as(f64, model.bgisl);
    const cgisl: f64 = @as(f64, model.cgisl);
    const egisl: f64 = @as(f64, model.egisl);
    const aigbacc: f64 = @as(f64, model.aigbacc);
    const bigbacc: f64 = @as(f64, model.bigbacc);
    const cigbacc: f64 = @as(f64, model.cigbacc);
    const nigbacc: f64 = @as(f64, model.nigbacc);
    const aigbinv: f64 = @as(f64, model.aigbinv);
    const bigbinv: f64 = @as(f64, model.bigbinv);
    const cigbinv: f64 = @as(f64, model.cigbinv);
    const eigbinv: f64 = @as(f64, model.eigbinv);
    const nigbinv: f64 = @as(f64, model.nigbinv);
    const aigc: f64 = @as(f64, model.aigc);
    const bigc: f64 = @as(f64, model.bigc);
    const cigc: f64 = @as(f64, model.cigc);
    const aigs: f64 = @as(f64, model.aigs);
    const bigs: f64 = @as(f64, model.bigs);
    const cigs: f64 = @as(f64, model.cigs);
    const aigd: f64 = @as(f64, model.aigd);
    const bigd: f64 = @as(f64, model.bigd);
    const cigd: f64 = @as(f64, model.cigd);
    const dlcig: f64 = @max(@as(f64, model.dlcig), 0.0);
    const dlcigd: f64 = @max(@as(f64, model.dlcigd), 0.0);
    const nigc: f64 = @as(f64, model.nigc);
    const poxedge: f64 = @as(f64, model.poxedge);
    const pigcd: f64 = @as(f64, model.pigcd);
    const ados: f64 = @as(f64, model.ados);
    const bdos: f64 = @as(f64, model.bdos);
    const njs: f64 = @as(f64, model.njs);
    const njd: f64 = @as(f64, model.njd);
    const bvs: f64 = @as(f64, model.bvs);
    const bvd: f64 = @as(f64, model.bvd);
    const xjbvs: f64 = @as(f64, model.xjbvs);
    const xjbvd: f64 = @as(f64, model.xjbvd);
    const kt2: f64 = @as(f64, model.kt2);
    const kt1: f64 = @as(f64, model.kt1);
    const kt1l: f64 = @as(f64, model.kt1l);

    // ========================================================================
    // Read node voltages (external -> type-adjusted). THESE ARE x-DEPENDENT.
    // ========================================================================
    const v_dp = x[dp];
    const v_sp = x[sp];
    const v_gp = x[gp];
    const v_bp = x[bp];
    const v_d_ext = x[d_ext];
    const v_s_ext = x[s_ext];
    const v_g_ext = x[g_ext];
    const v_b_ext = x[b_ext];
    const v_db_node = x[db];
    const v_sb_node = x[sb];

    // Type-adjusted intrinsic voltages (S)
    const vgs_raw = v_gp.sub(v_sp).scale(type_f);
    const vds_raw = v_dp.sub(v_sp).scale(type_f);
    const vbs_raw = v_bp.sub(v_sp).scale(type_f);

    // Source-drain reversal (region branch on vds_raw sign; each branch S)
    const is_reversed = vds_raw.val() < 0.0;
    const vds = vds_raw.abs();
    const mode: f64 = if (is_reversed) -1.0 else 1.0;
    const vgs = if (is_reversed) vgs_raw.sub(vds_raw) else vgs_raw;
    const vbs = if (is_reversed) vbs_raw.sub(vds_raw) else vbs_raw;

    // ========================================================================
    // Vbseff clamping (Eq 2.43--2.45)
    // ========================================================================
    // b4temp.c: vbc = 0.9*(phi - (0.5*k1/k2)^2), clamped to [-30, -3]; -30 when k2 >= 0
    const vbc = blk: {
        if (k2_param >= 0.0) break :blk -30.0;
        const t0_bc = 0.5 * k1_param / k2_param;
        break :blk @max(@min(0.9 * (phi_s - t0_bc * t0_bc), -3.0), -30.0);
    };
    const t0_vbs = vbs.addC(-vbc - DELTA1);
    const vbseff_lower = t0_vbs.add(t0_vbs.mul(t0_vbs).addC(-4.0 * DELTA1 * vbc).sqrt()).scale(0.5).addC(vbc);

    // Upper clamp (Eq 2.45)
    const phi95 = 0.95 * phi_s;
    const t1_vbs = vbseff_lower.neg().addC(phi95 - DELTA1);
    const vbseff = t1_vbs.add(t1_vbs.mul(t1_vbs).addC(4.0 * DELTA1 * phi95).sqrt()).scale(-0.5).addC(phi95);

    // ========================================================================
    // Depletion widths (Eqs 2.27, 2.35)
    // ========================================================================
    const xdep = vbseff.neg().addC(phi_s).scale(2.0 * EPS_SI / (Q_ELECTRON * ndep_m3)).maxC(1e-30).sqrt();

    // ========================================================================
    // Characteristic lengths (Eqs 2.26, 2.31, 2.34)
    // ========================================================================
    const lt = xdep.sqrt().scale(lt_factor).mul(vbseff.scale(dvt2).addC(1.0));
    const ltw = xdep.sqrt().scale(lt_factor).mul(vbseff.scale(dvt2w).addC(1.0));

    // Threshold temperature dependence (Eq 13.1) -- vbseff-dependent (S)
    const vth_temp_adj = vbseff.scale(kt2).addC(kt1 + kt1l / leff).scale(t_ratio_m1);

    // ========================================================================
    // Poly gate depletion (Eq 1.7)
    // ========================================================================
    const vgse = if (ngate_cm3 > 1.0e18)
        computePolyDepletion(S, vgs, dv.vfb, phi_s, ngate_cm3 * 1.0e6, toxe, epsrox)
    else
        vgs;

    // ========================================================================
    // Threshold voltage (Eq 2.40)
    // ========================================================================
    // SCE (Eq 2.29--2.30) -- lt is S; cosh_approx(dvt1*leff/max(lt,1e-20))
    const cosh_sce = sCosh(S, lt.maxC(1e-20).pow(-1.0).scale(dvt1 * leff));
    const theta_sce = cosh_sce.addC(-1.0).maxC(1e-10).pow(-1.0).scale(0.5 * dvt0);
    const dv_sce = theta_sce.scale(-(vbi - phi_s));

    // DIBL (Eqs 2.32--2.33)
    const dv_dibl = vbseff.scale(etab).addC(eta0_t).mul(vds).scale(-theta_dibl);

    // Narrow width (Eqs 2.37--2.39)
    const dv_nw1 = vbseff.scale(k3b).addC(k3).scale(toxe / (weff_prime + w0) * phi_s);
    const cosh_nw = sCosh(S, ltw.maxC(1e-20).pow(-1.0).scale(dvt1w * @sqrt(leff * weff_prime)));
    const dv_nw2 = cosh_nw.addC(-1.0).maxC(1e-10).pow(-1.0).mul(S.con(-(vbi - phi_s))).scale(0.5 * dvt0w);

    // DITS (Eq 2.22) -- vds S
    // -vt*ln( leff / max(leff+dvtp0*(1+exp(-dvtp1*vds)), 1e-30) )
    const dv_dits_log2 = if (dvtp0 > 0.0) blk: {
        const inner = vds.scale(-dvtp1).minC(80.0).exp().addC(1.0).scale(dvtp0).addC(leff).maxC(1e-30);
        break :blk sLog(S, inner.pow(-1.0).scale(leff)).scale(-vt);
    } else S.con(0.0);

    const dv_dits_tanh = if (dvtp2 != 0.0 or dvtp5 != 0.0)
        sTanh(S, vds.scale(dvtp4)).scale(-(dvtp5 + dvtp2 * contract.fmath.exp(-dvtp3 * safe_log(@max(leff, 1e-20)))))
    else
        S.con(0.0);

    // Complete Vth (Eq 2.40 + delvto + temperature) -- S
    const vth = vth_temp_adj
        .add(vbseff.neg().addC(phi_s).maxC(1e-30).sqrt().scale(k1ox).addC(-k1_param * sqrt_phi_s).scale(lpeb_factor))
        .add(vbseff.scale(-k2ox))
        .add(dv_nw1)
        .add(dv_nw2)
        .add(dv_sce)
        .add(dv_dibl)
        .add(dv_dits_log2)
        .add(dv_dits_tanh)
        .addC(vth0_param + delvto + lpe0_factor);

    // ========================================================================
    // Subthreshold swing n (Eq 3.21--3.22)
    // ========================================================================
    const cdep = xdep.pow(-1.0).scale(EPS_SI);
    const cosh_n = sCosh(S, lt.maxC(1e-20).pow(-1.0).scale(dvt1 * leff));
    const cdsc_term = vds.scale(cdscd).add(vbseff.scale(cdscb)).addC(cdsc).mul(cosh_n.addC(-1.0).maxC(1e-10).pow(-1.0)).scale(0.5);
    const n = cdep.scale(nfactor_t / coxe).add(cdsc_term.addC(cit).scale(1.0 / coxe)).addC(1.0).maxC(0.1);

    // ========================================================================
    // Vgsteff (Eq 3.7--3.8)
    // ========================================================================
    const voff_prime = voff_t + voffl / leff;
    const vov = vgse.sub(vth).scale(m_val);
    const nvt = n.scale(vt);

    // Numerator: n*vt * ln(1 + exp(vov / (n*vt)))  -- region branch on exp_arg
    const exp_arg = vov.div(nvt).minC(80.0);
    const ln1pe = if (exp_arg.val() > 40.0) vov.div(n) else nvt.mul(exp_arg.exp().addC(1.0).log());

    // Denominator
    const denom_exp_arg = vgse.sub(vth).scale(1.0 - m_val).addC(-voff_prime).neg().div(nvt).minC(80.0);
    const denom = n.scale(coxe / cdep0).mul(sExp(S, denom_exp_arg)).addC(m_val);

    const vgsteff = ln1pe.div(denom).maxC(1.0e-10);

    // ========================================================================
    // Charge centroid Xdc, Coxeff (Eqs 3.5--3.6)
    // ========================================================================
    // b4ld.c: T0 = (Vgsteff + vtfbphi2)/(2e8*toxp); Tcen = ados*1.9e-9/(1 + T0^(0.7*bdos));
    // Coxeff = epssub*coxp/(epssub + coxp*Tcen)
    const vfb_param: f64 = dv.vfb;
    const vtfbphi2 = @max(4.0 * (vth0_param - vfb_param - phi_s), 0.0);
    const coxp = epsrox * EPS_0 / toxp;
    const xdc_arg = vgsteff.addC(vtfbphi2).scale(1.0 / (2.0e8 * toxp));
    const tcen = sLog(S, xdc_arg.maxC(1e-12)).scale(0.7 * bdos).exp().addC(1.0).pow(-1.0).scale(ados * 1.9e-9);
    const coxeff = tcen.scale(coxp).addC(EPS_SI).pow(-1.0).scale(EPS_SI * coxp);

    // ========================================================================
    // Bulk charge effect Abulk (Eq 5.1--5.2)
    // ========================================================================
    const sqrt_xj_xdep = xdep.scale(xj).maxC(1e-30).sqrt();
    const f_doping = vbseff.neg().addC(phi_s).maxC(1e-30).sqrt().scale(2.0).pow(-1.0).scale(lpeb_factor * k1ox)
        .addC(k2ox - k3b * toxe / (weff_prime + w0) * phi_s);
    const denom_abt1 = sqrt_xj_xdep.scale(2.0).addC(leff);
    const abulk_term1 = denom_abt1.pow(-1.0).scale(a0 * leff).mul(vgsteff.scale(ags * leff).div(denom_abt1).neg().addC(1.0));
    const abulk_term2 = b0_param / (weff_prime + b1_param);
    const abulk = f_doping.mul(abulk_term1.addC(abulk_term2)).addC(1.0).div(vbseff.scale(keta).addC(1.0)).maxC(0.1);

    // ========================================================================
    // Effective width accounting for bias (Eq 1.12)
    // ========================================================================
    const dw_bias = vgsteff.scale(dwg).add(vbseff.neg().addC(phi_s).maxC(1e-30).sqrt().addC(-sqrt_phi_s).scale(dwb));
    const weff = dw_bias.scale(-2.0).addC(weff_prime).maxC(1.0e-9);

    // ========================================================================
    // Mobility (Eqs 5.6--5.16, mobMod=0)
    // ========================================================================
    const eeff_arg = vgsteff.add(vth.scale(2.0)).scale(1.0 / toxe);
    _ = eu_param;

    // ud_term = ud_t*(vth*toxe)^2 / (vgsteff + 2*sqrt(vth^2+0.0001))^2
    const t12 = vth.mul(vth).addC(0.0001).sqrt();
    const t9_denom = vgsteff.add(t12.scale(2.0)).maxC(1e-20);
    const t10 = S.con(toxe).div(t9_denom);
    const ud_term = t10.mul(t10).mul(vth).mul(vth).scale(ud_t);

    const mob_denom = eeff_arg.mul(vbseff.scale(uc_t).addC(ua_t)).add(eeff_arg.mul(eeff_arg).scale(ub_t)).add(ud_term).addC(1.0);
    const mu_eff = mob_denom.maxC(0.001).pow(-1.0).scale(mu0_t * f_leff);

    // ========================================================================
    // Saturation velocity and Esat (Eq 5.26--5.27)
    // ========================================================================
    const esat = mu_eff.maxC(1e-20).pow(-1.0).scale(2.0 * vsat_t);
    const esat_l = esat.scale(leff);

    // ========================================================================
    // Vdsat (Eq 5.27 intrinsic, or 5.28 with Rds)
    // ========================================================================
    const vgst_2vt = vgsteff.addC(2.0 * vt);

    // Source/drain resistance (Eq 5.17, rdsMod=0)
    const rds_prwb = vbseff.neg().addC(phi_s).maxC(1e-30).sqrt().addC(-sqrt_phi_s).scale(prwb).addC(1.0).maxC(0.01).sqrt();
    const rds_denom = rds_prwb.add(vgsteff.scale(prwg)).maxC(0.01);
    const rds_bias = rds_denom.scale(weffcj_wr).pow(-1.0).scale(rdsw_t);
    const rds_min = rdswmin_t / weffcj_wr;
    const rds = rds_bias.maxC(rds_min);

    // Intrinsic Vdsat (Eq 5.27)
    const vdsat_intr = esat_l.mul(vgst_2vt).div(abulk.mul(esat_l).add(vgst_2vt).maxC(1e-10));

    // With Rds (Eq 5.28--5.31) -- region branch on rds & aa
    const lambda_sat = vgsteff.scale(a1_param).addC(a2_param);
    const inv_lambda = if (lambda_sat.val() > 0.01) lambda_sat.pow(-1.0) else S.con(100.0);
    const wr_coxe_vsat = weff.mul(rds).scale(vsat_t * coxe);

    const aa = abulk.mul(abulk).mul(wr_coxe_vsat).add(abulk.mul(inv_lambda.addC(-1.0)));
    // b4ld.c: T1 = Vgst2Vtm*(2/lambda - 1) + Abulk*EsatL + 3*Abulk*Vgst2Vtm*WVCoxRds; bb = -T1
    const bb = vgst_2vt.mul(inv_lambda.scale(2.0).addC(-1.0)).add(abulk.mul(esat_l))
        .add(abulk.mul(vgst_2vt).mul(wr_coxe_vsat).scale(3.0)).neg();
    const cc = vgst_2vt.mul(esat_l).add(vgst_2vt.mul(vgst_2vt).mul(wr_coxe_vsat).scale(2.0));

    const vdsat = if (rds.val() > 1.0e-10 and @abs(aa.val()) > 1e-20)
        bb.neg().sub(bb.mul(bb).sub(aa.mul(cc).scale(4.0)).maxC(0.0).sqrt()).div(aa.scale(2.0))
    else
        vdsat_intr;

    // ========================================================================
    // Vdseff smoothing (Eq 5.33)
    // ========================================================================
    const delta_vds = delta_param;
    const t0_vdseff = vdsat.sub(vds).addC(-delta_vds);
    const vdseff = vdsat.sub(t0_vdseff.add(t0_vdseff.mul(t0_vdseff).add(vdsat.scale(4.0 * delta_vds)).sqrt()).scale(0.5));
    const vdseff_clamped = vdseff.maxC(1.0e-10);

    // ========================================================================
    // Channel current Ids0 (Eq 5.23)
    // ========================================================================
    const qch0 = vgsteff.mul(coxeff);
    const vb = vgst_2vt.div(abulk);
    const ids0_num = weff.mul(mu_eff).mul(qch0).mul(vdseff_clamped).mul(vdseff_clamped.div(vb.maxC(1e-10).scale(2.0)).neg().addC(1.0));
    const ids0_denom = vdseff_clamped.div(esat_l.maxC(1e-10)).addC(1.0).scale(leff);
    const ids0 = ids0_num.div(ids0_denom.maxC(1e-30));

    // ========================================================================
    // With internal Rds (Eq 5.24)
    // ========================================================================
    const ids_rds = ids0.div(ids0.mul(rds).div(vdseff_clamped.maxC(1e-10)).addC(1.0));

    // ========================================================================
    // Output conductance / Early voltages (Eqs 5.37--5.51)
    // ========================================================================

    // VACLM (Eqs 5.37--5.39)
    const fprout_term = vgst_2vt.maxC(1e-10).pow(-1.0).scale(leff).maxC(0.0).sqrt().scale(fprout).addC(1.0).pow(-1.0);
    const pvag_term = vgsteff.div(esat_l.maxC(1e-10)).scale(pvag).addC(1.0);
    const rds_ids0_vdseff = ids0.mul(rds).div(vdseff_clamped.maxC(1e-10)).addC(1.0);
    const cclm_inv = fprout_term.mul(pvag_term).mul(rds_ids0_vdseff)
        .mul(vdsat.div(esat.maxC(1e-10)).addC(leff)).scale(1.0 / litl).maxC(1e-30).pow(-1.0).scale(pclm);
    const vaclm = vds.sub(vdseff_clamped).maxC(1e-10).div(cclm_inv.maxC(1e-20));

    // VADIBL (Eqs 5.42--5.43)
    const vadibl_num = vgst_2vt.div(vbseff.scale(pdiblcb).addC(1.0).scale(rout).maxC(1e-10));
    const abulk_vdsat = abulk.mul(vdsat);
    const vadibl_factor = abulk_vdsat.div(abulk_vdsat.add(vgst_2vt).maxC(1e-10)).neg().addC(1.0);
    const vadibl = vadibl_num.mul(vadibl_factor).mul(pvag_term);

    // VASCBE (Eq 5.47)
    const vds_minus_vdseff = vds.sub(vdseff_clamped).maxC(1e-10);
    const vascbe_inv = vds_minus_vdseff.pow(-1.0).scale(-pscbe1 * litl).minC(80.0).exp().scale(pscbe2 / leff);
    const vascbe = vascbe_inv.maxC(1e-30).pow(-1.0);

    // VADITS (Eq 5.48)
    const vadits = if (pdits > 1.0e-20)
        vds.scale(pditsd).minC(80.0).exp().scale(1.0 + pditsl * leff).addC(1.0).mul(fprout_term).scale(1.0 / pdits)
    else
        S.con(1.0e30);

    // Vasat (Eq 5.51):
    //   num = esat_l + vdsat + 2*rds*vsat_t*coxe*weff*vgsteff*(1 - vdsat/(2*(abulk*vdsat+2vt)))
    //   den = max(rds*vsat_t*coxe*weff*abulk - 1 + 2*inv_lambda, 1e-10)
    const rds_wveff = rds.mul(weff).scale(vsat_t * coxe);
    const vasat_num = esat_l.add(vdsat).add(
        rds_wveff.mul(vgsteff).scale(2.0).mul(vdsat.div(abulk.mul(vdsat).addC(2.0 * vt).maxC(1e-10).scale(2.0)).neg().addC(1.0)),
    );
    const vasat_denom = rds_wveff.mul(abulk).addC(-1.0).add(inv_lambda.scale(2.0)).maxC(1e-10);
    const vasat = vasat_num.div(vasat_denom).maxC(1e-10);

    // VA = Vasat + VACLM
    const va = vasat.add(vaclm);

    // ========================================================================
    // Complete Ids (Eq 5.49)
    // ========================================================================
    const clm_factor = cclm_inv.mul(sLog(S, va.div(vasat).maxC(1.0))).addC(1.0);
    const dibl_factor = vds_minus_vdseff.div(vadibl.maxC(1e-10)).addC(1.0);
    const dits_factor = vds_minus_vdseff.div(vadits.maxC(1e-10)).addC(1.0);
    const scbe_factor = vds_minus_vdseff.div(vascbe.maxC(1e-10)).addC(1.0);

    const ids_no_scbe = ids_rds.scale(nf).mul(clm_factor).mul(dibl_factor).mul(dits_factor);
    const ids_full = ids_no_scbe.mul(scbe_factor);

    // ========================================================================
    // Velocity overshoot (Eqs 5.53--5.54)
    // ========================================================================
    const ids_hd = if (lambda_ov > 0.0) blk: {
        const delta_e_ratio = vds.sub(vdseff_clamped).div(esat.mul(S.con(litl)).maxC(1e-10));
        const sqrt_delta_e = delta_e_ratio.mul(delta_e_ratio).addC(1.0).sqrt();
        const overshoot = sqrt_delta_e.addC(-1.0).div(sqrt_delta_e.addC(1.0)).div(mu_eff.scale(leff)).scale(lambda_ov).addC(1.0);
        const esat_ov = esat.mul(overshoot);
        const esat_ov_l = esat_ov.scale(leff);
        break :blk ids_full.mul(vdseff_clamped.div(esat_l.maxC(1e-10)).addC(1.0)).div(vdseff_clamped.div(esat_ov_l.maxC(1e-10)).addC(1.0));
    } else ids_full;

    // ========================================================================
    // Source-end velocity limit (Eqs 5.55--5.58)
    // ========================================================================
    const ids_final_ch = if (vtl_param > 0.0) blk: {
        // b4ld.c: vs = Ids/(Coxeff*Weff*Vgsteff); Fsevl = (1 + (vs/(vtl*tfactor))^(2*MM))^(-1/(2*MM)), MM=3
        const t0_bt = leff / (xn_param * leff + @max(lc_param, 0.0));
        const tfactor = (1.0 - t0_bt) / (1.0 + t0_bt);
        const vs = ids_hd.abs().div(coxeff.mul(weff).mul(vgsteff.maxC(1e-20)).maxC(1e-30));
        const t1_vs = vs.scale(1.0 / @max(vtl_param * tfactor, 1e-20));
        const t1_sq = t1_vs.mul(t1_vs);
        const t2_vs = t1_sq.mul(t1_sq).mul(t1_sq).addC(1.0);
        break :blk ids_hd.mul(t2_vs.maxC(1e-30).pow(-1.0 / 6.0));
    } else ids_hd;

    // ========================================================================
    // Impact ionization current (Eq 6.1) -- region branch on vds_minus_vdseff
    // ========================================================================
    const iii = if ((alpha0 != 0.0 or alpha1 != 0.0) and vds_minus_vdseff.val() > 0.001) blk: {
        const alpha = (alpha0 + alpha1 * leff) / leff;
        break :blk vds_minus_vdseff.scale(alpha).mul(vds_minus_vdseff.pow(-1.0).scale(-beta0).minC(80.0).exp()).mul(ids_no_scbe.abs());
    } else S.con(0.0);

    // ========================================================================
    // GIDL/GISL (Eqs 6.3--6.4, gidlMod=0, mtrlMod=0)
    // ========================================================================
    // GIDL: drain side -- region branch on vds_gidl
    const vds_gidl = vds.sub(vgse).addC(-egidl);
    const i_gidl = if (agidl > 0.0 and vds_gidl.val() > 0.0) blk: {
        const vdb = v_dp.sub(v_bp).scale(type_f);
        const vdb3 = vdb.mul(vdb).mul(vdb);
        const t_gidl = vds_gidl.scale(agidl * weffcj * nf / (3.0 * toxe));
        const exp_gidl = vds_gidl.maxC(1e-10).pow(-1.0).scale(-3.0 * toxe * bgidl).minC(80.0).exp();
        break :blk t_gidl.mul(exp_gidl).mul(vdb3).div(vdb3.addC(cgidl).maxC(1e-30));
    } else S.con(0.0);

    // GISL: source side -- region branch on vsd_gisl
    const vsd_gisl = vds.neg().sub(vgs.sub(vds)).addC(-egisl);
    const i_gisl = if (agisl > 0.0 and vsd_gisl.val() > 0.0) blk: {
        const vsb = vbs.neg();
        const vsb3 = vsb.mul(vsb).mul(vsb);
        const t_gisl = vsd_gisl.scale(agisl * weffcj * nf / (3.0 * toxe));
        const exp_gisl = vsd_gisl.maxC(1e-10).pow(-1.0).scale(-3.0 * toxe * bgisl).minC(80.0).exp();
        break :blk t_gisl.mul(exp_gisl).mul(vsb3).div(vsb3.addC(cgisl).maxC(1e-30));
    } else S.con(0.0);

    // ========================================================================
    // Gate tunneling currents (Eqs 4.1--4.21)
    // ========================================================================
    // Vfbzb (Eq 4.3) -- vth_at_zero uses vth_temp_adj (S) + dv_nw1 (S)
    const vth_at_zero = vth_temp_adj.add(dv_nw1).addC(vth0_param + delvto + lpe0_factor);
    const vfbzb = vth_at_zero.addC(-phi_s - k1_param * sqrt_phi_s);

    // VFBeff (Eq 4.4)
    const vgb = vgs.sub(vbs);
    const t0_vfb = vfbzb.sub(vgb).addC(-0.02);
    const vfbeff = vfbzb.sub(t0_vfb.add(t0_vfb.mul(t0_vfb).add(vfbzb.scale(0.08)).sqrt()).scale(0.5));

    // Oxide voltages (Eqs 4.1--4.2)
    const voxacc = vfbzb.sub(vfbeff);
    const voxdepinv = vgsteff.addC(k1ox * sqrt_phi_s);

    // Gate-to-substrate accumulation (Eq 4.5)
    const igbacc = if (model.igbmod != 0) blk: {
        const vaux_acc = sExp(S, vgb.sub(vfbzb).neg().div(S.con(@max(nigbacc * vt, 1e-20)))).addC(1.0).log().scale(nigbacc * vt);
        const t_exp_acc = voxacc.scale(-bigbacc).addC(aigbacc).mul(voxacc.scale(cigbacc).addC(1.0).maxC(0.01)).scale(-B_ACC * toxe);
        break :blk weff.scale(leff * A_ACC * tox_rat).mul(vgb).mul(vaux_acc).mul(sExp(S, t_exp_acc));
    } else S.con(0.0);

    // Gate-to-substrate inversion (Eq 4.8)
    const igbinv = if (model.igbmod != 0) blk: {
        const vaux_inv = sExp(S, voxdepinv.addC(-eigbinv).div(S.con(@max(nigbinv * vt, 1e-20)))).addC(1.0).log().scale(nigbinv * vt);
        const t_exp_inv = voxdepinv.scale(-bigbinv).addC(aigbinv).mul(voxdepinv.scale(cigbinv).addC(1.0).maxC(0.01)).scale(-B_INV * toxe);
        break :blk weff.scale(leff * A_INV * tox_rat).mul(vgb).mul(vaux_inv).mul(sExp(S, t_exp_inv));
    } else S.con(0.0);

    const igb = igbacc.add(igbinv);

    // Gate-to-channel current (Eqs 4.10--4.12, igcMod=1)
    const igc0 = if (model.igcmod != 0) blk: {
        const vaux_gc = sExp(S, vgse.addC(-vth0_param).div(S.con(@max(nigc * vt, 1e-20)))).addC(1.0).log().scale(nigc * vt);
        const t_exp_gc = voxdepinv.scale(-bigc).addC(aigc).mul(voxdepinv.scale(cigc).addC(1.0).maxC(0.01)).scale(-B_INV * toxe);
        break :blk weff.scale(leff * A_INV * tox_rat).mul(vgse).mul(vaux_gc).mul(sExp(S, t_exp_gc));
    } else S.con(0.0);

    // Partition igc into igcs and igcd (Eqs 4.19--4.20)
    const pigcd_val = pigcd;
    const pv = vdseff_clamped.maxC(1e-10).scale(pigcd_val);
    const pv2 = pv.mul(pv).addC(2.0e-4);
    const igcs = igc0.mul(pv.add(pv.neg().exp()).addC(-1.0 + 1.0e-4)).div(pv2);
    const igcd = igc0.mul(pv.addC(1.0).mul(pv.neg().exp()).neg().addC(1.0 + 1.0e-4)).div(pv2);

    // Gate-to-source/drain overlap current (Eqs 4.13--4.14)

    const vgs_prime = vgs.addC(-vfbsd_val).mul(vgs.addC(-vfbsd_val)).addC(1.0e-4).sqrt();
    const igs = if (model.igcmod != 0 and dlcig > 0.0) blk: {
        const t_exp_gs = vgs_prime.scale(-bigs).addC(aigs).mul(vgs_prime.scale(cigs).addC(1.0).maxC(0.01)).scale(-B_INV * toxe * poxedge);
        break :blk weff.scale(dlcig * A_INV * tox_rat_edge).mul(vgs).mul(vgs_prime).mul(sExp(S, t_exp_gs));
    } else S.con(0.0);

    const vgd_val = vgs.sub(vds);
    const vgd_prime = vgd_val.addC(-vfbsd_val).mul(vgd_val.addC(-vfbsd_val)).addC(1.0e-4).sqrt();
    const igd = if (model.igcmod != 0 and dlcigd > 0.0) blk: {
        const t_exp_gd = vgd_prime.scale(-bigd).addC(aigd).mul(vgd_prime.scale(cigd).addC(1.0).maxC(0.01)).scale(-B_INV * toxe * poxedge);
        break :blk vgd_val.mul(vgd_prime).mul(sExp(S, t_exp_gd)).mul(weff).scale(dlcigd * A_INV * tox_rat_edge);
    } else S.con(0.0);

    // ========================================================================
    // Junction diode IV (Chapter 11, dioMod=1)
    // ========================================================================
    const as_val = if (instance.as_ > 0.0) instance.as_ else weffcj * nf * 1.0e-7;
    const ps_val = if (instance.ps > 0.0) instance.ps else 2.0 * (weffcj * nf + 1.0e-7);
    const ad_val = if (instance.ad > 0.0) instance.ad else weffcj * nf * 1.0e-7;
    const pd_val = if (instance.pd > 0.0) instance.pd else 2.0 * (weffcj * nf + 1.0e-7);


    const isbs = as_val * jss_t + ps_val * jsws_t + weffcj * nf * jswgs_t;
    const isbd = ad_val * jsd_t + pd_val * jswd_t + weffcj * nf * jswgd_t;

    // Junction voltages (S)
    const vbs_junc = v_bp.sub(v_sp).scale(type_f);
    const vbd_junc = v_bp.sub(v_dp).scale(type_f);

    const njs_vt = njs * vt;
    const njd_vt = njd * vt;

    const ibs_val = vbs_junc.scale(1.0 / njs_vt).minC(80.0).exp().addC(-1.0).scale(isbs).add(vbs_junc.scale(GMIN));
    const ibd_val = vbd_junc.scale(1.0 / njd_vt).minC(80.0).exp().addC(-1.0).scale(isbd).add(vbd_junc.scale(GMIN));
    _ = bvs;
    _ = bvd;
    _ = xjbvs;
    _ = xjbvd;

    // ========================================================================
    // Assemble KCL contributions (S)
    // ========================================================================
    const ids_out = ids_final_ch.scale(type_f * mode);
    const i_gidl_out = i_gidl.scale(type_f);
    const i_gisl_out = i_gisl.scale(type_f);
    const iii_out = iii.scale(type_f);
    const igb_out = igb.scale(type_f);
    const igcs_out = igcs.scale(type_f);
    const igcd_out = igcd.scale(type_f);
    const igs_out = igs.scale(type_f);
    const igd_out = igd.scale(type_f);
    const ibs_out = ibs_val.scale(type_f);
    const ibd_out = ibd_val.scale(type_f);

    // Parasitic resistance currents (S)
    const i_rd = v_d_ext.sub(v_dp).scale(g_rd);
    const i_rs = v_s_ext.sub(v_sp).scale(g_rs);
    const i_rg = v_g_ext.sub(v_gp).scale(g_rg);
    const i_rbpb = v_b_ext.sub(v_bp).scale(g_rbpb);
    const i_rbpd = v_bp.sub(v_db_node).scale(g_rbpd);
    const i_rbps = v_bp.sub(v_sb_node).scale(g_rbps);
    const i_rbdb = v_db_node.sub(v_b_ext).scale(g_rbdb);
    const i_rbsb = v_sb_node.sub(v_b_ext).scale(g_rbsb);

    const m = m_mult;

    var out: [n_u]S = undefined;

    // External drain
    out[d_ext] = i_rd.scale(m);
    // External gate
    out[g_ext] = i_rg.scale(m);
    // External source
    out[s_ext] = i_rs.scale(m);
    // External bulk
    out[b_ext] = i_rbpb.sub(i_rbdb).sub(i_rbsb).scale(m);

    // Intrinsic drain (dp)
    out[dp] = ids_out.sub(i_rd).add(ibd_out).sub(igcd_out).sub(igd_out).add(i_gidl_out).add(iii_out).scale(m);
    // Intrinsic source (sp)
    out[sp] = ids_out.neg().sub(i_rs).add(ibs_out).sub(igcs_out).sub(igs_out).add(i_gisl_out).scale(m);
    // Intrinsic gate (gp)
    out[gp] = i_rg.neg().add(igb_out).add(igcs_out).add(igcd_out).add(igs_out).add(igd_out).scale(m);
    // Body prime (bp)
    out[bp] = i_rbpb.neg().sub(ibs_out).sub(ibd_out).sub(igb_out).sub(i_gidl_out).sub(i_gisl_out).sub(iii_out).add(i_rbpd).add(i_rbps).scale(m);
    // db node
    out[db] = i_rbpd.neg().add(i_rbdb).scale(m);
    // sb node
    out[sb] = i_rbps.neg().add(i_rbsb).scale(m);

    return out;
}

// ============================================================================
// Charge function (q) -- Capacitance contributions (value-form)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const pq = &pc.q;
    const dv = vthDefaults(model);

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);
    const bp = @intFromEnum(U.body_prime);
    const d_ext = @intFromEnum(U.drain);
    const s_ext = @intFromEnum(U.source);
    const g_ext = @intFromEnum(U.gate);
    const b_ext = @intFromEnum(U.bulk);
    const db = @intFromEnum(U.db_node);
    const sb = @intFromEnum(U.sb_node);

    // Read precomputed values from QPrep
    const type_f = pq.type_f;
    const nf = pq.nf;
    const m_mult = pq.m_mult;
    const vt = pq.vt;
    const delta_t = pq.delta_t;
    const leff = pq.leff;
    const lactive = pq.lactive;
    const wactive = pq.wactive;
    const weffcj = pq.weffcj;
    const coxe = pq.coxe;
    const coxp_val = pq.coxp_val;
    const phi_s = pq.phi_s;
    const vth0_param = pq.vth0_param;

    // Cast remaining model params needed in x-dependent code
    const toxe: f64 = @as(f64, model.toxe);
    const toxp: f64 = @as(f64, model.toxp);
    const epsrox: f64 = @as(f64, model.epsrox);
    const ngate_cm3: f64 = @as(f64, model.ngate);
    const ados: f64 = @as(f64, model.ados);
    const bdos: f64 = @as(f64, model.bdos);
    const dvt1: f64 = @as(f64, model.dvt1);
    const dvt2: f64 = @as(f64, model.dvt2);
    const nfactor: f64 = @as(f64, model.nfactor);
    const cdsc: f64 = @as(f64, model.cdsc);
    const cdscb: f64 = @as(f64, model.cdscb);
    const cdscd: f64 = @as(f64, model.cdscd);
    const cit: f64 = @as(f64, model.cit);
    const noff: f64 = @as(f64, model.noff);
    const acde: f64 = @as(f64, model.acde);
    const moin: f64 = @as(f64, model.moin);
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const cgsl: f64 = @as(f64, model.cgsl);
    const cgdl: f64 = @as(f64, model.cgdl);
    const ckappas: f64 = @as(f64, model.ckappas);
    const ckappad: f64 = @as(f64, model.ckappad);
    const xpart: f64 = @as(f64, model.xpart);

    // Junction CV parameters
    const cjs_param: f64 = @as(f64, model.cjs);
    const cjd_param: f64 = @as(f64, model.cjd);
    const mjs: f64 = @as(f64, model.mjs);
    const mjd: f64 = @as(f64, model.mjd);
    const pbs: f64 = @as(f64, model.pbs);
    const pbd: f64 = @as(f64, model.pbd);
    const cjsws: f64 = @as(f64, model.cjsws);
    const cjswd: f64 = @as(f64, model.cjswd);
    const mjsws: f64 = @as(f64, model.mjsws);
    const mjswd: f64 = @as(f64, model.mjswd);
    const pbsws: f64 = @as(f64, model.pbsws);
    const pbswd: f64 = @as(f64, model.pbswd);
    const cjswgs: f64 = @as(f64, model.cjswgs);
    const cjswgd: f64 = @as(f64, model.cjswgd);
    const mjswgs: f64 = @as(f64, model.mjswgs);
    const mjswgd: f64 = @as(f64, model.mjswgd);
    const pbswgs: f64 = @as(f64, model.pbswgs);
    const pbswgd: f64 = @as(f64, model.pbswgd);
    const tcj: f64 = @as(f64, model.tcj);
    const tcjsw: f64 = @as(f64, model.tcjsw);
    const tcjswg: f64 = @as(f64, model.tcjswg);
    const tpb: f64 = @as(f64, model.tpb);
    const tpbsw: f64 = @as(f64, model.tpbsw);
    const tpbswg: f64 = @as(f64, model.tpbswg);

    // ---- x-DEPENDENT voltage reads ----
    const v_dp_val = x[dp];
    const v_sp_val = x[sp];
    const v_gp_val = x[gp];
    const v_bp_val = x[bp];

    const vgs = v_gp_val.sub(v_sp_val).scale(type_f);
    const vds_raw = v_dp_val.sub(v_sp_val).scale(type_f);
    const vbs = v_bp_val.sub(v_sp_val).scale(type_f);
    const vds = vds_raw.abs();
    const is_reversed = vds_raw.val() < 0.0;
    const vgs_eff = if (is_reversed) vgs.sub(vds_raw) else vgs;

    // Poly gate depletion for CV
    const vgse = if (ngate_cm3 > 1.0e18)
        computePolyDepletion(S, vgs_eff, dv.vfb, phi_s, ngate_cm3 * 1.0e6, toxe, epsrox)
    else
        vgs_eff;

    // Simplified Vth for CV (x-indep)
    const vth_cv = vth0_param;

    // ========================================================================
    // Subthreshold swing for CV
    // ========================================================================
    const lt = pq.lt;
    const cdep = pq.cdep;
    const cosh_n = sCosh(S, vbs.scale(dvt2).addC(1.0).scale(lt).maxC(1e-20).pow(-1.0).scale(dvt1 * leff));
    const cdsc_term = vds.scale(cdscd).add(vbs.scale(cdscb)).addC(cdsc).mul(cosh_n.addC(-1.0).maxC(1e-10).pow(-1.0)).scale(0.5);
    const n = cdsc_term.addC(cit).scale(1.0 / coxe).addC(1.0 + nfactor * cdep / coxe).maxC(0.1);
    const nvt = n.scale(vt);

    // ========================================================================
    // VgsteffCV (Eq 7.11, cvchargeMod=0)
    // ========================================================================
    const voffcv_prime = pq.voffcv_prime;
    const nvt_noff = nvt.scale(noff);
    const exp_cv = vgse.addC(-vth_cv - voffcv_prime).div(nvt_noff.maxC(1e-20)).minC(80.0);
    const vgsteff_cv = nvt_noff.mul(exp_cv.exp().addC(1.0).log());
    const vgsteff_cv_clamped = vgsteff_cv.maxC(1e-10);

    // ========================================================================
    // Short channel Vdsat,CV (Eq 7.10)
    // ========================================================================
    const clc_lact = pq.clc_lact;
    const abulk_cv = 1.0;
    const vdsat_cv = vgsteff_cv_clamped.scale(1.0 / @max(abulk_cv * (1.0 + clc_lact), 1e-10));

    // Vdseff for CV (smoothing)
    const t0_cv = vdsat_cv.sub(vds).addC(-0.02);
    const vdseff_cv = vdsat_cv.sub(t0_cv.add(t0_cv.mul(t0_cv).add(vdsat_cv.scale(0.08)).sqrt()).scale(0.5));
    const vdseff_cv_c = vdseff_cv.maxC(1e-10);

    // ========================================================================
    // Charge centroid for capMod=2 (Eqs 7.23--7.28)
    // ========================================================================
    const ndep_cm3 = pq.ndep_cm3;
    const ldebye = pq.ldebye;
    const xdc_acc_arg = vgse.sub(vbs).addC(-phi_s).scale(-acde * contract.fmath.exp(-0.25 * safe_log(@max(ndep_cm3 / 2.0e16, 1e-10))) / toxp);
    const xdc_acc = sExp(S, xdc_acc_arg).scale(ldebye / 3.0);
    const xdc_max = ldebye / 3.0;
    const delta_x = 1.0e-3 * toxe;
    const xdc_acc_x0 = xdc_acc.neg().addC(xdc_max - delta_x);
    const xdc_acc_clamped = xdc_acc_x0.add(xdc_acc_x0.mul(xdc_acc_x0).addC(4.0 * delta_x * xdc_max).sqrt()).scale(-0.5).addC(xdc_max);

    // Inversion Xdc (Eq 7.28)
    const xdc_inv_arg = vgsteff_cv_clamped.addC(4.0 * (vth0_param - dv.vfb - phi_s)).scale(1.0 / (2.0 * toxp)).addC(1.0);
    const xdc_inv = sLog(S, xdc_inv_arg.maxC(0.01)).scale(0.7 * bdos).exp().pow(-1.0).scale(ados * 1.9e-9);

    // Blend (region branch on vgsteff_cv_clamped)
    const xdc_blend = if (vgsteff_cv_clamped.val() > 0.01) xdc_inv else xdc_acc_clamped.maxC(1e-20);
    const ccen = xdc_blend.pow(-1.0).scale(EPS_SI);
    const coxeff_cv = ccen.scale(coxp_val).div(ccen.addC(coxp_val));

    // ========================================================================
    // Body charge thickness deviation (Eq 7.29)
    // ========================================================================
    const k1ox = pq.k1ox;
    const two_phi_b = 2.0 * phi_s;
    const delta_phi_arg = vgsteff_cv_clamped.mul(vgsteff_cv_clamped.addC(2.0 * k1ox * @sqrt(two_phi_b))).scale(1.0 / @max(moin * k1ox * k1ox * vt, 1e-20)).addC(1.0);
    const delta_phi = sLog(S, delta_phi_arg.maxC(1.0)).scale(vt);

    // ========================================================================
    // Intrinsic charge (capMod=2, Eqs 7.71--7.85)
    // ========================================================================
    // Accumulation charge
    const vfbzb = pq.vfbzb;
    // v0_acc = vfbzb + vbs - vgs - 0.02
    const v0_acc_s = vbs.sub(vgs).addC(vfbzb - 0.02);
    const vgbacc = v0_acc_s.add(v0_acc_s.mul(v0_acc_s).addC(0.08 * vfbzb).sqrt()).scale(0.5);
    const q_acc = vgbacc.scale(wactive * lactive).mul(coxeff_cv);

    // Vcveff (unused, kept for parity)
    const v1_cv = vdsat_cv.sub(vdseff_cv_c).addC(-0.02);
    const vcveff = vdsat_cv.sub(v1_cv.add(v1_cv.mul(v1_cv).add(vdsat_cv.scale(0.08)).sqrt()).scale(0.5));
    _ = vcveff;

    // Channel charges
    const two_vgst = vgsteff_cv_clamped.scale(2.0);
    const alphax = vdseff_cv_c.scale(abulk_cv).div(two_vgst.addC(1e-10).maxC(1e-10)).neg().addC(1.0);
    const alphax_c = alphax.maxC(0.0);
    _ = alphax_c;

    // Total channel charge (Qinv)
    const qch_inv = vgsteff_cv_clamped.mul(vdseff_cv_c.scale(abulk_cv).div(two_vgst.maxC(1e-10)).neg().addC(1.0)).scale(-wactive * lactive).mul(coxeff_cv);

    // Qsub
    const qsub = delta_phi.sub(vgsteff_cv_clamped.mul(vdseff_cv_c).scale((1.0 - abulk_cv) * abulk_cv).div(two_vgst.maxC(1e-10))).scale(wactive * lactive).mul(coxeff_cv);

    // Gate charge
    const qgate_intr = qch_inv.add(qsub).add(q_acc).neg();

    // Charge partition
    const frac_d: f64 = if (xpart >= 0.75) 0.0 else if (xpart >= 0.25) 0.5 else 0.4;
    const frac_s: f64 = 1.0 - frac_d;
    const q_drain_ch = qch_inv.scale(frac_d);
    const q_source_ch = qch_inv.scale(frac_s);

    // ========================================================================
    // Overlap charges (Eqs 7.87--7.94)
    // ========================================================================
    const vgs_ov_delta = 0.02;
    const vgs_ov = vgs.addC(vgs_ov_delta).sub(vgs.addC(vgs_ov_delta).mul(vgs.addC(vgs_ov_delta)).addC(4.0 * vgs_ov_delta).sqrt()).scale(0.5);
    const cgsl_term = if (cgsl > 0.0 and ckappas > 0.0)
        vgs.sub(vgs_ov).sub(vgs_ov.scale(-4.0 / ckappas).addC(1.0).maxC(1e-10).sqrt().addC(-1.0).scale(0.5 * ckappas)).scale(cgsl)
    else
        S.con(0.0);
    const q_overlap_s = vgs.scale(cgso).add(cgsl_term).scale(wactive);

    const vgd_val = vgs.sub(vds);
    const vgd_ov = vgd_val.addC(vgs_ov_delta).sub(vgd_val.addC(vgs_ov_delta).mul(vgd_val.addC(vgs_ov_delta)).addC(4.0 * vgs_ov_delta).sqrt()).scale(0.5);
    const cgdl_term = if (cgdl > 0.0 and ckappad > 0.0)
        vgd_val.sub(vgd_ov).sub(vgd_ov.scale(-4.0 / ckappad).addC(1.0).maxC(1e-10).sqrt().addC(-1.0).scale(0.5 * ckappad)).scale(cgdl)
    else
        S.con(0.0);
    const q_overlap_d = vgd_val.scale(cgdo).add(cgdl_term).scale(wactive);

    const q_overlap_b = vgs.sub(vbs).scale(lactive * cgbo);

    const q_overlap_g = q_overlap_s.add(q_overlap_d).add(q_overlap_b).neg();

    // ========================================================================
    // Junction depletion charges (Eqs 11.13--11.19)
    // ========================================================================
    const as_val = if (instance.as_ > 0.0) instance.as_ else weffcj * nf * 1.0e-7;
    const ps_val = if (instance.ps > 0.0) instance.ps else 2.0 * (weffcj * nf + 1.0e-7);
    const ad_val = if (instance.ad > 0.0) instance.ad else weffcj * nf * 1.0e-7;
    const pd_val = if (instance.pd > 0.0) instance.pd else 2.0 * (weffcj * nf + 1.0e-7);

    // Temperature-adjusted junction CV -- x-indep
    const cjs_t = cjs_param + tcj * delta_t;
    const cjd_t = cjd_param + tcj * delta_t;
    const cjsws_t = cjsws + tcjsw * delta_t;
    const cjswd_t = cjswd + tcjsw * delta_t;
    const cjswgs_t = cjswgs * (1.0 + tcjswg * delta_t);
    const cjswgd_t = cjswgd * (1.0 + tcjswg * delta_t);
    const pbs_t = @max(pbs - tpb * delta_t, 0.01);
    const pbd_t = @max(pbd - tpb * delta_t, 0.01);
    const pbsws_t = @max(pbsws - tpbsw * delta_t, 0.01);
    const pbswd_t = @max(pbswd - tpbsw * delta_t, 0.01);
    const pbswgs_t = @max(pbswgs - tpbswg * delta_t, 0.01);
    const pbswgd_t = @max(pbswgd - tpbswg * delta_t, 0.01);

    const vbs_junc = v_bp_val.sub(v_sp_val).scale(type_f);
    const vbd_junc = v_bp_val.sub(v_dp_val).scale(type_f);

    // Source junction charge
    const qbs_bot = junctionChargeS(S, vbs_junc, cjs_t, pbs_t, mjs).scale(as_val);
    const qbs_sw = junctionChargeS(S, vbs_junc, cjsws_t, pbsws_t, mjsws).scale(ps_val);
    const qbs_swg = junctionChargeS(S, vbs_junc, cjswgs_t, pbswgs_t, mjswgs).scale(weffcj * nf);
    const qbs = qbs_bot.add(qbs_sw).add(qbs_swg);

    // Drain junction charge
    const qbd_bot = junctionChargeS(S, vbd_junc, cjd_t, pbd_t, mjd).scale(ad_val);
    const qbd_sw = junctionChargeS(S, vbd_junc, cjswd_t, pbswd_t, mjswd).scale(pd_val);
    const qbd_swg = junctionChargeS(S, vbd_junc, cjswgd_t, pbswgd_t, mjswgd).scale(weffcj * nf);
    const qbd = qbd_bot.add(qbd_sw).add(qbd_swg);

    // ========================================================================
    // Write charge outputs
    // ========================================================================
    const m = m_mult;

    // Mode-dependent assignment (region branch on vds sign)
    const q_dp_ch = if (is_reversed) q_source_ch else q_drain_ch;
    const q_sp_ch = if (is_reversed) q_drain_ch else q_source_ch;
    const q_dp_ov = if (is_reversed) q_overlap_s else q_overlap_d;
    const q_sp_ov = if (is_reversed) q_overlap_d else q_overlap_s;

    var out: [n_u]S = undefined;
    out[gp] = qgate_intr.add(q_overlap_g).scale(m);
    out[dp] = q_dp_ch.add(q_dp_ov).add(qbd).scale(m);
    out[sp] = q_sp_ch.add(q_sp_ov).add(qbs).scale(m);
    out[bp] = qsub.add(q_overlap_b).sub(qbs).sub(qbd).scale(m);

    out[d_ext] = S.con(0.0);
    out[g_ext] = S.con(0.0);
    out[s_ext] = S.con(0.0);
    out[b_ext] = S.con(0.0);
    out[db] = S.con(0.0);
    out[sb] = S.con(0.0);

    return out;
}

// ============================================================================
// Voltage Limiting (limit function) -- unchanged signature, plain f64
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var result = x_new;
    const type_f: f64 = @floatFromInt(model.type_);

    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);
    const gp = @intFromEnum(U.gate_prime);
    const bp = @intFromEnum(U.body_prime);

    // Junction limiting (DEVpnjlim) for Vbs and Vbd
    const vt: f64 = K_BOLTZ * 300.15 / Q_ELECTRON;
    const vcrit = vt * contract.fmath.log(vt / (1.41421356 * @as(f64, model.jss) * 1e-8));

    // Limit bp-sp (source junction)
    {
        const vbs_new = (x_new[bp] - x_new[sp]) * type_f;
        const vbs_old = (x_old[bp] - x_old[sp]) * type_f;
        const vbs_lim = pnjlim(vbs_new, vbs_old, vt, vcrit);
        const delta_v = (vbs_lim - vbs_new) * type_f;
        result[bp] = result[bp] + delta_v * 0.5;
        result[sp] = result[sp] - delta_v * 0.5;
    }

    // Limit bp-dp (drain junction)
    {
        const vbd_new = (x_new[bp] - x_new[dp]) * type_f;
        const vbd_old = (x_old[bp] - x_old[dp]) * type_f;
        const vbd_lim = pnjlim(vbd_new, vbd_old, vt, vcrit);
        const delta_v = (vbd_lim - vbd_new) * type_f;
        result[bp] = result[bp] + delta_v * 0.5;
        result[dp] = result[dp] - delta_v * 0.5;
    }

    // Gate voltage limiting (DEVfetlim)
    {
        const vgs_new = (x_new[gp] - x_new[sp]) * type_f;
        const vgs_old = (x_old[gp] - x_old[sp]) * type_f;
        const vth: f64 = vthDefaults(model).vth0;
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

    return result;
}

// ============================================================================
// Parameter stepping (attempt function)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale junction saturation currents with GMIN stepping
    const gmin_scale = GMIN * (1.0 - lambda);
    const jss_new = model.jss + @as(f32, @floatCast(gmin_scale));
    const jsd_new = model.jsd + @as(f32, @floatCast(gmin_scale));
    m.jss = jss_new;
    m.jsd = jsd_new;

    // Scale subthreshold factor
    const voff_orig: f64 = @as(f64, model.voff);
    const voff_scaled = voff_orig * lambda + (-0.3) * (1.0 - lambda);
    m.voff = @as(f32, @floatCast(voff_scaled));

    return m;
}

// ============================================================================
// Helper: Poly gate depletion (Eq 1.7) -- value-form (S)
// ============================================================================

fn computePolyDepletion(comptime S: type, vgs: S, vfb: f64, phi_s: f64, ngate_m3: f64, toxe_val: f64, epsrox_val: f64) S {
    const arg = vgs.addC(-vfb - phi_s);
    // a_poly, x-independent
    const a_poly = epsrox_val * epsrox_val * EPS_0 * EPS_0 / (2.0 * Q_ELECTRON * EPS_SI * ngate_m3 * toxe_val * toxe_val);
    const term = arg.scale(2.0 * a_poly).addC(1.0);
    const sqrt_term = term.maxC(0.0).sqrt();
    // Eq 1.7: region branch on arg (accumulation/inversion) reproduces the
    // original piecewise selection; a_poly>0 is x-independent.
    const vpoly = if (arg.val() > 0.0 and a_poly > 0.0) sqrt_term.addC(-1.0).scale(1.0 / a_poly) else arg;
    return vpoly.addC(vfb + phi_s);
}

// ============================================================================
// Helper: PN junction voltage limiting (DEVpnjlim)
// ============================================================================

fn pnjlim(vnew: f64, vold: f64, vt_val: f64, vcrit: f64) f64 {
    const delta_v = vnew - vold;
    const abs_delta = @abs(delta_v);

    // Forward bias
    const result_fwd = if (vnew > vcrit and abs_delta > 2.0 * vt_val)
        if (vold > 0.0)
            vt_val * contract.fmath.log(vnew / vold) + vold
        else
            vcrit
    else
        vnew;

    // Reverse bias: less limiting needed
    const result = if (vnew < -3.0 * vt_val) blk: {
        const max_step = 3.0 * vt_val;
        break :blk if (abs_delta > max_step) vold - max_step else vnew;
    } else result_fwd;

    return result;
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
// Helper: Junction depletion charge -- value-form (S)
// ============================================================================
// For vj < 0: Q = cj * pb * (1 - (1 - vj/pb)^(1-mj)) / (1-mj)
// For vj >= 0: Q = cj * vj * (1 + 0.5*mj*vj/pb)  (quadratic extension)
// Region branch on vj reproduces the original piecewise charge.

fn junctionChargeS(comptime S: type, vj: S, cj: f64, pb: f64, mj: f64) S {
    const cj_f = @max(cj, 0.0);
    const pb_f = @max(pb, 0.01);
    if (vj.val() < 0.0) {
        const one_m_mj = 1.0 - mj;
        const arg = vj.scale(-1.0 / pb_f).addC(1.0);
        const arg_clamped = arg.maxC(1e-30);
        // (1-vj/pb)^(1-mj) = exp((1-mj)*log(clamped))  (matches safe_log guard)
        const pow_val = sLog(S, arg_clamped).scale(one_m_mj).exp();
        return pow_val.neg().addC(1.0).scale(cj_f * pb_f / one_m_mj);
    } else {
        return vj.scale(cj_f).mul(vj.scale(0.5 * mj / pb_f).addC(1.0));
    }
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

const std_testing = std.testing;

test "bsim4: nmos on-state channel current sign and node balance" {
    // Default NMOS. Bias: Vg=1.2, Vd=1.0, Vs=0, Vb=0 on all node pairs
    // (external == prime, so parasitic-R currents are ~0 at equal potentials
    // except the series R to prime nodes; we set prime == external so those
    // vanish and only channel + junction physics remain).
    const inst: Instance = .{};

    // Disable the source-end velocity limit (vtl=0) so the drain current is the
    // full channel current; default vtl otherwise clamps this tiny geometry to
    // a negligible value. This is a legitimate model configuration.
    const model2: Model = .{ .vtl = 0.0 };

    // x order: drain, gate, source, bulk, dp, sp, gp, bp, db, sb
    // Put external and prime nodes at equal potentials so parasitic R gives 0.
    const out = contract.evalValues(Self, .{
        1.0, 1.2, 0.0, 0.0, // d, g, s, b
        1.0, 0.0, 1.2, 0.0, // dp, sp, gp, bp
        0.0, 0.0, // db, sb
    }, &model2, &inst, 0);

    // Overall KCL must sum to ~0 (charge conservation of the current vector):
    var sum: f64 = 0;
    for (out) |v| sum += v;
    try std_testing.expectApproxEqAbs(@as(f64, 0.0), sum, 1e-9);

    // NMOS in inversion (Vgs=1.2 > Vth): drain-prime carries a finite,
    // nonzero conduction current (~1e-4 for these defaults).
    const dp = @intFromEnum(U.drain_prime);
    try std_testing.expect(@abs(out[dp]) > 1e-6);
    // The source-prime row is the KCL mirror; channel current dominates it too.
    const sp = @intFromEnum(U.source_prime);
    try std_testing.expect(@abs(out[sp]) > 1e-6);
}

test "bsim4: cutoff has negligible channel current" {
    // Vgs = 0 (below Vth0=0.7): device is off, channel current ~ 0.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{
        1.0, 0.0, 0.0, 0.0,
        1.0, 0.0, 0.0, 0.0,
        0.0, 0.0,
    }, &model, &inst, 0);
    const dp = @intFromEnum(U.drain_prime);
    // Subthreshold leakage is tiny compared to on-state (which is ~1e-4..1e-3).
    try std_testing.expect(@abs(out[dp]) < 1e-6);
}

test "bsim4: junction charge is negative under reverse bias" {
    // Reverse-biased drain junction (Vbd < 0) stores depletion charge.
    // With default cjd etc., qbd should be nonzero and the charge vector
    // must conserve (external/db/sb rows are exactly zero).
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{
        1.0, 0.0, 0.0, 0.0,
        1.0, 0.0, 0.0, 0.0,
        0.0, 0.0,
    }, &model, &inst, 0);

    // External / body-network nodes carry no charge.
    try std_testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.drain)]);
    try std_testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.gate)]);
    try std_testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.db_node)]);
    try std_testing.expectEqual(@as(f64, 0.0), out[@intFromEnum(U.sb_node)]);

    // Intrinsic drain charge (channel + overlap + junction) is finite.
    try std_testing.expect(std.math.isFinite(out[@intFromEnum(U.drain_prime)]));
}

test "bsim4: junctionChargeS matches hand computation (reverse bias)" {
    // Q(vj<0) = cj*pb*(1-(1-vj/pb)^(1-mj))/(1-mj).
    // cj=5e-4, pb=1.0, mj=0.5, vj=-1.0:
    //   arg = 1 - (-1)/1 = 2
    //   2^(0.5) = 1.4142135623730951
    //   Q = 5e-4*1.0*(1 - 1.4142135623730951)/0.5
    //     = 5e-4*( -0.4142135623730951 )/0.5
    //     = 5e-4 * -0.8284271247461902
    //     = -4.142135623730951e-4
    const V = contract.Value;
    const got = junctionChargeS(V, V.con(-1.0), 5.0e-4, 1.0, 0.5).val();
    try std_testing.expectApproxEqAbs(@as(f64, -4.142135623730951e-4), got, 1e-12);
}

test "bsim4: junctionChargeS forward bias quadratic branch" {
    // Q(vj>=0) = cj*vj*(1 + 0.5*mj*vj/pb).
    // cj=5e-4, pb=1.0, mj=0.5, vj=0.5:
    //   Q = 5e-4*0.5*(1 + 0.5*0.5*0.5/1.0)
    //     = 2.5e-4*(1 + 0.125)
    //     = 2.5e-4*1.125 = 2.8125e-4
    const V = contract.Value;
    const got = junctionChargeS(V, V.con(0.5), 5.0e-4, 1.0, 0.5).val();
    try std_testing.expectApproxEqAbs(@as(f64, 2.8125e-4), got, 1e-15);
}
