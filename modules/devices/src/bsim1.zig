const std = @import("std");
const contract = @import("contract");
const Self = @This();
const n_u = contract.nU(Self);

// ============================================================================
// Topology: D -- RD -- D' (intrinsic drain)
//           S -- RS -- S' (intrinsic source)
//           G (gate), B (bulk)
//           BSIM1 channel D' <-> S' with L/W-dependent parameters
//           Bulk-drain and bulk-source pn-junction diodes
// ============================================================================

pub const U = enum(u8) { drain, gate, source, bulk, drain_prime, source_prime };
pub const num_ports: usize = 4;

// ============================================================================
// Model Parameters — every L/W-dependent param has base, L-dep, and W-dep
// ============================================================================

pub const Model = struct {
    // --- Threshold Voltage Parameters ---
    VFB: f32 = 0,
    LVFB: f32 = 0,
    WVFB: f32 = 0,
    PHI: f32 = 0,
    LPHI: f32 = 0,
    WPHI: f32 = 0,
    K1: f32 = 0,
    LK1: f32 = 0,
    WK1: f32 = 0,
    K2: f32 = 0,
    LK2: f32 = 0,
    WK2: f32 = 0,

    // --- DIBL Parameters ---
    ETA: f32 = 0,
    LETA: f32 = 0,
    WETA: f32 = 0,
    X2E: f32 = 0,
    LX2E: f32 = 0,
    WX2E: f32 = 0,
    X3E: f32 = 0,
    LX3E: f32 = 0,
    WX3E: f32 = 0,

    // --- Mobility Parameters ---
    MUZ: f32 = 0,
    X2MZ: f32 = 0,
    LX2MZ: f32 = 0,
    WX2MZ: f32 = 0,
    MUS: f32 = 0,
    LMUS: f32 = 0,
    WMUS: f32 = 0,
    X2MS: f32 = 0,
    LX2MS: f32 = 0,
    WX2MS: f32 = 0,
    X3MS: f32 = 0,
    LX3MS: f32 = 0,
    WX3MS: f32 = 0,
    U0: f32 = 0,
    LU0: f32 = 0,
    WU0: f32 = 0,
    X2U0: f32 = 0,
    LX2U0: f32 = 0,
    WX2U0: f32 = 0,
    U1: f32 = 0,
    LU1: f32 = 0,
    WU1: f32 = 0,
    X2U1: f32 = 0,
    LX2U1: f32 = 0,
    WX2U1: f32 = 0,
    X3U1: f32 = 0,
    LX3U1: f32 = 0,
    WX3U1: f32 = 0,

    // --- Subthreshold Slope Parameters ---
    N0: f32 = 0,
    LN0: f32 = 0,
    WN0: f32 = 0,
    NB: f32 = 0,
    LNB: f32 = 0,
    WNB: f32 = 0,
    ND: f32 = 0,
    LND: f32 = 0,
    WND: f32 = 0,

    // --- Process Parameters ---
    TOX: f32 = 0,
    DL: f32 = 0,
    DW: f32 = 0,
    LD: f32 = 0,
    VDD: f32 = 0,
    TEMP: f32 = 0,

    // --- Source/Drain Resistance and Junction Parameters ---
    RSH: f32 = 0,
    JS: f32 = 0,
    PB: f32 = 0.1,
    MJ: f32 = 0,
    PBSW: f32 = 0.1,
    MJSW: f32 = 0,
    CJ: f32 = 0,
    CJSW: f32 = 0,
    WDF: f32 = 0,
    DELL: f32 = 0,

    // --- Overlap Capacitance Parameters ---
    CGSO: f32 = 0,
    CGDO: f32 = 0,
    CGBO: f32 = 0,

    // --- Noise Parameters ---
    KF: f32 = 0,
    AF: f32 = 1,

    // --- Model Type ---
    XPART: bool = false,
    type_: i32 = 1,
};

// ============================================================================
// Instance Parameters
// ============================================================================

pub const Instance = struct {
    W: f32 = 5e-6,
    L: f32 = 5e-6,
    TEMP: f64 = 300.15,
    M: f32 = 1.0,
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
    // Bulk junctions: B -- D', B -- S'
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    // Gate row (no DC current but derivatives may exist)
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
};

// ============================================================================
// Sparse Capacitance Stamp Pattern
// ============================================================================

pub const c_pattern_override = [_]contract.Entry(n_u){
    // Gate charges: G -- S', G -- D', G -- B
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.gate), .col = @intFromEnum(U.bulk) },
    // Bulk charges: B -- S', B -- D', B -- G
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.bulk), .col = @intFromEnum(U.gate) },
    // D' charges: D' -- D', D' -- G, D' -- B
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.drain_prime) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.bulk) },
    // S' charges: S' -- S', S' -- G, S' -- B, S' -- D'
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.source_prime) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.gate) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.bulk) },
    .{ .row = @intFromEnum(U.source_prime), .col = @intFromEnum(U.drain_prime) },
};

// ============================================================================
// Noise Sources
// ============================================================================

pub const noise_gens = [_]contract.NoiseGen(Self){
    // Drain resistance thermal noise: D -- D'
    .{ .row = @intFromEnum(U.drain), .col = @intFromEnum(U.drain_prime), .kind = .thermal },
    // Source resistance thermal noise: S -- S'
    .{ .row = @intFromEnum(U.source), .col = @intFromEnum(U.source_prime), .kind = .thermal },
    // Channel shot noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .shot },
    // Flicker noise: D' -- S'
    .{ .row = @intFromEnum(U.drain_prime), .col = @intFromEnum(U.source_prime), .kind = .flicker },
};

// ============================================================================
// Helper: L/W-dependent parameter extraction
// ============================================================================

inline fn lwParam(base: f64, l_dep: f64, w_dep: f64, l_eff_um: f64, w_eff_um: f64) f64 {
    return base + l_dep / l_eff_um + w_dep / w_eff_um;
}

// ============================================================================
// DC Parameter Preprocessing (pure f64 — no x dependence)
// ============================================================================

