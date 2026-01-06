const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: Mextram 505.5.0 (SiGe HBT Bipolar Transistor)
//
// External: C (collector), B (base), E (emitter), S (substrate)
// Internal: B1  (external base after RBc)
//           B2  (intrinsic base after variable RBv)
//           E1  (intrinsic emitter after RE)
//           C1  (epilayer/base boundary)
//           C2  (intrinsic collector)
//           C3  (extrinsic buried layer node)
//           C4  (intrinsic buried layer node)
//           dT  (thermal node for self-heating)
// ============================================================================

pub const U = enum(u8) {
    c, //  0: external collector
    b, //  1: external base
    e, //  2: external emitter
    s, //  3: external substrate
    b1, //  4: base after constant RBc
    b2, //  5: intrinsic base
    e1, //  6: intrinsic emitter
    c1, //  7: epilayer/base boundary
    c2, //  8: intrinsic collector
    c3, //  9: extrinsic buried layer
    c4, // 10: intrinsic buried layer
    dt, // 11: thermal node (self-heating)
};

pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters (159 total, matching Mextram 505.5.0 spec)
// ============================================================================

pub const Model = struct {
    // --- Instance and General Parameters ---
    // dta is instance, version/type/tref/exmod/exphi/exavl/exsub are model
    version: f32 = 505.50,
    type_: i32 = 1, // +1=NPN, -1=PNP
    tref: f32 = 25.0,
    exmod: i32 = 1,
    exphi: i32 = 1,
    exavl: i32 = 0,
    exsub: i32 = 1,

    // --- Main Current Parameters ---
    is: f32 = 22.0e-18,
    nff: f32 = 1.0,
    nfr: f32 = 1.0,
    ik: f32 = 0.1,
    ver: f32 = 2.5,
    vef: f32 = 44.0,
    issr: f32 = 1.0,

    // --- Forward Base Current Parameters ---
    ibi: f32 = 0.1e-18,
    nbi: f32 = 1.0,
    ibis: f32 = 0.0,
    nbis: f32 = 1.0,
    ibf: f32 = 2.7e-15,
    mlf: f32 = 2.0,
    ibfs: f32 = 0.0,
    mlfs: f32 = 2.0,

    // --- NBR Base Current Parameters (SWIB1) ---
    swib1: i32 = 0,
    ibinbr: f32 = 0.0,
    ibinbrs: f32 = 0.0,
    vknbr: f32 = 0.68,
    ibinbrqs: f32 = 0.0,

    // --- BTBT and TAT Base Current Parameters ---
    istat: f32 = 0.0,
    vtat: f32 = 1.0,
    vbtbt: f32 = 0.16,
    kbtbt: f32 = 0.0,

    // --- Reverse Base Current Parameters ---
    ibx: f32 = 3.14e-18,
    ikbx: f32 = 14.29e-3,
    ibr: f32 = 1.0e-15,
    mlr: f32 = 2.0,
    xext: f32 = 0.63,

    // --- Zener Tunneling Current Parameters ---
    izeb: f32 = 0.0,
    nzeb: f32 = 22.0,
    izcb: f32 = 0.0,
    nzcb: f32 = 22.0,
    vzmin: f32 = 1.0e-6,

    // --- Avalanche Current Parameters ---
    swavl: i32 = 1,
    aavl: f32 = 400.0,
    cavl: f32 = -0.37,
    itoavl: f32 = 500e-3,
    bavl: f32 = 25.0,
    vdcavl: f32 = 0.1,
    wavl: f32 = 1.1e-6,
    vavl: f32 = 3.0,
    sfh: f32 = 0.3,
    ihcavl: f32 = 4.0e-3,
    davl: f32 = -0.37,
    eavl: f32 = -0.37,
    aexavl: f32 = 0.3,
    ionexavl: f32 = 4.0e-3,
    swgemlim: i32 = 1,

    // --- Resistance Parameters ---
    re: f32 = 5.0,
    rbc: f32 = 23.0,
    rbv: f32 = 18.0,
    rcc: f32 = 12.0,
    rcblx: f32 = 0.0,
    rcbli: f32 = 0.0,

    // --- Epilayer Parameters ---
    rcv: f32 = 150.0,
    scrcv: f32 = 1250.0,
    ihc: f32 = 4.0e-3,
    axi: f32 = 0.3,
    vdc: f32 = 0.68,

    // --- Depletion Capacitance Parameters ---
    cje: f32 = 73.0e-15,
    vde: f32 = 0.95,
    pe: f32 = 0.4,
    xcje: f32 = 0.4,
    cbeo: f32 = 0.0,
    cjc: f32 = 78.0e-15,
    vdcctc: f32 = 0.68,
    pc: f32 = 0.5,
    swvchc: i32 = 0,
    swvjunc: i32 = 0,
    xp: f32 = 0.35,
    mc: f32 = 0.5,
    xcjc: f32 = 32.0e-3,
    cbco: f32 = 0.0,

    // --- Extrinsic Diffusion Charge and CB Breakdown Parameters ---
    swqex: i32 = 0,
    vdcex: f32 = 0.68,
    vbrcb: f32 = 100.0,
    pbrcb: f32 = 4.0,
    frevcb: f32 = 1000.0,
    swjbrcb: i32 = 0,

    // --- Transit Time Parameters ---
    mtau: f32 = 1.0,
    taue: f32 = 2.0e-12,
    taub: f32 = 4.2e-12,
    tepi: f32 = 41.0e-12,
    taur: f32 = 520.0e-12,
    tauex: f32 = 10.0e-12,
    nex: f32 = 1.0,

    // --- Heterojunction (SiGe) Parameters ---
    deg: f32 = 0.0,
    xrec: f32 = 0.0,
    xqb: f32 = 0.3333333,
    ke: f32 = 0.0,

    // --- Temperature Scaling Parameters ---
    dtmax: f32 = 200.0,
    aqbo: f32 = 0.3,
    ae: f32 = 0.0,
    ab: f32 = 1.0,
    aepi: f32 = 2.5,
    aepiex: f32 = 2.5,
    aex: f32 = 0.62,
    ac: f32 = 2.0,
    acx: f32 = 1.3,
    acbl: f32 = 2.0,
    ktat: f32 = 0.0,

    // --- Bandgap Voltage Parameters ---
    vgb: f32 = 1.17,
    vgbnbrqs: f32 = 1.12,
    vgbnbr: f32 = 1.12,
    vgbnbrs: f32 = 1.12,
    vgknbr: f32 = 1.12,
    vgc: f32 = 1.18,
    vge: f32 = 1.12,
    vgcx: f32 = 1.125,
    vgj: f32 = 1.15,

    // --- Zener Tunneling Bandgap Parameters ---
    vgzeb: f32 = 1.15,
    avgeb: f32 = 4.73e-4,
    tvgeb: f32 = 636.0,
    vgzcb: f32 = 1.15,
    avgcb: f32 = 4.73e-4,
    tvgcb: f32 = 636.0,

    // --- Additional Temperature and Tuning Parameters ---
    dvgte: f32 = 0.05,
    dais: f32 = 0.0,
    tnff: f32 = 0.0,
    tnfr: f32 = 0.0,
    tbavl: f32 = 500e-6,

    // --- Noise Parameters ---
    af: f32 = 2.0,
    afn: f32 = 2.0,
    kf: f32 = 20.0e-12,
    kfn: f32 = 20.0e-12,
    kavl: f32 = 0,
    kc: f32 = 0,
    ftaun: f32 = 0.0,

    // --- Substrate (4-Terminal) Parameters ---
    iss: f32 = 48.0e-18,
    icss: f32 = 0.0,
    iks: f32 = 545.5e-6,
    ikcs: f32 = 50.0e-6,
    cjs: f32 = 315.0e-15,
    vds: f32 = 0.62,
    ps: f32 = 0.34,
    vgs: f32 = 1.20,
    as_: f32 = 1.58, // 'as' is a keyword in Zig
    asub: f32 = 2.0,
    xisubi: f32 = 0.0,
    swvsch: i32 = 0,

    // --- Self-Heating Parameters ---
    swnlsh: i32 = 0,
    rth: f32 = 300.0,
    cth: f32 = 3.0e-9,
    ath: f32 = 0.0,

    // --- Reliability and Convergence Parameters ---
    isibrel: f32 = 0.0,
    nfibrel: f32 = 2.0,
    vexlim: f32 = 80.0,
    p0starlim: f32 = 1.0e-40,
    pwlim: f32 = 1.0e-40,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    dta: f32 = 0.0,
    mult: f32 = 1.0,
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: RE (e -- e1)
    .{ .row = @intFromEnum(U.e), .col = @intFromEnum(U.e1), .kind = .thermal },
    // Thermal noise: RBc (b -- b1)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.b1), .kind = .thermal },
    // Thermal noise: RBv (b1 -- b2) variable base resistance
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.b2), .kind = .thermal },
    // Thermal noise: RCc (c -- c3)
    .{ .row = @intFromEnum(U.c), .col = @intFromEnum(U.c3), .kind = .thermal },
    // Thermal noise: RCblx (c3 -- c4)
    .{ .row = @intFromEnum(U.c3), .col = @intFromEnum(U.c4), .kind = .thermal },
    // Thermal noise: RCbli (c4 -- c1)
    .{ .row = @intFromEnum(U.c4), .col = @intFromEnum(U.c1), .kind = .thermal },
    // Shot noise: IB1 + IB2 + IztEB (b2 -- e1)
    .{ .row = @intFromEnum(U.b2), .col = @intFromEnum(U.e1), .kind = .shot },
    // Flicker noise: ideal base current (b2 -- e1)
    .{ .row = @intFromEnum(U.b2), .col = @intFromEnum(U.e1), .kind = .flicker },
    // Shot noise: collector transport (c2 -- e1)
    .{ .row = @intFromEnum(U.c2), .col = @intFromEnum(U.e1), .kind = .shot },
    // Shot noise: sidewall base (b1 -- e1)
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.e1), .kind = .shot },
    // Flicker noise: non-ideal base current (b1 -- e1)
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.e1), .kind = .flicker },
    // Shot noise: IB3 + IztCB (b1 -- c4)
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.c4), .kind = .shot },
    // Flicker noise: IB3 (b1 -- c4)
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.c4), .kind = .flicker },
    // Shot noise: Iex (b1 -- c4)
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.c4), .kind = .shot },
    // Shot noise: Isub_int (b2 -- s)
    .{ .row = @intFromEnum(U.b2), .col = @intFromEnum(U.s), .kind = .shot },
    // Shot noise: Isub (b1 -- s)
    .{ .row = @intFromEnum(U.b1), .col = @intFromEnum(U.s), .kind = .shot },
    // Shot noise: XIex (b -- c3)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.c3), .kind = .shot },
    // Shot noise: XIsub (b -- s)
    .{ .row = @intFromEnum(U.b), .col = @intFromEnum(U.s), .kind = .shot },
};

// ============================================================================
// Helper: smooth transition functions (value-form, generic over S)
//
// These mirror the original branchless f64 helpers. Branches on x-dependent
// quantities are made through .val() (reproducing the original piecewise
// physics), with each branch computed in S ops so the derivative follows the
// selected branch (exactly as the f64 code did).
// ============================================================================

/// exp(min(a, cap)) — the ubiquitous overflow guard. cap is a constant.
inline fn expC(comptime S: type, a: S, cap: f64) S {
    return a.minC(cap).exp();
}

/// log(max(a, floor)) — the ubiquitous domain guard. floor is a constant.
inline fn logC(comptime S: type, a: S, floor: f64) S {
    return a.maxC(floor).log();
}

fn min_logexp(comptime S: type, x: S, x0: f64, a: f64) S {
    // smooth min: min_logexp(x, x0; a) ~ min(x, x0)
    // d = (x - x0)/a; d_safe = if (x < x0) d else -d; base = if (x < x0) x else x0
    const d = x.addC(-x0).scale(1.0 / a);
    const d_safe = if (x.val() < x0) d else d.neg();
    const base = if (x.val() < x0) x else S.con(x0);
    // base - a * log(1 + exp(min(d_safe, 80)))
    const t = expC(S, d_safe, 80.0).addC(1.0).log().scale(a);
    return base.sub(t);
}

fn max_logexp(comptime S: type, x: S, x0: f64, a: f64) S {
    // smooth max: max_logexp(x, x0; a) ~ max(x, x0)
    const d = x.addC(-x0).scale(1.0 / a);
    const d_safe = if (x.val() < x0) d else d.neg();
    const base = if (x.val() < x0) S.con(x0) else x;
    const t = expC(S, d_safe, 80.0).addC(1.0).log().scale(a);
    return base.add(t);
}

// f64 versions used when the argument does not depend on x (temperature prep).
inline fn min_logexp_f(x: f64, x0: f64, a: f64) f64 {
    const d = (x - x0) / a;
    const d_safe = if (x < x0) d else -d;
    const base = if (x < x0) x else x0;
    return base - a * contract.fmath.log(1.0 + contract.fmath.exp(@min(d_safe, 80.0)));
}

inline fn max_logexp_f(x: f64, x0: f64, a: f64) f64 {
    const d = (x - x0) / a;
    const d_safe = if (x < x0) d else -(d);
    const base = if (x < x0) x0 else x;
    return base + a * contract.fmath.log(1.0 + contract.fmath.exp(@min(d_safe, 80.0)));
}

// ============================================================================
// x-independent parameter / temperature preprocessing.
//
// EVERYTHING here is plain f64 EXCEPT quantities depending on the thermal-node
// voltage x[dt] (self-heating). To keep those Jacobian entries correct, the
// temperature (TK/VT/tN/...) and everything scaled by it must ride the scalar
// S. So temperature scaling is done generically over S in `tempScale` below;
// only the truly x-free constants (bandgaps, exponents, mode switches) are
// prepared here.
// ============================================================================

const Params = struct {
    type_f: f64,
    tref: f64,
    mult: f64,
    dta: f64,

    Is: f64,
    NFF: f64,
    NFR: f64,
    Ik: f64,
    Ver: f64,
    Vef: f64,
    Issr: f64,

    IBI: f64,
    NBI: f64,
    ISBI: f64,
    NSBI: f64,
    IBf: f64,
    mLf: f64,
    ISBf: f64,
    mSLf: f64,

    SWIB1: i32,
    IBInbr: f64,
    IBInbrs: f64,
    VKnbr: f64,
    IBInbrqs: f64,

    Istat: f64,
    Vtat: f64,
    Vbtbt: f64,
    Kbtbt: f64,

    IBX: f64,
    IkBX: f64,
    IBr: f64,
    mLr: f64,
    Xext: f64,

    IzEB: f64,
    NzEB: f64,
    IzCB: f64,
    NzCB: f64,
    Vzmin: f64,

    SWAVL: i32,
    Aavl: f64,
    Cavl: f64,
    ITOavl: f64,
    Bavl: f64,
    VdCavl: f64,
    Wavl: f64,
    Vavl: f64,
    SfH: f64,
    Ihcavl: f64,
    Davl: f64,
    Eavl_p: f64,
    Aexavl: f64,
    Ionexavl: f64,
    SWGEMLIM: i32,
    EXAVL: i32,

    RE: f64,
    RBc: f64,
    RBv: f64,
    RCc: f64,
    RCblx: f64,
    RCbli: f64,

    RCv: f64,
    SCRCv: f64,
    Ihc: f64,
    axi: f64,
    VdC: f64,

    VdE: f64,
    pE: f64,
    VdCctc: f64,
    pC: f64,
    Xp: f64,
    mC: f64,
    SWVCHC: i32,

    Vbrcb: f64,
    Pbrcb: f64,
    Frevcb: f64,
    SWJBRCB: i32,

    dEg: f64,
    Xrec: f64,

    AQB0: f64,
    AE: f64,
    AB: f64,
    Aepi: f64,
    Aex: f64,
    AC: f64,
    ACX: f64,
    ACbl: f64,
    Ktat_coeff: f64,
    dAIs: f64,
    tNFF: f64,
    tNFR: f64,
    TBavl: f64,

    VgB: f64,
    VgBnbrqs: f64,
    VgBnbr: f64,
    VgSBnbr: f64,
    VgKnbr: f64,
    VgC: f64,
    VgE: f64,
    VgCX: f64,
    Vgj: f64,

    VgZEB: f64,
    AVgEB: f64,
    TVgEB: f64,
    VgZCB: f64,
    AVgCB: f64,
    TVgCB: f64,

    ISs: f64,
    ICSs: f64,
    Iks: f64,
    Ikcs: f64,
    VgS: f64,
    AS: f64,
    Asub: f64,
    Xisubi: f64,
    SWVSCH: i32,
    EXSUB: i32,
    EXMOD: i32,

    SWNLSH: i32,
    Rth: f64,
    Ath: f64,
    DTmax: f64,

    ISIBrel: f64,
    NFIBrel: f64,

    vexlim: f64,
    p0starlim: f64,

    An: f64,
    Bn: f64,
};

