const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// BSIM2 (Berkeley Short-Channel IGFET Model 2)
//
// Topology: D -- RD -- D' (intrinsic drain)
//           S -- RS -- S' (intrinsic source)
//           G (gate), B (bulk)
//           Channel D' <-> S' controlled by gate/bulk voltages
//           Bulk-drain' and bulk-source' junction diodes
//           Gate overlap capacitances G-S', G-D', G-B
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, drain_prime, source_prime };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters
// ============================================================================

pub const Model = struct {
    // --- Device type ---
    type_: i32 = 1, // 1=NMOS, -1=PMOS

    // --- Threshold Voltage Parameters ---
    vfb: f32 = -1.0, // Flat band voltage
    lvfb: f32 = 0.0,
    wvfb: f32 = 0.0,
    phi: f32 = 0.75, // Strong inversion surface potential
    lphi: f32 = 0.0,
    wphi: f32 = 0.0,
    k1: f32 = 0.8, // Bulk effect coefficient 1
    lk1: f32 = 0.0,
    wk1: f32 = 0.0,
    k2: f32 = 0.0, // Bulk effect coefficient 2
    lk2: f32 = 0.0,
    wk2: f32 = 0.0,
    eta0: f32 = 0.0, // VDS dependence of threshold voltage
    leta0: f32 = 0.0,
    weta0: f32 = 0.0,
    etab: f32 = 0.0, // VBS dependence of eta
    letab: f32 = 0.0,
    wetab: f32 = 0.0,

    // --- Geometry Parameters ---
    dl: f32 = 0.0, // Channel length reduction (um)
    dw: f32 = 0.0, // Channel width reduction (um)
    ld: f32 = 0.0, // Lateral diffusion length (m)
    tox: f32 = 0.03, // Gate oxide thickness (um)

    // --- Mobility Parameters ---
    mu0: f32 = 400.0, // Low-field mobility (cm^2/V/s)
    mu0b: f32 = 0.0, // VBS dependence of low-field mobility
    lmu0b: f32 = 0.0,
    wmu0b: f32 = 0.0,
    mus0: f32 = 500.0, // Mobility at VDS=VDD
    lmus0: f32 = 0.0,
    wmus0: f32 = 0.0,
    musb: f32 = 0.0, // VBS dependence of mus
    lmusb: f32 = 0.0,
    wmusb: f32 = 0.0,
    mu20: f32 = 1.5, // VDS dependence of mu in tanh term
    lmu20: f32 = 0.0,
    wmu20: f32 = 0.0,
    mu2b: f32 = 0.0, // VBS dependence of mu2
    lmu2b: f32 = 0.0,
    wmu2b: f32 = 0.0,
    mu2g: f32 = 0.0, // VGS dependence of mu2
    lmu2g: f32 = 0.0,
    wmu2g: f32 = 0.0,
    mu30: f32 = 10.0, // VDS dependence of mu in linear term
    lmu30: f32 = 0.0,
    wmu30: f32 = 0.0,
    mu3b: f32 = 0.0, // VBS dependence of mu3
    lmu3b: f32 = 0.0,
    wmu3b: f32 = 0.0,
    mu3g: f32 = 0.0, // VGS dependence of mu3
    lmu3g: f32 = 0.0,
    wmu3g: f32 = 0.0,
    mu40: f32 = 0.0, // VDS dependence of mu in linear term
    lmu40: f32 = 0.0,
    wmu40: f32 = 0.0,
    mu4b: f32 = 0.0, // VBS dependence of mu4
    lmu4b: f32 = 0.0,
    wmu4b: f32 = 0.0,
    mu4g: f32 = 0.0, // VGS dependence of mu4
    lmu4g: f32 = 0.0,
    wmu4g: f32 = 0.0,

    // --- Gate-Field Mobility Degradation Parameters ---
    ua0: f32 = 0.2, // Linear VGS dependence of mobility
    lua0: f32 = 0.0,
    wua0: f32 = 0.0,
    uab: f32 = 0.0, // VBS dependence of ua
    luab: f32 = 0.0,
    wuab: f32 = 0.0,
    ub0: f32 = 0.0, // Quadratic VGS dependence of mobility
    lub0: f32 = 0.0,
    wub0: f32 = 0.0,
    ubb: f32 = 0.0, // VBS dependence of ub
    lubb: f32 = 0.0,
    wubb: f32 = 0.0,

    // --- Lateral-Field Mobility Parameters ---
    u10: f32 = 0.1, // VDS dependence of mobility
    lu10: f32 = 0.0,
    wu10: f32 = 0.0,
    u1b: f32 = 0.0, // VBS dependence of u1
    lu1b: f32 = 0.0,
    wu1b: f32 = 0.0,
    u1d: f32 = 0.0, // VDS dependence of u1
    lu1d: f32 = 0.0,
    wu1d: f32 = 0.0,

    // --- Subthreshold Parameters ---
    n0: f32 = 1.4, // Subthreshold slope
    ln0: f32 = 0.0,
    wn0: f32 = 0.0,
    nb: f32 = 0.5, // VBS dependence of n
    lnb: f32 = 0.0,
    wnb: f32 = 0.0,
    nd: f32 = 0.0, // VDS dependence of n
    lnd: f32 = 0.0,
    wnd: f32 = 0.0,
    vof0: f32 = 1.8, // Threshold voltage offset
    lvof0: f32 = 0.0,
    wvof0: f32 = 0.0,
    vofb: f32 = 0.0, // VBS dependence of vof
    lvofb: f32 = 0.0,
    wvofb: f32 = 0.0,
    vofd: f32 = 0.0, // VDS dependence of vof
    lvofd: f32 = 0.0,
    wvofd: f32 = 0.0,

    // --- Hot-Electron Effect Parameters ---
    ai0: f32 = 0.0, // Pre-factor of hot-electron effect
    lai0: f32 = 0.0,
    wai0: f32 = 0.0,
    aib: f32 = 0.0, // VBS dependence of ai
    laib: f32 = 0.0,
    waib: f32 = 0.0,
    bi0: f32 = 0.0, // Exponential factor of hot-electron effect
    lbi0: f32 = 0.0,
    wbi0: f32 = 0.0,
    bib: f32 = 0.0, // VBS dependence of bi
    lbib: f32 = 0.0,
    wbib: f32 = 0.0,

    // --- Cubic Spline Bounds ---
    vghigh: f32 = 0.2, // Upper bound of cubic spline function
    lvghigh: f32 = 0.0,
    wvghigh: f32 = 0.0,
    vglow: f32 = -0.15, // Lower bound of cubic spline function
    lvglow: f32 = 0.0,
    wvglow: f32 = 0.0,

    // --- Voltage Clamp / Operating Point Parameters ---
    vdd: f32 = 5.0, // Maximum VDS
    vgg: f32 = 5.0, // Maximum VGS
    vbb: f32 = 5.0, // Maximum VBS
    temp: f32 = 27.0, // Nominal temperature (degC)

    // --- Capacitance Parameters ---
    cgso: f32 = 0.0, // Gate-source overlap cap (F/m)
    cgdo: f32 = 0.0, // Gate-drain overlap cap (F/m)
    cgbo: f32 = 0.0, // Gate-bulk overlap cap (F/m)
    xpart: f32 = 0.0, // Channel charge partitioning flag

    // --- Junction Diode Parameters ---
    js: f32 = 0.0, // Junction saturation current density (A/m^2)
    pb: f32 = 0.8, // Junction built-in potential
    mj: f32 = 0.0, // Bottom junction grading coefficient
    pbsw: f32 = 0.8, // Side junction built-in potential
    mjsw: f32 = 0.0, // Side junction grading coefficient
    cj: f32 = 0.0, // Bottom junction cap (F/m^2)
    cjsw: f32 = 0.0, // Side junction cap (F/m)

    // --- Parasitic Resistance Parameters ---
    rsh: f32 = 0.0, // Sheet resistance (Ohm/sq)
    wdf: f32 = 10.0, // Default diffusion width (um)
    dell: f32 = 0.0, // Length reduction of diffusion (um)

    // --- Noise Parameters ---
    kf: f32 = 0.0, // Flicker noise coefficient
    af: f32 = 1.0, // Flicker noise exponent
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    w: f32 = 5e-6, // Channel width (m)
    l: f32 = 5e-6, // Channel length (m)
    temp: f32 = 300.15, // Device temperature (K)
    m: f32 = 1.0, // Parallel multiplier
};