const DcParams = struct {
    type_f: f64,
    inst_m: f64,
    vt: f64,
    l_eff_um: f64,
    m_vdd: f64,
    g_rd: f64,
    g_rs: f64,
    i_s_drain: f64,
    i_s_source: f64,
    vfb_eff: f64,
    phi_eff: f64,
    k1_eff: f64,
    k2_eff: f64,
    eta_eff: f64,
    x2e_eff: f64,
    x3e_eff: f64,
    beta0_0: f64,
    beta0_b: f64,
    beta_vdd: f64,
    beta_vdd_b: f64,
    beta_vdd_d: f64,
    u_gs: f64,
    u_gs_b: f64,
    u_ds: f64,
    u_ds_b: f64,
    u_ds_d: f64,
    n0_eff: f64,
    nb_eff: f64,
    nd_eff: f64,
    has_uds: bool,
    subth_disabled: bool,
};

fn dcParams(model: *const Model, instance: *const Instance) DcParams {
    // --- Physical constants ---
    const eps_sio2: f64 = 3.453e-13; // F/cm

    // --- Cast model parameters to f64 ---
    const type_f: f64 = @floatFromInt(model.type_);
    const m_vfb: f64 = @as(f64, model.VFB);
    const m_lvfb: f64 = @as(f64, model.LVFB);
    const m_wvfb: f64 = @as(f64, model.WVFB);
    const m_phi: f64 = @as(f64, model.PHI);
    const m_lphi: f64 = @as(f64, model.LPHI);
    const m_wphi: f64 = @as(f64, model.WPHI);
    const m_k1: f64 = @as(f64, model.K1);
    const m_lk1: f64 = @as(f64, model.LK1);
    const m_wk1: f64 = @as(f64, model.WK1);
    const m_k2: f64 = @as(f64, model.K2);
    const m_lk2: f64 = @as(f64, model.LK2);
    const m_wk2: f64 = @as(f64, model.WK2);
    const m_eta: f64 = @as(f64, model.ETA);
    const m_leta: f64 = @as(f64, model.LETA);
    const m_weta: f64 = @as(f64, model.WETA);
    const m_x2e: f64 = @as(f64, model.X2E);
    const m_lx2e: f64 = @as(f64, model.LX2E);
    const m_wx2e: f64 = @as(f64, model.WX2E);
    const m_x3e: f64 = @as(f64, model.X3E);
    const m_lx3e: f64 = @as(f64, model.LX3E);
    const m_wx3e: f64 = @as(f64, model.WX3E);
    const m_muz: f64 = @as(f64, model.MUZ);
    const m_x2mz: f64 = @as(f64, model.X2MZ);
    const m_lx2mz: f64 = @as(f64, model.LX2MZ);
    const m_wx2mz: f64 = @as(f64, model.WX2MZ);
    const m_mus: f64 = @as(f64, model.MUS);
    const m_lmus: f64 = @as(f64, model.LMUS);
    const m_wmus: f64 = @as(f64, model.WMUS);
    const m_x2ms: f64 = @as(f64, model.X2MS);
    const m_lx2ms: f64 = @as(f64, model.LX2MS);
    const m_wx2ms: f64 = @as(f64, model.WX2MS);
    const m_x3ms: f64 = @as(f64, model.X3MS);
    const m_lx3ms: f64 = @as(f64, model.LX3MS);
    const m_wx3ms: f64 = @as(f64, model.WX3MS);
    const m_u0: f64 = @as(f64, model.U0);
    const m_lu0: f64 = @as(f64, model.LU0);
    const m_wu0: f64 = @as(f64, model.WU0);
    const m_x2u0: f64 = @as(f64, model.X2U0);
    const m_lx2u0: f64 = @as(f64, model.LX2U0);
    const m_wx2u0: f64 = @as(f64, model.WX2U0);
    const m_u1: f64 = @as(f64, model.U1);
    const m_lu1: f64 = @as(f64, model.LU1);
    const m_wu1: f64 = @as(f64, model.WU1);
    const m_x2u1: f64 = @as(f64, model.X2U1);
    const m_lx2u1: f64 = @as(f64, model.LX2U1);
    const m_wx2u1: f64 = @as(f64, model.WX2U1);
    const m_x3u1: f64 = @as(f64, model.X3U1);
    const m_lx3u1: f64 = @as(f64, model.LX3U1);
    const m_wx3u1: f64 = @as(f64, model.WX3U1);
    const m_n0: f64 = @as(f64, model.N0);
    const m_ln0: f64 = @as(f64, model.LN0);
    const m_wn0: f64 = @as(f64, model.WN0);
    const m_nb: f64 = @as(f64, model.NB);
    const m_lnb: f64 = @as(f64, model.LNB);
    const m_wnb: f64 = @as(f64, model.WNB);
    const m_nd: f64 = @as(f64, model.ND);
    const m_lnd: f64 = @as(f64, model.LND);
    const m_wnd: f64 = @as(f64, model.WND);
    const m_tox: f64 = @as(f64, model.TOX);
    const m_dl: f64 = @as(f64, model.DL);
    const m_dw: f64 = @as(f64, model.DW);
    const m_vdd: f64 = @as(f64, model.VDD);
    const m_rsh: f64 = @as(f64, model.RSH);
    const m_js: f64 = @as(f64, model.JS);
    const m_wdf: f64 = @as(f64, model.WDF);
    const m_dell: f64 = @as(f64, model.DELL);

    // --- Cast instance parameters to f64 ---
    const inst_w: f64 = @as(f64, instance.W);
    const inst_l: f64 = @as(f64, instance.L);
    const inst_temp: f64 = instance.TEMP;
    const inst_m: f64 = @as(f64, instance.M);

    // ========================================================================
    // Effective Geometry
    // ========================================================================
    const l_eff_m = @max(inst_l - m_dl * 1.0e-6, 1.0e-9);
    const w_eff_raw = @max(inst_w, 1.0e-9);
    const l_eff_um = @max(l_eff_m * 1.0e6, 0.01);
    const w_eff_um = @max(w_eff_raw * 1.0e6 - m_dw, 0.01);
    const w_eff_m = @max(w_eff_raw - m_dw * 1.0e-6, 1.0e-8);

    // ========================================================================
    // Oxide Capacitance
    // ========================================================================
    const tox_cm = if (m_tox > 0.0) m_tox * 1.0e-4 else 1.0e-5;
    const cox = eps_sio2 / tox_cm; // F/cm^2

    // ========================================================================
    // L/W-Dependent Effective Parameters
    // ========================================================================
    const vfb_eff = lwParam(m_vfb, m_lvfb, m_wvfb, l_eff_um, w_eff_um);
    const phi_eff = @max(lwParam(m_phi, m_lphi, m_wphi, l_eff_um, w_eff_um), 0.1);
    const k1_eff = lwParam(m_k1, m_lk1, m_wk1, l_eff_um, w_eff_um);
    const k2_eff = lwParam(m_k2, m_lk2, m_wk2, l_eff_um, w_eff_um);
    const eta_eff = lwParam(m_eta, m_leta, m_weta, l_eff_um, w_eff_um);
    const x2e_eff = lwParam(m_x2e, m_lx2e, m_wx2e, l_eff_um, w_eff_um);
    const x3e_eff = lwParam(m_x3e, m_lx3e, m_wx3e, l_eff_um, w_eff_um);
    const x2mz_eff = lwParam(m_x2mz, m_lx2mz, m_wx2mz, l_eff_um, w_eff_um);
    const mus_eff = lwParam(m_mus, m_lmus, m_wmus, l_eff_um, w_eff_um);
    const x2ms_eff = lwParam(m_x2ms, m_lx2ms, m_wx2ms, l_eff_um, w_eff_um);
    const x3ms_eff = lwParam(m_x3ms, m_lx3ms, m_wx3ms, l_eff_um, w_eff_um);
    const uu0_eff = lwParam(m_u0, m_lu0, m_wu0, l_eff_um, w_eff_um);
    const x2u0_eff = lwParam(m_x2u0, m_lx2u0, m_wx2u0, l_eff_um, w_eff_um);
    const uu1_eff = lwParam(m_u1, m_lu1, m_wu1, l_eff_um, w_eff_um);
    const x2u1_eff = lwParam(m_x2u1, m_lx2u1, m_wx2u1, l_eff_um, w_eff_um);
    const x3u1_eff = lwParam(m_x3u1, m_lx3u1, m_wx3u1, l_eff_um, w_eff_um);
    const n0_eff = lwParam(m_n0, m_ln0, m_wn0, l_eff_um, w_eff_um);
    const nb_eff = lwParam(m_nb, m_lnb, m_wnb, l_eff_um, w_eff_um);
    const nd_eff = lwParam(m_nd, m_lnd, m_wnd, l_eff_um, w_eff_um);

    // ========================================================================
    // Beta Factor
    // ========================================================================
    const beta_factor = cox * (w_eff_um / l_eff_um) * 1.0e-4;

    // ========================================================================
    // Source/Drain Resistance
    // ========================================================================
    const g_rd = if (m_rsh > 0.0) inst_m / m_rsh else 1.0e12 * inst_m;
    const g_rs = g_rd;

    // ========================================================================
    // Junction Saturation Current
    // ========================================================================
    const a_jct = if (m_wdf > 0.0) m_wdf * m_dell else w_eff_m * 1.0e-6;
    const i_s_drain = @max(a_jct * m_js, 1.0e-15);
    const i_s_source = @max(a_jct * m_js, 1.0e-15);

    // ========================================================================
    // Thermal Voltage
    // ========================================================================
    const vt = 8.617333262145e-5 * inst_temp;

    // Check if velocity saturation parameters are nonzero (CLM enable)
    const has_uds = (@abs(m_u1) > 1.0e-20) or (@abs(m_x2u1) > 1.0e-20) or (@abs(m_x3u1) > 1.0e-20);

    return .{
        .type_f = type_f,
        .inst_m = inst_m,
        .vt = vt,
        .l_eff_um = l_eff_um,
        .m_vdd = m_vdd,
        .g_rd = g_rd,
        .g_rs = g_rs,
        .i_s_drain = i_s_drain,
        .i_s_source = i_s_source,
        .vfb_eff = vfb_eff,
        .phi_eff = phi_eff,
        .k1_eff = k1_eff,
        .k2_eff = k2_eff,
        .eta_eff = eta_eff,
        .x2e_eff = x2e_eff,
        .x3e_eff = x3e_eff,
        // Beta factors (scaled by geometry)
        .beta0_0 = m_muz * beta_factor,
        .beta0_b = x2mz_eff * beta_factor,
        .beta_vdd = mus_eff * beta_factor,
        .beta_vdd_b = x2ms_eff * beta_factor,
        .beta_vdd_d = x3ms_eff * beta_factor,
        // Mobility degradation parameters (scaled)
        .u_gs = uu0_eff * beta_factor,
        .u_gs_b = x2u0_eff * beta_factor,
        .u_ds = uu1_eff * beta_factor,
        .u_ds_b = x2u1_eff * beta_factor,
        .u_ds_d = x3u1_eff * beta_factor,
        .n0_eff = n0_eff,
        .nb_eff = nb_eff,
        .nd_eff = nd_eff,
        .has_uds = has_uds,
        .subth_disabled = n0_eff >= 200.0,
    };
}

