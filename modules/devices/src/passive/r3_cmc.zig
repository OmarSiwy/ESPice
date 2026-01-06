const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Terminal & internal-node enum
// ============================================================================
// External ports: n1 (terminal 1), nc (control/substrate), n2 (terminal 2)
// Internal nodes: i1 (between n1 and body), i2 (between body and n2),
//                 dt (self-heating temperature rise node)
pub const U = enum(u8) { n1, nc, n2, int1, int2, dt };
pub const num_ports: usize = 3;

// dt is a thermal node carrying temperature (flow-like), not a voltage
pub const u_kinds = [n_u]contract.UnknownKind{
    .voltage, // n1
    .voltage, // nc
    .voltage, // n2
    .voltage, // i1
    .voltage, // i2
    .flow, // dt (self-heating temperature rise)
};

// ============================================================================
// Physical constants
// ============================================================================
const T0: f64 = 273.15;
const KB: f64 = 1.3806505e-23;
const QQ: f64 = 1.6021918e-19;
const GMIN: f64 = 1.0e-12;
const GSHORT: f64 = 1.0e12;

// ============================================================================
// Model Parameters
// ============================================================================
pub const Model = struct {
    // --- Version / identification ---
    version: i32 = 1,
    subversion: i32 = 1,
    revision: i32 = 2,
    level: i32 = 1003,
    type_: i32 = -1, // -1 = n-body, +1 = p-body

    // --- Special model parameters ---
    scale: f32 = 1.0,
    shrink: f32 = 0.0, // percentage
    tmin: f32 = -100.0,
    tmax: f32 = 500.0,
    rthresh: f32 = 0.001,
    imax: f32 = 1.0,
    tnom: f32 = 27.0,
    lmin: f32 = 0.0,
    lmax: f32 = 9.9e9,
    wmin: f32 = 0.0,
    wmax: f32 = 9.9e9,
    jmax: f32 = 100.0,
    vmax: f32 = 9.9e9,
    tminclip: f32 = -100.0,
    tmaxclip: f32 = 500.0,

    // --- Geometry parameters (resistance body) ---
    rsh: f32 = 100.0, // Ohm/sq
    xw: f32 = 0.0, // um
    nwxw: f32 = 0.0, // um^2
    wexw: f32 = 0.0, // um
    fdrw: f32 = 1.0, // um
    fdxwinf: f32 = 0.0, // um
    xl: f32 = 0.0, // um
    xlw: f32 = 0.0, // dimensionless
    dxlsat: f32 = 0.0, // um

    // --- Depletion pinching parameters ---
    nst: f32 = 1.0,
    dfinf: f32 = 0.01, // 1/V^0.5
    dfl: f32 = 0.0,
    dfw: f32 = 0.0,
    dfwl: f32 = 0.0,
    sw_dfgeo: i32 = 1,
    dp: f32 = 2.0, // V (dpinf)
    dpl: f32 = 0.0,
    dple: f32 = 2.0,
    dpw: f32 = 0.0,
    dpwe: f32 = 0.5,
    dpwl: f32 = 0.0,

    // --- Velocity saturation parameters ---
    ecrit: f32 = 4.0, // V/um
    ecorn: f32 = 0.4, // V/um
    sw_vsatt: i32 = 0,
    xvsat: f32 = 0.0,
    du: f32 = 0.02,

    // --- Saturation smoothing parameters ---
    ats: f32 = 0.0, // V (atsinf)
    atsl: f32 = 0.0, // V*um

    // --- Pinch-off parameters ---
    sw_accpo: i32 = 0,
    grpo: f32 = 1e-12,

    // --- Contact resistance parameters ---
    rc: f32 = 0.0, // Ohm
    rcw: f32 = 0.0, // Ohm*um

    // --- Parasitic diode parameters ---
    fc: f32 = 0.9,
    isa: f32 = 0.0, // A/um^2
    na: f32 = 1.0,
    ca: f32 = 0.0, // F/um^2
    cja: f32 = 0.0, // F/um^2
    pa: f32 = 0.75, // V
    ma: f32 = 0.33,
    aja: f32 = -0.5, // V
    isp: f32 = 0.0, // A/um
    np: f32 = 1.0,
    cp: f32 = 0.0, // F/um
    cjp: f32 = 0.0, // F/um
    pp: f32 = 0.75, // V
    mp: f32 = 0.33,
    ajp: f32 = -0.5, // V
    vbv: f32 = 0.0, // V
    ibv: f32 = 1e-6, // A
    nbv: f32 = 1.0,

    // --- Flicker noise parameters ---
    kfn: f32 = 0.0,
    afn: f32 = 2.0,
    bfn: f32 = 1.0,
    sw_fngeo: i32 = 0,

    // --- Temperature coefficient parameters ---
    ea: f32 = 1.12, // V
    xis: f32 = 3.0,
    tc1: f32 = 0.0, // 1/K
    tc2: f32 = 0.0, // 1/K^2
    tc1l: f32 = 0.0,
    tc2l: f32 = 0.0,
    tc1w: f32 = 0.0,
    tc2w: f32 = 0.0,
    tc1wl: f32 = 0.0,
    tc2wl: f32 = 0.0,
    tc1rc: f32 = 0.0,
    tc2rc: f32 = 0.0,
    tc1dp: f32 = 0.0,
    tc2dp: f32 = 0.0,
    tc1kfn: f32 = 0.0,
    tc1vbv: f32 = 0.0,
    tc2vbv: f32 = 0.0,
    tc1nbv: f32 = 0.0,

    // --- Thermal network parameters ---
    tegth: f32 = 0.0,
    gth0: f32 = 1e6,
    gthp: f32 = 0.0,
    gtha: f32 = 0.0,
    gthc: f32 = 0.0,
    cth0: f32 = 0.0,
    cthp: f32 = 0.0,
    ctha: f32 = 0.0,
    cthc: f32 = 0.0,

    // --- Statistical variation parameters ---
    nsig_rsh: f32 = 0.0,
    nsig_w: f32 = 0.0,
    nsig_l: f32 = 0.0,
    sig_rsh: f32 = 0.0, // %
    sig_w: f32 = 0.0, // um
    sig_l: f32 = 0.0, // um
    smm_rsh: f32 = 0.0, // %*um
    smm_w: f32 = 0.0, // um^1.5
    smm_l: f32 = 0.0, // um^1.5
    sw_mmgeo: i32 = 0,
};

// ============================================================================
// Instance Parameters
// ============================================================================
pub const Instance = struct {
    w: f32 = 1e-6, // m, design width
    l: f32 = 1e-6, // m, design length
    wd: f32 = 0.0, // m, dogbone width
    a1: f32 = 0.0, // m^2, area of port n1 partition
    p1: f32 = 0.0, // m, perimeter of port n1 partition
    c1: f32 = 0, // number of contacts at n1
    a2: f32 = 0.0, // m^2, area of port n2 partition
    p2: f32 = 0.0, // m, perimeter of port n2 partition
    c2: f32 = 0, // number of contacts at n2
    trise: f32 = 0.0, // degC, local temperature offset
    sw_noise: i32 = 1,
    sw_et: i32 = 1, // self-heating switch
    sw_lin: i32 = 0, // force linearity
    sw_mman: i32 = 0, // mismatch analysis
    nsmm_rsh: f32 = 0.0,
    nsmm_w: f32 = 0.0,
    nsmm_l: f32 = 0.0,
    m: f32 = 1.0, // multiplicity
};

// ============================================================================
// Sparse conductance stamp pattern
// ============================================================================
// Connections: n1-i1 (end resistance), i1-i2 (body), i2-n2 (end resistance),
//              nc-i1 (diode 1), nc-i2 (diode 2), dt self-heating

// ============================================================================
// Capacitance stamp pattern (parasitic junction + thermal capacitance)
// ============================================================================

// ============================================================================
// Noise generators
// ============================================================================
pub const noise_gens = [_]contract.NoiseGen(Self){
    // Thermal noise: resistor body (i1 to i2)
    .{ .row = @intFromEnum(U.int1), .col = @intFromEnum(U.int2), .kind = .thermal },
    // Thermal noise: end resistance 1 (n1 to i1)
    .{ .row = @intFromEnum(U.n1), .col = @intFromEnum(U.int1), .kind = .thermal },
    // Thermal noise: end resistance 2 (i2 to n2)
    .{ .row = @intFromEnum(U.int2), .col = @intFromEnum(U.n2), .kind = .thermal },
    // Flicker noise: resistor body (i1 to i2)
    .{ .row = @intFromEnum(U.int1), .col = @intFromEnum(U.int2), .kind = .flicker },
    // Shot noise: parasitic diode 1 (nc to i1)
    .{ .row = @intFromEnum(U.nc), .col = @intFromEnum(U.int1), .kind = .shot },
    // Shot noise: parasitic diode 2 (nc to i2)
    .{ .row = @intFromEnum(U.nc), .col = @intFromEnum(U.int2), .kind = .shot },
};

