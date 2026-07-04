const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: HiSIM2 v3.20 -- Surface-Potential-Based Bulk MOSFET
//
//   External terminals: d, g, s, b (4 ports)
//   Internal nodes: dp, gp, sp, bp, db, sb (intrinsic + body resistance)
//   Intrinsic MOSFET: dp-gp-sp-bp
//   Series resistances: d-dp (RD), g-gp (RSHG), s-sp (RS)
//   Body network: b-bp (RBPB), bp-dp (RBPD), bp-sp (RBPS), b-db (RBDB), b-sb (RBSB)
//   Junction diodes: bp-dp (drain), bp-sp (source)
//   Channel current: dp -> sp (drift-diffusion + CLM + velocity saturation)
//   Substrate current: impact ionization dp->bp
//   Gate tunneling: gp->sp, gp->dp, gp->bp
//   GIDL/GISL: dp->bp, sp->bp
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, dp, gp, sp, bp, db, sb };
pub const num_ports: usize = 4;

// ============================================================================
// Physical Constants
// ============================================================================
const Q_ELEC: f64 = 1.6022e-19;
const KB: f64 = 1.3806e-23;
const KB_Q: f64 = KB / Q_ELEC; // 8.6174e-5 eV/K
const EPS_SI: f64 = 1.0349e-10;
const EPS_OX: f64 = 3.4531e-11;
const NI_300K: f64 = 1.04e16; // m^-3
const GMIN_DEFAULT: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Model Flags ---
    type_: i32 = 1, // 1=NMOS, -1=PMOS
    version: f32 = 3.20,
    info: i32 = 0,
    corsrd: i32 = 0, // Source/drain resistance handling
    coiprv: i32 = 0,
    copprv: i32 = 0,
    coadov: i32 = 1, // Add overlap to intrinsic capacitance
    coisub: i32 = 0, // Calculate substrate current
    coiigs: i32 = 0, // Calculate gate tunneling current
    cogidl: i32 = 0, // Calculate GIDL/GISL
    coovlp: i32 = 1, // Calculate overlap charge
    coflick: i32 = 0, // Calculate 1/f noise
    coisti: i32 = 0, // Calculate STI leakage
    conqs: i32 = 0, // NQS mode
    cothrml: i32 = 0, // Calculate thermal noise
    coign: i32 = 0, // Calculate induced gate noise
    codfm: i32 = 0, // DFM calculation
    corecip: i32 = 1, // Accurate capacitance reciprocity
    coqy: i32 = 0, // Calculate Qy
    coqovsm: i32 = 1, // Smoothing method for Qover
    coerrrep: i32 = 1,
    coddlt: i32 = 1, // DDLT model selector
    codio: i32 = 0, // Updated diode model selector
    codep: i32 = 0, // Depletion device selector
    corg: i32 = 0, // Gate resistance
    corbnet: i32 = 0, // Body resistance network
    covdsres: i32 = 3, // Vdssatres model switch
    copt: i32 = 0, // Punchthrough flag
    copspt: i32 = 0,
    copb20compat: i32 = 1,

    // --- Geometry & Process ---
    tox: f32 = 3e-9,
    xld: f32 = 0,
    xldc: f32 = 0, // defaults to XLD at runtime
    lover: f32 = 30e-9,
    xwd: f32 = 0,
    xwdc: f32 = 0, // defaults to XWD at runtime
    xl: f32 = 0,
    xw: f32 = 0,
    ll: f32 = 0,
    lld: f32 = 0,
    lln: f32 = 0,
    wl: f32 = 0,
    wl1: f32 = 0,
    wl1p: f32 = 1.0,
    wl2: f32 = 0,
    wl2p: f32 = 1.0,
    wld: f32 = 0,
    wln: f32 = 0,
    tpoly: f32 = 200e-9,
    kappa: f32 = 3.90,
    tnom: f32 = 27.0,
    toxov: f32 = 3e-9, // defaults to TOX

    // --- Doping & Flat-Band ---
    vfbc: f32 = -1.0,
    vfbcl: f32 = 0,
    vfbclp: f32 = 1.0,
    vbi: f32 = 1.1,
    nsubc: f32 = 5e17,
    nsubp: f32 = 1e18,
    nsubpl: f32 = 0.001,
    nsubpfac: f32 = 1.0,
    nsubpdlt: f32 = 0.01,
    nsubpw: f32 = 0,
    nsubpwp: f32 = 1.0,
    parl2: f32 = 10e-9,
    lp: f32 = 0,
    lpext: f32 = 1e-50,
    npext: f32 = 5e17,
    npextw: f32 = 0,
    npextwp: f32 = 1.0,
    vfbover: f32 = 0,
    nover: f32 = 1e19,

    // --- Short-Channel & Pocket Effects ---
    scp1: f32 = 1.0,
    scp2: f32 = 0,
    scp3: f32 = 0,
    sc1: f32 = 1.0,
    sc2: f32 = 0,
    sc3: f32 = 0,
    sc4: f32 = 0,
    scp21: f32 = 0,
    scp22: f32 = 0,
    bs1: f32 = 0,
    bs2: f32 = 0.9,
    sc3vbs: f32 = 0,

    // --- Poly-Gate Depletion ---
    pgd1: f32 = 0,
    pgd2: f32 = 0.3,
    pgd4: f32 = 0,

    // --- Quantum Mechanical Effect ---
    qme1: f32 = 0,
    qme2: f32 = 2.0,
    qme3: f32 = 0,

    // --- Mobility ---
    muecb0: f32 = 190,
    muecb1: f32 = 30,
    muecb0lp: f32 = 0,
    muecb1lp: f32 = 0,
    mueph0: f32 = 0.3,
    mueph1: f32 = 25e3,
    muephl: f32 = 0,
    mueplp: f32 = 1.0,
    muepld: f32 = 0,
    muephw: f32 = 0,
    muepwp: f32 = 1.0,
    muepwd: f32 = 0,
    muephs: f32 = 0,
    muepsp: f32 = 1.0,
    muephl2: f32 = 0,
    mueplp2: f32 = 1.0,
    muephw2: f32 = 0,
    muepwp2: f32 = 1.0,
    muesr0: f32 = 2.0,
    muesr1: f32 = 5e14,
    muesrl: f32 = 0,
    mueslp: f32 = 1.0,
    muesrw: f32 = 0,
    mueswp: f32 = 1.0,
    muetmp: f32 = 1.5,
    ndep: f32 = 1.0,
    ndepl: f32 = 0,
    ndeplp: f32 = 1.0,
    ndepw: f32 = 0,
    ndepwp: f32 = 1.0,
    ninv: f32 = 0.5,
    ninvd: f32 = 0,
    ninvdl: f32 = 0,
    ninvdlp: f32 = 1.0,
    bb: f32 = 2,
    vmax: f32 = 1e7,
    vtmp: f32 = 0,
    wvth0: f32 = 0,

    // --- Channel Length Modulation ---
    clm1: f32 = 0.7,
    clm2: f32 = 2.0,
    clm3: f32 = 1.0,
    clm5: f32 = 1.0,
    clm6: f32 = 0,

    // --- Vds Smoothing (DDLT) ---
    ddltmax: f32 = 10,
    ddltslp: f32 = 10,
    ddltict: f32 = 0,

    // --- Overshoot ---
    vover: f32 = 0.3,
    voverp: f32 = 0.3,
    vovers: f32 = 0,
    voversp: f32 = 0,

    // --- Substrate Current ---
    sub1: f32 = 10,
    sub2: f32 = 25,
    sub1l: f32 = 2.5e-3,
    sub1lp: f32 = 1.0,
    sub2l: f32 = 2e-6,
    svgs: f32 = 0.8,
    svbs: f32 = 0.5,
    svbsl: f32 = 0,
    svbslp: f32 = 1.0,
    svds: f32 = 0.8,
    slg: f32 = 30e-9,
    slgl: f32 = 0,
    slglp: f32 = 1.0,
    svgsl: f32 = 0,
    svgslp: f32 = 1.0,
    svgsw: f32 = 0,
    svgswp: f32 = 1.0,
    subtmp: f32 = 0,
    ibpc1: f32 = 0,
    ibpc2: f32 = 0,

    // --- Gate Current (Tunneling) ---
    gleak1: f32 = 50,
    gleak2: f32 = 10e6,
    gleak3: f32 = 0.06,
    gleak4: f32 = 4.0,
    gleak5: f32 = 7.5e3,
    gleak6: f32 = 0.25,
    gleak7: f32 = 1e-6,
    glksd1: f32 = 1e-15,
    glksd2: f32 = 5e6,
    glksd3: f32 = -5e6,
    glkb1: f32 = 5e-16,
    glkb2: f32 = 1.0,
    glkb3: f32 = 0,
    egig: f32 = 0,
    igtemp2: f32 = 0,
    igtemp3: f32 = 0,

    // --- GIDL/GISL ---
    gidl1: f32 = 2.0,
    gidl2: f32 = 3e7,
    gidl3: f32 = 0.9,
    gidl4: f32 = 0,
    gidl5: f32 = 0.2,
    gidl6: f32 = 0,
    gidl7: f32 = 1.0,

    // --- Narrow Channel ---
    wfc: f32 = 0,
    nsubcw: f32 = 0,
    nsubcwp: f32 = 1.0,
    nsubcmax: f32 = 5e18,
    nsubcw2: f32 = 0,
    nsubcwp2: f32 = 1.0,

    // --- Series Resistance ---
    rs: f32 = 0,
    rd: f32 = 0,
    rsh: f32 = 0,
    rshg: f32 = 0,
    rmin: f32 = 1e-4,

    // --- Body Resistance Network ---
    rbpb: f32 = 50,
    rbpd: f32 = 50,
    rbps: f32 = 50,
    rbdb: f32 = 50,
    rbsb: f32 = 50,
    gbmin: f32 = 1e-12,

    // --- STI ---
    nsti: f32 = 5e17,
    wsti: f32 = 0,
    wstil: f32 = 0,
    wstilp: f32 = 1.0,
    wstiw: f32 = 0,
    wstiwp: f32 = 1.0,
    scsti1: f32 = 0,
    scsti2: f32 = 0,
    vthsti: f32 = 0,
    vdsti: f32 = 0,
    muesti1: f32 = 0,
    muesti2: f32 = 0,
    muesti3: f32 = 1.0,
    nsubpsti1: f32 = 0,
    nsubpsti2: f32 = 0,
    nsubpsti3: f32 = 1.0,
    nsubcsti1: f32 = 0,
    nsubcsti2: f32 = 0,
    nsubcsti3: f32 = 1.0,

    // --- Band Gap & Temperature ---
    eg0: f32 = 1.1785,
    bgtmp1: f32 = 90.25e-6,
    bgtmp2: f32 = 1e-7,

    // --- Overlap Capacitance ---
    cgso: f32 = 0,
    cgdo: f32 = 0,
    cgbo: f32 = 0,
    ovslp: f32 = 2.1e-7,
    ovmag: f32 = 0.6,
    ovinvdlt: f32 = 75.0,

    // --- Lateral-Field Capacitance (Qy) ---
    xqy: f32 = 10e-9,
    xqy1: f32 = 0,
    xqy2: f32 = 2.0,
    qyrat: f32 = 0.5,

    // --- Junction Diode ---
    js0: f32 = 0.5e-6,
    js0sw: f32 = 0,
    nj: f32 = 1.0,
    njsw: f32 = 1.0,
    xti: f32 = 2.0,
    xti2: f32 = 0,
    cisb: f32 = 0,
    cvb: f32 = 0,
    ctemp: f32 = 0,
    cisbk: f32 = 0,
    cvbk: f32 = 0, // defaults to CVB
    divx: f32 = 0,
    vdiffj: f32 = 0.6e-3,
    cj: f32 = 5e-4,
    cjsw: f32 = 5e-10,
    cjswg: f32 = 5e-10,
    mj: f32 = 0.5,
    mjsw: f32 = 0.33,
    mjswg: f32 = 0.33,
    pb: f32 = 1.0,
    pbsw: f32 = 1.0,
    pbswg: f32 = 1.0,
    tcjbd: f32 = 0,
    tcjbs: f32 = 0,
    tcjbdsw: f32 = 0,
    tcjbssw: f32 = 0,
    tcjbdswg: f32 = 0,
    tcjbsswg: f32 = 0,

    // --- Symmetry ---
    vzadd0: f32 = 0.02,
    pzadd0: f32 = 0.02,

    // --- NQS ---
    dly1: f32 = 100e-12,
    dly2: f32 = 0.7,
    dly3: f32 = 0.8e-6,

    // --- 1/f Noise ---
    nftrp: f32 = 10e9,
    nfalp: f32 = 1e-19,
    nfalp1: f32 = 1e-19, // defaults to NFALP
    nfalp2: f32 = 1e-19, // defaults to NFALP
    falph: f32 = 1.0,
    sidp: f32 = 2.0,
    dlnoise: f32 = 0,
    cit: f32 = 0,

    // --- Punchthrough ---
    ptl: f32 = 0,
    ptp: f32 = 3.5,
    pt2: f32 = 0,
    ptlp: f32 = 1.0,
    pt4: f32 = 0,
    pt4p: f32 = 1.0,
    gdl: f32 = 0,
    gdlp: f32 = 0,
    gdld: f32 = 0,
    xjpt: f32 = 3e-8,
    njunc: f32 = 1e20,
    mupt: f32 = 0,
    vfbpt: f32 = 0,
    pslimpt: f32 = 0,

    // --- WPE ---
    web: f32 = 0,
    wec: f32 = 0,
    nsubcwpe: f32 = 0,
    npextwpe: f32 = 0,
    nsubpwpe: f32 = 0,

    // --- DFM ---
    mphdfm: f32 = -0.3,

    // --- STI Reference ---
    saref: f32 = 1e-6,
    sbref: f32 = 1e-6,

    // --- GMIN ---
    gmin: f32 = 0,

    // --- Vertical Doping ---
    nsubd: f32 = 5e17, // defaults to NSUBC
    vsftd: f32 = 0,
    sc2d: f32 = 0,
    wdepv: f32 = 10,
    nsubdnw: f32 = 0,
    nsubdw: f32 = 0,
    nsubdwp: f32 = 1,
    nsubdw0: f32 = 5e17, // defaults to NSUBD
    vbsrfar: f32 = -30, // -TYPE*30

    // --- Binning ---
    lmin: f32 = 0,
    lmax: f32 = 1,
    wmin: f32 = 0,
    wmax: f32 = 1,
    lbinn: f32 = 1,
    wbinn: f32 = 1,

    // --- Binning L-prefix parameters ---
    lvmax: f32 = 0,
    lbgtmp1: f32 = 0,
    lbgtmp2: f32 = 0,
    leg0: f32 = 0,
    llover: f32 = 0,
    lvfbover: f32 = 0,
    lnover: f32 = 0,
    lwl2: f32 = 0,
    lvfbc: f32 = 0,
    lnsubc: f32 = 0,
    lnsubp: f32 = 0,
    lscp1: f32 = 0,
    lscp2: f32 = 0,
    lscp3: f32 = 0,
    lsc1: f32 = 0,
    lsc2: f32 = 0,
    lsc3: f32 = 0,
    lsc4: f32 = 0,
    lpgd1: f32 = 0,
    lndep: f32 = 0,
    lninv: f32 = 0,
    lmuecb0: f32 = 0,
    lmuecb1: f32 = 0,
    lmueph1: f32 = 0,
    lvtmp: f32 = 0,
    lwvth0: f32 = 0,
    lmuesr1: f32 = 0,
    lmuetmp: f32 = 0,
    lsub1: f32 = 0,
    lsub2: f32 = 0,
    lsvds: f32 = 0,
    lsvbs: f32 = 0,
    lsvgs: f32 = 0,
    lnsti: f32 = 0,
    lwsti: f32 = 0,
    lscsti1: f32 = 0,
    lscsti2: f32 = 0,
    lvthsti: f32 = 0,
    lmuesti1: f32 = 0,
    lmuesti2: f32 = 0,
    lmuesti3: f32 = 0,
    lnsubpsti1: f32 = 0,
    lnsubpsti2: f32 = 0,
    lnsubpsti3: f32 = 0,
    lnsubcsti1: f32 = 0,
    lnsubcsti2: f32 = 0,
    lnsubcsti3: f32 = 0,
    lcgso: f32 = 0,
    lcgdo: f32 = 0,
    lclm1: f32 = 0,
    lclm2: f32 = 0,
    lclm3: f32 = 0,
    lwfc: f32 = 0,
    lgidl1: f32 = 0,
    lgidl2: f32 = 0,
    lgleak1: f32 = 0,
    lgleak2: f32 = 0,
    lgleak3: f32 = 0,
    lgleak6: f32 = 0,
    lglksd1: f32 = 0,
    lglksd2: f32 = 0,
    lglkb1: f32 = 0,
    lglkb2: f32 = 0,
    lnftrp: f32 = 0,
    lnfalp: f32 = 0,
    libpc1: f32 = 0,
    libpc2: f32 = 0,
    ljs0: f32 = 0,
    ljs0sw: f32 = 0,
    lnj: f32 = 0,
    lcisbk: f32 = 0,
    lvdiffj: f32 = 0,

    // --- Binning W-prefix parameters ---
    wvmax: f32 = 0,
    wbgtmp1: f32 = 0,
    wbgtmp2: f32 = 0,
    weg0: f32 = 0,
    wlover: f32 = 0,
    wvfbover: f32 = 0,
    wnover: f32 = 0,
    wwl2: f32 = 0,
    wvfbc: f32 = 0,
    wnsubc: f32 = 0,
    wnsubp: f32 = 0,
    wscp1: f32 = 0,
    wscp2: f32 = 0,
    wscp3: f32 = 0,
    wsc1: f32 = 0,
    wsc2: f32 = 0,
    wsc3: f32 = 0,
    wsc4: f32 = 0,
    wpgd1: f32 = 0,
    wndep: f32 = 0,
    wninv: f32 = 0,
    wmuecb0: f32 = 0,
    wmuecb1: f32 = 0,
    wmueph1: f32 = 0,
    wvtmp: f32 = 0,
    wwvth0: f32 = 0,
    wmuesr1: f32 = 0,
    wmuetmp: f32 = 0,
    wsub1: f32 = 0,
    wsub2: f32 = 0,
    wsvds: f32 = 0,
    wsvbs: f32 = 0,
    wsvgs: f32 = 0,
    wnsti: f32 = 0,
    wwsti: f32 = 0,
    wscsti1: f32 = 0,
    wscsti2: f32 = 0,
    wvthsti: f32 = 0,
    wmuesti1: f32 = 0,
    wmuesti2: f32 = 0,
    wmuesti3: f32 = 0,
    wnsubpsti1: f32 = 0,
    wnsubpsti2: f32 = 0,
    wnsubpsti3: f32 = 0,
    wnsubcsti1: f32 = 0,
    wnsubcsti2: f32 = 0,
    wnsubcsti3: f32 = 0,
    wcgso: f32 = 0,
    wcgdo: f32 = 0,
    wclm1: f32 = 0,
    wclm2: f32 = 0,
    wclm3: f32 = 0,
    wwfc: f32 = 0,
    wgidl1: f32 = 0,
    wgidl2: f32 = 0,
    wgleak1: f32 = 0,
    wgleak2: f32 = 0,
    wgleak3: f32 = 0,
    wgleak6: f32 = 0,
    wglksd1: f32 = 0,
    wglksd2: f32 = 0,
    wglkb1: f32 = 0,
    wglkb2: f32 = 0,
    wnftrp: f32 = 0,
    wnfalp: f32 = 0,
    wibpc1: f32 = 0,
    wibpc2: f32 = 0,
    wjs0: f32 = 0,
    wjs0sw: f32 = 0,
    wnj: f32 = 0,
    wcisbk: f32 = 0,
    wvdiffj: f32 = 0,

    // --- Binning P-prefix (cross-term) parameters ---
    pvmax: f32 = 0,
    pbgtmp1: f32 = 0,
    pbgtmp2: f32 = 0,
    peg0: f32 = 0,
    plover: f32 = 0,
    pvfbover: f32 = 0,
    pnover: f32 = 0,
    pwl2: f32 = 0,
    pvfbc: f32 = 0,
    pnsubc: f32 = 0,
    pnsubp: f32 = 0,
    pscp1: f32 = 0,
    pscp2: f32 = 0,
    pscp3: f32 = 0,
    psc1: f32 = 0,
    psc2: f32 = 0,
    psc3: f32 = 0,
    psc4: f32 = 0,
    ppgd1: f32 = 0,
    pndep: f32 = 0,
    pninv: f32 = 0,
    pmuecb0: f32 = 0,
    pmuecb1: f32 = 0,
    pmueph1: f32 = 0,
    pvtmp: f32 = 0,
    pwvth0: f32 = 0,
    pmuesr1: f32 = 0,
    pmuetmp: f32 = 0,
    psub1: f32 = 0,
    psub2: f32 = 0,
    psvds: f32 = 0,
    psvbs: f32 = 0,
    psvgs: f32 = 0,
    pnsti: f32 = 0,
    pwsti: f32 = 0,
    pscsti1: f32 = 0,
    pscsti2: f32 = 0,
    pvthsti: f32 = 0,
    pmuesti1: f32 = 0,
    pmuesti2: f32 = 0,
    pmuesti3: f32 = 0,
    pnsubpsti1: f32 = 0,
    pnsubpsti2: f32 = 0,
    pnsubpsti3: f32 = 0,
    pnsubcsti1: f32 = 0,
    pnsubcsti2: f32 = 0,
    pnsubcsti3: f32 = 0,
    pcgso: f32 = 0,
    pcgdo: f32 = 0,
    pclm1: f32 = 0,
    pclm2: f32 = 0,
    pclm3: f32 = 0,
    pwfc: f32 = 0,
    pgidl1: f32 = 0,
    pgidl2: f32 = 0,
    pgleak1: f32 = 0,
    pgleak2: f32 = 0,
    pgleak3: f32 = 0,
    pgleak6: f32 = 0,
    pglksd1: f32 = 0,
    pglksd2: f32 = 0,
    pglkb1: f32 = 0,
    pglkb2: f32 = 0,
    pnftrp: f32 = 0,
    pnfalp: f32 = 0,
    pibpc1: f32 = 0,
    pibpc2: f32 = 0,
    pjs0: f32 = 0,
    pjs0sw: f32 = 0,
    pnj: f32 = 0,
    pcisbk: f32 = 0,
    pvdiffj: f32 = 0,

    // --- Depletion-Mode MOSFET ---
    ndepm: f32 = 1e17,
    ndepml: f32 = 0,
    ndepmlp: f32 = 1.0,
    tndep: f32 = 0.2e-6,
    depleak: f32 = 0,
    depleakl: f32 = 0,
    depleaklp: f32 = 1.0,
    depeta: f32 = 0,
    depmue0: f32 = 1e3,
    depmue0l: f32 = 0,
    depmue0lp: f32 = 1.0,
    depmue1: f32 = 0,
    depmue1l: f32 = 0,
    depmue1lp: f32 = 1.0,
    depmue2: f32 = 1e3,
    depmueback0: f32 = 100,
    depmueback0l: f32 = 0,
    depmueback0lp: f32 = 1.0,
    depmueback1: f32 = 0,
    depmueback1l: f32 = 0,
    depmueback1lp: f32 = 1.0,
    depmueph0: f32 = 0.3,
    depmueph1: f32 = 5e3,
    depvmax: f32 = 3e7,
    depvmaxl: f32 = 0,
    depvmaxlp: f32 = 1.0,
    depvdsef1: f32 = 2.0,
    depvdsef1l: f32 = 0,
    depvdsef1lp: f32 = 1.0,
    depvdsef2: f32 = 0.5,
    depvdsef2l: f32 = 0,
    depvdsef2lp: f32 = 1.0,
    depbb: f32 = 1.0,
    depmuetmp: f32 = 1.5,
    depddlt: f32 = 3.0,
    deprbr: f32 = 1,
    depsubsl: f32 = 2.0,
    depvgpsl: f32 = 0,
    depninvd: f32 = 0,
    depvfbc: f32 = -1.0, // defaults to VFBC
    depps: f32 = 0.01,
    depqf: f32 = 0.01,
    depfdpd: f32 = 0.2,
    deppb0: f32 = 0.5,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    l: f32 = 5e-6,
    w: f32 = 5e-6,
    nf: f32 = 1,
    nrd: f32 = 0,
    nrs: f32 = 0,
    ngcon: f32 = 1,
    xgw: f32 = 0,
    xgl: f32 = 0,
    sa: f32 = 0,
    sb: f32 = 0,
    sd: f32 = 0,
    dtemp: f32 = 0,
    ad: f32 = 0,
    as_: f32 = 0,
    pd: f32 = 0,
    ps: f32 = 0,
    sca: f32 = 0,
    scb: f32 = 0,
    scc: f32 = 0,
    nsubcdfm: f32 = 5e17,
    vgsmin: f32 = -5, // -5*TYPE
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Channel thermal noise: dp -- sp
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp), .kind = .thermal },
    // Channel flicker (1/f) noise: dp -- sp
    .{ .row = @intFromEnum(U.dp), .col = @intFromEnum(U.sp), .kind = .flicker },
    // Drain junction shot noise: bp -- dp
    .{ .row = @intFromEnum(U.bp), .col = @intFromEnum(U.dp), .kind = .shot },
    // Source junction shot noise: bp -- sp
    .{ .row = @intFromEnum(U.bp), .col = @intFromEnum(U.sp), .kind = .shot },
    // Gate tunneling shot noise: gp -- dp
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.dp), .kind = .shot },
    // Gate tunneling shot noise: gp -- sp
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.sp), .kind = .shot },
    // Gate-bulk shot noise: gp -- bp
    .{ .row = @intFromEnum(U.gp), .col = @intFromEnum(U.bp), .kind = .shot },
};