// ============================================================================
// DC Current Function (eval) — value-form: physics generic over scalar S
// ============================================================================

pub fn eval(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return evalFromPrep(S, x, &pc, model, instance, t);
}

pub fn evalFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const gmin: f64 = 1.0e-12;
    const p = &pc.dc;

    // ========================================================================
    // Terminal Voltage Conditioning (PMOS and S/D Swap)
    // ========================================================================
    const vds_typed = x[dp].sub(x[sp]).scale(p.type_f);
    const vgs_typed = x[g].sub(x[sp]).scale(p.type_f);
    const vbs_typed = x[b].sub(x[sp]).scale(p.type_f);

    // Source/drain swap for reverse bias (VDS < 0)
    const vds_abs = vds_typed.abs();
    const vds_neg = vds_typed.minC(0.0);
    const mode = vds_typed.div(vds_abs.addC(1.0e-30));

    const v_ds = vds_abs;
    const v_gs = vgs_typed.sub(vds_neg);
    const v_bs = vbs_typed.sub(vds_neg);
    const v_bd = v_bs.sub(v_ds);

    // ========================================================================
    // Junction Diode Currents
    // ========================================================================
    const arg_bs = v_bs.scale(1.0 / p.vt).minC(80.0);
    const i_bs = arg_bs.exp().addC(-1.0).scale(p.i_s_source).add(v_bs.scale(gmin));

    const arg_bd = v_bd.scale(1.0 / p.vt).minC(80.0);
    const i_bd = arg_bd.exp().addC(-1.0).scale(p.i_s_drain).add(v_bd.scale(gmin));

    // ========================================================================
    // Gate-Field Mobility Degradation (Ugs)
    // ========================================================================
    const u_gs_eff = v_bs.scale(p.u_gs_b).addC(p.u_gs).maxC(0.0);

    // ========================================================================
    // Velocity Saturation Parameter (Uds)
    // ========================================================================
    const u_ds_raw = v_bs.scale(p.u_ds_b).add(v_ds.addC(-p.m_vdd).scale(p.u_ds_d)).addC(p.u_ds);
    const u_ds_scaled = u_ds_raw.maxC(0.0).scale(1.0 / p.l_eff_um);

    // ========================================================================
    // DIBL Effect (eta)
    // ========================================================================
    const eta_raw = v_bs.scale(p.x2e_eff).add(v_ds.addC(-p.m_vdd).scale(p.x3e_eff)).addC(p.eta_eff);
    const eta_clamp = eta_raw.maxC(0.0).minC(1.0);

    // ========================================================================
    // Surface Potential and Body Effect
    // ========================================================================
    const v_pb = v_bs.minC(0.0).neg().addC(p.phi_eff);
    const sqrt_vpb = v_pb.maxC(0.001).sqrt();

    // ========================================================================
    // Threshold Voltage
    // ========================================================================
    const v_on = sqrt_vpb.scale(p.k1_eff).sub(v_pb.scale(p.k2_eff)).sub(eta_clamp.mul(v_ds)).addC(p.vfb_eff + p.phi_eff);

    // ========================================================================
    // Gate Overdrive
    // ========================================================================
    const vgst = v_gs.sub(v_on);
    const vgst_pos = vgst.maxC(0.0);

    // ========================================================================
    // G and A Factors
    // ========================================================================
    const one = S.con(1.0);
    const g_factor = one.sub(one.div(v_pb.scale(0.8364).addC(1.744)));
    const a_factor = g_factor.scale(p.k1_eff / 2.0).div(sqrt_vpb).addC(1.0).maxC(1.0);

    // ========================================================================
    // Mobility Degradation Factor (Arg)
    // ========================================================================
    const arg_mob = u_gs_eff.mul(vgst).addC(1.0).maxC(1.0);

    // ========================================================================
    // Beta Interpolation (Quadratic in VDS)
    // ========================================================================
    const beta_vds0 = v_bs.scale(p.beta0_b).addC(p.beta0_0);
    const beta_vdd_val = v_bs.scale(p.beta_vdd_b).addC(p.beta_vdd);

    const beta_0 = if (p.m_vdd > 0.001) blk: {
        const c1 = beta_vdd_val.neg().add(beta_vds0).addC(p.beta_vdd_d * p.m_vdd).scale(1.0 / (p.m_vdd * p.m_vdd));
        const c2 = beta_vdd_val.sub(beta_vds0).scale(2.0 / p.m_vdd).addC(-p.beta_vdd_d);
        break :blk c1.mul(v_ds).add(c2).mul(v_ds).add(beta_vds0);
    } else beta_vds0;

    // ========================================================================
    // Beta with Mobility Degradation
    // ========================================================================
    const beta = beta_0.div(arg_mob);

    // ========================================================================
    // Saturation Voltage (VDSAT)
    // ========================================================================
    const v_c = u_ds_scaled.mul(vgst_pos).div(a_factor).maxC(0.0);
    const k_sat = v_c.scale(2.0).addC(1.0).sqrt().add(v_c).addC(1.0).scale(0.5);
    const vdsat = vgst_pos.div(a_factor.mul(k_sat.sqrt())).maxC(0.0);

    // ========================================================================
    // Drain Current (Unified Model)
    // ========================================================================
    const vds_eff = v_ds.min(vdsat);

    // Triode-style core current
    const argl1 = u_ds_scaled.mul(vds_eff).addC(1.0).maxC(1.0);
    const argl2 = vgst_pos.sub(a_factor.mul(vds_eff).scale(0.5));
    const id_base = beta.mul(argl2).mul(vds_eff).div(argl1);

    // ========================================================================
    // Channel Length Modulation (CLM)
    // ========================================================================
    const vds_excess = v_ds.sub(vdsat).maxC(0.0);
    const id_main = if (p.has_uds) id_base.mul(u_ds_scaled.mul(vds_excess).addC(1.0)) else id_base;

    // ========================================================================
    // Subthreshold Current
    // ========================================================================
    const n_sub = v_bs.scale(p.nb_eff).add(v_ds.scale(p.nd_eff)).addC(p.n0_eff).maxC(0.5);
    const w_ds = v_ds.scale(-1.0 / p.vt).minC(80.0).exp().neg().addC(1.0);
    const w_gs = vgst.div(n_sub.scale(p.vt)).minC(80.0).exp();
    const i_weak_0 = w_gs.mul(w_ds).scale(6.04965 * p.vt * p.vt * p.beta0_0);
    const i_limit = 4.5 * p.vt * p.vt * p.beta0_0;
    const i_subth_raw = i_weak_0.scale(i_limit).div(i_weak_0.addC(i_limit + 1.0e-30));
    const i_subth = if (p.subth_disabled) S.con(0.0) else i_subth_raw;

    // ========================================================================
    // Total Drain Current
    // ========================================================================
    const i_d_total = id_main.add(i_subth).maxC(0.0).scale(p.type_f * p.inst_m);

    // ========================================================================
    // Series Resistance Currents
    // ========================================================================
    const i_rd = x[d].sub(x[dp]).scale(p.g_rd);
    const i_rs = x[s].sub(x[sp]).scale(p.g_rs);

    // ========================================================================
    // KCL Node Assembly
    // ========================================================================
    // I_d = I_RD (current flowing into external drain)
    // I_g = 0
    // I_s = I_RS (current flowing into external source)
    // I_b = (I_BD + I_BS) * M
    // I_d' = -I_RD + I_D * type * M - I_BD * M
    // I_s' = -I_RS - I_D * type * M - I_BS * M
    //
    // Note: i_d_total already includes type_f * inst_m.
    // The mode factor handles source/drain reversal:
    //   In normal mode (mode=+1), current flows d'->s'
    //   In reversed mode (mode=-1), current flows s'->d'
    // The spec's I_D includes type*M, so we use i_d_total directly
    // but multiply by mode for the d'/s' node assignment.

    const i_ds_mode = i_d_total.mul(mode);

    var out: [n_u]S = undefined;
    out[d] = i_rd;
    out[g] = S.con(0.0);
    out[s] = i_rs;
    out[b] = i_bd.add(i_bs).scale(p.inst_m);
    out[dp] = i_rd.neg().add(i_ds_mode).sub(i_bd.scale(p.inst_m));
    out[sp] = i_rs.neg().sub(i_ds_mode).sub(i_bs.scale(p.inst_m));
    return out;
}