// ============================================================================
// Inline helpers (branchless, no std, vectorizable)
// ============================================================================

/// Smooth limiting of temperature factor to minimum 0.01 (f64, x-independent).
inline fn smoothClipMin(x: f64, xmin: f64) f64 {
    const d = x - xmin;
    return xmin + 0.5 * (d + @sqrt(d * d + 1.0e-6));
}

/// Smooth softplus (S form): ln(1 + exp(x)) with overflow guard.
inline fn softplusS(comptime S: type, x: S) S {
    const x_clamp = x.minC(80.0);
    return x_clamp.exp().addC(1.0).log();
}

/// Smooth limiting to minimum xmin (S form): xmin + 0.5*(d + sqrt(d^2 + 1e-6)).
inline fn smoothClipMinS(comptime S: type, x: S, xmin: f64) S {
    const d = x.addC(-xmin);
    return d.mul(d).addC(1.0e-6).sqrt().add(d).scale(0.5).addC(xmin);
}

// ============================================================================
// x-independent parameter/geometry preprocessing (pure f64)
// ============================================================================
// Everything here is independent of the terminal unknowns. Only the
// temperature that flows from the self-heating node v_dt (and the terminal
// voltages themselves) is x-dependent; those live in eval/q as S chains.
const Prep = struct {
    type_f: f64,
    tnom: f64,
    trise: f64,
    sw_et: f64,
    m_mult: f64,

    // geometry
    w_um: f64,
    l_um: f64,
    contact_avg: f64,
    c1_flag: f64,
    c2_flag: f64,
    w_eff_um: f64,
    l_eff_um: f64,
    rsh_eff: f64,
    df: f64,
    dp_i: f64,
    gf0: f64,

    // partition area/perimeter (um)
    a1_um2: f64,
    p1_um: f64,
    a2_um2: f64,
    p2_um: f64,

    // temperature coefficients (geometry-dependent, x-independent)
    tc1_eff: f64,
    tc2_eff: f64,

    // velocity saturation base
    dxlsat: f64,
    du: f64,
    ecorn: f64,
    ecrit: f64,
    xvsat: f64,
    sw_vsatt: f64,

    // saturation smoothing
    ats_i: f64,

    // pinch-off
    grpo: f64,
    sw_accpo_i: i32,
    nst: f64,
    dp_param_present: bool,

    // end resistance base
    re1_base: f64,
    re2_base: f64,
    tc1rc: f64,
    tc2rc: f64,
    rthresh: f64,

    // diode params
    has_diodes: bool,
    isa: f64,
    na: f64,
    isp: f64,
    np: f64,
    xis: f64,
    ea: f64,
    imax: f64,

    // breakdown
    has_bkd: bool,
    vbv_param: f64,
    ibv: f64,
    nbv_param: f64,
    tc1vbv: f64,
    tc2vbv: f64,
    tc1nbv: f64,

    // dp temperature coefficients
    tc1dp: f64,
    tc2dp: f64,

    // thermal conductance base
    gth_base: f64,
    tegth: f64,

    // switches
    sw_lin_f: f64,
};