// ============================================================================
// Smoothing Helpers (f64 -- used only on x-independent quantities)
// ============================================================================

/// SmoothZero: max(x, 0) with smooth transition
inline fn smoothZero(x: f64, delta: f64) f64 {
    return 0.5 * (x + @sqrt(x * x + 4.0 * delta * delta));
}

/// SmoothUpper: min(x, xmax) with smooth transition
inline fn smoothUpper(x: f64, xmax: f64, delta: f64) f64 {
    const t = xmax - x - delta;
    return xmax - 0.5 * (t + @sqrt(t * t + 4.0 * @abs(xmax) * delta));
}

/// SmoothLower: max(x, xmin) with smooth transition
inline fn smoothLower(x: f64, xmin: f64, delta: f64) f64 {
    const t = x - xmin - delta;
    return xmin + 0.5 * (t + @sqrt(t * t + 4.0 * @abs(xmin) * delta));
}

// ============================================================================
// S-generic Smoothing Helpers (x-dependent chains)
// ============================================================================

/// Limited exponential (value-form). Branch on .val() to reproduce the
/// original piecewise definition exactly; each branch computed in S ops.
inline fn lexpS(comptime S: type, x: S) S {
    const exp80 = @exp(80.0);
    const exp_neg80 = @exp(-80.0);
    if (x.val() > 80.0) {
        // exp80 * (1 + x - 80)
        return x.addC(1.0 - 80.0).scale(exp80);
    } else if (x.val() < -80.0) {
        return S.con(exp_neg80);
    } else {
        return x.minC(80.0).maxC(-80.0).exp();
    }
}

/// SymAdd: symmetry modification at Vds=0 (value-form).
/// a0 is an x-independent constant.
inline fn symAddS(comptime S: type, x_in: S, a0: f64) S {
    // t1 = 2*x_in/(a0+1e-30)
    const t1 = x_in.scale(2.0 / (a0 + 1.0e-30));
    const t1_sq = t1.mul(t1);
    // denom = 1 + t1*(0.5 + t1*(1/6 + t1_sq*(1/120)))
    const inner = t1_sq.scale(1.0 / 120.0).addC(1.0 / 6.0);
    const denom = t1.mul(inner).addC(0.5).mul(t1).addC(1.0);
    return S.con(a0).div(denom);
}

// ============================================================================
// Parameter Prep (x-INDEPENDENT). Everything not derived from terminal
// voltages is computed here in plain f64.
// ============================================================================