fn prep(model: *const Model, instance: *const Instance) Params {
    const mult: f64 = @as(f64, instance.mult);
    const An_npn: f64 = 7.03e7;
    const Bn_npn: f64 = 1.23e8;
    const An_pnp: f64 = 1.58e8;
    const Bn_pnp: f64 = 2.04e8;
    return .{
        .type_f = @floatFromInt(model.type_),
        .tref = @as(f64, model.tref),
        .mult = mult,
        .dta = @as(f64, instance.dta),

        .Is = @as(f64, model.is) * mult,
        .NFF = @as(f64, model.nff),
        .NFR = @as(f64, model.nfr),
        .Ik = @as(f64, model.ik) * mult,
        .Ver = @as(f64, model.ver),
        .Vef = @as(f64, model.vef),
        .Issr = @as(f64, model.issr),

        .IBI = @as(f64, model.ibi) * mult,
        .NBI = @as(f64, model.nbi),
        .ISBI = @as(f64, model.ibis) * mult,
        .NSBI = @as(f64, model.nbis),
        .IBf = @as(f64, model.ibf) * mult,
        .mLf = @as(f64, model.mlf),
        .ISBf = @as(f64, model.ibfs) * mult,
        .mSLf = @as(f64, model.mlfs),

        .SWIB1 = model.swib1,
        .IBInbr = @as(f64, model.ibinbr),
        .IBInbrs = @as(f64, model.ibinbrs),
        .VKnbr = @as(f64, model.vknbr),
        .IBInbrqs = @as(f64, model.ibinbrqs),

        .Istat = @as(f64, model.istat),
        .Vtat = @as(f64, model.vtat),
        .Vbtbt = @as(f64, model.vbtbt),
        .Kbtbt = @as(f64, model.kbtbt),

        .IBX = @as(f64, model.ibx) * mult,
        .IkBX = @as(f64, model.ikbx) * mult,
        .IBr = @as(f64, model.ibr) * mult,
        .mLr = @as(f64, model.mlr),
        .Xext = @as(f64, model.xext),

        .IzEB = @as(f64, model.izeb) * mult,
        .NzEB = @as(f64, model.nzeb),
        .IzCB = @as(f64, model.izcb) * mult,
        .NzCB = @as(f64, model.nzcb),
        .Vzmin = @as(f64, model.vzmin),

        .SWAVL = model.swavl,
        .Aavl = @as(f64, model.aavl),
        .Cavl = @as(f64, model.cavl),
        .ITOavl = @as(f64, model.itoavl) * mult,
        .Bavl = @as(f64, model.bavl),
        .VdCavl = @as(f64, model.vdcavl),
        .Wavl = @as(f64, model.wavl),
        .Vavl = @as(f64, model.vavl),
        .SfH = @as(f64, model.sfh),
        .Ihcavl = @as(f64, model.ihcavl),
        .Davl = @as(f64, model.davl),
        .Eavl_p = @as(f64, model.eavl),
        .Aexavl = @as(f64, model.aexavl),
        .Ionexavl = @as(f64, model.ionexavl),
        .SWGEMLIM = model.swgemlim,
        .EXAVL = model.exavl,

        .RE = @as(f64, model.re) / mult,
        .RBc = @as(f64, model.rbc) / mult,
        .RBv = @as(f64, model.rbv) / mult,
        .RCc = @as(f64, model.rcc) / mult,
        .RCblx = @as(f64, model.rcblx) / mult,
        .RCbli = @as(f64, model.rcbli) / mult,

        .RCv = @as(f64, model.rcv) / mult,
        .SCRCv = @as(f64, model.scrcv) / mult,
        .Ihc = @as(f64, model.ihc) * mult,
        .axi = @as(f64, model.axi),
        .VdC = @as(f64, model.vdc),

        .VdE = @as(f64, model.vde),
        .pE = @as(f64, model.pe),
        .VdCctc = @as(f64, model.vdcctc),
        .pC = @as(f64, model.pc),
        .Xp = @as(f64, model.xp),
        .mC = @as(f64, model.mc),
        .SWVCHC = model.swvchc,

        .Vbrcb = @as(f64, model.vbrcb),
        .Pbrcb = @as(f64, model.pbrcb),
        .Frevcb = @as(f64, model.frevcb),
        .SWJBRCB = model.swjbrcb,

        .dEg = @as(f64, model.deg),
        .Xrec = @as(f64, model.xrec),

        .AQB0 = @as(f64, model.aqbo),
        .AE = @as(f64, model.ae),
        .AB = @as(f64, model.ab),
        .Aepi = @as(f64, model.aepi),
        .Aex = @as(f64, model.aex),
        .AC = @as(f64, model.ac),
        .ACX = @as(f64, model.acx),
        .ACbl = @as(f64, model.acbl),
        .Ktat_coeff = @as(f64, model.ktat),
        .dAIs = @as(f64, model.dais),
        .tNFF = @as(f64, model.tnff),
        .tNFR = @as(f64, model.tnfr),
        .TBavl = @as(f64, model.tbavl),

        .VgB = @as(f64, model.vgb),
        .VgBnbrqs = @as(f64, model.vgbnbrqs),
        .VgBnbr = @as(f64, model.vgbnbr),
        .VgSBnbr = @as(f64, model.vgbnbrs),
        .VgKnbr = @as(f64, model.vgknbr),
        .VgC = @as(f64, model.vgc),
        .VgE = @as(f64, model.vge),
        .VgCX = @as(f64, model.vgcx),
        .Vgj = @as(f64, model.vgj),

        .VgZEB = @as(f64, model.vgzeb),
        .AVgEB = @as(f64, model.avgeb),
        .TVgEB = @as(f64, model.tvgeb),
        .VgZCB = @as(f64, model.vgzcb),
        .AVgCB = @as(f64, model.avgcb),
        .TVgCB = @as(f64, model.tvgcb),

        .ISs = @as(f64, model.iss) * mult,
        .ICSs = @as(f64, model.icss) * mult,
        .Iks = @as(f64, model.iks) * mult,
        .Ikcs = @as(f64, model.ikcs) * mult,
        .VgS = @as(f64, model.vgs),
        .AS = @as(f64, model.as_),
        .Asub = @as(f64, model.asub),
        .Xisubi = @as(f64, model.xisubi),
        .SWVSCH = model.swvsch,
        .EXSUB = model.exsub,
        .EXMOD = model.exmod,

        .SWNLSH = model.swnlsh,
        .Rth = @as(f64, model.rth) / mult,
        .Ath = @as(f64, model.ath),
        .DTmax = @as(f64, model.dtmax),

        .ISIBrel = @as(f64, model.isibrel) * mult,
        .NFIBrel = @as(f64, model.nfibrel),

        .vexlim = @as(f64, model.vexlim),
        .p0starlim = @as(f64, model.p0starlim),

        .An = if (model.type_ == 1) An_npn else An_pnp,
        .Bn = if (model.type_ == 1) Bn_npn else Bn_pnp,
    };
}

pub const PrepCache = Params;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// Temperature-scaled quantities, generic over S.
//
// TK depends on the thermal node voltage VdT = x[dt], so ALL of these carry
// derivatives w.r.t. that unknown. Quantities not used by q() live only in the
// eval() struct; the shared subset is computed the same way in both.
// ============================================================================

const kB_q: f64 = 8.6171e-5;
const Vd_low: f64 = 0.05;
const alpha_jE: f64 = 3.0;
const alpha_jC: f64 = 2.0;
const alpha_jS: f64 = 2.0;
const GMIN: f64 = 1.0e-12;