fn prep(model: *const Model, instance: *const Instance) Prep {
    // ---- model casts ----
    const type_f: f64 = @floatFromInt(model.type_);
    const scale: f64 = @as(f64, model.scale);
    const shrink: f64 = @as(f64, model.shrink);
    const tnom: f64 = @as(f64, model.tnom);
    const rsh: f64 = @as(f64, model.rsh);
    const xw: f64 = @as(f64, model.xw);
    const nwxw: f64 = @as(f64, model.nwxw);
    const wexw: f64 = @as(f64, model.wexw);
    const fdrw: f64 = @as(f64, model.fdrw);
    const fdxwinf: f64 = @as(f64, model.fdxwinf);
    const xl: f64 = @as(f64, model.xl);
    const xlw: f64 = @as(f64, model.xlw);
    const dxlsat: f64 = @as(f64, model.dxlsat);
    const nst: f64 = @as(f64, model.nst);
    const dfinf: f64 = @as(f64, model.dfinf);
    const dfl: f64 = @as(f64, model.dfl);
    const dfw: f64 = @as(f64, model.dfw);
    const dfwl: f64 = @as(f64, model.dfwl);
    const sw_dfgeo: f64 = @floatFromInt(model.sw_dfgeo);
    const dp_param: f64 = @as(f64, model.dp);
    const dpl: f64 = @as(f64, model.dpl);
    const dple: f64 = @as(f64, model.dple);
    const dpw: f64 = @as(f64, model.dpw);
    const dpwe: f64 = @as(f64, model.dpwe);
    const dpwl: f64 = @as(f64, model.dpwl);
    const ecrit: f64 = @as(f64, model.ecrit);
    const ecorn: f64 = @as(f64, model.ecorn);
    const sw_vsatt: f64 = @floatFromInt(model.sw_vsatt);
    const xvsat: f64 = @as(f64, model.xvsat);
    const du: f64 = @as(f64, model.du);
    const ats_param: f64 = @as(f64, model.ats);
    const atsl: f64 = @as(f64, model.atsl);
    const grpo: f64 = @as(f64, model.grpo);
    const rc: f64 = @as(f64, model.rc);
    const rcw: f64 = @as(f64, model.rcw);
    const imax: f64 = @as(f64, model.imax);
    const isa: f64 = @as(f64, model.isa);
    const na: f64 = @as(f64, model.na);
    const isp: f64 = @as(f64, model.isp);
    const np: f64 = @as(f64, model.np);
    const vbv_param: f64 = @as(f64, model.vbv);
    const ibv: f64 = @as(f64, model.ibv);
    const nbv_param: f64 = @as(f64, model.nbv);
    const ea: f64 = @as(f64, model.ea);
    const xis: f64 = @as(f64, model.xis);
    const tc1: f64 = @as(f64, model.tc1);
    const tc2: f64 = @as(f64, model.tc2);
    const tc1l: f64 = @as(f64, model.tc1l);
    const tc2l: f64 = @as(f64, model.tc2l);
    const tc1w: f64 = @as(f64, model.tc1w);
    const tc2w: f64 = @as(f64, model.tc2w);
    const tc1wl: f64 = @as(f64, model.tc1wl);
    const tc2wl: f64 = @as(f64, model.tc2wl);
    const tc1rc: f64 = @as(f64, model.tc1rc);
    const tc2rc: f64 = @as(f64, model.tc2rc);
    const tc1dp: f64 = @as(f64, model.tc1dp);
    const tc2dp: f64 = @as(f64, model.tc2dp);
    const tc1vbv: f64 = @as(f64, model.tc1vbv);
    const tc2vbv: f64 = @as(f64, model.tc2vbv);
    const tc1nbv: f64 = @as(f64, model.tc1nbv);
    const tegth: f64 = @as(f64, model.tegth);
    const gth0: f64 = @as(f64, model.gth0);
    const gthp: f64 = @as(f64, model.gthp);
    const gtha: f64 = @as(f64, model.gtha);
    const gthc: f64 = @as(f64, model.gthc);
    const rthresh: f64 = @as(f64, model.rthresh);
    const sw_accpo_i: i32 = model.sw_accpo;

    // Statistical variation parameters
    const nsig_rsh: f64 = @as(f64, model.nsig_rsh);
    const nsig_w: f64 = @as(f64, model.nsig_w);
    const nsig_l: f64 = @as(f64, model.nsig_l);
    const sig_rsh: f64 = @as(f64, model.sig_rsh);
    const sig_w: f64 = @as(f64, model.sig_w);
    const sig_l: f64 = @as(f64, model.sig_l);
    const smm_rsh: f64 = @as(f64, model.smm_rsh);
    const smm_w: f64 = @as(f64, model.smm_w);
    const smm_l: f64 = @as(f64, model.smm_l);
    const sw_mmgeo: f64 = @floatFromInt(model.sw_mmgeo);

    // ---- instance casts ----
    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_wd: f64 = @as(f64, instance.wd);
    const inst_a1: f64 = @as(f64, instance.a1);
    const inst_p1: f64 = @as(f64, instance.p1);
    const inst_c1: f64 = @as(f64, instance.c1);
    const inst_a2: f64 = @as(f64, instance.a2);
    const inst_p2: f64 = @as(f64, instance.p2);
    const inst_c2: f64 = @as(f64, instance.c2);
    const trise: f64 = @as(f64, instance.trise);
    const sw_et: f64 = @floatFromInt(instance.sw_et);
    const sw_lin_f: f64 = @floatFromInt(instance.sw_lin);
    const m_mult: f64 = @as(f64, instance.m);
    const sw_mman: f64 = @floatFromInt(instance.sw_mman);
    const nsmm_rsh: f64 = @as(f64, instance.nsmm_rsh);
    const nsmm_w: f64 = @as(f64, instance.nsmm_w);
    const nsmm_l: f64 = @as(f64, instance.nsmm_l);

    // ---- Geometry calculations (eqs 1-6) ----
    const shrink_factor = 1.0 - shrink / 100.0;
    const geo_scale = scale * shrink_factor;
    const l_um = inst_l * geo_scale * 1.0e6; // eq (1)
    const w_um = inst_w * geo_scale * 1.0e6; // eq (2)
    const wd_um = inst_wd * geo_scale * 1.0e6; // eq (6)

    // Contact flags
    const c1_flag: f64 = if (inst_c1 > 0.0) 1.0 else 0.0;
    const c2_flag: f64 = if (inst_c2 > 0.0) 1.0 else 0.0;
    const contact_avg = (c1_flag + c2_flag) * 0.5; // eq (3)

    // Effective length offset (eq 3)
    const xl_eff = (xl + xlw / @max(w_um, 1.0e-30)) * contact_avg;

    // Effective length (eq 4)
    const l_eff_um_nom = @max(l_um + xl_eff, 1.0e-6);

    // Effective width (eq 5)
    const fd_width_corr = fdxwinf * (1.0 - contract.fmath.exp(-w_um / @max(fdrw, 1.0e-30)));
    const w_eff_num = w_um + xw + (nwxw / @max(w_um, 1.0e-30)) + fd_width_corr;
    const web_denom = 1.0 - wexw * wd_um / @max(l_um * w_um, 1.0e-30);
    const w_eff_um_nom = @max(w_eff_num / @max(web_denom, 1.0e-6), 1.0e-6);

    // ---- Statistical variation (eqs 57-62) ----
    const W_mm = if (sw_mmgeo > 0.5) w_eff_um_nom else w_um;
    const L_mm = if (sw_mmgeo > 0.5) l_eff_um_nom else l_um;

    const w_eff_mm1 = w_eff_um_nom + nsig_w * sig_w + nsmm_w * smm_w / @sqrt(@max(m_mult * L_mm, 1.0e-30));
    const l_eff_mm1 = l_eff_um_nom + nsig_l * sig_l + nsmm_l * smm_l / @sqrt(@max(m_mult * W_mm, 1.0e-30));
    const rsh_mm1_exp = 0.01 * (nsig_rsh * sig_rsh + nsmm_rsh * smm_rsh / @sqrt(@max(m_mult * W_mm * L_mm, 1.0e-30)));
    const rsh_mm1 = rsh * contract.fmath.exp(@min(rsh_mm1_exp, 80.0));

    const w_eff_mm0 = w_eff_um_nom + nsig_w * @sqrt(sig_w * sig_w + smm_w * smm_w / @max(m_mult * L_mm, 1.0e-30));
    const l_eff_mm0 = l_eff_um_nom + nsig_l * @sqrt(sig_l * sig_l + smm_l * smm_l / @max(m_mult * W_mm, 1.0e-30));
    const rsh_mm0_exp = 0.01 * nsig_rsh * @sqrt(sig_rsh * sig_rsh + smm_rsh * smm_rsh / @max(m_mult * W_mm * L_mm, 1.0e-30));
    const rsh_mm0 = rsh * contract.fmath.exp(@min(rsh_mm0_exp, 80.0));

    const has_stat = (nsig_rsh != 0.0 or nsig_w != 0.0 or nsig_l != 0.0 or nsmm_rsh != 0.0 or nsmm_w != 0.0 or nsmm_l != 0.0);
    const w_eff_um = if (has_stat) (if (sw_mman > 0.5) w_eff_mm1 else w_eff_mm0) else w_eff_um_nom;
    const l_eff_um = if (has_stat) (if (sw_mman > 0.5) l_eff_mm1 else l_eff_mm0) else l_eff_um_nom;
    const rsh_eff: f64 = if (has_stat) (if (sw_mman > 0.5) rsh_mm1 else rsh_mm0) else rsh;

    // ---- Depletion factor geometry dependence (eq 7) ----
    const W_df = if (sw_dfgeo > 0.5) w_eff_um else w_um;
    const L_df = if (sw_dfgeo > 0.5) l_eff_um else l_um;
    const df = dfinf + dfw / @max(W_df, 1.0e-30) + dfl / @max(L_df, 1.0e-30) + dfwl / @max(W_df * L_df, 1.0e-30);

    // ---- Depletion potential geometry dependence (eq 8) ----
    const W_dp = w_eff_um;
    const L_dp = l_eff_um;
    const w_dpwe = contract.fmath.exp(dpwe * contract.fmath.log(@max(W_dp, 1.0e-30)));
    const l_dple = contract.fmath.exp(dple * contract.fmath.log(@max(L_dp, 1.0e-30)));
    const dp_i = dp_param * (1.0 + dpw / @max(w_dpwe, 1.0e-30)) * (1.0 + dpl / @max(l_dple, 1.0e-30)) * (1.0 + dpwl / @max(w_dpwe * l_dple, 1.0e-30));

    // ---- Zero-bias resistance (eq 9) ----
    const r0_base = rsh_eff * l_eff_um / @max(w_eff_um, 1.0e-30) * (1.0 - df * @sqrt(@max(dp_i, 1.0e-30)));
    const r0 = @max(r0_base, 1.0e-6);
    const gf0 = 1.0 / r0;

    // ---- Effective temperature coefficients (eqs 10-11) ----
    const tc1_eff = tc1 + tc1w / @max(w_eff_um, 1.0e-30) + contact_avg / @max(l_eff_um, 1.0e-30) * (tc1l + tc1wl / @max(w_eff_um, 1.0e-30));
    const tc2_eff = tc2 + tc2w / @max(w_eff_um, 1.0e-30) + contact_avg / @max(l_eff_um, 1.0e-30) * (tc2l + tc2wl / @max(w_eff_um, 1.0e-30));

    // ---- End resistance base (eqs 17, 30) ----
    const re1_base = if (inst_c1 > 0.0) (rc + rcw / @max(w_um, 1.0e-30)) / @max(inst_c1, 1.0) else 0.0;
    const re2_base = if (inst_c2 > 0.0) (rc + rcw / @max(w_um, 1.0e-30)) / @max(inst_c2, 1.0) else 0.0;

    // ---- Partition area/perimeter scaling (eqs 18-21) ----
    const geo_scale_um = geo_scale * 1.0e6;
    const geo_scale_um2 = geo_scale_um * geo_scale_um;
    const p1_um = inst_p1 * geo_scale_um; // eq (18)
    const a1_um2 = inst_a1 * geo_scale_um2; // eq (19)
    const p2_um = inst_p2 * geo_scale_um; // eq (20)
    const a2_um2 = inst_a2 * geo_scale_um2; // eq (21)

    // ---- Saturation voltage limiting (eq 42) ----
    const ats_i = ats_param / @max(1.0 + atsl / @max(l_eff_um, 1.0e-30), 1.0e-30);

    // ---- Thermal conductance base (eqs 12, 14-15) ----
    const a_um2 = l_um * w_um; // eq (14)
    const p_um = 2.0 * l_um + (c1_flag + c2_flag) * w_um; // eq (15)
    const gth_base = gth0 + gthp * p_um + gtha * a_um2 + gthc * (inst_c1 + inst_c2);

    return .{
        .type_f = type_f,
        .tnom = tnom,
        .trise = trise,
        .sw_et = sw_et,
        .m_mult = m_mult,
        .w_um = w_um,
        .l_um = l_um,
        .contact_avg = contact_avg,
        .c1_flag = c1_flag,
        .c2_flag = c2_flag,
        .w_eff_um = w_eff_um,
        .l_eff_um = l_eff_um,
        .rsh_eff = rsh_eff,
        .df = df,
        .dp_i = dp_i,
        .gf0 = gf0,
        .a1_um2 = a1_um2,
        .p1_um = p1_um,
        .a2_um2 = a2_um2,
        .p2_um = p2_um,
        .tc1_eff = tc1_eff,
        .tc2_eff = tc2_eff,
        .dxlsat = dxlsat,
        .du = du,
        .ecorn = ecorn,
        .ecrit = ecrit,
        .xvsat = xvsat,
        .sw_vsatt = sw_vsatt,
        .ats_i = ats_i,
        .grpo = grpo,
        .sw_accpo_i = sw_accpo_i,
        .nst = nst,
        .dp_param_present = dp_param != 0.0,
        .re1_base = re1_base,
        .re2_base = re2_base,
        .tc1rc = tc1rc,
        .tc2rc = tc2rc,
        .rthresh = rthresh,
        .has_diodes = (isa > 0.0 or isp > 0.0),
        .isa = isa,
        .na = na,
        .isp = isp,
        .np = np,
        .xis = xis,
        .ea = ea,
        .imax = imax,
        .has_bkd = vbv_param > 0.0,
        .vbv_param = vbv_param,
        .ibv = ibv,
        .nbv_param = nbv_param,
        .tc1vbv = tc1vbv,
        .tc2vbv = tc2vbv,
        .tc1nbv = tc1nbv,
        .tc1dp = tc1dp,
        .tc2dp = tc2dp,
        .gth_base = gth_base,
        .tegth = tegth,
        .sw_lin_f = sw_lin_f,
    };
}