const IParams = struct {
    type_f: f64,
    // geometry / oxide
    p_tox: f64,
    p_vfbc: f64,
    c_ox: f64,
    c_ox_inv: f64,
    l_gate: f64,
    l_gate_um: f64,
    w_gate_um: f64,
    l_eff: f64,
    w_eff: f64,
    l_ch_init: f64,
    // temperature
    temp_k: f64,
    tnom_k: f64,
    beta_inv: f64,
    beta: f64,
    eg_t: f64,
    temp_ratio: f64,
    // doping / surface potential constants
    nsub: f64,
    vfb: f64,
    phi_b0: f64,
    cnst0: f64,
    fac1: f64,
    fac1_sq: f64,
    cnst1: f64,
    // QME params
    p_qme1: f64,
    p_qme2: f64,
    p_qme3: f64,
    // symmetry
    p_vzadd0: f64,
    p_bs1: f64,
    p_bs2: f64,
    // SCE / vth
    p_parl2: f64,
    p_vbi: f64,
    p_sc1: f64,
    p_sc2: f64,
    p_sc3: f64,
    p_sc4: f64,
    p_scp1: f64,
    p_scp2: f64,
    p_scp3: f64,
    p_scp22: f64,
    p_lp: f64,
    p_wfc: f64,
    p_wvth0: f64,
    p_ptl: f64,
    p_ptp: f64,
    p_pt2: f64,
    // poly-gate depletion
    p_pgd1: f64,
    p_pgd2: f64,
    // mobility
    p_muecb0: f64,
    p_muecb1: f64,
    p_mueph0: f64,
    p_mueph1: f64,
    p_muesr0: f64,
    p_muesr1: f64,
    p_ndep: f64,
    p_ninv: f64,
    p_ninvd: f64,
    p_bb: f64,
    p_vmax: f64,
    p_vtmp: f64,
    p_muetmp: f64,
    // velocity saturation / DDLT
    p_ddltmax: f64,
    p_ddltslp: f64,
    p_ddltict: f64,
    // CLM
    p_clm1: f64,
    p_clm2: f64,
    p_clm3: f64,
    p_clm5: f64,
    p_clm6: f64,
    // overshoot
    p_vover: f64,
    p_voverp: f64,
    p_vovers: f64,
    p_voversp: f64,
    // substrate
    p_sub1: f64,
    p_sub2: f64,
    p_sub2l: f64,
    p_svds: f64,
    p_slg: f64,
    // gate tunneling
    p_gleak1: f64,
    p_gleak2: f64,
    p_gleak3: f64,
    p_gleak4: f64,
    p_gleak5: f64,
    p_glksd1: f64,
    p_glksd2: f64,
    p_glksd3: f64,
    p_glkb1: f64,
    p_glkb2: f64,
    // GIDL
    p_gidl1: f64,
    p_gidl2: f64,
    p_gidl3: f64,
    p_gidl4: f64,
    p_gidl5: f64,
    p_gidl6: f64,
    p_gidl7: f64,
    // junction diodes
    p_nj: f64,
    p_njsw: f64,
    p_js0: f64,
    p_js0sw: f64,
    p_cisb: f64,
    p_cvb: f64,
    p_cisbk: f64,
    p_cvbk: f64,
    p_divx: f64,
    p_vdiffj: f64,
    p_ctemp: f64,
    p_xti: f64,
    p_xti2: f64,
    eg_tnom: f64,
    is_d: f64,
    is_s: f64,
    is_d_bottom: f64,
    is_d_sw: f64,
    is_s_bottom: f64,
    is_s_sw: f64,
    jct_temp_factor: f64,
    jct_temp_factor2: f64,
    // series resistances
    g_rs: f64,
    g_rd: f64,
    g_rg: f64,
    g_rbpb: f64,
    g_rbpd: f64,
    g_rbps: f64,
    g_rbdb: f64,
    g_rbsb: f64,
    // gmin / multipliers
    gmin_val: f64,
    m_nf: f64,
};

fn prepI(model: *const Model, instance: *const Instance) IParams {
    const type_f: f64 = @floatFromInt(model.type_);
    const p_tox: f64 = @as(f64, model.tox);
    const p_xld: f64 = @as(f64, model.xld);
    const p_xwd: f64 = @as(f64, model.xwd);
    const p_xl: f64 = @as(f64, model.xl);
    const p_xw: f64 = @as(f64, model.xw);
    const p_ll: f64 = @as(f64, model.ll);
    const p_lld: f64 = @as(f64, model.lld);
    const p_lln: f64 = @as(f64, model.lln);
    const p_wl: f64 = @as(f64, model.wl);
    const p_wld: f64 = @as(f64, model.wld);
    const p_wln: f64 = @as(f64, model.wln);
    const p_tnom: f64 = @as(f64, model.tnom);
    const p_vfbc: f64 = @as(f64, model.vfbc);
    const p_vfbcl: f64 = @as(f64, model.vfbcl);
    const p_vfbclp: f64 = @as(f64, model.vfbclp);
    const p_nsubc: f64 = @as(f64, model.nsubc);
    const p_eg0: f64 = @as(f64, model.eg0);
    const p_bgtmp1: f64 = @as(f64, model.bgtmp1);
    const p_bgtmp2: f64 = @as(f64, model.bgtmp2);
    const p_muesr1: f64 = @as(f64, model.muesr1);

    const inst_l: f64 = @as(f64, instance.l);
    const inst_w: f64 = @as(f64, instance.w);
    const inst_nf: f64 = @as(f64, instance.nf);
    const inst_nrd: f64 = @as(f64, instance.nrd);
    const inst_nrs: f64 = @as(f64, instance.nrs);
    const inst_dtemp: f64 = @as(f64, instance.dtemp);

    // Temperature
    const temp_k = p_tnom + inst_dtemp + 273.15;
    const tnom_k = p_tnom + 273.15;
    const beta_inv = KB_Q * temp_k;
    const beta = 1.0 / beta_inv;
    const eg_t = p_eg0 - temp_k * (p_bgtmp1 + temp_k * p_bgtmp2);
    const eg_tnom = p_eg0 - tnom_k * (p_bgtmp1 + tnom_k * p_bgtmp2);
    const temp_ratio = temp_k / tnom_k;
    const ni = NI_300K * @exp(0.5 * (eg_tnom / (KB_Q * 300.0) - eg_t / beta_inv));

    // Geometry
    const l_gate = inst_l + p_xl;
    const w_gate = inst_w / inst_nf + p_xw;
    const l_gate_um = l_gate * 1.0e6;
    const w_gate_um = w_gate * 1.0e6;
    const dl = p_xld + p_ll / @exp(p_lln * @log(@max(l_gate + p_lld, 1.0e-30)));
    const dw = p_xwd + p_wl / @exp(p_wln * @log(@max(w_gate + p_wld, 1.0e-30)));
    const l_eff = @max(l_gate - 2.0 * dl, 1.0e-9);
    const w_eff = @max(w_gate - 2.0 * dw, 1.0e-9);
    const l_ch_init = l_eff;

    // NSUBC
    const nsubc_cm3 = @max(p_nsubc, 1.0);
    const nsub = nsubc_cm3 * 1.0e6;

    // Flat-band voltage
    const vfb = p_vfbc * (1.0 + p_vfbcl / @exp(p_vfbclp * @log(@max(l_gate_um, 1.0e-30))));

    // Surface potential constants (note: c_ox here uses nominal tox since the
    // QME correction depends on Vgs; the QME term is folded into c_ox inside
    // eval where it becomes x-dependent).
    const phi_b0 = 2.0 * beta_inv * @log(@max(nsub / ni, 1.0));
    const cnst0 = @sqrt(2.0 * Q_ELEC * nsub * EPS_SI);
    const cnst1 = ni * ni / (nsub * nsub);

    _ = p_muesr1;

    // -- Junction saturation currents (x-independent temperature part) --
    const inst_ad: f64 = @as(f64, instance.ad);
    const inst_as: f64 = @as(f64, instance.as_);
    const inst_pd: f64 = @as(f64, instance.pd);
    const inst_ps: f64 = @as(f64, instance.ps);
    const p_js0: f64 = @as(f64, model.js0);
    const p_js0sw: f64 = @as(f64, model.js0sw);
    const p_nj: f64 = @as(f64, model.nj);
    const p_xti: f64 = @as(f64, model.xti);
    const p_xti2: f64 = @as(f64, model.xti2);
    const p_ctemp: f64 = @as(f64, model.ctemp);

    const ad_eff: f64 = if (inst_ad > 0.0) inst_ad else w_eff * 1.0e-6;
    const as_eff: f64 = if (inst_as > 0.0) inst_as else w_eff * 1.0e-6;
    const pd_eff: f64 = if (inst_pd > 0.0) inst_pd else 2.0 * w_eff;
    const ps_eff: f64 = if (inst_ps > 0.0) inst_ps else 2.0 * w_eff;

    const delta_temp = temp_k - tnom_k;
    const xti_eff = p_xti + p_xti2 * delta_temp;
    const jct_temp_factor = @exp(xti_eff / @max(p_nj, 0.01) * @log(temp_ratio)) * @exp((eg_tnom / (p_nj * KB_Q * tnom_k) - eg_t / (p_nj * beta_inv)));
    const jct_temp_factor2 = 1.0 + p_ctemp * delta_temp;

    const is_d_bottom = p_js0 * ad_eff;
    const is_d_sw = p_js0sw * pd_eff;
    const is_d = (is_d_bottom + is_d_sw) * jct_temp_factor * jct_temp_factor2 + 1.0e-30;

    const is_s_bottom = p_js0 * as_eff;
    const is_s_sw = p_js0sw * ps_eff;
    const is_s = (is_s_bottom + is_s_sw) * jct_temp_factor * jct_temp_factor2 + 1.0e-30;

    // -- Series resistances --
    const p_rs: f64 = @as(f64, model.rs);
    const p_rd: f64 = @as(f64, model.rd);
    const p_rsh: f64 = @as(f64, model.rsh);
    const p_rshg: f64 = @as(f64, model.rshg);
    const p_rmin: f64 = @as(f64, model.rmin);
    const p_rbpb: f64 = @as(f64, model.rbpb);
    const p_rbpd: f64 = @as(f64, model.rbpd);
    const p_rbps: f64 = @as(f64, model.rbps);
    const p_rbdb: f64 = @as(f64, model.rbdb);
    const p_rbsb: f64 = @as(f64, model.rbsb);
    const p_gbmin: f64 = @as(f64, model.gbmin);
    const p_gmin_mdl: f64 = @as(f64, model.gmin);

    const rs_val = p_rs / @max(w_eff, 1.0e-30) + p_rsh * inst_nrs;
    const g_rs: f64 = if (rs_val > p_rmin) 1.0 / rs_val else GSHORT;
    const rd_val = p_rd / @max(w_eff, 1.0e-30) + p_rsh * inst_nrd;
    const g_rd: f64 = if (rd_val > p_rmin) 1.0 / rd_val else GSHORT;
    const rg_val = p_rshg / (3.0 * @max(inst_nf, 1.0));
    const g_rg: f64 = if (rg_val > p_rmin and model.corg != 0) 1.0 / rg_val else GSHORT;

    const g_rbpb: f64 = if (model.corbnet != 0 and p_rbpb > 0.0) 1.0 / p_rbpb + p_gbmin else GSHORT;
    const g_rbpd: f64 = if (model.corbnet != 0 and p_rbpd > 0.0) 1.0 / p_rbpd + p_gbmin else 0.0;
    const g_rbps: f64 = if (model.corbnet != 0 and p_rbps > 0.0) 1.0 / p_rbps + p_gbmin else 0.0;
    const g_rbdb: f64 = if (model.corbnet != 0 and p_rbdb > 0.0) 1.0 / p_rbdb + p_gbmin else GSHORT;
    const g_rbsb: f64 = if (model.corbnet != 0 and p_rbsb > 0.0) 1.0 / p_rbsb + p_gbmin else GSHORT;

    const gmin_val: f64 = if (p_gmin_mdl > 0.0) p_gmin_mdl else GMIN_DEFAULT;

    // c_ox / fac1 computed with nominal tox; the QME correction (Vgs-dependent)
    // is applied to c_ox inside eval. Here we pre-store the nominal.
    const t_oxe_nom = @max(p_tox, 1.0e-12);
    const c_ox = EPS_OX / t_oxe_nom;
    const c_ox_inv = t_oxe_nom / EPS_OX;
    const fac1 = cnst0 / c_ox;
    const fac1_sq = fac1 * fac1;

    return .{
        .type_f = type_f,
        .p_tox = p_tox,
        .p_vfbc = p_vfbc,
        .c_ox = c_ox,
        .c_ox_inv = c_ox_inv,
        .l_gate = l_gate,
        .l_gate_um = l_gate_um,
        .w_gate_um = w_gate_um,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .l_ch_init = l_ch_init,
        .temp_k = temp_k,
        .tnom_k = tnom_k,
        .beta_inv = beta_inv,
        .beta = beta,
        .eg_t = eg_t,
        .temp_ratio = temp_ratio,
        .nsub = nsub,
        .vfb = vfb,
        .phi_b0 = phi_b0,
        .cnst0 = cnst0,
        .fac1 = fac1,
        .fac1_sq = fac1_sq,
        .cnst1 = cnst1,
        .p_qme1 = @as(f64, model.qme1),
        .p_qme2 = @as(f64, model.qme2),
        .p_qme3 = @as(f64, model.qme3),
        .p_vzadd0 = @as(f64, model.vzadd0),
        .p_bs1 = @as(f64, model.bs1),
        .p_bs2 = @as(f64, model.bs2),
        .p_parl2 = @as(f64, model.parl2),
        .p_vbi = @as(f64, model.vbi),
        .p_sc1 = @as(f64, model.sc1),
        .p_sc2 = @as(f64, model.sc2),
        .p_sc3 = @as(f64, model.sc3),
        .p_sc4 = @as(f64, model.sc4),
        .p_scp1 = @as(f64, model.scp1),
        .p_scp2 = @as(f64, model.scp2),
        .p_scp3 = @as(f64, model.scp3),
        .p_scp22 = @as(f64, model.scp22),
        .p_lp = @as(f64, model.lp),
        .p_wfc = @as(f64, model.wfc),
        .p_wvth0 = @as(f64, model.wvth0),
        .p_ptl = @as(f64, model.ptl),
        .p_ptp = @as(f64, model.ptp),
        .p_pt2 = @as(f64, model.pt2),
        .p_pgd1 = @as(f64, model.pgd1),
        .p_pgd2 = @as(f64, model.pgd2),
        .p_muecb0 = @as(f64, model.muecb0),
        .p_muecb1 = @as(f64, model.muecb1),
        .p_mueph0 = @as(f64, model.mueph0),
        .p_mueph1 = @as(f64, model.mueph1),
        .p_muesr0 = @as(f64, model.muesr0),
        .p_muesr1 = @as(f64, model.muesr1),
        .p_ndep = @as(f64, model.ndep),
        .p_ninv = @as(f64, model.ninv),
        .p_ninvd = @as(f64, model.ninvd),
        .p_bb = @as(f64, model.bb),
        .p_vmax = @as(f64, model.vmax),
        .p_vtmp = @as(f64, model.vtmp),
        .p_muetmp = @as(f64, model.muetmp),
        .p_ddltmax = @as(f64, model.ddltmax),
        .p_ddltslp = @as(f64, model.ddltslp),
        .p_ddltict = @as(f64, model.ddltict),
        .p_clm1 = @as(f64, model.clm1),
        .p_clm2 = @as(f64, model.clm2),
        .p_clm3 = @as(f64, model.clm3),
        .p_clm5 = @as(f64, model.clm5),
        .p_clm6 = @as(f64, model.clm6),
        .p_vover = @as(f64, model.vover),
        .p_voverp = @as(f64, model.voverp),
        .p_vovers = @as(f64, model.vovers),
        .p_voversp = @as(f64, model.voversp),
        .p_sub1 = @as(f64, model.sub1),
        .p_sub2 = @as(f64, model.sub2),
        .p_sub2l = @as(f64, model.sub2l),
        .p_svds = @as(f64, model.svds),
        .p_slg = @as(f64, model.slg),
        .p_gleak1 = @as(f64, model.gleak1),
        .p_gleak2 = @as(f64, model.gleak2),
        .p_gleak3 = @as(f64, model.gleak3),
        .p_gleak4 = @as(f64, model.gleak4),
        .p_gleak5 = @as(f64, model.gleak5),
        .p_glksd1 = @as(f64, model.glksd1),
        .p_glksd2 = @as(f64, model.glksd2),
        .p_glksd3 = @as(f64, model.glksd3),
        .p_glkb1 = @as(f64, model.glkb1),
        .p_glkb2 = @as(f64, model.glkb2),
        .p_gidl1 = @as(f64, model.gidl1),
        .p_gidl2 = @as(f64, model.gidl2),
        .p_gidl3 = @as(f64, model.gidl3),
        .p_gidl4 = @as(f64, model.gidl4),
        .p_gidl5 = @as(f64, model.gidl5),
        .p_gidl6 = @as(f64, model.gidl6),
        .p_gidl7 = @as(f64, model.gidl7),
        .p_nj = p_nj,
        .p_njsw = @as(f64, model.njsw),
        .p_js0 = p_js0,
        .p_js0sw = p_js0sw,
        .p_cisb = @as(f64, model.cisb),
        .p_cvb = @as(f64, model.cvb),
        .p_cisbk = @as(f64, model.cisbk),
        .p_cvbk = @as(f64, if (model.cvbk != 0) model.cvbk else model.cvb),
        .p_divx = @as(f64, model.divx),
        .p_vdiffj = @as(f64, model.vdiffj),
        .p_ctemp = p_ctemp,
        .p_xti = p_xti,
        .p_xti2 = p_xti2,
        .eg_tnom = eg_tnom,
        .is_d = is_d,
        .is_s = is_s,
        .is_d_bottom = is_d_bottom,
        .is_d_sw = is_d_sw,
        .is_s_bottom = is_s_bottom,
        .is_s_sw = is_s_sw,
        .jct_temp_factor = jct_temp_factor,
        .jct_temp_factor2 = jct_temp_factor2,
        .g_rs = g_rs,
        .g_rd = g_rd,
        .g_rg = g_rg,
        .g_rbpb = g_rbpb,
        .g_rbpd = g_rbpd,
        .g_rbps = g_rbps,
        .g_rbdb = g_rbdb,
        .g_rbsb = g_rbsb,
        .gmin_val = gmin_val,
        .m_nf = inst_nf,
    };
}