// ============================================================================
// Charge Parameter Preprocessing (pure f64 — no x dependence)
// ============================================================================

const QParams = struct {
    type_f: f64,
    inst_m: f64,
    vfb_eff: f64,
    phi_eff: f64,
    k1_eff: f64,
    wl_cox: f64,
    cgd_w: f64, // CGDO * Weff
    cgs_w: f64, // CGSO * Weff
    cgb_l: f64, // CGBO * Leff
    cj_lin: f64, // c_zbs + c_zbssw (same for drain side)
    cj_quad: f64, // 0.5 * (c_zbs*MJ/PB + c_zbssw*MJSW/PBSW)
};

fn qParams(model: *const Model, instance: *const Instance) QParams {
    // --- Physical constants ---
    const eps_sio2: f64 = 3.453e-13; // F/cm

    // --- Cast model parameters to f64 ---
    const type_f: f64 = @floatFromInt(model.type_);
    const m_vfb: f64 = @as(f64, model.VFB);
    const m_lvfb: f64 = @as(f64, model.LVFB);
    const m_wvfb: f64 = @as(f64, model.WVFB);
    const m_phi: f64 = @as(f64, model.PHI);
    const m_lphi: f64 = @as(f64, model.LPHI);
    const m_wphi: f64 = @as(f64, model.WPHI);
    const m_k1: f64 = @as(f64, model.K1);
    const m_lk1: f64 = @as(f64, model.LK1);
    const m_wk1: f64 = @as(f64, model.WK1);
    const m_tox: f64 = @as(f64, model.TOX);
    const m_dl: f64 = @as(f64, model.DL);
    const m_dw: f64 = @as(f64, model.DW);
    const m_cgso: f64 = @as(f64, model.CGSO);
    const m_cgdo: f64 = @as(f64, model.CGDO);
    const m_cgbo: f64 = @as(f64, model.CGBO);
    const m_cj: f64 = @as(f64, model.CJ);
    const m_cjsw: f64 = @as(f64, model.CJSW);
    const m_pb: f64 = @max(@as(f64, model.PB), 0.01);
    const m_mj: f64 = @as(f64, model.MJ);
    const m_pbsw: f64 = @max(@as(f64, model.PBSW), 0.01);
    const m_mjsw: f64 = @as(f64, model.MJSW);
    const m_wdf: f64 = @as(f64, model.WDF);

    // --- Cast instance parameters to f64 ---
    const inst_w: f64 = @as(f64, instance.W);
    const inst_l: f64 = @as(f64, instance.L);
    const inst_m: f64 = @as(f64, instance.M);

    // ========================================================================
    // Effective Geometry
    // ========================================================================
    const l_eff_m = @max(inst_l - m_dl * 1.0e-6, 1.0e-9);
    const w_eff_raw = @max(inst_w, 1.0e-9);
    const l_eff_um = @max(l_eff_m * 1.0e6, 0.01);
    const w_eff_um = @max(w_eff_raw * 1.0e6 - m_dw, 0.01);
    const w_eff_m = @max(w_eff_raw - m_dw * 1.0e-6, 1.0e-8);

    // ========================================================================
    // Oxide Capacitance
    // ========================================================================
    const tox_cm = if (m_tox > 0.0) m_tox * 1.0e-4 else 1.0e-5;
    const cox = eps_sio2 / tox_cm; // F/cm^2

    // ========================================================================
    // L/W-Dependent Effective Parameters (for charge model)
    // ========================================================================
    const vfb_eff = lwParam(m_vfb, m_lvfb, m_wvfb, l_eff_um, w_eff_um);
    const phi_eff = @max(lwParam(m_phi, m_lphi, m_wphi, l_eff_um, w_eff_um), 0.1);
    const k1_eff = lwParam(m_k1, m_lk1, m_wk1, l_eff_um, w_eff_um);

    // ========================================================================
    // WL * Cox (in proper units: Cox[F/cm^2] * Leff[m] * Weff[m] * 1e4)
    // ========================================================================
    const wl_cox = cox * l_eff_m * w_eff_m * 1.0e4;

    // ========================================================================
    // Bulk Junction Depletion Capacitance Coefficients
    // ========================================================================
    // Junction areas and perimeters
    const a_jct = if (m_wdf > 0.0) m_wdf * @as(f64, model.DELL) else w_eff_m * 1.0e-6;
    const p_jct = 2.0 * w_eff_m;

    const c_zbs = m_cj * a_jct;
    const c_zbssw = m_cjsw * p_jct;

    return .{
        .type_f = type_f,
        .inst_m = inst_m,
        .vfb_eff = vfb_eff,
        .phi_eff = phi_eff,
        .k1_eff = k1_eff,
        .wl_cox = wl_cox,
        .cgd_w = m_cgdo * w_eff_m,
        .cgs_w = m_cgso * w_eff_m,
        .cgb_l = m_cgbo * l_eff_m,
        .cj_lin = c_zbs + c_zbssw,
        .cj_quad = 0.5 * (c_zbs * m_mj / m_pb + c_zbssw * m_mjsw / m_pbsw),
    };
}