pub const PrepCache = Prep;

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return prep(model, instance);
}

// ============================================================================
// Current contribution (value-form eval)
// ============================================================================
// The x-dependent quantities are the six terminal unknowns. Note that the
// self-heating node v_dt raises the device temperature, so the temperature
// chain (r_T, phi_t, tfac, gf, isa_T, ...) is x-dependent and must be S.
pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    const p = pc;

    const v_n1 = x[@intFromEnum(U.n1)];
    const v_nc = x[@intFromEnum(U.nc)];
    const v_n2 = x[@intFromEnum(U.n2)];
    const v_i1 = x[@intFromEnum(U.int1)];
    const v_i2 = x[@intFromEnum(U.int2)];
    const v_dt = x[@intFromEnum(U.dt)];

    const type_f = p.type_f;

    // ---- Temperature (x-dependent via self-heating v_dt) ----
    const t_nom_k = p.tnom + T0;
    // dT_sh = v_dt * sw_et
    const dT_sh = v_dt.scale(p.sw_et);
    // t_dev_k = t_nom_k + trise + dT_sh
    const t_dev_k = dT_sh.addC(t_nom_k + p.trise);
    // dT = t_dev_k - t_nom_k
    const dT = t_dev_k.addC(-t_nom_k);
    // r_T = t_dev_k / t_nom_k
    const r_T = t_dev_k.scale(1.0 / t_nom_k);
    // phi_t = KB * t_dev_k / QQ
    const phi_t = t_dev_k.scale(KB / QQ);
    const ln_rT = r_T.maxC(1.0e-30).log();

    // ---- Resistance temperature factor (eqs 24-26) ----
    // tfac_raw = 1 + tc1_eff*dT + tc2_eff*dT*dT
    const tfac_raw = dT.scale(p.tc1_eff).add(dT.mul(dT).scale(p.tc2_eff)).addC(1.0);
    const tfac = smoothClipMinS(S, tfac_raw, 0.01);
    // gf = gf0 / tfac
    const gf = tfac.pow(-1.0).scale(p.gf0);

    // ---- Depletion potential with temperature (eq 27) ----
    // dp_T = dp_i * (1 + tc1dp*dT + tc2dp*dT*dT)
    const dp_T = dT.scale(p.tc1dp).add(dT.mul(dT).scale(p.tc2dp)).addC(1.0).scale(p.dp_i);
    const dp_T_pos = dp_T.maxC(0.01);

    // ---- Velocity saturation temperature dependence (eqs 28-29) ----
    // r_T^xvsat = exp(xvsat*ln(r_T))
    const r_T_xvsat = ln_rT.scale(p.xvsat).exp();
    // vsat_tfac = (sw_vsatt) ? r_T^xvsat * tfac : 1
    const vsat_tfac = if (p.sw_vsatt > 0.5) r_T_xvsat.mul(tfac) else S.con(1.0);
    const ecorn_T = vsat_tfac.scale(p.ecorn);
    const ecrit_T = vsat_tfac.scale(p.ecrit);

    // ---- End resistance with temperature (eqs 17, 30) ----
    // rc_tc = smoothClipMin(1 + tc1rc*dT + tc2rc*dT^2, 0.01)
    const rc_tc_raw = dT.scale(p.tc1rc).add(dT.mul(dT).scale(p.tc2rc)).addC(1.0);
    const rc_tc = smoothClipMinS(S, rc_tc_raw, 0.01);

    // re1_T = re1_base * rc_tc ; ge1 = (re1_T > rthresh) ? 1/re1_T : GSHORT
    const re1_T = rc_tc.scale(p.re1_base);
    const ge1 = if (re1_T.val() > p.rthresh) re1_T.pow(-1.0) else S.con(GSHORT);
    const re2_T = rc_tc.scale(p.re2_base);
    const ge2 = if (re2_T.val() > p.rthresh) re2_T.pow(-1.0) else S.con(GSHORT);

    // ---- Diode saturation current temperature dependence (eqs 31-32) ----
    // isa_T = isa * exp(xis/na*ln_rT) * exp(min(-ea*(1-r_T)/(na*phi_t), 80))
    const one_minus_rT = r_T.neg().addC(1.0); // 1 - r_T
    const isa_arg2 = one_minus_rT.neg().scale(p.ea).div(phi_t.scale(p.na)).minC(80.0);
    const isa_T = ln_rT.scale(p.xis / p.na).exp().mul(isa_arg2.exp()).scale(p.isa);
    const isp_arg2 = one_minus_rT.neg().scale(p.ea).div(phi_t.scale(p.np)).minC(80.0);
    const isp_T = ln_rT.scale(p.xis / p.np).exp().mul(isp_arg2.exp()).scale(p.isp);

    // ---- Breakdown voltage/ideality temperature dependence (eqs 38-39) ----
    // vbv_T = vbv_param * (1 + tc1vbv*dT + tc2vbv*dT^2)
    const vbv_T = dT.scale(p.tc1vbv).add(dT.mul(dT).scale(p.tc2vbv)).addC(1.0).scale(p.vbv_param);
    // nbv_T = nbv_param * (1 + tc1nbv*dT)
    const nbv_T = dT.scale(p.tc1nbv).addC(1.0).scale(p.nbv_param);

    // ---- Thermal conductance (eqs 12) ----
    // gth_T = gth_base * exp(tegth*ln_rT)
    const gth_T = ln_rT.scale(p.tegth).exp().scale(p.gth_base);

    // ---- Branch voltages ----
    const v_21 = v_i2.sub(v_i1); // body voltage drop
    const v_c1 = v_nc.sub(v_i1).scale(type_f); // control-to-i1 (diode direction)
    const v_c2 = v_nc.sub(v_i2).scale(type_f); // control-to-i2 (diode direction)
    const v_1c = v_i1.sub(v_nc).scale(type_f); // i1-to-control for depletion

    // ---- Control voltage limiting / pinch-off (eq 43) ----
    // V_po = 1/(2*df^2) - 0.5*dp_T ; dp_T here is the S value dp_T_pos.
    const df_safe = @max(p.df, 1.0e-10);
    // v_po = 1/(2 df^2) - 0.5*dp_T_pos
    const v_po = dp_T_pos.scale(-0.5).addC(1.0 / (2.0 * df_safe * df_safe));
    // nst_phi_t = nst * phi_t
    const nst_phi_t = phi_t.scale(p.nst);
    const nst_phi_safe = nst_phi_t.maxC(1.0e-30);

    // V_1c_eff = V_po - nst*phi_t * softplus((V_po - V_1c)/(nst*phi_t))
    const v_1c_lim_arg = v_po.sub(v_1c).div(nst_phi_safe);
    const v_1c_eff = v_po.sub(nst_phi_t.mul(softplusS(S, v_1c_lim_arg)));

    // ---- Depletion pinching - body current (eq 40) ----
    // V_i = V_21 + 2*V_1c_eff
    const v_i = v_21.add(v_1c_eff.scale(2.0));
    const dp_v_i = dp_T_pos.add(v_i);
    const sqrt_dp_vi = dp_v_i.maxC(1.0e-30).sqrt();
    // g_depl = gf * (1 - df*sqrt_dp_vi)
    const g_depl = sqrt_dp_vi.scale(p.df).neg().addC(1.0).mul(gf);

    // Pinch-off minimum conductance
    const g_body_min = gf.scale(p.grpo);
    const g_body_raw = g_depl.max(g_body_min);

    // Pinch-off accuracy modes (sw_accpo). Smooth-max variants.
    const g_body_diff = g_depl.sub(g_body_min);
    // smooth_eps = coeff * gf^2 (coeff depends on sw_accpo tier)
    const smooth_coeff: f64 = if (p.sw_accpo_i >= 3) 1.0e-12 else if (p.sw_accpo_i >= 2) 1.0e-8 else 1.0e-4;
    const smooth_eps = gf.mul(gf).scale(smooth_coeff);
    // g_body_smooth = g_body_min + 0.5*(diff + sqrt(diff^2 + eps))
    const g_body_smooth = g_body_diff.mul(g_body_diff).add(smooth_eps).sqrt().add(g_body_diff).scale(0.5).add(g_body_min);
    const g_body = if (p.sw_accpo_i > 0) g_body_smooth else g_body_raw;

    // ---- Velocity saturation: mobility reduction factor (eq 41) ----
    const l_vsat = p.l_eff_um + p.dxlsat;
    // E_field = v_21 / l_vsat
    const E_field = v_21.scale(1.0 / @max(l_vsat, 1.0e-30));

    // E_ce = sqrt(ecorn^2 + (2 du ecrit)^2) - 2 du ecrit    (all S via ecrit_T/ecorn_T)
    const two_du_ecrit = ecrit_T.scale(2.0 * p.du);
    const E_ce = ecorn_T.mul(ecorn_T).add(two_du_ecrit.mul(two_du_ecrit)).sqrt().sub(two_du_ecrit);
    // du_e = du * E_ce / ecrit_T
    const du_e = E_ce.scale(p.du).div(ecrit_T.maxC(1.0e-30));

    // r_mu terms
    const two_ecrit = ecrit_T.scale(2.0).maxC(1.0e-30);
    const term1_arg = E_field.sub(E_ce).div(two_ecrit);
    const term2_arg = E_field.add(E_ce).div(two_ecrit);
    const term3_arg = E_ce.div(ecrit_T.maxC(1.0e-30));
    const r_mu = term1_arg.mul(term1_arg).add(du_e).sqrt()
        .add(term2_arg.mul(term2_arg).add(du_e).sqrt())
        .sub(term3_arg.mul(term3_arg).add(du_e.scale(4.0)).sqrt());

    // ---- Saturation voltage limiting (eq 42) ----
    const ats_i = p.ats_i;
    const v_sat_ecrit = ecrit_T.scale(l_vsat);
    const depl_vi = dp_T_pos.add(v_21).add(v_1c_eff.scale(2.0));
    const sqrt_depl_vi = depl_vi.maxC(1.0e-30).sqrt();
    // dg_dv = df * gf / (2*sqrt_depl_vi)
    const dg_dv = gf.scale(p.df).div(sqrt_depl_vi.maxC(1.0e-30).scale(2.0));
    // g_body_val = max(g_body, 1e-30)
    const g_body_val = g_body.maxC(1.0e-30);
    // v_sat = g_body_val / (g_body_val/v_sat_ecrit + dg_dv)
    const v_sat = g_body_val.div(g_body_val.div(v_sat_ecrit).add(dg_dv).maxC(1.0e-30));

    // If ats_i > 0, apply saturation smoothing
    const use_vsat_lim = ats_i > 1.0e-30;
    const ats_4 = 4.0 * @max(ats_i, 1.0e-30);
    const diff_minus = v_21.sub(v_sat);
    const diff_plus = v_21.add(v_sat);
    const denom_vsat = diff_minus.mul(diff_minus).addC(ats_4).sqrt().add(diff_plus.mul(diff_plus).addC(ats_4).sqrt());
    const v21_eff_sat = if (use_vsat_lim) v_21.mul(v_sat).scale(2.0).div(denom_vsat.maxC(1.0e-30)) else v_21;

    // ---- Body current (eq 44) ----
    const i_body_nonlin = g_body.mul(v21_eff_sat).div(r_mu.addC(1.0));
    const i_body_lin = gf.mul(v_21);
    const i_body_base = if (p.sw_lin_f > 0.5) i_body_lin else i_body_nonlin;

    // ---- Parasitic diode currents (eqs 46-47) ----
    // When sw_accpo > 0, limit diode junction voltages to pinch-off with the
    // same softplus smoothing as eq 43.
    const v_c1_diode = if (p.sw_accpo_i > 0)
        v_po.sub(nst_phi_t.mul(softplusS(S, v_po.sub(v_c1).div(nst_phi_safe))))
    else
        v_c1;
    const v_c2_diode = if (p.sw_accpo_i > 0)
        v_po.sub(nst_phi_t.mul(softplusS(S, v_po.sub(v_c2).div(nst_phi_safe))))
    else
        v_c2;

    // na*phi_t, np*phi_t (S)
    const na_phi = phi_t.scale(p.na);
    const np_phi = phi_t.scale(p.np);

    // Diode 1 (nc to i1). vmax = na*phi_t*ln(max(imax/(a*isa_T),1)) — but the
    // original branch selection compares v_diode < vmax; vmax depends on isa_T
    // (temperature, x-dependent), so evaluate it in S.
    const i_p1 = diodeBranch(S, v_c1_diode, isa_T, p.a1_um2, na_phi, isp_T, p.p1_um, np_phi, p.imax, p.has_diodes);
    const i_p2 = diodeBranch(S, v_c2_diode, isa_T, p.a2_um2, na_phi, isp_T, p.p2_um, np_phi, p.imax, p.has_diodes);

    // ---- Breakdown currents (eqs 48-49) ----
    const nbv_phi = nbv_T.mul(phi_t);
    const nbv_phi_safe = nbv_phi.maxC(1.0e-30);
    // bkd offset = exp(min(-vbv_T/nbv_phi, 80))
    const bkd_offset = vbv_T.neg().div(nbv_phi_safe).minC(80.0).exp();
    // v_bkd_max = -(vbv_T + nbv_phi*ln(max(imax/ibv,1)))
    const ln_imax_ibv = contract.fmath.log(@max(p.imax / @max(p.ibv, 1.0e-30), 1.0));
    const v_bkd_max = vbv_T.add(nbv_phi.scale(ln_imax_ibv)).neg();

    const i_b1 = breakdownBranch(S, v_c1, vbv_T, nbv_phi_safe, bkd_offset, v_bkd_max, p.ibv, p.has_bkd);
    const i_b2 = breakdownBranch(S, v_c2, vbv_T, nbv_phi_safe, bkd_offset, v_bkd_max, p.ibv, p.has_bkd);

    // ---- Total diode currents (with type factor for polarity) ----
    const i_diode1 = i_p1.add(i_b1).scale(type_f);
    const i_diode2 = i_p2.add(i_b2).scale(type_f);

    // ---- End resistance currents ----
    const v_e1 = v_n1.sub(v_i1);
    const i_e1 = v_e1.mul(ge1);
    const v_e2 = v_i2.sub(v_n2);
    const i_e2 = v_e2.mul(ge2);

    // ---- Self-heating: thermal network (eq 12) ----
    const p_body = i_body_base.mul(v_21);
    const p_e1 = i_e1.mul(v_e1);
    const p_e2 = i_e2.mul(v_e2);
    const p_diode1 = i_diode1.mul(v_nc.sub(v_i1));
    const p_diode2 = i_diode2.mul(v_nc.sub(v_i2));
    const p_total = p_body.add(p_e1).add(p_e2).add(p_diode1).add(p_diode2);
    // i_dt = gth_T*v_dt - p_total*sw_et
    const i_dt = gth_T.mul(v_dt).sub(p_total.scale(p.sw_et));

    // ---- Multiplier scaling ----
    const m_mult = p.m_mult;
    const i_body_scaled = i_body_base.scale(m_mult);
    const i_e1_scaled = i_e1.scale(m_mult);
    const i_e2_scaled = i_e2.scale(m_mult);
    const i_diode1_scaled = i_diode1.scale(m_mult);
    const i_diode2_scaled = i_diode2.scale(m_mult);
    const i_dt_scaled = i_dt.scale(m_mult);

    // ---- Assemble residual (KCL: positive = current leaving node) ----
    var out: [n_u]S = undefined;
    out[@intFromEnum(U.n1)] = i_e1_scaled;
    out[@intFromEnum(U.nc)] = i_diode1_scaled.add(i_diode2_scaled);
    out[@intFromEnum(U.n2)] = i_e2_scaled.neg();
    out[@intFromEnum(U.int1)] = i_e1_scaled.neg().add(i_body_scaled).sub(i_diode1_scaled);
    out[@intFromEnum(U.int2)] = i_body_scaled.neg().add(i_e2_scaled).sub(i_diode2_scaled);
    out[@intFromEnum(U.dt)] = i_dt_scaled;
    return out;
}