// ============================================================================
// DC Current Function (value-form). Physics generic over scalar S; only the
// x-dependent chains use S ops. Parameter prep is hoisted into prepI (f64).
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = instance;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.dp);
    const gp = @intFromEnum(U.gp);
    const sp = @intFromEnum(U.sp);
    const bp = @intFromEnum(U.bp);
    const db = @intFromEnum(U.db);
    const sb = @intFromEnum(U.sb);

    const p = &pc.dc;
    const type_f = p.type_f;
    const beta = p.beta;
    const beta_inv = p.beta_inv;
    const phi_b0 = p.phi_b0;
    const cnst0 = p.cnst0;
    const cnst1 = p.cnst1;
    const nsub = p.nsub;
    const w_eff = p.w_eff;
    const l_eff = p.l_eff;
    const l_gate = p.l_gate;
    const l_gate_um = p.l_gate_um;
    const w_gate_um = p.w_gate_um;
    const l_ch_init = p.l_ch_init;
    const vfb = p.vfb;
    const eg_t = p.eg_t;
    const temp_k = p.temp_k;
    const tnom_k = p.tnom_k;
    const temp_ratio = p.temp_ratio;

    // ========================================================================
    // Oxide Capacitance (with quantum mechanical effect on Tox) -- x-dependent
    // ========================================================================
    const vgs_for_qme = x[gp].sub(x[sp]).scale(type_f);
    // dTox = QME1 / max(|Vgs - Vfb - QME2|, 0.01) + QME3
    const qme1_denom = vgs_for_qme.addC(-p.p_vfbc - p.p_qme2).abs().maxC(0.01);
    const dtox_qme = S.con(p.p_qme1).div(qme1_denom).addC(p.p_qme3);
    const t_oxe = dtox_qme.addC(p.p_tox).maxC(1.0e-12);
    const c_ox = t_oxe.pow(-1.0).scale(EPS_OX); // EPS_OX / t_oxe
    const c_ox_inv = t_oxe.scale(1.0 / EPS_OX);
    const fac1 = c_ox.pow(-1.0).scale(cnst0); // cnst0 / c_ox
    const fac1_sq = fac1.mul(fac1);

    // ========================================================================
    // Terminal Voltages (typed for NMOS/PMOS)
    // ========================================================================
    const vgs_raw = x[gp].sub(x[sp]).scale(type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(type_f);
    const vbs_raw = x[bp].sub(x[sp]).scale(type_f);

    // Source-drain reversal (branchless)
    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs = vgs_raw.sub(vds_neg);
    const vds = vds_abs;
    const vbs = vbs_raw.sub(vds_neg);

    const mode = vds_raw.div(vds_abs.addC(1.0e-30));

    // ========================================================================
    // Symmetry Modification (Vzadd)
    // ========================================================================
    // dvbs_coeff = 1 + BS1 / (1 + exp(-vbs/max(BS2,0.01)))
    const dvbs_coeff = S.con(p.p_bs1).div(vbs.scale(-1.0 / @max(p.p_bs2, 0.01)).exp().addC(1.0)).addC(1.0);
    const vzadd = symAddS(S, vds.scale(0.5).mul(dvbs_coeff), p.p_vzadd0);
    const vbsz = vbs.add(vzadd);
    const vdsz = vds.add(vzadd.scale(2.0));
    const vgsz = vgs.add(vzadd);

    // Clamp Vbs for surface potential
    const vbscl = vbsz.minC(phi_b0 - 0.1);

    // ========================================================================
    // Short-Channel Effect (dVth)
    // ========================================================================
    const phi_b2 = phi_b0;
    const phi_bsum = vbscl.scale(-1.0).addC(phi_b2).maxC(0.01); // max(phi_b2 - vbscl, 0.01)
    // w_dpl = sqrt(2*EPS_SI*phi_bsum/(Q*nsub))
    const w_dpl = phi_bsum.scale(2.0 * EPS_SI / (Q_ELEC * nsub)).sqrt();
    const l_gate_eff = @max(l_gate - p.p_parl2, 1.0e-9);

    // dVth0 = 2*(VBI-phi_b0)*EPS_SI*w_dpl/(Cox*Lgeff^2)*sqrt(phi_bsum)
    const dvth0 = w_dpl.mul(phi_bsum.sqrt()).scale(2.0 * (p.p_vbi - phi_b0) * EPS_SI / (l_gate_eff * l_gate_eff)).div(c_ox);

    // SCE contribution: dvth0*(SC1 + SC3/Lgate*phi_bsum + SC2*vdsz*(1+SC4*phi_bsum))
    const sce_inner = phi_bsum.scale(p.p_sc3 / l_gate)
        .add(vdsz.mul(phi_bsum.scale(p.p_sc4).addC(1.0)).scale(p.p_sc2))
        .addC(p.p_sc1);
    const dvth_sc = dvth0.mul(sce_inner);

    // Pocket contribution (LP != 0)
    const dvth_lp: S = if (p.p_lp > 0.0)
        dvth0.mul(phi_bsum.scale(p.p_scp3 / @max(p.p_lp, 1.0e-30)).add(vdsz.scale(p.p_scp2)).addC(p.p_scp1))
            .sub(vdsz.mul(vdsz).addC(0.01).pow(-1.0).scale(p.p_scp22))
    else
        S.con(0.0);

    // Narrow-channel effect
    const w_eff_cv = w_eff;
    // qb0_for_wfc = cnst0*sqrt(max(phi_b2 - vbscl, 1e-30))
    const qb0_for_wfc = vbscl.scale(-1.0).addC(phi_b2).maxC(1.0e-30).sqrt().scale(cnst0);
    // dvth_w = qb0_for_wfc*(c_ox_inv - 1/(c_ox + WFC/max(w_eff_cv,1e-30))) + WVTH0/max(w_gate_um,1e-30)
    const dvth_w = qb0_for_wfc.mul(c_ox_inv.sub(c_ox.addC(p.p_wfc / @max(w_eff_cv, 1.0e-30)).pow(-1.0)))
        .addC(p.p_wvth0 / @max(w_gate_um, 1.0e-30));

    // Punchthrough: PTL*exp(PTP*log(max(vdsz,1e-30)))*(1+PT2*vdsz)
    const dvth_pt: S = if (p.p_ptl > 0.0)
        vdsz.maxC(1.0e-30).pow(p.p_ptp).scale(p.p_ptl).mul(vdsz.scale(p.p_pt2).addC(1.0))
    else
        S.con(0.0);

    // Total dVth
    const dvth = dvth_sc.add(dvth_lp).add(dvth_w).add(dvth_pt);

    // ========================================================================
    // Poly-Gate Depletion
    // ========================================================================
    const cnst_pgd = p.p_pgd1 * beta_inv;
    // dpg_raw = cnst_pgd*(lexp(vgsz - PGD2) - 1)
    const dpg_raw = lexpS(S, vgsz.addC(-p.p_pgd2)).addC(-1.0).scale(cnst_pgd);
    const dpg = dpg_raw.maxC(0.0).minC(1.0);

    // ========================================================================
    // Effective Gate Voltage Vgp
    // ========================================================================
    const vgp = vgsz.addC(-vfb).add(dvth).sub(dpg);

    // ========================================================================
    // Surface Potential Ps0 (source side) - Newton iteration
    // ========================================================================
    // Analytical initial guess
    // t_x = 1 + 4*(beta*(vgp-vbscl)-1)/(fac1_sq*beta^2)
    const t_x = vgp.sub(vbscl).scale(beta).addC(-1.0).scale(4.0).div(fac1_sq.scale(beta * beta)).addC(1.0);
    // ps0_ini_a = vgp + fac1_sq*beta*0.5*(1 - sqrt(max(t_x,0.001)))
    const ps0_ini_a = vgp.add(fac1_sq.scale(beta * 0.5).mul(t_x.maxC(0.001).sqrt().scale(-1.0).addC(1.0)));

    // Strong inversion upper bound
    // cnst_coxi = fac1_sq*beta
    const cnst_coxi = fac1_sq.scale(beta);
    // ps0_ini_b = log(max(vgp^2/(cnst_coxi+1e-30),1e-30))/(beta + 2/max(vgp,0.01)) + phi_b0
    const ps0_ini_b = vgp.mul(vgp).div(cnst_coxi.addC(1.0e-30)).maxC(1.0e-30).log()
        .div(vgp.maxC(0.01).pow(-1.0).scale(2.0).addC(beta)).addC(phi_b0);

    // Select initial guess (branch on value, per original piecewise physics)
    const ps0_ini: S = if (vgp.val() > phi_b0 + 0.5) ps0_ini_a.min(ps0_ini_b) else ps0_ini_a;

    // Newton iteration for Ps0
    var ps0 = ps0_ini.max(vbscl.addC(0.01));
    {
        var iter: u32 = 0;
        while (iter < 6) : (iter += 1) {
            const chi = ps0.sub(vbscl).scale(beta);
            const chi_safe = chi.maxC(0.01);
            const exp_neg_chi = chi_safe.neg().minC(80.0).exp();
            const exp_ps = ps0.addC(-phi_b0).scale(beta).minC(80.0).exp();

            const fval = chi_safe.add(exp_neg_chi).addC(-1.0).add(exp_ps.scale(cnst1));
            const sqrt_fval = fval.maxC(1.0e-30).sqrt();

            const f_ps = vgp.sub(ps0).sub(fac1.mul(sqrt_fval));
            // df_ps = -1 - fac1*0.5/max(sqrt_fval,1e-30)*(beta - beta*exp_neg_chi + beta*cnst1*exp_ps)
            const dinner = exp_neg_chi.scale(-beta).add(exp_ps.scale(beta * cnst1)).addC(beta);
            const df_ps = fac1.scale(0.5).div(sqrt_fval.maxC(1.0e-30)).mul(dinner).neg().addC(-1.0);

            const dps = f_ps.neg().div(df_ps.minC(-0.1));
            ps0 = ps0.add(dps.minC(0.3).maxC(-0.3));
        }
    }
    ps0 = ps0.max(vbscl.addC(0.001));

    // ========================================================================
    // Surface Potential Psl (drain side) - Newton iteration
    // ========================================================================
    var psl = ps0.add(vdsz.scale(0.5)).max(vbscl.add(vdsz).addC(0.01));
    {
        var iter: u32 = 0;
        while (iter < 6) : (iter += 1) {
            const chi_l = psl.sub(vbscl).sub(vdsz).scale(beta);
            const chi_l_safe = chi_l.maxC(0.01);
            const exp_neg_chi_l = chi_l_safe.neg().minC(80.0).exp();
            const exp_psl = psl.addC(-phi_b0).scale(beta).minC(80.0).exp();

            const fval_l = chi_l_safe.add(exp_neg_chi_l).addC(-1.0).add(exp_psl.scale(cnst1));
            const sqrt_fval_l = fval_l.maxC(1.0e-30).sqrt();

            const f_psl = vgp.sub(psl).sub(fac1.mul(sqrt_fval_l));
            const dinner_l = exp_neg_chi_l.scale(-beta).add(exp_psl.scale(beta * cnst1)).addC(beta);
            const df_psl = fac1.scale(0.5).div(sqrt_fval_l.maxC(1.0e-30)).mul(dinner_l).neg().addC(-1.0);

            const dpsl = f_psl.neg().div(df_psl.minC(-0.1));
            psl = psl.add(dpsl.minC(0.3).maxC(-0.3));
        }
    }
    psl = psl.max(ps0);

    // ========================================================================
    // Drift-Diffusion Current
    // ========================================================================
    const pds = psl.sub(ps0);

    // Bulk charge at source
    const qb0 = ps0.sub(vbscl).maxC(1.0e-30).sqrt().scale(cnst0);

    // Inversion charge density at source
    const xi0 = ps0.sub(vbscl).scale(beta).addC(-1.0).maxC(0.0);
    const exp_bps0 = ps0.addC(-phi_b0).scale(beta).minC(80.0).exp();
    const qn0_arg = xi0.add(xi0.addC(1.0).maxC(0.0).neg().exp()).addC(-1.0).add(exp_bps0.scale(cnst1)).maxC(0.0);
    const qn0 = qn0_arg.addC(1.0e-30).sqrt().sub(xi0.maxC(1.0e-30).sqrt()).maxC(0.0).mul(c_ox).mul(fac1);

    // Gate overdrive (Qn0/Cox)
    const vg_vt = qn0.div(c_ox).maxC(1.0e-20);

    // Fdd drift-diffusion function
    const sqrt_xi0 = xi0.maxC(1.0e-30).sqrt();
    const xi_l = psl.sub(vbscl).scale(beta).addC(-1.0).maxC(0.0);
    const sqrt_xil = xi_l.maxC(1.0e-30).sqrt();

    // fdd = beta*Cox*(vgp + beta_inv - (2*ps0+pds)*0.5) + beta*cnst0*(sqrt_xi0 - sqrt_xil)
    const fdd = c_ox.mul(vgp.addC(beta_inv).sub(ps0.scale(2.0).add(pds).scale(0.5))).scale(beta)
        .add(sqrt_xi0.sub(sqrt_xil).scale(beta * cnst0));
    const idd = pds.mul(fdd.abs());

    // ========================================================================
    // Effective Mobility
    // ========================================================================
    const qbu = qb0.scale(1.0 / (w_eff * l_eff));
    const qiu = qn0.scale(1.0 / (w_eff * l_eff)).maxC(1.0e-30);
    const pdsz_eff = pds.maxC(0.0);
    // e_eff = (NDEP*qbu + NINV*qiu)/EPS_SI / (1 + NINVD*pdsz_eff)
    const e_eff = qbu.scale(p.p_ndep).add(qiu.scale(p.p_ninv)).scale(1.0 / EPS_SI)
        .div(pdsz_eff.scale(p.p_ninvd).addC(1.0));
    const e_eff_cgs = e_eff.scale(1.0e-2).maxC(1.0); // Convert to V/cm

    // Coulomb scattering
    const rns = qiu.scale(1.0e-4 / Q_ELEC).maxC(1.0e-30); // Convert to cm^-2
    const mu_ecb = rns.scale(p.p_muecb1 / 1.0e11).addC(p.p_muecb0);

    // Phonon scattering with temperature dependence (x-independent scalar)
    const mu_eph = p.p_mueph1 * @exp(-p.p_muetmp * @log(temp_ratio));
    // e_eff_ph = exp(MUEPH0*log(max(e_eff_cgs,1)))
    const e_eff_ph = e_eff_cgs.maxC(1.0).log().scale(p.p_mueph0).exp();

    // Surface roughness
    const e_eff_sr = e_eff_cgs.maxC(1.0).log().scale(p.p_muesr0).exp();

    // Matthiessen's rule
    // inv_mu = 1/max(mu_ecb,1e-30) + e_eff_ph/max(mu_eph,1e-30) + e_eff_sr/max(MUESR1,1e-30)
    const inv_mu = mu_ecb.maxC(1.0e-30).pow(-1.0)
        .add(e_eff_ph.scale(1.0 / @max(mu_eph, 1.0e-30)))
        .add(e_eff_sr.scale(1.0 / @max(p.p_muesr1, 1.0e-30)));
    const mu_un = inv_mu.maxC(1.0e-30).pow(-1.0); // cm^2/Vs

    // ========================================================================
    // Velocity Saturation
    // ========================================================================
    const ddlt_val = @min(p.p_ddltmax, @max(1.0 + p.p_ddltslp * l_gate_um + p.p_ddltict, 1.0));
    // vdsat_eff = vg_vt + ddlt_val*beta_inv
    const vdsat_eff = vg_vt.addC(ddlt_val * beta_inv);
    // fmdvds = vdsz / max(vdsz + vdsat_eff - pds, vdsat_eff*0.01)
    const fmdvds = vdsz.div(vdsz.add(vdsat_eff).sub(pds).max(vdsat_eff.scale(0.01)));

    // e_y = max(idd*fmdvds / (max(qn0,1e-30)*beta*l_ch_init), 0)
    const e_y = idd.mul(fmdvds).div(qn0.maxC(1.0e-30).scale(beta * l_ch_init)).maxC(0.0);
    const e_y_cgs = e_y.scale(1.0e-2); // V/cm
    const vmax_t = p.p_vmax * (1.0 + p.p_vtmp * (temp_k - tnom_k));
    const em_ratio = mu_un.mul(e_y_cgs).scale(1.0 / @max(vmax_t, 1.0e-30));

    // BB-dependent velocity saturation
    const em_bb: S = if (p.p_bb >= 1.9 and p.p_bb <= 2.1)
        // BB=2 (NMOS): sqrt(1 + x^2)
        em_ratio.mul(em_ratio).addC(1.0).sqrt()
    else if (p.p_bb >= 0.9 and p.p_bb <= 1.1)
        // BB=1 (PMOS): 1 + x
        em_ratio.addC(1.0)
    else
        // General: (1 + x^BB)^(1/BB)
        em_ratio.maxC(1.0e-30).log().scale(p.p_bb).exp().addC(1.0).maxC(1.0).log().scale(1.0 / p.p_bb).exp();

    const mu = mu_un.div(em_bb.maxC(1.0));

    // ========================================================================
    // Channel Length Modulation (CLM)
    // ========================================================================
    const vds_sat = psl.sub(ps0).maxC(0.001);
    const delta_psi = vdsz.sub(vds_sat).maxC(0.0);

    // CLM depletion length
    const e0 = idd.div(qn0.maxC(1.0e-30).scale(beta * l_eff)).maxC(1.0);
    const t4_clm = p.p_clm2 * Q_ELEC * nsub / EPS_SI;
    // t7_clm = (2*idd/(max(qn0,1e-30)*beta) + 2*t4_clm*delta_psi + e0^2) / (max(l_eff,1e-30)*max(t4_clm,1e-30))
    const t7_clm = idd.scale(2.0).div(qn0.maxC(1.0e-30).scale(beta))
        .add(delta_psi.scale(2.0 * t4_clm))
        .add(e0.mul(e0))
        .scale(1.0 / (@max(l_eff, 1.0e-30) * @max(t4_clm, 1.0e-30)));
    const t8_clm = delta_psi.scale(2.0);
    // delta_l_clm = max((-t7 + sqrt(max(t7^2 + t8*t4,0)))*0.5, 0)
    const delta_l_clm = t7_clm.neg().add(t7_clm.mul(t7_clm).add(t8_clm.scale(t4_clm)).maxC(0.0).sqrt()).scale(0.5).maxC(0.0);

    // CLM modification factor (x-independent)
    const clm_mod = p.p_clm1 + p.p_clm6 * @exp(p.p_clm5 * @log(@max(l_gate_um, 1.0e-30)));
    const l_ch_raw = delta_l_clm.scale(-clm_mod * p.p_clm3).addC(l_eff);
    const l_ch = l_ch_raw.maxC(l_eff * 0.1);

    // ========================================================================
    // Overshoot
    // ========================================================================
    // ov_factor = 1 + VOVER*exp(VOVERP*log(max(vdsz+0.01,1e-30))) + VOVERS*exp(VOVERSP*log(max(vgsz+0.01,1e-30)))
    const ov_factor = vdsz.addC(0.01).maxC(1.0e-30).pow(p.p_voverp).scale(p.p_vover)
        .add(vgsz.addC(0.01).maxC(1.0e-30).pow(p.p_voversp).scale(p.p_vovers))
        .addC(1.0);

    // ========================================================================
    // Channel Current
    // ========================================================================
    // beta_wl = w_eff*beta_inv/l_ch
    const beta_wl = l_ch.pow(-1.0).scale(w_eff * beta_inv);
    const mu_si = mu.scale(1.0e-4); // cm^2/Vs -> m^2/Vs
    const ids0 = beta_wl.mul(idd).mul(mu_si).mul(ov_factor);

    const ids_val = ids0.maxC(0.0);

    // ========================================================================
    // Substrate Current (Impact Ionization)
    // ========================================================================
    const ps0z_sub = ps0.add(vzadd);
    const pslsat_sub = psl.add(vzadd);
    const xsub2 = p.p_sub2 + p.p_sub2l / @max(l_gate, 1.0e-30);
    // psi_subsat_raw = SVDS*vdsz + ps0z_sub - l_gate/(SLG+l_gate)*pslsat_sub
    const psi_subsat_raw = vdsz.scale(p.p_svds).add(ps0z_sub).sub(pslsat_sub.scale(l_gate / (@max(p.p_slg + l_gate, 1.0e-30))));
    const psi_subsat = psi_subsat_raw.maxC(0.01);
    const sub_exp = psi_subsat.pow(-1.0).scale(-xsub2).minC(80.0).exp();
    const isub_val: S = if (model.coisub != 0 and vdsz.val() > 0.01)
        psi_subsat.scale(p.p_sub1).mul(ids_val).mul(sub_exp)
    else
        S.con(0.0);

    // ========================================================================
    // Gate Tunneling Current (branchless, model flag selects via multiply)
    // ========================================================================
    const gt_enable: f64 = if (model.coiigs != 0) 1.0 else 0.0;

    // Channel gate tunneling
    const psdl = psl.sub(ps0);
    // e_tun_num = vgsz - vfb + GLEAK4*(dvth-dpg)*l_eff - psdl*GLEAK3
    const e_tun_num = vgsz.addC(-vfb).add(dvth.sub(dpg).scale(p.p_gleak4 * l_eff)).sub(psdl.scale(p.p_gleak3));
    // e_tun = max(e_tun_num/TOX,1)*(1 + e_y*1e-2/max(GLEAK5,1))
    const e_tun = e_tun_num.scale(1.0 / p.p_tox).maxC(1.0).mul(e_y.scale(1.0e-2 / @max(p.p_gleak5, 1.0)).addC(1.0));
    const eg32 = @exp(1.5 * @log(@max(eg_t, 0.1)));
    const eg12 = @sqrt(@max(eg_t, 0.1));

    const vg_vt_small = vg_vt.maxC(1.0e-20);
    const qiu_gate = qiu.scale(w_eff * l_eff);
    // gate_charge_factor = sqrt(max((qiu_gate + c_ox*vg_vt_small)/max(cnst0,1e-30), 1e-30))
    const gate_charge_factor = qiu_gate.add(c_ox.mul(vg_vt_small)).scale(1.0 / @max(cnst0, 1.0e-30)).maxC(1.0e-30).sqrt();

    // igate = gt_enable*GLEAK1*Q*w*l/eg12*gate_charge_factor*e_tun^2*exp(min(-GLEAK2*eg32/max(e_tun,1),80))
    const igate_val = gate_charge_factor.scale(gt_enable * p.p_gleak1 * Q_ELEC * w_eff * l_eff / eg12)
        .mul(e_tun).mul(e_tun)
        .mul(e_tun.maxC(1.0).pow(-1.0).scale(-p.p_gleak2 * eg32).minC(80.0).exp());

    // S/D direct tunneling
    const vgs_int = vgsz;
    const vgd_int = vgsz.sub(vdsz);

    // igs = gt_enable*GLKSD1/1e6*w*vgs^2/TOX^2*exp(min(TOX*(-GLKSD2*vgs + GLKSD3),80))
    const igs_val = vgs_int.mul(vgs_int).scale(gt_enable * p.p_glksd1 / 1.0e6 * w_eff / (p.p_tox * p.p_tox))
        .mul(vgs_int.scale(-p.p_glksd2).addC(p.p_glksd3).scale(p.p_tox).minC(80.0).exp());
    const igd_val = vgd_int.mul(vgd_int).scale(gt_enable * p.p_glksd1 / 1.0e6 * w_eff / (p.p_tox * p.p_tox))
        .mul(vgd_int.scale(-p.p_glksd2).addC(p.p_glksd3).scale(p.p_tox).minC(80.0).exp());

    // Gate-bulk tunneling
    const e_tun_b = e_tun_num.scale(1.0 / p.p_tox).maxC(1.0);
    const igb_val = e_tun_b.mul(e_tun_b).scale(gt_enable * p.p_glkb1 * w_eff * l_eff)
        .mul(e_tun_b.maxC(1.0).pow(-1.0).scale(-p.p_glkb2).minC(80.0).exp());

    // ========================================================================
    // GIDL/GISL (branchless, model flag selects via multiply)
    // ========================================================================
    const gidl_enable: f64 = if (model.cogidl != 0) 1.0 else 0.0;

    // GIDL (drain side)
    const vdb = x[dp].sub(x[bp]);
    // e_gidl_num = GIDL3*(vdsz+GIDL4) - vgsz + (dvth_sc+dvth_lp)*GIDL5 - GIDL6*qb0/c_ox
    const e_gidl_num = vdsz.addC(p.p_gidl4).scale(p.p_gidl3).sub(vgsz)
        .add(dvth_sc.add(dvth_lp).scale(p.p_gidl5)).sub(qb0.div(c_ox).scale(p.p_gidl6));
    const e_gidl = e_gidl_num.scale(1.0 / p.p_tox).maxC(0.0);
    const eg12_gidl = @sqrt(@max(eg_t, 0.1));
    const eg32_gidl = @exp(1.5 * @log(@max(eg_t, 0.1)));
    const e_gidl_pow = e_gidl.maxC(1.0e-30).pow(p.p_gidl7);
    const vdb3 = vdb.mul(vdb).mul(vdb);
    // igidl = gidl_enable*GIDL1*Q*w/eg12*e_gidl^2*exp(min(-GIDL2*eg32/max(e_gidl_pow,1e-30),80))*vdb3/(vdb3+0.5)
    const igidl = e_gidl.mul(e_gidl).scale(gidl_enable * p.p_gidl1 * Q_ELEC * w_eff / eg12_gidl)
        .mul(e_gidl_pow.maxC(1.0e-30).pow(-1.0).scale(-p.p_gidl2 * eg32_gidl).minC(80.0).exp())
        .mul(vdb3.div(vdb3.addC(0.5)));

    // GISL (source side, symmetric)
    const vsb = x[sp].sub(x[bp]);
    // e_gisl_num = -GIDL3*GIDL4 - vgsz + (dvth_sc+dvth_lp)*GIDL5 - GIDL6*qb0/c_ox
    const e_gisl_num = vgsz.neg().addC(-p.p_gidl3 * p.p_gidl4)
        .add(dvth_sc.add(dvth_lp).scale(p.p_gidl5)).sub(qb0.div(c_ox).scale(p.p_gidl6));
    const e_gisl = e_gisl_num.scale(1.0 / p.p_tox).maxC(0.0);
    const e_gisl_pow = e_gisl.maxC(1.0e-30).pow(p.p_gidl7);
    const vsb3 = vsb.mul(vsb).mul(vsb);
    const igisl = e_gisl.mul(e_gisl).scale(gidl_enable * p.p_gidl1 * Q_ELEC * w_eff / eg12_gidl)
        .mul(e_gisl_pow.maxC(1.0e-30).pow(-1.0).scale(-p.p_gidl2 * eg32_gidl).minC(80.0).exp())
        .mul(vsb3.abs().div(vsb3.abs().addC(0.5)));

    // ========================================================================
    // Junction Diode Currents
    // ========================================================================
    const nj_vt = p.p_nj * beta_inv;
    const njsw_vt = p.p_njsw * beta_inv;

    const is_d = p.is_d;
    const is_s = p.is_s;
    const is_d_bot_t = p.is_d_bottom * p.jct_temp_factor * p.jct_temp_factor2 + 1.0e-30;
    const is_d_sw_t = p.is_d_sw * p.jct_temp_factor * p.jct_temp_factor2;
    const is_s_bot_t = p.is_s_bottom * p.jct_temp_factor * p.jct_temp_factor2 + 1.0e-30;
    const is_s_sw_t = p.is_s_sw * p.jct_temp_factor * p.jct_temp_factor2;

    // Drain junction (V_bd = V_bp - V_dp)
    const vbd = x[bp].sub(x[dp]).scale(type_f);
    const vbd_eff = vbd.minC(p.p_vdiffj);
    const arg_bd_bot = vbd_eff.scale(1.0 / nj_vt).minC(80.0);
    const arg_bd_sw = vbd_eff.scale(1.0 / njsw_vt).minC(80.0);
    var ibd = arg_bd_bot.exp().addC(-1.0).scale(is_d_bot_t).add(arg_bd_sw.exp().addC(-1.0).scale(is_d_sw_t));
    // Linearization above vdiffj (branch on value)
    if (vbd.val() >= p.p_vdiffj) {
        ibd = ibd.add(vbd.addC(-p.p_vdiffj).scale(is_d / nj_vt * @exp(@min(p.p_vdiffj / nj_vt, 80.0))));
    }
    // Reverse bias contribution
    ibd = ibd.add(vbd.scale(-p.p_cvb / nj_vt).minC(80.0).exp().addC(-1.0).scale(p.p_cisb * is_d));
    ibd = ibd.add(vbd.scale(-p.p_cvbk / nj_vt).minC(80.0).exp().addC(-1.0).scale(p.p_cisbk));
    ibd = ibd.add(vbd.scale(p.p_divx * is_d));

    // Source junction (V_bs = V_bp - V_sp)
    const vbs_jct = x[bp].sub(x[sp]).scale(type_f);
    const vbs_jct_eff = vbs_jct.minC(p.p_vdiffj);
    const arg_bs_bot = vbs_jct_eff.scale(1.0 / nj_vt).minC(80.0);
    const arg_bs_sw = vbs_jct_eff.scale(1.0 / njsw_vt).minC(80.0);
    var ibs = arg_bs_bot.exp().addC(-1.0).scale(is_s_bot_t).add(arg_bs_sw.exp().addC(-1.0).scale(is_s_sw_t));
    if (vbs_jct.val() >= p.p_vdiffj) {
        ibs = ibs.add(vbs_jct.addC(-p.p_vdiffj).scale(is_s / nj_vt * @exp(@min(p.p_vdiffj / nj_vt, 80.0))));
    }
    ibs = ibs.add(vbs_jct.scale(-p.p_cvb / nj_vt).minC(80.0).exp().addC(-1.0).scale(p.p_cisb * is_s));
    ibs = ibs.add(vbs_jct.scale(-p.p_cvbk / nj_vt).minC(80.0).exp().addC(-1.0).scale(p.p_cisbk));
    ibs = ibs.add(vbs_jct.scale(p.p_divx * is_s));

    // ========================================================================
    // Series Resistances (external to internal nodes)
    // ========================================================================
    const i_rs = x[s].sub(x[sp]).scale(p.g_rs);
    const i_rd = x[d].sub(x[dp]).scale(p.g_rd);
    const i_rg = x[g].sub(x[gp]).scale(p.g_rg);

    // ========================================================================
    // Body Resistance Network
    // ========================================================================
    const i_rbpb = x[b].sub(x[bp]).scale(p.g_rbpb);
    const i_rbpd = x[bp].sub(x[dp]).scale(p.g_rbpd);
    const i_rbps = x[bp].sub(x[sp]).scale(p.g_rbps);
    const i_rbdb = x[b].sub(x[db]).scale(p.g_rbdb);
    const i_rbsb = x[b].sub(x[sb]).scale(p.g_rbsb);

    // db -> dp, sb -> sp short connections when body net is off
    const i_db_dp = x[db].sub(x[dp]).scale(GSHORT);
    const i_sb_sp = x[sb].sub(x[sp]).scale(GSHORT);

    // ========================================================================
    // Multiplier and Type Factor
    // ========================================================================
    const m_nf = p.m_nf;
    const gmin_val = p.gmin_val;

    // ========================================================================
    // KCL Stamps
    // ========================================================================
    // Intrinsic channel: dp -> sp
    const ids_stamp = ids_val.mul(mode).scale(type_f * m_nf);

    // Substrate current: dp -> bp
    const isub_stamp = isub_val.scale(type_f * m_nf);

    // GIDL: dp -> bp, GISL: sp -> bp
    const igidl_stamp = igidl.scale(type_f * m_nf);
    const igisl_stamp = igisl.scale(type_f * m_nf);

    // Gate tunneling
    const igate_stamp = igate_val.scale(type_f * m_nf);
    const igs_stamp = igs_val.scale(type_f * m_nf);
    const igd_stamp = igd_val.scale(type_f * m_nf);
    const igb_stamp = igb_val.scale(type_f * m_nf);

    // Junction diodes: bp -> dp, bp -> sp
    const ibd_stamp = ibd.scale(type_f * m_nf);
    const ibs_stamp = ibs.scale(type_f * m_nf);

    // GMIN parasitic on intrinsic nodes
    const gmin_dpsp = x[dp].sub(x[sp]).scale(gmin_val);
    const gmin_gpsp = x[gp].sub(x[sp]).scale(gmin_val);
    const gmin_bpsp = x[bp].sub(x[sp]).scale(gmin_val);

    // ========================================================================
    // Assemble Output Residual Vector
    // ========================================================================
    var out: [n_u]S = undefined;

    // External drain
    out[d] = i_rd;
    // External gate
    out[g] = i_rg;
    // External source
    out[s] = i_rs;
    // External bulk (body resistance network hub)
    out[b] = i_rbpb.add(i_rbdb).add(i_rbsb);

    // Internal drain (dp)
    out[dp] = i_rd.neg().add(ids_stamp).add(igidl_stamp).add(isub_stamp).sub(ibd_stamp)
        .add(igd_stamp).add(i_rbpd).add(gmin_dpsp).add(i_db_dp);

    // Internal gate (gp)
    out[gp] = i_rg.neg().add(igs_stamp).add(igd_stamp).add(igb_stamp).add(igate_stamp).add(gmin_gpsp);

    // Internal source (sp)
    out[sp] = i_rs.neg().sub(ids_stamp).add(igisl_stamp).sub(ibs_stamp).add(igs_stamp)
        .sub(gmin_dpsp).sub(gmin_gpsp).sub(gmin_bpsp).add(i_rbps).add(i_sb_sp);

    // Internal bulk (bp)
    out[bp] = i_rbpb.neg().sub(igidl_stamp).sub(isub_stamp).sub(igisl_stamp).add(ibd_stamp)
        .add(ibs_stamp).sub(igb_stamp).sub(i_rbpd).sub(i_rbps).add(gmin_bpsp);

    // Body-drain node (db)
    out[db] = i_rbdb.neg().sub(i_db_dp);
    // Body-source node (sb)
    out[sb] = i_rbsb.neg().sub(i_sb_sp);

    return out;
}