/// Smooth diffusion voltage: Ud + VT*log(1 + exp(min((Vd_low-Ud)/VT, 80))).
fn diffVolt(comptime S: type, VT: S, Ud: S) S {
    const arg = S.con(Vd_low).sub(Ud).div(VT);
    return Ud.add(VT.mul(expC(S, arg, 80.0).addC(1.0).log()));
}

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    const P = pc;
    const type_f = P.type_f;

    const nc = @intFromEnum(U.c);
    const nb = @intFromEnum(U.b);
    const ne = @intFromEnum(U.e);
    const ns = @intFromEnum(U.s);
    const nb1 = @intFromEnum(U.b1);
    const nb2 = @intFromEnum(U.b2);
    const ne1 = @intFromEnum(U.e1);
    const nc1 = @intFromEnum(U.c1);
    const nc2 = @intFromEnum(U.c2);
    const nc3 = @intFromEnum(U.c3);
    const nc4 = @intFromEnum(U.c4);
    const ndt = @intFromEnum(U.dt);

    // Self-heating temperature rise (clamped) — x-dependent
    const VdT = x[ndt].minC(P.DTmax).maxC(-P.DTmax);

    // Branch voltages (internal, NPN convention via type_f)
    const V_B2E1 = x[nb2].sub(x[ne1]).scale(type_f);
    const V_B2C2 = x[nb2].sub(x[nc2]).scale(type_f);
    const V_B2C1 = x[nb2].sub(x[nc1]).scale(type_f);
    const V_B1E1 = x[nb1].sub(x[ne1]).scale(type_f);
    const V_B1B2 = x[nb1].sub(x[nb2]).scale(type_f);
    const V_B1C4 = x[nb1].sub(x[nc4]).scale(type_f);
    const V_C1C2 = x[nc1].sub(x[nc2]).scale(type_f);
    const V_C2B1 = x[nc2].sub(x[nb1]).scale(type_f);
    const V_EE1 = x[ne].sub(x[ne1]).scale(type_f);
    const V_BB1 = x[nb].sub(x[nb1]).scale(type_f);
    const V_CC3 = x[nc].sub(x[nc3]).scale(type_f);
    const V_C3C4 = x[nc3].sub(x[nc4]).scale(type_f);
    const V_C4C1 = x[nc4].sub(x[nc1]).scale(type_f);
    const V_SC1 = x[ns].sub(x[nc1]).scale(type_f);
    const V_SC4 = x[ns].sub(x[nc4]).scale(type_f);
    const V_SC3 = x[ns].sub(x[nc3]).scale(type_f);
    const V_BC3 = x[nb].sub(x[nc3]).scale(type_f);
    const V_C1B1 = x[nc1].sub(x[nb1]).scale(type_f);
    const V_B1S = x[nb1].sub(x[ns]).scale(type_f);
    const V_B2S = x[nb2].sub(x[ns]).scale(type_f);
    const V_BS = x[nb].sub(x[ns]).scale(type_f);

    // ================================================================
    // Temperature Scaling (Eqs. 4.17-4.74) — x-dependent via VdT
    // ================================================================
    const TEMP: f64 = 27.0; // circuit ambient, typically passed externally
    const TK = VdT.addC(TEMP + P.dta + 273.15);
    const Tamb = TEMP + P.dta + 273.15;
    const TRK = P.tref + 273.15;
    const tN = TK.scale(1.0 / TRK);
    const VT = TK.scale(kB_q);
    const VTR = kB_q * TRK;
    // inv_VdeltaT = 1/VT - 1/VTR
    const inv_VdeltaT = S.con(1.0).div(VT).addC(-1.0 / VTR);

    const ln_tN = logC(S, tN, 1.0e-30);

    // NFF/NFR temperature dependence (Eqs 4.77-4.78)
    const dT_temp = TK.addC(-TRK);
    const NFF_T = if (P.tNFF != 0.0) blk: {
        const nff_tmp = dT_temp.scale(P.tNFF).addC(1.0).scale(P.NFF);
        const nff_ml = max_logexp(S, nff_tmp, 1.0, 0.001);
        break :blk nff_ml.addC(-0.001 * 0.693147180559945);
    } else S.con(P.NFF);

    const NFR_T = if (P.tNFR != 0.0) blk: {
        const nfr_tmp = dT_temp.scale(P.tNFR).addC(1.0).scale(P.NFR);
        const nfr_ml = max_logexp(S, nfr_tmp, 1.0, 0.001);
        break :blk nfr_ml.addC(-0.001 * 0.693147180559945);
    } else S.con(P.NFR);

    // Diffusion voltages (temperature scaled) (Eqs 4.23-4.28)
    // UdET = -3*VT*ln_tN + VdE*tN + (1-tN)*VgB
    const UdET = VT.mul(ln_tN).scale(-3.0).add(tN.scale(P.VdE)).add(tN.neg().addC(1.0).scale(P.VgB));
    const VdET = diffVolt(S, VT, UdET);

    const UdCT = VT.mul(ln_tN).scale(-3.0).add(tN.scale(P.VdC)).add(tN.neg().addC(1.0).scale(P.VgC));
    const VdCT = diffVolt(S, VT, UdCT);

    const UdCctcT = VT.mul(ln_tN).scale(-3.0).add(tN.scale(P.VdCctc)).add(tN.neg().addC(1.0).scale(P.VgC));
    const VdCctcT = diffVolt(S, VT, UdCctcT);

    const UKnbrT = VT.mul(ln_tN).scale(-3.0).add(tN.scale(P.VKnbr)).add(tN.neg().addC(1.0).scale(P.VgKnbr));
    const VKnbrT = diffVolt(S, VT, UKnbrT);

    // Depletion capacitance ratios (needed for Early voltage and XpT)
    const vde_vdet = VdET.maxC(1.0e-30);
    const vde_vdet_r = S.con(P.VdE).div(vde_vdet);

    const vdc_vdct_ratio = S.con(P.VdC).div(VdCT.maxC(1.0e-30));
    const vdc_vdct_pc = logC(S, vdc_vdct_ratio, 1.0e-30).scale(P.pC).exp();
    // XpT = Xp / max((1-Xp)*vdc_vdct_pc + Xp, 1e-30)
    const xpt_den = vdc_vdct_pc.scale(1.0 - P.Xp).addC(P.Xp).maxC(1.0e-30);
    const XpT = S.con(P.Xp).div(xpt_den);

    // Resistances (temperature) (Eqs 4.33-4.37)
    const RET = ln_tN.scale(P.AE).exp().scale(P.RE);
    const RBvT = ln_tN.scale(P.AB - P.AQB0).exp().scale(P.RBv);
    const RBcT = ln_tN.scale(P.Aex).exp().scale(P.RBc);
    const RCvT = ln_tN.scale(P.Aepi).exp().scale(P.RCv);
    const RCcT = ln_tN.scale(P.AC).exp().scale(P.RCc);
    const RCblxT = ln_tN.scale(P.ACbl).exp().scale(P.RCblx);
    const RCbliT = ln_tN.scale(P.ACbl).exp().scale(P.RCbli);

    // Conductances (Eqs 4.37d-4.37f)
    const GCcT = if (P.RCc > 0.0) S.con(1.0).div(RCcT) else S.con(0.0);
    const GCblxT = if (P.RCblx > 0.0) S.con(1.0).div(RCblxT) else S.con(0.0);
    const GCbliT = if (P.RCbli > 0.0) S.con(1.0).div(RCbliT) else S.con(0.0);

    // Currents (temperature) (Eqs 4.38-4.57)
    // IsT = Is * exp((4-AB-AQB0+dAIs)/NFF_T*ln_tN) * exp(min(-VgB/NFF_T*inv_VdeltaT, 80))
    const IsT = S.con(P.Is)
        .mul(S.con(4.0 - P.AB - P.AQB0 + P.dAIs).div(NFF_T).mul(ln_tN).exp())
        .mul(expC(S, S.con(-P.VgB).div(NFF_T).mul(inv_VdeltaT), 80.0));
    const IkT = ln_tN.scale(1.0 - P.AB).exp().scale(P.Ik);
    const IstatT = tN.maxC(1.0e-30).sqrt().scale(P.Istat).mul(expC(S, dT_temp.scale(P.Ktat_coeff), 80.0));

    const IBInbrT = expC(S, inv_VdeltaT.scale(-P.VgBnbr / P.NBI), 80.0).scale(P.IBInbr);
    const IBInbrqsT = expC(S, inv_VdeltaT.scale(-P.VgBnbrqs), 80.0).scale(P.IBInbrqs);
    const ISBInbrT = expC(S, inv_VdeltaT.scale(-P.VgSBnbr / P.NSBI), 80.0).scale(P.IBInbrs);

    const IBIT = ln_tN.scale((4.0 - P.AE + P.dAIs) / P.NBI).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.VgE / P.NBI), 80.0)).scale(P.IBI);
    const ISBIT = ln_tN.scale((4.0 - P.AE + P.dAIs) / P.NSBI).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.VgE / P.NSBI), 80.0)).scale(P.ISBI);
    const ISSIB2T = ln_tN.scale(6.0 - 2.0 * P.mSLf).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.Vgj / P.mSLf), 80.0)).scale(P.ISBf);

    const IBXT = ln_tN.scale(4.0 - P.ACX + P.dAIs).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.VgCX), 80.0)).scale(P.IBX);
    const IkBXT = ln_tN.scale(1.0 - P.ACX).exp().scale(P.IkBX);

    const IBfT = ln_tN.scale(6.0 - 2.0 * P.mLf).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.Vgj / P.mLf), 80.0)).scale(P.IBf);
    const IBrT = ln_tN.scale(6.0 - 2.0 * P.mLr).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.VgC / P.mLr), 80.0)).scale(P.IBr);

    const ISIBrelT = ln_tN.scale(4.0 / P.NFIBrel).exp()
        .mul(expC(S, inv_VdeltaT.scale(-P.Vgj / P.NFIBrel), 80.0)).scale(P.ISIBrel);

    // Early voltages (temperature) (Eqs 4.52-4.53)
    const VefT = ln_tN.scale(P.AQB0).exp().scale(P.Vef).div(xpt_den);
    const VerT = ln_tN.scale(P.AQB0).exp().scale(P.Ver).mul(logC(S, vde_vdet_r, 1.0e-30).scale(P.pE).exp());

    // Substrate currents (temperature) (Eqs 4.54-4.57)
    const ISsT = ln_tN.scale(4.0 - P.AS).exp().mul(expC(S, inv_VdeltaT.scale(-P.VgS), 80.0)).scale(P.ISs);
    const IksT = ln_tN.scale(1.0 - P.AS).exp().scale(P.Iks);
    const ICSsT = ln_tN.scale(3.5 - 0.5 * P.Asub).exp().mul(expC(S, inv_VdeltaT.scale(-P.VgS), 80.0)).scale(P.ICSs);
    const IkcsT = ln_tN.scale(1.0 - P.Asub).exp().scale(P.Ikcs);

    // Avalanche temperature (Eq 4.63)
    const BavlT = dT_temp.scale(P.TBavl).addC(1.0).scale(P.Bavl);
    // SWAVL=2 Bn temperature (Eq 4.64)
    const dt_300 = TK.addC(-300.0);
    const BnT = if (TK.val() < 525.0)
        dt_300.scale(7.2e-4).add(dt_300.mul(dt_300).scale(-1.6e-6)).addC(1.0).scale(P.Bn)
    else
        S.con(P.Bn * 1.081);

    // Heterojunction temperature (Eq 4.65)
    const dEgT = ln_tN.scale(P.AQB0).exp().scale(P.dEg);

    // Zener tunneling temperature (Eqs 4.66-4.73)
    // TRK terms are x-free; TK terms are x-dependent.
    const VgZEB0K = max_logexp_f(P.VgZEB + P.AVgEB * TRK * TRK / (TRK + P.TVgEB), 0.05, 0.1);
    const VgZEBT = max_logexp(S, TK.mul(TK).div(TK.addC(P.TVgEB)).scale(-P.AVgEB).addC(VgZEB0K), 0.05, 0.1);
    const NzEBT = logC(S, VgZEBT.scale(1.0 / P.VgZEB), 1.0e-30).scale(1.5).exp()
        .mul(logC(S, VdET.scale(1.0 / P.VdE), 1.0e-30).scale(P.pE - 1.0).exp()).scale(P.NzEB);
    const IzEBT = logC(S, VgZEBT.scale(1.0 / P.VgZEB), 1.0e-30).scale(-0.5).exp()
        .mul(logC(S, VdET.scale(1.0 / P.VdE), 1.0e-30).scale(2.0 - P.pE).exp())
        .mul(expC(S, NzEBT.neg().addC(P.NzEB), 80.0)).scale(P.IzEB);

    const VgZCB0K = max_logexp_f(P.VgZCB + P.AVgCB * TRK * TRK / (TRK + P.TVgCB), 0.05, 0.1);
    const VgZCBT = max_logexp(S, TK.mul(TK).div(TK.addC(P.TVgCB)).scale(-P.AVgCB).addC(VgZCB0K), 0.05, 0.1);
    const NzCBT = logC(S, VgZCBT.scale(1.0 / P.VgZCB), 1.0e-30).scale(1.5).exp()
        .mul(logC(S, VdCT.scale(1.0 / P.VdC), 1.0e-30).scale(P.pC - 1.0).exp()).scale(P.NzCB);
    const IzCBT = logC(S, VgZCBT.scale(1.0 / P.VgZCB), 1.0e-30).scale(-0.5).exp()
        .mul(logC(S, VdCT.scale(1.0 / P.VdC), 1.0e-30).scale(2.0 - P.pC).exp())
        .mul(expC(S, NzCBT.neg().addC(P.NzCB), 80.0)).scale(P.IzCB);

    // Self-heating thermal resistance (Eq 4.74) — Tamb is x-free
    const Rth_Tamb = P.Rth * contract.fmath.exp(P.Ath * contract.fmath.log(@max(Tamb / TRK, 1.0e-30)));

    // ================================================================
    // Emitter Depletion Charge voltages (Eqs 4.173-4.175)
    // ================================================================
    const VFE = VdET.scale(1.0 - contract.fmath.exp(-1.0 / P.pE * contract.fmath.log(alpha_jE)));
    const vjE_arg = V_B2E1.sub(VFE).div(VdET.scale(0.1)).minC(80.0);
    const VjE = V_B2E1.sub(VdET.scale(0.1).mul(vjE_arg.exp().addC(1.0).log()));
    const E0EB = logC(S, VjE.div(VdET).neg().addC(1.0), 1.0e-30).scale(1.0 - P.pE).exp();
    const VtE = VdET.scale(1.0 / (1.0 - P.pE)).mul(E0EB.neg().addC(1.0)).add(V_B2E1.sub(VjE).scale(alpha_jE));

    // ================================================================
    // Intrinsic Collector Depletion (Eqs 4.185-4.192)
    // ================================================================
    // bjC = (alpha_jC - XpT)/max(1-XpT, 1e-30)
    const bjC = XpT.neg().addC(alpha_jC).div(XpT.neg().addC(1.0).maxC(1.0e-30));
    // VFC = VdCctcT*(1 - exp(-1/pC*log(max(bjC,1e-30))))
    const VFC = VdCctcT.mul(logC(S, bjC, 1.0e-30).scale(-1.0 / P.pC).exp().neg().addC(1.0));

    // ================================================================
    // Epilayer Model (Eqs 4.146-4.166)
    // ================================================================
    const exp_b2c2_vdc = expC(S, V_B2C2.sub(VdCT).div(VT), 80.0);
    const exp_b2c1_vdc = expC(S, V_B2C1.sub(VdCT).div(VT), 80.0);
    const K0 = exp_b2c2_vdc.scale(4.0).addC(1.0).sqrt();
    const KW = exp_b2c1_vdc.scale(4.0).addC(1.0).sqrt();
    const pW = exp_b2c1_vdc.scale(2.0).div(KW.addC(1.0));
    // Ec = VT*(K0 - KW - log(max((K0+1)/max(KW+1,1e-30), 1e-30)))
    const Ec = VT.mul(K0.sub(KW).sub(logC(S, K0.addC(1.0).div(KW.addC(1.0).maxC(1.0e-30)), 1.0e-30)));
    const IC1C2 = Ec.add(V_C1C2).div(RCvT);

    const ic1c2_pos = IC1C2.val() > 0.0;

    // --- Forward mode ---
    const Vqs_th_fwd = VdCT.add(VT.scale(2.0).mul(logC(S, IC1C2.mul(RCvT).div(VT.scale(2.0)).addC(1.0), 1.0e-30))).sub(V_B2C1);
    // Vqs_raw = 0.5*(Vqs_th + sqrt(Vqs_th^2 + 4*(0.1*VdCT)^2))
    const vdct01 = VdCT.scale(0.1);
    const Vqs_raw = Vqs_th_fwd.add(Vqs_th_fwd.mul(Vqs_th_fwd).add(vdct01.mul(vdct01).scale(4.0)).sqrt()).scale(0.5);
    const Vqs = if (ic1c2_pos) Vqs_raw else vdct01;

    // Iqs = Vqs/SCRCv * (Vqs + Ihc*SCRCv) / max(Vqs + Ihc*RCvT, 1e-30)
    const Iqs = Vqs.scale(1.0 / P.SCRCv).mul(Vqs.addC(P.Ihc * P.SCRCv)).div(Vqs.add(RCvT.scale(P.Ihc)).maxC(1.0e-30));

    // alpha (Eq 4.154)
    const alpha_arg = IC1C2.div(Iqs.maxC(1.0e-30)).addC(-1.0).scale(1.0 / P.axi).minC(80.0);
    const alpha_num = alpha_arg.exp().addC(1.0).log().scale(P.axi).addC(1.0);
    const alpha_den = 1.0 + P.axi * contract.fmath.log(1.0 + contract.fmath.exp(@min(-1.0 / P.axi, 80.0)));
    const alpha = if (ic1c2_pos) alpha_num.scale(1.0 / @max(alpha_den, 1.0e-30)) else S.con(1.0);

    // yi (Eq 4.157)
    const v_qs = Vqs.scale(1.0 / @max(P.Ihc * P.SCRCv, 1.0e-30));
    // yi = (1 + sqrt(1 + 4*alpha*v_qs*(1+v_qs))) / (2*alpha*(1+v_qs))
    const yi = alpha.mul(v_qs).mul(v_qs.addC(1.0)).scale(4.0).addC(1.0).sqrt().addC(1.0)
        .div(alpha.mul(v_qs.addC(1.0)).scale(2.0));

    // xi/Wepi (Eq 4.158)
    const xi_Wepi_fwd = yi.div(pW.mul(yi).addC(1.0)).neg().addC(1.0);

    // g (Eq 4.159)
    const g_fwd = IC1C2.mul(RCvT).div(VT.scale(2.0)).mul(xi_Wepi_fwd);

    // p0* (Eqs 4.160, 4.275 numerically stable)
    const gm1_half = g_fwd.addC(-1.0).scale(0.5);
    // disc = gm1_half^2 + 2*g + pW*(pW + g + 1)
    const disc = gm1_half.mul(gm1_half).add(g_fwd.scale(2.0)).add(pW.mul(pW.add(g_fwd).addC(1.0)));
    const sqrt_disc = disc.maxC(0.0).sqrt();
    const p0star_fwd_g_gt_1 = gm1_half.add(sqrt_disc);
    // (2*g + pW*(pW+g+1)) / max((1-g)/2 + sqrt_disc, 1e-30)
    const p0star_fwd_g_le_1 = g_fwd.scale(2.0).add(pW.mul(pW.add(g_fwd).addC(1.0)))
        .div(g_fwd.neg().addC(1.0).scale(0.5).add(sqrt_disc).maxC(1.0e-30));
    const p0star_fwd_raw = if (g_fwd.val() > 1.0) p0star_fwd_g_gt_1 else p0star_fwd_g_le_1;
    const p0star_fwd = p0star_fwd_raw.maxC(P.p0starlim);

    // exp(V*_B2C2 / VT) forward (Eq 4.161)
    const exp_Vstar_fwd = p0star_fwd.mul(p0star_fwd.addC(1.0)).mul(expC(S, VdCT.div(VT), 80.0));

    // --- Reverse mode ---
    const p0star_rev = K0.addC(-1.0).scale(0.5);
    const exp_Vstar_rev = exp_b2c2_vdc.mul(expC(S, VdCT.div(VT), 80.0));

    // Small signal reverse mode xi/Wepi (Eq 4.164)
    const Ec_abs = Ec.abs();
    const vc1c2_abs = V_C1C2.abs();
    const small_signal_rev = (vc1c2_abs.val() < 1.0e-5 * VT.val()) or (Ec_abs.val() < contract.fmath.exp(-40.0) * VT.val() * (K0.val() + KW.val()));
    const pav = p0star_rev.add(pW).scale(0.5);
    const xi_Wepi_rev_normal = Ec.div(Ec.add(V_B2C2).sub(V_B2C1).maxC(1.0e-30));
    const xi_Wepi_rev_small = pav.div(pav.addC(1.0));
    const xi_Wepi_rev = if (small_signal_rev) xi_Wepi_rev_small else xi_Wepi_rev_normal;

    // Select forward vs reverse
    const exp_Vstar_B2C2 = if (ic1c2_pos) exp_Vstar_fwd else exp_Vstar_rev;
    const xi_Wepi = if (ic1c2_pos) xi_Wepi_fwd else xi_Wepi_rev;

    // V*_B2C2 for use in equations (via log of exp_Vstar)
    const Vstar_B2C2_over_VT = logC(S, exp_Vstar_B2C2, 1.0e-300);

    // ================================================================
    // Collector depletion charge voltage VtC (Eqs 4.179-4.192)
    // ================================================================
    const B1_fwd = IC1C2.addC(-P.Ihc).scale(0.5 * P.SCRCv);
    const B2_fwd = RCvT.scale(P.SCRCv * P.Ihc).mul(IC1C2);
    const Vxi0_fwd = B1_fwd.add(B1_fwd.mul(B1_fwd).add(B2_fwd).maxC(0.0).sqrt());
    const Vxi0 = if (ic1c2_pos) Vxi0_fwd else V_C1C2;

    const Vjunc = V_B2C1.add(Vxi0);

    // Vch (Eq 4.184)
    const Vch_fwd = VdCT.mul(IC1C2.div(IC1C2.add(Iqs).maxC(1.0e-30)).scale(2.0).addC(0.1));
    const Vch = if (ic1c2_pos) (if (P.SWVCHC == 1) Vch_fwd else vdct01) else vdct01;

    // VjC (Eq 4.187)
    const vjc_arg = Vjunc.sub(VFC).div(Vch).minC(80.0);
    const VjC = Vjunc.sub(Vch.mul(vjc_arg.exp().addC(1.0).log()));

    // Icap (Eq 4.189)
    const Icap = if (ic1c2_pos) IC1C2.scale(P.Ihc).div(IC1C2.addC(P.Ihc).maxC(1.0e-30)) else IC1C2;

    // fI (Eq 4.190)
    const fI = logC(S, Icap.scale(-1.0 / P.Ihc).addC(1.0), 1.0e-30).scale(P.mC).exp();

    // VCV (Eq 4.191)
    // VCV = VdCctcT/(1-pC) * (1 - fI*exp((1-pC)*log(max(1-VjC/VdCctcT,1e-30))) + fI*bjC*(Vjunc-VjC))
    const vcv_inner = fI.mul(logC(S, VjC.div(VdCctcT).neg().addC(1.0), 1.0e-30).scale(1.0 - P.pC).exp()).neg().addC(1.0)
        .add(fI.mul(bjC).mul(Vjunc.sub(VjC)));
    const VCV = VdCctcT.scale(1.0 / (1.0 - P.pC)).mul(vcv_inner);
    const VtC = XpT.neg().addC(1.0).mul(VCV).add(XpT.mul(V_B2C1));

    // ================================================================
    // Base charge and Early effect (Eqs 4.79-4.82)
    // ================================================================
    const q0I = if (P.dEg != 0.0) blk: {
        const dEgT_VT = dEgT.div(VT);
        const exp_deg = expC(S, dEgT_VT, 80.0);
        const num = expC(S, VtE.div(VerT).addC(1.0), 80.0).mul(dEgT_VT)
            .sub(expC(S, VtC.div(VefT).neg(), 80.0).mul(dEgT_VT));
        break :blk num.div(exp_deg.addC(-1.0).maxC(1.0e-30));
    } else VtE.div(VerT).addC(1.0).add(VtC.div(VefT));

    const q1I = q0I.add(q0I.mul(q0I).addC(0.01).sqrt()).scale(0.5);

    // n0, nB for high injection (Eqs 4.206-4.210)
    const f1 = IsT.scale(4.0).div(IkT).mul(expC(S, V_B2E1.div(NFF_T.mul(VT)), P.vexlim));
    const n0 = f1.div(f1.addC(1.0).sqrt().addC(1.0));
    const f2 = IsT.scale(4.0).div(IkT).mul(exp_Vstar_B2C2);
    const nB = f2.div(f2.addC(1.0).sqrt().addC(1.0));

    // qBI (Eq 4.81)
    const qBI = q1I.mul(n0.scale(0.5).add(nB.scale(0.5)).addC(1.0));

    // Main currents (Eqs 4.75-4.76, 4.82)
    const If = IsT.mul(expC(S, V_B2E1.div(NFF_T.mul(VT)), P.vexlim));
    // Ir
    const Ir = if (ic1c2_pos)
        IsT.scale(P.Issr).mul(expC(S, Vstar_B2C2_over_VT.div(NFR_T), P.vexlim))
    else
        IsT.scale(P.Issr).mul(expC(S, V_B2C2.div(NFR_T.mul(VT)), P.vexlim));

    const IN = If.sub(Ir).div(qBI);

    // ================================================================
    // Forward Base Currents (Eqs 4.83-4.104)
    // ================================================================
    const exp_b2e1_nbi = expC(S, V_B2E1.div(VT.scale(P.NBI)), P.vexlim);
    const exp_b1e1_nsbi = expC(S, V_B1E1.div(VT.scale(P.NSBI)), P.vexlim);

    var IB1: S = S.con(0.0);
    var IBS1: S = S.con(0.0);

    if (P.SWIB1 == 0) {
        // SWIB1=0 model (Eqs 4.83-4.89)
        const IB1E = IBIT.scale(1.0 - P.Xrec).mul(exp_b2e1_nbi.addC(-1.0));
        const IB1nbr_EB = IBIT.scale(P.Xrec).mul(exp_b2e1_nbi.addC(-1.0)).mul(VtC.div(VefT).addC(1.0));
        const IBqs1nbr = IBIT.scale(P.Xrec).mul(expC(S, Vstar_B2C2_over_VT, P.vexlim).addC(-1.0)).mul(VtC.div(VefT).addC(1.0));
        IB1 = IB1E.add(IB1nbr_EB).add(IBqs1nbr);
        IBS1 = ISBIT.mul(exp_b1e1_nsbi.addC(-1.0));
    } else {
        // SWIB1=1 model (NBR) (Eqs 4.90-4.97)
        const IB1E = IBIT.mul(exp_b2e1_nbi.addC(-1.0));
        const denom_nbr = expC(S, V_B2E1.sub(VKnbrT).div(VT), P.vexlim).scale(4.0).addC(1.0).sqrt().addC(1.0);
        const IB1nbr_EB = IBInbrT.scale(2.0).mul(VtC.div(VefT).addC(1.0)).mul(exp_b2e1_nbi.addC(-1.0)).div(denom_nbr);
        const exp_vstar = expC(S, Vstar_B2C2_over_VT, P.vexlim);
        const in_ist = IN.div(IsT.maxC(1.0e-300));
        const exp_in = expC(S, in_ist, P.vexlim);
        const IBqs1nbr = IBInbrqsT.mul(exp_vstar.addC(-1.0)).mul(exp_in.addC(-0.001)).div(exp_in.addC(-0.001).addC(1.0).maxC(1.0e-30));
        IB1 = IB1E.add(IB1nbr_EB).add(IBqs1nbr);

        const IBS1E = ISBIT.mul(exp_b1e1_nsbi.addC(-1.0));
        const denom_nbrs = expC(S, V_B1E1.sub(VKnbrT).div(VT), P.vexlim).scale(4.0).addC(1.0).sqrt().addC(1.0);
        const IBS1nbr = ISBInbrT.scale(2.0).mul(exp_b1e1_nsbi.addC(-1.0)).div(denom_nbrs);
        IBS1 = IBS1E.add(IBS1nbr);
    }

    // BTBT current (Eqs 4.98-4.99)
    const Vtmp1 = min_logexp(S, V_B2E1, P.Vbtbt, 0.001);
    const IBTBT = Vtmp1.scale(P.Kbtbt).mul(Vtmp1.neg().addC(P.Vbtbt)).mul(Vtmp1.neg().addC(P.Vbtbt));

    // TAT current (Eqs 4.100-4.101)
    const Vtmp2 = max_logexp(S, V_B2E1, 0.0, 0.0001);
    const ITAT = IstatT.mul(expC(S, Vtmp2.scale(1.0 / P.Vtat), P.vexlim).addC(-1.0));

    // Non-ideal base currents (Eqs 4.102-4.104)
    const IB2 = IBfT.mul(expC(S, V_B2E1.div(VT.scale(P.mLf)), P.vexlim).addC(-1.0)).add(V_B2E1.scale(GMIN));
    const IBS2 = ISSIB2T.mul(expC(S, V_B2E1.div(VT.scale(P.mSLf)), P.vexlim).addC(-1.0));
    const IBrel = ISIBrelT.mul(expC(S, V_B2E1.div(VT.scale(P.NFIBrel)), P.vexlim).addC(-1.0));

    // ================================================================
    // Reverse Base Currents (Eqs 4.105-4.108)
    // ================================================================
    const IB3_raw = IBrT.mul(expC(S, V_B1C4.div(VT.scale(P.mLr)), P.vexlim).addC(-1.0)).add(V_B1C4.scale(GMIN));

    // Substrate currents (Eqs 4.106)
    const exp_b2c2_vt = expC(S, V_B2C2.div(VT), P.vexlim);
    const exp_b1c4_vt = expC(S, V_B1C4.div(VT), P.vexlim);
    const exp_sc1_vt = expC(S, V_SC1.div(VT), P.vexlim);
    const exp_sc4_vt = expC(S, V_SC4.div(VT), P.vexlim);

    var Isub_int: S = S.con(0.0);
    var Isub: S = S.con(0.0);

    if (P.EXSUB == 0) {
        const denom_sub_int = ISsT.scale(4.0).div(IksT).mul(exp_b2c2_vt).addC(1.0).sqrt().addC(1.0);
        Isub_int = ISsT.scale(P.Xisubi * 2.0).mul(exp_b2c2_vt.addC(-1.0)).div(denom_sub_int);

        const denom_sub = ISsT.scale(4.0).div(IksT).mul(exp_b1c4_vt).addC(1.0).sqrt().addC(1.0);
        Isub = ISsT.scale((1.0 - P.Xisubi) * 2.0).mul(exp_b1c4_vt.addC(-1.0)).div(denom_sub);
    } else {
        const swvsch_f: f64 = @floatFromInt(P.SWVSCH);
        const denom_sub_int = ISsT.scale(4.0).div(IksT).mul(exp_b2c2_vt.add(exp_sc1_vt.scale(swvsch_f))).addC(1.0).sqrt().addC(1.0);
        Isub_int = ISsT.scale(P.Xisubi * 2.0).mul(exp_b2c2_vt.sub(exp_sc1_vt)).div(denom_sub_int);

        const denom_sub = ISsT.scale(4.0).div(IksT).mul(exp_b1c4_vt.add(exp_sc4_vt.scale(swvsch_f))).addC(1.0).sqrt().addC(1.0);
        Isub = ISsT.scale((1.0 - P.Xisubi) * 2.0).mul(exp_b1c4_vt.sub(exp_sc4_vt)).div(denom_sub);
    }

    // Substrate-collector diode (Eq 4.107)
    const swvsch_f2: f64 = @floatFromInt(P.SWVSCH);
    const denom_isf = ICSsT.scale(swvsch_f2 * 4.0).div(IkcsT).mul(exp_sc1_vt).addC(1.0).sqrt().addC(1.0);
    const ISf = ICSsT.scale(2.0).mul(exp_sc1_vt.addC(-1.0)).div(denom_isf);

    // Extrinsic reverse base current (Eq 4.108)
    const denom_iex = IBXT.scale(4.0).div(IkBXT).mul(exp_b1c4_vt).addC(1.0).sqrt().addC(1.0);
    const Iex_raw = IBXT.scale(2.0).mul(exp_b1c4_vt.addC(-1.0)).div(denom_iex);

    // ================================================================
    // CB Junction Breakdown (SWJBRCB) (Eqs 4.167-4.172)
    // ================================================================
    const eps_brcb: f64 = 1.0e-6;
    const Vcbeff = V_C1B1.mul(V_C1B1).addC(eps_brcb * eps_brcb).sqrt().add(V_C1B1).scale(0.5);
    const alpha_brcb = 1.0 - 1.0 / P.Frevcb;
    const f_stop = contract.fmath.exp(P.Pbrcb * contract.fmath.log(1.0 / (1.0 - alpha_brcb)));
    const df_brcb = f_stop * f_stop * contract.fmath.exp((P.Pbrcb - 1.0) * contract.fmath.log(@max(alpha_brcb, 1.0e-30))) * P.Pbrcb / P.Vbrcb;

    const fbrcb = if (P.SWJBRCB == 1) blk: {
        const v_ratio = Vcbeff.scale(1.0 / P.Vbrcb);
        break :blk if (v_ratio.val() < alpha_brcb)
            logC(S, S.con(1.0).div(v_ratio.neg().addC(1.0).maxC(1.0e-30)), 1.0e-30).scale(P.Pbrcb).exp()
        else
            Vcbeff.addC(-alpha_brcb * P.Vbrcb).scale(df_brcb).addC(f_stop);
    } else S.con(1.0);

    const IB3 = fbrcb.mul(IB3_raw);
    var Iex = fbrcb.mul(Iex_raw);

    // ================================================================
    // Avalanche Current (Eqs 4.109-4.134)
    // ================================================================
    const avl_mask: f64 = if ((IC1C2.val() > 0.0) and (V_B2C1.val() < VdCT.val())) 1.0 else 0.0;

    var GEM: S = S.con(0.0);

    if (P.SWAVL == 1) {
        // Eqs 4.111-4.112
        const phi_avl = V_C2B1.addC(P.VdCavl).mul(expC(S, IN.scale(-1.0 / @max(P.ITOavl, 1.0e-30)), 80.0));
        const phi_cavl = logC(S, phi_avl.abs(), 1.0e-30).scale(P.Cavl).exp();
        GEM = S.con(P.Aavl).div(BavlT.maxC(1.0e-30)).mul(phi_avl).mul(expC(S, BavlT.neg().mul(phi_cavl), 80.0));
    } else if (P.SWAVL == 2) {
        // Eqs 4.113-4.127
        const dEdx0 = 2.0 * P.Vavl / (P.Wavl * P.Wavl);
        const ic_ihc_ratio = Icap.scale(1.0 / P.Ihc);
        // xD_sq = 2/dEdx0 * max(VdCT - V_B2C1, 1e-30) / max(1 - ic_ihc, 1e-30)
        const xD_sq = VdCT.sub(V_B2C1).maxC(1.0e-30).scale(2.0 / dEdx0).div(ic_ihc_ratio.neg().addC(1.0).maxC(1.0e-30));
        const xD = xD_sq.maxC(0.0).sqrt();
        const Weff_val = if (P.EXAVL == 1) blk_w: {
            const xi_2wepi = xi_Wepi.scale(0.5);
            break :blk_w xi_2wepi.neg().addC(1.0).mul(xi_2wepi.neg().addC(1.0)).scale(P.Wavl);
        } else S.con(P.Wavl);
        const WD = xD.mul(Weff_val).div(xD.mul(xD).add(Weff_val.mul(Weff_val)).sqrt());
        const Eav_avl = VdCT.sub(V_B2C1).maxC(1.0e-30).div(WD.maxC(1.0e-30));
        const E0_avl = Eav_avl.add(WD.scale(0.5 * dEdx0).mul(ic_ihc_ratio.neg().addC(1.0)));

        const EM = if (P.EXAVL == 1) blk_em: {
            const xi_Wepi_c = xi_Wepi; // reuse
            const SHW_val = xi_Wepi_c.scale(2.0).addC(1.0).scale(2.0 * P.SfH).addC(1.0);
            const Efi = (1.0 + P.SfH) / (1.0 + 2.0 * P.SfH);
            // EW = Eav - 0.5*WD*dEdx0*(Efi - IC1C2/(Ihc*SHW))
            const EW = Eav_avl.sub(WD.scale(0.5 * dEdx0).mul(IC1C2.div(SHW_val.scale(P.Ihc)).neg().addC(Efi)));
            const em_disc = EW.sub(E0_avl).mul(EW.sub(E0_avl)).add(Eav_avl.mul(Eav_avl).scale(0.1).mul(ic_ihc_ratio));
            break :blk_em EW.add(E0_avl).add(em_disc.maxC(0.0).sqrt()).scale(0.5);
        } else E0_avl;

        const lambdaD = EM.mul(WD).div(EM.sub(Eav_avl).scale(2.0).maxC(1.0e-30));
        const ratio_em = Eav_avl.div(EM.maxC(1.0e-30)).neg().addC(1.0).abs();

        GEM = if (ratio_em.val() < 1.0e-7)
            expC(S, BnT.neg().div(EM.maxC(1.0e-30)), 80.0).mul(Weff_val).scale(P.An)
        else blk_gem: {
            const inv_EM = S.con(1.0).div(EM.maxC(1.0e-30));
            const term1 = expC(S, BnT.neg().mul(inv_EM), 80.0);
            const term2 = expC(S, BnT.neg().mul(inv_EM).mul(Weff_val.div(lambdaD.maxC(1.0e-30)).addC(1.0)), 80.0);
            break :blk_gem S.con(P.An).div(BnT.maxC(1.0e-30)).mul(EM).mul(lambdaD).mul(term1.sub(term2));
        };
    } else if (P.SWAVL == 3) {
        // Eqs 4.128-4.131
        const vdep_base_safe = V_B2C1.neg().addC(P.VdCavl).maxC(1.0e-30);
        // Vdep_tmp = vdep_base_safe^Cavl * (1 - IN/(Ihcavl+IN))^Davl
        const Vdep_tmp = logC(S, vdep_base_safe, 1.0e-30).scale(P.Cavl).exp()
            .mul(logC(S, IN.div(IN.addC(P.Ihcavl).maxC(1.0e-30)).neg().addC(1.0), 1.0e-30).scale(P.Davl).exp());

        const Vdep = if (P.EXAVL == 1) blk_vd: {
            const IN_shift = max_logexp(S, IN.addC(-P.Ionexavl).scale(1.0 / @max(P.Ihcavl, 1.0e-30)), 1.0, P.Aexavl);
            break :blk_vd Vdep_tmp.mul(logC(S, IN_shift, 1.0e-30).scale(P.Eavl_p).exp());
        } else Vdep_tmp;

        GEM = S.con(P.Aavl).div(BavlT.maxC(1.0e-30)).mul(V_B2C1.neg().addC(P.VdCavl)).mul(expC(S, BavlT.neg().mul(Vdep), 80.0));
    }

    // GEM Limiting (SWGEMLIM=1) (Eqs 4.132-4.134)
    if (P.SWGEMLIM == 1 and P.SWAVL != 0) {
        const RB2_avl = RBvT.scale(3.0).div(q1I.mul(n0.scale(0.5).add(nB.scale(0.5)).addC(1.0)).maxC(1.0e-30));
        // Gmax = VT/max(IN*(RBcT+RB2_avl),1e-30) + qBI*IBIT/max(IsT,1e-30) + RET/max(RBcT+RB2_avl,1e-30)
        const rb_sum = RBcT.add(RB2_avl);
        const Gmax = VT.div(IN.mul(rb_sum).maxC(1.0e-30))
            .add(qBI.mul(IBIT).div(IsT.maxC(1.0e-30)))
            .add(RET.div(rb_sum.maxC(1.0e-30)));

        if (P.SWAVL == 3) {
            GEM = min_logexp_S_S(S, GEM, Gmax, 1.0e-6);
        } else {
            GEM = GEM.mul(Gmax).div(GEM.add(Gmax).maxC(1.0e-30));
        }
    }

    GEM = GEM.scale(avl_mask);
    const Iavl = IN.mul(GEM);

    // ================================================================
    // EB Zener Tunneling Current (Eqs 4.135-4.137)
    // ================================================================
    const IztEB = if (P.IzEB > 0.0) blk_zeb: {
        const V_zeb = V_B2E1.minC(-P.Vzmin);
        const xz_eb = V_zeb.div(VdET);
        const neg_xz = xz_eb.neg();
        const neg_xz_2ppE = logC(S, neg_xz, 1.0e-30).scale(2.0 + P.pE).exp();
        // E0EB_z = pE*(1-pE)*(2 - 3*xz*(pE-1) - 6*xz^2*(pE-1+xz)) / max(6*neg_xz_2ppE, 1e-30)
        const e0_num = xz_eb.scale(-3.0 * (P.pE - 1.0))
            .add(xz_eb.mul(xz_eb).scale(-6.0).mul(xz_eb.addC(P.pE - 1.0)))
            .addC(2.0)
            .scale(P.pE * (1.0 - P.pE));
        const E0EB_z = e0_num.div(neg_xz_2ppE.scale(6.0).maxC(1.0e-30));
        const twopmpE = contract.fmath.exp((2.0 - P.pE) * contract.fmath.log(2.0));
        // DzEB_arg = twopmpE*NzEBT * V_zeb / max(VgZEBT*E0EB_z, 1e-30)
        const DzEB_arg = NzEBT.scale(twopmpE).mul(V_zeb).div(VgZEBT.mul(E0EB_z).maxC(1.0e-30));
        // DzEB = -V_zeb - VgZEBT/max(twopmpE*NzEBT,1e-30) * E0EB_z * (1 - exp(min(DzEB_arg,80)))
        const DzEB = V_zeb.neg().sub(VgZEBT.div(NzEBT.scale(twopmpE).maxC(1.0e-30)).mul(E0EB_z).mul(expC(S, DzEB_arg, 80.0).neg().addC(1.0)));
        const twopm1 = contract.fmath.exp((1.0 - P.pE) * contract.fmath.log(2.0));
        // izt_raw = IzEBT/max(twopm1*VdET,1e-30)*DzEB*E0EB_z*exp(min(NzEBT*(1 - twopm1/max(E0EB_z,1e-30)),80))
        // exp arg = NzEBT * (1 - twopm1/max(E0EB_z, 1e-30))
        const zeb_exp_arg = S.con(twopm1).div(E0EB_z.maxC(1.0e-30)).neg().addC(1.0).mul(NzEBT);
        const izt_raw = IzEBT.div(VdET.scale(twopm1).maxC(1.0e-30)).mul(DzEB).mul(E0EB_z)
            .mul(expC(S, zeb_exp_arg, 80.0));
        const rev_mask: f64 = if (V_B2E1.val() < 0.0) 1.0 else 0.0;
        break :blk_zeb izt_raw.scale(rev_mask);
    } else S.con(0.0);

    // ================================================================
    // CB Zener Tunneling Current (Eqs 4.138-4.140)
    // ================================================================
    const IztCB_raw = if (P.IzCB > 0.0) blk_zcb: {
        const V_zcb = V_B2C1.minC(-P.Vzmin);
        const xz_cb = V_zcb.div(VdCctcT);
        const neg_xz_cb = xz_cb.neg();
        const neg_xz_2ppC = logC(S, neg_xz_cb, 1.0e-30).scale(2.0 + P.pC).exp();
        const e0c_num = xz_cb.scale(-3.0 * (P.pC - 1.0))
            .add(xz_cb.mul(xz_cb).scale(-6.0).mul(xz_cb.addC(P.pC - 1.0)))
            .addC(2.0)
            .scale(P.pC * (1.0 - P.pC));
        const E0CB_z = e0c_num.div(neg_xz_2ppC.scale(6.0).maxC(1.0e-30));
        const twopmpC = contract.fmath.exp((2.0 - P.pC) * contract.fmath.log(2.0));
        const DzCB_arg = NzCBT.scale(twopmpC).mul(V_zcb).div(VgZCBT.mul(E0CB_z).maxC(1.0e-30));
        const DzCB = V_zcb.neg().sub(VgZCBT.div(NzCBT.scale(twopmpC).maxC(1.0e-30)).mul(E0CB_z).mul(expC(S, DzCB_arg, 80.0).neg().addC(1.0)));
        const twopm1_cb = contract.fmath.exp((1.0 - P.pC) * contract.fmath.log(2.0));
        const zcb_exp_arg = S.con(twopm1_cb).div(E0CB_z.maxC(1.0e-30)).neg().addC(1.0).mul(NzCBT);
        const izt_raw_cb = IzCBT.div(VdCctcT.scale(twopm1_cb).maxC(1.0e-30)).mul(DzCB).mul(E0CB_z)
            .mul(expC(S, zcb_exp_arg, 80.0));
        const rev_mask_cb: f64 = if (V_B2C1.val() < 0.0) 1.0 else 0.0;
        break :blk_zcb izt_raw_cb.scale(rev_mask_cb);
    } else S.con(0.0);

    const IztCB = fbrcb.mul(IztCB_raw);

    // ================================================================
    // Variable Base Resistance (Eqs 4.141-4.145)
    // ================================================================
    const q0Q = VtE.div(VerT).addC(1.0).add(VtC.div(VefT));
    const q1Q = q0Q.add(q0Q.mul(q0Q).addC(0.01).sqrt()).scale(0.5);
    const qBQ = q1Q.mul(n0.scale(0.5).add(nB.scale(0.5)).addC(1.0));
    const RB2 = RBvT.scale(3.0).div(qBQ.maxC(1.0e-30));

    // IB1B2 (Eq 4.145) = 2*VT/RB2*(exp(V_B1B2/VT)-1) + V_B1B2/RB2
    const IB1B2 = VT.scale(2.0).div(RB2).mul(expC(S, V_B1B2.div(VT), P.vexlim).addC(-1.0)).add(V_B1B2.div(RB2));

    // ================================================================
    // Extended Reverse Current Gain (EXMOD > 0) (Eqs 4.220-4.235)
    // ================================================================
    var XIex: S = S.con(0.0);
    var XIsub: S = S.con(0.0);

    if (P.EXMOD > 0) {
        Iex = Iex.scale(1.0 - P.Xext);
        Isub = Isub.scale(1.0 - P.Xext);

        if (P.EXMOD == 1 or P.EXMOD == 3) {
            const exp_bc3_vt = expC(S, V_BC3.div(VT), P.vexlim);

            const denom_ximex = IBXT.scale(4.0).div(IkBXT).mul(exp_bc3_vt).addC(1.0).sqrt().addC(1.0);
            const XIMex = IBXT.scale(P.Xext * 2.0).mul(exp_bc3_vt.addC(-1.0)).div(denom_ximex);

            var XImsub: S = S.con(0.0);
            if (P.EXSUB == 0) {
                const denom_xsub = ISsT.scale(4.0).div(IksT).mul(exp_bc3_vt).addC(1.0).sqrt().addC(1.0);
                XImsub = ISsT.scale((1.0 - P.Xisubi) * P.Xext * 2.0).mul(exp_bc3_vt.addC(-1.0)).div(denom_xsub);
            } else {
                const exp_sc3_vt = expC(S, V_SC3.div(VT), P.vexlim);
                const swvsch_f3: f64 = @floatFromInt(P.SWVSCH);
                const denom_xsub = ISsT.scale(4.0).div(IksT).mul(exp_bc3_vt.add(exp_sc3_vt.scale(swvsch_f3))).addC(1.0).sqrt().addC(1.0);
                XImsub = ISsT.scale((1.0 - P.Xisubi) * P.Xext * 2.0).mul(exp_bc3_vt.sub(exp_sc3_vt)).div(denom_xsub);
            }

            var Fex: S = S.con(1.0);
            if (P.EXMOD == 1) {
                // Vex = VT*(2 - log(max(Xext*(IBXT+ISsT)*RCcT/VT, 1e-30)))
                const Vex = VT.scale(2.0).sub(VT.mul(logC(S, IBXT.add(ISsT).scale(P.Xext).mul(RCcT).div(VT), 1.0e-30)));
                const VBex_arg = V_BC3.sub(Vex);
                const VBex = VBex_arg.add(VBex_arg.mul(VBex_arg).addC(0.0121).sqrt()).scale(0.5);
                Fex = VBex.div(IBXT.add(ISsT).scale(P.Xext).mul(RCcT).add(XIMex.add(XImsub).mul(RCcT)).add(VBex).maxC(1.0e-30));
            }

            XIex = Fex.mul(XIMex);
            XIsub = Fex.mul(XImsub);

            XIex = fbrcb.mul(XIex);
        }
    }

    // ================================================================
    // Parasitic Resistance Currents (linear)
    // ================================================================
    const GRE_s = S.con(1.0).div(RET.maxC(1.0e-30));
    const I_RE = V_EE1.mul(GRE_s);

    const GRBc_s = S.con(1.0).div(RBcT.maxC(1.0e-30));
    const I_RBc = V_BB1.mul(GRBc_s);

    const GSHORT: f64 = 1.0e12;
    const GCc_eff = if (P.RCc > 0.0) GCcT else S.con(GSHORT);
    const GCblx_eff = if (P.RCblx > 0.0) GCblxT else S.con(GSHORT);
    const GCbli_eff = if (P.RCbli > 0.0) GCbliT else S.con(GSHORT);

    const I_RCc_eff = V_CC3.mul(GCc_eff);
    const I_RCblx_eff = V_C3C4.mul(GCblx_eff);
    const I_RCbli_eff = V_C4C1.mul(GCbli_eff);

    // ================================================================
    // Self-Heating (Eqs 4.262-4.265)
    // ================================================================
    const VstarVT = Vstar_B2C2_over_VT.mul(VT);
    // GCcT/GCblxT/GCbliT are used directly here (as in original Pdiss)
    const Pdiss =
        IN.mul(V_B2E1.sub(VstarVT))
        .add(IC1C2.mul(VstarVT.sub(V_B2C1)))
        .sub(Iavl.mul(VstarVT))
        .add(V_EE1.mul(V_EE1).mul(GRE_s))
        .add(V_BB1.mul(V_BB1).mul(GRBc_s))
        .add(V_CC3.mul(V_CC3).mul(GCcT))
        .add(V_C3C4.mul(V_C3C4).mul(GCblxT))
        .add(V_C4C1.mul(V_C4C1).mul(GCbliT))
        .add(IB1B2.mul(V_B1B2))
        .add(IB1.add(IB2).sub(IztEB).add(IBTBT).add(ITAT).mul(V_B2E1))
        .sub(IztCB.mul(V_B2C2))
        .add(IBS1.add(IBS2).add(IBrel).mul(V_B1E1))
        .add(Iex.add(IB3).mul(V_B1C4))
        .add(XIex.mul(V_BC3))
        .add(Isub.mul(V_B1S))
        .add(Isub_int.mul(V_B2S))
        .add(XIsub.mul(V_BS))
        .add(ISf.mul(V_SC1));

    // Thermal current (Eqs 4.263-4.265)
    const I_th = if (P.SWNLSH == 0)
        VdT.scale(1.0 / @max(Rth_Tamb, 1.0e-30))
    else if (@abs(P.Ath - 1.0) < 1.0e-10)
        logC(S, VdT.scale(1.0 / Tamb).addC(1.0), 1.0e-30).scale(Tamb / @max(Rth_Tamb, 1.0e-30))
    else
        expC(S, logC(S, VdT.scale(1.0 / Tamb).addC(1.0), 1.0e-30).scale(1.0 - P.Ath), 80.0).addC(-1.0)
            .scale(Tamb / @max((1.0 - P.Ath) * Rth_Tamb, 1.0e-30));

    // ================================================================
    // Stamp currents into KCL (with NPN/PNP sign)
    // ================================================================
    var i_c: S = S.con(0.0);
    var i_b: S = S.con(0.0);
    var i_e: S = S.con(0.0);
    var i_s: S = S.con(0.0);
    var i_b1: S = S.con(0.0);
    var i_b2: S = S.con(0.0);
    var i_e1: S = S.con(0.0);
    var i_c1: S = S.con(0.0);
    var i_c2: S = S.con(0.0);
    var i_c3: S = S.con(0.0);
    var i_c4: S = S.con(0.0);
    var i_dt: S = S.con(0.0);

    // IC1C2: from C1 to C2
    i_c1 = i_c1.add(IC1C2);
    i_c2 = i_c2.sub(IC1C2);

    // IB1B2: from B1 to B2
    i_b1 = i_b1.add(IB1B2);
    i_b2 = i_b2.sub(IB1B2);

    // IN: from C2 to E1
    i_c2 = i_c2.add(IN);
    i_e1 = i_e1.sub(IN);

    // IB1: from B2 to E1
    i_b2 = i_b2.add(IB1);
    i_e1 = i_e1.sub(IB1);

    // IBS1: from B1 to E1
    i_b1 = i_b1.add(IBS1);
    i_e1 = i_e1.sub(IBS1);

    // IB2: from B2 to E1
    i_b2 = i_b2.add(IB2);
    i_e1 = i_e1.sub(IB2);

    // IBS2: from B2 to E1
    i_b2 = i_b2.add(IBS2);
    i_e1 = i_e1.sub(IBS2);

    // IBrel: from B2 to E1
    i_b2 = i_b2.add(IBrel);
    i_e1 = i_e1.sub(IBrel);

    // IBTBT: from B2 to E1
    i_b2 = i_b2.add(IBTBT);
    i_e1 = i_e1.sub(IBTBT);

    // ITAT: from B2 to E1
    i_b2 = i_b2.add(ITAT);
    i_e1 = i_e1.sub(ITAT);

    // IB3: from B1 to C4
    i_b1 = i_b1.add(IB3);
    i_c4 = i_c4.sub(IB3);

    // Iavl: from C2 to B2
    i_c2 = i_c2.add(Iavl);
    i_b2 = i_b2.sub(Iavl);

    // IztEB: from E1 to B2
    i_e1 = i_e1.add(IztEB);
    i_b2 = i_b2.sub(IztEB);

    // IztCB: from C2 to B2
    i_c2 = i_c2.add(IztCB);
    i_b2 = i_b2.sub(IztCB);

    // Iex: from B1 to C4
    i_b1 = i_b1.add(Iex);
    i_c4 = i_c4.sub(Iex);

    // XIex: from B to C3
    i_b = i_b.add(XIex);
    i_c3 = i_c3.sub(XIex);

    // Isub_int: from B2 to S
    i_b2 = i_b2.add(Isub_int);
    i_s = i_s.sub(Isub_int);

    // Isub: from B1 to S
    i_b1 = i_b1.add(Isub);
    i_s = i_s.sub(Isub);

    // XIsub: from B to S
    i_b = i_b.add(XIsub);
    i_s = i_s.sub(XIsub);

    // ISf: from S to C1
    i_s = i_s.add(ISf);
    i_c1 = i_c1.sub(ISf);

    // RE (E to E1)
    i_e = i_e.add(I_RE);
    i_e1 = i_e1.sub(I_RE);

    // RBc (B to B1)
    i_b = i_b.add(I_RBc);
    i_b1 = i_b1.sub(I_RBc);

    // RCc (C to C3)
    i_c = i_c.add(I_RCc_eff);
    i_c3 = i_c3.sub(I_RCc_eff);

    // RCblx (C3 to C4)
    i_c3 = i_c3.add(I_RCblx_eff);
    i_c4 = i_c4.sub(I_RCblx_eff);

    // RCbli (C4 to C1)
    i_c4 = i_c4.add(I_RCbli_eff);
    i_c1 = i_c1.sub(I_RCbli_eff);

    // Self-heating: dT node
    i_dt = I_th.sub(Pdiss);

    var out: [n_u]S = undefined;
    out[nc] = i_c.scale(type_f);
    out[nb] = i_b.scale(type_f);
    out[ne] = i_e.scale(type_f);
    out[ns] = i_s.scale(type_f);
    out[nb1] = i_b1.scale(type_f);
    out[nb2] = i_b2.scale(type_f);
    out[ne1] = i_e1.scale(type_f);
    out[nc1] = i_c1.scale(type_f);
    out[nc2] = i_c2.scale(type_f);
    out[nc3] = i_c3.scale(type_f);
    out[nc4] = i_c4.scale(type_f);
    out[ndt] = i_dt;
    return out;
}