/// Parasitic diode current for one junction (area + perimeter components with
/// imax linearization), plus GMIN leakage. Faithful S port of eqs 46-47.
inline fn diodeBranch(
    comptime S: type,
    v_diode: S,
    isa_T: S,
    a_um2: f64,
    na_phi: S,
    isp_T: S,
    p_um: f64,
    np_phi: S,
    imax: f64,
    has_diodes: bool,
) S {
    // vmax_a = (isa_T>0 and a>0) ? na*phi*ln(max(imax/(a*isa_T),1)) : 80*na*phi
    const isa_pos = isa_T.val() > 0.0 and a_um2 > 0.0;
    const vmax_a = if (isa_pos)
        na_phi.mul(S.con(imax).div(isa_T.scale(a_um2)).maxC(1.0).log())
    else
        na_phi.scale(80.0);
    const isp_pos = isp_T.val() > 0.0 and p_um > 0.0;
    const vmax_p = if (isp_pos)
        np_phi.mul(S.con(imax).div(isp_T.scale(p_um)).maxC(1.0).log())
    else
        np_phi.scale(80.0);

    // Area component
    const exp_a_arg = v_diode.div(na_phi).minC(80.0);
    const i_a_normal = isa_T.scale(a_um2).mul(exp_a_arg.exp().addC(-1.0));
    const exp_vmax_a = vmax_a.div(na_phi).minC(80.0).exp();
    const i_a_at_vmax = isa_T.scale(a_um2).mul(exp_vmax_a.addC(-1.0));
    const g_a_at_vmax = isa_T.scale(a_um2).div(na_phi).mul(exp_vmax_a);
    const i_a_lin = i_a_at_vmax.add(g_a_at_vmax.mul(v_diode.sub(vmax_a)));
    const i_a = if (v_diode.val() < vmax_a.val()) i_a_normal else i_a_lin;

    // Perimeter component
    const exp_p_arg = v_diode.div(np_phi).minC(80.0);
    const i_p_normal = isp_T.scale(p_um).mul(exp_p_arg.exp().addC(-1.0));
    const exp_vmax_p = vmax_p.div(np_phi).minC(80.0).exp();
    const i_p_at_vmax = isp_T.scale(p_um).mul(exp_vmax_p.addC(-1.0));
    const g_p_at_vmax = isp_T.scale(p_um).div(np_phi).mul(exp_vmax_p);
    const i_p_lin = i_p_at_vmax.add(g_p_at_vmax.mul(v_diode.sub(vmax_p)));
    const i_p = if (v_diode.val() < vmax_p.val()) i_p_normal else i_p_lin;

    const leak = v_diode.scale(GMIN);
    return if (has_diodes) i_a.add(i_p).add(leak) else leak;
}