pub const PrepCache = struct { dc: DcParams, q: QParams };

pub fn computePrep(model: *const Model, instance: *const Instance) PrepCache {
    return .{ .dc = dcParams(model, instance), .q = qParams(model, instance) };
}

// ============================================================================
// Charge Function (q) — value-form
// ============================================================================

pub fn q(comptime S: type, x: [n_u]S, model: *const Model, instance: *const Instance, t: f64) [n_u]S {
    const pc = computePrep(model, instance);
    return qFromPrep(S, x, &pc, model, instance, t);
}

pub fn qFromPrep(comptime S: type, x: [n_u]S, pc: *const PrepCache, model: *const Model, instance: *const Instance, _: f64) [n_u]S {
    @setFloatMode(.optimized);
    _ = model;
    _ = instance;

    const d = @intFromEnum(U.drain);
    const g = @intFromEnum(U.gate);
    const s = @intFromEnum(U.source);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    const p = &pc.q;

    // ========================================================================
    // Terminal Voltages (with type factor)
    // ========================================================================
    const vds_typed = x[dp].sub(x[sp]).scale(p.type_f);
    const vgs_typed = x[g].sub(x[sp]).scale(p.type_f);
    const vbs_typed = x[b].sub(x[sp]).scale(p.type_f);

    // Source/drain swap for reverse bias
    const vds_neg = vds_typed.minC(0.0);
    const v_gs = vgs_typed.sub(vds_neg);
    const v_bs = vbs_typed.sub(vds_neg);

    // ========================================================================
    // Surface Potential and Body Effect (for charge model)
    // ========================================================================
    const v_pb = v_bs.minC(0.0).neg().addC(p.phi_eff);
    const sqrt_vpb = v_pb.maxC(0.001).sqrt();

    // ========================================================================
    // Threshold Voltage for Charge Model (without DIBL)
    // ========================================================================
    const vth_0 = sqrt_vpb.scale(p.k1_eff).addC(p.vfb_eff + p.phi_eff);

    // ========================================================================
    // A Factor for Charge Model
    // ========================================================================
    const one = S.con(1.0);
    const g_factor = one.sub(one.div(v_pb.scale(0.8364).addC(1.744)));
    const a_factor = g_factor.scale(p.k1_eff / 2.0).div(sqrt_vpb).addC(1.0).maxC(1.0);

    // ========================================================================
    // Gate Overdrive for Charge
    // ========================================================================
    const vgst_q = v_gs.sub(vth_0);

    // ========================================================================
    // Saturation Region Gate Charge
    // ========================================================================
    const q_g_sat = v_gs.sub(vgst_q.div(a_factor.scale(3.0))).addC(-(p.vfb_eff + p.phi_eff)).scale(p.wl_cox);

    // ========================================================================
    // Saturation Region Bulk Charge
    // ========================================================================
    const one_minus_a = a_factor.neg().addC(1.0);
    const q_b_sat = vth_0.neg().addC(p.vfb_eff + p.phi_eff).add(one_minus_a.mul(vgst_q).div(a_factor.scale(3.0))).scale(p.wl_cox);

    // ========================================================================
    // Saturation Region Drain Charge
    // ========================================================================
    const q_d_sat = vgst_q.scale(-(4.0 / 15.0) * p.wl_cox);

    // ========================================================================
    // Overlap Charges
    // ========================================================================
    // Voltages for overlap charges (use raw terminal voltages, not swapped)
    const v_gd_ov = x[g].sub(x[dp]);
    const v_gs_ov = x[g].sub(x[sp]);
    const v_gb_ov = x[g].sub(x[b]);

    const q_gd_ov = v_gd_ov.scale(p.cgd_w);
    const q_gs_ov = v_gs_ov.scale(p.cgs_w);
    const q_gb_ov = v_gb_ov.scale(p.cgb_l);

    // ========================================================================
    // Total Gate Charge
    // ========================================================================
    const q_gate = q_g_sat.add(q_gd_ov).add(q_gs_ov).add(q_gb_ov);

    // ========================================================================
    // Bulk Junction Depletion Charges
    // ========================================================================
    // Use raw junction voltages (not type-adjusted) for junction charges
    const vbs_jct = x[b].sub(x[sp]);
    const vbd_jct = x[b].sub(x[dp]);

    // Linearized junction charge (source side)
    const q_bs_jct = vbs_jct.scale(p.cj_lin).add(vbs_jct.mul(vbs_jct).scale(p.cj_quad));

    // Linearized junction charge (drain side)
    const q_bd_jct = vbd_jct.scale(p.cj_lin).add(vbd_jct.mul(vbd_jct).scale(p.cj_quad));

    // ========================================================================
    // Intrinsic Drain and Bulk Charges
    // ========================================================================
    const q_drn = q_d_sat.sub(q_gd_ov);
    const q_bulk = q_b_sat.sub(q_gb_ov);

    // ========================================================================
    // Node Charge Assembly
    // ========================================================================
    var out: [n_u]S = undefined;
    out[d] = S.con(0.0);
    out[g] = q_gate.scale(p.inst_m);
    out[s] = S.con(0.0);
    out[b] = q_bulk.add(q_bd_jct).add(q_bs_jct).scale(p.inst_m);
    out[dp] = q_drn.sub(q_bd_jct).scale(p.inst_m);
    // Charge conservation: Q_s' = -(Q_g + Q_b + Q_d')
    out[sp] = out[g].add(out[b]).add(out[dp]).neg();
    return out;
}