// ============================================================================
// Sparse Conductance Stamp Pattern
// ============================================================================

pub const g_pattern_override = [_]contract.Entry(n_u){
    // RD branch: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain) },
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain) },
    // RS branch: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source) },
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source) },
    // Channel D' -- S' (incl. gate and bulk dependencies)
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
    // BD junction: B -- D'
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    // Gate row (no DC current, but derivatives may exist)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Gate charges
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.bulk) },
    // Bulk charges
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate) },
    // D' charges
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    // S' charges
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel thermal noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Flicker noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
};

// ============================================================================
// W/L Decomposition Helper
// ============================================================================

inline fn wlDecomp(p0: f64, pl: f64, pw: f64, inv_leff: f64, inv_weff: f64) f64 {
    return p0 + pl * inv_leff + pw * inv_weff;
}

// ============================================================================
// x-independent parameter preparation for the DC current (i / eval).
//
// Everything here is pure f64 (model + instance + geometry + temperature).
// It is hoisted out of `eval` so that the S (derivative-carrying) path only
// covers the x-dependent physics.
// ============================================================================

const CurrentParams = struct {
    type_f: f64,
    gmin: f64,

    // W/L decomposed effective params
    vfb_eff: f64,
    phi_eff: f64,
    k1_eff: f64,
    k2_eff: f64,
    eta0_eff: f64,
    etab_eff: f64,
    mu0: f64,
    mu0b_eff: f64,
    mu20_eff: f64,
    mu2b_eff: f64,
    mu2g_eff: f64,
    mu30_eff: f64,
    mu3b_eff: f64,
    mu3g_eff: f64,
    mu40_eff: f64,
    mu4b_eff: f64,
    mu4g_eff: f64,
    ua0_eff: f64,
    uab_eff: f64,
    ub0_eff: f64,
    ubb_eff: f64,
    n0_eff: f64,
    nb_eff: f64,
    nd_eff: f64,
    vof0_eff: f64,
    vofb_eff: f64,
    vofd_eff: f64,
    ai0_eff: f64,
    aib_eff: f64,
    bi0_eff: f64,
    bib_eff: f64,

    // clamps / thermal / geometry
    v_dd: f64,
    v_gg: f64,
    v_bb: f64,
    vt: f64,
    cox: f64,
    w_eff: f64,
    l_eff: f64,
    m_mult: f64,

    // junction
    js_eff: f64,
    has_clm: bool,

    // parasitic conductances
    g_d: f64,
    g_s: f64,
};