/// Breakdown current for one junction (eqs 48-49), with imax linearization.
inline fn breakdownBranch(
    comptime S: type,
    v_c: S,
    vbv_T: S,
    nbv_phi_safe: S,
    bkd_offset: S,
    v_bkd_max: S,
    ibv: f64,
    has_bkd: bool,
) S {
    if (!has_bkd) return S.con(0.0);
    // i_raw = -ibv*(exp(min(-(v_c+vbv_T)/nbv_phi,80)) - offset)
    const bkd_exp = v_c.add(vbv_T).neg().div(nbv_phi_safe).minC(80.0).exp();
    const i_raw = bkd_exp.sub(bkd_offset).scale(-ibv);
    // linear extension below v_bkd_max
    const bkd_at_max = v_bkd_max.add(vbv_T).neg().div(nbv_phi_safe).minC(80.0).exp().sub(bkd_offset).scale(-ibv);
    const g_at_max = v_bkd_max.add(vbv_T).neg().div(nbv_phi_safe).minC(80.0).exp().div(nbv_phi_safe).scale(ibv);
    const i_lin = bkd_at_max.sub(g_at_max.mul(v_c.sub(v_bkd_max)));
    return if (v_c.val() > v_bkd_max.val()) i_raw else i_lin;
}

// ============================================================================
// Charge function (junction depletion capacitances + thermal capacitance)
// ============================================================================
pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = pc;

    // ---- x-independent param prep ----
    const type_f: f64 = @floatFromInt(model.type_);
    const scale: f64 = @as(f64, model.scale);
    const shrink: f64 = @as(f64, model.shrink);
    const tnom: f64 = @as(f64, model.tnom);
    const fc: f64 = @as(f64, model.fc);
    const ca: f64 = @as(f64, model.ca);
    const cja: f64 = @as(f64, model.cja);
    const pa_param: f64 = @as(f64, model.pa);
    const ma: f64 = @as(f64, model.ma);
    const cp: f64 = @as(f64, model.cp);
    const cjp: f64 = @as(f64, model.cjp);
    const pp_param: f64 = @as(f64, model.pp);
    const mp: f64 = @as(f64, model.mp);
    const ea: f64 = @as(f64, model.ea);
    const aja: f64 = @as(f64, model.aja);
    const ajp: f64 = @as(f64, model.ajp);
    const cth0: f64 = @as(f64, model.cth0);
    const cthp: f64 = @as(f64, model.cthp);
    const ctha: f64 = @as(f64, model.ctha);
    const cthc: f64 = @as(f64, model.cthc);

    const inst_w: f64 = @as(f64, instance.w);
    const inst_l: f64 = @as(f64, instance.l);
    const inst_a1: f64 = @as(f64, instance.a1);
    const inst_p1: f64 = @as(f64, instance.p1);
    const inst_c1: f64 = @as(f64, instance.c1);
    const inst_a2: f64 = @as(f64, instance.a2);
    const inst_p2: f64 = @as(f64, instance.p2);
    const inst_c2: f64 = @as(f64, instance.c2);
    const trise: f64 = @as(f64, instance.trise);
    const sw_et: f64 = @floatFromInt(instance.sw_et);
    const m_mult: f64 = @as(f64, instance.m);

    // Geometry (x-independent)
    const shrink_factor = 1.0 - shrink / 100.0;
    const geo_scale = scale * shrink_factor;
    const l_um = inst_l * geo_scale * 1.0e6;
    const w_um = inst_w * geo_scale * 1.0e6;
    const geo_scale_um = geo_scale * 1.0e6;
    const geo_scale_um2 = geo_scale_um * geo_scale_um;
    const p1_um = inst_p1 * geo_scale_um;
    const a1_um2 = inst_a1 * geo_scale_um2;
    const p2_um = inst_p2 * geo_scale_um;
    const a2_um2 = inst_a2 * geo_scale_um2;

    const c1_flag: f64 = if (inst_c1 > 0.0) 1.0 else 0.0;
    const c2_flag: f64 = if (inst_c2 > 0.0) 1.0 else 0.0;

    const t_nom_k = tnom + T0;

    // ---- Terminal voltages ----
    const v_nc = x[@intFromEnum(U.nc)];
    const v_i1 = x[@intFromEnum(U.int1)];
    const v_i2 = x[@intFromEnum(U.int2)];
    const v_dt = x[@intFromEnum(U.dt)];

    // ---- Temperature (x-dependent via self-heating v_dt) ----
    const dT_sh = v_dt.scale(sw_et);
    const t_dev_k = dT_sh.addC(t_nom_k + trise);
    const r_T = t_dev_k.scale(1.0 / t_nom_k);
    const phi_t = t_dev_k.scale(KB / QQ);
    const ln_rT = r_T.maxC(1.0e-30).log();

    // Built-in potential temperature dependence (eqs 33-34)
    // pa_T = max(pa*r_T - 3*phi_t*ln_rT - ea*(r_T-1), 0.01)
    const pa_T_raw = r_T.scale(pa_param).sub(phi_t.mul(ln_rT).scale(3.0)).sub(r_T.addC(-1.0).scale(ea));
    const pa_T = pa_T_raw.maxC(0.01);
    const pp_T_raw = r_T.scale(pp_param).sub(phi_t.mul(ln_rT).scale(3.0)).sub(r_T.addC(-1.0).scale(ea));
    const pp_T = pp_T_raw.maxC(0.01);

    // Zero-bias capacitance temperature dependence (eqs 35-36)
    // cja_T = cja * exp(ma * ln(max(pa/pa_T, 1e-30)))
    const cja_T = pa_T.pow(-1.0).scale(pa_param).maxC(1.0e-30).log().scale(ma).exp().scale(cja);
    const cjp_T = pp_T.pow(-1.0).scale(pp_param).maxC(1.0e-30).log().scale(mp).exp().scale(cjp);

    // Diode voltages (with type factor)
    const v_c1 = v_nc.sub(v_i1).scale(type_f);
    const v_c2 = v_nc.sub(v_i2).scale(type_f);

    // ---- Parasitic capacitance charge (eqs 50-51) ----
    const q_c1_a = junctionChargeS(S, v_c1, cja_T, pa_T, ma, fc, aja);
    const q_c1_p = junctionChargeS(S, v_c1, cjp_T, pp_T, mp, fc, ajp);
    const q_c1_fixed = v_c1.scale(a1_um2 * ca + p1_um * cp);
    const q_p1 = q_c1_a.scale(a1_um2).add(q_c1_p.scale(p1_um)).add(q_c1_fixed).scale(type_f * m_mult);

    const q_c2_a = junctionChargeS(S, v_c2, cja_T, pa_T, ma, fc, aja);
    const q_c2_p = junctionChargeS(S, v_c2, cjp_T, pp_T, mp, fc, ajp);
    const q_c2_fixed = v_c2.scale(a2_um2 * ca + p2_um * cp);
    const q_p2 = q_c2_a.scale(a2_um2).add(q_c2_p.scale(p2_um)).add(q_c2_fixed).scale(type_f * m_mult);

    // ---- Thermal capacitance (eq 13) ----
    const a_um2 = l_um * w_um;
    const p_um = 2.0 * l_um + (c1_flag + c2_flag) * w_um;
    const cth = cth0 + cthp * p_um + ctha * a_um2 + cthc * (inst_c1 + inst_c2);
    const q_th = v_dt.scale(cth * m_mult);

    // ---- Assemble ----
    var out: [n_u]S = undefined;
    out[@intFromEnum(U.nc)] = q_p1.add(q_p2);
    out[@intFromEnum(U.int1)] = q_p1.neg();
    out[@intFromEnum(U.int2)] = q_p2.neg();
    out[@intFromEnum(U.n1)] = S.con(0.0);
    out[@intFromEnum(U.n2)] = S.con(0.0);
    out[@intFromEnum(U.dt)] = q_th;
    return out;
}