// smooth min of two S values (min_logexp form used only in the SWAVL=3 limiter)
fn min_logexp_S_S(comptime S: type, x: S, x0: S, a: f64) S {
    const d = x.sub(x0).scale(1.0 / a);
    const d_safe = if (x.val() < x0.val()) d else d.neg();
    const base = if (x.val() < x0.val()) x else x0;
    const t = expC(S, d_safe, 80.0).addC(1.0).log().scale(a);
    return base.sub(t);
}

// ============================================================================
// Charge Function (q)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = pc;
    const mult: f64 = @as(f64, instance.mult);
    const type_f: f64 = @floatFromInt(model.type_);
    const dta: f64 = @as(f64, instance.dta);
    const tref: f64 = @as(f64, model.tref);

    const nb = @intFromEnum(U.b);
    const ne = @intFromEnum(U.e);
    const ns = @intFromEnum(U.s);
    const nc = @intFromEnum(U.c);
    const nb1 = @intFromEnum(U.b1);
    const nb2 = @intFromEnum(U.b2);
    const ne1 = @intFromEnum(U.e1);
    const nc1 = @intFromEnum(U.c1);
    const nc2 = @intFromEnum(U.c2);
    const nc3 = @intFromEnum(U.c3);
    const nc4 = @intFromEnum(U.c4);
    const ndt = @intFromEnum(U.dt);

    // Model parameter casts (x-free)
    const VdE: f64 = @as(f64, model.vde);
    const pE: f64 = @as(f64, model.pe);
    const XCjE: f64 = @as(f64, model.xcje);
    const CjE: f64 = @as(f64, model.cje) * mult;
    const CBEO: f64 = @as(f64, model.cbeo) * mult;
    const VdC: f64 = @as(f64, model.vdc);
    const pC: f64 = @as(f64, model.pc);
    const XCjC: f64 = @as(f64, model.xcjc);
    const CjC: f64 = @as(f64, model.cjc) * mult;
    const CBCO: f64 = @as(f64, model.cbco) * mult;
    const VdCctc: f64 = @as(f64, model.vdcctc);
    const Xp: f64 = @as(f64, model.xp);
    const mC: f64 = @as(f64, model.mc);
    const VdS: f64 = @as(f64, model.vds);
    const pS: f64 = @as(f64, model.ps);
    const CjS: f64 = @as(f64, model.cjs) * mult;
    const VgB: f64 = @as(f64, model.vgb);
    const VgC: f64 = @as(f64, model.vgc);
    const VgS: f64 = @as(f64, model.vgs);
    const VdCex: f64 = @as(f64, model.vdcex);
    const Xext: f64 = @as(f64, model.xext);

    const AQB0: f64 = @as(f64, model.aqbo);
    const AB: f64 = @as(f64, model.ab);
    const Aepi: f64 = @as(f64, model.aepi);
    const ACX: f64 = @as(f64, model.acx);
    const Aepiex: f64 = @as(f64, model.aepiex);
    const dAIs: f64 = @as(f64, model.dais);
    const VgCX: f64 = @as(f64, model.vgcx);

    const Is: f64 = @as(f64, model.is) * mult;
    const NFF: f64 = @as(f64, model.nff);
    const Ik: f64 = @as(f64, model.ik) * mult;
    const Ver: f64 = @as(f64, model.ver);
    const Vef: f64 = @as(f64, model.vef);

    const RCv: f64 = @as(f64, model.rcv) / mult;
    const SCRCv: f64 = @as(f64, model.scrcv) / mult;
    const Ihc: f64 = @as(f64, model.ihc) * mult;
    const axi: f64 = @as(f64, model.axi);

    const mtau: f64 = @as(f64, model.mtau);
    const tauE: f64 = @as(f64, model.taue);
    const tauB: f64 = @as(f64, model.taub);
    const tepi: f64 = @as(f64, model.tepi);
    const tauR: f64 = @as(f64, model.taur);
    const tauex: f64 = @as(f64, model.tauex);
    const Nex: f64 = @as(f64, model.nex);
    const SWQEX: i32 = model.swqex;
    const EXMOD: i32 = model.exmod;

    const XQB: f64 = @as(f64, model.xqb);
    const KE: f64 = @as(f64, model.ke);
    const EXPHI: i32 = model.exphi;
    const dvgtE: f64 = @as(f64, model.dvgte);

    const IBX: f64 = @as(f64, model.ibx) * mult;
    const IkBX: f64 = @as(f64, model.ikbx) * mult;
    const Cth: f64 = @as(f64, model.cth) * mult;
    const tNFF: f64 = @as(f64, model.tnff);
    const DTmax: f64 = @as(f64, model.dtmax);

    const ISs: f64 = @as(f64, model.iss) * mult;
    const Iks: f64 = @as(f64, model.iks) * mult;
    const RCc: f64 = @as(f64, model.rcc) / mult;
    const Xisubi: f64 = @as(f64, model.xisubi);
    const SWVSCH: i32 = model.swvsch;
    const EXSUB: i32 = model.exsub;
    const AS: f64 = @as(f64, model.as_);
    const AC: f64 = @as(f64, model.ac);

    const SWVCHC: i32 = model.swvchc;

    const p0starlim: f64 = @as(f64, model.p0starlim);
    const vexlim: f64 = @as(f64, model.vexlim);

    // Branch voltages
    const VdT = x[ndt].minC(DTmax).maxC(-DTmax);

    const V_B2E1 = x[nb2].sub(x[ne1]).scale(type_f);
    const V_B2C2 = x[nb2].sub(x[nc2]).scale(type_f);
    const V_B2C1 = x[nb2].sub(x[nc1]).scale(type_f);
    const V_B1E1 = x[nb1].sub(x[ne1]).scale(type_f);
    const V_B1B2 = x[nb1].sub(x[nb2]).scale(type_f);
    const V_B1C4 = x[nb1].sub(x[nc4]).scale(type_f);
    const V_C1C2 = x[nc1].sub(x[nc2]).scale(type_f);
    const V_SC1 = x[ns].sub(x[nc1]).scale(type_f);
    const V_BC3 = x[nb].sub(x[nc3]).scale(type_f);
    const V_SC3 = x[ns].sub(x[nc3]).scale(type_f);
    const V_BE = x[nb].sub(x[ne]).scale(type_f);
    const V_BC = x[nb].sub(x[nc]).scale(type_f);

    // Temperature
    const TEMP: f64 = 27.0;
    const TK = VdT.addC(TEMP + dta + 273.15);
    const TRK = tref + 273.15;
    const tN = TK.scale(1.0 / TRK);
    const VT = TK.scale(kB_q);
    const VTR = kB_q * TRK;
    const inv_VdeltaT = S.con(1.0).div(VT).addC(-1.0 / VTR);
    const ln_tN = logC(S, tN, 1.0e-30);

    // NFF/NFR temperature
    const dT_temp = TK.addC(-TRK);
    const NFF_T = if (tNFF != 0.0) blk: {
        const nff_tmp = dT_temp.scale(tNFF).addC(1.0).scale(NFF);
        const nff_ml = max_logexp(S, nff_tmp, 1.0, 0.001);
        break :blk nff_ml.addC(-0.001 * 0.693147180559945);
    } else S.con(NFF);

    // Diffusion voltages (temperature)
    const UdET = VT.mul(ln_tN).scale(-3.0).add(tN.scale(VdE)).add(tN.neg().addC(1.0).scale(VgB));
    const VdET = diffVolt(S, VT, UdET);

    const UdCT = VT.mul(ln_tN).scale(-3.0).add(tN.scale(VdC)).add(tN.neg().addC(1.0).scale(VgC));
    const VdCT = diffVolt(S, VT, UdCT);

    const UdCctcT = VT.mul(ln_tN).scale(-3.0).add(tN.scale(VdCctc)).add(tN.neg().addC(1.0).scale(VgC));
    const VdCctcT = diffVolt(S, VT, UdCctcT);

    const UdST = VT.mul(ln_tN).scale(-3.0).add(tN.scale(VdS)).add(tN.neg().addC(1.0).scale(VgS));
    const VdST = diffVolt(S, VT, UdST);

    const UdCexT = VT.mul(ln_tN).scale(-3.0).add(tN.scale(VdCex)).add(tN.neg().addC(1.0).scale(VgC));
    const VdCexT = diffVolt(S, VT, UdCexT);

    // Capacitance temperature scaling
    const vde_vdet = VdET.maxC(1.0e-30);
    const CjET = logC(S, S.con(VdE).div(vde_vdet), 1.0e-30).scale(pE).exp().scale(CjE);

    const vds_vdst = VdST.maxC(1.0e-30);
    const CjST = logC(S, S.con(VdS).div(vds_vdst), 1.0e-30).scale(pS).exp().scale(CjS);

    const vdc_vdct_ratio = S.con(VdC).div(VdCT.maxC(1.0e-30));
    const vdc_vdct_pc = logC(S, vdc_vdct_ratio, 1.0e-30).scale(pC).exp();
    const CjCT = vdc_vdct_pc.scale(1.0 - Xp).addC(Xp).scale(CjC);
    const xpt_den = vdc_vdct_pc.scale(1.0 - Xp).addC(Xp).maxC(1.0e-30);
    const XpT = S.con(Xp).div(xpt_den);

    // Current temperature scaling
    const IsT = S.con(Is)
        .mul(S.con(4.0 - AB - AQB0 + dAIs).div(NFF_T).mul(ln_tN).exp())
        .mul(expC(S, S.con(-VgB).div(NFF_T).mul(inv_VdeltaT), 80.0));
    const IkT = ln_tN.scale(1.0 - AB).exp().scale(Ik);
    const IBXT = ln_tN.scale(4.0 - ACX + dAIs).exp().mul(expC(S, inv_VdeltaT.scale(-VgCX), 80.0)).scale(IBX);
    const IkBXT = ln_tN.scale(1.0 - ACX).exp().scale(IkBX);
    const ISsT = ln_tN.scale(4.0 - AS).exp().mul(expC(S, inv_VdeltaT.scale(-VgS), 80.0)).scale(ISs);
    const IksT = ln_tN.scale(1.0 - AS).exp().scale(Iks);

    // Resistance temperature
    const RCvT = ln_tN.scale(Aepi).exp().scale(RCv);
    const RCcT = ln_tN.scale(AC).exp().scale(RCc);

    // Transit time temperature (Eqs 4.58-4.62)
    const tauET = ln_tN.scale(AB - 2.0).exp().mul(expC(S, inv_VdeltaT.scale(-dvgtE), 80.0)).scale(tauE);
    const tauBT = ln_tN.scale(AQB0 + AB - 1.0).exp().scale(tauB);
    const tepiT = ln_tN.scale(Aepi - 1.0).exp().scale(tepi);
    const tauRT = tauBT.add(tepiT).scale(tauR / @max(tauB + tepi, 1.0e-30));
    const tauexT = ln_tN.scale(Aepiex - 1.0).exp().scale(tauex);

    // Early voltages (temperature)
    const VefT = ln_tN.scale(AQB0).exp().scale(Vef).div(xpt_den);
    const VerT = ln_tN.scale(AQB0).exp().scale(Ver).mul(logC(S, S.con(VdE).div(vde_vdet), 1.0e-30).scale(pE).exp());

    // ================================================================
    // Emitter depletion charge VtE
    // ================================================================
    const VFE = VdET.scale(1.0 - contract.fmath.exp(-1.0 / pE * contract.fmath.log(alpha_jE)));
    const vjE_arg = V_B2E1.sub(VFE).div(VdET.scale(0.1)).minC(80.0);
    const VjE = V_B2E1.sub(VdET.scale(0.1).mul(vjE_arg.exp().addC(1.0).log()));
    const E0EB = logC(S, VjE.div(VdET).neg().addC(1.0), 1.0e-30).scale(1.0 - pE).exp();
    const VtE = VdET.scale(1.0 / (1.0 - pE)).mul(E0EB.neg().addC(1.0)).add(V_B2E1.sub(VjE).scale(alpha_jE));

    // ================================================================
    // Emitter depletion charges (Eqs 4.176-4.178)
    // ================================================================
    const QtE = VtE.scale((1.0 - XCjE)).mul(CjET);

    const vjEs_arg = V_B1E1.sub(VFE).div(VdET.scale(0.1)).minC(80.0);
    const VjES = V_B1E1.sub(VdET.scale(0.1).mul(vjEs_arg.exp().addC(1.0).log()));
    const QtES = CjET.scale(XCjE).mul(
        VdET.scale(1.0 / (1.0 - pE)).mul(logC(S, VjES.div(VdET).neg().addC(1.0), 1.0e-30).scale(1.0 - pE).exp().neg().addC(1.0))
            .add(V_B1E1.sub(VjES).scale(alpha_jE)),
    );

    // ================================================================
    // Epilayer model
    // ================================================================
    const exp_b2c2_vdc = expC(S, V_B2C2.sub(VdCT).div(VT), 80.0);
    const exp_b2c1_vdc = expC(S, V_B2C1.sub(VdCT).div(VT), 80.0);
    const K0 = exp_b2c2_vdc.scale(4.0).addC(1.0).sqrt();
    const KW = exp_b2c1_vdc.scale(4.0).addC(1.0).sqrt();
    const pW = exp_b2c1_vdc.scale(2.0).div(KW.addC(1.0));
    const Ec = VT.mul(K0.sub(KW).sub(logC(S, K0.addC(1.0).div(KW.addC(1.0).maxC(1.0e-30)), 1.0e-30)));
    const IC1C2 = Ec.add(V_C1C2).div(RCvT);
    const ic1c2_pos = IC1C2.val() > 0.0;

    const vdct01 = VdCT.scale(0.1);
    const Vqs_th_fwd = VdCT.add(VT.scale(2.0).mul(logC(S, IC1C2.mul(RCvT).div(VT.scale(2.0)).addC(1.0), 1.0e-30))).sub(V_B2C1);
    const Vqs_raw = Vqs_th_fwd.add(Vqs_th_fwd.mul(Vqs_th_fwd).add(vdct01.mul(vdct01).scale(4.0)).sqrt()).scale(0.5);
    const Vqs = if (ic1c2_pos) Vqs_raw else vdct01;
    const Iqs = Vqs.scale(1.0 / SCRCv).mul(Vqs.addC(Ihc * SCRCv)).div(Vqs.add(RCvT.scale(Ihc)).maxC(1.0e-30));

    const alpha_arg = IC1C2.div(Iqs.maxC(1.0e-30)).addC(-1.0).scale(1.0 / axi).minC(80.0);
    const alpha_num = alpha_arg.exp().addC(1.0).log().scale(axi).addC(1.0);
    const alpha_den = 1.0 + axi * contract.fmath.log(1.0 + contract.fmath.exp(@min(-1.0 / axi, 80.0)));
    const alpha = if (ic1c2_pos) alpha_num.scale(1.0 / @max(alpha_den, 1.0e-30)) else S.con(1.0);

    const v_qs = Vqs.scale(1.0 / @max(Ihc * SCRCv, 1.0e-30));
    const yi = alpha.mul(v_qs).mul(v_qs.addC(1.0)).scale(4.0).addC(1.0).sqrt().addC(1.0)
        .div(alpha.mul(v_qs.addC(1.0)).scale(2.0));
    const xi_Wepi_fwd = yi.div(pW.mul(yi).addC(1.0)).neg().addC(1.0);
    const g_fwd = IC1C2.mul(RCvT).div(VT.scale(2.0)).mul(xi_Wepi_fwd);
    const gm1_half = g_fwd.addC(-1.0).scale(0.5);
    const disc = gm1_half.mul(gm1_half).add(g_fwd.scale(2.0)).add(pW.mul(pW.add(g_fwd).addC(1.0)));
    const sqrt_disc = disc.maxC(0.0).sqrt();
    const p0star_fwd_raw = if (g_fwd.val() > 1.0)
        gm1_half.add(sqrt_disc)
    else
        g_fwd.scale(2.0).add(pW.mul(pW.add(g_fwd).addC(1.0))).div(g_fwd.neg().addC(1.0).scale(0.5).add(sqrt_disc).maxC(1.0e-30));
    const p0star_fwd = p0star_fwd_raw.maxC(p0starlim);
    const exp_Vstar_fwd = p0star_fwd.mul(p0star_fwd.addC(1.0)).mul(expC(S, VdCT.div(VT), 80.0));
    const p0star_rev = K0.addC(-1.0).scale(0.5);

    const vc1c2_abs = V_C1C2.abs();
    const Ec_abs = Ec.abs();
    const small_signal_rev = (vc1c2_abs.val() < 1.0e-5 * VT.val()) or (Ec_abs.val() < contract.fmath.exp(-40.0) * VT.val() * (K0.val() + KW.val()));
    const pav = p0star_rev.add(pW).scale(0.5);
    const xi_Wepi_rev = if (small_signal_rev) pav.div(pav.addC(1.0)) else Ec.div(Ec.add(V_B2C2).sub(V_B2C1).maxC(1.0e-30));

    const p0star = if (ic1c2_pos) p0star_fwd else p0star_rev;
    const xi_Wepi = if (ic1c2_pos) xi_Wepi_fwd else xi_Wepi_rev;
    const exp_Vstar_B2C2 = if (ic1c2_pos) exp_Vstar_fwd else exp_b2c2_vdc.mul(expC(S, VdCT.div(VT), 80.0));

    // ================================================================
    // Collector depletion charge VtC (Eqs 4.179-4.192)
    // ================================================================
    const bjC = XpT.neg().addC(alpha_jC).div(XpT.neg().addC(1.0).maxC(1.0e-30));
    const VFC = VdCctcT.mul(logC(S, bjC, 1.0e-30).scale(-1.0 / pC).exp().neg().addC(1.0));

    const B1_fwd = IC1C2.addC(-Ihc).scale(0.5 * SCRCv);
    const B2_fwd = RCvT.scale(SCRCv * Ihc).mul(IC1C2);
    const Vxi0 = if (ic1c2_pos) B1_fwd.add(B1_fwd.mul(B1_fwd).add(B2_fwd).maxC(0.0).sqrt()) else V_C1C2;
    const Vjunc = V_B2C1.add(Vxi0);

    const Vch_fwd = VdCT.mul(IC1C2.div(IC1C2.add(Iqs).maxC(1.0e-30)).scale(2.0).addC(0.1));
    const Vch = if (ic1c2_pos) (if (SWVCHC == 1) Vch_fwd else vdct01) else vdct01;

    const vjc_arg = Vjunc.sub(VFC).div(Vch).minC(80.0);
    const VjC = Vjunc.sub(Vch.mul(vjc_arg.exp().addC(1.0).log()));

    const Icap = if (ic1c2_pos) IC1C2.scale(Ihc).div(IC1C2.addC(Ihc).maxC(1.0e-30)) else IC1C2;
    const fI = logC(S, Icap.scale(-1.0 / Ihc).addC(1.0), 1.0e-30).scale(mC).exp();

    const vcv_inner = fI.mul(logC(S, VjC.div(VdCctcT).neg().addC(1.0), 1.0e-30).scale(1.0 - pC).exp()).neg().addC(1.0)
        .add(fI.mul(bjC).mul(Vjunc.sub(VjC)));
    const VCV = VdCctcT.scale(1.0 / (1.0 - pC)).mul(vcv_inner);
    const VtC = XpT.neg().addC(1.0).mul(VCV).add(XpT.mul(V_B2C1));

    // ================================================================
    // Intrinsic collector depletion charge (Eq 4.193)
    // ================================================================
    const QtC = VtC.scale(XCjC).mul(CjCT);

    // ================================================================
    // Extrinsic collector depletion charges (Eqs 4.194-4.199)
    // ================================================================
    const vjcex_arg = V_B1C4.sub(VFC).div(VdCT.scale(0.1)).minC(80.0);
    const VjCex = V_B1C4.sub(VdCT.scale(0.1).mul(vjcex_arg.exp().addC(1.0).log()));
    // VtexV = VdCT/(1-pC)*(1 - exp((1-pC)*log(max(1-VjCex/VdCT,1e-30))) + bjC*(V_B1C4 - VjCex))
    const VtexV = VdCT.scale(1.0 / (1.0 - pC)).mul(
        logC(S, VjCex.div(VdCT).neg().addC(1.0), 1.0e-30).scale(1.0 - pC).exp().neg().addC(1.0)
            .add(bjC.mul(V_B1C4.sub(VjCex))),
    );
    const Qtex = CjCT.mul(XpT.neg().addC(1.0).mul(VtexV).add(XpT.mul(V_B1C4))).scale((1.0 - XCjC) * (1.0 - Xext));

    const xvjcex_arg = V_BC3.sub(VFC).div(VdCT.scale(0.1)).minC(80.0);
    const XVjCex = V_BC3.sub(VdCT.scale(0.1).mul(xvjcex_arg.exp().addC(1.0).log()));
    const XVtexV = VdCT.scale(1.0 / (1.0 - pC)).mul(
        logC(S, XVjCex.div(VdCT).neg().addC(1.0), 1.0e-30).scale(1.0 - pC).exp().neg().addC(1.0)
            .add(bjC.mul(V_BC3.sub(XVjCex))),
    );
    const XQtex = CjCT.mul(XpT.neg().addC(1.0).mul(XVtexV).add(XpT.mul(V_BC3))).scale((1.0 - XCjC) * Xext);

    // ================================================================
    // Substrate depletion charge (Eqs 4.200-4.202)
    // ================================================================
    const VFS = VdST.scale(1.0 - contract.fmath.exp(-1.0 / pS * contract.fmath.log(alpha_jS)));
    const vjs_arg = V_SC1.sub(VFS).div(VdST.scale(0.1)).minC(80.0);
    const VjS = V_SC1.sub(VdST.scale(0.1).mul(vjs_arg.exp().addC(1.0).log()));
    const QtS = CjST.mul(
        VdST.scale(1.0 / (1.0 - pS)).mul(logC(S, VjS.div(VdST).neg().addC(1.0), 1.0e-30).scale(1.0 - pS).exp().neg().addC(1.0))
            .add(V_SC1.sub(VjS).scale(alpha_jS)),
    );

    // ================================================================
    // Base charge for stored charges
    // ================================================================
    const q0Q = VtE.div(VerT).addC(1.0).add(VtC.div(VefT));
    const q1Q = q0Q.add(q0Q.mul(q0Q).addC(0.01).sqrt()).scale(0.5);

    const f1 = IsT.scale(4.0).div(IkT).mul(expC(S, V_B2E1.div(NFF_T.mul(VT)), vexlim));
    const n0 = f1.div(f1.addC(1.0).sqrt().addC(1.0));
    const f2 = IsT.scale(4.0).div(IkT).mul(exp_Vstar_B2C2);
    const nB = f2.div(f2.addC(1.0).sqrt().addC(1.0));

    // ================================================================
    // Stored emitter charge (Eqs 4.203-4.204)
    // ================================================================
    // QE0 = tauET*IkT*exp(1/mtau*log(max(IsT/IkT,1e-30)))
    const QE0 = tauET.mul(IkT).mul(logC(S, IsT.div(IkT), 1.0e-30).scale(1.0 / mtau).exp());
    const QE = QE0.mul(expC(S, V_B2E1.div(VT.scale(mtau)), vexlim));

    // ================================================================
    // Stored base charges (Eqs 4.205-4.211)
    // ================================================================
    const QB0 = tauBT.mul(IkT);
    const QBE = QB0.scale(0.5).mul(n0).mul(q1Q);
    const QBC = QB0.scale(0.5).mul(nB).mul(q1Q);

    // ================================================================
    // Stored epilayer charge (Eqs 4.212-4.213)
    // ================================================================
    const Qepi0 = VT.scale(4.0).mul(tepiT).div(RCvT);
    const Qepi = Qepi0.scale(0.5).mul(xi_Wepi).mul(p0star.add(pW).addC(2.0));

    // ================================================================
    // Stored extrinsic charges (Eqs 4.214-4.219)
    // ================================================================
    const exp_b1c4_vt = expC(S, V_B1C4.div(VT), vexlim);
    const g1 = IsT.scale(4.0).div(IkT).mul(exp_b1c4_vt.addC(-1.0));
    const nBex = IsT.scale(4.0).mul(exp_b1c4_vt.addC(-1.0)).div(IkT.mul(g1.addC(1.0).sqrt().addC(1.0)).maxC(1.0e-30));
    const g2 = expC(S, V_B1C4.sub(VdCT).div(VT), vexlim).scale(4.0);
    const pWex = g2.div(g2.addC(1.0).sqrt().addC(1.0));

    var Qex: S = S.con(0.0);
    if (SWQEX == 0) {
        Qex = QB0.scale(0.5).mul(nBex).add(Qepi0.scale(0.5).mul(pWex)).scale(1.0).mul(tauRT).div(tauBT.add(tepiT).maxC(1.0e-30));
    } else {
        Qex = IBXT.scale(2.0).mul(tauexT).mul(expC(S, V_B1C4.div(VT), vexlim))
            .div(expC(S, V_B1C4.sub(VdCexT).div(VT.scale(Nex)), vexlim).scale(4.0).addC(1.0).sqrt().addC(1.0));
    }

    // ================================================================
    // Extended reverse current gain charges (EXMOD > 0) (Eqs 4.231-4.235)
    // ================================================================
    var XQex: S = S.con(0.0);
    if (EXMOD > 0) {
        if (EXMOD == 1 or EXMOD == 3) {
            Qex = Qex.scale(1.0 - Xext);
        }

        if (EXMOD == 1 or EXMOD == 3) {
            if (SWQEX == 0) {
                const exp_bc3_vt = expC(S, V_BC3.div(VT), vexlim);
                const Xg1 = IsT.scale(4.0).div(IkT).mul(exp_bc3_vt);
                const XnBex = IsT.scale(4.0).mul(exp_bc3_vt.addC(-1.0)).div(IkT.mul(Xg1.addC(1.0).sqrt().addC(1.0)).maxC(1.0e-30));
                const Xg2 = expC(S, V_BC3.sub(VdCT).div(VT), vexlim).scale(4.0);
                const XpWex = Xg2.div(Xg2.addC(1.0).sqrt().addC(1.0));

                const Fex: S = if (EXMOD == 1) blk_fex: {
                    const denom_ximex = IBXT.scale(4.0).div(IkBXT).mul(exp_bc3_vt).addC(1.0).sqrt().addC(1.0);
                    const XIMex = IBXT.scale(Xext * 2.0).mul(exp_bc3_vt.addC(-1.0)).div(denom_ximex);

                    const XImsub = if (EXSUB == 0) blk_sub: {
                        const denom_xsub = ISsT.scale(4.0).div(IksT).mul(exp_bc3_vt).addC(1.0).sqrt().addC(1.0);
                        break :blk_sub ISsT.scale((1.0 - Xisubi) * Xext * 2.0).mul(exp_bc3_vt.addC(-1.0)).div(denom_xsub);
                    } else blk_sub: {
                        const exp_sc3_vt = expC(S, V_SC3.div(VT), vexlim);
                        const swvsch_f3: f64 = @floatFromInt(SWVSCH);
                        const denom_xsub = ISsT.scale(4.0).div(IksT).mul(exp_bc3_vt.add(exp_sc3_vt.scale(swvsch_f3))).addC(1.0).sqrt().addC(1.0);
                        break :blk_sub ISsT.scale((1.0 - Xisubi) * Xext * 2.0).mul(exp_bc3_vt.sub(exp_sc3_vt)).div(denom_xsub);
                    };

                    const Vex = VT.scale(2.0).sub(VT.mul(logC(S, IBXT.add(ISsT).scale(Xext).mul(RCcT).div(VT), 1.0e-30)));
                    const VBex_arg = V_BC3.sub(Vex);
                    const VBex = VBex_arg.add(VBex_arg.mul(VBex_arg).addC(0.0121).sqrt()).scale(0.5);

                    break :blk_fex VBex.div(IBXT.add(ISsT).scale(Xext).mul(RCcT).add(XIMex.add(XImsub).mul(RCcT)).add(VBex).maxC(1.0e-30));
                } else S.con(1.0);

                XQex = Fex.scale(Xext).mul(tauRT).div(tauBT.add(tepiT).maxC(1.0e-30))
                    .mul(QB0.scale(0.5).mul(XnBex).add(Qepi0.scale(0.5).mul(XpWex)));
            } else {
                const exp_bc3_vt2 = expC(S, V_BC3.div(VT), vexlim);
                XQex = IBXT.scale(Xext * 2.0).mul(tauexT).mul(exp_bc3_vt2)
                    .div(expC(S, V_BC3.sub(VdCexT).div(VT), vexlim).scale(4.0).addC(1.0).sqrt().addC(1.0));
            }
        }
    }

    // ================================================================
    // Distributed HF effects (EXPHI=1) (Eqs 4.236-4.240)
    // ================================================================
    var QBE_final = QBE;
    var QBC_final = QBC;
    var QE_final = QE;

    if (EXPHI == 1) {
        QBC_final = QBE.add(QE.scale(KE)).scale(XQB).add(QBC);
        QBE_final = QBE.add(QE.scale(KE)).scale(1.0 - XQB);
        QE_final = QE.scale(1.0 - KE);
    }

    // Total B2-E1 charge (Eq 4.240)
    const QB2E1 = QtE.add(QBE_final).add(QE_final);

    // ================================================================
    // Overlap capacitances (constant charge = C * V)
    // ================================================================
    const QBEO = V_BE.scale(CBEO);
    const QBCO = V_BC.scale(CBCO);

    // ================================================================
    // Thermal capacitance charge
    // ================================================================
    const Qth = VdT.scale(Cth);

    // ================================================================
    // QB1B2 charge for distributed HF (Eq 4.236)
    // ================================================================
    const QB1B2 = if (EXPHI == 1) blk: {
        const dQtE_dV = E0EB.scale((1.0 - XCjE)).mul(CjET);
        const dQE_dV = QE.div(VT.scale(mtau).maxC(1.0e-30));
        // dn0_dV_approx = n0 / max(NFF_T*VT,1e-30) / max(1 + sqrt(1+f1), 1e-30)
        const dn0_dV_approx = n0.div(NFF_T.mul(VT).maxC(1.0e-30)).div(f1.addC(1.0).sqrt().addC(1.0).maxC(1.0e-30));
        break :blk V_B1B2.scale(0.2).mul(dQtE_dV.add(QB0.scale(0.5).mul(q1Q).mul(dn0_dV_approx)).add(dQE_dV));
    } else S.con(0.0);

    // ================================================================
    // Stamp charges into outputs
    // ================================================================
    var q_c: S = S.con(0.0);
    var q_b: S = S.con(0.0);
    var q_e: S = S.con(0.0);
    var q_s: S = S.con(0.0);
    var q_b1: S = S.con(0.0);
    var q_b2: S = S.con(0.0);
    var q_e1: S = S.con(0.0);
    var q_c1: S = S.con(0.0);
    var q_c2: S = S.con(0.0);
    var q_c3: S = S.con(0.0);
    var q_c4: S = S.con(0.0);
    var q_dt: S = S.con(0.0);

    // QtE (B2-E1)
    q_b2 = q_b2.add(QB2E1);
    q_e1 = q_e1.sub(QB2E1);

    // QtES (B1-E1)
    q_b1 = q_b1.add(QtES);
    q_e1 = q_e1.sub(QtES);

    // QtC (B2-C2): intrinsic BC depletion + diffusion
    const q_b2c2 = QtC.add(QBC_final).add(Qepi);
    q_b2 = q_b2.add(q_b2c2);
    q_c2 = q_c2.sub(q_b2c2);

    // Qtex (B1-C4)
    const q_b1c4 = Qtex.add(Qex);
    q_b1 = q_b1.add(q_b1c4);
    q_c4 = q_c4.sub(q_b1c4);

    // XQtex (B-C3)
    const q_bc3 = XQtex.add(XQex);
    q_b = q_b.add(q_bc3);
    q_c3 = q_c3.sub(q_bc3);

    // QtS (S-C1)
    q_s = q_s.add(QtS);
    q_c1 = q_c1.sub(QtS);

    // QB1B2 (B1-B2)
    q_b1 = q_b1.add(QB1B2);
    q_b2 = q_b2.sub(QB1B2);

    // CBEO (B-E)
    q_b = q_b.add(QBEO);
    q_e = q_e.sub(QBEO);

    // CBCO (B-C)
    q_b = q_b.add(QBCO);
    q_c = q_c.sub(QBCO);

    // Thermal capacitance (dT node)
    q_dt = q_dt.add(Qth);

    var out: [n_u]S = undefined;
    out[nc] = q_c.scale(type_f);
    out[nb] = q_b.scale(type_f);
    out[ne] = q_e.scale(type_f);
    out[ns] = q_s.scale(type_f);
    out[nb1] = q_b1.scale(type_f);
    out[nb2] = q_b2.scale(type_f);
    out[ne1] = q_e1.scale(type_f);
    out[nc1] = q_c1.scale(type_f);
    out[nc2] = q_c2.scale(type_f);
    out[nc3] = q_c3.scale(type_f);
    out[nc4] = q_c4.scale(type_f);
    out[ndt] = q_dt;
    return out;
}