fn currentParams(model: *const Model, instance: *const Instance) CurrentParams {
    // --- Physical constants ---
    const gmin: f64 = 1.0e-12;

    // --- Cast model parameters to f64 ---
    const type_f: f64 = @floatFromInt(model.type_);

    // Geometry
    const dl: f64 = @as(f64, model.dl);
    const dw: f64 = @as(f64, model.dw);
    const tox: f64 = @as(f64, model.tox);

    // Threshold voltage params (base values)
    const vfb_0: f64 = @as(f64, model.vfb);
    const lvfb: f64 = @as(f64, model.lvfb);
    const wvfb: f64 = @as(f64, model.wvfb);
    const phi_0: f64 = @as(f64, model.phi);
    const lphi: f64 = @as(f64, model.lphi);
    const wphi: f64 = @as(f64, model.wphi);
    const k1_0: f64 = @as(f64, model.k1);
    const lk1: f64 = @as(f64, model.lk1);
    const wk1: f64 = @as(f64, model.wk1);
    const k2_0: f64 = @as(f64, model.k2);
    const lk2: f64 = @as(f64, model.lk2);
    const wk2: f64 = @as(f64, model.wk2);
    const eta0_0: f64 = @as(f64, model.eta0);
    const leta0: f64 = @as(f64, model.leta0);
    const weta0: f64 = @as(f64, model.weta0);
    const etab_0: f64 = @as(f64, model.etab);
    const letab: f64 = @as(f64, model.letab);
    const wetab: f64 = @as(f64, model.wetab);

    // Mobility params
    const mu0: f64 = @as(f64, model.mu0);
    const mu0b_0: f64 = @as(f64, model.mu0b);
    const lmu0b: f64 = @as(f64, model.lmu0b);
    const wmu0b: f64 = @as(f64, model.wmu0b);
    const mu20_0: f64 = @as(f64, model.mu20);
    const lmu20: f64 = @as(f64, model.lmu20);
    const wmu20: f64 = @as(f64, model.wmu20);
    const mu2b_0: f64 = @as(f64, model.mu2b);
    const lmu2b: f64 = @as(f64, model.lmu2b);
    const wmu2b: f64 = @as(f64, model.wmu2b);
    const mu2g_0: f64 = @as(f64, model.mu2g);
    const lmu2g: f64 = @as(f64, model.lmu2g);
    const wmu2g: f64 = @as(f64, model.wmu2g);
    const mu30_0: f64 = @as(f64, model.mu30);
    const lmu30: f64 = @as(f64, model.lmu30);
    const wmu30: f64 = @as(f64, model.wmu30);
    const mu3b_0: f64 = @as(f64, model.mu3b);
    const lmu3b: f64 = @as(f64, model.lmu3b);
    const wmu3b: f64 = @as(f64, model.wmu3b);
    const mu3g_0: f64 = @as(f64, model.mu3g);
    const lmu3g: f64 = @as(f64, model.lmu3g);
    const wmu3g: f64 = @as(f64, model.wmu3g);
    const mu40_0: f64 = @as(f64, model.mu40);
    const lmu40: f64 = @as(f64, model.lmu40);
    const wmu40: f64 = @as(f64, model.wmu40);
    const mu4b_0: f64 = @as(f64, model.mu4b);
    const lmu4b: f64 = @as(f64, model.lmu4b);
    const wmu4b: f64 = @as(f64, model.wmu4b);
    const mu4g_0: f64 = @as(f64, model.mu4g);
    const lmu4g: f64 = @as(f64, model.lmu4g);
    const wmu4g: f64 = @as(f64, model.wmu4g);

    // Gate-field mobility degradation
    const ua0_0: f64 = @as(f64, model.ua0);
    const lua0: f64 = @as(f64, model.lua0);
    const wua0: f64 = @as(f64, model.wua0);
    const uab_0: f64 = @as(f64, model.uab);
    const luab: f64 = @as(f64, model.luab);
    const wuab: f64 = @as(f64, model.wuab);
    const ub0_0: f64 = @as(f64, model.ub0);
    const lub0: f64 = @as(f64, model.lub0);
    const wub0: f64 = @as(f64, model.wub0);
    const ubb_0: f64 = @as(f64, model.ubb);
    const lubb: f64 = @as(f64, model.lubb);
    const wubb: f64 = @as(f64, model.wubb);

    // Subthreshold params
    const n0_0: f64 = @as(f64, model.n0);
    const ln0: f64 = @as(f64, model.ln0);
    const wn0: f64 = @as(f64, model.wn0);
    const nb_0: f64 = @as(f64, model.nb);
    const lnb: f64 = @as(f64, model.lnb);
    const wnb: f64 = @as(f64, model.wnb);
    const nd_0: f64 = @as(f64, model.nd);
    const lnd: f64 = @as(f64, model.lnd);
    const wnd: f64 = @as(f64, model.wnd);
    const vof0_0: f64 = @as(f64, model.vof0);
    const lvof0: f64 = @as(f64, model.lvof0);
    const wvof0: f64 = @as(f64, model.wvof0);
    const vofb_0: f64 = @as(f64, model.vofb);
    const lvofb: f64 = @as(f64, model.lvofb);
    const wvofb: f64 = @as(f64, model.wvofb);
    const vofd_0: f64 = @as(f64, model.vofd);
    const lvofd: f64 = @as(f64, model.lvofd);
    const wvofd: f64 = @as(f64, model.wvofd);

    // Hot-electron params
    const ai0_0: f64 = @as(f64, model.ai0);
    const lai0: f64 = @as(f64, model.lai0);
    const wai0: f64 = @as(f64, model.wai0);
    const aib_0: f64 = @as(f64, model.aib);
    const laib: f64 = @as(f64, model.laib);
    const waib: f64 = @as(f64, model.waib);
    const bi0_0: f64 = @as(f64, model.bi0);
    const lbi0: f64 = @as(f64, model.lbi0);
    const wbi0: f64 = @as(f64, model.wbi0);
    const bib_0: f64 = @as(f64, model.bib);
    const lbib: f64 = @as(f64, model.lbib);
    const wbib: f64 = @as(f64, model.wbib);

    // Operating point clamps
    const v_dd: f64 = @as(f64, model.vdd);
    const v_gg: f64 = @as(f64, model.vgg);
    const v_bb: f64 = @as(f64, model.vbb);

    // Junction params
    const js_param: f64 = @as(f64, model.js);
    const rsh: f64 = @as(f64, model.rsh);

    // --- Cast instance parameters to f64 ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);
    const t_dev: f64 = @as(f64, instance.temp);
    const m_mult: f64 = @as(f64, instance.m);

    // ------------------------------------------------------------------------
    // Effective dimensions
    // ------------------------------------------------------------------------
    // dl and dw are in um, but w_inst and l_inst are in m
    // Convert dl/dw from um to m
    const l_eff: f64 = @max(l_inst - dl * 1.0e-6, 1.0e-9);
    const w_eff: f64 = @max(w_inst - dw * 1.0e-6, 1.0e-9);

    // W/L decomposition factors: P_eff = P0 + PL * 1e-6/L_eff + PW * 1e-6/W_eff
    const inv_leff: f64 = 1.0e-6 / l_eff;
    const inv_weff: f64 = 1.0e-6 / w_eff;

    // ------------------------------------------------------------------------
    // Thermal voltage
    // ------------------------------------------------------------------------
    const vt: f64 = 8.617333e-5 * t_dev;

    // ------------------------------------------------------------------------
    // Oxide capacitance
    // ------------------------------------------------------------------------
    const eps_ox: f64 = 3.453e-11;
    const tox_m: f64 = @max(tox * 1.0e-6, 1.0e-12);
    const cox: f64 = eps_ox / tox_m;

    // ------------------------------------------------------------------------
    // Junction saturation current, CLM enable, parasitic conductances
    // ------------------------------------------------------------------------
    const js_eff: f64 = @max(js_param, 1.0e-15);
    const has_clm = (ai0_0 != 0.0 or aib_0 != 0.0 or lai0 != 0.0 or wai0 != 0.0 or laib != 0.0 or waib != 0.0);
    const g_d: f64 = if (rsh != 0.0) 1.0 / rsh else 1.0e12;
    const g_s: f64 = if (rsh != 0.0) 1.0 / rsh else 1.0e12;

    return .{
        .type_f = type_f,
        .gmin = gmin,
        .vfb_eff = wlDecomp(vfb_0, lvfb, wvfb, inv_leff, inv_weff),
        .phi_eff = wlDecomp(phi_0, lphi, wphi, inv_leff, inv_weff),
        .k1_eff = wlDecomp(k1_0, lk1, wk1, inv_leff, inv_weff),
        .k2_eff = wlDecomp(k2_0, lk2, wk2, inv_leff, inv_weff),
        .eta0_eff = wlDecomp(eta0_0, leta0, weta0, inv_leff, inv_weff),
        .etab_eff = wlDecomp(etab_0, letab, wetab, inv_leff, inv_weff),
        .mu0 = mu0,
        .mu0b_eff = wlDecomp(mu0b_0, lmu0b, wmu0b, inv_leff, inv_weff),
        .mu20_eff = wlDecomp(mu20_0, lmu20, wmu20, inv_leff, inv_weff),
        .mu2b_eff = wlDecomp(mu2b_0, lmu2b, wmu2b, inv_leff, inv_weff),
        .mu2g_eff = wlDecomp(mu2g_0, lmu2g, wmu2g, inv_leff, inv_weff),
        .mu30_eff = wlDecomp(mu30_0, lmu30, wmu30, inv_leff, inv_weff),
        .mu3b_eff = wlDecomp(mu3b_0, lmu3b, wmu3b, inv_leff, inv_weff),
        .mu3g_eff = wlDecomp(mu3g_0, lmu3g, wmu3g, inv_leff, inv_weff),
        .mu40_eff = wlDecomp(mu40_0, lmu40, wmu40, inv_leff, inv_weff),
        .mu4b_eff = wlDecomp(mu4b_0, lmu4b, wmu4b, inv_leff, inv_weff),
        .mu4g_eff = wlDecomp(mu4g_0, lmu4g, wmu4g, inv_leff, inv_weff),
        .ua0_eff = wlDecomp(ua0_0, lua0, wua0, inv_leff, inv_weff),
        .uab_eff = wlDecomp(uab_0, luab, wuab, inv_leff, inv_weff),
        .ub0_eff = wlDecomp(ub0_0, lub0, wub0, inv_leff, inv_weff),
        .ubb_eff = wlDecomp(ubb_0, lubb, wubb, inv_leff, inv_weff),
        .n0_eff = wlDecomp(n0_0, ln0, wn0, inv_leff, inv_weff),
        .nb_eff = wlDecomp(nb_0, lnb, wnb, inv_leff, inv_weff),
        .nd_eff = wlDecomp(nd_0, lnd, wnd, inv_leff, inv_weff),
        .vof0_eff = wlDecomp(vof0_0, lvof0, wvof0, inv_leff, inv_weff),
        .vofb_eff = wlDecomp(vofb_0, lvofb, wvofb, inv_leff, inv_weff),
        .vofd_eff = wlDecomp(vofd_0, lvofd, wvofd, inv_leff, inv_weff),
        .ai0_eff = wlDecomp(ai0_0, lai0, wai0, inv_leff, inv_weff),
        .aib_eff = wlDecomp(aib_0, laib, waib, inv_leff, inv_weff),
        .bi0_eff = wlDecomp(bi0_0, lbi0, wbi0, inv_leff, inv_weff),
        .bib_eff = wlDecomp(bib_0, lbib, wbib, inv_leff, inv_weff),
        .v_dd = v_dd,
        .v_gg = v_gg,
        .v_bb = v_bb,
        .vt = vt,
        .cox = cox,
        .w_eff = w_eff,
        .l_eff = l_eff,
        .m_mult = m_mult,
        .js_eff = js_eff,
        .has_clm = has_clm,
        .g_d = g_d,
        .g_s = g_s,
    };
}