// ============================================================================
// Charge Function (q) -- Intrinsic + Overlap + Junction Depletion + Qy
// ============================================================================

const QParams = struct {
    type_f: f64,
    p_tox: f64,
    p_vfbc: f64,
    p_qme1: f64,
    p_qme2: f64,
    p_qme3: f64,
    c_ox_ov: f64,
    l_gate: f64,
    l_gate_um: f64,
    w_gate_um: f64,
    l_eff: f64,
    w_eff: f64,
    w_eff_cv: f64,
    l_eff_cv: f64,
    beta_inv: f64,
    beta: f64,
    nsub: f64,
    vfb: f64,
    phi_b0: f64,
    cnst0: f64,
    cnst1: f64,
    p_vzadd0: f64,
    p_bs1: f64,
    p_bs2: f64,
    p_parl2: f64,
    p_vbi: f64,
    p_sc1: f64,
    p_sc2: f64,
    p_sc3: f64,
    p_sc4: f64,
    p_wfc: f64,
    p_wvth0: f64,
    p_pgd1: f64,
    p_pgd2: f64,
    p_lover: f64,
    p_ovslp: f64,
    p_ovmag: f64,
    p_cgso: f64,
    p_cgdo: f64,
    p_cgbo: f64,
    p_xqy: f64,
    p_qyrat: f64,
    p_pb: f64,
    p_pbsw: f64,
    p_pbswg: f64,
    p_mj: f64,
    p_mjsw: f64,
    p_mjswg: f64,
    // temperature-adjusted junction caps (x-independent)
    cj_ad: f64,
    cjsw_pd: f64,
    cjswg_wd: f64,
    cj_as: f64,
    cjsw_ps: f64,
    cjswg_ws: f64,
    m_nf: f64,
};