// ============================================================================
// Voltage Limiting (limit)
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var x = x_new;
    const type_f: f64 = @floatFromInt(model.type_);
    const kB_q_l: f64 = 8.6171e-5;
    const TEMP: f64 = 27.0;
    const VT = kB_q_l * (TEMP + 273.15);

    // PN junction limiting (DEVpnjlim) for B2-E1
    {
        const nb2 = @intFromEnum(U.b2);
        const ne1 = @intFromEnum(U.e1);
        const Is_d: f64 = @as(f64, model.is);
        const v_new = (x_new[nb2] - x_new[ne1]) * type_f;
        const v_old = (x_old[nb2] - x_old[ne1]) * type_f;
        const v_lim = pnjlim(v_new, v_old, VT, Is_d);
        const delta = (v_lim - v_new) * type_f;
        x[nb2] += delta;
    }

    // PN junction limiting for B1-E1
    {
        const nb1 = @intFromEnum(U.b1);
        const ne1 = @intFromEnum(U.e1);
        const Is_d: f64 = @as(f64, model.is);
        const v_new = (x_new[nb1] - x_new[ne1]) * type_f;
        const v_old = (x_old[nb1] - x_old[ne1]) * type_f;
        const v_lim = pnjlim(v_new, v_old, VT, Is_d);
        const delta = (v_lim - v_new) * type_f;
        x[nb1] += delta;
    }

    // PN junction limiting for B2-C2
    {
        const nb2 = @intFromEnum(U.b2);
        const nc2 = @intFromEnum(U.c2);
        const Is_d: f64 = @as(f64, model.is);
        const v_new = (x_new[nb2] - x_new[nc2]) * type_f;
        const v_old = (x_old[nb2] - x_old[nc2]) * type_f;
        const v_lim = pnjlim(v_new, v_old, VT, Is_d);
        const delta = (v_lim - v_new) * type_f;
        x[nb2] += delta * 0.5;
        x[nc2] -= delta * 0.5;
    }

    // PN junction limiting for B1-C4
    {
        const nb1 = @intFromEnum(U.b1);
        const nc4 = @intFromEnum(U.c4);
        const Is_d: f64 = @as(f64, model.is);
        const v_new = (x_new[nb1] - x_new[nc4]) * type_f;
        const v_old = (x_old[nb1] - x_old[nc4]) * type_f;
        const v_lim = pnjlim(v_new, v_old, VT, Is_d);
        const delta = (v_lim - v_new) * type_f;
        x[nb1] += delta * 0.5;
        x[nc4] -= delta * 0.5;
    }

    // Substrate junction limiting S-C1
    {
        const ns_ = @intFromEnum(U.s);
        const nc1 = @intFromEnum(U.c1);
        const Is_d: f64 = @as(f64, model.iss);
        const v_new = (x_new[ns_] - x_new[nc1]) * type_f;
        const v_old = (x_old[ns_] - x_old[nc1]) * type_f;
        const v_lim = pnjlim(v_new, v_old, VT, Is_d);
        const delta = (v_lim - v_new) * type_f;
        x[ns_] += delta * 0.5;
        x[nc1] -= delta * 0.5;
    }

    // Thermal node limiting: clamp dT
    {
        const ndt = @intFromEnum(U.dt);
        const dtmax: f64 = @as(f64, model.dtmax);
        x[ndt] = @min(@max(x[ndt], -dtmax), dtmax);
    }

    return x;
}