pub const PrepCache = struct { dc: CurrentParams, q: ChargeParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = currentParams(model, instance), .q = chargeParams(model, instance) };
}

// ============================================================================
// DC Current Function (value-form eval)
//
// x reads: gate, source_prime, drain_prime, bulk (terminal voltages) and the
// parasitic-resistor endpoints drain, source. Everything downstream of the
// terminal voltages is carried through the S scalar so the Jacobian is exact.
// Region selection (subthreshold vs strong inversion, CLM enable) branches on
// .val() exactly where the original code branched on the corresponding f64.
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const p = &pc.dc;

    // ------------------------------------------------------------------------
    // Terminal Voltages and Source/Drain Swap  (S ops from here)
    // ------------------------------------------------------------------------
    const vgs_raw = x[g].sub(x[sp]).scale(p.type_f);
    const vds_raw = x[dp].sub(x[sp]).scale(p.type_f);
    const vbs_raw = x[b].sub(x[sp]).scale(p.type_f);

    // Source/drain reversal when vds_raw < 0
    const vds_neg = vds_raw.minC(0.0);
    const vbs_eff = vbs_raw.sub(vds_neg).maxC(-p.v_bb);
    const vgs_eff = vgs_raw.sub(vds_neg).minC(p.v_gg);
    const vds_eff = vds_raw.abs().minC(p.v_dd);

    // Mode sign for S/D reversal: mode = vds_raw / (|vds_raw| + 1e-30)
    const mode = vds_raw.div(vds_raw.abs().addC(1.0e-30));

    // ------------------------------------------------------------------------
    // Threshold Voltage
    // ------------------------------------------------------------------------
    // Surface potential with body effect
    const vbs_clamp = vbs_eff.maxC(-p.phi_eff + 0.01);
    // phi_sb = phi_eff^2 / max(phi_eff + vbs_clamp, 0.01)
    const phi_sb = S.con(p.phi_eff * p.phi_eff).div(vbs_clamp.addC(p.phi_eff).maxC(0.01));
    const t1s = phi_sb.sqrt();

    // DIBL coefficient: eta = eta0_eff + etab_eff * vbs_eff
    const eta = vbs_eff.scale(p.etab_eff).addC(p.eta0_eff);

    // Threshold voltage:
    //   vth = vfb_eff + phi_eff + k1_eff*t1s - k2_eff*phi_sb - eta*vds_eff
    const vth = t1s.scale(p.k1_eff)
        .addC(p.vfb_eff + p.phi_eff)
        .sub(phi_sb.scale(p.k2_eff))
        .sub(eta.mul(vds_eff));

    // ------------------------------------------------------------------------
    // Subthreshold Region
    // ------------------------------------------------------------------------
    // n_sub = n0_eff + nb_eff*vbs_eff + nd_eff*vds_eff
    const n_sub = vbs_eff.scale(p.nb_eff).add(vds_eff.scale(p.nd_eff)).addC(p.n0_eff);
    // vof = vof0_eff + vofb_eff*vbs_eff + vofd_eff*vds_eff
    const vof = vbs_eff.scale(p.vofb_eff).add(vds_eff.scale(p.vofd_eff)).addC(p.vof0_eff);
    const von = vth.add(vof);

    // Subthreshold factor:
    //   sub_arg = max(min((vgs_eff - von)/(n_sub*vt), 0), -80)
    //   f_sub   = if vgs_eff >= von then 1 else exp(sub_arg)
    const sub_arg = vgs_eff.sub(von).div(n_sub.scale(p.vt)).minC(0.0).maxC(-80.0);
    const f_sub = if (vgs_eff.val() >= von.val()) S.con(1.0) else sub_arg.exp();

    // ------------------------------------------------------------------------
    // Mobility Model
    // ------------------------------------------------------------------------
    // Gate-field mobility degradation
    const ua = vbs_eff.scale(p.uab_eff).addC(p.ua0_eff);
    const ub = vbs_eff.scale(p.ubb_eff).addC(p.ub0_eff);

    // Gate overdrive (clamped positive): vov = max(vgs_eff - vth, 0)
    const vov = vgs_eff.sub(vth).maxC(0.0);

    // Vertical field degradation factor:
    //   u_vert = max(1 + vov*(ua + vov*ub), 0.2)
    const u_vert = vov.mul(ub).add(ua).mul(vov).addC(1.0).maxC(0.2);

    // ------------------------------------------------------------------------
    // Saturation Voltage
    // ------------------------------------------------------------------------
    const vdsat = vov.div(u_vert).maxC(1.0e-18);

    // ------------------------------------------------------------------------
    // Transconductance Parameter (Beta)
    // ------------------------------------------------------------------------
    // beta0_base = (mu0 + mu0b_eff*vbs_eff) * 1e-4 * cox * w_eff / l_eff
    const beta0_base = vbs_eff.scale(p.mu0b_eff).addC(p.mu0)
        .scale(1.0e-4 * p.cox * p.w_eff / p.l_eff);

    // VDS-dependent beta factors
    // beta2 = mu20_eff + mu2b_eff*vbs_eff + mu2g_eff*vgs_eff
    const beta2 = vbs_eff.scale(p.mu2b_eff).add(vgs_eff.scale(p.mu2g_eff)).addC(p.mu20_eff);
    // beta3 = mu30_eff + mu3b_eff*vbs_eff + mu3g_eff*vgs_eff
    const beta3 = vbs_eff.scale(p.mu3b_eff).add(vgs_eff.scale(p.mu3g_eff)).addC(p.mu30_eff);
    // beta4 = mu40_eff + mu4b_eff*vbs_eff + mu4g_eff*vgs_eff
    const beta4 = vbs_eff.scale(p.mu4b_eff).add(vgs_eff.scale(p.mu4g_eff)).addC(p.mu40_eff);

    // Tanh argument (clamped to [-30, 30]): x_beta = clamp(beta3*vds_eff)
    const x_beta = beta3.mul(vds_eff).minC(30.0).maxC(-30.0);
    const tanh_x = x_beta.tanh();

    // Beta multiplicative correction:
    //   f_beta = max(1 - beta2*(tanh_x - beta3*vds_eff) - beta4*vds_eff, 0.1)
    const f_beta = S.con(1.0)
        .sub(beta2.mul(tanh_x.sub(beta3.mul(vds_eff))))
        .sub(beta4.mul(vds_eff))
        .maxC(0.1);

    // Final transconductance parameter
    const beta = beta0_base.mul(f_beta);

    // ------------------------------------------------------------------------
    // Drain Current
    // ------------------------------------------------------------------------
    // Effective channel voltage (smooth triode/saturation unification)
    const vds_ch = vds_eff.min(vdsat);

    // Core drain current: ids_core = beta * (vov - vds_ch*0.5) * vds_ch
    const ids_core = beta.mul(vov.sub(vds_ch.scale(0.5))).mul(vds_ch);

    // ------------------------------------------------------------------------
    // Channel Length Modulation (Hot-Electron Effect)
    // ------------------------------------------------------------------------
    const ai = vbs_eff.scale(p.aib_eff).addC(p.ai0_eff);
    const bi = vbs_eff.scale(p.bib_eff).addC(p.bi0_eff);

    // Excess drain voltage: delta_vds = max(vds_eff - vdsat, 1e-20)
    const delta_vds = vds_eff.sub(vdsat).maxC(1.0e-20);

    // CLM factor: only when ai0 or aib are nonzero
    //   clm_exp_arg = min(bi/delta_vds, 30)
    //   f_clm = if has_clm then 1 + ai*exp(-clm_exp_arg) else 1
    const clm_exp_arg = bi.div(delta_vds).minC(30.0);
    const f_clm = if (p.has_clm) ai.mul(clm_exp_arg.neg().exp()).addC(1.0) else S.con(1.0);

    // ------------------------------------------------------------------------
    // Full Drain Current
    // ------------------------------------------------------------------------
    const ids_strong = ids_core.mul(f_clm).maxC(0.0);
    const ids_intrinsic = ids_strong.mul(f_sub);
    // i_ds = (ids_intrinsic + gmin*vds_eff) * m_mult * type_f
    const i_ds = ids_intrinsic.add(vds_eff.scale(p.gmin)).scale(p.m_mult * p.type_f);

    // ------------------------------------------------------------------------
    // Junction Diode Currents
    // ------------------------------------------------------------------------
    // Bulk-source and bulk-drain voltages (in type-adjusted coordinates)
    const vbd = vbs_eff.sub(vds_eff);

    // Source-bulk junction:
    //   arg_bs = min(vbs_eff/vt, 80)
    //   i_bs = m_mult * (js_eff*(exp(arg_bs) - 1) + gmin*vbs_eff)
    const arg_bs = vbs_eff.scale(1.0 / p.vt).minC(80.0);
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.js_eff).add(vbs_eff.scale(p.gmin)).scale(p.m_mult);

    // Drain-bulk junction:
    //   arg_bd = min(vbd/vt, 80)
    //   i_bd = m_mult * (js_eff*(exp(arg_bd) - 1) + gmin*vbd)
    const arg_bd = vbd.scale(1.0 / p.vt).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.js_eff).add(vbd.scale(p.gmin)).scale(p.m_mult);

    // ------------------------------------------------------------------------
    // Parasitic Resistances
    // ------------------------------------------------------------------------
    const i_rd = x[d].sub(x[dp]).scale(p.g_d);
    const i_rs = x[s].sub(x[sp]).scale(p.g_s);

    // ------------------------------------------------------------------------
    // KCL Node Assembly
    // ------------------------------------------------------------------------
    // Note: i_ds already has the mode*type_f baked in.
    // For S/D reversal, channel current direction is handled by 'mode'.
    const i_ds_mode = i_ds.mul(mode);

    var out: [n_u]S = undefined;
    out[d] = i_rd.neg();
    out[g] = S.con(0.0);
    out[s] = i_rs.neg();
    out[b] = i_bs.neg().sub(i_bd);
    out[dp] = i_rd.add(i_ds_mode).add(i_bd);
    out[sp] = i_rs.sub(i_ds_mode).add(i_bs);
    return out;
}