// ============================================================================
// Voltage Limiting
// ============================================================================

pub fn limit(model: *const Model, instance: *const Instance, x_new: [n_u]f64, x_old: [n_u]f64) [n_u]f64 {
    const g = @intFromEnum(U.gate);
    const b = @intFromEnum(U.bulk);
    const dp = @intFromEnum(U.drain_prime);
    const sp = @intFromEnum(U.source_prime);

    // --- Model parameters ---
    const m_vfb: f64 = @as(f64, model.VFB);
    const m_lvfb: f64 = @as(f64, model.LVFB);
    const m_wvfb: f64 = @as(f64, model.WVFB);
    const m_phi: f64 = @as(f64, model.PHI);
    const m_lphi: f64 = @as(f64, model.LPHI);
    const m_wphi: f64 = @as(f64, model.WPHI);
    const m_k1: f64 = @as(f64, model.K1);
    const m_lk1: f64 = @as(f64, model.LK1);
    const m_wk1: f64 = @as(f64, model.WK1);
    const m_dl: f64 = @as(f64, model.DL);
    const m_dw: f64 = @as(f64, model.DW);
    const m_js: f64 = @as(f64, model.JS);
    const m_wdf: f64 = @as(f64, model.WDF);
    const m_dell: f64 = @as(f64, model.DELL);

    const inst_w: f64 = @as(f64, instance.W);
    const inst_l: f64 = @as(f64, instance.L);
    const inst_temp: f64 = instance.TEMP;

    // Effective geometry
    const l_eff_m = @max(inst_l - m_dl * 1.0e-6, 1.0e-9);
    const w_eff_raw = @max(inst_w, 1.0e-9);
    const l_eff_um = @max(l_eff_m * 1.0e6, 0.01);
    const w_eff_um = @max(w_eff_raw * 1.0e6 - m_dw, 0.01);
    const w_eff_m = @max(w_eff_raw - m_dw * 1.0e-6, 1.0e-8);
    _ = w_eff_m;

    // Thermal voltage
    const vt: f64 = 8.617333262145e-5 * inst_temp;

    // Junction saturation current for pnjlim
    const a_jct = if (m_wdf > 0.0) m_wdf * m_dell else @max(inst_w, 1.0e-9) * 1.0e-6;
    const i_s = @max(a_jct * m_js, 1.0e-15);

    // Threshold voltage estimate (Vth0 without DIBL)
    const vfb_eff = lwParam(m_vfb, m_lvfb, m_wvfb, l_eff_um, w_eff_um);
    const phi_eff = @max(lwParam(m_phi, m_lphi, m_wphi, l_eff_um, w_eff_um), 0.1);
    const k1_eff = lwParam(m_k1, m_lk1, m_wk1, l_eff_um, w_eff_um);
    const vth_0 = vfb_eff + phi_eff + k1_eff * @sqrt(@max(phi_eff, 0.001));

    var result = x_new;

    // ========================================================================
    // 1. FET Gate Voltage Limiting (fetlim) for V_GS
    // ========================================================================
    {
        const vgs_new = result[g] - result[sp];
        const vgs_old = x_old[g] - x_old[sp];
        const dv = vgs_new - vgs_old;
        const vtox = vth_0 + 3.5;
        const vtsthi = @abs(2.0 * (vgs_old - vth_0)) + 2.0;
        const vtstlo = vtsthi * 0.5 + 2.0;
        var vgs_limited = vgs_new;

        if (vgs_old >= vtox) {
            if (dv <= 0.0) {
                // Decreasing from above vtox
                if (vgs_new < vtox) {
                    vgs_limited = @max(vgs_new, vth_0 + 2.0);
                } else {
                    // Clamp negative step
                    vgs_limited = @max(vgs_new, vgs_old - vtsthi);
                }
            } else {
                // Increasing from above vtox
                vgs_limited = @min(vgs_new, vgs_old + vtsthi);
            }
        } else if (vgs_old >= vth_0) {
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vth_0 - vtstlo);
            } else {
                vgs_limited = @min(vgs_new, vgs_old + vtsthi);
            }
        } else {
            if (dv <= 0.0) {
                vgs_limited = @max(vgs_new, vgs_old - vtsthi);
            } else {
                vgs_limited = @min(vgs_new, vth_0 + vtstlo);
            }
        }

        const delta_gs = vgs_limited - vgs_new;
        result[g] = result[g] + delta_gs;
    }

    // ========================================================================
    // 2. Drain-Source Voltage Limiting (limvds)
    // ========================================================================
    {
        const vds_new = result[dp] - result[sp];
        const vds_old = x_old[dp] - x_old[sp];
        var vds_limited = vds_new;

        if (vds_old >= 3.5) {
            if (vds_new > vds_old) {
                vds_limited = @min(vds_new, 3.0 * vds_old + 2.0);
            } else {
                if (vds_new < 3.5) {
                    vds_limited = @max(vds_new, 0.5 * vds_old);
                } else {
                    vds_limited = @max(vds_new, 2.0);
                }
            }
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

    // ========================================================================
    // 3. PN Junction Limiting (pnjlim) for V_BS
    // ========================================================================
    {
        const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * i_s));
        const vbs_new = result[b] - result[sp];
        const vbs_old = x_old[b] - x_old[sp];
        var vbs_limited = vbs_new;

        if (vbs_new > v_crit and @abs(vbs_new - vbs_old) > 2.0 * vt) {
            if (vbs_old > 0.0) {
                const arg = (vbs_new - vbs_old) / vt;
                if (arg > 0.0) {
                    vbs_limited = vbs_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
                } else {
                    vbs_limited = v_crit;
                }
            } else {
                vbs_limited = vt * contract.fmath.log(@max(vbs_new / vt, 1.0e-30));
            }
        }

        const delta_bs = vbs_limited - vbs_new;
        result[sp] = result[sp] - delta_bs;
    }

    // ========================================================================
    // 4. PN Junction Limiting (pnjlim) for V_BD
    //    (after V_BS and V_DS are limited, so use updated result)
    // ========================================================================
    {
        const v_crit = vt * contract.fmath.log(vt / (@sqrt(2.0) * i_s));
        const vbd_new = result[b] - result[dp];
        const vbd_old = x_old[b] - x_old[dp];
        var vbd_limited = vbd_new;

        if (vbd_new > v_crit and @abs(vbd_new - vbd_old) > 2.0 * vt) {
            if (vbd_old > 0.0) {
                const arg = (vbd_new - vbd_old) / vt;
                if (arg > 0.0) {
                    vbd_limited = vbd_old + vt * (2.0 + contract.fmath.log(@max(arg - 2.0, 1.0e-30)));
                } else {
                    vbd_limited = v_crit;
                }
            } else {
                vbd_limited = vt * contract.fmath.log(@max(vbd_new / vt, 1.0e-30));
            }
        }

        const delta_bd = vbd_limited - vbd_new;
        result[dp] = result[dp] - delta_bd;
    }

    return result;
}