fn prepQ(model: *const Model, instance: *const Instance) QParams {
    const type_f: f64 = @floatFromInt(model.type_);
    const p_tox: f64 = @as(f64, model.tox);
    const p_toxov: f64 = @as(f64, model.toxov);
    const p_xld: f64 = @as(f64, model.xld);
    const p_lover: f64 = @as(f64, model.lover);
    const p_xwd: f64 = @as(f64, model.xwd);
    const p_xl: f64 = @as(f64, model.xl);
    const p_xw: f64 = @as(f64, model.xw);
    const p_ll: f64 = @as(f64, model.ll);
    const p_lld: f64 = @as(f64, model.lld);
    const p_lln: f64 = @as(f64, model.lln);
    const p_wl: f64 = @as(f64, model.wl);
    const p_wld: f64 = @as(f64, model.wld);
    const p_wln: f64 = @as(f64, model.wln);
    const p_tnom: f64 = @as(f64, model.tnom);
    const p_vfbc: f64 = @as(f64, model.vfbc);
    const p_vfbcl: f64 = @as(f64, model.vfbcl);
    const p_vfbclp: f64 = @as(f64, model.vfbclp);
    const p_nsubc: f64 = @as(f64, model.nsubc);
    const p_eg0: f64 = @as(f64, model.eg0);
    const p_bgtmp1: f64 = @as(f64, model.bgtmp1);
    const p_bgtmp2: f64 = @as(f64, model.bgtmp2);

    const inst_l: f64 = @as(f64, instance.l);
    const inst_w: f64 = @as(f64, instance.w);
    const inst_nf: f64 = @as(f64, instance.nf);
    const inst_dtemp: f64 = @as(f64, instance.dtemp);
    const inst_ad: f64 = @as(f64, instance.ad);
    const inst_as: f64 = @as(f64, instance.as_);
    const inst_pd: f64 = @as(f64, instance.pd);
    const inst_ps: f64 = @as(f64, instance.ps);

    // Temperature
    const temp_k = p_tnom + inst_dtemp + 273.15;
    const tnom_k = p_tnom + 273.15;
    const beta_inv = KB_Q * temp_k;
    const beta = 1.0 / beta_inv;
    const eg_t = p_eg0 - temp_k * (p_bgtmp1 + temp_k * p_bgtmp2);
    const eg_tnom = p_eg0 - tnom_k * (p_bgtmp1 + tnom_k * p_bgtmp2);
    const delta_t = temp_k - tnom_k;
    const ni = NI_300K * @exp(0.5 * (eg_tnom / (KB_Q * 300.0) - eg_t / beta_inv));

    // Geometry
    const l_gate = inst_l + p_xl;
    const w_gate = inst_w / inst_nf + p_xw;
    const l_gate_um = l_gate * 1.0e6;
    const w_gate_um = w_gate * 1.0e6;
    const dl = p_xld + p_ll / @exp(p_lln * @log(@max(l_gate + p_lld, 1.0e-30)));
    const dw = p_xwd + p_wl / @exp(p_wln * @log(@max(w_gate + p_wld, 1.0e-30)));
    const l_eff = @max(l_gate - 2.0 * dl, 1.0e-9);
    const w_eff = @max(w_gate - 2.0 * dw, 1.0e-9);
    const w_eff_cv = w_eff;
    const l_eff_cv = l_eff;

    const c_ox_ov = EPS_OX / @max(p_toxov, 1.0e-12);

    const nsubc_cm3 = @max(p_nsubc, 1.0);
    const nsub = nsubc_cm3 * 1.0e6;

    const vfb = p_vfbc * (1.0 + p_vfbcl / @exp(p_vfbclp * @log(@max(l_gate_um, 1.0e-30))));

    const phi_b0 = 2.0 * beta_inv * @log(@max(nsub / ni, 1.0));
    const cnst0 = @sqrt(2.0 * Q_ELEC * nsub * EPS_SI);
    const cnst1 = ni * ni / (nsub * nsub);

    // Junction areas/perimeters
    const ad_eff: f64 = if (inst_ad > 0.0) inst_ad else w_eff * 1.0e-6;
    const as_eff: f64 = if (inst_as > 0.0) inst_as else w_eff * 1.0e-6;
    const pd_eff: f64 = if (inst_pd > 0.0) inst_pd else 2.0 * w_eff;
    const ps_eff: f64 = if (inst_ps > 0.0) inst_ps else 2.0 * w_eff;

    const p_cj: f64 = @as(f64, model.cj);
    const p_cjsw: f64 = @as(f64, model.cjsw);
    const p_cjswg: f64 = @as(f64, model.cjswg);
    const cj_d = p_cj * (1.0 + @as(f64, model.tcjbd) * delta_t);
    const cj_s = p_cj * (1.0 + @as(f64, model.tcjbs) * delta_t);
    const cjsw_d = p_cjsw * (1.0 + @as(f64, model.tcjbdsw) * delta_t);
    const cjsw_s = p_cjsw * (1.0 + @as(f64, model.tcjbssw) * delta_t);
    const cjswg_d = p_cjswg * (1.0 + @as(f64, model.tcjbdswg) * delta_t);
    const cjswg_s = p_cjswg * (1.0 + @as(f64, model.tcjbsswg) * delta_t);

    return .{
        .type_f = type_f,
        .p_tox = p_tox,
        .p_vfbc = p_vfbc,
        .p_qme1 = @as(f64, model.qme1),
        .p_qme2 = @as(f64, model.qme2),
        .p_qme3 = @as(f64, model.qme3),
        .c_ox_ov = c_ox_ov,
        .l_gate = l_gate,
        .l_gate_um = l_gate_um,
        .w_gate_um = w_gate_um,
        .l_eff = l_eff,
        .w_eff = w_eff,
        .w_eff_cv = w_eff_cv,
        .l_eff_cv = l_eff_cv,
        .beta_inv = beta_inv,
        .beta = beta,
        .nsub = nsub,
        .vfb = vfb,
        .phi_b0 = phi_b0,
        .cnst0 = cnst0,
        .cnst1 = cnst1,
        .p_vzadd0 = @as(f64, model.vzadd0),
        .p_bs1 = @as(f64, model.bs1),
        .p_bs2 = @as(f64, model.bs2),
        .p_parl2 = @as(f64, model.parl2),
        .p_vbi = @as(f64, model.vbi),
        .p_sc1 = @as(f64, model.sc1),
        .p_sc2 = @as(f64, model.sc2),
        .p_sc3 = @as(f64, model.sc3),
        .p_sc4 = @as(f64, model.sc4),
        .p_wfc = @as(f64, model.wfc),
        .p_wvth0 = @as(f64, model.wvth0),
        .p_pgd1 = @as(f64, model.pgd1),
        .p_pgd2 = @as(f64, model.pgd2),
        .p_lover = p_lover,
        .p_ovslp = @as(f64, model.ovslp),
        .p_ovmag = @as(f64, model.ovmag),
        .p_cgso = @as(f64, model.cgso),
        .p_cgdo = @as(f64, model.cgdo),
        .p_cgbo = @as(f64, model.cgbo),
        .p_xqy = @as(f64, model.xqy),
        .p_qyrat = @as(f64, model.qyrat),
        .p_pb = @as(f64, model.pb),
        .p_pbsw = @as(f64, model.pbsw),
        .p_pbswg = @as(f64, model.pbswg),
        .p_mj = @as(f64, model.mj),
        .p_mjsw = @as(f64, model.mjsw),
        .p_mjswg = @as(f64, model.mjswg),
        .cj_ad = cj_d * ad_eff,
        .cjsw_pd = cjsw_d * pd_eff,
        .cjswg_wd = cjswg_d * w_eff,
        .cj_as = cj_s * as_eff,
        .cjsw_ps = cjsw_s * ps_eff,
        .cjswg_ws = cjswg_s * w_eff,
        .m_nf = inst_nf,
    };
}