// ============================================================================
// x-independent parameter preparation for the charge function (q).
// ============================================================================

const ChargeParams = struct {
    cgso: f64,
    cgdo: f64,
    cgbo: f64,
    vfb_eff: f64,
    phi_eff: f64,
    pb_val: f64,
    mj_val: f64,
    pbsw_val: f64,
    mjsw_val: f64,
    cj_val: f64,
    cjsw_val: f64,
    w_eff: f64,
    l_eff: f64,
    m_mult: f64,
    cox_wl: f64,
    type_f: f64,
    one_m_mj: f64,
    one_m_mjsw: f64,
};

fn chargeParams(model: *const Model, instance: *const Instance) ChargeParams {
    // --- Cast model parameters to f64 ---
    const cgso: f64 = @as(f64, model.cgso);
    const cgdo: f64 = @as(f64, model.cgdo);
    const cgbo: f64 = @as(f64, model.cgbo);
    const tox: f64 = @as(f64, model.tox);
    const vfb_0: f64 = @as(f64, model.vfb);
    const lvfb: f64 = @as(f64, model.lvfb);
    const wvfb: f64 = @as(f64, model.wvfb);
    const phi_0: f64 = @as(f64, model.phi);
    const lphi: f64 = @as(f64, model.lphi);
    const wphi: f64 = @as(f64, model.wphi);
    const dl: f64 = @as(f64, model.dl);
    const dw: f64 = @as(f64, model.dw);
    const pb_val: f64 = @as(f64, model.pb);
    const mj_val: f64 = @as(f64, model.mj);
    const pbsw_val: f64 = @as(f64, model.pbsw);
    const mjsw_val: f64 = @as(f64, model.mjsw);
    const cj_val: f64 = @as(f64, model.cj);
    const cjsw_val: f64 = @as(f64, model.cjsw);

    // --- Cast instance parameters ---
    const w_inst: f64 = @as(f64, instance.w);
    const l_inst: f64 = @as(f64, instance.l);
    const m_mult: f64 = @as(f64, instance.m);

    // --- Effective dimensions ---
    const l_eff: f64 = @max(l_inst - dl * 1.0e-6, 1.0e-9);
    const w_eff: f64 = @max(w_inst - dw * 1.0e-6, 1.0e-9);

    // W/L decomposition factors
    const inv_leff: f64 = 1.0e-6 / l_eff;
    const inv_weff: f64 = 1.0e-6 / w_eff;

    const vfb_eff = wlDecomp(vfb_0, lvfb, wvfb, inv_leff, inv_weff);
    const phi_eff = wlDecomp(phi_0, lphi, wphi, inv_leff, inv_weff);

    // Oxide capacitance
    const eps_ox: f64 = 3.453e-11;
    const tox_m: f64 = @max(tox * 1.0e-6, 1.0e-12);
    const cox_val: f64 = eps_ox / tox_m;
    const cox_wl: f64 = cox_val * w_eff * l_eff;

    const type_f: f64 = @floatFromInt(model.type_);

    const one_m_mj = @max(1.0 - mj_val, 0.01);
    const one_m_mjsw = @max(1.0 - mjsw_val, 0.01);

    return .{
        .cgso = cgso,
        .cgdo = cgdo,
        .cgbo = cgbo,
        .vfb_eff = vfb_eff,
        .phi_eff = phi_eff,
        .pb_val = pb_val,
        .mj_val = mj_val,
        .pbsw_val = pbsw_val,
        .mjsw_val = mjsw_val,
        .cj_val = cj_val,
        .cjsw_val = cjsw_val,
        .w_eff = w_eff,
        .l_eff = l_eff,
        .m_mult = m_mult,
        .cox_wl = cox_wl,
        .type_f = type_f,
        .one_m_mj = one_m_mj,
        .one_m_mjsw = one_m_mjsw,
    };
}