// ============================================================================
// Parameter Stepping (Convergence Aid)
// ============================================================================

pub fn attempt(model: Model, lambda: f64) Model {
    var m = model;
    // Scale JS (junction saturation current density) with gmin stepping
    const gmin_step: f64 = 1.0e-12;
    const js_orig: f64 = @as(f64, model.JS);
    const js_stepped = js_orig + (gmin_step - js_orig) * (1.0 - lambda);
    m.JS = @floatCast(js_stepped);
    return m;
}

comptime {
    contract.validate(Self);
}

// ============================================================================
// Tests — expectations generated by running the ORIGINAL pointer-form
// i()/q() physics at the same bias points (regression values).
// ============================================================================

const testing = std.testing;

fn expectNear(expected: f64, actual: f64) !void {
    // Relative-ish comparison with a tiny absolute floor for exact zeros.
    const tol = @max(@abs(expected) * 1e-9, 1e-24);
    try testing.expectApproxEqAbs(expected, actual, tol);
}

// Shared DC test model: NMOS, VFB=-0.3, PHI=0.6, K1=0.5, MUZ=MUS=600,
// TOX=0.02um, VDD=5. N0=200 disables subthreshold. RSH=0 -> g_rd=1e12
// (test nodes keep d=d', s=s' so series-R currents are exactly 0).
const dc_model: Model = .{ .VFB = -0.3, .PHI = 0.6, .K1 = 0.5, .MUZ = 600, .MUS = 600, .TOX = 0.02, .VDD = 5, .N0 = 200 };