// DEVpnjlim: PN junction voltage limiting
fn pnjlim(v_new: f64, v_old: f64, vt: f64, is_val: f64) f64 {
    const v_crit = vt * contract.fmath.log(vt / (1.4142135623731 * @max(is_val, 1.0e-300)));

    if (v_new > v_crit and @abs(v_new - v_old) > 2.0 * vt) {
        if (v_old > 0.0) {
            const arg = 1.0 + (v_new - v_old) / vt;
            return if (arg > 0.0)
                v_old + vt * contract.fmath.log(arg)
            else
                v_crit;
        } else {
            return vt * contract.fmath.log(v_new / vt);
        }
    }
    return v_new;
}

// ============================================================================
// Parameter Stepping (attempt) — convergence aid
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale saturation currents by lambda for source stepping
    // At lambda=0: Is minimal (easy convergence), lambda=1: full model
    const gmin_factor: f32 = @floatCast(1.0e-12 * (1.0 - lambda));
    m.is = @floatCast(@as(f64, model.is) * lambda + gmin_factor);
    m.ibi = @floatCast(@as(f64, model.ibi) * lambda + gmin_factor);
    m.ibis = @floatCast(@as(f64, model.ibis) * lambda);
    m.ibf = @floatCast(@as(f64, model.ibf) * lambda);
    m.ibfs = @floatCast(@as(f64, model.ibfs) * lambda);
    m.ibx = @floatCast(@as(f64, model.ibx) * lambda + gmin_factor);
    m.ibr = @floatCast(@as(f64, model.ibr) * lambda);
    m.iss = @floatCast(@as(f64, model.iss) * lambda);
    m.icss = @floatCast(@as(f64, model.icss) * lambda);
    m.izeb = @floatCast(@as(f64, model.izeb) * lambda);
    m.izcb = @floatCast(@as(f64, model.izcb) * lambda);
    m.istat = @floatCast(@as(f64, model.istat) * lambda);
    m.kbtbt = @floatCast(@as(f64, model.kbtbt) * lambda);
    m.isibrel = @floatCast(@as(f64, model.isibrel) * lambda);
    m.ibinbr = @floatCast(@as(f64, model.ibinbr) * lambda);
    m.ibinbrs = @floatCast(@as(f64, model.ibinbrs) * lambda);
    m.ibinbrqs = @floatCast(@as(f64, model.ibinbrqs) * lambda);
    return m;
}