pub const PrepCache = struct { dc: IParams, q: QParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{
        .dc = prepI(model, instance),
        .q = prepQ(model, instance),
    };
}

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = instance;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.dp);
    const gp = @intFromEnum(U.gp);
    const sp = @intFromEnum(U.sp);
    const bp = @intFromEnum(U.bp);
    const db = @intFromEnum(U.db);
    const sb = @intFromEnum(U.sb);

    const p = &pc.q;
    const type_f = p.type_f;
    const beta = p.beta;
    const beta_inv = p.beta_inv;
    const phi_b0 = p.phi_b0;
    const cnst0 = p.cnst0;
    const cnst1 = p.cnst1;
    const nsub = p.nsub;
    const w_eff_cv = p.w_eff_cv;
    const l_eff_cv = p.l_eff_cv;
    const l_gate = p.l_gate;
    const w_gate_um = p.w_gate_um;
    const vfb = p.vfb;

    // Oxide capacitance (with QME1 quantum effect term) -- x-dependent
    const vgs_for_qme = x[gp].sub(x[sp]).scale(type_f);
    const qme1_denom = vgs_for_qme.addC(-p.p_vfbc - p.p_qme2).abs().maxC(0.01);
    const dtox_qme = S.con(p.p_qme1).div(qme1_denom).addC(p.p_qme3);
    const t_oxe = dtox_qme.addC(p.p_tox).maxC(1.0e-12);
    const c_ox = t_oxe.pow(-1.0).scale(EPS_OX);
    const c_ox_inv = t_oxe.scale(1.0 / EPS_OX);
    const fac1 = c_ox.pow(-1.0).scale(cnst0);
    const fac1_sq = fac1.mul(fac1);

    // Terminal voltages
    const vgs_raw = x[gp].sub(x[sp]).scale(type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(type_f);
    const vbs_raw = x[bp].sub(x[sp]).scale(type_f);

    const vds_abs = vds_raw.abs();
    const vds_neg = vds_raw.minC(0.0);
    const vgs = vgs_raw.sub(vds_neg);
    const vds = vds_abs;
    const vbs = vbs_raw.sub(vds_neg);
    const mode = vds_raw.div(vds_abs.addC(1.0e-30));

    // Symmetry (with body coefficient modification matching eval())
    const dvbs_coeff = S.con(p.p_bs1).div(vbs.scale(-1.0 / @max(p.p_bs2, 0.01)).exp().addC(1.0)).addC(1.0);
    const vzadd = symAddS(S, vds.scale(0.5).mul(dvbs_coeff), p.p_vzadd0);
    const vbsz = vbs.add(vzadd);
    const vdsz = vds.add(vzadd.scale(2.0));
    const vgsz = vgs.add(vzadd);
    const vbscl = vbsz.minC(phi_b0 - 0.1);

    // Short-channel effect
    const phi_bsum = vbscl.scale(-1.0).addC(phi_b0).maxC(0.01);
    const w_dpl = phi_bsum.scale(2.0 * EPS_SI / (Q_ELEC * nsub)).sqrt();
    const l_gate_eff = @max(l_gate - p.p_parl2, 1.0e-9);
    const dvth0 = w_dpl.mul(phi_bsum.sqrt()).scale(2.0 * (p.p_vbi - phi_b0) * EPS_SI / (l_gate_eff * l_gate_eff)).div(c_ox);
    const sce_inner = phi_bsum.scale(p.p_sc3 / l_gate)
        .add(vdsz.mul(phi_bsum.scale(p.p_sc4).addC(1.0)).scale(p.p_sc2))
        .addC(p.p_sc1);
    const dvth_sc = dvth0.mul(sce_inner);
    const qb0_for_wfc = vbscl.scale(-1.0).addC(phi_b0).maxC(1.0e-30).sqrt().scale(cnst0);
    const dvth_w = qb0_for_wfc.mul(c_ox_inv.sub(c_ox.addC(p.p_wfc / @max(w_eff_cv, 1.0e-30)).pow(-1.0)))
        .addC(p.p_wvth0 / @max(w_gate_um, 1.0e-30));
    const dvth = dvth_sc.add(dvth_w);

    // Poly-gate depletion
    const cnst_pgd = p.p_pgd1 * beta_inv;
    const dpg = lexpS(S, vgsz.addC(-p.p_pgd2)).addC(-1.0).scale(cnst_pgd).maxC(0.0).minC(1.0);

    // Effective gate voltage
    const vgp = vgsz.addC(-vfb).add(dvth).sub(dpg);

    // ========================================================================
    // Surface Potential Ps0 (source side)
    // ========================================================================
    const t_x = vgp.sub(vbscl).scale(beta).addC(-1.0).scale(4.0).div(fac1_sq.scale(beta * beta)).addC(1.0);
    const ps0_ini = vgp.add(fac1_sq.scale(beta * 0.5).mul(t_x.maxC(0.001).sqrt().scale(-1.0).addC(1.0)));
    var ps0 = ps0_ini.max(vbscl.addC(0.01));
    {
        var iter: u32 = 0;
        while (iter < 6) : (iter += 1) {
            const chi = ps0.sub(vbscl).scale(beta);
            const chi_safe = chi.maxC(0.01);
            const exp_neg_chi = chi_safe.neg().minC(80.0).exp();
            const exp_ps = ps0.addC(-phi_b0).scale(beta).minC(80.0).exp();
            const fval = chi_safe.add(exp_neg_chi).addC(-1.0).add(exp_ps.scale(cnst1));
            const sqrt_fval = fval.maxC(1.0e-30).sqrt();
            const f_ps = vgp.sub(ps0).sub(fac1.mul(sqrt_fval));
            const dinner = exp_neg_chi.scale(-beta).add(exp_ps.scale(beta * cnst1)).addC(beta);
            const df_ps = fac1.scale(0.5).div(sqrt_fval.maxC(1.0e-30)).mul(dinner).neg().addC(-1.0);
            const dps = f_ps.neg().div(df_ps.minC(-0.1));
            ps0 = ps0.add(dps.minC(0.3).maxC(-0.3));
        }
    }
    ps0 = ps0.max(vbscl.addC(0.001));

    // Surface Potential Psl (drain side)
    var psl = ps0.add(vdsz.scale(0.5)).max(vbscl.add(vdsz).addC(0.01));
    {
        var iter: u32 = 0;
        while (iter < 6) : (iter += 1) {
            const chi_l = psl.sub(vbscl).sub(vdsz).scale(beta);
            const chi_l_safe = chi_l.maxC(0.01);
            const exp_neg_chi_l = chi_l_safe.neg().minC(80.0).exp();
            const exp_psl = psl.addC(-phi_b0).scale(beta).minC(80.0).exp();
            const fval_l = chi_l_safe.add(exp_neg_chi_l).addC(-1.0).add(exp_psl.scale(cnst1));
            const sqrt_fval_l = fval_l.maxC(1.0e-30).sqrt();
            const f_psl = vgp.sub(psl).sub(fac1.mul(sqrt_fval_l));
            const dinner_l = exp_neg_chi_l.scale(-beta).add(exp_psl.scale(beta * cnst1)).addC(beta);
            const df_psl = fac1.scale(0.5).div(sqrt_fval_l.maxC(1.0e-30)).mul(dinner_l).neg().addC(-1.0);
            const dpsl = f_psl.neg().div(df_psl.minC(-0.1));
            psl = psl.add(dpsl.minC(0.3).maxC(-0.3));
        }
    }
    psl = psl.max(ps0);

    // ========================================================================
    // Charge Partitioning
    // ========================================================================
    const pds = psl.sub(ps0);

    // Gate overdrive
    const xi0 = ps0.sub(vbscl).scale(beta).addC(-1.0).maxC(0.0);
    const exp_bps0 = ps0.addC(-phi_b0).scale(beta).minC(80.0).exp();
    const qn0_arg = xi0.add(xi0.addC(1.0).maxC(0.0).neg().exp()).addC(-1.0).add(exp_bps0.scale(cnst1)).maxC(0.0);
    const qn0 = qn0_arg.addC(1.0e-30).sqrt().sub(xi0.maxC(1.0e-30).sqrt()).maxC(0.0).mul(c_ox).mul(fac1);
    const vg_vt = qn0.div(c_ox).maxC(1.0e-20);

    // alpha partitioning factor
    const delta_part = 0.01;
    // alpha = max(1 - (1+delta_part)*pds/max(vg_vt,1e-30), 0.001)
    const alpha = pds.scale(1.0 + delta_part).div(vg_vt.maxC(1.0e-30)).neg().addC(1.0).maxC(0.001);

    // Inversion charge per unit area
    // qiu = 2/3*vg_vt*(1+alpha+alpha^2)/(1+alpha)*c_ox
    const alpha2 = alpha.mul(alpha);
    const qiu = vg_vt.scale(2.0 / 3.0).mul(alpha.add(alpha2).addC(1.0)).div(alpha.addC(1.0)).mul(c_ox);

    // Bulk charge per unit area
    // qbu = cnst0*sqrt(max(ps0-vbscl,1e-30))/max(w_eff_cv*l_eff_cv,1e-30)
    const qbu = ps0.sub(vbscl).maxC(1.0e-30).sqrt().scale(cnst0 / @max(w_eff_cv * l_eff_cv, 1.0e-30));

    // Drain charge ratio
    // qdrat = 0.6 - 0.4*(0.5+alpha)/((1+alpha)*(1+alpha+alpha^2))
    const qdrat = alpha.addC(0.5).scale(0.4).div(alpha.addC(1.0).mul(alpha.add(alpha2).addC(1.0))).neg().addC(0.6);

    // Integrated charges
    const qi_total = qiu.scale(-w_eff_cv * l_eff_cv);
    const qb_total = qbu.scale(-w_eff_cv * l_eff_cv);
    const qd_intr = qi_total.mul(qdrat);
    const qs_intr = qi_total.sub(qd_intr);
    const qg_intr = qb_total.add(qi_total).neg();

    // ========================================================================
    // Overlap Charge
    // ========================================================================
    const l_ov = p.p_lover;

    // Raw terminal voltages for overlap
    const vgs_ov = x[gp].sub(x[sp]);
    const vgd_ov = x[gp].sub(x[dp]);
    const vgb_ov = x[gp].sub(x[bp]);

    var q_gos: S = S.con(0.0);
    var q_god: S = S.con(0.0);
    var q_gob: S = S.con(0.0);

    if (model.coovlp != 0) {
        // Source overlap
        // q_gos = vgs_ov*c_ox_ov*w*l_ov - OVSLP*c_ox_ov*w*(OVMAG+vgs_ov)*max(1.2-ps0,0)
        q_gos = vgs_ov.scale(p.c_ox_ov * w_eff_cv * l_ov)
            .sub(vgs_ov.addC(p.p_ovmag).scale(p.p_ovslp * p.c_ox_ov * w_eff_cv).mul(ps0.neg().addC(1.2).maxC(0.0)));
        q_gos = q_gos.add(vgs_ov.scale(p.p_cgso * w_eff_cv));

        // Drain overlap
        q_god = vgd_ov.scale(p.c_ox_ov * w_eff_cv * l_ov)
            .sub(vgd_ov.addC(p.p_ovmag).scale(p.p_ovslp * p.c_ox_ov * w_eff_cv).mul(psl.neg().addC(1.2).maxC(0.0)));
        q_god = q_god.add(vgd_ov.scale(p.p_cgdo * w_eff_cv));

        // Bulk overlap
        q_gob = vgb_ov.scale(p.p_cgbo * l_eff_cv);
    }

    // ========================================================================
    // Lateral-Field Capacitance (Qy)
    // ========================================================================
    var q_yd: S = S.con(0.0);
    var q_ys: S = S.con(0.0);

    if (model.coqy != 0) {
        // fmdvds = min(vdsz/max(psl-ps0+0.01,0.01), 1)
        const fmdvds = vdsz.div(psl.sub(ps0).addC(0.01).maxC(0.01)).minC(1.0);
        // qy = -(ps0 + vdsz - psl)*EPS_SI*w*1.3*w_dpl/max(XQY,1e-30)*fmdvds
        const qy = ps0.add(vdsz).sub(psl).neg().scale(EPS_SI * w_eff_cv * 1.3).mul(w_dpl).scale(1.0 / @max(p.p_xqy, 1.0e-30)).mul(fmdvds);
        q_yd = qy.scale(p.p_qyrat);
        q_ys = qy.scale(1.0 - p.p_qyrat);
    }

    // ========================================================================
    // Junction Depletion Charges
    // ========================================================================
    const one_minus_mj = 1.0 - p.p_mj;
    const one_minus_mjsw = 1.0 - p.p_mjsw;
    const one_minus_mjswg = 1.0 - p.p_mjswg;

    // Drain junction voltage (Vbp - Vdp, typed)
    const vbd_jct = x[bp].sub(x[dp]).scale(type_f);
    const qbd_bottom = junctionChargeS(S, vbd_jct, p.cj_ad, p.p_pb, p.p_mj, one_minus_mj);
    const qbd_sw = junctionChargeS(S, vbd_jct, p.cjsw_pd, p.p_pbsw, p.p_mjsw, one_minus_mjsw);
    const qbd_swg = junctionChargeS(S, vbd_jct, p.cjswg_wd, p.p_pbswg, p.p_mjswg, one_minus_mjswg);
    const qbd_jct = qbd_bottom.add(qbd_sw).add(qbd_swg);

    // Source junction voltage
    const vbs_jct = x[bp].sub(x[sp]).scale(type_f);
    const qbs_bottom = junctionChargeS(S, vbs_jct, p.cj_as, p.p_pb, p.p_mj, one_minus_mj);
    const qbs_sw = junctionChargeS(S, vbs_jct, p.cjsw_ps, p.p_pbsw, p.p_mjsw, one_minus_mjsw);
    const qbs_swg = junctionChargeS(S, vbs_jct, p.cjswg_ws, p.p_pbswg, p.p_mjswg, one_minus_mjswg);
    const qbs_jct = qbs_bottom.add(qbs_sw).add(qbs_swg);

    // ========================================================================
    // Mode-aware charge mapping (branch on value, per original)
    // ========================================================================
    const qd_mapped: S = if (mode.val() >= 0.0) qd_intr else qs_intr;
    const qs_mapped: S = if (mode.val() >= 0.0) qs_intr else qd_intr;

    // ========================================================================
    // Total Terminal Charges
    // ========================================================================
    const m_nf = p.m_nf;

    // Gate charge (intrinsic + overlap)
    const q_g = qg_intr.add(q_gos).add(q_god).add(q_gob).scale(m_nf);

    // Drain charge (intrinsic + overlap + junction + Qy)
    const q_d = qd_mapped.sub(q_god).sub(qbd_jct).add(q_yd).scale(m_nf);

    // Bulk charge (intrinsic + overlap + junction)
    const q_b = qb_total.sub(q_gob).add(qbd_jct).add(qbs_jct).scale(m_nf);

    // Source charge (conservation)
    const q_s = qs_mapped.sub(q_gos).sub(qbs_jct).add(q_ys).scale(m_nf);

    // ========================================================================
    // Assemble Output Charge Vector
    // ========================================================================
    var out: [n_u]S = undefined;

    // External nodes get zero charge (resistances are purely resistive)
    out[d] = S.con(0.0);
    out[g] = S.con(0.0);
    out[s] = S.con(0.0);
    out[b] = S.con(0.0);

    // Internal intrinsic nodes get charges
    out[dp] = q_d;
    out[gp] = q_g;
    out[sp] = q_s;
    out[bp] = q_b;

    // Body resistance nodes have no charge
    out[db] = S.con(0.0);
    out[sb] = S.con(0.0);

    return out;
}