// ============================================================================
// Junction charge helper (S form)
// ============================================================================
/// Compute junction depletion charge for a single component.
/// Two regions: reverse/moderate forward (power-law) and forward beyond fc*pb.
/// If aj > 0, the transition at fc*pb is smoothed using a hyperbolic blending.
/// cj0/pb are S (temperature-dependent); mj/fc/aj are constant f64.
inline fn junctionChargeS(comptime S: type, v: S, cj0: S, pb: S, mj: f64, fc_param: f64, aj: f64) S {
    const one_minus_mj = 1.0 - mj;
    const one_minus_mj_safe = @max(one_minus_mj, 1.0e-10);
    const pb_safe = pb.maxC(1.0e-30);

    // v_fc = fc*pb
    const v_fc = pb.scale(fc_param);

    // Region 1: V < fc*Pb (depletion)
    // q_dep = pb*cj0/(1-mj) * (1 - (max(1 - v/pb, 1e-30))^(1-mj))
    const v_over_pb = v.div(pb_safe);
    const arg_dep = v_over_pb.neg().addC(1.0).maxC(1.0e-30);
    // (arg_dep)^(1-mj) = exp((1-mj)*ln(arg_dep))
    const arg_dep_pow = arg_dep.log().scale(one_minus_mj).exp();
    const q_dep = pb.mul(cj0).scale(1.0 / one_minus_mj_safe).mul(arg_dep_pow.neg().addC(1.0));

    // Region 2: V >= fc*Pb (linear extension)
    const arg_fc = @max(1.0 - fc_param, 1.0e-30);
    // c_fc = cj0 / (1-fc)^mj
    const c_fc = cj0.scale(1.0 / contract.fmath.exp(mj * contract.fmath.log(arg_fc)));
    // q_fc = pb*cj0/(1-mj) * (1 - (1-fc)^(1-mj))
    const q_fc = pb.mul(cj0).scale((1.0 / one_minus_mj_safe) * (1.0 - contract.fmath.exp(one_minus_mj * contract.fmath.log(arg_fc))));
    // dc_dv_fc = mj * c_fc / (pb*(1-fc))
    const dc_dv_fc = c_fc.scale(mj).div(pb.scale(arg_fc).maxC(1.0e-30));
    const dv = v.sub(v_fc);
    // q_fwd = q_fc + c_fc*dv + 0.5*dc_dv_fc*dv^2
    const q_fwd = q_fc.add(c_fc.mul(dv)).add(dc_dv_fc.mul(dv).mul(dv).scale(0.5));

    // Smooth blending (aj > 0)
    const use_smooth = aj > 0.0;
    const diff_v = v.sub(v_fc);
    // v_smooth = v_fc + 0.5*(diff_v - sqrt(diff_v^2 + aj^2))
    const v_smooth = v_fc.add(diff_v.sub(diff_v.mul(diff_v).addC(aj * aj).sqrt()).scale(0.5));
    const v_over_pb_s = v_smooth.div(pb_safe);
    const arg_dep_s = v_over_pb_s.neg().addC(1.0).maxC(1.0e-30);
    const arg_dep_s_pow = arg_dep_s.log().scale(one_minus_mj).exp();
    const q_dep_smooth = pb.mul(cj0).scale(1.0 / one_minus_mj_safe).mul(arg_dep_s_pow.neg().addC(1.0));
    const v_excess = v.sub(v_smooth);
    // c_at_smooth = cj0 / (max(1 - v_smooth/pb, 1e-30))^mj
    const denom_c = v_smooth.div(pb_safe).neg().addC(1.0).maxC(1.0e-30).log().scale(mj).exp();
    const c_at_smooth = cj0.div(denom_c);
    const q_smooth_total = q_dep_smooth.add(c_at_smooth.mul(v_excess));

    const q_hard = if (v.val() < v_fc.val()) q_dep else q_fwd;
    return if (use_smooth) q_smooth_total else q_hard;
}

// ============================================================================
// Voltage limiting function (PN junction limiting)
// ============================================================================
pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    var x_lim = x_new;

    const type_f: f64 = @floatFromInt(model.type_);
    const tnom: f64 = @as(f64, model.tnom);
    const trise: f64 = @as(f64, instance.trise);
    const sw_et: f64 = @floatFromInt(instance.sw_et);
    const isa: f64 = @as(f64, model.isa);
    const isp: f64 = @as(f64, model.isp);
    const na: f64 = @as(f64, model.na);
    const np: f64 = @as(f64, model.np);

    const t_nom_k = tnom + T0;
    // Use old dt for temperature estimate
    const dT_sh = x_old[@intFromEnum(U.dt)] * sw_et;
    const t_dev_k = t_nom_k + trise + dT_sh;
    const phi_t = KB * t_dev_k / QQ;

    // Limit the parasitic diode voltages (DEVpnjlim)
    const has_diodes = (isa > 0.0 or isp > 0.0);
    if (has_diodes) {
        // Junction 1: V(nc) - V(i1) with type factor
        const v_c1_new = (x_new[@intFromEnum(U.nc)] - x_new[@intFromEnum(U.int1)]) * type_f;
        const v_c1_old = (x_old[@intFromEnum(U.nc)] - x_old[@intFromEnum(U.int1)]) * type_f;
        const v_c1_lim = pnjlim(v_c1_new, v_c1_old, phi_t, @min(na, np));

        // Apply correction
        const dv1 = (v_c1_lim - v_c1_new) * type_f;
        // Split correction between nc and i1
        x_lim[@intFromEnum(U.nc)] += dv1 * 0.5;
        x_lim[@intFromEnum(U.int1)] -= dv1 * 0.5;

        // Junction 2: V(nc) - V(i2) with type factor
        const v_c2_new = (x_new[@intFromEnum(U.nc)] - x_new[@intFromEnum(U.int2)]) * type_f;
        const v_c2_old = (x_old[@intFromEnum(U.nc)] - x_old[@intFromEnum(U.int2)]) * type_f;
        const v_c2_lim = pnjlim(v_c2_new, v_c2_old, phi_t, @min(na, np));

        const dv2 = (v_c2_lim - v_c2_new) * type_f;
        x_lim[@intFromEnum(U.nc)] += dv2 * 0.5;
        x_lim[@intFromEnum(U.int2)] -= dv2 * 0.5;
    }

    // Limit temperature rise (prevent wild oscillation)
    const dt_new = x_new[@intFromEnum(U.dt)];
    const dt_old = x_old[@intFromEnum(U.dt)];
    const dt_diff = dt_new - dt_old;
    const max_dt_step: f64 = 50.0; // max 50K per Newton step
    const dt_lim = if (dt_diff > max_dt_step)
        dt_old + max_dt_step
    else if (dt_diff < -max_dt_step)
        dt_old - max_dt_step
    else
        dt_new;
    x_lim[@intFromEnum(U.dt)] = dt_lim;

    return x_lim;
}

/// DEVpnjlim: PN junction voltage limiting
/// Logarithmic damping of Newton steps for forward-biased junctions
fn pnjlim(v_new: f64, v_old: f64, phi_t: f64, n_factor: f64) f64 {
    const v_crit = n_factor * phi_t * contract.fmath.log(n_factor * phi_t / (1.4142135623730951 * 1.0e-14));
    const nv_t = n_factor * phi_t;

    if (v_new > v_crit and @abs(v_new - v_old) > 2.0 * nv_t) {
        if (v_old > 0.0) {
            const arg = (v_new - v_old) / nv_t;
            if (arg > 0.0) {
                return v_old + nv_t * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
            } else {
                return v_old - nv_t * (2.0 + contract.fmath.log(@max(2.0 - arg, 1.0e-30)));
            }
        } else {
            return nv_t * contract.fmath.log(@max(v_new / nv_t, 1.0e-30));
        }
    }
    return v_new;
}