// ============================================================================
// Comptime Validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "mextram: quiescent (all zero) currents ~ 0" {
    // At zero bias every exp(0)-1 term vanishes and all branch voltages are 0,
    // so the KCL residual at each terminal must be ~0. Any nonzero entry would
    // indicate a translation error in an offset/constant term.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{0.0} ** n_u, &model, &inst, 0);
    for (out) |v| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), v, 1e-12);
    }
}

test "mextram: forward-active collector/emitter currents" {
    // Drive the intrinsic BE junction forward: put B2 and B1 at 0.8 V, E1/E at 0,
    // collector nodes high (2 V) so IN flows C2->E1. This is the on-state.
    // We check global charge conservation of the DC residual: sum over the four
    // external terminals + substrate of the stamped currents must be zero
    // (KCL of the whole device, thermal node excluded), and that the emitter
    // sinks current while the collector sources it (signs), which is the core
    // physics regression.
    const model: Model = .{};
    const inst: Instance = .{};
    var xv: [n_u]f64 = .{0.0} ** n_u;
    xv[@intFromEnum(U.c)] = 2.0;
    xv[@intFromEnum(U.c1)] = 2.0;
    xv[@intFromEnum(U.c2)] = 2.0;
    xv[@intFromEnum(U.c3)] = 2.0;
    xv[@intFromEnum(U.c4)] = 2.0;
    xv[@intFromEnum(U.b)] = 0.8;
    xv[@intFromEnum(U.b1)] = 0.8;
    xv[@intFromEnum(U.b2)] = 0.8;
    const out = contract.evalValues(Self, xv, &model, &inst, 0);

    // Total current entering the device across all non-thermal terminals is 0.
    var total: f64 = 0.0;
    inline for (.{ U.c, U.b, U.e, U.s, U.b1, U.b2, U.e1, U.c1, U.c2, U.c3, U.c4 }) |u| {
        total += out[@intFromEnum(u)];
    }
    try testing.expectApproxEqAbs(@as(f64, 0.0), total, 1e-9);

    // Forward active: the intrinsic emitter node E1 must sink the main transport
    // current IN (E1 receives -IN and -IB1 etc). The external terminals here are
    // clamped equal to their inner partners (RE/RCc drops are zero), so the
    // observable on-state current lives on the internal nodes. Guards against an
    // all-zero eval and confirms IN turned on.
    try testing.expect(@abs(out[@intFromEnum(U.e1)]) > 1e-6);
    try testing.expect(out[@intFromEnum(U.e1)] < 0.0); // IN + IB currents leave via E1 (sign -)
}