// Junction depletion charge (value-form), shared by BS and BD junctions.
// Reproduces the original sigmoid-blended forward/reverse depletion charge,
// with the forward/reverse selection driven by .val() (matching the original
// tanh-sigmoid saturating hard around v=0).
fn junctionCharge(comptime S: type, v: S, p: *const ChargeParams) S {
    // Sigmoid blend for forward/reverse:
    //   sig_arg = clamp(100*v, [-30, 30])
    //   sigma   = 0.5*(1 + tanh(sig_arg))
    const sig_arg = v.scale(100.0).minC(30.0).maxC(-30.0);
    const sigma = sig_arg.tanh().addC(1.0).scale(0.5);

    // Forward bias charge (VBS >= 0):
    //   q_fwd = v*(cj + cjsw)
    //         + v^2 * (cj*mj/(2*pb) + cjsw*mjsw/(2*pbsw))
    const q_fwd = v.scale(p.cj_val + p.cjsw_val)
        .add(v.mul(v).scale(p.cj_val * p.mj_val / (2.0 * p.pb_val) +
        p.cjsw_val * p.mjsw_val / (2.0 * p.pbsw_val)));

    // Reverse bias charge (VBS < 0):
    //   arg     = max(1 - v/pb, 0.01)
    //   arg_sw  = max(1 - v/pbsw, 0.01)
    //   sarg    = exp(one_m_mj * log(arg))       (= arg^(1-mj))
    //   sarg_sw = exp(one_m_mjsw * log(arg_sw))
    //   q_rev   = (pb*cj/one_m_mj)*(1 - arg*sarg)
    //           + (pbsw*cjsw/one_m_mjsw)*(1 - arg_sw*sarg_sw)
    const arg = v.scale(-1.0 / p.pb_val).addC(1.0).maxC(0.01);
    const arg_sw = v.scale(-1.0 / p.pbsw_val).addC(1.0).maxC(0.01);
    const sarg = arg.log().scale(p.one_m_mj).exp();
    const sarg_sw = arg_sw.log().scale(p.one_m_mjsw).exp();

    const q_rev = S.con(1.0).sub(arg.mul(sarg)).scale(p.pb_val * p.cj_val / p.one_m_mj)
        .add(S.con(1.0).sub(arg_sw.mul(sarg_sw)).scale(p.pbsw_val * p.cjsw_val / p.one_m_mjsw));

    // Blended charge: q = ((1 - sigma)*q_rev + sigma*q_fwd) * m_mult
    const one_minus_sigma = S.con(1.0).sub(sigma);
    return one_minus_sigma.mul(q_rev).add(sigma.mul(q_fwd)).scale(p.m_mult);
}