/// Junction depletion charge helper (value-form, two regions).
/// cz, phi, mj, one_minus_mj are x-independent constants; v is x-dependent.
inline fn junctionChargeS(comptime S: type, v: S, cz: f64, phi: f64, mj: f64, one_minus_mj: f64) S {
    if (cz == 0.0) return S.con(0.0);

    // Reverse bias (V < 0): power-law
    // ratio = max(1 - v/phi, 1e-30)
    const ratio = v.scale(-1.0 / phi).addC(1.0).maxC(1.0e-30);
    // q_rev = phi*cz/max(one_minus_mj,0.01)*(1 - exp(one_minus_mj*log(ratio)))
    const q_rev = ratio.log().scale(one_minus_mj).exp().neg().addC(1.0).scale(phi * cz / @max(one_minus_mj, 0.01));

    // Forward bias (V >= 0): quadratic extension
    // q_fwd = v*cz + v^2*0.5*cz*mj/phi
    const q_fwd = v.scale(cz).add(v.mul(v).scale(0.5 * cz * mj / phi));

    return if (v.val() < 0.0) q_rev else q_fwd;
}

// ============================================================================
// Voltage Limiting (DEVfetlim + DEVlimvds + DEVpnjlim)
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const gp = @intFromEnum(U.gp);
    const dp = @intFromEnum(U.dp);
    const sp = @intFromEnum(U.sp);
    const bp = @intFromEnum(U.bp);

    const type_f: f64 = @floatFromInt(model.type_);
    const p_vfbc: f64 = @as(f64, model.vfbc);
    const p_js0: f64 = @as(f64, model.js0);
    const p_tnom: f64 = @as(f64, model.tnom);
    const inst_dtemp: f64 = @as(f64, instance.dtemp);
    const inst_w: f64 = @as(f64, instance.w);

    const temp_k = p_tnom + inst_dtemp + 273.15;
    const vt: f64 = KB_Q * temp_k;

    // Critical voltage for pnjlim
    const is_jct = p_js0 * inst_w * 1.0e-6 + 1.0e-14;
    const v_crit = vt * @log(vt / (@sqrt(2.0) * is_jct));

    var result = x_new;

    // ========================================================================
    // DEVfetlim -- Gate-Source Voltage Limiting (on intrinsic nodes)
    // ========================================================================
    {
        const vgs_new = (x_new[gp] - x_new[sp]) * type_f;
        const vgs_old = (x_old[gp] - x_old[sp]) * type_f;

        // Estimate Vth from Vfbc
        const vth_est = -p_vfbc;
        const vtox = vth_est + 3.5;
        const vtsthi = @abs(2.0 * (vgs_old - vth_est)) + 2.0;
        const vtstlo = vtsthi / 2.0 + 2.0;
        const delta_v = vgs_new - vgs_old;

        var vgs_lim = vgs_new;

        if (vgs_old >= vth_est) {
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
            if (delta_v > 0.0 and vgs_new > vth_est + 0.5) {
                vgs_lim = vth_est + 0.5;
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
        const vds_new = (result[dp] - result[sp]) * type_f;
        const vds_old = (x_old[dp] - x_old[sp]) * type_f;

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
        result[dp] += delta_ds;
    }

    // ========================================================================
    // DEVpnjlim -- Bulk-Source Junction Voltage Limiting
    // ========================================================================
    {
        const vbs_new = (result[bp] - result[sp]) * type_f;
        const vbs_old = (x_old[bp] - x_old[sp]) * type_f;

        var vbs_limited = vbs_new;
        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * (2.0 + @log(@max(arg - 2.0, 1.0e-30)));
                } else {
                    vbs_limited = vbs_old - vt * (2.0 + @log(@max(2.0 - arg, 1.0e-30)));
                }
            } else {
                vbs_limited = vt * @log(@max(vbs_new / vt, 1.0e-30));
            }
        }

        const delta_bs = (vbs_limited - vbs_new) * type_f;
        result[bp] += delta_bs;
    }

    // ========================================================================
    // DEVpnjlim -- Bulk-Drain Junction Voltage Limiting
    // ========================================================================
    {
        const vbd_new = (result[bp] - result[dp]) * type_f;
        const vbd_old = (x_old[bp] - x_old[dp]) * type_f;

        var vbd_limited = vbd_new;
        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * (2.0 + @log(@max(arg - 2.0, 1.0e-30)));
                } else {
                    vbd_limited = vbd_old - vt * (2.0 + @log(@max(2.0 - arg, 1.0e-30)));
                }
            } else {
                vbd_limited = vt * @log(@max(vbd_new / vt, 1.0e-30));
            }
        }

        const delta_bd = (vbd_limited - vbd_new) * type_f;
        result[dp] -= delta_bd;
    }

    // Pass through external and body resistance nodes unchanged
    // (they are connected by short/resistance and do not need limiting)
    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;

    // Boost junction saturation current at lambda < 1
    const js0_orig: f64 = @as(f64, model.js0);
    const js0_stepped = js0_orig + gmin_step * (1.0 - lambda);
    m.js0 = @floatCast(js0_stepped);

    // Boost GMIN at lambda < 1
    const gmin_orig: f64 = @as(f64, model.gmin);
    const gmin_stepped = gmin_orig + 1.0e-3 * (1.0 - lambda);
    m.gmin = @floatCast(gmin_stepped);

    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn idx(u: U) usize {
    return @intFromEnum(u);
}

test "hisim2: series drain resistance stamps Ohm's law" {
    // With RD set, the d->dp branch is a plain resistor: I = (Vd - Vdp)/rd_val.
    // rd_val = RD/max(w_eff,1e-30) + RSH*NRD. Use RD only so g_rd = 1/RD.
    // Model RD=100, default L=W=5u. w_eff ~ 5u so rd_val = 100/5e-6 = 2e7 ohm...
    // To keep this simple and exact, drive only external drain vs internal dp
    // and set NRD so the term is a clean resistor. Use RSH path: RD=0, RSH=10,
    // NRD=1 -> rd_val = 10 ohm -> g_rd = 0.1 S.
    const model: Model = .{ .rsh = 10 };
    var inst: Instance = .{ .nrd = 1 };
    var xv = [_]f64{0} ** n_u;
    xv[idx(.drain)] = 1.0; // Vd = 1
    xv[idx(.dp)] = 0.0; // Vdp = 0
    const out = contract.evalValues(Self, xv, &model, &inst, 0);
    // I(drain) = (1 - 0)*0.1 = 0.1 A
    try testing.expectApproxEqAbs(@as(f64, 0.1), out[idx(.drain)], 1e-9);
    // And the dp node receives -i_rd = -0.1 plus intrinsic terms; here
    // Vdp=Vsp=Vgp=Vbp=0 so all intrinsic currents are ~0 (subthreshold, Vgs=0).
}

test "hisim2: zero bias -> negligible channel current, charge sane" {
    // All terminals grounded: Vgs=Vds=Vbs=0. Channel is deep subthreshold,
    // so external terminal currents should all be ~0 (only GMIN/leak, tiny).
    const model: Model = .{};
    var inst: Instance = .{};
    const xv = [_]f64{0} ** n_u;
    const out = contract.evalValues(Self, xv, &model, &inst, 0);
    // Every KCL residual at zero bias must be ~0 (all voltage diffs are 0).
    inline for (0..n_u) |u| {
        try testing.expectApproxEqAbs(@as(f64, 0.0), out[u], 1e-6);
    }

    // Charge at zero bias: junction charges are ~0 (V=0 -> q_fwd = 0),
    // intrinsic charges are finite but bounded. Just ensure it evaluates and
    // external/body-resistance nodes carry exactly zero charge.
    const qout = contract.qValues(Self, xv, &model, &inst, 0);
    try testing.expectEqual(@as(f64, 0.0), qout[idx(.drain)]);
    try testing.expectEqual(@as(f64, 0.0), qout[idx(.gate)]);
    try testing.expectEqual(@as(f64, 0.0), qout[idx(.source)]);
    try testing.expectEqual(@as(f64, 0.0), qout[idx(.bulk)]);
    try testing.expectEqual(@as(f64, 0.0), qout[idx(.db)]);
    try testing.expectEqual(@as(f64, 0.0), qout[idx(.sb)]);
}

test "hisim2: forward bulk-source junction residual (exact, from old formula)" {
    // Forward bias the bp-sp diode: Vbp - Vsp = 0.7 V (NMOS, type_f=+1),
    // all other nodes grounded. This model LINEARIZES the junction above
    // VDIFFJ = 0.6 mV, so the current is NOT the raw exp(V/Vt) -- it is the
    // exp evaluated at vdiffj plus a linear extension. Compute by hand from
    // the OLD i() formula and assert the exact residual on sp and bp.
    //
    //   nj_vt   = NJ*KB_Q*(TNOM+273.15)         = 1 * 8.6174e-5 * 300.15
    //           = 0.025863630632879785
    //   as_eff  = w_eff*1e-6 = 5e-6*1e-6         = 5e-12
    //   is_s_bottom = JS0*as_eff = 0.5e-6*5e-12  = 2.5e-18
    //   is_s = is_s_bot_t = 2.5e-18 (+1e-30); jct temp factors = 1 (T=Tnom)
    //   vbs_eff = min(0.7, 6e-4) = 6e-4
    //   ibs = is_s_bot_t*(exp(vbs_eff/nj_vt) - 1)
    //         + is_s/nj_vt*(0.7 - 6e-4)*exp(6e-4/nj_vt)    [linearization]
    //       = 6.924992354499952e-17
    //   gmin_bpsp = 0.7 * GMIN_DEFAULT(1e-12) = 7e-13
    //   sp residual = -ibs - gmin_bpsp = -7.000692499235449e-13
    //   bp residual = -i_rbpb + ibs + gmin_bpsp
    //     i_rbpb = (Vb - Vbp)*GSHORT = (0 - 0.7)*1e12 = -7e11
    //     => bp = 7e11 + 6.92e-17 + 7e-13 = 7e11 (GSHORT dominates)
    const model: Model = .{};
    var inst: Instance = .{};
    var xv = [_]f64{0} ** n_u;
    xv[idx(.bp)] = 0.7;
    const out = contract.evalValues(Self, xv, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, -7.000692499235449e-13), out[idx(.sp)], 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 7.0e11), out[idx(.bp)], 1e3);
}