test "bsim1: saturation region drain current" {
    // Hand check (old formula): Cox = 3.453e-13/2e-6 = 1.7265e-7 F/cm^2,
    // beta0 = 600 * Cox * (W/L=1) * 1e-4 = 1.0359e-8. vds=3, vgs=2, vbs=0:
    // v_pb = 0.6, sqrt = 0.774597, v_on = -0.3+0.6+0.5*0.774597 = 0.687298,
    // vgst = 1.312702, g = 1-1/(1.744+0.8364*0.6) = 0.554737,
    // a = 1+g*0.5/(2*0.774597) = 1.179040. U0=U1=0 -> arg_mob=1, vdsat =
    // vgst/a = 1.11337 < vds -> saturation: id = beta*vgst^2/(2a) = 7.5699e-9.
    // i_bd(v_bd=-3) = 1e-15*(exp(-3/vt)-1) + 1e-12*(-3) = -3.001e-12; i_bs=0.
    // out[dp] = id - i_bd = 7.57293e-9; out[sp] = -id; out[b] = i_bd+i_bs.
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 3.0, 2.0, 0.0, 0.0, 3.0, 0.0 }, &dc_model, &inst, 0);
    try expectNear(0.0, out[0]);
    try expectNear(0.0, out[1]);
    try expectNear(0.0, out[2]);
    try expectNear(-3.0010000000000002e-12, out[3]);
    try expectNear(7.57292826296721e-9, out[4]);
    try expectNear(-7.56992726296721e-9, out[5]);
}

test "bsim1: linear region drain current" {
    // vds = 0.05 < vdsat -> triode: id = beta*(vgst - a*vds/2)*vds
    // (with the VDD-quadratic beta interpolation; MUZ=MUS makes it flat).
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.05, 2.0, 0.0, 0.0, 0.05, 0.0 }, &dc_model, &inst, 0);
    try expectNear(0.0, out[0]);
    try expectNear(0.0, out[1]);
    try expectNear(0.0, out[2]);
    try expectNear(-5.085530392831295e-14, out[3]);
    try expectNear(6.646976053048652e-10, out[4]);
    try expectNear(-6.64646750000937e-10, out[5]);
}

test "bsim1: reverse mode (vds < 0) source/drain swap" {
    // Same bias as the saturation test but with source high: the S/D swap
    // makes |id| identical and mode=-1 flips the d'/s' assignment.
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 0.0, 2.0, 3.0, 0.0, 0.0, 3.0 }, &dc_model, &inst, 0);
    try expectNear(0.0, out[0]);
    try expectNear(0.0, out[1]);
    try expectNear(0.0, out[2]);
    try expectNear(-3.0010000000000002e-12, out[3]);
    try expectNear(-7.566926262967209e-9, out[4]);
    try expectNear(7.56992726296721e-9, out[5]);
}

test "bsim1: subthreshold current" {
    // N0=1.5 enables the weak-inversion branch. vgs=0.3 < v_on=0.687298:
    // vgst_pos=0 -> id_base=0, i_subth = i_limit*i_weak/(i_limit+i_weak)
    // with i_weak = 6.04965*vt^2*beta0*exp(vgst/(1.5*vt))*(1-exp(-vds/vt)).
    const model: Model = .{ .VFB = -0.3, .PHI = 0.6, .K1 = 0.5, .MUZ = 600, .MUS = 600, .TOX = 0.02, .VDD = 5, .N0 = 1.5 };
    const inst: Instance = .{};
    const out = contract.evalValues(Self, .{ 1.0, 0.3, 0.0, 0.0, 1.0, 0.0 }, &model, &inst, 0);
    try expectNear(0.0, out[0]);
    try expectNear(0.0, out[1]);
    try expectNear(0.0, out[2]);
    try expectNear(-1.001e-12, out[3]);
    try expectNear(1.002936692299156e-12, out[4]);
    try expectNear(-1.9366922991559728e-15, out[5]);
}

// Charge test model: same threshold params + overlap and junction caps.
const q_model: Model = .{ .VFB = -0.3, .PHI = 0.6, .K1 = 0.5, .TOX = 0.02, .CGSO = 1e-10, .CGDO = 1e-10, .CGBO = 1e-10, .CJ = 1e-4, .CJSW = 1e-10, .PB = 0.8, .MJ = 0.5, .PBSW = 0.8, .MJSW = 0.33 };

test "bsim1: charges at vgs=2 vds=3 vbs=0" {
    // Hand check (old formula): wl_cox = 1.7265e-7 * 5e-6 * 5e-6 * 1e4 =
    // 4.31625e-14. vth0 = 0.687298, vgst_q = 1.312702, a = 1.179040.
    // q_g_sat = wl_cox*(2 + 0.3 - 0.6 - 1.312702/(3*1.179040)) = 5.7358e-14.
    // Overlaps: q_gd = 1e-10*5e-6*(2-3) = -5e-16, q_gs = +1e-15, q_gb = +1e-15
    // -> q_gate = 5.8858e-14.
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 3.0, 2.0, 0.0, 0.0, 3.0, 0.0 }, &q_model, &inst, 0);
    try expectNear(0.0, out[0]);
    try expectNear(5.885769913703717e-14, out[1]);
    try expectNear(0.0, out[2]);
    try expectNear(-2.1822210306805246e-14, out[3]);
    try expectNear(-1.3371695566533385e-14, out[4]);
    try expectNear(-2.3663793263698545e-14, out[5]);
}

test "bsim1: charges with body bias vbs=-1" {
    // Body bias raises v_pb to phi+1, changing vth0/a and the junction terms.
    const inst: Instance = .{};
    const out = contract.qValues(Self, .{ 3.0, 2.0, 0.0, -1.0, 3.0, 0.0 }, &q_model, &inst, 0);
    try expectNear(0.0, out[0]);
    try expectNear(6.182615247769862e-14, out[1]);
    try expectNear(0.0, out[2]);
    try expectNear(-3.194506170456528e-14, out[3]);
    try expectNear(-1.158743632241181e-14, out[4]);
    try expectNear(-1.829365445072153e-14, out[5]);
}