// ============================================================================
// Charge Function (value-form q)
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, _: *const Model, _: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const p = &pc.q;

    // ------------------------------------------------------------------------
    // Voltages for charge computation  (S ops from here)
    // ------------------------------------------------------------------------
    const v_gs_prime = x[g].sub(x[sp]);
    const v_gd_prime = x[g].sub(x[dp]);
    const v_gb = x[g].sub(x[b]);
    const v_bs_prime = x[b].sub(x[sp]);
    const v_bd_prime = x[b].sub(x[dp]);

    // ------------------------------------------------------------------------
    // Gate Overlap Charges
    // ------------------------------------------------------------------------
    const q_gso = v_gs_prime.scale(p.cgso * p.w_eff);
    const q_gdo = v_gd_prime.scale(p.cgdo * p.w_eff);
    const q_gbo = v_gb.scale(p.cgbo * p.l_eff);

    // ------------------------------------------------------------------------
    // Intrinsic Gate Charge (Simplified Meyer)
    // ------------------------------------------------------------------------
    // Use type-adjusted VGS for intrinsic charge
    //   q_g_intr = cox_wl * (vgs_q - vfb_eff - phi_eff*0.5)
    const vgs_q = v_gs_prime.scale(p.type_f);
    const q_g_intr = vgs_q.addC(-p.vfb_eff - p.phi_eff * 0.5).scale(p.cox_wl);

    // ------------------------------------------------------------------------
    // Junction Depletion Charges (BS, BD)
    // ------------------------------------------------------------------------
    const q_bs = junctionCharge(S, v_bs_prime, p);
    const q_bd = junctionCharge(S, v_bd_prime, p);

    // ------------------------------------------------------------------------
    // Charge Node Stamps
    // ------------------------------------------------------------------------
    var out: [n_u]S = undefined;
    out[d] = S.con(0.0);
    out[g] = q_gso.add(q_gdo).add(q_gbo).add(q_g_intr);
    out[s] = S.con(0.0);
    out[b] = q_gbo.neg().sub(q_g_intr).add(q_bs).add(q_bd);
    out[dp] = q_gdo.neg().sub(q_bd);
    out[sp] = q_gso.neg().sub(q_bs);
    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, _: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const js_param: f64 = @as(f64, model.js);
    const js_eff: f64 = @max(js_param, 1.0e-15);
    const vfb_0: f64 = @as(f64, model.vfb);
    const phi_0: f64 = @as(f64, model.phi);
    const k1_0: f64 = @as(f64, model.k1);
    const temp_c: f64 = @as(f64, model.temp);
    const vt: f64 = 8.617333e-5 * (temp_c + 273.15);

    // Simplified threshold for limiting
    const vth_lim = vfb_0 + phi_0 + k1_0 * @sqrt(@max(phi_0, 1.0e-20));

    var result = x_new;

    // ========================================================================
    // PN Junction Limiting (pnjlim) for V_BS
    // ========================================================================
    {
        const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * js_eff));
        const vbs_new = x_new[b] - x_new[sp];
        const vbs_old = x_old[b] - x_old[sp];
        var vbs_limited = vbs_new;

        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = 1.0 + (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * contract.fmath.log(arg);
                } else {
                    vbs_limited = v_crit;
                }
            } else {
                vbs_limited = vt * contract.fmath.log(vbs_new / vt);
            }
        }

        const delta_bs = vbs_limited - vbs_new;
        result[sp] = result[sp] - delta_bs;
    }

    // ========================================================================
    // PN Junction Limiting (pnjlim) for V_BD
    // ========================================================================
    {
        const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * js_eff));
        const vbd_new = x_new[b] - x_new[dp];
        const vbd_old = x_old[b] - x_old[dp];
        var vbd_limited = vbd_new;

        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = 1.0 + (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * contract.fmath.log(arg);
                } else {
                    vbd_limited = v_crit;
                }
            } else {
                vbd_limited = vt * contract.fmath.log(vbd_new / vt);
            }
        }

        const delta_bd = vbd_limited - vbd_new;
        result[dp] = result[dp] - delta_bd;
    }

    // ========================================================================
    // FET Gate Voltage Limiting (fetlim) for V_GS
    // ========================================================================
    {
        const vgs_new = result[g] - result[sp];
        const vgs_old = x_old[g] - x_old[sp];
        const dv = vgs_new - vgs_old;
        const vtsthi = @abs(2.0 * (vgs_old - vth_lim)) + 2.0;
        const vtstlo = vtsthi * 0.5 + 2.0;
        const vtox = vth_lim + 3.5;
        var vgs_limited = vgs_new;

        if (vgs_old >= vth_lim and vgs_old >= vtox) {
            // Region: Vold >= Vth and Vold >= Vtox
            if (dv <= 0.0) {
                // Decreasing
                if (vgs_new >= vtox) {
                    vgs_limited = @max(vgs_new, vgs_old - vtsthi);
                } else {
                    vgs_limited = @max(vgs_new, vth_lim + 2.0);
                }
            } else {
                // Increasing
                vgs_limited = @min(vgs_new, vgs_old + vtsthi);
            }
        } else if (vgs_old >= vth_lim) {
            // Region: Vold >= Vth and Vold < Vtox
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vth_lim - 0.5);
            } else {
                vgs_limited = @min(vgs_new, vgs_old + vtstlo);
            }
        } else {
            // Region: Vold < Vth (off)
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vgs_old - vtsthi);
            } else {
                vgs_limited = @min(vgs_new, vgs_old + vtstlo);
            }
        }

        const delta_gs = vgs_limited - vgs_new;
        result[g] = result[g] + delta_gs;
    }

    // ========================================================================
    // VDS Limiting (limvds)
    // ========================================================================
    {
        const vds_new = result[dp] - result[sp];
        const vds_old = x_old[dp] - x_old[sp];
        var vds_limited = vds_new;

        if (vds_old >= 3.5) {
            if (vds_new > vds_old) {
                vds_limited = @min(vds_new, 3.0 * vds_old + 2.0);
            } else if (vds_new < 3.5) {
                vds_limited = @max(vds_new, 2.0);
            }
            // else: vds_new stays as is
        } else {
            if (vds_new > vds_old) {
                vds_limited = @min(vds_new, 4.0);
            } else {
                vds_limited = @max(vds_new, -0.5);
            }
        }

        const delta_ds = vds_limited - vds_new;
        result[dp] = result[dp] + delta_ds;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    const gmin_step: f64 = 1.0e-12;
    const js_orig: f64 = @as(f64, model.js);
    // Scale JS towards gmin for easier convergence when lambda < 1
    const js_stepped = js_orig + (gmin_step - js_orig) * (1.0 - lambda);
    m.js = @floatCast(js_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "bsim2: strong-inversion / saturation drain current (NMOS)" {
    // Default NMOS: vfb=-1, phi=0.75, k1=0.8, k2=0, eta0=0, ua0=0.2, ub0=0,
    // mu0=400, mu20=1.5, mu30=10, mu40=0, tox=0.03um, W=L=5u, temp=300.15K,
    // rsh=0 (=> g_d=g_s=1e12), js=0 (=> js_eff=1e-15), has_clm=false.
    //
    // Bias: VG=3, VD=3, VS=0, VB=0, node d=dp=3, s=sp=0.
    //   vgs_raw = 3, vds_raw = 3, vbs_raw = 0  (type_f=1)
    //   vds_neg = 0; vbs_eff = 0; vgs_eff = min(3,vgg=5)=3; vds_eff=min(3,vdd=5)=3
    //   mode = 3/(3+1e-30) = 1
    //   inv_leff = 1e-6/5e-6 = 0.2, inv_weff = 0.2 (no L/W params so eff=base)
    //   vbs_clamp = max(0, -0.75+0.01)=0
    //   phi_sb = 0.75^2 / max(0.75+0, 0.01) = 0.5625/0.75 = 0.75
    //   t1s = sqrt(0.75) = 0.8660254038
    //   eta = 0; vth = -1 + 0.75 + 0.8*0.8660254038 - 0 - 0
    //       = -0.25 + 0.6928203230 = 0.4428203230
    //   n_sub=1.4, vof = 1.8, von = vth+1.8 = 2.2428203230
    //   vgs_eff(3) >= von(2.2428) => f_sub = 1
    //   ua=0.2, ub=0; vov = 3 - 0.4428203230 = 2.5571796770
    //   u_vert = max(1 + 2.5571796770*(0.2 + 0), 0.2) = 1 + 0.5114359354 = 1.5114359354
    //   vdsat = 2.5571796770 / 1.5114359354 = 1.6919127419
    //   eps_ox=3.453e-11, tox_m=0.03e-6=3e-8, cox=3.453e-11/3e-8=1.151e-3
    //   beta0_base = (400 + 0)*1e-4 * 1.151e-3 * 5e-6/5e-6
    //              = 0.04 * 1.151e-3 * 1 = 4.604e-5
    //   beta2=1.5, beta3=10, beta4=0
    //   x_beta = clamp(10*3,[-30,30]) = 30
    //   tanh(30) ~= 1.0
    //   f_beta = max(1 - 1.5*(1 - 10*3) - 0, 0.1) = 1 - 1.5*(-29) = 1 + 43.5 = 44.5
    //   beta = 4.604e-5 * 44.5 = 2.048780e-3
    //   vds_ch = min(vds_eff=3, vdsat=1.6919127419) = 1.6919127419
    //   ids_core = beta*(vov - vds_ch*0.5)*vds_ch
    //            = 2.048780e-3*(2.5571796770 - 0.8459563710)*1.6919127419
    //            = 2.048780e-3*1.7112233060*1.6919127419
    //   1.7112233060*1.6919127419 = 2.895344...  -> *2.048780e-3 = 5.932197e-3
    //   f_clm = 1 (has_clm false); ids_strong = 5.932197e-3; f_sub=1
    //   i_ds = (5.932197e-3 + 1e-12*3)*1*1 ~= 5.932197e-3
    //   i_ds_mode = i_ds*1
    //   junctions: vbs_eff=0 -> i_bs = 1*(1e-15*(e^0-1)+1e-12*0)=0
    //              vbd = vbs_eff - vds_eff = -3 -> arg_bd=min(-3/vt,80)= -3/vt
    //                i_bd = 1e-15*(exp(-3/vt)-1) + 1e-12*(-3)
    //                     ~= 1e-15*(-1) - 3e-12 = -3.001e-12 (negligible)
    //   parasitics: i_rd = 1e12*(3-3)=0, i_rs = 1e12*(0-0)=0
    //   out[dp] = i_rd + i_ds_mode + i_bd ~= 5.932197e-3
    //   out[sp] = i_rs - i_ds_mode + i_bs ~= -5.932197e-3
    const model: Model = .{};
    const inst: Instance = .{};
    // node order: drain, gate, source, bulk, drain_prime, source_prime
    const out = contract.evalValues(Self, .{ 3.0, 3.0, 0.0, 0.0, 3.0, 0.0 }, &model, &inst, 0);
    // dp current ~ +5.932e-3, sp current ~ -5.932e-3 (drain conducts into channel)
    try testing.expectApproxEqAbs(@as(f64, 5.932197e-3), out[@intFromEnum(U.drain_prime)], 1e-6);
    try testing.expectApproxEqAbs(@as(f64, -5.932197e-3), out[@intFromEnum(U.source_prime)], 1e-6);
    // gate carries no DC current
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.gate)], 1e-15);
}