test "mextram: charge conservation at zero bias" {
    // With zero bias all depletion charges reduce to their V=0 values and the
    // stamped charge vector must sum to zero across non-thermal terminals
    // (each charge is placed as +Q/-Q on a node pair).
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{0.0} ** n_u, &model, &inst, 0);
    var total: f64 = 0.0;
    inline for (.{ U.c, U.b, U.e, U.s, U.b1, U.b2, U.e1, U.c1, U.c2, U.c3, U.c4 }) |u| {
        total += out[@intFromEnum(u)];
    }
    try testing.expectApproxEqAbs(@as(f64, 0.0), total, 1e-18);
}

test "mextram: EB depletion charge sign under forward bias" {
    // Forward BE bias increases the stored B2-E1 charge (QB2E1 = QtE + QBE + QE),
    // which is stamped +Q at B2 and -Q at E1. So q[b2] > 0 and q[e1] < 0.
    const model: Model = .{};
    const inst: Instance = .{};
    var xv: [n_u]f64 = .{0.0} ** n_u;
    xv[@intFromEnum(U.b2)] = 0.7;
    const out = contract.qValues(Self, xv, &model, &inst, 0);
    try testing.expect(out[@intFromEnum(U.b2)] > 0.0);
    try testing.expect(out[@intFromEnum(U.e1)] < 0.0);
}