// ============================================================================
// Parameter stepping for convergence aid
// ============================================================================
pub fn attempt(model: Model, lambda: f64) Model {
    // Scale junction saturation currents and add gmin*(1-lambda)
    // This helps convergence by making the diodes more conductive at lambda<1
    var m = model;

    // Scale saturation currents: at lambda=0, IS is large (easy to solve)
    // At lambda=1, IS is the real value
    const gmin_scale: f32 = @floatCast(1.0e-12 * (1.0 - lambda));
    const isa_f64: f64 = @as(f64, model.isa);
    const isp_f64: f64 = @as(f64, model.isp);

    // Smooth transition of saturation current
    const isa_scaled = isa_f64 + 1.0e-12 * (1.0 - lambda);
    const isp_scaled = isp_f64 + 1.0e-12 * (1.0 - lambda);
    m.isa = @floatCast(isa_scaled);
    m.isp = @floatCast(isp_scaled);

    // Add conductance for convergence
    _ = gmin_scale;

    return m;
}

// ============================================================================
// Contract validation
// ============================================================================

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "r3_cmc: linear-forced body current, 1V across body" {
    // sw_lin=1 forces I_body = gf * V21 (linear resistor), so the diodes and
    // velocity saturation drop out and the body current is a pure resistor.
    //
    // Geometry: w=l=1e-6 m, scale=1, shrink=0 -> w_um=l_um=1.0.
    //   df = dfinf = 0.01, dp_i = dp = 2.0.
    //   r0 = rsh*l/w*(1 - df*sqrt(dp))
    //      = 100*1*(1 - 0.01*sqrt(2)) = 100*(1 - 0.0141421356) = 98.5857864
    //   gf0 = 1/r0 = 0.0101433...
    // No self-heating contribution to gf here because we drive v_dt so that
    // dT changes tfac; to isolate the linear resistor we set sw_et=0 (v_dt has
    // no effect) and trise=0, so t_dev_k=t_nom_k, dT=0, tfac=1, gf=gf0.
    //   I_body = gf0 * V21, V21 = V(i2)-V(i1) = -1.0 (drive i1=1, i2=0).
    // Body current leaves i1 toward i2: out[int1] contains +i_body_scaled.
    const model: Model = .{ .isa = 0, .isp = 0, .vbv = 0 };
    const inst: Instance = .{ .sw_lin = 1, .sw_et = 0, .c1 = 0, .c2 = 0 };
    // Drive: n1=i1=1, n2=i2=0, nc=0, dt=0. End resistances zero (c1=c2=0 -> ge=GSHORT).
    // To avoid GSHORT dominating, put n1=i1 and n2=i2 (no end-res drop).
    const out = contract.evalValues(Self, .{ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 }, &model, &inst, 0);
    // gf0 = 1/(100*(1 - 0.01*sqrt(2)))
    const df: f64 = 0.01;
    const dp: f64 = 2.0;
    const gf0: f64 = 1.0 / (100.0 * (1.0 - df * @sqrt(dp)));
    // V21 = 0 - 1 = -1 ; i_body = gf0*(-1). out[int1] = +i_body (m=1).
    const expected_int1 = gf0 * (-1.0);
    try testing.expectApproxEqAbs(expected_int1, out[@intFromEnum(U.int1)], 1e-7);
    // out[int2] = -i_body -> +gf0
    try testing.expectApproxEqAbs(-expected_int1, out[@intFromEnum(U.int2)], 1e-7);
    // Charge conservation of body current at the two body nodes:
    try testing.expectApproxEqAbs(out[@intFromEnum(U.int1)], -out[@intFromEnum(U.int2)], 1e-9);
}

test "r3_cmc: forward-biased parasitic diode current" {
    // Isolate diode 1 (area only): isa>0, isp=0, no breakdown, sw_accpo=0.
    // a1_um2 = a1 * (scale*1e6)^2. a1 = 1e-12 m^2 -> a1_um2 = 1e-12*(1e6)^2 = 1.0.
    // na=1, tnom=27 -> t_dev_k=300.15, phi_t = KB*300.15/QQ.
    //   isa_T = isa (r_T=1 so temperature factors are 1).
    //   V_c1 = (V(nc) - V(i1)) * type_ ; type_=-1.
    //   Drive nc=0, i1=-0.4 -> V(nc)-V(i1)=0.4, *type_(-1) = -0.4 (reverse).
    // Use type_=+1 so a positive bias forward-biases: set type_=1, nc=0.5, i1=0.
    //   V_c1 = (0.5-0)*1 = 0.5 forward.
    //   I_area = a1_um2 * isa * (exp(V_c1/(na*phi_t)) - 1) + GMIN*V_c1
    //   i_diode1 = I_area * type_ = same sign.
    //   out[nc] = i_diode1 (m=1). We compute expected by hand below.
    const model: Model = .{ .type_ = 1, .isa = 1e-9, .isp = 0, .vbv = 0, .imax = 1e30, .sw_accpo = 0 };
    const inst: Instance = .{ .a1 = 1e-12, .a2 = 0, .p1 = 0, .p2 = 0, .c1 = 0, .c2 = 0, .sw_et = 0 };
    // n1,nc,n2,int1,int2,dt
    const out = contract.evalValues(Self, .{ 0.0, 0.5, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);

    const kb: f64 = 1.3806505e-23;
    const qq: f64 = 1.6021918e-19;
    const t_dev: f64 = 27.0 + 273.15;
    const phi_t: f64 = kb * t_dev / qq;
    const a1_um2: f64 = 1e-12 * 1e6 * 1e6; // = 1.0
    const isa: f64 = 1e-9;
    const v_c1: f64 = 0.5;
    const i_area: f64 = a1_um2 * isa * (contract.fmath.exp(v_c1 / (1.0 * phi_t)) - 1.0);
    const i_diode1: f64 = (i_area + 1.0e-12 * v_c1) * 1.0; // type_=+1
    // out[nc] = i_diode1 + i_diode2 ; diode2 has a2=0,p2=0 -> only GMIN*v_c2.
    // v_c2 = (0.5 - 0)*1 = 0.5 -> i_diode2 = GMIN*0.5.
    const i_diode2: f64 = 1.0e-12 * 0.5;
    const expected_nc: f64 = i_diode1 + i_diode2;
    try testing.expectApproxEqAbs(expected_nc, out[@intFromEnum(U.nc)], @abs(expected_nc) * 1e-6 + 1e-15);
}

test "r3_cmc: junction charge value" {
    // Reverse-biased junction (V_c1 < 0), area capacitance only, aja<0 so the
    // hard (non-smooth) branch is taken.
    // cja=1e-3 F/um^2, pa=0.75, ma=0.33, fc=0.9, aja=-0.5 (default).
    // a1=1e-12 m^2 -> a1_um2=1.0. type_=1, nc=0, i1=0.3 -> V_c1=(0-0.3)*1=-0.3.
    // r_T=1 (sw_et=0, trise=0): pa_T = max(0.75*1 - 0 - 0, 0.01)=0.75, cja_T=cja.
    // V_c1=-0.3 < fc*pa=0.675, depletion region:
    //   q_dep = pa*cja/(1-ma) * (1 - (1 - V/pa)^(1-ma))
    //         = 0.75*1e-3/0.67 * (1 - (1 - (-0.3)/0.75)^0.67)
    //         = 1.11940e-3 * (1 - (1.4)^0.67)
    // q_p1 = a1_um2 * q_dep (perimeter/fixed 0) * type_(1) * m(1).
    const model: Model = .{ .type_ = 1, .cja = 1e-3, .pa = 0.75, .ma = 0.33, .fc = 0.9, .aja = -0.5, .cjp = 0, .cp = 0, .ca = 0 };
    const inst: Instance = .{ .a1 = 1e-12, .p1 = 0, .a2 = 0, .p2 = 0, .c1 = 0, .c2 = 0, .sw_et = 0 };
    const out = contract.qValues(Self, .{ 0.0, 0.0, 0.0, 0.3, 0.0, 0.0 }, &model, &inst, 0);

    const cja: f64 = 1e-3;
    const pa: f64 = 0.75;
    const ma: f64 = 0.33;
    const v_c1: f64 = -0.3;
    const one_minus_mj: f64 = 1.0 - ma;
    const arg_dep: f64 = 1.0 - v_c1 / pa; // = 1.4
    const q_dep: f64 = pa * cja / one_minus_mj * (1.0 - contract.fmath.exp(one_minus_mj * contract.fmath.log(arg_dep)));
    const a1_um2: f64 = 1.0;
    const expected_int1: f64 = -(a1_um2 * q_dep); // out[int1] = -q_p1
    try testing.expectApproxEqAbs(expected_int1, out[@intFromEnum(U.int1)], @abs(expected_int1) * 1e-6 + 1e-15);
    // out[nc] = q_p1 + q_p2 ; q_p2 has a2=0 -> 0.
    try testing.expectApproxEqAbs(-expected_int1, out[@intFromEnum(U.nc)], @abs(expected_int1) * 1e-6 + 1e-15);
}