test "bsim2: subthreshold (VGS below von) gives near-zero drain current" {
    // Same device, VG=0.2 (well below von ~ 2.24), VD=1, VS=VB=0.
    //   vgs_eff = 0.2, vds_eff = 1, vbs_eff = 0
    //   vth (with vds_eff=1, eta=0) = same threshold core = 0.4428203230
    //   von = vth + 1.8 = 2.2428203230; vgs_eff(0.2) < von => f_sub = exp(sub_arg)
    //   sub_arg = max(min((0.2 - 2.2428203230)/(1.4*vt), 0), -80)
    //     vt = 8.617333e-5*300.15 = 0.025864... ; 1.4*vt = 0.036210...
    //     (0.2-2.2428203230)/0.036210 = -56.42... -> clamped in [-80,0] = -56.42
    //   f_sub = exp(-56.42) ~ 3.1e-25 (essentially zero)
    //   vov = max(0.2 - 0.4428203230, 0) = 0 => ids_core = 0
    //   => i_ds ~ gmin*vds_eff*f_sub-ish, but ids_strong=0 so intrinsic=0
    //   i_ds = (0 + 1e-12*1) = 1e-12  (only the gmin leakage term)
    // So drain_prime current is ~1e-12 (gmin), essentially zero.
    const model: Model = .{};
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.2, 0.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), out[@intFromEnum(U.drain_prime)], 1e-9);
}

test "bsim2: gate overlap charge (linear cgso/cgdo/cgbo)" {
    // Enable overlap caps: cgso=cgdo=1e-9 F/m, cgbo=2e-9 F/m, W=L=5u.
    // js/cj/cjsw = 0 so junction depletion charges are 0.
    // Bias: VG=1, all others 0 => node g=1, sp=dp=b=0.
    //   v_gs_prime = 1, v_gd_prime = 1, v_gb = 1
    //   q_gso = cgso*w_eff*v_gs = 1e-9*5e-6*1 = 5e-15
    //   q_gdo = cgdo*w_eff*v_gd = 5e-15
    //   q_gbo = cgbo*l_eff*v_gb = 2e-9*5e-6*1 = 1e-14
    //   type_f=1, vfb_eff=-1, phi_eff=0.75
    //   cox = 3.453e-11/3e-8 = 1.151e-3 ; cox_wl = 1.151e-3*5e-6*5e-6 = 2.8775e-14
    //   vgs_q = 1; q_g_intr = cox_wl*(1 - (-1) - 0.75*0.5)
    //         = 2.8775e-14*(1 + 1 - 0.375) = 2.8775e-14*1.625 = 4.6759375e-14
    //   junction charges: cj=cjsw=0 -> both fwd and rev terms 0 => q_bs=q_bd=0
    //   out[g] = q_gso + q_gdo + q_gbo + q_g_intr
    //          = 5e-15 + 5e-15 + 1e-14 + 4.6759375e-14 = 6.6759375e-14
    const model: Model = .{ .cgso = 1e-9, .cgdo = 1e-9, .cgbo = 2e-9 };
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 0.0, 1.0, 0.0, 0.0, 0.0, 0.0 }, &model, &inst, 0);
    try testing.expectApproxEqAbs(@as(f64, 6.6759375e-14), out[@intFromEnum(U.gate)], 1e-20);
}
